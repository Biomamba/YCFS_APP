#!/usr/bin/env Rscript
# =============================================================================
# V15.3 真机验收：三件**只有真厂商**才能回答的事
# =============================================================================
#
#     DSAPP_TEST_API_KEY=sk-xxx Rscript tests/v153_real_check.R
#
# 可选环境变量：
#     DSAPP_TEST_MODEL      默认 deepseek-flash（要和 Key 那家对得上）
#     DSAPP_TEST_BASE_URL   默认 https://api.deepseek.com
#     DSAPP_TEST_DATA       留着数据目录，排查用（不设就是临时目录，跑完就删）
#
# ── 为什么非要真跑一趟 ──────────────────────────────────────────────────────
#
# 假 LLM 验的是"我们按约定的格式发出去、按约定的格式收回来"。它回答不了：
#
#   ① **厂商真实那条 400 长什么样。** V15.3 那颗「直接帮我设置」按钮的判据是
#      `dsapp_maxtok_advice(rv$error)`，而它靠正则认几种"说了上限"的写法。
#      自检里喂的是**我自己写的**那句话 —— 验的是"我写的话我自己认识"
#      （selftest-green-is-not-coverage 的教训，本仓栽过两次）。厂商换一个
#      措辞（"must be less than or equal to" / "maximum is" / "不能超过"），
#      解析器就静默失效：按钮不出现，而**没有任何报错**。
#
#   ② **真实的思维链是不是一块一块流出来的。** V15.3 item 3 把思考过程改成
#      "追加，不重画"，前提是 `dsapp_llm_poll()` 真的会**分多次**返回增量。
#      假 LLM 的一次性响应测不出这件事（所以才有 slow.json 慢放）。
#
#   ③ **真模型写 HTML 标签时的实际形状。** 用户报的「HTML 标签变字面文字」
#      来自线上真实的模型输出。模型很可能把 `<h4>` 包在 ```html 代码围栏里
#      —— 那样的话白名单（转义之后、commonmark 之前那一步）根本看不到它，
#      用户看到的仍然是一个代码块。这是**只有真模型**才会暴露的形状。
#
# ── 三条闸，一条都不能少 ────────────────────────────────────────────────────
#
#   ⚠️ Key 只从环境变量读，**不落盘、不进命令行参数**（`ps` 和 shell 历史都
#      看得到 argv）。这是用户定的规矩，见 .Renviron.example 顶部。
#   ⚠️ 数据目录强制在临时目录下：跑真模型会往库里写消息，绝不能碰线上那份。
#   ⚠️ 提示词一律是"回一个字"这种量级 —— 这是一次验收，不是一次生成。
#      单条预算靠 max_tokens 卡住，见下面 BUDGET_TOK。
#
# 输出一律走 stderr：stdout 重定向到文件时是块缓冲的，卡住时一个字都看不到，
# 而"卡住"恰恰是这里最要报出来的情况。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)
suppressMessages(library(shiny))

ok <- TRUE; nfail <- 0L
say <- function(...) cat(sprintf(...), "\n", file = stderr())
chk <- function(name, cond) {
  if (isTRUE(cond)) say("  \033[32m✓\033[0m %s", name)
  else { ok <<- FALSE; nfail <<- nfail + 1L; say("  \033[31m✗ %s\033[0m", name) }
}
# 「看到了、值得记一笔，但**不是**被测代码的锅」的那种结论走这里。
# ⚠️ 别把这类东西写成 chk：真模型的措辞、它听不听提示词，都不是这个应用能
#    决定的。混进失败项里，读的人会以为部署坏了。
warn <- function(...) say(paste0("  \033[33m⚠\033[0m ", ...))

KEY <- Sys.getenv("DSAPP_TEST_API_KEY", "")
if (!nzchar(KEY)) {
  say("没有设 DSAPP_TEST_API_KEY，跳过真机验收。")
  say("用法：DSAPP_TEST_API_KEY=sk-xxx Rscript tests/v153_real_check.R")
  quit(status = 0L)
}
MODEL    <- Sys.getenv("DSAPP_TEST_MODEL", "deepseek-flash")
BASE_URL <- Sys.getenv("DSAPP_TEST_BASE_URL", "https://api.deepseek.com")

# 单条回复的上限。这里全是"回一个字"的提示词，给 512 绰绰有余 ——
# 给大了万一模型不理提示词，账单是真的。
BUDGET_TOK <- 512L
# 一个**必然超过任何厂商上限**的 max_tokens，用来把那条 400 钓出来。
# 提示词只有几个字，就算厂商真的收下了这个数，回的也还是几个字。
ABSURD_TOK <- 100000000L

# ---- 数据目录：强制临时 -----------------------------------------------------
keep <- Sys.getenv("DSAPP_TEST_DATA", "")
tmp <- if (nzchar(keep)) {
  dir.create(keep, recursive = TRUE, showWarnings = FALSE); keep
} else {
  d <- tempfile("dsapp_real_v153_"); dir.create(d, recursive = TRUE); d
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

# ---- 一个小工具：把一次请求跑到底，把所有增量攒起来 --------------------------
#
# ⚠️ 返回**增量序列**，不只是最后那段文字：B 那一条要判的就是"分了几个增量"。
#    只留最后结果的话，"一次吐完"和"一百次吐完"长得一模一样。
run_once <- function(prompt, max_tokens = BUDGET_TOK, thinking = TRUE,
                     timeout_s = 180) {
  h <- dsapp_llm_start(
    api_key = KEY,
    messages = list(list(role = "user", content = prompt)),
    model = MODEL, cfg = tcfg, temperature = 0.3,
    max_tokens = max_tokens, base_url = BASE_URL,
    thinking = thinking)
  on.exit(try(dsapp_llm_stop(h), silent = TRUE), add = TRUE)

  text <- ""; reason <- ""
  n_text <- 0L; n_reason <- 0L
  t0 <- Sys.time()
  repeat {
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) > timeout_s) {
      return(list(text = text, reasoning = reason, error = "本地超时",
                  n_text = n_text, n_reason = n_reason, timed_out = TRUE))
    }
    p <- dsapp_llm_poll(h)
    if (nzchar(p$text %||% ""))   { text   <- paste0(text, p$text);   n_text   <- n_text + 1L }
    if (nzchar(p$reasoning %||% "")) {
      reason <- paste0(reason, p$reasoning); n_reason <- n_reason + 1L
    }
    if (isTRUE(p$done)) {
      return(list(text = text, reasoning = reason, error = p$error,
                  n_text = n_text, n_reason = n_reason, timed_out = FALSE))
    }
    Sys.sleep(0.05)
  }
}

# =============================================================================
say("\n== A. 厂商真实那条 400，解析器认不认 ==")
# =============================================================================
# 这一步是整个真机验收里**最值钱**的一条：它验的是"换一家厂商/换一个措辞，
# 那颗按钮还会不会亮"。假的 400 证明不了这件事。
ra <- run_once("回复一个字：好", max_tokens = ABSURD_TOK, thinking = FALSE)

if (is.null(ra$error) || !nzchar(ra$error)) {
  say("  ⚠️ 厂商**收下**了 max_tokens=%d，没回 400。这一条无从判起 ——",
      ABSURD_TOK)
  say("     不是失败，但也没验到东西。换一家厂商、或者把 DSAPP_TEST_MODEL")
  say("     指到一个上限更小的模型再跑一次。")
} else {
  say("  厂商原文：%s", substr(gsub("[\r\n]+", " ", ra$error), 1, 300))
  adv <- dsapp_maxtok_advice(ra$error)
  chk("★★★ 厂商这条真实 400 解析得出 max_tokens 的上限", !is.null(adv),
      "adv=NULL —— 措辞没被认出来，界面上的按钮**不会亮**")
  if (!is.null(adv)) {
    chk("★★ 解出来的参数就是 max_tokens", identical(adv$param, "max_tokens"),
        adv$param)
    say("  解析出的上限 = %s", format(adv$max, scientific = FALSE))
    chk("★★ 解出来的上限是个有限的正常数", is.finite(adv$max) && adv$max > 0,
        adv$max)
    # ⚠️ 上限必须**比我们发出去的那个小**，否则说明它认错了数（比如把
    #    "至少"看成"至多"，或者从别处抠了一个数出来）。
    chk("★★★ 解出来的上限 < 我们发出去的那个（说明是从响应体里读的，不是瞎认）",
        adv$max < ABSURD_TOK, sprintf("解出 %s，发出 %d", adv$max, ABSURD_TOK))
  }
}

# =============================================================================
say("\n== B. 真实思维链是不是分多次流出来的 ==")
# =============================================================================
# V15.3 item 3 把思考过程改成"追加，不重画"，这个改法**成立的前提**是
# dsapp_llm_poll() 每次只交一小段增量。要是一次性全给，"追加"和"重画"
# 在用户眼里没有区别（只是恰好不闪而已），而那说明流式这条路其实没走通。
rb <- run_once("一步一步地想：37 乘 89 等于多少？先写思路再给答案。",
               max_tokens = BUDGET_TOK, thinking = TRUE, timeout_s = 240)

chk("★★★ 这一轮真的拿到回复了（不是超时 / 不是报错）",
    is.null(rb$error) && nzchar(rb$text %||% ""), rb$error %||% "")
if (is.null(rb$error)) {
  say("  正文 %d 字（%d 个增量），思维链 %d 字（%d 个增量）",
      nchar(rb$text), rb$n_text, nchar(rb$reason %||% ""), rb$n_reason)
  chk("★★ 思维链非空（模型真的走了思考模式）", nzchar(rb$reason %||% ""),
      sprintf("思维链 %d 字", nchar(rb$reason %||% "")))
  # ★★ 这条是 B 的核心：**分多次**。一次给完的话，"往外流"是假的。
  chk("★★★ 思维链是**分多次**交给界面的（≥3 个增量）—— 「往外流」不是装的",
      rb$n_reason >= 3L, sprintf("只有 %d 个增量", rb$n_reason))
  chk("★ 正文也是分多次给的（≥2 个增量）", rb$n_text >= 2L,
      sprintf("只有 %d 个增量", rb$n_text))
}

# =============================================================================
say("\n== C. 真模型写 HTML 标签时的实际形状 ==")
# =============================================================================
# 用户报的就是这个：模型在回复里写了 `<h4>`，界面上显示的却是字面的 `&lt;h4&gt;`。
# 白名单能放行的前提是 commonmark **看得见**那个标签 —— 而模型很可能把它
# 包在 ```html 围栏里，那样它连白名单都到不了，用户看到的仍然是一个代码块。
#
# 所以这里问两次，看真模型给的是哪一种形状。
prompt_bare <- paste0(
  "请直接输出下面这一行，不要加任何解释、不要加代码围栏：\n",
  "<h4>验收标题</h4>")
rc <- run_once(prompt_bare, max_tokens = BUDGET_TOK, thinking = FALSE)
say("  ── 原文 ──\n%s\n  ──────────", substr(rc$text %||% "", 1, 400))

fenced <- grepl("```", rc$text %||% "")
if (fenced) {
  # ⚠️ 这条**不判失败**：让模型别加围栏是提示词的事，不是应用能决定的。
  #    但它是个要紧的观察结果 —— 围栏里的 `<h4>` 连白名单都到不了，
  #    用户在界面上看到的仍然是一个代码块。真是这样的话，item 6 在
  #    **真实输出**上只解决了一半，得记下来。
  warn("真模型把 `<h4>` 包进了代码围栏 —— 白名单看不到它，界面上会是一个代码块。")
  warn("这不是渲染管线的问题（管线对围栏的处理是对的），是模型没听提示词。")
} else {
  say("  模型是**裸着**输出的（没有代码围栏）—— 这正是白名单能起作用的那种形状")
}
chk("★★★ 模型回的正文里有 `<h4>` 这个标签", grepl("<h4>", rc$text %||% "",
                                                    fixed = TRUE),
    substr(rc$text %||% "", 1, 120))

if (nzchar(rc$text %||% "")) {
  html <- dsapp_md_chat_html(rc$text, session = NULL, sid = NULL, cfg = tcfg)
  if (!fenced) {
    chk("★★★ 真模型的这段输出过完渲染管线**真的变成了 <h4> 元素**",
        grepl("<h4[ >]", html), substr(html, 1, 200))
    chk("★★ 而且没有留下 `&lt;h4&gt;` 那种字面文字",
        !grepl("&lt;h4&gt;", html, fixed = TRUE), substr(html, 1, 200))
  } else {
    # 围栏那一支：管线**应该**把它渲染成代码块（那是正确行为），这里只确认
    # 它没有反过来把围栏里的东西当标签放出去。
    chk("★★ 围栏那一支渲染成了代码块（这是对的，别把 `<pre>` 里的东西放出来）",
        grepl("<pre", html) || grepl("<code", html), substr(html, 1, 200))
  }
}

# =============================================================================
say("")
if (ok) say("\033[32m真机验收通过\033[0m") else say("\033[31m有失败项\033[0m（%d 条）", nfail)
if (!nzchar(keep)) say("数据目录是临时的，进程退出即删。要留着排查就设 DSAPP_TEST_DATA。")
quit(status = if (ok) 0L else 1L)
