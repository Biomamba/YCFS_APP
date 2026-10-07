#!/usr/bin/env Rscript
# Test_V15.2 · 任务结束的邮件提醒钩子（dsapp_task_notify）
#
#   cd /tmp/dsapp_v152/fake/app && Rscript tests/v152_task_notify.R
#
# ⚠️ 必须在 /tmp 的**假 SMTP 实例**里跑（自带 .Renviron，指向 127.0.0.1:2525）。
#    在仓库目录里跑会被拒 —— 那会拿生产库和生产 SMTP 做测试。
#
# 分两段：
#   A 入队逻辑（不联网）：谁在什么条件下会进队列、ref 去重挡不挡得住
#   B 端到端：kick → 子进程 drain → 假服务器真的收到了那封信
#
# ⚠️ B 段是关键。A 段全绿只说明"行写对了"，说明不了"信发出去了" ——
#    Test_V15.2 开发期正是栽在这种"入库全绿、东西没到"上。

setwd("/tmp/dsapp_v152/fake/app")
for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-24s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}

# ⚠️ 双保险：这个脚本会真的发信，绝不许对着生产库/生产 SMTP 跑。
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")
if (!identical(cfg$mail$host, "127.0.0.1")) stop("拒绝对着真 SMTP 跑")

con <- dsapp_db(cfg)
qry <- function(sql, ...) DBI::dbGetQuery(con, sql, params = list(...))
q <- function(ref) qry("SELECT * FROM mail_queue WHERE ref = ?", ref)

# ---- 造数据 ------------------------------------------------------------------
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("测试乙", sprintf("tester%d@example.org", stamp),
                         sprintf("138%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
say("建了测试账号", isTRUE(reg$ok), if (!isTRUE(reg$ok)) reg$msg else "")
if (!isTRUE(reg$ok)) quit(status = 1L)
u <- dsapp_user_by_email(sprintf("tester%d@example.org", stamp), con = con)
uid <- as.integer(u$id)
say("查到账号 id", !is.na(uid), sprintf("（id=%s）", uid))
if (is.na(uid)) quit(status = 1L)

sid <- db_session_create("提醒测试会话", user_id = uid, con = con)
mk_task <- function(title, status, stderr = "") {
  tid <- db_task_create(title, "1+1", session_id = sid, con = con)
  db_task_status(tid, status, exit_code = if (identical(status, "success")) 0L else 1L,
                 stderr = stderr, con = con)
  tid
}
set_prefs <- function(...) {
  p <- dsapp_uipref_get(uid, con = con)
  for (kv in list(...)) p[[names(kv)]] <- kv[[1]]
  dsapp_uipref_save(uid, p, con = con)
}

# ---- A1：开关关着 → 什么都不该进队 -------------------------------------------
set_prefs(list(email_task = FALSE))
t_off <- mk_task("关着开关的任务", "success")
dsapp_task_notify(t_off, cfg)
say("开关关着不发", nrow(q(sprintf("task:%s", t_off))) == 0L)

# ---- A2：打开成功开关 → 进队，字段要对 ---------------------------------------
set_prefs(list(email_task = TRUE))
t_ok <- mk_task("成功任务·单细胞聚类", "success")
dsapp_task_notify(t_ok, cfg)
r <- q(sprintf("task:%s", t_ok))
say("成功任务进队", nrow(r) == 1L, sprintf("（%d 行）", nrow(r)))
if (nrow(r) == 1L) {
  say("收件人是账号邮箱", identical(r$to_email[1], sprintf("tester%d@example.org", stamp)),
      r$to_email[1])
  say("to_email 就是 users.email",
      identical(r$to_email[1], as.character(dsapp_user_by_id(uid, con = con)$email)[1]))
  say("kind = task", identical(r$kind[1], "task"))
  say("status = pending", identical(r$status[1], "pending"))
  say("user_id 对得上", identical(as.integer(r$user_id[1]), uid))
  say("主题带任务名", grepl("单细胞聚类", r$subject[1], fixed = TRUE), r$subject[1])
  say("正文带退出码", grepl("退出码", r$body_md[1], fixed = TRUE))
}

# ---- A3：同一封不许进两次（ref 唯一索引）-------------------------------------
dsapp_task_notify(t_ok, cfg)
dsapp_task_notify(t_ok, cfg)
say("重复调用只一行", nrow(q(sprintf("task:%s", t_ok))) == 1L,
    sprintf("（%d 行）", nrow(q(sprintf("task:%s", t_ok)))))

# ---- A4：同一个键也管失败 ------------------------------------------------
t_fail <- mk_task("失败任务", "failed", stderr = "Error: 找不到对象 'x'\nExecution halted")
dsapp_task_notify(t_fail, cfg)
r2 <- q(sprintf("task:%s", t_fail))
say("失败任务进队", nrow(r2) == 1L)
if (nrow(r2) == 1L) {
  say("正文带报错", grepl("找不到对象", r2$body_md[1], fixed = TRUE))
  say("主题说失败了", grepl("失败", r2$subject[1], fixed = TRUE), r2$subject[1])
}
# 超时也算失败那一类
t_to <- mk_task("超时任务", "timeout")
dsapp_task_notify(t_to, cfg)
say("超时也发", nrow(q(sprintf("task:%s", t_to))) == 1L)

# ---- A6：没有邮箱的账号 / 非终态 / 查不到的任务 ------------------------------
say("不存在的任务不炸",
    isTRUE(tryCatch({ dsapp_task_notify(999999L, cfg); TRUE },
                    error = function(e) FALSE)))
# 非终态（任务还在跑）不发 —— 用一张 pending 的
t_run <- db_task_create("还在跑", "1+1", session_id = sid, con = con)
dsapp_task_notify(t_run, cfg)
say("非终态不发", nrow(q(sprintf("task:%s", t_run))) == 0L)

# ---- A7：closeout 的 on.exit 真的接上了（源码级）------------------------------
# 行为上验不了"必然调" —— 只能读源码确认钩子挂在函数入口。
src <- paste(readLines("R/taskrun.R", warn = FALSE), collapse = "\n")
fn <- regmatches(src, regexpr("dsapp_task_closeout <- function.*", src))
# ⚠️ 匹配的是**性质**（"on.exit 那一行里有 notify"），不是字面形状。
#    第一版写成 `on\.exit\(dsapp_task_notify`，后来给钩子加了一层 tryCatch
#    就失配了 —— 断言绑在实现的长相上，实现一改就假红（而功能是好的）。
say("closeout 用 on.exit 挂钩子",
    grepl("on\\.exit\\([^\\n]*dsapp_task_notify", fn))
# 钩子自己还得裹一层 tryCatch：on.exit 不吞异常，光靠被调方自觉是单点。
say("钩子裹了 tryCatch",
    grepl("on\\.exit\\(\\s*tryCatch\\([^\\n]*dsapp_task_notify", fn))

# ★ 上面这几条是**剥掉注释再 grep**（教训：要查的写法往往就写在解释它的注释里）
strip_c <- function(txt) {
  txt <- gsub("(?m)#.*$", "", txt, perl = TRUE)
  gsub("(?s)#'.*?\n", "\n", txt, perl = TRUE)
}
say("钩子在源码里（剥注释后）",
    grepl("on\\.exit\\([^\\n]*dsapp_task_notify", strip_c(fn)))

# ---- B：端到端 —— kick → 子进程 drain → 假服务器 -----------------------------
cat("\n=== 端到端（假 SMTP）===\n")
# A 段攒下的 pending 行先清掉，免得干扰"收到了几封"的计数
DBI::dbExecute(con, "DELETE FROM mail_queue WHERE status = 'pending'")

outdir <- "/tmp/dsapp_v152/fakesmtp_task"
unlink(outdir, recursive = TRUE)
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
out_log <- file.path(outdir, "server.out")
system2("python3", c("tests/fake_smtp.py", "2525", outdir, "--count", "1",
                     "--timeout", "40"),
        wait = FALSE, stdout = out_log, stderr = out_log)
up <- FALSE
for (i in 1:100) {
  Sys.sleep(0.1)
  if (file.exists(out_log) &&
      any(grepl("^READY", readLines(out_log, warn = FALSE)))) { up <- TRUE; break }
}
say("假服务器起来了(2525)", up)
if (!up) { cat(readLines(out_log, warn = FALSE), sep = "\n"); quit(status = 1L) }

t_e2e <- mk_task("端到端任务·发信验证", "success")
dsapp_task_notify(t_e2e, cfg)
say("进队了", nrow(q(sprintf("task:%s", t_e2e))) == 1L)

# ⚠️ kick 起的是**子进程**，它重读 cwd 的 .Renviron —— 所以必须在这个
#    实例目录里跑，cfg 也要显式传（子进程不继承父进程的内存）。
dsapp_mail_kick(cfg)

sent <- FALSE
for (i in 1:200) {
  Sys.sleep(0.1)
  r3 <- q(sprintf("task:%s", t_e2e))
  if (nrow(r3) == 1L && identical(r3$status[1], "sent")) { sent <- TRUE; break }
  if (nrow(r3) == 1L && identical(r3$status[1], "failed")) break
}
r3 <- q(sprintf("task:%s", t_e2e))
say("队列标记为已发", sent,
    sprintf("（status=%s tries=%s err=%s）", r3$status[1], r3$tries[1],
            substr(r3$last_error[1] %||% "", 1, 80)))

eml <- file.path(outdir, "msg_1.eml")
for (i in 1:100) { Sys.sleep(0.1); if (file.exists(eml)) break }
say("假服务器收到了", file.exists(eml),
    sprintf("（%d 字节）", if (file.exists(eml)) file.size(eml) else 0L))
if (file.exists(eml)) {
  msg <- rawToChar(readBin(eml, "raw", n = file.size(eml)))
  env <- paste(readLines(file.path(outdir, "msg_1.env"), warn = FALSE), collapse = " ")
  say("收件人是这个账号", grepl(sprintf("tester%d@example.org", stamp), env))
  say("主题是编码词", grepl("Subject: =\\?UTF-8\\?B\\?", msg))
  say("信里没漏密码", !grepl(cfg$mail$pass, msg, fixed = TRUE))
}

for (i in 1:100) { Sys.sleep(0.1)
  if (any(grepl("^DONE", readLines(out_log, warn = FALSE)))) break }
say("服务器干净退出",
    any(grepl("^DONE got=1", readLines(out_log, warn = FALSE))),
    paste(tail(readLines(out_log, warn = FALSE), 2), collapse = " | "))

cat("\n", if (ok) "=== 任务提醒全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
