# =============================================================================
# conda 环境管理
# =============================================================================
# 用户可以在界面上自己建 conda 环境，然后用那个环境跑分析任务。
#
# ---- 为什么不用 `conda create -n 名字` ----------------------------------------
#
# 这台机器上 conda 装在 /home/biomamba/miniconda3：
#
#     drwxr-xr-x  /home/biomamba              → 其他人可读可进入
#     drwxrwxr-x  /home/biomamba/miniconda3   → 同上
#     drwxrwxr-x  /home/biomamba/miniconda3/envs  → **shiny 不在 biomamba 组，写不进去**
#
# 而应用是以 `shiny` 身份运行的（shiny-server.conf 里的 run_as shiny）。
# 所以 `conda create -n foo` 会在最后一刻因为写不了 envs/ 而失败。
#
# 解法是 `conda create -p <路径>`：直接指定环境目录，绕开命名环境的注册表。
# 同时把包缓存也用 CONDA_PKGS_DIRS 重定向到 shiny 可写的地方 —— 否则
# conda 会去写 /home/biomamba/miniconda3/pkgs，同样失败。
#
# ⚠️⚠️ 但"shiny 可写"**不够**（V13.5 item 5 踩的坑）。libmamba 每次启动都会
#    对 `<CONDA_PKGS_DIRS>/cache` 反复 fchmodat（实测 2.5.0：0775 ↔ 02775
#    来回切几十次），而 POSIX 的 chmod 只认**属主或 root** —— 靠 ACL 拿到
#    rwx 的人照样 EPERM。原来的包缓存是**所有运行身份共用**的
#    `data/conda_pkgs`，属主 biomamba；线上跑在 shiny 下，于是每次建环境：
#
#        critical libmamba filesystem error: cannot set permissions:
#        Operation not permitted [.../data/conda_pkgs/cache]
#
#    chown 给谁都不对（另一个身份就崩）。所以现在按运行身份分目录
#    （`data/conda_pkgs/u<uid>/`，见 config.R 的 conda_pkgs_dir），
#    每个人用的那一份都是自己建的，属主天然正确。
#
# 代价：`conda env list` 看不到这些环境（它们不在 envs/ 下），环境也不会
# 出现在 ~/.conda/environments.txt 里。所以本应用自己维护环境清单，
# 不给用户暴露 conda 原生命令。
#
# ---- 关于 solver -------------------------------------------------------------
#
# 这台机器上是 conda 22.11.1，默认还是老的 classic solver。用它解
# bioconda 的依赖能跑十几分钟甚至解不出来。mamba 也装了，快一个数量级，
# 所以优先用 mamba。见 dsapp_find_solver()。
# =============================================================================

#' 找依赖求解器
#'
#' 优先 mamba（快得多），退回 conda。两者命令行在这里用到的部分完全兼容。
dsapp_find_solver <- function(cfg = dsapp_config()) {
  conda_bin <- cfg$conda$bin
  if (!nzchar(conda_bin) || !file.exists(conda_bin)) {
    return("")
  }
  # mamba 和 conda 装在同一目录下
  mamba_bin <- file.path(dirname(conda_bin), "mamba")
  if (file.exists(mamba_bin) && file.access(mamba_bin, 1) == 0) {
    return(mamba_bin)
  }
  conda_bin
}

#' 建好包缓存目录，并且**确认它归当前运行身份所有**
#'
#' ---- 为什么"能写"还不够（V13.5 item 5）--------------------------------------
#'
#' libmamba 每次启动都对 `<CONDA_PKGS_DIRS>/cache` 反复 `fchmodat`。
#' chmod 的权限判据是 **"进程 euid == 文件属主"**，不是"有没有 w 位" ——
#' 所以一个"我有 rwx（靠 ACL）、但属主是别人"的目录，**能读能写、就是不能
#' chmod**，mamba 一句 `Operation not permitted` 直接 critical 退出。
#'
#' 正常路径下这件事不会发生：`conda_pkgs_dir` 已经是 `u<uid>/` 了（见
#' config.R），谁跑应用谁就是它的属主。这里再查一遍，是因为还有一种情况
#' 会破坏它 —— **有人用 `DSAPP_CONDA_PKGS_DIR` 指到了一份共用缓存**，
#' 或者目录是上一版留下的、属主还是原来那个人。那时候 mamba 会吐一大段
#' C++ 异常，用户看到的是一堆看不懂的英文，而真正该做的那一步
#' （换目录，或者把它 chown 给运行身份）一个字都没提。
#'
#' ⚠️ 只在**真的不是自己**的时候才报错。`file.info()$uname` 取不到时
#'    （网络文件系统、Windows）一律放行 —— 宁可让 mamba 自己去报错，
#'    也不要因为查不出来就把一个本来能用的环境判死。
#' 实际该用的 conda 包缓存目录
#'
#' ★ V13.7 item 2：`DSAPP_CONDA_PKGS_DIR` 指到一份**别人**的缓存时，平台
#'   自己换回默认那份，而不是 `stop()` 摆出"两种修法任选一种"让用户挑。
#'   这件事只有一个正确答案 —— 换成自己那份 —— 所以它是一个决定，
#'   不是一个需要征询的选择。
#'
#' ⚠️ **只在环境变量真的设了的时候才换。** 没设而属主仍然不对，说明整个
#'    数据目录都不是这个身份的，换到哪儿都一样 —— 那种情况必须原样报出来，
#'    假装能自己修只会让用户以为"重试一下就好了"。判定留在调用方。
#'
#' ⚠️ 查不出属主（网络文件系统、Windows）一律不换，理由同下面那条注释：
#'    宁可让 mamba 自己去报错，也不要因为查不出来就把一个本来能用的缓存判死。
dsapp_conda_pkgs_dir <- function(cfg = dsapp_config()) {
  d <- cfg$conda_pkgs_dir
  if (is.null(d) || !nzchar(d)) return(d)
  if (!nzchar(Sys.getenv("DSAPP_CONDA_PKGS_DIR", ""))) return(d)

  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  uname <- tryCatch(file.info(d)$uname, error = function(e) NA_character_)
  if (length(uname) != 1L || is.na(uname) || !nzchar(uname)) return(d)
  me <- tryCatch(as.character(Sys.info()[["user"]]), error = function(e) "")
  if (length(me) != 1L || is.na(me) || !nzchar(me) || identical(uname, me)) {
    return(d)
  }

  # 换回默认那份。它和 config.R 里那个默认值是**同一个表达式** ——
  # 两处写的不一样的话，这里"换回去"就换到了一个谁也不认识的地方。
  fallback <- file.path(cfg$data_root, "conda_pkgs", paste0("u", dsapp_run_id()))
  if (identical(fallback, d)) return(d)   # 已经在默认位置，退无可退

  message(sprintf("[dsapp] DSAPP_CONDA_PKGS_DIR=%s 属主是 %s（当前身份 %s），%s",
                  d, uname, me, "已自动改用默认缓存"))
  tryCatch(
    dsapp_audit("自动改用默认包缓存",
                detail = sprintf("DSAPP_CONDA_PKGS_DIR 指向 %s（属主 %s），非当前身份 %s，已改用 %s",
                                 d, uname, me, fallback)),
    error = function(e) NULL)
  fallback
}

dsapp_conda_pkgs_prepare <- function(cfg = dsapp_config()) {
  d <- dsapp_conda_pkgs_dir(cfg)
  if (is.null(d) || !nzchar(d)) return(invisible(FALSE))
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

  if (!dir.exists(d)) {
    stop(sprintf(paste0(
      "包缓存目录建不出来：%s\n",
      "  当前运行身份：%s\n",
      "  这是**文件系统权限**问题，不是 conda 的问题 —— 让运维把上一级目录\n",
      "  的写权限给到这个身份，或者用 DSAPP_CONDA_PKGS_DIR 指到别处。"),
      d, dsapp_run_id()))
  }

  # 查属主。取不到（NA / 空）就放行，理由见上。
  uname <- tryCatch(file.info(d)$uname, error = function(e) NA_character_)
  if (length(uname) != 1L || is.na(uname) || !nzchar(uname)) return(invisible(TRUE))
  me <- tryCatch(as.character(Sys.info()[["user"]]), error = function(e) "")
  # ⚠️ 比的是**登录名**不是 uid：file.info() 只给名字。两者在正常部署里
  #    是一回事；取不到 me 时同样放行（不猜）。
  if (length(me) != 1L || is.na(me) || !nzchar(me) || identical(uname, me)) {
    return(invisible(TRUE))
  }

  # ★ V13.7 item 2：走到这儿还是"别人的目录"，但**根因分两种**，处理方式
  #   完全不同，不能一起 stop()：
  #
  #     (a) 有人用 DSAPP_CONDA_PKGS_DIR 指到了别人的缓存
  #         → 平台自己换回默认那份（u<uid>/，本来就是自己的），
  #           这件事只有一个正确答案，问用户等于把运维的活推给他。
  #           见上面 dsapp_conda_pkgs_dir()，正常情况下根本走不到这一行。
  #     (b) **默认**那份的属主就不是我们（数据目录整个是别人的）
  #         → 这是真的部署问题，平台换不了（换哪儿都是别人的），
  #           只能报出来。这时才轮到 stop()。
  #
  #   区分判据就是"环境变量有没有设" —— 没设还属主不对，退无可退。
  if (!nzchar(Sys.getenv("DSAPP_CONDA_PKGS_DIR", ""))) {
    stop(sprintf(paste0(
      "数据目录下的包缓存 %s 属主是 %s，而应用以 %s 的身份在跑。\n",
      "  这不是 conda 的问题，是**整个数据目录**的归属问题 —— 换一个缓存\n",
      "  目录也解决不了（换到哪儿都还是这个身份建不出来的位置）。\n",
      "  需要运维把数据目录交给运行身份（chown -R %s <数据目录>），\n",
      "  或者用 DSAPP_DATA_ROOT 指到一个这个身份建得出来的位置。"),
      d, uname, me, me))
  }

  stop(sprintf(paste0(
    "包缓存目录 %s 的属主是 %s，而应用现在以 %s 的身份在跑。\n",
    "  conda/mamba 需要能 chmod 这个目录，而 chmod 只有**属主本人**能做\n",
    "  （有写权限不算）。继续跑只会得到一句 libmamba 的\n",
    "  「cannot set permissions: Operation not permitted」。\n",
    "  两种修法，任选一种：\n",
    "    1) 别共用这一份缓存 —— 把 DSAPP_CONDA_PKGS_DIR 去掉，用回默认的\n",
    "       <数据目录>/conda_pkgs/u<uid>/（每个运行身份一份，互不干扰）；\n",
    "    2) 真要共用，就让运维执行 chown -R %s %s"),
    d, uname, me, me, d))
}

#' 调 conda/mamba 时用的环境变量
#'
#' 全部重定向到 shiny 可写的位置，并且关掉 conda 的自动更新检查
#' （那个会联网、会拖慢启动，在服务器上没意义）。
dsapp_conda_env_vars <- function(cfg = dsapp_config()) {
  dsapp_conda_pkgs_prepare(cfg)
  base <- Sys.getenv()
  vars <- c(
    # ⚠️ 走 dsapp_conda_pkgs_dir() 而不是直接读 cfg$conda_pkgs_dir：
    #    前者会在配置指向别人的缓存时自动换成默认那份（V13.7 item 2）。
    #    两处各读各的，就会出现"prepare 认的是 A、真正传给 conda 的是 B"，
    #    而 mamba 报错时用的是 B —— 查起来会绕很久。
    CONDA_PKGS_DIRS        = dsapp_conda_pkgs_dir(cfg),
    CONDA_ENVS_DIRS        = cfg$envs_root,
    CONDA_ALWAYS_YES       = "true",
    CONDA_AUTO_UPDATE_CONDA = "false",
    # 关掉 conda 每次启动时的 "有新版本" 提示，它会往 stdout 写东西，
    # 混进我们解析的输出里。
    CONDA_AUTO_ACTIVATE_BASE = "false"
  )
  base[names(vars)] <- vars
  base
}

#' 环境名合法性
#'
#' 环境名会变成目录名，所以必须挡住路径穿越（../）和奇怪的字符。
dsapp_env_name_ok <- function(name) {
  if (!is.character(name) || length(name) != 1 || !nzchar(name)) {
    return("环境名不能为空")
  }
  if (nchar(name) > 40) {
    return("环境名最长 40 个字符")
  }
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", name)) {
    return("环境名只能用字母、数字、下划线、点和短横线，且必须以字母或数字开头")
  }
  if (grepl("\\.\\.", name)) {
    return("环境名不能包含连续的点和 ..")
  }
  # 目录名以点开头会被 ls 之类当成隐藏文件，也会和我们的 .trash 冲突
  if (grepl("^\\.", name)) {
    return("环境名不能以点开头")
  }
  ""
}

#' 把用户填的包名列表切成向量
#'
#' 用户会写成 "scanpy seurat" / "scanpy, seurat" / 混着用，都得认。
#'
#' ⚠️ 这里必须 perl = TRUE。R 默认的 TRE 正则**在方括号内不把 \s 当空白**，
#' 而是当字面量 s —— 于是 "[\\s,]+" 的真实含义是"反斜杠、字母 s、逗号"，
#' 按字母 s 切分。"scanpy seurat" 会被切成 "canpy" 和 "eurat"，
#' 用户看到的是两个不存在的包名和一堆莫名其妙的安装失败，
#' 而输入看上去完全正常 —— 这类 bug 不会有人往"正则写错了"上想。
dsapp_split_pkgs <- function(x) {
  x <- trimws(paste(x %||% "", collapse = " "))
  if (!nzchar(x)) return(character(0))
  p <- strsplit(x, "[\\s,]+", perl = TRUE)[[1]]
  p <- trimws(p)
  p[nzchar(p)]
}

#' 单个环境的目录
dsapp_env_path <- function(name, cfg = dsapp_config()) {
  file.path(cfg$envs_root, name)
}

#' 环境是否可用（目录在，且解释器存在）
dsapp_env_exists <- function(name, cfg = dsapp_config()) {
  p <- dsapp_env_path(name, cfg)
  dir.exists(p) && file.exists(file.path(p, "bin", "python"))
}

#' 这个字符串能不能当"选中的环境"用
#'
#' 只认两种：`"system"`，或者**确实存在**的环境目录名。别的（尤其是那句
#' 中文摘要 —— 界面上显示给人看的那串）一律不认。
#'
#' 为什么要有这一道：环境的选项是"显示文本 + 回传值"两截拼出来的，两截
#' 一旦写反（见 utils.R 的 dsapp_choices），控件回传的就是那串**给人看的
#' 描述**。它长得人模人样、能一路写进 state$exec_env、直到执行器查不到这个
#' conda 环境才炸 —— 而那时候报的是"环境不存在"，离真正的原因隔了三层。
#' 这里挡一下，写反了当场就是"不认"，不写进 state。
#'
#' ⚠️ 用 dsapp_envs_list() 而不是 dsapp_env_exists()：后者要求 bin/python
#'    已经在，而**正在构建**的环境还没有它 —— 拿它守门会把用户刚建好、
#'    正等着用的那个环境拒掉。这里要的只是"这个名字是我们列出去过的"。
dsapp_env_selectable <- function(name, cfg = dsapp_config()) {
  if (is.null(name) || length(name) != 1 || is.na(name)) return(FALSE)
  name <- as.character(name)
  if (!nzchar(name)) return(FALSE)
  if (identical(name, "system")) return(TRUE)
  df <- tryCatch(dsapp_envs_list(cfg, sizes = FALSE), error = function(e) NULL)
  !is.null(df) && nrow(df) > 0 && name %in% as.character(df$name)
}

#' 列环境
#'
#' 直接从磁盘读，不查数据库 —— 环境的真实状态就是磁盘上的目录，
#' 让数据库再存一份只会带来不一致。
#'
#' @param sizes 要不要统计每个环境占多大。**默认不要**，见下面的 ⚠️。
dsapp_envs_list <- function(cfg = dsapp_config(), sizes = FALSE) {
  empty <- data.frame(name = character(), path = character(),
                      python = character(), rscript = character(),
                      status = character(), size_mb = numeric(),
                      mtime = character(), stringsAsFactors = FALSE)
  root <- cfg$envs_root
  if (!dir.exists(root)) return(empty)

  dirs <- list.dirs(root, recursive = FALSE, full.names = FALSE)
  # 创建中的环境目录带着 .building 标记，还没成型，不列出来
  dirs <- dirs[!grepl("^\\.", dirs)]
  if (!length(dirs)) return(empty)

  # ⚠️ 统计目录大小是 list.files(recursive = TRUE) + file.info 走一遍**整棵
  # 目录树**。conda 环境动辄几万个文件：实测 archr_env 62699 个文件要 5.9 秒、
  # spaniche_env 70137 个要 6.9 秒。而调用它的两处（对话页的环境下拉框、
  # 设置页的环境下拉框）都挂在 invalidateLater(5000) 上，也就是**每 5 秒
  # 重算一次**；本站是 Shiny Server 开源版，一个应用一个 R 进程、所有访客
  # 共用，几个环境就能让进程把全部时间花在数文件上，谁都用不了。
  #
  # 大小是给人看的装饰性信息，只有「环境」页的表格里显示。所以默认不算，
  # 要算的调用方显式传 sizes = TRUE，并且走下面这个 TTL 缓存。
  sz <- if (sizes) dsapp_env_sizes_cached(dirs, root, cfg) else NULL

  rows <- lapply(dirs, function(d) {
    p  <- file.path(root, d)
    py <- file.path(p, "bin", "python")
    r  <- file.path(p, "bin", "Rscript")
    info <- file.info(p)
    # status：建的成没成、包装没装上。读的是一个小状态文件，很便宜。
    # 设置页的下拉框要拿它把有问题的环境标出来，别等跑到一半才报错。
    #
    # ⚠️ V12 item 4 之前这里写的是 `st$status %||% "ready"`，而**没有任何
    #    地方会往状态文件里写 status** —— 于是这个字段恒等于 "ready"，
    #    界面上那个「构建中」分支从来没出现过。一键建环境上线之后这就成了
    #    真问题：conda 是**一边解依赖一边就把目录建出来**的，一个正在建的
    #    环境会在列表里显示成"可用"，用户点了它去跑任务，撞上一堆
    #    "找不到 numpy"，而没有任何地方提示过它还在建。
    #
    #    现在按**磁盘上的事实**推：作业进程还活着 → 构建中；进程没了、
    #    解释器也不在 → 失败（上次建到一半死了）；解释器在 → 可用。
    #    不写状态文件是因为"谁在什么时候把它改回去"本身就是个坑 ——
    #    应用重启、作业被 kill、用户删目录，每一条都要记得改，漏一条就
    #    永远停在"构建中"。推导出来的值没有这个失效模式。
    st <- tryCatch(dsapp_env_read_status(d, cfg), error = function(e) NULL)
    has_py <- file.exists(py); has_r <- file.exists(r)
    status <- st$status %||% ""
    if (!nzchar(status)) {
      pid <- suppressWarnings(as.integer(st$pid %||% NA))
      status <- if (!is.na(pid) && dsapp_pid_alive(pid)) "building"
                else if (has_py || has_r) "ready"
                else "failed"
    }
    data.frame(
      name    = d,
      path    = p,
      python  = if (has_py) py else "",
      rscript = if (has_r) r else "",
      status  = status,
      size_mb = if (is.null(sz)) NA_real_ else sz[[d]],
      mtime   = if (is.na(info$mtime)) "" else dsapp_fmt_time(info$mtime),
      stringsAsFactors = FALSE
    )
  })

  out <- do.call(rbind, rows)
  out[order(out$name), , drop = FALSE]
}

#' 环境大小，带 TTL 缓存
#'
#' 走一遍目录树太贵（见上面 dsapp_envs_list 的说明），所以算过一次就记着。
#' 缓存放在进程内的 dsapp_state() 里：环境大小是个粗粒度数字，十分钟前的
#' 和现在差不了多少，为此卡住整个进程不值得。装完包想立刻看到新数字的，
#' 重开一次页面即可（缓存跟着应用进程走）。
dsapp_env_sizes_cached <- function(dirs, root, cfg = dsapp_config(),
                                   ttl_sec = 600) {
  st <- dsapp_state()
  if (is.null(st$env_sizes)) st$env_sizes <- new.env(parent = emptyenv())

  now <- as.numeric(Sys.time())
  out <- list()
  for (d in dirs) {
    hit <- st$env_sizes[[d]]
    if (!is.null(hit) && now - hit$at < ttl_sec) {
      out[[d]] <- hit$mb
      next
    }
    p <- file.path(root, d)
    files <- list.files(p, recursive = TRUE, full.names = TRUE, all.files = TRUE)
    mb <- if (length(files)) {
      round(sum(file.info(files)$size, na.rm = TRUE) / 1024^2, 1)
    } else 0
    st$env_sizes[[d]] <- list(mb = mb, at = now)
    out[[d]] <- mb
  }
  out
}

#' 环境里的关键包清单
#'
#' 提示词要用它告诉模型「这个环境里装了什么」，否则模型会凭空
#' library() 一个没装的包。只列用户显式装过的顶层包，不递归。
dsapp_env_packages <- function(name, cfg = dsapp_config()) {
  meta <- file.path(dsapp_env_path(name, cfg), "conda-meta")
  if (!dir.exists(meta)) return(character())
  files <- list.files(meta, pattern = "\\.json$")
  # conda-meta/<pkg>-<ver>-<build>.json，去掉版本和 build
  pkgs <- sub("-[^-]+-[^-]+\\.json$", "", files)
  sort(unique(pkgs[nzchar(pkgs)]))
}

#' 删除环境前的闸门（纯函数）
#'
#' 抽出来是因为这几条拒绝理由**每一条都对应一次真实的误伤**，而它们全在
#' 响应式上下文里（读 engine、读 state），自检够不着。判定本身是纯的，
#' 参数由调用方在响应式上下文里取好再传进来。
#'
#' @param name        要删的环境名
#' @param exists      目录在不在
#' @param busy        有没有 conda 作业在跑（`dsapp_env_busy()`）
#' @param running_env 正在执行的那个任务用的环境名；没有任务在跑就 NULL
#' @return "" 表示可以删；否则是拒绝的理由（直接显示给用户）
dsapp_env_delete_reason <- function(name, exists, busy = FALSE,
                                    running_env = NULL) {
  if (!is.character(name) || length(name) != 1 || !nzchar(name)) {
    return("没有选中环境")
  }
  # 「系统环境」不是一个目录，删不了 —— 它是这台机器上装好的 R / Python。
  # 这一条不能省：界面上它和 conda 环境并排列着，用户很容易顺手选中它。
  if (identical(name, "system")) {
    return("「系统环境」是服务器上装好的 R / Python，不是本应用建的，删不了")
  }
  if (nzchar(dsapp_env_name_ok(name))) return("环境名非法")
  if (!isTRUE(exists)) return("环境不存在")
  # conda 的 solver 很吃 CPU，而且删到一半的目录会让正在跑的 solve 崩掉。
  if (isTRUE(busy)) return("有 conda 作业正在跑，等它结束再删")
  # 任务正在这个环境里执行：删掉的话它会在一半的地方报出莫名其妙的错
  # （找不到解释器、找不到包），而且错在离原因很远的地方。
  if (!is.null(running_env) && !is.na(running_env) &&
      identical(as.character(running_env), name)) {
    return(sprintf("有任务正在用 %s 执行，等它结束再删", name))
  }
  ""
}

#' 删除环境
#'
#' 用 rm -rf 而不是 `conda env remove -p`：后者要先解一遍依赖，慢，而且
#' 对于已经损坏的环境还可能失败。这里就是删目录，没有别的副作用。
#' 走 dsapp_safe_name 再确认一次，杜绝 ../ 之类拼进来的可能。
dsapp_env_delete <- function(name, cfg = dsapp_config()) {
  if (nzchar(dsapp_env_name_ok(name))) {
    return(list(ok = FALSE, msg = "环境名非法"))
  }
  # 二次确认，和下面那个 normalizePath 是一对：这里挡 "system"（它没有目录，
  # 拼出来会是 envs_root/system 这种看着正常的路径），下面挡路径穿越。
  if (identical(name, "system")) {
    return(list(ok = FALSE, msg = "「系统环境」不是本应用建的，删不了"))
  }
  p <- dsapp_env_path(name, cfg)
  # 二次确认：要删的目录必须真的在 envs_root 底下
  if (!identical(normalizePath(dirname(p), mustWork = FALSE),
                 normalizePath(cfg$envs_root, mustWork = FALSE))) {
    return(list(ok = FALSE, msg = "路径校验失败，拒绝删除"))
  }
  if (!dir.exists(p)) {
    return(list(ok = FALSE, msg = "环境不存在"))
  }
  unlink(p, recursive = TRUE, force = TRUE)
  if (dir.exists(p)) {
    return(list(ok = FALSE, msg = "删除失败，可能有进程正在使用该环境"))
  }
  list(ok = TRUE, msg = sprintf("环境 %s 已删除", name))
}

#' 环境创建状态文件
dsapp_env_log_path <- function(name, cfg = dsapp_config()) {
  file.path(cfg$logs_dir, sprintf("env-%s.log", name))
}

dsapp_env_status_path <- function(name, cfg = dsapp_config()) {
  file.path(cfg$logs_dir, sprintf("env-%s.status", name))
}

#' 启动环境创建（非阻塞）
#'
#' ⚠️ 这个方法**会立刻返回**，绝不能在这里等 conda 跑完 ——
#' Shiny Server 开源版一个应用只有一个 R 进程，所有访客共享，
#' 一个同步的 conda solve 会把所有人的页面一起冻住。
#'
#' 返回 list(ok, msg, pid)。
dsapp_env_create <- function(name, packages = character(),
                             python_version = "3.11",
                             channels = c("conda-forge", "bioconda"),
                             cfg = dsapp_config()) {
  bad <- dsapp_env_name_ok(name)
  if (nzchar(bad)) {
    return(list(ok = FALSE, msg = bad))
  }
  if (dsapp_env_exists(name, cfg)) {
    return(list(ok = FALSE, msg = sprintf("环境 %s 已存在", name)))
  }
  if (dsapp_env_busy()) {
    return(list(ok = FALSE, msg = "已有 conda 作业在跑。solver 很吃 CPU，同时跑两个会把机器拖垮，请等它结束。"))
  }

  solver <- dsapp_find_solver(cfg)
  if (!nzchar(solver)) {
    return(list(ok = FALSE, msg = paste0(
      "找不到 conda/mamba。请确认 conda 已安装，",
      "或在 .Renviron 里用 DSAPP_CONDA_BIN 指定完整路径")))
  }

  # 环境名是通过校验了，但目录可能以「创建中」的形式残留（上次失败）
  env_path <- dsapp_env_path(name, cfg)
  if (dir.exists(env_path)) {
    unlink(env_path, recursive = TRUE, force = TRUE)
  }

  # 包清单也要过一遍：用户可能在包名里塞 `; rm -rf /` 这种 shell 注入。
  # conda 是用 argv 直接调的（不经过 shell），本来就注入不了，但包名
  # 里的空格会让 conda 把后面半截当成另一个包名，报出莫名其妙的错。
  packages <- trimws(packages)
  packages <- packages[nzchar(packages)]
  if (length(packages)) {
    bad_pkg <- packages[!grepl("^[A-Za-z0-9][A-Za-z0-9_.:=<>!*+-]*$", packages)]
    if (length(bad_pkg)) {
      return(list(ok = FALSE, msg = sprintf(
        "包名不合法：%s（只能用字母数字和 . _ - = < > ! : * +）",
        paste(bad_pkg, collapse = ", "))))
    }
  }

  if (!grepl("^[0-9]+\\.[0-9]+$", python_version)) {
    return(list(ok = FALSE, msg = "Python 版本格式应为 3.11 这样"))
  }

  ch_args <- as.vector(rbind("-c", channels))
  args <- c("create", "-p", env_path, "-y",
            "--override-channels", ch_args,
            sprintf("python=%s", python_version),
            packages)

  dsapp_env_job_launch(
    name, args,
    header = c(
      sprintf("=== 创建环境 %s ===", name),
      sprintf("求解器：%s", solver),
      sprintf("目标路径：%s", env_path),
      sprintf("Python：%s", python_version),
      sprintf("附加包：%s", if (length(packages)) paste(packages, collapse = " ") else "（无）"),
      sprintf("频道：%s", paste(channels, collapse = ", ")),
      "",
      "依赖解析可能要几分钟到十几分钟（bioconda 的包多，解起来慢）。",
      "这个过程不影响你用其他页面。",
      ""),
    cfg = cfg
  )
}

# =============================================================================
# 环境配置（V12 item 4）
# =============================================================================
# 用户原话：「环境也要像 skills 一样可以自动上传配置，帮我预设单细胞/空转环境」。
#
# 「像 skills 一样」指的是**同一套用法**：界面上给一个上传入口，把一份文本
# 贴进去/传上去，看一遍预览，点一下导入。技能那边导入的是 .md，这边导入的
# 是一份环境配置（环境名 + Python 版本 + 频道 + 包清单）。
#
# 和技能那边**不一样**的地方，也值得写清楚：
#
#   * 技能是**每账号私有**的（每条技能挂在 user_id 上）；conda 环境是
#     **全站共享**的 —— 建出来所有对话都能选它当基础环境。所以界面上必须
#     如实写着"这是共享的"，不能让人以为自己建了一个私有环境。
#   * 建环境要跑 conda solve，几分钟到十几分钟，而且是全站唯一一个 R 进程
#     在跑。所以走的是 envs.R 里那套**后台作业**（dsapp_env_job_launch），
#     点完立刻返回，进度靠轮询日志尾部 —— 绝不能同步等。

#' 内置的环境模板
#'
#' 「帮我预设单细胞/空转环境」—— 预设的是**配置**，不是环境本身：
#' 一键建仍然要跑一次 conda，几十分钟，那是用户自己的决定。
#'
#' 返回一个具名 list，每项是 list(name, python, channels, packages, note)。
#' 包清单放在这里而不是一个数据文件里，是为了让 deploy.sh 那份拷贝清单
#' 自动带上它们 —— 一个独立的 .yaml 目录很容易在部署时被漏掉，而漏掉的
#' 表现是"模板是空的"，界面照常渲染，不报错。
#'
#' ⚠️ 写包名的时候要克制：清单里任何一个包在 conda-forge / bioconda 里解
#'    不出来，整条 `conda create` 会**整体失败**（conda 不做部分安装），
#'    用户等二十分钟换来一句 UnsatisfiableError。所以这里只放主流、
#'    长期在频道里的包；偏门的、需要编译的、体积特别大的（cellpose 要
#'    torch，napari 要 Qt）一律**注释掉**并写上它是什么 —— 用户想要就
#'    自己取消注释，那一步是他自己做的选择。
#'
#' ⚠️ R 那套（Seurat / DESeq2 / Bioconductor 全家）**不在这里**。这台机器
#'    上它们装在系统 R 的 site-library 里（18 GB），任何对话都能直接用。
#'    再在 conda 环境里装一份 r-base + r-seurat，既慢又和系统那套重复，
#'    还会让用户以为"不建这个环境就没有 Seurat"。模板的注释里如实写着。
dsapp_env_templates <- function() {
  list(
    "单细胞" = list(
      name = "scRNA",
      python = "3.11",
      channels = c("conda-forge", "bioconda"),
      note = paste(
        "单细胞转录组（Python 侧）。R 那套（Seurat / DESeq2 / Bioconductor）",
        "系统 R 里已经有了，不用在这里再装一份。"),
      packages = c(
        "scanpy",            # 单细胞分析主库
        "anndata",           # .h5ad 数据结构，scanpy 的地基
        "muon",              # 多模态（CITE-seq / 多组学）
        "scvi-tools",        # 深度学习的整合、注释、去噪
        "harmonypy",         # 批次整合（Harmony）
        "bbknn",             # 批次整合（BBKNN）
        "scrublet",          # 双细胞检测
        "leidenalg",         # Leiden 聚类
        "python-igraph",     # 上面那个的依赖，显式列出免得被解成别的版本
        "umap-learn",        # UMAP 降维
        "scikit-learn",
        "statsmodels",
        "numba",
        "h5py",
        "zarr",
        "loompy",
        "openpyxl",
        "matplotlib",
        "seaborn",
        "pandas",
        "numpy",
        "scipy"
      ),
      # "要的时候再加"的包。它们会以**注释**的形式出现在模板文本里 ——
      # 用户看得到、取消注释就能装，但不会被解析成要装的包（解析器跳过 # 行）。
      # 默认不装是因为装上会让 solve 明显变慢，有的还要 torch。
      optional = c(
        celltypist       = "自动细胞类型注释",
        infercnvpy       = "拷贝数变异推断（肿瘤）",
        decoupler        = "通路 / 转录因子活性",
        cellrank         = "细胞命运推断",
        palantir         = "同上",
        velocyto         = "RNA 速率（要单独跑，和 scanpy 版本耦合紧）",
        `harmony-pytorch` = "大样本的 Harmony（要 torch）",
        gseapy           = "富集分析"
      )
    ),
    "空转" = list(
      name = "spatial",
      python = "3.11",
      channels = c("conda-forge", "bioconda"),
      note = paste(
        "空间转录组（Visium / Xenium / MERFISH / Stereo-seq）。",
        "squidpy 是主库，spatialdata 是新一代的数据结构（10x 官方在推）。"),
      packages = c(
        "squidpy",           # 空转分析主库（邻域富集、共现、形态特征）
        "spatialdata",       # 多模态空转数据结构（Xenium / MERFISH 都走它）
        "spatialdata-io",    # 各家平台格式的读取器
        "spatialdata-plot",  # 静态出图（matplotlib）
        "scanpy",            # squidpy 的地基，也用来做常规单细胞那半
        "anndata",
        "leidenalg",
        "python-igraph",
        "umap-learn",
        "scikit-image",      # 组织图像的基本处理
        "scikit-learn",
        "numba",
        "h5py",
        "zarr",
        "matplotlib",
        "seaborn",
        "pandas",
        "numpy",
        "scipy"
      ),
      optional = c(
        `napari-spatialdata` = "交互式看片子，要 Qt，服务器上跑不起来",
        cellpose             = "细胞分割（要 torch，很重）",
        stardist             = "同上，另一套分割模型",
        cell2location        = "解卷积（要 GPU 才实用）",
        `tangram-sc`         = "空间映射",
        opencv               = "图像配准，需要的话取消注释"
      )
    )
  )
}

#' 把一条模板渲染成可以直接编辑的配置文本
#'
#' 输出的就是 dsapp_envspec_parse() 认得的那种格式 —— 用户看到的、
#' 改的、再传回来的，是**同一份东西**，中间没有第二套表示。
dsapp_env_template_text <- function(tpl) {
  if (is.null(tpl)) return("")
  opt <- tpl$optional %||% character(0)
  # 可选包整行都是注释（`#   - celltypist  # 说明`），不是 `  - # celltypist`
  # —— 后者形式上是个列表项，解析器得专门去认"以 # 开头的包名"，多一处
  # 要维护的规则；行首注释是解析器本来就会跳过的。
  opt_lines <- if (length(opt)) {
    c("",
      "# 下面这些是「要的时候再加」的：去掉行首的 # 和它前面的空格就能装上。",
      sprintf("#   - %-20s # %s", names(opt), unname(opt)))
  } else character(0)
  paste(c(
    sprintf("# %s", tpl$note %||% ""),
    "# 改完点下面的「一键创建」。以 # 开头的行是注释，不会传给 conda。",
    "",
    sprintf("name: %s", tpl$name %||% ""),
    sprintf("python: %s", tpl$python %||% "3.11"),
    sprintf("channels: %s", paste(tpl$channels %||% "conda-forge", collapse = ", ")),
    "",
    "packages:",
    paste0("  - ", tpl$packages %||% character(0)),
    opt_lines
  ), collapse = "\n")
}

#' 内置模板里**还没建**的那几个（V13.4 item 7）
#'
#' ★ 用户原话：「言出法随的环境界面，并没有同步内置环境，选项里只有系统
#'   环境一个」。他的"内置环境"就是「环境」页那个「内置模板」下拉里的
#'   单细胞 / 空转 / …… —— 那几份只是**配置**，磁盘上 `data/envs/` 是空的，
#'   所以言出法随那边的下拉里自然什么都没有。
#'
#' ⚠️ 这个函数的返回值**不能直接当"选中的环境"用**：环境还没建，
#'    `dsapp_env_selectable()` 不认（它是对的，见那里的说明）。所以调用方
#'    要拿它单独分一组显示，选中时走"先建再选"。
#'
#' @param have 已知存在的环境名。★ V13.5 item 6 加的：环境页那张卡片在一次
#'   渲染里已经调过 `dsapp_envs_list()` 了，再让它为了这一行去调第二次，
#'   等于每次重画都多扫一遍 conda 的环境目录。调用方手上现成有名单时就传进来。
#'   NULL（默认）才是自己去查 —— 别的调用方（mod_chat）没有现成的名单。
#'
#' @return 一份 dsapp_env_templates() 的子集（可能长度为 0，不是 NULL）
dsapp_env_templates_pending <- function(cfg = dsapp_config(), have = NULL) {
  tpl <- dsapp_env_templates()
  # ⚠️ 查不到就当成"全都没建"：这里是给下拉框拼选项用的，多列几个
  #    （点下去会走"先建"那条路，不撒谎）比少列几个好。
  if (is.null(have)) {
    have <- tryCatch(as.character(dsapp_envs_list(cfg, sizes = FALSE)$name),
                     error = function(e) character(0))
  }
  have <- as.character(have)
  keep <- vapply(tpl, function(t)
    !(as.character(t$name %||% "") %in% have), logical(1))
  tpl[keep]
}

#' 照内置模板建一个环境（V13.4 item 7）
#'
#' 「环境」页那条创建路径（mod_envs.R 的 spec_create）是**三步**：
#' 拼配置文本 → 解析 → 校验 → 建。言出法随这边只有一个模板对象，没有
#' 编辑器，所以走一条更短的路：模板本身就是结构化的（name / python /
#' channels / packages），直接拼成解析器那个形状，跳过文本这一步。
#'
#' ⚠️ 但**校验那一步不能跳**（dsapp_envspec_check）。它挡的是"已经有一个
#'    同名的了""现在有别的 conda 作业在跑""找不到 conda"—— 这几件事在
#'    言出法随这一侧一样会发生，跳过校验的话用户点了「开始创建」，
#'    等半天才知道根本没开始。
#'
#' ⚠️ 不在这里判权限/限流：conda 作业是全站共享的机器资源，
#'    `dsapp_env_busy()` 那道闸在 dsapp_env_create() 里，两边都过得到。
#'
#' @return list(ok, msg, pid) —— 和 dsapp_env_create() 同一形状
dsapp_env_create_from_template <- function(tpl, cfg = dsapp_config()) {
  if (is.null(tpl)) return(list(ok = FALSE, msg = "没有这个模板"))
  spec <- list(
    ok       = TRUE,
    msg      = "",
    name     = as.character(tpl$name %||% ""),
    python   = as.character(tpl$python %||% "3.11"),
    channels = as.character(tpl$channels %||% c("conda-forge", "bioconda")),
    packages = as.character(tpl$packages %||% character(0)),
    notes    = character(0)
  )
  ck <- dsapp_envspec_check(spec, cfg)
  if (!isTRUE(ck$ok)) return(list(ok = FALSE, msg = ck$msg %||% "建不了"))
  dsapp_env_create(spec$name, spec$packages,
                   python_version = spec$python,
                   channels = spec$channels, cfg = cfg)
}

#' 解析一份环境配置文本
#'
#' 认两种写法：
#'
#'   1. **本项目自己的格式**（模板就是这个样子，也是最省事的一种）：
#'        name: scRNA
#'        python: 3.11
#'        channels: conda-forge, bioconda
#'        packages:
#'          - scanpy
#'          - anndata
#'
#'   2. **`conda env export` 的输出**。用户手上现成的多半是这一种 ——
#'      让管理员先去 SSH 里跑一条命令再把结果贴进来，比让他照着格式重打
#'      一份包清单现实得多。这一种的 `dependencies:` 里混着 `python=3.11`
#'      这种带版本的条目和一个 `- pip:` 子列表，下面都单独处理。
#'
#' ⚠️ 解析**永远不抛异常**：这是用户粘进来的文本，什么形状都可能。出错就
#'    返回 ok = FALSE 加一句能看懂的话，让界面上显示出来。
#'
#' @return list(ok, msg, name, python, channels, packages, notes)
#'   notes 是给预览区显示的"我们对你这份配置做了什么"（比如去掉了版本号）。
dsapp_envspec_parse <- function(txt) {
  out <- list(ok = FALSE, msg = "", name = "", python = "3.11",
              channels = c("conda-forge", "bioconda"), packages = character(0),
              notes = character(0))
  # ⚠️ `nzchar(NA_character_)` 是 TRUE（keepNA 默认 FALSE），所以
  #    `is.null(txt) || !nzchar(trimws(txt))` 挡不住 NA —— 它会一路走到
  #    `if (startsWith(trimws(NA), "{"))` 那句，报 "missing value where
  #    TRUE/FALSE needed"。而这个函数挂在 renderUI 里，抛出去的后果是整张
  #    卡片变成 Error 页，不是一句提示。NA 也不是假想的输入：textAreaInput
  #    被清空时发上来的就是 NA（不是 ""），而这一格的值直接来自它。
  if (is.null(txt)) txt <- ""
  if (!is.character(txt)) txt <- as.character(txt)
  txt <- paste(txt[!is.na(txt)], collapse = "\n")
  if (!nzchar(trimws(txt))) {
    out$msg <- "配置是空的"
    return(out)
  }

  # BOM 要去掉：Windows 记事本存出来的 UTF-8 前面有三个字节，它会让第一行
  # 的 `name:` 变成 `﻿name:` —— 于是环境名读不出来，而且看不出为什么。
  txt <- sub("^﻿", "", txt)

  # ---- JSON：`conda env export --json` 的输出 -------------------------------
  #
  # 把 JSON **翻译成下面那套行格式**再走同一条路，而不是再写一遍解析。
  # 两条路各写一份的话，版本号处理、python 特判、包名过滤这些规则迟早
  # 只改一边。
  #
  # ⚠️ dependencies 里混着字符串和对象（`{"pip": [...]}`），必须先摊平；
  #    直接 unlist 会把对象变成一堆没有名字的元素。
  if (startsWith(trimws(txt), "{") && requireNamespace("jsonlite", quietly = TRUE)) {
    j <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE),
                  error = function(e) NULL)
    if (!is.null(j) && is.list(j)) {
      ln <- character(0)
      if (nzchar(as.character(j$name %||% ""))) {
        ln <- c(ln, sprintf("name: %s", as.character(j$name)))
      }
      for (ch in as.character(unlist(j$channels %||% character(0)))) {
        ln <- c(ln, sprintf("channels: %s", ch))
      }
      flat <- character(0)
      for (d in j$dependencies %||% list()) {
        if (is.list(d)) {
          for (sub in names(d)) flat <- c(flat, as.character(unlist(d[[sub]])))
        } else {
          flat <- c(flat, as.character(d))
        }
      }
      if (length(flat)) ln <- c(ln, "dependencies:", paste0("- ", flat))
      txt <- paste(ln, collapse = "\n")
    }
  }

  lines <- strsplit(txt, "\r?\n")[[1]]

  name <- ""; python <- ""; channels <- character(0)
  pkgs <- character(0); notes <- character(0)
  mode <- ""            # "" / "packages" / "deps" / "pip"
  dropped_ver <- 0L

  for (ln in lines) {
    raw <- ln
    ln <- trimws(ln)
    if (!nzchar(ln) || startsWith(ln, "#")) next

    # ---- 列表项 ----
    if (startsWith(ln, "-")) {
      item <- trimws(sub("^-+", "", ln))
      if (!nzchar(item)) next
      # 被注释掉的列表项（`- # celltypist`）。行首的 # 上面已经跳过了，这里
      # 挡的是"# 在 - 后面"的写法 —— 模板自己不会这么写，但用户手改的时候
      # 很容易把 `  - celltypist` 注释成 `  - # celltypist`，而那样得到的
      # 是一个叫 "#celltypist" 的包名，conda 解不出来，报错还难看懂。
      if (startsWith(item, "#")) next
      # conda export 里的 `- pip:` / `- variables:` 是子块的开头，不是包
      if (grepl(":$", item)) {
        key <- sub(":$", "", item)
        mode <- if (identical(key, "pip")) "pip" else mode
        next
      }
      # `python=3.11` 是解释器版本，不是包 —— 两种模式都要判（conda export
      # 里它在 dependencies 下，用户手写时也可能写在 packages 下）。
      if (grepl("^python\\s*[=<>!]", item)) {
        v <- sub("^python\\s*[=<>!]+\\s*", "", item)
        if (!nzchar(python) && grepl("^[0-9]+\\.[0-9]+", v)) {
          python <- regmatches(v, regexpr("^[0-9]+\\.[0-9]+", v))
        }
        next
      }
      # ★ 版本号一律去掉，只留包名 —— 不管在哪种模式里。
      #
      #   两种来源各有一个理由：
      #     * pip 那些 `scanpy==1.10.0` 是 pip 的语法，conda 不认，原样
      #       传过去整条 solve 直接失败。
      #     * conda 自己的 `numpy=1.26.4` 语法上能用，但它是**从另一台
      #       机器上导出来的**：那个版本在我们的频道组合下未必还在，
      #       一旦解不出来，整条 `conda create` 就是二十分钟后一句
      #       UnsatisfiableError。而用户想要的其实是"一个能跑分析的
      #       环境"，不是"逐字节复刻那台机器"。
      #   去掉版本是**有损**的，所以下面记一条 note 说出来，不悄悄地改
      #   用户的东西。
      if (grepl("[<>=!]", item)) {
        item <- sub("[<>=!].*$", "", item)
        dropped_ver <- dropped_ver + 1L
      }
      item <- trimws(item)
      # 裸列表（没有 packages:/dependencies: 头部，用户手写时很常见）和
      # 有头部的列表走同一条路 —— 收进来，最后统一去重、过滤。
      if (nzchar(item)) pkgs <- c(pkgs, item)
      next
    }

    # ---- key: value ----
    if (grepl(":", ln, fixed = TRUE)) {
      key <- trimws(sub(":.*$", "", ln))
      val <- trimws(sub("^[^:]*:", "", ln))
      k <- tolower(key)
      if (k %in% c("name", "environment", "env")) {
        # conda export 会写 `name: base`（导出机器上的名字），而我们是用
        # -p 指定路径的，这个名字只当建议值。
        if (!nzchar(name) && nzchar(val)) name <- val
        next
      }
      if (k %in% c("python", "python_version")) {
        v <- regmatches(val, regexpr("[0-9]+\\.[0-9]+", val))
        if (length(v) && nzchar(v) && !nzchar(python)) python <- v
        next
      }
      if (k %in% c("channels", "channel")) {
        channels <- c(channels, dsapp_split_pkgs(val))
        next
      }
      if (k %in% c("packages", "dependencies", "deps")) {
        # `packages: scanpy, anndata` 一行写完也认
        inline <- dsapp_split_pkgs(val)
        pkgs <- c(pkgs, inline)
        mode <- if (identical(k, "dependencies")) "deps" else "packages"
        next
      }
      # prefix: / variables: 之类，忽略
      next
    }
  }

  # 裸列表模式下 mode 一直是 ""，那些项已经收进 pkgs 了
  channels <- unique(channels[!grepl("^https?://", channels)])
  channels <- channels[grepl("^[A-Za-z0-9_.-]+$", channels)]
  if (!length(channels)) channels <- c("conda-forge", "bioconda")

  pkgs <- unique(trimws(pkgs))
  pkgs <- pkgs[nzchar(pkgs)]
  # 包名里带空格的会被 conda 当成两个包名，报出和真实原因无关的错
  pkgs <- pkgs[!grepl("\\s", pkgs)]
  if (!nzchar(python)) python <- "3.11"
  if (dropped_ver > 0L) {
    notes <- c(notes, sprintf(
      "有 %d 个包写了版本号，已按**包名**取（版本是从别的机器上导出来的，硬钉住会让依赖解不出来）",
      dropped_ver))
  }
  if (!length(pkgs)) {
    out$msg <- "没读到任何包。检查一下 packages: 下面有没有以 - 开头的行。"
    out$name <- name; out$python <- python; out$channels <- channels
    return(out)
  }

  out$ok <- TRUE
  out$name <- name
  out$python <- python
  out$channels <- channels
  out$packages <- pkgs
  out$notes <- notes
  out
}

#' 建环境之前把这份配置过一遍
#'
#' 从「解析出来」到「真的能建」之间还差几道闸：环境名合法吗、是不是已经
#' 有了、现在有没有别的 conda 作业在跑。这些 dsapp_env_create() 自己也会
#' 判，但那是**点下去之后**才报错 —— 而点下去意味着用户已经开始等了。
#' 这里提前判一次，预览区能当场告诉他"这个名字已经有人用了"。
#'
#' @return list(ok, msg, warn)  warn 是"能建，但你得知道"的那些事
dsapp_envspec_check <- function(spec, cfg = dsapp_config()) {
  if (!isTRUE(spec$ok)) return(list(ok = FALSE, msg = spec$msg %||% "配置有问题",
                                    warn = character(0)))
  warn <- character(0)
  bad <- dsapp_env_name_ok(spec$name)
  if (nzchar(bad)) {
    return(list(ok = FALSE, msg = paste0("环境名不合规：", bad,
                                         "（在配置的 name: 那行改一个）"),
                warn = warn))
  }
  if (dsapp_env_exists(spec$name, cfg)) {
    return(list(ok = FALSE, msg = sprintf("已经有一个叫 %s 的环境了，换个名字",
                                          spec$name), warn = warn))
  }
  if (dsapp_env_busy()) {
    return(list(ok = FALSE,
                msg = "现在有另一个 conda 作业在跑。solver 很吃 CPU，同时跑两个会把机器拖垮，等它结束再来。",
                warn = warn))
  }
  if (!nzchar(dsapp_find_solver(cfg))) {
    return(list(ok = FALSE, msg = "找不到 conda/mamba，没法建环境", warn = warn))
  }
  if (length(spec$packages) > 120L) {
    warn <- c(warn, sprintf("包有 %d 个，依赖解析会很慢（可能十几分钟以上）",
                            length(spec$packages)))
  }
  # 共享这件事必须说在前面：用户很容易以为"我建的环境是我自己的"。
  warn <- c(warn, "conda 环境是**全站共享**的：建好之后所有人都能选它当基础环境")
  list(ok = TRUE, msg = "", warn = warn)
}

#' 往已有环境里装包
#'
#' 生信分析几乎没有一次装齐的：先建个 Python 环境，跑到一半发现要 scanpy，
#' 再加。没有这个功能的话用户只能删掉环境重建，几十分钟白等。
dsapp_env_install <- function(name, packages,
                              channels = c("conda-forge", "bioconda"),
                              cfg = dsapp_config()) {
  bad <- dsapp_env_name_ok(name)
  if (nzchar(bad)) return(list(ok = FALSE, msg = bad))
  if (!dsapp_env_exists(name, cfg)) {
    return(list(ok = FALSE, msg = sprintf("环境 %s 不存在", name)))
  }
  if (dsapp_env_busy()) {
    return(list(ok = FALSE, msg = "已有 conda 作业在跑，请等它结束"))
  }

  packages <- trimws(packages)
  packages <- packages[nzchar(packages)]
  if (!length(packages)) {
    return(list(ok = FALSE, msg = "没有填要装的包"))
  }
  bad_pkg <- packages[!grepl("^[A-Za-z0-9][A-Za-z0-9_.:=<>!*+-]*$", packages)]
  if (length(bad_pkg)) {
    return(list(ok = FALSE, msg = sprintf("包名不合法：%s",
                                          paste(bad_pkg, collapse = ", "))))
  }

  ch_args <- as.vector(rbind("-c", channels))
  args <- c("install", "-p", dsapp_env_path(name, cfg), "-y",
            "--override-channels", ch_args, packages)

  dsapp_env_job_launch(
    name, args,
    header = c(
      sprintf("=== 往环境 %s 装包 ===", name),
      sprintf("包：%s", paste(packages, collapse = " ")),
      sprintf("频道：%s", paste(channels, collapse = ", ")),
      ""),
    cfg = cfg
  )
}

#' 启动一个 conda 作业并记录 pid
#'
#' create 和 install 除了 argv 之外完全一样，共用这段。
dsapp_env_job_launch <- function(name, args, header, cfg = dsapp_config()) {
  solver <- dsapp_find_solver(cfg)
  if (!nzchar(solver)) {
    return(list(ok = FALSE, msg = "找不到 conda/mamba"))
  }

  log_path    <- dsapp_env_log_path(name, cfg)
  status_path <- dsapp_env_status_path(name, cfg)
  unlink(c(log_path, status_path))

  writeLines(header, log_path)

  p <- tryCatch(
    processx::process$new(
      command = solver,
      args    = args,
      env     = dsapp_conda_env_vars(cfg),
      stdout  = log_path,
      stderr  = "2>&1"
    ),
    error = function(e) e
  )

  if (inherits(p, "error")) {
    return(list(ok = FALSE, msg = paste0("无法启动 conda：", conditionMessage(p))))
  }

  writeLines(c(
    sprintf("pid=%d", p$get_pid()),
    sprintf("log=%s", log_path),
    sprintf("name=%s", name),
    sprintf("env=%s", dsapp_env_path(name, cfg)),
    # 记下这一刻环境是否已存在：用来区分「创建」和「装包」两种作业的成败
    # 判据。装包失败不该被误报成「环境没建起来」，因为环境本来就在。
    sprintf("preexisting=%s", if (dsapp_env_exists(name, cfg)) "1" else "0")
  ), status_path)

  # 登记进程对象，这样轮询时能拿到真实退出码
  assign(name, p, envir = dsapp_env_jobs)

  list(ok = TRUE, pid = p$get_pid(), msg = sprintf("已开始处理环境 %s", name))
}

#' 正在跑的 conda 作业句柄
#'
#' 应用进程内的登记表，name → processx 进程对象。留着它才能拿到**退出码** ——
#' 光靠 pid 只能知道「进程没了」，而 conda 失败退出和成功退出都表现为
#' 「没了」，分不出来。
#'
#' 应用重启后这张表就空了，那时候退回按 pid + 日志尾判断（见下）。
dsapp_env_jobs <- new.env(parent = emptyenv())

#' 读作业状态文件
dsapp_env_read_status <- function(name, cfg = dsapp_config()) {
  p <- dsapp_env_status_path(name, cfg)
  if (!file.exists(p)) return(NULL)
  lines <- readLines(p, warn = FALSE)
  parts <- strsplit(lines, "=", fixed = TRUE)
  kv <- vapply(parts, function(x) if (length(x) >= 2) paste(x[-1], collapse = "=") else "",
               character(1))
  names(kv) <- vapply(parts, function(x) x[[1]], character(1))
  as.list(kv)
}

#' conda 输出里有没有明显的失败痕迹
#'
#' 只在拿不到退出码时（应用重启过）才用。宁可漏判成成功也不能误判成
#' 失败 —— 用户看到「失败」会去删环境重来，而环境其实是好的。所以这里
#' 只认 conda 非常明确的错误标志。
dsapp_env_log_failed <- function(txt) {
  if (!nzchar(txt)) return(FALSE)
  pats <- c("PackagesNotFoundError", "UnsatisfiableError", "CondaError",
            "Critical error", "ResolvePackageNotFound", "CondaHTTPError",
            "failed with initial frozen solve", "InvalidSpec")
  any(vapply(pats, function(p) grepl(p, txt, fixed = TRUE), logical(1)))
}

#' 查环境作业进度
#'
#' 返回 list(running, done, ok, log_tail, exit_code)。
dsapp_env_progress <- function(name, cfg = dsapp_config()) {
  log_path <- dsapp_env_log_path(name, cfg)
  tail_txt <- if (file.exists(log_path)) dsapp_tail(log_path, n = 60) else ""

  # ---- 首选：进程还在这张表里，能拿到真实退出码 ----
  if (exists(name, envir = dsapp_env_jobs, inherits = FALSE)) {
    h <- get(name, envir = dsapp_env_jobs)
    if (is.null(h) || !h$is_alive()) {
      code <- tryCatch(h$get_exit_status(), error = function(e) NA_integer_)
      rm(list = name, envir = dsapp_env_jobs)
      st <- dsapp_env_read_status(name, cfg)
      pre <- identical(st$preexisting, "1")
      # 创建类作业：退出码为 0 之外还要确认环境真的成型了（解释器在）。
      # 装包类作业：环境本来就在，只看退出码。
      ok <- identical(code, 0L) && (pre || dsapp_env_exists(name, cfg))
      return(list(running = FALSE, done = TRUE, ok = ok,
                  exit_code = code, log_tail = tail_txt))
    }
    return(list(running = TRUE, done = FALSE, ok = FALSE,
                exit_code = NA_integer_, log_tail = tail_txt))
  }

  # ---- 回退：应用重启过，登记表空了，只能靠 pid ----
  st <- dsapp_env_read_status(name, cfg)
  if (is.null(st) || is.null(st$pid) || !nzchar(st$pid)) {
    return(list(running = FALSE, done = FALSE,
                ok = dsapp_env_exists(name, cfg), exit_code = NA_integer_,
                log_tail = tail_txt))
  }

  pid <- suppressWarnings(as.integer(st$pid))
  if (!is.na(pid) && dsapp_pid_alive(pid)) {
    return(list(running = TRUE, done = FALSE, ok = FALSE,
                exit_code = NA_integer_, log_tail = tail_txt))
  }

  pre <- identical(st$preexisting, "1")
  ok <- !dsapp_env_log_failed(tail_txt) && (pre || dsapp_env_exists(name, cfg))
  list(running = FALSE, done = TRUE, ok = ok, exit_code = NA_integer_,
       log_tail = tail_txt)
}

#' 当前是否有 conda 作业在跑
#'
#' 界面上用来禁用按钮。conda 的 solver 很吃 CPU 和内存，同时跑两个
#' 会把机器拖垮，而且两个 solver 抢同一个 pkgs 缓存还可能损坏它。
#'
#' ⚠️★ V13.5：**先收尸，再点数**。
#'
#'   登记表原来只在 `dsapp_env_progress()` 里清理（看到 is_alive() 假就
#'   rm 掉）。而 progress 是**会话里那个轮询**在调的，它的存活区间是
#'   "用户点了创建 → 那次作业结束"，而且只在这个会话还开着的时候跑。
#'   于是有这么一条路：
#'
#'     用户点了「创建 scRNA」→ 关掉标签页 → 二十分钟后作业跑完 →
#'     没有任何人会去调 progress("scRNA") → 那个**已经死掉的**句柄
#'     永远留在表里 → dsapp_env_busy() 永远为真 → 从此**全站**再没人
#'     建得了环境，每个人点下去都是"现在有另一个 conda 作业在跑"，
#'     直到应用重启。
#'
#'   报错信息还会把人往错的方向带：确实没有作业在跑，用户会去反复点、
#'   截图、以为机器卡了。所以这里自己看一眼进程还活着没 —— is_alive()
#'   是 processx 的本地判断，读一次 /proc，纳秒级，放在这道闸上不心疼。
dsapp_env_busy <- function() {
  for (nm in ls(dsapp_env_jobs)) {
    h <- tryCatch(get(nm, envir = dsapp_env_jobs, inherits = FALSE),
                  error = function(e) NULL)
    alive <- tryCatch(isTRUE(h$is_alive()), error = function(e) FALSE)
    if (!alive) rm(list = nm, envir = dsapp_env_jobs)
  }
  length(ls(dsapp_env_jobs)) > 0
}

#' pid 是否还活着
#'
#' kill -0 只检查信号能不能发出去，不会真的杀进程。
dsapp_pid_alive <- function(pid) {
  if (is.na(pid) || pid <= 0) return(FALSE)
  # 注意：不能用 tools::pskill(pid, 0)，某些平台上 0 号信号行为不一致。
  # /proc 是 Linux 上最直接的判断方式。
  if (dir.exists("/proc")) {
    return(dir.exists(file.path("/proc", as.character(pid))))
  }
  !inherits(try(tools::pskill(pid, 0), silent = TRUE), "try-error")
}

#' 环境对应的解释器路径
#'
#' 任务执行时用。返回 list(python, rscript, bin_dir)，没有的项是 ""。
#' bin_dir 会被前置到 PATH —— 这样 `conda install samtools` 装上的
#' 命令行工具在脚本里也能直接调用，这对生信场景很关键。
dsapp_env_interpreters <- function(name, cfg = dsapp_config()) {
  if (!nzchar(name) || is.null(name) || identical(name, "system")) {
    return(list(python = "", rscript = "", bin_dir = "", label = "系统环境"))
  }
  p <- dsapp_env_path(name, cfg)
  py <- file.path(p, "bin", "python")
  rs <- file.path(p, "bin", "Rscript")
  list(
    python  = if (file.exists(py)) py else "",
    rscript = if (file.exists(rs)) rs else "",
    bin_dir = file.path(p, "bin"),
    label   = sprintf("conda 环境 %s", name)
  )
}

#' 把环境信息渲染成给用户看的一行摘要
dsapp_env_summary <- function(name, cfg = dsapp_config()) {
  if (!nzchar(name) || identical(name, "system")) {
    return("系统环境（服务器上已装的 R / Python）")
  }
  it <- dsapp_env_interpreters(name, cfg)
  langs <- c(if (nzchar(it$python)) "Python",
             if (nzchar(it$rscript)) "R")
  if (!length(langs)) return(sprintf("conda 环境 %s（未检测到解释器）", name))
  sprintf("conda 环境 %s（%s）", name, paste(langs, collapse = " + "))
}

# =============================================================================
# 每对话增量库
# =============================================================================
# 「每个任务自动创建一个路径和环境，用户只对自己路径和环境中的内容有干涉权」
# —— 路径那一半是 utils.R 的 dsapp_ws_dir（对话工作区），环境这一半在这里。
#
# ---- 为什么不是 conda clone（原计划，实测后推翻）----------------------------
#
# 实测这台机器：
#   * conda base 9.3 GB、pkgs 缓存 11 GB，而且两者在**不同的文件系统**上，
#     `conda create --clone` 只能真拷贝、硬链不起来 —— 每个对话 9.3 GB。
#   * 更要命的是功能上不成立：那 18 GB 的生信包（Seurat / DESeq2 /
#     Bioconductor 全家）装在 /usr/local/lib/R/site-library，属于**系统 R**，
#     根本不在 conda 里。clone 出来的环境一个都用不了 —— 用户建完发现
#     library(Seurat) 报错，而那正是他最常用的包。
#
# ---- 现在的做法：增量叠加 ---------------------------------------------------
#
#   R      → <工作区>/.Rlib   ，通过 R_LIBS_USER 前置进 .libPaths()
#   Python → <工作区>/.venv   ，`python3 -m venv --system-site-packages`
#
# 两者都是**叠加**在基础环境（系统环境，或用户在「环境」页选的 conda 环境）
# 之上：基础环境里已有的包照常可见可用，新装的只落在对话自己的目录里。
# 实测 Python 侧 3.9 秒 / 19 MB —— 对比 clone 的 9.3 GB / 十几分钟。
#
# 装坏了不用怕：删掉 .Rlib / .venv 就退回干净的基础环境，对话内容不受影响。
#
# ⚠️ R_LIBS_USER 指向的目录**必须已经存在**。R 是在启动时构造 .libPaths() 的，
#    不存在的条目会被**静默丢掉** —— 不报错、不警告，只是往里装的包再也找
#    不着（用户看到的是"我明明装好了，怎么还说没有"）。所以 .Rlib 由
#    dsapp_run_code() 在起子进程**之前**建好。实测：目录存在时它排在
#    .libPaths() 的第一位（新装的包能盖住系统里的旧版本），不存在则整个消失。
#
# ⚠️ venv 必须在**最终路径**上建，不能建到临时目录再改名 —— venv 里
#    bin/pip 的头一行是 `#!<venv>/bin/python3` 这样的绝对路径，改名之后 pip
#    就指向一个不存在的地方，报出来的错跟"改名"毫无关系，很难查。所以并发
#    保护用锁目录（dir.create 在目标已存在时返回 FALSE，这一步是原子的）。
# =============================================================================

#' 对话的 R 增量库路径
dsapp_ws_rlib <- function(sid, cfg = dsapp_config()) {
  ws <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(ws)) return(NA_character_)
  file.path(ws, ".Rlib")
}

#' 对话的 Python 虚拟环境路径
dsapp_ws_venv <- function(sid, cfg = dsapp_config()) {
  ws <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(ws)) return(NA_character_)
  file.path(ws, ".venv")
}

#' 确保对话的 R 增量库存在
#'
#' 就是一次 mkdir。**必须在起 R 子进程之前调**，理由见本节顶部。
#' @return 路径；没有对话归属（sid 为 NA）或建不出来时返回 NULL
dsapp_rlib_ensure <- function(sid, cfg = dsapp_config()) {
  d <- dsapp_ws_rlib(sid, cfg)
  if (is.na(d)) return(NULL)
  if (!dir.exists(d) && !dir.create(d, recursive = TRUE, showWarnings = FALSE)) {
    return(NULL)
  }
  d
}

#' 确保对话的 Python 虚拟环境可用
#'
#' ⚠️ 首次调用要跑 `python3 -m venv`（本机实测约 4 秒），所以**只在真要跑
#'    Python 时才调** —— 一个只跑 R 的对话不该为它付这 4 秒。
#'    这个函数只会在 callr 子进程里被调到（见 jobs.R），不会阻塞 Shiny 主进程。
#'
#' ⚠️ base_python 必须是**本次真正执行代码的那个解释器**。用 A 建 venv 再用
#'    B 执行的话，脚本里的 `python` 命令和起 subprocess 的解释器会是两个不同
#'    的 Python，症状是"命令行跑得好好的，一进 subprocess 就找不到包"。
#'
#' @return list(ok, bin, msg)
dsapp_venv_ensure <- function(sid, cfg = dsapp_config(), base_python = NULL) {
  fail <- function(msg) list(ok = FALSE, bin = NULL, msg = msg)

  v <- dsapp_ws_venv(sid, cfg)
  if (is.na(v)) return(fail(""))

  bin <- file.path(v, "bin")
  py  <- file.path(bin, "python3")
  if (file.exists(py)) return(list(ok = TRUE, bin = bin, msg = ""))

  base <- base_python %||% ""
  if (!nzchar(base) || !file.exists(base)) {
    return(fail("找不到用来建虚拟环境的 Python 解释器"))
  }

  # 工作区可能还没建（第一次执行 Python）。venv 要落在这儿，先保证父目录在。
  dir.create(dirname(v), recursive = TRUE, showWarnings = FALSE)

  lock <- file.path(dirname(v), ".venv.lock")
  if (dir.create(lock, showWarnings = FALSE)) {
    on.exit(unlink(lock, recursive = TRUE), add = TRUE)
    log <- file.path(dirname(v), ".dsapp_venv.log")
    r <- tryCatch(
      processx::run(base, c("-m", "venv", "--system-site-packages", v),
                    error_on_status = FALSE, stdout = log, stderr = "2>&1"),
      error = function(e) list(status = NA_integer_)
    )
    if (!file.exists(py)) {
      return(fail(sprintf(
        "创建本对话的 Python 虚拟环境失败（%s -m venv 退出码 %s），详见 %s",
        base, r$status %||% "?", log)))
    }
    return(list(ok = TRUE, bin = bin, msg = ""))
  }

  # 别人正在建。等它，不要自己也建一遍 —— 两个 venv 同时往一个目录里写会写坏。
  for (i in seq_len(120)) {
    Sys.sleep(1)
    if (file.exists(py)) return(list(ok = TRUE, bin = bin, msg = ""))
    if (!dir.exists(lock)) break          # 建的人退出了（on.exit 删了锁）
  }
  fail("等待另一个任务创建虚拟环境时超时")
}

#' 本次执行要注入的环境附加项
#'
#' 按语言按需建：只跑 R 的对话不会因为这里而多出一个 .venv。
#'
#' @param lang    本次要执行的语言（"R" / "Python" / "Bash"）
#' @param base_python 真机上执行 Python 的那个解释器，见 dsapp_venv_ensure
#' @return list(rlib, venv, venv_bin, py_target, notes)
dsapp_session_libs <- function(sid, cfg = dsapp_config(), lang = "R",
                               base_python = NULL) {
  out <- list(rlib = NULL, venv = NULL, venv_bin = NULL, py_target = NULL,
              notes = character(0))
  if (is.null(sid) || length(sid) == 0 || is.na(sid)) return(out)

  if (identical(lang, "R")) {
    d <- dsapp_rlib_ensure(sid, cfg)
    if (is.null(d)) {
      out$notes <- "无法创建本对话的 R 包目录（.Rlib），新装的包会落到默认库。"
    } else {
      out$rlib <- d
    }
    return(out)
  }

  if (identical(lang, "Python")) {
    r <- dsapp_venv_ensure(sid, cfg, base_python)
    if (isTRUE(r$ok)) {
      out$venv     <- dirname(r$bin)
      out$venv_bin <- r$bin
      return(out)
    }
    # ---- 回落：把 pip 的安装目标锁在对话目录里 ----
    #
    # venv 建不出来（没装 ensurepip、磁盘满、基础解释器有问题）时不能让
    # pip 就这么跑 —— 它会写进 ~/.local，那是**所有对话、所有用户共用**的
    # 地方，正是「只对自己环境有干涉权」要避免的。PIP_TARGET 把安装目标
    # 钉死在对话工作区，PYTHONPATH 让装进去的包能被 import 到。
    # 效果比 venv 弱（没有独立的 bin/，装不了带命令行工具的包），但隔离性
    # 一致，而且用户会从结果里的提示知道发生了什么。
    ws  <- dsapp_ws_dir(sid, cfg, create = FALSE)
    tgt <- file.path(ws, ".pylib")
    if (!is.na(ws) && dir.create(tgt, recursive = TRUE, showWarnings = FALSE)) {
      out$py_target <- tgt
    }
    if (nzchar(r$msg)) out$notes <- r$msg
    return(out)
  }

  out
}

#' 对话的包目录现状（只读，不创建任何东西）
#'
#' 给提示词用。拼提示词是**每次发消息都会跑**的高频操作，所以这里一律用
#' file.exists / dir.exists 这种不碰磁盘内容、不起子进程的探测。
#'
#' @return NULL（没有对话）或 list(ws, rlib, rlib_ok, venv, venv_ok, pylib, pylib_ok)
dsapp_session_lib_status <- function(sid, cfg = dsapp_config()) {
  if (is.null(sid) || length(sid) == 0 || is.na(sid)) return(NULL)
  ws <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(ws)) return(NULL)

  venv_ok <- file.exists(file.path(ws, ".venv", "bin", "python3"))
  list(
    ws       = ws,
    rlib     = file.path(ws, ".Rlib"),
    rlib_ok  = dir.exists(file.path(ws, ".Rlib")),
    venv     = file.path(ws, ".venv"),
    venv_ok  = venv_ok,
    pylib    = file.path(ws, ".pylib"),
    # .pylib 只是 venv 建不出来时的回落，两者不会同时在用
    pylib_ok = !venv_ok && dir.exists(file.path(ws, ".pylib"))
  )
}

#' 删掉对话的整个工作区（含 .Rlib / .venv）
#'
#' 删对话时调。删不掉不算致命（磁盘上留一份垃圾而已），所以只回报结果，
#' 不抛异常 —— 调用方正在删对话，不该被一个目录删不掉打断。
#'
#' @return 实际释放的字节数（估不出来时 NA）
dsapp_ws_delete <- function(sid, cfg = dsapp_config()) {
  d <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(d) || !dir.exists(d)) return(0)
  # 先量再删：工作区里有 venv（上万个文件），删完就没法量了。
  # 量不出来不是错误，只是统计不到（dsapp_dir_bytes 会返回 NA）。
  bytes <- dsapp_dir_bytes(d)

  unlink(d, recursive = TRUE, force = TRUE)
  if (dir.exists(d)) return(NA_real_)

  # 锁目录可能在 unlink 之后才被另一个进程放回来（它 on.exit 时删的是
  # 已经不在的路径，然后自己也被删了）—— 正常不会发生，真发生了也只是
  # 目录树里多一个空壳，下次启动清理会扫掉。这里不再纠缠。
  bytes
}
