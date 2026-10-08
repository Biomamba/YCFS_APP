#!/usr/bin/env Rscript
# =============================================================================
# Test_V17.2 item 4：挂机的时候任务挂了，AI 到底有没有接手
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/ui_v172/t_autofix_unattended.R .
#
# ── 用户原话 ────────────────────────────────────────────────────────────────
#
# 「Biomamba_ceshi账号下的自动纠错似乎没能正常运行，即使是我挂载了"长任务
#  无人值守编排"的情况下。这类任务100%不需要用户确认，应该能自动运行才对」
#   后面附的就是卡片上那三行：
#     · 这一段没跑通，AI 已经在自动重试了 —— 你不用做什么。
#     · R 脚本中途退出了（stderr 在上面，没被别的规则认出来）
#       —— unused argument (gene = "TCF3")
#     · 重试这一步 一直没动静的话，可以点它再跑一遍。
#
# ── 根因（线上库，2026-10-08，uid=11）────────────────────────────────────
#
#   对话 s-20261008180139-1174 / 任务 #576，10:23:58 失败。而 agent_runs 里
#   那一行是 **mode = "finish"** —— 用户关页面时选的是「让当前任务跑完」。
#   那一档归 .dsapp_task_sitter_worker：守住任务、收尾、把结果写回对话，
#   然后**退出**，全程没有任何进程把模型叫起来。卡片上那句"已经在自动重试"
#   是**画卡片那一刻**写下的判断，挂机这条路上从来没有兑现过它。
#
# ── 这个测试盯什么 ──────────────────────────────────────────────────────────
#
#   A 决策   —— 什么情况下该接手、什么情况下**不该**（全是不起进程的分支）
#   B 端到端 —— 真起一个守护进程，让它守一个**已经失败**的任务，看它是不是
#               真的把模型叫起来了。这一节会起真进程（callr），是**唯一**
#               能证明"接手发生了"的方式：库里那条 finish 记录被换成 full
#               记录，而且新的那条带着我们传进去的采样参数快照。
#   C 文案   —— 后台进门那句【平台提示】按 origin 分三支。**求值**它，不是
#               grep 它：把 .dsapp_agent_worker 里那个 paste0 表达式从 AST
#               里抠出来，分别用三个 origin 各求一次值。
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source，且整份脚本**必须**用
#    `Rscript --no-environ` 跑 —— 仓库根的 .Renviron 指着生产库，而它
#    会盖掉继承的环境变量（只设 env 是不隔离的）。
# ⚠️ 会起真进程（callr），但**一条出网请求都没有**：那个进程拿不到 API Key，
#    会在第一秒里以 "这个账号没有可用的 API Key" 收场 —— 这正是我们要的，
#    它同时证明了"进程真的跑起来了"和"它用的是我们传进去的 data_root"。
#    base_url 也故意指到 127.0.0.1:9（discard 端口）兜底。
# ⚠️ 断言里不写字面量常数（轮数/墙钟的默认值从 config.R 取）。
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
tmp <- tempfile("dsapp_v172_fix_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}
# 应用起步时那一步（它建 logs_dir / run_dir）。不建的话 callr::r_bg 的
# stdout 指不到文件，报的却是"启动 R 解释器失败"—— 和真正的原因差着十万八千里。
dsapp_init_dirs(cfg0)
con <- dsapp_db(cfg0)
say("\n数据根：%s", cfg0$data_root)

# ---- 夹具 -------------------------------------------------------------------
stamp <- as.integer(Sys.time())
em <- sprintf("autofix%d@example.org", stamp)
r0 <- dsapp_user_create("fixer", em, sprintf("139%08d", stamp %% 1e8), "测试",
                        password = "test-only-1234",
                        password2 = "test-only-1234")
if (!isTRUE(r0$ok)) stop(r0$msg)
uid <- as.integer(dsapp_user_by_email(em, con = con)$id)

# 一次真实的失败：线上那条一模一样的 R 报错
ERR <- paste0("Error in GDCquery(project = \"TCGA-BRCA\", gene = \"TCF3\") : \n",
              "  unused argument (gene = \"TCF3\")\n",
              "Execution halted\n")

#' 造一个"正在跑、然后挂了"的任务
#'
#' ⚠️ 必须**同时**落一个结果文件：守护进程判"任务结束了没有"读的是
#'    run/job-<tid>.json（见 .dsapp_detach_poll），而不是任务行。只改任务行
#'    的话，收尾那一步会走进"执行进程意外退出（可能被系统杀掉）"那一支，
#'    把真实的报错**覆盖掉** —— 那样后面所有断言验的都是另一次失败。
mk_case <- function(tag, stderr = ERR, status = "error") {
  sid <- db_session_create(sprintf("挂机测试-%s", tag), user_id = uid, con = con)
  tid <- db_task_create(sprintf("任务-%s", tag), code = "GDCquery(gene='TCF3')",
                        lang = "R", session_id = sid, con = con)
  invisible(DBI::dbExecute(con, "UPDATE tasks SET status = 'running' WHERE id = ?",
                           params = list(tid)))
  writeLines(jsonlite::toJSON(
    list(ok = TRUE, status = status, exit_code = 1L, stdout = "",
         stderr = stderr, workdir = "", artifacts = list(), saved = list(),
         progress = list(), env_notes = list(), bad_artifacts = list()),
    auto_unbox = TRUE, null = "null", force = TRUE),
    file.path(cfg0$run_dir, sprintf("job-%d.json", tid)))
  list(sid = sid, tid = tid)
}

#' 把账号的「出错自动修」开关写进库（界面勾选框的落点就是这个）
#' ⚠️ 走官方那个写入口 dsapp_uipref_save()，不自己拼 JSON —— 自己拼的话，
#'    存进去的形状和真实路径存的不一样，测试测的就是另一件事了。
set_pref <- function(on) {
  p <- dsapp_uipref_get(uid, con = con)
  p$agent_autofix <- isTRUE(on)
  invisible(dsapp_uipref_save(uid, p, con = con))
  # 回读确认（写没写进去是另一件事，见 CLAUDE 里那条"界面回执说已允许而库里是 0"）
  isTRUE(dsapp_uipref_get(uid, con = con)$agent_autofix) == isTRUE(on)
}
set_pref(TRUE)
say("开关写进去了吗：agent_autofix = %s（读回来确认过）",
    dsapp_uipref_get(uid, con = con)$agent_autofix)

snapshot <- function(temp = 0.42)
  list(temperature = temp, ctx_limit = 0, thinking = TRUE,
       reasoning_effort = "high", vendor = "fake-vendor",
       model = "fake-model", base_url = "http://127.0.0.1:9/v1")

# =============================================================================
sect("A 决策：什么该接手、什么不该（都不起进程）")
# =============================================================================

# A1 失败 + 开关开着 → 该接手。这一条**会起进程**，见 B 节；这里只问
#    "不起进程的那些闸放不放行"，所以用一个已经被占用的对话先把它挡住 ——
#    闸门是**短路**的：上面任何一条不成立都会在起进程之前返回。
a_busy <- mk_case("busy")
db_task_status(a_busy$tid, "error", exit_code = 1L, stderr = ERR, con = con)
dsapp_arun_begin(a_busy$sid, user_id = uid, mode = "full", cfg = cfg0)
r <- .dsapp_autofix_takeover(a_busy$tid, a_busy$sid, user_id = uid, cfg = cfg0)
chk("★ 已经有后台循环在跑时**不**再起一条（两条会各写各的，用户看到两份过程）",
    !isTRUE(r$taken) && grepl("已经有一个后台循环", r$why, fixed = TRUE),
    sprintf("taken=%s why=%s", r$taken, r$why))

# A2 成功 → 不接手
a_ok <- mk_case("ok", status = "success")
db_task_status(a_ok$tid, "success", exit_code = 0L, stderr = "", con = con)
r <- .dsapp_autofix_takeover(a_ok$tid, a_ok$sid, user_id = uid, cfg = cfg0)
chk("★ 任务成功时什么都不做（「自动纠错」只在错的时候出现）",
    !isTRUE(r$taken) && grepl("没有失败", r$why, fixed = TRUE),
    sprintf("taken=%s why=%s", r$taken, r$why))

# A3 ★★ 阴性对照：卡片的静默分支（"AI 已经在自动重试了"）**只**在开关开着
#    时出现。关掉开关 → 既不接手，也不留那句"没接手"的交代（卡片本来就在
#    问用户）。这一条是"开关真的被读了"的**唯一**证据 —— 不关它的话，
#    "读偏好"和"恒为真"在行为上分不开。
a_off <- mk_case("prefoff")
db_task_status(a_off$tid, "error", exit_code = 1L, stderr = ERR, con = con)
set_pref(FALSE)
r <- .dsapp_autofix_takeover(a_off$tid, a_off$sid, user_id = uid, cfg = cfg0)
chk("★★ 开关关掉时不接手，而且**不**说自己「没能接手」（卡片会直接问用户）",
    !isTRUE(r$taken) && isFALSE(r$quiet) &&
      grepl("关掉了「出错自动修」", r$why, fixed = TRUE),
    sprintf("taken=%s quiet=%s why=%s", r$taken, r$quiet, r$why))
set_pref(TRUE)

# A4 ★★ 用户**自己停掉**的任务不接手。（卡片上这条判据叫"这不是待修的 bug"，
#    两处必须是同一个 —— 见 envfix.R 的 dsapp_err_stopped。）
a_stop <- mk_case("stopped", stderr = "已手动停止（任务页）\n")
db_task_status(a_stop$tid, "error", exit_code = 1L,
               stderr = "已手动停止（任务页）\n", con = con)
r <- .dsapp_autofix_takeover(a_stop$tid, a_stop$sid, user_id = uid, cfg = cfg0)
chk("★★ 用户点了「停止」的任务不接手（AI 又自己跑起来 = 跟用户对着干）",
    !isTRUE(r$taken) && grepl("被人停掉", r$why, fixed = TRUE),
    sprintf("taken=%s why=%s", r$taken, r$why))
chk("★ 阴性对照：同上，但**没有**那个标记时就会接手（说明上面那条不是恒真）",
    { a2 <- mk_case("notstopped")
      db_task_status(a2$tid, "error", exit_code = 1L, stderr = ERR, con = con)
      # 用一个已经在跑的对话把闸门挡在起进程之前，只为了看它**走过了**
      # "被停掉"那一道 —— why 会变成下一条闸门的话
      dsapp_arun_begin(a2$sid, user_id = uid, mode = "full", cfg = cfg0)
      r2 <- .dsapp_autofix_takeover(a2$tid, a2$sid, user_id = uid, cfg = cfg0)
      !grepl("被人停掉", r2$why, fixed = TRUE) },
    "同一份 stderr 换掉那一句之后，判据还是说'被人停掉'")

# A5 拿不到任务行 / 拿不到对话
r <- .dsapp_autofix_takeover(999999L, a_ok$sid, user_id = uid, cfg = cfg0)
chk("★ 任务行不在了 → 不接手（不报错）",
    !isTRUE(r$taken) && grepl("查不到", r$why, fixed = TRUE),
    sprintf("why=%s", r$why))
r <- .dsapp_autofix_takeover(a_ok$tid, NULL, user_id = uid, cfg = cfg0)
chk("★ 对话 id 是空/NA → 不接手（不报错）",
    !isTRUE(r$taken) && grepl("对话", r$why, fixed = TRUE),
    sprintf("why=%s", r$why))

# =============================================================================
sect("B 端到端：守护进程守着真失败，然后把模型叫起来")
# =============================================================================
# 这一节走的是**生产上那条一模一样的路**：dsapp_detach_sit() 起守护进程，
# 守护进程收尾 + 写回对话 + 销掉自己那条登记，然后调 .dsapp_autofix_takeover()。
b <- mk_case("e2e")
say("对话 %s · 任务 #%d", b$sid, b$tid)

params <- snapshot(0.42)
sit <- dsapp_detach_sit(b$tid, b$sid, user_id = uid,
                        target = list(kind = "server", env = "system"),
                        params = params, max_iter = 11L, wall_limit = 5400L,
                        cfg = cfg0)
chk("★ 守护进程起来了（预设「让当前任务跑完」的入口）", isTRUE(sit))

# ⚠️ 这一刻库里必须是 **finish** 那条：守护进程是在**父进程**里登记的
#    （dsapp_arun_begin 就在 r_bg 之前），而子进程要先把 R/ 下几十个文件
#    source 一遍才可能碰库 —— 中间隔着秒级。所以这里读到的"finish"不是
#    抢跑，是**顺序**。
r0b <- dsapp_arun_get(b$sid, cfg0)
chk("★ 登记先落成 finish（「正在后台跑完这个任务」，不是「接着往下跑」）",
    !is.null(r0b) && identical(as.character(r0b$blob$mode %||% ""), "finish"),
    sprintf("mode=%s", if (is.null(r0b)) "<没有行>" else r0b$blob$mode %||% ""))

#' 等一个条件成立，最多等多久
wait_for <- function(f, secs = 150, step = 0.5) {
  t0 <- Sys.time()
  repeat {
    v <- tryCatch(f(), error = function(e) FALSE)
    if (isTRUE(v)) return(TRUE)
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) > secs) return(FALSE)
    Sys.sleep(step)
  }
}

# ★★ B1：那条 finish 记录被**换成**了 full —— 这就是"接手发生了"。
#
# ⚠️ 它同时钉住了顺序：agent_runs 上 session_id 是 UNIQUE，守护进程不先
#    调 dsapp_arun_finish()（把自己那条销掉），dsapp_detach_start() 进门
#    第一句就会判"已经有循环在跑"然后拒绝。所以这一条绿 = 顺序是对的。
# ⚠️ 判据只看 mode，**不看 state**：接手起来的那个进程几秒之内就会因为
#    拿不到 API Key 收场（B4），而这里每 0.5 秒才看一次 —— 把 state 也写进
#    条件里，这条断言就变成"谁跑得快谁说了算"。state 由 B4 单独钉。
took <- wait_for(function() {
  rr <- dsapp_arun_get(b$sid, cfg0)
  !is.null(rr) && identical(as.character(rr$blob$mode %||% ""), "full")
}, secs = 150)
rb <- dsapp_arun_get(b$sid, cfg0)
chk("★★ 任务挂了之后，库里那条 finish 被换成了 **full**（有人把模型叫起来了）",
    took,
    sprintf("现在 mode=%s state=%s note=%s",
            if (is.null(rb)) "<没有行>" else rb$blob$mode,
            if (is.null(rb)) "" else rb$state,
            if (is.null(rb)) "" else rb$note))

# ★ B2：结果写回了对话（模型被叫起来时能读到那条报错）。
msgs <- DBI::dbGetQuery(con,
  "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id",
  params = list(b$sid))
tool_txt <- paste(msgs$content[msgs$role == "tool"], collapse = "\n")
chk("★ 结果写回了这条对话（后面被叫起来的模型读得到它）",
    grepl(sprintf("【执行结果 · 任务 #%d】", b$tid), tool_txt, fixed = TRUE),
    sprintf("tool 消息 %d 条", sum(msgs$role == "tool")))
chk("★★ 写回去的是**原样的报错**，不是「执行进程意外退出」",
    grepl("unused argument", tool_txt, fixed = TRUE) &&
      !grepl("执行进程意外退出", tool_txt, fixed = TRUE),
    substr(tool_txt, 1, 200))

# ★★ B3：接手那一条**带着现场快照**。
#    不带的话，挂机时 AI 自己修的那一次会用平台默认的温度/轮数/墙钟 ——
#    和用户盯着它修的那一次不是同一个请求，而他完全无从察觉。
chk("★★ 接手那条循环带着采样参数快照（挂机修的和盯着修的是同一个请求）",
    !is.null(rb) &&
      isTRUE(all.equal(as.numeric(rb$blob$params$temperature), 0.42)) &&
      identical(as.character(rb$blob$params$vendor %||% ""), "fake-vendor"),
    sprintf("params=%s", paste(utils::capture.output(str(rb$blob$params)),
                               collapse = " ")))
chk("★★ 轮数/墙钟也跟着走（漏传的话用户选 8 小时、后台按 2 小时掐断）",
    !is.null(rb) && identical(as.integer(rb$max_iter), 11L) &&
      isTRUE(all.equal(as.numeric(rb$blob$wall_limit), 5400)),
    sprintf("max_iter=%s wall=%s",
            if (is.null(rb)) "" else rb$max_iter,
            if (is.null(rb)) "" else rb$blob$wall_limit))

# ★★ B4：那个进程**真的跑起来了**，而且用的是我们的数据目录。
#    它拿不到 API Key，所以会在第一秒里以 orphan 收场 —— 那句 note 就是
#    它的指纹：说明它进到了 worker 主流程里，而不是"库里写了一行就没了"。
#    （这一条同时也保证了整个测试**一条出网请求都没有**。）
fin <- wait_for(function() {
  rr <- dsapp_arun_get(b$sid, cfg0)
  !is.null(rr) && !identical(as.character(rr$state %||% ""), "running")
}, secs = 150)
rf <- dsapp_arun_get(b$sid, cfg0)
chk("★★ 接手起来的那个进程真的跑到了收尾（不是只在库里写了一行）",
    fin && !is.null(rf) &&
      grepl("API Key", as.character(rf$note %||% ""), fixed = TRUE),
    sprintf("state=%s note=%s",
            if (is.null(rf)) "" else rf$state,
            if (is.null(rf)) "" else rf$note))

# ★ B5：阴性对照 —— 整个 B 节里**只有**那一条记录，没有被谁写重。
n_rows <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM agent_runs WHERE session_id = ?",
                          params = list(b$sid))$n
chk("★ 阴性对照：这个对话在 agent_runs 里始终只有一行（覆盖写，不是堆记录）",
    identical(as.integer(n_rows), 1L), sprintf("n=%s", n_rows))

# =============================================================================
sect("C 后台进门那句【平台提示】：三档不能共用一句话")
# =============================================================================
# 求值，不是 grep。把 .dsapp_agent_worker 里那个 paste0 表达式从 AST 里抠出来
# （parse 之后注释本来就没有了），三个 origin 各求一次值。
say_src <- paste(readLines(file.path(app_dir, "R", "detach.R"), warn = FALSE),
                 collapse = "\n")
exprs <- parse(text = say_src)

find_assign <- function(e, name) {
  if (!is.call(e)) return(NULL)
  if (identical(as.character(e[[1]])[1], "<-") && length(e) >= 3L &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), name)) return(e[[3]])
  for (i in seq_along(e)) {
    r <- find_assign(e[[i]], name)
    if (!is.null(r)) return(r)
  }
  NULL
}
find_head <- function(e, head) {
  if (!is.call(e)) return(NULL)
  if (identical(as.character(e[[1]])[1], head)) return(e)
  for (i in seq_along(e)) {
    r <- find_head(e[[i]], head)
    if (!is.null(r)) return(r)
  }
  NULL
}
worker <- NULL
for (e in exprs) {
  if (identical(as.character(e[[1]])[1], "<-") && is.name(e[[2]]) &&
      identical(as.character(e[[2]]), ".dsapp_agent_worker")) worker <- e[[3]]
}
opened <- if (is.null(worker)) NULL else find_assign(worker, "opened")
note_expr <- if (is.null(opened)) NULL else find_head(opened, "paste0")

chk("★ 抠到了后台进门那句话的表达式（抠不到就是结构变了，后面的断言全都不作数）",
    !is.null(note_expr))

note_of <- function(origin) {
  env <- new.env(parent = globalenv())
  env$origin <- origin
  paste(as.character(eval(note_expr, env)), collapse = "")
}
txt_sched <- note_of("schedule")
txt_fix   <- note_of("autofix")
txt_det   <- note_of("detach")
say("--- origin=autofix ---\n%s\n---", txt_fix)

chk("★★ autofix 那一档讲的是「任务失败了、平台接手修」",
    grepl("没有跑通", txt_fix, fixed = TRUE) &&
      grepl("出错自动修", txt_fix, fixed = TRUE) &&
      grepl("不需要你确认", txt_fix, fixed = TRUE),
    txt_fix)
chk("★★ 它**不**说「你在设置里选了「一路跑完」」（用户选的是「让当前任务跑完」）",
    !grepl("一路跑完", txt_fix, fixed = TRUE), txt_fix)
chk("★★ 三档的文案两两不同（共用一句 = origin 这个参数白加了）",
    length(unique(c(txt_sched, txt_fix, txt_det))) == 3L,
    sprintf("schedule=%s | detach=%s", substr(txt_sched, 1, 40), substr(txt_det, 1, 40)))
chk("★ 阴性对照：另外两档各自的内容没被改掉",
    grepl("定时订阅", txt_sched, fixed = TRUE) &&
      grepl("一路跑完", txt_det, fixed = TRUE))

# 没接成手时那条交代。⚠️ 用 deparse（注释会被 parse 掉）逐行判，
# 不做整段 grep —— 注释里就写着这些词，整段 grep 是白送的红/绿。
sitter <- NULL
for (e in exprs) {
  if (identical(as.character(e[[1]])[1], "<-") && is.name(e[[2]]) &&
      identical(as.character(e[[2]]), ".dsapp_task_sitter_worker")) sitter <- e[[3]]
}
sit_txt <- if (is.null(sitter)) "" else paste(deparse(sitter), collapse = "\n")
chk("★★ 没接成手时补一句交代（卡片上那句承诺没人兑现，不能让用户蒙在鼓里）",
    grepl("没有**自动接手**", sit_txt, fixed = TRUE) ||
      grepl("自动接手", sit_txt, fixed = TRUE),
    "守护进程里找不到那句交代")
chk("★ 而且它说的是「卡片上那句话是写下卡片时的判断」（不是让用户自己猜）",
    grepl("写下卡片时的判断", sit_txt, fixed = TRUE), "")

# =============================================================================
sect("D 「是不是被人停掉的」只有一处定义")
# =============================================================================
chk("★ 判据抽在 envfix.R 里（挂机和卡片问的是同一个问题）",
    is.function(dsapp_err_stopped) &&
      isTRUE(dsapp_err_stopped("已手动停止（任务页）")) &&
      isTRUE(dsapp_err_stopped("应用重启，任务被中断")) &&
      !isTRUE(dsapp_err_stopped(ERR)),
    sprintf("停止=%s 重启=%s 真报错=%s",
            dsapp_err_stopped("已手动停止（任务页）"),
            dsapp_err_stopped("应用重启，任务被中断"),
            dsapp_err_stopped(ERR)))
rnd <- readLines(file.path(app_dir, "R", "render.R"), warn = FALSE)
chk("★ 卡片那边改成调它了，**没有**再自带一份正则（两处各写一份迟早分叉）",
    any(grepl("dsapp_err_stopped(err_body)", rnd, fixed = TRUE)) &&
      !any(grepl("已手动停止|已被中止|被中断", rnd)),
    "render.R 里还留着一份自己的正则")

say("")
if (nfail > 0L) {
  say("\033[31m%d/%d 条没过\033[0m", nfail, NOK + nfail)
  quit(status = 1)
}
say("\033[32m全部通过（%d 条）\033[0m", NOK)
