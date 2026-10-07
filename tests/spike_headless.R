#!/usr/bin/env Rscript
# =============================================================================
# 尖刀验证（Test_V15.2 步骤 0）：**没有 Shiny 会话**时，agent 循环跑不跑得完？
# =============================================================================
#
# 为什么单独写这一个脚本、而不是直接去写订阅功能：
#
#   「文献速递定时订阅」的全部可行性压在一句话上 ——
#   **能不能在没有浏览器、没有登录、没有主进程的情况下，把一次完整的
#     agent 循环跑到收尾。** 读代码看着能行（R/detach.R 就是干这个的），
#   但"看着能行"在这个仓库里栽过太多次了。所以先花一次最小代价证明它，
#   再往上盖 UI。
#
# 代价控制：提示词**故意是废话**（只要求回一句、不许检索、不许建文件），
#   max_iter / wall_limit 都压到最小。证明的是**机制**，不是速递本身。
#
# 跑法（⚠️ 必须在实例目录里跑，让它读那一份 .Renviron）：
#
#   cd /tmp/dsapp_v152/app && Rscript tests/spike_headless.R
#
# ⚠️ 绝不要拿它对着生产 data_root 跑 —— 它会**真的建会话、真的烧 token**。
# =============================================================================

t0 <- Sys.time()

# ---- 1. source 代码：和 .dsapp_agent_worker 一模一样的那一套 -----------------
# 跳过 mod_*.R：它们是 UI 模块，依赖 Shiny，无头环境里用不到也不需要。
app_dir <- normalizePath(".")
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  if (grepl("^mod_", basename(f))) next
  source(f, local = globalenv())
}
cfg <- dsapp_config()

cat("== 应用目录 :", cfg$app_dir, "\n")
cat("== 数据目录 :", cfg$data_root, "\n")

# ⚠️ 这一条是保命的。仓库根的 .Renviron 会把实例接到**生产库**上，
#    而且不报错、界面无异常。跑之前先确认脚下踩的是 /tmp。
if (!grepl("^/tmp/", cfg$data_root)) {
  stop("拒绝对着非 /tmp 的 data_root 跑尖刀验证：", cfg$data_root)
}

USER_ID <- 1L
con <- dsapp_db(cfg)

u <- dsapp_user_by_id(USER_ID, con = con)
if (is.null(u)) stop("users.id = ", USER_ID, " 不存在")
cat("== 账号     :", u$nickname, "<", u$email, ">\n")

s <- tryCatch(dsapp_settings_get(USER_ID, con = con), error = function(e) list())
cat("== LLM      : vendor=", s$vendor %||% "?",
    " model=", s$model %||% "?", "\n", sep = "")
if (!nzchar(s$vendor %||% "")) stop("这个账号没配模型厂商，无头跑没法开始")

# ---- 2. 建一个测试会话，塞一句**廉价的**用户消息 ----------------------------
sid <- db_session_create(title = "[尖刀] 无头运行验证", user_id = USER_ID,
                         con = con)
cat("== 会话     :", sid, "\n")

PROMPT <- paste(
  "这是一次连通性验证，**不要做任何检索，不要执行任何命令，不要创建任何文件**。",
  "请只回复一句：无头运行正常。",
  sep = "\n")
db_message_add(sid, "user", PROMPT, con = con)

# ---- 3. 起后台循环 ----------------------------------------------------------
WALL <- 300L    # 5 分钟足够跑完一句废话；真跑速递时会开到几十分钟
ITER <- 3L

ok <- dsapp_detach_start(
  sid, user_id = USER_ID,
  target = list(kind = "server", env = "system"),
  max_iter = ITER, wall_limit = WALL,
  params = list(vendor = s$vendor, model = s$model, base_url = s$base_url,
                temperature = 0.3, max_tokens = 2048),
  scene = "agent", resume = NULL, mode = "full", cfg = cfg)

cat("== 起没起来 :", ok, "\n")
if (!isTRUE(ok)) {
  r <- dsapp_arun_get(sid, cfg)
  cat("!! 没起来，agent_runs 里是：\n"); print(r)
  quit(status = 1)
}

# ---- 4. 等它收尾（这就是将来调度器要干的事）--------------------------------
# 判据是**离开 running**，不是"变成 done" —— stopped/orphan 同样是收尾，
# 而且那两种恰恰是最需要看见的失败。
deadline <- t0 + WALL + 60
last <- ""
repeat {
  Sys.sleep(2)
  r <- dsapp_arun_get(sid, cfg)
  st <- as.character(r$state %||% "?")
  if (!identical(st, last)) {
    cat(sprintf("[%5.0fs] state=%s  note=%s\n",
                as.numeric(difftime(Sys.time(), t0, units = "secs")),
                st, substr(as.character(r$note %||% ""), 1, 90)))
    last <- st
  }
  if (!identical(st, "running")) break
  if (Sys.time() > deadline) { cat("!! 超时\n"); break }
}

# ---- 5. 看结果 --------------------------------------------------------------
cat("\n===== 对话里落下来的消息 =====\n")
msgs <- db_messages_get(sid, con = con)
for (i in seq_len(nrow(msgs))) {
  cat(sprintf("[%s] %s\n", msgs$role[i],
              substr(gsub("\n", " ", msgs$content[i] %||% ""), 1, 160)))
}

cat("\n===== 工作区 =====\n")
wd <- dsapp_ws_dir(sid, cfg = cfg, create = FALSE)
cat("路径:", wd %||% "(没有)", "\n")
if (!is.null(wd) && dir.exists(wd)) print(list.files(wd, all.files = TRUE))

cat("\n===== 日志尾部 =====\n")
for (ext in c("out", "err")) {
  p <- file.path(cfg$logs_dir, sprintf("detach-%s.%s", sid, ext))
  if (file.exists(p)) {
    cat("--- ", basename(p), " ---\n", sep = "")
    cat(paste(tail(readLines(p, warn = FALSE), 20), collapse = "\n"), "\n")
  }
}

r <- dsapp_arun_get(sid, cfg)
cat("\n== 最终 state:", as.character(r$state %||% "?"), "\n")
cat("== 耗时:", round(as.numeric(difftime(Sys.time(), t0, units = "secs"))), "秒\n")
cat("== 会话 id（要手动清掉的话）:", sid, "\n")
