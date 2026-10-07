# ============================================================================
# R/syncservers.R —— 信息同步跳板（V16.6 item 1）
#
# 用户原话：「管理员页面也可以增加信息同步跳板，支持填写新的服务器信息做
#            新的跳板。」「skills、公告等有必要的功能，都需要通过跳板来同步」
#
# ---------------------------------------------------------------------------
# 一、"跳板"是什么
# ---------------------------------------------------------------------------
# 就是一张**管理员登记的服务器清单**：名字 + 主机 + 端口 + 远端同步目录。
# 桌面版/另一台服务器在设置页里从这张清单里**选一台**，不用手打地址。
#
# 为什么需要它：同步的会合点是一个**绝对路径**（<服务器 data_root>/sync/），
# 而那个路径没法猜 —— 应用跑在 shiny 用户下、ssh 进来的是另一个用户，
# 两个 $HOME 根本不是同一个目录（见 R/sync.R 文件头第五节）。原来只能让
# 用户在设置页里手填一整串 `/srv/shiny-server/YCFS_APP/data/sync`，填错一个
# 字符的表现是"同步失败"，而没人能从这句话里看出是路径错了。
#
# ⚠️ 这张表里**只有地址，没有任何凭据**。SSH 的用户名/密码/私钥永远由用户
#    自己在设置页填、只放在会话内存里（R/nodes.R 那条策略，别在这儿开口子）。
#    清单是**公开信息**：它要跟着同步包发给对端，好让对端也能看见。
#
# ---------------------------------------------------------------------------
# 二、为什么不用一条"服务器之间级联转发"的进程
# ---------------------------------------------------------------------------
# 用户选的是「管理员登记的端点列表」这一档，不是"服务器互相转"。
# 而且**现有服务器本来就已经是中转**：A 把包推进来 → 应用 → 为每个对端
# 重建回包 → B 拉走时就把 A 的内容带走了。多一台服务器只是多一个会合点，
# 不需要任何新的转发进程。
#
# ---------------------------------------------------------------------------
# 三、app_settings：一个极小的 KV 表
# ---------------------------------------------------------------------------
# 跳板那张卡上有一个「允许同步建号」的开关，它得有个地方落。本仓此前没有
# 通用的"全局设置"表（prompt_overrides 是一张专用 KV），这里补一张最小的。
#
# ⚠️ 值是 TEXT，读出来一律是字符串。布尔就存 "1"/"0"，别存 TRUE/FALSE ——
#    jsonlite 往返之后 TRUE 会变成 "TRUE"，和 "1" 对不上。
# ============================================================================

#' 建表（幂等）
dsapp_db_schema_sync_servers <- function(con) {
  # ---- 跳板清单 -----------------------------------------------------------
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_servers (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT NOT NULL,
      host       TEXT NOT NULL,
      port       INTEGER NOT NULL DEFAULT 22,
      remote_dir TEXT NOT NULL DEFAULT '',
      note       TEXT NOT NULL DEFAULT '',
      enabled    INTEGER NOT NULL DEFAULT 1,
      is_default INTEGER NOT NULL DEFAULT 0,
      created_by INTEGER,
      created_at TEXT NOT NULL
    )")
  # 名字唯一：清单是给人选的，两条同名的条目在界面上分不出谁是谁。
  # 和 users.email 一样用**唯一索引**而不是表级 UNIQUE 约束 —— 老库里万一
  # 已经有重复行，建索引会失败，那时宁可让索引缺失也不要让应用起不来。
  try(DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_syncservers_name ON sync_servers(name)"),
    silent = TRUE)

  # ---- 全局设置 KV ---------------------------------------------------------
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS app_settings (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT '',
      updated_by INTEGER
    )")
  invisible(TRUE)
}

# ---- app_settings：读 / 写 -------------------------------------------------

#' 读一条全局设置
#'
#' @param default 没设过时返回什么。**调用方要显式给**，不要指望函数替它
#'   猜一个默认值 —— 这个表里每一条的默认值都是那个功能自己的产品决定。
dsapp_setting_get <- function(key, default = "", cfg = dsapp_config(),
                              con = dsapp_db(cfg)) {
  key <- trimws(as.character(key %||% ""))
  if (!nzchar(key)) return(default)
  v <- tryCatch(
    DBI::dbGetQuery(con, "SELECT value FROM app_settings WHERE key = ?",
                    params = list(key))$value,
    error = function(e) NULL)
  if (is.null(v) || !length(v) || is.na(v[1])) return(default)
  as.character(v[1])
}

#' 写一条全局设置（没有就插）
dsapp_setting_set <- function(key, value, user_id = NULL,
                              cfg = dsapp_config(), con = dsapp_db(cfg)) {
  key <- trimws(as.character(key %||% ""))
  if (!nzchar(key)) return(invisible(FALSE))
  # ⚠️ 长度 0 的值先收敛成 ""：DBI 对零长度参数会当成"没有参数"，
  #    报的是 `replacement has 1 row, data has 0` 那一类错，很难往
  #    "值本身是空的"上想。空串是合法值（= 清掉这条设置）。
  value <- as.character(value %||% "")[1]
  if (is.na(value)) value <- ""
  invisible(tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO app_settings (key, value, updated_at, updated_by)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET
         value = excluded.value,
         updated_at = excluded.updated_at,
         updated_by = excluded.updated_by",
      params = list(key, value, dsapp_now(),
                    if (is.null(user_id)) NA_integer_ else as.integer(user_id)))
    TRUE
  }, error = function(e) FALSE))
}

# ---- 「允许同步建号」这一个开关 --------------------------------------------

# app_settings 里的键名。
DSAPP_SETTING_SYNC_ALLOW_CREATE <- "sync_allow_create"

#' 现在允许"同步包给一个云端还没有的邮箱建号"吗？
#'
#' 默认 **FALSE**（关）。三个来源，优先级从高到低：
#'
#'   1. 环境变量 `DSAPP_SYNC_ALLOW_CREATE`（部署级，**盖过一切**）
#'   2. app_settings 里那条（管理员在后台管理页点的）
#'   3. 默认值 FALSE
#'
#' ---------------------------------------------------------------------------
#' ★ 为什么默认关，以及"关"到底意味着什么
#' ---------------------------------------------------------------------------
#' 开了它，**任何能往收件箱里放一个 JSON 的人**就能给任意邮箱建号（抢注）。
#' 包必须自带一份口令校验器才可能"两边密码一致"，而校验器一旦落在跳板上，
#' 跳板管理员对它做离线爆破的成本只取决于用户密码有多长 ——
#' `DSAPP_PW_MIN = 6L`，1000 轮 sha256。**对弱口令，拿到校验器等于拿到密码。**
#'
#' 所以：**当中转用的、给不特定人群用的服务器，这个开关必须关着。**
#' 自己给自己的一台机器当中转、或者"我就是想让本地注册的账号自动出现在
#' 云端"，才打开。开了之后每一次建号都会写审计，并给那个邮箱发一封信
#' （见 .dsapp_sync_user_claim）—— 抢注是拦不住的，能做的只有"让被抢的人
#' 知道"和"留下痕迹"。
#'
#' ⚠️ 环境变量**盖过**管理员在界面上的选择，是有意的：中转服务器的运维者
#'    要能在一个地方把它钉死，而不用担心某天有人在后台点了开关。
#'    界面上会如实显示"被环境变量锁定"，不会让那个开关看起来是坏的。
dsapp_sync_allow_create <- function(cfg = dsapp_config(), con = dsapp_db(cfg)) {
  env <- trimws(Sys.getenv("DSAPP_SYNC_ALLOW_CREATE", ""))
  if (nzchar(env)) return(dsapp_env_truthy(env))
  dsapp_env_truthy(dsapp_setting_get(DSAPP_SETTING_SYNC_ALLOW_CREATE, "0",
                                     cfg = cfg, con = con))
}

#' 这个开关现在是不是被环境变量钉住了（界面用它来决定显不显示"锁定"）
dsapp_sync_allow_create_locked <- function() {
  nzchar(trimws(Sys.getenv("DSAPP_SYNC_ALLOW_CREATE", "")))
}

#' 把一串环境变量/设置值读成 TRUE/FALSE
#'
#' 认 1/true/yes/on（不分大小写）。**认不出来的值一律当 FALSE** ——
#' 这一条是安全默认：`DSAPP_SYNC_ALLOW_CREATE=maybe` 必须是"关"。
dsapp_env_truthy <- function(x) {
  x <- tolower(trimws(as.character(x %||% "")))
  if (!length(x) || is.na(x[1])) return(FALSE)
  x[1] %in% c("1", "true", "yes", "on", "y", "t")
}

# ---- 跳板清单的增删改查 ----------------------------------------------------

#' 主机名合法性（和 R/remote.R 的 dsapp_ssh_ctx 同一套判据）
#'
#' ★ 挡的是**选项注入**：以 `-` 开头的主机名会被 ssh 当成命令行选项解析
#'   （`-oProxyCommand=...`）。所以既限字符集，又单独禁掉开头的横线。
#'
#' ⚠️ 这个函数是为了消掉**三份**逐字重复的拷贝（remote.R 一份、nodes.R 一份、
#'    这里本来会有第三份）。三份拷贝的危险不在于啰嗦，而在于**它们会分叉**：
#'    改了一处忘了另一处，症状是"从这条路进得来、从那条路进不来"。
dsapp_remote_host_ok <- function(host) {
  host <- trimws(as.character(host %||% ""))
  if (!nzchar(host) || is.na(host[1])) return(FALSE)
  # ⚠️ 必须 perl = TRUE。R 默认的 TRE 不把方括号里的 \ 当转义：
  #    写到 `[A-Za-z0-9_.:\[\]-]` 时，TRE 在 `\]` 那个位置就把字符类**提前
  #    收尾**了，整个模式实际变成「若干允许字符 + 字面量 -]」，于是**任何**
  #    主机名都不匹配。症状是"一填地址就报非法字符"，看起来像在正常拦截，
  #    其实是校验把所有人都挡了 —— 这种"错得像个功能"的 bug 最难发现。
  grepl("^[A-Za-z0-9_.:\\[\\]-]+$", host, perl = TRUE) && !grepl("^-", host)
}

#' 列跳板（默认只列启用的；管理页要连停用的一起看）
dsapp_syncservers_list <- function(only_enabled = FALSE, cfg = dsapp_config(),
                                   con = dsapp_db(cfg)) {
  r <- tryCatch(DBI::dbGetQuery(con, paste0(
    "SELECT id, name, host, port, remote_dir, note, enabled, is_default,
            created_by, created_at
       FROM sync_servers",
    if (isTRUE(only_enabled)) " WHERE enabled = 1" else "",
    " ORDER BY is_default DESC, name")), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) {
    # ⚠️ 返回**零行的 data.frame**，不是 NULL。调用方（界面表格）拿到 NULL
    #    和拿到零行要走两条完全不同的路，而"清单是空的"在这里是常态
    #    （新装的机器一条都没有）。
    return(data.frame(id = integer(0), name = character(0), host = character(0),
                      port = integer(0), remote_dir = character(0),
                      note = character(0), enabled = integer(0),
                      is_default = integer(0), created_by = integer(0),
                      created_at = character(0), stringsAsFactors = FALSE))
  }
  r
}

#' 取一条跳板（NA = 没有）
dsapp_syncserver_get <- function(id, cfg = dsapp_config(), con = dsapp_db(cfg)) {
  r <- dsapp_syncservers_list(cfg = cfg, con = con)
  i <- which(as.integer(r$id) == as.integer(id))
  if (!length(i)) return(NULL)
  as.list(r[i[1], , drop = FALSE])
}

#' 默认跳板（桌面版设置页"从清单里选"时预选的那一条）
dsapp_syncserver_default <- function(cfg = dsapp_config(), con = dsapp_db(cfg)) {
  r <- dsapp_syncservers_list(only_enabled = TRUE, cfg = cfg, con = con)
  if (!nrow(r)) return(NULL)
  i <- which(as.integer(r$is_default) == 1L)
  if (!length(i)) i <- 1L
  as.list(r[i[1], , drop = FALSE])
}

#' 校验一条跳板的输入。返回 list(ok, msg, host, name, remote_dir, port)
#'
#' 抽出来是为了让"新增"和"修改"走**同一套**判据 —— 两边各写一遍的话，
#' 迟早出现"新增时拦得住、修改时拦不住"。
.dsapp_syncserver_check <- function(name, host, port, remote_dir, note = "") {
  name <- trimws(as.character(name %||% ""))
  host <- trimws(as.character(host %||% ""))
  remote_dir <- trimws(as.character(remote_dir %||% ""))
  port <- suppressWarnings(as.integer(port %||% 22))
  if (!nzchar(name)) return(list(ok = FALSE, msg = "跳板名称不能为空"))
  if (nchar(name) > 60) return(list(ok = FALSE, msg = "跳板名称不要超过 60 个字"))
  if (!dsapp_remote_host_ok(host)) {
    return(list(ok = FALSE, msg = "主机地址为空或含非法字符"))
  }
  if (is.na(port) || port < 1 || port > 65535) {
    return(list(ok = FALSE, msg = "端口应是 1-65535 之间的数字"))
  }
  # 远端目录必须是**绝对路径**：scp 会把它拼进 `host:path`，相对路径的含义
  # 取决于 ssh 登录时的当前目录 —— 同一台跳板在不同轮次可能落到不同地方。
  # 留空是合法的（用 DSAPP_SYNC_REMOTE_DIR_DEFAULT），非空就必须以 / 开头。
  if (nzchar(remote_dir) && !grepl("^/", remote_dir)) {
    return(list(ok = FALSE,
                msg = "远端同步目录要填绝对路径（以 / 开头），留空则用默认值"))
  }
  list(ok = TRUE, name = name, host = host, port = port,
       remote_dir = sub("/+$", "", remote_dir),
       note = substr(trimws(as.character(note %||% "")), 1, 200))
}

#' 新增一条跳板
#'
#' @return list(ok, id, msg)
dsapp_syncserver_add <- function(name, host, port = 22, remote_dir = "",
                                 note = "", user = NULL, cfg = dsapp_config(),
                                 con = dsapp_db(cfg)) {
  ck <- .dsapp_syncserver_check(name, host, port, remote_dir, note)
  if (!isTRUE(ck$ok)) return(list(ok = FALSE, msg = ck$msg))
  # 名字唯一。这里先查一次是为了给出一句人话；真正的兜底是那个唯一索引。
  if (nrow(dsapp_syncservers_list(cfg = cfg, con = con))) {
    ex <- dsapp_syncservers_list(cfg = cfg, con = con)
    if (any(tolower(ex$name) == tolower(ck$name))) {
      return(list(ok = FALSE, msg = sprintf("已经有一条叫「%s」的跳板了", ck$name)))
    }
  }
  # 第一条自动成为默认 —— 否则新装的机器加完第一条，桌面版那边还是"没得选"。
  n0 <- nrow(dsapp_syncservers_list(cfg = cfg, con = con))
  uid <- if (is.null(user)) NA_integer_ else as.integer(user$id)
  ok <- tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO sync_servers
         (name, host, port, remote_dir, note, enabled, is_default,
          created_by, created_at)
       VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)",
      params = list(ck$name, ck$host, ck$port, ck$remote_dir, ck$note,
                    if (n0 == 0L) 1L else 0L, uid, dsapp_now()))
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(list(ok = FALSE, msg = "写入失败（可能已经有同名的跳板）"))
  dsapp_audit("sync.server_add", user = user, target = ck$name,
              detail = sprintf("%s:%s%s", ck$host, ck$port,
                               if (nzchar(ck$remote_dir)) ck$remote_dir else ""),
              cfg = cfg, con = con)
  list(ok = TRUE, msg = sprintf("已新增跳板「%s」", ck$name))
}

#' 改一条跳板
dsapp_syncserver_update <- function(id, name, host, port = 22, remote_dir = "",
                                    note = "", user = NULL, cfg = dsapp_config(),
                                    con = dsapp_db(cfg)) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "没有指定要改哪一条"))
  ck <- .dsapp_syncserver_check(name, host, port, remote_dir, note)
  if (!isTRUE(ck$ok)) return(list(ok = FALSE, msg = ck$msg))
  ex <- dsapp_syncservers_list(cfg = cfg, con = con)
  dup <- ex$id[!is.na(ex$id) & as.integer(ex$id) != id &
                 tolower(ex$name) == tolower(ck$name)]
  if (length(dup)) {
    return(list(ok = FALSE, msg = sprintf("已经有一条叫「%s」的跳板了", ck$name)))
  }
  n <- tryCatch(DBI::dbExecute(con,
    "UPDATE sync_servers SET name = ?, host = ?, port = ?, remote_dir = ?,
            note = ? WHERE id = ?",
    params = list(ck$name, ck$host, ck$port, ck$remote_dir, ck$note, id)),
    error = function(e) 0L)
  if (!n) return(list(ok = FALSE, msg = "没有找到这条跳板"))
  dsapp_audit("sync.server_update", user = user, target = ck$name,
              detail = sprintf("%s:%s", ck$host, ck$port), cfg = cfg, con = con)
  list(ok = TRUE, msg = sprintf("已更新跳板「%s」", ck$name))
}

#' 启用 / 停用
dsapp_syncserver_set_enabled <- function(id, enabled, user = NULL,
                                         cfg = dsapp_config(),
                                         con = dsapp_db(cfg)) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "没有指定哪一条"))
  n <- tryCatch(DBI::dbExecute(con,
    "UPDATE sync_servers SET enabled = ? WHERE id = ?",
    params = list(if (isTRUE(enabled)) 1L else 0L, id)), error = function(e) 0L)
  if (!n) return(list(ok = FALSE, msg = "没有找到这条跳板"))
  # 停用的那条如果正好是默认，默认位要**让出去**，否则桌面版选出来的
  # 是一条 disabled 的 —— 界面上它根本不在下拉里，表现是"选了没反应"。
  if (!isTRUE(enabled)) try(.dsapp_syncserver_fix_default(con), silent = TRUE)
  dsapp_audit("sync.server_enable", user = user, target = as.character(id),
              detail = if (isTRUE(enabled)) "on" else "off", cfg = cfg, con = con)
  list(ok = TRUE, msg = if (isTRUE(enabled)) "已启用" else "已停用")
}

#' 设为默认
dsapp_syncserver_set_default <- function(id, user = NULL,
                                         cfg = dsapp_config(),
                                         con = dsapp_db(cfg)) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "没有指定哪一条"))
  one <- dsapp_syncserver_get(id, cfg = cfg, con = con)
  if (is.null(one)) return(list(ok = FALSE, msg = "没有找到这条跳板"))
  if (!isTRUE(as.integer(one$enabled) == 1L)) {
    return(list(ok = FALSE, msg = "停用中的跳板不能设为默认"))
  }
  ok <- tryCatch({
    DBI::dbExecute(con, "UPDATE sync_servers SET is_default = 0")
    DBI::dbExecute(con, "UPDATE sync_servers SET is_default = 1 WHERE id = ?",
                   params = list(id))
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(list(ok = FALSE, msg = "设置失败"))
  dsapp_audit("sync.server_default", user = user, target = as.character(id),
              cfg = cfg, con = con)
  list(ok = TRUE, msg = sprintf("已把「%s」设为默认跳板", one$name))
}

#' 删一条跳板
#'
#' ⚠️ 这是**登记信息**，不是用户数据：删掉只是从清单里去掉，不会动任何
#'    已经同步过的内容，也不会去碰那台服务器。（和"删账号"完全是两回事，
#'    见 R/users.R 的 dsapp_user_delete。）
dsapp_syncserver_delete <- function(id, user = NULL, cfg = dsapp_config(),
                                    con = dsapp_db(cfg)) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "没有指定哪一条"))
  one <- dsapp_syncserver_get(id, cfg = cfg, con = con)
  if (is.null(one)) return(list(ok = FALSE, msg = "没有找到这条跳板"))
  n <- tryCatch(DBI::dbExecute(con, "DELETE FROM sync_servers WHERE id = ?",
                               params = list(id)), error = function(e) 0L)
  if (!n) return(list(ok = FALSE, msg = "删除失败"))
  # 删掉的是默认那条的话，把默认位补给下一条 —— 不留"有清单但没有默认"
  # 这个中间态，它会让桌面版的预选落空。
  try(.dsapp_syncserver_fix_default(con), silent = TRUE)
  dsapp_audit("sync.server_delete", user = user, target = one$name,
              cfg = cfg, con = con)
  list(ok = TRUE, msg = sprintf("已删除跳板「%s」", one$name))
}

# 保证"只要清单里还有启用的条目，就恰好有一条是默认"。
.dsapp_syncserver_fix_default <- function(con) {
  r <- dsapp_syncservers_list(cfg = dsapp_config(), con = con)
  if (!nrow(r)) return(invisible(FALSE))
  en <- r[as.integer(r$enabled) == 1L, , drop = FALSE]
  if (!nrow(en)) {
    DBI::dbExecute(con, "UPDATE sync_servers SET is_default = 0")
    return(invisible(FALSE))
  }
  if (any(as.integer(en$is_default) == 1L)) return(invisible(TRUE))
  DBI::dbExecute(con, "UPDATE sync_servers SET is_default = 0")
  DBI::dbExecute(con, "UPDATE sync_servers SET is_default = 1 WHERE id = ?",
                 params = list(as.integer(en$id[1])))
  invisible(TRUE)
}

# ---- 通过同步"认领"出来的账号（后台管理页那一栏）--------------------------

#' 列出由同步包建出来的账号
#'
#' 只读，用于展示和审计。**不参与任何鉴权判断** —— 一个账号是不是管理员
#' 只看 is_admin/admin_scope 两列。
dsapp_sync_claimed_users <- function(cfg = dsapp_config(), con = dsapp_db(cfg)) {
  r <- tryCatch(DBI::dbGetQuery(con, "
    SELECT id, email, nickname, sync_claimed_at, sync_claimed_from,
           CASE WHEN sync_pubkey IS NULL OR sync_pubkey = '' THEN 0 ELSE 1 END
             AS has_key
      FROM users
     WHERE sync_claimed_at IS NOT NULL AND sync_claimed_at <> ''
     ORDER BY sync_claimed_at DESC LIMIT 200"), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) {
    return(data.frame(id = integer(0), email = character(0),
                      nickname = character(0), sync_claimed_at = character(0),
                      sync_claimed_from = character(0), has_key = integer(0),
                      stringsAsFactors = FALSE))
  }
  r
}

# ============================================================================
# 四、出厂清单：随桌面版一起发出去的那批跳板
# ============================================================================
# 用户原话：「支持填写新的服务器信息做新的跳板」。
#
# ★ 这一节回答的是一个**分发**问题，不是协议问题：
#   后台页那张卡管的是**这一台机器自己**的清单。而桌面版发到几百台机器上
#   之后，"把新跳板告诉每一台"没法靠用户手打 —— 那正是这张卡想省掉的事。
#
# ★ 为什么**不**让清单跟着同步包走（这是本节最重要的一个取舍）
# ---------------------------------------------------------------------------
# 同步包的签名覆盖 `.dsapp_sync_sig_payload()` 的**顶层键集**，而那个集合
# 在本版是**冻结点**（见 R/synckey.R 里 V15 加 `forum` 那次事故的注释：
# 顶层多一个键，两边算出的 HMAC 就不同，V15 ↔ V14 双向全挂）。
# 更要紧的是：清单里是**跳板地址**，而用户会照着它去填 SSH 密码 ——
# 一份**没签名**的地址清单等于一个钓鱼入口（谁能写会合目录，谁就能把
# "官方中转"改到自己的机器上，然后收走用户手打的 SSH 密码）。
# 签名它就得往 payload 里加键 → 破坏兼容；不签名就只能当"参考"，
# 而"参考用的地址"配上"紧接着就要输密码"是这条链上最不该有的组合。
#
# 所以这一版走**出厂清单**：谁打包、谁决定这批机器默认连哪儿。
# 它跟二进制一起分发、和可执行文件同源，天然可信 —— 一个能被改掉
# jump_servers.json 的人，早就能改 app.R 了。
#
# ⚠️ 以后如果真要让"服务器把新跳板推给所有客户端"，正确的做法是让
#    **服务器用自己的 Ed25519 身份签一份独立的清单文件**（它的公钥可以
#    经由同步包的 claim 让对端学到），而不是往 payload 里塞键。
#    那是一条独立的小协议，本版不做。

#' 随包分发的跳板清单文件在哪（找不到返回 ""）
#'
#' 两个来源，先找到先用：
#'   1. 环境变量 `DSAPP_JUMP_SERVERS` 指的 JSON 文件（运维/自部署用）
#'   2. `<应用目录>/desktop/jump_servers.json`（打包时塞进去的那份）
dsapp_syncservers_shipped_path <- function() {
  p <- trimws(Sys.getenv("DSAPP_JUMP_SERVERS", ""))
  if (nzchar(p) && file.exists(p)) return(normalizePath(p, mustWork = FALSE))
  q <- file.path(dsapp_app_dir(), "desktop", "jump_servers.json")
  if (file.exists(q)) return(normalizePath(q, mustWork = FALSE))
  ""
}

#' 读出厂清单。**只读、只当输入**，一条都不合法就返回零行。
#'
#' ⚠️ 这个文件是**外部输入**（虽然和二进制同源，但没有签名的东西一律按
#'    敌人写的处理）：逐条过 `.dsapp_syncserver_check()`，过不了的**跳过
#'    并计数**，绝不"整份作废"也绝不"跳过校验直接入库"。
#'    整份作废的坏处是打包的人写错一个字，所有机器一条都种不上；
#'    不校验的坏处是 `host` 里可以放 `-oProxyCommand=...`。
dsapp_syncservers_shipped <- function() {
  p <- dsapp_syncservers_shipped_path()
  empty <- data.frame(name = character(0), host = character(0),
                      port = integer(0), remote_dir = character(0),
                      note = character(0), stringsAsFactors = FALSE)
  if (!nzchar(p)) return(empty)
  raw <- tryCatch(jsonlite::fromJSON(p, simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(raw)) return(empty)
  # 允许两种形状：顶层数组，或者 {"servers":[...]}
  items <- if (is.list(raw) && !is.null(raw$servers)) raw$servers else raw
  if (!is.list(items) || !length(items)) return(empty)
  # 有的 fromJSON 会把纯数组读成 list-of-list，有的读成 data.frame 的行；
  # 统一按"一条一个 list"处理，认不出来的形状直接放弃这一条。
  rows <- lapply(items, function(it) {
    if (!is.list(it)) return(NULL)
    g <- function(k, d = "") {
      v <- it[[k]]
      if (is.null(v) || !length(v)) return(d)
      as.character(v)[1]
    }
    ck <- .dsapp_syncserver_check(g("name"), g("host"),
                                  suppressWarnings(as.integer(g("port", "22"))),
                                  g("remote_dir"), g("note"))
    if (!isTRUE(ck$ok)) return(NULL)
    data.frame(name = ck$name, host = ck$host, port = ck$port,
               remote_dir = ck$remote_dir, note = ck$note,
               stringsAsFactors = FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if (!length(rows)) return(empty)
  out <- do.call(rbind, rows)
  # 同一个名字在出厂清单里出现两次的话，后面那条 INSERT 会撞唯一索引 ——
  # 那样整批种子都会失败（第一条之后的都不进去），所以这里先去重。
  out[!duplicated(tolower(out$name)), , drop = FALSE]
}

#' 第一次跑的时候把出厂清单种进 `sync_servers`
#'
#' **幂等**：表里已经有条目就什么都不做 —— 管理员删掉一条之后，下次启动
#' 不该把它又推回来（"我明明删了"）。
#'
#' @return 种进去的条数（0 = 没种）
dsapp_syncservers_seed <- function(cfg = dsapp_config(), con = dsapp_db(cfg)) {
  # ⚠️ 这里**必须**先查一次表，不能靠"INSERT OR IGNORE + 唯一索引"来兜：
  #    那样兜住的是"同名"，兜不住"管理员把最后一条删了" —— 表空了他重启
  #    一次，出厂清单又全回来了。
  n0 <- tryCatch(nrow(dsapp_syncservers_list(cfg = cfg, con = con)),
                 error = function(e) NA_integer_)
  if (is.na(n0)) return(0L)     # 表还没有（schema 没跑）→ 不当成"空"
  if (n0 > 0L) return(0L)
  sh <- dsapp_syncservers_shipped()
  if (!nrow(sh)) return(0L)
  n <- 0L
  for (i in seq_len(nrow(sh))) {
    r <- tryCatch(
      dsapp_syncserver_add(sh$name[i], sh$host[i], sh$port[i],
                           sh$remote_dir[i], sh$note[i],
                           user = NULL, cfg = cfg, con = con),
      error = function(e) list(ok = FALSE))
    if (isTRUE(r$ok)) n <- n + 1L
  }
  if (n > 0L) {
    try(dsapp_audit("sync.server_seed", target = "出厂清单",
                    detail = sprintf("种入 %d 条", n), cfg = cfg, con = con),
        silent = TRUE)
  }
  n
}
