#!/usr/bin/env Rscript
# Test_V15.2 · V2：假 SMTP 端到端。
#
#   cd /tmp/dsapp_v152/app && Rscript tests/v152_fake_smtp.R
#
# 证明的是**字节真的送到了收件端、而且内容是对的** —— 不是 `ok: TRUE`。
# 开发期就栽在这上面：发信全绿、图一张没内联、收件人看到裂图。
#
# ⚠️ 这条**不联网、不碰真凭据**：Sys.setenv 把 SMTP 指到 127.0.0.1 的假服务器，
#    USER/PASS 留空（`dsapp_mail_send_raw()` 只在非空时才 setopt）。
#    所以它**可以**进 selftest —— 但先放在这儿，等断言稳了再搬。
#
# ⚠️ 走的是 `dsapp_mail_deliver()`（同步、在本进程里发）。
#    `dsapp_mail_kick()` 那条路会起子进程，子进程**重读 cwd 的 .Renviron**，
#    这里的 Sys.setenv 盖不住它 —— 那条另有一个专用实例验（见 run_scheduler）。

setwd("/tmp/dsapp_v152/app")
for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-22s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}

# ---- 起假服务器 --------------------------------------------------------------
port <- 25000L + (as.integer(Sys.time()) %% 2000L)
# ⚠️ 固定路径，不用 tempdir() —— 红了要能直接翻开 msg_1.eml 看。
#    每次跑之前清一次，免得看到上一封的残留（那会让人以为"这次也收到了"）。
outdir <- "/tmp/dsapp_v152/fakesmtp"
unlink(outdir, recursive = TRUE)
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
out_log <- file.path(outdir, "server.out")

pid <- system2("python3", c("tests/fake_smtp.py", port, outdir,
                            "--count", "1", "--timeout", "45"),
               wait = FALSE, stdout = out_log, stderr = out_log)
ready <- FALSE
for (i in 1:100) {
  Sys.sleep(0.1)
  if (file.exists(out_log) && any(grepl("^READY", readLines(out_log, warn = FALSE)))) {
    ready <- TRUE; break
  }
}
say("假服务器起来了", ready, sprintf("（端口 %d）", port))
if (!ready) { cat(readLines(out_log, warn = FALSE), sep = "\n"); quit(status = 1L) }

# ---- 把发信指到假服务器（不碰 .Renviron，也不碰真凭据）------------------------
# ⚠️ USER/PASS 给的是**假值**，不是真凭据。`dsapp_mail_ready()` 要求四个都非空
#    （D4：用"配没配齐"代替开关），所以留空会直接被拒。
#    假值还能顺带验一件事：curl 手里有凭据、而服务器**不播 AUTH** 时必须
#    照样把信发出去（`dsapp_mail_send_raw()` 只在非空时 setopt）。
Sys.setenv(DSAPP_SMTP_HOST = "127.0.0.1", DSAPP_SMTP_PORT = as.character(port),
           DSAPP_SMTP_SSL = "no",
           DSAPP_SMTP_USER = "fake@example.org", DSAPP_SMTP_PASS = "not-a-real-password",
           DSAPP_SMTP_FROM = "biomamba@biomamba.com.cn",
           DSAPP_SMTP_FROM_NAME = "言出法随")
cfg <- dsapp_config()
ep <- dsapp_mail_endpoint(cfg)
say("指到假服务器", identical(ep$url, sprintf("smtp://127.0.0.1:%d", port)), ep$url)

# ---- 造一封内容明确可断言的速递 ----------------------------------------------
td <- file.path(outdir, "lit"); dir.create(td, showWarnings = FALSE)
png_path <- file.path(td, "fig_test.png")
writeBin(as.raw(c(
  0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a, 0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
  0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, 0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,
  0xde, 0x00,0x00,0x00,0x0c,0x49,0x44,0x41, 0x54,0x08,0xd7,0x63,0xf8,0xcf,0xc0,
  0x00,0x00,0x03,0x01,0x01,0x00,0x18,0xdd, 0x8d,0xb0, 0x00,0x00,0x00,0x00,0x49,
  0x45,0x4e,0x44,0xae,0x42,0x60,0x82)), png_path)
md_path <- file.path(td, "文献速递.md")
SUBJ <- "文献速递 · 单细胞多组学 · 2026-09-28"
md <- paste(c("# 文献速递", "", "正文一句中文。", "",
              "![图](fig_test.png)", ""), collapse = "\n")
writeLines(md, md_path, useBytes = TRUE)

TO <- "someone@example.org"
res <- dsapp_mail_deliver(to = TO, subject = SUBJ, body_md = md,
                          base_dir = td, attach_path = md_path, cfg = cfg)
say("deliver 说成功", isTRUE(res$ok), if (!isTRUE(res$ok)) res$msg else "")

# ---- 等服务器落盘 ------------------------------------------------------------
eml <- file.path(outdir, "msg_1.eml")
envf <- file.path(outdir, "msg_1.env")
for (i in 1:100) { Sys.sleep(0.1); if (file.exists(eml)) break }
say("服务器收到了信", file.exists(eml),
    sprintf("（%d 字节）", if (file.exists(eml)) file.size(eml) else 0L))
if (!file.exists(eml)) {
  cat(readLines(out_log, warn = FALSE), sep = "\n"); quit(status = 1L)
}
msg <- rawToChar(readBin(eml, "raw", n = file.size(eml)))

# ---- 一个够用的 MIME 拆解器 ---------------------------------------------------
# ⚠️ 不能拿明文去 grep 整个报文：正文两个 part 都是
#    `Content-Transfer-Encoding: base64`（见 dsapp_mime_build），
#    直接搜"正文一句中文"必然搜不到 —— 第一版就是这么假红的，
#    而报文其实一个字都没错。断言必须**解出来再比**。
# ⚠️ 取头部必须**先把折行展开再逐行找**。第一版写成一条正则
#    `^Name:.*(\r\n[ \t].*)*`，看着对，实际拿不到续行 —— R 的 PCRE 里 `.`
#    **不匹配 \n 但匹配 \r**，于是 `.*` 把行尾的 \r 吃掉了，后面的 `\r\n`
#    就再也匹配不上。症状是长主题只解出第一块、被**静默截断**
#    （"…· 2026-09"），而主题明明是对的。
hdr <- function(part, name) {
  i <- regexpr("\r\n\r\n", part, fixed = TRUE)
  head <- if (i > 0L) substring(part, 1L, i - 1L) else part
  head <- gsub("\r\n[ \t]+", " ", head)              # 展开续行
  lines <- strsplit(head, "\r\n", fixed = TRUE)[[1]]
  hit <- grep(sprintf("^%s:", name), lines, ignore.case = TRUE, value = TRUE)
  if (!length(hit)) return("")
  sub("^[^:]*:[ \t]*", "", hit[1])
}
# 按 boundary 切出各 part（丢掉前导说明和收尾的 `--B--`）
mime_parts <- function(txt, b) {
  seg <- strsplit(txt, paste0("--", b), fixed = TRUE)[[1]]
  seg <- seg[-1]
  seg <- seg[!grepl("^--", seg)]                 # 收尾那一段
  seg[nzchar(trimws(seg))]
}
# part 的正文：第一个空行之后的一切；是 base64 就解掉
mime_body <- function(part) {
  i <- regexpr("\r\n\r\n", part, fixed = TRUE)
  if (i < 0) return("")
  body <- substring(part, i + 4L)
  if (grepl("base64", hdr(part, "Content-Transfer-Encoding"), fixed = TRUE)) {
    b <- gsub("[^A-Za-z0-9+/=]", "", body)
    return(tryCatch(rawToChar(openssl::base64_decode(b)), error = function(e) ""))
  }
  body
}
# RFC 2047：一个头部里可能有**多个**编码词（长主题会被折成好几块），
# 必须全部解出来拼回去 —— 只取第一块会得到被截断的主题。
rfc2047 <- function(v) {
  if (!nzchar(v)) return("")
  m <- regmatches(v, gregexpr("=\\?UTF-8\\?B\\?[^?]*\\?=", v))[[1]]
  if (!length(m) || identical(m, character(0))) return(v)
  paste(vapply(m, function(w) {
    b <- sub("^=\\?UTF-8\\?B\\?", "", sub("\\?=$", "", w))
    tryCatch(rawToChar(openssl::base64_decode(b)), error = function(e) "")
  }, character(1), USE.NAMES = FALSE), collapse = "")
}

# ---- 信封 --------------------------------------------------------------------
env <- paste(readLines(envf, warn = FALSE), collapse = "\n")
say("收件人正确", grepl(sprintf("RCPT TO=<%s>", TO), env, fixed = TRUE),
    gsub("\n", " | ", env))

# ---- 头部 --------------------------------------------------------------------
say("主题是编码词", grepl("Subject: =\\?UTF-8\\?B\\?", msg))
say("主题解码一致", identical(rfc2047(hdr(msg, "Subject")), SUBJ),
    rfc2047(hdr(msg, "Subject")))
say("From 显示名", grepl("From: =\\?UTF-8\\?B\\?", msg))
say("From 解码一致", grepl("言出法随", rfc2047(hdr(msg, "From")), fixed = TRUE),
    rfc2047(hdr(msg, "From")))
say("To 正确", grepl(TO, hdr(msg, "To"), fixed = TRUE), hdr(msg, "To"))
say("有 Message-ID", grepl("Message-ID: <", msg, fixed = TRUE))
say("有 Date", grepl("Date: ", msg, fixed = TRUE))
say("MIME-Version", grepl("MIME-Version: 1.0", msg, fixed = TRUE))

# ---- 正文：解出来再断言 -------------------------------------------------------
b_mix <- sub('.*boundary="([^"]+)".*', "\\1", hdr(msg, "Content-Type"))
say("mixed 外壳", grepl("multipart/mixed", hdr(msg, "Content-Type")) &&
                    nzchar(b_mix) && !identical(b_mix, hdr(msg, "Content-Type")), b_mix)
mix <- mime_parts(msg, b_mix)
say("mixed 有 2 段", length(mix) == 2L, sprintf("（%d）", length(mix)))

alt <- mix[[1]]
b_alt <- sub('.*boundary="([^"]+)".*', "\\1", hdr(alt, "Content-Type"))
say("alternative 外壳", grepl("multipart/alternative", hdr(alt, "Content-Type")))
alts <- mime_parts(alt, b_alt)
say("alternative 有 2 段", length(alts) == 2L, sprintf("（%d）", length(alts)))

txt_part <- alts[[which(grepl("text/plain", vapply(alts, hdr, "", "Content-Type")))]]
html_part <- alts[[which(grepl("text/html", vapply(alts, hdr, "", "Content-Type")))]]
plain <- mime_body(txt_part)
html <- mime_body(html_part)

say("纯文本有中文", grepl("正文一句中文", plain, fixed = TRUE))
say("HTML 有标题", grepl("<h1>文献速递</h1>", html, fixed = TRUE))

# ---- ★ 图真的在里面（这一条才是重点）----------------------------------------
# 在**解出来的 HTML** 里找 data: URI，且 PNG 魔数（base64 后必是 iVBORw0KGgo）
# 跟着后面 —— 说明收件端拿到的是**图的字节本身**，不是"图裂了"。
say("图字节送到了", grepl("src=\"data:image/png;base64,iVBORw0KGgo", html, fixed = TRUE))
say("没有残留相对路径", !grepl("fig_test.png", html, fixed = TRUE))

# ---- 附件：解出来逐字节比 -----------------------------------------------------
att <- mix[[2]]
say("附件文件名 RFC2231", grepl("filename\\*=UTF-8''", hdr(att, "Content-Disposition")))
say("附件是 base64",
    grepl("base64", hdr(att, "Content-Transfer-Encoding"), fixed = TRUE))
got_att <- tryCatch({
  b <- gsub("[^A-Za-z0-9+/=]", "", {
    i <- regexpr("\r\n\r\n", att, fixed = TRUE); substring(att, i + 4L) })
  openssl::base64_decode(b)
}, error = function(e) raw(0))
say("附件字节一致",
    identical(got_att, readBin(md_path, "raw", n = file.size(md_path))),
    sprintf("（解出 %d 字节 / 原文件 %d 字节）", length(got_att), file.size(md_path)))

# ---- 报文卫生 -----------------------------------------------------------------
say("CRLF 纯净", !grepl("[^\r]\n", msg))

# ---- 让服务器收尾 ------------------------------------------------------------
for (i in 1:150) { Sys.sleep(0.1)
  if (any(grepl("^DONE", readLines(out_log, warn = FALSE)))) break }
log_now <- readLines(out_log, warn = FALSE)
say("服务器干净退出", any(grepl("^DONE got=1", log_now)),
    paste(tail(log_now, 2), collapse = " | "))

cat("\n", if (ok) "=== 假 SMTP 全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
