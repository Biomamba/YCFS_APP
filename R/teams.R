# =============================================================================
# 团队（V13 item 3）
# =============================================================================
# 用户的原话：「共享会话需要在组内账户可以选择，分享给其它账户需要手动填写。
# 所以你需要有一个团队管理系统和界面」。
#
# 要解决的是一个很具体的体验问题：现在共享对话框里是**全站所有账号**的一个
# 长名单，一个几十人的实例里找同事得在一堆陌生人里翻。而现实中的共享几乎
# 都发生在同一个课题组/同一个项目组内部 —— 常见的那些人应该是一个短名单，
# 一眼就点得到；偶发的、跨组的分享才值得动手打一遍邮箱。
#
# 所以这个文件只有两件事：
#   1. 团队本身（建组、改组名、加人、踢人）—— 给管理页用
#   2. 「谁和我同组」这一个查询 —— 给共享弹窗筛短名单用
#
# ⚠️ 团队**不是**权限单位。它只影响"共享弹窗里默认列谁"，**不**影响任何
#    一条授权判断 —— 判权限的自始至终只有 db_session_role()（见 db.R）。
#    这一点必须守住：把"同组"接进权限判断的话，某天有人调了一下分组，别人
#    手里正在跑的对话会**静默地**多出或失去访问权，而两件事在界面上看不出
#    关联。团队是"方便挑人"，共享是"明确授权"，两回事。
#
# ⚠️ 没有指向 users 的外键，理由同 tasks / session_share / session_skills
#    （见 dsapp_db_schema 的说明）：删账号要显式清一次 team_members，
#    别指望级联。dsapp_user_delete 里已经加了那一步。
# =============================================================================

dsapp_db_schema_teams <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS teams (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT NOT NULL,
      note       TEXT NOT NULL DEFAULT '',
      created_by INTEGER,
      created_at TEXT NOT NULL
    )")
  # 组名唯一。不唯一的话下拉框里会出现两个一模一样的组，加人的时候不知道
  # 加进了哪一个 —— 而两个组的成员看起来会"莫名其妙对不上"。
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_team_name ON teams(name)")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS team_members (
      team_id    INTEGER NOT NULL,
      user_id    INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (team_id, user_id)
    )")
  # 两个方向都要走：管理页按组列成员（team_id 是主键前缀，走主键就够），
  # 共享弹窗按**人**反查"我所在的组"（没有索引可用，单独建一个）。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_team_member_user ON team_members(user_id)")
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# 读
# ---------------------------------------------------------------------------

#' 全部团队，带成员数
#'
#' @return data.frame(id, name, note, created_by, created_at, n_members)；
#'   出错了返回 NULL
#'
#' ⚠️ `created_by` 是 V13.8 item 1 起才**读**的（写从 V13 起就有）。
#'    项目管理员的可见范围是"他建的组"，判据就在这一列上 —— 见
#'    mod_admin.R 的 teams() 和 R/users.R 的 dsapp_admin_scope_user_ids。
dsapp_teams_list <- function(con = dsapp_db()) {
  tryCatch(
    DBI::dbGetQuery(con, "
      SELECT t.id, t.name, t.note, t.created_by, t.created_at,
             (SELECT COUNT(*) FROM team_members m WHERE m.team_id = t.id)
               AS n_members
        FROM teams t
        ORDER BY t.name"),
    error = function(e) NULL)
}

#' 一个团队的成员 user_id（整数向量）
dsapp_team_members <- function(team_id, con = dsapp_db()) {
  r <- tryCatch(
    DBI::dbGetQuery(con, "SELECT user_id FROM team_members WHERE team_id = ?",
                    params = list(as.integer(team_id)))$user_id,
    error = function(e) integer(0))
  as.integer(r %||% integer(0))
}

#' 一个账号在哪些组里（整数向量）
dsapp_user_team_ids <- function(user_id, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(integer(0))
  r <- tryCatch(
    DBI::dbGetQuery(con, "SELECT team_id FROM team_members WHERE user_id = ?",
                    params = list(uid))$team_id,
    error = function(e) integer(0))
  as.integer(r %||% integer(0))
}

#' 和我同组的所有人（不含自己）
#'
#' 这是共享弹窗那个短名单的来源。**跨组取并集**：一个人在 A 组和 B 组里，
#' 那么 A 组和 B 组的成员都会看到他 —— 一个人同时属于多个课题组是常态。
#'
#' @return 整数向量（可能长度为 0）
dsapp_user_teammates <- function(user_id, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(integer(0))
  r <- tryCatch(
    DBI::dbGetQuery(con, "
      SELECT DISTINCT m2.user_id
        FROM team_members m1
        JOIN team_members m2 ON m2.team_id = m1.team_id
       WHERE m1.user_id = ? AND m2.user_id <> ?",
      params = list(uid, uid))$user_id,
    error = function(e) integer(0))
  as.integer(r %||% integer(0))
}

# ---------------------------------------------------------------------------
# 写
# ---------------------------------------------------------------------------

dsapp_team_fail <- function(msg) list(ok = FALSE, id = NA_integer_, msg = msg)

#' 建组 / 改组
#'
#' @param id NULL 表示新建，否则改这个组（组名和备注一起改）
dsapp_team_save <- function(id = NULL, name, note = "", by = NULL,
                            con = dsapp_db()) {
  name <- trimws(as.character(name %||% ""))
  note <- trimws(as.character(note %||% ""))
  if (!nzchar(name)) return(dsapp_team_fail("组名不能空着。"))
  if (nchar(name) > 60) return(dsapp_team_fail("组名太长了（最多 60 个字）。"))

  now <- dsapp_now()
  if (is.null(id) || is.na(suppressWarnings(as.integer(id)))) {
    r <- tryCatch({
      DBI::dbExecute(con,
        "INSERT INTO teams (name, note, created_by, created_at)
         VALUES (?, ?, ?, ?)",
        params = list(name, note, as.integer(by %||% NA_integer_), now))
      as.integer(DBI::dbGetQuery(con, "SELECT last_insert_rowid()")[[1]])
    }, error = function(e) e)
    if (inherits(r, "error")) {
      # 撞唯一索引给的是 SQLite 的英文原文（UNIQUE constraint failed），
      # 直接抛给用户看不懂。重名是这里唯一现实的失败原因，单独翻译一句。
      if (grepl("UNIQUE", conditionMessage(r), ignore.case = TRUE)) {
        return(dsapp_team_fail(sprintf("已经有一个叫「%s」的组了。", name)))
      }
      return(dsapp_team_fail(paste("建组失败：", conditionMessage(r))))
    }
    return(list(ok = TRUE, id = r, msg = sprintf("已建组「%s」", name)))
  }

  tid <- as.integer(id)
  r <- tryCatch(
    DBI::dbExecute(con, "UPDATE teams SET name = ?, note = ? WHERE id = ?",
                   params = list(name, note, tid)),
    error = function(e) e)
  if (inherits(r, "error")) {
    if (grepl("UNIQUE", conditionMessage(r), ignore.case = TRUE)) {
      return(dsapp_team_fail(sprintf("已经有一个叫「%s」的组了。", name)))
    }
    return(dsapp_team_fail(paste("保存失败：", conditionMessage(r))))
  }
  if (!isTRUE(r >= 1)) return(dsapp_team_fail("这个组已经不在了，刷新看看。"))
  list(ok = TRUE, id = tid, msg = sprintf("已保存「%s」", name))
}

#' 删组
#'
#' ⚠️ 成员关系和共享**都要一起清**，而且是显式清。共享不清的话，那些对话
#'    还挂在别人名下，而"为什么他还看得到"就再也解释不清了 —— 组已经没了。
dsapp_team_delete <- function(id, con = dsapp_db()) {
  tid <- suppressWarnings(as.integer(id))
  if (is.na(tid)) return(dsapp_team_fail("没指定要删哪个组。"))
  try(DBI::dbExecute(con, "DELETE FROM team_members WHERE team_id = ?",
                     params = list(tid)), silent = TRUE)
  n <- tryCatch(DBI::dbExecute(con, "DELETE FROM teams WHERE id = ?",
                               params = list(tid)),
                error = function(e) 0L)
  if (!isTRUE(n >= 1)) return(dsapp_team_fail("这个组已经不在了，刷新看看。"))
  list(ok = TRUE, id = tid, msg = "已删除该组")
}

#' 整批设定一个组的成员
#'
#' 用"整批替换"而不是"逐个加/删"：管理页上就是一组勾选框，点保存时界面
#' 交上来的就是最终名单。做成增量的话，两个管理员同时改会得到一个谁也
#' 没想要的结果，而且没有报错。
#'
#' @return 实际写入的人数；出错返回 NULL
dsapp_team_set_members <- function(team_id, user_ids, con = dsapp_db()) {
  tid <- suppressWarnings(as.integer(team_id))
  if (is.na(tid)) return(NULL)
  ids <- suppressWarnings(as.integer(user_ids %||% integer(0)))
  ids <- unique(ids[!is.na(ids)])
  now <- dsapp_now()
  tryCatch({
    DBI::dbExecute(con, "DELETE FROM team_members WHERE team_id = ?",
                   params = list(tid))
    if (length(ids)) {
      # 一条 INSERT + 多个 VALUES，别在循环里逐条打库。
      vals <- paste(sprintf("(%d, %d, %s)", tid, ids,
                            DBI::dbQuoteString(con, now)), collapse = ",")
      DBI::dbExecute(con, paste0(
        "INSERT OR IGNORE INTO team_members (team_id, user_id, created_at)
         VALUES ", vals))
    }
    length(ids)
  }, error = function(e) NULL)
}

#' 把某个人从所有组里摘掉（删账号时用）
dsapp_team_remove_user <- function(user_id, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(invisible(0L))
  n <- tryCatch(DBI::dbExecute(con, "DELETE FROM team_members WHERE user_id = ?",
                               params = list(uid)),
                error = function(e) 0L)
  invisible(as.integer(n %||% 0L))
}

# ---------------------------------------------------------------------------
# 管理页那段界面
# ---------------------------------------------------------------------------

#' 表格里那一行的「改」/「删」按钮
#'
#' ⚠️ 这里**不能**用 `actionButton(ns(paste0("team_del_", id)))` 那种"每行一个
#'    id"的写法。那种写法要求服务端动态地 observe 一批会变的 input id，
#'    而 observeEvent 在**输入列表本身变化**时也会重新触发一次 —— 删掉一个组
#'    之后列表变了，观察者又跑一遍，看见上一颗按钮还停在 1，于是把刚删掉的
#'    组再删一次（报"这个组已经不在了"）。加个"已处理过"的记性也能修，但那
#'    是在给一个本来就不该有的状态擦屁股。
#'
#'    改成往**同一个** input 里塞一个带随机数的对象：值每次都不同，所以每次
#'    点击都会触发；服务端只看 `id` 决定操作谁。随机数是必需的 —— 只用 id 的话，
#'    连点两次同一个按钮，第二次的值和第一次一样，Shiny 认为"没变"就不会触发。
dsapp_team_row_btn <- function(ns, input_id, team_id, label, cls) {
  tags$button(
    type = "button",
    class = paste("btn btn-sm", cls),
    onclick = sprintf(
      "Shiny.setInputValue('%s', {id: %d, n: Math.random()}, {priority: 'event'});",
      ns(input_id), as.integer(team_id)),
    label)
}

#' 团队管理面板
#'
#' 放在管理页里，和「账号」并列。只有管理员进得来（调用方负责判）。
#'
#' @param ns 命名空间函数
#' @param users dsapp_users_list() 的结果（用来画加人的勾选框）
#' @param teams dsapp_teams_list() 的结果
#' @param edit_id 当前正在编辑哪个组（NULL = 只看列表 / 新建）
dsapp_teams_panel <- function(ns, users, teams, edit_id = NULL) {
  if (is.null(users) || nrow(users) == 0) {
    return(div(class = "text-muted small", "还没有账号，先建一个账号再来分组。"))
  }
  # 候选人的标签带邮箱：昵称可以重名也可以留空，邮箱不会。
  all_choices <- stats::setNames(
    as.character(users$id),
    sprintf("%s（%s）", users$nickname, users$email))

  cur <- NULL
  if (!is.null(edit_id) && !is.null(teams) && nrow(teams)) {
    hit <- which(teams$id == as.integer(edit_id))
    if (length(hit)) cur <- teams[hit[1], , drop = FALSE]
  }
  sel <- if (is.null(cur)) character(0) else
    as.character(dsapp_team_members(cur$id))

  tagList(
    div(class = "small text-muted mb-2",
      icon("circle-info"), " 团队只决定「共享对话框里默认列出谁」，",
      tags$b("不决定谁能看什么"), "。真正给权限的是共享本身。"),

    if (!is.null(teams) && nrow(teams)) {
      tags$table(class = "table table-sm align-middle",
        tags$thead(tags$tr(tags$th("组名"), tags$th("人数"),
                           tags$th("备注"), tags$th(""))),
        tags$tbody(lapply(seq_len(nrow(teams)), function(i) {
          r <- teams[i, , drop = FALSE]
          tags$tr(
            tags$td(tags$b(r$name[[1]])),
            tags$td(as.character(r$n_members[[1]])),
            tags$td(class = "small text-muted", r$note[[1]]),
            tags$td(
              dsapp_team_row_btn(ns, "team_edit_id", r$id[[1]], "改",
                                 "btn-outline-secondary"),
              dsapp_team_row_btn(ns, "team_del_id", r$id[[1]], "删",
                                 "btn-outline-danger"))
          )
        })))
    } else {
      div(class = "text-muted small mb-2", "还没有团队。")
    },

    tags$hr(),
    tags$h6(if (is.null(cur)) "新建团队" else
      sprintf("编辑「%s」", cur$name[[1]])),
    textInput(ns("team_name"), "组名",
              value = if (is.null(cur)) "" else cur$name[[1]],
              placeholder = "例如：张老师课题组", width = "100%"),
    textInput(ns("team_note"), "备注（可选）",
              value = if (is.null(cur)) "" else cur$note[[1]],
              width = "100%"),
    checkboxGroupInput(ns("team_members"), "组内账号",
                       choices = all_choices, selected = sel),
    div(class = "d-flex gap-2",
      actionButton(ns("team_save"),
                   if (is.null(cur)) "建组" else "保存",
                   class = "btn-primary btn-sm"),
      if (!is.null(cur))
        actionButton(ns("team_cancel"), "取消编辑",
                     class = "btn-link btn-sm"))
  )
}
