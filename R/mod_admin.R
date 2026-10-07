# =============================================================================
# 管理页（只有管理员看得到）
# =============================================================================
# V5 引入。Python 版原本承担着"完整多用户平台"的角色 —— 用户列表、用量统计、
# 系统监控、停用/删除/重置。V5 放弃 Python 版（外网端口不方便转发）之后，
# 这些能力得在 R 版里有对应的东西，否则"多用户"只剩下一张注册表，出事时
# 管理员没有任何手段：有人注册了垃圾账号删不掉，有人忘了密码帮不了，
# 磁盘被谁的工作区吃满了也看不出来。
#
# 这里提供三块：
#   1. 平台用量 —— 用户/对话/任务数与磁盘占用。生信数据大，磁盘是最先
#      出问题的地方（一个 .venv 几百 MB，一个 h5ad 几个 G）。
#   2. 用户管理 —— 停用/启用、重置恢复码、删除账号。
#   3. 数据归属 —— 共享区文件归谁、没有归属的划给谁。
#
# ⚠️ 管理页**不显示**任何用户的数据内容（对话正文、任务输出、文件内容）。
#    管理员需要的是"这个人在用、用得怎么样"，不是"他在分析什么"。
#    生信数据常常是未发表的，能少一个人看到就少一个人。
# =============================================================================

#' @param scope 看这一页的人的管理员级别（`""` / `"project"` / `"platform"`），
#'   由 app.R 用 dsapp_user_admin_scope(user) 算好传进来。
#'
#'   ★ V13.8 item 1：这一页原来没有这个参数 —— 它假定"能进来的就是平台管理员"。
#'   分了两级之后，有几张卡说的是**整台机器和整个平台**的事（健康、磁盘、
#'   全站账号数），项目管理员看这些既没有用、也超出了他该看到的范围，所以
#'   在渲染这一层就不给他们（`if (platform)`）。
#'
#'   ⚠️ 这里**只管看不看得见**。"动得了动不了"是另一回事，判在 server 里
#'      （见 mod_admin_server 顶部那段），而且**每一条写库的路都要自己判**。
#'      只靠这一层的话，藏起来的卡片、藏起来的按钮都挡不住一个自己拼
#'      input 值的人，而这一页的按钮里有「删除账号」。
#' 管理页的卡片：**一张一个命名条目**（★ V15.4 item 7）
#'
#' 原来这里是一整个 `tagList`（一页堆到底），现在按卡片返回，由
#' R/mod_backstage.R 把它们分进四个子页。拆开的只是"怎么分组"，**渲染什么
#' 一个字没动**，而且 `ns` 还是同一个（`NS("admin")`）—— 所以 mod_admin_server
#' 那边一行都不用改，两边的 `ns("...")` 自然对得上。
#'
#' ⚠️ `scope` 那一层门控**留在卡片自己身上**（`if (platform)`），没有搬到调用
#'    方：搬过去就有两个地方决定"这张卡给不给项目管理员"，两边一旦不一致，
#'    症状是某个身份看到半张页面 —— 而这是权限相关的，宁可不给也不能多给。
#'    没渲染出来的条目是 NULL，`tagList()` 自己会把 NULL 丢掉。
#'
#' ⚠️ `top_row` 是**两张卡一组**（平台用量 + 磁盘占用）：它们并排一行是布局上
#'    的决定，拆成两个条目的话，每个用到它的地方都要自己再写一遍
#'    `layout_columns(col_widths = c(6, 6), ...)` —— 改了一处漏另一处，
#'    而表现只是"这两张卡在某些身份下不并排了"，没人会当成 bug 去查。
mod_admin_cards <- function(ns, scope = "platform") {
  platform <- identical(as.character(scope %||% "")[1], "platform")

  list(
    # 服务器健康。放在**最上面**：这一页别的卡片说的都是"平台里有什么"，
    # 只有这一块说的是"这台机器还撑不撑得住"。磁盘满、内存告急的时候，
    # 管理员打开这一页第一眼要看到的正是它 —— 而不是先滚过三张表。
    #
    # ⚠️ 只给平台管理员。它读的是整机计数器（CPU / 内存 / 磁盘 / 执行槽位），
    #    而执行槽位是**全应用共用一个** —— 项目管理员看到"槽位满了"也做不了
    #    任何事，只会在自己组的人提交不了任务时以为是自己的问题。
    health = if (platform) card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("heart-pulse"), " 服务器健康", uiOutput(ns("health_badge"), inline = TRUE)),
        actionButton(ns("health_refresh"), NULL, icon = icon("rotate"),
                     class = "btn-sm btn-outline-secondary", title = "立即重新采集")
      ),
      card_body(uiOutput(ns("health")))
    ),

    top_row = if (platform) layout_columns(
      col_widths = c(6, 6),

      card(
        card_header(icon("chart-simple"), " 平台用量"),
        card_body(uiOutput(ns("stats")))
      ),

      card(
        card_header(
          class = "d-flex justify-content-between align-items-center",
          span(icon("database"), " 磁盘占用"),
          actionButton(ns("refresh"), NULL, icon = icon("rotate"),
                       class = "btn-sm btn-outline-secondary")
        ),
        card_body(uiOutput(ns("disk")))
      )
    ),

    usage = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("coins"), " token 用量"),
        span(class = "small text-muted fw-normal",
             "按天和按账号，不含对话内容")
      ),
      card_body(uiOutput(ns("usage")))
    ),

    users = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("users"), " 用户"),
        span(class = "small text-muted fw-normal",
             "停用后该账号无法登录，但数据都留着")
      ),
      # ⚠️ V13.10 item 3：`fillable = FALSE` 是"账号表格压住下面按钮"的**根因
      #    修复**。用户原话：「管理页面的账号表格有时会与下方按钮重叠，请做好
      #    页面的自适应」。
      #
      #    这就是 V13.2 item 3 在任务页修过的同一个 bug —— 任务页/文件页都改
      #    了，管理页**漏了**（`grep -c fillable R/mod_admin.R` 在这一版之前是
      #    0）。三层默认值叠出来的：
      #
      #      1. bslib 的 card_body 默认 fillable，卡体是个 `.html-fill-container`
      #         （flex 列）；
      #      2. htmltools 的 fill.css 把带 html-fill-item 的孩子设成
      #         `flex: 1 1 auto; min-height: 0`；
      #      3. DT 的 datatables-crosstalk.css 还有一条
      #         `.html-fill-container > .html-fill-item.datatables{flex-basis:400px}`。
      #
      #    结果是**表格成了卡体里唯一能伸缩的孩子**，按钮行和提示文字都是
      #    `flex: 0 0 auto`。行数一多、视口一矮，表格就被压到内容高度以下，
      #    直接画在后头的按钮行身上 —— 按钮行没背景色、DT 行也是透明的，
      #    看上去就是"糊在一起"。所以是"**有时**"：行数少/窗口高的时候不出现。
      #
      #     理由和别的参考实现写在 R/mod_tasks.R:47-68，这里不重复。
      #    后台页（R/mod_htadmin.R）是同一个结构，同步改。
      card_body(
        fillable = FALSE,
        # 筛选条。用户表是**唯一**能按账号操作的地方（停用、重置密码、设配额、
        # 删号），账号一多就要靠它定位 —— 而且这几个按钮都作用在"选中的那一行"
        # 上，选错行的代价是停用了别人。
        div(class = "d-flex gap-2 align-items-end mb-2 flex-wrap",
          div(class = "flex-grow-1", style = "min-width:170px;",
            textInput(ns("u_kw"), NULL, placeholder = "搜昵称 / 邮箱 / 研究方向")),
          div(style = "min-width:110px;",
            selectInput(ns("u_role"), NULL, width = "100%", selectize = FALSE,
                        choices = c("（全部角色）" = "", "管理员" = "admin",
                                    "普通用户" = "user"))),
          div(style = "min-width:110px;",
            selectInput(ns("u_status"), NULL, width = "100%", selectize = FALSE,
                        choices = c("（全部状态）" = "", "启用" = "active",
                                    "停用" = "disabled"))),
          div(style = "min-width:130px;",
            selectInput(ns("u_pw"), NULL, width = "100%", selectize = FALSE,
                        choices = DSAPP_USER_PW_CHOICES)),
          actionButton(ns("u_clear"), NULL, icon = icon("xmark"),
                       class = "btn-sm btn-outline-secondary mb-3",
                       title = "清空筛选")
        ),
        uiOutput(ns("u_count")),
        # ★ V13.10 item 3：跟任务页/文件页一样套一层 `.dsapp-dt-nowrap` ——
        #   这张表有 14 列（ID…最后活跃），窄窗口下不 nowrap 就会每格折成
        #   三行、行高撑得老高。套上之后过宽由这一层横向滚，见
        #   www/app.css 的 .dsapp-dt-nowrap（连同 options 里的 autoWidth=FALSE，
        #   三件事缺一不可）。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("tbl"))),
        div(class = "d-flex gap-2 mt-3 flex-wrap",
          actionButton(ns("toggle"), "停用 / 启用",
                       class = "btn-sm btn-outline-warning",
                       icon = icon("ban")),
          actionButton(ns("reset_token"), "重置恢复码",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("key")),
          actionButton(ns("reset_pw"), "重置密码",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("lock")),
          actionButton(ns("set_email"), "改登录邮箱",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("at")),
          # ★ V13.12 item 3：原来这里是**两个**按钮（「设置配额」「资源上限」），
          #   现在合成一个。「配额」这个词单独摆着会让人以为它管的是 CPU 和
          #   内存（用户自己就是这么理解的），而它其实只管磁盘。合并之后
          #   标题里两样都写上，弹窗里再分成两段说清楚。
          actionButton(ns("set_quota_limits"), "配额与资源上限",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("sliders")),
          # ★ V13.8 item 1：删除账号**只给平台管理员**。用户的原话把这件事
          #   划在平台管理员那一边（"平台管理员可以更改、添加、删除平台内
          #   所有的账号与任务"），项目管理员拿到的是"查看并更改组内的账号
          #   成员"—— 「更改」不包括删号，而删号会连带删掉那个人所有对话、
          #   工作区和环境，是不可逆的。
          #   server 里那一道同样是硬拦，不只是这里藏按钮。
          if (platform) actionButton(ns("delete"), "删除账号",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("trash"))
        ),
        uiOutput(ns("action_msg"))
      )
    ),

    tasks = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("gauge-high"), " 各用户的任务运行情况"),
        span(class = "small text-muted fw-normal",
             "只看状态和耗时，看不到代码和输出")
      ),
      card_body(
        fillable = FALSE,
        p(class = "small text-muted",
          "按账号查他名下跑过什么 —— 出问题时第一个要回答的问题就是",
          dsapp_md_inline("「他到底提交了什么、跑成功没有」。这里显示的是**归属**："),
          "别人共享给他的对话不在里面（那些不是他的任务）。"),
        div(class = "d-flex gap-2 align-items-end mb-2 flex-wrap",
          div(style = "min-width:230px;", uiOutput(ns("ut_user_sel"))),
          div(style = "min-width:130px;",
            # selectize = FALSE：「全部状态」的值是空串，selectize 会把它当成
            # placeholder 从菜单里删掉，于是选过之后就再也回不到「全部」。
            # 旁边几个筛选下拉踩过同一个坑（见日志卡里的注释）。
            selectInput(ns("ut_status"), NULL, width = "100%",
                        selectize = FALSE,
                        choices = c("（全部状态）" = "", "成功" = "success",
                                    "失败" = "failed", "出错" = "error",
                                    "超时" = "timeout", "运行中" = "running",
                                    "排队中" = "pending"))),
          actionButton(ns("ut_refresh"), NULL, icon = icon("rotate"),
                       class = "btn-sm btn-outline-secondary mb-3",
                       title = "重新查询")
        ),
        uiOutput(ns("ut_stats")),
        # V13.10 item 3：同一处自适应修复（表格是卡体里唯一能伸缩的孩子，
        # 会被压到内容高度以下）。这张卡下面没有兄弟元素，所以不会"压住按钮"，
        # 但会**把行裁掉**。现在按内容长高，滚动交回 .dsapp-main-body。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("ut_tbl")))
      )
    ),

    logins = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("lock"), " 登录锁定"),
        actionButton(ns("unlock_all"), "全部解锁", icon = icon("unlock"),
                     class = "btn-sm btn-outline-secondary")
      ),
      card_body(
        p(class = "small text-muted",
          "同一个邮箱连续登录失败若干次会被临时锁定（默认 8 次 / 15 分钟，",
          "见 .Renviron 的 DSAPP_LOGIN_MAX_FAIL）。这里列出当前还在锁定中的",
          "账号 —— 有人被锁在门外又等不及的话，在这里解锁。"),
        uiOutput(ns("locks"))
      )
    ),

    audit = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("list-check"), " 操作日志"),
        span(class = "small text-muted fw-normal",
             "谁在什么时候干了什么；不记对话内容和文件内容")
      ),
      card_body(
        fillable = FALSE,
        div(class = "d-flex gap-2 flex-wrap align-items-end mb-3",
          div(style = "min-width:190px;", uiOutput(ns("au_user_sel"))),
          div(style = "min-width:190px;", uiOutput(ns("au_action_sel"))),
          div(style = "min-width:130px;",
            # selectize = FALSE 的理由和旁边两个下拉一样：「全部」的值是空串，
            # selectize 会把它当成 placeholder 从菜单里删掉，于是选过 7 天之后
            # 就再也回不到「全部」，只能刷新页面。
            selectInput(ns("au_days"), "时间范围", width = "100%",
                        selectize = FALSE,
                        choices = c("最近 24 小时" = "1", "最近 7 天" = "7",
                                    "最近 30 天" = "30", "全部" = ""),
                        selected = "7")),
          div(style = "min-width:150px;",
            textInput(ns("au_kw"), NULL, placeholder = "关键词（邮箱/文件名）")),
          div(class = "form-check mb-2",
            tags$input(type = "checkbox", class = "form-check-input",
                       id = ns("au_fail_only")),
            tags$label(class = "form-check-label small", `for` = ns("au_fail_only"),
                       "只看失败/被拒")),
          actionButton(ns("au_refresh"), NULL, icon = icon("rotate"),
                       class = "btn-sm btn-outline-secondary mb-2")
        ),
        uiOutput(ns("au_stats")),
        # V13.10 item 3：同上。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("au_tbl")))
      )
    ),

    teams = card(
      card_header(icon("people-group"), " 团队"),
      card_body(
        uiOutput(ns("teams_ui"))
      )
    ),

    # 文件归属只给平台管理员。这一卡列的是**每个账号**（列里带邮箱）各自
    # 占了多少文件，项目管理员能管的账号只是其中一片 —— 按片显示要另写一套
    # 渲染，而"改名/删除别人的文件"这件事本身就不在他的范围里
    # （判据见 dsapp_file_can_edit，V13.8 起收窄成平台管理员）。
    files = if (platform) card(
      card_header(icon("folder-tree"), " 文件管理区的归属"),
      card_body(
        p(class = "small text-muted",
          dsapp_md_inline("★ V13 起文件管理区是**按账号分开的**（data/files/u<账号>/）："),
          "每个账号只看到自己的区，别人的文件在界面上列不出来，路径也解析",
          dsapp_md_inline("不过去。这里管的是**区里面**「谁能改名和删除」：自己的随便动，"),
          "没有归属记录的人人可动（V5 之前传进来的那些），",
          "别人的只有管理员能动。"),
        uiOutput(ns("files")),
        # ★ V16.6 item 3：盘上没有主人的管理区目录（u<N> 存在、users 里没有这个
        #   id）。删号删干净之后这里应该一直是空的；露出来的那些就是
        #   「删过的账号，文件还在共享区里」那批历史遗留。
        uiOutput(ns("orphan_dirs"))
      )
    )
  )
}

mod_admin_server <- function(id, state, engine = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    # ---- 管理范围（V13.8 item 1）--------------------------------------------
    #
    # 用户的原话：「管理页面需要区分项目管理员和平台管理员，项目管理员只能
    # 查看并更改自己分发出去的任务、组内的账号成员，而平台管理员可以更改、
    # 添加、删除平台内所有的账号与任务」。
    #
    # ⚠️ 这一页原来**一道服务端鉴权都没有** —— 唯一的闸门是 app.R 里那道
    #    `if (is_admin)` 的 UI 闸。进得来就等于什么都能干。分两级之后必须
    #    把"看得见"和"动得了"分开管：UI 那道只回答"进不进得来"，进来之后
    #    每一次写库都在下面这里再判一次。
    #
    #    藏按钮挡得住误点，挡不住一个自己拼 input 值的人（Shiny 的 input
    #    就是 HTTP 上来的一个值），而这一页的按钮里有「删除账号」和
    #    「重置密码」。
    #
    # 两个范围的实际算法在 R/users.R（dsapp_admin_scope_user_ids /
    # dsapp_admin_scope_session_ids），那里的注释解释了"组内""分发出去"
    # 各自对应哪一列。这里只做一件事：**每次用之前从库里现读一次身份**。

    # 当前这个人的**实时**身份行。
    #
    # ⚠️ 不用 state$user。那是登录那一刻的快照，而 state 在会话建立后就
    #    不再更新 —— 一个刚被降成项目管理员的人，在他那个已经开着的标签页里
    #    会一直按平台管理员行事，直到他刷新页面。管理权限这种量级的东西
    #    不能留这种时间差，代价不过是每次重算一次主键查询。
    me <- reactive({
      id <- state$user_id
      if (is.null(id) || length(id) != 1 || is.na(id)) return(NULL)
      tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)), error = function(e) NULL)
    })

    is_platform <- reactive({ dsapp_user_is_platform_admin(me()) })

    # 能管的账号 id。**NULL = 不限**（平台管理员），integer(0) = 一个都管不了。
    # 这两个值在下面长得像但意思相反，判错一个方向就是"平台管理员什么都
    # 看不见"，所以调用方一律用 is.null() 判，不要用 length()。
    #
    # ⚠️ 依赖 refresh()：组的成员是在这一页上改的，改完不重算的话，
    #    刚加进来的人要等 60 秒（那个定时器）才会出现在他能管的名单里。
    my_user_ids <- reactive({
      refresh()
      dsapp_admin_scope_user_ids(me(), con = dsapp_db(cfg))
    })

    # 能管的对话 id。同上，NULL = 不限。
    my_sess_ids <- reactive({
      refresh()
      dsapp_admin_scope_session_ids(me(), con = dsapp_db(cfg))
    })

    # 两个动作级的判据。**每一个写库的 handler 都要过一道**，包括那些
    # 参数看起来"不可能来自界面"的 —— 见上面那段。
    can_user <- function(id) {
      dsapp_admin_can_touch_user(me(), id, con = dsapp_db(cfg))
    }
    can_team <- function(tid) {
      if (is_platform()) return(TRUE)
      u <- me()
      if (is.null(u)) return(FALSE)
      t <- tryCatch(
        DBI::dbGetQuery(dsapp_db(cfg),
          "SELECT created_by FROM teams WHERE id = ?",
          params = list(as.integer(tid))),
        error = function(e) NULL)
      if (is.null(t) || nrow(t) == 0) return(FALSE)
      identical(as.integer(t$created_by[[1]]), as.integer(u$id))
    }

    # 被挡下来时统一说这一句。**不透露"那个账号存在但不在你的范围里"** ——
    # 那等于把全平台有哪些账号告诉他了，正是这一版要收住的东西。
    deny <- function(what = "这个账号") {
      note(sprintf("%s不在你的管理范围内。", what), "warning")
    }

    refresh <- reactiveVal(0)
    msg <- reactiveVal(NULL)
    # 手动"立即刷新"用。改这个值会让 health() 重算，重算前先把采集缓存清掉，
    # 否则点刷新会和 5 秒缓存撞上、界面纹丝不动（看起来像按钮坏了）。
    health_ver <- reactiveVal(0)

    # 每分钟对一次用量。这一页常年开着的时候（比如你在盯磁盘），
    # 数字不动会让人以为坏了。
    #
    # ⚠️ 是 **60 秒**不是 10 秒，而且这里的 `refresh(...)` 必须真的**写**一次 ——
    #    原来的写法是 `observe({ refresh(); invalidateLater(10000) })`：只**读**
    #    不写，依赖值永远是 0，于是 observer 每 10 秒空跑一趟，下游一个都没失效。
    #    注释写着"每 10 秒对一次"，实际上一秒都没对过（走查时发现的）。
    #
    #    为什么是 60 秒：stats() 里每个字节数都是一次 `du -sb`，而 du 要递归
    #    遍历整个数据目录 —— 那可能是几个 T。10 秒一次、再乘上开着的标签页数，
    #    等于拿运维页面把磁盘拖垮。用户的**数量**本来也不会在 10 秒里变。
    #    要立刻看最新值就用卡片上的刷新按钮。
    observe({
      invalidateLater(60000)
      refresh(isolate(refresh()) + 1)
    })

    # ---- 服务器健康 ----
    #
    # 采集和判定都在 R/health.R 里（纯函数在那边，selftest 够得着）。
    # 这里只做一件那边做不了的事：**在响应式上下文里**把引擎状态读成普通值。
    # engine$state 是 reactiveValues，扔进 dsapp_health_summary() 里读会
    # 直接报 "Can't access reactive value outside of reactive consumer"，
    # 整块卡片变空白 —— 所以先读后传。
    health <- reactive({
      # V9 item 6。用户的原话：「服务器健康刷新太频繁了，要么改成实时同步，
      # 要么改为 60s 刷新一次」。原来这里是 3 秒一次。
      #
      # 选的是**两条路一起走**，因为它们回答的是两个不同的问题：
      #
      #   * 机器那几项（CPU / 内存 / 磁盘）3 秒变不出新东西 —— 采集一次
      #     要读 /proc、跑 df，开着的每个管理页都在重复这件事。60 秒
      #     （底层还有 5 秒 TTL 缓存兜着）足够，而"我刚清了一堆文件想看看
      #     降下来没有"这种即时需求由卡片头上那颗「立即重新采集」按钮负责。
      #
      #   * **执行槽位是秒级变化的**（任务起、任务止），而它恰恰是管理员
      #     最需要准的那一格：用户被挡在门外的时候看到「空闲」，会去查错的
      #     方向。它不需要轮询 —— 状态就活在 engine$state 里，**下面读它
      #     一下就是订阅**：任务一起一止，这个 reactive 立刻失效重算。
      #     这就是那半句"实时同步"，而且比轮询更实时（是推送，不是发现）。
      invalidateLater(60000)
      health_ver()       # 「立即刷新」也走这条
      if (!is.null(engine)) engine$state$running   # ← 起止任务时立刻重算
      eng <- NULL
      if (!is.null(engine)) {
        tid <- tryCatch(engine$current_task_id(), error = function(e) NULL)
        if (!is.null(tid)) {
          # 跑了多久问数据库要 started_at，不问引擎 —— 引擎里没存开始时间，
          # 而这一列本来就有（db.R 的 tasks 表）。
          started <- tryCatch({
            r <- DBI::dbGetQuery(dsapp_db(cfg),
                   "SELECT started_at FROM tasks WHERE id = ?",
                   params = list(as.integer(tid)))
            if (nrow(r) > 0) r$started_at[1] else NA_character_
          }, error = function(e) NA_character_)
          eng <- list(busy = TRUE, task_id = tid,
                      elapsed = dsapp_since_seconds(started))
        } else {
          eng <- list(busy = FALSE)
        }
      }
      res <- dsapp_health_summary(cfg, engine = eng)
      # 把引擎状态原样带出去给界面用（界面里要显示"跑了多久"），省得
      # 再问一次数据库 —— 两次查询之间任务可能刚好结束，两个数字对不上。
      res$engine <- eng
      res
    })

    observeEvent(input$health_refresh, {
      dsapp_health_reset_cache()      # 先清缓存，再触发重算
      health_ver(health_ver() + 1)
    })

    output$health_badge <- renderUI({
      # ★ V13.8 item 1：那张卡只给平台管理员（见 mod_admin_ui）。这里挡一道
      # 是因为 renderUI 的函数体服务端照跑不误 —— health() 每次要读 /proc、
      # 跑 df，还有 60 秒的定时器在推着它重算，项目管理员身上纯属白烧。
      if (!is_platform()) return(NULL)
      h <- tryCatch(health(), error = function(e) NULL)
      if (is.null(h)) return(NULL)
      tagList(HTML("&nbsp;"), dsapp_health_badge(h$level))
    })

    output$health <- renderUI({
      if (!is_platform()) return(NULL)
      # ⚠️ 整块包 tryCatch：健康监控是**在最糟的时候**才被打开的东西
      #    （盘满了、内存爆了）。它自己出异常绝不能把整页管理后台带走。
      h <- tryCatch(health(), error = function(e) NULL)
      if (is.null(h)) {
        # ★ V13.7 item 2：原来是「健康信息读取失败 —— 刷新页面重试；
        #   持续失败请看服务端日志。」—— 两句都是把平台的活推给用户，
        #   后一句尤其：让人"去看服务端日志"是让他去做一件他做不到的事
        #   （他连那台机器都上不去）。
        #
        #   平台自己先做一遍：采集有一层 TTL 缓存（R/health.R 的
        #   dsapp_health_probe），失败多半就败在那份缓存上（探到一半文件没了、
        #   du 撞上正在被清理的目录）。清掉缓存再采一次，能自己好就自己好了。
        #
        #   ⚠️ 重试是**再调一次 health()**，不是在这里重算一遍采集：eng 那段
        #      只有那个 reactive 里有。reactive 抛异常时**不会**把异常缓存
        #      下来（缓存的是值），所以第二次读会真的重跑。
        #   ⚠️ 不推 health_ver() 来强制重算 —— health_ver 就是这个 render 的
        #      依赖，自己写自己失效会转圈（这个仓库里踩过，症状是静默停掉
        #      而不是报错）。
        h <- tryCatch({
          dsapp_health_reset_cache()
          health()
        }, error = function(e) NULL)
      }
      if (is.null(h)) {
        # 自动重试也过了还是不行：如实说，并且**明说这一块空着不影响别的**——
        # 这个页面是用户在最糟的时候才打开的，一句"失败了"会让他以为整台机器
        # 都出事了。旁边那颗重采按钮是本来就有的，提一句不算是把平台的活推给
        # 他：平台已经自己试过一轮了。
        # ⚠️ 按钮上只有图标（"立即重新采集"是 title，要悬停才看得见），所以
        #    这里按**位置 + 样子**指路，不能只说它的名字 —— 说一个看不见的
        #    名字等于没说。
        return(p(class = "text-muted small mb-0",
                 paste0("健康信息这次没采上来。平台已经清掉缓存自动重试过一次，",
                        "还是不行 —— 点卡片右上角那个转圈图标可以再采一次。",
                        "这一块暂时空着，不影响下面的数据和别的功能。")))
      }

      # 一行"标签 : 值"
      kv <- function(label, value) {
        div(class = "d-flex justify-content-between border-bottom py-1",
          span(class = "text-muted small", label),
          span(class = "small font-monospace", value))
      }
      dash <- function(x) if (is.null(x) || length(x) != 1 || is.na(x)) "—" else x

      # ---- 左栏：CPU / 内存 / 交换 ----
      cpu <- h$cpu
      cpu_txt <- if (is.na(cpu$percent)) {
        if (!isTRUE(cpu$primed)) "首次采样中…" else "不可用"
      } else sprintf("%.1f%%", cpu$percent)
      cpu_sub <- if (!is.na(cpu$cores)) {
        s <- sprintf("%d 核", cpu$cores)
        if (isTRUE(cpu$load$ok)) s <- paste0(s, sprintf(" · 负载 %.2f / %.2f / %.2f",
                                                        cpu$load$m1, cpu$load$m5, cpu$load$m15))
        s
      } else NULL

      mem <- h$mem
      mem_txt <- if (!isTRUE(mem$ok)) "不可用"
                 else sprintf("%s / %s（%.0f%%）", dsapp_fmt_bytes(mem$used),
                              dsapp_fmt_bytes(mem$total), mem$percent)
      mem_sub <- if (isTRUE(mem$ok)) {
        sprintf("可用 %s%s", dsapp_fmt_bytes(mem$available),
                if (identical(mem$source, "MemFree")) "（老内核，按 MemFree 估）" else "")
      } else NULL

      sw <- h$swap
      swap_txt <- if (!isTRUE(sw$ok)) "不可用"
                  else if (isTRUE(sw$none)) "未启用（正常）"
                  else sprintf("%s / %s（%.0f%%）", dsapp_fmt_bytes(sw$used),
                               dsapp_fmt_bytes(sw$total), sw$percent)

      # ---- 磁盘：数据盘和程序目录分开列 ----
      # 读不到挂载点时标签退回**路径** —— 磁盘采集失败正是最需要知道
      # "该去看哪儿"的时候，写个「（?）」帮不上忙。
      disk_label <- function(d, what) {
        sprintf("%s（%s）", what, d$mount %||% d$path %||% "?")
      }
      disk_row <- function(d, label) {
        if (is.null(d) || !isTRUE(d$ok)) {
          return(div(class = "d-flex justify-content-between border-bottom py-1",
            span(class = "text-muted small", label),
            span(class = "small text-warning", d$reason %||% "读不到")))
        }
        div(class = "mb-2",
          div(class = "d-flex justify-content-between align-items-baseline",
            span(class = "small", label),
            span(class = "small font-monospace",
                 sprintf("%s / %s（%.0f%%）", dsapp_fmt_bytes(d$used),
                         dsapp_fmt_bytes(d$total), d$percent))),
          div(class = "progress", style = "height:6px;",
            div(class = paste0("progress-bar",
                               if (!is.na(d$free_percent) &&
                                   d$free_percent < DSAPP_HEALTH_DISK_CRITICAL_FREE_PCT) " bg-danger"
                               else if (d$percent >= DSAPP_HEALTH_DISK_WARN_PCT) " bg-warning"),
                role = "progressbar",
                style = sprintf("width:%.1f%%", max(0, min(100, d$percent))))),
          div(class = "text-muted", style = "font-size:.7rem;",
              sprintf("挂载点 %s · 剩 %s", d$mount, dsapp_fmt_bytes(d$available))))
      }

      # ---- 引擎槽位 ----
      # R 版的执行引擎是**全站单槽**的：它忙的时候别人提交不了任务。这件事
      # 必须让管理员看得见 —— 用户那边只会看到一句"已有任务在执行"。
      e <- h$engine
      slot <- if (is.null(e)) {
        span(class = "text-muted small", "（本页未接入引擎）")
      } else if (!isTRUE(e$busy)) {
        span(class = "badge text-bg-secondary", "空闲")
      } else {
        tagList(
          span(class = "badge text-bg-primary", "执行中"),
          span(class = "small ms-2",
               sprintf("任务 #%d", as.integer(e$task_id %||% NA_integer_)),
               # ⚠️ elapsed 是 NA 时**只写"任务 #N"**，不补一个"已跑 0 秒"
               #    —— 那个 0 是编出来的，管理员会以为是刚提交的。
               if (!is.na(e$elapsed %||% NA_real_))
                 paste0(" · 已跑 ", dsapp_fmt_duration(e$elapsed)) else "")
        )
      }

      self <- h$self
      tagList(
        layout_columns(
          col_widths = c(6, 6),
          div(
            # CPU 没有"阈值"这回事 —— 满载不等于出问题（任务本来就该把
            # CPU 吃满），所以它的进度条永远不染红，阈值给个够不着的数。
            dsapp_health_bar("CPU 使用率", cpu$percent, cpu_txt, cpu_sub,
                             warn_pct = 101),
            dsapp_health_bar("内存使用率", if (isTRUE(mem$ok)) mem$percent else NA_real_,
                             mem_txt, mem_sub, warn_pct = h$thresholds$mem_warn),
            dsapp_health_bar("交换分区",
                             if (isTRUE(sw$ok) && !isTRUE(sw$none)) sw$percent else NA_real_,
                             swap_txt, warn_pct = h$thresholds$swap_warn)
          ),
          div(
            disk_row(h$disk$data, disk_label(h$disk$data, "数据盘")),
            if (!isTRUE(h$disk$same_fs))
              disk_row(h$disk$install, disk_label(h$disk$install, "程序目录所在盘"))
            else
              p(class = "small text-muted mb-2",
                icon("circle-info"), " 数据盘和程序目录在同一块盘上，只列一次。")
          )
        ),

        # ---- 告警 ----
        # 正常时**也要说一句"正常"**：只在不正常时才有东西，管理员就没法
        # 区分"一切正常"和"这一块没渲染出来"。
        if (length(h$issues) == 0) {
          div(class = "alert alert-success py-2 mb-3 small mb-0",
              icon("circle-check"), " 各项指标正常。",
              sprintf("阈值：磁盘剩余 <%.0f%% 或使用率 ≥%d%%、内存 ≥%d%%、交换分区 ≥%d%%。",
                      h$thresholds$disk_critical_free, h$thresholds$disk_warn,
                      h$thresholds$mem_warn, h$thresholds$swap_warn))
        } else {
          div(class = paste0("alert py-2 mb-3 small mb-0 ",
                             if (identical(h$level, "critical")) "alert-danger" else "alert-warning"),
            tags$b(if (identical(h$level, "critical")) "需要立即处理：" else "注意："),
            tags$ul(class = "mb-0 mt-1",
              lapply(h$issues, function(x) tags$li(x))))
        },

        # ---- 进程与运行时长 ----
        layout_columns(
          col_widths = c(6, 6),
          div(
            kv("本进程内存占用", dsapp_fmt_bytes(self$rss)),
            kv("本进程线程数", dash(self$threads)),
            kv("本进程打开的文件", dash(self$fds))
          ),
          div(
            kv("系统已运行", dsapp_fmt_duration(h$uptime)),
            kv("执行槽位", slot),
            # ⚠️ 精确到**秒**（V9 item 6）。上面那几项 60 秒才采一次，只写到
            #    分钟的话，「18:03」既可能是刚采的、也可能是 59 秒前采的 ——
            #    而管理员盯着这一格判断"我刚清完磁盘，数字怎么还没降"。
            kv("数据采集于", format(h$at, "%H:%M:%S", tz = Sys.timezone()))
          )
        ),

        p(class = "small text-muted mb-0 mt-2",
          icon("circle-info"), " 只读整机计数器（/proc、df），",
          "不读取任何人的任务内容、文件名或工作目录。",
          "执行槽位是整个应用共用一个 —— 它被占满时所有人都提交不了新任务。"),
        # 刷新节奏要说出来（V9 item 6）。用户这次的要求就是"太频繁了"——
        # 改完不写，下一个人（或者三个月后的自己）看到数字不动，第一反应
        # 还是"是不是坏了"，然后又会去调小它。
        p(class = "small text-muted mb-0",
          icon("stopwatch"), " CPU / 内存 / 磁盘每 60 秒采一次；",
          "需要立刻看最新值点右上角的刷新。",
          "执行槽位是实时的 —— 有任务起止会立刻反映在这里。")
      )
    })

    # 「磁盘占用」卡片右上角那个刷新按钮。原来没有 handler —— 按钮在、点了
    # 没反应（走查时顺手发现的）。
    observeEvent(input$refresh, { refresh(isolate(refresh()) + 1) })

    stats <- reactive({
      refresh()
      dsapp_platform_stats(cfg, con = dsapp_db(cfg))
    })

    output$stats <- renderUI({
      # ★ V13.8 item 1：那张卡对项目管理员根本没渲染（见 mod_admin_ui），
      # 但 renderUI 的**函数体服务端照样会跑** —— 不在这里挡住的话，
      # 每 60 秒白跑一趟 dsapp_platform_stats()（好几趟 du -sb，扫的是
      # 整个数据目录），算出来的东西没有任何人看。
      if (!is_platform()) return(NULL)
      s <- stats()
      pct <- function(a, b) if (is.na(a) || is.na(b) || b == 0) "—"
                            else sprintf("%.0f%%", 100 * a / b)
      row <- function(label, value, note = NULL) {
        div(class = "d-flex justify-content-between border-bottom py-1",
          span(class = "text-muted small", label),
          span(tags$b(value), if (!is.null(note))
            span(class = "text-muted small ms-2", note))
        )
      }
      tagList(
        row("账号", sprintf("%s 个", s$n_users %||% "—"),
            sprintf("其中启用 %s 个", s$n_active %||% "—")),
        row("对话", s$n_chat %||% "—"),
        row("消息", s$n_msg %||% "—"),
        row("任务", s$n_task %||% "—",
            sprintf("成功 %s / 失败 %s（成功率 %s）",
                    s$n_task_ok %||% "—", s$n_task_err %||% "—",
                    pct(s$n_task_ok, (s$n_task_ok %||% 0) + (s$n_task_err %||% 0)))),
        row("共享区文件", s$n_files %||% "—")
      )
    })

    output$disk <- renderUI({
      # ★ V13.8 item 1：同 output$stats，那张卡只给平台管理员。
      if (!is_platform()) return(NULL)
      s <- stats()
      row <- function(label, bytes, path) {
        div(class = "d-flex justify-content-between align-items-baseline border-bottom py-1",
          div(span(class = "text-muted small", label),
              div(class = "text-muted", style = "font-size:.7rem;",
                  tags$code(path))),
          tags$b(dsapp_fmt_bytes(bytes))
        )
      }
      tagList(
        row("数据目录合计", s$bytes_data, cfg$data_root),
        row("对话工作区", s$bytes_ws, cfg$ws_root),
        # ⚠️ 显示的是 files_root（父目录），不是 cfg$files_dir —— 后者是
        # 启动时那个 _anon 占位（见 config.R 的说明）。管理员看到的应该是
        # "这些加起来放在哪儿"，那就是父目录。
        row("文件管理区（各账号合计）", s$bytes_files,
            cfg$files_root %||% cfg$files_dir),
        row("conda 环境", s$bytes_envs, cfg$envs_root),
        p(class = "small text-muted mb-0 mt-2",
          icon("circle-info"), dsapp_md_inline(" 工作区是**每个对话**一块（含各自的 R 包目录和"),
          "Python 虚拟环境）。删掉对话时会一并删掉，长期不用的话",
          dsapp_md_inline("在「言出法随」页删掉即可释放。上面的用户表里能看出**是谁**占的 ——"),
          "磁盘告急时按那一列找人就够了。")
      )
    })

    # ---- token 用量 ----
    #
    # 数据来自 usage_log（每次生成写一行，见 db.R 的 db_usage_add）。
    # 这一块回答的是"额度被谁、在什么时候用掉了" —— 全站共用一个 API Key，
    # 没有这个数字时，账单来了只能靠猜。
    usage <- reactive({
      refresh()
      con <- dsapp_db(cfg)
      by_user <- db_usage_by_user(con = con)
      by_day  <- db_usage_by_day(14, con = con)
      list(by_user = by_user, by_day = by_day)
    })

    output$usage <- renderUI({
      # ⚠️ stats() **不要在这里无条件调**。它每算一次要跑好几趟 `du -sb`
      #    （遍历整个数据目录，可能是几个 T），而项目管理员根本看不到
      #    「平台用量」那张卡 —— 为一行他用不上的合计去扫盘是纯浪费。
      #    下面只有平台管理员那一支会用到它。
      u <- usage()
      bu <- u$by_user
      bd <- u$by_day

      num <- function(x) if (is.null(x) || is.na(x)) "—"
                        else format(round(as.numeric(x)), big.mark = ",")

      # ★ V13.8 item 1：范围过滤。**在取 uname 之前**做 —— 下面 uname()
      # 要给每一行查一次账号，先筛掉的不只是显示，还有那些查询。
      #
      # ⚠️ 顺带把上面那行「累计」也改成从**筛过的行**求和，不再用
      #    stats()$tokens_total。那一格是全平台的合计，而项目管理员看到
      #    的"累计"必须是自己范围内那一份 —— 否则这一个数字就把他看不见的
      #    那些账号的用量报出来了，而这一卡的其他行又都对不上。
      sc <- my_user_ids()
      scoped <- !is.null(sc)
      if (scoped) {
        if (is.null(bu) || nrow(bu) == 0) {
          bu <- NULL
        } else {
          bu <- bu[as.integer(bu$user_id) %in% as.integer(sc), , drop = FALSE]
        }
        if (!is.null(bd) && nrow(bd) > 0) {
          # 按天那份没有账号维度，只能整块不给 —— 见下面那段说明。
          bd <- bd[0, , drop = FALSE]
        }
      }

      if (is.null(bu) || nrow(bu) == 0) {
        return(p(class = "text-muted small mb-0",
                 if (scoped) "你管理范围内的账号还没有记录到用量。"
                 else "还没有记录到用量。",
                 "厂商不返回 token 数时这里会一直是空的",
                 "（宁可不显示，也不显示一个假的 0）。"))
      }

      uname <- function(uid) {
        if (is.na(uid)) return("（无归属）")
        r <- tryCatch(dsapp_user_by_id(uid, con = dsapp_db(cfg)),
                      error = function(e) NULL)
        if (is.null(r)) sprintf("已删除的账号 #%s", uid)
        else sprintf("%s <%s>", r$nickname, r$email)
      }

      # 按账号排序后取前若干。**排序在 R 里做**，不写进 SQL 的 ORDER BY：
      # by_user 这份结果还要按 user_id 去 join 用户表，顺序在页面上
      # 是显示需求，不该混进取数逻辑（两处各排一次迟早不一致）。
      ord <- order(-as.numeric(bu$total))
      bu  <- bu[ord, , drop = FALSE]

      row <- function(left, right, note = NULL) {
        div(class = "d-flex justify-content-between align-items-baseline border-bottom py-1 small",
          span(class = "text-truncate", style = "max-width:60%;", left),
          span(tags$b(right),
               if (!is.null(note)) span(class = "text-muted ms-2", note))
        )
      }

      # 「累计」那一行。平台管理员继续用 stats()（全平台合计，含那些
      # user_id 为空的历史行）；项目管理员用它自己那份的和 —— 见上面
      # 那段关于范围过滤的说明。
      if (scoped) {
        tot_tokens <- sum(as.numeric(bu$total), na.rm = TRUE)
        tot_calls  <- sum(as.numeric(bu$n_calls), na.rm = TRUE)
      } else {
        s <- stats()
        tot_tokens <- s$tokens_total
        tot_calls  <- s$n_llm
      }

      tagList(
        row(if (scoped) "范围内累计" else "累计",
            sprintf("%s tokens", num(tot_tokens)),
            sprintf("%s 轮生成", num(tot_calls))),
        div(class = "mt-3 mb-1 text-muted small fw-bold", "按账号"),
        lapply(seq_len(nrow(bu)), function(i) {
          row(uname(bu$user_id[[i]]),
              num(bu$total[[i]]),
              sprintf("%s 轮 · 输入 %s / 输出 %s",
                      num(bu$n_calls[[i]]), num(bu$prompt[[i]]),
                      num(bu$completion[[i]])))
        }),
        if (nrow(bd) > 0) {
          tagList(
            div(class = "mt-3 mb-1 text-muted small fw-bold",
                "按天（最近 14 天，UTC）"),
            lapply(seq_len(nrow(bd)), function(i) {
              row(bd$day[[i]], num(bd$total[[i]]),
                  sprintf("%s 轮 · %s 人", num(bd$n_calls[[i]]),
                          num(bd$n_users[[i]])))
            })
          )
        },
        p(class = "small text-muted mb-0 mt-3",
          icon("circle-info"),
          " 只记数字，不记对话内容。厂商没返回用量时那一轮不计数 ——",
          "所以这里的合计可能略小于真实账单，不会大。")
      )
    })

    # ---- 团队（V13 item 3）-------------------------------------------------
    #
    # 全是"点一下、写一次库、刷新"的简单动作，所以放在一个 observeEvent 里
    # 按 input 名字分派，而不是十来个小 observer：这些动作互斥、都要
    # refresh()、都要 note()，分开写只会把同一段样板抄十来遍。
    team_edit <- reactiveVal(NULL)

    teams <- reactive({
      refresh()
      t <- dsapp_teams_list(con = dsapp_db(cfg))
      # V13.8 item 1：项目管理员只看到**自己建的**组 —— 他的范围就是
      # "组内的账号成员"，而"组"指的是他建的那些。别人的组在这里出现的话，
      # 他点「改」就能把别人组里的人挪走。
      if (!is_platform() && !is.null(t) && nrow(t) > 0) {
        u <- me()
        if (is.null(u)) return(t[0, , drop = FALSE])
        t <- t[as.integer(t$created_by) %in% as.integer(u$id), , drop = FALSE]
      }
      t
    })

    # 团队面板的候选人名单。
    #
    # ⚠️ 和用户表用的 users_all() **不是一回事**，别合并：users_all() 是
    #    "我能**管理**谁"（管的是停用、改密、配额、删号），而这里是
    #    "我能把**谁**放进我的组"。项目管理员如果只能从自己现有范围里挑人，
    #    他就永远建不起第二个组 —— 候选名单等于当前成员，看起来就是个坏掉的
    #    下拉框。
    #
    #    所以候选放宽到**所有非管理员账号**。这不算泄露：共享对话框里
    #    本来就能看到全站账号的昵称和邮箱（见 R/share.R 的
    #    dsapp_share_resolve_emails），这里给的还更少。真正收住的是
    #    "能不能**动**他"—— 那一条自始至终看 users_all()。
    #
    #    管理员（两种）不进候选：把另一个管理员拉进自己的组，等于给他开了
    #    一扇管自己组员的门（范围是按"我建的组里的成员"算的）。
    users_team_pool <- reactive({
      if (is_platform()) return(users_all())
      refresh()
      df <- tryCatch(dsapp_users_list(con = dsapp_db(cfg)), error = function(e) NULL)
      if (is.null(df) || nrow(df) == 0) return(df)
      df[as.integer(df$is_admin %||% 0L) == 0L, , drop = FALSE]
    })

    output$teams_ui <- renderUI({
      dsapp_teams_panel(ns, users_team_pool(), teams(), team_edit())
    })

    # 表格里每行的「改」「删」按钮：都塞进**同一个** input（见
    # dsapp_team_row_btn 的说明），这里只要读出它带回来的 id。
    # `n` 是每点一次的随机数，保证"连点两次同一个按钮"也能触发。
    row_team_id <- function(v) {
      if (is.null(v)) return(NA_integer_)
      # 值可能是 list（正常）、也可能是 JSON 串（旧版 shiny 的兜底）——
      # 两种都认，认不出来就当没点。宁可这一下没反应，也不要删错组。
      if (is.list(v)) return(suppressWarnings(as.integer(v$id %||% NA_integer_)))
      suppressWarnings(as.integer(v[["id"]] %||% NA_integer_))
    }

    observeEvent(input$team_edit_id, {
      tid <- row_team_id(input$team_edit_id)
      if (!is.na(tid)) team_edit(tid)
    }, ignoreInit = TRUE)

    observeEvent(input$team_del_id, {
      tid <- row_team_id(input$team_del_id)
      if (is.na(tid)) return()
      if (!can_team(tid)) return(deny("这个团队"))
      t <- teams()
      nm <- if (!is.null(t) && nrow(t)) {
        h <- which(t$id == tid); if (length(h)) t$name[[h[1]]] else as.character(tid)
      } else as.character(tid)
      r <- dsapp_team_delete(tid, con = dsapp_db(cfg))
      audit("team_delete", target = nm, detail = r$msg %||% "")
      if (!isTRUE(r$ok)) return(note(r$msg, "warning"))
      if (identical(team_edit(), tid)) team_edit(NULL)
      note(sprintf("已删除团队「%s」。共享名单不受影响 —— 团队只管挑人，不管权限。", nm),
           "success")
      refresh(refresh() + 1)
    }, ignoreInit = TRUE)

    observeEvent(input$team_cancel, team_edit(NULL), ignoreInit = TRUE)

    observeEvent(input$team_save, {
      tid <- team_edit()
      # 改组要先判这个组是不是他的（新建的话 tid 是 NULL，跳过）。
      if (!is.null(tid) && !can_team(tid)) return(deny("这个团队"))
      r <- dsapp_team_save(tid, input$team_name, input$team_note,
                           by = state$user_id, con = dsapp_db(cfg))
      if (!isTRUE(r$ok)) return(note(r$msg, "warning"))
      n <- dsapp_team_set_members(r$id, input$team_members,
                                  con = dsapp_db(cfg))
      if (is.null(n)) return(note("组建好了，但成员没存上，再点一次保存。",
                                  "warning"))
      audit(if (is.null(tid)) "team_create" else "team_update",
            target = trimws(input$team_name %||% ""),
            detail = sprintf("%d 名成员", n))
      team_edit(NULL)
      note(sprintf("%s，组内 %d 人。", r$msg, n), "success")
      refresh(refresh() + 1)
    }, ignoreInit = TRUE)

    # ⚠️ 两个 reactive，别合并成一个：users() 是**筛过的**，只给用户表用。
    #    「文件管理区的归属」那张卡里的账号下拉（claim_user）用的是
    #    users_all() —— 那个下拉和用户表的筛选没有半点关系，跟着一起缩的话，
    #    管理员在用户表里搜了个人，另一个卡片的账号列表就莫名其妙只剩一个了。
    users_all <- reactive({
      refresh()
      df <- dsapp_users_list(con = dsapp_db(cfg))

      # 配额和密码状态一起取。包 tryCatch 是沿用这里的既有做法：这两列
      # 都是 V5 追加的（ALTER TABLE 加的），万一某个老库没加上，宁可这两列
      # 显示成「—」，也不要让整个用户表报错打不开 —— 那是管理页的主视图。
      #
      # ⚠️ 这一步放在 users() 里而不是 renderDataTable 里：下面「密码状态」
      #    那个筛选要用 has_pw / must_pw 判断，而筛选必须做在给 DT 之前
      #    （理由见 tasks() 里那段注释 —— 行号回查的是 users()）。
      qtok <- tryCatch(
        DBI::dbGetQuery(dsapp_db(cfg),
          "SELECT id, quota_gb, must_change_pw, cpu_sec, mem_mb, max_procs,
                  CASE WHEN pass_hash IS NULL OR pass_hash = '' THEN 0 ELSE 1 END AS has_pw
             FROM users"),
        error = function(e) NULL)
      # 取一列的样板。老库上这几列可能还没加上（ALTER TABLE 加的），
      # NULL 时整列填 NA —— 表格显示「—」，而不是整个管理页打不开。
      pull <- function(col, mode = "numeric") {
        if (is.null(qtok) || !col %in% names(qtok)) {
          return(if (mode == "numeric") rep(NA_real_, nrow(df)) else rep(NA, nrow(df)))
        }
        qtok[[col]][match(as.integer(df$id), as.integer(qtok$id))]
      }
      df$quota_gb  <- pull("quota_gb")
      df$has_pw    <- pull("has_pw", "int")
      df$must_pw   <- pull("must_change_pw", "int")
      df$cpu_sec   <- pull("cpu_sec")
      df$mem_mb    <- pull("mem_mb")
      df$max_procs <- pull("max_procs")

      # ★ V13.8 item 1：**范围过滤就做在这一处**。
      #
      # 用户表、任务卡那个账号下拉、日志卡那个账号下拉、以及团队面板的候选
      # 名单全都是从 users_all() 来的 —— 收在这里，四条路一起收住，不会
      # 出现"用户表里看不到他，但任务卡的下拉里选得到他"这种半拉子状态。
      #
      # ⚠️ 放在最后（配额那几列之后）而不是查询里：dsapp_users_list 是给
      #    别处也用的公共查询，不该长出一个"按管理员身份筛"的参数 ——
      #    那是管理页的事，不是"列账号"这件事的属性。
      sc <- my_user_ids()
      if (!is.null(sc) && nrow(df) > 0) {
        df <- df[as.integer(df$id) %in% as.integer(sc), , drop = FALSE]
      }
      df
    })

    users <- reactive({
      # ⚠️ 筛选做在**这里**（拿到 df 之后、交给 DT 之前）。selected() 按行号
      #    回查 users()，在 renderDataTable 里另筛一份的话，行号对应的就是
      #    另一批账号 —— 点第 1 行停用的是别人。文件页/任务页踩过同样的坑。
      dsapp_filter_users(users_all(), input$u_kw, input$u_role,
                         input$u_status, input$u_pw)
    })

    output$u_count <- renderUI({
      n <- nrow(users())
      total <- nrow(users_all())
      div(class = "small text-muted mb-1",
        if (n == total) sprintf("共 %d 个账号", total)
        else sprintf("筛出 %d 个（共 %d 个）", n, total))
    })

    observeEvent(input$u_clear, {
      updateTextInput(session, "u_kw", value = "")
      updateSelectInput(session, "u_role", selected = "")
      updateSelectInput(session, "u_status", selected = "")
      updateSelectInput(session, "u_pw", selected = "")
    })

    # 每个账号占了多少磁盘。**独立于 users()** 分开算：量磁盘要跑 du，
    # 遍历几万个文件是秒级的活；把它挂在用户表上一次渲染里，会让"停用/
    # 启用"这种操作也跟着卡好几秒。分开放，表格先出来，磁盘列后补。
    disk <- reactive({
      refresh()
      dsapp_user_disk_usage(cfg, con = dsapp_db(cfg))
    })

    output$tbl <- DT::renderDataTable({
      df <- users()
      if (nrow(df) == 0) {
        return(DT::datatable(data.frame(提示 = "还没有账号"),
                             options = list(dom = "t"), rownames = FALSE))
      }
      dk <- tryCatch(disk(), error = function(e) NULL)
      dbytes <- if (is.null(dk) || nrow(dk) == 0) rep(NA_real_, nrow(df))
                else dk$bytes[match(as.integer(df$id), dk$user_id)]
      # 配额/密码状态三列已经由 users() 取好（筛选也要用它们，见那里的注释）。
      qgb <- df$quota_gb; has_pw <- df$has_pw; must_pw <- df$must_pw

      # 资源上限一列。三样挤在一格里，用 "·" 分隔 —— 拆成三列的话，
      # 这张表就有 16 列了，而其中两列常年是"默认"。
      # 全都跟着平台走时写「平台默认」，不写具体数字：写死数字之后，
      # 改了平台默认值（.Renviron）这张表还是老数字，看起来像"没生效"。
      # ★ V15.6 item 14：负数是「不限制」的哨兵（见 users.R 的
      #   DSAPP_LIMIT_UNLIMITED）。⚠️ 不认它的话，这一格会显示
      #   「-1s · -1 KB · -1 进程」—— 管理员看到的是一串负数，
      #   而它实际的含义恰恰相反（一点限制都没有）。
      lim <- vapply(seq_len(nrow(df)), function(i) {
        parts <- character(0)
        if (!is.na(df$cpu_sec[i]))
          parts <- c(parts, if (df$cpu_sec[i] < 0) "CPU 不限"
                            else sprintf("%gs", df$cpu_sec[i]))
        if (!is.na(df$mem_mb[i]))
          parts <- c(parts, if (df$mem_mb[i] < 0) "内存不限"
                            else dsapp_fmt_bytes(df$mem_mb[i] * 1024 * 1024))
        if (!is.na(df$max_procs[i]))
          parts <- c(parts, if (df$max_procs[i] < 0) "进程不限"
                            else sprintf("%d 进程", df$max_procs[i]))
        if (length(parts) == 0) "平台默认" else paste(parts, collapse = " · ")
      }, character(1))

      show <- data.frame(
        id       = df$id,
        nickname = df$nickname,
        email    = df$email,
        field    = substr(df$field %||% "", 1, 24),
        phone    = df$phone,
        # ★ V13.8 item 1：原来这里写的是 `ifelse(is_admin == 1L, "管理员", "用户")`
        #   —— 只有一档。分出项目/平台两级之后，这一列再不写清楚级别，管理页
        #   上就**看不出谁是平台管理员**：平台管理员想找人接手，得先去后台页
        #   挨个点；项目管理员也看不出自己这一片里是不是混进了另一个管理员。
        #   ⚠️ 走 dsapp_admin_scope_label() 而不是自己再写一遍 ifelse：
        #      三个中文词只在一个地方定义（R/users.R），后台页那一列用的也是它。
        role     = vapply(seq_len(nrow(df)), function(i)
                     dsapp_admin_scope_label(
                       dsapp_user_admin_scope(as.list(df[i, , drop = FALSE]))),
                     character(1)),
        status   = ifelse(df$status == "active", "启用", "停用"),
        chat     = df$n_chat,
        task     = df$n_task,
        disk     = vapply(dbytes, dsapp_fmt_bytes, character(1)),
        # 配额列要显示"占了多少 / 上限多少"，只写一个 "200 GB" 看不出紧不紧。
        # 没有配额写「不限」—— 不写的话空格看起来像"没设置好"。
        quota    = ifelse(is.na(qgb) | qgb <= 0, "不限",
                          sprintf("%s / %s",
                                  vapply(dbytes, dsapp_fmt_bytes, character(1)),
                                  vapply(qgb, function(g)
                                    dsapp_fmt_bytes(g * DSAPP_GB), character(1)))),
        limits   = lim,
        # 密码一列同时回答两件事："他有没有锁"和"他是不是还欠我一次改密"。
        # 分开两列在表格里太占地方，而这两件事永远不会同时重要。
        pw       = ifelse(is.na(must_pw), "—",
                   ifelse(as.integer(must_pw) == 1L, "待改密",
                   ifelse(as.integer(has_pw) == 1L, "已设", "无密码"))),
        # ⚠️ `USE.NAMES = FALSE` 不能省。vapply() 默认在 X 是 character 时
        #    把 **X 的值**当成结果的名字（给 sapply 准备的行为），而
        #    `users.last_seen_at` 是**可空列**（R/users.R:55 那个建表语句里
        #    没有 NOT NULL，直插库的账号就是 NULL）。筛到**只剩一行**、又恰好
        #    是 NULL 那一行时，names(seen) 会是 NA_character_ →
        #    data.frame() 报 `row names contain missing values` → 整张表消失
        #    （htmlwidgets 的错误处理是 visibility:hidden，旧 DOM 留着，
        #    错误只进 app_error.log）。
        #    同一处写法在 R/mod_htadmin.R 的 output$tbl 上已经实测炸过。
        seen     = vapply(df$last_seen_at, dsapp_fmt_time, character(1),
                          USE.NAMES = FALSE),
        stringsAsFactors = FALSE
      )
      DT::datatable(
        show,
        colnames = c("ID", "昵称", "邮箱", "研究方向", "手机号", "角色",
                     "状态", "对话", "任务", "磁盘", "配额", "资源上限",
                     "密码", "最后活跃"),
        selection = "single", rownames = FALSE,
        # V13.10 item 3：`autoWidth = FALSE` 配合上面那层 .dsapp-dt-nowrap。
        # DT 自带 `table.dataTable{width:100%}` 把表格钉死在容器宽度上，
        # 列被压窄、文字糊到隔壁格子 —— 永远不会溢出，横向滚动条也就永远
        # 不出现。不用 `scrollX = TRUE`（理由见 R/mod_tasks.R:96-100）。
        options = list(dom = "tp", pageLength = 10, ordering = FALSE,
                       autoWidth = FALSE,
                       columnDefs = list(list(className = "dt-left",
                                              targets = "_all")))
      )
    })

    selected <- reactive({
      i <- input$tbl_rows_selected
      df <- users()
      if (is.null(i) || length(i) == 0 || i > nrow(df)) return(NULL)
      as.integer(df$id[i])
    })

    note <- function(text, type = "message") {
      msg(div(class = paste0("alert alert-", type, " py-2 px-3 mt-3 mb-0 small"),
              text))
    }

    # 记一条管理动作（见 R/audit.R 顶部那条规则：操作者另有其人的动作记在
    # 调用方）。user = 当前管理员，target = 被操作的那个账号的邮箱。
    #
    # ⚠️ target 用**邮箱**而不是昵称：昵称可以重复、可以改，邮箱是账号的
    #    稳定标识。日志被翻出来看的时候（可能几个月后），"张三"这三个字
    #    未必还指得清是谁。
    audit <- function(action, target = "", detail = "", ok = TRUE) {
      dsapp_audit(action, user = state$user, user_id = state$user_id,
                  target = target, detail = detail, ok = ok,
                  session = session, cfg = cfg)
    }

    output$action_msg <- renderUI(msg())

    # ---- 操作日志 ----
    #
    # 这个区块**不自动刷新**：日志是拿来翻的，翻到一半被新行顶掉比不刷新
    # 更烦人（而且筛选项会跟着跳）。要新的就点刷新 —— 那个按钮同时把
    # 账号/动作两个下拉的选项也重算一遍（新用户、新动作类型会不断出现）。
    au_refresh <- reactiveVal(0)

    # 两个筛选下拉的选项要**跟着日志长**：动作那一栏尤其明显 —— 应用刚起来
    # 时日志是空的，只有"（全部）"一个选项，之后发生的动作类型（上传、改密、
    # 停用……）都是后来才出现的。所以这里依赖 au_refresh()：点刷新按钮就重算。
    # 这点很关键 —— 不重算的话下拉永远是空的，看起来像筛选坏了。
    #
    # ⚠️ 读当前选中值一律用 isolate()。不用的话这个 observer 就依赖了它自己
    #    写的东西（updateSelectInput → input 变 → observer 重跑），是一个
    #    自己喂自己的环。加上"选项没变就不发更新"这道闸，两重保险。
    # ⚠️ 这两个下拉用 renderUI **渲染**出来，而不是用 updateSelectInput 去改。
    #
    #    踩过的坑：模块的 server 在会话建立时就跑，那一刻浏览器还没拿到页面，
    #    此时发出的 updateSelectInput 消息到了客户端**找不到对应元素，被丢掉**
    #    （Shiny 的 input 消息不排队）。表现是下拉永远是空的、而且不报任何错，
    #    看起来像筛选功能坏了。renderUI 没有这个问题 —— 选项是跟着 HTML
    #    一起到达的。
    #
    #    选项要"跟着日志长"：应用刚起来时日志是空的，只有"（全部）"，之后
    #    发生的动作类型（上传、改密、停用……）都是后来才出现的。所以两个
    #    render 都依赖 au_refresh()（刷新按钮）。
    #
    # ⚠️ 里面的 input$au_user / input$au_action 一律 isolate()。不隔离的话
    #    这个 render 就依赖了它自己渲染出来的输入（改选 → 重渲染 → 重建
    #    元素 → 选择被重置），是自己喂自己的环。
    output$au_user_sel <- renderUI({
      refresh(); au_refresh()
      con <- dsapp_db(cfg)
      us <- tryCatch(dsapp_users_list(con), error = function(e) NULL)
      ch <- c("（所有人）" = "")
      if (!is.null(us) && nrow(us) > 0) {
        ch <- c(ch, stats::setNames(
          as.character(us$id),
          sprintf("%s <%s>", us$nickname, us$email)))
      }
      # 已经**被删掉**的账号：日志里有、users 表里没有。它们的 user_id 还
      # 留在日志行上（那张表故意不加外键，见 R/audit.R 顶部），所以照旧能筛。
      # 这一条是"某人被删了，但他当初干了什么"的唯一入口 —— email 那一列
      # 冗余存着，就是为了这时候还能认出是谁。
      gone <- tryCatch(DBI::dbGetQuery(con, "
        SELECT a.user_id AS id, MAX(a.email) AS email
          FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
         WHERE a.user_id IS NOT NULL AND u.id IS NULL
         GROUP BY a.user_id ORDER BY a.user_id"), error = function(e) NULL)
      if (!is.null(gone) && nrow(gone) > 0) {
        ch <- c(ch, stats::setNames(
          as.character(gone$id),
          sprintf("%s（已删除）", gone$email)))
      }
      sel <- isolate(input$au_user) %||% ""
      # ⚠️ selectize = FALSE 是**必须的**，不是风格选择。
      #
      #    selectize 把「值为空的那个选项」当成占位符（placeholder），并从
      #    下拉菜单里**移除**。于是"（全部）"这一项在菜单里根本点不到 ——
      #    用户一旦按动作筛过一次，就再也回不到全部，只能刷新页面。
      #    原生 <select> 没有这个行为，空值选项就是一个正常可选项。
      #    顺带还解决了另一个问题：selectize 的原生 <select> 是空的，
      #    界面上看不见、自动化测试也读不到真实选项。
      selectInput(ns("au_user"), "账号", width = "100%", selectize = FALSE,
                  choices = ch, selected = if (sel %in% unname(ch)) sel else "")
    })

    output$au_action_sel <- renderUI({
      refresh(); au_refresh()
      acts <- tryCatch(dsapp_audit_actions(con = dsapp_db(cfg)),
                       error = function(e) character(0))
      a <- c("（全部）" = "")
      if (length(acts)) a <- c(a, stats::setNames(acts, dsapp_audit_label(acts)))
      sel <- isolate(input$au_action) %||% ""
      # selectize = FALSE 的理由同上一条（空值选项会被吃掉）。
      selectInput(ns("au_action"), "动作", width = "100%", selectize = FALSE,
                  choices = a, selected = if (sel %in% unname(a)) sel else "")
    })

    au_rows <- reactive({
      au_refresh(); refresh()
      days <- suppressWarnings(as.numeric(input$au_days %||% ""))
      dsapp_audit_list(
        user_id  = suppressWarnings(as.integer(input$au_user %||% NA)),
        action   = if (nzchar(input$au_action %||% "")) input$au_action else NULL,
        only_fail = isTRUE(input$au_fail_only),
        days     = if (is.na(days)) NULL else days,
        keyword  = input$au_kw %||% "",
        # ★ V13.8 item 1：范围过滤。`NULL` = 不限（平台管理员）。
        # 注意 dsapp_audit_stats() 那条**统计**说的是全库总数，这里没跟着
        # 缩 —— 见下面 output$au_stats 里那句说明。
        scope_ids = my_user_ids(),
        limit    = 500L, con = dsapp_db(cfg))
    })

    output$au_stats <- renderUI({
      st <- tryCatch(dsapp_audit_stats(con = dsapp_db(cfg)),
                     error = function(e) NULL)
      if (is.null(st)) return(NULL)
      # ⚠️ 这几个数是**全库**的，不跟着上面的范围缩。这是刻意的：
      #    "库里一共多少条、最早到什么时候"回答的是"这份日志保存得怎么样"，
      #    不是"谁做了什么"—— 不含任何账号信息。要让项目管理员看到
      #    "共 0 条日志"才是误导（他会以为日志功能坏了）。
      div(class = "small text-muted mb-2",
        sprintf("库里共 %d 条日志（其中 %d 条失败/被拒），最早 %s。",
                st$total, st$failed, dsapp_fmt_time(st$first_at)),
        if (!is.null(my_user_ids()))
          " 下面是**你管理范围内的账号**产生的记录，最多 500 条。"
        else " 下面最多显示最近 500 条。",
        " 超过 180 天的会在应用启动时清掉。")
    })

    output$au_tbl <- DT::renderDataTable({
      df <- au_rows()
      if (is.null(df) || nrow(df) == 0) {
        return(DT::datatable(data.frame(提示 = "这段时间里没有符合条件的记录"),
                             options = list(dom = "t", ordering = FALSE),
                             rownames = FALSE))
      }
      show <- data.frame(
        at     = vapply(df$at, dsapp_fmt_time, character(1)),
        who    = ifelse(nzchar(df$email), df$email,
                        ifelse(is.na(df$user_id), "—",
                               sprintf("#%s（已删除）", df$user_id))),
        action = dsapp_audit_label(df$action),
        target = substr(df$target, 1, 60),
        detail = substr(df$detail, 1, 60),
        result = ifelse(as.integer(df$ok) == 1L, "成功", "失败/被拒"),
        ip     = df$ip,
        stringsAsFactors = FALSE)
      DT::datatable(
        show,
        colnames = c("时间", "账号", "动作", "对象", "说明", "结果", "来源 IP"),
        rownames = FALSE,
        options = list(dom = "tp", pageLength = 15, ordering = FALSE,
                       columnDefs = list(list(className = "dt-left",
                                              targets = "_all"))))
    })

    observeEvent(input$au_refresh, { au_refresh(au_refresh() + 1) })

    observeEvent(input$toggle, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      # ★ V13.8 item 1：服务端鉴权。下同 —— 这一页每一个写库的 handler
      #   进来第一件事都是这一句（`grep -c "can_user(id)"` 应当等于写操作的
      #   条数）。理由见本文件顶部"管理范围"那段。
      if (!can_user(id)) return(deny())
      if (identical(id, as.integer(state$user_id))) {
        # 自己把自己停用会立刻退出且再也进不来（除非改数据库），
        # 这个口子不该开。
        return(note("不能停用当前登录的管理员自己。", "warning"))
      }
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      new_status <- if (identical(u$status, "active")) "disabled" else "active"
      try(dsapp_user_set_status(id, new_status, con = dsapp_db(cfg)),
          silent = TRUE)
      audit("admin_status", target = as.character(u$email %||% ""),
            detail = if (identical(new_status, "disabled")) "停用" else "启用")
      note(sprintf("账号 #%d（%s）已%s。", id, u$nickname,
                   if (identical(new_status, "disabled")) "停用" else "启用"),
           "success")
      refresh(refresh() + 1)
    })

    observeEvent(input$reset_token, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      if (!can_user(id)) return(deny())
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      tok <- dsapp_user_reset_token(id, con = dsapp_db(cfg))
      audit("admin_token", target = as.character(u$email %||% ""),
            detail = "旧码与旧 cookie 失效")
      note(HTML(sprintf(
        "账号 #%d（%s）的新恢复码：<br><code>%s</code><br>
         <span class='text-muted'>把它发给本人。旧码和旧 cookie 都已失效 ——
         他在新码登录之前进不来（没设密码的话）。</span>",
        id, htmltools::htmlEscape(u$nickname), htmltools::htmlEscape(tok))),
        "success")
      refresh(refresh() + 1)
    })

    # ---- 重置密码 ----
    #
    # 管理员**指定**一个新密码（没有邮件通道可以发一次性链接），用户下次
    # 登录时会被强制改掉 —— 见 dsapp_user_admin_reset_password 和
    # mod_welcome.R 的强制改密页。管理员知道的那个密码因此只生效一次。
    observeEvent(input$reset_pw, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      if (!can_user(id)) return(deny())
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      if (is.null(u)) return(note("这个账号已经不在了。", "warning"))
      showModal(modalDialog(
        title = sprintf("重置 %s 的密码", u$nickname),
        passwordInput(ns("new_pw"), "临时密码",
                      placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
        helpText(class = "small text-muted",
          "把这个密码告诉本人。他下次登录时会被要求改成自己的 —— ",
          tags$b("这个临时密码只能用来登录一次。"),
          tags$br(),
          "原来那个密码立刻失效。恢复码不受影响。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_reset_pw"), "重置", class = "btn-primary")
        )
      ))
    })

    observeEvent(input$confirm_reset_pw, {
      id <- selected()
      req(id)
      if (!can_user(id)) return(deny())
      # 邮箱要在**重置之前**取：后面的 note() 用的是昵称，但日志要的是
      # 邮箱；失败时账号还在，成功时也已经取到了。
      u <- tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      r <- tryCatch(
        dsapp_user_admin_reset_password(id, input$new_pw %||% "",
                                        con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      removeModal()
      audit("pw_admin_reset", target = as.character(u$email %||% ""),
            detail = "临时密码，登录后必须改", ok = isTRUE(r$ok))
      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))
      note(sprintf("%s 下次登录时必须先设置自己的新密码。", r$msg), "success")
      refresh(refresh() + 1)
    })

    # ---- 配额 + 资源上限（V13.12 item 3：合并成一个入口）----------------------
    #
    # 用户原话：「设置配额和资源上限应该合并」。
    #
    # ⚠️ 合并的是**入口**，不是**存储**。这是两件语义完全不同的事，硬凑成
    #    一列一定会出事：
    #      · quota_gb（GB，0/NULL = 不限）——磁盘累计额度，"他能存多少"，
    #        管的是上传/解压/起任务这三道闸（R/users.R 的 dsapp_quota_check）。
    #      · cpu_sec / mem_mb / max_procs（秒/MB/个数，NULL = 跟着平台默认）
    #        ——单任务的 OS 上限，落成 ulimit（R/executor.R），管的是
    #        "他这一次能吃掉多少机器"。
    #    单位不同、空值语义相反（一个 0 是"不限"、另一个空是"用默认"）、
    #    计量方向也不同。所以下面**照样调两个写入函数、记两条审计**，
    #    只是让管理员少点一次按钮、少开一个弹窗。
    #    审计标签也保持分开（admin_quota / admin_limits）—— 合成一条的话，
    #    以后翻日志再也分不清某次改动动的是磁盘还是 CPU。
    observeEvent(input$set_quota_limits, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      if (!can_user(id)) return(deny())
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      if (is.null(u)) return(note("这个账号已经不在了。", "warning"))

      cur_q <- suppressWarnings(as.numeric(u$quota_gb %||% NA))
      cur_l <- dsapp_user_limits(id, con = dsapp_db(cfg))
      dflt  <- dsapp_limits_for_user(NULL, cfg = cfg, con = dsapp_db(cfg))
      # GPU 是三态（TRUE / FALSE / NA），不在 cur_l 里（见 users.R 的说明），
      # 单独取一次；下面 radioButtons 的选项和默认选中都读它。
      cur_g <- dsapp_user_gpu_enabled(id, con = dsapp_db(cfg))
      # ★ V15.6 item 14：三项里只要有一项是哨兵，勾选框就默认勾上。
      #   ⚠️ 这段必须写在 showModal() **外面** —— 参数列表里不能有赋值语句
      #      （parse 直接报 unexpected symbol，而且报在下面那一行，
      #       看起来像是 checkboxInput 写错了）。
      cur_unlim <- dsapp_limit_is_unlimited(cur_l$cpu_sec) ||
                   dsapp_limit_is_unlimited(cur_l$mem_mb) ||
                   dsapp_limit_is_unlimited(cur_l$max_procs)

      showModal(modalDialog(
        title = sprintf("给 %s 设置配额与资源上限", u$nickname),
        size = "l",

        # ---- 第一段：磁盘配额 ----
        tags$h6(class = "fw-bold", icon("hard-drive"), " 存储配额"),
        # 默认填当前值而不是 0：管理员多半是来微调的，从 0 开始会让他
        # 一不小心就把一个已经设好的配额清掉。
        numericInput(ns("quota_gb"), "配额（GB）",
                     value = if (is.na(cur_q)) 0 else cur_q,
                     min = 0, max = 1e6, step = 10),
        helpText(class = "small text-muted",
          tags$b("0 表示不限配额。"),
          "配额管的是：对话工作区 + 对话专属 conda 环境 + 他发布到共享区的文件。",
          tags$br(),
          "超了之后他不能再上传、不能再解压、不能起新任务 ——",
          dsapp_md_inline("但**已经有的文件仍然读得到**，删掉一些就能继续。"),
          tags$br(),
          "不改别人的东西：这个配额只影响他自己能写多少。"),

        tags$hr(),

        # ---- 第二段：运行资源上限 ----
        #
        # 三样一起设，分三个弹窗的话管理员要点三次、而这三样通常是同时调的
        # （"这个人跑单细胞，给他多要点内存"）。
        #
        # ⚠️ 输入框默认填**当前值**，没设过的填平台默认值 —— 但那是**显示**用的
        #    参考，不是"已经设过了"。所以下面判断"要不要写库"看的是管理员有没有
        #    真的改过，而不是输入框里有没有数字。
        #    留空 = 恢复默认，这是 dsapp_user_set_limits 的既定语义（见那边注释）。
        tags$h6(class = "fw-bold", icon("microchip"), " 运行资源上限"),
        helpText(class = "small text-muted",
          "这三项是他", tags$b("单个任务"), "能用的上限，不是全平台的。",
          tags$br(),
          tags$b("留空 = 跟着平台默认走"), "（当前是 ",
          sprintf("%g 秒 CPU、%s 内存、%d 个进程",
                  dflt$cpu_sec,
                  dsapp_fmt_bytes(dflt$mem_mb * 1024 * 1024),
                  as.integer(dflt$max_procs)),
          "）。账号被删或者没设置过时，走的也是这套默认值。"),
        # ★★ V15.6 item 14：用户原话「配额和资源上限里需要可以让管理员直接
        #    设置，不限制使用」。
        #
        #    ⚠️ 为什么是一个勾选框，而不是让管理员往数字框里填 0 / -1：
        #      数字框的 min 是 60 / 256 / 16，填 0 根本进不去；而"清空"
        #      **已经**是"恢复平台默认"的意思了（见上面那行 helpText）。
        #      同一格里再塞一层意思，管理员分不清"我清空是要默认还是要不限制"。
        #    ⚠️ 三样一起设，不拆成三个勾选框：这个勾选框回答的是"这个人要不要
        #      卡着跑"，而那三样通常是一起决定的（"他跑单细胞，别卡他"）。
        #      真要只放开一项（比如只放内存），把另外两项填上数字、勾上这个框
        #      是不行的 —— 勾上就是三项全放开。这条限制写在下面的 helpText 里，
        #      不让管理员去猜。
        checkboxInput(ns("lim_unlimited"),
          HTML("<b>不限制</b>（CPU 时间 / 内存 / 进程数都不设上限）"),
          value = cur_unlim),
        helpText(class = "small text-muted",
          "勾上之后，他跑的任务", tags$b("不会被因为超时或内存被杀"),
          "（只受机器本身限制）。", tags$br(),
          # ⚠️ 这句必须写：不写的话，管理员会以为"勾上 + 填数字"能表示
          #    "只放开某一项"，而实际是三项全放开。
          "勾上时下面三个数字", tags$b("会被忽略"), "；要只放开其中一项，",
          "请保持不勾、把另外两项填上数字。", tags$br(),
          "机器被跑满时，不设上限的账号", tags$b("会影响同一台机器上的其他人"),
          " —— 平台默认值（不勾这个框时的那个）就是为这件事准备的。"),
        numericInput(ns("lim_cpu"), "CPU 时间上限（秒）",
                     value = if (is.null(cur_l$cpu_sec) ||
                                 dsapp_limit_is_unlimited(cur_l$cpu_sec)) NA
                             else cur_l$cpu_sec,
                     min = 60, max = 86400, step = 60),
        numericInput(ns("lim_mem"), "内存上限（MB）",
                     value = if (is.null(cur_l$mem_mb) ||
                                 dsapp_limit_is_unlimited(cur_l$mem_mb)) NA
                             else cur_l$mem_mb,
                     min = 256, max = 4 * 1024 * 1024, step = 256),
        numericInput(ns("lim_procs"), "最大进程数",
                     value = if (is.null(cur_l$max_procs) ||
                                 dsapp_limit_is_unlimited(cur_l$max_procs)) NA
                             else cur_l$max_procs,
                     min = 16, max = 65536, step = 8),
        helpText(class = "small text-muted",
          icon("triangle-exclamation"),
          " 调", tags$b("小"), "会立刻影响他下一次执行：内存给小了，单细胞那种任务会直接",
          "被系统杀掉（报 OOM，不是报错退出）。调大不保证一定给得到 ——",
          "机器本身的内存是硬上限。"),

        tags$hr(),

        # ---- 第三段：GPU 开关（V14 item 7）----
        #
        # ⚠️ 用**三选一**而不是一个勾选框：存储本身是三态的
        #    （users.gpu_enabled = 1 / 0 / NULL），而 NULL 是"跟着平台默认"
        #    —— 一个勾选框只有"勾/不勾"两种状态，表达不了它。硬用勾选框的话，
        #    "恢复默认"就只能靠"再勾一次"之类的暗规则，管理员永远搞不清
        #    现在到底是哪种。见 users.R 的 dsapp_user_gpu_enabled()。
        #
        # ⚠️ 取值用 "allow"/"deny"/"default" 三个字符串，**不要**用
        #    TRUE/FALSE/""：radioButtons 的 value 会经过一次 JSON 往返，
        #    逻辑值和"没选"在客户端长得太像，而这个界面上的"没选"恰好
        #    是有语义的（= 恢复默认）。
        tags$h6(class = "fw-bold", icon("microchip"), " GPU 使用权限"),
        radioButtons(ns("lim_gpu"), NULL,
          choices = c(
            "跟着平台默认" = "default",
            "允许使用 GPU" = "allow",
            "禁止使用 GPU" = "deny"
          ),
          selected = if (is.na(cur_g)) "default" else if (cur_g) "allow" else "deny",
          inline = TRUE),
        helpText(class = "small text-muted",
          "当前平台默认：", tags$b(if (isTRUE(cfg$exec$gpu)) "允许" else "禁止"),
          "（由环境变量 ", tags$code("DSAPP_EXEC_GPU"), " 决定）。",
          tags$br(),
          "关掉之后，他跑的代码", tags$b("看不见任何显卡"),
          "（进程里的 CUDA_VISIBLE_DEVICES 等一律置空），PyTorch / RAPIDS /",
          "cell2location 这类会干净地回落到 CPU，而不是报一堆看不懂的驱动错。",
          tags$br(),
          tags$b("只管本机执行。"), "他要是配了自己的「远程服务器」，代码在",
          "那台机器上跑 —— 那是他的硬件，这个开关管不着。",
          tags$br(),
          # 机器上没卡时如实说一句。否则管理员打开开关、用户去跑、还是失败，
          # 而失败信息（no CUDA-capable device）看着像开关没生效。
          {
            hg <- dsapp_host_gpu()
            if (isTRUE(hg$ok)) {
              tagList(icon("circle-check"), " ", hg$detail, "。")
            } else {
              tagList(icon("triangle-exclamation"), " ",
                tags$b(hg$detail), " —— 现在打开这个开关",
                tags$b("不会有任何可观察的差别"), "（用户那边照样会报",
                tags$code("no CUDA-capable device"), "）。它是给以后挂了卡准备的。")
            }
          }),

        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_quota_limits"), "保存", class = "btn-primary")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_quota_limits, {
      id <- selected()
      removeModal()
      if (is.null(id)) return(invisible(NULL))
      if (!can_user(id)) return(deny())

      # numericInput 被清空时 input 是 NA（不是 NULL）—— 两个都要当成
      # "恢复默认"，见 dsapp_user_set_limits 的语义。`%||%` 只挡 NULL。
      g <- function(x) if (is.null(x) || length(x) == 0 || is.na(x)) NULL else x

      u <- tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      who <- as.character(u$email %||% "")

      # ---- 磁盘配额 ----
      gb <- tryCatch(
        dsapp_user_set_quota(id, input$quota_gb %||% 0, con = dsapp_db(cfg)),
        error = function(e) NA_real_)
      if (is.na(gb)) {
        note("存储配额没写成，资源上限也没动 —— 请重试。", "danger")
        return(invisible(NULL))
      }
      audit("admin_quota", target = who,
            detail = if (gb <= 0) "不限" else sprintf("%.1f GB", gb))

      # ---- 运行资源上限 ----
      #
      # ★ V15.6 item 14：勾了「不限制」就三项一起写哨兵（负数），数字框里
      #   填的东西**一律忽略** —— 界面上的 helpText 就是这么说的。
      #   ⚠️ 不能写成"勾上时只把空着的那些设成不限制"：那样管理员填了 60 秒
      #      又勾上不限制，得到的是一个"CPU 60 秒、内存进程不限"的混合体，
      #      而他看到的是自己勾了不限制。要么全放开、要么全按数字，不留中间态。
      unlim_sel <- isTRUE(input$lim_unlimited)
      lim_val <- function(x) if (unlim_sel) DSAPP_LIMIT_UNLIMITED else g(x)
      r <- tryCatch(
        dsapp_user_set_limits(id, cpu_sec = lim_val(input$lim_cpu),
                              mem_mb = lim_val(input$lim_mem),
                              max_procs = lim_val(input$lim_procs),
                              con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_limits", target = who,
            detail = if (unlim_sel) "不限制"
                     else sprintf("cpu=%s mem=%s procs=%s",
                                  g(input$lim_cpu) %||% "默认",
                                  g(input$lim_mem) %||% "默认",
                                  g(input$lim_procs) %||% "默认"),
            ok = isTRUE(r$ok))

      # ---- GPU 开关（V14 item 7）----
      #
      # ⚠️ 单独写一次、单独记一条审计（admin_gpu）：它和上面那三样不是一回事
      #    —— 那三样是"他能吃多少机器"，这一样是"他能不能碰那张卡"。
      #    合成一条 admin_limits 的话，以后翻日志分不清某次改动到底动没动卡。
      #
      # ⚠️ "跟着平台默认"要写 NULL，而且**必须走 dsapp_user_clear_gpu()**：
      #    dsapp_user_set_gpu() 的入参是布尔，传 NULL 进去会被它当成"禁止"
      #    （见那边的注释），正好和这里要的相反。
      gpu_sel <- as.character(input$lim_gpu %||% "default")[1]
      gr <- tryCatch(
        switch(gpu_sel,
          allow = dsapp_user_set_gpu(id, TRUE,  con = dsapp_db(cfg)),
          deny  = dsapp_user_set_gpu(id, FALSE, con = dsapp_db(cfg)),
          dsapp_user_clear_gpu(id, con = dsapp_db(cfg))
        ),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_gpu", target = who,
            detail = switch(gpu_sel, allow = "允许", deny = "禁止", "恢复平台默认"),
            ok = isTRUE(gr$ok))

      if (!isTRUE(r$ok)) {
        note(sprintf("配额已保存；资源上限没写成：%s", r$msg %||% ""), "warning")
      } else {
        note(sprintf("账号 #%d 已更新：存储配额 %s；资源上限 %s；GPU %s。",
                     id,
                     if (gb <= 0) "不限" else dsapp_fmt_bytes(gb * DSAPP_GB),
                     # ★ V15.6 item 14：回执要如实说"不限制"，不能笼统写成
                     #   "空的项走平台默认" —— 勾了不限制的账号，那三项既不是
                     #   空的、也没走平台默认，管理员从这句回执里看不出来。
                     if (unlim_sel) "不限制" else "空的项走平台默认",
                     if (!isTRUE(gr$ok)) "没改成"
                     else switch(gpu_sel, allow = "已允许", deny = "已禁止",
                                 "恢复平台默认")),
             "success")
      }
      refresh(refresh() + 1)
    })

    # ---- 改登录邮箱 ----
    #
    # 邮箱在这个应用里就是账号本身（登录用它、日志用它标识人、恢复码挂在它
    # 下面），所以这是个身份级别的动作，不是"改个联系方式"。界面上要把这句
    # 话说明白，否则管理员会以为改完对方只是收不到通知了。
    observeEvent(input$set_email, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      if (!can_user(id)) return(deny())
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      if (is.null(u)) return(note("这个账号已经不在了。", "warning"))
      showModal(modalDialog(
        title = sprintf("修改 %s 的登录邮箱", u$nickname),
        textInput(ns("new_email"), "新邮箱", value = as.character(u$email %||% "")),
        helpText(class = "small text-muted",
          tags$b("邮箱就是这个账号的用户名。"),
          "改完之后他要用新邮箱登录，恢复码不受影响，密码也不变 ——",
          "已经登录着的会话不会掉线。",
          tags$br(),
          "旧邮箱上的登录失败计数会一起清掉。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_email"), "保存", class = "btn-primary")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_email, {
      id <- selected()
      removeModal()
      if (is.null(id)) return(invisible(NULL))
      if (!can_user(id)) return(deny())
      old <- tryCatch(as.character(dsapp_user_by_id(id, con = dsapp_db(cfg))$email
                                   %||% ""), error = function(e) "")
      r <- tryCatch(
        dsapp_user_set_email(id, input$new_email %||% "", con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_email", target = old, detail = r$msg %||% "", ok = isTRUE(r$ok))
      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))
      note(r$msg, "success")
      refresh(refresh() + 1)
    })

    observeEvent(input$delete, {
      id <- selected()
      if (is.null(id)) return(note("先在表里选一个账号。", "warning"))
      if (!can_user(id)) return(deny())
      if (identical(id, as.integer(state$user_id))) {
        return(note("不能删除当前登录的管理员自己。", "warning"))
      }
      u <- dsapp_user_by_id(id, con = dsapp_db(cfg))
      if (is.null(u)) return(note("这个账号已经不在了。", "warning"))

      # 删账号是会掉数据的动作，二次确认。用 modal 是可以的 ——
      # 这一页没有 agent 循环在跑，不存在"弹窗挂着人就走了"的问题
      # （那条约束见 mod_chat.R 的说明）。
      showModal(modalDialog(
        title = "确认删除账号",
        # ★★ V16.6 item 3：这段文案必须和代码**同款**。改前它写的是
        #    「上传到共享区的文件不会被删除…会变成公共文件」—— 那是老行为，
        #    而用户这次要求的就是反过来（「全部历史记录和文件应该一并删除，
        #    而不是进入共享区」）。文案不改的话，管理员看到的承诺和实际发生的
        #    事正好相反，而且**双方都不会报错**。
        sprintf("将删除 %s（%s）及其 %d 个对话、这些对话的工作区和环境。",
                u$nickname, u$email, u$n_chat %||% 0L),
        tags$br(),
        tags$b("这个账号的文件管理区（data/files/ 下他那一整个目录）也会一并删除。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_delete"), "确认删除",
                       class = "btn-danger")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_delete, {
      id <- selected()
      removeModal()
      if (is.null(id)) return(invisible(NULL))
      if (!can_user(id)) return(deny())
      # ★ V13.8 item 1：删号是**平台管理员专有**的（界面上那个按钮也藏了，
      #   见 mod_admin_ui；这里是不信任界面的那一道）。项目管理员对组内
      #   账号能做的事是"更改"，删号不在里面 —— 它会连带删掉那个人所有
      #   对话、工作区和环境，不可逆。
      if (!is_platform()) {
        return(note("删除账号只由平台管理员做 —— 你可以先停用他。", "warning"))
      }
      # 删之前先把身份读出来：删完 dsapp_user_by_id 就查不到了，
      # 而这条日志恰恰是**最需要留下**的那种（见 R/audit.R 顶部第 3 条）。
      u <- tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      n <- tryCatch(dsapp_user_delete(id, cfg, con = dsapp_db(cfg)),
                    error = function(e) {
                      # ★ V13.7 item 2：原文进审计日志，界面上说人话
                      note(dsapp_err_user(e, "删除这个账号",
                                          hint = "账号还在，没有被删掉一半。"), "danger")
                      NULL
                    })
      audit("admin_delete", target = as.character(u$email %||% ""),
            detail = sprintf("%s · %s 个对话", as.character(u$nickname %||% ""),
                             if (is.null(n)) "?" else n),
            ok = !is.null(n))
      if (!is.null(n)) {
        # ★ V16.6 item 3：把"连文件一起清了"说出来。用户提这件事的原话是
        #   「文件应该一并删除，而不是进入共享区」—— 回执里不带这一句的话，
        #   管理员没法从界面上知道到底清没清（只能自己去翻盘）。
        rg <- attr(n, "purged")
        note(sprintf("已删除账号 #%d：%d 个对话%s。",
                     id, n,
                     if (is.null(rg)) "" else sprintf("、%d 个文件（管理区目录已整个删除）",
                                                      rg[["files_dir"]])),
             "success")
      }
      refresh(refresh() + 1)
    })

    # ---- 各用户的任务运行情况 ----
    #
    # 不跟 refresh() 那条 60 秒的节拍走：这一块是管理员**主动来看**的
    # （"他说任务卡住了，我看看"），等 60 秒才更新等于逼他再点一次。
    # 有自己的刷新按钮，另外选中账号/状态变化时也会重查。
    ut_refresh <- reactiveVal(0)
    observeEvent(input$ut_refresh, ut_refresh(ut_refresh() + 1))

    # 账号下拉。和日志卡里那两个下拉同样的做法：**renderUI 渲染**，不用
    # updateSelectInput —— 模块 server 在会话建立时就跑，那一刻浏览器还没
    # 拿到页面，此时发出去的 update 消息到了客户端找不到元素、被直接丢掉
    # （Shiny 的 input 消息不排队）。表现是下拉永远空的，且不报任何错。
    #
    # 这里用 users_all() 而不是 users()：后者是**用户表筛过的**，管理员在
    # 用户表里搜了个人，这里的账号列表就莫名其妙只剩一个了。
    output$ut_user_sel <- renderUI({
      refresh()
      us <- tryCatch(users_all(), error = function(e) NULL)
      ch <- c("（选一个账号）" = "")
      if (!is.null(us) && nrow(us) > 0) {
        ch <- c(ch, stats::setNames(
          as.character(us$id),
          sprintf("%s <%s>", us$nickname, us$email)))
      }
      # 当前选中值 isolate()：不隔离的话这个 render 就依赖了它自己渲染出来的
      # 输入（改选 → 重渲染 → 重建元素 → 选择被重置），是自己喂自己的环。
      selectInput(ns("ut_user"), NULL, width = "100%",
                  choices = ch, selected = isolate(input$ut_user) %||% "")
    })

    ut_rows <- reactive({
      ut_refresh()
      uid <- input$ut_user
      if (is.null(uid) || !nzchar(as.character(uid))) return(NULL)
      st <- as.character(input$ut_status %||% "")
      df <- tryCatch(db_tasks_by_owner(as.integer(uid), limit = 200,
                                       con = dsapp_db(cfg)),
                     error = function(e) NULL)
      if (is.null(df)) return(NULL)
      # ★ V13.8 item 1：项目管理员看的是「自己**分发出去**的任务」。
      #
      # "按账号列任务"这个视角本身不够 —— 组里那个人名下还跑着他自己的、
      # 以及**别人**共享给他的对话里的任务，那些跟这个项目管理员没有任何
      # 关系。所以再过一道对话级的筛：只留他名下和他分发出去的那些对话
      # 里的任务（判据见 R/users.R 的 dsapp_admin_scope_session_ids）。
      #
      # ⚠️ `session_id %in% NULL` 是 logical(0)，会把这批行判成"长度 0 的
      #    下标"而不是"全留" —— 平台管理员那边必须走 is.null() 那条路。
      sc <- my_sess_ids()
      if (!is.null(sc) && nrow(df) > 0) {
        df <- df[as.character(df$session_id) %in% sc, , drop = FALSE]
      }
      if (nzchar(st) && nrow(df) > 0) df <- df[as.character(df$status) == st, ,
                                               drop = FALSE]
      df
    })

    output$ut_stats <- renderUI({
      ut_refresh()
      uid <- input$ut_user
      if (is.null(uid) || !nzchar(as.character(uid))) {
        return(p(class = "text-muted small mb-2",
                 "先在上面选一个账号。"))
      }
      # 范围过滤和下面的 ut_rows 用同一份判据（见那里的注释）。
      cnt <- tryCatch(db_task_counts_by_owner(as.integer(uid),
                                              session_ids = my_sess_ids(),
                                              con = dsapp_db(cfg)),
                      error = function(e) NULL)
      if (is.null(cnt) || length(cnt) == 0) {
        return(p(class = "text-muted small mb-2", "这个账号还没跑过任务。"))
      }
      # ⚠️ `cnt[[k]]` 在**名字不存在**时是抛异常（"subscript out of bounds"），
      #    不是返回 NULL —— 而这段代码的常态恰恰是"大多数状态键都不存在"
      #    （一个从没失败过的账号，cnt 里只有 success 一个键）。必须先用
      #    %in% 判一下。（写完跑测试当场踩到，普通使用下就是整张卡变空白。）
      n <- function(k) if (k %in% names(cnt)) as.integer(cnt[[k]]) else 0L
      # 只把**非零**的项摆出来。全列出来的话，一个正常账号那行常年是
      # "成功 12 · 失败 0 · 出错 0 · 超时 0 · 运行中 0 · 排队中 0"，
      # 真正要看的那个数字反而被淹没。
      parts <- c(
        if (n("running") > 0) sprintf("运行中 %d", n("running")),
        if (n("pending") > 0) sprintf("排队中 %d", n("pending")),
        if (n("success") > 0) sprintf("成功 %d", n("success")),
        if (n("failed") > 0)  sprintf("失败 %d", n("failed")),
        if (n("error") > 0)   sprintf("出错 %d", n("error")),
        if (n("timeout") > 0) sprintf("超时 %d", n("timeout")))
      # 有正在跑的就用带颜色的徽章 —— 这是整张卡最需要一眼看到的信号。
      div(class = "mb-2",
        if (n("running") + n("pending") > 0)
          span(class = "badge text-bg-success me-2",
               sprintf("● 正在跑 %d 个", n("running") + n("pending"))),
        span(class = "small text-muted", paste(parts, collapse = " · ")))
    })

    output$ut_tbl <- DT::renderDataTable({
      df <- ut_rows()
      if (is.null(df)) {
        return(DT::datatable(data.frame(提示 = "先选一个账号"),
                             options = list(dom = "t"), rownames = FALSE))
      }
      if (nrow(df) == 0) {
        return(DT::datatable(data.frame(提示 = "没有符合条件的任务"),
                             options = list(dom = "t"), rownames = FALSE))
      }
      # 耗时：跑完的用 finished - started，还在跑的用 现在 - started。
      # 不写这一列的话，"跑了 3 个小时还没结束"和"3 秒跑完"在表上长得
      # 一模一样 —— 而前者正是管理员被叫来看的东西。
      dur <- vapply(seq_len(nrow(df)), function(i) {
        st <- as.character(df$started_at[i] %||% "")
        if (!nzchar(st) || is.na(st)) return("—")
        en <- as.character(df$finished_at[i] %||% "")
        secs <- if (nzchar(en) && !is.na(en)) {
          # 两个时间戳都是库里的 UTC 字符串，相减前统一解析一次。
          a <- dsapp_parse_time(st); b <- dsapp_parse_time(en)
          if (is.na(a) || is.na(b)) NA_real_ else as.numeric(difftime(b, a,
                                                                     units = "secs"))
        } else {
          dsapp_since_seconds(st)
        }
        if (is.na(secs)) "—" else dsapp_fmt_duration(secs)
      }, character(1))

      show <- data.frame(
        id      = df$id,
        session = substr(df$session_title %||% rep("", nrow(df)), 1, 28),
        title   = substr(df$title, 1, 32),
        lang    = df$lang,
        status  = dsapp_status_label(df$status),
        exit    = ifelse(is.na(df$exit_code), "—", as.character(df$exit_code)),
        dur     = dur,
        time    = vapply(df$created_at, dsapp_fmt_time, character(1)),
        stringsAsFactors = FALSE
      )
      DT::datatable(
        show,
        # ⚠️ 这一列里**没有**代码、stdout、stderr。管理页不显示任何用户的
        #    数据内容（见文件头），生信数据常常是未发表的。要看输出，让本人
        #    在任务页上看，或者他共享对话给你。
        colnames = c("ID", "对话", "标题", "语言", "状态", "退出码",
                     "耗时", "创建时间"),
        selection = "none", rownames = FALSE,
        options = list(dom = "tp", pageLength = 10, ordering = FALSE,
                       columnDefs = list(list(className = "dt-left",
                                              targets = "_all")))
      )
    })

    # ---- 登录锁定 ----
    #
    # V13.8 item 1：锁是按**邮箱**记的（login_fail 表），所以范围过滤要先
    # 把邮箱换成账号、再判在不在范围里。不在范围内的行直接不显示 ——
    # "谁被锁了"本身就是一条账号信息。
    locked_rows <- reactive({
      refresh()
      lk <- tryCatch(dsapp_login_locks(con = dsapp_db(cfg)),
                     error = function(e) NULL)
      if (is.null(lk) || nrow(lk) == 0) return(lk)
      sc <- my_user_ids()
      if (is.null(sc)) return(lk)
      keep <- vapply(as.character(lk$email), function(em) {
        u <- tryCatch(dsapp_user_by_email(em, con = dsapp_db(cfg)),
                      error = function(e) NULL)
        !is.null(u) && as.integer(u$id) %in% as.integer(sc)
      }, logical(1))
      lk[keep, , drop = FALSE]
    })

    output$locks <- renderUI({
      lk <- tryCatch(locked_rows(), error = function(e) NULL)
      if (is.null(lk) || nrow(lk) == 0) {
        return(p(class = "text-muted small mb-0", "当前没有账号处于锁定状态。"))
      }
      tagList(
        div(class = "dsapp-file-owner-list",
          lapply(seq_len(nrow(lk)), function(i) {
            # 邮箱 → 昵称只在**查得到**的时候补。锁定的行按邮箱存，
            # 邮箱对应的账号可能刚刚被删掉（那行计数还在），此时不能报错。
            u <- tryCatch(dsapp_user_by_email(lk$email[[i]], con = dsapp_db(cfg)),
                          error = function(e) NULL)
            div(class = "d-flex justify-content-between border-bottom py-1 small",
              span(tags$code(lk$email[[i]]),
                   if (!is.null(u)) span(class = "text-muted ms-2", u$nickname)),
              span(class = "text-muted",
                   sprintf("连错 %s 次 · 还有 %d 分钟",
                           lk$n_fail[[i]], ceiling(lk$secs[[i]] / 60)))
            )
          })
        ),
        p(class = "small text-muted mb-0 mt-2",
          "被锁的人自己等满时间也能进，解锁只是让他不用等。")
      )
    })

    observeEvent(input$unlock_all, {
      # V13.8 item 1：「全部解锁」对项目管理员是**他范围内的全部**，
      # 不是全平台。按钮上写的字没变（他看到的"全部"就是他那一屏），
      # 但服务端解的确实是那个范围 —— dsapp_login_unlock(NULL) 会一把
      # 清掉所有人的锁，包括他根本看不见的那些账号。
      n <- 0L
      if (is_platform()) {
        n <- tryCatch(dsapp_login_unlock(NULL, con = dsapp_db(cfg)),
                      error = function(e) 0L)
      } else {
        sc <- my_user_ids()
        for (em in as.character(locked_rows()$email %||% character(0))) {
          u <- tryCatch(dsapp_user_by_email(em, con = dsapp_db(cfg)),
                        error = function(e) NULL)
          if (is.null(u) || !as.integer(u$id) %in% as.integer(sc)) next
          n <- n + tryCatch(dsapp_login_unlock(em, con = dsapp_db(cfg)),
                            error = function(e) 0L)
        }
      }
      audit("admin_unlock", detail = sprintf("全部解锁，共 %d 个", n))
      note(sprintf("已解除 %d 个账号的登录锁定。", n), "success")
      refresh(refresh() + 1)
    })

    # ---- 文件归属 ----
    output$files <- renderUI({
      # ★ V13.8 item 1：同 output$stats。**这一条尤其要挡** —— 它第一件事
      # 就是 dsapp_files_sync_owners()，那是一次**写库**（把新文件补进
      # file_owner）。让一个看不见这张卡的人每次刷新都触发一次全平台扫描
      # 写入，既浪费又莫名其妙。
      if (!is_platform()) return(NULL)
      refresh()
      con <- dsapp_db(cfg)
      # ★ V13.10 item 2：先清掉指平台点文件的行（`.migrated_v13` 这种），
      #   再补登记盘上的新文件。顺序**不能反**：先补的话，这一轮算出来的
      #   无归属数里还含着马上要被删掉的那几行，用户会看到"有 1 个无归属"
      #   然后刷新一下又没了。
      try(dsapp_files_purge_dotfiles(con, cfg), silent = TRUE)
      n_new <- tryCatch(dsapp_files_sync_owners(con, cfg), error = function(e) 0L)

      # ⚠️ V13 item 6：name 现在带 `u<N>/` 前缀（见 users.R 的 dsapp_owner_key），
      #    管理员看的这份清单要把它显示成"哪个账号的哪个文件"，所以前缀单独
      #    拆一列出来，而不是让它在文件名里当一段路径 —— 后者容易被当成
      #    "文件管理区里有个叫 u3 的文件夹"。
      df <- tryCatch(DBI::dbGetQuery(con, "
        SELECT f.name, f.user_id, u.nickname
        FROM file_owner f LEFT JOIN users u ON u.id = f.user_id
        ORDER BY f.created_at DESC LIMIT 200"), error = function(e) NULL)
      if (!is.null(df) && nrow(df)) {
        df$acct <- sub("/.*$", "", df$name)
        df$name <- sub("^[^/]*/", "", df$name)
      }

      if (is.null(df) || nrow(df) == 0) {
        return(p(class = "text-muted small mb-0", "共享区里还没有文件。"))
      }
      # ⚠️ 单独 COUNT 一遍，**不能**用 `sum(is.na(df$user_id))`。df 上面是
      #    带 LIMIT 200 的，那个和数只是"最近 200 行里有几个无归属" —— 一旦
      #    表超过 200 行，下面那句话报的数就比真实值小，而它是一句**结论**
      #    （"共享区里有 N 个文件没有归属"），报小了会让人以为清干净了。
      orphan <- tryCatch(as.integer(DBI::dbGetQuery(con,
        "SELECT COUNT(*) n FROM file_owner WHERE user_id IS NULL")$n),
        error = function(e) 0L)

      tagList(
        if (n_new > 0 || orphan > 0) {
          div(class = "alert alert-secondary py-2 px-3 small",
            icon("circle-info"),
            sprintf(" 共享区里有 %d 个文件没有归属（这个版本之前上传的）。",
                    orphan),
            "它们对所有人生效、人人可删。要把它们划到一个账号名下的话，",
            "在下面选一个账号。")
        },
        div(class = "d-flex gap-2 align-items-center mb-2",
          selectInput(ns("claim_user"), NULL, width = "220px",
                      choices = c("（选择账号）" = "",
                                  stats::setNames(
                                    as.character(users_all()$id),
                                    sprintf("%s <%s>", users_all()$nickname,
                                            users_all()$email)))),
          actionButton(ns("claim_files"), "把无归属文件划给这个账号",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrows-turn-to-dots"))
        ),
        div(class = "dsapp-file-owner-list",
          lapply(seq_len(min(nrow(df), 60)), function(i) {
            div(class = "d-flex justify-content-between border-bottom py-1 small",
              span(tags$code(df$name[i]),
                   span(class = "text-muted ms-2", df$acct[i])),
              span(class = "text-muted",
                   if (is.na(df$user_id[i])) "公共（无归属）" else df$nickname[i])
            )
          })
        ),
        if (nrow(df) > 60) {
          p(class = "small text-muted mt-2 mb-0",
            sprintf("（只列最近 60 个，共 %d 个）", nrow(df)))
        }
      )
    })

    observeEvent(input$claim_files, {
      # ★ V13.8 item 1：整张「文件管理区的归属」卡只给平台管理员。
      # 这一条尤其要挡：它是一条**写库**的路（把无归属文件划到某个账号
      # 名下），而且改的是全平台共享区的归属。
      if (!is_platform()) return(deny("文件归属"))
      uid <- suppressWarnings(as.integer(input$claim_user %||% NA))
      if (is.na(uid)) return(note("先选一个账号。", "warning"))
      # ⚠️ 划过去的时候**前缀也要一起改**（V13 item 6）。file_owner.name 是
      #    `u<N>/相对路径`，而"无归属"的那些行前缀是 `_anon/` —— 只把
      #    user_id 改掉的话，行会变成"归属人是 3 号、但键在 _anon 段里"：
      #    3 号账号在界面上看不到它（查询按 u3/ 前缀过滤），而归属显示又
      #    说他拥有它。两边同时对不上，而且谁都不会报错。
      #
      # ⚠️ CASE 是必需的，不是保险：老库里的行压根**没有前缀**
      #    （`asv_table.csv`，V13 之前建的），无条件 substr 会把它切成
      #    `u1/able.csv` —— 归属行指向一个不存在的文件名。详见 users.R
      #    的 dsapp_user_claim_orphans，两处必须同款。
      n <- tryCatch(DBI::dbExecute(dsapp_db(cfg),
        "UPDATE file_owner
            SET user_id = ?,
                name = ? || CASE WHEN substr(name, 1, ?) = ?
                                 THEN substr(name, length(?) + 1)
                                 ELSE name END
          WHERE user_id IS NULL",
        params = list(uid, dsapp_owner_key("", uid),
                      nchar(dsapp_owner_key("", NA)), dsapp_owner_key("", NA),
                      nchar(dsapp_owner_key("", NA)))), error = function(e) 0L)
      tu <- tryCatch(dsapp_user_by_id(uid, con = dsapp_db(cfg)),
                     error = function(e) NULL)
      audit("admin_owner", target = as.character(tu$email %||% ""),
            detail = sprintf("%d 个无归属文件划过去", n))
      note(sprintf("已把 %d 个无归属文件划给账号 #%d。", n, uid), "success")
      refresh(refresh() + 1)
    })

    # ---- 无主的管理区目录（V16.6 item 3）----------------------------------
    #
    # ⚠️ 输出名 orphan_dirs 和里面那两个控件（orphan_pick / orphan_purge）
    #    **故意不同名** —— 同 id 会让 Shiny 的 updateXxx 静默失效，见 selftest ⑧。
    output$orphan_dirs <- renderUI({
      if (!is_platform()) return(NULL)
      refresh()
      or <- tryCatch(dsapp_files_orphans(cfg = cfg, con = dsapp_db(cfg)),
                     error = function(e) NULL)
      if (is.null(or) || !nrow(or)) {
        return(p(class = "small text-muted mt-3 mb-0",
                 icon("circle-check"), " ",
                 "没有无主的管理区目录。"))
      }
      mb <- sum(or$size_mb, na.rm = TRUE)
      tagList(
        hr(),
        div(class = "alert alert-warning py-2 px-3 small",
          icon("triangle-exclamation"), " ",
          sprintf("盘上有 %d 个管理区目录没有对应的账号（共 %d 个文件、%.1f MB）。",
                  nrow(or), sum(or$n_files), mb),
          "这些是**删号之前**遗留的（那时只删了归属记录、没删目录），",
          "下次有人登录时它们会被重新登记进共享区。清掉之后就不会再冒出来。"),
        checkboxGroupInput(ns("orphan_pick"), NULL,
          choices = stats::setNames(
            as.character(or$uid),
            sprintf("u%d —— %d 个文件 / %.1f MB", or$uid, or$n_files, or$size_mb))),
        div(class = "d-flex gap-2 align-items-center",
          actionButton(ns("orphan_purge"), "清掉勾选的目录",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("trash")),
          actionButton(ns("orphan_all"), "全选",
                       class = "btn-sm btn-outline-secondary")
        )
      )
    })

    observeEvent(input$orphan_all, {
      if (!is_platform()) return(deny("清理无主目录"))
      or <- tryCatch(dsapp_files_orphans(cfg = cfg, con = dsapp_db(cfg)),
                     error = function(e) NULL)
      if (is.null(or) || !nrow(or)) return(note("现在没有无主目录。", "info"))
      updateCheckboxGroupInput(session, "orphan_pick",
                               selected = as.character(or$uid))
    })

    observeEvent(input$orphan_purge, {
      if (!is_platform()) return(deny("清理无主目录"))
      picked <- suppressWarnings(as.integer(input$orphan_pick %||% integer(0)))
      picked <- picked[!is.na(picked)]
      if (!length(picked)) return(note("先勾一个要清的目录。", "warning"))
      # ⚠️ 界面传上来的 uid **一律不信**：`dsapp_files_orphans_purge()` 内部
      #    拿"当前真的没有主人"复核一遍。少了那一步的话，一个自己拼 input 的
      #    人能把**活着的**账号的文件目录删掉（不可逆）。
      n <- tryCatch(dsapp_files_orphans_purge(picked, cfg = cfg,
                                              con = dsapp_db(cfg)),
                    error = function(e) 0L)
      audit("admin_orphan_purge", target = paste(picked, collapse = ","),
            detail = sprintf("清掉 %d 个无主管理区", n))
      note(sprintf("清掉 %d 个无主管理区目录。%s", n,
                   if (n < length(picked)) "（其余几个已经不是无主的了，跳过）" else ""),
           if (n > 0) "success" else "warning")
      refresh(refresh() + 1)
    })

    invisible(NULL)
  })
}
