# =============================================================================
# 环境页
# =============================================================================
# 这一页的模型是**两层**，V5 定下来的：
#
#   基础环境（可选、可删）—— 所有对话共用的那一层。系统 R / Python，或者
#     一个 conda 环境。选它写在 state$exec_env 里，**会话级**生效（跟着
#     浏览器标签页走，不跟着对话走），界面上如实写着这一点。
#
#   对话环境（自动创建）—— 每个对话自己叠加的一层：R 库（.Rlib）和 Python
#     虚拟环境（.venv），首次执行该语言的代码时自动建。代码里
#     `install.packages()` / `pip install` 装的东西落进这一层，只对这个
#     对话可见。装坏了这页上有一键清空。
#
# ---- 这段历史值得留着，因为"选环境"被撤过又加回来过 ----------------------
#
# V4 曾按 item 4「环境不需要用户选择，在后台执行任务的时候自动生成即可」
# 把"选环境"整个撤掉。那个判断有一半是对的，但撤过头了：
#
#   * 对的那半：**全局共享的 conda 环境当默认执行环境**是错的。A 建了
#     scRNA 环境、B 往里 pip install，改的是同一份；B 的包覆盖了 A 依赖的
#     版本，A 的分析会在某天开始产出不一样的结果，且没有任何地方记录过
#     "那天环境被改过"。所以对话环境必须独立成层 —— .Rlib / .venv 就是
#     答案，这一层没有回退。
#   * 过头的半：把"基础环境"也一并锁死，用户就再也换不了底了。而这台机器
#     上那 18 GB 的生信包（Seurat / DESeq2 / Bioconductor 全家）装在
#     /usr/local/lib/R/site-library，属于**系统 R** —— 用户想换到一个
#     conda 环境上跑是很自然的需求。V5 把选择权还回来，但**只还到基础环境
#     这一层**：选中的环境是底，对话自己的那一层照旧叠加在它上面，隔离性
#     一点没少。
#
#   所以这一页现在是"能选、能删"，而不是 V3 那种"能建、能装、能选、能删"。
#   建和装为什么仍然没有界面入口，见文件末尾那段。
# =============================================================================

mod_envs_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "dsapp-page",
      # ---- 说明 ----
      card(
        card_header(icon("circle-info"), " 关于环境"),
        card_body(
          class = "py-2",
          p(class = "mb-2",
            "环境分两层。", tags$b("基础环境"), "是这台服务器上装好的那套",
            "（系统 R / Python，或者一个 conda 环境）—— 所有对话默认都用它。",
            tags$b("对话环境"), "是每个对话自己的一层，叠加在基础环境之上：",
            "你在某个对话里装的包只落在那个对话里。"),
          p(class = "mb-2",
            "要装额外的包（scanpy、Seurat、特定版本的 bioconductor 包……），",
            tags$b("直接让 AI 在代码里装就行"), " —— 它装进的是这个对话自己的",
            "那一层，不会影响别的对话，也不会影响服务器的系统环境。"),
          div(class = "dsapp-warn",
            icon("shield-halved"),
            " 对话之间互相隔离：你在一个对话里装的包，另一个对话看不见。")
        )
      ),

      # ---- 基础环境：选 / 删 ----
      card(
        card_header(
          class = "d-flex justify-content-between align-items-center",
          span(icon("microchip"), " 基础环境"),
          actionButton(ns("base_refresh"), NULL, icon = icon("rotate"),
                       class = "btn-sm btn-outline-secondary",
                       title = "重新扫描磁盘上的环境")
        ),
        card_body(
          class = "py-2",
          uiOutput(ns("base_env_ui"))
        )
      ),

      # ---- 新建环境（V12 item 4）----
      card(
        card_header(
          class = "d-flex justify-content-between align-items-center",
          span(icon("wand-magic-sparkles"), " 新建环境"),
          span(class = "small text-muted fw-normal",
               "内置模板 / 上传配置 / 一键创建")
        ),
        card_body(
          class = "py-2",
          uiOutput(ns("create_ui"))
        )
      ),

      # ---- 对话环境：选一个对话看 / 删 ----
      card(
        card_header(icon("box-archive"), " 对话环境"),
        card_body(
          class = "py-2",
          uiOutput(ns("pick_ui")),
          uiOutput(ns("ws_env_card"))
        )
      )
    )
  )
}

#' @param engine 全局执行引擎。用来挡住"任务正在跑，却去重建它的包目录"
#'   这种操作（见下面 ws_reset 的说明）。
mod_envs_server <- function(id, state, engine = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ⚠️ 这一行不能省，而且**不能**指望外层那个 cfg。
    #
    # app.R 顶上的 `cfg <- dsapp_config()` 是在 Shiny 的 app 环境里求值的，
    # 而 R/*.R 是用 source(local = globalenv()) 载入的 —— 这些函数的作用域
    # 是 globalenv，看不见 app 环境里的 cfg。少这一行的表现是：打开一个对话
    # 之后「环境」页整页变成一个 Error（"object 'cfg' not found"），
    # 没有对话时反而正常 —— 因为 dsapp_session_lib_status() 在没有 sid 时
    # 提前 return，压根没走到用 cfg 的那行。
    #
    # 其他四个模块都是各自在 server 里取一次配置，这里是唯一漏掉的。
    cfg <- dsapp_config()

    # =========================================================================
    # 基础环境：选一个来跑，删掉不要的
    # =========================================================================
    # V5 加回来的。V4 曾按 item 4「环境不需要用户选择」把这一整块撤掉，
    # 但那是**过头**了：item 4 要的是"每个对话有自己的环境、不用用户操心"，
    # 不是"用户永远不能碰环境"。两件事并不冲突 ——
    #
    #   基础环境（这一块）  = 所有对话共用的那一层，**可以选、可以删**
    #   对话环境（下面那块）= 每个对话自己叠加的一层，自动创建
    #
    # 选择写在 state$exec_env 里，是**会话级**的（跟着这个浏览器标签页走，
    # 不跟着对话走）—— 这一点在界面上如实写着，不装作是每对话独立。
    # app.R 的 e$start() 会拿它去校验环境还在不在，executor 用它挑解释器，
    # prompts.R 的 build_environment_section() 用它决定告诉模型"装了什么包"。
    base_refresh <- reactiveVal(0)

    # ⚠️ sizes = TRUE 会走一整棵目录树（实测一个环境几万个文件、6 秒上下）。
    #    所以**默认不算**，只有用户显式点了「统计占用」才算一次，之后靠
    #    dsapp_env_sizes_cached 的 10 分钟 TTL 兜着。绝不能让页面一渲染就
    #    去 du —— 这里卡住的是全站共用的那一个 R 进程。
    sz_on     <- reactiveVal(FALSE)
    sz_tick   <- reactiveVal(0)
    count_dir <- reactiveVal(0)   # 「统计占用」把结果带出来用的脉冲

    base_envs <- reactive({
      base_refresh()
      dsapp_envs_list(cfg, sizes = isTRUE(sz_on()))
    })

    output$base_env_ui <- renderUI({
      # ⚠️ 这一句是**必须**的：光算 dsapp_envs_list() 不会让 selftest 之外
      #    的任何人受益，而下面那句 isolate(state$exec_env) 才是重点 ——
      #    state 是 reactiveValues，在 renderUI 里裸读会把"用户切了环境"
    #    变成这张卡片的重渲染源。重建 radioButtons 会让刚点下的选择闪一下，
    #    极端情况下还会把值冲成 NULL。isolate + 手动脉冲，模式同 mod_chat。
      cur <- isolate(state$exec_env %||% "system")
      sz_tick()                      # 「统计占用」点过之后重画一次
      df  <- base_envs()

      # 先拼选项：系统环境永远排第一，然后是磁盘上扫到的 conda 环境
      #
      # ⚠️⚠️ **名字是给人看的，值是给机器用的** —— 别写反了。
      #    Shiny 的 selectInput/radioButtons 认的是 `c(标签 = 值)`：向量里的
      #    **值**变成 <option value="...">（也就是回传给服务端的那个），
      #    **名字**变成显示文本。这一行原来写的是
      #    `c("system" = dsapp_env_summary("system", cfg))` —— 反的。
      #    后果不是"显示得难看"：控件回传的是那句中文摘要
      #    （"系统环境（服务器上已装的 R / Python）"），于是
      #    state$exec_env 被写成这句话 → 执行器拿它去查 conda 环境 →
      #    每次都报"选定的 conda 环境 系统环境…不存在"，**任何任务都跑不起来**。
      #    见 utils.R 的 dsapp_choices() 和 selftest 的「选项方向」一节。
      choices <- dsapp_choices("system", dsapp_env_summary("system", cfg))
      if (nrow(df) > 0) {
        for (i in seq_len(nrow(df))) {
          nm  <- df$name[[i]]
          bits <- c(dsapp_env_summary(nm, cfg),
                    switch(df$status[[i]],
                           ready   = NULL,
                           building = "构建中",
                           failed   = "上次构建失败",
                           df$status[[i]]),
                    if (!is.na(df$size_mb[[i]]))
                      dsapp_fmt_bytes(df$size_mb[[i]] * 1024^2),
                    if (nzchar(df$mtime[[i]])) paste0(df$mtime[[i]], " 更新"))
          # 同上：值（回传的）= 环境名，名字（显示的）= 那串描述
          choices <- c(choices, dsapp_choices(nm, paste(bits, collapse = " · ")))
        }
      }
      # cur 是**值**（"system" 或环境名），所以要跟 unname() 比。
      # 这里原来是 names(choices) —— 在旧的（写反的）写法下它歪打正着能对上，
      # 方向改回来之后必须跟着改，否则系统环境那一项永远匹配不上，
      # selected 会被硬拨回 "system"：用户在环境页选了 A，一刷新跳回系统环境。
      if (!(cur %in% unname(choices))) cur <- "system"

      # ★ V13.5 item 6：「单细胞与空转环境也请预置」。
      #
      #   这两份内置模板（envs.R 的 dsapp_env_templates()）以前只在「新建
      #   环境」那个下拉框里露面，而那一栏的默认选项是**第一个模板**，用户
      #   多半直接把编辑器里的文本点掉了 —— 结果就是"单细胞 / 空转"这两个
      #   最常用的环境一直没人建，磁盘上 data/envs/ 是空的，基础环境列表里
      #   当然也看不到它们。
      #
      #   这里把"还没建的内置环境"直接摆到基础环境列表底下，一键可建。
      #   ⚠️ 建的动作**不在这里重写**：走的是「新建环境」那张卡片同一条路
      #      （dsapp_env_create_from_template → create_target/create_poll），
      #      进度和"建好之后自动刷新"都由那一套现成的逻辑负责。
      #
      #   ⚠️ have = df$name：上面刚算过，别再让 dsapp_env_templates_pending()
      #      自己扫一遍 conda（见 envs.R 里那个参数的说明）。
      pend <- tryCatch(
        dsapp_env_templates_pending(cfg, have = as.character(df$name)),
        error = function(e) list())

      n_conda <- nrow(df)
      tagList(
        div(class = "small text-muted mb-2",
          "代码默认在", tags$b("系统环境"), "里执行。选一个 conda 环境的话，",
          "所有对话都会以它为底 —— 对话自己装的那一层仍然叠加在它上面。",
          "这个选择", tags$b("只对当前浏览器生效"), "，换台电脑要重选一次。"),

        # ★ V13.5 item 6（前半）：「系统环境（服务器上已装的 R / Python）」
        #   这行莫名其妙换行。
        #
        #   根因不在文字长度：shiny 给每个输入控件套了一层
        #   `.shiny-input-container`，**默认宽度 300px**。radioButtons 没传
        #   width 时就是 300 —— 那句摘要 21 个字加括号里的英文，300px 装不下，
        #   于是折成两行，看着像"这里出了什么怪事"。
        #   传 width = "100%" 放开钳制，再用 .dsapp-radio-nowrap 强制单行 +
        #   横向滚动（宁可滑，也不要折行）—— 和列表那边的做法一致。
        div(class = "dsapp-radio-nowrap",
          radioButtons(ns("env_pick"), NULL, choices = choices,
                       selected = cur, width = "100%")),

        div(class = "d-flex gap-2 flex-wrap align-items-center",
          actionButton(ns("env_use"), "用这个环境跑",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("check")),
          actionButton(ns("env_delete"), "删除选中的环境",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("trash")),
          actionButton(ns("size_scan"), "统计占用",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("ruler")),
          span(class = "small text-muted",
               if (n_conda == 0)
                 "磁盘上还没有 conda 环境。"
               else if (!isTRUE(sz_on()))
                 sprintf("%d 个 conda 环境（占用大小要点「统计占用」才算）", n_conda)
               else
                 sprintf("%d 个 conda 环境", n_conda))
        ),

        div(class = "dsapp-warn mt-2 small",
          icon("circle-info"),
          " 现在用的是：", tags$b(dsapp_env_summary(cur, cfg)),
          if (!identical(cur, "system"))
            "。删掉它就会退回系统环境。" else ""),

        # ---- 还没建的内置环境：一键预置（V13.5 item 6）----
        if (length(pend)) {
          div(class = "dsapp-tpl-pending mt-3 pt-2",
            div(class = "small text-muted mb-2",
              icon("box-open"),
              " 这两个常用环境还没建，点一下就能装（依赖解析几分钟到十几分钟，",
              "可以离开这一页）："),
            div(class = "d-flex flex-wrap gap-2",
              lapply(names(pend), function(key) {
                t  <- pend[[key]]
                nm <- as.character(t$name %||% "")
                if (!nzchar(nm)) return(NULL)
                actionButton(ns(paste0("tpl_mk_", nm)),
                             sprintf("创建「%s」", key),
                             class = "btn-sm btn-outline-primary",
                             icon = icon("circle-plus"),
                             title = sprintf("conda 环境名：%s，约 %d 个包",
                                             nm, length(t$packages %||% character(0))))
              })
            )
          )
        },
        uiOutput(ns("tpl_mk_progress"))
      )
    })

    observeEvent(input$env_pick, {
      # 只改 state，不做别的。不在这里顺手刷新列表 —— 那会让"点一下选项"
      # 触发一次重渲染，而重渲染又会把选择写回去，绕成一个环。
      #
      # ⚠️ 只认"我们列出去过的值"。选项的显示文本/回传值写反时，这里收到的
      #    是那句中文摘要，它会被写进 state$exec_env 并让**所有任务**报
      #    "环境不存在"。见 envs.R 的 dsapp_env_selectable()。
      if (!is.null(input$env_pick) && nzchar(input$env_pick) &&
          !dsapp_env_selectable(input$env_pick, cfg)) {
        showNotification(
          sprintf("忽略了一个无法识别的环境选项（%s）—— 界面上显示的名字被当成值回传了，请截图给管理员。",
                  input$env_pick),
          type = "error", duration = 12)
        return(invisible(NULL))
      }
      if (!is.null(input$env_pick) && nzchar(input$env_pick)) {
        state$exec_env <- input$env_pick
        # 选了具体环境就意味着"在服务器上跑"，把目标机也拨回 server ——
        # 否则用户会看到"本地电脑 + conda 环境 scRNA"这种自相矛盾的组合。
        state$exec_target <- "server"
      }
    }, ignoreNULL = TRUE)

    observeEvent(input$env_use, {
      nm <- input$env_pick %||% "system"
      # 同一道守卫（这条是"用这个环境跑"，写进去的后果一样重）
      if (!dsapp_env_selectable(nm, cfg)) {
        showNotification(
          sprintf("这个选项无法识别（%s），没有切换环境。请截图给管理员。", nm),
          type = "error", duration = 12)
        return(invisible(NULL))
      }
      state$exec_env <- nm
      state$exec_target <- "server"
      showNotification(sprintf("这个浏览器之后的任务会在「%s」里执行",
                               dsapp_env_summary(nm, cfg)),
                       type = "message", duration = 6)
    })

    observeEvent(input$size_scan, {
      sz_on(TRUE)
      sz_tick(sz_tick() + 1)
      showNotification("正在统计占用，环境大的话要几秒", type = "message")
    })

    observeEvent(input$base_refresh, {
      # 手动刷新时把大小缓存也作废：用户点了刷新多半就是因为刚装完包。
      st <- dsapp_state()
      if (!is.null(st$env_sizes)) rm(list = ls(st$env_sizes), envir = st$env_sizes)
      base_refresh(base_refresh() + 1)
      sz_tick(sz_tick() + 1)
    })

    # ---- 删除基础环境 ----
    observeEvent(input$env_delete, {
      nm <- input$env_pick %||% ""
      exists <- !identical(nm, "system") && dsapp_env_exists(nm, cfg)
      reason <- dsapp_env_delete_reason(
        nm, exists = exists, busy = dsapp_env_busy(),
        # 正在跑的任务用的是提交那一刻的 exec_env。任务行里存的 target 是
        # 给人看的标签、不是环境名，反解它太脆；拿当前值判已经够用。
        running_env = if (is.null(engine) || is.null(engine$current_task_id()))
                        NULL else (state$exec_env %||% "system"))
      if (nzchar(reason)) {
        return(showNotification(reason, type = "warning", duration = 8))
      }
      p <- dsapp_env_path(nm, cfg)
      showModal(modalDialog(
        title = "确认删除环境",
        p(sprintf("确定删除 conda 环境 %s 吗？", nm)),
        tags$ul(class = "small",
          tags$li("环境目录 ", tags$code(p), " 会被整个删掉。"),
          tags$li("已装进这个环境的包需要重装。"),
          tags$li("对话里的代码、对话自己装的包、产出文件", tags$b("都不受影响"), "。")
        ),
        if (identical(state$exec_env %||% "system", nm))
          div(class = "dsapp-warn",
              icon("triangle-exclamation"),
              " 这个环境正在被当前浏览器使用，删掉之后会自动退回系统环境。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_env_delete"), "删除", class = "btn-danger")
        )
      ))
    })

    observeEvent(input$do_env_delete, {
      nm <- input$env_pick %||% ""
      r <- dsapp_env_delete(nm, cfg)
      removeModal()
      if (!isTRUE(r$ok)) {
        return(showNotification(r$msg, type = "error", duration = 8))
      }
      # 删掉的正好是当前在用的 → 退回系统环境。不退的话用户的下一个任务
      # 会撞上 app.R 里那道"环境不存在"的校验，报的错还指向一个刚被他自己
      # 删掉的名字。
      if (identical(state$exec_env %||% "system", nm)) {
        state$exec_env <- "system"
      }
      st <- dsapp_state()
      if (!is.null(st$env_sizes)) rm(list = ls(st$env_sizes), envir = st$env_sizes)
      base_refresh(base_refresh() + 1)
      sz_tick(sz_tick() + 1)
      # ★ V13.4 item 7：删掉的环境要从**言出法随页**的下拉框里消失。
      #   那个下拉同样是冻住的，得在这里推它一下（另一边在建好时推）。
      st$env_rev <- (st$env_rev %||% 0L) + 1L
      showNotification(r$msg, type = "message", duration = 6)
    })

    # =========================================================================
    # 新建环境（V12 item 4）
    # =========================================================================
    # 用户原话：「环境也要像 skills 一样可以自动上传配置，帮我预设单细胞/
    # 空转环境」。所以这块的用法和技能页的上传是**同一套**：给一份文本
    # （或者选一个内置模板），看一眼解析出来的结果，点一下建。
    #
    # ⚠️ 建环境是**几分钟到十几分钟**的 conda solve，而本站一个应用只有一个
    #    R 进程、所有访客共享（见 envs.R 顶部）。所以：
    #      * 绝不在这里同步等 —— 走 dsapp_env_create()，它内部是后台作业
    #      * 进度靠轮询日志尾巴（dsapp_env_progress，它自己只读最后 64 KB）
    #      * 关掉页面不影响创建：作业是独立进程，状态文件落在 logs/ 里
    #
    # ⚠️ 这块以前**故意没有界面入口**（V3 有、item 4 撤了，理由写在文件末尾
    #    那段）。现在加回来的前提是后台作业那套东西已经齐了 —— 没有它的话，
    #    点一下按钮就是全站冻住二十分钟，那才是当初撤掉它的真正原因。
    tpl_all <- dsapp_env_templates()
    tpl_names <- names(tpl_all)

    # 这次创建的进度。create_target 一旦有值，下面那个 observe 就开始轮询。
    create_target <- reactiveVal(NULL)
    create_poll   <- reactiveVal(FALSE)
    create_state  <- reactiveVal(NULL)
    # ★ V13.5 item 6：这次创建是**从哪张卡片**起的。
    #
    #   两张卡片（基础环境的「创建「单细胞」」/「创建「空转」」，和新建环境
    #   的「一键创建」）共用同一个 create_target，进度块就有两处能显示它。
    #   不记来源的话，从基础环境点一下，同一句"正在创建 scRNA…"会在上下
    #   两张卡片里各出现一次 —— 用户会以为开了两个作业。
    #
    #   "panel" = 新建环境那张卡片，"base" = 基础环境卡片。
    #   ⚠️ 只影响**显示**：作业只有一个，轮询也只有一个（下面那个 observe）。
    create_from <- reactiveVal("panel")

    # ★ V13.5 item 6：基础环境卡片里那两个「创建」按钮（单细胞 / 空转）。
    #
    #   建的动作和「新建环境」那张卡片**走同一条路** —— 同样是
    #   dsapp_env_create_from_template()，同样把 create_target/create_poll
    #   立起来，于是进度显示、"建好之后自动刷新基础环境列表""通知言出法随页
    #   那个下拉框"这些全部由下面那一个 observe 负责，这里不重写第二份。
    #
    # ⚠️ 观察者一次性注册（模板表是写死的常量）。**不要**改成在
    #    output$base_env_ui 里 lapply(observeEvent) —— renderUI 每重画一次
    #    就叠一层观察者，点一下按钮会建出 N 个同名环境（第二个起全部撞
    #    "已经有一个同名的了"校验，用户看到的是一串莫名其妙的报错）。
    #
    # ⚠️ id 里用模板的 **name**（scRNA / spatial，纯 ASCII），不是「单细胞」
    #    那个中文键 —— 中文要进 HTML 的 id 属性，选择器和转义都跟着变麻烦。
    mk_builtin <- function(nm) {
      df   <- isolate(base_envs())
      pend <- tryCatch(
        dsapp_env_templates_pending(cfg, have = as.character(df$name)),
        error = function(e) list())
      hit <- Filter(function(t) identical(as.character(t$name %||% ""), nm), pend)
      if (!length(hit)) {
        # 竞态：列表是上一次渲染时算的，这中间可能已经在「新建环境」里
        # 把它建了（或者正在建）。这时候什么都不做 —— 再发一次创建会撞校验。
        return(showNotification(sprintf("内置环境 %s 已经建好了。", nm),
                                type = "message", duration = 8))
      }
      r <- dsapp_env_create_from_template(hit[[1]], cfg)
      if (!isTRUE(r$ok)) {
        return(showNotification(r$msg %||% "没能开始创建",
                                type = "error", duration = 12))
      }
      create_from("base")
      create_target(nm)
      create_state(NULL)
      create_poll(TRUE)
      showNotification(
        sprintf("已开始创建内置环境 %s（%s）。可以离开这一页，建好之后它会自己出现在上面。",
                nm, names(hit)[[1]]),
        type = "message", duration = 12)
    }

    for (.key in tpl_names) {
      local({
        key <- .key
        nm  <- as.character(tpl_all[[key]]$name %||% "")
        if (nzchar(nm)) {
          observeEvent(input[[paste0("tpl_mk_", nm)]],
                       mk_builtin(nm), ignoreInit = TRUE)
        }
      })
    }

    # 编辑器的初值 = 第一个模板。**只在渲染那一次取**（下面 create_ui 是
    # 一次性渲染的 renderUI，里面全是常量，没有任何响应式依赖）。
    tpl_seed <- dsapp_env_template_text(tpl_all[[tpl_names[[1]]]])

    output$create_ui <- renderUI({
      tagList(
        div(class = "small text-muted mb-2",
          "选一个内置模板，或者上传一份自己的配置（", tags$code("conda env export"),
          " 导出的 ", tags$code(".yaml"), " 也认）。下面那个框可以直接改，",
          "改完点「一键创建」。"),
        div(class = "dsapp-warn mb-2",
          icon("triangle-exclamation"),
          " 建的是", tags$b("全站共享"), "的 conda 环境：建好之后所有对话都能",
          "选它当基础环境。依赖解析要几分钟到十几分钟，期间可以照常用别的页面，",
          "关掉这一页也不影响。"),
        # ★ V13.4 item 2：「内置模板」和「上传配置」两栏没对齐。
        #
        #   原来是 align-items-end（底边对齐），而右栏的 fileInput 除了控件
        #   本身，底下还挂着一个 `<div class="progress shiny-file-input-progress">`
        #   （shiny::fileInput 自带的进度条，平时不显示但**占位**）。右栏因此
        #   比左栏高出一截，底边对齐就把左栏的下拉整个往下顶 —— 看起来就是
        #   两个控件错开。改成顶边对齐：两边的 label 是一样的
        #   `<label class="control-label">`、都是单行，所以 label 齐平、控件
        #   自然落在同一条水平线上，进度条自己往下垂着不影响任何人。
        #
        #   ⚠️ 别改回 align-items-end，也别去给进度条写 display:none ——
        #      上传真在跑的时候是要靠它显示进度的。
        div(class = "row g-2 align-items-start",
          div(class = "col-12 col-md-5",
            selectInput(ns("tpl_pick"), "内置模板", width = "100%",
                        choices = tpl_names, selected = tpl_names[[1]])),
          div(class = "col-12 col-md-7",
            fileInput(ns("spec_file"), "上传配置（可选）", width = "100%",
                      accept = c(".yaml", ".yml", ".txt", ".env", ".json"),
                      buttonLabel = "选择文件", placeholder = "还没选文件"))
        ),
        textAreaInput(ns("spec_text"), "配置内容", value = tpl_seed,
                      rows = 12, width = "100%",
                      resize = "vertical"),
        uiOutput(ns("spec_preview")),
        uiOutput(ns("create_progress"))
      )
    })

    # 换模板 → 把模板文本灌进编辑器。
    #
    # ⚠️ 这里**会覆盖用户在编辑器里的改动**。这是有意的：那个下拉框写着
    #    「内置模板」，选它就是在说"用这一份"。做成"只在编辑器为空时才灌"
    #    的话，用户改完一版想回到模板，会发现选下拉框没反应 —— 那才是真正
    #    说不通的行为。
    observeEvent(input$tpl_pick, {
      tpl <- tpl_all[[input$tpl_pick]]
      if (is.null(tpl)) return()
      updateTextAreaInput(session, "spec_text",
                          value = dsapp_env_template_text(tpl))
    }, ignoreNULL = TRUE)

    # 上传配置文件 → 读出来灌进编辑器。
    #
    # ⚠️ fileInput 的值**清不掉**（Shiny 的老问题，input$spec_file 会一直
    #    留着上一次那个文件）。所以同一个文件改完再传一次**不会触发**这个
    #    observer —— 用户会以为"传了没反应"。这是已知的、可接受的：改内容
    #    直接在下面那个框里改就行，那个框本来就是可编辑的。
    observeEvent(input$spec_file, {
      f <- input$spec_file
      if (is.null(f) || nrow(f) == 0) return()
      if (isTRUE(f$size[[1]] > 1024 * 1024)) {
        return(showNotification("这个文件超过 1 MB，多半不是一份环境配置",
                                type = "error", duration = 8))
      }
      txt <- dsapp_read_text_file(f$datapath[[1]])
      if (is.null(txt)) {
        return(showNotification("读不出来这个文件", type = "error", duration = 8))
      }
      updateTextAreaInput(session, "spec_text", value = txt)
      showNotification(sprintf("已载入 %s，下面确认一下再建", f$name[[1]]),
                       type = "message", duration = 6)
    })

    # 解析结果。编辑器里每一次改动都会重算 —— 解析几百行文本是微秒级的事，
    # 换来的是"边改边看到解析成什么样"，比点一下「预览」按钮直接得多。
    spec <- reactive({
      dsapp_envspec_parse(input$spec_text %||% tpl_seed)
    })
    spec_check <- reactive({ dsapp_envspec_check(spec(), cfg) })

    output$spec_preview <- renderUI({
      s <- spec()
      ck <- spec_check()
      if (!isTRUE(s$ok)) {
        return(div(class = "dsapp-warn mt-2",
          icon("circle-xmark"), " ", ck$msg %||% s$msg))
      }
      div(class = "mt-2",
        div(class = "small",
          span(class = "text-muted", "环境名 "), tags$b(s$name),
          span(class = "text-muted", " · Python "), tags$b(s$python),
          span(class = "text-muted", " · 频道 "),
          tags$b(paste(s$channels, collapse = ", ")),
          span(class = "text-muted", sprintf(" · %d 个包", length(s$packages)))),
        # 包名逐个列出来。不列的话，解析器把清单读歪了（比如把注释当包名）
        # 用户是看不出来的 —— 而 conda 会照着这份清单跑二十分钟再失败。
        div(class = "small text-muted mt-1",
            paste(utils::head(s$packages, 40), collapse = " "),
            if (length(s$packages) > 40)
              sprintf(" …… 还有 %d 个", length(s$packages) - 40)),
        if (length(s$notes)) {
          div(class = "small text-muted mt-1",
              icon("circle-info"), " ", dsapp_md_inline(paste(s$notes, collapse = "；")))
        },
        if (length(ck$warn)) {
          div(class = "small text-muted mt-1",
              lapply(ck$warn, function(w) div(icon("circle-info"), " ", dsapp_md_inline(w))))
        },
        if (!isTRUE(ck$ok)) {
          div(class = "dsapp-warn mt-2", icon("circle-xmark"), " ", ck$msg)
        },
        div(class = "d-flex gap-2 align-items-center mt-2",
          if (isTRUE(ck$ok))
            actionButton(ns("spec_create"), "一键创建",
                         class = "btn-primary",
                         icon = icon("wand-magic-sparkles"))
          else
            tags$button(class = "btn btn-primary", type = "button",
                        disabled = "disabled", "一键创建"),
          span(class = "small text-muted",
               if (isTRUE(ck$ok))
                 "点下去就开始解依赖，大概几分钟到十几分钟"
               else "上面这条处理掉就能建了")
        )
      )
    })

    observeEvent(input$spec_create, {
      s <- spec()
      ck <- spec_check()
      if (!isTRUE(ck$ok)) {
        return(showNotification(ck$msg, type = "error", duration = 10))
      }
      r <- dsapp_env_create(s$name, s$packages,
                            python_version = s$python,
                            channels = s$channels, cfg = cfg)
      if (!isTRUE(r$ok)) {
        return(showNotification(r$msg, type = "error", duration = 12))
      }
      create_from("panel")
      create_target(s$name)
      create_state(NULL)
      create_poll(TRUE)
      showNotification(
        sprintf("已开始创建环境 %s。可以离开这一页，建好之后在「基础环境」里选它。",
                s$name),
        type = "message", duration = 12)
    })

    # 轮询进度。只有 create_poll 为真时才每 2 秒醒一次 —— 建完之后立刻
    # 停掉，不留一个永远在跑的定时器（这一页平时是没人看的）。
    #
    # dsapp-selftest: self-reactive-ok create_poll
    #
    #   ⚠️ 上面那行是给 selftest 的显式豁免，不是注释装饰。这个 observe **读**
    #      create_poll（决定要不要继续定时）又**写**它（建完置 FALSE 停下来），
    #      按"自失效"那条规则会被扫出来。它不会失控的理由：写 FALSE 之后下一轮
    #      `isTRUE(create_poll())` 就是假，那个 if 整个不进去，也就不会再写 ——
    #      多跑一轮就停。**这条理由要是哪天被改动推翻了，豁免就得跟着撤掉。**
    #      （旁边 base_refresh / sz_tick 的读已经 isolate 了，见下。）
    observe({
      nm <- create_target()
      if (is.null(nm)) return()
      if (isTRUE(create_poll())) invalidateLater(2000)
      pr <- tryCatch(dsapp_env_progress(nm, cfg), error = function(e) NULL)
      if (is.null(pr)) return()
      create_state(pr)
      if (isTRUE(pr$done) && isTRUE(create_poll())) {
        create_poll(FALSE)
        if (isTRUE(pr$ok)) {
          showNotification(
            sprintf("环境 %s 建好了 —— 在「基础环境」里选它就能用", nm),
            type = "message", duration = 15)
        } else {
          showNotification(
            sprintf("环境 %s 没建起来，下面的日志末尾有原因", nm),
            type = "error", duration = 20)
        }
        # 新环境要出现在「基础环境」的列表里。大小缓存也一起作废 ——
        # 用户接下来最可能做的事就是点「统计占用」看它多大。
        st <- dsapp_state()
        if (!is.null(st$env_sizes)) rm(list = ls(st$env_sizes), envir = st$env_sizes)
        # ⚠️ 读的那一侧 isolate：这两个值在这里只是**通知**（加一让别人重画），
        #    这个 observe 根本不需要依赖它们。不 isolate 就是白白多一次自失效
        #    —— 眼下被 create_poll(FALSE) 那道门挡着不会失控，但那属于碰巧。
        base_refresh(isolate(base_refresh()) + 1)
        sz_tick(isolate(sz_tick()) + 1)
        # ★ V13.4 item 7：也要告诉**言出法随页**那个下拉框。
        #   它平时是渲染一次就冻住的（理由见 mod_chat.R 里那段），
        #   不主动通知的话，用户建完环境切回对话页，下拉里还是老样子。
        #
        # ⚠️ 读的那一侧 isolate —— 和 mod_chat.R 里那条轮询同一个道理：
        #    这个 observe 只要**读**了 env_rev，它就成了 env_rev 的依赖，
        #    而它自己又写 env_rev。这里眼下不会失控（上面 create_poll(FALSE)
        #    已经把再入的门关上了），但那是**碰巧**：哪天有人把那个条件挪一
        #    下，就是无上限的自失效循环，整个 R 进程卡死、所有人白屏。
        #    写成 isolate 之后，"读"这件事不再建立依赖，也就不依赖那个巧合。
        st$env_rev <- isolate(st$env_rev %||% 0L) + 1L
      }
    })

    # 进度块本身。抽成函数是因为**两个地方**要显示它：
    # 「新建环境」卡片里的 create_progress，和「基础环境」卡片里那两个
    # 一键预置按钮下面的 tpl_mk_progress（V13.5 item 6）。同一个
    # create_target() 在两个卡片里都要看得见 —— 从哪张卡片点的，就在哪张
    # 卡片里看着它跑完。写两份的话，"日志尾部"那段迟早只改一边。
    progress_ui <- function(nm, pr) {
      if (is.null(pr)) {
        return(div(class = "mt-2 small text-muted",
                   icon("spinner", class = "fa-spin"), " 正在启动 conda…"))
      }
      div(class = "mt-2",
        div(class = "small",
          if (isTRUE(pr$done)) {
            if (isTRUE(pr$ok))
              span(class = "text-success", icon("circle-check"),
                   sprintf(" 环境 %s 建好了", nm))
            else
              span(class = "text-danger", icon("circle-xmark"),
                   sprintf(" 环境 %s 没建起来", nm))
          } else {
            span(icon("spinner", class = "fa-spin"),
                 sprintf(" 正在创建 %s…（解依赖可能要十几分钟，可以去做别的）", nm))
          }),
        # ⚠️ 日志尾部**必须**给用户看。conda 失败的方式有几十种（包名写错、
        #    版本冲突、频道连不上），把原因藏起来只报一句"失败了"，用户唯一
        #    能做的就是再来一次同样的操作。
        tags$pre(class = "dsapp-pre dsapp-envlog", pr$log_tail %||% "")
      )
    }

    # 两张卡片共用 create_target，但**只在起点那张卡片里显示**进度
    # （理由见 create_from 的说明）。
    output$create_progress <- renderUI({
      nm <- create_target()
      if (is.null(nm) || !identical(create_from(), "panel")) return(NULL)
      progress_ui(nm, create_state())
    })

    # ★ V13.5 item 6：基础环境卡片里那两个一键预置按钮的进度。
    output$tpl_mk_progress <- renderUI({
      nm <- create_target()
      if (is.null(nm) || !identical(create_from(), "base")) return(NULL)
      progress_ui(nm, create_state())
    })

    # =========================================================================
    # 对话环境：选一个对话来看，删掉它装的东西
    # =========================================================================
    # 原来这块只看 state$chat_session_id，也就是"必须在言出法随页把那个对话
    # 打开着"。要清三个不用了的对话的环境，就得来回切三次对话 —— 而这正是
    # 用户来看这一页最常见的原因（磁盘满了）。所以加一个选择器。
    #
    # NULL = 跟着言出法随页当前打开的那个走。
    pick_sid <- reactiveVal(NULL)

    my_sessions <- reactive({
      # 读 sessions_ver 不如直接查库：这一页不常有，一次查询很便宜，
      # 而没有依赖值的话新建/删除对话之后列表不会更新。
      state$chat_session_id
      db_sessions_list(user_id = state$user_id, con = dsapp_db(cfg))
    })

    # 在言出法随页切了对话 → 这里跟着走（用户没有显式选过的时候）。
    observeEvent(state$chat_session_id, { pick_sid(NULL) }, ignoreNULL = TRUE)

    picked_sid <- reactive({ pick_sid() %||% state$chat_session_id })

    output$pick_ui <- renderUI({
      ss <- my_sessions()
      if (nrow(ss) == 0) {
        return(div(class = "text-muted small",
          icon("circle-info"),
          " 你还没有对话。到「言出法随」页新建一个之后，这里会列出它的环境。"))
      }
      ids <- ss$id
      # ⚠️ isolate 这一句是重点：不隔离的话，"用户在下拉里选了一个"会写
      #    pick_sid()，而 pick_sid() 又是这个 renderUI 的依赖 —— renderUI
      #    立刻重跑、把 selectInput 整个重建一遍，用户刚点的那一下被冲掉。
      #    这类"控件自己把自己重建掉"的环在界面上表现为"点了没反应"。
      sel <- isolate(pick_sid()) %||% state$chat_session_id
      if (is.null(sel) || !(as.character(sel) %in% ids)) sel <- ids[[1]]
      labs <- vapply(ids, function(s) db_session_label(s, con = dsapp_db(cfg)),
                     character(1))
      selectInput(ns("sess_pick"), NULL, width = "100%",
                  choices = stats::setNames(ids, labs), selected = sel)
    })

    observeEvent(input$sess_pick, {
      if (!is.null(input$sess_pick) && nzchar(input$sess_pick)) {
        pick_sid(input$sess_pick)
      }
    }, ignoreNULL = TRUE)

    # =========================================================================
    # 本对话自己的包目录
    # =========================================================================
    # 每个对话有自己的 R 库（.Rlib）和 Python 虚拟环境（.venv），装的包只影响
    # 本对话（见 envs.R 的「每对话增量库」）。这块卡片是让这件事**看得见** ——
    # 不然用户在界面上找不到任何痕迹，会以为包装到系统里去了，然后不敢装。
    #
    # 和上面的 conda 环境是两回事，所以分成两张卡片、标题也写得不一样：
    # conda 环境是全局共享的，这里是对话私有的。混在一起列的话，用户会以为
    # 删掉 conda 环境就等于清掉自己对话里装的东西。
    ws_refresh <- reactiveVal(0)

    # 顶层条目数量。装好的 R 包在 .Rlib 下就是一个目录，venv 的包在
    # lib/pythonX.Y/site-packages 下，所以数目录就够了，不用去解析什么清单。
    # 只数一层，不走目录树 —— 一屏数字不值得卡住整个进程（理由同
    # dsapp_env_sizes_cached 的 ⚠️）。
    count_dirs <- function(p) {
      if (is.na(p) || !dir.exists(p)) return(NA_integer_)
      length(list.files(p, all.files = FALSE, no.. = TRUE))
    }

    # 实测 .venv 里 site-packages 混着 python3.9/3.11 这种版本号目录，
    # 直接取第一个存在的。
    venv_site_count <- function(venv) {
      lib <- file.path(venv, "lib")
      if (is.na(venv) || !dir.exists(lib)) return(NA_integer_)
      py <- list.files(lib, pattern = "^python[0-9]", full.names = TRUE)
      if (!length(py)) return(NA_integer_)
      count_dirs(file.path(py[[1]], "site-packages"))
    }

    ws_env_state <- reactive({
      ws_refresh()
      sid <- picked_sid()
      # 每 5 秒对一次目录 mtime。包目录会被**执行中的任务**改动，而改它的
      # 不是这个页面，光靠本页操作触发是不够的。没有对话时不轮询。
      if (!is.null(sid)) invalidateLater(5000)
      st <- dsapp_session_lib_status(sid, cfg)
      if (is.null(st)) return(NULL)
      st$rlib_n  <- if (isTRUE(st$rlib_ok))  count_dirs(st$rlib) else NA_integer_
      st$venv_n  <- if (isTRUE(st$venv_ok))  venv_site_count(st$venv) else NA_integer_
      st
    })

    # 占用大小。**故意不挂在 ws_env_state 底下** —— 那个 reactive 每 5 秒
    # 被 invalidateLater 唤醒一次，把 du 挂进去等于每 5 秒遍历一遍 venv 的
    # 上万个小文件（见 dsapp_dir_bytes 的 ⚠️）。这里只读 sz_on / sz_tick /
    # ws_refresh，都是"用户点了才变"的值。
    ws_bytes <- reactive({
      if (!isTRUE(sz_on())) return(NULL)
      sz_tick()
      sid <- picked_sid()
      if (is.null(sid)) return(NULL)
      list(rlib = dsapp_dir_bytes(dsapp_ws_rlib(sid, cfg)),
           venv = dsapp_dir_bytes(dsapp_ws_venv(sid, cfg)))
    })

    output$ws_env_card <- renderUI({
      sid <- picked_sid()
      if (is.null(sid)) {
        return(div(class = "text-muted small",
                   "选中一个对话之后，这里会显示它自己的包目录。"))
      }
      st <- ws_env_state()
      sz <- ws_bytes()

      # 没跑过代码的对话：三个目录一个都不在。这不是错误，是正常状态 ——
      # 说清楚"什么时候会有"，而不是让用户对着三个"未创建"猜。
      if (is.null(st) || (!isTRUE(st$rlib_ok) && !isTRUE(st$venv_ok) &&
                          !isTRUE(st$pylib_ok))) {
        return(div(class = "text-muted small",
          icon("circle-info"),
          " 这个对话还没执行过代码，所以还没有自己的包目录。",
          "第一次跑 R 或 Python 时会自动建，不需要你做什么。"))
      }

      line <- function(label, ok, n, note, bytes = NULL) {
        div(class = "d-flex align-items-baseline gap-2 small mb-1",
          span(style = "min-width:5.5em;", tags$b(label)),
          if (ok) span(class = "badge text-bg-success", "已就绪")
          else span(class = "badge text-bg-secondary", "未创建"),
          span(class = "text-muted",
               if (isTRUE(ok) && !is.na(n)) sprintf("已装 %d 个包", n)
               else note),
          if (!is.null(bytes))
            span(class = "text-muted", sprintf("· %s", dsapp_fmt_bytes(bytes)))
        )
      }

      div(
        div(class = "small text-muted mb-2",
          "在这个对话里执行代码时装的新包，落在下面这两个目录里，",
          tags$b("只有这个对话看得见"), "——不影响基础环境，也不影响别人的对话。"),
        line("R", st$rlib_ok, st$rlib_n,
             # 这里原本问的是 pylib_ok —— 复制粘贴留下的错。R 库没建起来时
             # 它会显示 Python 那边的状态，于是"未创建"后面跟着一句空白
             # （或者反过来显示 Python 的说明），用户看不出该怎么办。
             if (isTRUE(st$rlib_ok)) "" else "首次执行 R 代码时自动创建",
             if (!is.null(sz)) sz$rlib),
        line("Python", st$venv_ok, st$venv_n,
             if (isTRUE(st$pylib_ok))
               "虚拟环境没建起来，已回落到 .pylib（pip 装到这里）"
             else "首次执行 Python 代码时自动创建",
             if (!is.null(sz)) sz$venv),
        div(class = "d-flex gap-2 mt-3 flex-wrap",
          actionButton(ns("ws_reset_rlib"), "清空 R 包目录",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("rotate-right")),
          actionButton(ns("ws_reset_venv"), "清空 Python 环境",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("rotate-right")),
          actionButton(ns("ws_reset_all"), "两个都清空",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("broom"))
        ),
        helpText(class = "small text-muted mb-0 mt-2",
          "装坏了就清空重建：只清掉这里装的包，对话内容和产出文件都不受影响。",
          "清空之后下次执行时会自动重建。")
      )
    })

    # ---- 清空（重建）----
    #
    # 「装坏了删掉重建就行」这句话写在提示词里、也写在上面那句帮助文字里，
    # 那就得真的能一键做到 —— 否则用户只能去 SSH 里手删目录，而这是个
    # 没有登录的网页应用，大部分用户根本没有 SSH。
    ws_reset <- function(which) {
      sid <- picked_sid()
      if (is.null(sid)) return(invisible(FALSE))
      # 每个语言一份，外加 .pylib（venv 建不出来时的回落）。
      # 「两个都清空」不该漏掉 .pylib —— 漏了的话用户点完发现 Python 那边
      # 还是"已就绪"，会以为按钮坏了。
      paths <- switch(which,
        rlib  = dsapp_ws_rlib(sid, cfg),
        venv  = dsapp_ws_venv(sid, cfg),
        all   = c(dsapp_ws_rlib(sid, cfg), dsapp_ws_venv(sid, cfg),
                  file.path(dsapp_ws_dir(sid, cfg, create = FALSE), ".pylib"))
      )
      paths <- paths[!is.na(paths)]
      present <- paths[dir.exists(paths)]
      if (!length(present)) {
        showNotification("这些目录还没建出来，不用清空", type = "message")
        return(invisible(FALSE))
      }
      # 正跑着的任务正在用这个目录。删掉它的话，那个任务会在一半的地方
      # 报出莫名其妙的错（找不到包、找不到解释器），而且错在离原因很远的
      # 地方。直接拦住，别让用户以为是代码写错了。
      #
      # ⚠️ 只在**正在跑的那个任务属于这个对话**时才拦。这条页面上可以选
      #    任意一个对话，拿"引擎忙"一刀切的话，别人（或自己另一个对话）
      #    在跑任务时这里什么都清不了，而理由还写着"有任务正在执行"，
      #    用户看着自己的空对话完全不知道为什么。
      if (!is.null(engine) && !is.null(engine$current_task_id())) {
        trow <- tryCatch(
          db_task_get(engine$current_task_id(), con = dsapp_db(cfg)),
          error = function(e) NULL)
        if (dsapp_task_in_session(trow, sid)) {
          showNotification("这个对话有任务正在执行，等它结束再清空", type = "warning")
          return(invisible(FALSE))
        }
      }
      unlink(present, recursive = TRUE, force = TRUE)
      if (any(dir.exists(present))) {
        showNotification("删除失败，可能还有进程占着这个目录", type = "error")
        return(invisible(FALSE))
      }
      ws_refresh(ws_refresh() + 1)
      showNotification(
        sprintf("%s 已清空，下次执行时会自动重建",
                switch(which, rlib = "R 包目录", venv = "Python 环境",
                       all = "这个对话的包目录")),
        type = "message", duration = 6)
      invisible(TRUE)
    }

    observeEvent(input$ws_reset_rlib, ws_reset("rlib"))
    observeEvent(input$ws_reset_venv, ws_reset("venv"))
    observeEvent(input$ws_reset_all,  ws_reset("all"))

    # ---- 没做的东西，以及为什么 ----
    #
    # **界面上的「新建环境」「装包」按钮仍然没有**。V3 有，item 4 撤了；
    # V5 把"选"和"删"加回来，这两个没加回来，理由是它们各自有一条硬约束：
    #
    #   新建：conda create 一次要解几分钟到十几分钟的依赖，而本站是
    #         Shiny Server 开源版 —— 一个应用一个 R 进程、所有访客共用。
    #         要做得不阻塞任何人，得配一整套后台作业 + 进度面板 + 断线重连，
    #         那是独立的一块工作。dsapp_env_create() / dsapp_env_install()
    #         留在 envs.R 里能用，只是没有界面入口。
    #
    #   装包：同上，而且更要紧的是**它不该是主要的装包路径**。提示词里
    #         明确让模型在代码里直接 install.packages() / pip install，
    #         装进对话自己那一层（.Rlib / .venv），只对这个对话可见 ——
    #         那才是「只对自己环境有干涉权」的落点。一个往共享 conda 环境
    #         里装的按钮，等于在界面上开了一条绕开隔离的路。
    #
    # 哪天真要做，记得 V3 那份实现里有个值得抄的坑：用 output 当
    # conditionalPanel 的条件时，必须配 outputOptions(suspendWhenHidden = FALSE)
    # —— 那个 output 因为不可见而被挂起的话，条件永远读到空字符串，
    # 整块操作区**一次都不会出现**，而界面上不报任何错。
    #
    # 另一个已经踩过的坑（V3 的作业进度面板）：`x <- isolate(x) + 1` 这种
    # "自增一下当作脉冲"的写法，必须同时确认**有人读 x**。reactiveVal 的写入
    # 只会让"读过它"的东西失效，没人读就等于没写 —— 于是面板永远停在第一帧，
    # 用户看到十几分钟不动的日志还以为 conda 卡住了。本仓库反复出现这类
    # "静默失效"（另见 components.R 的 js_lit/js_str）。
  })
}
