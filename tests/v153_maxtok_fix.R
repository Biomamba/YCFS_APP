#!/usr/bin/env Rscript
# =============================================================================
# V15.3 item 2 端到端：厂商真回 400 → 「直接帮我设置」→ 下一次请求真的变了
# =============================================================================
#     Rscript tests/v153_maxtok_fix.R        # 在应用目录下跑
#
# ── 这份测试要回答的问题 ────────────────────────────────────────────────────
#
# 用户原话：「运行时关于模型设置的问题报错『HTTP 400：Field 'max_tokens' must
# at most 65536』能不能直接亮一个按钮『直接帮我设置』，然后用户点击后就可以
# 自动更改并应用新的模型服务配置」。
#
# 自检（selftest.R）里那一节测的是**解析器**：喂一句写好的报错原文，看它解出
# 什么。那证明不了"厂商那条 400 会变成这句话"—— 把手写的字符串喂给解析器，
# 验的是"我写的那句话我自己认识"（selftest-green-is-not-coverage 的教训，
# 本仓已经栽过两次）。所以这里让 httr2 真的收到一个 HTTP 400、真的从响应体里
# 抠出 message、真的走完整条链路。
#
# ── 四步，一步都不能少 ──────────────────────────────────────────────────────
#
#   ① 真 400 进到界面上         （假服务端回真 HTTP 400，断言 rv$error 的原文）
#   ② 按钮接上这条 400           （断言 dsapp_maxtok_advice() 解出 65536）
#   ③ 点下去写进库 + 改当前会话  （断言 model_param_limits 那一行 + force 信号）
#   ④ **下一次请求里真的是新值** （读假服务端点收的**请求体**，断言 max_tokens）
#
# ④ 是整份测试里最硬的一条。前三步都绿而 ④ 红，说明"学是学会了、记也记住了，
# 就是没应用" —— 那正是用户会骂的那种 bug，而且前三步一条都看不出来。
#
# ── 三个 testServer 块，共用同一个 state ────────────────────────────────────
#
# 「应用」这一步在**模型设置页**（mod_model.R 里 state$maxtok_force 的接收端），
# 而 testServer 一次只能挂一个模块。所以拆成三块，按用户真实的操作顺序走：
#     A. mod_chat  —— 发消息 → 400 → 点按钮（= 用户在第一屏做的）
#     B. mod_model —— 收到信号 → 写 state$max_tokens（= 用户切到设置页）
#     C. mod_chat  —— 再发一条 → 断言出网请求体里的 max_tokens（= 用户重发）
# 三块共用同一个 reactiveValues，信号真的从 A 流到 B、B 的结果真的被 C 读到。
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

# 假服务端给的那个上限。**故意不用 65536** —— 那是 DS_App 自己的默认上限。
#
# 这一点比看起来重要：夹具要是用 65536，"解析出来的上限 = 假服务端给的那个"
# 这条断言，在**解析器整个坏掉、一路返回默认值**的情况下照样是绿的。
# 用一个只出现在 400.json 里的数，断言才真的指向"这个数是从响应体里读出来的"。
SRV_MAX <- 24576L
# 也是夹具里的数：一个**比厂商上限大**的值，代表用户当前填的那个。
BIG_TOK <- 10485760L

# ---- 起假 LLM 服务端（400 模式 + 请求记账）---------------------------------
tmp <- tempfile("dsapp_maxtok_")
dir.create(tmp, recursive = TRUE)
queue_dir <- file.path(tmp, "queue"); dir.create(queue_dir)
req_dir   <- file.path(tmp, "reqs")
served_file <- file.path(tmp, "served.txt")
port_file   <- file.path(tmp, "port.txt")

if (!nzchar(Sys.which("python3"))) {
  say("找不到 python3，跳过端到端测试。")
  quit(status = 0L)
}
srv <- processx::process$new(
  "python3", c(file.path(app_dir, "tests", "fake_llm.py"),
               queue_dir, served_file, port_file, req_dir),
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
FAKE_URL <- sprintf("http://127.0.0.1:%d", port)

# ---- 装应用 -----------------------------------------------------------------
Sys.setenv(DSAPP_DATA_ROOT = tmp)
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}
# ⚠️⚠️ 这个名字**不能**叫 `cfg`（模块里那个 `cfg <- function() ...` 会盖住它，
#    详见 tests/agent_loop.R 里那段说明）。同理 `state` / `rv` / `session`
#    这些模块里有的局部名，这里都不能用。
tcfg <- dsapp_config(); dsapp_init_dirs(tcfg)

# ---- 假 LLM 的脚本 ----------------------------------------------------------
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
# 装 400 模式：前 `times` 次请求回真 HTTP 400。
#
# ⚠️ 错误体必须是**厂商那个形状**（`{"error":{"message":"..."}}`），不能是一句
#    纯文本 —— llm.R:264 先试 `fromJSON(body)$error$message`，解析不出来才退回
#    整段 body。用纯文本的话，被测代码拿到的字符串会带上 JSON 外壳，和线上
#    真实的样子不一样，测出来的东西就偏了。
arm_400 <- function(msg = sprintf("Field 'max_tokens' must be at most %d",
                                  SRV_MAX),
                    times = 1L, status = 400L) {
  writeLines(jsonlite::toJSON(
    list(status = status, times = times,
         body = list(error = list(message = msg, type = "invalid_request_error"))),
    auto_unbox = TRUE), file.path(queue_dir, "400.json"))
}
disarm_400 <- function() unlink(file.path(queue_dir, "400.json"))

# 读回假服务端**收到**的请求体。第 i 个 = 第 i 次出网请求。
req_body <- function(i) {
  fs <- sort(list.files(req_dir, full.names = TRUE))
  if (length(fs) < i) return(NULL)
  tryCatch(jsonlite::fromJSON(fs[i], simplifyVector = TRUE),
           error = function(e) NULL)
}
req_n <- function() length(list.files(req_dir))

# ---- 起模块的第一步：一个真账号 ---------------------------------------------
# ⚠️ 必须有真实账号：item 7 的只读闸门会拦下无主对话的第二条消息，症状是
#    "发消息没反应"，报错方向完全指向别处（agent_loop.R 里记着这一条）。
u0 <- dsapp_user_create("上限测试", "maxtok@dsapp.invalid", "00000000004",
                        "测试", password = "test1234")
if (!isTRUE(u0$ok)) { say("建不出测试账号：%s", u0$msg %||% "?"); quit(status = 1L) }

state <- reactiveValues(
  user_id = as.integer(u0$user$id), user = u0$user,
  api_key = "fake-key", vendor = "deepseek",
  base_url = FAKE_URL,
  model = "fake-model", temperature = 0.3,
  # ★ 用户当前填的是 App 允许的最大值 —— 比厂商说的 65536 大。
  #   这正是线上那条 400 的成因：应用侧量程 1024–10485760，厂商实际只到 65536，
  #   而两张厂商/模型档位表是**空的而且是故意的**（注释明写"交给厂商报错"）。
  max_tokens = BIG_TOK,
  thinking = NULL, reasoning_effort = NULL,
  chat_session_id = NULL,
  exec_target = "server", exec_env = "system",
  remote = list(host = "", port = 22, user = "", auth = "password",
                password = "", key_text = "", activate = "",
                workdir = "", verified = FALSE))

# 给这个账号存一把 Key —— 走应用自己的那条路（存库），不是往 state 上贴一个。
#
# ⚠️⚠️ 必须存库里，而且必须在**模型页跑过之前**。mod_model 启动时会
#    `state$api_key <- rec$api_key %||% ""` —— 库里没有就写空串。于是 C 块
#    那个 `api_key_now()` 闸门把"重发"整个挡下来：`dsapp_chat_send` 走到
#    `if (!nzchar(api_key_now())) { dsapp_prompt_model(); return(FALSE) }`
#    就回头了，一个请求都不发。
#
#    症状是"点了发送没反应、没有报错、也没有任何出网请求"，和界面坏了长得
#    一模一样（cooldown-looks-like-broken-ui 的同一条教训）。第一次跑这份
#    测试就是栽在这里，而它跟被测的 max_tokens 逻辑毫无关系。
#    真实用户的 Key 本来就在库里，所以这里也存库里 —— 顺带让 A 块那次请求
#    的鉴权头也是从库里取的，更接近线上。
# ⚠️ 用 u0$user$id，不是 state$user_id —— 后者是 reactiveValues，在响应式
#    上下文之外**读**会直接 abort（"Can't access reactive value outside of
#    reactive consumer"）。这个 abort 发生在脚本顶层，看起来像是测试框架
#    坏了，其实是这一行。
#
# ⚠️⚠️ base_url 也要一起存，而且必须存**假服务端的地址**。
#    不存的话它落成厂商默认值（https://api.deepseek.com），模型页一启动就
#    把 state$base_url 换成那个 —— 于是 C 块那条"重发"打到**真的 DeepSeek**
#    上，拿回来一句 HTTP 401。假绿/假红都不算，这是最坏的一种：**测试真的
#    出网了**，还把库里的 Key 送了出去（这里是一把假的，但换成真凭据就是个
#    事故）。所以这一行不是"为了让它跑通"，是隔离夹具的必做项。
#    ⚠️ 两处都要写：`dsapp_settings_save` 落的是 users 表那三列（模型页启动时
#       读的是它），`dsapp_api_key_put` 落的是钥匙串（api_key_now() 读的是它）。
#       只写一处的话另一处会回落到厂商默认值 —— 而"回落到厂商默认值"就是
#       "打到真的 api.deepseek.com 上去"。
uid0 <- as.integer(u0$user$id)
dsapp_settings_save(uid0, vendor = "deepseek", model = "fake-model",
                    base_url = FAKE_URL, api_key = "fake-key",
                    con = dsapp_db(tcfg))
dsapp_api_key_put(uid0, "deepseek", "fake-key",
                  base_url = FAKE_URL, model = "fake-model",
                  con = dsapp_db(tcfg))
dsapp_api_key_activate(uid0, "deepseek", con = dsapp_db(tcfg))

# 执行引擎住在 app.R 里（不在 R/ 下）。直接 source 整个 app.R 会连带起一个
# Shiny 服务，所以只把 dsapp_engine_new 那一段抠出来 source —— 测的仍然是
# 真代码，不是复制品。（同 tests/agent_loop.R。）
app_lines <- readLines(file.path(app_dir, "app.R"), warn = FALSE)
eng_from <- grep("^dsapp_engine_new <- function", app_lines)[1]
eng_to   <- grep("^engine <- dsapp_engine_new", app_lines)[1]
if (is.na(eng_from) || is.na(eng_to)) {
  say("app.R 里找不到 dsapp_engine_new 的定义，测试需要更新。"); quit(status = 1L)
}
writeLines(app_lines[eng_from:(eng_to - 1L)], (eng_src <- file.path(tmp, "engine.R")))
source(eng_src, local = globalenv())

# 引擎：聊天模块的签名是 mod_chat_server(id, state, engine)。
# ⚠️ 这份测试**不用** agent 循环，但 engine 参数是必填的 —— 不传的话模块里
#    那个心跳 observe 会报 `argument "engine" is missing`，而且报在
#    `session$setInputs` 里面，看起来像"点了发送没反应"，方向完全指错。
engine <- dsapp_engine_new(tcfg)

DB <- function() dsapp_db(tcfg)
lim_rows <- function() {
  tryCatch(DBI::dbGetQuery(DB(),
    "SELECT vendor, model, param, min_value, max_value, source, note
       FROM model_param_limits"), error = function(e) NULL)
}

say("\n\033[1m== 前置：什么都没学之前，上限是应用侧的 10,485,760 ==\033[0m")
rng0 <- dsapp_param_range("deepseek", "fake-model", "max_tokens")
chk("★ 起点上限就是应用侧的 10,485,760（不是被谁偷偷收窄过的）",
    identical(as.numeric(rng0$max), as.numeric(BIG_TOK)))
chk("起点库里一条学到的记录都没有",
    is.null(lim_rows()) || nrow(lim_rows()) == 0L)

# =============================================================================
# A. 发一条消息，厂商回真 400，然后点「直接帮我设置」
# =============================================================================
say("\n\033[1m== A. 真 HTTP 400 进到界面上 ==\033[0m")
# ⚠️ 顺序不能反：set_queue() 会 `unlink(list.files(queue_dir))` 把队列目录
#    清空 —— 它**不知道** 400.json 也是夹具的一部分，顺手就把刚装好的 400
#    删了。症状是"请求发出去了、返回的是正常 SSE、rv$error 空的"，
#    看起来像"400 那条代码路径根本没走"，而实际上是夹具自己在拆台。
set_queue("这条永远不会被读到（400 拦在前面）。")
arm_400()

testServer(mod_chat_server, args = list(state = state, engine = engine), {
  # 推进模拟时钟。testServer 里所有定时器（200ms 的流式轮询等）都靠它走。
  pump <- function(secs, until = NULL) {
    t0 <- Sys.time()
    while (as.numeric(Sys.time() - t0, units = "secs") < secs) {
      try(session$elapse(200), silent = TRUE)
      Sys.sleep(0.05)
      if (!is.null(until) && isTRUE(until())) return(TRUE)
    }
    is.null(until) || isTRUE(until())
  }
  done <- function() !isTRUE(rv$streaming) && !is.null(rv$error)

  session$setInputs(target_kind = "server", agent_mode = FALSE, input = "你好")
  session$setInputs(send = 1)
  pump(30, until = done)

  sid <- state$chat_session_id
  say("  对话号 = %s", sid %||% "(没建出来)")
  err <- rv$error %||% ""
  say("  rv$error = %s", substr(gsub("\n", " ", err), 1, 140))

  chk("★ 第一步：这是一个**真的 HTTP 400**（不是本地拼的字符串）",
      grepl("HTTP 400", err, fixed = TRUE))
  chk("★★ 响应体里的 message 被原样带出来了（厂商原文，不是壳）",
      grepl(sprintf("must be at most %d", SRV_MAX), err, fixed = TRUE))
  chk("★ 出网请求确实发出去过（假服务端收到了 1 个请求体）",
      identical(req_n(), 1L))
  chk("★★ 那条被拒的请求里，max_tokens 就是用户填的 10,485,760（400 的成因）",
      identical(as.numeric(req_body(1)$max_tokens), as.numeric(BIG_TOK)))
  chk("★ 400 没有消耗队列（被拒的请求不占正常应答的位置）",
      identical(served_n(), 0L))

  # ---- 按钮 ----
  say("\n\033[1m== A2. 界面上真的长出了那颗按钮 ==\033[0m")
  adv <- tryCatch(dsapp_maxtok_advice(rv$error), error = function(e) NULL)
  chk("★★ 从这条**真**报错里解出了上限，而且等于假服务端给的那个数",
      is.list(adv) && identical(as.numeric(adv$max), as.numeric(SRV_MAX)))
  chk("解出来的参数名就是 max_tokens",
      is.list(adv) && identical(adv$param, "max_tokens"))

  # 气泡是 rv$error 非空时 output$streaming 渲染出来的那一支。
  # ⚠️ 必须 paste(collapse=)。renderUI 的返回值 as.character() 之后是**两个**
  #    元素：第一个是 HTML，第二个是它的依赖清单（font-awesome 那些）。
  #    不合并的话 grepl() 返回的是长度 2 的逻辑向量，`chk` 里的 isTRUE()
  #    拿到它会一路 FALSE —— 按钮明明在，断言却红，而且红得毫无线索。
  bubble <- tryCatch(paste(as.character(output$streaming), collapse = "\n"),
                     error = function(e) "")
  chk("★ 错误气泡里有「直接帮我设置」这颗按钮",
      grepl("直接帮我设置", bubble, fixed = TRUE))
  chk("★ 按钮的 id 就是 maxtok_fix（点击事件能接上）",
      grepl("maxtok_fix", bubble, fixed = TRUE))
  chk("★ 按钮旁边写明了要改成哪个数（带千分位）",
      grepl(format(SRV_MAX, big.mark = ",", scientific = FALSE), bubble,
            fixed = TRUE))
  chk("★ 上下文类报错**不会**长出按钮（这条是 400，所以有）",
      is.null(dsapp_maxtok_advice(
        "This model's maximum context length is 65536 tokens, however you requested 70000 tokens. max_tokens is too large.")))

  say("\n\033[1m== A3. 点下去：写库 + 改当前会话 ==\033[0m")
  chk("点之前库里还是空的（按钮不是自动生效的）",
      is.null(lim_rows()) || nrow(lim_rows()) == 0L)
  session$setInputs(maxtok_fix = 1)
  session$elapse(100)

  lr <- lim_rows()
  say("  model_param_limits:")
  if (!is.null(lr) && nrow(lr) > 0) {
    for (i in seq_len(nrow(lr)))
      say("    %s / %s / %s → max=%s  source=%s", lr$vendor[i], lr$model[i],
          lr$param[i], lr$max_value[i], lr$source[i])
  } else say("    （空）")

  chk("★★ 库里有了这一行（下次开新会话不会再撞同一个 400）",
      !is.null(lr) && nrow(lr) == 1L)
  chk("★★ 记下来的上限 = 厂商说的那个数",
      !is.null(lr) && nrow(lr) == 1L &&
        identical(as.numeric(lr$max_value[1]), as.numeric(SRV_MAX)))
  chk("记在**这个厂商 + 这个模型**名下",
      !is.null(lr) && nrow(lr) == 1L &&
        identical(lr$vendor[1], "deepseek") && identical(lr$model[1], "fake-model"))
  chk("来源标成 provider_400（看得出这条上限是哪来的）",
      !is.null(lr) && nrow(lr) == 1L && identical(lr$source[1], "provider_400"))
  chk("note 里留着 400 的原文（排查时能对回去）",
      !is.null(lr) && nrow(lr) == 1L &&
        grepl(sprintf("must be at most %d", SRV_MAX), lr$note[1], fixed = TRUE))

  # 当前进程当场生效（学习就发生在本进程，不等下次启动）
  rng1 <- dsapp_param_range("deepseek", "fake-model", "max_tokens")
  chk("★★ 本进程的量程当场收窄到厂商说的那个数",
      identical(as.numeric(rng1$max), as.numeric(SRV_MAX)))
  chk("★★ 10,485,760 被夹成厂商那个上限",
      identical(as.numeric(dsapp_param_clamp("deepseek", "fake-model",
                                             "max_tokens", BIG_TOK)),
                as.numeric(SRV_MAX)))

  chk("★ 交给模型页去应用的那个信号已经发出去了",
      is.list(state$maxtok_force) &&
        identical(as.numeric(state$maxtok_force$value), as.numeric(SRV_MAX)))
  chk("★ 错误气泡收起来了（它要说的话由通知接上）", is.null(rv$error))

  # 到这一刻 state$max_tokens **还没变** —— 那是 B 块的事。这里先钉住，
  # 免得将来有人在聊天模块里顺手也写一遍，把"唯一真值"变成两处。
  chk("此时 state$max_tokens 仍是旧值（应用是模型页的活）",
      identical(as.numeric(state$max_tokens), as.numeric(BIG_TOK)))
})

# =============================================================================
# B. 模型设置页收到信号，真的把 max_tokens 改掉
# =============================================================================
say("\n\033[1m== B. 模型页接收端：真的改了，而且是夹过的 ==\033[0m")

testServer(mod_model_server, args = list(state = state), {
  session$setInputs()
  session$elapse(100)

  # ⚠️⚠️ 必须先把这个页面的 厂商/模型 摆成和 A 块一样的。
  #
  #    模型页那个大 observe 会 `state$model <- dsapp_model_migrate(v,
  #    input$model)$model`，而 testServer 里 input$model 是 NULL ——
  #    migrate 对空模型名会**回落到该厂商的默认模型**（deepseek-flash）。
  #    于是量程是按 deepseek/deepseek-flash 算的，而 A 块学到的记录挂在
  #    deepseek/fake-model 名下，第四层**整个不生效**。
  #
  #    这个坑第一次跑的时候没被发现，反而制造了一条**假绿**：收到的数
  #    24576 落在 [1024, 10485760] 里，dsapp_param_clamp 原样放行 ——
  #    "夹过之后是这个数"和"根本没夹"看起来一模一样。所以下面每一条
  #    跟夹取有关的断言前面，都先钉一句量程真的收窄了没有。
  # ⚠️ base_url 也要摆回来。模型页有一个"状态同步到会话"的 observe：
  #        state$base_url <- dsapp_vendor_base_url(v, input$base_url)
  #    testServer 里 input$base_url 是 NULL → 回落到**厂商默认地址**
  #    （https://api.deepseek.com）。真实用户填了中转地址时那一格有值，
  #    所以这里也把它摆上 —— 不是为了让它跑通，是为了让夹具和真实用户
  #    长得一样，同时把出网**钉死在假服务端上**。
  #    （这一条抓过一次真事故：C 块那条"重发"打到了真的 api.deepseek.com，
  #      拿回一句 HTTP 401 —— 夹具测试变成了真的外呼。）
  session$setInputs(vendor = "deepseek", model = "fake-model",
                    base_url = FAKE_URL)
  session$elapse(100)
  chk("★★ 模型页认的就是 A 块那个模型（名字对不上，学到的上限就是死的）",
      identical(state$model, "fake-model") && identical(state$vendor, "deepseek"))
  chk("★★ 而且量程确实已经收到厂商说的那个数（不是原样放行）",
      identical(as.numeric(dsapp_param_range(state$vendor, state$model,
                                             "max_tokens")$max),
                as.numeric(SRV_MAX)))

  # 复刻 A 块发出的那个信号（rev 继续往上加 —— reactiveValues 只在值**真的
  # 变了**的时候才通知下游，写一个一样的列表等于什么都没发生）。
  bump <- function(v) {
    old <- isolate(state$maxtok_force)
    state$maxtok_force <- list(rev = (old$rev %||% 0L) + 1L,
                               value = v, param = "max_tokens")
    session$elapse(200)
  }

  # ⚠️ 不在这里断言"起点还是 10,485,760"。模型页一进来就会用它自己那一格
  #    （rv$maxtok，testServer 里没渲染过控件，所以是它的初值 65536）重算一遍
  #    state$max_tokens —— 那是**真实行为**，不是夹具的毛病。而这一版学到了
  #    24576，重算的结果是 24576。钉死"起点等于某个数"只会把这条测试绑在
  #    控件初值上，测不到任何产品行为。
  say("  进页面后的 state$max_tokens = %s", state$max_tokens)

  bump(SRV_MAX)
  say("  收到信号后：state$max_tokens = %s, rv$maxtok = %s",
      state$max_tokens, rv$maxtok)
  chk("★★ state$max_tokens 变成了厂商说的那个数",
      identical(as.numeric(state$max_tokens), as.numeric(SRV_MAX)))
  chk("★ 模型页自己那一格（rv$maxtok）也同步了",
      identical(as.numeric(rv$maxtok), as.numeric(SRV_MAX)))

  # ⚠️ 这条是"接收端不能只是照抄传进来的数"：模型页是 max_tokens 的所在地，
  #    它有义务按**当下算出来的量程**夹一次。少了这一步，信号里带什么数就
  #    写什么数 —— 而信号的来源是外部报错文本，不是可信输入。
  bump(99999999L)
  chk("★★ 传一个超出量程的数进来，落下去的是夹过的值（不是照抄）",
      identical(as.numeric(state$max_tokens), as.numeric(SRV_MAX)))
})

# =============================================================================
# C. 再发一条：出网请求体里真的是新值
# =============================================================================
say("\n\033[1m== C. 重发：出网请求里真的是新上限 ==\033[0m")

disarm_400()                      # 这一次厂商会正常应答
set_queue("这次通了。")

testServer(mod_chat_server, args = list(state = state, engine = engine), {
  pump <- function(secs, until = NULL) {
    t0 <- Sys.time()
    while (as.numeric(Sys.time() - t0, units = "secs") < secs) {
      try(session$elapse(200), silent = TRUE)
      Sys.sleep(0.05)
      if (!is.null(until) && isTRUE(until())) return(TRUE)
    }
    is.null(until) || isTRUE(until())
  }
  done <- function() !isTRUE(rv$streaming) && nzchar(draft() %||% "")

  # ★ 出网隔离的自检。上面那条 base_url 的坑（模型页把它换回厂商默认地址、
  #   于是测试打到真的 DeepSeek 上）如果哪天又回来，这一条要第一个红 ——
  #   后面那些"请求体里的 max_tokens 不对"的红全都指向别处，而且会让人
  #   以为是产品代码坏了。
  chk("★★ 这一条仍然打在假服务端上（base_url 没被模型页换掉）",
      identical(state$base_url, FAKE_URL))
  chk("★★ 用的还是那把假 Key（没有被模型页清成空串）",
      nzchar(state$api_key %||% ""))

  session$setInputs(target_kind = "server", agent_mode = FALSE, input = "再试一次")
  session$setInputs(send = 1)
  pump(30, until = done)

  chk("重发没有报错", is.null(rv$error))
  chk("假服务端这回真的应答了（吃到队列里那一条）", identical(served_n(), 1L))
})

# ⚠️ 断言放在 testServer **外面**读文件：这样即使模块里某一步炸了，前面已经
#    跑完的请求也还在盘上，看得见"到底发出去的是什么"。
say("\n--- 出网请求记账（假服务端收到的请求体）---")
say("  一共 %d 个请求", req_n())
b1 <- req_body(1); b2 <- req_body(2)
say("  #1 max_tokens=%s  model=%s", b1$max_tokens %||% "(无)", b1$model %||% "?")
say("  #2 max_tokens=%s  model=%s", b2$max_tokens %||% "(无)", b2$model %||% "?")

chk("★ 一共只有两次出网请求（400 那次 + 重发那次，没多没少）",
    identical(req_n(), 2L))
chk("★★ 第 1 次带的是旧值 10,485,760（这是被拒的那一次）",
    !is.null(b1) && identical(as.numeric(b1$max_tokens), as.numeric(BIG_TOK)))
chk("★★★ 第 2 次带的是学到的那个上限 —— 配置真的应用到出网请求上了",
    !is.null(b2) && identical(as.numeric(b2$max_tokens), as.numeric(SRV_MAX)))
chk("两次请求的 model 是同一个（不是换了个模型才对的）",
    !is.null(b1) && !is.null(b2) && identical(b1$model, b2$model))

# =============================================================================
# D. 换一条进程 = 换一个会话：学到的上限要能从库里读回来
# =============================================================================
say("\n\033[1m== D. 重启后还在（持久化不是内存里的假象）==\033[0m")

dsapp_param_learned_clear()      # 清掉内存，模拟"R worker 换代了"
rng2 <- dsapp_param_range("deepseek", "fake-model", "max_tokens")
chk("清掉内存后量程退回应用侧的 10,485,760（说明确实清干净了）",
    identical(as.numeric(rng2$max), as.numeric(BIG_TOK)))

n_loaded <- dsapp_param_learned_load(DB())
chk("★ 从库里读回来了", isTRUE(n_loaded) || is.numeric(n_loaded))
rng3 <- dsapp_param_range("deepseek", "fake-model", "max_tokens")
chk("★★ 读回来之后量程又收窄了（下次开新会话不会再撞 400）",
    identical(as.numeric(rng3$max), as.numeric(SRV_MAX)))

# 别的模型不受影响 —— 一条记录套到所有模型头上的话，用户换一个模型就莫名其妙
# 被限到 65,536，而他那个模型明明能到 1M。
rng4 <- dsapp_param_range("deepseek", "别的模型", "max_tokens")
chk("★ 别的模型不受影响（上限还是 10,485,760）",
    identical(as.numeric(rng4$max), as.numeric(BIG_TOK)))
rng5 <- dsapp_param_range("另一个厂商", "fake-model", "max_tokens")
chk("★ 别的厂商也不受影响",
    identical(as.numeric(rng5$max), as.numeric(BIG_TOK)))

unlink(tmp, recursive = TRUE)
say("\n\033[1m%s（失败 %d）\033[0m", if (ok) "全部通过" else "有失败", nfail)
quit(status = if (ok) 0L else 1L)
