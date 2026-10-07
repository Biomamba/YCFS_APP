# =============================================================================
# 代理（VPN）设置 —— Test_V16.3 item 2
# =============================================================================
#
# 用户原话：「模型服务里额外加一个VPN设置，用户填写自己的代理地址、端口、
#           协议信息、订阅密匙后可以访问境外模型和数据，订阅密匙同样需要
#           加密处理」。
#
# 这一份只干三件事：**存**（按账号一行、密匙加密）、**算**（把设置变成 curl
# 的一套选项 / 一组环境变量）、**量**（拿这个代理真发一次请求，把结果说出来）。
# 谁在哪儿用它见下面「三处接线」。
#
# -----------------------------------------------------------------------------
# ⚠️⚠️ 铁律：代理**只能按请求挂**，绝不能设成全局的
# -----------------------------------------------------------------------------
#
# 这个应用是一个 R 进程服务**所有**用户（Shiny Server 开源版，见 jobs.R 顶部）。
# 所以下面这些写法**一律不许出现**，一条都不行：
#
#     httr2::set_config(httr2::use_proxy(...))     # 全局，全站一起走代理
#     Sys.setenv(http_proxy = ...)                 # 进程级，同上
#     options(httr2_proxy = ...)
#
# 任何一个用户打开代理，都会让**别人的**请求也绕到他那条线路上 —— 慢是小事，
# 别人填的密匙、别人的模型请求全从他的代理出去，那是数据泄露。而且它不报错：
# 所有人只会觉得"今天网好慢"。
#
# 正确做法只有一条：**把选项挂在那一次 request 对象上**（`req_options()`），
# 或者**传给那一个子进程的环境**（用户代码执行那条路）。两处都在下面。
#
# 所以这个文件里没有、也不该有 `set_config` / `Sys.setenv`。selftest 里有一条
# 机械扫描盯着这句话（扫的是剥掉注释之后的源码）。
#
# -----------------------------------------------------------------------------
# 三处接线（漏一处，用户就会看到"填了代理没用"）
# -----------------------------------------------------------------------------
#
#   ① 对话流式   .dsapp_llm_worker（R/llm.R）—— 被 callr 序列化送走，
#                里面**不能**调 dsapp_* 函数，所以选项在父进程算好、
#                当参数传进去（和 omit_temperature 同一个套路）。
#   ② 非流式     .dsapp_llm_once（R/llm.R）—— 跑在父进程。
#   ③ 拉模型清单 dsapp_llm_models（R/llm.R）—— 跑在后台子进程，那边把 R/*.R
#                整个 source 了一遍，能直接调这里的函数；但选项仍然在**父进程**
#                算好再传（子进程少读一次库，也少一条"子进程库路径不对"的暗路）。
#
#   ④ 用户代码   dsapp_exec_env（R/executor.R）—— "访问境外**数据**"靠这一条：
#                R/Python 里的 download.file / urllib / requests / pip 认的是
#                环境变量，不是 curl 选项。同样是**只给这一个子进程**。
#
# -----------------------------------------------------------------------------
# 为什么协议里有 socks5 又有 socks5h
# -----------------------------------------------------------------------------
#
# 两者的区别只有一个：**域名由谁来解析**。
#   socks5://   本地解析出 IP，再把 IP 交给代理
#   socks5h://  〃  把域名整个交给代理，由代理那边解析
#
# 境外访问要的是后者：本地 DNS 对很多境外域名要么被污染要么解析不了，而
# socks5:// 一旦本地解析失败，请求在出门之前就死了，症状是"连不上"——
# 和"代理没填对"长得一模一样，用户会一直去改地址和端口。
# 两个都留着是因为本地有可用 DNS、只想过个隧道的情况 socks5 更快。
#
# -----------------------------------------------------------------------------
# 为什么回环地址**不**走代理
# -----------------------------------------------------------------------------
#
# noproxy 里钉死了 127.0.0.1 / localhost / ::1。理由不是洁癖：代理的用途是
# 「访问境外」，而回环地址天生就在本机。真把它塞进代理的话，本机跑的 ollama、
# 或者这个应用自己的假服务端（测试用的）会先被送到代理那边、再由代理回头连
# 本机 —— 绕一圈，而且大多数代理默认拒绝连自己的回环，报出来的是一句
# `Connection refused`，指不到代理配置上。
#
# ⚠️ 别把这几条从 noproxy 里删掉：删了之后，探针里那些连本机的路径会**静默**
#    变成走代理，而假代理会把它们全答成 200 —— 一个什么都通过的测试。
# =============================================================================

#' 建表（由 R/db.R 的 dsapp_db_schema 调）
#'
#' 一个账号一行。`sub_key` 存的是**密文**（dsapp_sec_enc），和 user_api_keys
#' 同一条规矩 —— 往这张表写值的代码必须走 dsapp_proxy_save()，直接写 SQL 就是
#' 在库里塞明文。
dsapp_db_schema_proxy <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS user_proxy (
      user_id    INTEGER PRIMARY KEY,
      enabled    INTEGER NOT NULL DEFAULT 0,
      protocol   TEXT NOT NULL DEFAULT 'socks5h',
      host       TEXT NOT NULL DEFAULT '',
      port       INTEGER,
      username   TEXT NOT NULL DEFAULT '',
      sub_key    TEXT,
      key_mode   TEXT NOT NULL DEFAULT 'both',
      updated_at TEXT NOT NULL
    )")
  invisible(TRUE)
}

DSAPP_PROXY_PROTOCOLS <- c(
  "socks5h" = "SOCKS5（域名交给代理解析，推荐）",
  "socks5"  = "SOCKS5（本地解析域名）",
  "http"    = "HTTP 代理",
  "https"   = "HTTPS 代理（到代理这一段用 TLS）"
)

#' 密匙用途
#'
#' 为什么要有这个下拉、而不是猜一个默认值：各家"订阅"服务的鉴权方式不一样，
#' 而 curl 只认 `用户名:密码` 这一种写法。猜错的表现是 **407 Proxy
#' Authentication Required** —— 那句话说"你的密匙不对"，但真正的原因是
#' "你把密匙填在了另一个字段里"。让用户自己指明比让代码猜便宜。
DSAPP_PROXY_KEY_MODES <- c(
  "both" = "用户名和密码都填它",
  "pass" = "只当密码（用户名用上面填的）",
  "user" = "只当用户名（密码留空）"
)

#' 把「代码 → 说明」这张表翻成 selectInput 要的形状
#'
#' ⚠️⚠️ 上面那两张表**不能直接喂给 `selectInput(choices = )`**，这是一个
#'     不出声的坑，2026-10-04 被浏览器探针当场逮住：
#'
#'     shiny 的 `choices` 里，**元素**才是提交给服务端的值，**名字**是给用户
#'     看的文字。上面那两张表是按"代码 → 说明"写的查找表（名字=代码），正好
#'     反过来。直接喂进去的后果，链条长而且每一环都不报错：
#'       ① 用户在下拉里看到的是 `socks5h` 这种代码（说明文字反而成了值）；
#'       ② 提交上来的是整句中文，`dsapp_proxy_norm()` 拿它去
#'          `%in% names(DSAPP_PROXY_PROTOCOLS)` 一比，永远对不上；
#'       ③ 对不上就**静默回落**到默认值 `socks5h` / `both`；
#'       ④ 于是用户挑了「HTTP 代理」，存进库里的还是 socks5h，请求按 SOCKS5
#'          发到一个 HTTP 代理上 —— 连不上。
#'     结果是**整个协议下拉形同虚设**，而界面上它看起来完全正常。
#'
#'     这条只有真在浏览器里点一下才看得见：源码每一行都对，自检也全绿
#'     （本仓那条「自检全绿 ≠ 功能被验过」的老账）。
#'
#' @param tab 形如 `c(代码 = "说明")` 的表
#' @return 形如 `c("说明" = 代码)`，可直接给 selectInput
dsapp_proxy_choices <- function(tab) stats::setNames(names(tab), unname(tab))

#' 归一化一份代理设置
#'
#' 三种输入都收：NULL、库里查出来的 data.frame 行、界面上报上来的 list。
#' 输出**永远**是同一个形状的 list（不是 NULL）—— 界面那边每一处都要读它，
#' 让它有时 NULL 有时 list，等于把判空抄得到处都是。
dsapp_proxy_norm <- function(p = NULL) {
  g <- function(k, d = "") {
    v <- if (is.null(p)) NULL else p[[k]]
    if (is.null(v) || length(v) == 0) return(d)
    v <- v[[1]]
    if (is.na(v)) return(d)
    v
  }
  proto <- trimws(as.character(g("protocol", "socks5h")))
  if (!proto %in% names(DSAPP_PROXY_PROTOCOLS)) proto <- "socks5h"
  mode <- trimws(as.character(g("key_mode", "both")))
  if (!mode %in% names(DSAPP_PROXY_KEY_MODES)) mode <- "both"
  port <- suppressWarnings(as.integer(g("port", NA_integer_)))
  if (is.na(port) || port < 1L || port > 65535L) port <- NA_integer_
  list(enabled  = isTRUE(as.logical(g("enabled", FALSE))),
       protocol = proto,
       host     = trimws(as.character(g("host", ""))),
       port     = port,
       username = trimws(as.character(g("username", ""))),
       # ⚠️ 密匙在这里是**明文**。库里的那一份是 dsapp_sec_dec() 解出来的。
       sub_key  = as.character(g("sub_key", "")),
       key_mode = mode)
}

#' 这份设置能不能拿去发请求
#'
#' 「填了一半」和「没填」在界面上是两件事，但在这里是同一件：地址或端口缺一个
#' 就没法用。宁可不挂代理（走直连、该报什么错报什么错），也不要挂一个
#' 半截的代理把**所有**请求变成一句 `Could not resolve proxy`。
dsapp_proxy_ok <- function(p) {
  q <- dsapp_proxy_norm(p)
  isTRUE(q$enabled) && nzchar(q$host) && !is.na(q$port)
}

#' 读某个账号的代理设置
#'
#' ⚠️ 和 `dsapp_api_key_recall()` 不同，这里**总是**返回一个完整的 list
#'    （没设置过 = 一份空的）。理由见 dsapp_proxy_norm()。
dsapp_proxy_get <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(dsapp_proxy_norm(NULL))
  }
  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT enabled, protocol, host, port, username, sub_key, key_mode
         FROM user_proxy WHERE user_id = ?",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(dsapp_proxy_norm(NULL))
  p <- dsapp_proxy_norm(row)
  # ★ 出库解密。解不开（钥匙串换了/丢了）时 dsapp_sec_dec 返回 NULL，这一份
  #   看起来就是"密匙没填" —— 那是**有意**的：把密文当密匙发出去，换来的是
  #   一句 407，而真正的原因（钥匙串变了）界面上一个字都不会提。
  p$sub_key <- as.character(dsapp_sec_dec(row$sub_key[[1]]) %||% "")
  p
}

#' 给"这一刻要发请求的人"读代理设置
#'
#' 调用方一律用这个，不要自己去查库 —— 多一处自己拼的读法，就多一处
#' "忘了判 enabled"（那样用户关了开关，请求还在绕代理，而界面上开关是关的）。
#' 返回 NULL 表示"这次不挂代理"，可以直接当 `proxy =` 参数传下去。
dsapp_proxy_for <- function(user_id, con = dsapp_db()) {
  p <- tryCatch(dsapp_proxy_get(user_id, con = con), error = function(e) NULL)
  if (!dsapp_proxy_ok(p)) return(NULL)
  p
}

#' 存一份代理设置
#'
#' `sub_key` 为空串时**不动**已存的那个（和 dsapp_api_key_put / settings_save
#' 同一条规矩）：防抖保存会带着半截密匙触发好几轮，照直写进去就是把用户上一轮
#' 粘好的密匙抹了。真删走 dsapp_proxy_clear()。
dsapp_proxy_save <- function(user_id, enabled = FALSE, protocol = "socks5h",
                             host = "", port = NULL, username = "",
                             sub_key = "", key_mode = "both",
                             con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  p <- dsapp_proxy_norm(list(enabled = enabled, protocol = protocol, host = host,
                             port = port, username = username,
                             sub_key = sub_key, key_mode = key_mode))
  k <- trimws(p$sub_key)
  # ★ 入库前加密。这是密匙进数据库的唯一一道门，所以放在这里、而不是散在
  #   调用方 —— 少写一处就是一段明文躺在库里，而且没有任何迹象。
  know <- if (nzchar(k)) dsapp_sec_enc(k) else NA_character_

  invisible(tryCatch({
    DBI::dbExecute(con, "
      INSERT INTO user_proxy (user_id, enabled, protocol, host, port,
                              username, sub_key, key_mode, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        enabled    = excluded.enabled,
        protocol   = excluded.protocol,
        host       = excluded.host,
        port       = excluded.port,
        username   = excluded.username,
        -- 空串当成「这次没带密匙」，不覆盖已存的（理由见上面那段）
        sub_key    = COALESCE(excluded.sub_key, user_proxy.sub_key),
        key_mode   = excluded.key_mode,
        updated_at = excluded.updated_at",
      params = list(as.integer(user_id), as.integer(isTRUE(p$enabled)),
                    p$protocol, p$host,
                    if (is.na(p$port)) NA_integer_ else p$port,
                    p$username, know, p$key_mode, dsapp_now()))
    TRUE
  }, error = function(e) FALSE))
}

#' 清掉某个账号的代理设置（连同密匙）
dsapp_proxy_clear <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  invisible(tryCatch({
    DBI::dbExecute(con, "DELETE FROM user_proxy WHERE user_id = ?",
                   params = list(as.integer(user_id)))
    TRUE
  }, error = function(e) FALSE))
}

#' 代理的 curl 选项
#'
#' 返回一个**纯 list**（没有一个函数、没有一个 dsapp_* 名字），因为它要当参数
#' 穿过 callr 的序列化边界送进 .dsapp_llm_worker。那边只做一件事：
#' `do.call(httr2::req_options, c(list(req), opts))`。
#'
#' ⚠️ 用户名/密码用 `proxyuserpwd`（一个 "user:pass" 字符串）**分开**给，
#'    不是拼进 proxy 的 URL 里。拼 URL 的话密匙里一个 `@` 或 `:` 就会把整个
#'    URL 拆错位，而 curl 那边看到的是一句"无法解析代理地址"—— 用户会去改
#'    地址和端口，而那两样根本没错。
dsapp_proxy_opts <- function(p) {
  if (!dsapp_proxy_ok(p)) return(NULL)
  q <- dsapp_proxy_norm(p)

  # 密匙按 key_mode 落到 user / pass 上（见 DSAPP_PROXY_KEY_MODES 的说明）。
  # ⚠️ netrc 那条路（"只给用户名"）在 curl 里的写法是 `user:`（密码留空），
  #    不是 `user`。给一个光秃秃的 user，curl 会把它当成"用户名和密码都是
  #    user"（CURLOPT_PROXYUSERPWD 的既定行为），于是 407 照样来。
  u <- q$username
  k <- q$sub_key
  if (identical(q$key_mode, "both")) {
    if (nzchar(k)) u <- k else if (nzchar(u)) k <- u
  } else if (identical(q$key_mode, "user")) {
    u <- if (nzchar(k)) k else u
    k <- ""
  } else {
    # key_mode == "pass"
    if (!nzchar(k)) k <- u
  }

  opts <- list(
    proxy        = paste0(q$protocol, "://", q$host),
    proxyport    = q$port,
    # 回环永远直连（理由见文件顶部那段）。这一条是**故意**钉死的。
    noproxy      = "127.0.0.1,localhost,::1"
  )
  if (nzchar(u) || nzchar(k)) {
    opts$proxyuserpwd <- paste0(u, ":", k)
    # 1 = CURLAUTH_BASIC。SOCKS5 那两种协议下 curl 忽略它、直接用
    # proxyuserpwd 当 SOCKS5 的用户名/密码 —— 也正是我们要的。
    opts$proxyauth <- 1
  }
  opts
}

#' 把代理挂到一个 httr2 请求上
#'
#' 父进程那两处（.dsapp_llm_once / 探针）用它。**不返回 NULL**：没配代理时
#' 原样把 req 还回去，调用方可以一直链下去。
dsapp_proxy_apply <- function(req, p) {
  opts <- dsapp_proxy_opts(p)
  if (is.null(opts) || length(opts) == 0) return(req)
  do.call(httr2::req_options, c(list(req), opts))
}

#' 子进程该带的环境变量
#'
#' 「访问境外**数据**」靠这一条：R 的 download.file / curl、Python 的
#' requests / urllib / pip 认的都是环境变量，不是 curl 选项。
#'
#' ⚠️ 这里返回的是一个**给子进程用的** named character vector，调用方只把它
#'    塞进那一个 processx::process$new(env = ...)。它**不是** Sys.setenv ——
#'    那份环境只在用户那一段代码里存在，出了那个进程就没了。
dsapp_proxy_env <- function(p) {
  if (!dsapp_proxy_ok(p)) return(character(0))
  q <- dsapp_proxy_norm(p)
  u <- q$username
  k <- q$sub_key
  if (identical(q$key_mode, "both")) {
    if (nzchar(k)) u <- k else if (nzchar(u)) k <- u
  } else if (identical(q$key_mode, "user")) {
    u <- if (nzchar(k)) k else u
    k <- ""
  } else {
    if (!nzchar(k)) k <- u
  }
  auth <- if (nzchar(u) || nzchar(k)) {
    # ⚠️ 这里的 user:pass 是**要拼进 URL** 的，所以必须转义 —— 密匙里一个
    #    `@` 或 `/` 会让整条 URL 解析到别的地方去（而报错是"域名解析失败"）。
    #    和上面 curl 选项那条路正好相反：那条路不许转义，这条路必须转义。
    paste0(utils::URLencode(u, reserved = TRUE), ":",
           utils::URLencode(k, reserved = TRUE), "@")
  } else ""
  url <- paste0(q$protocol, "://", auth, q$host, ":", q$port)
  # http_proxy / HTTP_PROXY 都给：libcurl 与 requests 认小写，有些老工具只认
  # 大写。all_proxy 是 SOCKS 那条路上必须的那个（curl 在 socks 协议下会读它）。
  c(http_proxy  = url, https_proxy = url, all_proxy = url,
    HTTP_PROXY  = url, HTTPS_PROXY = url, ALL_PROXY = url,
    # 回环直连（同上，别删）
    no_proxy    = "127.0.0.1,localhost,::1",
    NO_PROXY    = "127.0.0.1,localhost,::1")
}

#' 给人看的一句话描述（日志 / 界面用）
#'
#' ⚠️ **不含密匙**。这一句会被写进日志、显示在界面上，密匙进去了就等于泄漏。
dsapp_proxy_desc <- function(p) {
  q <- dsapp_proxy_norm(p)
  if (!dsapp_proxy_ok(q)) return("")
  sprintf("%s://%s:%d%s", q$protocol, q$host, q$port,
          if (nzchar(q$sub_key) || nzchar(q$username)) "（带鉴权）" else "")
}

#' 拿这份代理真发一次请求
#'
#' 存在的理由和「获取模型」那颗按钮一模一样：**让用户能自己判断配没配对**。
#' 代理填错的表现只有两种 —— 连不上（Could not resolve/connect proxy）和
#' 407 —— 而它们都会出现在**下一次发消息**的时候，用户根本不会把它和"我刚
#' 才填的代理"联系起来。
#'
#' 打的是 `https://www.gstatic.com/generate_204`（Google 的连通性探测点，
#' 固定回 204、没有响应体）。选它是因为：① 它在境外，代理有没有真的把请求
#' 带出去一试就知道；② 它不返回任何内容，不会顺手把什么数据拉回来。
#'
#' ⚠️ `timeout` 给得比普通请求短：这是个交互式按钮，用户等不了 20 秒。
#'
#' @return list(ok, msg, ms)
dsapp_proxy_test <- function(p, timeout = 12) {
  if (!dsapp_proxy_ok(p)) {
    return(list(ok = FALSE, ms = 0,
                msg = "还没填全：需要「地址」和「端口」，并且打开上面的开关。"))
  }
  url <- "https://www.gstatic.com/generate_204"
  t0 <- Sys.time()
  res <- tryCatch({
    req <- httr2::request(url)
    req <- dsapp_proxy_apply(req, p)
    req <- httr2::req_timeout(req, timeout)
    # 4xx/5xx 不抛：我们要读状态码判断"通没通"，而不是拿到一句异常
    req <- httr2::req_error(req, is_error = function(resp) FALSE)
    resp <- httr2::req_perform(req)
    list(ok = TRUE, status = httr2::resp_status(resp))
  }, error = function(e) list(ok = FALSE, err = conditionMessage(e)))

  ms <- as.integer(round(as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000))
  if (isTRUE(res$ok)) {
    return(list(ok = TRUE, ms = ms,
                msg = sprintf("通了：经 %s 访问境外站点，HTTP %d，用了 %.1f 秒。",
                              dsapp_proxy_desc(p), res$status, ms / 1000)))
  }
  list(ok = FALSE, ms = ms, msg = dsapp_proxy_why(res$err))
}

#' 把 curl 那句英文翻译成人话
#'
#' 不翻译的话，用户拿到的是 `Failed to connect to 1.2.3.4 port 1080 after
#' 12000 ms: Connection refused` —— 里面没有一个字告诉他下一步该改哪儿。
dsapp_proxy_why <- function(err) {
  e <- as.character(err %||% "")[1] %||% ""
  if (!nzchar(e)) return("没连上，但没拿到原因。")
  if (grepl("407", e) || grepl("Proxy Authentication", e, ignore.case = TRUE)) {
    return(paste0("代理要求鉴权，但凭据没通过（407）。最可能的原因是「密匙用途」",
                  "选错了 —— 换一个再试。原始信息：", e))
  }
  if (grepl("resolve", e, ignore.case = TRUE)) {
    return(paste0("代理的地址解析不了：确认「地址」栏里只填主机名或 IP",
                  "（不要带 http:// 前缀、不要带端口）。原始信息：", e))
  }
  if (grepl("refused", e, ignore.case = TRUE) ||
      grepl("Failed to connect", e, ignore.case = TRUE)) {
    return(paste0("连不上代理的地址和端口：确认代理软件正在运行、端口没写错、",
                  "以及它在监听这个网卡。原始信息：", e))
  }
  if (grepl("timed out", e, ignore.case = TRUE) ||
      grepl("timeout", e, ignore.case = TRUE)) {
    return(paste0("超时。代理地址写对了但连不通，或者代理那头到境外的线路不通。",
                  "原始信息：", e))
  }
  paste0("没通过：", e)
}
