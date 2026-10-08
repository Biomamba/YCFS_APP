# =============================================================================
# 文件管理
# =============================================================================
# ★ V13 item 6 起，文件管理区**按账号隔离**。
#
# 旧的文件头写的是「所有用户共用，刻意不按账号隔离 —— 生信数据要能互相
# 引用」。那个判断在 V5（刚有账号）时是成立的，到 V12 就不成立了：V12 给
# 任务加了产物**自动同步**，于是共用区里开始自动堆进每个人的分析产物
# （data/files/<对话标题-尾4位>/…）。用户 2026-09-16 报的就是这个：
# 「文件管理区不用所有人可见，每个账号显示自己的管理区就好」。
#
# 现在是**真隔离**，不是列表过滤：
#
#     data/files/
#       u1/   ← 账号 1 的管理区，界面上的"根目录"就是这里
#       u3/   ← 账号 3 的
#       _anon/ ← 没有账号时的占位（登录页之前、后台脚本），永远是空的
#
# 每个账号只能看到、也只能解析到自己那个 u<N>/ 底下的路径 —— 因为
# dsapp_file_path() 的 root 就是它，`../u3/x.csv` 早就在 dsapp_rel_segments()
# 那一关被拒了（它拒 `..`），而绝对路径同样过不去。
#
# ⚠️ 不要退回"一个共用目录 + 列表里按 file_owner 过滤"。那种做法看着也能
#    满足"显示自己的"，但文件仍然躺在同一个能被猜到的路径上，而预览是走
#    静态路由发的（/files/<相对路径>）—— 换个账号把 URL 里的名字一改就能
#    下载别人的东西。**显示层的隔离不是隔离**，而且它错得很安静：界面上
#    一切正常，只有知道 URL 的人看得出来。
#
# 隔离的是"看得见什么"；"能改什么"仍然是另一条线（改名、删除按上传者
# 判定，见 R/users.R 的 file_owner）—— 那条留着，因为它在同一账号内仍然
# 有意义（团队共享进来的东西你不该能删）。
#
# 这里所有对外暴露文件名的函数，第一步都过 dsapp_safe_name() 并校验最终
# 路径确实落在 files_dir 内 —— 文件名来自浏览器，是实打实的不可信输入。
#
# ⚠️ 共享区的角色在 V3 agent 改造后变窄了：它现在是**上传区**。
#    代码执行和产物落地都在对话工作区（utils.R 的 dsapp_ws_dir），产物要
#    进共享区得用户显式点「发布」（见 dsapp_publish_artifact）。
#    原因是自动执行会把每一轮的中间文件都倒进来，把「文件」页和模型看到
#    的文件清单一起淹掉 —— 模型分不清哪个是自己的中间产物、哪个是用户的
#    原始数据，就会拿中间文件当输入源。
# =============================================================================

# ---------------------------------------------------------------------------
# 按账号定位管理区（V13 item 6）
# ---------------------------------------------------------------------------

#' 某个账号的管理区目录（data/files/u<N>）
#'
#' @param user_id NULL / NA → `_anon` 占位目录（永远空，见 config.R 那段说明）
dsapp_files_root <- function(user_id = NULL, cfg = dsapp_config()) {
  base <- cfg$files_root %||% file.path(cfg$data_root, "files")
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  # ⚠️ 长度也判：user_id 可能是 character(0)（没登录），as.integer 给 NA
  #    没问题，但 `if (is.na(uid))` 遇到长度 0 会报 "argument is of length
  #    zero" —— 而那是在每次渲染文件页时都要走的路。
  if (length(uid) != 1L || is.na(uid)) return(file.path(base, "_anon"))
  file.path(base, sprintf("u%d", uid))
}

#' 把 cfg 绑到某个账号上（**所有**取文件路径的地方都该先过这一手）
#'
#' 返回的是同一个 list，只有 `files_dir` 换成了那个账号的管理区。这样
#' files.R / mod_files.R 里那几十处 `cfg$files_dir` 一个字都不用改 ——
#' 它们本来就说的是"当前账号的管理区根"。
dsapp_config_user <- function(user_id, cfg = dsapp_config()) {
  cfg$files_dir <- dsapp_files_root(user_id, cfg)
  # 顺手把账号记在 cfg 上。有些函数（dsapp_entry_move / dsapp_entry_delete）
  # 只收 cfg、不收 user_id，而它们要写 file_owner —— 那张表的键带账号前缀
  # （见 users.R 的 dsapp_owner_key）。让它们从 cfg 上读，比让每个调用方都
  # 多传一个参数可靠：**多一个参数就多一个能传错的地方**，而这里传错的
  # 后果是改到别人的归属行。
  #
  # ⚠️ 不要用 basename(cfg$files_dir) 去反解账号。目录名的格式（u3）
  #    是布局细节，哪天变成 data/files/3/ 或者加了一层，反解出来的东西
  #    会静默变成 NA，然后所有归属写入都落到 _anon —— 不报错。
  cfg$files_uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  cfg
}

#' cfg 上记着的账号（没有就是 NA）
dsapp_cfg_uid <- function(cfg = dsapp_config()) {
  u <- cfg$files_uid %||% NA_integer_
  if (length(u) != 1L) NA_integer_ else u
}

#' 按对话 id 绑 cfg：查出对话的主人，再走 dsapp_config_user
#'
#' 给那些手里只有一个 `sid`、拿不到 Shiny session 的地方用（executor 镜像
#' 共享区、prompts 拼文件清单、产物同步）。查不到主人时**落到 _anon**：
#' 那是个空目录，表现为"这个对话看不到任何上传文件"，而不是"能看到所有人
#' 的上传文件"。
dsapp_config_sid <- function(sid, cfg = dsapp_config()) {
  uid <- tryCatch({
    u <- DBI::dbGetQuery(dsapp_db(cfg), "SELECT user_id FROM sessions WHERE id = ?",
                         params = list(sid))$user_id
    if (length(u)) u[[1]] else NA_integer_
  }, error = function(e) NA_integer_)
  dsapp_config_user(uid, cfg)
}

#' 所有账号的管理区根目录（已存在的那些）
#'
#' 给"跨账号"的少数几个地方用：管理页的磁盘统计、归属补登记。**界面列文件
#' 不许用它** —— 那是隔离的反面。
dsapp_files_all_roots <- function(cfg = dsapp_config()) {
  base <- cfg$files_root %||% file.path(cfg$data_root, "files")
  d <- tryCatch(list.files(base, pattern = "^u[0-9]+$", full.names = TRUE),
                error = function(e) character(0))
  d[dir.exists(d)]
}

#' 确保某个账号的管理区目录存在，返回它的路径
dsapp_files_ensure <- function(user_id, cfg = dsapp_config()) {
  d <- dsapp_files_root(user_id, cfg)
  if (!dir.exists(d)) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    # 目录归账号自己：0755 够用（同一个 shiny 进程写所有账号的目录，
    # 靠的是**应用层**的路径隔离，不是文件系统的权限位）。
  }
  d
}

#' 老共用区 → 按账号拆分（V13 item 6，一次性）
#'
#' V12 及以前，data/files/ 是所有人的共用区，里面直接摊着用户传的东西和
#' 每个对话的同步目录。V13 把根换成了 data/files/u<N>/，那么**已经躺在
#' 那儿的那些东西必须有人搬**，否则用户升级完一打开文件页：空的。
#' 用户 2026-09-16 报的第二条（「比如 brca_result 这个文件夹，我在文件
#' 管理区就看不到」）就是这一类 —— 东西在，但新根下面什么都没有。
#'
#' 归属怎么定：
#'   · 有 file_owner 记录 → 记的那个人（V5 起每个上传点都登记了）
#'   · 没有 → id 最小的那个启用账号。理由：升级之前这个区是"大家的"，
#'     而现实中它几乎总是第一个账号在用；搬到一个确定的人名下，比留一个
#'     谁也不认识的 _legacy 目录强 —— 后者在界面上等于消失了。
#'
#' ⚠️ 用 rename 不用 copy：可能需要搬几十 G，而两者在同一个文件系统里，
#'    rename 是瞬时的、原子的。跨设备时 rename 会失败（EXDEV），那时退回
#'    复制 —— 留着这条退路是因为 data_root 有可能是挂载点。
#'
#' ⚠️ 靠一个**标记文件**判"搬过了"，不靠"目录是不是空的"。判空的话，
#'    一个本来就没有文件的老库每次启动都会再跑一遍；更要命的是，用户后来
#'    自己删光了 u1 里的东西，标记就又"失效"了，于是第二次启动会把
#'    _anon 之类的东西再搬一次。
dsapp_files_migrate <- function(cfg = dsapp_config()) {
  base <- cfg$files_root %||% file.path(cfg$data_root, "files")
  if (!dir.exists(base)) return(invisible(FALSE))
  marker <- file.path(base, ".migrated_v13")
  if (file.exists(marker)) return(invisible(FALSE))

  # 哪些条目是"老共用区的东西"：不是 u<数字>，也不是 _anon，也不是标记。
  # 点开头的（.migrated_v13 自己、用户自己藏的）不算。
  # ⚠️ 同一类坑：`ents != "_anon"`，不是 `!identical(ents, "_anon")`
  #    —— 见下面归属表那段的说明。
  #
  # ⚠️ 已知的模糊地带：老共用区里如果**恰好**有个顶层文件夹叫 `u3`，这里
  #    会把它当成"3 号账号的管理区"而不是待搬的老内容（两处的判据都是
  #    `^u[0-9]+$`）。代价是那个文件夹会出现在 3 号账号的管理区里，不会
  #    丢、也不会串到别人那儿去。用户自己起名恰好撞上 `u<数字>` 的概率
  #    极低，为它加一套"这个 u3 到底是哪一种"的判定不划算 —— 记在这儿，
  #    将来真出现了知道去哪儿找。
  ents <- list.files(base, all.files = FALSE, no.. = TRUE)
  legacy <- ents[!grepl("^u[0-9]+$", ents) & ents != "_anon" &
                 !startsWith(ents, ".")]

  if (!length(legacy)) {
    # 全新库（或者本来就已经是新结构）。直接落标记，不再复查。
    try(file.create(marker), silent = TRUE)
    return(invisible(FALSE))
  }

  # 归属：先查 file_owner，查不到就落到最小的启用账号
  fallback <- tryCatch({
    r <- DBI::dbGetQuery(dsapp_db(cfg),
      "SELECT id FROM users WHERE status = 'active' ORDER BY id LIMIT 1")$id
    if (length(r)) as.integer(r[[1]]) else 1L
  }, error = function(e) 1L)

  owner_of <- function(rel) {
    tryCatch({
      r <- DBI::dbGetQuery(dsapp_db(cfg),
        "SELECT user_id FROM file_owner WHERE name = ?",
        params = list(rel))$user_id
      # 老库的 file_owner.user_id 可能是 NULL（V5 之前建的目录）
      if (length(r) && !is.na(r[[1]])) as.integer(r[[1]]) else fallback
    }, error = function(e) fallback)
  }

  moved <- 0L; failed <- character(0)
  for (e in legacy) {
    uid <- owner_of(e)
    dest_root <- dsapp_files_root(uid, cfg)
    if (!dir.exists(dest_root)) {
      dir.create(dest_root, recursive = TRUE, showWarnings = FALSE)
    }
    dest <- file.path(dest_root, e)
    if (file.exists(dest)) {          # 目标已存在（搬过一半），别覆盖
      failed <- c(failed, e); next
    }
    ok <- tryCatch({
      if (file.rename(file.path(base, e), dest)) TRUE
      else file.copy(file.path(base, e), dest_root, recursive = TRUE,
                     copy.mode = TRUE, copy.date = TRUE)
    }, error = function(e2) FALSE)
    if (isTRUE(ok)) moved <- moved + 1L else failed <- c(failed, e)
  }

  # ---- 归属表也要跟着搬 ---------------------------------------------------
  #
  # 老库的 file_owner.name 是**相对管理区根**的路径（`16S分析/测试文件夹`），
  # 新格式是**带账号前缀**的（`u1/16S分析/测试文件夹`，理由见 users.R 的
  # dsapp_owner_key）。不做这一步的话，升级完之后**每一条归属记录都对不上**：
  # 界面上所有文件显示「公共」，而 dsapp_file_can_edit 认为无主 = 人人可删；
  # 同时 dsapp_files_sync_owners 会把盘上每个文件当成"新的"再补登记一遍，
  # 于是表里一个文件两行（一行旧格式对不上、一行新格式）。
  #
  # 归属人按刚才算出来的落点补齐：老库里 user_id 为 NULL 的行意味着
  # "无主"，而无主在新世界里没有意义（每个人的区是他自己的），
  # 落到 fallback 那个账号上。
  #
  # ⚠️ 只在**没有前缀**的行上做（`name NOT LIKE '%/%'` 不行 —— 路径本来
  #    就带斜杠）。判据取第一段是不是 u<数字> / _anon。
  #
  # ⚠️ `seg != "_anon"` 而不是 `!identical(seg, "_anon")`：seg 是**向量**，
  #    identical() 拿整个向量跟一个长度 1 的字符串比，永远 FALSE —— 于是
  #    `!identical(...)` 恒为 TRUE，`_anon` 那一段根本滤不掉，会被当成老行
  #    改名成 `u<N>/_anon/...`。这类"看起来在过滤、其实恒真"的写法在别的
  #    地方也出现过，见到 identical() 跟向量比就要停下来看一眼。
  try({
    fo <- DBI::dbGetQuery(dsapp_db(cfg), "SELECT name, user_id FROM file_owner")
    if (!is.null(fo) && nrow(fo)) {
      seg <- sub("/.*$", "", fo$name)
      is_legacy <- !grepl("^u[0-9]+$", seg) & seg != "_anon"
      for (i in which(is_legacy)) {
        uid <- if (is.na(fo$user_id[i])) fallback else as.integer(fo$user_id[i])
        DBI::dbExecute(dsapp_db(cfg),
          "UPDATE OR REPLACE file_owner SET name = ?, user_id = ? WHERE name = ?",
          params = list(dsapp_owner_key(fo$name[i], uid), uid, fo$name[i]))
      }
      # 剩下那些已经是新格式、但归属人为空的
      try(DBI::dbExecute(dsapp_db(cfg),
        "UPDATE file_owner SET user_id = ? WHERE user_id IS NULL",
        params = list(fallback)), silent = TRUE)
    }
  }, silent = TRUE)

  try(file.create(marker), silent = TRUE)
  # 走审计日志 —— 这是这个项目里**唯一**的持久日志（没有 dsapp_log 那种东西，
  # 别顺手造一个：一份只在启动时写过一次的日志文件，出问题时没人想得起来看）。
  try(dsapp_audit("files_migrate", target = sprintf("u%d", fallback),
                  detail = sprintf("搬了 %d 项，失败 %d 项%s", moved,
                                   length(failed),
                                   if (length(failed))
                                     paste0("（", paste(utils::head(failed, 5),
                                                       collapse = "、"), "）")
                                   else ""),
                  cfg = cfg), silent = TRUE)
  invisible(moved > 0L)
}

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

#' 把相对路径拆成段，逐段校验
#'
#' V5 起共享区支持子目录，于是"一个名字"变成了"一条相对路径"。路径是
#' 浏览器发来的、彻底不可信的东西，所以**在它碰到文件系统之前**先拆开逐段看：
#'
#'   * 反斜杠先换成斜杠（Windows 传上来的路径分隔符）
#'   * 绝对路径、盘符一律拒绝（`/etc/passwd`、`C:\x`）
#'   * `.` 和 `..` 一律拒绝，不是"消掉它"—— 消掉之后 `a/../../b` 会变成
#'     一个合法的 `b`，而用户以为自己写的是别的地方。而且 `..` 出现在**任何**
#'     一段里都说明这条路径不是界面生成的
#'   * 每一段还要单独过一遍 dsapp_safe_name 并且**不许它改动任何东西**：
#'     清洗后不一样，说明这一段里藏了别的东西（控制字符、`/` 的变体）
#'
#' @return 段向量（`character(0)` 表示根目录）；不合法时 NULL
dsapp_rel_segments <- function(rel) {
  if (is.null(rel) || !length(rel)) return(character(0))
  rel <- as.character(rel)[1]
  if (is.na(rel)) return(NULL)
  rel <- gsub("\\\\", "/", trimws(rel))
  if (!nzchar(rel)) return(character(0))
  if (startsWith(rel, "/")) return(NULL)
  if (grepl("^[A-Za-z]:", rel)) return(NULL)

  parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
  parts <- parts[nzchar(parts)]        # "a//b" 和 "a/b" 是一回事
  if (!length(parts)) return(character(0))
  if (any(parts %in% c(".", ".."))) return(NULL)
  # 以 `-` 开头的段拒绝。共享区里的名字最终会作为**参数**出现在几个外部
  # 命令里（`find`、`du`、`tar`…），而以 `-` 开头的东西在那个位置会被
  # 当成选项 —— 一个叫 `-rf` 的文件名足以让某条命令的意思整个变掉。
  # 这些命令目前都把路径加了引号（挡的是词分割，不是选项解析），而且
  # 路径都是拼出来的；但这是那种"今天没问题、明天有人加一条 system2
  # 就出事"的地方，接口上先关掉。dsapp_node_validate 拒 `-` 开头的
  # 主机名，是同一条理由。
  if (any(startsWith(parts, "-"))) return(NULL)
  for (p in parts) {
    if (!identical(tryCatch(dsapp_safe_name(p), error = function(e) NULL), p)) {
      return(NULL)
    }
  }
  parts
}

#' 在 root 下安全地解析一条相对路径
#'
#' 双重校验：先逐段清洗校验（见 dsapp_rel_segments），再确认拼出来的绝对
#' 路径仍在 root 里。只做前者不够 —— 符号链接可以绕过纯字符串层面的检查。
#'
#' ⚠️ 这是安全边界。文件管理区、对话工作区都走它，所以只有这一份实现，
#'    不要各自再写一遍 —— 两份实现里只要有一份忘了 normalizePath，
#'    那个目录就能被软链绕出去。
#'
#' ⚠️ must_exist = FALSE 时**不能**直接 `normalizePath(dirname(path))`：
#'    多层新目录的第一层还不存在，normalizePath 会失败 —— 于是"新建
#'    a/b/c"永远建不出来，而且报的是一个和目录无关的错。这里往上找到
#'    第一个**存在**的祖先，normalize 它（这一步才认得出软链），再把
#'    剩下几段接回去。
#'
#' @return 合法路径；不合法时返回 NULL（调用方必须处理 NULL）
dsapp_path_in <- function(root, parts, must_exist = TRUE) {
  if (is.null(parts)) return(NULL)
  if (is.null(root) || !dir.exists(root)) return(NULL)
  root_real <- normalizePath(root, mustWork = TRUE)
  if (!length(parts)) return(root_real)

  path <- do.call(file.path, as.list(c(root_real, parts)))

  if (must_exist) {
    if (!file.exists(path)) return(NULL)
    real <- normalizePath(path, mustWork = TRUE)
  } else {
    anc <- path; rest <- character(0)
    while (!dir.exists(anc)) {
      rest <- c(basename(anc), rest)
      parent <- dirname(anc)
      # 一路走到文件系统根还是不存在：说明 root 本身有问题，放弃
      if (identical(parent, anc)) return(NULL)
      anc <- parent
    }
    real <- normalizePath(anc, mustWork = TRUE)
    if (length(rest)) real <- do.call(file.path, as.list(c(real, rest)))
  }

  # 前缀必须精确匹配到目录边界：/data/files2 不能通过 /data/files 的检查
  if (!startsWith(real, paste0(root_real, .Platform$file.sep)) &&
      !identical(real, root_real)) {
    return(NULL)
  }
  real
}

#' 把浏览器报回来的相对路径与上传行**按下标**对齐
#'
#' 文件夹上传时，Shiny 服务端的 `FileUploadOperation$fileBegin` 会把目录
#' 成分 basename 掉（见 www/app.js 里那段说明），所以相对路径是**另一条
#' 输入**报回来的。两条输入靠**顺序**对应 —— Shiny 按 FileList 的顺序逐个
#' 上报，浏览器那边也按同一个顺序取。
#'
#' ⚠️ 和 `R/mod_files.R` 里那段同类逻辑**刻意有一处不同**：长度对不上时的
#'    basename 兜底，那边用 `hit[1]`，这里**同名候选多于一个就放弃**（留 NA
#'    → 该文件平铺到根目录）。理由是 10x 数据天然长这样：
#'    `sample1/matrix.mtx` 和 `sample2/matrix.mtx` 同名，挑第一个就是张冠李戴
#'    —— 用户拿到的是"跑通了，但用的是另一个样本"。平铺是**看得见**的结构
#'    丢失，比静默换样本好。别顺手把两处统一回去。
#'
#' @param up    `input$<fileInput>`（data.frame，至少有 name）
#' @param paths 浏览器报回来的相对路径向量，或 NULL
#' @return character(nrow(up))；对不上的位置是 NA（= 平铺到根目录）
dsapp_upload_rels <- function(up, paths) {
  n <- if (is.null(up)) 0L else NROW(up)
  if (!n) return(character(0))
  rels <- rep(NA_character_, n)
  if (is.null(paths) || !length(paths)) return(rels)
  paths <- as.character(paths)
  if (length(paths) == n) return(paths)
  # 长度对不上：JS 那边的 MAX=3000 截断、老浏览器不给 webkitRelativePath、
  # 或者用户混选。只对**唯一同名**做配对。
  used <- rep(FALSE, length(paths))
  nm <- as.character(up$name)
  for (i in seq_len(n)) {
    hit <- which(!used & basename(paths) == nm[i])
    if (length(hit) == 1L) { rels[i] <- paths[hit[[1]]]; used[hit[[1]]] <- TRUE }
  }
  rels
}

#' 把共享区里的文件**只读地**挂进一个工作区
#'
#' 和 `dsapp_mirror_shared()` 的关系：
#'   * 那个是**整片平移**（递归整个共享区，最深 8 层），只在执行代码时跑一次；
#'   * 这个是**点名挂几个**，给"用户刚上传完，立刻要用"这种交互路径用。
#'
#' ⚠️ 交互路径上**绝不能**调 `dsapp_mirror_shared()`：它会遍历共享区里的
#'    每一个文件，用户攒了几万个文件之后，每传一次文件就卡一次整页。
#'
#' 已存在的名字**不覆盖**（沿用 mirror_shared 的立场：工作区里第 1 轮产出的
#' 同名文件优先，那多半是用户的真实数据）。
#'
#' @param cfg   config（只为拿 `files_dir`）
#' @param rels  相对共享区根的路径向量（= `dsapp_file_save()` 返回的 `msg`）
#' @param ws    目标工作区目录
#' @return list(ok, ws, placed, skipped, failed, msg)
dsapp_mirror_into_ws <- function(cfg, rels, ws, create = TRUE) {
  out <- list(ok = FALSE, ws = NA_character_, placed = character(0),
              skipped = character(0), failed = character(0), msg = "")
  if (is.null(ws) || length(ws) != 1L || is.na(ws) || !nzchar(ws)) {
    out$msg <- "没有打开的对话（拿不到工作区）"
    return(out)
  }
  # 工作区是**懒建**的（纯文字消息不建目录，见 executor.R）。这里是第三个
  # 建它的地方 —— 之所以在这里建：用户点「上传」就是明确的"我要在这个对话里
  # 干活"，比"打开这一页"强得多。不建的话 dsapp_cloudx_file_choices() 对
  # 不存在的目录返回 character(0)，下拉里永远只有那个手填哨兵。
  if (!dir.exists(ws)) {
    if (!isTRUE(create)) { out$msg <- "工作区目录还不存在"; return(out) }
    dir.create(ws, recursive = TRUE, showWarnings = FALSE)
    if (!dir.exists(ws)) {
      out$msg <- sprintf("建不出工作区目录：%s", ws)
      return(out)
    }
  }
  out$ws <- ws
  for (r in rels) {
    seg <- dsapp_rel_segments(r)
    # ⚠️ 两端都过 dsapp_path_in（安全边界，见它自己的说明）：单纯 file.path
    #    拼出来的路径挡不住软链绕出 root，而这里的 rel 来自浏览器。
    src <- if (is.null(seg)) NULL else
      dsapp_path_in(cfg$files_dir, seg, must_exist = TRUE)
    dst <- if (is.null(seg)) NULL else
      dsapp_path_in(ws, seg, must_exist = FALSE)
    if (is.null(seg) || is.null(src) || is.null(dst)) {
      out$failed <- c(out$failed, r); next
    }
    if (file.exists(dst) || dsapp_is_link(dst)) {
      out$skipped <- c(out$skipped, r); next
    }
    mid <- dirname(dst)
    if (!dir.exists(mid)) dir.create(mid, recursive = TRUE, showWarnings = FALSE)
    if (isTRUE(dsapp_place_input(src, dst))) out$placed <- c(out$placed, r)
    else out$failed <- c(out$failed, r)
  }
  out$ok <- length(out$placed) > 0L || length(out$skipped) > 0L
  out$msg <- sprintf("挂进工作区 %d 个（已存在跳过 %d，失败 %d）",
                     length(out$placed), length(out$skipped),
                     length(out$failed))
  out
}

#' 在指定目录下安全地解析**一个文件名**（不含路径）
dsapp_safe_path_in <- function(root, name, must_exist = TRUE) {
  if (is.null(name) || !length(name)) return(NULL)
  name <- as.character(name)[1]
  if (is.na(name) || !nzchar(name)) return(NULL)
  if (!dir.exists(root)) return(NULL)

  safe <- dsapp_safe_name(name)
  # 清洗后名字变了，说明原始输入里带了路径成分，直接拒绝而不是"纠正后使用"
  if (!identical(safe, name)) return(NULL)
  dsapp_path_in(root, safe, must_exist)
}

#' 安全地解析文件管理区里的路径
#'
#' @param name 相对路径，可以带 `/`（V5 起共享区有子目录）。
#'   根目录写 `""`。
dsapp_file_path <- function(name, cfg = dsapp_config(), must_exist = TRUE) {
  dsapp_path_in(cfg$files_dir, dsapp_rel_segments(name), must_exist)
}

#' 安全地解析对话工作区里的路径
dsapp_ws_path <- function(name, sid, cfg = dsapp_config(), must_exist = TRUE) {
  d <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(d)) return(NULL)
  # 走 dsapp_path_in 而不是 dsapp_safe_path_in：工作区里也有子目录了
  # （模型把图写进 results/ 是常态），名字里的 `/` 必须能穿透。
  dsapp_path_in(d, dsapp_rel_segments(name), must_exist)
}

#' 产物路径的**唯一**入口：认两种坐标，靠前缀区分
#'
#' ★ V13.11 item 1。这个应用里的"产物"有**两个**根，而且同名文件在两个根
#' 底下都可能有：
#'
#'   * `""`（无前缀）—— **对话工作区**（`data/workspaces/chat-<sid>/`）。
#'     模型跑出来的原始产出，也是每一条助手消息的正文里被自动识别成链接的
#'     那些文件名（`dsapp_linkify_files` 拿的是工作区相对路径）。
#'   * `"files:"`  —— **文件管理区里本对话的那个文件夹**
#'     （`data/files/u<N>/<标题>-<尾4位>/`）。"言出法随"页右边那张
#'     「本对话的文件」卡走的是这一条，见 mod_chat.R 的 `output$artifacts_card`。
#'
#' ⚠️ **为什么非要一个前缀，而不是"先按文件区试、找不到再退回工作区"**：
#'    两条路都会**成功**，只是成功到不同的文件上。正文里那句 `results/` 被
#'    链接出来的是工作区那份；而文件区根目录下很可能真有一个同名的
#'    `results/`（用户自己传的）。悄悄按另一个根解析，用户点开看到的是
#'    **别人的/另一份**文件 —— 没有任何报错，只是内容不对。所以坐标必须
#'    由**发出方**写死，解析这一侧只做白名单式分派，不做猜测。
#'
#' ⚠️ 文件区那一支要用 `dsapp_config_sid()` 而不是调用方传进来的 cfg：
#'    对话被共享出去之后，看页面的人不是对话主人，而文件区是**按账号分的**
#'    （`data/files/u<N>/`）。用观看者的 cfg 解析，会去他自己的文件区里找
#'    一个不存在的文件夹 —— 表现是"这个对话的文件一个都没有"，而主人那边
#'    明明有。工作区那一支同理（`dsapp_ws_path` 的调用方一直传的就是 sid 绑
#'    的 cfg，这里只是把这条不变式写死在一个地方）。
dsapp_art_path <- function(name, sid, cfg = dsapp_config(), must_exist = TRUE) {
  name <- as.character(name %||% "")
  if (length(name) != 1L || is.na(name) || !nzchar(name)) return(NULL)
  if (startsWith(name, DSAPP_ART_FILES_PREFIX)) {
    rel <- sub(paste0("^", DSAPP_ART_FILES_PREFIX), "", name)
    dsapp_file_path(rel, dsapp_config_sid(sid, cfg), must_exist)
  } else {
    dsapp_ws_path(name, sid, dsapp_config_sid(sid, cfg), must_exist)
  }
}

#' 把一条文件区相对路径包成产物坐标（`dsapp_art_path` 认的那种）
#'
#' ⚠️ 零长度输入必须**原样**返回零长度。`paste0("files:", character(0))` 在 R
#'    里给的不是长度 0，而是**长度 1 的 `"files:"`**（paste 把零长度参数当成
#'    空串参与拼接）。调用方是拿它去填数据框一列的：0 行的表 + 长度 1 的值 =
#'    `replacement has 1 row, data has 0`。文件区**是空的**那种对话（新开的
#'    对话、还没产出任何东西的对话）刚好就是 0 行，于是整张产物卡片渲染不出
#'    来，界面上是一片红字 Error —— 而这恰恰是最常见的状态。
#'    V15.5 的自检只验了源码里那一行长什么样（`df$coord <- dsapp_art_files_ref(df$rel)`），
#'    没验空表跑一遍，于是全绿着漏过去了。
dsapp_art_files_ref <- function(rel) {
  if (!length(rel)) return(character(0))
  paste0(DSAPP_ART_FILES_PREFIX, rel)
}

#' 把"当前这一层往下"的相对路径包成产物坐标（★ V15.5 item 10）
#'
#' `dsapp_art_tree_images()` 那一路（缩略图）给回来的 `rel` 是**相对 root**
#' 的，而 `files:` 坐标是**相对账号文件区根**（`data/files/u<N>/`）的 ——
#' 中间隔着"当前这一层"（`<对话文件夹>/results` 这种）。少拼这一层的话，
#' `files:results/plot.png` 会被解析到文件区**根**下的 `results/plot.png`：
#' 那个位置要么是用户自己传的一份同名文件（点开看到的是别的东西），要么
#' 根本不存在 —— 而**不存在时界面只是什么都不画**（renderImage 拿到 NULL
#' 就直接返回），不报错、日志里也没有。V15.4 那版缩略图就是这么静默地
#' 一直是空的，自检还全绿（它只验了"取图"那一步，没人验坐标能不能落回盘上）。
#'
#' @param level_rel 当前这一层在文件区里的相对路径（`dsapp_files_list()` 的
#'   `rel` 口径：第一段是对话文件夹名）
#' @param rel 相对 `level_rel` 的路径（可以带 `/`，可以是向量）
dsapp_art_files_ref_in <- function(level_rel, rel) {
  # ⚠️ 零长度要在**第一行**就拦住，挡在下面那句 `%||% ""` **之前**：
  #    `%||%` 对 length(a)==0 是走 fallback 的（见 utils.R），于是
  #    `character(0) %||% ""` 回来的是**长度 1 的 `""`**，零长度这个信息到
  #    这里就已经没了。再往下 `paste0("lvl", "/", "")` 给出 `"lvl/"`，
  #    最后是一个看着挺像坐标、其实指向目录本身的 `files:lvl/` —— 和
  #    `dsapp_art_files_ref` 里那个 paste0 零长度坑是同一类。
  #    眼下调用方 art_thumbs_norm() 在 0 行时就提前返回了，所以还没人踩到；
  #    但那是**别处**的守卫顺手挡住的，不是这里对了。
  if (!length(rel)) return(character(0))
  level_rel <- as.character(level_rel %||% "")
  rel <- as.character(rel %||% "")
  out <- if (length(level_rel) == 1L && nzchar(level_rel)) {
    paste0(level_rel, "/", rel)
  } else rel
  dsapp_art_files_ref(out)
}

#' 产物坐标 → `list(root, rel)`，给"下载要打包"那件事用（★ V14 item 3）
#'
#' `dsapp_art_path()` 给的是**绝对路径**，而打包（zip 里的条目名）要的是
#' "相对哪个根"。这两种坐标对应的根**不一样**：
#'   · 工作区坐标 → 根是本对话的工作区目录；
#'   · `files:` 坐标 → 根是**这个对话在文件区里的那个文件夹**
#'     （`data/files/u<N>/<标题>-<尾号>/`），不是整个 `files_dir`
#'     —— 后者会把 `u1/` 这一层也打进包里，而且不同账号的目录名会撞。
#'
#' ⚠️ 和 `dsapp_art_path` 用同一个 `dsapp_config_sid(sid, cfg)`：对话被共享
#'    出去之后，看页面的人不是对话主人，用观看者的 cfg 会指到别人的文件区。
dsapp_art_root_rel <- function(name, sid, cfg = dsapp_config()) {
  cfg_sid <- dsapp_config_sid(sid, cfg)
  name <- as.character(name %||% "")
  if (length(name) != 1L || is.na(name) || !nzchar(name)) {
    return(list(root = NULL, rel = NULL))
  }
  if (startsWith(name, DSAPP_ART_FILES_PREFIX)) {
    rel <- sub(paste0("^", DSAPP_ART_FILES_PREFIX), "", name)
    # 打包的根取"这个文件所在的那一层"再往上收到对话文件夹 —— 直接用
    # dirname(rel) 会把包打散（同一份 md 引到隔壁文件夹的图就丢了）。
    # 对话文件夹 = 文件区路径的第一段。
    parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
    base <- if (length(parts) > 1) parts[[1]] else ""
    root <- if (nzchar(base)) file.path(cfg_sid$files_dir, base) else cfg_sid$files_dir
    # ★★ V16.10：`rel` 必须是**相对 `root`** 的，这里以前返回的是相对
    #    `files_dir` 的那一份（带着第一段），于是 `file.path(root, rel)`
    #    把对话文件夹拼了两遍 —— 那个路径**不存在**。
    #
    #    实测（2026-10-07，只读）：
    #      coord = files:帮我看一下TP53…-6087/nsclc_data/LUAD_clinicalMatrix.tsv
    #      root  = …/data/files/u1/帮我看一下TP53…-6087
    #      rel   = 帮我看一下TP53…-6087/nsclc_data/LUAD_clinicalMatrix.tsv
    #      file.exists(file.path(root, rel))          → FALSE
    #      file.exists(file.path(cfg$files_dir, rel)) → TRUE
    #
    #    `dsapp_dl_plan()` 的 `@param rel` 明写「`path` 相对 `root` 的路径」,
    #    所以违反契约的是**这一边**。可达的那条路只有"文件区里的 .md 且
    #    有本地依赖"（那种才走 kind="zip"）：`dsapp_md_deps(path, root)` 回来
    #    的 deps 是相对 root 的，和这个翻倍的 rel 混在一个 `zip::zip(files=,
    #    root=)` 里 —— 前者能进包、后者找不到，而 `dsapp_art_dl` 的
    #    `content()` **不看 `dsapp_dl_write()` 的返回值** ⇒ 用户拿到一个缺件
    #    的包，界面一声不吭。修在这里，deps 和 rel 才是同一个口径。
    #
    #    ⚠️ `length(parts) == 1` 那一支（坐标就是对话文件夹本身）**本来就
    #       自洽**：root = files_dir，rel = `<base>` 正好相对它。别一起改。
    rel <- if (nzchar(base)) paste(parts[-1], collapse = "/") else rel
    list(root = root, rel = rel)
  } else {
    list(root = dsapp_ws_dir(sid, cfg_sid, create = FALSE), rel = name)
  }
}

#' 产物坐标 → 给人看的名字（剥掉 `files:` 前缀）
#'
#' ⚠️ 剥前缀这一步看着多余，其实每一处都非做不可：凡是拿坐标去
#'    `basename()` / `tools::file_ext()` / `dsapp_file_kind()` / 显示的地方，
#'    留着前缀就是拿 `files:x/y.png` 当文件名。`basename()` 侥幸还能对，
#'    但只要坐标是"文件夹本身"（`files:很高兴-1234`，没有斜杠），
#'    basename 就把整个 `files:很高兴-1234` 原样还回来 —— 那串会**直接显示
#'    在弹窗标题上**。
dsapp_art_label <- function(name) {
  name <- as.character(name %||% "")
  sub(paste0("^", DSAPP_ART_FILES_PREFIX), "", name)
}

#' 把共享区里的文件标成只读
#'
#' ⚠️ 上传区的文件必须只读，这是**安全属性**：执行时这些文件以软链进入
#'    工作区，软链会穿透写 —— 脚本里一句 write.csv(df, "expr.csv") 就能
#'    把用户上传的原始数据静默覆盖掉。同名写出在生信脚本里是非常常见的写法。
#'
#' 以前这件事是在 executor.R 里做的：每次代码执行前，把整个共享区 chmod
#' 一遍。那是让**任务去改全局共享状态**，而且只在有任务跑的时候才生效 ——
#' 上传之后到下次执行之间那道口子是开着的。现在改成每个写入点各设一次，
#' 谁写谁负责。
dsapp_files_protect <- function(path) {
  if (is.null(path) || is.na(path) || !file.exists(path)) return(invisible(FALSE))
  # 目录不能设 0444：那样谁也进不去，得保持可进入
  if (isTRUE(file.info(path)$isdir)) return(invisible(FALSE))
  try(Sys.chmod(path, mode = "0444"), silent = TRUE)
  invisible(TRUE)
}

#' 空目录列表
dsapp_files_empty <- function() {
  data.frame(name = character(0), rel = character(0), is_dir = logical(0),
             size = numeric(0), size_h = character(0), mtime = character(0),
             kind = character(0), stringsAsFactors = FALSE)
}

#' 列出文件管理区**某一层**的内容
#'
#' V5 起共享区有子目录，所以这里列的是"当前这一层"，不是全树。
#' 每一行带 `rel`（相对根目录的路径），界面拿它做面包屑和操作坐标。
#'
#' ⚠️ 用 list.files 的**非递归**形式，不要图省事开 recursive = TRUE：
#'    它会跟着目录软链一路钻下去（共享区里放一个 `loop -> .` 就能让它
#'    无限展开），而且列全树之后界面上的"新建文件夹"就无从谈起了。
#'
#' @param dir 当前目录的相对路径，`""` 是根
dsapp_files_list <- function(cfg = dsapp_config(), dir = "") {
  d <- dsapp_file_path(dir, cfg, must_exist = TRUE)
  if (is.null(d) || !dir.exists(d)) return(dsapp_files_empty())

  fs <- list.files(d, all.files = FALSE, no.. = TRUE)
  if (!length(fs)) return(dsapp_files_empty())

  info <- file.info(file.path(d, fs))
  keep <- !is.na(info$size)
  fs <- fs[keep]; info <- info[keep, , drop = FALSE]
  if (!length(fs)) return(dsapp_files_empty())

  is_dir <- as.logical(info$isdir)
  # 名字里已经带 `/` 的软链目录不列出来：点进去就出了共享区（normalizePath
  # 那关会拒绝它），界面上会表现成"点了一下什么都没发生"。不如不显示。
  if (any(is_dir)) {
    for (i in which(is_dir)) {
      if (dsapp_is_link(file.path(d, fs[i])) &&
          is.null(dsapp_path_in(cfg$files_dir,
                                c(dsapp_rel_segments(dir), fs[i])))) {
        is_dir[i] <- FALSE
      }
    }
  }

  prefix <- if (nzchar(dir)) paste0(sub("/+$", "", dir), "/") else ""
  data.frame(
    name   = fs,
    rel    = paste0(prefix, fs),
    is_dir = is_dir,
    # 目录的大小恒为 0：显示一个"目录占 4 KB"是文件系统的元数据，
    # 对用户没有意义，而算真实体积要给每个目录跑一次 du。
    size   = ifelse(is_dir, 0, info$size),
    size_h = ifelse(is_dir, "—", vapply(info$size, dsapp_fmt_bytes, character(1))),
    mtime  = format(info$mtime, "%Y-%m-%d %H:%M"),
    kind   = ifelse(is_dir, "folder", vapply(fs, dsapp_file_kind, character(1))),
    stringsAsFactors = FALSE
  )
}

#' 文件列表的**规范顺序**（目录在前，然后**按修改时间从新到旧**）
#'
#' ★ V14 item 2：原来是"目录在前、按名字升序"。用户原话：「文件管理区应该
#'   默认把时间更新的内容展示在前面」。
#'
#'   ⚠️ 改的理由是**否定**出来的：按名字排对一个"我自己往里放东西"的目录
#'      没有意义 —— 名字是用户自己起的，跟他此刻要找的东西没关系；而这个
#'      应用里绝大多数文件是**刚跑出来的产物**（`step5_forest_cox.png`、
#'      `分析报告.html`），用户来这一页的动作几乎总是"拿刚才那个东西"。
#'      按名字排要么把它埋在中间，要么沉到底下，每次都得先点一下表头。
#'
#'   ⚠️ 目录**仍然在最前面**，没有跟着一起按时间排。这是有意的：目录在这张
#'      表里是**导航**（点进去、面包屑、上传目标），不是内容。让它按时间
#'      混进文件堆里，用户要找"上一层"就得先找它在哪 —— 而文件管理器
#'      （Finder / 资源管理器）全都是目录在前，改掉是在跟肌肉记忆打架。
#'      目录之间仍按名字排（目录通常就几个，名字比时间好认）。
#'
#'   ⚠️ 时间用的是 `df$mtime` 那一列**格式化过的字符串**，这里重新解析回
#'      时间戳。不直接按字符串排是因为那等于在依赖 `"%Y-%m-%d %H:%M"` 的
#'      定宽零填充 —— 哪天有人把这个格式改成 `%Y/%-m/%-d`，排序会**静默地**
#'      变成字典序（"2026-9-9" 排在 "2026-10-1" 后面），而且看上去还挺像
#'      回事。解析一次不贵，`dsapp_files_order` 每次渲染只跑一次。
#'      解析不出来（NA）的排在最后（`order()` 的 na.last 默认就是 TRUE）。
#'
#' ⚠️ 这个函数存在的唯一理由是：**表格的显示顺序必须和数据框的行顺序一致**。
#'    界面上所有按行号取数据的操作（选中、删除、改名、点名字进目录）都是拿
#'    DT 给的行号去 `files()` 里取第 i 行 —— 这两边顺序一旦不同，用户在界面上
#'    选中第 1 行、程序动的却是另一个文件。删除尤其致命：那是"我没选它，它却
#'    没了"。
#'
#'    `dsapp_files_list()` 给的是 `list.files()` 的顺序，也就是文件系统的
#'    readdir 顺序（ext4 开了 htree 之后是哈希序，不是字母序）。所以排序
#'    必须在**渲染之前、并且只做一次**，让显示和数据共用同一个结果。
#'
#'    另外：DT 客户端点表头排序**不会**破坏这个对应关系 ——
#'    `input$tbl_rows_selected` / `cell_clicked$row` 传回来的是**数据行号**
#'    （DT 源码里 `tweakCellIndex` 用的是 `cell().index().row`，不是显示位置）。
dsapp_files_order <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(df)
  # ⚠️ 没有 mtime 列时退回"按名字" —— 不能让整个文件页**崩掉**。
  #    这个函数以前只认 name / is_dir 两列，是 V14 才引入 mtime 的，
  #    而它的调用方不止一处（自检里那个手搓的夹具就没有 mtime）。
  #    缺一列就抛 "argument lengths differ"，症状是文件页整个渲染不出来，
  #    报错还停在 order() 这种和业务无关的地方 —— 不如退化成旧行为。
  ts <- if (is.null(df$mtime)) NULL else suppressWarnings(
    as.numeric(as.POSIXct(df$mtime, format = "%Y-%m-%d %H:%M", tz = "UTC")))
  if (!is.null(ts) && length(ts) == nrow(df)) {
    # ★ V14 item 2：目录在前（按名字）→ 文件按修改时间**从新到旧**。
    ts[is.na(ts)] <- -Inf        # 解析不出来的压到最后，不依赖 na.last 的默认值
    # ⚠️ 目录的时间键要**置成同一个常数**，不能是 NA。
    #    order() 的 na.last 是**全局**的：给目录留 NA 的话，它们会被整批
    #    挪到结果最后 —— 连"目录在前"这条一起推翻，而且看起来像是排序没生效。
    #    置成 0 之后目录之间在时间键上全部并列，自然地落到第三键（名字）上，
    #    正好就是"目录之间按名字排"。
    key <- ifelse(df$is_dir, 0, -ts)
    return(df[order(!df$is_dir, key, tolower(df$name)), , drop = FALSE])
  }
  df[order(!df$is_dir, tolower(df$name)), , drop = FALSE]
}

#' 把一份清单规范成"展示层直接可用"的字段（★ V16.10）
#'
#' 起因是用户那句「言出法随的文件页面和真正的文件管理页面文件不同步，那意味着
#' 你写了两套文件展示系统」。**数据层本来就只有一套**（`dsapp_files_list()` +
#' `dsapp_files_order()`，两个页面都在调），这话真正命中的是**展示层的三处漂移**：
#'
#'   · 目录怎么标 —— 文件页那张 DT 往名字前面塞一个 📁（`R/mod_files.R` 的
#'     `output$tbl`）；对话页右边那张卡用 FontAwesome 的 `folder` 图标 + 一枚
#'     「文件夹」徽标；文件页的工作区卡片（`ws_row`）又是图标 + 一枚
#'     `dsapp-pill`。三处各写各的。
#'   · 文件用什么图标 —— 对话页写 `file-lines`，工作区卡片写 `file`。
#'   · 目录的大小 —— 三个地方三种写法：`dsapp_files_list()` 给 `"—"`、
#'     对话页那一支 `if (!is_d)` 干脆不显示、`dsapp_ws_artifacts()` 给
#'     **真实字节数**。合并到同一张卡片上之后，用户看到的是"同样是文件夹，
#'     一行写 `20 B`、一行写 `—`"，分不出哪个才算数。
#'
#' 这个函数把这三条**收口到一处**，两个页面各自保留形态（一边是 htmltools 的
#' `lapply`、一边是 `DT::renderDataTable`）—— 手上拿的是同一份字段。
#'
#' ⚠️ 如实说清它的边界：它**不是**"消灭了两套系统"，数据层从来只有一套。
#'    它挡的是"下次再有人加一处展示时，图标名/徽标文案又抄一遍、抄歪一处"
#'    —— 那种不一致不会报错，只会让两个页面看着不像一个软件。
#'
#' ⚠️ 不改 `df` 已有的列（`name` / `rel` / `mtime` / `kind` 原样透传）：
#'    DT 那边要拿 `size_h` 和 `mtime` 直接当列，`_rel` 那一列还绑着行号。
#'    只**追加**四列。行数、行序一律不动 —— `dsapp_files_order()` 的输出顺序
#'    是"显示的行"和"数据框的第 i 行"之间的唯一约定（见它那段说明）。
#'
#' ⚠️ 唯一的例外是 `size_h`：**目录那一格一律改写成 `"—"`**（上面第二条）。
#'    文件区那支本来就是 `—`，改的其实是工作区那支给的真实字节数 ——
#'    不改的话同一个文件夹在两个页面上是两个数。
#'
#' @param df `dsapp_files_list()` 那一层清单（允许 0 行）
#' @return `df` + `icon`（FontAwesome 名）/ `mark`（徽标文字，非目录是 NA）/
#'         `action`（`"open"` / `"preview"`）/ `dt_name`（DT 那一列的名字，
#'         目录带 📁 前缀）
dsapp_files_rows <- function(df) {
  if (is.null(df)) df <- dsapp_files_empty()
  n <- nrow(df)
  if (n == 0) {
    df$icon    <- character(0)
    df$mark    <- character(0)
    df$action  <- character(0)
    df$dt_name <- character(0)
    return(df)
  }
  # ⚠️ 用 `%||%` 兜底而不是直接 `df$is_dir`：这个函数的调用方不止
  #    `dsapp_files_list()`（自检里那个手搓的夹具就只有 name/is_dir 两列，
  #    `dsapp_files_order()` 的注释里记着同一件事）。少一列就抛
  #    "argument lengths differ"，报错停在和业务无关的地方。
  is_dir <- if (is.null(df$is_dir)) rep(FALSE, n) else as.logical(df$is_dir)
  is_dir[is.na(is_dir)] <- FALSE
  nm <- if (is.null(df$name)) rep("", n) else as.character(df$name)

  # ★ V16.10：目录的体积统一写 `—`（见函数头那条）。
  #   三个来源本来是三种写法：`dsapp_files_list()` 给 `—`、对话页那一支
  #   `if (!is_d)` 不显示、`dsapp_ws_artifacts()` 给真实字节数。合并到同一张
  #   卡片上之后就成了"同样是文件夹，一行 20 B、一行 —"。
  #   ★ 这条是**探针抓出来的**：`tests/ui_v1610` 里"目录那一行写 —"红在
  #     `results 20 B 文件夹` 上，而它在自检里全绿 —— 自检只验"函数写好了
  #     没"，验不到"合并之后两边合起来长什么样"。
  #   ⚠️ 放在 `n == 0` 那道提前返回**之后**：空表没有行要写，加列反而会让
  #      "空表也要有这四列"那条约定的含义变模糊。
  if (!is.null(df$size_h)) df$size_h[is_dir] <- "—"

  df$icon    <- ifelse(is_dir, "folder", "file")
  df$mark    <- ifelse(is_dir, "文件夹", NA_character_)
  df$action  <- ifelse(is_dir, "open", "preview")
  # DT 那里不能用 FontAwesome（那一格是纯文本，塞不进 <i>），所以目录靠一个
  # emoji 标。文案和上面 `mark` 是**同一条规则**，只是表达形式不同 ——
  # 两个表达都从这一个函数出去，改的时候一起改。
  df$dt_name <- ifelse(is_dir, paste0("\U0001F4C1 ", nm), nm)
  df
}

#' 新建文件夹
#'
#' @param dir 在哪个目录下建（相对路径），`""` = 根目录
#' @param name 文件夹名（不含路径；界面也允许用户敲 "a/b" 一次性建多级）
#' @param user_id 建它的人。**目录也要登记归属**：不登记的话它无主，
#'   而 dsapp_file_can_edit 对无主条目是放行的 —— 任何人都能改你建的
#'   文件夹的名字。空的文件夹本身没什么可损失的，但"我建的东西别人
#'   随手能改名"会让共享区变得没法协作。
#' @return list(ok, rel, msg)
dsapp_dir_create <- function(dir, name, cfg = dsapp_config(), user_id = NULL) {
  parts <- dsapp_rel_segments(dir)
  if (is.null(parts)) return(list(ok = FALSE, msg = "目录路径不合法"))

  # 允许一次建多级：用户敲 "GSE123/raw" 是很自然的写法，
  # 逼他建两次只会让人嫌烦。逐段校验交给 dsapp_rel_segments。
  sub <- dsapp_rel_segments(name)
  if (is.null(sub)) {
    return(list(ok = FALSE, msg = "文件夹名字不合法（不能含 / 之外的特殊字符，也不能是 . 或 ..）"))
  }
  if (!length(sub)) return(list(ok = FALSE, msg = "请填文件夹名字"))

  full <- c(parts, sub)
  rel  <- paste(full, collapse = "/")
  path <- dsapp_path_in(cfg$files_dir, full, must_exist = FALSE)
  if (is.null(path)) return(list(ok = FALSE, msg = "路径不合法"))
  if (file.exists(path)) {
    return(list(ok = FALSE, msg = sprintf("「%s」已经存在了", rel)))
  }
  if (!dir.create(path, recursive = TRUE, showWarnings = FALSE)) {
    return(list(ok = FALSE, msg = "建目录失败（检查共享区的权限）"))
  }
  # 一次建多级时，中间那几级也一起登记 —— 只登记最后一层的话，
  # "GSE123/raw" 里的 GSE123 是无主的，别人能把它连名带内容一起改掉。
  #
  # ⚠️ 只认领**无主**的。中间那几级很可能本来就存在、是别人建的
  #    （用户敲 "GSE123/raw" 时 GSE123 常常早就在那了），无条件写会把
  #    人家的归属改成自己的 —— 一句话就把别人的文件夹变成自己的，
  #    顺带把原主人挤成"无权改名"。
  if (!is.null(user_id) && !is.na(user_id)) {
    con <- dsapp_db(cfg)
    for (k in seq_along(sub)) {
      r <- paste(full[seq_len(length(parts) + k)], collapse = "/")
      if (is.na(dsapp_file_owner(r, con, user_id))) {
        try(dsapp_file_owner_set(r, user_id, con), silent = TRUE)
      }
    }
  }
  list(ok = TRUE, rel = rel, msg = sprintf("已新建文件夹「%s」", rel))
}

#' 改名 / 移动
#'
#' @param rel 要动的条目（相对路径）
#' @param to  新名字（只改名）或新相对路径（移动）。两种情况共用一个函数：
#'   在文件系统层面它们本来就是同一件事（rename），拆成两个只会让"改名到
#'   另一个目录里"这种操作落进缝里。
#' @param keep_name TRUE 时 to 被当成**目标目录**，名字沿用原来的（界面上
#'   的"移动到…"）
dsapp_entry_move <- function(rel, to, cfg = dsapp_config(), keep_name = FALSE) {
  src_parts <- dsapp_rel_segments(rel)
  if (is.null(src_parts) || !length(src_parts)) {
    return(list(ok = FALSE, msg = "请先选一个文件或文件夹"))
  }
  dst_parts <- dsapp_rel_segments(to)
  if (is.null(dst_parts)) return(list(ok = FALSE, msg = "目标名字不合法"))
  if (keep_name) dst_parts <- c(dst_parts, src_parts[length(src_parts)])
  if (!length(dst_parts)) return(list(ok = FALSE, msg = "请填新的名字"))

  src <- dsapp_path_in(cfg$files_dir, src_parts, must_exist = TRUE)
  if (is.null(src)) return(list(ok = FALSE, msg = "文件不存在或路径不合法"))

  # 移进自己里面：`a` → `a/b`。rename 会失败，但错误信息是系统给的
  # （"Invalid argument"），用户看不懂。这里提前拦住并说人话。
  if (length(dst_parts) > length(src_parts) &&
      identical(dst_parts[seq_along(src_parts)], src_parts)) {
    return(list(ok = FALSE, msg = "不能把一个文件夹移动到它自己里面"))
  }

  dst <- dsapp_path_in(cfg$files_dir, dst_parts, must_exist = FALSE)
  if (is.null(dst)) return(list(ok = FALSE, msg = "目标路径不合法"))
  if (file.exists(dst)) {
    return(list(ok = FALSE, msg = sprintf("「%s」已经存在了",
                                          paste(dst_parts, collapse = "/"))))
  }
  if (!dir.exists(dirname(dst)) &&
      !dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)) {
    return(list(ok = FALSE, msg = "目标目录建不出来"))
  }

  ok <- tryCatch(file.rename(src, dst), error = function(e) FALSE)
  if (!isTRUE(ok)) {
    return(list(ok = FALSE, msg = "改名失败（可能目标已存在，或跨设备）"))
  }

  # 归属记录跟着走。改的是**前缀**：移动一个文件夹时，里面每个文件的
  # 归属行都要一起搬，否则那些文件会突然变成"无主"（人人可删）。
  dsapp_file_owner_move(paste(src_parts, collapse = "/"),
                        paste(dst_parts, collapse = "/"),
                        user_id = dsapp_cfg_uid(cfg))

  list(ok = TRUE, rel = paste(dst_parts, collapse = "/"),
       msg = sprintf("已改名为「%s」", paste(dst_parts, collapse = "/")))
}

#' 删除文件或**空**文件夹
#'
#' ⚠️ 文件夹必须**空**才能删。
#'    递归删一个目录意味着"我删掉自己建的文件夹，顺手删掉别人放在里面的
#'    三个数据集" —— 共享区是所有人的，这个副作用不该由一次点击产生。
#'    空文件夹删不掉只是麻烦一下，误删别人的数据是找不回来的。
dsapp_entry_delete <- function(rel, cfg = dsapp_config()) {
  parts <- dsapp_rel_segments(rel)
  if (is.null(parts) || !length(parts)) {
    return(list(ok = FALSE, msg = "请先选一个文件或文件夹"))
  }
  path <- dsapp_path_in(cfg$files_dir, parts, must_exist = TRUE)
  if (is.null(path)) return(list(ok = FALSE, msg = "文件不存在或路径不合法"))

  if (dir.exists(path) && !dsapp_is_link(path)) {
    inner <- list.files(path, all.files = FALSE, no.. = TRUE)
    if (length(inner)) {
      return(list(ok = FALSE, msg = sprintf(
        "「%s」里还有 %d 个条目，不能删。先把里面的东西删掉或移走。",
        paste(parts, collapse = "/"), length(inner))))
    }
  }

  # ⚠️ **用 file.exists 复核，不要信 unlink 的返回值**。
  #    unlink() 在删不掉的时候既有返回非 0 的、也有返回 0 的（取决于
  #    失败发生在哪一步：目录不可写、文件被设成 0444、路径是个挂载点…）。
  #    返回 0 而什么都没删，界面上会显示"已删除"，然后列表里它还在 ——
  #    用户会以为是自己看错了，反复点几次。
  try(unlink(path, recursive = TRUE, force = TRUE), silent = TRUE)
  if (file.exists(path)) {
    return(list(ok = FALSE,
                msg = "删除失败：文件还在。多半是共享区目录的权限问题，找管理员看一下。"))
  }
  dsapp_file_owner_drop(paste(parts, collapse = "/"),
                        user_id = dsapp_cfg_uid(cfg))
  list(ok = TRUE, msg = sprintf("已删除「%s」", paste(parts, collapse = "/")))
}

#' 删一个对话时，把它留在**文件管理区**里的东西一并清掉
#'
#' ★ Test_V17.2 item 1。用户原话：「Biomamba_ceshi 账号下，会话删除后，
#' 文件页面的文件还存在」。
#'
#' 成因很直白：`db_session_delete()` 会删掉 `ws_published` 的行
#' （R/db.R），但**盘上一个字节都不动** —— 删对话那条路只调了
#' `dsapp_ws_delete()`，而它删的是**工作区**（`data/workspaces/chat-<sid>/`）。
#' 产物同步出去的那一份在 `data/files/u<N>/<对话文件夹>/` 里，两者是不同的
#' 目录。库里的行没了、盘上的文件还在，于是文件页里那个文件夹永远挂在那儿，
#' 名字还是那个已经被删掉的对话 —— 用户能看见的正是这个。
#'
#' ## 删什么、留什么
#'
#' 判据只有一条：**`ws_published` 里记着的 `dest` 才是这个对话放进去的东西**。
#'
#'   · 自动同步（`dsapp_sync_artifacts`）写的是 `<同步文件夹>/<工作区相对路径>`
#'   · 手动发布（`dsapp_publish_artifact`）写的是文件区**根**下的一个名字
#'   · **目录不写**（同步那支碰到目录只 `dir.create` 就 next，见 files.R）
#'
#' 所以：`dest` 指向的文件删掉 → 删完之后空掉的目录顺手剪掉（产物多半在
#' `results/` 这类子目录里，文件删干净了空壳还在，界面上照样看得见）→
#' 剪完整个同步文件夹都空了才删这个文件夹。
#'
#' ⚠️ 用户**自己**传进那个文件夹里的东西（上传落点是"当前所在的这一层"，
#'    见 mod_files.R 的 `perform_upload`）不在 `ws_published` 里 ⇒ **一律留着**，
#'    文件夹也跟着留下。理由和 `dsapp_entry_delete` 只肯删空文件夹是同一条：
#'    递归删一个目录意味着"我删掉自己的东西，顺手删掉别人放在里面的"。
#'
#' ## 两个必须守住的前提
#'
#' ⚠️ **必须在 `db_session_delete()` 之前调**。两个理由：`ws_published` 的行
#'    那时候还在（db.R 里那句 DELETE 会清掉它），`sessions` 的行也还在
#'    （`dsapp_config_sid()` 才查得到主人）。顺序反了就落到 `_anon` —— 一个
#'    **永远空的**目录（R/config.R:1232 故意的），表现为"一个文件都没删"，
#'    而且**不报错**。
#'
#' ⚠️ **绝不抛异常**。调用方正在删对话，这里任何一步失败都只能记进返回值：
#'    删不掉几个文件不该把"删对话"整个搞挂（同一理由见 `dsapp_ws_delete`）。
#'
#' @param dry 只算不删。删确认弹窗里报的那个数就是它给的 —— 弹窗说的和
#'   真删的**必须是同一把尺子**，否则又是"报 3 个、删 0 个"那种假账。
#' @return list(n = 会删/已删的文件数, dir = 同步文件夹名或 NULL,
#'   removed_dir = 文件夹是否也删掉了, kept = 文件夹里剩下的条目数,
#'   freed = 释放的字节数)
dsapp_session_files_purge <- function(sid, cfg = dsapp_config(), dry = FALSE) {
  out <- list(n = 0L, dir = NULL, removed_dir = FALSE, kept = 0L, freed = 0)
  if (is.null(sid) || !length(sid)) return(out)
  sid <- as.character(sid[[1]])
  if (is.na(sid) || !nzchar(sid)) return(out)

  tryCatch({
    # ⚠️ cfg 要按**对话的主人**重新绑一次：文件区是按账号分的
    #    （data/files/u<N>/），拿一个别人的 cfg 进来会去他自己的区里找 ——
    #    找不到就一个都不删，静默。
    cs  <- dsapp_config_sid(sid, cfg)
    con <- dsapp_db(cfg)
    uid <- dsapp_cfg_uid(cs)

    pubs <- tryCatch(db_ws_pub_map(sid, con = con), error = function(e) NULL)
    # 别的对话也发布过同一个落点时不许动。理论上到不了这里（手动发布走
    # dsapp_unique_path，自动同步一个对话一个文件夹），但"理论上"不是判据。
    others <- tryCatch(DBI::dbGetQuery(con,
      "SELECT DISTINCT dest FROM ws_published WHERE session_id <> ?",
      params = list(sid))$dest, error = function(e) character(0))
    others <- others[!is.na(others) & nzchar(others)]

    # ⚠️ 落点要在**删文件之前**读出来：下面 dry 模式要拿它算 "同步文件夹里
    #    还剩几个"，而那正是弹窗里那个 kept。
    sdir <- tryCatch(db_sync_dir_get(sid, con = con), error = function(e) NULL)
    n_in_dir <- 0L   # 待删的文件里，有几个落在这个同步文件夹内

    if (!is.null(pubs) && nrow(pubs)) {
      for (k in seq_len(nrow(pubs))) {
        d <- as.character(pubs$dest[[k]])
        if (is.na(d) || !nzchar(d) || d %in% others) next
        p <- tryCatch(dsapp_file_path(d, cs, must_exist = FALSE),
                      error = function(e) NULL)
        if (is.null(p)) next
        # 目录交给下面"剪空目录"那一步，这里只认文件（目录本来也不该出现在
        # ws_published 里，真出现了就是有人手改过库）。
        if (isTRUE(file.info(p)$isdir)) next
        if (!file.exists(p)) {
          # 文件早就不在了（用户删过，或者移动过 —— `dsapp_entry_move` 会搬
          # file_owner 的行、**不搬** ws_published.dest，这是一笔已知的旧账）。
          # 顺手把指向空气的归属行清掉，别统计成"删了一个"。
          if (!dry) dsapp_file_owner_drop(d, con = con, user_id = uid)
          next
        }
        sz <- file.info(p)$size
        if (!dry) {
          try(unlink(p, force = TRUE), silent = TRUE)
          # ⚠️ **用 file.exists 复核，不要信 unlink 的返回值** —— 同
          #    dsapp_entry_delete 那段说明：unlink 删不掉时也常常返回 0。
          if (file.exists(p)) next
          dsapp_file_owner_drop(d, con = con, user_id = uid)
        }
        out$n <- out$n + 1L
        if (!is.na(sz)) out$freed <- out$freed + sz
        if (!is.null(sdir) && nzchar(sdir) &&
            (identical(d, sdir) || startsWith(d, paste0(sdir, "/")))) {
          n_in_dir <- n_in_dir + 1L
        }
      }
    }

    # ---- 同步文件夹：剪掉空目录，空了才整个删 ----
    #
    # ⚠️ 这一段**不能**写成 `if (...) return(...)`：`return()` 在
    #    `tryCatch({...})` 的花括号里返回的是**整个函数**，不是那个块 ——
    #    2026-10-08 就是这么写的第一版，早退那一路返回了 NULL 而不是 `out`，
    #    调用方拿到 `NULL$n` = NULL，屏幕上表现为"函数没说话"。
    #    （`tryCatch` 的表达式在调用方的环境里求值，这是 R 的语义。）
    if (!is.null(sdir) && nzchar(sdir)) {
      out$dir <- sdir
      droot <- tryCatch(dsapp_file_path(sdir, cs, must_exist = FALSE),
                        error = function(e) NULL)
      if (!is.null(droot) && dir.exists(droot) && !dsapp_is_link(droot)) {
        if (!dry) {
          # 从**最深**的开始剪。按路径长度降序就够了：子路径一定比父路径长，
          # 所以父目录被检查时子目录已经处理完了，一趟就够。
          subs <- list.dirs(droot, recursive = TRUE, full.names = TRUE)
          subs <- subs[order(nchar(subs), decreasing = TRUE)]
          for (dd in subs) {
            if (identical(normalizePath(dd, mustWork = FALSE),
                          normalizePath(droot, mustWork = FALSE))) next
            if (dsapp_is_link(dd)) next
            if (!length(list.files(dd, all.files = TRUE, no.. = TRUE))) {
              try(file.remove(dd), silent = TRUE)  # file.remove 能删**空**目录
            }
          }
        }

        # dry 也要报 kept —— 弹窗里那句"你自己放进去的会留着"只有真有时才
        # 该出现。dry 模式下文件还没删，所以要把**落在这一支里**的待删文件
        # 减掉（只能减这一支：根上那些手动发布的不在这个文件夹里，一起减掉
        # 就会算出负数，把"还有用户的东西"错报成"什么都没有"）。
        n_left <- length(list.files(droot, recursive = TRUE, all.files = TRUE,
                                    no.. = TRUE))
        if (dry) n_left <- max(0L, n_left - n_in_dir)
        out$kept <- n_left
        if (n_left == 0L) {
          if (dry) {
            out$removed_dir <- TRUE
          } else {
            # ⚠️ 到这一步它已经是空的了，用 file.remove 而不是
            #    `unlink(recursive = TRUE)`：那个会连**非空**目录一起端掉，
            #    正是本函数上面明令不要的动作。空目录删不掉只是留个空壳。
            if (isTRUE(file.remove(droot))) out$removed_dir <- TRUE
          }
        }
      }
    }
  }, error = function(e) NULL)

  out
}

#' 共享区里所有子目录（相对路径），给「移动到…」的下拉用
#'
#' 用 `find -type d` 而不是 `list.dirs(recursive = TRUE)`：后者会跟着目录
#' 软链钻出去（见 dsapp_files_list 的说明），把一个共享区外面的目录列进
#' 下拉里，用户选中之后移动会失败得莫名其妙。find 默认不跟软链。
dsapp_shared_dirs <- function(cfg = dsapp_config()) {
  if (!dir.exists(cfg$files_dir)) return(character(0))
  out <- tryCatch(
    suppressWarnings(system2("find", c(shQuote(cfg$files_dir), "-type", "d"),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  out <- out[nzchar(out)]
  if (!length(out)) return(character(0))

  # ⚠️ `find` 会把**根目录自己**也打出来，而且不带结尾斜杠：
  #        /data/files
  #        /data/files/GSE123
  #    早先这里用 `sub("^<root>/", "", out)` 去前缀，根那一行（没有结尾
  #    斜杠）匹配不上，于是它原样留在结果里 —— 下拉框里就多出一个
  #    「/data/files」的绝对路径选项。用户选中它 = 把文件"移动"到一个
  #    绝对路径上，dsapp_rel_segments 会拒掉，报的还是一句和移动无关的
  #    「目标名字不合法」。根目录**不是**这里该给的选项：它的语义是
  #    「（不移动）」，界面另有专门的「共享区根目录」入口（见 mod_files.R
  #    的 DSAPP_MOVE_ROOT）。
  #
  #    按字符前缀切而不是正则：Linux 路径里 `.` `[` `*` 都合法，
  #    拼进正则就是另一个坑。
  root <- normalizePath(cfg$files_dir, mustWork = TRUE)
  keep <- out == root | startsWith(out, paste0(root, .Platform$file.sep))
  rel <- substring(out[keep], nchar(root) + 1L)
  rel <- sub(paste0("^", .Platform$file.sep), "", rel)
  sort(rel[nzchar(rel) & rel != "."])
}

#' 把共享区镜像进对话工作区：目录建成**真目录**，文件才软链
#'
#' 执行代码之前调用。共享区是只读输入区，工作区是可写产物区，两边在同一个
#' 目录树里共存（模型写 `read.csv("expr.csv")` 时不该关心文件从哪来）。
#'
#' ⚠️ **绝不能把共享区的目录整个软链进来**。软链会穿透写：工作区里的
#'    `GSE123` 要是软链，模型在 `GSE123/` 下新建一个文件，那个文件真的落在
#'    公共共享区里 —— 一个对话就能往所有人的共享区里写东西，"只读输入区"
#'    这个前提当场作废。所以目录一律 dir.create 真建，只有文件用软链
#'    （文件层面有 0444 兜底，见 dsapp_files_protect）。
#'
#' ⚠️ 软链**目录**（共享区里 `loop -> .` 这种）一律跳过，连列都不列。
#'    跟着走会无限展开（`find`/`list.files` 都会，只是方式不同），而且
#'    软链可以指向共享区外面 —— 那样工作区里就凭空多出一棵完全不受
#'    权限约束的树。跳过它们比"检查目标在不在共享区里"更省事也更安全。
#'
#' 已存在的名字**不覆盖**：工作区里第 1 轮产出的 expr.csv 优先于共享区的
#' 同名文件。反过来做的话，模型第二轮读到的会是用户最初上传的那份，而它
#' 明明刚写过一份新的 —— 这种错很难看出来。
#'
#' @param max_depth 层级上限。共享区是给人用的，8 层足够；真出现更深的，
#'   如实报给模型（见返回值），而不是假装挂全了。
#' @return list(linked, dirs, deep) —— deep 是因超深被跳过的目录数
dsapp_mirror_shared <- function(src_root, dest_root, max_depth = 8L) {
  st <- list(linked = 0L, dirs = 0L, deep = 0L)
  if (!dir.exists(src_root) || !dir.exists(dest_root)) return(st)

  walk <- function(src, dest, depth) {
    items <- list.files(src, all.files = FALSE, no.. = TRUE)
    if (!length(items)) return(invisible(NULL))
    for (it in items) {
      s <- file.path(src, it)
      d <- file.path(dest, it)
      if (dsapp_is_link(s)) next              # 软链目录：跳过（见上面 ⚠️）
      if (dir.exists(s)) {
        if (depth >= max_depth) { st$deep <<- st$deep + 1L; next }
        if (!dir.exists(d)) {
          if (!dir.create(d, showWarnings = FALSE)) next
          st$dirs <<- st$dirs + 1L
        } else if (dsapp_is_link(d)) {
          next                                # 工作区里同名的软链目录，不碰
        }
        walk(s, d, depth + 1L)
        next
      }
      # ---- 只读保护 ----
      #
      # 这是**唯一**能在"文件马上就要被软链进工作区"的那一刻保证这条
      # 不变式的地方。上传和发布两个写入点已经各自 chmod 过一次
      # （dsapp_files_protect），但那不是保证：管理员 scp 进来一份参考
      # 数据、从 git checkout 出来一个脚本、或者别处拷过来的文件，谁都
      # 没给它设过只读 —— 而它一样会被软链进工作区，一样会被一句
      # write.csv(df, "top.txt") 静默覆盖掉。丢的是原始数据。
      #
      # ⚠️ 只在**确实可写**时才 chmod。绝大多数文件上传时就已经是 0444，
      #    在这里一次 stat 就跳过了，不会反复去改整个目录 —— 那正是 V2
      #    那版"每次执行 chmod 一遍全局共享区"的问题（任务在写全局状态，
      #    而且只在自己要跑的时候才写）。
      if (file.access(s, 2L) == 0L) dsapp_files_protect(s)

      # 已存在就跳过。file.exists 对**断掉的软链**返回 FALSE，所以还要单独
      # 看一眼是不是链接 —— 否则会对一个已经存在的链接再 symlink 一次，
      # 失败（EEXIST）被 silent 吞掉，看着像"挂上了"其实没有。
      if (file.exists(d) || dsapp_is_link(d)) next
      # ⚠️ 不要在这里直接写 file.symlink：Windows 上普通用户建不了软链，
      #    而失败是静默的 —— 工作目录里少一个输入文件，模型看到的是
      #    "文件不存在"。dsapp_place_input 会降级成复制（见 platform.R）。
      if (isTRUE(dsapp_place_input(s, d))) st$linked <<- st$linked + 1L
    }
    invisible(NULL)
  }
  walk(src_root, dest_root, 1L)
  st
}

#' 清掉工作区里指向共享区的**断链**
#'
#' 共享区里的文件被删掉之后，工作区里那条软链会悬空。不管它的话：
#'   * `dsapp_ws_artifacts()` 会把它当成一个 0 字节的产物列出来
#'   * 模型 `read.csv()` 它得到 "No such file"，而文件清单里明明写着有
#'   * 用户在一个不存在的文件上点「发布」
#' 断链没有任何用处，删掉它是安全的（unlink 一个软链删的是链，不是目标）。
#'
#' ⚠️ 只删**链、且指向共享区**的那些。模型自己 `ln -s` 出来的符号链接可能
#'    指向工作区里的另一个文件（哪怕是断的，也可能是在等下一步生成），
#'    那不是我们的地盘，不碰。
dsapp_ws_prune_links <- function(workdir, cfg = dsapp_config()) {
  if (!dir.exists(workdir) || !dir.exists(cfg$files_dir)) return(invisible(0L))
  root <- normalizePath(cfg$files_dir, mustWork = TRUE)
  links <- tryCatch(
    suppressWarnings(system2("find", c(shQuote(workdir), "-type", "l"),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  links <- links[nzchar(links)]
  if (!length(links)) return(invisible(0L))

  n <- 0L
  for (p in links) {
    tgt <- Sys.readlink(p)
    if (is.na(tgt) || !nzchar(tgt)) next
    if (!startsWith(tgt, root)) next          # 不是我们挂的，别动
    if (file.exists(p)) next                  # 目标还在，留着
    if (isTRUE(file.remove(p))) n <- n + 1L
  }
  invisible(n)
}

#' 共享区里的文件总数与总大小（递归，不跟软链）
#'
#' 给管理页和配额用。用 `find -type f` 而不是 list.files(recursive = TRUE)：
#' 后者会跟着目录软链无限展开（见 dsapp_files_list 的说明）。
#'
#' ★ V13.10 item 2：**点开头的路径一律不算**（`-not -path '*/.*'`）。
#'
#'   用户的原话是「每个用户生成的文件都归自己所有，为什么会产生无归属
#'   文件？」。查下来生产库里恰好有一行无归属记录，名字是 `.migrated_v13`
#'   —— 那是 `dsapp_files_migrate()` 自己落的迁移标记（0 字节），**不是
#'   用户的文件**。它是被这个函数扫进去的：`find -type f` 把点文件也算
#'   文件，而 V12 那版 `dsapp_files_sync_owners()` 拿到什么就登记什么、
#'   且当时登记出来的归属人是 NULL（V13 之前 `_anon` 就是"公共"）。
#'   于是平台自己的一个小标记，在管理页上变成了"有个文件没人认领、
#'   谁都能删"。
#'
#'   ⚠️ 在**扫描这一层**挡，而不是在登记那一层挡。登记那层挡的话，换个
#'      调用方（配额统计、prompts.R 的文件清单、executor.R 的共享区判定）
#'      就又漏了 —— 而这个函数是"共享区里有哪些文件"的唯一定义处。
#'      `.DS_Store`、`.Rhistory`、编辑器存的 `.foo.csv.swp`、`~$xx.xlsx`
#'      这一类也都该一起挡掉，它们的共同点就是"不是用户放的东西"。
#'
#'   ⚠️ 用 `-not -path '*/.*'` 而不是 `! -name '.*'`：后者只挡文件名本身
#'      点开头的，`u1/.cache/foo.csv` 这种**藏在一个点目录里**的照样漏进来。
dsapp_shared_scan <- function(cfg = dsapp_config()) {
  if (!dir.exists(cfg$files_dir)) {
    return(list(files = character(0), bytes = 0))
  }
  # ⚠️ `shQuote("*/.*")` 的那对引号**不是多余的**，去掉就坏。system2 底下
  #    走的是 `sh -c`，不引起来的话 `*/.*` 会被 shell 先拿当前目录做一次
  #    通配展开 —— 展开结果取决于**进程的工作目录**（通常是项目根，里面有
  #    `data`、`tests` 这些），于是 find 收到的是一串莫名其妙的目录名，
  #    报 `paths must precede expression` 并返回 status 1、零输出。
  #    而零输出的表现是"共享区里一个文件都没有" —— 不报错、只是空的，
  #    配额永远显示 0、补登记永远补不出东西。实测就是这么坏的。
  out <- tryCatch(
    suppressWarnings(system2("find",
                             c(shQuote(cfg$files_dir), "-type", "f",
                               "-not", "-path", shQuote("*/.*")),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  out <- out[nzchar(out)]
  if (!length(out)) return(list(files = character(0), bytes = 0))
  prefix <- paste0(normalizePath(cfg$files_dir, mustWork = TRUE),
                   .Platform$file.sep)
  rel <- sub(paste0("^", prefix), "", out)
  list(files = rel, bytes = sum(file.size(out), na.rm = TRUE))
}

#' 清掉归属表里"指向平台自己那些点文件"的行（V13.10 item 2）
#'
#' `dsapp_shared_scan()` 从这一版起不再扫点文件，但**表里已经写进去的那些
#' 不会自己消失** —— 生产库里就留着 `.migrated_v13` 那一行，管理页据此
#' 一直在报"有 N 个文件没有归属"，而那个文件根本不是用户的。
#'
#' ⚠️ 判据只认**路径里有没有点开头的段**，不去猜"这个文件还在不在"。
#'    猜存在性的话，磁盘临时没挂上、或者用户正好在两次扫描之间改了名，
#'    就会把**真文件**的归属行删掉 —— 按 dsapp_file_can_edit 的规则，
#'    无主 = 人人可删，等于把别人的文件公开了。删错点文件的代价是零
#'    （它们本来就不该在表里），删错真文件的代价是权限失控，两者不对称。
#'
#' @return 删掉的行数
dsapp_files_purge_dotfiles <- function(con = dsapp_db(), cfg = dsapp_config()) {
  # ⚠️ SQL 里没法直接表达"任意一段以点开头"，所以拉回来在 R 里判。
  #    这张表是"每个文件一行"（生产环境百来行），全量拉不心疼；
  #    真涨到几万行时该改的是这张表的设计，不是在这里加 LIMIT 猜。
  nm <- tryCatch(DBI::dbGetQuery(con, "SELECT name FROM file_owner")$name,
                 error = function(e) character(0))
  if (!length(nm)) return(invisible(0L))
  seg <- strsplit(nm, "/", fixed = TRUE)
  bad <- vapply(seg, function(s) any(startsWith(s, ".")), logical(1))
  bad[is.na(bad)] <- FALSE
  if (!any(bad)) return(invisible(0L))
  n <- 0L
  for (k in nm[bad]) {
    n <- n + tryCatch(DBI::dbExecute(con,
      "DELETE FROM file_owner WHERE name = ?", params = list(k)),
      error = function(e) 0L)
  }
  as.integer(n)
}

# ---- 预览的两条硬指标（V11 item 11）---------------------------------------
#
# 用户原话：「文件预览只显示前 512KB 是不行的，文本格式可以只显示前 20 行，
# html 文件应该显示完全，小于 20MB 在线预览都可以」。
#
# ⚠️ 20MB 是**在线预览**的上限，不是下载的上限 —— 下载那条路不受影响。
#    定这个数是因为超过它之后，读进内存 + 塞给浏览器这一套会让页面明显卡住，
#    而"卡住"比"不给预览"更让人以为程序坏了。
DSAPP_PREVIEW_MAX_BYTES <- 20 * 1024^2

# 文本文件只显示前这么多行。**不用字节数** —— 用户要看的是"这文件长什么样"，
# 而一行有多长跟信息量无关；按字节切会把一行从中间劈开，看着像文件坏了。
DSAPP_PREVIEW_LINES <- 20L

# 产物坐标的前缀，认它的是 dsapp_art_path()（见上面那段说明）。
#
# ⚠️ 用 `files:` 而不是 `/` 或者 `~`：这条串会**穿进 DOM 属性、再穿回来**
#    （onclick 里是个 JS 字符串字面量），带 `/` 开头会让它看起来像一个绝对
#    路径，将来谁顺手加一句 file.exists() 就会在根目录下找。冒号在 Linux 的
#    文件名里合法但罕见，撞上真实文件名的概率可以忽略。
DSAPP_ART_FILES_PREFIX <- "files:"

#' 文件预览用的 MIME
dsapp_preview_mime <- function(name, kind = dsapp_file_kind(name)) {
  ext <- tolower(tools::file_ext(name))
  if (kind == "html") return("text/html; charset=utf-8")
  if (kind == "markdown") return("text/plain; charset=utf-8")
  if (kind == "pdf") return("application/pdf")
  if (kind == "image") return(dsapp_image_mime(name))
  if (ext %in% c("json")) return("application/json; charset=utf-8")
  if (ext %in% c("xml")) return("text/xml; charset=utf-8")
  "text/plain; charset=utf-8"
}

#' 给一个本地文件生成能在 `<iframe>` / `<img>` / 下载里直接用的 URL
#'
#' @param session Shiny session。**现在必须给**（V13 item 6 起）
#' @return URL 字符串，或 NULL（给不出可用地址时）
#'
#' -----------------------------------------------------------------------------
#' ★ V13 item 6：**静态路由那条路没了**，一律走 registerDataObj
#' -----------------------------------------------------------------------------
#' 以前这里分两条路：管理区（files/）走 addResourcePath 挂在全局静态路由上，
#' 工作区走 session$registerDataObj。当时那个分法是对的 —— 管理区"本来就是
#' 所有人共用的"，再挂一次静态路由不会多泄露什么。
#'
#' 现在管理区**按账号隔离**了（见本文件顶部的说明），那句话就不成立了：
#' 静态路由是**进程级**的，`/files/<相对路径>` 对任何登录用户都成立，换个
#' 账号把路径一改就能下载别人的文件 —— 而界面上一切正常，只有知道 URL 的
#' 人看得出来。所以这条路整个去掉：两个地方都走 registerDataObj，地址形如
#' `session/<token>/dataobj/<name>?w=..&nonce=..`，带会话 token 和一次性
#' nonce，**只有本会话自己知道**。
#'
#' ⚠️ 连带 effect：app.R 里那句 `addResourcePath("files", cfg$files_dir)` 也
#'    删了。它原来指的是全局 cfg 的 files_dir，改成按账号之后那里是 _anon
#'    （一个空目录）—— 留着它只会让人以为"管理区是挂出去的"，哪天有人照着
#'    它写一句新的就走了老路。
#'
#' ⚠️ 不能用 `session$fileUrl()` 代替 —— 它是把整个文件 base64 成一个
#'    `data:` URL 塞进 href 的（见 shiny 的实现）。几十 KB 的缩略图没问题，
#'    20MB 的 HTML 会变成一个 27MB 的字符串，浏览器直接卡死。
dsapp_preview_url <- function(session, path, mime = NULL, cfg = dsapp_config()) {
  # ★ V15.6 item 9：`path` 零长度或长度 >1 时，下面那句 `!file.exists(path)`
  #   不是返回 FALSE，是**抛错**（`missing value where TRUE/FALSE needed` /
  #   `'length = 2' in coercion to 'logical(1)'`）。目前只靠每个调用方先
  #   自己 is.null() 兜着 —— 那是"每处各自记得"的约定，迟早有人忘，而症状
  #   是预览整块炸成"An error has occurred"（看不出跟哪个文件有关）。
  #   同族的坑本仓踩过：`paste0("files:", character(0))` 会变成 1 个元素。
  if (length(path) != 1L || is.na(path)) return(NULL)
  if (is.null(path) || !file.exists(path)) return(NULL)
  # ★ V13 item 6：`session` 从"可选"变成了**必需** —— 静态路由那条路没了，
  #   没有 session 就发不出 dataobj 地址。传 NULL 现在是返回 NULL（调用方
  #   显示"无法预览"），而不是悄悄降级到一条谁都能访问的 URL。
  if (is.null(session)) return(NULL)
  if (is.null(mime)) mime <- dsapp_preview_mime(basename(path))

  np <- tryCatch(normalizePath(path, mustWork = FALSE), error = function(e) NULL)
  # ⚠️ 一条历史：静态路由**发不出去响应头**（addResourcePath 没地方挂），
  #    于是就没有下面那条 CSP sandbox。iframe 上的 sandbox 属性只护得住
  #    "在预览框里看"这一种打开方式；用户把地址复制到新标签页打开时，文档
  #    就回到了本应用的源上，脚本能带 cookie 去打本站的任何接口。管理区是
  #    用户自己能写的 —— 也就是说那会变成一条"上传一个 html 就能接管自己
  #    账号"的路（在共用区时代是"接管**别人**账号"）。
  #
  #    V13 item 6 之后静态路由整个没了（见函数头），但这段说明留着：它解释的
  #    是**下面那些响应头为什么必须一条不少**，而这跟走哪条路无关。
  #
  #    代价：非自包含的报告（saveWidget(selfcontained = FALSE)、
  #    rmarkdown 关掉 self_contained）拿不到同目录的 report_files/ 资源，
  #    样式会缺。这个代价是明摆着的、可见的，比一个静默的 XSS 入口便宜。
  #    调用方（mod_files.R）会额外提示一句。
  key <- tryCatch(digest::digest(paste0(np, "|", mime), algo = "md5",
                                 serialize = FALSE),
                  error = function(e) NULL)
  if (is.null(key)) key <- as.character(abs(sum(utf8ToInt(basename(path)))))
  session$registerDataObj(
    paste0("pv-", substr(key, 1, 12)),
    # `inline` 是给下面那个处理器看的开关，不是给调用方的参数 —— 只有
    # HTML 需要"读进来改一遍再发"（见处理器里 ★★ V14 item 4 那一段）。
    list(path = np, mime = mime, inline = grepl("^text/html", mime)),
    function(data, req) {
      sz <- tryCatch(file.info(data$path)$size, error = function(e) NA)
      if (is.na(sz)) {
        return(list(status = 404L,
                    headers = list(`Content-Type` = "text/plain; charset=utf-8"),
                    body = charToRaw("文件不存在")))
      }
      # ★★ V15.6 item 15：0 字节 = **这个文件还没写完**（跑着的任务正在往
      #    里写，而工作区的产物是实时进列表的）。
      #
      #    以前这里会走到 200 + 空 body：<img> 拿到一个空响应，渲染成一张
      #    碎图 —— 不报错、也没有任何提示，用户看到的就是"图片裂了，等一会
      #    又好了"。归到 500 之后，前端那颗 <img> 的 error 处理器会自己重试
      #   三次（见 www/app.js 的"预览图片"那一段），文件写完的那一次就成了。
      #    ⚠️ 文案对"真就是个空文件"同样成立，不要写成"加载失败"。
      #    （`is.na(sz)` 那一种已经在上面按 404 返回了，这里只管 0。）
      if (sz <= 0) {
        return(list(status = 500L,
                    headers = list(`Content-Type` = "text/plain; charset=utf-8"),
                    body = charToRaw("这个文件是空的（0 字节）")))
      }
      b <- tryCatch(readBin(data$path, "raw", n = sz), error = function(e) NULL)
      # ⚠️ 读出来的字节数**少于** file.info 报的大小 = 读的过程中文件被改了
      #    （截断重写）。半个 PNG 解码不出来，症状和上面那条一样。
      #    同样交给前端重试，不在这里循环重读（单进程 Shiny，重读要占住
      #    所有人的请求路径）。
      if (is.null(b) || length(b) < sz) {
        return(list(status = 500L,
                    headers = list(`Content-Type` = "text/plain; charset=utf-8"),
                    body = charToRaw("读取失败（文件可能正在被写入）")))
      }
      # ★★ V14 item 4：HTML 走出去了要**先把图片内联进来**再发。
      #
      #    这是 "报告预览时图片是裂的" 那个 bug 的正解。原因写在文件下半部分
      #    `dsapp_html_inline` 那一大段里，一句话版：这个文档的基地址是
      #    `/session/<token>/dataobj/`，报告里写的 `figures/a.png` 被解析到
      #    那个路由下，而它只认注册过的 `pv-<hash>`，于是每一张图都是 404。
      #
      #    ⚠️ 放在**服务端**而不是"预览时让前端去拼地址"：报告是用户已经
      #       生成好的东西，改前端只能救新报告；老报告（用户正在抱怨的那份）
      #       必须在这里救。这就是 item 4 和 item 3 分开列、却用同一段代码
      #       修的原因。
      #
      #    ⚠️ 内联**失败**（读不了、图太大、base64 出错）时一律退回原文 ——
      #       宁可是几张裂图，也不能让整个预览变成"无法读取该文件"：
      #       后者会让用户以为报告坏了，而它其实好好的。
      if (isTRUE(data$inline)) {
        r <- tryCatch(
          dsapp_html_read_inlined(data$path, dirname(data$path),
                                  max_total = DSAPP_HTML_PREVIEW_INLINE_MAX),
          error = function(e) NULL)
        if (!is.null(r) && isTRUE(r$ok) && !is.null(r$html) && nzchar(r$html)) {
          b <- charToRaw(enc2utf8(r$html))
        }
      }
      hdr <- list(`Content-Type` = data$mime,
                  `Content-Disposition` = "inline",
                  # 别让浏览器"猜"类型：一个叫 report.png 的 HTML 会被当成
                  # 图片以外的类型执行，这正是 nosniff 要挡的。
                  `X-Content-Type-Options` = "nosniff")
      # ⚠️ HTML 预览必须带 CSP sandbox。iframe 上的 sandbox 属性只在这一层
      #    生效；用户把地址复制到新标签页打开时就没有 iframe 了，那时**只有
      #    这个响应头**能拦住脚本读本应用的 cookie。allow-scripts 但**不给**
      #    allow-same-origin ⇒ 文档处在一个不透明源里，脚本能跑（报告里的
      #    plotly 之类还能用），但碰不到本应用的 DOM / cookie / localStorage。
      if (grepl("^text/html", data$mime)) {
        hdr[["Content-Security-Policy"]] <- "sandbox allow-scripts allow-popups"
      }
      # ★ Test_V15.3 item 6：SVG 也要。SVG 是**能装脚本的文档**，不是纯图片 ——
      #   用 <img> 嵌的时候浏览器不跑它的脚本，但用户右键"在新标签页打开图片"
      #   就没人在挡了：文档回到本应用的源上，脚本能读 cookie / localStorage。
      #
      #   ⚠️ 不给 allow-scripts：SVG 图里没有需要跑脚本才能显示的东西（和
      #      HTML 报告不同，那边的 plotly 之类是真要跑的）。sandbox 不给
      #      allow-scripts 时脚本一律不执行，而图该显示还是显示。
      #   ⚠️ 也不给 allow-same-origin ⇒ 不透明源，碰不到本应用的任何东西。
      #
      #   这不是 item 6 新开的口子，是**顺手补上的一处旧口子**：工作区里的
      #   .svg 在「文件」页一直是可以这样打开的。现在聊天正文里的
      #   `![](fig.png)` 会生成同一类地址，正好一并收口。
      if (grepl("^image/svg", data$mime)) {
        hdr[["Content-Security-Policy"]] <- "sandbox"
      }
      list(status = 200L, headers = hdr, body = b)
    })
}

#' 给预览地址挂一个"版本号"（★ V15.6 item 9）
#'
#' `dsapp_preview_url()` 发出来的地址是**稳定的**：`pv-<md5(路径|类型)>`。
#' 于是同一个文件被覆盖写之后（重跑一次任务、报告重新生成），浏览器很可能
#' 拿缓存里那份旧的渲染出来 —— 用户看到的是**上一版**的报告/图片，而界面
#' 上没有任何异常。对话页那两条路早就带了 `?v=`（见 mod_chat.R 里
#' `art_preview_ui` 那一段），文件页这三条一直没带。
#'
#' @return 带版本号的 URL；拿不到 mtime 时原样返回（宁可吃缓存，也不能因为
#'   一个 file.info 失败就让预览整个打不开）。
dsapp_preview_url_v <- function(url, path) {
  if (is.null(url) || !length(url)) return(url)
  mt <- tryCatch(as.numeric(file.info(path)$mtime), error = function(e) NA_real_)
  if (!length(mt) || !is.finite(mt[1])) return(url)
  paste0(url, if (grepl("?", url, fixed = TRUE)) "&" else "?",
         "v=", sprintf("%.0f", mt[1]))
}

#' 读一个文本文件的前 n 行（预览用）
#'
#' 用 `readLines(n=)` 而不是 `readLines()` 再 `head()` —— 后者会把整个文件
#' 读进内存，而预览一个 2GB 的日志正是要避免这件事。readLines 的 n 参数
#' 在 C 层就停住了。
#'
#' @return list(lines = 字符向量, truncated = 是否还有更多行)
dsapp_preview_head <- function(path, n = DSAPP_PREVIEW_LINES) {
  if (is.null(path) || !file.exists(path)) {
    return(list(lines = character(0), truncated = FALSE))
  }
  # ⚠️ 有些日志是 CRLF 或纯 \r 结尾的老格式，r 模式在 Linux 上不转会留下 \r，
  #    显示时看不出问题，但用户一复制就带一串控制字符。
  ls <- tryCatch(readLines(path, n = n + 1L, warn = FALSE, skipNul = TRUE),
                 error = function(e) character(0))
  more <- length(ls) > n
  if (more) ls <- ls[seq_len(n)]
  # ⚠️ 这里**不**去数总行数。数它就得把整个文件读一遍，而"不读整个文件"
  #    正是这个函数存在的理由 —— 预览一个几 GB 的日志时，为了在标题上写
  #    "共 3,812,004 行"而把它全读进来，是本末倒置。
  list(lines = sub("\r$", "", ls), truncated = more)
}

#' 读一个文本文件的**全部**内容（Markdown / 报告预览用）
#'
#' ★ V13.12 item 9：用户原话「md 报告和 html 报告可以全部渲染，不用只预览
#'   前 20 行」。
#'
#' ⚠️ `DSAPP_PREVIEW_LINES`（20 行）**继续留着**，但它现在只服务"看一眼这
#'    文件长什么样"的**源码 / 日志**预览。报告是另一回事：用户是**读它**的，
#'    截断等于没给 —— 一份 300 行的分析报告只渲出前 20 行，用户会以为报告
#'    本身就只有这么点内容，而不是以为"预览被截了"。
#'
#' ⚠️ 仍然有一道**字节**闸（DSAPP_PREVIEW_MAX_BYTES，20MB）兜底，超了就退回
#'    读开头 20 行并**如实标出** truncated。那道闸和在线预览的上限同源，防的
#'    是"页面卡死"，不是"内容太多"—— 顺带也挡住了"把 2GB 的 .md 读进内存
#'    把 Shiny 进程撑死"这条自伤路径。
#'
#' @return list(text = 单个字符串, truncated = 是否被截, bytes = 文件大小)
dsapp_preview_full <- function(path, max_bytes = DSAPP_PREVIEW_MAX_BYTES) {
  fallback <- function(trunc) {
    h <- dsapp_preview_head(path, DSAPP_PREVIEW_LINES)
    list(text = paste(h$lines, collapse = "\n"),
         truncated = isTRUE(trunc) || isTRUE(h$truncated),
         bytes = suppressWarnings(as.numeric(file.info(path)$size %||% 0)))
  }
  if (is.null(path) || !file.exists(path)) {
    return(list(text = "", truncated = FALSE, bytes = 0))
  }
  sz <- suppressWarnings(as.numeric(file.info(path)$size))
  if (is.na(sz)) return(list(text = "", truncated = FALSE, bytes = 0))
  if (sz > max_bytes) return(fallback(TRUE))

  # skipNul / 去 \r 的理由和 dsapp_preview_head 那边一样（见上）。
  ls <- tryCatch(readLines(path, warn = FALSE, skipNul = TRUE),
                 error = function(e) NULL)
  if (is.null(ls)) return(fallback(TRUE))
  list(text = paste(sub("\r$", "", ls), collapse = "\n"),
       truncated = FALSE, bytes = sz)
}

#' 判断文件类型，决定用哪种方式预览
dsapp_file_kind <- function(name) {
  ext <- tolower(tools::file_ext(name))
  if (ext %in% c("png", "jpg", "jpeg", "gif", "bmp", "webp", "svg")) return("image")
  if (ext %in% c("pdf")) return("pdf")
  if (ext %in% c("csv", "tsv", "txt")) {
    # txt 也可能是表格，但先按文本处理更稳（不假设分隔符）
    if (ext %in% c("csv", "tsv")) return("table")
    return("text")
  }
  # V11 item 1：html / markdown 从 text 里**分出来**。
  # 以前它们都走 text 分支 = dsapp_escape 之后当源码显示，用户看到的是
  # 一堆 <div> 和 ## —— 而这两种格式"预览"的意思就是**渲染出来**。
  if (ext %in% c("html", "htm")) return("html")
  # Rmd / qmd 就是 Markdown（本来也是给用户看源文件的，渲染出来最直观）
  if (ext %in% c("md", "markdown", "rmd", "qmd")) return("markdown")
  if (ext %in% c("r", "py", "sh", "bash", "json", "yaml", "yml",
                 "log", "out", "err", "xml", "css", "js")) return("text")
  # 压缩包单独一类：预览面板要给它一个「解压」按钮，而不是一句"下载下来
  # 自己解"。注意判据是**整个文件名**的规则（`x.tar.gz` 的 file_ext 是
  # "gz"，只看扩展名会和普通 .gz 混在一起）。
  if (!is.na(dsapp_archive_kind(name))) return("archive")
  if (ext %in% c("rds", "rdata", "h5ad", "h5", "hdf5", "bam", "sam",
                 "vcf", "gz", "zip", "tar", "bed", "gtf", "gff", "fasta",
                 "fa", "fq", "fastq")) return("binary")
  "other"
}

#' 图片的 MIME 类型
#'
#' 给 renderImage 用。**不能**省掉让它自己猜：猜错的后果不是报错，是浏览器
#' 把图片当成二进制流下载下来 —— 在对话里就是一块空白，什么提示都没有。
#' svg 尤其要写死：它的 MIME 是 image/svg+xml，按扩展名拼出来的
#' "image/svg" 是不认的。
dsapp_image_mime <- function(name) {
  switch(tolower(tools::file_ext(name)),
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    gif  = "image/gif",
    bmp  = "image/bmp",
    webp = "image/webp",
    svg  = "image/svg+xml",
    "application/octet-stream")
}

#' 缩略图的大小上限
#'
#' ⚠️ 这个上限是**给服务器自己**留的，不是给用户省流量：Shiny 的
#'    `session$fileUrl()` 是把整个文件 `readBin()` 读进内存再 base64 之后
#'    塞进 URL 的（见 shiny 的 ShinySession$fileUrl，没有大小阈值这回事）。
#'    也就是说每画一张缩略图，主进程就要多背一份完整图片 + 1.33 倍的
#'    base64 字符串。而本站是 Shiny Server 开源版 —— 一个应用一个 R 进程、
#'    所有访客共用，300 dpi 存出来的一张图上十兆，几个人同时刷就能把这个
#'    进程顶爆，炸的是**别人**的会话。
#'    正常的火山图/UMAP 在 200 KB ~ 2 MB，4 MB 足够覆盖真实用法；
#'    超过的照旧能下载，只是不给缩略图。
DSAPP_THUMB_MAX_BYTES <- 4 * 1024^2

#' 挑出要出缩略图的图
#'
#' UI 和 renderImage 的渲染函数**必须**都调这一个函数。两边各写一遍筛选
#' 条件，改了一边漏了另一边，表现是界面上一个空的缩略图框 —— 不报错，
#' 只是什么都不显示，最难查的那类问题。
dsapp_thumb_pick <- function(df, n_max = 4L) {
  if (is.null(df) || !nrow(df)) return(character(0))
  if (!all(c("name", "kind", "size") %in% names(df))) return(character(0))
  ok <- !is.na(df$kind) & df$kind == "image" &
        !is.na(df$size) & df$size <= DSAPP_THUMB_MAX_BYTES
  utils::head(df$name[ok], n_max)
}

#' 因为太大而没出缩略图的图（界面要如实说一句，不然用户以为没生成）
dsapp_thumb_too_big <- function(df) {
  if (is.null(df) || !nrow(df)) return(character(0))
  if (!all(c("name", "kind", "size") %in% names(df))) return(character(0))
  df$name[!is.na(df$kind) & df$kind == "image" &
          !is.na(df$size) & df$size > DSAPP_THUMB_MAX_BYTES]
}

#' 某一层**往下**所有图片，按修改时间从新到旧
#'
#' ★ V15.4 item 2。用户原话：「在我多轮对话出结果后，并没有在言出法随的
#' 文件预览界面同步」。
#'
#' 探索之后发现，那一格**本身是在刷新的**（3 秒轮询，摘要递归，见
#' mod_chat.R 的 art_files），真正让用户觉得"没同步"的是**看得见的东西**：
#' 那张卡片列的是**当前这一层**，而任务产物几乎总是落在模型自己新建的一个
#' 项目文件夹里（`绘制国旗-4666/five_star_flag_python/data/figures/*.png`）。
#' 于是用户盯着的那一格从始至终只有一行「📁 five_star_flag_python」，
#' 图一张都不出来 —— 他不点进去就永远看不到自己刚跑出来的东西，而
#' "要不要点进去看一眼"这件事对他是不可见的：那一行看起来和"什么都没有"
#' 差不多。
#'
#' 所以缩略图**穿透子目录**（列表仍然是当前层，只有图穿透）。这样根上
#' 就能看见整段对话最新的几张产出，点开就是那张图；要看全的、要下载的，
#' 点进文件夹或者去「文件」页。
#'
#' ⚠️ 递归扫描本身**不是新增开销**：art_files 的 checkFunc 每 3 秒已经在
#'    同一个目录上跑一次 dsapp_ws_snapshot(dirs = TRUE)。这里多跑一次
#'    非递归的那一支，代价是几次 stat。
#' ⚠️ `cap` 是防呆不是节流：文件区是工作区的镜像，真有人往对话目录里倒
#'    几万张图的话，file.info() 会把一次渲染拖到几百毫秒。到顶了就按
#'    find 的顺序（路径字典序）截断，**不**保证截到的是最新的 —— 这是
#'    兜底路径，正常用量根本碰不到，要说的是"宁可少画几张，也不能把
#'    页面卡住"。
#' ⚠️ 返回的 `name` 在有重名（`results/plot.png` 和 `figures/plot.png`）
#'    时会退化成相对路径。理由：调用方拿 `name` 回头 `match()` 出 `rel`，
#'    而重名会让 match 静默指到**另一个文件**上 —— 点缩略图看到的是别的
#'    图，且没有任何报错。宁可把标题显示长一点。
dsapp_art_tree_images <- function(root, n_max = 4L, cap = 2000L) {
  empty <- data.frame(name = character(0), rel = character(0),
                      kind = character(0), size = numeric(0),
                      stringsAsFactors = FALSE)
  if (is.null(root) || !length(root) || is.na(root) || !dir.exists(root)) {
    return(empty)
  }
  fs <- tryCatch(dsapp_ws_snapshot(root, dirs = FALSE),
                 error = function(e) character(0))
  if (!length(fs)) return(empty)
  # 先按后缀筛一刀再 stat：目录里绝大部分是 .json/.ipynb/.py，不筛的话
  # 每一次渲染都要为几十个和缩略图无关的文件跑一次 file.info()。
  keep <- tolower(tools::file_ext(fs)) %in%
    c("png", "jpg", "jpeg", "gif", "bmp", "webp", "svg")
  fs <- fs[keep]
  if (!length(fs)) return(empty)
  if (length(fs) > cap) fs <- utils::head(fs, cap)

  info <- file.info(file.path(root, fs))
  ok <- !is.na(info$size)
  fs <- fs[ok]; info <- info[ok, , drop = FALSE]
  if (!length(fs)) return(empty)

  nm <- basename(fs)
  dup <- duplicated(nm) | duplicated(nm, fromLast = TRUE)
  nm[dup] <- fs[dup]
  df <- data.frame(
    name   = nm,
    rel    = fs,
    # kind 用**完整相对路径**判：dsapp_file_kind() 认的是扩展名，两者结果
    # 一样，但传完整路径可以避免"名字里恰好带点号"那类边角情况。
    kind   = vapply(fs, dsapp_file_kind, character(1)),
    size   = as.numeric(info$size),
    mtime  = as.numeric(info$mtime),
    stringsAsFactors = FALSE)
  df <- df[order(-df$mtime, df$rel), , drop = FALSE]
  utils::head(df, n_max)
}

#' 读取表格预览
#'
#' 只读前 n 行。有些表达矩阵是几万行 × 几万列，整个读进来 R 进程直接 OOM。
dsapp_preview_table <- function(path, n = 100) {
  ext <- tolower(tools::file_ext(path))
  sep <- if (ext == "tsv") "\t" else ","

  df <- tryCatch(
    utils::read.table(path, sep = sep, header = TRUE, nrows = n,
                      check.names = FALSE, quote = "\"",
                      comment.char = "", stringsAsFactors = FALSE,
                      fileEncoding = "UTF-8"),
    error = function(e) NULL
  )

  if (is.null(df)) {
    # 分隔符猜错了很常见（.txt 改成 .csv、分号分隔的欧洲格式），
    # 退一步用 read.csv 的自动嗅探再试一次
    df <- tryCatch(
      utils::read.csv(path, header = TRUE, nrows = n, check.names = FALSE,
                      stringsAsFactors = FALSE),
      error = function(e) NULL
    )
  }
  dsapp_preview_fix_names(df)
}

#' 把预览用的列名补成 DT 能吃的样子（V13.2 item 10）
#'
#' 用户报的错是：
#'
#'     Error in if (!searchable[j]) next: argument is length zero
#'
#' ⚠️ 这个错**不在我们的代码里**，是 DT 服务端过滤那一层的：
#'    `DT:::dataTablesFilter` 里按请求里的列名建 `imap`，列名为空串时
#'    该位置记成 `0`，接着 `searchable[0]` 取出来是 `logical(0)`，
#'    于是 `if (!logical(0))` 报 "argument is of length zero"。
#'    也就是说：**只要有一个列的列名是空串，表格预览就整个报错**，
#'    而且报的是一个和"列名"毫无关系的错。
#'
#' ⚠️ 空列名从哪来的：上面读文件用的是 `check.names = FALSE`（那个必须留着，
#'    否则 `read.table` 会把 `gene name` 改成 `gene.name`，用户对不上自己的
#'    表头）。而 R 自己 `write.csv(df)` 出来的文件，第一行就是 `"","a","b"`
#'    —— 行名那一列的表头是空的。所以**用户从 R 里导出的 csv 一点问题都没有，
#'    一预览就报错**，这是最常见的那条路径。
#'
#' 补法用 R 自己的约定 `V1 / V2 …`（和 read.table 的 check.names=TRUE 一致），
#' 重名的再 `make.unique()` 去重 —— DT 对重复列名的报错是另一条
#' （"The column name 'x' is not found in data"），一样让人摸不着头脑。
dsapp_preview_fix_names <- function(df) {
  if (is.null(df) || !is.data.frame(df) || ncol(df) == 0L) return(df)
  nm <- names(df)
  if (is.null(nm) || length(nm) != ncol(df)) nm <- rep("", ncol(df))
  bad <- is.na(nm) | !nzchar(trimws(nm))
  if (any(bad)) nm[bad] <- sprintf("V%d", which(bad))
  nm <- trimws(nm)
  if (anyDuplicated(nm)) nm <- make.unique(nm, sep = "_")
  names(df) <- nm
  df
}

#' 一个文件的预览内容（文件页的预览卡 / 任务页的弹窗 **共用**）
#'
#' ★ V13.4 item 5a：这段原来是 mod_files.R 里 `output$preview` 的一整块
#'   内联分支。任务页要"点文件名就能预览"（用户原话），而预览这件事——
#'   体积闸门、HTML 的 sandbox、图片/PDF 走会话级地址、表格列名修补——
#'   每一支都是踩过坑才写成这样的。**再抄一份到任务页，等于把那些坑重新
#'   挖一遍**：抄的人只会抄"能显示"的那部分，`nosniff`、CSP、体积闸门
#'   这些"看不见但必须"的东西一定会漏。所以抽成一个函数，两边都用它。
#'
#' @param path 绝对路径。**调用方负责校验归属**（文件页走 dsapp_file_path，
#'   任务页走 dsapp_ws_path）—— 这里不做路径检查，它只管"这个文件怎么显示"。
#' @param session 用来注册会话级预览地址，见 dsapp_preview_url
#' @param ns 调用方的命名空间函数。只有表格那一支要用（DT 的输出 id）
#' @param table_render `function(df)` → UI，表格那一支怎么画。
#'   传 NULL 表示调用方没有独立的 output 可以挂 DT —— 任务页的弹窗就是
#'   这种情况（它整个内容在 renderUI 里，而 **renderUI 里不能嵌套
#'   renderDataTable**），此时退化成一张静态 HTML 表格。
#'
#' @return UI；或者 **NULL**。NULL 不是"出错"，是"这一支归调用方自己画"：
#'   眼下只有**压缩包**是这样 —— 文件页要给它配一个"解压到本对话工作区"
#'   的按钮，而那个按钮依赖"当前打开的是哪个对话"，只有文件页知道。
#'   任务页那边压缩包是**本来就在工作区里**的东西，没有什么可解的。
dsapp_preview_ui <- function(path, session, cfg = dsapp_config(), ns = NULL,
                             table_render = NULL) {
  if (is.null(path) || !file.exists(path)) {
    return(div(class = "alert alert-warning m-3", "文件不存在或名称非法。"))
  }

  s    <- basename(path)
  kind <- dsapp_file_kind(s)
  size <- file.info(path)$size

  # ---- 体积闸门（V11 item 11）----
  #
  # 用户原话：「小于 20MB 在线预览都可以」—— 反过来，超过就不给预览。
  #
  # ⚠️ 闸门放在**所有分支之前**，不是塞进文本分支里。图片、PDF 一样能
  #    把浏览器拖死，而"页面卡住"在用户眼里和"程序坏了"没有区别。
  #    下载那条路不受这个数影响。
  if (!is.na(size) && size > DSAPP_PREVIEW_MAX_BYTES) {
    return(div(class = "alert alert-secondary m-3",
      icon("triangle-exclamation"),
      sprintf(" %s，超过在线预览上限 %s，请下载后查看。",
              dsapp_fmt_bytes(size),
              dsapp_fmt_bytes(DSAPP_PREVIEW_MAX_BYTES))))
  }

  # ---- HTML：渲染出来，不是显示源码（V11 item 1）----
  #
  # V10 及以前 html 和 txt 一起走 text 分支 = dsapp_escape 之后当源码
  # 显示。用户看到的是一整页 <div>，原话就是"html 不能显示渲染后的，
  # 是以文本形式展现的"。
  #
  # ⚠️ sandbox 里**没有** allow-same-origin，这是故意的：
  #    报告里的 plotly/DT 要跑脚本，所以留 allow-scripts；但文档因此
  #    处在一个不透明源里，读不到本应用的 DOM、cookie、localStorage。
  #    响应头那条 CSP 是同一件事的第二道锁（见 files.R 的
  #    dsapp_preview_url），防的是"把地址复制到新标签页打开"。
  if (kind == "html") {
    # ★ V15.6 item 9：HTML 预览也带版本号。这条最要紧 —— 报告页就是 HTML，
    #   而"重新生成报告"是**覆盖写同一个文件名**，不带 `?v=` 的话用户点了
    #   半天刷新，看到的还是上一版（连 Ctrl+F5 都未必管用，因为 iframe 的
    #   缓存键在部分浏览器里跟顶层文档不是一回事）。
    url <- dsapp_preview_url_v(
      dsapp_preview_url(session, path, "text/html; charset=utf-8", cfg), path)
    if (is.null(url)) {
      return(div(class = "alert alert-warning m-3", "无法读取该文件。"))
    }
    # ★★ V14 item 4：先在心里内联一遍，**只为统计**能不能全内联上。
    #
    #    真正发给浏览器的那份是 dsapp_preview_url() 的处理器自己内联的
    #    （同一条路、同一个上限），这里读第二遍只是为了决定要不要提示。
    #    重复读一次是**故意的**：要让那个处理器知道"该内联"很容易，要让
    #    它把"没能内联几处"再传回来给这一层用，就得给 dataobj 加一条
    #    反向通道，代价比多读一遍大得多。文件本身已经过上面 20MB 的闸门。
    probe <- tryCatch(
      dsapp_html_read_inlined(path, dirname(path),
                              max_total = DSAPP_HTML_PREVIEW_INLINE_MAX),
      error = function(e) NULL)
    has_files_dir <- length(list.files(file.path(dirname(path),
          paste0(tools::file_path_sans_ext(basename(path)), "_files")))) > 0
    return(tagList(
      # 非自包含的报告（saveWidget(selfcontained = FALSE) 之类）会带一个
      # 同名的 _files/ 目录。预览走的是会话级接口，同目录资源拿不到，
      # 那种报告在线看会缺样式 —— 与其让人对着一个没样式的页面猜，
      # 不如直接说清楚。
      if (has_files_dir)
        div(class = "alert alert-secondary small py-2 mx-2 mt-2 mb-0",
            icon("circle-info"),
            paste0(" 这个 HTML 依赖同目录下的 ",
                   tools::file_path_sans_ext(basename(path)), "_files/，",
                   "在线预览可能缺样式或图表；下载后打开是完整的。")),
      # ★ V14 item 4：报告里引用的文件**在盘上就找不到**时，说清楚是几个。
      #
      #    ⚠️ 这一条和上面那条是**两回事**，不能合并：上面说的是"能拿到、
      #       但这条预览通路拿不到"（我们已经靠内联解决了），这一条说的是
      #       "东西根本不在"。前者的正确反应是修代码，后者的正确反应是
      #       让用户知道报告本身缺料 —— 不区分的话，用户看到裂图根本分不清
      #       该找谁。
      if (!is.null(probe) && isTRUE(probe$ok) && probe$miss > 0)
        div(class = "alert alert-warning small py-2 mx-2 mt-2 mb-0",
            icon("triangle-exclamation"),
            sprintf(" 报告里有 %d 处引用指向的文件已经不在了（工作区里找不到），%s",
                    probe$miss,
                    if (probe$n > 0)
                      sprintf("其余 %d 张图已内联，能正常显示。", probe$n)
                    else "这些位置会显示为裂图。")),
      tags$iframe(src = url, sandbox = "allow-scripts allow-popups",
                  style = "width: 100%; height: 70vh; border: 0;",
                  class = "dsapp-preview-frame")
    ))
  }

  # ---- Markdown：同样要渲染（V11 item 1 的"其它标记语言"）----
  #
  # ★ V13.12 item 9：**渲染全文**，不再是前 20 行。理由见 dsapp_preview_full。
  if (kind == "markdown") {
    full <- dsapp_preview_full(path)
    return(tagList(
      p(class = "text-muted small px-2 pt-2 mb-1",
        sprintf("%s%s", dsapp_fmt_bytes(size),
                if (full$truncated)
                  sprintf("，文件太大，仅渲染前 %d 行", DSAPP_PREVIEW_LINES) else "")),
      div(class = "dsapp-preview-md", HTML(dsapp_md_html(full$text)))
    ))
  }

  if (kind == "image") {
    # ★★ V13.2：这里原来写的是 `paste0("files/", URLencode(s))`，
    #    指向 addResourcePath 注册的 /files 静态路由 —— **那条路由
    #    V13.1 item 6 就删掉了**（按账号隔离管理区，静态路由是进程级的，
    #    留着等于谁都能按路径拿别人的文件；见 app.R 里那段说明）。
    #
    #    删路由的时候漏了这里和下面 PDF 两处，于是从 V13.1 起：
    #      * 图片预览收到 404 → `<img>` 渲染成一个十几像素高的碎图；
    #      * PDF 预览收到 404 → 一个空白框。
    #    **界面上不报错、console 里也没有任何东西**，所以一直没人发现；
    #    测出来靠的是量 `naturalWidth`（0 = 根本没加载成功）。
    #
    #    改成和 html/markdown 分支同一条路：会话级 registerDataObj
    #    （见 files.R 的 dsapp_preview_url）。
    # ★ V15.6 item 9/15：地址本身是稳定的（`pv-<md5>`），文件被覆盖写之后
    #   浏览器会拿缓存 —— 加上 mtime 当版本号。同时给 <img> 挂上
    #   `dsapp-img`：www/app.js 末尾那段就是按这个 class 找图的，负责
    #   加载中转圈、失败自愈重试、彻底失败画成"图裂了"而不是十几像素的空白。
    #   ⚠️ 这两个 class 缺一不可 —— 只加 alt 不加 `dsapp-img`，转圈不会出现，
    #      用户回到的就是 item 15 报的那个样子。
    url <- dsapp_preview_url_v(
      dsapp_preview_url(session, path, dsapp_image_mime(s), cfg), path)
    if (is.null(url)) {
      return(div(class = "alert alert-warning m-3", "无法读取该文件。"))
    }
    return(tags$img(src = url,
                    class = "img-fluid rounded dsapp-img",
                    alt = basename(path),
                    style = "max-height: 70vh;"))
  }

  if (kind == "pdf") {
    # 同上一处：静态路由早没了，这里也必须走会话级接口。
    # ★ V15.6 item 9：PDF 同样要吃版本号 —— 重跑一次任务覆盖了同名 PDF，
    #   地址不变，浏览器就把上一版画给你（而且 iframe 里连个加载事件都
    #   不好观察，用户只看到"新报告没生成"）。
    url <- dsapp_preview_url_v(
      dsapp_preview_url(session, path, "application/pdf", cfg), path)
    if (is.null(url)) {
      return(div(class = "alert alert-warning m-3", "无法读取该文件。"))
    }
    return(tags$iframe(
      src = url,
      style = "width: 100%; height: 70vh; border: 0;"))
  }

  if (kind == "table") {
    df <- dsapp_preview_table(path, n = 100)
    if (is.null(df)) {
      return(div(class = "alert alert-warning m-3",
                 "无法解析为表格。可能是分隔符不是逗号/制表符，或文件不是表格。"))
    }
    return(tagList(
      p(class = "text-muted small px-2 pt-2 mb-1",
        sprintf("预览前 %d 行（共 %s）", nrow(df), dsapp_fmt_bytes(size))),
      if (is.null(table_render)) dsapp_preview_static_table(df)
      else table_render(df)
    ))
  }

  if (kind == "text") {
    # V11 item 11：以前是"末尾 512 KB"，现在按**行**取前 20 行。
    #
    # 用户要的是"这文件长什么样"，而一行有多长跟信息量无关：按字节切
    # 会把一行从中间劈开，看着像文件坏了；而且 512KB 的日志有上万行，
    # 用户滑都滑不到底，读起来比 20 行更难。
    #
    # ⚠️ 读的是**开头**不是末尾。日志里最有用的是开头（命令、参数、
    #    版本、报错前的上下文），而"末尾"这个选择是 V7 为了省内存随手
    #    定的，不是用户要的。
    head <- dsapp_preview_head(path, DSAPP_PREVIEW_LINES)
    return(tagList(
      p(class = "text-muted small px-2 pt-2 mb-1",
        sprintf("%s%s", dsapp_fmt_bytes(size),
                if (head$truncated)
                  sprintf("，仅显示前 %d 行", DSAPP_PREVIEW_LINES) else "")),
      tags$pre(class = "dsapp-preview-pre",
               dsapp_escape(paste(head$lines, collapse = "\n")))
    ))
  }

  # 压缩包：**归调用方**（见函数头对 NULL 的说明）
  if (kind == "archive") return(NULL)

  # 二进制：不给预览，引导下载
  div(class = "alert alert-secondary m-3",
      sprintf("二进制文件（%s），不支持在线预览，请下载后查看。",
              dsapp_fmt_bytes(size)))
}

#' 把数据框画成一张**静态** HTML 表格（任务页弹窗的表格预览）
#'
#' 为什么不直接上 DT：这一支的调用点在 `renderUI` 里，而 renderUI 里
#' **不能嵌套 renderDataTable**（DT 的输出要自己一个 output 槽）。文件页
#' 有那个槽（`output$preview_tbl`），任务页的弹窗没有 —— 为它单开一个
#' output 就得多一套"当前在看哪个文件"的状态，而那个状态和"当前选中的
#' 任务"会不同步。一张静态表格换来的是"点开就看得见"，这个交换划算。
#'
#' ⚠️ 列名和单元格**都**要转义：内容来自文件，而文件是用户（或模型）写的，
#'    是不可信输入。这里用的是 tags 而不是 HTML()，转义由 htmltools 负责。
dsapp_preview_static_table <- function(df, max_rows = 100L) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L) {
    return(p(class = "text-muted small px-2", "（没有数据行）"))
  }
  df <- utils::head(df, max_rows)
  div(class = "dsapp-preview-tablewrap",
    tags$table(class = "table table-sm table-striped small mb-0",
      tags$thead(tags$tr(lapply(names(df), function(nm) tags$th(nm)))),
      tags$tbody(lapply(seq_len(nrow(df)), function(i)
        tags$tr(lapply(df, function(col) tags$td(as.character(col[[i]])))))
      )
    )
  )
}

# ⚠️ 这里原来有 dsapp_file_delete() 和 dsapp_file_rename()，V5 起删掉了。
#    它们是平铺时代的实现，现在用会**静默地只做一半**：
#      * rename 把新名字过 dsapp_safe_name，那里拒绝 `/` —— 于是"移动"
#        这个动作直接不可用，而用户以为自己点了移动
#      * 两个都不搬 file_owner 的归属行，改完名的文件会变成"无主"
#        （按 dsapp_file_can_edit，无主 = 人人可删）
#      * delete 对目录无效，且不校验目录是否为空
#    统一走 dsapp_entry_move() / dsapp_entry_delete()，别再各写一份。

#' 把对话工作区里的产物**手动**发布到文件管理区
#'
#' ⚠️ V12 item 3 起，任务产物会**自动**同步一份到文件管理区（见
#'    dsapp_sync_artifacts）。这个函数还在，它管的是自动同步够不着的那部分：
#'      * 自动同步有体积和个数上限，超出的要用户自己点
#'      * 手动传进工作区的文件不是"任务产出"，不在自动同步的范围里
#'      * 想改落点/改名字（自动同步固定落在对话自己的文件夹里）
#'
#' ⚠️ 自动同步那边**不再平铺进共享区根目录**，这是它能回来的关键 ——
#'    V3 之前是执行完直接往根目录拷，在 agent 模式下会失控：一个任务跑六轮，
#'    每轮的中间文件都进共享区，于是
#'      * 「文件」页分不清哪些是用户传的、哪些是模型产的
#'      * 模型下一轮看到的文件清单里混进自己的中间产物（见 prompts.R）
#'      * 共享区被"tmp1.csv / tmp2.csv"这类东西塞满
#'    现在每个对话一个文件夹，那些中间产物至少是**分堆放着**的，翻得到、
#'    也不碍别人的事。手动发布这条路仍然是平铺（用户点的时候知道自己在
#'    干什么，要的就是"放到共享区根目录给别人拿"）。
#'
#' @return list(ok, msg, name)
dsapp_publish_artifact <- function(name, sid, cfg = dsapp_config()) {
  # ★ V13 item 6：发布是"把我的产物放进**我的**管理区"，所以要按这个对话的
  #   主人重新绑一次 cfg。放在最前面 —— 下面的 dsapp_ws_path 虽然走的是
  #   工作区（不看 files_dir），但 dest 那一步看，中途再换根会让 src/dest
  #   落在两套配置上，将来谁加一句用 cfg$files_dir 的代码就出错。
  cfg <- dsapp_config_sid(sid, cfg)
  src <- dsapp_ws_path(name, sid, cfg)
  if (is.null(src)) return(list(ok = FALSE, msg = "文件不存在或名称非法"))

  # 共享区里的软链不能发布：软链指向工作区，复制过去的是个空壳，
  # 而且删掉工作区后它在共享区里就悬空了。
  if (dsapp_is_link(src)) {
    return(list(ok = FALSE, msg = "这是共享区文件的只读链接，不需要发布"))
  }
  if (isTRUE(file.info(src)$isdir)) {
    return(list(ok = FALSE, msg = "暂不支持发布目录"))
  }

  dest <- dsapp_unique_path(cfg$files_dir, basename(src))
  ok <- tryCatch(file.copy(src, dest, overwrite = FALSE),
                 error = function(e) FALSE)
  if (!isTRUE(ok)) {
    return(list(ok = FALSE, msg = sprintf("发布失败：%s", basename(src))))
  }
  dsapp_files_protect(dest)
  # 记下"工作区里的 name 发布了，落在共享区的 dest"。界面上的「已发布」
  # 标记查的就是这条记录 —— 拿文件名去共享区里比对是不行的，落点是
  # basename 而 name 是相对路径（详见 db.R 里 ws_published 的说明）。
  try(db_ws_pub_set(sid, name, basename(dest)), silent = TRUE)
  list(ok = TRUE, msg = basename(dest), name = basename(dest))
}

# ---- 任务产物自动同步（V12 item 3） ----------------------------------------

# 一次同步最多搬多少个文件。一个批量脚本可以产出几千个文件（每个样本一张
# 图），全搬进共享区要几分钟，而任务收尾那条路径是**同步**跑的 ——
# 卡住的是所有人的页面（一个应用一个 R 进程，见 DSAPP_ZIP_MAX 的说明）。
# 超了如实说，不静默截断（note 会挂到任务记录上）。
#
# ⚠️ V16.9 更正：上面那句「超了如实说」是从 V12 起就写在文档里的**意图**，
#    而代码当时做的是 `skipped + 1; next` —— 一个字都没说。整整一个版本里
#    全库 1247 个真产物只同步进去 949 个，谁都没发现。现在超了返回
#    `blocked`，任务收尾据此提醒用户（见 R/taskrun.R）。
#
# ⚠️ 这两个常量现在是 `dsapp_sync_artifacts()` 的**默认实参**，不是硬编码 ——
#    「补齐」那条路径（dsapp_sync_repair）在**子进程**里跑，不卡任何人的页面，
#    所以它显式放大这两个值。改这里的默认值仍然要连带看那两处。
DSAPP_SYNC_MAX_FILES <- 300L

# 一次同步最多搬多少字节。
#
# ⚠️ 这个数比 DSAPP_ZIP_MAX（2G）小得多，因为两者的代价不一样：打包下载是
#    用户**自己点**的，卡一下他知道在等什么；自动同步是任务收尾时**自己**跑
#    的，用户正在看别的页面，而复制走的是主进程 —— 一个 50G 的 .bam 复制
#    几分钟，所有人的页面一起僵住，还没人知道为什么。512M 足够覆盖绝大多数
#    真实产物（表格、图、pdf），超出的部分如实说，用户想要就自己去「文件」
#    页的对话产物里手动发布（那条路没有这个上限）。
DSAPP_SYNC_MAX_BYTES <- 512 * 1024^2

#' 这个对话在文件管理区里的同步文件夹（取不到就定一个）
#'
#' 名字形如 `单细胞分析-4279`：前面是对话标题（用户认得出），后面是对话 id
#' 尾 4 位（重名时不会撞车）。**只在第一次同步时定**，之后一直用这个名字 ——
#' 为什么不能每次现算，见 db.R 里 sync_dirs 建表那一段。
#'
#' @return 共享区里的相对路径（一段），失败时 NULL
dsapp_sync_dir <- function(sid, cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(sid)) return(NULL)
  con <- dsapp_db(cfg)

  got <- tryCatch(db_sync_dir_get(sid, con = con), error = function(e) NULL)
  if (!is.null(got)) return(got)

  ttl <- tryCatch({
    r <- DBI::dbGetQuery(con, "SELECT title FROM sessions WHERE id = ?",
                         params = list(sid))$title
    if (length(r) && !is.na(r[[1]])) as.character(r[[1]]) else ""
  }, error = function(e) "")

  dir <- dsapp_sync_free_name(con, sid, dsapp_sync_stem(ttl, sid))
  db_sync_dir_set(sid, dir, con = con)
  dir
}

#' 对话标题 → 同步文件夹名的**前半段**（不含撞车序号）
#'
#' 名字形如 `单细胞分析-4279`：前面是对话标题（用户认得出），后面是对话 id
#' 尾 4 位（重名时不会撞车）。
#'
#' ⚠️ 抽出来是为了让"第一次同步时定名字"（dsapp_sync_dir）和"改对话名之后
#'    跟着改"（dsapp_sync_rename）**算的是同一个名字**。这两处一旦漂了，
#'    用户改完名会看到一个跟标题对不上的文件夹，而且再改一次也对不上。
dsapp_sync_stem <- function(ttl, sid) {
  if (is.null(ttl) || !length(ttl) || is.na(ttl[[1]])) ttl <- ""
  ttl <- as.character(ttl[[1]])
  if (!nzchar(ttl)) ttl <- "新会话"

  # 标题是用户/模型给的，可能很长、带斜杠、带控制字符 —— 过一遍
  # dsapp_safe_name（它只取最后一段、掐到 200 字、拒掉纯点号）。
  stem <- dsapp_safe_name(ttl)
  if (!nzchar(stem) || identical(stem, "unnamed")) stem <- "对话"
  stem <- substr(stem, 1, 40)

  if (is.null(sid) || !length(sid) || is.na(sid[[1]])) sid <- ""
  sid <- as.character(sid[[1]])
  tail4 <- gsub("[^A-Za-z0-9]", "", sub("^.*-", "", sid))
  tail4 <- if (nzchar(tail4)) substr(tail4, 1, 4) else substr(gsub("[^A-Za-z0-9]", "", sid), 1, 4)
  if (nzchar(tail4)) paste0(stem, "-", tail4) else stem
}

#' 撞车就加序号
#'
#' 文件夹不能撞车：另一个对话的标题可能一模一样。
#' 这里**不能**用 dsapp_unique_path 的 `(1)` 形式，它按文件存在与否判，
#' 而我们这里判的是"有没有**另一个对话**占着这个名字"。
#'
#' ⚠️ V13 item 6：撞车判断要**只看同一个账号的**对话。管理区按账号分了
#'    之后，甲账号有个「单细胞分析-4279」，乙账号的对话标题哪怕一模一样
#'    也落在自己的 u<N>/ 里，根本不冲突 —— 还按全局判的话，乙会拿到一个
#'    莫名其妙的「单细胞分析-4279(1)」，而他翻遍自己的管理区也找不出
#'    那个"已经占了名字的"是谁。
#'
#' ⚠️ `session_id <> ?` 那个条件是给**改名**用的：第一次同步时自己那行还
#'    不存在，多这个条件没有影响；改名时自己那行**已经存在**了（存的是旧
#'    名字），不把自己排掉的话 —— 见下面 dsapp_sync_rename 的说明。
dsapp_sync_free_name <- function(con, sid, base) {
  used <- tryCatch(DBI::dbGetQuery(con,
    "SELECT d.dir FROM sync_dirs d JOIN sessions s ON s.id = d.session_id
      WHERE d.session_id <> ? AND s.user_id IS (SELECT user_id FROM sessions WHERE id = ?)",
    params = list(sid, sid))$dir,
    error = function(e) character(0))
  dir <- base
  i <- 1L
  while (dir %in% used && i <= 999L) {
    dir <- paste0(base, "(", i, ")")
    i <- i + 1L
  }
  dir
}

#' 对话改名之后，把管理区里那个同步文件夹也跟着改（V13.2 item 6）
#'
#' 用户原话：「目前改任务名称的时候，文件管理系统中的名称并不能一并修改」。
#'
#' ---- 为什么原来不跟，现在又跟了 -------------------------------------------
#'
#' 同步文件夹的名字是 `<对话标题>-<id 尾4位>`，它只在**第一次同步**时定下来
#' （见 db.R 里 sync_dirs 建表那一段）。当初这么定是因为标题会被**自动**改：
#' 第一句话发出去之后对话就有了名字。现算的话，每改一次标题就换一个文件夹，
#' 之前同步进去的产物全留在一个没人认领的旧文件夹里，用户会以为东西丢了。
#'
#' 但**用户自己**改名是另一回事：他改完标题、切到「文件」页，看到文件夹还
#' 顶着旧名字，只会觉得"改名没生效"—— 他报的就是这个。所以现在跟着改。
#' （自动命名那条路也走同一个函数，但它跑的时候同步文件夹通常还没建出来，
#' 就算建出来了，把「对话-xxxx」改成真标题也正是用户想要的。）
#'
#' ⚠️ 改名要动**三本账**，漏一本都不会报错、但都会出问题：
#'   · sync_dirs.dir      — 落点本身。不改的话下次同步又按旧名字建一个，
#'                          用户会看到两个文件夹，新的那个还是空的
#'   · file_owner.name    — 归属行（键是**带账号前缀**的相对路径，见 users.R
#'                          的 dsapp_owner_key）。不改的话里面每个文件都变成
#'                          "无主"，而按 dsapp_file_can_edit 的规则无主 = 人人可删
#'   · ws_published.dest  — 发布记录。不改的话重跑一次任务就多一个
#'                          `plot(1).png`（详见图纸见 db_ws_pub_reprefix）
#'
#' ⚠️ 盘上没有那个文件夹（用户自己删了、或者只是账上有）时**不算失败**：
#'    把账改了，下次同步按新名字建出来就是了。
#'
#' ⚠️ 整个函数**不许抛异常**：它挂在改名的路上，而那时候标题已经改成功了。
#'    这里失败最多是文件夹名没跟上，绝不能让"改名"这个动作报错。
#'    所有错误就地咽掉，写进返回值的 msg。
#'
#' @param con 显式传库连接。**测试传的是临时库**，自己 `dsapp_db()` 会去改真库。
#' @return list(ok, moved, from, to, msg)
dsapp_sync_rename <- function(sid, new_title, cfg = dsapp_config(),
                              con = NULL) {
  out <- list(ok = FALSE, moved = FALSE, from = NULL, to = NULL, msg = "")
  if (is.null(sid) || !length(sid) || is.na(sid[[1]]) ||
      !nzchar(as.character(sid[[1]]))) {
    out$msg <- "没有对话"; return(out)
  }
  sid <- as.character(sid[[1]])

  if (is.null(con)) con <- tryCatch(dsapp_db(cfg), error = function(e) NULL)
  if (is.null(con)) { out$msg <- "库打不开"; return(out) }

  old <- tryCatch(db_sync_dir_get(sid, con = con), error = function(e) NULL)
  out$from <- old
  if (is.null(old) || !nzchar(old)) {
    # 还没同步过 —— 名字还没定下来，第一次同步时会直接用新标题算。
    out$ok <- TRUE; out$msg <- "还没同步过，不用改"; return(out)
  }

  base <- dsapp_sync_stem(new_title, sid)
  if (identical(base, old)) { out$ok <- TRUE; out$msg <- "名字没变"; return(out) }

  # 归属行和发布记录的键都带账号前缀，先把 cfg 绑到**对话主人**身上。
  # 用全局 cfg 的话前缀是 u<当前登录者>/，改的是别人的账（或者谁的都不是）。
  ucfg <- tryCatch(dsapp_config_sid(sid, cfg), error = function(e) cfg)

  newdir <- dsapp_sync_free_name(con, sid, base)
  out$to <- newdir

  dst <- dsapp_file_path(newdir, ucfg, must_exist = FALSE)
  if (is.null(dst)) { out$msg <- "新名字不合法"; return(out) }
  src <- dsapp_file_path(old, ucfg, must_exist = TRUE)

  if (is.null(src) || !dir.exists(src)) {
    db_sync_dir_set(sid, newdir, con = con)
    out$ok <- TRUE; out$moved <- FALSE
    out$msg <- "文件夹不在盘上，只改了记录"
    return(out)
  }
  if (file.exists(dst)) { out$msg <- "新名字被占了"; return(out) }

  # 目录本身没有 0444（dsapp_files_protect 只对文件设），所以 rename 不会
  # 被只读位挡住 —— 挡住它的是父目录的写权限。
  ok <- tryCatch(file.rename(src, dst), error = function(e) FALSE)
  if (!isTRUE(ok)) { out$msg <- "改名失败（检查管理区目录权限）"; return(out) }

  db_sync_dir_set(sid, newdir, con = con)
  try(dsapp_file_owner_move(old, newdir, con = con,
                            user_id = dsapp_cfg_uid(ucfg)), silent = TRUE)
  try(db_ws_pub_reprefix(sid, old, newdir, con = con), silent = TRUE)

  out$ok <- TRUE; out$moved <- TRUE
  out$msg <- sprintf("同步文件夹已改名为「%s」", newdir)
  out
}

#' 把一次任务的产物自动同步到文件管理区（V12 item 3）
#'
#' 用户原话：「任务产生的文件还是不能同步到文件管理区，请设置自动同步」。
#'
#' ⚠️ 这是 V3 拿掉过的那件事，**做法不一样**，差别就在"落到哪儿"：
#'    V3 是直接平铺进共享区根目录，一个跑六轮的 agent 任务会把
#'    tmp1.csv / tmp2.csv / plot(1).png 全倒在用户眼皮底下，共享区里分不清
#'    哪些是人传的、哪些是机器产的（见 dsapp_publish_artifact 的说明）。
#'    现在每个对话在共享区下有**自己一个文件夹**，产物按工作区里的相对路径
#'    原样落进去：子目录结构保留，重跑覆盖自己上一轮的产物，不会越滚越多。
#'
#' ⚠️ 只在**任务收尾**时同步（app.R 里 db_task_files_set 那一段），不在执行
#'    途中同步：跑到一半的 CSV 是半截的，用户下载了会以为数据就长这样。
#'
#' ⚠️ 整个函数**不许抛异常**。它挂在任务收尾那条路上，而那时候任务已经跑完
#'    了 —— 同步失败（磁盘满、库锁超时、文件名非法）绝不能把结果毁掉。
#'    所有错误就地咽掉，写进返回值的 msg 里，调用方只记日志。
#'
#' @param sid 对话 id
#' @param artifacts 工作区内的**相对路径**（executor 的差集，已排除内部文件）
#' @param user_id 归属人；NULL 时去库里查对话的主人
#' @param max_files,max_bytes 这一次最多搬多少个 / 多少字节。默认值就是下面
#'   那两个 DSAPP_SYNC_* 常量 —— **生产里所有现有调用点都吃默认值**，行为
#'   一行没变。只有「补齐」那条路径（dsapp_sync_repair）会显式放大它们，
#'   因为它跑在**子进程**里、不卡任何人的页面。
#' @return list(ok, dir, n, bytes, skipped, blocked, msg)
#'   `skipped` = 结构性跳过（内部文件 / 镜像进来的软链 / 目标非法），它是
#'   **正常**的，不该拿去提醒用户；`blocked` = 被上限刷掉或复制失败，
#'   调用方必须据此说话（见下面 break 那一段）。
dsapp_sync_artifacts <- function(sid, artifacts, user_id = NULL,
                                 max_files = DSAPP_SYNC_MAX_FILES,
                                 max_bytes = DSAPP_SYNC_MAX_BYTES,
                                 cfg = dsapp_config()) {
  out <- list(ok = FALSE, dir = NULL, n = 0L, bytes = 0, skipped = 0L,
              blocked = 0L, blocked_names = character(0), msg = "")
  if (is.null(sid) || !nzchar(sid)) { out$msg <- "没有对话"; return(out) }
  artifacts <- as.character(artifacts %||% character(0))
  artifacts <- artifacts[!is.na(artifacts) & nzchar(artifacts)]
  if (!length(artifacts)) { out$ok <- TRUE; out$msg <- "这次没有产物"; return(out) }

  # ★ V13 item 6：先定人、再定 cfg，顺序不能反。
  #   产物要同步进**对话主人自己的**管理区（data/files/u<N>/），而
  #   `dsapp_file_path(rel, cfg, ...)` 是按 cfg$files_dir 解析的 ——
  #   cfg 还是全局那个的话，解析出来的是 _anon（空目录），产物会同步到一个
  #   谁也看不见的地方去过。而且它不报错：目录建得出来，文件也复制得进去，
  #   只有打开「文件」页才发现什么都没有。
  if (is.null(user_id)) {
    user_id <- tryCatch({
      u <- DBI::dbGetQuery(dsapp_db(cfg),
                           "SELECT user_id FROM sessions WHERE id = ?",
                           params = list(sid))$user_id
      if (length(u) && !is.na(u[[1]])) as.integer(u[[1]]) else NULL
    }, error = function(e) NULL)
  }
  cfg <- dsapp_config_user(user_id, cfg)

  res <- tryCatch({
    dsapp_files_ensure(user_id, cfg)
    rel <- dsapp_sync_dir(sid, cfg)
    if (is.null(rel)) stop("定不出落点")
    dest_root <- dsapp_file_path(rel, cfg, must_exist = FALSE)
    if (is.null(dest_root)) stop("落点非法")
    if (!dir.exists(dest_root) && !dir.create(dest_root, recursive = TRUE,
                                              showWarnings = FALSE)) {
      stop("建不了目录")
    }

    # 这个对话以前同步出去的落点。用来判"共享区里那个同名文件是不是我自己的"
    # —— 是就覆盖（重跑一次任务，产物应该更新，而不是多出一个 plot(1).png），
    # 不是就另起一个名字（绝不覆盖别人传上来的东西）。
    pubs <- tryCatch(db_ws_pub_map(sid, con = dsapp_db(cfg)),
                     error = function(e) NULL)
    mine <- if (is.null(pubs)) character(0) else as.character(pubs$dest)

    n_file <- 0L; n_byte <- 0; skipped <- 0L; blocked <- 0L
    # ★ V16.9：blocked 的**名字**也要带出去，不能只带个数。
    #   界面那句「还有 N 个没搬动」要是只能靠"把交给我的整批都当成没搬动"
    #   来凑数，就会在"只被刷掉 3 个、搬进去 297 个"时谎报 300 ——
    #   而那正是最常见的形态（撞上限时前面的都已经搬进去了）。
    blocked_names <- character(0)

    # ★★ V17 item 2：工作区里**镜像自文件区**的那一层，不能反过来同步回文件区。
    #
    #   用户原话：「文件管理页面的 T2DM–PD公开数据项目：可直接复制的Agen-8251
    #   里面的 data_raw，就是空的，但是它在言出法随页面的文件管理区就是有文件的」。
    #
    #   成因是一条**环**：
    #     ① 执行代码前 `dsapp_mirror_shared()` 把**整个**管理区映进工作区根，
    #        目录用 `dir.create` 真建、文件用软链（见它的说明：目录不能软链，
    #        否则模型一句 write.csv 就写进了公共区）；
    #     ② `dsapp_ws_artifacts()` 用 `find` 打快照，**软链不进、真目录进**；
    #     ③ 于是差集里全是"镜像目录本身"，而 `isdir` 那一支只 `dir.create`。
    #   ⇒ 每一次任务收尾，都把**别的对话的文件夹名字**在本次对话的文件夹里
    #     重建一遍（空的）。生产里最刺眼的一条是自指：
    #     `u11/按照…-9030/按照…-9030/` —— 只有"整片镜像"才会造出这种东西。
    #
    #   ⚠️ 判据用**首段名字**，因为镜像只发生在工作区**根**那一层
    #      （`dsapp_mirror_shared(src_root = cfg$files_dir, dest_root = 工作区根)`），
    #      而落点是 `<对话文件夹>/<原名>` —— 首段命中就够了，子层跟着一起挡掉。
    mirror_names <- tryCatch(
      list.files(cfg$files_dir, all.files = FALSE, no.. = TRUE),
      error = function(e) character(0))

    # ⚠️⚠️ 光凭"名字对得上"**不够**，会误伤：用户在管理区根上建过一个叫
    #    `16S分析` 的文件夹，而模型完全可能在**工作区根**建一个同名的真产物
    #    目录 —— 那时名字对得上，但它不是镜像，跳过它等于把用户的产物丢了
    #    （丢得还很安静：界面只说"0 个产物"，不报错）。
    #
    #    真正区分得开的是**软链**：镜像目录是 `dsapp_mirror_shared()` 建的，
    #    它给文件铺的是软链，模型自己不会建软链。所以要求"这一支里确实有软链"。
    #    `-quit` 找到第一条就停（管理区动辄上万文件，不 early-exit 会明显变慢）；
    #    `-maxdepth 3` 是因为软链就铺在镜像的前几层 —— 这一条只用来**证实**，
    #    不要求穷尽，所以浅一点没有正确性代价。
    #
    #    ⚠️ 已知的残留取舍：管理区里那个文件夹**自己是空的**（一个文件都没有）
    #       时，镜像出来的壳里也就没有软链 ⇒ 认不出来 ⇒ 还是会被建一次。
    #       "一个空目录"和"一个镜像过来的空目录"在盘上**真的没有区别**，
    #       这里认不了就是认不了；代价只是偶尔多一个空壳，不会丢产物。
    ws_is_mirror <- function(seg) {
      p <- tryCatch(dsapp_ws_path(seg, sid, cfg, must_exist = TRUE),
                    error = function(e) NULL)
      if (is.null(p) || !dir.exists(p)) return(FALSE)
      hit <- suppressWarnings(system2(
        "find", c(shQuote(p), "-maxdepth", "3", "-type", "l", "-print", "-quit"),
        stdout = TRUE, stderr = FALSE))
      length(hit) > 0 && any(nzchar(hit))
    }
    # 每个首段只 find 一次（一个会话的产物里同一段会反复出现）。
    .mirror_cache <- new.env(parent = emptyenv())

    # ⚠️ 用**下标**循环而不是 `for (a in artifacts)`：到顶 break 的那一刻要
    #    报出"还剩几条没搬"，而 `which(artifacts == a)` 在重名时会数错
    #    （同一个相对路径出现两次是可能的 —— 入参是外部给的字符串向量）。
    for (i in seq_along(artifacts)) {
      a <- artifacts[[i]]
      # ⚠️ 内部文件**在这里也要挡一次**，不能只靠调用方（executor 的差集）
      #    已经过滤过。`.Rlib` / `.venv` 里是几千个包文件，漏进来一次就是
      #    几分钟的主进程复制 + 共享区里一片狼藉，而且没有任何报错。这条
      #    不是"以防万一"：这个函数的入参是**外部给的一个字符串向量**，
      #    它自己必须能扛住里面有什么。
      if (isTRUE(dsapp_ws_is_internal(a))) { skipped <- skipped + 1L; next }
      # 镜像层（见上面那两段）。判据是**两件事同时成立**：
      #   ① 首段名字出现在管理区根上；② 工作区里这一支**确实含软链**。
      # 只看 ① 会误伤同名真产物，只看 ② 会把模型自己建的软链也当成镜像。
      if (length(mirror_names)) {
        seg <- strsplit(a, "/", fixed = TRUE)[[1]][1]
        if (seg %in% mirror_names) {
          known <- .mirror_cache[[seg]]
          if (is.null(known)) {
            known <- ws_is_mirror(seg)
            assign(seg, known, envir = .mirror_cache)
          }
          if (isTRUE(known)) { skipped <- skipped + 1L; next }
        }
      }
      src <- dsapp_ws_path(a, sid, cfg, must_exist = TRUE)
      if (is.null(src)) { skipped <- skipped + 1L; next }
      # 共享区镜像进来的只读软链不是这个对话的产物 —— 它**本来就在**
      # 共享区里，同步过去等于自己复制自己。
      if (dsapp_is_link(src)) { skipped <- skipped + 1L; next }

      target_rel <- file.path(rel, a)
      target <- dsapp_file_path(target_rel, cfg, must_exist = FALSE)
      if (is.null(target)) { skipped <- skipped + 1L; next }

      isdir <- isTRUE(file.info(src)$isdir)
      if (isdir) {
        # 目录只建结构，不占配额（空目录也要建 —— V8 item 7：模型建了个
        # 空文件夹，用户得有地方看得见它）。
        dir.create(target, recursive = TRUE, showWarnings = FALSE)
        next
      }

      # ★ V16.9：上限这里**不再静默跳过**。
      #
      #   以前是 `skipped <- skipped + 1L; next`，两个后果都在生产里真出过事：
      #     · 条数到顶之后，`n_file >= MAX` 对**后面每一条**都成立 → 剩下的
      #       几千条会被白扫一遍，只为把计数加上去；
      #     · 更要命的是 `blocked` 和"内部文件/镜像软链"共用一个 `skipped`，
      #       调用方分不出"本来就不该搬"和"没搬成"，于是**界面上一个字都没有**。
      #       而任务收尾传进来的是**这一次的差集**（R/taskrun.R），被刷掉的
      #       文件下一轮既不是新增也不是改动 → **永远不会再被提交一次**。
      #       2026-10-06 实测：全库 1247 个真产物只同步进去 949 个，缺的 298 个
      #       里有 9 GB 是撞了下面那道字节闸（切口是干净的字母序断层）。
      #   现在到顶就 break（继续扫也搬不动），并把实情记进 blocked ——
      #   上面 DSAPP_SYNC_MAX_FILES 注释里那句「超了如实说，不静默截断」
      #   从 V12 起就写在文档里，直到这一版才真的做到。
      if (n_file >= max_files) {
        blocked <- blocked + (length(artifacts) - i + 1L)
        blocked_names <- c(blocked_names, artifacts[i:length(artifacts)])
        break
      }
      sz <- file.info(src)$size
      if (is.na(sz)) {
        blocked <- blocked + 1L; blocked_names <- c(blocked_names, a); next
      }
      # ⚠️ 字节闸这里**不能 break**：后面的文件可能很小，跳过这一条大的还能
      #    搬进来好几个 —— 而 break 会把它们一起丢掉（那正是旧的"永不复试"
      #    场景，只不过换了个触发条件）。单文件超过 max_bytes 的，靠
      #    dsapp_sync_repair 放大上限那条路来救，这里如实计入 blocked。
      if (n_byte + sz > max_bytes) {
        blocked <- blocked + 1L; blocked_names <- c(blocked_names, a); next
      }

      dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
      if (file.exists(target)) {
        if (!(target_rel %in% mine)) {
          # 不是我们同步出去的（别人传上来的、或者手动发布落在同名位置），
          # 另起一个名字，绝不覆盖。
          target <- dsapp_unique_path(dirname(target), basename(target))
          target_rel <- file.path(rel, sub(paste0("^", rel, "/"), "", target))
        } else {
          # ★ 是我们自己上一轮同步出去的，要**覆盖**（重跑一次任务，产物
          #   应该更新，而不是堆出一串 plot(1).png / plot(2).png）。
          #
          # ⚠️ 覆盖之前必须先 chmod 回可写。共享区里的文件是 0444
          #    （dsapp_files_protect，那是**安全属性**：它们会以软链进工作区，
          #    软链会穿透写，脚本里一句 write.csv 就能把原始数据覆盖掉）。
          #    不 chmod 直接 file.copy(overwrite = TRUE) 会**失败**，而且
          #    失败得很安静 —— R 只丢一句 warning，返回值是 FALSE。实测就是
          #    这样：任务重跑之后共享区里那份还是上一轮的旧内容，用户看到
          #    的数是错的。
          #
          #    只对被我们覆盖的那一个文件 chmod，且立刻在下面重新调
          #    dsapp_files_protect() 打回去。
          try(Sys.chmod(target, mode = "0644"), silent = TRUE)
        }
      }
      # 复制失败（磁盘满、权限、源文件正被写）也是 blocked 不是 skipped ——
      # 它同样是"本该搬进来但没搬成"，用户有权知道。
      if (!isTRUE(file.copy(src, target, overwrite = TRUE))) {
        blocked <- blocked + 1L; blocked_names <- c(blocked_names, a); next
      }

      dsapp_files_protect(target)
      if (!is.null(user_id)) {
        try(dsapp_file_owner_set(target_rel, user_id, con = dsapp_db(cfg)),
            silent = TRUE)
      }
      try(db_ws_pub_set(sid, a, target_rel, con = dsapp_db(cfg)), silent = TRUE)

      n_file <- n_file + 1L; n_byte <- n_byte + sz
    }

    list(ok = TRUE, dir = rel, n = n_file, bytes = n_byte, skipped = skipped,
         blocked = blocked, blocked_names = blocked_names, msg = "")
  }, error = function(e) list(ok = FALSE, dir = NULL, n = 0L, bytes = 0,
                              skipped = 0L, blocked = 0L,
                              blocked_names = character(0),
                              msg = conditionMessage(e)))

  out$ok <- isTRUE(res$ok); out$dir <- res$dir
  out$n <- as.integer(res$n %||% 0L); out$bytes <- res$bytes %||% 0
  out$skipped <- as.integer(res$skipped %||% 0L); out$msg <- res$msg %||% ""
  # ⚠️ blocked **必须**从 res 里取出来。本仓有账：`res$skipped` 曾经漏在
  #    这里，于是返回值里那个字段是 NULL —— `sprintf("%s", NULL)` 给的是
  #    character(0)，界面上就是一句空白提示，而不是报错。
  out$blocked <- as.integer(res$blocked %||% 0L)
  out$blocked_names <- as.character(res$blocked_names %||% character(0))
  out
}

#' 把**历史**对话工作区里的产物补同步进管理区（V13 item 2）
#'
#' 用户原话：「比如 brca_result 这个文件夹，我在文件管理区就看不到」。
#'
#' ---- 为什么会有"看不到"这件事 ------------------------------------------------
#'
#' 产物自动同步是 **V12 item 3** 才加的（见上面 dsapp_sync_artifacts），而且
#' 只在**任务收尾**那一刻跑。在那之前跑出来的产物，一直只躺在对话自己的
#' 工作区里（data/workspaces/chat-<sid>/）—— 那里用户根本进不去，界面上
#' 也没有任何入口，所以从用户的角度看就是"东西没了"。
#'
#' 实测生产库（2026-09-16）：sync_dirs 表**一行都没有**，而 workspaces 下
#' 有 chat-s-20260912215607-5136、chat-s-20260915131728-4498 两个目录。
#' 也就是说 V12 上线之后**一次同步都没发生过** —— 那些对话的产物全部还在
#' 工作区里，一个都没进管理区。
#'
#' ---- 判据 ------------------------------------------------------------------
#'
#' 「这个对话以前同步过没有」不看目录在不在、也不看里面有东西没有，看
#' **sync_dirs 表里有没有它的行**：那一行是 dsapp_sync_dir() 第一次同步时
#' 写下的，写了就说明这条路走通过（哪怕产物是空的）。
#'
#' ⚠️ 反过来判（"管理区里没这个文件夹就补一次"）会踩两个坑：用户把同步
#'    文件夹删了之后，每次打开文件页都会给他重新建一个；而任务重跑又会让
#'    产物文件名带 (1)、(2) 一路涨。表是准的，盘不是。
#'
#' ⚠️ 整个函数**不许抛异常**，理由和 dsapp_sync_artifacts 一样：它是在渲染
#'    文件页的路上被调的，抛出去就是白屏。每一条对话各包一层。
#'
#' @param user_id 只补这个账号的对话。NULL 时什么都补不了（宁可不做）
#' @return list(n_sessions, n_files, dirs = character(0))
dsapp_sync_backfill <- function(user_id, cfg = dsapp_config()) {
  out <- list(n_sessions = 0L, n_files = 0L, dirs = character(0))
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) return(out)
  cfg <- dsapp_config_user(uid, cfg)

  sess <- tryCatch(db_sessions_list(user_id = uid, con = dsapp_db(cfg)),
                   error = function(e) NULL)
  if (is.null(sess) || nrow(sess) == 0) return(out)

  # 一次把已有的同步落点全查出来，别在循环里逐条查库
  done <- tryCatch(DBI::dbGetQuery(dsapp_db(cfg),
                                   "SELECT session_id FROM sync_dirs")$session_id,
                   error = function(e) character(0))

  for (i in seq_len(nrow(sess))) {
    sid <- as.character(sess$id[i])
    if (is.na(sid) || !nzchar(sid)) next
    if (sid %in% done) next          # 这条路走通过，交给 V12 的自动同步

    arts <- tryCatch(dsapp_ws_artifacts(sid, cfg), error = function(e) NULL)
    if (is.null(arts) || nrow(arts) == 0) next

    r <- tryCatch(dsapp_sync_artifacts(sid, arts$name, user_id = uid, cfg = cfg),
                  error = function(e) NULL)
    if (is.null(r) || !isTRUE(r$ok)) next

    out$n_sessions <- out$n_sessions + 1L
    out$n_files    <- out$n_files + as.integer(r$n %||% 0L)
    if (!is.null(r$dir) && nzchar(r$dir)) out$dirs <- c(out$dirs, r$dir)
  }
  out
}

#' 把工作区里**所有还没进管理区**的产物补齐（V16.9 item 1）
#'
#' ---- 和 dsapp_sync_backfill 的分工（两边的判据是**反的**，别合并）----------
#'
#'   * `dsapp_sync_backfill()` 走**表**（`sync_dirs` 有行就跳过）—— 够快，所以
#'     挂在「打开文件页」那条**渲染路**上自动跑一次。它只能补「从来没同步过
#'     的对话」。
#'   * `dsapp_sync_repair()` 走**盘**（工作区真产物 − 管理区里此刻真在的那些）
#'     —— 慢（要 stat 每个文件），所以只在用户**手动点**「导入历史产物」时跑，
#'     而且丢进子进程。
#'
#' ---- 为什么必须有它 --------------------------------------------------------
#'
#' 自动同步（R/taskrun.R）每次只传**这一次任务的差集**，而
#' `dsapp_sync_artifacts()` 撞上 `DSAPP_SYNC_MAX_FILES` / `_BYTES` 时是
#' **静默跳过**。被刷掉的那些，下一轮既不是新增也不是改动 → **永远不会再被
#' 提交一次**。2026-10-06 实测全库：1247 个真产物只同步进去 949 个，
#' 差 298 个（其中 9 GB 撞的是字节闸）。
#'
#' backfill **救不了**它们：那些对话**恰恰都有 sync_dirs 行**（没同步过的对话
#' 不可能撞上限），所以 backfill 会精准地全部跳过 —— 这就是用户看到的
#' 「点同步也没用」。
#'
#' ⚠️ 判据是**盘**不是表。用户把管理区里某个同步文件夹整个删掉之后，sync_dirs
#'    那行还在（它记的是"曾经做过什么"），于是 backfill 永远跳过它；repair
#'    会把它整个带回来（`s-20260930195103-0034` 生产里就是这情形）。这是
#'    **手动动作**，符合预期 —— 但不能拿它当自动路径用，否则每次打开文件页
#'    都给用户重建他刚删掉的东西。
#'
#' ⚠️ 这个函数**要能被 `dsapp_bg_start()` 丢进子进程**（R/jobs.R:178）。所以：
#'    * **不许引用任何 shiny 符号**（`session$` / `input$` / `reactive*`）——
#'      子进程只 source 非 `mod_` 的文件，引用了就是"找不到函数"；
#'    * **不许把 `con` 之类的 S4 外部指针放进参数或返回值** —— 跨不了进程；
#'    * `cfg` 用默认实参，子进程自己从 `.Renviron` 读 `data_root`。
#'    `selftest.R` 有一条静态断言钉着第一条。
#'
#' @param user_id 只补这个账号的对话
#' @param sid 只补这一个对话（NULL = 该账号全部）
#' @param min_age 跳过 mtime 在最近这么多秒内动过的文件。会话可能**正在**写它，
#'   而复制半截文件是**静默**的（文件在、内容少一半、没有报错）
#' @param max_files,max_bytes 这一次的上限。默认远大于 DSAPP_SYNC_* —— 这条
#'   路跑在子进程里，卡不到任何人的页面，所以敢放大。仍然是**有上限**的，
#'   而且超了照样计进 `blocked` 如实报出来（"不静默"这条没有例外）
#' @return list(ok, n_sessions, n_files, n_bytes, skipped, blocked, recent,
#'              blocked_files, recent_files, errors, dirs) —— **字段一个都不许少**
#'   （`sprintf("%s", NULL)` 给的是 `character(0)`，界面上就是一句空白）
dsapp_sync_repair <- function(user_id, sid = NULL, min_age = 5,
                              max_files = 20000L,
                              max_bytes = 64 * 1024^3,
                              cfg = dsapp_config()) {
  out <- list(ok = FALSE, n_sessions = 0L, n_files = 0L, n_bytes = 0,
              skipped = 0L, blocked = 0L, recent = 0L,
              blocked_files = character(0), recent_files = character(0),
              errors = character(0), dirs = character(0))
  uid <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (length(uid) != 1L || is.na(uid)) {
    out$errors <- "没有指定账号"
    return(out)
  }
  cfg <- dsapp_config_user(uid, cfg)

  sess <- tryCatch(db_sessions_list(user_id = uid, con = dsapp_db(cfg)),
                   error = function(e) NULL)
  if (is.null(sess) || nrow(sess) == 0) { out$ok <- TRUE; return(out) }

  ids <- as.character(sess$id)
  ids <- ids[!is.na(ids) & nzchar(ids)]
  if (!is.null(sid)) {
    want <- as.character(sid)
    ids <- ids[ids %in% want]
  }

  for (s in ids) {
    # ⚠️ 每个对话各包一层 tryCatch，理由和 backfill 一样：一个对话炸了
    #    （工作区被删、库锁、文件名非法）不能把整轮补齐毁掉。
    # ⚠️ 循环体里**不能写 `return()`** —— R 里 tryCatch 表达式里的 return()
    #    返回的是**外层函数**，第一个对话就会把整轮补齐掐断。
    r <- tryCatch({
      arts <- dsapp_ws_artifacts(s, cfg)
      if (is.null(arts) || nrow(arts) == 0) {
        list(ok = TRUE, nothing = TRUE)
      } else {
        rel <- dsapp_sync_dir(s, cfg)
        if (is.null(rel)) stop("定不出落点")

        # 「已经搬过去而且没变」= ws_published 里记的落点**此刻真在盘上**，
        # 且大小和工作区那份一致。
        #   ⚠️ 不判 exists 就当成"已经有了"是不够的：产物重跑之后内容变了、
        #      而那次改动正好被上限刷掉 —— 只判 exists 会漏掉它，而那正是
        #      要修的场景之一。
        #   ⚠️ 也不能反过来只信 ws_published 有行：用户把管理区里那份删了，
        #      行还在，那时候**必须**重新搬（他要的是"补齐"，不是"别烦我"）。
        pubs <- tryCatch(db_ws_pub_map(s, con = dsapp_db(cfg)),
                         error = function(e) NULL)
        done_a <- character(0)
        if (!is.null(pubs) && nrow(pubs) > 0) {
          for (k in seq_len(nrow(pubs))) {
            dp <- dsapp_file_path(as.character(pubs$dest[k]), cfg,
                                  must_exist = TRUE)
            if (is.null(dp)) next
            wp <- dsapp_ws_path(as.character(pubs$name[k]), s, cfg,
                                must_exist = TRUE)
            if (is.null(wp)) next
            dw <- file.info(dp)$size; ww <- file.info(wp)$size
            if (!is.na(dw) && !is.na(ww) && dw == ww) {
              done_a <- c(done_a, as.character(pubs$name[k]))
            }
          }
        }
        # setdiff 顺手去重（入参理论上不该有重复，但不靠它）
        need <- setdiff(as.character(arts$name), done_a)

        recent_files <- character(0)
        if (min_age > 0 && length(need)) {
          wp <- vapply(need, function(a)
            dsapp_ws_path(a, s, cfg, must_exist = TRUE) %||% NA_character_,
            character(1), USE.NAMES = FALSE)
          mt <- as.numeric(file.info(wp)$mtime)
          fresh <- !is.na(mt) & (as.numeric(Sys.time()) - mt) < min_age
          if (any(fresh)) {
            recent_files <- need[fresh]
            need <- need[!fresh]
          }
        }

        if (!length(need)) {
          list(ok = TRUE, nothing = TRUE, recent_files = recent_files)
        } else {
          rr <- dsapp_sync_artifacts(s, need, user_id = uid,
                                     max_files = max_files,
                                     max_bytes = max_bytes, cfg = cfg)
          rr$recent_files <- recent_files
          # 这一次到底**没搬成**哪些 —— 界面/日志要能报出名字，不是一个数。
          # ⚠️ 直接取 rr$blocked_names，**不要**写
          #    `if (rr$blocked > 0) need else character(0)`：那在"只被刷掉 3 个、
          #    搬进去 297 个"时会报成 300 个没搬动（`need` 是**整批**），
          #    而界面上那句话是「还有 N 个没搬动，再点一次补齐」—— 用户按这个
          #    数点第二次、发现还是一样多，就会当成按钮坏了。
          rr$blocked_files <- as.character(rr$blocked_names %||% character(0))
          rr
        }
      }
    }, error = function(e) list(ok = FALSE, msg = conditionMessage(e)))

    if (!isTRUE(r$ok)) {
      out$errors <- c(out$errors,
                      sprintf("%s: %s", s, r$msg %||% "未知错误"))
      next
    }
    if (length(r$recent_files)) {
      out$recent <- out$recent + length(r$recent_files)
      out$recent_files <- c(out$recent_files, r$recent_files)
    }
    if (isTRUE(r$nothing)) next

    out$n_sessions <- out$n_sessions + 1L
    out$n_files    <- out$n_files + as.integer(r$n %||% 0L)
    out$n_bytes    <- out$n_bytes + as.numeric(r$bytes %||% 0)
    out$skipped    <- out$skipped + as.integer(r$skipped %||% 0L)
    out$blocked    <- out$blocked + as.integer(r$blocked %||% 0L)
    out$blocked_files <- c(out$blocked_files, r$blocked_files %||% character(0))
    if (!is.null(r$dir) && nzchar(r$dir)) out$dirs <- c(out$dirs, r$dir)
  }

  # 有一个对话出错就 ok = FALSE —— 调用方据此决定提示的措辞，但**已经搬进去
  # 的那些不会回滚**（复制是逐条的，回滚反而会把用户的东西弄没）。
  out$ok <- length(out$errors) == 0
  out
}

# ---- 打包下载（V7） --------------------------------------------------------

# 一次**同步**打包的体积上限。
#
# 打包是**同步**跑在 R 进程里的（zip 是个子进程，R 在等它），而本站一个
# 应用一个 R 进程、所有访客共用 —— 一个几十 G 的目录被打包时，所有人的
# 页面都卡着，而且谁也不知道为什么。上限管的不是磁盘，是"别把服务器堵死"。
#
# ★ V16.10：这个常数的**值**没动，但它不再是"到此为止"了 —— 超过它就转到
#   `dsapp_zip_build()` 那个子进程里去打（见 `DSAPP_ZIP_BG_MAX`）。文件页
#   那几个只读的勾选下载仍然按老规矩来：超了就说清楚、让用户少勾几个，
#   因为那种场景下"等三分钟"比"少勾几个"更烦人。
DSAPP_ZIP_MAX <- 2 * 1024^3

# 后台打包的**硬顶**（★ V16.10）。
#
# 超过 `DSAPP_ZIP_MAX` 的那些走子进程，但子进程也不是无上限的：它写出来的
# 是一个**真的落盘**的 zip，先占磁盘、再由 downloadHandler 复制给浏览器。
# 8 G 是"单个对话的产物"这个量级的天花板（全库最大的那个对话是 9 G，
# 而那是整个对话、不是一层）。真撞上它说明有人想一次搬走一台机器，
# 那时候说一句话比悄悄写满磁盘强。
DSAPP_ZIP_BG_MAX <- 8 * 1024^3

#' 把一个目录**展开成真文件**（★ V16.10）
#'
#' 以前 `dsapp_zip_plan()` 遇到目录是把**目录名**原样交给 `zip::zip()`，
#' 靠 zip 自己递归。那样有两个问题，而且都不报错：
#'
#'   1. **软链会被 zip 跟进去**。zip 默认跟随软链（它包的是目标的内容），
#'      而工作区里的软链指向的是文件管理区里的**只读输入** —— 上面
#'      `dsapp_zip_plan()` 里那段"不进产物包"的设计，只在**顶层**成立：
#'      只要那些软链在某个子目录里（很常见，模型爱建 `data/` 往里挂），
#'      一整条目录丢进去就把它们全拖进包了。
#'   2. **体积算不准**。`dsapp_dir_bytes()` 走的是 `du`，而 `du` **不**跟随
#'      软链 —— 于是"盘点的体积"和"包里真实的体积"是两个数，超限那道闸
#'      按小的那个判。
#'
#' 所以自己走一遍，遇软链就跳过、只收真文件。
#'
#' ⚠️ **不能偷懒用 `list.files(recursive = TRUE)`**：它会跟着目录软链一路
#'    钻下去（`dsapp_files_list()` 那段注释记着同一件事：共享区里放一个
#'    `loop -> .` 就能让它无限展开）。这里用队列自己走，遇到软链直接不进队 ——
#'    不跟随就不可能有环。
#'
#' @param dir_abs 绝对路径
#' @param seg_prefix 这个目录相对 `root` 的路径（包里的条目名由它起头）
#' @return list(rels, bytes, links) —— `links` 是**跳过的**软链条数，
#'         调用方拿它说人话（"全都不可打包"和"目录是空的"要说得出区别）
dsapp_zip_expand <- function(dir_abs, seg_prefix) {
  rels <- list(); bytes <- 0; links <- 0L
  # 队列：每个元素是一个待走的目录（绝对路径 + 它在包里的前缀）
  queue <- list(list(abs = dir_abs, seg = seg_prefix))
  guard <- 0L
  while (length(queue)) {
    # 兜底：真出现病态深的树时宁可少打一点，也不要把主 R 进程拖死
    # （所有访客共用一个进程 —— 见 DSAPP_ZIP_MAX 上面那段）。
    guard <- guard + 1L
    if (guard > 200000L) break
    cur <- queue[[1L]]; queue <- queue[-1L]
    fs <- list.files(cur$abs, all.files = FALSE, no.. = TRUE)
    if (!length(fs)) next
    for (nm in fs) {
      ap <- file.path(cur$abs, nm)
      sp <- paste0(cur$seg, "/", nm)
      if (isTRUE(dsapp_is_link(ap))) { links <- links + 1L; next }
      inf <- file.info(ap)
      if (is.na(inf$size)) next          # 读不了就跳过，不猜
      if (isTRUE(inf$isdir)) {
        queue[[length(queue) + 1L]] <- list(abs = ap, seg = sp)
      } else {
        rels[[length(rels) + 1L]] <- sp
        bytes <- bytes + inf$size
      }
    }
  }
  list(rels = if (length(rels)) unlist(rels, use.names = FALSE) else character(0),
       bytes = bytes, links = links)
}

#' 盘点一次打包请求：哪些能打、一共多大
#'
#' 「下载选中」在 V7 之前是假的 —— 表格是单选，勾了一个目录点下载还会
#' 直接失败（`file.copy` 一个目录必定 FALSE，而且失败得悄无声息：浏览器
#' 那边只是下载了一个 0 字节的文件）。所以这里把"选中了什么"先算清楚，
#' 界面据此在**点下去之前**就把结果说清楚（是单文件直下、还是打个包），
#' 而不是让用户下完一个空文件再来问为什么。
#'
#' @param rels 相对 `root` 的路径（界面勾选的行）
#' @param max_bytes 这次允许打多大。**默认值一个字都不许动** —— 生产那三个
#'   调用点（`R/mod_files.R` 的 `:1452` / `:1492` / `:2190`）行为必须零变化。
#'   多根打包（`dsapp_zip_plan_multi`）用它把**剩余预算**传给下一组。
#' @return list(ok, msg, rels=相对路径, bytes, has_dir=是不是有目录, stale, n)
#'         `stale = TRUE` 时 `msg` 是空的 —— 那种情况**不该**由这里拼一句话
#'         给用户看，该由调用方去刷新自己的列表（见下面的 ★）。
dsapp_zip_plan <- function(rels, root, max_bytes = DSAPP_ZIP_MAX) {
  rels <- as.character(rels %||% character(0))
  rels <- rels[!is.na(rels) & nzchar(rels)]
  # ⚠️ stale 一开始就要放在返回结构里：调用方是 `if (!isTRUE(plan$ok))`
  #    这种写法，少一个字段就是 NULL，配上 `isTRUE()` 悄悄地走 else 分支
  #    —— 而不是报错。这种"缺字段不报错"的结构在这个仓库里踩过。
  if (!length(rels)) {
    return(list(ok = FALSE, msg = "没有选中任何东西", stale = FALSE))
  }

  keep <- character(0); bytes <- 0; has_dir <- FALSE
  # ★ V13.7 item 2：软链被跳过（下面那条）和"文件真的没了"原来是**同一个
  #   `!length(keep)` 出口，所以只说得出那句「刷新一下页面再试」。但这两件
  #   事的正确处置是相反的：软链是设计如此（说清楚就行），文件没了是列表
  #   陈旧（平台自己刷新）。分开数，别让前者冒充后者。
  n_link <- 0L      # 顶层就是软链的
  n_dir  <- 0L      # 顶层是目录的（哪怕里面一个能打的都没有）
  n_inner_link <- 0L
  for (r in rels) {
    seg <- dsapp_rel_segments(r)
    if (is.null(seg) || !length(seg)) next
    p <- dsapp_path_in(root, seg, must_exist = TRUE)
    if (is.null(p)) next
    # 工作区里软链进来的是文件管理区里的**只读输入**，不是这个对话的产物。
    # 打进包里等于把别人上传的几 G 数据复制一份给下载的人，而那份东西他
    # 在文件管理区本来就能直接下。
    if (dsapp_is_link(p)) { n_link <- n_link + 1L; next }
    seg_rel <- paste(seg, collapse = "/")

    is_dir <- isTRUE(file.info(p)$isdir)
    has_dir <- has_dir || is_dir
    if (is_dir) {
      n_dir <- n_dir + 1L
      # ★ V16.10：目录**展开**成真文件再进包，理由见 dsapp_zip_expand。
      ex <- dsapp_zip_expand(p, seg_rel)
      n_inner_link <- n_inner_link + ex$links
      add <- ex$rels
      b   <- ex$bytes
    } else {
      add <- seg_rel
      b   <- suppressWarnings(file.size(p))
      if (is.na(b)) b <- 0
    }

    if (bytes + b > max_bytes) {
      return(list(ok = FALSE, stale = FALSE, msg = sprintf(
        "选中的内容有 %s，超过一次打包的上限（%s）。少勾几个，或者单个下载。",
        dsapp_fmt_bytes(bytes + b), dsapp_fmt_bytes(max_bytes))))
    }
    bytes <- bytes + b
    keep <- c(keep, add)
  }

  if (!length(keep)) {
    # 全是只读输入软链：这是设计如此（上面那段注释），不是列表陈旧，
    # 也不该让用户去刷新 —— 刷新一百遍它还是软链。
    if (n_link > 0L && n_link == length(rels)) {
      return(list(ok = FALSE, stale = FALSE, msg = paste0(
        "选中的是文件管理区里的输入（在这个对话里是只读的），不进产物包。",
        "到「文件」页单独下它就行。")))
    }
    # ★ V16.10 新增的出口：选的**是目录**、而且里面的东西全都被跳过了。
    #   不单独接住的话会掉进下面那个 stale 分支，界面就变成"刷新一下页面"
    #   —— 而刷新一百遍也没用，那是设计如此。和上面那条软链是同一类误判。
    if (n_dir > 0L) {
      return(list(ok = FALSE, stale = FALSE, msg = sprintf(
        "选中的文件夹里没有可打包的产物%s。",
        if (n_inner_link > 0L)
          sprintf("（里面有 %d 项是文件管理区的只读输入，不进产物包）",
                  n_inner_link) else "")))
    }
    # ★ V13.7 item 2：原来是「选中的文件都不在了，刷新一下页面再试」——
    #   把 F5 写成了用户的待办。列表陈旧是平台自己查得出来、也做得了主的
    #   （重拉一遍就是刷新做的事），所以这里**只说事实、不给动作**，
    #   由调用方用 dsapp_notify_stale() 自己刷新。
    #   `msg` 留空：这个函数的读者是调用方，它才知道该刷新哪个列表。
    return(list(ok = FALSE, stale = TRUE, msg = ""))
  }
  list(ok = TRUE, stale = FALSE, msg = "", rels = keep, bytes = bytes,
       has_dir = has_dir, n = length(keep))
}

#' 盘点一次**跨根**的打包请求（★ V16.10）
#'
#' 对话页右边那张「本对话的文件」卡是**两个根混在一起**的一层清单：
#' 已经同步进文件管理区的那些行带 `files:` 前缀，还没同步过去的工作区行
#' 不带 —— 见 `dsapp_art_path()` 那段说明。而 `dsapp_zip_plan()` 只认一个
#' `root`，所以整层打包这件事在两个根之间走不通。
#'
#' 这里做的事很薄：把每条坐标用 `dsapp_art_root_rel()` 拆成 `(root, rel)`，
#' **按 root 分组**，然后逐组调 `dsapp_zip_plan()` —— 软链跳过、目录展开、
#' 超限、stale 那一整套**一行都不重写**（重写就是第二份会漂的实现）。
#'
#' ⚠️ 预算（`max_bytes`）是**跨组累计**的：传给下一组的是剩余量，不是原始
#'    上限。不然三个 1.9 G 的组会各自过关，合起来 5.7 G 照样把主进程堵死。
#'
#' ⚠️ 组间 rel 撞车的处置：**先出现的组赢**（和 `art_level_merge()` 那条
#'    "同名以文件区为准"是同一条规矩）。调用方只要按"文件区在前"的顺序传
#'    坐标，两边的行为就是一致的。
#'
#' @param coords 产物坐标（`files:` 前缀的有无都可以）
#' @return list(ok, stale, msg, groups=list(list(root, rels, bytes, n)),
#'              bytes, n, has_dir)
dsapp_zip_plan_multi <- function(coords, sid, cfg = dsapp_config(),
                                 max_bytes = DSAPP_ZIP_MAX) {
  coords <- as.character(coords %||% character(0))
  coords <- coords[!is.na(coords) & nzchar(coords)]
  if (!length(coords)) {
    return(list(ok = FALSE, stale = FALSE, msg = "没有选中任何东西"))
  }

  roots <- character(0); rels_by_root <- list()
  for (co in coords) {
    rr <- tryCatch(dsapp_art_root_rel(co, sid, cfg),
                   error = function(e) list(root = NULL, rel = NULL))
    root <- rr$root; rel <- rr$rel
    # 工作区不存在时 dsapp_ws_dir() 给的是 NA —— 不是 NULL，`%||%` 拦不住
    if (is.null(root) || !length(root) || is.na(root[[1]]) || !nzchar(root[[1]])) next
    if (is.null(rel) || !length(rel) || is.na(rel[[1]]) || !nzchar(rel[[1]])) next
    root <- root[[1]]; rel <- rel[[1]]
    i <- match(root, roots)
    if (is.na(i)) {
      roots <- c(roots, root)
      rels_by_root[[length(rels_by_root) + 1L]] <- rel
    } else {
      rels_by_root[[i]] <- c(rels_by_root[[i]], rel)
    }
  }
  if (!length(roots)) {
    # 一条坐标都没解析出来 = 列表陈旧（那个文件真的没了），由调用方刷新。
    return(list(ok = FALSE, stale = TRUE, msg = ""))
  }

  groups <- list(); total <- 0; seen <- character(0); has_dir <- FALSE
  for (i in seq_along(roots)) {
    rels <- unique(rels_by_root[[i]])
    rels <- rels[!rels %in% seen]       # 先出现的组赢
    if (!length(rels)) next
    p <- dsapp_zip_plan(rels, roots[[i]], max_bytes = max_bytes - total)
    if (!isTRUE(p$ok)) {
      # ⚠️ 一组出问题就**整单**不成 —— 不能"能打的那几组先打了"：
      #    那样用户拿到一个看着正常、其实少了一个根的包，而且没有任何提示。
      return(list(ok = FALSE, stale = isTRUE(p$stale), msg = p$msg %||% ""))
    }
    seen <- c(seen, p$rels)
    groups[[length(groups) + 1L]] <- list(root = roots[[i]], rels = p$rels,
                                          bytes = p$bytes, n = p$n)
    total <- total + p$bytes
    has_dir <- has_dir || isTRUE(p$has_dir)
  }
  if (!length(groups)) {
    return(list(ok = FALSE, stale = FALSE, msg = "选中的内容都不在盘上了。"))
  }
  list(ok = TRUE, stale = FALSE, msg = "", groups = groups,
       bytes = total, n = sum(vapply(groups, function(g) g$n, numeric(1))),
       has_dir = has_dir)
}

#' 按盘点结果真的打一个 zip
#'
#' @param dst 目标 zip 路径。Shiny 的 downloadHandler 会给一个**已经存在
#'   的空文件** —— 实测 `zip::zip()` 直接往上写没问题（它把这个空文件当成
#'   一个待追加的归档），不用先删。
dsapp_zip_write <- function(dst, plan, root) {
  if (!isTRUE(plan$ok)) return(list(ok = FALSE, msg = plan$msg))
  res <- tryCatch({
    if (requireNamespace("zip", quietly = TRUE)) {
      # root 必须给：包里的路径按相对 root 写，子目录结构才保得住
      # （results/volcano.png 在包里还在 results/ 下）。全拍平的话同名
      # 文件会互相覆盖，而且用户解压出来也认不出哪个是哪个。
      zip::zip(dst, files = plan$rels, root = root)
    } else {
      old <- setwd(root); on.exit(setwd(old), add = TRUE)
      utils::zip(dst, files = plan$rels)
    }
    NULL
  }, error = function(e) conditionMessage(e))
  # zip::zip 成功时返回 TRUE（不是 NULL），失败时上面已经变成字符串了
  if (is.character(res)) return(list(ok = FALSE, msg = sprintf("打包失败：%s", res)))
  list(ok = TRUE, msg = "", n = plan$n, bytes = plan$bytes)
}

#' 按**多根**盘点结果真的打一个 zip（★ V16.10）
#'
#' 第一组用 `zip::zip()` 建包，其余组用 `zip::zip_append()` 追加到同一个文件。
#' ✅ 已核实（2026-10-07，本机 `zip` 2.3.1）：`zip_append` 的参数和 `zip` 一样是
#' `zipfile, files, recurse, compression_level, include_directories, root, mode`
#' —— `root` 在，所以每一组**各自**按自己的根算条目名，这正是多根要的。
#'
#' ⚠️ `root` 是逐组给的，不是全局一个：组 A 的 root 是文件区里那个对话文件夹、
#'    组 B 的是工作区目录，两个根的相对路径口径完全不同。忘了传 root 的话
#'    条目名会变成绝对路径（解压出来是一棵 `/data3/...` 的树），不报错。
#'
#' ⚠️ **`utils::zip` 那条 fallback 不支持追加**。多组又没有 `zip` 包时，
#'    这里**直接返回失败**，不退化成"只打第一组"—— 那样用户拿到一个看着
#'    正常、其实少了一个根的包，而界面上什么都不会说。
dsapp_zip_write_multi <- function(dst, plan) {
  if (!isTRUE(plan$ok)) return(list(ok = FALSE, msg = plan$msg %||% ""))
  groups <- plan$groups
  if (is.null(groups) || !length(groups)) {
    return(list(ok = FALSE, msg = "没有要打包的内容"))
  }
  has_zip <- requireNamespace("zip", quietly = TRUE)
  if (!has_zip && length(groups) > 1L) {
    return(list(ok = FALSE, msg = paste0(
      "这次要打包的内容分散在两个位置（对话工作区 + 文件管理区），",
      "而这台机器上没有 zip 支持，打不成一个包。分开下载即可。")))
  }

  res <- tryCatch({
    for (i in seq_along(groups)) {
      g <- groups[[i]]
      if (!length(g$rels)) next
      if (!has_zip) {
        old <- setwd(g$root); on.exit(setwd(old), add = TRUE)
        utils::zip(dst, files = g$rels)
      } else if (i == 1L) {
        zip::zip(dst, files = g$rels, root = g$root)
      } else {
        zip::zip_append(dst, files = g$rels, root = g$root, mode = "mirror")
      }
    }
    NULL
  }, error = function(e) conditionMessage(e))
  if (is.character(res)) return(list(ok = FALSE, msg = sprintf("打包失败：%s", res)))
  list(ok = TRUE, msg = "", n = plan$n, bytes = plan$bytes)
}

# ---- 后台打包（★ V16.10）---------------------------------------------------
#
# 为什么要有这一层：打包是**同步**的，而"整个对话一键打包"动辄几个 G ——
# 那几秒到几分钟里，所有访客的页面都卡着（一个应用一个 R 进程）。所以超过
# DSAPP_ZIP_MAX 的那些挪到子进程去打，主进程只轮询。
#
# ⚠️⚠️ `dsapp_zip_build()` 是 `dsapp_bg_start()` 的入参，**跑在子进程里**。
#    子进程只 source 非 `mod_` 的 `R/*.R`（见 R/jobs.R 的 `.dsapp_bg_worker`），
#    所以这个函数里**一个 shiny 符号都不许出现**（`session$` / `input$` /
#    `reactive` / `showNotification` / `req`）—— 写了就是子进程里报
#    "could not find function"，而主进程这边只看到"子进程意外退出"。
#    自检里有一条专门扫这个。

#' 后台打包：子进程入口（★ V16.10）
#'
#' ⚠️ 形参是**两个具名参数**，不是一个 `args` 列表 —— `dsapp_bg_start()` 是
#'    `do.call(fn, args)` 调的，写成 `function(args)` 就得在调用点写成
#'    `args = list(args = list(groups =, dst =))`，那一层套一层迟早有人漏。
#'    仓里其余几个后台入口（`dsapp_sync_repair(user_id, cfg)`、
#'    `dsapp_ssh_test(...)`）都是具名的。
#'
#' @param groups `dsapp_zip_plan_multi()` 的产物（`list(list(root, rels, ...))`）
#' @param dst 目标 zip 的**绝对**路径（子进程不共享主进程的 cwd，
#'   相对路径会落到别处 —— 而且是**子进程**的 cwd，连日志里都看不出来）
#' @return list(ok, n, bytes, msg) —— 由 `.dsapp_bg_worker` 落成 JSON 给主进程
dsapp_zip_build <- function(groups = NULL, dst = NULL) {
  if (is.null(dst) || !length(dst) || is.na(dst[[1]]) || !nzchar(dst[[1]])) {
    return(list(ok = FALSE, n = 0L, bytes = 0, msg = "没有给定打包的目标文件"))
  }
  d <- dirname(dst)
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  # ⚠️ 先删掉同名残留再打。`zip::zip()` 对**已存在**的归档是**追加**语义
  #    （`dsapp_zip_write()` 那段注释说的就是这个：Shiny 给的是一个空文件，
  #    所以追加没问题）。但这里如果上一次跑崩了留下一个半截的包，追加进去
  #    就是一个混着两批内容的包 —— 解压出来多了几个不该有的文件，
  #    而且没有任何提示。
  if (file.exists(dst)) unlink(dst)

  plan <- list(ok = TRUE, groups = groups,
               n = sum(vapply(groups %||% list(),
                              function(g) as.numeric(g$n %||% 0), numeric(1))),
               bytes = sum(vapply(groups %||% list(),
                                  function(g) as.numeric(g$bytes %||% 0), numeric(1))))
  r <- tryCatch(dsapp_zip_write_multi(dst, plan),
                error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
  if (!isTRUE(r$ok)) {
    unlink(dst)
    return(list(ok = FALSE, n = 0L, bytes = 0, msg = r$msg %||% "打包失败"))
  }
  # 打完再量一次真实的体积：盘点的数和包里的数不是一个数（压缩率、
  # 打包期间文件又变了），而用户看到的"下到多大"是后者。
  sz <- suppressWarnings(file.size(dst))
  list(ok = TRUE, n = plan$n, bytes = if (is.na(sz)) plan$bytes else as.numeric(sz),
       msg = "")
}

#' 把后台打好的包交给浏览器（★ V16.10）
#'
#' 两个页面的 `downloadHandler$content()` 都调它 —— 复制完**立刻删**：
#' 那个包可能有好几个 G，留着就是拿数据盘换省事。
#'
#' ⚠️ 失败（包在"打完"和"复制"之间被清掉、或者 `run_dir` 满了）会返回
#'    `FALSE`，**调用方一定要看**：下载已经开始，界面上没法再提示了，
#'    浏览器那边只会拿到一个空文件 —— 不记一条日志的话，这件事在服务端
#'    完全不留痕迹。
dsapp_zip_bg_handoff <- function(file, path) {
  if (is.null(path) || !length(path) || is.na(path[[1]]) || !nzchar(path[[1]])) {
    return(FALSE)
  }
  ok <- tryCatch(isTRUE(file.copy(path, file, overwrite = TRUE)),
                 error = function(e) FALSE)
  try(unlink(path), silent = TRUE)
  ok
}

#' 清掉后台打包留下的孤儿 zip（★ V16.10）
#'
#' 正常路径上，打包好的包由 `downloadHandler` 的 `content()` 复制给浏览器、
#' 复制完就 `unlink`。但用户在"正在打包…"的时候把页面关掉，就没人做那一步了
#' —— 文件留在 `run_dir` 里，几 G 一个。
#'
#' ⚠️ **不挂定时器**：这是在**一次新的后台打包开始时**顺手清一次。定时器要
#'    一直醒着，而这个清理本身就是低频的；而且 `run_dir` 在数据盘上，
#'    `exports/` 那套 GC（48 小时 / 2048 MB）管的是别的目录，够不着这里。
#'
#' @param dir 结果目录（`cfg$run_dir`）
#' @param max_age 秒；超过这个岁数还没被人取走的，就是孤儿
#' @return 清掉的个数（不可见）
dsapp_zip_bg_gc <- function(dir, max_age = 6 * 3600) {
  if (is.null(dir) || !length(dir) || is.na(dir[[1]]) || !dir.exists(dir)) {
    return(invisible(0L))
  }
  pat <- "^zipbuild-.*\\.zip$"
  fps <- list.files(dir, pattern = pat, full.names = TRUE)
  if (!length(fps)) return(invisible(0L))
  inf <- file.info(fps)
  old <- !is.na(inf$mtime) &
         (as.numeric(Sys.time()) - as.numeric(inf$mtime)) > max_age
  fps <- fps[old]
  if (!length(fps)) return(invisible(0L))
  for (f in fps) try(unlink(f), silent = TRUE)
  invisible(length(fps))
}

# ---- HTML 自包含化 / markdown 依赖打包（★ V14 item 3、item 4）---------------
#
# 用户原话（item 3）：「生成的全部 html 文件需要把图片写进 html 文件里，
# 而不是临时从附带文件夹里读取，这样保障用户单独分发 html 文件时，其它人
# 也能正常查看。对应的 md 文件下载时需要把依赖的文件一起打包下载」。
# 用户原话（item 4）：「最新的分析报告预览时，html 里的图片是裂的」。
#
# ★★ 这两条是**同一个根因**，所以放在一起修。
#
#    在线预览走的是 dsapp_preview_url() 注册的**会话级**接口，浏览器眼里
#    这份文档的基地址是 `/session/<token>/dataobj/`，**不是报告所在的那个
#    目录**。模型按提示词写的 `<img src="litdigest/figures/x.png">` 于是被
#    解析成 `/session/<token>/dataobj/litdigest/figures/x.png` —— 那个路由
#    只认注册过的 `pv-<hash>`，别的路径一律 404。表现就是一张裂图，而且
#    **Shiny 日志里一个字都没有**（请求根本没走到任何会记日志的处理器）。
#
#    实测（2026-09-27，data/workspaces/chat-s-20260926155458-9226/分析报告.html）：
#    报告里 11 个 <img>，磁盘上一张不缺、相对路径也全对，在线预览全是裂的。
#    所以这不是"图片没生成"，是"地址解析不到"。
#
# ⚠️ 为什么不给工作区挂一条静态路由（那是最直觉的修法）：见 app.R 里
#    `addResourcePath` 那一段 —— 静态路由是**进程级**的，等于把按账号隔离
#    整个绕过去。V13 item 6 明确删掉过它，不能加回来。
#
# ⚠️ 为什么不用 `session$fileUrl()`：它是把整个**文档** base64 成一个 data:
#    URL，一个 20MB 的报告会变成 27MB 的字符串（见本文件上面那段）。
#    这里 base64 的是**图片**，文档本身还是一个普通文件。
#
# 修法是同一个：**把图片变成文档的一部分**，三个落点各修一件事 ——
#   · 预览时：读进来 → 内联 → 发给浏览器。**老报告立刻不裂了**，用户不必
#     重跑一遍分析（这一步是 item 4 的关键：出问题的那份报告早就写完了，
#     光改提示词救不了它）；
#   · 下载时：内联之后再给。单独分发到别的机器上也是完整的（item 3 前半）；
#   · 生成后：分析任务收尾时把盘上那份**直接改写**成自包含的（item 3 的
#     字面要求：生成出来的 html 文件本身就是完整的）。

# 单个内联文件的上限。超过就不内联，留一条相对引用 —— 一张 100MB 的图
# base64 之后是 133MB 的文本，浏览器打开它比看到一张裂图还难受。
DSAPP_HTML_INLINE_ONE_MAX <- 32 * 1024^2

# 一次内联的总上限。内联是**同步**跑在 R 进程里的（readBin + base64），
# 而本站一个应用一个 R 进程、所有访客共用 —— 和 DSAPP_ZIP_MAX 管的是
# 同一件事：别让一个人的报告把所有人的页面卡住。
DSAPP_HTML_INLINE_TOTAL_MAX <- 192 * 1024^2

# **在线预览**单独用一条更严的上限（★ V14 item 4）。
#
# ⚠️ 为什么不能和上面共用一个数：磁盘上那份 HTML 有多大，和浏览器要解析
#    的东西有多大，**是两回事**。内联之后图片变成正文，一个 15MB 的 HTML
#    可以内联出两百多 MB 的文本，而 20MB 的预览闸门（DSAPP_PREVIEW_MAX_BYTES）
#    量的是**磁盘上**那个文件，根本拦不住它。表现会是"点一下预览，整个
#    浏览器标签页卡死" —— 而按这个文件上面那段的老话，页面卡住在用户眼里
#    和程序坏了没有区别。
#    48MB 已经远超任何一份真实报告：实测那份裂图的报告内联完是 1.7MB。
DSAPP_HTML_PREVIEW_INLINE_MAX <- 48 * 1024^2

#' 相对引用 → 工作区内的相对路径（词法归一化 + 越界拦截）
#'
#' 把 `figures/a.png`、`./a.png`、`sub/../a.png` 归一成 `a.png` 这种形式。
#' **任何往上跑出根目录的引用一律返回 NULL** —— `../../../etc/passwd` 也是
#' 个合法的相对路径，不挡的话，一份报告就能把服务器上的任意文件读进
#' 浏览器，而且内联之后那份内容还会跟着报告被分发出去。
#'
#' ⚠️ **不能**用 `normalizePath()` 来做这件事，两个方向都会错：
#'    · 路径**不存在**时它原样返回，`a/../../x` 这种没归一化的串就混过去了；
#'    · 路径存在时它会连**符号链接**一起解析，而工作区里"上传区镜像进来的
#'      只读输入"恰恰是符号链接 —— 明明在里面的图会被判成"跑到外面了"，
#'      于是报告里的图静默地不内联（这和本函数要防的是两回事）。
#'    这里要的只是**词法**上的越界判断，自己按 `/` 切最准。
#'
#' @return 归一化之后的相对路径；越界或为空时返回 NULL
dsapp_html_rel <- function(ref) {
  ref <- trimws(as.character(ref %||% ""))
  if (length(ref) != 1 || is.na(ref) || !nzchar(ref)) return(NULL)
  # 反斜杠也当分隔符：模型偶尔会写 `figures\a.png`（Windows 习惯）
  ref <- gsub("\\\\", "/", ref)
  if (startsWith(ref, "/")) return(NULL)      # 绝对路径不在工作区里，也无从判断
  parts <- strsplit(ref, "/", fixed = TRUE)[[1]]
  out <- character(0)
  for (p in parts) {
    if (!nzchar(p) || identical(p, ".")) next
    if (identical(p, "..")) {
      if (!length(out)) return(NULL)          # 这一下就跑到根外面去了
      out <- out[-length(out)]
      next
    }
    out <- c(out, p)
  }
  if (!length(out)) return(NULL)
  paste(out, collapse = "/")
}

#' 一个 `<img src>` / `url()` 的值是不是"要从盘上读进来"的那种
#'
#' 自带内容的（data:）和外部地址一律返回 NULL —— 前者已经内联过了（再内联
#' 一次会得到一个 data:image/png;base64,data:image/png;base64,... 的怪物），
#' 后者本来就不该被内联（那会把别人服务器上的图抓进用户的报告里）。
dsapp_html_ref_rel <- function(ref) {
  r <- trimws(as.character(ref %||% ""))
  if (length(r) != 1 || is.na(r) || !nzchar(r)) return(NULL)
  # 查询串和锚点不属于文件名：`a.png?v=2#x` 指的还是同一个文件
  r <- sub("[?#].*$", "", r)
  if (!nzchar(r)) return(NULL)
  if (grepl("^(data:|https?:|//|mailto:|javascript:|#)", r, ignore.case = TRUE)) {
    return(NULL)
  }
  # 其它带协议的（file:、ftp:、tel: …）一律不碰 —— 判断不了的一律不动，
  # 比"猜一个然后改错"便宜。
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*:", r)) return(NULL)
  # 浏览器存的是 URL，中文和空格可能是 %E4%B8%AD / %20 的形式
  dec <- tryCatch(utils::URLdecode(r), error = function(e) r)
  dsapp_html_rel(dec)
}

#' 把 HTML 里指向本地文件的引用换成 base64 内联
#'
#' 认两种写法（这是"图"在 HTML 里出现的全部方式）：
#'   · `<img src="...">`（含单引号、属性前后空格、大小写混写）
#'   · CSS 里的 `url(...)`（`style="background:url(x.png)"` 和内联
#'     `<style>` 块里的 `background-image: url(x.png)` 都算）
#'
#' ⚠️ **只管这两种**，不是漏了：`<link rel=stylesheet>` / `<script src>` 指向
#'    本地文件的情况确实存在，但那要换的是**整个标签**（<link> 得变成
#'    <style>），改错了会把报告结构弄坏。而提示词本来就要求"样式写在
#'    <style> 里、不引用任何 CDN"，所以那两种情况对新报告不该出现。
#'    真出现了也不比现在更坏：和图片一样是一处 404。
#'
#' @param html     HTML 全文（字符向量会先用 \n 拼起来）
#' @param base_dir 相对路径按谁解析（一般是报告所在的目录）
#' @param max_total 这一次最多内联进去多少字节（预览那条路会给一个更小的）
#' @return list(html, n = 换掉几处, bytes = 内联进去多少字节,
#'              skipped = 有几处"看见了但没换"，miss = 有几处指向不存在的文件)
dsapp_html_inline <- function(html, base_dir,
                              max_total = DSAPP_HTML_INLINE_TOTAL_MAX) {
  txt <- paste(as.character(html %||% ""), collapse = "\n")
  out <- list(html = txt, n = 0L, bytes = 0, skipped = 0L, miss = 0L)
  if (!nzchar(txt)) return(out)

  root <- tryCatch(normalizePath(base_dir, mustWork = TRUE),
                   error = function(e) NA_character_)
  if (is.na(root)) return(out)

  seen <- new.env(parent = emptyenv())   # 同一个文件被引两次只读一次
  total <- 0

  #' 把一个引用换成 data: URI；换不了就原样返回
  resolve <- function(ref) {
    rel <- dsapp_html_ref_rel(ref)
    if (is.null(rel)) return(NULL)
    if (!is.null(seen[[rel]])) return(seen[[rel]])   # 已经读过 / 已经判定读不了
    p <- file.path(root, rel)
    # ⚠️ 用 file.exists 而不是 file.info：file.info 对不存在的路径返回一行
    #    NA 而**不报错**，下面 isTRUE(isdir) 于是是 FALSE，接着就会去
    #    readBin 一个不存在的文件 —— 那才是会抛异常的地方。
    if (!file.exists(p) || isTRUE(file.info(p)$isdir)) {
      seen[[rel]] <- ""      # 空串 = 这个引用不内联（下面按"没换成"计数）
      return(NULL)
    }
    sz <- suppressWarnings(file.size(p))
    if (is.na(sz) || sz <= 0 || sz > DSAPP_HTML_INLINE_ONE_MAX ||
        total + sz > max_total) {
      seen[[rel]] <- ""
      return(NULL)
    }
    b <- tryCatch(readBin(p, "raw", n = sz), error = function(e) NULL)
    if (is.null(b) || !length(b)) { seen[[rel]] <- ""; return(NULL) }
    enc <- tryCatch(openssl::base64_encode(b), error = function(e) NULL)
    # ⚠️ base64_encode 对 raw 输入返回的是**带换行**的长字符串吗 —— 实测
    #    （openssl 2.x）不是，但真带上换行的话嵌进 HTML 属性里就是语法错误。
    #    一行 sub 换掉，比赌对方的实现便宜。
    if (is.null(enc)) { seen[[rel]] <- ""; return(NULL) }
    enc <- gsub("[\r\n]", "", enc)
    if (!nzchar(enc)) { seen[[rel]] <- ""; return(NULL) }
    # ★ V13.7 的 dsapp_preview_mime 给的就是 `image/png` 这种，正好是
    #   data: URI 要的那一段。认不出来的按八位字节流给，浏览器至少会试着
    #   当图片解 —— 比给一个错的类型强。
    mime <- tryCatch(dsapp_preview_mime(basename(p)),
                     error = function(e) "application/octet-stream")
    if (!nzchar(mime)) mime <- "application/octet-stream"
    uri <- sprintf("data:%s;base64,%s", mime, enc)
    total <<- total + sz
    seen[[rel]] <- uri
    uri
  }

  # ---- 1) <img src="..."> --------------------------------------------------
  # 先整段匹配**标签**，再在标签里换属性值。反过来（直接拿一条正则去匹配
  # `src="..."`）会把 HTML 注释里、JS 字符串里的同名模式一起改掉。
  m <- gregexpr("<img\\b[^>]*>", txt, perl = TRUE, ignore.case = TRUE)
  tags <- regmatches(txt, m)[[1]]
  if (length(tags) && !identical(tags, character(0)) && m[[1]][1] > 0) {
    hit <- 0L; miss <- 0L; skipped <- 0L
    new <- vapply(tags, function(tg) {
      # 属性值可以用单引号、双引号，也可以不带引号（HTML5 允许）。
      # 不带引号那种里出现 `>` 是不可能的，所以上面那条 <img[^>]*> 是安全的。
      a <- regmatches(tg, regexec(
        "(?is)^(.*?\\bsrc\\s*=\\s*)([\"']?)([^\"'>\\s]+)(\\2)(.*)$",
        tg, perl = TRUE))[[1]]
      if (length(a) != 6) return(tg)
      uri <- resolve(a[[4]])
      if (is.null(uri)) {
        # 只在"这个引用看着像本地文件"时才记 miss，外部地址不算。
        if (is.null(dsapp_html_ref_rel(a[[4]]))) skipped <<- skipped + 1L
        else miss <<- miss + 1L
        return(tg)
      }
      hit <<- hit + 1L
      # ★★ V14 修：末尾必须是 a[[6]]（`(.*)` = 标签里 src 之后的一切），
      #    不是 a[[5]]。
      #    分层：a[[2]]=前缀 `<img src=`、a[[3]]=开引号、a[[4]]=引用、
      #    a[[5]]=闭引号（就是 `(\2)`）、a[[6]]=**剩余部分含结尾的 `>`**。
      #    一开始写成 a[[5]] 收尾，于是 `<img src='a.png' id='x'>` 被换成
      #    `<img src='data:...'` —— id/class/style 全丢，**连 `>` 都没了**，
      #    后面那个 `<` 就被浏览器当成属性名的一部分吃掉（实测 `</body>`
      #    会变成 img 上的 `body=""`）。
      #    ⚠️ 为什么难发现：src 本身是对的、图**照样能显示**，所以"图裂了"
      #    这类断言全绿；坏的是属性、以及图后面那一小段标记。selftest 里
      #    为此加了一条"src 之后的属性必须还在"的断言，别删。
      paste0(a[[2]], a[[3]], uri, a[[3]], a[[6]])
    }, character(1), USE.NAMES = FALSE)
    regmatches(txt, m) <- list(new)
    out$n <- out$n + hit; out$miss <- out$miss + miss
    out$skipped <- out$skipped + skipped
  }

  # ---- 2) CSS 的 url(...) --------------------------------------------------
  # ⚠️ 要连**引号一起**认：`url("a b.png")` 里的空格让不带引号那版匹配不上，
  #    而带空格的图片名在这个应用里很常见（中文标题做出来的图）。
  m2 <- gregexpr("url\\(\\s*([\"']?)([^\"')]+)\\1\\s*\\)", txt, perl = TRUE,
                 ignore.case = TRUE)
  hits2 <- regmatches(txt, m2)[[1]]
  if (length(hits2) && !identical(hits2, character(0)) && m2[[1]][1] > 0) {
    hit <- 0L; miss <- 0L; skipped <- 0L
    new2 <- vapply(hits2, function(u) {
      a <- regmatches(u, regexec("(?is)^url\\(\\s*([\"']?)([^\"')]+)\\1\\s*\\)$",
                                 u, perl = TRUE))[[1]]
      if (length(a) != 3) return(u)
      uri <- resolve(a[[3]])
      if (is.null(uri)) {
        if (is.null(dsapp_html_ref_rel(a[[3]]))) skipped <<- skipped + 1L
        else miss <<- miss + 1L
        return(u)
      }
      hit <<- hit + 1L
      sprintf("url(\"%s\")", uri)
    }, character(1), USE.NAMES = FALSE)
    regmatches(txt, m2) <- list(new2)
    out$n <- out$n + hit; out$miss <- out$miss + miss
    out$skipped <- out$skipped + skipped
  }

  out$html <- txt
  out$bytes <- total
  out
}

#' HTML 里还有没有"指向本地文件的相对引用"
#'
#' 用来判断要不要提示用户（"这份报告单独发出去会缺图"）。和
#' `dsapp_html_inline()` 认的是同一套写法，免得出现"内联说没有了、提示说
#' 还有"这种自相矛盾。
dsapp_html_has_local_ref <- function(html) {
  txt <- paste(as.character(html %||% ""), collapse = "\n")
  if (!nzchar(txt)) return(FALSE)
  for (pat in c("<img\\b[^>]*\\bsrc\\s*=\\s*[\"']?([^\"'>\\s]+)",
                "url\\(\\s*[\"']?([^\"')]+)\\s*\\)")) {
    m <- gregexpr(pat, txt, perl = TRUE, ignore.case = TRUE)
    hits <- regmatches(txt, m)[[1]]
    if (!length(hits) || identical(hits, character(0))) next
    for (h in hits) {
      a <- regmatches(h, regexec(pat, h, perl = TRUE, ignore.case = TRUE))[[1]]
      if (length(a) >= 2 && !is.null(dsapp_html_ref_rel(a[[2]]))) return(TRUE)
    }
  }
  FALSE
}

#' 读一个 HTML 文件 → 内联 → 返回全文（不落盘）
#'
#' 预览和下载都走这一条：它们要的是"发出去的那份内容"，盘上那个文件不该
#' 因为"有人看了一眼"就被改掉。
#'
#' @return list(ok, html, n, bytes, miss, skipped, msg)
#'   `miss` = 有几处引用指向**工作区里不存在**的文件（报告本身有问题）；
#'   `skipped` = 有几处是外部地址/已经内联过的（正常，不用管）。
dsapp_html_read_inlined <- function(path, base_dir = dirname(path),
                                    max_total = DSAPP_HTML_INLINE_TOTAL_MAX) {
  if (is.null(path) || !file.exists(path)) {
    return(list(ok = FALSE, html = NULL, n = 0L, bytes = 0, miss = 0L,
                skipped = 0L, msg = "文件不存在"))
  }
  txt <- tryCatch(readLines(path, warn = FALSE, encoding = "UTF-8"),
                  error = function(e) NULL)
  if (is.null(txt)) {
    return(list(ok = FALSE, html = NULL, n = 0L, bytes = 0, miss = 0L,
                skipped = 0L, msg = "读取失败"))
  }
  r <- tryCatch(dsapp_html_inline(txt, base_dir, max_total = max_total),
                error = function(e) NULL)
  if (is.null(r)) {
    return(list(ok = TRUE, html = paste(txt, collapse = "\n"), n = 0L,
                bytes = 0, miss = 0L, skipped = 0L, msg = ""))
  }
  # ⚠️ 出任何意外都退回**原文**，不能返回 NULL：调用方拿 NULL 会渲染成
  #    "无法读取该文件"，而文件明明是好的 —— 那比裂几张图更让人以为坏了。
  list(ok = TRUE, html = r$html, n = r$n, bytes = r$bytes,
       miss = as.integer(r$miss %||% 0L),
       skipped = as.integer(r$skipped %||% 0L), msg = "")
}

#' 把盘上那份 HTML **改写成**自包含的（★ V14 item 3）
#'
#' 和上面那个的区别只有一个：这个会落盘。分析任务收尾时对**这次产出的**
#' html 逐个跑一遍，于是"生成出来的 html 文件"本身就是完整的 —— 用户从
#' 工作区里直接拷走、或者打个包发给别人，不依赖任何附带文件夹。
#'
#' ⚠️ 先写临时文件再 `file.rename`：报告是用户唯一要留档的东西，
#'    "写了一半进程没了"留下一个半截 HTML 比不改还糟（下一次预览就是
#'    一个残缺的页面，而且没有任何地方说得出它是残缺的）。
#'    rename 在同一个目录内是原子的，中途失败那份**原文**还在。
#'
#' ⚠️ 只有真的换掉了东西才落盘。一处都换不掉（比如报告本来就是自包含的）
#'    时**必须原样不动** —— 否则每跑一次任务就要把这个文件的 mtime 改一遍，
#'    界面上按时间排序会莫名其妙地跳，同步那边也会以为它变了。
#'
#' @return list(ok, n, bytes, msg)
dsapp_html_selfcontain_file <- function(path, base_dir = dirname(path)) {
  if (is.null(path) || !file.exists(path)) {
    return(list(ok = FALSE, n = 0L, bytes = 0, msg = "文件不存在"))
  }
  # ⚠️ 软链**只读不改**。工作区里的产物常常是指向管理区的软链（实测数据
  #    就是这样，见 dsapp_md_deps 里那段），而下面那句 file.rename 换掉的
  #    是**软链本身**（rename 不跟软链），于是工作区里会冒出一个真的文件、
  #    和管理区那份从此各走各的 —— 界面上看不出任何区别，直到用户发现
  #    "我改的怎么没同步过去"。
  #    这和 dsapp_zip_plan 跳过软链是同一条理由：镜像进来的东西不是本地
  #    的产物，不该在本地被改写。
  #    代价：软链的那份报告在盘上不是自包含的。但预览和下载那两条路照样
  #    给的是内联过的内容（它们读内容、不落盘），用户拿到的仍然完整。
  #    所以这里返回 ok=TRUE、n=0 —— 是"不用改"，不是"改失败了"。
  if (dsapp_is_link(path)) {
    return(list(ok = TRUE, n = 0L, bytes = 0, msg = ""))
  }
  r <- dsapp_html_read_inlined(path, base_dir)
  if (!isTRUE(r$ok)) return(list(ok = FALSE, n = 0L, bytes = 0, msg = r$msg))
  if (r$n <= 0) return(list(ok = TRUE, n = 0L, bytes = 0, msg = ""))
  tmp <- paste0(path, ".dsapp-inline-", Sys.getpid())
  write_ok <- tryCatch({
    # 二进制方式写 + 自己 enc2utf8：内容已经是 UTF-8 字符，用文本连接按
    # 本地编码再转一次会把报告里的中文全部写坏（本机 locale 未必是 UTF-8）。
    con <- file(tmp, open = "wb")
    on.exit(close(con), add = TRUE)
    writeBin(charToRaw(enc2utf8(r$html)), con)
    TRUE
  }, error = function(e) FALSE)
  if (!isTRUE(write_ok)) {
    try(unlink(tmp), silent = TRUE)
    return(list(ok = FALSE, n = 0L, bytes = 0, msg = "写入失败"))
  }
  ok <- tryCatch(file.rename(tmp, path), error = function(e) FALSE)
  if (!isTRUE(ok)) {
    try(unlink(tmp), silent = TRUE)
    return(list(ok = FALSE, n = 0L, bytes = 0, msg = "替换失败"))
  }
  list(ok = TRUE, n = r$n, bytes = r$bytes, msg = "")
}

#' 把一次任务产出的 html 全部自包含化（★ V14 item 3）
#'
#' 挂在任务收尾（R/taskrun.R 的 dsapp_task_closeout）上，**在落库和同步之前**：
#' 这两步都会记录文件大小，先改完再记，记录里的数字才是用户下载到的那个。
#'
#' ⚠️ 只碰 `.html` / `.htm`。`.md` 那条路是**下载时**打包（见
#'    dsapp_md_deps）—— markdown 没法把图片塞进正文（塞进去就成 base64
#'    文本墙了），只能连文件一起给。
#'
#' ⚠️ 全程 tryCatch：任务已经跑完了，这里出任何错都不能把结果毁掉，
#'    最多是那一份报告没被内联（预览那一步还有第二次机会）。
#'
#' @param names 产物名（工作区相对路径）
#' @return list(n = 改了几份, imgs = 一共内联了几张, bytes = 内联进去多少)
dsapp_ws_selfcontain_html <- function(workdir, names) {
  out <- list(n = 0L, imgs = 0L, bytes = 0)
  if (is.null(workdir) || is.na(workdir) || !dir.exists(workdir)) return(out)
  nm <- as.character(names %||% character(0))
  nm <- nm[!is.na(nm) & nzchar(nm)]
  nm <- nm[grepl("\\.html?$", nm, ignore.case = TRUE)]
  if (!length(nm)) return(out)
  root <- tryCatch(normalizePath(workdir, mustWork = TRUE),
                   error = function(e) NA_character_)
  if (is.na(root)) return(out)
  for (n in nm) {
    rel <- dsapp_html_rel(n)
    if (is.null(rel)) next
    p <- file.path(root, rel)
    if (!file.exists(p) || isTRUE(file.info(p)$isdir)) next
    r <- tryCatch(dsapp_html_selfcontain_file(p, dirname(p)),
                  error = function(e) NULL)
    if (is.null(r) || !isTRUE(r$ok) || r$n <= 0) next
    out$n <- out$n + 1L
    out$imgs <- out$imgs + as.integer(r$n)
    out$bytes <- out$bytes + as.numeric(r$bytes %||% 0)
  }
  out
}

#' 从 markdown 里找出它**依赖的本地文件**（★ V14 item 3）
#'
#' 用户原话：「对应的 md 文件下载时需要把依赖的文件一起打包下载」。
#' markdown 引图有两种写法，两种都要认：
#'   · 行内的 `![说明](figures/a.png)` —— 最常用；
#'   · 引用式 `![说明][id]` + 文末的 `[id]: figures/a.png` —— 模型写长报告
#'     时偶尔会用（一张图引两次的时候省事）。
#'   外加 HTML 那套 `<img src="...">`：md 里直接嵌 HTML 是合法的，而这个
#'   应用给模型的提示词里恰好就出现过 `<img src="相对路径">` 的说法。
#'
#' @param path markdown 文件
#' @param root 打包的根（zip 内的路径按它算）
#' @return 相对 `root` 的路径向量（**不含 md 自己**，调用方补上）；顺序稳定
#'         且去重，这样同一个报告两次下载打出来的包内容一致。
dsapp_md_deps <- function(path, root) {
  if (is.null(path) || !file.exists(path)) return(character(0))
  root_abs <- tryCatch(normalizePath(root, mustWork = TRUE),
                       error = function(e) NA_character_)
  if (is.na(root_abs)) return(character(0))
  txt <- tryCatch(paste(readLines(path, warn = FALSE, encoding = "UTF-8"),
                        collapse = "\n"), error = function(e) NULL)
  if (is.null(txt) || !nzchar(txt)) return(character(0))

  # md 在 root 下的**词法**位置。
  #
  # ⚠️ 这里只 normalize 到 **dirname**，最后一段（basename）原样留着 ——
  #    这是本文件里第三次踩同一个坑，写清楚免得下次又绕回来：
  #    工作区里的产物常常是**指向管理区的软链**
  #    （`生成分析GLM测试-0641/分析报告.md -> data/files/u1/.../分析报告.md`，
  #    实测数据就是这样）。对**整个**路径做 normalizePath 会跟着软链跳到
  #    管理区去，于是"这个 md 在工作区里的位置"变成管理区的位置，下面
  #    所有相对 root 的判断全部落空 —— 表现是**这份 md 明明有 5 张图，
  #    却算出来 0 个依赖**，而且一声不响。
  #    dirname 不会被最后一段的软链带走（父目录是工作区里真实的目录）。
  md_base <- basename(path)
  pdir <- tryCatch(normalizePath(dirname(path), mustWork = TRUE),
                   error = function(e) NULL)
  md_rel <- if (is.null(pdir) || !startsWith(pdir, root_abs)) {
    md_base                                     # 说不清在哪，当成就在 root 下
  } else if (identical(pdir, root_abs)) {
    md_base
  } else {
    paste0(substring(pdir, nchar(root_abs) + 2L), "/", md_base)
  }
  md_dir_rel <- dirname(md_rel)
  if (identical(md_dir_rel, ".")) md_dir_rel <- ""

  cand <- character(0)
  grab <- function(pat, txt, group = 2L) {
    m <- gregexpr(pat, txt, perl = TRUE, ignore.case = TRUE)
    hits <- regmatches(txt, m)[[1]]
    if (!length(hits) || identical(hits, character(0))) return(character(0))
    vapply(hits, function(h) {
      a <- regmatches(h, regexec(pat, h, perl = TRUE, ignore.case = TRUE))[[1]]
      if (length(a) < group) "" else a[[group]]
    }, character(1), USE.NAMES = FALSE)
  }
  # ![alt](target "title")  —— 尖括号那种 ![alt](<a b.png>) 也认
  cand <- c(cand, grab("!\\[[^\\]]*\\]\\(\\s*<?([^\\s>)]+)[^)]*\\)", txt, 2L))
  # [id]: target —— ⚠️ 要 `(?m)`：引用式定义在文末，每一条都另起一行，
  # 不加多行模式的话 `^` 只认整篇的开头，一条都匹配不上。
  cand <- c(cand, grab("(?m)^\\s*\\[[^\\]]+\\]:\\s*<?([^\\s>]+)", txt, 2L))
  # <img src="target">
  cand <- c(cand, grab("<img\\b[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']", txt, 2L))

  cand <- cand[!is.na(cand) & nzchar(cand)]
  if (!length(cand)) return(character(0))

  out <- character(0)
  for (c1 in cand) {
    rel <- dsapp_html_rel(sub("[?#].*$", "", utils::URLdecode(c1)))
    if (is.null(rel)) next
    # 先在 md 自己的目录里找，找不到再退回 root（模型把图放在工作区根、
    # 报告写在子目录里是常事）。两条路都用**词法**拼接 + 词法归一化 ——
    # `dsapp_html_rel` 会把 `..` 消掉，跑出 root 的一律返回 NULL，
    # 所以下面的 cand_rel 一定是落在 root 里面的一条干净相对路径
    #（zip slip 那条路在这里就被堵住了，不用再比一次 realpath）。
    for (cand_rel in unique(c(
        if (nzchar(md_dir_rel)) paste0(md_dir_rel, "/", rel) else rel,
        rel))) {
      got <- dsapp_html_rel(cand_rel)
      if (is.null(got)) next
      p <- file.path(root_abs, got)
      # file.exists 是**跟软链**的（这正是我们要的：镜像进来的输入照样算
      # 依赖），而上面拼出来的名字是词法的（这正是 zip 里要的）。
      if (!file.exists(p) || isTRUE(file.info(p)$isdir)) next
      out <- c(out, got)
      break
    }
  }
  unique(out)
}

#' 点下载时"到底给用户什么"（★ V14 item 3）
#'
#' 三种结果，`filename()` 和 `content()` 两处都按 `kind` 分支：
#'   · `file` —— 原样一个文件（绝大多数情况）；
#'   · `html` —— 先内联图片再给。**单独发出去也完整**，这正是 item 3 要的；
#'   · `zip`  —— 这个文件 + 它依赖的本地文件，打成一个包（markdown 专用）。
#'
#' ⚠️ 这三条判断必须在**取下载内容之前**做定，不能等 `content()` 里再看 ——
#'    因为下载名是 `filename()` 单独算的，两边对不上就是"名字叫 .md、
#'    内容是 zip"这种文件，用户双击打不开，而且看不出是谁的错。
#'
#' ⚠️ markdown **没有**"内联"这条路：图片塞进正文只能是 base64 文本墙，
#'    那已经不是一份能读的 markdown 了。所以 md 只能连文件一起打包
#'    （用户原话就是这么要求的：「对应的 md 文件下载时需要把依赖的文件
#'    一起打包下载」）。
#'
#' @param path 盘上的绝对路径
#' @param root 打包的根（zip 内的相对路径按它算）
#' @param rel  `path` 相对 `root` 的路径。给 NULL 时按路径前缀现推 ——
#'        但**能传就传**：推的那条路要 normalizePath，而工作区里的产物
#'        常常是指向管理区的软链（见 dsapp_md_deps 里那段），推出来会跑偏。
#' @return list(kind, path, name, rel, n, bytes, root)
dsapp_dl_plan <- function(path, root, rel = NULL, name = basename(path)) {
  out <- list(kind = "file", path = path, name = name)
  if (is.null(path) || !file.exists(path) || isTRUE(file.info(path)$isdir)) {
    return(out)
  }
  if (is.null(rel) || !length(rel) || is.na(rel[[1]]) || !nzchar(rel[[1]])) {
    root_abs <- tryCatch(normalizePath(root, mustWork = TRUE),
                         error = function(e) NA_character_)
    pdir <- tryCatch(normalizePath(dirname(path), mustWork = TRUE),
                     error = function(e) NULL)
    rel <- if (is.null(pdir) || is.na(root_abs) || !startsWith(pdir, root_abs)) {
      name
    } else if (identical(pdir, root_abs)) {
      name
    } else {
      paste0(substring(pdir, nchar(root_abs) + 2L), "/", name)
    }
  } else {
    rel <- rel[[1]]
  }

  # ---- HTML：内联之后才给 ----
  if (grepl("\\.html?$", name, ignore.case = TRUE)) {
    return(list(kind = "html", path = path, name = name))
  }

  # ---- markdown：连依赖一起打包 ----
  if (grepl("\\.(md|markdown)$", name, ignore.case = TRUE)) {
    deps <- tryCatch(dsapp_md_deps(path, root), error = function(e) character(0))
    if (length(deps)) {
      rels <- unique(c(rel, deps))
      bytes <- 0
      for (r in rels) {
        b <- suppressWarnings(file.size(file.path(root, r)))
        if (!is.na(b)) bytes <- bytes + b
      }
      return(list(kind = "zip", rel = rels, n = length(rels), bytes = bytes,
                  root = root,
                  name = sprintf("%s-含依赖.zip",
                                 tools::file_path_sans_ext(name))))
    }
  }
  out
}

#' 下载落盘的最后一步：按 plan 把内容写进 `file`（★ V14 item 3）
#'
#' 三个下载处理器（工作区产物 / 管理区 / 对话产物）共用这一份，免得
#' "内联"这件事在某一处被漏掉 —— 那会是"从文件页下载是好的、从对话页
#' 下载就裂了"这种最难查的差异。
#'
#' @return list(ok, msg)
dsapp_dl_write <- function(file, d) {
  d <- d %||% list()
  if (identical(d$kind, "zip")) {
    return(dsapp_zip_write(file, list(ok = TRUE, rel = d$rel, n = d$n,
                                      bytes = d$bytes), d$root))
  }
  if (identical(d$kind, "html")) {
    r <- tryCatch(dsapp_html_read_inlined(d$path, dirname(d$path)),
                  error = function(e) NULL)
    if (is.null(r) || !isTRUE(r$ok) || is.null(r$html)) {
      # 内联这条路走不通就**原样给**：用户要的是那份报告，给一份
      # "图片可能裂"的报告，比给一个下载失败强。
      ok <- tryCatch(file.copy(d$path, file), error = function(e) FALSE)
      return(list(ok = isTRUE(ok), msg = ""))
    }
    ok <- tryCatch({
      con <- file(file, open = "wb")
      on.exit(close(con), add = TRUE)
      writeBin(charToRaw(enc2utf8(r$html)), con)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(ok)) {
      ok2 <- tryCatch(file.copy(d$path, file), error = function(e) FALSE)
      return(list(ok = isTRUE(ok2), msg = ""))
    }
    return(list(ok = TRUE, msg = ""))
  }
  ok <- tryCatch(file.copy(d$path, file), error = function(e) FALSE)
  list(ok = isTRUE(ok), msg = "")
}

# ---- 压缩包 ----------------------------------------------------------------

#' 是不是压缩包，是哪种
#'
#' 只认这几种，不做"看起来像就试一下"：解压是要落盘的写操作，格式判断错了
#' 的代价是用户在工作区里得到一个半截目录。
dsapp_archive_kind <- function(name) {
  n <- tolower(basename(name))
  if (grepl("\\.zip$", n)) return("zip")
  if (grepl("\\.(tar|tar\\.gz|tgz|tar\\.bz2|tbz|tbz2|tar\\.xz|txz)$", n)) {
    return("tar")
  }
  NA_character_
}

#' 压缩包里的条目名安不安全
#'
#' 挡 zip-slip：条目名写成 `/etc/cron.d/x` 或 `../../../home/shiny/.ssh/x`
#' 时，解压会把文件写到目标目录外面。这是压缩包最经典的攻击面。
dsapp_archive_entry_ok <- function(e) {
  if (is.na(e) || !nzchar(e)) return(FALSE)
  e <- gsub("\\\\", "/", e)          # Windows 打的包用反斜杠
  if (startsWith(e, "/")) return(FALSE)
  if (grepl("^[A-Za-z]:", e)) return(FALSE)
  parts <- strsplit(e, "/", fixed = TRUE)[[1]]
  !any(parts == "..")
}

#' 把共享区里的压缩包解到对话工作区
#'
#' 解到**工作区**而不是共享区，两个原因：
#'   1. 共享区是平铺的。一个 GSE 包里几百上千个文件倒进去，「文件」页就没法
#'      看了，模型看到的文件清单也会被淹掉（见本文件顶部的说明）。
#'   2. 解出来的东西是**拿来分析的**，而分析在对话工作区里跑。解完就能直接
#'      用，不用再"从共享区软链进来"。
#'
#' 安全上的四道处理，见下面各处的注释：先验条目名、隔离目录里解、删掉所有
#' 符号链接、解开后按体积和条目数再卡一次。
#'
#' @return list(ok, msg, dir, n, bytes, links)
dsapp_archive_extract <- function(name, sid, cfg = dsapp_config(),
                                  user_id = NULL) {
  # ★ V13 item 6：管理区按账号分了，包在**这个对话主人的**区里。调用方给的
  #   cfg 往往是全局那个（files_dir 指向空的 _anon），不在这里重新钉一次
  #   账号的话，用户在自己的对话里点「解压」，永远得到"文件不存在或名称
  #   非法" —— 而那个包就明明白白列在旁边的文件选择框里。
  #
  # ⚠️ user_id 优先于 sid：管理页那种"没有对话、只有账号"的场景走前者。
  if (!is.null(user_id) && length(user_id) && !is.na(suppressWarnings(as.integer(user_id)))) {
    cfg <- dsapp_config_user(user_id, cfg)
  } else if (!is.null(sid)) {
    cfg <- dsapp_config_sid(sid, cfg)
  }
  src <- dsapp_file_path(name, cfg)
  if (is.null(src)) return(list(ok = FALSE, msg = "文件不存在或名称非法"))

  kind <- dsapp_archive_kind(name)
  if (is.na(kind)) {
    return(list(ok = FALSE,
                msg = "只认得 .zip 和 .tar / .tar.gz / .tgz / .tar.bz2 / .tar.xz"))
  }

  ws <- dsapp_ws_dir(sid, cfg, create = TRUE)
  if (is.na(ws)) {
    return(list(ok = FALSE,
                msg = "先在「言出法随」页打开一个对话 —— 压缩包会解到那个对话的工作区里"))
  }

  # ---- 1. 先看清单，解压之前就知道里面有什么 -------------------------------
  listing <- tryCatch(
    if (kind == "zip") utils::unzip(src, list = TRUE) else NULL,
    error = function(e) NULL)
  entries <- tryCatch(
    if (kind == "zip") listing$Name else utils::untar(src, list = TRUE),
    error = function(e) NULL)
  if (is.null(entries) || !length(entries)) {
    return(list(ok = FALSE,
                msg = "读不出内容：包可能损坏，或者扩展名和实际格式对不上"))
  }

  bad <- entries[!vapply(entries, dsapp_archive_entry_ok, logical(1))]
  if (length(bad)) {
    # 不做"跳过坏条目、解其余"：包里有这种条目本身就说明它不是正常打出来的，
    # 部分解压只会让人以为"解成功了"，然后在后面某个步骤上莫名其妙地失败。
    return(list(ok = FALSE, msg = sprintf(
      "拒绝解压：%d 个条目的路径不安全（绝对路径或带 .. 跳级），例如「%s」",
      length(bad), substr(bad[[1]], 1, 60))))
  }

  if (length(entries) > cfg$extract$max_files) {
    return(list(ok = FALSE, msg = sprintf(
      "拒绝解压：包里有 %d 个条目，超过上限 %d。生信数据建议先在外面裁好再传。",
      length(entries), cfg$extract$max_files)))
  }

  # zip 的清单里带原始大小，解之前就能拦；tar 拿不到（GNU tar 的 -tvf 输出
  # 要解析，格式随版本和 locale 变），它的上限靠解开之后再卡一次。
  if (kind == "zip" && !is.null(listing$Length)) {
    declared <- sum(as.numeric(listing$Length), na.rm = TRUE)
    if (declared > cfg$extract$max_bytes) {
      return(list(ok = FALSE, msg = sprintf(
        "拒绝解压：包里声明的大小是 %s，超过上限 %s",
        dsapp_fmt_bytes(declared), dsapp_fmt_bytes(cfg$extract$max_bytes))))
    }
  }

  # ---- 2. 在隔离目录里解 ---------------------------------------------------
  # 临时目录建在**工作区里面**，不是 tempfile() 默认的 /tmp：
  #   * 同一个文件系统，最后一步是 rename 而不是跨设备拷贝（几个 G 要拷很久）
  #   * 占的磁盘算在这个对话头上，管理页看得见；写到 /tmp 上是把系统盘写满
  #   * 名字以点开头，dsapp_ws_files() 不会把它列出来
  tmp <- tempfile(pattern = ".dsapp_extract_", tmpdir = ws)
  dir.create(tmp, recursive = TRUE, showWarnings = FALSE)
  # on.exit 兜底：中途 return（下面每一个失败分支）都要把半截目录清掉，
  # 否则失败一次就在工作区里留一堆垃圾文件。
  on.exit(unlink(tmp, recursive = TRUE, force = TRUE), add = TRUE)

  warn <- NULL
  tryCatch(
    withCallingHandlers({
      if (kind == "zip") utils::unzip(src, exdir = tmp)
      else utils::untar(src, exdir = tmp)
    }, warning = function(w) {
      # GNU tar 解不开某个条目时发的是 **warning**（"returned error code 2"），
      # 不是 error；zip 那边的坏条目也可能是 warning。不能一律当致命错误 ——
      # 有些包上挂着无害的扩展头，tar 也要念叨一句。记下来，最后如实报。
      warn <<- conditionMessage(w)
      invokeRestart("muffleWarning")
    }),
    error = function(e) { warn <<- conditionMessage(e) })

  # ---- 3. 符号链接一律删掉 -------------------------------------------------
  # untar 走的是系统的 GNU tar，**会**把包里的软链原样建出来；R 内置的
  # unzip 不认软链（把链接当普通文件写出内容，反而是安全的）。
  # 工作区里留一个指向 /etc 或别人目录的软链，等于给下一步模型写的代码
  # 开了个穿出去的口子 —— 它读到的会是那个位置的内容。
  # 不挑"只删指向外面的"：判断软链指向哪里要 realpath 逐条比对，容易漏；
  # 压缩包里本来就极少有正当的软链，一律删掉最简单也最安全。
  #
  # ⚠️ 用 `find -type l`，**不能**用 list.files(recursive = TRUE)：
  #    后者会跟着目录软链递归下去，包里放一个 `loop -> .` 就能让它无限
  #    展开（实测 40 层还在往下走）。find 默认不跟软链。
  links <- character(0)
  lout <- tryCatch(
    suppressWarnings(system2("find", c(shQuote(tmp), "-type", "l"),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  links <- lout[nzchar(lout)]
  for (p in links) unlink(p, recursive = FALSE, force = TRUE)

  # ---- 4. 解开之后按实际体积和条目数再卡一次 -------------------------------
  fout <- tryCatch(
    suppressWarnings(system2("find", c(shQuote(tmp), "-type", "f"),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  files <- fout[nzchar(fout)]

  if (!length(files)) {
    return(list(ok = FALSE, msg = paste0(
      "解开后一个文件都没有。",
      if (!is.null(warn)) paste0("解压程序说：", substr(warn, 1, 200)) else "")))
  }
  if (length(files) > cfg$extract$max_files) {
    return(list(ok = FALSE, msg = sprintf(
      "拒绝解压：实际解出 %d 个文件，超过上限 %d", length(files), cfg$extract$max_files)))
  }
  total <- sum(file.size(files), na.rm = TRUE)
  if (total > cfg$extract$max_bytes) {
    return(list(ok = FALSE, msg = sprintf(
      "拒绝解压：实际解出 %s，超过上限 %s。整个包都没留下。",
      dsapp_fmt_bytes(total), dsapp_fmt_bytes(cfg$extract$max_bytes))))
  }

  # ---- 4.5 配额 ------------------------------------------------------------
  # 放在**搬进工作区之前**：这时东西还在临时目录里，拒绝的代价是删掉一个
  # 临时目录；搬进去之后再拒绝，就得反过来把它删出来，而删的过程中
  # 用户看到的是"文件出现了又消失了"。
  #
  # 这一步和上面的 max_bytes 是两回事：那是**全站**的单次上限（保护机器），
  # 这是**这个账号**的累计上限（分配额度）。两个都要过。
  q <- dsapp_quota_check(user_id, total,
                         what = sprintf("解压「%s」", basename(name)), cfg = cfg)
  if (!isTRUE(q$ok)) {
    return(list(ok = FALSE, msg = q$msg))
  }

  # ---- 5. 搬进工作区 -------------------------------------------------------
  tops <- list.files(tmp, all.files = TRUE, no.. = TRUE)
  if (!length(tops)) {
    return(list(ok = FALSE, msg = "压缩包解开之后是空的"))
  }

  # `tar czf x.tgz mydir` 是最常见的打法，包里通常只有一个顶层目录。
  # 那种情况下直接用它的名字，不再套一层 —— 否则每个包都白白多一级
  # 「GSE123.tar/GSE123/…」。
  if (length(tops) == 1 && dir.exists(file.path(tmp, tops))) {
    target <- dsapp_unique_path(ws, dsapp_safe_name(tops))
    moved <- tryCatch(file.rename(file.path(tmp, tops), target),
                      error = function(e) FALSE)
    if (!isTRUE(moved)) {
      return(list(ok = FALSE, msg = "解压结果搬进工作区时失败（可能磁盘满了）"))
    }
  } else {
    stem <- sub("\\.(zip|tar|tar\\.gz|tgz|tar\\.bz2|tbz|tbz2|tar\\.xz|txz)$",
                "", basename(name), ignore.case = TRUE)
    target <- dsapp_unique_path(ws, dsapp_safe_name(stem))
    if (!dir.create(target, recursive = TRUE, showWarnings = FALSE)) {
      return(list(ok = FALSE, msg = "在工作区里建目录失败"))
    }
    for (t in tops) {
      file.rename(file.path(tmp, t), file.path(target, t))
    }
  }

  # msg 成功时也要有：调用方和自检都拿它当"这次干了什么"的一句话。
  # ⚠️ 少一个字段不会报错 —— `sprintf("%s", NULL)` 给的是 character(0)，
  #    界面上就是一句空白的提示，测试里就是一条**不打印名字的通过**。
  list(ok = TRUE, dir = basename(target), n = length(files), bytes = total,
       links = length(links), warn = warn,
       msg = sprintf("已解出 %d 个文件（%s）到「%s」%s",
                     length(files), dsapp_fmt_bytes(total), basename(target),
                     if (length(links))
                       sprintf("；%d 个符号链接被丢弃（安全策略）", length(links))
                     else ""))
}

#' 保存上传文件
#'
#' 分块读写，不用 file.copy —— 上传的文件可能上 G，一次性读进内存会炸。
#'
#' @param rel V9 item 12：浏览器报回来的**相对路径**（文件夹上传时形如
#'   `16S分析/otu_table.csv`，普通上传时就是文件名或 NULL）。给定时，
#'   中间那些目录会在共享区里按原样建出来。
#'   ⚠️ 不能用 `upload$name` 代替：Shiny 服务端的
#'   FileUploadOperation$fileBegin 里有 `basename(.currentFileInfo$name)`，
#'   目录成分在**服务端**就被丢掉了，`upload$name` 里永远只有文件名。
#'   相对路径是从另一条输入（见 www/app.js 的 dsapp-dirupload）来的。
dsapp_file_save <- function(upload, cfg = dsapp_config(), user_id = NULL,
                            dir = "", rel = NULL) {
  if (is.null(upload)) return(list(ok = FALSE, msg = "没有收到文件"))

  # 上传到当前所在的那一层（V5 起共享区有子目录）。dir 是浏览器发来的，
  # 所以在拼路径之前先过 dsapp_path_in —— 它会把 `..`、绝对路径和软链
  # 一律挡掉。
  parts <- dsapp_rel_segments(dir)
  if (is.null(parts)) return(list(ok = FALSE, msg = "目标文件夹不合法"))
  dest_dir <- dsapp_path_in(cfg$files_dir, parts, must_exist = TRUE)
  if (is.null(dest_dir) || !dir.exists(dest_dir)) {
    # 目录在用户填名字的这段时间里被删了。回到根目录上传，但**要说一声** ——
    # 默默存到别处比失败更糟：用户会在当前这一层里找不到刚传的文件。
    dest_dir <- cfg$files_dir
    dir <- ""
    parts <- character(0)
  }

  # ---- 文件夹上传：还原目录结构（V9 item 12）----
  #
  # rel 是浏览器给的，等价于"用户输入"，所以走和 dir 完全一样的那道门：
  # dsapp_rel_segments 逐段校验（`..`、绝对路径、以 `-` 开头、需要清洗的
  # 名字一律拒），一段都不许它改动。
  #
  # 只取**目录部分**（去掉最后一段），文件名仍旧用 Shiny 给的 upload$name：
  # 两者在正常情况下一模一样（Shiny 那边就是 basename），但 name 是
  # 上传流程自己那个字段，用它更不容易和 datapath 对不上。
  sub <- character(0)
  if (!is.null(rel) && length(rel) == 1 && !is.na(rel) && nzchar(rel)) {
    seg <- dsapp_rel_segments(rel)
    if (is.null(seg)) {
      # 相对路径非法 —— 不静默降级成"平铺到当前目录"。用户选的是文件夹，
      # 平铺的结果是一堆散文件，看起来像是传成功了，实则结构没了。
      return(list(ok = FALSE,
                  msg = sprintf("路径不合法，已跳过：%s", upload$name)))
    }
    if (length(seg) > 1) sub <- seg[-length(seg)]
  }

  # 配额：共享区落盘是三个写入点之一（另两个是解压和开始执行）。
  # ⚠️ 必须在 file.copy **之前**判 —— 先写再检查，那几十 G 已经在盘上了，
  #    检查通过与否都改变不了磁盘要满的事实。
  #
  # 用实际字节数（file.size(datapath)）而不是声称的大小：上传的临时文件
  # 就在本地，量它是一瞬间的事，而且它是真的。
  in_bytes <- suppressWarnings(file.size(upload$datapath))
  if (is.na(in_bytes)) in_bytes <- 0
  q <- dsapp_quota_check(user_id, in_bytes, what = sprintf("上传「%s」", upload$name),
                         cfg = cfg)
  if (!isTRUE(q$ok)) return(list(ok = FALSE, msg = q$msg))

  # 中间目录按需建。must_exist = FALSE 走的是 dsapp_path_in 里"往上找到
  # 第一个存在的祖先再 normalize"那条分支 —— 多层新目录（a/b/c）的第一层
  # 本来就还不存在，直接 normalizePath 会失败。
  if (length(sub)) {
    sub_dir <- dsapp_path_in(cfg$files_dir, c(parts, sub), must_exist = FALSE)
    if (is.null(sub_dir)) {
      return(list(ok = FALSE, msg = sprintf("路径不合法，已跳过：%s", upload$name)))
    }
    if (!dir.exists(sub_dir)) {
      ok_dir <- tryCatch({
        dir.create(sub_dir, recursive = TRUE, showWarnings = FALSE)
        dir.exists(sub_dir)
      }, error = function(e) FALSE)
      if (!isTRUE(ok_dir)) {
        return(list(ok = FALSE,
                    msg = sprintf("建不出目录「%s」，已跳过：%s",
                                  paste(sub, collapse = "/"), upload$name)))
      }
    }
    # 建完再校验一次（must_exist = TRUE）：新目录是刚创建的，这一步顺带
    # 把真实路径取回来，后面拼 dest 用的是它。
    sub_dir <- dsapp_path_in(cfg$files_dir, c(parts, sub), must_exist = TRUE)
    if (is.null(sub_dir)) {
      return(list(ok = FALSE, msg = sprintf("路径不合法，已跳过：%s", upload$name)))
    }
    dest_dir <- sub_dir
  }

  dest <- dsapp_unique_path(dest_dir, upload$name)

  ok <- tryCatch({
    file.copy(upload$datapath, dest, overwrite = FALSE)
  }, error = function(e) FALSE)

  if (!isTRUE(ok)) {
    return(list(ok = FALSE, msg = sprintf("保存失败：%s", upload$name)))
  }

  # 存成只读：共享区是输入区，防止被脚本同名写出覆盖（详见 dsapp_files_protect）
  dsapp_files_protect(dest)

  # msg 是**相对共享区根目录**的路径，不是 basename：归属表存的也是这个
  # （见 users.R 里 file_owner.name 的说明），上传到子目录时两者必须一致，
  # 否则归属行会指向一个共享区里不存在的名字，文件就成了"无主"（人人可删）。
  all_parts <- c(parts, sub)
  rel <- paste0(if (length(all_parts)) paste0(paste(all_parts, collapse = "/"), "/") else "",
                basename(dest))
  list(ok = TRUE, msg = rel, name = basename(dest),
       path = dest, size = file.info(dest)$size)
}
