# =============================================================================
# 分析 agent：自动执行循环
# =============================================================================
# 用户的原话是「我要的是分析agent，你写的似乎只是个chatbox」。诊断属实 ——
# 在这之前，全仓库只有一处 dsapp_llm_start() 调用，执行结果写进 tasks 表、
# 渲染在「任务」页，**从来不回到模型**。模型写完代码这一轮就结束了，下一步
# 做什么完全靠人重新描述。所谓 agent 的核心 —— 看结果、改错、继续 ——
# 一行都没有。
#
# 这个文件就是那个核心：一个状态机，把「模型输出代码 → 执行 → 结果回喂 →
# 模型接着做」串成一个循环，直到模型给出一个不含可执行代码块的回答为止。
#
# -----------------------------------------------------------------------------
# 为什么不用原生 tool-calling
# -----------------------------------------------------------------------------
# 不是因为厂商差异，是因为安全模型。jobs.R 的 dsapp_extract_block() 被明确
# 注释为**安全属性**：浏览器只发坐标，代码一律由服务端回数据库重读重扫。
# tool-calling 会把这条反过来 —— 模型直接产出要执行的参数，用户在代码跑完
# 之前看不到它。那样「确认执行」、扫描徽章、任务页的来源追溯全部失效。
# 所以继续用代码围栏，只是把"谁来点执行"从人换成了循环。
#
# -----------------------------------------------------------------------------
# 状态机
# -----------------------------------------------------------------------------
#   idle
#    └─(用户发送)→ generating                  LLM 流式，复用 mod_chat 的轮询
#         └─(生成结束，dsapp_split_segments 解析)
#              ├─ 无可执行块 ─────────────────→ idle（最终答复，循环结束）
#              ├─ 被截断 / 未闭合 / 被拦截 ───→ 回喂说明 → generating
#              ├─ 命中需确认的警告 ───────────→ awaiting_user（内联卡片）
#              │     ⚠️ ★ V15.6 item 5 之后**没有规则会走到这里**了（外发数据
#              │        那条降成纯记录，见 dsapp_agent_scan_decision）。这一格
#              │        留在图里是因为状态机本身还在，别照着它去找触发点。
#              └─ 可执行 → submitting → waiting   轮询 db_task_get(task_id)
#                                           └─→ 组装结果 → 写 tool 消息 → generating
#                                                （★ V15.5：轮次用满时不再当场结束，
#                                                  改为让模型收尾一轮，见 feed_result
#                                                  里"最后一次机会"那一段）
#
# ⚠️ 这个文件里**绝不能**读 rv$session_id（mod_chat 的响应式值）：
#    循环可能在对话已经被删掉之后还在跑，那时读到的 id 指向一行不存在的
#    会话，任何 db_message_add 都会撞外键（db.R 开了 foreign_keys）。
#    起手就把 sid 抄进 a$sid，之后只用它。
# =============================================================================


# 进程级的「这条助手消息已经被某一轮取走执行了」登记表。
#
# ⚠️ 必须是**进程级**而不是每个标签页一份：本站是 Shiny Server 开源版，
#    一个应用一个 R 进程、所有访客共用，所以一个全局环境正好等价于
#    "所有标签页共享"。同一个对话在两个标签页里各开一个 agent 循环时，
#    同一段代码只会被执行一次。
#
# 为什么需要它：循环的入口是"助手消息生成完毕"这个事件。这个事件理论上
# 可能对同一条消息触发两次（重复渲染、响应式抖动），而重复执行的后果是
# 同一段重代码跑两遍 —— 在生信场景里那是几十分钟和一倍的内存，还很可能是
# 一个静默的错误结果。登记表是纯内存的，不落盘、不需要迁移。
dsapp_agent_claims <- new.env(parent = emptyenv())

#' 认领一条助手消息（幂等）
#'
#' @return TRUE = 这次认领成功（可以执行）；FALSE = 已经被别处认领过了
dsapp_agent_claim <- function(message_id) {
  if (is.null(message_id) || length(message_id) == 0 || is.na(message_id)) {
    # 拿不到消息 id 就不做去重。宁可偶尔重复执行，也不要因为一个空 id
    # 把整个循环卡死在"没人认领"上。
    return(TRUE)
  }
  key <- as.character(as.integer(message_id))
  reg <- dsapp_agent_claims
  if (is.null(reg$at)) { reg$at <- numeric(0); reg$ids <- character(0) }
  if (key %in% reg$ids) return(FALSE)

  reg$ids <- c(reg$ids, key)
  reg$at  <- c(reg$at, as.numeric(Sys.time()))

  # 只留最近一小时的。不清的话这个表会随着应用运行一直长 —— 每条助手
  # 消息一个条目，一天下来几千条，虽然每条只有几十字节，但没理由留着。
  if (length(reg$ids) > 500) {
    keep <- reg$at > (as.numeric(Sys.time()) - 3600)
    reg$ids <- reg$ids[keep]
    reg$at  <- reg$at[keep]
  }
  TRUE
}

#' 取消一条认领
#'
#' 用于"这一轮决定不执行"的路径（比如命中 exfil 警告后用户点了终止）。
#' 不取消的话，用户点「继续」时会被自己的认领挡住，而且看不出为什么。
dsapp_agent_release <- function(message_id) {
  if (is.null(message_id) || length(message_id) == 0 || is.na(message_id)) {
    return(invisible(FALSE))
  }
  key <- as.character(as.integer(message_id))
  reg <- dsapp_agent_claims
  if (is.null(reg$ids)) return(invisible(FALSE))
  keep <- reg$ids != key
  reg$ids <- reg$ids[keep]
  reg$at  <- reg$at[keep]
  invisible(TRUE)
}


# =============================================================================
# 纯函数部分：选块、判定、组装回喂文本
#
# 这三件事是循环里最容易出错、又最难从界面上看出错的地方，所以全部做成
# 纯函数，selftest.R 里能直接喂字符串验证（见"agent 循环的纯函数部分"）。
# =============================================================================

#' 从一段助手回复里挑出这一轮要执行的代码块
#'
#' ⚠️ 用 dsapp_split_segments() 而不是 dsapp_parse_code_blocks()。
#'    后者没有 closed 字段：未闭合的围栏会被一路读到文本结尾，于是流式
#'    截断的半截代码会被当成一个"完整"的块执行 —— 然后拿着语法错误的报错
#'    去让模型"改错"，而模型看着自己写的东西认为没问题，来回几轮都修不好。
#'    前者返回 closed，能区分"围栏没闭合"和"围栏闭合但内容是半截的"。
#'
#' 一轮只取第一个可执行块。后面的会被跳过，并且要**明确告诉模型**它被跳过
#' 了 —— 不说的话模型以为三步都跑了，会拿着不存在的产物继续往下做。
#'
#' @param text 助手这一轮的完整回复
#' @param finish_reason LLM 的结束原因（见 llm.R），"length" = 被截断
#' @param cut_off 流是被中途掐断的（没收到 `[DONE]`、也没有 finish_reason），
#'   见 llm.R 里 `complete` 的说明。和 "length" 一样，半截的代码不能执行。
#' @return list(kind, blk, extra, reason)
#'   kind: "ok" 有可执行的块 / "none" 一个都没有（循环结束）
#'         / "truncated" 回复被截断 / "unclosed" 围栏没闭合
#'         / "unparsed" 正文里有 ``` 但平台一个块都没认出来（见下面 ★ V15.6）
dsapp_agent_pick_block <- function(text, finish_reason = NULL, cut_off = FALSE) {
  none <- function(kind, reason) {
    list(kind = kind, blk = NULL, extra = 0L, reason = reason)
  }

  # 被 max_tokens 掐断的回复一律不执行。哪怕代码块本身看起来闭合了 ——
  # 截断点上很可能正好是"代码写完了、结论还没写完"，但更常见的是代码
  # 本身就在围栏中间被切断。宁可让模型重发一次，也不要跑一段半截脚本
  # 再花几轮去修一个不存在的 bug。
  if (identical(finish_reason, "length")) {
    return(none("truncated", "上一条回复被长度上限截断，末尾的代码可能不完整"))
  }
  # 流被中途掐断，同理。**这个判断必须在这里**，不能只靠上面的 "length"：
  # 掐断的那次服务端报的还是 finish_reason = "stop"（线上实例见 mod_chat.R
  # 里 cut_off 那段），从 finish_reason 上根本看不出来。
  if (isTRUE(cut_off)) {
    return(none("truncated", "上一条回复没有生成完（流被中断），末尾的代码可能不完整"))
  }

  segs <- dsapp_split_segments(text)
  if (!length(segs)) return(none("none", "回复里没有代码块"))

  codes <- Filter(function(s) identical(s$type, "code"), segs)
  if (!length(codes)) {
    # ★ V15.6 安全带：正文里**有**反引号，却一个代码段都没认出来 —— 这不是
    #   "模型只是说了句结论"，是"它写了围栏、平台没认出来"。两者的出口差得
    #   很远：前者正常收尾，后者必须让模型重发。
    #   2026-09-30 线上那次「跑到一半不转了」就是这种形状（开围栏粘在正文
    #   末尾）。真正的写法问题已经在 dsapp_fence_open() 那边修掉了，这一支
    #   是**兜底**：以后再有认不出来的新花样，最多浪费一轮，不会静默收尾。
    #    判据要**窄**：只认"``` 后面跟着语言标注"的写法（那才是想开围栏的
    #    样子）。正文里随口提一个光秃秃的 ``` 不算 —— 那会把一整轮对话浪费
    #    在跟模型解释 markdown 上。
    if (grepl("```[A-Za-z0-9_+-]", text)) {
      return(none("unparsed", "回复里出现了 ``` 但没有一个能被识别成代码块"))
    }
    return(none("none", "回复里没有代码块"))
  }

  # 不可执行的语言（text / json / log……）不算数，见 jobs.R 的 dsapp_norm_lang
  exec <- Filter(function(s) s$lang %in% c("R", "Python", "Bash"), codes)
  if (!length(exec)) {
    return(none("none", "回复里的代码块都不是可执行语言（r / python / bash）"))
  }

  closed <- Filter(function(s) isTRUE(s$closed), exec)
  if (!length(closed)) {
    return(none("unclosed", "代码块的结束围栏没有闭合，内容可能不完整"))
  }

  first <- closed[[1]]
  list(kind = "ok", blk = list(lang = first$lang, code = first$code,
                               index = first$index),
       extra = length(closed) - 1L, reason = "")
}

#' 根据扫描结果决定这一轮怎么办
#'
#' 现在只有两档：**高危拦截**（回喂理由让模型改写）和**放行**。所有 warn
#' 级规则一律自动放行、只留一行可见标注（`dsapp_agent_warn_labels()`），
#' 生信里下载参考数据、连 API 拉注释是日常动作，本来也不该由用户来判。
#'
#' ★★ V15.6 item 5：用户的原话是「发起网络请求不需要用户同意，可以直接
#'    执行」。改这儿之前，可疑级里**只有 exfil_curl_post 一条**会让循环
#'    停下来弹确认框（`decision == "confirm"`）。去掉它之后，"停下等用户"
#'    这条路上再也没有任何规则会走 —— 这是**故意的**，别再按"这条提示其实
#'    挺有用"给它加回来：用户拿到的是一段他没法判断的代码（他不知道那个
#'    地址该不该信、也不知道数据发出去会怎样），却没有"不发"这个选项
#'    （不发就跑不动），于是唯一的结局是每次点一下「继续」。这和 V13.8
#'    删掉的 install_pkg 是同一类——**拦住的从来不是危险动作，是正常工作**。
#'
#' ⚠️ 于是 `awaiting_user` 这条状态（agent.R 下面那两处 `decision ==
#'    "confirm"` 分支、mod_chat.R 的内联确认卡、detach.R 的释放）就成了
#'    **够不着**的分支。之所以留着不删：它是"循环因为等人而停下"这件事
#'    在状态机里的**唯一**表示，删掉等于把这种状态从设计里抹掉，下次真
#'    需要"停下来问"时又得从头长一遍。留着它不影响任何行为 —— 没有规则
#'    能让它发生。
#'
#' ⚠️ V13.8 item 3：这里原来还列着 install_pkg，但那条规则本身已经从
#'    R/scanner.R 里删掉了（用户：「联网装包不用风险提示」），所以这里
#'    不再提它 —— 提了会让下一个人以为它还在、还归这一档管。
#'
#' @return "blocked" | "run"（"confirm" 保留在返回值的类型里，但当前没有
#'   任何规则会产生它，见上面的 V15.6 item 5）
dsapp_agent_scan_decision <- function(scan) {
  if (!is.null(scan$blocked) && nrow(scan$blocked) > 0) return("blocked")
  "run"
}

#' 自动放行的那几条警告，给人看的一行说明
dsapp_agent_warn_labels <- function(scan) {
  if (is.null(scan$warnings) || nrow(scan$warnings) == 0) return(character(0))
  unique(sprintf("第 %d 行：%s", scan$warnings$line, scan$warnings$reason))
}

#' 组装回喂给模型的执行结果
#'
#' 头一行必须是【执行结果 · 任务 #N】—— 记住 llm.R 的 dsapp_build_context()
#' 会把 role:"tool" 降级成 "user"（不带 tool_call_id 的 role:tool 会被好几家
#' 厂商直接 400），所以"这是执行结果不是人在说话"完全靠这个头来传达。
#'
#' stdout/stderr 在这里**再截一次**，而且比执行层截得更狠：执行层留 512KB
#' 是为了让用户在任务页能翻完整日志，而模型这边 512KB ≈ 13 万 token，一次
#' 就顶爆上下文。模型需要的是报错的那几行，不是全部日志。
dsapp_agent_tool_text <- function(task_id, status, lang, exit_code = NA_integer_,
                                  secs = NA_real_, stdout = "", stderr = "",
                                  artifacts = character(0),
                                  artifact_sizes = NULL,
                                  env_notes = character(0),
                                  bad_artifacts = character(0),
                                  warnings = character(0),
                                  note = NULL,
                                  max_chars = 4000L) {
  status_txt <- switch(
    as.character(status),
    "success" = "成功",
    "failed"  = "失败（程序自己报错退出）",
    "timeout" = "超时被强制终止",
    "error"   = "未能执行（平台侧错误）",
    as.character(status))

  head <- sprintf("【执行结果 · 任务 #%s】", task_id)

  # ⚠️ 这里每一处都要判长度。`is.na(NULL)` 是 logical(0)，`if (logical(0))`
  #    直接报 "argument is of length zero" —— 而这个函数跑在循环里，一抛
  #    整个 agent 就静默停在那儿了。
  ok_num <- function(x) length(x) == 1 && !is.na(x)

  meta <- c(
    sprintf("状态：%s", status_txt),
    sprintf("语言：%s", lang),
    if (ok_num(exit_code)) sprintf("退出码：%d", as.integer(exit_code)),
    if (ok_num(secs)) sprintf("耗时：%.1f 秒", as.numeric(secs))
  )

  clip <- function(txt, label) {
    txt <- txt %||% ""
    if (!nzchar(trimws(txt))) return(sprintf("\n--- %s ---\n（空）", label))
    n <- nchar(txt)
    if (n > max_chars) {
      txt <- paste0(sprintf("（前 %d 个字符已省略）\n", n - max_chars),
                    substr(txt, n - max_chars + 1L, n))
    }
    sprintf("\n--- %s ---\n%s", label, txt)
  }

  # ★ V15.5 item 3：产物清单按**给人看 / 给机器看**分两栏。
  #
  #   用户原话：「整理完之后居然返给用户的是一份 json 文件，完全没有人类
  #   可读性」。原来这里不看后缀，一律写成「本次产出的文件」，于是模型照着
  #   这句话把 `step6_candidate_audit.json` 当成交付物汇报，页面也照着它
  #   渲染成可点预览的 chip —— 用户看到的"成果"就是一个 json。
  #
  #   判据在 executor.R 的 dsapp_artifact_is_human()（后缀白名单，只有它
  #   一处定义），理由和踩过的坑都写在那儿。
  #
  # ⚠️ 可交付那一栏的表头**必须**以「本次产出的文件」开头：render.R 的
  #    dsapp_sec_files() 按这个前缀取列表，改了前缀，那排 chip 会静默消失
  #    （不报错，就是"产物那一行不见了"）。
  art <- if (length(artifacts)) {
    sz <- if (is.null(artifact_sizes) || length(artifact_sizes) != length(artifacts)) {
      rep("", length(artifacts))
    } else {
      vapply(artifact_sizes, dsapp_fmt_bytes, character(1))
    }
    human <- dsapp_artifact_is_human(artifacts)
    rows  <- sprintf("- %s  %s", artifacts, sz)
    block <- function(label, keep) {
      if (!any(keep)) return("")
      sprintf("\n--- %s ---\n%s", label, paste(rows[keep], collapse = "\n"))
    }
    paste0(
      block("本次产出的文件（人类可读，可以直接交给用户）", human),
      block("本次运行过程中落盘的中间文件（不是给用户看的结论）", !human),
      # 全是中间产物时，光换标题**不够**：模型的默认行为是照着清单写
      # "本次产出：xxx.json"，换个标题它照样能把 json 说成交付物。必须把话
      # 挑明，并且指定替代动作（结论写进正文）。
      if (!any(human)) paste0(
        "\n⚠️ 这次**没有任何**人类可读的产物（没有报告 / 图片 / 表格），上面这些",
        "全是过程产物，**不是**给用户的结论。结论要写在你这一轮的回复正文里",
        "（中文，讲清拿到了什么、关键数字是多少）；只丢一个文件名不算交付。\n")
      else "")
  } else ""

  warn <- if (length(warnings)) {
    # ⚠️ 小节分隔行的规范形态是 `--- 标签 ---`（结尾那个 `---` 前面**有空格**）。
    #    这里原来是 `）---`（没空格），render.R 的小节切分按 `^--- .+ ---$`
    #    匹配不上 → 整条消息被解析成一整块，"平台提示"那一节在卡片上从来不
    #    显示。切分那边已经放宽成空格可选，这里补上空格是让它回归规范形态。
    sprintf("\n--- 平台提示（已自动放行） ---\n%s",
            paste(sprintf("- %s", warnings), collapse = "\n"))
  } else ""

  # ★ V13.12 item 8：产物体检。
  #
  #   用户原话：「"生成分析GLM测试"，这个任务生成出来的很多文件只有表头，
  #   看一下是哪里出了问题，需要架构优化的话请执行」。
  #
  #   判据在平台这边（executor.R 的 dsapp_artifact_check：0 字节 / 只有
  #   表头没有数据行 / 空 JSON），这里只负责**把它摆到模型眼前**，并且
  #   说清楚"这件事归你，不归用户"—— 和 item 12 同一条原则：
  #   代码类的、逻辑上的问题自己查自己修，别回头问用户。
  #
  #   ⚠️ 措辞里"不要汇报成结果"这句不能省。模型的默认行为是照着产物
  #      清单写总结，一份空表在它嘴里会变成"已完成 5 个队列的 TP53 表达
  #      分析"—— 用户就是这么被坑的。
  # ★ V15.5 item 12：这一节现在装**两类**问题，措辞不能再假定"都是空表"。
  #   第二类是图上画成方框的字（判据在 executor.R 的 dsapp_font_glyph_check：
  #   matplotlib 往 stderr 打的那行 missing from current font）。合成一段
  #   而不是新开一节，是因为下面那条"摆到模型眼前"的链路只有一个入口。
  art_bad <- if (length(bad_artifacts)) {
    # ⚠️ 判据要和 dsapp_font_glyph_check 写出来的那句话对齐。**别**写成
    #    `missing from current font`：那是 matplotlib 3.8 及以前的措辞，
    #    3.11 打的是 `missing from font(s) DejaVu Sans.` —— 这台机器上是后者，
    #    照旧写法判永远为假，模型会拿到"文件里没有数据"那套解释去查一个
    #    根本不存在的空表问题。
    font_bad <- any(grepl("方框", bad_artifacts, fixed = TRUE) |
                    grepl("missing from font", bad_artifacts, fixed = TRUE))
    sprintf(paste0(
      "\n--- 产出有问题（平台体检，下面这些**不能当作结果交出去**） ---\n%s\n",
      if (font_bad) paste0(
        "上面第一类（如果有）是**文件里没有数据**：平台照常收下了，但里面是空的。\n",
        "带 ⚠️ 的那条是**图里有字没画出来**：那些字在图上是一个个空心方框，\n",
        "用户拿到手里就是一张废图（英文和数字是好的，所以粗看还挺正常）。\n",
        "原因只有一个：画图时用的字体**没有中文字形**。按【运行环境】→\n",
        "「中文字体」那一节列出的字体文件重新指定字体、重画这张图 ——\n",
        "**不要**改成英文标签了事，用户要的就是中文图。\n")
      else
        "上面这些文件平台照常收下了，但**里面没有数据**，不能当作分析结果。\n",
      "请自己查清楚是哪一种，然后修好重跑，**不要**问用户怎么处理：\n",
      "  · 上游接口对这套参数返回了空（比如分子谱不存在、样本被过滤光）——\n",
      "    换一个能取到数据的研究/参数，或者在代码里显式判空后跳过它；\n",
      "  · 脚本自己的过滤条件写得太紧，把数据全筛掉了 —— 回头核对筛选逻辑。\n",
      "⚠️ 在修好之前，**不要**在回复里把这些文件说成「已完成」「结果如下」；\n",
      "   已经写进报告里的结论，也要回头改掉。"),
      paste(bad_artifacts, collapse = "\n"))
  } else ""

  tail_txt <- if (!is.null(note) && nzchar(note)) sprintf("\n备注：%s", note) else ""

  # 报错在前、结果在后：模型该先读 stderr。
  #
  # 但**任务成功且 stderr 为空时不印那一节**。印一个"（空）"再标上
  # "报错在这里，先读它"，是让模型去读空气 —— 这一段会原样进上下文，
  # 每一轮都占位置（实测第一次跑通时回喂的头四行就是这个）。
  # 失败时即使 stderr 为空也留着："平台没有给出任何报错"本身是信息。
  # ★ V13.12 item 4：成功时把 stderr 里的**警告**摘掉，别喂给模型。
  #
  #   用户原话是「分析过程中的 warring 和报错没有必要返回给用户」。这里
  #   挡的是**第二条**到达用户的路径：就算界面上收起来了（render.R 那边），
  #   模型自己在 tool 消息里读到那两行 warning，下一轮回复里照样会写一句
  #   "运行中有 2 条警告，但不影响结果" —— 用户看到的还是它。
  #
  #   ⚠️ **只在成功时摘**。失败时的 stderr 是模型唯一的线索，"NAs introduced
  #      by coercion" 这类警告经常正是结果不对的原因，摘掉它等于让模型瞎修。
  #     失败时由 render.R 那侧对**用户**收起来，模型这一侧一个字都不动。
  is_bad <- !identical(as.character(status), "success")
  n_warn <- 0L
  if (!is_bad && nzchar(trimws(stderr %||% ""))) {
    sp_st <- tryCatch(dsapp_stderr_split(stderr, failed = FALSE),
                      error = function(e) list(keep = stderr, noise = "",
                                               n_noise = 0L))
    if (nzchar(trimws(sp_st$noise %||% ""))) {
      stderr <- sp_st$keep %||% ""
      n_warn <- as.integer(sp_st$n_noise %||% 0L)
    }
  }

  # ★ V13.12 item 4：摘掉警告之后得说一声，否则模型会以为"这次干净得很"，
  #   下次真出问题时反而拿这个当基准。⚠️ 同时把"别提"写进去 —— 不写的话
  #   它会出于礼貌汇报一句"有警告但已忽略"，那句话就是用户不该看见的东西。
  warn_note <- if (n_warn > 0L) {
    sprintf(paste0("\n（这次执行有 %d 条 R/Python 警告，已经被平台收走 —— ",
                   "它们不影响结果，**不要**在回复里提起，也不要问用户怎么处理。）"),
            n_warn)
  } else ""

  has_err <- nzchar(trimws(stderr %||% ""))

  # V11 item 8：失败时先判一次"这锅该谁背"。
  #
  # ⚠️ 判完要**写进这条消息本身**，不能只在调用方分岔。这条消息有两个读者
  #    （模型和用户），也有两个来源（agent 循环的 feed_result、手动执行的
  #    dsapp_write_run_msg），在调用方各写一遍必然漏一个 —— 而漏掉的那条路
  #    表现是"环境问题又被贴回给用户了"，跟没做一样。
  envfix <- if (is_bad) {
    tryCatch(dsapp_env_failure(stderr = stderr, status = status),
             error = function(e) list(is_env = FALSE))
  } else list(is_env = FALSE)
  env_txt <- tryCatch(dsapp_env_fix_hint(envfix), error = function(e) "")

  paste0(head, "\n",
         paste(meta, collapse = "\n"),
         if (has_err || is_bad) clip(stderr, "stderr（报错在这里，先读它）") else "",
         env_txt,
         clip(stdout, "stdout（末尾）"),
         # ⚠️ art_bad 紧跟在产物清单后面：模型读清单的下一眼就是"这里面
         #    哪些是空的"。放到最后会被 clip 出来的 stdout 挤到看不见的地方。
         art, art_bad, warn, tail_txt, warn_note)
}

#' 轮次用满时喂给模型的"最后一次机会"（★ V15.5 item 3）
#'
#' 用户报的那次（会话 s-20260930130349-4988，7 个任务撞上上限 6 轮）最后一条
#' 是**工具卡片**：模型从头到尾没看到最后一个任务的结果，也就没给出结论 ——
#' 用户拿到的"交付物"是卡片底下那排文件名。
#'
#' 光再多喂一轮还不够，得把这一轮的性质说清楚，否则它会当成普通一轮继续写
#' 代码（而那一轮平台**不会**执行任何东西，见 on_llm_done 里的 a$final 分支）。
#'
#' ⚠️ 里面必须点名"结论写进正文"和"不要把中间文件当交付"。这两句是用户报的
#'    那个问题的正面要求 —— 第 ① 条（产物分栏）只改了清单的说法，模型仍可能
#'    只回一句"已完成，产物见上"。话要说到它该怎么交。
#'
#' @param max_iter 这次用的轮数上限（和界面上那个滑块同源）
dsapp_agent_last_chance_text <- function(max_iter) {
  sprintf(paste0(
    "【平台提示 · 最后一次收尾机会】\n",
    "自动执行已经用满了这次给的轮数（%d 轮），平台**不会再执行任何代码**了。\n",
    "请**只用文字**把这次分析交代清楚，把结论写在这条回复的正文里：\n",
    "  · 做到了哪一步、结果是什么（关键数字、结论都写在正文里，不要只给文件名）；\n",
    "  · 已经落盘的文件里，哪些是给人看的交付物（报告 / 图 / 表）、",
    "哪些只是中间数据（json / rds / tsv 这类）；\n",
    "  · 哪些没做完、卡在哪儿、下一步建议怎么做。\n",
    "**不要**再给可执行代码块 —— 给了也不会被执行，用户只会看到一个跑不动的按钮。\n",
    "如果结论还没成型，就如实说清\"目前只走到哪一步\"，",
    "这比补一段没验证过的结论好。"),
    as.integer(max_iter))
}

#' 这一趟的产出**全是机器可读文件**时，写给用户的那条平台提示
#'
#' ★ V15.5 item 3 的第 ④ 条。前面三条管的是"模型怎么称呼这些文件"，这一条
#' 管的是**用户有没有被明确告知**：清单换了措辞，可用户看到的仍然是一排
#' 文件名和第 ① 条之后不再标注的 chip，没人跟他说"这次没有能看的东西"。
#'
#' ⚠️ 写进**对话**（hooks$add_msg），不是弹通知。弹窗关掉就没了，而这件事
#'    要在用户回头翻这段对话时还看得见 —— 他是拿这段对话当记录用的。
#'
#' @param files 这一趟自动执行里落盘的产物名
#' @return 要写进对话的文本；没有文件、或里面有可交付物时返回 ""（不打扰）
dsapp_agent_delivery_note <- function(files) {
  files <- as.character(files %||% character(0))
  files <- unique(files[!is.na(files) & nzchar(files)])
  # 有**任何一个**人类可读的产物就不吭声。这条提示是"什么都没交付"的兜底，
  # 不是每次收尾都要念一遍的通报 —— 天天念的话用户会连真问题一起忽略。
  if (!length(files) || any(dsapp_artifact_is_human(files))) return("")
  sprintf(paste0(
    "【平台提示 · 这一趟没有人类可读的交付物】\n",
    "本次自动执行落盘的 %d 个文件都是机器可读的中间产物，平台没有从中看到\n",
    "能直接给用户看的东西（没有报告 / 图片 / 表格）：\n%s\n",
    "分析结论应该在上面那条回复的正文里。想要一份能直接看的交付物，\n",
    "可以点上面那颗「总结并生成报告」，它会生成 markdown / HTML / Word 报告；\n",
    "或者直接说一句\"把结论整理成一份报告\"。"),
    length(files),
    paste(sprintf("  - %s", utils::head(files, 20L)), collapse = "\n"))
}


#' 把一个任务的结果拼成"可以写进对话的那条消息"
#'
#' V11 item 8：从 mod_chat 的 dsapp_write_run_msg() 里提出来的。原来只有
#' 对话页那个模块会写执行结果，于是**从「历史任务」页点重跑**出来的那一次，
#' 结果只落在任务列表里，而它所属的那条对话一个字都没有 —— 用户的原话是
#' 「实际的成功输出与失败输出都应该在言出法随界面给到用户」，重跑也是他
#' 自己发起的一次执行，没道理例外。
#'
#' @return 拼好的文本；任务行不在（被删了）时返回 NULL。
dsapp_task_result_text <- function(tid, cfg = dsapp_config(), lang = NULL) {
  if (is.null(tid)) return(NULL)
  row <- tryCatch(db_task_get(tid, con = dsapp_db(cfg)), error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(NULL)

  sid <- as.character(row$session_id %||% "")

  secs <- tryCatch({
    st <- as.character(row$started_at %||% "")
    fi <- as.character(row$finished_at %||% "")
    if (nzchar(st) && nzchar(fi)) {
      as.numeric(difftime(as.POSIXct(fi, tz = "UTC"),
                          as.POSIXct(st, tz = "UTC"), units = "secs"))
    } else NA_real_
  }, error = function(e) NA_real_)

  # 产物从 task_files 读（一次查询），不扫盘 —— 归属是引擎在收尾时写好的
  # （app.R 的 db_task_files_set），比现场扫更准也更便宜。
  files <- tryCatch({
    m <- db_task_files_map(sid, con = dsapp_db(cfg))
    m$name[m$task_id == tid]
  }, error = function(e) character(0))

  dsapp_agent_tool_text(
    task_id = tid,
    status = as.character(row$status %||% "?"),
    lang = as.character(row$lang %||% lang %||% "?"),
    exit_code = suppressWarnings(as.integer(row$exit_code)),
    secs = secs,
    stdout = row$stdout %||% "",
    stderr = row$stderr %||% "",
    artifacts = utils::head(files, 40),
    # ★ V13.12 item 8：这条路是「历史任务」页点重跑回来的。任务行里没有
    # 存体检结果（那是执行收尾时的现场结论，且要读文件才拿得到），所以
    # 在这里按工作区**重跑一遍**体检 —— 重跑也是用户发起的一次执行，
    # 没道理只在对话页那条路上拦住空产物。
    # ★ V15.5 item 12：改走 dsapp_bad_artifacts()（唯一入口）—— 原来这里只
    #   调 dsapp_artifact_check()，于是"图里画成了方框"那条结论在这条路上
    #   根本不存在。stderr 就在这一行里（row$stderr），不查白不查。
    bad_artifacts = dsapp_bad_artifacts(utils::head(files, 40),
                                        row$workdir %||% NA_character_,
                                        row$stderr %||% ""))
}

#' 同上，但直接写进对话
#'
#' @return TRUE / FALSE（写没写成）。**不弹通知** —— 通知长什么样由调用方
#'   决定，这个函数在后台轮询里也会被调到，那里弹通知会刷屏。
dsapp_task_result_write <- function(tid, sid, cfg = dsapp_config(), lang = NULL) {
  if (is.null(sid) || is.null(tid)) return(invisible(FALSE))
  txt <- dsapp_task_result_text(tid, cfg = cfg, lang = lang)
  if (is.null(txt)) return(invisible(FALSE))
  ok <- tryCatch({
    db_message_add(sid, "tool", txt, con = dsapp_db(cfg))
    TRUE
  }, error = function(e) FALSE)
  invisible(ok)
}


# =============================================================================
# 状态机
# =============================================================================

#' 建一个 agent 循环
#'
#' 放**模块内部**（在 mod_chat_server 里实例化），不放 app.R：贴着 engine
#' 容易被后来的人提升成全局对象，那样两个用户共用一台状态机，工具结果会
#' 串到别人的对话里。也不单开一个 mod_agent_server —— 那要把 state / rv /
#' hist_ver 全跨模块边界传，还会和 mod_chat 抢 rv$streaming（那个值驱动
#' 发送按钮的忙闲）。代码放这个文件，mod_chat 只留开关、状态条、停止。
#'
#' @param hooks 由 mod_chat 提供的回调：
#'   get_sid()            → 当前对话 id（可能为 NULL）
#'   get_target()         → 本次执行的目标（server/remote/local）
#'   begin_llm(scene)     → 用给定场景拼上下文并开始新一轮生成
#'   add_msg(role, text)  → 写一条消息（已包 tryCatch）
#'   running()            → 界面是否正忙（LLM 流式中）；循环要等它让位
#'   refresh()            → 通知界面刷新（历史、状态条）
#' @param heart 要不要注册那个每秒一次的心跳 observe。**默认要**（会话里
#'   就是这样用的）。R/detach.R 的脱离会话续跑传 FALSE —— 它跑在一个没有
#'   Shiny 会话的子进程里，自己用 `a$tick()` 推循环。
#' @param wall_limit 自动结束时间：这一次自动执行的**总时长上限**（秒）。
#'   ★ V13.17 item 31 之前这里是写死的 7200，现在由界面上的滑块给
#'   （`R/mod_chat.R` 的 `input$agent_wall`）。默认值仍是 7200，所以不传
#'   参数的调用方行为和以前**逐字相同**。
dsapp_agent_new <- function(state, engine, session, ns, cfg, hooks,
                            max_iter = DSAPP_AGENT_MAX_ITER,
                            wall_limit = DSAPP_AGENT_WALL_DEF,
                            fix_max = DSAPP_AGENT_AUTOFIX_UNLIM,
                            heart = TRUE) {
  a <- new.env(parent = emptyenv())

  a$max_iter <- dsapp_iter_value(max_iter)
  # ⚠️ 走 dsapp_wall_value() 而不是 as.numeric()：滑块的值在几种情况下会
  #    是空向量（见 utils.R 那段注释），as.numeric(integer(0)) 得到
  #    numeric(0)，存进去之后 `x > a$wall_limit` 求值成 logical(0)，
  #    `if (logical(0))` 抛错 —— 报错点在下一次心跳里，离这里很远。
  a$wall_limit <- dsapp_wall_value(wall_limit)

  # 开关。**默认关闭** —— 自动执行是有代价的（会自己跑代码、花 token），
  # 必须由用户明确打开，不能因为"这样更智能"就默认替人做主。
  a$enabled <- FALSE

  # ★ V13.5 item 1：出错之后由 AI 自己接手。**默认开着。**
  #
  # ⚠️ 它和上面那个 a$enabled 是**两件事**，不要合并成一个开关：
  #
  #      a$enabled —— 每一轮都自动往下跑（没出错也跑、用户没要求也跑）
  #      a$autofix —— **只在任务失败之后**把模型叫起来查这一次的报错
  #
  #   前者默认关是对的（那是"花我的钱"的授权），后者默认开也是对的 ——
  #   用户的原话就是「报错需要AI自己解决，而不是用户自己确认」。
  #
  #   为什么这条默认值这么重要：V11 item 8 其实已经把"识别"那半边做完了
  #   （envfix.R 认得出这是环境问题、锅该谁背，dsapp_env_fix_hint 也写好了
  #   给模型看的话），但叫醒模型那一步被 a$enabled 挡着，而它默认是关的。
  #   于是"让 AI 自动调试"这条路**从来没通过**：用户看到报错，界面上什么
  #   都不会发生，只能自己点确认、自己猜。这就是这一版要修的东西。
  a$autofix <- TRUE

  # 自动接手的时刻表（滑动窗口，见 config.R 里那两条常量）。空 = 本会话还
  # 没自动接手过。**不是计数器**：计数器需要一个"什么时候归零"的定义，
  # 而这里没有那样的时刻（理由写在 config.R 里）。
  a$fix_times <- numeric(0)

  # ★★ V16.2 item 1：这道闸的次数上限，**默认就是不设上限**。
  #
  #   用户原话：「出错自动修也要默认没上限」。所以默认值是哨兵 0
  #   （DSAPP_AGENT_AUTOFIX_UNLIM），不是 DSAPP_AGENT_AUTOFIX_MAX。
  #
  #   ⚠️ 上面那个 a$fix_times 仍然要记（哪怕不设上限）—— 它是状态条和
  #      审计日志里"已经自动排查过几次"的来源，**不是**只有闸才用。
  #      不设上限时它只增不减，这没关系：它只是个时刻表，不是计数器。
  #
  #   ⚠️ 它在 agent 对象上，不在常量里：用户在界面上改一下就要**当场**
  #      生效（和 a$wall_limit / a$max_iter 同一个形状 —— 循环正跑着改，
  #      下一轮判断立刻按新值走）。写成读常量的话，用户改完要等下一次
  #      换代才生效，而界面上那个勾已经是新的了。
  a$fix_max <- dsapp_fix_max_value(fix_max)

  # 这一次生成是不是"自动接手"起来的（见 a$can_loop）。
  #
  # ⚠️ 它必须**每轮复位**。它一旦粘住，用户在纯聊天模式下发一句话就会掉进
  #    自动循环里 —— 关着的开关形同虚设，而且用户看不出为什么模型突然开始
  #    自己跑代码。复位点有两处：a$finish()（这段循环结束）和
  #    on_llm_done() 里用户新开一轮的那一支。
  a$armed <- FALSE

  a$state <- "idle"       # idle / generating / want_run / waiting / awaiting_user
  a$iter <- 0L
  a$sid <- NULL           # ⚠️ 起手抄下来，之后绝不读 rv$session_id
  a$t0 <- NULL
  a$task_id <- NULL
  a$pending <- NULL       # 等待用户确认的那个块
  a$pending_mid <- NULL   # 它来自哪条助手消息（终止时要释放认领）
  a$retry_until <- NULL   # want_run 的重试截止时间
  a$note <- ""            # 给状态条显示的一句话
  a$last_key <- NULL      # 上一条已被取走的助手消息 id
  # 这两个要有初值。R 的环境取不存在的字段给的是 NULL，而 NULL 传进
  # dsapp_agent_tool_text() 会在 `if (is.na(x))` 那里炸成 "argument is of
  # length zero" —— 循环挂掉且不留痕迹。
  a$warn_note <- character(0)   # 本次自动放行的警告
  a$last_secs <- NA_real_       # 本次执行的耗时
  # ★ V15.5 item 3：这两个也要有初值。
  #   a$final —— 轮到收尾轮了吗（轮次用满时置上，见 feed_result）。它决定
  #              on_llm_done 是不是"这一轮只许收尾、代码不执行"。
  #   a$prod  —— 这一趟自动执行落盘的产物名（feed_result 每轮追加，见
  #              a$deliver_note）。初值给 character(0) 而不是留空：判断用的是
  #              length()，NULL 进去长度是 0 也能过，但 `c(NULL, x)` 那种
  #              半路拼接更容易在别处写错，不如一开始就是个正经的空向量。
  a$final <- FALSE
  a$prod  <- character(0)

  a$active <- function() !identical(a$state, "idle")

  #' 这一次生成，循环**允不允许**接着往下走（★ V13.5 item 1）
  #'
  #' 调用方是 mod_chat.R 流式结束那一段（它原来写的是裸的
  #' `isTRUE(st$agent$enabled)`）和 on_llm_done 自己的第一行。
  #'
  #' ⚠️ 两处必须**问同一句话**。只改其中一处的话，症状是"自动接手起了个头
  #    就没有下文"：模型被叫起来、生成了一轮，然后 on_llm_done 在第一行
  #    被 enabled 挡回去，那一轮的结论就直接变成一条普通聊天消息，没人
  #    照着它去改代码。看起来像"模型查了半天什么也没做"。
  a$can_loop <- function() isTRUE(a$enabled) || isTRUE(a$armed)

  a$status <- function() {
    # ★ V13.17 item 31：把 wall_limit 也报出去。改它的人是**别人**
    #   （mod_chat 里那个观察 input$agent_wall 的 observe），状态条只是读 ——
    #   不放在这里的话，那两个数字就只活在输入控件里，后台续跑那一份
    #   （detach.R，没有界面）读不到，而它恰恰是最需要知道"还能跑多久"的。
    list(state = a$state, iter = a$iter, max_iter = a$max_iter,
         wall_limit = a$wall_limit, note = a$note)
  }

  # ---- 收尾 ----------------------------------------------------------------

  a$finish <- function(note = "", keep_sid = FALSE) {
    a$state <- "idle"
    a$note <- note
    a$task_id <- NULL
    a$pending <- NULL
    a$pending_mid <- NULL
    a$retry_until <- NULL
    a$t0 <- NULL
    a$iter <- 0L
    # ★ V13.5 item 1：这一段循环结束了，"自动接手"这次授权跟着作废。
    #   不清的话，用户下一句普通聊天也会掉进循环里（见 a$armed 的说明）。
    a$armed <- FALSE
    # ★ V15.5 item 3：收尾轮的一次性开关和这一趟的产物清单也是"这一段循环
    #   的东西"，跟着一起清。留着的话，下一段循环会拿上一段的产物去判
    #   "这一趟交付了什么"（见 a$deliver_note）。
    a$final <- FALSE
    a$prod  <- character(0)
    if (!keep_sid) a$sid <- NULL
    hooks$refresh()
    invisible(TRUE)
  }

  #' 循环正常收尾：这一趟的产出里一个"给人看的"都没有时，写一条平台提示
  #'
  #' ★ V15.5 item 3 第 ④ 条。
  #'
  #' 用户报的那次（会话 s-20260930130349-4988）：跑完 7 个任务，工作区里是
  #' 一堆 json/rds，模型最后一条是一段 python 代码块。前面三条改动管的是
  #' "清单怎么说"，这一条管的是**用户有没有被明确告知** —— 只换措辞的话，
  #' 用户看到的仍然是一排文件名，没人跟他说"这次没有能看的东西"。
  #'
  #' ⚠️ 写进**对话**（hooks$add_msg），不是弹通知：弹窗关掉就没了，而这件事
  #'    要在他回头翻这段对话时还看得见 —— 这段对话是他的记录。
  #' ⚠️ 调点一共四个，全都是"循环到此为止"：模型给出结论、收尾轮结束、
  #'    两个时间闸出口（回喂那一支 / 生成结束那一支）。时间闸**也要**发：
  #'    挂机跑很久被叫停的那一趟，用户手里最可能只有一堆 json。
  #' ⚠️ 用户点停止那一路**不**发：那是他主动打断，他知道自己在干什么，
  #'    这时候念一句"没有人类可读的交付物"是往打断上再补一刀。
  #' ⚠️ 这句说的是**事实**（这一趟没有给人看的产物），不是结论 —— 所以它
  #'    在任何一种"这一趟结束了"的场合都成立，弹不出错误的话。
  a$deliver_note <- function() {
    txt <- tryCatch(dsapp_agent_delivery_note(a$prod),
                    error = function(e) "")
    if (!nzchar(txt)) return(invisible(FALSE))
    hooks$add_msg("tool", txt)
    invisible(TRUE)
  }

  #' 停止循环
  #'
  #' 只停循环**本身**，不碰引擎 —— 引擎是全局单槽的，这个对话停的时候
  #' 可能正有别人的任务在跑，顺手 abort 会把别人的任务杀掉。
  #' 需要连任务一起停的场合（用户点停止、删对话）由调用方显式调
  #' engine$abort()，见 mod_chat.R。
  a$stop <- function(note = "已停止") {
    if (!a$active()) return(invisible(FALSE))
    a$finish(note)
  }

  # ---- 提交执行 ------------------------------------------------------------

  #' 把块交给引擎
  #'
  #' 引擎是单槽无队列的（app.R 的 e$start：忙就直接拒）。循环遇到忙不能
  #' 当场失败，也不能无限重试 —— 那种情况下用户看到的是一个永远转圈的
  #' 状态条。这里给一个有上限的重试窗口，超时就如实回喂一条"平台正忙"，
  #' 然后照样走回喂流程（模型可以据此决定重发还是先给结论）。
  a$try_submit <- function() {
    blk <- a$pending
    if (is.null(blk)) { a$finish("没有待执行的代码块"); return(invisible(FALSE)) }

    target <- hooks$get_target()
    if (identical(target$kind, "local")) {
      # ⚠️ 这句里**没有**占位符，就不要再塞参数：`sprintf(fmt, blk$lang)` 会
      #    报 "one argument not used by format"，字符串本身照旧能拼出来，所以
      #    界面上一切正常，只有日志里每次多一条 Warning。
      hooks$add_msg("tool", paste0(
        "【执行结果 · 未执行】\n本对话选的是「本地电脑」模式，代码不在服务器上跑，",
        "自动执行循环无法继续。请把脚本给用户，让他用代码卡片的「打包下载」带走。"))
      a$pending <- NULL
      a$pending_mid <- NULL
      a$state <- "generating"
      hooks$begin_llm("agent")
      return(invisible(TRUE))
    }

    res <- tryCatch(
      engine$start(blk$code, blk$lang,
                   # 标题由引擎自动起（V9 item 7），这里不传
                   session_id = a$sid, target = target,
                   # 配额要在 agent 循环里也生效 —— 循环是**无人值守**的，
                   # 一个跑飞的循环比手点执行更容易把磁盘写满。
                   user_id = state$user_id),
      error = function(e) list(ok = FALSE, msg = conditionMessage(e)))

    if (isTRUE(res$ok)) {
      a$task_id <- res$task_id
      a$pending <- NULL
      a$pending_mid <- NULL
      a$retry_until <- NULL
      a$state <- "waiting"
      a$note <- sprintf("任务 #%d 执行中", res$task_id)
      hooks$refresh()
      return(invisible(TRUE))
    }

    # 忙 → 等一会儿再试；其它错误（环境不存在、目标不成立）当场回喂，
    # 重试一万次也是同一个结果。
    if (grepl("正在执行", res$msg %||% "")) {
      if (is.null(a$retry_until)) {
        a$retry_until <- Sys.time() + 60
        a$note <- "平台正忙，等待执行槽位…"
        hooks$refresh()
        return(invisible(FALSE))
      }
      if (Sys.time() < a$retry_until) return(invisible(FALSE))
    }

    # V11 item 8：提交期就被挡下来，也要分清是"环境问题"还是"代码/平台问题"。
    #
    # 原来这里只有一句「如果这是环境配置问题，直接告诉用户需要怎么处理」——
    # 正好和用户要的相反：环境问题是平台自己的事，用户既看不懂也管不着。
    # 现在按判定的 kind 给两套话（沿用 dsapp_env_fix_hint 的口径，见 envfix.R）。
    pf <- tryCatch(dsapp_env_failure(msg = res$msg %||% "", status = NULL),
                   error = function(e) list(is_env = FALSE))
    # ★ V13.10 item 4：`self_fix` 也走 hint —— 提交期被挡下来的语法错误
    #   （比如扫描器或引擎回的是 SyntaxError）就是这种。判据用
    #   `dsapp_env_fix_hint()` 的返回值而不是在这里再写一遍 if：hint 自己
    #   认得全三种情况，"再写一遍"迟早和它分叉。
    pf_hint <- tryCatch(dsapp_env_fix_hint(pf), error = function(e) "")
    detail <- if (nzchar(pf_hint)) {
      paste0(sprintf("【执行结果 · 未执行】\n平台没能提交这段 %s 代码：%s\n",
                     blk$lang, res$msg %||% "未知原因"),
             pf_hint)
    } else {
      sprintf(
        "【执行结果 · 未执行】\n平台没能提交这段 %s 代码：%s\n\
请先不要重发同一段代码。这不是环境问题 —— 先看清平台给的理由，\
能改就改（比如把代码拆小、去掉被拦的那部分），改不了就如实向用户说明。",
        blk$lang, res$msg %||% "未知原因")
    }
    hooks$add_msg("tool", detail)
    a$pending <- NULL
    a$pending_mid <- NULL
    a$retry_until <- NULL
    a$state <- "generating"
    hooks$begin_llm("agent")
    invisible(TRUE)
  }

  # ---- 等任务结束 ----------------------------------------------------------

  #' 任务是否已经结束；结束了就把结果组装出来回喂
  #'
  #' ⚠️ 读 db_task_get()，**不读 engine$poll()**。engine$poll() 是一次性
  #'    终结器（app.R：先到先做，e$handle 置空），app.R 那个 observer 先到
  #'    就先收尾并把 handle 置空，第二个调用者拿到 NULL —— 那和"还在跑"
  #'    在返回值上无法区分。
  #'
  #' 停止条件是三选一，缺一不可：
  #'   1. DB 状态是终结态
  #'   2. 或这一行没了（用户中途把任务删了）
  #'   3. 或引擎已经不再持有这个 task_id（被 e$abort() 掐了）
  #' 少了第 3 条，用户点停止之后循环会一直等一个永远不会变成终结态的
  #' 条件 —— 因为 abort 是杀进程 + 复位内存，不一定回写数据库。
  a$check_task <- function() {
    tid <- a$task_id
    if (is.null(tid)) return(invisible(FALSE))

    row <- tryCatch(db_task_get(tid, con = dsapp_db(cfg)), error = function(e) NULL)
    held <- tryCatch(engine$current_task_id(), error = function(e) NULL)

    if (is.null(row)) {
      return(a$feed_result(NULL, tid, note = "任务记录已被删除（用户可能在任务页删掉了它）"))
    }

    st <- as.character(row$status)
    if (!st %in% c("success", "failed", "error", "timeout")) {
      # 还握着就继续等；不握了说明被中止了
      if (!identical(held, tid)) {
        return(a$feed_result(row, tid, note = "这个任务已被中止（用户点了停止，或应用重启过）"))
      }
      return(invisible(FALSE))
    }

    a$feed_result(row, tid)
  }

  #' 把一次执行的结果写成 tool 消息，然后继续下一轮
  a$feed_result <- function(row, tid, note = NULL) {
    a$task_id <- NULL

    if (is.null(row)) {
      txt <- sprintf("【执行结果 · 任务 #%d】\n状态：未能取到结果\n备注：%s",
                     tid, note %||% "任务记录不存在")
    } else {
      arts <- tryCatch(dsapp_ws_artifacts(a$sid, cfg), error = function(e) NULL)
      # ★ V13.12 item 8：产物体检。查的是**这次任务产出的**那几个文件
      #   （task_files 里带 task_id 的行，执行收尾时写好的），不是整个
      #   工作区 —— 工作区是持久的，拿全量去查会把历史上那些空文件
      #   每次重报一遍。见 executor.R 的 dsapp_artifact_check()。
      # ★ V15.5 item 12：这里原来只调 dsapp_artifact_check()，"图里的字画成
      #   方框"那条结论永远不会出现在**模型看得见的那段文本**里（收尾函数
      #   算过一遍，但它的返回值没人接）。改走唯一入口 dsapp_bad_artifacts()，
      #   方框判据读的就是这一行的 stderr。
      bad_art <- tryCatch({
        m <- db_task_files_map(a$sid, con = dsapp_db(cfg))
        dsapp_bad_artifacts(m$name[m$task_id == tid],
                            dsapp_ws_dir(a$sid, cfg, create = FALSE),
                            row$stderr %||% "")
      }, error = function(e) character(0))
      # ★ V15.5 item 3 第 ④ 条：记下**这次任务**产出的文件名，收尾时据此判断
      #   "这一趟有没有能给人看的东西"。
      #   ⚠️ 用上面同一份 m（task_files 里带这个 task_id 的行），不要用
      #      arts（那是整个工作区的快照，会把上一轮、上十轮的产物都算进来）——
      #      判"这一趟交付了什么"必须只看这一趟。
      #   ⚠️ 单独包一层 tryCatch：库读不到时宁可没有这条提示，也不能让
      #      回喂流程挂在半路（循环里抛异常 = 静默停住，见文件顶部）。
      tryCatch({
        m2 <- db_task_files_map(a$sid, con = dsapp_db(cfg))
        a$prod <- unique(c(a$prod, m2$name[m2$task_id == tid]))
      }, error = function(e) NULL)
      # 耗时从任务行的 started_at / finished_at 算，不用内存里的计时 ——
      # 循环可能在应用重启后才看到这一行，那时候内存里什么都没有。
      secs <- tryCatch({
        if (nzchar(row$started_at %||% "") && nzchar(row$finished_at %||% "")) {
          as.numeric(difftime(as.POSIXct(row$finished_at, tz = "UTC"),
                              as.POSIXct(row$started_at, tz = "UTC"),
                              units = "secs"))
        } else NA_real_
      }, error = function(e) NA_real_)

      txt <- dsapp_agent_tool_text(
        task_id = tid,
        status = as.character(row$status),
        lang = as.character(row$lang %||% "?"),
        exit_code = suppressWarnings(as.integer(row$exit_code)),
        secs = secs,
        stdout = row$stdout %||% "",
        stderr = row$stderr %||% "",
        artifacts = if (is.null(arts)) character(0) else utils::head(arts$name, 40),
        artifact_sizes = if (is.null(arts)) NULL else utils::head(arts$size, 40),
        bad_artifacts = bad_art,
        warnings = a$warn_note %||% character(0),
        note = note)
    }
    a$warn_note <- character(0)
    a$last_secs <- NA_real_
    a$note <- sprintf("任务 #%d 已结束，正在分析结果…", tid)
    hooks$add_msg("tool", txt)

    # ★ V15.5 item 3：撞上限时**不能再直接收尾**，要给模型最后一次发言机会。
    #
    #   用户报的那次（会话 s-20260930130349-4988）正是撞在这里：7 个任务、
    #   上限 6 轮，这条回喂写完循环就结束了 —— 模型**从头到尾没看到最后一个
    #   任务的结果**，对话停在一条工具卡片上，用户拿到的"结论"就是卡片底下
    #   那排文件名。钱一样花，差的只是最后那一次发言。
    #
    #   ⚠️ 终止性靠 a$final 这个一次性开关，**不靠模型听不听话**：
    #      收尾轮无论它交回来什么（文字 / 代码块 / 半截代码），on_llm_done
    #      进门第一件事就是看见 a$final 并收尾 —— 那一轮不执行任何东西，
    #      所以"它又写了一个块"不可能把上限撑开。见下面 on_llm_done 里那一支。
    #   ⚠️ 时间闸现在排在轮次闸**前面**：撞了时间闸还再起一轮生成（几秒到
    #      几十秒），和"到点就停"的语义相反。两个闸同时到点时，说法从
    #      "已达轮次上限"变成"时间到了"，这句才是用户该看到的那一个。
    if (!is.null(a$t0) &&
        as.numeric(difftime(Sys.time(), a$t0, units = "secs")) > a$wall_limit) {
      # ★ V15.5 item 3 第 ④ 条：时间闸这一支同样是"循环结束了"，交付提示
      #   一视同仁 —— 挂机两小时被时间闸叫停的那一趟，用户手里可能也只有
      #   一堆 json，他更需要有人告诉他没有能看的东西。
      a$deliver_note()
      return(a$finish(dsapp_agent_wall_note(a$wall_limit)))
    }
    if (a$iter >= a$max_iter) {
      a$final <- TRUE
      hooks$add_msg("tool", dsapp_agent_last_chance_text(a$max_iter))
      a$state <- "generating"
      a$note <- "轮次已用满，正在让模型给出收尾结论…"
      hooks$refresh()
      hooks$begin_llm("agent")
      return(invisible(TRUE))
    }

    a$state <- "generating"
    hooks$refresh()
    hooks$begin_llm("agent")
    invisible(TRUE)
  }

  # ---- 主入口：一轮生成结束 ------------------------------------------------

  #' 生成结束时调用
  #'
  #' @param text 助手这一轮的完整回复
  #' @param finish_reason LLM 的结束原因（"length" = 被截断）
  #' @param message_id 这条助手消息在库里的 id（用来去重）
  #' @param cut_off 流被中途掐断（见 llm.R 的 complete）
  a$on_llm_done <- function(text, finish_reason = NULL, message_id = NULL,
                            cut_off = FALSE) {
    # ★ V13.5 item 1：问 can_loop()，不是 enabled。自动接手起来的那一轮
    #   armed = TRUE、enabled 仍然是 FALSE，用 enabled 判会让它在这里被
    #   挡回去 —— 模型查完了却没人照它说的去改，等于白叫。
    if (!a$can_loop()) return(invisible(FALSE))

    # 已经在跑就说明这一轮是循环自己发起的，不是新的一轮用户请求 ——
    # 那也要处理（这正是循环的推进方式），但不能重置 iter / sid。
    if (identical(a$state, "idle")) {
      sid <- hooks$get_sid()
      if (is.null(sid)) return(invisible(FALSE))
      a$sid <- sid
      a$t0 <- Sys.time()
      a$iter <- 0L
      a$warn_note <- character(0)
      a$prod <- character(0)
      # ★ V15.5 item 3：收尾轮的一次性开关也要在这一支复位。
      #   a$finish() 会清它，但**不是每条路都经过 finish**：收尾轮生成回来时
      #   如果用户正好把循环关掉了（a$can_loop() 在第一行为假）就直接 return，
      #   a$final 会留在 TRUE 上。用户再开一轮、说第一句话，on_llm_done 就会
      #   撞上下面那一支：循环在"用户刚开口"的时候静默结束，还附一句
      #   「轮次已用满」—— 正是那段注释里警告过的症状，只是入口不同。
      a$final <- FALSE
      # ★ V13.5 item 1：走到这一支 = **用户新开了一轮**（不是循环自己在往下
      #   推）。自动接手是"一次失败一次授权"，不能跨用户请求继承 ——
      #   不然用户在纯聊天模式下说一句"你好"也会掉进循环。
      a$armed <- FALSE
    }

    # 同一条助手消息只处理一次。见文件顶部 dsapp_agent_claims 的说明。
    if (!dsapp_agent_claim(message_id)) {
      a$note <- "这一轮已经被处理过了（可能是另一个标签页），跳过"
      hooks$refresh()
      return(invisible(FALSE))
    }
    a$last_key <- message_id

    # ★ V15.5 item 3：这是轮次用满之后那一轮**收尾发言**，无论它交回来什么，
    #   循环到此为止。
    #
    #   ⚠️ 这一支必须排在 a$iter 自增**前面**：收尾轮不是第 N+1 轮，它不消耗
    #      额度 —— 排在后面的话 `a$iter > a$max_iter` 会先命中，模型那条
    #      收尾结论倒是不会被执行（结果一样），但状态条上会闪一下 "7/6 轮"。
    #   ⚠️ 排在认领**后面**：两个标签页同时收尾时，认领过的那条不该再走一遍
    #      收尾流程（会多出一条平台提示，而且 a$final 已被清掉，行为分叉）。
    #   ⚠️ 清掉 a$final 是**必须**的：粘住的话，用户下一句普通聊天结束时会
    #      撞上这一支，循环在"用户刚说了一句话"时静默结束 —— 不报错，只是
    #      什么都不发生。
    if (isTRUE(a$final)) {
      a$final <- FALSE
      # 第 ④ 条：收了尾但一个能给人看的东西都没有 —— 得让用户知道。
      a$deliver_note()
      return(a$finish("轮次已用满，模型已给出收尾结论"))
    }

    a$iter <- a$iter + 1L
    if (a$iter > a$max_iter) {
      return(a$finish(sprintf("已达轮次上限（%d 轮），循环停止", a$max_iter)))
    }
    if (!is.null(a$t0) &&
        as.numeric(difftime(Sys.time(), a$t0, units = "secs")) > a$wall_limit) {
      # ★ V15.5 item 3 第 ④ 条：同 feed_result，时间闸出口也发交付提示。
      a$deliver_note()
      return(a$finish(dsapp_agent_wall_note(a$wall_limit)))
    }

    pick <- dsapp_agent_pick_block(text, finish_reason, cut_off)

    if (identical(pick$kind, "none")) {
      # 第 ④ 条：模型给了结论（没有可执行块 = 循环到此为止），但如果这一趟
      # 落盘的全是 json/rds 这类中间产物，用户手里其实什么都没有能看的。
      a$deliver_note()
      return(a$finish("模型给出了结论，循环结束"))
    }
    if (identical(pick$kind, "truncated")) {
      # 两种截断的回喂措辞要分开：被长度上限截断是"你写太长了"，重发时该拆小；
      # 流被掐断是"网络/服务端把你打断了"，跟你写多长没关系 —— 让模型去"拆小"
      # 是给了一个错误的因果，它会莫名其妙地把好好的脚本砍成两半。
      return(a$feed_back(if (isTRUE(cut_off)) sprintf(
        "这一轮的回复**没有生成完**（流被中断，不是你的问题），末尾的代码可能不完整，\
平台没有执行它。请**原样重发**这一段：内容不用改，也不用拆小。") else sprintf(
        "这一轮的回复被长度上限截断了，末尾的代码可能不完整，平台没有执行它。\
请把要做的事**拆小**、重发一次：只给一个可执行代码块，说明文字尽量简短。\
如果这一步本来就很大，先做能独立验证的第一步。")))
    }
    if (identical(pick$kind, "unclosed")) {
      return(a$feed_back(sprintf(
        "这一轮的代码块**结束围栏没有闭合**（缺少单独一行的 ```），\
平台无法确定代码到哪里结束，没有执行它。请重新发一次完整的代码块。\
提示：围栏要独占一行，代码内部如果也有 ``` 请改用四个反引号包住。")))
    }
    if (identical(pick$kind, "unparsed")) {
      # ★ V15.6 安全带（同 dsapp_agent_pick_block 里的注释）：以前这一支会
      #   掉进上面 "none" 的出口 = "模型给出了结论，循环结束"，用户看到的是
      #   "回复写到一半就不动了"。宁可多问一轮，也不要静默收尾。
      return(a$feed_back(sprintf(
        "这一轮的回复里出现了 ```，但平台没能把它识别成一个**代码块**，\
所以没有执行。最常见的原因是**开围栏没有独占一行** —— 比如写成了\
「……预计耗时 1 分钟。```python」，围栏粘在句子末尾了。请原样重发一次：\
开围栏自己占一行、语言标注紧跟围栏、正文与围栏之间换行。")))
    }

    blk <- pick$blk
    scan <- tryCatch(dsapp_scan_code(blk$code), error = function(e) NULL)
    if (is.null(scan)) {
      return(a$feed_back("平台扫描这段代码时出错了，没有执行。请重发一次。"))
    }

    decision <- dsapp_agent_scan_decision(scan)

    if (identical(decision, "blocked")) {
      # 拦截理由要**回喂**，不能只是拦掉。以前拦掉就完了，用户看到的是一张
      # 卡片、模型那边毫无反馈 —— 它会以为代码跑了，或者原样再发一遍。
      return(a$feed_back(sprintf(
        "平台**拒绝执行**这段代码，命中了高危规则：\n%s\n\n\
请改写：去掉这些操作，或者换成不触发它们的等价写法。\
如果这个操作是任务必需的，直接向用户说明需要他手工完成，不要反复重发。",
        dsapp_scan_message(scan))))
    }

    if (identical(decision, "confirm")) {
      a$pending <- blk
      a$pending_mid <- message_id
      a$state <- "awaiting_user"
      a$note <- "有一段代码需要你确认后才能执行"
      hooks$refresh()
      return(invisible(TRUE))
    }

    # 自动放行的警告要**看得见** —— 悄悄放过、界面上一点痕迹都没有的话，
    # 用户没法事后追查"这一步为什么往外发了数据"。
    a$warn_note <- dsapp_agent_warn_labels(scan)

    if (pick$extra > 0L) {
      hooks$add_msg("tool", sprintf(
        "【平台提示】这一轮还有 %d 个可执行代码块被**跳过**了（一轮只执行第一个）。\
如果需要执行它们，请在收到本次执行结果之后，单独再发。", pick$extra))
    }

    a$pending <- blk
    a$state <- "want_run"
    a$note <- sprintf("准备执行第 %d 轮：%s", a$iter, blk$lang)
    hooks$refresh()
    a$try_submit()
    invisible(TRUE)
  }

  #' 不执行，把一句说明回喂给模型让它重来
  a$feed_back <- function(msg) {
    hooks$add_msg("tool", paste0("【平台提示】\n", msg))
    a$state <- "generating"
    a$note <- "已把平台的说明回传给模型，等待它改写"
    hooks$refresh()
    hooks$begin_llm("agent")
    invisible(TRUE)
  }

  # ---- 内联确认卡 ----------------------------------------------------------

  a$confirm <- function() {
    if (!identical(a$state, "awaiting_user")) return(invisible(FALSE))
    a$state <- "want_run"
    a$note <- "已确认，开始执行"
    hooks$refresh()
    a$try_submit()
    invisible(TRUE)
  }

  a$deny <- function() {
    if (!identical(a$state, "awaiting_user")) return(invisible(FALSE))
    mid <- a$pending_mid
    dsapp_agent_release(mid)
    a$pending <- NULL
    a$pending_mid <- NULL
    a$feed_back(
      "用户**拒绝**执行这段代码（它要把数据发往外部地址）。请换一种做法：\
如果只是为了拿到公开数据，改用不携带本地数据的外发方式；\
如果确实需要上传，请告诉用户具体要传什么、传到哪儿，由用户自己决定。")
  }

  # ---- 手动执行失败之后自动接手（V11 item 8）-------------------------------

  #' 任务挂了，把循环拉起来让模型自己排查 —— **不需要用户先点确认**
  #'
  #' ★ V13.5 item 1。用户的原话：「报错需要AI自己解决，而不是用户自己确认」。
  #'
  #' 为什么需要它：手动执行**不走**循环的 try_submit / check_task，结果由
  #' mod_chat 的 dsapp_write_run_msg() 写一条 tool 消息就结束了。那条消息
  #' 会带上「这是环境问题、由你处理」（见上面的 dsapp_env_fix_hint），
  #' 但**没有人接着往下做** —— 模型根本不会被叫起来读它，那句话就白写了。
  #' 那就得有人在这一刻画一条起跑线。
  #'
  #' ---- 这一版改了什么 ------------------------------------------------------
  #'
  #' 原来第一道闸是 `a$enabled`（「自动执行」开关），而它**默认是关的**。
  #' 于是这条路在默认配置下从来没通过：报错就只是报错，界面上什么都不会
  #' 发生。现在换成 `a$autofix`（默认开），并且**不再要求是环境类失败** ——
  #' 用户说的是"报错需要 AI 自己解决"，没有限定只有缺包才算。
  #'
  #' 判定仍然要交给模型：回喂给它那条 tool 消息里带着平台的分类
  #'（dsapp_env_failure 的 kind / retryable），"缺包就装上重跑""列名写错就
  #' 改代码重跑""环境被删了就告诉用户"分别该怎么做，话都写好了。
  #' 平台这边**不替它决定要不要重跑** —— 它能看到完整的报错，比这里的正则
  #' 看得准。
  #'
  #' ⚠️ 但**不能让用户蒙在鼓里**：模型被叫起来的同时发一条通知说清楚
  #'    "AI 接手了、在改什么、怎么关掉"。安静地花钱是这个项目里最不能做的事。
  #'
  #' ---- 剩下的两道闸（原来三道，第 3 道 `is_env` 去掉了）-------------------
  #'
  #'   1. 循环空闲、且模型没在生成。正在跑就让它自己处理：插一脚会打乱它的
  #'      iter 计数，也会把用户正在等的那一轮回复顶掉。
  #'   2. **频率闸**（滑动窗口，见 config.R）。挡的是"改不好 → 再跑 → 再挂
  #'      → 再改"这个死循环。撞上它会明确告诉用户（不是静默返回）——
  #'      这个项目里"点了没反应"已经被当成 bug 查过好几次了。
  a$kick_env_fix <- function(env, tid = NULL, notify = NULL) {
    if (!isTRUE(a$autofix)) return(invisible(FALSE))
    if (a$active()) return(invisible(FALSE))
    if (isTRUE(hooks$running())) return(invisible(FALSE))

    # 先剪掉窗口外的，再看还剩几次。
    # ⚠️ 存的是**纯数字秒**（as.numeric(Sys.time())），不是 POSIXct。
    #    POSIXct 混进 numeric 向量会被强制转成数字、且带一个没人看的
    #    tzone 属性，再取出来比较时对不上；而 difftime 对象直接和 1800
    #    比大小能过、单位却取决于它是怎么算出来的 —— 都是静默出错的形状。
    # ⚠️ 这个窗口是**整个会话一份**，不是按任务算的 —— 而且必须是整个会话。
    #
    #   看起来它"应该"按任务分开算：任务 A 连撞三次之后，半小时里任何任务
    #   失败都被推给用户，而任务 B 是个全新的问题，凭什么被连坐。
    #   这个直觉是错的，我差点照着改了：**自动修复的下一轮本身就是新任务**。
    #   "改代码 → 重跑"每转一圈就 create 一个新 task_id，所以恰恰是那个要挡的
    #   死循环在不停地换 tid。按任务分开算 = 每一圈都是"新任务、计数为零"
    #   = 频率闸完全失效，变成无上限地烧 token。
    #   selftest 里那段就是拿 1/2/3/99/100 这几个不同的 tid 喂进来的，
    #   照着直觉改会当场红 —— 那几条断言就是在钉这个。
    #
    #   要挡的是"这个会话在反复烧钱"，不是"某个任务在反复挂"。
    now <- as.numeric(Sys.time())
    a$fix_times <- a$fix_times[a$fix_times > now - DSAPP_AGENT_AUTOFIX_WINDOW]

    # ★★ V16.2 item 1：闸门只在**设了上限**的时候才拦。
    #
    #   用户原话：「出错自动修也要默认没上限」。a$fix_max 是哨兵 0 时
    #   （默认）这一整段不成立 —— 上面那行剪窗口照剪（a$fix_times 还要
    #   拿去报"已经自动排查过几次"），但**不拦**。
    #
    #   ⚠️ 判据是 `!is_unlimited && ...`，**不是**把 fix_max 换成一个很大的
    #      数。换大数的话，界面上会显示"上限 999999 次"这种东西，而
    #      "不设上限"和"上限很大"是两件事（见 config.R 里 DSAPP_CTX_FOLLOW
    #      那段："用户读到什么，代码就得真的做什么"）。
    #   ⚠️ 别把它简化成 `length(a$fix_times) >= a$fix_max` 然后指望
    #      fix_max = 0 时比较为假：0 会让 **第一次** 就 `1 >= 0` 成立，
    #      于是默认档变成"一次都不许自动修"——正好是用户要的反面，
    #      而且它看起来像"功能坏了"，不像"上限读错了"。
    if (!isTRUE(dsapp_autofix_is_unlimited(a$fix_max)) &&
        length(a$fix_times) >= a$fix_max) {
      # 走到这里说明"改 → 跑 → 又挂"已经转到了**用户设的那个次数**。
      # **停下来是对的** —— 再转下去只是反复烧时间和额度，那不叫自动解决。
      #
      # 但停下来的这句话里**不许**再有"你看一眼报错、告诉我往哪改"：
      # 平台手里有完整的尝试记录，判断方向是平台自己的事，不是用户的待办。
      # 所以这里说的是"做了多少次、为什么停、你不用做什么"。
      #
      # ★ V16.2 item 1：次数报 a$fix_max，**不是** DSAPP_AGENT_AUTOFIX_MAX。
      #   上限现在是用户在「不设上限」那一组里自己设的（默认不设上限、
      #   走到这里说明他设了），照着常量报就会说出一个他没设过的数 ——
      #   而这句话的全部作用就是告诉他"为什么停了"。
      a$note <- sprintf("已经自动排查过 %d 次，先停一下",
                        as.integer(a$fix_max))
      # 尝试记录进持久日志：界面上那句话是给用户看的，这一条是给排查的人看的。
      tryCatch(
        dsapp_audit("自动修复暂停",
                    target = paste0("任务 #", if (is.null(tid)) "?" else tid),
                    detail = sprintf("本会话 %d 秒窗口内自动修复 %d 次仍未通过，暂停自动重跑",
                                     as.integer(DSAPP_AGENT_AUTOFIX_WINDOW),
                                     length(a$fix_times)),
                    ok = FALSE),
        error = function(e) NULL)
      hooks$refresh()
      if (is.function(notify)) {
        # ⚠️ 这里是 showNotification 的纯文本，**不是 markdown** ——
        #    写 `**加粗**` 会原样把星号显示出来。
        notify(sprintf(
          paste0("这个报错已经自动排查过 %d 次、每次都换了办法，还是没通过，",
                 "所以先停下来了 —— 再自动重跑只会反复烧时间。",
                 "试过哪些办法、报错什么样，都留在上面了，",
                 "不用你判断往哪个方向改。",
                 "想让它再多试几次的话，「不设上限」那一组里的",
                 "「出错自动修」把次数调大（或者直接勾回不设上限）。"),
          as.integer(a$fix_max)), "warning")
      }
      return(invisible(FALSE))
    }

    sid <- hooks$get_sid()
    if (is.null(sid)) return(invisible(FALSE))

    a$fix_times <- c(a$fix_times, now)
    # ★ 这两行是这一版的关键：armed 让 can_loop() 为真，于是**即使
    #   「自动执行」关着**，这一次生成结束后 on_llm_done 也会被叫到，
    #   模型说的改法才会真的被执行。没有它，模型查完了也没人照做。
    a$armed <- TRUE

    a$sid <- sid
    a$t0 <- Sys.time()
    a$iter <- 0L            # 新开的一段，轮次从头算
    a$warn_note <- character(0)
    # ★ V15.5 item 3：新开一段，收尾开关和产物清单跟着复位（和 a$iter 同一个
    #   道理）—— 不复位的话，上一段的收尾状态会被这一段的第一次 on_llm_done
    #   读到，那一段就"还没跑就结束了"。
    a$final <- FALSE
    a$prod  <- character(0)
    a$state <- "generating"

    # ★ V13.10 item 4：`self_fix` 的那几种（缺包、语法错、变量名写错）是
    #   **AI 自己的锅**，用户原话「不要交由用户解决……甚至不用记录和提示
    #   信息」。所以这一路的通知**不发**。
    #
    #   ⚠️ 但状态条那一行小字（a$note）**留着**，只把它缩短。
    #      全静默会被当成"点了没反应" —— 这个坑查过好几次了（见
    #      www/app.js 的 dsappNavSeq 那段注释）。用户的诉求是"别来问我"，
    #      不是"别让我看见屏幕上有动静"，这两件事得分开办。
    #
    #   ⚠️ 上头那个频率闸的通知**不在此列**，照发。它说的不是"出错了"，
    #      是"试了三次还是不行、我停下来了" —— 那已经不是日常噪声，而是
    #      用户必须知道的结论；静默掉它，用户会以为任务还在跑。
    sf <- dsapp_env_self_fix(env)
    a$note <- if (sf)
      sprintf("任务 #%s 没跑通，AI 正在自动重试",
              if (is.null(tid)) "?" else as.character(tid))
    else if (isTRUE(env$is_env))
      sprintf("任务 #%s 是环境问题（%s），AI 正在自己排查",
              if (is.null(tid)) "?" else as.character(tid), env$label %||% "")
    else
      sprintf("任务 #%s 失败了，AI 正在自己看这个报错",
              if (is.null(tid)) "?" else as.character(tid))
    hooks$refresh()
    hooks$begin_llm("agent")

    if (is.function(notify) && !sf) {
      notify(sprintf(
        "%s，已经让 AI 接手排查 —— 它会读报错、改代码或补装依赖，然后自己重跑。%s",
        if (isTRUE(env$is_env))
          sprintf("任务 #%s 是环境问题", if (is.null(tid)) "?" else as.character(tid))
        else
          sprintf("任务 #%s 失败了", if (is.null(tid)) "?" else as.character(tid)),
        "不需要你确认。不想让它自动接手的话，把上面「出错自动修」取消勾选。"),
        "message")
    }
    invisible(TRUE)
  }

  # ---- 心跳 ----------------------------------------------------------------

  #' 心跳：催一次状态机往前走
  #'
  #' ★ V13.7 item 5 从下面那个 observe 里抽出来的。抽出来的理由：**脱离会话
  #   的后台续跑要用同一个状态机**（R/detach.R），而那个进程里没有 Shiny
  #   会话、注册不了 observe。让它自己抄一份推进逻辑的话，两条路的循环行为
  #   会分叉 —— 而分叉的表现是"挂机跑出来和盯着跑出来不一样"，没人会去比对。
  #   ⚠️ 抽出来之后**下面那个 observe 必须只调这一个函数**，不许再往里写
  #      别的判断：写进去的那部分后台那条路就看不见了。
  a$tick <- function() {
    if (!a$active()) return(invisible(FALSE))

    if (identical(a$state, "want_run")) {
      a$try_submit()
    } else if (identical(a$state, "waiting")) {
      a$check_task()
    } else if (identical(a$state, "generating")) {
      # 等 LLM 那一轮结束。它在 rv$streaming 里跑，我们什么都不用做，
      # 但要说一句"在等生成"—— 否则状态条停在上一句"任务 #N 已结束"，
      # 看起来像是卡住了。
      if (!isTRUE(hooks$running())) {
        a$note <- "正在等待模型给出下一步…"
      }
    }
    invisible(TRUE)
  }

  # 一个 observe 管三件事：重试提交、等任务结束、清掉过期的确认卡。
  #
  # ⚠️ invalidateLater() 必须**无条件地排在判断之前**。
  #
  # 这里原来写的是"空闲时第一行就 return，不占响应式循环"，看着更省，实际
  # 是坏的。这个心跳体里读的全是普通环境字段（a$state / a$active()），Shiny
  # 看不见它们变化，所以它**唯一**的唤醒源就是自己排的那个定时器。而它第一次
  # 跑是在模块初始化时，那会儿 state 还是 "idle" —— 第一行 return，定时器
  # 根本没排上。从此这个 observe 永远沉默，之后再没有任何东西能叫醒它：
  # a$state 不是 reactiveVal，改它不触发失效。
  #
  # 表现是循环把任务提交出去之后就停在那儿：任务早就 success 了，状态条
  # 一直显示"任务 #N 执行中"，模型再也等不到结果，直到用户刷新页面。
  # 实测确认过：条件式写法在循环开始后的 6 秒里跳 0 次，无条件式跳 6 次。
  #
  # 代价是空闲会话每秒空转一次（一次几乎为空的 reactive flush），可以忽略；
  # 换掉的是一个只在特定时序下出现、且**完全静默**的挂起。
  #
  # ⚠️ `heart = FALSE` 时**不注册**这个 observe（V13.7 item 5）：那是给
  #    detach.R 的后台进程用的 —— 那里没有会话，注册了要么报错要么挂在一个
  #    永远不会 flush 的域上，而循环得靠调用方自己按 tick() 推。
  if (isTRUE(heart)) {
    shiny::observe({
      invalidateLater(1000)
      a$tick()
    })
  }

  a
}
