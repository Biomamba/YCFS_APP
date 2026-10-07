#!/usr/bin/env Rscript
# =============================================================================
# 「断线提示分两档出场」那批判据的**变异测试**
# =============================================================================
# 背景（2026-10-07，用户原话）：
#   「服务器现在还是经常未响应，这个提示能不能显示的不要这么频繁，
#     即使真的断了，也请间隔一段时间再提示」
# 改法：判死线到了**只出左下角小条**，从离开 up 那一刻再撑
#   DSAPP_OFFLINE_CARD_MS 才铺盖住整页的卡片。
#
# 自检里那 6 条新断言全是**反向**的（"看门狗那一段里不许出现
# dsappOfflineShow"这种）。反向断言最容易写成"永远为真" —— 一次全绿什么都
# 证明不了。所以把判据**原样**抠出来喂变异体：七条变异，每条都把对应那处
# 改回**旧的形状**（用户抱怨的那个形状），判据必须红。
#
# ⚠️ 抄过来的判据必须证明是**同一份**：第 0 节断言那几行逐字出现在
#    selftest.R 里（只把换行和连续空格归一化）。不然改了 selftest 而这里没
#    跟着改，变异验的就是一个**早就不是那个**的判据 —— 本仓的账：一个打偏了
#    的变异证明的是零，却长得像"判据很强"。
# ⚠️ 每条变异还要先断言"打中了"。`sub()` 改的是文件里**第一处**，不是你以为
#    的那一处（本仓记过：假绿就是这么来的）。
#
# 用法：Rscript --no-environ tests/v1611_tier_mut.R
# =============================================================================
e <- new.env()
for (x in parse("selftest.R")) {
  if (is.call(x) && identical(x[[1]], as.name("<-")) && is.name(x[[2]]) &&
      as.character(x[[2]]) %in% c("strip_js_comments", "dsapp_block_at"))
    eval(x, e)
}
strip_js <- e$strip_js_comments
blk_at   <- e$dsapp_block_at
raw <- paste(readLines("www/app.js", warn = FALSE), collapse = "\n")
jsc0 <- strip_js(raw)

ok <- TRUE
say <- function(...) cat(..., "\n", sep = "")
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) { cat("  \033[32m✓\033[0m ", name, "\n", sep = "") }
  else { ok <<- FALSE
         cat("  \033[31m✗ ", name, "\033[0m",
             if (nzchar(extra)) paste0("   ", extra), "\n", sep = "") }
}
norm <- function(x) gsub("[[:space:]]+", " ", x)
self <- paste(readLines("selftest.R", warn = FALSE), collapse = "\n")

# ---------------------------------------------------------------------------
# 判据（与 selftest.R 里那 6 条**逐字相同**，只把取值来源换成参数 jsc）
# ---------------------------------------------------------------------------
c1 <- function(jsc) {   # 判死那一支只出小条
  m <- regexpr("if \\(Date\\.now\\(\\) - dsappLastPing > DSAPP_PING_DEAD_MS\\)\\s*\\{", jsc)
  seg <- blk_at(jsc, m)
  nzchar(seg) && grepl('dsappOfflineWarn("silent")', seg, fixed = TRUE) &&
    !grepl("dsappOfflineShow(", seg, fixed = TRUE)
}
c2 <- function(jsc) {   # CARD_MS 是个正经的间隔
  m <- regmatches(jsc, regexpr("DSAPP_OFFLINE_CARD_MS = [0-9]+", jsc))
  if (!length(m)) FALSE else {
    d <- as.numeric(sub(".*= ", "", m)); d >= 4000 && d <= 300000 }
}
c3 <- function(jsc) {   # 铺卡片那条路问过「先等一下」
  seg <- blk_at(jsc, regexpr("function dsappOfflineEscalate(st) {", jsc, fixed = TRUE))
  nzchar(seg) && grepl("dsappCardDismissed", seg, fixed = TRUE) &&
    grepl("DSAPP_OFFLINE_CARD_MS", seg, fixed = TRUE)
}
c4 <- function(jsc) {   # 「先等一下」真的记下来
  seg <- blk_at(jsc, regexpr("function dsappOfflineDismiss() {", jsc, fixed = TRUE))
  nzchar(seg) && grepl("dsappCardDismissed = true", seg, fixed = TRUE)
}
c5 <- function(jsc) {   # 回到 up 两个都归零
  seg <- blk_at(jsc, regexpr("function dsappNetSet(state, why) {", jsc, fixed = TRUE))
  nzchar(seg) && grepl("dsappOutageSince = Date.now()", seg, fixed = TRUE) &&
    grepl("dsappOutageSince = 0", seg, fixed = TRUE) &&
    grepl("dsappCardDismissed = false", seg, fixed = TRUE)
}
c6 <- function(jsc) {   # 自愈有话要说时卡片必须先在
  seg <- blk_at(jsc, regexpr("function dsappHealNote(msg) {", jsc, fixed = TRUE))
  nzchar(seg) && grepl('getElementById("dsapp-offline")', seg, fixed = TRUE) &&
    grepl("dsappOfflineShow(", seg, fixed = TRUE)
}

say("\n== 0. 这六段判据确实是 selftest.R 里那一份吗 ==")
for (frag in c('!grepl("dsappOfflineShow(", seg, fixed = TRUE)',
               'grepl(\'dsappOfflineWarn("silent")\', seg, fixed = TRUE)',
               'regexpr("DSAPP_OFFLINE_CARD_MS = [0-9]+", jsc)',
               'regexpr("function dsappOfflineEscalate(st) {", jsc, fixed = TRUE)',
               'grepl("dsappCardDismissed = true", seg, fixed = TRUE)',
               'regexpr("function dsappOfflineDismiss() {", jsc, fixed = TRUE)',
               'regexpr("function dsappNetSet(state, why) {", jsc, fixed = TRUE)',
               'grepl("dsappOutageSince = Date.now()", seg, fixed = TRUE)',
               'regexpr("function dsappHealNote(msg) {", jsc, fixed = TRUE)'))
  chk(sprintf("selftest.R 里有这一句：%s", substr(frag, 1, 46)),
      grepl(norm(frag), norm(self), fixed = TRUE))

say("\n== 1. 基线：仓库现在这版 → 六条判据全绿 ==")
chk("c1 判死只出小条 → 绿", c1(jsc0))
chk("c2 CARD_MS 是正经间隔 → 绿", c2(jsc0))
chk("c3 Escalate 问过 dismissed → 绿", c3(jsc0))
chk("c4 Dismiss 记账 → 绿", c4(jsc0))
chk("c5 NetSet 归零 → 绿", c5(jsc0))
chk("c6 HealNote 先铺卡片 → 绿", c6(jsc0))

say("\n== 2. 变异体（每条都要让对应判据红）==")
mut <- function(name, from, to, criterion, which) {
  m <- sub(from, to, raw, fixed = TRUE)
  chk(sprintf("%s 打中了", name), !identical(m, raw),
      "没打中 —— 后面的红/绿都是白送的")
  j <- strip_js(m)
  chk(sprintf("%s → %s 必须红", name, which), !criterion(j))
}

# M1：改回旧形状 —— 判死直接铺整页卡片（用户抱怨的就是这个）
mut("M1 判死直接铺卡片", 'dsappOfflineWarn("silent");\n      return;',
    'dsappOfflineShow("silent");\n      return;', c1, "c1")
# M2：卡片延迟常数改成 0（= 没有延迟，"间隔一段时间"这句话没了）
mut("M2 CARD_MS = 0", "var DSAPP_OFFLINE_CARD_MS = 30000;",
    "var DSAPP_OFFLINE_CARD_MS = 0;", c2, "c2")
# M3：铺卡片那条路不问「先等一下」（那颗按钮在 CARD_MS 之后被自动机制盖掉）
mut("M3 Escalate 不问 dismissed",
    "  if (dsappCardDismissed || !(dsappOutageSince > 0)) return;",
    "  if (!(dsappOutageSince > 0)) return;", c3, "c3")
# M4：「先等一下」没记下来
mut("M4 Dismiss 不记账", "  dsappCardDismissed = true;\n", "", c4, "c4")
# M5：回到 up 不归零（下一轮断线带着上一轮的时钟，"别弹了"也一直哑着）
mut("M5 回 up 不归零",
    "  if (state === \"up\") {\n    dsappOutageSince = 0;\n    dsappCardDismissed = false;\n  }",
    "  if (state === \"up\") {\n    dsappCardDismissed = false;\n  }", c5, "c5")
# M6：自愈不再保证卡片在（"它一回来这页会自己刷新"就没人看见了）
mut("M6 HealNote 不铺卡片",
    '  if (!document.getElementById("dsapp-offline"))\n    dsappOfflineShow(window.dsappNet.state === "silent" ? "silent"\n                                                       : "disconnected");',
    "", c6, "c6")
# M7：计时改成 n.since（silent→down 换档会重置，卡片越推越远、永远不来）
mut("M7 计时改成 n.since",
    "  } else if (n.state === \"up\") {\n    dsappOutageSince = Date.now();\n  }",
    "  }\n  dsappOutageSince = n.since;", c5, "c5")

say("")
if (ok) {
  cat("\033[32m判据都活着：基线全绿、七条变异条条见红。\033[0m\n")
} else {
  cat("\033[31m有判据是死的（上面标 ✗ 的）。\033[0m\n")
  quit(status = 1)
}
