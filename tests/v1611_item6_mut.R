#!/usr/bin/env Rscript
# =============================================================================
# item 6 的**判据**变异测试
# =============================================================================
# 自检里那几条新断言是"读仓库文件 + 判据"两段拼起来的。整条自检跑一遍要
# 好几分钟、而且会去动生产目录，不适合反复跑 —— 所以把判据**原样**抠出来，
# 喂三份输入，看它在"该红"的输入上是不是真的红。
#
# ⚠️ 抄过来的东西必须证明是**同一份**：下面第一条就断言这段文本逐字出现在
#    selftest.R 里（只把换行和连续空格归一化）。不然改了 selftest 的判据
#    而这里没跟着改，变异就会在验一个**早就不是那个**的判据 ——
#    本仓的账：一个打偏了的变异证明的是零，却长得像"探针不够强"。
# =============================================================================
ok <- TRUE
say <- function(...) cat(..., "\n", sep = "")
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) { cat("  \033[32m✓\033[0m ", name, "\n", sep = "") }
  else { ok <<- FALSE
         cat("  \033[31m✗ ", name, "\033[0m", if (nzchar(extra)) paste0("   ", extra), "\n", sep = "") }
}
norm <- function(x) gsub("[[:space:]]+", " ", x)

self <- paste(readLines("selftest.R", warn = FALSE), collapse = "\n")

# ---------------------------------------------------------------------------
# 判据 ①：CSS 三档字号（从 render 出来的样式表文本上量）
# ---------------------------------------------------------------------------
# ⚠️ 与 selftest.R 里那段**逐字相同**，只把 `css <- gsub(...)` 那行的取值
#    来源换成参数（这里要喂变异体，不能真去读 www/app.css）。
css_fs_criterion <- function(css) {
  fs_of <- function(sel) {
    i <- regexpr(sel, css, fixed = TRUE)[1]
    if (i < 0) return(NA_character_)
    blk <- substring(css, i)
    j <- regexpr("}", blk, fixed = TRUE)[1]
    if (j < 0) return(NA_character_)
    blk <- substr(blk, 1L, j - 1L)
    k <- regexpr("font-size:\\s*[0-9.]+rem", blk)
    if (k[1] < 0) return(NA_character_)
    sub("^font-size:\\s*", "", regmatches(blk, k))
  }
  doc <- fs_of(".dsapp-tos-md > h1:first-child")   # 文档题
  grp <- fs_of(".dsapp-tos-md h1 {")               # 四个分组
  h2s <- fs_of(".dsapp-tos-md h2,")                # 十个章
  num <- function(x) suppressWarnings(as.numeric(sub("rem$", "", x)))
  !is.na(doc) && !is.na(grp) && !is.na(h2s) &&
    length(unique(c(doc, grp, h2s))) == 3L &&
    identical(num(c(doc, grp, h2s)), sort(num(c(doc, grp, h2s)), decreasing = TRUE))
}

# 判据 ②：一级标题正好 5 个 / 二级正好 10 个
h_structure_criterion <- function(lines) {
  h1 <- sub("^#\\s+", "", grep("^#\\s+[^#]", lines, value = TRUE))
  h2 <- sub("^##\\s+", "", grep("^##\\s", lines, value = TRUE))
  identical(h1, c("用户须知", "第一部分　总则", "第二部分　使用与责任",
                  "第三部分　数据与隐私", "第四部分　终止与免责")) &&
    identical(h2, c("一、服务说明", "二、账号与密钥安全", "三、使用规范",
                    "四、费用与计费", "五、数据与隐私", "六、服务可用性",
                    "七、账号与服务终止", "八、知识产权", "九、免责声明",
                    "十、协议变更与联系我们"))
}

# 判据 ③：正文第一行就是文档题
firstline_criterion <- function(lines) identical(trimws(lines[1]), "# 用户须知")

# ---------------------------------------------------------------------------
# 0. 先证明这三段抄来的判据确实是 selftest.R 里那一份
# ---------------------------------------------------------------------------
say("\n== 0. 抄件与 selftest.R 逐字一致吗 ==")
# 判据①的判别性片段（挑三行最能说明"是同一份实现"的）
for (frag in c("doc <- fs_of(\".dsapp-tos-md > h1:first-child\")",
               "grp <- fs_of(\".dsapp-tos-md h1 {\")",
               "identical(num(c(doc, grp, h2s)), sort(num(c(doc, grp, h2s)), decreasing = TRUE))",
               "tos_h1 <- sub(\"^#\\\\s+\", \"\", grep(\"^#\\\\s+[^#]\", tos_lines, value = TRUE))",
               "identical(trimws(tos_lines[1]), \"# 用户须知\")"))
  chk(sprintf("selftest.R 里有这一句：%s", substr(frag, 1, 46)),
      grepl(norm(frag), norm(self), fixed = TRUE))

# ---------------------------------------------------------------------------
# 1. 基线：仓库现在这版 → 三条判据都必须**绿**
# ---------------------------------------------------------------------------
say("\n== 1. 基线（仓库现在这版）==")
real_css <- paste(readLines("www/app.css", warn = FALSE), collapse = "\n")
real_txt <- readLines("data/user_must_know_V1.txt", warn = FALSE,
                      encoding = "UTF-8")
chk("① CSS 三档字号 → 绿", css_fs_criterion(real_css))
chk("② 标题结构 → 绿", h_structure_criterion(real_txt))
chk("③ 第一行是文档题 → 绿", firstline_criterion(real_txt))
say("     （基线全绿 = 判据没写反；下面才是变异）")

# ---------------------------------------------------------------------------
# 2. 变异体：每条都**必须**让对应的判据红
# ---------------------------------------------------------------------------
say("\n== 2. 变异体 ==")

# M1：把分组标题的字号改成和二级章**一模一样** —— 这次改动的实质就是分层，
#     只加 `#` 不分层等于没改，判据必须抓得住。
m1 <- sub(".dsapp-tos-md h1 {\n  font-size: .9375rem;",
          ".dsapp-tos-md h1 {\n  font-size: .875rem;", real_css, fixed = TRUE)
chk("M1 打中了（h1 规则真的从 .9375rem 变成了 .875rem）",
    !identical(m1, real_css), "没打中，后面那条绿是白送的")
chk("M1 分组与章**同字号** → ① 必须红", !css_fs_criterion(m1))

# M2：把文档题那条规则**摘掉**（用户第一眼看到的那档没了）
m2 <- sub(".dsapp-tos-md > h1:first-child {\n  font-size: 1.0625rem; font-weight: 700;",
          ".dsapp-tos-md > h1:first-child {\n  font-size: .9375rem; font-weight: 700;",
          real_css, fixed = TRUE)
chk("M2 打中了（文档题那条真的改了）", !identical(m2, real_css),
    "没打中，后面那条绿是白送的")
chk("M2 文档题退化成和分组一样大 → ① 必须红", !css_fs_criterion(m2))

# M3：把三档写得**从大到小反了**（互不相同但不递减）—— 只判"互不相同"的
#     写法会在这里白送一个绿。
m3 <- sub(".dsapp-tos-md > h1:first-child {\n  font-size: 1.0625rem;",
          ".dsapp-tos-md > h1:first-child {\n  font-size: .75rem;",
          real_css, fixed = TRUE)
chk("M3 打中了", !identical(m3, real_css), "没打中")
chk("M3 文档题比正文还小（互不相同但不递减）→ ① 必须红",
    !css_fs_criterion(m3))

# M4：**删掉**一个分组标题（归纳时手滑吞掉一章的等价物）
m4 <- real_txt[!grepl("^# 第三部分", real_txt)]
chk("M4 打中了（第三部分那行真的没了）", length(m4) == length(real_txt) - 1L,
    "没打中")
chk("M4 少一个一级分组 → ② 必须红", !h_structure_criterion(m4))

# M5：把某一章降级/删掉（十章变九章）
m5 <- real_txt[!grepl("^## 五、数据与隐私", real_txt)]
chk("M5 打中了", length(m5) == length(real_txt) - 1L, "没打中")
chk("M5 少一个二级章 → ② 必须红", !h_structure_criterion(m5))

# M6：**分组里再插一章**（顺序对了但多出来一节）
m6 <- append(real_txt, "## 十一、多出来的一章",
             after = which(grepl("^## 十、", real_txt)))
chk("M6 打中了", length(m6) == length(real_txt) + 1L, "没打中")
chk("M6 多一个二级章 → ② 必须红", !h_structure_criterion(m6))

# M7：第一行前面插一句 —— 文档题不再是第一个孩子，CSS 那条 `:first-child`
#     就静默失效（这是**最阴**的一种：文件看着没错，屏幕上少一档层次）
m7 <- c("言出法随生信 APP", real_txt)
chk("M7 打中了", length(m7) == length(real_txt) + 1L, "没打中")
chk("M7 第一行不是 `# 用户须知` 了 → ③ 必须红", !firstline_criterion(m7))

# M8：把 `#` 换成 `##`（等于这次的改动**整个没做**）
m8 <- sub("^# 用户须知", "## 用户须知", real_txt)
chk("M8 打中了", !identical(m8, real_txt), "没打中")
chk("M8 文档题降级成二级（= 改动没做）→ ③ 必须红", !firstline_criterion(m8))
chk("M8 同时 ② 也必须红（一级标题只剩 4 个）", !h_structure_criterion(m8))

# ---------------------------------------------------------------------------
# 3. 顺带修好的那两条老断言：**读不到文件必须红**
# ---------------------------------------------------------------------------
# 这两条（内嵌兜底逐字一致 / 改一个字指纹就变）原来的写法是
#     f <- dsapp_tos_file(); if (is.null(f)) TRUE else …
# 而自检把 DSAPP_DATA_ROOT 指到空临时目录 ⇒ f 恒为 NULL ⇒ **恒真**。
# item 6 加断言时当场撞上：同样的 `readLines(NULL)` 让**整个自检中断**，
# 而屏幕上 0 个 ✗ —— 看着像"全过"。所以这里把守卫单独钉一遍。
say("\n== 3. 「读不到文件」的守卫（新写法必须红，旧写法是 TRUE）==")
guard <- function(lines) if (!length(lines)) FALSE else
  identical(paste(lines, collapse = "\n"), embed)
for (f in c("R/utils.R", "R/config.R", "R/tos.R")) try(source(f), silent = TRUE)
if (!exists("dsapp_tos_default_text")) {
  chk("能取到内嵌正文（取不到下面几条没意义）", FALSE)
} else {
  embed <- dsapp_tos_default_text()
  chk("④ 文件读不到 → **红**（旧写法在这里是 TRUE = 那个洞）",
      !isTRUE(guard(character(0))))
  chk("④ 读到了且一致 → 绿", isTRUE(guard(real_txt)))
  one_off <- real_txt
  one_off[length(one_off)] <- paste0(one_off[length(one_off)], "多一个字")
  chk("④ 正文改一个字 → **红**（证明这条是真的在比，不是恒真）",
      !isTRUE(guard(one_off)))
  chk("④ 空文件（不是 NULL，是读到了 0 行）→ 也红",
      !isTRUE(guard(character(0))))
}

say("")
if (ok) {
  cat("\033[32m判据都活着：基线全绿、八条变异条条见红。\033[0m\n")
} else {
  cat("\033[31m有判据是死的（上面标 ✗ 的）。\033[0m\n")
  quit(status = 1)
}
