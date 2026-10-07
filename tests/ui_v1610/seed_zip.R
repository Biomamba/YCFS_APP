#!/usr/bin/env Rscript
# =============================================================================
# 给 tests/ui_v1610/probe_filezip.py 造一个**两个根都有东西**的对话
# =============================================================================
#
#   Rscript --no-environ tests/ui_v1610/seed_zip.R <app_dir> <data_root> <email>
#
# 干的事：
#   1. 按邮箱找到探针刚注册的那个账号（找不到就退出码 2）
#   2. 建一个对话，往它工作区里写 5 个文件（含一层子目录）
#   3. **真的调一次 dsapp_sync_artifacts()**，把其中 2 个收进文件管理区
#   4. 把关键数字打到 stdout（`KEY=VALUE` 一行一个），探针去解析
#
# ⚠️⚠️ 为什么要"同步 2 个、留 3 个在没同步的状态"：这样这一层里**两个根
#    同时在**（文件区那 2 行带 `files:` 前缀、工作区那 3 行不带）。这正是
#    `dsapp_zip_plan_multi()` 存在的唯一理由（单根的 `dsapp_zip_plan()` 喂两组
#    坐标进去会**静默丢掉一组**），也是"点一下按钮打出来的包里两边的文件都
#    在"这句断言能成立的前提。全都同步过去的话这道题就退化成单根了 ——
#    而单根那条路早就被文件页用了几个月，验了等于没验。
#
# ⚠️ 名字里带中文和空格：`dsapp_safe_name()` 那条路（下载名洗字符）要真的
#    走一遍。上一版归档里就是因为文件名全是有序 ASCII，那条断言从没跑过。
#
# ⚠️⚠️ 必须 `--no-environ` 跑，并且 data_root 由**命令行**给。
#    仓库根那份 .Renviron 指着生产库，而 Rscript 会读 **cwd** 的 .Renviron
#    并**盖掉**继承的环境变量 —— 本仓为此在生产库里种过东西。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop("用法：seed_zip.R <app_dir> <data_root> <email>")
app_dir   <- args[[1]]
data_root <- args[[2]]
email     <- args[[3]]

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
# ⚠️ **不能**写 `!nrow(u)`：dsapp_user_by_email() 回来的是 `as.list(d[1, ])`，
#    一个 **list** 不是 data.frame，`nrow()` 给 NULL，而 `!NULL` 报的是
#    `invalid argument type` —— 一句和"这个人没找到"毫无关系的错。
if (is.null(u) || !length(u)) {
  message("找不到账号：", email)
  quit(status = 2L)
}
uid <- as.integer(u$id[[1]])

title <- sprintf("打包下载测试-%s", format(Sys.time(), "%H%M%S"))
sid <- db_session_create(title, user_id = uid, con = con)
cfg <- dsapp_config_user(uid, cfg0)
wd  <- dsapp_ws_dir(sid, cfg, create = TRUE)

# 3 个留在工作区（没同步）+ 1 层子目录 + 2 个会被同步进文件区。
# ⚠️ 名字里故意带中文/空格/`+`：下载名的清洗那条路要真的走一遍。
ws_only <- c("差异基因 表.csv", "volcano plot.png", "README.txt")
sub_rel <- file.path("results", "figures")
dir.create(file.path(wd, sub_rel), recursive = TRUE, showWarnings = FALSE)
writeLines("gene,logFC\nTP53,2.1", file.path(wd, ws_only[[1]]))
writeLines("png-bytes", file.path(wd, ws_only[[2]]))
writeLines("readme", file.path(wd, ws_only[[3]]))
writeLines("png-bytes", file.path(wd, sub_rel, "top10.png"))
writeLines("png-bytes", file.path(wd, sub_rel, "hub genes.png"))

to_pub <- c("analysis.R", "sessionInfo.txt")
writeLines("print(1)", file.path(wd, to_pub[[1]]))
writeLines("R 4.4.1", file.path(wd, to_pub[[2]]))

# ★ 真走一遍同步那条路（别自己往 data/files 里拷 —— 那样种出来的场景
#   在旧代码上也是绿的，理由见 tests/ui_v168/seed_overlimit.R 的头注释）。
r <- dsapp_sync_artifacts(sid, to_pub, user_id = uid, cfg = cfg)
rel <- dsapp_sync_dir(sid, cfg)

n_ws <- length(list.files(wd, recursive = TRUE))
cat(sprintf("SID=%s\n", sid))
cat(sprintf("UID=%d\n", uid))
cat(sprintf("TITLE=%s\n", title))
cat(sprintf("DIR=%s\n", rel))
cat(sprintf("WORKDIR=%s\n", wd))
cat(sprintf("PUB=%d\n", as.integer(r$n %||% 0L)))
# 这一层（根）一共有多少**行** —— 探针拿它当"按钮上那个 N"的期望值。
# 根这一层 = 文件区根下 2 个文件 + 工作区根下 3 个文件 + 1 个子目录
# （`results/`，它是工作区里那一层，会被列成一行目录）。
# ⚠️ 用**数**出来而不是写死：夹具改了名字这里就跟着变，不写死一个 6。
cat(sprintf("WS_ONLY=%d\n", length(ws_only)))
cat(sprintf("SUB=%s\n", sub_rel))
cat(sprintf("ON_DISK=%d\n", n_ws))
