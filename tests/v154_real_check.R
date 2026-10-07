#!/usr/bin/env Rscript
# =============================================================================
# V15.4 真机验收：第 5 条的**后一半**只有真厂商能回答
# =============================================================================
#
#     DSAPP_TEST_API_KEY=sk-xxx Rscript tests/v154_real_check.R
#
# 可选环境变量：
#     DSAPP_TEST_MODEL      默认 deepseek-flash（要和 Key 那家对得上）
#     DSAPP_TEST_BASE_URL   默认 https://api.deepseek.com
#     DSAPP_TEST_DATA       留着数据目录，排查用（不设就是临时目录，跑完就删）
#
# ── 为什么非要真跑一趟 ──────────────────────────────────────────────────────
#
# 用户第 5 条的原话是「markdown 不需要在 html 中保留原格式，我需要编译渲染后
# 的效果」。它有两个半边：
#
#   ① **平台自己的渲染管线**（聊天气泡、文件预览）—— 那是纯函数，自检和浏览器
#      探针已经钉死了，不需要真模型；
#   ② **模型自己生成的 .html 文件** —— 那一份 HTML 是**模型写的**，平台一个
#      字节都不碰。能不能编译成 HTML，取决于提示词里那条规则**模型听不听**。
#
# ②就是这里要验的：线上 messages.id = 391 那个会话里，模型写了
#
#     parts.append("<section><pre>" + html.escape(content) + "</pre></section>")
#
# 并且配了一句"Markdown 以保留原文方式显示"—— 用户打开生成的报告，看到的是一
# 屏 `## 标题` 和 `| 列 | 列 |`。V15.4 在 `DSPROMPT_CODE_RULES_TAIL` 里补了
# 「规则 10」，但**提示词写没写进去**（自检能验）和**模型照不照做**（只有真跑
# 才知道）是两件事 —— selftest-green-is-not-coverage，本仓栽过两次。
#
# ── 三条闸，一条都不能少 ────────────────────────────────────────────────────
#
#   ⚠️ Key 只从环境变量读，**不落盘、不进命令行参数**（`ps` 和 shell 历史都
#      看得到 argv）。这是用户定的规矩，见 .Renviron.example 顶部。
#   ⚠️ 数据目录强制在临时目录下：跑真模型会往库里写消息，绝不能碰线上那份。
#   ⚠️ 提示词一律是"生成一个小报告"这种量级，单条预算靠 max_tokens 卡住。
#
# 输出一律走 stderr：stdout 重定向到文件时是块缓冲的，卡住时一个字都看不到，
# 而"卡住"恰恰是这里最要报出来的情况。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)

ok <- TRUE; nfail <- 0L
say <- function(...) cat(sprintf(...), "\n", file = stderr())
chk <- function(name, cond) {
  if (isTRUE(cond)) say("  \033[32m✓\033[0m %s", name)
  else { ok <<- FALSE; nfail <<- nfail + 1L; say("  \033[31m✗ %s\033[0m", name) }
}
# 「看到了、值得记一笔，但**不是**被测代码的锅」的那种结论走这里。
# ⚠️ 别把这类东西写成 chk：真模型听不听提示词，不是这个应用能决定的。
#    混进失败项里，读的人会以为部署坏了。
warn <- function(...) say(paste0("  \033[33m⚠\033[0m ", ...))

KEY <- Sys.getenv("DSAPP_TEST_API_KEY", "")
if (!nzchar(KEY)) {
  say("没有设 DSAPP_TEST_API_KEY，跳过真机验收。")
  say("用法：DSAPP_TEST_API_KEY=sk-xxx Rscript tests/v154_real_check.R")
  quit(status = 0L)
}
MODEL    <- Sys.getenv("DSAPP_TEST_MODEL", "deepseek-flash")
BASE_URL <- Sys.getenv("DSAPP_TEST_BASE_URL", "https://api.deepseek.com")

# 这份报告要写到几百字，比 v153 那份"回一个字"的预算大一些。
# 但它仍然只是一次验收，不是一次生成 —— 上限卡在 4000。
BUDGET_TOK <- 4000L

# ---- 数据目录：强制临时 -----------------------------------------------------
keep <- Sys.getenv("DSAPP_TEST_DATA", "")
tmp <- if (nzchar(keep)) {
  dir.create(keep, recursive = TRUE, showWarnings = FALSE); keep
} else {
  d <- tempfile("dsapp_real_v154_"); dir.create(d, recursive = TRUE); d
}
if (!(startsWith(normalizePath(tmp, mustWork = FALSE), "/tmp/") ||
      startsWith(normalizePath(tmp, mustWork = FALSE), "/var/tmp/"))) {
  say("拒绝运行：DSAPP_TEST_DATA=%s 不在临时目录下。", tmp)
  quit(status = 1L)
}
say("数据目录 %s", tmp)

Sys.setenv(DSAPP_DATA_ROOT = tmp)
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}
# ⚠️ 这个名字**不能**叫 `cfg`（模块里那个 `cfg <- function() ...` 会盖住它，
#    详见 tests/agent_loop.R 里那段说明）。同理 state / rv / session 都不能用。
tcfg <- dsapp_config(); dsapp_init_dirs(tcfg)
say("应用已装载，%d 个 R 文件", length(list.files(file.path(app_dir, "R"))))

# 一次请求跑到底，返回增量序列（同 v153_real_check.R，理由见那里的注释）。
run_once <- function(messages, max_tokens = BUDGET_TOK, thinking = TRUE,
                     timeout_s = 300) {
  h <- dsapp_llm_start(
    api_key = KEY, messages = messages, model = MODEL, cfg = tcfg,
    temperature = 0.3, max_tokens = max_tokens, base_url = BASE_URL,
    thinking = thinking)
  on.exit(try(dsapp_llm_stop(h), silent = TRUE), add = TRUE)

  text <- ""; reason <- ""; n_text <- 0L; n_reason <- 0L
  t0 <- Sys.time()
  repeat {
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) > timeout_s) {
      return(list(text = text, reasoning = reason, error = "本地超时",
                  n_text = n_text, n_reason = n_reason, timed_out = TRUE))
    }
    p <- dsapp_llm_poll(h)
    if (nzchar(p$text %||% ""))      { text   <- paste0(text, p$text);   n_text   <- n_text + 1L }
    if (nzchar(p$reasoning %||% "")) { reason <- paste0(reason, p$reasoning); n_reason <- n_reason + 1L }
    if (isTRUE(p$done)) {
      return(list(text = text, reasoning = reason, error = p$error,
                  n_text = n_text, n_reason = n_reason, timed_out = FALSE))
    }
    Sys.sleep(0.05)
  }
}

# =============================================================================
say("\n== A. 「规则 10」真的在**实际发出去的** system 消息里 ==")
# =============================================================================
# 自检断的是 DSPROMPT_CODE_RULES_TAIL 这个**常数**里有那段话。但真正出网的是
# build_system_prompt() 拼出来的那一大段 —— 中间隔着 section_for()、覆盖层、
# 场景路由三道。常数里有、拼出来没有，是完全可能的（漏拼一节、场景判错），
# 而且**不报错**。
sys_chat  <- build_system_prompt("chat",  tcfg)
sys_agent <- build_system_prompt("agent", tcfg)
say("  chat 提示词 %d 字，agent %d 字", nchar(sys_chat), nchar(sys_agent))

chk("★★★ chat 场景的 system 消息里有「规则 10」",
    grepl("规则 10", sys_chat, fixed = TRUE), "")
chk("★★★ 而且带上了那句**可执行的**要求（不是只有一个标题）",
    grepl("编译", sys_chat, fixed = TRUE) &&
      grepl("html.escape", sys_chat, fixed = TRUE), "")
chk("★★ agent 场景也带上了（两种模式的提示词都挂在 TAIL 上）",
    grepl("规则 10", sys_agent, fixed = TRUE), "")
# 反面：这条规则**只该**出现在有代码铁律的场景里。debug 那一档只有
# capabilities + interaction（见 R/prompts.R 的场景路由），不该带上它。
sys_debug <- build_system_prompt("debug", tcfg)
chk("★★ debug 场景**没有**代码铁律（规则 10 也不该在）",
    !grepl("规则 10", sys_debug, fixed = TRUE), "")

# =============================================================================
say("\n== B. 真模型拿到这条提示词之后，写出来的 HTML 长什么样 ==")
# =============================================================================
# 这是本次唯一"只有真厂商能回答"的问题。给它的任务**故意**包含 markdown 的
# 四种骨架（标题 / 列表 / 表格 / 加粗）—— 这四样正是用户抱怨"照贴原文"时看到
# 的东西（`## 标题`、`| 列 | 列 |`、`**粗**`）。
task <- paste0(
  "请写一段 Python 脚本，运行后在当前目录生成一个 HTML 文件 report.html。",
  "内容是本次分析的结论，必须包含：一个二级标题、一个三项的列表、",
  "一个两列的表格、一处加粗。**直接输出代码块**，不要解释。")
rb <- run_once(list(list(role = "system", content = sys_chat),
                    list(role = "user",   content = task)),
               max_tokens = BUDGET_TOK, thinking = FALSE)

chk("★★★ 这一轮真的拿到回复了（不是超时 / 不是报错）",
    is.null(rb$error) && nzchar(rb$text %||% ""), rb$error %||% "")
if (is.null(rb$error) && nzchar(rb$text %||% "")) {
  say("  ── 模型原文（前 900 字）──\n%s\n  ──────────",
      substr(rb$text, 1, 900))

  md  <- rb$text
  # 模型可能把 HTML 片段放进代码块里，也可能写成字符串拼接 —— 两种都在
  # 下面这套判据的覆盖范围内（判的是**它写出来的那些标签**）。
  has_pre_wrap <- grepl("<pre>\" + html.escape(md", md, fixed = TRUE) ||
                 grepl("html.escape(content", md, fixed = TRUE) ||
                 grepl("html.escape(md", md, fixed = TRUE) ||
                 grepl("markdown", md, ignore.case = TRUE)
  has_tags <- grepl("<h2", md, fixed = TRUE) || grepl("<h1", md, fixed = TRUE)
  has_tbl  <- grepl("<table", md, fixed = TRUE)
  has_lst  <- grepl("<ul", md, fixed = TRUE) || grepl("<ol", md, fixed = TRUE)

  say("  写出来的标签：标题=%s 表格=%s 列表=%s", has_tags, has_tbl, has_lst)

  chk("★★★ 它写的是**真的 HTML 标签**，不是把 markdown 原文塞进 <pre>",
      has_tags && has_tbl && has_lst, "")
  # ★★ 这条是这一节的核心，判据和线上那个现场一一对应：
  #    那次模型写的是 `"<pre>" + html.escape(content) + "</pre>"`，
  #    并且自己在注释里说"Markdown 以保留原文方式显示"。
  chk("★★★ 没有出现「把一整段 markdown 原文 escape 之后塞进 <pre>」那个形状",
      !has_pre_wrap,
      "出现了 html.escape(整段) / markdown 之类的写法 —— 用户看到的就是这个")

  # 顺带看一眼平台的渲染管线拿到这段回复会怎么处理（围栏那一支应当渲染成
  # 代码块 —— 那是正确行为，别把围栏里的东西当标签放出来）。
  html <- dsapp_md_chat_html(md, session = NULL, sid = NULL, cfg = tcfg)
  fenced <- grepl("```", md, fixed = TRUE)
  if (fenced) {
    chk("★★ 回复里有代码围栏时，管线把它渲染成代码块（围栏里的标签不外泄）",
        grepl("<pre", html) || grepl("<code", html), substr(html, 1, 160))
  }
}

# =============================================================================
say("")
if (ok) say("\033[32m真机验收通过\033[0m") else say("\033[31m有失败项\033[0m（%d 条）", nfail)
if (!nzchar(keep)) say("数据目录是临时的，进程退出即删。要留着排查就设 DSAPP_TEST_DATA。")
quit(status = if (ok) 0L else 1L)
