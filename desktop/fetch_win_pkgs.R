#!/usr/bin/env Rscript
# =============================================================================
# 把依赖包的**目标平台二进制**装进随包分发的 R 运行时
# =============================================================================
#   Rscript desktop/fetch_win_pkgs.R <目标 library 目录> [R x.y] [R x.y.z] [平台]
#
#   平台：windows（默认）| macos-arm64 | macos-x86_64
#
# ⚠️ 文件名里的 "win" 是 V13.2 留下的（那时只有 Windows 包）。V16.6 起它
#    也管 macOS —— 名字没改是因为 build_windows_bundle.sh、build_macos_bundle.sh、
#    selftest.R 和 desktop/README.md 都按这个名字引用它，改名只会多出四处
#    需要同步的地方（本仓栽过"两份清单会分家"的跟头）。**它现在三个平台都用。**
#
# ---- 为什么能在 Linux 上干这件事 --------------------------------------------
#
# CRAN 为每个平台备了一份**预编译好的**包：
#   Windows  bin/windows/contrib/<x.y>/xxx.zip        （libs/x64/*.dll 现成）
#   macOS    bin/macosx/big-sur-<arch>/contrib/<x.y>/xxx.tgz（libs/*.so 现成）
# 装包 = 把这个压缩包解开、放进 library/ 下。整件事不需要运行那个平台、
# 不需要 wine、不需要编译器 —— 只要网络。
#
# ⚠️ 版本号必须是**目标运行时**那个 R 的版本（4.4 ↔ contrib/4.4）。装错一档
#    的症状是：包看着在，一 library() 就报 "package was built for R x.y.z"
#    或者干脆 DLL load failed —— 而那时已经在用户机器上了。
#
# ⚠️ 不建议用 install.packages(type = "win.binary") 直接装：那样下载和安装
#    都发生在**当前这个 R** 里，而当前这个 R 是 Linux 的，它会把 .dll/.so 当成
#    装错了的东西丢掉。手动解压是这里唯一可控的做法。
#
# ⚠️ available.packages() 的 type 参数在这里**基本不起作用**（contriburl 一给
#    死，它就照那个 URL 上的 PACKAGES 读，实测传错平台照样返回 23656 个包）。
#    真正决定平台的是**包文件的扩展名**（.zip vs .tgz）和**怎么解** —— 那两件
#    事在下面 PLAT 表里。别以为传了 type 就万事大吉。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop(paste0("用法：Rscript desktop/fetch_win_pkgs.R <library 目录> ",
              "[R x.y] [R x.y.z] [平台] [包缓存目录]"))
}
lib <- args[[1]]
rver <- if (length(args) >= 2) args[[2]] else "4.4"
platform <- if (length(args) >= 4) args[[4]] else "windows"
# ★ 第 5 个参数：**下载缓存目录**（可省）。
#
#   为什么要它：打包脚本每次跑都会 `rm -rf $STAGE`（要重解压运行时），而
#   library 就在 $STAGE 底下 —— 于是"装过的跳过"这条续跑逻辑每次都被连根
#   拔掉，64 个包**每轮全下**。CRAN 偶尔会抽风，实测每 64 个里会掉 2~3 个
#   （`Couldn't connect to server` / `Couldn't resolve host name`），
#   全下成功一轮的概率只有百分之十几 —— **重试到天荒地老也收敛不了**。
#   把下好的包文件存到 $STAGE 外面（和运行时 zip 一起放 dl/），
#   下一轮就只补缺的那几个，两三轮必收敛。
#   不传这个参数 = 老行为（下到 tempdir，用完就删）。
cache <- if (length(args) >= 5) args[[5]] else NULL

# ---- 平台表 -----------------------------------------------------------------
# 每个平台要说清四件事：仓库在哪、包是什么扩展名、怎么解开、编译产物长什么样。
# ⚠️ 这张表是**唯一**分平台的地方。原来 "windows" 是散在代码里的字面量
#    （repo 拼串、".zip"、unzip、libs/x64/*.dll 各一处），加 mac 时那种写法
#    会漏掉某一处，而漏掉的表现是"包解开了、DLL 自检也过了、用户那边一
#    library() 就崩"。
PLAT <- list(
  windows = list(
    label    = "Windows",
    repo     = function(rver) sprintf(
      "https://cloud.r-project.org/bin/windows/contrib/%s", rver),
    ap_type  = "win.binary",
    ext      = ".zip",
    unpack   = function(z, lib) utils::unzip(z, exdir = lib, overwrite = TRUE),
    libdir   = c("libs", "x64"),
    pat      = "\\.dll$",
    binlabel = "x64 DLL"
  ),
  `macos-arm64` = list(
    label    = "macOS (Apple Silicon)",
    repo     = function(rver) sprintf(
      "https://cloud.r-project.org/bin/macosx/big-sur-arm64/contrib/%s", rver),
    ap_type  = "mac.binary.big-sur-arm64",
    ext      = ".tgz",
    unpack   = function(z, lib) utils::untar(z, exdir = lib, tar = "internal"),
    libdir   = "libs",
    pat      = "\\.so$",
    binlabel = "arm64 .so"
  ),
  `macos-x86_64` = list(
    label    = "macOS (Intel)",
    repo     = function(rver) sprintf(
      "https://cloud.r-project.org/bin/macosx/big-sur-x86_64/contrib/%s", rver),
    ap_type  = "mac.binary.big-sur-x86_64",
    ext      = ".tgz",
    unpack   = function(z, lib) utils::untar(z, exdir = lib, tar = "internal"),
    libdir   = "libs",
    pat      = "\\.so$",
    binlabel = "x86_64 .so"
  )
)

if (!platform %in% names(PLAT)) {
  stop("不认识的平台：", platform,
       "\n  可选：", paste(names(PLAT), collapse = " / "))
}
P <- PLAT[[platform]]

# 这个应用真正 library()/:: 用到的包（见 R/*.R 的统计）。
# 递归依赖由 tools::package_dependencies 自己补全，不用手写。
WANT <- c("shiny", "bslib", "htmltools", "httr2", "callr", "processx",
          "DBI", "RSQLite", "DT", "commonmark", "digest", "jsonlite",
          "openssl", "systemfonts", "future", "zip", "BiocManager", "curl")

# R 自带的 recommended 包，portable-r 里已经有了。
# ⚠️ 不排掉它们不会出错，只会白白多下一个几十 MB 的 Matrix/survival。
RECOMMENDED <- c("KernSmooth", "MASS", "Matrix", "boot", "class", "cluster",
                 "codetools", "foreign", "lattice", "mgcv", "nlme", "nnet",
                 "rpart", "spatial", "survival")

repo <- P$repo(rver)
message("== ", P$label, " 二进制仓库：", repo)

ap <- available.packages(contriburl = repo, type = P$ap_type)
if (!nrow(ap)) stop("这个仓库里一个包都没有，检查 R 版本号（", rver, "）对不对")

missing <- setdiff(WANT, rownames(ap))
if (length(missing)) {
  # 不静默跳过：少一个包的表现是用户那边"某个功能点不开"，而这里一句话都没有。
  stop("仓库里找不到这些包：", paste(missing, collapse = ", "))
}

deps <- tools::package_dependencies(WANT, db = ap, recursive = TRUE)
pkgs <- sort(unique(c(WANT, unlist(deps, use.names = FALSE))))
pkgs <- setdiff(pkgs, RECOMMENDED)
# base 包不在 contrib 里，setdiff 掉更省事
pkgs <- intersect(pkgs, rownames(ap))
message("== 要装 ", length(pkgs), " 个包（含递归依赖，已排除 R 自带的）")

dir.create(lib, recursive = TRUE, showWarnings = FALSE)
tmp <- file.path(tempdir(), "binpkgs")
dir.create(tmp, recursive = TRUE, showWarnings = FALSE)
if (!is.null(cache)) {
  # pkgs/ 这一层是为了让缓存目录和运行时压缩包（portable-r-*.zip）分开摆，
  # 不然 dl/ 底下会混着两种完全不同的东西。
  cache <- file.path(cache, "pkgs", platform)
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
}

ok <- character(0); bad <- character(0); from_cache <- 0L
for (p in pkgs) {
  dest <- file.path(lib, p)
  if (dir.exists(dest) && file.exists(file.path(dest, "DESCRIPTION"))) {
    ok <- c(ok, p); next                     # 断点续跑：装过的跳过
  }
  url <- sprintf("%s/%s_%s%s", repo, p, ap[p, "Version"], P$ext)
  # 缓存路径 = <缓存目录>/<平台>/<包>_<版本><扩展名>。两个部分都不能省：
  #   · **带版本号**：换 R 版本时同名不同内容，按裸包名缓存会把 4.4 编的
  #     .dll 塞进 4.5 的库里，而那不报错、只在用户那边崩。
  #   · **带平台**：macOS 的两个架构共用 `.tgz` 扩展名，`<包>_<版本>.tgz`
  #     这个名字在 arm64 和 x86_64 上是**一模一样**的 —— 共用一个平铺缓存
  #     的话，打 Intel 包时会直接吃到 Apple Silicon 的二进制。
  #     ⚠️ 这个坑下面那段 Mach-O 自检**能**抓到（每个包都报 incompatible
  #     architecture，然后 quit(status=1)），所以不会静默发出去 ——
  #     但它会让 x86_64 那个包**根本打不出来**（只要 arm64 的缓存还在），
  #     而报错看着像"CRAN 给的包不对"，指不到缓存上。
  cached <- if (is.null(cache)) NULL else
    file.path(cache, sprintf("%s_%s%s", p, ap[p, "Version"], P$ext))
  zf <- file.path(tmp, paste0(p, P$ext))
  r <- tryCatch({
    if (!is.null(cached) && file.exists(cached) && file.size(cached) > 0) {
      file.copy(cached, zf, overwrite = TRUE)
      from_cache <- from_cache + 1L
    } else {
      utils::download.file(url, zf, mode = "wb", quiet = TRUE)
      # ⚠️ 先落到缓存**再**解包：解包失败说明这个文件是坏的（半截下载），
      #    存进缓存就会一直坏下去 —— 所以缓存只在下完之后、解包之前写。
      #    解包失败时把缓存里那份删掉，下轮重下。
      if (!is.null(cached)) file.copy(zf, cached, overwrite = TRUE)
    }
    P$unpack(zf, lib)
    TRUE
  }, error = function(e) {
    message("   !! ", p, " 失败：", conditionMessage(e))
    if (!is.null(cached) && file.exists(cached)) unlink(cached)
    FALSE
  })
  if (r && file.exists(file.path(dest, "DESCRIPTION"))) {
    ok <- c(ok, p); message("   + ", p, " ", ap[p, "Version"])
  } else {
    bad <- c(bad, p); message("   !! ", p, " 解压后没有 DESCRIPTION")
    if (!is.null(cached) && file.exists(cached)) unlink(cached)
  }
  unlink(zf)
}
if (from_cache > 0L) message("== 其中 ", from_cache, " 个来自本地缓存，没走网络")

message("== 装好 ", length(ok), " 个，失败 ", length(bad), " 个")
if (length(bad)) {
  message("失败清单：", paste(bad, collapse = ", "))
  quit(status = 1)
}

# ---- 收尾自检 1：文件真的解出来了 -------------------------------------------
# ⚠️ 光看目录在不在是不够的：压缩包下载被截断、或者只解出了一半文件，
#    目录照样在。这里检查每个包**必须有 DESCRIPTION**，以及带编译代码的包
#    （就是那几个真正会被用户用到的：RSQLite/systemfonts/openssl…）
#    有没有平台对应的编译产物 —— 少了它，用户那边一 library() 就崩。
#
# ⚠️ 但**"有 .so" 不等于"这个 .so 是给这个架构的"**：CRAN 的 big-sur-arm64
#    和 big-sur-x86_64 是两份不同的仓库，万一 arch 传错，包照样解得开、
#    DESCRIPTION 照样在、libs/*.so 也照样在 —— 上面全绿，用户那边一
#    library() 报的是 "mach-o file, but is an incompatible architecture"。
#    所以多一步：用 file(1) 看那个 .so 的 CPU 类型对不对得上。
#    （file 在 Linux 上也能读 Mach-O 的头部，不需要 Mac。）
if (platform != "windows") {
  want_cpu <- if (platform == "macos-arm64") "arm64" else "x86_64"
  mismatch <- character(0); n_so <- 0L
  for (p in pkgs) {
    d <- do.call(file.path, c(list(lib, p), as.list(P$libdir)))
    if (!dir.exists(d)) next
    sos <- list.files(d, pattern = P$pat, full.names = TRUE)
    n_so <- n_so + length(sos)
    for (s in sos) {
      ft <- tryCatch(system2("file", c("-b", shQuote(s)), stdout = TRUE,
                             stderr = FALSE),
                     error = function(e) character(0))
      ft <- paste(ft, collapse = " ")
      if (nzchar(ft) && !grepl(want_cpu, ft, fixed = TRUE)) {
        mismatch <- c(mismatch, sprintf("%s（file 说：%s）", p, ft))
      }
    }
  }
  message("== 其中 ", n_so, " 个 ", P$binlabel)
  if (length(mismatch)) {
    message("⚠️⚠️ 这些编译产物的架构**不是** ", want_cpu, "：")
    message("   ", paste(mismatch, collapse = "\n   "))
    message("   大概率是 arch 传错了 —— 打包用的平台是 ", platform, "。")
    message("   症状是用户那边一 library() 就报 incompatible architecture。")
    quit(status = 1)
  }
} else {
  n_dll <- 0L; no_dll <- character(0)
  for (p in pkgs) {
    d <- do.call(file.path, c(list(lib, p), as.list(P$libdir)))
    if (dir.exists(d)) {
      k <- length(list.files(d, pattern = P$pat))
      n_dll <- n_dll + k
      if (k == 0) no_dll <- c(no_dll, p)
    }
  }
  message("== 其中 ", n_dll, " 个 ", P$binlabel)
  if (length(no_dll)) message("⚠️ 声明了 libs/x64 却没有 DLL：",
                              paste(no_dll, collapse = ", "))
}

desc_missing <- pkgs[!file.exists(file.path(lib, pkgs, "DESCRIPTION"))]
if (length(desc_missing)) {
  message("⚠️ 没有 DESCRIPTION 的包：", paste(desc_missing, collapse = ", "))
  quit(status = 1)
}

# ---- 收尾自检 2：包声明的 R 版本下限 vs 运行时实际版本 -----------------------
#
# ⚠️ 上面那几条查的全是"文件在不在、架构对不对"。**版本对不对**才是另一个
#    会出事的地方：CRAN 的 contrib/<x.y> 是按 R 版本分档的，万一 rver 传错
#    （比如 4.4 写成了 4.5），包照样解得开、DESCRIPTION 照样在、.dll/.so 也
#    照样是 x64/arm64 —— 上面全绿，但用户那边一 library() 就报
#    "package 'xxx' was built for R 4.5.0"。那时包已经发出去了。
#
#    判据取每个包 Depends/Imports/LinkingTo 里 `R (>= x.y.z)` 的**最高**那个
#    下限 —— 只要有一个够不着，包就用不了。
full_rver <- if (length(args) >= 3) args[[3]] else NULL
if (is.null(full_rver)) {
  message("（没给完整的 R 版本号，跳过「版本下限」这项自检 —— ",
          "build_*_bundle.sh 会传第 3 个参数）")
} else {
  # a >= b ?
  ge <- function(a, b) numeric_version(a) >= numeric_version(b)
  bad <- character(0)
  for (p in pkgs) {
    d <- tryCatch(read.dcf(file.path(lib, p, "DESCRIPTION"),
                           fields = c("Depends", "Imports", "LinkingTo")),
                  error = function(e) NULL)
    if (is.null(d)) next
    txt <- paste(d[!is.na(d)], collapse = ", ")
    m <- regmatches(txt, gregexpr("R \\(>= *[0-9][0-9.]*", txt))[[1]]
    if (!length(m)) next
    need <- max(numeric_version(sub(".*>= *", "", m)))
    if (!ge(full_rver, need)) {
      bad <- c(bad, sprintf("%s（要 R >= %s）", p, as.character(need)))
    }
  }
  if (length(bad)) {
    message("⚠️⚠️ 这些包要求的 R 版本高于运行时（", full_rver, "）：")
    message("   ", paste(bad, collapse = "\n   "))
    message("   大概率是 rver 传错了 —— 运行时是 ", full_rver,
            "，contrib 仓库却用了 ", rver, "。")
    quit(status = 1)
  }
  message("== 全部 ", length(pkgs), " 个包声明的 R 版本下限都不高于 ", full_rver)
}
message("== OK")
