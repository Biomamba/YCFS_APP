# =============================================================================
# 通用工具
# =============================================================================

#' 取默认值：`a` 为空就用 `b`
#'
#' ⚠️⚠️ **数据框必须单独判**（V13.10 item 1 的根因）。
#'
#'    老写法是 `if (is.null(a) || length(a) == 0 || is.na(a[1])) b else a`，
#'    对**原子向量**没问题（`a[1]` 只有一个元素）。但 `a` 是**数据框**时，
#'    `a[1]` 取的是"第一列"而不是"第一个元素" —— 于是 `is.na(a[1])` 返回一个
#'    **长度 = 行数** 的逻辑向量，`||` 在 R 4.3 之后对这种输入直接报错：
#'
#'        'length = 20' in coercion to 'logical(1)'
#'
#'    20 就是当时账号表的行数。现场是 `R/mod_htadmin.R` 的
#'    `nrow(rows() %||% data.frame())` —— 后台页那个"共 N 个账号"，
#'    只要**账号数 ≥ 2** 就必炸（1 行时 `is.na()` 长度正好是 1，所以
#'    "本地试的时候好好的"）。用户报的现象正是「后台页面显示 An error has
#'    occurred」。
#'
#'    这一条在 V13.9 里一模一样，属于**潜伏已久**：R 4.3 之前 `||` 对长度 >1
#'    的输入只是静默取第一个元素，不报错；升级到 4.4 之后才变成硬错误。
#'
#' @section environment：
#'    environment 的 `length()` **恒为 0**，所以它永远走 fallback ——
#'    这是**已知且刻意保留**的行为，`dsapp_session()` 的注释（见下）
#'    专门讲过怎么绕（用 `is.null()` 判）。这里不动它：改掉会让一批
#'    现在"靠 fallback 歪打正着"的调用点换行为，风险比收益大。
#'
#' @section S4 对象（数据库连接就是这个）：
#'    `a[1]` 对 S4 对象**不是返回元素，是直接抛**：
#'
#'        object of type 'S4' is not subsettable
#'
#'    DBI 的连接（`dbConnect()` 的返回值）就是 S4。所以
#'    `con %||% dsapp_db(cfg)` 这个写法**只要真传了连接就必炸** ——
#'    而它偏偏长得像一句无害的默认值兜底。
#'
#'    ⚠️ 真正难查的不是抛，是**抛在哪儿**：调用点通常整段包着 tryCatch
#'       （收尾链、后台循环都这么写），于是异常被吞掉，症状变成
#'       "一切正常、就是什么都没发生"。Test_V15.2 的邮件提醒就踩了这个：
#'       每一封信都在 `dsapp_mail_enqueue()` 里被自己的 tryCatch 吃掉，
#'       日志只留一行，界面上完全看不出来。
#'
#'    ✅ 写法：**别用 `%||%` 兜连接**，用惰性判断 ——
#'       `if (is.null(con)) con <- dsapp_db(cfg)`。
#'       R/mail.R 和 R/litsub.R 里是这个写法，别改回去。
#'       这里**不加 `isS4(a)` 分支**：`%||%` 全仓库几百个调用点，为一个
#'       已经有一句话正确写法的问题去改所有人的行为，不划算。
`%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 0) return(b)     # 空数据框（0 列）也走这条，同老行为
  if (is.data.frame(a)) return(a)   # ★ a[1] 是第一列，不是第一个元素
  if (is.na(a[1])) return(b)
  a
}

#' 统一的 UTC 时间戳字符串
#'
#' 存库一律用 UTC，避免服务器时区和用户时区不一致时排序错乱。
#' 展示时再转本地时区（见 dsapp_fmt_time）。
dsapp_now <- function() {
  format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
}

#' 从现在往前推 n 秒的那个时间戳
#'
#' 和 dsapp_now() 同一种格式，所以**可以直接拿去和库里的时间列做字符串
#' 比较**（"%Y-%m-%d %H:%M:%S" 是定长且字典序等于时间序的）。
#' 限流那类"最近一小时几条"的查询全靠这一点，不需要在 SQL 里做日期运算。
dsapp_ago <- function(sec) {
  format(Sys.time() - as.numeric(sec %||% 0), "%Y-%m-%d %H:%M:%S", tz = "UTC")
}

#' 把 UTC 时间戳转成本地时区显示
dsapp_fmt_time <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(x)) return("—")
  t <- as.POSIXct(x, tz = "UTC")
  if (is.na(t)) return(x)
  format(t, "%m-%d %H:%M", tz = Sys.timezone())
}

#' 人类可读的字节数
#' 目录占用的字节数
#'
#' ⚠️ 这个函数很**贵**：它要遍历整棵目录树（.venv 里上万个文件，实测一次
#'    零点几秒到几秒）。所以只允许挂在**用户显式点击**的路径上，绝不能塞进
#'    任何 invalidateLater 驱动的轮询里 —— 本站一个应用一个 R 进程、所有访客
#'    共用，一个 5 秒一次的 du 就能把所有人的页面拖住。
#'
#' 量不出来（du 不在、权限不够）返回 NA，不抛异常：占用大小是装饰性信息，
#' 为它把整个页面变成 Error 不值得。
dsapp_dir_bytes <- function(p) {
  if (length(p) != 1 || is.na(p) || !dir.exists(p)) return(0)
  dsapp_du_bytes(p)[[1]]
}

#' 目录占多少字节（跨平台，可一次量一批）
#'
#' ★ V16.6 item 5：抽出来是因为原来仓里有**四份**各写一遍的
#'   `system2("du", c("-sb", ...))`（R/utils.R / R/gc.R / R/users.R 两处）。
#'   四份一起错，而且错得没有声音。
#'
#' ⚠️⚠️ **`-b` 是 GNU 的选项，macOS/BSD 的 du 没有它**。在 mac 上
#'    `du -sb` 的报错打到 stderr（我们一直 stderr = FALSE 吞掉），于是
#'    out 是空的 → 落到 NA。也就是说：
#'    **mac 版上每一个"占用多少空间"都会显示成「—」，包括工作区大小、
#'    平台统计、清理孤儿目录时报的"释放了多少"** —— 而它一声不响。
#'    这里改成先试 `-sb`（Linux，已验证），不行再试 `-sk`（两个平台都有，
#'    单位 1024 字节，所以乘回去）。
#'
#' ⚠️ 接受**向量**、一次 du 量完一批，不是图省事：调用方
#'    （R/users.R 的 dsapp_dir_sizes）每 10 秒刷一次，一个个量 = 一次次
#'    重走整棵目录树。所以批量能力是这个函数的**接口的一部分**，别改成循环。
#'
#' @return 和 paths 等长的数值向量（字节）；量不到的那几个是 NA
dsapp_du_bytes <- function(paths) {
  paths <- as.character(paths)
  if (!length(paths)) return(numeric(0))
  res <- rep(NA_real_, length(paths))
  ok <- !is.na(paths) & nzchar(paths)
  if (!any(ok)) return(res)
  want <- paths[ok]

  for (fl in c("-sb", "-sk")) {
    out <- tryCatch(suppressWarnings(
      system2("du", c(fl, shQuote(want)), stdout = TRUE, stderr = FALSE)),
      error = function(e) character(0))
    if (!length(out)) next
    bytes <- suppressWarnings(as.numeric(sub("[[:space:]].*$", "", out)))
    nm <- sub("^[^[:space:]]+[[:space:]]+", "", out)
    if (!any(!is.na(bytes))) next
    if (identical(fl, "-sk")) bytes <- bytes * 1024
    # ⚠️ 按**路径**对回去，不按 basename、也不按顺序：
    #    basename 撞名会张冠李戴（数字看着完全合理）；按顺序则依赖 du 的
    #    输出次序，而某个路径量不到（权限）时它会少一行 —— 那之后**全部
    #    错位一格**，每一个数字都合理，只有大小对不上人。
    idx <- match(normalizePath(want, mustWork = FALSE),
                 normalizePath(nm, mustWork = FALSE))
    if (any(!is.na(idx))) {
      hit <- !is.na(idx)
      res[ok][hit] <- bytes[idx[hit]]
      return(res)
    }
    # 路径一个都对不上（du 版本把路径写法改了）→ 退回按行序对，但只在
    # 行数正好相等时才敢用（不等就是上面说的错位）。
    if (length(bytes) == length(want)) {
      res[ok] <- bytes
      return(res)
    }
  }
  res
}

#' 子进程该用哪个 UTF-8 locale
#'
#' ★ V16.6 item 5：原来硬写着 `C.UTF-8`（R/executor.R 里给的 LANG/LC_ALL）。
#'   **macOS 上根本没有这个 locale** —— 传给孩子进程的表现是 libc 回退到
#'   "C"，中文输出又变回乱码，而"设过了"这件事看着已经做了。
#'
#'   探测方式：`Sys.setlocale()` 在不认识那个名字时**返回空串**（不抛异常）。
#'   探完把本进程的 locale 改回去 —— 这个函数只回答"该给孩子进程用什么"，
#'   不该顺手改应用自己的（本仓铁律：绝不 Sys.setenv 影响别的用户）。
dsapp_utf8_locale <- function() {
  cands <- c("C.UTF-8", "en_US.UTF-8", "UTF-8")
  old <- Sys.getlocale("LC_CTYPE")
  on.exit(suppressWarnings(tryCatch(Sys.setlocale("LC_CTYPE", old),
                                    error = function(e) "")), add = TRUE)
  for (c1 in cands) {
    got <- suppressWarnings(tryCatch(Sys.setlocale("LC_CTYPE", c1),
                                     error = function(e) ""))
    if (nzchar(got)) return(c1)
  }
  # 一个都没有（极少见）：给 C.UTF-8 保持和 Linux 上一致的老行为，
  # 至少不比原来差，而且 build 时能在自检里被看见。
  "C.UTF-8"
}

dsapp_fmt_bytes <- function(n) {
  if (is.null(n) || is.na(n)) return("—")
  units <- c("B", "KB", "MB", "GB", "TB")
  i <- 1
  while (n >= 1024 && i < length(units)) {
    n <- n / 1024
    i <- i + 1
  }
  if (i == 1) sprintf("%d %s", as.integer(n), units[i])
  else sprintf("%.1f %s", n, units[i])
}

#' 拼一个下拉框/单选框的选项：**名字是给人看的，值是给机器用的**
#'
#' Shiny 的 `selectInput` / `radioButtons` / `selectizeInput` 认的是
#' `c(标签 = 值)`：向量里的**值**变成 `<option value="...">`（也就是回传给
#' 服务端的那个），**名字**变成显示文本。查一下 `shiny:::selectOptions` 就
#' 能确认，它的实现是 `sprintf('<option value="%s">%s</option>', choice, label)`
#' —— `mapply(choices, names(choices))`，值在前、名字在后。
#'
#' ⚠️⚠️ 这条搞反**不会报错**，只会把"那句给人看的描述"当成值发回服务端。
#'    本项目踩过：`c("system" = dsapp_env_summary("system", cfg))` ——
#'    控件回传的是"系统环境（服务器上已装的 R / Python）"这一整句，于是
#'    `state$exec_env` 被写成这句话，执行器拿它去查 conda 环境，**每一个
#'    任务都报"环境不存在"**。界面上一切正常，选项看着也对，只有任务跑不起来。
#'
#' 所以统一走这个函数：参数名把方向写死了，传反了看得出来。
#'
#' @param values 回传给服务端的值（环境名、id 之类）
#' @param labels 显示文本，和 values 等长
#' @return 带名字的字符向量，可直接交给 choices=
dsapp_choices <- function(values, labels) {
  values <- as.character(values)
  labels <- as.character(labels)
  if (length(values) != length(labels)) {
    stop(sprintf("dsapp_choices(): values 有 %d 个，labels 有 %d 个",
                 length(values), length(labels)))
  }
  stats::setNames(values, labels)
}

#' 这个路径是不是一个符号链接
#'
#' ⚠️ **不要直接写 `nzchar(Sys.readlink(p))`** —— 这个写法在这里是反的，
#'    而且反得看不出来：
#'
#'      * `Sys.readlink()` 对**不存在的路径**返回 `NA`（不是 ""）
#'      * R 里 `nzchar(NA)` 默认是 **TRUE**
#'
#'    于是 `nzchar(Sys.readlink(p))` 对"不存在的路径"回答 TRUE，
#'    对"真实存在的普通文件"回答 FALSE —— 正好把两种最要紧的情况搞反了。
#'    它不会报错，只会让 `if (nzchar(Sys.readlink(d))) next` 这类守卫
#'    永远跳过所有目标，功能静默失效。
#'
#'    这个坑在本项目里被踩过一次：工作区镜像**一个文件都没挂上**，
#'    而单元测试因为用了同一个错误写法，全都是绿的。
#'
#' @return 逻辑值，长度与 path 相同；不存在的路径一律 FALSE
dsapp_is_link <- function(path) {
  if (!length(path)) return(logical(0))
  r <- Sys.readlink(path)
  !is.na(r) & nzchar(r)
}

#' 清理上传文件名
#'
#' 这是安全边界，不是美观问题：文件名来自浏览器，可能带 ../ 或绝对路径。
#' 直接拼进目标路径就等于把任意写文件的能力交出去了。
dsapp_safe_name <- function(name) {
  if (is.null(name) || !nzchar(name)) return("unnamed")

  # 只取最后一段，去掉任何目录成分（同时处理 / 和 Windows 的 \）
  name <- gsub("\\\\", "/", name)
  name <- basename(name)

  # 去掉控制字符和路径分隔残留
  name <- gsub("[[:cntrl:]]", "", name)

  # 以点开头的名字（. 和 ..）以及空名一律替换掉
  if (!nzchar(name) || grepl("^\\.+$", name)) return("unnamed")

  # 控制长度，给扩展名留出空间
  if (nchar(name) > 200) {
    ext <- tools::file_ext(name)
    stem <- substr(name, 1, 180)
    name <- if (nzchar(ext)) paste0(stem, ".", ext) else stem
  }
  name
}

#' 防止同目录下重名覆盖
#'
#' 上传两张都叫 expr.csv 的表是很常见的，直接覆盖会静默丢数据。
#' 改成 expr.csv → expr(1).csv。
dsapp_unique_path <- function(dir, name) {
  name <- dsapp_safe_name(name)
  target <- file.path(dir, name)
  if (!file.exists(target)) return(target)

  ext  <- tools::file_ext(name)
  stem <- if (nzchar(ext)) sub(paste0("\\.", ext, "$"), "", name) else name

  for (i in seq_len(999)) {
    candidate <- file.path(dir, paste0(stem, "(", i, ")",
                                       if (nzchar(ext)) paste0(".", ext) else ""))
    if (!file.exists(candidate)) return(candidate)
  }
  # 999 个重名还没排开，基本不可能；兜底加个随机后缀而不是死循环
  file.path(dir, paste0(stem, "-", as.integer(Sys.time()),
                        if (nzchar(ext)) paste0(".", ext) else ""))
}

#' 对话工作区
#'
#' 每个对话一块自己的地，这个对话里所有任务的代码都在这里执行。
#'
#' 为什么是"每个对话"而不是"每个任务"：任务之间要能看见彼此的产物 ——
#' 第一步跑完的中间文件，第二步得能直接读。每次执行换一个新目录的话，
#' 模型每一轮都是从头开始，"接着上一步继续"这件事就无从谈起。
#'
#' ⚠️ 旧的 data/work/task-<id>/ 是**每次执行 unlink 重建**的，那个模型下
#'    产物只能靠拷回全局共享区来传递。现在产物就留在工作区里，共享区
#'    退化成"用户上传区"，发布是显式动作。见 executor.R 顶部。
#'
#' 路径由 session_id 推导，不落库 —— 少一列就少一处会和真实目录不一致的
#' 状态。sid 为 NULL 时返回 NA：还没有对话就没有工作区，调用方自己决定
#' 这时候该怎么办。
#' 对话工作区的目录名
#'
#' ⚠️ 这里以前写的是 `sprintf("chat-%d", as.integer(sid))`，是**错的**，
#'    而且错得很安静：真实的 session_id 长这样 —— `s-20260912170855-3349`
#'    （见 dsapp_id），`as.integer()` 一转换就是 NA，于是每一个对话的工作区
#'    都叫 `chat-NA`，**所有对话、所有用户共用同一块地**。扫描、隔离、发布、
#'    删除全都落在同一个目录上：一个人 `rm -rf *` 就是所有人一起没。
#'
#'    自测没抓住是因为那里的夹具用了 `sidA <- 7L` 这种整数 —— 整数能转换，
#'    于是测试全绿。夹具的形状一旦和真实数据不一样，测出来的绿是假的。
#'
#' 洗字符是防目录穿越：sid 会直接拼进文件路径，虽然它目前由应用自己生成，
#' 但"路径安全"不该建立在"上游永远不作恶"上面。
#'
#' ⚠️ 这个函数**必须是向量化的**。原来写的是 `as.character(sid)[1]` —— 传一个
#'    向量进来只会取第一个，剩下的静默丢掉。管理页统计每个人的磁盘用量时，
#'    传的是"全部对话的 id"，于是**所有账号都按第一个对话的工作区算**：
#'    data.frame(user_id = <n 个>, bytes = <1 个>) 不报错，R 会把那一个值
#'    循环填满整列，页面显示得完完整整，数字全是错的。自测里就是它让
#'    "甲的用量"显示成 70 字节。取标量的写法在别处也许无害，在这里是错的，
#'    因为唯一的向量调用点同时是最要命的那个（统计）。
dsapp_ws_name <- function(sid) {
  if (!length(sid)) return("chat-unknown")
  s <- as.character(sid)
  # NA 先补掉：gsub 在 NA 上是原样返回 NA，后面的 nzchar(NA) 又是 TRUE，
  # 一路漏到 paste0 就是 "chat-NA" —— 又是一个共享目录。
  s[is.na(s)] <- "unknown"
  s <- gsub("[^A-Za-z0-9._-]", "_", s)
  s[!nzchar(s) | s %in% c(".", "..")] <- "unknown"
  paste0("chat-", s)
}

#' 从**模块里**跳到别的页签
#'
#' ⚠️ 模块里不能直接用 `bslib::nav_select("nav", tab)`，也不能用模块自己那个
#' `session` —— 模块的 session 是 session_proxy，`sendInputMessage` 会给 id
#' 加上模块命名空间（"nav" 变成 "chat-nav"），页面上没有那个元素，于是
#' **静默失效：不报错，就是点了没反应**。传 `session = session` 一样不行
#' （那个 session 也是代理），`session$parent` 也不行 —— 2026-09-14 用最小
#' Shiny 应用把四种写法都实测过，只有顶层调 nav_select 跳得动。
#'
#' 所以顶层 session 由 app.R 在服务端启动时存进 `state$root_session`，这里取
#' 出来用。app.R 里那段有完整的来龙去脉。
#'
#' @param state  app.R 建的 reactiveValues（里面有 root_session）
#' @param tab    nav_panel 的 **value**（"chat"/"files"/…），不是标题
#' @return 成功 TRUE；拿不到顶层 session 时 FALSE（不抛异常 —— 跳转失败不该
#'   把调用它的那个 observeEvent 一起炸掉）
dsapp_nav_to <- function(state, tab) {
  root <- tryCatch(state$root_session, error = function(e) NULL)
  if (is.null(root)) return(FALSE)
  ok <- tryCatch({
    bslib::nav_select("nav", tab, session = root)
    TRUE
  }, error = function(e) FALSE)
  ok
}

#' 模块里要发自定义消息 / 重载页面时，用这个拿 session
#'
#' ⚠️⚠️ 模块里那个 `session` 是 **session_proxy**，不是真的 ShinySession。
#'    经验事实（2026-09-15，V9 item 1 实测）：在它上面调 `sendCustomMessage`
#'    和 `reload` **不报错、也不生效** —— 日志干干净净，浏览器里什么都没发生。
#'    症状就是"点了没反应"，而刷新一下又对了。
#'
#'    这个仓库里对"到底哪些方法能用"有过两种互相矛盾的说法（app.js 的
#'    dsapp:rail-model 那条注释说能用，skins.R 的 dsapp_skin_apply 说不能用），
#'    两边都有"修好了"的记录 —— 说明它要么和调用时机有关，要么当年修的是
#'    别的东西。**别再去考古了**：顶层那一份（app.R 里 `state$root_session`）
#'    在两种说法下都是对的，统一走它。
#'
#' ⚠️ 默认值必须用 `is.null()` 判，**不能**写 `state$root_session %||% session`。
#'    `%||%` 是 `length(a) == 0` 那套判断，而 **environment 的 length 恒为 0**，
#'    于是它对任何一个 session 都返回 fallback —— 静默退回模块 session，
#'    正好是这里要避开的那个。
#'
#' ⚠️ 读 `state$root_session` 包了 tryCatch：state 是 reactiveValues，在响应式
#'    上下文之外读会抛。调用点大多在 observeEvent 里（安全），但
#'    dsapp_nav_to 那条路已经证明了"总有人会在外面调它"。
dsapp_session <- function(state, session, what = "操作") {
  root <- tryCatch(state$root_session, error = function(e) NULL)
  if (is.null(root)) {
    warning(sprintf("%s：拿不到顶层 session，这个动作可能不会生效", what),
            call. = FALSE)
    return(session)
  }
  root
}

dsapp_ws_dir <- function(sid, cfg = dsapp_config(), create = TRUE) {
  if (is.null(sid) || length(sid) == 0 || is.na(sid)) return(NA_character_)
  d <- file.path(cfg$ws_root, dsapp_ws_name(sid))
  if (isTRUE(create) && !dir.exists(d)) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  d
}

# =============================================================================
# 任务标题（V9 item 7）
# =============================================================================
# 用户的原话：「任务中的标题无法区分，请以"任务功能_所属会话"作为标题」。
#
# 原样是 `sprintf("%s 代码", lang)` —— 任务页排下来一整列「R 代码」，
# 除了看时间没有任何办法分辨哪一行是干什么的。跑过二十次之后那一页就是
# 二十行一模一样的东西。
#
# 拼法只有两种输入：功能从**代码上方的正文**里取，会话从 sessions.title 取。
# 之所以不塞进 db_task_create：那个函数在 db.R，而"从消息里抠一句话"是
# 渲染层的事，两边放一起会让 db.R 依赖 render.R。放在这里居中。
# =============================================================================

#' 把一行 Markdown 洗成能当标签用的短句
#'
#' 「## 2. **差异分析**（DESeq2）」→「差异分析（DESeq2）」
#' 标题、列表、引用、有序列表、加粗、行内代码的标志全去掉 —— 这些符号留在
#' 一个任务标题里只会占地方，而标题要在任务页那一列里塞得下。
dsapp_label_line <- function(x) {
  if (is.null(x) || !length(x) || is.na(x)) return("")
  x <- as.character(x)[1]
  x <- gsub("^[[:space:]]*[#>]+[[:space:]]*", "", x)          # 标题 / 引用
  x <- gsub("^[[:space:]]*[-*+][[:space:]]+", "", x)          # 无序列表
  x <- gsub("^[[:space:]]*[0-9]+[.)][[:space:]]*", "", x)     # 有序列表
  x <- gsub("\\*\\*|__|`", "", x)                             # 加粗 / 行内代码
  x <- gsub("[[:space:]]+", " ", x)
  trimws(x)
}

#' 把界面文案里的 `**加粗**` 渲染出来（V13.4 item 3）
#'
#' 界面文案里有不少地方写了 markdown 的加粗（`**…**`），但那些字符串是
#' **直接**塞进 `tags$span()` / `showNotification()` 的 —— 那条路上没有
#' markdown 渲染这一步，于是用户看到的是**两个字面的星号**。管理页那句
#' 「工作区是**每个对话**一块」就是这么来的：写的时候是强调，显示出来是噪声。
#'
#' 用法：**只在这个字符串要变成界面文字的那一处**套一层。别在产生数据的函数
#' 里套 —— 那些函数的返回值还会被喂给模型、写进日志、拿去断言，那些地方要的
#' 是纯文本（`R/scanner.R` 的 `dsapp_scan_message()` 就是两头都要用的例子，
#' 它靠一个 `md` 参数分开，而不是改自己的返回类型）。
#'
#' ⚠️ 返回的是 `HTML()`，也就是**绕过 shiny 的自动转义**。所以：
#'   - **先转义、再替换**，顺序不能反。反过来文本里一个 `<script>` 会被当成
#'     标签留下 —— 后半段替换出来的 `<strong>` 才是我们唯一想放行的那一种。
#'   - 也正因为先转义了，它可以安全地用在"拼了用户数据"的句子上
#'     （`R/share.R` 那条通知里就嵌着用户填错的邮箱）。
#'   - 但**绝不要**拿它去渲染模型输出或整篇 markdown。那是 `R/render.R` 的
#'     `dsapp_md_html()` 干的活（走 commonmark，认得标题/列表/代码块）。
#'     这里只认加粗一种 —— 调用方要的就是"一句话里那几个字重一点"，
#'     多认几种反而会在"用户正文里本来就有星号"的地方吃出意外。
dsapp_md_inline <- function(x) {
  if (is.null(x) || !length(x)) return(HTML(""))
  x <- paste(as.character(x), collapse = " ")
  x <- htmltools::htmlEscape(x)
  # ⚠️ 用 [^*]+ 而不是 .+ ：一段话里出现两个**不配对**的星号时（正文里写
  #    "2*3 和 4*5" 就会），.+ 会把中间整段吞掉变成粗体。宁可这一对不渲染。
  x <- gsub("\\*\\*([^*]+)\\*\\*", "<strong>\\1</strong>", x)
  HTML(x)
}

#' 这段代码上面那句话说的是什么
#'
#' 从**同一段代码所在的那条助手消息**里，取它正上方最近的一段正文，
#' 再取那一段里第一行有内容的。
#'
#' ⚠️ 按 `code` 内容找块，不按"第几个块"。一条消息里可能有三个代码块，
#'    用户在第二个上点了执行，拿第一个上面的正文就是张冠李戴 ——
#'    而标题恰恰是用户用来认"我跑的是哪一次"的东西。
dsapp_task_feature <- function(content, code) {
  if (is.null(content) || !length(content) || is.na(content) ||
      !nzchar(content) || is.null(code) || !nzchar(code)) {
    return("")
  }
  segs <- tryCatch(dsapp_split_segments(as.character(content)[1]),
                   error = function(e) list())
  if (length(segs) == 0) return("")

  hit <- NA_integer_
  for (i in seq_along(segs)) {
    if (identical(segs[[i]]$type, "code") && identical(segs[[i]]$code, code)) {
      hit <- i
      break
    }
  }
  if (is.na(hit)) return("")

  # 从命中处往上找最近的一段正文。中间隔着别的代码块也照样往上找 ——
  # 模型常写"第一段…\n```\n…\n```\n第二段…\n```"，用户在第二个块上执行，
  # 那个"第二段…"才是它的说明。
  for (i in rev(seq_len(hit - 1L))) {
    if (!identical(segs[[i]]$type, "text")) next
    lines <- strsplit(segs[[i]]$text, "\n", fixed = TRUE)[[1]]
    for (ln in lines) {
      lab <- dsapp_label_line(ln)
      # 太短的（"代码："）当不了标签，继续往下找。
      if (nchar(lab) >= 4) return(lab)
    }
  }
  ""
}

#' 任务标题 = 任务功能_所属会话
#'
#' @param code       要执行的代码
#' @param lang       语言（取不到功能时退化成「<语言> 代码」）
#' @param session_id 所属对话
#' @param con        数据库连接
#' @param max        整条标题的长度上限。任务页那一列宽度有限，标题太长会
#'                   把「状态/时间」几列挤出去。
#'
#' @return 字符串。任何一步取不到东西都有兜底，**永远不返回空串** ——
#'   标题是 NOT NULL 列，返回 NULL 会让 db_task_create 直接抛。
dsapp_task_title <- function(code, lang = "R", session_id = NULL,
                             con = dsapp_db(), max = 48L) {
  feat <- ""
  sess <- ""

  sid <- if (is.null(session_id) || !length(session_id)) NA_character_
         else as.character(session_id)[1]

  if (!is.na(sid) && nzchar(sid)) {
    # 这条对话的消息。倒着找：命中的几乎总是最后几条，而一个长对话可能有
    # 几百条 —— 正着扫每次执行都要走完全程。
    msgs <- tryCatch(
      DBI::dbGetQuery(con,
        "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id DESC",
        params = list(sid)),
      error = function(e) NULL)

    if (!is.null(msgs) && nrow(msgs) > 0) {
      for (i in seq_len(nrow(msgs))) {
        if (!identical(as.character(msgs$role[i]), "assistant")) next
        f <- dsapp_task_feature(msgs$content[i], code)
        if (nzchar(f)) { feat <- f; break }
      }
      # 助手那句话里没有正文（模型直接甩代码是常事）→ 退回用户那条提问。
      # 顺序不能反：用户问的是"帮我做差异分析"，模型答的是"下面用 DESeq2
      # 做差异分析"，两个都能认，但后者更贴近**这一段代码**在干什么。
      if (!nzchar(feat)) {
        for (i in seq_len(nrow(msgs))) {
          if (!identical(as.character(msgs$role[i]), "user")) next
          for (ln in strsplit(as.character(msgs$content[i]), "\n",
                              fixed = TRUE)[[1]]) {
            lab <- dsapp_label_line(ln)
            if (nchar(lab) >= 4) { feat <- lab; break }
          }
          if (nzchar(feat)) break
        }
      }
    }

    sess <- tryCatch({
      t <- DBI::dbGetQuery(con, "SELECT title FROM sessions WHERE id = ?",
                           params = list(sid))$title
      if (length(t) && !is.na(t[[1]])) dsapp_label_line(as.character(t[[1]])) else ""
    }, error = function(e) "")
  }

  if (!nzchar(feat)) feat <- sprintf("%s 代码", lang)

  # 会话名和功能名一模一样时不重复一遍（新建对话时标题就是第一句提问，
  # 于是「差异分析_差异分析」—— 看着像 bug）。
  if (!nzchar(sess) || identical(feat, sess)) {
    return(substr(feat, 1, max))
  }

  # 两边各让一步，别让功能那半截把会话名整个挤掉
  half <- max %/% 2L
  substr(paste0(substr(feat, 1, max - half - 1L), "_",
                substr(sess, 1, half)), 1, max)
}

#' 这一行任务是不是挂在某个对话上
#'
#' 用来回答"现在跑着的这个任务，是不是我正要删掉/正要离开的那个对话的"。
#'
#' ⚠️ 两边必须是**字符串**比较，绝不能过 as.integer()。
#'    任务号是自增整数，对话号不是（形如 `s-20260913145800-4279`）。
#'    `as.integer(sid)` 不报错，它给 NA；两边都成了 NA，`identical()` 又是
#'    TRUE —— 于是"只停本对话的任务"这道闸门静默变成"停任何任务"：
#'    用户在 A 对话点删除（或直接关掉页面），会把 B 对话里正跑着的任务杀掉，
#'    界面上只是任务莫名其妙失败了，日志里一行错都没有。
dsapp_task_in_session <- function(trow, sid) {
  if (is.null(trow) || is.null(sid)) return(FALSE)
  if (!"session_id" %in% names(trow)) return(FALSE)
  a <- as.character(trow$session_id)[1]
  b <- as.character(sid)[1]
  if (is.na(a) || is.na(b) || !nzchar(a) || !nzchar(b)) return(FALSE)
  identical(a, b)
}

#' 工作区里的文件清单（不含我们自己塞进去的隐藏文件）
#'
#' 上传到共享区的文件会以只读软链的形式出现在每个工作区里，这里用
#' all.files = FALSE 把 .dsapp_* 排除掉，软链仍会列出来。
dsapp_ws_files <- function(sid, cfg = dsapp_config()) {
  d <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(d) || !dir.exists(d)) return(character(0))
  list.files(d, all.files = FALSE, no.. = TRUE)
}

#' 一段字节里，前多少个字节构成**完整**的 UTF-8 字符
#'
#' 流式输出和日志尾巴都是"从文件中间某个字节开始读"的，那个位置可能正好落在
#' 一个多字节字符中间（写完一个 delta 就 flush，边界与字符边界无关）。从此处
#' rawToChar 会得到无效编码的字符串：界面上是乱码，而且 strsplit / fromJSON
#' 这类函数在无效编码上要么警告要么直接失败 —— 一个字符没对齐，整行都白读。
#'
#' 于是统一在这里算"能安全解码到哪里"：返回值之前的字节都是完整字符，之后的
#' 那几个字节留给下一轮（下一轮它们会跟后续字节拼成完整字符）。
#'
#' @return 0..length(bytes) 的整数
dsapp_utf8_complete <- function(bytes) {
  n <- length(bytes)
  if (n == 0) return(0L)

  # 从末尾往前退，跳过续字节（10xxxxxx），停在最后一个字符的首字节上
  i <- n
  while (i > 0L && bitwAnd(as.integer(bytes[i]), 0xC0L) == 0x80L) i <- i - 1L
  if (i == 0L) return(0L)   # 整段都是续字节：不该发生，宁可等下一轮

  lead <- as.integer(bytes[i])
  need <- if (lead < 0x80L) 1L else if (lead < 0xE0L) 2L
          else if (lead < 0xF0L) 3L else 4L

  if (i + need - 1L <= n) n else i - 1L
}

#' 安全地把字节解码成字符串（只解码完整的字符）
#'
#' @return list(txt, used) —— used 是实际吃掉的字节数，调用方据此推进位置。
dsapp_raw_to_utf8 <- function(bytes) {
  used <- dsapp_utf8_complete(bytes)
  if (used <= 0L) return(list(txt = "", used = 0L))
  txt <- tryCatch(rawToChar(bytes[seq_len(used)]), error = function(e) "")
  if (nzchar(txt)) Encoding(txt) <- "UTF-8"
  list(txt = txt, used = used)
}

#' 根据扩展名猜语言，用于代码高亮和选择执行器
dsapp_lang_of <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("r", "rmd")) return("R")
  if (ext %in% c("py")) return("Python")
  if (ext %in% c("sh", "bash")) return("Bash")
  "Text"
}

#' 读取文件末尾若干行
#'
#' 用于日志预览。大文件不能整个读进来 —— 一个几 G 的日志会把 R 进程撑爆。
dsapp_tail <- function(path, n = 200, max_bytes = 262144) {
  if (!file.exists(path)) return("")
  size <- file.info(path)$size
  if (is.na(size) || size == 0) return("")

  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)

  # 先从末尾读一段，再按行切。比 readLines 整个文件快几个数量级。
  read_bytes <- min(size, max_bytes)
  seek(con, where = size - read_bytes, origin = "start")
  raw <- readBin(con, "raw", n = read_bytes)
  # 起点可能落在多字节字符中间，先对齐到字符边界再解码（见 dsapp_utf8_complete）
  txt <- dsapp_raw_to_utf8(raw)$txt

  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  # 第一行可能是被截断的半行，丢掉；除非本来就只读到了开头
  if (read_bytes < size && length(lines) > 1) lines <- lines[-1]

  paste(utils::tail(lines, n), collapse = "\n")
}

#' 读一份用户上传的文本文件，编码猜两次
#'
#' 中文用户在 Windows 上用记事本写的 .md / .txt 多半是 GBK。按 UTF-8 读进来
#' 会得到一串乱码 —— 而且**不会报错**：技能会以乱码的样子静静地存进去，
#' 环境配置会解析出一堆乱码包名，用户要等下次用的时候才发现。所以先按
#' UTF-8 试，读出无效字节再退回 GBK。
#'
#' ⚠️ 判据用 `iconv(txt, "UTF-8", "UTF-8")` 会不会产生 NA，而不是
#'    `validUTF8()`：后者对"能解码但被替换过"的串也点头。这条是从技能
#'    导入那边原样搬过来的（V8 item 1），行为不要改。
#'
#' ⚠️ 两个地方在用（技能导入、环境配置上传），**别各写一份** —— 编码这种
#'    东西修 bug 只会修到其中一份，另一份继续静静地存乱码。
dsapp_read_text_file <- function(path) {
  # suppressWarnings：文件不存在时 file() 会警告，返回的 NULL 已经由
  # tryCatch 接管；这条警告会飘进 Shiny 的日志，而它描述的正是调用方
  # 已经处理掉的情况。
  txt <- tryCatch(suppressWarnings(
           paste(readLines(path, warn = FALSE, encoding = "UTF-8"),
                 collapse = "\n")),
                  error = function(e) NULL)
  if (is.null(txt)) return(NULL)
  if (!any(is.na(iconv(txt, "UTF-8", "UTF-8")))) return(txt)

  # ⚠️ 回退这一半必须走 `file(encoding = "GBK")`，**不能**写
  #    `readLines(path, encoding = "GBK")`。
  #
  #    readLines 的 encoding 参数只认得 "latin1" 和 "UTF-8" —— 它的作用
  #    是"给读进来的串**打上**这个编码的标记"，不是"按这个编码**转**一遍"。
  #    传 "GBK" 进去不会报错，也不会转换，返回的还是那串无效字节。
  #    于是就出现这个最难查的形态：**回退分支跑了，判据也是 NA，返回的
  #    却还是乱码** —— 因为两次读出来的东西一模一样。表现是 GBK 文件传
  #    上来"没报错、也没生效"，用户看到编辑器没反应。
  #
  #    file(description, encoding=) 才是真的转码（内部走 iconv）。
  alt <- tryCatch(suppressWarnings({
    con <- file(path, open = "r", encoding = "GBK")
    on.exit(close(con), add = TRUE)
    paste(readLines(con, warn = FALSE), collapse = "\n")
  }), error = function(e) NULL)
  if (!is.null(alt) && !any(is.na(iconv(alt, "UTF-8", "UTF-8")))) {
    Encoding(alt) <- "UTF-8"
    return(alt)
  }
  txt
}

#' 截断过长的输出
#'
#' 执行结果要存进 SQLite 并在页面上渲染。不截断的话，一个打印百万行的
#' 循环就能把数据库和浏览器一起拖垮。
#'
#' keep 决定留哪一头，默认留开头（日志的结论通常在前面）。stderr 要传
#' "tail"，理由见下面。
dsapp_truncate <- function(x, max_kb = 512, keep = c("head", "tail")) {
  keep <- match.arg(keep)

  # ⚠️ NA 必须在这里挡掉，这不是防御性编程。
  #
  # db.R 的 nn() 让「调用方没提供」的 stdout/stderr 落库时是 NA 而不是 ""。
  # 而 nzchar(NA) 返回 TRUE、nchar(NA, type = "bytes") 返回 NA，于是下面
  # 那个 if (NA) 直接抛 "missing value where TRUE/FALSE needed"。
  # 崩的正好是「任务失败、没产出 stdout」那条路径 —— 也就是最需要看到
  # 报错的时候。IS NA 和 nzchar 都要判，二者互不覆盖。
  if (is.null(x) || is.na(x) || !nzchar(x)) return("")

  limit <- max_kb * 1024
  if (nchar(x, type = "bytes") <= limit) return(x)

  # ---- 按行丢，不按字节切 ----
  #
  # ⚠️ 这里以前是 `substr(x, 1, limit)` 再 `sub("[^�]*$", "", ...)` 收尾。
  #    那第二句会把**整个字符串清空**：R 的正则是 TRE，方括号里的多字节
  #    字符被当成了三个独立字节（0xEF 0xBF 0xBD），于是 [^�] 变成"这三个
  #    字节以外的任意字节"——普通 ASCII 全都满足，[^�]*$ 从开头一路吃到
  #    结尾，sub 就把整段替换成了空串。
  #
  #    后果不是"少截一点"，是**超长输出整个消失**：任务页上只剩一句
  #    "… [输出过长，已截断，仅保留前 512 KB]"，正文一个字都没有。一个
  #    打印了几百 KB 的失败任务，用户看到的是空白 —— 正好是最需要看日志
  #    的时候。ASCII 和中文都中招，只有"恰好没超限"的输出不受影响。
  #
  # 现在改成按行取舍：多字节字符不会出现在行中间被劈开的位置，丢掉的
  # 是完整的行（读起来不会从半句话开始），而且 head / tail 两条路对称。
  lines <- strsplit(x, "\n", fixed = TRUE)[[1]]
  sizes <- nchar(lines, type = "bytes")

  if (identical(keep, "head")) {
    # cum[i] = 第 1 行到第 i 行的字节数（含换行）
    cum <- cumsum(sizes + 1L)
    ok  <- which(cum <= limit)
    body <- if (length(ok)) {
      paste(lines[seq_len(max(ok))], collapse = "\n")
    } else {
      # 第一行单独就超限了（一个几百 KB 的 JSON 挤在一行里）。按行丢没有
      # 意义，退回按字符截这一行 —— substr 在 UTF-8 字符串上按**字符**
      # 计数，不会把汉字劈成半个。
      substr(lines[1], 1, limit)
    }
    return(paste0(body,
      sprintf("\n\n… [输出过长，已截断，仅保留前 %s]", dsapp_fmt_bytes(limit))))
  }

  # ---- keep = "tail"：保留结尾 ----
  #
  # 为什么 stderr 必须走这条：R 的 traceback、Python 的 Traceback 都印在
  # 输出的**最末尾**。只留开头的话，看到的是满屏正常的日志，最后那句
  # "Error in ..." 正好被切掉 —— 最该看的一行没了。
  #
  # cum[i] = 第 i 行到末尾的字节数（每行都算上一个换行符，末行多算一个，
  # 偏保守一个字节，无所谓）。取满足限额的**最早**一行，就能留下尽量多的
  # 尾部内容。
  cum <- rev(cumsum(rev(sizes + 1L)))
  ok  <- which(cum <= limit)

  tail_txt <- if (length(ok)) {
    paste(lines[min(ok):length(lines)], collapse = "\n")
  } else {
    n <- nchar(lines[length(lines)])
    substr(lines[length(lines)], max(1, n - limit + 1), n)
  }

  paste0(sprintf("… [输出过长，已截断，仅保留末尾 %s]\n\n",
                 dsapp_fmt_bytes(limit)),
         tail_txt)
}

#' 读「自动执行轮数」滑块的值，任何异常输入都退回默认值
#'
#' ⚠️ 存在的理由是**三种**"看起来像没值"的输入，只有第一种能被 %||% 挡住：
#'      NULL         —— 滑块还没建起来（%||% 管这个）
#'      integer(0)   —— 建起来了但这一次 flush 里没有值（%||% **不管**：
#'                      它判的是 is.null，空向量不是 NULL，会原样放行）
#'      NA / 0 / 负数 —— 用户拖到了边界、或者前端被人改过
#'    放行空向量的后果不是"用默认值"，而是 `a$iter >= a$max_iter` 求值成
#'    logical(0)，`if (logical(0))` 抛错 —— 报错点在 agent 循环里，离这里
#'    很远，"轮数没设上"这句话在堆栈里一个字都看不到。
dsapp_iter_value <- function(x) {
  # ★★ V16.3 item 4：「轮数」也有不设上限这一档了（见 config.R 的
  #   DSAPP_AGENT_ITER_UNLIMITED）。这一句**必须排在下面那句钳制前面**，
  #   和 dsapp_wall_value() 里同一位置的同一句话是一个道理：
  #   min(Inf, 20) 算出来是 20 —— 不报错、不警告，用户勾的是"不设上限"，
  #   跑起来 20 轮就被掐断，而他第二天回来看见「已达轮次上限（20 轮）」。
  #   ⚠️ 判据用 !is.finite 而不是 == Inf：JSON 往返（脱离会话那个 blob、
  #      后台子进程的参数）里 Inf 会变成字符串 "Inf"，as.numeric 解得回来。
  n0 <- suppressWarnings(as.numeric(x))
  if (length(n0) == 1L && !is.na(n0) && !is.finite(n0)) return(Inf)
  n <- suppressWarnings(as.integer(x))
  if (length(n) != 1L || is.na(n) || n < 1L) return(DSAPP_AGENT_MAX_ITER)
  min(n, DSAPP_AGENT_ITER_MAX)
}

#' 这个轮数上限是不是"不设上限"
#'
#' 和 dsapp_wall_is_unlimited() 同一个形状（NULL / 空向量 / NA 一律**不算**
#' 不设上限 —— 那是"还没设过"，该走默认的 6 轮）。
dsapp_iter_is_unlimited <- function(x) {
  n <- suppressWarnings(as.numeric(x))
  length(n) == 1L && !is.na(n) && !is.finite(n)
}

#' 轮数上限跨边界（落库那一个 INTEGER 列 / callr 传给后台子进程）时用
#'
#' ⚠️ 存在的唯一理由是 `as.integer(Inf)` 是 **NA**（还带一条 warning）：
#'    后台那条路（`dsapp_arun_begin()` / `dsapp_detach_start()`）原来直接
#'    `as.integer(max_iter)`，于是"不设上限"到了子进程里变成 NA，
#'    `dsapp_iter_value(NA)` 兜回 **6 轮** —— 用户勾了不设上限、关掉页面让
#'    它自己跑，跑 6 轮就停了，而对话里那句「已达轮次上限（6 轮）」看起来
#'    完全正常。这是本仓最忌讳的"界面说 A、代码做 B"。
#'    （SQLite 那个列是 INTEGER affinity，实测存得下 Inf：typeof 是 real。）
dsapp_iter_store <- function(x) {
  if (isTRUE(dsapp_iter_is_unlimited(x))) return(Inf)
  as.integer(x)
}

#' 轮数上限"说人话"（界面上那句「第 N/M 轮」的分母）
#'
#' ⚠️ **不能**直接 sprintf("%d", max_iter)：`sprintf("%d", Inf)` 抛
#'    "invalid format '%d'; use format %f, %e, %g or %a for numeric objects"
#'    —— 报错点在渲染函数里，用户看到的是整块状态条不见了，而堆栈里一个字
#'    都没提"轮数"。（实测。）
dsapp_iter_label <- function(x) {
  if (isTRUE(dsapp_iter_is_unlimited(x))) return("不限")
  as.character(dsapp_iter_value(x))
}

#' 读「自动结束时间」滑块的值（秒），任何异常输入都退回默认值
#'
#' ★ V13.17 item 31。和 dsapp_iter_value() 是**同一个坑的两份**（NULL /
#'   integer(0) / NA），所以写法照抄，只把两端换成时长那一对常量。
#'
#' ⚠️ 两者**不能合并成一个函数**：轮数的兜底是 DSAPP_AGENT_MAX_ITER（6），
#'    时长的是 DSAPP_AGENT_WALL_DEF（7200）。合并之后"拿轮数的默认值去兜时长的底"
#'    会得到 6 秒 —— 不报错，只是每次自动执行活 6 秒就停。这种错要等到用户
#'    抱怨"跑一下就自己停了"才看得见。
#'
#' ⚠️ 这里是**钳制**（clamp）不是校验报错：滑块的值在前端可以被改，
#'    越界时把闸门收到允许范围内，比抛错好 —— 抛错的话整个 agent 循环起不来，
#'    而用户只是把滑块拖过头了而已。
dsapp_wall_value <- function(x) {
  n <- suppressWarnings(as.numeric(x))
  if (length(n) != 1L || is.na(n) || n <= 0) return(DSAPP_AGENT_WALL_DEF)
  # ★ V16.1 item 5：「不设上限」在值域里就是 Inf（见 config.R 的
  #   DSAPP_AGENT_WALL_UNLIMITED）。
  # ⚠️ 这一句必须排在下面那句 min/max **前面**：min(max(Inf, 1800), 28800)
  #    算出来是 28800 —— 不报错、不警告，用户选的是"不设上限"，跑起来却
  #    八小时准时被掐断。而这种错要等到他第二天回来看见"已达自动结束时间"
  #    才知道，那时候已经没法复现了。
  # ⚠️ 判据用 !is.finite 而不是 == Inf：JSON 往返（脱离会话那个 blob）里
  #    Inf 会变成字符串 "Inf"，as.numeric 解得回来；但 -Inf 走的是上面那句
  #    （-Inf <= 0 为真 → 退回默认值），这是有意的：负的时长没有含义，
  #    宁可退回默认值，也不要把它当成"永不过期"。
  if (!is.finite(n)) return(DSAPP_AGENT_WALL_UNLIMITED)
  min(max(n, DSAPP_AGENT_WALL_MIN), DSAPP_AGENT_WALL_MAX)
}

#' 这个时长是不是"不设上限"
#'
#' ★ V16.1 item 5。写成函数而不是到处 `is.infinite()`，是因为**判据只有一处**
#'   才好改：哪天真要换个表示法（比如 NA），改这里就够，不用去 grep。
#'
#' ⚠️ 先过 as.numeric 再判：这个值会在数据库 blob（jsonlite）里往返一趟，
#'    Inf 到那边是**字符串** "Inf"，不转的话 is.finite("Inf") 直接抛错。
dsapp_wall_is_unlimited <- function(x) {
  n <- suppressWarnings(as.numeric(x))
  length(n) == 1L && !is.na(n) && !is.finite(n) && n > 0
}

#' 读「自动结束时间」**滑块**的值（单位是**小时**，滑块自己的刻度）
#'
#' ★ V16.1 item 5。滑块的最右一格是"不设上限"，它的刻度值是
#'   DSAPP_AGENT_WALL_SLIDER_UNLIM（8.5 小时，比最高档 8 小时再高一格）。
#'
#' ⚠️⚠️ 这个"翻译"必须单独有一个函数，不能让调用方写 `input$agent_wall * 3600`
#'    了事。8.5 × 3600 = 30600 是一个**看着完全合法**的秒数（比 8 小时只多
#'    半小时），喂给 dsapp_wall_value() 会被钳成 28800 —— 于是"不设上限"
#'    这一档从头到尾没生效过，而界面上那个小字走的是 dsapp_wall_label()，
#'    它念的是……也是 8 小时。**界面和实际行为一致地说着同一句错话**，
#'    没有任何东西会红。所以换算只能有一个入口。
dsapp_wall_from_slider <- function(x) {
  h <- suppressWarnings(as.numeric(x))
  if (length(h) != 1L || is.na(h)) return(DSAPP_AGENT_WALL_DEF)
  if (abs(h - DSAPP_AGENT_WALL_SLIDER_UNLIM) < 1e-9) {
    return(DSAPP_AGENT_WALL_UNLIMITED)
  }
  dsapp_wall_value(h * 3600)
}

#' 把秒数说成人话：「2 小时」「30 分钟」「2.5 小时」「不设上限」
#'
#' ★ V13.17 item 31。滑块上下都摆着秒，但没有人用秒想事情 ——
#'   界面上那个小字和提示词里那句都得走这里，**同一个数只有一种说法**。
#'
#' ⚠️ 不足 1 小时说"分钟"、整点说"N 小时"、半点说"N.5 小时"：
#'    这是滑块步长（30 分钟）本身决定的，三种形态正好覆盖它取得到的全部值。
#'    别把它写成通用的"X 小时 Y 分钟" —— 滑块只会落在整点和半点上，
#'    那种写法会输出"2 小时 0 分钟"。
#'
#' ★ V16.1 item 5：多了一档「不设上限」，而且它现在是**默认值**。
#' ⚠️ 这一句不能省。少了它，Inf 会一路走到下面 `h <- s / 3600`：
#'    `abs(Inf - round(Inf))` = NaN，`if (NaN)` 抛
#'    "missing value where TRUE/FALSE needed" —— 而这个函数被
#'    output$wall_label 和提示词两处读着，页面会直接崩在渲染上。
dsapp_wall_label <- function(secs) {
  s <- dsapp_wall_value(secs)
  if (isTRUE(dsapp_wall_is_unlimited(s))) return("不设上限")
  if (s < 3600) return(sprintf("%d 分钟", as.integer(round(s / 60))))
  h <- s / 3600
  if (abs(h - round(h)) < 1e-9) sprintf("%d 小时", as.integer(round(h)))
  else sprintf("%.1f 小时", h)
}

#' 自动执行到点停下时，写进状态条的那句话
#'
#' ★ V13.17 item 31。改这条文案的理由：这个数以前是写死的，说"已达总时长
#' 上限"就够了；现在是**用户自己选的**，不说清是多少的话，看到这句话的人
#' 第一反应是"什么上限？我设的是 8 小时啊"—— 而他可能确实设的 8 小时，
#' 只是从昨晚跑到了现在。
dsapp_agent_wall_note <- function(secs) {
  # ★ V16.1 item 5：不设上限时这句话**到不了**（下面那句比较是
  #   `已跑秒数 > Inf`，恒 FALSE，见 agent.R 的两处），但也不能就这么放着：
  #   万一哪天真被调到，"已达自动结束时间（不设上限），循环停止"是一句
  #   自相矛盾的话，比不说还糟。
  if (isTRUE(dsapp_wall_is_unlimited(secs))) {
    return("循环停止（这次没有设自动结束时间）")
  }
  sprintf("已达自动结束时间（%s），循环停止", dsapp_wall_label(secs))
}

#' 「出错自动修」的次数上限是不是"不设上限"
#'
#' ★★ V16.2 item 1。用户原话：「出错自动修也要默认没上限」。
#'
#' ⚠️⚠️ **NULL 算作不设上限**，和隔壁 dsapp_maxtok_is_unlimited() **刻意相反**
#'    （那里 NULL 是"还没取到"，所以不算）。理由：这一项的**默认值就是不设
#'    上限**（见 config.R 的 DSAPP_AGENT_AUTOFIX_UNLIM），所以"没给值"和
#'    "给的就是默认值"必须是同一个结果。反过来写的话，任何一条构造 agent
#'    对象时漏传 fix_max 的路径都会**静默退回 3 次**——而那正是用户要去的
#'    那个东西，界面上还勾着「不设上限」，两边说的不是一回事。
#'    和 DSAPP_CTX_FOLLOW 那一档同一个道理（0 = 跟随模型 = 这里的默认档）。
#'
#' ⚠️ 先过 as.numeric：这个值会在 sqlite blob（jsonlite）里往返一趟，
#'    也可能被浏览器报成字符串。
dsapp_autofix_is_unlimited <- function(x) {
  if (is.null(x) || length(x) == 0L) return(TRUE)
  n <- suppressWarnings(as.numeric(x[1]))
  if (is.na(n)) return(TRUE)          # NA = 没给 = 默认 = 不设上限
  !is.finite(n) || n <= 0
}

#' 把「出错自动修」上限归一成"能直接比较"的数
#'
#' ★ V16.2 item 1。和 dsapp_wall_value() / dsapp_iter_value() 同一个套路：
#'   调用方（滑块、输入框、库里的旧行）给什么形状的都有，归一只有这一个入口。
#'
#' ⚠️ 空向量必须在这里被吸收掉，理由和 wall_limit 那条一模一样：
#'    `as.numeric(integer(0))` 是 numeric(0)，存进 agent 对象之后
#'    `length(a$fix_times) >= a$fix_max` 求值成 logical(0)，而
#'    `if (logical(0))` 在**循环内部**抛错 —— 堆栈里一个字都看不到
#'    "上限没设上"。
dsapp_fix_max_value <- function(x) {
  if (isTRUE(dsapp_autofix_is_unlimited(x))) return(DSAPP_AGENT_AUTOFIX_UNLIM)
  n <- suppressWarnings(as.numeric(x[1]))
  if (!is.finite(n) || n < 1) return(DSAPP_AGENT_AUTOFIX_UNLIM)
  as.integer(floor(n))
}

#' 「出错自动修」上限说成人话：「不设上限」「3 次」
#'
#' ★ V16.2 item 1。界面上那个小字和状态条那句话都得走这里，
#'   **同一个数只有一种说法**（和 dsapp_wall_label 同一个规矩）。
dsapp_autofix_label <- function(x) {
  if (isTRUE(dsapp_autofix_is_unlimited(x))) return("不设上限")
  sprintf("%d 次", as.integer(suppressWarnings(as.numeric(x[1]))))
}

#' HTML 转义
#'
#' 聊天内容和代码都要原样显示给用户看，不能当 HTML 解析 ——
#' 模型生成的代码里出现 <script> 是完全可能的。
dsapp_escape <- function(x) {
  if (is.null(x)) return("")
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x
}

#' 把代码里字面的 `\uXXXX` 转义还原成真正的字符
#'
#' -----------------------------------------------------------------------------
#' ⚠️⚠️ 这个函数是为 2026-09-15 那个断点加的，别删
#' -----------------------------------------------------------------------------
#' 现场：task#11 跑到 92% 挂了，报
#'     Error: unexpected symbol in: "pkg_tab <- data.frame(\n  包"
#'
#' 模型写的中文有两种形态混在一段代码里：一部分是**真汉字**，一部分是
#' 字面的 `\uXXXX` 六字符转义。在字符串字面量里两种都对（R 认 `"包"`），
#' 所以此前一直没出事：
#'     x[is.na(x)] <- "—"        # 合法，等于 —
#'     pick <- function(x, default = "—") { ... }
#'
#' 但模型偶尔会把它用在**需要裸符号的位置** —— 上面那句的列名。R 无法把
#' `包` 解析成一个符号，于是整段脚本连**解析**都过不去，一行都没跑。
#' 实测（2026-09-15）：
#'     data.frame(包 = 1)   →  Error: unexpected symbol
#'     data.frame(包   = 1)     →  正常，列名就是 包
#'
#' 所以把字面转义还原成真字符：在字符串里是**等价改写**（值一模一样），
#' 在符号位置是**修复**。两头都对。
#'
#' ⚠️ 只还原反斜杠**没有被转义**的那些。`"\\u5305"` 的意图是"我要那六个
#'    字符本身"（正则、JSON 转义表、写编码转换脚本都会这么写），动了就错了。
#'    判据是「这个反斜杠前面没有另一个反斜杠」—— 用一次负向后顾做不到，
#'    所以走 gsub 的回调，按匹配位置数前面连续反斜杠的个数。
#'
#' ⚠️ 这不改变"模型不该这么写"这个事实，只是不让它把整段脚本打死。
#'    真正该做的（让模型别写转义）在 prompts.R 里另说。
dsapp_decode_uescapes <- function(x) {
  if (is.null(x) || !length(x)) return(x)
  if (!any(grepl("\\u", x, fixed = TRUE))) return(x)
  vapply(x, function(s) {
    if (is.na(s) || !nzchar(s)) return(s)
    m <- gregexpr("\\\\u[0-9a-fA-F]{4}", s)[[1]]
    if (length(m) == 1L && m[1] == -1L) return(s)
    chars <- strsplit(s, "", fixed = TRUE)[[1]]
    # 从后往前改，免得前面的替换挪动了后面的下标
    for (i in rev(seq_along(m))) {
      at <- m[i]
      # 数这个反斜杠前面连着几个反斜杠。奇数个 = 它自己被转义了，跳过。
      k <- at - 1L
      nb <- 0L
      while (k >= 1L && chars[k] == "\\") { nb <- nb + 1L; k <- k - 1L }
      if (nb %% 2L == 1L) next
      cp <- strtoi(substr(s, at + 2L, at + 5L), base = 16L)
      if (is.na(cp)) next
      repl <- tryCatch(intToUtf8(cp), error = function(e) NULL)
      if (is.null(repl) || !nzchar(repl)) next
      chars <- c(chars[seq_len(at - 1L)], strsplit(repl, "", fixed = TRUE)[[1]],
                 chars[-seq_len(at + 5L)])
    }
    paste(chars, collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

#' 执行目标的可读标签
#'
#' 任务列表里要显示"这条结果是在哪儿、用什么环境跑出来的"。同一个脚本在
#' 系统环境和 conda 环境里结果经常不一样，不标出来的话事后根本对不上账。
#' ★ V14 item 6：措辞从「当前服务器 / 远程服务器 / 本地电脑」改成
#' 「**本站部署机** / **你自己的服务器** / **你自己的电脑**」。
#'
#'   用户问：「用户所在的算力节点，是用户自有服务器，还是我的部署服务器」。
#'   答案是明确的（默认 kind = "server"），但**界面上一直没说清归属** ——
#'   "当前服务器"里的"当前"是个相对说法，用户完全可能理解成"我现在选中的
#'   那台（我自己的）机器"。这个歧义有实际代价：他可能把几个 G 的原始数据
#'   传到自己根本连不上的机器上，或者反过来，以为数据在自己手里、其实在
#'   平台的盘上。
#'
#'   所以每一支都把**物主**写出来。这不是文案偏好 —— 改回"当前服务器"就等于
#'   把这个问题重新藏起来。（外面 selftest 钉的就是这几个字符串，是有意的。）
dsapp_target_label <- function(target) {
  if (is.null(target)) return("本站部署机 · 环境自动准备")
  kind <- target$kind %||% "server"

  if (identical(kind, "remote")) {
    r <- target$remote %||% list()
    return(sprintf("你自己的服务器 · %s@%s:%s",
                   r$user %||% "?", r$host %||% "?", r$port %||% 22))
  }
  if (identical(kind, "local")) {
    return("你自己的电脑（导出运行包）")
  }
  # ⚠️ 这个按 env 分叉的文案在 V4 被删过一次、V5 加回来。两次的理由都要记住：
  #
  #   删（V4）：那会儿用户**不能**选环境，env 恒为 "system"，再分叉只会
  #   冒出一个用户既看不懂、也无从改变的环境名。那时候删是对的。
  #
  #   加回（V5）：环境页上现在真的能选、能删了（见 mod_envs.R），env 不再
  #   恒为 "system"。此时**必须**标出来 —— 同一个脚本在系统环境和 conda
  #   环境里结果经常不一样，任务列表事后要能对上账。不标的话，用户看到
  #   两次同样的代码跑出不同结果，会以为平台不可靠。
  #
  #   所以这一条不是"文案偏好"，它跟着"用户能不能选环境"这个事实走。
  #   哪天选择入口再被撤掉，这里要跟着删 —— 否则就会显示一个用户没选过、
  #   也不知道去哪改的环境名。
  env <- target$env %||% "system"
  if (is.null(env) || !nzchar(env) || identical(env, "system")) {
    return("本站部署机 · 系统环境")
  }
  sprintf("本站部署机 · conda 环境 %s", env)
}

#' 生成短 ID
dsapp_id <- function(prefix = "s") {
  paste0(prefix, "-", format(Sys.time(), "%Y%m%d%H%M%S"),
         "-", sprintf("%04d", sample.int(9999, 1)))
}

#' 认证链路的诊断日志
#'
#' ⚠️ 为什么单独有一份、而不是并进 audit_log：
#'
#'    2026-09-13 线上报「登录成功，却弹回登录页」。audit_log 里那条 login
#'    明明是 ok=1 —— 因为**认证确实成功了**，丢的是后面那一跳：登录成功要
#'    走 session$reload() 清掉上一个账号的模块状态，而 reload 之后新会话的
#'    身份**只剩 cookie 一条路**。cookie 有没有真的写进浏览器、reload 之后
#'    有没有送回来，**服务端完全看不见**。当时只能靠反复猜，查了很久。
#'
#'    这份日志把那一跳的两端都记下来：页面每次加载时看到了什么、走了哪条
#'    路、cookie 的回执是成功还是被浏览器拒了。出问题时直接读它。
#'
#' 记的是**有没有、对不对**，不是令牌本身 —— 日志文件不该变成新的凭据泄露点。
#' 落在 data/logs/auth.log（755/644，出问题时不用 sudo 就能读）。
#' 给 www/ 下的静态资源拼一个随文件变动的版本号
#'
#' ⚠️ 这不是"优化"，是**修 bug**。Shiny Server 发静态文件时只带 Last-Modified，
#'    **没有 Cache-Control、没有 ETag**，浏览器于是走启发式缓存 —— 什么时候
#'    重新下载由它自己算。
#'
#'    2026-09-13 线上就是中的这个招：用户浏览器里一直跑着旧的 app.js，而登录
#'    那一跳的逻辑（写 cookie、交回执、把 cookie 交给服务端）**全在 app.js 里**。
#'    表现是：服务端认证成功、日志写着登录成功，人却永远回到登录页；服务端这边
#'    怎么改都没用。定位到它靠的是 auth.log 里少了一行 —— app.js 每次连上都会
#'    写"页面加载："，而用户那两次登录前后**一次都没有**，我用干净浏览器打开
#'    线上立刻就有了。
#'
#'    用 mtime 当版本号：每次部署 rsync 都带着新的 mtime，URL 自然就变了，
#'    浏览器只能重新下载。以后改 JS/CSS 一定要走这个函数，别再写裸文件名。
dsapp_asset <- function(f) {
  p <- file.path(dsapp_config()$app_dir, "www", f)
  v <- tryCatch(as.integer(file.info(p)$mtime), error = function(e) NULL)
  if (is.null(v) || is.na(v)) v <- 0L
  sprintf("%s?v=%d", f, v)
}

# =============================================================================
# 平台 logo（V10 item 3）
# =============================================================================
# 图放在 `<data_root>/logo/`，**不在 www/ 里**。原因：
#   · www/ 是随代码走的那份（归档、git、别人 clone 走的都是它），而 logo
#     是"这台部署的 VI"，换套皮不该是一次代码改动；
#   · 更要紧的是 www/ 下的东西**任何人都能直接下载**。现在里面只有 css/js，
#     放进去就等于把 logo 变成公开静态资源 —— 这次是 logo 无所谓，
#     但"往 www/ 里丢东西"这个习惯迟早会有人用来放别的东西。
# 所以走 addResourcePath 单独挂一路（见 app.R），和 files/ exports/ 一个路子。
#
# ★ V13.9 item 12：`www/help-wx.png` 是这条约定的一个**例外**，写在这里
#   免得下一个人看到它以为是谁忘了规矩。逐条对上面那两条理由：
#     · 它不是"这台部署的 VI"，而是随代码走的**内容** —— 帮助页上那张
#       Biomamba 海报（客服微信码 + 公众号码 + 课程/服务器信息），每台
#       部署上都该长得一样，也没有"换套皮"这回事；
#     · 它本来就是**给人看的宣传图**，被谁直接下载走完全无所谓。上面那句
#       "迟早有人用来放别的东西"防的是私密文件，而这张图印在哪都不算泄密。
#   反过来，放进 data_root/logo/ 才是错的：那个目录是"运维换 VI"的地方，
#   而这里需要的是"跟着代码一起发到每一台机器上"，data/ 恰恰不进归档、
#   新部署上也没有 —— 那样帮助页在别人的机器上会开天窗。
#   ⚠️ 例外仅此一张。再有图要放，先照上面两条理由重新过一遍，别顺着这条抄。
#
# 三条设计：
#   · **挑最新的那张**。换 logo = 往目录里丢一张新图，不改代码、不改配置、
#     不用删旧图（留着旧的还能回滚）。
#   · 界面上**只给一个盒子**，图按原比例缩放着放进去（CSS 见 app.css 的
#     .dsapp-logo-img）。不写死宽高比、不裁切 —— 给一张长条形的字标
#     也能看，不会变成一条压扁的丝带。
#   · 找不到图就**回落到原来的 FontAwesome 图标**，不留白、不报错。
#     全新部署、归档出来的副本、别人的机器上都没有 data/logo/，
#     这条回落是它们能正常跑的前提。
DSAPP_LOGO_EXT <- "png|jpe?g|svg|webp|gif|ico"

#' `<data_root>/logo/` 里最新的那张图（没有就 NULL）
dsapp_logo_file <- function(cfg = dsapp_config()) {
  d <- cfg$logo_dir
  if (is.null(d) || !nzchar(d) || !dir.exists(d)) return(NULL)
  fs <- list.files(d, pattern = sprintf("\\.(%s)$", DSAPP_LOGO_EXT),
                   ignore.case = TRUE, full.names = TRUE)
  if (!length(fs)) return(NULL)
  fi <- tryCatch(file.info(fs), error = function(e) NULL)
  if (is.null(fi) || !nrow(fi)) return(fs[1])
  # 同一秒内放进两张时按文件名兜底定序 —— 否则 list.files 的顺序
  # 由文件系统决定，同一份部署在两台机器上可能挑出不同的图。
  fs[order(fi$mtime, basename(fs), decreasing = TRUE)][1]
}

#' logo 的 URL（没有图就 NULL）
#'
#' ⚠️ 必须 URL 编码。文件名是中文的（`头像logo2026.09.jpg`），裸着塞进
#'    href 里浏览器会各自按不同规则转义，而 Shiny 那边的静态路由是**按
#'    解码后的路径找文件**的 —— 编码对不上就是 404，表现是登录页上一个
#'    破图标，且没有任何报错。
#'
#' ⚠️ `?v=<mtime>` 和 dsapp_asset 是同一个理由：换图时文件名往往没变
#'    （运维就是把新图覆盖上去），不带这个参数浏览器会一直用缓存里那张。
dsapp_logo_url <- function(cfg = dsapp_config()) {
  f <- dsapp_logo_file(cfg)
  if (is.null(f)) return(NULL)
  v <- tryCatch(as.integer(file.info(f)$mtime), error = function(e) NULL)
  if (is.null(v) || is.na(v)) v <- 0L
  sprintf("dsapplogo/%s?v=%d", utils::URLencode(basename(f), reserved = TRUE), v)
}

#' 品牌 logo 的那个方盒子：有图放图，没图放原来的图标
#'
#' @param class 盒子上的类名（.dsapp-auth-logo / .dsapp-rail-logo），
#'   有图时会**追加** `is-img` —— 那两处原来都是"深色底 + 白色图标"的
#'   徽章样式，底下垫一张真图会变成一块突兀的色块，所以 is-img 要把
#'   底色去掉。类名拼接在这里做，调用方就不用各判一次。
#' @param fallback 没图时用的 FontAwesome 图标名
dsapp_logo_box <- function(class, fallback = "dna", cfg = dsapp_config()) {
  u <- dsapp_logo_url(cfg)
  if (is.null(u)) {
    return(div(class = class, icon(fallback)))
  }
  div(class = paste(class, "is-img"),
    tags$img(src = u, class = "dsapp-logo-img", alt = "Biomamba 生信基地")
  )
}

#' 浏览器标签页图标
#'
#' 没配 logo 时返回 NULL —— **不要**回落成 FontAwesome。浏览器只认图片，
#' 塞一个 <i> 进去在标签页上是空白，反而比默认图标更糟。
dsapp_favicon <- function(cfg = dsapp_config()) {
  u <- dsapp_logo_url(cfg)
  if (is.null(u)) return(NULL)
  tags$link(rel = "icon", href = u)
}

#' 把一个 R 字符串转成 JS 字面量，用来拼进内联 onclick
#'
#' 只有一处用途：`onclick = sprintf("Shiny.setInputValue(%s, ...)", dsapp_js_str(id))`。
#' 不要直接 `sprintf("'%s'", id)` —— 模块的 id 里带命名空间（`chat-foo`），
#' 正常没引号，但**没人保证**；真出了一个引号就会拼出一段坏 JS，而坏掉的
#' 内联 onclick **不报错**，表现是"这个按钮点了没反应"。
#' jsonlite 会把它转义成合法字面量。
#'
#' ⚠️ 全仓库只有这一份实现。mod_chat.R 里原来有一个同名的局部函数
#'    （那 8 处调用点都正常），V9 item 3 在 mod_files.R 里也用了一次，
#'    才发现它只活在 mod_chat 的模块作用域里 —— mod_files 一调就是
#'    "could not find function js_str"，**整个页面白屏**。
#'    两个模块都要用的东西，就不能定义在某一个模块里面。
dsapp_js_str <- function(x) {
  jsonlite::toJSON(as.character(x), auto_unbox = TRUE)
}

#' 拼一段"把某个值发给某个 Shiny input"的内联 JS（onclick / onkeydown 用）
#'
#' `priority:'event'` 是**关键**，不是可选项：不加的话 Shiny 会按"值没变就
#' 不派发"处理，于是**同一个文件连点两次只有第一次有效** —— 用户看到的是
#' "预览关掉之后再也点不开了，刷新一下又好了"。加了它每次点击都派发。
#'
#' 值一律走 dsapp_js_str 转义，理由见上面那个函数。
dsapp_fire <- function(input_id, value) {
  sprintf("Shiny.setInputValue(%s, %s, {priority:'event'}); return false;",
          dsapp_js_str(input_id), dsapp_js_str(value))
}

#' 页脚：版本号 + 客服微信（V6 item 7）
#'
#' 单独拎出来是因为它要在**每个**入口页上都出现 —— 主界面、注册/登录页、
#' 强制改密页是三个各自独立的 UI（见 app.R 里 server 的 app_root 分流），
#' 只挂在 dsapp_main_ui 上的话，没进门的人恰恰看不到客服微信，
#' 而需要问"怎么进不去"的正是他们。
#'
#' ⚠️⚠️ 这个函数**必须待在 R/ 下，不能搬回 app.R**，哪怕它看起来更适合
#'    和 dsapp_main_ui 放在一起。
#'
#'    原因见 app.R 里那段长注释：app.R 的顶层不在 globalenv 里（Shiny 给它
#'    套了一层），而 R/*.R 是明确 source 进 globalenv 的。**app.R 看得见
#'    R/，R/ 看不见 app.R。** 而本函数的调用方之一是 R/mod_welcome.R 里的
#'    dsapp_auth_shell —— 一个在 globalenv 里的函数。
#'
#'    2026-09-14 V6 把它放在 app.R，后果是：主界面好好的，**注册/登录页
#'    整个白屏**，页面上只有一句 "could not find function dsapp_footer_ui"。
#'    而登录页恰恰是"进不来的人"唯一看得见的那一页。
dsapp_footer_ui <- function() {
  tags$div(class = "dsapp-footer",
    # 版本号（item 7）：出问题时第一句话永远是"你用的是哪一版"，把它放在
    # 客服微信**旁边**，用户截图时两个一起进画面。格式 V_6.0.0 —— 下划线是
    # 用户指定的写法，不是笔误。
    tags$span(class = "dsapp-footer-ver",
      sprintf("V_%s", DSAPP_VERSION)),
    tags$span(class = "dsapp-footer-sep", "·"),
    # ★ V16.6 item 6：「获取最新版」——用户原话「版本号后面加一个获取最新版，
    #   就用这个链接作为超链接」。位置就是他说的位置：紧跟版本号。
    #
    #   为什么值得放在页脚：出问题时第一句话永远是「你用的是哪一版」，
    #   下一句就是「去哪拿新的」。两件事挨着，截图时一起进画面。
    #
    #   ⚠️ 地址来自 R/config.R 的 DSAPP_RELEASE_URL，**不在这里再写一遍** ——
    #      自检断言"页脚那个链接就是它"，两处各写一遍的话改了这处那处还绿着，
    #      而错了的表现是用户点进一个 404。
    #
    #   ⚠️ 和旁边两处（客服、算力环境）同一条规矩：长短两段都渲染、CSS 二选一。
    #      页脚是 position:fixed + 固定高度（--dsapp-footer-h），**折成两行就会
    #      盖住页面底部**，所以窄屏是"换一段更短的文案"而不是"挤一挤"。
    #      nowrap 也必须给（见 app.css），否则「获取最新版」能从中间断开。
    #
    #   ⚠️ 桌面版（Windows/Mac 那个包）跑的是同一份界面 —— 这个链接跟着进包，
    #      于是**老包里的链接永远指向最新版**，这正是要的效果。
    tags$a(class = "dsapp-footer-getver",
      href = DSAPP_RELEASE_URL,
      target = "_blank", rel = "noopener noreferrer",
      title = "去 GitHub 下载最新版（Windows / macOS / 源码）",
      icon("download"),
      tags$span(class = "dsapp-footer-getver-long", " 获取最新版"),
      tags$span(class = "dsapp-footer-getver-short", " 最新版"),
      icon("arrow-up-right-from-square", class = "dsapp-footer-getver-ext")),
    tags$span(class = "dsapp-footer-sep", "·"),
    # ★ V13.11 item 12：文案改成"问题在前、联系方式在后"。
    #
    #   原来是「欢迎联系客服微信 Biomamba_zhushou（使用中遇到问题，加微信说一声）」——
    #   把"为什么要联系"塞在括号里放在最后，扫一眼的人只看到一串微信号，
    #   不知道什么情况下该加。改成先给场景再给动作。
    #
    #   ⚠️ 原来靠 .dsapp-footer-tip 在窄屏上藏掉一句来保一行，那个 span 现在
    #      去掉了，所以**换成和下面「算力环境」同一个套路**：长短两段都渲染
    #      出来，CSS 按宽度二选一（app.css 里 .dsapp-footer-ask-long/-short）。
    #      这样"有事找客服"这件事在任何宽度下都在，只是说得详细还是简略 ——
    #      而不是窄屏上干脆消失。
    tags$span(class = "dsapp-footer-ask",
      icon("headset"),
      tags$span(class = "dsapp-footer-ask-long", " 使用中遇到问题？欢迎联系客服微信 "),
      tags$span(class = "dsapp-footer-ask-short", " 客服微信 ")),
    tags$span(class = "dsapp-footer-wx", "Biomamba_zhushou"),
    tags$span(class = "dsapp-footer-sep dsapp-footer-sep-gpu", "·"),
    # ★ V13.4 item 8：算力环境的入口。
    #
    # ⚠️ 这里**必须**是两段文案、靠 CSS 二选一显示，不能只有长的那句。
    #    页脚是 position:fixed + 高度变量（--dsapp-footer-h，宽屏 2.6rem、窄屏
    #    4.4rem —— 定义在 www/skins.css），而
    #    #app_root 的 padding-bottom 补的就是这个数 —— 内容一旦折成两行，
    #    页脚会**盖住页面底部**，而且只在某些窗口宽度下出现，最难查的那类。
    #    窄屏上长句换成短标签，宽度就压到和现在这句差不多（见 app.css 里
    #    那条 @media）。
    #
    #    rel="noopener noreferrer" 不是摆设：target="_blank" 的页面能通过
    #    window.opener 改这一页的地址（反向 tabnabbing），现代浏览器默认已经
    #    挡了，但显式写上不吃亏。
    tags$a(class = "dsapp-footer-gpu",
      href = "https://biomamba.xiyoucloud.net/",
      target = "_blank", rel = "noopener noreferrer",
      # 窄屏只显示短标签时，整句仍留在 title 里（悬停和读屏都拿得到）
      title = "算力不够？看看足够满足你硕博生涯使用的算力环境",
      icon("server"),
      tags$span(class = "dsapp-footer-gpu-long",
                " 算力不够？看看足够满足你硕博生涯使用的算力环境"),
      tags$span(class = "dsapp-footer-gpu-short", " 算力环境"),
      icon("arrow-up-right-from-square", class = "dsapp-footer-gpu-ext")
    )
  )
}

#' 被顶下线之后、登录页上面那条说明（V11 item 4b）
#'
#' 为什么要有它：单端登录的表现是"我在 A 电脑上开着，去 B 电脑登了一下，
#' 回来发现 A 退出了"。不解释的话，用户的第一反应是"是不是坏了 / 是不是
#' 被盗了"，而这两个猜测都会让他来问、或者去改密码。
#'
#' ⚠️ 放在**登录页上面**而不是弹一个通知：通知会被点掉、会超时消失，而这条
#'    信息正是用户站在登录页上、准备再登一次的时候需要的 —— 他得先知道
#'    "再登一次会把另一台顶掉"这件事是**预期行为**，不是异常。
#'
#' ⚠️ 不写成"你的账号在别处登录"，那读起来像被盗号。主语是用户自己：
#'    「这个账号在别的地方登录了」+ 说明这是有意的限制。
dsapp_kicked_notice_ui <- function() {
  tags$div(class = "dsapp-kick-note",
    icon("right-from-bracket"),
    tags$div(class = "dsapp-kick-note-body",
      tags$b("这个账号刚刚在别的地方登录了，本页已自动退出。"),
      tags$div(class = "dsapp-kick-note-sub",
        "同一个账号同一时间只允许一个端在用（两个端同时操作同一个工作区会",
        "互相打架）。如果刚才是你自己在另一台设备上登录，这里重新登一次",
        "就能把那边顶下线。")
    )
  )
}

dsapp_auth_log <- function(...) {
  # ⚠️ 必须**先在 try 外面**把消息算出来。`...` 是惰性求值：直接把它塞进
  #    try(..., silent = TRUE) 里面用，参数求值时的报错会被一起吞掉 ——
  #    调用方以为记了一笔，日志里其实什么都没有，而且**一声不响**。
  #
  #    这个坑 2026-09-13 真踩到了，而且踩在最要命的地方：on_login 里写的是
  #        dsapp_auth_log(sprintf("on_login uid=%d ...", state$user_id, ...))
  #    而 state 是 reactiveValues，在响应式上下文之外读会抛
  #    "Can't access reactive value ... outside of reactive consumer"
  #    （自动进入这条路就是在上下文之外调的）。于是那条"登录成功"的记录
  #    **一条都没写进去过** —— 我拿来远程排障的东西，自己在骗自己。
  #    求值失败要留痕，不能装作没发生。
  msg <- tryCatch(paste0(...),
                  error = function(e) sprintf("（这条日志的参数求值就失败了：%s）",
                                              conditionMessage(e)))
  p <- tryCatch(file.path(dsapp_config()$logs_dir, "auth.log"),
                error = function(e) NULL)
  if (is.null(p)) return(invisible(NULL))
  try({
    if (!dir.exists(dirname(p))) dir.create(dirname(p), recursive = TRUE)
    cat(sprintf("%s  %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), msg),
        file = p, append = TRUE)
  }, silent = TRUE)
  invisible(NULL)
}

# ---- DT 表格的「表头全选」---------------------------------------------------
#
# 挂在 DT::datatable(options = list(initComplete = dsapp_dt_select_all()))。
#
# ★ 为什么需要这个东西：Select 扩展 1.7.0 **没有**表头全选功能。它只给
#   表头 <th> 加一个 `select-checkbox` 类名就完事，既不往里面放控件，也不绑
#   点击；它自己的 CSS 也只写了 tbody 那条选择器。所以表头那格永远是空的。
#   真正干活的 JS 在 www/app.js 的 `window.dsappSelectAll`（连同"为什么
#   不能靠断言 th.select-checkbox 存在来验它"的说明）。
#
# 这里只负责把那个函数挂到表初始化完成的时机上。用 `settings.oInstance.api()`
# 取 API 而不是 `this`：DataTables 1.13 的 initComplete 里 `this` 确实是 API，
# 但这是文档里没承诺的实现细节，oInstance 是稳的。
dsapp_dt_select_all <- function() {
  DT::JS(paste0(
    "function (settings, json) {",
    "  var api = (settings && settings.oInstance && settings.oInstance.api)",
    "    ? settings.oInstance.api() : this;",
    "  if (window.dsappSelectAll) window.dsappSelectAll(api);",
    "}"))
}

# =============================================================================
# 任务列表的两级展示（V13.11 item 11）
# =============================================================================
#
# 用户原话：
#   「历史任务也按任务标题名称和内部执行的具体任务进行分级展示」
#
# 说的是执行历史那一张平铺的表。一条对话里 agent 往往会跑十几个任务，每个
# 都占一行 —— 十条来自**同一个提问**的任务摊在表里，长得几乎一样（标题里
# 那半截会话名是重复的），想找"上周那个跑失败的是哪一步"只能一行行读。
#
# 任务标题本身就是 `<这一步在干什么>_<所属对话>`（见 dsapp_task_title），
# 所以两级天然存在，只是没画出来：
#   父级 = 所属对话（= 用户说的「任务标题名称」）
#   子级 = 每一步自己（= 用户说的「内部执行的具体任务」）

#' 把任务列表重排成「按对话聚在一起」
#'
#' 只**重排**，不加行也不删行 —— 这一页所有的选择/重跑/删除都按**行号**回查
#' tasks()（见 mod_tasks.R 的 selected_ids），插一行"分组标题"就会让行号整体
#' 错位，表现是"点第 3 行删掉的是第 4 条"。分组只体现在列的内容上。
#'
#' @param df db_tasks_list() 的结果（必须带 session_id 和 id）
#' @return 行序被重排过的 df。空表原样返回。
dsapp_group_tasks <- function(df) {
  if (is.null(df) || !nrow(df)) return(df)
  # 没这一列（老调用点、或者哪天 db_tasks_list 改了列）就当没分组 ——
  # ⚠️ 不能让它往下走：下面 ave() 要求分组向量和 id 等长，而
  #    as.character(NULL) 是 character(0)，报的是一句
  #    "'x' and 'g' must have the same length"，从这句话完全看不出
  #    是"列没了"。
  if (is.null(df$session_id)) return(df)
  sid <- as.character(df$session_id)
  sid[is.na(sid)] <- ""
  if (is.null(df$id) || !length(df$id)) return(df)

  # 组间：按这一组里**最新的那条**倒序 —— 刚跑完的对话排最上面，和原来
  # "ORDER BY id DESC"给人的感觉一致。
  #
  # ⚠️ 组内反过来用**升序**（id 从小到大 = 执行顺序）。这不是随手定的：
  #    同一个提问下那十几步是有先后的（先装环境、再取数、再建模），
  #    倒着排读起来像倒放。父级那行自己也是一条任务，它排在组的第一行。
  #
  # ⚠️ 用 ave(..., FUN = max) 而不是 tapply()：tapply 返回的是按因子水平排好
  #    序的一小张表，还得 match 回原位置，中间任何一步对不上都表现为"顺序
  #    莫名其妙"，而且不报错。ave 保证长度和输入一致、位置一一对应。
  newest <- ave(df$id, sid, FUN = max)
  # ⚠️ 别忘了外面这层下标：order() 返回的是**行号**，直接把 order(...) 当
  #    返回值交出去，调用方拿到的是一个整数向量，然后 `df$title` 会报
  #    "$ operator is invalid for atomic vectors" —— 而 nrow() 会返回 NULL、
  #    在 if 里又是一个别的错。第一版就是这么写的，自检当场抓住。
  #
  # ⚠️ drop = FALSE 不能省：筛到只剩一条任务时，不带它的一维下标会把数据框
  #    降成一个向量，后面每一处按列取都崩。
  df[order(-newest, sid, df$id), , drop = FALSE]
}

#' 分组显示时，把标题尾巴上那半截会话名去掉
#'
#' dsapp_task_title() 拼的是 `<功能>_<会话名前 24 字>`。分组之后会话名已经
#' 单独占一列了，标题里再带一遍就是每行重复一次同样的半句话，把真正有信息量
#' 的那半截挤没了。
#'
#' ⚠️ **只在确实是它的后缀时才去**。拼的时候功能那半截是按 48 字总额度截过的
#'    （max - half - 1 = 23 字），所以功能名太长时标题长这样：
#'    `很长的功能名前二十三个字_会话名前24字` —— 后缀还在，能对上；
#'    但功能名和会话名**一模一样**时 dsapp_task_title 整条就不拼后缀了，
#'    那种标题强行按 `_` 切会把功能名切掉一块。对不上就原样留着，
#'    宁可在分组视图里重复一遍，也不能显示一个缺了字的标题。
#'
#' @param titles        任务标题（向量）
#' @param session_title 每个任务所属对话的名字（等长向量，长度可以不等）
#' @return 等长字符向量，绝不返回空串或 NA
dsapp_task_short_title <- function(titles, session_title = NULL) {
  t_ <- as.character(titles)
  if (!length(t_)) return(t_)
  # ⚠️ NA 必须在任何 nchar/endsWith 之前换掉：nchar(NA) 是 2（它把 "NA" 当
  #    字符串量），endsWith(NA, x) 是 NA，而 if() 拿到 NA 直接抛
  #    "missing value where TRUE/FALSE needed"。
  t_[is.na(t_)] <- ""
  out <- t_

  s_ <- as.character(session_title %||% rep("", length(t_)))
  if (length(s_) != length(t_)) {
    s_ <- rep(s_, length.out = length(t_))
  }
  s_[is.na(s_)] <- ""

  for (i in seq_along(out)) {
    if (!nzchar(s_[i]) || !nzchar(out[i])) next
    # 拼进标题的是会话名的**前 24 字**（utils.R 的 dsapp_task_title 里那两处
    # substr(..., 1, half)），所以也拿前 24 字去比。
    sfx <- paste0("_", substr(s_[i], 1, 24L))
    if (endsWith(out[i], sfx)) {
      cut <- substr(out[i], 1L, nchar(out[i]) - nchar(sfx))
      # 切完只剩空串（功能那半截本来就是空的）→ 退回完整标题，不留空单元格
      if (nzchar(cut)) out[i] <- cut
    }
  }
  out
}

# ---- 思考时的"活人感"提示词（Test_V15.4 item 3）-----------------------------
#
# 用户原话：「并在思考的时候加个转圈的图案，提示用户"模型正在思考"？或者加
# 一些有活人感的提示词，例如："院士别催了，我正在全力思考"、"冒了烟的思考中"；
# 你可以再想十个不重复的，随机使用」。
#
# ⚠️⚠️ 这个数组**只在服务端用一次**：骨架渲染时整个塞进 `data-quips` 属性，
#    **轮换在客户端做**（www/app.js 的 setInterval 改 textContent）。
#    千万别改成"服务端每 N 秒换一条" —— 那等于把这一版刚从 output$streaming
#    里掐掉的 200ms 重画又装回来，用户报的"闪屏"会原样复发，而且这次连转圈
#    动画一起闪（CSS 动画是元素一换就从头开始的）。判据见
#    tests/ui_v154/probe_v154.py 的 uuid 指纹那一条。
#
# 分隔符用 ASCII 单元分隔符（U+001F），不用逗号/竖线：提示词是中文文案，
# 以后有人加一条带标点的，用可见字符当分隔符就会当场裂开 —— 而裂开的症状是
# "提示词少了一截"，看不出是分隔符的问题。
# ⚠️ 写成 `\u001f` 这个**转义**，别在这里直接嵌那个控制字符：它会被编辑器、
#    复制粘贴、各种转码环节悄悄吃掉，而吃掉的症状是分隔符变成空串 ——
#    `strsplit` 拿空串当分隔符会**按字符切开**，于是一条提示词被切成十几个
#    "单字提示词"。不报错，只是轮换时一个字一个字地跳。
DSAPP_THINK_QUIP_SEP <- "\u001f"

DSAPP_THINK_QUIPS <- c(
  "院士别催了，我正在全力思考",
  "冒了烟的思考中",
  "脑子转得比风扇快，稍等",
  "正在把问题拆成小块",
  "让我先捋一捋",
  "这条路走不通，换一条再想",
  "结论还在路上，别急",
  "已经写在草稿纸上了",
  "正在和公式较劲",
  "让我把逻辑再核一遍",
  "快了，别眨眼",
  "正在给你的问题找个漂亮解法"
)
