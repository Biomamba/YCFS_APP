#!/usr/bin/env Rscript
# Test_V15.2 · 定时订阅调度器（**oneshot**，不留常驻进程）
#
#   cd /data3/biomamba/analysis/DS_App && Rscript run_scheduler.R
#
# 由 systemd 的 dsapp-lit.timer 每 5 分钟起一次（见 deploy_link.sh 那一节）。
# 干三件事，一件都不能省：
#
#   1. dsapp_lit_reclaim()  —— 把卡住的订阅放回去（见下）
#   2. dsapp_lit_tick()     —— 把到点的订阅跑掉、发信
#   3. dsapp_mail_drain()   —— 把队列里剩下的信发出去
#
# ⚠️⚠️ 为什么是 oneshot 而不是常驻守护进程：
#    R 是单线程的，一个"睡 5 分钟看一眼"的常驻进程要么拿 sleep 占着（那
#    它就没法在被 systemctl stop 时干净退出），要么自己实现调度循环 ——
#    而 systemd 的 timer 已经把这件事做完了，而且带日志、带重启策略、
#    带 `systemctl list-timers` 能一眼看见下次什么时候跑。
#
# ⚠️⚠️ 第 3 步不是"顺手"。任务提醒那封信是**网页进程**入队 + kick 出去的；
#    如果那一刻 kick 没起来（options 被别的调用覆盖、callr 起不来、
#    或者页面正好在关），那封信就躺在库里没人管。这个 oneshot 是它唯一的
#    兜底 —— 少了这一步，症状是"有时候收不到任务邮件，刷新一下又好了"。
#
# ⚠️ 这个脚本一次可能跑**很久**（每条订阅最长 DSAPP_LIT_RUN_WALL 秒，
#    一轮最多 DSAPP_LIT_TICK_MAX 条）。systemd 那边要给它足够的时间，
#    或者干脆设成 Type=oneshot 不设 TimeoutStartSec 上限 —— 具体见单元文件。

# ---------------------------------------------------------------------------
# 0. 站到应用目录上
# ---------------------------------------------------------------------------
#
# ⚠️⚠️ 必须在**任何 dsapp_config() 之前**。R 启动时会读 `<工作目录>/.Renviron`，
#    而 `.Renviron` 里的值**盖掉**继承来的同名环境变量（R 的既定行为）。
#    这里要的正是**生产**那份 .Renviron（DSAPP_DATA_ROOT / SMTP 凭据都在里面），
#    所以站对目录是这里唯一的正确做法。
#
#    单元文件里也有 WorkingDirectory=，两个都要有：
#      · 单元里的那个管"systemd 从哪儿起它"
#      · 这一句管"不管从哪儿起都站对地方"（手工 Rscript 跑、cron 跑、别的
#        单元拿它当 ExecStart 跑）
#    只留单元里那个的话，手工 `Rscript run_scheduler.R` 会从当前目录读
#    .Renviron —— 在测试实例里跑就到了生产库上，而且不报错。
.args <- commandArgs(trailingOnly = FALSE)
.app_dir <- NULL
.f <- grep("^--file=", .args, value = TRUE)
if (length(.f)) {
  .app_dir <- dirname(normalizePath(sub("^--file=", "", .f[1]), mustWork = FALSE))
}
if (is.null(.app_dir) || !dir.exists(file.path(.app_dir, "R"))) {
  # 走不到这儿（systemd 会指对目录），但真走到了也别往下跑：
  # source 不到 R/*.R 的话后面每一句都是"找不到函数"，而那看起来像代码坏了。
  stop("定位不到应用目录（R/ 不在 --file= 的同级）。用 `Rscript /绝对路径/run_scheduler.R` 起。")
}
setwd(.app_dir)

# ---------------------------------------------------------------------------
# 1. source R/*.R（跳过 mod_*：它们依赖 shiny，调度器用不着）
# ---------------------------------------------------------------------------
#
# ⚠️ 和 .dsapp_job_worker / .dsapp_agent_worker 用的是同一条路数：
#    list.files 的默认顺序是字母序，和 app.R 的 files 向量**不是**同一个顺序。
#    这里能这么偷懒是因为 R/*.R 的顶层只有函数定义和常量（没有互相依赖的
#    副作用代码），顺序无所谓。哪天有人往某个文件顶层加一句"必须在别人之前
#    跑"的代码，这条假设就破了 —— 所以别加。
for (f in list.files(file.path(.app_dir, "R"), full.names = TRUE)) {
  if (grepl("^mod_", basename(f))) next
  source(f, local = globalenv())
}

# 起不来的话要**非零退出** —— 单元是 Type=oneshot，退出码进 journal，
# `systemctl status dsapp-lit` 一眼能看见红的。
main <- function() {
  t0 <- Sys.time()
  cfg <- dsapp_config()

  cat(sprintf("[lit] tick 开始 %s（data_root=%s，tz=%s）\n",
              format(t0, "%Y-%m-%d %H:%M:%S"), cfg$data_root,
              cfg$tz %||% "UTC"))

  # ---- 1. 先把卡住的订阅放回去 ------------------------------------------
  #
  # ⚠️ 和邮件的 reclaim 是同一个病：认领（last_status='running'）之后进程
  #    要是死了，那一行永远停在 'running'，而 tick 只捞 `next_at <= now`
  #    —— next_at 在认领时就推到了未来，所以它**不会**被再捞起来，
  #    界面上显示"正在跑"，其实那个进程早就没了。
  #
  #    阈值的口径和邮件那边一致：一轮最长 DSAPP_LIT_RUN_WALL 秒，
  #    给一倍余量。
  n <- tryCatch(dsapp_lit_reclaim(cfg = cfg),
                error = function(e) { cat("[lit] 回收卡住的订阅失败：",
                                          conditionMessage(e), "\n"); 0L })
  if (isTRUE(n > 0L)) cat(sprintf("[lit] 回收了 %d 条卡住的订阅\n", n))

  # ---- 2. 跑到点的订阅 ---------------------------------------------------
  #
  # ⚠️ 这一段会阻塞很久（每条最长 DSAPP_LIT_RUN_WALL 秒）。这是**故意的**：
  #    它是 oneshot，没有别的活要干。别为了"快点返回"把它扔进 r_bg ——
  #    那样 systemd 会以为这一轮结束了，5 分钟后起下一个，而前一个还在跑。
  tick <- tryCatch(dsapp_lit_tick(cfg = cfg),
                   error = function(e) {
                     cat("[lit] tick 抛了：", conditionMessage(e), "\n")
                     list(ran = 0L, skipped = 0L, notes = character(0))
                   })
  cat(sprintf("[lit] ran=%s skipped=%s\n",
              tick$ran %||% 0L, tick$skipped %||% 0L))
  for (nt in tick$notes %||% character(0)) cat("[lit]   ", nt, "\n")

  # ---- 3. 把队列里剩下的信发出去 -----------------------------------------
  #
  # ⚠️ 先 reclaim 再 drain，顺序不能反：reclaim 放回去的那些行正是要
  #    这一轮发掉的。
  tryCatch({
    r <- dsapp_mail_reclaim(cfg)
    if (isTRUE(r > 0L)) cat(sprintf("[lit] 回收了 %d 封卡住的信\n", r))
  }, error = function(e) NULL)

  dr <- tryCatch(dsapp_mail_drain(cfg = cfg),
                 error = function(e) {
                   cat("[lit] 排空邮件抛了：", conditionMessage(e), "\n")
                   list(sent = 0L, failed = 0L)
                 })
  cat(sprintf("[lit] 邮件 sent=%s failed=%s\n",
              dr$sent %||% 0L, dr$failed %||% 0L))

  cat(sprintf("[lit] tick 结束，用了 %.1f 秒\n",
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  invisible(TRUE)
}

# ⚠️ 包一层是为了让**异常也变成非零退出码**。Type=oneshot 的单元里，
#    R 的未捕获异常会给退出码 1，看着也对 —— 但它会把异常打到 stderr 而
#    退出码那一栏和"函数返回 FALSE"长得一样。这里显式分开，日志里好认。
res <- tryCatch(main(), error = function(e) e)
if (inherits(res, "error")) {
  cat("[lit] 挂了：", conditionMessage(res), "\n", sep = "")
  quit(status = 1L)
}
quit(status = 0L)
