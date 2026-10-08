#!/usr/bin/env Rscript
# =============================================================================
# 生产补齐：把「工作区里有、文件管理区里没有」的产物真的搬进去
# =============================================================================
#
#   cd /data3/biomamba/analysis/DS_App
#   sudo -u shiny -H Rscript --no-environ tests/repair_prod.R        # 全库
#   sudo -u shiny -H Rscript --no-environ tests/repair_prod.R 11     # 只补 u11
#
# 干的事：对每个账号调一次 dsapp_sync_repair()（R/files.R），连跑到不再有
# 东西可搬为止（最多 3 遍），然后把"哪些文件真的进去了"对着盘核一遍。
#
# -----------------------------------------------------------------------------
# ★★ 为什么**必须**用 `sudo -u shiny`：属主不是我随便挑的
# -----------------------------------------------------------------------------
# 共享区里的文件是 0444，而"重跑一次任务、产物应该更新"那条路走的是
#
#     try(Sys.chmod(target, mode = "0644"), silent = TRUE)   # R/files.R 覆盖分支
#     file.copy(src, target, overwrite = TRUE)
#
# **两条都只对属主成立**：
#   · Sys.chmod 不是属主就 EPERM，而它包在 try(..., silent=TRUE) 里 →
#     **一声不响地没改**；
#   · file.copy(overwrite=TRUE) **不是**先 unlink 再拷，是就地以写意图打开
#     —— 2026-10-06 实测：对一个 0444 文件，**连属主自己都失败**：
#
#         before mode=444
#         WARN: cannot create file '.../a.txt', reason 'Permission denied'
#         res=FALSE          ← 内容还是旧的
#
#     所以那条路上"先 chmod 回可写"不是可选的优化，是**前提**。
#
# ⇒ 如果这些文件是 biomamba 建的，shiny 之后 chmod 不动、file.copy 也失败，
#   那个对话**每一次重跑都会静默地更新不了产物**，而 ws_published 里还记着
#   它 —— 正是 R/files.R:2241 那段注释在防的事（"用户看到的数是错的"）。
#   9030 那条流水线现在还在产出，一定会踩上。
#
# 所以：这个脚本**只认 shiny**，别的身份一律拒绝（下面第一道闸）。
# 要改判据请连同这一段一起改，别只把 stop() 注释掉。
# -----------------------------------------------------------------------------
#
# ⚠️ `--no-environ`：Rscript 会读 **cwd** 的 .Renviron 并盖掉继承的环境变量。
#    这里 cwd 就是应用根，那份 .Renviron 指的正是生产 data_root —— 但我们
#    仍然带 --no-environ，让 data_root 只由 dsapp_config() 的默认值决定，
#    然后**把它打印出来并断言**，不靠"应该是对的"。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
want <- suppressWarnings(as.integer(args[args != ""]))
want <- want[!is.na(want)]

# ---- 闸 1：身份 -------------------------------------------------------------
# ⚠️ 这道闸跑在 source("R/*.R") **之前** —— 所以这里不能用仓里的任何东西，
#    连 `%||%` 都不行（那是 R/config.R 里定义的，此刻还不存在；base R 要到
#    4.4 才有）。写 `who %||% "?"` 的话，这个脚本在**该拒绝的时候**报的是
#    "could not find function "%||%"" —— 一道看起来在拦、其实拦不住的闸。
who <- tryCatch(system("id -un", intern = TRUE), error = function(e) NA_character_)
who <- if (length(who) == 1L && !is.na(who) && nzchar(who)) who else "?"
if (!identical(who, "shiny")) {
  stop(sprintf(paste0(
    "拒绝对着生产跑：当前身份是「%s」，必须是 shiny。\n",
    "  属主不对的后果是**静默**的：那个对话以后每次重跑都更新不了产物。\n",
    "  理由见本文件头部那段（含 2026-10-06 的实测）。\n",
    "  正确跑法：  sudo -u shiny -H Rscript --no-environ tests/repair_prod.R %s"),
    who, paste(want, collapse = " ")), call. = FALSE)
}

# ---- 闸 2：目录与 data_root -------------------------------------------------
#
# ★★ 2026-10-08 加固。原来这里**只**判 `R/files.R` 在不在，于是一个
#    **长得和应用根一模一样的目录**能混过去：`~/dsapp_build/github_YCFS_APP`
#    —— 那是 `desktop/pack_github.sh` 拼出来准备推 GitHub 的**打包仓**，
#    `R/files.R` 当然有（整棵源码都在），但它**没有 data/**。
#
#    于是一路走到下面 `dsapp_config()`：应用目录下建不出 data/ ⇒ 它**静默
#    回落**到 `/home/shiny/.local/share/DS_App/data` ⇒ 那个路径也不存在 ⇒
#    `normalizePath(mustWork = TRUE)` 抛
#
#        path[1]="/home/shiny/.local/share/DS_App/data": No such file or directory
#
#    —— 一句**指向用户从没提过的路径**的报错。用户看到的和真正的原因
#    （"你在打包仓里跑，不是应用根"）之间隔了两层静默降级。
#    （同族：本仓「报错指向完全无关的地方」那几笔。）
#
#    修法：把"这就是应用根"的判据钉在**只有真应用根才有的东西**上 ——
#    `data/` 是那条分界线（打包仓按设计排除它，见 pack_github.sh 的 EX 表）。
#    并且把 data_root 那一步的失败**翻译成人话**，别再让它以 normalizePath
#    的原文示人。
app_dir <- normalizePath(getwd(), mustWork = TRUE)
APP_ROOT_HINT <- "/data3/biomamba/analysis/DS_App"
if (!file.exists(file.path(app_dir, "R", "files.R"))) {
  stop(sprintf(paste0(
    "请在应用根目录里跑（现在是 %s）。\n",
    "  应用根 = 含 R/ 与 data/ 的那个目录，本机是 %s"), app_dir, APP_ROOT_HINT),
    call. = FALSE)
}
if (!dir.exists(file.path(app_dir, "data"))) {
  stop(sprintf(paste0(
    "这个目录里有 R/ 但没有 data/ —— 它多半是**打包仓**，不是应用根。\n",
    "  现在在：%s\n",
    "  应该去：%s\n",
    "  ⚠️ 别在打包仓里跑这个脚本：那里没有生产库，dsapp_config() 会**静默**\n",
    "     回落到 ~/.local/share 下的另一个数据目录（不存在，于是报一句和\n",
    "     真正原因毫无关系的 normalizePath 错）。"),
    app_dir, APP_ROOT_HINT), call. = FALSE)
}
suppressWarnings(suppressMessages(
  for (f in list.files("R", full.names = TRUE)) source(f, local = globalenv())
))

cfg <- dsapp_config()
# ⚠️ 这里**故意**不用 mustWork = TRUE：先自己判一下在不在，好把话说清楚。
#    用 mustWork 的话，路径不存在时抛的是 normalizePath 的原文，读的人
#    根本看不出"你跑错目录了"。
raw_dr <- cfg$data_root
if (is.null(raw_dr) || length(raw_dr) != 1L || is.na(raw_dr) ||
    !dir.exists(raw_dr)) {
  stop(sprintf(paste0(
    "数据根不存在：%s\n",
    "  两种可能，下面两个值一看便知是哪种：\n",
    "     ① 跑错目录了（没在应用根里跑） ② DSAPP_DATA_ROOT 写错了\n",
    "  当前工作目录：%s\n",
    "  DSAPP_DATA_ROOT（.Renviron）：%s\n",
    "  ⚠️ 应用根应当是 %s\n",
    "  ⇒ 正确跑法：cd %s && sudo -u shiny -H Rscript --no-environ %s %s"),
    paste(raw_dr, collapse = ", "), app_dir,
    Sys.getenv("DSAPP_DATA_ROOT", unset = "(未设)"),
    APP_ROOT_HINT, APP_ROOT_HINT, "tests/repair_prod.R",
    paste(want, collapse = " ")), call. = FALSE)
}
dr  <- normalizePath(raw_dr, mustWork = TRUE)
if (startsWith(dr, "/tmp")) stop("拒绝：data_root 落在 /tmp（", dr, "）", call. = FALSE)
if (!identical(dr, file.path(app_dir, "data"))) {
  stop("拒绝：data_root 不是本应用自己的 data/：", dr, call. = FALSE)
}

cat("WHOAMI   =", who, "\n")
cat("APP_DIR  =", app_dir, "\n")
cat("DATA_ROOT=", dr, "\n")

con  <- dsapp_db(cfg)
tabs <- DBI::dbGetQuery(con,
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")$name
snap <- function() vapply(tabs, function(t)
  as.numeric(DBI::dbGetQuery(con, sprintf('SELECT count(*) AS c FROM "%s"', t))$c),
  numeric(1))
before <- snap()

# ---- 要补哪些账号：有对话的那些，u11 排最前 --------------------------------
uids <- tryCatch(
  DBI::dbGetQuery(con, paste("SELECT user_id, count(*) AS n FROM sessions",
                             "WHERE user_id IS NOT NULL GROUP BY user_id"))$user_id,
  error = function(e) integer(0))
uids <- suppressWarnings(as.integer(uids))
uids <- uids[!is.na(uids)]
if (length(want)) uids <- uids[uids %in% want]
if (!length(uids)) stop("没有要补的账号", call. = FALSE)
uids <- c(uids[uids == 11L], uids[uids != 11L])   # 用户报的那个先跑

mail <- tryCatch({
  m <- DBI::dbGetQuery(con, "SELECT id, email FROM users")
  setNames(as.character(m$email), as.character(m$id))
}, error = function(e) character(0))

gb <- function(x) sprintf("%.3f GB", as.numeric(x) / 1024^3)
verdict_fail <- character(0)
grand_n <- 0L; grand_b <- 0

# ---- 盘上属主/权限：**补齐前后各扫一次** ------------------------------------
# 这一段是"必须用 shiny"那件事的收尾证据 —— 非 shiny 属主的文件以后永远
# 覆盖不了，所以要盯住。
#
# ⚠️ 判据是"**补齐有没有让它变多**"，不是"现在有几个"。理由：这个数天生
#    就有存量（本机的 /tmp 测试实例整个是普通用户跑起来的，它的文件本来就
#    全不是 shiny）。拿绝对值当判据的话，那种环境里必然红，而红的原因和
#    补齐一点关系都没有 —— 一条**永远红**的断言和一条永远绿的同样没用。
#    （同族的账：本仓"重跑任务要自己登记 manual_run"那次。）
shiny_uid <- suppressWarnings(as.integer(system("id -u shiny", intern = TRUE)))
scan_files <- function(uid) {
  cfg_u <- dsapp_config_user(uid, cfg)
  root  <- cfg_u$files_dir
  # ⚠️ dir.exists(NULL) / dir.exists(character(0)) 给的是 logical(0)，
  #    而 `if (!logical(0))` 报的是 "argument is of length zero" ——
  #    一句和"这个账号没有目录"毫无关系的错。先判长度。
  if (is.null(root) || length(root) != 1L || is.na(root) || !dir.exists(root))
    return(c(n = 0L, foreign = 0L, odd = 0L))
  # ⚠️⚠️ `all.files` 必须是 **TRUE**（2026-10-08 修）。
  #    原来是 FALSE，于是**静默跳过所有点目录/点文件** —— 这把尺子自己少报，
  #    而屏幕上那个数看着完全合理。实测：那次跑出来"盘上 523→525"，可真值是
  #    "523→699"，差的 174 个正好是当时躺在文件区里的 `.skills/` 文档
  #    （就是 V17.1 修的那件事）。
  #    阳性对照（在 /tmp 里造 `.skills/` + 点文件 + 点目录）：FALSE 数出 2、
  #    TRUE 数出 5、`find -type f` 真值 5 ⇒ 少报的是点路径。
  #    ⚠️ 注意**现在**改完这个数不会变（那批已经清掉了）—— "改了没反应"
  #    不等于没生效，要拿对照样本量，别拿现场数据量。
  fps <- list.files(root, recursive = TRUE, full.names = TRUE, all.files = TRUE,
                    no.. = TRUE)
  if (!length(fps)) return(c(n = 0L, foreign = 0L, odd = 0L))
  inf <- file.info(fps)
  inf <- inf[!is.na(inf$isdir) & !inf$isdir, , drop = FALSE]
  if (!nrow(inf)) return(c(n = 0L, foreign = 0L, odd = 0L))
  c(n       = nrow(inf),
    foreign = sum(!is.na(inf$uid) & (inf$uid != shiny_uid)),
    # ⚠️⚠️ **不要**写 `as.integer(inf$mode) & 511L` —— `&` 在 R 里是**逻辑与**，
    #    不是按位与：`292 & 511` 算出来是 `TRUE`（非零即真），要按位与得用
    #    bitwAnd()。2026-10-06 实测踩过：那样写出来的判据**不报错**，只是把
    #    **每一个**文件都数成"权限不对"（1800/1800），而那个数看着像
    #    "整棵树都坏了"，很可能就这么信了 —— 一条恒真的判据长得像一条很强的判据。
    #    这里直接比 octmode 自己的八进制字符串，最不容易再错。
    odd     = sum(!is.na(inf$mode) & (as.character(inf$mode) != "444")))
}
fs_before <- lapply(uids, scan_files)
names(fs_before) <- as.character(uids)

for (uid in uids) {
  nm <- if (!is.null(mail[as.character(uid)]) && nzchar(mail[as.character(uid)]))
    mail[[as.character(uid)]] else ""
  cat("\n==== u", uid, "  ", nm, " ====\n", sep = "")

  # ---- 跑，跑到没有新东西可搬为止 -----------------------------------------
  # ⚠️ 第 2 遍不是"多跑一遍保险"：它就是**判据**。"缺口归零"在没有现成
  #    "缺口"字段可读的时候，唯一的度量方式就是"再算一遍，看还有没有要搬的"
  #    —— 而这一遍走的是同一条生产代码路径（dsapp_sync_repair），
  #    不是另写一份 diff 去对（那样两边一旦漂了，绿的是错的）。
  #
  # ⚠️⚠️ **`recent` 必须进判据**（2026-10-06 实测栽过）：min_age 会把
  #    "最近 5 秒内改过"的产物挡下来（会话可能正在写它，搬过去是半截的）。
  #    那批文件**不报错、不计 blocked、也不搬**，只落在 recent 里。
  #    判据要是只看 `n_files == 0 && blocked == 0`，就会在"还有 60 个没补"
  #    的时候报「✔ 缺口归零」—— 因为第一遍正好卡在这 5 秒窗口里。
  #    第一次跑出来的是 `太新=60` 配一个绿 ✔，**假绿**。
  #    （本仓同族：自检全绿 ≠ 功能被验过。）
  #    这里对 recent 的处置是"等一会儿再看"，不是"当它不存在"。
  min_age <- 5
  last <- NULL
  for (pass in 1:4) {
    r <- dsapp_sync_repair(uid, min_age = min_age, cfg = cfg)
    last <- r
    cat(sprintf("  第%d遍: 对话=%d 搬入=%-5d %-10s 跳过=%d 被挡=%d 太新=%d 出错=%d\n",
                pass, as.integer(r$n_sessions), as.integer(r$n_files),
                gb(r$n_bytes), as.integer(r$skipped), as.integer(r$blocked),
                as.integer(r$recent), length(r$errors)))
    if (length(r$blocked_files)) {
      cat("         被挡的（前 5）：", paste(head(r$blocked_files, 5), collapse = " | "), "\n")
    }
    if (length(r$errors)) {
      cat("         出错：", paste(r$errors, collapse = " || "), "\n")
    }
    grand_n <- grand_n + as.integer(r$n_files)
    grand_b <- grand_b + as.numeric(r$n_bytes)
    if (pass >= 4) break
    if (as.integer(r$n_files) == 0L && as.integer(r$blocked) == 0L) {
      if (as.integer(r$recent) == 0L) break        # 真收敛：没得搬、没被挡、没太新的
      # 还有太新的 —— 它们不是搬不动，是**现在不能搬**。不睡的话下一遍看到的
      # 还是同一批（判据看着一样，白跑），睡够 min_age 它们才够格。
      cat(sprintf("         （还有 %d 个太新，等 %d 秒再看）\n",
                  as.integer(r$recent), min_age + 1L))
      Sys.sleep(min_age + 1)
    }
  }

  # ---- 判据 ---------------------------------------------------------------
  ok <- length(last$errors) == 0L && as.integer(last$blocked) == 0L &&
        as.integer(last$n_files) == 0L && as.integer(last$recent) == 0L
  if (ok) {
    cat("  ✔ 缺口归零（没得搬了、没被挡、也没有因为「太新」被留在门外的）\n")
  } else {
    verdict_fail <- c(verdict_fail, sprintf("u%d", uid))
    if (as.integer(last$n_files) > 0)
      cat("  ✘ 还在往里搬 —— 这个对话此刻多半仍在产出；等它闲下来再跑一次\n")
    if (as.integer(last$blocked) > 0) cat("  ✘ 有被挡住的（见上）\n")
    if (length(last$errors)) cat("  ✘ 有对话出错（见上）\n")
    if (as.integer(last$recent) > 0)
      cat(sprintf(paste0("  ✘ 还有 %d 个太新没搬（最近 %d 秒内改过，现在搬会搬到半截的）",
                         "——\n     等这个对话闲下来**再跑一次本脚本**即可；补齐是幂等的，",
                         "\n     已经补进去的不会重来。\n"),
                  as.integer(last$recent), min_age))
  }
}

# ---- 对着盘核：补齐**有没有**造出不是 shiny 的文件 --------------------------
cat("\n---- 盘上核对（补齐前 -> 补齐后）----\n")
fs_after <- lapply(uids, scan_files)
names(fs_after) <- as.character(uids)
tot_b <- c(n = 0L, foreign = 0L, odd = 0L); tot_a <- tot_b
for (k in seq_along(uids)) {
  uid <- uids[[k]]
  b <- fs_before[[as.character(uid)]]; a <- fs_after[[as.character(uid)]]
  tot_b <- tot_b + b; tot_a <- tot_a + a
  grew <- a[["foreign"]] - b[["foreign"]]
  cat(sprintf("  u%-3d 文件 %d->%d   非 shiny 属主 %d->%d%s   非 0444 %d->%d\n",
              uid, b[["n"]], a[["n"]], b[["foreign"]], a[["foreign"]],
              if (grew > 0) "  ✘ 变多了" else if (grew < 0) "  (变少了)" else "",
              b[["odd"]], a[["odd"]]))
  if (grew > 0) verdict_fail <- c(verdict_fail, sprintf("u%d 新增了非 shiny 文件", uid))
}
grew_all <- tot_a[["foreign"]] - tot_b[["foreign"]]
cat(sprintf("  合计：文件 %d->%d，非 shiny 属主 %d->%d（%+d），非 0444 %d->%d\n",
            tot_b[["n"]], tot_a[["n"]], tot_b[["foreign"]], tot_a[["foreign"]],
            grew_all, tot_b[["odd"]], tot_a[["odd"]]))
if (tot_b[["foreign"]] > 0L) {
  cat("  （存量里那些非 shiny 的**不是这次造的**，判据只看有没有变多；",
      "但它们同样覆盖不了，值得单独查一下）\n", sep = "")
}
if (tot_a[["odd"]] > 0L) {
  cat("  （非 0444 的：可能是刚建出来还没打保护的，也可能是带 ACL 的，",
      "看一眼再下结论）\n", sep = "")
}

# ---- 库核对 -----------------------------------------------------------------
after <- snap()
diff <- names(which(before != after))
cat("\n---- 库改动 ----\n")
if (length(diff)) {
  for (d in diff) cat(sprintf("  %-22s %s -> %s\n", d, before[[d]], after[[d]]))
} else cat("  （没有任何表行数变化）\n")

cat("\n==== 小结 ====\n")
cat(sprintf("  共搬入 %d 个 / %s（含重试那几遍）\n", grand_n, gb(grand_b)))
if (length(verdict_fail)) {
  cat("  ✘ 没干净：", paste(verdict_fail, collapse = ", "), "\n", sep = "")
  quit(status = 1L)
}
cat("  ✔ 全部账号缺口归零\n")
