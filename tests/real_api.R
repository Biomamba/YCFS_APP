#!/usr/bin/env Rscript
# =============================================================================
# 真模型验收：让 agent 循环对着**真的** LLM 跑一遍
# =============================================================================
#
#     DSAPP_TEST_API_KEY=sk-xxx Rscript tests/real_api.R
#
# 和 tests/agent_loop.R 的分工：
#   * agent_loop.R 用假 LLM，验的是**状态机**——谁在什么时候推进哪一步。
#     它快、免费、离线，每次改动都该跑。
#   * 本文件用真模型，验的是假 LLM **验不到**的东西：真实的 SSE 分块边界、
#     真实的 finish_reason、流式增量读取、以及最要紧的一条 ——
#     模型到底认不认我们那套「代码围栏即工具调用」的协议。
#     假 LLM 的回复是我们自己写的，它当然认。
#
# ⚠️ 所以这个文件**不能**进 selftest.R / deploy.sh --check：
#    它要联网、要花钱、要跑几分钟，而且结果依赖模型的自由发挥。
#    它是部署后手工跑一次的验收，不是回归测试。
#
# ⚠️ API Key 从环境变量读，**不落盘、不进命令行参数**。写进文件或者写成
#    命令行参数都会被 ps / 历史记录看见。这是用户定的规矩（见
#    .Renviron.example 顶部），别为了方便破了它。
#
# 输出走 stderr：stdout 重定向到文件时是块缓冲的，卡住时一个字都看不到，
# 而"卡住"恰恰是这里最要报出来的情况。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)
suppressMessages(library(shiny))

say <- function(...) cat(sprintf(...), "\n", file = stderr())
ok <- TRUE; nfail <- 0L
chk <- function(name, cond) {
  if (isTRUE(cond)) say("  \033[32m✓\033[0m %s", name)
  else { ok <<- FALSE; nfail <<- nfail + 1L; say("  \033[31m✗ %s\033[0m", name) }
}

KEY <- Sys.getenv("DSAPP_TEST_API_KEY", "")
if (!nzchar(KEY)) {
  say("没有设 DSAPP_TEST_API_KEY，跳过真模型验收。")
  say("用法：DSAPP_TEST_API_KEY=sk-xxx Rscript tests/real_api.R")
  quit(status = 0L)
}

MODEL <- Sys.getenv("DSAPP_TEST_MODEL", "deepseek-flash")
BUDGET_S <- as.numeric(Sys.getenv("DSAPP_TEST_BUDGET_S", "600"))

# ---- 数据：一份有真实差异的模拟表达矩阵 --------------------------------------
#
# ⚠️ 默认用临时目录，进程一退就被 R 删掉。**排查失败时一定要设
#    DSAPP_TEST_DATA**：模型回了什么、循环为什么没动手，答案全在库里的
#    那条 assistant 消息里，而临时目录在你看之前就没了（踩过：第一次跑挂了，
#    想去看原文，目录已经消失）。
keep <- Sys.getenv("DSAPP_TEST_DATA", "")
tmp <- if (nzchar(keep)) {
  dir.create(keep, recursive = TRUE, showWarnings = FALSE); keep
} else {
  d <- tempfile("dsapp_real_"); dir.create(d, recursive = TRUE); d
}
Sys.setenv(DSAPP_DATA_ROOT = tmp)
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}
cfg <- dsapp_config(); dsapp_init_dirs(cfg)

app_lines <- readLines(file.path(app_dir, "app.R"), warn = FALSE)
eng_from <- grep("^dsapp_engine_new <- function", app_lines)[1]
eng_to   <- grep("^engine <- dsapp_engine_new", app_lines)[1]
writeLines(app_lines[eng_from:(eng_to - 1L)], (eng_src <- file.path(tmp, "engine.R")))
source(eng_src, local = globalenv())

set.seed(42)
n_gene <- 300
ctrl <- matrix(rnorm(n_gene * 3, 8, 1.2), n_gene, 3)
trt  <- matrix(rnorm(n_gene * 3, 8, 1.2), n_gene, 3)
# 挑 30 个基因做成真的差异表达，这样火山图上有东西可看
de <- sample(n_gene, 30)
trt[de, ] <- trt[de, ] + sample(c(-3, 3), 30, replace = TRUE)
expr <- data.frame(gene = sprintf("GENE%04d", seq_len(n_gene)),
                   ctrl1 = ctrl[, 1], ctrl2 = ctrl[, 2], ctrl3 = ctrl[, 3],
                   trt1 = trt[, 1], trt2 = trt[, 2], trt3 = trt[, 3])
# 放进共享上传区 —— 走的是用户上传那条路：会被软链进工作区，只读
upload <- file.path(cfg$files_dir, "expr.csv")
write.csv(expr, upload, row.names = FALSE)
Sys.chmod(upload, "0444")     # 和 files.R 上传落盘后的权限一致
say("数据就绪：%s（%d 基因 × 6 样本）", upload, n_gene)

# ---- 起模块 -----------------------------------------------------------------
state <- reactiveValues(
  api_key = KEY, vendor = "deepseek",
  base_url = "https://api.deepseek.com",
  model = MODEL, temperature = 0.3, max_tokens = 8192,
  thinking = NULL, reasoning_effort = NULL,
  chat_session_id = NULL,
  exec_target = "server", exec_env = "system",
  remote = list(host = "", port = 22, user = "", auth = "password",
                password = "", key_text = "", activate = "",
                workdir = "", verified = FALSE))
engine <- dsapp_engine_new(cfg)
say("模型 = %s", MODEL)

Q <- paste0("工作区里有 expr.csv（gene, ctrl1-3, trt1-3 六列，已经 log2 过）。",
            "请分两步做：",
            "第一步，算出每个基因在 trt 组和 ctrl 组的均值差，以及一个简单的",
            "差异显著性（比如 t 检验的 p 值），把结果存成 deg.csv；",
            "第二步，用 deg.csv 画一张火山图（横轴 log2FC，纵轴 -log10(p)），",
            "存成 volcano.png。做完告诉我结论。")

testServer(mod_chat_server, args = list(state = state, engine = engine), {
  observe({
    if (!isTRUE(engine$state$running)) return()
    invalidateLater(500)
    engine$poll()
  })

  pump <- function(secs, until = NULL, trace = TRUE) {
    t0 <- Sys.time(); last <- t0
    while (as.numeric(Sys.time() - t0, units = "secs") < secs) {
      try(session$elapse(300), silent = TRUE)
      Sys.sleep(0.10)
      s <- tryCatch(st$agent$status(), error = function(e) NULL)
      if (trace && as.numeric(Sys.time() - last, units = "secs") > 10) {
        last <- Sys.time()
        say("    [%3.0fs] agent=%-13s iter=%s/%s %s",
            as.numeric(Sys.time() - t0, units = "secs"),
            s$state %||% "?", s$iter %||% "?", s$max_iter %||% "?",
            substr(s$note %||% "", 1, 60))
      }
      if (!is.null(until) && isTRUE(until())) return(TRUE)
    }
    FALSE
  }

  # ⚠️ agent_mode 必须**先 FALSE 再 TRUE**，不能直接设 TRUE。
  #    mod_chat 里那个 observer 是 `observeEvent(input$agent_mode, ...,
  #    ignoreInit = TRUE)`，而 testServer 下第一次 setInputs 的值会被当成
  #    初始值被 ignoreInit 吃掉 —— 开关看着是打开的，`a$enabled` 其实还是
  #    FALSE。于是循环一声不吭：模型答了，没有任何任务被提交，状态条的 note
  #    是空的（on_llm_done 在 `if (!isTRUE(a$enabled)) return()` 就返回了）。
  #
  #    这个症状**极其像模型不配合**（"它答了但没给可执行代码块"），我第一次
  #    就照那个方向查了半天。所以下面直接断言 enabled，让它一旦没打开就报成
  #    "开关没生效"，而不是伪装成"模型的问题"。
  session$setInputs(target_kind = "server",
                    agent_mode = FALSE, input = Q)
  session$setInputs(agent_mode = TRUE)
  chk("开关真的打开了（a$enabled 为真）", isTRUE(st$agent$enabled))
  if (!isTRUE(st$agent$enabled)) {
    say("\n\033[31m开关没生效，后面测的都不是 agent 模式，直接停。\033[0m")
    quit(status = 1L)
  }

  say("\n\033[1m== 发任务，让循环自己跑 ==\033[0m")
  session$setInputs(send = 1)

  done <- pump(BUDGET_S, until = function() {
    !isTRUE(st$agent$active()) && !isTRUE(rv$streaming) &&
      !is.null(rv$session_id) && nrow(db_messages_get(rv$session_id,
                                                     con = dsapp_db(cfg))) > 1
  })
  if (!done) {
    s <- tryCatch(st$agent$status(), error = function(e) NULL)
    say("\n\033[31m时间到了还没跑完，卡在：state=%s iter=%s note=%s\033[0m",
        s$state %||% "?", s$iter %||% "?", s$note %||% "")
  }

  sid <- rv$session_id
  msgs <- db_messages_get(sid, con = dsapp_db(cfg))

  say("\n\033[1m--- 消息流 ---\033[0m")
  for (i in seq_len(nrow(msgs))) {
    body <- gsub("\n", " ", msgs$content[i])
    say("[%d] %-9s %s", msgs$id[i], msgs$role[i], substr(body, 1, 88))
  }

  say("\n\033[1m--- 执行过的代码 ---\033[0m")
  tk <- DBI::dbGetQuery(dsapp_db(cfg),
                        "SELECT id,status,lang,exit_code FROM tasks ORDER BY id")
  for (i in seq_len(nrow(tk))) {
    say("任务 #%d  %s  %s  退出码 %s", tk$id[i], tk$status[i], tk$lang[i],
        tk$exit_code[i])
  }

  say("\n\033[1m--- 工作区 ---\033[0m")
  ws <- dsapp_ws_dir(sid, cfg, create = FALSE)
  fs <- list.files(ws, all.files = FALSE, no.. = TRUE)
  for (f in fs) {
    p <- file.path(ws, f)
    say("  %-16s %8s  %s", f, dsapp_fmt_bytes(file.info(p)$size),
        if (isTRUE(file.info(p)$isdir)) "(目录)" else "")
  }

  # ---- 判定 ----------------------------------------------------------------
  # 这里断的是**结构性**的东西（有没有真的执行、循环有没有停、轮次有没有超），
  # 不验模型的措辞或统计方法 —— 那些每次跑都不一样，钉死了只会变成噪声。
  say("")
  tool_txt <- paste(msgs$content[msgs$role == "tool"], collapse = "\n")
  chk("★ 模型真的被叫起来了（有助手回复）", any(msgs$role == "assistant"))
  chk("★ 至少执行了一个任务（模型认了围栏协议）", nrow(tk) >= 1)
  chk("★ 执行结果回喂给了模型（有 tool 消息）", any(msgs$role == "tool"))
  chk("★ 回喂里带着真实的 stdout/stderr",
      grepl("stdout|stderr", tool_txt))
  chk("★ 循环停下来了（没撞时间预算）", done)
  chk("★ 循环正常收尾（模型给出结论，不是撞上限/被停）",
      grepl("结论", st$agent$status()$note %||% "", fixed = TRUE))
  chk("轮次在 6 以内", isTRUE(st$agent$status()$iter <= 6))
  chk("★ 第一步的产物 deg.csv 落在工作区里",
      "deg.csv" %in% fs)
  chk("★ 第二步读到了第一步的产物（火山图输出了）",
      any(c("volcano.png") %in% fs))
  chk("没有任务卡在 running",
      !any(tk$status == "running"))
  say("\n工作区：%s", ws)
})

say("\n\033[1m%s（失败 %d）\033[0m",
    if (ok) "真模型验收通过" else "有失败", nfail)
say("（数据留在 %s，要看产物就自己去翻）", tmp)
quit(status = if (ok) 0L else 1L)
