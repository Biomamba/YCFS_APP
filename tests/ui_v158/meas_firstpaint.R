#!/usr/bin/env Rscript
# =============================================================================
# V15.12 取证：**每个账号的"首屏"到底有多少字节**（只读，不写库）
# =============================================================================
# 为什么要有这个：2026-10-03 那个「页面崩溃」= 每 120 秒一次的整页重载圈，
# 而圈的动力就是"首屏这一包排不完"。所以每次讨论"要不要把预算/心跳调大调小"
# 之前，先拿它把**真实的字节数**量出来 —— 不要靠估。
#
# 首屏 = 外壳（人人不同：管理员多「后台管理」那几页）+ 登录时**自动打开**的
# 那个会话的历史窗口。自动打开哪一个：R/mod_chat.R 里 db_sessions_list() 是
# `ORDER BY updated_at DESC` 取第一条 —— 所以这里也按每个用户最近更新的
# 那个会话算。⚠️ 这条正是 2026-10-03 那次差点量错的地方：应用会自动选中最近
# 更新的会话，你要是拿一个"更早的"会话去量，量出来的数看着合理但没人会看到。
#
# 用法：
#   cd /data3/biomamba/analysis/DS_App
#   Rscript tests/ui_v158/meas_firstpaint.R            # 默认读线上库（只读打开）
#   DSAPP_MEAS_DB=/tmp/dsapp_v1512b/data/dsapp.sqlite3 Rscript tests/ui_v158/meas_firstpaint.R
#
# ⚠️ 库一律**只读**打开（SQLITE_RO），不建表、不写一个字节。
# ⚠️ 输出里 `旧包KB` / `新包KB` 是"V15.11 只数正文"和"V15.12 正文+思维链"两种
#    预算口径下，这个窗口会渲染出多少字节 —— 差多少就是那件事修了多少。
# =============================================================================
suppressMessages(library(shiny))
Sys.setenv(DSAPP_DATA_ROOT = "/tmp/dsapp_meas_root")   # 只为骗过路径守卫，不写

.args <- commandArgs(trailingOnly = FALSE)
.repo <- normalizePath(file.path(dirname(sub("^--file=", "",
                    .args[grepl("^--file=", .args)][1])), "..", ".."))
setwd(.repo)
for (f in list.files("R", full.names = TRUE, pattern = "\\.R$")) source(f, local = globalenv())

.db <- Sys.getenv("DSAPP_MEAS_DB",
                  file.path(.repo, "data", "dsapp.sqlite3"))
cat("库：", .db, "（只读）\n")
con <- DBI::dbConnect(RSQLite::SQLite(), dbname = .db, flags = RSQLite::SQLITE_RO)

# 每个用户"最近更新的那个会话"
recent <- DBI::dbGetQuery(con, "
  SELECT s.user_id, u.email, s.id AS sid, count(m.id) AS n,
         sum(length(coalesce(m.content,'')))   AS txt,
         sum(length(coalesce(m.reasoning,''))) AS rea
  FROM sessions s JOIN messages m ON m.session_id = s.id
  JOIN users u ON u.id = s.user_id
  WHERE s.id IN (SELECT id FROM (
        SELECT id, user_id, row_number() OVER (PARTITION BY user_id
               ORDER BY updated_at DESC) rn FROM sessions) WHERE rn = 1)
  GROUP BY s.id ORDER BY s.user_id")

cat("\n=== 登录时自动打开的那个会话，窗口后打出多少字节 ===\n")
cat(sprintf("%-22s %-24s %4s %9s %6s %9s %9s\n",
            "user", "session", "条", "思维链KB", "旧条", "旧包KB", "新包KB"))
for (k in seq_len(nrow(recent))) {
  sid <- recent$sid[k]
  msgs <- DBI::dbGetQuery(con, sprintf(
    "SELECT id, role, coalesce(content,'') AS content, coalesce(reasoning,'') AS reasoning
     FROM messages WHERE session_id = '%s' ORDER BY id", sid))
  if (!nrow(msgs)) next
  # 渲染这些消息要多少字节（渲染不出来记 0，**不补默认值**）
  nb <- function(idx) sum(vapply(idx, function(i) {
    h <- tryCatch(dsapp_msg_bubble(msgs$role[i], msgs$content[i], msgs$id[i],
                                   reasoning = msgs$reasoning[i]),
                  error = function(e) NULL)
    if (is.null(h)) 0L
    else {
      b <- suppressWarnings(as.integer(nchar(as.character(h), type = "bytes")))
      if (is.na(b)) 0L else b
    }
  }, 0))
  mk <- function(ch) {
    w <- dsapp_hist_window(ch, 0L)
    if (w$shown > 0L) seq.int(w$start, nrow(msgs)) else integer(0)
  }
  i_old <- mk(nchar(msgs$content))                              # V15.11 的口径
  i_new <- mk(nchar(msgs$content) + nchar(msgs$reasoning))      # V15.12 的口径
  cat(sprintf("%-22s %-24s %4d %9.1f %6d %9.1fK %9.1fK\n",
              recent$email[k], sid, nrow(msgs), recent$rea[k] / 1024,
              length(i_old), nb(i_old) / 1024, nb(i_new) / 1024))
}
DBI::dbDisconnect(con)
cat("\n（这是**窗口**那一块。整屏还要加上外壳：112~116 KB —— 见 README 里那句\n")
cat("  「外壳这个数在不同次测量里落在 112~116 KB」。\n")
cat("  判死的条件是「一包字节数 > 链路速率 × (心跳周期 + 10)」——\n")
cat("  3.65 KB/s（实测最慢的那条）× 190 秒 ≈ 694 KB。\n")
