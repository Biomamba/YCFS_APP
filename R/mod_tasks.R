# =============================================================================
# 任务页
# =============================================================================
# 执行历史 + 重跑 + 产物下载。
#
# 重跑时同样走完整的三层防线：从数据库读出代码 → 重新静态扫描 → 重新执行。
# 不因为"这段代码之前跑过"就跳过扫描 —— 扫描规则会随版本更新，
# 而且任务表里的代码理论上可能被别的途径改过。
# =============================================================================

mod_tasks_ui <- function(id) {
  ns <- NS(id)

  # ★ V13.5 item 2：这一页原来是一句 `layout_columns(col_widths = c(5, 7))`。
  #
  #   用户原话：「执行历史和任务详情的宽窄需要用户能自定义」。
  #   c(5,7) 是 bslib 按 12 栅格算的**百分比**（41.7% / 58.3%），谁也改不了 ——
  #   窗口一窄，"执行历史"那五格就压不住里面那张六列的表。
  #
  #   换成和对话页**同一套**东西：一列定宽（`--dsapp-tasks-w`）、一条分隔条、
  #   剩下那列吃满。分隔条、拖动、双击回默认、键盘微调全部由 www/app.js
  #   里那份通用引擎提供，这里只负责给出**结构**和那个 `data-dsapp-panel`。
  #
  # ⚠️ 三件事必须同时对，少一件就是"拖了没反应"：
  #     1. 外层要有 .dsapp-task-page（app.js 的 clampTasks 按它的宽度算上限）；
  #     2. 定宽的那一列要有 .dsapp-task-hist（app.js 的 current() 量它的实际宽度
  #        当作拖动的起点，量不到就退回默认值 520 —— 表现是第一次拖动会跳一下）；
  #     3. 分隔条的 id 结尾必须是 split_ + [vhstm] 里的一个字母（这里是 `t`），
  #        app.js 靠 el.id.replace(/split_[vhstm]$/, "panel_size") 推 input 名。
  #        推不出来就**一声不响**地不上报，控制台干干净净。
  #
  # ⚠️ `.dsapp-task-detail` 上那个 min-width: 0 由 CSS 给（见 www/app.css）：
  #    flex 子项的默认 min-width 是 auto = 内容宽度，而详情里有代码块和
  #    产物路径，不写这一句右列会被撑出去、整页横向溢出。
  div(
    class = "dsapp-task-page",

    div(
      class = "dsapp-task-hist",
      card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span("执行历史"),
        actionButton(ns("refresh"), NULL, icon = icon("rotate"),
                     class = "btn-sm btn-outline-secondary")
      ),
      # ⚠️ V13.2 item 3：`fillable = FALSE` 是这个页面"按钮被表格压住"的**根因修复**，
      #    不是随手加的。原来的写法（默认 fillable = TRUE）会连着踩三层默认值：
      #
      #      1. bslib 的 card_body 默认 fillable，于是卡体是个
      #         `.html-fill-container`（flex 列）；
      #      2. htmltools 的 fill.css 把所有子元素里**带 html-fill-item 的**
      #         设成 `flex: 1 1 auto; min-height: 0`；
      #      3. DT 自己还有一条
      #         `.html-fill-container > .html-fill-item.datatables { flex-basis: 400px }`
      #         （DT 的 datatables-crosstalk.css，注释里写的正是"父元素想适应
      #         表格、表格想适应父元素"这个死结）。
      #
      #    合起来：**表格是卡体里唯一能伸缩的孩子**，其它孩子（按钮行、提示
      #    文字）都是 `flex: 0 0 auto`，既不长也不缩。表格一旦有真实行、
      #    高度不够，它就缩到内容高度**以下**，于是画在了后面那些兄弟元素
      #    身上 —— 而按钮行没有背景色，DT 的行也是透明的，所以看起来就是
      #    "按钮和表格糊在一起"。
      #
      #    关掉 fillable 之后卡片按内容长高，滚动交回 `.dsapp-main-body` ——
      #    这正是 www/codex.css:267-271 写下的本意（"内容比视口高 → 页签长
      #    出去，由 .dsapp-main-body 滚"）。表格本来就有 pageLength = 12
      #    兜着，长不到天上去。
      card_body(
        fillable = FALSE,
        # 筛选条。任务页是**唯一**能看到"跑过的都怎么样了"的地方，
        # 而它会一直长（每次重跑都加一行）—— 没有筛选的话，想找上周那个
        # 失败的任务只能一页页翻。
        div(class = "d-flex gap-2 align-items-end mb-2 flex-wrap",
          div(style = "min-width:130px;",
            selectInput(ns("f_status"), NULL, width = "100%",
                        selectize = FALSE,
                        choices = DSAPP_TASK_STATUS_CHOICES)),
          div(class = "flex-grow-1", style = "min-width:160px;",
            textInput(ns("f_kw"), NULL, placeholder = "搜标题或代码里的内容")),
          # ★ V13.11 item 11：两级展示的开关。默认**开着**（用户要的就是这个）。
          # 留一个关掉的开关是因为关掉之后回到"一行一条、按时间倒序"的老样子，
          # 那种视图在"我就想看看最近跑的那几条"时反而更直接。
          # 排序（V13.4 item 4）和它不冲突：见下面 output$tbl 里 rowCallback
          # 那段注释。
          div(style = "min-width:130px;",
            checkboxInput(ns("f_group"), "按对话分组", value = TRUE)),
          actionButton(ns("f_clear"), NULL, icon = icon("xmark"),
                       class = "btn-sm btn-outline-secondary mb-3",
                       title = "清空筛选")
        ),
        uiOutput(ns("count")),
        # ★ V13.5 item 3：外面这层是给「每行不换行 + 过宽就横向滚」用的。
        #   见 www/app.css 的 .dsapp-dt-nowrap 和下面 options 里的 scrollX。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("tbl"))),
        div(class = "d-flex gap-2 mt-3 align-items-center flex-wrap",
          actionButton(ns("rerun"), "重跑",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("play")),
          actionButton(ns("stop"), "停止",
                       class = "btn-sm btn-outline-warning",
                       icon = icon("stop")),
          # V7 item 6：多选 + 删除。按钮上的条数由服务端 updateActionButton()
          # 改写（见 mod_tasks_server），这里只给个初始文字。
          actionButton(ns("delete"), "删除选中",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("trash")),
          # item 7：不要绕道文件共享区传任务，直接选中任务共享给某个账号。
          # 语义上共享的是**这条任务所在的对话**（工作区、环境、上游产物
          # 都在对话上，只给一条任务是读不到输入的）—— 点开后弹窗第一句
          # 就说这件事，见 R/share.R。
          actionButton(ns("share"), "共享",
                       class = "btn-sm btn-outline-success",
                       icon = icon("share-nodes"),
                       title = "把这条任务所在的对话共享给指定账号查看")
        ),
        # 勾选状态是唯一一处"用户在做批量操作"的信号，界面上必须说出来：
        # 勾了几条、删会删几条、其余按钮认的是哪一条。不写的话，勾了三行
        # 再点「重跑」，用户不知道跑的是哪一行。
        uiOutput(ns("sel_hint")),
        # ⚠️ V13.2 item 4：这里原来写的是 `"…停的是**当前正在执行**的那个…"`。
        #    代码里到处都是 `**加粗**` 的写法，但那是**注释**里的约定 ——
        #    card_body 里的 HTML 不过 markdown，两个星号会原样显示给用户。
        #    要加粗得用 tags$b()。
        #
        #    至于"这句没渲染出来"：它其实一直在 DOM 里（自检里那条断言查的
        #    是字符串在不在源码里，所以一直是绿的）。用户看不到是因为它排在
        #    **卡体最后一个孩子**，而上面的表格把高度吃光之后，它被挤到卡体
        #    的 overflow 边沿之外 —— 同一个根因，见上面 fillable = FALSE
        #    那段。所以 item 3 和 item 4 是**同一处**修复。
        p(class = "small text-muted mt-2 mb-0",
          "「停止」停的是", tags$b("当前正在执行"),
          "的那个任务 —— 服务器同一时刻只跑",
          "一个任务（所有人的都排在后面）。选中它再点停止。")
      )
      )
    ),

    # 竖分隔条。结构和对话页那条**一模一样**（www/app.css 的 .dsapp-split-v），
    # 区别只有两点：id 结尾的字母（t）和 data-dsapp-panel 指的量（tasks_w）。
    #
    # ⚠️ tabindex 是给键盘用户的：焦点落上去之后左右方向键各微调 16px
    #    （见 app.js 的 keydown 分支）。少了它这条分隔条用键盘够不着。
    tags$div(
      class = "dsapp-split-v",
      id = ns("split_t"),
      `data-dsapp-panel` = "tasks_w",
      tabindex = "0", role = "separator",
      `aria-label` = "拖动调整执行历史的宽度",
      title = "拖动调整宽度（双击恢复默认）"
    ),

    # `dsapp-taskdetail` 是给 www/app.js 的 dsapp:flash 定位用的（V8 item 5：
    # 从文件页跳过来时要滚到这块并闪一下）。挂在外层 card 上而不是 card_body
    # 上 —— 要滚进视野的是整张卡（含标题栏），只滚 body 的话标题还留在屏幕外。
    div(
      class = "dsapp-task-detail",
      card(
      class = "dsapp-taskdetail",
      card_header(textOutput(ns("detail_title"), inline = TRUE)),
      # 右边这张同理（V13.2 item 3）：任务详情里有代码块和产物列表，长度不可
      # 预知，让它按内容长高、由页面滚，比"缩到卡片里再内部滚"好读得多。
      card_body(fillable = FALSE, uiOutput(ns("detail")))
      )
    )
  )
}

mod_tasks_server <- function(id, state, engine) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    refresh <- reactiveVal(0)

    # ★ V13.5 item 2：分隔条拖完（或键盘调完、双击回默认）报到服务端的那一下。
    #
    # ⚠️ 收的是 **`tasks-panel_size`**，不是顶层的 `panel_size` —— 上面那条
    #    分隔条的 id 是 ns("split_t")，长这样：`tasks-split_t`。app.js 的
    #    report() 做的是 `el.id.replace(/split_[vhstm]$/, "panel_size")`，
    #    **命名空间前缀原样保留**，于是算出来就是带前缀的这个名字。
    #    （主菜单那条反过来：它长在 app.R 的外壳里、没有前缀，所以报的是
    #     顶层 input，由 app.R 里那条同名的 observer 收。）
    #    收错名字的症状不是报错，是**拖完松手宽度弹回去**，控制台干干净净。
    #
    # ⚠️ ignoreNULL / ignoreInit 都要给上：`panel_size` 不是某个控件的值，
    #    是 app.js 用 Shiny.setInputValue 发的普通 input，初始化那一下是 NULL，
    #    不 ignore 的话会拿 NULL 去覆盖用户已经存好的尺寸。
    observeEvent(input$panel_size, {
      p <- input$panel_size
      if (is.null(p) || !is.list(p)) return()
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      # 只写报上来的那个键，其余沿用**库里现在的**值 —— dsapp_uipref_save()
      # 收的是一份完整偏好，少给一个键它会把那个键打回默认值（表现在用户
      # 那边就是"拖完执行历史，文件区宽度自己变回 320 了"）。
      full <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                       error = function(e) dsapp_uipref_norm(NULL))
      if (!is.null(p$tasks_w)) full$tasks_w <- p$tasks_w
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg)), silent = TRUE)
      # 加一把，让设置页那张卡也跟着显示新数字（那边 observeEvent 了它）。
      state$uipref_rev <- state$uipref_rev + 1L
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # 有任务在跑时自动刷新列表 —— 否则用户要手动点刷新才能看到状态变化。
    # 数据来自数据库而不是内存，所以其他会话提交的任务也能看到。
    #
    # ⚠️ 这里的 refresh(...) 必须真的**写**一次，只读是没用的。
    #    原来的写法是 `observe({ refresh(); if (running) invalidateLater(1500) })`：
    #    `refresh()` 读出来的值被丢掉，依赖值永远是 0，于是 invalidateLater
    #    只是让**这个 observer 自己**每 1.5 秒空跑一趟，下游的 tasks()
    #    一次都没失效过 —— 用户看到的是"我在言出法随页提交了任务、它明明在跑，
    #    切到任务页却是空的（或者一直停在旧状态）"。管理页踩过同一个坑，
    #    见 mod_admin.R 里那段注释。
    #
    #    isolate() 不能省：不 isolate 的话这一行同时**读**和**写** refresh()，
    #    observer 自己触发自己，1.5 秒的定时器就变成了自激的空转。
    #
    # V11 item 8：重跑出来的结果，也要回到它所属的那条对话里。
    #
    # 重跑是在「历史任务」页发起的，但它跑的是**某条对话**里的任务
    # （engine$start 传的 session_id 就是那条对话的）。结果只落在任务列表
    # 里的话，用户在对话里完全看不出自己刚重跑过 —— 而用户的原话是
    # 「实际的成功输出与失败输出都应该在言出法随界面给到用户」。
    #
    # ⚠️ 必须用 reactiveVal **记着"这一次是我提交的"**，不能靠"状态翻转了
    #    就去写"。全站只有一个执行槽，跑完的那个很可能是**别人**的任务；
    #    猜错的表现是往一条不相干的对话里塞一条执行结果，而且它看起来
    #    和真的执行记录一模一样，谁也查不出来。
    #
    # ⚠️ 也不能在这里写 pending_rerun() 而不 isolate：那是**读**，
    #    会让这个 observer 依赖它，而下面 settle 的时候要写它 ——
    #    读写同一个值，observer 自己触发自己。
    pending_rerun <- reactiveVal(NULL)

    settle_rerun <- function() {
      p <- isolate(pending_rerun())
      if (is.null(p)) return(invisible(FALSE))
      row <- tryCatch(db_task_get(p$tid, con = dsapp_db(cfg)),
                      error = function(e) NULL)
      if (is.null(row) || nrow(row) == 0) {
        pending_rerun(NULL)          # 记录被删了，没什么可写的
        return(invisible(FALSE))
      }
      if (!as.character(row$status %||% "") %in%
          c("success", "failed", "error", "timeout")) {
        return(invisible(FALSE))     # 还在跑，等下一拍
      }
      pending_rerun(NULL)
      ok <- tryCatch(dsapp_task_result_write(p$tid, p$sid, cfg = cfg, lang = p$lang),
                     error = function(e) FALSE)
      if (isTRUE(ok)) {
        # ⚠️ 写完必须通知对话页。对话页的历史靠它自己私有的 hist_ver 决定要
        #    不要重渲染，而那个 reactiveVal 在这个模块里够不着 —— 不加这一
        #    下，用户切回对话页看见的还是旧的那一屏（见 app.R 的 msg_rev）。
        state$msg_rev <- (state$msg_rev %||% 0L) + 1L

        # 任务挂了就交给对话页去把模型叫起来（V11 item 8 / ★ V13.5 item 1）。
        #
        # ⚠️ 这里**只发请求，不自己判断要不要叫**：agent 是挂在"当前打开的
        #    那条对话"上的，它够不够格接手（自动接手开着没、闲没闲、是不是
        #    这个对话、频率闸过没过）只有对话页说得清。这个模块负责的是
        #    "这次重跑挂了"这个事实。
        #
        # ★ V13.5 item 1 去掉了原来的 `isTRUE(env$is_env)`：用户的原话是
        #   「报错需要AI自己解决」，不限于环境类。是不是环境问题照样算出来
        #   一起带给模型，它据此决定怎么改。
        #   ⚠️ 判"挂了没"要看 status，**不能**只看 stderr 非空 —— 成功的
        #      任务也可能往 stderr 里写 warning（R 的 warning 就走 stderr），
        #      那会把模型叫起来去查一个根本没失败的任务。
        tryCatch({
          if (!identical(as.character(row$status %||% ""), "success")) {
            env <- dsapp_env_failure(
              stderr = as.character(row$stderr %||% ""),
              status = as.character(row$status %||% ""))
            state$env_fix_req <- list(sid = p$sid, tid = p$tid, env = env,
                                      n = (isolate(state$env_fix_req)$n %||% 0L) + 1L)
          }
        }, error = function(e) NULL)

        showNotification(
          sprintf("任务 #%d 已结束，结果已经写进它所属的那条对话", p$tid),
          type = "message", duration = 6)
      }
      invisible(ok)
    }

    # ---- 任务列表：**内容变了才重画**（★ V13.12 item 20）-------------------
    #
    # 这一页原来每 1.5 秒把 refresh() 加一 —— tasks() 跟着重查，下面那张 DT 表
    # 整张重画、计数重画、勾选提示重画。用户的原话是「分析进行时页面还是会
    # 刷新，取消这个机制，实时更新蹦出新结果就好」：他要的是**新结果蹦出来**，
    # 不是表格每 1.5 秒被换成一份一模一样的东西 —— 换一遍会连滚动位置、
    # 勾选状态一起丢掉，正在看第 80 行的用户每 1.5 秒被弹回表头。
    #
    # 所以轮询照旧（不轮询就永远发现不了别的会话提交的任务），但查出来的
    # 结果先跟上一拍比一次，**一模一样就不写**：没人被叫醒，也就没有重画。
    #
    # ⚠️ tasks() 因此**不能**再读 refresh()。它一读，下面那个"唤醒详情栏"
    #    的 refresh 加一就又把表格叫醒了 —— 白刷绕一圈又回来了。
    #    表格认 tasks_data，详情栏认 refresh，两条线各走各的（见 current()）。
    tasks_data <- reactiveVal(NULL)

    # 查 + 筛 + 重排，写成普通函数：observer（定时轮询那条路）和 tasks() 的
    # 首帧兜底都调它，逻辑只有一份。
    #
    # ⚠️ 筛选/重排必须留在**这里**（拿到 df 之后、交给 DT 之前），三条理由
    #    都在下面 tasks() 原来的注释里，一个字都没变 —— 只是换了个函数装。
    compute_tasks <- function() {
      # 只看自己账号名下对话里的任务。state$user_id 在注册/登录之后才非空，
      # 而任务页在那之前根本不会渲染，所以这里不需要额外的空值分支。
      #
      # with_code 只在**真的输了关键词**时才打开：这一页在任务跑着的时候
      # 每 1.5 秒重查一次，默认把 200 条任务的完整脚本都拉回来是白烧内存。
      # 不给的话 dsapp_filter_tasks() 会静默降级成"只搜标题"（见 db.R）。
      df <- db_tasks_list(user_id = state$user_id,
                          with_code = nzchar(trimws(input$f_kw %||% "")),
                          con = dsapp_db(cfg))
      df <- dsapp_filter_tasks(df, input$f_status, input$f_kw)
      if (isTRUE(input$f_group)) df <- dsapp_group_tasks(df)
      df
    }

    # 重新查一次。force = TRUE 是**用户手动**要的那一下（刷新按钮、删完、
    # 停完、重跑完）：那时候数据可能和上一拍长得一样（比如删掉的是一条
    # 被筛掉的记录），但界面必须动，不能拿"没变化"把用户挡回去。
    sync_tasks <- function(force = FALSE) {
      df <- tryCatch(compute_tasks(), error = function(e) NULL)
      if (is.null(df)) return(invisible(FALSE))
      if (!force && identical(df, isolate(tasks_data()))) return(invisible(FALSE))
      tasks_data(df)
      # 详情栏（current()）和它的产物列表认的是 refresh，这里加一让它们
      # 跟着重新读一次库。
      refresh(isolate(refresh()) + 1)
      invisible(TRUE)
    }

    # ⚠️ 状态**翻转**的那一拍也要刷，不能只靠定时器。任务结束的那一刻
    #    running 变 FALSE、定时器随之取消，最后一次轮询很可能停在结束前
    #    半秒 —— 不补这一下，终结状态（成功/失败）永远不会显示出来，
    #    用户盯着一个永远"运行中"的任务。
    #
    # ⚠️ 翻转那一拍**无条件**写（force），不交给指纹去判：引擎把 running
    #    置假和任务行落库是两步，最后一拍很可能赶在落库之前，指纹一比
    #    "没变化"—— 而这是**最后一次**轮询了，不再补一下的话这一页就永远
    #    停在"运行中"。白刷一次，换的是终结状态一定显示得出来。
    was_running <- reactiveVal(FALSE)
    observe({
      running <- isTRUE(engine$state$running)
      flip <- !identical(running, isolate(was_running()))
      # 每一拍都查一次，不再条件式地跳过：
      #   · 定时器那拍（在跑）—— 为了发现新提交的任务、别人的任务跑完了；
      #   · 筛选条/关键词/账号变了那拍 —— 那**不是**"在跑"才有的，跳过的
      #     话用户改一下筛选，表格纹丝不动（这正是把 refresh 从 tasks() 里
      #     摘掉之后新长出来的一个坑，得在这儿补上）。
      # 查完跟上一拍比，一模一样就不写 —— 不写就没人被叫醒，也就没有重画。
      sync_tasks(force = flip)
      # 表格没变的时候 refresh 不会动（上面那一拍走不到 tasks_data 那条线），
      # 但我**选中的那条正在跑**的话，详情栏得继续走 —— 实时输出就是在
      # 那一格里长出来的，停下来的话用户盯着一个不动的日志，还以为卡死了。
      if (running && !flip &&
          identical(engine$state$task_id, isolate(selected_id()))) {
        refresh(isolate(refresh()) + 1)
      }
      was_running(running)
      if (running) invalidateLater(1500)
      # 重跑收尾（item 8）。放在最后：它要读的是**已经落库**的状态，
      # 排在 refresh 前面的话读到的可能还是上一拍的数据。
      settle_rerun()
    })

    # 表格/计数/勾选提示读的都是**它**，不是 compute_tasks()。
    #
    # ⚠️ 这里**故意不读 refresh()**：读了的话，上面那个"唤醒详情栏"的 refresh
    #    加一就又把这几个 output 叫醒，白刷绕一圈原样回来。数据从 tasks_data
    #    来（内容变了才有新值），refresh 只喂 current() / task_group。
    #
    # 首帧兜底：observer 和 output 在同一拍里被唤醒，谁先谁后不保证，所以
    # tasks_data 可能还是 NULL —— 那时自己算一次。这一条只在第一拍走得到。
    tasks <- reactive({
      d <- tasks_data()
      if (is.null(d)) compute_tasks() else d
    })

    output$count <- renderUI({
      n <- nrow(tasks())
      total <- nrow(db_tasks_list(user_id = state$user_id, con = dsapp_db(cfg)))
      div(class = "small text-muted mb-1",
        if (n == total) sprintf("共 %d 条执行记录", total)
        else sprintf("筛出 %d 条（共 %d 条）", n, total))
    })

    observeEvent(input$f_clear, {
      updateSelectInput(session, "f_status", selected = "")
      updateTextInput(session, "f_kw", value = "")
    })

    output$tbl <- DT::renderDataTable({
      df <- tasks()
      if (nrow(df) == 0) {
        return(DT::datatable(
          data.frame(提示 = "还没有执行记录"),
          options = list(dom = "t", ordering = FALSE), rownames = FALSE))
      }

      # ---- 两级展示（V13.11 item 11）--------------------------------------
      #
      # 用户原话：「历史任务也按任务标题名称和内部执行的具体任务进行分级展示」。
      #
      # 一条对话里 agent 往往要跑十几步（装环境、取数、建模…），一步一行平铺
      # 在表里，标题那半截会话名还每行重复一遍 —— 想找"上周那个跑失败的是
      # 哪一步"只能一行行读。任务标题本身就是 `<这一步在干什么>_<所属对话>`
      # （见 utils.R 的 dsapp_task_title），两级天然存在，只是一直没画出来：
      #
      #   父级 = 所属对话（= 用户说的「任务标题名称」）
      #   子级 = 每一步自己（= 用户说的「内部执行的具体任务」）
      #
      # ⚠️ 父级**不是**凭空插一行，而是让每组的第一条任务**兼任**组标题
      #    （「对话」那一列写会话名，其余行写一个 └）。这一页所有批量操作
      #    （选中/重跑/停止/删除/共享）都按**行号**回查 tasks()，插一行就会
      #    让行号整体错位 —— 而那种错的表现是"点第 3 行删掉的是第 4 条"，
      #    真的会删错东西，不只是显示不对。
      #
      # ⚠️ 组标题取的是 sessions.title（用户自己那句提问），**不是**把任务
      #    标题按 `_` 切开取后半截。切不出来：dsapp_task_title 是按 48 字总额
      #    度截过的（功能名 23 + 下划线 + 会话名 24），功能名一长后半截就被
      #    截没了，而功能名自己就带下划线。db_tasks_by_owner 早就是这么取的
      #    （那里取不到会写「（对话已删除）」），这里跟它保持一致。
      grouping <- isTRUE(input$f_group) && !is.null(df$session_id)

      conv <- rep("", nrow(df))     # 「对话」这一列的内容
      grp  <- rep("", nrow(df))     # 行 class，交给下面 rowCallback

      if (grouping) {
        sid <- as.character(df$session_id); sid[is.na(sid)] <- ""
        st  <- as.character(df$session_title %||% rep("", nrow(df)))
        if (length(st) != nrow(df)) st <- rep("", nrow(df))
        st[is.na(st)] <- ""
        # 会话被删掉之后任务一般也跟着删了（见 db_session_delete），但老库里
        # 可能还有遗留行。留个白格子在表里看着像界面坏了，给一句实话。
        st[!nzchar(st)] <- "（对话已删除）"

        head_i <- !duplicated(sid)
        # ⚠️ 用 ave() 而不是 table(sid)[sid]：后者靠名字回查，sid 里出现空串
        #    或特殊字符时的行为不好推理，而 ave 保证长度和位置一一对应。
        grp_n <- ave(seq_along(sid), sid, FUN = length)

        # 只有一步的对话不写「（1 个任务）」—— 那是句废话，还占地方。
        conv[head_i] <- ifelse(
          grp_n[head_i] > 1L,
          sprintf("%s（%d 个任务）", st[head_i], grp_n[head_i]),
          st[head_i])
        conv[!head_i] <- "└"          # └
        grp[head_i]  <- "dsapp-task-grp-head"
        grp[!head_i] <- "dsapp-task-grp-sub"
      }

      # 分组视图下标题尾巴上那半截会话名是多余的（左边那一列已经写着呢），
      # 去掉它才看得见"这一步到底在干什么"。**只在分组时去** —— 平铺视图里
      # 会话名没别的地方显示，去掉了就彻底看不见了。
      ttl <- as.character(df$title %||% rep("", nrow(df)))
      if (length(ttl) != nrow(df)) ttl <- rep("", nrow(df))
      if (grouping) ttl <- dsapp_task_short_title(ttl, df$session_title)

      show <- data.frame(
        # V7 item 6：第 0 列是复选框列，内容永远是空字符串 —— 方框是
        # select-checkbox 这个 class 用 CSS 画出来的（::before 画框、
        # tr.selected 的 ::after 画 ✓），表头那个"全选"也是同一套。
        sel = rep("", nrow(df)),
        id = df$id,
        conv = conv,
        title = substr(ttl, 1, 40),
        # 共享来的任务（item 7）必须标出来。不标的话它和自己的任务在列表里
        # 长得一模一样，而"重跑 / 删除"对它又是禁用的 —— 用户点了没反应，
        # 只会以为界面坏了。
        # ⚠️ 向量化比较，别用 identical()：那个是拿整列和标量比，长度不等
        #    永远返回 FALSE —— 表现是"这一列全是空的"，不报错。
        from = ifelse(as.character(df$role %||% rep("", nrow(df))) == "shared",
                      "共享", ""),
        lang = df$lang,
        status = dsapp_status_label(df$status),
        time = vapply(df$created_at, dsapp_fmt_time, character(1)),
        # 完成时间（V9 item 7）。用户的原话是「额外还需要显示任务完成时间」——
        # 光有创建时间答不了"这个跑完没有、跑完多久了"：一个 running 的任务
        # 创建时间和现在只差几秒，一个失败的任务可能创建于两小时前。
        #
        # ⚠️ 不能 vapply(df$finished_at, ...)：没跑完的任务这一列是 NULL 或
        #    NA，而 vapply 要求每次调用的返回值长度**严格**为 1 ——
        #    dsapp_fmt_time(NA) 返回 "—" 是对的，但它拿到 NA_character_ 时
        #    也一样，倒是没问题；真正会炸的是这一列整个是 NULL（老库还没
        #    迁移过 tasks 表的那几个版本）。所以先补一列再算。
        done = vapply(
          if (is.null(df$finished_at)) rep(NA_character_, nrow(df))
          else df$finished_at,
          dsapp_fmt_time, character(1)),
        # ★ V13.11 item 11：行 class 的**载体**。DT 没有"给某一行加个类"的
        #    接口，只能靠在 options$rowCallback 里读一列数据再加 —— 所以这里
        #    搭一趟车。它在 columnDefs 里是 visible = FALSE，用户看不见，
        #    也不参与排序/搜索（这一列的值就两种，本来也没意义）。
        #
        # ⚠️ 它必须是**最后一列**，rowCallback 里按下标取（见下面 rowCallback
        #    的注释）。放在中间的话下标变了不会报错，只会静默地永远取到空值、
        #    分组的那几条样式全部失效。
        grp = grp,
        stringsAsFactors = FALSE
      )

      DT::datatable(
        show,
        colnames = c("", "ID", "对话", "标题", "来源", "语言", "状态",
                     "创建时间", "完成时间", "分组"),
        extensions = "Select", rownames = FALSE,
        # ⚠️ selection = "none" 是**必须的**，不是笔误。DT 自带的那套行选中
        #    （点行高亮、Ctrl 多选）和 Select 扩展是**两套独立实现**，同时开着
        #    会互相抢 —— 点一下勾上、再点一下被另一套清掉。这里只留 Select
        #    扩展（复选框），勾选结果照样喂给 input$tbl_rows_selected：DT 的
        #    绑定里有一段专门的分支（datatables.js:1007），条件是
        #    `selection.mode === 'none' && !server && 装了 Select 扩展`。
        selection = "none",
        options = list(
          # ★ V13.4 item 4：ordering 打开了（用户要「能够排序」）。
          #
          # ⚠️ 排序**不会**打乱勾选。DT 的 rows_selected 给的是**数据行号**
          #    （原始数据里的下标），不是屏幕上第几行 —— 排完序之后行号不变，
          #    所以下面 selected_ids() 里 `df$id[i]` 那个映射照样成立。
          #    这一点要是反的，表现会是"排个序，删掉的却是别的记录"。
          #
          # 第 0 列（复选框）在 columnDefs 里是 orderable = FALSE，表头不会
          # 出现排序箭头；app.js 的 dsappSelectAll 里那句 stopPropagation
          # 就是为"哪天有人把排序打开"留的，现在正好接住。
          #
          # 时间列排的是 dsapp_fmt_time 的**字符串**（YYYY-MM-DD HH:MM），
          # 字典序和时间序一致，所以按字面排就是按时间排。
          dom = "tp", pageLength = 12, ordering = TRUE,
          # ★ V13.5 item 3：每行**不许换行**，宽度不够就整张表横向滚。
          #
          #   用户原话：「执行历史的列表每行不允许换行，如果过宽，请增加整个
          #   列表的滑动条」。
          #
          #   两件事缺一不可，而且分别在两个地方：
          #     1. `white-space: nowrap` 在 CSS 里（.dsapp-dt-nowrap，见
          #        www/app.css）—— 不换行；
          #     2. 滚动容器也在 CSS 里（同一个类）—— 过宽时给一条横向滚动条。
          #   只做 1 会**横向溢出到卡片外面**（表格没有自己的滚动容器，
          #   撑破的是整页）；只做 2 没有意义（列能被压窄，永远不触发滚动）。
          #
          #   ⚠️ 这一页在 V13.5 item 2 之后左栏宽度是**用户可调**的，所以他
          #      完全可能把它拖到比内容窄 —— 这条滚动条不是"以防万一"，
          #      是那条分隔条的必然配套。
          #
          #   ⚠️ `autoWidth = FALSE` 是配套的，不能省。DT 默认（TRUE）会让
          #      DataTables **算出**一组加起来正好等于容器宽的列宽写进内联
          #      style —— 表格宽度被钉死在容器上，永远不溢出，那条滚动条
          #      一次都不会出现（而列被压窄之后，nowrap 的文字会直接糊到
          #      隔壁单元格上，因为 td 的 overflow 是 visible）。
          #      关掉之后宽度交回给浏览器：内容多宽表格就多宽，超了才滚。
          #
          #   ⚠️ 这里**故意不用** DT 自带的 `scrollX = TRUE`。它会把表头克隆
          #      一份到 .dataTables_scrollHead 里单独放一张 <table>，于是
          #      "往表头塞东西"的 dsappSelectAll（www/app.js）塞错了地方 ——
          #      方框在 DOM 里、自检绿、屏幕上没有；就算两边都塞，DataTables
          #      重画时 cloneNode 出来的那份**不带事件监听**，会得到一个看得见
          #      但点不动的方框。自己套一层滚动容器没有这些问题，表头也跟着
          #      一起横滚，对齐是浏览器保证的。
          autoWidth = FALSE,
          # ★ V13.11 item 11：给每一行挂上它该有的样式类（组标题 / 组员）。
          #
          #   第 3 个参数 index 是**数据行号**（不是屏幕上第几行），和
          #   input$tbl_rows_selected 是同一套编号 —— 所以排序、翻页都不会
          #   让类挂错行。这里没用它，但签名不能省：DT 是按位置传参的。
          #
          #   ⚠️ 取的是**最后一列**（grp，visible = FALSE）。写成写死的数字
          #      的话，哪天中间插一列就会静默失效（取到一列空的字符串，
          #      不报错、分组样式全没了）。所以用 ncol(show) - 1 现算，
          #      和上面 `grp = grp` 那条注释是同一个约定。
          rowCallback = DT::JS(sprintf(
            "function(row, data, index) {
               var c = data[%d];
               if (c) { row.className = row.className ? row.className + ' ' + c : c; }
             }", ncol(show) - 1L)),
          # 表头全选方框（Select 1.7.0 没有这个功能，见 dsapp_dt_select_all）
          initComplete = dsapp_dt_select_all(),
          columnDefs = list(
            list(orderable = FALSE, className = "select-checkbox", targets = 0),
            list(className = "dt-left", targets = "_all"),
            # 分组标记那一列只给 rowCallback 读，不给用户看。
            # ⚠️ 它是**最后一列**，和上面 rowCallback 里 `ncol(show) - 1` 是
            #    同一个约定，改一处必须改另一处。
            list(visible = FALSE, targets = ncol(show) - 1L)),
          # style = "multi" + td:first-child：**每次点方框是切换**（勾上/
          # 取消），而不是"点一下只留这一个"。
          #
          # ⚠️ 不要改成 "os"：那个模式下普通点击会**清掉**前面勾的，只有
          #    Ctrl/⌘ + 点击才追加。而这是一列复选框，用户的心理模型就是
          #    "一个个勾" —— 浏览器实测抓到过：勾第二个之后按钮上只剩一条。
          #
          # ★ V13.4 item 4：selector 从 "td:first-child" 放宽到整行。
          #
          #   用户原话：「点击信息条就能选择，而不是点击小框」。原来只有
          #   最左边那个 16 像素的方框能点，而这一列的表头还是空的（全选框
          #   是 app.js 自己塞进去的）—— 一条记录的可点区域小到要瞄准。
          #
          #   代价是**点标题也会勾上它**，这是用户明确要的：勾上之后右侧详情
          #   卡就切到这一条（详情认"行号最小的那条"），所以"点一下 = 选中 +
          #   看详情"，比原来"点标题没反应、得去点方框"更符合直觉。
          #   style = "multi" 保留：再点一下是取消，不会把别的勾清掉。
          select = list(style = "multi", selector = "td")
        )
      )
    # ⚠️ 上面那个三元条件里的 `!server` 必须是真的 —— `server = FALSE` 不
    #    能省。`renderDT` 默认 server = TRUE，那样 options$serverSide 就是
    #    TRUE，前端那段绑定整段跳过。表现**不是报错**：方框照画、点了照样
    #    高亮（那是 Select 扩展自己画的），只有 input$tbl_rows_selected
    #    永远是空的 —— 按钮上的数字永远不动，"删除选中"下的永远是一个空集
    #    合。2026-09-15 浏览器实测抓到过这个：代码看着全对，UI 全对，就是
    #    什么都没发生。DT 自己在启动日志里 warning 过一句"Select 扩展不
    #    适用于服务端模式"，很容易被当成噪音划过去。
    }, server = FALSE)

    # 勾选集合：**行号 → 任务 id**。行号是 DT 的**全量数据**下标（不是当前页
    # 的），因为本表分页 12 条一页而 rows_selected 给的是全局行号。
    selected_ids <- reactive({
      i <- input$tbl_rows_selected
      df <- tasks()
      if (is.null(i) || length(i) == 0) return(integer(0))
      i <- i[!is.na(i) & i >= 1 & i <= nrow(df)]
      if (length(i) == 0) return(integer(0))
      # 按行号排序后取 id：DT 的 rows({selected:true}) 本来就按表格顺序给，
      # 但这里不依赖那个实现细节 —— 下面"详情认第一条"要的是**稳定的**第一条。
      as.integer(df$id[sort(i)])
    })

    # 右侧详情、重跑、停止、共享都只认**一条**。多选之后取哪一条？
    # 取行号最小的那条（= 列表里最上面那条），并且在下面 sel_hint 里把
    # "其余按钮认的是第一条"说出来 —— 不写的话用户勾了三行点重跑，
    # 不知道跑的是哪一行。
    selected_id <- reactive({
      ids <- selected_ids()
      if (length(ids) == 0) return(NULL)
      ids[[1]]
    })

    current <- reactive({
      id <- selected_id()
      if (is.null(id)) return(NULL)
      # 有这个任务的作业在跑时跟着刷新，让用户看到实时状态
      if (isTRUE(engine$state$running) &&
          identical(engine$state$task_id, id)) refresh()
      db_task_get(id, con = dsapp_db(cfg))
    })

    # ---- 选中任务的归属（item 7）--------------------------------------------
    # 共享给我的对话里的任务：**看得到，动不了**。
    #
    # ⚠️ db_task_get() 给的是原始任务行，里面没有角色 —— 归属只能从
    #    session_id 反查，而且**必须**查：这个 reactive 是重跑和删除的
    #    唯一闸门，写成"默认放行"的话，被共享的人能在别人的工作区里
    #    重新跑代码、删掉别人的执行记录。
    current_role <- reactive({
      t <- current()
      if (is.null(t)) return("none")
      db_session_role(t$session_id, state$user_id,
                      is_admin = dsapp_user_is_platform_admin(state$user),
                      con = dsapp_db(cfg))
    })
    #' 共享来的任务被拦下时统一说这句。说清楚"为什么点了没反应"，
    #' 而不是静默什么都不做。
    deny_shared <- function(what) {
      showNotification(
        sprintf("这条任务来自别人共享给你的对话，只能查看和下载，不能%s。", what),
        type = "warning", duration = 8)
    }

    # ---- 从文件页的产物分组跳过来（V8 item 5）-----------------------------
    #
    # 跳转方只给一个任务号，剩下的（在不在当前筛选里、在第几页）只有这一页
    # 知道。所以先记下来，等列表真的算出来了再定位。
    #
    # ⚠️ 不能在一个 observeEvent 里直接 selectRows。那一刻 tasks() 很可能
    #    还是上一次那一份 —— 上面刚把筛选条清掉，而新值要等客户端下一次
    #    上报才生效 —— 行号对不上，选中的会是**别的任务**，且界面上看不出
    #    任何异常。
    pending_focus <- reactiveVal(NULL)
    focus_tries   <- reactiveVal(0L)

    observeEvent(state$focus_task, {
      id <- state$focus_task
      # 一次性指令，进门就清。留着的话，用户下次自己切回任务页会莫名其妙
      # 跳到一条旧任务上。
      state$focus_task <- NULL
      id <- suppressWarnings(as.integer(id))
      if (is.na(id)) return()
      # 用户点的是"看这条任务"，不是"看筛选结果" —— 先把筛选清掉。
      updateSelectInput(session, "f_status", selected = "")
      updateTextInput(session, "f_kw", value = "")
      focus_tries(0L)
      pending_focus(id)
    }, ignoreNULL = TRUE)

    # dsapp-selftest: self-reactive-ok pending_focus
    #
    #   ⚠️ 显式豁免。读 pending_focus()（下一行）又写它（下面两处都写 NULL）。
    #     不会失控的理由：**写进去的是 NULL**，下一轮第 2 行就 return。读那一
    #     侧不能 isolate —— 「在文件区点一个任务跳过来」是写 pending_focus(id)
    #     来发起这次定位的，这个依赖就是唤醒源。
    #     （旁边 focus_tries 的读已经 isolate 了，见下面那行 `n <- isolate(...)`。）
    observe({
      id <- pending_focus()
      if (is.null(id)) return()
      df <- tasks()
      i <- match(id, as.integer(df$id))
      if (is.na(i)) {
        # 列表可能还在按上一次的筛选算。等一拍再试，别立刻报"没找到"——
        # 那样只要筛选条上当时挂着东西，从文件页跳过来就必然弹一句假报错。
        n <- isolate(focus_tries())
        if (n >= 5L) {
          focus_tries(0L); pending_focus(NULL)
          showNotification(
            sprintf("没找到任务 #%d（可能不是你的，或者已经删了）", id),
            type = "warning", duration = 8)
        } else {
          focus_tries(n + 1L)
          invalidateLater(300)
        }
        return()
      }
      focus_tries(0L); pending_focus(NULL)
      # ⚠️ 这里**不能**用 DT::selectRows()。本表的 selection = "none"（理由
      #    见 output$tbl 那段注释：勾选交给 Select 扩展），而 DT 的
      #    methods.selectRows 整个定义在 datatables.js 的
      #    `if (inArray(selMode, ['single','multiple']))` 里面 —— mode 是
      #    "none" 时**这个函数根本没被定义**，发过去的 proxy 消息到了浏览器
      #    就没人接。表现和"漏了一个 observeEvent"一模一样：服务端日志一句
      #    话没有、try() 也 catch 不到（R 这边只是把消息发出去，发成功了），
      #    界面上就是"跳过来了，但什么都没选中"。2026-09-15 浏览器实测抓到。
      #    所以走自定义消息，用 Select 扩展自己的 API 选 —— 那正是用户手点
      #    复选框走的那条路，input$tbl_rows_selected 会照常被喂上，
      #    详情卡不用再认第二份状态。
      session$sendCustomMessage("dsapp:dtselect",
        list(id = session$ns("tbl"), row = i))
      # 表格滚到了，右侧详情也该露出来。窄屏下两栏是上下堆叠的，
      # 不滚的话用户只看到一个被选中的列表行。
      session$sendCustomMessage("dsapp:flash",
        list(sel = ".dsapp-taskdetail"))
    })

    # ---- 这条任务到底产出了什么（V8 item 5）-------------------------------
    #
    # ⚠️ 用**和文件页同一份**数据。这里原来是 dsapp_artifacts_of(t$workdir)，
    #    也就是"把这个工作区现存的文件全部列一遍" —— 那是**整个对话**的
    #    产出，不是这一条任务的。用户点开第 3 条，看到的是 1、2、3 条加起来
    #    的东西，点开第 1 条看到的是同一批。文件页按任务分好了组，任务页却
    #    在列整个工作区 —— 用户说的"二者脱钩"有一半就是从这儿来的。
    task_group <- reactive({
      t <- current()
      if (is.null(t) || is.null(t$session_id) || !nzchar(t$session_id)) return(NULL)
      gs <- tryCatch(dsapp_ws_groups(t$session_id, cfg),
                     error = function(e) list())
      for (g in gs) {
        if (!is.na(g$task_id) && identical(as.integer(g$task_id), as.integer(t$id)))
          return(g)
      }
      NULL
    })

    #' 产物行里的动作链接。和文件页同一套做法：把 `动作|参数` 塞进一个
    #' **共用**的 input，由一个 observer 分派（理由见 mod_files.R 里
    #' ws_act_link 的说明 —— renderUI 里逐个注册 observer 会留下永不回收
    #' 的一批，而且全都指向上一次的数据）。
    art_link <- function(label, act, arg, ico = NULL, cls = "dsapp-wsrow-a") {
      js <- sprintf(paste0("event.stopPropagation();",
                           "Shiny.setInputValue(%s,%s,{priority:'event'});",
                           "return false;"),
                    jsonlite::toJSON(ns("art_act"), auto_unbox = TRUE),
                    jsonlite::toJSON(paste0(act, "|", arg), auto_unbox = TRUE))
      tags$a(href = "#", class = cls, onclick = js,
             if (!is.null(ico)) icon(ico), " ", label)
    }

    #' 产物名：点一下直接预览（V13.4 item 5a）
    #'
    #' 用户原话：「历史任务的文件区需要能够直接通过点击文件名预览」。
    #' 原来这只是一段 span，名字旁边的「去文件区看」要跳到另一个页面 ——
    #' 而"这个文件是什么"这个问题，跳过去之后还得在文件页里再找一遍。
    #'
    #' ⚠️ **目录不给预览**，保持纯文本。没有"预览一个文件夹"这回事，
    #'    做成一个点了弹出"无法预览"的链接比不做更糟。
    #'
    #' ⚠️ 走的是和 art_link 同一个 input（ns("art_act")），不是各自一套 ——
    #'    renderUI 里逐个注册 observer 会留下一批永不回收的观察者
    #'    （mod_files.R 的 ws_act_link 那段注释写了这件事）。
    art_name <- function(nm, is_dir) {
      if (isTRUE(is_dir)) {
        return(span(class = "dsapp-taskart-name", title = nm, nm))
      }
      js <- sprintf(paste0("event.stopPropagation();",
                           "Shiny.setInputValue(%s,%s,{priority:'event'});",
                           "return false;"),
                    jsonlite::toJSON(ns("art_act"), auto_unbox = TRUE),
                    jsonlite::toJSON(paste0("preview|", nm), auto_unbox = TRUE))
      tags$a(href = "#", class = "dsapp-taskart-name",
             title = paste0("点击预览：", nm),
             onclick = js, nm)
    }

    #' 跳到文件页的对话产物区，并且停在指定的产物（或这个对话）上。
    #'
    #' 走共享状态而不是 URL 参数：文件页的默认视图是**当前对话**，而这里
    #' 要它显示的是**这条任务所属的**对话，两边很可能不是同一个。
    goto_ws <- function(task, name = NULL) {
      state$focus_ws <- list(sid = task$session_id, task_id = as.integer(task$id),
                             name = name)
      dsapp_nav_to(state, "files")
    }

    observeEvent(input$art_act, {
      v <- input$art_act
      req(v, nzchar(v))
      cut <- regexpr("|", v, fixed = TRUE)
      if (cut < 1) return()
      act <- substr(v, 1, cut - 1)
      arg <- substr(v, cut + 1, nchar(v))
      t <- current()
      if (is.null(t)) return()
      if (identical(act, "open")) {
        goto_ws(t, if (nzchar(arg)) arg else NULL)
      } else if (identical(act, "preview")) {
        # 点文件名直接预览（V13.4 item 5a）。弹窗里现算，不预先读文件 ——
        # 几百个产物一条条读进来，这一页就废了。
        art_preview(arg)
        showModal(modalDialog(
          title = arg,
          size = "l",
          uiOutput(ns("art_prev_ui")),
          easyClose = TRUE,
          footer = tagList(
            modalButton("关闭"),
            actionButton(ns("art_prev_goto"), "去文件区看",
                         class = "btn-sm btn-outline-primary",
                         icon = icon("arrow-up-right-from-square"))
          )
        ))
      }
    })

    #' 弹窗里要预览的那个产物名（工作区相对路径）
    art_preview <- reactiveVal(NULL)

    output$art_prev_ui <- renderUI({
      nm <- art_preview()
      if (is.null(nm) || !nzchar(nm)) return(NULL)
      t <- current()
      if (is.null(t)) return(NULL)
      sid <- t$session_id
      if (is.null(sid) || !nzchar(sid %||% "")) {
        return(div(class = "alert alert-warning m-3", "这条任务没有关联的对话工作区。"))
      }
      # ⚠️ 必须先过 dsapp_ws_path 再交给预览：预览那一层（dsapp_preview_ui）
      #    只负责"这个文件怎么显示"，它**不做路径归属判断** —— 直接把
      #    `nm` 拼进工作区路径的话，一个叫 `../../data/dsapp.sqlite3` 的
      #    产物名就能读到工作区外面去。名字来自数据库，而数据库里的名字
      #    是模型生成的代码写出来的。
      path <- dsapp_ws_path(nm, sid, cfg)
      if (is.null(path)) {
        return(div(class = "alert alert-warning m-3",
          sprintf(paste0("工作区里找不到「%s」了 —— 它可能被后来的任务覆盖过，",
                         "或者被删掉了。用下面的「去文件区看」看看现在有什么。"),
                  nm)))
      }
      # 表格那一支不传 table_render：弹窗的内容整个在 renderUI 里，
      # 而 renderUI 里不能嵌套 renderDataTable（见 dsapp_preview_ui 的说明）。
      dsapp_preview_ui(path, session, cfg = cfg)
    })

    observeEvent(input$art_prev_goto, {
      t <- current()
      if (is.null(t)) return()
      removeModal()
      goto_ws(t, if (nzchar(art_preview() %||% "")) art_preview() else NULL)
    })

    observeEvent(input$open_ws, {
      t <- current()
      if (is.null(t) || is.null(t$session_id) || !nzchar(t$session_id)) {
        return(showNotification("这条任务没有关联的对话工作区", type = "warning"))
      }
      goto_ws(t)
    })

    output$detail_title <- renderText({
      t <- current()
      if (is.null(t)) "任务详情" else sprintf("任务 #%d · %s", t$id, t$title)
    })

    output$detail <- renderUI({
      t <- current()
      if (is.null(t)) {
        return(p(class = "text-muted small", "在左侧选择一条记录查看详情。"))
      }

      # 正在跑的任务，把子进程的实时输出读出来 —— 长任务（RunUMAP 之类）
      # 只给一个转圈会让人以为卡死了。子进程把 stdout 直接写文件，
      # 这里 tail 一下就能看到进度。
      #
      # ⚠️ 路径**不能**用 t$workdir：那一列是任务**结束时**才写进去的
      #    （见 app.R 里 e$poll 那次 db_task_status），running 状态下它是
      #    NA —— 于是这个条件永远不成立，整块"实时输出"从来没渲染过一次。
      #    它不报错、不留痕，只是永远不出现。工作区路径本来就可以从
      #    session_id 推出来（utils.R 的 dsapp_ws_dir），用那个。
      live_out <- NULL
      if (identical(t$status, "running")) {
        wd <- if (!is.null(t$workdir) && !is.na(t$workdir)) t$workdir
              else if (!is.null(t$session_id) && nzchar(t$session_id %||% ""))
                dsapp_ws_dir(t$session_id, cfg, create = FALSE)
              else NULL
        if (!is.null(wd) && !is.na(wd)) {
          live_out <- dsapp_tail(file.path(wd, ".dsapp_stdout"),
                                 n = 200, max_bytes = 128 * 1024)
        }
      }

      tagList(
        div(class = "d-flex align-items-center gap-2 mb-3",
            dsapp_status_badge(t$status),
            tags$span(class = "text-muted small",
                      sprintf("%s · %s", t$lang,
                              dsapp_fmt_time(t$created_at))),
            if (!is.null(t$exit_code) && !is.na(t$exit_code))
              tags$span(class = "text-muted small",
                        sprintf("· 退出码 %d", t$exit_code))
        ),

        # 完成时间（V9 item 7）。单独一行而不是挤在上面那排里：那一排已经
        # 有状态徽章、语言、创建时间、退出码，再加一个就没有主次了；
        # 而"什么时候跑完的、跑了多久"是这一页最常被问的两个问题。
        div(class = "small text-muted mb-3",
          icon("flag-checkered"), " 完成时间：",
          if (identical(t$status, "running")) "还在跑"
          else dsapp_fmt_time(t$finished_at %||% NA_character_),
          if (!is.null(t$started_at) && !is.na(t$started_at) &&
              !is.null(t$finished_at) && !is.na(t$finished_at)) {
            secs <- dsapp_duration_between(t$started_at, t$finished_at)
            if (!is.na(secs)) sprintf("（耗时 %s）", dsapp_fmt_duration(secs))
          }
        ),

        if (!is.null(live_out) && nzchar(live_out)) tagList(
          h6(class = "text-muted small", "实时输出"),
          tags$pre(class = "dsapp-pre", live_out)
        ),

        h6(class = "text-muted small mt-3", "代码"),
        tags$pre(class = "dsapp-pre", dsapp_escape(t$code)),

        if (!is.null(t$stdout) && !is.na(t$stdout) && nzchar(t$stdout)) tagList(
          h6(class = "text-muted small mt-3", "标准输出"),
          tags$pre(class = "dsapp-pre", dsapp_escape(t$stdout))
        ),

        if (!is.null(t$stderr) && !is.na(t$stderr) && nzchar(t$stderr)) tagList(
          h6(class = "text-muted small mt-3", "标准错误"),
          tags$pre(class = "dsapp-pre dsapp-pre-err", dsapp_escape(t$stderr))
        ),

        # ---- 产物（V8 item 5：可点、可跳回文件区）----
        if (!is.null(t$session_id) && nzchar(t$session_id %||% "")) {
          g <- task_group()
          if (!is.null(g) && nrow(g$files)) {
            tagList(
              div(class = "d-flex align-items-center gap-2 mt-3 mb-1",
                h6(class = "text-muted small mb-0",
                   sprintf("产物（%d 个文件%s）", g$n_file,
                           if (isTRUE(g$n_dir > 0))
                             sprintf("、%d 个文件夹", g$n_dir) else "")),
                actionButton(ns("open_ws"), "在文件区打开",
                             class = "btn-sm btn-outline-primary py-0",
                             icon = icon("folder-open"))
              ),
              div(class = "dsapp-taskarts",
                lapply(seq_len(nrow(g$files)), function(i)
                  div(class = paste("dsapp-taskart",
                                    if (isTRUE(g$files$is_dir[i]))
                                      "dsapp-taskart-dir" else ""),
                    icon(if (isTRUE(g$files$is_dir[i])) "folder" else "file"),
                    art_name(g$files$name[i], g$files$is_dir[i]),
                    span(class = "dsapp-taskart-size small text-muted",
                         g$files$size_h[i]),
                    art_link("去文件区看", "open", g$files$name[i],
                             "arrow-up-right-from-square")
                  ))
              )
            )
          } else if (!is.null(t$workdir) && !is.na(t$workdir)) {
            # 没有产物索引可查（V8 之前的任务、或者这条任务被后来的任务
            # 覆盖过 —— task_files 的归属是"最新的任务赢"）。回落到"列一遍
            # 工作区"，但**必须说清楚**这是整个工作区而不是这一条任务的，
            # 否则用户会以为下面这些都是这条任务产出的。
            old <- dsapp_artifacts_of(t$workdir)
            if (length(old)) tagList(
              div(class = "d-flex align-items-center gap-2 mt-3 mb-1",
                h6(class = "text-muted small mb-0", "工作区里现有的文件"),
                actionButton(ns("open_ws"), "在文件区打开",
                             class = "btn-sm btn-outline-primary py-0",
                             icon = icon("folder-open"))
              ),
              p(class = "small text-muted mb-1",
                "这条任务没有留下产物索引（它产出的文件后来被别的任务覆盖过）。",
                dsapp_md_inline("下面列的是这个对话工作区**现在**的全部内容。")),
              tags$ul(class = "small",
                lapply(old, function(a) tags$li(a)))
            )
          }
        }
      )
    })

    # ---- 重跑 ----
    observeEvent(input$rerun, {
      t <- current()
      if (is.null(t)) {
        showNotification("请先选择一条记录", type = "warning")
        return()
      }
      # 重跑 = 在**别人的工作区**里再跑一遍代码、烧掉一次全站唯一的执行槽。
      # 被共享的人只能看（见 dsapp_role_can_write）。
      if (!dsapp_role_can_write(current_role())) return(deny_shared("重跑"))
      # 用 is_busy() 而不是 engine$state$running：这里是"要不要提交"的
      # 判断，不该和响应式状态扯上关系（理由见 app.R 引擎那段注释）
      if (engine$is_busy()) {
        showNotification("已有任务在执行，请等它结束", type = "warning")
        return()
      }

      res <- engine$start(t$code, t$lang,
                          # 别直接 paste0("[重跑] ", ...)：连着重跑会把标题
                          # 堆成一串「[重跑]」，把任务名挤出列宽（见
                          # dsapp_rerun_title 的说明）
                          title = dsapp_rerun_title(t$title),
                          session_id = t$session_id,
                          user_id = state$user_id)
      if (!isTRUE(res$ok)) {
        showNotification(res$msg, type = "error", duration = 8)
      } else {
        showNotification(sprintf("已提交任务 #%d", res$task_id),
                         type = "message")
        # V11 item 8：记下"这次重跑该把结果写回哪条对话"。
        # ⚠️ 只有 session_id 真的存在时才记。老任务（或会话被删过的任务）
        #    的 session_id 是 NA/空串，照着写会撞 db_message_add 的外键，
        #    整个面板报错 —— 而"这条任务没有对话"本来就是正常情况，
        #    不是异常，不该用异常去处理它。
        sid <- t$session_id
        if (!is.null(sid) && length(sid) == 1 && !is.na(sid) && nzchar(as.character(sid))) {
          pending_rerun(list(tid = as.integer(res$task_id),
                             sid = as.character(sid),
                             lang = t$lang))
        }
        # 用户手动要的那一下：force —— 数据可能和上一拍一样（比如删掉的
        # 是一条被当前筛选挡在外面的记录），但界面必须动。
        sync_tasks(force = TRUE)
      }
    })

    # ---- 停止正在执行的任务 ----
    #
    # 引擎是**全站单槽**的（见 app.R 里 e$busy）：同一时刻只有一个任务在跑，
    # 所有人的任务排在这一个槽后面。所以这个按钮能停的只有那一个。
    #
    # ⚠️ 两条自我约束，都是"别把别人的东西停掉"：
    #    1. 只停**选中的那条**，选中的不是正在跑的就不动它 —— 用户点错一行
    #       就把自己排了半小时的任务掐掉，这个误伤代价太大。
    #    2. 正在跑的是**别人**的任务时，明确说"停不了"。普通用户没有停别人
    #       任务的权限（这是共享平台，不是他的机器）。
    observeEvent(input$stop, {
      tid <- engine$current_task_id()
      if (is.null(tid)) {
        return(showNotification("当前没有正在执行的任务", type = "message"))
      }
      t <- current()
      if (is.null(t) || !identical(as.integer(t$id), as.integer(tid))) {
        # 正在跑的这个任务在不在**他自己**的列表里？不在就是别人的。
        mine <- tryCatch(
          as.integer(tid) %in% as.integer(
            db_tasks_list(user_id = state$user_id, con = dsapp_db(cfg))$id),
          error = function(e) FALSE)
        return(showNotification(
          if (isTRUE(mine))
            sprintf("正在运行的是任务 #%d —— 先在列表里选中它，再点停止。",
                    as.integer(tid))
          else
            "现在跑的是别人的任务，你只能等它结束或请管理员处理。",
          type = "warning", duration = 8))
      }
      engine$abort(reason = "已手动停止（任务页）")
      showNotification(sprintf("已停止任务 #%d", as.integer(tid)),
                       type = "message")
      sync_tasks(force = TRUE)
    })

    # ---- 删除（V7 item 6：改成多选）-----------------------------------------
    #
    # 原来 DT 是 selection = "single"，只能一条一条删。用户的原话是「任务界面
    # 需要有多选+删除按钮」—— 一段调不通的代码来回改几遍就会攒下十几条失败
    # 记录，一条条点等于罚他做重复劳动。
    #
    # ⚠️ 归属闸门必须**逐条**过。共享给我的对话里的任务能看见但不能删，而
    #    "勾中的一批"里完全可能既有自己的、又有共享来的（同一个列表里）。
    #    只查第一条就放行的话，后面那些会被顺带删掉，而且没有任何提示。

    #' 弹窗那一刻钉住的 id 向量。
    #' ⚠️ 不钉住的话，保存时要回头看 selected_ids() —— 而那玩意儿跟着左侧
    #'    表格的勾选走。用户在弹窗开着的时候又勾了一行（完全做得到，弹窗不挡
    #'    表格），删掉的就是**另一批**，界面上一点异常都看不出来。这个坑
    #'    「共享」那个弹窗踩过，见下面 share_sid 的注释。
    pending_delete <- reactiveVal(NULL)

    #' 一批任务里，这个账号能删的那些
    #'
    #' 返回 list(ok = id 向量, deny = 被拦下的条数)
    delete_scope <- function(ids) {
      n_all <- length(ids)
      df <- tasks()
      k <- match(ids, as.integer(df$id))
      # ⚠️ ids 和 k 必须**同步**筛。只把 k 里的 NA 去掉、ids 原样留着的话，
      #    两个向量就错位了 —— 下面按 can 取子集时取到的是**别的任务**，
      #    而唯一的表现是"删掉了一条我没勾的记录"。
      keep <- !is.na(k)
      ids <- ids[keep]
      k <- k[keep]
      can <- vapply(df$session_id[k], function(s) {
        dsapp_role_can_write(
          db_session_role(s, state$user_id,
                          is_admin = dsapp_user_is_platform_admin(state$user),
                          con = dsapp_db(cfg)))
      }, logical(1))
      # deny 是"勾了但删不了"的总数：查不到的（列表刚被刷掉）也算。
      list(ok = as.integer(ids)[can], deny = n_all - sum(can))
    }

    observeEvent(input$delete, {
      ids <- selected_ids()
      if (length(ids) == 0) {
        # V13.4 item 4：整行都能点了，这句话不再提"方框"（见 output$tbl 里
        # select 的说明）。指路指错比不指路更让人怀疑自己点错了地方。
        showNotification("请先选中要删除的记录（点那一行即可）",
                         type = "warning", duration = 6)
        return()
      }
      sc <- delete_scope(ids)
      if (length(sc$ok) == 0) {
        showNotification(
          "选中的记录都来自别人共享给你的对话，只能查看和下载，不能删除。",
          type = "warning", duration = 8)
        return()
      }
      # 正在跑的那条不能删：引擎还攥着它的 task_id，删了之后
      # app.R 的收尾 observer 会去写一个不存在的行（写不进去，任务状态
      # 永远停在 running），而用户看到的是"我删了它还在跑"。
      running_id <- if (isTRUE(engine$state$running)) engine$state$task_id else NULL
      if (length(running_id) && any(sc$ok == running_id)) {
        sc$ok <- sc$ok[sc$ok != running_id]
        if (length(sc$ok) == 0) {
          return(showNotification(
            sprintf("任务 #%d 正在执行，不能删除 —— 先在列表里勾选它再点「停止」。",
                    as.integer(running_id)),
            type = "warning", duration = 8))
        }
      }
      pending_delete(sc$ok)

      msg <- if (length(sc$ok) == 1L) {
        sprintf("确定删除任务 #%d 的记录吗？（不会删除已产出的文件）",
                as.integer(sc$ok))
      } else {
        sprintf("确定删除勾选的 %d 条执行记录吗？（不会删除已产出的文件）",
                length(sc$ok))
      }
      showModal(modalDialog(
        title = "确认删除",
        p(msg),
        if (sc$deny > 0) p(class = "small text-warning mb-0",
          sprintf("另有 %d 条来自别人共享给你的对话，会被跳过。", sc$deny)),
        p(class = "small text-muted mb-0", "执行记录删了就找不回来了；产物文件不受影响。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_delete"),
                       sprintf("删除 %d 条", length(sc$ok)),
                       class = "btn-danger")
        )
      ))
    })

    observeEvent(input$do_delete, {
      ids <- pending_delete()
      if (is.null(ids) || length(ids) == 0) {
        removeModal()
        return()
      }
      # 再查一次：弹窗开着的这段时间里用户的身份可能已经变了
      # （共享被撤回、管理员改了归属）。上面那道闸门挡的是"打开弹窗"，
      # 这一道挡的才是"真的删"。
      sc <- delete_scope(ids)
      if (length(sc$ok) == 0) {
        removeModal()
        pending_delete(NULL)
        return(deny_shared("删除"))
      }
      n <- 0L
      for (id in sc$ok) {
        ok <- tryCatch({ db_task_delete(id, con = dsapp_db(cfg)); TRUE },
                       error = function(e) FALSE)
        if (ok) n <- n + 1L
      }
      removeModal()
      pending_delete(NULL)
      showNotification(
        if (n == length(sc$ok)) sprintf("已删除 %d 条执行记录", n)
        else sprintf("已删除 %d 条，另有 %d 条删除失败（数据库忙，稍后再试）",
                     n, length(sc$ok) - n),
        type = if (n == length(sc$ok)) "message" else "warning",
        duration = 6)
      sync_tasks(force = TRUE)
    })

    # ---- 勾选状态提示 --------------------------------------------------------

    # 删除按钮上带条数：勾了几条，点下去会删几条 —— 不用用户自己数。
    # ⚠️ 放在独立的 observe 里，不能写进下面的 renderUI：那个 renderUI 读的
    #    就是勾选集合，在它里面再发一条要改 DOM 的消息，Shiny 会报
    #    "output is in an unexpected state"（mod_model.R 的 key_ver 踩过）。
    observe({
      n <- length(selected_ids())
      updateActionButton(session, "delete",
                         label = if (n > 0) sprintf("删除选中（%d）", n)
                                 else "删除选中")
    })

    output$sel_hint <- renderUI({
      n <- length(selected_ids())
      if (n == 0) {
        return(p(class = "small text-muted mt-2 mb-0",
                 "勾选每行最左边的方框可以多选；表头那个方框是全选。"))
      }
      p(class = "small mt-2 mb-0",
        sprintf("已勾选 %d 条。", n),
        if (n > 1L) span(class = "text-muted",
          "「重跑 / 停止 / 共享」和右侧详情只认最上面那一条；「删除选中」会删掉全部勾选的。")
      )
    })

    # ---- 共享（item 7）------------------------------------------------------
    #
    # 用户在这一页想做的事是"把我刚跑出来的这个结果给谁看看"。以前的唯一
    # 办法是把产物发布到文件管理区 —— 那等于把一份**已经脱离上下文**的文件
    # 丢给全站，而且谁都能改。这里改成：选中任务 → 共享给指定账号。
    #
    # ⚠️ 共享的单位是**对话**：任务靠对话的工作区接力（上游写出的文件是
    #    下游的输入），单独给一条任务，对方拿到的是一段读不到输入的代码。
    #    这一点写在弹窗第一句里，不让用户自己猜。
    # ⚠️ 弹窗是**针对哪段对话**开的，必须在开的那一刻钉住。
    #    不钉的话就得在保存时回头看 current() —— 而 current() 跟着左侧表格的
    #    选中行走。用户在弹窗开着的时候点了另一行（完全做得到，弹窗不挡
    #    表格），保存下去的名单就落到**另一个人**的对话上了，界面上一点
    #    异常都看不出来。
    share_sid <- reactiveVal(NULL)

    observeEvent(input$share, {
      t <- current()
      if (is.null(t)) {
        showNotification("请先选择一条记录", type = "warning")
        return()
      }
      sid <- t$session_id
      if (is.null(sid) || length(sid) != 1 || is.na(sid) || !nzchar(as.character(sid))) {
        return(showNotification("这条记录没有归属的对话，无法共享",
                                type = "warning", duration = 8))
      }
      # 打开弹窗之前查一次。和对话页一样：这个按钮只在有权限时才有意义，
      # 但"有没有权限"随时可能变（管理员改了归属），而弹窗里的保存是会
      # 真的写库的。
      if (!dsapp_role_can_write(current_role())) {
        return(deny_shared("共享"))
      }
      # V13 item 3：候选分两拨 —— 同组的列成勾选框，其它账号手填邮箱。
      cand <- dsapp_share_candidates(state, cfg)
      if (nrow(cand$all) == 0) {
        return(showNotification("系统里还没有别的可用账号可以共享", type = "warning"))
      }
      share_sid(sid)
      dsapp_share_modal(
        ns,
        intro = tagList(
          sprintf("共享的是任务 #%d 所在的", as.integer(t$id)), tags$b("整个对话"),
          "—— 它的全部消息、代码和任务，以及本对话产出的文件。",
          tags$b("不能"), "发消息、跑代码、改名或删除。"),
        mates = cand$mates,
        selected = dsapp_share_current_ids(sid, cfg),
        others = cand$others)
    })

    observeEvent(input$do_share, {
      sid <- share_sid()
      if (is.null(sid)) {
        removeModal()
        return(showNotification("没记住这次要共享哪段对话，请重新点一次共享",
                                type = "warning", duration = 8))
      }
      # 写库之前**再**查一次权限 —— 查的是**钉住的那段对话**，不是当前
      # 选中的那行（两者可能已经不是一回事了）。而且没权限要 return：
      # 只关个弹窗接着写等于没有这道闸门。selftest 里有一条专门查这个
      # 位置关系的断言（闸门必须排在写库之前、且里面真的 return）。
      # 查不动角色时它返回 none（拦），这个默认值本身由 selftest 盯着 ——
      # 见 R/share.R 的 dsapp_share_role。
      role <- dsapp_share_role(sid, state, cfg)
      if (!dsapp_role_can_write(role)) {
        removeModal()
        return(deny_shared("共享"))
      }
      col <- dsapp_share_collect(input$share_ids, input$share_emails,
                                 state$user_id, con = dsapp_db(cfg))
      n <- dsapp_share_save(sid, col$ids, state, cfg)
      removeModal()
      if (is.null(n)) return()
      dsapp_share_notify(col, n)
    })

    observeEvent(input$refresh, sync_tasks(force = TRUE))
  })
}

#' 列出工作目录里的产物
#'
#' 递归、文件和目录都列。工作区有子目录之后（V5），只列顶层会把模型写进
#' `results/` 的图整个漏掉 —— 而"这个任务到底产出了什么"正是这一页
#' 存在的理由，漏掉比列错更糟。
#'
#' ⚠️ 目录也要列（V8 item 7）：这一页就是用户回头查"模型到底建没建那个
#'    文件夹"的地方，只列文件的话，一个空文件夹在这里也是隐形的 ——
#'    而"目录是空的"恰恰是唯一需要来这里确认的情况。
dsapp_artifacts_of <- function(workdir) {
  if (is.null(workdir) || is.na(workdir) || !dir.exists(workdir)) return(character(0))
  # dsapp_ws_snapshot 不跟软链（上传区镜像进来的只读输入不是产物），
  # 给的是相对路径，子目录里的一眼能看出在哪。
  fs <- dsapp_ws_snapshot(workdir, dirs = TRUE)
  fs <- fs[!dsapp_ws_is_internal(fs)]
  if (length(fs) == 0) return(character(0))

  info <- file.info(file.path(workdir, fs))
  keep <- !is.na(info$size)
  fs <- fs[keep]; info <- info[keep, , drop = FALSE]
  if (length(fs) == 0) return(character(0))
  is_dir <- !is.na(info$isdir) & info$isdir
  # 目录不加大小：file.info 给的是目录项自己的 4096，跟里面装了多少东西
  # 无关，写"4.0 KB"是在骗人。目录只标一个 `/`。
  sz <- ifelse(is_dir, "", paste0(" (",
              vapply(info$size, dsapp_fmt_bytes, character(1)), ")"))
  sprintf("%s%s", ifelse(is_dir, paste0(fs, "/"), fs), sz)
}
