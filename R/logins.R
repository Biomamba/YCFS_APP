# =============================================================================
# 单端登录（V11 item 4b）
# =============================================================================
# 用户的原话：「注意同一个账号不允许多端登录，否则会出现异步bug」。
#
# 先把"异步 bug"是什么说清楚，因为**这一条决定了实现该长什么样**：
#
#   本站一个应用一个 R 进程（Shiny Server 开源版），所有访客共用。但**会话
#   是分开的** —— 每个浏览器连接有自己的 server() 实例、自己的模块状态
#   （st$agent、rv$session_id、文件页的选中项……）。同一个账号开两个端，就是
#   在同一个工作区上跑两套互不知情的状态机：
#     · 甲端开始自动执行循环，乙端同时删掉那个对话 → chdir 到一个已经不在的
#       目录，或者把结果写回一个已删的会话；
#     · 两端各自持有一份"当前正在跑的任务"，而引擎是**全局单槽**的
#       （见 R/jobs.R），乙端提交时把甲端那个任务的状态覆盖掉；
#     · 配额、环境构建锁、并发上限都是按账号算的，两个端各算各的。
#   这些都不是"数据脏一点"，是**跑到一半的行为不可预测** —— 所以要求是
#   "同一时刻只允许一个端在用"。
#
# 做成什么：
#   users 表多一行 login_sessions，**一个账号一行**（user_id 就是主键）。
#   谁最后登录谁写这一行；别的端在下一次心跳（≤15 秒）发现自己手里那个
#   nonce 已经不是当前那一行了，就被判"已被顶下线"，整页换成提示页。
#
# ⚠️⚠️ 为什么 nonce 是**拼在原来那个 cookie 值里**（`<token>.<nonce>`），
#     而不是另开一个 cookie：
#
#     2026-09-13 那次线上事故就是"浏览器里跑的是缓存下来的旧 app.js"——
#     旧 JS 不认识新 cookie，回执永远不来，用户反复被弹回登录页，而服务端
#     日志干干净净（app.R 里那段长注释记着）。**再加一个 cookie 等于再开一条
#     同类的路**：任何一个跑着旧 JS 的浏览器都会变成"能登录、但一刷新就掉"。
#     拼进现有 cookie 值里就不存在这个问题 —— 旧 JS 只会把服务端给它的那串
#     字符串原样写回去、原样送回来，位对位，它不需要知道里面有几个部分。
#     解析、比对、判归属全部在服务端。
#
# ⚠️ cookie 值里的 `.` 不会和 token 本身撞：dsapp_token() 生成的是纯十六进制
#    （见 R/users.R），不含点。老 cookie（没有点）会被当成 "nonce 为空"，
#    走"认领"这条路 —— 那正是升级那一刻该发生的事（V11 之前登录的端会在
#    下一次加载时认领这一行，而不是被自己的空 nonce 判死）。
#
# ⚠️ 这张表**不是身份凭证的来源**。凭它进不来：认人一如既往靠 users.token
#    （见 dsapp_user_by_token）。它只回答"这个 token 的持有者是不是当前那一个
#    端"，所以被清空、被删掉都只是"大家都重新认领一次"，不会把人锁在外面。
# =============================================================================

# 心跳间隔（毫秒）。给 app.R 的心跳观察者用。
#
# ⚠️ 这个数只影响"被顶下线之后多久才发现"，不影响正确性 —— 所以可以取得
#    比较宽松。反过来，取得太小是**真花钱**的：每个登录着的端每 N 毫秒查
#    一次库，而所有访客共用同一个 R 进程，这个查询是串行的。15 秒够用了。
#
# DSAPP_LOGIN_POLL_MS 是给**浏览器回归测试**留的口子：测试要验的是"乙端登录
# 之后甲端会被踢下来"，15 秒一次的心跳会让每条断言都干等 15 秒以上，一个
# 用例跑一分钟，跑两次就没人愿意跑了。下限钉在 1 秒 —— 再小就没有心跳的
# 意思了，纯粹是无谓的轮询。生产上不设这个变量，走下面那个默认值。
DSAPP_LOGIN_POLL_MS <- local({
  v <- suppressWarnings(as.integer(Sys.getenv("DSAPP_LOGIN_POLL_MS", "")))
  if (is.na(v) || v < 1000L) 15000L else v
})

# last_seen_at 的写回节流（秒）。心跳每 15 秒一次，每次都写的话就是每个端
# 每分钟 4 次写库 —— 而这一列只是给管理员看"谁还在"的，分钟级足够。
DSAPP_LOGIN_TOUCH_SEC <- 60L

dsapp_db_schema_logins <- function(con) {
  # user_id 直接当主键 = "一个账号一行"，这条约束**写在结构里**而不是写在
  # 代码里：多端并发登录时两个进程同时 INSERT 也不会留下两行（谁后写谁赢）。
  # 靠代码"记得先删再插"的话，中间那一瞬就是两行都在的状态。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS login_sessions (
      user_id      INTEGER PRIMARY KEY,
      nonce        TEXT NOT NULL,
      ip           TEXT NOT NULL DEFAULT '',
      ua           TEXT NOT NULL DEFAULT '',
      created_at   TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    )")
  invisible(TRUE)
}

#' 拆开 cookie 值里的 `<token>.<nonce>`
#'
#' 没有点（V11 之前发出去的 cookie、或者 URL 里的裸令牌）时 nonce 是空串 ——
#' 那表示"这一端还没有认领过"，由调用方决定认领还是拒绝。
#'
#' @return list(token, nonce)
dsapp_login_split <- function(x) {
  x <- as.character(x %||% "")
  if (!nzchar(x)) return(list(token = "", nonce = ""))
  # ⚠️ 从**最后一个**点切，不是第一个：万一以后 token 本身带了点，切的仍然
  #    该是我们拼在最后的那一段。
  i <- regexpr("\\.[^.]*$", x)
  if (i < 0) return(list(token = x, nonce = ""))
  list(token = substr(x, 1L, i - 1L),
       nonce = substring(x, i + 1L))
}

dsapp_login_cookie <- function(user_token, nonce) {
  if (!nzchar(nonce %||% "")) return(as.character(user_token))
  paste0(user_token, ".", nonce)
}

#' 认领这一端：把这一行改成我的 nonce
#'
#' **只有真正登录（或者"这一端本来就是主人"的自动登录）才该调它**，
#' 每次页面加载都调一次的话，两个端会互相顶，永远在重载。
#'
#' @return 新的 nonce
dsapp_login_start <- function(user_id, ip = "", ua = "", con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id))
  if (is.na(uid)) return("")
  nonce <- dsapp_token(16)
  now <- dsapp_now()
  try(DBI::dbExecute(con, "
    INSERT INTO login_sessions (user_id, nonce, ip, ua, created_at, last_seen_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(user_id) DO UPDATE SET
      nonce = excluded.nonce,
      ip = excluded.ip,
      ua = excluded.ua,
      created_at = excluded.created_at,
      last_seen_at = excluded.last_seen_at",
    params = list(uid, nonce, substr(as.character(ip %||% ""), 1, 64),
                  substr(as.character(ua %||% ""), 1, 200), now, now)),
    silent = TRUE)
  nonce
}

#' 这一端还是当前那一端吗
#'
#' 空 nonce 一律判否 —— "没带凭据"和"带对了"必须分开，把空当成放行等于
#' 给了一条绕过单端限制的路（手写一个不带点的 cookie 就行）。
dsapp_login_owns <- function(user_id, nonce, touch = TRUE, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id))
  nonce <- as.character(nonce %||% "")
  if (is.na(uid) || !nzchar(nonce)) return(FALSE)
  row <- tryCatch(DBI::dbGetQuery(con,
    "SELECT nonce, last_seen_at FROM login_sessions WHERE user_id = ?",
    params = list(uid)), error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) {
    # 这一行不在（库被换过 / 管理员清过 / 还在 V10 的库里跑）。判否，
    # 让调用方按"需要重新登录"处理 —— 那是安全的那个方向。
    return(FALSE)
  }
  if (!identical(as.character(row$nonce[[1]]), nonce)) return(FALSE)

  # 心跳顺带记一笔"还活着"，但节流（见 DSAPP_LOGIN_TOUCH_SEC）。
  # 写库失败**不影响判定**：这一列是给人看的，不是判据。
  if (isTRUE(touch)) {
    last <- as.character(row$last_seen_at[[1]] %||% "")
    t0 <- suppressWarnings(as.POSIXct(last, tz = "UTC"))
    if (is.na(t0) ||
        as.numeric(difftime(Sys.time(), t0, units = "secs")) >=
          DSAPP_LOGIN_TOUCH_SEC) {
      try(DBI::dbExecute(con,
        "UPDATE login_sessions SET last_seen_at = ? WHERE user_id = ? AND nonce = ?",
        params = list(dsapp_now(), uid, nonce)), silent = TRUE)
    }
  }
  TRUE
}

#' 退出登录：把这一行让出来
#'
#' ⚠️ 只删**自己那一行**（nonce 也要对上）。不加这个条件的话，"甲退出"会把
#'    乙刚登录写下的那一行删掉，乙下一次心跳就被判下线 —— 而乙什么都没做。
dsapp_login_stop <- function(user_id, nonce, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id))
  nonce <- as.character(nonce %||% "")
  if (is.na(uid) || !nzchar(nonce)) return(invisible(FALSE))
  invisible(tryCatch(DBI::dbExecute(con,
    "DELETE FROM login_sessions WHERE user_id = ? AND nonce = ?",
    params = list(uid, nonce)), error = function(e) 0L))
}

#' 这个账号当前那一端是谁（管理页用）
#'
#' @return NULL 或 list(nonce, ip, ua, created_at, last_seen_at)
dsapp_login_current <- function(user_id, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id))
  if (is.na(uid)) return(NULL)
  d <- tryCatch(DBI::dbGetQuery(con,
    "SELECT * FROM login_sessions WHERE user_id = ?", params = list(uid)),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  as.list(d[1, , drop = FALSE])
}
