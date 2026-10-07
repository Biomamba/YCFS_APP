#!/usr/bin/env Rscript
# Test_V15.2 · 文献速递页那两张新卡片（「发到我的邮箱」+「定时订阅」）
#
#   cd /tmp/dsapp_v152/fake/app && Rscript tests/v152_lit_cards.R
#
# ⚠️ 这个文件**真的把模块跑起来**（shiny::testServer，照 tests/agent_loop.R
#    的先例），不是对着源码 grep。理由见 memory 的 `selftest-green-is-not-coverage`：
#    上一版邮件开关的接线测试只证明了"函数写对了 / 那行代码在文件里",
#    而真正的 bug（列表为空时「刷新列表」按钮跟着消失、"每行一个 radioButtons"
#    造成只有第一行选得动）两条都躲过去了 —— 它们都是**结构**问题，
#    结构问题只有把 DOM 建出来才看得见。
#
# 三段：
#   A 纯逻辑：速递清单只认自己的；订阅的增删改开关都带 user_id
#   B testServer：卡片真的建出来、按钮真的起作用、**写完回库确认**
#   C 源码级：几条只能在源码里查的（不许轮询扫描、路径白名单那行的形状）

setwd("/tmp/dsapp_v152/fake/app")
# ⚠️ bslib 也要加载：模块里的 card() / card_header() / card_body() 是它的，
#    app.R 那边靠 library(bslib) 带进来。只加载 shiny 的话卡片一建就报
#    "could not find function card"，而错误指向 renderUI 内部，看不出缺包。
suppressMessages(library(shiny))
suppressMessages(library(bslib))
for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
source("R/mod_lit.R", local = globalenv())
cfg <- dsapp_config()
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")
if (!grepl("^/tmp/", cfg$files_dir %||% "/tmp/x")) stop("files_dir 不是 /tmp")

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-40s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}
con <- dsapp_db(cfg)
strip_c <- function(txt) {
  txt <- gsub("(?m)#.*$", "", txt, perl = TRUE)
  gsub("(?s)#'.*?\n", "\n", txt, perl = TRUE)
}
read_src <- function(p) paste(readLines(p, warn = FALSE), collapse = "\n")
# ⚠️ renderUI 的输出直接 as.character() 出来**长度可能大于 1**
#    （tagList/card 是嵌套的 tag 列表）。不 collapse 的话，后面任何
#    `nzchar(x)` / `grepl(..., x)` 都会拿到长度 2 的向量，报的是
#    "'length = 2' in coercion to 'logical(1)'" —— 一个和"卡片没建出来"
#    毫无关系的错。一律走这里。
flat <- function(x) paste(as.character(x), collapse = "\n")

stamp <- as.integer(Sys.time())
mkuser <- function(tag) {
  em <- sprintf("%s%d@example.org", tag, stamp)
  r <- dsapp_user_create(tag, em, sprintf("137%08d", (stamp + nchar(tag)) %% 1e8),
                         "测试", password = "test-only-1234",
                         password2 = "test-only-1234")
  if (!isTRUE(r$ok)) stop(r$msg)
  list(email = em, row = dsapp_user_by_email(em, con = con))
}
A <- mkuser("卡片甲")      # 主测账号
B <- mkuser("卡片乙")      # 用来验"看不到别人的"
uidA <- as.integer(A$row$id); uidB <- as.integer(B$row$id)

# ======================= A 纯逻辑 =============================================
cat("=== A 纯逻辑 ===\n")

# 造两份速递：甲乙各一份，各在自己的会话工作区里
mkdigest <- function(uid, sid_title, body) {
  # ⚠️ db_session_create 返回的是**字符串** id（"s-2026...-1234"），
  #    不是 list、也不能 as.integer（memory：对话号不是任务号）。
  sid <- as.character(db_session_create(sid_title, uid, con = con))
  wd <- dsapp_ws_dir(sid, cfg = cfg, create = TRUE)
  writeLines(body, file.path(wd, "文献速递.md"))
  list(sid = sid, path = file.path(wd, "文献速递.md"))
}
dA <- mkdigest(uidA, "甲的检索", "# 甲的速递\n\n内容甲\n")
dB <- mkdigest(uidB, "乙的检索", "# 乙的速递\n\n内容乙\n")

# ⚠️ 还要给**库里 id 最小那个账号**（不是甲也不是乙，是自举时就有的那个）
#    也造一份速递。为什么非造不可：跨账号泄漏那两条断言的变异测试一开始
#    是**绿着通过的** —— 因为变异体"把 1 号账号的速递也扫进来"扫到的是个
#    空账号，什么都没多出来，断言自然没反应。夹具里没有别人的东西，
#    "看不到别人的"就成了一句无从证伪的话。
uidOther <- as.integer(DBI::dbGetQuery(
  con, "SELECT MIN(id) AS id FROM users WHERE id NOT IN (?, ?)",
  params = list(uidA, uidB))$id)
if (!is.na(uidOther)) {
  dOther <- mkdigest(uidOther, "别人的检索", "# 别人的速递\n\n不该被看到\n")
} else dOther <- NULL

fA <- dsapp_lit_find_digests(uidA, cfg = cfg, con = con)
say("找得到自己的速递", !is.null(fA) && nrow(fA) >= 1L)
say("★ 只找得到自己的（看不到乙的）",
    !is.null(fA) && !any(grepl(dB$path, fA$path, fixed = TRUE)),
    sprintf("（%d 份）", if (is.null(fA)) 0L else nrow(fA)))
# ⚠️ 上一条只认了乙。变异测试证明这不够："把 1 号账号的速递也扫进来"那个
#    变异体泄漏的是**第三个人**的，只盯乙的话它绿着过去。跨账号的断言
#    必须把**所有**已知的别人都点一遍，否则它在守一个很窄的巧合。
say("★ 也看不到第三个人的",
    is.null(dOther) || !any(grepl(dOther$path, fA$path, fixed = TRUE)))
say("★ 甲自己那份在", !is.null(fA) && any(grepl(dA$path, fA$path, fixed = TRUE)))
say("返回的路径是真文件", !is.null(fA) && all(file.exists(fA$path)))
say("结果里有会话标题", !is.null(fA) && "title" %in% names(fA))

# 订阅的跨账号隔离
subA <- dsapp_litsub_add(uidA, "单细胞 转录组", n_read = 2L, n_skim = 4L,
                         freq = "weekly", weekday = 3L, hour = 9L, minute = 30L,
                         enabled = TRUE, title = "甲的订阅",
                         cfg = cfg, con = con)
say("甲建得起来", isTRUE(subA$ok), subA$msg %||% "")
say("建完之后 next_at 有值",
    nzchar(dsapp_litsub_list(uidA, cfg = cfg, con = con)$next_at[1] %||% ""))

say("★ 乙的列表里看不到甲的",
    is.null(dsapp_litsub_list(uidB, cfg = cfg, con = con)) ||
      !(subA$id %in% dsapp_litsub_list(uidB, cfg = cfg, con = con)$id))
r <- dsapp_litsub_delete(subA$id, uidB, cfg = cfg, con = con)
say("★ 乙删不掉甲的", !isTRUE(r$ok))
say("★ 乙改不了甲的（toggle）",
    !isTRUE(dsapp_litsub_toggle(subA$id, uidB, FALSE, cfg = cfg, con = con)$ok))
say("★ 甲那条还在且还开着",
    isTRUE(as.integer(dsapp_litsub_list(uidA, cfg = cfg, con = con)$enabled[1]) == 1L))

# ======================= B testServer ========================================
cat("\n=== B 模块真跑起来 ===\n")

# ⚠️ 邮件那一段要 dsapp_mail_ready() 为真卡片才出现。假实例的 .Renviron
#    已经配了（指向 127.0.0.1:2525 那个假 SMTP），这里再确认一次 ——
#    不成立的话下面几条会以"卡片是 NULL"的形式红，而原因完全看不出来。
say("假实例配了 SMTP（下面才测得到邮件卡）", isTRUE(dsapp_mail_ready(cfg)))

state <- reactiveValues(user_id = uidA, user = A$row)
got <- new.env(parent = emptyenv())

# ⚠️⚠️ testServer 里那段 `{...}` 是在**模块 server 的执行帧里**求值的
#    （见 tests/agent_loop.R 顶部那段说明）—— 好处是能直接摸到 input/output，
#    代价是**模块里的局部变量会把同名的全局变量挡住**。
#    mod_lit_server 里有 `cfg <- dsapp_config`，于是我在那段里写
#    `dsapp_lit_find_digests(uid, cfg = cfg)` 传进去的是**函数**不是配置，
#    报出来的是 "object of type 'closure' is not subsettable"，
#    栈顶却指在 dsapp_ws_dir 里 —— 和真正的原因隔着两层。
#    所以测试自己的这两样东西一律换个名字，别跟模块内的撞。
cfg0 <- cfg
con0 <- con

testServer(mod_lit_server, args = list(state = state), {
  # ⚠️ 先等一拍再读。`observeEvent(state$user_id, scan_digests())` 是
  #    **异步**于这次读取的：紧接着读 output 有可能赶在它前面，
  #    读到的是还没扫过的空卡片。变异测试里就撞上了 —— 同一个变异体
  #    在乙那边红了、在甲这边绿着，纯粹因为谁先跑到。
  #    夹具不能有这种"看谁先跑"的断言。
  Sys.sleep(0.25)
  got$card   <- tryCatch(flat(output$litsub_card), error = function(e) paste0("ERR:", conditionMessage(e)))
  got$table0 <- tryCatch(flat(output$sub_table), error = function(e) paste0("ERR:", conditionMessage(e)))
  got$mail   <- tryCatch(flat(output$mail_lit_card), error = function(e) paste0("ERR:", conditionMessage(e)))

  # 登录之后自动扫了一次速递 —— 那张卡上应该看得到甲的会话标题
  got$mail_has_digest <- grepl("甲的检索", got$mail, fixed = TRUE)

  # ---- 新建一条订阅（走真的按钮）----
  session$setInputs(kw = "单细胞 转录组", n_read = 2, n_skim = 3,
                    year_from = 2020, year_to = 2025,
                    skills = integer(0), extra_presets = character(0),
                    extra = "", sub_freq = "daily", sub_wd = 1,
                    sub_dom = 1, sub_hour = 7, sub_min = 15,
                    sub_title = "界面建的", sub_enabled = TRUE)
  session$setInputs(sub_add = 1)
  Sys.sleep(0.3)
  got$table1 <- tryCatch(flat(output$sub_table), error = function(e) paste0("ERR:", conditionMessage(e)))
  got$summary <- tryCatch(flat(output$sub_new_summary), error = function(e) "")
  # ⚠️⚠️ 别去读 input$sub_pick 指望它是刚渲染出来那一条：renderUI 画出来的
  #    控件**不会**顺手把服务端的 input 设上（真实浏览器里是用户点/选出来的，
  #    这里没有那个人）。第一次写就是这么红的：got$ids 是 NA，
  #    整段"停用/启用"被 if 静默跳过，两条断言报的却是"没写进库"。
  #    要从库里取真实 id，再 setInputs 模拟"用户选了这一条"。
  ids_now <- dsapp_litsub_list(uidA, cfg = cfg0, con = con0)$id
  got$ids <- as.integer(ids_now)
  session$setInputs(sub_add = 2)
  Sys.sleep(0.2)

  # ---- 停用 / 启用（选中那一条）----
  if (length(got$ids) && !is.na(got$ids[1])) {
    session$setInputs(sub_pick = as.character(got$ids[1]))
    session$setInputs(sub_off = 1); Sys.sleep(0.3)
    got$enabled_after_off <- dsapp_litsub_list(uidA, cfg = cfg0, con = con0)
    session$setInputs(sub_on = 1); Sys.sleep(0.3)
    got$enabled_after_on <- dsapp_litsub_list(uidA, cfg = cfg0, con = con0)
  }

  # ---- 发信：先送一个**伪造的路径**（不在清单里的文件）----
  got$forged_before <- DBI::dbGetQuery(con0, "SELECT COUNT(*) AS n FROM mail_queue")$n
  session$setInputs(mail_lit_pick = "/etc/passwd")
  session$setInputs(mail_lit_go = 1); Sys.sleep(0.4)
  got$forged_after <- DBI::dbGetQuery(con0, "SELECT COUNT(*) AS n FROM mail_queue")$n
  got$forged_note <- tryCatch(flat(output$mail_lit_msg), error = function(e) "")

  # ---- 再送一个**清单里真有的**----
  d_now <- dsapp_lit_find_digests(uidA, cfg = cfg0, con = con0)
  got$real_path <- if (is.null(d_now)) "" else d_now$path[1]
  session$setInputs(mail_lit_pick = got$real_path)
  session$setInputs(mail_lit_go = 2); Sys.sleep(0.5)
  got$q <- tryCatch(DBI::dbGetQuery(
    con0, "SELECT id, to_email, subject, status FROM mail_queue ORDER BY id DESC LIMIT 1"),
    error = function(e) NULL)

  # ---- 空列表时那颗「刷新列表」还在不在 ----
  # 把甲的速递先挪走，再点刷新，看卡片还在不在（按钮在不在这条由 C 段守）
  got$mail_html <- flat(output$mail_lit_card)
})

# 乙那一段：乙**有**一份自己的速递（A 段为了验隔离造的），但**没有**订阅。
# 于是它同时验两件事：
#   · 界面上会不会漏出甲的速递（库那一层 A 段已经验过，这里是**画出来**那一层）
#   · 一条订阅都没有时表格的样子
stateB <- reactiveValues(user_id = uidB, user = B$row)
testServer(mod_lit_server, args = list(state = stateB), {
  Sys.sleep(0.25)
  got$b_table <- tryCatch(flat(output$sub_table), error = function(e) paste0("ERR:", conditionMessage(e)))
  got$b_mail  <- tryCatch(flat(output$mail_lit_card), error = function(e) paste0("ERR:", conditionMessage(e)))
})

# 丙：什么都没有。**空状态**只有在这儿才验得到 ——
# 「刷新列表」那颗按钮是不是被误关进了"有速递"分支里，
# 只有真建一遍空卡片才看得见（C 段的源码检查守不住结构）。
uidC <- as.integer(mkuser("卡片丙")$row$id)
stateC <- reactiveValues(user_id = uidC, user = list(id = uidC, email = ""))
testServer(mod_lit_server, args = list(state = stateC), {
  Sys.sleep(0.25)
  got$c_table <- tryCatch(flat(output$sub_table), error = function(e) paste0("ERR:", conditionMessage(e)))
  got$c_mail  <- tryCatch(flat(output$mail_lit_card), error = function(e) paste0("ERR:", conditionMessage(e)))
})

say("定时订阅卡建出来了", is.character(got$card) && nzchar(got$card) &&
      !grepl("^ERR:", got$card))
say("卡片里写了时区",
    grepl(cfg$tz %||% "UTC", got$card, fixed = TRUE))
# ⚠️ 甲在 A 段已经建过一条了，所以这里**不该**是空状态 —— 反过来，
#    表格里应该出现那条（证明它读的是库，不是新起的模块内存）。
say("表格读的是库里的（甲那条在）",
    grepl("甲的订阅", got$table0, fixed = TRUE) ||
      grepl("单细胞", got$table0, fixed = TRUE))
say("建完表格里有那条", grepl("界面建的", got$table1, fixed = TRUE) ||
      grepl("单细胞", got$table1, fixed = TRUE))
say("★ 建完表格里出现具体时刻（不是「（关着）」）",
    grepl("07:15", got$table1, fixed = TRUE))
# 乙：一条订阅都没有 → 表说"还没有订阅"
say("★ 空订阅的账号：表说「还没有订阅」",
    grepl("还没有订阅", got$b_table, fixed = TRUE))
# ★★ 乙的下拉里**只能有乙自己的那份**。库那一层 A 段已经验过，
#    这一条守的是"画出来那一层" —— 有人把 find_digests 的结果缓存到了
#    state 上、或者把用户 id 传错了，都会在这里现形。
say("★★ 乙的下拉里是乙自己的速递",
    grepl("乙的检索", got$b_mail, fixed = TRUE))
say("★★ 乙的卡上看不到甲的速递",
    !grepl("甲的检索", got$b_mail, fixed = TRUE))
say("★★ 乙的卡上也看不到第三个人的",
    !grepl("别人的检索", got$b_mail, fixed = TRUE))
say("★★ 甲的卡上看不到别人的速递",
    !grepl("别人的检索", got$mail, fixed = TRUE))

# 丙：连速递都没有。空状态 + 那颗按钮必须还在
say("★ 丙：邮件卡说「还没找到速递」",
    grepl("还没找到速递", got$c_mail, fixed = TRUE))
say("★★ 丙（空列表）：「刷新列表」还在",
    grepl('mail_lit_refresh', got$c_mail, fixed = TRUE))
say("★★ 丙（空列表）：没有「发这一份」",
    !grepl('mail_lit_go', got$c_mail, fixed = TRUE))
say("丙：表说「还没有订阅」",
    grepl("还没有订阅", got$c_table, fixed = TRUE))
# ⚠️⚠️ 「选中」那个下拉在**整张表**里只能有一个 id。每行画一个 radioButtons
#    的版本会在这里红 —— 而它在界面上是"只有第一行选得动，后面几行点了
#    等于没点、一声不吭"。
n_pick <- length(gregexpr('id="lit-sub_pick"', got$table1, fixed = TRUE)[[1]])
say("★ 选中控件全文只有一个", n_pick == 1L, sprintf("（%d 个）", n_pick))
say("新建表单的预览说清了关键词",
    grepl("单细胞", got$summary, fixed = TRUE))

l1 <- got$enabled_after_off
l2 <- got$enabled_after_on
say("★ 点「停用」真写进库了",
    !is.null(l1) && any(as.integer(l1$enabled) == 0L),
    sprintf("（enabled=%s）", if (is.null(l1)) "NULL" else paste(l1$enabled, collapse = ",")))
say("★ 点「启用」真写进库了",
    !is.null(l2) && any(as.integer(l2$enabled) == 1L))

# ★★ 这一段是本次改动里最要紧的安全断言
say("★★ 伪造路径没进队列",
    identical(as.numeric(got$forged_before), as.numeric(got$forged_after)),
    sprintf("（%s → %s）", got$forged_before, got$forged_after))
say("★★ 伪造路径给了明确回执",
    grepl("不在列表里", got$forged_note, fixed = TRUE), got$forged_note)
say("★ 真路径进了队列",
    !is.null(got$q) && nrow(got$q) == 1L)
say("★ 队列里的收件人是甲的邮箱",
    !is.null(got$q) && identical(as.character(got$q$to_email[1]), A$email))
say("★ 队列里的收件人不是乙的",
    !is.null(got$q) && !identical(as.character(got$q$to_email[1]), B$email))
say("主题写了「文献速递」",
    !is.null(got$q) && grepl("文献速递", as.character(got$q$subject[1])))

# ======================= C 源码级 ============================================
cat("\n=== C 源码级 ===\n")
lit <- strip_c(read_src("R/mod_lit.R"))
mail_src <- strip_c(read_src("R/litsub.R"))

# ★★ 扫速递清单要遍历 200 个工作区目录，是全站唯一那个 R 进程里最贵的一类
#    操作。挂成定时轮询 = 每开一个页面就每 N 秒遍历一次磁盘。
say("★★ 扫描没有挂定时器（不许 invalidateLater）",
    !grepl("invalidateLater", lit))
say("扫描挂在登录上", grepl("observeEvent\\(state\\$user_id, scan_digests\\(\\)", lit))
say("扫描挂在刷新按钮上",
    grepl("observeEvent\\(input\\$mail_lit_refresh, scan_digests\\(\\)", lit))

# ★ 白名单那一步的形状：送来的路径必须在这个账号的清单里
say("★★ 送信前核对路径在清单里",
    grepl("p %in% d\\$path", lit))
# ⚠️⚠️ `fixed = TRUE` 下模式是**字面**的 —— 里面再写 `\\(` 就是在找
#    "反斜杠 + 左括号"这两个字符，永远不命中，`regexpr` 返回 -1。
#    而 `i > 0 && j > 0` 这种写法会把 -1 **吞掉**变成一条恒假的断言：
#    它红得莫名其妙，方向还完全指错（"顺序不对" vs "模式根本没匹配上"）。
#    仓库里 selftest.R 为同一个坑写过一段注释（tos_src 那处），这是第二次。
#    所以这里一律用**不含反斜杠的字面串**。
lit_has <- function(x) grepl(x, lit, fixed = TRUE)
lit_at <- function(x) regexpr(x, lit, fixed = TRUE)[1]
say("★★ 核对在入队**之前**",
    lit_at("p %in% d$path") > 0 &&
      lit_at("dsapp_lit_mail_queue(") > 0 &&
      lit_at("p %in% d$path") < lit_at("dsapp_lit_mail_queue("))
say("入队之后才 kick",
    lit_at("dsapp_lit_mail_queue(") > 0 &&
      lit_at("dsapp_mail_kick(") > lit_at("dsapp_lit_mail_queue("))
say("本进程不直接发信", !grepl("dsapp_mail_send_raw\\(", lit))

# 三个动作都走同一个口子（各写一遍迟早有一条漏掉 user_id）
# 定义处写的是 `act_on_sub <- function(fn)`（名字后面没有括号），
# 所以数到的是**三个调用点**：启用 / 停用 / 删除。
say("★ 三个动作共用一个 act_on_sub",
    length(gregexpr("act_on_sub(", lit, fixed = TRUE)[[1]]) >= 3L,
    sprintf("（%d 个）", length(gregexpr("act_on_sub(", lit, fixed = TRUE)[[1]])))
say("★ toggle 和 delete 都收 user_id",
    grepl("dsapp_litsub_toggle\\(id, uid", lit) &&
      grepl("dsapp_litsub_delete\\(id, uid", lit))

# 断环 / 轮询的老规矩（在共用实现里）
say("轮询用共用实现", grepl("dsapp_mail_ui_watch\\(cfg\\)", lit))

# 「刷新列表」不能跟着下拉一起藏进 else 分支
# ⚠️ 这里本来还有一条**源码级**的"刷新按钮不在「有速递」分支里"：
#    比 `还没找到速递` / `mail_lit_refresh` / `mail_lit_go` 三个字面串的
#    先后位置。变异测试把它删掉了 —— 把刷新按钮真的挪回 if 分支里之后，
#    这条**照样绿**（三个串的相对顺序没变，变的是缩进和外面那层 if），
#    而 B 段那条真建一遍空卡片的断言当场变红。
#    一条在被测变异下不会红的断言比没有断言更糟：它占着"这里测过了"的位置。
#    结构问题只有把 DOM 建出来才看得见，所以这条归 B 段（丙的卡片）守。
say("时区在界面上写出来了", lit_has("tags$code(tz_cn())"))

cat("\n", if (ok) "=== 文献速递两张卡全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
