# =============================================================================
# 环境类失败的识别（V11 item 8）
# =============================================================================
#
# 用户的原话：「因为环境配置等原因导致任务失败应该让 AI 自动调试，只有思路
# 选择等场景需要用户做对应的反馈」。
#
# 这句话要落地，缺的**不是**让模型更努力，而是缺一个"这次失败的锅该谁背"的
# 判断。因为模型看到的报错和用户看到的报错是同一段文本，而它默认的礼貌是
# "把报错原文贴给用户、由用户决定"—— 缺包、缺系统库、镜像连不上，这些全是
# 平台/环境自己的事，用户既看不懂也管不着，贴给他只是把问题转手。
#
# 所以这里做一件很窄的事：**从报错文本里认出"这是环境问题"**，并给它一个
# 中文短标签 + 一句"你（模型）该怎么处理"。判断结果有两个去处：
#
#   1. R/agent.R 的 dsapp_agent_tool_text() —— 回喂给模型的 tool 消息里
#      多一段「平台判定：环境问题（由你处理）」，手动执行和自动循环**共用**
#      同一条消息，所以两条路都生效。
#   2. R/agent.R 的 a$try_submit() —— 提交期就被平台挡下来的那几种
#      （环境被删、解释器不在），措辞单独走一遍。
#
# ⚠️ 判据只能是**文本**。平台拿不到"这次失败属于哪一类"的结构化信息：
#    报错来自用户代码、来自 R 解释器、来自 conda、来自平台的 shell 包装，
#    四路混在同一个 stderr 里。硬要结构化就得让每一路都打标，改造成本远
#    大于收益，而文本匹配在这个场景里够用 —— 认错一类的代价只是回喂的话
#    说得不够贴切，模型仍然看得到原始报错。
#
# ⚠️ 规则**有序**，先匹配到的赢。`there is no package called` 要排在
#    `could not find function` 前面：缺包时 R 常常两条都打，而后者的标签
#    更含糊。

#' 环境类失败的特征表
#'
#' 每条：kind（归类）、re（正则）、label（给人看的中文短标签，%s 填捕获组）。
#'
#' `retryable` 的含义是"**模型自己动手有没有可能修好**"，它决定回喂时给
#' 哪一套建议：
#'   TRUE  —— 装包/换镜像/重试，模型能自己做完，**不要**打扰用户；
#'   FALSE —— 模型改不了（环境被删、解释器没了、盘满），该说清楚"要用户
#'            做什么"，但仍然不许只说一句"失败了请检查环境"就完事。
#'
#' `self_fix`（V13.10 item 4）是"**这一条连用户都不该看见**"。用户的原话：
#'
#'   「我开启出错自动修之后版本依赖、语法错误不要交由用户解决，请自行处理，
#'     甚至不用记录和提示信息。例如最近的一个会话中的
#'     "Error: object 'l' not found" 就不应该返回。」
#'
#' 版依赖（kind = missing_pkg / solver / network）本来就 retryable，这一版
#' 补上的是**语法错误**和**代码本身写错**这两类 —— 它们是模型自己上一轮
#' 生成出来的东西，用户既看不出问题也不该被问。判据落在这里而不是散在
#' agent.R 里，是因为"这句话该谁看"必须和"这是什么错"一起决定，分开写
#' 迟早会对不上。
#'
#' self_fix = TRUE 的效果有两处，**两处都要**：
#'   1. 回喂给模型的提示词换成"这是你自己写的代码的问题，改它，别转述给用户"；
#'   2. 界面上的通知和"环境问题"框**都不出现**（用户明确说了"不用记录和
#'      提示信息"）—— 只在状态条留一行小字，因为自动执行本身要有个动静，
#'      全静默会被当成"点了没反应"（这个坑见 www/app.js 的 dsappNavSeq）。
dsapp_env_rules <- function() {
  list(
    list(kind = "missing_pkg", retryable = TRUE,
         re = "there is no package called [‘'\"]?([A-Za-z0-9._]+)",
         label = "缺少 R 包 %s"),
    list(kind = "missing_pkg", retryable = TRUE,
         re = "package or namespace load failed for [‘'\"]?([A-Za-z0-9._]+)",
         label = "R 包 %s 加载失败（装了但加载不起来，多半是版本或系统依赖对不上）"),
    list(kind = "missing_pkg", retryable = TRUE,
         re = "ModuleNotFoundError: No module named [‘'\"]?([A-Za-z0-9._]+)",
         label = "缺少 Python 包 %s"),
    list(kind = "missing_pkg", retryable = TRUE,
         re = "ImportError: ([^\n]{1,60})",
         label = "Python 导入失败：%s"),
    list(kind = "missing_pkg", retryable = TRUE,
         re = "could not find function [‘\"]([^’\"]+)",
         label = "找不到函数 %s（多半是缺包或漏了 library()）"),
    list(kind = "missing_pkg", retryable = TRUE,
         re = "command not found: ?([A-Za-z0-9._-]+)",
         label = "环境里没有 %s 这个命令"),
    # ---- 系统层：装得上但用不了 ------------------------------------------
    list(kind = "sys_lib", retryable = TRUE,
         re = "cannot open shared object file",
         label = "缺系统动态库（包装上了，但它依赖的系统库不在）"),
    list(kind = "sys_lib", retryable = TRUE,
         re = "unable to load shared object",
         label = "动态库加载失败"),
    # ---- 环境本身没了：模型改不了 ----------------------------------------
    list(kind = "missing_env", retryable = FALSE,
         re = "conda 环境 ([A-Za-z0-9._-]+) 不存在",
         label = "所选 conda 环境 %s 已经不在平台上了"),
    list(kind = "missing_env", retryable = FALSE,
         re = "环境不存在|环境已损坏|环境未就绪",
         label = "运行环境不在了或未就绪"),
    list(kind = "missing_interp", retryable = FALSE,
         re = "无法启动执行进程|解释器不存在|没有可用的解释器",
         label = "平台没能把执行进程拉起来（解释器不在）"),
    # ---- 资源与权限 -------------------------------------------------------
    list(kind = "disk", retryable = FALSE,
         re = "No space left on device|Disk quota exceeded|磁盘空间不足|超出配额|已达存储配额",
         label = "磁盘或配额满了"),
    list(kind = "perm", retryable = FALSE,
         re = "Permission denied|Read-only file system|Operation not permitted",
         label = "文件权限不够（往只读的地方写了）"),
    # ---- 网络：装包那条路上最常见的失败 ----------------------------------
    list(kind = "network", retryable = TRUE,
         re = "Could not resolve host|Failed to connect|Connection timed out|Connection refused|SSL certificate problem|无法连接|网络不通",
         label = "装包时连不上源（网络或镜像的问题）"),
    list(kind = "solver", retryable = TRUE,
         re = "PackagesNotFoundError|UnsatisfiableError|Solving environment: failed|依赖冲突|依赖求解失败",
         label = "conda 解不出依赖（要装的包和现有环境冲突）"),

    # =====================================================================
    # ★ V13.10 item 4：下面两组是"AI 自己的锅"，**一个字都不该回到用户那里**。
    #
    # ⚠️ 位置：必须排在 missing_pkg 那一组**后面**。"there is no package
    #    called" 要赢过一切 —— 缺包时 R 常常同时打出
    #    "Error in library(x) : there is no package called 'x'"，把它判成
    #    "代码写错了"会让模型去改一行本来没错的 library() 调用。
    #
    # ⚠️ 也必须排在 network / solver 后面：装包失败时的 stderr 里常常夹着
    #    一段 R 的 "Error in ..."，先匹配到 code_bug 的话，模型会去改代码
    #    而真正该做的是换镜像。
    # =====================================================================

    # ⚠️⚠️ 这两组一律写 `env = FALSE`：它们**不是环境问题**（is_env 仍是
    #     FALSE，和 V11 起的语义完全一致 —— 自检里那条「业务错误不算环境
    #     问题」钉的就是这个）。它们是"该谁修"的问题，由 self_fix 回答。
    #    把语法错误塞进 is_env 会让界面弹出一个「环境问题」框，而环境根本
    #    没坏，用户会跑去环境页乱点。

    # ---- 语法错误：这段代码根本没通过解析 --------------------------------
    #
    # 这一类最该自动处理：解析都没过，说明上一轮生成的**代码块本身就是坏的**。
    # 常见来源是生成被 max_tokens 截断（R/agent.R 的 dsapp_agent_pick_block
    # 已经挡了一部分，挡不住的是"看着完整、其实括号没配平"）。
    list(kind = "syntax", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "unexpected end of input|unexpected INCOMPLETE_STRING|unexpected string literal constant",
         label = "代码没写完（括号/引号没配平，多半是上一轮生成被截断了）"),
    list(kind = "syntax", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "unexpected symbol|unexpected '[^']*'|unexpected ([A-Z_]+)",
         label = "代码语法错误（R 解析不了这一行）"),
    list(kind = "syntax", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "SyntaxError|IndentationError|TabError",
         label = "Python 语法错误"),
    list(kind = "syntax", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "parse error|ParseError",
         label = "代码解析失败"),

    # ---- 代码本身写错了（跑得起来，但引用了不存在的东西）-----------------
    #
    # ★ 用户点名的那一条就在这里：
    #     Error: object 'l' not found
    #   它既不是缺包也不是环境坏了 —— 是上一轮生成的代码里用了一个没定义
    #   的变量（`l` 通常是 `length(...)` 或者某个循环变量被写漏了）。
    #   模型看得到自己刚写的那段代码，改起来是它最擅长的事，而用户拿到
    #   "object 'l' not found" 除了发懵做不了任何事。
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "object '[^']+' not found|找不到对象 '[^']+'",
         label = "代码里用了一个不存在的变量"),
    # R 装在中文 locale 下时，"object 'x' not found" 是印成「找不到对象」的，
    # 所以上面那条的正则两种写法都要认（同一个错的两种字面）。
    # ⚠️ 自检里那条「少写一个变量名也不算环境问题」用的样本正是中文那句 ——
    #    它钉的是 is_env，这条规则的 env = FALSE 和它一致，两边不会打架。
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "object of type '[^']+' is not subsettable",
         label = "把不是数据框的东西当数据框用了"),
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "NameError: name '[^']+' is not defined",
         label = "Python 代码里用了一个不存在的变量"),
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "subscript out of bounds|undefined columns selected|incorrect number of dimensions",
         label = "下标越界（取的那一行/列/元素不存在）"),
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "non-numeric argument to binary operator|invalid '[^']*' type|argument is not a matrix|is not a function, character or symbol",
         label = "类型不对（这个位置要的不是这种数据）"),
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "TypeError:|ValueError:|AttributeError:|KeyError:|IndexError:",
         label = "Python 代码本身写错了"),
    list(kind = "code_bug", retryable = TRUE, self_fix = TRUE, env = FALSE,
         re = "^Execution halted$|\\nExecution halted\\s*$",
         label = "R 脚本中途退出了（stderr 在上面，没被别的规则认出来）")
  )
}

#' 这一次失败该不该让 AI 自己扛下来（V13.10 item 4）
#'
#' 判据是"模型能不能自己修"，不是"是不是环境问题"—— 语法错误和变量名写错
#' 都不是环境问题，但同样是模型自己造的、也只有它自己能修。
#'
#' @return TRUE/FALSE
dsapp_env_self_fix <- function(env) {
  if (is.null(env) || !is.list(env)) return(FALSE)
  isTRUE(env$self_fix) || isTRUE(env$retryable)
}

#' 这段报错是不是环境问题？
#'
#' @param stderr 任务的 stderr（主要判据）
#' @param status 任务状态；"error" = 平台侧错误，一律算环境问题
#' @param msg    平台自己的错误消息（提交期失败走这条）
#' @param extra  其它要一起看的文本
#' @return list(is_env, kind, label, retryable, self_fix, matched)
#'         is_env = FALSE 时 label 是 ""、kind 是 NA。
#'
#' ⚠️ `is_env` 和 `self_fix` 是**两个问题**（V13.10 item 4 拆开的）：
#'      is_env   —— 环境坏了吗？（决定界面弹不弹「环境问题」框）
#'      self_fix —— 这件事该不该让用户知道？（决定通知压不压、要不要回喂）
#'    语法错误、变量名写错：is_env = FALSE，self_fix = TRUE。
#'    缺包、装不上：is_env = TRUE，self_fix 也是 TRUE（**用户不用管**）。
#'    环境被删、盘满：is_env = TRUE，self_fix = FALSE（**必须**让用户知道）。
#'    把两者并成一个字段的话，"用户要不要看见"就没法单独回答了 —— 而自检里
#'    钉着 is_env 的旧语义（业务错误不算环境问题），不能动。
dsapp_env_failure <- function(stderr = "", status = NULL, msg = "",
                              extra = "") {
  blank <- list(is_env = FALSE, kind = NA_character_, label = "",
                retryable = FALSE, self_fix = FALSE, matched = "")

  txt <- paste(c(stderr %||% "", msg %||% "", extra %||% ""), collapse = "\n")
  if (!nzchar(trimws(txt))) {
    # 一个字都没有，但状态是"平台侧错误"—— 那是平台连报错都没能写回来，
    # 这种也算环境问题（模型据此知道不是自己的代码写错了）。
    if (identical(as.character(status %||% ""), "error")) {
      return(list(is_env = TRUE, kind = "platform", retryable = FALSE,
                  self_fix = FALSE,
                  label = "平台侧错误（没有留下 stderr）", matched = ""))
    }
    return(blank)
  }

  for (r in dsapp_env_rules()) {
    m <- regmatches(txt, regexpr(r$re, txt, perl = TRUE))
    if (!length(m) || !nzchar(m[1])) next
    cap <- regmatches(txt, regexec(r$re, txt, perl = TRUE))[[1]]
    # ⚠️ 标签里没有 %s 的那几条**不能**照样 sprintf —— R 会报
    #    "one argument not used by format"，在自检里刷一屏警告，
    #    看起来像是刚写的东西坏了（实际只是多喂了一个参数）。
    arg <- if (length(cap) >= 2) cap[2] else ""
    lab <- if (grepl("%s", r$label, fixed = TRUE)) {
      sprintf(r$label, arg)
    } else {
      r$label
    }
    # ⚠️ `env` 不写默认是 TRUE —— 老规则一条都不用改，行为原样。
    #    只有 V13.10 item 4 那两组（语法/代码写错）显式写 `env = FALSE`。
    return(list(is_env = isTRUE(r$env %||% TRUE),
                kind = r$kind,
                retryable = isTRUE(r$retryable),
                # 能自己重试的，本来就轮不到用户插手（V11 起界面就是这么说的，
                # 只不过那时还在"提示"他一下）；self_fix 显式的那些连提都不提。
                self_fix = isTRUE(r$self_fix) || isTRUE(r$retryable),
                label = lab, matched = m[1]))
  }

  if (identical(as.character(status %||% ""), "error")) {
    return(list(is_env = TRUE, kind = "platform", retryable = FALSE,
                self_fix = FALSE,
                label = "平台侧错误（任务没能真正跑起来）", matched = ""))
  }
  blank
}

#' 给模型看的一段"这次失败该怎么处理"
#'
#' 措辞分三套，按「是不是环境问题」×「模型能不能自己修」来选。
#' **三套都必须明确写出"不要做什么"** —— 模型的默认行为就是"把报错贴给
#' 用户、请用户决定"，不点名禁止的话，加了这一段它照样会把锅转手。
#'
#' ★ V13.10 item 4 加的第三套（self_fix 但 is_env = FALSE）措辞最重：
#'   用户的原话是「语法错误不要交由用户解决……**甚至不用记录和提示信息**」，
#'   所以这里连"告诉用户你修好了"都禁掉 —— 报告一句"刚才是变量名写错了，
#'   已修正"，用户看到的就是一条他不该看见的错。修完直接往下走。
dsapp_env_fix_hint <- function(env) {
  is_env <- isTRUE(env$is_env)
  self_fix <- isTRUE(env$self_fix)
  # 既不是环境问题、模型也不用管 —— 认不出来的一类，不对它说任何话。
  if (!is_env && !self_fix) return("")

  head <- if (is_env) {
    sprintf("\n--- 平台判定：这是**环境问题**，不是用户该处理的事 ---\n判定：%s\n",
            env$label)
  } else {
    sprintf(paste0("\n--- 平台判定：这次失败是**上一轮代码自己的问题**，",
                   "用户既看不出也不该被问 ---\n判定：%s\n"),
            env$label)
  }

  # ---- 第三套：代码本身写错了（语法、变量名、类型）---------------------
  # ⚠️ 这条**必须在 retryable 判断之前**：这类规则的 retryable 也是 TRUE，
  #    掉到下面去的话，模型收到的建议会变成"pip install 一下"。
  if (!is_env) {
    return(paste0(head, paste0(
      "这段代码是**你自己刚写的**，报错说明它没跑通 —— 这不需要用户参与，",
      "也不需要征求谁的意见。按这个来：\n",
      "1. 看回你刚才发出去的那段代码（就在上面的对话里），定位到出问题的那一行。",
      "括号/引号没配平就补上，变量名写错或漏定义就改对；\n",
      "2. **新起一个代码块**重跑，不要在原处反复贴同一段；\n",
      "3. 修好之后直接继续往下做，**不要**写\"刚才那个错误是因为……，现在已经修好了\"",
      "这类说明，也不要把它列进你的回复里 —— 用户要的是结果，不是这次的翻车记录。\n",
      "**不要**把原始报错贴给用户，**不要**问他怎么处理。"))
    )
  }

  body <- if (isTRUE(env$retryable)) {
    paste0(
      "环境问题不需要用户做决定，你自己就能修。按这个顺序来：\n",
      "1. **单独一个代码块**把缺的东西装上（R：install.packages() / BiocManager::install()；",
      "Python：用当前解释器 pip install），装完**再新起一块**重跑刚才那段；\n",
      "2. 上一步失败就换办法（换镜像、换等价的包、换实现），",
      "但**不要**把同一段代码原样重发；\n",
      "3. 只有这些都试过、确实修不好，才向用户说明\"需要你做什么\"，",
      "并把你试过的办法和原始报错一起给出。\n",
      "**不要**只是把这段报错转述给用户就停下。")
  } else {
    paste0(
      "这一条**你改不了**（不是装个包能解决的），但也不许只说一句\"失败了\"：\n",
      "1. 先说清楚是什么坏了、影响到哪一步；\n",
      "2. 再说**具体**要用户做什么（哪一页、点哪里、选什么），一句话说清；\n",
      "3. 能绕开的就绕开：如果换一种写法、换一份数据、用系统环境里已有的包",
      "也能把这一步做完，就直接那么做，别停在报错上等用户。")
  }
  paste0(head, body)
}

# =============================================================================
# 把 stderr 拆成「真的报错」和「只是警告」（V13.12 item 4）
# =============================================================================
#
# 用户原话：「分析过程中的 warring 和报错没有必要返回给用户」。
#
# 前半句（warning）是这一版的活，后半句（报错）由 self_fix + autofix 那条路
# 负责（见上面 dsapp_env_failure 的注释）。
#
# ---- 为什么警告会「返回给用户」，而且看起来像报错 ---------------------------
#
# R 把 `warning()` 全部写进 **stderr**，和 `stop()` 的报错同一个流。而
# render.R 的 dsapp_run_card 一直是这么判的：`stderr 非空 ⇒ 画一个红框写上
# 「报错」`。于是：
#
#     Warning message:
#     In log(x) : NaNs produced
#
# 这种**任务成功、结果完全正确**的一次执行，在对话里是一屏红字加一个
# 「让 AI 分析这个报错」的按钮。用户看到的是"失败了"，而它根本没失败 ——
# 这是这套界面里最容易误导人的一处。
#
# ---- 判据为什么是「整块」而不是「逐行」--------------------------------------
#
# R 的警告是**两行起**的：
#
#     Warning message:
#     In read.table(...) : incomplete final line found
#
# 只按行首匹配的话，第二行（`In ...`）留了下来，红框里就剩一句没头没尾的
# "In read.table(...) : ..."，比不拆还糟。所以这里做的是**整块识别**：
# 从一条警告的开头行起，把它后面属于它的续行一起收走。
#
# ---- 安全网：失败时绝不把仅有的线索藏掉 -------------------------------------
#
# `failed = TRUE` 时，如果剥完警告之后「真报错」一行都不剩，就把**原文
# 整个还回去**。宁可让用户多看几行警告，也不能出现"任务失败、界面上一个字
# 都没有"——那比现在的毛病严重得多。`failed = FALSE` 时不做这个兜底：
# 成功且 stderr 只有警告，本来就该什么都不显示。

#' 警告块的开头长什么样
#'
#' ⚠️ `^Warning` 一条就够覆盖 R 的 `Warning:` / `Warning message:` /
#'    `Warning messages:`（都是同一个前缀），别再拆成三条 —— 拆开之后加
#'    一种新写法必然漏改其中一条，而漏掉的表现是"那种警告又冒出来了"，
#'    只在特定包的输出里复现。
dsapp_stderr_warn_start_re <- function() {
  paste0(
    "^Warning",
    "|^In addition: *Warning",
    "|^There were [0-9]+ (or more )?warnings",
    "|^[0-9]+ 个警告",
    # 中文 locale 下 R 印的是「警告信息」/「警告:」
    "|^警告",
    # Python：`/path/x.py:12: DeprecationWarning: ...`
    "|:[0-9]+: *[A-Za-z]*Warning",
    "|^[A-Za-z]*Warning:",
    # R CMD check 风格的 note（conda/mamba 也印 note:）
    "|^[Nn]ote: "
  )
}

#' 警告块的续行长什么样
dsapp_stderr_warn_cont_re <- function() {
  paste0(
    "^[[:space:]]",      # 缩进行（Python 警告会把源码那行抄下来）
    "|^In ",             # R：`In log(x) : NaNs produced`
    "|^[0-9]+: ",        # R：`Warning messages:` 下面编号列出
    "|^: ",              # R：换行后的 `: 内容`
    "|^$"                # 空行不打断
  )
}

#' stderr → list(keep, noise)
#'
#' @param txt    任务 stderr（原始文本）
#' @param failed 这个任务本身是不是失败了。决定要不要走"至少留一行"的兜底。
#' @return list(keep = 真报错, noise = 警告, n_noise = 警告块个数)
dsapp_stderr_split <- function(txt, failed = TRUE) {
  txt <- txt %||% ""
  if (!nzchar(trimws(txt))) {
    return(list(keep = "", noise = "", n_noise = 0L))
  }
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  keep  <- logical(length(lines))
  in_w  <- FALSE
  n_w   <- 0L
  start_re <- dsapp_stderr_warn_start_re()
  cont_re  <- dsapp_stderr_warn_cont_re()

  for (i in seq_along(lines)) {
    ln <- lines[i]
    if (in_w) {
      if (grepl(cont_re, ln, perl = TRUE)) {
        keep[i] <- FALSE
        next
      }
      in_w <- FALSE
      # 掉出警告块 —— 落到下面按"新的开头"再判一次
    }
    if (grepl(start_re, ln, perl = TRUE)) {
      keep[i] <- FALSE
      in_w <- TRUE
      n_w <- n_w + 1L
    } else {
      keep[i] <- TRUE
    }
  }

  k <- lines[keep]
  n <- lines[!keep]
  # 兜底：见文件头「安全网」那一段
  if (isTRUE(failed) && !any(nzchar(trimws(k)))) {
    return(list(keep = txt, noise = "", n_noise = 0L))
  }
  list(keep  = paste(k, collapse = "\n"),
       noise = paste(n, collapse = "\n"),
       n_noise = n_w)
}

#' 短标签，给界面用（tool 气泡标题、状态条）
dsapp_env_failure_label <- function(env) {
  if (!isTRUE(env$is_env)) return("")
  sprintf("环境问题：%s", env$label %||% "")
}

#' 给**用户**看的一句话（执行结果卡片里那个"环境问题"框）
#'
#' ⚠️ 和 dsapp_env_fix_hint() 是**两个读者**，不能共用一套话。那一套是写给
#'    模型的（"你自己就能修""不要转手给用户"），直接摆到界面上，用户会看到
#'    一句对着别人说的话；这一套是写给用户的，说的是"这件事要不要你动手"。
#'
#' ⚠️ 可自修的那一类**必须明说"你不用做什么"**。用户看到一屏红字的第一反应
#'    是"是不是我哪里选错了"，不说清楚他就会去乱点环境设置 —— 而环境恰恰是
#'    这里最不该被乱动的东西（改错了，原本能跑的任务也跟着跑不了）。
#'
#' @param autofix 「出错自动修」开着吗（V13.10 item 4）
#'
#' ★ 为什么这个开关**必须由调用方传进来**、不能在这里自己读：这个函数是纯的
#'   （render.R 的 dsapp_run_card 拿它渲染历史卡片），而 autofix 是**每个对话
#'   一份**的运行时状态（mod_chat.R 的 input$agent_fix → a$autofix）。到这里
#'   去翻 session 就等于把渲染函数和会话绑死，历史卡片会跟着"当前这个对话"
#'   的勾选状态变 —— 三个月前那次失败该说什么，取决于今天勾没勾，这是错的。
#'
#' ★ 开关打开时，**自修类一律返回空串**：用户原话是「甚至不用记录和提示
#'   信息」。返回空串不等于什么都不显示 —— 调用方拿到空串就不渲染那一块，
#'   见 render.R 里 `nzchar(...)` 那道判断。
#'   ⚠️ 默认值必须是 FALSE。默认 TRUE 的话，所有没传这个参数的老调用点都会
#'      静默变成"什么都不说"，包括自检里那几条断言 —— 而它们红的时候指向的
#'      是 envfix.R，真正的原因却在某个没改的调用点上。
dsapp_env_user_note <- function(env, autofix = FALSE) {
  if (!isTRUE(env$is_env)) return("")
  # 自动修开着 → 这几种本来就轮不到用户，一个字都不说。
  if (isTRUE(autofix) && isTRUE(env$self_fix)) return("")
  if (isTRUE(env$retryable)) {
    return(paste0("这是执行环境的问题，不是这段代码写错了。装包这类事由平台和 AI ",
                  "负责，你不用做什么 —— 它自己会装好再跑一遍。"))
  }
  switch(as.character(env$kind %||% ""),
    # ★ V13.7 item 2：这两条原来都是「到「环境」页……」—— 把平台的活写成了
    #   用户的待办，而且是写给一个**上次已经选对过**的人。
    #
    #   ⚠️ 改文案必须和改行为一起做，否则就是在骗人：
    #     · missing_env —— 提交前的那道检查真的会清掉失效选择、切回系统环境
    #       （mod_chat.R 的 dsapp_current_target），所以"不用你去改设置"是真的。
    #       留在这里的是提交之后、真正执行之前那一小段里的竞争。
    #     · missing_interp —— 平台**故意不替**它换解释器（换个解释器跑出来的
    #       结果对不上，selftest 钉着这条）。所以这里不能写"会自动换个环境"，
    #       能说的只有"不是你选错了、不用去改设置"。真正接手的是 AI 那条路
    #       （dsapp_env_fix_hint 里写着让它换写法绕开）。
    #       ⚠️ 措辞上**连「环境」页这三个字都不出现**：一提到那个页面，
    #          用户的下一个动作就是去那儿乱点，而环境恰恰是这里最不该被
    #          乱动的东西（改错了，原本能跑的任务也跟着跑不了）。
    missing_env    = paste0("选用的分析环境不在了或已经损坏。平台在每次执行前都会重新检查，",
                            "环境真的没了就自动切回系统环境 —— 这件事由平台处理，不用你动手。"),
    missing_interp = paste0("这个环境里没有跑这段代码需要的解释器。这是环境本身的问题，",
                            "不是你哪里选错了 —— 不用去改设置。"),
    disk           = "磁盘或配额满了。到「文件」页删掉一些不要的产物再试。",
    perm           = "要写的位置没有权限。换一个输出目录，或到「文件」页确认那个目录还在。",
    "这一条 AI 改不了，需要你处理。"
  )
}
