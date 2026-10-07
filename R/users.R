# =============================================================================
# 账号（注册 / 登录 / 数据归属）
# =============================================================================
# V5 引入。此前这个应用**没有登录**，所有对话、任务、文件全局共享 —— 那是个
# 刻意的取舍（共享区里的东西所有访客可见，界面上如实写着）。V5 改成按账号
# 归属，理由不是"要个登录框"，而是两件具体的事：
#
#   1. 用户要能**找回自己之前的操作**。没有账号时，换台电脑、清一次浏览器
#      缓存，之前跑过的对话就再也找不回来了 —— 对话在库里，但没有任何线索
#      指向"这是谁的"。
#   2. 隔离要有主体。工作区和环境早就按**对话**隔离了，但"谁可以打开这个
#      对话"没有答案。有了账号，隔离链条才闭合：账号 → 对话 → 工作区/环境。
#
# ⚠️ 这不是一个认证系统，别按认证系统的标准去读它：
#    * 没有邮箱验证、没有找回密码的邮件通道、没有会话过期策略；
#    * 身份靠浏览器里一个长期 cookie 维持，清掉 cookie 就要用邮箱 + 密码
#      （或恢复码）重新认领；
#    * **V13.1 item 7 起密码是必填的**。原来"不设密码的账号凭邮箱就能进"
#      那条路已经**整条删掉**了，不是默认关掉 —— 见 dsapp_user_auth 里
#      无密码账号那一支。老库里那些 pass_hash = '' 的账号从此登不进来，
#      只能由管理员重置密码，或者用当初那张恢复码。
#
#    ⚠️ 这段原来写的是「真正的敏感数据（API Key、SSH 密码、私钥）**依然不落盘**」。
#    **V6 起 API Key 不在这句话里了** —— 它按账号存进 users.llm_api_key，
#    是用户明确要求"记住"的结果。仍然不落盘的只剩 SSH 密码/私钥，见 app.R 里
#    state 的说明和 R/remote.R。
#
#    ★ V13.1 item 9：**那一列现在是密文**（AES-GCM，钥匙串在
#      data_root/.keyring 0600）—— 见 R/crypto.R 顶部那张"挡得住什么/
#      挡不住什么"的清单。所以"谁能读这个库文件谁就拿到所有人的 Key"
#      这句话，现在要加一个前提：**还得能读那台机器上的钥匙串**。
#      而钥匙串和库在同一台机器上，所以对 root 来说结论没变 ——
#      这不是"加密了就安全了"，只是把"拷走一个文件"这条路堵上了。
# =============================================================================

#' 建表（幂等）
#'
#' 在 dsapp_db_schema() 里调用，所以任何一次 dsapp_db() 都会把表补齐 ——
#' 老库升级上来不用手工跑迁移。
dsapp_db_schema_users <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS users (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      nickname    TEXT NOT NULL,
      email       TEXT NOT NULL,
      phone       TEXT NOT NULL DEFAULT '',
      field       TEXT NOT NULL DEFAULT '',
      pass_salt   TEXT NOT NULL DEFAULT '',
      pass_hash   TEXT NOT NULL DEFAULT '',
      token       TEXT NOT NULL DEFAULT '',
      is_admin    INTEGER NOT NULL DEFAULT 0,
      status      TEXT NOT NULL DEFAULT 'active',
      must_change_pw INTEGER NOT NULL DEFAULT 0,
      created_at  TEXT NOT NULL,
      last_seen_at TEXT
    )")
  # 邮箱唯一，但按**归一化后**的（小写去空格）唯一 —— 见 dsapp_user_norm_email。
  # 不建 UNIQUE 约束而是建唯一索引：老库升级时若已有重复行，建索引会失败，
  # 那时宁可让索引缺失（下面 db 层还会查重）也不要让整个应用起不来。
  try(DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email)"),
    silent = TRUE)

  # 文件归属。`name` 是相对 files_dir 的**相对路径**（V5 起共享区有子目录；
  # 以前是平铺的文件名，两者在表里长得一样 —— 老行的 "expr.csv" 就是根目录
  # 下的那个文件，不需要迁移）。
  #
  # 用独立表而不是给 files_dir 里的文件加后缀：文件名是用户看得见、会写进
  # 代码里的东西（read.csv("expr.csv")），动它等于把所有人的脚本都改坏。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS file_owner (
      name       TEXT PRIMARY KEY,
      user_id    INTEGER,
      created_at TEXT NOT NULL
    )")

  # 每账号磁盘配额（V5 追加）。NULL / 0 = 不限。
  #
  # 用 GB 而不是字节：这一列是给人填的（管理页一个输入框），而"给我 200 G"
  # 是人的说法，"214748364800"不是。换算只在一个地方做（dsapp_user_quota_bytes）。
  #
  # ⚠️ 默认**不限**（NULL）。这很重要：配额是管理动作，不是产品默认值。
  #    凭空给每个新账号设一个上限，会让第一个用大数据集的人撞到一堵他没
  #    听说过的墙 —— 而唯一的线索是一句"空间不足"。
  ucols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(users)")$name,
                    error = function(e) character(0))
  if (!"quota_gb" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN quota_gb REAL"),
        silent = TRUE)
  }

  # 「管理员重置了密码，用户下次登录必须先改掉」的标记（V5 追加）。
  #
  # 为什么需要这个标记：管理员重置密码时只能**指定**一个新密码（没有邮件
  # 通道可以发一次性链接），而那个密码是管理员定的、经过管理员的手 ——
  # 它不该长期有效。留一个标记，用户下次进来就被拦下来换成自己的，
  # 管理员知道的那个密码从此失效。
  if (!"must_change_pw" %in% ucols) {
    try(DBI::dbExecute(con,
      "ALTER TABLE users ADD COLUMN must_change_pw INTEGER NOT NULL DEFAULT 0"),
      silent = TRUE)
  }

  # ---- 跨机同步的账号身份（V16.6 item 1）-----------------------------------
  #
  # `sync_pubkey`：这个账号在**别的机器**上那台客户端用来签同步包的
  # Ed25519 公钥（64 个十六进制字符）。空串 = 没绑定过。
  #
  # ★ 为什么加这一列、以及为什么它放在 users 上而不是另起一张表：
  #   同步的**写方向**（桌面版 → 服务器）从此不再用"密码现推的 HMAC"，
  #   而是用公钥验签。理由是本仓的威胁模型自己写明的：用户代码和应用
  #   同一个 uid（R/executor.R:9-11），**任何能跑分析代码的人都能读
  #   dsapp.sqlite3**。用 HMAC 的话，读一次库就能拿到推同步包所需的全部
  #   材料，等于任何一个能跑代码的用户都能往别人账号里塞会话 —— 而
  #   "密码哈希"至少还得先爆破一次。公钥是公开的，读到它不产生任何能力。
  #
  # ⚠️ 公钥**不是**密码，泄漏它没有任何后果，所以这一列不进任何密钥
  #    加密的范畴（和 llm_api_key 那四列不是一回事）。反过来，**私钥
  #    永远只在客户端那台机器上**，服务器从头到尾见不到它。
  if (!"sync_pubkey" %in% ucols) {
    try(DBI::dbExecute(con,
      "ALTER TABLE users ADD COLUMN sync_pubkey TEXT NOT NULL DEFAULT ''"),
      silent = TRUE)
  }
  # 这个账号是哪台机器通过同步"认领"出来的（空 = 网页版自己注册的）。
  # 只用于后台管理页展示和审计，**不参与任何鉴权判断**。
  if (!"sync_claimed_at" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN sync_claimed_at TEXT"),
        silent = TRUE)
  }
  if (!"sync_claimed_from" %in% ucols) {
    try(DBI::dbExecute(con,
      "ALTER TABLE users ADD COLUMN sync_claimed_from TEXT NOT NULL DEFAULT ''"),
      silent = TRUE)
  }

  # ---- 按账号记住的模型设置（V6 追加，item 1）------------------------------
  #
  # ⚠️ 这四列**推翻**了 V3 以来"API Key 绝不落盘"的决定。是用户明确要求的：
  #    "每次进入需要重新填写 API 和 key，请保留记忆功能"。
  #
  #    旧的顾虑（库被拷走 Key 就跟着走）依然成立，没有消失，只是被换成了
  #    一个更烦人的日常成本。所以：
  #      · 界面上必须**如实说明** Key 现在是存在服务器上的；
  #      · 提供「清除已保存的 Key」按钮，用户想回到"每次重填"可以随时回；
  #      · 库文件的权限必须收紧（data/ 归 biomamba + ACL 给 shiny，
  #        两者之外谁也读不到）。DEPLOYMENT.md 里有这一条。
  #
  #    不要把这四列并进 state —— state 是会话内存，这两条路都要留着。
  if (!"llm_vendor" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN llm_vendor TEXT"),
        silent = TRUE)
  }
  if (!"llm_model" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN llm_model TEXT"),
        silent = TRUE)
  }
  if (!"llm_base_url" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN llm_base_url TEXT"),
        silent = TRUE)
  }
  if (!"llm_api_key" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN llm_api_key TEXT"),
        silent = TRUE)
  }

  # ---- 每账号的界面皮肤（V8 追加，item 4）----------------------------------
  #
  # 存的是 R/skins.R 里 DSAPP_SKINS 的**键**（"dark" / "light" / …），不是
  # 颜色值 —— 存颜色的话，以后调一次配色就要去改所有人的数据。
  #
  # ⚠️ NULL 是**合法状态**（老库升上来就是这样），含义是"没选过"，由
  #    dsapp_skin_get() 收敛成默认皮肤。不要写 UPDATE 去把 NULL 填成
  #    'dark'：那样就分不清"从没选过"和"明确选了深色"，而这两件事以后
  #    大概率要区别对待（比如"跟随系统"上线时，前者应该跟着系统走）。
  if (!"skin" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN skin TEXT"),
        silent = TRUE)
  }

  # ---- 每账号的面板尺寸（V13.2 追加，item 5）-------------------------------
  #
  # 一列 JSON：`{"files_w":420,"composer_h":0}`。哪些键、各自默认多少、
  # 上下限是多少，全在 R/uiprefs.R 里；这里只负责存。
  #
  # ⚠️ 和 skin 一样，NULL 是**合法状态**（老库升上来就是这样），含义是
  #    "没调过"，由 dsapp_uipref_get() 收敛成默认值。
  if (!"ui_prefs" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN ui_prefs TEXT"),
        silent = TRUE)
  }

  # ---- 管理员分级（V13.8 追加，item 1）-------------------------------------
  #
  # 用户的原话：「管理页面需要区分项目管理员和平台管理员，项目管理员只能查看
  # 并更改自己分发出去的任务、组内的账号成员，而平台管理员可以更改、添加、
  # 删除平台内所有的账号与任务」。
  #
  # 取值：
  #   ''          普通用户
  #   'project'   项目管理员 —— 管理页照常进得去，但只看得到自己那一片
  #   'platform'  平台管理员 —— 全平台
  #
  # ⚠️ **is_admin 和 admin_scope 是一件事的两半，必须同时维护**：
  #      is_admin = 1  ⟺  admin_scope ∈ {'project','platform'}
  #    is_admin 管的是"进不进得去管理页"（app.R 里的那道 UI 闸），
  #    admin_scope 管的是"进去之后能碰谁"。写成两个各自为政的开关的话，
  #    迟早出现"进得去但什么都动不了"或者更糟的"看得见所有人的账号"。
  #    唯一的写入口是 dsapp_user_set_admin()，别在别处 UPDATE 这两列。
  #
  # ⚠️ 为什么不用一个 INTEGER 存三档（0/1/2）：管理页的按钮权限、审计日志、
  #    以及"这个人到底是哪种管理员"这句话在界面上要反复出现，而 `>= 1` 这种
  #    比较每写一次就多一个可以写反的地方。字符串三态一眼看得懂，也经得起
  #    以后再加一档（比如 'auditor'）。
  if (!"admin_scope" %in% ucols) {
    try(DBI::dbExecute(con,
      "ALTER TABLE users ADD COLUMN admin_scope TEXT NOT NULL DEFAULT ''"),
      silent = TRUE)
  }

  # 老库升上来：V13.8 之前 is_admin = 1 的那些账号**一律**是平台管理员 ——
  # 那时候没有"项目管理员"这个概念，他们当时能做的事就是全平台的事。
  # 降级成 project 等于悄悄削掉现有管理员的权限，而他们自己不会知道。
  #
  # 这条 UPDATE 幂等，每次 dsapp_db() 都会跑一遍；`admin_scope = ''` 这个
  # 条件保证它不会把明确设成 'project' 的人又提回平台。
  try(DBI::dbExecute(con,
    "UPDATE users SET admin_scope = 'platform'
      WHERE is_admin = 1 AND (admin_scope IS NULL OR admin_scope = '')"),
    silent = TRUE)

  # ---- 每账号的硬件资源配额（V6 追加，item 4）------------------------------
  #
  # 三列都沿用"NULL = 用平台默认值"的约定（和 quota_gb 的 0 = 不限 不同，
  # 因为这三项**平台本来就有默认值**，见 config.R 的 exec 段）。
  # 管理员在管理页给某个账号单独收紧或放宽，NULL 表示"跟着平台走"。
  #
  #   cpu_sec   单任务的 CPU 时间上限（秒）
  #   mem_mb    单任务的内存上限（MB）—— 注意这是**地址空间**上限，
  #             不是 RSS，和 ulimit -v 同义
  #   max_procs 单任务的进程/线程数上限
  #
  # 为什么是每账号而不是每对话：这是管理员控制"谁能吃多少机器"的手段，
  # 而账号是管理动作的单位。对话级的隔离已经由工作区 + 对话环境保证了。
  for (col in c("cpu_sec", "mem_mb", "max_procs")) {
    if (!col %in% ucols) {
      try(DBI::dbExecute(con, sprintf("ALTER TABLE users ADD COLUMN %s REAL", col)),
          silent = TRUE)
    }
  }

  # ---- 每账号的 GPU 开关（V14 追加，item 7）--------------------------------
  #
  # 用户原话：「在「配额与资源」上限中加一个设置用户是否能够使用 GPU 资源的
  # 开关按钮」。
  #
  # 三态，和上面那三列同一个约定：
  #   NULL = **没设过**，跟着平台默认走（config.R 的 exec$gpu，默认 FALSE）
  #   0    = 管理员**明确关掉**（这个人不许用卡）
  #   1    = 管理员**明确打开**
  #
  # ⚠️⚠️ 它**不能**并进上面那个 for 循环、也不能并进 dsapp_user_limits()。
  #    那两个函数里的 `num()` / `norm()` 把 0 和负数一律当成"恢复默认"
  #    （那是给 cpu_sec 那种"0 秒没有意义"的量写的）。gpu_enabled 的 0 是
  #    **一个有意义的值**（不许用），塞进去会被吃掉 —— 表现是管理员关掉之后
  #    刷新一下又变成开着的，而且库里那一行看起来完全正常（存的是 NULL）。
  #    所以读写各走一个专用函数，见下面的 dsapp_user_gpu_enabled /
  #    dsapp_user_set_gpu。
  #
  # ⚠️ 用 INTEGER 而不是 REAL（上面那三列是 REAL，别照抄）：这是个布尔量，
  #    整数列读回来不会是 0.9999999，比较起来不用容差。
  if (!"gpu_enabled" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN gpu_enabled INTEGER"),
        silent = TRUE)
  }

  # 会话归属。NULL = V5 之前留下的无主对话（见 dsapp_user_claim_orphans）。
  scols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(sessions)")$name,
                    error = function(e) character(0))
  if (!"user_id" %in% scols) {
    try(DBI::dbExecute(con, "ALTER TABLE sessions ADD COLUMN user_id INTEGER"),
        silent = TRUE)
  }

  # 登录失败计数（V5 追加）。
  #
  # 为什么需要它：这个应用的账号模型有意做得很轻（密码选填、没有邮件通道），
  # 唯一的门锁就是密码 —— 而一个**没有节流**的密码表单，等于把门锁送给
  # 一个能跑脚本的人。库里存的是 sha256 迭代散列（见 dsapp_pw_hash），
  # 离线撞库成本已经不低；但线上直接猜不用付那个成本，试到对为止。
  #
  # 按**归一化邮箱**做主键：锁的是"这个账号"，不是"这个 IP"。按 IP 锁在
  # 这个部署形态下没有意义（全校一个出口 IP，锁一个人等于锁所有人）。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS login_fail (
      email        TEXT PRIMARY KEY,
      n_fail       INTEGER NOT NULL DEFAULT 0,
      first_at     TEXT NOT NULL,
      last_at      TEXT NOT NULL,
      locked_until TEXT
    )")

  invisible(TRUE)
}

# ---- 每账号的活跃情况（V13.8 item 2 的后台页）-------------------------------

#' 一个账号最近有多活跃
#'
#' 后台页那张「用户活跃情况」表的取数处。回答的是管理员真会问的那几个问题：
#' **他最近来过没有、来了干了多少、是不是注册完就再没动过**。
#'
#' ⚠️ 全部是**计数和时间**，没有一条内容（对话正文、任务输出、文件内容）。
#'    这不是顺手为之 —— 见 R/mod_admin.R 文件头那条：生信数据常常是未发表的，
#'    "谁在用、用得怎么样"和"他在分析什么"是两件事，后台页只回答前者。
#'
#' ⚠️ 「最近 N 天」这个窗口只作用于**从 audit_log 数出来的那几列**
#'    （n_act / n_login / last_act）。累计的对话数、任务数、token 数是
#'    **全时段**的：管理员把窗口从 30 天调到 7 天时，想看的是"这几天谁在动"，
#'    而"这个人一共跑了多少任务"跟着缩水会让他以为数据丢了。
#'
#' @param days 活跃窗口（天）。`NULL` / `NA` / `<= 0` 都当成 30。
#' @return data.frame；出错了返回 NULL。
#'   id, nickname, email, is_admin, admin_scope, status, created_at,
#'   last_seen_at, n_chat, n_task, n_msg, tokens, n_act, n_login, last_act
dsapp_user_activity <- function(days = 30, con = dsapp_db()) {
  d <- suppressWarnings(as.integer(days %||% 30))
  if (length(d) != 1L || is.na(d) || d <= 0) d <- 30L
  d <- min(d, 3650L)
  # audit_log.at 存的是 UTC 字符串（dsapp_now），所以这个下界也要用
  # **UTC** 算 —— 用本地时间算出来的边界在时区非 UTC 的机器上会整体偏移
  # 几小时，表现为"今天早上的登录没算进去"。
  since <- format(Sys.time() - d * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")

  tryCatch(
    DBI::dbGetQuery(con, "
      SELECT u.id, u.nickname, u.email, u.is_admin, u.admin_scope, u.status,
             u.created_at, u.last_seen_at,
             (SELECT COUNT(*) FROM sessions s WHERE s.user_id = u.id) AS n_chat,
             (SELECT COUNT(*) FROM tasks t
                JOIN sessions s2 ON s2.id = t.session_id
               WHERE s2.user_id = u.id) AS n_task,
             (SELECT COUNT(*) FROM messages m
                JOIN sessions s3 ON s3.id = m.session_id
               WHERE s3.user_id = u.id) AS n_msg,
             (SELECT COALESCE(SUM(COALESCE(x.total_tokens, 0)), 0)
                FROM usage_log x WHERE x.user_id = u.id) AS tokens,
             (SELECT COUNT(*) FROM audit_log a
               WHERE a.user_id = u.id AND a.at >= ?) AS n_act,
             (SELECT COUNT(*) FROM audit_log a2
               WHERE a2.user_id = u.id AND a2.action = 'login'
                 AND a2.at >= ?) AS n_login,
             (SELECT MAX(a3.at) FROM audit_log a3
               WHERE a3.user_id = u.id) AS last_act
        FROM users u ORDER BY u.id", params = list(since, since)),
    error = function(e) NULL)
}

# ---- 登录节流 --------------------------------------------------------------

#' 节流参数
#'
#' 默认：同一个邮箱连续错 8 次，锁 15 分钟；计数窗口也是 15 分钟 ——
#' "连续"指的是在窗口内，隔了三天再错一次不该接着上次的数往上加。
#'
#' 8 这个数不是安全参数，是**给人留的余地**：真人打错密码两三次很常见
#' （大写锁定、输入法、记混了旧密码），第 3 次就锁会变成骚扰；
#' 而脚本猜 8 次和猜 3 次没有区别 —— 它要的是几万次。
dsapp_login_cfg <- function() {
  as_num <- function(key, default) {
    v <- suppressWarnings(as.numeric(Sys.getenv(key, "")))
    if (is.na(v) || v <= 0) default else v
  }
  list(max_fail   = as_num("DSAPP_LOGIN_MAX_FAIL", 8),
       lock_sec   = as_num("DSAPP_LOGIN_LOCK_SEC", 900),
       window_sec = as_num("DSAPP_LOGIN_WINDOW_SEC", 900))
}

dsapp_secs_since <- function(t, now = dsapp_now()) {
  if (is.null(t) || is.na(t) || !nzchar(t)) return(Inf)
  suppressWarnings(as.numeric(difftime(as.POSIXct(now, tz = "UTC"),
                                       as.POSIXct(t, tz = "UTC"),
                                       units = "secs")))
}

#' 距离某个时刻还有多少秒
#'
#' ⚠️ 和 dsapp_secs_since 是两个方向，**不能互相代替**。locked_until 是
#'    **将来**的时刻，"距现在多少秒"算出来是负数（-900），拿 lock_sec 去减
#'    它得到的是 1800 —— 一个比锁定时间还长的剩余时间，页面上会写
#'    "还有 30 分钟"，而配置明明是 15 分钟。这个 bug 自检抓到过一次
#'    （剩下多少时间这条断言），别再合并这两个函数。
dsapp_secs_until <- function(t, now = dsapp_now()) {
  if (is.null(t) || is.na(t) || !nzchar(t)) return(-Inf)
  suppressWarnings(as.numeric(difftime(as.POSIXct(t, tz = "UTC"),
                                       as.POSIXct(now, tz = "UTC"),
                                       units = "secs")))
}

dsapp_login_row <- function(email, con = dsapp_db()) {
  email <- dsapp_user_norm_email(email)
  if (!nzchar(email)) return(NULL)
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT * FROM login_fail WHERE email = ?", params = list(email)),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  as.list(d[1, , drop = FALSE])
}

#' 现在是否处于锁定期
#'
#' @return list(locked, secs) —— secs 是剩余秒数（向上取整到分钟给界面用）
dsapp_login_locked <- function(email, con = dsapp_db()) {
  r <- dsapp_login_row(email, con)
  if (is.null(r)) return(list(locked = FALSE, secs = 0))
  left <- dsapp_secs_until(r$locked_until)
  if (is.na(left) || left <= 0) return(list(locked = FALSE, secs = 0))
  list(locked = TRUE, secs = left)
}

#' 记一次失败
#'
#' @return list(n, left, locked, secs)：n 是窗口内的累计失败次数，
#'   left 是还能再试几次，locked 表示这次是否**刚刚**触发锁定。
dsapp_login_fail <- function(email, con = dsapp_db()) {
  email <- dsapp_user_norm_email(email)
  c0 <- dsapp_login_cfg()
  now <- dsapp_now()
  if (!nzchar(email)) return(list(n = 0, left = c0$max_fail, locked = FALSE, secs = 0))

  r <- dsapp_login_row(email, con)
  # 窗口外重新计数。不重置的话，一个账号三个月里被不同的人各打错几次，
  # 累计到 8 就锁 —— 而它其实从没被攻击过。
  n <- if (is.null(r) || is.na(r$last_at) ||
           dsapp_secs_since(r$last_at, now) > c0$window_sec) 0L
       else as.integer(r$n_fail %||% 0L)
  n <- n + 1L

  just_locked <- n >= c0$max_fail
  until <- if (just_locked)
    format(as.POSIXct(now, tz = "UTC") + c0$lock_sec, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  else if (!is.null(r) && !is.na(r$locked_until)) r$locked_until else NA_character_

  try(DBI::dbExecute(con,
    "INSERT INTO login_fail (email, n_fail, first_at, last_at, locked_until)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(email) DO UPDATE SET
       n_fail = excluded.n_fail, last_at = excluded.last_at,
       locked_until = excluded.locked_until",
    params = list(email, n,
                  if (is.null(r)) now else r$first_at, now, until)),
    silent = TRUE)

  list(n = n, left = max(0L, as.integer(c0$max_fail) - n),
       locked = just_locked,
       secs = if (just_locked) c0$lock_sec else 0)
}

#' 登录成功后清掉计数
#'
#' 不清的话，一个记性不好的用户每次都要在"还剩 3 次"的提示下登录 ——
#' 而他每次都成功。计数该在他证明自己是谁的那一刻归零。
dsapp_login_reset <- function(email, con = dsapp_db()) {
  email <- dsapp_user_norm_email(email)
  if (!nzchar(email)) return(invisible(FALSE))
  try(DBI::dbExecute(con, "DELETE FROM login_fail WHERE email = ?",
                     params = list(email)), silent = TRUE)
  invisible(TRUE)
}

#' 把一次失败翻译成给用户看的那句话
#'
#' 单独抽出来是因为**三处**（密码登录、恢复码登录）要说同一句话，
#' 分开写早晚会有一处忘了带上"还能试几次"。
dsapp_login_fail_msg <- function(base, f) {
  if (isTRUE(f$locked)) {
    return(sprintf("%s。连续错 %d 次，这个账号已被锁定 %d 分钟。",
                   base, f$n, ceiling(f$secs / 60)))
  }
  if (!is.null(f$left) && f$left > 0) {
    return(sprintf("%s（还可以试 %d 次）", base, f$left))
  }
  base
}

#' 当前被锁的账号（管理页用）
dsapp_login_locks <- function(con = dsapp_db()) {
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT email, n_fail, last_at, locked_until FROM login_fail
     WHERE locked_until IS NOT NULL ORDER BY last_at DESC"),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  d$secs <- vapply(d$locked_until, dsapp_secs_until, numeric(1))
  d[!is.na(d$secs) & d$secs > 0, , drop = FALSE]
}

#' 解除锁定
#'
#' @param email NULL 表示全部解锁（管理页的「全部解锁」）
dsapp_login_unlock <- function(email = NULL, con = dsapp_db()) {
  if (is.null(email)) {
    n <- tryCatch(DBI::dbExecute(con, "DELETE FROM login_fail"),
                  error = function(e) 0L)
  } else {
    n <- tryCatch(DBI::dbExecute(con, "DELETE FROM login_fail WHERE email = ?",
                                 params = list(dsapp_user_norm_email(email))),
                  error = function(e) 0L)
  }
  as.integer(n %||% 0L)
}

# ---- 基础工具 --------------------------------------------------------------

#' 归一化邮箱
#'
#' 存库和比对都用它。不做归一化的话 "A@x.com" 和 "a@x.com" 会注册成两个
#' 账号，而用户认为自己只有一个 —— 之后他会发现"我的对话时有时无"。
dsapp_user_norm_email <- function(x) {
  x <- trimws(tolower(as.character(x %||% "")))
  gsub("\\s+", "", x)
}

#' 随机令牌（恢复码 / cookie 值）
#'
#' 用 /dev/urandom 而不是 sample()：sample() 走 R 的 RNG，种子可预测，
#' 而这个值是**唯一**的身份凭证（没密码时凭它认领账号）。
dsapp_token <- function(n = 24) {
  # suppressWarnings：/dev/urandom 不是普通文件，readBin 每次都会念一句
  # "'raw = FALSE' but '/dev/urandom' is not a regular file"。读出来的东西
  # 完全正确，只是 R 的 file() 在按文件名打开时习惯性检查了一下。这条警告
  # 会混进 Shiny 的日志里，每次注册都刷一行，把真问题淹掉。
  bytes <- tryCatch(suppressWarnings(readBin("/dev/urandom", "raw", n = n)),
                    error = function(e) NULL)
  if (is.null(bytes) || length(bytes) < n) {
    # 没有 /dev/urandom（非 Linux）时退回 RNG。弱，但总比没有强，
    # 而且这种环境本来也不是这个应用的部署形态。
    return(paste0(sample(c(letters, LETTERS, 0:9), n * 2, replace = TRUE),
                  collapse = ""))
  }
  paste0(sprintf("%02x", as.integer(bytes)), collapse = "")
}

#' 口令散列
#'
#' ⚠️ 这是 sha256 迭代，不是 scrypt/bcrypt —— R 这边没有现成可用的实现，
#'    而为一个"可选的、非敏感的"口令引入新依赖不值得（deploy.sh 的依赖
#'    清单是硬校验，多一个包就多一次部署失败的机会）。
#'    迭代 1000 次把单次猜测的成本抬起来，挡住的是"拿库里的散列去撞常见
#'    口令"这类离线攻击。**别往这个账号里放任何真正敏感的东西。**
#' 密码最短长度
#'
#' 注册和「改密码」共用同一个数：两处各写一个字面量的话，迟早一边改成 8
#' 另一边还是 6，而用户会在"注册时允许、改密码时被拒"之间撞上一堵没道理的墙。
DSAPP_PW_MIN <- 6L

dsapp_pw_hash <- function(password, salt) {
  h <- paste0(salt, ":", password)
  for (i in seq_len(1000)) {
    h <- digest::digest(paste0(h, salt), algo = "sha256", serialize = FALSE)
  }
  h
}

#' 校验注册信息
#'
#' @return 归一化后的 list(nickname, email, phone, field, password) 或
#'   list(error = "给用户看的那句话")
dsapp_user_validate <- function(nickname, email, phone, field, password = "",
                                password2 = NULL) {
  nickname <- trimws(as.character(nickname %||% ""))
  field    <- trimws(as.character(field %||% ""))
  phone    <- gsub("[^0-9+]", "", as.character(phone %||% ""))
  email    <- dsapp_user_norm_email(email)
  password <- as.character(password %||% "")

  if (!nzchar(nickname)) return(list(error = "请填昵称"))
  if (nchar(nickname) > 40) return(list(error = "昵称太长了（40 字以内）"))
  if (!nzchar(email)) return(list(error = "请填邮箱"))
  # 故意宽松：只挡明显不是邮箱的输入。真要严格校验只有发信一途，
  # 而这个应用没有邮件通道 —— 与其用一条正则把合法邮箱挡在外面，
  # 不如挡掉手滑。
  if (!grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email)) {
    return(list(error = "邮箱格式看起来不对（应形如 name@example.com）"))
  }
  if (!nzchar(phone)) return(list(error = "请填手机号"))
  if (nchar(phone) < 5 || nchar(phone) > 20) {
    return(list(error = "手机号格式看起来不对"))
  }
  if (!nzchar(field)) return(list(error = "请填研究方向（一句话即可）"))
  if (nchar(field) > 100) return(list(error = "研究方向太长了（100 字以内）"))

  # ★ V13.1 item 7：密码从"可选"变成**必填**。
  #   原来留空是允许的，留空的账号就落进"填对邮箱就能进"那条路；那条路
  #   已经从 dsapp_user_auth 里删掉了（见那里的说明）。所以这里必须挡住 ——
  #   否则用户能在注册页造出一个**永远登不进来**的账号。
  if (!nzchar(password)) {
    return(list(error = sprintf("请设一个密码（至少 %d 位）", DSAPP_PW_MIN)))
  }
  if (nchar(password) < DSAPP_PW_MIN) {
    return(list(error = sprintf("密码至少 %d 位", DSAPP_PW_MIN)))
  }
  if (!is.null(password2) && !identical(password, as.character(password2))) {
    return(list(error = "两次输入的密码不一致"))
  }

  list(nickname = nickname, email = email, phone = phone, field = field,
       password = password)
}

# ---- 查 --------------------------------------------------------------------

#' 管理员邮箱名单
#'
#' 来自 .Renviron 的 DSAPP_ADMIN_EMAIL（逗号分隔）。**留空也能用**：
#' 第一个注册的账号自动成为管理员（见 dsapp_user_create）——
#' 不然全新部署会陷入"没有管理员可以任命管理员"的死结。
dsapp_admin_emails <- function() {
  raw <- Sys.getenv("DSAPP_ADMIN_EMAIL", "")
  if (!nzchar(raw)) return(character(0))
  dsapp_user_norm_email(strsplit(raw, ",", fixed = TRUE)[[1]])
}

dsapp_user_row <- function(where, params, con = dsapp_db()) {
  # ⚠️ 空 params 必须换成 NULL。DBI 对"SQL 里没有 ? 却传了 params"是**抛错**的
  #    （"Query does not require parameters."），而下面那个 tryCatch 会把错误
  #    变成 NULL —— 于是调用方看到的是"查无此人"，而不是"查询写错了"。
  #    2026-09-13 踩到：dsapp_default_user 传了 list()，结果库里明明有账号，
  #    却一路走"没有可用账号"的分支，静默回落到登录页。
  if (!length(params)) params <- NULL
  d <- tryCatch(DBI::dbGetQuery(con,
    paste0("SELECT * FROM users WHERE ", where, " LIMIT 1"), params = params),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  as.list(d[1, , drop = FALSE])
}

#' 凭令牌找人（**只验令牌本身**，不管单端登录）
#'
#' ⚠️ 和 dsapp_user_by_token 的区别就一句话：这个**不看**这一端是不是当前
#'    那一端。它只该用在两处：
#'      · 内部已经确认过归属之后的二次查询；
#'      · "令牌对，但这个端已经被顶下线了"那条提示 —— 要区分这两种情况就得
#'        先有一个只看令牌的入口（见 R/mod_welcome.R 的自动登录那一段）。
#'    **别拿它当登录入口**：绕开 dsapp_user_by_token 就是绕开单端登录。
dsapp_user_by_token_raw <- function(token, con = dsapp_db()) {
  token <- as.character(token %||% "")
  if (!nzchar(token)) return(NULL)
  # 从**最后一个**点切（见 R/logins.R 的 dsapp_login_split）：老 cookie 里
  # 没有点，那时整串就是令牌。
  dsapp_user_row("token = ?", list(dsapp_login_split(token)$token), con)
}

#' 凭令牌找人（**令牌 + 单端登录**，V11 item 4b）
#'
#' cookie 里的值形如 `<users.token>.<nonce>`（见 R/logins.R 顶部那段说明）。
#' 两段都要对：令牌证明"你是这个账号"，nonce 证明"你现在是当前那一端"。
#'
#' @return users 表的一行；令牌无效、账号停用、或者这一端已经被别处顶下线
#'   时返回 NULL。**三种情况都返回 NULL 是刻意的** —— 调用方（自动登录）
#'   对它们的处理完全一样：清 cookie、回登录页。
dsapp_user_by_token <- function(token, con = dsapp_db()) {
  u <- dsapp_user_by_token_raw(token, con)
  if (is.null(u)) return(NULL)
  nonce <- dsapp_login_split(token)$nonce
  # ⚠️ nonce 为空 = 这串值里没有"这一端"的信息（V11 之前发出去的 cookie、
  #    或者 URL 里的裸令牌）。**判否**，不放行：
  #      放行的话，手写一个不带点的 cookie 就能绕开单端限制；
  #      而认领是**登录**才做的事（见 app.R 的 on_login），不是自动登录。
  #    升级的代价因此是"所有端重新登录一次"，而不是"限制形同虚设"。
  if (!nzchar(nonce) || !dsapp_login_owns(u$id, nonce, con = con)) return(NULL)
  u
}

dsapp_user_by_email <- function(email, con = dsapp_db()) {
  email <- dsapp_user_norm_email(email)
  if (!nzchar(email)) return(NULL)
  dsapp_user_row("email = ?", list(email), con)
}

dsapp_user_by_id <- function(id, con = dsapp_db()) {
  if (is.null(id) || length(id) == 0 || is.na(id)) return(NULL)
  dsapp_user_row("id = ?", list(as.integer(id)), con)
}

dsapp_user_is_admin <- function(user) {
  if (is.null(user)) return(FALSE)
  isTRUE(as.integer(user$is_admin %||% 0L) == 1L)
}

# ---- 管理员分级（V13.8，item 1）--------------------------------------------
#
# 三个函数的分工，容易混，写在这里：
#
#   dsapp_user_is_admin()          进不进得去管理页 —— 两种管理员都是 TRUE
#   dsapp_user_is_platform_admin() 能不能动**全平台**的东西
#   dsapp_user_is_project_admin()  只有自己那一片
#
# ⚠️ 判"能不能动全平台"的地方**一律**用 platform 那个，不要用 is_admin。
#    后者对项目管理员也是 TRUE，拿它当全局通行证，项目管理员就看到了所有人
#    的账号和所有对话 —— 正是这一版要修掉的那件事。

#' 这个账号的管理员级别
#'
#' @return `""` / `"project"` / `"platform"`；认不出来的一律当 `""`（普通用户）。
#'
#' ⚠️ `admin_scope` 空但 `is_admin = 1` 时返回 `"platform"`，这是**刻意的**
#'    兜底，不是漏洞：那种组合只可能出现在"刚建好的管理员还没等到下一次
#'    建表回填"这个窗口中（见 dsapp_db_schema_users 里那条 UPDATE）。
#'    兜底成 platform 和回填的结果一致，所以两条路读出来永远一样；
#'    要是兜底成 ""，那一瞬间这个管理员在界面上会变成"什么都动不了"。
dsapp_user_admin_scope <- function(user) {
  if (is.null(user)) return("")
  s <- tryCatch(as.character(user$admin_scope %||% "")[1], error = function(e) "")
  if (length(s) != 1L || is.na(s) || !nzchar(s)) {
    # 老行 / 刚建的行：is_admin 说了算。
    return(if (dsapp_user_is_admin(user)) "platform" else "")
  }
  if (s %in% c("project", "platform")) s else ""
}

dsapp_user_is_platform_admin <- function(user) {
  identical(dsapp_user_admin_scope(user), "platform")
}

dsapp_user_is_project_admin <- function(user) {
  identical(dsapp_user_admin_scope(user), "project")
}

#' 管理员级别 → 界面上那个词
#'
#' 单独一个函数而不是在界面里写 if/else：这个词会出现在用户表的角色列、
#' 后台页的权限下拉、以及日志的详情里，三处各写一遍迟早不一致
#' （理由同 DSAPP_AUDIT_LABELS）。
dsapp_admin_scope_label <- function(scope) {
  switch(as.character(scope %||% "")[1],
         platform = "平台管理员",
         project  = "项目管理员",
         "普通用户")
}

#' 改一个账号的管理员级别（**唯一**的写入口）
#'
#' @param scope `""` / `"project"` / `"platform"`
#' @return list(ok, msg)
#'
#' ⚠️ 两道自锁，别去掉：
#'   1. **不能改自己**。平台管理员把自己降成普通用户之后，这一页立刻
#'      进不去了，而唯一能改回来的人也得先进得去 —— 平台会被锁死在一个
#'      谁也改不了权限的状态里。要降自己的话，让另一个平台管理员来点。
#'   2. **不能把最后一个平台管理员降级**。同上，只是绕了一层：两个管理员
#'      互相把对方降掉，结果一样。
dsapp_user_set_admin <- function(id, scope, con = dsapp_db(), by = NULL) {
  if (is.null(id) || length(id) == 0 || is.na(id)) {
    return(list(ok = FALSE, msg = "缺少账号"))
  }
  id <- as.integer(id)
  scope <- as.character(scope %||% "")[1]
  if (is.na(scope) || !scope %in% c("", "project", "platform")) {
    return(list(ok = FALSE, msg = "不认识的级别"))
  }
  cur <- tryCatch(dsapp_user_by_id(id, con = con), error = function(e) NULL)
  if (is.null(cur)) return(list(ok = FALSE, msg = "这个账号已经不在了"))

  old <- dsapp_user_admin_scope(cur)
  if (identical(old, scope)) {
    return(list(ok = TRUE, msg = sprintf("他本来就是%s，没改。",
                                         dsapp_admin_scope_label(scope))))
  }
  if (!is.null(by) && !is.na(by) && identical(as.integer(by), id)) {
    return(list(ok = FALSE, msg = "不能改自己的级别 —— 改完就没人能改回来了。"))
  }
  # 从平台管理员降下去（或者直接清成普通用户）时，得留一个。
  if (identical(old, "platform") && !identical(scope, "platform")) {
    n <- tryCatch(
      DBI::dbGetQuery(con, paste0(
        "SELECT COUNT(*) AS n FROM users WHERE is_admin = 1 AND id <> ",
        id, " AND (admin_scope = 'platform' OR admin_scope IS NULL",
        " OR admin_scope = '')"))$n[[1]],
      error = function(e) 0L)
    if (!isTRUE(as.integer(n) >= 1L)) {
      return(list(ok = FALSE, msg = "这是最后一个平台管理员了，不能降 —— 降完谁都进不来这一页。"))
    }
  }

  # ⚠️ 两列一起写，一条 UPDATE。分两条写的话，中间那一瞬间 is_admin 和
  #    admin_scope 会对不上，而 dsapp_db_schema_users 的回填正好在这时跑的话
  #    会把一个刚降级的人又提回 platform。
  DBI::dbExecute(con,
    "UPDATE users SET is_admin = ?, admin_scope = ? WHERE id = ?",
    params = list(as.integer(scope %in% c("project", "platform")),
                  scope, id))
  list(ok = TRUE,
       msg = sprintf("%s → %s", dsapp_admin_scope_label(old),
                     dsapp_admin_scope_label(scope)))
}

dsapp_user_active <- function(user) {
  !is.null(user) && identical(as.character(user$status %||% "active"), "active")
}

# ---- 按账号记住的模型设置（V6，item 1）-------------------------------------

#' 读回某个账号保存的模型设置
#'
#' 返回**一定是完整的 list**，四个键都在（缺的给 NULL / ""）。调用方拿到
#' 就能直接喂给 input 的 value=，不用每处再判一次 NULL。
#'
#' ⚠️ user_id 为 NULL / NA 时返回空设置，**不查库**。这不是优化：自动进入
#'    模式（auth_mode=auto）下，登录闸门还没把 user_id 写进 state 时，
#'    模块的 UI 就已经渲染了一次，那时候查 `WHERE id = NULL` 会得到
#'    0 行 —— 看着也没事，但会白白多一次库往返，而且让"没登录"和
#'    "登录了但没存过设置"两种状态在日志里长得一样。
dsapp_settings_get <- function(user_id, con = dsapp_db()) {
  empty <- list(vendor = NULL, model = NULL, base_url = NULL,
                api_key = NULL, saved = FALSE)
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(empty)

  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT llm_vendor, llm_model, llm_base_url, llm_api_key
         FROM users WHERE id = ?", params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(empty)

  nn <- function(x) {
    if (is.null(x) || length(x) == 0 || is.na(x)) NULL else as.character(x)
  }
  v <- nn(row$llm_vendor[[1]])
  m <- nn(row$llm_model[[1]])
  b <- nn(row$llm_base_url[[1]])
  # ★ V13.1 item 9：这一列在库里是密文，读出来要解密。老明文（升级时迁移
  #   还没跑到）dsapp_sec_dec 会原样返回，不会把用户锁在门外。
  k <- dsapp_sec_dec(nn(row$llm_api_key[[1]]))
  list(vendor = v, model = m, base_url = b, api_key = k,
       saved = !is.null(k) && nzchar(k))
}

#' 保存模型设置到账号名下
#'
#' `api_key` 为 `NULL` **或空串**都表示"不要动已经存着的那把 Key" —— 这个
#' 区分是必要的：用户在设置页把 Key 输入框清空、只是想改个模型名，不该顺手
#' 把 Key 删了。真的要删，只有一条路：`dsapp_settings_forget_key()`。
#'
#' ⚠️ 空串为什么也算"不动"（而不是"清空"）：左栏的保存是**防抖**触发的，
#'    粘贴 Key 的过程中会带着越来越长的前缀触发好几轮。哪一轮真被写进去，
#'    用户都会得到一个界面说"已记住"、实际是错的 Key —— 而他下次登录时
#'    看见的是"认证失败"，查不到这里来。清空是**明确意图**，就该走明确的
#'    那个函数，不该和"这个框现在恰好是空的"共用一个值。
dsapp_settings_save <- function(user_id, vendor = NULL, model = NULL,
                                base_url = NULL, api_key = NULL,
                                con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }

  sets <- character(0); vals <- list()
  add <- function(col, val) {
    sets <<- c(sets, sprintf("%s = ?", col))
    vals <<- c(vals, list(if (is.null(val)) NA_character_ else as.character(val)))
  }
  # ★★ V13.6 item 1：`vendor` 传**空串**时当作"不动"，和 api_key 同一条规矩。
  #
  #   `llm_vendor` 是被 `user_api_keys` 那条不变量用来定位"当前这把 Key 是谁家的"
  #   的（见下面那段）。把它写成空串，等于把账号的厂商标成"没有厂商"，而界面
  #   上只是下拉框空一格 —— 看不出发生过什么。
  #
  #   谁会传空串进来：左栏那个防抖保存（mod_model.R）。它的输入是
  #   `input$vendor`，而在**页面刚建立起会话、控件还没把值报上来**的那一小段
  #   时间里，`input$vendor` 是 NULL —— 照直写下去就是三个空串，把用户存过的
  #   厂商/模型/地址一起抹掉。2026-09-17 复现过：退出登录再登回来，库里的
  #   vendor/model/base_url 全变空串、llm_api_key 变 NULL（界面上的表现是
  #   「Key 又被清空了」）。同一次触发还会把用户手填的中转地址永久抹掉 ——
  #   因为页面是在库已经被抹掉之后才渲染的，输入框里带出来的是空串。
  #
  #   厂商下拉永远有一个选中项，"厂商 = 空"从来不是用户的意图，所以这条
  #   不丢任何东西。真正要清空只有一条路：dsapp_settings_forget_key()。
  if (!is.null(vendor) && nzchar(trimws(as.character(vendor)[1] %||% ""))) {
    add("llm_vendor", vendor)
  }
  if (!is.null(model))    add("llm_model", model)
  if (!is.null(base_url)) add("llm_base_url", base_url)
  # 空串不进 SET 子句 —— 见上面那段。注意判断要在 add() **之前**做。
  if (!is.null(api_key) && nzchar(as.character(api_key)[1] %||% "")) {
    # ★ V13.1 item 9：加密入库（见 R/crypto.R）。
    add("llm_api_key", dsapp_sec_enc(api_key))
  }
  if (!length(sets)) return(invisible(FALSE))

  vals <- c(vals, list(as.integer(user_id)))
  ok <- tryCatch({
    DBI::dbExecute(con,
      sprintf("UPDATE users SET %s WHERE id = ?", paste(sets, collapse = ", ")),
      params = vals)
    TRUE
  }, error = function(e) FALSE)
  invisible(ok)
}

# ---- 分厂商的 API Key 钥匙串（V13.1 item 5）--------------------------------
#
# 建表在 R/db.R 的 dsapp_db_schema_keys()。这里只放读写。
#
# ⚠️ 不变量（整个设置页都靠它成立，改这里之前先读一遍）：
#
#      users.llm_api_key  ==  user_api_keys[users.id, users.llm_vendor]
#
#   也就是"那一列永远是**当前选中厂商**那把 Key 的镜像"。留着这一列是因为
#   读它的地方太多了（llm.R 取 cfg$api_key、mod_settings 的闸门、管理页），
#   全部改成查表是一次没有收益的大改。加一条不变量比改二十个调用点便宜。
#
#   写的时候必须**一起**写：只写列不写表，切走再切回来 Key 就没了；只写表
#   不写列，下一次发消息用的还是上一家的 Key。dsapp_api_key_activate() 就是
#   干这件事的，凡是想让某个厂商"生效"的地方都走它。

#' 记住某个厂商的 Key（连同它的地址和模型）
#'
#' `api_key` 为空串时**不动**已存的那把 —— 和 dsapp_settings_save() 同一条
#' 规矩，理由也一样（防抖保存会带着半截 Key 触发好几轮；清空是明确意图，
#' 走 dsapp_api_key_forget()）。
#'
#' `vendor` 为空时直接返回 FALSE，不猜。猜错的代价是把 A 的 Key 写到 B 名下。
dsapp_api_key_put <- function(user_id, vendor, api_key,
                              base_url = NULL, model = NULL,
                              con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return(invisible(FALSE))

  k <- as.character(api_key %||% "")[1] %||% ""
  if (!nzchar(trimws(k))) return(invisible(FALSE))

  nb <- function(x) {
    if (is.null(x)) return(NA_character_)
    s <- as.character(x)[1]
    if (is.na(s) || !nzchar(trimws(s))) NA_character_ else s
  }

  # ★ V13.1 item 9：**入库前加密**。这是 Key 进数据库的唯一一道门，
  #   所以加密放在这里、而不是散在调用方 —— 少写一处就是一个明文 Key
  #   躺在库里，而且没有任何迹象。
  k <- dsapp_sec_enc(k)

  invisible(tryCatch({
    DBI::dbExecute(con, "
      INSERT INTO user_api_keys (user_id, vendor, api_key, base_url, model,
                                 updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id, vendor) DO UPDATE SET
        api_key    = excluded.api_key,
        -- 地址/模型传 NULL 时不覆盖：改 Key 的那条路径不该顺手清掉地址。
        base_url   = COALESCE(excluded.base_url, user_api_keys.base_url),
        model      = COALESCE(excluded.model,    user_api_keys.model),
        updated_at = excluded.updated_at",
      params = list(as.integer(user_id), v, k,
                    # ⚠️ 空串要当成 NULL（"这次没带这个信息"），不能当成
                    #    "把已经存的地址清掉"。界面上那两个输入框在控件重建
                    #    的瞬间会是空串，照直写进去就会把用户填的地址抹了。
                    nb(base_url), nb(model), dsapp_now()))
    TRUE
  }, error = function(e) FALSE))
}

#' 把"这一家现在用的模型"写回它**自己**那一行（Test_V15.8 item 3）
#'
#' 为什么需要单独一个函数：`user_api_keys.model` 是"按厂商记住上次用的模型"，
#' 而它**只在用户敲了 Key（或带着 Key 换厂商）时才写** —— 也就是说，用户改
#' 一次模型下拉，`users.llm_model` 变了、这份副本**没变**。于是它会陈旧。
#'
#' ★★ 陈旧本身不致命（V15.7 item 8 已经把主次定成"库为准"），致命的是它
#'    **在换厂商那一刻被当成权威**：R/mod_model.R 的 `observeEvent(input$vendor)`
#'    会把 `dsapp_api_key_recall()` 拿到的 model **直接推回下拉**。副本里要是
#'    一个别的名字，用户就会看到"我什么都没改，模型自己变了"，而下一拍防抖
#'    再把它写进 `users.llm_model` —— 从此出网请求带的就是那个名字。
#'
#'    生产库里**当场就有一个**（2026-10-02 读到）：uid=11（qwen 那个账号）
#'    `users.llm_model = 'qwen3.8-max'`，而 `user_api_keys.qwen.model =
#'    'deepseek-flash'` —— 连厂商都不是同一家。他会踩上的动作只是"切走再切回来"。
#'
#'    怎么被写成那样的：页面刚建立会话时，Key 输入框先被填上（触发
#'    `observeEvent(input$api_key)` 去写这把 Key），而那一刻模型下拉还没把值
#'    报上来 —— 归属取的是 `key_vendor()`（= 库里的厂商，已经是 qwen），模型
#'    取的却还是平台默认名。这条竞态和 V15.7 item 8 是同一个来路。
#'
#' ⚠️ 修在**写入侧**、并且只在这一个地方修：让"模型变了"这件事顺手把副本刷成
#'    同一个值，副本就再也不会漂。反过来去改换厂商那一处的读取逻辑（比如
#'    "副本里的名字不在清单里就不认"）会误伤中转站那种自定义模型名 ——
#'    那些名字本来就不在静态清单里。
#'
#' ⚠️ 空串/ NULL 一律**不写**（和 dsapp_settings_save / dsapp_api_key_put 同一
#'    条规矩）：控件重建那一瞬间报上来的是空，照直写下去就是把用户的记忆抹了。
#'
#' ⚠️ 只 UPDATE 已有的行，**不 INSERT**：钥匙串里那一行的 `api_key` 是主内容，
#'    凭空插一行没有 Key 的，会让 `dsapp_api_key_recall()` 从"这家没存过"
#'    变成"存过但是空的"，界面提示跟着变。
dsapp_api_key_sync_model <- function(user_id, vendor, model, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  m <- as.character(model %||% "")[1] %||% ""
  if (!nzchar(v) || !nzchar(trimws(m))) return(invisible(FALSE))

  invisible(tryCatch({
    n <- DBI::dbExecute(con,
      "UPDATE user_api_keys SET model = ?, updated_at = ?
        WHERE user_id = ? AND vendor = ?",
      params = list(m, dsapp_now(), as.integer(user_id), v))
    n > 0
  }, error = function(e) FALSE))
}

#' 取某个厂商记着的那一套
#'
#' 没有就返回 NULL（**不是**返回一个字段全是 NULL 的 list）—— 调用方靠
#' "是不是 NULL"区分"这家没存过"和"存过但是空的"，这两种情况的界面不一样。
dsapp_api_key_recall <- function(user_id, vendor, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(NULL)
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return(NULL)

  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT api_key, base_url, model FROM user_api_keys
        WHERE user_id = ? AND vendor = ?",
      params = list(as.integer(user_id), v)),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(NULL)

  nn <- function(x) if (is.null(x) || length(x) == 0 || is.na(x)) NULL else as.character(x)
  # ★ V13.1 item 9：**出库解密**。解不开（钥匙串丢了/换过）时 dsapp_sec_dec
  #   返回 NULL，这一家看起来就是"没存过 Key"，界面会让用户重填。
  #   这是有意的：把密文当 Key 发出去只会换来一个查不到原因的 401。
  list(api_key  = dsapp_sec_dec(nn(row$api_key[[1]])),
       base_url = nn(row$base_url[[1]]),
       model    = nn(row$model[[1]]))
}

#' 这一刻**真正该拿去发请求**的那把 Key（V13.7 item 3）
#'
#' 存在的理由：Key 在库里有**两个**落脚点，而它们会合法地不一致 ——
#'
#'   · `user_api_keys`（钥匙串，按厂商一张行）—— `dsapp_api_key_recall()` 读它；
#'   · `users.llm_api_key`（"当前生效"那一列）—— `dsapp_settings_get()` 读它。
#'
#' 两者不一致的常见来路：账号是从更早的版本升上来的（那时只有列、没有
#' 钥匙串）、`user_api_keys` 被外部的库操作动过、或者升级迁移还没跑到。
#' 这时候列里有 Key、钥匙串里没有这一家的行，`recall()` 返回 NULL —— 发消息
#' 的闸门只看 `recall()` 的话，用户会看到"库里明明有 Key，却让你去设置页填"。
#' V13.6 item 1 那个 pending 自愈就是被这件事咬出来的，这里把它堵在源头。
#'
#' 优先级：**钥匙串里这一家的** > `users.llm_api_key`。
#' 前者是用户为这个厂商明确认过的那把；后者是"当前生效"的副本，按厂商记
#' 之后它只是缓存。反过来（列优先）会在切厂商的那一瞬间拿上一家的 Key 去
#' 请求 —— 那正是 V13.1 item 5 修掉的 bug，不能倒回去。
#'
#' ⚠️ 列里那把只有在 `llm_vendor` **就是**这个厂商时才能用。不对着的话它是
#'    **别人家的 Key**，拿去请求只会换来一个不提厂商的 401。
#'
#' 返回 `""` 表示"这一刻没有可用的 Key"，调用方照常走"请先去设置页填"。
dsapp_api_key_effective <- function(user_id, vendor, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return("")
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return("")

  rec <- tryCatch(dsapp_api_key_recall(user_id, v, con = con),
                  error = function(e) NULL)
  k <- rec$api_key %||% ""
  if (nzchar(k)) return(k)

  s <- tryCatch(dsapp_settings_get(user_id, con = con),
                error = function(e) list())
  sv <- trimws(as.character(s$vendor %||% "")[1] %||% "")
  if (identical(sv, v)) return(s$api_key %||% "")
  ""
}

#' 让"当前生效"那一列自己长回来（Test_V15.4 item 1）
#'
#' 用户原话：「上次更新后，我的应用模型似乎被去激活了，我重新点击了更新后才
#' 重新应用，**不要因为版本更新让用户付出额外的操作**」。
#'
#' 症状落地的那一句话是「请先到设置页填 API Key」—— 而用户**明明填过**。原因是
#' 发消息的闸门读 `users.llm_api_key` 那一列，而钥匙串里那把才是原件；两者
#' 一旦不同步（列被更早的版本/某条路径抹成 NULL，钥匙串还完好），闸门就报
#' "没填"。用户唯一的出路是去设置页重新粘一遍 Key，也就是他说的"额外的操作"。
#'
#' 这里做的是**从原件补回副本**：钥匙串里这一家有、而且**解得开**，就把密文原样
#' 搬回列里（`dsapp_api_key_activate()` 干的就是这件事），并返回解出来的明文
#' 给调用方写进内存。
#'
#' ⚠️⚠️ 判据必须是"**解得开**"，不是"行存在"。换过 `data_root`、或者密文库
#'    被人动过的时候，行还在、密文解不开了 —— 那种情况补回去等于把一个永远
#'    解不开的串写进列，症状从"请先到设置页填 API Key"变成 401，而且更难查
#'    （列里看着是有 Key 的）。所以先 `recall()`（它解密），解得开才补。
#'
#' ⚠️ 只补"当前厂商"这一家：列的含义就是"当前生效厂商那把 Key 的镜像"，
#'    补别家等于把 B 家的 Key 放进了 A 家的位置。
#'
#' 返回这一刻**真正该拿去发请求**的那把明文 Key（补成功就是它，补不了就退回
#' `dsapp_api_key_effective()` 的答案）。返回 `""` = 确实没有，调用方照常提示。
dsapp_api_key_ensure <- function(user_id, vendor, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return("")
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return("")

  rec <- tryCatch(dsapp_api_key_recall(user_id, v, con = con),
                  error = function(e) NULL)
  key <- rec$api_key %||% ""
  if (nzchar(key)) {
    # 钥匙串里有**并且解得开** → 把列补齐（幂等：列本来就对的时候写的是同一串）。
    tryCatch(dsapp_api_key_activate(user_id, v, con = con),
             error = function(e) NULL)
    return(key)
  }
  # 钥匙串里没有这一家 —— 那就看列里有没有（老账号、或者只写过列的那种）。
  dsapp_api_key_effective(user_id, v, con = con)
}

#' 忘掉某个厂商的 Key（`vendor` 为 NULL 时忘掉**全部**厂商）
#'
#' 只删钥匙串里的行，**顺手不碰** users.llm_api_key —— 调用方多半紧接着就要
#' 让"当前厂商"重新生效（dsapp_api_key_activate），那一步会把列一起改对。
#' 这里自作主张清列的话，如果被清的正好不是当前厂商，列就和表对不上了。
dsapp_api_key_forget <- function(user_id, vendor = NULL, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  invisible(tryCatch({
    if (is.null(vendor)) {
      DBI::dbExecute(con, "DELETE FROM user_api_keys WHERE user_id = ?",
                     params = list(as.integer(user_id)))
    } else {
      v <- trimws(as.character(vendor)[1] %||% "")
      if (!nzchar(v)) return(invisible(FALSE))
      DBI::dbExecute(con,
        "DELETE FROM user_api_keys WHERE user_id = ? AND vendor = ?",
        params = list(as.integer(user_id), v))
    }
    TRUE
  }, error = function(e) FALSE))
}

#' 让某个厂商"生效"：把 users.llm_api_key 同步成它那把
#'
#' 这是那条不变量的**唯一**写入口。切厂商时、保存设置时、清除 Key 时都调它。
#'
#' ⚠️ 它会把列写成 NULL（这家没存过 Key 的时候）—— 这正是要的：切成一家
#'    没填过 Key 的厂商，界面上就该显示"还没填 Key"，而不是接着用上一家的
#'    那把去请求（那是 401，而且报错信息里不会提"你换厂商了"）。
#'    注意这跟 dsapp_settings_save(api_key = NULL) 的"不动"是两回事，
#'    所以这里自己写一句 UPDATE，不走那个函数。
#'
#' ⚠️⚠️ 但**厂商名为空时它什么都不做**（V13.6 item 1）。这是一条安全边界，
#'    不是省事：`v = ""` 会让下面那个查询取不到行，于是走"这家没存过 Key"
#'    那一支，把 `users.llm_api_key` 写成 NULL —— 也就是**用"空厂商"这个
#'    名义把当前那把 Key 抹掉**。而调用点拿到的 vendor 往往来自 `input$vendor`，
#'    在"页面刚建立会话、控件还没报值"的那一小段里它就是 NULL/空串。
#'    2026-09-17 复现过（退出登录再登回来，列被写成 NULL）。
#'    "把某个厂商生效"这件事在厂商名是空的时候**没有意义**，所以这里直接
#'    返回 FALSE，一个字节都不写。
dsapp_api_key_activate <- function(user_id, vendor, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return(invisible(FALSE))

  # ★ V13.1 item 9：这里读的是**库里原样的那一串**（密文），不是解密后的
  #   Key —— 然后把密文原样搬进 users.llm_api_key。
  #
  #   为什么不走 dsapp_api_key_recall()（它解密）：那条路会逼着我在写回之前
  #   再加密一次，多一次"解→加"的往返。往返本身不贵，贵的是它带来的两个
  #   失败模式：钥匙串万一读不出来，recall 返回的 api_key 是 NULL，于是这一
  #   句把列**写成 NULL** —— 用户什么都没干，Key 就没了。搬密文没有这个
  #   问题：搬过去还是那一串，解不解得开是读的时候的事。
  raw <- if (nzchar(v)) tryCatch(
    DBI::dbGetQuery(con,
      "SELECT api_key FROM user_api_keys WHERE user_id = ? AND vendor = ?",
      params = list(as.integer(user_id), v)),
    error = function(e) NULL) else NULL
  k <- if (is.null(raw) || nrow(raw) == 0 || is.na(raw$api_key[[1]])) NULL
       else as.character(raw$api_key[[1]])

  invisible(tryCatch({
    if (is.null(k) || !nzchar(k)) {
      # ★★ Test_V15.4 item 1：**厂商没变的时候，不许拿"这家没有钥匙串行"
      #    当理由把列抹掉。**
      #
      #    原来的行为是无条件清空。它在"用户主动切到一家没填过 Key 的厂商"
      #    时是对的（界面必须诚实地说"还没填 Key"），在**厂商根本没变**时
      #    是纯破坏：列里那把 Key 是这家**唯一**还活着的副本（钥匙串那一行
      #    可能因为换过 data_root、从老版本升上来、被外部的库操作动过而没了），
      #    清掉就是"用户什么都没干，Key 没了"—— 而下一句还在读它。
      #
      #    判据取自**库本身**而不是调用方传参：调用点有四处，让每一处都记得
      #    "我这次是不是真的在换厂商"是记不住的，而漏记的表现是静默抹 Key。
      #    这里直接比 `users.llm_vendor`：
      #      · 不同 → 调用方正在换厂商，列里那把是**上一家的**，必须清掉
      #               （留着就会拿着 A 家的 Key 去请求 B 家，401 里还不提厂商）；
      #      · 相同 → 厂商没变，列里那把就是这一家的，留着。
      #    列本来就是空的时候什么都不用做（下面 `cur` 为空直接跳过）。
      #
      #    ⚠️ 用户**明确**要清空的那条路不受影响：`dsapp_settings_forget_key()`
      #       自己写 UPDATE，压根不走这个函数。
      cur <- tryCatch(
        DBI::dbGetQuery(con,
          "SELECT llm_vendor, llm_api_key FROM users WHERE id = ?",
          params = list(as.integer(user_id))),
        error = function(e) NULL)
      same_vendor <- !is.null(cur) && nrow(cur) == 1 &&
        identical(trimws(as.character(cur$llm_vendor[[1]] %||% "")), v)
      col_has_key <- !is.null(cur) && nrow(cur) == 1 &&
        nzchar(as.character(cur$llm_api_key[[1]] %||% ""))
      if (same_vendor && col_has_key) {
        # 什么都不做 —— 这是自愈，不是失败。留个痕，否则下次有人看日志会
        # 以为这里该写没写。
        message("[dsapp] 厂商 ", v, " 名下没有钥匙串行，但列里有 Key —— ",
                "厂商未变，保留列（不入库的自愈，user=", user_id, "）")
        return(invisible(TRUE))
      }
      # ⚠️ "这家没存过 Key" 必须走**字面 NULL** 这一条，不能写成
      #    `params = list(k, uid)` 让 k 当 NULL 传进去 —— RSQLite 对
      #    params 列表里的 NULL 元素会报 "Parameter 2 does not have length 0"，
      #    而调用点大多包着 tryCatch，症状是**列没被改成 NULL、还留着上一家
      #    那把 Key**，界面上完全看不出来。2026-09-16 写这一节时踩过一次。
      #    （dsapp_settings_save 那边用 NA_character_ 是可以的，那是另一条
      #    绑定路径；这里两个分支都写字面量，不依赖那个区别。）
      DBI::dbExecute(con, "UPDATE users SET llm_api_key = NULL WHERE id = ?",
                     params = list(as.integer(user_id)))
    } else {
      DBI::dbExecute(con, "UPDATE users SET llm_api_key = ? WHERE id = ?",
                     params = list(k, as.integer(user_id)))
    }
    TRUE
  }, error = function(e) {
    # 不再静默：这里失败 = 应用会拿着上一家厂商的 Key 去请求，报回来的是
    # 401，而报错信息里没有一个字提到"厂商"。
    message("[dsapp] 同步 API Key 失败（user=", user_id, " vendor=", v, "）：",
            conditionMessage(e))
    FALSE
  }))
}

#' 忘掉保存的 Key
#'
#' 只清 Key，**留着厂商/模型/base_url** —— 用户点这个按钮想表达的是
#' "别替我存钥匙"，不是"把我的模型选择也忘了"。
#'
#' ⚠️ 这里**不能**走 dsapp_settings_save(api_key = "")：空串在那边是
#'    "不要动"（理由见那个函数的说明）。清空是唯一一个必须绕开那条保护的
#'    动作。
#'
#' ---- V13.1 item 5：清的是**所有厂商**，不只是当前这个 ----
#'
#' 有了钥匙串之后，"清除"该清一把还是清全部，是个真问题。选了清全部，
#' 理由是这个按钮的**动机**：点它的人是"别替我存钥匙"，而在意这件事的人
#' （公用机器、借别人的电脑、实验室共用账号）**不会**知道要去每个厂商那里
#' 各点一次 —— 他甚至不记得自己配过几家。只清当前厂商的话，界面上会显示
#' "还没记住 Key"，看起来干干净净，而另外几家的 Key 还好端端躺在库里。
#' 那是一种假的安全感，比不做这个功能更糟。
#'
#' 代价是"只想删掉某一家那把那把旧 Key"的人会把别的也删了 —— 所以他得
#' 重新粘一遍。对比漏删的后果（凭据留在服务器上、用户以为已经删了），
#' 这个方向的错误是可以承受的。
dsapp_settings_forget_key <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  # 先数一下有几把，好让调用方能如实告诉用户"清掉了 N 把"，而不是笼统的
  # 一句"已清除" —— 他配过三家、界面只说清了一把的话，剩下的两把就永远
  # 不会有人去查了。
  n <- tryCatch(
    as.integer(DBI::dbGetQuery(con,
      "SELECT COUNT(*) FROM user_api_keys WHERE user_id = ?",
      params = list(as.integer(user_id)))[[1]]),
    error = function(e) 0L)

  dsapp_api_key_forget(user_id, vendor = NULL, con = con)
  invisible(tryCatch({
    DBI::dbExecute(con, "UPDATE users SET llm_api_key = NULL WHERE id = ?",
                   params = list(as.integer(user_id)))
    TRUE
  }, error = function(e) FALSE))

  # 返回清掉的**把数**（不是 TRUE/FALSE）给界面写文案用。
  # ⚠️ 必须在删之前数（上面那句 n <- ...）。写成删完再数的话，界面会永远
  #    说"已清除 0 把"，而这看起来一点也不像坏了。
  invisible(n)
}

# ---- 每账号的硬件资源配额（V6，item 4）-------------------------------------

#' 「这一项不设上限」的哨兵（★ V15.6 item 14）
#'
#' 用户原话：「配额和资源上限里需要可以让管理员直接设置，不限制使用」。
#'
#' ⚠️⚠️ 为什么**必须**用一个哨兵，而不是拿现成的 0 / NA / NULL 兼两种意思：
#'    那三个值在这一列上**已经有主了** —— 它们全都表示"恢复平台默认"，而
#'    平台默认是**有限**的（DSAPP_EXEC_CPU_SEC=1800 等）。拿 0 当"不限制"的
#'    话，管理员点了"不限制"，落库被 norm() 吃成 NA、读回来又被 num() 吃成
#'    NULL，最后执行时用回平台默认 —— 界面上写着"不限制"，跑起来 12 分钟被
#'    砍掉，而且**全程不报错**。
#'
#'    负数没有这个歧义：这一列的取值范围是有物理意义的正数，负数是任何
#'    路径都不会产生的值。所以：
#'      · NULL / NA / 0  → 恢复平台默认（原来的语义，一字未动）
#'      · 负数（哨兵）    → 不设上限
#'      · 正数            → 夹进量程后落库
#'
#' ⚠️ 改这一套的时候，**五个地方要一起改**（少一个就是上面那种静默降级）：
#'    ① dsapp_user_limits() 的 num()   —— 读回来时别把哨兵吃掉
#'    ② dsapp_user_set_limits() 的 norm() —— 落库时别把哨兵吃掉
#'    ③ dsapp_limits_for_user()        —— 哨兵要变成 Inf 再交出去
#'    ④ executor.R 的 ulimit 模板       —— Inf 不是数字，不能 sprintf("%d")
#'    ⑤ prompts.R 打印上限那一段        —— 同上，as.integer(Inf) 是 NA
DSAPP_LIMIT_UNLIMITED <- -1

#' 这一项是不是"不设上限"
#'
#' ⚠️ 判据是 `< 0` 而不是 `== DSAPP_LIMIT_UNLIMITED`：哨兵经过一次 JSON
#'    往返（界面 → input）可能变成 -1.0，`identical(-1, -1L)` 是 FALSE，
#'    而 `==` 在浮点上也够用；写成 `< 0` 就把这些都盖住了，代价只是
#'    "-2 也算不限制"，而 -2 在界面上根本产生不出来。
dsapp_limit_is_unlimited <- function(x) {
  if (is.null(x) || length(x) == 0) return(FALSE)
  v <- suppressWarnings(as.numeric(x))[1]
  !is.na(v) && v < 0
}

#' 某个账号的硬件资源上限
#'
#' 返回 list(cpu_sec, mem_mb, max_procs)，**每一项都可能是 NULL** ——
#' NULL 的意思是"跟着平台默认值走"（config.R 的 exec 段），不是 0。
#' 负数（DSAPP_LIMIT_UNLIMITED）的意思是"不设上限"。
#'
#' 这里刻意不在这里填默认值：填了的话，管理员看到的"当前生效值"就永远是
#' 一串数字，分不清哪些是他设的、哪些是平台给的；而他一旦想"恢复默认"
#' 就没有回头路（不知道默认是多少）。默认值的解析在 dsapp_limits_for_user()。
dsapp_user_limits <- function(user_id, con = dsapp_db()) {
  empty <- list(cpu_sec = NULL, mem_mb = NULL, max_procs = NULL)
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(empty)

  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT cpu_sec, mem_mb, max_procs FROM users WHERE id = ?",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(empty)

  num <- function(x) {
    if (is.null(x) || length(x) == 0 || is.na(x)) return(NULL)
    v <- suppressWarnings(as.numeric(x))
    if (is.na(v)) return(NULL)
    # ★ V15.6 item 14：哨兵必须在 `v <= 0` **前面**认出来。顺序反了的话，
    #   "不限制"读回来变成 NULL = "跟着平台默认"，执行时照样有上限 ——
    #   而且不报错（这条正是上面那段警告说的第一个静默降级点）。
    if (v < 0) return(DSAPP_LIMIT_UNLIMITED)
    if (v <= 0) NULL else v
  }
  list(cpu_sec = num(row$cpu_sec[[1]]),
       mem_mb  = num(row$mem_mb[[1]]),
       max_procs = num(row$max_procs[[1]]))
}

#' 设置某个账号的硬件资源上限
#'
#' `NULL` / `NA` / `0` 表示"恢复平台默认"。这是有意的：管理页那个
#' 输入框里，用户清空 = 恢复默认，是最自然的表达。
#' **负数**（DSAPP_LIMIT_UNLIMITED）= 不设上限，见那个常量上面的说明。
dsapp_user_set_limits <- function(id, cpu_sec = NULL, mem_mb = NULL,
                                  max_procs = NULL, con = dsapp_db()) {
  if (is.null(id) || length(id) == 0 || is.na(id)) {
    return(list(ok = FALSE, msg = "缺少账号"))
  }
  norm <- function(x, lo, hi) {
    if (is.null(x) || length(x) == 0) return(NA_real_)
    v <- suppressWarnings(as.numeric(x))
    if (is.na(v)) return(NA_real_)
    # ★ V15.6 item 14：哨兵**原样落库**，不夹进量程。夹了的话 max(-1, 60)
    #   就是 60 —— 管理员设的"不限制"当场变成一个 1 分钟的上限，
    #   而界面下一次打开显示的是 60，看起来像他自己填错了。
    if (v < 0) return(DSAPP_LIMIT_UNLIMITED)
    if (v <= 0) return(NA_real_)
    min(max(v, lo), hi)
  }
  DBI::dbExecute(con,
    "UPDATE users SET cpu_sec = ?, mem_mb = ?, max_procs = ? WHERE id = ?",
    params = list(norm(cpu_sec, 60, 86400),
                  norm(mem_mb, 256, 4 * 1024 * 1024),
                  norm(max_procs, 16, 65536),
                  as.integer(id)))
  # 审计留给调用方记（和 dsapp_user_set_quota 一致）。这里**不能**自己记：
  # dsapp_audit 的 user 参数是**操作者**，而这里手上有的是**被操作的那个
  # 账号** —— 自己记的话，日志上会写"张三改了张三的资源上限"，真正的操作者
  # 反而没留下。见 R/audit.R 顶部第 3 条。
  list(ok = TRUE, msg = "资源上限已更新")
}

#' 改登录邮箱
#'
#' 邮箱在这个应用里就是**账号**：登录用它、日志用它标识"这是谁"、
#' 恢复码也挂在它下面。所以改邮箱是个身份级别的动作，不是改个联系方式。
#'
#' 三件事必须一起做，少一件都会留下一个说不清的账号：
#'   1. 查重 —— 邮箱有 UNIQUE 约束，撞了会抛 SQLite 错误（那句英文报错
#'      对管理员没有任何意义）。这里先查，给一句人话。
#'   2. 清掉旧邮箱的登录锁定 —— 锁定是按**邮箱**记的（见 dsapp_login_row）。
#'      不清的话，旧邮箱上的失败次数会永远留在那儿；哪天有人注册了那个
#'      邮箱，一上来就是"再错 1 次就锁"。
#'   3. 邮箱大小写/空白归一化走 dsapp_user_norm_email，和注册/登录同一套。
#'      不归一化的话，改完邮箱的人用自己刚设的邮箱登录会被判"密码不对"。
#'
#' @return list(ok, msg)
dsapp_user_set_email <- function(id, email, con = dsapp_db()) {
  if (is.null(id) || length(id) == 0 || is.na(id)) {
    return(list(ok = FALSE, msg = "缺少账号"))
  }
  em <- dsapp_user_norm_email(email)
  if (!nzchar(em) || !grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", em)) {
    return(list(ok = FALSE, msg = "邮箱格式不对"))
  }
  cur <- tryCatch(dsapp_user_by_id(id, con = con), error = function(e) NULL)
  if (is.null(cur)) return(list(ok = FALSE, msg = "这个账号已经不在了"))
  old <- as.character(cur$email %||% "")
  if (identical(tolower(old), tolower(em))) {
    return(list(ok = TRUE, msg = sprintf("邮箱没变，还是 %s", em)))
  }
  # 查重查的是**用户表**，不是锁定表。这两张表是独立的：一个邮箱可能只在
  # login_fail 里有行（试过密码但没注册成），那种情况不算"被占用"——
  # 否则管理员会被一个根本不存在账号的邮箱挡住，而且没有界面能清掉它。
  hit <- tryCatch(dsapp_user_by_email(em, con = con), error = function(e) NULL)
  if (!is.null(hit) && !identical(as.integer(hit$id), as.integer(id))) {
    return(list(ok = FALSE, msg = sprintf("%s 已经被另一个账号用了", em)))
  }
  DBI::dbExecute(con, "UPDATE users SET email = ? WHERE id = ?",
                 params = list(em, as.integer(id)))
  # 旧邮箱上的失败计数跟着一起清掉。不清的话它会在那儿烂着；哪天有人注册了
  # 那个旧邮箱，一上来就是"再错 1 次就锁"—— 而他一次都没试过。
  tryCatch(dsapp_login_unlock(old, con = con), error = function(e) NULL)
  list(ok = TRUE, msg = sprintf("%s → %s", old, em))
}

#' 某个账号的 GPU 开关（三态）
#'
#' 返回 TRUE / FALSE / NA：
#'   TRUE  = 管理员**明确打开**
#'   FALSE = 管理员**明确关掉**
#'   NA    = 这一行**没设过**，调用方该去看平台默认（cfg$exec$gpu）
#'
#' ⚠️ 返回 NA 而不是直接回落到平台默认：这两个状态在界面上要分开显示
#'    （"跟着平台"和"管理员关的"是两件事，后者不会因为平台默认改了而改变）。
#'    要"合并好的最终值"用 dsapp_limits_for_user()$gpu。
#'
#' ⚠️ 读的是 gpu_enabled 这一列**本身**，不走 dsapp_user_limits()：那边的
#'    num() 会把 0 吃成 NULL，"明确关掉"和"没设过"于是在读出侧又混成一个。
dsapp_user_gpu_enabled <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(NA)
  v <- tryCatch(
    DBI::dbGetQuery(con, "SELECT gpu_enabled FROM users WHERE id = ?",
                    params = list(as.integer(user_id)))$gpu_enabled,
    error = function(e) NULL)
  if (is.null(v) || length(v) == 0 || is.na(v[[1]])) return(NA)
  as.integer(v[[1]]) != 0L
}

#' 设置某个账号的 GPU 开关
#'
#' `on` 收 TRUE / FALSE（也收 0 / 1 / "1" / "0"）。
#'
#' ⚠️ 和 dsapp_user_set_limits 一样，**审计留给调用方记** —— 这里手上有的
#'    是**被操作的那个账号**，自己记的话日志上会写成"张三改了张三的开关"。
#'
#' @param on TRUE = 允许用 GPU；FALSE = 不许用。
#' @return list(ok, msg)
dsapp_user_set_gpu <- function(id, on, con = dsapp_db()) {
  if (is.null(id) || length(id) == 0 || is.na(id)) {
    return(list(ok = FALSE, msg = "缺少账号"))
  }
  # ⚠️ 只认肯定写法，认不出来当 FALSE（"不许用"是安全的那一边）——
  #    和 config.R 的 as_flag 同一个取舍：读错方向等于把卡敞开。
  on <- isTRUE(on) || identical(as.character(on)[1], "1") ||
        tolower(as.character(on)[1]) %in% c("true", "yes", "on")
  DBI::dbExecute(con, "UPDATE users SET gpu_enabled = ? WHERE id = ?",
                 params = list(if (on) 1L else 0L, as.integer(id)))
  list(ok = TRUE, msg = if (on) "已允许使用 GPU" else "已禁止使用 GPU")
}

#' 清掉某个账号的 GPU 开关（回到"跟着平台默认"）
#'
#' 单独一个函数而不是 `dsapp_user_set_gpu(id, NULL)`：那个函数的入参是
#' 布尔，`NULL` 传进去会被当成"不许用"，正好和"恢复默认"相反 ——
#' 而两者在界面上是两颗不同的按钮（保存 / 恢复平台默认）。
dsapp_user_clear_gpu <- function(id, con = dsapp_db()) {
  if (is.null(id) || length(id) == 0 || is.na(id)) {
    return(list(ok = FALSE, msg = "缺少账号"))
  }
  DBI::dbExecute(con, "UPDATE users SET gpu_enabled = NULL WHERE id = ?",
                 params = list(as.integer(id)))
  list(ok = TRUE, msg = "GPU 开关已恢复平台默认")
}

#' 把「账号配额」和「平台默认」合成一份**实际会用到的**上限
#'
#' 执行链路只该调这一个函数。分成两处各取一次的话，"管理员设了内存上限"
#' 和"执行时用了内存上限"之间没有任何东西保证它们读的是同一列。
#'
#' @param user_id 任务发起人；NULL（无主任务）时全部走平台默认。
dsapp_limits_for_user <- function(user_id, cfg = dsapp_config(),
                                  con = dsapp_db()) {
  base <- list(cpu_sec = cfg$exec$cpu_sec,
               mem_mb = cfg$exec$mem_mb,
               max_procs = cfg$exec$max_procs)
  u <- dsapp_user_limits(user_id, con = con)
  for (k in names(base)) {
    # ★ V15.6 item 14：哨兵在这里**翻译成 Inf**再交出去。
    #
    #   为什么不把 -1 原样传下去：下游全是"把数字格式化进字符串"的地方
    #   （executor.R 的 sprintf("ulimit -v %d")、prompts.R 的 as.integer），
    #   它们看到 -1 会老老实实写出 `ulimit -v -1` 和「内存上限：-1 MB」——
    #   前者被 `2>/dev/null || true` 吞掉（限制静默消失，碰巧等于不限制，
    #   但那是运气），后者是打印给模型看的假数。
    #
    #   Inf 的含义在这里是**单一**的："这一项没有上限"。下游一律用
    #   is.finite() 判它，而不是拿它去算术。选 Inf 而不是 NA/NULL，是因为
    #   那两个在本函数里已经是"平台默认"的意思了（上面 base 里装的就是）。
    base[[k]] <- if (dsapp_limit_is_unlimited(u[[k]])) Inf else
      if (!is.null(u[[k]])) u[[k]] else base[[k]]
  }
  # ★ V14 item 7：GPU 这一项**不进上面那个循环**，理由见 users.R 里
  #   gpu_enabled 那段的说明（0 是有意义的值，会被 num()/norm() 吃掉）。
  #
  # ⚠️ 这里把三态收成**两态**（TRUE/FALSE）再交出去：执行链路只需要回答
  #    "这一次能不能用卡"，而 NA 传下去迟早会有人在某个 if 里用错
  #    （`if (NA)` 在 R 里是**硬错误**，会让整个任务起不来）。
  #    要显示"是跟着平台还是管理员设的"，界面上另外调
  #    dsapp_user_gpu_enabled()。
  g <- dsapp_user_gpu_enabled(user_id, con = con)
  base$gpu <- if (is.na(g)) isTRUE(cfg$exec$gpu) else isTRUE(g)
  base
}

#' 这个账号这次能不能用 GPU（合成好的逻辑值）
#'
#' 给**只想问 GPU 这一件事**的调用方用（提示词里 conda 环境那一支）。
#' 它和 `dsapp_limits_for_user()$gpu` 是同一个口径 —— 账号值优先、没设过
#' 落回平台默认 —— 差别只在不用把 cpu/mem/max_procs 一起算出来。
#'
#' ⚠️ 这里**不是**第二份真相：它内部就是走 dsapp_limits_for_user()，
#'    改口径只会改那一处。自己另写一遍取数逻辑，就等着两边哪天对不上。
#'
#' ⚠️ user_id 为 NULL / NA（无主任务、自检、后台子进程没带身份）时返回
#'    平台默认 —— 和 dsapp_limits_for_user(NULL) 的行为一致，不能默认放行。
#'
#' ⚠️ 默认值写成 `con = dsapp_db(cfg)`（**惰性求值**，R 允许默认值引用前面的
#'    形参），**不要**写成 `con = NULL` 再 `con %||% dsapp_db(cfg)`：
#'    连接是 S4 对象，`%||%` 最后一步会去算 `is.na(a[1])`，而 S4 对象没有
#'    `[` 方法 —— 那里会**抛错**，被下面的 tryCatch 吞掉之后变成"读不出来"
#'    → 恒返回 FALSE。症状是"管理员明明开了，用户还是没卡"，而且全程不报错。
#'    （`%||%` 对 environment 也有同一个毛病，见 utils.R 那段说明。）
dsapp_gpu_allowed <- function(user_id, cfg = dsapp_config(), con = dsapp_db(cfg)) {
  if (is.null(user_id) || length(user_id) == 0 ||
      is.na(suppressWarnings(as.integer(user_id)))) {
    return(isTRUE(cfg$exec$gpu))
  }
  lim <- tryCatch(dsapp_limits_for_user(user_id, cfg, con = con),
                  error = function(e) NULL)
  if (is.null(lim)) return(FALSE)   # 读不出来 → 不给（见 executor.R 同款取舍）
  isTRUE(lim$gpu)
}

#' 「直接进入」模式下用哪个账号
#'
#' 取 id 最小的**启用中**用户 —— 也就是最早注册的那个（管理员自己）。
#' 一个都没有就现场建一个，否则进门时没有账号可用，页面会直接空白。
#'
#' ⚠️ 2026-09-13 加的。背景：用户反复报"登录了还是进不去"。查下来，
#'    服务端认证一直是成功的，卡住的是登录**之后**那一跳 —— 它依赖浏览器
#'    执行 app.js（把 cookie 交给服务端 / 回执），而他浏览器里跑的是**缓存
#'    下来的旧 app.js**，那里面还没有 cookie 这套东西。于是：
#'    回执永远不来 → 2 秒超时 → 重载 → 新会话没有任何身份 → 回到登录页。
#'    证据是 auth.log 里他两次登录前后**一次都没有**"页面加载："那一行，
#'    而那行是 app.js 写给服务端的；我用干净浏览器打开线上，立刻就有了。
#'
#'    结论：把"进门"整件事从浏览器搬回服务端。不经过登录页、不写 cookie、
#'    不需要 reload —— 浏览器里的 JS 是死是活都影响不了进门。
#'
#' @return users 表的一行（含 token）
dsapp_default_user <- function(cfg = dsapp_config(), con = dsapp_db()) {
  # ORDER BY id 不能省：dsapp_user_row 只加了 LIMIT 1，不加排序的话拿到哪一行
  # 是"实现说了算"，换个 SQLite 版本就可能变成另一个账号。
  u <- dsapp_user_row("status = 'active' ORDER BY id", list(), con = con)
  if (!is.null(u)) return(u)

  # 一个可用账号都没有：建一个。邮箱用固定值（不是真实邮箱，不会和谁撞）。
  #
  # ⚠️ 手机号和研究方向**必须填**：dsapp_user_validate 会挡空值（那是注册
  #    表单的规矩）。第一次写的时候这里传了两个空串，结果一路返回 NULL、
  #    静默回落到登录页 —— 又是个"不报错只是不工作"。占位值要写得看得出来
  #    是占位，别填成看着像真手机号的数字。
  #
  # ★ V13.1 item 7：这里原来传的是 `password = ""`（密码留空）。免密登录
  #   取消之后，密码在 dsapp_user_validate 里是**必填**，空串会一路返回
  #   错误 → 这个函数返回 NULL → **auto 模式整个失效**，而 auto 模式正是
  #   "登录这一套坏了"时唯一的兜底（见 config.R 的 auth_mode 说明）。
  #   把兜底改坏是最不该犯的错：平时测不到，要用它的那天才发现。
  #
  #   所以改成给一个**随机密码**：没人知道它、也没人需要知道 —— auto 模式
  #   根本不走 dsapp_user_auth（它在服务端直接把会话挂到这个账号上，
  #   见 app.R 的 auth_mode == "auto" 那一段）。这样换来一条干净的不变式：
  #   **库里不存在没有密码的账号**，"哪些账号能用邮箱白捡"这个问题从此
  #   不需要逐个判断。
  r <- tryCatch(
    dsapp_user_create("本机用户", "local@dsapp.invalid", "00000000000",
                      "（自动创建的本机账号）", dsapp_token(24), con = con),
    error = function(e) NULL)
  if (is.null(r) || !isTRUE(r$ok)) {
    # 建不出来就说清楚为什么。沉默的话现象只是"登录页又出来了"，
    # 和一堆别的原因长得一模一样。
    dsapp_auth_log(sprintf("直接进入失败：默认账号建不出来（%s）",
                           if (is.null(r)) "调用出错" else (r$msg %||% "未知原因")))
    return(NULL)
  }
  r$user
}

dsapp_users_list <- function(con = dsapp_db()) {
  DBI::dbGetQuery(con, "
    SELECT u.id, u.nickname, u.email, u.phone, u.field, u.is_admin,
           u.admin_scope, u.status,
           u.created_at, u.last_seen_at,
           (SELECT COUNT(*) FROM sessions s WHERE s.user_id = u.id) AS n_chat,
           (SELECT COUNT(*) FROM tasks t
              JOIN sessions s2 ON s2.id = t.session_id
             WHERE s2.user_id = u.id) AS n_task
    FROM users u ORDER BY u.id")
}

# ---- 管理员看得见谁（V13.8，item 1）----------------------------------------
#
# 「项目管理员只能查看并更改自己**分发出去**的任务、**组内**的账号成员」——
# 这句话里两个范围各自的出处：
#
#   账号   = 他建的团队（teams.created_by）里的成员 + 他自己
#   任务   = 他名下（sessions.user_id）的对话 + 他分发出去的
#            （session_share.granted_by）对话，这两类下面的任务
#
# ⚠️ 这两条**只在管理页里生效**。它们**不是**权限系统的一部分 ——
#    判权限的自始至终只有 db_session_role()（见 db.R 顶部）。这里回答的是
#    "管理页那一屏列给谁看"，不是"他能不能打开这段对话"。混起来的话，
#    哪天有人调整了一个分组，别人手里正在跑的对话会静默地多出或失去访问权。
#
# ⚠️ 全部返回 NULL 表示「不限」而不是「空集」。空集用 integer(0) /
#    character(0)。这两个值在调用方长得像但意思相反，判错一个方向就是
#    "平台管理员什么都看不见"。所以调用方一律用 `is.null(scope)` 判。

#' 这个管理员能管的账号 id；平台管理员返回 NULL（= 全部）
dsapp_admin_scope_user_ids <- function(user, con = dsapp_db()) {
  if (is.null(user)) return(integer(0))
  if (dsapp_user_is_platform_admin(user)) return(NULL)
  me <- suppressWarnings(as.integer(user$id %||% NA_integer_))
  if (length(me) != 1L || is.na(me)) return(integer(0))
  # 自己必须在名单里：管理页要能给自己改密码、看自己的用量 —— 而一个
  # "连自己都看不到"的管理页第一眼就像坏了。
  #
  # ⚠️ `u.is_admin = 0` 这个条件是**防提权**的，不是装饰：组里的成员会
  #    进入组创建者的管理范围，所以"把另一个管理员拉进我的组"就等于
  #    "我从此能停用他、改他的密码"。管理页的候选人名单里已经把管理员
  #    滤掉了（见 mod_admin.R 的 users_team_pool），但那道在界面上 ——
  #    判据得在这儿，一个自己拼 input 的人绕不过去。
  #    另一面：平台管理员本来就不受限（上面已经 return NULL 了）。
  ids <- tryCatch(
    DBI::dbGetQuery(con, "
      SELECT DISTINCT m.user_id
        FROM team_members m
        JOIN teams t ON t.id = m.team_id
        JOIN users u ON u.id = m.user_id
       WHERE t.created_by = ? AND u.is_admin = 0",
      params = list(me))$user_id,
    error = function(e) integer(0))
  sort(unique(c(me, as.integer(ids %||% integer(0)))))
}

#' 能改这个账号吗（服务端判据）
#'
#' ⚠️ 界面上的按钮**藏起来不算数**。所有真正写库的 handler 进来第一件事
#'    都要过这一道 —— 藏按钮挡得住误点，挡不住一个自己拼 input 值的人，
#'    而这一页的按钮里有「删除账号」。
dsapp_admin_can_touch_user <- function(actor, target_id, con = dsapp_db()) {
  if (is.null(actor)) return(FALSE)
  if (dsapp_user_is_platform_admin(actor)) return(TRUE)
  sc <- dsapp_admin_scope_user_ids(actor, con = con)
  if (is.null(sc)) return(TRUE)          # 理论上到不了，防御性写法
  tid <- suppressWarnings(as.integer(target_id %||% NA_integer_))
  length(tid) == 1L && !is.na(tid) && tid %in% sc
}

#' 这个管理员能管的对话 id（字符向量）；平台管理员返回 NULL（= 全部）
#'
#' 项目管理员要动一段对话，只有两种情况：那是他自己的，或者那是**他分发
#' 出去的**。后者看 session_share.granted_by —— 那一列本来就是共享那一下
#' 记下来的（见 db_session_share_set），一直没人读过。
dsapp_admin_scope_session_ids <- function(user, con = dsapp_db()) {
  if (is.null(user)) return(character(0))
  if (dsapp_user_is_platform_admin(user)) return(NULL)
  me <- suppressWarnings(as.integer(user$id %||% NA_integer_))
  if (length(me) != 1L || is.na(me)) return(character(0))
  ids <- tryCatch(
    DBI::dbGetQuery(con, "
      SELECT id FROM sessions WHERE user_id = ?
      UNION
      SELECT session_id AS id FROM session_share WHERE granted_by = ?",
      params = list(me, me))$id,
    error = function(e) character(0))
  as.character(ids %||% character(0))
}

#' 能管这段对话吗（服务端判据）
dsapp_admin_can_touch_session <- function(actor, sid, con = dsapp_db()) {
  if (is.null(actor)) return(FALSE)
  if (dsapp_user_is_platform_admin(actor)) return(TRUE)
  sc <- dsapp_admin_scope_session_ids(actor, con = con)
  if (is.null(sc)) return(TRUE)
  s <- as.character(sid %||% "")
  length(s) == 1L && nzchar(s) && s %in% sc
}

# ---- 写 --------------------------------------------------------------------

#' 注册
#'
#' @return list(ok, user, token, claimed, msg) 或 list(ok = FALSE, msg)
dsapp_user_create <- function(nickname, email, phone, field, password = "",
                              password2 = NULL, con = dsapp_db()) {
  v <- dsapp_user_validate(nickname, email, phone, field, password, password2)
  if (!is.null(v$error)) return(list(ok = FALSE, msg = v$error))

  if (!is.null(dsapp_user_by_email(v$email, con))) {
    return(list(ok = FALSE, msg = "这个邮箱已经注册过了 —— 用下面的「已有账号」登录"))
  }

  is_first <- tryCatch(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM users")$n[[1]] == 0,
    error = function(e) FALSE)

  salt <- dsapp_token(8)
  # ⚠️ V13.1 item 7 起 v$password **一定非空**（dsapp_user_validate 必填），
  #    所以这个 else 分支现在到不了了。留着 "" 是为了万一有人绕过 validate
  #    直接建号时，落下来的是一行"有 salt 没 hash"的账号 —— 它在
  #    dsapp_user_auth 里会被**当成无密码账号拒掉**，而不是变成一个
  #    "任何密码都能过"的账号（空 hash 撞上空密码的哈希是可能的，
  #    那才是真正危险的默认值）。
  hash <- if (nzchar(v$password)) dsapp_pw_hash(v$password, salt) else ""
  token <- dsapp_token(24)
  admins <- dsapp_admin_emails()
  is_admin <- is_first || v$email %in% admins
  # V13.8 item 1：级别要和 is_admin **在同一行 INSERT 里**写下去。
  # 只写 is_admin 的话，这一行会短暂处于"是管理员但没有级别"的状态 ——
  # 读出来靠 dsapp_user_admin_scope() 的兜底才勉强对，而中间任何一次
  # 建表回填（每次 dsapp_db() 都跑）会把它坐实成 platform。宁可写明白。
  # 第一个账号和 .Renviron 里点名的那几个都是平台管理员：他们是这个实例
  # 的建立者，把自己降成项目管理员得之后再手动改。
  scope <- if (is_admin) "platform" else ""

  id <- DBI::dbGetQuery(con,
    "INSERT INTO users (nickname, email, phone, field, pass_salt, pass_hash,
                        token, is_admin, admin_scope, status, created_at,
                        last_seen_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?) RETURNING id",
    params = list(v$nickname, v$email, v$phone, v$field, salt, hash, token,
                  as.integer(is_admin), scope, dsapp_now(), dsapp_now()))$id
  id <- as.integer(id)

  # 首个账号顺手接管 V5 之前留下的无主数据。不接管的话，用户注册完会发现
  # 自己之前跑的东西全都不见了 —— 而它们明明还在库里。
  claimed <- if (is_first) dsapp_user_claim_orphans(id, con) else 0L

  # 注册要留痕：这个平台是多人共用的，管理员需要知道账号是什么时候多出来的
  # （以及有没有人拿一串临时邮箱刷注册）。
  dsapp_audit("register", user_id = id, target = v$email,
              detail = if (is_admin) "管理员账号" else "", con = con)

  list(ok = TRUE, user = dsapp_user_by_id(id, con), token = token,
       claimed = claimed,
       msg = if (claimed > 0)
         sprintf("已把此前 %d 个未归属的对话划到这个账号名下", claimed) else "")
}

#' 按一份**同步包里的认领材料**建号（V16.6 item 1）
#'
#' ★★ 为什么不复用 `dsapp_user_create()`：那个函数里有**两条提权口**，
#'    任何一条到了这条路上都是"投一个包 = 拿一个平台管理员"：
#'      · `is_first`（库是空的 → 第一个账号自动 `scope = "platform"`）；
#'      · `DSAPP_ADMIN_EMAIL` 命中（.Renviron 里点名的那几个邮箱）。
#'    这条路是**别人投进来的数据**触发的，不是人在表单里注册的，
#'    所以这两条都不能沾 —— 级别一律写字面量 0 / ''。
#'
#' ★ 口令材料（salt / hash）**原样存**，不重新生成、不重新算：
#'    它们就是"两边密码一致"的全部秘密。云端存下这两个值之后，用户拿
#'    同一个密码就能在网页版登录（dsapp_user_auth 的算法本来就是
#'    `dsapp_pw_hash(密码, salt) == hash`，和盐是谁生成的无关）。
#'
#' ⚠️ 调用方**必须**已经做完验签和全部格式校验。这个函数只负责"写进去"
#'    这一件事，它自己不做任何安全检查 —— 别把它当入口用。
#'
#' @return 新账号的 id（整数）；写不进去返回 NA_integer_
dsapp_user_create_from_sync <- function(email, salt, hash, nickname = "",
                                        phone = "", field = "", pubkey = "",
                                        from_node = "", con = dsapp_db()) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email)) return(NA_integer_)
  # 二次确认"这个邮箱还没有"。调用方查过一次，但从那一次到这里之间
  # **可能已经有别人建了同一个邮箱**（两个包几乎同时到、或者本人刚好在
  # 网页版注册了）。这里再查一次是最后一道闸：唯一索引会挡住，但那一下
  # 是抛错，而抛错在这条路上会被 tryCatch 吞成"建号失败"，
  # 报出来的是"同步失败"而不是"这个邮箱已经存在了"。
  if (!is.null(dsapp_user_by_email(email, con))) return(NA_integer_)
  nm <- trimws(as.character(nickname %||% ""))
  if (!nzchar(nm)) nm <- email
  # 头像用的首字母在别处，这里只截长度：昵称是能从包进来的自由文本，
  # 不截的话一条超长昵称能把管理页的表格撑爆。
  nm <- substr(nm, 1, 40)
  id <- tryCatch(
    DBI::dbGetQuery(con,
      "INSERT INTO users (nickname, email, phone, field, pass_salt, pass_hash,
                          token, is_admin, admin_scope, status, created_at,
                          last_seen_at, sync_pubkey, sync_claimed_at,
                          sync_claimed_from)
       VALUES (?, ?, ?, ?, ?, ?, '', 0, '', 'active', ?, ?, ?, ?, ?)
       RETURNING id",
      params = list(nm, email,
                    substr(trimws(as.character(phone %||% "")), 1, 40),
                    substr(trimws(as.character(field %||% "")), 1, 60),
                    as.character(salt), tolower(as.character(hash)),
                    dsapp_now(), dsapp_now(),
                    tolower(trimws(as.character(pubkey %||% ""))),
                    dsapp_now(),
                    substr(as.character(from_node %||% ""), 1, 80)))$id,
    error = function(e) NULL)
  if (is.null(id) || !length(id)) return(NA_integer_)
  id <- as.integer(id)
  # ⚠️ `token` 显式写空串：那是**找回密码用的凭据**（明文存在 users.token，
  #    `?u=<token>` 能直接登进来）。同步包**没有**带它，也绝不能带 ——
  #    带了就等于"一个包能拿走别人账号的登录凭据"。
  #    留空是安全的一侧：忘了密码只能找管理员重置，而不是被包里的 token 顶掉。
  #
  # 审计：这条路是"别人投进来的数据"建出来的号，必须留痕。
  # detail 里**不放**任何口令材料（审计表的 detail 是给人看的，
  # 而且它会被管理页整个读出来）。
  dsapp_audit("register_sync", user_id = id, target = email,
              detail = sprintf("来源节点 %s", from_node %||% ""), con = con)
  id
}

#' 把无主数据划给某个账号
#'
#' @return 被认领的对话数
dsapp_user_claim_orphans <- function(user_id, con = dsapp_db(),
                                     cfg = dsapp_config()) {
  user_id <- as.integer(user_id)
  n <- tryCatch(
    DBI::dbExecute(con, "UPDATE sessions SET user_id = ? WHERE user_id IS NULL",
                   params = list(user_id)),
    error = function(e) 0L)

  # 文件同理：盘上有、表里没有的先补登记成"无主"，再整批划过去。
  # ⚠️ 前缀要一起改，理由见 mod_admin.R 里同一段 SQL 上的注释。
  #
  # ⚠️⚠️ CASE 那一段不是防御性写法，是**必需**的：老库里的行是**没有前缀**的
  #     （`asv_table.csv`，V13 之前建的）。无条件 `substr(name, 6)` 会把
  #     `_anon/` 长度当成所有行的前缀长度 —— 对老行来说切掉的是**文件名的前
  #     6 个字符**，`asv_table.csv` 直接变成 `u1/able.csv`。文件还在盘上，
  #     归属行却指着一个不存在的名字，界面上显示"无主"。
  try(DBI::dbExecute(con,
    "UPDATE file_owner
        SET user_id = ?,
            name = ? || CASE WHEN substr(name, 1, ?) = ?
                             THEN substr(name, length(?) + 1) ELSE name END
      WHERE user_id IS NULL",
    params = list(user_id, dsapp_owner_key("", user_id),
                  nchar(dsapp_owner_key("", NA)), dsapp_owner_key("", NA),
                  nchar(dsapp_owner_key("", NA)))), silent = TRUE)

  as.integer(n %||% 0L)
}

#' 把盘上存在、表里没有的文件补登记成"无主"
#'
#' 文件归属是**旁挂**的：盘上有的文件表里未必有。与其要求每个写入点都记得
#' 登记（漏一处就永远漏，而且是静默漏），不如在登录/管理页按现状补一次。
#' 补出来的行 user_id 是 NULL，也就是"公共"。
dsapp_files_sync_owners <- function(con = dsapp_db(), cfg = dsapp_config()) {
  # ★ V13 item 6：管理区不是一个目录了，是每个账号一个（data/files/u<N>/）。
  #   所以这里要**逐个账号**扫，而且登记进去的 `name` 仍然是**相对该账号
  #   根目录**的路径 —— file_owner 的语义没变（files.R 的 dsapp_file_path
  #   也是相对各自根解析的），变的是"根"在哪儿。
  roots <- tryCatch({
    base <- cfg$files_root %||% file.path(cfg$data_root, "files")
    d <- list.files(base, pattern = "^u[0-9]+$", full.names = TRUE)
    d[dir.exists(d)]
  }, error = function(e) character(0))

  known <- tryCatch(DBI::dbGetQuery(con, "SELECT name FROM file_owner")$name,
                    error = function(e) character(0))
  n <- 0L
  for (root in roots) {
    uid <- suppressWarnings(as.integer(sub("^u", "", basename(root))))
    ucfg <- cfg
    ucfg$files_dir <- root
    # 递归扫全部**文件**（含子目录）。用 find -type f 而不是
    # list.files(recursive = TRUE)：后者会跟着目录软链一路钻出去，
    # 把管理区外面的路径也当成"管理区里的文件"补登记进来。
    # 只登记文件不登记目录 —— 归属管的是"谁能改名/删除"，目录的权限
    # 在 dsapp_file_can_edit 里单独判（见那里的说明）。
    on_disk <- tryCatch(dsapp_shared_scan(ucfg)$files,
                        error = function(e) character(0))
    if (!length(on_disk)) next
    # ⚠️ on_disk 是**相对该账号根目录**的（`asv_table.csv`），而 known 里存的
    #    是**带前缀的键**（`u1/asv_table.csv`）。不补前缀直接 setdiff 的话，
    #    每一个盘上有的文件都会"看起来没登记过" —— 于是每次都走一遍 INSERT
    #    OR IGNORE（全靠 OR IGNORE 兜着才没写坏），而且返回的 n 是虚的
    #    （"补登记了 300 个"，其实一个都没插进去）。
    pfx <- dsapp_owner_key("", uid)
    known_rel <- known[startsWith(known, pfx)]
    missing <- setdiff(on_disk, substring(known_rel, nchar(pfx) + 1L))
    if (!length(missing)) next
    # 一条 INSERT + VALUES 批量，别在循环里逐条打库：管理区可能有几百个文件。
    #
    # ⚠️ 这里补出来的归属人不再是 NULL 了。旧版是 NULL（=「公共」），因为
    #    那时候一个区是大家的；现在这个 root 就是**这个账号的**，补出来的
    #    行当然归他 —— 补成 NULL 的话，界面上显示「公共」，而"公共"在
    #    dsapp_file_can_edit 那条路上意味着谁都能删（包括别的账号吗？不，
    #    别的账号根本看不到这个区了）——即便如此，"自己的文件显示成公共"
    #    本身就是错的，用户会以为自己没有所有权。
    vals <- paste(sprintf("(%s, %d, %s)",
                          DBI::dbQuoteString(con, dsapp_owner_key(missing, uid)),
                          uid,
                          DBI::dbQuoteString(con, dsapp_now())), collapse = ",")
    try(DBI::dbExecute(con, paste0(
      "INSERT OR IGNORE INTO file_owner (name, user_id, created_at) VALUES ",
      vals)), silent = TRUE)
    known <- c(known, paste0(pfx, missing))
    n <- n + length(missing)
  }
  n
}

#' 登录（邮箱 + 口令）
#'
#' @param session Shiny 会话（可选）。只用来在审计日志里记一条来源 IP ——
#'   排查"同一个地址在拿不同邮箱试密码"时它是唯一的线索。
dsapp_user_auth <- function(email, password, con = dsapp_db(), session = NULL) {
  u <- dsapp_user_by_email(email, con)
  if (is.null(u)) {
    # 不存在的邮箱也计数：不然这个表单就是一个免费、无限次的账号枚举器
    # （"没有这个邮箱的账号"和"密码不对"把有没有这个人直接说出来了）。
    # 按邮箱分别计数，所以错别人的邮箱锁不到你自己的账号。
    f <- dsapp_login_fail(email, con)
    dsapp_audit("login_fail", target = email, ok = FALSE,
                detail = "没有这个邮箱的账号", session = session, con = con)
    return(list(ok = FALSE,
                msg = dsapp_login_fail_msg("没有这个邮箱的账号", f)))
  }
  if (!dsapp_user_active(u)) {
    dsapp_audit("login_fail", user = u, ok = FALSE, detail = "账号已停用",
                session = session, con = con)
    return(list(ok = FALSE, msg = "这个账号已被停用，请联系管理员"))
  }
  hash <- as.character(u$pass_hash %||% "")

  # ★ V13.1 item 7：无密码账号**一律拒绝**。
  #
  #   用户原话：「取消免密登录这种方式」。原来这里有一条刻意的旁路 ——
  #   pass_hash 是空串就把人放进去，理由写在旧注释里（"界面上明说了不设密码
  #   的账号别人填邮箱就能进，那就要真的能进"）。**那条路现在整条删掉了。**
  #
  #   为什么是删掉而不是"默认关掉"：
  #     免密登录的危害不是"弱"，是**它把账号变成了一个公开的名字**。任何
  #     知道或猜到邮箱的人都能进去，看到里面所有的工作区、文件、还有那把
  #     存在库里的 API Key —— 而账号主人这边一点痕迹都没有。留着开关，
  #     迟早会有人再打开。
  #
  #   老库里 pass_hash = '' 的账号从此登不进来。这是**有意的**，不是误伤：
  #   给一条"老账号可以继续免密"的过渡期，等于把上面那个洞原样留着。
  #   出口是有的，只是变成两条**需要凭据**的路：管理员重置密码，或者
  #   当初注册时那张恢复码（dsapp_user_auth_token，那条路照旧能用 ——
  #   恢复码是印出来只显示一次的密钥，不是"免密"）。
  #
  #   ⚠️ 这一支必须放在**锁定检查之前**：这类账号现在根本没有任何可尝试的
  #      凭据，让它们进锁定计数器只会被拿来刷别人的账号。
  if (!nzchar(hash)) {
    dsapp_audit("login_fail", user = u, ok = FALSE,
                detail = "账号没有密码（免密登录已在 V13.1 取消）",
                session = session, con = con)
    return(list(ok = FALSE, msg = paste0(
      "这个账号还没有设密码，无法登录。",
      "请联系管理员重置密码，或用注册时那张恢复码登录。")))
  }

  lk <- dsapp_login_locked(email, con)
  if (isTRUE(lk$locked)) {
    # 被锁也要记一条：日志里"失败 8 次 → 锁定"连起来看才知道有没有人在试。
    dsapp_audit("login_locked", user = u, ok = FALSE,
                detail = sprintf("还剩 %d 分钟", ceiling(lk$secs / 60)),
                session = session, con = con)
    return(list(ok = FALSE, msg = sprintf(
      "这个账号因连续登录失败被临时锁定，请 %d 分钟后再试（或找管理员解锁）。",
      ceiling(lk$secs / 60))))
  }

  if (!identical(dsapp_pw_hash(as.character(password %||% ""),
                               as.character(u$pass_salt %||% "")), hash)) {
    f <- dsapp_login_fail(email, con)
    dsapp_audit("login_fail", user = u, ok = FALSE, detail = "密码不对",
                session = session, con = con)
    return(list(ok = FALSE,
                msg = dsapp_login_fail_msg("密码不对", f)))
  }
  dsapp_login_reset(email, con)
  dsapp_audit("login", user = u, session = session, con = con)

  # ★ V13.7 item 7：登录成功是**唯一**能拿到同步密钥的时刻 —— 密码明文只在
  #   这个函数里过一下。现推一个放进程内存（R/synckey.R），不落盘。
  #
  # ⚠️ 放在**验密成功之后**，别提到前面去：那样任何一个打错密码的尝试都能
  #    往内存表里塞一个（错的）密钥，把上一次登录留下的正确密钥顶掉。
  #    表现是"我这边明明登录着，同步突然说密钥不对"——查起来毫无头绪。
  try(dsapp_synckey_put(email, dsapp_sync_key(password, email)), silent = TRUE)

  list(ok = TRUE, user = u, token = as.character(u$token %||% ""),
       must_change = isTRUE(as.logical(u$must_change_pw %||% FALSE)))
}

#' 登录（邮箱 + 恢复码）
#'
#' 恢复码**就是**这个账号的凭证，而且它印在屏幕上、可能被人抄走或转发 ——
#' 所以这条路和密码一样要节流。
#'
#' ★ V13.1 item 7 之后，这是老库里**无密码账号唯一**的自助入口：密码那条路
#'   已经对 pass_hash = '' 的账号整条关掉了（见 dsapp_user_auth）。恢复码是
#'   注册时印出来、只显示一次的密钥，要用它得真的持有它 —— 和"填个邮箱就进"
#'   不是一回事，所以这条路留着没有把免密登录又放回来。
dsapp_user_auth_token <- function(email, token, con = dsapp_db(),
                                  session = NULL) {
  u <- dsapp_user_by_email(email, con)
  if (is.null(u)) {
    f <- dsapp_login_fail(email, con)
    dsapp_audit("login_fail", target = email, ok = FALSE,
                detail = "恢复码登录：没有这个邮箱的账号",
                session = session, con = con)
    return(list(ok = FALSE,
                msg = dsapp_login_fail_msg("没有这个邮箱的账号", f)))
  }
  if (!dsapp_user_active(u)) {
    dsapp_audit("login_fail", user = u, ok = FALSE, detail = "账号已停用",
                session = session, con = con)
    return(list(ok = FALSE, msg = "这个账号已被停用，请联系管理员"))
  }
  lk <- dsapp_login_locked(email, con)
  if (isTRUE(lk$locked)) {
    dsapp_audit("login_locked", user = u, ok = FALSE, detail = "恢复码登录",
                session = session, con = con)
    return(list(ok = FALSE, msg = sprintf(
      "这个账号因连续登录失败被临时锁定，请 %d 分钟后再试（或找管理员解锁）。",
      ceiling(lk$secs / 60))))
  }
  if (!identical(as.character(u$token %||% ""), trimws(as.character(token %||% "")))) {
    f <- dsapp_login_fail(email, con)
    dsapp_audit("login_fail", user = u, ok = FALSE, detail = "恢复码不对",
                session = session, con = con)
    return(list(ok = FALSE,
                msg = dsapp_login_fail_msg("恢复码不对", f)))
  }
  dsapp_login_reset(email, con)
  dsapp_audit("login_token", user = u, session = session, con = con)
  list(ok = TRUE, user = u, token = as.character(u$token),
       must_change = isTRUE(as.logical(u$must_change_pw %||% FALSE)))
}

dsapp_user_touch <- function(id, con = dsapp_db()) {
  if (is.null(id) || is.na(id)) return(invisible(FALSE))
  try(DBI::dbExecute(con, "UPDATE users SET last_seen_at = ? WHERE id = ?",
                     params = list(dsapp_now(), as.integer(id))), silent = TRUE)
  invisible(TRUE)
}

dsapp_user_set_status <- function(id, status, con = dsapp_db()) {
  status <- if (identical(status, "disabled")) "disabled" else "active"
  DBI::dbExecute(con, "UPDATE users SET status = ? WHERE id = ?",
                 params = list(status, as.integer(id)))
  # 停用/启用是管理动作，留痕。@who 由调用方（管理页）在包装层补上，
  # 这里只记"谁被怎么了"—— 函数本身不知道操作者是谁。
  invisible(TRUE)
}

#' 换一个新恢复码
#'
#' 管理员给用户"重置"用的。旧码立刻失效 —— 这是重置的意义。
#' 注意：**不动密码**。用户设过密码的话，密码仍然有效。
dsapp_user_reset_token <- function(id, con = dsapp_db()) {
  tok <- dsapp_token(24)
  DBI::dbExecute(con, "UPDATE users SET token = ? WHERE id = ?",
                 params = list(tok, as.integer(id)))
  tok
}

#' 设 / 改密码
#'
#' 三个入口共用这一个函数：注册后补设（原本没有密码）、自己改密码、
#' 管理员重置。**只有一个地方**管散列和 salt，别在界面回调里各写一遍 ——
#' salt 忘了重新生成的话，同一个密码在库里就是同一串散列，一眼能看出
#' 哪些账号用了一样的密码。
#'
#' @param old_password 账号**已有**密码时，这里是当前密码。为空表示没提供。
#' @param skip_old_check 跳过当前密码校验。**只有一条路能传 TRUE**：用户
#'   当前这一步已经用恢复码证明过自己是账号主人（见 mod_welcome.R 的强制
#'   改密页）。恢复码本身就是这个账号的主凭证，拿它再要求输入旧密码是
#'   自相矛盾的 —— 而"忘了旧密码"正是走那条路的唯一理由。
#' @return list(ok, msg, wrong_old, locked)
dsapp_user_set_password <- function(id, new_password, old_password = NULL,
                                    skip_old_check = FALSE, con = dsapp_db()) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "账号不存在"))

  u <- tryCatch(dsapp_user_by_id(id, con), error = function(e) NULL)
  if (is.null(u)) return(list(ok = FALSE, msg = "账号不存在"))

  new_password <- as.character(new_password %||% "")
  if (nchar(new_password) < DSAPP_PW_MIN) {
    return(list(ok = FALSE,
                msg = sprintf("新密码至少 %d 位", DSAPP_PW_MIN)))
  }
  if (nchar(new_password) > 200) {
    return(list(ok = FALSE, msg = "新密码太长了（200 位以内）"))
  }

  old_hash <- as.character(u$pass_hash %||% "")

  # ---- 已有密码：先证明你知道当前密码 ----
  #
  # ⚠️ 这道检查防的是"别人趁你不在，用你忘退的浏览器把密码换掉"——
  #    换了之后账号就是他的了。它**不是**防爆破的主防线（登录那道才是），
  #    所以这里沿用同一套失败计数：不然一个已经拿到会话的人可以在这里
  #    无限次地试你的旧密码，而登录页那边还老老实实地计着数。
  if (nzchar(old_hash) && !isTRUE(skip_old_check)) {
    email <- as.character(u$email %||% "")
    lk <- dsapp_login_locked(email, con)
    if (isTRUE(lk$locked)) {
      return(list(ok = FALSE, locked = TRUE, msg = sprintf(
        "尝试次数太多，这个账号被临时锁定，请 %d 分钟后再试。",
        ceiling(lk$secs / 60))))
    }
    if (!nzchar(as.character(old_password %||% ""))) {
      dsapp_audit("pw_fail", user = u, ok = FALSE, detail = "没填当前密码",
                  con = con)
      return(list(ok = FALSE, wrong_old = TRUE, msg = "请先填当前密码"))
    }
    if (!identical(dsapp_pw_hash(as.character(old_password),
                                 as.character(u$pass_salt %||% "")),
                   old_hash)) {
      f <- dsapp_login_fail(email, con)
      dsapp_audit("pw_fail", user = u, ok = FALSE, detail = "当前密码不对",
                  con = con)
      return(list(ok = FALSE, wrong_old = TRUE,
                  msg = dsapp_login_fail_msg("当前密码不对", f)))
    }
    dsapp_login_reset(email, con)
  }

  salt <- dsapp_token(8)
  DBI::dbExecute(con,
    "UPDATE users SET pass_salt = ?, pass_hash = ?, must_change_pw = 0
     WHERE id = ?",
    params = list(salt, dsapp_pw_hash(new_password, salt), id))

  # 改完密码顺手把失败计数清掉：用户刚证明了自己是谁，还留着一个
  # "再错 1 次就锁"的计数，下一次手滑就被关在门外 —— 而那是他自己
  # 刚才改密码时留下的。
  try(dsapp_login_reset(as.character(u$email %||% ""), con), silent = TRUE)

  # detail 只记"是怎么改的"，不记密码本身（当然）。skip_old_check 那条路
  # 是"用恢复码证明身份后改的"，事后回看日志时要能分辨出来 —— 它绕过了
  # 一道检查，是审计上更需要留痕的一条路。
  dsapp_audit("pw_set", user = u,
              detail = if (isTRUE(skip_old_check)) "用恢复码验证后设置"
                       else if (nzchar(old_hash)) "凭当前密码修改"
                       else "首次设置",
              con = con)

  list(ok = TRUE, msg = if (nzchar(old_hash)) "密码已更新" else "密码已设置")
}

#' 管理员重置密码
#'
#' 和用户自己改的区别只有一个：**打上"下次登录必须改掉"的标记**。
#' 管理员定的密码经过管理员的手（写在纸条上、发在微信里），不该长期有效。
#'
#' 同时清掉登录失败计数：重置密码的常见起因就是"用户被锁在门外了"，
#' 重置完还让他等 15 分钟说不过去。
dsapp_user_admin_reset_password <- function(id, new_password, con = dsapp_db()) {
  id <- as.integer(id)
  if (is.na(id)) return(list(ok = FALSE, msg = "账号不存在"))
  u <- tryCatch(dsapp_user_by_id(id, con), error = function(e) NULL)
  if (is.null(u)) return(list(ok = FALSE, msg = "账号不存在"))

  new_password <- as.character(new_password %||% "")
  if (nchar(new_password) < DSAPP_PW_MIN) {
    return(list(ok = FALSE, msg = sprintf("新密码至少 %d 位", DSAPP_PW_MIN)))
  }

  salt <- dsapp_token(8)
  DBI::dbExecute(con,
    "UPDATE users SET pass_salt = ?, pass_hash = ?, must_change_pw = 1
     WHERE id = ?",
    params = list(salt, dsapp_pw_hash(new_password, salt), id))
  try(dsapp_login_reset(as.character(u$email %||% ""), con), silent = TRUE)

  # 审计**不在这里**记：这个动作的施与者是管理员，而本函数只知道谁的密码
  # 被重置了。按 R/audit.R 顶部那条规则，操作者另有其人的动作记在调用方
  # （mod_admin.R），那里才拿得到 state$user。

  list(ok = TRUE, msg = sprintf("已重置 %s 的密码，他下次登录时必须改成自己的",
                                as.character(u$nickname %||% "")))
}

#' 账号当前的密码状态（给界面显示用）
dsapp_user_pw_state <- function(user) {
  if (is.null(user)) return(list(has = FALSE, must_change = FALSE))
  list(has = nzchar(as.character(user$pass_hash %||% "")),
       must_change = isTRUE(as.logical(user$must_change_pw %||% FALSE)))
}

#' 删除账号
#'
#' 连带删掉：它名下的对话（消息随外键级联删）、每个对话的工作区目录、
#' 以及它上传的文件的归属记录。
#'
#' ⚠️ V16.6 item 3 起，这条注释里"共享区里的文件本身不删"那半句**不再成立**：
#'    用户的原话是「删除账户后，该账号对应的全部历史记录和文件应该一并删除，
#'    而不是进入共享区」。所以现在连同 `data/files/u<N>/` 整个目录一起删。
#'    在这之前那一版只删了 file_owner 的行、留着盘上的目录，而
#'    `dsapp_files_sync_owners()` 每次登录/开管理页都会把盘上有、表里没有的
#'    文件**重新补登记**成这个账号的 —— 于是"删过的号"的文件又冒出来，
#'    看上去像"进了共享区"。根因就是这里。
dsapp_user_delete <- function(id, cfg = dsapp_config(), con = dsapp_db()) {
  id <- as.integer(id)
  # ★ 邮箱要在删 users 行**之前**取 —— forum_marks 是拿邮箱当键的，
  #   行删掉之后就再也对不上是谁了（那张表故意没有 user_id，
  #   见 R/forum.R：论坛的作者身份走邮箱，本地 uid 不过网）。
  email <- tryCatch(
    DBI::dbGetQuery(con, "SELECT email FROM users WHERE id = ?",
                    params = list(id))$email,
    error = function(e) character(0))
  sids <- tryCatch(
    DBI::dbGetQuery(con, "SELECT id FROM sessions WHERE user_id = ?",
                    params = list(id))$id,
    error = function(e) character(0))

  for (sid in sids) {
    try(db_session_delete(sid, con, cfg = cfg), silent = TRUE)
    try(dsapp_ws_delete(sid, cfg), silent = TRUE)
  }

  try(DBI::dbExecute(con, "DELETE FROM file_owner WHERE user_id = ?",
                     params = list(id)), silent = TRUE)
  # ★ V13 item 3：团队关系也要清。team_members 没有指向 users 的外键（理由
  #   同 tasks / session_share），留着的话那个组的人数永远比实际多一个，
  #   而多出来的那个在账号列表里查不到名字 —— 管理页上就是一个"幽灵成员"。
  try(dsapp_team_remove_user(id, con = con), silent = TRUE)

  # ★★ V16.6 item 3：其余全部残留。放在删 users 行**之前**（下面那个函数
  #    里有一句按 user_id 删 rows 的，users 行没了它照样能删，但
  #    设备上"账号已删、密钥还在"这个中间态越短越好）。
  #
  # ⚠️ 清之前先数一遍。删完再数全是 0，界面上就没法告诉管理员"清了几个文件"
  #    —— 而那正是用户这次提这件事要看到的东西（"说删了"和"真删了"要能对上）。
  res <- tryCatch(dsapp_user_residue(id, email = email, cfg = cfg, con = con),
                  error = function(e) NULL)
  try(dsapp_user_purge(id, email = email, cfg = cfg, con = con), silent = TRUE)

  DBI::dbExecute(con, "DELETE FROM users WHERE id = ?", params = list(id))
  n <- length(sids)
  # 挂成属性而不是改返回值：返回值是"删了几个对话"，两处调用方都在用它拼
  # 人话，改成一整个 list 会把那两处悄悄变成 "0 个对话"（list 拼进 sprintf
  # 报的是别的错，或者更糟 —— 不报错）。
  attr(n, "purged") <- res
  n
}

# ---------------------------------------------------------------------------
# 账号的残留（V16.6 item 3）
# ---------------------------------------------------------------------------

# 删号要清哪些表。**这张表就是"删干净"的定义**，自检和回库对账都照它数。
#
# ⚠️ 故意**不在**这张表里的（删号时留着，每条都有理由，别"顺手"加进来）：
#   · usage_log  —— 平台自己的用量账，append-only。删了的话"这个月用了多少
#                   token"会随着删号往下掉，而那笔钱是真花掉的。
#   · audit_log  —— 同上，审计记录的**存在**比记录里那个人的存在更重要。
#   · consent_log —— 「他同意过用户须知」这件事不因为销号而没发生过。
#   · forum_threads / forum_posts —— 公开贡献。删了会让别人的回复悬空
#                   （reply_to 指向一条不存在的帖子）。作者名保留原文，
#                   界面上显示成已注销用户。
#   · envs（conda 环境）—— **不是按账号分的**：envs_root 下是所有账号共享
#                   的一套环境（`dsapp_env_path(name, cfg)` 只按名字拼，
#                   没有任何 owner 概念）。删号时连它一起删 = 把别人正在用
#                   的环境删掉。这一条和当初计划里"他建的 conda 环境"那句
#                   假设相反，是照着代码改的。
.dsapp_user_tables <- c("sessions", "login_sessions", "skill_order",
                        "mail_queue", "ssh_nodes", "user_api_keys",
                        "user_proxy", "lit_subs", "skills")

#' 一个账号名下还剩多少东西（只读；给管理页和"删干净了没有"用）
#'
#' 返回命名整数向量，名字是表名 / `files_dir`。查不到的表按 0 算
#' （老库上没有的表不该让这条函数炸）。
dsapp_user_residue <- function(id, email = NULL, cfg = dsapp_config(),
                               con = dsapp_db()) {
  id <- as.integer(id)
  out <- stats::setNames(integer(length(.dsapp_user_tables) + 2L),
                         c(.dsapp_user_tables, "forum_marks", "files_dir"))
  for (t in .dsapp_user_tables) {
    out[[t]] <- tryCatch(
      DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s WHERE user_id = ?", t),
                      params = list(id))$n,
      error = function(e) 0L)
  }
  # session_share 有**两个**账号列：user_id 是被分享的人，granted_by 是分享
  # 出去的人。只按 user_id 数的话，他分享给别人的那些记录一条都看不见。
  out[["session_share"]] <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT COUNT(*) n FROM session_share WHERE user_id = ? OR granted_by = ?",
      params = list(id, id))$n, error = function(e) 0L)
  if (!is.null(email) && length(email) == 1L && !is.na(email) && nzchar(email)) {
    out[["forum_marks"]] <- tryCatch(
      DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM forum_marks WHERE user_email = ?",
                      params = list(email))$n, error = function(e) 0L)
  }
  d <- dsapp_files_root(id, cfg)
  out[["files_dir"]] <- if (dir.exists(d)) length(list.files(d, recursive = TRUE)) else 0L
  out
}

#' 把这个账号名下的东西全清掉
#'
#' 不动 users 行本身（那一步由 `dsapp_user_delete()` 最后做），也不动
#' 上面那段注释里列出的"故意留着"的表。
dsapp_user_purge <- function(id, email = NULL, cfg = dsapp_config(),
                             con = dsapp_db()) {
  id <- as.integer(id)
  if (length(id) != 1L || is.na(id)) return(invisible(FALSE))

  # ★★ 他那些技能的 id 要在**删之前**取出来。反过来的话下一段拿到的是空集，
  #    于是 skill_files 里几 MB 的正文**永久残留**（那两张关联表都没有
  #    指向 skills 的外键，本体删了它们不会跟着走），而且一声不响。
  sids <- tryCatch(
    DBI::dbGetQuery(con, "SELECT id FROM skills WHERE user_id = ?",
                    params = list(id))$id,
    error = function(e) integer(0))

  for (t in .dsapp_user_tables) {
    try(DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE user_id = ?", t),
                       params = list(id)), silent = TRUE)
  }
  # 挂载和配套文件（用上面先取好的 id 清单）
  if (length(sids)) {
    ph <- paste(rep("?", length(sids)), collapse = ",")
    try(DBI::dbExecute(con,
        sprintf("DELETE FROM session_skills WHERE skill_id IN (%s)", ph),
        params = as.list(as.integer(sids))), silent = TRUE)
    try(DBI::dbExecute(con,
        sprintf("DELETE FROM skill_files WHERE skill_id IN (%s)", ph),
        params = as.list(as.integer(sids))), silent = TRUE)
  }
  try(DBI::dbExecute(con,
      "DELETE FROM session_share WHERE user_id = ? OR granted_by = ?",
      params = list(id, id)), silent = TRUE)
  if (!is.null(email) && length(email) == 1L && !is.na(email) && nzchar(email)) {
    try(DBI::dbExecute(con, "DELETE FROM forum_marks WHERE user_email = ?",
                       params = list(email)), silent = TRUE)
    # login_fail 是按邮箱记的失败计数/锁定。账号都没了还留着的话，
    # 同一个邮箱**重新注册**之后会发现自己一开始就被锁着。
    try(DBI::dbExecute(con, "DELETE FROM login_fail WHERE email = ?",
                       params = list(email)), silent = TRUE)
  }

  # ★★★ 盘上那个目录。这就是用户看到「文件进了共享区」的那个根因：
  #     老版本只删 file_owner 的行，而 dsapp_files_sync_owners() 下次
  #     扫到 u<N> 还会把里面的文件补登记回来。
  d <- dsapp_files_root(id, cfg)
  # ⚠️⚠️ 删之前死认一遍目录形状。dsapp_files_root() 对 NA 会给
  #    `files_root/_anon`，对别的意外输入也可能给到父目录 ——
  #    真删错的话是**不可逆**的（recursive = TRUE）。
  if (grepl("^u[0-9]+$", basename(d)) && dir.exists(d)) {
    unlink(d, recursive = TRUE, force = TRUE)
  }
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# 孤儿管理区（有 u<N> 目录、没有对应的 users 行）
# ---------------------------------------------------------------------------

#' 列出盘上没有主人的管理区目录
#'
#' 删号删干净之后这里应该是空的。**历史遗留**（V16.6 之前删过的号）会在
#' 这儿露出来 —— 而那些正是"进了共享区"的那批文件。
dsapp_files_orphans <- function(cfg = dsapp_config(), con = dsapp_db()) {
  empty <- data.frame(uid = integer(), path = character(),
                      n_files = integer(), size_mb = numeric(),
                      stringsAsFactors = FALSE)
  base <- cfg$files_root %||% file.path(cfg$data_root, "files")
  dirs <- tryCatch({
    d <- list.files(base, pattern = "^u[0-9]+$", full.names = TRUE)
    d[dir.exists(d)]
  }, error = function(e) character(0))
  if (!length(dirs)) return(empty)
  uids <- suppressWarnings(as.integer(sub("^u", "", basename(dirs))))
  live <- tryCatch(DBI::dbGetQuery(con, "SELECT id FROM users")$id,
                   error = function(e) integer(0))
  orphan <- which(!is.na(uids) & !(uids %in% as.integer(live)))
  if (!length(orphan)) return(empty)
  rows <- lapply(orphan, function(i) {
    f <- list.files(dirs[i], recursive = TRUE, all.files = TRUE,
                    full.names = TRUE, no.. = TRUE)
    f <- f[!dir.exists(f)]
    sz <- sum(as.numeric(file.size(f)), na.rm = TRUE)
    data.frame(uid = uids[i], path = dirs[i], n_files = length(f),
               size_mb = round(sz / 1024^2, 2), stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

#' 清掉指定的几个孤儿管理区
#'
#' `uids` 由调用方给（管理页上是管理员勾的），这里再对着
#' `dsapp_files_orphans()` 复核一遍 —— 界面传上来的东西一律不信：
#' 万一传进来一个**活着的** uid，删掉的就是别人的文件。
dsapp_files_orphans_purge <- function(uids, cfg = dsapp_config(), con = dsapp_db()) {
  or <- dsapp_files_orphans(cfg = cfg, con = con)
  want <- intersect(as.integer(uids), or$uid)
  if (!length(want)) return(0L)
  n <- 0L
  for (i in want) {
    p <- or$path[match(i, or$uid)]
    # 同上：只认 u<N> 这个形状
    if (grepl("^u[0-9]+$", basename(p)) && dir.exists(p)) {
      unlink(p, recursive = TRUE, force = TRUE)
      if (dir.exists(p)) next
      n <- n + 1L
      # ★★★ V16.6 item 3：归属行**也要清**。只 unlink 的话，`file_owner`
      #     里那几行会永远留着，而管理页的「文件归属」卡是 `SELECT ... FROM
      #     file_owner`（不碰盘），于是清完之后那一行**照样列在那里** ——
      #     指向一个已经不存在的文件。实测：探针 ② 红了，报的正是
      #     `left_behind.csv u990001` 还在页面上，而盘上那个目录已经没了。
      #     这就是用户报的「进了共享区」的**另一半**：老版本只删行不删目录，
      #     这次补了删目录，但反方向的残留（删目录不删行）当时没堵上。
      #
      # ⚠️ 按 `user_id = i` **或** 前缀两条一起删，不能只删前者：
      #    补登记写的行 user_id 是数字 uid，而 V13 之前手工划过来的那些行
      #    user_id 可能是 NULL、前缀却还是 u<i>/ —— 只按 user_id 删会漏掉
      #    后者，而漏掉的那几行照样出现在清单里（同一个症状，换了个来源）。
      try(DBI::dbExecute(con,
        "DELETE FROM file_owner WHERE user_id = ? OR name LIKE ?",
        params = list(i, paste0(dsapp_owner_key("", i), "%"))), silent = TRUE)
    }
  }
  n
}

# ---- 归属 ------------------------------------------------------------------

#' 某个账号能看到的对话 id
#'
#' 全应用只有这一处定义"谁看得见哪些对话"，其他模块都从它取 ——
#' 分散写 SQL 的话，漏掉一处就是一次越权。
dsapp_user_session_ids <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(character(0))
  }
  tryCatch(
    DBI::dbGetQuery(con, "SELECT id FROM sessions WHERE user_id = ? ORDER BY id",
                    params = list(as.integer(user_id)))$id,
    error = function(e) character(0))
}

# ★★ V13 item 6：file_owner.name 从"相对管理区的路径"变成了
#    **"u<账号>/相对路径"**。这一改是必须的，不是洁癖：
#
#    file_owner 的主键是 name（唯一索引），而管理区按账号拆开之后，
#    「asv_table.csv」这种名字在**每个**账号的管理区里都会出现 ——
#    甲传了一个，乙也传了一个，两条记录撞同一个主键，后写的覆盖先写的。
#    后果不是显示错乱那么轻：dsapp_file_can_edit 拿归属判"能不能删"，
#    乙的文件归属行被甲的覆盖之后，乙**删不掉自己的文件**（界面上写着
#    「归属：甲」），而甲那边看到的归属也是错的。
#
#    前缀里的账号就是管理区目录名的那个账号，两边一一对应，
#    出问题时 `ls data/files/u3/` 和 `SELECT * FROM file_owner WHERE
#    name LIKE 'u3/%'` 能直接对起来。
dsapp_owner_key <- function(name, user_id) {
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  seg <- if (length(uid) != 1L || is.na(uid)) "_anon" else sprintf("u%d", uid)
  paste0(seg, "/", name)
}

#' 文件归属（user id）；没有记录时 NA
#'
#' ⚠️ `con` **必须排在 user_id 前面**。原来的签名是 (name, con)，全项目
#'    几十处是按位置调的 `dsapp_file_owner(x, con)`；把 user_id 插在中间
#'    之后，那些调用会把一个 DBI 连接当成账号传进来 —— 不报错，只是
#'    as.integer(connection) 给个 NA，于是查的是 `_anon/` 那一段，永远
#'    查不到，永远返回 NA（"无主"），而"无主"在 can_edit 那里意味着**人人
#'    可删**。一条签名顺序就能把权限判断整个架空，而且测试全绿。
#'
#' @param user_id **哪个账号的管理区**。传 NULL 表示"不知道是谁的"，
#'   这时查的是 `_anon/` 那一段 —— 正常不会命中任何东西，返回 NA。
dsapp_file_owner <- function(name, con = dsapp_db(), user_id = NULL) {
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT user_id FROM file_owner WHERE name = ?",
    params = list(dsapp_owner_key(name, user_id))),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NA_integer_)
  as.integer(d$user_id[[1]])
}

dsapp_file_owner_set <- function(name, user_id, con = dsapp_db()) {
  if (is.null(name) || !nzchar(name)) return(invisible(FALSE))

  # ★ V13.10 item 2：**没有账号就不写**。
  #
  #   用户的原话：「每个用户生成的文件都归自己所有，为什么会产生无归属
  #   文件？」—— 这一行就是那个"无归属"的产地。
  #
  #   原来的行为是：user_id 为 NULL/NA 时照样写一行，键是 `_anon/<name>`、
  #   归属人是 NA。而 `_anon` 目录按设计**永远是空的**（见 config.R 的
  #   dsapp_files_root：它是"没有账号"时的占位，真实文件不可能落在那里）。
  #   所以这一行写下去，指向的是一个**物理上不存在**的文件，而它在管理页
  #   读起来是"有一批老文件没人认领，谁都能删"。
  #
  #   ⚠️ 沉默返回 FALSE 而不是抛错：四个调用点都在 try() 里（上传、发布、
  #      建目录、产物同步），报错会被吞掉，而这里"没写"本来就是正确行为。
  #      但**返回值要能区分**——排查"文件显示成公共"时，这一条是第一个要
  #      看的判据。
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(invisible(FALSE))

  # 前缀用的账号和归属人**是同一个**（文件在谁的管理区里就归谁）。
  # 这两者分开传的话迟早会出现"文件在 u3 里、归属行写着 u5/"，
  # 而那意味着 5 号账号能删 3 号账号的文件 —— 所以只收一个参数。
  try(DBI::dbExecute(con,
    "INSERT INTO file_owner (name, user_id, created_at) VALUES (?, ?, ?)
     ON CONFLICT(name) DO UPDATE SET user_id = excluded.user_id",
    params = list(dsapp_owner_key(name, uid), uid, dsapp_now())),
    silent = TRUE)
  invisible(TRUE)
}

dsapp_file_owner_drop <- function(name, con = dsapp_db(), user_id = NULL) {
  try(DBI::dbExecute(con, "DELETE FROM file_owner WHERE name = ?",
                     params = list(dsapp_owner_key(name, user_id))), silent = TRUE)
  invisible(TRUE)
}

#' 改名 / 移动之后，归属记录跟着走
#'
#' 共享区有子目录之后，"改名"和"移动"在归属表里表现为**前缀变了**：
#' 移动一个文件夹，里面每个文件的行都要一起搬。只改文件夹自己那一行的话，
#' 里面的文件会突然变成"无主"——而按 dsapp_file_can_edit 的规则，
#' 无主 = 人人可删。
#'
#' ⚠️ 用 `substr` 精确切前缀而不是 `LIKE 'old/%'`：
#'    LIKE 里 `_` 匹配任意单字符、`%` 匹配任意串，而路径里这两个字符
#'    都可能出现（`my_data` 这种名字很常见）。转义它们要写 ESCAPE 子句，
#'    容易漏；在 R 里切完再逐条更新反而更直白，而且文件数是个位到百位级。
dsapp_file_owner_move <- function(from, to, con = dsapp_db(), user_id = NULL) {
  if (is.null(from) || !nzchar(from) || identical(from, to)) {
    return(invisible(0L))
  }
  # ⚠️ 只在**这个账号的**前缀里找。不带前缀扫全表的话，甲把 `data` 改名成
  #    `raw_data` 会把乙管理区里同名的 `data` 也一起改掉 —— 乙的文件归属
  #    行凭空消失，变成"无主"，而按 dsapp_file_can_edit 的规则无主=人人可删。
  pfx <- dsapp_owner_key("", user_id)          # 形如 "u3/"
  rows <- tryCatch(DBI::dbGetQuery(con,
    "SELECT name FROM file_owner WHERE substr(name, 1, ?) = ?",
    params = list(nchar(pfx), pfx))$name,
    error = function(e) character(0))
  if (!length(rows)) return(invisible(0L))
  # 上面查出来的已经带前缀了，下面做前缀运算时要按"去掉前缀的相对路径"来，
  # 所以先把它剥掉，算完再装回去。
  rel <- substring(rows, nchar(pfx) + 1L)
  from_k <- dsapp_owner_key(from, user_id)
  to_k   <- dsapp_owner_key(to, user_id)
  from <- from_k; to <- to_k
  rows <- paste0(pfx, rel)

  hit <- rows == from | startsWith(rows, paste0(from, "/"))
  if (!any(hit)) return(invisible(0L))
  new <- paste0(to, substr(rows[hit], nchar(from) + 1L, nchar(rows[hit])))

  # 一条 UPDATE 一条 CASE，别在循环里逐条打库 —— 移动一个几百个文件的
  # 目录会变成几百次写事务，中途失败就只搬了一半。
  try(DBI::dbExecute(con, sprintf(
    "UPDATE file_owner SET name = CASE name %s END WHERE name IN (%s)",
    paste(sprintf("WHEN %s THEN %s",
                  DBI::dbQuoteString(con, rows[hit]),
                  DBI::dbQuoteString(con, new)), collapse = " "),
    paste(DBI::dbQuoteString(con, rows[hit]), collapse = ","))), silent = TRUE)
  invisible(sum(hit))
}

#' 能否动这个文件（改名 / 删除）
#'
#' 规则：自己的随便动；无主的（V5 之前上传的）人人可动 —— 它们本来就没有
#' 归属，锁死会让老部署里堆积的文件谁都清不掉；别人的只有管理员能动。
#'
#' ⚠️ V13.8 item 1 起这里的"管理员"收窄成**平台**管理员。项目管理员的
#'    范围是"自己分发出去的任务、组内的账号成员"，文件不在里面 ——
#'    给他全平台文件的改名/删除权，等于他随手一下就能弄坏别人脚本里
#'    引用的文件名，而那不是任何人在"项目"这个尺度上管得着的事。
dsapp_file_can_edit <- function(name, user, con = dsapp_db()) {
  if (is.null(user)) return(FALSE)
  # 平台管理员照旧随便动（他本来就能看到所有管理区）。
  if (dsapp_user_is_platform_admin(user)) return(TRUE)
  owner <- dsapp_file_owner(name, user$id, con)
  if (is.na(owner)) return(TRUE)
  identical(owner, as.integer(user$id))
}

# ---- 统计（管理页用）-------------------------------------------------------

#' 一次 du 量一批目录
#'
#' @return 数值向量，名字是目录的 basename；量不到的记 NA
#'
#' ⚠️ 一次把**所有**目录传给 du，不要 for 循环一个一个量。
#'    生信的工作区里动辄几万个小文件，`du` 每次都要重新走一遍目录树；
#'    一个用户二十个对话就是二十次全盘遍历，管理页每 10 秒刷一次 ——
#'    量磁盘这件事本身能把机器拖垮。传一批进去，du 内部只遍历一次。
dsapp_dir_sizes <- function(roots) {
  roots <- roots[!is.na(roots) & nzchar(roots)]
  if (!length(roots)) return(numeric(0))
  roots <- roots[dir.exists(roots)]
  if (!length(roots)) return(numeric(0))

  # ★ V16.6 item 5：改走公共的跨平台实现（R/utils.R 的 dsapp_du_bytes）。
  #   原来这里自己拼 `du -sb`，两个毛病：
  #     ① `-b` 是 GNU 的，macOS 上整批回 NA（占用量全显示「—」，不报错）；
  #     ② 按 basename 把结果对回 roots，两个同名目录就**静默错配**
  #        （张冠李戴，而数字看着完全合理）。
  #   ⚠️ 仍然是**一次 du 量一批**（函数签名收向量），这条性能约束见上面
  #      那段说明 —— 别改成逐个调。
  bytes <- dsapp_du_bytes(roots)
  stats::setNames(bytes, basename(roots))
}

#' 每个账号占了多少磁盘
#'
#' 分三块加起来：对话工作区、对话专属 conda 环境、他发布到共享区的文件。
#'
#' ⚠️ 这是**估算**，不是配额，也不需要准到字节：
#'    目的是回答"磁盘满了，先找谁" —— 差几 MB 不影响这个判断。
#'    所以环境那部分只认 `chat-<sid>` 这种应用自己建的目录；用户手工用
#'    conda 建的共享环境算不到任何一个人头上（它们本来也不属于某个人）。
#'
#' @return data.frame(user_id, bytes, n_chat)
dsapp_user_disk_usage <- function(cfg = dsapp_config(), con = dsapp_db()) {
  sess <- tryCatch(DBI::dbGetQuery(con, "SELECT id, user_id FROM sessions"),
                   error = function(e) NULL)
  if (is.null(sess) || nrow(sess) == 0) {
    return(data.frame(user_id = integer(0), bytes = numeric(0), n_chat = integer(0)))
  }

  ws_names  <- dsapp_ws_name(sess$id)
  ws_bytes  <- dsapp_dir_sizes(file.path(cfg$ws_root, ws_names))
  env_bytes <- dsapp_dir_sizes(file.path(cfg$envs_root, ws_names))

  # 名字对不上的记 0：目录还没建（这个对话一次都没跑过）本来就该算 0。
  #
  # ⚠️ 长度必须显式对齐，不能指望 `v[nms]` 一定还你 length(nms) 个值。
  #    一个都没量到时 `numeric(0)[nms]` 返回的是**一个** NA，不是一列 NA；
  #    这一列再进 data.frame(user_id = <n 个>, bytes = <1 个>)，R 不报错，
  #    而是把那一个值循环填满整列 —— 页面照常显示，数字全错。
  pick <- function(v, nms) {
    out <- as.numeric(v[nms])
    out[is.na(out)] <- 0
    if (length(out) != length(nms)) out <- rep(0, length(nms))
    out
  }
  per_sess <- pick(ws_bytes, ws_names) + pick(env_bytes, ws_names)

  df <- data.frame(user_id = suppressWarnings(as.integer(sess$user_id)),
                   bytes = per_sess, stringsAsFactors = FALSE)

  # 共享区里归他的文件
  fo <- tryCatch(DBI::dbGetQuery(con, "SELECT name, user_id FROM file_owner"),
                 error = function(e) NULL)

  # 只算**还存在**的账号。dsapp_user_delete 会清掉 file_owner 里他的行，
  # 但那是两条语句，中间断掉（进程被杀、库锁超时）就会留下指向已删 id 的行。
  # 照单全收的话管理页会多出一行查不到名字的"幽灵账号"：占着磁盘、点不开、
  # 也删不掉。宁可漏算也先不显示 —— 磁盘统计差几 MB 无所谓，幽灵行会让人
  # 以为系统坏了。
  if (!is.null(fo) && nrow(fo) > 0) {
    alive <- tryCatch(DBI::dbGetQuery(con, "SELECT id FROM users")$id,
                      error = function(e) NULL)
    if (!is.null(alive)) {
      fo <- fo[!is.na(fo$user_id) & fo$user_id %in% as.integer(alive), ,
               drop = FALSE]
    }
  }
  if (!is.null(fo) && nrow(fo) > 0) {
    # ★ V13 item 6：`fo$name` 是相对**某个账号的**管理区根的路径，而每个
    #   账号的根不一样 —— 所以不能一个 cfg$files_dir 拼到底。按归属人逐个
    #   解析；归属人认不出来（NULL / 已删账号）的行直接跳过，反正那些文件
    #   现在也落在某一个 u<N>/ 里，会被那个账号自己那次统计数到。
    sz <- vapply(seq_len(nrow(fo)), function(i) {
      uid <- suppressWarnings(as.integer(fo$user_id[i]))
      if (is.na(uid)) return(0)
      # ⚠️ 去掉 `u<N>/` 前缀再拼：fo$name 现在是 `u3/16S分析/asv.csv`，
      #    而 dsapp_files_root(uid) 已经是 .../u3 了。不去前缀就会拼成
      #    .../u3/u3/16S分析/asv.csv —— 文件不存在，file.size 给 NA，
      #    静默算成 0 字节。整个管理区的配额统计会一直是 0。
      rel <- sub("^[^/]*/", "", fo$name[i])
      p <- file.path(dsapp_files_root(uid, cfg), rel)
      s <- suppressWarnings(file.size(p))
      if (is.na(s)) 0 else as.numeric(s)
    }, numeric(1))
    df <- rbind(df, data.frame(user_id = suppressWarnings(as.integer(fo$user_id)),
                               bytes = as.numeric(sz), stringsAsFactors = FALSE))
  }

  df <- df[!is.na(df$user_id), , drop = FALSE]
  if (nrow(df) == 0) {
    return(data.frame(user_id = integer(0), bytes = numeric(0), n_chat = integer(0)))
  }
  agg <- stats::aggregate(bytes ~ user_id, data = df, FUN = sum)
  nch <- stats::aggregate(bytes ~ user_id, data = df, FUN = length)
  names(nch)[2] <- "n_items"
  merge(agg, nch, by = "user_id", all.x = TRUE)
}

# ---- 配额 ------------------------------------------------------------------

DSAPP_GB <- 1024^3

#' 某个账号的配额（字节）
#'
#' @return 数值；**0 表示不限**（和数据库里 NULL/0 的含义一致，也和 Python 版
#'   的 user_quota_gb 一致）。调用方必须先判断 `> 0` 再比大小 ——
#'   把 0 当成"一个字节都不许用"会让所有没设配额的账号立刻写不进任何东西。
dsapp_user_quota_bytes <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(0)
  v <- tryCatch(DBI::dbGetQuery(con,
    "SELECT quota_gb FROM users WHERE id = ?",
    params = list(as.integer(user_id)))$quota_gb, error = function(e) NULL)
  if (is.null(v) || !length(v) || is.na(v[[1]])) return(0)
  gb <- suppressWarnings(as.numeric(v[[1]]))
  if (is.na(gb) || gb <= 0) return(0)
  gb * DSAPP_GB
}

#' 设置配额
#'
#' @param gb 0 或负数 = 不限。上限 1e6 GB，纯粹是挡手滑多敲几个零 ——
#'   一个把配额设成 1e15 的管理员不会得到任何保护，只会得到一个看起来
#'   设过了的错觉。
dsapp_user_set_quota <- function(id, gb, con = dsapp_db()) {
  gb <- suppressWarnings(as.numeric(gb))
  if (is.na(gb) || gb < 0) gb <- 0
  if (gb > 1e6) gb <- 1e6
  DBI::dbExecute(con, "UPDATE users SET quota_gb = ? WHERE id = ?",
                 params = list(if (gb == 0) NA_real_ else gb, as.integer(id)))
  invisible(gb)
}

#' 一个账号现在占了多少（字节）
#'
#' 三块加起来，和 dsapp_user_disk_usage 用的是同一套口径：
#'   对话工作区 + 对话专属 conda 环境 + 他发布到共享区的文件。
#'
#' ⚠️ **和 dsapp_user_disk_usage 必须口径一致**。管理页显示"用了 80 G"、
#'    而这里算出来 100 G 把上传挡掉，用户会看到一个自相矛盾的界面，
#'    然后合理地认为系统坏了。改任何一边都要改另一边 —— 所以这里直接
#'    复用同一个函数，而不是另写一段 SQL。
#'
#' @return 数值（字节）；量不到的部分按 0 计
dsapp_quota_used <- function(user_id, cfg = dsapp_config(), con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) return(0)
  uid <- as.integer(user_id)
  u <- tryCatch(dsapp_user_disk_usage(cfg, con), error = function(e) NULL)
  if (is.null(u) || nrow(u) == 0) return(0)
  hit <- which(as.integer(u$user_id) == uid)
  if (!length(hit)) return(0)
  as.numeric(u$bytes[[hit[[1]]]] %||% 0)
}

#' 还能不能再写 incoming 这么多字节
#'
#' @return list(ok, used, quota, msg)。ok = TRUE 时 msg 是 ""。
#'
#' 给三个写入点用：上传落盘、压缩包解压、开始执行。**这三处是全部**，
#' 漏掉任何一处，配额就只是文件页上的一个装饰。
dsapp_quota_check <- function(user_id, incoming = 0, what = "这次操作",
                              cfg = dsapp_config(), con = dsapp_db()) {
  quota <- dsapp_user_quota_bytes(user_id, con)
  if (quota <= 0) {
    return(list(ok = TRUE, used = 0, quota = 0, msg = ""))
  }
  used <- dsapp_quota_used(user_id, cfg, con)
  incoming <- max(0, as.numeric(incoming %||% 0))

  if (used + incoming <= quota) {
    return(list(ok = TRUE, used = used, quota = quota, msg = ""))
  }

  # 提示里要说清三件事：现在用了多少、上限多少、怎么办。
  # 只说"空间不足"会让人以为磁盘满了 —— 而磁盘是管理员的事，
  # 配额是他自己的事，两者要采取的行动完全不同。
  list(ok = FALSE, used = used, quota = quota,
       msg = sprintf(
         "已达到你的存储配额：已用 %s / 上限 %s，%s还需要 %s。%s",
         dsapp_fmt_bytes(used), dsapp_fmt_bytes(quota), what,
         dsapp_fmt_bytes(incoming),
         if (incoming > 0 && used + incoming > quota && used < quota)
           "请先删掉一些不用的对话或共享区文件再试。"
         else "已经在配额之上了，请先删掉一些不用的对话或共享区文件。"))
}

#' 配额用量条（文件页 / 设置页显示用）
#'
#' @return NULL 表示不限（**不显示比显示一条满格的空条好** —— 不限配额的
#'   用户看到一个条只会以为自己也快满了）
dsapp_quota_bar <- function(user_id, cfg = dsapp_config(), con = dsapp_db()) {
  quota <- dsapp_user_quota_bytes(user_id, con)
  if (quota <= 0) return(NULL)
  used <- dsapp_quota_used(user_id, cfg, con)
  pct <- min(100, round(100 * used / quota))
  list(used = used, quota = quota, pct = pct,
       over = used >= quota,
       near = pct >= 85)
}

dsapp_platform_stats <- function(cfg = dsapp_config(), con = dsapp_db()) {
  q1 <- function(sql) tryCatch(DBI::dbGetQuery(con, sql)[[1]][[1]],
                               error = function(e) NA)
  dir_size <- function(d) {
    if (is.null(d) || is.na(d) || !dir.exists(d)) return(0)
    # ★ V16.6 item 5：走公共实现（原来是第四份自己拼的 `du -sb`，
    # macOS 上没有 -b → 平台统计里的磁盘占用永远是「—」）
    dsapp_du_bytes(d)[[1]]
  }

  ws <- tryCatch(DBI::dbGetQuery(con,
    "SELECT id, user_id FROM sessions"), error = function(e) NULL)

  list(
    n_users    = q1("SELECT COUNT(*) FROM users"),
    n_active   = q1("SELECT COUNT(*) FROM users WHERE status = 'active'"),
    n_chat     = q1("SELECT COUNT(*) FROM sessions"),
    n_msg      = q1("SELECT COUNT(*) FROM messages"),
    n_task     = q1("SELECT COUNT(*) FROM tasks"),
    n_task_ok  = q1("SELECT COUNT(*) FROM tasks WHERE status = 'success'"),
    n_task_err = q1("SELECT COUNT(*) FROM tasks WHERE status IN ('error','failed','timeout')"),
    # ★ V13 item 6：管理区按账号分了，统计要把**所有**账号的加起来。
    #   用 cfg$files_dir 的话数到的是 _anon（空的），管理页上会显示"0 个文件"，
    #   而磁盘上明明有东西 —— 这种"统计说没有、实际有"最难被发现。
    n_files    = sum(vapply(dsapp_files_all_roots(cfg), function(d)
                     length(list.files(d, all.files = FALSE, no.. = TRUE)),
                     integer(1)), 0L),
    bytes_ws    = dir_size(cfg$ws_root),
    bytes_files = sum(vapply(dsapp_files_all_roots(cfg), dir_size, numeric(1)), 0),
    bytes_envs  = dir_size(cfg$envs_root),
    bytes_data  = dir_size(cfg$data_root),
    # token 用量（V5）。和磁盘不一样，这个**不来自 du** —— 它在库里，
    # 是每一轮生成发生时写下的原始数字，所以不会因为工作区被删而失真。
    tokens_total = q1("SELECT COALESCE(SUM(COALESCE(total_tokens,0)),0)
                       FROM usage_log"),
    n_llm        = q1("SELECT COUNT(*) FROM usage_log")
  )
}
