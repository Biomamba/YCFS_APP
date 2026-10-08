# =============================================================================
# 存储层（SQLite）
# =============================================================================
# 用 SQLite 而不是 MySQL/Redis：Shiny Server 下应用是单进程，多人共用，
# 没有独立的 worker 守护进程，SQLite 的零运维特性正好匹配。开 WAL 之后
# 读写不互相阻塞，配合 busy_timeout 足以应付实验室规模的并发。
#
# 归属：V5 起本应用**有账号**（见 R/users.R）。会话、任务按 users.id 归属，
# 各人只看得到自己的；文件管理区（file_owner 表）是**刻意公开**的例外 ——
# 生信数据要能互相引用，但改名/删除按归属判定权限。
#
# ⚠️ 归属过滤是**靠调用方传 user_id 实现的**，SQLite 层没有行级安全，也没有
#    "忘了传就报错"的机制。db_sessions_list() / db_tasks_list() 的处理方式是
#    user_id 为 NULL 时返回空集：宁可显示"什么都没有"，也不能把全站数据漏给
#    一个没带身份的调用。新加查询时照这个来。
# =============================================================================

#' 进程级状态容器
#'
#' 数据库连接缓存在这里。放在 globalenv 而不是文件级变量，是为了让
#' source() 重复执行时不会把已有连接冲掉（Shiny 开发模式会反复 source）。
dsapp_state <- function() {
  if (!exists(".dsapp_state", envir = globalenv(), inherits = FALSE)) {
    assign(".dsapp_state", new.env(parent = emptyenv()), envir = globalenv())
  }
  get(".dsapp_state", envir = globalenv(), inherits = FALSE)
}

#' 取数据库连接（惰性建立）
#'
#' callr 子进程里也会调用这个函数 —— 子进程是独立进程，会各自建自己的
#' 连接，这正是我们要的：SQLite 连接不能跨进程共享。
#' 连接缓存命中时对一次账：代码比库新就当场把表补齐
#'
#' @return 真的补了返回 TRUE（给测试和日志用），没补返回 FALSE
#'
#' -----------------------------------------------------------------------------
#' ⚠️⚠️ 这个函数是为 2026-09-15 线上那个事故加的，别删
#' -----------------------------------------------------------------------------
#' 事故现场：用户点《用户须知》的「同意并继续」，界面回
#'    没能记录你的确认，请重试。如果一直失败请联系管理员。（no such table: consent_log）
#' 然后被这个闸门永久挡在应用外面 —— 而**自检全绿**。
#'
#' 原因是两件事凑在一起，单独看每一件都是对的：
#'   ① `dsapp_db()` 把连接缓存在**进程级**的 `.dsapp_state` 里（见上面那段
#'      说明，那个设计本身没问题：每调一次都重连会贵得离谱）；
#'   ② 建表（`dsapp_db_schema`）**只在建连接那一刻**跑一次。
#' 平时这两条相安无事 —— 进程重启 = 新连接 = 新表。可这台机器上改了 R/*.R
#' 之后 **R 进程并不重启**（Shiny Server 在同一个进程里重新求值），于是：
#'     10:29 的进程建好连接（那时还没有 consent_log 这张表）
#'     → 18:31 我改了代码，同一进程里开始跑新代码
#'     → 新代码去 INSERT consent_log，而手里那个连接是**老**连接的
#'     → no such table。
#' 而测试实例每次都是新起的进程，永远走不到这条路上 —— 这就是为什么它能
#' 一路绿灯地漏过去。
#'
#' 判据用 `PRAGMA user_version`（SQLite 专门留的、给使用者记结构版本的一个
#' 整数，存在库头里）而不是"查一下表在不在"：后者要枚举所有表，而且每加一张
#' 表就得改一次判断。对账靠版本号，加表的人只需要把 DSAPP_SCHEMA_VERSION +1。
#'
#' 开销：稳态下就是**一次内存里的 identical()** —— `st$schema_v` 记着"这个
#' 连接已经按哪一版代码补过表了"，和代码里的常量一比就完事，不查库。
#' 之所以能这么省，是因为要比的是**代码里的常量**：代码一换（重新求值），
#' 常量就变了，比较立刻失败 —— 正好是我们要察觉的那一刻。
dsapp_db_migrate <- function(con) {
  st <- dsapp_state()
  if (identical(st$schema_v, DSAPP_SCHEMA_VERSION)) return(invisible(FALSE))

  # 库里记的结构版本。读不出来（老库、被别的东西锁着）就当成 0，照补不误 ——
  # 建表那一段是幂等的，多补一次没有任何代价，少补一次才是这次的事故。
  cur <- tryCatch(as.integer(DBI::dbGetQuery(con, "PRAGMA user_version")[[1]]),
                  error = function(e) NA_integer_)
  if (!is.na(cur) && cur > DSAPP_SCHEMA_VERSION) {
    # 库比代码新：代码是回滚回去的。这时候**不能**拿老代码的建表语句去动库
    # （补不出新表，倒有可能把新列当成"缺失"重复加）。记下已经对过账就走。
    st$schema_v <- DSAPP_SCHEMA_VERSION
    return(invisible(FALSE))
  }
  if (!is.na(cur) && cur == DSAPP_SCHEMA_VERSION) {
    st$schema_v <- DSAPP_SCHEMA_VERSION
    return(invisible(FALSE))
  }

  message(sprintf("[dsapp] 数据库结构落后于代码（库 %s / 代码 %d），正在补齐…",
                  if (is.na(cur)) "读不出" else as.character(cur),
                  DSAPP_SCHEMA_VERSION))
  dsapp_db_schema(con)
  try(DBI::dbExecute(con,
        sprintf("PRAGMA user_version = %d", DSAPP_SCHEMA_VERSION)), silent = TRUE)
  st$schema_v <- DSAPP_SCHEMA_VERSION
  invisible(TRUE)
}

dsapp_db <- function(cfg = dsapp_config()) {
  st <- dsapp_state()
  # ⚠️ 命中缓存还要**对得上路径**，不能只看"有没有活着的连接"。
  #
  #    这是个进程内的单例，`cfg` 参数只有在建连接那一刻被看过一眼。少了这半句，
  #    任何"换一个 cfg 再调一次"的代码都会**静默拿到上一个库**：它以为自己
  #    在新的数据目录里读写，实际全落在旧的上面，而且一句报错都没有。
  #    2026-09-14 自检里就踩着这个 —— 有个测试临时改了 DSAPP_DATA_ROOT，
  #    父进程随即连上了一个空库并缓存住，后面十来个断言在一个空库上跑，
  #    红了一片，看起来像是配额功能坏了。
  #
  #    正常运行时数据目录不会变，所以这一句对线上是纯粹的无操作。
  if (!is.null(st$db) && DBI::dbIsValid(st$db) &&
      identical(st$db_path, cfg$db_path)) {
    # ⚠️ 这一句是 2026-09-15 事故的修复（no such table: consent_log）。
    #    缓存命中**不等于**表是对的：连接可能是上一版代码建的，而进程一直
    #    没重启。详见上面 dsapp_db_migrate 的说明。稳态下它只是一次内存比较。
    dsapp_db_migrate(st$db)
    return(st$db)
  }
  if (!is.null(st$db) && DBI::dbIsValid(st$db)) {
    # 路径变了：把旧连接关掉再建新的。不关的话会话一多会攒下一堆句柄。
    try(DBI::dbDisconnect(st$db), silent = TRUE)
    st$db <- NULL
  }

  dsapp_init_dirs(cfg)
  con <- DBI::dbConnect(RSQLite::SQLite(), cfg$db_path)

  # WAL：读不阻塞写。默认的 rollback journal 在多会话同时读写时会
  # 频繁 "database is locked"。
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  # 遇到锁时等 5 秒再报错，而不是立刻失败。执行任务写库和页面读列表
  # 撞车是常态。
  DBI::dbExecute(con, "PRAGMA busy_timeout = 5000")
  # 外键约束默认是关的，关掉会让删除会话后留下孤儿消息。
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON")

  dsapp_db_schema(con)
  # 库结构版本跟着连接一起记（和 st$db_path 同样的道理，见下面那段注释）。
  # 新连接刚刚跑完建表，所以这里直接认定它已经是当前版本。
  try(DBI::dbExecute(con,
        sprintf("PRAGMA user_version = %d", DSAPP_SCHEMA_VERSION)), silent = TRUE)
  st$schema_v <- DSAPP_SCHEMA_VERSION
  st$db <- con
  # ⚠️ 路径要和连接一起记住 —— 漏了这一句，上面那个 identical() 永远为假，
  #    于是每一次 dsapp_db() 都会把上一个连接关掉再重连：调用方手里那个
  #    句柄说失效就失效（"Invalid or closed connection"），而每次调用都
  #    重新建连接本身也很贵。
  st$db_path <- cfg$db_path
  con
}

#' 建表（幂等）
dsapp_db_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sessions (
      id         TEXT PRIMARY KEY,
      title      TEXT NOT NULL DEFAULT '新会话',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS messages (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      role       TEXT NOT NULL,
      content    TEXT NOT NULL,
      created_at TEXT NOT NULL
    )")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_msg_session ON messages(session_id, id)")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS tasks (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id  TEXT,
      title       TEXT NOT NULL,
      lang        TEXT NOT NULL DEFAULT 'R',
      code        TEXT NOT NULL,
      status      TEXT NOT NULL DEFAULT 'pending',
      exit_code   INTEGER,
      stdout      TEXT,
      stderr      TEXT,
      workdir     TEXT,
      created_at  TEXT NOT NULL,
      started_at  TEXT,
      finished_at TEXT
    )")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_task_created ON tasks(id DESC)")

  # ---- V7 任务产物 ----------------------------------------------------------
  # 哪个任务写出了哪个文件。
  #
  # 在这张表之前，"这个文件是哪来的"在库里没有任何线索：任务页列出的是
  # 当时那次执行前后工作区的差集（见 executor.R 的 before/after 快照），
  # 差集算完就扔了，只剩一句 "artifacts" 的 JSON 落在 run/job-*.json 里，
  # 下次重启就被清理掉。于是文件页只能把所有产物平铺成一长条，几十个文件
  # 之后完全看不出哪个是哪个任务的（用户的原话：「文件需要以任务名称分类
  # 展开」）。
  #
  # ⚠️ 只存**相对路径**，不存大小/摘要。大小随时会变（用户可能再跑一次
  #    覆盖掉），存下来就得同步，迟早对不上。要显示大小时现读盘。
  #
  # ⚠️ 这张表是**旁挂的索引，不是真相来源**：文件被用户删掉之后这里可能
  #    还留着行。读取的一方（dsapp_ws_groups）永远以磁盘为准，只在
  #    "这个在磁盘上真实存在的文件当初是谁写的"这一步查这里。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS task_files (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id    INTEGER NOT NULL,
      session_id TEXT,
      name       TEXT NOT NULL,
      created_at TEXT NOT NULL
    )")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_tfile_sess ON task_files(session_id)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_tfile_task ON task_files(task_id)")
  # 同一个任务重复写同一个文件名（比如脚本里循环追加）只该留一行，
  # 靠 UNIQUE 兜住 —— INSERT OR REPLACE 才不会越积越多。
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_tfile_uniq ON task_files(task_id, name)")

  # 哪些工作区产物被「发布」到了文件管理区（V7）。
  #
  # ★ 为什么必须**记下来**，而不是拿文件名去共享区里比对：
  #   `dsapp_publish_artifact` 把文件落在共享区**根目录**（用 basename），
  #   而工作区里的 `name` 是**相对路径**。于是 `results/de_genes.csv` 发布
  #   出去叫 `de_genes.csv`，两边永远对不上 —— 子目录里的产物发布完，
  #   界面上的标记还停在「仅本对话」，用户以为没成功，就再点一次，共享区
  #   里于是多出一个 `de_genes1.csv`。
  #
  #   反过来只比 basename 也不行：`A/expr.csv` 和 `B/expr.csv` 是两份不同
  #   的文件，却会被认成同一份。**记下来**是唯一能同时避开这两种错的法子。
  #
  #   `dest` 存共享区里的实际落点（可能被 dsapp_unique_path 加了序号），
  #   读取时还要确认它**现在**还在（用户可能已经把共享区那份删了，那就该
  #   退回「仅本对话」）。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ws_published (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      name       TEXT NOT NULL,
      dest       TEXT,
      created_at TEXT NOT NULL
    )")
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_wspub_uniq ON ws_published(session_id, name)")

  # ---- 自动同步的落点（V12 item 3）------------------------------------------
  #
  # 每个对话在文件管理区下有**自己的一个文件夹**，任务产出的文件自动落进去
  # （见 files.R 的 dsapp_sync_artifacts）。这张表记的就是"哪个对话对应哪个
  # 文件夹"。
  #
  # ⚠️ 为什么要**记下来**，而不是每次按标题现算一个：文件夹名里带着对话
  #    标题（用户认得出是哪个对话），而标题是**会变的** —— 第一句话发出去
  #    之后模型会给对话起个名。现算的话，改一次标题就换一个文件夹，
  #    之前同步进去的产物留在一个没人认领的旧文件夹里，用户会以为东西丢了。
  #    所以名字只在第一次同步时定下来，之后一直用它。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_dirs (
      session_id TEXT PRIMARY KEY,
      dir        TEXT NOT NULL,
      created_at TEXT NOT NULL
    )")

  # ---- V3 迁移 --------------------------------------------------------------
  # 记录任务用的是哪个分析环境（"system" / conda 环境名 / "远程 user@host"）。
  # 不记的话任务页只看到一个孤零零的结果，用户没法判断"这个数是哪个环境
  # 跑出来的" —— 同一个脚本在不同环境里结果不同，这是生信里最常见的坑。
  #
  # SQLite 的 ADD COLUMN 没有 IF NOT EXISTS，重复执行会报 duplicate column，
  # 所以先查一下表结构。整个 schema 函数是幂等的，这里也必须幂等。
  cols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(tasks)")$name,
                   error = function(e) character(0))
  if (!"target" %in% cols) {
    try(DBI::dbExecute(con, "ALTER TABLE tasks ADD COLUMN target TEXT"),
        silent = TRUE)
  }

  # ---- V5 迁移 --------------------------------------------------------------
  # 消息的思维链。以前思考过程只活在流式那几十秒里（界面上一闪，
  # 生成结束就 st$reason <- ""），落库的只有正文。
  #
  # 这在"思考把 max_tokens 额度吃光、正文为空"的情况下是致命的：用户等了
  # 几分钟，界面上转过"正在思考"，结束后**什么都没有** —— 没有正文可显示，
  # 思考过程又被丢掉，看起来就像应用坏了。存下来之后，至少那几分钟的思考
  # 是能翻出来看的，也知道模型到底卡在哪一步。
  mcols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(messages)")$name,
                    error = function(e) character(0))
  if (!"reasoning" %in% mcols) {
    try(DBI::dbExecute(con, "ALTER TABLE messages ADD COLUMN reasoning TEXT"),
        silent = TRUE)
  }

  # ---- V5 账号 --------------------------------------------------------------
  dsapp_db_schema_users(con)
  # 用户须知与同意日志（V9 item 1）。**必须排在 users 后面**：它给 users
  # 加两列，表得先在。整段包 try：它失败顶多是"同意状态读不出来、每次都
  # 重新问一遍"，不该把整个应用挡在门外 —— 而 schema 函数是 dsapp_db()
  # 每次调用都会走的路。
  #
  # ⚠️ 但**失败必须出声**。原来这里写的是 `try(..., silent = TRUE)`，
  #    2026-09-15 线上就是被它坑的：表没建出来，一句日志都没有，用户只看到
  #    "no such table: consent_log"，我从"闸门为什么不放行"一路查到"这个连接
  #    是什么时候建的"。message() 会进 Shiny Server 的应用日志（也就是
  #    /var/log/shiny-server/ 下那个文件），下次同类问题一眼就能看见。
  tryCatch(dsapp_tos_schema(con),
           error = function(e)
             message("[dsapp] 用户须知建表失败：", conditionMessage(e),
                     "\n        （同意闸门会因此拦下所有人，见 R/tos.R）"))
  # 远程节点名册（R/nodes.R）。**只存机器身份，不存凭据** —— 见那个文件顶部。
  dsapp_db_schema_nodes(con)

  # ---- V5 token 用量 --------------------------------------------------------
  # 每一轮模型生成记一行。V5 之前用量只活在界面上的那个气泡里
  # （`rv$usage`，刷新即消失），于是"这个月谁把额度用光了"这个问题
  # 在库里没有任何线索 —— 而这个应用是多人共用**一个** API Key 的。
  #
  # ⚠️ 这张表**不存对话内容**，只有数字和坐标（谁、哪个对话、什么场景、
  #    哪个模型、几个 token）。管理页的承诺是"管理员不看你分析的是什么"，
  #    多存一个 prompt 就把那句话变成假的了。见 mod_admin.R 顶部。
  #
  # model / scene 存明文而不是外键：模型名是用户随时在设置页改的，
  # 建一张 models 表只会多一层要同步的东西，而且老模型下线之后
  # （见 R/models.R）历史行仍要能读出"当时用的是哪个名字"。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS usage_log (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id           INTEGER,
      session_id        TEXT,
      scene             TEXT NOT NULL DEFAULT '',
      model             TEXT NOT NULL DEFAULT '',
      prompt_tokens     INTEGER,
      completion_tokens INTEGER,
      total_tokens      INTEGER,
      day               TEXT NOT NULL DEFAULT '',
      created_at        TEXT NOT NULL
    )")
  # 管理页的两个聚合方向：按天、按人。分开建索引而不是一个复合索引 ——
  # 两个查询各自都用不上对方的前缀。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_usage_day ON usage_log(day)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_usage_user ON usage_log(user_id)")

  # ---- V5 操作审计（见 R/audit.R 顶部）----
  dsapp_db_schema_audit(con)

  # ---- V5 对话共享（item 7）----
  dsapp_db_schema_share(con)

  # ---- V13.3 本地库 ↔ 在线版同步（item 2）----
  # 三张**旁挂**表：同步不改任何现有表的 schema，见 R/sync.R 顶部第二节。
  dsapp_db_schema_sync(con)

  # ---- V13 团队（item 3）----
  # 团队只影响"共享对话框里默认列谁"，不参与任何权限判断，见 R/teams.R。
  dsapp_db_schema_teams(con)

  # ---- V11 单端登录（item 4b）----
  # 一个账号一行的"当前那一端"，见 R/logins.R 顶部。
  dsapp_db_schema_logins(con)

  # ---- V15 论坛（item 8）----
  # 三张表：帖子 / 回复 / 点赞。回复挂帖子走的是**全局身份**
  # (origin_node, origin_id) 而不是本地外键，理由见 R/forum.R 文件头第三节。
  dsapp_db_schema_forum(con)

  # ---- Test_V15.2 邮件队列 ----
  # 一张旁挂表：不改任何现有表，所以只加一个 schema 函数 + 版本号 +1。
  # 为什么要落库而不是直接在内存里发，见 R/mail.R 顶部第 3 节
  # （一句话：定时发信的时候没有任何页面开着，失败了没人当场看见）。
  #
  # ⚠️ **不包 try**：这张表建不出来，发信功能会以"no such table: mail_queue"
  #    的形式到处冒出来，而那个错误信息完全指不到真正的原因
  #    （见上面 tos 那段的血泪）。建不出来就该当场出声。
  dsapp_db_schema_mail(con)

  # ---- Test_V15.2 文献速递定时订阅 ----
  # 同样是旁挂表，见 R/litsub.R 顶部。
  dsapp_db_schema_lit(con)

  # ---- Test_V15.3 厂商报出来的参数上限（item 2）----
  # 旁挂表，(厂商, 模型, 参数) → 上限。建表函数放在 R/models.R 里紧挨着用它的
  # 那几层参数档 —— 和 mail.R / litsub.R 一样，功能自己的表自己建。
  # ⚠️ **不包 try**：建不出来时 dsapp_param_learn() 会以 "no such table" 的形式
  #    炸在"点按钮"那一刻，而那句错误完全指不到真正的原因。建不出来就该当场出声。
  dsapp_db_schema_paramlim(con)

  # ---- Test_V15.4 系统提示词的分节覆盖（item 8）----
  # 同样是旁挂表，建表函数放在 R/prompts.R 里紧挨着用它的那一层 —— 和
  # paramlim 一样，功能自己的表自己建。
  # ⚠️ 也**不包 try**：建不出来时 dsapp_prompt_load() 会安静地什么都没读到
  #    （它包了 tryCatch 兜底），于是"超管改了提示词但没生效"——而真正的原因
  #    是表压根没建起来。那种错误指向的地方和原因隔着三层。
  dsapp_db_schema_prompt(con)

  # ---- V13.1 分厂商的 API Key 钥匙串（item 5）----
  # 放在技能库**前面**：技能那一段整段包在 try 里（见下面的说明），
  # 而钥匙串是设置页的核心功能，不能跟着它一起被吞掉。
  dsapp_db_schema_keys(con)

  # ---- Test_V16.3 item 2：按账号的代理（VPN）设置 ----
  # 旁挂表，建表函数放在 R/proxy.R 里紧挨着用它的那一层 —— 和 mail / litsub /
  # paramlim / prompt 一样，功能自己的表自己建。
  # ⚠️ 也**不包 try**：建不出来时 dsapp_proxy_save() 会安静地返回 FALSE
  #    （它包了 tryCatch 兜底），于是"填了代理、界面说记住了、其实一个字都
  #    没写进去"—— 而真正的原因是表压根没建起来。
  dsapp_db_schema_proxy(con)

  # ---- V8 技能库（item 1）----
  # 放在最后、并且整段包在 try 里：建表和种子数据都在这一句里，万一种子里
  # 有一条写坏了，不能让**整个应用**起不来 —— 技能是锦上添花的功能，
  # 它出问题顶多是技能页空着，不该把对话也一起拖下水。
  try(dsapp_db_schema_skills(con), silent = TRUE)

  # ---- V16.6 item 1：信息同步跳板 + 全局设置 KV（R/syncservers.R）----------
  # ⚠️ 照例"加表必须抬版本"。不抬的症状见 R/config.R 里 DSAPP_SCHEMA_VERSION
  #    那段记的三次事故：老连接上没有这张表，而读它的路又都套着 tryCatch
  #    （读不出来当"没有"），于是表现是"点了没反应、也不报错"。
  tryCatch(dsapp_db_schema_sync_servers(con),
           error = function(e)
             message("[dsapp] 同步跳板建表失败：", conditionMessage(e),
                     "\n        （后台管理页那张卡会空白，见 R/syncservers.R）"))

  # ---- V13.1 把已存的 API Key 加密（item 9）----
  #
  # ⚠️ 放在**最后**，而且必须在 dsapp_db_schema_keys() 之后：那个函数会把
  #    users.llm_api_key 原样抄进 user_api_keys.api_key（明文抄明文、密文抄
  #    密文），抄完之后这里一次性把两张表里的明文都换成密文，顺序反过来的话
  #    就会漏掉刚抄过去的那一份。
  #
  # ⚠️ 它挂在 dsapp_db_schema 里、而不是 dsapp_db_migrate 的版本判断后面。
  #    migrate 在 `库版本 == 代码版本` 时是**直接 return** 的，而"钥匙串那天
  #    没建成"这种事跟库版本毫无关系 —— 挂在版本判断后面，等于钥匙串一旦
  #    第一次没建成，线上那批明文 Key 就永远躺在库里等不到第二次机会。
  #    dsapp_db_schema 是**每建一条新连接**跑一次（即每次重启进程跑一次），
  #    这个频率对"扫一遍 users 表"来说绰绰有余。
  try(dsapp_db_migrate_secrets(con), silent = TRUE)

  invisible(TRUE)
}

#' 把库里已存的 API Key 从明文换成密文（V13.1 item 9）
#'
#' 幂等：已经是密文的行跳过。跑不动（钥匙串建不出来）时**什么都不写** ——
#' 宁可让它下次再试，也不能把用户的 Key 弄丢或者写成半截。
#'
#' @return 这次加密了几条（不可见），给日志和自检看。
dsapp_db_migrate_secrets <- function(con, cfg = dsapp_config()) {
  n <- 0L

  .enc_col <- function(sql, upd, idcol) {
    rows <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) NULL)
    if (is.null(rows) || !nrow(rows)) return(0L)
    k <- 0L
    for (i in seq_len(nrow(rows))) {
      v <- as.character(rows[[2]][[i]])
      if (is.na(v) || !nzchar(v) || dsapp_sec_is_enc(v)) next
      e <- dsapp_sec_enc(v, cfg)
      # 加密失败时 dsapp_sec_enc 原样返回 —— 那就别写，写了等于没变，
      # 还会让"跑过了"这件事看起来像成功了。
      if (identical(e, v)) next
      ok <- tryCatch({
        DBI::dbExecute(con, upd,
                       params = list(e, rows[[idcol]][[i]]))
        TRUE
      }, error = function(e) FALSE)
      if (ok) k <- k + 1L
    }
    k
  }

  n <- n + .enc_col(
    "SELECT id, llm_api_key FROM users
      WHERE llm_api_key IS NOT NULL AND TRIM(llm_api_key) <> ''",
    "UPDATE users SET llm_api_key = ? WHERE id = ?", 1L)

  n <- n + .enc_col(
    "SELECT rowid, api_key FROM user_api_keys
      WHERE api_key IS NOT NULL AND TRIM(api_key) <> ''",
    "UPDATE user_api_keys SET api_key = ? WHERE rowid = ?", 1L)

  if (n > 0L) {
    message(sprintf("[dsapp] 已把 %d 条 API Key 加密入库（V13.1 item 9）。", n))
  }
  invisible(n)
}

#' 对话共享表（item 7）
#'
#' 用户的原话：「不要通过文件共享区来传递任务，直接可以选择任务共享，
#' 指定账号查看」。以前要把一份分析交给同事，只能把产物"发布"到文件管理区
#' —— 那等于**把结果从它所属的对话里摘出来**：对方拿到的是一个孤零零的
#' csv，看不到它是哪段代码、在哪个环境、根据哪句话跑出来的，也无从判断
#' 这份数据是不是最新的。
#'
#' ⚠️ 这张表**不复制任何数据**，只记一行"谁可以看哪个对话"。它是授权，
#'    不是副本 —— 所以撤回共享就是删一行，对方立刻看不到，
#'    也不会留下一个"当时导出过的旧版本"在别处流传。
#'
#' ⚠️ 没有指向 sessions 的外键，和 tasks 一样（见 dsapp_db_schema 的说明）。
#'    代价是删对话会留下永远查不出来的孤儿授权行 —— 所以 db_session_delete
#'    里显式删一次，别指望级联。
# ---- 按厂商记的 API Key 钥匙串（V13.1 item 5）-------------------------------

#' 每个账号、每个厂商各存一把 Key
#'
#' 用户原话：「填写的api key要有记忆功能，在切换厂商时能直接切换过来，
#' 不然每次复制API key不好操作」。
#'
#' 在这张表之前只有 `users.llm_api_key` **一列**，全站一个账号一把 Key。
#' 于是切厂商时输入框里留的是上一个厂商的 Key，而防抖保存会把它原样写到
#' 新厂商名下 —— 不只是"要重新粘一遍"这么轻：换厂商之后第一次发消息，
#' 发出去的是**上一家的 Key**，报 401，而用户刚刚才在设置页看到"Key 已记住"。
#'
#' 主键 (user_id, vendor)：一个厂商一把。base_url / model 也一起存 ——
#' 用户换到某家时想切回来的就是"他那套配置"，光有 Key 还得再调一遍地址和
#' 模型，省下的那点复制粘贴又还回去了。
#'
#' ★ V13.1 item 9：`api_key` 和 `users.llm_api_key` **都是密文**
#'    （R/crypto.R，AES-GCM + data_root/.keyring）。写进去之前
#'    dsapp_api_key_put() 会加密，读出来之后 dsapp_api_key_recall() 会解密，
#'    这个文件里的 SQL 看到的是密文 —— 下面那句 INSERT..SELECT 是密文抄密文，
#'    抄完再由 dsapp_db_migrate_secrets() 统一把两张表里的老明文换成密文。
#'    ⚠️ 往这张表里写值的代码**必须**走 dsapp_api_key_put()，直接写 SQL
#'       就是在往库里塞明文。
dsapp_db_schema_keys <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS user_api_keys (
      user_id    INTEGER NOT NULL,
      vendor     TEXT NOT NULL,
      api_key    TEXT,
      base_url   TEXT,
      model      TEXT,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (user_id, vendor)
    )")

  # ---- 一次性把老数据搬进来 ----
  #
  # 这张表是 V13.1 才有的，而线上账号的 Key 都还躺在 users.llm_api_key 那一列里。
  # 不搬的话，所有人升上来之后"切回原来的厂商"会发现自己那把 Key 不见了 ——
  # 而 Key 是用户自己从厂商控制台复制来的，我们赔不回来。
  #
  # 只搬 (llm_vendor, llm_api_key) 这一对：那一列**只属于当前选中的厂商**，
  # 这是它能给出的唯一确定的归属。
  #
  # ⚠️ INSERT OR IGNORE + WHERE NOT EXISTS，两重都留着：这个函数在
  #    "库版本落后"时会被再跑一遍（见 dsapp_db_migrate），而那时候表里
  #    可能已经有用户新填的 Key 了 —— 覆盖掉他刚填的那把是纯粹的倒退。
  invisible(tryCatch(
    DBI::dbExecute(con, "
      INSERT OR IGNORE INTO user_api_keys
        (user_id, vendor, api_key, base_url, model, updated_at)
      SELECT id, llm_vendor, llm_api_key, llm_base_url, llm_model,
             COALESCE(created_at, datetime('now'))
        FROM users
       WHERE llm_api_key IS NOT NULL AND TRIM(llm_api_key) <> ''
         AND llm_vendor  IS NOT NULL AND TRIM(llm_vendor)  <> ''"),
    error = function(e) 0))
  invisible(TRUE)
}

dsapp_db_schema_share <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS session_share (
      session_id TEXT NOT NULL,
      user_id    INTEGER NOT NULL,
      granted_by INTEGER,
      created_at TEXT NOT NULL,
      PRIMARY KEY (session_id, user_id)
    )")
  # 主键是 (session_id, user_id)，按 session 查走主键前缀，够用；
  # 反向那句"别人共享给我的"没有索引可用，单独建一个。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_share_user ON session_share(user_id)")
  invisible(TRUE)
}

# ---- 同步（V13.3 item 2）----------------------------------------------------
#
# ⚠️ 这三张表是**旁挂**的，一张现有表都没改。这是同步这个功能最重要的
#    一条设计约束：它加进来之后，任何一张现有表的 CREATE/ALTER 都没动过，
#    所以最坏情况是"同步不生效"，而不是"对话数据被写坏"。
#
#    （替代方案是给 sessions/messages 加一个全局唯一的 sync_uid 列，
#    但那样每条读会话的 SQL 都要跟着认新列，改动面大得多。用映射表则
#    读写路径一行不用改。）

dsapp_db_schema_sync <- function(con) {
  # 每个「对端」的同步水位。
  #
  # peer 的键是 `<node_id>:<email>`（见 R/sync.R 的 dsapp_sync_peer_key）——
  # 一台机器上两个本地账号各同步各的，**不能共用水位**：A 账号把水位推到
  # 最新之后，B 账号那批更早的行就永远同步不过去了。
  #
  # in_* 是"我已经收下对端到哪了"，out_* 是"我已经发给对端到哪了"。
  # at 和 del 分开：数据的更新会推高 updated_at，而**删除不会** ——
  # 一条 DELETE 不产生任何时间戳，合成一个水位的话，删完再同步，删除事件
  # 会被"数据水位"挡在外面，表现是"删了的对话在对端又回来了"。
  #
  # peer_node 是**对端的节点标识**，只在"桌面版那一侧的锚点行"里有值，
  # 服务器那边永远是空串。为什么要单开一列而不是塞进 peer：
  #
  #   桌面版**推**的时候还不知道服务器的节点 id（那要等回包），可 state 的
  #   键当时就得定下来。所以桌面版用两行 —— 锚点行的键里是"远端同步目录"
  #   （连上之前就知道），对端行的键才是 `<node>:<email>`。peer_node 就是
  #   把这两行接起来的那根线：从锚点行读出对端叫什么，才找得到接收水位。
  #   服务器不需要这根线：它每次都是从包里直接拿到发送方的节点 id 的。
  #
  # ⚠️ 它**不是**防回声用的。防回声是按 sync_map 筛的（"凡是能从 sync_map
  #    里查到的行都是别人给我的，一律不发回去"，见 R/sync.R 文件头第六节）
  #    —— 按对端节点筛是不行的：第一次推的时候还不知道对端是谁，而第一次推
  #    恰恰最容易回声。这段注释最早就是按"防回声"写的，是错的，改掉了。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_state (
      peer      TEXT PRIMARY KEY,
      peer_node TEXT NOT NULL DEFAULT '',
      in_at     TEXT NOT NULL DEFAULT '',
      in_del    TEXT NOT NULL DEFAULT '',
      out_at    TEXT NOT NULL DEFAULT '',
      out_del   TEXT NOT NULL DEFAULT '',
      last_at   TEXT NOT NULL DEFAULT '',
      note      TEXT NOT NULL DEFAULT ''
    )")
  # ★ V15 item 8：论坛段的水位。
  #
  # ⚠️ **必须和 in_at / out_at 分开**，不能复用。论坛和会话是两个互不相干的
  #    时间线：合用一个水位的话，会话推得快会把论坛的水位一起顶上去 ——
  #    表现是**论坛的内容永远同步不全**（水位比实际收到的靠前，剩下的那些
  #    再也轮不到），而且一句报错都没有。
  #
  # ⚠️ 用 ALTER 而不是改上面那句 CREATE：老库里 sync_state 已经建好了，
  #    `CREATE TABLE IF NOT EXISTS` 对已存在的表是**一句空操作**，新列加不
  #    上去。这个仓库里所有后加的列都是这么做的（users 那十几列、skills.scope、
  #    messages.reasoning 都是）。
  # ★ V16.6 item 2：技能段**自己两条**水位。理由和上面 in_forum 那一段
  #   一字不差，只是换了条时间线：技能正文改动的 updated_at，和技能墓碑的 at。
  #   ⚠️ 两条都要，不能只留一条 —— "改"和"删"是两条独立的时间线，
  #   合用一个的话，改一次技能就会把删除的水位顶上去，老的墓碑再也发不出去
  #   （表现是"删了技能，同步一下它又回来了"）。
  for (col in c("in_forum", "out_forum",
                "in_skills", "out_skills", "in_del_skills", "out_del_skills")) {
    try(DBI::dbExecute(con, sprintf(
      "ALTER TABLE sync_state ADD COLUMN %s TEXT NOT NULL DEFAULT ''", col)),
      silent = TRUE)
  }

  # 「(来源节点, 来源 id) → 本地 id」的映射。跨机撞号就靠它拆开。
  #
  # ★ V13.7 item 7：`peer` 这一列的语义**收窄**了 —— 它现在是"**造出这一行的
  #   那个节点**"（origin node），不再是"把它交给我的那个节点"。两者在直连
  #   同步下是同一个值（A 直接推给 B），所以**老数据不用迁移**；只有转发
  #   （A 造 → B 转给 C）才分得开，而转发是这一版才有的。
  #
  #   为什么必须按"造它的节点"存：反查要用它回答"我这一行是谁造的"，而
  #   会话继续往下转发、以及墓碑要删哪一条，都依赖这个答案唯一且不变。
  #   按"谁交给我的"存的话，同一行经两条路径到达时会得到两个不同的身份。
  #
  # ⚠️ 两个 id 都存**文本**。这不是保守，是必须 —— 这个库里的主键类型
  #    **本来就不统一**（2026-09-16 实测）：
  #        sessions.id        TEXT PRIMARY KEY   （dsapp_id(): s-20260916120000-1234）
  #        messages.id        INTEGER PRIMARY KEY AUTOINCREMENT
  #        messages.session_id TEXT REFERENCES sessions(id)
  #    SYNC.md §2.1 当初写的是"11 张表都是 AUTOINCREMENT"，**sessions 不是**。
  #    把 local_id 写成 INTEGER 的后果很隐蔽：SQLite 的 TEXT 主键列允许
  #    NULL（这是它和别的库不一样的地方），于是 `INSERT INTO sessions
  #    (title, ...)` 不带 id 会**成功**、id 是 NULL、RETURNING id 给回一个
  #    NA —— 不报错、不抛异常，只是在库里留下一批没有主键的对话。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_map (
      peer     TEXT NOT NULL,
      kind     TEXT NOT NULL,
      origin   TEXT NOT NULL,
      local_id TEXT NOT NULL,
      PRIMARY KEY (peer, kind, origin)
    )")
  # 反查用（回答"本地这条在对端叫什么"）。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_sync_map_rev ON sync_map(peer, kind, local_id)")
  # ★ 这个索引服务的是"按本地行反查它的出身"（R/sync.R 的 dsapp_sync_collect
  #   和 .dsapp_sync_origin_of）：
  #     LEFT JOIN sync_map m ON m.kind = 'session' AND m.local_id = s.id
  #   它**按 kind + local_id 查、不带 peer**，所以以 peer 打头的
  #   idx_sync_map_rev 在这里用不上 —— 没有这个索引就是每读一行会话全表扫
  #   一遍 sync_map。sync_map 是只增不减的，跑上几个月之后差别很明显。
  #
  # ⚠️ V13.7 item 7 之前，这里服务的是老防回声条件
  #    （`NOT EXISTS (… WHERE m.kind = 'session' AND m.local_id = sessions.id)`）。
  #    防回声搬到接收端之后那个条件没了，但这个索引**照旧要留着** ——
  #    现在的 JOIN 用的还是同两列。别看到"条件没了"就把它一起删掉。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_sync_map_kind ON sync_map(kind, local_id)")

  # 墓碑：本地删掉的记录。全库没有软删除，删完什么都不剩，对端无从得知。
  #
  # ⚠️ 只由 db_session_delete() 一个地方写（那是全仓库唯一删会话的收口）。
  #    不用 SQLite 触发器：应用对端的墓碑时也会 DELETE，触发器会**再记
  #    一条**，于是两台机器之间来回弹，停不下来。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_tombstone (
      id     INTEGER PRIMARY KEY AUTOINCREMENT,
      kind   TEXT NOT NULL,
      origin TEXT NOT NULL,
      node   TEXT NOT NULL,
      at     TEXT NOT NULL
    )")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_sync_tomb_at ON sync_tombstone(at)")

  # ---- V13.7 item 5：脱离会话的后台续跑 ------------------------------------
  #
  # 用户关掉页面（或者登出）之后，AI 的自动循环要能接着把活干完。那件事跑在
  # 一个**独立的 R 进程**里（R/detach.R 的 .dsapp_agent_worker），它没有
  # Shiny 会话、没有那个全局引擎对象，所以它跟这个应用之间**只剩数据库
  # 这一条路**：状态写这里，界面读这里，"停止"按钮也写这里。
  #
  # ⚠️ 为什么不是内存里的一个对象：Shiny Server 开源版一个应用一个 R 进程，
  #    但它**会重启**（部署、崩溃、systemctl restart）。内存里的登记表一重启
  #    就没了，而那个子进程还在跑 —— 于是界面上什么都看不见，用户也没法停它，
  #    只能等它自己跑完。写库之后，重启的进程照样能看见"有这么一条在跑"。
  #
  # ⚠️ 每个对话**最多一条**（下面那个 UNIQUE）：同一个对话起了两条后台循环
  #    的话，两条会各自往同一条对话里写消息、各自提交任务，用户回来看到的
  #    是两份交错的分析过程 —— 而且两边都以为自己是唯一那个。
  #
  # 状态取值：
  #   running  正在跑
  #   done     跑完了（正常收尾：轮次用完、模型说完了、出错停下）
  #   blocked  **停下等你了** —— 模型写了一段按规则要本人确认才能跑的代码，
  #            后台没人能按那个按钮。和 done 分开是必须的：用户回来该做的事
  #            完全不同（done 不用管，blocked 要去对话里点一下「执行」）。
  #            合成一个的话他会以为活干完了，直接走人。
  #   stopped  被用户按停 / 被新的一轮顶掉
  #   orphan   进程没了但没写收尾（被 kill -9、应用重启时子进程一起没了）
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS agent_runs (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id  TEXT NOT NULL,
      user_id     INTEGER,
      target_json TEXT,
      max_iter    INTEGER,
      state       TEXT NOT NULL DEFAULT 'running',
      note        TEXT,
      task_id     INTEGER,
      started_at  TEXT NOT NULL,
      updated_at  TEXT NOT NULL
    )")
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_arun_sess ON agent_runs(session_id)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_arun_state ON agent_runs(state)")

  invisible(TRUE)
}

# ---- 访问角色（item 7）------------------------------------------------------

#' 一个账号对某个对话是什么身份（纯函数）
#'
#' 这是整个共享功能的**唯一**判据。写成纯函数是为了自检够得着 ——
#' 真正调它的 db_session_role() 要查库，自检里断言不了。
#'
#' 优先级 admin > owner > shared：
#'   - admin：管理页要看得到全部对话，这是既有承诺（见 mod_admin.R 顶部：
#'     "管理员不看你分析的是什么"指的是不该看内容，不是看不到列表）。
#'   - owner：会话行上的 user_id。
#'   - shared：session_share 里有一行。
#'
#' ⚠️ `share_ids` 里出现 owner 自己时仍然是 owner —— 共享给自己是无意义
#'    操作，但不能因此把他降级成只读。
#' @param owner_id  sessions.user_id（可能为 NA：老库里的无主对话）
#' @param share_ids session_share 里被授权的 user_id 向量
#' @param viewer_id 正在看的这个账号
dsapp_session_role <- function(owner_id, share_ids, viewer_id,
                               is_admin = FALSE) {
  if (is.null(viewer_id) || length(viewer_id) != 1 || is.na(viewer_id)) {
    return("none")
  }
  viewer_id <- as.integer(viewer_id)
  if (isTRUE(is_admin)) return("admin")
  if (!is.null(owner_id) && length(owner_id) == 1 && !is.na(owner_id) &&
      identical(as.integer(owner_id), viewer_id)) {
    return("owner")
  }
  ids <- suppressWarnings(as.integer(share_ids))
  ids <- ids[!is.na(ids)]
  if (length(ids) && viewer_id %in% ids) return("shared")
  "none"
}

#' 能看吗（读消息、看任务、下载产物）
dsapp_role_can_view <- function(role) {
  is.character(role) && length(role) == 1 && !is.na(role) &&
    role %in% c("owner", "admin", "shared")
}

#' 能改吗（发消息、跑代码、改名、删除、共享给别人）
#'
#' ⚠️ shared **是只读的**。让被共享的人也能发消息，等于把共享变成了一条
#'    双向通道：owner 只是"给他看一眼结果"，对方却能在 owner 的对话里
#'    跑代码、在 owner 的工作区里写文件、烧 owner 的 API 额度。
#'    要做协作的话那是另一个功能（明确邀请、双方知情），不是共享的默认值。
dsapp_role_can_write <- function(role) {
  is.character(role) && length(role) == 1 && !is.na(role) &&
    role %in% c("owner", "admin")
}

#' 查一个对话对这个账号的身份
#'
#' 返回 "owner" / "shared" / "admin" / "none"。
#' ⚠️ 对话**不存在**时返回 "none"，不是报错 —— 调用方（比如刚被删掉的
#'    那一格还没重渲染）拿到 none 之后应当什么都不做。
#'
#' ⚠️ 这一位是**薄壳**，真正查库的是下面 db_session_role_ex()。要按处境说
#'    不同的话的地方（"已经没了" / "库出错" / "这是别人共享给你的"）用那个，
#'    这里签名和返回值一字不改，全应用三十来个调用点照旧。
db_session_role <- function(sid, user_id, is_admin = FALSE, con = dsapp_db()) {
  db_session_role_ex(sid, user_id, is_admin = is_admin, con = con)$role
}

#' 同上，但把「为什么是 none」一起带出来
#'
#' ★ Test_V16.1 item 3：这个函数是被一个真 bug 逼出来的。
#'
#' db_session_role() 把三种**完全不同的处境**压成同一个 "none"：
#'   ① 对话真的不在了（刚被删掉、侧栏那一格还没重算）
#'   ② 角色查询本身抛错（连接废了、库忙）
#'   ③ 这个账号既不是 owner 也不在共享名单里
#' 删除入口拿到 "none" 之后一律说「这是别人共享给你的对话，删不了」——
#' 于是主账号（平台管理员）在①和②两种情况下会被告知一件**根本不存在的事**，
#' 然后怎么点都删不掉。说错话比不说话更糟：它把用户赶去查一个不相干的
#' "共享"设置，而真正的原因（列表没刷新 / 库出错）一个字都没露。
#'
#' @return list(role = 同 db_session_role 的取值,
#'              why  = "ok" / "no-sid" / "missing" / "db-error",
#'              err  = 出错时的错误文本，否则 NULL)
db_session_role_ex <- function(sid, user_id, is_admin = FALSE, con = dsapp_db()) {
  if (is.null(sid) || length(sid) != 1 || is.na(sid) || !nzchar(as.character(sid))) {
    return(list(role = "none", why = "no-sid", err = NULL))
  }
  # ⚠️ error 分支回的是**错误对象本身**，不再折成 NULL。折成 NULL 之后
  #    "查询抛错"和"查到了 0 行"就再也分不开 —— 那正是上面 ① / ② 的来源，
  #    而它们该对用户说的话完全不同（"已经没了" vs "库出错了"）。
  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT s.user_id AS owner_id,
              (SELECT GROUP_CONCAT(user_id) FROM session_share
                WHERE session_id = s.id) AS share_ids
         FROM sessions s WHERE s.id = ?",
      params = list(as.character(sid))),
    error = function(e) e)
  if (inherits(row, "error")) {
    return(list(role = "none", why = "db-error", err = conditionMessage(row)))
  }
  if (nrow(row) == 0) return(list(role = "none", why = "missing", err = NULL))
  raw <- row$share_ids[[1]]
  ids <- if (is.null(raw) || length(raw) == 0 || is.na(raw) || !nzchar(raw)) {
    integer(0)
  } else {
    as.integer(strsplit(as.character(raw), ",", fixed = TRUE)[[1]])
  }
  list(role = dsapp_session_role(row$owner_id[[1]], ids, user_id, is_admin),
       why = "ok", err = NULL)
}

# ---- 共享名单 ---------------------------------------------------------------

#' 把对话共享给哪些账号（覆盖式写入）
#'
#' 覆盖式而不是增量：界面上是一个勾选框列表，"这次保存之后名单就是这样"
#' 是唯一说得清的语义。增量的话用户取消勾选还得再找一个"移除"按钮。
db_session_share_set <- function(sid, user_ids, granted_by = NULL,
                                 con = dsapp_db()) {
  ids <- suppressWarnings(as.integer(user_ids))
  ids <- ids[!is.na(ids)]
  # 所有者不用写进表里：他是 owner，判据在 sessions.user_id 上。
  # 写进去只会让"这份名单"变成一句需要解释的话。
  owner <- tryCatch(
    DBI::dbGetQuery(con, "SELECT user_id FROM sessions WHERE id = ?",
                    params = list(as.character(sid)))$user_id,
    error = function(e) NA_integer_)
  if (length(owner) == 1 && !is.na(owner)) ids <- setdiff(ids, as.integer(owner))
  ids <- unique(ids)

  DBI::dbWithTransaction(con, {
    cur <- tryCatch(
      DBI::dbGetQuery(con, "SELECT user_id FROM session_share WHERE session_id = ?",
                      params = list(as.character(sid)))$user_id,
      error = function(e) integer(0))
    drop <- setdiff(as.integer(cur), ids)
    if (length(drop)) {
      DBI::dbExecute(con,
        sprintf("DELETE FROM session_share WHERE session_id = ? AND user_id IN (%s)",
                paste(rep("?", length(drop)), collapse = ",")),
        params = c(list(as.character(sid)), as.list(drop)))
    }
    add <- setdiff(ids, as.integer(cur))
    for (u in add) {
      DBI::dbExecute(con,
        "INSERT OR IGNORE INTO session_share
           (session_id, user_id, granted_by, created_at) VALUES (?, ?, ?, ?)",
        params = list(as.character(sid), as.integer(u),
                      if (is.null(granted_by) || is.na(granted_by)) NA_integer_
                      else as.integer(granted_by), dsapp_now()))
    }
  })
  invisible(length(ids))
}

#' 一个对话共享给了谁（带昵称，界面直接用）
db_session_share_list <- function(sid, con = dsapp_db()) {
  if (is.null(sid) || length(sid) != 1 || is.na(sid)) return(character(0))
  tryCatch(
    DBI::dbGetQuery(con,
      "SELECT sh.user_id, COALESCE(u.nickname, '') AS nickname,
              COALESCE(u.email, '') AS email, sh.created_at
         FROM session_share sh
         LEFT JOIN users u ON u.id = sh.user_id
        WHERE sh.session_id = ?
        ORDER BY sh.created_at",
      params = list(as.character(sid))),
    error = function(e) NULL)
}

#' 别人共享给我的对话 id
db_sessions_shared_with <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) != 1 || is.na(user_id)) {
    return(character(0))
  }
  tryCatch(
    DBI::dbGetQuery(con,
      "SELECT session_id FROM session_share WHERE user_id = ?",
      params = list(as.integer(user_id)))$session_id,
    error = function(e) character(0))
}

# ---- 会话 ------------------------------------------------------------------

#' 会话列表
#'
#' @param user_id 只列这个账号的对话。**默认不列任何人的**：V5 之前这里
#'   是无条件全表返回，改成带账号之后，"忘了传 user_id" 必须表现为
#'   "什么都看不到"而不是"看到所有人的"—— 前者一眼就能发现，后者不会。
#' @param all 仅管理页用（列出全部账号的对话）
#'
#' 返回里多两列（item 7）：
#'   `role`       —— owner / shared / admin，界面据此决定给不给改名/删除
#'   `owner_name` —— 共享来的对话要标出"这是谁的"，否则用户会以为自己
#'                   什么时候建过一个叫这个名字的对话
db_sessions_list <- function(user_id = NULL, all = FALSE, con = dsapp_db()) {
  if (isTRUE(all)) {
    return(DBI::dbGetQuery(con,
      "SELECT id, title, created_at, updated_at, 'admin' AS role,
              '' AS owner_name FROM sessions ORDER BY updated_at DESC"))
  }
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(DBI::dbGetQuery(con,
      "SELECT id, title, created_at, updated_at, '' AS role,
              '' AS owner_name FROM sessions WHERE 1 = 0"))
  }
  uid <- as.integer(user_id)
  # ⚠️ 这里**必须**同时列"自己的"和"共享给我的"。只列自己的话，被共享的
  #    对话在左侧列表里根本不出现 —— 授权行建了，人却看不到东西，
  #    用户会以为共享没生效。
  DBI::dbGetQuery(con,
    "SELECT s.id, s.title, s.created_at, s.updated_at,
            CASE WHEN s.user_id = ? THEN 'owner' ELSE 'shared' END AS role,
            COALESCE(u.nickname, '') AS owner_name
       FROM sessions s
       LEFT JOIN session_share sh
              ON sh.session_id = s.id AND sh.user_id = ?
       LEFT JOIN users u ON u.id = s.user_id
      WHERE s.user_id = ? OR sh.user_id IS NOT NULL
      ORDER BY s.updated_at DESC",
    params = list(uid, uid, uid))
}

db_session_create <- function(title = "新会话", user_id = NULL,
                              con = dsapp_db()) {
  now <- dsapp_now()
  id  <- dsapp_id("s")
  DBI::dbExecute(con,
    "INSERT INTO sessions (id, title, user_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)",
    params = list(id, title,
                  if (is.null(user_id) || is.na(user_id)) NA_integer_
                  else as.integer(user_id), now, now))
  id
}

#' 对话的显示名（文件页 / 环境页标题栏用）
#'
#' ⚠️ 不要拿 `as.integer(sid)` 当显示名。任务号是自增整数，对话号**不是** ——
#'    它是 `s-20260913145800-4279` 这种字符串（见 dsapp_id）。照抄任务页的
#'    `sprintf("任务 #%d", as.integer(tid))` 过来，得到的是 `对话 #NA 的工作区`：
#'    界面上是一句没有信息的话，后台还跟着一行 "NAs introduced by coercion"。
#'
#' 优先用标题（左侧列表里显示的就是它，用户能对上号），取不到才退回短号。
db_session_label <- function(sid, con = dsapp_db()) {
  if (is.null(sid) || length(sid) == 0 || is.na(sid) ||
      !nzchar(as.character(sid)[1])) {
    return("")
  }
  sid <- as.character(sid)[1]
  ttl <- tryCatch(
    DBI::dbGetQuery(con, "SELECT title FROM sessions WHERE id = ?",
                    params = list(sid))$title,
    error = function(e) NULL)
  if (is.null(ttl) || !length(ttl) || is.na(ttl[[1]]) || !nzchar(ttl[[1]])) {
    # 对话已经被删了（比如刚删完，页面上那一格还没重渲染）
    return(paste0("对话 ", substr(sid, 1, 22)))
  }
  paste0("对话「", substr(as.character(ttl[[1]]), 1, 20), "」")
}

#' 这个对话属于谁
#'
#' 返回 user_id（整数）或 NULL（无主对话 / 对话已删 / 库出错）。
#' 执行链路用它去查"这个人能占多少机器"（见 dsapp_limits_for_user）。
#'
#' 为什么不从 state 拿：执行是在子进程里跑的，而且 dsapp_run_code 的调用方
#' 有三条路（手动执行、agent 循环、重跑历史任务），里面只有一条手上有 state。
#' 从 session_id 反查是唯一不需要给三条路各加一个参数的做法。
db_session_owner <- function(sid, con = dsapp_db()) {
  if (is.null(sid) || length(sid) == 0 || is.na(sid) ||
      !nzchar(as.character(sid)[1])) {
    return(NULL)
  }
  u <- tryCatch(
    DBI::dbGetQuery(con, "SELECT user_id FROM sessions WHERE id = ?",
                    params = list(as.character(sid)[1]))$user_id,
    error = function(e) NULL)
  if (is.null(u) || !length(u) || is.na(u[[1]])) return(NULL)
  as.integer(u[[1]])
}

db_session_rename <- function(id, title, con = dsapp_db()) {
  DBI::dbExecute(con, "UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?",
                 params = list(title, dsapp_now(), id))

  # ★★ V13.2 item 6：文件管理区里那个同步文件夹的名字里带着标题，跟着改。
  #
  # 用户原话：「目前改任务名称的时候，文件管理系统中的名称并不能一并修改」。
  #
  # 为什么挂**这里**而不是两个调用点上：这条路有两个调用方 ——
  #   · mod_chat.R 收第一条消息时的自动命名（谁也没改，但文件夹名得对上）
  #   · mod_chat.R 用户自己点「改名」
  # 挂在调用点上就得挂两次，而漏掉一次的表现正是用户报的这个 bug
  # （"改了名但文件夹没动"）—— 而且不报错。收口在这里，以后再加第三个
  # 改名入口也不会漏。
  #
  # ⚠️ 传 `con` 进去、不让它自己 `dsapp_db()`：测试传的是临时库，
  #    自己开库会去改真库。
  # ⚠️ 包在 try 里：标题**已经改成功了**，这里失败最多是文件夹名没跟上，
  #    绝不能让"改名"这个动作本身报错。
  try(dsapp_sync_rename(id, title, con = con), silent = TRUE)
}

db_session_touch <- function(id, con = dsapp_db()) {
  DBI::dbExecute(con, "UPDATE sessions SET updated_at = ? WHERE id = ?",
                 params = list(dsapp_now(), id))
}

#' @param cfg 只在**记墓碑**那一步用得上（同步要写"是哪个节点删的"）。
#'   ⚠️ 必须由调用方传进来，不能让下面按默认值取 —— `dsapp_config()` 给的是
#'   **进程默认**那个 data_root，而 `con` 可能是另一个库的连接。两者对不上时
#'   墓碑上记的是**别的节点的 id**，而接收端就是拿这个 id 去 sync_map 里翻
#'   "那我该删哪一条"的 —— 翻不到就静默跳过，表现是**对端怎么也删不掉**，
#'   一句报错都没有。多 data_root 的场景（自检里那个三机转发用例）就是
#'   这么栽的：删除传播整个失效，而所有别的断言都是绿的。
#'
#'   ⚠️ 顺带的另一个后果：默认 cfg 那次的 `dsapp_sync_node_id()` 会去读/写
#'   **默认 data_root 下**的 `.node_id`。那是一次真实的副作用 —— 给一个跟
#'   这次删除毫无关系的目录生成一个节点身份。
db_session_delete <- function(id, con = dsapp_db(), cfg = dsapp_config()) {
  # ⚠️ 记墓碑之前先确认 `con` **就是** `cfg` 说的那个库。
  #
  #   上面 `@param cfg` 那段说的是"调用方要传对"，这一句是"传错了也别出事"。
  #   两者都要：光靠约定，下一个调用点（自检脚本、运维小工具、以后新写的
  #   删除入口）漏传一次，就又是一次**静默的删除传播失效**，而且它不会在
  #   任何断言里露头 —— 2026-09-19 那次就是漏了三处才发现的。
  #
  #   判据走 `PRAGMA database_list`：SQLite 自己报的"这个连接开着哪个文件"，
  #   比"调用方说它是谁"可信。路径都过一遍 normalizePath，免得同一份文件
  #   因为软链、`..`、末尾斜杠这些写法被判成两个（`/srv/shiny-server/DS_App`
  #   就是个软链，线上天天走这条路）。
  #
  #   ⚠️ 取不到就**照记**（`error = function(e) TRUE`）：PRAGMA 都读不出来时
  #      这个连接多半已经废了，紧接着的 DELETE 自己会炸；这里再吞掉墓碑，
  #      只会多一个"删除为什么没传过去"的谜。
  .same_db <- function(con, cfg) tryCatch({
    f <- DBI::dbGetQuery(con, "PRAGMA database_list")
    f <- as.character(f$file[f$name == "main"])
    length(f) == 1L && nzchar(f) &&
      identical(normalizePath(f, mustWork = FALSE),
                normalizePath(cfg$db_path, mustWork = FALSE))
  }, error = function(e) TRUE)
  # messages 有 ON DELETE CASCADE，但那只在外键打开时生效；
  # 这里显式删一次，不依赖 PRAGMA 的状态。
  DBI::dbExecute(con, "DELETE FROM messages WHERE session_id = ?", params = list(id))
  # ⚠️ 任务行必须一起删，否则会留下**永远看不见**的孤儿。
  #
  #    tasks 表没有指向 sessions 的外键（见 dsapp_db_schema），所以删会话
  #    不会连带删任务。而 db_tasks_list() 是靠 `JOIN sessions` 把任务归属到
  #    账号上的 —— 会话行一没，那些任务在任务页里就再也列不出来了：
  #    不报错、不提示，就是凭空少了几条。用户看到的是"我跑了那么多任务，
  #    怎么一条都没有"。
  #
  #    一起删也符合语义：这个会话的工作区（产物所在）本来就要被删掉
  #    （见 mod_chat.R 的 do_del_chat），留着指向已消失目录的任务行没有意义。
  DBI::dbExecute(con, "DELETE FROM tasks WHERE session_id = ?", params = list(id))
  # 共享授权行同理（item 7）：session_share 也没有外键。留着的话它不会
  # 造成越权（db_session_role 先查 sessions，查不到就是 none），但会一直
  # 堆积，而且哪天有人写一句"从 session_share 反查对话"就会踩空。
  DBI::dbExecute(con, "DELETE FROM session_share WHERE session_id = ?",
                 params = list(id))
  # 产物索引（V7）同 session_id，一起清。工作区目录紧接着就会被删掉，
  # 留着索引行只会指向一堆不存在的文件。
  try(DBI::dbExecute(con, "DELETE FROM task_files WHERE session_id = ?",
                     params = list(id)), silent = TRUE)
  # 发布记录（V7）同理。
  #
  # ⚠️ Test_V17.2 item 1：**盘上那批文件由调用方先清**
  #    （`dsapp_session_files_purge()`，在 mod_chat.R 的 do_del_chat 里，
  #    必须赶在这一句**之前**调 —— 行没了就不知道该删哪些落点了）。
  #    这里只删行，一行磁盘代码都不加：本函数是**唯一**的删会话收口，
  #    而它的调用方里有自检的临时库、有同步落地、有"删账号"（那边整棵
  #    `data/files/u<N>/` 由 dsapp_user_purge 端掉）。把 unlink 塞进来，
  #    每次自检删一个假对话都会去碰盘 —— 而 cfg 传错一次就是删真文件。
  try(DBI::dbExecute(con, "DELETE FROM ws_published WHERE session_id = ?",
                     params = list(id)), silent = TRUE)
  # 自动同步的落点（V12 item 3）同理，之前一直漏着。
  #
  # 留着不会造成越权（谁也不会拿一行 sync_dirs 去开门），但会**占着那个
  # 文件夹名字**：`dsapp_sync_free_name()` 是靠 sync_dirs 的行判重名的。
  # 更麻烦的是 session_id 并非永不复用（见下面 session_skills 那段：
  # dsapp_id() 是秒级时间戳 + 4 位随机数），一旦撞上，新对话会**直接继承
  # 上一个已删对话的文件夹名**，产物发进一个标题对不上的目录里去。
  try(DBI::dbExecute(con, "DELETE FROM sync_dirs WHERE session_id = ?",
                     params = list(id)), silent = TRUE)
  # 技能挂载（V8 item 1）同理：session_skills 也没有外键。
  # 留着的话那些行会永远查不出来（技能页是按 sid 查的），越积越多；而且
  # session_id 并非永不复用 —— dsapp_id() 是「秒级时间戳 + 4 位随机数」，
  # 同一个 id 在旧对话删掉之后**是可能被下一个对话撞上的**。一旦撞上，
  # 那个新对话会凭空继承一批它没勾过的技能，而用户在界面上看不到任何
  # 异常来源。概率很小，但清掉是一行的事。
  try(dsapp_session_skills_clear(id, con = con), silent = TRUE)

  # 墓碑（V13.3 item 2）：全库没有软删除，这一句 DELETE 之后，"这里曾经
  # 有过一个对话"在库里没有任何痕迹，同步的另一端也就无从得知该删。
  #
  # ⚠️ 挂在**这里**而不是调用点上，理由和上面 dsapp_sync_rename 那段
  #    一模一样：收口只有一处，以后再加第三个删除入口也不会漏。
  # ⚠️ 包在 try 里：删对话本身已经成功了，墓碑只是"顺带告诉对端"，
  #    绝不能让"记墓碑失败"把删除动作搞成报错。
  # ⚠️ `con` 不是 `cfg` 那个库就**不记** —— 见函数开头那段。记了的话，接收端
  #    拿墓碑上那个（属于别的节点的）id 去 sync_map 里翻，翻不到、静默跳过，
  #    删除永远传不过去；顺带还在**别人家的 data_root** 下建一个 .node_id。
  if (.same_db(con, cfg)) {
    try(dsapp_sync_tombstone_add("session", id, con = con, cfg = cfg),
        silent = TRUE)
  }

  DBI::dbExecute(con, "DELETE FROM sessions WHERE id = ?", params = list(id))
}

# ---- 消息 ------------------------------------------------------------------

db_messages_get <- function(session_id, con = dsapp_db()) {
  DBI::dbGetQuery(con,
    "SELECT id, role, content, reasoning, created_at FROM messages
     WHERE session_id = ? ORDER BY id",
    params = list(session_id))
}

#' 追加一条消息
#'
#' @param reasoning 思维链原文（可空）。**不参与发给模型的上下文** ——
#'   见 mod_chat.R 里拼上下文那段的说明：思维链是给人看的，塞回模型
#'   既浪费额度又会让它反复纠结同一段推理。
#'
#' @return 新消息的 id（invisible）。agent 循环要用它给这一轮"认领" ——
#'   同一条助手消息只能被取走执行一次，见 agent.R 的 dsapp_agent_claim()。
db_message_add <- function(session_id, role, content, reasoning = NULL,
                           con = dsapp_db()) {
  id <- DBI::dbGetQuery(con,
    "INSERT INTO messages (session_id, role, content, reasoning, created_at)
     VALUES (?, ?, ?, ?, ?) RETURNING id",
    params = list(session_id, role, content,
                  if (is.null(reasoning) || !nzchar(reasoning)) NA_character_
                  else reasoning,
                  dsapp_now()))$id
  db_session_touch(session_id, con)
  invisible(as.integer(id))
}

# ---- 任务 ------------------------------------------------------------------

db_task_create <- function(title, code, lang = "R", session_id = NA_character_,
                           con = dsapp_db(), target = NA_character_) {
  id <- DBI::dbGetQuery(con,
    "INSERT INTO tasks (session_id, title, lang, code, status, created_at, target)
     VALUES (?, ?, ?, ?, 'pending', ?, ?) RETURNING id",
    params = list(session_id, title, lang, code, dsapp_now(),
                  if (is.null(target)) NA_character_ else target))$id
  as.integer(id)
}

db_task_get <- function(id, con = dsapp_db()) {
  d <- DBI::dbGetQuery(con, "SELECT * FROM tasks WHERE id = ?", params = list(id))
  if (nrow(d) == 0) return(NULL)
  d[1, , drop = FALSE]
}

#' 批量取任务行的**轻量列**（V9 item 2）
#'
#' 和 db_task_get() 的区别是**不取 code / stdout / stderr**。那三列是任务表
#' 里唯一会长到几 MB 的东西，而"渲染对话流里的执行卡片"只需要知道状态、
#' 耗时、退出码这些几十字节的元信息 —— 输出正文在 tool 消息里已经有了
#' （dsapp_agent_tool_text 写进去的那份，已经裁到 4000 字符）。
#'
#' ⚠️ 必须能批量。历史渲染要按消息条数查任务行，逐条 db_task_get() 的话，
#'    一个跑过几十次执行的对话每发一条新消息都要把几十 MB 的输出列读一遍
#'    再扔掉 —— 而这一切在界面上完全看不出来，只是"越用越慢"。
#'
#' @param ids 任务号向量；空/全 NA 返回 NULL（调用方按"没有卡片"处理）
#' @return data.frame 或 NULL
db_tasks_meta <- function(ids, con = dsapp_db()) {
  ids <- suppressWarnings(as.integer(ids))
  ids <- unique(ids[!is.na(ids)])
  if (!length(ids)) return(NULL)
  # ids 已经过 as.integer，拼进 SQL 不构成注入面；IN 的占位符个数随调用
  # 变化，DBI 的 params 对变长 IN 支持不稳，这里直接拼。
  DBI::dbGetQuery(con, sprintf(
    "SELECT id, session_id, title, lang, status, exit_code, target,
            created_at, started_at, finished_at
       FROM tasks WHERE id IN (%s)",
    paste(ids, collapse = ", ")))
}

#' 任务列表
#'
#' @param user_id 只列这个账号名下对话里的任务。默认**不列任何人的** ——
#'   理由同 db_sessions_list：漏传 user_id 应当表现为"空"，
#'   而不是"所有人的"。
#' @param all 仅管理页用
#' @param with_code 要不要带上 `code` 列。**默认不带**，两个理由：
#'
#'   1. 任务页的关键词搜索是"标题或代码"，只有真的输了关键词才需要这列。
#'      而这一页在任务跑着的时候每 1.5 秒重查一次（见 mod_tasks.R 的
#'      自动刷新）—— 每次都把 200 条任务的完整脚本拉回来，是白烧内存。
#'   2. `dsapp_filter_tasks()` 对 `df$code` 缺席是**静默降级**成"只搜标题"的
#'      （它有一句 `if (is.null(c_)) c_ <- rep("", nrow(df))`）。所以忘记传
#'      with_code 不会报错，只会让搜代码失灵。调用方要清楚自己在做什么。
db_tasks_list <- function(limit = 200, user_id = NULL, all = FALSE,
                          with_code = FALSE, con = dsapp_db()) {
  # 列名在这里拼，前缀分开给：JOIN 那条得带 t.
  cols <- paste0("id, session_id, title, lang, status, exit_code, ",
                 "created_at, started_at, finished_at",
                 if (isTRUE(with_code)) ", code" else "")
  tcols <- paste0("t.id, t.session_id, t.title, t.lang, t.status, t.exit_code, ",
                  "t.created_at, t.started_at, t.finished_at",
                  if (isTRUE(with_code)) ", t.code" else "")

  # 归属（item 7）：界面上要据此决定给不给"重跑 / 停止 / 删除"。
  # 共享来的对话里那些任务对只读访客不能有写操作 —— 见 dsapp_role_can_write。
  if (isTRUE(all)) {
    # ★ V13.11 item 11：这里也带上 session_title。原来这条走的是不带 t. 前缀的
    #   cols，因为 `FROM tasks` 没有别名；加了 JOIN 之后 `id` 在两张表里都有，
    #   不加前缀 SQLite 会直接报 "ambiguous column name" —— 所以这一支改用
    #   tcols。**两条取数路径的列必须完全一致**，否则任务页按名字取列时会在
    #   某一条路径上拿到 NULL，而那种错是不报错的（见 filters.R 里那段
    #   "%||% 看的是第一个元素"的说明）。
    return(DBI::dbGetQuery(con,
      sprintf("SELECT %s, COALESCE(s.title, '') AS session_title,
                      'admin' AS role
               FROM tasks t LEFT JOIN sessions s ON s.id = t.session_id
               ORDER BY t.id DESC LIMIT ?", tcols),
      params = list(limit)))
  }
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(DBI::dbGetQuery(con,
      sprintf("SELECT %s, '' AS session_title, '' AS role
               FROM tasks t WHERE 1 = 0", tcols)))
  }
  uid <- as.integer(user_id)
  # JOIN（不是 LEFT JOIN）：任务的归属只能从 sessions.user_id 推出来，
  # 没有会话行就无从判断它是谁的 —— 见 db_session_delete 的说明，
  # 现在删会话会连它的任务一起删，所以正常情况下不会有孤儿行。
  #
  # ⚠️ WHERE 里那个 EXISTS 就是 item 7：「共享给我的对话里的任务」也要列出来。
  #    漏掉它的话，别人共享给你的对话你打得开、但任务页空空如也 ——
  #    而"这个分析跑了什么、跑成功没有"恰恰是共享最想问的事。
  DBI::dbGetQuery(con,
    sprintf("SELECT %s,
                    COALESCE(s.title, '') AS session_title,
                    CASE WHEN s.user_id = ? THEN 'owner' ELSE 'shared' END AS role
             FROM tasks t
             JOIN sessions s ON s.id = t.session_id
             WHERE (s.user_id = ?
                    OR EXISTS (SELECT 1 FROM session_share sh
                                WHERE sh.session_id = s.id AND sh.user_id = ?))
             ORDER BY t.id DESC LIMIT ?", tcols),
    params = list(uid, uid, uid, limit))
}

#' 某个账号**名下**的任务（管理页用）
#'
#' 和 db_tasks_list(user_id=) 的区别：那个是"我能看到的"（自己的 + 别人共享
#' 给我的），这个只认**归属** —— 管理员查"这个人在跑什么"，共享进来的对话
#' 不属于他，算进去会让任务数对不上他的用量。
#'
#' ⚠️ 判据是 `s.user_id = ?`，不是"他是不是发起人"。任务表里没有发起人列，
#'    归属只能从会话推 —— 见 db_session_owner 的说明。
#'
#' @param limit 最多返回多少行。管理页一次看 200 条足够；不限量的话，一个跑过
#'   几万次任务的老账号会把这一页拖到打不开。
#' @return data.frame，无数据时是**零行**而不是 NULL
db_tasks_by_owner <- function(user_id, limit = 200, con = dsapp_db()) {
  cols <- paste0("t.id, t.session_id, t.title, t.lang, t.status, t.exit_code, ",
                 "t.created_at, t.started_at, t.finished_at, ",
                 "COALESCE(s.title, '（对话已删除）') AS session_title")
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(DBI::dbGetQuery(con,
      sprintf("SELECT %s FROM tasks t LEFT JOIN sessions s ON s.id = t.session_id
               WHERE 1 = 0", cols)))
  }
  # LEFT JOIN，不是 JOIN：删账号时任务会跟着会话一起删（dsapp_user_delete），
  # 但万一库里有历史残留（V3 之前删过会话的那些行），JOIN 会把它们静默吞掉，
  # 表现是"任务数比用量里的少"而没人知道为什么。
  DBI::dbGetQuery(con,
    sprintf("SELECT %s FROM tasks t
             LEFT JOIN sessions s ON s.id = t.session_id
             WHERE s.user_id = ? ORDER BY t.id DESC LIMIT ?", cols),
    params = list(as.integer(user_id), as.integer(limit)))
}

#' 某个账号名下任务的状态计数
#'
#' 单独一个查询而不是数上面那份行：上面那份是**截断过的**（LIMIT），
#' 拿它算"正在跑几个"会在任务多的账号上少算 —— 而"正在跑"正是这一页
#' 最需要准的一个数。
#'
#' @return 具名整数向量，键是状态（无数据时是长度 0 的向量）
#' @param session_ids V13.8 item 1：只看这些对话里的任务（字符向量），
#'   `NULL` = 不限。给管理页的项目管理员用 —— 他数"这个账号跑成功几个"
#'   时，该数的只是他**分发出去**的那些对话里的任务，不是这个人名下的全部。
#'   ⚠️ 空向量 `character(0)` 的意思是"一个都不看"，和 `NULL` 相反。
db_task_counts_by_owner <- function(user_id, session_ids = NULL,
                                    con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(stats::setNames(integer(0), character(0)))
  }
  sql <- "SELECT t.status, COUNT(*) AS n FROM tasks t
            LEFT JOIN sessions s ON s.id = t.session_id
           WHERE s.user_id = ?"
  params <- list(as.integer(user_id))
  if (!is.null(session_ids)) {
    sid <- as.character(session_ids)
    # 空集时要给出的是一条恒假的 SQL，不是 "IN ()"（那是语法错误，
    # 会被下面的 tryCatch 吞成"这个账号还没跑过任务"—— 一句假话）。
    if (length(sid) == 0) {
      sql <- paste(sql, "AND 1 = 0")
    } else {
      sql <- paste0(sql, " AND t.session_id IN (",
                    paste(rep("?", length(sid)), collapse = ","), ")")
      params <- c(params, as.list(sid))
    }
  }
  sql <- paste(sql, "GROUP BY t.status")
  r <- tryCatch(DBI::dbGetQuery(con, sql, params = params),
                error = function(e) NULL)
  if (is.null(r) || nrow(r) == 0) {
    return(stats::setNames(integer(0), character(0)))
  }
  stats::setNames(as.integer(r$n), as.character(r$status))
}

db_task_status <- function(id, status, exit_code = NULL,
                           stdout = NULL, stderr = NULL,
                           workdir = NULL, con = dsapp_db()) {
  # DBI 不接受 NULL 当绑定值，会报 "Parameter N does not have length 1"。
  # 这里的参数全是可选的（错误路径只传 stderr，正常路径不传 workdir 的情况
  # 也存在），所以统一在入口把 NULL 折成 NA —— 放在这一个地方处理，
  # 比要求每个调用点都记得传 NA_character_ 可靠。
  nn <- function(x) if (is.null(x)) NA else x

  # 分状态写：开始执行时只更新 started_at，结束时才写结果。
  # 用一个 UPDATE 覆盖全部字段的话，"开始执行"这一步会把上一次的
  # 输出内容抹掉，页面在任务运行期间会闪一下空白。
  if (identical(status, "running")) {
    DBI::dbExecute(con,
      "UPDATE tasks SET status = 'running', started_at = ? WHERE id = ?",
      params = list(dsapp_now(), id))
  } else {
    DBI::dbExecute(con,
      "UPDATE tasks SET status = ?, exit_code = ?, stdout = ?, stderr = ?,
                        workdir = COALESCE(?, workdir), finished_at = ?
       WHERE id = ?",
      params = list(status, nn(exit_code), nn(stdout), nn(stderr), nn(workdir),
                    dsapp_now(), id))
  }
  invisible(TRUE)
}

db_task_delete <- function(id, con = dsapp_db()) {
  DBI::dbExecute(con, "DELETE FROM tasks WHERE id = ?", params = list(id))
  # 产物索引跟着走。留着的话文件页会把一个已经不存在的任务的标题显示成
  # 分组名 —— 点进去什么都没有，看着像文件被删了。
  try(DBI::dbExecute(con, "DELETE FROM task_files WHERE task_id = ?",
                     params = list(id)), silent = TRUE)
}

# ---- 任务产物索引（V7） ----------------------------------------------------

#' 记一次任务产出
#'
#' 在任务收尾、产物差集算出来之后调用一次（见 app.R 的执行收尾）。
#' **先删后插**，语义是"这个任务的产物就是这些" —— 重跑同一个任务时
#' 上一次的行必须消失，否则文件页会把早就被覆盖的旧名字也列出来。
#'
#' @param names 相对工作区的路径（executor 给的 `artifacts`）
#'
#' ⚠️ 调用方必须 tryCatch。这条路径在"任务刚跑完、用户正在看结果"的时刻
#'    上，写索引失败不该把结果本身毁掉 —— 索引丢了只是文件页少个分组。
db_task_files_set <- function(task_id, session_id, names, con = dsapp_db()) {
  if (is.null(task_id) || is.na(task_id)) return(invisible(FALSE))
  names <- as.character(names %||% character(0))
  names <- names[!is.na(names) & nzchar(names)]
  now <- dsapp_now()
  DBI::dbExecute(con, "DELETE FROM task_files WHERE task_id = ?",
                 params = list(as.integer(task_id)))
  if (!length(names)) return(invisible(TRUE))
  # 一次事务：这批行要么全在要么全不在。半批的话文件页会显示"这个任务
  # 产出了 3 个文件"而实际有 7 个，且没有任何迹象说明少了。
  DBI::dbWithTransaction(con, {
    for (nm in names) {
      DBI::dbExecute(con,
        "INSERT OR REPLACE INTO task_files (task_id, session_id, name, created_at)
         VALUES (?, ?, ?, ?)",
        params = list(as.integer(task_id), session_id, nm, now))
    }
  })
  invisible(TRUE)
}

#' 工作区文件 → 产出它的任务
#'
#' @return data.frame(name, task_id)，每个名字只留**最新**的那个任务。
#'   同一个路径被后来的任务覆盖时（第二次跑写同名文件），归属要跟着走 ——
#'   否则用户点开旧任务的分组，看到的是新任务的内容。
db_task_files_map <- function(session_id, con = dsapp_db()) {
  empty <- data.frame(name = character(0), task_id = integer(0),
                      stringsAsFactors = FALSE)
  if (is.null(session_id) || !nzchar(session_id)) return(empty)
  tryCatch(
    DBI::dbGetQuery(con,
      "SELECT name, MAX(task_id) AS task_id FROM task_files
       WHERE session_id = ? GROUP BY name",
      params = list(session_id)),
    error = function(e) empty)
}

# ---- 发布记录（V7） --------------------------------------------------------

#' 记一次「发布」：工作区里的 name 落到了共享区的 dest
#'
#' 同一个 (session, name) 重复发布只留最新一条 —— 重名时共享区会多出一个
#' 带序号的文件，但"这一份发布过"这件事只有一件。
db_ws_pub_set <- function(session_id, name, dest, con = dsapp_db()) {
  if (is.null(session_id) || !nzchar(session_id)) return(invisible(FALSE))
  if (is.null(name) || !nzchar(name)) return(invisible(FALSE))
  tryCatch({
    DBI::dbExecute(con,
      "INSERT OR REPLACE INTO ws_published (session_id, name, dest, created_at)
       VALUES (?, ?, ?, ?)",
      params = list(session_id, name, dest %||% basename(name), dsapp_now()))
    invisible(TRUE)
  }, error = function(e) invisible(FALSE))
}

#' 这个对话的自动同步落点（共享区里的相对路径，V12 item 3）
#'
#' 没同步过就返回 NULL。建表说明见 dsapp_db_schema 里 sync_dirs 那一段。
db_sync_dir_get <- function(session_id, con = dsapp_db()) {
  if (is.null(session_id) || !nzchar(session_id)) return(NULL)
  tryCatch({
    r <- DBI::dbGetQuery(con, "SELECT dir FROM sync_dirs WHERE session_id = ?",
                         params = list(session_id))$dir
    if (!length(r) || is.na(r[[1]]) || !nzchar(r[[1]])) NULL else as.character(r[[1]])
  }, error = function(e) NULL)
}

#' 记下这个对话的自动同步落点。重复调用只改不改名（INSERT OR REPLACE 用的是
#' 同一个 key，调用方只在取不到的时候才生成新名字）。
db_sync_dir_set <- function(session_id, dir, con = dsapp_db()) {
  if (is.null(session_id) || !nzchar(session_id)) return(invisible(FALSE))
  if (is.null(dir) || !nzchar(dir)) return(invisible(FALSE))
  tryCatch({
    DBI::dbExecute(con,
      "INSERT OR REPLACE INTO sync_dirs (session_id, dir, created_at)
       VALUES (?, ?, ?)",
      params = list(session_id, dir, dsapp_now()))
    invisible(TRUE)
  }, error = function(e) invisible(FALSE))
}

#' 这个账号名下都对话过什么（★ V17.2 item 3：跨会话）
#'
#' 文件区是按**账号**共用的（`data/files/u<N>/`），所以同一个账号下别的对话
#' 同步出去的产物，在当前对话里也看得见 —— 但看得见的只有**一行路径**。
#' 模型拿到 `单细胞分析-4279/results/expr.rds` 时，无从判断这是用户上传的
#' 原始数据、它自己上一轮的中间产物，还是**另一个对话**跑出来的成果。
#'
#' 这个函数就是那张对照表：
#'   · `convs` —— 对话本身（标题 / 最后活动 / 消息数 / 产物文件夹）
#'   · `pub`   —— `ws_published` 里"哪个对话发布过哪个落点"。
#'     手动发布到管理区**根**上的文件不在任何文件夹里，认领它们只能靠这张表。
#'
#' ⚠️ 只查**同一个账号**的对话。同步文件夹是按账号分的，别人账号的对话名
#'    出现在这个人的提示词里既是泄露，模型照着去找文件也一定会落空。
#' ⚠️ 只读。这里**不建** sync_dirs 行 —— 那等于"模型看一眼提示词，平台就替
#'    别人的对话定了个落点"。落点只由同步那条路（`dsapp_sync_dir`）写。
#' ⚠️ 出错/取不到账号一律返回**空表**：提示词里少一段，用户看到的是
#'    "AI 好像不记得我之前那个对话"，而不是整页报错（这条提示词是在每次
#'    请求里拼的，它抛异常 = 用户发不出消息）。
#'
#' @param user_id 账号 id。NA/NULL（比如 _anon）⇒ 空表。
#' @param sid     当前对话 id，用来标 `is_self`。
#' @return list(convs = data.frame(session_id,title,updated_at,n_msg,dir,is_self),
#'              pub   = data.frame(dest,session_id,title,is_self))
dsapp_conv_index <- function(user_id, sid = NULL, con = dsapp_db()) {
  blank <- list(
    convs = data.frame(session_id = character(0), title = character(0),
                       updated_at = character(0), n_msg = integer(0),
                       dir = character(0), is_self = logical(0),
                       stringsAsFactors = FALSE),
    pub   = data.frame(dest = character(0), session_id = character(0),
                       title = character(0), is_self = logical(0),
                       stringsAsFactors = FALSE))
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(blank)
  sid <- if (is.null(sid) || !length(sid) || is.na(sid[[1]])) ""
         else as.character(sid[[1]])
  tryCatch({
    convs <- DBI::dbGetQuery(con,
      "SELECT s.id AS session_id, s.title AS title, s.updated_at AS updated_at,
              COALESCE(d.dir, '') AS dir,
              (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS n_msg
         FROM sessions s
         LEFT JOIN sync_dirs d ON d.session_id = s.id
        WHERE s.user_id = ?
        ORDER BY s.updated_at DESC",
      params = list(uid))
    convs$n_msg   <- as.integer(convs$n_msg)
    # NA 安全的相等：session_id 理论上不会是 NA，但标题可能是，别让一行脏
    # 数据把整个逻辑向量变成 NA（`&` 会把 NA 传下去，下游 if() 就报错了）。
    convs$is_self <- nzchar(sid) &
      !is.na(convs$session_id) & as.character(convs$session_id) == sid
    pub <- DBI::dbGetQuery(con,
      "SELECT p.dest AS dest, p.session_id AS session_id, s.title AS title
         FROM ws_published p
         JOIN sessions s ON s.id = p.session_id
        WHERE s.user_id = ?",
      params = list(uid))
    pub$is_self <- nzchar(sid) &
      !is.na(pub$session_id) & as.character(pub$session_id) == sid
    # 同一个落点被两个对话发过时（理论上只有自己跟自己），留最早那条就行 ——
    # 提示词里只用来标"来自对话「X」"，多标一个不会更有用。
    if (nrow(pub)) pub <- pub[!duplicated(pub$dest), , drop = FALSE]
    list(convs = convs, pub = pub)
  }, error = function(e) blank)
}

#' 这个对话发布过哪些工作区文件
#'
#' @return data.frame(name, dest)。`name` 是工作区内的相对路径（可能带
#'   `/`），`dest` 是共享区里的落点。
db_ws_pub_map <- function(session_id, con = dsapp_db()) {
  empty <- data.frame(name = character(0), dest = character(0),
                      stringsAsFactors = FALSE)
  if (is.null(session_id) || !nzchar(session_id)) return(empty)
  tryCatch(
    DBI::dbGetQuery(con,
      "SELECT name, dest FROM ws_published WHERE session_id = ?",
      params = list(session_id)),
    error = function(e) empty)
}

#' 发布记录里的落点跟着同步文件夹改名走（V13.2 item 6）
#'
#' 自动同步出去的那批 `dest` 长成 `<同步文件夹>/<工作区里的相对路径>`（见
#' files.R 的 dsapp_sync_artifacts，它写的是 `file.path(rel, a)`）。对话被
#' 改名、同步文件夹跟着换了名字之后，这些 dest 就成了**指向不存在的地方的
#' 旧路径**。两处会因此出错，而且都不报错：
#'
#'   · 界面上的「已发布」标记会退回「仅本对话」—— 它是拿 dest 去管理区
#'     当前列表里比对的，旧路径当然不在里面。用户看到的是"我发布过的东西
#'     怎么又变成本对话的了"。
#'   · 更糟的是 dsapp_sync_artifacts 里那个 `mine` 集合也来自这张表：它用
#'     来判断"管理区里那个同名文件是不是我自己上一轮同步出去的"。认不出来
#'     就会**另起一个名字**（绝不覆盖别人传上来的东西 —— 那条规则本身没错），
#'     于是一次重跑之后管理区里多出一个 `plot(1).png`，跑几次多几个。
#'
#' ⚠️ 在 R 里切前缀，**不用** SQL 的 LIKE：路径里 `_` 和 `%` 都是合法字符，
#'    LIKE 会把它们当通配符（`my_data` 能匹配到 `myXdata`）。同样的坑和解法
#'    见 users.R 的 dsapp_file_owner_move。表里行数是个位到百位级，逐条
#'    UPDATE 完全够用。
#'
#' @return invisible(改了几行)
db_ws_pub_reprefix <- function(session_id, from, to, con = dsapp_db()) {
  if (is.null(session_id) || !nzchar(session_id)) return(invisible(0L))
  if (is.null(from) || is.null(to) || !nzchar(from) || !nzchar(to) ||
      identical(from, to)) {
    return(invisible(0L))
  }
  rows <- tryCatch(
    DBI::dbGetQuery(con, "SELECT id, dest FROM ws_published WHERE session_id = ?",
                    params = list(session_id)),
    error = function(e) NULL)
  if (is.null(rows) || !nrow(rows)) return(invisible(0L))

  d <- as.character(rows$dest)
  # 自己那一层（`dest == from`，不该出现但兜住）和它下面每一层都要搬
  hit <- !is.na(d) & (d == from | startsWith(d, paste0(from, "/")))
  if (!any(hit)) return(invisible(0L))
  new <- paste0(to, substr(d[hit], nchar(from) + 1L, nchar(d[hit])))

  ids <- rows$id[hit]
  for (k in seq_along(new)) {
    try(DBI::dbExecute(con, "UPDATE ws_published SET dest = ? WHERE id = ?",
                       params = list(new[[k]], ids[[k]])), silent = TRUE)
  }
  invisible(sum(hit))
}

# ---- token 用量 ------------------------------------------------------------

#' 记一轮生成的 token 用量
#'
#' @param usage 厂商原始 usage 对象（直接透传，见 llm.R 的
#'   dsapp_usage_numbers）。**厂商不报用量时静默返回 FALSE，不写行** ——
#'   写一行全 NULL 的记录会让管理页的合计看起来像"用了 0 个 token"，
#'   那是个理直气壮的假数字（同一理由见 dsapp_usage_text）。
#'
#' @return invisible(TRUE/FALSE) —— 是否真的写了一行
#'
#' ⚠️ 调用方**必须**用 tryCatch 包住。这条路径在"生成刚刚成功、用户正在
#'    看回复"的时刻上，写库失败（锁超时、磁盘满）绝不能把那一轮回复
#'    一起毁掉：用量是统计，回复是用户的劳动成果，两者不是一个量级。
db_usage_add <- function(user_id, session_id, usage, scene = "", model = "",
                         con = dsapp_db()) {
  u <- dsapp_usage_numbers(usage)
  if (is.null(u)) return(invisible(FALSE))

  nn_int <- function(x) if (is.null(x)) NA_integer_ else as.integer(round(x))
  now <- dsapp_now()

  DBI::dbExecute(con,
    "INSERT INTO usage_log (user_id, session_id, scene, model,
                            prompt_tokens, completion_tokens, total_tokens,
                            day, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(
      if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) NA_integer_
      else as.integer(user_id),
      if (is.null(session_id) || !length(session_id) || is.na(session_id)) NA_character_
      else as.character(session_id),
      as.character(scene %||% ""), as.character(model %||% ""),
      nn_int(u$prompt), nn_int(u$completion), nn_int(u$total),
      # 存 UTC 日期（dsapp_now 就是 UTC）。管理页按天聚合时读这一列，
      # 不做时区换算 —— 它是**运营口径**的"这一天用了多少"，
      # 差几个小时的边界无所谓，而每次查询都 strftime 一遍不划算。
      substr(now, 1, 10), now))
  invisible(TRUE)
}

#' 按账号汇总用量
#'
#' @return data.frame(user_id, total, prompt, completion, n_calls)
db_usage_by_user <- function(con = dsapp_db()) {
  tryCatch(DBI::dbGetQuery(con, "
    SELECT user_id,
           SUM(COALESCE(total_tokens, 0))      AS total,
           SUM(COALESCE(prompt_tokens, 0))     AS prompt,
           SUM(COALESCE(completion_tokens, 0)) AS completion,
           COUNT(*)                            AS n_calls
    FROM usage_log GROUP BY user_id"), error = function(e) NULL)
}

#' 按天汇总用量（最近 n 天，倒序）
db_usage_by_day <- function(days = 14, con = dsapp_db()) {
  tryCatch(DBI::dbGetQuery(con, "
    SELECT day,
           SUM(COALESCE(total_tokens, 0))  AS total,
           COUNT(*)                        AS n_calls,
           COUNT(DISTINCT user_id)         AS n_users
    FROM usage_log WHERE day <> ''
    GROUP BY day ORDER BY day DESC LIMIT ?",
    params = list(as.integer(days))), error = function(e) NULL)
}

#' 某个账号的累计用量
#'
#' 给 #39 的配额强制用：管理页显示的数字和真正拦人的数字必须是**同一个
#' 函数算出来的**，否则会出现"页面上说没超、提交时被拒"这种没法解释的状态。
db_usage_user_total <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(0)
  v <- tryCatch(DBI::dbGetQuery(con,
    "SELECT COALESCE(SUM(COALESCE(total_tokens, 0)), 0) AS n
     FROM usage_log WHERE user_id = ?",
    params = list(as.integer(user_id)))$n[[1]], error = function(e) 0)
  as.numeric(v %||% 0)
}

#' 关闭连接
#'
#' 应用退出时调用，确保 WAL 内容合并回主库文件。
dsapp_db_close <- function() {
  st <- dsapp_state()
  if (!is.null(st$db)) {
    try(DBI::dbDisconnect(st$db), silent = TRUE)
    st$db <- NULL
  }
  invisible(TRUE)
}
