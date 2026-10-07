#!/usr/bin/env Rscript
# =============================================================================
# 给 tests/ui_v168/probe_syncrepair.py 造一个**真的撞过上限**的对话
# =============================================================================
#
#   Rscript --no-environ tests/ui_v168/seed_overlimit.R <app_dir> <data_root> <email> [多造几个]
#
# 干的事：
#   1. 按邮箱找到探针刚注册的那个账号（找不到就退出码 2）
#   2. 建一个对话，往它工作区里写 `DSAPP_SYNC_MAX_FILES + N` 个小文件
#   3. **用默认上限**跑一次 dsapp_sync_artifacts() —— 这正是生产里那条
#      "静默丢弃"的路径：前 300 个进管理区，后 N 个既不报错也不重试
#   4. 把关键数字打到 stdout（`KEY=VALUE` 一行一个），探针去解析
#
# ⚠️⚠️ 为什么这一步必须真的调 dsapp_sync_artifacts、而不是探针自己往
#    data/files/ 里拷文件：**sync_dirs 那一行是这道题的全部关键**。
#    点「导入对话产物」之所以"没用"，就是因为老的 dsapp_sync_backfill 拿
#    sync_dirs 当判据、而**撞过上限的对话必然有那一行**，于是被精准跳过。
#    自己拷文件造出来的"缺"，缺的恰好是那一行 —— 那样种出来的场景
#    **在旧代码上也是绿的**，整条探针会变成"验了个空气"。
#
# ⚠️⚠️ 必须 `--no-environ` 跑，并且 data_root 由**命令行**给。
#    仓库根那份 .Renviron 指着生产库，而 Rscript 会读 **cwd** 的 .Renviron
#    并**盖掉**继承的环境变量 —— 本仓为此在生产库里种过东西。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop("用法：seed_overlimit.R <app_dir> <data_root> <email> [extra]")
app_dir   <- args[[1]]
data_root <- args[[2]]
email     <- args[[3]]
n_extra   <- if (length(args) >= 4) as.integer(args[[4]]) else 60L

setwd(app_dir)
Sys.setenv(DSAPP_DATA_ROOT = data_root)

suppressWarnings(suppressMessages({
  for (f in list.files("R", full.names = TRUE)) source(f, local = globalenv())
}))

cfg0 <- dsapp_config()
# ⚠️ 兜底自查：写盘之前先确认真的落在临时目录里。这一条红了就**立刻停**，
#    不然后面每一下都在往别的地方写。
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 写：%s", cfg0$data_root))
}

con <- dsapp_db(cfg0)
u <- dsapp_user_by_email(email, con = con)
# ⚠️⚠️ **不能**写 `!nrow(u)`：dsapp_user_by_email() 走的是 dsapp_user_row()，
#     回来的是 `as.list(d[1, , drop = FALSE])` —— 一个 **list**，不是 data.frame。
#     `nrow()` 对 list 返回 NULL，而 `!NULL` 不报"长度为 0"，报的是
#     **`invalid argument type`** —— 一句和"这个人没找到"毫无关系的错。
#     这一段是从 R/share.R:97 那段注释抄来的教训（本仓 2026-09-16 在自检里
#     踩过同一脚）。判"查没查到"只需要 is.null()。
if (is.null(u) || !length(u)) {
  message("找不到账号：", email)
  quit(status = 2L)
}
uid <- as.integer(u$id[[1]])

sid <- db_session_create("超限同步测试对话", user_id = uid, con = con)
cfg <- dsapp_config_user(uid, cfg0)
wd  <- dsapp_ws_dir(sid, cfg, create = TRUE)

n_gen <- as.integer(DSAPP_SYNC_MAX_FILES) + n_extra
nms <- sprintf("seed_%04d.txt", seq_len(n_gen))
for (nm in nms) writeLines("x", file.path(wd, nm))

# ★ 默认上限 —— 不要传 max_files / max_bytes。传了就种不出"被上限刷掉"这件事。
r <- dsapp_sync_artifacts(sid, nms, user_id = uid, cfg = cfg)

rel <- dsapp_sync_dir(sid, cfg)
n_on_disk <- sum(vapply(nms, function(nm)
  !is.null(dsapp_file_path(file.path(rel, nm), cfg, must_exist = TRUE)),
  logical(1)))

cat(sprintf("SID=%s\n", sid))
cat(sprintf("UID=%d\n", uid))
cat(sprintf("GEN=%d\n", n_gen))
cat(sprintf("PUB=%d\n", as.integer(r$n)))
# ⚠️⚠️ **不要**写成 `cat(sprintf("BLOCKED=%d\n", as.integer(r$blocked)))`。
#    在本版（V16.9）上没问题，但这份夹具还要能对着**上一版归档**跑（那是
#    "探针到底抓不抓得住这个 bug"的对照）。V16.8 的 dsapp_sync_artifacts
#    根本没有 `blocked` 这个字段 → `as.integer(NULL)` 是 **integer(0)** →
#    `sprintf` 给的是 **character(0)** → `cat` **一个字都不打**。于是探针
#    那边 KeyError，报的是"我解析不到 BLOCKED"，而不是"旧代码没有这个字段"
#    —— 差别很大：前者像夹具坏了，后者才是结论。
#    （这正是本仓记过的 `paste0` 零长度坑的同一族。）
blk <- suppressWarnings(as.integer(r$blocked %||% NA_integer_))
cat(sprintf("BLOCKED=%s\n",
            if (length(blk) == 1L && !is.na(blk)) as.character(blk) else "NA"))
cat(sprintf("ON_DISK=%d\n", n_on_disk))
cat(sprintf("DIR=%s\n", rel))
cat(sprintf("WORKDIR=%s\n", wd))
