# =============================================================================
# 远程节点名册
# =============================================================================
# V5 追加。此前远程服务器信息是**一次性**的：设置页那张表单填完就只活在这次
# 会话里，刷新页面、换台电脑、第二天再来，都得重新敲一遍 IP / 用户名 /
# 工作目录 / 激活命令。真实用法是"我有一台实验室的服务器"，重复录入是纯粹的
# 损耗，而损耗会让人干脆不用这个功能。
#
# 名册存的是一台机器的**身份**：
#   名字、主机、端口、用户名、认证方式、远程工作目录、激活命令、备注、默认项。
#
# ⚠️ **凭据仍然不落盘 —— 这一条没有被名册松动。**
#    密码和私钥不进这张表、不进任何表、不写任何文件。名册里只存
#    "这台机器用哪种认证方式"，选一个节点之后密码框还是空的，要重填一次。
#
#    为什么不做"加密后存起来"：加密的密钥必须放在同一台服务器上（应用要能
#    自动解密才能用），于是它挡住的只有"库文件被单独拷走"这一种情况，
#    而挡不住任何能读到库文件的人 —— 而后者才是真实威胁。多一层看起来
#    安全的机制会让人往里放更敏感的东西，最终比明文更危险。
#    同一理由写在 mod_settings.R 的 API Key 说明里。
#
#    缓解措施不是"少存一点"，是**同一个会话里不用重复填**：载入节点时会从
#    会话内存里取回上次用过的凭据（见 mod_settings.R 的 node_creds）。
#    内存里的东西关掉页面就没了，这才是凭据该有的生命周期。
# =============================================================================

#' 建表（幂等）
dsapp_db_schema_nodes <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ssh_nodes (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    INTEGER NOT NULL,
      name       TEXT NOT NULL,
      host       TEXT NOT NULL,
      port       INTEGER NOT NULL DEFAULT 22,
      username   TEXT NOT NULL,
      auth       TEXT NOT NULL DEFAULT 'password',
      workdir    TEXT NOT NULL DEFAULT '',
      activate   TEXT NOT NULL DEFAULT '',
      note       TEXT NOT NULL DEFAULT '',
      is_default INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      last_ok_at TEXT
    )")
  # 一个人的节点数量是个位数，按 user_id 建个索引就够了。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_nodes_user ON ssh_nodes(user_id)")
  invisible(TRUE)
}

#' 校验并归一化一个节点
#'
#' 挡的是**写进 ssh 命令行会出事**的输入，不是"格式不好看"。
#' 主机名和用户名最终会变成 `ssh user@host` 的参数，里面出现空格、`-o`、
#' 或者换行，就等于让一个文本框能往 ssh 命令行里塞选项。
#'
#' @return list(error = "给用户看的那句话") 或归一化后的 list
dsapp_node_validate <- function(node) {
  nm <- function(x) trimws(as.character(x %||% ""))

  name <- nm(node$name)
  host <- nm(node$host)
  user <- nm(node$username %||% node$user)
  port <- suppressWarnings(as.integer(node$port %||% 22))
  auth <- if (identical(node$auth, "key")) "key" else "password"
  workdir  <- nm(node$workdir)
  activate <- nm(node$activate)
  note     <- nm(node$note)

  if (!nzchar(name)) return(list(error = "请给这个节点起个名字"))
  if (nchar(name) > 64) return(list(error = "节点名字太长了（64 字以内）"))
  if (!nzchar(host)) return(list(error = "请填主机名或 IP"))
  if (nchar(host) > 255) return(list(error = "主机名太长了"))

  # ⚠️ 这几条是**安全**检查，不是格式检查。下面每个字段都会被拼进
  #    `ssh -p <port> <user>@<host>` 或远程命令里（见 remote.R）。
  #    允许空格就等于允许 `host -o ProxyCommand=...` 这种注入 ——
  #    用户自己注入自己还算小事，但提示词里的远程信息也会流向模型，
  #    一个能改这些字段的人等于给模型开了一条往任意主机发指令的路。
  # ⚠️ 这里必须 perl = TRUE。R 默认的 TRE 引擎**不支持字符组里的 \\[ 转义**，
  #    写成 grepl("^[A-Za-z0-9._:\\[\\]-]+$", "10.0.0.5") 得到的是 FALSE ——
  #    不是"拦住了坏输入"，而是**把所有输入都判成坏的**，包括 10.0.0.5。
  #    那样每个节点都存不进去，而错误信息还说主机名有非法字符。
  #
  # ★ V16.6：判据搬进了 `dsapp_remote_host_ok()`（R/syncservers.R），
  #   这里那份逐字拷贝删掉。原来同一套判据在本仓有**两份**（这里和
  #   R/remote.R），而拷贝的危险不是啰嗦，是**它们会分叉** —— 改了一处
  #   忘了另一处，症状是"从这条路进得来、从那条路进不来"。
  #   （那个函数里带着上面这段 perl=TRUE 的说明，以及 [[:space:]] 那一档：
  #     它的字符集本来就不含空格，所以空格检查是白送的。）
  if (!dsapp_remote_host_ok(host)) {
    return(list(error = "主机名里有不认识的字符（只允许字母、数字、点、横线、冒号）"))
  }
  if (!nzchar(user)) return(list(error = "请填用户名"))
  if (grepl("[[:space:]@]", user) || startsWith(user, "-")) {
    return(list(error = "用户名里不能有空格或 @"))
  }
  if (is.na(port) || port < 1 || port > 65535) {
    return(list(error = "端口要在 1–65535 之间"))
  }
  # 工作目录和激活命令会被拼进远程 shell 命令。这里**不**试图做严格的
  # shell 转义（那需要一个完整的 shell 解析器，做半个比不做更糟），
  # 只挡住控制字符和换行 —— 换行能让一条命令变成两条。
  for (f in list(list(v = workdir, n = "远程工作目录"),
                 list(v = activate, n = "激活命令"))) {
    if (grepl("[\r\n]", f$v)) {
      return(list(error = sprintf("%s里不能有换行", f$n)))
    }
    if (nchar(f$v) > 512) {
      return(list(error = sprintf("%s太长了（512 字以内）", f$n)))
    }
  }

  list(name = name, host = host, port = port, username = user, auth = auth,
       workdir = workdir, activate = activate, note = note)
}

#' 新建 / 保存一个节点
#'
#' @param id 给了就是改，没给就是新建。
#' @return list(ok, id, msg) 或 list(ok = FALSE, msg)
dsapp_node_save <- function(user_id, node, id = NULL, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(list(ok = FALSE, msg = "没有登录账号，无法保存节点"))
  }
  v <- dsapp_node_validate(node)
  if (!is.null(v$error)) return(list(ok = FALSE, msg = v$error))

  uid <- as.integer(user_id)
  id  <- if (is.null(id) || !length(id) || is.na(id)) NULL else as.integer(id)

  # 同名视为同一个节点，直接改它。不这么做的话，用户改完名字点保存会得到
  # 两个只差一个字的条目，而他分不清哪个是"现在用的那个"。
  if (is.null(id)) {
    dup <- tryCatch(DBI::dbGetQuery(con,
      "SELECT id FROM ssh_nodes WHERE user_id = ? AND name = ?",
      params = list(uid, v$name))$id, error = function(e) NULL)
    if (length(dup)) id <- as.integer(dup[[1]])
  }

  if (is.null(id)) {
    is_first <- tryCatch(DBI::dbGetQuery(con,
      "SELECT COUNT(*) AS n FROM ssh_nodes WHERE user_id = ?",
      params = list(uid))$n[[1]] == 0, error = function(e) FALSE)
    id <- as.integer(DBI::dbGetQuery(con,
      "INSERT INTO ssh_nodes (user_id, name, host, port, username, auth,
                              workdir, activate, note, is_default, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
      params = list(uid, v$name, v$host, v$port, v$username, v$auth,
                    v$workdir, v$activate, v$note,
                    as.integer(is_first), dsapp_now()))$id)
    msg <- sprintf("已保存节点「%s」%s", v$name,
                   if (is_first) "（第一个节点，已设为默认）" else "")
  } else {
    # 改的时候**不动 is_default**：它是用户用「设为默认」显式选的，
    # 不该因为"顺手改了个工作目录"而变。
    DBI::dbExecute(con,
      "UPDATE ssh_nodes SET name = ?, host = ?, port = ?, username = ?,
              auth = ?, workdir = ?, activate = ?, note = ?
       WHERE id = ? AND user_id = ?",
      params = list(v$name, v$host, v$port, v$username, v$auth,
                    v$workdir, v$activate, v$note, id, uid))
    msg <- sprintf("已更新节点「%s」", v$name)
  }
  list(ok = TRUE, id = id, msg = msg)
}

#' 节点列表
#'
#' @param user_id 只列这个账号的。**NULL 返回空**，理由同 db_sessions_list：
#'   漏传应当表现为"看不到"，而不是"看到所有人的"。
dsapp_nodes_list <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(NULL)
  }
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT * FROM ssh_nodes WHERE user_id = ?
     ORDER BY is_default DESC, name", params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  d
}

#' 取一个节点
#'
#' ⚠️ **必须带 user_id**。这是唯一的越权防线：id 是自增整数，猜中别人的
#'    节点号就能读到别人的主机名和用户名（凭据不在库里，但机器名单本身
#'    就是信息）。所有调用点都要传当前登录账号。
dsapp_node_get <- function(id, user_id, con = dsapp_db()) {
  if (is.null(id) || !length(id) || is.na(id)) return(NULL)
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(NULL)
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT * FROM ssh_nodes WHERE id = ? AND user_id = ?",
    params = list(as.integer(id), as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  as.list(d[1, , drop = FALSE])
}

dsapp_node_delete <- function(id, user_id, con = dsapp_db()) {
  if (is.null(id) || is.na(id)) return(invisible(FALSE))
  DBI::dbExecute(con, "DELETE FROM ssh_nodes WHERE id = ? AND user_id = ?",
                 params = list(as.integer(id), as.integer(user_id)))
  invisible(TRUE)
}

#' 设为默认
dsapp_node_set_default <- function(id, user_id, con = dsapp_db()) {
  uid <- as.integer(user_id)
  # 先全部清掉再置一个：靠"两个都是默认"来兜底的话，界面上就会出现
  # 两个都带默认标记的节点，用户没法知道下次载入的是哪个。
  DBI::dbExecute(con, "UPDATE ssh_nodes SET is_default = 0 WHERE user_id = ?",
                 params = list(uid))
  DBI::dbExecute(con,
    "UPDATE ssh_nodes SET is_default = 1 WHERE id = ? AND user_id = ?",
    params = list(as.integer(id), uid))
  invisible(TRUE)
}

#' 默认节点
dsapp_node_default <- function(user_id, con = dsapp_db()) {
  d <- dsapp_nodes_list(user_id, con)
  if (is.null(d)) return(NULL)
  i <- which(as.integer(d$is_default) == 1L)
  as.list(d[if (length(i)) i[[1]] else 1L, , drop = FALSE])
}

#' 记一次连接成功
#'
#' 让用户看得出"这台机器上次是什么时候连通的"。连不上和从没连过是两回事，
#' 而界面上都显示成"未验证"的话就分不出来。
dsapp_node_touch_ok <- function(id, user_id, con = dsapp_db()) {
  try(DBI::dbExecute(con,
    "UPDATE ssh_nodes SET last_ok_at = ? WHERE id = ? AND user_id = ?",
    params = list(dsapp_now(), as.integer(id), as.integer(user_id))),
    silent = TRUE)
  invisible(TRUE)
}

#' 节点 → 远程执行配置
#'
#' 转成 remote.R 认识的那个 list（和设置页表单同构），**不含凭据** ——
#' 密码/私钥由调用方从会话内存里补。
dsapp_node_to_remote <- function(node, password = "", key_text = "") {
  list(host     = node$host %||% "",
       port     = as.integer(node$port %||% 22),
       user     = node$username %||% node$user %||% "",
       auth     = node$auth %||% "password",
       password = password,
       key_text = key_text,
       activate = node$activate %||% "",
       workdir  = node$workdir %||% "")
}

#' 一句话描述一个节点（列表里显示用）
#'
#' 用户名的字段名在两种形态里不一样：数据库行叫 `username`，转成远程配置
#' 之后叫 `user`（remote.R 用的是后者）。这里两个都认 —— 调用方多半是直接
#' 把手上那个 list 递进来，不该为了打一行字先查一遍它是哪种形态。
dsapp_node_label <- function(node) {
  sprintf("%s@%s:%s",
          node$username %||% node$user %||% "",
          node$host %||% "",
          node$port %||% 22)
}
