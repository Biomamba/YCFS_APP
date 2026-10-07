#!/usr/bin/env Rscript
# =============================================================================
# tests/ui_v167 —— `dsapp_linkify_files()` 回归（Test_V16.7）
# =============================================================================
#
#   Rscript --no-environ tests/ui_v167/linkify_regression.R
#
# 退出码 0 = 全绿。
#
# ---- 这一版在修什么（读这份的人先看这 8 行）--------------------------------
#
# 用户报的是 `Biomamba_ceshi` 账号上那句「An error has occurred.」。
# 根因不在那个账号上：`dsapp_linkify_files()` 把工作区里**全部**产物名拼成
# **一条**正则去匹配正文，而那个工作区被模型建过一整个 Python 虚拟环境 ——
# 名单 5262 条、拼出来 **43.8 万字符**，PCRE 编译直接失败
# （'regular expression is too large'）。它抛在 renderUI 里，于是**整格
# 对话报废**，用户看到的就是那句被 sanitize 过的英文。
#
# 所以这份测试的**第一判据**是"老实现必须在这里炸" —— 一个不触发原场景的
# 测试，即使全绿也什么都证明不了（本仓栽过：塞进 output 的变异从没被执行，
# 探针全绿；一个不改变行为的变异证明的是零）。
#
# ---- 为什么要自带一份"老实现"而不是 `git show` 上一版 ----------------------
#
# 因为要能在这个仓库**外面**跑（本仓老规矩：这些脚本要能在"把仓库拷到
# /tmp 单独跑"的场景里工作），而且要能和当前实现**同一进程内并排比**。
# 老实现是从 V16.6 的 `R/render.R:1502` 逐字搬过来的（连尾部拼接一起）。
# 它不进包、不被 `R/` 里任何东西引用，只活在这里。
#
# ---- 判据里"真工作区"那一条为什么可以 SKIP ---------------------------------
#
# 那份工作区（5262 条产物名）是**生产数据**，不在仓库里。所以判据 1 有两条腿：
#   · 1a（永远跑）：合成一份够长的名单，老实现必须抛错 —— 阈值是 PCRE 编译
#     上限（LINK_SIZE=2 约 64K 字符），与具体哪份工作区无关。
#   · 1b（有就跑）：真工作区那份名单，老实现必须抛错。本机没有就明说 SKIP。
# ⚠️ SKIP **会打印出来并且计数**，收尾那行专门报「跑了几条、跳了几条」——
#    这个仓库栽过"探针里拿不到元素就跳过 → 那条从来没跑过却长得像通过"，
#    所以跳过必须是看得见的，不能是静默的。
# =============================================================================

Sys.setenv(DSAPP_DATA_ROOT = file.path(tempdir(), "dsapp_v167_regression"))

# 仓库根 = 这份脚本往上两级。别写死绝对路径 —— 拷到别处也要能跑。
args <- commandArgs(trailingOnly = FALSE)
self <- sub("^--file=", "", args[grep("^--file=", args)][1])
# ⚠️⚠️ 仓库根 = 脚本自己往上两级，**并且要断言那两级确实是 tests/ui_v167**。
#    这条断言不是洁癖，是血换的：做变异测试（把 `dsapp_re_find_all` 的
#    `chunk_chars` 调成 1e12，等于把修复退掉）时，变异体被我放成了
#    `<仓库>/_mut2/a/linkify_regression.R` —— 只比仓库根深两级，于是
#    `../..` 正确解析回了**仓库根**，脚本 source 的是**没被变异的**
#    `./R/`，跑出来 23 项全绿。屏幕上那行「仓库：/data3/.../DS_App」
#    就是唯一的线索，而它长得完全正常。
#    → 变异体必须放在 `<变异根>/tests/ui_v167/`（三级），和真身同深度。
#    这里加断言，把"跑的不是被测对象"变成一声明响。
if (is.na(self)) stop("拿不到 --file=；这份脚本要用 `Rscript 路径/linkify_regression.R` 跑")
SELF <- normalizePath(self, mustWork = TRUE)
REPO <- normalizePath(file.path(dirname(SELF), "..", ".."), mustWork = TRUE)
if (basename(dirname(SELF)) != "ui_v167" || basename(dirname(dirname(SELF))) != "tests")
  stop("这份脚本必须待在 <仓库根>/tests/ui_v167/ 里跑。现在在：", SELF,
       "（往上是 " , REPO, "）—— 目录深度不对就会**悄悄 source 另一棵树**。")
setwd(REPO)
for (f in list.files("R", pattern = "[.]R$", full.names = TRUE)) source(f)

cat("仓库：", REPO, "\n")
# 打印 source 的到底是哪一份 render.R。变异测试/对照实例全靠它一眼认出来。
cat("加载自：", file.path(REPO, "R", "render.R"),
    "  md5 ", unname(tools::md5sum(file.path(REPO, "R", "render.R"))), "\n")
cat("DSAPP_VERSION：", DSAPP_VERSION, "\n")
cat("数据目录（临时）：", Sys.getenv("DSAPP_DATA_ROOT"), "\n\n")

n_pass <- 0L; n_fail <- 0L; n_skip <- 0L
ok  <- function(label, cond) {
  if (isTRUE(cond)) { n_pass <<- n_pass + 1L; cat("  ✓ ", label, "\n") }
  else              { n_fail <<- n_fail + 1L; cat("  ✗ ", label, "   <<<< 红\n") }
}
skip <- function(label, why) { n_skip <<- n_skip + 1L; cat("  ⊘ 跳过：", label, "（", why, "）\n") }

# 把 `<a>…</a>` 的正文抽出来。在整段 HTML 上瞎 grepl 会把属性里的文件名也算上。
link_texts <- function(x) {
  m <- regmatches(x, gregexpr('class="dsapp-file-link"[^>]*>([^<]*)</a>', x, perl = TRUE))[[1]]
  sub('^.*>([^<]*)</a>$', "\\1", m)
}
plain <- function(x) gsub("<[^>]*>", "", x)   # 剥掉标签，比正文

# ---- 老实现：V16.6 的 dsapp_linkify_files 主体，逐字搬来 --------------------
# （只搬"拼一条大正则"那一段；V16.6 的版本里没有预筛、没有切块）
old_linkify <- function(html, names, input_id, title = "点击下载 %s") {
  names <- unique(as.character(names))
  names <- names[!is.na(names) & nzchar(names)]
  names <- names[order(nchar(names), decreasing = TRUE)]
  pat <- sprintf("(?<![[:alnum:]_/])(?:%s)(?![[:alnum:]_/])",
                 paste(dsapp_re_escape(names), collapse = "|"))
  h <- gregexpr(pat, html, perl = TRUE)[[1]]
  if (h[1] == -1L) return(html)
  ln <- attr(h, "match.length"); s <- as.integer(h); e <- s + ln - 1L
  out <- character(0); prev <- 1L
  for (j in seq_along(s)) {
    if (s[j] > prev) out <- c(out, substr(html, prev, s[j] - 1L))
    out <- c(out, dsapp_file_link_html(substr(html, s[j], e[j]), input_id, title))
    prev <- e[j] + 1L
  }
  if (prev <= nchar(html)) out <- c(out, substr(html, prev, nchar(html)))
  paste(out, collapse = "")
}

# ---- 合成名单：够长就一定越过 PCRE 编译上限（≈64K 字符）--------------------
set.seed(7)
syn_names <- sprintf("env/lib/python3.11/site-packages/pkg_%04d/sub/module_%04d_data.csv",
                     seq_len(8000), seq_len(8000))
syn_esc_len <- sum(nchar(dsapp_re_escape(syn_names)) + 1L)
syn_hit <- syn_names[c(1L, 2000L, 8000L)]

syn_html <- paste(c(rep("这是一段中文正文，讲的是分析结果，包含若干数字 12345 和标点。", 60),
                    sprintf("产物在 %s，还有 %s。", syn_hit[1], syn_hit[2]),
                    rep("| 基因 | logFC | p |\n|---|---|---|\n| Pou4f2 | 1.2 | 0.01 |\n", 60),
                    sprintf("最后一份是 %s。", syn_hit[3])), collapse = "\n")

cat("===== 判据 1a：老实现在长名单上必须抛错（否则说明场景根本没触发）=====\n")
cat(sprintf("  合成名单 %d 条、转义后 %s 字符（PCRE 编译上限约 64K）\n",
            length(syn_names), format(syn_esc_len, big.mark = ",")))
# ⚠️ 必须连**警告**一起收：`gregexpr` 碰上编译不过的模式是「先 warning 说
#    'regular expression is too large'，再 stop 一句泛泛的 'invalid regular
#    expression'」。只读 conditionMessage(e) 的话看到的是后者 —— 单看它
#    分不出"太大"和"文法写错了"。第一次跑这份脚本时就栽在这：那条断言写成
#    了 `cat("✓ …", grepl(...))`，既不进计数、又在屏幕上报 FALSE，
#    长得完全像一条绿。**判据一律走 ok()，不许自己 cat 一个 ✓。**
old_try <- function(...) {
  warns <- character(0)
  msg <- tryCatch(
    withCallingHandlers(
      { old_linkify(...); NULL },
      warning = function(w) {
        warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning")
      }),
    error = function(e) conditionMessage(e))
  list(err = msg, warns = warns)
}
r1a <- old_try(syn_html, syn_names, "f")
if (is.null(r1a$err)) {
  n_fail <- n_fail + 1L
  cat("  ✗ 老实现**没有抛错** —— 这条测试失去了前提，判据 2 的\"不抛错\"也就不值钱了\n")
} else {
  ok(paste0("老实现抛错：", substr(r1a$err, 1, 60)), TRUE)
  ok("错的是 PCRE 编译这一层（不是别的意外）",
     grepl("too large", paste(c(r1a$err, r1a$warns), collapse = " "), fixed = TRUE))
}

# ---- 真工作区（生产数据，不在仓库里）----------------------------------------
WS <- file.path(REPO, "data", "workspaces", "chat-s-20261003213145-9030")
cat("\n===== 判据 1b：真工作区那份名单，老实现必须抛错 =====\n")
if (dir.exists(WS)) {
  real_names <- sort(as.character(list.files(WS, recursive = TRUE, all.files = TRUE, no.. = TRUE)))
  cat(sprintf("  %s\n  → %d 条、转义后 %s 字符\n", WS, length(real_names),
              format(sum(nchar(dsapp_re_escape(real_names)) + 1L), big.mark = ",")))
  r1b <- old_try(syn_html, real_names, "f")
  ok("老实现在真工作区名单上抛错", !is.null(r1b$err))
  ok("错的同样是 PCRE 编译这一层",
     grepl("too large", paste(c(r1b$err, r1b$warns), collapse = " "), fixed = TRUE))
  ok("真工作区名单确实上千条（不是把一份小名单当成大名单）", length(real_names) > 1000L)
} else {
  real_names <- character(0)
  skip("真工作区那份名单", "生产数据不在仓库里；判据 1a 的合成名单已覆盖同一阈值")
}

# ---- 判据 2：新实现 ----------------------------------------------------------
cat("\n===== 判据 2：新实现不许抛错，而且该链的必须链上 =====\n")
t0 <- Sys.time()
out <- tryCatch(dsapp_linkify_files(syn_html, syn_names, "f"),
                error = function(e) structure(conditionMessage(e), class = "linkify_error"))
dt <- as.numeric(Sys.time() - t0, units = "secs") * 1000
if (inherits(out, "linkify_error")) {
  n_fail <- n_fail + 1L
  cat("  ✗ 仍然抛错：", substr(out, 1, 140), "\n")
} else {
  got <- link_texts(out)
  cat(sprintf("  用时 %.0f ms，链出 %d 个\n", dt, length(got)))
  ok("三个命中的名字都变成了链接", all(syn_hit %in% got))
  ok("正文一个字没丢", identical(plain(out), plain(syn_html)))
  ok("没有 <a> 套 <a>", !grepl("<a [^>]*<a ", out))
}

# 判据 2b：真工作区那份名单走一遍（新版不许抛错）
if (length(real_names)) {
  cat("\n===== 判据 2b：新实现喂真工作区那份名单 =====\n")
  t0 <- Sys.time()
  out2 <- tryCatch(dsapp_linkify_files(syn_html, real_names, "f"),
                   error = function(e) structure(conditionMessage(e), class = "linkify_error"))
  dt2 <- as.numeric(Sys.time() - t0, units = "secs") * 1000
  if (inherits(out2, "linkify_error")) {
    n_fail <- n_fail + 1L
    cat("  ✗ 抛错：", substr(out2, 1, 140), "\n")
  } else {
    cat(sprintf("  用时 %.0f ms\n", dt2))
    ok("正文一个字没丢", identical(plain(out2), plain(syn_html)))
    ok("没有 <a> 套 <a>", !grepl("<a [^>]*<a ", out2))
  }
} else {
  skip("新实现喂真工作区名单", "同上")
}

# ---- 判据 2c：★ 正文里**真的**有上千个文件名 —— 这条才在考切块 --------------
# ⚠️⚠️ 这一段是**变异测试逼出来的**，别删。
#    一开始只有判据 2（正文里只出现 3 个名字）。把修复退掉（`chunk_chars`
#    调成 1e12，等于退回"一条大正则"）重跑 —— **十九项照样全绿**。
#    原因是预筛：正文里没出现的名字根本进不了正则，8000 条筛完只剩 3 条，
#    那样一条正则怎么都不会超限。也就是说**判据 2 从头到尾没考过切块**，
#    切块那道防线拆了它也不知道。
#    真正需要切块的是另一种正文：模型一口气列出上千个产物名（报告里附清单、
#    目录树、`ls -R` 的输出都长这样）。这时预筛一个都筛不掉，硬碰硬就是
#    40 万字符的正则 —— 正是线上那个场景。
#    ⚠️ 而且退掉修复**不会抛错**：`dsapp_re_find_all` 里那层 tryCatch 会把
#    "编译不过"吞成"这一块一个都不链"。所以这条判据不能只断言"不抛错"，
#    必须断言**该链的都链上了** —— 否则它长得跟全绿一模一样。
cat("\n===== 判据 2c：正文里真有上千个文件名时，必须全部链上 =====\n")
hit_names <- syn_names[seq_len(1500)]
hit_esc_len <- sum(nchar(dsapp_re_escape(hit_names)) + 1L)
hit_html <- paste(hit_names, collapse = "\n")
cat(sprintf("  正文里出现 %d 个名字、转义后 %s 字符（超过 64K 上限 → 非切块不可）\n",
            length(hit_names), format(hit_esc_len, big.mark = ",")))
ok("这段正文确实非切块不可（转义后 > 64K）", hit_esc_len > 65536)
r2c_old <- old_try(hit_html, hit_names, "f")
ok("老实现在这段正文上抛错", !is.null(r2c_old$err))
t0 <- Sys.time()
out2c <- tryCatch(dsapp_linkify_files(hit_html, hit_names, "f"),
                  error = function(e) structure(conditionMessage(e), class = "linkify_error"))
dt2c <- as.numeric(Sys.time() - t0, units = "secs") * 1000
if (inherits(out2c, "linkify_error")) {
  n_fail <- n_fail + 1L
  cat("  ✗ 新实现抛错：", substr(out2c, 1, 140), "\n")
} else {
  got2c <- link_texts(out2c)
  cat(sprintf("  用时 %.0f ms，链出 %d / %d 个\n", dt2c, length(got2c), length(hit_names)))
  # ★ 这一条就是变异测试里唯一会红的那条：把切块退掉 → tryCatch 吞掉编译错误
  #   → 链出 0 个 → 红。
  ok("1500 个名字**一个不少**地都链上了", setequal(got2c, hit_names))
  ok("正文一个字没丢", identical(plain(out2c), plain(hit_html)))
}

# ---- 判据 3：名单不大时，新旧必须逐字节相同 ---------------------------------
# 这是"改法没改语义"的核心证据：切块+预筛之后的输出，和原来那条大正则
# 在小名单上必须**一个字都不差**。
cat("\n===== 判据 3：名单不大时，新旧实现必须逐字节相同 =====\n")
sub <- syn_names[seq_len(150)]
diff_rounds <- integer(0)
for (k in 1:6) {
  h2 <- paste(sample(c(sprintf("已生成 %s", syn_names[1]),
                       sprintf("见 %s", syn_names[2]),
                       sprintf("跑 %s", syn_names[3]),
                       "随手一句没有文件名的话",
                       sub[1:5]), 40, replace = TRUE), collapse = "。\n")
  o1 <- dsapp_linkify_files(h2, sub, "f")
  o2 <- tryCatch(old_linkify(h2, sub, "f"),
                 error = function(e) paste("旧路径抛错:", conditionMessage(e)))
  if (!identical(o1, o2)) {
    diff_rounds <- c(diff_rounds, k)
    cat("  第", k, "轮不一致\n    新链出:", paste(link_texts(o1), collapse = ","),
        "\n    旧链出:", paste(link_texts(o2), collapse = ","), "\n")
  }
}
ok("六轮全部逐字节相同", length(diff_rounds) == 0L)

# ---- 判据 4：正文里一个名字都没有时原样返回 ---------------------------------
cat("\n===== 判据 4：正文里一个名字都没有时，原样返回 =====\n")
ok("原样返回", identical(dsapp_linkify_files(syn_html, c("zzz_no_such.xyz"), "f"), syn_html))

# ---- 判据 5：长的优先、不重叠 ------------------------------------------------
cat("\n===== 判据 5：长的优先、不重叠（原来靠单趟扫描保证的性质）=====\n")
h3 <- "见 a/b.txt 和 b.txt，还有 b.txt.bak。"
o3 <- dsapp_linkify_files(h3, c("a/b.txt", "b.txt", "b.txt.bak"), "f")
cat("  链出的：", paste(link_texts(o3), collapse = " | "), "\n")
ok("三个各成一条、没被咬开",
   identical(sort(link_texts(o3)), sort(c("a/b.txt", "b.txt", "b.txt.bak"))))
ok("正文没被撕开", !grepl(">a/<a", o3, fixed = TRUE))

# 判据 5b：元字符必须被转义（`a.csv` 不许匹配上 `abcsv`）
# 名字拼进正则之前要过 `dsapp_re_escape`；漏了 `.` 的话 `a.csv` 会匹配
# 任意字符，用户会看到一段莫名其妙的文字变成下载链接。
#
# ⚠️⚠️ 这条**必须直接打在 `dsapp_re_escape` / `dsapp_re_find_all` 上**，
#    不能只走 `dsapp_linkify_files` —— 变异测试证明过：把转义字符类里的
#    `.` 拿掉之后，端到端那条**照样绿**。原因是预筛：`dsapp_link_candidates`
#    用的是 `fixed = TRUE` 的**字面**查找，`a.csv` 在 "看 abcsv 这个" 里
#    根本不存在 → 这个名字压根进不了正则。也就是说这条路径上现在是
#    预筛在兜底，转义坏了看不出来。
#    可是转义仍然是要紧的：预筛那个 tryCatch 的兜底分支是"出错就把**整份**
#    名单原样放下去"（`error = function(e) names`），那条路上没有任何预筛。
cat("\n===== 判据 5b：正则元字符必须被转义 =====\n")
ok("转义函数把 `.` 变成字面量", dsapp_re_escape("a.csv") == "a\\.csv")
ok("转义函数处理 `+` `(` `)`", dsapp_re_escape("a+b(c)") == "a\\+b\\(c\\)")
# 绕过预筛，直接考匹配器
ok("匹配器里 `a.csv` 不匹配 `abcsv`",
   length(dsapp_re_find_all(c("a.csv"), "看 abcsv 这个")$start) == 0L)
ok("但匹配器里 `a.csv` 自己照样命中",
   length(dsapp_re_find_all(c("a.csv"), "看 a.csv 这个")$start) == 1L)
# 端到端也留一条（它现在由预筛兜着，但这是**用户真看到的那条路**）
ok("端到端：`a.csv` 不会把 `abcsv` 变成链接",
   length(link_texts(dsapp_linkify_files("看 abcsv 这个", c("a.csv"), "f"))) == 0L)
ok("端到端：`a.csv` 自己照样链得上",
   identical(link_texts(dsapp_linkify_files("看 a.csv 这个", c("a.csv"), "f")), "a.csv"))

# ---- 判据 6：切块路径和单块必须给出同一个结果 -------------------------------
cat("\n===== 判据 6：切块路径和单块必须给出同一个结果 =====\n")
BIG <- syn_names[seq_len(300)]
big_html <- paste(rep(c(syn_names[1], syn_names[7], syn_names[300]), 300), collapse = " ")
one  <- dsapp_re_find_all(BIG, big_html, chunk_chars = 1e9)
many <- dsapp_re_find_all(BIG, big_html, chunk_chars = 200L)
cat(sprintf("  名单 %d 条、正文 %d 字符；单块 %d 处 / 每块 200 字符切出 %d 处\n",
            length(BIG), nchar(big_html), length(one$start), length(many$start)))
ok("单块与切块结果完全相同", identical(one, many))
ok("切块确实切了（否则上一条是空的）", length(many$start) > 0L)

# ---- 判据 7：预筛：一个都不在正文里时，一个正则都不该跑 ----------------------
cat("\n===== 判据 7：名字全都不在正文里时，预筛就该返回空 =====\n")
ok("预筛返回 0 条",
   length(dsapp_link_candidates(syn_names, "完全无关的一段话，一个文件名都没有。")) == 0L)
ok("预筛没把该留的筛掉", all(dsapp_link_candidates(syn_names, syn_html) %in% syn_hit))

# ---- 判据 8：预筛的 useBytes 口径与逐字符口径必须一致 ------------------------
# `useBytes = TRUE` 是那条 9 倍加速的命门（219ms → 25ms）。加速不能换来
# 不一样的答案 —— UTF-8 是自同步编码，字节命中必然落在字符边界上，这里实测钉住。
cat("\n===== 判据 8：预筛 useBytes 的口径与不带它完全一致 =====\n")
ref <- syn_names[vapply(syn_names, function(n) grepl(n, syn_html, fixed = TRUE), logical(1))]
ok("两种口径筛出来的名单完全相同",
   identical(dsapp_link_candidates(syn_names, syn_html), ref))

# ---- 收尾 --------------------------------------------------------------------
cat(sprintf("\n================  ✓ %d   ✗ %d   ⊘ 跳过 %d  ================\n",
            n_pass, n_fail, n_skip))
if (n_skip > 0L)
  cat("⚠️ 跳过的条目列在上面（都是需要生产工作区那两条），没有静默略过。\n")
if (n_fail > 0L) {
  cat("有红的。**别把这份结果当成通过。**\n")
  quit(status = 1L)
}
cat("全绿。\n")
quit(status = 0L)
