#!/usr/bin/env Rscript
# Test_V15.2 的真发探针：把一条**构造好的**速递走完整条链路发出去。
#
#   cd /tmp/dsapp_v152/app && Rscript tests/v152_send_probe.R <收件人>
#
# ⚠️ 收件人**必须从命令行给**，不给就拒跑。默认写死一个地址的话，
#    早晚有人对着生产库跑一遍，把测试邮件发给真实的用户。
#
# ⚠️ 这份**不进 selftest.R**（那里从不联网），也**不进 deploy.sh --check**。
#    它的角色和 tests/real_api.R 一样：手工验收用的。
#
# SMTP 凭据：本文件**不碰**。它们只从 .Renviron 读（DSAPP_SMTP_*），
# 也就是生产配置本身的那一份 —— 不在这里再抄一遍、不进命令行参数
# （ps 和 shell 历史都看得到）。

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || !nzchar(args[1])) {
  stop("用法：Rscript tests/v152_send_probe.R <收件人邮箱>\n",
       "      收件人必须显式给 —— 不许有默认值，见文件头。")
}
TO <- args[1]

for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()

cat("== 配置 ==\n")
cat("   data_root :", cfg$data_root, "\n")
cat("   tz        :", cfg$tz, "\n")
ep <- dsapp_mail_endpoint(cfg)
cat("   endpoint  :", ep$url, "(", ep$use_ssl, ")\n")
cat("   from      :", cfg$mail$from, "\n")
cat("   ready     :", dsapp_mail_ready(cfg), "\n")
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")
if (!dsapp_mail_ready(cfg)) stop("这台机器没配 SMTP（DSAPP_SMTP_*）")

# ---- 造一份**带中文、带 Markdown 结构、带一张真图**的速递 -------------------
# 图是关键：它验的是 dsapp_html_inline() + data: 放行那一条链路 ——
# 也就是"收件人看到的图会不会裂"。用一张真 PNG，不用占位符。
td <- tempfile("lit"); dir.create(td, showWarnings = FALSE)
png_path <- file.path(td, "fig_测试图.png")
# 手写一张最小的合法 PNG（1x1 红点）—— 不引 png 包
png_raw <- as.raw(c(
  0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a, 0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
  0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, 0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,
  0xde, 0x00,0x00,0x00,0x0c,0x49,0x44,0x41, 0x54,0x08,0xd7,0x63,0xf8,0xcf,0xc0,
  0x00,0x00,0x03,0x01,0x01,0x00,0x18,0xdd, 0x8d,0xb0, 0x00,0x00,0x00,0x00,0x49,
  0x45,0x4e,0x44,0xae,0x42,0x60,0x82))
writeBin(png_raw, png_path)

md <- file.path(td, "文献速递.md")
writeLines(c(
  "# 文献速递 · 单细胞多组学（Test_V15.2 发信探针）",
  "",
  "> 这是一封**链路验证邮件**，不是真实的检索结果。",
  "",
  "## 本次检索条件",
  "",
  "| 项目 | 值 |",
  "|---|---|",
  "| 关键词 | 单细胞多组学、空间转录组 |",
  "| 精读 | 3 篇 |",
  "| 略读 | 5 篇 |",
  "",
  "## 精读",
  "",
  "### 1. 一个很长的中文标题，用来验证行宽不会把排版撑坏",
  "",
  "- **期刊**：Nature Methods（示例）",
  "- **年份**：2026",
  "- **链接**：<https://example.org/paper/1>",
  "",
  "下面这张图验的是**内联**那条路：收件人那边如果能看到一个红点，",
  "说明 `dsapp_html_inline()` + `data:` 放行是通的。",
  "",
  "![测试图](fig_测试图.png)",
  "",
  "## 略读",
  "",
  "1. 第二条示例文献",
  "2. 第三条示例文献",
  "",
  "---",
  "",
  "**结束。**",
  ""), md, useBytes = TRUE)

cat("\n== 渲染 ==\n")
r <- dsapp_mail_render(paste(readLines(md, warn = FALSE), collapse = "\n"), td)
cat("   内联图片 :", r$n, "张，", round(r$bytes / 1024, 1), "KB\n")
cat("   真丢的   :", r$skipped, "张（外链和本来就是 data: 的不算）\n")
cat("   data: 放行:", grepl("src=\"data:image/", r$html), "\n")
if (!grepl("src=\"data:image/", r$html)) {
  cat("   !! 图没内联上 —— 收件人会看到裂图\n")
}
cat("   <script> 转义:", !grepl("<script", r$html, fixed = TRUE), "\n")

cat("\n== 真发到", TO, "==\n")
res <- dsapp_mail_deliver(
  to = TO,
  subject = "【Test_V15.2】文献速递发信链路验证 · 中文主题",
  body_md = paste(readLines(md, warn = FALSE), collapse = "\n"),
  base_dir = td, attach_path = md, cfg = cfg)

cat("   ok  :", res$ok, "\n")
if (!res$ok) cat("   msg :", res$msg, "\n")
cat("\n（附件目录留着看：", td, "）\n")
quit(status = if (isTRUE(res$ok)) 0L else 1L)
