#!/usr/bin/env Rscript
# =============================================================================
# Test_V16.9 端到端：产物撞了同步上限之后，**说得出来**、也**补得回来**
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/v168_syncfix.R .
#
# ── 要回答的问题 ─────────────────────────────────────────────────────────────
#
# 用户原话：「有个很严重的问题：Biomamba_ceshi 页面里，对话页面的文件展示的
#           是全的，但是文件区的文件几乎没有，点同步也没用」。
#
# 实测全库（2026-10-06）：1247 个真产物只同步进去 949 个，缺 298 个（9 GB）。
# 三条机制叠在一起，**每一条都不报错**：
#
#   1. dsapp_sync_artifacts() 撞 DSAPP_SYNC_MAX_FILES / _BYTES 时是
#      `skipped++` 然后 next —— 不报错，而且和"内部文件"共用一个计数，
#      调用方分不出"本来就不该搬"和"没搬成"；
#   2. 自动同步传的是**本次任务的差集**，被刷掉的下轮既非新增也非改动
#      → 永远不会再进队列；
#   3. 「点同步」走的 dsapp_sync_backfill() 判据是 sync_dirs **表** ——
#      而没同步过的对话不可能撞上限 ⇒ 它精准跳过每一个需要补的对话。
#
# ── 这份测试的重点不是"函数返回对了" ────────────────────────────────────────
#
# 而是**盘上到底有没有那个文件**。A1 只要断言 `blocked == 50` 就很容易写成
# 一条永远绿的判据（本仓栽过：selftest-green-is-not-coverage）。所以每条
# 正向断言后面都跟着一次"去管理区里数一数"。
#
# ★★ A2/A6 是整份里唯一有分量的两条：它们证明**同一个上限条件下，
#    repair 能把 blocked 的那批真的搬进来**（A2 搬进来、A6 再跑不重复搬）。
#    这两条红了，说明"补齐"这个功能本身是坏的 —— 那才是用户点按钮时想要的。
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source。仓库根的 .Renviron 把
#    DSAPP_DATA_ROOT 指着**生产库**，而 Rscript **读 cwd 的 .Renviron 并且
#    它会盖掉继承的环境变量** —— 所以：先 `Sys.setenv()`，并且整份脚本
#    **必须用 `Rscript --no-environ` 跑**（只设环境变量是**不隔离**的）。
#    本仓为此在生产库里种过两行技能（renviron-beats-inherited-env）。
# ⚠️ 一条出网请求都没有。这一份只在本机读写临时目录。
# ⚠️ 断言里**不写上限常数的字面量**：从 dsapp_sync_artifacts / repair 身上
#    读出来。本仓有账：改常数漏改断言，红的那条报的错指向完全无关的地方。
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
tmp <- tempfile("dsapp_syncfix_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
# ⚠️ 兜底自查：source 之后配置里那个 data_root 必须还在 /tmp 里。
#    这一条要是红的，**立刻停下** —— 下面每一次写盘都会落在生产目录上。
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}

# ---- 夹具 -------------------------------------------------------------------
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("同步补齐测试",
                         sprintf("syncfix%d@example.org", stamp),
                         sprintf("139%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
con <- dsapp_db(cfg0)
u <- dsapp_user_by_email(sprintf("syncfix%d@example.org", stamp), con = con)
uid <- as.integer(u$id)
sid <- db_session_create("同步补齐测试会话", user_id = uid, con = con)
cfg <- dsapp_config_user(uid, cfg0)
wd  <- dsapp_ws_dir(sid, cfg, create = TRUE)

# 上限常数的**真实值**（断言里一律用它们，不写字面量）
MAXF <- get("DSAPP_SYNC_MAX_FILES", envir = globalenv())
MAXB <- get("DSAPP_SYNC_MAX_BYTES", envir = globalenv())

# 一个**稀疏**文件：apparent size = size 字节，实际只占一个块。
# 用 seek 到末尾再写 1 个字节造，不依赖 truncate(1)。
# ⚠️ 不这么造的话，"造一个 512 MB 的文件"就意味着真写 512 MB，而这一段
#    要跑很多次 —— 测试会因为磁盘而红，而不是因为代码。
#
# ⚠️⚠️ 必须**直接 `file(path, "wb")`**，不能先 `file.create()` 再 `file(path,"r+b")`。
#    后者实测 seek 不生效（size 落到 1）—— 而且它**不会报错**：文件造出来了、
#    断言里那句 "apparent size = ..." 才会红，红的位置看着像"上限判断坏了"。
make_sparse <- function(path, size) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  c2 <- file(path, "wb")
  on.exit(close(c2), add = TRUE)
  seek(c2, size - 1)
  writeBin(as.raw(0L), c2)
  invisible(path)
}

# 管理区里这个对话的同步文件夹（rel），以及"某个产物此刻真的在盘上吗"
dest_rel <- dsapp_sync_dir(sid, cfg)
on_dest <- function(nm) {
  !is.null(dsapp_file_path(file.path(dest_rel, nm), cfg, must_exist = TRUE))
}
n_on_dest <- function(nms) sum(vapply(nms, on_dest, logical(1)))
n_pub <- function() nrow(db_ws_pub_map(sid, con = dsapp_db(cfg)))

say("\n数据根：%s\n账号 %d · 对话 %s · 管理区落点 %s",
    cfg$data_root, uid, sid, dest_rel)
say("上限常数：DSAPP_SYNC_MAX_FILES=%s  DSAPP_SYNC_MAX_BYTES=%s",
    format(MAXF, scientific = FALSE), format(MAXB, scientific = FALSE))

# =============================================================================
sect("A1 撞条数上限：搬进去 MAXF 个，剩下的**说出来**而不是静默丢掉")
# =============================================================================

n_gen <- as.integer(MAXF) + 50L
names_a1 <- sprintf("a1_%04d.txt", seq_len(n_gen))
for (nm in names_a1) writeLines("x", file.path(wd, nm))

# ⚠️ **不传 max_files** —— 要的就是生产里那条默认路径所用的常数。
r1 <- dsapp_sync_artifacts(sid, names_a1, user_id = uid, cfg = cfg)
chk(sprintf("搬进去的正好是上限那么多个（%d）", MAXF),
    identical(as.integer(r1$n), as.integer(MAXF)),
    sprintf("n=%s（期望 %s）", r1$n, MAXF))
chk(sprintf("剩下的 %d 个记进 blocked", n_gen - as.integer(MAXF)),
    identical(as.integer(r1$blocked), n_gen - as.integer(MAXF)),
    sprintf("blocked=%s（期望 %d）", r1$blocked, n_gen - as.integer(MAXF)))
chk("★ blocked 和 skipped **不是一个数**：内部文件/软链才算 skipped",
    identical(as.integer(r1$skipped), 0L),
    sprintf("skipped=%s（期望 0）", r1$skipped))
chk("★ blocked_names 报的是**真被挡下**的那批，不是一个数",
    identical(sort(r1$blocked_names), sort(names_a1[-seq_len(as.integer(MAXF))])),
    sprintf("拿到 %d 个名字", length(r1$blocked_names)))
chk("★ 盘上真的有 MAXF 个（不是只在返回值里对）",
    identical(n_on_dest(names_a1), as.integer(MAXF)),
    sprintf("盘上 %d", n_on_dest(names_a1)))
chk("  而且被挡的那些**确实不在**盘上（挡住是真的挡住）",
    n_on_dest(names_a1[-seq_len(as.integer(MAXF))]) == 0L)

# =============================================================================
sect("A2 补齐：同一个上限条件下，repair 把 blocked 那批真的搬进来")
# =============================================================================

# ⚠️ min_age = 0：这一段要验的是"能不能补回来"，不是"会不会避开正在写的"。
#    避开正在写的那个行为在 A5 单独验。
r2 <- dsapp_sync_repair(uid, sid = sid, min_age = 0, cfg = cfg)
chk(sprintf("补进来 %d 个（正好是 A1 被挡下的那批）", n_gen - as.integer(MAXF)),
    identical(as.integer(r2$n_files), n_gen - as.integer(MAXF)),
    sprintf("n_files=%s（期望 %d）", r2$n_files, n_gen - as.integer(MAXF)))
chk("补齐这一轮没有再撞上限（blocked == 0）",
    identical(as.integer(r2$blocked), 0L),
    sprintf("blocked=%s", r2$blocked))
chk("没有对话出错", length(r2$errors) == 0,
    paste(r2$errors, collapse = " / "))
chk("★ repair 的默认上限**必须**大于自动同步那两个（否则补不回来）",
    isTRUE(eval(formals(dsapp_sync_repair)$max_files) > MAXF) &&
      isTRUE(eval(formals(dsapp_sync_repair)$max_bytes) > MAXB))

# =============================================================================
sect("A3 收口：库里的行数 == 盘上的文件数 == 产出的个数")
# =============================================================================

chk(sprintf("ws_published 里 %d 行（全部 %d 个产物）", n_gen, n_gen),
    identical(n_pub(), n_gen),
    sprintf("库里 %d 行", n_pub()))
chk(sprintf("管理区盘上真的有 %d 个", n_gen),
    identical(n_on_dest(names_a1), n_gen),
    sprintf("盘上 %d", n_on_dest(names_a1)))
# ⚠️ 库和盘**两个都要数**。本仓有账：只比库会看不出"库里记着、盘上没了"
#    （用户删过管理区里的文件夹那次），只比盘会看不出"盘上有、库里没记"
#    （于是下一轮重跑又搬一遍，堆出一串 plot(1).png）。
chk("★ 库和盘是同一个数（两边同时成立才算数）",
    identical(n_pub(), n_on_dest(names_a1)))

# =============================================================================
sect("A4 字节闸：单文件超上限被挡，但**不许把它后面的小文件一起丢掉**")
# =============================================================================

# A4a —— 真·超上限的单个文件，用**生产默认**那两个常数，不传参。
#        稀疏文件，所以"造一个 512 MB+1"不占磁盘、也不会真被复制
#        （它一开始就该被挡下，压根走不到 file.copy）。
big <- file.path(wd, "a4_huge.bin")
make_sparse(big, MAXB + 1)
chk(sprintf("稀疏文件造出来了，apparent size = %s",
            format(file.info(big)$size, scientific = FALSE)),
    identical(as.numeric(file.info(big)$size), as.numeric(MAXB) + 1))

writeLines("y", file.path(wd, "a4_small1.txt"))
writeLines("y", file.path(wd, "a4_small2.txt"))
r4a <- dsapp_sync_artifacts(sid, c("a4_huge.bin", "a4_small1.txt", "a4_small2.txt"),
                            user_id = uid, cfg = cfg)
chk("★★ 超大文件被挡下、且**没有 break** —— 它后面的两个小文件照样搬进去了",
    identical(as.integer(r4a$n), 2L) && identical(as.integer(r4a$blocked), 1L),
    sprintf("n=%s blocked=%s（期望 n=2 blocked=1）", r4a$n, r4a$blocked))
chk("  被挡的是那个大文件，名字对得上",
    identical(as.character(r4a$blocked_names), "a4_huge.bin"),
    paste(r4a$blocked_names, collapse = ","))
chk("  大文件确实没进管理区（挡住不是嘴上说说）", !on_dest("a4_huge.bin"))
# ⚠️ 把它删掉：A6 会再跑一次 repair，留着它就要真写 512 MB 进 /tmp，
#    而这一段（"reapir 敢用大上限"）已经由上面那条 formals 断言钉住了。
unlink(big)

# A4b —— 同样是"大的被挡、小的照过"，换成小预算再验一遍机制本身。
#        上一条走的是默认常数（512 MB），跑得慢且依赖 /tmp 的稀疏支持；
#        这一条把预算压到 KB 级，任何环境下都秒过。
mid <- file.path(wd, "a4_mid.bin")
make_sparse(mid, 2 * 1024^2)                 # 2 MB 稀疏
writeLines("y", file.path(wd, "a4_small3.txt"))
r4b <- dsapp_sync_artifacts(sid, c("a4_mid.bin", "a4_small3.txt"),
                            user_id = uid, max_bytes = 1024^2, cfg = cfg)
chk("★ 小预算下：2 MB 的被挡、它后面的小文件照样进来（`next` 不是 `break`）",
    identical(as.integer(r4b$n), 1L) && identical(as.integer(r4b$blocked), 1L),
    sprintf("n=%s blocked=%s", r4b$n, r4b$blocked))

# A4c —— 被字节闸挡下的那个，repair（默认 64 GB）能救回来。
r4c <- dsapp_sync_repair(uid, sid = sid, min_age = 0, cfg = cfg)
chk("★ repair 用放大的上限把它救回来了",
    identical(as.integer(r4c$n_files), 1L) && on_dest("a4_mid.bin"),
    sprintf("n_files=%s  盘上=%s", r4c$n_files, on_dest("a4_mid.bin")))

# =============================================================================
sect("A5 min_age：正在被写的文件要**跳过并如实报出**，不是静默复制半截")
# =============================================================================

writeLines("z", file.path(wd, "a5_fresh.txt"))     # mtime = 刚刚
r5 <- dsapp_sync_repair(uid, sid = sid, min_age = 30, cfg = cfg)
chk("刚写过的那个被跳过了", !on_dest("a5_fresh.txt"))
chk("★★ 而且**报出来了**（recent > 0）—— 静默跳过正是这次要修的病",
    identical(as.integer(r5$recent), 1L),
    sprintf("recent=%s", r5$recent))
chk("  报的是这个名字", identical(as.character(r5$recent_files), "a5_fresh.txt"),
    paste(r5$recent_files, collapse = ","))
chk("  跳过它不算 blocked（不是失败，是稍后再来）",
    identical(as.integer(r5$blocked), 0L),
    sprintf("blocked=%s", r5$blocked))

# 反面：min_age = 0 时它就该被搬进去 —— 证明上面那条不是"这个文件永远补不上"
r5b <- dsapp_sync_repair(uid, sid = sid, min_age = 0, cfg = cfg)
chk("min_age = 0 时同一个文件立刻能补上（上面那条不是死路）",
    identical(as.integer(r5b$n_files), 1L) && on_dest("a5_fresh.txt"),
    sprintf("n_files=%s 盘上=%s", r5b$n_files, on_dest("a5_fresh.txt")))

# =============================================================================
sect("A6 幂等：再补一次什么都不做（这是「可以随便点」的前提）")
# =============================================================================

r6 <- dsapp_sync_repair(uid, sid = sid, min_age = 0, cfg = cfg)
chk("第二次补齐：搬了 0 个",
    identical(as.integer(r6$n_files), 0L), sprintf("n_files=%s", r6$n_files))
chk("第二次补齐：搬了 0 字节",
    identical(as.numeric(r6$n_bytes), 0), sprintf("n_bytes=%s", r6$n_bytes))
chk("第二次补齐：没有 blocked、没有 recent、没有 errors",
    identical(as.integer(r6$blocked), 0L) &&
      identical(as.integer(r6$recent), 0L) && length(r6$errors) == 0,
    sprintf("blocked=%s recent=%s errors=%s", r6$blocked, r6$recent,
            paste(r6$errors, collapse = "/")))
chk("★ 幂等是真的幂等：多出来的那些文件没有被搬第二遍",
    identical(n_pub(), n_gen + 5L) && identical(n_on_dest(names_a1), n_gen),
    sprintf("库里 %d 行（期望 %d）· 盘上 %d",
            n_pub(), n_gen + 5L, n_on_dest(names_a1)))

# =============================================================================
sect("A7 反面：上面那组断言**确实会因为超限而红**（不是一条白送的绿）")
# =============================================================================

# ⚠️ 写法说明：判据"没劲"的典型形态是"不管代码对不对它都绿"。
#    这里把 A1 的场景**故意压到上限 1**，然后断言"结果真的和 A1 期待的不一样"。
#    哪天有人把上限闸删了（n 恒等于入参长度），下面这两条会立刻变红。
n3 <- c("a7_1.txt", "a7_2.txt", "a7_3.txt")
for (nm in n3) writeLines("w", file.path(wd, nm))
r7 <- dsapp_sync_artifacts(sid, n3, user_id = uid, max_files = 1L, cfg = cfg)
chk("★ 上限压到 1 时，只搬 1 个、挡下 2 个（闸门真的在）",
    identical(as.integer(r7$n), 1L) && identical(as.integer(r7$blocked), 2L),
    sprintf("n=%s blocked=%s", r7$n, r7$blocked))
chk("★ 因此 A1 的判据有劲：同一个调用换个上限就给出不同的数",
    !identical(as.integer(r7$n), as.integer(r7$blocked)))
chk("  被挡下的两个确实不在盘上", n_on_dest(n3[2:3]) == 0L)
chk("  收尾：repair 能把 A7 这批也补回来（上限放大这条路对每个上限都成立）",
    { rr <- dsapp_sync_repair(uid, sid = sid, min_age = 0, cfg = cfg)
      identical(as.integer(rr$n_files), 2L) && identical(n_on_dest(n3), 3L) },
    sprintf("盘上 %d/3", n_on_dest(n3)))

# =============================================================================
say("\n%s  ✓ %d 条通过   ✗ %d 条失败",
    if (nfail == 0L) "\033[32m=== 全过 ===\033[0m" else "\033[31m=== 有红的 ===\033[0m",
    NOK, nfail)
say("（临时数据根：%s）", tmp)
quit(status = if (nfail == 0L) 0L else 1L)
