# =============================================================================
# 加载器（V16.6 item 5）—— build_bytecode.R 会把这个文件复制成分发包里的 app.R
# =============================================================================
# 分发版的目录里**没有 R/、没有 app.R 正文**，只有：
#
#     app.R         ← 就是这个文件（十几行）
#     app.rds       ← app.R 里的函数（字节码）+ 其余顶层语句
#     lib.rds       ← R/*.R 里的全部对象（字节码）
#     built_with_R.txt
#
# Shiny 照常 `runApp(应用目录)`，它 source 的就是这个 app.R。
#
# ⚠️ 改这里等于改分发版的入口。仓库里那份 app.R 一个字都不动 ——
#    源码模式和分发模式是**两条**路，别把它们混起来改。
# =============================================================================
local({
  # ---- 定位应用目录 ---------------------------------------------------------
  # 不能只靠 getwd()：双击 .bat 进来时工作目录未必是应用目录。用
  # --file= 那一项反推（run_local.R 也是这么干的），拿不到才退回 getwd()。
  dsapp_bc_dir <- function() {
    a <- commandArgs(trailingOnly = FALSE)
    hit <- grep("^--file=", a, value = TRUE)
    if (length(hit)) {
      return(dirname(normalizePath(sub("^--file=", "", hit[[1]]), mustWork = FALSE)))
    }
    p <- Sys.getenv("DSAPP_APP_DIR", "")
    if (nzchar(p)) return(normalizePath(p, mustWork = FALSE))
    normalizePath(getwd(), mustWork = FALSE)
  }
  ad <- dsapp_bc_dir()

  # ---- R 版本闸门 -----------------------------------------------------------
  # ⚠️ 这道闸不能省。字节码是**认 R 版本**的：编译用的 R 和跑起来的 R
  #    差得太多时，R 不会给你一个能看懂的错，而是退回解释执行 ——
  #    也就是"应用照跑，只是慢回原样"，没有任何迹象说这个包不该用在这个 R 上。
  #    所以要自己比：build 时把版本号写进 built_with_R.txt。
  #
  # ★ 比到哪一位？**major.minor，不是 major.minor.patch**。这是量出来的，
  #   不是猜的（2026-10-05，Linux 上 R 4.4.2 与 conda 装的 R 4.4.3 对照）：
  #
  #      · 4.4.2 打的 lib.rds 在 4.4.3 里 readRDS —— **无警告**，
  #        .Internal(inspect()) 里 BODY 仍然是 BCODESXP（没有悄悄退回解释）；
  #      · 同一个函数两边算出来的值一样（f(1:10)=113，dsapp_utf8_locale() 两边
  #        都回 "C.UTF-8"）。
  #
  #    回头看 R 自己的实现也对得上：library() 里那段 testRversion() 是
  #    `if (R_version_built_under > current) warning(...)` —— 它管的是
  #    **包的 Built 版本**，而且只在"更新"时才吭声。字节码同理：补丁版之间
  #    格式没变，变了的是 minor。
  #
  #    ⚠️ 为什么非要放宽到 minor：CRAN 的 contrib/4.4 仓库里，包是**用 4.4.3
  #       编译的**，而打包机上的 R 是 4.4.2。卡到 patch 的话，每一个包都得
  #       用 4.4.3 重打一遍才发得出去 —— 而那是台服务器上的系统 R，
  #       换一次要 sudo 动系统包。这条闸门要挡的是"格式真的变了"，
  #       不是"补丁号不一样"。
  stamp <- file.path(ad, "built_with_R.txt")
  if (file.exists(stamp)) {
    want <- trimws(readLines(stamp, warn = FALSE)[1])
    have <- R.version.string
    # ⚠️⚠️ 取前两位之前**必须先把空串滤掉**。
    #    strsplit("R version 4.4.2 (...)", "[^0-9]+") 的第 1 个元素是**空串**
    #    （开头的 "R version " 在第一个数字之前），所以下标整体挪了一位：
    #        [1:3] -> c("", "4", "4") -> ".4.4"   ← 老写法，比的是 major.minor
    #        [1:2] -> c("", "4")      -> ".4"     ← 谁来了都是 ".4"
    #    也就是说，改成 [1:2] 会把这道闸门变成**永远通过** —— 一个不挡任何
    #    东西的闸门，而且它长得跟正常的一模一样。（2026-10-05 差点就这么发出去，
    #    是手工验算 key("4.4.2") vs key("4.6.1") 才发现的。）
    #    写法改成"先滤空串再取"，不再依赖下标偏移这个巧合。
    key <- function(s) {
      v <- strsplit(s, "[^0-9]+")[[1]]
      paste(v[nzchar(v)][1:2], collapse = ".")
    }
    if (!identical(key(want), key(have))) {
      stop(sprintf(paste0(
        "这个程序包是用 %s 打的，当前跑它的是 %s。\n",
        "R 的字节码跨 minor 版本不能保证可用（对不上时 R 会退回解释执行、\n",
        "不一定报错），所以这里直接停下。请用随包的运行时启动：Windows 双击\n",
        "run_app.bat，macOS 双击 run_app.command，或者用包里的\n",
        "runtime/R/bin/Rscript 启动 run_local.R。"),
        want, have), call. = FALSE)
    }
  }

  # ---- 把 R/*.R 的对象放回 globalenv ---------------------------------------
  # ⚠️ 必须是**真 globalenv**，不能另建一个 env：这些函数互相调用走的是
  #    闭包环境，放进别的 env 里就会在新进程的 globalenv 里找不到彼此
  #    （实测报 `object 'f' not found`）。app.R 在源码模式下 source 它们时
  #    用的也是 globalenv，这里要一模一样。
  lib <- readRDS(file.path(ad, "lib.rds"))
  list2env(lib, envir = globalenv())

  # ---- 建应用环境，放 app.R 的函数和顶层语句 -------------------------------
  # 源码模式下 Shiny 把 app.R 求值在一个 new.env(parent = globalenv()) 里，
  # 这里照做：R/*.R 在 globalenv、app.R 的东西在 e，两边的可见性关系和
  # 源码模式完全一致。
  e <- new.env(parent = globalenv())
  bc <- readRDS(file.path(ad, "app.rds"))
  for (nm in names(bc$defs)) {
    fn <- bc$defs[[nm]]
    environment(fn) <- e          # 重新指到应用环境（build 时指向 globalenv）
    assign(nm, fn, envir = e)
  }
  # 其余顶层语句**按原顺序**跑：cfg/engine/app_ui 的赋值、addResourcePath、
  # onStop 注册、启动时的卡死任务清理都在这里面。
  # ⚠️ 顺序不能改 —— 它们是按"后面用前面"写出来的。
  for (ex in bc$drv) eval(ex, envir = e)

  # 源码模式下 app.R 最后一句就是这句。
  shiny::shinyApp(e$app_ui, e$server)
})
