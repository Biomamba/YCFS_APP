# =============================================================================
# 皮肤（V8 item 4）
# =============================================================================
# 用户的原话：「设置中加一个皮肤选择模块，明亮和黑暗主体必须要有，有其它酷炫
# 的主题例如 ChatGPT 主题、claude 主题、apple 主题也可以加入备选」。
#
# ---- 这套东西怎么分工的 ------------------------------------------------------
#
#   这一份文件（R/skins.R）  ：有哪几个皮肤、每个叫什么、用户选了哪个、
#                             选完怎么落库。**不含任何颜色值。**
#   www/skins.css          ：每个皮肤的颜色值，按 `:root[data-skin="id"]`。
#   浏览器                  ：`<html data-skin="id">` 一变，整站颜色就跟着变，
#                             不经过服务端、不重渲染、不刷新页面。
#
#   分界线的位置不是随便划的：**"有哪几个"是服务端的事，"长什么样"是客户端的
#   事**。所以加一个皮肤要同时改这两处，而 R 这边永远不需要知道 #d97757 是
#   什么颜色 —— 反过来，CSS 那边也不需要知道用户是谁。
#
# ---- 两条不能动的约束 --------------------------------------------------------
#
# ★★ 不要为了"让服务端也知道主题色"去动 `shinyOptions(bootstrapTheme=...)`。
#    那一格是**全局**的（整个 R 进程一份，所有会话共用），而皮肤是每账号各自
#    的 —— 按会话改它等于改别人的界面。更要命的是它是左栏导航能不能点的关键
#    （见 app.R:503 那段长注释：删掉它，左栏每一项都点不动，且不报任何错）。
#    所以 bslib 那套主题**永远保持深色**，只负责让 bslib 的渲染钩子认得出来；
#    看得见的颜色全部由 skins.css 覆盖。这也是为什么每个皮肤都必须把
#    `--bs-*` 整套写全：没人替它兜底。
#
# ★★ `data-skin` 必须挂在 `<html>` 上，不是 `<body>`。
#    Bootstrap 自己的变量定义在 `:root` 上（= html），而弹窗、下拉菜单这些
#    是挂在 body 直属的（.modal 就在 body 下），body 上的属性选不中它们；
#    html 上的能选中整棵树。app.R 的 head 里那段内联脚本也是往
#    documentElement 上写，两边必须是同一个元素。
# =============================================================================

#' 皮肤名册
#'
#' 顺序就是界面上展示的顺序：**深色和明亮排在最前面** —— 用户说的是"这两
#' 个必须要有"，其它几个是"也可以加入备选"，主次在界面上就该看得出来。
#'
#' `chips` 是设置页那张选择卡上的色块，纯展示用（服务端不拿它做任何判断）。
#' 它必须和 www/skins.css 里那个皮肤的实际取值**对得上** —— 对不上的话，
#' 用户看着一张绿色的卡点下去，界面变成蓝色，这比没有预览更糟。
#' 改配色时两处一起改；tests/ui_v8/skins.py 会核对。
#'
#' `dark = TRUE` 的那个决定了"没有账号时"和"读不到时"回落到哪个 —— 见
#' dsapp_skin_default()。
DSAPP_SKINS <- list(
  dark = list(
    label = "深色",
    hint  = "默认。长时间看代码不刺眼",
    dark  = TRUE,
    chips = c("#0d1117", "#161b22", "#3fb950", "#e6edf3")
  ),
  light = list(
    label = "明亮",
    hint  = "白底深字，投屏和打印友好",
    dark  = FALSE,
    chips = c("#ffffff", "#f6f8fa", "#1a7f37", "#1f2328")
  ),
  chatgpt = list(
    label = "ChatGPT",
    hint  = "中性灰 + 青绿点缀，圆角更大",
    dark  = TRUE,
    chips = c("#212121", "#171717", "#10a37f", "#ececec")
  ),
  claude = list(
    label = "Claude",
    hint  = "暖白 + 陶土橙，观感柔和",
    dark  = FALSE,
    chips = c("#faf9f5", "#f2efe7", "#a04a26", "#2b2a27")
  ),
  apple = list(
    label = "Apple",
    hint  = "冷灰底 + 苹果蓝，边界极淡",
    dark  = FALSE,
    chips = c("#f5f5f7", "#fbfbfd", "#0071e3", "#1d1d1f")
  )
)

#' 全部皮肤 id（按展示顺序）
dsapp_skin_ids <- function() names(DSAPP_SKINS)

#' 默认皮肤
#'
#' 取名册里第一个 `dark = TRUE` 的，而不是写死 "dark" —— 万一以后把默认换成
#' 别的深色皮肤，这里不用跟着改。
dsapp_skin_default <- function() {
  for (id in names(DSAPP_SKINS)) if (isTRUE(DSAPP_SKINS[[id]]$dark)) return(id)
  names(DSAPP_SKINS)[[1]]
}

#' 把任意输入收敛成一个合法皮肤 id
#'
#' ⚠️ 这个函数是**必须**的，不是防御性编程。皮肤 id 有两条来路：
#'    · 数据库 `users.skin` —— 老库升级上来时这一列是 NULL；管理员手工改过库、
#'      或者某个皮肤的 id 在新版本里被改名，库里就会留着一个**曾经合法**的
#'      值。直接拿去拼 `data-skin="..."` 会得到一个没有任何 CSS 匹配的元素，
#'      全站回落到 bslib 那份深色主题 —— 看着"还行"，但设置页里选中的那一项
#'      是空的，用户以为设置没保存。
#'    · 浏览器的 localStorage（app.R 的 head 内联脚本）。
#'    两条路都必须先过这里。
dsapp_skin_norm <- function(id) {
  id <- tryCatch(as.character(id)[1], error = function(e) NA_character_)
  if (length(id) != 1 || is.na(id) || !nzchar(id)) return(dsapp_skin_default())
  if (!id %in% names(DSAPP_SKINS)) return(dsapp_skin_default())
  id
}

#' 单个皮肤的元信息（已收敛，取不到就是默认皮肤那一份）
dsapp_skin_meta <- function(id) DSAPP_SKINS[[dsapp_skin_norm(id)]]

#' 读某个账号的皮肤
#'
#' 和 dsapp_settings_get() 一样：**没登录时不查库**，直接给默认值。理由也一样
#' —— 登录闸门写 state$user_id 之前，界面已经渲染过一次了，那时候查
#' `WHERE id = NULL` 只会多一次无用的库往返。
dsapp_skin_get <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(dsapp_skin_default())
  }
  v <- tryCatch(
    DBI::dbGetQuery(con, "SELECT skin FROM users WHERE id = ?",
                    params = list(as.integer(user_id)))$skin,
    error = function(e) NULL)
  if (is.null(v) || length(v) == 0) return(dsapp_skin_default())
  dsapp_skin_norm(v[[1]])
}

#' 存某个账号的皮肤
#'
#' 空值 / 非法 id 一律**当成默认皮肤存**，而不是"不动" —— 和 API Key 那条
#' "空串 = 别动"的约定**故意相反**，因为这里的空值不可能是"用户正在输入中"：
#' 皮肤是点一下就定的，没有中间态。真收到空值只可能是前端出了岔子，那时
#' 落一个确定的默认值，比留着一个坏值让界面继续不匹配要好。
dsapp_skin_save <- function(user_id, skin, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 || is.na(user_id)) {
    return(invisible(FALSE))
  }
  ok <- tryCatch({
    DBI::dbExecute(con, "UPDATE users SET skin = ? WHERE id = ?",
                   params = list(dsapp_skin_norm(skin), as.integer(user_id)))
    TRUE
  }, error = function(e) FALSE)
  invisible(ok)
}

#' 把一个皮肤推到浏览器
#'
#' ⚠️ 要传**顶层** session。模块里拿到的是带命名空间的子 session，
#'    sendCustomMessage 发出去的消息名会被加上前缀，app.js 那边按
#'    `dsapp:skin` 注册的处理器收不到（和 dsapp_nav_to 同一个坑，见 utils.R）。
#'    调用方一律从 state$root_session 取。
dsapp_skin_apply <- function(session, skin) {
  id <- dsapp_skin_norm(skin)
  try(session$sendCustomMessage("dsapp:skin", list(skin = id)), silent = TRUE)
  invisible(id)
}

#' 设置页的皮肤选择卡
#'
#' 用 radioButtons + CSS 伪装成卡片，而不是自己拼 div + onclick：
#'   · 键盘可达（Tab 能走到、方向键能换）是原生 radio 白送的，自己拼要重做
#'     一遍，而且十有八九做不全；
#'   · 状态由浏览器维护，服务端只管读一个字符串，不用同步"哪张卡是选中的"；
#'   · 断线重连后 Shiny 会自动把选中态恢复回来。
#' 代价是要写一段 CSS 把 .form-check 那套改成卡片，那段在 www/skins.css 里。
#'
#' choiceNames 用 HTML() 是因为色块得画在**标签里面**（label 才是可点区域）。
#' ⚠️ 这里的 HTML 全部由本文件的 chips 拼出来，没有任何用户输入拼进去 ——
#'    不要把用户的什么东西加进这个列表。
dsapp_skin_picker <- function(ns, selected = NULL) {
  sel <- dsapp_skin_norm(selected)
  ids <- dsapp_skin_ids()

  chip_html <- function(sk) {
    paste0(
      '<span class="dsapp-skin-card">',
      '<span class="dsapp-skin-chips">',
      paste(sprintf('<i style="background:%s"></i>', sk$chips), collapse = ""),
      '</span>',
      '<span class="dsapp-skin-name">', sk$label, '</span>',
      '<span class="dsapp-skin-hint">', sk$hint, '</span>',
      '</span>')
  }

  tags$div(
    class = "dsapp-skinpick",
    radioButtons(
      ns("skin"), NULL,
      choiceNames  = lapply(ids, function(i) HTML(chip_html(DSAPP_SKINS[[i]]))),
      choiceValues = ids,
      selected     = sel, inline = TRUE
    )
  )
}
