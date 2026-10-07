# =============================================================================
# 平台差异层（V6 item 6：Windows 本地运行）
# =============================================================================
# 这个应用原本只跑在 Linux 服务器上（Shiny Server + `run_as shiny`），代码里
# 因此散着几处"想当然"的 Linux 假设：`/bin/bash`、`ulimit`、`/dev/null`、
# `/usr/bin/setsid`、`file.symlink` 建只读软链。在 Windows 上这些不是"慢一点"
# 或者"少个功能"，是**当场报错、应用起不来**。
#
# ⚠️ 用户的原话是「在本地打开就可以利用本地电脑来执行实际的计算」——
#    也就是说 Windows 那边要的是**完整可用的执行链**，不是"能打开看看"。
#    所以下面每一处降级都写清了"降级之后少了什么保护"，而不是悄悄换个实现。
#
# ⚠️ 这一层**只放"这里和那里不一样"的判断**，不放业务逻辑。判定的依据一律
#    用能力（文件在不在、函数有没有），不要用 `Sys.info()[["sysname"]]` 去
#    比字符串 —— 换容器、换发行版、WSL 都会误判，而误判的表现是"跑起来
#    一半才炸"。
# =============================================================================

#' 是不是 Windows
#'
#' 用 `.Platform$OS.type` 而不是 `Sys.info()[["sysname"]]`：前者是 R 自己
#' 编译时就定下来的，后者可以被环境变量影响。这个值决定要不要用 bash，
#' 判错了就是整个执行链断掉。
dsapp_is_windows <- function() identical(.Platform$OS.type, "windows")

#' 当前进程的"运行身份"标识，用来给**必须由本人拥有**的目录起名
#'
#' ---- 为什么需要它（V13.5 item 5）--------------------------------------------
#'
#' conda/mamba 的包缓存目录**只认属主能 chmod**。libmamba 每次启动都会对
#' `<CONDA_PKGS_DIRS>/cache` 反复 `fchmodat`（实测 2.5.0：在 0775 和 02775
#' 之间来回切几十次），而 POSIX 规定 chmod 只有**文件属主或 root** 能做 ——
#' 靠 ACL 拿到 rwx **不等于**能 chmod，那一步照样返回 EPERM。
#'
#' 这台机器上 `data/conda_pkgs/cache` 的属主是 biomamba，而线上应用跑在
#' `shiny` 名下，于是每一次建环境都是：
#'
#'     critical libmamba filesystem error: cannot set permissions:
#'     Operation not permitted [/data3/.../data/conda_pkgs/cache]
#'
#' **这不是磁盘问题、不是 conda 版本问题，是"两个人共用一份缓存"这件事本身
#' 不成立**：开发用 biomamba、线上用 shiny，无论把这份缓存 chown 给谁，
#' 另一个人的 chmod 就必然失败。所以缓存必须**按运行身份分开放**。
#'
#' ---- 为什么取的是登录名而不是数字 uid ---------------------------------------
#'
#' ⚠️ R **没有** `Sys.getuid()` —— 那是 Python 的 `os.getuid()`。别照着写，
#'    它不会报错，只会在 `exists()` 那一层静默走兜底分支（2026-09-17 实测：
#'    第一版就是这么写的，返回了 "biomamba" 而不是 1001，看起来"能用"，
#'    但两个分支的语义完全不同，谁也不知道自己在用哪一个）。
#'
#' 那为什么不 `system2("id", "-u")` 去要一个数字：`dsapp_config()` 每次调用
#' 都会走这儿，而它在一轮请求里被调很多次 —— 为了一次目录名去 fork 一个
#' 子进程，在单进程的 Shiny 里是白送的开销。而且数字 uid 对
#' `file.info()$uname` 那个属主检查没用：那里只有名字，还得反查一次。
#'
#' 登录名两个用途都直接满足：够稳定、够安全，而且**属主检查就是一次字符串
#' 相等**。它和 `file.info()$uname` 同源（都是 passwd 库），不会出现
#' "名字对得上、uid 对不上"这种夹缝。
#'
#' ⚠️ 返回值会进目录名，所以只允许安全字符；取不到就退化成一个固定的
#'    "u" —— 那种环境下本来就分不出身份，硬编一个假名字只会更难查。
dsapp_run_id <- function() {
  nm <- tryCatch(as.character(Sys.info()[["user"]]), error = function(e) "")
  if (length(nm) == 1L && !is.na(nm) && grepl("^[A-Za-z0-9_.-]+$", nm)) {
    return(nm)
  }
  "u"
}

#' 有没有 POSIX shell（bash）
#'
#' 有 bash 才有 ulimit 那一套资源限制 —— 见 dsapp_wrapper_script。
#' Windows 上**没有**等价的进程内手段：Job Object 那套 R 里没有绑定，
#' `processx` 也没有暴露。所以 Windows 上资源限制是**没有的**，这一点
#' 必须让用户看得见（见 dsapp_exec_env 的说明和界面上的提示），
#' 不能让他以为跟服务器上一样被管着。
dsapp_bash_path <- function() {
  if (dsapp_is_windows()) return(NULL)
  for (p in c("/bin/bash", "/usr/bin/bash", Sys.which("bash"))) {
    if (nzchar(p) && file.exists(p)) return(p)
  }
  NULL
}

#' 有没有 ulimit 这套资源限制
dsapp_has_rlimit <- function() !is.null(dsapp_bash_path())

#' 空设备
#'
#' Linux 是 /dev/null，Windows 是 NUL。**不能写死** —— 写死之后 Windows 上
#' `stdin = "/dev/null"` 会被当成一个文件名，进程起不来。
dsapp_devnull <- function() if (dsapp_is_windows()) "NUL" else "/dev/null"

#' setsid 可执行文件的路径
#'
#' 只在"要把 ssh 子进程从当前终端脱离"这一处用到（见 R/remote.R）。
#' 找不到就返回 NULL，调用方**不加 setsid 也要能跑** —— 这层包装的目的是
#' 防止密码提示挂住进程，不是功能本身。
dsapp_setsid_path <- function() {
  if (dsapp_is_windows()) return(NULL)
  p <- "/usr/bin/setsid"
  if (file.exists(p)) p else NULL
}

#' 当前进程有没有额外的文件系统特权（root / CAP_DAC_OVERRIDE）
#'
#' 判的是**能力**，不是 uid —— 换容器、换 capabilities、换 sudo 配置都不会
#' 误判。目前只有一个用途：决定"只读位保护"那几条自检要不要明说跳过。
dsapp_can_bypass_ro <- function() {
  p <- tempfile("dsapp_roprobe_")
  on.exit(unlink(p), add = TRUE)
  if (!isTRUE(tryCatch({ writeLines("x", p); TRUE }, error = function(e) FALSE))) {
    return(FALSE)
  }
  Sys.chmod(p, "0444")
  isTRUE(tryCatch({ writeLines("y", p); TRUE },
                  error = function(e) FALSE, warning = function(w) FALSE))
}

#' 把源文件放进工作目录
#'
#' Linux 上是**只读软链**：软链而不是复制，是因为生信数据动辄几个 G；只读
#' 是因为 `write.csv(df, "expr.csv")` 这种"结果写回输入同名文件"的写法太
#' 常见，而软链会穿透 —— 不加保护，用户上传的原始数据会被静默覆盖。
#'
#' ⚠️ Windows 上 `file.symlink()` 需要管理员权限或开发者模式，普通用户调用
#'    直接失败（而且失败是**静默**的：`try(..., silent=TRUE)` 一包，工作目录
#'    里就少一个输入文件，模型看到的是"文件不存在"）。所以这里降级成复制。
#'
#'    降级掉的是"省空间"和"改不动原件"里的**前者**：复制出来的那份照样
#'    chmod 0444（Windows 上映射成只读属性），原件也依然是安全的。
#'    真正没了的保护是"硬链接/软链穿透写不到原件"这条 —— 复制品是一个独立
#'    文件，改了不影响原件，其实反而更安全，代价只是磁盘。
#'
#' @return TRUE 表示放好了（软链或复制都算）
dsapp_place_input <- function(src, dst) {
  if (file.exists(dst) || dsapp_is_link(dst)) return(FALSE)
  if (isTRUE(tryCatch(file.symlink(src, dst), error = function(e) FALSE))) {
    return(TRUE)
  }
  # 复制这条路：先复制再设只读，顺序不能反 —— 反过来复制会失败。
  if (!isTRUE(tryCatch(file.copy(src, dst, overwrite = FALSE),
                       error = function(e) FALSE))) {
    return(FALSE)
  }
  try(Sys.chmod(dst, mode = "0444"), silent = TRUE)
  TRUE
}

#' 平台说明（给界面用）
#'
#' 说清"这台机器上哪些保护是没有的"。用户在没有 ulimit 的机器上跑别人的
#' 代码之前，应该知道这件事。
dsapp_platform_note <- function() {
  if (dsapp_is_windows()) {
    "Windows 本地运行：代码直接用你的账号权限执行，**没有** CPU/内存/进程数限制，也没有文件系统隔离。只跑你自己信得过的代码。"
  } else if (!dsapp_has_rlimit()) {
    "这台机器上没有 bash，资源限制（CPU 时间 / 内存 / 进程数）没有生效。"
  } else {
    NULL
  }
}

#' 目录能不能写
#'
#' @param d 目标目录（可以还不存在 —— 那就看它的上级能不能写）
#'
#' ⚠️ 用 file.access(d, 2) 而不是 try(file.create())：前者不会在只读的
#'    网盘/共享盘上留下半截文件，也不会因为在别人的目录里试写而触发审计。
#'    代价是它在 ACL/只读挂载上偶尔会乐观一点 —— 所以调用方拿到 TRUE 之后
#'    仍然要能容忍"最后一步才失败"。
dsapp_dir_writable <- function(d) {
  # ⚠️ 这里**不用** %||%：它在 utils.R 里，而 platform.R 排在 utils.R 前面。
  #    函数体是懒求值的所以现在也能跑，但 platform.R 是这一层的地基，
  #    不该依赖上层的小工具 —— 哪天有人在更早的地方调它就是个找不到函数。
  if (is.null(d) || !length(d)) return(FALSE)
  d <- as.character(d)[[1]]
  if (is.na(d) || !nzchar(d)) return(FALSE)
  if (dir.exists(d)) return(file.access(d, 2L) == 0L)
  up <- dirname(d)
  if (!dir.exists(up)) return(FALSE)
  file.access(up, 2L) == 0L
}

#' 当前用户的私有数据目录（跨平台）
#'
#' Windows 用 %LOCALAPPDATA%，其它平台按 XDG。**不用 `~` 兜底到底**：
#' Windows 上 `~` 有时指向网络漫游目录（登录慢、还可能只读），
#' %LOCALAPPDATA% 才是"这台机器上属于我的可写目录"。
dsapp_user_data_dir <- function() {
  if (dsapp_is_windows()) {
    base <- Sys.getenv("LOCALAPPDATA", "")
    prof <- Sys.getenv("USERPROFILE", "")
    if (!nzchar(base) && nzchar(prof)) base <- file.path(prof, "AppData", "Local")
  } else {
    base <- Sys.getenv("XDG_DATA_HOME", "")
    if (!nzchar(base)) {
      home <- Sys.getenv("HOME", "")
      if (nzchar(home)) base <- file.path(home, ".local", "share")
    }
  }
  if (!nzchar(base)) base <- tempdir()   # 最后的兜底：至少能跑起来
  file.path(base, "DS_App")
}

#' 数据目录该放哪（V13.2 item 1）
#'
#' 默认"应用在哪、数据就在哪"（整个目录拷走 = 搬家，这是本地版最想要的
#' 性质）。但打包成 exe / 装到 Program Files 之后，应用目录**不可写**，
#' 建库那一步会失败，而报错长得像"数据库坏了"。
#'
#' ⚠️ 所以这里不是"选一个好看的位置"，是**能不能起来**的问题。判定顺序：
#'    环境变量 > 应用目录旁边 > 当前用户的私有目录。
#'
#' @return list(path, fallback) —— fallback = TRUE 表示用了备用位置，
#'         调用方（界面/启动器）应该把这件事说出来，否则用户会以为
#'         自己的对话丢了。
dsapp_default_data_root <- function(app_dir = dsapp_app_dir()) {
  env <- Sys.getenv("DSAPP_DATA_ROOT", "")
  if (nzchar(env)) return(list(path = env, fallback = FALSE))
  inside <- file.path(app_dir, "data")
  if (dsapp_dir_writable(inside)) return(list(path = inside, fallback = FALSE))
  list(path = file.path(dsapp_user_data_dir(), "data"), fallback = TRUE)
}

#' 这台机器上到底有没有 GPU（V14 item 7）
#'
#' 给「配额与资源」那个开关做旁白用的：管理员把某个账号打开成"允许"，
#' 结果机器上根本没插卡 —— 不告诉他的话，他会以为开关没生效。
#'
#' ⚠️ 判据是**设备节点在不在**（`/dev/nvidia0`、`/dev/kfd`），不是
#'    `nvidia-smi` 在不在。这台机器上就有这种情况：`/usr/bin/nvidia-smi`
#'    装着（跟着驱动包一起装的），但 `/dev/nvidia*` 一个都没有 ——
#'    真跑起来 `nvidia-smi` 的报错是"couldn't communicate with the
#'    NVIDIA driver"，而一个只看命令在不在的判据会答"有卡"。
#'
#' ⚠️ 结果**不缓存**：这是个纯 stat，几微秒；而缓存了就要面对"卡是热插的
#'    还是刚崩的"。它只在管理员开弹窗时调一次，不值得为它引入状态。
#'
#' @return list(ok, kind, detail) —— ok 是结论，kind ∈ {"nvidia","amd","none"}，
#'         detail 是给管理员看的一句话。
dsapp_host_gpu <- function() {
  if (dsapp_is_windows()) {
    # Windows 上没有 /dev；用 nvidia-smi 在不在当近似判据，并**如实说明
    # 这是近似** —— 本地版本来就不是主力执行环境。
    has <- nzchar(Sys.which("nvidia-smi"))
    return(list(ok = has, kind = if (has) "nvidia" else "none",
                detail = if (has) "检测到 nvidia-smi（Windows 上只做近似判断）"
                         else "未检测到 NVIDIA 驱动工具"))
  }
  nv <- Sys.glob("/dev/nvidia[0-9]*")
  if (length(nv)) {
    return(list(ok = TRUE, kind = "nvidia",
                detail = sprintf("检测到 %d 个 NVIDIA 设备节点（%s）",
                                 length(nv), nv[1])))
  }
  if (length(Sys.glob("/dev/kfd"))) {
    return(list(ok = TRUE, kind = "amd", detail = "检测到 AMD ROCm 设备（/dev/kfd）"))
  }
  list(ok = FALSE, kind = "none",
       detail = "本机未检测到 GPU 设备（/dev/nvidia* 与 /dev/kfd 都不存在）")
}

#' 这台部署机的身份（V14 item 6）
#'
#' 用户问的原话是「用户所在的算力节点，是用户自有服务器，还是我的部署服务器」。
#' 答案在代码里是明确的（默认 target$kind = "server"，见 utils.R 的
#' dsapp_target_label），但**界面上从来没有把这句话说给用户听** —— 他看到的
#' 是「当前挂载服务器」五个字，而"挂载"是个平台内部才懂的说法。于是他很容易
#' 以为"当前服务器"指的是自己以前配过的那台机器，或者反过来，把自己数据往
#' 上面传的时候不知道传到了谁的盘上。
#'
#' 所以这里给的是一份**能对上号**的身份：主机名 + 核数 + 内存。用户如果对这台
#' 机器有 shell 权限，一眼就能认出"哦，就是那台"；没有的话，至少知道它不是
#' 自己的机器。
#'
#' ⚠️ 主机名和核数**不算秘密** —— 用户本来就能在上面跑任意代码，一句
#'    `system("hostname")` 就有了。所以显示它们不是信息泄露；真正要改的是
#'    「这是谁的机器」这个**归属**没说清楚。反过来说，也**不要**在这里加
#'    路径、账号名、挂载点之类的东西：那些对回答这个问题没有帮助。
dsapp_host_identity <- function() {
  node <- tryCatch(as.character(Sys.info()[["nodename"]]),
                   error = function(e) "")
  if (length(node) != 1L || is.na(node)) node <- ""

  # ★ V15.10 item 1：走 dsapp_cores() —— 进程内只问一次。这里原来每次都
  #   fork 一个 shell 去问 getconf（6.9 ms），而这个函数是打开「这台机器
  #   是谁」那一格时调的。拿不到仍是 NA（不编数），语义一字不变。
  cores <- dsapp_cores()

  # 总内存。Linux 读 /proc/meminfo；读不到就算了（NA），**不要**编一个数 ——
  # 界面上一句具体的"944 GB"比"内存充足"可信得多，而编错了更糟。
  mb <- NA_real_
  if (!dsapp_is_windows() && file.exists("/proc/meminfo")) {
    ln <- tryCatch(readLines("/proc/meminfo", n = 1L), error = function(e) "")
    v  <- suppressWarnings(as.numeric(sub("\\D+(\\d+).*", "\\1", ln)))
    if (length(v) == 1L && !is.na(v) && v > 0) mb <- v / 1024
  }

  list(host  = node,
       cores = cores,
       mem_mb = mb,
       # 一行摘要，调用方直接贴到界面上就行 —— 免得每个调用点各拼一遍，
       # 拼出三种不同的说法。
       label = paste0(
         if (nzchar(node)) sprintf("本机 %s", node) else "本站部署机",
         if (!is.na(cores)) sprintf(" · %d 核", cores) else "",
         if (!is.na(mb)) sprintf(" · %s 内存", dsapp_fmt_bytes(mb * 1024^2)) else ""
       ))
}
