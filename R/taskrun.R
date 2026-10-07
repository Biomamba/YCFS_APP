# =============================================================================
# 提交一次执行、以及一次执行结束之后的收尾（V13.7 item 5）
# =============================================================================
#
# 这两件事原来都长在 app.R 的引擎对象里（e$start / e$poll）。拆出来是因为
# item 5 要加一条**脱离会话**的执行路径：页面关掉之后，后台进程接着把
# agent 循环走完。那条路没有 Shiny 会话、也没有那个全局引擎对象，但它要做的
# 事**和引擎一模一样** —— 同一道安全检查、同一道配额闸、同一张 tasks 表、
# 同一个产物同步。
#
# 抄一份的话，两边迟早会分叉，而分叉的表现是**其中一条路少了某道闸**：
# 比如后台那条忘了查配额，用户就会看到"手点跑不了、挂机反而跑起来了"。
# 所以这里的原则是：**只有一份**，app.R 的引擎也改成调这里。
#
# ⚠️ 这两个函数都**不许碰 shiny**。它们会在两处被调到，其中一处是
#    callr::r_bg 起来的子进程（R/detach.R 的 .dsapp_agent_worker）——
#    那里没有会话、没有 reactive 上下文，任何 `input$` / `reactiveValues`
#    都会当场抛 "Can't access reactive value outside of reactive consumer"。
#    ⚠️ 而且**不要**在文件顶部写 `library(shiny)`：子进程里 R/*.R 全都会被
#       source 一遍，加载 shiny 要多花几百毫秒，而这里一个函数都用不上它。
# =============================================================================

#' 提交一次执行：安全检查 → 配额 → 环境校验 → 建行 → 起作业
#'
#' @param code,lang   要跑的东西
#' @param title       任务名；NULL 就自动起名「任务功能_所属会话」（V9 item 7）
#' @param session_id  决定代码在哪个工作区里跑，以及每对话增量库挂在哪。
#'                    **少了它，执行会退回一次性的 task-<id> 目录**，
#'                    装进对话库的包一个也用不上。
#' @param target      list(kind = "server", env = ...) / list(kind = "remote", ...)
#' @param user_id     配额和审计都要它
#' @return list(ok, msg, task_id, handle)
#'         `ok = TRUE` 时 handle 要交给 dsapp_job_poll() 轮询。
#'
#' ⚠️ **不判"引擎忙不忙"**。那是调用方的事，而且两边不一样：会话里那个引擎
#'    用内存里的 `e$busy`（进程内单槽），脱离会话的那条路只能查库
#'    （见 dsapp_task_slot_busy）。把这一条塞进来的话，两种语义会互相污染。
dsapp_task_submit <- function(code, lang, title = NULL,
                              session_id = NA_character_,
                              target = list(kind = "server", env = "system"),
                              user_id = NULL, cfg = dsapp_config()) {
  if (identical(target$kind, "local")) {
    return(list(ok = FALSE, msg =
      "「本地电脑」模式不在服务器上执行代码，请用代码卡片的「打包下载」。"))
  }

  # 第一道防线。这里再扫一次而不是信任调用方：重跑路径、对话页路径、
  # 后台续跑路径都汇到这里，扫描放在唯一的入口上才不会漏。
  #
  # 远程执行也要扫。那台机器是用户自己的，炸了不心疼，但扫描还挡着
  # 另一件事：手滑。三种目标行为一致，比"远程就放松"更好预期。
  scan <- dsapp_scan_code(code)
  if (nrow(scan$blocked) > 0) {
    return(list(ok = FALSE, msg = paste0("代码未通过安全检查：\n",
                                         dsapp_scan_message(scan))))
  }

  # 第三道配额闸，也是最后一道。
  #
  # 前两道（上传、解压）管的是**用户主动往里放东西**；这一道管的是
  # **代码自己写出来的东西** —— 一段 `write.csv(..., "out.csv")` 循环
  # 能把工作区写到把盘撑满，而它不经过前两道中的任何一道。
  #
  # ⚠️ 这里只能判"**已经**超了"，判不了"这次会写多少" —— 代码还没跑，
  #    没人知道。所以语义是"超了就不许再起新任务"，而不是"预扣"。
  #    这不是妥协，是这件事唯一能有的精度：能预知产出体积的执行根本
  #    不需要配额。
  #
  # 远程目标不查：代码在**用户自己的机器**上跑，写的也是那台机器的盘。
  # 拿我们这边的配额去拦它，等于用一个不存在的约束报一个假错。
  if (identical(target$kind, "server")) {
    q <- tryCatch(dsapp_quota_check(user_id, 0, what = "再跑一个任务"),
                  error = function(e) list(ok = TRUE))
    if (!isTRUE(q$ok)) return(list(ok = FALSE, msg = q$msg))
  }

  # 提交前校验目标还成立。环境可能在提交后被别人删了，
  # 不查的话任务会跑起来才发现「解释器不存在」，白占一次队列。
  #
  # ★ V13.7 item 2：这句话原来结尾是「到「环境」页重新选择」—— 那是把平台的
  #   活写成用户的待办，而且是写给一个**上次已经选对过**的人（那个环境是他
  #   自己挑的，被删掉不是他干的）。措辞改成和 envfix.R 里那套一致：说清楚
  #   是什么坏了、谁在处理。真的清掉失效选择在 mod_chat.R 的
  #   dsapp_current_target()，它在**每次**提交之前都会查一遍，所以走到这里的
  #   这一句只剩一个很窄的竞态窗口（查完之后、提交之前环境被删）。
  if (identical(target$kind, "server")) {
    env <- target$env %||% "system"
    if (!identical(env, "system") && !dsapp_env_exists(env, cfg)) {
      return(list(ok = FALSE, msg = sprintf(
        paste0("选用的分析环境 %s 在提交的这一瞬间被删掉了。",
               "环境已经不在了，平台会切回系统环境重试 —— 不用你去改设置。"),
        env)))
    }
  }

  con <- dsapp_db(cfg)
  if (is.null(title) || !nzchar(title %||% "")) {
    title <- tryCatch(
      dsapp_task_title(code, lang, session_id = session_id, con = con),
      error = function(e) sprintf("%s 代码", lang))
  }
  tid <- db_task_create(title, code, lang, session_id = session_id, con = con,
                        target = dsapp_target_label(target))
  db_task_status(tid, "running", con = con)

  handle <- tryCatch(dsapp_job_start(code, lang, tid, cfg, target, session_id),
                     error = function(err) err)

  if (inherits(handle, "error")) {
    db_task_status(tid, "error", exit_code = NA_integer_,
                   stderr = conditionMessage(handle), con = con)
    return(list(ok = FALSE, msg = paste0("无法启动执行进程：",
                                         conditionMessage(handle))))
  }

  list(ok = TRUE, msg = "", task_id = tid, handle = handle)
}

# ---- ★ Test_V15.2：任务结束的邮件提醒 ---------------------------------------
#
# 用户原话：「言出法随界面开启一个让用户勾选邮件提醒的功能，开启后能把任务
# 运行成功完成/失败的信息发送到用户的邮箱」。
#
# 三个开关在 DSAPP_UIPREF_SPECS 里（R/uiprefs.R），**默认全 FALSE**：
# 发信是往外发东西，没问过就不能发。
#
# ⚠️ 这里**只入队，不发信**。发信要握手 + TLS，秒级，绝不放在收尾链上
#    （主进程不做长活，见 R/jobs.R 顶部）。入队是一次 INSERT，微秒级，
#    然后 dsapp_mail_kick() 起一个后台进程去排。
#
# ⚠️ 去重靠 mail_queue 上 `ref` 的部分唯一索引（`task:<tid>`）。收尾函数
#    可能被调不止一次（重连、重试），唯一索引保证同一封不会进两次队。
#
# ⚠️ **整段包在自己的 tryCatch 里**，这一点和 dsapp_task_closeout 的规矩
#    不冲突：那条规矩说的是不许吞**收尾自己**的异常（吞了任务页会永远转圈），
#    这里是反过来 —— 发信这段出事，绝不能把收尾链带崩。两件事不矛盾。
dsapp_task_notify <- function(tid, cfg = dsapp_config()) {
  tryCatch({
    # 没配 SMTP = 这个功能整个不存在。用户没开开关时连库都不用查。
    if (!isTRUE(dsapp_mail_ready(cfg))) return(invisible(FALSE))

    con <- dsapp_db(cfg)
    t <- db_task_get(tid, con = con)
    if (is.null(t) || nrow(t) == 0L) return(invisible(FALSE))

    st <- as.character(t$status %||% "")[1]
    # 只认终态。跑到一半（running）不发 —— 那说明收尾还没走到写状态那一步
    # （比如 closeout 自己在 db_task_status 之前抛了），这时候发信是错的。
    if (!st %in% c("success", "failed", "timeout", "error")) {
      return(invisible(FALSE))
    }
    is_ok <- identical(st, "success")

    # 收件人：tid → session_id → user_id → users.email
    uid <- db_session_owner(t$session_id %||% NULL, con = con)
    if (is.null(uid)) return(invisible(FALSE))
    u <- dsapp_user_by_id(uid, con = con)
    to <- as.character(u$email %||% "")[1]
    # 没有邮箱的账号（比如管理员代建的）就静默跳过 —— 不是错误。
    if (!nzchar(to) || !grepl("@", to, fixed = TRUE)) return(invisible(FALSE))

    # ⚠️ 成功和失败共用**一个**键（email_task）。理由写在 uiprefs.R 的规格
    #    那儿：拆成两个的话，「言出法随」页那一个总勾选框和设置页的两个
    #    细勾选框会对不上，只关一半时总开关显示什么都是错的。
    prefs <- dsapp_uipref_get(uid, con = con)
    if (!isTRUE(prefs$email_task)) return(invisible(FALSE))

    title <- as.character(t$title %||% "")[1]
    if (!nzchar(title)) title <- sprintf("任务 #%s", tid)

    verb <- switch(st,
      success = "跑完了",
      timeout = "超时被中止了",
      failed  = "失败了",
      error   = "出错了")
    mark <- if (is_ok) "✅" else "❌"

    body <- c(sprintf("## %s 任务%s", mark, verb), "",
              sprintf("- **任务**：%s", title),
              sprintf("- **编号**：#%s", tid),
              sprintf("- **开始**：%s", as.character(t$started_at %||% "—")[1]),
              sprintf("- **结束**：%s", as.character(t$finished_at %||% "—")[1]),
              sprintf("- **退出码**：%s", as.character(t$exit_code %||% "—")[1]))

    # 失败时把 stderr 的尾巴带上 —— 那才是"为什么挂了"。
    # ⚠️ 用「行尾两个空格」换行，**不用代码块**：代码块会经过
    #    dsapp_escape() → commonmark 被**二次转义**（`&` 变 `&amp;amp;`、
    #    `<` 变 `&amp;lt;`，见 R/render.R 顶部的说明，这是既有问题）。
    #    报错信息里 `<` `&` 太常见，走代码块会显示成乱码。行尾两空格是
    #    Markdown 核心语法（不是扩展），渲染成 <br>，且全程是普通文本。
    err <- as.character(t$stderr %||% "")[1]
    if (!is_ok && nzchar(err)) {
      lines <- utils::tail(strsplit(err, "\n", fixed = TRUE)[[1]], 30L)
      lines <- lines[nzchar(trimws(lines))]
      if (length(lines)) {
        body <- c(body, "", "**报错信息（末尾 30 行）**：", "",
                  paste(paste0(lines, "  "), collapse = "\n"))
      }
    }
    # 这一句是给"挂机跑长任务"的人看的：他多半不在电脑前，点不动界面。
    body <- c(body, "",
              "---", "",
              "这封邮件是你在「言出法随」里开了邮件提醒之后自动发的。",
              "要关掉它：设置 → 执行 → 邮件提醒。")

    body_md <- paste(body, collapse = "\n")

    id <- dsapp_mail_enqueue(
      to = to,
      subject = sprintf("【言出法随】%s 任务%s：%s",
                        if (is_ok) "✅" else "❌", verb, title),
      body_md = body_md,
      # 通知正文里没有图片，base_dir 给工作区是留给以后用的；
      # 给空串则 dsapp_mail_render 会跳过内联那一步，也不出错。
      base_dir = "",
      kind = "task",
      ref = sprintf("task:%s", tid),
      user_id = uid,
      cfg = cfg, con = con)

    if (!is.na(id)) {
      dsapp_mail_kick(cfg)
      message(sprintf("[dsapp] 任务 %s 的提醒邮件已入队（#%s）", tid, id))
    }
    invisible(!is.na(id))
  }, error = function(e) {
    # ⚠️ 绝不 re-raise。这里出事（库锁、字段缺、地址怪）不该让一个已经
    #    跑完的任务在界面上变成"收尾失败"。
    message(sprintf("[dsapp] 任务 %s 的提醒邮件没能入队：%s",
                    tid, conditionMessage(e)))
    invisible(FALSE)
  })
}

# =============================================================================
# 产物变更信号（★ V15.4 item 2）
# =============================================================================
# 用户原话：「在我多轮对话出结果后，并没有在言出法随的文件预览界面同步，
# 这个界面应该能在产出文件后自动刷新，并且也给用户一个手动刷新的按钮」。
#
# 那个界面（mod_chat.R 的 output$artifacts_card）读的是一条 3 秒的
# `reactivePoll`，判据是"目录里文件数 / 总字节 / mtime 之和"。它能自己转，
# 但有两个它看不出来的时刻：
#
#   · 同步动作可能**不改变摘要** —— 覆盖写一个**一模一样大小**的文件、
#     或者把 mtime 保留着搬过来（rsync -t / cp -p），三项全不变；
#   · 用户点了刷新按钮的那一下，本来就该**立刻**重算，而不是"等下一跳"。
#
# 所以这里放一个进程内的计数器：任务收尾时 +1，两个 poll 的 checkFunc
# **把它拼进返回的字符串**（拼进去，不是"读一下"—— `reactivePoll` 的实现
# 是 `rv$cookie <- checkFunc()`，而 reactiveValues 只有**值真变**才失效
# 下游；只读不拼等于什么都没做。这条在 R/mod_files.R 的 ws_groups 那里
# 已经被踩实过一次，那段注释就是为这件事写的）。
#
# ⚠️ 为什么是"进程内的 env"而不是 `state$art_rev`（计划里原来写的那样）：
#    `state` 是 app.R 里 `server()` 的**局部变量**，而 dsapp_task_closeout()
#    定义在 R/taskrun.R 的顶层 —— R 在**函数的定义环境**里找自由变量，不是在
#    调用方那里，所以它无论如何也看不见 `state`。改成让调用方来发信号也不行：
#    这个函数有**三个**调用点（app.R:520 的会话引擎、R/detach.R:589 和 :907
#    的脱离会话续跑），漏掉任何一个，那条路上的产物就永远不刷新，而且不报错。
#    放在这个函数里，三条路自动全覆盖。
#
# ⚠️ 计数器只增不减，不按对话分。分对话要在这里查会话 → 多一次库往返，
#    而且 detach.R 那条路上 `trow$session_id` 可能是 NULL。**粗一点没关系**：
#    拿到手的是一次多余的重算（各自重读一次自己的目录），不是错误的结果 ——
#    别的对话的任务跑完，顺手把你这一格也刷一下，代价是几毫秒的 list.files。
.dsapp_art_signal <- new.env(parent = emptyenv())
.dsapp_art_signal$rev <- 0L

#' 产物可能变了（任务收尾时调一次）
dsapp_art_bump <- function() {
  v <- .dsapp_art_signal$rev
  if (!length(v) || is.na(v)) v <- 0L
  .dsapp_art_signal$rev <- v + 1L
  invisible(.dsapp_art_signal$rev)
}

#' 当前的产物版本号。**给 checkFunc 拼字符串用**，不是给界面读的 ——
#' 它是普通数值，读它不建立任何响应式依赖。
dsapp_art_rev <- function() {
  v <- .dsapp_art_signal$rev
  if (!length(v) || is.na(v)) 0L else as.integer(v)
}

#' 一次执行结束之后的收尾：写状态 → 记产物 → 同步进文件管理区
#'
#' @param tid 任务 id
#' @param r   dsapp_job_poll() 拿回来的 result；NULL 或 `ok = FALSE` 表示
#'            执行进程没能正常回传（被杀、崩了）
#' @return 引擎 e$poll() 原来返回的那个 list（界面上的提示直接读它）
#'
#' ⚠️ 这个函数**会抛** —— 写库失败（库锁超时、磁盘满、外键冲突）会。调用方
#'    必须自己决定抛出去之后怎么办：会话里的引擎把状态复位走 on.exit，
#'    后台那条路则是"这一轮结束、循环继续"。**不要**在这里包一层 tryCatch
#'    把异常吞掉：吞掉之后任务页会永远停在一个转不完的圈上，而没有任何
#'    地方说过为什么。
dsapp_task_closeout <- function(tid, r, cfg = dsapp_config()) {
  con <- dsapp_db(cfg)

  # ★ Test_V15.2：无论从哪条路出去，都补一次"任务结束了"的邮件提醒。
  #
  # ⚠️ 用 on.exit 而不是在每个 return 前面各写一次。这个函数有两条出口
  #    （下面那条 error 分支、以及末尾的隐式返回），而且它**会抛**
  #    （见上面那段说明）。on.exit 三条路全覆盖，包括以后新加的出口 ——
  #    逐点插桩的写法漏一个出口的表现是"某些失败收不到信"，静默且难查。
  #
  # ⚠️ 它不改返回值，也不吞收尾自己的异常：真正干活的
  #    `dsapp_task_notify()` 自己整段包了 tryCatch，出事只记一行日志。
  #    收尾链该抛还是照抛，规矩没变。
  #
  # ⚠️⚠️ 这里**再兜一层 tryCatch**，看着重复，但不是。`on.exit` **本身不吞
  #     异常**（实测：`function() { on.exit(stop("x")); 1L }` 照样抛），
  #     所以收尾链的安危**全押在被调方有没有自己包住**。那是单点：
  #     哪天有人在 notify 的 tryCatch 外面加一行、或者把那个 tryCatch 挪走，
  #     一条已经跑完的任务就会因为"发信模块出问题"而在界面上变成收尾失败。
  #     tests/v152_closeout_guard.R 用变异把这一条钉住了 —— 把 notify 换成
  #     必抛的版本，这个 tryCatch 就是唯一的拦截点。
  #
  # ⚠️ 拦的是"钩子出事"，不是"收尾出事"：所以和上面那条规矩不冲突。
  #
  # ⚠️ 位置在 `con <- dsapp_db(cfg)` **之后**：库连不上时它读状态也读不到，
  #    而且那种情况下任务状态还是 running，本来就轮不到它发信。
  on.exit(tryCatch(dsapp_task_notify(tid, cfg), error = function(e) NULL),
          add = TRUE)

  if (is.null(r) || !isTRUE(r$ok)) {
    stderr <- if (!is.null(r) && !is.null(r$stderr)) r$stderr
              else "执行进程意外退出（可能被系统杀掉）"
    db_task_status(tid, "error", exit_code = NA_integer_,
                   stderr = stderr, con = con)
    return(list(task_id = tid, status = "error", stderr = stderr))
  }

  db_task_status(tid, r$status %||% "error",
                 exit_code = r$exit_code %||% NA_integer_,
                 stdout = r$stdout %||% "",
                 stderr = r$stderr %||% "",
                 workdir = r$workdir %||% NULL,
                 con = con)

  # ★ V14 item 3：这次产出的 HTML 报告**就地改写成自包含的**（图片 base64
  #   写进文件本身），用户原话：「生成的全部 html 文件需要把图片写进 html
  #   文件里，而不是临时从附带文件夹里读取，这样保障用户单独分发 html 文件
  #   时，其它人也能正常查看」。
  #
  # ⚠️ 位置：必须在下面**落库（db_task_files_set）和同步之前**。
  #    这两步都会记文件大小，先改完再记，记录里的数字才是用户真正下载到的
  #    那个 —— 反过来会让"产物列表显示 38 KB、下载下来 1.7 MB"，
  #    而且没有任何地方解释得清这个差。
  #
  # ⚠️ 整段 tryCatch：任务已经跑完了，内联失败绝不能把结果毁掉。失败时的
  #    退路是通的 —— 预览和下载那两条路各自都会内联一遍（见 files.R 的
  #    dsapp_html_read_inlined），用户拿到的仍然是完整的报告。
  #
  # ⚠️ 为什么放在这一层而不是 executor 里：executor 是**子进程**（见 jobs.R），
  #    它跑在任务还没结束的时候，那会儿写出来的还是半截文件；
  #    而且改盘上的产物属于"任务收尾"，和 dsapp_sync_artifacts 同一层。
  tryCatch(
    dsapp_ws_selfcontain_html(r$workdir %||% NULL, r$artifacts),
    error = function(e) NULL)

  # V7：记下"这次执行写出了哪些文件"。文件页据此把产物按任务分组
  # （用户的原话：「文件需要以任务名称分类展开」）。
  #
  # 差集是 executor 在执行前后各扫一次工作区算出来的（见 dsapp_run_code），
  # 这里只是把它落库 —— 以前它只活在 run/job-*.json 里，而那个文件下次
  # 启动就被清理掉了，所以"这个文件是哪个任务写的"在库里没有任何线索。
  #
  # ⚠️ 整段 tryCatch 包住：写索引失败（库锁超时、磁盘满）绝不能把
  #    刚刚跑成功的任务结果毁掉。索引丢了只是文件页少一个分组，
  #    结果丢了用户就得重跑一遍几个小时的分析。
  trow <- NULL
  tryCatch({
    trow <- db_task_get(tid, con = con)
    db_task_files_set(tid, trow$session_id %||% NULL, r$artifacts, con = con)
  }, error = function(e) NULL)

  # ★ V12 item 3：产物自动同步到文件管理区。
  #
  # 用户原话：「任务产生的文件还是不能同步到文件管理区，请设置自动同步」。
  # 以前产物只留在对话自己的工作区里，要用户自己点「发布」——而"要记得点
  # 发布"这件事本身就是绝大多数人不会做的动作，于是他们跑去「文件」页
  # 找不到东西，结论是"同步坏了"。
  #
  # 落点是**每个对话一个文件夹**（不是共享区根目录），理由见
  # files.R 的 dsapp_sync_artifacts。
  #
  # ⚠️ 位置在下游、不在 executor 里：executor 是**子进程**（见 jobs.R），
  #    它不该碰共享区和归属表；而且它跑在任务还没结束的时候，那会儿写出
  #    来的是半截文件。
  # ⚠️ 和上面一样整段包 tryCatch：任务已经跑完了，同步失败绝不能把结果毁掉。
  #
  # ⚠️⚠️ Test_V16.9：**兜底的那个 list 必须和成功路径同形**。
  #    原来它少写了 `bytes` 和 `blocked`，于是同步一旦抛异常，下游读
  #    `sync$blocked` 拿到的是 NULL、`isTRUE(NULL > 0)` 是 FALSE ——
  #    "同步整个失败了"反而比"同步漏了几个"更安静。本仓为此记过账
  #    （R/files.R 里 `res$skipped` 字段缺失那次）。加字段时两边一起加。
  sync <- tryCatch(
    dsapp_sync_artifacts(trow$session_id %||% NULL, r$artifacts,
                         user_id = trow$user_id %||% NULL, cfg = cfg),
    error = function(e) list(ok = FALSE, dir = NULL, n = 0L, bytes = 0,
                             skipped = 0L, blocked = 0L,
                             msg = conditionMessage(e)))

  # ★ Test_V16.9：有产物**因为上限**没进文件区时，留一条可查的记录。
  #
  # 用户原话：「对话页面的文件展示的是全的，但是文件区的文件几乎没有，
  # 点同步也没用」。那次 9030 缺的 119 个就是这么来的：撞了
  # DSAPP_SYNC_MAX_BYTES 之后 `blocked++` 继续跑，**不报错、不重试、
  # 也永远不会再进队列**（差集里它下轮既非新增也非改动）——
  # 全库累积 298 个文件、9 GB，而没有任何地方能查到这件事发生过。
  #
  # 这里只负责"留痕"（谁、哪个对话、丢了几个、多大），**给用户看的那句话
  # 在 app.R 的成功提示里**（那条路本来就会读 sync$skipped，见下面
  # `synced = sync` 的去向）；修的办法是文件页那颗「补齐」按钮
  # （dsapp_sync_repair）。
  #
  # ⚠️ 包 tryCatch：审计是旁路，它自己内部也包了一层，但这里再包一层是
  #    有意的 —— 这是任务收尾的路上，任何"顺手做的事"都不许把已经跑完的
  #    结果带下去（和上面 index/同步那两段同一个规矩）。
  # ⚠️ 用 `%||% 0L` 而不是直接比：上面兜底那一支、以及**旧版本写下的**
  #    sync 对象都可能没有这个字段。
  if ((sync$blocked %||% 0L) > 0L) {
    tryCatch(
      dsapp_audit("artifact_sync_blocked",
                  user_id = trow$user_id %||% NULL,
                  target = as.character(trow$session_id %||% ""),
                  detail = sprintf("任务 %s：%d 个产物超出同步上限未进文件区（本次已同步 %d 个，%.1f MB）",
                                   tid, as.integer(sync$blocked),
                                   as.integer(sync$n %||% 0L),
                                   (sync$bytes %||% 0) / 1024^2),
                  ok = FALSE, cfg = cfg, con = con),
      error = function(e) NULL)
  }

  # ★ V15.4 item 2：产物可能变了 —— 通知「言出法随」右栏那一格。
  #   位置在 sync **之后**：它要通知的正是"同步已经落地"这件事。
  #   ⚠️ 不包 tryCatch，因为 dsapp_art_bump() 不会抛（纯内存自增）；
  #      真抛了也应该让调用方看见 —— 见上面 @details 里"不要吞异常"那条。
  dsapp_art_bump()

  list(task_id = tid, status = r$status, saved = r$saved,
       artifacts = r$artifacts, workdir = r$workdir,
       remote_note = r$remote_note, synced = sync,
       env_notes = as.character(unlist(r$env_notes)),
       # ★ V13.12 item 8：产物体检结果，一路带到 tool 消息里（见
       # executor.R 的 dsapp_artifact_check）。落库那一步会把这段文字
       # 写进对话，所以**这里不能吞**：吞了，模型下一轮就以为一切正常。
       bad_artifacts = as.character(unlist(r$bad_artifacts %||% character(0))))
}

#' 此刻数据库里有没有"别人正在跑"的任务（非响应式）
#'
#' **只给脱离会话的那条路用**（R/detach.R）。会话里那个引擎有自己的
#' `e$busy` 单槽，它才是正常的互斥；这个函数是给"另一个进程"补的 ——
#' 后台续跑的循环不在那个引擎里，它想提交任务时看不见 `e$busy`。
#'
#' ⚠️ 判据用 **status = 'running' 的行**，不是引擎内存。应用重启之后内存里
#'    什么都没有，但库里会留下一行永远 running（启动清理会把它标成
#'    "应用重启，任务被中断"，见 db.R）—— 那个清理跑过之后这里就是干净的。
#'
#' ⚠️ 这里**有一个收不掉的竞态**：查完到真提交之间有几十毫秒，这中间
#'    网页那边的会话可能刚好提交了一个任务。关不掉的原因是"单槽"这个
#'    约束只活在**进程内存**里，跨进程要真锁就得改表结构。
#'    代价是有界的：最坏情况两个任务同时跑，而不是数据被写坏。
#'    真正要做的是把单槽落进库（比如 tasks 上加一个 running 唯一索引），
#'    那是另一件事，不在这一次的范围里。
dsapp_task_slot_busy <- function(cfg = dsapp_config()) {
  n <- tryCatch(
    DBI::dbGetQuery(dsapp_db(cfg),
                    "SELECT COUNT(*) AS n FROM tasks WHERE status = 'running'")$n,
    error = function(e) NA_integer_)
  # 查不出来（NA）当"忙"：宁可让后台多等一轮，也不要因为查不出来就
  # 抢了别人正在跑的那个槽。和 envs.R 里 uname 取不到就放行是**相反**的
  # 取舍 —— 那边放行的代价是"少一次拦截"，这边放行的代价是"两个任务同时跑"。
  if (length(n) != 1L || is.na(n)) return(TRUE)
  as.integer(n) > 0L
}
