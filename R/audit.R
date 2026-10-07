# =============================================================================
# 操作审计日志
# =============================================================================
# V5 引入（对应 Python 版的操作审计）。解决的问题很具体：这个应用是**多人
# 共用一台机器**的共享分析平台，出事的时候管理员需要能回答"谁在什么时候
# 干了什么" —— 而在没有日志的情况下，答案是"不知道"：
#
#   * 共享区里的一个数据集被删了 —— 是本人删的，还是别人删的？
#   * 某个账号半夜登录过 —— 是他自己，还是有人拿着他的邮箱进来的？
#   * 磁盘昨天涨了 200G —— 是谁传的？哪个对话跑的？
#   * 登录失败锁定了 —— 是本人记错密码，还是有人在拿别人的邮箱试？
#
# ⚠️ 三条自我约束，写在这里免得后来的人越加越多：
#
#   1. **不记内容。** 只记"谁 + 什么动作 + 对象的名字"，对话正文、任务
#      输出、文件内容一律不进日志。理由和 mod_admin.R 顶部那条一样：生信
#      数据常常是未发表的，能少一个人看到就少一个人。日志是给管理员查
#      "发生了什么事"用的，不是给他查"别人在分析什么"用的。
#      —— 所以 detail 里**永远不要**塞代码、stdout、文件内容。
#
#   2. **写日志失败不能影响主操作。** 磁盘满、库被锁、表结构不对，都不该
#      让"删除文件"这个动作失败。dsapp_audit() 吞掉所有异常，最多留一条
#      警告。审计是**旁路**，不是事务的一部分。
#
#   3. **账号删了日志要留着。** 所以 user_id 上**不加外键**，并且冗余一列
#      email。删账号时 ON DELETE CASCADE 会把"是谁删的"这条线索一起删掉，
#      而"删除账号"恰恰是最需要留痕的操作之一。
#
# 保留期默认 180 天（见 dsapp_audit_gc），启动时清一次。
#
# 两个记录点各有各的位置，别搞混：
#
#   * **动作的主体就是操作者**（登录、注册、改自己的密码）—— 记在 R/users.R
#     里，那些函数是唯一入口，记在那里所有调用方都白得一条日志。
#   * **操作者另有其人**（管理员停用别人、删别人的账号）—— 记在调用方
#     （mod_admin.R），因为被调的函数只知道"谁被操作了"，不知道"谁在操作"。
#     这种地方记的是 user = 管理员、target = 被操作者的邮箱。
# =============================================================================

#' 建表（幂等）
#'
#' 在 dsapp_db_schema() 里调用，任何一次 dsapp_db() 都会把表补齐。
dsapp_db_schema_audit <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS audit_log (
      id      INTEGER PRIMARY KEY AUTOINCREMENT,
      at      TEXT NOT NULL,
      user_id INTEGER,
      email   TEXT NOT NULL DEFAULT '',
      action  TEXT NOT NULL,
      target  TEXT NOT NULL DEFAULT '',
      detail  TEXT NOT NULL DEFAULT '',
      ok      INTEGER NOT NULL DEFAULT 1,
      ip      TEXT NOT NULL DEFAULT ''
    )")
  # 管理页默认按时间倒序看，所以 at 上有索引；按人筛也常用。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at DESC)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_log(user_id, at DESC)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action, at DESC)")
}

#' 动作码 → 中文标签
#'
#' 界面直接用它翻译。**不要**在界面里写 if/else 翻译动作码 —— 那样新加一个
#' 动作就要改两处，漏一处界面上就是一串英文码。这里查不到的原样显示，
#' 老日志遇上新代码也不会变成空白。
DSAPP_AUDIT_LABELS <- c(
  register       = "注册账号",
  login          = "登录",
  login_fail     = "登录失败",
  login_locked   = "登录被锁",
  login_token    = "恢复码登录",
  logout         = "退出",
  pw_set         = "设置/修改密码",
  pw_fail        = "改密失败",
  pw_admin_reset = "管理员重置密码",
  admin_status   = "停用/启用账号",
  admin_token    = "重置恢复码",
  admin_quota    = "设置配额",
  admin_email    = "改登录邮箱",
  admin_limits   = "设置资源上限",
  admin_delete   = "删除账号",
  admin_unlock   = "解锁账号",
  admin_owner    = "改文件归属",
  file_upload    = "上传文件",
  file_delete    = "删除文件",
  file_rename    = "改名/移动",
  file_mkdir     = "新建文件夹",
  file_publish   = "发布产物",
  file_extract   = "解压",
  task_submit    = "提交任务",
  task_cancel    = "中止任务",
  quota_block    = "配额拦截",
  # V9 item 1。同意那一下的**权威记录**在 consent_log（按版本、可追历史），
  # 这里这一条是给管理页"操作日志"那一栏看的 —— 管理员在那儿关心的是
  # "这个人今天做了什么"，而同意须知是其中一个动作。
  # 两条不重复：consent_log 回答"他同意的是哪一版"，audit_log 回答"他什么时候动过"。
  tos_agree      = "确认用户须知",
  tos_declined   = "拒绝用户须知（退出）",
  # V11 item 4b。这一条是**给别人顶下线**的那一端记的（被顶的那一端在
  # 自己的浏览器上，它写不进库 —— 它的身份已经被换掉了，写进去反而会
  # 把新那一端的记录搅浑）。所以日志读法：看到 login 紧跟一条 login_kick，
  # 就是"这个人从 A 端换到了 B 端"。
  login_kick     = "顶掉其它端登录",
  # ★ V13.8 item 1：这三条从 V13 团队功能上线起就**一直缺着**（走查时发现）。
  #   缺了不会报错 —— 界面上那一格显示的是 "team_create" 这个英文码，
  #   看起来像调试信息漏出来了。新增动作码时顺手在这儿补一行。
  team_create    = "新建团队",
  team_update    = "修改团队",
  team_delete    = "删除团队",
  # V13.8 item 1 / item 2：管理员分级 + 后台页。
  admin_scope    = "调整管理员级别",
  admin_add      = "后台新建账号"
)

#' 取客户端 IP
#'
#' Shiny Server 下 REMOTE_ADDR 是有的；本地 runApp、callr 子进程里没有，
#' 那就记空串 —— 不要为了凑一个值去调系统命令（那会拖慢每一次写日志）。
#'
#' ⚠️ 这个值只在"同一台机器上有人乱来"时有用（比如同一个 IP 反复试密码）。
#'    经反向代理进来时它是代理的地址，不是真客户的 —— 记下来是为了排查
#'    模式，不是当作证据。
dsapp_audit_ip <- function(session = NULL) {
  if (is.null(session)) return("")
  tryCatch({
    req <- session$request
    if (is.null(req)) return("")
    x <- req$REMOTE_ADDR %||% ""
    substr(as.character(x)[1] %||% "", 1, 64)
  }, error = function(e) "")
}

#' 记一条审计
#'
#' @param action 动作码，见 DSAPP_AUDIT_LABELS
#' @param user   users 表的一行（或 NULL）。给了就自动取 id 和 email
#' @param user_id 没有 user 行时直接给 id（比如登录失败，账号可能压根不存在）
#' @param target 操作对象：文件名/相对路径、被操作的邮箱、任务号等
#' @param detail 补充说明（**绝不能放内容**，见文件头第 1 条）
#' @param ok     FALSE 表示这次动作被拒绝了
#' @param session 有的话记一条 IP
#'
#' @return invisible(TRUE/FALSE)，调用方**不需要**判断返回值
dsapp_audit <- function(action, user = NULL, user_id = NULL, target = "",
                        detail = "", ok = TRUE, session = NULL,
                        cfg = dsapp_config(), con = dsapp_db(cfg)) {
  # 整段包在 tryCatch 里：审计是旁路，它失败绝不能把主操作带下去。
  # 这里连 warning 都吞掉 —— 一次失败的日志调用不该在用户屏幕上弹东西。
  invisible(tryCatch({
    uid <- user_id
    email <- ""
    if (!is.null(user)) {
      if (is.null(uid)) uid <- user$id
      email <- as.character(user$email %||% "")
    }
    if (!is.null(uid) && (length(uid) == 0 || is.na(uid))) uid <- NULL

    # 只给了 user_id 没给 user 行（比如引擎提交任务那条路）：**现在**把邮箱
    # 查出来一起写进去。这一查是必须的 —— email 列存在的全部意义就是
    # "账号以后被删掉时，日志里还知道是谁"。等到那时候再查，行已经没了。
    if (!nzchar(email) && !is.null(uid)) {
      email <- tryCatch(
        as.character(DBI::dbGetQuery(con, "SELECT email FROM users WHERE id = ?",
                                      params = list(as.integer(uid)))$email[1]
                     %||% ""),
        error = function(e) "")
    }

    DBI::dbExecute(con,
      "INSERT INTO audit_log (at, user_id, email, action, target, detail, ok, ip)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      params = list(
        dsapp_now(),
        if (is.null(uid)) NA_integer_ else as.integer(uid),
        substr(as.character(email %||% "")[1] %||% "", 1, 200),
        substr(as.character(action %||% "")[1] %||% "", 1, 40),
        # 截断：target 是文件名/路径，正常不会长；但真有人传一个超长名字
        # 进来也不该让 INSERT 失败。
        substr(as.character(target %||% "")[1] %||% "", 1, 500),
        substr(as.character(detail %||% "")[1] %||% "", 1, 500),
        if (isTRUE(ok)) 1L else 0L,
        dsapp_audit_ip(session)))
    TRUE
  }, error = function(e) FALSE))
}

#' 查审计日志
#'
#' @param user_id 只看某个人（NULL = 所有人）
#' @param action  只看某类动作（NULL = 全部，支持向量）
#' @param only_fail 只看被拒绝/失败的那些
#' @param days    只看最近几天（NULL = 不限）
#' @param keyword 在 email / target / detail 里模糊匹配
#' @param limit   最多返回多少行（**必须有上限**：日志会长到几十万行，
#'                一次全查出来会把 Shiny 进程的内存吃光）
#' @param scope_ids V13.8 item 1：只看这些账号的日志（整数向量）。
#'   `NULL` = 不限（平台管理员）；**空向量 = 一条都不给**，不是"不限"。
#'   这两个值意思相反，调用方一律用 is.null() 判 —— 判错一个方向就是
#'   "项目管理员看见了全平台的操作日志"。
#'   ⚠️ 它和 user_id 是**两回事**：user_id 是"界面上选了某个人"（下拉里
#'   筛），scope_ids 是"这个人本来就不该看到"。两个条件会同时生效。
dsapp_audit_list <- function(user_id = NULL, action = NULL, only_fail = FALSE,
                             days = NULL, keyword = "", limit = 500L,
                             scope_ids = NULL, con = dsapp_db()) {
  limit <- max(1L, min(as.integer(limit %||% 500L), 5000L))
  sql <- "SELECT id, at, user_id, email, action, target, detail, ok, ip
            FROM audit_log WHERE 1 = 1"
  params <- list()

  if (!is.null(scope_ids)) {
    sid <- suppressWarnings(as.integer(scope_ids))
    sid <- sid[!is.na(sid)]
    if (length(sid) == 0) {
      sql <- paste(sql, "AND 1 = 0")
    } else {
      sql <- paste0(sql, " AND user_id IN (",
                    paste(rep("?", length(sid)), collapse = ","), ")")
      params <- c(params, as.list(sid))
    }
  }

  if (!is.null(user_id) && length(user_id) == 1 && !is.na(user_id)) {
    sql <- paste(sql, "AND user_id = ?")
    params <- c(params, list(as.integer(user_id)))
  }
  act <- as.character(action %||% character(0))
  act <- act[nzchar(act)]
  if (length(act) > 0) {
    sql <- paste0(sql, " AND action IN (",
                  paste(rep("?", length(act)), collapse = ","), ")")
    params <- c(params, as.list(act))
  }
  if (isTRUE(only_fail)) sql <- paste(sql, "AND ok = 0")
  if (!is.null(days) && length(days) == 1 && !is.na(days) && days > 0) {
    sql <- paste(sql, "AND at >= ?")
    params <- c(params, list(format(Sys.time() - days * 86400,
                                    "%Y-%m-%d %H:%M:%S", tz = "UTC")))
  }
  kw <- trimws(as.character(keyword %||% ""))
  if (nzchar(kw)) {
    sql <- paste(sql, "AND (email LIKE ? OR target LIKE ? OR detail LIKE ?)")
    like <- paste0("%", kw, "%")
    params <- c(params, list(like, like, like))
  }
  sql <- paste(sql, "ORDER BY id DESC LIMIT ?")
  params <- c(params, list(limit))

  out <- tryCatch(DBI::dbGetQuery(con, sql, params = params),
                  error = function(e) NULL)
  if (is.null(out)) {
    return(data.frame(id = integer(0), at = character(0),
                      user_id = integer(0), email = character(0),
                      action = character(0), target = character(0),
                      detail = character(0), ok = integer(0),
                      ip = character(0), stringsAsFactors = FALSE))
  }
  out
}

#' 日志里**实际出现过**的动作码（给筛选下拉用）
#'
#' 用库里的实际值而不是 DSAPP_AUDIT_LABELS 的全部键：这个应用可能已经跑过
#' 一段时间，某些动作一次都没发生过，下拉里摆一排永远查不出东西的选项只会
#' 让人以为筛选坏了。
dsapp_audit_actions <- function(con = dsapp_db()) {
  out <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT action, COUNT(*) AS n FROM audit_log GROUP BY action
       ORDER BY n DESC")$action,
    error = function(e) character(0))
  as.character(out %||% character(0))
}

#' 动作码的中文标签
#'
#' @return 和输入等长的字符向量。**不带 names**：命名向量的下标索引会把
#'   名字一起带出来，`identical(x, "上传文件")` 就是 FALSE —— 这种毛病在
#'   真值判断里看不出来（值是对的），只在严格比较时冒出来。
dsapp_audit_label <- function(action) {
  a <- as.character(action %||% "")
  lab <- unname(DSAPP_AUDIT_LABELS[a])
  ifelse(is.na(lab), a, lab)
}

#' 统计（管理页顶部那行小字用）
dsapp_audit_stats <- function(con = dsapp_db()) {
  out <- tryCatch(DBI::dbGetQuery(con,
    "SELECT COUNT(*) AS total,
            SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END) AS failed,
            MIN(at) AS first_at, MAX(at) AS last_at
       FROM audit_log"), error = function(e) NULL)
  if (is.null(out) || nrow(out) == 0) {
    return(list(total = 0L, failed = 0L, first_at = "", last_at = ""))
  }
  list(total = as.integer(out$total[1] %||% 0L),
       failed = as.integer(out$failed[1] %||% 0L),
       first_at = as.character(out$first_at[1] %||% ""),
       last_at = as.character(out$last_at[1] %||% ""))
}

#' 清理过期日志
#'
#' 启动时调一次（见 app.R）。不清理的话这张表会跟着应用一直长 —— 每条几十
#' 字节看着不多，但登录失败这类动作是**可以被外部触发**的（谁都能对着登录
#' 框刷），不设上限等于给了任何人一个写满磁盘的手段。
#'
#' 保留期用天数而不是条数：管理员查问题时问的是"上周三谁删的"，
#' "最近 5000 条"回答不了这个问题。
dsapp_audit_gc <- function(days = 180, con = dsapp_db()) {
  invisible(tryCatch({
    cut <- format(Sys.time() - days * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    n <- DBI::dbExecute(con, "DELETE FROM audit_log WHERE at < ?",
                        params = list(cut))
    as.integer(n)
  }, error = function(e) 0L))
}
