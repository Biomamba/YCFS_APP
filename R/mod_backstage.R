# =============================================================================
# 「后台管理」：把原来的「管理」页和「后台」页合成一页（★ V15.4 item 7）
# =============================================================================
# 用户原话：「请合并管理和后台界面，生成一个"后台管理"界面，原有的组间请以
#           合理的分类生成子界面」。
#
# 两页原来是左栏里的两项：`admin`（管理，项目管理员 + 平台管理员）和
# `htadmin`（后台，只有平台管理员）。合并之后左栏只剩一项「后台管理」，
# 里面用四个子页签分装那 14 张卡片（用户在两选一里选的"4 组"）：
#
#   平台总览   —— 服务器健康 · 平台用量 · 磁盘占用 · 平台账号概览
#   用户与权限 —— 用户 · 团队 · 登录锁定 · 用户活跃情况
#   运行与日志 —— 各用户的任务运行情况 · 操作日志 · 应用报错日志
#   资源与文件 —— token 用量 · 可调用硬件资源 · 文件管理区的归属
#   提示词     —— 系统提示词编辑器（V15.4 item 8 的新能力）
#
# ⚠️ 「两种管理员都能进，但进去看到的界面不一样」（用户对这个问题的原话）。
#    "不一样"落在三处，别只做其中一处：
#      1. 「平台总览」和「提示词」两个**子页签**对项目管理员根本不存在；
#      2. 中间三页里，平台专属的那几张卡不渲染（门控留在各自的 cards 函数里，
#         见 R/mod_admin.R / R/mod_htadmin.R）；
#      3. 写操作的**服务端**鉴权一点没松 —— 那两道闸分别在
#         mod_admin_server / mod_htadmin_server 里，这次一个字都没动。
#
# ⚠️⚠️ `nav_panel` 的 value 仍然钉成 `"admin"`，**不能**跟着标题改成
#    "backstage"：全仓有多处 `bslib::nav_select("nav", "admin")` 和
#    `data-nav` 的跳转（见 app.R 那段 ⚠️）。改 value 的症状是"点了没反应"，
#    而且不报错。左栏那一项也一样（R/uiprefs.R 的 DSAPP_NAV_ITEMS）。
#
# ⚠️ 两个老 server 仍然**无条件注册**（app.R 的 mod_admin_server("admin") /
#    mod_htadmin_server("htadmin")）。不要因为"项目管理员看不到那几张卡"就
#    改成 `if (is_platform)`：注册和渲染是两件事，页面上渲不渲染由这里这道
#    UI 闸决定，模块里每个 handler 开头的 guard() 是第二道。少注册一个的
#    症状是 `output ... not found` 或者整块空白。
# =============================================================================

#' 「后台管理」整页
#'
#' @param id 命名空间。**必须是 "admin"** —— 它在两处都对着一份已经存在的
#'   server：管理页那 10 张卡的 `ns("...")` 要落回 `mod_admin_server("admin")`，
#'   后台页那 4 张卡要落回 `mod_htadmin_server("htadmin")`（所以那半边用的是
#'   另一个前缀 `NS("htadmin")`，见下面）。
#' @param scope 这个账号的管理范围（"platform" / "project"）。
#'
#' ⚠️ 这一整棵树跑在 app.R 的 `output$app_root` 里面，所以**不能读任何
#'    `state$`**：读一下就等于让整个应用外壳（左栏、对话页、任务页……）依赖
#'    于那个值，每变一次就整页重渲（理由与现场见 R/mod_settings.R 那段长注释）。
#'    `scope` 是这里唯一的"身份输入"，它是**普通值**（app.R 在渲染前算好的），
#'    不是 reactive —— 这一点别顺手改掉。
mod_backstage_ui <- function(id = "admin", scope = "platform") {
  ns  <- NS(id)         # 管理页那 10 张卡：对齐 mod_admin_server("admin")
  ns2 <- NS("htadmin")  # 后台页那 4 张卡：对齐 mod_htadmin_server("htadmin")
  platform <- identical(as.character(scope %||% "")[1], "platform")

  # 卡片在**这里**现取。两个 cards 函数是纯函数，自己会按 scope 把平台专属
  # 的条目置成 NULL（不是靠 CSS 藏）—— 所以下面不用再判一次。
  a <- mod_admin_cards(ns, scope)
  h <- mod_htadmin_cards(ns2, scope)

  navset_underline(
    id = ns("bs_tab"),

    # ⚠️「平台总览」整页平台专属：四张卡里三张是整机/全平台口径，一张
    #    （平台账号概览）是全站账号的分布。项目管理员在这里没有可做的事，
    #    而"看得到但做不了"比"看不到"更容易让人以为是自己没权限。
    if (platform) nav_panel("平台总览", value = "overview",
      tagList(
        a$health,
        a$top_row,
        h$accounts
      )
    ),

    # 用户与权限：前三个都开（项目管理员管的是自己组里那一片，同一个界面、
    # 查询范围由 server 按 scope 收窄）；「用户活跃情况」是全站口径，只给平台。
    nav_panel("用户与权限", value = "users",
      tagList(
        a$users,
        a$teams,
        a$logins,
        h$activity
      )
    ),

    # 运行与日志：任务和操作日志按 scope 收窄（项目管理员只看得到自己组的人）；
    # 应用报错日志整张卡平台专属 —— 报错栈里会带上文件名和工作区名。
    nav_panel("运行与日志", value = "runs",
      tagList(
        a$tasks,
        a$audit,
        h$errors
      )
    ),

    # 资源与文件：token 用量按 scope 收窄；硬件资源和文件归属是平台级的
    # 分配动作（"这个人能用几张卡"、"这个区归谁"），只给平台管理员。
    nav_panel("资源与文件", value = "res",
      tagList(
        a$usage,
        h$limits,
        a$files
      )
    ),

    # ★ V16.6 item 1：信息同步跳板。**整页平台专属** —— 它管的是"这台机器
    #   允许谁来、允许谁被建号"，而「允许同步建号」那个开关一旦被打开，
    #   任何能往同步目录里放包的人就能给任意邮箱建号。这和"谁能改账号级别"
    #   是同一个重量级的东西，所以判据也一样（平台管理员）。
    #
    #   ⚠️ `h$syncjump` 在非平台管理员那里是 **NULL**（mod_htadmin_cards
    #      整个返回空 list）。但这里仍然显式判一次 `platform` —— 两个独立
    #      的判据总比一个强，而且 tagList 里混进 NULL 是合法的（什么都不画），
    #      万一哪天卡片函数改成"返回但置空"，这一页不会变成一个空白页签。
    if (platform) nav_panel("信息同步", value = "sync",
      tagList(
        h$syncjump
      )
    ),

    # ★ V15.4 item 8：系统提示词。**平台专属** —— 它改的是**每一个请求**
    #   发给模型的东西，等于全平台的行为开关。项目管理员看不到这个页签，
    #   服务端那边每一条写库的路还会再过一次 guard()（两道，见 mod_prompt.R）。
    #
    # ⚠️ 这一格用的是**自己的**命名空间 `NS("prompt")`，不是 `ns`。理由：
    #    它的 server 和另外两组一样在 app.R 里**平级注册**
    #    （`mod_prompt_server("prompt", state)`），不套在谁的 moduleServer
    #    里面 —— 套进去就得回答"嵌套的 moduleServer 到底加不加前缀"，
    #    而那个答案随 Shiny 版本变，错了的症状是"**按钮点了没反应**、
    #    也不报错"（input 名对不上，observer 永远不触发）。
    #    平级注册 + 显式前缀，两边一眼能对上。
    if (platform) nav_panel("提示词", value = "prompt",
      mod_prompt_ui(NS("prompt"))
    )
  )
}

# ⚠️ 这里**没有** `mod_backstage_server()`，是有意的：这一页只有 UI 是新的，
#    三组 server（管理页 10 张卡 / 后台页 4 张卡 / 提示词编辑器）都在 app.R 里
#    平级注册，各自的命名空间就是它们 UI 用的那个（"admin" / "htadmin" /
#    "prompt"）。包一层空壳 server 只会让"哪张卡在哪个 ns 下"变成一件要顺着
#    调用链读的事，而这三组 handler 加起来有两千多行。
