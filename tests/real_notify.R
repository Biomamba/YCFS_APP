#!/usr/bin/env Rscript
# =============================================================================
# 真邮件验收（第 2 项）：任务跑完 / 失败的通知邮件
# =============================================================================
#
#     Rscript tests/real_notify.R <应用目录> [收件人]
#
# 验的是用户指令第 2 条：「言出法随界面开启一个让用户勾选邮件提醒的功能，
# 开启后能把任务运行成功完成/失败的信息发送到用户的邮箱」。
#
# 和 tests/real_mail.R 的分工：
#   * real_mail.R  验**文献速递**那条路（渲染 + 内联图 + Markdown 附件）
#   * 本文件       验**任务通知**那条路（收尾钩子 → 收件人解析 → 偏好开关 →
#                  成功/失败两种模板 → ref 去重）
#
# 走的是**真**路径，不是"直接调 dsapp_task_notify"：
#     db_task_status() … → dsapp_task_closeout(tid, r, cfg)
#                          └─ on.exit(dsapp_task_notify(tid, cfg))
#                          └─ 入队 → dsapp_mail_kick() → 后台子进程排空
# 也就是说，从"任务收尾"到"信发出去"整条链一次跑通。绕过 closeout 直接调
# notify 的话，on.exit 那段挂钩（以及它被 tryCatch 包住这件事）就验不到，
# 而那恰恰是 V15.2 新加的那一行。
#
# ⚠️ 这个文件**不能**进 selftest.R / deploy.sh --check：它联网、真投信、
#    结果依赖外部 SMTP 服务器。它是部署后手工跑一次的验收，不是回归测试。
#    离线的回归在 selftest.R 的「V15.2」节和 tests/v152_closeout_guard.R。
#
# ⚠️ 凭据**只借读、不复制**。见下面那段说明和 tests/real_mail.R 的同名段落。
#    本文件里也**不打印** dsapp_config()$mail 的任何一项。
#
# ⚠️ 强烈建议对着**探针实例**跑（`.Renviron` 里 DSAPP_DATA_ROOT 指到 /tmp 的
#    那种）。本文件会往库里建账号、会话、任务行 —— 对着生产库跑会在生产库里
#    留下验收痕迹，那就说不清"哪条是用户的、哪条是验的"了。
#    （本文件会在跑之前检查 data_root，不在 /tmp 就先问一句。）
#
# 输出走 stderr：stdout 重定向到文件时是块缓冲的，卡住时一个字都看不到，
# 而"卡住"恰恰是这里最要报出来的情况。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)
suppressMessages(library(shiny))

# ---- 凭据：**借读**，不复制 --------------------------------------------------
#
# 探针实例的 .Renviron 里只有 DSAPP_DATA_ROOT（这是故意的：那份文件同时
# 决定了"往哪个库写"，让它保持一行，误接生产库的可能性就少一条）。
# SMTP 那几项从生产那份 .Renviron 借读进来，密码因此在磁盘上**只有一个
# 落盘位置** —— 副本不会跟着原文一起轮换，半年后没人知道它从哪来。
#
# ⚠️ 顺序要紧：readRenviron() 会把那份文件里的**所有**键都写进环境，包括
#    DSAPP_DATA_ROOT —— 也就是会把探针实例**接回生产库**（不报错、界面上
#    也看不出任何异样，是 memory 里记过的那个坑）。所以先把探针自己的
#    data_root 存下来，读完再按回去。
creds <- Sys.getenv("DSAPP_MAIL_CREDS", "")
data_root_keep <- Sys.getenv("DSAPP_DATA_ROOT", "")
if (nzchar(creds)) {
  if (!file.exists(creds)) {
    cat(sprintf("DSAPP_MAIL_CREDS 指的文件不存在：%s\n", creds), file = stderr())
    quit(status = 2L)
  }
  readRenviron(creds)
  if (nzchar(data_root_keep)) Sys.setenv(DSAPP_DATA_ROOT = data_root_keep)
}

say <- function(...) cat(sprintf(...), "\n", file = stderr())
ok <- TRUE; nfail <- 0L
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) say("  \033[32m✓\033[0m %s %s", name, extra)
  else { ok <<- FALSE; nfail <<- nfail + 1L
         say("  \033[31m✗ %s\033[0m %s", name, extra) }
}

TO <- if (length(args) >= 2) args[[2]] else "wchcpu2019@163.com"

for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()

say("\n== 配置 ==")
if (!isTRUE(dsapp_mail_ready(cfg))) {
  say("这个应用目录没配齐 SMTP（HOST/USER/PASS/FROM 有一个是空的），跳过。")
  say("要跑这个验收，先在 .Renviron 里补齐 DSAPP_SMTP_*。")
  quit(status = 0L)
}
say("  发件人：%s（密码不打印，任何情况下都不）", cfg$mail$from %||% "?")
say("  data_root：%s", cfg$data_root)
if (!grepl("^/tmp/", cfg$data_root)) {
  say("\n\033[33m⚠️ data_root 不在 /tmp —— 这看着像**生产库**。\033[0m")
  say("   本文件会往库里建账号 / 会话 / 任务行（都是验收痕迹）。")
  say("   确实要对着它跑的话，设 DSAPP_NOTIFY_ALLOW_PROD=1 再跑一次。")
  if (!nzchar(Sys.getenv("DSAPP_NOTIFY_ALLOW_PROD", ""))) quit(status = 2L)
}
con <- dsapp_db(cfg)

# ⚠️ 干跑时**必须把 kick 堵死**：`dsapp_task_notify()` 入队之后会调
#    `dsapp_mail_kick()` 起一个后台子进程去排空 —— 那个子进程是真的会发信的，
#    光在这里"不调 drain"根本拦不住它，信照样出去。
#    kick 的判据是 `getOption("dsapp.mail.kick")` 上那个句柄还活着
#    （见 R/mail.R 的 dsapp_mail_kick），所以放一个"永远活着"的假句柄，
#    它就会安静地返回 FALSE。
if (nzchar(Sys.getenv("DSAPP_MAIL_DRY", ""))) {
  options(dsapp.mail.kick = list(proc = list(is_alive = function() TRUE)))
}

# ---- 造一个收件账号（收件地址必须来自 users.email，不能手填） ----------------
say("\n== 账号 ==")
u <- dsapp_user_by_email(TO, con = con)
if (is.null(u)) {
  mk <- dsapp_user_create(nickname = "邮件验收账号", email = TO,
                          phone = "13000000000", field = "验收",
                          password = dsapp_token(12), con = con)
  if (!isTRUE(mk$ok)) { say("  建号失败：%s", mk$msg %||% "?"); quit(status = 2L) }
  u <- dsapp_user_by_email(TO, con = con)
}
if (is.null(u) || !length(u$id)) { say("  拿不到账号行，停。"); quit(status = 2L) }
uid <- as.integer(u$id[1])
say("  id=%s  邮箱=%s（收件地址取自 users.email）", uid,
    as.character(u$email[1] %||% ""))

# ⚠️ 邮件那一栏的偏好：**成功和失败共用一个键** `email_task`。
#    拆成两个的话，「言出法随」页那一个总勾选框和设置页的两个细勾选框会对不上
#    （只关一半时总开关显示什么都是错的）。理由写在 R/uiprefs.R 的规格那儿。
pref_on <- function(v) {
  p <- dsapp_uipref_get(uid, con = con)
  p$email_task <- v
  dsapp_uipref_save(uid, p, con = con)
  isTRUE(dsapp_uipref_get(uid, con = con)$email_task)
}
say("  打开 email_task 开关：%s", pref_on(TRUE))

sid <- db_session_create("邮件验收会话", user_id = uid, con = con)
chk("建了会话", nzchar(sid %||% ""), sprintf("(%s)", sid))
ws <- tryCatch(dsapp_ws_dir(sid), error = function(e) NULL)

# ---- 造任务 + 走**真的**收尾 -------------------------------------------------
#
# r 的形状照 dsapp_job_poll() 拿回来的那份（见 R/taskrun.R 里
# dsapp_task_closeout 的 docstring）。ok=TRUE 表示执行进程正常回传了结果，
# 这时状态由 r$status 决定；ok=FALSE 走的是"执行进程意外退出"那条分支。
mk_task <- function(title, status, code = "1 + 1", exit_code = 0L,
                    stderr = "") {
  tid <- db_task_create(title, code, lang = "R", session_id = sid, con = con)
  db_task_status(tid, "running", con = con)
  r <- list(ok = TRUE, status = status, exit_code = exit_code,
            stdout = "[1] 2\n", stderr = stderr,
            workdir = ws, artifacts = character(0), saved = character(0))
  dsapp_task_closeout(tid, r, cfg = cfg)
  tid
}
rows_for <- function(tid) {
  DBI::dbGetQuery(con,
    "SELECT id, to_email, subject, body_md, kind, ref, status, tries, last_error
       FROM mail_queue WHERE ref = ?", params = list(sprintf("task:%s", tid)))
}

say("\n== A. 成功的任务 ==")
tid_ok <- mk_task("验收：跑得成的那个", "success")
a <- rows_for(tid_ok)
chk("★ 收尾之后队列里有且只有一行", nrow(a) == 1L, sprintf("(n=%d)", nrow(a)))
if (nrow(a)) {
  chk("★ kind 是 task", identical(as.character(a$kind[1]), "task"),
      as.character(a$kind[1]))
  chk("★★ 收件人是 users.email（不是别处来的地址）",
      identical(as.character(a$to_email[1]), TO), as.character(a$to_email[1]))
  chk("★★ 主题带 ✅ 和「跑完了」",
      grepl("✅", a$subject[1], fixed = TRUE) &&
        grepl("跑完了", a$subject[1], fixed = TRUE), a$subject[1])
  chk("★ 主题里有任务标题", grepl("跑得成的那个", a$subject[1], fixed = TRUE))
  chk("★ 正文里有任务号", grepl(sprintf("#%s", tid_ok), a$body_md[1],
                                fixed = TRUE))
  chk("★ 成功的信里不该出现「报错信息」那一段",
      !grepl("报错信息", a$body_md[1], fixed = TRUE))
}

say("\n== B. 失败的任务 ==")
# ⚠️ 这段 stderr 里**故意**放了 `<` `&` 和中文 —— 它们是 R 报错的常见字符，
#    而正文里走的是"行尾两空格换行"而不是代码块，正是为了让它们原样显示
#    （代码块会被二次转义成 &amp;lt;，见 R/taskrun.R 里那段说明）。
err_txt <- paste(c("Error in check_install(pkg):",
                   "  package 'NotARealPkg' is not available",
                   "Calls: <Anonymous> & handler",
                   "执行中断"), collapse = "\n")
tid_bad <- mk_task("验收：跑挂的那个", "failed", exit_code = 1L,
                   stderr = err_txt)
b <- rows_for(tid_bad)
chk("★ 失败也发（用户要求：成败都要发）", nrow(b) == 1L,
    sprintf("(n=%d)", nrow(b)))
if (nrow(b)) {
  chk("★★ 主题带 ❌ 和「失败了」",
      grepl("❌", b$subject[1], fixed = TRUE) &&
        grepl("失败了", b$subject[1], fixed = TRUE), b$subject[1])
  chk("★★ 正文带上了 stderr 的尾巴（那才是「为什么挂了」）",
      grepl("NotARealPkg", b$body_md[1], fixed = TRUE))
  # ⚠️ 这两条是**渲染层面**的：正文里不能出现裸 `<`（会被当 HTML 标签），
  #    也不能出现 HTML 实体（说明被二次转义了）。两条都指向"用户看到的乱码"。
  chk("★★ 报错里的 `<` `&` 在正文里是原样的（没有被转义成实体）",
      grepl("<Anonymous> & handler", b$body_md[1], fixed = TRUE) &&
        !grepl("&amp;lt;", b$body_md[1], fixed = TRUE) &&
        !grepl("&amp;amp;", b$body_md[1], fixed = TRUE))
  chk("★ 正文里有退出码", grepl("1", b$body_md[1], fixed = TRUE))

  # ★★ 光看 body_md 不够 —— 用户看到的是**渲染之后**的 HTML，而报错信息
  #    恰恰是最容易在这一步坏掉的东西：正文走 dsapp_escape() → commonmark，
  #    多转义一层的话 `&` 会变成 `&amp;amp;`，收件人看到的是一串实体码。
  #    R/taskrun.R:186-190 那段"用行尾两空格、不用代码块"的说明就是在防它，
  #    这条断言是那段说明的**证据**（不然它只是一句注释）。
  rb <- tryCatch(dsapp_mail_render(b$body_md[1], base_dir = ""),
                 error = function(e) list(html = "", note = conditionMessage(e)))
  chk("★★ 渲染后的 HTML 里报错是「看得懂的」（没有二次转义）",
      grepl("NotARealPkg", rb$html %||% "", fixed = TRUE) &&
        !grepl("&amp;lt;", rb$html %||% "", fixed = TRUE) &&
        !grepl("&amp;amp;", rb$html %||% "", fixed = TRUE))
  chk("★ 渲染后的 HTML 里没有裸的 <Anonymous>（那是没转义）",
      !grepl("<Anonymous>", rb$html %||% "", fixed = TRUE))
}

# ---- C. 开关关掉 = 一封信都不入队（负对照） ---------------------------------
#
# ⚠️ 这条不能省。没有它的话，"信发出去了"这个结论和"根本没检查开关"是
#    分不开的 —— 而"用户明确关了却还收到信"是这个功能最招人烦的失败。
say("\n== C. 关掉开关（负对照）==")
say("  关掉 email_task：%s", !pref_on(FALSE))
tid_off <- mk_task("验收：开关关着的那个", "success")
c_off <- rows_for(tid_off)
chk("★★ 开关关着时一行都不建", nrow(c_off) == 0L, sprintf("(n=%d)", nrow(c_off)))
# 后面的 D/E 还要发信，开关得按回去。invisible 不能省：pref_on 返回逻辑值，
# 裸调一次就会在日志里多打一个没头没尾的 `[1] TRUE`。
invisible(pref_on(TRUE))

# ---- D. 只认终态：还在跑的任务不发 ------------------------------------------
say("\n== D. 任务还在跑 ==")
tid_run <- db_task_create("验收：还在跑的那个", "Sys.sleep(1)", lang = "R",
                          session_id = sid, con = con)
db_task_status(tid_run, "running", con = con)
invisible(dsapp_task_notify(tid_run, cfg))
d_run <- rows_for(tid_run)
chk("★ status='running' 时不发（收尾还没走到写状态那一步）",
    nrow(d_run) == 0L, sprintf("(n=%d)", nrow(d_run)))

# ---- E. ref 去重：同一个任务再通知一次，不会多出一封信 ----------------------
say("\n== E. 重复通知 ==")
invisible(dsapp_task_notify(tid_ok, cfg))
e <- rows_for(tid_ok)
chk("★★ 第二次通知没有多建行（ref 唯一索引挡住的）", nrow(e) == 1L,
    sprintf("(n=%d)", nrow(e)))
chk("★ 还是原来那一行（id 没变）", nrow(e) == 1L && identical(as.integer(e$id[1]),
                                                             as.integer(a$id[1])))

# ---- F. 真的发出去 ----------------------------------------------------------
#
# ⚠️ 这里和 real_mail.R 不同：**不**同步 drain，而是先等 dsapp_task_notify
#    里那次 `dsapp_mail_kick()` 起的后台子进程。生产走的就是这条路
#    （收尾钩子在主进程里跑，主进程绝不做 SMTP 握手），同步 drain 等于验了
#    一条线上不会走的路。子进程起不来的话再退回同步 drain，并在结论里说明。
# ⚠️ `DSAPP_MAIL_DRY=1` → 验到"两封信都正确入队了"为止，**不投递**。
#    调模板（改一个字）的时候很需要它：每跑一次就真发两封，收件箱会被淹掉，
#    而"这条路真能发出去"这个事实只需要验一次。真投递那次的证据是收件箱。
if (nzchar(Sys.getenv("DSAPP_MAIL_DRY", ""))) {
  say("\n== F. 投递 ==")
  say("  （DSAPP_MAIL_DRY 已设：到此为止，不投递。A~E 就是全部结论。）")
  say("  ⚠️ 队列里留着两条 pending，跑真投递前先清掉它们：")
  say("     DELETE FROM mail_queue WHERE id IN (%s, %s);",
      a$id[1] %||% "?", b$id[1] %||% "?")
  if (ok) say("\n\033[1m=== 干跑全过（没有发信）===\033[0m")
  quit(status = if (ok) 0L else 1L)
}
say("\n== F. 投递 ==")
qids <- c(a$id[1] %||% NA_integer_, b$id[1] %||% NA_integer_)
deadline <- Sys.time() + 120
st <- rep(NA_character_, length(qids))
repeat {
  st <- vapply(qids, function(q) {
    if (is.na(q)) return(NA_character_)
    r <- tryCatch(DBI::dbGetQuery(con,
      "SELECT status FROM mail_queue WHERE id = ?", params = list(as.integer(q))),
      error = function(e) NULL)
    if (is.null(r) || !nrow(r)) NA_character_ else as.character(r$status[1])
  }, character(1))
  if (all(st %in% c("sent", "failed")) || Sys.time() > deadline) break
  Sys.sleep(1)
}
say("  等待 %.0f 秒后队列状态：%s", as.numeric(Sys.time() - (deadline - 120),
                                              units = "secs"),
    paste(sprintf("%s=%s", qids, st), collapse = "  "))

if (!all(st %in% c("sent", "failed"))) {
  say("  后台子进程没在 120 秒内排完（可能没起来）。同步 drain 一次兜底。")
  t0 <- Sys.time()
  res <- tryCatch(dsapp_mail_drain(cfg, max = 5L),
                  error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
  say("  同步 drain 用了 %.1f 秒：%s", as.numeric(Sys.time() - t0, units = "secs"),
      paste(utils::capture.output(str(res)), collapse = " "))
  st <- vapply(qids, function(q) {
    r <- DBI::dbGetQuery(con, "SELECT status FROM mail_queue WHERE id = ?",
                         params = list(as.integer(q)))
    if (!nrow(r)) NA_character_ else as.character(r$status[1])
  }, character(1))
}

final <- DBI::dbGetQuery(con,
  "SELECT id, subject, status, tries, last_error, sent_at
     FROM mail_queue WHERE id IN (?, ?)", params = as.list(as.integer(qids)))
for (i in seq_len(nrow(final))) {
  say("  #%s  %s  status=%s tries=%s sent_at=%s", final$id[i],
      final$subject[i], final$status[i], final$tries[i],
      final$sent_at[i] %||% "—")
}
chk("★★ 成功通知的信 status='sent'",
    identical(tryCatch(as.character(final$status[final$id == a$id[1]][1]),
                       error = function(e) ""), "sent"))
chk("★★ 失败通知的信 status='sent'",
    identical(tryCatch(as.character(final$status[final$id == b$id[1]][1]),
                       error = function(e) ""), "sent"))
for (i in seq_len(nrow(final))) {
  if (!identical(as.character(final$status[i]), "sent")) {
    say("  \033[31m#%s 投递失败原因：%s\033[0m", final$id[i],
        substr(as.character(final$last_error[i] %||% "（空）"), 1L, 400L))
  }
}

# ---- G. 密码卫生 ------------------------------------------------------------
# 队列里躺着的是**正文**，而正文会进日志、进界面。密码出现在这里的唯一
# 可能就是有人在拼报文时把 cfg 整个打进去了。
say("\n== G. 密码 ==")
pw <- as.character(cfg$mail$pass %||% "never-match-me")
blob <- paste(c(a$body_md %||% "", b$body_md %||% "",
                a$subject %||% "", b$subject %||% "",
                final$last_error %||% ""), collapse = "\n")
chk("★★ SMTP 密码不在主题/正文/错误信息里", !grepl(pw, blob, fixed = TRUE))

# ---- 收尾 --------------------------------------------------------------------
say("")
if (ok) {
  say("\033[1m=== 任务通知验收通过：两封信都投给了 %s ===\033[0m", TO)
  say("⚠️ 最后一步是**人**的活：收件箱里应该有两封 ——")
  say("   · 「✅ 任务跑完了：验收：跑得成的那个」")
  say("   · 「❌ 任务失败了：验收：跑挂的那个」，正文末尾带一段报错")
  say("   （没看到就翻垃圾邮件；新发件人第一次投递常被拦。）")
} else {
  say("\033[1m=== 有 %d 项没过 ===\033[0m", nfail)
}
say("  本次造的行：账号 id=%s、会话 %s、任务 %s/%s/%s/%s",
    uid, sid, tid_ok, tid_bad, tid_off, tid_run)
say("  （探针库里留着无妨；要对生产库跑过的话记得清掉。）")
quit(status = if (ok) 0L else 1L)
