# =============================================================================
# 面板宽高的用户自定义（V13.2 item 5）
# =============================================================================
# 用户原话：
#   「侧面导航栏，二级目录中，例如言出法随界面中的输出界面的宽高，能不能
#     支持用户自定义？记得做好自适应，不要相互堆叠」
#
# ---- 这一层管什么 -----------------------------------------------------------
#
#   这一份文件（R/uiprefs.R）：有哪几个尺寸可以调、各自的默认值/上下限、
#                            某个账号调成了多少、怎么落库。
#   www/app.css            ：那些尺寸**怎么用**（一律走 CSS 变量，见下面）。
#   www/app.js             ：拖分隔条那一下的实时反馈 + 把结果报回服务端。
#   R/mod_chat.R           ：分隔条本身长在哪儿。
#   R/mod_settings.R       ：设置页那张卡片（键盘可达的那条路）。
#
# ---- 为什么是 CSS 变量 ------------------------------------------------------
#
# ⚠️ 尺寸**只能**这样落进样式表：`--dsapp-files-w` 挂在 `<html>` 上，CSS 里
#    写 `flex: 0 0 var(--dsapp-files-w, 320px)`。不这么做的话，服务端要为了
#    "用户把栏拖宽了 20px"重新渲染一整页（消息流、产物卡片全在里面），
#    拖一下卡一下；而拖动过程中那一帧的反馈必须由**浏览器**自己给。
#
# ⚠️ 变量挂在 `<html>` 而不是某个 div 上：挂 div 的话，谁把那一段 DOM
#    包一层、或者某个 renderUI 重画一次，变量就跟着没了 —— 表现是"拖完
#    宽度弹回默认"，而且完全不报错。
#
# ---- 存储 -------------------------------------------------------------------
#
# 存 `users.ui_prefs` 一列 JSON（形如 `{"files_w":420,"composer_h":0}`），
# 而不是每个尺寸开一列。理由：这一列以后大概率还会加东西（别的页面的面板），
# 加一项就 ALTER TABLE 一次、schema 版本抬一次，成本全花在仪式上。
#
# ⚠️ NULL 是**合法状态**（老库升上来就是这样），含义是"没调过"，由
#    dsapp_uipref_get() 收敛成默认值。和 users.skin 同一个约定。
# =============================================================================

# =============================================================================
# 左侧全局导航有哪些项、按什么顺序（V13.11 item 3）
# =============================================================================
# 用户原话：
#   「最左侧导航栏也需要可以通过拖拽改变位置」
# —— 拖宽是 V13.5 item 8 就有的（menu_w），这里做的是**拖着重排**。
#
# ★ 这张表是**唯一**的真相来源，三处都读它：
#     * app.R 的 dsapp_main_ui 渲染左栏那一段（谁看得见、按什么顺序）
#     * dsapp_uipref_one() 的 nav_order 白名单（用户拖出来的值能收哪些）
#     * selftest.R「左栏导航项与 navset 的 value 一一对应」那条断言
#   以前左栏是 8 个写死的 dsapp_rail_link("chat", ...) 调用，顺序=源码顺序，
#   且 nav_panel 那边的 value 是另一份手抄的拷贝 —— 两边靠人肉对齐。
#
# ⚠️ **必须住在这个文件里，不能挪进 app.R。** app.R 的顶层是被 Shiny 用
#    `sys.source(envir = new.env(parent = globalenv()))` 求值的，它的顶层
#    对象**不在 globalenv**；而 dsapp_uipref_one() 住在 globalenv（R/*.R 是
#    `source(local = globalenv())` 进去的），够不着它 —— 一调就是
#    `could not find function`。判据和 app.R 末尾那段一样：
#    **这个对象有没有被 R/ 下的文件用过？有 → 放 R/**。
#
# ⚠️ `role` 决定**谁看得见**这一项：不写 = 所有人；"admin" = 管理页那个
#    开关（dsapp_user_is_admin）；"platform" = 只给平台管理员。
#    它只管**渲染**，不管 nav_order 的白名单 —— 那个收全部 8 个值，
#    理由见 dsapp_uipref_one() 里 nav_order 那一段。
#    ★ V16.5 item 5：这段判据搬进了 dsapp_nav_visible()（文件末尾），
#      原来内联在 app.R 的 UI 里 —— app.R 的顶层不在 globalenv，自检够不着。
#      "platform" 这一档 V13.11 就写进注释了，但**一直到 V16.5 才第一次有
#      人用**（云工具）；也就是说在这之前它是"从没被跑过的代码"。
DSAPP_NAV_ITEMS <- list(
  list(value = "chat",     icon = "comments",            label = "言出法随"),
  list(value = "tasks",    icon = "list-check",          label = "历史任务"),
  list(value = "files",    icon = "folder-open",         label = "文件"),
  # ★ V13.11 item 5：文献速递。⚠️ value 只能是**小写字母**（selftest 里那条
  #   「左栏导航项与 navset 的 value 一一对应」用的正则是 `[a-z]+`），
  #   所以是 "lit" 而不是 "litSearch" 或 "文献速递"。
  list(value = "lit",      icon = "newspaper",           label = "文献速递"),
  # ★ V15 item 8：论坛。用户原话：「加一个论坛页面，用户能交流自己使用过程中
  #   的经验或遇到的问题」。
  #
  #   排在这里（工作页那一组的末尾）：它和上面四个一样是**天天可能点开**的
  #   东西，而不是"配一次很久不动"的配置页。
  #   ⚠️ value 只能是小写字母（selftest 那条「导航项与 navset 的 value
  #      一一对应」用的正则是 `[a-z]+`），所以是 "forum"。
  #   ⚠️ **不写 role** = 所有人都看得见。论坛藏起来就没有意义了。
  #   ⚠️ 老账号的 nav_order 里没有 "forum" —— dsapp_nav_sorted 的规矩是
  #      "order 里没有的接在后面"，所以它们这一项会排在最后面。这是那张表
  #      设计时就定好的行为（新页面不会因为没人拖过就消失），别去动
  #      nav_order 的默认值（那份默认值刻意是空的）。
  list(value = "forum",    icon = "comment-dots",        label = "论坛"),
  # 技能排在「环境」前面：它和上面三个一样是**天天要用**的东西（对话里
  # 随时可能想挂一条），而「环境」「设置」是配置，改一次很久不动。
  # ★ V15.8 item 2：云工具（结合蛋白设计流水线的 GUI）。
  #   用户原话：「加一个云工具模块，第一个功能就是能够给这套流程的自动化
  #   分析提供一个GUI」。
  #
  #   位置：工作页那一组的**末尾**（论坛之后、技能之前）。它和上面四个一样
  #   是"天天可能点开"的东西 —— 一次跑几十分钟，但用户会反复回来看结果；
  #   而「技能」「环境」「设置」是配一次的，排在它后面。
  #   ⚠️ value 只能是小写字母（selftest 那条「导航项与 navset 的 value
  #      一一对应」用的正则是 `[a-z]+`），所以是 "cloudtool"。
  #   ★★ V16.5 item 5：`role = "platform"` —— **暂时只对平台管理者开放**。
  #      用户原话：「云工具暂时只对平台管理者开放，普通用户不显示」。
  #
  #      ⚠️ 是 "platform" 不是 "admin"：后者连**项目管理员**一起放行
  #         （那是「后台管理」那一项的口径，见下面 admin 那条的 ⚠️）。
  #         用户说的是"只对平台管理者"，多放一种人就与这句话不符了。
  #      ⚠️ V15.8 那时写的是"不写 role = 所有人都看得见"，理由是"这一页只是
  #         把命令行包成表单"。**那条理由仍然成立**，改的是产品口径（用它的人
  #         还没定下来），不是"那一页不安全了" —— 所以别顺手在服务端加闸：
  #         这里只做"不显示"，页面本身的门槛（GPU / 权重 / 执行器体检）
  #         一个字没动。
  #      ⚠️ 隐藏只发生在这两处：这张表的 role、以及 app.R 里那个 nav_panel
  #         的 if —— 两边必须一起改（只改一边的症状：左栏没有它、但
  #         `nav_select("nav", "cloudtool")` 还能切过去，且不报错）。
  #   ⚠️ 老账号的 nav_order 里没有这个值 —— dsapp_nav_sorted 的规矩是
  #      "order 里没有的接在后面"，所以它们这一项会排在后面。这是那张表
  #      设计时就定好的行为，别去动 nav_order 的默认值。
  list(value = "cloudtool", icon = "cloud",             label = "云工具",
       role = "platform"),
  list(value = "skills",   icon = "wand-magic-sparkles", label = "技能"),
  list(value = "envs",     icon = "layer-group",         label = "环境"),
  # ★ V13.12 item 19：模型服务从"左栏常驻的折叠块"改成**独立页**。
  #   用户原话：「把模型服务换成和其它几个侧面导航栏一样的单独页面吧」。
  #   排在这里是跟着语义走的：它和「环境」「设置」一样是**配置**页
  #   （配一次很久不动），而不是上面那排天天要用的工作页。
  # ⚠️ value 只能是小写字母（见上面 "lit" 那条）。
  list(value = "model",    icon = "robot",               label = "模型服务"),
  list(value = "settings", icon = "gear",                label = "设置"),
  # ★ V13.14 item 23：帮助从**设置页的第四个页签**提升成左栏的一项。
  #   用户原话：「帮助页面独立到左侧导航栏」。
  #
  #   排在「设置」后面、两个管理员项前面：它和上面那三项一样是**配置**
  #   （配一次很久不动），而且是应用级的、不针对某一次分析；而「管理」
  #   「后台」是少数人才有的、且是给别人用的，仍然压在最下面。
  #
  #   ⚠️ 不写 `role` = **所有人都看得见**。帮助是给用户的，藏起来它就没用了。
  #   内容在 R/mod_help.R（整页静态，没有 server）。
  #
  #   ⚠️ 老账号的 nav_order 里**没有** "help" 这个值（他们的偏好是上一版存
  #      的）。dsapp_nav_sorted 的规矩是"order 里没有的接在后面"，所以对它
  #      们这一项会排在「后台」之后 —— 这是那张表设计时就定好的行为（新加
  #      的页面不会因为"没人拖过它"而消失），不是 bug。别为了把它顶到设置
  #      后面去动 nav_order 的默认值：那份默认值刻意是空的。
  list(value = "help",     icon = "circle-question",     label = "帮助"),
  # ★ V15.4 item 7：原来的「管理」和「后台」两项合成这一项
  #   （用户原话：「请合并管理和后台界面，生成一个"后台管理"界面」）。
  #
  #   ⚠️⚠️ `value` 仍然是 `"admin"`。**只有 label 变了**。全仓有多处
  #      裸 `bslib::nav_select("nav", "admin")` / `data-nav="admin"` 在认
  #      这个字符串，改了它的症状是"点了没反应、也不报错"。
  #   ⚠️ `role` 仍然是 `"admin"`（= 项目管理员也看得见），不是 "platform"：
  #      用户对这个问题的原话是「两种管理员都能进，但是进去后看到的界面不
  #      一样」。"不一样"由 R/mod_backstage.R 里那三层门控实现（少两个子页签、
  #      少几张卡、服务端 guard() 一点没松），不是靠这里筛掉谁。
  #   ⚠️ 原来的 `htadmin` 那一项**删掉了**。老账号的 nav_order 里可能还留着
  #      这个值 —— 无害，dsapp_nav_sorted 会把 order 里多出来的值忽略掉
  #      （它的规矩是"按 order 排、order 里没有的接在后面"，不是严格相等）。
  #   ⚠️ 图标名要和 nav_panel 那边对得上；selftest 里有一条钉着这一栏的图标。
  list(value = "admin",    icon = "users-gear",          label = "后台管理",
       role = "admin")
)

DSAPP_NAV_VALUES <- vapply(DSAPP_NAV_ITEMS, function(x) x$value, character(1))

#' 这一屏的左栏到底渲染哪几项
#'
#' @param items       DSAPP_NAV_ITEMS。留参数是为了让自检能塞夹具进来。
#' @param is_admin    dsapp_user_is_admin(user) —— **两种**管理员都是 TRUE
#' @param admin_scope dsapp_user_admin_scope(user) —— ""/"project"/"platform"
#' @return 过滤后的 items，顺序不变
#'
#' ★ V16.5 item 5：这段判据原来**内联在 app.R 的 UI 里**。搬出来的原因是
#'    可测性：app.R 顶层不在 globalenv（UI 是个函数体，且 selftest 从不 eval
#'    它），"平台管理员才看得见"这件事于是**一次都没被跑过** —— 而它偏偏是
#'    一个"写错了完全没症状"的判据（写反了只有拿两类账号各登一次才看得出来）。
#'
#' ⚠️ 它管的是**看得见/看不见**，不是权限。服务端模块照旧无条件注册
#'    （理由见 app.R 里那段 ⚠️）。这里筛掉的项，靠
#'    `bslib::nav_select("nav", "<value>")` 仍然切得过去 —— 所以它和
#'    app.R 里那个 nav_panel 的 `if` **必须一起改**，这是第二道。
#'
#' ⚠️⚠️ 认不出来的 role **藏起来**（不是放行）。将来手滑写成 "Platform" 时，
#'    两种错法的症状是"这一项不见了" vs "普通用户也看得见" —— 前者当场就能
#'    发现，后者要等用户来问。往安全那一侧倒。
dsapp_nav_visible <- function(items = DSAPP_NAV_ITEMS,
                              is_admin = FALSE,
                              admin_scope = "") {
  keep <- vapply(items, function(it) {
    r <- it$role
    # 不写 role、或写了空串 = 所有人都看得见。NA 也走这一档：这张表是手写的，
    # 出现 NA 只可能是写漏了；藏起来的话症状指向的是"表里有 NA"这件不相干的
    # 事（而 nzchar(NA) 是 TRUE —— 不显式判 NA 的话它会掉进下面的 admin 档）。
    if (is.null(r) || length(r) != 1L || is.na(r) || !nzchar(r)) return(TRUE)
    if (identical(r, "platform")) return(identical(admin_scope, "platform"))
    if (identical(r, "admin"))    return(isTRUE(is_admin))
    FALSE
  }, logical(1))
  items[keep]
}

#' 把一份「用户拖出来的顺序」套到这一屏真正要渲染的那几项上
#'
#' @param values 看得见的 nav value，按内置顺序（调用方已按角色筛过）
#' @param order  nav_order 存着的那一份（可能是空的 = 没拖过）
#' @return 重排后的 values
#'
#' ⚠️ 规则是「按 order 排，order 里没有的**接在后面**」，不是「按 order 排、
#'    剩下的丢掉」。丢掉的两种坏法都不报错：
#'      * 以后加新页面（下一个就是「文献速递」），它的 value 不在任何人的
#'        order 里 —— 丢掉的话新入口永远不出现，而且完全没有报错；
#'      * 管理员把「管理」拖到第一位、之后被降成普通账号，那个 value 对他
#'        无效，但不能因此把别的项一起挤掉。
dsapp_nav_sorted <- function(values, order) {
  values <- as.character(values %||% character(0))
  order  <- as.character(order %||% character(0))
  order  <- order[order %in% values]
  c(unique(order), values[!values %in% order])
}

#' 可以调的尺寸，和各自的规矩
#'
#' `def` 是默认值，`min`/`max` 是**硬边界**。边界不是"界面上的建议"——
#' `dsapp_uipref_norm()` 每次读、每次写都会夹一遍，所以就算有人手改了库里
#' 那个 JSON，界面也不会被撑坏。
#'
#' ⚠️ 上下限要**互相留活路**：`files_w` 的上限 900 是"再宽就别扭了"，
#'    但真正防堆叠的不是它 —— 是 app.js 拖动时按**当前容器宽度**现算的
#'    那条比例上限。900 只是一个兜底，防止有人在 4K 屏上拖出半屏空白。
DSAPP_UIPREF_SPECS <- list(
  # 言出法随右边那一栏（「本对话的文件」/产物）的宽度。
  #
  # ⚠️ 默认 320 必须和 app.css 里 `.dsapp-files-col` 那条 `var()` 的 fallback
  #    **一个字都不差**。对不上的表现：没调过的用户看到的是 320，调过的
  #    看到的是另一个数，而"调回默认"按钮会跳到一个第三个数。
  files_w = list(kind = "int", def = 320L, min = 200L, max = 900L),
  # 输入区（对话框）的高度。**0 = 不干预**，高度由 textAreaInput 的 rows
  # 自己定 —— 这是默认，也是绝大多数人该待的状态。
  #
  # ⚠️ 它调的是**输入区**，不是输出框。用户说的是"输出界面的高"，
  #    但输出框在当前版面里已经**吃掉了一整屏剩下的全部高度**（见 app.css
  #    的 .dsapp-chat-main），再给它一个"高度"没有意义；能调、而且调了
  #    看得见效果的，是"输出框和输入框怎么分这一屏"。拖动分隔条往上 =
  #    输入区变矮 = 输出框变高。设置页那一栏的文案按这个说法写。
  composer_h = list(kind = "int", def = 0L, min = 0L, max = 620L),

  # 言出法随左边那条**任务导航栏**（会话列表那一列）的宽度。V13.4 item 6。
  #
  # ⚠️ 默认 260 必须和 mod_chat.R 里 `sidebar(width = 260)` **一个字都不差**。
  #    这两个数是同一个默认值的两份拷贝：那一个是页面刚渲染出来、`<style>`
  #    还没插入时用的，这一个是"没调过"的账号用的。对不上的表现和 files_w
  #    那条一样 —— 没调过的人看到一个宽度，随手一拖又跳到另一个。
  #
  # ⚠️ 上限 520 只是兜底。真正的上限在 app.js 里按**当前容器宽度**现算
  #    （见 clampSess）：一栏撑到 520 之后主区就没法看了，而主区才是这一页
  #    的正事。
  sess_w = list(kind = "int", def = 260L, min = 180L, max = 520L),

  # ★ V13.5 item 8：**主菜单**（最左边那条全局导航栏）的宽度。
  #
  # ⚠️ 默认 264 必须和 codex.css 里 `.dsapp-shell` 那条
  #    `grid-template-columns: var(--dsapp-menu-w, 264px) minmax(0, 1fr)`
  #    的 fallback **一个字都不差**。对不上的表现和 sess_w 那条一样：
  #    没调过的账号看到一个宽度，随手一拖又跳到另一个。
  #
  # ⚠️ 它和 sess_w **不是一回事**，别合并：sess_w 是「言出法随」页内部那条
  #    会话列表（bslib sidebar，只影响那一页），menu_w 是**所有页面**左边那条
  #    全局导航（.dsapp-shell 的第一列）。两个变量、两条分隔线、两个设置项。
  menu_w = list(kind = "int", def = 264L, min = 180L, max = 420L),

  # ★ V13.5 item 2：历史任务页「执行历史 ↔ 任务详情」的分配。
  #
  # 这一格量的是**左栏（执行历史）**的宽度，右边的详情吃掉剩下的 ——
  # 和 files_w 一个约定（调左边那个，因为它是有边界的那个）。
  #
  # ⚠️ 默认 520 必须和 app.css 里 `.dsapp-task-hist` 那条 var() 的 fallback
  #    一字不差。这一版之前这里根本不可调：那一页写死的是 bslib 的
  #    `layout_columns(col_widths = c(5, 7))`，5/12 在 1336 的容器上是 556 ——
  #    现在换成 flex + 变量，默认值取 520（比 556 略窄一点，给详情多留些）。
  tasks_w = list(kind = "int", def = 520L, min = 300L, max = 1200L),

  # ★ V14 item 1：文件页「文件管理区 ↔ 预览」的分配。
  #
  # 用户原话：「文件管理区和预览之间应该可以拖动改变大小」。
  #
  # 这一格量的是**左栏（文件管理区）**的宽度，右边的预览吃掉剩下的 ——
  # 和 files_w / tasks_w 一个约定（调左边那个，因为它是有边界的那个）。
  #
  # ⚠️ 默认 420 必须和 app.css 里 `.dsapp-files-list` 那条 var() 的 fallback
  #    一字不差，理由同 .dsapp-files-col 那段。这一版之前这里根本不可调：
  #    那一页写死的是 bslib 的 `layout_columns(col_widths = c(5, 7))`，
  #    5/12 在 1336 的容器上是 556 —— 默认值取 420（比 556 窄不少，把多出来
  #    的宽度让给预览：那一页右边的报告/图片才是用户真正在看的东西，
  #    而文件名那一列 420 足够放下）。
  #
  # ⚠️⚠️ 它和 `files_w` **不是一回事**，别合并：files_w 是「言出法随」那一页
  #    右边的产物栏（.dsapp-files-col），这个是「文件」页里的文件管理区
  #    （.dsapp-files-list）。两个页面、两条分隔条、两个变量。
  #    共用一个键的表现：在文件页拖动会去量对话页那一列（那时它是隐藏的，
  #    量出来 0）→ 分隔条一碰就跳到最小值，而且存下来的宽度把对话页也改了。
  filespage_w = list(kind = "int", def = 420L, min = 240L, max = 1200L),

  # 技能列表怎么排（V13.2 item 13）。"custom" = 拖出来的顺序。
  #
  # ★ 它和上面两个尺寸**不是一类东西**（一个是像素、一个是枚举），但还是
  #   放在同一份偏好里：都是"这个账号看着舒服的样子"，而且都要跟着账号走。
  #   为此 DSAPP_UIPREF_SPECS 多了一个 `kind` —— 见下面 dsapp_uipref_one()。
  #
  # ⚠️ choices 里那几个字符串必须和 DSAPP_SKILLS_SORTS（skills.R）一字不差。
  #    分叉的表现：界面能选、查询不认，静默落回"custom" —— 用户选了"按名称"
  #    却看到一堆按拖拽顺序排的。
  skills_sort = list(kind = "choice", def = "custom",
                     choices = c("custom", "name", "created", "updated")),
  # 反向排。只对上面那三个"有大小"的排序有意义，"custom" 时不起作用。
  skills_desc = list(kind = "flag", def = FALSE),

  # ★ V13.7 item 5：页面关掉 / 登出之后，正在跑的循环怎么办。
  #
  # 用户原话：「需要在登出状态下，AI的思考和任务能够继续挂载执行，并且
  # **是否执行可以让用户预设选择**」—— 后半句就是这个键。
  #
  #   off    —— 一关页面就停，不留任何后台进程（这一版之前的行为）
  #   finish —— 让**当前正在跑的那个任务**跑完。不叫模型、不推下一轮。
  #   full   —— 整个循环交给后台接着跑，一直到轮次/时长上限或需要你确认
  #
  # ⚠️ 这三个值在 R/mod_chat.R 的 onSessionEnded 和 R/detach.R 里被分派，
  #    改字符串要两处一起改。分叉的表现最难查：**用户以为自己在挂机，
  #    实际什么都没在跑**，而界面上一切正常。
  #
  # ⚠️ 默认是 finish 而不是 full。理由：这个功能的全部前提就是"没人看着"，
  #    所以默认值必须在**没人看着的时候也是安全的**。finish 的代价有上界
  #    （一个任务的机时），full 没有（模型能连着跑满 max_iter 轮）。
  #    用户想要全自动，设置里一格就点过去了 —— 但那是他**点**的。
  #
  # ⚠️ 它和 DSAPP_AGENT_MAX_ITER 的关系：full 那一档受轮次上限和自动结束时间
  #    双重约束（见 R/agent.R），所以它不是"无限跑"。
  #
  #    ★ V13.17 item 31 更新：那两条闸**现在都是用户自己在对话页拖的滑块**
  #    （轮数 / 自动结束时间），不再是常量。所以"要放开"不再是改代码的事 ——
  #    用户把两个滑块拉满就是他能拿到的最大额度，而那个最大值仍然是有界的
  #    （20 轮 / 8 小时，见 config.R 里那一对角度的说明）。
  #    ⚠️ 这两条闸和**设置页**里那些值是两回事：设置页管的是"关页面之后怎么办"，
  #       滑块管的是"这一次自动执行能跑多久"。别把 default 往这边接。
  agent_detach = list(kind = "choice", def = "finish",
                      choices = c("off", "finish", "full")),

  # ★ V13.11 item 3：左栏**导航项的顺序**（拖动重排出来的那一份）。
  #
  # ⚠️ 别和 menu_w 搞混：menu_w 是那条导航栏的**宽度**，这个是里面那 6~8 个
  #    入口谁在谁上面。两个都挂在最左边那条栏上，但是两件事。
  #
  # ⚠️ 空向量 = **没拖过**，用内置顺序。别把它写成"默认等于内置顺序"——
  #    那样以后内置顺序一变（比如插进去一个「文献速递」），所有从没拖过的
  #    账号会莫名其妙跟着变，而他们什么都没做过。
  #
  # ⚠️ 存在 ui_prefs 这列 JSON 里而不是新开一张 nav_order 表：它是"这个账号
  #    看着顺眼的样子"，和上面几个尺寸同类、同生命周期（跟着账号走、
  #    登出还在）。技能那套之所以是独立的表，是因为技能是**全局资源**、
  #    顺序要跨账号共享，不是一回事。
  nav_order = list(kind = "order", def = character(0)),

  # ★ V13.12 item 4：「新对话开始时，那两个执行开关默认是什么」。
  #
  # 用户原话：「请在用户第一次开启任务时让用户选择是否自动执行和出错自动修，
  # 然后记住用户的默认设置，新会话生效」。
  #
  # ⚠️ 这里存的**不是**"当前这条对话的开关状态"，而是"下一条新对话开成什么
  #    样"。两者一定要分开：前者在对话页那两个 checkbox 上，随开随关、不落库；
  #    后者只在两个时刻写 —— 首次那个弹窗、以及设置页那张卡片。
  #    混成一个的话，用户在某个对话里临时关掉自动执行，他所有的对话就都被
  #    改了默认值，而他从没说过要那样。
  #
  # ⚠️ 默认值必须和 mod_chat.R 里那两个 checkboxInput 的 value = 一字不差
  #    （FALSE / TRUE）。对不上的表现：从没答过弹窗的老账号（agent_asked
  #    还是 FALSE）进新对话，看到的开关状态和"平台默认"是两回事。
  agent_auto = list(kind = "flag", def = FALSE),
  agent_autofix = list(kind = "flag", def = TRUE),

  # 问过没有。**这一条只回答"还要不要弹那个窗"**。
  #
  # ⚠️ 为什么不是"看 agent_auto 有没有设过"：flag 类型的读回来一定是
  #    TRUE/FALSE（dsapp_uipref_one 会拿 def 补上），"没设过"和"设成了
  #    FALSE"在归一化之后长得一模一样。用户明确选了"都先别开"，下次进新
  #    对话又弹一次，他会以为这个设置没存上。
  agent_asked = list(kind = "flag", def = FALSE),

  # ---- ★ Test_V15.2：邮件提醒（两个开关）----------------------------------
  #
  # 用户原话：「言出法随界面开启一个让用户勾选邮件提醒的功能，开启后能把
  # 任务运行成功完成/失败的信息发送到用户的邮箱」。
  #
  # ⚠️ **两个都是 def = FALSE**：发信是**往外发东西**，默认必须是"什么都不发"。
  #    默认开着的话，一个从没进过设置页的账号跑一个任务，他的邮箱就会凭空
  #    收到一封信 —— 那是我们必须先问过才做的事。
  #
  # ⚠️ 收件地址**不在这里**，就是 `users.email`（账户体系的枢纽，见
  #    R/users.R 的 idx_users_email）。加一个覆盖字段会带来"哪个地址才算数"
  #    的歧义，而用户要改地址本来就可以改登录邮箱。
  #
  # ⚠️ 邮件功能的**总闸是"配没配齐 SMTP"**（`dsapp_mail_ready()`），不是这里
  #    的开关。两个都要成立才发得出去 —— 见 R/mail.R 的 D4 说明。
  #
  # 任务结束（成功 / 失败 / 超时 / 出错）时发不发。
  #
  # ⚠️ 这**一个**键管成功和失败两种信，不再往下切。计划里原先是拆成
  #    email_task_ok / email_task_fail 两个键的，实施时改成一个，理由是
  #    **UI 对不上**：用户要的那个勾选框在「言出法随」页（一个框），设置页
  #    要能细调（两个框）。只关掉"失败"之后回对话页，那个总勾选框该显示
  #    什么？显示勾着 = 撒谎，显示没勾 = 用户以为自己全关了、结果还在收
  #    成功信。两种都像坏了。
  #    而用户原话要的就是"成功完成/失败的信息"一起发 —— 一个键正好。
  #    真有人只要失败提醒，再加键也不迟，那时两个页面一起改。
  email_task = list(kind = "flag", def = FALSE),
  # 定时订阅那一跑跑完之后发不发（文献速递正文 + 附件）。
  #
  # ⚠️ 和 email_task 分开，因为它们管的是**两件不同的事**：这个管的是
  #    "到点自动跑的那个订阅"，那个管的是"我自己点运行的任务"。
  #    合起来的话，只想收订阅速递的人会被自己每跑一次分析的提醒信淹掉。
  email_lit_done = list(kind = "flag", def = FALSE)
)

#' 把一个偏好值收敛进合法范围
#'
#' 非法值一律**回默认值**，不是"报错"也不是"当成 0"。这几个值只可能来自：
#' 老库里的脏 JSON、用户手改库、前端发上来的半个数字。三种情况都该让界面
#' 回到一个确定的样子，而不是留个洞。
dsapp_uipref_one <- function(name, value) {
  sp <- DSAPP_UIPREF_SPECS[[name]]
  if (is.null(sp)) return(NULL)

  if (identical(sp$kind, "choice")) {
    v <- as.character(value %||% "")[1]
    if (length(v) != 1L || is.na(v) || !v %in% sp$choices) v <- sp$def
    return(v)
  }
  if (identical(sp$kind, "flag")) {
    # ⚠️ 只认 TRUE/FALSE 本身，**不认** "TRUE"/1 这类。jsonlite 读回来的
    #    就是逻辑值，而浏览器那边（app.js）发的是 0/1 —— 所以两种都要收。
    #    别的值（"yes"、2、NULL）当成"没设过"回默认。
    if (is.logical(value) && length(value) == 1L && !is.na(value)) return(value)
    v <- suppressWarnings(as.numeric(value))
    if (length(v) == 1L && !is.na(v) && v %in% c(0, 1)) return(v == 1)
    return(sp$def)
  }
  if (identical(sp$kind, "order")) {
    # ⚠️ unlist 不能省：jsonlite 读一个**空数组**（`[]`）回来给的是
    #    `list()` 而不是 `character(0)`，读非空数组在某些 simplify 路径下
    #    也是 list。不 unlist 的话 `v %in% DSAPP_NAV_VALUES` 恒为 FALSE，
    #    表现是"拖完顺序一刷新就回到默认"，且不报错。
    v <- as.character(unlist(value, use.names = FALSE))
    v <- v[!is.na(v) & nzchar(v)]
    # ⚠️ 白名单用**全部** 8 个 value，**不按角色筛**。理由：筛掉的话，管理员
    #    拖出来的顺序在他被降权的**那一瞬间**就被永久改写了（存回去的少了
    #    一项），再升回管理员顺序也没了。多存几个对他当前看不见的值没有任何
    #    坏处 —— 渲染那一侧本来就会再取一次交集（见 dsapp_nav_sorted）。
    v <- unique(v[v %in% DSAPP_NAV_VALUES])
    # ⚠️ 去重之后一个不剩 = 用户把顺序拖成了一份全是垃圾的东西 —— 收敛成
    #    "没拖过"，而不是留一个空向量以外的怪值。空向量本身就是这个含义。
    return(v)
  }

  v <- suppressWarnings(as.numeric(value))
  if (length(v) != 1L || is.na(v) || !is.finite(v)) v <- sp$def
  as.integer(max(sp$min, min(sp$max, round(v))))
}

#' 把一份（可能残缺、可能非法的）偏好收敛成**完整且合法**的一份
#'
#' 返回值一定含有 DSAPP_UIPREF_SPECS 里**每一个**键 —— 调用方不需要再判空。
dsapp_uipref_norm <- function(x) {
  if (is.character(x) && length(x) == 1L) x <- dsapp_uipref_parse(x)
  if (!is.list(x)) x <- list()
  out <- list()
  for (nm in names(DSAPP_UIPREF_SPECS)) {
    out[[nm]] <- dsapp_uipref_one(nm, x[[nm]])
  }
  out
}

#' JSON 文本 → list。坏文本一律当空（→ 全默认），不抛异常
dsapp_uipref_parse <- function(txt) {
  if (is.null(txt) || length(txt) != 1L || is.na(txt) || !nzchar(txt)) {
    return(list())
  }
  tryCatch({
    j <- jsonlite::fromJSON(txt, simplifyVector = TRUE)
    if (is.list(j)) j else list()
  }, error = function(e) list())
}

#' 读某个账号的面板尺寸
#'
#' 和 dsapp_skin_get() 一样：**没登录时不查库**，直接给默认值 —— 登录闸门
#' 写 state$user_id 之前界面已经渲染过一次了，那时候查 `WHERE id = NULL`
#' 只会多一次无用的库往返。
dsapp_uipref_get <- function(user_id, con = dsapp_db()) {
  if (is.null(user_id) || length(user_id) == 0 ||
      is.na(suppressWarnings(as.integer(user_id)))) {
    return(dsapp_uipref_norm(NULL))
  }
  txt <- tryCatch(
    DBI::dbGetQuery(con, "SELECT ui_prefs FROM users WHERE id = ?",
                    params = list(as.integer(user_id)))$ui_prefs,
    error = function(e) NULL)
  if (is.null(txt) || length(txt) == 0 || is.na(txt[[1]])) {
    return(dsapp_uipref_norm(NULL))
  }
  dsapp_uipref_norm(as.character(txt[[1]]))
}

#' 存某个账号的面板尺寸
#'
#' 存进去的永远是**收敛过**的一份：脏输入不会进库，于是下次读出来不用
#' 再猜它是什么。
dsapp_uipref_save <- function(user_id, prefs, con = dsapp_db()) {
  uid <- suppressWarnings(as.integer(user_id))
  if (length(uid) != 1L || is.na(uid)) return(invisible(FALSE))
  p <- dsapp_uipref_norm(prefs)
  txt <- tryCatch(jsonlite::toJSON(p, auto_unbox = TRUE), error = function(e) NULL)
  if (is.null(txt)) return(invisible(FALSE))
  ok <- tryCatch({
    DBI::dbExecute(con, "UPDATE users SET ui_prefs = ? WHERE id = ?",
                   params = list(as.character(txt), uid))
    TRUE
  }, error = function(e) FALSE)
  invisible(ok)
}

#' 把尺寸写成一段 `<style>`，塞进页面
#'
#' ★ 为什么不走 `sendCustomMessage`（皮肤那条路走的就是它）：那条路要拿到
#'   **顶层** session，而这里在模块里；模块 session 是个 proxy，
#'   `sendCustomMessage` 在它身上会**静默失效**（见 CLAUDE 里那条）。
#'   一段 `<style>` 没有这个问题：它跟着页面一起渲染，谁渲染都一样，
#'   而且 style 标签是**全局**的，放在哪个 DOM 位置都生效。
#'
#' ⚠️ 值全部过了 `dsapp_uipref_norm()`（as.integer + 夹边界），拼进 HTML
#'    的是**整数**，没有注入面。
dsapp_uipref_css <- function(prefs) {
  p <- dsapp_uipref_norm(prefs)
  # 变量一直发（两个都是整数），**类**只在"输入区被固定高度"时加。
  #
  # ⚠️ 那个类不能省。CSS 里没有"这个变量定义了没有"这种选择器，于是
  #    `flex: 0 0 var(--dsapp-composer-h, auto)` 在变量**没定义**时会退化成
  #    `0 0 auto` —— 和现在的默认 `0 1 auto` 不是一回事（少了"能压缩"），
  #    在矮屏幕上会把这一页顶出滚动条。类由这里和 app.js 两边一起管，
  #    规则长这样：`html.dsapp-fixed-composer .dsapp-composer{...}`。
  #
  # ⚠️ 类写在 `<html>` 上（documentElement），和变量同一层。写在内层的
  #    div 上的话，拖动期间 JS 得去 DOM 里找那个 div，而它可能还没渲染。
  tagList(
    tags$style(HTML(sprintf(
      paste0(":root{--dsapp-files-w:%dpx;--dsapp-composer-h:%dpx;",
             "--dsapp-sess-w:%dpx;--dsapp-menu-w:%dpx;--dsapp-tasks-w:%dpx;",
             "--dsapp-filespage-w:%dpx;}"),
      p$files_w, p$composer_h, p$sess_w, p$menu_w, p$tasks_w,
      p$filespage_w))),
    # ★ 紧跟一段脚本，干两件事。**必须和上面那条 style 一起发**：拆开发就有
    #   一帧是"变量到位了、类还没加"，用户看到的是输入区先弹回自动高度、
    #   再跳回去。跟着发的话它们同一次插入，中间没有那一帧。
    #
    #   一、把类补上。
    #
    #   二、★ 把拖动留下的**内联**变量清掉。不清的话内联值会一直压着样式表：
    #      用户在设置页把宽度从 420 改成 500，页面纹丝不动 —— 看起来像"设置
    #      页填了不生效"，而控制台一个错都没有。清掉之后这份 style 说了算。
    #
    #   ⚠️ 正在拖的时候不能清（清的那一下宽度会跳回上一次存的值），所以要问
    #      一下 app.js 立的那面旗子。两边就是靠 `window.dsappDragging` 对齐的。
    tags$script(HTML(paste0(
      "(function(){var d=document.documentElement;",
      "if(!window.dsappDragging){",
      # ⚠️ 这里**必须**把每个可拖的量都列上。漏一个的表现：那个量在设置页
      #    改完不生效 —— 拖动留下的内联值一直压着这一份 style，而控制台
      #    一个错都没有。V13.5 加 menu_w / tasks_w 时同步补上。
      "d.style.removeProperty('--dsapp-files-w');",
      "d.style.removeProperty('--dsapp-composer-h');",
      "d.style.removeProperty('--dsapp-sess-w');",
      "d.style.removeProperty('--dsapp-menu-w');",
      "d.style.removeProperty('--dsapp-tasks-w');",
      "d.style.removeProperty('--dsapp-filespage-w');}",
      "d.classList.toggle('dsapp-fixed-composer',", p$composer_h, ">0);",
      "})();")))
  )
}

#' 设置页那张「界面尺寸」卡片的**内容**（V13.2 item 5）
#'
#' ⚠️ 只返回 card_body 里的东西，外层的 card()/card_header() 由 mod_settings
#'    那边套 —— 和 dsapp_skin_picker() 一个约定。这里再套一层的话界面上会
#'    出现**两个标题**（一个"界面尺寸"、一个同名的），而这种小事没人会去报。
#'
#' ★ 为什么拖了分隔条还要有这张卡片：分隔条**只能用鼠标**。键盘用户、触摸板
#'   不好使的人、以及"我就想精确填个 420"的人，都得有一条别的路进去。
#'   （和 dsapp_skin_picker 放弃自拼 div、改用原生 radio 是同一个理由。）
#'
#' ⚠️ 「恢复默认」那颗按钮要有：拖歪了之后靠手拖回 320 是很难的。
dsapp_uipref_card <- function(ns, prefs) {
  p <- dsapp_uipref_norm(prefs)
  sp <- DSAPP_UIPREF_SPECS
  tagList(
    p(class = "text-muted small mb-3",
      "版面尺寸。每一栏都可以直接在页面上拖分隔线调 —— ",
      "拖完这里会跟着变；填数字是给「我就想精确填一个数」和键盘用户的路。"),
    fluidRow(
      # ★ V13.4 item 6 把这一行从两列改成三列；V13.5 item 2 / item 8 又加了
      #   两条（主菜单、历史任务页），现在是两行五格。
      #
      # ⚠️ 分成两组是为了**说清楚它们各自管哪儿**：第一行管全局（所有页面
      #    都看得见的两条栏），第二行只管某一个页面。混在一起排的话，
      #    「任务导航栏」和「主菜单」这两个名字没人分得清谁是谁。
      column(4,
        numericInput(ns("pref_menu_w"), "主菜单宽度（px）",
                     value = p$menu_w, min = sp$menu_w$min,
                     max = sp$menu_w$max, step = 10)
      ),
      column(4,
        numericInput(ns("pref_sess_w"), "任务导航栏宽度（px）",
                     value = p$sess_w, min = sp$sess_w$min,
                     max = sp$sess_w$max, step = 10)
      ),
      column(4,
        numericInput(ns("pref_files_w"), "文件区宽度（px）",
                     value = p$files_w, min = sp$files_w$min,
                     max = sp$files_w$max, step = 10)
      )
    ),
    fluidRow(
      column(4,
        numericInput(ns("pref_tasks_w"), "执行历史栏宽度（px）",
                     value = p$tasks_w, min = sp$tasks_w$min,
                     max = sp$tasks_w$max, step = 10)
      ),
      column(4,
        numericInput(ns("pref_composer_h"), "输入区高度（px，0 = 自动）",
                     value = p$composer_h, min = sp$composer_h$min,
                     max = sp$composer_h$max, step = 10)
      ),
      # ★ V14 item 1：文件页「文件管理区 ↔ 预览」那一格。
      #
      # ⚠️ 它和上面那个「文件区宽度」**名字长得像、管的是两个页面**：
      #    files_w 是「言出法随」页右边的产物栏（.dsapp-files-col），
      #    filespage_w 是「文件」页左边那一栏（.dsapp-files-list）。
      #    标签里必须把页面名写出来，不然用户改了其中一个、跑去另一个页面
      #    发现没变，只会认为"这个设置是坏的"。
      column(4,
        numericInput(ns("pref_filespage_w"), "文件管理区宽度（px）",
                     value = p$filespage_w, min = sp$filespage_w$min,
                     max = sp$filespage_w$max, step = 10)
      )
    ),
    p(class = "text-muted small",
      tags$b("主菜单"), "是最左边那条全局导航（所有页面都在），",
      tags$b("文件区 / 任务导航栏 / 输入区"), "只管「言出法随」那一页，",
      tags$b("执行历史栏"), "只管「历史任务」那一页，",
      tags$b("文件管理区"), "只管「文件」那一页",
      "（四者都是右边那栏吃剩下的宽度）。",
      "输入区填 0 表示由输入框自己撑开（默认）；调大它 = 上面的输出框变矮。",
      "窗口变窄时几栏会自动改成上下叠放，那时候宽度设置不起作用。"),
    # ★ V13.11 item 3：导航项的顺序**没有**输入框（顺序是拖出来的，填数字
    #   表达不了），但得在这儿说一声，否则用户拖乱了只会来问"怎么变回去"。
    #   「恢复默认」是 dsapp_uipref_norm(NULL)，一次把所有键都收回内置值，
    #   nav_order 也在里面 —— 所以不需要再给一颗单独的按钮。
    p(class = "text-muted small",
      tags$b("主菜单里的入口还可以拖着重排顺序"), "：鼠标移到某一项最左边的 ",
      tags$code("⠿"), " 上按住往上/下拖，松手就存下来，下次打开还是这个顺序。",
      "拖乱了点下面的「恢复默认」就回到内置顺序。"),
    actionButton(ns("pref_reset"), "恢复默认",
                 class = "btn-outline-secondary btn-sm")
  )
}

#' 设置页那张「离开页面之后」卡片的**内容**（V13.7 item 5）
#'
#' 用户原话：「需要在登出状态下，AI的思考和任务能够继续挂载执行，并且
#' 是否执行可以让用户预设选择」。
#'
#' ⚠️ 为什么这张卡片在这个文件里：它存的是 `users.ui_prefs` 那一列 JSON，
#'    和上面那张「界面尺寸」共用一套读写（dsapp_uipref_get / _save）。这个
#'    列名字里的 "ui" 是历史遗留 —— 它实际是"这个账号的一份杂项偏好"，
#'    加一列要 ALTER TABLE + 抬 schema 版本，为了一个三选一的开关不值当。
#'    见本文件顶部那段。所以：**存储**在这，**卡片**也放这，免得读写分家。
#'
#' ⚠️ 用原生 radio 而不是 select：三档的**差别是这段文案本身**，用户需要
#'    同时看见三个选项各自什么意思才能选。下拉框把另外两个藏起来了，
#'    而这是个人命关天的开关（选 full = 关掉页面之后还在花钱）。
dsapp_detach_card <- function(ns, prefs) {
  p <- dsapp_uipref_norm(prefs)
  # ⚠️ 取值用 [[]] 不用 $：以后万一有人把键名换成数字开头，$ 会静默返回
  #    NULL（本仓库在厂商名那处踩过，见 skills.R 附近的说明）。
  cur <- p[["agent_detach"]] %||% "finish"

  # ⚠️ 用 radioButtons + HTML 标签，不自己拼 div + input：键盘可达、断线
  #    重连后选中态能自己恢复，都是原生 radio 白送的（和 dsapp_skin_picker
  #    同一个理由，那段说明在 skins.R 里）。自己拼的话这些都要重做一遍，
  #    而且十有八九做不全。
  #
  # ⚠️ 这里的 HTML 全是本函数里的固定字符串，**没有任何用户输入拼进去** ——
  #    加新档位时也别加（同 dsapp_skin_picker 顶部那条警告）。
  choice_html <- function(title, desc) {
    HTML(paste0('<span class="dsapp-detach-opt"><b>', title, '</b>',
                '<span class="text-muted small">', desc, '</span></span>'))
  }

  tagList(
    p(class = "text-muted small mb-3",
      "关掉页面、退出登录之后，正在跑的自动执行怎么办。",
      "只有在你", tags$b("已经开着"), "自动执行时才有区别 —— 没有循环在跑的时候，",
      "关页面就是关页面，这三档都一样。"),
    radioButtons(
      ns("pref_detach"), NULL,
      choiceNames = list(
        choice_html("立刻停", "页面一关就停，不留任何后台进程，正在跑的任务会被中止。"),
        choice_html("让当前任务跑完（默认）",
                    "正在跑的那个任务跑完、结果写进这条对话；不会再开始新的一轮，也不会再叫模型。"),
        choice_html("一路跑完",
                    paste0("整个循环交给后台接着跑：等任务、看结果、继续下一步，",
                           "直到轮次或时长上限。",
                           "需要你本人在对话里点「执行」确认的那类代码，后台会停下来等你。"))
      ),
      choiceValues = c("off", "finish", "full"),
      selected = cur, inline = FALSE
    ),
    # ⚠️ 这句必须说，而且是**位置**上的说明：后台跑着的时候用户回来看什么、
    #    在哪儿能把它停掉。不写的话他只能猜，而猜错的代价是"以为停了、
    #    其实还在烧"或者反过来。
    p(class = "text-muted small mb-0",
      "后台在跑的时候，回到那条对话的顶部会看到一条提示，",
      "旁边就是「停止」—— 不用等到它自己跑完。")
  )
}

#' 设置页那张「AI 怎么干活」卡片的**内容**（V13.12 item 4）
#'
#' 用户原话：「请在用户第一次开启任务时让用户选择是否自动执行和出错自动修，
#' 然后记住用户的默认设置，新会话生效」。
#'
#' 第一次那个弹窗是**问一次**，这张卡片是**改主意的地方**。没有它的话，
#' 用户在弹窗里手一滑选了"都先别开"，就再也找不到开关了 —— 对话页那两个
#' 复选框他多半不知道是"只改当前对话"的。
#'
#' ⚠️ 和对话页那两个复选框是**两个东西**：这里改的是"下一条新对话的默认"，
#'    对话页改的是"这一条"。文案里必须写清楚，否则用户会以为设置页这个
#'    开关坏了（改了，当前对话纹丝不动）。
#'
#' ⚠️ 用 checkboxInput 而不是自己拼 <input>：见 mod_chat.R 里那段说明 ——
#'    Shiny 靠 class 认领控件，手写的那个 input$ 永远是 NULL，表现是
#'    "点了没反应"而且不报错。
dsapp_agent_pref_card <- function(ns, prefs) {
  p <- dsapp_uipref_norm(prefs)
  tagList(
    p(class = "text-muted small mb-3",
      "每开一条", tags$b("新对话"), "时，「自动执行」和「出错自动修」默认是什么状态。",
      "当前这条对话里的开关不受影响 —— 那两个在「言出法随」页的输入框上面，",
      "随开随关。"),
    checkboxInput(ns("pref_agent_auto"),
                  label = paste0("自动执行：不用每步点确认，AI 自己一轮轮往下做",
                                 "（会持续消耗 token，默认关）"),
                  value = isTRUE(p$agent_auto)),
    checkboxInput(ns("pref_agent_autofix"),
                  label = paste0("出错自动修：任务跑挂了之后，AI 自己读报错、",
                                 "改代码或补依赖、然后重跑一遍（默认开）"),
                  value = isTRUE(p$agent_autofix)),
    p(class = "text-muted small mb-0",
      "关掉「出错自动修」之后，运行报错会原样摆出来等你处理；",
      "开着的时候，它自己造的错（语法、变量名、缺包）会被它自己接手，",
      "对话里不再显示。",
      tags$b("运行过程中的警告两种情况下都不显示"), "—— 它们不影响结果，",
      "需要的时候可以从执行记录那张卡片里翻出来。")
  )
}

#' 设置页 · 「邮件提醒」那张卡片的内容（★ Test_V15.2 item 2）
#'
#' @param ns   命名空间函数
#' @param prefs 归一化过的偏好
#' @param email 收件地址（= `users.email`，由调用方查好传进来）
#'
#' ⚠️ 这张卡片的**外框**在 mod_settings.R 里，而且整张卡只在
#'    `dsapp_mail_ready(cfg)` 为真时出现 —— 没配 SMTP 的部署（Windows 便携包、
#'    用户自托管）看不到它，也不会点到一个必然报错的按钮。理由见
#'    `dsapp_mail_ready()` 的 D4 说明。
#'
#' ⚠️ 收件地址是**只读**的，就是登录邮箱。不给"另填一个地址"的输入框：
#'    那样就有了两个地址、两处真相，用户改了一个以为生效了其实是另一个。
#'    要换地址就去「账号」那一栏换登录邮箱。
dsapp_mail_pref_card <- function(ns, prefs, email = "") {
  p <- dsapp_uipref_norm(prefs)
  to <- as.character(email %||% "")[1]
  tagList(
    p(class = "text-muted small mb-3",
      "任务跑完之后、或者定时订阅出了新的文献速递之后，往你的邮箱发一封信。",
      "下面两个开关", tags$b("默认都是关的"), "—— 没勾之前一封都不会发。"),

    # ⚠️ 收件地址就是 users.email，**只读显示**。不加"另填一个地址"的输入框：
    #    那样就有了两个地址、两处真相，用户改了一个以为生效了其实是另一个。
    #    （类名用 Bootstrap 现成的，不自己造 —— 造了就得同时改 app.css，
    #      漏一边的表现是这一行完全不显示，而且不报错。）
    div(class = "mb-3",
      tags$span(class = "text-muted", "收件地址："),
      if (nzchar(to)) tags$code(to)
      else tags$span(class = "text-danger", "（这个账号没有填邮箱）"),
      tags$div(class = "text-muted small",
               "就是你的登录邮箱。要换地址，去「账号」那一栏改。")),

    checkboxInput(ns("pref_mail_task"),
                  # ⚠️ 说清楚"另一处在哪儿"。同一个键有两个入口，用户在其中
                  #    一处改了、到另一处发现状态不一样的话，会以为设置没保存。
                  #    （另一处在「言出法随」页**最下面**那排控件里，所以写
                  #      "最下面那排"，不写"上面"。V12 item 1 把那一排从输入框
                  #      上方挪到底部了，写错方向等于指错地方。）
                  label = paste0("任务跑完 / 失败之后发一封",
                                 "（「言出法随」页最下面那排控件里也有这个开关，",
                                 "两处改的是同一个设置）"),
                  value = isTRUE(p$email_task)),
    checkboxInput(ns("pref_mail_lit"),
                  label = "定时订阅跑完之后，把整份文献速递发到邮箱",
                  value = isTRUE(p$email_lit_done)),

    div(class = "mt-2",
      actionButton(ns("mail_test"), "发一封测试邮件",
                   class = "btn-sm btn-outline-secondary",
                   icon = icon("paper-plane")),
      # ⚠️ 回执必须是**自己一个 output**，不能塞进 actionButton 旁边写死 ——
      #    它要显示"正在发 / 发出去了 / 失败了"，写死就等于这三个状态
      #    永远显示同一个。理由和本文件里那些尺寸卡片一样。
      uiOutput(ns("mail_test_msg")))
  )
}
