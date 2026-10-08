#!/usr/bin/env Rscript
# =============================================================================
# Test_V17.2 item 1：删对话 → 文件管理区里那批产物也要跟着走
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/ui_v172/t_session_files_purge.R .
#
# ── 用户原话 ────────────────────────────────────────────────────────────────
#
# 「Biomamba_ceshi账号下，会话删除后，文件页面的文件还存在」
#
# ── 成因 ────────────────────────────────────────────────────────────────────
#
# `db_session_delete()` 会删掉 `ws_published` 的行，但**盘上一个字节都不动**。
# 删对话那条路只调了 `dsapp_ws_delete()`，它删的是**工作区**
# （`data/workspaces/chat-<sid>/`）；产物同步出去的那一份在
# `data/files/u<N>/<对话文件夹>/` 里。库里的行没了、盘上的文件还在 ——
# 文件页里那个文件夹就永远挂在那儿。
#
# ── 这份测试盯的是**盘**，不是返回值 ────────────────────────────────────────
#
# 只断言"函数说它删了 3 个"是本仓栽过好几次的弱判据（selftest-green-is-not-
# coverage）：计数对而盘上文件还在，屏幕上和"修好了"一模一样。所以每一节都
# 落到 `file.exists()` / `dir.exists()` 上，而且**阴性对照和阳性对照都在**：
#
#   · B0/B1 是**阴性对照**：用户自己传进那个文件夹的东西必须**原封不动**
#     （上传落点是"当前所在的这一层"，见 mod_files.R 的 perform_upload）。
#     少了这条，"删干净了"和"顺手把用户的文件一起端了"在屏幕上没有区别。
#   · E 节是**顺序的反证**：先 `db_session_delete()` 再 purge ⇒ 一个文件都
#     删不掉（`dsapp_config_sid()` 查不到主人 ⇒ 落到 `_anon` 空目录）。
#     这一节存在的意义是：把"必须放在删库之前"这条从注释里的话变成一条
#     会红的判据 —— 哪天有人图省事把它挪到后面，这里立刻响。
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source。仓库根的 .Renviron 把
#    DSAPP_DATA_ROOT 指着**生产库**，而 Rscript **读 cwd 的 .Renviron 并且
#    它会盖掉继承的环境变量** —— 所以整份脚本**必须用 `Rscript --no-environ`
#    跑**（只设环境变量是**不隔离**的，本仓为此在生产库里种过两行技能）。
# ⚠️ 一条出网请求都没有，只在临时目录里读写。
# ⚠️ 断言里不写字面量常数。
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
tmp <- tempfile("dsapp_v172_purge_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
# ⚠️ 兜底自查：source 之后 data_root 必须还在 /tmp 里。红了**立刻停**。
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}

# ---- 夹具 -------------------------------------------------------------------
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("删除测试",
                         sprintf("purge%d@example.org", stamp),
                         sprintf("139%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
con <- dsapp_db(cfg0)
u <- dsapp_user_by_email(sprintf("purge%d@example.org", stamp), con = con)
uid <- as.integer(u$id)
cfg <- dsapp_config_user(uid, cfg0)
fdir <- cfg$files_dir

say("\n数据根：%s", cfg$data_root)
say("账号 %d · 管理区 %s", uid, fdir)

# 造一个"已经发布过东西"的对话：文件在盘上、两处库行都在 —— 这正是删对话
# 那一刻的真实状态。
mk_pub_session <- function(title) {
  sid <- db_session_create(title, user_id = uid, con = con)
  rel <- dsapp_sync_dir(sid, cfg)          # 定下落点（写 sync_dirs 行）
  dir.create(file.path(fdir, rel), recursive = TRUE, showWarnings = FALSE)
  list(sid = sid, rel = rel)
}

# 把一个文件"发布"进管理区（盘 + file_owner + ws_published 三处一起）
pub <- function(sid, dest, content = "x") {
  p <- file.path(fdir, dest)
  dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
  writeLines(content, p)
  dsapp_file_owner_set(dest, uid, con = con)
  db_ws_pub_set(sid, dest, dest, con = con)
  p
}
owner_of <- function(dest) {
  r <- DBI::dbGetQuery(con, "SELECT name FROM file_owner WHERE name = ?",
                       params = list(dsapp_owner_key(dest, uid)))$name
  length(r) > 0L
}
pub_rows <- function(sid) {
  tryCatch(DBI::dbGetQuery(con,
    "SELECT dest FROM ws_published WHERE session_id = ?",
    params = list(sid))$dest, error = function(e) character(0))
}
syncdir_rows <- function(sid) {
  tryCatch(DBI::dbGetQuery(con,
    "SELECT dir FROM sync_dirs WHERE session_id = ?",
    params = list(sid))$dir, error = function(e) character(0))
}

# =============================================================================
sect("A 正常路径：一个对话，自动同步的 + 手动发布的 + 用户自己传的")
# =============================================================================
A <- mk_pub_session("删除测试甲")
a1 <- pub(A$sid, file.path(A$rel, "results", "a1.csv"), "a1")
a2 <- pub(A$sid, file.path(A$rel, "a2.csv"), "a2")
am <- pub(A$sid, "手动发布.csv", "manual")          # 手动发布：落在**根**上
# 用户自己传进这个文件夹的（不在 ws_published 里 —— 上传走的是另一条路）
au <- file.path(fdir, A$rel, "我自己传的.csv")
writeLines("mine", au)
dsapp_file_owner_set(file.path(A$rel, "我自己传的.csv"), uid, con = con)
# 一个空目录（模型建过、东西被删光了的那种）
dir.create(file.path(fdir, A$rel, "空目录"), showWarnings = FALSE)

say("甲 %s · 落点 %s", A$sid, A$rel)
chk("夹具齐了：三处发布 + 用户自己的一个文件",
    all(file.exists(a1, a2, am, au)) && length(pub_rows(A$sid)) == 3L,
    sprintf("盘上 %s，ws_published %d 行",
            paste(file.exists(c(a1, a2, am, au)), collapse = ","),
            length(pub_rows(A$sid))))

d0 <- dsapp_session_files_purge(A$sid, cfg, dry = TRUE)
chk("★ dry 只算不删：说 3 个，盘上一个都没动",
    identical(as.integer(d0$n), 3L) && all(file.exists(a1, a2, am, au)),
    sprintf("n=%s，盘上 %s", d0$n, paste(file.exists(c(a1, a2, am, au)), collapse = ",")))
chk("★ dry 说得出同步文件夹里还留着 1 个（用户自己那个）",
    identical(as.integer(d0$kept), 1L) && identical(d0$dir, A$rel),
    sprintf("kept=%s dir=%s", d0$kept, d0$dir))

r <- dsapp_session_files_purge(A$sid, cfg)

# ★★ 判据是**盘**，不是返回值
chk("★★ 自动同步出去的产物从盘上没了",
    !file.exists(a1) && !file.exists(a2),
    sprintf("a1=%s a2=%s", file.exists(a1), file.exists(a2)))
chk("★★ 手动发布到根上的那个也没了",
    !file.exists(am), sprintf("还在：%s", am))
chk("★ 删完之后空掉的子目录被剪掉了（产物多在 results/ 里）",
    !dir.exists(file.path(fdir, A$rel, "results")))
chk("★ 空目录也没了", !dir.exists(file.path(fdir, A$rel, "空目录")))
chk("★★ 归属行跟着走（file_owner 不留指向空气的行）",
    !owner_of(file.path(A$rel, "results", "a1.csv")) &&
      !owner_of(file.path(A$rel, "a2.csv")) && !owner_of("手动发布.csv"))
chk("★ 返回值对得上盘：删了 3 个", identical(as.integer(r$n), 3L),
    sprintf("n=%s", r$n))

# ---- 阴性对照：用户自己放进去的那个，一个字都不能动 ----
chk("★★ 阴性对照：用户自己传进那个文件夹的文件**原封不动**",
    file.exists(au) && identical(readLines(au), "mine"),
    sprintf("还在吗 %s", file.exists(au)))
chk("★★ 文件夹本身也留着（里面还有用户的东西，不能整个端掉）",
    dir.exists(file.path(fdir, A$rel)))
chk("★ kept 报的是 1", identical(as.integer(r$kept), 1L),
    sprintf("kept=%s", r$kept))
chk("★ removed_dir 是 FALSE（文件夹没删）", !isTRUE(r$removed_dir))

# =============================================================================
sect("B 删库收尾：两处行都要走，且再跑一次是空转")
# =============================================================================
invisible(db_session_delete(A$sid, con = con, cfg = cfg))
chk("★ ws_published 的行没了", length(pub_rows(A$sid)) == 0L,
    sprintf("还剩 %d 行", length(pub_rows(A$sid))))
chk("★★ sync_dirs 的行也没了（以前一直漏着 —— 它会占着文件夹名字）",
    length(syncdir_rows(A$sid)) == 0L,
    sprintf("还剩 %s", paste(syncdir_rows(A$sid), collapse = ",")))
r2 <- dsapp_session_files_purge(A$sid, cfg)
chk("★ 幂等：会话都没了再跑一次，一个都不删、不报错",
    identical(as.integer(r2$n), 0L))
chk("★ 阴性对照仍然是阴性：用户那个文件还在",
    file.exists(au) && dir.exists(file.path(fdir, A$rel)))

# =============================================================================
sect("C 文件夹里没有用户的东西 ⇒ 整个文件夹要消失")
# =============================================================================
C <- mk_pub_session("删除测试丙")
c1 <- pub(C$sid, file.path(C$rel, "x", "c1.csv"), "c1")
c2 <- pub(C$sid, file.path(C$rel, "c2.csv"), "c2")
rc <- dsapp_session_files_purge(C$sid, cfg)
chk("★★ 盘上两个文件都没了", !file.exists(c1) && !file.exists(c2))
chk("★★ 整个对话文件夹也没了（不然界面上还挂着一个空壳）",
    !dir.exists(file.path(fdir, C$rel)),
    sprintf("还在：%s", file.path(fdir, C$rel)))
chk("★ removed_dir 是 TRUE", isTRUE(rc$removed_dir))
chk("★ kept 是 0", identical(as.integer(rc$kept), 0L))

# =============================================================================
sect("D 别的对话发布过同一个落点 ⇒ 不许动它")
# =============================================================================
D  <- mk_pub_session("删除测试丁")
E  <- mk_pub_session("删除测试戊")
shared <- file.path(D$rel, "shared.csv")
dp <- pub(D$sid, shared, "d")            # 丁发布了它
dsapp_file_owner_set(shared, uid, con = con)
db_ws_pub_set(E$sid, shared, shared, con = con)   # 戊也记着同一个落点（人为）
rd <- dsapp_session_files_purge(D$sid, cfg)
chk("★★ 有别的对话引用着 ⇒ 那个文件**不删**（宁可少删，不许误删）",
    file.exists(dp), sprintf("被删了：%s", dp))
chk("★ 它的归属行也还在", owner_of(shared))
chk("★ 返回值如实报 0 个", identical(as.integer(rd$n), 0L))

# =============================================================================
sect("E 顺序的反证：先删库、后清盘 ⇒ 一个文件都删不掉")
# =============================================================================
# ⚠️ 这一节**故意**把顺序做反，为了证明"必须放在 db_session_delete 之前"
#    不是一句注释、而是一条会红的判据。它红了才是对的 —— 所以断言写成
#    "删不掉"，绿=顺序确实要紧。
F <- mk_pub_session("删除测试己")
f1 <- pub(F$sid, file.path(F$rel, "f1.csv"), "f1")
f2 <- pub(F$sid, "手动己.csv", "manual")
invisible(db_session_delete(F$sid, con = con, cfg = cfg))  # ← 先删库（错的顺序）
rf <- dsapp_session_files_purge(F$sid, cfg)        # ← 再清盘（已经晚了）
chk("★★ 顺序反了就是删不掉：盘上两个文件都还在（注释里那句是真的）",
    file.exists(f1) && file.exists(f2),
    sprintf("f1=%s f2=%s", file.exists(f1), file.exists(f2)))
chk("★★ 而且它**不报错**（静默落到 _anon 空目录 —— 这正是用户看到的样子）",
    identical(as.integer(rf$n), 0L))
chk("★ 反证要用对夹具：换回正确顺序（先清盘）同样的对话是删得掉的",
    { G <- mk_pub_session("删除测试庚")
      g1 <- pub(G$sid, file.path(G$rel, "g1.csv"), "g1")
      rg <- dsapp_session_files_purge(G$sid, cfg)
      identical(as.integer(rg$n), 1L) && !file.exists(g1) })

say("")
if (nfail > 0L) {
  say("\033[31m%d/%d 条没过\033[0m", nfail, NOK + nfail)
  quit(status = 1)
}
say("\033[32m全部通过（%d 条）\033[0m", NOK)
