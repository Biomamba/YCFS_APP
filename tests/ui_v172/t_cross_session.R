#!/usr/bin/env Rscript
# =============================================================================
# Test_V17.2 item 3：跨会话 —— 模型知不知道"这个文件是哪个对话的"
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/ui_v172/t_cross_session.R .
#
# ── 用户原话 ────────────────────────────────────────────────────────────────
#
# 「当前系统是否支持跨会话识别文件、上下文？如果不能，我希望做到」
#
# ── 现状（改之前）──────────────────────────────────────────────────────────
#
#   · 文件：**支持一半**。文件区按账号分（`data/files/u<N>/`），所以同一个
#     账号下别的对话同步出去的产物，在这个对话里本来就看得到 —— 但提示词里
#     只有一行路径，模型分不清那是用户上传的、自己上一轮的、还是**另一个
#     对话**的。
#   · 上下文：**不支持**。`db_messages_get()` 是 `WHERE session_id = ?`，
#     别的对话说过什么，模型一个字都读不到。
#
# 所以这次做的是：把「能看见的那部分」变成「看得懂」，并把「看不见的那部分」
# **明写出来**（不写的话模型会照着标题编）。这个测试盯的就是这两件事。
#
# ── 判据为什么按**行**取，而不是整段 grep ───────────────────────────────────
#
# 提示词的产物就是一段文本，没有别的落点可断言。但"整段里包含某个词"是**弱
# 判据**：这次的正文里恰好就有解释这两类标记的段落（「行尾标着「对话「X」的
# 产物」的……」），整段 grep 会在**一个标记都没标上**的时候照样通过 ——
# 那正是本仓栽过好几次的"判据没劲"。所以这里一律先切出**那一行**再断言。
#
# 每一节都配了阴性对照：
#   · B 节：用户自己传的文件**不带**任何来源标记（否则"全标一遍"也能过）
#   · B 节：**别人的账号**的对话标题一个字都不能出现（这是泄露）
#   · C 节：只有一个对话时，「其他对话」那一节**整段不出现**
#   · E 节：超上限时如实说"还有 N 个没列出来"，而不是默默截断
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source，且整份脚本**必须用
#    `Rscript --no-environ`** 跑 —— 仓库根的 .Renviron 指着生产库，而它
#    会盖掉继承的环境变量（只设 env 是不隔离的）。
# ⚠️ 一条出网请求都没有，只在临时目录里读写。
# ⚠️ 断言里不写字面量常数（上限从 DSAPP_PROMPT_CONV_MAX 取）。
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
tmp <- tempfile("dsapp_v172_cross_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}

# ---- 判据工具 ---------------------------------------------------------------
# 把清单里**那一行**取出来（"- <名字>  (...)"，可能带来源标记）。
# ⚠️ 取不到返回 "<没有这一行>"，于是所有基于它的断言立刻是红的 ——
#    "拿不到元素就跳过"是本仓明令禁止的写法。
line_of <- function(txt, name) {
  ln <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  hit <- ln[startsWith(trimws(ln), paste0("- ", name))]
  if (length(hit)) hit[[1]] else "<没有这一行>"
}
n_items <- function(txt, prefix) {
  length(regmatches(txt, gregexpr(paste0("\n- ", prefix), txt, fixed = TRUE))[[1]])
}

# ---- 夹具 -------------------------------------------------------------------
con <- dsapp_db(cfg0)
stamp <- as.integer(Sys.time())

mk_user <- function(nm) {
  em <- sprintf("%s%d@example.org", gsub("[^a-zA-Z]", "", nm), stamp)
  r <- dsapp_user_create(nm, em, sprintf("139%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234",
                         password2 = "test-only-1234")
  if (!isTRUE(r$ok)) stop(r$msg)
  as.integer(dsapp_user_by_email(em, con = con)$id)
}
uidA <- mk_user("crossA")
uidB <- mk_user("crossB")

cfgA <- dsapp_config_user(uidA, cfg0)
cfgB <- dsapp_config_user(uidB, cfg0)

# 建一个对话 + 定下落点 + 把一个文件「发布」进去（盘、file_owner、ws_published）
mk_conv <- function(uid, cfg, title) {
  sid <- db_session_create(title, user_id = uid, con = con)
  rel <- dsapp_sync_dir(sid, cfg)
  dir.create(file.path(cfg$files_dir, rel), recursive = TRUE, showWarnings = FALSE)
  list(sid = sid, rel = rel, cfg = cfg, uid = uid)
}
publish <- function(cv, dest, content = "x") {
  p <- file.path(cv$cfg$files_dir, dest)
  dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
  writeLines(content, p)
  dsapp_file_owner_set(dest, cv$uid, con = con)
  db_ws_pub_set(cv$sid, dest, dest, con = con)
  p
}
# 让对话「说过话」（n_msg > 0）：没说过话的空对话不进清单
speak <- function(sid, txt = "做个分析") {
  invisible(DBI::dbExecute(con,
    "INSERT INTO messages (session_id, role, content, created_at)
     VALUES (?, 'user', ?, ?)", params = list(sid, txt, dsapp_now())))
}

T1 <- "单细胞分析"     # 甲·当前对话
T2 <- "差异分析"       # 甲·另一个对话
TB <- "别人的私有对话" # 乙的（跨账号：甲那边一个字都不该出现）

A1 <- mk_conv(uidA, cfgA, T1)
A2 <- mk_conv(uidA, cfgA, T2)
B1 <- mk_conv(uidB, cfgB, TB)
speak(A1$sid); speak(A2$sid); speak(B1$sid)

# 甲1 自己发布出去的两个：一个进了对话文件夹，一个手动发布在管理区**根**上
p_a1  <- publish(A1, file.path(A1$rel, "results", "umap.pdf"))
p_a1m <- publish(A1, "手动图.pdf")
# 甲2 的产物 —— 另一个对话的
p_a2  <- publish(A2, file.path(A2$rel, "diff.csv"))
# 乙的产物（别的账号）
p_b1  <- publish(B1, file.path(B1$rel, "secret.csv"))
# 甲自己传到管理区根上的：没发布过、也不在任何文件夹里 ⇒ 不该有任何标记
p_up  <- file.path(cfgA$files_dir, "我自己传的.csv")
writeLines("mine", p_up)
dsapp_file_owner_set("我自己传的.csv", uidA, con = con)

say("\n数据根：%s", cfgA$data_root)
say("甲 %d（%s / %s）· 乙 %d", uidA, A1$sid, A2$sid, uidB)

# =============================================================================
sect("A 索引：只认同一个账号的对话")
# =============================================================================
ciA <- dsapp_conv_index(uidA, A1$sid, con = con)
titlesA <- as.character(ciA$convs$title)

chk("★ 甲看到的是自己那两个对话",
    length(titlesA) == 2L && all(c(T1, T2) %in% titlesA),
    sprintf("拿到 %s", paste(titlesA, collapse = " / ")))
chk("★★ 阴性对照：乙的对话标题**不出现**在甲的索引里（跨账号看别人的对话名 = 泄露）",
    !any(grepl(TB, titlesA, fixed = TRUE)),
    sprintf("拿到 %s", paste(titlesA, collapse = " / ")))
chk("★ is_self 标对了：只有一个，而且就是当前这个",
    sum(ciA$convs$is_self) == 1L &&
      identical(as.character(ciA$convs$session_id[ciA$convs$is_self]), A1$sid))
chk("★ 消息条数查得出来",
    all(ciA$convs$n_msg > 0L),
    sprintf("n_msg=%s", paste(ciA$convs$n_msg, collapse = ",")))
chk("★ 落点对得上：差异分析的文件夹就是它同步出去的那个",
    identical(as.character(ciA$convs$dir[ciA$convs$title == T2]), A2$rel))
chk("★ pub 表认得出「手动发布到根上」的那个文件是谁发的（路径里看不出来）",
    { m <- match("手动图.pdf", ciA$pub$dest)
      !is.na(m) && identical(as.character(ciA$pub$session_id[m]), A1$sid) },
    sprintf("pub: %s", paste(ciA$pub$dest, collapse = ",")))
chk("★ 没有账号（_anon / 未登录）时返回空表，不报错",
    { e <- dsapp_conv_index(NA, NULL, con = con)
      nrow(e$convs) == 0L && nrow(e$pub) == 0L })
chk("★ 夹具自检：三个产物文件真的在盘上（后面所有断言都靠它）",
    all(file.exists(p_a1, p_a1m, p_a2, p_b1, p_up)),
    paste(file.exists(c(p_a1, p_a1m, p_a2, p_b1, p_up)), collapse = ","))

# =============================================================================
sect("B 提示词：共享清单里每一行都认得出主人")
# =============================================================================
txt1 <- build_file_section(A1$sid, cfgA)
say("--- 甲1 的提示词（文件那一段）---\n%s\n---", txt1)

l_other <- line_of(txt1, file.path(A2$rel, "diff.csv"))
chk("★ 别的对话的产物，那一行标着它的标题",
    grepl(sprintf("对话「%s」的产物", T2), l_other, fixed = TRUE),
    sprintf("那一行是：%s", l_other))
l_mine <- line_of(txt1, file.path(A1$rel, "results", "umap.pdf"))
chk("★ 自己发布出去的也标出来了（不标的话它看着像用户传的）",
    grepl("本对话发布的产物", l_mine, fixed = TRUE),
    sprintf("那一行是：%s", l_mine))
l_root <- line_of(txt1, "手动图.pdf")
chk("★ 手动发布到根上的那个也认出来了（只能靠 ws_published，路径里看不出）",
    grepl("本对话发布的产物", l_root, fixed = TRUE),
    sprintf("那一行是：%s", l_root))
l_up <- line_of(txt1, "我自己传的.csv")
chk("★★ 阴性对照：甲自己传的数据**不带**来源标记",
    !grepl("←", l_up, fixed = TRUE),
    sprintf("那一行是：%s", l_up))
chk("★★ 阴性对照：乙的账号/文件在甲的提示词里一个字都没有",
    !grepl(TB, txt1, fixed = TRUE) && !grepl("secret.csv", txt1, fixed = TRUE))

# =============================================================================
sect("C 提示词：别的对话那一节，以及「读不到正文」这件事必须明写")
# =============================================================================
chk("★ 列出了同一账号的其他对话",
    grepl("同一账号的其他对话", txt1, fixed = TRUE) &&
      grepl(sprintf("「%s」", T2), txt1, fixed = TRUE))
chk("★ 当前这个对话不在「其他对话」那份清单里",
    n_items(txt1, sprintf("「%s」", T1)) == 0L,
    sprintf("列了 %d 行", n_items(txt1, sprintf("「%s」", T1))))
chk("★★ 明写了「你看不到别的对话的正文」（不写它就会照着标题编）",
    grepl("对话正文是隔离的", txt1, fixed = TRUE) &&
      grepl("读不到那边", txt1, fixed = TRUE))
chk("★ 给了「怎么接着做」：拷进工作区再改（共享区是只读软链）",
    grepl("file.copy(", txt1, fixed = TRUE))
chk("★ 例子里的路径是**真实存在**的文件夹名，不是占位符",
    grepl(A2$rel, txt1, fixed = TRUE) && !grepl("<文件夹>", txt1, fixed = TRUE),
    sprintf("找不到 %s", A2$rel))

# =============================================================================
sect("D 只有一个对话时：那一节整段不出现")
# =============================================================================
# 阳性基线：给甲再加一个对话，同一份提示词里那一节必须**已经**在（否则
# 下面的阴性对照可能是因为"这一节从来没写出来"而白过）。
A3 <- mk_conv(uidA, cfgA, "崭新的对话")
speak(A3$sid)
txt_after <- build_file_section(A3$sid, cfgA)
chk("★ 阳性基线：多了一个对话之后，那一节在（「差异分析」列在里面）",
    grepl("同一账号的其他对话", txt_after, fixed = TRUE) &&
      n_items(txt_after, sprintf("「%s」", T2)) == 1L)

uidC <- mk_user("crossC")
cfgC <- dsapp_config_user(uidC, cfg0)
C1 <- mk_conv(uidC, cfgC, "独苗对话")
speak(C1$sid)
txtC <- build_file_section(C1$sid, cfgC)
chk("★★ 只有一个对话时，「同一账号的其他对话」整段不出现",
    !grepl("同一账号的其他对话", txtC, fixed = TRUE),
    "还是出现了 —— 第一次用的人会看到一段用不上的说明")
chk("★ 阴性对照：同一份提示词里，文件那一节照常还在",
    grepl("可用数据文件", txtC, fixed = TRUE))

# =============================================================================
sect("E 对话多了：列 DSAPP_PROMPT_CONV_MAX 个，多的如实说")
# =============================================================================
lim <- as.integer(DSAPP_PROMPT_CONV_MAX)
uidD <- mk_user("crossD")
cfgD <- dsapp_config_user(uidD, cfg0)
D0 <- mk_conv(uidD, cfgD, "主对话")
speak(D0$sid)
for (i in seq_len(lim + 2L)) {
  Di <- mk_conv(uidD, cfgD, sprintf("历史对话%02d", i))
  speak(Di$sid)
  Sys.sleep(0.02)   # updated_at 只到秒，错开一点免得排序不稳
}
txtD <- build_file_section(D0$sid, cfgD)
got <- n_items(txtD, "「历史对话")
chk(sprintf("★ 最多列 %d 个别的对话", lim), got == lim,
    sprintf("列了 %d 个（上限 %d）", got, lim))
chk("★★ 超出的如实说「还有 N 个没列出来」，不静默截断",
    grepl(sprintf("还有 %d 个更早的对话没列出来", lim + 2L - lim), txtD, fixed = TRUE))
chk("★ 阴性对照：真的列了对话（不是「空列表 + 一句还有 N 个」）", got >= 1L)

# =============================================================================
sect("F 兜底：查不到索引时，提示词照样拼得出来")
# =============================================================================
# 反证「索引挂了 ⇒ 用户发不出消息」这件事不会发生：提示词是每次请求都要拼的，
# 这里给一个用不了的连接，它必须返回**空表**而不是抛异常。
bad <- tryCatch(dsapp_conv_index(uidA, A1$sid, con = "不是连接"),
                error = function(e) "抛异常了")
chk("★★ 连接不可用时返回空表而不抛异常",
    is.list(bad) && nrow(bad$convs) == 0L && nrow(bad$pub) == 0L,
    sprintf("拿到：%s", paste(as.character(bad), collapse = " ")))
txt_bad <- tryCatch(build_file_section(A1$sid,
                                       dsapp_config_user(uidA, cfg0)),
                    error = function(e) "抛异常了")
chk("★ 阴性对照：这种情况下提示词本体仍然拼得出来（只是少了标记）",
    is.character(txt_bad) && length(txt_bad) == 1L &&
      grepl("可用数据文件", txt_bad, fixed = TRUE),
    sprintf("拿到：%s", paste(as.character(txt_bad), collapse = " ")))

say("")
if (nfail > 0L) {
  say("\033[31m%d/%d 条没过\033[0m", nfail, NOK + nfail)
  quit(status = 1)
}
say("\033[32m全部通过（%d 条）\033[0m", NOK)
