#!/usr/bin/env Rscript
# Test_V15.2 的冒烟测试：把 MIME 组装和 next_at 这两块纯逻辑先跑通。
# 正式断言在 selftest.R 的 V15.2 一节里，这份是开发期快速反馈用的。
#
#   cd /tmp/dsapp_v152/app && Rscript tests/v152_smoke.R

for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-14s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}

# ---- MIME：无附件（multipart/alternative）-----------------------------------
m <- dsapp_mime_build(to = "a@b.com", subject = "文献速递 2026-09-28",
                      text = "hello 正文", html = "<h1>你好</h1>",
                      from = "bot@x.com", from_name = "言出法随",
                      boundary = "BND1", date = "Mon, 28 Sep 2026 08:00:00 +0800",
                      msgid = "<t@x>", cfg = cfg)
cat("=== 头部 ===\n")
cat(paste(head(strsplit(m, "\r\n")[[1]], 7), collapse = "\n"), "\n\n")

say("CRLF 纯净", !grepl("[^\r]\n", m))
say("alternative", grepl('multipart/alternative; boundary="BND1"', m))
say("boundary 配对", length(gregexpr("--BND1", m, fixed = TRUE)[[1]]) == 3L,
    "（2 个开 + 1 个收）")
say("subject 编码", grepl("Subject: =\\?UTF-8\\?B\\?", m))
say("From 显示名", grepl("From: =\\?UTF-8\\?B\\?", m))
say("收尾 --", grepl("--BND1--\r\n$", m))

# ---- MIME：带附件（multipart/mixed）-----------------------------------------
# ⚠️ 附件内容要**够长**：base64 折行是 76 列，内容太短就一行到底，
#    下面那条 "base64 <=76" 断言会变成**空跑**（`all(numeric(0))` 恒 TRUE）
#    却显示 OK —— 正是 selftest-green-is-not-coverage 那种假绿。
tf <- tempfile(fileext = ".md")
writeLines(paste(rep("文献速递正文内容", 40L), collapse = ""), tf)
m2 <- dsapp_mime_build(to = "a@b.com", subject = "t", html = "<p>x</p>",
                       attach = list(list(path = tf, name = "文献速递.md")),
                       from = "bot@x.com", boundary = "BND2", cfg = cfg)
say("mixed 外壳", grepl('multipart/mixed; boundary="BND2"', m2))
say("mixed 收尾", grepl("--BND2--\r\n$", m2))
say("RFC2231 名", grepl("filename\\*=UTF-8''", m2))
say("附件 base64", grepl("Content-Transfer-Encoding: base64", m2))

# base64 每行不超 76
lines <- strsplit(m2, "\r\n")[[1]]
b64lines <- lines[grepl("^[A-Za-z0-9+/=]{40,}$", lines)]
say("base64 有折行", length(b64lines) >= 2L,
    sprintf("（%d 行，最长 %d）", length(b64lines),
            if (length(b64lines)) max(nchar(b64lines)) else 0L))
say("base64 <=76", all(nchar(b64lines) <= 76L))

# ---- 附件不存在时不许拼进去 ------------------------------------------------
m3 <- dsapp_mime_build(to = "a@b.com", subject = "t", html = "<p>x</p>",
                       attach = list(list(path = "/no/such/file.md")),
                       from = "bot@x.com", boundary = "BND3", cfg = cfg)
say("坏附件跳过", !grepl("multipart/mixed", m3))

# ---- next_at -----------------------------------------------------------------
tz <- "Asia/Shanghai"
f <- as.POSIXct("2026-09-28 09:30:00", tz = tz)      # 周一
cat("\n=== next_at ===\n")
say("daily", identical(dsapp_lit_next_at("daily", from = f, hour = 8, tz = tz),
                       "2026-09-29 08:00:00"))
say("weekly 周一", identical(dsapp_lit_next_at("weekly", weekday = 1L, from = f,
                                               hour = 8, tz = tz),
                             "2026-10-05 08:00:00"))
say("weekly 周三", identical(dsapp_lit_next_at("weekly", weekday = 3L, from = f,
                                               hour = 8, tz = tz),
                             "2026-09-30 08:00:00"))
say("当天未到点", identical(dsapp_lit_next_at("daily", from = f, hour = 12, tz = tz),
                            "2026-09-28 12:00:00"))
# ★ 最关键的一条：恰好等于时必须跳到**下一个**
ex <- as.POSIXct("2026-09-29 08:00:00", tz = tz)
say("恰好等于→次日",
    identical(dsapp_lit_next_at("daily", from = ex, hour = 8, tz = tz),
              "2026-09-30 08:00:00"))
# 月末顺延
say("31号→2月末",
    identical(dsapp_lit_next_at("monthly", day_of_month = 31L,
                                from = as.POSIXct("2027-01-31 09:00:00", tz = tz),
                                hour = 8, tz = tz), "2027-02-28 08:00:00"))
say("跨年",
    identical(dsapp_lit_next_at("monthly", day_of_month = 5L,
                                from = as.POSIXct("2026-12-20 09:00:00", tz = tz),
                                hour = 8, tz = tz), "2027-01-05 08:00:00"))

# ---- ★ 图片内联：顺序不能反（V15.2 真踩过的坑）-------------------------------
cat("\n=== 图片内联 ===\n")
td <- tempfile("smoke"); dir.create(td, showWarnings = FALSE)
# 手写一张最小的合法 PNG（1x1 红点）
writeBin(as.raw(c(
  0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a, 0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
  0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, 0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,
  0xde, 0x00,0x00,0x00,0x0c,0x49,0x44,0x41, 0x54,0x08,0xd7,0x63,0xf8,0xcf,0xc0,
  0x00,0x00,0x03,0x01,0x01,0x00,0x18,0xdd, 0x8d,0xb0, 0x00,0x00,0x00,0x00,0x49,
  0x45,0x4e,0x44,0xae,0x42,0x60,0x82)), file.path(td, "fig_测试图.png"))
rh <- dsapp_mail_render("段落。\n\n![测试图](fig_测试图.png)\n", td)$html
say("相对图内联上了", grepl('src="data:image/png;base64,', rh))
# ⚠️ V14 修过的老 bug：src 之后的属性被吃掉（连 `>` 都没了）。别删这条。
say("src 后属性还在", grepl('alt="测试图"', rh) && grepl("/>$", sub(".*(<img[^>]*>).*", "\\1", rh)))
say("没丢计数", dsapp_mail_render("![没有](nope.png)\n", td)$skipped == 1L)
say("网页路不内联", !grepl("data:image", dsapp_md_html("![x](fig_测试图.png)"), fixed = TRUE))

# ---- 关键词分割（搬过来之后还对不对）----------------------------------------
cat("\n=== 关键词 ===\n")
say("顿号/逗号", identical(dsapp_lit_keywords("a、b，c;d\ne"), c("a","b","c","d","e")))
say("不按空格切", identical(dsapp_lit_keywords("single cell RNA"), "single cell RNA"))

cat("\n", if (ok) "=== 冒烟全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
