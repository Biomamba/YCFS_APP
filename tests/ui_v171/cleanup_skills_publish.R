#!/usr/bin/env Rscript
# =============================================================================
# 清掉被 `dsapp_sync_repair()` 误发进**用户文件区**的 `.skills/` 文件
# =============================================================================
#   Rscript --no-environ tests/ui_v171/cleanup_skills_publish.R           # 只报不改（默认）
#   Rscript --no-environ tests/ui_v171/cleanup_skills_publish.R --apply   # 真删
#
# ## 这些东西是怎么来的
#
# `dsapp_ws_is_internal()`（R/executor.R）原来只挡 `.Rlib` / `.venv` /
# `.pylib` / `.dsapp_*`，**漏了 `.skills`** —— 而挡着它的本该是 skills.R
# 注释里那句「点目录 list.files 默认不列它」。那句话只对列目录的写法成立，
# `dsapp_ws_snapshot()` 用的却是 `find`（为的是不跟软链钻出去），find 列点文件。
# 于是技能配套文档进了 `dsapp_ws_artifacts()`，被「盘上快照 − 已发布」这个
# **全量**差集一把捞进了用户的文件管理区。
#
# 平时不发作：自动同步传的是**本次任务的产物**（R/taskrun.R:399），不含技能
# 文件；backfill 又只补没有 sync_dirs 行的对话。只有手动 repair 会全量扫。
# 2026-10-08 实测：一次 repair 就往 u1 发了 174 个（u11 另 1 个，合计 175）。
#
# 代码那半边已经修了（`dsapp_ws_is_internal` 点名加上了 `.skills`）。
# 这个脚本收拾**已经发出去的那些**。
#
# ## 为什么删掉是安全的
#
# 文件区那份是**副本**；工作区里 `<workdir>/.skills/` 那份才是模型真正读的
# （R/prompts.R 明着让模型去读 `.skills/<技能名>/SKILL.md`），技能源在
# `skills_builtin/` 和 skills 表里。删这三样的**任何一个副本**都不影响功能。
#
# ## 两条纪律
#
# 1. **先删盘、后删库**，顺序不能反 —— 但理由**不是**"扫盘会把行登记回来"
#    （那句是错的，2026-10-08 查证后改的，见下）：这些行是
#    `dsapp_sync_artifacts()`（R/files.R:2419-2423）在**发布那一刻**同一轮里
#    写进去的（`dsapp_file_owner_set()` + `db_ws_pub_set()`），**跟扫盘无关**。
#    真正的机制是：盘上文件还在、而 `ws_published` 行被删了 ⇒
#    `dsapp_sync_repair()` 的「盘上快照 − 已发布」差集里又是这 175 个 ⇒
#    下一次谁点一次"导入历史产物"就**重新发布一遍**，两处行一起回来。
#
#    ⚠️ 顺带纠正一个容易想当然的点：`file_owner` 那半边**本来就自愈**。
#       `dsapp_files_sync_owners()`（R/users.R:1893）走的是
#       `dsapp_shared_scan()`，而那个函数是
#       `find <dir> -type f -not -path '*/.*'` —— **按设计就不扫点路径**
#       （V13.10 起）。管理页渲染时还会先跑一次 `dsapp_files_purge_dotfiles()`
#       （R/mod_admin.R:2015）。⇒ 那 174 行只要碰上一次管理页就会自己没了。
#       **别把"它自己会好"当成"清干净了"**：文件还在盘上、ws_published 还在，
#       用户在文件管理区里照样看得见那 175 个东西 —— 那才是用户能感知的部分。
# 2. **判据只认 `.skills` 这一整段**，不是"任意点路径"。用户的
#    `dsapp_files_purge_dotfiles()` 取的是后者（它的理由是"删错点文件的代价
#    是零"），但那是一条更宽的断言，不该拿它来执行一次**已经批准过的、
#    范围明确**的删除。范围外的点路径这里只**报**不删。
# =============================================================================

suppressMessages(library(shiny))

args <- commandArgs(trailingOnly = TRUE)
APPLY <- "--apply" %in% args

## ---- 装载应用代码（和 selftest.R 一样的做法：不 source mod_*）--------------
app_dir <- normalizePath(".", mustWork = TRUE)
for (f in list.files("R", full.names = TRUE)) {
  if (grepl("^mod_", basename(f))) next
  source(f, local = globalenv())
}
# ⚠️ 上面那些文件里可能设 DSAPP_DATA_ROOT 之类；求值完再取一次配置。
cfg <- dsapp_config()
root <- cfg$data_root
# ⚠️⚠️ 这里要的是 **files_root**（`data/files`，所有账号管理区的物理父目录），
#     **不是 files_dir**。第一版写的就是 `cfg$files_dir`，跑出来是
#     `data/files/_anon` —— 一个**永远是空的**目录（config.R:1232 故意这么设的：
#     忘了带上账号时要"错得响、错得安全"）。它确实响得对：不算这条的话，
#     `--apply` 会把 174+174 行库删掉、而**一个盘上文件都没动**，
#     下一次谁打开管理页 `dsapp_files_sync_owners()` 又把行登记回来 ——
#     一次标准的**假修**，屏幕上还写着"✔ 清干净了"。
fdir <- cfg$files_root

cat(sprintf("APP_DIR    = %s\n", app_dir))
cat(sprintf("DATA_ROOT  = %s\n", root))
cat(sprintf("files_root = %s\n", fdir))
if (!dir.exists(fdir)) stop("files_root 不存在，先别删：", fdir)
# 防呆：万一被解析成 "/" 或者数据根自己，下面那句 unlink 就是灾难
if (normalizePath(fdir) %in% c("/", normalizePath(root))) {
  stop("files_root 解析得不对（= ", fdir, "），拒绝继续")
}
# 结构判据：一颗正常的 files_root 底下必须有一个 `u<数字>` 账号区。
# 只判 dir.exists 是不够的 —— `_anon` 也是存在的目录，而它永远空着，
# 于是"扫到 0 个"和"路径接错了"在屏幕上完全一样。
ents <- list.files(fdir)
if (!any(grepl("^u[0-9]+$", ents)) && !"_anon" %in% ents) {
  stop("files_root 底下既没有账号区也没有 _anon（= ", fdir,
       "），路径多半接错了，拒绝继续")
}

cat(sprintf("模式      = %s\n\n", if (APPLY) "★ APPLY（真删）" else "DRY-RUN（只报不改）"))

## ---- ① 盘上：找出文件区里所有 `.skills` 目录 --------------------------------
# ⚠️ 只走 files_dir。工作区（workspaces_dir）里那些 `.skills` 是**对的**，
#    模型就是靠它们读技能附件的，绝对不能碰。
sk_dirs <- list.dirs(fdir, recursive = TRUE, full.names = TRUE)
sk_dirs <- sk_dirs[basename(sk_dirs) == ".skills"]

n_files <- vapply(sk_dirs, function(d)
  length(list.files(d, recursive = TRUE, all.files = TRUE, no.. = TRUE)),
  integer(1))
n_bytes <- vapply(sk_dirs, function(d) {
  fs <- list.files(d, recursive = TRUE, all.files = TRUE, no.. = TRUE,
                   full.names = TRUE)
  if (!length(fs)) return(0)
  sum(file.info(fs)$size, na.rm = TRUE)
}, numeric(1))

cat(sprintf("① 盘上：文件区里有 %d 个 `.skills` 目录，共 %d 个文件 / %.3f MB\n",
            length(sk_dirs), sum(n_files), sum(n_bytes) / 1024^2))
for (i in seq_along(sk_dirs)) {
  cat(sprintf("     %4d 文件  %8.1f KB  %s\n", n_files[i], n_bytes[i] / 1024,
              sub(paste0("^", fdir, "/?"), "", sk_dirs[i])))
}

## ---- ② 库里：两处点路径行（先只数，不删）-----------------------------------
con <- dsapp_db(cfg)

seg_has <- function(x, what) {
  if (!length(x)) return(logical(0))
  vapply(strsplit(x, "/", fixed = TRUE),
         function(s) any(s == what), logical(1), USE.NAMES = FALSE)
}

fo <- tryCatch(DBI::dbGetQuery(con, "SELECT name FROM file_owner")$name,
               error = function(e) character(0))
fo_sk <- fo[seg_has(fo, ".skills")]
# 范围外的点路径：只报不删（见文件头纪律 2）
fo_other <- setdiff(fo[grepl("(^|/)\\.[^/]", fo)], fo_sk)

wp <- tryCatch(DBI::dbGetQuery(con,
        "SELECT id, session_id, name, dest FROM ws_published"),
        error = function(e) NULL)
wp_sk <- if (is.null(wp) || !nrow(wp)) wp else
  wp[seg_has(wp$name, ".skills") | seg_has(wp$dest, ".skills"), , drop = FALSE]

cat(sprintf("\n② 库里：file_owner %d 行、ws_published %d 行带 `.skills` 段\n",
            length(fo_sk), if (is.null(wp_sk)) 0L else nrow(wp_sk)))
if (length(fo_other))
  cat(sprintf("   ⚠️ 另有 %d 行是**范围外**的点路径，只报不删：%s\n",
              length(fo_other), paste(utils::head(fo_other, 5), collapse = ", ")))

# ★ 两把尺子互相对一次：盘上说有、库上说没有（或反过来），都说明**其中一把
#   是坏的**，这时候删任何东西都是在赌。第一版就是在这里露的馅 ——
#   盘上扫出 0 个目录、而库里有 174+174 行，那两个数不该同时成立。
n_wp_sk <- if (is.null(wp_sk)) 0L else nrow(wp_sk)
if ((length(sk_dirs) == 0L) != (length(fo_sk) == 0L && n_wp_sk == 0L)) {
  stop(sprintf(paste0("盘和库对不上：盘上 %d 个 `.skills` 目录，库里 ",
                      "file_owner %d 行 / ws_published %d 行。",
                      "两边不该只有一个有 —— 先查是哪把尺子坏了，别删。"),
               length(sk_dirs), length(fo_sk), n_wp_sk))
}

## ---- ③ 动手（顺序：先盘后库，见文件头）-------------------------------------
if (!APPLY) {
  cat("\nDRY-RUN 结束。要真删就加 --apply。\n")
  quit(status = 0)
}

if (length(sk_dirs)) {
  for (d in sk_dirs) unlink(d, recursive = TRUE, force = TRUE)
}
# 删完复扫一遍 —— 不复扫的话，"unlink 因为权限没删掉"和"删干净了"
# 在屏幕上长得一样（本仓栽过：拿不到元素就跳过一律改红）。
left_dirs <- list.dirs(fdir, recursive = TRUE, full.names = TRUE)
left_dirs <- left_dirs[basename(left_dirs) == ".skills"]
left_files <- length(list.files(left_dirs, recursive = TRUE, all.files = TRUE,
                                no.. = TRUE))

n_fo <- 0L
for (k in fo_sk) n_fo <- n_fo + DBI::dbExecute(con,
  "DELETE FROM file_owner WHERE name = ?", params = list(k))
n_wp <- 0L
if (!is.null(wp_sk) && nrow(wp_sk)) {
  for (k in wp_sk$id) n_wp <- n_wp + DBI::dbExecute(con,
    "DELETE FROM ws_published WHERE id = ?", params = list(k))
}

# ---- 核对：库和盘两边都要真的归零 ----
fo2 <- DBI::dbGetQuery(con, "SELECT name FROM file_owner")$name
wp2 <- DBI::dbGetQuery(con, "SELECT id, name, dest FROM ws_published")
cat(sprintf("\n③ 清完：盘上剩 %d 个 `.skills` 目录 / %d 个文件；" ,
            length(left_dirs), left_files))
cat(sprintf("file_owner 点路径行 %d → %d；ws_published 点路径行 %d → %d\n",
            length(fo_sk), sum(seg_has(fo2, ".skills")),
            if (is.null(wp_sk)) 0L else nrow(wp_sk),
            sum(seg_has(wp2$name, ".skills") | seg_has(wp2$dest, ".skills"))))

ok <- length(left_dirs) == 0L && left_files == 0L &&
      !any(seg_has(fo2, ".skills")) &&
      !any(seg_has(wp2$name, ".skills") | seg_has(wp2$dest, ".skills"))
cat(sprintf("实际删掉：file_owner %d 行、ws_published %d 行、目录 %d 个\n",
            n_fo, n_wp, length(sk_dirs)))
if (!ok) { cat("\n\033[31m✗ 没清干净，上面是残留\033[0m\n"); quit(status = 1) }
cat("\n\033[32m✔ 盘和库两边都归零\033[0m\n")
