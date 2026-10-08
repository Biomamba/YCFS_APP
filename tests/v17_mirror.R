#!/usr/bin/env Rscript
# =============================================================================
# Test_V17 item 2：镜像进工作区的那一层，**不许**再同步回管理区
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/v17_mirror.R .
#
# ── 用户原话 ────────────────────────────────────────────────────────────────
#
# 「文件管理页面的 T2DM–PD公开数据项目：可直接复制的Agen-8251 里面的
#   data_raw，就是空的，但是它在言出法随页面的文件管理区就是有文件的」
#
# ── 成因是一条环（每一环单看都对，合起来才出问题）────────────────────────────
#
#   ① 执行代码前 `dsapp_mirror_shared(cfg$files_dir, workdir)` 把**整个**
#      管理区映进工作区**根**：目录 `dir.create` 真建、文件铺只读软链
#      （目录不能软链 —— 软链目录会穿透写，模型一句 write.csv 就写进公共区）；
#   ② `dsapp_ws_artifacts()` 用 `find` 打快照，`-type f`/`-type d` **不跟软链**
#      ⇒ 软链文件不进、真目录进；
#   ③ 于是产物差集里全是"别的对话的文件夹名"，而 `dsapp_sync_artifacts()` 的
#      `isdir` 那一支只 `dir.create(target)` —— **不报错、不占配额**，
#      每一次任务收尾就在本对话的文件夹里重建一批别的对话的**空壳**。
#
#   生产里最刺眼的一条是自指（只有"整片镜像"才造得出这种东西）：
#     `u11/按照…-9030/按照…-9030/`
#
# ── 这份测试的重点不是"函数返回 skipped 不为 0" ─────────────────────────────
#
# 而是**管理区盘上到底有没有多出那个空壳**。只断言计数很容易写成一条永远
# 绿的判据（本仓栽过：selftest-green-is-not-coverage）。所以：
#
#   · A4/B0 是**反证**：先证明"如果不挡，差集里确实有它" —— 少了这条，
#     A1 绿了也可能只是因为夹具根本没造出镜像，而不是因为闸门生效；
#   · B 节是**唯一能杀掉"只认名字"那种写法**的一节：管理区根上真有一个
#     同名文件夹，但工作区里那一支是模型自己建的真目录（没有软链），
#     它必须照搬。只按名字挡的写法会在这里红。
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source。仓库根的 .Renviron 把
#    DSAPP_DATA_ROOT 指着**生产库**，而 Rscript **读 cwd 的 .Renviron 并且
#    它会盖掉继承的环境变量** —— 所以：先 `Sys.setenv()`，并且整份脚本
#    **必须用 `Rscript --no-environ` 跑**（只设环境变量是**不隔离**的）。
#    本仓为此在生产库里种过两行技能（renviron-beats-inherited-env）。
# ⚠️ 一条出网请求都没有。只在临时目录里读写。
# ⚠️ 断言里不写字面量常数；跟源头比。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)

NOK <- 0L; nfail <- 0L
say <- function(...) cat(sprintf(...), "\n", file = stderr())
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) { NOK <<- NOK + 1L; say("  \033[32m✓\033[0m %s", name) }
  else {
    nfail <<- nfail + 1L
    say("  \033[31m✗ %s\033[0m   %s", name, extra)
  }
}
sect <- function(x) say("\n\033[36m== %s ==\033[0m", x)

# ---- 先把数据根挪走，再 source ---------------------------------------------
tmp <- tempfile("dsapp_mirror_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
# ⚠️ 兜底自查：source 之后 data_root 必须还在 /tmp 里。这一条红了**立刻停**，
#    否则下面每一次写盘都落在生产目录上。
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}

# ---- 夹具 -------------------------------------------------------------------
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("镜像同步测试",
                         sprintf("mirror%d@example.org", stamp),
                         sprintf("138%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
con <- dsapp_db(cfg0)
u <- dsapp_user_by_email(sprintf("mirror%d@example.org", stamp), con = con)
uid <- as.integer(u$id)
cfg <- dsapp_config_user(uid, cfg0)

# 本对话（sid）—— 产物要落进它自己的管理区文件夹
sid <- db_session_create("镜像同步测试会话", user_id = uid, con = con)
# 另一个对话（sib）—— 它只是"管理区里**别人的**那个文件夹"的来源。
# ⚠️ 用同一个账号：镜像的是 `cfg$files_dir`（= data/files/u<N>/），
#    它对整个账号生效，跟对话属主无关。
sib <- db_session_create("另一个对话", user_id = uid, con = con)

dest_a <- dsapp_sync_dir(sid, cfg)   # 本对话的落点（此刻盘上还不存在）
dest_b <- dsapp_sync_dir(sib, cfg)   # 别人的文件夹（下面手工建出来）

# 别人的文件夹：一个真文件 + 一个带文件的子目录。
# ⚠️ `data_raw` 这个名字是照用户报的那条抄的 —— 症状就出在它上面。
fdir <- cfg$files_dir
dir.create(file.path(fdir, dest_b), recursive = TRUE, showWarnings = FALSE)
writeLines("raw", file.path(fdir, dest_b, "raw.csv"))
dir.create(file.path(fdir, dest_b, "data_raw"), showWarnings = FALSE)
writeLines("d1", file.path(fdir, dest_b, "data_raw", "d1.csv"))

say("\n数据根：%s", cfg$data_root)
say("账号 %d · 本对话 %s（落点 %s）", uid, sid, dest_a)
say("另一个对话 %s（落点 %s）", sib, dest_b)

# ---- 模拟"执行代码前"那一步 ------------------------------------------------
wd <- dsapp_ws_dir(sid, cfg, create = TRUE)
dsapp_ws_prune_links(wd, cfg)
mir <- dsapp_mirror_shared(cfg$files_dir, wd)
say("镜像：%d 个目录 / %d 条软链", mir$dirs, mir$linked)

# =============================================================================
sect("A 反证：不挡的话，差集里确实有那个镜像目录")
# =============================================================================

chk("★ 夹具真的把别人的文件夹镜像进了工作区根（否则下面全是空转）",
    dir.exists(file.path(wd, dest_b)),
    sprintf("wd/%s 不存在", dest_b))
chk("★ 镜像里的**文件**是软链（这一条决定了它不会进快照）",
    isTRUE(dsapp_is_link(file.path(wd, dest_b, "raw.csv"))))
chk("★ 镜像里的**子目录**是真目录（软链目录会穿透写，所以必须真建）",
    dir.exists(file.path(wd, dest_b, "data_raw")) &&
      !isTRUE(dsapp_is_link(file.path(wd, dest_b, "data_raw"))))

arts <- dsapp_ws_artifacts(sid, cfg)$name
chk("★★ 产物差集里**确实**有那个镜像目录（这就是会被同步回去的东西）",
    dest_b %in% arts,
    sprintf("快照里没有 %s；有：%s", dest_b,
            paste(utils::head(arts, 20), collapse = ", ")))
chk("★ 镜像里的子目录也在差集里（首段命中就得整支挡掉，不能只挡根）",
    paste0(dest_b, "/data_raw") %in% arts)
chk("★ 镜像进来的**软链文件**不在快照里（find 不跟软链 —— 老行为）",
    !(paste0(dest_b, "/raw.csv") %in% arts))

# ---- B/C 节的夹具，必须在 sync 之前造好 -------------------------------------
# B：管理区根上**真有一个同名文件夹**，但工作区里这一支是模型自建的真目录。
#    这一节专门杀"只按名字挡"的写法。
CLASH <- "同名区"
dir.create(file.path(fdir, CLASH), showWarnings = FALSE)
writeLines("keep-me", file.path(fdir, CLASH, "老文件.txt"))
dir.create(file.path(wd, CLASH), showWarnings = FALSE)
writeLines("report", file.path(wd, CLASH, "report.txt"))

# C：模型在**工作区根**建的空文件夹（V8 item 7 要保的那一条）。
MODELDIR <- "模型建的空文件夹"
dir.create(file.path(wd, MODELDIR), showWarnings = FALSE)

# E：最平凡的一条 —— 一个普通产物文件。
writeLines("plain", file.path(wd, "plain.csv"))

arts <- dsapp_ws_artifacts(sid, cfg)$name

# =============================================================================
sect("B 同步")
# =============================================================================

r <- dsapp_sync_artifacts(sid, arts, user_id = uid, cfg = cfg)
say("  结果：ok=%s n=%d skipped=%d blocked=%d",
    r$ok, r$n, r$skipped, r$blocked)
chk("同步本身成功", isTRUE(r$ok), r$msg)
chk("没有东西被上限刷掉（这一段不该撞上限）", identical(as.integer(r$blocked), 0L),
    sprintf("blocked=%s", r$blocked))

on_dest <- function(nm) {
  !is.null(dsapp_file_path(file.path(dest_a, nm), cfg, must_exist = TRUE))
}

# =============================================================================
sect("A1 镜像层**没有**被同步回去")
# =============================================================================

chk("★★★ 别人的文件夹**没有**在本对话的文件夹里出现（用户报的那条）",
    !on_dest(dest_b),
    sprintf("管理区里长出了 %s/%s", dest_a, dest_b))
chk("★★★ 它的子目录也没有（首段命中，整支挡掉）",
    !on_dest(file.path(dest_b, "data_raw")))
chk("★ 计数上是「挡掉了」而不是「没看见」（skipped > 0）",
    as.integer(r$skipped) > 0L,
    sprintf("skipped=%s", r$skipped))

# =============================================================================
sect("B1 同名但不是镜像的真产物 —— 必须照搬（杀掉「只认名字」的写法）")
# =============================================================================

chk("★★★ 模型自建的 `同名区/report.txt` 同步进去了",
    on_dest(file.path(CLASH, "report.txt")),
    "只按名字挡的写法会在这里红")
chk("★ 内容是逐字节对的（不是建了个空壳充数）",
    identical(readLines(dsapp_file_path(file.path(dest_a, CLASH, "report.txt"),
                                        cfg, must_exist = TRUE)),
              "report"))
chk("★ 管理区里原来那个同名文件夹里的文件**没被动过**（不是覆盖，是各在各处）",
    identical(readLines(file.path(fdir, CLASH, "老文件.txt")), "keep-me"))

# =============================================================================
sect("C V8 item 7 不回退：模型建的空文件夹，用户得看得见")
# =============================================================================

chk("★★ 工作区**根**上模型自建的空文件夹同步进去了",
    on_dest(MODELDIR),
    sprintf("管理区里没有 %s/%s", dest_a, MODELDIR))
chk("★ 它真的是个目录（不是 0 字节的假文件）",
    isTRUE(file.info(dsapp_file_path(file.path(dest_a, MODELDIR), cfg,
                                     must_exist = TRUE))$isdir))
chk("★ 它真的是空的（没被塞进什么镜像内容）",
    length(list.files(dsapp_file_path(file.path(dest_a, MODELDIR), cfg,
                                      must_exist = TRUE),
                      all.files = TRUE, no.. = TRUE)) == 0L)

# =============================================================================
sect("E 平凡路径不回退")
# =============================================================================

chk("普通产物文件照常搬进去", on_dest("plain.csv"))
chk("内容对", identical(readLines(dsapp_file_path(file.path(dest_a, "plain.csv"),
                                                  cfg, must_exist = TRUE)),
                        "plain"))

# =============================================================================
sect("F 幂等：再跑一次，结果一样，且不会把挡掉的东西放回来")
# =============================================================================

r2 <- dsapp_sync_artifacts(sid, arts, user_id = uid, cfg = cfg)
chk("第二次仍然成功", isTRUE(r2$ok), r2$msg)
chk("★★ 第二次跑完，别人的文件夹**还是**没出现（闸门不是一次性的）",
    !on_dest(dest_b))
chk("★ 同名真产物第二次也没被误挡",
    (!is.null(dsapp_file_path(file.path(dest_a, CLASH, "report.txt"), cfg,
                              must_exist = TRUE))))

# ---- 收尾 -------------------------------------------------------------------
say("\n%s  %d 条通过 / %d 条失败", if (nfail == 0L) "\033[32m全部通过\033[0m"
    else "\033[31m有失败\033[0m", NOK, nfail)
quit(status = if (nfail == 0L) 0L else 1L)
