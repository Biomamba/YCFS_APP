# =============================================================================
# 按账号共享（item 7）
# =============================================================================
# 共享的**单位是对话**，不是单条任务。
#
# 为什么不做成"一条任务共享给一个人"：一个对话就是一块工作区、一个环境
# （见 utils.R 的 dsapp_ws_dir），任务之间靠工作区里的文件接力 —— 上游任务
# 写出的 results/expr_clean.csv，下游任务读它。只共享一条任务的话，对方看到
# 的是一段读不到输入的代码和一张孤零零的图，"查看"这个动作本身就没有意义。
# 所以：**选中任务 → 共享的是它所在的那个对话**，界面上把这句话说明白。
#
# 这个文件是共享的唯一实现：候选账号怎么筛、弹窗长什么样、写库前怎么复查
# 权限。言出法随页和任务页都从这里调 —— 各写一份的话迟早分叉，而分叉的
# 表现是"从任务页共享出去的人能改数据"，不是样式对不齐。
#
# ⚠️ 这里只放**共用的**部分。"保存"那一步各页各写（两边判权限用的东西不
#    同：对话页看 sess_role()，任务页看选中任务反查出来的 current_role()），
#    但两处都必须满足同一条不变式：**写库之前再查一次权限**，而且查出来
#    没权限就 return，不能只是关个弹窗接着写（见 selftest 里那条查位置关系
#    的断言）。
# =============================================================================

#' 可以共享给谁 —— 按"同组优先，其它手填"分两拨
#'
#' V13 item 3 之前这里返回**全站所有账号**，共享框是一个几十项的长名单；
#' 用户要的是「组内账户可以选择，分享给其它账户需要手动填写」。
#'
#' 排除两类账号，两类都是**排除而不是灰掉**：
#'   · 自己 —— 共享给自己是无意义操作，而且会让人以为自己丢了所有权；
#'   · 停用的账号 —— 选了也登不进来，只会让 owner 以为"我已经共享给他了"。
#'
#' @return list(mates = data.frame, others = data.frame, all = data.frame)；
#'   每一拨可能是一行都没有的 data.frame（**不是 NULL** —— 调用方要能直接
#'   nrow()，不必到处判空）
dsapp_share_candidates <- function(state, cfg = dsapp_config()) {
  empty <- function() data.frame(id = integer(0), nickname = character(0),
                                 email = character(0),
                                 stringsAsFactors = FALSE)
  us <- tryCatch(dsapp_users_list(con = dsapp_db(cfg)),
                 error = function(e) NULL)
  if (is.null(us) || nrow(us) == 0) {
    return(list(mates = empty(), others = empty(), all = empty()))
  }

  # ⚠️ as.integer()：state$user_id 在某些路径上是字符（cookie / 查询串里
  #    来的），而 us$id 是整数。不转的话 `us$id != "3"` 会走字符比较，
  #    "10" != "3" 是 TRUE —— 10 号账号会莫名其妙地出现在自己的候选名单里。
  me <- suppressWarnings(as.integer(state$user_id %||% NA_integer_))
  us <- us[is.na(us$id) | us$id != me, , drop = FALSE]
  us <- us[as.character(us$status) == "active", , drop = FALSE]
  if (nrow(us) == 0) {
    return(list(mates = empty(), others = empty(), all = empty()))
  }

  mates <- tryCatch(dsapp_user_teammates(me, con = dsapp_db(cfg)),
                    error = function(e) integer(0))
  is_mate <- us$id %in% mates
  list(mates  = us[is_mate, , drop = FALSE],
       others = us[!is_mate, , drop = FALSE],
       all    = us)
}

#' 候选账号 → checkboxGroupInput 的 choices
#'
#' 标签里带上邮箱：昵称可以重名（也可以留空），邮箱不会。
dsapp_share_choices <- function(us) {
  if (is.null(us) || nrow(us) == 0) return(character(0))
  stats::setNames(as.character(us$id),
                  sprintf("%s（%s）", us$nickname, us$email))
}

#' 手填的邮箱 → user id
#'
#' 一行一个，也容忍逗号/分号/空格分隔 —— 用户很自然会一次粘一串进来。
#' 大小写不敏感（邮箱本来就是），**首尾空格要去掉**（从邮件里复制出来的
#' 几乎总带着）。
#'
#' ⚠️ 认不出来的邮箱**不报错、也不丢**：逐个回给调用方，由界面上说清楚
#'    "这几个没找到"。直接静默丢掉的话，用户会以为共享成功了 —— 这正是
#'    共享功能最不能出的错（他以为对方能看到，实际看不到；或者反过来）。
#'
#' @return list(ids = 整数向量, unknown = 字符向量, self = 逻辑)
dsapp_share_resolve_emails <- function(text, me = NULL, con = dsapp_db()) {
  raw <- as.character(text %||% "")
  parts <- unlist(strsplit(raw, "[[:space:],;，；]+"))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return(list(ids = integer(0), unknown = character(0),
                                  self = FALSE))
  parts <- unique(tolower(parts))
  me <- suppressWarnings(as.integer(me %||% NA_integer_))

  ids <- integer(0); unknown <- character(0); hit_self <- FALSE
  for (em in parts) {
    u <- tryCatch(dsapp_user_by_email(em, con = con),
                  error = function(e) NULL)
    # ⚠️ 这里**不能**写 `!nrow(u)`。
    #
    #    dsapp_user_by_email() 走的是 dsapp_user_row()，回来的是
    #    `as.list(d[1, , drop = FALSE])` —— 一个 **list**，不是 data.frame。
    #    `nrow()` 对 list 返回 NULL，而 `!NULL` 不报"长度为 0"，报的是
    #    **`invalid argument type`** —— 一句和"这个人没找到"毫无关系的错，
    #    而且它是在 tryCatch 之外抛的，会把整个共享流程打断。
    #    （2026-09-16 自检里踩到：手填邮箱那九条断言全红在这上面。）
    #
    #    判"查没查到"只需要 is.null() —— 查不到时 dsapp_user_row 返回 NULL。
    if (is.null(u) || !length(u)) { unknown <- c(unknown, em); next }
    uid <- as.integer(u$id[[1]])
    if (!is.na(me) && identical(uid, me)) { hit_self <- TRUE; next }
    if (!identical(as.character(u$status[[1]]), "active")) {
      unknown <- c(unknown, em); next
    }
    ids <- c(ids, uid)
  }
  list(ids = unique(ids), unknown = unknown, self = hit_self)
}

#' 共享弹窗
#'
#' @param ns 调用方的命名空间函数
#' @param intro 弹窗顶部那段说明（tagList）。**必须说清楚共享的范围** ——
#'   用户点的是"共享这条任务"，实际共享出去的是整个对话，不说明白就是
#'   在替用户做他不知道的决定。
#' @param mates 同组候选（dsapp_share_candidates()$mates）
#' @param selected 当前已经共享给谁（user id 的整数向量）
#' @param others 非本组的候选（$others）—— 只用来把当前名单里的外部账号
#'   翻译成邮箱回填进输入框
#'
#' @return 弹窗里那个文本域的初值：**当前共享名单中、不在我组里的那些人的
#'   邮箱**。回填是必须的 —— 不回填的话，用户改一次名单（哪怕只是多加一个
#'   组内同事）就会把之前手填的外部账号全部冲掉，而界面上看不出这件事。
dsapp_share_modal <- function(ns, intro, mates, selected, others = NULL) {
  sel <- as.integer(selected %||% integer(0))
  mate_ids <- as.integer(mates$id %||% integer(0))
  prefill <- character(0)
  if (length(sel) && !is.null(others) && nrow(others)) {
    hit <- others$id %in% sel
    if (any(hit)) prefill <- as.character(others$email[hit])
  }

  showModal(modalDialog(
    title = "共享这个对话",
    div(class = "small text-muted mb-2", intro),

    if (length(mate_ids)) {
      tagList(
        tags$label(class = "form-label mb-1", "同组账号"),
        # 传 NULL 而不是空字符串：空串会让 Shiny 渲染出一个值为 "" 的选项，
        # 提交时多出来一个不存在的 user id。
        checkboxGroupInput(ns("share_ids"), NULL,
                           choices = dsapp_share_choices(mates),
                           selected = as.character(sel[sel %in% mate_ids]))
      )
    } else {
      div(class = "small text-muted fst-italic mb-2",
          "你还没有加入任何团队 —— 想让同事出现在这里，请管理员在「管理 → 团队」里把你和他分到一组。")
    },

    textAreaInput(ns("share_emails"),
                  "其它账号（手填邮箱，一行一个）",
                  value = paste(prefill, collapse = "\n"),
                  rows = 3, width = "100%",
                  placeholder = "someone@example.com"),

    div(class = "small text-muted",
      icon("circle-info"), " 取消勾选、或把邮箱从框里删掉即撤回；撤回后对方立刻看不到。"),
    footer = tagList(
      modalButton("取消"),
      actionButton(ns("do_share"), "保存", class = "btn-primary")
    )
  ))
  invisible(prefill)
}

#' 弹窗里两拨输入合起来 → 最终的 user id 名单
#'
#' 对话页和任务页的保存路径都用这一条，免得两边各写一遍解析逻辑（两边对
#' "填错了怎么办"的处理一旦分叉，就会出现"从任务页共享能成功、从对话页
#' 共享静默少一个人"这种事）。
#'
#' @return list(ids = 整数向量, unknown = 字符向量, self = 逻辑)
dsapp_share_collect <- function(ids, emails, me, con = dsapp_db()) {
  a <- suppressWarnings(as.integer(ids %||% integer(0)))
  a <- unique(a[!is.na(a)])
  b <- dsapp_share_resolve_emails(emails, me = me, con = con)
  list(ids = unique(c(a, b$ids)), unknown = b$unknown, self = b$self)
}

#' 查某段对话对当前账号来说是什么角色
#'
#' 共享的每一道闸门都是"这个角色能不能写"。**查不动的时候必须是 none** ——
#' 数据库繁忙、schema 对不上、连接断了，这些都会让 db_session_role() 抛异常，
#' 而抛异常那一刻的正确行为是"谁也写不了"，不是"谁都能写"。
#'
#' 这么做还顺带把这个默认值变成**可测的**：selftest 拿一个没有 sessions 表的
#' 库去调它，看回来的到底是不是 none（写在页面里的 tryCatch 测不到）。
#'
#' @return "admin" / "owner" / "shared" / "none"
dsapp_share_role <- function(sid, state, cfg = dsapp_config(),
                             con = dsapp_db(cfg)) {
  tryCatch(
    db_session_role(sid, state$user_id,
                    is_admin = dsapp_user_is_platform_admin(state$user),
                    con = con),
    error = function(e) "none")
}

#' 一段对话已经共享给了谁
#'
#' @return 整数向量（可能长度为 0）
dsapp_share_current_ids <- function(sid, cfg = dsapp_config()) {
  cur <- tryCatch(db_session_share_list(sid, con = dsapp_db(cfg)),
                  error = function(e) NULL)
  if (is.null(cur) || nrow(cur) == 0) return(integer(0))
  as.integer(cur$user_id)
}

#' 保存完之后统一给一句反馈（两页共用）
#'
#' 认不出来的邮箱**必须说出来**。这是共享这个功能里唯一"看起来成功了、其实
#' 没有"的失败方式：用户填了 `boss@lab.edu`，少打一个字母，点保存，界面
#' 弹一句"已共享给 1 个账号" —— 他以为共享出去了。过了两天对方说没收到，
#' 谁也说不清是哪一步的问题。
dsapp_share_notify <- function(col, n) {
  if (length(col$unknown)) {
    # ⚠️ dsapp_md_inline() 收进去的是**整句 sprintf 的结果**，不是那个格式串 ——
    #    邮箱是用户填的，转义必须发生在拼好之后（见 R/utils.R 里那段说明）。
    showNotification(dsapp_md_inline(sprintf(
                       "这几个邮箱没找到对应账号，**没有**共享给他们：%s",
                       paste(utils::head(col$unknown, 5), collapse = "、"))),
                     type = "warning", duration = 12)
  }
  if (isTRUE(col$self)) {
    showNotification("其中包含你自己的邮箱，已跳过。", type = "warning", duration = 8)
  }
  showNotification(if (isTRUE(n > 0)) sprintf("已共享给 %d 个账号", n)
                   else "已取消全部共享", type = "message", duration = 5)
}

#' 保存共享名单（两页共用）
#'
#' ⚠️ 权限**不在这里判** —— 调用方必须自己先判、判完 return。做成"传一个
#'    角色进来、没权限就返回 NULL"的话，将来有人漏传参数，默认值就是
#'    "不拦"，而这条路的默认值必须是"拦"。
#'
#' @return 保存后的共享人数；出错返回 NULL（已经弹过提示了）
dsapp_share_save <- function(sid, ids, state, cfg = dsapp_config()) {
  tryCatch(
    db_session_share_set(sid, ids %||% character(0),
                         granted_by = state$user_id, con = dsapp_db(cfg)),
    error = function(e) {
      # ★ V13.7 item 2：原来这里直接把 conditionMessage(e) 摆到界面上 ——
      #   那多半是一句 `database is locked` 之类的英文原文，对这个用户没有
      #   任何信息量，只会让他以为是自己选错了账号。原文走审计日志，
      #   界面上只说「哪一步没成、现在怎么办」；共享名单本身没写坏，
      #   再点一次就行，所以那句提示是实话。
      showNotification(
        dsapp_err_user(e, "保存共享名单",
                       hint = "名单没有被改坏，直接再点一次就好。"),
        type = "error", duration = 8)
      NULL
    })
}
