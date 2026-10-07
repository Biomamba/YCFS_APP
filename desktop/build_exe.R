#!/usr/bin/env Rscript
# =============================================================================
# 用 shinyelectron 打一个 Windows 桌面 exe（V13.2 item 1 的"方案 B"）
# =============================================================================
#
#   Rscript desktop/build_exe.R [输出目录]
#
# ---- 先说清楚：这份代码**在这台机器上跑不了** ---------------------------------
#
# 用户选的是「shinyelectron 出单个 .exe」。这条路本身是通的，但**不是在
# 这台 Linux 开发机上**通的，原因有三条，都是实测出来的，不是猜的：
#
#   1. shinyelectron 0.2.1 要求 Node.js >= 22、npm >= 11.5（它 DESCRIPTION
#      里的 SystemRequirements）。这台机器上是 node v12.4.0 / npm 6.9.0
#      （miniconda 自带那份），差了一个大版本。
#   2. 就算把 Node 装上，**从 Linux 交叉编译出 Windows 的 exe，electron-builder
#      要过 wine**（往 exe 里塞图标和版本信息用的是 rcedit，那是个 Windows
#      程序）。这台机器上没有 wine，conda-forge 的 linux-64 也没有（只有一个
#      同名的 untwine，不是一回事）。
#   3. shinyelectron 的 bundled 策略要下载**便携版 R**。它对 Windows/macOS
#      都发布了现成的压缩包，Linux 那条路在源码里是直接 abort 的
#      （"Portable R for Linux is not yet supported"）—— 所以连"先在本地打个
#      Linux 版验证一下流程"都做不到。
#
# 所以这个脚本的定位是：**把套件准备好**，拿到一台有 Node 22+ 的 Windows
# 机器（或者在 Linux 上装好 wine）之后，一条命令就能出包。上面三条它会在
# 开头自己检查一遍并且**当场停下来说明白**，而不是跑到一半报个看不懂的错。
#
# ⚠️ 在那之前，请用 desktop/build_windows_bundle.sh 那个产物：免安装 zip +
#    便携 R，用户双击 run_app.bat 就能用，效果上解决的是同一个问题
#    （"用户机器上不用装 R，也不用把 R 装在固定路径"），而且那份是**已经
#    组装好、自检过**的。
#
# ---- 和 bundle 那份的关键区别 --------------------------------------------------
#
#   · bundle：一个文件夹，用户看得见 R/、www/、data/，双击 .bat 起一个本地
#     服务，浏览器打开。杀毒软件一般不误报，出问题用户自己能看见日志。
#   · exe   ：一个文件，双击就是一个独立窗口（Electron 内核），更像"软件"。
#     代价是：体积更大（Electron 内核 + R 运行时，200 MB 起）、没有代码
#     签名证书时**大概率被杀毒软件拦**、出错时用户看不到命令行输出。
#
# =============================================================================

suppressMessages({
  if (!requireNamespace("shinyelectron", quietly = TRUE)) {
    stop("没装 shinyelectron。先跑：install.packages(\"shinyelectron\")")
  }
})

# 定位仓库根目录：用 `--file=` 反推（和 run_local.R 一个套路），取不到再
# 退回 getwd()。
#
# ⚠️ 不用 `sys.frame(1)$ofile` 那种写法：它只在 source() 时有效，而且这里
#    在 Rscript 直接跑的情况下 `sys.frame(1)` 本身就不可靠。另外 `%||%` 是
#    R/utils.R 里定义的，那个文件这会儿还没被载入 —— 在这里用它等于调用一个
#    不存在的函数。这两个坑第一次写的时候都踩了。
REPO <- normalizePath(getwd(), mustWork = FALSE)
local({
  a <- commandArgs(trailingOnly = FALSE)
  hit <- grep("^--file=", a, value = TRUE)
  if (length(hit)) {
    p <- normalizePath(sub("^--file=", "", hit[[1]]), mustWork = FALSE)
    assign("REPO", dirname(dirname(p)), envir = globalenv())
  } else {
    assign("REPO", normalizePath(getwd(), mustWork = FALSE), envir = globalenv())
  }
})

# ---- 参数 -------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
FORCE <- "--force" %in% args
args <- setdiff(args, "--force")

# ★ 2026-10-07（走 GitHub Actions 之后加的）：--plat / --arch。
#
#   为什么不是另写一份 build_mac_exe.R：这个脚本里**真正难写的那几段**
#   （干净副本的清单与泄露自检、_shinyelectron.yml 的改写、产出物自检）
#   两个平台逐字相同，只有三处不同 —— 平台名、架构名、图标格式。抄一份
#   出去的话，下次修"副本里混进了 data/"这种问题就只修一边。
#
#   默认值等于改之前的行为（win + x64），所以老的调用方式一个字不用改。
getopt1 <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", name, "="), "", hit[[1]])
}
PLAT <- getopt1("plat", "win")
ARCH <- getopt1("arch", if (PLAT == "mac") "arm64" else "x64")
args <- args[!grepl("^--(plat|arch)=", args)]

OUT <- if (length(args)) args[[1]] else file.path(Sys.getenv("HOME"), "dsapp_build")
OUT <- normalizePath(OUT, mustWork = FALSE)

say <- function(...) cat(sprintf(...), "\n", sep = "")
hr  <- function() cat(strrep("-", 68), "\n", sep = "")

version <- local({
  l <- grep("DSAPP_VERSION\\s*<-\\s*\"", readLines(file.path(REPO, "R", "config.R"),
                                                   warn = FALSE), value = TRUE)
  if (length(l)) sub(".*\"([^\"]+)\".*", "\\1", l[[1]]) else "0.0.0"
})
APP_NAME <- "DS_App"        # ⚠️ 故意用 ASCII
# 为什么不叫「Biomamba 言出法随」：这个名字会变成 exe 的文件名、安装目录名、
# 开始菜单项名。electron-builder 在 Windows 上处理非 ASCII 的产物名时要靠
# 系统的代码页，打包机（多半是英文 Windows）和用户机（多半是中文 Windows）
# 不一致时会出现乱码目录名。窗口标题、界面里的中文一个字都不少 —— 那些是
# 应用自己渲染的，走 UTF-8，不受这里影响。

if (!PLAT %in% c("win", "mac")) stop("--plat 只能是 win 或 mac，收到：", PLAT)
if (!ARCH %in% c("x64", "arm64")) stop("--arch 只能是 x64 或 arm64，收到：", ARCH)

say("应用版本：%s", version)
say("目标平台：%s / %s", PLAT, ARCH)
say("输出目录：%s", OUT)

# ---- 0. 先检查"这台机器能不能干这件事" ---------------------------------------
#
# ⚠️ 这一段是这个脚本最重要的部分。没有它的话，用户（或者我自己）会在
#    一个跑不了的机器上启动打包，等十分钟，然后收到一句 electron-builder
#    的英文栈 —— 那条路我走过，最后查出来是"Node 版本差一个大版本"。
#
# 每条检查都给出**怎么办**，而不只是"不行"。
preflight <- function() {
  problems <- character(0)

  node <- Sys.which("node"); npm <- Sys.which("npm")
  if (!nzchar(node) || !nzchar(npm)) {
    problems <- c(problems, sprintf(
      "① 没有 node/npm。装 Node.js 22 或更高（https://nodejs.org/），或者 conda install -c conda-forge 'nodejs>=22'。"))
  } else {
    nv <- tryCatch(system2(node, "--version", stdout = TRUE, stderr = FALSE),
                   error = function(e) "")
    mv <- tryCatch(system2(npm, "--version", stdout = TRUE, stderr = FALSE),
                   error = function(e) "")
    nv <- sub("^v", "", trimws(paste(nv, collapse = "")))
    mv <- trimws(paste(mv, collapse = ""))
    say("node %s / npm %s（%s）", nv, mv, node)
    # 比版本号：shinyelectron 要 Node >= 22、npm >= 11.5
    ge <- function(a, b) {
      pa <- as.integer(strsplit(a, "[.-]")[[1]]); pb <- as.integer(strsplit(b, "[.-]")[[1]])
      n <- max(length(pa), length(pb)); length(pa) <- n; length(pb) <- n
      pa[is.na(pa)] <- 0L; pb[is.na(pb)] <- 0L
      d <- which(pa != pb)
      if (!length(d)) return(TRUE)
      pa[d[1]] > pb[d[1]]
    }
    if (!ge(nv, "22")) problems <- c(problems, sprintf(
      "① Node 版本太低（是 %s，shinyelectron 要 >= 22）。conda install -c conda-forge 'nodejs>=22' 装一个独占环境再用。",
      nv))
    if (!ge(mv, "11.5")) problems <- c(problems, sprintf(
      "① npm 版本太低（是 %s，要 >= 11.5）。它会跟着 Node 一起升级。", mv))
  }

  # ⚠️⚠️ 2026-10-07：**shinyelectron 的 Suggests 里有几个是它打包路径上真用的**，
  #    没装的表现是一句**和真实原因毫无关系**的英文报错。已经在 CI 上撞了三次：
  #
  #      包      在哪用的                                没装时那边报什么
  #      renv    dependencies-r.R 探测 R 依赖清单        "there is no package called 'rlang'"
  #      rlang   cli::cli_abort() 内部（cli 没声明它）    （就是上面那句，指的是它）
  #      withr   utils.R 的 run_command_safe()           "Node.js is required but not found"
  #
  #    第三条最阴，值得单独说：run_command_safe() **整个函数体包在 tryCatch 里**，
  #    `withr::local_tempdir()` 抛的"没有这个包"被 error= 处理器吞掉、统一成
  #    `status = 1L`。调用方 validate_node_npm() 只看到"这条命令没跑成"，于是报
  #    "Node.js is required but not found" —— 而 **node 明明在 PATH 上**（实测：
  #    22.23.2 就在那儿，这份 preflight 自己都把它的绝对路径打出来了，下一步
  #    还是被判成 not found）。照那句英文去查 Node 会查到一个死胡同。
  #
  #    ⇒ 与其等它跑十分钟再报那句假话，不如**开工前一秒**直接说清楚缺什么。
  soft <- c("renv", "rlang", "withr")
  absent <- soft[!vapply(soft, requireNamespace, logical(1), quietly = TRUE)]
  if (length(absent)) {
    problems <- c(problems, sprintf(
      paste0("③ 少了 shinyelectron **运行时**要用的包：%s\n",
             "     这几个写在它的 Suggests 里，但打包这条路真的会调到；缺了会报\n",
             "     一句和真实原因无关的英文错（如 'Node.js is required but not found'）。\n",
             "     装上：Rscript -e 'install.packages(c(%s))'"),
      paste(absent, collapse = ", "),
      paste(sprintf('"%s"', absent), collapse = ", ")))
  }

  os <- .Platform$OS.type
  # ★ 2026-10-07：这段原来只问"是不是 Windows"，因为当时目标只有 win。
  #   现在 mac 走同一份脚本，判据就得看**目标平台**，不能只看宿主机。
  host <- if (os == "windows") "win"
          else if (identical(Sys.info()[["sysname"]], "Darwin")) "mac"
          else "linux"
  say("宿主机：%s", host)

  if (PLAT == "win" && host != "win") {
    # 交叉编译到 Windows 要 wine（electron-builder 用 rcedit 写图标和版本信息，
    # rcedit 是 Windows 程序）。
    if (!nzchar(Sys.which("wine"))) {
      problems <- c(problems, paste0(
        "② 目标平台是 win，这台不是 Windows，而且没有 wine —— 交叉编译过不去。\n",
        "     要么换一台 Windows 机器（**推荐**，原生打包不用 wine），\n",
        "     要么在 Linux 上装 wine：sudo apt install wine64。"))
    }
  }

  if (PLAT == "mac" && host != "mac") {
    # ⚠️ 这一条**没有绕法**，而且不该有：electron-builder 在非 macOS 上直接
    #    拒绝出 mac 目标（打 dmg 要 hdiutil、签名要 codesign，都是系统自带、
    #    没有替代实现）。想在 Linux 上硬做，只能自己拼 .app + ldid 临时签名
    #    + libdmg-hfsplus 造 dmg —— 那条路**产出的东西本地没有任何办法验证**，
    #    而 mac 上最要命的恰好就是"能不能启动"。所以不做。
    problems <- c(problems, paste0(
      "② 目标平台是 mac，而这台是 ", host, " —— electron-builder 只在 macOS 上出 mac 目标。\n",
      "     走 GitHub Actions 的 macos-14 / macos-13 runner，见 .github/workflows/desktop.yml。"))
  }

  if (length(problems)) {
    hr()
    say("这台机器打不了 %s 包：", PLAT)
    for (p in problems) { say("  %s", p) }
    hr()
    say("另一条路（现在就能用，而且已经组装好、自检过）：")
    say("  bash desktop/build_windows_bundle.sh          # Windows 免安装 zip")
    say("  bash desktop/build_macos_bundle.sh . arm64    # macOS 免安装 zip")
    say("  → 里面自带便携 R 和全部依赖包，用户解压后双击启动器")
    say("")
    if (!FORCE) {
      say("（真要继续试，加 --force。多数情况下它会晚一点再失败。）")
      quit(status = 1)
    }
    say("--force：还是继续试。")
    hr()
  }
}

preflight()

# ---- 1. 准备一份**干净**的应用目录 -------------------------------------------
#
# ⚠️⚠️ 绝对不能把仓库目录直接交给 export()。它会整个拷进安装包里，而这个
#     仓库里有：
#       · data/dsapp.sqlite3   —— 开发库，里面是真实的账号和会话
#       · data/.secret_key / data/.keyring —— 加密 API Key 用的密钥
#       · data/workspaces/     —— 所有人的对话工作区
#       · history_Version/     —— 十几个历史版本，几个 G
#     把仓库直接打包 = 把上面这些一起发给用户。这不是"包大了点"，是泄密。
#     所以下面显式列清单，和 desktop/build_windows_bundle.sh 保持一致。
STAGE <- file.path(OUT, "exe_stage", "app")
say("准备干净的副本：%s", STAGE)
unlink(file.path(OUT, "exe_stage"), recursive = TRUE)
dir.create(STAGE, recursive = TRUE, showWarnings = FALSE)

for (f in c("app.R")) {
  file.copy(file.path(REPO, f), file.path(STAGE, f), overwrite = TRUE)
}
for (d in c("R", "www", "skills_builtin")) {
  file.copy(file.path(REPO, d), STAGE, recursive = TRUE, overwrite = TRUE)
}

# 自检：不该出现的东西一个都不能有
leak <- character(0)
for (p in c("data", "history_Version", "selftest.R", ".Renviron",
            "data/dsapp.sqlite3", "data/.secret_key")) {
  if (file.exists(file.path(STAGE, p))) leak <- c(leak, p)
}
if (length(leak)) {
  stop("干净的副本里居然有这些：", paste(leak, collapse = ", "),
       " —— 打包流程有问题，停下来。")
}
if (!file.exists(file.path(STAGE, "app.R"))) stop("副本里没有 app.R")
say("  副本干净（R/ %d 个文件，www/ %d 个，skills_builtin/ %d 个）",
    length(list.files(file.path(STAGE, "R"))),
    length(list.files(file.path(STAGE, "www"))),
    length(list.files(file.path(STAGE, "skills_builtin"))))

# ---- 2. 配置文件 -------------------------------------------------------------
#
# shinyelectron 会读应用目录下的 `_shinyelectron.yml`（CONFIG_FILENAME）。
# 写在文件里而不是全塞进 export() 的参数，是因为这样**用户在 Windows 上
# 直接跑 `Rscript build_exe.R` 时看到的就是全部设置**，不用来回翻 R 代码。
# 图标按平台分：Windows 要 .ico，mac 要 .icns。两者**不是换个扩展名**，
# 是两套容器格式（.ico 内含多档 BMP/PNG，.icns 是 Apple 的 iconset 封装）。
ICON <- file.path(REPO, "desktop", if (PLAT == "mac") "app.icns" else "app.ico")
if (!file.exists(ICON)) {
  stop(if (PLAT == "mac") paste0(
         "没有 desktop/app.icns。它只能在 macOS 上生成：\n",
         "  bash desktop/make_icns.sh      # 从 desktop/app.png 出，用系统自带的 sips + iconutil")
       else paste0(
         "没有 desktop/app.ico。生成它：见 desktop/README.md 里那一段。"))
}

cfg <- readLines(file.path(REPO, "desktop", "_shinyelectron.yml"), warn = FALSE)
# icon 的路径是相对**应用目录**的，而应用目录是临时副本，所以这里按实际
# 位置改写成绝对路径。
cfg <- sub("^(\\s*icon:\\s*).*$", paste0("\\1", ICON), cfg)
# ⚠️ 顺手把版本号也改写掉。_shinyelectron.yml 里那份是**手写的**，从 V13.2
#    之后就没再跟上过（一直写着 13.2.0）—— 而 shinyelectron 是从这份 yml
#    读版本的，export() 的参数里没有 app_version。不改写的话，用户看到的
#    "应用版本"和我们以为发出去的那一版对不上，而这在排查问题时最要命。
cfg <- sub("^(\\s*version:\\s*).*$",
           paste0("\\1\"", version, "\""), cfg)

# ★ 便携 R 的版本：**必须钉死**，而且必须和本应用字节码的 R 小版本一致。
#
#   不钉会怎样（2026-10-07 实测）：shinyelectron 的兜底常量
#   SHINYELECTRON_DEFAULTS$runtime_versions$r 是 **4.6.1**，于是 CI 上每次都去
#   下 4.6.1 打进包里。而本仓库的 .R 字节码是 R 4.4.x 编的（本机
#   R.version.string = "R version 4.4.2"）—— 小版本对不上，症状是
#   "打出来的包能开、一用就废"。
#
#   优先级（读过 R/runtime-versions.R:11）：配置里的 `dependencies.r.version`
#   > "latest" > 上面那个常量。所以写进 yml 就够了。R/ 那边只有
#   resolve_runtime_version() 读这个键，merge_r_dependencies() 只看
#   repos/packages（读过，version 在依赖检测里一个字都没用），所以钉它
#   除了选运行时之外没有副作用。
#
#   ⚠️ 这个值和下面 2b 段预置缓存时的版本**必须是同一个**，所以只在这里写
#      一次、下面引用变量 —— 抄成两份的话，改了这头忘那头就是"预置了 4.4.3、
#      上游去找 4.5.0"，而报出来的是又一句看不懂的英文错。
RUNTIME_R_VERSION <- "4.4.3"

cfg <- c(cfg,
         "",
         "# ---- 下面这两行由 desktop/build_exe.R 自动追加，不要手改 ----------",
         "# 便携 R 的版本。不写的话 shinyelectron 会回落到它自己的 pin（4.6.1），",
         "# 和本应用字节码的 R 小版本对不上（详见 build_exe.R 里的注释）。",
         "dependencies:",
         "  r:",
         sprintf("    version: \"%s\"", RUNTIME_R_VERSION))
writeLines(cfg, file.path(STAGE, "_shinyelectron.yml"))

# 写完**读回来**核一遍：这份 yml 是要被 shinyelectron 解析的，拼错一个缩进
# 就是"静默回落默认值"，而默认值恰恰是我们要避开的那个 4.6.1。
# 用**它自己的** read_config()/resolve_runtime_version() 读 —— 这样核对的是
# "它实际会怎么解析"，不是"我以为 YAML 该长什么样"。
.rv <- tryCatch(
  shinyelectron:::resolve_runtime_version(
    "r", shinyelectron:::read_config(STAGE)),
  error = function(e) paste0("<解析失败：", conditionMessage(e), ">"))
if (!identical(.rv, RUNTIME_R_VERSION)) {
  stop("_shinyelectron.yml 里钉的 R 版本没生效：期望 ", RUNTIME_R_VERSION,
       "，shinyelectron 解析出来是 ", .rv,
       "\n（写进 yml 的那几行在 build_exe.R 的 2 段末尾；别让它静默回落成 4.6.1）")
}
say("便携 R 版本：%s（从写好的 _shinyelectron.yml 读回来核过）", .rv)

# ---- 2b. 便携 R 预置进 shinyelectron 的缓存 ----------------------------------
#
# ⚠️⚠️ 为什么非要自己干这一步（2026-10-07 查清 —— 是 shinyelectron 0.2.1 的 bug，
#      不是我们配错了）：bundled 策略下它会下载便携 R 再校 SHA-256，
#      **在 R 4.4.x 上每次必失败**，mac-app 那个 job 就是这么红的：
#
#        ✖ Error: Checksum verification failed for R 4.6.1
#        ✖ Expected SHA-256: 7077a884f4368f389783c25001861f428fca0715505be0453ae20cb809baa4d7
#        ✖ Actual SHA-256:                      ← 关键：这里是**空的**
#
#      "Actual 是空的"就是线索。它算哈希走的是
#        R/install-nodejs.R 的 compute_sha256()  →  tools::sha256sum()
#      而 **`tools::sha256sum` 在 R 4.4.x 的 tools 包里根本不存在**（本机实测
#      R 4.4.2：getNamespaceExports("tools") 里有 md5sum、checkMD5sums，没有
#      sha256sum；直接调会抛 "'sha256sum' is not an exported object"）。
#      那个函数外面包着 tryCatch、出错返回 NULL，于是
#      identical(tolower(NULL), "7077...") 恒为 FALSE ⇒ **和下载下来的文件
#      一点关系都没有，每次必失败**。
#
#      躲不掉，两条路都堵死：
#        · 换版本没用 —— portable-r 从 v4.3.2 起**每个 release 都发 .sha256**
#          边车（查过 releases API），expected_sha256 不会为 NULL，那段校验
#          每次都会走到；
#        · 换 R 没用 —— 4.4.x 全都没有那个函数，而我们的字节码就是 4.4.x 的。
#
#      ⇒ 绕法：**自己下载 + 自己校验 + 自己解压到它的缓存目录**。
#        install_r_portable() 里 `is_installed = r_is_installed(...)`（就是
#        "那个目录在不在"），而 force 默认 FALSE、embed_r_runtime() 也不传
#        force（都逐行读过源码）⇒ 缓存命中就直接 return 了，
#        **那段跑不起来的校验根本不会被调用**。
#
#      ⚠️ 校验是我们自己做掉的，不是跳过：用系统自带的 sha256 工具
#        （shasum / sha256sum / certutil）对着**官方的 .sha256 边车**核。
#        一个工具都没有时**大声警告但继续**（fail-open）—— 这是构建期从
#        GitHub Releases 走的 HTTPS 下载，把"机器上没有校验工具"变成硬失败，
#        会让这条路在任何干净机器上都不可用。对不上则**立刻停**。
#
#      ⚠️ 只在真踩到这个 bug 时才插手：`tools::sha256sum` 存在（R >= 4.5）
#        就直接返回，让上游走它自己的路。将来这台机器的 R 升上去，
#        这段代码自动失效、不需要人来删。
#
#      ⚠️ 解压**用上游自己的 tar 程序**（extract_tar_program()）而不是
#        utils::untar 的 internal —— 那份 mac 归档里全是符号链接，
#        R 自带的 internal 实现不保证保留它们。
sha256_from_output <- function(out) {
  # 从一个 sha256 工具的 stdout 里认出那个哈希。**逐行**认，两种排版各一条规则：
  #   ① 把整行的空白全去掉，正好 64 位十六进制 ⇒ 就是它
  #      （certutil 有些版本打成 "AB CD EF …"，每字节一个空格）；
  #   ② 否则按空白切，取第一个 64 位串
  #      （shasum/sha256sum 是 "<哈希>␣␣<文件名>"；PowerShell 的 Get-FileHash
  #        打印的就是光秃秃一行 64 位）。
  #   ③ 切出来的串如果正好是 `\` + 64 位，把那个 `\` 摘掉再认（见下）。
  #
  # ⚠️ 规则③ 是 GNU coreutils 的**转义前缀**：文件名里含反斜杠时，它会给整行
  #    前缀一个 `\`，并把文件名里的反斜杠写成 `\\`。Windows 上每个 temp 路径都是
  #    `C:\Users\…` ⇒ 那边**每一次**都带这个前缀。实测（本机 /tmp）：
  #        sha256sum 'a\b.txt'  →  \<64 位十六进制>␣␣a\\b.txt
  #    没有规则③ 的话这一行整个认不出来 ⇒ 落回 NULL ⇒ 上层当成"这台机器没有
  #    校验工具" ⇒ **跳过校验**，也就是这段代码存在的意义当场消失。
  #    （2026-10-07 第 6 次 CI：Windows 那条红先暴露的是测试里的对照值，但同一段
  #      输出它自己也认不出来 —— 两边一起修了。）
  #
  # ⚠️ 别图省事把**整段输出**拼起来再找 —— 第一版就是那样，结果被
  #    "SHA256 hash of file:"、"CertUtil: …" 这些说明行里的十六进制字母污染，
  #    拼出来长度永远不是 64 ⇒ 找不到 ⇒ 上层当成"这台机器没工具"⇒ **跳过校验**。
  #    那是这条路上最坏的失败形态：看着一切正常，实际上没校。
  #    desktop/tests/seed_portable_r.R 里有专门盯这一条的假绿探针，别删。
  #
  # ⚠️ 单独拆成一个函数不是为了好看：`sha256_of` 要靠 shim PATH 才能造出
  #    Windows 的 certutil 输出，而那条路在 Windows 上根本造不出来
  #    （`file.symlink("/bin/false")` 不存在；`Sys.which` 也不认没扩展名的假货）。
  #    拆开之后，"从输出里认哈希"这段**每个平台都测得到**，包括 Windows。
  pick <- function(tok) {
    if (startsWith(tok, "\\") && nchar(tok) == 65L) tok <- substring(tok, 2L)   # 规则③
    if (grepl("^[0-9a-fA-F]{64}$", tok)) tolower(tok) else NULL
  }
  for (ln in out) {
    h <- pick(gsub("[[:space:]]", "", ln))          # 规则①
    if (!is.null(h)) return(h)
    for (tok in strsplit(ln, "[[:space:]]+")[[1]]) {  # 规则②（+③）
      h <- pick(tok)
      if (!is.null(h)) return(h)
    }
  }
  NULL
}

sha256_of <- function(path) {
  # 按顺序试，用第一个真的能算出哈希的工具。
  #
  # ⚠️ 认哈希的办法是"从输出里**找**那个 64 位十六进制串"，不是按行/按列切：
  #    三个工具的排版各不相同（certutil 前后还夹着说明行）。
  # ⚠️ 而且要兼容**每字节之间带空格**的排版（`AB CD EF …`）——有些版本的
  #    certutil 就是这么打的。只按空白切成 token 的话，那种输出会一个 64 位
  #    串都找不出来 ⇒ 静默降级成"这台机器上没有校验工具"⇒ **跳过校验**。
  #    那是这条路上最坏的失败形态：看着一切正常，实际上没校。
  #    所以下面除了"按空白切"，还把"把所有十六进制片段接起来"也算一个候选。
  arg <- if (.Platform$OS.type == "windows") shQuote(path) else path
  # ⚠️ `-Command` 那段**必须 shQuote**：system2 不替我们引号，整串会按空白拆成
  #    好几个参数，`(…)` 落到 sh 手里就是语法错 —— 2026-10-07 的 mac 日志里实打实
  #    打出来了：`sh: -c: line 0: syntax error near unexpected token '('`。
  #    出错**不抛异常**（stdout 空 ⇒ 这条探针当成没结果 ⇒ 往后走），所以它是
  #    "静默失效"：只有 powershell 一个工具可用的机器上，校验会被悄悄跳过。
  #    shQuote 在 Windows 上自动用 cmd 的引法、在 POSIX 上用单引号，两边都对。
  ps  <- shQuote(sprintf("(Get-FileHash -Algorithm SHA256 '%s').Hash", path))
  probes <- list(
    list("shasum",     c("-a", "256", arg)),
    list("sha256sum",  c(arg)),
    list("certutil",   c("-hashfile", arg, "SHA256")),
    # Windows 上一定有 PowerShell；certutil 的输出格式在不同版本里变过，
    # 留这一条做兜底（Get-FileHash 的输出是干净的 64 位十六进制）。
    list("powershell", c("-NoProfile", "-NonInteractive", "-Command", ps))
  )
  for (p in probes) {
    if (!nzchar(Sys.which(p[[1]]))) next
    out <- suppressWarnings(system2(p[[1]], p[[2]], stdout = TRUE, stderr = FALSE))
    h <- sha256_from_output(out)
    if (!is.null(h)) return(h)
  }
  NULL
}

seed_portable_r <- function(version, plat, arch) {
  se <- asNamespace("shinyelectron")

  if ("sha256sum" %in% getNamespaceExports("tools")) {
    say("这台机器的 R 有 tools::sha256sum —— 上游的校验是好的，不用预置。")
    return(invisible(FALSE))
  }

  need <- c("r_install_path", "r_download_url", "r_executable",
            "extract_tar_program")
  miss <- need[!vapply(need, exists, logical(1), envir = se, inherits = FALSE)]
  if (length(miss)) {
    say("⚠️ shinyelectron 的内部函数对不上了（缺 %s）—— 跳过预置。",
        paste(miss, collapse = ", "))
    say("   包版本换过了？先看这段的注释，别直接把预置删了 —— 上面那个")
    say("   checksum 的 bug 还在的话，删了这条 job 必红。")
    return(invisible(FALSE))
  }
  get_ns <- function(nm) get(nm, envir = se)

  ipath <- get_ns("r_install_path")(version, plat, arch)
  if (!is.null(get_ns("r_executable")(version, plat, arch))) {
    say("便携 R %s 已经在缓存里（%s），跳过下载。", version, ipath)
    return(invisible(TRUE))
  }

  url <- get_ns("r_download_url")(version, plat, arch)
  tmp <- tempfile(fileext = paste0(".", tools::file_ext(url)))
  say("预置便携 R %s ← %s", version, url)
  st <- tryCatch(utils::download.file(url, tmp, mode = "wb", quiet = TRUE),
                 error = function(e) conditionMessage(e))
  if (!is.numeric(st) || !identical(as.integer(st), 0L)) {
    say("⚠️ 下载失败（%s）。预置没做成，剩下的交回上游 ——", st)
    say("   它多半会报那句 'Checksum verification failed ... Actual SHA-256: '（空的），")
    say("   那不是网络问题，是 tools::sha256sum 不存在。看这段的注释。")
    return(invisible(FALSE))
  }
  say("  下载完成：%.1f MB", file.size(tmp) / 1024^2)

  # 官方的 .sha256 边车。取不到就 fail-open，和上游的行为一致。
  want <- tryCatch({
    l  <- suppressWarnings(readLines(paste0(url, ".sha256"), warn = FALSE))
    h  <- unlist(strsplit(paste(l, collapse = " "), "[[:space:]]+"))
    h  <- grep("^[0-9a-fA-F]{64}$", h, value = TRUE)
    if (length(h)) tolower(h[[1]]) else NULL
  }, error = function(e) NULL)
  got <- sha256_of(tmp)

  if (is.null(want)) {
    say("  ⚠️ 没取到官方 .sha256 边车 —— 这一次没得校（继续）")
  } else if (is.null(got)) {
    say("  ⚠️ 这台机器上 shasum/sha256sum/certutil 一个都没有 —— 这一次没得校（继续）")
  } else if (!identical(got, want)) {
    unlink(tmp)
    stop("便携 R ", version, " 的 SHA-256 对不上：\n",
         "  官方边车：", want, "\n",
         "  实际算得：", got, "\n",
         "  下载的文件已经删掉了，别绕过这一步。")
  } else {
    say("  SHA-256 校验通过（%s…，我们自己对边车核的）", substr(got, 1, 16))
  }

  # 解压到 staging 再整体搬 —— 和上游 download_and_extract_portable_tool()
  # 里的做法一样：中途失败绝不留下一个"半个安装"。
  staging <- paste0(ipath, ".staging-", Sys.getpid())
  unlink(staging, recursive = TRUE)
  dir.create(staging, recursive = TRUE, showWarnings = FALSE)
  ok <- tryCatch({
    if (tools::file_ext(tmp) == "gz") {
      utils::untar(tmp, exdir = staging, tar = get_ns("extract_tar_program")())
    } else {
      utils::unzip(tmp, exdir = staging)
    }
    TRUE
  }, error = function(e) { say("  ⚠️ 解压失败：%s", conditionMessage(e)); FALSE })
  unlink(tmp)
  if (!ok) { unlink(staging, recursive = TRUE); return(invisible(FALSE)) }

  dir.create(dirname(ipath), recursive = TRUE, showWarnings = FALSE)
  unlink(ipath, recursive = TRUE)
  if (!file.rename(staging, ipath)) {
    stop("把解压好的便携 R 搬到缓存目录时失败：", staging, " → ", ipath)
  }

  # 搬完用**它自己的** r_executable() 找一遍。找不到就必须撤回整个目录 ——
  # 因为 r_is_installed() 只问"目录在不在"，留着一个结构不对的目录，
  # 上游会命中它、把一堆垃圾打进包里（症状是"包能开、一用就废"）。
  exe <- get_ns("r_executable")(version, plat, arch)
  if (is.null(exe)) {
    unlink(ipath, recursive = TRUE)
    say("  ⚠️ 解压成功但 r_executable() 找不到 Rscript —— 归档结构和它期望的")
    say("     不一样，已经把目录撤掉了，交回上游。")
    return(invisible(FALSE))
  }
  say("  便携 R 已就位：%s", exe)
  invisible(TRUE)
}

seed_portable_r(RUNTIME_R_VERSION, PLAT, ARCH)

# ---- 3. 打包 -----------------------------------------------------------------
icon <- ICON

say("开始打包（第一次会下载 Electron 和便携版 R，慢，也可能失败）")
hr()
res <- tryCatch(
  shinyelectron::export(
    appdir           = STAGE,
    destdir          = file.path(OUT, "exe_out"),
    app_name         = APP_NAME,
    app_type         = "r-shiny",
    # ⚠️ 必须是 bundled。默认值是 shinylive —— 那是把 R 编译成 WebAssembly
    #    在浏览器里跑，而这个应用要读写文件系统、要起子进程跑 R/Python 任务，
    #    WASM 里一样都做不到。设错的症状是"打出来的包能打开、但一用就废"。
    runtime_strategy = "bundled",
    # ★ 这两个**必须**跟着 --plat/--arch 走。2026-10-07 第一次跑 CI 之前它们是
    #   写死的 "win"/"x64" —— 解析、校验、preflight 都加好了，偏偏漏了把值接
    #   到这里，于是两个 mac job 会拿到一份"去建 Windows 包"的指令。
    #   ⚠️ 这类"参数解析对了但没接上"的漏，本地怎么读代码都看不出来，
    #      因为每一段单独看都是对的。
    platform         = PLAT,
    arch             = ARCH,
    icon             = icon,
    overwrite        = TRUE,
    build            = TRUE,
    run_after        = FALSE,   # CI 上没人能"跑一下"刚生出来的东西
    open_after       = FALSE,
    verbose          = TRUE
  ),
  error = function(e) {
    hr()
    say("打包失败：%s", conditionMessage(e))
    say("")
    say("按经验，先看这几条：")
    say("  · Node 是不是 >= 22（node --version）")
    say("  · npm 能不能连上 registry（npm ping）")
    say("  · renv / rlang / withr 装了没有 —— shinyelectron 把它们放在 Suggests，")
    say("    却是打包路径上真用的，缺一个就报一句和原因无关的英文错（preflight 已拦）")
    say("  · Windows 目标在非 Windows 上需要 wine")
    say("  · 磁盘够不够（Electron + R 运行时，中间产物 1 GB 起）")
    quit(status = 1)
  }
)

# ---- 4. 自检产出 -------------------------------------------------------------
hr()
say("找产出物……")

# ⚠️⚠️ 后缀**按平台分**：win 是 .exe，mac 是 .dmg。2026-10-07 之前这里写死
#      `\\.exe$` —— 后果是 mac 那条路**即使打成功了**也会在最后一步报
#      "没找到 .exe" 然后 quit(status = 1)，整条 CI 变成红的，而产物其实在
#      磁盘上躺着。这是同一个"只想着 win"的毛病第三次现形（前两次是
#      export() 的 platform/arch 和 preflight 的宿主机判断）。
#
#      另外 `.app` 是个**目录**：list.files() 本身不会返回它，但递归会把
#      bundle 里面几百个文件全捞出来 —— 所以下面把 `.app/` 里面的路径滤掉，
#      单独用 list.dirs() 找 bundle。
PAT <- if (PLAT == "mac") "\\.(dmg|zip)$" else "\\.(exe|zip)$"
found <- list.files(file.path(OUT, "exe_out"), pattern = PAT,
                    recursive = TRUE, full.names = TRUE)
found <- found[!grepl("\\.app/", found, fixed = TRUE)]
apps <- if (PLAT == "mac") {
  d <- list.dirs(file.path(OUT, "exe_out"), recursive = TRUE)
  d[grepl("\\.app$", d)]
} else character(0)

if (!length(found) && !length(apps)) {
  say("没找到 %s 产物。看看上面的输出里 electron-builder 报了什么。",
      if (PLAT == "mac") ".dmg / .app" else ".exe")
  quit(status = 1)
}
for (f in found) say("  %s  %.1f MB", f, file.info(f)$size / 1024^2)
for (a in apps)  say("  %s/  （.app 包，未压缩）", a)

say("")
if (PLAT == "mac") {
  say("⚠️ 打出来了不等于能用。发出去之前请在真 Mac 上过一遍")
  say("   desktop/README.md 末尾那张验收清单 —— 尤其是这几条：")
  say("     · 双击能起来（不是一闪而过）")
  say("     · 注册一个账号，关掉重开，账号还在（数据目录定位对了）")
  say("     · 跑一个 R 任务，能出结果（自带运行时接上了）")
  say("     · 首次打开的 Gatekeeper 拦截（没有 Developer ID 时必然发生，")
  say("       右键→打开 能绕过；但用户得知道这件事）")
  say("     · ⚠️ 芯片要对：arm64 包在 Intel 机器上跑不了，反之亦然")
} else {
  say("⚠️ 打出来了不等于能用。发出去之前请在真 Windows 上过一遍")
  say("   desktop/README.md 末尾那张验收清单 —— 尤其是这四条：")
  say("     · 双击能起来（不是一闪而过）")
  say("     · 注册一个账号，关掉重开，账号还在（数据目录定位对了）")
  say("     · 跑一个 R 任务，能出结果（自带运行时接上了）")
  say("     · 杀毒软件不拦（没有代码签名时这条最容易出问题）")
}
