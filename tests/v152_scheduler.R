#!/usr/bin/env Rscript
# Test_V15.2 · 调度器：认领、防重跑、回收、以及 run_scheduler.R 本身
#
#   cd /tmp/dsapp_v152/fake/app && Rscript tests/v152_scheduler.R
#
# ⚠️⚠️ 全程**不烧 token**：`dsapp_lit_run_one` 被换成一个假的（只记调用次数）。
#    真跑一次 agent 循环要几十块人民币，而这个文件要跑很多遍。
#    真正"能不能跑通"的那一次在 V3 的手工验收里，用一条真订阅跑一次。
#
# 分三段：
#   A 认领的原子性 —— 到点会被认领、认领之后不会再被捞、撞车只有一个能认领
#   B 回收 —— 卡在 'running' 的会被标红，正在跑的**不许**被抢
#   C run_scheduler.R 本身 —— 能起来、能退出、没到点时什么都不干

setwd("/tmp/dsapp_v152/fake/app")

# ⚠️ 调度器脚本在**仓库根目录**，不在 R/ 里 —— 所以它不跟着 R/*.R 的同步走。
#    这里顺手从仓库拷一份过来，省得每次改完忘了拷、测的还是上一版。
.sched_src <- "/data3/biomamba/analysis/DS_App/run_scheduler.R"
if (file.exists(.sched_src)) file.copy(.sched_src, "run_scheduler.R", overwrite = TRUE)
if (!file.exists("run_scheduler.R")) stop("实例里没有 run_scheduler.R")

for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()
# ⚠️ 双保险。这个脚本会改 lit_subs 里的行，绝不许对着生产库跑。
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-34s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}

con <- dsapp_db(cfg)
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("调度测试", sprintf("sched%d@example.org", stamp),
                         sprintf("136%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234", password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
u <- dsapp_user_by_email(sprintf("sched%d@example.org", stamp), con = con)
uid <- as.integer(u$id)

# 假 run_one：只记次数，不建会话、不起循环、不烧 token
calls <- new.env()
calls$n <- 0L
calls$msg <- ""
real_run_one <- dsapp_lit_run_one
dsapp_lit_run_one <- function(sub, cfg = dsapp_config()) {
  calls$n <- calls$n + 1L
  list(ok = TRUE, msg = "", session = "fake-session")
}

mk_sub <- function(next_at, enabled = 1L, status = "", last_at = NULL) {
  id <- DBI::dbGetQuery(con,
    "INSERT INTO lit_subs (user_id, title, keywords, n_read, n_skim,
                           freq, weekday, day_of_month, hour, minute,
                           enabled, next_at, last_at, last_status, last_error,
                           created_at, updated_at)
     VALUES (?, ?, '单细胞', 3, 5, 'daily', 1, 1, 8, 0, ?, ?, ?, ?, '',
             ?, ?) RETURNING id",
    # ⚠️ last_at 一定要给标量：NULL 的长度是 0，DBI 会抛
    #    "Parameter 5 does not have length 1"（第一版就是这么红的）。
    params = list(uid, sprintf("测试订阅 %s", as.integer(Sys.time())),
                  as.integer(enabled), next_at,
                  if (is.null(last_at)) NA_character_ else as.character(last_at),
                  status, dsapp_now(), dsapp_now()))$id
  as.integer(id)
}
row <- function(id) DBI::dbGetQuery(con, "SELECT * FROM lit_subs WHERE id = ?",
                                    params = list(as.integer(id)))

# ======================= A 认领 ===============================================
cat("=== A 认领 ===\n")
past <- format(Sys.time() - 3600, "%Y-%m-%d %H:%M:%S", tz = cfg$tz)
future <- format(Sys.time() + 86400, "%Y-%m-%d %H:%M:%S", tz = cfg$tz)

id1 <- mk_sub(past)
before <- row(id1)
calls$n <- 0L
# ⚠️ invisible()：dsapp_lit_tick 返回一个 list，裸调会在 stdout 上自动打印
#    一整坨（$ran / $skipped / $notes...），把断言列表冲得没法看。
t1 <- invisible(dsapp_lit_tick(cfg = cfg))
r1 <- row(id1)
say("到点的被认领跑了", calls$n == 1L, sprintf("（假 run_one 调了 %d 次）", calls$n))
say("tick 报了 ran=1", identical(as.integer(t1$ran), 1L))
say("next_at 推到未来", r1$next_at > before$next_at,
    sprintf("（%s → %s）", before$next_at, r1$next_at))
say("next_at 确实在未来", r1$next_at > format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
say("last_status 收尾成 ok", identical(r1$last_status, "ok"))
say("last_at 写上了", nzchar(r1$last_at %||% ""))
say("last_session 记了", identical(r1$last_session, "fake-session"))

# ★ 这一条是**整个订阅功能最重要的不变式**：认领过了就不能再跑
calls$n <- 0L
t2 <- invisible(dsapp_lit_tick(cfg = cfg))
say("第二次 tick 不重跑", calls$n == 0L,
    sprintf("（又调了 %d 次）", calls$n))
say("第二次 ran=0", identical(as.integer(t2$ran), 0L))
say("next_at 没被第二次动过", identical(row(id1)$next_at, r1$next_at))

# 关着的订阅不该被捞。
# ⚠️ 这一条造出来的行**一直关着**，后面不再打开 —— 它 next_at 是过去时，
#    一旦被打开就会参与后面每一次 tick（第一版就是这么红的：后面
#    "回收过的不会被补跑"那一条被它顶掉了）。
id2 <- mk_sub(past, enabled = 0L)
calls$n <- 0L
invisible(dsapp_lit_tick(cfg = cfg))
say("enabled=0 的不跑", calls$n == 0L, sprintf("（调了 %d 次）", calls$n))

# ★★ 撞车：两个 tick 进程**同时**读到同一行的时候，只有一个能认领成功。
#
# ⚠️⚠️ 这一条**必须直接调 dsapp_lit_claim()**，不能靠上面那种"跑两次 tick"。
#    上面那两条（"第二次 tick 不重跑"）其实是被 tick 开头那条 SELECT 挡住的
#    —— 变异测试证实过：把 claim 里 `next_at <= ?` 那个条件改成恒真，
#    那两条**照样全绿**，因为那一行根本进不了循环体。
#    而 SELECT 是**读**，读不加锁：两个进程真的可以同时读到同一行。
#    挡住重复执行的是那条 UPDATE，所以只有直接调它两次才验得到。
src <- paste(readLines("R/litsub.R", warn = FALSE), collapse = "\n")
id_race <- mk_sub(past)
r_race <- row(id_race)
first  <- dsapp_lit_claim(as.list(r_race), Sys.time(), cfg = cfg, con = con)
second <- dsapp_lit_claim(as.list(r_race), Sys.time(), cfg = cfg, con = con)
say("★ 认领第一次成功", isTRUE(first))
say("★★ 认领第二次被挡下", isFALSE(second))
say("认领后状态是 running", identical(row(id_race)$last_status, "running"))
say("认领把 next_at 推走了", row(id_race)$next_at > past)
# 第三个进程也一样挡得住（不是"只挡一次"）
say("第三次也挡得住",
    isFALSE(dsapp_lit_claim(as.list(r_race), Sys.time(), cfg = cfg, con = con)))
calls$n <- 0L
invisible(dsapp_lit_tick(cfg = cfg))
say("已经认领的不被 tick 再跑", calls$n == 0L)
invisible(DBI::dbExecute(con, "UPDATE lit_subs SET last_status = 'ok' WHERE id = ?",
               params = list(as.integer(id_race))))

# 源码级：认领必须发生在跑之前
say("认领发生在跑之前",
    regexpr("dsapp_lit_claim\\(sub", src)[1] <
      regexpr("dsapp_lit_run_one\\(sub", src)[1])

# ======================= B 回收 ===============================================
cat("\n=== B 回收 ===\n")
old <- format(Sys.time() - 3 * DSAPP_LIT_RUN_WALL, "%Y-%m-%d %H:%M:%S", tz = "UTC")
id3 <- mk_sub(future, status = "running", last_at = old)
id4 <- mk_sub(future, status = "running",
              last_at = dsapp_now())            # 刚刚认领的，正在跑
n <- dsapp_lit_reclaim(cfg = cfg, con = con)
say("回收了卡住的那一条", isTRUE(n >= 1L), sprintf("（n=%d）", n))
say("卡住的标成 failed", identical(row(id3)$last_status, "failed"))
say("错误说明说得清", grepl("调度进程", row(id3)$last_error))
say("★ 正在跑的**没被抢**", identical(row(id4)$last_status, "running"),
    row(id4)$last_status)
# ⚠️ next_at 不许被回收动过 —— 动了就是"每 5 分钟重跑一次"的烧钱环
say("回收不动 next_at", identical(row(id3)$next_at, future))
# 回收之后 tick 也不该去跑它（next_at 还在未来）
calls$n <- 0L
t3 <- invisible(dsapp_lit_tick(cfg = cfg))
say("回收过的不会被补跑", calls$n == 0L,
    sprintf("（调了 %d 次，notes=%s）", calls$n,
            paste(t3$notes %||% character(0), collapse = " / ")))

# ======================= C run_scheduler.R ===================================
cat("\n=== C run_scheduler.R ===\n")
invisible(DBI::dbExecute(con, "UPDATE lit_subs SET enabled = 0 WHERE user_id = ?",
                         params = list(uid)))       # 什么都不该跑
out <- suppressWarnings(
  system2("Rscript", "run_scheduler.R", stdout = TRUE, stderr = TRUE))
status <- attr(out, "status") %||% 0L
say("退出码 0", identical(as.integer(status), 0L),
    sprintf("（status=%s）", as.integer(status)))
txt <- paste(out, collapse = "\n")
say("打了 tick 开始", grepl("\\[lit\\] tick 开始", txt))
say("打了 ran=", grepl("\\[lit\\] ran=", txt))
say("打了邮件统计", grepl("\\[lit\\] 邮件 sent=", txt))
# ⚠️ 日志里绝不能出现 SMTP 密码（凭据只进 .Renviron，绝不进日志）
say("日志里没有密码",
    !nzchar(cfg$mail$pass %||% "x") || !grepl(cfg$mail$pass, txt, fixed = TRUE))
# 没到点时一条都不跑
say("没到点就什么都不跑", grepl("\\[lit\\] ran=0 skipped=0", txt),
    paste(grep("\\[lit\\] ran=", out, value = TRUE), collapse = " "))

# 反面：把一条订阅摆成到点，run_scheduler.R 应该**真的**去认领它。
# ⚠️ 这一条会走到 dsapp_lit_run_one —— 真的建会话、真的起 agent 循环、真的烧
#    token。所以**故意不做**：那属于 V3 的手工验收（一次就够），不属于一个
#    要反复跑的自检。这里只验到"脚本能起来、能退出、没到点不干活"。
id5 <- mk_sub(past)
calls$n <- 0L
invisible(dsapp_lit_tick(cfg = cfg))
say("★ 到点的那条被认领（对照）", calls$n == 1L)
invisible(DBI::dbExecute(con, "UPDATE lit_subs SET enabled = 0 WHERE id = ?",
                         params = list(as.integer(id5))))

dsapp_lit_run_one <- real_run_one

cat("\n", if (ok) "=== 调度器全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
