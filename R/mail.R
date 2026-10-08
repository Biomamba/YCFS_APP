# =============================================================================
# 邮件通道（Test_V15.2 item 1）
# =============================================================================
#
# 用户原话：
#   「企业微信邮箱是 biomamba@biomamba.com.cn，请帮我把文献速递的内容
#     以邮件的形式发送给用户」
#   「开启后能把任务运行成功完成/失败的信息发送到用户的邮箱」
#
# 这份文件只做三件事：**拼 MIME**、**排队**、**发**。谁来发信（文献速递页、
# 任务收尾、定时订阅）是别人的事，它们一律只调 dsapp_mail_enqueue()。
#
# ---- 1. 为什么是 curl::send_mail，不引新包 ---------------------------------
#
# `curl` 是 R 自带的，libcurl 编译时就带 smtp/smtps。2026-09-28 在本机实测过
# （smtps://smtp.exmail.qq.com:465 + username/password 握手成功、服务器应答
# AUTH），链路是通的。
#
# 这台机器上确实装了 mailR / sendmailR，但**它们不在任何一份依赖清单里** ——
# 换句话说 Windows 包和别的部署机器上都没有。用它们 = 多一处"本机能跑、
# 换个地方就起不来"，而且那两家的 MIME 组装是黑盒，自检碰不到。
#
# ---- 2. 为什么 MIME 是自己拼的（而不是找个包）------------------------------
#
# 因为**拼 MIME 是这条链路上唯一能离线测的部分**。
#
# selftest.R 的铁律是从不联网（见它顶部）。发信那一步必然联网、必然进不了
# 自检；但如果报文组装是一个**纯函数**（dsapp_mime_build() → 一个字符串），
# 自检就能逐字节断言：中文主题有没有编成 RFC 2047、boundary 配不配对、
# base64 有没有按 76 列折行、是不是全程 CRLF。剩下真正联网的那一步薄到
# 只剩一次 send_mail 调用 —— 出错的面自然就小。
#
# ---- 3. 为什么要有 mail_queue 这张表，而不是直接发 -------------------------
#
# 因为**定时订阅发信的时候，没有任何页面是开着的**。
#
# 界面上点「发到我的邮箱」，失败了可以弹个红条告诉用户；定时任务在凌晨八点
# 失败了，没有人在看 —— 那一封就**永久消失了**，而且没有任何痕迹。所以：
#
#   入队（一次 INSERT，微秒级） → dsapp_mail_kick() 起子进程排空
#
# 队列落库不落内存，换来三件事：失败可重试（最多 DSAPP_MAIL_MAX_TRIES 次）、
# 失败看得见（界面上有「上次发信失败：<原因>」）、进程重启不丢。
#
# ⚠️ **绝不在主进程里同步发信。** 一次 SMTP 是 握手 + TLS + 传 base64 图片，
#    秒级起步。Shiny Server 开源版**一个应用只有一个 R 进程**，在里头同步发
#    就等于让所有用户一起等 —— 和 R/jobs.R / R/llm.R 顶部否决长活是同一个
#    理由。发信一律走 dsapp_bg_start()。
#
# ---- 4. 凭据放 .Renviron，明文（这个边界要说清楚）--------------------------
#
# 与 DSAPP_CONDA_BIN 同级，都是"这台机器的平台级配置"。
#
# ⚠️ **如实说明它保护到什么程度**：.Renviron 必须能被 shiny 用户读到
#    （DSAPP_DATA_ROOT 就是这么读的），所以这个密码对应用进程是可读的。
#    这和"应用自己需要它"是同一个信任级别。
#    R/crypto.R 的钥匙串（data_root/.keyring）也在同一个边界里 ——
#    加密只是防"库文件被单独拷走"；.Renviron 既不备份也不同步，
#    加密它没有额外收益，只会多一处能坏的地方。
#
# ---- 5. 密码不许出现在任何能被人看到的地方 ---------------------------------
#
# 日志、通知、异常消息、审计 detail —— 一处都不行。这条在自检里有哨兵盯着，
# 见 selftest 的 V15.2 一节。
# =============================================================================

# 一条最多试几次。超过就置 failed，不再自动重试（留在库里给人看）。
DSAPP_MAIL_MAX_TRIES <- 3L

# 正文内联图片的总字节上限。超了就把图片丢掉、在正文里说明一句 ——
# **不要**因为图太大就整封发不出去。企业微信邮箱单封上限是几十 MB，
# 但真正的问题是收件方（163、QQ）对超大正文会直接判垃圾邮件。
DSAPP_MAIL_INLINE_MAX <- 5 * 1024^2

# 附件上限。文献速递的 .md 正常就几十 KB，这个数是防呆，不是配额。
DSAPP_MAIL_ATTACH_MAX <- 20 * 1024^2

# 主题最长多少字符（编码前）。太长的主题在收件方列表里会被截，
# 而且 RFC 2047 折行之后有些客户端解不回来。
DSAPP_MAIL_SUBJECT_MAX <- 180L

# src 放宽到允许内联图片时，认哪些 MIME。
# ⚠️ **故意不含 image/svg+xml**：SVG 里可以塞 <script>，而邮件客户端对
#    data: URI 里的 SVG 处理得不一致。只放行位图，没有例外。
DSAPP_MAIL_DATA_SRC_RE <- "^data:image/(png|jpe?g|gif|webp|bmp)"

# ---- 建表 -------------------------------------------------------------------

#' mail_queue 的表结构（由 R/db.R 的 dsapp_db_schema 调用）
#'
#' 和 agent_runs 一样是**旁挂表**：不改任何现有表，所以只加一个 schema 函数、
#' 把 DSAPP_SCHEMA_VERSION 加一就够。
dsapp_db_schema_mail <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS mail_queue (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id     INTEGER,
      to_email    TEXT NOT NULL,
      subject     TEXT NOT NULL,
      body_md     TEXT NOT NULL DEFAULT '',
      base_dir    TEXT NOT NULL DEFAULT '',
      attach_path TEXT,
      kind        TEXT NOT NULL DEFAULT 'manual',
      ref         TEXT NOT NULL DEFAULT '',
      status      TEXT NOT NULL DEFAULT 'pending',
      tries       INTEGER NOT NULL DEFAULT 0,
      last_error  TEXT NOT NULL DEFAULT '',
      created_at  TEXT NOT NULL,
      sent_at     TEXT
    )")

  # ★ 去重靠这一条。ref 是调用方给的稳定键（任务通知是 'task:<tid>'，
  #   订阅是 'lit:<sub_id>:<yyyymmddHHMM>'）。
  #
  # ⚠️ **部分索引**（WHERE ref <> ''）不能省：手动发信那种没有天然键的，
  #    ref 留空串；不排除掉的话第二封手动邮件就会被唯一索引挡下来 ——
  #    症状是"点了发送，界面说成功，邮箱里什么都没有"，而且只在发第二封
  #    的时候出现。
  #
  # ⚠️ 但**去重是"尽力而为"，不是"绝不会重"**：`INSERT OR IGNORE` 挡的是
  #    唯一索引冲突，挡不住"两个进程同时读到 pending 再各自发一次"。
  #    那一道由 dsapp_mail_claim() 的原子 UPDATE 兜（见那个函数）。
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_mailq_ref
       ON mail_queue(ref) WHERE ref <> ''")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_mailq_status ON mail_queue(status)")
  invisible(TRUE)
}

# ---- 配置 -------------------------------------------------------------------

#' 这台机器配没配好发信
#'
#' ★ **故意没有 DSAPP_MAIL_ENABLED 这个开关**，用"配没配齐"代替。
#'
#' 多一个开关就多一种"开关开着但没配 host"的半成品状态：界面显示得出来、
#' 点下去报错，而管理员以为自己配好了。四个必填项（host / user / pass /
#' from）任何一个空着就是没配 —— 没配的效果是**界面整个不出现**，
#' 不是"出现一个点了就坏的按钮"。
#'
#' Windows 便携包和用户自托管部署天生没有这几项，于是它们自动看不到邮件功能，
#' 不需要任何人去关它。
dsapp_mail_ready <- function(cfg = dsapp_config()) {
  m <- cfg$mail %||% list()
  all(nzchar(c(
    as.character(m$host %||% "")[1],
    as.character(m$user %||% "")[1],
    as.character(m$pass %||% "")[1],
    as.character(m$from %||% "")[1]
  )))
}

#' 拼出 send_mail 要的那几个连接参数
#'
#' ⚠️ `curl::send_mail` 只在 server 串以 `:465` 结尾时才自动补 `smtps://`
#'    前缀，别的端口一律按明文 `smtp://` 处理。所以这里**显式给完整 URL**，
#'    把 ssl 档位一起定下来，不依赖它那条规则。
dsapp_mail_endpoint <- function(cfg = dsapp_config()) {
  m <- cfg$mail %||% list()
  host <- as.character(m$host %||% "")[1]
  port <- suppressWarnings(as.integer(m$port %||% 465L))
  if (is.na(port) || port < 1L || port > 65535L) port <- 465L
  # 465 是隐式 TLS（SMTPS），587 是 STARTTLS，其余默认不加密。
  # DSAPP_SMTP_SSL 可以强行覆盖 —— 自检/假服务器要用 "no"。
  ssl <- tolower(trimws(as.character(m$ssl %||% "auto")[1]))
  if (!ssl %in% c("auto", "force", "try", "no")) ssl <- "auto"
  if (identical(ssl, "auto")) {
    ssl <- if (port == 465L) "force" else if (port == 587L) "try" else "no"
  }
  scheme <- if (identical(ssl, "no")) "smtp" else "smtps"
  list(url = sprintf("%s://%s:%d", scheme, host, port), use_ssl = ssl,
       port = port, host = host)
}

# ---- MIME 组装（纯函数 —— 自检的主战场）-------------------------------------

#' RFC 2047 编码一个头部字段的值
#'
#' 纯 ASCII 原样返回。非 ASCII 编成 `=?UTF-8?B?<base64>?=`，
#' **按 UTF-8 字符边界**切块，每块编完不超过 75 字符（RFC 2047 的硬限制）。
#'
#' ⚠️ 切块**必须在字符边界上**：把一个三字节的汉字劈成两半，得到的 base64
#'    解出来是乱码。所以这里先按字符拆（`strsplit(x, "")`），
#'    累计字节数，而不是按固定字节数切。
#'
#' ⚠️ 块与块之间用 `CRLF + 空格` 折行 —— 这是 RFC 2047 规定的续接方式，
#'    解码方会把它们拼回去。**用空格直接连会被解成两个独立的词**，
#'    中间多出一个空格，中文主题里就多一个空格。
dsapp_mail_rfc2047 <- function(x) {
  x <- as.character(x %||% "")[1]
  if (is.na(x) || !nzchar(x)) return("")

  # 有控制字符就一定要编码（裸的控制字符在头部里是非法的）；
  # 全 ASCII 且干净的原样返回 —— 纯英文主题编成 =?UTF-8?B?...?= 虽然合法，
  # 但有些老客户端会把编码词当字面量显示出来。
  if (!grepl("[^\x20-\x7E]", x, perl = TRUE)) return(x)

  # 每块最多 45 字节：45 字节 base64 是 60 字符，加 "=?UTF-8?B?" (10)
  # 和 "?=" (2) 一共 72 < 75。
  CHUNK <- 45L
  chars <- strsplit(enc2utf8(x), "", fixed = TRUE)[[1]]
  sizes <- nchar(chars, type = "bytes")

  words <- character(0)
  buf <- character(0); used <- 0L
  flush <- function() {
    if (!length(buf)) return(invisible(NULL))
    b64 <- openssl::base64_encode(charToRaw(paste0(buf, collapse = "")))
    b64 <- gsub("[^A-Za-z0-9+/=]", "", b64)
    words[[length(words) + 1L]] <<- paste0("=?UTF-8?B?", b64, "?=")
    buf <<- character(0); used <<- 0L
    invisible(NULL)
  }
  for (i in seq_along(chars)) {
    # 单个字符本身就超一块（不会发生在 UTF-8 里，但别让它死循环）
    if (used + sizes[i] > CHUNK && used > 0L) flush()
    buf <- c(buf, chars[i]); used <- used + sizes[i]
  }
  flush()

  # useBytes 的 paste 会在块之间插 CRLF + 空格
  paste(words, collapse = "\r\n ")
}

#' base64 按 76 列折行（RFC 2045）
#'
#' ⚠️ 先**去掉**输入里已有的换行再自己折：`openssl::base64_encode` 对 raw
#'    输入（openssl 2.x 实测）不带换行，但真带上换行的话，两种换行混在一起
#'    （它给 `\n`、MIME 要 `\r\n`）解码方会照样吃下去 —— 直到某个较真的
#'    客户端把整个附件解坏。一行 sub 换掉，比赌对方的实现便宜。
dsapp_mail_b64wrap <- function(b64, width = 76L) {
  b64 <- gsub("[^A-Za-z0-9+/=]", "", as.character(b64 %||% "")[1])
  n <- nchar(b64)
  if (is.na(n) || n == 0L) return("")
  if (n <= width) return(b64)
  starts <- seq.int(1L, n, by = width)
  paste(substring(b64, starts, pmin(starts + width - 1L, n)), collapse = "\r\n")
}

#' RFC 2822 的 Date 头
#'
#' ⚠️ **不能用 `format(Sys.time(), "%a, %d %b %Y ...")`**：`%a` / `%b` 是
#'    **跟着 locale 走的**。这台机器的 LC_TIME 是中文时，出来的就是
#'    「周日, 28 9月 2026」这种，头部直接不合法，收件方会当成垃圾邮件
#'    或者把时间解析成 1970。所以日/月名自己写死。
dsapp_mail_date <- function(t = Sys.time(), tz = NULL) {
  lt <- as.POSIXlt(t, tz = tz %||% "")
  wd <- c("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[lt$wday + 1L]
  mo <- c("Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")[lt$mon + 1L]
  off <- format(t, "%z", tz = tz %||% "")
  if (!nzchar(off) || is.na(off)) off <- "+0000"
  # ⚠️ 一律 as.integer()：`as.POSIXlt()$sec` 是 **double**（秒可以带小数），
  #    而 `%02d` 只吃 integer —— 不给它转的话 sprintf 直接抛
  #    "invalid format '%02d'"，而那个报错发生在拼 Date 头的时候，
  #    看起来像是日期算错了，其实是类型。实测踩过一次。
  sprintf("%s, %02d %s %04d %02d:%02d:%02d %s",
          wd, as.integer(lt$mday), mo, as.integer(lt$year) + 1900L,
          as.integer(lt$hour), as.integer(lt$min), as.integer(lt$sec), off)
}

#' Message-ID
#'
#' 只要求**全局唯一**，不要求能被回信路由到。域名部分用本机节点名，
#' 拿不到就用 dsapp.invalid（RFC 2606 保留域名，永远不会撞上真的域）。
dsapp_mail_msgid <- function(cfg = dsapp_config()) {
  host <- tryCatch(as.character(Sys.info()[["nodename"]] %||% ""),
                   error = function(e) "")
  host <- gsub("[^A-Za-z0-9.-]", "", host)
  if (!nzchar(host)) host <- "dsapp.invalid"
  sprintf("<%s@%s>", dsapp_id("m"), host)
}

#' 生成一个 MIME boundary
#'
#' ⚠️ 唯一性来自"时间戳 + 进程号 + 自增计数"，**不靠随机数** ——
#'    用 `sample()` / `runif()` 会动全局 RNG 状态，而 selftest 里后面还有
#'    别的断言可能依赖随机序列；跑一次自检就把它们的结果改了，
#'    而且顺序一变结果就变。这种事排查起来毫无线索。
#'    （`dsapp_id()` 自己用了 sample.int，那是既有约定，这里不跟着加。）
#'
#' 自检要断言 boundary 配对，所以它必须能被**注入**：调用方传 boundary 参数，
#' 传了就用传进来的。
dsapp_mail_boundary <- function(tag = "mix") {
  n <- (getOption("dsapp.mail.boundary_n", 0L) %||% 0L) + 1L
  options(dsapp.mail.boundary_n = n)
  sprintf("=_dsapp_%s_%s_%d_%d", tag, format(Sys.time(), "%Y%m%d%H%M%S"),
          Sys.getpid(), n)
}

#' 组装一封完整的 MIME 报文（**纯函数，不联网、不读库**）
#'
#' @param to        收件人地址
#' @param subject   主题（非 ASCII 自动 RFC 2047）
#' @param text      纯文本正文（NULL / 空则不放这一段）
#' @param html      HTML 正文（同上）
#' @param attach    list(path=, name=NULL, mime=NULL) 或它们的 list；附件
#' @param from      发件地址
#' @param from_name 发件显示名（非 ASCII 自动编码）
#' @param boundary  注入用；两个 boundary 分别是 mixed / alternative
#' @param date      Date 头的内容（注入用，默认现在）
#'
#' @return character(1)：整封报文的原始字节，**行尾一律 CRLF**。
#'
#' ⚠️ 返回值整条自带 `\r\n`，按**长度 1 的字符向量**交给 curl::send_mail。
#'    它对字符输入做的是 `paste(message, collapse = "\r\n")` —— 既不改行尾
#'    也不补尾部的 CRLF。分成多行传进去的话每行之间会被再插一次 CRLF，
#'    但那**只是碰巧对**；一条完整的字符串才是这里真正想要的形状。
dsapp_mime_build <- function(to, subject, text = NULL, html = NULL,
                             attach = NULL, from,
                             from_name = "", boundary = NULL,
                             date = NULL, msgid = NULL,
                             cfg = dsapp_config()) {
  to   <- as.character(to %||% "")[1]
  from <- as.character(from %||% "")[1]
  if (!nzchar(to))   stop("收件人为空")
  if (!nzchar(from)) stop("发件人为空")

  subject <- substr(as.character(subject %||% "")[1], 1L,
                    DSAPP_MAIL_SUBJECT_MAX)

  # -- 头部公共部分 --
  from_hdr <- if (nzchar(from_name)) {
    sprintf("%s <%s>", dsapp_mail_rfc2047(from_name), from)
  } else from

  hdr <- c(
    sprintf("From: %s", from_hdr),
    sprintf("To: %s", to),
    sprintf("Subject: %s", dsapp_mail_rfc2047(subject)),
    sprintf("Date: %s", date %||% dsapp_mail_date()),
    sprintf("Message-ID: %s", msgid %||% dsapp_mail_msgid(cfg)),
    "MIME-Version: 1.0"
  )

  # -- 正文：text/plain + text/html 合成 multipart/alternative --
  has_text <- !is.null(text) && nzchar(paste(text, collapse = ""))
  has_html <- !is.null(html) && nzchar(paste(html, collapse = ""))

  body_part <- NULL
  if (has_text && has_html) {
    b_alt <- boundary %||% dsapp_mail_boundary("alt")
    # ⚠️ 顺序有讲究：RFC 2046 说 alternative 里**越靠后越"富"**，
    #    客户端从后往前挑第一个它能显示的。放反了的话纯文本客户端没问题，
    #    但有些客户端会挑中 text/plain，用户看到的是没渲染的 Markdown 源码。
    body_part <- paste0(
      "Content-Type: multipart/alternative; boundary=\"", b_alt, "\"\r\n",
      "\r\n",
      "--", b_alt, "\r\n",
      "Content-Type: text/plain; charset=UTF-8\r\n",
      "Content-Transfer-Encoding: base64\r\n",
      "\r\n",
      dsapp_mail_b64wrap(openssl::base64_encode(
        charToRaw(paste0(paste(text, collapse = "\n"), "\n")))),
      "\r\n",
      "\r\n",
      "--", b_alt, "\r\n",
      "Content-Type: text/html; charset=UTF-8\r\n",
      "Content-Transfer-Encoding: base64\r\n",
      "\r\n",
      dsapp_mail_b64wrap(openssl::base64_encode(
        charToRaw(paste0(paste(html, collapse = "\n"), "\n")))),
      "\r\n",
      "\r\n",
      "--", b_alt, "--\r\n")
  } else if (has_html) {
    body_part <- paste0(
      "Content-Type: text/html; charset=UTF-8\r\n",
      "Content-Transfer-Encoding: base64\r\n",
      "\r\n",
      dsapp_mail_b64wrap(openssl::base64_encode(
        charToRaw(paste0(paste(html, collapse = "\n"), "\n")))),
      "\r\n")
  } else if (has_text) {
    body_part <- paste0(
      "Content-Type: text/plain; charset=UTF-8\r\n",
      "Content-Transfer-Encoding: base64\r\n",
      "\r\n",
      dsapp_mail_b64wrap(openssl::base64_encode(
        charToRaw(paste0(paste(text, collapse = "\n"), "\n")))),
      "\r\n")
  } else {
    # 一封信总得有点东西。空的 multipart 有些客户端会当损坏。
    body_part <- paste0(
      "Content-Type: text/plain; charset=UTF-8\r\n",
      "Content-Transfer-Encoding: 8bit\r\n",
      "\r\n",
      "（无正文）\r\n")
  }

  # -- 附件：文件不存在就**跳过**，不要拼一个读不出来的附件进去 --
  atts <- list()
  if (!is.null(attach)) {
    if (is.list(attach) && !is.null(attach$path)) atts <- list(attach) else atts <- attach
    atts <- Filter(function(a) {
      p <- a$path %||% ""
      nzchar(p) && file.exists(p) && !isTRUE(file.info(p)$isdir) &&
        !is.na(suppressWarnings(file.size(p))) &&
        file.size(p) > 0 && file.size(p) <= DSAPP_MAIL_ATTACH_MAX
    }, atts)
  }

  mime_of <- function(p) {
    m <- tryCatch(dsapp_preview_mime(basename(p)), error = function(e) "")
    if (!nzchar(m %||% "")) "application/octet-stream" else m
  }

  # -- 拼装 --
  if (!length(atts)) {
    # 没有附件：alternative 那一段就是整封信的正文，不需要外面再套一层。
    return(paste0(paste(hdr, collapse = "\r\n"), "\r\n",
                  body_part))
  }

  b_mix <- boundary %||% dsapp_mail_boundary("mix")
  parts <- character(0)
  parts <- c(parts,
    paste0("--", b_mix, "\r\n", body_part))

  for (a in atts) {
    p    <- a$path
    name <- a$name %||% basename(p)
    sz   <- file.size(p)
    b64  <- tryCatch(
      dsapp_mail_b64wrap(openssl::base64_encode(readBin(p, "raw", n = sz))),
      error = function(e) NULL)
    if (is.null(b64) || !nzchar(b64)) next
    # ⚠️ filename 走 RFC 2231（filename*=UTF-8''<percent-encoded>）。
    #    中文文件名用旧的 `filename="文献速递.md"` 会被不认 UTF-8 的客户端
    #    显示成乱码或直接丢掉附件；RFC 2231 是 1997 年就有的标准写法，
    #    现代客户端都认。**两个都给**：只给 filename* 的话老客户端连名字
    #    都拿不到。
    ascii_name <- gsub("[^A-Za-z0-9._-]", "_", name)
    enc_name <- tryCatch(
      paste0("UTF-8''", URLencode(name, reserved = TRUE)),
      error = function(e) paste0("UTF-8''", ascii_name))
    parts <- c(parts, paste0(
      "--", b_mix, "\r\n",
      "Content-Type: ", mime_of(p), "; name=\"", ascii_name, "\"\r\n",
      "Content-Transfer-Encoding: base64\r\n",
      "Content-Disposition: attachment; filename=\"", ascii_name,
      "\"; filename*=", enc_name, "\r\n",
      "\r\n",
      b64, "\r\n"))
  }
  parts <- c(parts, paste0("--", b_mix, "--\r\n"))

  paste0(paste(hdr, collapse = "\r\n"), "\r\n",
         "Content-Type: multipart/mixed; boundary=\"", b_mix, "\"\r\n",
         "\r\n",
         paste(parts, collapse = ""))
}

# ---- 正文渲染 ---------------------------------------------------------------

#' 把一段 Markdown 渲染成**能进邮件**的 HTML
#'
#' 和网页预览那条路的差别只有一处：**允许 data: 内联图片**。
#' 邮件客户端拿不到你工作区里的相对路径，不内联的话所有图都是裂的 ——
#' 而文献速递那种"11 个 <img> 全是本地文件"的产出正是主力场景。
#'
#' ⚠️⚠️ **三步的顺序不能动**，尤其"内联"必须在"消毒"**之前**：
#'
#'     .dsapp_md_html_raw()  →  dsapp_html_inline()  →  dsapp_sanitize_links()
#'        转义 + commonmark        换 data: URI            剥不合规的 src
#'
#'    反过来的话，`![图](fig.png)` 渲染出的**相对** src 会被消毒那一步换成
#'    空串（它只放行 `^https?://`），等内联跑起来时**根本没有 src 可换** ——
#'    而且全程不报错：HTML 合法、`ok: TRUE`、内联函数老实报"0 张"。
#'    实测踩过（2026-09-28）。详见 `R/render.R` 的 `.dsapp_md_html_raw()`。
#'
#'    ⚠️ 所以这里**不能**用 `dsapp_md_html(mail = TRUE)`：那个函数是
#'       "渲染 + 消毒"一次做完的，没有给内联留位置。
#'
#' @return list(html=, n=, bytes=, skipped=, note=)
#'   note 非空时要拼进正文告诉用户"有几张图没带上" —— 静默丢图是
#'   最坏的一种失败：用户以为发出去了，收件人看到的是一篇没有图的报告。
dsapp_mail_render <- function(body_md, base_dir = "",
                              max_inline = DSAPP_MAIL_INLINE_MAX) {
  txt <- paste(as.character(body_md %||% ""), collapse = "\n")
  if (!nzchar(trimws(txt))) {
    return(list(html = "", n = 0L, bytes = 0, skipped = 0L, note = ""))
  }
  # 统一换行：库里存进来的可能是 \r\n（Windows 上产生的文件）。
  txt <- gsub("\r\n", "\n", txt, fixed = TRUE)

  # ① 渲染（未消毒）
  html <- .dsapp_md_html_raw(txt)

  # ② 内联。⚠️ 这里出任何意外都退回①的结果继续走 —— 少几张图远好过整封发不出去。
  inl <- list(html = html, n = 0L, bytes = 0, skipped = 0L, miss = 0L)
  if (nzchar(base_dir) && dir.exists(base_dir)) {
    inl <- tryCatch(
      dsapp_html_inline(html, base_dir, max_total = max_inline),
      error = function(e) list(html = html, n = 0L, bytes = 0, skipped = 0L,
                               miss = 0L))
  }

  # ③ 消毒。★ 放在内联之后，并且放行 data:（邮件客户端拿不到相对路径）。
  #    这是全文件唯一允许 allow_data = TRUE 的地方。
  # ⚠️ Test_V15.4 item 5：消毒**之前**先过体积闸门。这一版起 `<img>` 会被放行
  #    （`dsapp_md_allow_img()`），于是"模型自己在正文里内联了一张几十 MB 的图"
  #    第一次成为可能 —— 那封信会被收件方直接判垃圾邮件。以前不用担心，
  #    是因为那时 `<img>` 根本渲染不出来。
  html <- dsapp_sanitize_links(
    dsapp_md_limit_data_imgs(inl$html, max_inline), allow_data = TRUE)

  note <- ""
  # ⚠️ 只认 miss，**不能**把 skipped 加进来。`dsapp_html_inline()` 是这么分的
  #    （见它的文档注释）：`skipped` = 外部地址 / 本来就是 data: 的，这些**正常**，
  #    收件人照样看得到；`miss` = 看着像本地文件但读不了或压根不在 —— 这才是
  #    "图丢了"。而"文件太大"走的也是 miss：`resolve()` 里读不了就返回 NULL，
  #    调用点按 `dsapp_html_ref_rel()` 判得出来它是个本地路径，于是记 miss。
  #    一开始把两个加起来，实测一封正文只有 1 张真丢的邮件会报"有 3 张图片
  #    没能带进"（另外两张一张是 https 外链、一张是被剥掉的 data:text/html）。
  lost <- as.integer(inl$miss %||% 0L)
  if (lost > 0L) {
    note <- sprintf(
      "（有 %d 张图片没能带进邮件：文件太大或已经不在工作区里。完整内容见附件。）",
      lost)
  }
  list(html = html, n = as.integer(inl$n %||% 0L),
       bytes = as.numeric(inl$bytes %||% 0),
       skipped = lost, note = note)
}

# ---- 发送 -------------------------------------------------------------------

#' 真正把一封信交给 SMTP（**这是全文件唯一联网的地方**）
#'
#' @return list(ok=TRUE) 或 list(ok=FALSE, msg="...")
#'
#' ⚠️ msg 里**绝不能带上 cfg$mail**。`curl` 的错误消息本身只说服务器和
#'    "Login denied"，不带密码；但这里拼消息时手一滑写个
#'    `paste(conditionMessage(e), m$pass)` 就会把它写进日志和界面。
#'    自检有一条哨兵扫这个。
dsapp_mail_send_raw <- function(to, mime, cfg = dsapp_config()) {
  if (!dsapp_mail_ready(cfg)) {
    return(list(ok = FALSE, msg = "这台机器没有配置发信（DSAPP_SMTP_*）"))
  }
  if (!requireNamespace("curl", quietly = TRUE)) {
    return(list(ok = FALSE, msg = "没有 curl 包，发不了信"))
  }
  m  <- cfg$mail
  ep <- dsapp_mail_endpoint(cfg)

  args <- list(
    mail_from   = as.character(m$from)[1],
    mail_rcpt   = to,
    message     = mime,
    smtp_server = ep$url,
    use_ssl     = ep$use_ssl,
    # ⚠️ verbose = TRUE 会往 stderr 打 "Uploaded N bytes..."，而我们把这个
    #    stderr 收进了 logs/mail.err。默认值是 TRUE，必须显式关掉。
    verbose     = FALSE,
    connecttimeout = 15L,
    timeout        = 90L)

  # ⚠️ 只在非空时给凭据。给了空的 username，curl 会去试 AUTH 然后被拒 ——
  #    假 SMTP 服务器（自检用）根本不播 AUTH，那样就永远连不上。
  u <- as.character(m$user %||% "")[1]
  p <- as.character(m$pass %||% "")[1]
  if (nzchar(u)) args$username <- u
  if (nzchar(p)) args$password <- p

  tryCatch({
    do.call(curl::send_mail, args)
    list(ok = TRUE, msg = "")
  }, error = function(e) {
    list(ok = FALSE, msg = substr(conditionMessage(e), 1L, 300L))
  })
}

#' 渲染 + 组装 + 发送一条完整的信
#'
#' 给队列排空和"发测试邮件"共用。调用方拿到的是邮件**内容**，不是队列行。
dsapp_mail_deliver <- function(to, subject, body_md = "", base_dir = "",
                               attach_path = NULL,
                               cfg = dsapp_config()) {
  r <- dsapp_mail_render(body_md, base_dir)

  text_part <- if (nzchar(trimws(body_md))) {
    paste0(body_md, "\n")
  } else ""

  html_part <- r$html
  if (nzchar(r$note)) {
    # 提示拼在**正文最前面**而不是最后：文献速递动辄几千字，
    # 放末尾等于没有。
    html_part <- paste0("<p><em>", dsapp_escape(r$note), "</em></p>\n", html_part)
    text_part <- paste0(r$note, "\n\n", text_part)
  }

  att <- NULL
  if (!is.null(attach_path) && nzchar(attach_path %||% "") &&
      file.exists(attach_path)) {
    att <- list(list(path = attach_path))
  }

  mime <- dsapp_mime_build(
    to = to, subject = subject, text = text_part, html = html_part,
    attach = att,
    from = cfg$mail$from,
    from_name = cfg$mail$from_name %||% "",
    cfg = cfg)

  dsapp_mail_send_raw(to, mime, cfg)
}

# ---- 队列 -------------------------------------------------------------------

#' 入队一封信。**这是所有发信方唯一该调的入口。**
#'
#' @param ref 去重键。同一个 ref 只会入队一次（事务级）。留空 = 不去重。
#' @return 新的行号；被去重挡下时返回 NA（**不是错误**）
dsapp_mail_enqueue <- function(to, subject, body_md = "", base_dir = "",
                               attach_path = NULL, kind = "manual",
                               ref = "", user_id = NULL,
                               cfg = dsapp_config(), con = NULL) {
  to <- trimws(as.character(to %||% "")[1])
  # ⚠️ 收件地址为空就**别建行**。建了的话排空时才发现，那时错误信息是
  #    "收件人为空"，而真正的原因（上游没查到这个人）已经看不见了。
  if (!nzchar(to) || !grepl("@", to, fixed = TRUE)) {
    return(NA_integer_)
  }
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  id <- tryCatch(
    DBI::dbGetQuery(con,
      "INSERT OR IGNORE INTO mail_queue
         (user_id, to_email, subject, body_md, base_dir, attach_path,
          kind, ref, status, tries, last_error, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, '', ?)
       RETURNING id",
      params = list(
        if (is.null(user_id) || is.na(user_id)) NA_integer_
        else as.integer(user_id),
        to,
        substr(as.character(subject %||% "")[1], 1L, DSAPP_MAIL_SUBJECT_MAX),
        paste(as.character(body_md %||% ""), collapse = "\n"),
        as.character(base_dir %||% "")[1],
        if (is.null(attach_path) || !nzchar(attach_path %||% "")) NA_character_
        else as.character(attach_path)[1],
        as.character(kind %||% "manual")[1],
        as.character(ref %||% "")[1],
        dsapp_now()))$id,
    error = function(e) {
      message("[dsapp] 邮件入队失败：", conditionMessage(e))
      NA_integer_
    })
  if (length(id) == 0L) return(NA_integer_)   # OR IGNORE 命中唯一索引
  as.integer(id)
}

#' 原子地认领一条（把 pending 改成 sending）
#'
#' ★ **这一条是"同一封信不会发两遍"的真正保证**，不是 ref 上的唯一索引。
#'   唯一索引挡的是"同一个 ref 入队两次"；挡不住"两个排空进程同时读到
#'   同一行 pending 再各自发一次"。`UPDATE ... WHERE status='pending'`
#'   是原子的，受影响行数 > 0 的那个才是认领成功的那一个。
dsapp_mail_claim <- function(id, con) {
  n <- tryCatch(
    DBI::dbExecute(con,
      "UPDATE mail_queue SET status = 'sending', tries = tries + 1
        WHERE id = ? AND status = 'pending'",
      params = list(as.integer(id))),
    error = function(e) 0L)
  isTRUE(n > 0L)
}

#' 把卡在 'sending' 的信放回 'pending'
#'
#' ⚠️⚠️ 为什么非要有这一个：`status` 只有 'sending' 一个中间态，而
#'    `dsapp_mail_drain()` 只捞 'pending'。排空进程要是在发送中途被弄死
#'    （OOM、机器重启、`systemctl restart` 正好卡在那个窗口），那一行就
#'    **永远停在 'sending'** —— 既不会重试、也不会进 `dsapp_mail_last_error()`
#'    的统计（那个只数 'failed'），界面上一切正常。这是最坏的一种失败：
#'    静默，而且看起来没出事。
#'
#' `created_at` 是这场事故唯一的时间戳（队列里没记"什么时候开始发的"，
#' 加一列要动 schema，收益不值）。用 30 分钟做阈值：一次 SMTP 是**秒级**，
#' 30 分钟还停在 sending 只可能是进程已经死了。
#'
#' @return 放回去了几条
dsapp_mail_reclaim <- function(cfg = dsapp_config(), older_than = 1800) {
  con <- dsapp_db(cfg)
  cutoff <- format(Sys.time() - older_than, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  n <- tryCatch(
    DBI::dbExecute(con,
      "UPDATE mail_queue SET status = 'pending'
        WHERE status = 'sending' AND created_at < ?",
      params = list(cutoff)),
    error = function(e) 0L)
  as.integer(n %||% 0L)
}

#' 排空队列（**在子进程里跑**，见 dsapp_mail_kick）
#'
#' @param max 这一轮最多发几封。有上限是因为它跑在一个后台进程里，
#'   而 SMTP 一封就是几秒；没上限的话积压一百封会把那个进程挂很久。
dsapp_mail_drain <- function(cfg = dsapp_config(), max = 10L) {
  if (!dsapp_mail_ready(cfg)) return(list(ok = FALSE, msg = "没配 SMTP", sent = 0L))
  con <- dsapp_db(cfg)
  rows <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT id, to_email, subject, body_md, base_dir, attach_path, kind, user_id
         FROM mail_queue WHERE status = 'pending'
        ORDER BY id LIMIT ?", params = list(as.integer(max))),
    error = function(e) NULL)
  if (is.null(rows) || !nrow(rows)) return(list(ok = TRUE, sent = 0L, failed = 0L))

  sent <- 0L; failed <- 0L
  for (i in seq_len(nrow(rows))) {
    r <- as.list(rows[i, , drop = FALSE])
    if (!dsapp_mail_claim(r$id, con)) next   # 别人抢先认领了

    res <- tryCatch(
      dsapp_mail_deliver(
        to = r$to_email, subject = r$subject, body_md = r$body_md %||% "",
        base_dir = r$base_dir %||% "",
        attach_path = if (is.na(r$attach_path)) NULL else r$attach_path,
        cfg = cfg),
      error = function(e) list(ok = FALSE, msg = conditionMessage(e)))

    if (isTRUE(res$ok)) {
      sent <- sent + 1L
      DBI::dbExecute(con,
        "UPDATE mail_queue SET status='sent', sent_at=?, last_error=''
          WHERE id = ?", params = list(dsapp_now(), as.integer(r$id)))
      # ★★ V17 item 6（OA 审计的 M1）：这里原来写死 `user_id = NULL`，于是
      #    "谁收到了哪封信"这一行**没有归属** —— 后果不只是难看：
      #    `dsapp_audit_list()` 按用户过滤时用的是 `AND user_id IN (...)`，
      #    这些行会被整体**漏掉**，查一个人的投递记录永远是空的。
      #    带上收件人 uid 之后，`dsapp_audit()` 还会顺手把 email 列也填上
      #    （那一列存在的意义就是"账号被删了之后日志里还知道是谁"）。
      #    ⚠️ 队列行本来就是一人一封（见 dsapp_mail_enqueue 的单人校验），
      #      所以"这一行的 user_id"就是收件人，不存在张冠李戴。
      dsapp_audit("mail_sent", user_id = r$user_id, target = r$to_email,
                  detail = sprintf("%s（%s）", r$subject, r$kind),
                  ok = TRUE, cfg = cfg, con = con)
    } else {
      failed <- failed + 1L
      # 失败有两种：还能再试的（网络抖、服务器 4xx）和试了也白试的。
      # 这里只按次数分：到 MAX_TRIES 就停，不再自动重试，但**留在库里**
      # 并且界面上看得见 —— 静默放弃是最坏的。
      tries <- tryCatch(
        DBI::dbGetQuery(con, "SELECT tries FROM mail_queue WHERE id = ?",
                        params = list(as.integer(r$id)))$tries[1],
        error = function(e) DSAPP_MAIL_MAX_TRIES)
      done <- isTRUE(tries >= DSAPP_MAIL_MAX_TRIES)
      DBI::dbExecute(con,
        "UPDATE mail_queue SET status = ?, last_error = ? WHERE id = ?",
        params = list(if (done) "failed" else "pending",
                      substr(as.character(res$msg %||% "")[1], 1L, 500L),
                      as.integer(r$id)))
      if (done) {
        dsapp_audit("mail_failed", target = r$to_email,
                    detail = sprintf("%s：%s", r$subject,
                                     substr(res$msg %||% "", 1L, 200L)),
                    ok = FALSE, cfg = cfg, con = con)
      }
    }
  }
  list(ok = TRUE, sent = sent, failed = failed)
}

#' 起一个后台进程排空队列
#'
#' 可以随便多调几次 —— 重复的排空不会把信发两遍（认领那一步是原子的）。
#' 进程内的防重入只是省资源，不是正确性的一部分。
#'
#' @return invisible(TRUE/FALSE)：起没起来
dsapp_mail_kick <- function(cfg = dsapp_config()) {
  if (!dsapp_mail_ready(cfg)) return(invisible(FALSE))

  st <- getOption("dsapp.mail.kick")
  if (is.list(st) && !is.null(st$proc) && isTRUE(st$proc$is_alive())) {
    return(invisible(FALSE))     # 已经有一个在排了
  }
  ok <- tryCatch({
    h <- dsapp_bg_start("dsapp_mail_drain", args = list(cfg = cfg), cfg = cfg,
                        tag = "mail")
    options(dsapp.mail.kick = h)
    TRUE
  }, error = function(e) {
    message("[dsapp] 排空邮件的子进程没起来：", conditionMessage(e))
    FALSE
  })
  invisible(ok)
}

#' 界面上"发了一封信、等回执"的那套轮询（**两个页面共用这一份**）
#'
#' 设置页的「发一封测试邮件」和「文献速递」页的「发到我的邮箱」都是同一件事：
#' 入队 → kick → 等子进程把状态写回库里 → 告诉用户成没成。两处各写一遍的话，
#' 迟早只有一处被修（比如"超时之后还在转"这种）。
#'
#' ⚠️⚠️ 本进程绝不做那次 SMTP 握手。全站只有一个 R 进程，一次 SMTP 是秒级，
#'    在这儿同步发等于所有人一起卡住（R/health.R:26 那段注释骂的就是这个）。
#'    所以是"入队 + 起子进程"，然后**轮询库里的状态**给回执。
#'
#' ⚠️⚠️ 内部那个 observe 读的**只有** `job()`，别的全走 isolate。特别是
#'    `ticks`：它既读又写的话就是自己失效自己 —— 配上下面的 invalidateLater，
#'    症状不是卡死，而是"定时器瞬间烧穿、然后静默停掉"，页面上什么都不显示。
#'    重跑的**唯一**来源是 invalidateLater。
#'
#' ⚠️ 必须在 moduleServer 里调（它要一个 reactive 上下文来注册 observe）。
#'
#' @param cfg_fun 返回 cfg 的函数（模块里 cfg 往往是 reactive）
#' @return list(send = function(id) 开始盯, note = reactiveVal 给 renderUI 读)
dsapp_mail_ui_watch <- function(cfg_fun, interval = 1000L, max_ticks = 45L) {
  job   <- shiny::reactiveVal(NA_integer_)
  note  <- shiny::reactiveVal("")
  ticks <- shiny::reactiveVal(0L)

  shiny::observe({
    id <- job()
    if (is.na(id)) return()
    n <- isolate(ticks())
    if (n > max_ticks) {          # 等太久就别再转了，别让页面一直显示"正在发"
      note("等超时了。信可能还在后台发，过一会儿刷新看看。")
      job(NA_integer_); return()
    }
    r <- tryCatch(
      DBI::dbGetQuery(dsapp_db(cfg_fun()),
        "SELECT status, last_error FROM mail_queue WHERE id = ?",
        params = list(as.integer(id))),
      error = function(e) NULL)
    if (is.null(r) || !nrow(r)) { job(NA_integer_); return() }
    st <- as.character(r$status[1])
    if (identical(st, "sent")) {
      note("发出去了。收件箱里没有的话翻一下垃圾邮件。")
      job(NA_integer_); return()
    }
    if (identical(st, "failed")) {
      note(paste0("没发出去：",
                  substr(as.character(r$last_error[1] %||% ""), 1L, 160L)))
      job(NA_integer_); return()
    }
    ticks(n + 1L)
    shiny::invalidateLater(interval)
  })

  list(
    send = function(id) {
      if (is.na(id)) { note("没能入队（详情见服务端日志）。"); return(invisible(FALSE)) }
      ticks(0L)
      note("正在发…")
      job(as.integer(id))
      invisible(TRUE)
    },
    note = note)
}

#' 某个账号最近一次发信失败的原因（界面上要显示出来）
#'
#' @return 字符串；没有失败就是 ""
dsapp_mail_last_error <- function(user_id, cfg = dsapp_config(), con = NULL) {
  if (is.null(user_id) || is.na(user_id)) return("")
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT subject, last_error FROM mail_queue
        WHERE user_id = ? AND status = 'failed'
        ORDER BY id DESC LIMIT 1", params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return("")
  sprintf("「%s」没发出去：%s", substr(r$subject[1], 1L, 40L),
          substr(r$last_error[1] %||% "", 1L, 120L))
}

#' 某个账号的发信统计（设置页那张卡片显示）
dsapp_mail_stats <- function(user_id, cfg = dsapp_config(), con = NULL) {
  empty <- list(sent = 0L, failed = 0L, pending = 0L, last_sent = "")
  if (is.null(user_id) || is.na(user_id)) return(empty)
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT status, COUNT(*) AS n, MAX(sent_at) AS last_sent
         FROM mail_queue WHERE user_id = ? GROUP BY status",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(empty)
  get <- function(s) {
    v <- r$n[r$status == s]
    if (!length(v)) 0L else as.integer(v[1])
  }
  ls <- r$last_sent[!is.na(r$last_sent)]
  list(sent = get("sent"), failed = get("failed"), pending = get("pending"),
       last_sent = if (length(ls)) as.character(ls[1]) else "")
}
