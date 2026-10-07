# =============================================================================
# 整页报错的兜底（V13.10 item 1）
# =============================================================================
#
# 用户原话：
#
#   「后台页面显示：An error has occurred. Check your logs or contact the
#     app author for clarification.」
#
# 这句话不是这个应用写的，也不是任何模板里的字符串 —— 它是 **Shiny 把真实
# 错误文本替换掉之后**的那一句。所以第一版排查时把整个文件系统 grep 了一遍
# 都没找到它，那是正常的。三个环节拼起来才是完整的那张页面：
#
#   1. 这个应用的**整个界面**是 app.R 里唯一一个 `renderUI("app_root")`
#      （注册、登录、强制改密、须知闸门、主界面全在里面，见 app.R:1239
#      和 dsapp_main_ui）。renderUI 里抛出的异常，Shiny 的处理是把**那个
#      output 的内容整块**换成错误文本 —— 而那个 output 就是整页。于是
#      "某一页的某一处出错"的表现是"整个应用变成一句英文报错"：左栏、
#      页签、页脚、所有卡片全没了，只剩一句话。
#
#   2. 线上跑的是 Shiny Server，它的 `sanitize_errors` **默认是开的**
#      （/opt/shiny-server/lib/router/config-router-util.js:57
#       `appSettings.sanitizeErrors = true;`，只有配置里显式写
#       `sanitize_errors false;` 才会关）。这东西的作用正是"别把 R 的报错
#      原文给用户看"。
#
#      ⚠️ 本机的 /etc/shiny-server/shiny-server.conf **没有**这一行，也就是
#         开着。改它要 sudo 且要重启服务，而且从"不泄露内部信息"的角度它
#         本来就没错 —— **所以不要去打服务器配置的主意**，要在应用里解决。
#
#   3. 于是用户拿到的是：一句英文 + "去看日志" + 一条他自己打不开的日志路径
#      （/var/log/shiny-server/ 下那些文件是 shiny:shiny 0640，连开发者都要
#      sudo 才读得到）。
#
# 这一版做三件事，把这条链子每一环都换掉：
#
#   dsapp_err_log()   完整错误 + **抛出时的调用栈**写进 data/logs/app_error.log。
#                     这个文件归应用自己（shiny 可写、团队可读），不必 sudo。
#   dsapp_err_try()   给 renderUI / observe 的函数体套一层：出错时把那一块
#                     换成一张人话卡片，而不是把整页清空。
#   dsapp_err_init()  全局兜底。注册 shiny::onUnhandledError()，让"没有任何
#                     output 接住"的错误（observe / observeEvent / 定时器里
#                     抛的那些）也进同一份日志 —— 它们在 Shiny 里默认只是
#                     往控制台打一行 Warning，谁都不会去看。
#   dsapp_err_soften_session()
#                     （V15.6 item 4）**软错误不判会话死刑**。上面那条只是
#                     "记下来"，错误该关会话还是照关：observe 里一个没人接的
#                     错 = Shiny 把整个会话 close 掉 = 用户那边 socket 断开、
#                     弹「与服务器的连接断了」、整页点不动。这个函数把这个
#                     会话的 unhandledError 换成"记日志但不 close"。
#
# ⚠️ 用 `shiny::onUnhandledError(fun, session = NULL)` 注册的是**全局**回调
#    （见 shiny 源码：session 为 NULL 时进 .globals$onUnhandledErrorCallbacks），
#    必须在任何 session 建立之前调用，所以放在 app.R 启动段。放进 server()
#    里就只对那一个 session 生效了。
#
# ⚠️ 这张兜底卡片**不给普通用户看内部细节**（工作区路径、SQL、堆栈）。用户
#    能做的只有"刷新一下再试"，卡片就说这一句 + 一个时间戳，好让他报障时
#    对得上日志。细节全在日志文件里，给管理员看。

.dsapp_err <- new.env(parent = emptyenv())
.dsapp_err$inited <- FALSE
# 出错时**绝不**让日志本身再抛一次 —— 兜底的兜底。（写日志失败、目录只读、
# 配置还没建起来都会走到这里。）
.dsapp_err$max_bytes <- 1024 * 1024

# Shiny 把**输出渲染**的报错换成的通用文案。
#
# ★★ 2026-10-06 实测定下来的（在此之前整个文件顶部那段"是 sanitize_errors
#    换的"只是推断，没有验过）：
#
#      options(shiny.sanitize.errors = TRUE)
#      output$box <- renderUI(stop("真实错"))     # 浏览器里那一格
#      → 显示 "An error has occurred. Check your logs or contact the app
#              author for clarification."
#      → 我们注册的 onUnhandledError 收到的 conditionMessage **也是这一句**
#      → 只有 stderr（/var/log/shiny-server/*.log，shiny:shiny 0640，
#        要 sudo）里才是："Error in renderUI: 真实错" + 完整堆栈
#      → 浏览器里那句是**真的**，不是前端 JS 换的；shiny 1.10.0 的 R 代码里
#        连 "sanitize" 这个词都没有（那个选项是 shiny-server 从启动参数
#        塞进来的，读它的代码在 R6 方法体里，所以按函数体 deparse 搜不到）
#
# 后果就是我们自己那份 app_error.log：线上 581 条记录里 577 条
# `where=unhandled`，**消息全是这一句**，堆栈全是样板 —— 它看着"有错误
# 记录"，其实一条能定位的信息都没有。这个常量就是用来把这种记录认出来的。
.dsapp_err$sanitized_msg <-
  "An error has occurred. Check your logs or contact the app author for clarification."

#' 应用错误日志的路径
#'
#' 刻意**不放在** /var/log/shiny-server/：那里的文件是 shiny:shiny 0640，
#' 开发/运维都得 sudo 才读得到，"去看日志"这句话因此等于没说。
dsapp_err_log_path <- function(cfg = dsapp_config()) {
  file.path(cfg$logs_dir, "app_error.log")
}

#' 把一次错误写进日志
#'
#' @param e    错误对象（或字符串）
#' @param where 出错的位置标签，比如 "app_root"、"htadmin$tbl"
#' @param trace 调用栈。**必须**是抛出那一刻抓的（见 dsapp_err_try 里的
#'   withCallingHandlers）—— 在 tryCatch 的 handler 里现抓 sys.calls()
#'   拿到的是 handler 自己的栈，一行有用的都没有。
#' @return 日志文件路径（写失败返回 NA_character_）
dsapp_err_log <- function(e, where = "", trace = NULL, cfg = NULL) {
  p <- tryCatch({
    cfg <- cfg %||% dsapp_config()
    dsapp_err_log_path(cfg)
  }, error = function(e) NA_character_)

  msg <- tryCatch(conditionMessage(e), error = function(e2) as.character(e))
  if (length(msg) == 0 || is.na(msg[1])) msg <- "(无法取出错误信息)"

  tb <- ""
  if (!is.null(trace)) {
    # ★★ V16.7：这里原来是 `utils::head(trace, 40)`，注释还写着"40 层足够
    #    覆盖到这个应用自己的代码" —— **正好是反的**。
    #
    #    `sys.calls()` 是**从外到内**排的：最外面那几十层永远是
    #    runApp → serviceApp → flushReact → promises 的样板，一次都不例外。
    #    线上 221 条记录的堆栈指纹只有两种（差 1 个字节），就是这个原因 ——
    #    真正抛错的 observe / renderUI 在**尾部**，被 head() 整个切掉了。
    #    于是这份日志从建立起就没能定位过任何一次错误，而它看上去"有堆栈"，
    #    连"要不要往下翻"这个念头都不会有。
    #
    #    实测过的证据在 selftest.R 那段排查记录里：当年把 40 临时改成 300，
    #    栈里立刻露出 `<observer:output$htadmin-count>`。也就是说真凶一直在
    #    栈里，只差没有去读尾部。
    #
    #    现在两头都留：头 8 帧说明"是哪个循环抛的"（serviceApp / flushReact /
    #    定时器），尾 26 帧才是"谁抛的"。中间用一行 `...` 表示省略。
    #    ⚠️ 尾部帧**必须**保留原始行号 i（它是 sys.calls() 里的真实下标），
    #       不要重新从 1 编号 —— 那个下标是"往里数第几层"，是排查时唯一能
    #       和别的日志对齐的东西。
    n <- length(trace)
    # 每一帧拍成一行，顺便把**源码位置**带上。
    # ⚠️ `deparse()` 不会输出 srcref —— Shiny 自己的 traceback 里那句
    #    `renderUI [R/mod_skills.R#378]` 是它另外拿 attr(call,"srcref") 拼的。
    #    我们也拼：排查时"哪一行"比"函数叫什么"值钱得多。
    frame_line <- function(i) {
      cl <- trace[[i]]
      d <- tryCatch(paste(deparse(cl), collapse = " "), error = function(e2) "<?>")
      src <- ""
      sr <- tryCatch(attr(cl, "srcref"), error = function(e2) NULL)
      if (!is.null(sr)) {
        fn <- tryCatch(attr(sr, "srcfile")$filename, error = function(e2) NULL)
        if (length(fn) == 1L && !is.na(fn) && nzchar(fn))
          src <- sprintf(" [%s#%s]", basename(fn), as.integer(sr[1]))
      }
      sprintf("  %4d: %s%s", i, substr(d, 1, 160), src)
    }
    lines <- vapply(seq_len(n), frame_line, character(1))

    # ★★ V16.7 第二处：光"取尾部"还不够，得**按名字捞**。
    #
    #    上面那个 head/tail 的修法对 `observe` 那条路是对的（抛错的
    #    observer 就在栈底）。但**输出（renderUI / renderText / …）不行**：
    #    它的错误要经过 printError 才轮到我们看，而 printError 出现时
    #    栈底三帧永远是它自己的机器码：
    #
    #        66: value[[3L]](cond)
    #        67: catch(e)
    #        68: printError(cond)
    #
    #    —— 取尾部正好取到这三行，真凶（`<observer:output$xxx>`）在中间。
    #    所以再加一段：把栈里**长得像应用自己的**帧按名字挑出来单独列。
    #    判据是名字，不是位置，两头都不靠。
    key <- grep("output\\$|<observer:|<reactive:|renderUI|renderText|renderPlot|renderTable|renderPrint|renderDT|renderDataTable|datatable",
                lines)
    key <- utils::tail(key, 14L)

    head_n <- 8L
    tail_n <- 26L
    idx <- if (n <= head_n + tail_n) seq_len(n) else
      c(seq_len(head_n), NA_integer_, seq.int(n - tail_n + 1L, n))
    body <- vapply(idx, function(i) if (is.na(i)) "   ..." else lines[[i]],
                   character(1))
    tb <- paste0(
      if (length(key)) paste0("  ★ 关键帧（谁抛的就在这几层里）：\n",
                              paste(lines[key], collapse = "\n"), "\n") else "",
      paste(body, collapse = "\n"))
  }

  stamp <- tryCatch(dsapp_now(), error = function(e2) "")
  uid <- tryCatch(.dsapp_err$uid %||% "", error = function(e2) "")
  # ★ V16.7：错误的**类**也要记。只凭那句话（经常是被 sanitize 过的通用文案）
  #   分不出"R 自己抛的简单错误"和"某个包的自定义条件"，而这两类的排查方向
  #   完全不同。class(e) 是一个词，代价可以忽略。
  cls <- tryCatch(paste(class(e), collapse = "/"), error = function(e2) "")
  if (length(cls) == 0 || is.na(cls[1])) cls <- ""
  block <- sprintf("[%s] %s%s\n  %s%s\n%s\n\n",
                   stamp, where %||% "", if (nzchar(uid)) paste0(" uid=", uid) else "",
                   if (nzchar(cls)) paste0("[", cls, "] ") else "", msg[1], tb)

  tryCatch({
    if (is.na(p)) return(invisible(NA_character_))
    if (!dir.exists(dirname(p))) {
      dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    }
    # 简单轮转：超过 1MB 就把当前这份挪成 .1（覆盖上一份）。
    # 不做无界追加 —— 一个每 5 秒重试的循环能在一夜之间把磁盘写满，
    # 而"日志把磁盘写满"比"没有日志"严重得多。
    if (file.exists(p) && isTRUE(file.info(p)$size > .dsapp_err$max_bytes)) {
      file.rename(p, paste0(p, ".1"))
    }
    cat(block, file = p, append = TRUE)
  }, error = function(e2) NULL)

  invisible(p)
}

#' 出错时给用户看的那张卡片
#'
#' ⚠️ 文案里**不能**出现工作区路径、SQL、表名、堆栈。用户能做的事只有
#'    "刷新再试"和"把时间告诉管理员"，那就只说这两件。时间戳是给管理员
#'    拿去日志里对齐的，所以要精确到秒而且和日志里用的是同一个时钟。
dsapp_err_card <- function(e = NULL, where = "") {
  stamp <- tryCatch(dsapp_now(), error = function(e2) "")
  bslib::card(
    class = "dsapp-err-card",
    bslib::card_body(
      tags$div(class = "d-flex align-items-center gap-2 mb-2",
        shiny::icon("triangle-exclamation", class = "text-warning"),
        tags$strong("这一块没能显示出来")
      ),
      tags$p(class = "small text-muted mb-2",
        "这多半是暂时性的（正在读写数据、或者上一次操作还没跑完）。",
        tags$strong("刷新一下这个页面"),
        "通常就好了。"),
      tags$p(class = "small text-muted mb-0",
        "如果刷新之后还是这样，把下面这个时间告诉管理员：",
        tags$code(stamp),
        if (nzchar(where %||% "")) tagList(
          "（位置：", tags$code(where), "）"
        )
      )
    )
  )
}

#' 兜住一整页的错误
#'
#' 给 `renderUI("app_root")` 那种**整页级**的 output 用。出错时返回一张
#' 卡片而不是把界面清空 —— 至少左栏和页签还在，用户能切走。
dsapp_err_page <- function(e = NULL, where = "app_root") {
  # ⚠️ 这个函数自己也要能容错：它是在"别的东西已经坏了"的前提下被调用的。
  #    样式表可能没加载、shiny 的 icon() 可能也在报错。所以整块用
  #    tryCatch 兜住，最差也要返回一句话。
  tryCatch(
    tags$div(class = "dsapp-err-page",
      tags$div(class = "alert alert-warning m-3",
        tags$h5(class = "alert-heading",
          shiny::icon("triangle-exclamation"), " 页面没能加载出来"),
        tags$p("这不是你的操作有问题 —— 应用在处理这个页面时遇到了一个内部错误。"),
        tags$p(class = "mb-2",
          "先", tags$strong("刷新一下"),
          "；还不行的话把下面这一行发给管理员，日志里有对应的记录："),
        tags$pre(class = "mb-0 small", style = "white-space:pre-wrap;",
          sprintf("%s  @ %s\n%s", tryCatch(dsapp_now(),
                                           error = function(e2) ""),
                  where %||% "?", tryCatch(conditionMessage(e),
                                           error = function(e2) "")))
      )
    ),
    error = function(e2) tags$p("页面出错了，请刷新重试。")
  )
}

#' 试运行一段代码，出错就记日志并按需给个替身
#'
#' @param expr     要跑的表达式（惰性）
#' @param where    标签，写进日志
#' @param on_error 出错时的返回值。给函数就调用它（拿得到错误对象），
#'                 否则直接用那个值。
#' @return expr 的值，或者 on_error 的结果。**不 rethrow** —— 调用方要的
#'   就是"把这一块让出去，别让整页跟着陪葬"。
dsapp_err_try <- function(expr, where = "", on_error = NULL) {
  trace <- NULL
  hit <- FALSE
  res <- tryCatch(
    withCallingHandlers(
      expr,
      # ⚠️ 调用栈必须在这里抓。放到下面 tryCatch 的 handler 里，拿到的是
      #    handler 那一层的栈，真正出错的位置一行都不在里面。
      error = function(e) {
        trace <<- sys.calls()
        hit <<- TRUE
      }
    ),
    error = function(e) {
      if (!hit) trace <<- sys.calls()
      dsapp_err_log(e, where, trace)
      if (is.function(on_error)) on_error(e) else on_error
    }
  )
  res
}

#' 全局兜底：没人接的错误也进日志
#'
#' `observe` / `observeEvent` / `invalidateLater` 里抛的错，Shiny 默认只在
#' 控制台打一行 `Warning: Error in observe: ...`。控制台是
#' /var/log/shiny-server/ 里那个要 sudo 才读得到的文件 —— 等于没人看得到。
dsapp_err_init <- function() {
  if (isTRUE(.dsapp_err$inited)) return(invisible(FALSE))
  .dsapp_err$inited <- TRUE
  tryCatch(
    shiny::onUnhandledError(function(e) {
      # ★ 被 Shiny 换过消息的那一条**不进日志**：它一个字节的信息都没有
      #   （谁抛的、在哪一行，全在真实错误里，而真实错误由下面的
      #   printError 补丁那一头记下来）。放它进来只会让日志里 577 条
      #   全是一句英文，把真正有用的那几条淹掉 —— 这正是 2026-10-06
      #   那次"整个日志翻遍了也定位不了一次错误"的成因。
      #   ⚠️ 只跳过**这一句**，别顺手把 unhandled 整条路掐掉：没被换过
      #      消息的那些（observe / 定时器 / 子进程回调）还得靠它。
      msg <- tryCatch(conditionMessage(e), error = function(e2) "")
      if (identical(msg, .dsapp_err$sanitized_msg)) return(invisible(NULL))
      tr <- tryCatch(sys.calls(), error = function(e2) NULL)
      dsapp_err_log(e, "unhandled", tr)
    }),
    error = function(e) NULL          # 老版本 shiny 没有这个 API 就算了
  )
  dsapp_err_patch_printerror()
  invisible(TRUE)
}

#' 把「输出渲染」那一路的**真实**报错截下来（V16.7）
#'
#' Shiny 的输出（renderUI / renderText / renderPlot / …）抛错时走两条路：
#'
#'   1. 真实的错误 + 完整堆栈 → `printError()` → **stderr**。线上那是
#'      /var/log/shiny-server/*.log，`shiny:shiny 0640`，连开发者都要 sudo
#'      才读得到（这正是用户看到"去看日志"却根本打不开的那个文件）。
#'   2. 给 `unhandledError` / `onUnhandledError` 的，是一条**消息被换过**的
#'      错误 —— 见 `.dsapp_err$sanitized_msg`。我们唯一能自己写的日志
#'      （app_error.log）走的就是这条，所以它以前只装得下一句英文。
#'
#' 修法是给 `shiny:::printError` **套一层**：错误到那儿时消息还没被换、
#' 栈还在，而且它是**一个函数**，套一次覆盖全应用所有 output ——
#' 不用去动每一个 `renderUI`（那有几百处，改漏一处就又白记一次）。
#' 套完照常调用原函数，控制台/系统日志里的样子一个字节都不变。
#'
#' ⚠️ 只加日志，不改行为。套不上（换了 Shiny 版本、绑定锁着）就
#'    **什么都不做**并记一笔 —— 宁可回到"记不到"，也不能把错误处理本身
#'    弄坏（那连日志都拿不到了）。
dsapp_err_patch_printerror <- function() {
  if (isTRUE(.dsapp_err$pe_patched)) return(invisible(TRUE))
  orig <- tryCatch(get("printError", envir = asNamespace("shiny")),
                   error = function(e) NULL)
  if (!is.function(orig)) {
    tryCatch(dsapp_err_log(simpleError(
      "shiny:::printError 找不到，输出渲染的真实报错这一版记不下来（换过 Shiny 版本？）"),
      "patch_printerror"), error = function(e) NULL)
    return(invisible(FALSE))
  }
  patched <- function(cond) {
    tryCatch({
      msg <- tryCatch(conditionMessage(cond), error = function(e2) "")
      if (!identical(msg, .dsapp_err$sanitized_msg)) {
        # where 用 "output" 而不是 "unhandled"：这一条是**渲染那一路**的，
        # 而且它是真实消息。日志里出现 `where=output` = 找到一个能定位的错了，
        # 与之配对的 `where=unhandled` 那句英文才是它的影子。
        dsapp_err_log(cond, "output", sys.calls())
      }
    }, error = function(e2) NULL)
    orig(cond)
  }
  ok <- tryCatch({
    utils::assignInNamespace("printError", patched, ns = "shiny")
    TRUE
  }, error = function(e) {
    tryCatch(dsapp_err_log(e, "patch_printerror"), error = function(e2) NULL)
    FALSE
  })
  .dsapp_err$pe_patched <- ok
  invisible(ok)
}

#' 软错误不再判会话死刑（V15.6 第 4 条）
#'
#' ★★ 用户报「经常运行一半弹『与服务器的连接断了』，看一下是不是 APP 写的
#'    有 bug」。**是 APP 的 bug —— 但不在心跳那头，心跳只是症状。**
#'
#' 机理（Shiny 的设计如此，不是这个应用写的）：
#'   `observe` / `observeEvent` / 定时器里抛出没人接的错误时，
#'   `Observer$.createContext()` 注册的那段 catch 会调用
#'   `domain$unhandledError(e, close = TRUE)`（Shiny 源码原样），而
#'   `ShinySession$unhandledError()` 的最后一句是 `if (close) self$close()`
#'   —— **把整个会话关掉**。会话一关：
#'     · 它名下的定时器全被清掉（`invalidateLater` 注册时挂了 onEnded 清理，
#'       所以心跳也一起没了）
#'     · 前端的 socket 断开 → www/app.js 弹「与服务器的连接断了」
#'     · 这之后点什么都没反应，直到刷新
#'   而 R 进程活得好好的（别的会话、别的用户一点事都没有），日志里也只是一条
#'   Warning —— 从服务端看完全不像"用户整页死了"。
#'
#' 2026-09-30 实测（同一个进程、同一颗炸弹，只换抛错的位置）：
#'   炸弹放 `renderText` 里 → 会话活着、心跳照跳、点击正常（Shiny 自己就把
#'                           渲染错误兜住了，画成一张报错卡片）
#'   炸弹放 `observe` 里    → 心跳停在第 7 跳、onEnded 当场触发、浏览器收到
#'                           `shiny:disconnected`  ← 就是用户报的那一幕
#'   复现用的最小应用和探针：tests/err_guard/（改代码前先跑一遍）
#'
#' 修法：把**这个会话**的 `unhandledError` 换成"照原样走一遍、但 close 一律
#' 传 FALSE"。原来该做的全都在（错误照进 app_error.log、onUnhandledError 的
#' 回调照调、控制台照打），只是**不再关会话** —— 于是坏掉的是那一个输出，
#' 用户看到的是"这一块没出来"，而不是"整个应用失联"。
#'
#' ⚠️ 为什么在**实例**上换，而不是打类（generator）的补丁：R6 在 `$new()` 时
#'    会把实例方法的环境整个换掉，闭包里捕获的东西到那时就没了 —— 试过，报的
#'    是 `could not find function "orig"`。而实例本身就是个 environment，
#'    `$<-` 进去的闭包环境归我们自己，稳。
#' ⚠️ R6 会把实例上的方法绑定**锁住**（`bindingIsLocked()` 为 TRUE），所以先
#'    `unlockBinding()`。这是 R 的正式 API：它锁的是"防止外部改写"，而这里改的
#'    正是我们自己的那个会话对象。
#' ⚠️ 想清楚再用：会话**不再因为报错自动关闭**。真出现"会话状态已经乱了"的
#'    情况，它会带着坏状态继续跑（而不是断开重来）。判断依据是：这是个长任务
#'    应用，用户很可能正盯着跑了几分钟的分析，**丢会话的代价远大于留一个坏
#'    输出**；而"服务端真的不吭声了"那条路另有兜底（app.R 的心跳 +
#'    www/app.js 的 DSAPP_PING_DEAD_MS），该报的照样报。
#'    要退回 Shiny 原行为：删掉 server() 开头那一行调用就行。
#'
#' @return 装上了 TRUE；结构对不上（换了 Shiny 版本）FALSE —— 那时**什么都不做**，
#'   宁可回到"报错判死"，也不能把错误处理本身弄坏（那连日志都拿不到了）。
dsapp_err_soften_session <- function(session) {
  orig <- tryCatch(session$unhandledError, error = function(e) NULL)
  if (!is.function(orig) || !("close" %in% names(formals(orig)))) {
    tryCatch(
      dsapp_err_log(simpleError(
        "unhandledError 的形状和预期不一样，软错误守卫没装上（换过 Shiny 版本？）"),
        "soften_session"),
      error = function(e) NULL)
    return(invisible(FALSE))
  }
  if (isTRUE(bindingIsLocked("unhandledError", session))) {
    tryCatch(unlockBinding("unhandledError", session), error = function(e) NULL)
  }
  session$unhandledError <- function(e, close = TRUE) orig(e, close = FALSE)
  invisible(TRUE)
}

#' 最近几条错误（后台页用）
#'
#' 直接把日志尾巴原样给平台管理员看 —— 他要的就是"刚才那个时间点出了什么事"，
#' 在这儿重新排版一遍反而会把堆栈截断。**只给平台管理员**（调用方把关）。
#'
#' @param n 最多几行（按块切，不是按行）
dsapp_err_recent <- function(n = 5L, cfg = dsapp_config()) {
  p <- tryCatch(dsapp_err_log_path(cfg), error = function(e) NA_character_)
  if (is.na(p) || !file.exists(p)) return(character(0))
  txt <- tryCatch(readLines(p, warn = FALSE), error = function(e) character(0))
  if (length(txt) == 0) return(character(0))
  # 每个块以 "[时间戳] " 开头（见 dsapp_err_log 的 sprintf）。
  starts <- grep("^\\[", txt)
  if (length(starts) == 0) return(utils::tail(txt, 60))
  starts <- c(starts, length(txt) + 1L)
  k <- length(starts) - 1L
  from <- max(1L, k - as.integer(n) + 1L)
  utils::tail(txt[starts[from]:(starts[k + 1L] - 1L)], 200)
}
