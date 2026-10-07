# =============================================================================
# 列表的筛选与状态显示（任务页、管理页用户表）
# =============================================================================
# 这两个函数本身没什么难的，单独拎出来是因为**放在哪里决定了能不能被测**：
# R/mod_*.R 里的代码要跑起来需要一个 Shiny 会话（selftest 直接跳过整个
# mod_* 文件），所以筛选逻辑写在 reactive 里就等于没有测试覆盖。
#
# 而这段逻辑恰恰是**界面看不出错**的那一类：
#
#   任务页和管理页的用户表都是"上面一个表、下面一排按钮作用在选中的那一行"，
#   而选中是按**行号**回查数据的：
#
#       input$tbl_rows_selected  →  df$id[i]
#
#   只要筛选和交给 DT 的数据不是同一份，行号就指向另一条记录 —— 于是「删除」
#   删掉的是别人那条任务，「停用」停用的是另一个账号。界面上完全看不出来，
#   用户看到的就是自己选的那一行。文件页最早踩到这个坑（见 dsapp_files_order）。
#
# 所以这里的两条硬约定：
#
#   1. **筛选必须做在把数据交给 DT 之前**，而且只做一次。调用方拿到结果要
#      原样交给 DT，不能再在外面筛一遍。
#   2. **顺序不能变**。DT 的行号 = 数据框的行号；筛完重排（比如按相关度）
#      就等于换了一批记录，而界面上的行号还是那个行号。
#
# 返回值一律是 data.frame（不是 NULL、不是空向量），调用方直接 nrow()。
# =============================================================================

# ---------------------------------------------------------------------------
# 任务页
# ---------------------------------------------------------------------------

#' 任务表的状态筛选选项
#'
#' 值和 executor.R 里真正写库的那几个状态**必须**对得上（success / failed /
#' timeout / error / running / pending，见 dsapp_run_code 末尾和 app.R 的
#' db_task_status 调用点）。写错一个字母的后果是"选了这一项永远筛出 0 条"，
#' 而界面上看不出是筛错了还是真没有 —— 所以集中定义一处，selftest 里再拿它
#' 和库里的实际值对一遍。
DSAPP_TASK_STATUS_CHOICES <- c(
  "（全部状态）" = "", "成功" = "success", "失败" = "failed",
  "错误" = "error", "超时" = "timeout", "运行中" = "running",
  "待执行" = "pending")

#' 任务状态的显示文案
#'
#' ⚠️ 必须和 DSAPP_TASK_STATUS_CHOICES **一一对应**，一个都不能漏。
#'    这里漏掉一个的后果不是空白而是**显示成别的状态**：原来的实现是
#'    `switch(s, success=…, failed=…, timeout=…, running=…, "· 待执行")`，
#'    `error` 没有分支，于是**出错的任务在列表里显示成「待执行」** ——
#'    用户看到的是"我的任务还没跑"，实际上是跑挂了。走查时抓到过这个
#'    （手动停止的任务写库就是 error，停下来之后显示成"待执行"）。
#'    selftest 里有一条把两边对齐。
#'
#' 认不出来的状态**原样显示**而不是兜到「待执行」（同 dsapp_audit_label）：
#' 以后新增状态时，宁可让人看见一个没翻译的英文码，也不要撒谎说它没跑。
DSAPP_TASK_STATUS_LABELS <- c(
  success = "✓ 成功", failed = "✗ 失败", error = "✗ 错误",
  timeout = "⏱ 超时", running = "▶ 运行中", pending = "· 待执行")

#' 状态码 → 表格里的显示文案
dsapp_status_label <- function(status) {
  # ⚠️ 不要写成 `status %||% character(0)`：utils.R 的 %||% 会把 NA 也换成
  #    兜底值，于是"状态是 NA"这一行整个消失（表格里少一行，不是显示成「—」）。
  #    as.character(NULL) 本来就是 character(0)，NULL 也不用特判。
  s <- as.character(status)
  lab <- unname(DSAPP_TASK_STATUS_LABELS[s])
  ifelse(is.na(lab), ifelse(is.na(s), "—", paste0("· ", s)), lab)
}

#' 执行状态徽章（详情页顶部那个彩色的）
dsapp_status_badge <- function(status) {
  s <- as.character(status %||% "")[1] %||% ""
  spec <- switch(s,
    success = list("成功", "success"),
    failed  = list("失败", "danger"),
    error   = list("错误", "danger"),
    timeout = list("超时", "warning"),
    running = list("运行中", "primary"),
    pending = list("待执行", "secondary"),
    # 认不出来就原样显示。**不能**兜到「待执行」——那是在说假话。
    list(if (nzchar(s)) s else "未知", "secondary")
  )
  tags$span(class = paste0("badge text-bg-", spec[[2]]), spec[[1]])
}

#' 按状态和关键词筛任务表
#'
#' @param df     db_tasks_list() 的结果
#' @param status 状态码，""/NULL = 全部
#' @param kw     关键词，在标题和代码里找（fixed = TRUE，不当正则）
dsapp_filter_tasks <- function(df, status = NULL, kw = NULL) {
  if (is.null(df) || nrow(df) == 0) return(df)

  st <- as.character(status %||% "")[1] %||% ""
  if (!is.na(st) && nzchar(st)) df <- df[df$status == st, , drop = FALSE]

  kw <- trimws(as.character(kw %||% "")[1] %||% "")
  if (!is.na(kw) && nzchar(kw) && nrow(df) > 0) {
    # 代码也搜。这一页常见的两个问题分别是"那个跑失败的任务叫什么"
    # 和"哪个任务里读了 GSE123" —— 前者靠标题，后者只能靠代码。
    #
    # 用 fixed = TRUE：用户搜的是文件名、函数名，里面有 . ( ) 之类的正则
    # 元字符，当正则解释会搜不到（write.csv 的 . 会匹配任意字符，反而搜出
    # 一堆不相干的）。
    #
    # ⚠️ 这里**不能**用 %||% 兜底。utils.R 里的 %||% 是
    #    `if (is.null(a) || length(a) == 0 || is.na(a[1])) b else a` ——
    #    它看的是**第一个元素**。df$title 是向量，只要第一条任务的标题是
    #    NA（老行、或者提交时没给标题），`df$title %||% rep("", n)` 就会把
    #    **整列**换成空串，于是搜什么都没有结果，而界面上看起来完全正常。
    #    这个坑是 selftest 抓出来的。
    #
    # ⚠️ NA 也要换成空串：NA 参与 | 的结果是 NA，df[NA, ] 会筛出一片空行。
    t_ <- df$title; if (is.null(t_)) t_ <- rep("", nrow(df))
    c_ <- df$code;  if (is.null(c_)) c_ <- rep("", nrow(df))
    t_ <- as.character(t_); c_ <- as.character(c_)
    t_[is.na(t_)] <- ""; c_[is.na(c_)] <- ""
    df <- df[grepl(kw, t_, fixed = TRUE) | grepl(kw, c_, fixed = TRUE), ,
             drop = FALSE]
  }
  df
}

# ---------------------------------------------------------------------------
# 管理页：用户表
# ---------------------------------------------------------------------------

#' 用户表的密码状态筛选选项
#'
#' 三档，和表格里那一列（无密码 / 已设 / 待改密）一一对应。三档而不是两档
#' 的原因很实在：强制改密的账号**是**有 pass_hash 的（管理员给了个临时密码），
#' 只有两档的话，"还有谁欠着一次改密"就混进「已设」里找不出来了。
#' 重跑时的标题
#'
#' 重跑要在标题上留个痕（否则列表里分不清哪条是原跑哪条是重跑），但**只留
#' 一次**：连着重跑 9 次的话，标题会变成「[重跑] [重跑] … 长任务（重跑用）」，
#' 表格列宽一截，"长任务"这四个字直接被挤出可视区 —— 走查时就是这么发现的，
#' 列表里一排条目长得一模一样，只看得到「[重跑]」。
#'
#' 这是显示逻辑不是业务逻辑，放这里是为了让 selftest 够得着（它跳过所有
#' mod_*.R，见 selftest.R 顶部的说明）。
dsapp_rerun_title <- function(title) {
  t <- as.character(title %||% "")[1] %||% ""
  if (!nzchar(t)) return("重跑")
  if (startsWith(t, "[重跑] ")) t else paste0("[重跑] ", t)
}

DSAPP_USER_PW_CHOICES <- c("（全部密码状态）" = "", "无密码" = "none",
                           "已设" = "set", "待改密" = "must")

#' 按条件筛用户表
#'
#' @param df  dsapp_users_list() 的结果，且**已经带上** has_pw / must_pw 两列
#'            （由 mod_admin.R 的 users_all() 补上）
#' @param kw  关键词，在昵称/邮箱/研究方向里找（fixed = TRUE）
#' @param role ""/"admin"/"user"
#' @param status ""/"active"/"disabled"
#' @param pw   ""/DSAPP_USER_PW_CHOICES 的值
dsapp_filter_users <- function(df, kw = NULL, role = NULL, status = NULL,
                               pw = NULL) {
  if (is.null(df) || nrow(df) == 0) return(df)

  # 缺列时补 NA 而不是报错：管理页是出事后唯一能操作的地方，不能因为某个
  # 老库少一列（V5 的几列都是 ALTER TABLE 加上去的）就整个打不开。
  col <- function(nm) {
    v <- df[[nm]]
    if (is.null(v)) rep(NA, nrow(df)) else v
  }

  kw <- trimws(as.character(kw %||% "")[1] %||% "")
  if (!is.na(kw) && nzchar(kw) && nrow(df) > 0) {
    # fixed = TRUE：搜的是邮箱，里面有 . 和 @，当正则解释会搜出不相干的。
    # NA 同样先换成空串（理由见 dsapp_filter_tasks）。
    hit <- rep(FALSE, nrow(df))
    for (nm in c("nickname", "email", "field")) {
      v <- as.character(col(nm)); v[is.na(v)] <- ""
      hit <- hit | grepl(kw, v, fixed = TRUE)
    }
    df <- df[hit, , drop = FALSE]
  }

  role <- as.character(role %||% "")[1] %||% ""
  if (nrow(df) > 0 && identical(role, "admin"))
    df <- df[as.integer(col("is_admin")) == 1L, , drop = FALSE]
  # != 不是 == 0：老行的 is_admin 可能是 NULL/NA，那些是普通用户而不是
  # "既不是管理员也不是用户"的第三类 —— 界面上的 ifelse(is_admin == 1, ...)
  # 也是这么分的，两边必须一致，否则筛"用户"会漏掉一批人。
  if (nrow(df) > 0 && identical(role, "user"))
    df <- df[as.integer(col("is_admin")) != 1L, , drop = FALSE]

  stt <- as.character(status %||% "")[1] %||% ""
  # NA 的 status 归到「停用」：表格那一列写的是
  # ifelse(status == "active", "启用", "停用")，NA 显示出来就是"停用"。
  # 筛选和显示不一致的话，用户会看到"筛停用筛不出这个明明写着停用的账号"。
  if (nrow(df) > 0 && identical(stt, "active"))
    df <- df[!is.na(col("status")) & col("status") == "active", , drop = FALSE]
  if (nrow(df) > 0 && identical(stt, "disabled"))
    df <- df[is.na(col("status")) | col("status") != "active", , drop = FALSE]

  pwf <- as.character(pw %||% "")[1] %||% ""
  if (nrow(df) > 0 && !is.na(pwf) && nzchar(pwf)) {
    # 「待改密」优先于「已设」：待改密的账号 has_pw 也是 1，按"有没有密码"
    # 归到「已设」里的话，"还有谁欠着一次改密"这个筛选就永远是空的。
    has  <- as.integer(col("has_pw"))
    must <- as.integer(col("must_pw"))
    keep <- switch(pwf,
      none = !is.na(has) & has == 0L,
      must = !is.na(must) & must == 1L,
      set  = !is.na(has) & has == 1L & (is.na(must) | must != 1L),
      rep(FALSE, nrow(df)))
    keep[is.na(keep)] <- FALSE
    df <- df[keep, , drop = FALSE]
  }
  df
}
