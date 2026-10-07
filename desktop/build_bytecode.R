#!/usr/bin/env Rscript
# =============================================================================
# 把 app.R + R/*.R 打成**两个二进制 rds**（V16.6 item 5）
# =============================================================================
#
#   Rscript --no-environ desktop/build_bytecode.R <仓库目录> <输出目录>
#
# 产出（都写进 <输出目录>）：
#
#   lib.rds    R/*.R 里的**所有**顶层对象（函数已编译成字节码）
#   app.rds    app.R 里的函数（同样编译）+ 剩下的顶层语句（原样留着，启动时再跑）
#   app.R      **极薄的加载器**：读上面两个 rds、把应用拼起来、返回 appobj
#              ★ 这个文件不在这里现写，是把 desktop/bytecode_app.R **复制**过来的 ——
#                加载器和 rds 是一对，必须同生同死：拿新 rds 配旧加载器时，
#                加载器会按老字段名去读，得到 NULL，而报出来的错是
#                "argument is not a function" 之类完全指不到点子上的话。
#                在本脚本里复制 = 打包方没有"忘了同步"的机会。
#
# 分发的包里**没有 R/ 目录、没有明文的 app.R 正文** —— Shiny 拿到的
# app.R 只有十几行，正文全在二进制里。
#
# -----------------------------------------------------------------------------
# ★★★ 先把丑话说前面：这不是"无法查看源码"，只是"不再是明文"
# -----------------------------------------------------------------------------
# 用户的原话是「一体式的程序文件，让用户无法查看源码」。R 是解释型语言，
# **做不到**真正的源码保护。实测（R 4.4.2）：
#
#   形态                    strings/编辑器能看    readRDS + deparse() 能拿
#   明文 .R                 是（就是原文）        是（原文）
#   未压缩 .rds             是（标识符全在）      是（原文）
#   压缩 .rds（本脚本产出） 否（gzip 二进制）      **是 —— 完整原文**
#
# 最后一行是这条路的**上限**：compiler::cmpfun() 把函数编译成 BCODESXP
# （disassemble() 能看到指令），但**常量池里原样留着整棵 AST** ——
# 因为 R 要靠它做 deparse/print/srcref。所以 `deparse(readRDS("app.rds")$...$server)`
# 出来的是**和源码逐字一样**的函数体。
# （顺带一提：早期版本用 `strings app.rds | grep 函数名` 自测，搜不到就当
#   藏住了 —— 那搜不到只是因为 saveRDS 默认 gzip 压过，跟藏没藏无关。）
#
# 所以这个包的**真实价值**是两条，都不是"保密"：
#   1. 用户拿到的是"一个文件 + 一堆数据"，没有一坨 .R 可以翻；
#   2. **启动时不用再解析 + 编译**：JIT 那笔开销在 build 时就付掉了
#      （见 app.R 顶上那段 DSAPP_JIT 的说明 —— 本应用每个 worker 世代
#      只有第 2 个会话会被 JIT 卡 8 秒，预编译顺带把这件事整个消掉）。
# 要真保密只能不跑 R（编译成原生程序），那是另一个项目。
#
# ⚠️ **字节码跨机器可以，跨 R 版本要卡在 minor 这一位**。编译用的 R 和跑它
#    的 portable R 必须 **major.minor 相同**（打包机 4.4.2 / 运行时 4.4.3 是
#    验证过的组合；两个 build 脚本默认 RVER=4.4.3）。版本对不上时 R 会认出
#    字节码版本不符并**回退成解释执行**（不报错）—— 所以别指望它崩给你看。
#    ★ 为什么是 minor 不是 patch：实测 4.4.2 打的 lib.rds 在 4.4.3 里
#      readRDS 无警告、BODY 仍是 BCODESXP、结果一致（bytecode_app.R 里记了
#      全过程）；而 CRAN 的 contrib/4.4 里包是**用 4.4.3 编的**，卡到 patch
#      就一个包都发不出去。
#    两道闸各自把关：build 脚本比"打包机 R vs 包里的运行时"，加载器比
#    "built_with_R.txt vs 当前跑的 R"（见 desktop/bytecode_app.R）。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("用法：Rscript --no-environ desktop/build_bytecode.R <仓库目录> <输出目录>",
       call. = FALSE)
}
repo <- normalizePath(args[[1]], mustWork = TRUE)
out_dir <- args[[2]]
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

say <- function(...) cat(sprintf(...), "\n", sep = "")
die <- function(...) stop(sprintf(...), call. = FALSE)

say("仓库：%s", repo)
say("输出：%s", out_dir)
say("打包用的 R：%s", R.version.string)

# -----------------------------------------------------------------------------
# 1. 从 app.R 里**读**出 R/*.R 的清单（不抄一份）
# -----------------------------------------------------------------------------
# 抄一份清单 = 两份会分家：app.R 里加了一个文件、这里没加，表现是"分发包
# 里某个页面打不开"，而源码模式一切正常 —— 最难查的那一类。
# 所以这里解析 app.R，找到 `files <- c(...)` 那一句，只求值**右边的 c()**。
app_src <- readLines(file.path(repo, "app.R"), warn = FALSE)
app_exprs <- parse(text = app_src, keep.source = FALSE)

find_r_files <- function(exprs) {
  hit <- NULL
  walk <- function(e) {
    if (is.call(e)) {
      if (identical(e[[1]], as.name("<-")) && length(e) == 3L &&
          identical(e[[2]], as.name("files")) && is.call(e[[3]]) &&
          identical(e[[3]][[1]], as.name("c"))) {
        hit <<- eval(e[[3]], envir = baseenv())
      }
      for (i in seq_along(e)) if (!is.null(e[[i]])) try(walk(e[[i]]), silent = TRUE)
    }
  }
  for (e in exprs) walk(e)
  hit
}

r_files <- find_r_files(app_exprs)
if (is.null(r_files) || !length(r_files)) {
  die("在 app.R 里找不到 `files <- c(...)` —— 那份 R/*.R 清单挪位置了？" )
}
say("从 app.R 读到 %d 个 R/*.R 文件", length(r_files))

# ⚠️ 反方向也要查：**磁盘上有、清单里没有**的 R/*.R。
#    只查"清单里的都存在"是不够的 —— 新加一个文件却忘了往 app.R 的清单里添，
#    源码模式下那个文件根本没被 source（功能"莫名不存在"），而分发包是照
#    清单打的，于是**两边都坏**，且坏得一模一样，谁也不提示。
#    build_windows_bundle.sh 里原来有一条同样的检查，那是在**发布物**上查的
#    （只覆盖 Windows zip）；挪到这里，任何一种包、包括还没写的，都自动被管住。
on_disk <- sort(list.files(file.path(repo, "R"), pattern = "\\.R$"))
not_listed <- setdiff(on_disk, r_files)
if (length(not_listed)) {
  die("R/ 下有 %d 个文件没写进 app.R 的 files 清单：%s",
      length(not_listed), paste(not_listed, collapse = ", "))
}

# -----------------------------------------------------------------------------
# 2. 把 R/*.R 按**原顺序** source 进 globalenv，收集顶层对象
# -----------------------------------------------------------------------------
# ⚠️ 必须进 globalenv，而且必须原顺序：这些文件里后面 source 的会调用前面
#    定义的函数（见 app.R 里那段顺序说明）。
#
# ⚠⚠️ 而且**必须真的进 globalenv**，不能收进一个自建的 env 了事 ——
#    实测过：R/*.R 的函数互相调用走的是**闭包环境**，把 `g` 收进 list 存起来
#    再 readRDS 出来，g 里那句 `f(...)` 会在**新进程的 globalenv** 里找 f，
#    找不到就 `object 'f' not found`。所以恢复的时候也要放回真 globalenv。
before <- ls(globalenv(), all.names = TRUE)
# ⚠️ 循环必须裹在 local() 里：不然循环变量 f / p 会落在**快照之后**的
#    globalenv 里，被当成"R/*.R 的顶层对象"一起打进包 —— 于是分发版的
#    globalenv 里凭空多出一个 f 和一个 p。它们不一定立刻坏事，但
#    R/*.R 的函数全都在 globalenv 里按名字找变量，塞进去两个来路不明的
#    短名字纯属埋雷。实测第一版就是这么污染了 3 个对象。
local({
  for (f in r_files) {
    p <- file.path(repo, "R", f)
    if (!file.exists(p)) die("app.R 的清单里有 %s，但仓库里没有这个文件", f)
    source(p, local = globalenv())
  }
})
# "before" 自己也要排掉：它在快照**之后**才被赋值，所以它自己在 delta 里
# （第一版就是这么把 `before` 这个字符向量打进包里的）。
lib_names <- setdiff(ls(globalenv(), all.names = TRUE), c(before, "before"))
# 兜底：本脚本自己的临时变量一个都不许进包。上面两个修法任何一条失效，
# 这里要当场炸，而不是等分发包里多出一个叫 f 的变量。
leaked <- intersect(lib_names, c("args", "repo", "out_dir", "say", "die",
                                 "app_src", "app_exprs", "find_r_files",
                                 "r_files", "before", "lib", "lib_names",
                                 "defs", "drv", "def_names", "n_cmp", "sz"))
if (length(leaked)) die("打包脚本自己的变量漏进包里了：%s", paste(leaked, collapse = ", "))
lib <- mget(lib_names, envir = globalenv(), ifnotfound = list(NULL))
say("R/*.R 顶层对象：%d 个", length(lib))

# -----------------------------------------------------------------------------
# 3. 拆 app.R 的顶层语句：函数定义 / 其余 / 末尾的 shinyApp()
# -----------------------------------------------------------------------------
is_def <- function(e) {
  is.call(e) && identical(e[[1]], as.name("<-")) && length(e) == 3L &&
    is.name(e[[2]]) && is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function"))
}
is_shinyapp <- function(e) is.call(e) && identical(e[[1]], as.name("shinyApp"))

def_names <- character(0)
defs <- list()
drv <- list()
for (e in app_exprs) {
  if (is_def(e)) {
    nm <- as.character(e[[2]])
    scratch <- new.env(parent = globalenv())
    # 只求值 `name <- function(...)` —— 建个闭包而已，**函数体不跑**
    eval(e, envir = scratch)
    fn <- get(nm, envir = scratch)
    # ⚠️ 先砍成 globalenv 再编译：不砍的话闭包环境会连着把 build 时的
    #    scratch env 整个序列化进去（那个 env 的父是 globalenv，还不算灾难，
    #    但白胖一圈，而且语义上会指错地方）。恢复时加载器会重新指到应用 env。
    environment(fn) <- globalenv()
    defs[[nm]] <- compiler::cmpfun(fn)
    def_names <- c(def_names, nm)
  } else if (is_shinyapp(e)) {
    # 启动器自己会 shinyApp(app_ui, server)，这里不用再建一个
    next
  } else {
    drv[[length(drv) + 1L]] <- e
  }
}
say("app.R 函数定义：%d 个（%s）", length(defs), paste(def_names, collapse = ", "))
say("app.R 其余顶层语句：%d 条（启动时按原顺序跑）", length(drv))

if (!all(c("server", "app_ui") %in% c(def_names, "app_ui"))) {
  die("app.R 里没有 server 函数定义 —— 拆分逻辑对不上了")
}
if (!"server" %in% def_names) die("没找到 server()，拆分逻辑对不上了")

# -----------------------------------------------------------------------------
# 4. 把所有函数编译成字节码
# -----------------------------------------------------------------------------
# 非函数的对象（常量、options 结果之类）原样留着。
n_cmp <- 0L
for (nm in names(lib)) {
  if (is.function(lib[[nm]])) {
    lib[[nm]] <- compiler::cmpfun(lib[[nm]])
    n_cmp <- n_cmp + 1L
  }
}
say("已编译成字节码：lib %d 个 + app %d 个 = %d 个函数",
    n_cmp, length(defs), n_cmp + length(defs))

# -----------------------------------------------------------------------------
# 5. 落盘
# -----------------------------------------------------------------------------
saveRDS(lib, file.path(out_dir, "lib.rds"), compress = "xz")
saveRDS(list(defs = defs, drv = drv,
             built_by = R.version.string,
             built_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
        file.path(out_dir, "app.rds"), compress = "xz")

# 记一份版本指纹：启动器要拿它和**跑起来的那个 R** 比，对不上就拒绝启动。
# 因为 R 遇到版本不符的字节码是**静默回退**到解释执行，不比对就等于没验。
writeLines(R.version.string, file.path(out_dir, "built_with_R.txt"))

# ---- 6. 把加载器复制成分发包里的 app.R --------------------------------------
# ⚠️ 源文件在 desktop/ 下（不在 R/ 里，所以不会被打进 lib.rds），
#    目录取本脚本自己所在的位置 —— 不能用 getwd()，打包脚本是从别处调过来的。
# Rscript 一定会带 --file=；被 source() 进来时没有，那就退回"仓库下的 desktop/"
# （本脚本就住在那里）。两条都拿不到才会报错，不留"悄悄复制了别处一个同名文件"的缝。
self_dir <- local({
  hit <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(hit)) dirname(sub("^--file=", "", hit[[1]]))
  else file.path(repo, "desktop")
})
loader_src <- file.path(self_dir, "bytecode_app.R")
if (!file.exists(loader_src)) die("找不到加载器 %s", loader_src)
# ⚠️ 两层都要 invisible：file.copy() 返回 TRUE/FALSE，在脚本顶层会被 R
#    **自动打印**出来（打包日志里凭空一行 `[1] TRUE`）；而且失败时它返回
#    FALSE 而不是报错 —— 不接返回值的话，"加载器没复制过去"会静默通过，
#    直到用户双击时才报"找不到 app.R"。
copied <- file.copy(loader_src, file.path(out_dir, "app.R"), overwrite = TRUE)
if (!isTRUE(copied)) die("加载器复制失败：%s -> %s", loader_src, out_dir)
say("加载器 -> app.R  %s B", file.size(file.path(out_dir, "app.R")))

sz <- function(p) format(file.size(p) / 1024, digits = 4)
say("lib.rds  %s KB", sz(file.path(out_dir, "lib.rds")))
say("app.rds  %s KB", sz(file.path(out_dir, "app.rds")))
say("完成。")
