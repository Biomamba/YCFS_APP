#!/usr/bin/env Rscript
# Test_V15.2 · 邮件提醒的**界面接线**（设置页那张卡 + 言出法随那个勾选框）
#
#   cd /tmp/dsapp_v152/fake/app && Rscript tests/v152_mail_prefs.R
#
# ⚠️ 这个文件查的是**接线**，不是"函数对不对"。
#    `selftest-green-is-not-coverage` 那条教训说的是：函数写对了 ≠ 用户看得见。
#    这里能证明的到此为止 —— "卡片长什么样、点了有没有反应"要浏览器探针
#    （tests/ui_v152/）来说，那一步在 V4。
#
# 三段：
#   A 偏好键本身：两个新键在不在、默认值对不对、存一个键会不会踩掉别的
#   B 卡片函数：能建出来、收件地址显示的是传进去的那个邮箱、两个勾选框的
#     id 和当前值对得上
#   C 源码级：接线接上了没有（★ 剥注释再 grep —— 反例往往就写在解释它的
#     注释里，这个坑踩过三次）

setwd("/tmp/dsapp_v152/fake/app")
# ⚠️ B 段要真的把卡片建出来，得让 shiny 的标签函数（tagList/p/div/checkboxInput…）
#    在作用域里。`R/*.R` 自己的顶层代码不调它们，所以平时 source 起来不用加载
#    shiny —— 这个脚本要，就显式加载。别把 R/*.R 改成 library(shiny)。
suppressMessages(library(shiny))
for (f in list.files("R", full.names = TRUE)) {
  if (!grepl("^mod_", basename(f))) source(f, local = globalenv())
}
cfg <- dsapp_config()
if (!grepl("^/tmp/", cfg$data_root)) stop("拒绝对着非 /tmp 的 data_root 跑")

ok <- TRUE
say <- function(label, cond, extra = "") {
  cat(sprintf("%-34s %s %s\n", label, if (isTRUE(cond)) "OK " else "!! ", extra))
  if (!isTRUE(cond)) ok <<- FALSE
}
# ★ 剥注释：要查的写法往往就写在解释它的注释里（memory：scan-source-strip-comments）
strip_c <- function(txt) {
  txt <- gsub("(?m)#.*$", "", txt, perl = TRUE)
  gsub("(?s)#'.*?\n", "\n", txt, perl = TRUE)
}
read_src <- function(p) paste(readLines(p, warn = FALSE), collapse = "\n")

con <- dsapp_db(cfg)

# ======================= A 偏好键 =============================================
cat("=== A 偏好键 ===\n")
sp <- DSAPP_UIPREF_SPECS
say("有 email_task 键", "email_task" %in% names(sp))
say("有 email_lit_done 键", "email_lit_done" %in% names(sp))
say("email_task 默认关",
    identical(sp$email_task$kind, "flag") && isFALSE(sp$email_task$def))
say("email_lit_done 默认关",
    identical(sp$email_lit_done$kind, "flag") && isFALSE(sp$email_lit_done$def))
say("归一化后默认是 FALSE",
    isFALSE(dsapp_uipref_norm(NULL)$email_task) &&
    isFALSE(dsapp_uipref_norm(NULL)$email_lit_done))

# 存一个键不能踩掉别的键（"改完宽度，输入区高度自己变回自动了"那个坑）
stamp <- as.integer(Sys.time())
reg <- dsapp_user_create("邮件界面测试", sprintf("mailui%d@example.org", stamp),
                         sprintf("137%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234", password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
u <- dsapp_user_by_email(sprintf("mailui%d@example.org", stamp), con = con)
uid <- as.integer(u$id)

p0 <- dsapp_uipref_get(uid, con = con)
p0$files_w <- 333L
dsapp_uipref_save(uid, p0, con = con)
p1 <- dsapp_uipref_get(uid, con = con)
p1$email_task <- TRUE
dsapp_uipref_save(uid, p1, con = con)
p2 <- dsapp_uipref_get(uid, con = con)
say("设了 email_task", isTRUE(p2$email_task))
say("别的键没被踩掉", identical(as.integer(p2$files_w), 333L),
    sprintf("（files_w=%s）", p2$files_w))
say("email_lit_done 还是关的", isFALSE(p2$email_lit_done))

# 关回去
p2$email_task <- FALSE
dsapp_uipref_save(uid, p2, con = con)
say("能关回去", isFALSE(dsapp_uipref_get(uid, con = con)$email_task))
say("关掉后 files_w 还在",
    identical(as.integer(dsapp_uipref_get(uid, con = con)$files_w), 333L))

# ======================= B 卡片函数 ===========================================
cat("\n=== B 卡片函数 ===\n")
ns <- function(x) paste0("settings-", x)
mailto <- sprintf("mailui%d@example.org", stamp)
h <- as.character(dsapp_mail_pref_card(ns, dsapp_uipref_norm(NULL), mailto))
say("能建出来", length(h) > 0L && nzchar(h))
say("显示了收件地址", grepl(mailto, h, fixed = TRUE))
say("有任务提醒勾选框", grepl('id="settings-pref_mail_task"', h, fixed = TRUE))
say("有速递提醒勾选框", grepl('id="settings-pref_mail_lit"', h, fixed = TRUE))
say("有测试按钮", grepl('id="settings-mail_test"', h, fixed = TRUE))
say("有回执容器", grepl('id="settings-mail_test_msg"', h, fixed = TRUE))
# 默认关着 → 两个勾选框都不该带 checked
say("默认不勾", !grepl("checked", h, fixed = TRUE))

h2 <- as.character(dsapp_mail_pref_card(
  ns, list(email_task = TRUE, email_lit_done = TRUE), mailto))
say("勾上后带 checked", grepl("checked", h2, fixed = TRUE))
# ⚠️ 两个都勾上时要有**两个** checked 属性 —— 只搜到一个说明两个勾选框
#    共用了同一个 id 或者同一个值源（表现是"勾一个另一个跟着变"）。
#
# ⚠️ 数是 `checked="checked"` 这个**整属性**，不是子串 "checked"：
#    shiny 渲染出来就是 `checked="checked"`，子串会数成两倍
#    （第一版写成数子串，4 个 → 假红，代码是好的）。
n_checked <- length(gregexpr('checked="checked"', h2, fixed = TRUE)[[1]])
say("两个勾选框各管各的", n_checked == 2L, sprintf("（%d 个）", n_checked))

# 没有邮箱的账号：不能显示成空白，要说出来
h3 <- as.character(dsapp_mail_pref_card(ns, dsapp_uipref_norm(NULL), ""))
say("没邮箱时明说", grepl("没有填邮箱", h3, fixed = TRUE))

# ======================= C 源码级接线 =========================================
cat("\n=== C 源码级接线 ===\n")
set <- strip_c(read_src("R/mod_settings.R"))
chat <- strip_c(read_src("R/mod_chat.R"))

# 设置页：卡片的外框也归 output 管（没配 SMTP 时整张卡不出现）
say("设置页有 mail_card_wrap", grepl('output\\$mail_card_wrap <- renderUI', set))
say("没配 SMTP 时返回 NULL",
    grepl('if \\(!mail_ok\\) return\\(NULL\\)', set))
say("mail_ok 判的是 dsapp_mail_ready",
    grepl('mail_ok <- isTRUE\\(dsapp_mail_ready\\(cfg\\)\\)', set))
say("卡片塞进执行页签", grepl('uiOutput\\(ns\\("mail_card_wrap"\\)\\)', set))
say("设置页两个键都存",
    grepl('mail_pref_changed\\("email_task"', set) &&
    grepl('mail_pref_changed\\("email_lit_done"', set))
# ★ 断环的那一条：值没变就不写
say("写之前先比对（断自失效环）",
    grepl('identical\\(isTRUE\\(cur\\[\\[which\\]\\]\\), isTRUE\\(value\\)\\)', set))
# 测试邮件走队列，不在本进程直接发
say("测试邮件走入队", grepl('dsapp_mail_enqueue\\(', set))
say("本进程不直接发信", !grepl('dsapp_mail_send_raw\\(', set))
say("入队后 kick 起子进程", grepl('dsapp_mail_kick\\(', set))
# ⚠️ 轮询那一段必须 isolate 读 ticks（读了又写就是自己失效自己）。
#    它现在住在 dsapp_mail_ui_watch() 里（两个页面共用一份），所以查 R/mail.R。
say("轮询用 isolate 读 ticks",
    grepl('n <- isolate\\(ticks\\(\\)\\)', strip_c(read_src("R/mail.R"))))
say("轮询只读 job 那一个依赖",
    grepl('id <- job\\(\\)', strip_c(read_src("R/mail.R"))))
# 两个页面共用同一个轮询实现，不各写一份
say("设置页用共用轮询", grepl('dsapp_mail_ui_watch\\(cfg\\)', set))
say("本进程不直接发信（设置页）", !grepl('dsapp_mail_send_raw\\(', set))

# 言出法随：勾选框只在配了 SMTP 时出现
say("对话页有 mail_notify", grepl('checkboxInput\\(ns\\("mail_notify"\\)', chat))
say("对话页也判 mail_ready",
    grepl('if \\(isTRUE\\(dsapp_mail_ready\\(dsapp_config\\(\\)\\)\\)\\)', chat))
say("对话页不用 conditionalPanel",
    !grepl('conditionalPanel', chat))
say("对话页保存前也比对",
    grepl('identical\\(isTRUE\\(full\\$email_task\\), v\\)', chat))
say("对话页推新值时 isolate input",
    grepl('isolate\\(input\\$mail_notify\\)', chat))

# 两处改的必须是**同一个**键
say("两处同一个键",
    grepl('"email_task"', set) && grepl('full\\$email_task', chat))

cat("\n", if (ok) "=== 邮件界面接线全过 ===" else "=== 有红的 ===", "\n", sep = "")
quit(status = if (ok) 0L else 1L)
