# =============================================================================
# desktop/build_exe.R 里 seed_portable_r() / sha256_of() 的测试
#
# 跑法（不需要联网 —— 下载那一步被打了桩，指向本地造的假归档）：
#     Rscript --no-environ desktop/tests/seed_portable_r.R
#
# 为什么要单独测这两个函数：
#   · seed_portable_r 存在的理由是绕开 shinyelectron 0.2.1 的一个 bug
#     （在 R 4.4.x 上 tools::sha256sum 不存在 ⇒ 便携 R 的校验**每次都失败**）。
#     绕法是"把缓存目录先填好，让它短路"。**短路一旦不成立，症状是 CI 上
#     再报一次那句看不懂的 checksum 错**，而不是这里红 —— 所以这里必须钉住。
#   · sha256_of 是我们自己接手的校验。它**静默出错的方式**是"返回 NULL"，
#     而上层把 NULL 当成"这台机器没有校验工具"⇒ **跳过校验**。那是这条路上
#     最坏的形态：看着一切正常，实际上没校。所以下面专门有一条假绿探针。
#
# ⚠️ 下面那条"带空格的 certutil 输出"是**假绿探针**，别删：
#    第一版 sha256_of 只按空白切 token，遇到 "AB CD EF …" 这种排版会一个
#    64 位串都找不到。我当时把夹具的 PATH 分隔符写成了 .Platform$file.sep
#    （"/" 而不是 ":"），PATH 拼出来一个有效项都没有，Sys.which 回落到了
#    **真的** shasum ⇒ 夹具整体空转、探针假绿，而它长得像通过。
#    所以夹具里现在有 stopifnot 自检 which 出来的确实是那几个假货。
# =============================================================================

suppressMessages(library(shinyelectron))
say <- function(...) cat(sprintf(...), "\n", sep = "")
PASS <- 0L; FAIL <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { PASS <<- PASS + 1L; cat("  ✔ ", what, "\n", sep = "") }
  else { FAIL <<- FAIL + 1L; cat("  ✘ ", what, "  ← 红了\n", sep = "") }
}

# ---- 从 build_exe.R 里**结构化地**取出这两个真函数（不抄一份，免得测的是副本）
HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) stop("请用 Rscript <路径> 跑，别用 source()")
  normalizePath(file.path(dirname(sub("^--file=", "", a[[1]])), "..", "build_exe.R"))
})
cat("被测文件：", HERE, "\n", sep = "")
ex <- parse(HERE)
env <- new.env(parent = globalenv())
env$say <- say
got <- character(0)
for (e in ex) {
  if (is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]]) &&
      as.character(e[[2]]) %in% c("sha256_of", "sha256_from_output", "seed_portable_r")) {
    eval(e, env); got <- c(got, as.character(e[[2]]))
  }
}
cat("取到的函数：", paste(got, collapse = ", "), "\n\n", sep = "")
stopifnot(setequal(got, c("sha256_of", "sha256_from_output", "seed_portable_r")))

# ---- 1. 真 URL 字符串（核对资产名，和 GitHub releases API 列出来的一致）------
cat("[1] r_download_url 拼出来的 URL\n")
urls <- list(
  c("4.4.3","mac","arm64")  -> "https://github.com/portable-r/portable-r-macos/releases/download/v4.4.3/portable-r-4.4.3-macos-arm64.tar.gz",
  c("4.4.3","mac","x64")    -> "https://github.com/portable-r/portable-r-macos/releases/download/v4.4.3/portable-r-4.4.3-macos-x86_64.tar.gz",
  c("4.4.3","win","x64")    -> "https://github.com/portable-r/portable-r-windows/releases/download/v4.4.3/portable-r-4.4.3-win-x64.zip",
  c("4.4.3","win","arm64")  -> "https://github.com/portable-r/portable-r-windows/releases/download/v4.4.3/portable-r-4.4.3-win-aarch64.zip")
for (k in names(urls)) {
  p <- strsplit(k, ",")[[1]]
  u <- shinyelectron:::r_download_url(p[1], p[2], p[3])
  ok(identical(u, urls[[k]]), sprintf("%s/%s/%s", p[1], p[2], p[3]))
}

# ---- 2. sha256_of：和 sha256sum 对一遍 --------------------------------------
cat("\n[2] sha256_of()\n")
f <- tempfile(); writeLines("hello 言出法随", f)
ref <- sub("[[:space:]].*$", "", system2("sha256sum", f, stdout = TRUE))
ok(identical(env$sha256_of(f), tolower(ref)), paste0("算出来的和 sha256sum 一致（", substr(ref,1,12), "…）"))
ok(is.null(env$sha256_of(tempfile())), "文件不存在时返回 NULL（不炸）")

# ⚠️ 下面这段是**集成**测法（真的换 PATH、真的 fork 子进程），只在
#    POSIX 上有意义：Windows 上 `file.symlink("/bin/false")` 不存在，而且
#    `Sys.which` 不认没有扩展名的假货，造不出这个夹具。Windows 上靠上面
#    2b 那节覆盖（那节才是真正在验解析逻辑的）。
# ⚠️ 每字节带空格的排版（有些 certutil 就这么打）必须也能认出来。
#    这条是**假绿探针**：只按空白切 token 的实现在这里必然返回 NULL，
#    而 NULL 会被上层当成"这台机器没工具" ⇒ 静默跳过校验。
if (.Platform$OS.type == "windows") {
  cat("  （Windows：跳过 PATH 集成那段，2b 已覆盖解析逻辑）\n")
} else {
disp <- paste(strsplit(toupper(ref), "(?<=..)", perl = TRUE)[[1]], collapse = " ")
fakebin <- file.path(tempdir(), "certutil")   # ⚠️ 名字必须就是 certutil，否则盖不住真的
writeLines(c("#!/bin/sh", sprintf("echo 'SHA256 hash of file:'"), sprintf("echo '%s'", disp),
             "echo 'CertUtil: -hashfile command completed successfully.'"), fakebin)
Sys.chmod(fakebin, "0755")
old_path <- Sys.getenv("PATH")
# 把 shasum/sha256sum/powershell 藏起来，逼它走 certutil 分支
fakeshim <- file.path(tempdir(), "shim"); dir.create(fakeshim, showWarnings = FALSE)
for (nm in c("shasum", "sha256sum", "powershell"))
  stopifnot(isTRUE(file.symlink("/bin/false", file.path(fakeshim, nm))))
# ⚠️ 分隔符是 .Platform$path.sep（":"）**不是** file.sep（"/"）——
#    我第一版就写成 file.sep 了，PATH 拼成 "shim//tmp//usr/bin:…" 一个有效项都没有，
#    Sys.which 于是回落到**原来的** PATH，探针量到的是真的 shasum ——
#    整套夹具空转，探针假绿，而它长得像通过。所以下面必须自检。
Sys.setenv(PATH = paste(fakeshim, tempdir(), old_path, sep = .Platform$path.sep))
w <- Sys.which(c("shasum", "sha256sum", "certutil", "powershell"))
stopifnot(
  identical(unname(w[["shasum"]]),    file.path(fakeshim, "shasum")),
  identical(unname(w[["sha256sum"]]), file.path(fakeshim, "sha256sum")),
  identical(unname(w[["certutil"]]),  file.path(tempdir(), "certutil")),
  identical(unname(w[["powershell"]]),file.path(fakeshim, "powershell")))
cat("   [调试] PATH 前两段：", paste(head(strsplit(Sys.getenv("PATH"), ":")[[1]], 2), collapse=" | "), "\n")
cat("   [调试] which：", paste(names(Sys.which(c("shasum","sha256sum","certutil","powershell"))),
    Sys.which(c("shasum","sha256sum","certutil","powershell")), sep="=", collapse="  "), "\n")
cat("   [调试] 假 certutil 存在？", file.exists(file.path(tempdir(), "certutil")), "\n")
o <- suppressWarnings(system2("certutil", c("-hashfile", f, "SHA256"), stdout=TRUE, stderr=FALSE))
cat("   [调试] certutil 输出行数=", length(o), " 第2行=", if(length(o)>1) o[2] else "<无>", "\n")
cat("   [调试] sha256_of 函数体里的 hit 那行=",
    grep("hit <- grep", deparse(body(env$sha256_of)), value=TRUE), "\n")
got_disp <- env$sha256_of(f)
Sys.setenv(PATH = old_path)
ok(identical(got_disp, tolower(ref)),
   paste0("★ 带空格的 certutil 输出也能认（拿到 ", if (is.null(got_disp)) "NULL" else substr(got_disp,1,12), "…）"))
}  # end if not windows

# ---- 2b. ★ 各平台 sha256 工具的真实排版（不依赖 PATH，Windows 上也跑）-------
#
#   这一节是这套测试里**唯一在 Windows runner 上也有覆盖**的部分 ——
#   而 Windows 恰恰是 `sha256_of` 最没把握的地方（本机是 Linux，
#   conda 那份 certutil 是 NSS 的、跟 Windows 自带的完全不是一个程序）。
#   下面每一行的 `out` 都是那个工具**真的会打出来的样子**，不是我编的。
cat("\n[2b] 各种工具的排版都能认\n")
H <- strrep("ab", 32)                       # 一个长度为 64 的十六进制串
UP <- toupper(H)
spaced <- paste(strsplit(UP, "(?<=..)", perl = TRUE)[[1]], collapse = " ")
cases <- list(
  list(nm = "shasum / sha256sum",  out = c(paste0(H, "  dsapp.zip")),                    want = H),
  list(nm = "sha256sum 二进制标记", out = c(paste0(H, " *dsapp.zip")),                    want = H),
  list(nm = "certutil 连写",        out = c("SHA256 hash of file dsapp.zip:", UP,
                                            "CertUtil: -hashfile command completed successfully."),
                                    want = H),
  list(nm = "★certutil 每字节空格", out = c("SHA256 hash of file dsapp.zip:", spaced,
                                            "CertUtil: -hashfile command completed successfully."),
                                    want = H),
  list(nm = "PowerShell Get-FileHash", out = c(UP, ""),                                   want = H),
  list(nm = "什么都没有",           out = character(0),                                    want = NULL),
  list(nm = "只有说明行（不能乱认）", out = c("Usage: certutil <command> -d <dbdir> <options>",
                                            "certutil - Utility to manipulate NSS certificate databases"),
                                    want = NULL))
for (cs in cases) {
  g <- env$sha256_from_output(cs$out)
  ok(identical(g, cs$want),
     sprintf("%-24s → %s", cs$nm, if (is.null(g)) "NULL" else substr(g, 1, 12)))
}

# ---- 3. 造归档 ---------------------------------------------------------------
WORK <- file.path(tempdir(), "seedtest"); dir.create(WORK, showWarnings = FALSE)
mkarc <- function(ver, plat, arch, exe, base = NULL) {
  # ⚠️ 名字**写死成真的**（从 GitHub releases API 列出来的资产名抄的），
  #    不从 r_executable() 的公式推 —— 推出来的话这段就成了自证。
  #    mac 的 portable 目录是 `macos-<arm64|x86_64>`，win 是 `win-<aarch64|x64>`。
  base <- base %||% sprintf("portable-r-%s-%s-%s", ver,
                            if (plat == "mac") "macos" else plat,
                            if (arch == "arm64") (if (plat == "mac") "arm64" else "aarch64")
                            else (if (plat == "mac") "x86_64" else "x64"))
  src <- file.path(WORK, "src", base)
  unlink(src, recursive = TRUE); dir.create(file.path(src, "bin"), recursive = TRUE)
  writeLines("#!/bin/sh\necho fake", file.path(src, "bin", exe))
  Sys.chmod(file.path(src, "bin", exe), "0755")
  ext <- if (plat == "win") "zip" else "tar.gz"
  out <- file.path(WORK, paste0(base, ".", ext))
  unlink(out); old <- setwd(file.path(WORK, "src"))
  if (plat == "win") utils::zip(out, base, flags = "-rq") else utils::tar(out, base, tar = "tar")
  setwd(old)
  h <- sub("[[:space:]].*$", "", system2("sha256sum", out, stdout = TRUE))
  writeLines(sprintf("%s  %s", h, basename(out)), paste0(out, ".sha256"))
  cat(sprintf("  · %-44s %6d B\n", basename(out), file.size(out)))
  out
}
`%||%` <- function(a, b) if (is.null(a)) b else a
cat("\n[3] 造测试归档\n")
A_MAC <- mkarc("9.9.9", "mac", "arm64",   "Rscript")
A_WIN <- mkarc("9.9.8", "win", "x64",     "Rscript.exe")
A_BAD <- mkarc("9.9.7", "mac", "arm64",   "Rscript", base = "wrongname")

# ---- 4. 打桩：把 r_download_url 换成 file://，其余全走真代码 ------------------
cat("\n[4] 打桩 r_download_url（→ file://）\n")
maps <- c("9.9.9/mac/arm64" = A_MAC, "9.9.8/win/x64" = A_WIN, "9.9.7/mac/arm64" = A_BAD)
cache <- shinyelectron:::cache_dir()
unlockBinding("r_download_url", asNamespace("shinyelectron"))
assign("r_download_url", function(version, platform = NULL, arch = NULL) {
  k <- paste(version, platform, arch, sep = "/")
  if (k %in% names(maps)) paste0("file://", maps[[k]]) else "file:///nonexistent/nope.tar.gz"
}, envir = asNamespace("shinyelectron"))
say("  桩已装上（cache_dir = %s）", cache)

cleanup <- function(ver, plat, arch) {
  p <- shinyelectron:::r_install_path(ver, plat, arch); unlink(p, recursive = TRUE)
}
seed <- function(...) {
  # 真函数是从 build_exe.R 里取出来的那份，只是它的父环境里要有 getNamespaceExports 等
  environment(env$seed_portable_r) <- env
  env$seed_portable_r(...)
}

# ---- 5. mac / arm64：正常预置 -------------------------------------------------
cat("\n[5] mac/arm64 预置\n")
cleanup("9.9.9", "mac", "arm64")
r <- seed("9.9.9", "mac", "arm64")
ok(isTRUE(r), "seed_portable_r 返回 TRUE")
exe <- shinyelectron:::r_executable("9.9.9", "mac", "arm64")
ok(!is.null(exe) && file.exists(exe), paste0("r_executable() 找得到：", exe))

# ---- 6. ★ 决定性的一条：预置之后，真的 install_r_portable() 会短路 -----------
#    给它一个**不存在**的 URL：如果它还去下载，就必然报错。
cat("\n[6] ★ 预置后 install_r_portable() 必须短路（URL 指向不存在的文件）\n")
res <- tryCatch(
  shinyelectron:::install_r_portable(version = "9.9.9", platform = "mac", arch = "arm64",
                                     verbose = FALSE),
  error = function(e) paste0("<报错：", conditionMessage(e), ">"))
ok(identical(res, shinyelectron:::r_install_path("9.9.9", "mac", "arm64")),
   "install_r_portable 直接返回缓存路径，没有去下载")

# ---- 7. win / x64（.zip + Rscript.exe）---------------------------------------
cat("\n[7] win/x64 预置\n")
cleanup("9.9.8", "win", "x64")
ok(isTRUE(seed("9.9.8", "win", "x64")), "seed_portable_r 返回 TRUE")
ok(!is.null(shinyelectron:::r_executable("9.9.8", "win", "x64")), "Rscript.exe 找得到")

# ---- 8. 归档结构不对 ⇒ 必须撤回目录（不能留个坏目录毒到上游）----------------
cat("\n[8] 归档结构不对\n")
cleanup("9.9.7", "mac", "arm64")
r <- seed("9.9.7", "mac", "arm64")
ok(isFALSE(r), "返回 FALSE")
ok(!dir.exists(shinyelectron:::r_install_path("9.9.7", "mac", "arm64")),
   "★ 缓存目录被撤掉了（否则 r_is_installed() 会命中毒上游）")

# ---- 9. 哈希对不上 ⇒ 必须 stop，且不留目录 -----------------------------------
cat("\n[9] 哈希对不上\n")
cleanup("9.9.9", "mac", "arm64")
writeLines(paste0(strrep("0", 64), "  ", basename(A_MAC)), paste0(A_MAC, ".sha256"))
r <- tryCatch(seed("9.9.9", "mac", "arm64"), error = function(e) conditionMessage(e))
ok(is.character(r) && grepl("SHA-256 对不上", r), "抛错且说的是哈希对不上")
ok(!dir.exists(shinyelectron:::r_install_path("9.9.9", "mac", "arm64")), "没有留下目录")
# 还原边车
h <- sub("[[:space:]].*$", "", system2("sha256sum", A_MAC, stdout = TRUE))
writeLines(sprintf("%s  %s", h, basename(A_MAC)), paste0(A_MAC, ".sha256"))

# ---- 10. 边车没了 ⇒ fail-open，但照样装上 ------------------------------------
cat("\n[10] 边车取不到\n")
unlink(paste0(A_MAC, ".sha256"))
ok(isTRUE(seed("9.9.9", "mac", "arm64")), "没边车也继续（fail-open）")
ok(!is.null(shinyelectron:::r_executable("9.9.9", "mac", "arm64")), "照样装上了")

# ---- 11. 已经有缓存 ⇒ 不动它 -------------------------------------------------
cat("\n[11] 缓存已存在\n")
ok(isTRUE(seed("9.9.9", "mac", "arm64")), "第二次调用直接命中缓存")

# ---- 收尾 --------------------------------------------------------------------
cat(sprintf("\n===== 过 %d 条，红 %d 条 =====\n", PASS, FAIL))
for (v in list(c("9.9.9","mac","arm64"), c("9.9.8","win","x64"), c("9.9.7","mac","arm64")))
  cleanup(v[1], v[2], v[3])
if (FAIL) quit(status = 1)
