# =============================================================================
# 脱离会话的续跑：页面关了、人登出了，AI 接着把活干完（V13.7 item 5）
# =============================================================================
#
# 用户原话：
#   「需要在登出状态下，AI的思考和任务能够继续挂载执行，并且是否执行可以让
#     用户预设选择」
#
# 拆成两件事：
#   1. **是否执行**由用户在设置页预设（R/uiprefs.R 的 agent_detach，
#      三档：立刻停下 / 让当前任务跑完 / 一路跑完）。
#   2. **怎么执行**：这一份文件。
#
# ---- 为什么必须是另一个进程 -------------------------------------------------
#
# 因为 Shiny 开源版**一个应用只有一个 R 进程**，而这个仓库的整个执行模型都
# 建立在"主进程绝不做长活"上（见 R/jobs.R 顶部、R/llm.R 顶部）。页面关掉
# 之后主进程里**没有任何东西会自己醒来**：
#
#   · 那个每秒一次的心跳是 `shiny::observe` + `invalidateLater`，它挂在
#     **会话**上。会话没了，心跳就没了（agent.R 的 a$tick）。
#   · `later::later()` 那条路 R/sync.R 里明确否决过（未声明依赖 + 回调跑在
#     主进程事件循环里，全站一起卡）。
#
# 所以"接着跑"只能落到一个**真的独立进程**上。这里用的还是 callr::r_bg ——
# 仓库里已经有三处（jobs.R / llm.R / jobs.R 的通用后台），依赖是现成的。
#
# ---- 关键取舍：**同一个状态机**，不是第二份循环 ------------------------------
#
# 最省事的写法是"在子进程里把 agent 循环再实现一遍"。**不这么做**，因为那
# 两份一定会分叉，而分叉的表现是"挂机跑出来的结果和盯着跑出来的不一样" ——
# 没有人会去逐行比对两个进程里的循环逻辑。
#
# 做法是让子进程构造**同一个** dsapp_agent_new()，把它的外壳换掉：
#
#   会话里                                子进程里（这里）
#   ───────────────────────────────       ───────────────────────────────
#   shiny::observe + invalidateLater  →   调用方自己 while + Sys.sleep
#   hooks$begin_llm = 起流式子进程     →   同步调一次 .dsapp_llm_once()
#   hooks$add_msg   = 写库 + 刷界面    →   只写库
#   hooks$refresh   = 刷界面           →   空转
#   engine          = 全局单槽引擎     →   dsapp_engine_shim()（同接口）
#   build_system_prompt（mod_chat 里）→   dsapp_scene_messages()（共用）
#
# ⚠️ 所以 agent.R 里那个心跳才是 a$tick() 而不是直接写在 observe 里 ——
#    抽出来就是为了这里能推它。改回去的话，这条路的循环会当场停摆，而且
#    不报任何错（a$state 不是 reactiveVal，没人推它就永远不动）。
#
# ---- 和主进程的关系：只剩数据库一条路 ---------------------------------------
#
# 子进程看不见主进程的内存（那个全局引擎对象、那个会话的 state）。所以：
#   · 状态写 agent_runs 表，"停止"按钮也写这张表（子进程每轮读一次）
#   · 任务走 dsapp_task_submit()（和会话完全同一条路，不抄第二份逻辑）
#
# ⚠️ **单槽的缺口**：主进程的"同时只跑一个任务"是内存里的一个标志位
#    （app.R 的 e$busy），跨进程看不见。这里用 dsapp_task_slot_busy() 查库
#    补一道，但它有一个几十毫秒的竞态窗口，成因和代价写在那个函数的注释里。
#    结论：最坏情况是两个任务同时跑，不会写坏任何数据。
# =============================================================================

# ---- agent_runs 表的读写 ----------------------------------------------------

#' 记下"这个对话有一个脱离会话的循环在跑"
#'
#' ⚠️ 同一对话**覆盖**写（表上 session_id 是 UNIQUE）。起一条新的意味着旧的
#'    那条已经不作数了 —— 留着两条的话，界面会同时显示两段"正在后台跑"，
#'    而用户根本没有第二个可以停的地方。
dsapp_arun_begin <- function(sid, user_id = NULL, target = NULL,
                             max_iter = NULL, wall_limit = NULL, params = NULL,
                             mode = "full",
                             cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(as.character(sid))) return(invisible(FALSE))
  sid <- as.character(sid)
  now <- dsapp_now()
  con <- dsapp_db(cfg)
  # target 和 params 一起打包进 target_json 一列。
  # ⚠️ 不加列：这两样都是"这一次运行的环境快照"，加两列就多两处要跟着
  #    schema 版本走的地方，而它们从来没有被单独查询过 —— 读出来就是一个
  #    list，怎么放进去的就怎么拿出来。
  #
  # mode（V13.7 item 5）："full" = 整个循环在后台接着跑，"finish" = 只有
  # 当前那个任务在后台跑完。**必须记下来**，不能靠界面猜 —— 两档在库里
  # 都是 state='running'，而横幅上那句话在两档下说的是完全不同的两件事。
  # 写成"AI 正在替你接着分析"而实际只是守着最后一个任务跑完，是在骗用户。
  #
  # wall_limit（★ V13.17 item 31）：用户选的自动结束时间，也进这一个 blob。
  # ⚠️ 同样**不加列**。max_iter 当年是单开了一列的，但那是它先来；这两个
  #    数现在是**成对**读写的（横幅要同时显示"第几轮 / 还剩多久"），
  #    分开存就得保证两处一起更新，而它们从来不被单独查询。
  # ⚠️ 加了这个键之后，**老行**（V13.17 之前写的）读出来 blob$wall_limit
  #    是 NULL。读的那一侧一律 `%||% DSAPP_AGENT_WALL_DEF` —— 老行当时跑的
  #    就是 7200，默认值正好还原它，不需要迁移。
  blob <- tryCatch(
    jsonlite::toJSON(list(target = target, params = params, mode = mode,
                          wall_limit = wall_limit),
                     auto_unbox = TRUE, null = "null", force = TRUE),
    error = function(e) NA_character_)
  tryCatch({
    DBI::dbExecute(con,
      "INSERT INTO agent_runs
         (session_id, user_id, target_json, max_iter, state, note, task_id,
          started_at, updated_at)
       VALUES (?, ?, ?, ?, 'running', '', NULL, ?, ?)
       ON CONFLICT(session_id) DO UPDATE SET
         user_id = excluded.user_id, target_json = excluded.target_json,
         max_iter = excluded.max_iter, state = 'running', note = '',
         task_id = NULL, started_at = excluded.started_at,
         updated_at = excluded.updated_at",
      params = list(sid, as.integer(user_id %||% NA),
                    as.character(blob), dsapp_iter_store(max_iter %||% NA),
                    now, now))
    invisible(TRUE)
  }, error = function(e) invisible(FALSE))
}

#' 更新一条后台运行的状态（子进程每轮调一次）
dsapp_arun_update <- function(sid, state = NULL, note = NULL, task_id = NULL,
                              cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(as.character(sid))) return(invisible(FALSE))
  sets <- character(0); ps <- list()
  if (!is.null(state))   { sets <- c(sets, "state = ?");   ps <- c(ps, list(as.character(state))) }
  if (!is.null(note))    { sets <- c(sets, "note = ?");    ps <- c(ps, list(as.character(note))) }
  # task_id 允许被**清空**（一轮跑完之后要清）。用 is.null 判的话就永远清不掉，
  # 于是界面上一直挂着一个早就跑完的任务号。所以单开一个显式开关：NA = 清空。
  #
  # ⚠️⚠️ 清空那一支**必须**把 NULL 字面写进 SQL，不能走占位符 + 参数列表。
  #    DBI 会当场拒掉（"Parameter N does not have length 1."），而这里的
  #    tryCatch 把它吞成 FALSE —— 症状不是"task_id 没清掉"，是**整条 UPDATE
  #    都没执行**：state/note 一起没写，状态永远停在 running。
  #    2026-09-19 实测踩到：后台续跑跑完之后收尾写不进去，横幅一直挂着
  #    「AI 正在后台接着跑」，而进程早就退了。
  if (!is.null(task_id)) {
    if (identical(task_id, NA)) {
      sets <- c(sets, "task_id = NULL")
    } else {
      sets <- c(sets, "task_id = ?"); ps <- c(ps, list(as.integer(task_id)))
    }
  }
  if (!length(sets)) return(invisible(FALSE))
  sets <- c(sets, "updated_at = ?"); ps <- c(ps, list(dsapp_now()))
  ps <- c(ps, list(as.character(sid)))
  tryCatch({
    DBI::dbExecute(dsapp_db(cfg),
                   sprintf("UPDATE agent_runs SET %s WHERE session_id = ?",
                           paste(sets, collapse = ", ")),
                   params = ps)
    invisible(TRUE)
  }, error = function(e) {
    # ⚠️ 这里**不能**静默。吞掉的后果不是"少写一个字段"，而是"整条 UPDATE
    #    没执行" —— 调用方（收尾那一步）拿到的 FALSE 只是"没写成"，
    #    而真正出事的是状态停在 running：横幅一直挂着，用户等一个永远
    #    不会来的结果。至少要留下痕迹。
    message("[dsapp] 后台续跑状态写库失败：", conditionMessage(e))
    invisible(FALSE)
  })
}

#' 读一个对话的后台运行状态；没有就返回 NULL
#'
#' ⚠️ 整段 tryCatch 返回 NULL：这张表是**旁挂的状态**，不是对话内容。库还没
#'    补到这一版（老连接）、或者表被锁着，都不该让对话页打不开 —— 而这一步
#'    恰恰是在渲染路上调的。
dsapp_arun_get <- function(sid, cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(as.character(sid))) return(NULL)
  row <- tryCatch(
    DBI::dbGetQuery(dsapp_db(cfg),
      "SELECT session_id, user_id, target_json, max_iter, state, note,
              task_id, started_at, updated_at
         FROM agent_runs WHERE session_id = ?",
      params = list(as.character(sid))),
    error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(NULL)
  r <- as.list(row[1, , drop = FALSE])
  r$blob <- tryCatch(
    jsonlite::fromJSON(r$target_json %||% "", simplifyVector = FALSE),
    error = function(e) list())
  r
}

#' 某一条后台运行还在跑吗
dsapp_arun_running <- function(sid, cfg = dsapp_config()) {
  r <- dsapp_arun_get(sid, cfg)
  !is.null(r) && identical(as.character(r$state %||% ""), "running")
}

#' 请后台停下来（用户按「停止」时调）
#'
#' ⚠️ 只**改状态**，不杀进程。子进程每一轮开头都会读一次这张表，看到不是
#'    "running" 就自己收尾 —— 收尾包括把当前任务停掉、往对话里留一句说明。
#'    直接 kill 的话，正在跑的那个任务会变成孤儿（它是**另一个** callr 进程，
#'    不在这个子进程的进程组里），而且对话里不会留下任何痕迹。
dsapp_arun_stop <- function(sid, reason = "用户点了停止", cfg = dsapp_config()) {
  dsapp_arun_update(sid, state = "stopped", note = reason, cfg = cfg)
}

#' 收尾时销掉**自己那条**登记
#'
#' ⚠️ 为什么要判 mode：这条记录可能已经跑了几十分钟。这中间用户完全可能
#'    回到页面、又关一次页面、这次选了**另一档** —— 库里那一行已经被
#'    ON CONFLICT 改写成新那条记录了（agent_runs 上 session_id 是 UNIQUE，
#'    一个对话同时只能有一条）。旧的收尾者要是闭着眼睛 update，就会把
#'    **正在跑的**那条标成 done：横幅消失，而新进程还在后台烧 token，
#'    用户再也没有地方停它。
#'
#'    mode 就是"这条记录归谁"的凭据。不相等 = 已经被顶掉了，闭嘴退出。
#'
#' ⚠️ 判据**故意不包含 state**：用户点「停止」走的正是 dsapp_arun_stop()，
#'    它当场把 state 改成 'stopped'；随后循环收尾时 state 已经不是 running
#'    了，但它仍然是这条记录的主人，必须能把自己的收尾说明写进去。
#'
#'    读一次再判、然后再写，中间有个毫秒级的窗口。这里接受它：要撞上得
#'    同一个对话在几毫秒内被关两次、而且两次选的档不一样。
#' @return TRUE/FALSE（销掉没有）
dsapp_arun_finish <- function(sid, state = "done", note = "",
                              mode = "full", clear_task = TRUE,
                              cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(as.character(sid))) return(invisible(FALSE))
  r <- dsapp_arun_get(sid, cfg)
  if (is.null(r)) return(invisible(FALSE))
  if (!identical(as.character(r$blob$mode %||% "full"), mode)) {
    return(invisible(FALSE))
  }
  # 顺手把 task_id 清掉：收尾之后界面上不该再挂着一个早就跑完的任务号。
  # ⚠️ 只在**确认了主人是自己之后**清。分开写成两次 update 的话，第二次
  #    是无条件写，会把顶替进来的那条新记录的 task_id 抹掉 —— 而那条新
  #    记录的任务**正在跑**，横幅上那个任务号正是用户唯一能对上号的线索。
  dsapp_arun_update(sid, state = state, note = note,
                    task_id = if (isTRUE(clear_task)) NA else NULL,
                    cfg = cfg)
}

#' 应用启动时把上次留下的"正在跑"标成孤儿
#'
#' ⚠️ 必须做。子进程是 callr::r_bg(supervise = TRUE) 起来的 —— 它挂在**父
#'    进程**上，父进程被 systemctl restart 掉的时候它跟着一起没了。于是库里
#'    会留下一行永远 running：对话页上一直显示"AI 正在后台继续"，而实际上
#'    什么都没有在跑，用户等一辈子也等不到。
#'
#'    和 db.R 里"应用重启，任务被中断"那次清理是同一类事、同一个理由。
#'    那句判据在那里已经写过一次了，这里不重写。
dsapp_arun_sweep_orphans <- function(cfg = dsapp_config()) {
  tryCatch({
    n <- DBI::dbExecute(dsapp_db(cfg),
      "UPDATE agent_runs SET state = 'orphan',
              note = '应用重启了，后台续跑跟着停了（不是跑完了）',
              updated_at = ?
        WHERE state = 'running'",
      params = list(dsapp_now()))
    if (isTRUE(n > 0)) {
      message(sprintf("[dsapp] 清理了 %d 条应用重启遗留的后台续跑记录", n))
    }
    invisible(n)
  }, error = function(e) invisible(0L))
}

# ---- 起一个后台续跑 ---------------------------------------------------------

#' 把当前这一段循环交给一个后台进程接着跑
#'
#' 调用点只有一个：mod_chat.R 的 session$onSessionEnded（预设是「一路跑完」
#' 且循环还活着时才调）。
#'
#' @param sid      对话 id（循环写消息、查上下文都按它）
#' @param user_id  配额、审计、API Key 都要它
#' @param target   本次执行的目标（**快照**，不是引用）：会话没了之后
#'                 `dsapp_current_target()` 无从调起
#' @param max_iter 轮数上限（用户拖的那个滑块）
#' @param wall_limit ★ V13.17 item 31：自动结束时间（秒），用户拖的**另一个**
#'                 滑块。和 max_iter 成对 —— 后台这条路上没有界面，
#'                 这两个数只能靠显式传参，不能靠"读一下 input$"。
#' @param params   采样参数的**快照**：list(temperature, max_tokens, thinking,
#'                 reasoning_effort, vendor, model, base_url)。
#'                 ⚠️ 必须快照。这几个值是**会话态**（state$temperature 之类），
#'                    库里根本没有——不传的话后台那条路只能用平台默认值，
#'                    于是"挂机跑出来的"和"盯着跑出来的"是两次不同的请求。
#' @param scene    提示词场景，默认 "agent"
#' @param mode     "full"（整个循环接着跑）或 "finish"（只守着当前任务跑完）。
#'                 ⚠️ 只是给界面看的，不影响后台怎么跑 —— 除非将来给 finish
#'                    也走这条循环（现在它走 dsapp_detach_sit，是另一个入口）。
#'                    不记的话，横幅上分不出这两档，只能说一句含糊的
#'                    "正在后台运行"，或者干脆说错。
#' @param resume   接手一个**已经在跑的任务**时的现场，list(task_id, last_key, iter)：
#'                   task_id  —— 引擎槽里那个任务的 id（还没结束的那个）
#'                   last_key —— 循环最后处理过的那条助手消息 id
#'                   iter     —— 已经跑到第几轮
#'                 ⚠️ 不传这三个的话，后台那条路会**重跑一遍**刚才那段代码：
#'                    它从对话历史里重新挑最后一个代码块，而那个块的执行结果
#'                    还没写进对话（正在跑），于是看起来就是一个"从没执行过"
#'                    的块。用户回来会发现同一个分析跑了两遍、写了两套产物。
#' @return TRUE/FALSE（起没起来）。**不抛异常**：它是在会话收尾的路上调的，
#'         那里抛出去没有任何人能接。
dsapp_detach_start <- function(sid, user_id = NULL, target = NULL,
                               max_iter = DSAPP_AGENT_MAX_ITER,
                               wall_limit = DSAPP_AGENT_WALL_DEF,
                               params = NULL, scene = "agent",
                               resume = NULL, mode = "full",
                               # ★ Test_V15.2：这次后台循环**是谁发起的**。
                               #   "detach"（默认）= 用户关页面时交接过来的
                               #   "schedule"      = 定时订阅到点自动跑的
                               #
                               # ⚠️ 存在的唯一理由是**文案不能撒谎**。定时任务
                               #    从头到尾没有过页面，而 worker 往对话里写的是
                               #   「页面关闭了，但你在设置里选了「一路跑完」」——
                               #    用户回来看到这句话会去翻自己的设置，找一个
                               #    他从来没做过的选择。两边都"没错"，错的是它们
                               #    共用了同一句话。
                               origin = "detach",
                               cfg = dsapp_config()) {
  args <- .dsapp_detach_begin(sid, user_id = user_id, target = target,
                              max_iter = max_iter, wall_limit = wall_limit,
                              params = params, scene = scene, resume = resume,
                              mode = mode, origin = origin, cfg = cfg)
  # NULL = 闸门挡住（已经有循环在跑 / sid 是空）。和原来一样：不起进程，
  # 也**不**留下任何登记。
  if (is.null(args)) return(invisible(FALSE))

  ok <- tryCatch({
    callr::r_bg(
      func = .dsapp_agent_worker,
      args = args,
      stdout = file.path(cfg$logs_dir, sprintf("detach-%s.out", args$sid)),
      stderr = file.path(cfg$logs_dir, sprintf("detach-%s.err", args$sid)),
      supervise = TRUE)
    TRUE
  }, error = function(e) {
    dsapp_arun_update(args$sid, state = "orphan",
                      note = paste0("后台进程没能起来：", conditionMessage(e)),
                      cfg = cfg)
    FALSE
  })
  invisible(ok)
}

#' 后台循环的"前一半"：登记 + 把 worker 要的参数拼好
#'
#' ★★ Test_V17.2 item 4 拆出来的。原来这一半和"起进程"是**焊在一起**的，
#'    而挂机自动接手那条路要的是前一半加**另一样东西**：
#'
#'    守护进程（.dsapp_task_sitter_worker）里**不能**再起一个 callr 子进程。
#'    实测（2026-10-08）：callr 的子进程再 `r_bg()` 一个孙进程，**中间那个
#'    进程一退出，孙进程就跟着没了**，跟孙进程自己的 `supervise = FALSE`
#'    一点关系都没有 ——
#'      · 中间进程活着（`Sys.sleep(20)`）→ 孙进程正常写完文件；
#'      · 中间进程一 `return()` → 孙进程当场消失，连一行 stderr 都不留。
#'    而守护进程干完活就**必须**退出。于是那条路上"起一个新进程接着跑"这个
#'    动作**根本不可能成功** —— 症状是 agent_runs 里那一行永远停在 running、
#'    对话里一个字都不多、日志里只有一句"已接手"。（第一版就是这么写的，
#'    测试 B 节当场红了。）
#'
#'    所以守护进程走的是"**自己变成**那段循环"：它已经把 R/ 全 source 过了，
#'    调 `.dsapp_agent_worker()` 就是把那段循环在这个进程里跑一遍。
#'    前一半（登记 + 拼参数）两边**共用这一份** —— 各写一份的话，
#'    "盯着跑"和"挂机跑"的参数迟早不一样，而那种分叉没人看得出来。
#'
#' @return 参数列表（喂给 .dsapp_agent_worker），或者 NULL（这一对话已经有
#'         循环在跑了 / sid 是空的）。**不抛异常。**
.dsapp_detach_begin <- function(sid, user_id = NULL, target = NULL,
                                max_iter = DSAPP_AGENT_MAX_ITER,
                                wall_limit = DSAPP_AGENT_WALL_DEF,
                                params = NULL, scene = "agent",
                                resume = NULL, mode = "full",
                                origin = "detach", cfg = dsapp_config()) {
  if (is.null(sid) || !nzchar(as.character(sid))) return(NULL)
  sid <- as.character(sid)

  # 同一对话只允许一条。已经有一条在跑就别再起 —— 两条会各自往同一条对话里
  # 写消息、各自提交任务，用户回来看到两份交错的分析过程。
  if (dsapp_arun_running(sid, cfg)) return(NULL)

  dsapp_arun_begin(sid, user_id = user_id, target = target,
                   max_iter = max_iter, wall_limit = wall_limit,
                   params = params, mode = mode, cfg = cfg)

  list(app_dir = cfg$app_dir, sid = sid,
       user_id = as.integer(user_id %||% NA),
       resume = resume,
       # ⚠️ 这两个数是**逐个显式传**的，不能省（callr 的 args 是一份干净的
       #    列表，worker 里引用不到外部的任何对象）。
       #    漏传 wall_limit 的话，用户选了 8 小时关的页面，后台按默认 2 小时
       #    跑 —— 而对话里那句"已达自动结束时间（2 小时）"看起来完全正常，
       #    只是和他选的不一样。
       # ★ V16.3 item 4：**不能**写 as.integer(max_iter) ——
       #   as.integer(Inf) 是 NA，而 NA 到了 worker 里会被 dsapp_iter_value()
       #   兜回 6 轮：用户勾了"不设上限"、关掉页面让它自己跑，6 轮就停了，
       #   界面上看不出任何异常。
       target = target, max_iter = dsapp_iter_store(max_iter),
       wall_limit = dsapp_wall_value(wall_limit),
       params = params, scene = scene,
       # ⚠️ 和上面两个数同理：漏传的话 worker 拿到默认的 "detach"，
       #    于是一次定时任务会在对话里写「页面关闭了」——**不报错**，
       #    只是那句话是假的。
       origin = origin,
       # 子进程不许自己推导数据目录，用父进程这份。
       # 理由和 jobs.R 的 .dsapp_job_worker 里那段一字不差：
       # 子进程启动时会读 <应用目录>/.Renviron，那里的值会**盖掉**
       # 继承来的同名环境变量。
       data_root = cfg$data_root)
}

# ---- 只管"当前这个任务跑完"（预设中间那一档）-------------------------------

#' 看着一个正在跑的任务，把它跑完、收尾、结果写回对话
#'
#' ★ 预设「让当前任务跑完」就是它。和上面那个完整循环的**区别**：
#'   它不叫模型、不往下推轮次 —— 只是替用户守着这一次执行。
#'
#' 为什么这一档值得单开（而不是"要么全停、要么全跑"）：
#'   用户合上电脑的时候，正在跑的那个任务往往已经烧了二十分钟机时。
#'   停掉它 = 那二十分钟白烧，而且**结果一个字都不落**（结果只有收尾那一步
#'   才写进对话）。只守着它跑完，代价是有界的（一个任务），拿到的是他本来
#'   就该拿到的那份结果 —— 这是"安全"和"有用"之间那条线。
#'
#' ⚠️ 为什么必须有**进程**在这守着，不能靠"用户回来时自己会补上"：
#'   会话里那个轮询 observer（app.R 的引擎）是**每个会话一份**的，页面一关
#'   就没了。结果文件躺在 run/ 里、库里的任务行永远停在 running，而没有任何
#'   人会去读它 —— 直到用户下次登录（可能是明天），而这中间应用只要重启
#'   一次，run/ 就被清干净了，那份结果**永久消失**。
#'
#' @param target,params,max_iter,wall_limit ★ Test_V17.2 item 4：给**接手**
#'   准备的现场快照。原来这一档用不到它们（它只守着任务，不叫模型），
#'   现在用得着了 —— 任务失败时它会再起一个完整循环让模型自己修
#'   （见 .dsapp_autofix_takeover）。不传的话，挂机时 AI 自己修的那一次
#'   用的是平台默认的温度/上限/轮数/墙钟，和用户盯着它修的那一次**不是
#'   同一个请求**，而他完全无从察觉。默认值全 NULL = 老行为（平台默认）。
#'
#' @return TRUE/FALSE（起没起来）。和 dsapp_detach_start 一样，不抛。
dsapp_detach_sit <- function(task_id, sid, user_id = NULL, target = NULL,
                             params = NULL, max_iter = NULL,
                             wall_limit = NULL,
                             cfg = dsapp_config()) {
  if (is.null(task_id) || is.na(suppressWarnings(as.integer(task_id)))) {
    return(invisible(FALSE))
  }
  # ⚠️ 起进程**之前**先登记。反过来的话，用户在这几十毫秒里刷新页面，
  #    横幅不会出现 —— 而那一刻恰恰是他最想确认"到底有没有在跑"的时候。
  #    登记了但进程没起来，下面那个 error 分支会把状态改回 orphan，
  #    不至于在库里留一条永远 running 的假记录。
  dsapp_arun_begin(sid, user_id = user_id, target = NULL,
                   max_iter = NA_integer_, params = NULL,
                   mode = "finish", cfg = cfg)

  ok <- tryCatch({
    callr::r_bg(
      func = .dsapp_task_sitter_worker,
      args = list(app_dir = cfg$app_dir,
                  task_id = as.integer(task_id),
                  sid = if (is.null(sid)) NA_character_ else as.character(sid),
                  # ★ Test_V17.2 item 4：这几个是给"任务挂了之后自动接手"
                  #   用的现场快照（见 .dsapp_autofix_takeover）。
                  #   ⚠️ 和 dsapp_detach_start 里那两行同一个道理，**必须逐个
                  #      显式传**：callr 的 args 是一份干净的列表，worker 里
                  #      引用不到外面的任何对象。而 max_iter 更要当心 ——
                  #      转成 as.integer 的话 Inf（"不设上限"）会变成 NA，
                  #      worker 里再被兜回 6 轮，用户勾的"不设上限"就不作数了。
                  user_id = as.integer(user_id %||% NA),
                  target = target, params = params,
                  max_iter = dsapp_iter_store(max_iter %||% DSAPP_AGENT_MAX_ITER),
                  wall_limit = dsapp_wall_value(wall_limit %||% DSAPP_AGENT_WALL_DEF),
                  data_root = cfg$data_root),
      stdout = file.path(cfg$logs_dir, sprintf("sitter-%s.out", task_id)),
      stderr = file.path(cfg$logs_dir, sprintf("sitter-%s.err", task_id)),
      supervise = TRUE)
    TRUE
  }, error = function(e) {
    message("[dsapp] 守护进程没能起来：", conditionMessage(e))
    if (!is.null(sid)) try(dsapp_arun_update(
      sid, state = "orphan",
      note = paste0("守护进程没能起来：", conditionMessage(e)), cfg = cfg),
      silent = TRUE)
    FALSE
  })
  invisible(ok)
}

# ---- 子进程入口 -------------------------------------------------------------

#' 轮询一个**不属于自己**的任务（接手来的）
#'
#' 和 `dsapp_job_poll()` 的唯一区别：它判"还活着吗"靠 `handle$proc$is_alive()`，
#' 而接手来的句柄里 `proc` 是 NULL（那个 callr 进程是**父进程**起的，句柄没
#' 跟着传过来，也传不过来 —— 一个 callr 进程对象没法跨进程序列化）。
#'
#' 于是 `dsapp_job_poll()` 会得出 `alive = FALSE` → `done = TRUE`、
#' `result = NULL`，而调用方（dsapp_task_closeout）把"done 了但没结果"
#' 解释成**执行进程意外退出** —— 一个好好在跑的任务会被当场标成失败。
#'
#' 这里换成"问库"：任务行只要还是 `running`，就说明它还在跑。
#'
#' @return 和 dsapp_job_poll() 同一个形状：list(done, alive, result)
.dsapp_detach_poll <- function(h, cfg) {
  if (!is.null(h$result_file) && file.exists(h$result_file)) {
    res <- tryCatch(
      jsonlite::fromJSON(readLines(h$result_file, warn = FALSE),
                         simplifyVector = FALSE),
      error = function(e) NULL)
    # ⚠️ 文件在但读不出来 = 子进程正写到一半，**不是**结束。落到下面接着等。
    if (!is.null(res)) return(list(done = TRUE, alive = FALSE, result = res))
  }

  st <- tryCatch({
    row <- db_task_get(h$task_id, con = dsapp_db(cfg))
    if (is.null(row)) NA_character_ else as.character(row$status %||% NA)
  }, error = function(e) NA_character_)

  # 不在了 / 已经不是 running（被应用重启的清理标成"中断"、被用户从任务页
  # 删掉、被别处收尾）→ 结束，但**没有结果**。调用方会据此写一条"意外退出"。
  # 这是对的：那个结果确实拿不到了（跑它的进程已经随着父进程一起没了）。
  if (is.na(st) || !identical(st, "running")) {
    return(list(done = TRUE, alive = FALSE, result = NULL))
  }
  list(done = FALSE, alive = TRUE, result = NULL)
}

#' 脱离会话的 agent 循环（跑在一个全新的 R 进程里）
#'
#' ⚠️ 这个函数会被**序列化后送到另一个 R 进程**执行。它不能引用本文件里
#'    外面的任何对象，所有依赖都要靠参数带进来 —— 和 jobs.R 的
#'    .dsapp_job_worker 是同一条规矩。
.dsapp_agent_worker <- function(app_dir, sid, user_id, target, max_iter,
                                wall_limit = NULL,
                                params, scene, resume = NULL,
                                origin = "detach",
                                data_root = NULL) {
  # 数据目录跟着**父进程**，不跟着 .Renviron 重新推导。
  # ⚠️ 必须在任何 dsapp_config() 之前跑，理由见 jobs.R 里同一位置的注释。
  if (!is.null(data_root) && nzchar(as.character(data_root)[1])) {
    Sys.setenv(DSAPP_DATA_ROOT = as.character(data_root)[1])
  }

  for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
    if (grepl("^mod_", basename(f))) next     # UI 模块，子进程用不到
    source(f, local = globalenv())
  }

  cfg <- dsapp_config()
  say <- function(...) message(sprintf("[detach %s] ", sid), ...)

  note <- function(txt) {
    tryCatch(dsapp_arun_update(sid, note = txt, cfg = cfg),
             error = function(e) NULL)
  }
  finish <- function(state, txt) {
    # 走 dsapp_arun_finish 而不是裸 update：这条记录可能已经被顶掉了
    # （用户又关了一次页面、这次选的是「让当前任务跑完」）。见那个函数的
    # 说明 —— 闭着眼睛写会把**新那条**标成 done，横幅消失而进程还在跑。
    tryCatch(dsapp_arun_finish(sid, state = state, note = txt,
                               mode = "full", cfg = cfg),
             error = function(e) NULL)
  }

  # ---- 采样参数：缺什么补什么 ---------------------------------------------
  #
  # ⚠️ 这里**不能**退回 cfg$llm$xxx 那套平台默认就完事。会话里那几个值
  #    （温度、长度上限、思考开关）是**滑块**，库里不存，所以快照没带过来的
  #    时候，用平台默认是唯一的选择 —— 但要**如实记一笔**，让用户回来时
  #    能看出"这一次和平时不一样"，而不是自己纳闷结果为什么差一截。
  p <- params %||% list()
  temperature <- suppressWarnings(as.numeric(p$temperature %||% 0.3))
  if (is.na(temperature)) temperature <- 0.3
  # ★★ V15.5 item 6：快照里带的是**单次使用上限**（state$ctx_limit），不是
  #   max_tokens —— 回复上限现在是从它推出来的（见下面的 ctx_plan）。
  #
  #   ⚠️ `p$max_tokens` 那半截是给**旧快照**兜的：后台进程是 callr 起的，
  #      用户在旧代码上发起、进程在热更新后才被读到这种事没法完全排除。
  #      旧语义里 65536 是"回复上限"，新语义里它当"单次使用上限"用是**安全**
  #      的方向（更紧），反过来才是危险的。读到旧键就按旧的默认值理解。
  if (!is.null(p$ctx_limit)) {
    ctx_limit <- suppressWarnings(as.numeric(p$ctx_limit)[1])
  } else {
    ctx_limit <- suppressWarnings(as.numeric(p$max_tokens %||% NA_real_)[1])
  }
  # 0 = 跟随模型（原 V13.14 item 22 的"不设上限"哨兵，含义换了但值没换），
  # **必须原样留着**：dsapp_ctx_is_follow() 认它。
  # ⚠️ 负数和 NA 才是真的坏了。原来那条 `max_tokens < 512L → 65536L` 会把 0
  #    悄悄换成一个真实上限 —— 那是"用户走开一下结果就变了"的老 bug。
  if (!is.finite(ctx_limit) || ctx_limit < 0) ctx_limit <- DSAPP_CTX_FOLLOW
  thinking <- p$thinking
  reasoning_effort <- p$reasoning_effort
  vendor <- p$vendor
  model <- p$model
  base_url <- p$base_url

  # ---- 走哪一家：快照缺哪一项，就用这个账号在设置里存的补哪一项 -----------
  #
  # ⚠️ 这三行不是"以防万一"。`dsapp_api_key_effective()` 在 vendor 是空串时
  #    **直接返回 ""**（它的第一行就 return），而快照里 vendor 是可能缺的：
  #    params 是调用方拼的，少传一个键就是 NULL。少了这三行，症状是**每一次**
  #    挂机续跑都在第一秒里停掉，还留一句"这个账号没有可用的 API Key"——
  #    用户明明配着 Key，只会以为是自己账号的问题。
  #    base_url/model 同理：留着 NULL 会掉进 .dsapp_llm_once 的平台默认值，
  #    也就是"拿默认那家的地址，去发另一家的模型名"。
  if (is.na(user_id)) {
    finish("orphan", "这个对话没有归属账号，后台续跑没法确定用哪把 API Key。")
    return(invisible(FALSE))
  }
  s <- tryCatch(dsapp_settings_get(user_id, con = dsapp_db(cfg)),
                error = function(e) list())
  if (!nzchar(as.character(vendor   %||% "")[1])) vendor   <- s$vendor
  if (!nzchar(as.character(base_url %||% "")[1])) base_url <- s$base_url
  if (!nzchar(as.character(model    %||% "")[1])) model    <- s$model

  # 和对话页的 api_key_now() 是**同一套优先级**（见 R/users.R 里
  # dsapp_api_key_effective 的说明）：钥匙串里这一家的 > users.llm_api_key。
  # 区别只有一个 —— 那边最后兜的是 state$api_key，这里没有 state，兜
  # 设置里那一列。两边要是不一致，就会出现"盯着跑能跑、挂机跑说没 Key"。
  api_key <- tryCatch(dsapp_api_key_effective(user_id, vendor,
                                              con = dsapp_db(cfg)),
                      error = function(e) "")
  if (!nzchar(api_key)) api_key <- s$api_key %||% ""
  if (!nzchar(api_key)) {
    finish("orphan", "这个账号没有可用的 API Key，后台续跑没有开始。")
    return(invisible(FALSE))
  }

  # ---- 引擎垫片：接口和 app.R 里那个一模一样，但槽位是**这个进程自己的** --
  e <- new.env(parent = emptyenv())
  e$handle <- NULL
  e$current_task_id <- function() if (is.null(e$handle)) NULL else e$handle$task_id
  #' 提交。返回 list(ok, msg, task_id)，和真引擎同一个约定 ——
  #' agent.R 的 a$try_submit() 靠 `grepl("正在执行", res$msg)` 认出"忙"，
  #' 所以这句措辞**不能改**（改了两边都变哑巴，而且不报错）。
  e$start <- function(code, lang, title = NULL, session_id = NA_character_,
                      target = list(kind = "server", env = "system"),
                      user_id = NULL) {
    if (!is.null(e$handle)) {
      return(list(ok = FALSE, msg = "已有任务正在执行，请等它结束"))
    }
    # 跨进程的那道补丁。查库（主进程的 e$busy 在这里看不见）。
    if (dsapp_task_slot_busy(cfg)) {
      return(list(ok = FALSE, msg = "已有任务正在执行，请等它结束"))
    }
    sub <- dsapp_task_submit(code, lang, title = title, session_id = session_id,
                             target = target, user_id = user_id, cfg = cfg)
    if (!isTRUE(sub$ok)) return(list(ok = FALSE, msg = sub$msg))
    e$handle <- sub$handle
    note(sprintf("任务 #%d 执行中", sub$task_id))
    tryCatch(dsapp_arun_update(sid, task_id = sub$task_id, cfg = cfg),
             error = function(x) NULL)
    list(ok = TRUE, msg = "", task_id = sub$task_id)
  }
  #' 轮询 + 收尾。和 app.R 的 e$poll() 一样是**一次性终结器**：收完就置空。
  #'   区别只有一个：状态复位不存在（这里没有界面），写库失败就抛出去 ——
  #'   调用方是下面那个 while，它接得住。
  e$poll <- function() {
    if (is.null(e$handle)) return(NULL)
    h <- e$handle
    # ⚠️ `detached = TRUE` 的句柄（接手一个**已经在跑**的任务）不能用
    #    dsapp_job_poll()：它判"还活着吗"靠的是 `handle$proc$is_alive()`，
    #    而这个进程里 proc 是 NULL（那个 callr 进程属于**父进程**）。
    #    于是它会得出 alive = FALSE → done = TRUE → result = NULL，
    #    而 closeout 把 result = NULL 解释成"执行进程意外退出"——
    #    明明是好好在跑的任务，会被当场标记成失败。见 .dsapp_detach_poll。
    res <- tryCatch(
      if (isTRUE(h$detached)) .dsapp_detach_poll(h, cfg)
      else dsapp_job_poll(h),
      error = function(err) list(done = TRUE, alive = FALSE, result = NULL))
    if (!isTRUE(res$done)) return(NULL)
    e$handle <- NULL
    tryCatch(dsapp_arun_update(sid, task_id = NA, cfg = cfg),
             error = function(x) NULL)
    dsapp_task_closeout(h$task_id, res$result, cfg = cfg)
  }

  # ---- hooks：全部去掉界面那一半 ------------------------------------------
  #
  # ⚠️ `begin_llm` **不能**在这里直接调模型。理由：会话那条路上它是**异步**
  #    的（起个流式子进程就返回），所以 a$on_llm_done() 总是在 begin_llm
  #    返回之后才跑。这里要是同步调完再回调 on_llm_done，就变成
  #    on_llm_done → begin_llm → on_llm_done → … 一层层递归下去，几轮就把
  #    栈吃掉了，而且 wall_limit 那道理根本没机会生效。
  #    所以这里只**举个手**，真正的调用在下面 while 里，扁平地转。
  want_llm <- new.env(parent = emptyenv())
  want_llm$on <- FALSE

  hooks <- list(
    get_sid    = function() sid,
    get_target = function() target,
    begin_llm  = function(scene) {
      want_llm$on <- TRUE
      note("正在等模型给出下一步…")
      invisible(TRUE)
    },
    # 后台没有"界面正忙"这回事。恒 FALSE —— agent.R 用它只是决定状态条上
    # 显示哪句话（见 a$tick 的 generating 分支）。
    running    = function() FALSE,
    add_msg    = function(role, txt) {
      tryCatch({
        db_message_add(sid, role, txt, con = dsapp_db(cfg))
        invisible(TRUE)
      }, error = function(e) {
        # ⚠️ 写不进去**不抛**：抛出去会把整个循环带走，而这条消息多半只是
        #    语境（一条平台提示）。真正的结果写不进去会在下一轮暴露成
        #    "模型看不见上一次执行的结果"，那时还有救。
        say("写消息失败：", conditionMessage(e))
        invisible(NULL)
      })
    },
    refresh    = function() invisible(TRUE)
  )

  stt <- list(user_id = if (is.na(user_id)) NULL else user_id)

  a <- dsapp_agent_new(stt, e, session = NULL, ns = NULL, cfg = cfg, hooks,
                       max_iter = max_iter,
                       # ★ V13.17 item 31：自动结束时间。走到这儿 source() 已经
                       #   跑过了，dsapp_wall_value() 在（默认值 NULL → 平台默认，
                       #   和父进程漏传时的行为一致）。
                       wall_limit = wall_limit,
                       # ⚠️ 没有会话，注册不了心跳 —— 循环由下面那个 while 推。
                       heart = FALSE)

  # ---- 收尾时把"为什么停的"写进对话 ---------------------------------------
  #
  # ⚠️ 这一段是**给用户看的**，而且是他回来之后唯一的交代。少了它，用户看到
  #    的是"我关了个页面，然后对话里凭空多出来几轮，最后停在半路"。
  opened <- tryCatch(db_message_add(sid, "tool", paste0(
    "【平台提示】\n",
    if (identical(as.character(origin %||% "")[1], "schedule"))
      "这次是定时订阅到点自动发起的检索，没有任何人在看着这个对话。\
它会在后台把这一轮跑完，结果照样会写进这条对话，跑完还会发一封邮件到你的邮箱。"
    else if (identical(as.character(origin %||% "")[1], "autofix"))
      # ★ Test_V17.2 item 4：挂机时任务挂了，平台的「出错自动修」自己接手起的
      #   这一段。⚠️ 这句话**不能**和下面那句共用 —— 那是三件不同的事：
      #   定时任务（没人开过页面）、用户选了「一路跑完」（整段循环接着跑）、
      #   用户选了「让当前任务跑完」而那个任务**失败了**（只有守护进程在，
      #   现在由平台接手修）。写成同一句的话，用户会去翻自己的设置找一个
      #   他从来没做过的选择。origin 这个参数存在的全部理由就是这个。
      "刚才那个任务没有跑通。你关页面时选的是「让当前任务跑完」，\
所以守着它的是后台的守护进程 —— 它把结果写回来了，但它不会把 AI 叫起来。\
那件事由平台的「出错自动修」接手了：接下来这一段是 AI 自己在读那条报错、\
改代码、重跑，不需要你确认。"
    else
      "页面关闭了，但你在设置里选了「一路跑完」，\
所以这一段自动执行交给后台继续了。你可以关掉这个页面，结果照样会写进这条对话。")),
    error = function(e) NULL)

  # 起手：把循环从 idle 叫起来跑第一轮。
  #
  # ⚠️ 置的是 **enabled**，不是 armed。can_loop() 是两个取"或"，
  #    看起来随便哪个都行 —— 但 armed 会在 a$on_llm_done() 里被**清掉**
  #    （agent.R 里那行 `a$armed <- FALSE`，配的注释是"走到这一支 = 用户新开
  #    了一轮，自动接手不能跨用户请求继承"）。那是给会话里写的：那边每一轮
  #    都由用户的新消息重新授权一次。
  #
  #    后台这条路没有"用户新开一轮"这回事，只有一条连续往下跑的循环。用 armed
  #    的话，第一轮进门时它就被清成 FALSE 了，第二轮进 can_loop() 直接被挡回
  #    来 —— 而挡回来**不改变 a$state**，于是 while 会一圈圈空转下去：
  #    生成、丢弃、生成、丢弃，界面看着像死了，日志上什么都没报。踩过这个
  #    形状的坑（本仓库的 reactiveVal 自失效那次）。
  #
  #    enabled 的语义正好就是这里要的（agent.R 里它自己的注释：
  #    "每一轮都自动往下跑"），而且没有任何地方会清它。
  a$enabled <- TRUE
  a$max_iter <- dsapp_iter_value(max_iter)
  # ★ V13.17 item 31：和上面一样，参数已经逐个传进来了，这里再显式落一次 ——
  #   构造函数里也设过，但这一处是"后台这份循环到底按什么跑"的**唯一记录点**，
  #   两个数并排写在一起，将来加第三个闸的时候不会漏掉一半。
  a$wall_limit <- dsapp_wall_value(wall_limit)
  a$t0 <- Sys.time()
  a$sid <- sid

  # ---- 接手一个正在跑的任务（resume）--------------------------------------
  #
  # 用户关页面的时候，循环**大多数时间**不在生成，而是在等一个任务跑完
  # （分析动辄几分钟到几小时，一轮生成只有几秒）。所以这一支才是常态，
  # 不是边角情况 —— 不处理它的话，"一路跑完"这个选项基本等于没用。
  #
  # 三件事必须一起做，少一件都会出事：
  #
  #   1. `e$handle` 指向那个任务，`a$state <- "waiting"`：让 a$tick() 走
  #      check_task 那条支，而不是从 idle 重新起一轮。
  #      ⚠️ 句柄要打 `detached = TRUE` —— 那个 callr 进程属于**父进程**，
  #         这里没有它的 proc（见 e$poll 里那段）。不打的话会被当场判死。
  #
  #   2. **认领 last_key**：认领登记表是每个进程一份的，这个新进程里它空的。
  #      不认领的话，万一走到 on_llm_done（比如任务刚结束、历史里那个块还
  #      没配结果），它会重新挑中**同一个块**再执行一遍 —— 同一个分析跑两遍、
  #      写两套产物。用户的原话里最不能接受的就是这个。
  #
  #   3. 轮次接着数：`a$iter <- resume$iter`。从 0 重数的话 max_iter 那个
  #      上限会在后台被**重新发放一遍**，用户设的"最多跑 N 轮"就不作数了。
  rs <- resume %||% NULL
  if (!is.null(rs) && !is.null(rs$task_id) &&
      !is.na(suppressWarnings(as.integer(rs$task_id)))) {
    tid0 <- as.integer(rs$task_id)
    e$handle <- list(
      proc = NULL, detached = TRUE, task_id = tid0,
      result_file = file.path(cfg$run_dir, paste0("job-", tid0, ".json")))
    a$task_id <- tid0
    a$state   <- "waiting"
    a$iter    <- as.integer(rs$iter %||% 0L)
    a$note    <- sprintf("任务 #%d 执行中（接手自关闭的页面）", tid0)
    if (!is.null(rs$last_key) && !is.na(suppressWarnings(as.integer(rs$last_key)))) {
      dsapp_agent_claim(as.integer(rs$last_key))
      a$last_key <- as.integer(rs$last_key)
    }
    note(a$note)
    say("接手任务 #", tid0, "，轮次从 ", a$iter, " 接着数")
  } else {
    # 没有在跑的任务 → 按会话里的老规矩，先让模型说下一步。
    hooks$begin_llm(scene)
  }

  # ---- 主循环 --------------------------------------------------------------
  #
  # 扁的：推一次心跳 → 有举手就同步生成一轮 → 再推。没有递归。
  #
  # ⚠️ 每一轮都要读一次 agent_runs 的 state：用户回来点了「停止」，或者
  #    另一条路径把它标成 orphan，这里就得收手。**不能只看内存**，因为
  #    那个"停止"是**另一个进程**写进去的。
  reason <- "循环结束"
  hard_stop <- FALSE
  # 停下来的原因分三类，因为**用户回来该做的事完全不同**：
  #   done    —— 正常跑完，不用管
  #   blocked —— 卡在"等你点确认"上，你要去点一下
  #   stopped —— 是你自己（或重启）把它停掉的
  # 合成一个 done 的话，blocked 那一类会被当成"跑完了"，而对话里那个
  # 确认按钮才是用户唯一该做的事 —— 他会以为活干完了，直接走人。
  blocked <- FALSE
  repeat {
    st <- tryCatch(dsapp_arun_get(sid, cfg), error = function(x) NULL)
    if (is.null(st) || !identical(as.character(st$state %||% ""), "running")) {
      reason <- "用户把后台续跑停掉了"
      hard_stop <- TRUE
      break
    }

    # ★ 收尾：会话里这一步是 app.R 那个引擎观察器每秒做一次的，**这里没有
    #   会话，得自己做** —— 而且非做不可。
    #
    #   a$check_task() 判"任务结束没有"读的是 **tasks 表的 status**，而那一行
    #   只有 dsapp_task_closeout() 会写；closeout 又只有 e$poll() 会调。
    #   漏掉这一句的表现是最难查的一种：任务早就跑完了、结果文件躺在 run/
    #   里，而循环停在 waiting 上一动不动 —— 不报错、不退出、不写任何东西，
    #   日志上只有心跳。用户回来看到的是"AI 卡住了"。
    #
    # ⚠️ 放在 want_llm 判断**之前**：任务结束那一轮要先把库里的状态落定，
    #    紧接着的 a$tick() → check_task() 才看得见它。顺序反过来会白等一轮
    #    （不影响正确性，只是慢半秒，但没必要）。
    tryCatch(e$poll(), error = function(x) say("收尾失败：", conditionMessage(x)))

    if (isTRUE(want_llm$on)) {
      want_llm$on <- FALSE
      msgs <- tryCatch(
        dsapp_scene_messages(sid, scene, cfg,
                             target = target,
                             user_id = stt$user_id,
                             max_iter = max_iter,
                             # ★ V13.17 item 31：自动结束时间也要跟过来。
                             #   漏了的话，模型在后台拿到的提示词里那个时长
                             #   和它实际会被掐断的时刻**不是同一个数** ——
                             #   会话里跟到后台，前后两个阶段说的不是一回事。
                             wall_limit = a$wall_limit,
                             vendor = vendor, model = model,
                             # ★ V15.5 item 6：单次使用上限跟着过来，
                             #   否则后台那条路的历史预算退回保守默认，
                             #   和"盯着跑"带进去的不是同一份上下文。
                             ctx_limit = ctx_limit),
        error = function(x) x)
      if (inherits(msgs, "error")) {
        reason <- paste0("拼上下文失败：", conditionMessage(msgs))
        break
      }

      # ★ V15.5 item 6：回复上限和会话里一样，是**算出来的** ——
      #   总上限减掉这一轮真正带进去的上下文。两条路（盯着跑 / 挂机跑）
      #   必须调同一个 dsapp_ctx_plan()，各算各的迟早会分叉，而分叉的表现是
      #   "同一个任务，走开一下结果就短了一截"。
      #   ⚠️ max_tokens 原来直接取自快照。现在快照里存的是 ctx_limit，
      #      它推不出回复上限 —— 推出它需要**已经拼好的 messages**。
      plan <- dsapp_ctx_plan(msgs, vendor, model, ctx_limit)
      if (isTRUE(getOption("dsapp.detach.debug"))) {
        say("上下文 ≈", plan$used, " / ", plan$limit,
            " token（", plan$pct, "%），本轮回复额度 ", plan$out)
      }

      # 路径参数和采样参数从**同一份快照**来（见上面 params 那段）。
      res <- tryCatch(
        .dsapp_llm_once(api_key, msgs, model = model, cfg = cfg,
                        max_tokens = plan$out, temperature = temperature,
                        base_url = base_url, thinking = thinking,
                        reasoning_effort = reasoning_effort,
                        # ★ Test_V16.3 item 2：挂机续跑这条路也要走用户填的
                        #   代理。漏了它的表现最难查 —— 用户盯着跑的时候一切
                        #   正常（走的是 mod_chat 那条路，代理是挂上的），
                        #   一离开页面就整段失败，而失败原因是"连不上厂商"。
                        #   stt$user_id 是这次续跑的发起人（见上面 641 行）。
                        proxy = tryCatch(dsapp_proxy_for(stt$user_id),
                                         error = function(e) NULL)),
        error = function(x) x)
      if (inherits(res, "error")) {
        # ⚠️ 生成失败就**停**，不重试。这里没有会话可以重来，无声地重试
        #    只会烧 token；而失败的原因（Key 失效、余额用完、模型名错）
        #    用户回来时看到这一句就能自己判断。
        reason <- paste0("模型调用失败：", conditionMessage(res))
        break
      }

      mid <- tryCatch(db_message_add(sid, "assistant", res$text,
                                     con = dsapp_db(cfg)),
                      error = function(x) NULL)
      cfg_usage <- tryCatch(dsapp_usage_text(res$usage), error = function(x) "")
      if (nzchar(cfg_usage)) note(cfg_usage)

      if (isTRUE(getOption("dsapp.detach.debug"))) {
        say("生成一轮，", nchar(res$text %||% ""), " 字，finish_reason=",
            res$finish_reason %||% "?")
      }

      a$on_llm_done(res$text, finish_reason = res$finish_reason,
                    message_id = mid)
    }

    # 等用户回来确认的那一类：后台没有人可以按确认，只能停下并说清楚。
    #
    # ⚠️ 这里**不能**图省事调 a$deny()。deny 是"用户点了拒绝"那条路 ——
    #    它会 feed_back 一句「用户**拒绝**执行这段代码」把循环继续推下去。
    #    后台根本没有用户，那句话是假的；而且循环会接着跑、接着撞上同一个
    #    确认框，来回烧 token。**也不能**替用户放行：那道闸本来就是为了拦住
    #    "把本地数据发往外部地址"这类代码，让它在没人看着的时候自动过去，
    #    正好废掉了它唯一存在的理由。
    #
    #    正确做法是停下。那条助手消息连同代码块就留在对话里，用户回来自己
    #    看一眼、自己点「执行」—— 认领登记表（dsapp_agent_claims）是**每个
    #    进程一份**，这个进程退出不影响主进程那边重新认领同一条消息。
    if (identical(a$state, "awaiting_user")) {
      dsapp_agent_release(a$pending_mid)
      blocked <- TRUE
      reason <- paste0("有一段代码按规则需要你本人确认才能执行，后台没法替你点，\
所以停在这里了 —— 回到对话页，那条消息下面就有执行按钮。")
      break
    }
    if (!a$active()) {
      reason <- a$note %||% "循环结束"
      break
    }
    Sys.sleep(0.5)
  }

  # ⚠️ 收尾的顺序：先停引擎里那个任务，再写状态。
  #    反过来的话，用户看到"已经停了"而任务还在跑 —— 那个任务会一直占着
  #    槽位，而没有任何人能停它（它的 handle 只活在这个进程的内存里，
  #    而这个进程马上就要退出了）。
  if (hard_stop) {
    tryCatch(e$poll(), error = function(x) NULL)   # 顺手回收一下已经结束的
    tid <- e$current_task_id()
    if (!is.null(tid)) {
      tryCatch(dsapp_job_abort(e$handle), error = function(x) NULL)
      tryCatch(db_task_status(tid, "error", exit_code = NA_integer_,
                              stderr = "后台续跑被停止，任务一并中止",
                              con = dsapp_db(cfg)),
               error = function(x) NULL)
    }
  }

  tryCatch(db_message_add(sid, "tool", paste0(
    "【平台提示】\n",
    if (identical(as.character(origin %||% "")[1], "schedule"))
      "定时检索结束了：" else "后台续跑结束了：",
    reason, "。")), error = function(e) NULL)
  finish(if (hard_stop) "stopped" else if (blocked) "blocked" else "done",
         reason)
  invisible(TRUE)
}

# ---- ★★ Test_V17.2 item 4：挂机时的自动接手 ---------------------------------

#' 任务挂着挂了：再起一个后台循环，让模型自己把它修好
#'
#' 用户原话：
#'   「Biomamba_ceshi账号下的自动纠错似乎没能正常运行，即使是我挂载了
#'    "长任务无人值守编排"的情况下。这类任务100%不需要用户确认，应该能自动
#'    运行才对」—— 他附的就是卡片上那句「这一段没跑通，AI 已经在自动重试了」。
#'
#' ---- 现场（线上，2026-10-08，uid=11）---------------------------------------
#'   对话 s-20261008180139-1174 / 任务 #576，10:23:58 失败：
#'     unused argument (gene = "TCF3")
#'   而 agent_runs 里那一行是 **mode = "finish"** —— 用户关页面时选的是
#'   「让当前任务跑完」。那一档归 .dsapp_task_sitter_worker：守住任务、收尾、
#'   把结果写回对话，然后**退出**。从头到尾没有任何进程把模型叫起来 ——
#'   而卡片上"AI 已经在自动重试了"是**画卡片那一刻**写下的判断
#'   （render.R 的 quiet_fail），挂机这条路上从来没有兑现过它。
#'
#' ---- 为什么不能让会话里那个 observer 顺手补一下 -----------------------------
#'   前台那条路是 mod_chat.R 的 observeEvent(engine$state$running) 调
#'   a$kick_env_fix()，而那是个**会话内的 R6 对象**：页面一关就没了。守护进程
#'   里没有会话、没有循环、也调不到那个方法。它唯一能做的只有一件事 ——
#'   **再起一个后台循环**，让模型自己看那条报错。就是下面这个函数。
#'
#' ---- 为什么不加频率闸 -------------------------------------------------------
#'   这里**不需要**额外的计数闸。守护进程只在"用户关页面的那一刻正好有一个
#'   任务在跑"时被起一次，所以一次挂机最多接手一次（同一个任务不会失败两次）；
#'   接手起来的那个完整循环自带轮数上限和墙钟上限，它内部"改 → 跑 → 又挂"
#'   那个圈由它自己消化 —— agent.R 的滑动窗口管的就是这件事。在这儿再加一层
#'   计数，做出来的只会是"挂机时第三次失败就不理了"这种东西，那正是用户报的
#'   毛病本身。
#'
#' ⚠️ 判据一律**复用**现成的：该不该让 AI 扛（dsapp_env_self_fix）、是不是
#'    被人停掉的（dsapp_err_stopped）、开关读哪一列（uiprefs 的 agent_autofix）。
#'    在这里重写一份的话，分叉出来的表现恰好就是"盯着跑会自己修、挂机跑不会"
#'    —— 一字不差就是用户报的这条。
#'
#' @return list(taken = 起没起来, why = 一句话（给日志/给用户）,
#'              quiet = 卡片上是不是写着"AI 已经在自动重试了"）。不抛异常。
.dsapp_autofix_takeover <- function(task_id, sid, user_id = NULL, target = NULL,
                                    params = NULL, max_iter = NULL,
                                    wall_limit = NULL, cfg = dsapp_config()) {
  no <- function(why, quiet = FALSE) {
    list(taken = FALSE, why = why, quiet = isTRUE(quiet))
  }

  sid <- as.character(sid %||% "")[1]
  if (is.na(sid) || !nzchar(sid)) return(no("这条对话已经被删了"))
  tid <- suppressWarnings(as.integer(task_id))
  if (is.na(tid)) return(no("没有任务号"))

  # 只有**失败**才接手。成功、还在跑、或者任务行已经被删了，都什么都不做。
  row <- tryCatch(db_task_get(tid, con = dsapp_db(cfg)), error = function(e) NULL)
  if (is.null(row) || !nrow(row)) return(no("查不到这条任务"))
  status <- as.character(row$status[1] %||% "")
  if (!nzchar(status) || identical(status, "success")) {
    return(no("这一次没有失败"))
  }
  err <- as.character(row$stderr[1] %||% "")
  env <- tryCatch(dsapp_env_failure(stderr = err, status = status),
                  error = function(e) list(is_env = FALSE))

  # 账号：参数里没带就从对话行上取。⚠️ 必须拿到 —— worker 第一步就是
  # `if (is.na(user_id))`，拿不到它后台循环会在第一秒里停掉，还留一句
  # "这个对话没有归属账号"。
  uid <- suppressWarnings(as.integer(user_id %||% NA))
  if (is.na(uid)) {
    uid <- tryCatch(as.integer(DBI::dbGetQuery(
      dsapp_db(cfg), "SELECT user_id FROM sessions WHERE id = ?",
      params = list(sid))$user_id[1]), error = function(e) NA_integer_)
  }
  if (is.na(uid)) return(no("这个对话没有归属账号"))

  # 「出错自动修」关着就不接手 —— 那是用户自己关掉的。
  # ⚠️ 读的是**账号的偏好**（uiprefs 的 agent_autofix），不是界面上那个勾选框：
  #    挂机时没有会话，input$agent_fix 根本不存在。两边读同一个来源，
  #    才不会出现"界面上勾着、挂机却不修"（或者反过来，更糟）。
  # ⚠️ 读不到偏好（库出错）时**按开处理**：这个开关默认是开的，而"读不出来
  #    就什么都不做"会让一次真实的失败石沉大海。宁可多修一次。
  p <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                error = function(e) list(agent_autofix = TRUE))
  pref_on <- !isFALSE(p$agent_autofix)

  # 卡片上那句"AI 已经在自动重试了"写不写，取决于**同一个**开关加
  # dsapp_env_self_fix —— 见 render.R 的 quiet_fail。这里算出来是为了：
  # 万一没接成手，得有一句话去补上那个承诺（下面 call 站点用它决定要不要
  # 写一条【平台提示】）。承诺过的才需要交代，没承诺过的不用。
  quiet <- pref_on && isTRUE(dsapp_env_self_fix(env))

  if (!pref_on) return(no("你的设置里关掉了「出错自动修」", quiet))
  # 用户自己停掉的任务**不接手**。这条判据和卡片上"这不是待修的 bug"是
  # 同一个（dsapp_err_stopped）—— 用户点了停止，AI 又把它跑起来，那不是
  # 自动纠错，那是跟用户对着干。
  if (dsapp_err_stopped(err)) return(no("这个任务是被人停掉的，不是自己挂的", quiet))

  # 已经有循环在跑就别插队：两条循环会各自往同一条对话里写消息、各自提交任务，
  # 用户回来看到两份交错的分析过程。（.dsapp_detach_begin 里也有一道同样的闸，
  # 这里提前问一次只是为了把原因说清楚。）
  if (dsapp_arun_running(sid, cfg)) return(no("这个对话已经有一个后台循环在跑", quiet))

  # ★★ 这里**不另起进程** —— 守护进程自己就是那段循环。原因见
  #    .dsapp_detach_begin() 头上那段实测记录（callr 的孙进程会被中间进程的
  #    退出带走，而守护进程干完活必须退出）。所以下面这一句是**阻塞**的：
  #    它在守护进程这个进程里把整段 agent 循环跑完（可能几十分钟，直到
  #    wall_limit 或者轮数到顶），跑完才 return。
  # ⚠️ 试过的那版（dsapp_detach_start → callr::r_bg(.dsapp_agent_worker)）在
  #    测试里是 **红的**：库里的行永远停在 running、对话里一个字都不多、
  #    detach-*.out/.err 一个字都没有 —— 因为它一起来就被带走了。
  #    表现和"自动纠错没运行"一模一样，正是用户报的那一条。
  args <- .dsapp_detach_begin(
    sid, user_id = uid, target = target,
    # ⚠️ 和用户关页面那一次用的是**同一份快照**（mod_chat 的 session-end 里
    #    传给 dsapp_detach_sit 的那几个数）。不传的话后台循环会拿到平台默认的
    #    温度/上限/轮数/墙钟，于是"挂机时 AI 自己修的这一次"和"你盯着它修的
    #    那一次"是两次参数不同的请求 —— 而用户完全无从察觉。
    max_iter = max_iter %||% DSAPP_AGENT_MAX_ITER,
    wall_limit = wall_limit %||% DSAPP_AGENT_WALL_DEF,
    params = params, scene = "agent",
    # resume 是 NULL，**故意**的：任务已经结束了（结果都写回对话了），
    # 不存在"还在跑的那个任务"要接手 —— 后台循环该做的是看那条报错，
    # 从头说下一步。
    resume = NULL, mode = "full",
    # 文案：worker 进门那句【平台提示】按 origin 分三支，autofix 是其中一支。
    # 不传的话它会写「你在设置里选了「一路跑完」」—— 用户明明选的是
    # 「让当前任务跑完」，他会去翻自己的设置，找一个他从来没做过的选择。
    origin = "autofix", cfg = cfg)
  if (is.null(args)) return(no("这个对话已经有一个后台循环在跑", quiet))

  # ⚠️ 日志落到守护进程自己那一份（logs/sitter-<task_id>.out|err），不再另开
  #    detach-<sid>.* —— 起进程那条路才有重定向，这条路里 stdout 就是守护进程
  #    的 stdout。找日志的人要知道这一条：挂机自动修的那一段在 sitter 的日志里。
  taken <- tryCatch({
    do.call(.dsapp_agent_worker, args)
    TRUE
  }, error = function(e) {
    dsapp_arun_update(sid, state = "orphan",
                      note = paste0("自动接手时出错：", conditionMessage(e)),
                      cfg = cfg)
    FALSE
  })

  if (!isTRUE(taken)) return(no("自动接手时出错", quiet))
  list(taken = TRUE, why = "", quiet = quiet)
}

#' 守着当前任务跑完的守护进程（预设「让当前任务跑完」）
#'
#' ⚠️ 和上面那个一样：会被序列化到另一个 R 进程，不能引用外面的对象。
#'
#' ⚠️ 它**不碰 agent 状态机**，也不写 agent_runs 表 —— 它守的是一个**任务**，
#'    不是一段循环。所以对话页上不会出现"AI 正在后台继续思考"那条横幅
#'    （那句话说出去就是假的：没有在思考，只是在等一个进程结束）。用户回来
#'    看到的直接就是那条执行结果，这才是实话。
.dsapp_task_sitter_worker <- function(app_dir, task_id, sid, data_root = NULL,
                                      user_id = NULL, target = NULL,
                                      params = NULL, max_iter = NULL,
                                      wall_limit = NULL) {
  if (!is.null(data_root) && nzchar(as.character(data_root)[1])) {
    Sys.setenv(DSAPP_DATA_ROOT = as.character(data_root)[1])
  }
  for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
    if (grepl("^mod_", basename(f))) next
    source(f, local = globalenv())
  }

  cfg <- dsapp_config()
  say <- function(...) message(sprintf("[sitter %s] ", task_id), ...)

  # 结果文件的位置按 jobs.R 里 dsapp_job_start() 的约定算，不另外发明一套。
  result_file <- file.path(cfg$run_dir, paste0("job-", task_id, ".json"))

  # 上限：执行器自己的超时 + 五分钟余量。
  # ⚠️ 必须有个上限。下面那两个"该收手了"的条件都依赖**别人**改库或者写文件，
  #    而这两件事都有可能永远不发生（比如任务进程被 kill -9 了、而应用没重启
  #    所以没人做清理）。没有上限的话这个进程会一直在那儿每分钟查一次库，
  #    直到机器重启 —— 用户看不见、日志里也只有它自己知道。
  deadline <- Sys.time() + as.numeric(cfg$exec$timeout %||% 1800) + 300

  # 句柄按接手来的那种造（proc 是 NULL、detached = TRUE），查活/查结果
  # 都走 .dsapp_detach_poll() —— 和 agent 那条路共用同一份判断，
  # 免得两处各自解释"任务还在不在跑"。
  h <- list(proc = NULL, detached = TRUE, task_id = task_id,
            result_file = result_file)

  repeat {
    res <- tryCatch(.dsapp_detach_poll(h, cfg),
                    error = function(e) { say("查任务失败：", conditionMessage(e))
                                          list(done = FALSE, alive = TRUE) })
    if (isTRUE(res$done)) {
      # 拿到结果 → 收尾 + 写回对话；拿不到（进程没了）→ 也收尾，让任务行
      # 从 running 落到 error，不然它会一直挂在那儿像还在跑。
      #
      # ⚠️ 收尾**会抛**（见 dsapp_task_closeout 的说明）。抛了就如实记一笔
      #    然后退出 —— 不能在这里重试：同一条路重试还会在同一个地方抛。
      ok <- tryCatch({
        dsapp_task_closeout(task_id, res$result, cfg = cfg); TRUE
      }, error = function(e) { say("收尾失败：", conditionMessage(e)); FALSE })

      # 结果写回对话。⚠️ 放在收尾**之后**：dsapp_task_result_text() 读的是
      # tasks 表里已经落好的 status/stdout，不先收尾的话它拼出来的是
      # "还在跑"那一版。收尾失败也照样写 —— 那会儿表里至少有一行，
      # 写出来的是个（可能不完整的）结果，比什么都没有强。
      if (!is.na(sid)) {
        tryCatch(dsapp_task_result_write(task_id, sid, cfg = cfg),
                 error = function(e) say("写回对话失败：", conditionMessage(e)))
      }
      say("任务 ", task_id, " 守护结束，收尾 ok=", ok)
      # 销掉登记 —— 横幅上的「正在后台跑完这个任务」到这一刻就不再是事实了。
      # ⚠️ 收尾失败（ok = FALSE）时也要销，但状态得说清楚是**失败**：
      #    留着 running 的话横幅会一直挂着，用户等的那个结果根本不会来。
      if (!is.na(sid)) {
        try(dsapp_arun_finish(
          sid, state = if (isTRUE(ok)) "done" else "blocked",
          note = if (isTRUE(ok)) "" else "任务收尾失败，结果没能写回对话",
          mode = "finish", cfg = cfg), silent = TRUE)
      }

      # ---- ★★ Test_V17.2 item 4：挂了就自己接手 ---------------------------
      #
      # 用户原话：「这类任务100%不需要用户确认，应该能自动运行才对」。
      #
      # ⚠️ 顺序是**死的**，三件事都得排在它前面：
      #   1. 收尾（closeout）   —— 不先收尾，任务行还停在 running，
      #      接手起来的循环会以为"那个任务还在跑"，一直在那儿等它；
      #   2. 写回对话           —— 模型被叫起来时要能读到那条报错。反过来的话
      #      它只能对着空气排查，而表现和"模型瞎编"一模一样；
      #   3. dsapp_arun_finish  —— 这一条最要紧：那张表上 session_id 是 UNIQUE，
      #      守护进程这条 "finish" 记录不销掉，接手那条 full 记录**写不进去**
      #      （.dsapp_detach_begin 进门第一句就是"已经在跑就别再起"）。
      #      这是本函数里唯一一处不能挪动的顺序。
      # ⚠️ 下面这一句是**阻塞**的：接手那条路不另起进程（原因见
      #    .dsapp_detach_begin 头上那段实测），所以它会一直跑到那段循环
      #    自己收手为止。return 在它后面 —— 也就是说这个守护进程的寿命
      #    等于"守任务 + 修任务"两段之和。
      if (!is.na(sid)) {
        fx <- tryCatch(.dsapp_autofix_takeover(
                          task_id, sid, user_id = user_id, target = target,
                          params = params, max_iter = max_iter,
                          wall_limit = wall_limit, cfg = cfg),
                       error = function(e) {
                         say("自动接手失败：", conditionMessage(e))
                         list(taken = FALSE, why = "自动接手时出错", quiet = FALSE)
                       })
        say("自动接手：", if (isTRUE(fx$taken)) "已接手" else fx$why)
        # 没接成手、而卡片上又写着"AI 已经在自动重试了" —— 那句承诺就没人
        # 兑现了。**必须**补一句话，否则用户回来看到的是一句空头支票，
        # 而他没有任何办法知道（这正是他这次报上来的那件事）。
        # 只在这一种组合下写：卡片本来就会问用户的那些（关着开关、不是
        # 自己能修的错），不需要再解释一遍"为什么没自动修"。
        if (!isTRUE(fx$taken) && isTRUE(fx$quiet)) {
          try(db_message_add(sid, "tool", paste0(
            "【平台提示】\n",
            sprintf("任务 #%d 没有跑通，而这一次**没有**自动接手（%s）。",
                    task_id, fx$why),
            "上面那张卡片上写着「AI 已经在自动重试了」，那是写下卡片时的判断 —— \
你关页面时选的是「让当前任务跑完」，守着它的只有这个守护进程，\
而它只管把结果写回来，不会把模型叫起来。\n",
            "接着修的话：点那张卡片上的「重试这一步」，或者直接把报错发给我。"),
            con = dsapp_db(cfg)), silent = TRUE)
        }
      }
      return(invisible(TRUE))
    }

    if (Sys.time() > deadline) {
      say("等到上限了，任务 ", task_id, " 还没结束，守护退出")
      # ⚠️ 这里是**没等到**，不是跑完了。状态必须和 done 分开 —— 合成一个
      #    的话，用户回来看到的是"任务已完成"，而结果压根不存在。
      if (!is.na(sid)) {
        try(dsapp_arun_finish(
          sid, state = "blocked",
          note = sprintf("等了 %d 分钟任务还没结束，守护进程先退出了",
                         round((as.numeric(cfg$exec$timeout %||% 1800) + 300) / 60)),
          mode = "finish", cfg = cfg), silent = TRUE)
      }
      return(invisible(FALSE))
    }

    Sys.sleep(1)
  }
}
