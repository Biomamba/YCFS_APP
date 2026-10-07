#!/usr/bin/env Rscript
# =============================================================================
# 文件夹上传的落盘测试（V9 item 12）
# =============================================================================
#
# 覆盖的是 dsapp_file_save() 的 rel 参数 —— 也就是"用户选了一个文件夹"时
# 共享区里到底长什么样。
#
# ★ 为什么这个必须单独测：路径是**浏览器给的**，是应用里少有的几处
#   直接由客户端决定落盘位置的地方。搞错了不是"功能不好用"，是能写到
#   共享区外面去，或者让 A 的文件落进 B 的目录里。
#
#   而且失败方式很安静：目录没建出来 → 平铺；路径被清洗过 → 落到别的
#   名字下。两种都不报错，界面上还显示"已上传"。
#
# 用法：Rscript tests/upload_dirs.R
# 只写临时目录，不碰真实的 data/ 和任何生产数据。

suppressWarnings(suppressMessages({
  library(DBI); library(RSQLite)
}))

tmp_root <- tempfile("dsapp_upload_test_")
dir.create(tmp_root, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp_root)

# app.R 里的加载顺序（只挑这个测试用得到的，mod_* 是 Shiny 模块，跳过）
for (f in c("utils.R", "config.R", "db.R", "users.R", "audit.R",
            "skills.R", "files.R")) {
  source(file.path("R", f), local = globalenv())
}

cfg <- dsapp_config()
dsapp_init_dirs(cfg)

ok_n <- 0L; bad_n <- 0L
chk <- function(label, cond) {
  if (isTRUE(cond)) { ok_n <<- ok_n + 1L; cat(sprintf("  ✓ %s\n", label)) }
  else { bad_n <<- bad_n + 1L; cat(sprintf("  ✗ %s\n", label)) }
}

# 造一个"上传的文件"：Shiny 给的是临时文件 + 文件名两样东西
mk <- function(content) {
  p <- tempfile("up_")
  writeLines(content, p)
  p
}

# 走一遍 dsapp_file_save，返回结果（顺带把共享区清干净，用例之间互不影响）
save1 <- function(fname, rel = NULL, dir = "") {
  src <- mk("hello")
  dsapp_file_save(list(name = fname, datapath = src), cfg,
                  user_id = NULL, dir = dir, rel = rel)
}
wipe <- function() {
  unlink(list.files(cfg$files_dir, full.names = TRUE), recursive = TRUE)
}

cat("\n== 普通上传（rel = NULL）不动结构 ==\n")
wipe()
r <- save1("otu_table.csv")
chk("落在根目录", identical(r$msg, "otu_table.csv"))
chk("文件真的在", file.exists(file.path(cfg$files_dir, "otu_table.csv")))

cat("\n== 文件夹上传：单层 ==\n")
wipe()
r <- save1("otu_table.csv", rel = "16S分析/otu_table.csv")
chk("相对路径带上了目录", identical(r$msg, "16S分析/otu_table.csv"))
chk("目录被建出来", dir.exists(file.path(cfg$files_dir, "16S分析")))
chk("文件在目录里",
    file.exists(file.path(cfg$files_dir, "16S分析", "otu_table.csv")))
chk("没有平铺到根目录",
    !file.exists(file.path(cfg$files_dir, "otu_table.csv")))

cat("\n== 文件夹上传：多层 ==\n")
wipe()
r <- save1("c.txt", rel = "proj/raw/fastq/c.txt")
chk("三层目录都建出来",
    dir.exists(file.path(cfg$files_dir, "proj", "raw", "fastq")))
chk("文件在最里面",
    file.exists(file.path(cfg$files_dir, "proj/raw/fastq/c.txt")))
chk("msg 是三级相对路径", identical(r$msg, "proj/raw/fastq/c.txt"))

cat("\n== 文件夹上传：落在当前所在的那一层里 ==\n")
wipe()
dir.create(file.path(cfg$files_dir, "已存在的层"))
r <- save1("x.txt", rel = "sub/x.txt", dir = "已存在的层")
chk("目录是 [当前层]/sub",
    dir.exists(file.path(cfg$files_dir, "已存在的层", "sub")))
chk("msg 带上当前层", identical(r$msg, "已存在的层/sub/x.txt"))

cat("\n== 恶意路径一律拒绝 ==\n")
wipe()
# `..` 任何一段出现都拒（见 dsapp_rel_segments 的说明）
r <- save1("passwd", rel = "../../etc/passwd")
chk("`..` 被拒", !isTRUE(r$ok))
r <- save1("passwd", rel = "a/../../etc/passwd")
chk("藏在中间的 `..` 也被拒", !isTRUE(r$ok))
r <- save1("passwd", rel = "/etc/passwd")
chk("绝对路径被拒", !isTRUE(r$ok))
# 以 `-` 开头：这些名字最终会作为参数出现在外部命令里（见 files.R 的注释）
r <- save1("x", rel = "-rf/x")
chk("`-` 开头的段被拒", !isTRUE(r$ok))
chk("拒绝时一个文件都没落盘",
    length(list.files(cfg$files_dir, all.files = TRUE,
                      no.. = TRUE)) == 0)

cat("\n== 文件名冲突时加序号，且目录结构不受影响 ==\n")
wipe()
r1 <- save1("a.csv", rel = "d/a.csv")
r2 <- save1("a.csv", rel = "d/a.csv")
chk("第一个是原名", identical(r1$msg, "d/a.csv"))
chk("第二个加了序号", identical(r2$msg, "d/a(1).csv"))
chk("两个文件都在",
    length(list.files(file.path(cfg$files_dir, "d"))) == 2)

cat("\n== 相对路径的最后一段和 name 不一致时，以 name 为准 ==\n")
# 正常不会发生（Shiny 的 name 就是 basename），但真发生了不能张冠李戴
wipe()
r <- save1("real.csv", rel = "d/other.csv")
chk("落盘用的是 name", identical(r$msg, "d/real.csv"))
chk("目录仍旧来自 rel", dir.exists(file.path(cfg$files_dir, "d")))

cat("\n== 只给文件名不给目录（rel 里没有 /）等价于普通上传 ==\n")
wipe()
r <- save1("solo.csv", rel = "solo.csv")
chk("落在当前层", identical(r$msg, "solo.csv"))

# ---- 收尾 ----
unlink(tmp_root, recursive = TRUE)
cat(sprintf("\n通过 %d，失败 %d\n", ok_n, bad_n))
if (bad_n > 0) quit(status = 1)
