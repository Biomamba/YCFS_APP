#!/usr/bin/env Rscript
# =============================================================================
# 本地启动器（V6 item 6）
# =============================================================================
# 在**用户自己的电脑上**把这个应用跑起来，用本地机器做实际计算。
#
#   Rscript run_local.R            # 默认端口 8899，自动开浏览器
#   Rscript run_local.R 9000       # 指定端口
#   Windows 上双击 run_app.bat      # 同一个东西，省掉敲命令
#
# ---- 和服务器版的区别（用户必须知道）---------------------------------------
#
#   * **没有资源限制**。服务器版靠 bash 的 ulimit 限住 CPU 时间/内存/进程数，
#     Windows 上没有这套东西（见 R/platform.R）。代码就是以你自己的账号权限
#     在跑 —— 所以别拿它跑来路不明的代码。
#   * **第一次启动落在注册页**（V6 起本地和服务器走同一套登录）。填完就是
#     管理员，恢复码只显示一次，抄下来。
#   * 每个对话一块工作区、每对话独立 R/Python 库，这些**照旧**，在
#     <数据目录>/workspaces 下面。
#   * 「远程服务器」那一路需要 ssh/scp，Windows 10+ 自带 OpenSSH 客户端，
#     一般可用；密码认证在 Windows 上会降级（没有 setsid），建议用密钥。
#   * conda 环境那一路需要本机装了 conda；没装的话「环境」页会说明，
#     基础解释器照常能用。
#
# ---- 为什么不用 shiny::runApp(launch.browser=TRUE) 了事 ---------------------
#
#   runApp 的 launch.browser 在 RStudio 里是"在 Viewer 面板打开"，在
#   Rscript 下才是开系统浏览器；而端口被占时它给的是 R 的报错栈，
#   普通用户看不懂。这里自己挑端口、自己开浏览器，出错时给人话。
# =============================================================================

# ---- 定位应用目录 -----------------------------------------------------------
# 不能靠 getwd()：双击 run_app.bat 时工作目录未必是应用目录（尤其是从
# "以管理员身份运行"或者快捷方式启动）。用 --file= 那一项反推。
dsapp_local_app_dir <- function() {
  a <- commandArgs(trailingOnly = FALSE)
  hit <- grep("^--file=", a, value = TRUE)
  if (length(hit)) {
    p <- normalizePath(sub("^--file=", "", hit[[1]]), mustWork = FALSE)
    return(dirname(p))
  }
  # source() 进来的（比如在 RStudio 里点 Source）：用调用方的路径兜底
  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(dirname(normalizePath(sys.frames()[[1]]$ofile, mustWork = FALSE)))
  }
  normalizePath(getwd(), mustWork = FALSE)
}

app_dir <- dsapp_local_app_dir()
setwd(app_dir)
# app.R 会读它；在这里设一次，避免以后从别处启动时推导错（和服务器版一致）
Sys.setenv(DSAPP_APP_DIR = app_dir)

say <- function(...) cat(sprintf(...), "\n", sep = "")

# ---- V13.2 item 1：优先用随包分发的 R ---------------------------------------
#
# 分发版里带了 runtime/R（见 desktop/build_windows_bundle.sh），依赖包也都
# 预装在那里面。走 run_app.bat 双击进来时本来就已经是它了，这一段是兜底：
# 用户（或者一份说明书写错了的旧文档）敲 `Rscript run_local.R` 时，用的
# 可能是机器上另一个 R —— 那个 R 十有八九**没装依赖包**，接下来会报
# "there is no package called 'bslib'"，看着像应用坏了，其实只是跑错了 R。
#
# ⚠️ 不能无条件换成自带的那个：`Rscript run_local.R 9000` 带参数时要原样
#    传过去；而且换完之后**必须立刻退出**，否则父进程会继续往下跑，变成
#    两个 R 抢同一个端口。
dsapp_reexec_bundled <- function(app_dir) {
  # 已经换过一次了（子进程会带着这个变量），别再套娃
  if (nzchar(Sys.getenv("DSAPP_BUNDLED_REEXEC"))) return(invisible(FALSE))

  exe <- file.path(app_dir, "runtime", "R", "bin",
                   if (.Platform$OS.type == "windows") "Rscript.exe"
                   else "Rscript")
  if (!file.exists(exe)) return(invisible(FALSE))

  # 现在跑的就是它？那没什么可换的
  me <- file.path(R.home("bin"),
                  if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  same <- tryCatch(
    identical(normalizePath(exe, mustWork = FALSE),
              normalizePath(me, mustWork = FALSE)),
    error = function(e) FALSE)
  if (isTRUE(same)) return(invisible(FALSE))

  say("检测到随包分发的 R 运行时，改用它启动：%s", exe)
  say("（机器上原来那个 R 不一定会装齐依赖包）")
  # ⚠️ 这个变量不用手动传给子进程：system2 继承当前进程的环境，而
  #    Sys.setenv 改的就是当前进程。子进程看到它就不会再换一次。
  Sys.setenv(DSAPP_BUNDLED_REEXEC = "1")
  st <- tryCatch(
    system2(exe,
            args = c(shQuote(file.path(app_dir, "run_local.R")),
                     vapply(commandArgs(trailingOnly = TRUE), shQuote, ""))),
    error = function(e) {
      say("用它启动失败：%s", conditionMessage(e))
      1L
    })
  # ⚠️ 这个 quit 不能省：不退出的话父进程会接着往下跑，两个 R 抢同一个端口。
  quit(save = "no", status = as.integer(st))
}

dsapp_reexec_bundled(app_dir)

# ---- 依赖检查 ---------------------------------------------------------------
# 缺包时报的是 R 自己的英文错误，用户只会看到 "there is no package called
# 'bslib'"，不知道该做什么。这里直接给一句带安装命令的话。
need <- c("shiny", "bslib", "httr2", "callr", "processx", "DBI", "RSQLite",
          "DT", "commonmark", "digest", "jsonlite", "curl", "openssl")
miss <- need[!vapply(need, function(p) length(find.package(p, quiet = TRUE)) > 0,
                     logical(1))]
if (length(miss)) {
  say("缺少 R 包：%s", paste(miss, collapse = ", "))
  say("")
  say("请先装好再启动，命令：")
  say('  install.packages(c(%s))',
      paste(sprintf('"%s"', miss), collapse = ", "))
  say("")
  say("（国内网络慢的话可以先用清华镜像：")
  say('  options(repos = c(CRAN = "https://mirrors.tuna.tsinghua.edu.cn/CRAN/")) )')
  quit(status = 1)
}

suppressMessages(library(shiny))

# ---- 挑端口 -----------------------------------------------------------------
# 默认 8899。被占了就往后找 —— 比直接报"端口被占用"友好，也比让用户自己去
# 改参数强。找不到空闲端口才放弃。
dsapp_pick_port <- function(start = 8899L, tries = 20L) {
  for (p in seq.int(start, start + tries - 1L)) {
    # 直接试监听：比"先探测再监听"少一次竞态（探测时空着、监听时被抢）
    ok <- tryCatch({
      srv <- serverSocket(p)
      close(srv)
      TRUE
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(p)
  }
  NULL
}

args <- commandArgs(trailingOnly = TRUE)
port <- suppressWarnings(as.integer(args[1]))
if (is.na(port) || port < 1L || port > 65535L) {
  port <- dsapp_pick_port()
  if (is.null(port)) {
    say("从 8899 开始找了 20 个端口都被占用了。")
    say("请手动指定一个：Rscript run_local.R 9000")
    quit(status = 1)
  }
} else if (!is.null(dsapp_pick_port(port, tries = 1L))) {
  # 显式指定的端口是空的，用它
  # ⚠️ 这里不能留空 `{ }`：顶层 if/else 的**空块值是 NULL 且可见**，会被 R
  #    自动打印出来 —— 用户双击启动，屏幕第一行是个光秃秃的 NULL。
  invisible(TRUE)
} else {
  say("端口 %d 已经被占用，换一个再试。", port)
  quit(status = 1)
}

# ---- 数据目录 ---------------------------------------------------------------
# .Renviron 里如果写了 DSAPP_DATA_ROOT 就用它（服务器版就是这么配的）；
# 没写就落在应用目录下 —— 本地运行时"应用在哪、数据就在哪"最好找。
#
# ⚠️ V13.2 item 1：**应用目录不一定可写**。分发包解压到"下载"文件夹里时它
#    是可写的，但用户完全可能把整个文件夹拖进 Program Files、或者从只读的
#    共享盘/只读 U 盘上直接运行 —— 那时 file.path(app_dir, "data") 建不出来，
#    而报错发生在建库那一刻，长得像"数据库坏了"。所以先探一下可写性，
#    不可写就退到当前用户自己的目录，并且**把这件事说出来**（用户得知道
#    自己的对话存哪儿了，不然下一次打开会以为数据丢了）。
#
# ⚠️ 判定逻辑本身在 R/platform.R 里（dsapp_default_data_root 那一组），这里
#    **直接 source 它**，不要抄一份。
#    第一版是抄的 —— 抄的坏处不是"多几行"，是**两份会分家**：启动器按一份
#    判断、应用按另一份判断，于是屏幕上印着 A 路径、数据实际写进了 B 路径，
#    而这正是最不能出错的一件事（用户据此判断"我的对话还在不在"）。
#    platform.R 只依赖 base，先 source 它是安全的（它有函数体引用 utils.R 的
#    东西，但函数体是懒求值的，这里只调用其中不依赖别的函数的那三个）。
# ★ V16.6 item 5：分发版（单文件包）里**没有 R/ 目录** —— 那些函数的字节码
#   在 lib.rds 里（见 desktop/build_bytecode.R）。两种形态都要能跑：
#   仓库里跑 → 走源码；分发包里跑 → 从 lib.rds 恢复。
#   ⚠️ 判定只看 platform.R 在不在：分发包里 R/ 整个不存在，不会出现
#      "有一半"的状态。找不到就**当场退出**，别退回到 getwd() 猜一个 ——
#      数据目录猜错的表现是"我的对话不见了"，而那是用户最不能接受的一种错。
if (file.exists(file.path(app_dir, "R", "platform.R"))) {
  source(file.path(app_dir, "R", "platform.R"))
} else if (file.exists(file.path(app_dir, "lib.rds"))) {
  # ⚠️ 必须 invisible()：`list2env()` 返回的是那个 environment，在脚本顶层
  #    会被 R **自动打印**出来（屏幕上一上来就是 `<environment: R_GlobalEnv>`）。
  #    普通用户看到这个只会以为程序出问题了。
  invisible(list2env(readRDS(file.path(app_dir, "lib.rds")),
                     envir = globalenv()))
} else {
  say("这个目录里既没有 R/platform.R，也没有 lib.rds —— 包不完整。")
  say("（%s）", app_dir)
  quit(status = 1)
}

note <- "（对话工作区、上传的文件、会话记录都在数据目录里；整个目录拷走 = 搬家）"
root <- dsapp_default_data_root(app_dir)
data_root <- root$path
if (isTRUE(root$fallback)) {
  say("应用目录写不进去（%s 是只读的：可能装在 Program Files 下，", app_dir)
  say("或者是从只读的盘/U 盘上直接运行的），数据改放这里：")
  say("    %s", data_root)
  say("想固定到别处：设环境变量 DSAPP_DATA_ROOT，或者在 .Renviron 里写一行。")
  say("")
}
say("应用目录：%s", app_dir)
say("数据目录：%s", data_root)
say("%s", note)
say("")

url <- sprintf("http://127.0.0.1:%d/", port)
say("正在启动……浏览器会自动打开 %s", url)
say("关掉这个窗口（或按 Ctrl+C）就停止服务。")
say("")

# ---- 起服务 -----------------------------------------------------------------
# host 只绑 127.0.0.1：本地运行**不要**暴露到局域网。
#
# ⚠️ 这里的理由 V6 改过，别照着旧版理解。旧版写的是"本地模式默认直接进，
#    没有登录保护"—— 那是 auth_mode 默认还是 "auto" 的时候。V6 起默认是
#    "login"（见 R/config.R 里那段），本地跑和服务器跑走的是**同一套**
#    注册/密码/恢复码。
#
#    所以绑 127.0.0.1 现在是**第二道**而不是唯一一道防线，留着是因为：
#      · .Renviron 里设了 DSAPP_AUTH_MODE=auto 就又变回直接进（排查时用），
#        那天这句绑定就是唯一的保护；
#      · 数据目录里有 API Key 和会话记录，本机其它用户能连上就等于全拿走。
#
#    第一次启动库里没有账号，会落在**注册**页；第一个注册的就是管理员。
tryCatch(
  shiny::runApp(app_dir, port = port, host = "127.0.0.1",
                launch.browser = TRUE, quiet = TRUE),
  error = function(e) {
    say("")
    say("启动失败：%s", conditionMessage(e))
    say("常见原因：端口被占用、数据目录没有写权限、R 包版本太旧。")
    quit(status = 1)
  }
)
