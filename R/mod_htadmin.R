# =============================================================================
# 后台（V13.8 item 2，只有**平台管理员**看得到）
# =============================================================================
# 用户的原话：「我需要有一个 ht 页面，作为超级管理员，拥有查看用户数、用户
# 活跃情况、更改用户权限、添加用户、删除用户，调整用户可调用硬件资源限制」。
#
# ⚠️ 「ht」按**后台**理解（拼音 hòutái），不是"HT 页"之类的专有名词。
#    这一页就是那个后台：一屏把"平台上有多少人、谁在动、谁是什么级别、每个
#    人能吃掉多少机器"说完，并且能直接改。
#
# ⚠️ 和「管理」页（mod_admin.R）的分工，别混：
#     管理页 = 日常运维 —— 谁被锁了、磁盘谁占的、某个任务跑成功没有。
#              项目管理员也进得去（只看得到自己那一片）。
#     后台页 = 平台治理 —— 账号的增删、级别的升降、资源的分配。
#              **只有平台管理员**，连 UI 都不给项目管理员。
#    两页有重叠（都能停用账号），这是有意的：后台页是"我要治理平台"的入口，
#    不该让人先去管理页里翻。重叠的那几个动作走的是同一批函数，判据也同一套。
#
# ⚠️ 这一页的每一个写操作都要**两道**：
#     ① app.R 里 `identical(admin_scope, "platform")` —— 决定看不看得见这一页；
#     ② 下面每个 handler 开头的 `is_platform()` —— 决定动得了动不了。
#    只做①的话，一个自己拼 input 值的人能直接调这一页的 observeEvent
#    （Shiny 的 input 就是 HTTP 上来的一个值），而这里的按钮里有「删除用户」
#    和「提升为平台管理员」—— 后者等于把整个平台交出去。
# =============================================================================

#' 后台页的卡片：**一张一个命名条目**（★ V15.4 item 7）
#'
#' 和 R/mod_admin.R 的 mod_admin_cards() 同一个改法、同一个理由：原来是一整个
#' tagList，现在按卡片返回，由 R/mod_backstage.R 分进子页。`ns` 还是
#' `NS("htadmin")` —— mod_htadmin_server("htadmin", ...) 那边一行都不用改。
#'
#' ⚠️ 这四张卡**整组只给平台管理员**（scope 不是 platform 时返回空 list）。
#'    合并之前这不成问题 —— 整页都是平台专属；合并之后"后台管理"这一页项目
#'    管理员也进得来，所以要在这里再挡一道。挡在**渲染层**：用 CSS 藏、
#'    服务端照算，等于白算（这一卡要读报错日志的尾巴、要全表扫活跃度）。
mod_htadmin_cards <- function(ns, scope = "platform") {
  if (!identical(as.character(scope %||% "")[1], "platform")) return(list())

  list(
    # ---- 概览 ----
    accounts = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("chart-pie"), " 平台账号概览"),
        actionButton(ns("refresh"), NULL, icon = icon("rotate"),
                     class = "btn-sm btn-outline-secondary", title = "重新统计")
      ),
      card_body(uiOutput(ns("overview")))
    ),

    # ---- 用户数与活跃情况 ----
    activity = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("users-viewfinder"), " 用户活跃情况"),
        span(class = "small text-muted fw-normal",
             "只统计次数和时间，不含任何对话内容")
      ),
      # ⚠️ V13.10 item 3：`fillable = FALSE` 是"表格压住下面那排按钮"的根因
      #    修复，和管理页（R/mod_admin.R）是同一个 bug、同一套三层默认值
      #    （bslib card_body → htmltools fill.css → DT 的
      #    `.html-fill-container > .html-fill-item.datatables{flex-basis:400px}`）。
      #    这里是**潜在的**复发点：V13.9 之后这一页的行数还少（7 行），
      #    表格缩不到按钮上；账号一多就会和管理页之前一样糊在一起。
      #    完整推导见 R/mod_tasks.R:47-68。
      card_body(
        fillable = FALSE,
        p(class = "small text-muted",
          "这张表回答的是", dsapp_md_inline("「谁在真的用、谁注册完就再没来过」："),
          "近 N 天的动作数和登录次数来自操作日志，累计那几列是**全时段**的",
          dsapp_md_inline("（把窗口从 30 天调到 7 天时，你不想看到「一共跑了 200 个任务」跟着变成 12）。")),
        div(class = "d-flex gap-2 align-items-end mb-2 flex-wrap",
          div(class = "flex-grow-1", style = "min-width:170px;",
            textInput(ns("kw"), NULL, placeholder = "搜昵称 / 邮箱")),
          div(style = "min-width:120px;",
            # selectize = FALSE：空串会被 selectize 当成 placeholder 吃掉，
            # 选过一次就再也回不到「全部」（管理页那几个下拉踩过同一个坑）。
            selectInput(ns("f_scope"), NULL, width = "100%", selectize = FALSE,
                        choices = c("（全部级别）" = "", "普通用户" = "user",
                                    "项目管理员" = "project",
                                    "平台管理员" = "platform"))),
          div(style = "min-width:110px;",
            selectInput(ns("f_status"), NULL, width = "100%", selectize = FALSE,
                        choices = c("（全部状态）" = "", "启用" = "active",
                                    "停用" = "disabled"))),
          div(style = "min-width:150px;",
            selectInput(ns("days"), "活跃窗口", width = "100%",
                        selectize = FALSE,
                        choices = c("最近 7 天" = "7", "最近 30 天" = "30",
                                    "最近 90 天" = "90", "最近一年" = "365"),
                        selected = "30")),
          actionButton(ns("clear"), NULL, icon = icon("xmark"),
                       class = "btn-sm btn-outline-secondary mb-3",
                       title = "清空筛选")
        ),
        uiOutput(ns("count")),
        # V13.10 item 3：同样是 `.dsapp-dt-nowrap`（12 列，窄窗口下不 nowrap
        # 会每格折行）。见 www/app.css 的 .dsapp-dt-nowrap。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("tbl"))),

        # ---- 针对选中账号的动作 ----
        #
        # 「添加用户」故意和另外几个放在一排但**不依赖选中行** ——
        # 新账号还没有行可选，把它混进"先选一个账号"那套里的话，第一次
        # 用这一页的人会先去找一个不存在的行。
        hr(),
        div(class = "d-flex gap-2 flex-wrap align-items-center",
          actionButton(ns("add"), "添加用户",
                       class = "btn-sm btn-primary", icon = icon("user-plus")),
          actionButton(ns("set_scope"), "更改权限",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("user-shield")),
          actionButton(ns("toggle"), "停用 / 启用",
                       class = "btn-sm btn-outline-warning", icon = icon("ban")),
          actionButton(ns("reset_pw"), "重置密码",
                       class = "btn-sm btn-outline-secondary", icon = icon("lock")),
          actionButton(ns("del"), "删除用户",
                       class = "btn-sm btn-outline-danger", icon = icon("trash"))
        ),
        uiOutput(ns("action_msg"))
      )
    ),

    # ---- 硬件资源限制 ----
    limits = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("microchip"), " 可调用硬件资源"),
        span(class = "small text-muted fw-normal",
             "按账号，作用于他的每一个任务")
      ),
      card_body(uiOutput(ns("limits")))
    ),

    # ---- 应用自身的报错（V13.10 item 1）----
    #
    # 用户报的那句 "Check your logs or contact the app author for
    # clarification" 有一半的毛病出在"日志在哪儿"：Shiny Server 的日志是
    # /var/log/shiny-server/ 下 shiny:shiny 0640 的文件，管理员自己都得
    # sudo 才读得到。这一卡把 data/logs/app_error.log 的尾巴直接摆在这里，
    # 平台管理员不用登服务器就能看到"刚才那个时间点出了什么事"。
    #
    # ⚠️ 只给平台管理员（下面的 renderUI 里挡）。这段文本里有**文件路径和
    #    工作区名**，而工作区名带 session id —— 和"后台页只回答谁在用、
    #    不回答他在分析什么"那条边界是一致的：报错栈里偶尔会带上文件名。
    errors = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("bug"), " 应用报错日志"),
        actionButton(ns("err_refresh"), NULL, icon = icon("rotate"),
                     class = "btn-sm btn-outline-secondary", title = "重新读取")
      ),
      card_body(
        fillable = FALSE,
        p(class = "small text-muted",
          "应用自己记的错误（", tags$code("data/logs/app_error.log"),
          "）。用户在页面上看到「这一块没能显示出来」时，对应的完整错误",
          "和调用栈在这里 —— 不用去服务器上翻 /var/log/shiny-server。"),
        uiOutput(ns("err_log"))
      )
    ),

    # ---- 信息同步跳板（V16.6 item 1）----
    #
    # 用户原话：「管理员页面也可以增加信息同步跳板，支持填写新的服务器信息
    #            做新的跳板。」
    #
    # 这一张卡管的是**这一台机器**的跳板清单（sync_servers 表）。它有三块：
    #   ① 允许同步建号的开关 —— 云端要不要认"桌面版注册的账号"
    #   ② 清单本身 —— 增删改、设默认、启停
    #   ③ 已经由同步包建出来的账号（只读，用来对账）
    #
    # ⚠️ 清单是**公开信息**（地址而已），凭据一概不在这里 —— SSH 用户名/
    #    密码/私钥永远由用的人自己在设置页填、只活在会话内存里
    #    （R/nodes.R:12-24 那条策略，别在这张卡上开口子）。
    #
    # ⚠️ 「允许同步建号」是这一页**最危险的一个开关**，所以它旁边必须写清楚
    #    开着的代价。开了之后任何能往收件箱里放一个 JSON 的人，就能给任意
    #    邮箱建一个"他自己知道密码"的账号。默认关（见 R/syncservers.R）。
    syncjump = card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("tower-broadcast"), " 信息同步跳板"),
        actionButton(ns("sj_refresh"), NULL, icon = icon("rotate"),
                     class = "btn-sm btn-outline-secondary", title = "重新读取")
      ),
      card_body(
        fillable = FALSE,
        p(class = "small text-muted",
          "「跳板」是一台可以当中转的服务器：本机把对话和账号推到它的",
          tags$code("data/sync/"), " 目录下，别的机器再去那儿取。",
          "这里登记的是**地址**；SSH 用户名和密码由用的人在设置页自己填，",
          "不落库、不落盘。"),
        # ⚠️ 这个 uiOutput 的 id 必须和里面那个 checkboxInput 的 id **不一样**。
        #    uiOutput 自己会渲染成 `<div id="htadmin-sj_allow">`，里面的
        #    checkboxInput(ns("sj_allow")) 又渲染成 `<input id="htadmin-sj_allow">`
        #    —— 同一个 id 出现两次（非法 HTML）。今天看着没事（input 那条路
        #    仍然绑得上），但**按 id 找元素从此就有歧义**：Shiny 的
        #    updateCheckboxInput 走 document.getElementById，拿到的是**外层那个
        #    div**，它身上没有 input binding，于是更新静默失效（不报错）。
        #    探针里 `locator("#htadmin-sj_allow")` 也会直接报 strict mode 冲突。
        #    所以外层叫 _ui，里面那个仍然叫 sj_allow（input$sj_allow 不变）。
        uiOutput(ns("sj_allow_ui")),
        hr(),
        uiOutput(ns("sj_list")),
        div(class = "d-flex gap-2 flex-wrap align-items-center mt-2",
          actionButton(ns("sj_add"), "新增跳板",
                       class = "btn-sm btn-primary", icon = icon("plus")),
          actionButton(ns("sj_edit"), "修改",
                       class = "btn-sm btn-outline-primary", icon = icon("pen")),
          actionButton(ns("sj_default"), "设为默认",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("star")),
          actionButton(ns("sj_toggle"), "启用 / 停用",
                       class = "btn-sm btn-outline-warning", icon = icon("ban")),
          actionButton(ns("sj_del"), "删除",
                       class = "btn-sm btn-outline-danger", icon = icon("trash"))
        ),
        uiOutput(ns("sj_msg")),
        hr(),
        uiOutput(ns("sj_claimed"))
      )
    )
  )
}

mod_htadmin_server <- function(id, state, engine = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    refresh <- reactiveVal(0)
    msg <- reactiveVal(NULL)

    # 当前操作者的**实时**身份行。
    #
    # ⚠️ 不用 state$user（登录那一刻的快照）。这一页能做「把某人提升为
    #    平台管理员」，而一个刚被降级的人在他那个开着的标签页里，用快照
    #    身份还能继续提人 —— 直到他刷新。判权限的东西一律现读库。
    me <- reactive({
      id <- state$user_id
      if (is.null(id) || length(id) != 1 || is.na(id)) return(NULL)
      tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)), error = function(e) NULL)
    })

    is_platform <- reactive({ dsapp_user_is_platform_admin(me()) })

    # 唯一的门。所有写操作第一句都是它。挡下来的时候**不解释为什么** ——
    # 这一页本来就只该平台管理员看到，说多了等于确认"这个入口是存在的"。
    deny <- function() {
      msg(div(class = "alert alert-warning py-2 px-3 mt-3 mb-0 small",
              "这一页只有平台管理员能操作。"))
      FALSE
    }
    guard <- function() {
      if (isTRUE(is_platform())) return(TRUE)
      deny()
      FALSE
    }

    note <- function(text, type = "message") {
      msg(div(class = paste0("alert alert-", type, " py-2 px-3 mt-3 mb-0 small"),
              text))
    }

    audit <- function(action, target = "", detail = "", ok = TRUE) {
      dsapp_audit(action, user = me(), user_id = state$user_id,
                  target = target, detail = detail, ok = ok,
                  session = session, cfg = cfg)
    }

    # ---- 取数 ----
    days <- reactive({
      d <- suppressWarnings(as.integer(input$days %||% 30))
      if (length(d) != 1L || is.na(d) || d <= 0) 30L else d
    })

    # ★ V13.10 item 1：这里原来是 `tryCatch(..., error = function(e) NULL)` ——
    #   错误吞得干干净净，界面上表现为"这张表没有符合条件的账号"，看起来像
    #   筛选筛空了，谁也不知道真出过错。改成 dsapp_err_try：返回值不变
    #   （还是 NULL，下面照样走空态），但**错误和调用栈进 data/logs/app_error.log**。
    #   用户报"后台页面出错了"的时候，日志里得有个东西可以对。
    act <- reactive({
      refresh()
      dsapp_err_try(dsapp_user_activity(days(), con = dsapp_db(cfg)),
                    where = "htadmin$act", on_error = NULL)
    })

    # V13.10 item 1：筛选这一段也兜住。它读的是 df 的列（nickname / email /
    # status / admin_scope），而 df 是 dsapp_user_activity() 现查出来的 ——
    # 表结构一变（比如某次迁移少了一列），这里就是 "argument 'x' is missing"
    # 这种看不出所以然的错，而它是在 renderDataTable 里抛的，表现是整张表
    # 变成一片红字。兜住之后至少日志里有完整调用栈。
    rows <- reactive({
      dsapp_err_try(local({
      df <- act()
      if (is.null(df)) return(NULL)
      kw <- trimws(input$kw %||% "")
      if (nzchar(kw)) {
        hit <- grepl(kw, df$nickname, fixed = TRUE, ignore.case = TRUE) |
               grepl(kw, df$email, fixed = TRUE, ignore.case = TRUE)
        df <- df[hit, , drop = FALSE]
      }
      fs <- as.character(input$f_scope %||% "")
      if (nzchar(fs)) {
        sc <- vapply(seq_len(nrow(df)), function(i)
          dsapp_user_admin_scope(as.list(df[i, , drop = FALSE])), character(1))
        df <- df[if (fs == "user") sc == "" else sc == fs, , drop = FALSE]
      }
      ft <- as.character(input$f_status %||% "")
      if (nzchar(ft)) df <- df[as.character(df$status) == ft, , drop = FALSE]
      df
      }), where = "htadmin$rows", on_error = NULL)
    })

    output$overview <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      df <- act()
      if (is.null(df) || nrow(df) == 0) {
        return(p(class = "text-muted small mb-0", "还没有账号。"))
      }
      n_scope <- function(s) {
        sum(vapply(seq_len(nrow(df)), function(i)
          identical(dsapp_user_admin_scope(as.list(df[i, , drop = FALSE])), s),
          logical(1)))
      }
      n_on   <- sum(as.character(df$status) == "active")
      n_act  <- sum(as.numeric(df$n_act) > 0)
      never  <- sum(as.numeric(df$n_act) == 0 & as.numeric(df$n_chat) == 0)

      kv <- function(label, value, note = NULL) {
        div(class = "d-flex justify-content-between border-bottom py-1",
          span(class = "text-muted small", label),
          span(tags$b(value),
               if (!is.null(note)) span(class = "text-muted small ms-2", note)))
      }
      tagList(
        layout_columns(
          col_widths = c(6, 6),
          div(
            kv("账号总数", sprintf("%d 个", nrow(df)),
               sprintf("启用 %d · 停用 %d", n_on, nrow(df) - n_on)),
            kv("平台管理员", sprintf("%d 个", n_scope("platform"))),
            kv("项目管理员", sprintf("%d 个", n_scope("project"))),
            kv("普通用户", sprintf("%d 个", n_scope("")))
          ),
          div(
            kv(sprintf("近 %d 天动过", days()), sprintf("%d 个", n_act),
               sprintf("占 %.0f%%", 100 * n_act / max(1, nrow(df)))),
            kv("一次都没用过", sprintf("%d 个", never),
               "注册了但没建过对话、也没有任何操作记录"),
            kv("累计对话", format(sum(as.numeric(df$n_chat)), big.mark = ",")),
            kv("累计任务", format(sum(as.numeric(df$n_task)), big.mark = ","))
          )
        ),
        p(class = "small text-muted mb-0 mt-2",
          icon("circle-info"), " ",
          dsapp_md_inline("「近 N 天动过」数的是**操作日志**里有过记录的账号 ——"),
          "只登录不说话也算动过。改窗口在下面那张表的筛选条上。")
      )
    })

    output$count <- renderUI({
      n <- nrow(rows() %||% data.frame())
      total <- nrow(act() %||% data.frame())
      div(class = "small text-muted mb-1",
        if (n == total) sprintf("共 %d 个账号", total)
        else sprintf("筛出 %d 个（共 %d 个）", n, total))
    })

    output$tbl <- DT::renderDataTable({
      df <- rows()
      if (is.null(df) || nrow(df) == 0) {
        return(DT::datatable(data.frame(提示 = "没有符合条件的账号"),
                             options = list(dom = "t"), rownames = FALSE))
      }
      scope_lab <- vapply(seq_len(nrow(df)), function(i)
        dsapp_admin_scope_label(
          dsapp_user_admin_scope(as.list(df[i, , drop = FALSE]))), character(1))

      # 「近 N 天」这一列**没动过的写「—」不写 0**。写 0 的话，"注册完
      # 从没来过"和"来过但只是登录了一下"在表上长得一样，而前者才是要清理的。
      touch <- ifelse(as.numeric(df$n_act) > 0,
                      sprintf("%d 次", as.integer(df$n_act)), "—")

      show <- data.frame(
        id      = df$id,
        nickname = df$nickname,
        email   = df$email,
        role    = scope_lab,
        status  = ifelse(as.character(df$status) == "active", "启用", "停用"),
        touch   = touch,
        login   = as.integer(df$n_login),
        # ★★★ V16.6：`USE.NAMES = FALSE` 是**必需的**，不是风格问题。
        #   vapply() 默认 USE.NAMES = TRUE，规则是「X 是 character 且结果还
        #   没名字 → 把 **X 的值本身**当结果的名字」（给 sapply 准备的行为）。
        #   这里的 X 是 df$last_act，而 `last_act` 是 `MAX(audit_log.at)`
        #   —— **一次都没动过的账号是 NA**。于是「筛出来的那个人恰好没动过」
        #   → names(last) == NA_character_ → data.frame() 报
        #   `row names contain missing values` → 整个 output$tbl 抛错。
        #   界面上看到的不是红字，是**这张表直接消失**（htmlwidgets 的错误
        #   处理是 el.style.visibility = "hidden"，旧 DOM 原样留着），
        #   而错误只进 data/logs/app_error.log。
        #   ⚠️ 触发条件是「筛完**只剩一行**」且那一行 last_act 是 NA —— 正好是
        #      「找出那个从没来过的号、把它删掉」这个最常用的操作。长度 ≥ 2 时
        #      USE.NAMES 不生效（R 只在 length(X) == 1 时走那一支），所以手工
        #      试很容易试不出来。V16.6 的浏览器探针就是这么撞上的；逐版回看，
        #      V16.1 起每一版的 mod_htadmin.R 都是这个写法（老 bug，本版修）。
        last    = vapply(df$last_act, dsapp_fmt_time, character(1),
                         USE.NAMES = FALSE),
        seen    = vapply(df$last_seen_at, dsapp_fmt_time, character(1),
                         USE.NAMES = FALSE),
        chat    = as.integer(df$n_chat),
        task    = as.integer(df$n_task),
        tokens  = format(round(as.numeric(df$tokens)), big.mark = ","),
        stringsAsFactors = FALSE
      )
      DT::datatable(
        show,
        colnames = c("ID", "昵称", "邮箱", "级别", "状态",
                     sprintf("近 %d 天动作", days()), "登录次数",
                     "最后动作", "最后在线", "对话", "任务", "tokens"),
        selection = "single", rownames = FALSE,
        # V13.10 item 3：配合上面那层 .dsapp-dt-nowrap（见 R/mod_admin.R 里
        # 同一处的注释）。
        options = list(dom = "tp", pageLength = 15, ordering = FALSE,
                       autoWidth = FALSE,
                       columnDefs = list(list(className = "dt-left",
                                              targets = "_all")))
      )
    })

    selected <- reactive({
      i <- input$tbl_rows_selected
      df <- rows()
      if (is.null(df) || is.null(i) || length(i) == 0 || i > nrow(df)) return(NULL)
      as.integer(df$id[i])
    })

    # 选中那一行的完整信息（要拿 email 做日志、拿 nickname 做提示）。
    # 从库里现读而不是从 rows() 里取：表格可能已经因为筛选变化重渲染过，
    # 而 selected() 拿的是**更新后**的行号 —— 两个对不上的时候，从 rows()
    # 取会拿到另一个账号的名字，而操作作用在 selected() 那个 id 上。
    sel_user <- reactive({
      id <- selected()
      if (is.null(id)) return(NULL)
      tryCatch(dsapp_user_by_id(id, con = dsapp_db(cfg)), error = function(e) NULL)
    })

    output$action_msg <- renderUI(msg())

    observeEvent(input$refresh, { msg(NULL); refresh(refresh() + 1) })
    observeEvent(input$clear, {
      updateTextInput(session, "kw", value = "")
      updateSelectInput(session, "f_scope", selected = "")
      updateSelectInput(session, "f_status", selected = "")
    })

    # ---- 添加用户 ----
    observeEvent(input$add, {
      if (!guard()) return()
      showModal(modalDialog(
        title = "添加用户",
        textInput(ns("new_nick"), "昵称"),
        textInput(ns("new_email"), "登录邮箱"),
        passwordInput(ns("new_pw"), "初始密码",
                      placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
        selectInput(ns("new_scope"), "权限级别", width = "100%",
                    selectize = FALSE,
                    choices = c("普通用户" = "", "项目管理员" = "project",
                                "平台管理员" = "platform")),
        textInput(ns("new_field"), "研究方向（可不填）"),
        helpText(class = "small text-muted",
          "把这个邮箱和密码告诉本人，他自己登录。",
          tags$br(),
          dsapp_md_inline("**平台管理员**能改、加、删全平台的账号和任务；"),
          dsapp_md_inline("**项目管理员**只看得到自己分发出去的任务和组内的账号成员。"),
          tags$br(),
          "级别之后随时可以在这一页改。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_add"), "创建", class = "btn-primary")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_add, {
      removeModal()
      if (!guard()) return()
      # ⚠️ 这里**没有**选行的概念 —— 新建的账号还不存在。所以不能走
      #    selected() 那一套，参数全部来自弹窗里的输入。
      r <- tryCatch(
        dsapp_user_create(input$new_nick %||% "", input$new_email %||% "",
                          phone = "", field = input$new_field %||% "",
                          password = input$new_pw %||% "",
                          con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))

      # 级别：dsapp_user_create 只会给出 "platform"（第一个账号 / 白名单）
      # 或者 ""，所以这里要按弹窗里选的再设一次。
      #
      # ⚠️ `by` 一定要传 —— 不传的话 dsapp_user_set_admin 那道"不能改自己"
      #    的自锁就失效了（它靠 by 判断）。这里传的是**新账号的 id 之外**的
      #    操作者，正常；但少了这个参数，将来有人把这段抄到别处就会静默
      #    少一道闸。
      sc <- as.character(input$new_scope %||% "")
      if (nzchar(sc)) {
        sr <- tryCatch(dsapp_user_set_admin(r$user$id, sc, con = dsapp_db(cfg),
                                            by = state$user_id),
                       error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
        if (!isTRUE(sr$ok)) {
          note(sprintf("账号建好了（%s），但级别没设上：%s。在这一页找到他再改一次就行。",
                       r$user$email %||% "", sr$msg), "warning")
          refresh(refresh() + 1)
          return(invisible(NULL))
        }
      }
      audit("admin_add", target = as.character(r$user$email %||% ""),
            detail = sprintf("%s · %s", r$user$nickname %||% "",
                             dsapp_admin_scope_label(sc)))
      note(sprintf("已创建 %s <%s>，级别：%s。把密码告诉他就能登录了。",
                   r$user$nickname %||% "", r$user$email %||% "",
                   dsapp_admin_scope_label(sc)), "success")
      refresh(refresh() + 1)
    })

    # ---- 改权限 ----
    observeEvent(input$set_scope, {
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(note("先在表里选一个账号。", "warning"))
      cur <- dsapp_user_admin_scope(u)
      # 自己那一行：允许看、不允许改（dsapp_user_set_admin 会拦，这里先把
      # 话说明白，省得他点完保存才被拒）。
      showModal(modalDialog(
        title = sprintf("更改 %s 的权限级别", u$nickname),
        helpText(class = "small text-muted",
          "现在的级别：", tags$b(dsapp_admin_scope_label(cur)), "。"),
        selectInput(ns("scope_sel"), "改成", width = "100%", selectize = FALSE,
                    choices = c("普通用户" = "", "项目管理员" = "project",
                                "平台管理员" = "platform"),
                    selected = cur),
        # ⚠️ V15.5 item 3：这里的重点原来写成 `**所有**` 这种 —— helpText()
        #    里的字符串是**纯文本**，星号会原样显示。粗体一律用 tags$b()。
        #    （同一类错在 mod_lit.R 的「定时订阅」卡片里也有一份，一起修的。）
        helpText(class = "small text-muted",
          tags$b("平台管理员"), "：可查看、更改、添加、删除平台内",
          tags$b("所有"), "的账号与任务。",
          tags$br(),
          tags$b("项目管理员"), "：只能查看并更改", tags$b("自己分发出去的任务"),
          "和", tags$b("自己建的组里的账号成员"), " —— 进管理页看不到别人的账号，",
          "也删不掉账号（删号只由平台管理员做）。",
          tags$br(),
          tags$b("普通用户"), "：只有自己的对话、文件和任务。",
          tags$br(),
          icon("triangle-exclamation"),
          " 级别是", tags$b("立刻生效"), "的，但对方那个已经开着的标签页要刷新之后才换。",
          "两个自锁挡在这里：不能改自己的级别，也不能把最后一个平台管理员降下去 ——",
          "否则这一页从此没人进得来。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_scope"), "保存", class = "btn-primary")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_scope, {
      removeModal()
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(invisible(NULL))
      old <- dsapp_user_admin_scope(u)
      r <- tryCatch(
        dsapp_user_set_admin(u$id, as.character(input$scope_sel %||% ""),
                             con = dsapp_db(cfg), by = state$user_id),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_scope", target = as.character(u$email %||% ""),
            detail = sprintf("%s → %s", dsapp_admin_scope_label(old),
                             dsapp_admin_scope_label(input$scope_sel %||% "")),
            ok = isTRUE(r$ok))
      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))
      note(sprintf("%s 的级别：%s", u$nickname, r$msg), "success")
      refresh(refresh() + 1)
    })

    # ---- 停用 / 启用 ----
    observeEvent(input$toggle, {
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(note("先在表里选一个账号。", "warning"))
      if (identical(as.integer(u$id), as.integer(state$user_id))) {
        return(note("不能停用你自己。", "warning"))
      }
      new_status <- if (identical(as.character(u$status), "active"))
        "disabled" else "active"
      try(dsapp_user_set_status(u$id, new_status, con = dsapp_db(cfg)),
          silent = TRUE)
      audit("admin_status", target = as.character(u$email %||% ""),
            detail = if (identical(new_status, "disabled")) "停用" else "启用")
      note(sprintf("%s 已%s。", u$nickname,
                   if (identical(new_status, "disabled")) "停用" else "启用"),
           "success")
      refresh(refresh() + 1)
    })

    # ---- 重置密码 ----
    observeEvent(input$reset_pw, {
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(note("先在表里选一个账号。", "warning"))
      showModal(modalDialog(
        title = sprintf("重置 %s 的密码", u$nickname),
        passwordInput(ns("new_pw2"), "临时密码",
                      placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
        helpText(class = "small text-muted",
          "把这个密码告诉本人。他下次登录时会被要求改成自己的 —— ",
          tags$b("这个临时密码只能用来登录一次。"),
          tags$br(), "原来那个密码立刻失效。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_reset_pw"), "重置", class = "btn-primary")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_reset_pw, {
      removeModal()
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(invisible(NULL))
      r <- tryCatch(
        dsapp_user_admin_reset_password(u$id, input$new_pw2 %||% "",
                                        con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("pw_admin_reset", target = as.character(u$email %||% ""),
            detail = "临时密码，登录后必须改", ok = isTRUE(r$ok))
      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))
      note(r$msg, "success")
      refresh(refresh() + 1)
    })

    # ---- 删除用户 ----
    observeEvent(input$del, {
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(note("先在表里选一个账号。", "warning"))
      if (identical(as.integer(u$id), as.integer(state$user_id))) {
        return(note("不能删除你自己。", "warning"))
      }
      # 删掉最后一个平台管理员 = 这一页从此没人进得来。dsapp_user_set_admin
      # 挡住了"降级"，但删号走的是另一条路（dsapp_user_delete 直接删行），
      # 所以这里得再判一次 —— 两处漏一处，平台就锁死了。
      if (identical(dsapp_user_admin_scope(u), "platform")) {
        n <- tryCatch(DBI::dbGetQuery(dsapp_db(cfg),
               "SELECT COUNT(*) AS n FROM users
                 WHERE is_admin = 1 AND id <> ?",
               params = list(as.integer(u$id)))$n[[1]],
               error = function(e) 0L)
        if (!isTRUE(as.integer(n) >= 1L)) {
          return(note("这是最后一个平台管理员了，不能删 —— 删完谁都进不来这一页。",
                      "warning"))
        }
      }
      showModal(modalDialog(
        title = "确认删除用户",
        # ★★ V16.6 item 3：文案必须和代码同款。改前这里写的是「他上传到共享区
        #    的文件不会被删除…会变成公共文件」—— 老行为，正好是用户这次要求
        #    反过来做的那件事。承诺和实际相反，而且两边都不报错。
        sprintf("将删除 %s（%s）及其 %d 个对话、这些对话的工作区和环境。",
                u$nickname, u$email, u$n_chat %||% 0L),
        tags$br(),
        tags$b("他的文件管理区（data/files/ 下那一整个目录）也会一并删除。"),
        tags$br(),
        tags$b("这个动作不可逆。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("confirm_del"), "确认删除", class = "btn-danger")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$confirm_del, {
      removeModal()
      if (!guard()) return()
      u <- sel_user()
      if (is.null(u)) return(invisible(NULL))
      # 身份要在**删之前**取好：删完 dsapp_user_by_id 就查不到了，而这条
      # 日志恰恰是最需要留下的那种（见 R/audit.R 顶部第 3 条）。
      n <- tryCatch(dsapp_user_delete(u$id, cfg, con = dsapp_db(cfg)),
                    error = function(e) {
                      note(dsapp_err_user(e, "删除这个账号",
                                          hint = "账号还在，没有被删掉一半。"),
                           "danger")
                      NULL
                    })
      audit("admin_delete", target = as.character(u$email %||% ""),
            detail = sprintf("%s · %s 个对话", as.character(u$nickname %||% ""),
                             if (is.null(n)) "?" else n),
            ok = !is.null(n))
      if (!is.null(n)) {
        rg <- attr(n, "purged")   # ★ V16.6 item 3：文件也算一份，见 mod_admin.R
        note(sprintf("已删除 %s：%d 个对话%s。", u$nickname, n,
                     if (is.null(rg)) "" else sprintf("、%d 个文件（管理区目录已整个删除）",
                                                      rg[["files_dir"]])),
             "success")
      }
      refresh(refresh() + 1)
    })

    # ---- 硬件资源限制 ----
    #
    # 用 renderUI 跟着选中行重画，而不是给一个 selectInput 再配一堆
    # updateNumericInput：后者要处理"选中的账号变了但输入框里还是上一个人的
    # 数字"这个经典 bug（`updateNumericInput` 只更新值，用户已经手动改过的
    # 那个数字在更新到达之前一直显示着）。重画整块没有这个问题。
    output$limits <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      u <- sel_user()
      if (is.null(u)) {
        return(p(class = "text-muted small mb-0",
                 "在上面选一个账号，这里就能给他单独分配 CPU / 内存 / 进程数。"))
      }
      cur  <- dsapp_user_limits(u$id, con = dsapp_db(cfg))
      dflt <- dsapp_limits_for_user(NULL, cfg = cfg, con = dsapp_db(cfg))
      # 「实际生效」是配额和平台默认合成之后的那一份 —— 执行链路读的就是它
      # （dsapp_limits_for_user）。只显示账号自己的那三列的话，一个没设过
      # 限额的账号看起来像"没有上限"，而他实际上受平台默认值约束。
      eff  <- dsapp_limits_for_user(u$id, cfg = cfg, con = dsapp_db(cfg))
      # GPU 是**三态**（TRUE / FALSE / NA），和上面那三列的"空 = 默认"不是
      # 一回事，所以它不在 cur 里，得单独取一次。取一次就够，别在下面两处
      # 各查一遍库。
      cg   <- dsapp_user_gpu_enabled(u$id, con = dsapp_db(cfg))
      # ★ V15.6 item 14：哨兵（负数）= 不限制，见 users.R 的
      #   DSAPP_LIMIT_UNLIMITED。这里三件事都要认它：
      #     ① "当前生效"那一行的 %g / as.integer 会把 -1 原样打印出来；
      #     ② 输入框里要塞 NA，不能塞 -1（min=60 的数字框显示 -1 会立刻
      #        被浏览器判非法，管理员看到的是一个红框）；
      #     ③ 勾选框的初值看这三项里有没有哨兵。
      cur_unlim <- dsapp_limit_is_unlimited(cur$cpu_sec) ||
                   dsapp_limit_is_unlimited(cur$mem_mb) ||
                   dsapp_limit_is_unlimited(cur$max_procs)
      eff_txt <- function(v, fmt) {
        if (dsapp_limit_is_unlimited(v)) return("不限")
        if (!is.finite(suppressWarnings(as.numeric(v %||% NA_real_))[1]))
          return("不限")
        fmt(v)
      }
      tagList(
        div(class = "small text-muted mb-2",
          "当前生效：", tags$b(sprintf("%s CPU · %s 内存 · %s 进程",
                                      eff_txt(eff$cpu_sec, function(v)
                                        sprintf("%g 秒", v)),
                                      eff_txt(eff$mem_mb, function(v)
                                        dsapp_fmt_bytes(v * 1024 * 1024)),
                                      eff_txt(eff$max_procs, function(v)
                                        sprintf("%d 个", as.integer(v))))),
          "（", if (all(vapply(cur, is.null, logical(1)))) "全部跟着平台默认"
               else "其中带 ★ 的是单独给他设的", "）"),
        checkboxInput(ns("lim_unlimited"),
          HTML("<b>不限制</b>（CPU 时间 / 内存 / 进程数都不设上限）"),
          value = cur_unlim),
        layout_columns(
          col_widths = c(4, 4, 4),
          numericInput(ns("lim_cpu"), sprintf("CPU 时间上限（秒）%s",
                        if (is.null(cur$cpu_sec)) "" else "★"),
                       value = if (is.null(cur$cpu_sec) ||
                                   dsapp_limit_is_unlimited(cur$cpu_sec)) NA
                               else cur$cpu_sec,
                       min = 60, max = 86400, step = 60),
          numericInput(ns("lim_mem"), sprintf("内存上限（MB）%s",
                        if (is.null(cur$mem_mb)) "" else "★"),
                       value = if (is.null(cur$mem_mb) ||
                                   dsapp_limit_is_unlimited(cur$mem_mb)) NA
                               else cur$mem_mb,
                       min = 256, max = 4 * 1024 * 1024, step = 256),
          numericInput(ns("lim_procs"), sprintf("最大进程数%s",
                        if (is.null(cur$max_procs)) "" else "★"),
                       value = if (is.null(cur$max_procs) ||
                                   dsapp_limit_is_unlimited(cur$max_procs)) NA
                               else cur$max_procs,
                       min = 16, max = 65536, step = 8)
        ),

        # ★ V14 item 7：GPU 开关。
        #
        # ⚠️ 单独一行三选一，和上面那三个数值框**不是同一类东西**：那三项
        #    决定"他这一次能吃多少机器"，这一项决定"他能不能碰那张卡"。
        #    存储上更是完全分开的 —— 上面三列是 NULL = 跟平台默认，而
        #    gpu_enabled 的 NULL 也是"跟平台默认"，但 0 是**明确禁止**
        #    （不是"没设"），所以它没进 dsapp_user_limits() 那套 num() 归一化
        #    （见 users.R）。用一个能填 0 的数值框来表达它，一定会出事。
        #
        # ⚠️ 取值 "default"/"allow"/"deny" 三个字符串，理由同 mod_admin.R。
        div(class = "mt-2",
          radioButtons(ns("lim_gpu"),
            sprintf("GPU 使用权限%s", if (is.na(cg)) "" else "★"),
            choices = c("跟着平台默认" = "default",
                        "允许使用 GPU" = "allow",
                        "禁止使用 GPU" = "deny"),
            selected = if (is.na(cg)) "default" else if (cg) "allow" else "deny",
            inline = TRUE)
        ),
        div(class = "d-flex gap-2 align-items-center flex-wrap",
          actionButton(ns("save_limits"), "保存",
                       class = "btn-sm btn-primary", icon = icon("floppy-disk")),
          actionButton(ns("clear_limits"), "恢复平台默认",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("rotate-left")),
          span(class = "small text-muted",
               dsapp_md_inline("留空 / 填 0 也是**恢复平台默认**；勾「不限制」则三项全放开，数字框的内容会被忽略。")),
          span(class = "small text-muted",
               sprintf("平台默认：%g 秒 · %s · %d 进程 · GPU %s",
                       dflt$cpu_sec,
                       dsapp_fmt_bytes(dflt$mem_mb * 1024 * 1024),
                       as.integer(dflt$max_procs),
                       if (isTRUE(dflt$gpu)) "允许" else "禁止"))
        ),
        p(class = "small text-muted mb-0 mt-2",
          icon("triangle-exclamation"), " 前三项作用于他的**单个任务**。",
          "内存给小了，单细胞那种任务会被系统直接杀掉（报 OOM，不是报错退出）。",
          "调大也不保证一定给得到 —— 机器本身的内存是硬上限。",
          tags$br(),
          {
            hg <- dsapp_host_gpu()
            if (isTRUE(hg$ok)) {
              tagList("GPU：", hg$detail, "。禁止之后他的代码看不到任何显卡",
                      "（CUDA_VISIBLE_DEVICES 等置空），需要 GPU 的库会回落到 CPU。")
            } else {
              tagList("GPU：", tags$b(hg$detail), " —— 现在开这个开关",
                      tags$b("不会产生任何可观察的差别"), "，它是给以后挂了卡准备的。")
            }
          },
          "开关只管本机执行；他配了「远程服务器」的话，代码在他自己机器上跑。")
      )
    })

    # 保存 / 恢复默认走同一条路。`use_inputs = FALSE` 时三个值全传 NULL，
    # 而 dsapp_user_set_limits 把 NULL 当"恢复平台默认"（见它的说明）。
    save_limits <- function(use_inputs) {
      if (!guard()) return(invisible(NULL))
      u <- sel_user()
      if (is.null(u)) return(note("先在表里选一个账号。", "warning"))
      # numericInput 被清空时 input 是 NA（不是 NULL）—— 两个都要当成
      # "恢复默认"。`%||%` 只挡 NULL，所以这里自己写一个。
      g <- function(x) if (is.null(x) || length(x) == 0 || is.na(x)) NULL else x
      # ★ V15.6 item 14：勾了「不限制」就三项一起写哨兵，数字框一律忽略
      #   （口径和 mod_admin.R 那边**必须**一致，两个入口同一件事不能有两种
      #   结果）。「恢复平台默认」那颗按钮优先级更高：它是"全部撤销"。
      unlim_sel <- isTRUE(use_inputs) && isTRUE(input$lim_unlimited)
      lv <- function(x) if (unlim_sel) DSAPP_LIMIT_UNLIMITED else g(x)
      vals <- if (use_inputs) {
        list(cpu = lv(input$lim_cpu), mem = lv(input$lim_mem),
             procs = lv(input$lim_procs))
      } else {
        list(cpu = NULL, mem = NULL, procs = NULL)
      }
      r <- tryCatch(
        dsapp_user_set_limits(u$id, cpu_sec = vals$cpu, mem_mb = vals$mem,
                              max_procs = vals$procs, con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_limits", target = as.character(u$email %||% ""),
            detail = if (unlim_sel) "不限制"
                     else sprintf("cpu=%s mem=%s procs=%s",
                                  vals$cpu %||% "默认", vals$mem %||% "默认",
                                  vals$procs %||% "默认"),
            ok = isTRUE(r$ok))

      # ---- GPU 开关（V14 item 7）----
      #
      # 单独一条审计、单独一次写入。`use_inputs = FALSE`（「恢复平台默认」
      # 那颗按钮）时 GPU 也一并清回 NULL —— 那颗按钮的语义是"这个人身上
      # 所有单独设过的东西全部撤销"，漏掉 GPU 的话按了没反应，而按钮上
      # 写着"恢复平台默认"。
      #
      # ⚠️ 清空必须走 dsapp_user_clear_gpu()：dsapp_user_set_gpu() 收的是
      #    布尔，NULL 进去 = "禁止"，正好反了（见 users.R 那边的注释）。
      gpu_sel <- if (use_inputs) as.character(input$lim_gpu %||% "default")[1]
                 else "default"
      gr <- tryCatch(
        switch(gpu_sel,
          allow = dsapp_user_set_gpu(u$id, TRUE,  con = dsapp_db(cfg)),
          deny  = dsapp_user_set_gpu(u$id, FALSE, con = dsapp_db(cfg)),
          dsapp_user_clear_gpu(u$id, con = dsapp_db(cfg))
        ),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      audit("admin_gpu", target = as.character(u$email %||% ""),
            detail = switch(gpu_sel, allow = "允许", deny = "禁止", "恢复平台默认"),
            ok = isTRUE(gr$ok))

      if (!isTRUE(r$ok)) return(note(r$msg, "danger"))
      note(sprintf("%s 的资源上限已更新（空的项走平台默认）；GPU %s。", u$nickname,
                   if (!isTRUE(gr$ok)) "没改成"
                   else switch(gpu_sel, allow = "已允许", deny = "已禁止",
                               "恢复平台默认")),
           "success")
      refresh(refresh() + 1)
    }

    observeEvent(input$save_limits, save_limits(TRUE))
    observeEvent(input$clear_limits, save_limits(FALSE))

    # ---- 应用报错日志（V13.10 item 1）-------------------------------------
    err_refresh <- reactiveVal(0)
    observeEvent(input$err_refresh, err_refresh(err_refresh() + 1L))

    output$err_log <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      err_refresh()
      # ⚠️ 读文件这一步本身也可能失败（文件不在、权限不对），而这一卡就是
      #    用来展示失败的 —— 它自己再抛一个就等于没有。所以失败要说出来，
      #    不能静默成空。
      got <- tryCatch(list(ok = TRUE, txt = dsapp_err_recent(5L, cfg = cfg)),
                      error = function(e) list(ok = FALSE,
                                               msg = conditionMessage(e)))
      if (!isTRUE(got$ok)) {
        return(p(class = "small text-muted mb-0",
                 "日志读不出来：", tags$code(got$msg)))
      }
      txt <- got$txt
      if (length(txt) == 0) {
        return(p(class = "small text-muted mb-0",
                 icon("circle-check"), " 暂时没有记录到的报错。"))
      }
      tags$div(
        p(class = "small text-muted mb-1",
          sprintf("最近 %d 条（新的在下面）：", min(5L, length(txt)))),
        tags$pre(class = "dsapp-err-log",
                 paste(utils::tail(txt, 200), collapse = "\n"))
      )
    })

    # ---- 信息同步跳板（V16.6 item 1）---------------------------------------
    #
    # 三块：① 允许同步建号的开关 ② 清单的增删改 ③ 已经建出来的账号。
    # 全部走 guard()（平台管理员），和这一页其余部分同一道门。
    sj_rev <- reactiveVal(0)     # 清单变了就 +1，触发重画
    sj_msg <- reactiveVal(NULL)  # 这张卡自己的提示条（不跟上面那张卡混）

    sj_note <- function(text, type = "message") {
      sj_msg(div(class = paste0("alert alert-", type,
                                " py-2 px-3 mt-2 mb-0 small"), text))
    }

    sj_list <- reactive({
      sj_rev()
      dsapp_err_try(dsapp_syncservers_list(cfg = cfg, con = dsapp_db(cfg)),
                    where = "htadmin$sj_list", on_error = NULL)
    })

    # 选中的那一条。用 selectInput 而不是 DT 的行选中：这张表最多十几行，
    # 而 DT 的 select 模式要额外处理"重画之后选中丢失"（筛选一变 selection
    # 就回 NULL），管理页那边为此写过一段。这里不值得。
    sj_sel <- reactive({
      id <- suppressWarnings(as.integer(input$sj_sel %||% NA))
      if (is.na(id)) return(NULL)
      dsapp_syncserver_get(id, cfg = cfg, con = dsapp_db(cfg))
    })

    observeEvent(input$sj_refresh, sj_rev(sj_rev() + 1L))

    # ---- ① 允许同步建号 ----
    #
    # ⚠️ `ignoreInit = TRUE` 是必须的：没有它，这一页**每次打开**都会拿
    #    画出来的值（FALSE）去写一遍库 —— 而那个值不一定是库里的值
    #    （环境变量锁着的时候画出来的是锁定态）。表现是"我明明开着，
    #    打开后台看一眼就变成关的了"。observeEvent 默认 ignoreInit = FALSE。
    observeEvent(input$sj_allow, {
      if (!guard()) return()
      if (dsapp_sync_allow_create_locked()) {
        return(sj_note(paste0("这个开关被环境变量 DSAPP_SYNC_ALLOW_CREATE ",
                              "钉住了，改这里不会生效。"), "warning"))
      }
      v <- if (isTRUE(input$sj_allow)) "1" else "0"
      dsapp_setting_set(DSAPP_SETTING_SYNC_ALLOW_CREATE, v,
                        user_id = state$user_id, cfg = cfg,
                        con = dsapp_db(cfg))
      audit("sync.allow_create", target = "同步建号",
            detail = if (v == "1") "on" else "off")
      sj_note(if (v == "1")
        "已允许：桌面版可以把本地注册的账号带上来（每次都会写审计并给该邮箱发信）。"
        else "已关闭：云端不再凭同步包建号。", "success")
      sj_rev(sj_rev() + 1L)
    })

    # ⚠️ 这个名字必须和卡上那个 `uiOutput(ns("sj_allow_ui"))` **逐字相同**。
    #    写成 output$sj_allow 的话，Shiny 不会报错 —— 它只是**不去填那个 div**，
    #    于是卡片画出来了、标题和按钮都在，中间那一块永远是空的。
    #    自检查不出来（renderUI 没有会话就不求值），只有浏览器看得见。
    output$sj_allow_ui <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      sj_rev()
      on  <- isTRUE(dsapp_sync_allow_create(cfg = cfg, con = dsapp_db(cfg)))
      lk  <- dsapp_sync_allow_create_locked()
      env <- trimws(Sys.getenv("DSAPP_SYNC_ALLOW_CREATE", ""))
      div(class = "border rounded p-2",
        div(class = "d-flex align-items-center gap-2",
          div(class = "flex-grow-1",
            tags$b("允许同步建号"),
            div(class = "small text-muted",
              "桌面版/另一台服务器上注册的邮箱，第一次同步时在这儿自动建号，",
              "密码沿用他本地那个。")),
          # 锁定的时候画一颗**禁用**的勾，并把当前值显示出来 ——
          # 画成可点但点了没反应的话，看起来像开关坏了。
          if (lk) span(class = "badge text-bg-secondary", "被环境变量锁定")
          else checkboxInput(ns("sj_allow"), NULL, value = on, width = "auto")
        ),
        if (lk)
          p(class = "small text-muted mb-0 mt-1",
            "环境变量 ", tags$code("DSAPP_SYNC_ALLOW_CREATE"),
            " = ", tags$code(env), "，它盖过这里的设置。"),
        # ★ 这段话是这个开关的**代价**，不是免责声明。删掉它 = 让管理员在
        #   不知道后果的情况下点开它。
        div(class = "small text-muted mt-2",
          icon("triangle-exclamation"), " ",
          "开着的代价：任何能往收件箱里放一个包的人，都能给任意邮箱建一个",
          tags$b("他自己知道密码"), "的账号（抢注）。包里那份口令校验器是",
          "1000 轮 sha256，而密码下限是 ", DSAPP_PW_MIN, " 位 —— ",
          tags$b("对弱口令，拿到校验器等于拿到密码。"),
          "自己给自己当中转可以开；给不特定人群用的服务器请保持关闭。"),
        # ★★ R3（部署后果，必须写在这儿）：同步建出来的号**一律 is_admin=0**，
          #    而本平台"第一个注册的账号自动成为平台管理员"那条规则只在
          #    **网页版注册**那条路上。两件事合起来 = 一台**只**靠同步建号的
          #    服务器会永远没有管理员，而且没有任何界面能补救（进不去后台页）。
          #    这不是 bug，是"不许凭一个同步包提权"的必然代价，所以要写清楚。
        p(class = "small text-muted mb-0 mt-1",
          icon("circle-info"), " ",
          "同步建出来的账号**一律是普通用户**（不许凭一个包提权）。",
          "所以一台机器要有人管，得先在网页版注册第一个账号 —— ",
          tags$b("第一个注册的账号才是平台管理员"), "。")
      )
    })

    # ---- ② 清单 ----
    output$sj_list <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      r <- sj_list()
      if (is.null(r) || !nrow(r)) {
        return(p(class = "text-muted small mb-0",
                 "还没有登记任何跳板。新增一条之后，设置页那边就能直接选它。"))
      }
      ch <- stats::setNames(as.character(r$id), vapply(seq_len(nrow(r)), function(i)
        sprintf("%s  —  %s:%s%s%s", r$name[i], r$host[i], r$port[i],
                if (nzchar(r$remote_dir[i])) paste0("  ", r$remote_dir[i]) else "",
                if (as.integer(r$enabled[i]) == 1L) "" else "  （已停用）"),
        character(1)))
      tagList(
        selectInput(ns("sj_sel"), NULL, width = "100%", choices = ch,
                    selectize = FALSE),
        p(class = "small text-muted mb-0",
          sprintf("共 %d 条。", nrow(r)),
          if (!any(as.integer(r$is_default) == 1L) &&
              any(as.integer(r$enabled) == 1L))
            "（还没有设默认）" else "",
          "远端目录留空表示用默认值 ", tags$code(DSAPP_SYNC_REMOTE_DIR_DEFAULT), "。")
      )
    })

    # 新增 / 修改共用一个弹窗。edit_id = NA 就是新增。
    sj_form <- function(one = NULL) {
      ed <- !is.null(one)
      showModal(modalDialog(
        title = if (ed) sprintf("修改跳板「%s」", one$name) else "新增跳板",
        textInput(ns("sj_f_name"), "名称",
                  value = if (ed) one$name else "",
                  placeholder = "例如：官方中转"),
        textInput(ns("sj_f_host"), "主机地址",
                  value = if (ed) one$host else "",
                  placeholder = "IP 或域名，例如 1.2.3.4"),
        numericInput(ns("sj_f_port"), "SSH 端口",
                     value = if (ed) as.integer(one$port) else 22L,
                     min = 1, max = 65535, step = 1),
        textInput(ns("sj_f_dir"), "远端同步目录",
                  value = if (ed) one$remote_dir else "",
                  placeholder = DSAPP_SYNC_REMOTE_DIR_DEFAULT),
        textInput(ns("sj_f_note"), "备注", value = if (ed) one$note else ""),
        helpText(class = "small text-muted",
          "远端目录是那台服务器上 YCFS_APP 的 data 目录下的 sync 子目录，",
          "也就是它的 .Renviron 里 DSAPP_DATA_ROOT 后面加 /sync。留空用默认值。",
          tags$br(),
          "这里**不要**填 SSH 用户名和密码 —— 那两样由用的人在设置页自己填。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("sj_save"), if (ed) "保存" else "新增",
                       class = "btn-primary")
        )
      ))
    }

    sj_edit_id <- reactiveVal(NA_integer_)

    observeEvent(input$sj_add, {
      if (!guard()) return()
      sj_edit_id(NA_integer_)
      sj_form(NULL)
    })

    observeEvent(input$sj_edit, {
      if (!guard()) return()
      one <- sj_sel()
      if (is.null(one)) return(sj_note("先在上面选一条跳板。", "warning"))
      sj_edit_id(as.integer(one$id))
      sj_form(one)
    })

    observeEvent(input$sj_save, {
      if (!guard()) return()
      id <- sj_edit_id()
      r <- if (is.na(id)) {
        dsapp_syncserver_add(input$sj_f_name %||% "", input$sj_f_host %||% "",
                             input$sj_f_port %||% 22, input$sj_f_dir %||% "",
                             input$sj_f_note %||% "", user = me(),
                             cfg = cfg, con = dsapp_db(cfg))
      } else {
        dsapp_syncserver_update(id, input$sj_f_name %||% "",
                                input$sj_f_host %||% "",
                                input$sj_f_port %||% 22, input$sj_f_dir %||% "",
                                input$sj_f_note %||% "", user = me(),
                                cfg = cfg, con = dsapp_db(cfg))
      }
      removeModal()
      if (!isTRUE(r$ok)) return(sj_note(r$msg %||% "没成功", "danger"))
      sj_note(r$msg, "success")
      sj_rev(sj_rev() + 1L)
    })

    observeEvent(input$sj_default, {
      if (!guard()) return()
      one <- sj_sel()
      if (is.null(one)) return(sj_note("先在上面选一条跳板。", "warning"))
      r <- dsapp_syncserver_set_default(as.integer(one$id), user = me(),
                                        cfg = cfg, con = dsapp_db(cfg))
      sj_note(r$msg, if (isTRUE(r$ok)) "success" else "warning")
      if (isTRUE(r$ok)) sj_rev(sj_rev() + 1L)
    })

    observeEvent(input$sj_toggle, {
      if (!guard()) return()
      one <- sj_sel()
      if (is.null(one)) return(sj_note("先在上面选一条跳板。", "warning"))
      r <- dsapp_syncserver_set_enabled(as.integer(one$id),
                                        !isTRUE(as.integer(one$enabled) == 1L),
                                        user = me(), cfg = cfg,
                                        con = dsapp_db(cfg))
      sj_note(r$msg, if (isTRUE(r$ok)) "success" else "warning")
      if (isTRUE(r$ok)) sj_rev(sj_rev() + 1L)
    })

    observeEvent(input$sj_del, {
      if (!guard()) return()
      one <- sj_sel()
      if (is.null(one)) return(sj_note("先在上面选一条跳板。", "warning"))
      r <- dsapp_syncserver_delete(as.integer(one$id), user = me(),
                                   cfg = cfg, con = dsapp_db(cfg))
      sj_note(r$msg, if (isTRUE(r$ok)) "success" else "warning")
      if (isTRUE(r$ok)) sj_rev(sj_rev() + 1L)
    })

    output$sj_msg <- renderUI(sj_msg())

    # ---- ③ 由同步包建出来的账号 ----
    #
    # 只读，用来对账。抢注拦不住（包里的口令校验器是真的），能做的只有
    # 「留痕」和「让人看得见」—— 这一栏就是"让人看得见"。
    output$sj_claimed <- renderUI({
      if (!isTRUE(is_platform())) return(NULL)
      sj_rev()
      r <- dsapp_err_try(dsapp_sync_claimed_users(cfg = cfg,
                                                  con = dsapp_db(cfg)),
                         where = "htadmin$sj_claimed", on_error = NULL)
      if (is.null(r) || !nrow(r)) {
        return(p(class = "small text-muted mb-0",
                 "还没有账号是通过同步包建出来的。"))
      }
      tagList(
        p(class = "small text-muted mb-1",
          sprintf("由同步包建出的账号（最近 %d 个）：", nrow(r)),
          "每一行都是一次「某台机器上的注册被带到了这里」。"),
        div(class = "dsapp-dt-nowrap",
          tags$table(class = "table table-sm small mb-0",
            tags$thead(tags$tr(tags$th("邮箱"), tags$th("昵称"),
                               tags$th("来自节点"), tags$th("时间"),
                               tags$th("公钥"))),
            tags$tbody(lapply(seq_len(nrow(r)), function(i) {
              tags$tr(
                tags$td(r$email[i]),
                tags$td(r$nickname[i] %||% ""),
                tags$td(tags$code(substr(r$sync_claimed_from[i] %||% "", 1, 12))),
                tags$td(r$sync_claimed_at[i] %||% ""),
                tags$td(if (as.integer(r$has_key[i]) == 1L)
                  span(class = "badge text-bg-success", "已绑")
                  else span(class = "badge text-bg-secondary", "无"))
              )
            }))
          ))
      )
    })

    invisible(NULL)
  })
}
