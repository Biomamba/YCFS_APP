# ============================================================================
# R/sync.R —— 本地库 ↔ 在线版数据库的增量同步
#
# 用户原话（V13.2 工单 item 2）：「如何解决 exe 和在线版本的数据库统一问题？
# 例如用户信息、任务会话」。
#
# 方案（用户 2026-09-16 拍板）：本地库 + 增量同步；传输复用现有 ssh（scp），
# **不在服务器上加服务、不开端口**；同步凭据**只在这次会话的内存里**，
# 不写库、不落盘（和 R/nodes.R 那条策略一致，那条没有被松动）。
#
# ---------------------------------------------------------------------------
# 一、能同步什么、不能同步什么
# ---------------------------------------------------------------------------
# 能同步的是「**对话**」：
#   · 账号（users 行的**身份部分**）
#   · 会话（sessions）
#   · 消息（messages）
#
# 不能同步的是「**算过的东西**」：
#   · tasks / task_files / ws_published —— 行指向的产物文件只在跑过它的
#     那台机器上。同步一行任务过去，那边点开是空的 —— 比不同步更糟：
#     不同步用户知道"这边没有"，同步了用户以为"东西丢了"。
#   · 环境（envs）—— 是那台机器上真实存在的 conda/venv 目录。
#   · 技能（skills）—— 正文在 data_root 下，且 id 是自增的。
#   · API Key —— 存在 data_root/.keyring 里，**每台机器的钥匙串不同**，
#     密文搬过去解不开（见 R/crypto.R 顶部）。
#   · 工作区文件 —— 体积不可控。
# 逐条论证在仓库根的 SYNC.md 里。
#
# ---------------------------------------------------------------------------
# 二、三个必须绕开的坑（都是 SYNC.md 里先勘察出来的）
# ---------------------------------------------------------------------------
# 1. **主键会撞号。** 库里有 11 张表的主键是 AUTOINCREMENT。同一台机器上
#    第 7 个对话在两边都是 7，直接按 id 覆盖就是把两个不相关的对话合并。
#
#    这里的做法：**不碰任何现有表的 schema**，另开一张 sync_map 做
#    「(来源节点, 来源 id) → 本地 id」的映射。好处是同步这个功能**加不进
#    现有表的任何约束**，最坏情况是同步不生效，而不是把对话数据搞坏。
#
# 2. **全库没有软删除。** 删除是硬 DELETE，删完什么都不剩 —— 对端不知道
#    该删。所以另开一张 sync_tombstone，在 db_session_delete() 那个**唯一
#    的收口**上记一笔（R/db.R 里删会话只有那一个函数，所以不用挂 SQLite
#    触发器；触发器反而会在"应用对端墓碑"时再触发一次，成环）。
#
# 3. **两台机器的钟不一定一样。** 但**每个方向的时间戳都只在发送方那台
#    机器的时钟域里**：A 发给 B 的行带的是 A 的 updated_at，B 只是把它
#    存下来、下次原样回给 A。**接收方从不拿自己的钟去比**，所以偏移不影响
#    正确性。剩下只有"同一秒内写了两行"这一种漏，用一个重叠窗口兜住。
#
# ---------------------------------------------------------------------------
# 三、服务器那边「谁来应用」（SYNC.md §4.4 标了"必须在动手前定"的那条）
# ---------------------------------------------------------------------------
# **没有守护进程，是惰性应用。** 勘察过三条路：
#
#   · `later::later()` 自递归定时器 —— 否决。`later` 在这个仓库里**未声明、
#     零使用**，引入要同时改四处依赖清单（deploy.sh / run_local.R /
#     desktop/build_windows_bundle.sh / desktop/fetch_win_pkgs.R），漏一处
#     就是 Windows 免安装包或线上预检失败；而且回调跑在**主进程的事件循环**
#     里，全站只有一个 R 进程，那里做任何传输/写库都是全站卡顿
#     （R/health.R:26 那段注释骂的就是这个写法）。
#   · `callr` 常驻子进程 —— 可行、零新依赖，但这个仓库里**从来没有常驻
#     进程**（三处 r_bg 全是一次性、都带 supervise=TRUE），而且部署方式是
#     `systemctl restart shiny-server`，常驻进程得额外做存活检查、代码版本
#     检查、pid 兜底。为一个"最多延迟一次页面加载"的需求引入这些，不划算。
#   · **惰性应用（选它）** —— 收件箱在「应用启动时」和「每个会话首个 render
#     之前」各查一次，查的只是一次 list.files，有新包才真干活。
#
# 为什么这样就够了：**服务器上的数据变化，必然是"有人用了网页版"产生的**
# （服务器自己不会凭空写对话）。而"有人用了网页版"就意味着钩子已经跑过。
# 反过来，如果没人开网页版，那也没人在等新数据。所以延迟上界恰好等于
# "下一次有人看" —— 也就是**这件事真正被需要的时刻**。
#
# 桌面那边方向相反：它有会话、有凭据，所以由它主动 push + pull（见
# dsapp_sync_now）。
#
# ---------------------------------------------------------------------------
# 四、为什么同步包是 JSON 而不是 SQLite 文件
# ---------------------------------------------------------------------------
# SYNC.md §4.5 要求「绝不把客户端送来的文件当 SQL 执行」。用 JSON 让这条
# **结构上不可能违反** —— 包里根本没有 SQL 这个种类。而现成的 DBI/RSQLite
# 在读一个外部 SQLite 文件时，虽然只读也算安全，但"打开一个别人给的文件"
# 这件事本身没必要做。JSON 的额外好处是运维能直接 `cat` 它排查问题。
#
# 代价是体积约 2 倍。对话是纯文本，几 MB 的量级，可以接受。
#
# ---------------------------------------------------------------------------
# 五、两边在哪儿碰头（会合目录）
# ---------------------------------------------------------------------------
# 桌面版往**服务器的 data 目录**下传，不是往 `$HOME` 下传：
#
#      <服务器的 data_root>/sync/inbox/          桌面版推上来的包
#      <服务器的 data_root>/sync/outbox/<桌面节点>/  服务器给这个桌面留的回包
#      <服务器的 data_root>/sync/inbox/applied/  已应用的包（留证，出问题能复现）
#
# ⚠️ 为什么不是 `$HOME/.dsapp_sync`（最初就是这么写的，是**错的**）：
#    应用在服务器上跑在 **shiny 用户**下、`$HOME=/home/shiny`，而 ssh 进来
#    的是**另一个用户**（本机是 biomamba，`$HOME=/home/biomamba`）—— 两个
#    $HOME 根本不是同一个目录。照 $HOME 拼的话，桌面版把包推到
#    /home/biomamba/.dsapp_sync/inbox，而应用在 /home/shiny 那边等，
#    **两边永远见不着面，而且谁都不报错**。
#    data_root（.Renviron 里的 DSAPP_DATA_ROOT）是唯一一个"应用要写、
#    桌面版的 ssh 用户也有权限写"的目录：它归部署账号所有，ACL 里同时给了
#    shiny rwx（setfacl，见 deploy_link.sh）。
#
# 代价是这个路径没法自动猜到，得让用户填一次（设置页那个"远端同步目录"）。
# 默认值取 `/srv/shiny-server/YCFS_APP/data/sync` —— shiny-server 的标准部署
# 位置，而且本机就是这么部署的（`/srv/shiny-server/YCFS_APP` 是个软链）。
#
# ---------------------------------------------------------------------------
# 六、每一行都带**造它的那个节点**的身份（防回声 + 允许转发，V13.7 item 7）
# ---------------------------------------------------------------------------
# 每一次同步，包里的会话/消息都带一对 `(origin_node, origin_id)` —— **造出
# 这一行的那个节点**，和它在那台机器上的 id。这是这一行**永久的身份**，
# 它跟着这一行走过每一次转发，永远不变。
#
# 为什么要这样：用户要的是**三个渠道的数据都能在云端合上**（Windows 桌面 /
# 自用 Linux 上的 Shiny / 官网在线），也就是 A 推给服务器、服务器要能再给
# B。而"这一行是谁造的"必须能回答，否则 B 收到之后无从判断"我手上是不是
# 已经有它了"。
#
# ★ 所以防回声的规则**从发送方搬到了接收方**，这是这一版最关键的改动：
#
#   接收方拿到一行时看它的 origin_node：
#     · == 我自己的节点 id → **这一行本来就是我造的**，绕了一圈回来了。
#       origin_id 就是我本地的主键，直接按它找本地那一行（合并，绝不插入）。
#     · 别的节点 → 查 sync_map(origin_node, kind, origin_id) 翻本地 id，
#       翻得到就合并、翻不到才插入。
#
#   为什么放在接收方：**发送方在第一次推的时候根本不知道对端是谁**
#   （服务器的 node id 要等第一个回包才知道）。原来的规则"sync_map 里查得到
#   的一律不发"之所以成立，是因为它**不需要知道对端是谁**；代价是它把
#   "别人给我的"和"我要转给第三方的"当成了同一件事 —— 于是服务器收到了
#   桌面版的东西之后，**再也不会发给第二个桌面版**，云端成了个死胡同。
#
#   V13.3 那版为什么会在 2026-09-16 实测出"对话翻倍"：A 推给 B，B 回推给 A，
#   而 B 回推的那一行带的是 **B 的本地 id** —— 那个 id 在 A 的库里毫无意义，
#   A 认不出来，于是又插了一遍。**问题不是"回推"这个动作，是回推时身份丢了。**
#   现在身份跟着行走，回推的这一行 origin_node 就是 A，A 一眼认出是自己。
#
# ★ 发送方**仍然**做一次筛（dsapp_sync_collect 的 for_node）：明显是对端造
#   的行不发。但那纯粹是省流量，**正确性不靠它** —— 它拿不到 for_node 时
#   （第一次推）就是不过滤，而那样也不会错，只是多传一些对端会自己认出来的行。
#
#   ⚠️ 这个筛只能筛**整个会话都是对端的**那种。消息是按会话取的，会话行一
#      被筛掉，它身上的消息就跟着没了 —— 于是下面那条"顺带修好的旧限制"
#      会被它原样推翻。第一版就是栽在这里，实测表现为 B 补的话回不到 A，
#      而包是"成功"的。
#
# ★ 顺带修好的旧限制：V13.3 记过"从对端收来的对话，在本地接着聊，新聊的
#   那几轮不会回流到对端"。现在会了 —— B 在 A 的对话里接着聊，新消息的
#   origin_node 是 B，推给 A 时 A 翻不出 (B, 消息 id) 就插进那条会话里。
#   而那几条消息推回 B 时，B 认出 origin_node == 自己，不会重复插。

# ---- 常量 ------------------------------------------------------------------

DSAPP_NODE_ID_FILE <- ".node_id"

# 增量窗口的重叠秒数。水位是「已同步到的那个 updated_at」，用 `>` 比较；
# 同一秒内写了两行的话，后一行会落在水位上被漏掉。每次往回退这么多秒重新
# 取一遍 —— 重复取到的行由**幂等 apply** 吸收掉，不会有副作用。
#
# 60 秒足够覆盖"同一秒写入"和"两个进程抢写"，又不会让每轮同步都重传一大堆。
DSAPP_SYNC_OVERLAP_SEC <- 60L

# 单个包最多带多少行。第一次同步会把整个库倒过去，不分页的话一个几百 MB
# 的 JSON 在 scp 和 jsonlite 那儿都很难看。剩下的下一轮继续。
DSAPP_SYNC_MAX_SESSIONS <- 200L
DSAPP_SYNC_MAX_MESSAGES <- 5000L

# 墓碑保留天数。和 audit_log 的 180 天对齐（见 R/gc.R 的 dsapp_gc）。
DSAPP_SYNC_TOMBSTONE_DAYS <- 180L

# 服务器上的同步目录（默认值，用户可以改）。为什么是 data_root/sync 而不是
# $HOME 下的什么位置，见文件头第五节。这个值同时也是"锚点行"键的一部分，
# 所以**改了它等于换了一个同步对象**：水位重新算、数据重传一遍（不会丢，
# 只是慢）。设置页里那栏的说明是这么写的。
DSAPP_SYNC_REMOTE_DIR_DEFAULT <- "/srv/shiny-server/YCFS_APP/data/sync"

# 用户行里**允许过网**的列。
#
# ⚠️ 这是个**白名单**，而且是刻意这么写的。下面这几列**绝对不能**跟着
#    同步包走：
#      · is_admin —— 桌面版能把自己的号提成服务器管理员，这是提权。
#      · status   —— 桌面版能把一个被封的号在服务器上解锁。
#      · token    —— 那是密码盐，跟着走了等于把"下次注册同一个邮箱"的
#                    行为改掉（两台机器注册同一个邮箱会得到不同的盐，
#                    见 dsapp_pw_hash 的说明）。
#      · llm_api_key / *.keyring 相关 —— 每台机器一把钥匙，搬过去解不开。
#      · ui_prefs —— 界面偏好，本来就该各机器各算各的（输出版面宽度是
#                    按屏幕尺寸调的，跟着走反而错）。
#
# ★ V13.7 item 7：**pass_salt / pass_hash 从这个白名单里去掉了**。
#
#   它们原来在这里的理由是"账号身份要跟着走，两边得能算出同一个东西"。
#   但那个理由站不住：两台机器上同一个邮箱的盐是**各自随机**生成的，
#   算出来的 hash 天生不同 —— 它们从来就没能让两边"对上"，只是**过了网**。
#   而接收端当时会拿包里的 hash 去建号（见 .dsapp_sync_user_find 的注释），
#   于是这两个字段的实际作用只剩一个：**给攻击者提供铸号的材料**。
#
#   现在接收端只认不建，这两个字段就彻底没有用途了。让密码散列待在本机、
#   从不过网，是这一版在"私密性"上最实在的一步。
#
#   ⚠️ 同步密钥（R/synckey.R）**不是**这个 hash —— 它是密码在**另一个盐**
#      下算出来的，两边都能现推，但谁都不落盘。别把这两个概念混起来，
#      更别因为"反正有 hash 了"就把 pass_hash 加回这个白名单。
DSAPP_SYNC_USER_COLS <- c("email", "nickname", "phone", "field", "created_at")

# ---- 节点标识 --------------------------------------------------------------
#
# 每台安装一个 id，用来回答"这行是从哪来的"。存成文件而不是库里的表：
# 它必须在**建库之前**就能读到（第一次同步可能发生在库刚建好、什么都还
# 没有的时候），而且它描述的是"这台机器"，不是"这个库文件"——库被换掉/
# 重建之后，这台机器还是这台机器。
#
# 写法照抄 R/crypto.R 的 .keyring：放 data_root 下、权限 0600、进程内缓存。

.dsapp_node_cache <- new.env(parent = emptyenv())

dsapp_sync_node_id_path <- function(cfg = dsapp_config()) {
  file.path(cfg$data_root, DSAPP_NODE_ID_FILE)
}

#' 本机的同步节点 id（没有就生成一个）
#'
#' 幂等：文件存在就直接读。文件被删掉的话会重新生成一个新的 —— 那等价于
#' 「这台机器变成了一台新机器」，对端会把它当成新的同步对象（水位重来一遍，
#' 数据不会丢，只是会重传）。
dsapp_sync_node_id <- function(cfg = dsapp_config()) {
  key <- cfg$data_root
  if (!is.null(.dsapp_node_cache[[key]])) return(.dsapp_node_cache[[key]])

  p <- dsapp_sync_node_id_path(cfg)
  id <- ""
  if (file.exists(p)) {
    id <- tryCatch(trimws(paste(readLines(p, warn = FALSE), collapse = "")),
                   error = function(e) "")
    # 只认自己的格式，别把一个被别的东西写坏的文件当成 id 用。
    if (!grepl("^[A-Za-z0-9_-]{8,64}$", id)) id <- ""
  }
  if (!nzchar(id)) {
    id <- paste0("n", dsapp_token(16))
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(p, ".tmp")
    ok <- tryCatch({
      writeLines(id, tmp)
      file.rename(tmp, p)
    }, error = function(e) FALSE)
    if (!isTRUE(ok)) {
      # 写不进去不是致命错误（应用目录只读、磁盘满…）。退回"每次启动一个
      # 新 id"会让同步退化成全量重传，但**不会出错**——比直接抛异常好。
      .dsapp_node_cache[[key]] <- id
      return(id)
    }
    try(Sys.chmod(p, mode = "0600"), silent = TRUE)
  }
  .dsapp_node_cache[[key]] <- id
  id
}

# ---- 目录 ------------------------------------------------------------------

dsapp_sync_root <- function(cfg = dsapp_config()) {
  file.path(cfg$data_root, "sync")
}
dsapp_sync_inbox <- function(cfg = dsapp_config()) {
  file.path(dsapp_sync_root(cfg), "inbox")
}
dsapp_sync_inbox_applied <- function(cfg = dsapp_config()) {
  file.path(dsapp_sync_root(cfg), "inbox", "applied")
}

#' 把归档包里的**认领材料**抹掉（口令校验器不该在盘上过夜）
#'
#' ★ 背景：桌面版第一次往一台服务器推的时候，包里带着一份认领材料
#'   （`claim`，里面是 pass_salt + pass_hash）。服务器应用完这个包会把它
#'   挪进 `inbox/applied/` **原样留档** —— 于是那份口令校验器就永远躺在
#'   盘上了，而且**改了密码它还在**（库里的那一列已经跟着改了）。
#'   本仓对同步临时文件的既有规矩就是"不留过夜"（`sent/`、`applied/`
#'   都有过期清理），口令材料比对话内容更该守这条。
#'
#' ⚠️ 抹掉它**不会**破坏签名：`claim` 不在 `.dsapp_sync_sig_payload` 的
#'    覆盖范围里（这正是"加顶层键不算换协议"的同一条性质），所以抹完之后
#'    这个归档包**照样验得过**，需要复现时仍然是一份有效物证。
#'
#' ⚠️ 只删 `claim`，别的字段一个不动 —— 包括收件人、水位、所有数据行。
#'    失败一律吞掉：抹不掉是"盘上多留了一份校验器"，而抛出去会让一个
#'    **已经应用成功**的包被当成失败重试。
#' @return TRUE = 抹掉了；FALSE = 本来就没有（没事可做）。**两者都不是失败**，
#'   调用方不需要看返回值 —— 这个返回值只给自检用。
#'   ⚠️ 别把 `return()` 写在 `try()` 里面：`try` 的 expr 是在**调用方的帧**里
#'      求值的，`return()` 会直接从外层函数返回，读代码的人（和我）都容易
#'      以为它只跳出 try 那一段。这里改成"一个出口 + 一个 flag"。
.dsapp_sync_scrub_claim <- function(file) {
  did <- FALSE
  try({
    if (file.exists(file)) {
      txt <- paste(readLines(file, warn = FALSE), collapse = "\n")
      if (grepl("\"claim\"", txt, fixed = TRUE)) {
        b <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
        if (!is.null(b[["claim"]]) || !is.null(b[["claim_sig"]])) {
          b[["claim"]] <- NULL
          b[["claim_sig"]] <- NULL
          writeLines(jsonlite::toJSON(b, auto_unbox = TRUE, null = "null",
                                      digits = NA), file)
          did <- TRUE
        }
      }
    }
  }, silent = TRUE)
  invisible(did)
}
dsapp_sync_outbox <- function(cfg = dsapp_config()) {
  file.path(dsapp_sync_root(cfg), "outbox")
}
dsapp_sync_tmp <- function(cfg = dsapp_config()) {
  file.path(dsapp_sync_root(cfg), "tmp")
}

dsapp_sync_mkdirs <- function(cfg = dsapp_config()) {
  for (d in c(dsapp_sync_inbox(cfg), dsapp_sync_inbox_applied(cfg),
              dsapp_sync_outbox(cfg), dsapp_sync_tmp(cfg))) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  invisible(TRUE)
}

# ---- 对端标识 --------------------------------------------------------------
#
# 一个「对端」= 一台机器 + 一个账号。同一台机器上两个本地账号各同步各的，
# 不能共用水位（否则 A 账号推进了水位，B 账号那批行就永远同步不过去了）。

dsapp_sync_peer_key <- function(node, email) {
  paste0(node, ":", tolower(trimws(email)))
}

#' 把 peer_key 变成能当目录名用的字符串
#'
#' 只留 `[A-Za-z0-9_-]`。邮箱里的 `@` `.` `+` 在 Linux 上是合法的目录名，
#' 但同步目录会被 scp 当**远端路径**拼进命令行，而 R/remote.R 对主机名做了
#' 字符白名单、对路径没有 —— 与其指望路径那层，不如在这里就把它变成
#' 一个"怎么拼都不可能出问题"的形状。
dsapp_sync_peer_slug <- function(key) {
  s <- gsub("[^A-Za-z0-9_-]", "_", key)
  if (nchar(s) > 100) s <- substr(s, 1, 100)
  s
}

# ---- 水位 ------------------------------------------------------------------

#' 读一个对端的同步状态；没有就返回一份空的
dsapp_sync_state_get <- function(peer, con = dsapp_db()) {
  d <- tryCatch(
    DBI::dbGetQuery(con, "SELECT * FROM sync_state WHERE peer = ?",
                    params = list(peer)),
    error = function(e) NULL)
  if (is.null(d) || !nrow(d)) {
    # ⚠️ 这份"空状态"的字段表要和 sync_state 的列**对齐**（V15 item 8 加了
    #    in_forum / out_forum）。漏一个的后果不是报错 —— 调用方读到 NULL，
    #    然后 `NULL > "2026-..."` 在 R 里是 `logical(0)`，`if` 一碰就是
    #    "argument is of length zero"。位置上离"少同步一段论坛"很远。
    return(list(peer = peer, peer_node = "", in_at = "", in_del = "",
                out_at = "", out_del = "", in_forum = "", out_forum = "",
                # ★ V16.6 item 2：技能段的四条（正文进/出、墓碑进/出）。
                in_skills = "", out_skills = "",
                in_del_skills = "", out_del_skills = "",
                last_at = "", note = ""))
  }
  as.list(d[1, , drop = FALSE])
}

dsapp_sync_state_set <- function(peer, con = dsapp_db(), ...) {
  cur <- dsapp_sync_state_get(peer, con)
  upd <- list(...)
  for (k in names(upd)) {
    v <- upd[[k]]
    cur[[k]] <- if (is.null(v) || (length(v) == 1 && is.na(v))) "" else as.character(v)
  }
  try(DBI::dbExecute(con,
    "INSERT INTO sync_state
       (peer, peer_node, in_at, in_del, out_at, out_del,
        in_forum, out_forum, in_skills, out_skills,
        in_del_skills, out_del_skills, last_at, note)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(peer) DO UPDATE SET
       peer_node = excluded.peer_node,
       in_at = excluded.in_at, in_del = excluded.in_del,
       out_at = excluded.out_at, out_del = excluded.out_del,
       in_forum = excluded.in_forum, out_forum = excluded.out_forum,
       in_skills = excluded.in_skills, out_skills = excluded.out_skills,
       in_del_skills = excluded.in_del_skills,
       out_del_skills = excluded.out_del_skills,
       last_at = excluded.last_at, note = excluded.note",
    params = list(peer, cur$peer_node %||% "", cur$in_at %||% "",
                  cur$in_del %||% "", cur$out_at %||% "", cur$out_del %||% "",
                  cur$in_forum %||% "", cur$out_forum %||% "",
                  cur$in_skills %||% "", cur$out_skills %||% "",
                  cur$in_del_skills %||% "", cur$out_del_skills %||% "",
                  cur$last_at %||% "", cur$note %||% "")), silent = TRUE)
  invisible(cur)
}

#' 「锚点」：本机主动发起时用的那行状态，键里**不含对端的节点 id**
#'
#' 为什么要这么一行（而不是直接用 peer_key）：桌面版**推**的时候还不知道
#' 服务器的节点 id —— 那个 id 只在服务器回包的 `node` 字段里，得先收到
#' 一个包才知道。可 state 的键要是"对端节点:邮箱"，第一次推就没有键可用。
#'
#' 所以分两行、各干各的：
#'   · 锚点行（键 = `dir:<远端同步目录>:<邮箱>`）：只有桌面版会写。
#'     记对端节点（收到回包之后补上）、发送水位、最后一轮的时间。
#'     远端同步目录在**连上之前**就知道（用户填的），所以这行永远有键可用。
#'   · 对端行（键 = `<对端节点>:<邮箱>`）：接收水位 in_at / in_del 写在这。
#'     两边都写这行 —— 服务器那边（惰性应用）也是这个键，因为它是从包里
#'     直接拿到发送方节点 id 的。
#'
#' ⚠️ 两台的**行形状不一样**，这是有意的，不是漏了：
#'    服务器只被动回包，它没有"远端目录"这个概念，所以没有锚点行；
#'    桌面版有锚点行，但它的 in_at 在对面那行里 —— 读的时候要走
#'    dsapp_sync_req_from()，别直接读锚点行的 in_at（那永远是空的，
#'    表现是"每轮都全量重传一遍"，不报错）。
dsapp_sync_anchor_key <- function(remote_dir, email) {
  paste0("dir:", trimws(as.character(remote_dir)), ":",
         tolower(trimws(as.character(email))))
}

#' 把一个水位往回退 overlap 秒
#'
#' 时间戳是 `%Y-%m-%d %H:%M:%S` 的 UTC 字符串（dsapp_now），定长所以能直接
#' 当字符串比大小。退回 0 以下就退成空串（= 从头来）。
.dsapp_sync_rewind <- function(at, overlap = DSAPP_SYNC_OVERLAP_SEC) {
  at <- trimws(at %||% "")
  if (!nzchar(at)) return("")
  t <- suppressWarnings(as.POSIXct(at, tz = "UTC", format = "%Y-%m-%d %H:%M:%S"))
  if (is.na(t)) return("")
  format(t - overlap, "%Y-%m-%d %H:%M:%S", tz = "UTC")
}

# ---- 映射 ------------------------------------------------------------------

#' 查映射。查不到返回 NA_character_
#'
#' ⚠️ 一律返回**字符**。会话 id 本来就是字符串（s-2026...-1234），消息 id
#'    是整数 —— 统一成字符是唯一能同时装下两者的形状，调用方要在哪边用就
#'    自己 as.integer()。别在这里"顺手转成整数"：那会把会话 id 变成 NA，
#'    而 NA 在这条路径上的含义是"没同步过"，于是**每同步一次就重新插一遍**。
.dsapp_sync_map_get <- function(peer, kind, origin, con = dsapp_db()) {
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT local_id FROM sync_map WHERE peer = ? AND kind = ? AND origin = ?",
      params = list(peer, kind, as.character(origin))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NA_character_)
  as.character(r$local_id[1])
}

#' "某台机器上的某条记录"在内存里的键
#'
#' ⚠️ 用 `\x1f`（单元分隔符）而不是 `:` 或 `-` 拼：节点 id 和记录 id 都是
#'    `[A-Za-z0-9_-]` 里挑出来的（见 dsapp_sync_node_id 的格式校验），
#'    所以 `-` 和 `_` 都可能在两边出现，拼出来的串**有歧义**：`(a-b, c)` 和
#'    `(a, b-c)` 会撞成同一个键。`\x1f` 不在那个字符集里，撞不上。
#'    （sync_map 那边不用担心这个 —— 它的主键是三列，不是拼出来的串。）
.dsapp_sync_skey <- function(node, id) {
  paste0(as.character(node), "\x1f", as.character(id))
}

.dsapp_sync_map_put <- function(peer, kind, origin, local_id, con = dsapp_db()) {
  try(DBI::dbExecute(con,
    "INSERT INTO sync_map (peer, kind, origin, local_id) VALUES (?, ?, ?, ?)
     ON CONFLICT(peer, kind, origin) DO UPDATE SET local_id = excluded.local_id",
    params = list(peer, kind, as.character(origin), as.character(local_id))),
    silent = TRUE)
  invisible(local_id)
}

#' 反查：本地某条记录，在对端那边叫什么
#'
#' ⚠️ 现在**没有调用点**。留着是因为它回答的问题（"我这条在对端是几号"）
#'    以后会用到 —— 比如做"两边都改了同一个对话"的冲突提示，界面上得说出
#'    "对方那边是哪个对话"。删墓碑**不用**它，理由见
#'    .dsapp_sync_collect_tombstones 上面那段。
#'
#' ⚠️ 注意它和下面 `.dsapp_sync_origin_of` 的区别：这个**要指定对端**，
#'    回答"我这条在**某个特定对端**那边是几号"；那个不指定对端，回答
#'    "**这一行是谁造的**"。同步路径上要的几乎都是后者。
.dsapp_sync_map_reverse <- function(peer, kind, local_id, con = dsapp_db()) {
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT origin FROM sync_map WHERE peer = ? AND kind = ? AND local_id = ?",
      params = list(peer, kind, as.integer(local_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(character(0))
  as.character(r$origin)
}

#' 一条本地记录的**出身**：它是哪个节点造出来的、在那边是几号
#'
#' 规则只有一条，但它把整个转发模型撑起来了：
#'   · 在 sync_map 里**查得到** → 这一行是收来的，出生于映射里那一对
#'     `(peer, origin)`；
#'   · **查不到** → 这一行是本机自己造的，出身就是 `(我自己, 本地 id)`。
#'
#' ⚠️ 为什么"查不到"就一定是自己造的：每收到一行都会现生成一个全新的本地
#'    id 再写映射（见 .dsapp_sync_session_insert 的撞号重试），所以"本地有
#'    这一行、而映射里没有"只可能是本地新建的。这条推理是整套防回声的地基，
#'    改动插入路径时要一起想。
#'
#' ⚠️ `ORDER BY rowid LIMIT 1` 不是可有可无的：sync_map 的主键是
#'    `(peer, kind, origin)`，`local_id` **不在主键里**，理论上不保证唯一。
#'    实际上不会撞（同上：一个本地 id 只被认领一次），但真撞了的话，不排序
#'    就是"每次查到哪条看 SQLite 心情"—— 表现为同一行时而发得出去、时而
#'    发不出去，最难查。取一条定死的，至少行为是确定的。
.dsapp_sync_origin_of <- function(kind, local_id, cfg = dsapp_config(),
                                  con = dsapp_db(cfg)) {
  me <- dsapp_sync_node_id(cfg)
  lid <- as.character(local_id)
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT peer, origin FROM sync_map
      WHERE kind = ? AND local_id = ? ORDER BY rowid LIMIT 1",
    params = list(as.character(kind), lid)), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(list(node = me, id = lid))
  list(node = as.character(r$peer[1]), id = as.character(r$origin[1]))
}

# ---- 墓碑 ------------------------------------------------------------------

#' 记一条墓碑（本地删了东西）
#'
#' 由 db_session_delete() 调用 —— 那是**唯一**删会话的地方（R/db.R）。
#' 失败一律吞掉：删对话这个动作本身已经成功了，墓碑只是"顺带告诉对端"，
#' 不能让它把删除动作搞失败。
dsapp_sync_tombstone_add <- function(kind, local_id, con = dsapp_db(),
                                     cfg = dsapp_config()) {
  try(DBI::dbExecute(con,
    "INSERT INTO sync_tombstone (kind, origin, node, at)
     VALUES (?, ?, ?, ?)",
    params = list(kind, as.character(local_id),
                  dsapp_sync_node_id(cfg), dsapp_now())), silent = TRUE)
  invisible(TRUE)
}

#' 清掉过期的墓碑
#'
#' 挂进 dsapp_gc()。太久之前的墓碑没有意义了 —— 一个 180 天没同步过的
#' 对端，它那边的数据本来也就该按"重新全量"处理。
dsapp_sync_gc <- function(days = DSAPP_SYNC_TOMBSTONE_DAYS, con = dsapp_db()) {
  t <- format(Sys.time() - days * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  n <- tryCatch(DBI::dbExecute(con,
    "DELETE FROM sync_tombstone WHERE at < ?", params = list(t)),
    error = function(e) 0L)
  as.integer(n)
}

# ---- 打包 ------------------------------------------------------------------

#' 取一个账号名下、水位之后的所有会话和消息
#'
#' @param user_id 本地账号 id。**只同步这个账号的东西** —— 同步是"我的数据
#'   跟着我走"，不是"把整台机器倒过去"。
#' @param for_node 这一包是**发给谁**的（对端节点 id），空串 = 不知道对端是谁。
#'   ⚠️ 它**只管省流量，不管对错** —— 正确性在接收端（见文件头第六节）。
#'   拿不到就传空串，多发一些对端自己会认出来的行而已，不会重复。
#'   桌面版第一次推的时候就是空的：服务器的节点 id 要等第一个回包才知道。
#'   ⚠️ 它筛的粒度是**会话**，而且只在"这个会话整个都是对端的东西"时才筛
#'   —— 夹带了别处写的新消息的会话照发。理由写在下面筛的那一段，那里的
#'   教训是"按会话筛"很容易顺手把消息也筛掉。
#' @return list(sessions = list(...), messages = list(...))
dsapp_sync_collect <- function(user_id, since_at = "", cfg = dsapp_config(),
                               con = dsapp_db(cfg), for_node = "") {
  since <- .dsapp_sync_rewind(since_at)
  me <- dsapp_sync_node_id(cfg)
  for_node <- trimws(as.character(for_node %||% ""))

  # ★ 每一行都带上它的**出身**。LEFT JOIN sync_map 就是"这一行是从对端收来
  #   的吗"的答案：查得到 = 收来的（peer/origin 就是造它的节点和它在那边的
  #   id），查不到 = 本机自己造的（出身就是我自己 + 本地 id）。
  #
  # ⚠️ 这个 JOIN 是 1:1 的，不会把行数放大：sync_map 里 local_id 指向某一
  #    条本地会话的行最多只有一条 —— 每收一条就现生成一个全新的本地 id
  #    （见 .dsapp_sync_session_insert 的撞号重试），一个本地 id 只可能被
  #    认领一次。索引 idx_sync_map_local 就是为这个 JOIN 建的
  #    （原来那个 idx_sync_map_rev 以 peer 打头，这个 JOIN 用不上）。
  #
  # ⚠️ 这里**故意不在 SQL 里筛 for_node**。筛的动作在下面、看过消息之后才做，
  #    理由见那一段。原来这里是
  #      AND (m.peer IS NULL OR ? = '' OR m.peer <> ?)
  #    （三个条件缺一不可：放行"我自己造的"、不知道对端就别筛、别把对端造
  #    的发回给对端；写成 `m.peer <> ?` 单独一个的话 for_node 为空串时会把
  #    本机自己造的行也筛掉 —— NULL <> '' 是 NULL 不是 TRUE —— 表现是第一次
  #    推上去一个空包，而两边都不报错）。
  sess <- tryCatch(DBI::dbGetQuery(con,
    "SELECT s.id, s.title, s.created_at, s.updated_at,
            m.peer AS origin_node, m.origin AS origin_id
       FROM sessions s
       LEFT JOIN sync_map m ON m.kind = 'session' AND m.local_id = s.id
      WHERE s.user_id = ? AND s.updated_at > ?
      ORDER BY s.updated_at LIMIT ?",
    params = list(as.integer(user_id), since,
                  DSAPP_SYNC_MAX_SESSIONS + 1L)),
    error = function(e) NULL)
  if (is.null(sess)) sess <- data.frame()

  truncated <- nrow(sess) > DSAPP_SYNC_MAX_SESSIONS
  if (truncated) sess <- sess[seq_len(DSAPP_SYNC_MAX_SESSIONS), , drop = FALSE]

  # 出身：收来的用映射里那一对，自己造的用我自己 + 本地 id。
  # ⚠️ 在**截断之后**算。放前面的话这两列会比 sess 长（截断砍掉了尾巴），
  #    后面按下标取就会错位一格 —— 会话挂到别人的消息上，而且不报错。
  sess_origin_node <- if (nrow(sess)) {
    ifelse(is.na(sess$origin_node), me, as.character(sess$origin_node))
  } else character(0)
  sess_origin_id <- if (nrow(sess)) {
    ifelse(is.na(sess$origin_id), as.character(sess$id),
           as.character(sess$origin_id))
  } else character(0)
  # 本地会话 id → 它的出身。消息要按这个把"我在哪条会话里"翻译成对端认识的
  # 形状 —— 消息自己的出身和它所属会话的出身是**两件事**（B 在 A 的对话里
  # 接着聊：消息的出身是 B，会话的出身还是 A）。
  sess_origin_of <- function(local_sid) {
    i <- match(as.character(local_sid), as.character(sess$id))
    if (is.na(i)) return(NULL)
    list(node = sess_origin_node[i], id = sess_origin_id[i])
  }

  # ⚠️ 会话 id 是**字符串**（s-2026...-1234）。这里原来是 as.integer()，
  #    结果会把整列变成 NA —— 消息一条都取不到，而包看上去是"成功的"，
  #    只是里面没有消息。同步完用户看到一排空对话，不知道是哪一步丢的。
  ids <- as.character(sess$id)
  msg <- data.frame()
  if (length(ids)) {
    # ⚠️ 消息按**会话**取，不按消息自己的时间取。原因是消息表没有
    #    updated_at（它只追加，从不修改），而 created_at 可能早于会话的
    #    updated_at —— 按时间筛会把"给老会话补的新消息"漏掉。
    #    跟着会话走则天然覆盖：只要会话还是新的，它的消息就一起过去。
    #
    # ⚠️ 和会话那边一样，这里的 LEFT JOIN 是为了带上每条消息**自己的**
    #    出身。注意它和所属会话的出身不是一回事（见上面 sess_origin_of）。
    #
    # ⚠️ 这里拼的是**占位符**不是值：ids 是本地库里的会话 id，但拼 SQL
    #    这个动作本身要经得起"以后有人拿别的来源填 ids"。DBI 的 params
    #    对变长 IN 支持不稳（见 db_tasks_meta 的同类说明），所以拼占位符
    #    个数、值走 params。
    msg <- tryCatch(DBI::dbGetQuery(con, sprintf(
      "SELECT g.id, g.session_id, g.role, g.content, g.reasoning, g.created_at,
              gm.peer AS origin_node, gm.origin AS origin_id
         FROM messages g
         LEFT JOIN sync_map gm ON gm.kind = 'message' AND gm.local_id = g.id
        WHERE g.session_id IN (%s) ORDER BY g.id",
      paste(rep("?", length(ids)), collapse = ", ")),
      params = as.list(ids)), error = function(e) NULL)
    if (is.null(msg)) msg <- data.frame()
    if (nrow(msg) > DSAPP_SYNC_MAX_MESSAGES) {
      msg <- msg[seq_len(DSAPP_SYNC_MAX_MESSAGES), , drop = FALSE]
      truncated <- TRUE
    }
  }

  # ★ for_node 的筛，**必须在取完消息之后做**。
  #
  #   原来是在会话那条 SQL 里筛的（`m.peer <> for_node`），看起来等价，其实
  #   漏掉了一整类行：消息是**按会话**取的，会话行一旦被筛掉，它身上的消息
  #   就一条都取不到。于是「B 在 A 造的对话里接着聊，那几句回不到 A」这个
  #   旧毛病，换了套机制又原样犯了 —— 会话的出身是 A（== for_node），被筛，
  #   连同 B 写的新消息一起消失，而包看上去是"成功"的。
  #
  #   现在的规则：会话的出身是对端、**并且**它下面没有一条"不是对端造的"
  #   消息，才不发。纯回声（对端的东西转一圈回来）照样省掉；夹带了别人新
  #   写的东西就一定发。
  #
  #   ⚠️ 这只是省流量，正确性仍然在接收端（文件头第六节）。所以这里的判断
  #      宁可**放过**不可**错杀** —— 上面那个条件写成"有没有对端不知道的
  #      消息"要准得多，但那需要把每台的 sync_map 都拿来比，不值当：多发
  #      几条对端自己会认出来的行，代价只是带宽。
  if (nzchar(for_node) && nrow(sess)) {
    foreign <- if (nrow(msg)) {
      unique(as.character(msg$session_id[
        is.na(msg$origin_node) | as.character(msg$origin_node) != for_node]))
    } else character(0)
    keep <- sess_origin_node != for_node | as.character(sess$id) %in% foreign
    if (!all(keep)) {
      sess             <- sess[keep, , drop = FALSE]
      sess_origin_node <- sess_origin_node[keep]
      sess_origin_id   <- sess_origin_id[keep]
      if (nrow(msg)) {
        msg <- msg[as.character(msg$session_id) %in% as.character(sess$id), ,
                   drop = FALSE]
      }
    }
  }

  # 被截断的时候**不能推进水位**（见 dsapp_sync_build_bundle 的说明）：
  # 水位一旦推到最新，没传完的那些行就永远轮不到了。
  list(
    sessions  = if (nrow(sess)) lapply(seq_len(nrow(sess)), function(i) list(
      id = as.character(sess$id[i]), title = sess$title[i] %||% "",
      created_at = sess$created_at[i] %||% "", updated_at = sess$updated_at[i] %||% "",
      # ★ 这一行的**出身**（见文件头第六节）。`id` 仍然是**我本地**的 id ——
      #   它是"我这条会话在同步包里排第几"的坐标，接收方要用 origin_id
      #   去 sync_map 里翻。两者在"我自己造的会话"上是同一个值，在转发来的
      #   会话上不是（那时 id 是本地 id、origin 才是造它的那台机器的 id）。
      origin_node = sess_origin_node[i],
      origin_id   = sess_origin_id[i],
      # ⚠️ 会话要带上"它属于谁"。对端靠这个把对话挂到正确的本地账号上
      #    （见 dsapp_sync_apply_bundle 里那段）。这个值在**对端**的
      #    users 表里是个 id，所以接收方要用 sync_map 翻，不能直接当本地
      #    uid 用 —— 两个库的自增 id 毫无关系。
      user_id = as.character(user_id)
    )) else list(),
    messages  = if (nrow(msg)) lapply(seq_len(nrow(msg)), function(i) {
      so <- sess_origin_of(msg$session_id[i])
      list(
        id = as.character(msg$id[i]),
        # 这一行消息自己的出身。
        origin_node = if (is.na(msg$origin_node[i])) me
                      else as.character(msg$origin_node[i]),
        origin_id   = if (is.na(msg$origin_id[i])) as.character(msg$id[i])
                      else as.character(msg$origin_id[i]),
        # ⚠️ `session_id` 是**所属会话的出身 id**，不是本地 id。接收方拿
        #    它去 sess_map 里查（那张表的键也是出身 id）。转发的会话上
        #    这两个值不一样，写错的表现是"消息一条都挂不上"——而包看上去
        #    是成功的，只是里面每一条消息都因为"父会话不存在"被丢掉了。
        session_id   = if (is.null(so)) as.character(msg$session_id[i]) else so$id,
        session_node = if (is.null(so)) me else so$node,
        role = msg$role[i] %||% "", content = msg$content[i] %||% "",
        reasoning = if (is.na(msg$reasoning[i])) NULL else msg$reasoning[i],
        created_at = msg$created_at[i] %||% ""
      )
    }) else list(),
    truncated = truncated,
    high_water = if (nrow(sess)) max(sess$updated_at) else ""
  )
}

#' 取这个账号的**身份行**（users）
#'
#' ⚠️ 只取 DSAPP_SYNC_USER_COLS 里的列。见那个常量的注释 —— 提权列
#'    （is_admin/status）和每机器一分的秘密（token/llm_api_key）都不过网。
.dsapp_sync_collect_user <- function(user_id, con = dsapp_db()) {
  cols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(users)")$name,
                   error = function(e) character(0))
  use <- intersect(DSAPP_SYNC_USER_COLS, cols)
  if (!length(use)) return(NULL)
  r <- tryCatch(DBI::dbGetQuery(con, sprintf(
    "SELECT id, %s FROM users WHERE id = ?",
    paste(use, collapse = ", ")), params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  out <- list(id = as.character(r$id[1]))
  for (k in use) {
    v <- r[[k]][1]
    out[[k]] <- if (is.na(v)) NULL else as.character(v)
  }
  out
}

#' 取**本机那一行**用户的口令材料（只给认领材料用）
#'
#' ★ 这是全仓**唯一**一处把 pass_salt/pass_hash 读出来准备过网的地方，
#'   所以它单独一个函数、单独一段注释 —— 埋在 collect_user 里的话，
#'   下次有人给那个函数加一列就会顺手把它带进**每一个**包。
#'
#' ⚠️ 和 `.dsapp_sync_collect_user` 是**两件事**：那个走
#'    `DSAPP_SYNC_USER_COLS` 白名单（email/nickname/phone/field/created_at），
#'    口令材料**不在**白名单里，也永远不该进去。这里读出来的东西只喂给
#'    `dsapp_sync_claim_make()`，而那个函数的产物只在 `claim = TRUE` 的
#'    那一个包里出现。
#'
#' @return list(email, salt, hash, nickname, phone, field)；读不到返回 NULL。
.dsapp_sync_claim_local <- function(user_id, con = dsapp_db()) {
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT email, pass_salt, pass_hash, nickname, phone, field
       FROM users WHERE id = ?", params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  g <- function(k) {
    v <- r[[k]][1]
    if (is.null(v) || length(v) == 0L || is.na(v)) "" else as.character(v)
  }
  out <- list(email = tolower(trimws(g("email"))), salt = g("pass_salt"),
              hash = g("pass_hash"), nickname = g("nickname"),
              phone = g("phone"), field = g("field"))
  # 邮箱、盐、哈希三个缺一个，这份材料就没法用来建号 —— 返回 NULL 让调用方
  # 干脆别带（带一份残缺的过去，对面只会在格式校验那里拒掉，白跑一趟）。
  if (!nzchar(out$email) || !nzchar(out$salt) || !nzchar(out$hash)) return(NULL)
  out
}

#' 取待推送的墓碑
#'
#' ★ 墓碑里带的是**我方本地的 id，不做任何翻译**。这一点很容易想反，
#'   记一下为什么：
#'
#'   对端第一次收到这条会话时，它写下的映射是
#'       sync_map(peer = 我, kind = 'session', origin = **我的 id**, local_id = 它的 id)
#'   —— origin 那一列存的就是**我这边**的 id。所以它拿到"我把本地 id=7
#'   删了"这条消息时，一句 `sync_map` 查询就能翻出"那我该删我这边第 12 条"。
#'
#'   反过来（发送方先翻译成"对端认识的 id"）是**错**的，而且错得很隐蔽：
#'   翻译要用 `.dsapp_sync_map_reverse(对端的 node id, ...)`，可桌面版在
#'   收到服务器第一个回包**之前根本不知道服务器的 node id** —— 于是
#'   "刚连上就删了个对话"这种最常见的顺序下，删除事件永远发不出去，
#'   而两边都不报错。
#' ★ V13.7 item 7：包里带的是**这一行原本的出身**，不是我本地 id。
#'   会话那边同样的道理（见 dsapp_sync_collect）。本地 id 在这里要经过一次
#'   反查：一条我从 A 那儿收来的会话，在我本地是 55 号，但这个墓碑要让
#'   **A** 看得懂 —— A 只认识它自己的 10 号。LEFT JOIN sync_map 就是这次反查，
#'   查不到说明这一行本来就是我自己造的，那出身就是 `(我, 本地 id)`，
#'   而 `sync_tombstone.node` 存的正是"记这条墓碑的节点"。
.dsapp_sync_collect_tombstones <- function(since_del, con = dsapp_db(),
                                           kinds = "session",
                                           limit = 500L) {
  # ⚠️⚠️ `con` **必须留在第二个位置**。V16.6 加 kinds/limit 时第一版把它们
  #    插在 con 前面，而 R/sync.R 里那个调用点是按位置写的
  #    （`.dsapp_sync_collect_tombstones(req_from_del, con)`）—— 于是连接对象
  #    落进了 `kinds`，`kinds %||% "session"` 里的 `is.na(a[1])` 对 S4 连接
  #    报的是 **"object of type 'S4' is not subsettable"**，一个和"参数插错
  #    位置"毫无字面关系的错。加参数一律加在**末尾**，别插中间。
  since <- .dsapp_sync_rewind(since_del)
  # ★ V16.6 item 2：`kinds` 是**必须**的。技能墓碑如果混进主包那个数组，
  #   它就要和会话共用 `req_from_del` 那一条水位 —— 会话推得快会把水位一起
  #   顶上去，老的技能墓碑再也发不出去，表现是"删了技能同步一下又回来了"。
  #   默认 `"session"`：调用方不写就是原来的行为，一个字都没变。
  kinds <- as.character(kinds %||% "session")
  if (!length(kinds)) return(list(items = list(), high_water = "",
                                  truncated = FALSE))
  # ⚠️ 占位符个数**数**出来，不手写（R/skills.R 里那条 2026-09-19 的事故
  #    就是手写个数写岔了，两支里错两支，还被 tryCatch 吞成 NULL）。
  #    `?` 当正则读是"前一个字符可选"，所以算个数必须 fixed = TRUE。
  ph <- paste(rep("?", length(kinds)), collapse = ", ")
  r <- tryCatch(DBI::dbGetQuery(con, sprintf(
    "SELECT t.id, t.kind, t.origin, t.at, t.node,
            m.peer AS onode, m.origin AS oid
       FROM sync_tombstone t
       LEFT JOIN sync_map m ON m.kind = t.kind AND m.local_id = t.origin
      WHERE t.at > ? AND t.kind IN (%s)
      ORDER BY t.at LIMIT ?", ph),
    params = c(list(since), as.list(kinds), list(as.integer(limit) + 1L))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) {
    return(list(items = list(), high_water = "", truncated = FALSE))
  }
  # ★ 截断了**不能推水位**（同会话/论坛）。水位推上去之后，没发完的那批
  #   `at` 比新水位小，下一轮的 `> 水位` 永远筛不到它们。
  trunc <- nrow(r) > as.integer(limit)
  if (trunc) r <- r[seq_len(as.integer(limit)), , drop = FALSE]
  out <- list()
  for (i in seq_len(nrow(r))) {
    out[[length(out) + 1L]] <- list(
      kind = as.character(r$kind[i]),
      # 出身节点 + 出身 id。老包（v1）没有 node 字段，接收端会退回用
      # 包自己的 node —— 见 dsapp_sync_apply_bundle 里那一段。
      node = if (is.na(r$onode[i])) as.character(r$node[i])
             else as.character(r$onode[i]),
      id   = if (is.na(r$oid[i])) as.character(r$origin[i])
             else as.character(r$oid[i]),
      at   = as.character(r$at[i]))
  }
  list(items = out,
       high_water = if (trunc) "" else max(r$at),
       truncated = trunc)
}

#' 打一个包（写成 JSON 文件）
#'
#' @param req_from 对端**已经收到的**水位。对端把它的 in_at 报给我们，我们
#'   就只发它之后的东西。这是"服务器怎么知道该回什么"的答案 —— 服务器
#'   那边没有请求-响应，是靠这个字段把"要什么"捎过来的。
#' @param out_dir 包写到哪个目录。默认写进本机的 tmp/，桌面版再把文件 scp
#'   到服务器；服务器回包时直接指到 `outbox/<对端>/`（见 .dsapp_sync_reply）。
#' @param key 同步签名密钥（`dsapp_sync_key()` 现推的那份）。
#'   ⚠️ 和 `dsapp_sync_apply_bundle` 的 `key` **故意不一样**：那边不传会
#'   自己去内存表里按邮箱找，这边**不找**，拿不到就返回 `ok = FALSE`。
#'   原因是两边"忘了传"的后果不对称 ——
#'     · 打包这边忘了传 → **响亮的失败**（一句"没有可用的同步密钥"），
#'       而且绝不会发出未签名的包（发出去对面也会拒，白跑一趟）；
#'     · 应用那边忘了传 → **静默挂起**（包躺在收件箱里等本人登录），
#'       不报错、界面照常，最难查。所以才给它加了那个兜底。
#'   所以这里是有意"不兜底"的：调用方本来就该显式说明"用谁的密钥"。
#' @return list(ok, path, n_sessions, n_messages, n_del, high_water, truncated)
dsapp_sync_build_bundle <- function(peer, user_id, req_from = "", req_from_del = "",
                                    cfg = dsapp_config(), con = dsapp_db(cfg),
                                    out_dir = NULL, for_node = "", key = NULL,
                                    req_from_forum = "", claim = FALSE,
                                    req_from_skills = "",
                                    req_from_del_skills = "") {
  node <- dsapp_sync_node_id(cfg)
  col <- dsapp_sync_collect(user_id, req_from, cfg, con, for_node = for_node)
  user <- .dsapp_sync_collect_user(user_id, con)
  tomb <- .dsapp_sync_collect_tombstones(req_from_del, con)
  # ★ V15 item 8：论坛段。**不传 user_id / for_node** —— 它是公共的，
  #   所有人的帖子对所有人可见（见 R/forum.R 文件头和 SYNC.md 第九节）。
  #   ⚠️ 别顺手把 for_node 传进去"省得回声"：论坛行的身份是
  #   (origin_node, origin_id)，收端自己认得出"这是我造的"，不需要发送端筛。
  #   发送端筛反而有害 —— 桌面版第一次推的时候不知道对端是谁（V13.3 那个
  #   坑，SYNC.md §4.5 第 2 条），筛错了就是"帖子发上去了但谁也看不见"。
  frm <- dsapp_forum_collect(req_from_forum, con)
  # ★ V16.6 item 2：技能段。**它自己的两条水位**（正文 / 墓碑），不蹭会话的
  #   —— 理由见 R/skills.R 文件头第三节。
  #   ⚠️ 也不传 for_node：技能的身份是 (origin_node, origin_id)，收端自己
  #   认得出"这是我造的"，发送端筛反而会在"第一次推还不知道对端是谁"时
  #   筛错（论坛那一段踩过同一个坑，见上面 forum 的注释）。
  skl <- dsapp_skills_collect(req_from_skills, req_from_del_skills,
                              user_id = user_id, cfg = cfg, con = con)

  b <- list(
    # ⚠️ 格式版本。2 = 每一行带 (origin_node, origin_id)、包带签名。
    #    1 是老格式：行没有出身（接收端当成"就是发件人造的"）、包没有签名。
    #    接收端**仍然能吃 1**（见 apply_bundle），但**发出去的一律是 2** ——
    #    对方若是老客户端，它看不懂 origin_node，会当成自己的字段忽略掉，
    #    于是退化成 V13.3 的行为：不转发、也不出错。
    v = 2L,
    node = node,
    sent_at = dsapp_now(),
    # 包里带上"我是谁"。对端要靠它把行归到自己那个账号下 —— 账号是按
    # email 认的（users 表上有唯一索引），不是按 id。
    user = user,
    # ★ 这两个字段是**请求**，不是数据：告诉收到这个包的人"我已经有到哪儿
    #   了，你只要给我这之后的东西"。服务器回包就是靠它们算的。
    #
    #   ⚠️ 最早的版本漏了这两个字段（只当成传给 build_bundle 的参数用），
    #      结果是服务器**没有任何办法知道桌面版手上有什么** —— 只能每轮
    #      把整个库回一遍。不报错，只是越同步越慢，而且桌面版每次都在
    #      重放同一批包（靠幂等吸收，看不出来）。
    req_from = as.character(req_from %||% ""),
    req_from_del = as.character(req_from_del %||% ""),
    # ★ V15 item 8：论坛段的请求水位，和上面两个同性质。见 .dsapp_sync_sig_payload。
    req_from_forum = as.character(req_from_forum %||% ""),
    sessions = col$sessions,
    messages = col$messages,
    tombstones = tomb$items,
    # ★ V15 item 8：**公共段**。它和上面三个的关键差别只有一条：
    #   上面的内容都是"这个账号的东西"，这一段是"所有人的东西"。
    #   包里带着它，是因为**收端的密钥决定了谁能收到这一包**（给谁打包
    #   就用谁的密钥签），而不是因为论坛的内容归这个账号。
    forum = list(threads = frm$threads, posts = frm$posts, marks = frm$marks),
    # ★ V16.6 item 2：技能段。⚠️ 它**不在** `.dsapp_sync_sig_payload` 的覆盖
    #   范围里（那是冻结点），所以它**自己带一条签名**（下面紧跟着盖）。
    #   老接收端看不见这个键，算出来的 HMAC 一个字节都没变。
    #   ⚠️ 段里带着**它自己的两条水位**（req_from / req_from_del）—— 放顶层
    #      就绕开了主签名，放段里才被段自己那条签名盖住。
    skills = list(
      req_from     = as.character(req_from_skills %||% ""),
      req_from_del = as.character(req_from_del_skills %||% ""),
      items        = skl$items,
      links        = skl$links,
      dels         = skl$dels,
      high_water     = skl$high_water,
      high_water_del = skl$high_water_del
    )
  )

  # ★ 签名（V13.7 item 7）。没有密钥就**不发**：一个没有签名的包在新版
  #   接收端会被拒收，发出去只是白跑一趟，还会在收件箱里留个垃圾文件。
  #   宁可在这里明确失败，让用户看到"需要先登录一次"。
  #
  # ⚠️ 签名必须在**所有字段都填完之后**算（.dsapp_sync_sig_payload 覆盖了
  #    v/node/sent_at/user/req_from/req_from_del）。挪到前面去就会签到一个
  #    还没填完的包 —— 发出去的那份和签名覆盖的那份不是一个东西，对面必拒。
  sig <- dsapp_sync_sign(b, key)
  if (is.na(sig)) {
    return(list(ok = FALSE,
                msg = paste0("没有可用的同步密钥，这个包没有发出去。",
                             "同步密钥是从登录密码现推的：请在两边用同一个",
                             "密码各登录一次，然后再同步。")))
  }
  b$sig <- sig

  # ★ V16.6 item 2：**技能段自己那条签名**。
  #
  #   为什么非盖不可：技能段不在主签名（`b$sig`）的覆盖范围里 —— 那正是不
  #   换协议的原因。不补这一条的话，任何一个能在中转服务器上写文件的人，
  #   都能往一个合法包里塞一段技能，而技能是**会被挂进系统提示词**的文本。
  #
  #   ⚠️ 和主包一个形状：HMAC 和 Ed25519 **两条都盖**，收件人挑验得过的。
  #      理由一模一样 —— 发件人不知道收件人手里有什么（内存里那把密码派生
  #      的密钥？库里绑过的公钥？还是只有认领材料里那把？），猜错的症状是
  #      **静默失败**。
  #   ⚠️ 位置：`skills` 必须已经填完（上面 b 的构造里），而 `skills_sig*`
  #      绝不能进 `.dsapp_sync_skills_payload`（那就是签名盖住自己）。
  #   ⚠️⚠️ 这里**不看"段里有没有东西"**，一律盖。写成"空了就不盖"是个
  #      看着像省事的优化，其实是**把正常路径变成红**：收端那条判据是
  #      "包里有 skills 键就必须验得过"，而空段也有那个键 ——
  #      于是每一轮同步都被自己拒收。本仓 `mutation-must-change-behavior`
  #      那条老账就是这个形状（不改变行为的"优化"证明的是零）。
  ss <- dsapp_sync_skills_sign(b, key)
  if (!is.na(ss)) b$skills_sig <- ss

  # ★ V16.6 item 1：**本机身份那份签名**（Ed25519），和上面那条 HMAC 并列。
  #
  #   为什么要两个都盖：云端验哪一条，取决于服务器**当时手里有什么** ——
  #     · 有密码派生的密钥吗？取决于"账号本人最近 12 小时登录过网页版没有"
  #       （密钥只在密码登录那一刻进内存，服务器不存它）—— 桌面版**无从得知**；
  #     · 账号绑过公钥吗？也看不出来。
  #   只盖一条 = 猜，猜错的症状是**静默失败**（包发出去了、收件箱里躺着、
  #   界面上什么都不说）。两条都盖，服务器挑验得过的那个。
  #
  #   ⚠️ 签名的位置：必须在**所有字段都填完之后**，和上面那条 HMAC 同一个
  #      理由 —— 晚一步加字段，签的就是另一份字节，对面必拒。
  #   ⚠️ `sig_ed` / `claim` / `claim_sig` 都**不在** `.dsapp_sync_sig_payload`
  #      的覆盖范围里，所以老服务器算出来的 HMAC 一个字节都没变（这一条有
  #      自检钉着）。往 payload 里加键才是换协议。
  id <- dsapp_sync_identity_ensure(cfg)
  if (!is.null(id)) {
    sig_ed <- dsapp_sync_sign_ed(b, id$seed)
    if (!is.na(sig_ed)) b$sig_ed <- sig_ed
    # ★ V16.6 item 2：技能段的 Ed25519 那一份（同一个身份私钥）。
    #   没有它的话，服务器在"账号本人最近 12 小时没登录过网页版"时
    #   （= 内存里没有 HMAC 密钥，只能靠绑过的公钥验签）整包验得过、
    #   技能段却验不过 → 被下面那条"有段必验"的判据拒收。**整包同步全挂**，
    #   而症状是"我什么都没改，昨天还好好的"。
    if (!is.null(b[["skills"]])) {
      ss_ed <- dsapp_sync_skills_sign_ed(b, id$seed)
      if (!is.na(ss_ed)) b$skills_sig_ed <- ss_ed
    }
  }

  # ★ 认领材料：只有**第一次**往这台服务器推的时候才带。
  #
  #   它里面装着本地那一行的 pass_salt/pass_hash —— 那是"两边密码一致"的
  #   全部秘密，也是云端唯一能拿到的口令校验器。**它是一份校验器不是密码，
  #   但对弱口令等价于密码**（1000 轮 sha256、DSAPP_PW_MIN = 6L），所以：
  #     · 只在建号/配对的那一个包里出现，此后永不过网；
  #     · 服务器落地之后会把归档包里的这一段抹掉（见 .dsapp_sync_user_claim）。
  #
  #   ⚠️ 判据用 `isTRUE(claim)`，而且**默认 FALSE**：调用方忘了传就退化成
  #      "只盖 HMAC"，也就是本版之前的形状 —— 老服务器照收，不会因此漏密码。
  #      反过来的默认（每次都带）会让口令校验器**每轮同步都过一遍网**，
  #      而这件事没有任何界面症状。
  if (isTRUE(claim)) {
    cu <- .dsapp_sync_claim_local(user_id, con)
    if (!is.null(cu)) {
      cl <- dsapp_sync_claim_make(cu$email, cu$salt, cu$hash,
                                  uid = user_id, nickname = cu$nickname,
                                  phone = cu$phone, field = cu$field,
                                  cfg = cfg)
      if (!is.null(cl)) {
        cl$claim_sig <- dsapp_sync_claim_sign(cl, cfg)
        if (!is.na(cl$claim_sig)) b$claim <- cl
      }
    }
  }

  dsapp_sync_mkdirs(cfg)
  if (is.null(out_dir)) out_dir <- dsapp_sync_tmp(cfg)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  # ⚠️ 文件名里必须带随机尾巴。只用"节点_秒级时间戳"的话，同一秒内的两个包
  #    会**同名、后一个把前一个覆盖掉** —— 收件箱那边看到的就是一个包，
  #    另一个包连同里面的对话一声不响地没了。dsapp_sync_now 里"推完立刻拉"
  #    这种连着两轮的操作很容易踩到。
  nm <- sprintf("%s_%s_%s.json", dsapp_sync_peer_slug(node),
                format(Sys.time(), "%Y%m%d%H%M%S"), dsapp_token(4))
  p <- file.path(out_dir, nm)
  ok <- tryCatch({
    writeLines(jsonlite::toJSON(b, auto_unbox = TRUE, null = "null",
                                digits = NA), p)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(list(ok = FALSE, msg = "打包失败（写临时文件出错）"))

  # ⚠️ 水位只在**没被截断**时推进。被截断说明这个包里只装了一部分，
  #    推进水位等于把没装进去的那些行标记成"已同步"，它们就再也轮不到了。
  #    表现是"同步过几次之后，早先的对话永远缺几条"——不报错，最难查。
  list(ok = TRUE, path = p, node = node,
       n_sessions = length(col$sessions), n_messages = length(col$messages),
       n_del = length(tomb$items),
       n_forum = length(frm$threads) + length(frm$posts) + length(frm$marks),
       n_skills = length(skl$items), n_skills_del = length(skl$dels),
       high_water = col$high_water, high_water_del = tomb$high_water,
       high_water_forum = frm$high_water,
       high_water_skills = skl$high_water,
       high_water_del_skills = skl$high_water_del,
       # ★ 三个 truncated 分开报。合成一个的话会出现"论坛被截断 → 会话的
       #   水位也不推进"，表现是对话越同步越重复（无害但很慢）；反过来更糟：
       #   会话被截断而论坛水位照推，论坛那半截**永远补不回来**。
       #   技能那一段同理，而且它**自己内部还有两条**（正文/墓碑），
       #   `skl$truncated` 是那两条的或 —— 所以它是"技能这边有东西没发完"。
       truncated = isTRUE(col$truncated) || isTRUE(frm$truncated) ||
                   isTRUE(skl$truncated))
}

# ---- 应用 ------------------------------------------------------------------

#' 应用一个包（JSON 文件）
#'
#' 幂等：同一个包应用两次结果一样。这是有意的 —— 水位那套只是优化，正确性
#' 靠的是"重复应用不产生副作用"。
#'
#' @return list(ok, msg, n_sess, n_msg, n_del, n_user)
dsapp_sync_apply_file <- function(path, cfg = dsapp_config(),
                                  con = dsapp_db(cfg), key = NULL) {
  b <- tryCatch(
    jsonlite::fromJSON(paste(readLines(path, warn = FALSE), collapse = "\n"),
                       simplifyVector = FALSE),
    error = function(e) NULL)
  if (is.null(b) || !is.list(b)) {
    return(list(ok = FALSE, msg = "包不是合法 JSON"))
  }
  dsapp_sync_apply_bundle(b, cfg, con, key = key)
}

#' 应用一个已经解析好的包
#'
#' ★ V13.7 item 7：**先验签，再动手**。验不过就一个字节都不写。
#'
#' @param key 这个账号的同步密钥（dsapp_synckey_get()）。空串 = 现在拿不到
#'   （账号本人不在线），**不是"跳过验签"** —— 拿不到密钥时这个包会被挂起，
#'   原封不动留在收件箱里等本人下次登录（见 dsapp_sync_maybe_apply）。
dsapp_sync_apply_bundle <- function(b, cfg = dsapp_config(), con = dsapp_db(cfg),
                                    key = NULL) {
  peer <- trimws(as.character(b$node %||% ""))
  if (!nzchar(peer)) return(list(ok = FALSE, msg = "包里没有来源节点标识"))
  # 自己的包不该出现在自己这儿。真出现了（比如把两边目录搞混了）就直接
  # 扔掉 —— 硬着头皮应用会把自己的行按对端身份再插一遍，变成双份。
  if (identical(peer, dsapp_sync_node_id(cfg))) {
    return(list(ok = FALSE, msg = "这个包是自己发的，跳过", self = TRUE))
  }

  # ---- 0. 验签 ------------------------------------------------------------
  #
  # ⚠️ 顺序是**安全要求**：这一段必须在任何一次写库**之前**。放到后面去
  #    （比如"先把账号认出来再验签"）就晚了 —— 认账号那一步本身已经是
  #    攻击者够得着的写操作了。
  #
  # ⚠️ 邮箱取自**包里**（还没验签，所以它此刻是攻击者可控的字符串）。这不要紧：
  #    它的唯一用途是**去取密钥**，而攻击者拿不到受害者的密钥，所以冒用别人的
  #    邮箱只会导致验签失败。反过来"用本地已经登录的那个账号的邮箱"才是错的
  #    —— 那会让 A 的包用 B 的密钥去验。
  email_claim <- tolower(trimws(as.character((b$user %||% list())$email %||% "")))
  if (!nzchar(email_claim)) {
    return(list(ok = FALSE, msg = "包里没有账号邮箱，无法验签"))
  }
  # ★ V16.6 item 1：**把能接受的证明都摆出来，验过哪条算哪条**。
  #
  #   为什么不是"一个签名键、按长度分派算法"（那个写法看着更省事，我第一版
  #   就是那么写的，后来推翻了）：**发件人不知道自己该盖哪一种**。
  #     · 云端能不能验 HMAC，取决于"账号本人最近 12 小时登录过网页版没有"
  #       —— 同步密钥只在密码登录那一刻进内存，服务器不存它，桌面版
  #       **无从得知**；
  #     · 账号有没有绑过公钥，桌面版也看不出来。
  #   一个键 = 发件人必须猜，猜错的症状是**静默失败**。所以桌面版两种都盖：
  #   `sig`（HMAC，64 字符）和 `sig_ed`（Ed25519，128 字符）各占一个键。
  #
  # ⚠️ 三条证明之间**没有强弱次序**，任何一条过了就是本人：一条要私钥，
  #    一条要密码派生的密钥，一条只在"账号还不存在"时适用。所以这里是
  #    "或"，不是"先试 A 不行再降级到 B" —— 后者会让"账号绑了公钥"
  #    这个状态把一台合法的新设备永久挡在门外。
  # ⚠️ 一律用 `[[` 不用 `$`：**list 的 `$` 会做部分匹配**，而本版新加的
  #    三个顶层键彼此是前缀关系 —— 包上只有 `sig_ed` 时 `b$sig` 会返回
  #    **`sig_ed` 的值**，只有 `claim_sig` 时 `b$claim` 会返回那个字符串。
  #    这一版之前 `sig` 是孤零零一个键，没有这个形状；是加键加出来的坑。
  sig_got <- as.character(b[["sig"]] %||% "")
  sig_ed <- as.character(b[["sig_ed"]] %||% "")
  cl <- b[["claim"]]
  claim_ok <- FALSE      # 这个包有权给 email_claim **建号**吗
  bind_pub <- ""         # 这一包要不要顺手给账号绑上公钥（写库在第 1 步）
  uid_pre <- .dsapp_sync_user_find(email_claim, con)   # 只读 SELECT

  # ---- 证明一：账号绑过的公钥（Ed25519）----------------------------------
  # ★ 只认**库里那把**，绝不看包里的 claim：公钥一旦绑上，它就是这个账号
  #   在所有机器上的身份，包说什么都不该改变这一点。
  pub_stored <- if (!is.na(uid_pre)) .dsapp_sync_user_pubkey(uid_pre, con) else ""
  ok <- nzchar(sig_ed) && nzchar(pub_stored) &&
        isTRUE(dsapp_sync_verify_ed(b, pub_stored))

  # ---- 证明二：密码派生的 HMAC（V13.7 起的老路，判定逻辑一个字没改）-------
  #
  # 没显式给密钥就自己去找。★ 让**这一层**去找，而不是让每个调用方去传：
  # 调用方可能有好几处（惰性应用 / 桌面版拉回包 / 自检），漏掉任何一处就是
  # 一个不验签的入口 —— 而"忘了传参数"这种漏法不会报错，只会静默放行。
  key <- as.character(key %||% "")
  if (!nzchar(key)) key <- dsapp_synckey_get(email_claim)
  hmac_ok <- nzchar(key) && isTRUE(dsapp_sync_verify(b, key))
  if (!ok && hmac_ok) ok <- TRUE

  # ---- 证明三：认领（只在"账号还不存在"时适用）---------------------------
  # 自证：材料里那把公钥，验材料自己的签名，再用它验正文。
  # ⚠️ 这两步的**顺序**不能反：先确认"材料没被改过"，再用材料里那把公钥去
  #    验正文。反过来（先验正文再验材料）等于用一把还没确认归属的钥匙去
  #    开锁 —— 攻击者换掉 claim 里的 hash 就能建出一个"密码由他定"的账号。
  #
  # ★★ 这一条**只在账号不存在时**才算数。账号已经存在、而库里没有它的公钥
  #    （网页版注册的号）时，自证只能证明"造材料的人手里有那把钥匙"，
  #    **证明不了他是这个账号的主人** —— 认了就等于"任何人给自己的账号
  #    认领一次，就能往别人账号里写数据"。那种情况必须走证明一或证明二。
  claim_why <- ""
  if (!ok && is.na(uid_pre) && nzchar(sig_ed) && is.list(cl)) {
    if (!dsapp_sync_claim_verify(cl)) {
      claim_why <- "认领材料没有通过自证校验（可能被中途改过）"
    } else if (!isTRUE(dsapp_sync_verify_ed(b, as.character(cl[["pubkey"]] %||% ""),
                                             field = "sig_ed"))) {
      claim_why <- dsapp_sync_verify_msg(email_claim)
    } else {
      # 材料自证通过 → 这个包有权建号。真正的闸门在后面那一步
      # （.dsapp_sync_user_claim 里还有开关 / 管理员邮箱 / 格式 / 限流四道）。
      claim_ok <- TRUE
    }
  }

  # ---- 顺手绑公钥（只在"已经独立证明过是本人"的前提下）-------------------
  # 场景：账号是先在**网页版**注册的（或者早于本版建的），库里没有公钥。
  # 那桌面版的证明一就永远用不上，只能靠证明二 —— 而证明二要求"本人最近
  # 12 小时内登录过网页版"。等于把一扇隐形的时间窗架在用户脖子上：同步
  # 昨天还好好的，今天就说"账号不在线"。这里在**已经验过密码派生密钥**
  # 的前提下把公钥绑上，此后这台机器走证明一，不再依赖那个窗口。
  #
  # ⚠️ 绑的前提是 `hmac_ok` —— 也就是"来的人知道密码"。自证材料**自己
  #    不算数**（那正是下面那段注释在防的事：自证只证明"造材料的人手里
  #    有那把钥匙"，证明不了他是账号的主人）。材料在这里只提供**公钥**，
  #    采不采纳由那个已经独立成立的证明决定。
  # ⚠️ 这里只**记账不写库**：下面整段必须在所有写操作之前（selftest 钉着
  #    这个顺序），真正的 UPDATE 在第 1 步里做。
  if (hmac_ok && !is.na(uid_pre) && !nzchar(pub_stored) && is.list(cl) &&
      isTRUE(dsapp_sync_claim_verify(cl))) {
    pk <- tolower(trimws(as.character(cl[["pubkey"]] %||% "")))
    # 材料的邮箱必须和这个包声明的邮箱是同一个 —— 否则就是"用 A 的包把
    # B 的公钥绑到 A 账号上"（材料自证只管它自己没被改过，不管它是谁的）。
    if (nzchar(pk) && identical(tolower(trimws(as.character(cl[["email"]] %||% ""))),
                                email_claim)) {
      bind_pub <- pk
    }
  }

  # ---- 一条都没过：按"最可能的原因"给话，而不是笼统一句失败 --------------
  #
  # ★★ 这里最要命的一条：**"没有密钥可验" 和 "有密钥、但验不过" 是两件事**，
  #    绝不能合流。前者是"本人不在线"→ 挂起，包留在收件箱等它登录；后者是
  #    "有人在伪造/中途改了包"→ **硬拒**。
  #    把它们都写成 deferred 的话，一个伪造的包会安安静静躺在收件箱里，
  #    界面上只有一句"等账号登录"—— 而它永远不会自己变红。
  #    （这一版我第一稿就是把这两件事合流了，"验签不过的包被拒收"那条
  #    自检当场变红，报出来的却是"账号不在线，这个包先留着"。）
  if (!ok && !claim_ok) {
    if (nzchar(claim_why)) {
      # 带了认领材料但材料本身没过 —— 那是伪造的形状，不留情面。
      return(list(ok = FALSE, bad_sig = TRUE, email = email_claim,
                  msg = claim_why))
    }
    if (nzchar(key)) {
      # ★ 有密钥可用（调用方传的，或者内存里取到的），而签名没对上。
      #   这就是拒收，没有任何"再等等"的余地。
      return(list(ok = FALSE, bad_sig = TRUE, email = email_claim,
                  msg = dsapp_sync_verify_msg(email_claim)))
    }
    # 走到这里 = 一条密钥都没有：既没有公钥，内存里也没有密码派生的密钥。
    # ★ 下面这段**就是老代码那条 deferred 分支，逐字不变** —— 账号存不存在
    #   都不影响：老版本在"取不到密钥"时一律挂起，这里保持一致。
    #   特地多说一句"这台机器的公钥为什么没被采纳"，否则用户看到的就是
    #   一句"同步失败"，而他唯一能做的重试永远不会好。
    return(list(ok = FALSE, deferred = TRUE, email = email_claim,
                msg = paste0(
                  "账号 ", email_claim, " 不在线，这个包先留在收件箱里等它登录。",
                  if (nzchar(sig_ed) && !is.na(uid_pre) && !nzchar(pub_stored))
                    paste0("\n（这台机器带的公钥没有被采纳：账号是先在网页版",
                           "注册的，服务器上还没有它的公钥。用密码登录一次",
                           "网页版之后再同步，那一次会带上可以独立验证的凭据。）")
                  else "")))
  }

  # ---- 0.5 技能段自己那条签名（V16.6 item 2）----------------------------
  # ★★ 位置是**安全要求**：和主签名一样，必须在任何一次写库之前。技能段
  #    不在主签名的覆盖范围里（那正是本版能不换协议的原因），所以它**必须
  #    自己证明自己** —— 否则任何一个能在中转服务器上写文件的人，都能往
  #    一个合法包里塞一段技能。
  #
  # ★ 判据是**"有段就必须验得过"**：验不过 → 整包拒收，不是"把技能段丢掉
  #   继续"。丢掉的话，攻击者只要让签名故意不过，就能把技能段**抹掉**而
  #   用户毫无察觉（技能悄悄消失，且下一轮水位照推、再也补不回来）。
  #   和主签名那条规矩一致："宁可拒收一个真包，也不能收下一个假包。"
  #
  # ⚠️ 可接受的公钥**取法**：
  #   · 主包靠账号绑过的公钥验过 → 就用那一把（**只认库里那把**，包里
  #     说的一概不算，理由见上面证明一）；
  #   · 账号**还没绑过**公钥 → 才看认领材料里那把，而且要求材料自证通过、
  #     邮箱和信封一致。这两种材料本来就是同一把钥匙的两种来路，
  #     "先绑后同步"和"建号那一次"各占一头。
  skills_pubs <- pub_stored
  if (!nzchar(skills_pubs) && is.list(cl) &&
      isTRUE(dsapp_sync_claim_verify(cl)) &&
      identical(tolower(trimws(as.character(cl[["email"]] %||% ""))),
                email_claim)) {
    skills_pubs <- as.character(cl[["pubkey"]] %||% "")
  }
  if (!is.null(b[["skills"]]) &&
      !isTRUE(dsapp_sync_skills_verify(b, key, skills_pubs))) {
    return(list(ok = FALSE, bad_sig = TRUE, email = email_claim,
                msg = paste0("包里的技能段没有通过验签（可能被中途改过），",
                             "整包拒收。")))
  }

  peer_key <- ""
  # 这个包该挂到本地哪个账号下。NA = 没认出来 —— 会话仍然会被收下，
  # 只是没有归属（sessions.user_id 允许 NULL），以后认出来了还能补。
  local_uid <- NA_integer_
  email <- ""
  n_sess <- 0L; n_msg <- 0L; n_del <- 0L; n_user <- 0L
  # ★ V16.6：这一包**是不是把账号建出来了**。要在返回值里带出去，好让
  #   回包那边知道"这是个新号，刚绑了公钥"（以及让界面能说一句人话）。
  created <- FALSE

  tryCatch({
    # ---- 1. 账号 ----------------------------------------------------------
    # ★ V13.7 item 7：**只认不建**。
    #
    # 原来这里会照着包里的字段给一个没人用过的邮箱**建号**，包括包自己带的
    # pass_salt/pass_hash —— 也就是"投一个包 = 铸一个自己知道密码的账号"。
    # 现在改成：云端已经有这个邮箱才继续，没有就整包拒收。
    #
    # 这是有意的产品行为，不是能力缺失：同步是"我的数据跟着我走"，主语是
    # **一个已经存在的账号**。云端没有这个账号，就说明这个人还没在网页版
    # 注册过 —— 那也谈不上"把数据同步到他的云端账号"。
    u <- b$user
    if (is.list(u) && nzchar(as.character(u$email %||% ""))) {
      email <- trimws(as.character(u$email))
      uid <- .dsapp_sync_user_find(email, con)
      # ★ V16.6 item 1：账号还不存在、而这个包**有权建号**（第 0 步里
      #   认领材料自证通过）→ 建。这里仍然不是"包说什么就建什么"：
      #   .dsapp_sync_user_claim 里还有开关 / 管理员邮箱 / 格式 / 限流四道闸，
      #   而且写进去的 is_admin 是**字面量 0**。
      if (is.na(uid) && isTRUE(claim_ok)) {
        made <- .dsapp_sync_user_claim(b[["claim"]], email, cfg = cfg, con = con)
        if (isTRUE(made$ok)) {
          uid <- as.integer(made$uid)
          created <- TRUE
        } else {
          # 建号没成（闸门关着 / 格式不对 / 限流 / 邮箱刚被抢注）。
          # ★ 这里**仍然回 no_account**：对桌面版来说"没建成"和
          #   "云端没有这个账号"是同一件事 —— 要走的下一步都是同一句话
          #   （用同一个邮箱去网页版注册，或者让管理员打开开关）。
          #   分成两个返回码的话，桌面版那边要认两个码，而漏认一个的
          #   症状是"同步失败但没有任何提示"。
          return(list(ok = FALSE, no_account = TRUE, email = email,
                      claim_denied = TRUE,
                      msg = dsapp_sync_claim_msg(email,
                               made$msg %||% "原因不明")))
        }
      }
      if (is.na(uid)) {
        return(list(ok = FALSE, no_account = TRUE, email = email,
                    msg = paste0(
                      "云端还没有 ", email, " 这个账号，这个包没有应用。",
                      "请先用**同一个邮箱**在网页版注册一次，然后再同步 —— ",
                      "同步是把数据送到你的云端账号里，云端得先有这个账号。")))
      }
      # ★ V16.6：第 0 步认定"该给这个账号绑公钥"（HMAC 已经证明来者知道
      #   密码，包里的材料自证且邮箱对得上）→ 在这里补上写库。
      #   绑完之后这台机器走证明一，不再要求"本人最近 12 小时登录过网页版"。
      #   ⚠️ 只在库里**还没有**公钥时绑，绝不覆盖 —— 覆盖 = 一台新设备可以
      #      顶掉旧设备的身份。
      if (nzchar(bind_pub)) {
        # ⚠️ SQL 里再拦一道 `sync_pubkey = ''`：第 0 步读到"没有公钥"和
        #    这里写下去之间隔着几行别的代码，中间真插进来另一个包的话，
        #    没有这个条件就会**覆盖**掉刚绑好的那把。
        try(DBI::dbExecute(con,
              "UPDATE users SET sync_pubkey = ?, sync_claimed_at = ?, sync_claimed_from = ? WHERE id = ? AND sync_pubkey = ''",
              params = list(bind_pub, dsapp_now(), peer, as.integer(uid))),
            silent = TRUE)
        try(dsapp_audit("sync.bind_pubkey", user_id = as.integer(uid),
                        target = email, detail = paste0("来自节点 ", peer)),
            silent = TRUE)
      }
      n_user <- 1L
      local_uid <- uid
      peer_key <- dsapp_sync_peer_key(peer, email)
      # 对端自己的 users.id 也要记下来：桌面版下次推的包里，会话行
      # 是挂在它的 uid 上的，认不出来就把对话挂到 NULL 账号上了。
      .dsapp_sync_map_put(peer, "user", as.character(u$id %||% email), uid, con)
    }
    if (!nzchar(peer_key)) {
      # 包里没有账号信息（**服务器回给桌面的包里就没有** —— 客户端不需要
      # 服务器替它建号，服务器的账号清单更不该往客户端走）。
      #
      # 那就用"发送方的节点 + 空的账号位"当键。水位照样存得下来，只是
      # 同一台机器上的多个本地账号会共用一行 —— 这是这段降级路径的已知
      # 代价，而它只在"对端没带 user 字段"时才会走到。
      peer_key <- dsapp_sync_peer_key(peer, "_")
    }

    # ---- 1.5 技能（V16.6 item 2）-----------------------------------------
    # ★ 位置：**必须在会话之前**。技能段里的 `links`（对话挂了哪些技能）
    #   两端都是出身坐标，会话那一头要等第 2 步落地才解析得了 ——
    #   但技能**本体**没有这个依赖，而先把技能铺好，第 3 步的消息、
    #   以及后面任何要读技能的地方都不会撞上空窗。
    # ⚠️ `b[["skills"]]` 不是 `b$skills`：本版新加的 `skills_sig` /
    #    `skills_sig_ed` 和它是前缀关系，`$` 会部分匹配（见 R/skills.R
    #    文件头那条警告）。
    sk_res <- tryCatch(
      dsapp_skills_apply(b[["skills"]], peer, local_uid, cfg = cfg, con = con),
      error = function(e) {
        message("[dsapp] 技能段应用失败：", conditionMessage(e))
        list(n = 0L, links = list(), skipped = 0L, high = "", high_del = "")
      })
    n_skills <- as.integer(sk_res$n)
    # ⚠️ 水位取的是**包里报的那两个**，不是"应用成功的那些行"——
    #    和论坛段一个口径：有行应用失败时，最坏情况只是重传一次（幂等吸收），
    #    而按"应用成功的"推会把失败那几行**永久跳过**。
    sk_hi     <- as.character(sk_res$high %||% "")
    sk_hi_del <- as.character(sk_res$high_del %||% "")

    # ---- 2. 会话 ----------------------------------------------------------
    sess_map <- list()   # 对端会话 id -> 本地会话 id
    me <- dsapp_sync_node_id(cfg)
    for (s in b$sessions %||% list()) {
      oid <- as.character(s$id %||% "")
      if (!nzchar(oid)) next
      title <- as.character(s$title %||% "")
      cat_ <- as.character(s$created_at %||% dsapp_now())
      uat <- as.character(s$updated_at %||% cat_)
      # ★ 这一行的**出身**。老包（v1）没有这两个字段 → 当成"就是发件人造的"，
      #   那正是 v1 的语义（v1 的包里只会有发件人自己造的行）。
      onode <- trimws(as.character(s$origin_node %||% ""))
      if (!nzchar(onode)) onode <- peer
      ooid <- trimws(as.character(s$origin_id %||% ""))
      if (!nzchar(ooid)) ooid <- oid

      if (identical(onode, me)) {
        # ★★ **这一行是我自己造的，绕了一圈回来了。**
        #
        # 不插入、不改映射 —— origin_id 就是我本地的主键，直接按它找。
        # 这一步就是整套防回声的地基：V13.3 那次"对话翻倍"，根因是回推的
        # 包里带的是**中间那台的本地 id**，原造者认不出来只好再插一遍。
        # 现在身份跟着行走，原造者一眼认出是自己。
        #
        # ⚠️ 认出来之后走的是 merge（LWW），不是"跳过"。因为对端可能确实
        #    改过标题（它在自己的副本上重命名了）—— 那是合法的更新，该收。
        # ⚠️ 本地已经没有这一条（我自己删了）就**什么都不做**：我删它是我的
        #    决定，不能因为别人手上那份还在就把它复活。
        if (.dsapp_sync_session_exists(ooid, con)) {
          .dsapp_sync_session_merge(ooid, title, uat, con)
        }
        sess_map[[.dsapp_sync_skey(onode, ooid)]] <- ooid
        n_sess <- n_sess + 1L
        next
      }

      lid <- .dsapp_sync_map_get(onode, "session", ooid, con)
      if (is.na(lid) || !.dsapp_sync_session_exists(lid, con)) {
        # 本地没有 → 插一条。
        #
        # ⚠️ 归属优先用**会话自己带的 user_id**（对端那个账号的 id），
        #    翻不出映射才退到"这个包的账号"。反过来（一律用包账号）在
        #    "一台机器上两个账号往同一台服务器同步"时会串号：B 账号推上来
        #    的对话，会被挂到 A 账号名下。
        #
        # ⚠️ 用 `onode` 而不是 `peer` 去翻：转发的会话上这两个不是一回事。
        #    中转那台机器把 A 的会话转给我时，包里的 user_id 是**中转台**的
        #    本地 uid，所以映射要按中转台的节点查 —— 而 onode 在"会话由 A 造、
        #    由 B 转"这种情况下是 **A**，会话自己带的 user_id 也是 A 的 uid。
        #    两边必须用同一个节点去查，用错了就是 NA，会话挂到 NULL 账号上。
        uid <- NA_integer_
        if (!is.null(s$user_id) && nzchar(as.character(s$user_id))) {
          uid <- .dsapp_sync_map_get(onode, "user", as.character(s$user_id), con)
        }
        if (is.na(uid)) uid <- local_uid
        lid <- .dsapp_sync_session_insert(uid, title, cat_, uat, con)
        if (is.na(lid)) next
        .dsapp_sync_map_put(onode, "session", ooid, lid, con)
      } else {
        # 本地有 → 比 updated_at，谁新听谁的（last-writer-wins）。
        .dsapp_sync_session_merge(lid, title, uat, con)
      }
      sess_map[[.dsapp_sync_skey(onode, ooid)]] <- lid
      n_sess <- n_sess + 1L
    }

    # ---- 2.5 挂载关系（V16.6 item 2）-------------------------------------
    # ★ 必须**在会话之后**：它两端都是出身坐标，会话那一头只有到这一步
    #   才落进 sync_map。见 R/skills.R 文件头第六节。
    # ⚠️ 解析不出来的**不报错也不记"处理过了"** —— 技能可能被截断在下一包
    #   里。这里刻意不推任何水位（理由写在 dsapp_skills_links_apply 上面）。
    n_links <- tryCatch(
      dsapp_skills_links_apply(sk_res$links, con = con),
      error = function(e) 0L)

    # ---- 3. 消息 ----------------------------------------------------------
    for (m in b$messages %||% list()) {
      oid <- as.character(m$id %||% "")
      soid <- as.character(m$session_id %||% "")
      if (!nzchar(oid) || !nzchar(soid)) next
      # 消息自己的出身（和它所属会话的出身**不是一回事**：B 在 A 的对话里
      # 接着聊，消息的出身是 B，会话的出身还是 A）。
      monode <- trimws(as.character(m$origin_node %||% ""))
      if (!nzchar(monode)) monode <- peer
      moid <- trimws(as.character(m$origin_id %||% ""))
      if (!nzchar(moid)) moid <- oid
      # 这条消息挂在哪条会话下 —— 用**会话的**出身（session_node/session_id）。
      snode <- trimws(as.character(m$session_node %||% ""))
      if (!nzchar(snode)) snode <- peer

      if (identical(monode, me)) {
        # 我自己造的消息绕回来了：origin_id 就是我本地的主键。消息只追加、
        # 从不修改，所以**本地有就跳过、没有也不插入**。
        #
        # ⚠️ "没有也不插入"是有意的：本地没有 = 我自己把它删了（或者它的
        #    父会话被删过）。这时候补插回去，用户会看到删掉的对话里冒出
        #    几条消息。宁可少，不要多。
        next
      }

      lid <- .dsapp_sync_map_get(monode, "message", moid, con)
      if (!is.na(lid) && .dsapp_sync_message_exists(lid, con)) {
        n_msg <- n_msg + 1L
        next   # 消息只追加、从不修改，已经有的就不用再写一遍
      }
      sid <- sess_map[[.dsapp_sync_skey(snode, soid)]]
      if (is.null(sid)) {
        sid <- .dsapp_sync_map_get(snode, "session", soid, con)
      }
      # ⚠️ 我自己的会话：它的本地主键就是 origin_id，不用查映射。
      if ((is.null(sid) || is.na(sid)) && identical(snode, me) &&
          .dsapp_sync_session_exists(soid, con)) {
        sid <- soid
      }
      # ⚠️ 会话行必须已经存在。messages.session_id 是全库**唯一**的外键
      #    （db.R:160，ON DELETE CASCADE），父行不在就是一句
      #    "FOREIGN KEY constraint failed"。包里的顺序保证了会话先来，
      #    但一个手工拼的包可能不是 —— 所以这里再挡一道。
      #
      # ⚠️ is.null 和 is.na 都要判。`sess_map[[soid]]` 拿不到时是 NULL，
      #    而 `is.na(NULL)` 是 logical(0)，`if (logical(0))` 直接抛
      #    "argument is of length zero" —— 报错点在离原因最远的地方。
      if (is.null(sid) || length(sid) != 1 || is.na(sid) ||
          !.dsapp_sync_session_exists(sid, con)) next
      new_id <- .dsapp_sync_message_insert(
        sid, as.character(m$role %||% "user"),
        as.character(m$content %||% ""),
        if (is.null(m$reasoning)) NULL else as.character(m$reasoning),
        as.character(m$created_at %||% dsapp_now()), con)
      if (!is.na(new_id)) {
        .dsapp_sync_map_put(monode, "message", moid, new_id, con)
        n_msg <- n_msg + 1L
      }
    }

    # ---- 4. 墓碑 ----------------------------------------------------------
    for (t in b$tombstones %||% list()) {
      kind <- as.character(t$kind %||% "")
      rid <- as.character(t$id %||% "")
      if (!identical(kind, "session") || !nzchar(rid)) next
      # 墓碑带的是**被删那一行的出身**（谁造的、在那边是几号），不是我
      # 本地 id —— 所以一句 sync_map 查询就能翻出"那我该删我这边哪一条"。
      tnode <- trimws(as.character(t$node %||% ""))
      if (!nzchar(tnode)) tnode <- peer   # v1 老包：没有 node，就是发件人造的
      # ★ **我自己造的行，别人删了他手上那份，不能连我这儿一起删。**
      #
      # 这一条很容易想反，所以记清楚：墓碑的语义是"**我这份不要了**"，
      # 不是"这一行从世界上消失"。A 造的会话，B 手上有一份、B 删了 ——
      # 那只是 B 不要了，A 那边该留着。转发链上如果没有这道闸，B 删一次
      # 就能把源头 A 的对话删掉，而 A 什么都没做。
      #
      # ⚠️ 代价：B 那边执行 `purge` 之后，下一轮同步 A 又会把它推回给 B
      #    （A 手上那份还在）。所以"删除"在**转发来的**副本上不是永久的,
      #    它会自己长回来。这是有意的取舍：宁可让 B 多删一次，也不能让
      #    B 的一条删除动作去动 A 的数据。要彻底支持它得引入"墓碑也转发"
      #    的规则，那是另一件事。
      if (identical(tnode, me)) next
      lid <- .dsapp_sync_map_get(tnode, "session", rid, con)
      if (is.na(lid)) next
      # ⚠️ 走 .dsapp_sync_session_purge 而不是 db_session_delete()：
      #    后者会**再记一条本地墓碑**，于是"应用对端的删除"变成"我也删了
      #    一条"，下一轮又发回给对端 —— 两台机器之间来回弹，永远停不下来。
      .dsapp_sync_session_purge(lid, con)
      n_del <- n_del + 1L
    }
    # ★ V16.6 item 2：技能墓碑。它们**不在**这个数组里 —— 在技能段自己的
    #   `dels` 里（理由：那个数组和水位是绑死的，混进来就要共用一条水位，
    #   而技能和会话是两条时间线）。所以这里单独收一次。
    # ⚠️ 位置还是**这一步**：它和会话墓碑共用同一道闸（"我自己造的行，
    #   别人删了他手上那份，不连我这儿一起删"），放在一起才看得出这层关系。
    #   ⚠️ 技能的**应用顺序**也在这里 —— 它是"删"，和正文的"写"分开，
    #   谁先谁后都不会让状态不一致（删除用 id，不用内容）。
    n_del <- n_del + tryCatch(
      dsapp_skills_tombstones_apply(b[["skills"]][["dels"]], peer,
                                    me = me, con = con),
      error = function(e) 0L)

    # ---- 5. 论坛（V15 item 8）--------------------------------------------
    # ★ 放在**水位之前**、墓碑之后。位置不敏感（论坛不依赖会话/墓碑，
    #   它自己的行身份是自带的），但必须在水位那一段之前 —— 论坛段的水位
    #   是从**应用结果**里取的。
    #
    # ⚠️ 论坛段**不看 email / local_uid**：它是公共的，账号认不出来照样收。
    #   这是有意的 —— 一个还没在云端注册过的桌面用户推上来的帖子，
    #   也不该因此丢掉（他自己的会话会被 no_account 整包拒收，论坛部分
    #   因为走的是同一个包，实际上也到不了这一步；这条注释是给以后
    #   "把论坛拆成独立包"的人看的）。
    frm_res <- tryCatch(
      dsapp_forum_apply(b$forum, peer, cfg = cfg, con = con),
      error = function(e) {
        message("[dsapp] 论坛段应用失败：", conditionMessage(e))
        list(n_threads = 0L, n_posts = 0L, n_marks = 0L, skipped = 0L)
      })
    n_forum <- as.integer(frm_res$n_threads + frm_res$n_posts + frm_res$n_marks)
    # ⚠️ 论坛的水位不在这里推。它用的是**包里带的最新 updated_at**
    #    （dsapp_forum_section_high），而不是应用成功的那些行 —— 这两者
    #    在有行应用失败时会分叉。放在这里推会让"失败那一行"被跳过，
    #    而放在下面统一推、用包里的值，最坏情况只是重传一次（幂等吸收）。
    f_hi <- dsapp_forum_section_high(b$forum)

    # ---- 6. 推水位 --------------------------------------------------------
    hi <- ""
    for (s in b$sessions %||% list()) {
      v <- as.character(s$updated_at %||% "")
      if (nzchar(v) && v > hi) hi <- v
      v <- as.character(s$created_at %||% "")
      if (nzchar(v) && v > hi) hi <- v
    }
    t_hi <- ""
    for (t in b$tombstones %||% list()) {
      v <- as.character(t$at %||% "")
      if (nzchar(v) && v > t_hi) t_hi <- v
    }
    st <- dsapp_sync_state_get(peer_key, con)
    dsapp_sync_state_set(peer_key, con,
      in_at = if (hi > (st$in_at %||% "")) hi else st$in_at,
      in_del = if (t_hi > (st$in_del %||% "")) t_hi else st$in_del,
      # ★ 论坛**单独一行水位**，不和上面两个混（理由见 R/db.R 里 sync_state
      #   那段 ALTER 的注释：混在一起会让论坛永远同步不全，且不报错）。
      in_forum = if (f_hi > (st$in_forum %||% "")) f_hi else (st$in_forum %||% ""),
      # ★ V16.6 item 2：技能段的**两条**（正文 / 墓碑），同样各自一行。
      #   漏了墓碑那一条的后果是"删掉的技能下一轮又回来"。
      in_skills = if (sk_hi > (st$in_skills %||% "")) sk_hi
                  else (st$in_skills %||% ""),
      in_del_skills = if (sk_hi_del > (st$in_del_skills %||% "")) sk_hi_del
                      else (st$in_del_skills %||% ""),
      last_at = dsapp_now(),
      note = sprintf("%s 送来 会话%d 消息%d 删除%d 论坛%d",
                     peer, n_sess, n_msg, n_del, n_forum))
    # 返回值里带上 peer / email / local_uid / req_from：服务器那边要拿它们
    # 回包（.dsapp_sync_reply）。少一样都回不了 —— 尤其是 req_from，
    # 它就是"对方手上有什么"，没有它只能整库回一遍。
    list(ok = TRUE, peer_key = peer_key, peer = peer, email = email,
         local_uid = local_uid, account_created = created,
         req_from = as.character(b$req_from %||% ""),
         req_from_del = as.character(b$req_from_del %||% ""),
         req_from_forum = as.character(b$req_from_forum %||% ""),
         # ★ V16.6 item 2：技能段的**两条**请求水位，从段里读（不在顶层）。
         #   ⚠️ 必须用 `[[`：`b$skills` 在"只有 skills_sig"时会部分匹配到
         #   那个签名字符串，而 `["req_from"]` 对字符串取下标会报错。
         req_from_skills = as.character(
           (b[["skills"]] %||% list())[["req_from"]] %||% ""),
         req_from_del_skills = as.character(
           (b[["skills"]] %||% list())[["req_from_del"]] %||% ""),
         n_sess = n_sess, n_msg = n_msg, n_del = n_del, n_user = n_user,
         n_forum = n_forum, forum_high = f_hi, forum_skipped = frm_res$skipped,
         n_skills = n_skills, n_links = n_links, skills_high = sk_hi)
  }, error = function(e) {
    list(ok = FALSE, msg = paste0("应用失败：", conditionMessage(e)))
  })
}

# ---- 应用用的底层写操作 ----------------------------------------------------
#
# 单独一组，不复用 db.R 里那几个 —— db.R 的那几个都带副作用（db_message_add
# 会 db_session_touch、db_session_delete 会记墓碑），同步路径上要的是
# **不带副作用**的版本，否则会成环或者把水位推乱。

.dsapp_sync_session_exists <- function(id, con) {
  if (is.null(id) || length(id) != 1 || is.na(id) || !nzchar(as.character(id))) {
    return(FALSE)
  }
  r <- tryCatch(DBI::dbGetQuery(con, "SELECT 1 FROM sessions WHERE id = ?",
                                params = list(as.character(id))),
                error = function(e) NULL)
  !is.null(r) && nrow(r) > 0
}

.dsapp_sync_message_exists <- function(id, con) {
  if (is.null(id) || length(id) != 1 || is.na(id)) return(FALSE)
  r <- tryCatch(DBI::dbGetQuery(con, "SELECT 1 FROM messages WHERE id = ?",
                                params = list(as.integer(id))),
                error = function(e) NULL)
  !is.null(r) && nrow(r) > 0
}

#' 插一条同步过来的会话
#'
#' ★ **必须自己生成 id**，不能让 SQLite 分配 —— sessions.id 是
#'   `TEXT PRIMARY KEY`（见 db.R 里 sync_map 那段注释），而 SQLite 对
#'   TEXT 主键**不会自动赋值**。不带 id 的 INSERT 在这里是**成功**的、
#'   id 是 NULL、`RETURNING id` 给回一个 NA：一句报错都没有，只是库里
#'   多了一批没有主键、谁也查不到的对话。
#'
#' ★ 还要防撞号：dsapp_id() 是"秒级时间戳 + 4 位随机数"（R/utils.R:762），
#'   同一秒内建 100 个对话就有约 12% 的概率撞上一个 —— 而这里可能一口气
#'   插 200 条（DSAPP_SYNC_MAX_SESSIONS）。所以撞了就重试，而不是
#'   INSERT OR REPLACE（那会**覆盖掉本地已有的那个对话**，比报错糟得多）。
.dsapp_sync_session_insert <- function(user_id, title, created_at, updated_at, con) {
  for (attempt in 1:20) {
    sid <- dsapp_id("s")
    ok <- tryCatch({
      DBI::dbExecute(con,
        "INSERT INTO sessions (id, title, created_at, updated_at, user_id)
         VALUES (?, ?, ?, ?, ?)",
        params = list(sid, title, created_at, updated_at,
                      if (is.na(user_id)) NA_integer_ else as.integer(user_id)))
      TRUE
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(sid)
  }
  NA_character_
}

.dsapp_sync_session_merge <- function(local_id, title, updated_at, con) {
  cur <- tryCatch(DBI::dbGetQuery(con,
    "SELECT title, updated_at FROM sessions WHERE id = ?",
    params = list(as.character(local_id))), error = function(e) NULL)
  if (is.null(cur) || !nrow(cur)) return(invisible(FALSE))
  # LWW：只看 updated_at。相等就不动 —— 相等时"不动"比"改"安全，
  # 因为它保证了反复同步同一批数据不会产生新的写入（也就不会把对方的
  # updated_at 又推高，形成两边互相刷新时间的活锁）。
  if (!(updated_at > (cur$updated_at[1] %||% ""))) return(invisible(FALSE))
  try(DBI::dbExecute(con, "UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?",
                     params = list(title, updated_at, as.character(local_id))),
      silent = TRUE)
  invisible(TRUE)
}

.dsapp_sync_message_insert <- function(session_id, role, content, reasoning,
                                       created_at, con) {
  tryCatch({
    r <- DBI::dbGetQuery(con,
      "INSERT INTO messages (session_id, role, content, reasoning, created_at)
       VALUES (?, ?, ?, ?, ?) RETURNING id",
      params = list(as.character(session_id), role, content,
                    if (is.null(reasoning) || !nzchar(reasoning)) NA_character_
                    else reasoning, created_at))
    as.integer(r$id[1])
  }, error = function(e) NA_integer_)
}

#' 删一个会话及其从属行，**不记墓碑**
#'
#' ⚠️ 和 db_session_delete() 的区别只有一条，但那条是致命的：这里**不写
#'    sync_tombstone**。写了的话，"应用对端的删除"就变成"我也删了一条"，
#'    下一轮同步又把这条墓碑发回给对端 —— 两台机器之间来回弹，永远停不下来。
.dsapp_sync_session_purge <- function(id, con) {
  id <- as.character(id)
  try(DBI::dbExecute(con, "DELETE FROM messages WHERE session_id = ?",
                     params = list(id)), silent = TRUE)
  try(DBI::dbExecute(con, "DELETE FROM sessions WHERE id = ?",
                     params = list(id)), silent = TRUE)
  invisible(TRUE)
}

#' 按邮箱找一个**已经存在**的本地账号；没有就返回 NA
#'
#' ★ V13.7 item 7：这个函数**原来叫 .dsapp_sync_user_ensure，而且会建号**。
#'   建号的依据是包自己带的字段 —— 包括 pass_salt / pass_hash。也就是说，
#'   任何能往收件箱里放一个 JSON 的人，都能给一个没人用过的邮箱**铸一个
#'   自己知道密码的账号**。当时那条注释（"找到就什么都不改"）防的是**改**
#'   已有账号的密码，那一条确实防住了；但**建**新号那一路是完全敞开的，
#'   而它比改密码更省事 —— 不用知道任何东西，挑个邮箱就行。
#'
#'   现在只认不建：云端没有这个邮箱，整包拒收，并明确告诉用户"请先用同一个
#'   邮箱在网页版注册一次"。同步是"我的数据跟着我走"，主语得先存在。
#'
#' ⚠️ 顺带把**密码材料彻底移出了同步包**（DSAPP_SYNC_USER_COLS 里不再有
#'    pass_salt / pass_hash）。没有这条路径之后，让它们过网就只剩坏处了：
#'    没有任何一处再需要它们，而它们是对端密码散列的全部原料。
#'
#' ⚠️ 邮箱比较**必须 tolower**。users.email 上有唯一索引，但索引是按存入的
#'    原样比的（SQLite 默认 BINARY 排序规则），所以 "A@x.com" 和 "a@x.com"
#'    在库里是**两行**。这里的 tolower 是为了和登录路径用同一把尺子 ——
#'    登录那边是 dsapp_user_norm_email 归一过的。
.dsapp_sync_user_find <- function(email, con) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email)) return(NA_integer_)
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT id FROM users WHERE lower(email) = ? ORDER BY id LIMIT 1",
    params = list(email)), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NA_integer_)
  as.integer(r$id[1])
}

#' 取一个账号绑定的同步签名公钥（没有返回 ""）
#'
#' ★ 公钥**不是秘密** —— 它天生就是公开的，泄漏它不产生任何能力。所以
#'   它不进任何密钥加密的范畴（和 users.llm_api_key 那几列不是一回事），
#'   也不需要像 dsapp_synckey_* 那样只放内存。真正要守住的是**私钥**，
#'   而私钥从头到尾只存在于客户端那台机器上，服务器见不到。
.dsapp_sync_user_pubkey <- function(uid, con) {
  uid <- suppressWarnings(as.integer(uid))
  if (length(uid) != 1L || is.na(uid)) return("")
  r <- tryCatch(DBI::dbGetQuery(con,
    "SELECT sync_pubkey FROM users WHERE id = ?", params = list(uid)),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return("")
  tolower(trimws(as.character(r$sync_pubkey[1] %||% "")))
}

#' 同步包**能不能**给这个邮箱建号
#'
#' ★ V16.6 item 1 起，这个问题的答案**不再是常量**了 —— 用户要的是
#'   「Windows 本地版注册的邮箱号能在网页版直接登录」，那件事只能靠
#'   "云端认账、把号建出来"实现。但它是**有条件的**：
#'
#'     · 闸门关着（默认）→ FALSE，行为与 V13.7 起**逐字相同**；
#'     · 闸门开着 → TRUE，但仍要过 `.dsapp_sync_user_claim()` 那一串检查
#'       （自证签名、格式、管理员邮箱、限流），**并且级别一律写 0**。
#'
#' ⚠️ 这个名字保住了原样，是**故意的**：它是"同步不建号"这件事在自检里
#'    可断言的那个名字（原来那行注释说的）。现在自检拿它断言两件事 ——
#'    闸门关时一如既往地 FALSE，闸门开时才 TRUE。名字里带 `may` 而不是
#'    `will`，正是因为它从此是个**条件**。
.dsapp_sync_may_create_account <- function(cfg = dsapp_config(),
                                           con = dsapp_db(cfg)) {
  isTRUE(dsapp_sync_allow_create(cfg = cfg, con = con))
}

#' 按一份认领材料建号（V16.6 item 1）—— 这条路是**唯一**能给同步包建号的地方
#'
#' ★ 为什么不叫 `_ensure`：`_ensure` 是 V13.7 删掉的那个"照单建号"的名字，
#'   自检里有一条断言专门盯着"仓库里不许再出现那个名字"（它代表的行为是
#'   "包说什么就建什么"）。这条路恰恰相反 —— 它有四道闸，而且**级别写死**。
#'
#' 调用前提：**验签已经过了**（见 dsapp_sync_apply_bundle 第 0 步）。
#' 本函数自己再做的四件事：
#'
#'   1. **闸门**（DSAPP_SYNC_ALLOW_CREATE）关着就拒 —— 默认关上；
#'   2. **管理员邮箱不许认领**。这一条不是洁癖：库里一个账号都没有时
#'      "第一个账号自动是平台管理员"（R/users.R 的 is_first），而这条路
#'      **显式绕开了**那个提权口（写死 is_admin = 0）。于是如果允许认领
#'      `.Renviron` 里点名的那种管理员邮箱，就会出现一个"占着管理员邮箱、
#'      却不是管理员"的行 —— 之后本人想注册会被唯一索引挡住，**永久死锁**。
#'   3. 格式校验（`.dsapp_sync_claim_check`）；
#'   4. 限流。
#'
#' @param cl 包里的 `claim` 段（**已验签**）。
#' @return list(ok, uid, msg)
.dsapp_sync_user_claim <- function(cl, email_claim, cfg = dsapp_config(),
                                   con = dsapp_db(cfg)) {
  if (!isTRUE(.dsapp_sync_may_create_account(cfg = cfg, con = con))) {
    return(list(ok = FALSE, denied = TRUE,
                msg = "云端没有开启「允许同步建号」"))
  }
  ck <- .dsapp_sync_claim_check(cl, email_claim)
  if (!isTRUE(ck$ok)) return(list(ok = FALSE, msg = ck$msg))

  # 管理员邮箱：拒。理由见上面第 2 条。
  if (ck$email %in% dsapp_admin_emails()) {
    dsapp_audit("sync.claim_refuse_admin", target = ck$email,
                detail = "邮箱在 DSAPP_ADMIN_EMAIL 名单里", ok = FALSE,
                cfg = cfg, con = con)
    return(list(ok = FALSE,
                msg = "这个邮箱在服务器的管理员名单里，不能由同步包建号"))
  }

  # 限流：同一个来源节点在窗口内最多建 N 个号。
  #
  # ⚠️ 说清楚它的定位：这**不是**防抢注（抢注是拦不住的，见
  #    dsapp_sync_allow_create 的文档），只是"别让一个脚本一晚上灌一万行
  #    users"。真正的出口是那个开关和审计，别指望这条限流。
  #    也**不要**顺手给网页版注册也加一条 —— 那边没有限流是另一件事，
  #    在这里单独加会给人一种"注册已经防住了"的错觉。
  n_recent <- tryCatch(DBI::dbGetQuery(con,
    "SELECT COUNT(*) AS n FROM users
      WHERE sync_claimed_from = ? AND sync_claimed_at > ?",
    params = list(as.character(cl[["node"]] %||% ""),
                  dsapp_ago(3600)))$n[[1]], error = function(e) 0L)
  if (isTRUE(n_recent >= 20L)) {
    dsapp_audit("sync.claim_refuse_rate", target = ck$email,
                detail = sprintf("来源节点 %s 一小时内已建 %d 个",
                                 cl[["node"]] %||% "", as.integer(n_recent)),
                ok = FALSE, cfg = cfg, con = con)
    return(list(ok = FALSE, msg = "这个来源节点建号太频繁了，请稍后再试"))
  }

  uid <- dsapp_user_create_from_sync(
    email = ck$email, salt = ck$salt, hash = ck$hash,
    nickname = ck$nickname, phone = ck$phone, field = ck$field,
    pubkey = as.character(cl[["pubkey"]] %||% ""),
    from_node = as.character(cl[["node"]] %||% ""), con = con)
  if (is.na(uid)) {
    # 走到这儿最可能的原因是"刚好有人抢先建了这个邮箱"（本人正在网页版
    # 注册），或者写入失败。两种都不该往外抛错。
    return(list(ok = FALSE, msg = "建号没有成功（这个邮箱可能刚刚已经被注册了）"))
  }

  # ★ 给被建号的那个邮箱发一封信。这是**抢注唯一的出口**：拦不住，
  #   但要让本人知道。发信失败不影响建号（dsapp_mail_enqueue 自己吞异常）。
  try(dsapp_mail_enqueue(ck$email,
        subject = "你的邮箱被用于创建了一个账号",
        body_md = paste0(
          "有人用这个邮箱在服务器上创建了账号（通过同步包）。\n",
          "如果这是你自己做的，忽略这封信即可。\n",
          "如果不是你，请立刻联系服务器管理员 —— 有人可能正在使用你的邮箱。\n",
          "来源节点：", cl[["node"]] %||% "（未知）", "\n",
          "时间：", dsapp_now()),
        con = con), silent = TRUE)

  list(ok = TRUE, uid = uid)
}

# ---- 回包（服务器把数据送回给桌面版）--------------------------------------

#' 给刚收到的那一包回一个包，放进 outbox/<对端>/
#'
#' 桌面版是**推完顺手拉**：它往 inbox 放一个包，然后去 `outbox/<它的节点>/`
#' 取回包。服务器这边没有请求-响应，回包是**应用完请求之后顺手生成**的 ——
#' 所以这个函数必须紧跟在 apply 后面调（见 dsapp_sync_maybe_apply）。
#'
#' ★ 水位从哪儿来：从**请求包自己带的** `req_from` / `req_from_del`。这就是
#'   那两个字段存在的全部理由（见 dsapp_sync_build_bundle）。所以在服务器上
#'   回包**不需要**读它自己的发送水位 —— 它读的是对方报上来的接收水位。
#'
#' @param res dsapp_sync_apply_bundle() 的返回值。
#' @return invisible(TRUE/FALSE)
.dsapp_sync_reply <- function(res, cfg = dsapp_config(), con = dsapp_db(cfg)) {
  if (!isTRUE(res$ok)) return(invisible(FALSE))
  peer <- trimws(as.character(res$peer %||% ""))
  uid <- res$local_uid
  # 认不出账号（或者对端没报账号）就不回：没有账号就没有"同步谁的数据"
  # 这个主语。宁可这一轮什么都不回，也不能回一个装着别人数据的包。
  if (!nzchar(peer) || is.null(uid) || length(uid) != 1 || is.na(uid)) {
    return(invisible(FALSE))
  }

  dst <- file.path(dsapp_sync_outbox(cfg), dsapp_sync_peer_slug(peer))
  dir.create(dst, recursive = TRUE, showWarnings = FALSE)

  # ★ for_node = 对端的节点 id：这一包是**发给它**的，所以别把它自己造的
  #   行回给它（它那边已经有了）。见 dsapp_sync_collect 的 for_node。
  # ★ key = 这个账号的同步密钥。回包也要签 —— 桌面版那边同样要先验签再
  #   应用，否则"服务器→桌面版"这个方向就是敞开的：任何人往 outbox/<节点>/
  #   里放一个包，就能往桌面版的库里塞对话。
  r <- tryCatch(dsapp_sync_build_bundle(
    peer = dsapp_sync_node_id(cfg), user_id = as.integer(uid),
    req_from = res$req_from %||% "", req_from_del = res$req_from_del %||% "",
    # ★ V15 item 8：把对端报上来的论坛水位原样传下去 —— 这就是"论坛段
    #   从哪儿开始发"的全部依据。漏传的话每轮回包都把整个论坛重发一遍，
    #   不报错、只是越同步越慢（V13.3 在 req_from 上踩过同一个坑）。
    req_from_forum = res$req_from_forum %||% "",
    # ★ V16.6 item 2：技能段的**两条**水位，同样原样传下去 —— 这就是
    #   "技能段从哪儿开始发"的全部依据。漏传的话每轮回包都把整个技能库
    #   重发一遍，不报错、只是越同步越慢（V13.3 在 req_from 上踩过同一个坑）。
    req_from_skills = res$req_from_skills %||% "",
    req_from_del_skills = res$req_from_del_skills %||% "",
    cfg = cfg, con = con, out_dir = dst, for_node = peer,
    key = dsapp_synckey_get(res$email %||% "")), error = function(e) NULL)
  if (is.null(r) || !isTRUE(r$ok)) return(invisible(FALSE))

  # 记一下"我给这个桌面发了什么"。纯记账：回包的内容不是靠它算的（靠
  # 对方报的 req_from），所以它错了也不会同步错，只是设置页上显示的数字
  # 对不上。别为了它加任何失败路径。
  key <- dsapp_sync_peer_key(peer, res$email %||% "")
  st <- dsapp_sync_state_get(key, con)
  try(dsapp_sync_state_set(key, con,
    out_at = if ((r$high_water %||% "") > (st$out_at %||% "")) r$high_water
             else st$out_at,
    out_del = if ((r$high_water_del %||% "") > (st$out_del %||% ""))
                r$high_water_del else st$out_del,
    out_forum = if ((r$high_water_forum %||% "") > (st$out_forum %||% ""))
                  r$high_water_forum else (st$out_forum %||% ""),
    # ★ V16.6 item 2：技能段的两条（正文 / 墓碑），各占一行水位。
    out_skills = if ((r$high_water_skills %||% "") > (st$out_skills %||% ""))
                   r$high_water_skills else (st$out_skills %||% ""),
    out_del_skills = if ((r$high_water_del_skills %||% "") >
                         (st$out_del_skills %||% ""))
                       r$high_water_del_skills else (st$out_del_skills %||% ""),
    last_at = dsapp_now(),
    note = sprintf("已回 会话%d 消息%d 删除%d 论坛%d 技能%d",
                   r$n_sessions, r$n_messages, r$n_del, r$n_forum %||% 0L,
                   r$n_skills %||% 0L)), silent = TRUE)
  invisible(TRUE)
}

# ---- 惰性应用（服务器那边的钩子）------------------------------------------

.dsapp_sync_seen <- new.env(parent = emptyenv())

#' 有新的收件箱文件就应用掉；没有就立刻返回
#'
#' 这个函数会被**每次会话渲染**调用，所以它必须便宜到无感：正常情况下
#' 就是一次 `list.files()`。真正的开销（读 JSON、写库）只在真有新包时发生。
#'
#' @param force 忽略进程内缓存，强制扫一遍（自检和"立即同步"用）
#' @return invisible(应用了几个包)
dsapp_sync_maybe_apply <- function(cfg = dsapp_config(), force = FALSE) {
  d <- dsapp_sync_inbox(cfg)
  if (!dir.exists(d)) return(invisible(0L))

  fs <- tryCatch(list.files(d, pattern = "\\.json$", full.names = TRUE),
                 error = function(e) character(0))
  if (!length(fs)) return(invisible(0L))

  # 进程内去重：文件名 + 大小 + mtime 拼成指纹，和上次一样就跳过。
  # ⚠️ 不能只记文件名 —— 收件箱里的文件名可能被复用（同一个 peer 在同一秒
  #    又推了一个包），只比名字会把第二个包当成"已经处理过"。
  fp <- paste(basename(fs), file.size(fs), as.numeric(file.mtime(fs)),
              sep = "|", collapse = "\n")
  if (!isTRUE(force) && identical(.dsapp_sync_seen[["fp"]], fp)) {
    return(invisible(0L))
  }
  .dsapp_sync_seen[["fp"]] <- fp

  n <- 0L
  # 有包"这次没成、但以后可能成"时置位（挂起 / 验签不过）。见下面指纹那一段。
  retry_any <- FALSE
  for (f in fs) {
    r <- tryCatch(dsapp_sync_apply_file(f, cfg), error = function(e) NULL)
    if (!is.null(r) && isTRUE(r$deferred)) {
      retry_any <- TRUE
      # 记一笔给设置页看：用户推完了却"什么都没发生"时，得有个地方能告诉他
      # 是"等网页版登录"，而不是让他以为同步功能坏了。
      try({
        k <- dsapp_sync_peer_key(dsapp_sync_node_id(cfg), r$email %||% "")
        # ⚠️ 别写 `cfg = cfg` —— dsapp_sync_state_set() 的第三个参数是 `...`，
        #    cfg 会当成一个**字段名**塞进去（写入时被忽略，纯属误导），
        #    而且 `as.character(cfg)` 万一碰上不能强转的类型会抛异常，
        #    整个 note 写不进去 —— 还被 try() 吞掉。
        dsapp_sync_state_set(k, con = dsapp_db(cfg),
                             note = sprintf("有包在等 %s 登录网页版",
                                            r$email %||% ""))
      }, silent = TRUE)
    }
    if (!is.null(r) && isTRUE(r$bad_sig)) {
      # ★ 验签不过的包**也要留痕**，理由和上面那条一样、但更急：它是
      #   "两边密码不一样"或"有人在往这个账号里塞东西"的**唯一**线索。
      #   不留痕的话，用户看到的就是"同步说成功了，对话一条没变"——
      #   和"这个功能本来就是坏的"长得一模一样，而真正该做的动作（把两边
      #   的密码改成同一个）他永远猜不到。
      #
      #   ⚠️ 这里写的是**短**提示：它会被塞进设置页那行
      #      `上次同步：…（<note>）` 的括号里，把 dsapp_sync_verify_msg 那段
      #      多行解释整段搬过来会把那一行撑烂。完整说法在 push 那一侧。
      retry_any <- TRUE
      try({
        k <- dsapp_sync_peer_key(dsapp_sync_node_id(cfg), r$email %||% "")
        dsapp_sync_state_set(k, con = dsapp_db(cfg),
                             note = sprintf(
          "有个包没通过校验、没有应用（多半是 %s 在两边的密码不一样）",
          r$email %||% ""))
      }, silent = TRUE)
    }
    if (!is.null(r) && isTRUE(r$ok)) {
      n <- n + 1L
      # ★ 应用完**顺手回一个包**。桌面版是"推完就去 outbox 拉"，而服务器
      #   这边没有任何东西会主动跑 —— 不回包的话桌面版永远拉到一个空目录，
      #   表现是"推上去了，但服务器上的对话下不来"，两边都不报错。
      try(.dsapp_sync_reply(r, cfg), silent = TRUE)
      # 应用成功就挪进 applied/。挪而不是删：出问题时 applied/ 里还留着
      # 原始包可以复现，而且"这个包到底应用过没有"这件事有据可查。
      dst <- file.path(dsapp_sync_inbox_applied(cfg), basename(f))
      if (!isTRUE(file.rename(f, dst))) {
        try(file.copy(f, dst, overwrite = TRUE), silent = TRUE)
        try(unlink(f), silent = TRUE)
      }
      # ★ V16.6：归档之前把认领材料抹掉（口令校验器不在盘上过夜）。
      #   放在**归档之后**、不是应用之前 —— 应用那一步要读它。
      .dsapp_sync_scrub_claim(dst)
    } else if (!is.null(r) && isTRUE(r$self)) {
      # 自己发的包（两边目录配错时会出现）。挪走，免得每轮都重试。
      try(file.rename(f, file.path(dsapp_sync_inbox_applied(cfg),
                                   paste0("SELF_", basename(f)))), silent = TRUE)
    }
    # ok=FALSE 且不是 self 的包**留在原地**：它可能是"应用时数据库正忙"，
    # 下一轮值得再试。一直失败的话它会一直躺在那儿 —— 这是有意的，
    # 静默丢掉一个应用不了的包比留着更糟。
    #
    # ★ 验签失败（bad_sig）的包**也留在原地**，和上面同一个理由 —— 但
    #   要清楚它和"数据库正忙"不是一回事：它是**不会自己好的**，会一直躺在
    #   那儿。留着是有意的：它是"有人在往这个账号里塞东西"的唯一物证，
    #   自动删掉等于把证据清了。而且密码改对之后，同一个包是能通过的。
  }

  # ★★ 有包"这次没成、但以后可能成"时**必须作废指纹缓存**。
  #
  # 指纹（文件名+大小+mtime）是用来"没变化就别重复扫"的。但这两件事的变化
  # **不在文件里** —— 文件一个字节都没动，变的是"账号本人上线了，现在有
  # 密钥了"（挂起），或者"用户把两边的密码改成同一个了"（验签不过）。
  # 指纹不变 → 下一轮直接返回 0 → 那个包**永远不会被重试**，直到有别的包
  # 进来把指纹顶掉。表现是"我明明登录了网页版 / 明明把密码改一样了，桌面
  # 推上去的东西还是没下来"，而且刷新多少次都一样。
  if (retry_any) .dsapp_sync_seen[["fp"]] <- NULL
  invisible(n)
}

# ---- 高层：跑一轮完整同步 --------------------------------------------------

#' 跑一轮同步（桌面版那边调）
#'
#' 一轮 = 推自己的 + 拉对端的 + 应用拉回来的。
#'
#' 顺序是 **先推后拉**，不是随便定的：包里的 `req_from` 告诉服务器"我已经
#' 收到哪了"，服务器据此决定回什么。先拉的话，拉回来的是按**上一轮**的
#' 水位算的回复，永远慢一拍。
#'
#' @param target 形状同 R/remote.R 的 target（list(remote = list(host=,
#'   user=, port=, auth=, password=, key_text=))）。由调用方从会话内存里的
#'   凭据现拼 —— 见 R/mod_settings.R：凭据不落盘。
#' @param email 当前登录账号的邮箱。同步是"我的数据跟着我走"。
#' @param user_id 对应的本地账号 id。
#' @param remote_dir 服务器上的同步目录（绝对路径）。留空用默认值。
#' @param key 同步签名密钥（dsapp_sync_key() 现推的那份）。留空则按邮箱去
#'   内存表里取 —— 但**后台子进程里一定取不到**（那是另一个进程），
#'   走 dsapp_sync_worker 那条路时必须显式传。
#' @return list(ok, msg, pushed, pulled, applied, ...)
dsapp_sync_now <- function(target, email, user_id, remote_dir = "",
                           cfg = dsapp_config(), con = dsapp_db(cfg),
                           key = NULL) {
  email <- tolower(trimws(email))
  node <- dsapp_sync_node_id(cfg)

  prep <- dsapp_ssh_ctx(target, cfg)
  if (!isTRUE(prep$ok)) return(list(ok = FALSE, msg = prep$msg))
  ctx <- prep$ctx
  on.exit(dsapp_ssh_cleanup(ctx), add = TRUE)

  # ⚠️ 工作目录必须显式给。应用目录不一定是可写的（线上是 /srv 下的软链），
  #    而同步的临时文件应该待在 data_root 下 —— 和库、钥匙串同一个地方，
  #    备份/清理的口径才一致。
  root <- dsapp_sync_root(cfg)
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  dsapp_sync_mkdirs(cfg)

  # ---- 远端目录 -----------------------------------------------------------
  # 会合目录是**服务器的 data_root/sync**，不是 $HOME 下的什么位置 ——
  # 为什么（应用跑在 shiny 用户下、ssh 进来的是另一个用户，两个 $HOME
  # 根本不是同一个目录）见文件头第五节。所以这个路径只能让用户填一次。
  remote_root <- trimws(as.character(remote_dir %||% ""))
  if (!nzchar(remote_root)) remote_root <- DSAPP_SYNC_REMOTE_DIR_DEFAULT
  # 必须是绝对路径：scp 会把这段拼进 `host:path`，相对路径的含义取决于
  # ssh 登录时的当前目录 —— 同一个设置在不同轮次可能落到不同地方。
  if (!grepl("^/", remote_root)) {
    return(list(ok = FALSE,
                msg = "远端同步目录要填绝对路径（以 / 开头），比如 /srv/shiny-server/YCFS_APP/data/sync"))
  }
  remote_root <- sub("/+$", "", remote_root)
  remote_inbox <- file.path(remote_root, "inbox")
  remote_outbox_me <- file.path(remote_root, "outbox", dsapp_sync_peer_slug(node))
  # 服务器那边的"已应用"留证目录，只用来做过期清理（是 <远端目录>/inbox/applied/，
  # 不是 outbox 底下的 —— 别跟着 outbox 的相对路径走）。
  remote_applied <- file.path(remote_root, "inbox", "applied")

  # ---- 水位 ---------------------------------------------------------------
  # 两行，各干各的：锚点行（键里不含对端节点，第一次推就有）记"对端是谁"
  # 和发送水位；对端行（键 = 对端节点:邮箱）记接收水位。见 dsapp_sync_anchor_key。
  anchor <- dsapp_sync_anchor_key(remote_root, email)
  a <- dsapp_sync_state_get(anchor, con)
  peer_node <- trimws(a$peer_node %||% "")
  req_from <- ""; req_from_del <- ""; req_from_forum <- ""
  # ★ V16.6 item 2：技能段的**两条**接收水位（正文 / 墓碑）。
  req_from_skills <- ""; req_from_del_skills <- ""
  if (nzchar(peer_node)) {
    stp <- dsapp_sync_state_get(dsapp_sync_peer_key(peer_node, email), con)
    req_from <- stp$in_at %||% ""
    req_from_del <- stp$in_del %||% ""
    # ★ V15 item 8：论坛的接收水位。⚠️ 第一次同步时 peer_node 是空的，
    #   这里就取不到 —— 于是 forum 水位是空串，服务器把**整个论坛**发过来。
    #   这是对的（第一次本来就该全量），而且论坛比对话小得多。
    req_from_forum <- stp$in_forum %||% ""
    # ★ V16.6 item 2：技能段那两条。同论坛那一条：第一次同步时
    #   peer_node 是空的，这里取不到 —— 那是**对的**（第一次本来就该全量）。
    req_from_skills <- stp$in_skills %||% ""
    req_from_del_skills <- stp$in_del_skills %||% ""
  }

  # ---- 1. 打包 + 推送 -----------------------------------------------------
  # ★ 同步密钥（V13.7 item 7）。优先用调用方传进来的（会话里现推的那份），
  #   没传就按邮箱从内存表里取。两个来源都没有 = 这个人当前没有有效的登录
  #   态 —— 那就**不发**：没有密钥签不出包，发出去对面也会拒收。
  sk <- as.character(key %||% "")
  if (!nzchar(sk)) sk <- dsapp_synckey_get(email)
  if (!nzchar(sk)) {
    return(list(ok = FALSE, need_login = TRUE, msg = paste0(
      "没有可用的同步密钥。同步密钥是从登录密码现推的、只放在内存里 —— ",
      "请重新登录一次（用和网页版相同的密码），然后再同步。")))
  }

  b <- dsapp_sync_build_bundle(peer = node, user_id = user_id,
                               req_from = req_from,
                               req_from_del = req_from_del,
                               req_from_forum = req_from_forum,
                               # ★ V16.6 item 2：技能段的两条水位。
                               req_from_skills = req_from_skills,
                               req_from_del_skills = req_from_del_skills,
                               cfg = cfg, con = con,
                               # ★ 第一次推的时候 peer_node 还是空的 ——
                               #   服务器的节点 id 要等第一个回包才知道。
                               #   那时传空串就是"不知道对端是谁"，collect
                               #   不过滤，多发一些对面自己会认出来的行。
                               for_node = peer_node,
                               key = sk,
                               # ★★ V16.6 item 1：**只在这台服务器还没回过包的时候**
                               #   带认领材料（= 口令校验器）。
                               #
                               #   为什么用 peer_node 当判据：它是**只有服务器回过
                               #   一个包才会被写上**的东西（下面 dsapp_sync_state_set
                               #   那一处）。空 = 从没成功同步过。
                               #     · 云端没这个号 → 第一包带材料 → 建号；
                               #     · 云端有这个号但没绑公钥 → 第一包带材料 →
                               #       服务器那边在 HMAC 验过的前提下把公钥绑上；
                               #     · 建号被拒（开关关着）→ 不会有回包 → peer_node
                               #       一直是空的 → 下轮继续带。这是**故意**的：
                               #       管理员把开关打开之后，用户什么都不用做。
                               #   ⚠️ 代价写明：配对成功之前，那一个包里每轮都带着
                               #      口令校验器。它落在服务器的收件箱里（同一台机器
                               #      上本来就存着 pass_hash 那一列），配对成功后
                               #      归档包里那一段会被服务器抹掉。
                               claim = !nzchar(peer_node))
  if (!isTRUE(b$ok)) return(list(ok = FALSE, msg = b$msg %||% "打包失败"))

  tmpdir <- dirname(b$path)
  bn <- basename(b$path)
  # 对端的目录得先建出来：dsapp_ssh_push 只管往上放文件，不会替你 mkdir
  # （R/remote.R 里没有这一步），目录不在就是一句 scp 的
  # "No such file or directory"，看着像路径拼错了，其实是没建。
  mk <- dsapp_ssh_run(ctx, sprintf(
    "mkdir -p %s %s", shQuote(remote_inbox), shQuote(remote_outbox_me)),
    timeout = 60, cfg = cfg)
  if (!isTRUE(mk$ok)) {
    return(list(ok = FALSE, msg = paste0("远端建目录失败：\n", mk$stderr)))
  }

  up <- dsapp_ssh_push(ctx, tmpdir, remote_inbox, bn, cfg = cfg)
  if (!isTRUE(up$ok)) {
    return(list(ok = FALSE, msg = up$msg %||% "推送失败"))
  }

  # ⚠️ 水位只在**没被截断**时推进。被截断说明这个包只装了一部分，推进等于
  #    把没装进去的行标记成已同步，它们就永远轮不到了（见 build_bundle）。
  #    发送水位记在**锚点行**上（它是"我和这台服务器的关系"，不随对端节点
  #    id 变不变而搬家）。
  if (!isTRUE(b$truncated)) {
    dsapp_sync_state_set(anchor, con,
      out_at = if ((b$high_water %||% "") > (a$out_at %||% "")) b$high_water else a$out_at,
      out_del = if ((b$high_water_del %||% "") > (a$out_del %||% "")) b$high_water_del else a$out_del,
      # ★ V15 item 8：论坛的发送水位，也记在锚点行上（和 out_at 同理 ——
      #   它是"我和这台服务器的关系"，不随对端节点 id 变不变而搬家）。
      out_forum = if ((b$high_water_forum %||% "") > (a$out_forum %||% ""))
                    b$high_water_forum else (a$out_forum %||% ""),
      last_at = dsapp_now(),
      note = sprintf("已推 会话%d 消息%d 删除%d 论坛%d", b$n_sessions,
                     b$n_messages, b$n_del, b$n_forum %||% 0L))
  }

  # ---- 2. 拉回来 ----------------------------------------------------------
  # 服务器是**惰性应用**（见本文件顶部第三节）：它要等下一次有人打开网页版
  # 才会把收件箱吃进去、才会回包。所以这里不去催它，只把**已有的**拉回来；
  # 这一轮拉到的可能是上一次推的回复，这是设计内的。
  local_pull <- file.path(dsapp_sync_tmp(cfg), "pull")
  unlink(local_pull, recursive = TRUE, force = TRUE)
  dir.create(local_pull, recursive = TRUE, showWarnings = FALSE)
  dn <- dsapp_ssh_pull(ctx, remote_outbox_me, local_pull, cfg = cfg)
  # 拉失败不算整轮失败：推已经成功了，那才是主要目的。远端 outbox 可能
  # 压根还不存在（第一次同步时服务器那边什么都还没建）。
  pulled <- 0L
  done_f <- character(0)   # 应用成功的那些（下面要在远端挪走）
  if (isTRUE(dn$ok)) {
    got <- list.files(file.path(local_pull, basename(remote_outbox_me)),
                      pattern = "\\.json$", full.names = TRUE)
    if (!length(got)) {
      got <- list.files(local_pull, pattern = "\\.json$", full.names = TRUE)
    }
    for (f in got) {
      # ★ 在这里认"对端是哪台机器"。回包的 `node` 字段就是服务器的节点 id，
      #   拿到之后写进锚点行 —— 下一轮 req_from 才找得到地方读（接收水位
      #   在"对端行"里，键要用节点 id 拼）。
      #
      #   为什么不放在 dsapp_sync_apply_bundle 里顺手写：那里不知道锚点的键
      #   （锚点的键里有"远端目录"，那是桌面版才有的概念，服务器没有）。
      bb <- tryCatch(
        jsonlite::fromJSON(paste(readLines(f, warn = FALSE), collapse = "\n"),
                           simplifyVector = FALSE),
        error = function(e) NULL)
      pn <- trimws(as.character(bb$node %||% ""))
      if (nzchar(pn) && !identical(pn, node)) {
        dsapp_sync_state_set(anchor, con, peer_node = pn)
        if (!identical(pn, peer_node)) {
          peer_node <- pn
          a <- dsapp_sync_state_get(anchor, con)
        }
      }
      # ★ key 必须显式传：这一段跑在同步子进程里（dsapp_sync_worker），
      #   子进程的内存密钥表是空的 —— 不传的话每一份回包都会被判成"账号
      #   不在线"而挂起，然后被下面的 unlink 连临时目录一起删掉。表现是
      #   "推上去了，回包也拉下来了，就是应用不上"，而且一声不响。
      r <- tryCatch(dsapp_sync_apply_file(f, cfg, con, key = sk),
                    error = function(e) NULL)
      if (!is.null(r) && isTRUE(r$ok)) { pulled <- pulled + 1L; done_f <- c(done_f, basename(f)) }
    }

    # ★ 应用过的回包要在**服务器上**挪进 sent/，不能只删本地那份。
    #   不挪的话它们会一直躺在 outbox/<我>/ 里，下一轮被整个拉一遍、
    #   再应用一遍（幂等，所以不会出错 —— 只是每轮都在重放全部历史，
    #   同步会一轮比一轮慢，而且服务器上的目录只涨不消）。
    #   和收件箱那边的 applied/ 是同一个约定：挪走留证，不删。
    #
    # ⚠️ 只挪**应用成功**的那些。失败的（坏 JSON 之类）留在原地，
    #    下一轮还会被拉下来重试 —— 静默丢掉一个应用不了的包比留着更糟。
    #
    # 顺手给 sent/ 和 applied/ 做个保留期。这两边的 .json 里是**明文的对话
    # 内容**，不能无限期堆在一台共享服务器上；出问题要复现的话，留半年也
    # 足够了（和墓碑一个尺度）。
    #
    # ⚠️ applied/ 不在 outbox/<我>/ 底下，它是 <远端目录>/inbox/applied/
    #    （R/sync.R:229）—— 别跟着 cd 之后的相对路径走。
    # 全程用绝对路径，不 cd —— cd 失败（目录还没建）时那条 `exit 0` 会把
    # 后面的清理一起跳过，而清理恰恰是唯一不需要目录存在的那件事。
    remote_sent <- file.path(remote_outbox_me, "sent")
    mv_cmd <- if (length(done_f)) {
      sprintf("for f in %s; do mv -f %s/\"$f\" %s/ 2>/dev/null; done; ",
              paste(shQuote(done_f), collapse = " "),
              shQuote(remote_outbox_me), shQuote(remote_sent))
    } else ""
    try(dsapp_ssh_run(ctx, sprintf(
      "mkdir -p %s; %s find %s %s -maxdepth 1 -name '*.json' -mtime +%d -delete 2>/dev/null; exit 0",
      shQuote(remote_sent), mv_cmd,
      shQuote(remote_applied), shQuote(remote_sent), DSAPP_SYNC_TOMBSTONE_DAYS),
      timeout = 60, cfg = cfg), silent = TRUE)
    unlink(local_pull, recursive = TRUE, force = TRUE)
  }

  list(ok = TRUE, node = node, anchor = anchor, peer_node = peer_node,
       pushed = 1L, pulled = pulled,
       n_sessions = b$n_sessions, n_messages = b$n_messages, n_del = b$n_del,
       truncated = isTRUE(b$truncated),
       msg = sprintf("已推送 会话 %d / 消息 %d；取回 %d 个包",
                     b$n_sessions, b$n_messages, pulled))
}

#' 后台同步的子进程入口（给 dsapp_bg_start 用）
#'
#' ⚠️ 为什么必须走子进程：一次同步要 scp 好几个来回，几十秒很正常，而
#'    **全站只有一个 R 进程**（Shiny Server 开源版，见 R/jobs.R 顶部）。
#'    在主进程里同步跑 = 全站所有人一起卡住，正是 R/health.R:26 那段注释
#'    骂的写法。dsapp_bg_start 就是为这类事建的。
#'
#' ⚠️ `cfg` 必须**显式传进来**，不能让子进程自己 `dsapp_config()`。
#'    R/jobs.R:36-54 记过这个事故：子进程读的是**当前工作目录**的
#'    .Renviron，而它的优先级高于继承来的环境变量 —— 于是父子两个进程
#'    各算各的 data_root。那次的表现是"任务成功但产物不见了"，
#'    放到同步上就是"同步成功了，但同步的是另一个库"。
#'
#' ⚠️ 参数必须是能被 serialize 的纯数据（cfg 是个普通 list，可以）。
#'    这里也不能引用 session / reactive。
dsapp_sync_worker <- function(cfg, target, email, user_id, remote_dir = "",
                              key = NULL) {
  con <- tryCatch(dsapp_db(cfg), error = function(e) NULL)
  if (is.null(con)) return(list(ok = FALSE, msg = "子进程连不上库"))
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  # ★ `key` 必须由**父进程显式传进来**，子进程里现取是取不到的：
  #   同步密钥表（R/synckey.R 的 .dsapp_synckey）是**进程内存**，而这里跑的
  #   是一个全新的 R 进程 —— 它的表是空的。
  #
  #   ⚠️ 这个漏法非常隐蔽：子进程里 dsapp_synckey_get() 老老实实返回 ""，
  #      然后 build_bundle 报"没有可用的同步密钥"，用户看到的是"明明刚登录，
  #      一同步就说要重新登录"。而主进程里直接调（自检、非后台路径）却是好的。
  #      和 R/jobs.R:36-54 记的那个"子进程读的是当前工作目录的 .Renviron"
  #      是同一类事故：**父子进程的环境不是同一个**。
  dsapp_sync_now(target, email, user_id, remote_dir = remote_dir,
                 cfg = cfg, con = con, key = key)
}

#' 同步状态摘要（给设置页显示）
#'
#' @param remote_dir 和 dsapp_sync_now 用同一个值 —— 锚点行的键里有它，
#'   给别的值会读到另一行（表现是"刚同步完，设置页还显示从没同步过"）。
dsapp_sync_status <- function(email, remote_dir = "", cfg = dsapp_config(),
                              con = dsapp_db(cfg)) {
  node <- dsapp_sync_node_id(cfg)
  remote_root <- trimws(as.character(remote_dir %||% ""))
  if (!nzchar(remote_root)) remote_root <- DSAPP_SYNC_REMOTE_DIR_DEFAULT
  anchor <- dsapp_sync_anchor_key(remote_root, email)
  a <- dsapp_sync_state_get(anchor, con)
  pn <- trimws(a$peer_node %||% "")
  stp <- if (nzchar(pn)) {
    dsapp_sync_state_get(dsapp_sync_peer_key(pn, email), con)
  } else {
    list(in_at = "", in_del = "", in_forum = "",
         in_skills = "", in_del_skills = "")
  }
  nb <- tryCatch({
    d <- dsapp_sync_inbox(cfg)
    if (dir.exists(d)) length(list.files(d, pattern = "\\.json$")) else 0L
  }, error = function(e) 0L)
  list(node = node, anchor = anchor, peer_node = pn,
       state = a, in_at = stp$in_at %||% "", in_del = stp$in_del %||% "",
       # V15 item 8：论坛那一路的接收水位（设置页的同步摘要里显示，
       # 用户能一眼看出"论坛到底同步了没有"）。
       in_forum = stp$in_forum %||% "",
       # V16.6 item 2：技能段那两条（设置页的同步摘要里显示，用户能一眼
       # 看出"技能到底同步了没有"）。
       # ⚠️ 这两条是**技能正文**和**技能墓碑**两种进度，不是"技能和别的"。
       in_skills = stp$in_skills %||% "",
       in_del_skills = stp$in_del_skills %||% "",
       pending_inbox = nb, root = dsapp_sync_root(cfg),
       remote_dir = remote_root)
}
