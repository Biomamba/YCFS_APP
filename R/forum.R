# =============================================================================
# 论坛（V15 item 8）
# =============================================================================
# 用户原话：「加一个论坛页面，用户能交流自己使用过程中的经验或遇到的问题。
# 你需要考虑好同步问题，现有的账户体系是靠什么为枢纽进行同步的？」
#
# 这个问题本身有一半是**考据题**，答案写在 SYNC.md 第九节，一句话版：
#
#   枢纽是 **users.email**（归一化小写）那**一列**。
#   不是 users.id —— 那是 INTEGER PRIMARY KEY AUTOINCREMENT，每台机器各自
#   从 1 开始，笔记本上的 7 号和服务器上的 7 号是两个人（SYNC.md §2.1）。
#   跨机认账号只认邮箱：`.dsapp_sync_user_find()` 那句 SQL 就是
#   `WHERE lower(email) = ?`，全仓库只有这一处认账号。
#
# 于是论坛这一层所有的"这个人是谁"都按 email 记，见下面 §一。
#
# -----------------------------------------------------------------------------
# 一、论坛和数据同步那套东西的关系（这一节是设计，不是实现说明）
# -----------------------------------------------------------------------------
#
# 论坛和"对话"有一个根本差别，绕不开：
#
#   · 对话是**私有的、按账号的** —— 同步的语义是"我的数据跟着我走"，
#     主语是**一个账号**，所以 `dsapp_sync_collect(user_id)` 第一件事就是
#     按 user_id 筛，包也按账号签。
#   · 论坛是**公共的、一对多的** —— 主语是**所有账号**。A 发的帖要出现在
#     B 和 C 的界面上，而 A 既不知道 B 是谁，也没有 B 的密钥。
#
# 所以论坛**不能**照搬对话那条"按账号打包"的路。这里做的三件事是：
#
#   1. **公共段**：包里多一个 `forum` 段，**不按 user_id 筛**，只按水位筛。
#      收端应用时按行自己的全局身份去重，天然幂等（见 §二）。
#   2. **枢纽仍是 email**：`author_email` / `user_email` 是跨机唯一的那个人。
#      `author_uid`（本地 users.id）只在**本机**用来连表显示昵称头像，
#      **不过网** —— 过了网就是 §2.1 那个撞号。
#   3. **软删**：删除是行上的一个状态，不是行的消失。于是论坛**完全不需要
#      墓碑**（`sync_tombstone` 那套是给硬 DELETE 补的，见 SYNC.md §2.2）。
#      这一条是论坛和会话在实现上最大的分歧点，也是它比会话简单的地方。
#
# -----------------------------------------------------------------------------
# 二、行的身份：`(origin_node, origin_id)`，**不进 sync_map**
# -----------------------------------------------------------------------------
# 会话那套要用 `sync_map` 是因为它的行身份是**本地自增 id**，跨机必撞，
# 所以需要一张翻译表把"你那边第 7 条"翻译成"我这边第 42 条"。
#
# 论坛自带一对**全局唯一的行身份**：`(origin_node, origin_id)` =
# 「造出这一行的节点」+「它在那台机器上的 id」。两个节点不可能造出同一对，
# 所以：
#
#   · **不需要 sync_map**，收端直接 `INSERT ... ON CONFLICT(origin_node,
#     origin_id) DO UPDATE` 就对了，重复收到同一个包不会插出两份；
#   · 转发天然成立 —— 一行从 B 转给 C，它带的那对身份不变，C 认的还是
#     「A 造的」。
#
# ⚠️ 这和 V13.3→V13.7 那一整段踩坑史是同一个道理（SYNC.md §4.5/§7.1）：
#    **身份必须跟着行走**。论坛是天生带身份的，这算它比会话好写的地方。
#
# ⚠️ 但 `origin_id` **只在造它的那个节点上等于本地 id**。别在别的节点上
#    拿它当主键用 —— 显示、跳转一律用本地 `id`，过网一律用那一对。
#
# -----------------------------------------------------------------------------
# 三、帖子 ↔ 回复：**不用本地外键**
# -----------------------------------------------------------------------------
# 回复挂在帖子上。直觉是 `forum_posts.thread_id REFERENCES forum_threads(id)`
# —— 那是错的，而且错得很安静：
#
#   · 库里**唯一一个外键**是 messages.session_id（R/db.R），它带来一条硬
#     约束：**必须先有 sessions 行才能插 messages**。论坛照抄的话，一个包里
#     回复先到、帖后到（分页截断、或者两个包）就是外键报错 —— 而报错点在
#     收端应用循环里，整包应用会中断。
#   · 更要命的是**跨节点对不上**：帖子的本地 id 在 A 是 5、在 B 是 42。
#     A 推上来的回复里带的 thread_id=5，在 B 那边指向的是**另一条帖**。
#
# 所以回复挂的是帖子的**全局身份**：`(thread_onode, thread_oid)`。
# 取回复的 SQL 就是 `WHERE thread_onode=? AND thread_oid=?`，一个索引搞定，
# 没有外键、没有先后顺序、没有翻译表。显示时如果想拿帖子的标题，再 JOIN
# 一次同两张列即可。
#
# -----------------------------------------------------------------------------
# 四、几处"看起来该同步、其实不能同步"的
# -----------------------------------------------------------------------------
#   · `views`（浏览量）**只在本机累加，不过网**。理由不是省事：每次浏览都
#     改行的话，`updated_at` 一被推高，这一行就会**重新发给所有人**，
#     于是"有人看了一眼"变成一次全站同步。而且两台机器的浏览量本来就
#     没有可加性（同一个人在两台机器上各看一次算两次）。真要合并计数，
#     得单独做一张只增不改的浏览表 —— 这一版不做，界面上写的是"本机浏览量"。
#   · `n_replies` / `n_likes` **不存**，每次都现算。存下来的话它就是一份
#     缓存，而它会在"回复到了、帖子还没到"这种半包状态下变成错的数字，
#     而且不会被任何东西修正。
#   · 点赞（`forum_marks`）**同步**，但走的是另一条路：它的身份是
#     `(kind, target_onode, target_oid, user_email)` —— 四列全是天然的、
#     全局唯一的，所以它既不需要 origin 也不需要 sync_map，直接 UPSERT。
#     取消点赞写成 `value = 0` 而不是 DELETE 行 —— 又一次绕开墓碑。
# =============================================================================

# ---- 分类 -------------------------------------------------------------------

#' 论坛板块
#'
#' ⚠️ `value` 是**存进库、过网、并且被 URL/input name 用到**的东西，改它
#'    等于改协议：老行会变成"没有分类"（列表里那一项筛不出来），而且两端
#'    版本不一致时对不上。标题（label）随便改。
DSAPP_FORUM_CATS <- list(
  list(value = "share",   label = "经验分享",       icon = "lightbulb"),
  list(value = "ask",     label = "提问求助",       icon = "circle-question"),
  list(value = "pitfall", label = "踩坑记录",       icon = "triangle-exclamation"),
  list(value = "skill",   label = "技能与提示词",   icon = "wand-magic-sparkles"),
  # 公告只有管理员能发（见 dsapp_forum_thread_new 里的 can_notice）。
  # ⚠️ 它排最后是有意的：默认发帖分类取的是**第一个**（经验分享），
  #    把公告放第一个的话，手快点一下发出去的就是一条"公告"。
  list(value = "notice",  label = "公告",           icon = "bullhorn",
       admin = TRUE)
)

DSAPP_FORUM_CAT_VALUES <- vapply(DSAPP_FORUM_CATS,
                                 function(x) x$value, character(1))

#' 分类 value → 中文名
#'
#' ⚠️ 认不出来时**原样返回那个 value**，不要返回空串。库里可能存着一个
#'    这个版本还不认识的分类（对端版本更新、或者有人手改了库），返回空串
#'    的话列表上那一行的分类标签就是一片空白 —— 看起来像渲染坏了。
dsapp_forum_cat_label <- function(v) {
  v <- as.character(v %||% "")
  for (c in DSAPP_FORUM_CATS) if (identical(c$value, v)) return(c$label)
  v
}

dsapp_forum_cat_icon <- function(v) {
  v <- as.character(v %||% "")
  for (c in DSAPP_FORUM_CATS) if (identical(c$value, v)) return(c$icon)
  "comment-dots"
}

#' 发帖时能选的分类（公告要管理员）
dsapp_forum_cat_choices <- function(is_admin = FALSE) {
  keep <- Filter(function(c) isTRUE(is_admin) || !isTRUE(c$admin),
                 DSAPP_FORUM_CATS)
  stats::setNames(vapply(keep, function(c) c$value, character(1)),
                  vapply(keep, function(c) c$label, character(1)))
}

# ---- 帖子状态 ---------------------------------------------------------------

# open    正常
# solved  提问已解决（只有提问用得上，但任何分类都能标）
# closed  已关闭，不再接受新回复（作者或管理员）
# hidden  被管理员隐藏（内容还在，作者自己看得见，别人看不见）
# deleted 已删除（软删；**终态**，见 dsapp_forum_apply 里那条 LWW 例外）
DSAPP_FORUM_TSTATUS <- c("open", "solved", "closed", "hidden", "deleted")

# 回复的状态：没有 solved/closed，那两个是帖子级的
DSAPP_FORUM_PSTATUS <- c("ok", "hidden", "deleted")

#' 这个状态下，**除作者和管理员之外**的人还看不看得见
#'
#' 写成纯函数是为了自检够得着 —— 列表页那条 SQL 里的 `status NOT IN (...)`
#' 和这里是同一件事的两份表达，必须一起改。
dsapp_forum_visible <- function(status, is_mod = FALSE, is_mine = FALSE) {
  if (isTRUE(is_mod) || isTRUE(is_mine)) return(TRUE)
  !as.character(status %||% "") %in% c("hidden", "deleted")
}

# ---- 限额 -------------------------------------------------------------------

# 正文长度。为什么是这几个数：
#   · 标题 120 —— 列表一行放得下，也够写清"什么情况下报的什么错"；
#   · 正文 20000 —— 一次完整的报错栈 + 复现步骤 + 代码，再长就该传文件了；
#   · 标签 120、最多 6 个 —— 标签是用来筛的，不是用来堆的。
DSAPP_FORUM_MAX_TITLE <- 120L
DSAPP_FORUM_MAX_BODY  <- 20000L
DSAPP_FORUM_MAX_TAGS  <- 120L
DSAPP_FORUM_MAX_TAGN  <- 6L

# 同一个人的发帖间隔（秒）。防的是"按住回车刷屏"和脚本循环发帖。
# ⚠️ 判据是**这个人的最后一条**（帖子或回复都算），不是"每个帖子"。
#    取值小到正常人感觉不到（10 秒写不完一个标题），大到刷屏会卡住。
DSAPP_FORUM_COOLDOWN <- 10L

# ---- 建表 -------------------------------------------------------------------

#' 论坛建表（幂等）
#'
#' 挂在 dsapp_db_schema() 里（R/db.R），和技能、审计、团队那几张表一个路子：
#' 任何一次 dsapp_db() 都会补齐，老库升级上来不用手工跑迁移。
#'
#' ⚠️ `origin_id` 存**文本**。和 sync_map 那两列同一个理由（R/db.R 里
#'    sync_map 那段注释）：这个库里的主键类型本来就不统一，而且论坛以后
#'    万一要换成 `dsapp_id("f")` 那种 TEXT id，存 INTEGER 的列会**静默**
#'    把 'f-2026...' 变成 2026（SQLite 的类型亲和性）。
dsapp_db_schema_forum <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS forum_threads (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      origin_node  TEXT NOT NULL DEFAULT '',
      origin_id    TEXT NOT NULL DEFAULT '',
      title        TEXT NOT NULL DEFAULT '',
      body         TEXT NOT NULL DEFAULT '',
      category     TEXT NOT NULL DEFAULT 'ask',
      tags         TEXT NOT NULL DEFAULT '',
      author_email TEXT NOT NULL DEFAULT '',
      author_name  TEXT NOT NULL DEFAULT '',
      status       TEXT NOT NULL DEFAULT 'open',
      pinned       INTEGER NOT NULL DEFAULT 0,
      views        INTEGER NOT NULL DEFAULT 0,
      created_at   TEXT NOT NULL DEFAULT '',
      updated_at   TEXT NOT NULL DEFAULT ''
    )")
  # ★ 这一对是论坛整套东西的**唯一行身份**。UNIQUE 不只是"防重复"——
  #   它是 `ON CONFLICT(...) DO UPDATE` 那句 UPSERT 的落点，也是
  #   "同一个包应用两次结果一样"（幂等）的全部依据。删了它，重复投递的包
  #   会在库里插出两份，而且两边都不报错。
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_forum_th_oid
       ON forum_threads(origin_node, origin_id)")
  # 列表页的排序键。三列分开建而不是一个复合索引：三个排序各用各的。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_th_upd ON forum_threads(updated_at)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_th_cat ON forum_threads(category)")
  # 按作者筛（"我的帖子"）。按 email 建，因为那才是跨机的那个人。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_th_author ON forum_threads(author_email)")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS forum_posts (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      origin_node     TEXT NOT NULL DEFAULT '',
      origin_id       TEXT NOT NULL DEFAULT '',
      thread_onode    TEXT NOT NULL DEFAULT '',
      thread_oid      TEXT NOT NULL DEFAULT '',
      body            TEXT NOT NULL DEFAULT '',
      author_email    TEXT NOT NULL DEFAULT '',
      author_name     TEXT NOT NULL DEFAULT '',
      reply_to_onode  TEXT NOT NULL DEFAULT '',
      reply_to_oid    TEXT NOT NULL DEFAULT '',
      status          TEXT NOT NULL DEFAULT 'ok',
      created_at      TEXT NOT NULL DEFAULT '',
      updated_at      TEXT NOT NULL DEFAULT ''
    )")
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_forum_po_oid
       ON forum_posts(origin_node, origin_id)")
  # ★ 取一层楼的回复就靠这个索引。它服务的是**显示路径上每开一条帖都要跑
  #   一次**的查询（列表页还要对每一行跑一次子查询数回复数），没有它
  #   就是全表扫 forum_posts。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_po_thread
       ON forum_posts(thread_onode, thread_oid)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_po_upd ON forum_posts(updated_at)")

  # 点赞 / "有用"。★ 四列联合主键就是这一行的**全局身份**，所以它不需要
  # origin 那两列、也不需要 sync_map —— 同一个赞从任何路径收到多少次，
  # UPSERT 之后都只有一行。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS forum_marks (
      kind         TEXT NOT NULL DEFAULT '',
      target_onode TEXT NOT NULL DEFAULT '',
      target_oid   TEXT NOT NULL DEFAULT '',
      user_email   TEXT NOT NULL DEFAULT '',
      value        INTEGER NOT NULL DEFAULT 1,
      created_at   TEXT NOT NULL DEFAULT '',
      updated_at   TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (kind, target_onode, target_oid, user_email)
    )")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_forum_mk_upd ON forum_marks(updated_at)")

  invisible(TRUE)
}

# ---- 小工具 -----------------------------------------------------------------

#' 一行论坛记录的全局身份串
#'
#' `.dsapp_sync_skey` 是同步那套里同形状的工具（R/sync.R），但它是内部
#' 函数、而且分隔符的选择和这里无关，所以各写各的。**分隔符不能出现在
#' node id 里** —— node id 是 hex（R/sync.R 的 dsapp_sync_node_id 生成的），
#' 冒号是安全的。
#' @return "node:id"，两边有一边为空时返回 NA_character_
dsapp_forum_key <- function(onode, oid) {
  onode <- trimws(as.character(onode %||% ""))
  oid   <- trimws(as.character(oid %||% ""))
  if (!nzchar(onode) || !nzchar(oid)) return(NA_character_)
  paste0(onode, ":", oid)
}

#' 把 "node:id" 拆回去
#'
#' ⚠️ 用**第一个**冒号切（`strsplit` 默认就是从头开始匹配），并且只取前两
#'    段。node id 里现在是不会有冒号的，但把 id 部分写成 `paste(rest,
#'    collapse=":")` 比"假设它一定不含冒号"便宜 —— 后者在有人换了 node id
#'    格式之后会**静默**把 id 截断，表现是"点进去是另一条帖"。
dsapp_forum_unkey <- function(k) {
  k <- as.character(k %||% "")
  if (!nzchar(k) || is.na(k)) return(c(node = "", id = ""))
  parts <- strsplit(k, ":", fixed = TRUE)[[1]]
  if (length(parts) < 2) return(c(node = "", id = ""))
  c(node = parts[1], id = paste(parts[-1], collapse = ":"))
}

#' 现在的发帖人是谁（统一从 state$user 那一份取）
#'
#' ★ 这是**唯一**一处把"当前用户"翻译成论坛要的那两列。所有写库的路都必须
#'   经过它，理由是 author_email 是枢纽：某处图省事写成 `user$id`（本地
#'   id）的话，那一行到了对端就**认不出是谁**，而且不报错。
#'
#' ⚠️ 邮箱**必须**和登录那边用同一把尺子（`.dsapp_sync_user_find` 那句
#'    `lower(email)`、`dsapp_user_norm_email`）—— 大小写不统一的话，
#'    "我的帖子"筛不出来、跨机认不出同一个人，而且全程无声。
#' @return list(email, name, uid)，认不出来的账号 email 为空串
dsapp_forum_author <- function(user = NULL) {
  email <- tolower(trimws(as.character(user$email %||% "")))
  list(email = email,
       name  = trimws(as.character(user$nickname %||% "")) %||% "",
       uid   = suppressWarnings(as.integer(user$id %||% NA_integer_)))
}

#' 文本归一化：去首尾空格、把 CRLF 压成 LF
#'
#' ⚠️ `\r` 一定要去掉。用户从 Windows 的记事本/微信里粘一段报错进来，那
#'    段文本带着 `\r\n`；存进库、渲染成 Markdown 之后，行尾的 `\r` 在
#'    浏览器里表现为"多一个看不见的字符"，而它会让**两端内容不同**——
#'    同一个帖子在两台机器上 `updated_at` 一样但正文差一个字节，LWW 会
#'    一直判"对方更新"，来回推。这类问题不报错，只是永远同步不完。
dsapp_forum_norm <- function(x, max = NULL) {
  x <- as.character(x %||% "")
  if (!length(x)) return("")
  x <- gsub("\r\n", "\n", x, fixed = TRUE)
  x <- gsub("\r", "\n", x, fixed = TRUE)
  x <- trimws(x)
  if (!is.null(max)) x <- substr(x, 1L, as.integer(max))
  x
}

#' 标签串归一化：逗号/顿号/分号/换行都当分隔符，去重、保序、封顶
#'
#' ⚠️ 按**空格**切是错的（同 dsapp_lit_keywords 那条注释）："single cell"
#'    是一个标签。用户想分开就自己打逗号。
dsapp_forum_tags <- function(x) {
  x <- dsapp_forum_norm(x, DSAPP_FORUM_MAX_TAGS * 4L)
  if (!nzchar(x)) return("")
  parts <- unlist(strsplit(x, "[,，、;；\n]+"))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  parts <- unique(substr(parts, 1L, 24L))
  paste(utils::head(parts, DSAPP_FORUM_MAX_TAGN), collapse = ",")
}

# ---- 写：发帖 / 回复 ---------------------------------------------------------

#' 这个账号最近有没有发过东西（限流用）
#'
#' @return 距离上一次发言的秒数；没发过返回 Inf
.dsapp_forum_since_last <- function(email, con) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email)) return(Inf)
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT MAX(t) AS t FROM (
       SELECT MAX(created_at) AS t FROM forum_threads WHERE author_email = ?
       UNION ALL
       SELECT MAX(created_at) AS t FROM forum_posts  WHERE author_email = ?)",
    params = list(email, email)), error = function(e) NULL)
  if (is.null(r) || !nrow(r) || is.na(r$t[1]) || !nzchar(r$t[1])) return(Inf)
  # 两边都是 dsapp_now() 写的 "YYYY-MM-DD HH:MM:SS"（UTC），可以直接转
  t0 <- suppressWarnings(as.POSIXct(r$t[1], tz = "UTC"))
  if (is.na(t0)) return(Inf)
  as.numeric(difftime(Sys.time(), t0, units = "secs"))
}

#' 发一条新帖
#'
#' @param cfg ⚠️ **必须由调用方传进来**，理由和 db_session_delete() 那条
#'   一样（SYNC.md §7.5）：`dsapp_config()` 给的是**进程默认**那个 data_root，
#'   而这里要用它去取 node id。取错了不会报错，只会把这一行的出身记成
#'   **别的节点** —— 于是它同步出去之后，对端按 (origin_node, origin_id)
#'   去重时认不出自己发的那一条，**每次同步都插一份新的**。
#' @return list(ok, id, msg)
dsapp_forum_thread_new <- function(title, body, category = "ask", tags = "",
                                   user = NULL, is_admin = FALSE,
                                   cfg = dsapp_config(), con = dsapp_db(cfg)) {
  a <- dsapp_forum_author(user)
  if (!nzchar(a$email)) {
    return(list(ok = FALSE, msg = "认不出当前账号，先重新登录一次。"))
  }
  title <- dsapp_forum_norm(title, DSAPP_FORUM_MAX_TITLE)
  body  <- dsapp_forum_norm(body,  DSAPP_FORUM_MAX_BODY)
  if (!nzchar(title)) return(list(ok = FALSE, msg = "标题不能是空的。"))
  if (!nzchar(body))  return(list(ok = FALSE, msg = "正文不能是空的。"))
  category <- as.character(category %||% "ask")
  if (!category %in% DSAPP_FORUM_CAT_VALUES) category <- "ask"
  # 公告只有管理员能发。⚠️ 这里是**服务端**的判据，不是"界面上没给他这个
  #    选项"—— 界面那层是体验，这层才是规则。
  if (identical(category, "notice") && !isTRUE(is_admin)) {
    return(list(ok = FALSE, msg = "「公告」只有管理员能发。"))
  }
  gap <- .dsapp_forum_since_last(a$email, con)
  if (is.finite(gap) && gap < DSAPP_FORUM_COOLDOWN) {
    return(list(ok = FALSE,
                msg = sprintf("发得太快了，%d 秒后再试。",
                              ceiling(DSAPP_FORUM_COOLDOWN - gap))))
  }

  node <- tryCatch(dsapp_sync_node_id(cfg), error = function(e) "")
  if (!nzchar(node)) return(list(ok = FALSE, msg = "本机还没有节点标识，发不了帖。"))
  now <- dsapp_now()

  ok <- tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO forum_threads
         (origin_node, origin_id, title, body, category, tags,
          author_email, author_name, status, pinned, views,
          created_at, updated_at)
       VALUES (?, '', ?, ?, ?, ?, ?, ?, 'open', 0, 0, ?, ?)",
      params = list(node, title, body, category, dsapp_forum_tags(tags),
                    a$email, a$name, now, now))
    TRUE
  }, error = function(e) {
    message("[dsapp] 发帖失败：", conditionMessage(e))
    FALSE
  })
  if (!isTRUE(ok)) return(list(ok = FALSE, msg = "写库失败，看一眼日志。"))

  # ★ origin_id = 本地 id。分两步写是**故意**的：AUTOINCREMENT 的 id 只有
  #   INSERT 之后才知道，而本地 id 恰好是一个"在这台机器上唯一、且永不复用"
  #   （AUTOINCREMENT 保证不复用）的值，拿它当初次出身最省事。
  #   ⚠️ 别改成"先 SELECT max(id)+1 再插" —— 那是竞态，两个人同时发帖会
  #   拿到同一个 origin_id，而 UNIQUE 索引会**让第二个人发帖失败**，
  #   错误信息还看不出是并发引起的。
  id <- tryCatch(DBI::dbGetQuery(con,
    "SELECT id FROM forum_threads WHERE origin_node = ? AND created_at = ?
       AND author_email = ? ORDER BY id DESC LIMIT 1",
    params = list(node, now, a$email))$id[1], error = function(e) NA_integer_)
  if (!is.na(id)) {
    try(DBI::dbExecute(con,
      "UPDATE forum_threads SET origin_id = ? WHERE id = ?",
      params = list(as.character(id), as.integer(id))), silent = TRUE)
  }
  list(ok = TRUE, id = id, msg = "已发布")
}

#' 回一条（`reply_to` 非空 = 楼中楼，引用某一层）
#'
#' @param thread_onode,thread_oid 帖子的**全局身份**（不是本地 id，见文件头 §三）
dsapp_forum_post_new <- function(thread_onode, thread_oid, body,
                                 reply_to_onode = "", reply_to_oid = "",
                                 user = NULL, cfg = dsapp_config(),
                                 con = dsapp_db(cfg)) {
  a <- dsapp_forum_author(user)
  if (!nzchar(a$email)) {
    return(list(ok = FALSE, msg = "认不出当前账号，先重新登录一次。"))
  }
  body <- dsapp_forum_norm(body, DSAPP_FORUM_MAX_BODY)
  if (!nzchar(body)) return(list(ok = FALSE, msg = "回复不能是空的。"))
  key <- dsapp_forum_key(thread_onode, thread_oid)
  if (is.na(key)) return(list(ok = FALSE, msg = "这条帖子的身份不完整，回不了。"))

  # 帖子得在、而且得能回。⚠️ 这三条检查必须在**服务端**做：界面上"关闭的
  # 帖子不显示回复框"只是体验，绕过界面直接发一个 input 是很容易的事。
  th <- tryCatch(DBI::dbGetQuery(con,
    "SELECT status FROM forum_threads WHERE origin_node = ? AND origin_id = ?",
    params = list(as.character(thread_onode),
                  as.character(thread_oid))), error = function(e) NULL)
  if (is.null(th) || !nrow(th)) {
    return(list(ok = FALSE, msg = "这条帖子在本机还没有，等同步过来再回。"))
  }
  st <- as.character(th$status[1])
  if (identical(st, "closed") || identical(st, "deleted") || identical(st, "hidden")) {
    return(list(ok = FALSE, msg = "这条帖子已经不能回复了。"))
  }
  gap <- .dsapp_forum_since_last(a$email, con)
  if (is.finite(gap) && gap < DSAPP_FORUM_COOLDOWN) {
    return(list(ok = FALSE,
                msg = sprintf("发得太快了，%d 秒后再试。",
                              ceiling(DSAPP_FORUM_COOLDOWN - gap))))
  }

  node <- tryCatch(dsapp_sync_node_id(cfg), error = function(e) "")
  if (!nzchar(node)) return(list(ok = FALSE, msg = "本机还没有节点标识，回不了帖。"))
  now <- dsapp_now()

  ok <- tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO forum_posts
         (origin_node, origin_id, thread_onode, thread_oid, body,
          author_email, author_name, reply_to_onode, reply_to_oid,
          status, created_at, updated_at)
       VALUES (?, '', ?, ?, ?, ?, ?, ?, ?, 'ok', ?, ?)",
      params = list(node, as.character(thread_onode), as.character(thread_oid),
                    body, a$email, a$name,
                    as.character(reply_to_onode %||% ""),
                    as.character(reply_to_oid %||% ""), now, now))
    TRUE
  }, error = function(e) {
    message("[dsapp] 回复失败：", conditionMessage(e))
    FALSE
  })
  if (!isTRUE(ok)) return(list(ok = FALSE, msg = "写库失败，看一眼日志。"))

  # ★ 回复也会推高**帖子**的 updated_at。
  #   为什么必须推：列表页按"最新回复"排序，而且同步的水位是按行自己的
  #   updated_at 走的 —— 帖子行不动的话，"有人回了你的帖"这件事传不到
  #   对端（对端只看到一条新的 post 行，列表排序不会变）。
  #   ⚠️ 推的时候**只动 updated_at**，别顺手把行整个 UPDATE 一遍：
  #   那会把正文一起写一次，两端如果正文有细微差别就会互相覆盖。
  id <- tryCatch(DBI::dbGetQuery(con,
    "SELECT id FROM forum_posts WHERE origin_node = ? AND created_at = ?
       AND author_email = ? ORDER BY id DESC LIMIT 1",
    params = list(node, now, a$email))$id[1], error = function(e) NA_integer_)
  if (!is.na(id)) {
    try(DBI::dbExecute(con, "UPDATE forum_posts SET origin_id = ? WHERE id = ?",
                       params = list(as.character(id), as.integer(id))),
        silent = TRUE)
  }
  try(DBI::dbExecute(con,
    "UPDATE forum_threads SET updated_at = ?
      WHERE origin_node = ? AND origin_id = ? AND updated_at < ?",
    params = list(now, as.character(thread_onode),
                  as.character(thread_oid), now)), silent = TRUE)

  list(ok = TRUE, id = id, msg = "已回复")
}

# ---- 写：改 / 删 / 状态 ------------------------------------------------------

#' 改一条帖子（只有作者或管理员）
#'
#' ⚠️ 改的时候**不碰** `origin_node` / `origin_id` —— 那是行的身份，动了
#'    等于换了一行：对端会当成一条**新帖**插进来，原来的那条还留着。
#'    这是"看起来只是多 UPDATE 了一列"的那类 bug。
dsapp_forum_thread_edit <- function(onode, oid, title = NULL, body = NULL,
                                    category = NULL, tags = NULL,
                                    user = NULL, is_admin = FALSE,
                                    con = dsapp_db()) {
  a <- dsapp_forum_author(user)
  row <- dsapp_forum_thread(onode, oid, con = con)
  if (is.null(row)) return(list(ok = FALSE, msg = "没有这条帖子。"))
  if (!dsapp_forum_can_edit(row$author_email, a$email, is_admin)) {
    return(list(ok = FALSE, msg = "只能改自己发的帖子。"))
  }
  sets <- character(0); vals <- list()
  if (!is.null(title)) {
    title <- dsapp_forum_norm(title, DSAPP_FORUM_MAX_TITLE)
    if (!nzchar(title)) return(list(ok = FALSE, msg = "标题不能是空的。"))
    sets <- c(sets, "title = ?"); vals <- c(vals, list(title))
  }
  if (!is.null(body)) {
    body <- dsapp_forum_norm(body, DSAPP_FORUM_MAX_BODY)
    if (!nzchar(body)) return(list(ok = FALSE, msg = "正文不能是空的。"))
    sets <- c(sets, "body = ?"); vals <- c(vals, list(body))
  }
  if (!is.null(category)) {
    category <- as.character(category)
    if (!category %in% DSAPP_FORUM_CAT_VALUES) category <- "ask"
    if (identical(category, "notice") && !isTRUE(is_admin)) {
      return(list(ok = FALSE, msg = "「公告」只有管理员能发。"))
    }
    sets <- c(sets, "category = ?"); vals <- c(vals, list(category))
  }
  if (!is.null(tags)) {
    sets <- c(sets, "tags = ?"); vals <- c(vals, list(dsapp_forum_tags(tags)))
  }
  if (!length(sets)) return(list(ok = TRUE, msg = "没有改动"))
  # ★ updated_at 一定要跟着走：它是同步的水位、也是 LWW 的比较键。
  #   不推的话这次编辑**永远不会同步出去**，而且本机看着一切正常。
  sets <- c(sets, "updated_at = ?")
  vals <- c(vals, list(dsapp_now()))
  vals <- c(vals, list(as.character(onode), as.character(oid)))
  ok <- tryCatch({
    DBI::dbExecute(con,
      sprintf("UPDATE forum_threads SET %s WHERE origin_node = ? AND origin_id = ?",
              paste(sets, collapse = ", ")), params = vals)
    TRUE
  }, error = function(e) FALSE)
  list(ok = isTRUE(ok), msg = if (isTRUE(ok)) "已保存" else "写库失败")
}

#' 作者本人 / 管理员 —— 这条内容归不归你管
#'
#' 纯函数，自检够得着。
#' ⚠️ 邮箱比较一律走 `.dsapp_sync_email_eq` 那把尺子（tolower + trimws）。
dsapp_forum_can_edit <- function(owner_email, my_email, is_admin = FALSE) {
  if (isTRUE(is_admin)) return(TRUE)
  .dsapp_forum_email_eq(owner_email, my_email)
}

.dsapp_forum_email_eq <- function(a, b) {
  identical(tolower(trimws(as.character(a %||% ""))),
            tolower(trimws(as.character(b %||% "")))) &&
    nzchar(tolower(trimws(as.character(a %||% ""))))
}

#' 改状态（solved / closed / open / hidden / deleted）
#'
#' ★ 删除在这里就是**把 status 改成 'deleted'**，不 DELETE 行。这是论坛
#'   不需要墓碑的全部原因（文件头 §一第 3 条）。
#'
#' ⚠️ `deleted` 是**终态**：一旦是它就不再接受任何改动，连作者自己也不能
#'    "恢复"。理由是同步 —— 恢复需要区分"我改回来了"和"对端还没收到我删
#'    的那一版"，而在没有墓碑的前提下这两种情况在库里长得一模一样
#'    （都是一行 status='open' 的、updated_at 更晚的记录）。要支持恢复就得
#'    把墓碑那套搬过来，不值当。界面上删之前会问一次。
dsapp_forum_thread_status <- function(onode, oid, status,
                                      user = NULL, is_admin = FALSE,
                                      con = dsapp_db()) {
  status <- as.character(status %||% "")
  if (!status %in% DSAPP_FORUM_TSTATUS) {
    return(list(ok = FALSE, msg = "不认识的状态。"))
  }
  row <- dsapp_forum_thread(onode, oid, con = con)
  if (is.null(row)) return(list(ok = FALSE, msg = "没有这条帖子。"))
  if (identical(as.character(row$status), "deleted")) {
    return(list(ok = FALSE, msg = "这条帖子已经删了。"))
  }
  a <- dsapp_forum_author(user)
  # ★ 谁能做什么，分三档：
  #   · deleted / hidden —— 作者本人可以删自己的；hidden 只有管理员能设
  #     （作者要藏自己的东西，删就是了，hidden 是**管理动作**）
  #   · pinned —— 只有管理员
  #   · solved / closed / open —— 作者的正常操作
  if (identical(status, "hidden") && !isTRUE(is_admin)) {
    return(list(ok = FALSE, msg = "只有管理员能隐藏。"))
  }
  if (!dsapp_forum_can_edit(row$author_email, a$email, is_admin)) {
    return(list(ok = FALSE, msg = "只能改自己发的帖子。"))
  }
  now <- dsapp_now()
  ok <- tryCatch({
    DBI::dbExecute(con,
      "UPDATE forum_threads SET status = ?, updated_at = ?
        WHERE origin_node = ? AND origin_id = ?",
      params = list(status, now, as.character(onode), as.character(oid)))
    TRUE
  }, error = function(e) FALSE)
  list(ok = isTRUE(ok), msg = if (isTRUE(ok)) "已更新" else "写库失败")
}

#' 置顶 / 取消置顶（只有管理员）
dsapp_forum_thread_pin <- function(onode, oid, pinned = TRUE,
                                   is_admin = FALSE, con = dsapp_db()) {
  if (!isTRUE(is_admin)) return(list(ok = FALSE, msg = "只有管理员能置顶。"))
  now <- dsapp_now()
  ok <- tryCatch({
    DBI::dbExecute(con,
      "UPDATE forum_threads SET pinned = ?, updated_at = ?
        WHERE origin_node = ? AND origin_id = ?",
      params = list(if (isTRUE(pinned)) 1L else 0L, now,
                    as.character(onode), as.character(oid)))
    TRUE
  }, error = function(e) FALSE)
  list(ok = isTRUE(ok), msg = if (isTRUE(ok)) "已更新" else "写库失败")
}

#' 删一条回复 / 隐藏它
dsapp_forum_post_status <- function(onode, oid, status = "deleted",
                                    user = NULL, is_admin = FALSE,
                                    con = dsapp_db()) {
  status <- as.character(status %||% "")
  if (!status %in% DSAPP_FORUM_PSTATUS) {
    return(list(ok = FALSE, msg = "不认识的状态。"))
  }
  if (identical(status, "hidden") && !isTRUE(is_admin)) {
    return(list(ok = FALSE, msg = "只有管理员能隐藏。"))
  }
  row <- tryCatch(DBI::dbGetQuery(con,
    "SELECT origin_node, origin_id, author_email, status, thread_onode, thread_oid
       FROM forum_posts WHERE origin_node = ? AND origin_id = ?",
    params = list(as.character(onode), as.character(oid))),
    error = function(e) NULL)
  if (is.null(row) || !nrow(row)) return(list(ok = FALSE, msg = "没有这条回复。"))
  if (identical(as.character(row$status[1]), "deleted")) {
    return(list(ok = FALSE, msg = "这条回复已经删了。"))
  }
  a <- dsapp_forum_author(user)
  if (!dsapp_forum_can_edit(row$author_email[1], a$email, is_admin)) {
    return(list(ok = FALSE, msg = "只能改自己发的回复。"))
  }
  now <- dsapp_now()
  ok <- tryCatch({
    DBI::dbExecute(con,
      "UPDATE forum_posts SET status = ?, updated_at = ?
        WHERE origin_node = ? AND origin_id = ?",
      params = list(status, now, as.character(onode), as.character(oid)))
    TRUE
  }, error = function(e) FALSE)
  list(ok = isTRUE(ok), msg = if (isTRUE(ok)) "已更新" else "写库失败")
}

# ---- 写：点赞 ---------------------------------------------------------------

#' 点赞 / 取消点赞
#'
#' @param kind "thread" 或 "post"
#' ★ `value = 0` 表示取消，**不 DELETE 行**。同软删那条理由：行没了就得
#'   靠墓碑告诉对端"那个赞没了"，而留着一个 value=0 的行什么都不用做。
dsapp_forum_mark <- function(kind, target_onode, target_oid, on = TRUE,
                             user = NULL, con = dsapp_db()) {
  kind <- as.character(kind %||% "")
  if (!kind %in% c("thread", "post")) return(list(ok = FALSE, msg = "类型不对。"))
  a <- dsapp_forum_author(user)
  if (!nzchar(a$email)) return(list(ok = FALSE, msg = "先登录。"))
  key <- dsapp_forum_key(target_onode, target_oid)
  if (is.na(key)) return(list(ok = FALSE, msg = "目标身份不完整。"))
  now <- dsapp_now()
  ok <- tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO forum_marks
         (kind, target_onode, target_oid, user_email, value, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(kind, target_onode, target_oid, user_email)
       DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
      params = list(kind, as.character(target_onode), as.character(target_oid),
                    a$email, if (isTRUE(on)) 1L else 0L, now, now))
    TRUE
  }, error = function(e) {
    message("[dsapp] 点赞失败：", conditionMessage(e)); FALSE
  })
  list(ok = isTRUE(ok), msg = if (isTRUE(ok)) "" else "写库失败")
}

# ---- 读 ---------------------------------------------------------------------

#' 一条帖子（按全局身份取）
#' @return 一行的 list，没有返回 NULL
dsapp_forum_thread <- function(onode, oid, con = dsapp_db()) {
  onode <- as.character(onode %||% ""); oid <- as.character(oid %||% "")
  if (!nzchar(onode) || !nzchar(oid)) return(NULL)
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT * FROM forum_threads WHERE origin_node = ? AND origin_id = ?",
    params = list(onode, oid)), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  as.list(r[1, , drop = FALSE])
}

#' 帖子的回复（一层楼一层楼地取）
#'
#' ★ **每个看的人都拿到同样的行数、同样的顺序** —— 包括已删/被隐藏的那些。
#'   正文给不给由渲染那一层决定（见函数体里那段）。所以 `viewer_email` /
#'   `is_admin` 在这里**不再决定可见性**，只剩两个用途：
#'   `viewer_email` 算 `i_liked`（"我点没点过这一层的赞"）；
#'   `is_admin` 目前只是**签名上的兼容**，留着是因为调用点都在传它，
#'   哪天要按身份脱敏（比如给非管理员把 deleted 那行的 body 清空）
#'   就从这里下手 —— 但**不能靠少返回来做**（行数=楼层号）。
#'
#' ⚠️ 排序按 `created_at, origin_node, origin_id` 三列，**不能只按时间**：
#'    两台机器上同一秒发的回复时间戳会一样，只按时间排的话两端的楼层顺序
#'    可能不同（SQLite 不保证相等键的顺序稳定）。加后两列是为了让两端
#'    算出**同一个顺序** —— 楼层号对不上的话，"3 楼说的"这句话就没意义了。
dsapp_forum_posts <- function(thread_onode, thread_oid, viewer_email = "",
                              is_admin = FALSE, con = dsapp_db()) {
  onode <- as.character(thread_onode %||% "")
  oid   <- as.character(thread_oid %||% "")
  if (!nzchar(onode) || !nzchar(oid)) return(data.frame())
  ve <- tolower(trimws(as.character(viewer_email %||% "")))
  # ★★ 这里**故意不过滤 status**（`p.status = 'ok'`）。
  #
  #    直觉是"删掉的楼层就别发给别人看了"，而那是错的 —— 而且错得正好
  #    打在这套设计唯一要防的那件事上：过滤掉的话，甲看到的是
  #    #1 #2 #3（中间那条画成"该回复已删除"），乙看到的是 #1 #2，
  #    而且是**另外两条**。于是"你看 3 楼说的"这句话在两个人的屏幕上
  #    指向不同的内容 —— 楼层号存在的全部意义就是这一个，
  #    过滤掉它等于把楼层号变成每屏一个的局部编号。
  #
  #    所以：**行一定要发给所有人，正文由渲染那一层决定给不给**
  #    （R/mod_forum.R 里 `if (deleted || hidden)` 那一支画占位符，
  #    正文根本不会进 HTML）。正文不进浏览器 = 没有泄漏，
  #    而行在 = 楼层号两端一致。
  #
  # ⚠️ 改这里之前先想清楚：`posts` 的**行数**是楼层号的依据，
  #    任何"让某些行消失"的过滤都会让号错位。要藏内容就藏 body。
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT p.*,
            (SELECT COUNT(*) FROM forum_marks m
              WHERE m.kind = 'post' AND m.target_onode = p.origin_node
                AND m.target_oid = p.origin_id AND m.value = 1) AS n_likes,
            (SELECT COUNT(*) FROM forum_marks m2
              WHERE m2.kind = 'post' AND m2.target_onode = p.origin_node
                AND m2.target_oid = p.origin_id AND m2.value = 1
                AND m2.user_email = ?) AS i_liked
       FROM forum_posts p
      WHERE p.thread_onode = ? AND p.thread_oid = ?
      ORDER BY p.created_at, p.origin_node, p.origin_id",
    params = list(ve, onode, oid)),
    error = function(e) NULL)
  if (is.null(r)) data.frame() else r
}

#' 列表页的数据
#'
#' @param category 空 = 全部
#' @param q 关键词（标题 / 正文 / 标签，LIKE）
#' @param sort active（最新回复）/ new（最新发布）/ hot（回复最多）/ like（最多有用）
#' @param author_email 非空 = 只看这个人发的
#' @param replied_by 非空 = 只看这个人回复过的（"我参与过的"）
#' @param viewer_email / is_admin 决定 hidden 的可见性
#' @param limit 取多少条
#' ⚠️ **LIKE 的通配符要转义**。用户搜 `100%` 的时候，不转义的话 `%` 是
#'    通配符，会匹配到所有帖子 —— 用户看到的是"搜什么都返回一堆不相关的"，
#'    而他不会想到是通配符。`ESCAPE '\'` 那句不能省。
dsapp_forum_list <- function(category = "", q = "", sort = "active",
                             author_email = "", replied_by = "",
                             viewer_email = "", is_admin = FALSE,
                             status = "", limit = 200L, con = dsapp_db()) {
  cat_ <- as.character(category %||% "")
  qv   <- trimws(as.character(q %||% ""))
  sort <- as.character(sort %||% "active")
  ae   <- tolower(trimws(as.character(author_email %||% "")))
  rb   <- tolower(trimws(as.character(replied_by %||% "")))
  ve   <- tolower(trimws(as.character(viewer_email %||% "")))
  st   <- as.character(status %||% "")

  where <- c("1 = 1")
  # ★★ 参数顺序 = SQL 里 `?` 出现的顺序。**SELECT 里那个 `i_liked` 子查询
  #    排在 WHERE 之前**，所以它那个 `?`（也是 ve，判"我点没点过赞"）必须
  #    排在第一个 —— 这就是下面两个 `ve` 的由来。
  #
  # ⚠️⚠️ 漏掉第一个 `ve` 的症状值得记下来，它是这一页**最贵**的一种坏法：
  #    SQLite 报 "Query requires 4 params; 3 supplied"，而这句查询在
  #    tryCatch 里（读不出来返回空 data.frame）—— 于是表现是**论坛列表永远
  #    是空的、一句报错都没有**，用户看到的是"还没有人发帖"。写这段的时候
  #    就是这么漏的，是自检里那条"列表里 deleted 的行谁都看不到"把它抓出来
  #    的（那条断言的"实际是：0"后面跟着日志里一行 [dsapp] 论坛列表查询失败）。
  #    加任何一列/改任何一段 WHERE 之后，**都要重新数一遍 `?`**。
  par <- list(ve, ve, as.integer(if (isTRUE(is_admin)) 1L else 0L))
  # 可见性：删掉的一律不出现（含作者本人 —— 删了就是删了）；隐藏的只有
  # 管理员和作者本人看得见。
  where <- c(where, "t.status <> 'deleted'")
  where <- c(where, "(t.status <> 'hidden' OR t.author_email = ? OR ? = 1)")
  if (nzchar(cat_)) { where <- c(where, "t.category = ?"); par <- c(par, list(cat_)) }
  if (nzchar(st) && st %in% DSAPP_FORUM_TSTATUS) {
    where <- c(where, "t.status = ?"); par <- c(par, list(st))
  }
  if (nzchar(qv)) {
    like <- paste0("%", gsub("([\\\\%_])", "\\\\\\1", qv), "%")
    where <- c(where,
      "(t.title LIKE ? ESCAPE '\\' OR t.body LIKE ? ESCAPE '\\'
        OR t.tags LIKE ? ESCAPE '\\' OR t.author_name LIKE ? ESCAPE '\\')")
    par <- c(par, list(like, like, like, like))
  }
  if (nzchar(ae)) { where <- c(where, "t.author_email = ?"); par <- c(par, list(ae)) }
  if (nzchar(rb)) {
    where <- c(where, paste0(
      "EXISTS (SELECT 1 FROM forum_posts pp
                WHERE pp.thread_onode = t.origin_node
                  AND pp.thread_oid = t.origin_id
                  AND pp.author_email = ? AND pp.status = 'ok')"))
    par <- c(par, list(rb))
  }

  # ★ 排序键里**每一条都带 origin_node, origin_id 兜底**，理由同
  #   dsapp_forum_posts：两端要算出同一个顺序，SQLite 对相等键不保证顺序。
  ord <- switch(sort,
    new  = "t.created_at DESC, t.origin_node, t.origin_id",
    hot  = "n_replies DESC, t.created_at DESC, t.origin_node, t.origin_id",
    like = "n_likes DESC, t.created_at DESC, t.origin_node, t.origin_id",
    # active 是默认：最新回复优先。没有任何回复时退回发帖时间 ——
    # COALESCE 那句不能省，否则新发的帖（last_reply 为 NULL）会排到最底下，
    # 表现是"我刚发的帖不见了"。
    "COALESCE(last_reply_at, t.created_at) DESC, t.origin_node, t.origin_id")

  sql <- sprintf(
    "SELECT t.*,
            (SELECT COUNT(*) FROM forum_posts p
              WHERE p.thread_onode = t.origin_node AND p.thread_oid = t.origin_id
                AND p.status = 'ok') AS n_replies,
            (SELECT COUNT(*) FROM forum_marks m
              WHERE m.kind = 'thread' AND m.target_onode = t.origin_node
                AND m.target_oid = t.origin_id AND m.value = 1) AS n_likes,
            (SELECT COUNT(*) FROM forum_marks m3
              WHERE m3.kind = 'thread' AND m3.target_onode = t.origin_node
                AND m3.target_oid = t.origin_id AND m3.value = 1
                AND m3.user_email = ?) AS i_liked,
            (SELECT MAX(p2.created_at) FROM forum_posts p2
              WHERE p2.thread_onode = t.origin_node
                AND p2.thread_oid = t.origin_id AND p2.status = 'ok')
              AS last_reply_at
       FROM forum_threads t
      WHERE %s
      ORDER BY t.pinned DESC, %s
      LIMIT ?", paste(where, collapse = " AND "), ord)
  par <- c(par, list(as.integer(limit)))
  r <- tryCatch(DBI::dbGetQuery(con, sql, params = par),
                error = function(e) {
                  message("[dsapp] 论坛列表查询失败：", conditionMessage(e))
                  NULL
                })
  if (is.null(r)) data.frame()
  else r
}

#' "3 小时前"这种相对时间
#'
#' ⚠️ `dsapp_now()` 写的是 **UTC**（R/utils.R），所以这里必须按 UTC 解析再和
#'    `Sys.time()` 比 —— 直接 `as.POSIXct(at)` 会按本机时区解释，在东八区
#'    就整整差 8 小时，表现是"刚发的帖显示 8 小时前"。这个错误不报错，
#'    而且只在非 UTC 的机器上出现，本地测试很可能看不出来。
#'
#' @param at "YYYY-MM-DD HH:MM:SS"
#' @return 人话；解析不出来返回原串（宁可显示原始时间，也不要显示"NA 前"）
dsapp_forum_ago <- function(at) {
  at <- as.character(at %||% "")
  if (!nzchar(at)) return("")
  t0 <- suppressWarnings(as.POSIXct(at, tz = "UTC"))
  if (is.na(t0)) return(at)
  d <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  # 未来时间（两端时钟有偏移，或者对端推来一条 updated_at 更晚的行）——
  # 显示"刚刚"而不是"-3 小时前"。负号在界面上看着像 bug。
  if (!is.finite(d) || d < 0) return("刚刚")
  if (d < 60)     return("刚刚")
  if (d < 3600)   return(sprintf("%d 分钟前", as.integer(d %/% 60)))
  if (d < 86400)  return(sprintf("%d 小时前", as.integer(d %/% 3600)))
  if (d < 2592000) return(sprintf("%d 天前", as.integer(d %/% 86400)))
  substr(at, 1L, 10L)
}

#' 某个账号的论坛活动统计（给"我的"那一栏显示）
dsapp_forum_my_stat <- function(email, con = dsapp_db()) {
  e <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(e)) return(list(threads = 0L, posts = 0L, likes = 0L))
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT
       (SELECT COUNT(*) FROM forum_threads
         WHERE author_email = ? AND status <> 'deleted') AS threads,
       (SELECT COUNT(*) FROM forum_posts
         WHERE author_email = ? AND status <> 'deleted') AS posts,
       (SELECT COUNT(*) FROM forum_marks
         WHERE user_email = ? AND value = 1) AS likes",
    params = list(e, e, e)), error = function(e2) NULL)
  if (is.null(r) || !nrow(r)) return(list(threads = 0L, posts = 0L, likes = 0L))
  list(threads = as.integer(r$threads[1]), posts = as.integer(r$posts[1]),
       likes = as.integer(r$likes[1]))
}

#' 浏览 +1
#'
#' ⚠️ **只改 views，绝不改 updated_at**。见文件头 §四：改了 updated_at 就
#'    等于"有人看了一眼"→ 这一行重新同步给所有人。而且这里刻意**不写
#'    message/日志**，也不在失败时重试 —— 浏览量少算一个不是问题，
#'    为了它卡住页面渲染才是。
dsapp_forum_view <- function(onode, oid, con = dsapp_db()) {
  onode <- as.character(onode %||% ""); oid <- as.character(oid %||% "")
  if (!nzchar(onode) || !nzchar(oid)) return(invisible(FALSE))
  try(DBI::dbExecute(con,
    "UPDATE forum_threads SET views = views + 1
      WHERE origin_node = ? AND origin_id = ?",
    params = list(onode, oid)), silent = TRUE)
  invisible(TRUE)
}

#' 我点过赞的东西在这批里吗（列表页批量回显用）
#'
#' 列表页每一行都要画一个"有用"按钮，而 dsapp_forum_list 已经带回了
#' `i_liked` 一列 —— 这个函数是给别处（比如详情页的帖子本身）用的。
dsapp_forum_i_liked <- function(kind, target_onode, target_oid, email,
                                con = dsapp_db()) {
  e <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(e)) return(FALSE)
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT value FROM forum_marks
      WHERE kind = ? AND target_onode = ? AND target_oid = ? AND user_email = ?",
    params = list(as.character(kind), as.character(target_onode),
                  as.character(target_oid), e)), error = function(e2) NULL)
  if (is.null(r) || !nrow(r)) return(FALSE)
  isTRUE(as.integer(r$value[1]) == 1L)
}

# =============================================================================
# 同步：收集与应用
# =============================================================================
# 这两段挂在 R/sync.R 的 dsapp_sync_collect / dsapp_sync_apply_bundle 里，
# 和 sessions / messages 并列成第三个、第四个、第五个段。
#
# ★ 和会话那两段最大的不同：**不按 user_id 筛**。论坛是公共的，A 的帖子
#   要发给 B 和 C，而 A 的密钥只在 A 登录时在内存里 —— 所以"谁能收到"这件事
#   由**收端那一侧的打包过程**决定（给谁打包就用谁的密钥签，内容里带上
#   所有人的公开帖），不是由内容自己决定。这是公共段和私有段在协议上的
#   唯一分歧，别在别处再发明一套。
#
# ★ 水位：`updated_at > since`，字典序比较（dsapp_now() 的格式定长，
#   见 SYNC.md §2.7）。三个段**共用一个水位**（`forum_at`），理由：
#   帖子和回复要按顺序应用，而"帖子先到、回复后到"会让回复暂时挂不上
#   （虽然显示层 JOIN 得回来，但列表的回复数会短暂少算）。共用水位 +
#   同一个包里先帖后回复，就把这个窗口缩到最小。
#
# ⚠️ 分页：`LIMIT max+1` 那句和会话那边同一个写法 —— 多取一条只为知道
#    "还有没有"，多出来的那条**不能**进包，而且要据此**不推进水位**
#   （推进了的话剩下那些**永远同步不出去**，且两边都不报错）。
# =============================================================================

# 单个包每个段最多带多少行。取值理由同 DSAPP_SYNC_MAX_SESSIONS：一次同步
# 不该把一个几百 MB 的库塞进内存，而且论坛是公共段 —— 每加一个用户，
# 这个包就多发一份，分值别开太大。
DSAPP_SYNC_MAX_FORUM <- 400L

#' 收集要发出去的论坛段
#'
#' @param since_at 水位（"YYYY-MM-DD HH:MM:SS"）
#' @return list(threads, posts, marks, high_water, truncated)
dsapp_forum_collect <- function(since_at = "", con = dsapp_db()) {
  since <- .dsapp_sync_rewind(since_at)
  empty <- list(threads = list(), posts = list(), marks = list(),
                high_water = "", truncated = FALSE)

  # ⚠️ 三段的取法一样，只有列名不同，所以抽成一个内层函数。
  #    ★ 一定要**带上 status**：软删的那一行 status='deleted'，它必须
  #    跟着包走 —— 这是删除唯一能传播出去的方式（论坛没有墓碑）。
  #    只发 `status <> 'deleted'` 的话，删除事件永远到不了对端。
  grab <- function(sql, n) {
    r <- tryCatch(DBI::dbGetQuery(con, sql,
                                  params = list(since, n + 1L)),
                  error = function(e) NULL)
    if (is.null(r) || !nrow(r)) return(list(df = NULL, trunc = FALSE))
    trunc <- nrow(r) > n
    if (trunc) r <- r[seq_len(n), , drop = FALSE]
    list(df = r, trunc = trunc)
  }

  th <- grab(
    "SELECT origin_node, origin_id, title, body, category, tags,
            author_email, author_name, status, pinned,
            created_at, updated_at
       FROM forum_threads WHERE updated_at > ?
      ORDER BY updated_at LIMIT ?", DSAPP_SYNC_MAX_FORUM)
  po <- grab(
    "SELECT origin_node, origin_id, thread_onode, thread_oid, body,
            author_email, author_name, reply_to_onode, reply_to_oid,
            status, created_at, updated_at
       FROM forum_posts WHERE updated_at > ?
      ORDER BY updated_at LIMIT ?", DSAPP_SYNC_MAX_FORUM)
  mk <- grab(
    "SELECT kind, target_onode, target_oid, user_email, value,
            created_at, updated_at
       FROM forum_marks WHERE updated_at > ?
      ORDER BY updated_at LIMIT ?", DSAPP_SYNC_MAX_FORUM)

  df2list <- function(df) {
    if (is.null(df) || !nrow(df)) return(list())
    lapply(seq_len(nrow(df)), function(i) as.list(df[i, , drop = FALSE]))
  }

  # ★ 水位只在**三段都没被截断**时推进。任一段被截断就说明"还有没发完的"，
  #   此时把水位推到 max 会让剩下的那批**永远发不出去**（下一次的 since
  #   比它们大）。和会话那边 `high_water` 的处理是同一个规矩。
  trunc <- isTRUE(th$trunc) || isTRUE(po$trunc) || isTRUE(mk$trunc)
  all_at <- c(if (!is.null(th$df)) th$df$updated_at,
              if (!is.null(po$df)) po$df$updated_at,
              if (!is.null(mk$df)) mk$df$updated_at)
  hw <- if (length(all_at)) max(all_at) else ""

  list(threads = df2list(th$df), posts = df2list(po$df),
       marks = df2list(mk$df),
       high_water = if (trunc) "" else hw, truncated = trunc)
}

#' 应用对端来的论坛段
#'
#' @param sec 包里的 `forum` 段（list(threads, posts, marks)）
#' @param peer 包的来源节点（老格式没带 origin_node 时的兜底）
#' @param cfg ⚠️ 必须传 —— 它要拿本机 node id 判"这一行是不是我自己造的"
#' @return list(n_threads, n_posts, n_marks, skipped)
dsapp_forum_apply <- function(sec, peer, cfg = dsapp_config(), con = dsapp_db(cfg)) {
  out <- list(n_threads = 0L, n_posts = 0L, n_marks = 0L, skipped = 0L)
  if (is.null(sec) || !is.list(sec)) return(out)
  me <- tryCatch(dsapp_sync_node_id(cfg), error = function(e) "")

  # ⚠️ 每一行都单独 tryCatch：一行坏数据（比如对端写了个超长的 body、
  #    或者 origin_id 是空的）不该让**整包**应用中断 —— 那会把这一包里
  #    其它几十条正常的内容一起丢掉，而错误信息只提到那一行。
  onerow <- function(f) tryCatch({ f(); TRUE }, error = function(e) {
    message("[dsapp] 论坛行应用失败：", conditionMessage(e)); FALSE
  })

  # ---- 帖子 ---------------------------------------------------------------
  for (s in sec$threads %||% list()) {
    onode <- trimws(as.character(s$origin_node %||% ""))
    if (!nzchar(onode)) onode <- peer
    oid <- trimws(as.character(s$origin_id %||% ""))
    if (!nzchar(oid)) { out$skipped <- out$skipped + 1L; next }
    uat <- as.character(s$updated_at %||% s$created_at %||% dsapp_now())
    ok <- onerow(function() {
      # ★★ 我自己造的、绕了一圈回来了：**只认不插**。
      #    这一条就是防回声的地基（SYNC.md §7.1）。论坛这边比会话还多一层
      #    保护 —— 就算这里写错，UNIQUE(origin_node, origin_id) 也会把插入
      #    拦下来（报错 → onerow 吞掉 → 计数不加），不会插出两份。
      #    但**不能只靠那个索引**：它拦下来的是"插入失败"，而正确的行为是
      #    "合并"（对端可能确实改过标题）。所以这里得自己判。
      ex <- dsapp_forum_thread(onode, oid, con = con)
      if (!is.null(ex)) {
        # ★ 已删除是**终态**：不因为对端手上还有一份就复活。
        #   会话那边同样的规则写在 .dsapp_sync_session_exists 那个分支里。
        if (identical(as.character(ex$status), "deleted")) return(invisible())
        # ★ LWW：只有对端那份**确实更新**才覆盖。相等就不动 —— 相等时
        #   覆盖会让两端的 updated_at 永远一样但内容可能是对方那版，
        #   而且"等于"在同一个包重复投递时最常出现（幂等的关键）。
        if (!(uat > as.character(ex$updated_at %||% ""))) return(invisible())
        DBI::dbExecute(con,
          "UPDATE forum_threads
              SET title = ?, body = ?, category = ?, tags = ?,
                  author_email = ?, author_name = ?, status = ?, pinned = ?,
                  updated_at = ?
            WHERE origin_node = ? AND origin_id = ?",
          params = list(as.character(s$title %||% ""),
                        as.character(s$body %||% ""),
                        as.character(s$category %||% "ask"),
                        as.character(s$tags %||% ""),
                        tolower(trimws(as.character(s$author_email %||% ""))),
                        as.character(s$author_name %||% ""),
                        as.character(s$status %||% "open"),
                        as.integer(s$pinned %||% 0L),
                        uat, onode, oid))
        out$n_threads <<- out$n_threads + 1L
        return(invisible())
      }
      # ⚠️ 状态要先过一遍白名单。对端（或者一个手写的包）塞一个没见过的
      #    status 过来，直接写进去的话那一行会**从此在列表里消失**
      #    （列表的 WHERE 认的是已知状态），而且谁也说不清它去哪了。
      st <- as.character(s$status %||% "open")
      if (!st %in% DSAPP_FORUM_TSTATUS) st <- "open"
      DBI::dbExecute(con,
        "INSERT INTO forum_threads
           (origin_node, origin_id, title, body, category, tags,
            author_email, author_name, status, pinned, views,
            created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
        params = list(onode, oid,
                      substr(as.character(s$title %||% ""), 1L,
                             DSAPP_FORUM_MAX_TITLE),
                      substr(as.character(s$body %||% ""), 1L,
                             DSAPP_FORUM_MAX_BODY),
                      as.character(s$category %||% "ask"),
                      as.character(s$tags %||% ""),
                      tolower(trimws(as.character(s$author_email %||% ""))),
                      as.character(s$author_name %||% ""),
                      st, as.integer(s$pinned %||% 0L),
                      as.character(s$created_at %||% uat), uat))
      out$n_threads <<- out$n_threads + 1L
    })
    if (!isTRUE(ok)) out$skipped <- out$skipped + 1L
  }

  # ---- 回复 ---------------------------------------------------------------
  # ⚠️ 回复在帖子**之后**处理，但**不依赖**它 —— 挂靠走的是全局身份
  #    (thread_onode, thread_oid)，那条帖子这会儿在不在本机都不影响这一行
  #    能不能落下（见文件头 §三）。所以顺序只是"让同一包里看起来整齐"，
  #    不是正确性要求。别把它改成"找不到帖子就跳过"。
  for (p in sec$posts %||% list()) {
    onode <- trimws(as.character(p$origin_node %||% ""))
    if (!nzchar(onode)) onode <- peer
    oid <- trimws(as.character(p$origin_id %||% ""))
    tonode <- trimws(as.character(p$thread_onode %||% ""))
    toid   <- trimws(as.character(p$thread_oid %||% ""))
    if (!nzchar(oid) || !nzchar(tonode) || !nzchar(toid)) {
      out$skipped <- out$skipped + 1L; next
    }
    uat <- as.character(p$updated_at %||% p$created_at %||% dsapp_now())
    ok <- onerow(function() {
      ex <- tryCatch(DBI::dbGetQuery(con,
        "SELECT status, updated_at FROM forum_posts
          WHERE origin_node = ? AND origin_id = ?",
        params = list(onode, oid)), error = function(e) NULL)
      if (!is.null(ex) && nrow(ex)) {
        if (identical(as.character(ex$status[1]), "deleted")) return(invisible())
        if (!(uat > as.character(ex$updated_at[1] %||% ""))) return(invisible())
        DBI::dbExecute(con,
          "UPDATE forum_posts
              SET thread_onode = ?, thread_oid = ?, body = ?,
                  author_email = ?, author_name = ?,
                  reply_to_onode = ?, reply_to_oid = ?, status = ?,
                  updated_at = ?
            WHERE origin_node = ? AND origin_id = ?",
          params = list(tonode, toid,
                        as.character(p$body %||% ""),
                        tolower(trimws(as.character(p$author_email %||% ""))),
                        as.character(p$author_name %||% ""),
                        as.character(p$reply_to_onode %||% ""),
                        as.character(p$reply_to_oid %||% ""),
                        as.character(p$status %||% "ok"),
                        uat, onode, oid))
        out$n_posts <<- out$n_posts + 1L
        return(invisible())
      }
      st <- as.character(p$status %||% "ok")
      if (!st %in% DSAPP_FORUM_PSTATUS) st <- "ok"
      DBI::dbExecute(con,
        "INSERT INTO forum_posts
           (origin_node, origin_id, thread_onode, thread_oid, body,
            author_email, author_name, reply_to_onode, reply_to_oid,
            status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(onode, oid, tonode, toid,
                      substr(as.character(p$body %||% ""), 1L,
                             DSAPP_FORUM_MAX_BODY),
                      tolower(trimws(as.character(p$author_email %||% ""))),
                      as.character(p$author_name %||% ""),
                      as.character(p$reply_to_onode %||% ""),
                      as.character(p$reply_to_oid %||% ""),
                      st, as.character(p$created_at %||% uat), uat))
      out$n_posts <<- out$n_posts + 1L
    })
    if (!isTRUE(ok)) out$skipped <- out$skipped + 1L
  }

  # ---- 点赞 ---------------------------------------------------------------
  # 身份是那四列联合主键，天然全局唯一 → 直接 UPSERT，不需要 origin、
  # 也不需要"这是不是我自己造的"那条判断（一个赞无所谓谁造的）。
  for (m in sec$marks %||% list()) {
    kind <- as.character(m$kind %||% "")
    tonode <- trimws(as.character(m$target_onode %||% ""))
    toid   <- trimws(as.character(m$target_oid %||% ""))
    ue <- tolower(trimws(as.character(m$user_email %||% "")))
    if (!kind %in% c("thread", "post") || !nzchar(tonode) ||
        !nzchar(toid) || !nzchar(ue)) {
      out$skipped <- out$skipped + 1L; next
    }
    uat <- as.character(m$updated_at %||% m$created_at %||% dsapp_now())
    ok <- onerow(function() {
      DBI::dbExecute(con,
        "INSERT INTO forum_marks
           (kind, target_onode, target_oid, user_email, value,
            created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(kind, target_onode, target_oid, user_email)
         DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
           WHERE excluded.updated_at > forum_marks.updated_at",
        params = list(kind, tonode, toid, ue,
                      if (isTRUE(as.integer(m$value %||% 0L) == 1L)) 1L else 0L,
                      as.character(m$created_at %||% uat), uat))
      out$n_marks <<- out$n_marks + 1L
    })
    if (!isTRUE(ok)) out$skipped <- out$skipped + 1L
  }

  out
}

#' 论坛段里所有行的最新 updated_at
#'
#' 收端拿它当"我收到哪儿了"的水位。★ 必须和**发送端** `dsapp_forum_collect`
#' 推进水位的口径一致（都是 max(updated_at)）—— 两边口径不一致的话，
#' 要么重复传（无害，幂等吸收），要么**漏传**（有害，而且不报错）。
#'
#' ⚠️ 从**应用成功的那些行**里取，不是从整个段里取。段里有一行应用失败
#'    （onerow 吞掉了），水位却推到它那儿的话，那一行**永远不会重来**。
dsapp_forum_section_high <- function(sec) {
  if (is.null(sec) || !is.list(sec)) return("")
  at <- unlist(lapply(c("threads", "posts", "marks"), function(k) {
    vapply(sec[[k]] %||% list(),
           function(x) as.character(x$updated_at %||% x$created_at %||% ""),
           character(1))
  }), use.names = FALSE)
  at <- at[nzchar(at)]
  if (!length(at)) "" else max(at)
}
