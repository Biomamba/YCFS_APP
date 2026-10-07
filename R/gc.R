# =============================================================================
# 启动清理：删掉再也不会有人用的东西
# =============================================================================
#
# 这里每一个函数都在 `unlink(recursive = TRUE)`。写错一个字符，用户几小时的
# 分析结果就没了，而且**没法撤销**。所以本文件的写法有几个刻意的约束：
#
#   1. 凡是"这个目录属于谁"的判断，一律**从数据库重建期望的名字**，再和
#      磁盘上的名字作集合比较。绝不反过来从目录名解析出对话号 —— 那个方向
#      要反解 dsapp_ws_name() 的字符清洗（见 utils.R），而清洗是**有损**的：
#      `../../etc` 和 `.._.._etc` 洗完是同一个名字。反解一旦出错，错的方向
#      是"把别人的工作区当成孤儿删掉"。
#
#   2. 查不到数据库就**什么都不删**。宁可留一堆垃圾等下次启动，也不能在
#      "数据库暂时读不出来"的时候把"所有对话都不存在"当成事实。
#
#   3. 年龄下限。刚被碰过的目录一律不动。这条在两种场合救命：应用重启时
#      旧进程可能还在收尾；以及以后如果有人把这个函数接到按钮上，它也不会
#      删掉用户正在用的东西。代价只是垃圾多留一个启动周期。
#
#   4. 只认自己写的文件名。run/ 里将来多出别的文件（比如有人手工放了个
#      参考数据），本文件不该顺手把它删了。
# =============================================================================

#' 孤儿工作区：对话已经不在了，目录还在
#'
#' 正常路径下删对话时 dsapp_ws_delete() 会连工作区一起删（含 .Rlib / .venv）。
#' 这里是**兜底**：那次删除失败、或者进程被 kill 在半路，就会留下孤儿。
#' 孤儿不只是占地方 —— 一个已删对话的 .venv 里可能装着几个 G 的包。
#'
#' @param min_age_mins 最近这么多分钟内被动过的目录不动（见文件顶部第 3 条）
#' @return list(n = 删掉的目录数, bytes = 释放的字节, skipped = 因为太新而跳过的)
dsapp_gc_orphan_ws <- function(cfg = dsapp_config(), min_age_mins = 10) {
  root <- cfg$ws_root
  if (is.null(root) || !dir.exists(root)) {
    return(list(n = 0L, bytes = 0, skipped = 0L))
  }

  dirs <- list.files(root, pattern = "^chat-", full.names = TRUE)
  dirs <- dirs[dir.exists(dirs)]
  if (!length(dirs)) return(list(n = 0L, bytes = 0, skipped = 0L))

  # ⚠️ 查询失败必须**放弃整个动作**，不能退回空集合 —— 空集合的含义是
  #    "一个对话都没有"，那会把所有工作区都判成孤儿。这里返回 NA 而不是
  #    character(0)，就是为了让下面能区分"查到了，是空的"和"没查成"。
  live <- tryCatch({
    rows <- DBI::dbGetQuery(dsapp_db(cfg), "SELECT id FROM sessions")
    as.character(rows$id)
  }, error = function(e) NA_character_)

  if (length(live) == 1L && is.na(live)) {
    return(list(n = 0L, bytes = 0, skipped = length(dirs), db_error = TRUE))
  }

  expected <- vapply(live, dsapp_ws_name, character(1), USE.NAMES = FALSE)
  orphans <- dirs[!basename(dirs) %in% expected]

  cutoff <- Sys.time() - min_age_mins * 60
  n <- 0L; bytes <- 0; skipped <- 0L
  for (d in orphans) {
    # 年龄看目录**本身**的 mtime。工作区里新建文件会更新父目录的 mtime
    # （目录内容变了），所以"最后一轮执行"能被看见 —— 这正是要防的那种
    # "还在用"。往深层递归去看最新 mtime 更准，但递归一个带 venv 的目录
    # （上万个文件）要为启动时的这几毫秒付很多；父目录够用了。
    mt <- tryCatch(file.info(d)$mtime, error = function(e) NA)
    if (is.na(mt) || mt > cutoff) { skipped <- skipped + 1L; next }

    # ★ V16.6 item 5：走公共的跨平台实现（原来这里自己拼了一次 du -sb，
    #   macOS 的 BSD du 没有 -b → 永远 NA → 清理时报"释放了 0 字节"）
    b <- dsapp_du_bytes(d)

    unlink(d, recursive = TRUE, force = TRUE)
    if (dir.exists(d)) next      # 删不掉就如实不算，别谎报释放了多少
    n <- n + 1L
    if (!is.na(b)) bytes <- bytes + b
  }

  list(n = n, bytes = bytes, skipped = skipped)
}

#' run/ 和 work/ 里的中转文件
#'
#' 这些文件是"跑一次"的中间产物，正常情况下由产出它们的那段代码自己删
#' （比如 dsapp_llm_finish 会 unlink 掉三个 llm 文件）。但只要进程被 kill -9、
#' 或者正好在启动清理标记任务失败的那个窗口里退出，就会留下来，而且**从来
#' 没有第二个人来收**。日积月累是实打实的磁盘。
#'
#' ⚠️ 只删**认得出是自己写的**名字。具体说：run/ 下前缀是 job-/llm-/bg- 且
#'    后缀是 .json/.out/.reason 的（含 .tmp 中间态），work/ 下叫 task-<数字>
#'    或 remote-<数字> 的目录。别的一概不碰 —— 那可能是有人手工放进去的东西，
#'    也可能是以后新加的、本函数还不认识的文件，那就该由新的代码来负责收。
#'
#' 年龄下限同 dsapp_gc_orphan_ws，理由见文件顶部。
#'
#' @return list(n = 删掉的文件数, bytes = 释放的字节数)
dsapp_gc_scratch <- function(cfg = dsapp_config(), max_age_hours = 24) {
  n <- 0L; bytes <- 0
  cutoff <- Sys.time() - max_age_hours * 3600

  hit <- function(paths) {
    for (p in paths) {
      mt <- tryCatch(file.info(p)$mtime, error = function(e) NA)
      if (is.na(mt) || mt > cutoff) next
      sz <- tryCatch(file.info(p)$size, error = function(e) NA_real_)
      unlink(p, recursive = TRUE, force = TRUE)
      if (file.exists(p) || dir.exists(p)) next
      n <<- n + 1L
      if (!is.na(sz)) bytes <<- bytes + sz
    }
  }

  if (dir.exists(cfg$run_dir)) {
    # 两条分开写，是因为 llm 的中转文件是 `<token>.out` 这种**没有**前缀的
    # 形式（token 本身就是 "llm-" 开头，见 llm.R），而 job/bg 是
    # `<前缀>-<id>.<后缀>`。合成一条正则容易漏掉其中一半。
    hit(list.files(cfg$run_dir,
                   pattern = "^(job|bg|llm)-[A-Za-z0-9._-]+\\.(json|out|reason)(\\.tmp)?$",
                   full.names = TRUE))
    # 写入用的是"先写 .tmp 再 rename"，所以中断时会留下 job-<id>.json.tmp
    hit(list.files(cfg$run_dir, pattern = "\\.json\\.tmp$", full.names = TRUE))
  }

  if (dir.exists(cfg$work_dir)) {
    # ⚠️⚠️ 只收 remote-，**绝对不要收 work/task-<id>**。
    #
    #    这两个目录长得像一类东西，其实完全不是。task-<id> 的路径是**写进
    #    tasks 表的**（executor.R 的 `workdir = workdir`），任务页拿它去列
    #    "产物"（mod_tasks.R:171 → dsapp_artifacts_of）。删掉它，任务记录还在、
    #    产物清单变成空 —— 而删除对话框上明明写着「不会删除已产出的文件」。
    #    这是**用户数据**，不是中转文件，只是恰好放在 work/ 下面。
    #
    #    remote-<id> 才是真中转：远程任务的 tasks 行里 workdir 是 NA
    #    （remote.R:616 明说了"本地没有对应的 workdir"），它只是往用户机器上
    #    推文件之前的暂存副本，副本的源头还在 files_dir 里。
    #
    #    用 ^remote-[0-9]+$ 而不是 ^remote- ：任务号一定是数字，别把将来可能
    #    出现的 remote-abc 误伤。宁可漏收，不要错收。
    hit(list.files(cfg$work_dir, pattern = "^remote-[0-9]+$", full.names = TRUE))
  }

  list(n = n, bytes = bytes)
}

#' 启动清理总入口
#'
#' app.R 启动时调一次。**任何一步出错都不该拦住应用启动** —— 清理失败只是
#' 磁盘上多些垃圾，起不来是整个服务不可用。所以每一步各自 tryCatch。
#'
#' @return list(ws_n, ws_bytes, scratch_n, scratch_bytes, errors)
dsapp_gc <- function(cfg = dsapp_config(), min_age_mins = 10,
                     scratch_max_age_hours = 24, audit_days = 180) {
  errs <- character(0)
  ws <- list(n = 0L, bytes = 0)
  sc <- list(n = 0L, bytes = 0)

  # 审计日志。**必须**有这一步：登录失败这类动作是外部可触发的（谁都能对着
  # 登录框刷），不设上限等于给了任何人一个把表撑爆的手段。见 R/audit.R。
  au_n <- tryCatch(dsapp_audit_gc(days = audit_days, con = dsapp_db(cfg)),
                   error = function(e) {
                     errs <<- c(errs, paste0("审计日志：", conditionMessage(e)))
                     0L
                   })

  # 同步墓碑（V13.3）。**必须有这一步**：每删一个对话就多一行，而删掉的
  # 对话越是多、墓碑涨得越快，且它们只在"还有对端没同步过"时才有用。
  # 180 天没同步过的对端，它那边的数据本来就该按全量重来（见 R/sync.R）。
  tm_n <- tryCatch(dsapp_sync_gc(days = audit_days, con = dsapp_db(cfg)),
                   error = function(e) {
                     errs <<- c(errs, paste0("同步墓碑：", conditionMessage(e)))
                     0L
                   })

  ws <- tryCatch(dsapp_gc_orphan_ws(cfg, min_age_mins = min_age_mins),
                 error = function(e) {
                   errs <<- c(errs, paste0("工作区：", conditionMessage(e)))
                   list(n = 0L, bytes = 0)
                 })
  sc <- tryCatch(dsapp_gc_scratch(cfg, max_age_hours = scratch_max_age_hours),
                 error = function(e) {
                   errs <<- c(errs, paste0("中转文件：", conditionMessage(e)))
                   list(n = 0L, bytes = 0)
                 })

  if (isTRUE(ws$db_error)) {
    errs <- c(errs, "工作区：读不到会话表，本轮不清理孤儿目录")
  }

  list(ws_n = ws$n, ws_bytes = ws$bytes, ws_skipped = ws$skipped %||% 0L,
       scratch_n = sc$n, scratch_bytes = sc$bytes, audit_n = au_n %||% 0L,
       errors = errs)
}
