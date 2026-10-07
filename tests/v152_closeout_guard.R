#!/usr/bin/env Rscript
# Test_V15.2 · 收尾链的守门测试：**发信抛错不能把任务收尾带崩**
#
#   cd /tmp/dsapp_v152/fake/app && Rscript tests/v152_closeout_guard.R
#
# 为什么单独一个文件：这一条验的是 dsapp_task_closeout() 的**注释里写死的规矩**
# ——「这个函数会抛，调用方不许在那里包 tryCatch 把它吞掉」。邮件钩子挂在
# 它的 on.exit 上，如果钩子自己会抛，就等于凭空给它加了一条新的中断路径，
# 而那正是那条规矩要防的事。
#
# ⚠️ 这里的做法是**变异**：把 dsapp_task_notify 换成一个必抛的版本，
#    然后看 dsapp_task_closeout 还正不正常。
#    不这么测的话，"钩子包了 tryCatch"这件事只是注释里的一句话 ——
#    注释不会变红。

setwd("/tmp/dsapp_v152/fake/app")
for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-30s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}

con <- dsapp_db(cfg)
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("收尾测试", sprintf("closeout%d@example.org", stamp),
                         sprintf("139%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
u <- dsapp_user_by_email(sprintf("closeout%d@example.org", stamp), con = con)
sid <- db_session_create("收尾测试会话", user_id = as.integer(u$id), con = con)
tid <- db_task_create("收尾测试任务", "1+1", session_id = sid, con = con)

r <- list(ok = TRUE, status = "success", exit_code = 0L,
          stdout = "[1] 2\n", stderr = "", workdir = NULL,
          artifacts = character(0), saved = character(0),
          remote_note = NULL, env_notes = character(0),
          bad_artifacts = character(0))

# ---- 1) 正常路径：基线 --------------------------------------------------------
res <- tryCatch(dsapp_task_closeout(tid, r, cfg), error = function(e) e)
say("基线：收尾正常返回", !inherits(res, "error"),
    if (inherits(res, "error")) conditionMessage(res) else "")
say("基线：返回了 status",
    is.list(res) && identical(res$status, "success"))

# ---- 2) 变异：把 notify 换成必抛的 --------------------------------------------
# ⚠️ 直接覆盖 globalenv 里的名字 —— on.exit 里的调用是在**退出时**才解析的，
#    所以覆盖之后 dsapp_task_closeout 会用到这个版本。
real_notify <- dsapp_task_notify
dsapp_task_notify <- function(tid, cfg = NULL) stop("变异：发信模块炸了")

tid2 <- db_task_create("变异测试任务", "1+1", session_id = sid, con = con)
res2 <- tryCatch(dsapp_task_closeout(tid2, r, cfg), error = function(e) e)
say("变异下收尾没被带崩", !inherits(res2, "error"),
    if (inherits(res2, "error")) conditionMessage(res2) else "")
say("变异下返回值照旧",
    is.list(res2) && identical(res2$status, "success"))
say("变异下任务状态写对了",
    identical(as.character(db_task_get(tid2, con = con)$status)[1], "success"))

# ---- 3) 反面：证明第 2 条不是"on.exit 会吞异常"给的假绿 -----------------------
# ⚠️ on.exit **不会**吞异常。这一条把它钉死：如果哪天有人把 closeout 里那个
#    tryCatch 删了（以为"notify 自己包了"就够了），第 2 条会立刻变红。
say("on.exit 本身不吞异常",
    inherits(tryCatch({ f <- function() { on.exit(stop("x")); 1L }; f() },
                      error = function(e) e), "error"))

# 换回真的 notify，喂它一个查不到的任务号：内部 tryCatch 该把它吃成 FALSE
dsapp_task_notify <- real_notify
out <- tryCatch(dsapp_task_notify(999999L, cfg), error = function(e) "THREW")
say("真 notify 遇错不抛", !identical(out, "THREW"),
    if (identical(out, "THREW")) "（内部 tryCatch 没兜住）" else "")
say("真 notify 遇错返回 FALSE", isFALSE(out))

cat("\n", if (ok) "=== 收尾守门全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
