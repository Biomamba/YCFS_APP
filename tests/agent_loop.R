#!/usr/bin/env Rscript
# =============================================================================
# agent 循环的端到端测试
# =============================================================================
#     Rscript tests/agent_loop.R        # 在应用目录下跑
#
# selftest.R 只测循环里**不依赖响应式**的那几块（挑块、判风险、拼回喂文本、
# 去重认领）。循环真正容易错的地方 —— 状态在几个 observe 之间怎么流转、
# 任务结束时谁去写库、回喂之后谁发起下一轮 —— 读代码看不出来，必须真的跑。
#
# 这里用 shiny::testServer 起一个真的模块实例，配 tests/fake_llm.py 那个
# 脚本化的假 LLM 服务端，让循环真的走完两轮：
#     第 1 轮：模型给一段 R 代码 → 平台执行 → 结果回喂
#     第 2 轮：模型给一段没有代码的结论 → 循环结束
#
# 它抓到过的真 bug（都不是看代码能看出来的）：
#   * 心跳 observe 写成"空闲时先 return"，定时器根本没排上，循环提交完任务
#     就永久沉默 —— 任务早就 success 了，状态条一直显示"执行中"。
#   * 工作区名用 as.integer(sid) 拼，真实对话号转出来是 NA，所有对话共用
#     一个 chat-NA 目录，隔离整个失效。
#   * 三处 observe 自读自写同一个 reactive，导致整个 R 进程卡死。
# 所以这份测试别删。
#
# 输出一律走 stderr：R 的 stdout 重定向到文件时是块缓冲的，进程卡住时一个
# 字都看不到 —— 而"卡住"恰恰是这个测试最要报出来的情况。
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

# ---- 起假 LLM 服务端 --------------------------------------------------------
tmp <- tempfile("dsapp_loop_")
dir.create(tmp, recursive = TRUE)
queue_dir <- file.path(tmp, "queue"); dir.create(queue_dir)
served_file <- file.path(tmp, "served.txt")
port_file <- file.path(tmp, "port.txt")

if (!nzchar(Sys.which("python3"))) {
  say("找不到 python3，跳过端到端测试。")
  quit(status = 0L)
}
srv <- processx::process$new(
  "python3", c(file.path(app_dir, "tests", "fake_llm.py"),
               queue_dir, served_file, port_file),
  stdout = "|", stderr = "|")
on.exit(if (srv$is_alive()) srv$kill(), add = TRUE)

port <- NULL
for (i in 1:100) {
  if (file.exists(port_file)) {
    p <- suppressWarnings(as.integer(readLines(port_file, warn = FALSE)[1]))
    if (!is.na(p) && p > 0) { port <- p; break }
  }
  Sys.sleep(0.05)
}
if (is.null(port)) {
  say("假 LLM 服务端没起来：\n%s", srv$read_error() %||% "")
  quit(status = 1L)
}
say("假 LLM 服务端在 127.0.0.1:%d", port)

# ---- 装应用 ----------------------------------------------------------------
Sys.setenv(DSAPP_DATA_ROOT = tmp)
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}
# ⚠️⚠️ 这个名字**不能**叫 `cfg`。
#
#    `shiny::testServer(mod, args, { ... })` 把这段 `{...}` 放在**模块 server
#    函数的执行帧里**求值（这正是它能让 testServer 里直接摸到 input/output/
#    session 的原因）。于是模块里那句
#        cfg <- function() dsapp_config_user(state$user_id, dsapp_config())
#    会**盖住**这里的全局 `cfg` —— 名字一样，词法上更近的那个赢。
#    症状：`dsapp_db(cfg)` 收到一个闭包，抛
#        object of type 'closure' is not subsettable
#    而且**指不到源头**：报错在 dsapp_db 里，看起来像数据库层坏了。
#    2026-09-17 量到：拿 V13.4 的归档跑这份测试是**同一个**错，所以这个坑从
#    V13.3（`cfg <- function()` 那次改动）就在，只是这条测试从那时起没人跑过。
#    往后加变量名时同样要当心：**模块里有的局部名，这里都不能用**。
tcfg <- dsapp_config(); dsapp_init_dirs(tcfg)

# 执行引擎住在 app.R 里（不在 R/ 下）。直接 source 整个 app.R 会连带起一个
# Shiny 服务，所以只把 dsapp_engine_new 那一段抠出来 source —— 测的仍然是
# 真代码，不是复制品。
app_lines <- readLines(file.path(app_dir, "app.R"), warn = FALSE)
eng_from <- grep("^dsapp_engine_new <- function", app_lines)[1]
eng_to   <- grep("^engine <- dsapp_engine_new", app_lines)[1]
if (is.na(eng_from) || is.na(eng_to)) {
  say("app.R 里找不到 dsapp_engine_new 的定义，测试需要更新。"); quit(status = 1L)
}
writeLines(app_lines[eng_from:(eng_to - 1L)], (eng_src <- file.path(tmp, "engine.R")))
source(eng_src, local = globalenv())

# ---- 假 LLM 的脚本 ---------------------------------------------------------
#
# 用 jsonlite 拼 SSE，不手写转义。手写版本踩过一次：换行被转成了字面的
# `\n` 两个字符（而不是 JSON 的换行转义），模型"写"出来的代码块整个挤在
# 一行里，被测代码当然找不到可执行块。测出来的红跟产品无关，纯粹是夹具
# 自己在撒谎 —— 而那种红最难查，因为方向是反的。
sse <- function(content, finish = "stop") {
  chunk <- function(obj)
    paste0("data: ", jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null"),
           "\n\n")
  paste0(
    chunk(list(choices = list(list(delta = list(content = content),
                                   finish_reason = NULL)))),
    chunk(list(choices = list(list(delta = NULL, finish_reason = finish)))),
    "data: [DONE]\n\n")
}
set_queue <- function(...) {
  unlink(list.files(queue_dir, full.names = TRUE))
  items <- list(...)
  for (i in seq_along(items)) {
    writeLines(sse(items[[i]]), file.path(queue_dir, sprintf("%03d.txt", i)))
  }
  writeLines("0", served_file)
}
served_n <- function() {
  suppressWarnings(as.integer(readLines(served_file, warn = FALSE)[1])) %||% 0L
}

R1 <- paste0("先看一下工作目录里有什么。\n\n",
             "```r\n",
             "cat(\"HELLO-FROM-ROUND-1\\n\")\n",
             "write.csv(data.frame(a = 1:3), \"round1_out.csv\", row.names = FALSE)\n",
             "```\n")
R2 <- "第一步跑通了，产出 round1_out.csv。分析完成，这里是结论。"

# ---- 起模块 ----------------------------------------------------------------
#
# ⚠️ 必须有**真实账号**，state$user_id / state$user 不能省。
#    item 7 给对话加了一道只读闸门：`if (!can_write() && !is.null(rv$session_id))`
#    —— 共享进来的人不能发言。而 can_write() 是问"这个对话对**你**是什么身份"，
#    账号为空时 dsapp_session_role() 一律返回 none（fail closed，这是对的）。
#
#    这个夹具原本没有账号（写在账号体系之前），于是：第一条消息发得出去
#    （那时 rv$session_id 还是 NULL，闸门整个跳过、顺手建了个**无主**对话），
#    第二条就被自己的闸门拦下，还提示"这是别人共享给你的对话"。
#    症状是 agent 循环压根不启动（假 LLM 的 served 停在 0），十五条断言全红，
#    而报错方向完全指向别处。2026-09-14 查出来，修的是夹具不是产品代码 ——
#    真实路径上 state$user_id 一定非空（app.R 的 on_login 两条路都会设）。
u0 <- dsapp_user_create("端到端测试", "e2e@dsapp.invalid", "00000000003",
                        "测试", password = "test1234")
if (!isTRUE(u0$ok)) { say("建不出测试账号：%s", u0$msg %||% "?"); quit(status = 1L) }

state <- reactiveValues(
  user_id = as.integer(u0$user$id), user = u0$user,
  api_key = "fake-key", vendor = "deepseek",
  base_url = sprintf("http://127.0.0.1:%d", port),
  model = "fake-model", temperature = 0.3, max_tokens = 4096,
  thinking = NULL, reasoning_effort = NULL,
  chat_session_id = NULL,
  exec_target = "server", exec_env = "system",
  remote = list(host = "", port = 22, user = "", auth = "password",
                password = "", key_text = "", activate = "",
                workdir = "", verified = FALSE))
engine <- dsapp_engine_new(tcfg)

testServer(mod_chat_server, args = list(state = state, engine = engine), {
  # 复刻 app.R 里那个引擎轮询 observer。没有它，任务跑完了也没人把结果写回
  # tasks 行 —— agent 循环读的正是那一行，会一直等下去，"循环不动"的锅
  # 就扣在被测代码头上了。
  observe({
    if (!isTRUE(engine$state$running)) return()
    invalidateLater(500)
    engine$poll()
  })

  # 推进模拟时钟。testServer 里所有的定时器（200ms 的流式轮询、1s 的 agent
  # 心跳、500ms 的引擎轮询）都靠 session$elapse() 走。
  #
  # peak_iter 是**采样到的**最大轮次。不能等循环停下来再去读 st$agent$iter ——
  # a$finish() 会把它清零（`a$iter <- 0L`，那是对的：iter 说的是"本次循环跑
  # 到第几轮"，循环结束了就没有"第几轮"了）。所以在结束之后去读，永远读到 0。
  #
  # 这里踩过一次：`until` 写成 `!active() && iter > 0`，两个条件在时间上互斥
  # （active 时 iter 才非零，iter 归零时已经不 active 了），于是它永远不成立，
  # 每段 pump 都白等满整个超时。更坏的是下游那条"轮次控制在 6 以内"的断言
  # 读到的也是 0，`0 <= 6` 恒真 —— 一条永远不会红的断言比没有断言更糟，
  # 它占着"这里测过了"的位置。
  peak_iter <- 0L
  pump <- function(secs, until = NULL, trace = FALSE) {
    t0 <- Sys.time(); last <- t0
    while (as.numeric(Sys.time() - t0, units = "secs") < secs) {
      try(session$elapse(300), silent = TRUE)
      Sys.sleep(0.10)
      s <- tryCatch(st$agent$status(), error = function(e) NULL)
      if (!is.null(s)) peak_iter <<- max(peak_iter, s$iter %||% 0L)
      if (trace && as.numeric(Sys.time() - last, units = "secs") > 3) {
        last <- Sys.time()
        say("    [%.0fs] agent=%s iter=%s/%s note=%s | streaming=%s served=%d",
            as.numeric(Sys.time() - t0, units = "secs"),
            s$state %||% "?", s$iter %||% "?", s$max_iter %||% "?",
            s$note %||% "", isTRUE(rv$streaming), served_n())
      }
      if (!is.null(until) && isTRUE(until())) return(TRUE)
    }
    is.null(until) || isTRUE(until())
  }

  session$setInputs(target_kind = "server",
                    agent_mode = FALSE, input = "帮我跑一个两步的分析")

  say("\n\033[1m== 默认关闭时不该自动执行 ==\033[0m")
  set_queue("手动模式的回答，没有代码块。")
  session$setInputs(send = 1)
  pump(20)
  chk("助手回复落库了",
      any(db_messages_get(state$chat_session_id, con = dsapp_db(tcfg))$role == "assistant"))
  chk("没有 tool 消息（没自动执行）",
      !any(db_messages_get(state$chat_session_id, con = dsapp_db(tcfg))$role == "tool"))
  chk("tasks 表是空的",
      DBI::dbGetQuery(dsapp_db(tcfg), "SELECT COUNT(*) n FROM tasks")$n == 0)

  sid <- state$chat_session_id
  say("  对话号 = %s", sid)
  say("  工作区 = %s", dsapp_ws_name(sid))

  say("\n\033[1m== 打开 agent 开关，走两轮 ==\033[0m")
  session$setInputs(agent_mode = TRUE)
  set_queue(R1, R2)
  session$setInputs(input = "帮我跑一个两步的分析")
  session$setInputs(send = 2)
  pump(60, trace = TRUE,
       until = function() !isTRUE(st$agent$active()) && peak_iter > 0L)

  msgs <- db_messages_get(sid, con = dsapp_db(tcfg))
  say("\n--- 消息流 ---")
  for (i in seq_len(nrow(msgs))) {
    say("  [%d] %-9s %s", msgs$id[i], msgs$role[i],
        substr(gsub("\n", " ", msgs$content[i]), 1, 66))
  }

  chk("★ 出现了 tool 消息（执行结果回喂了）", any(msgs$role == "tool"))
  # 恰好一条：多出来的 tool 消息只可能是平台提示（块被跳过 / 被拦截 / 被截断），
  # 这一轮脚本不该触发其中任何一种。数量对不上就说明循环走了意料之外的支路。
  chk("★ 只有一条 tool 消息，没有多余的平台提示",
      identical(sum(msgs$role == "tool"), 1L))
  tool_txt <- paste(msgs$content[msgs$role == "tool"], collapse = "\n")
  chk("★ 回喂头一行是【执行结果 · 任务 #N】", grepl("【执行结果 · 任务 #", tool_txt))
  chk("★ 回喂里带着真实 stdout", grepl("HELLO-FROM-ROUND-1", tool_txt, fixed = TRUE))
  chk("★ 回喂里列了产出的文件", grepl("round1_out.csv", tool_txt, fixed = TRUE))
  chk("状态如实写成成功", grepl("成功", tool_txt))

  tk <- DBI::dbGetQuery(dsapp_db(tcfg),
                        "SELECT id, status, lang, session_id FROM tasks ORDER BY id")
  say("\n--- tasks 表 ---")
  for (i in seq_len(nrow(tk)))
    say("  #%d %s %s %s", tk$id[i], tk$status[i], tk$lang[i], tk$session_id[i])
  chk("★ 真的有任务被提交执行", nrow(tk) >= 1)
  chk("★ 任务停在终结态（不是 running）",
      nrow(tk) >= 1 && all(tk$status %in% c("success", "failed", "error", "timeout")))
  chk("任务挂在这个对话上", all(as.character(tk$session_id) == as.character(sid)))
  chk("任务是 R 语言", nrow(tk) >= 1 && identical(tk$lang[1], "R"))
  chk("提交的代码就是模型写的那段",
      grepl("HELLO-FROM-ROUND-1",
            db_task_get(tk$id[1], con = dsapp_db(tcfg))$code, fixed = TRUE))

  ws <- dsapp_ws_dir(sid, tcfg, create = FALSE)
  say("  工作区路径 = %s", ws)
  chk("★ 工作区按对话号命名，不是 chat-NA",
      !is.na(ws) && !grepl("chat-NA", ws, fixed = TRUE))
  chk("★ 产物落在对话工作区里", file.exists(file.path(ws, "round1_out.csv")))
  chk("产物没有自动进共享区",
      !file.exists(file.path(tcfg$files_dir, "round1_out.csv")))

  chk("★ 循环最终停下来（没卡在 generating / waiting）", !isTRUE(st$agent$active()))

  st_note <- st$agent$status()$note %||% ""
  say("  收尾说明 = %s", st_note)
  # 停下来的**理由**要断言，不能只看"停了"。轮次上限、总时长上限、用户停止
  # 都会让 active 变 FALSE，但它们全都是失败路径 —— 只查 active 的话，
  # "循环把 6 轮额度跑爆了"和"模型给出结论正常收尾"看起来一模一样。
  chk("★ 是因为模型给出结论而收尾，不是撞上限/被停",
      grepl("结论", st_note, fixed = TRUE))
  chk("采样到循环在数轮次（active 期间 iter 涨过）", peak_iter >= 1L)
  chk("轮次没越过上限", peak_iter <= 6L)
  # 这条是整段测试里最硬的一条：假 LLM 每收到一次请求就把计数器 +1，
  # 恰好 2 说明"第一轮要代码 → 执行 → 结果回喂 → 第二轮给结论"这条链
  # 一步不多一步不少地走完了。循环空转（拿着同一结果反复问）会让它变成 3、
  # 4、5……；循环根本没推进（结果没回喂）会停在 1。
  chk("★ 恰好两轮请求（一次没多、一次没少）", identical(served_n(), 2L))
  chk("★ 助手消息恰好 3 条（1 条手动 + 循环的 2 轮）",
      identical(sum(msgs$role == "assistant"), 3L))
})

# ---- item 1：运行中的任务要立刻出现在任务页 ---------------------------------
#
# 用户原话："运行过程中在任务界面并不能看到任务"。根因在 mod_tasks 的自动刷新
# observer：原来的写法是
#     observe({ refresh(); if (running) invalidateLater(1500) })
# `refresh()` 只**读**不写，依赖值永远是 0 —— 定时器只是让这个 observer 自己
# 每 1.5 秒空跑一趟，下游的 tasks() 一次都没失效过。用户看到的就是"任务明明
# 在跑，切到任务页却是空的 / 一直停在旧状态"。
#
# 这条测试复刻那个时序：**先把列表渲染出来**（此刻库里确实没有任务），再插
# 一条 running 的、把引擎置成"正在跑"，然后只走时钟、不碰任何输入 —— 列表
# 必须自己长出来。旧代码在这条上必红。
say("\n\033[1m== 运行中的任务在任务页可见（item 1）==\033[0m")

uid2 <- dsapp_user_create("任务页测试", "taskpage@dsapp.invalid", "00000000002",
                          "测试", password = "test1234")$user$id
sid2 <- db_session_create("任务页测试用对话", user_id = uid2, con = dsapp_db(tcfg))
state2 <- reactiveValues(user_id = uid2,
                         user = dsapp_user_by_id(uid2, con = dsapp_db(tcfg)))
engine2 <- dsapp_engine_new(tcfg)
chk("测试账号建出来了", !is.null(uid2) && !is.na(uid2))

testServer(mod_tasks_server, args = list(state = state2, engine = engine2), {
  # ⚠️ 断言落在 output$count 上，不是 output$tbl。DT 默认走**服务端**处理，
  #    初始载荷里根本没有行数据（payload 只有 1.4KB，连 "data" 这个键都没有），
  #    拿标题去 grep 渲染结果永远是 FALSE —— 一条恒为假的断言。
  #    count 读的是同一个 tasks()，而且"共 N 条执行记录"正是用户看到的那个数。
  n_of <- function() {
    h <- as.character(output$count)[1]
    suppressWarnings(as.integer(sub(".*共 ([0-9]+) 条.*", "\\1", h)))
  }

  session$setInputs(f_status = "", f_kw = "")
  session$elapse(100)
  n0 <- n_of()
  say("  渲染完成时：共 %s 条", n0)
  chk("列表先渲染出来了（此时还没有新任务）", !is.na(n0))

  # 插一条 running 的任务，并把引擎置成"正在跑" —— 这正是用户在言出法随页
  # 点了「确认执行」之后、切到任务页之前那一刻的库状态。
  tid2 <- db_task_create("TASK-RUNNING-1", "Sys.sleep(60)", "R",
                         session_id = sid2, con = dsapp_db(tcfg))
  db_task_status(tid2, "running", con = dsapp_db(tcfg))
  engine2$state$running <- TRUE
  engine2$state$task_id <- tid2

  # 只走时钟。**不 setInputs**：用户没点刷新，界面得自己更新。
  session$elapse(300)
  n1 <- n_of()
  say("  引擎转 running 后：共 %s 条", n1)
  chk("★ 引擎状态一变，列表立刻多出这条任务（不用手点刷新）",
      !is.na(n1) && !is.na(n0) && n1 == n0 + 1L)

  # 再走 1.5 秒定时器那条路：引擎状态不再变，库里又多了**别人**提交的任务。
  # 这条路单独测，因为上面那条是靠 `engine$state$running` 的响应式依赖触发的，
  # 定时器坏掉了它照样绿。
  tid3 <- db_task_create("TASK-RUNNING-2", "Sys.sleep(60)", "R",
                         session_id = sid2, con = dsapp_db(tcfg))
  db_task_status(tid3, "running", con = dsapp_db(tcfg))
  session$elapse(200)
  n2 <- n_of()
  session$elapse(2000)          # 越过 invalidateLater(1500)
  n3 <- n_of()
  say("  定时器前一拍：共 %s 条 → 越过后：共 %s 条", n2, n3)
  chk("★ 1.5 秒定时器那条路也是通的（别人提交的任务也会自己冒出来）",
      !is.na(n3) && !is.na(n2) && n3 == n2 + 1L)
  chk("★ 跑着的任务状态就是 running（不是等跑完才出现）",
      identical(db_task_get(tid2, con = dsapp_db(tcfg))$status, "running"))
})

unlink(tmp, recursive = TRUE)
say("\n\033[1m%s（失败 %d）\033[0m", if (ok) "全部通过" else "有失败", nfail)
quit(status = if (ok) 0L else 1L)
