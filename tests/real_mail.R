#!/usr/bin/env Rscript
# =============================================================================
# 真邮件验收：用**真的** SMTP 把一封文献速递发出去
# =============================================================================
#
#     Rscript tests/real_mail.R <应用目录> [收件人]
#
# 和 tests/fake_smtp.py 那条路的分工：
#   * 假 SMTP 验的是**接线**——谁在什么时候入队、drain 有没有认领、MIME 拼得
#     对不对。它离线、免费、每次改动都该跑（tests/v152_scheduler.R 的 C 段）。
#   * 本文件验的是假服务器**验不到**的东西：真实 TLS 握手、真实的
#     AUTH LOGIN、收件方服务器认不认我们拼的报文、中文主题在真实收件箱里
#     是不是乱码、内联的 data: 图片在真实邮件客户端里显示不显示。
#     假服务器全程不对 base64 解码、也不做任何 MIME 校验 —— 它当然认。
#
# ⚠️ 所以这个文件**不能**进 selftest.R / deploy.sh --check：
#    它要联网、要真的往别人邮箱里投信、结果依赖外部服务器。
#    它是部署后手工跑一次的验收，不是回归测试。
#
# ⚠️ 凭据**只从应用目录的 .Renviron 读**（那正是应用自己读它的方式），
#    不落盘到别处、不进命令行参数 —— 命令行参数 `ps` 和 shell 历史都看得到。
#    这是用户定的规矩（见 .Renviron.example 顶部），别为了方便破了它。
#    本文件里也**不打印** dsapp_config()$mail 的任何一项。
#
# 输出走 stderr：stdout 重定向到文件时是块缓冲的，卡住时一个字都看不到，
# 而"卡住"恰恰是这里最要报出来的情况。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)
suppressMessages(library(shiny))

# ---- 凭据：**借读**，不复制 --------------------------------------------------
#
# 为什么是借读而不是把 SMTP 那几行拷进探针实例的 .Renviron：拷一份就是让
# 同一个密码在磁盘上多出一份副本，而副本不会跟着原文一起轮换 —— 半年后有人
# 改了密码，探针那份还在，而且没人知道它从哪来。所以这里反过来做：
#
#     DSAPP_MAIL_CREDS=<某份 .Renviron>  →  readRenviron() 把它读进来
#
# 于是密码始终只有**一个**落盘位置（生产那份 .Renviron），探针实例只是
# 临时把它读进内存。
#
# ⚠️ 顺序要紧：readRenviron() 会把那份文件里的**所有**键都写进环境，包括
#    DSAPP_DATA_ROOT —— 也就是会把探针实例**接回生产库**（不报错、界面上
#    也看不出任何异样，是 memory 里记过的那个坑）。所以先把探针自己的
#    data_root 存下来，读完再按回去。
creds <- Sys.getenv("DSAPP_MAIL_CREDS", "")
data_root_keep <- Sys.getenv("DSAPP_DATA_ROOT", "")
if (nzchar(creds)) {
  if (!file.exists(creds)) {
    cat(sprintf("DSAPP_MAIL_CREDS 指的文件不存在：%s\n", creds), file = stderr())
    quit(status = 2L)
  }
  readRenviron(creds)
  if (nzchar(data_root_keep)) Sys.setenv(DSAPP_DATA_ROOT = data_root_keep)
}

say <- function(...) cat(sprintf(...), "\n", file = stderr())
ok <- TRUE; nfail <- 0L
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) say("  \033[32m✓\033[0m %s %s", name, extra)
  else { ok <<- FALSE; nfail <<- nfail + 1L
         say("  \033[31m✗ %s\033[0m %s", name, extra) }
}

TO <- if (length(args) >= 2) args[[2]] else "user1@example.com"

for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()

# ---- 起手先确认这是**能发信**的一份配置 --------------------------------------
say("\n== 配置 ==")
if (!isTRUE(dsapp_mail_ready(cfg))) {
  say("这个应用目录没配齐 SMTP（HOST/USER/PASS/FROM 有一个是空的），跳过。")
  say("要跑这个验收，先在 .Renviron 里补齐 DSAPP_SMTP_*。")
  quit(status = 0L)
}
say("  SMTP 主机：%s", cfg$mail$host %||% "?")
say("  端口：%s（SSL=%s）", cfg$mail$port %||% "?", isTRUE(cfg$mail$ssl))
say("  发件人：%s", cfg$mail$from %||% "?")
say("  收件人：%s", TO)
say("  ⚠️ 密码不打印，任何情况下都不。")
say("  data_root：%s", cfg$data_root)
# ⚠️ 这一条是防呆：跑之前必须知道自己在往哪个库写。对着生产库跑会让
#    验收的痕迹留在生产库里（虽然无害，但"验收"和"线上"混在一起以后
#    就说不清了）。
if (grepl("^/tmp/", cfg$data_root)) say("  （data_root 在 /tmp，是临时实例）")

# ---- 语料：要么现造一份，要么用**一份真的** --------------------------------
#
# 两种模式，差别只在"正文从哪来"：
#
#   · 不给第三个参数 = 现造一份带图、带表、带原始 HTML 的合成速递。
#     它验的是**渲染那条链**：中文主题、相对路径的图、内联成 data: URI、
#     消毒、Markdown 原件当附件。发一封 "hello" 的话这些一个都走不到，
#     而它们恰恰是出过 bug 的地方（内联排在消毒之后 → 图全裂，见
#     R/render.R 里 `.dsapp_md_html_raw` 头上那段）。
#
#   · 给第三个参数 = 用那份**真实的**速递（形如
#     data/workspaces/<会话>/文献速递.md），而且**走界面那颗按钮用的函数**
#     （dsapp_lit_mail_queue）—— 收件地址从 users.email 现查，不手填。
#     它验的是另一件事：**用户真拿到手的东西发得出去、收得到**。
#     真速递通常没有图，所以依赖合成语料的那几条断言会跳过（见下面）。
MD_ARG <- if (length(args) >= 3) args[[3]] else ""

say(if (nzchar(MD_ARG)) "\n== 语料：一份真实的速递 ==" else "\n== 造一份速递 ==")
if (nzchar(MD_ARG)) {
  if (!file.exists(MD_ARG)) { say("  找不到 %s", MD_ARG); quit(status = 2L) }
  md_path <- normalizePath(MD_ARG)
  work    <- dirname(md_path)
  md      <- paste(readLines(md_path, warn = FALSE, encoding = "UTF-8"),
                   collapse = "\n")
  say("  %s", md_path)
  chk("速递读得出来而且不空", nzchar(trimws(md)),
      sprintf("(%s 字节)", format(file.info(md_path)$size, big.mark = ",")))
} else {
work <- file.path(cfg$data_root, "real_mail_probe")
dir.create(work, recursive = TRUE, showWarnings = FALSE)

png_path <- file.path(work, "volcano.png")
grDevices::png(png_path, width = 480, height = 320, bg = "white")
graphics::plot(1:20, (1:20) %% 7, type = "b", col = "#3b6ea5",
               main = "验收用图", xlab = "x", ylab = "y")
grDevices::dev.off()
chk("造图成功", file.exists(png_path) && file.info(png_path)$size > 1000,
    sprintf("(%d 字节)", file.info(png_path)$size))

md <- paste0(
  "# 文献速递（验收）\n\n",
  "这是一封**真实发送**的验收邮件，用来确认整条链路：中文主题、Markdown 渲染、",
  "本地图片内联、以及 Markdown 原件作为附件。\n\n",
  "## 精读\n\n",
  "1. **Single-cell atlas of something** — *Nature*, 2026\n",
  "   一句话结论：这一条是验收用的假数据，不是真的文献。\n\n",
  "2. **Another paper with a `code` span** — *Cell*, 2025\n\n",
  # ⚠️ 表格前面必须**空一行**，而且不能缩进。缩进三格的话 commonmark 会把它
  #    当成列表项 2 的续行 —— 表格塌成一段普通文字，`<table>` 一个都没有，
  #    而"渲染成功"照样为真。第一版就是这么写的，那条断言当场红了。
  "| 指标 | 值 |\n|---|---|\n| 细胞数 | 12,345 |\n| 基因数 | 2,000 |\n\n",
  "## 配图\n\n",
  "![火山图](volcano.png)\n\n",
  "图注：这张图走的是 `dsapp_html_inline()`，收件人应该**看得到图**，",
  "而不是一个裂开的图标。\n\n",
  "## 风险点自查\n\n",
  "- 原始 HTML 应该被转义：<script>alert(1)</script>\n",
  "- 下划线不该被吃成斜体：gene_name_1 与 gene_name_2\n")
md_path <- file.path(work, "文献速递.md")
writeLines(md, md_path, useBytes = TRUE)
chk("速递写好", file.exists(md_path), sprintf("(%d 字节)", file.info(md_path)$size))
}

# ---- 渲染这一步单独验一次 ----------------------------------------------------
# 不验的话，"发出去了但图是裂的"会以"收到了一封邮件"的形式**通过**。
# memory：selftest-green-is-not-coverage —— 发成功 ≠ 发对了。
say("\n== 渲染 ==")
# ⚠️ dsapp_mail_render() 返回的是 list(html=, n=, bytes=, skipped=, note=) ——
#    **没有 ok/msg**，它不抛错也不自我判定。（第一版这里按 ok/msg 写，
#    跑起来才发现；这个函数的 docstring 里"ok: TRUE"那句说的是
#    .dsapp_md_html_raw 那条老路，不是它的返回值。）
r <- dsapp_mail_render(md, base_dir = work)
chk("★ 有 HTML 正文", nzchar(r$html %||% ""))
# ⚠️ note 非空 = 有图**被丢掉**了（超上限/读不到）。那是"发出去了一封没有图的
#    报告"，收件人不会知道少了什么 —— 所以它必须是一条独立的断言。
#    ★ 这一条**两种语料都要跑**：真速递里要是有图而没内联上，正是它来报。
chk("★★ 没有图片被静默丢掉（note 必须是空的）",
    !nzchar(r$note %||% ""), r$note %||% "")
chk("★ 中文没被转成实体（收件人看到的该是汉字）",
    grepl("速递", r$html %||% "", fixed = TRUE))

# ⚠️ 下面这几条**只对合成语料成立** —— 它们验的是渲染器认不认那些构造，
#    而真速递里可能一张图、一个 <script>、一张表都没有。对着真速递跑这几条
#    会假红（"真速递里没有 <table>" 不是缺陷），所以按语料分开。
if (!nzchar(MD_ARG)) {
  chk("★★ 图片真的内联进去了（不是留下相对路径）", isTRUE(r$n >= 1L),
      sprintf("（%d 张，%s 字节）", r$n %||% 0L,
              format(r$bytes %||% 0, big.mark = ",")))
  chk("★★ 正文里没有残留的相对 src（那会是一张裂图）",
      !grepl('src="volcano.png"', r$html %||% "", fixed = TRUE))
  chk("★★ <script> 被转义了（commonmark 对原始 HTML 是原样放行的）",
      !grepl("<script", r$html %||% "", fixed = TRUE) &&
        grepl("&lt;script&gt;", r$html %||% "", fixed = TRUE))
  chk("★ 表格渲染成了 <table>", grepl("<table", r$html %||% "", fixed = TRUE))
} else {
  # 真速递里没有 <script> 才说明它干净；有的话**这一条会红，那是真的该红**
  # （用户的工作区文件里混进了原始 HTML）。
  chk("★★ 真速递的正文里没有未转义的 <script>",
      !grepl("<script", r$html %||% "", fixed = TRUE))
}

# ---- MIME 组装也看一眼（这一步离线就验过，这里用的是真内容） ----------------
say("\n== 报文 ==")
mime <- dsapp_mime_build(to = TO,
                         subject = sprintf("【言出法随】文献速递 · 验收 %s",
                                           format(Sys.time(), "%Y-%m-%d %H:%M")),
                         text = "这封邮件需要支持 HTML 的客户端才能正常显示。",
                         html = r$html, attach = list(list(path = md_path,
                                                           name = "文献速递.md")),
                         from = cfg$mail$from,
                         from_name = cfg$mail$from_name %||% "",
                         cfg = cfg)
chk("★ 中文主题做了 RFC 2047 编码", grepl("=?UTF-8?B?", mime, fixed = TRUE))
chk("★★ 报文里没有裸 LF（真实服务器对行尾是敏感的）",
    !grepl("(?<!\r)\n", mime, perl = TRUE))
chk("★ 附件在（Markdown 原件）", grepl("multipart/mixed", mime, fixed = TRUE))
chk("★★ 密码不在报文里（它只该出现在 SMTP 的 AUTH 那一行）",
    !grepl(cfg$mail$pass %||% "never", mime, fixed = TRUE))

# ---- 真的发出去 --------------------------------------------------------------
#
# ⚠️ 这里**同步**调用 drain，不走 dsapp_mail_kick()。验收要的是"到底发没发出去"
#    这个结论，起子进程的话得再轮询一遍队列，而失败原因还得回头翻日志。
#    drain 会认领 → 渲染 → send_mail → 改状态，最后一行状态就是答案。
say("\n== 发送 ==")
# ⚠️ `DSAPP_MAIL_DRY=1` → 验到"报文拼好了"为止，**不投递**。
#    调正文夹具的时候很需要它：改一个字就真发一封，收件箱会被淹掉，而
#    "这条路真的能发出去"这个事实只需要验一次。真投递那次的证据是收件箱。
if (nzchar(Sys.getenv("DSAPP_MAIL_DRY", ""))) {
  say("  （DSAPP_MAIL_DRY 已设：到此为止，不投递。）")
  say("   上面「渲染」「报文」两节就是全部结论；去掉这个变量再跑就是真发。")
  if (ok) say("\n\033[1m=== 干跑全过（没有发信）===\033[0m")
  quit(status = if (ok) 0L else 1L)
}
say("  ⚠️ 接下来这一步会**真的往 %s 投一封信**。", TO)
if (nzchar(MD_ARG)) {
  # ★ 和界面那颗「发到我的邮箱」按钮**同一个函数**。这不是洁癖：那个函数
  #   自己解析收件地址（users.email）、自己定 base_dir（图片是相对正文所在
  #   目录找的）、自己拼主题。这里另写一遍 enqueue 就等于验了一条**用户不会
  #   走的路**，而按钮那条路上的错（收件人查错、base_dir 传错）一条都测不到。
  v152_u <- dsapp_user_by_email(TO, con = dsapp_db(cfg))
  if (is.null(v152_u) || !length(v152_u$id)) {
    say("  这个库里没有邮箱为 %s 的账号。真速递那条路是按 users.email 发信的。",
        TO)
    quit(status = 2L)
  }
  say("  收件账号：id=%s（收件地址取自 users.email，不是命令行给的）",
      v152_u$id[1])
  q <- dsapp_lit_mail_queue(as.integer(v152_u$id[1]), md_path,
                            cfg = cfg, con = dsapp_db(cfg),
                            kind = "lit_manual", ref = "")
  chk("★ 入队成功（走的是 dsapp_lit_mail_queue，和按钮同一条路）",
      isTRUE(q$ok) && !is.na(q$id), q$msg %||% "")
  qid <- q$id
} else {
  qid <- dsapp_mail_enqueue(to = TO,
                            subject = sprintf("【言出法随】文献速递 · 验收 %s",
                                              format(Sys.time(), "%Y-%m-%d %H:%M")),
                            body_md = paste(readLines(md_path, warn = FALSE,
                                                      encoding = "UTF-8"),
                                            collapse = "\n"),
                            base_dir = work,
                            attach_path = md_path,
                            kind = "test", ref = "",
                            user_id = NULL, cfg = cfg)
  chk("入队成功", !is.na(qid), sprintf("(id=%s)", qid))
}
if (is.na(qid %||% NA_integer_)) { say("  没入队，后面不用发了。"); quit(status = 1L) }

t0 <- Sys.time()
res <- tryCatch(dsapp_mail_drain(cfg, max = 3L),
                error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
dt <- as.numeric(Sys.time() - t0, units = "secs")
say("  drain 用了 %.1f 秒，返回：%s", dt,
    paste(utils::capture.output(str(res)), collapse = " "))

row <- DBI::dbGetQuery(dsapp_db(cfg),
                       "SELECT status, tries, last_error, sent_at, subject
                          FROM mail_queue WHERE id = ?",
                       params = list(as.integer(qid)))
st <- as.character(row$status[1] %||% "")
# 把队列里那封信的主题也报出来 —— 收件人看到的**就是**它，而不是上面
# MIME 那一节自己拼的那个。两者不一致的话（真跑过一次）这里看得出来。
say("  队列里的主题：%s", as.character(row$subject[1] %||% "（读不到）"))
chk("★★ 队列里那条是 sent", identical(st, "sent"),
    sprintf("(status=%s tries=%s)", st, row$tries[1] %||% "?"))
if (!identical(st, "sent")) {
  say("  \033[31m投递失败原因：%s\033[0m",
      substr(as.character(row$last_error[1] %||% "（空）"), 1L, 400L))
  # ⚠️ 常见原因按经验排一下，省得每次都要重新推：
  say("  排查顺序：")
  say("   1) 端口对不对（465 走 smtps，587 要写 smtp://）")
  say("   2) 客户端专用密码是不是又被重置了（企业微信后台一改就失效）")
  say("   3) 这台机器能不能出网：curl -v telnet://%s:%s",
      cfg$mail$host %||% "?", cfg$mail$port %||% "?")
  say("   4) 发件人地址必须和 SMTP 账号是同一个（企业微信邮箱要求）")
}

# ---- 收尾 --------------------------------------------------------------------
say("")
if (ok) {
  say("\033[1m=== 真邮件验收通过：信已经投给 %s ===\033[0m", TO)
  say("⚠️ 最后一步是**人**的活：打开收件箱确认三件事 ——")
  say("   · 主题里的中文不乱码")
  say("   · 正文里的那张「火山图」显示出来了（不是裂图）")
  say("   · 附件「文献速递.md」能下载、能打开")
  say("   （没在收件箱里就翻一下垃圾邮件 —— 新发件人第一次投递常被拦。）")
} else {
  say("\033[1m=== 有 %d 项没过 ===\033[0m", nfail)
}
quit(status = if (ok) 0L else 1L)
