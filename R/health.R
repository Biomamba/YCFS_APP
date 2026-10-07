# =============================================================================
# 服务器健康监控（管理页）
# =============================================================================
# V5 引入，对应 Python 版的 services/monitor.py。回答的是管理页上**别的卡片
# 回答不了**的问题：这台机器还撑得住吗？
#
#   * 「平台用量」说的是"有多少账号、多少任务"；
#   * 「磁盘占用」说的是"我们的目录加起来多少字节"；
#   * 这一块说的是"这块盘还剩多少、内存还够不够再起一个比对任务"。
#
# 三者的差别很实在：数据目录只有 50G，但如果盘上还有别人的 900G，管理员看
# 「磁盘占用」会以为一切正常，直到任务写不进去。
#
# ⚠️ 四条自我约束：
#
#   1. **不读任何用户内容。** 只读 /proc 里的整机计数器和 df 的挂载点。
#      运行中的任务这里只报"引擎忙/闲、跑了多久"，不报是谁的、跑的什么 ——
#      同 mod_admin.R 顶部那条（任务标题常带样本名）。
#
#   2. **任何一项采集失败都不能空掉整块。** /proc 在容器里常常只挂了一部分，
#      数据盘可能已被卸载，df 可能根本没有。每个采集项各自兜底，拿不到的
#      显示「—」并说明原因，绝不让整个管理页打不开 —— 出事的时候，管理页
#      恰恰是最需要能打开的那一页。
#
#   3. **绝不在请求路径上 sleep。** CPU 使用率要两次采样相减，很自然会写成
#      "读一次 → Sys.sleep(0.5) → 再读一次"。**不能这么写**：这个应用是
#      全站**一个 R 进程**，sleep 0.5 秒就是把所有人的界面冻住 0.5 秒，而
#      管理页每 10 秒轮询一次，开三个标签页就是每 10 秒冻 1.5 秒。这里改成
#      "拿上一次采样的结果做基线"，代价是**第一次**调用没有基线（返回 NA），
#      所以启动时先 prime 一次（见 app.R）。
#
#   4. **一次调用给一个快照。** 页面分几次取会拼出"CPU 是 10:00:00 的、
#      磁盘是 10:00:04 的"这种结果，管理员看到"CPU 空载但磁盘在涨"时无从
#      判断是真现象还是采样时机造成的错觉。
#
# 纯函数与副作用分开：解析函数（dsapp_parse_*）只吃文本、吐 list，selftest
# 直接喂真实 /proc 内容就能测，包括那些**只在别人机器上才出现**的怪格式。
# =============================================================================

# ---------------------------------------------------------------------------
# 阈值
# ---------------------------------------------------------------------------
# 写死而不做成配置项：这三个数字调大调小都没有实际意义 —— 任何规模的盘剩
# 5% 都撑不过一次生信任务的数据落盘，内存到 90% 时长任务随时会被 OOM 杀掉。
DSAPP_HEALTH_DISK_CRITICAL_FREE_PCT <- 5    # 剩余低于这个比例 → 严重
DSAPP_HEALTH_DISK_WARN_PCT          <- 90   # 使用率高于这个 → 注意
DSAPP_HEALTH_MEM_WARN_PCT           <- 90
DSAPP_HEALTH_SWAP_WARN_PCT          <- 90

# 快照缓存秒数。管理页每 10 秒刷一次、每个标签页各刷各的，这个窗口把"同时
# 打开的几个页面"合并成一次采集，又短到不会让人看到过期结论（磁盘使用率
# 本来也不会在 5 秒里跳到告警线）。
DSAPP_HEALTH_TTL <- 5

# 采集结果的缓存。**不用 reactiveVal**：这里要能在 Shiny 之外被调用
# （selftest、启动时的 prime），而 reactiveVal 出了响应式上下文就报错。
.dsapp_health_env <- new.env(parent = emptyenv())
.dsapp_health_env$at <- as.POSIXct(NA)
.dsapp_health_env$value <- NULL
.dsapp_health_env$cpu_prev <- NULL   # 上一次的 /proc/stat 计数器，做基线用

#' 清掉采集缓存
#'
#' ⚠️ **默认不动 CPU 基线**（`cpu_prev`）。这一条是走查时踩出来的：
#'    「立即刷新」按钮先清缓存再重算，如果顺手把基线也清了，重算就变成
#'    "没有上一次采样"，CPU 使用率退回 NA，界面上显示「首次采样中…」——
#'    按钮看起来就像把页面弄坏了。而基线根本不是缓存，它是**上一次的测量
#'    结果**，清掉它只会白等一个周期。
#'
#' @param keep_cpu FALSE 时才连基线一起清（只有测试需要）
dsapp_health_reset_cache <- function(keep_cpu = TRUE) {
  .dsapp_health_env$at <- as.POSIXct(NA)
  .dsapp_health_env$value <- NULL
  if (!isTRUE(keep_cpu)) .dsapp_health_env$cpu_prev <- NULL
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# 解析（纯函数，selftest 直接喂文本）
# ---------------------------------------------------------------------------

#' 解析 /proc/stat 的第一行（整机 CPU 计数器）
#'
#' 格式：`cpu  user nice system idle iowait irq softirq steal guest guest_nice`
#' 字段个数随内核版本变（老内核没有 steal/guest），所以按下标取、缺的当 0，
#' 不写死长度。
#'
#' @return list(total, idle, ok)；拿不到就 ok = FALSE
dsapp_parse_stat <- function(lines) {
  ln <- lines[grepl("^cpu ", lines)][1]
  if (is.na(ln) || !nzchar(ln)) return(list(ok = FALSE, total = NA_real_, idle = NA_real_))
  # 按空白切；第一个是 "cpu"
  parts <- strsplit(trimws(ln), "[[:space:]]+")[[1]]
  num <- suppressWarnings(as.numeric(parts[-1]))
  num <- num[!is.na(num)]
  if (length(num) < 4) return(list(ok = FALSE, total = NA_real_, idle = NA_real_))
  # idle 是第 4 个字段，iowait 是第 5 个。**iowait 要算进 idle**：
  # 等磁盘的时间不是 CPU 在干活（生信任务大量时间在等 IO，不算进去的话
  # 一个纯 IO 的任务会让"CPU 使用率"显示成 100%，把人吓一跳）。
  idle <- num[4] + (if (length(num) >= 5) num[5] else 0)
  list(ok = TRUE, total = sum(num), idle = idle)
}

#' 由两次 /proc/stat 采样算 CPU 使用率
#'
#' @return 0-100 的百分比；没有基线或计数器没动时返回 NA（**不是 0** ——
#'   0 会被读成"完全空闲"，而 NA 会被读成"还不知道"，后者才是实话）
dsapp_cpu_percent <- function(prev, now) {
  if (is.null(prev) || is.null(now)) return(NA_real_)
  if (!isTRUE(prev$ok) || !isTRUE(now$ok)) return(NA_real_)
  dt <- now$total - prev$total
  di <- now$idle - prev$idle
  if (!is.finite(dt) || dt <= 0) return(NA_real_)
  pct <- (1 - di / dt) * 100
  # 夹到 [0,100]：多核计时抖动会让个别内核给出 100 出头或极小负值，
  # 进度条遇到这种值会画出格。
  round(max(0, min(100, pct)), 1)
}

#' 解析 /proc/meminfo
#'
#' 形如 `MemTotal:  16316104 kB`。值统一是 kB，转成字节返回。
dsapp_parse_meminfo <- function(lines) {
  out <- list()
  hit <- regmatches(lines, regexec("^([A-Za-z_()]+):[[:space:]]+([0-9]+)", lines))
  for (h in hit) {
    if (length(h) == 3) out[[h[2]]] <- as.numeric(h[3]) * 1024
  }
  if (length(out) == 0) return(list(ok = FALSE))
  out$ok <- TRUE
  out
}

#' 内存/交换分区快照
#'
#' `MemAvailable` 是内核给出的"还能拿来跑新任务"的估计值，比 `MemFree` 更
#' 贴近管理员真正关心的问题（free 不含可回收的页缓存，永远很小）。
#' 老内核（< 3.14）没有这一项，那时退回 MemFree。
dsapp_mem_snapshot <- function(mi) {
  if (is.null(mi) || !isTRUE(mi$ok)) {
    return(list(ok = FALSE, total = NA_real_, used = NA_real_,
                available = NA_real_, percent = NA_real_))
  }
  total <- mi$MemTotal %||% NA_real_
  avail <- mi$MemAvailable %||% mi$MemFree %||% NA_real_
  if (is.na(total) || total <= 0) {
    return(list(ok = FALSE, total = NA_real_, used = NA_real_,
                available = NA_real_, percent = NA_real_))
  }
  used <- total - avail
  list(ok = TRUE, total = total, used = used, available = avail,
       percent = round(max(0, min(100, used * 100 / total)), 1),
       cached = (mi$Cached %||% 0) + (mi$Buffers %||% 0),
       source = if (!is.null(mi$MemAvailable)) "MemAvailable" else "MemFree")
}

#' 交换分区快照
#'
#' 单独看它是因为「内存紧张」和「已经在换页」是两种严重程度：前者还有救，
#' 后者意味着正在跑的任务会被拖慢一个数量级（比对、聚类尤其明显）。
dsapp_swap_snapshot <- function(mi) {
  if (is.null(mi) || !isTRUE(mi$ok)) return(list(ok = FALSE, total = NA_real_, percent = NA_real_))
  total <- mi$SwapTotal %||% 0
  free  <- mi$SwapFree %||% 0
  if (is.na(total) || total <= 0) {
    # 没开交换分区是**正常配置**（很多服务器就是这么设的），不是采集失败。
    # 两者要分开：前者不该在告警里出现，后者要。
    return(list(ok = TRUE, total = 0, used = 0, free = 0, percent = 0,
                none = TRUE))
  }
  used <- total - free
  list(ok = TRUE, total = total, used = used, free = free,
       percent = round(max(0, min(100, used * 100 / total)), 1), none = FALSE)
}

#' 解析 /proc/loadavg
#'
#' `0.52 0.58 0.59 1/1234 56789` —— 前三个是 1/5/15 分钟平均负载。
dsapp_parse_loadavg <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(list(ok = FALSE))
  n <- suppressWarnings(as.numeric(strsplit(trimws(txt), "[[:space:]]+")[[1]][1:3]))
  if (length(n) < 3 || any(is.na(n))) return(list(ok = FALSE))
  list(ok = TRUE, m1 = n[1], m5 = n[2], m15 = n[3])
}

#' 解析库里的 UTC 时间戳
#'
#' 时间戳格式见 utils.R 的 dsapp_now()。**解析失败返回 NA 而不是 0** ——
#' 0 会被读成"刚开始跑"，而"不知道跑了多久"是另一回事（比如库里的时间戳
#' 是空的，或者格式变过）。
#'
#' 单独拎出来是因为它有两个调用方：dsapp_since_seconds（算"到现在多久"）
#' 和管理页的任务耗时列（算"起止之间多久"）。两边各写一遍的话，格式一改
#' 就会只有一边坏 —— 而坏的那一边是静默的（返回 NA，界面显示「—」）。
dsapp_parse_time <- function(ts) {
  if (is.null(ts) || length(ts) != 1 || is.na(ts) || !nzchar(as.character(ts))) {
    return(NA_real_)
  }
  # 显式给 format：as.POSIXct 猜格式时遇到不认识的内容是**抛异常**而不是
  # 返回 NA（"character string is not in a standard unambiguous format"），
  # 一个坏时间戳就能把整块管理页带走。
  t <- tryCatch(
    as.POSIXct(as.character(ts), tz = "UTC", format = "%Y-%m-%d %H:%M:%S"),
    error = function(e) NA)
  if (length(t) != 1 || is.na(t)) return(NA_real_)
  t
}

#' 从库里的 UTC 时间戳算"已经过去多少秒"
#'
#' @return 秒数；解析不了或时钟被回拨过（负数）时 NA
dsapp_since_seconds <- function(ts) {
  t <- dsapp_parse_time(ts)
  if (length(t) != 1 || is.na(t)) return(NA_real_)
  s <- as.numeric(difftime(Sys.time(), t, units = "secs"))
  if (!is.finite(s) || s < 0) return(NA_real_)   # 负数说明时钟被回拨过
  s
}

#' 两个库内时间戳之间隔了多少秒
#'
#' 和 dsapp_since_seconds 的区别：那个算的是"到**现在**"，这个算的是两列
#' 之间的差（任务页的"耗时 = finished_at - started_at"）。
#'
#' @return 秒数；任一端解析不了、或结束早于开始（时钟回拨）时 NA
dsapp_duration_between <- function(from, to) {
  a <- dsapp_parse_time(from)
  b <- dsapp_parse_time(to)
  if (length(a) != 1 || is.na(a) || length(b) != 1 || is.na(b)) return(NA_real_)
  s <- as.numeric(difftime(b, a, units = "secs"))
  if (!is.finite(s) || s < 0) return(NA_real_)
  s
}

#' 解析 /proc/uptime（秒）
dsapp_parse_uptime <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NA_real_)
  v <- suppressWarnings(as.numeric(strsplit(trimws(txt), "[[:space:]]+")[[1]][1]))
  if (length(v) != 1 || is.na(v) || v < 0) return(NA_real_)
  v
}

#' 把秒数说成人话（`3 天 4 小时`）
dsapp_fmt_duration <- function(sec) {
  if (is.null(sec) || length(sec) != 1 || is.na(sec) || !is.finite(sec)) return("—")
  sec <- max(0, as.numeric(sec))
  if (sec < 60) return(sprintf("%.0f 秒", sec))
  if (sec < 3600) return(sprintf("%.0f 分钟", sec / 60))
  if (sec < 86400) return(sprintf("%.1f 小时", sec / 3600))
  d <- floor(sec / 86400); h <- floor((sec %% 86400) / 3600)
  if (h > 0) sprintf("%d 天 %d 小时", d, h) else sprintf("%d 天", d)
}

#' 解析 `df -P -k <path>` 的输出
#'
#' POSIX 输出（`-P`）保证一行一个文件系统，格式：
#'
#'     Filesystem     1024-blocks      Used Available Capacity Mounted on
#'     /dev/sda1        103080888  45678901  52123456      47% /
#'
#' ⚠️ 用正则而不是 strsplit：**挂载点里可以有空格**（`/media/My Data`），
#'    按空白切会把挂载点切碎。正则把前 5 个字段按"数字/百分数"锚死，最后
#'    一段整段当挂载点。文件系统名同理（有些网络盘的名字带空格）。
#'
#' ⚠️ 单位是 **1024 字节块**（`-k` 保证），要乘 1024 才是字节。
dsapp_parse_df <- function(out, path = "") {
  if (is.null(out) || length(out) == 0) {
    return(list(ok = FALSE, path = path, reason = "没有输出"))
  }
  # 去掉表头，找到第一条数据行
  pat <- "^\\s*(.*?)\\s+([0-9]+)\\s+([0-9]+)\\s+([0-9]+)\\s+([0-9]+)%\\s+(.*?)\\s*$"
  for (ln in out) {
    m <- regmatches(ln, regexec(pat, ln))[[1]]
    if (length(m) == 7) {
      total <- as.numeric(m[3]) * 1024
      used  <- as.numeric(m[4]) * 1024
      avail <- as.numeric(m[5]) * 1024
      free_pct <- if (total > 0) round(100 * avail / total, 1) else NA_real_
      return(list(ok = TRUE, path = path, fs = m[2], mount = m[7],
                  total = total, used = used, available = avail,
                  percent = as.numeric(m[6]), free_percent = free_pct))
    }
  }
  list(ok = FALSE, path = path, reason = "看不懂 df 的输出")
}

#' 某个路径所在文件系统的占用
#'
#' 路径不存在（盘被卸载、目录还没建）时 df 会报错退出 —— 如实返回 ok = FALSE，
#' 让界面显示「—」并说明原因，而不是拿一个 0 冒充"这块盘是空的"。
dsapp_disk_snapshot <- function(path) {
  if (is.null(path) || !nzchar(path)) return(list(ok = FALSE, path = "", reason = "没有路径"))
  if (!dir.exists(path)) {
    return(list(ok = FALSE, path = path, reason = "目录不存在（盘被卸载了？）"))
  }
  out <- tryCatch(
    suppressWarnings(system2("df", c("-P", "-k", shQuote(path)),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  # system2 失败时会给一个带 "status" 属性的警告性结果；长度 0 就是没跑起来
  if (length(out) == 0) {
    return(list(ok = FALSE, path = path, reason = "df 跑不起来"))
  }
  dsapp_parse_df(out, path)
}

#' 解析 /proc/self/status 里的几个数（本进程占用）
#'
#' 只取三个数，**不取命令行**（命令行里有部署路径，甚至可能有启动参数里的
#' 密钥）。
dsapp_parse_self_status <- function(lines) {
  get1 <- function(key) {
    ln <- lines[grepl(paste0("^", key, ":"), lines)][1]
    if (is.na(ln)) return(NA_real_)
    v <- suppressWarnings(as.numeric(regmatches(ln, regexpr("[0-9]+", ln))[1]))
    v
  }
  rss_kb <- get1("VmRSS")
  list(ok = !is.na(rss_kb),
       rss = if (is.na(rss_kb)) NA_real_ else rss_kb * 1024,
       threads = get1("Threads"),
       vm_size = { v <- get1("VmSize"); if (is.na(v)) NA_real_ else v * 1024 })
}

# ---------------------------------------------------------------------------
# 采集（有副作用，各自兜底）
# ---------------------------------------------------------------------------

dsapp_read_lines <- function(path, n = -1L) {
  tryCatch(readLines(path, n = n, warn = FALSE), error = function(e) character(0))
}

#' 读一次 /proc/stat 并更新 CPU 基线
#'
#' **不 sleep**（理由见文件头第 3 条）。第一次调用返回 NA，并把当次计数器
#' 存下来；下一次调用才拿得到真实百分比。
dsapp_cpu_sample <- function(stat_lines = NULL) {
  lines <- stat_lines %||% dsapp_read_lines("/proc/stat")
  now <- dsapp_parse_stat(lines)
  prev <- .dsapp_health_env$cpu_prev
  .dsapp_health_env$cpu_prev <- now
  list(ok = isTRUE(now$ok), percent = dsapp_cpu_percent(prev, now),
       primed = !is.null(prev))
}

#' 启动时先采一次，让管理页第一眼就是真值
#'
#' app.R 启动时调一次。代价是一次 readLines，可以忽略。
dsapp_health_prime <- function() {
  # 先清掉可能残留的基线（比如 selftest 里反复调用），保证语义是"从这里开始"
  invisible(tryCatch(dsapp_cpu_sample(), error = function(e) NULL))
}

#' 本进程占用
dsapp_self_snapshot <- function() {
  st <- dsapp_parse_self_status(dsapp_read_lines("/proc/self/status"))
  # 打开的文件描述符数。/proc/self/fd 里是符号链接，list.files 数得出来。
  # 拿不到就给 NA —— 给 0 会被读成"没有句柄泄漏"。
  fds <- tryCatch(length(list.files("/proc/self/fd")), error = function(e) NA_integer_)
  list(ok = isTRUE(st$ok), pid = Sys.getpid(), rss = st$rss,
       threads = st$threads, fds = fds)
}

#' 采集一台机器的健康快照（**带缓存**）
#'
#' @param use_cache FALSE 表示强制重新采集（界面上的"立即刷新"用）
dsapp_health_probe <- function(cfg = dsapp_config(), use_cache = TRUE) {
  now <- Sys.time()
  if (isTRUE(use_cache) && !is.na(.dsapp_health_env$at) &&
      as.numeric(difftime(now, .dsapp_health_env$at, units = "secs")) < DSAPP_HEALTH_TTL &&
      !is.null(.dsapp_health_env$value)) {
    return(.dsapp_health_env$value)
  }

  cpu  <- tryCatch(dsapp_cpu_sample(), error = function(e) list(ok = FALSE, percent = NA_real_))
  mi   <- tryCatch(dsapp_parse_meminfo(dsapp_read_lines("/proc/meminfo")),
                   error = function(e) list(ok = FALSE))
  load <- tryCatch(dsapp_parse_loadavg(
    { l <- dsapp_read_lines("/proc/loadavg"); if (length(l)) l[1] else "" }),
    error = function(e) list(ok = FALSE))
  up   <- tryCatch(dsapp_parse_uptime(
    { l <- dsapp_read_lines("/proc/uptime"); if (length(l)) l[1] else "" }),
    error = function(e) NA_real_)

  mem  <- dsapp_mem_snapshot(mi)
  swap <- dsapp_swap_snapshot(mi)

  # 数据盘和安装目录分开报：这两者经常不在同一个挂载点上，而"数据盘写满"
  # 是这类平台最常见的运维故障 —— 处置方式（清用户数据 vs 清日志）完全不同。
  disk_data <- tryCatch(dsapp_disk_snapshot(cfg$data_root),
                        error = function(e) list(ok = FALSE, path = cfg$data_root, reason = "采集失败"))
  # 程序目录。用 DSAPP_APP_DIR 而不是 getwd()：部署在 shiny-server 下时
  # 工作目录未必是应用目录（app.R 顶部把它记下来了，就是为这种场合）。
  install_root <- Sys.getenv("DSAPP_APP_DIR", "")
  if (!nzchar(install_root)) {
    install_root <- tryCatch(normalizePath(".", mustWork = FALSE), error = function(e) getwd())
  }
  disk_inst <- tryCatch(dsapp_disk_snapshot(install_root),
                        error = function(e) list(ok = FALSE, path = install_root, reason = "采集失败"))

  cores <- tryCatch(parallel::detectCores(), error = function(e) NA_integer_)
  if (is.null(cores) || is.na(cores)) cores <- NA_integer_

  val <- list(
    at = now,
    cpu = list(ok = isTRUE(cpu$ok), percent = cpu$percent,
               primed = isTRUE(cpu$primed), cores = cores,
               load = load,
               # 负载要除以核数才有意义：60 核上 load=12 是轻载，4 核上就是过载
               load_per_core = if (isTRUE(load$ok) && !is.na(cores) && cores > 0)
                 round(load$m1 / cores, 2) else NA_real_),
    mem = mem, swap = swap,
    uptime = up,
    disk = list(data = disk_data, install = disk_inst,
                same_fs = isTRUE(disk_data$ok) && isTRUE(disk_inst$ok) &&
                          identical(disk_data$mount, disk_inst$mount)),
    self = tryCatch(dsapp_self_snapshot(),
                    error = function(e) list(ok = FALSE, pid = Sys.getpid()))
  )
  .dsapp_health_env$value <- val
  .dsapp_health_env$at <- now
  val
}

# ---------------------------------------------------------------------------
# 告警判定（纯函数）
# ---------------------------------------------------------------------------
# 阈值判断放在**这里**而不是界面里：同一份数字将来可能被别的地方用（导出、
# 告警），散在界面里就会各写一份，迟早对不上。
#
# 单独抽成函数还有一个理由：selftest 可以直接构造"磁盘 96%"这种状态去验
# 告警，而不用真的把盘写满。

#' @param probe  dsapp_health_probe() 的结果
#' @param engine 可选的 list(busy=, task_id=, elapsed=)，见 mod_admin 的调用
#' @return list(level = "ok"/"warn"/"critical", issues = 字符向量)
dsapp_health_issues <- function(probe, engine = NULL) {
  issues <- character(0)
  level <- 0L   # 0 = 正常，1 = 注意，2 = 严重
  warn <- function(...) { level <<- max(level, 1L); issues <<- c(issues, paste0(...)) }
  crit <- function(...) { level <<- max(level, 2L); issues <<- c(issues, paste0(...)) }

  # ---- 磁盘 ----
  # 标签里的挂载点读不到时退回**路径**，不要写成「数据盘（?）」——
  # 磁盘采集失败正是最需要知道"该去看哪儿"的时候，一个问号帮不上忙。
  disk_label <- function(d, what) {
    where <- d$mount %||% d$path %||% "?"
    sprintf("%s（%s）", what, where)
  }
  check_disk <- function(d, label) {
    if (is.null(d) || !isTRUE(d$ok)) {
      # 「采集失败」本身要报出来：看不见的盘不能当作没问题
      warn(label, "容量采集失败（", d$reason %||% "未知原因", "），请检查挂载状态")
      return(invisible(NULL))
    }
    if (is.na(d$total) || d$total <= 0) return(invisible(NULL))
    if (!is.na(d$free_percent) && d$free_percent < DSAPP_HEALTH_DISK_CRITICAL_FREE_PCT) {
      crit(label, "剩余空间不足 ", DSAPP_HEALTH_DISK_CRITICAL_FREE_PCT, "%（剩 ",
           dsapp_fmt_bytes(d$available), "），请立即清理")
    } else if (!is.na(d$percent) && d$percent >= DSAPP_HEALTH_DISK_WARN_PCT) {
      warn(label, "使用率已达 ", sprintf("%.0f", d$percent), "%（阈值 ",
           DSAPP_HEALTH_DISK_WARN_PCT, "%）")
    }
    invisible(NULL)
  }
  check_disk(probe$disk$data, disk_label(probe$disk$data, "数据盘"))
  # 安装目录和数据盘同盘时只报一次 —— 同一块盘报两遍会让人以为是两块都满了
  if (!isTRUE(probe$disk$same_fs)) {
    check_disk(probe$disk$install, disk_label(probe$disk$install, "程序目录所在盘"))
  }

  # ---- 内存 ----
  m <- probe$mem
  if (!isTRUE(m$ok)) {
    warn("内存信息采集失败，无法判断是否接近 OOM")
  } else if (!is.na(m$percent) && m$percent >= DSAPP_HEALTH_MEM_WARN_PCT) {
    warn("内存使用率 ", sprintf("%.0f", m$percent), "%（阈值 ",
         DSAPP_HEALTH_MEM_WARN_PCT, "%），长任务可能被 OOM 终止")
  }

  # ---- 交换分区 ----
  sw <- probe$swap
  if (isTRUE(sw$ok) && !isTRUE(sw$none) && !is.na(sw$percent) &&
      sw$percent >= DSAPP_HEALTH_SWAP_WARN_PCT) {
    warn("交换分区使用率 ", sprintf("%.0f", sw$percent),
         "%，系统已开始换页，任务会明显变慢")
  }

  # ---- 负载 ----
  if (isTRUE(probe$cpu$load$ok) && !is.na(probe$cpu$load_per_core) &&
      probe$cpu$load_per_core >= 2) {
    warn("1 分钟负载 ", probe$cpu$load$m1, "，是 ", probe$cpu$cores,
         " 核的 ", probe$cpu$load_per_core, " 倍 —— 任务会明显变慢")
  }

  # ---- 引擎 ----
  # R 版的执行引擎是**全站单槽**的（见 app.R）。它忙的时候别人提交不了任务，
  # 而界面上"排队"是不存在的 —— 用户只会看到"已有任务在执行，请等它结束"。
  # 所以槽位被占多久必须让管理员看得见。
  if (!is.null(engine) && isTRUE(engine$busy)) {
    if (!is.null(engine$elapsed) && !is.na(engine$elapsed) &&
        engine$elapsed > 3600) {
      warn("执行槽已被占用 ", dsapp_fmt_duration(engine$elapsed),
           "（任务 #", engine$task_id %||% "?", "）—— 这期间所有人都提交不了任务")
    }
  }

  list(level = c("ok", "warn", "critical")[level + 1L], issues = issues)
}

#' 完整体检：采集 + 判定 + 引擎状态
#'
#' 采集部分带缓存（5 秒），判定和引擎状态每次现算 —— 引擎忙不忙是**当下**的
#' 事实，缓存它没有意义。
#'
#' @param engine list(busy=, task_id=, elapsed=)，由调用方在响应式上下文里取好
#'   传进来。这里刻意不接收 engine 对象本身：它内部是 reactiveValues，
#'   在这个纯函数里读会直接报错（这个坑 app.R 里记着）。
dsapp_health_summary <- function(cfg = dsapp_config(), engine = NULL, use_cache = TRUE) {
  probe <- dsapp_health_probe(cfg, use_cache = use_cache)
  iss <- dsapp_health_issues(probe, engine)
  c(probe, list(level = iss$level, issues = iss$issues,
                thresholds = list(disk_warn = DSAPP_HEALTH_DISK_WARN_PCT,
                                  disk_critical_free = DSAPP_HEALTH_DISK_CRITICAL_FREE_PCT,
                                  mem_warn = DSAPP_HEALTH_MEM_WARN_PCT,
                                  swap_warn = DSAPP_HEALTH_SWAP_WARN_PCT)))
}

# ---------------------------------------------------------------------------
# 界面片段
# ---------------------------------------------------------------------------

#' 健康等级徽章
dsapp_health_badge <- function(level) {
  spec <- switch(as.character(level %||% "")[1],
    ok       = list("正常", "success"),
    warn     = list("注意", "warning"),
    critical = list("严重", "danger"),
    list("未知", "secondary"))
  tags$span(class = paste0("badge text-bg-", spec[[2]]), spec[[1]])
}

#' 一条"标签 — 进度条 — 数字"的用量行
#'
#' @param warn_pct 超过这个百分比就把进度条染红。**必须由调用方给**：
#'   磁盘、内存、交换分区的告警线是三件事，共用一个默认值迟早会串。
dsapp_health_bar <- function(label, pct, text, sub = NULL, warn_pct) {
  bad <- !is.na(pct) && pct >= warn_pct
  div(class = "mb-2",
    div(class = "d-flex justify-content-between align-items-baseline",
      span(class = "small", label),
      span(class = "small font-monospace", text)),
    div(class = "progress", style = "height:6px;",
      div(class = paste0("progress-bar", if (bad) " bg-danger" else ""),
          role = "progressbar",
          style = sprintf("width:%.1f%%", max(0, min(100, pct %||% 0))))),
    if (!is.null(sub)) div(class = "text-muted", style = "font-size:.7rem;", sub)
  )
}
