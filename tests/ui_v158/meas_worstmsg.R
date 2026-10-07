#!/usr/bin/env Rscript
# =============================================================================
# V15.12 取证：**单条消息渲染出来最大能有多大**（只读，不写库）
# =============================================================================
# 为什么要有这个：`dsapp_hist_window()` 的规则① 是「最后 DSAPP_HIST_FLOOR_MSG(=2)
# 条**永远渲染**、不参与预算」—— 也就是说那个 50 000 字符的预算是**有底的**，
# 底就是这两条消息的原始大小。这个脚本量的是这个底能有多高。
#
# 2026-10-03 实测：最大的一条（id=749）**384 352 字节**。
# 配上规则①，一个会话的理论最坏首屏 ≈ 2×384 KB + 外壳 115 KB ≈ 880 KB，
# 而判死的线是 3.65 KB/s × 190 秒 ≈ 694 KB —— **仍然是可能越过的**。
# 这不是"没修好"，是"修的是这一层，上一层（单条消息没有渲染上限）还没修"：
# 真正的解法是给单条消息加渲染上限/折叠，属于产品改动，V15.12 没做。
# 每次动预算/心跳之前，先跑这个看底有没有变高。
#
# 用法：
#   cd /data3/biomamba/analysis/DS_App
#   Rscript tests/ui_v158/meas_worstmsg.R            # 默认读线上库（只读打开）
#   DSAPP_MEAS_DB=/tmp/dsapp_v1512b/data/dsapp.sqlite3 Rscript tests/ui_v158/meas_worstmsg.R
#
# ⚠️ 库一律**只读**打开（SQLITE_RO），不建表、不写一个字节。
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

big <- DBI::dbGetQuery(con, "
  SELECT id, session_id, role, length(coalesce(content,'')) AS n,
         length(coalesce(reasoning,'')) AS r
  FROM messages ORDER BY (length(coalesce(content,'')) + length(coalesce(reasoning,''))) DESC LIMIT 12")
cat("\n=== 正文+思维链最长的 12 条 ===\n")
cat(sprintf("%-6s %-22s %-10s %8s %8s %10s\n", "id", "session", "role", "正文", "思维链", "渲染字节"))
for (i in seq_len(nrow(big))) {
  m <- DBI::dbGetQuery(con, sprintf(
    "SELECT id, role, coalesce(content,'') AS content, coalesce(reasoning,'') AS reasoning
     FROM messages WHERE id = %d", big$id[i]))
  h <- tryCatch(as.character(dsapp_msg_bubble(m$role[1], m$content[1], m$id[1],
                                              reasoning = m$reasoning[1])),
                error = function(e) NULL)
  b <- if (is.null(h)) NA_integer_ else as.integer(nchar(h, type = "bytes"))
  cat(sprintf("%-6d %-22s %-10s %8d %8d %10s\n", big$id[i], substr(big$session_id[i],1,22),
              big$role[i], big$n[i], big$r[i],
              if (is.na(b)) "渲染失败" else format(b)))
}
DBI::dbDisconnect(con)
cat("\n（规则①：最后 2 条永远渲染、不参与预算 —— 所以上面最大的那条 ×2 + 外壳 115 KB\n")
cat("  就是理论最坏首屏；3.65 KB/s × 190 秒 ≈ 694 KB 是判死的线。）\n")
