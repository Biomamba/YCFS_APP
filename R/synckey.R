# ============================================================================
# R/synckey.R —— 同步包的签名密钥（V13.7 item 7）
#
# 用户原话：「记得要做好用户的安全性与私密性保障」。
#
# ---------------------------------------------------------------------------
# 一、要挡的是什么
# ---------------------------------------------------------------------------
# 同步的会合点是一个**文件目录**（<服务器的 data_root>/sync/inbox/），投包的
# 动作就是往那个目录里放一个 .json。在那个目录里，"谁放的"这件事**没有任何
# 凭据** —— 包自己说它是谁，那就是谁。
#
# 于是有两条攻击路，成本都很低，都不需要登录进这套应用：
#
#   (A) **铸号**：包里带一个没人用过的邮箱 + 自己挑的 pass_salt/pass_hash，
#       接收端会照着这个把账号建出来。攻击者于是凭空得到一个自己知道密码的
#       账号 —— 而"邮箱是唯一索引"这条防线只保护**已存在**的账号。
#       → 这一条已经从根上去掉了：见 R/sync.R 里 DSAPP_SYNC_USER_COLS 的注释
#         和 .dsapp_sync_user_find（不再建号），密码材料根本不过网。
#
#   (B) **顶别人的号**：包里填**受害者**的邮箱。接收端认得这个邮箱（账号
#       确实存在），于是把包里那批对话挂到受害者名下 —— 攻击者不但能把内容
#       塞进别人的账号，还能从回包里**把受害者的对话读回来**（回包放在
#       outbox/<攻击者的节点>/）。
#       → 这一条**只能靠签名挡**，就是本文件存在的理由。
#
# ---------------------------------------------------------------------------
# 二、密钥从哪儿来：两边都有的、且攻击者没有的那个东西
# ---------------------------------------------------------------------------
# 桌面版和服务器之间没有任何天然的共享秘密：账号是按邮箱认的，两台机器上
# 同一邮箱的 pass_salt 是**各自随机生成**的（见 dsapp_pw_hash 的说明），
# 算出来的 pass_hash 天生不同。SSH 凭据也不行 —— 那是部署账号的，应用
# 进程（shiny 用户）根本看不到。
#
# 唯一"两边都知道、且只有本人知道"的东西就是**密码本身**。所以密钥是
# **从密码现推的**：
#
#     sync_key(邮箱, 密码) = dsapp_pw_hash(密码, "dsapp-sync-v1|" + 邮箱)
#
# ★ 复用 dsapp_pw_hash 那条 1000 轮 sha256 的链，不另造一个 KDF。好处是
#   "强度"这件事只有一处定义：哪天把轮数抬上去，登录和同步一起变强，不会
#   出现"登录加固了、签名还是旧强度"这种查不出来的落差。
#
# ★ 那个前缀是**域分离**，不是装饰：它保证同步密钥和登录用的 pass_hash
#   是两个不同的值（盐不同 → 链不同），所以任何一个泄漏都不牵连另一个。
#
# ★ 两边都**不存它**：服务器在用户登录那一刻推出来、放进程内存；桌面版
#   在同步那一刻从会话里现推（同步本来就是登录状态下点的）。落盘的只有
#   各自那份带随机盐的 pass_hash，而它推不出同步密钥（盐不一样）。
#
# ⚠️ 代价，写在这儿免得以后当成 bug 查：**两边的密码必须一样**。用户在
#    桌面版用 A 密码注册、在网页版用 B 密码注册，两边推出来的密钥就不同，
#    签名验不过。这不是"同步坏了"，是"这两台机器本来就证明不了是同一个人"。
#    所以验签失败时的提示必须把这条说出来（见 dsapp_sync_verify 的文档），
#    不能让用户面对一句没头没脑的"同步失败"。
#
# ---------------------------------------------------------------------------
# 三、为什么敢只放内存：用户代码读不到主进程的内存
# ---------------------------------------------------------------------------
# 必须先说清楚这台机器上真实的隔离强度，否则"只放内存"看着像敷衍：
# R/executor.R:9-11 写明了「应用以 shiny 用户运行，代码也在 shiny 身份下
# 执行」—— 用户提交的分析代码**和主进程同一个 uid**，而且 shiny 对
# data_root 整棵树有 rwx（deploy_link.sh:126 的 setfacl）。
#
# 所以：**任何落盘的密钥都等于公开**。写个 0600 的文件也没用，读它的和写它
# 的是同一个 uid。这也是为什么不能用"服务器上存一个配对密钥"那套常见做法。
#
# 但用户代码**不在主进程里跑**：它走 callr::r_bg（R/jobs.R:115）起一个全新
# 的 R 进程。Linux 的 ptrace 默认受 yama 限制（/proc/sys/kernel/yama/
# ptrace_scope = 1），**子进程不允许 ptrace 它的祖先**。所以那个子进程读不到
# 主进程的地址空间 —— 密钥只要不出主进程，它就够不着。
#
# ⚠️ 这是一个**部署前提**，不是代码保证：ptrace_scope 必须是 1 或 2。
#    被改成 0（`echo 0 > /proc/sys/kernel/yama/ptrace_scope`）之后，同 uid
#    的进程可以互相读内存，这条防线就没了。deploy_link.sh 的预检里有断言。
#
# ⚠️ 还要说清楚它**挡不住什么**：拿到代码执行权的人照样能直接读
#    dsapp.sqlite3（同一个 uid）。那时候对话内容已经被看光了，签名再严也
#    没有意义。**同步层的签名挡的是"不会写代码、只会改客户端或者拼一个
#    JSON 去 scp"的那一类攻击者** —— 那是现实里成本最低、最可能发生的一类。
#    真要连代码执行一起挡，只有把应用整体放进容器/虚拟机，把 uid 分开
#    （R/executor.R 那段注释说的就是这个，那是另一件事）。
#
# ---------------------------------------------------------------------------
# 四、生命周期
# ---------------------------------------------------------------------------
#   · dsapp_user_auth() 验密成功那一刻 → dsapp_synckey_put(email, key)
#   · 登出 → dsapp_synckey_drop(email)
#   · 每次用到就续一次期（滑动窗口），超过 DSAPP_SYNCKEY_TTL 没人用就作废
#
# ★ 为什么要 TTL 而不是"登出才清"：登出不一定发生（关掉浏览器不算登出，
#   服务端只看得到会话结束）。留一个没人续期的密钥在内存里，等于把"登录过
#   一次"变成"这台机器上永远有效"。滑动过期让它的寿命跟着**实际使用**走。
# ============================================================================

# 密钥在内存里最多留多久（秒），每次用到就续期。
#
# 12 小时：比任何一个正常的连续使用时段都长（不会让人干到一半突然验签失败），
# 又比"永远"短得多。挑一个白班的长度就够 —— 它的作用是"没人用就自己消失"，
# 不是"限制用户能干活多久"。
DSAPP_SYNCKEY_TTL <- 12L * 3600L

# 域分离前缀。**改了它等于换了一套密钥**：所有已配对的机器都要重新登录一次
# 才能继续同步（数据不会丢，只是那一轮推不动）。所以别随手改。
DSAPP_SYNC_KDF_TAG <- "dsapp-sync-v1|"

# 进程内的活跃密钥表：email → list(key, at)。
#
# ⚠️ 用 new.env 而不是 list：这是个**跨会话共享**的表（Shiny Server 开源版
#    全站只有一个 R 进程，见 R/jobs.R 顶部），而 list 在 <<- 赋值时会**复制
#    整个列表**。会话一多，每次登录都要复制一遍全表。
#
# ⚠️ 键特意用**小写邮箱**：登录路径和同步路径拿到的邮箱大小写不一定一致
#    （有 tolower，也有没 tolower 的），用原始串当键会出现"刚登录完，
#    同步说没有密钥"这种只在大小写不同的账号上复现的怪事。
.dsapp_synckey <- new.env(parent = emptyenv())

#' 从密码推出同步签名密钥（两边都算这一个函数）
#'
#' @param password 用户输入的明文密码。**只在内存里过一下，绝不落盘**
#'   （和 R/nodes.R 那条"同步凭据只在会话内存"的策略一致）。
#' @param email 账号邮箱。它是**盐的一部分**，所以两个用户用同一个密码也会
#'   得到两个不同的密钥。
#' @return 64 个字符的十六进制串（sha256 的十六进制形式），可以直接当
#'   HMAC 的密钥用。邮箱或密码为空时返回 `""` —— 调用方要把 `""` 当成
#'   "没有密钥"，**不要**当成"密钥是空串"（那样会算出一个谁都能算的签名）。
dsapp_sync_key <- function(password, email) {
  email <- tolower(trimws(as.character(email %||% "")))
  password <- as.character(password %||% "")
  if (!nzchar(email) || !nzchar(password)) return("")
  dsapp_pw_hash(password, paste0(DSAPP_SYNC_KDF_TAG, email))
}

#' 把一条活跃密钥放进内存表（登录成功时调）
dsapp_synckey_put <- function(email, key) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email) || !nzchar(as.character(key %||% ""))) {
    return(invisible(FALSE))
  }
  assign(email, list(key = as.character(key), at = as.numeric(Sys.time())),
         envir = .dsapp_synckey)
  invisible(TRUE)
}

#' 取一条活跃密钥；没有 / 过期的返回 `""`
#'
#' 取到就**续期**（滑动窗口）：密钥的寿命跟着实际使用走，而不是从登录那一刻
#' 开始倒计时 —— 否则一个开了 12 小时的页面会在某一刻毫无征兆地同步不动。
dsapp_synckey_get <- function(email, touch = TRUE) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email)) return("")
  v <- .dsapp_synckey[[email]]
  if (is.null(v) || !is.list(v)) return("")
  age <- as.numeric(Sys.time()) - as.numeric(v$at %||% 0)
  if (!is.finite(age) || age > DSAPP_SYNCKEY_TTL) {
    # 过期的顺手删掉。不删也不会被取到（上面 age 已经挡住了），但留着会让
    # 内存表只涨不消 —— 一个跑几个月的进程能攒下所有登录过的账号。
    if (exists(email, envir = .dsapp_synckey, inherits = FALSE)) {
      rm(list = email, envir = .dsapp_synckey)
    }
    return("")
  }
  if (isTRUE(touch)) {
    assign(email, list(key = v$key, at = as.numeric(Sys.time())),
           envir = .dsapp_synckey)
  }
  as.character(v$key)
}

#' 丢掉一条密钥（登出时调）
dsapp_synckey_drop <- function(email) {
  email <- tolower(trimws(as.character(email %||% "")))
  if (!nzchar(email)) return(invisible(FALSE))
  if (exists(email, envir = .dsapp_synckey, inherits = FALSE)) {
    rm(list = email, envir = .dsapp_synckey)
  }
  invisible(TRUE)
}

#' 现在有哪些账号的密钥在手上（诊断用，**只返回邮箱，不返回密钥**）
#'
#' ⚠️ 绝不返回密钥本身。这个函数是给设置页/自检看"签名通道通不通"的，
#'    一旦它开始返回密钥，就等于给"把密钥显示在界面上"开了个口子。
dsapp_synckey_emails <- function() {
  e <- ls(envir = .dsapp_synckey)
  # 顺手把过期的清一遍：这个函数是唯一会遍历全表的地方，清理放这儿最省事。
  for (x in e) {
    v <- .dsapp_synckey[[x]]
    age <- as.numeric(Sys.time()) - as.numeric((v %||% list())$at %||% 0)
    if (!is.finite(age) || age > DSAPP_SYNCKEY_TTL) {
      rm(list = x, envir = .dsapp_synckey)
    }
  }
  sort(ls(envir = .dsapp_synckey))
}

# ---- 签名 / 验签 -----------------------------------------------------------

#' 递归归一化一棵 JSON 树（对象键排序、NULL 归一、数组保序）
#'
#' ★ 签名签的是**字节**，不是"意思"。收发两端拿到的是**同一个内容的两种内存
#'   形状**：发端是 R 里现拼出来的 list（比如某条消息 `reasoning = NULL`），
#'   收端是 `fromJSON(simplifyVector = FALSE)` 解析出来的另一棵 list。要让两边
#'   序列化出同一串字节，就得先把它们压成同一种形状 —— 就是这个函数。
#'
#'   三条规则，目标是一个不动点：`canon(parse(canon(x))) == canon(x)`。
#'     · **对象**（有名 list）**按键名排序**：两边字段顺序不一定相同（发端是
#'       代码里写的顺序，收端是文件里的顺序，而文件可能是老版本写的）；
#'     · **NULL 和长度 1 的 NA** 一律归一成 NULL，序列化成 `null`，读回来还是
#'       NULL，再归一还是 `null` —— 稳定。不归一的话，R 里的 NULL 会被
#'       jsonlite 按不同 `null=` 参数写成 `null` 或者干脆**整个字段消失**，
#'       两种形状的字节不同，签名必错；
#'     · **数组**（无名 list）**保持原序**：消息的先后是内容的一部分，排序会
#'       把对话打乱 —— 而且那也是一种"同一份内容有多种合法字节"的自由度，
#'       正是签名最怕的东西。
#'
#' ⚠️ 排序用 `method = "radix"`，**不能用默认的 `order()`**：默认的字符排序
#'    走**当前机器的 locale collation**，而这件事的两端是**两台不同的机器**
#'    （桌面版在 Windows、服务端在 Linux，locale 十有八九不一样）。本机
#'    en_US.UTF-8 实测 `c("a1","a_1","a_b","aB")` 默认排出来是
#'    `a_1 a_b a1 aB`（标点先于字母、大小写不敏感），radix 排出来是
#'    `a1 aB a_1 a_b`（纯字节序）—— 同一台机器上就已经不一致了，换台机器
#'    只会更不一致。排序不同 → 字节不同 → **每一个包都验签失败**，而症状
#'    只是"同步永远不通"，极难往 locale 上想。
#'    radix 对字符是按字节（C locale）排的，跨平台恒定。
#'    当前 payload 里的键名都是小写字母加下划线，两种排法**恰好**一致 ——
#'    但"恰好"不是"保证"，而代价只有六个字符。
#'
#' ⚠️ 输入约定：对象必须是**有名 list**、数组必须是**无名 list**、标量是长度 1
#'    的原子向量。data.frame 在这里没有意义（同步结构里不出现），但真被塞进来
#'    的话下面会把它摊成"列名的对象"，结果同样是确定的 —— 只是别指望它跟
#'    `toJSON` 直接写出来的 data.frame 一致。
.dsapp_sync_canon <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.data.frame(x)) x <- as.list(x)
  if (is.list(x)) {
    nm <- names(x)
    if (is.null(nm) || !any(nzchar(nm))) {
      return(lapply(x, .dsapp_sync_canon))          # JSON 数组：保序
    }
    y <- lapply(x, .dsapp_sync_canon)
    return(y[order(names(y), method = "radix")])    # JSON 对象：键排序
  }
  if (length(x) == 1L && is.na(x)) return(NULL)
  x
}

#' 被签名的那部分内容
#'
#' ★ **显式列字段**，不是"整个包减掉 sig"。这个区别是安全要求：按"整个包
#'   减 sig"签的话，攻击者往包里**加**一个字段（比如以后某版新增的
#'   `force = true`）就能绕过签名 —— 那个字段不在签名覆盖范围内，却是接收端
#'   会读的。显式列出来就堵死了这条路：没列进来的字段，接收端也一律不看。
#'
#' ⚠️ 加字段的规矩：**先加到这里，再加到读取的地方**。反过来的话，新字段
#'    是"能写进去、验签不管、接收端照读"——正是上面那个洞。
#'
#' -----------------------------------------------------------------------------
#' ⚠️⚠️ `data` 是 V13.7 补进来的，补之前这里**只有信封**
#' -----------------------------------------------------------------------------
#' 最早这一版只签了 v/node/sent_at/user/req_from/req_from_del 六个字段 ——
#' 也就是"这个包是谁发的、发给谁的"这层信封，而**真正的内容（sessions /
#' messages / tombstones）一个字节都没签**。
#'
#' 后果是整件事白做：攻击者拿一个**合法签名过的**包（自己的包就行，他也是
#' 用户），把里面的对话内容改掉、签名原样留着，接收端照样验签通过 ——
#' 因为签名覆盖的那六个字段他一个都没动。"顶别人的号"这条路是堵上了，
#' 但"往包里塞/改内容"这条路整个开着，而后者才是这条功能真正要防的东西。
#'
#' 这个洞当时**自检是绿的**：那条断言改的是 A 自己发的包，而 apply_bundle
#' 看到 `node == 我自己` 会在验签之前就early return（"自己的包跳过"），
#' 于是"拒收"这个结果是对的、原因却是错的。**用错误的理由通过的断言比红的
#' 更危险**，它是唯一一种不会催你去查的失败。改签名范围的时候顺手加了一条
#' 用**对端的包**改内容的自检，就是防这个。
#'
#' 教训写成一句话：**签名要覆盖"接收端会读的全部字段"**，信封和数据一样是
#' 被读的字段，缺一个就等于没签。
.dsapp_sync_sig_payload <- function(b) {
  list(
    v            = b$v %||% 0L,
    node         = as.character(b$node %||% ""),
    sent_at      = as.character(b$sent_at %||% ""),
    user         = b$user,
    req_from     = as.character(b$req_from %||% ""),
    req_from_del = as.character(b$req_from_del %||% ""),
    # ★ V15 item 8：论坛段的水位。它和上面两个是同一类东西（**请求**，
    #   不是数据）——告诉对端"论坛我收到哪儿了"。漏签它的后果和漏签
    #   req_from 一模一样：攻击者改一个字就能让对端**少发**一整段论坛内容，
    #   而包里其余部分验签照过。凡是接收端会读的字段都得在这儿。
    req_from_forum = as.character(b$req_from_forum %||% ""),
    # ★ 内容本身。三个集合都用 `%||% list()` 归一：字段缺失和空集合在
    #   "有没有东西"上是一回事，归一到 `[]` 才不会出现"缺字段"和"空数组"
    #   两种字节。里面每一行的字段交给 .dsapp_sync_canon 递归处理。
    data         = list(
      sessions   = b$sessions %||% list(),
      messages   = b$messages %||% list(),
      tombstones = b$tombstones %||% list(),
      # ★ V15 item 8：论坛是**公共段**（所有人共享），和上面三个"我的数据"
      #   不是一回事，但在"被读的字段"这一点上完全一样 —— 所以照样要签。
      #   ⚠️ 加这一段会让 V15 和 V14 **双向都验不过**：签名签的是字节，而
      #   V14 的这个函数里根本没有 forum 这一项（V15 收到 V14 的包时，这里
      #   求值成 `[]`，字节和 V14 签的那份也不同），两边算出来的必然不一样。
      #   **这是有意的、也是必须的**：论坛是一条新的信任边界，让不认识它的
      #   老客户端"忽略掉这一段"，就等于让任何人往包里塞帖子。代价写在
      #   SYNC.md 第九节的升级影响里（自部署 Linux 版改代码即生效；已经发
      #   出去的 Windows 免安装包需要重新分发一次）。
      forum      = b$forum %||% list()
    )
  )
}

#' 序列化成**唯一确定**的字节串
#'
#' 签名签的是字节，不是"意思"—— 同一份内容序列化出两种字节，签名就验不过。
#' 所以收发两端必须用**同一个函数、同一组参数**，任何一边改了参数都是全线
#' 验签失败。这是这个文件里最脆的一处，改它之前先想清楚。
#'
#' ⚠️ `digits = NA` 不能省：默认它会把数字按 4 位有效数字输出，浮点字段
#'    （这一版没有，但包里有 `v` 这种整数）在往返之后可能变成 `1` 和
#'    `1.0000000000000002` 两种形状。
#'
#' ⚠️ `auto_unbox = TRUE` 下"长度 1 的向量"会被拆成标量，而**长度 1 的 list**
#'    仍然是数组（`["a"]`）。两者字节不同 —— 所以归一化那一步不能把标量包成
#'    单元素 list。`.dsapp_sync_canon` 对原子向量是原样返回的，正是为了这个。
#'
#' ⚠️ 整个 payload 都要过 `.dsapp_sync_canon`（不只是 `data`）：信封里
#'    `user` 是嵌套结构，同样有键序和 NULL 两个问题。
.dsapp_sync_canonical <- function(b) {
  jsonlite::toJSON(.dsapp_sync_canon(.dsapp_sync_sig_payload(b)),
                   auto_unbox = TRUE, digits = NA, null = "null")
}

#' 给一个包盖章
#'
#' @param key dsapp_sync_key() 算出来的密钥。空串 = 没有密钥，**拒绝盖章**
#'   （返回 NA）：盖出一个"谁都能算"的签名比不盖更糟 —— 它会让验签那头
#'   以为自己验过了。
#' @return 十六进制签名串；没有密钥时返回 NA_character_
dsapp_sync_sign <- function(b, key) {
  key <- as.character(key %||% "")
  if (!nzchar(key)) return(NA_character_)
  tryCatch(
    digest::hmac(charToRaw(key), as.character(.dsapp_sync_canonical(b)),
                 algo = "sha256", serialize = FALSE, raw = FALSE),
    error = function(e) NA_character_)
}

#' 验一个包签名（**HMAC 那条路**）
#'
#' ★ V16.6：这个函数只认 `b$sig` 这一个键，而且它永远是 HMAC（64 个
#'   十六进制字符）。Ed25519 签名**另占一个键** `b$sig_ed`，走
#'   `dsapp_sync_verify_ed()`。
#'
#'   为什么是"两个键并存"而不是"一个键、按长度分派"：
#'   发件人**常常不知道自己该盖哪一种**。云端到底能不能验 HMAC，取决于
#'   "账号本人最近 12 小时内有没有登录过网页版"（同步密钥只在密码登录那一刻
#'   进内存），这个信息在桌面版这边**不存在**；账号有没有绑过公钥，桌面版
#'   也看不出来。一个键就意味着发件人必须猜，而**猜错的症状是静默失败**。
#'   两个键 = 两种证明都摆上，收件人挑验得过的那个。
#'
#'   兼容性：`sig_ed` 是新的顶层键，**不在** `.dsapp_sync_sig_payload` 的
#'   覆盖范围里，所以老服务器算出来的 HMAC 一个字节都没变 —— 它照样验得过
#'   `b$sig`，只是对 `b$sig_ed` 视而不见。这一条是本版能不换协议的原因。
#'
#' @return TRUE/FALSE。**任何异常都是 FALSE**（宁可拒收一个真包，也不能收下
#'   一个假包 —— 前者用户再同步一次就好，后者是别人的对话进了你的账号）。
dsapp_sync_verify <- function(b, key) {
  # ⚠️ `[[` 不是 `$`：**list 的 `$` 会做部分匹配**。包上只有 `sig_ed` 而
  #    没有 `sig` 的时候，`b$sig` 会返回 **`sig_ed` 那个 128 位的值** ——
  #    于是这一路的 got 是 ed 签名、want 是 64 位 HMAC，长度不等 → 拒。
  #    结果虽然是安全的（fail-closed），但"读到了另一个字段"这种事不该
  #    靠长度恰好不等来兜底：`sig_ed` 一旦也是 64 位就会变成静默错判。
  #    `[[` 只认精确名字，没有这个形状。本版新加的三个顶层键
  #    （sig_ed / claim / claim_sig）彼此都是前缀关系，这个坑是**新引入的**。
  got <- as.character(b[["sig"]] %||% "")
  if (!nzchar(got)) return(FALSE)
  key <- as.character(key %||% "")
  if (!nzchar(key)) return(FALSE)
  want <- dsapp_sync_sign(b, key)
  if (is.na(want)) return(FALSE)
  # 长度不等时 identical 自然判假，不需要单独拦 —— 包括"有人把 ed 签名
  # 塞进 sig 键"这种情况，结果是拒收（fail-closed），正是我们要的。
  identical(got, want)
}

#' 验签失败时给用户看的那句话
#'
#' ★ 必须把**最可能的原因**说出来。只写"同步失败"，用户唯一能做的就是再来
#'   一次，而再来一次结果一样 —— 因为根因是"两边的密码不一样"，重试永远不会
#'   好。这条提示是这条功能能不能被用起来的关键，不是客套话。
dsapp_sync_verify_msg <- function(email) {
  paste0(
    "这个同步包没有通过校验，没有应用。\n",
    "最可能的原因是：桌面版和网页版**用的不是同一个密码**。\n",
    "同步密钥是从密码现推的（服务器不存它），两边密码不同就推不出同一个密钥，",
    "包会被拒收 —— 这是有意的：否则任何人往收件箱里放一个包，就能把内容塞进",
    "你的账号、还能从回包里读走你的对话。\n",
    "请把 ", email, " 在两边改成同一个密码，然后再同步一次。")
}

# ============================================================================
# V16.6 item 1：Ed25519 —— 认领通道（本地注册的账号自动出现在云端）
# ============================================================================
#
# ---------------------------------------------------------------------------
# 一、为什么非得上公钥签名不可
# ---------------------------------------------------------------------------
# 用户要的是「在 Windows 版本地注册的邮箱号，能直接在网页版登录，会话记录
# 也跟着过去」。而云端要**在账号还不存在的那一刻**判断"这个包该不该给它
# 建号" —— 它手里既没有账号行（还没建），内存里也没有密钥（密钥只在**密码
# 登录**那一刻进内存，见 R/users.R:1930）。
#
# 于是包必须自带一份**口令校验器**（pass_salt + pass_hash），否则云端拿不到
# "同一个密码能登录"的能力。这是数学上的硬约束，不是实现选择：云端要么
# 信任这个包（谁都能抢注），要么能**独立验证**这个包确实出自"将来能用这个
# 密码登录的那个人"。
#
# 而"独立验证一个自带校验器的包"只有一条路：**包里的校验器自己是被签名
# 覆盖的，而验证签名用的公钥也在包里**（自证）。这就是 TOFU —— 第一次
# 见到这把钥匙就认它。攻击者当然可以自己造一对钥匙、给任意邮箱发一个包，
# 但那正是"抢注"，跟签名无关，只能用「开关 + 审计 + 通知信」处理
# （见 R/syncservers.R 的 dsapp_sync_allow_create）。
#
# ⚠️ 换 HMAC 是**不安全**的：HMAC 的密钥必须两边都有，而云端此刻没有。
#    把密钥跟着包一起发过去，等于攻击者改完校验器再自己算一个 HMAC ——
#    循环论证，什么也没证明。
#
# ---------------------------------------------------------------------------
# 二、为什么不是"所有包都改用 Ed25519"
# ---------------------------------------------------------------------------
# 只给**认领**这一条路加。已有的同步（账号已存在）**一个字节都不动**，
# 继续走密码现推的 HMAC。三个理由：
#
#   · 老客户端（已经发出去的 Windows 免安装包）必须继续能用。它们发的是
#     64 个字符的 HMAC，长度分派让它们走原路，双向都不受影响。
#   · 服务器**没有私钥**。它给桌面版回包时用的是内存里那份密码派生的
#     HMAC 密钥 —— 那正是"用户登录过网页版"这件事的副产品。新加的
#     Ed25519 私钥只在**客户端**那台机器上，服务器从头到尾见不到。
#   · 改动面越小，能出错的地方越少。这一版的四个工作流已经够大了。
#
# ---------------------------------------------------------------------------
# 三、两种签名各占一个键（`sig` = HMAC，`sig_ed` = Ed25519）
# ---------------------------------------------------------------------------
# ⚠️ 一开始写的是"一个键、按签名长度分派"（64 = HMAC，128 = Ed25519），
#    看着更省事，其实是错的：**发件人不知道自己该盖哪一种**。
#      · 云端能不能验 HMAC，取决于"账号本人最近 12 小时登录过网页版没有"
#        （同步密钥只在密码登录那一刻进内存，服务器不存它）—— 这件事
#        桌面版**无从得知**；
#      · 账号有没有绑过公钥，桌面版也看不出来。
#    一个键 = 发件人必须猜，而**猜错的症状是静默失败**：包发出去了、
#    收件箱里躺着、界面上什么都不说。这正是本仓反复栽的那个形状。
#    两个键 = 把两种证明**都摆上**，收件人挑验得过的那个。
#
# 兼容性（这一条决定了本版能不能不换协议）：
#   `sig_ed` / `claim` / `claim_sig` 都是**新的顶层键**，**不在**
#   `.dsapp_sync_sig_payload` 的覆盖范围里。老接收端算出来的 HMAC 因此
#   一个字节都没变 —— 它照样验得过 `b$sig`，只是对新键视而不见。
#   ⚠️ 反过来说：**往 payload 里加键就是换协议**，V15 加 `forum` 那次
#   让 V15↔V14 双向全挂，就是这条规矩的代价。
#
#   老接收端看不懂 `claim` 会忽略它 —— 而老版本本来也只认不建号，
#   所以"被忽略"在这里恰好是安全的行为。
# ============================================================================

# HMAC-SHA256 十六进制签名的长度
DSAPP_SYNC_SIG_HMAC_LEN <- 64L
# Ed25519 签名的十六进制长度（64 字节）
DSAPP_SYNC_SIG_ED_LEN <- 128L
# 公钥 / 私钥种子的十六进制长度（32 字节）
DSAPP_SYNC_KEY_HEX_LEN <- 64L

#' 原始字节 → 小写十六进制
dsapp_hex_encode <- function(r) {
  if (!length(r)) return("")
  paste(sprintf("%02x", as.integer(r)), collapse = "")
}

#' 小写十六进制 → 原始字节
#'
#' 认不出来（奇数长度、含非十六进制字符）返回 `NULL` —— 调用方**必须**
#' 把 NULL 当成"拒绝"。这里不能"尽量解析"：一个能解析出半截东西的
#' 解码器，配上一个"签名字节少一半也算过"的比较，就是一条静默的绕过。
dsapp_hex_decode <- function(s) {
  s <- tolower(trimws(as.character(s %||% "")))
  if (!length(s) || is.na(s[1])) return(NULL)
  s <- s[1]
  if (!nzchar(s) || nchar(s) %% 2L != 0L) return(NULL)
  if (grepl("[^0-9a-f]", s)) return(NULL)
  as.raw(strtoi(substring(s, seq(1L, nchar(s), 2L),
                          seq(2L, nchar(s), 2L)), 16L))
}

#' 这台机器的同步身份私钥存在哪
#'
#' 放在 data_root 下、**和库、钥匙串同一个地方** —— 备份和清理的口径才一致
#' （R/sync.R 那边给同步临时目录也是这个理由）。
dsapp_sync_identity_path <- function(cfg = dsapp_config()) {
  file.path(dsapp_sync_root(cfg), "identity.key")
}

#' 读这台机器的同步身份（没有就返回 NULL）
#'
#' @return list(seed = <64 位十六进制>, pub = <64 位十六进制>) 或 NULL
#' @return 文件里存的就是一行 64 个十六进制字符（32 字节的 ed25519 种子）。
#'   **存种子不存 PEM**：PEM 好几十个字符、还带换行，而这一份要跟同步包
#'   一起过 scp —— 一行十六进制不会在传输或读写里被换行符咬到。
dsapp_sync_identity <- function(cfg = dsapp_config()) {
  p <- dsapp_sync_identity_path(cfg)
  if (!file.exists(p)) return(NULL)
  seed <- tryCatch(trimws(readLines(p, warn = FALSE)[1] %||% ""),
                   error = function(e) "")
  if (!nzchar(seed) || nchar(seed) != DSAPP_SYNC_KEY_HEX_LEN) return(NULL)
  raw <- dsapp_hex_decode(seed)
  if (is.null(raw) || length(raw) != 32L) return(NULL)
  list(seed = tolower(seed), pub = dsapp_sync_pub_from_seed(seed))
}

#' 从私钥种子算出公钥（64 位十六进制）
#'
#' 算不出来返回 `""`。**任何异常都返回空串**：调用方把空串当"没有身份"，
#' 而绝不把异常往上抛 —— 这条路在同步的热路径上，一个坏掉的钥匙文件
#' 不该让整个同步页面崩掉。
dsapp_sync_pub_from_seed <- function(seed) {
  raw <- dsapp_hex_decode(seed)
  if (is.null(raw) || length(raw) != 32L) return("")
  tryCatch({
    k <- openssl::read_ed25519_key(raw)
    dsapp_hex_encode(as.list(as.list(k)$pubkey)$data)
  }, error = function(e) "")
}

#' 确保这台机器有同步身份（没有就生成一份并落盘）
#'
#' @return list(seed, pub)；生成不出来返回 NULL。
#'
#' ⚠️ 文件权限 0600。**但要说清楚它挡不住什么**：应用和用户的代码同一个
#'    uid（R/executor.R:9-11），所以 0600 挡的是"别的用户"，挡不住"同 uid
#'    的进程"。这条防线真正的价值在**另外一端** —— 服务器从头到尾没有
#'    这把私钥，所以即使服务器的库被整个读走，也伪造不出这个客户端的包。
#'    见文件头第三节。
dsapp_sync_identity_ensure <- function(cfg = dsapp_config()) {
  id <- dsapp_sync_identity(cfg)
  if (!is.null(id)) return(id)
  dir.create(dsapp_sync_root(cfg), recursive = TRUE, showWarnings = FALSE)
  seed <- tryCatch({
    k <- openssl::ed25519_keygen()
    dsapp_hex_encode(as.list(k)$data)
  }, error = function(e) "")
  if (!nzchar(seed) || nchar(seed) != DSAPP_SYNC_KEY_HEX_LEN) return(NULL)
  p <- dsapp_sync_identity_path(cfg)
  ok <- tryCatch({
    writeLines(seed, p)
    Sys.chmod(p, mode = "0600")
    TRUE
  }, error = function(e) FALSE)
  if (!ok) return(NULL)
  list(seed = seed, pub = dsapp_sync_pub_from_seed(seed))
}

#' 用 Ed25519 给一个包盖章
#'
#' 签的还是 `.dsapp_sync_canonical(b)` —— **和 HMAC 那条路逐字节同一份内容**。
#' 两条路只是"用什么东西盖这个章"不同，被盖的那份东西必须一模一样，
#' 否则验签的两端会在"签的是什么"上分家。
#'
#' @return 128 个十六进制字符；没有种子时返回 NA_character_
dsapp_sync_sign_ed <- function(b, seed) {
  raw <- dsapp_hex_decode(seed)
  if (is.null(raw) || length(raw) != 32L) return(NA_character_)
  tryCatch({
    k <- openssl::read_ed25519_key(raw)
    sig <- openssl::signature_create(
      charToRaw(as.character(.dsapp_sync_canonical(b))), key = k)
    dsapp_hex_encode(sig)
  }, error = function(e) NA_character_)
}

#' 验一个 Ed25519 签名的包
#'
#' @param pubkey 64 个十六进制字符的公钥。空 / 认不出来 → FALSE。
#' @param field 签名放在包的哪个键里。默认 `sig_ed`。
#'   ⚠️ **不是 `sig`** —— `sig` 那个键是 HMAC 的地盘，两种签名各占一个键，
#'   谁也盖不着谁（见下面"为什么两个签名并存"）。
#' @return TRUE/FALSE。**任何异常都是 FALSE**（和 dsapp_sync_verify 同一条规矩）。
#'
#' ⚠️ `openssl::signature_verify()` 在验不过时是**抛错**、不是返回 FALSE
#'    （实测：`Error in data_verify(md, sig, pk) : Verification failed`）。
#'    不套 tryCatch 的话，一个伪造的包会让整个同步流程崩在半路 —— 而那正是
#'    攻击者想要的效果（拒绝服务）。所以这里一律 tryCatch 成 FALSE。
dsapp_sync_verify_ed <- function(b, pubkey, field = "sig_ed") {
  pub <- dsapp_hex_decode(pubkey)
  if (is.null(pub) || length(pub) != 32L) return(FALSE)
  got <- dsapp_hex_decode(as.character(b[[field]] %||% ""))
  if (is.null(got) || length(got) != 64L) return(FALSE)
  isTRUE(tryCatch(
    openssl::signature_verify(
      charToRaw(as.character(.dsapp_sync_canonical(b))), got,
      pubkey = openssl::read_ed25519_pubkey(pub)),
    error = function(e) FALSE))
}

# ---- 认领（claim）----------------------------------------------------------

#' 造一份"认领"材料：这台客户端请求云端给它建一个账号
#'
#' @param email 要建的邮箱（归一化后的小写）。
#' @param salt,hash 本地那一行的 pass_salt / pass_hash。**它们就是"两边密码
#'   一致"的全部秘密** —— 云端把这两列原样存进去，用户在网页版用同一个
#'   密码就能登录。
#' @param uid 本地那个账号的 id（对端靠它把会话行归位）。
#'
#' ⚠️ 这是一份**校验器**，不是密码。但它等价于密码的强度：1000 轮 sha256、
#'    `DSAPP_PW_MIN = 6L`。**对弱口令，拿到它等于拿到密码。** 所以：
#'    · 它只在"建号那一个包"里出现一次，此后永不过网；
#'    · 云端落地之后，归档的包里要把这一段抹掉（见 .dsapp_sync_user_claim）。
dsapp_sync_claim_make <- function(email, salt, hash, uid = NULL, nickname = "",
                                  phone = "", field = "",
                                  cfg = dsapp_config()) {
  id <- dsapp_sync_identity_ensure(cfg)
  if (is.null(id)) return(NULL)
  list(
    v        = 1L,
    email    = tolower(trimws(as.character(email %||% ""))),
    nickname = substr(as.character(nickname %||% ""), 1, 40),
    phone    = substr(as.character(phone %||% ""), 1, 40),
    field    = substr(as.character(field %||% ""), 1, 60),
    # ⚠️⚠️ salt **只 trim，绝不 tolower**。
    #   `dsapp_token()`（R/users.R）在 Linux 上吐的是小写十六进制，但在
    #   **Windows 上会回落到 `sample(c(letters, LETTERS, 0:9))`** —— 也就是
    #   说 Windows 建出来的账号，盐是**大小写混合**的。
    #   这里顺手 tolower 一下的后果不是"格式不对"，而是**哈希对不上**：
    #   盐是 dsapp_pw_hash 的输入的一部分，改一个字母就是另一个哈希。
    #   症状会是"桌面版注册的号，在云端用同一个密码登不进去，还说密码错"——
    #   而它**只在 Windows 上复现**，在开发机（Linux）上永远是对的。
    #   （我在下面 .dsapp_sync_claim_check 的格式校验里已经专门放行了
    #     字母数字盐、还写了注释提醒，结果转头在**构造**这一侧把它
    #     tolower 掉了 —— 同一个坑，防错了地方。）
    salt     = trimws(as.character(salt %||% "")),
    # hash 是 digest::digest 的输出，恒为小写十六进制，tolower 是无操作；
    # 留着只是让"两边都别动大小写"这件事看起来一致。
    hash     = tolower(trimws(as.character(hash %||% ""))),
    # 本地那个账号的 id：云端要拿它建档，把这一批会话/消息挂到这个 uid 上
    # （peer 映射表，见 .dsapp_sync_map_put）。
    uid      = as.character(uid %||% ""),
    node     = dsapp_sync_node_id(cfg),
    pubkey   = id$pub,
    at       = dsapp_now()
  )
}

#' 把**任意一棵** JSON 树序列化成唯一确定的字节串
#'
#' ⚠️⚠️ 这个函数是 V16.6 从一次**真的踩到的**事故里拆出来的，别把它和
#'      `.dsapp_sync_canonical` 混用：
#'
#'   `.dsapp_sync_canonical(x)` 走的是 `.dsapp_sync_sig_payload()`，而那个
#'   函数**只挑出包（bundle）的那几个字段**（v/node/sent_at/user/req_from…/
#'   data）。认领材料（claim）的字段它**一个都不认识** —— 于是
#'   `canonical(claim)` 对任何一份 claim 都算出**同一个常量**：
#'   一个字段全空、三个集合全空的包。
#'
#'   后果是签名**覆盖了零个字节**：改 `hash`、改 `salt`、改 `email`，签名
#'   原样留着照样验得过。这不是"签名弱"，是**签名什么都没签**，而它在
#'   自检里长得和"验签通过"一模一样 —— 本仓 `mutation-must-change-behavior`
#'   那条老账的又一个形状（一个不改变行为的变异证明的是零）。
#'
#'   实测抓到它的那一条是"把 claim$hash 换掉之后重新验签"：期望 FALSE，
#'   实际 TRUE。
#'
#' ★ 规矩：**要签的对象是什么，就用哪个序列化器**。包用
#'   `.dsapp_sync_canonical`（它有"接收端会读哪些字段"这层语义），
#'   别的结构一律用这个。
.dsapp_sync_canonical_obj <- function(x) {
  jsonlite::toJSON(.dsapp_sync_canon(x),
                   auto_unbox = TRUE, digits = NA, null = "null")
}

#' 给认领材料盖章（用本机私钥）
#'
#' 盖的是 `canonical_obj(claim 去掉 claim_sig 本身)`。
#' @return 128 个十六进制字符；失败返回 NA_character_
dsapp_sync_claim_sign <- function(cl, cfg = dsapp_config()) {
  id <- dsapp_sync_identity(cfg)
  if (is.null(id)) return(NA_character_)
  bare <- cl
  bare$claim_sig <- NULL
  raw <- dsapp_hex_decode(id$seed)
  if (is.null(raw) || length(raw) != 32L) return(NA_character_)
  tryCatch({
    k <- openssl::read_ed25519_key(raw)
    dsapp_hex_encode(openssl::signature_create(
      charToRaw(as.character(.dsapp_sync_canonical_obj(bare))), key = k))
  }, error = function(e) NA_character_)
}

#' 验一份认领材料是不是它自己声称的那把钥匙签的（自证）
#'
#' ★ 这就是"自证"：验证用的公钥**取自材料本身**。它证明的只有一件事 ——
#'   "造这份材料的人持有 claim$pubkey 对应的私钥"。它**不能**证明"这个人
#'   是邮箱的主人"，那件事没有任何密码学办法能证明（第一次见面）。
#'   抢注只能用开关 + 审计 + 通知信处理。
#'
#' ⚠️ 验证**必须**用 `cl` 去掉 `claim_sig` 之后的那份字节，和盖章时一致。
#'    不一致的话，攻击者改掉 `hash` 字段再原样留着签名字，就变成"改完还
#'    验得过" —— 那这个签名就白加了。
dsapp_sync_claim_verify <- function(cl) {
  if (!is.list(cl)) return(FALSE)
  pub <- as.character(cl[["pubkey"]] %||% "")
  sig <- dsapp_hex_decode(as.character(cl[["claim_sig"]] %||% ""))
  if (is.null(sig) || length(sig) != 64L) return(FALSE)
  raw <- dsapp_hex_decode(pub)
  if (is.null(raw) || length(raw) != 32L) return(FALSE)
  bare <- cl
  bare$claim_sig <- NULL
  isTRUE(tryCatch(
    openssl::signature_verify(
      charToRaw(as.character(.dsapp_sync_canonical_obj(bare))), sig,
      pubkey = openssl::read_ed25519_pubkey(raw)),
    error = function(e) FALSE))
}

#' 认领材料合不合法（**格式**这一层，和签名无关）
#'
#' 判据和 dsapp_user_validate() 那一套**故意分开写**：那边是给"人在表单里
#' 打字"用的，返回的是一句中文；这边是给"机器投进来的包"用的，必须
#' **严格**（多余一个字符就拒），而且不能顺手做任何写操作。
#'
#' @return list(ok, msg)
.dsapp_sync_claim_check <- function(cl, email_claim) {
  if (!is.list(cl)) return(list(ok = FALSE, msg = "包里没有认领材料"))
  e <- tolower(trimws(as.character(cl[["email"]] %||% "")))
  if (!nzchar(e)) return(list(ok = FALSE, msg = "认领材料里没有邮箱"))
  # ★ 材料里的邮箱必须和信封里那个**一模一样**。不一样就说明有人在
  #   中途换了收件人 —— 拒。
  if (!identical(e, tolower(trimws(as.character(email_claim %||% ""))))) {
    return(list(ok = FALSE, msg = "认领材料里的邮箱和信封不一致"))
  }
  if (!grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e)) {
    return(list(ok = FALSE, msg = "邮箱格式不对"))
  }
  # ★★ 口令校验器的格式。
  #    hash：64 个十六进制（sha256 的输出，dsapp_pw_hash 拼链之后还是 64）。
  #    salt：**必须是 [A-Za-z0-9]，不能写死十六进制** ——
  #      本机 dsapp_token() 在 Windows 上会回落到 `sample(c(letters,
  #      LETTERS, 0:9))`（见 R/utils.R），也就是说 **Windows 上生成出来的
  #      salt 是字母数字、不是十六进制**。这里写死 `[0-9a-f]` 的话，
  #      **每一个 Windows 建号包都会被拒**，而症状是"同步说云端没有这个
  #      账号"（走的是老的 no_account 那条路），极难往字符集上想。
  salt <- as.character(cl[["salt"]] %||% "")
  if (!grepl("^[A-Za-z0-9]{8,64}$", salt)) {
    return(list(ok = FALSE, msg = "口令盐的格式不对"))
  }
  hash <- tolower(as.character(cl[["hash"]] %||% ""))
  if (!grepl("^[0-9a-f]{64}$", hash)) {
    return(list(ok = FALSE, msg = "口令校验值的格式不对"))
  }
  # 其余字段走"可以空、但非空就得合法"的宽松档 —— 它们在网页版注册表单里
  # 也是可选的，没必要在这里比那边更严。
  nm <- trimws(as.character(cl[["nickname"]] %||% ""))
  if (nchar(nm) > 40) return(list(ok = FALSE, msg = "昵称太长"))
  ph <- trimws(as.character(cl[["phone"]] %||% ""))
  if (nchar(ph) > 40) return(list(ok = FALSE, msg = "手机号太长"))
  ld <- trimws(as.character(cl[["field"]] %||% ""))
  if (nchar(ld) > 60) return(list(ok = FALSE, msg = "领域太长"))
  list(ok = TRUE, email = e, salt = salt, hash = hash,
       nickname = if (nzchar(nm)) nm else e,
       phone = ph, field = ld)
}

#' 认领失败时给用户看的那句话
dsapp_sync_claim_msg <- function(email, why) {
  paste0(
    "云端还没有 ", email, " 这个账号，而且这次没有建成。\n",
    "原因：", why, "\n",
    "如果这是你自己的服务器，可以用管理员账号在「后台管理 → 信息同步跳板」",
    "里把「允许同步建号」打开，然后再同步一次；否则请先用同一个邮箱在网页版",
    "注册一次。\n",
    "（云端默认不允许凭一个同步包建号：那等于任何能往收件箱里放文件的人，",
    "都能给任意邮箱建一个自己知道密码的账号。）")
}
