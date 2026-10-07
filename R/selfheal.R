# ============================================================================
# 平台自己能修的事，不要问用户（V13.7 item 2）
# ============================================================================
#
# 用户原话：「系统、软件报错不要让用户决断，自动解决」。
#
# 这句话在这个项目里落地成一条**可以照着检查的规矩**，而不是一句态度：
#
#   凡是"该怎么办"是确定的、且平台自己动得了手的，平台就**当场做掉**，
#   然后把「已经做了什么」告诉用户。交给用户的只允许剩两类：
#
#     (a) 平台确实做不到的（要 sudo、要改 .Renviron、要别的用户配合）
#     (b) 只有用户知道的（他想要哪个环境、哪份数据）
#
#   「请到「环境」页重新选一个」「请刷新一下页面」「请截图给管理员」
#   这三句是这一版主要清理的对象 —— 它们**都不是**上面那两类，
#   它们是"平台知道答案却把动作转手了"。
#
# ---- 为什么单独一个文件 --------------------------------------------------
#
# 因为散着改会退回去。这个仓库里 showNotification 出现过 160 多次，
# 每一处都自己拼句子，于是同一个问题的说法有五六种，而"让用户去点一下"
# 那种写法**看起来特别自然**，下次加功能的人顺手就写了。
# 收进这里之后，检查的办法就变成一句可执行的：报错文案不许出现祈使句
# 形式的"请你……"（selftest 里有断言扫这个）。
#
# ---- 约定（和 R/db.R 的 migrate / R/files.R 的 ensure 同一套）-------------
#
#   1. **绝不抛异常**。这些函数跑在渲染路上，抛出去就是白屏。
#   2. 幂等。再跑一遍没有副作用。
#   3. 技术细节（conditionMessage、stderr、库名、路径）**进审计日志**，
#      不进用户屏幕。用户屏幕上只留"哪一步没成、现在怎么办"。
#   4. 失败要说出来，不静默 —— 这个项目里"点了没反应"被当成 bug 查过好几次。
#
# ⚠️ 和 R/envfix.R 的分工：那边管**任务执行**失败（跑代码跑挂了，回喂给模型
#    让它自己修）；这里管**平台自身**的失败（写库、刷新、选环境这些）。
#    两者的读者不同，不要互相调用。

#' 这个异常是不是「待会儿自己就好了」那一类
#'
#' SQLite 的 `database is locked` 是**唯一**一类真的会自己好的错误：别的
#' 连接正在写，等它写完就好。识别出来才有资格重试 —— 认错了对象会变成
#' "对着一个永远好不了的错误重试三遍，把用户卡住三倍久"。
#'
#' ⚠️ 匹配用的是 `conditionMessage()` 的**英文原文**，因为它来自 SQLite
#'    本身，不受我们改文案影响。别改成匹配我们自己的中文句子。
dsapp_err_is_locked <- function(e) {
  m <- tryCatch(conditionMessage(e), error = function(x) "")
  if (length(m) != 1L || is.na(m) || !nzchar(m)) return(FALSE)
  grepl("database is locked|database table is locked", m, ignore.case = TRUE)
}

#' 写库：撞上锁就自己等一会儿再来
#'
#' ⚠️ `tries` 和 `wait` 都要小。Shiny 是**单线程**的，这里的 `Sys.sleep()`
#'    会把整个 R 进程连同所有会话一起按住 —— 而连接上已经挂着
#'    `busy_timeout = 5000`（R/db.R），也就是说走到这里之前 SQLite 自己
#'    已经等过 5 秒了。现在是"再来两下、总共不超过 1 秒"，最坏情况给用户
#'    加的延迟是有界的。
#'
#' 重试仍然失败就把原异常抛回去 —— 这一层只负责"多给一次机会"，
#' 不负责替调用方决定失败之后怎么办。
dsapp_db_retry <- function(fn, tries = 3L, wait = 0.3) {
  n <- max(1L, suppressWarnings(as.integer(tries)[1]) %||% 1L)
  if (is.na(n) || n < 1L) n <- 1L
  last <- NULL
  for (i in seq_len(n)) {
    r <- tryCatch(list(ok = TRUE, v = fn()),
                  error = function(e) list(ok = FALSE, e = e))
    if (isTRUE(r$ok)) return(r$v)
    last <- r$e
    # 只在"等一会儿真的会好"的时候才等。其余错误立刻抛回去 ——
    # 语法错、约束冲突这类重试一百遍也是一样的结果。
    if (!dsapp_err_is_locked(last) || i >= n) break
    Sys.sleep(wait * i)
  }
  stop(last)
}

#' 把异常翻成一句**给用户看**的话，原始信息进审计日志
#'
#' @param e      捕获到的异常
#' @param doing  哪一步没成，写成用户认得出的动作（「保存对话记录」）
#' @param hint   平台已经做过的补救，或者确实需要用户做的那一件事。
#'               **没把握就别写** —— 空着比编一句强。
#'
#' ★ 为什么不直接把 `conditionMessage(e)` 摆到界面上：那多半是
#'   `database is locked` / `cannot open the connection` 这类英文原文。
#'   它对这个用户没有任何信息量，只会让他以为是自己操作错了，
#'   而他唯一能做的动作是"再点一次" —— 那正是平台该自己做的事。
#'
#' ⚠️ 但**不等于瞒着**：原文走 dsapp_audit 进了持久日志（排查问题时看得到）。
#'    对用户说人话和对开发者保留细节，是两件事，不用二选一。
dsapp_err_user <- function(e, doing, hint = NULL) {
  raw <- tryCatch(conditionMessage(e), error = function(x) "")
  if (length(raw) == 1L && !is.na(raw) && nzchar(raw)) {
    tryCatch(dsapp_audit("平台错误", target = doing, detail = raw, ok = FALSE),
             error = function(x) NULL)
  }
  tail_txt <- if (!is.null(hint) && length(hint) == 1L && nzchar(hint)) {
    hint
  } else {
    "这不是你操作的问题，可以直接重试一次。"
  }
  paste0(doing, "没成功。", tail_txt)
}

#' 引用到的东西已经不在了：平台自己把列表刷新掉，别让用户去按 F5
#'
#' 场景：两个页签开着，在 A 里删了这条对话/文件/技能，回 B 里点它 ——
#' 库里已经没有了。原来的写法是一句红色 toast「请刷新一下页面」，
#' 把一次纯粹的界面陈旧说成了错误，还附赠一个用户待办。
#'
#' 正确的做法是：平台自己重新拉一遍列表（就是 F5 会做的事），然后
#' 用**普通消息**（不是 error）说清楚"它不在了，列表已经是最新的"。
#' 用户不用做任何事，看到的也是一句陈述而不是一句指令。
#'
#' @param what   什么东西不在了，写进句子里（「这条技能」）
#' @param refresh 刷新列表的 thunk（通常是 `xxx_res(xxx_res() + 1L)`）。
#'                包在 tryCatch 里 —— 刷新失败也不能把主流程带下去。
dsapp_notify_stale <- function(what, refresh = NULL) {
  if (is.function(refresh)) {
    tryCatch(refresh(), error = function(e) NULL)
  }
  tryCatch(
    showNotification(sprintf("%s已经不在了，列表已经自动刷新。", what),
                     type = "message", duration = 5),
    error = function(e) NULL)
  invisible(FALSE)
}

#' 环境选择指向了一个已经不存在（或没有这个解释器）的 conda 环境
#'
#' 这是用户在「设置 → 硬件选择」里**曾经**选对过、后来那个环境被删掉的情形。
#' 平台完全查得出来，也完全知道该怎么办：那个选择已经失效了，清掉它、
#' 回到平台默认环境。留在那儿只会让**每一次**执行都失败在同一处，
#' 而用户看到的是一句"请到「环境」页重新选一个"—— 他上次就是这么选的。
#'
#' @return `list(dangling = TRUE/FALSE, env = <失效的环境名>)`
#'         调用方据此决定要不要清掉会话里存的那个选择。
#'
#' ⚠️ 这里**只做判定，不动数据**。真正清掉那个选择是调用方的事（它才知道
#'    选择存在哪儿、怎么存）。理由和 dsapp_limits_for_user 那段一样：
#'    这个函数是纯的，selftest 会直接调它，不该让它去碰数据库。
dsapp_env_sel_dangling <- function(env_name, cfg = dsapp_config()) {
  no <- list(dangling = FALSE, env = NA_character_)
  if (is.null(env_name) || length(env_name) != 1L || is.na(env_name)) return(no)
  env_name <- trimws(as.character(env_name))
  # "system" 是"就用系统解释器"，不是 conda 环境名 —— 它没有"被删掉"这回事
  if (!nzchar(env_name) || identical(env_name, "system")) return(no)

  exists_ok <- tryCatch(dsapp_env_exists(env_name, cfg), error = function(e) NA)
  # 查不出来（NA）一律当"没失效"：宁可不清理，也不要因为查不出来就把
  # 一个本来能用的选择判死。和 R/envs.R 里 uname 取不到就放行同一个道理。
  if (length(exists_ok) != 1L || is.na(exists_ok)) return(no)
  if (!isTRUE(exists_ok)) return(list(dangling = TRUE, env = env_name))

  # 环境在，但这个语言的解释器不在里面。⚠️ 这一条**不算失效**：
  # 环境本身是好的，是代码块的语言选错了 —— 那是模型该改的事
  #（dsapp_env_fix_hint 里写着），不是这里该替他清掉的。
  no
}
