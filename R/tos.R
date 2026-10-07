# =============================================================================
# 用户须知与同意记录（V9 item 1）
# =============================================================================
# 用户的原话：「针对我这个产品，请你设置一个用户须知，在注册时需要勾选同意，
# 每隔 1 week 提醒老用户再勾选同意一次，并保留这个用户点击同意的日志」。
#
# 三件事，各归各的：
#   1. **文本**      —— dsapp_tos_text()。**优先读数据目录里的
#      `user_must_know_V*.txt`**，读不到才用代码里内嵌的那一份（V10 改的；
#      V9 是纯写死在代码里，运营想改一句条款就得改代码 + 重新部署）。
#   2. **同意记录**  —— consent_log 表。**只增不改**，每次点同意写一行。
#   3. **该不该问**  —— dsapp_tos_gate()。注册时必勾；之后每 7 天再问一次。
#
# -----------------------------------------------------------------------------
# ⚠️ 为什么"版本号"是这套东西的核心，而不是"时间"
# -----------------------------------------------------------------------------
# 用户要的是"每周提醒再勾一次"。但如果只按时间判，会有一种很难看的失败：
# 我们把须知**改了一句**（比如新增"不要上传可识别个人身份的人类遗传数据"），
# 而某个用户三天前刚勾过 —— 按时间算他不用再看，于是他对一段**从来没读过**
# 的文字保持着"已同意"的状态。那份同意是假的。
#
# 所以判定条件是**或**：
#     版本对不上  → 必须重新确认（不管多久之前勾的）
#     超过 7 天   → 必须重新确认（不管版本有没有变）
#
# 改文案的人只要记住一件事：**改了实质内容就抬 DSAPP_TOS_VERSION**。
# 抬版本不需要迁移、不需要通知，下次谁登录谁重新读一遍。
# （V10 起就算忘了抬也不会漏问 —— 正文指纹会兜住，见下面 dsapp_tos_version_key）
#
# ⚠️ 版本号用字符串而不是数字，并且**不要**用日期当版本号。2026-09-15 这种
#    写法看着很明白，但两次改动发生在同一天时就分不出先后了。用 "2.0"/"2.1"。
#
# V10：正文整篇换成了 data/user_must_know_V1.txt 里的正式条款（十条），
#      和 V9 那段自己拟的完全不是一份东西 —— 按上面的规矩抬版本，
#      所有已同意的人下次进来都要重新读一遍。这是有意的：他们同意过的是
#      另一段文字，那段文字里并没有"密钥加密存储"这类承诺。
#
# 2.1（2026-10-07）：正文加了标题层级 —— 文档题 `# 用户须知` + 四个一级分组
#      （第一部分 总则 / 第二部分 使用与责任 / 第三部分 数据与隐私 /
#      第四部分 终止与免责），原来那十个 `##` 章**一个字没动**，只是归了组。
#
#      ⚠️ 这**必须**抬版本，不是为了好看：真正决定"要不要重新问一次"的是
#         dsapp_tos_version_key() 里的正文指纹，而正文已经变了 —— 指纹一定
#         会变、所有人一定会被重新问。如果显示版本还停在 "2.0"，界面上就会
#         出现「同意的是 2.0 版，当前是 2.0 版」这种自相矛盾的句子
#         （见 mod_tos_gate 里那句 sprintf）。抬版本是为了让那句话成立。
#
#      ⚠️ 也**没有**按文件头的约定丢一个 V2 文件进来：那条约定是给运营改
#         条款用的（不用改代码、也不删旧文件）。这次是**结构**改动，而且
#         要跟内嵌兜底、DEPLOYMENT.md 的引用一起改 —— 留两份反而会漂。
#         将来运营要换条款文字，V2/V3… 那条路照旧。
DSAPP_TOS_VERSION <- "2.1"

# 多久重新确认一次。用户说的是"1 week"，改这个数字就是改频率。
#
# ⚠️ 这个值是**重新确认的间隔**，不是会话时长。7 天里用户开着页面不动，
#    不会被踢出来 —— 判定只在"进入应用"那一刻做一次（见 app.R 的 app_root）。
DSAPP_TOS_DAYS <- 7

#' 用户须知的正文（Markdown）
#'
#' 来源**优先是数据目录里的文件**：`<data_root>/user_must_know_V*.txt`，
#' 有多个就取版本号最大的那个。找不到文件时回落到下面内嵌的这一份。
#'
#' ⚠️ 为什么不直接写死在代码里（V9 的写法），也不只放文件（V10 之前想过）：
#'    · 只写死在代码里 —— 改一句条款要走改代码 + 部署，法务/运营改不动；
#'    · 只放文件 —— 全新部署、归档出来的副本、别人的机器上都没有这个文件，
#'      界面会开天窗（而这份东西恰恰是**注册页**要读的，缺了就是注册不了）。
#'    两边都留一份，文件优先，代码兜底。内容不一致时以文件为准，这是有意的：
#'    文件是"这台部署现在生效的版本"。
#'
#' ⚠️ 内嵌那一份（dsapp_tos_default_text）是 `data/user_must_know_V1.txt` 的
#'    **逐字拷贝**（用 R 生成，不是手抄）。改文件的时候要一起改，否则新部署
#'    和这台机器上跑的不是同一份条款 —— 而用户同意的是他当时看到的那一份。
dsapp_tos_text <- function(cfg = dsapp_config()) {
  d <- dsapp_tos_doc(cfg)
  d$text
}

#' 这份须知的全文 + 它是从哪儿来的
#'
#' @return list(text = 正文, file = 实际读到的那份文件路径，用的是内嵌兜底时
#'   为 NULL)
#'
#' ⚠️ 这里有个进程内缓存，键是**文件路径 + 修改时间 + 大小**。为什么非要缓存：
#'    `dsapp_tos_version_key()` 每次都要算正文指纹，而它会被 gate 每次渲染时
#'    调到 —— 于是每渲染一次就 digest 一遍 5 KB 文本。更麻烦的是**读文件**
#'    这件事一旦发生在渲染路径上，磁盘慢一下界面就卡一下。
#'
#'    而键里带上 mtime 是为了「改了文件要立刻生效」：运营把 V2 丢进去，
#'    刷一下页面就该看到新的 —— 不需要重启、也不需要等缓存过期。
#'    （键里不带 mtime 只用路径的话，换文件是能生效的，改**同一个**文件
#'    就不生效了，而那恰恰是最常见的改法。）
dsapp_tos_doc <- function(cfg = dsapp_config()) {
  f <- dsapp_tos_file(cfg)
  key <- if (is.null(f)) "(内嵌)" else {
    fi <- tryCatch(file.info(f), error = function(e) NULL)
    sprintf("%s|%s|%s", f, if (is.null(fi)) NA else fi$mtime,
            if (is.null(fi)) NA else fi$size)
  }
  st <- tryCatch(dsapp_state(), error = function(e) NULL)
  if (!is.null(st) && identical(st$tos_key, key) && !is.null(st$tos_doc)) {
    return(st$tos_doc)
  }

  txt <- NULL
  if (!is.null(f)) {
    txt <- tryCatch({
      x <- paste(readLines(f, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
      if (nzchar(trimws(x))) x else NULL
    }, error = function(e) {
      message("[dsapp] 读用户须知文件出错：", conditionMessage(e))
      NULL
    })
  }
  if (is.null(txt)) {
    if (!is.null(f)) message("[dsapp] 用户须知文件读不出来，回落到内嵌版本：", f)
    txt <- dsapp_tos_default_text()
  }
  doc <- list(text = txt, file = f)
  if (!is.null(st)) {
    st$tos_key <- key
    st$tos_doc <- doc
  }
  doc
}

#' 数据目录里那份须知文件（没有就 NULL）
#'
#' 认文件名 `user_must_know_V<n>.txt`，取 n 最大的那个。这样"改版"就是把
#' 新文件丢进去（V2、V3…），不用改代码、也不用删旧文件 —— 留着旧的还能
#' 查到"当时用户读的是哪一版"。
#'
#' ⚠️ 文件名里的 V<n> 只是**排序用的**，不参与版本判定 —— 判定看的是正文
#'    指纹（见 dsapp_tos_version_key）。否则会出现"文件名叫 V2、内容和
#'    V1 一模一样"就逼所有人重新确认一遍的蠢事，反过来"内容改了却还叫
#'    V1"又漏掉一问。文件名管找到哪一份，内容管算不算新版，各管各的。
dsapp_tos_file <- function(cfg = dsapp_config()) {
  root <- cfg$data_root
  if (is.null(root) || !dir.exists(root)) return(NULL)
  fs <- list.files(root, pattern = "^user_must_know_V[0-9]+\\.txt$",
                   full.names = TRUE)
  if (!length(fs)) return(NULL)
  num <- suppressWarnings(as.integer(sub("^.*_V([0-9]+)\\.txt$", "\\1",
                                         basename(fs))))
  fs[order(num, decreasing = TRUE)][1]
}

# =============================================================================
# 版本号：给人看的 + 存库比对的，是两个东西
# =============================================================================
# DSAPP_TOS_VERSION 是**给人看的**版本号（"2.0"），写在界面上、也写在注释里，
# 改了条款就抬它。但只靠它有一个漏洞：条款内容改了、版本号忘了抬，那么已经
# 同意过的人**不会**被重新问一次 —— 而"他同意的那段文字"和"他现在看到的
# 那段文字"已经不是同一段了。这套机制唯一的实质失败就是这个。
#
# 所以存进库、拿去比对的是 dsapp_tos_version_key()：显示版本 + 正文指纹。
# 正文改一个字，指纹就变，所有人重新确认一遍 —— 不依赖任何人记得抬版本号。
# 界面上仍然只显示 dsapp_tos_version_show()，用户看到的还是 "2.0"。
dsapp_tos_version_show <- function() DSAPP_TOS_VERSION

dsapp_tos_fingerprint <- function(cfg = dsapp_config()) {
  # digest 不在的话退回空串 —— 那时 key 就等于显示版本，行为退回到 V9 那样
  # （要靠人抬版本号），而不是报错。少一层保险，但应用照常能用。
  if (!requireNamespace("digest", quietly = TRUE)) return("")
  txt <- tryCatch(dsapp_tos_text(cfg), error = function(e) NULL)
  if (is.null(txt) || !nzchar(txt)) return("")
  substr(digest::digest(txt, algo = "md5", serialize = FALSE), 1, 8)
}

dsapp_tos_version_key <- function(cfg = dsapp_config()) {
  fp <- dsapp_tos_fingerprint(cfg)
  if (!nzchar(fp)) dsapp_tos_version_show()
  else sprintf("%s+%s", dsapp_tos_version_show(), fp)
}

#' 从存库的那串里取出给人看的部分（"2.0+7f3a2c1d" -> "2.0"）
dsapp_tos_version_label <- function(x) {
  if (is.null(x) || !length(x) || is.na(x)) return("")
  sub("\\+.*$", "", as.character(x))
}

# -----------------------------------------------------------------------------
# 内嵌的兜底正文（下面这份是 data/user_must_know_V1.txt 的逐字拷贝）
# -----------------------------------------------------------------------------
# ⚠️ 用 R 从那个文件生成（encodeString），**不是手抄** —— 手抄必然会走样，
#    而这份文字的每一句都是对用户的承诺（比如"密钥加密存储"）。
dsapp_tos_default_text <- function() {
  paste(c(
    "# 用户须知",
    "",
    "欢迎使用**言出法随生信APP**（以下简称 \"本平台\"）。本平台由**Biomamba 生信基地**运营。在使用本平台前，请您仔细阅读本须知全部内容。您注册、登录或使用本平台，即视为已阅读并同意本须知全部条款。",
    "",
    "# 第一部分　总则",
    "",
    "## 一、服务说明",
    "",
    "1. 本平台是一款 API 请求转发工具，仅提供技术转发与代理服务，不提供、不销售任何模型、接口或数据服务本身。",
    "2. 您在使用本平台时，须自行拥有合法的 API 密钥来源及相应的使用权限，并对其合法性承担全部责任。",
    "3. 本平台不参与第三方 API 服务商的计费、内容生产与服务质量控制。",
    "",
    "## 二、账号与密钥安全",
    "",
    "1. 您上传的 API 密钥将经过加密存储，本平台不以明文形式保存密钥，不将密钥用于转发请求以外的任何用途，不对密钥内容进行日志记录。",
    "2. 您应妥善保管账号、密码及 API 密钥，不得以任何形式向他人泄露、转借或共享。因您保管不当（包括但不限于分享、截图、公开展示、设备丢失）导致的密钥泄露及由此产生的损失，由您自行承担。",
    "3. 如发现密钥疑似泄露，您应立即在对应的 API 服务商处重置密钥，并可通过客服微信 **Biomamba_zhushou** 联系本平台协助排查。",
    "4. 本平台不承担因您自身原因导致密钥泄露所产生的任何责任。",
    "",
    "# 第二部分　使用与责任",
    "",
    "## 三、使用规范",
    "",
    "1. 您承诺不将本平台用于任何违法用途，包括但不限于：诈骗、网络攻击、传播违法信息、侵犯他人知识产权或隐私权等行为。",
    "2. 您不得通过本平台批量转售、倒卖 API 能力或利用本平台从事任何形式的商业套利行为。",
    "3. 您不得滥用本平台服务，包括但不限于绕过限流机制、恶意并发请求、干扰平台正常运行或影响其他用户使用。",
    "4. 您使用第三方 API 服务时，应遵守该服务商的服务条款。因您违反第三方条款导致的账号封禁、损失或法律纠纷，由您自行承担，本平台不承担责任。",
    "",
    "## 四、费用与计费",
    "",
    "1. 本平台的计费规则以页面实时展示为准。您使用第三方 API 所产生的全部费用由您自行承担。",
    "2. 您的账户余额不足时，相关转发请求可能被暂停，直至您完成充值。",
    "3. 充值金额的使用与退款规则以充值页面及客服说明为准。因第三方 API 服务商调整价格导致的费用变化，本平台不承担差价责任。",
    "4. 本平台可能对用量异常的账户采取提醒、限流或暂停服务等措施。",
    "",
    "# 第三部分　数据与隐私",
    "",
    "## 五、数据与隐私",
    "",
    "1. 您通过本平台转发的请求内容（包括输入文本与返回结果）仅用于完成转发，本平台不对其进行存储或用于任何其他用途。",
    "2. 本平台可能记录必要的运行日志（如请求时间、用量、错误码等元数据），不记录请求正文内容。",
    "3. 您应知悉，您对接的第三方 API 服务商可能位于境外，您的请求内容可能被传输至境外服务器处理，请您在提交涉及个人信息或人遗等敏感数据前自行评估风险。",
    "4. 您保证提交的内容合法合规，不含有违法或侵害他人权益的信息。",
    "",
    "## 六、服务可用性",
    "",
    "1. 本平台不保证服务永不中断。因第三方 API 服务商故障、限流、政策调整或下架导致的不可用、延迟或失败，本平台不承担责任。",
    "2. 本平台可能对服务进行升级、优化或调整，并可能造成临时性中断。",
    "3. 因不可抗力（包括但不限于自然灾害、政府行为、网络故障、电力中断等）导致的服务中断或损失，本平台不承担责任。",
    "",
    "# 第四部分　终止与免责",
    "",
    "## 七、账号与服务终止",
    "",
    "1. 如您违反本须知约定，本平台有权视情节采取警示、限制功能、暂停服务直至永久封禁账号等措施。",
    "2. 本平台终止服务时，将按法律法规要求处理您的数据，您应在此之前自行备份必要信息。",
    "",
    "## 八、知识产权",
    "",
    "1. 本平台的软件、界面、代码及相关技术成果的知识产权归 Biomamba 生信基地 所有。",
    "2. 您提交、生成的内容权利归您所有，但您须保证该等内容合法合规。",
    "",
    "## 九、免责声明",
    "",
    "1. 本平台仅提供技术转发服务，不对您使用 API 产生的内容、结果及业务后果承担任何责任。",
    "2. 因您使用本平台或第三方 API 服务引发的任何纠纷、损失或法律责任，由您自行解决并承担；本平台在法律允许的范围内不承担连带责任。",
    "3. 本平台提供的服务 \"按现状\" 提供，不对服务的适用性、准确性、完整性作出任何明示或默示的保证。",
    "",
    "## 十、协议变更与联系我们",
    "",
    "1. 本平台有权根据法律法规及业务需要修订本须知，修订后的须知将通过站内公告发布，发布后即视为送达。您继续使用本平台即视为接受修订后的内容。",
    "2. 如您对本须知或本平台服务有任何疑问、意见或投诉，可通过客服微信 **Biomamba_zhushou** 联系我们。",
    "3. 本须知的解释权归 Biomamba 生信基地 所有。因本须知产生的争议，双方应协商解决；协商不成的，提交平台运营方所在地有管辖权的人民法院诉讼解决。"
  ), collapse = "\n")
}

#' 建表 + 迁移（幂等）
#'
#' 在 dsapp_db_schema() 里调用，位置在 dsapp_db_schema_users() **之后**
#' （要给 users 加列，表得先在）。
dsapp_tos_schema <- function(con) {
  # ⚠️ **只增不改**的日志表。同一个人可以有很多行：注册时一行，之后每 7 天
  #    一行，改版之后重新确认又是一行 —— 这正是"保留点击同意的日志"要的东西。
  #    所以**没有** UNIQUE 约束，也永远不要 UPDATE 它。
  #
  # 为什么还要另外在 users 上存两列（见下）："这个人现在算不算同意过"是每次
  # 进应用都要问一次的问题，走日志表就得 MAX(agreed_at) 扫一遍。两列是那份
  # 日志的**物化视图**，日志才是真相 —— 两者对不上时以日志为准。
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS consent_log (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id     INTEGER,
      doc         TEXT NOT NULL DEFAULT 'tos',
      version     TEXT NOT NULL DEFAULT '',
      action      TEXT NOT NULL DEFAULT 'agree',
      source      TEXT NOT NULL DEFAULT '',
      agreed_at   TEXT NOT NULL,
      user_agent  TEXT NOT NULL DEFAULT ''
    )")
  # 两个查询方向：管理页"某个人同意过几次"（按 user）、
  # "这一版有多少人同意过"（按 version+doc）。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_consent_user ON consent_log(user_id)")
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_consent_ver ON consent_log(doc, version)")

  # users 上那两列（物化视图）。SQLite 的 ADD COLUMN 没有 IF NOT EXISTS，
  # 先查表结构 —— 整个 schema 函数必须幂等，这条也一样。
  ucols <- tryCatch(DBI::dbGetQuery(con, "PRAGMA table_info(users)")$name,
                    error = function(e) character(0))
  if (!"tos_version" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN tos_version TEXT"),
        silent = TRUE)
  }
  if (!"tos_agreed_at" %in% ucols) {
    try(DBI::dbExecute(con, "ALTER TABLE users ADD COLUMN tos_agreed_at TEXT"),
        silent = TRUE)
  }
  invisible(TRUE)
}

#' 这个人现在还要不要再确认一次
#'
#' @return list(need = TRUE/FALSE, reason = "never"|"version"|"stale"|"",
#'              last = 上次同意的时刻（可能是 NULL）, version = 上次同意的版本)
#'
#' 三种要重新确认的情形分开报，是因为界面上的措辞完全不同：
#'   never   —— 从来没同意过（老账号、或者刚注册还没勾）
#'   version —— 须知改过，你没读过这一版
#'   stale   —— 超过 7 天没确认了
#' 混成一句"请重新确认"的话，用户会以为是自己做过什么才被拦下来的。
dsapp_tos_gate <- function(user_id, con = dsapp_db()) {
  none <- list(need = TRUE, reason = "never", last = NULL, version = NULL)
  if (is.null(user_id) || is.na(user_id)) return(none)

  row <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT tos_version, tos_agreed_at FROM users WHERE id = ?",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(none)

  ver  <- as.character(row$tos_version[[1]] %||% "")
  when <- as.character(row$tos_agreed_at[[1]] %||% "")
  if (!nzchar(ver) || !nzchar(when)) return(none)

  # ⚠️ 比的是**带指纹的 key**，不是 DSAPP_TOS_VERSION。库里的值可能是三种
  #    形态，都必须判成"要对齐"：
  #      "1.0"          V9 存的（那时候还没有指纹这回事）
  #      "2.0"          文件名换了、指纹算不出来时降级存进去的
  #      "2.0+7f3a2c1d" V10 存的正规形态
  #    前两种和当前的 key 一定不相等 —— 于是老用户被重新问一次，正是要的。
  if (!identical(ver, dsapp_tos_version_key())) {
    return(list(need = TRUE, reason = "version", last = when, version = ver))
  }

  # ⚠️ 时间戳解析失败时**要重新问**（返回 need = TRUE），不能当成"还新鲜"。
  #    存进去的都是 dsapp_now() 的 ISO 串，正常不会失败；真失败了说明这一行
  #    被别的东西写坏了，那时候宁可多问一次 —— 少问一次的后果是"用户在没
  #    读过新版须知的情况下一直算已同意"，那是这套机制唯一的实质失败。
  age <- tryCatch(
    as.numeric(difftime(Sys.time(), as.POSIXct(when), units = "days")),
    error = function(e) NA_real_)
  if (is.na(age)) {
    return(list(need = TRUE, reason = "stale", last = when, version = ver))
  }
  # 负数 = 数据库里的时间在未来（时钟被改过、或者从别的机器同步过来的库）。
  # 也算过期：不能因为一个未来的时间戳就永远不再问。
  if (age < 0) age <- DSAPP_TOS_DAYS + 1

  if (age >= DSAPP_TOS_DAYS) {
    return(list(need = TRUE, reason = "stale", last = when, version = ver))
  }
  list(need = FALSE, reason = "", last = when, version = ver)
}

#' 记一次同意
#'
#' 日志和 users 上那两列一起写。**顺序是先日志后两列**：日志写失败就整个
#' 失败（抛出去，让调用方如实报错），而两列写失败只是"下次还得再问一次"，
#' 比反过来（两列写上了、日志没有）安全得多 —— 后者会变成一句查无实据的
#' "他同意过"。
#'
#' @param source 在哪儿同意的："register"（注册页）/ "weekly"（到点重申）
#'   / "admin"（管理员代确认，目前没用上，留着）。**必填**：
#'   日志里只有时间没有场景的话，事后分不清"这个人注册时读过了"和
#'   "他被弹窗拦下来随手点的"。
dsapp_tos_record <- function(user_id, source, version = dsapp_tos_version_key(),
                             ua = "", con = dsapp_db()) {
  if (is.null(user_id) || is.na(user_id)) {
    stop("记同意日志需要 user_id")
  }
  now <- dsapp_now()
  ins <- function() DBI::dbExecute(con,
    "INSERT INTO consent_log (user_id, doc, version, action, source, agreed_at, user_agent)
     VALUES (?, 'tos', ?, 'agree', ?, ?, ?)",
    params = list(as.integer(user_id), as.character(version),
                  as.character(source), now, substr(ua %||% "", 1, 200)))

  # ⚠️ ★★ 这条 tryCatch 是 V10 修的那个线上 bug 的**兜底**，不是它的主修。
  #
  #    主修在 R/db.R（DSAPP_SCHEMA_VERSION + PRAGMA user_version），那里保证
  #    连接一到手就把落后的表补齐。但那条路有一个前提：**代码里的常量变了**。
  #    而线上真炸的那一次是「连接是 V8 时候建的、表没建；代码已经是 V9」——
  #    那次靠 user_version 就能自愈。可如果哪天有人加表**忘了抬常量**，
  #    症状会和这次一模一样：一个权限什么都对、就是查不到表的连接，
  #    用户卡在注册页上，报 "no such table"。
  #
  #    所以这里再兜一层：insert 报错时，无条件重跑一遍建表再试一次。
  #    dsapp_tos_schema 是幂等的、几毫秒的事，正常路径上**一次都不会跑到**
  #    （第一次 insert 成功就直接返回了）。宁可在这里多写十行，也不要
  #    再让用户看到一次"点了同意，它说没这张表"。
  ok <- tryCatch({ ins(); TRUE }, error = function(e) {
    msg <- conditionMessage(e)
    # 只有"表不存在"这一类才值得重试。别的错误（磁盘满、库锁死、约束冲突）
    # 重试一次既没用又掩盖真因 —— 那类照样原样抛出去，让界面如实报错。
    if (!grepl("no such table|no such column", msg, ignore.case = TRUE)) {
      stop(e)
    }
    message("[dsapp] consent_log 写入时报「", msg, "」，补建表结构后重试一次。")
    try(dsapp_tos_schema(con), silent = TRUE)
    ins()
    TRUE
  })

  DBI::dbExecute(con,
    "UPDATE users SET tos_version = ?, tos_agreed_at = ? WHERE id = ?",
    params = list(as.character(version), now, as.integer(user_id)))
  invisible(now)
}

#' 某个账号的同意历史（管理页用）
dsapp_tos_history <- function(user_id, limit = 50L, con = dsapp_db()) {
  tryCatch(
    DBI::dbGetQuery(con,
      "SELECT version, source, agreed_at FROM consent_log
        WHERE user_id = ? AND doc = 'tos'
        ORDER BY id DESC LIMIT ?",
      params = list(as.integer(user_id), as.integer(limit))),
    error = function(e) data.frame(version = character(0), source = character(0),
                                   agreed_at = character(0)))
}

#' 须知正文的界面（注册页和每周重申页共用同一份）
#'
#' ⚠️ 两处**必须**用同一个渲染函数。各写一份的话，改文案时只会改一处，
#'    于是用户在注册页读到的和每周被要求确认的不是同一段文字 ——
#'    而他"同意"的是后者。
#'
#' @param id 外层 div 的 id（可 NULL）。注册页要用它做滚动位置复位之类的事
#'   时才给；不给就是一个匿名盒子。
dsapp_tos_body_ui <- function(id = NULL) {
  div(class = "dsapp-tos", id = id,
    div(class = "dsapp-tos-md", HTML(dsapp_tos_html()))
  )
}

#' 正文 → HTML（Markdown）
#'
#' ⚠️ 顺序（先 dsapp_escape 挡住原始 HTML，再交给 commonmark 处理标记）
#'    的理由写在 render.R 的 dsapp_md_html() 上面，V11 起这段逻辑归它了，
#'    这里只是转调 —— 文件预览的 .md 分支要的是同一件事，再抄一份迟早
#'    会有一边忘了转义。
#'
#'    V9 这里写的是一段自我辩解（"须知要逐字读，不过渲染器"），结果是用户
#'    看到的是一堆字面的 `## 一、服务说明` 和 `**Biomamba 生信基地**` ——
#'    这不是"逐字"，这是**没渲染**。用户的原话就是"注意 markdown 标记要能
#'    正常渲染"。逐字与否取决于**文本**有没有被改写，而不取决于有没有经过
#'    渲染器：转义只动 & < > " 这四个字符，`# * - 1.` 一个都不碰，
#'    所以渲染出来的就是文件里写的那份。
dsapp_tos_html <- function(cfg = dsapp_config()) {
  txt <- dsapp_tos_text(cfg)
  if (is.null(txt) || !nzchar(txt)) return("")
  dsapp_md_html(txt)
}

#' 版本 + 日期那行小字
dsapp_tos_meta <- function() {
  sprintf("版本 %s · 自同意之日起 %d 天内有效",
          dsapp_tos_version_show(), DSAPP_TOS_DAYS)
}

# =============================================================================
# 到期重申页（V9 item 1）
# =============================================================================
# 做成一整页而不是一个弹窗，理由和 mod_welcome.R 里强制改密页那段一样：
# 弹窗（哪怕 easyClose = FALSE）底下压着的是**已经渲染好的主界面**，
# 用户会以为自己已经进来了、只是有个框挡着 —— 而这里的语义恰恰是
# "你还没进来"。整页替换没有这个歧义，也不依赖任何前端 JS
# （bootstrap 的 modal 要靠 JS 才关得掉，而 JS 关不掉的框在用户眼里
# 就是"应用卡死了"）。
#
# 出口有两条，缺一不可：
#   1. 勾选 + 继续 —— 常规路径
#   2. 退出登录 —— 用户如果不愿意同意新版须知，得有一条体面的退路。
#      没有这条的话他只能清 cookie 或者关掉页面，而两种做法都不会在
#      日志里留下任何痕迹。
# =============================================================================

dsapp_tos_gate_ui <- function(id) {
  ns <- NS(id)
  tagList(uiOutput(ns("tos_page")))
}

#' @param state 和别的模块共用那份 reactiveValues（要读 user_id / user）
#' @param on_done 同意之后调，用来把闸门放开
mod_tos_gate_server <- function(id, state, on_done) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()
    err <- reactiveVal(NULL)

    output$tos_page <- renderUI({
      uid <- state$user_id
      g <- tryCatch(dsapp_tos_gate(uid, con = dsapp_db(cfg)),
                    error = function(e) list(need = TRUE, reason = "never",
                                             last = NULL, version = NULL))

      # 三种情形分开说。混成一句"请重新确认"的话，老账号用户会以为
      # 是自己做错了什么才被拦下来的。
      sub <- switch(g$reason,
        "version" = "《用户须知》有更新，请阅读这一版之后重新确认。",
        "stale"   = sprintf("距离上次确认已超过 %d 天，请再确认一次。",
                            DSAPP_TOS_DAYS),
        sprintf("开始之前，请先阅读并同意下面的《用户须知》。")
      )

      dsapp_auth_shell("用户须知", sub = sub, wide = TRUE, logo = "file-shield",
        body = tagList(
          # 上次是什么时候同意的 —— 用户需要知道"为什么又问我"。
          # reason = "never" 时没有上一次，这一行就不出现。
          if (!is.null(g$last) && nzchar(g$last %||% "")) {
            div(class = "dsapp-tos-last",
              icon("clock-rotate-left"), " 上次确认：",
              dsapp_fmt_time(g$last),
              # ⚠️ 显示的必须是 dsapp_tos_version_label() 剥出来的"2.0"。
              #    库里的值是 "2.0+7f3a2c1d" 这种带指纹的 key（见
              #    dsapp_tos_version_key），直接往界面上打就是一串乱码。
              #    V9 存进去的 "1.0" 本来就没有加号，剥了也还是 "1.0"。
              if (!is.null(g$version) && nzchar(g$version %||% "") &&
                  !identical(g$version, dsapp_tos_version_key()))
                sprintf("（同意的是 %s 版，当前是 %s 版）",
                        dsapp_tos_version_label(g$version),
                        dsapp_tos_version_show())
            )
          },
          div(class = "dsapp-tos-wrap",
            dsapp_tos_body_ui(),
            div(class = "dsapp-tos-meta", dsapp_tos_meta())
          ),
          checkboxInput(ns("agree"),
            sprintf("我已阅读并同意上述《用户须知》（%s 版）",
                    dsapp_tos_version_show()),
            value = FALSE),
          if (!is.null(err())) {
            div(class = "dsapp-auth-msg is-error", err())
          },
          actionButton(ns("do_agree"), "同意并继续", class = "dsapp-btn-primary"),
          div(class = "dsapp-auth-alt",
            actionLink(ns("do_logout"), "不同意，退出登录"))
        ),
        note = dsapp_footer_ui())
    })

    observeEvent(input$do_agree, {
      if (!isTRUE(input$agree)) {
        err("请先勾选上面的方框。")
        return()
      }
      uid <- state$user_id
      if (is.null(uid) || is.na(uid)) {
        # 理论上到不了（这一页只在登录之后才渲染）。真到了就如实说，
        # 不要假装成功 —— 那会让用户以为已经同意了，下次进来又被拦。
        #
        # ★ V13.7 item 2：原来是「请刷新页面重新登录」—— F5 是**平台自己
        #   就会做的事**（session$reload()），不该写成用户的待办。
        #   剩下的那半句"重新登录"确实是他的事：凭据没了，平台没法替他登，
        #   这一条属于"平台确实做不到"那一类，可以交给他。
        #
        # ⚠️ 顺序：先说清楚，再重载。重载是整页导航，那个 toast 多半来不及
        #    看见 —— 这是**接受**的，因为重载落点就是登录页，那本身就是
        #    答案。反过来（先重载再说）只会更糟：消息一定看不见。
        #    不做"让 toast 穿越重载"的机制：这一支理论上到不了，为它加一套
        #    sessionStorage 接力不划算。
        err("登录状态已经失效了，正在回到登录页 —— 重新登录后就能继续。")
        session$reload()
        return()
      }

      # ⚠️ 写失败就**不放行**，和注册那条正好相反。
      #
      #    注册时账号已经建好了，日志写不进去只是少一条记录；
      #    这里日志写不进去却放行的话，就变成"用户以为自己同意了、
      #    日志里查无此事"—— 而这套机制的全部意义就是那份日志。
      #    宁可让他再点一次。
      ok <- tryCatch({
        dsapp_tos_record(uid, source = "weekly",
                         ua = session$request$HTTP_USER_AGENT %||% "",
                         con = dsapp_db(cfg))
        TRUE
      }, error = function(e) {
        # ★ V13.7 item 2：原文进审计日志，界面上说人话。
        #   ⚠️ 这里**必须**保留"再点一次"这个动作 —— 用户须知没记上就进不了
        #      应用，而重试点正是 dsapp_tos_record 自己会重跑的路径，不是
        #      把平台的活推给他。
        err(dsapp_err_user(e, "记录你的确认",
                           hint = "再点一次这个按钮就行。"))
        FALSE
      })
      if (!isTRUE(ok)) return()

      err(NULL)
      on_done()
    })

    # 不同意就走人。**要留痕** —— 日志里只有"同意"没有"因为不同意而离开"
    # 的话，事后看数据会得出"所有人都同意了"的结论，而那是错的。
    observeEvent(input$do_logout, {
      tryCatch(
        dsapp_audit("tos_declined", user = state$user, user_id = state$user_id,
                    session = session, cfg = cfg),
        error = function(e) NULL)
      # ⚠️ 必须走 dsapp_session()。用模块自己那个 session 的话，
      #    清 cookie 和 reload **都不生效也不报错** —— 用户点了"不同意"，
      #    页面一动不动地停在确认页上，看起来就是"这个按钮坏了"。
      #    更糟的是这里是个**闭环**：cookie 没清掉 → 就算真 reload 了，
      #    起来还是自动登录 → 又撞上同一个确认页。用户被永久困住，
      #    唯一的出路是自己去清浏览器数据。
      root <- dsapp_session(state, session, "退出登录")
      root$sendCustomMessage("dsapp:clearToken", list())
      root$reload()
    })
  })
}
