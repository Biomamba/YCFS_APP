# =============================================================================
# 技能库页（V8 item 1）
# =============================================================================
# 用户的原话：「加一个 skills 库系统，可以让用户自行上传 skills，并且在对话时
# 选择是否要关联调用 skills，也支持用户自然语言描述需求生成新的 skills
# 添加到库中」。
#
# 这一页管**库**（有哪些技能、怎么进来、怎么改）。"这个对话挂哪几条"在
# 言出法随页的输入框上方（见 mod_chat.R 的 skill_bar），因为那是**用**的地方，
# 让用户为了勾一个技能先跳到另一页再跳回来，是最容易被放弃的一步。
#
# 数据层和拼提示词在 R/skills.R，那一份顶部解释了"技能到底是什么"。
#
# ---- 三条来路，对应界面上三个按钮 -------------------------------------------
#
#   新建       手写。给已经想清楚要什么的人。
#   上传       .md / .txt。给已经在别处攒了一堆 prompt 的人 —— 这是**迁移**
#              路径，不提供的话他们只能一条条复制粘贴。
#   一句话生成  描述需求 → 模型写一条。给"我知道我想要什么效果，但不知道
#              该怎么跟模型说"的人 —— 这是大多数人。
#
# ⚠️ 三条路最后都汇进**同一个编辑器**（save_modal）。生成出来直接存的话，
#    用户没机会看一眼模型写了什么，而技能是会**长期影响之后每一次对话**的
#    东西 —— 一条写歪的技能比一次答歪的回答严重得多，因为它不会自己过期。
# =============================================================================

mod_skills_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "dsapp-page",

      # ---- 说明 ----
      #
      # ★ V13.16 item 30：开头这两段换成用户给的文案。
      #   ⚠️ 用户说的是"关于技能的介绍换成以下内容" —— **只换了介绍**。
      #      下面那三条（本平台支持自定义并上传 / 写一次每次都能勾 /
      #      按对话挂载 / 两个池）是这一页的**操作说明**，不是介绍：
      #      少了"按对话挂载"，用户会以为勾过的技能对所有对话生效；
      #      少了"两个池"和"另存为我的"，他会找不到自己建的技能、
      #      也不知道怎么改内置那条。所以它们原样留着。
      #   ⚠️ 用户原文里的 `"智能员工"` 用的是 ASCII 直引号，这里按全站排版
      #      换成「」；`更高效的使用` 改成 `更高效地使用`（"地"）。
      #      内容是原话，只动了标点和那个错字。
      card(
        card_header(icon("wand-magic-sparkles"), " 关于技能"),
        card_body(
          class = "py-2",
          p(class = "mb-2",
            "在 AI Agent 体系里，", tags$b("Skill（技能）"),
            "是封装好、可被 Agent 调用的独立能力单元。",
            "Agent 相当于「智能员工」，Skill 就是员工掌握的一项项专业本事",
            "（查文献、运行生信脚本、调用 API、文件读写、绘图等）。",
            "Skills 可以单独使用，也可以组合起来使用，",
            "帮助你更高效地使用 AI Agent！"),
          p(class = "mb-1", "比如你可以和 AI 约定以下 skills："),
          tags$ol(class = "mb-2",
            tags$li("输出图片必须 ≥ 300 dpi，以满足 SCI 发表要求；"),
            tags$li("所有分析图片必须由代码生成，不可由 AI 生成；"),
            tags$li("文献检索时请校验，避免 AI 幻觉。")),
          p(class = "mb-2",
            "本平台支持", tags$b("自定义技能并上传"), "！"),
          p(class = "mb-2",
            "它和你在输入框里打的要求是同一件事，区别只是",
            tags$b("写一次、以后每次都能勾"), "。"),
          div(class = "dsapp-warn",
            icon("shield-halved"),
            " 技能是", tags$b("按对话挂载"), "的：只有你勾了它的那个对话会用到它，",
            "换一个对话就是另一套。"),
          p(class = "mb-0",
            "技能分两个池：", tags$b("我的技能"), "默认只有你自己看得到；",
            tags$b("公共技能库"), "里的技能所有人可见、可勾选，",
            "但只有作者能改 —— 想改别人（或内置）的那条，用「另存为我的」复制一份。")
        )
      ),

      # ---- 工具栏 ----
      card(
        card_header(
          class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
          span(icon("book-bookmark"), " 技能库"),
          div(class = "d-flex gap-2 flex-wrap",
            actionButton(ns("new"), "新建",
                         class = "btn-sm btn-primary", icon = icon("plus")),
            actionButton(ns("upload"), "上传文件",
                         class = "btn-sm btn-outline-secondary",
                         icon = icon("file-arrow-up")),
            actionButton(ns("gen"), "用一句话生成",
                         class = "btn-sm btn-outline-secondary",
                         icon = icon("wand-magic-sparkles"))
          )
        ),
        card_body(
          class = "py-2",
          # ---- 两个池（V13.7 item 6）----
          #
          # 用户的原话：「skills 需要分类，我的 skills、公共 skills 库」。
          #
          # ★ 用 bslib 的 navset_pill 而不是自己搭一排按钮：这一页已经通篇是
          #   bslib 的 card，pill 是同一套主题变量画出来的，跟着皮肤走；
          #   自己搭的话每加一个皮肤都要回来补一遍选中态的配色。
          #
          # ⚠️ 面板里**故意是空的**。列表放在两个面板**外面**，是为了让搜索框、
          #    排序控件和列表本体在切池时**不被重建** —— 排进面板里的话，
          #    切一次池整块 DOM 就换一遍，正在展开的技能全合上、
          #    搜索框里的字也没了。用户切池的意图是"换个地方找"，
          #    不是"把我这一屏清空"。
          #
          # ⚠️ 只影响**显示**。授权一律走 dsapp_skills_list(pool = NULL)，
          #    见 R/skills.R 里那段：拿它当权限判断的话，
          #    "我的"那一栏会漏掉自己刚发布出去的技能。
          bslib::navset_pill(
            id = ns("pool"),
            bslib::nav_panel("我的技能", value = "mine"),
            bslib::nav_panel("公共技能库", value = "public")
          ),
          # 技能多了以后要能找。这个框只过滤**当前这一页**的列表，
          # 不查库 —— 一个账号的技能量级是几十条，全量查出来再过滤更简单。
          textInput(ns("q"), NULL, width = "100%",
                    placeholder = "搜索技能名 / 简介 / 标签…"),
          # ★ 排序控件（V13.2 item 13）。放在**自己的 output** 里，和下面
          #   列表分开：它的初值要读库（这个账号上次选的排法），而首屏渲染
          #   发生在登录闸门写 state$user_id **之前** —— 写死在静态 UI 里的
          #   话，登录之后它永远停在"自定义"，用户上次选的"按名称"就丢了。
          #
          # ⚠️ 拆成**两块**画（左边下拉 / 右边方向按钮 + 提示），理由见
          #    mod_skills_server 里那两段注释。外框留在这里，是因为它不该
          #    跟着任何一块重画。
          # ★ V13.4 item 5：「排序」「下拉」「正序/倒序」这三样原来不在一条
          #   水平线上，两个原因叠在一起（都在 www/app.css 的
          #   `.dsapp-skills-sortbar` 那段里写了）：一是 `.form-group` 自带的
          #   下边距让下拉那一块的**盒子**比看得见的内容高，align-items-center
          #   居中的是盒子、不是控件；二是「排序」那个 span 和下拉是块级
          #   兄弟，span 被挤到了单独一行。这里只加个类名，几何交给 CSS ——
          #   对齐是纯样式问题，写在 R 里就得靠调 margin 去凑。
          div(class = "dsapp-skills-sortbar d-flex align-items-center gap-2 flex-wrap mb-2",
            uiOutput(ns("sort_ui")),
            uiOutput(ns("sort_dir_ui"))),
          uiOutput(ns("list_ui"))
        )
      )
    )
  )
}


mod_skills_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ⚠️ 和 mod_envs.R 同一个坑：R/*.R 是用 source(local = globalenv())
    #    载入的，看不见 app.R 里那个 cfg。漏了这一行的表现是整页
    #    "object 'cfg' not found"。
    cfg <- dsapp_config()

    # 列表重画用的脉冲。任何一次增删改之后 +1。
    sk_ver <- reactiveVal(0)

    # 池的两个选项文案（V13.7 item 6）。上传弹窗、编辑器、以及下面那句
    # 「存到哪儿」的提示共用同一份 —— 分开写的话改文案时只会改到其中一处，
    # 用户会在两个弹窗里看到同一个概念叫两个名字。
    scope_choices <- c(
      "我的技能（只有我自己看得到）" = "private",
      "公共技能库（所有登录用户可见、可勾选，只有我能改）" = "public")

    # 现在看着哪个池（V13.7 item 6）。"mine" / "public"。
    #
    # ⚠️ `%||% "mine"` 那个兜底不能省：这个值来自 bslib 的 navset，而
    #    navset 是在**首屏渲染之后**才把选中态报上来的。少了兜底的话，
    #    第一帧 pool() 是 NULL，两个池的谓词都落不到 —— 用户会看到列表
    #    闪一下"没有技能"再变回来。
    # ⚠️ 收敛走 dsapp_skill_pool_norm()，认不出来的一律回落成 NULL（全集）。
    #    这里**不能**写成 if/else 只认 "public"：那样以后加第三个池
    #    （比如"团队"）时，界面加了、这里忘了，表现是这个池整栏空着，
    #    而空列表和"确实没有技能"长得一模一样。
    pool <- reactive({
      v <- dsapp_skill_pool_norm(input$pool %||% "mine")
      if (is.null(v)) "mine" else v
    })

    # 生成任务的句柄 / 结果。NULL = 没在跑也没结果。
    gen_job <- reactiveVal(NULL)
    gen_res <- reactiveVal(NULL)

    # 读这个账号的界面偏好（排法在里面）。**故意写成普通函数而不是 reactive**：
    # 它读 state$user_id，所以谁调用它谁就依赖登录状态；但它**不**碰
    # sk_ver()，于是"要不要跟着列表重画"这件事由每个 output 自己决定 ——
    # 下面那两块排序控件正是靠这个才拆得开的。
    read_prefs <- function() {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        dsapp_uipref_norm(NULL)
      } else {
        tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                 error = function(e) dsapp_uipref_norm(NULL))
      }
    }

    # 这个账号选的排法（V13.2 item 13）。和面板尺寸同一个存放处
    # （users.ui_prefs），但**各读各的**：mod_skills 只关心这两个键。
    sort_pref <- reactive({
      sk_ver()
      p <- read_prefs()
      list(sort = dsapp_skills_sort_norm(p$skills_sort),
           desc = isTRUE(p$skills_desc))
    })

    save_sort_pref <- function(sort = NULL, desc = NULL) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      full <- read_prefs()
      if (!is.null(sort)) full$skills_sort <- sort
      if (!is.null(desc)) full$skills_desc <- desc
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg)), silent = TRUE)
      # 告诉别的模块尺寸/偏好那份变了（和面板尺寸共用一把计数器）。
      # ⚠️ 这里**不**能靠 sk_ver() 之外的东西去重画列表：那会把"排序变了"
      #    和"技能内容变了"混成一件事，以后加个自动刷新就分不清谁在动。
      state$uipref_rev <- state$uipref_rev + 1L
      sk_ver(sk_ver() + 1L)
      # ★ 那个下拉是特意做成**不重画**的（见下面 output$sort_ui），所以凡是
      #   绕过它的改动都得在这里补一刀。眼下只有拖拽那条路会走到这儿，而拖拽
      #   本身就要求当前是「自定义」—— 多数时候这是个空操作。留着是为了以后
      #   再加别的入口（比如设置页里也能改排序）时不会漏掉这一步。
      # ⚠️ 用 updateSelectInput 而不是重画控件：就地改值不动元素，下拉不会
      #   因为"正好开着"而被合上。值没变时它不触发事件，不会打转。
      try(updateSelectInput(session, "sk_sort",
                            selected = dsapp_skills_sort_norm(full$skills_sort)),
          silent = TRUE)
    }

    my_skills <- reactive({
      sk_ver()
      # ⚠️ state$user_id 变化（登录/换账号）也必须让列表重画 —— 换账号后
      #    必须看到新账号的技能，而不是上一个人的（那份还在浏览器里没被
      #    销毁的话，用户会以为自己的技能跑到别人账号下面去了）。
      state$user_id
      sp <- sort_pref()
      # ★ pool 只影响**显示**（V13.7 item 6）。挂载、排序白名单那些授权口径
      #   走的仍然是不带 pool 的那一支，见 R/skills.R 里那段说明。
      dsapp_skills_list(state$user_id, con = dsapp_db(cfg),
                        sort = sp$sort, desc = sp$desc, pool = pool())
    })

    # 这一条是不是我自己的。界面渲染要反复问，包一层省得每处都写
    # is.na(user_id) || user_id != state$user_id 那一串。
    is_mine <- function(r) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return(FALSE)
      !is.na(r$user_id[[1]]) && identical(as.integer(r$user_id[[1]]),
                                          as.integer(uid))
    }

    # 展开着的那几条（V13.2 item 11）。和 ws_open 一个套路：报"当前开着的
    # 全部"，服务端不做增量维护，丢一次事件也能自愈。
    sk_open <- reactiveVal(character(0))

    # =========================================================================
    # 排序控件（V13.2 item 13）
    # =========================================================================
    # ---- 左半：那个下拉。依赖**只有** state$user_id，画一次就不再重画 ----
    #
    # ⚠️ 这里绝不能读 sk_ver()。读了的话，每存一条技能、每拖一次顺序，
    #    这个 <select> 都会被整个重建一次；而原生下拉一被替换，正在展开的
    #    那一屏就合上了 —— 用户刚点开、还没选，它就自己关了。
    #    （值要变的时候用 updateSelectInput() 就地改，见 save_sort_pref。）
    output$sort_ui <- renderUI({
      tagList(
        span(class = "small text-muted", icon("arrow-down-wide-short"), " 排序"),
        # ⚠️ `selectize = FALSE`：这是个四项的小下拉，selectize 那层包装
        #    在这里只会让"点开它"变得要靠坐标（而坐标会随窗口宽度变）。
        #    原生 select 键盘也能用，测试里也能直接 select_option。
        selectInput(ns("sk_sort"), NULL, width = "auto", selectize = FALSE,
                    choices = c("自定义（可拖拽）" = "custom", "名称" = "name",
                                "加入时间" = "created", "最近修改" = "updated"),
                    selected = dsapp_skills_sort_norm(read_prefs()$skills_sort))
      )
    })

    # ---- 右半：方向按钮 + 提示。跟着 sk_ver() 走 ----
    #
    # ⚠️ 这两样东西都是**当前排法的函数**（"↓ 倒序 / ↑ 正序"、以及自定义
    #    时才出现的那句"按住 ⠿ 拖动"），所以必须重画。第一版把它们和下拉
    #    写在同一块、又只依赖 state$user_id —— 结果是切到「名称」之后旁边还
    #    挂着"按住 ⠿ 拖动"，切回「自定义」之后方向按钮顶着一个灰掉的
    #    「↓ 倒序」（那是上一个排法留下的 desc）。置灰的按钮用户也改不掉它，
    #    只能看着。
    #    重画一个按钮没有任何代价：它不是下拉，没有"展开着"这个状态。
    #
    # ★ V13.4 item 5：那句"自定义没有正倒序"后来被证明是错的 —— 见下面
    #   renderUI 里那段。现在按钮在任何档位下都可点，也就不再有"灰着的
    #   ↓ 倒序"这个状态需要靠复位 desc 去躲。
    output$sort_dir_ui <- renderUI({
      sk_ver()
      p <- read_prefs()
      cur <- dsapp_skills_sort_norm(p$skills_sort)
      desc <- isTRUE(p$skills_desc)
      tagList(
        # ★ V13.4 item 5：这个按钮**不再置灰**。
        #
        #   原来「自定义」档是灰的，理由是"自定义顺序就是你拖出来的样子，
        #   没有正倒序"。可「自定义」是**默认**档 —— 于是绝大多数人打开技能
        #   页，看到的第一个排序控件就是个点不动的按钮。用户的原话是
        #   「点击正序倒序 skills 的排列顺序并没有改变」：他点的那个按钮，
        #   从第一秒起就是 disabled 的。一个默认状态下的主要控件不该是死的。
        #
        #   现在自定义档也有方向：**倒序 = 把你拖出来的那份顺序整个翻过来**
        #   （没拖过的仍然垫底，见 dsapp_skills_list 里那段）。要回到"我拖的
        #   样子"就再点一下切回正序 —— 比让人去回忆那个顺序容易得多。
        actionButton(ns("sk_dir"),
                     if (desc) "↓ 倒序" else "↑ 正序",
                     class = "btn-sm btn-outline-secondary",
                     title = if (cur == "custom")
                               "倒序 = 把你拖出来的顺序整个翻过来（没拖过的仍在最后）"
                             else "点一下换个方向"),
        span(class = "small text-muted",
             if (cur == "custom")
               "按住左边的 ⠿ 拖动可以自己排顺序")
      )
    })

    observeEvent(input$sk_sort, {
      s <- dsapp_skills_sort_norm(input$sk_sort)
      # ★ V13.4 item 5：切排法时**不再**把方向复位成正序。
      #
      #   原来复位是因为"自定义档没有方向，留着 desc 会顶出一个改不掉、
      #   又和眼前顺序无关的灰按钮"。现在每个档都有方向了，复位反而变成
      #   新的意外：用户在「名称 + 倒序」下切到「自定义」，方向被悄悄掰回
      #   正序 —— 他刚拖好的那份顺序看起来"自己翻回去了"，而没有任何东西
      #   告诉他发生了什么。
      #   方向键和表格的排序箭头一样，是**跨排法粘住**的。要复位就自己点。
      save_sort_pref(sort = s)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    observeEvent(input$sk_dir, {
      save_sort_pref(desc = !isTRUE(sort_pref()$desc))
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # 拖完之后前端发上来的**全量顺序**（见 dsapp_skill_order_set 的说明：
    # 收到的是技能 id 的字符向量，来自浏览器，只做类型收敛不当授权）。
    observeEvent(input$sk_order, {
      ids <- input$sk_order
      if (is.null(ids) || !length(ids)) return()
      dsapp_skill_order_set(state$user_id, ids, con = dsapp_db(cfg))
      # ★ 拖完自动切到"自定义"：用户刚表达的就是"我要这个顺序"，此时列表
      #   还按"名称"排的话，他松手之后会看见列表**弹回原样** —— 看起来
      #   就是"拖了没用"。同理，正倒序也一起复位（自定义没有正倒序）。
      save_sort_pref(sort = "custom", desc = FALSE)
    }, ignoreNULL = TRUE)

    # 展开/收起（用户点了哪几个三角）。和 ws_open 一样只存内存：
    # 这是一次浏览里的临时状态，刷新回到"全收起"没什么损失。
    observeEvent(input$sk_open, {
      v <- input$sk_open
      sk_open(if (is.null(v)) character(0) else as.character(v))
    }, ignoreNULL = FALSE)

    # =========================================================================
    # 列表
    # =========================================================================
    output$list_ui <- renderUI({
      df <- my_skills()
      # ★ 空列表的文案要分清是哪个池（V13.7 item 6）。
      #   一句通用的"还没有技能"在公共库里是**错的** —— 用户自己明明有
      #   十几条，只是因为一条都没发布，公共库看起来像功能坏了。
      if (is.null(df) || nrow(df) == 0) {
        return(if (identical(pool(), "public"))
          div(class = "text-muted small py-2",
            icon("circle-info"), " 公共技能库里还没有别人发布的技能。",
            "你自己写的那几条可以用「查看 / 编辑」打开，把「存到哪个池」",
            "改成「公共技能库」发布出去 —— 发布后所有人都能看到和勾选，",
            "但只有你能改、能收回。")
        else
          div(class = "text-muted small py-2",
            icon("circle-info"), " 还没有技能。点右上角「新建」「上传文件」",
            "或者「用一句话生成」建第一条。"))
      }

      q <- trimws(tolower(input$q %||% ""))
      if (nzchar(q)) {
        hay <- tolower(paste(df$name, df$summary, df$tags))
        df <- df[grepl(q, hay, fixed = TRUE), , drop = FALSE]
        if (nrow(df) == 0) {
          return(div(class = "text-muted small py-2",
                     sprintf("没有匹配「%s」的技能。", q)))
        }
      }

      sp  <- sort_pref()
      # ★ 搜索框里有字的时候**不许拖**。
      #
      #   报告上去的是"当前这一屏从上到下的 id"，而过滤之后那一屏只是全集
      #   的一个子集。允许拖的话，用户搜"作图"、把两条拖一下，服务端就会把
      #   这两条排成第 1、2 位，而没显示出来的那几十条还各自留着旧的名次 ——
      #   名次撞车，顺序变成一团谁也没法解释的样子，而且用户完全不知道是
      #   "搜了一下"导致的。宁可这时候不给拖。
      can_drag <- identical(sp$sort, "custom") && !nzchar(trimws(input$q %||% ""))
      open_now <- sk_open()

      rows <- lapply(seq_len(nrow(df)), function(i) {
        r <- df[i, , drop = FALSE]
        builtin <- isTRUE(r$builtin[[1]] == 1)
        mine <- is_mine(r)                      # V13.7 item 6
        pub  <- identical(as.character(r$scope[[1]] %||% ""), "public")
        sid <- r$id[[1]]
        body <- r$body[[1]] %||% ""
        nch <- nchar(body)
        outline <- dsapp_skills_outline(body)
        # ★ 内置技能的"文件信息"（V13.2 item 11）：文件名 / 大小 / 上游仓库 /
        #   许可是**不在库里**的，现从 skills_builtin/ 那份（进程内缓存的）
        #   列表里按名字查。查不到（比如 .md 的名字改过、库里那条还没跟上）
        #   就少显示那几行 —— 见 dsapp_skill_builtin_info 的说明。
        binfo <- if (builtin) dsapp_skill_builtin_info(r$name[[1]]) else NULL

        tags_html <- if (nzchar(r$tags[[1]])) {
          ts <- trimws(strsplit(r$tags[[1]], "[,，;；]")[[1]])
          ts <- ts[nzchar(ts)]
          lapply(ts, function(t) span(class = "dsapp-skill-tag", t))
        } else NULL

        # 一条"文件"行：图标 + 名称 + 后面那串说明。展开之后看到的就是
        # 这么几行 —— 用户原话是"以文件夹的形式，这样能展示 skills 的更多
        # 内置文件信息"，所以每一行都要有**这个技能特有的**东西，
        # 不写"正文：有"这种放之四海皆准的话。
        frow <- function(ico, label, value, cls = "") {
          div(class = paste("dsapp-skill-file", cls),
            icon(ico), span(class = "dsapp-skill-file-k", label),
            span(class = "dsapp-skill-file-v", value))
        }

        # 正文那一行：有文件名就写文件名，没有就写"正文"。
        # ⚠️ nchar() 数的是**字符**不是字节：3000 个汉字在 UTF-8 里是 9 KB，
        #    报 KB 会让人以为"这篇很短"。所以两个字都报，各说各的。
        body_line <- sprintf("%s · 约 %s 字 · %d 节",
                             if (!is.null(binfo) && nzchar(binfo$file %||% ""))
                               binfo$file
                             else if (nch < 2000) "正文" else "正文（长文）",
                             format(nch, big.mark = ","),
                             length(outline))
        if (!is.null(binfo) && !is.na(binfo$bytes)) {
          body_line <- sprintf("%s · %s", dsapp_fmt_bytes(binfo$bytes), body_line)
        }

        # ---- 配套文件树（V13.12 item 13）-------------------------------------
        #
        # 用户原话：「skills 界面目前只显示文本，一些 skills 是附带文件夹和
        # 文件的，请同步显示配套的文件夹」。
        #
        # 上面那几行 frow() 描述的都是**正文**。一个真实的技能（比如用户自己
        # 那份「Biomamba 教程制作规则」）还带着 templates/ 整棵子树，而那一块
        # 在这个界面里原来一个像素都没有。
        #
        # ⚠️ 查的是**库**（skill_files），不是 skills_builtin/ 那个目录 ——
        #    内置技能的配套文件在 seed 时就种进库了，两条来路走同一张表，
        #    这里就不用分"内置/上传"两套渲染。见 skills.R 里 dsapp_skills_seed。
        fdf <- dsapp_skill_files_list(sid, con = dsapp_db(cfg))
        tree_block <- if (nrow(fdf) > 0) {
          tot <- sum(as.numeric(fdf$bytes), na.rm = TRUE)
          # 按路径查元信息。tree 里只有路径，大小/存没存内容在这里补回来。
          meta <- fdf; rownames(meta) <- meta$path

          leaf <- function(p, depth) {
            m <- meta[p, , drop = FALSE]
            sz <- if (nrow(m)) dsapp_fmt_bytes(m$bytes[[1]]) else "—"
            stored <- nrow(m) && isTRUE(m$stored[[1]] == 1L)
            kind <- if (nrow(m)) as.character(m$kind[[1]]) else "binary"
            # 只有**存了内容的文本**才可点。二进制点开是一屏乱码，
            # 超限的压根没内容 —— 两种情况都不给链接，免得点了个寂寞。
            if (stored && identical(kind, "text")) {
              tags$a(href = "#", class = "dsapp-skill-leaf is-open",
                     style = sprintf("padding-left:%.2fem", depth * 1.1),
                     onclick = sprintf(
                       "Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
                       jsonlite::toJSON(ns("sk_act"), auto_unbox = TRUE),
                       jsonlite::toJSON(paste0("peek|", sid, "|", p), auto_unbox = TRUE)),
                     icon("file-lines"), span(basename(p)),
                     span(class = "dsapp-skill-leaf-sz", sz))
            } else {
              span(class = "dsapp-skill-leaf is-off",
                   style = sprintf("padding-left:%.2fem", depth * 1.1),
                   icon(if (identical(kind, "binary")) "file-image" else "file"),
                   span(basename(p)),
                   span(class = "dsapp-skill-leaf-sz",
                        paste0(sz, if (!stored) " · 内容太大未存" else "")))
            }
          }

          # 递归渲染。目录用 <details>，和技能本身那个"文件夹"是同一套形态
          # （不依赖 JS、键盘可用），点开收起的状态不跨刷新保留 —— 它是一次
          # 浏览里的临时状态，值得记的只有"哪条技能展开着"。
          draw <- function(node, depth) {
            out <- list()
            for (d in names(node$dirs)) {
              ch <- node$dirs[[d]]
              out[[length(out) + 1L]] <- tags$details(
                class = "dsapp-skilldir",
                open = if (depth == 0L) NA else NULL,
                tags$summary(style = sprintf("padding-left:%.2fem", depth * 1.1),
                             icon("folder"), span(d),
                             span(class = "dsapp-skill-leaf-sz",
                                  sprintf("%d 个", dsapp_skill_tree_count(ch)))),
                draw(ch, depth + 1L))
            }
            for (f in node$files) out[[length(out) + 1L]] <- leaf(f, depth)
            out
          }
          tagList(
            frow("folder-tree", "配套文件",
                 sprintf("%d 个 · 共 %s%s", nrow(fdf), dsapp_fmt_bytes(tot),
                         if (any(fdf$stored == 0L))
                           sprintf("（其中 %d 个超过单文件上限，只记了名字）",
                                   sum(fdf$stored == 0L)) else "")),
            div(class = "dsapp-skill-tree",
                draw(dsapp_skill_tree(fdf$path), 0L))
          )
        } else NULL

        src_line <- if (!is.null(binfo)) {
          # ⚠️ 这两行**依赖 `meta` 是 list**（见 R/skills.R 的 dsapp_skill_parse
          #    里那段 ★★ V13.16 item 28 的说明）：`[[` 取一个不存在的名字，
          #    对 list 返回 NULL、对**字符向量是硬错误** "subscript out of bounds"。
          #    曾经因为 meta 是 character(0)，academic-search / deeppapernote
          #    这两条没有 `repo:` 的内置技能把**整个技能列表**渲染崩了。
          #    真出问题的地方是解析器，这里不重复兜底 —— 兜在这儿的话，
          #    下一次是别的调用点先炸。
          repo <- binfo$meta[["repo"]] %||% ""
          lic  <- binfo$meta[["license"]] %||% ""
          paste(c(if (nzchar(repo)) repo else "内置",
                  if (nzchar(lic)) lic else NULL), collapse = " · ")
        } else {
          switch(r$source[[1]],
                 upload    = "上传的文件",
                 generated = "用一句话生成",
                 "自己在技能页写的")
        }

        div(class = "dsapp-skill-row dsapp-skill-folder",
          # ★ 拖拽手柄（V13.2 item 13）。**只有它是 draggable**，整行不是 ——
          #   整行可拖的话，点标题展开、选中文字都会变成"开始拖"，而那两件事
          #   用户天天在做。拖动时用 setDragImage 把整行当影子（见 app.js）。
          div(class = paste("dsapp-skill-drag", if (!can_drag) "is-off"),
              `data-id` = as.character(sid),
              draggable = if (can_drag) "true" else "false",
              # 键盘那条路：Tab 到它，上下方向键挪一格（见 app.js）。
              # ⚠️ 不给 tabindex 的话它根本聚焦不了 —— 而"只能用鼠标拖"
              #    对触摸板不好使的人是实打实的用不了。
              tabindex = if (can_drag) "0" else NULL,
              role = "button",
              `aria-label` = "调整这条技能的顺序",
              title = if (can_drag) "按住拖动，或聚焦后按上下方向键"
                      else "先把上面的排序切到「自定义（可拖拽）」，搜索框清空",
              icon("grip-vertical")),
          div(class = "dsapp-skill-main",
            # ★ `<details>` 就是"文件夹"这一形态本身：点标题展开/收起，不依赖
            #   JS，键盘也能用（Tab 到 summary、Enter 开合）。
            #   ⚠️ data-input / data-key 是给 app.js 用的（开合状态上报），
            #      和「本对话产物」那些分组是同一套约定。
            tags$details(
              class = "dsapp-skillgroup",
              `data-key` = as.character(sid),
              open = if (as.character(sid) %in% open_now) NA else NULL,
              tags$summary(class = "dsapp-skill-head",
                icon("folder", class = "dsapp-skill-fold"),
                span(class = "dsapp-skill-name", r$name[[1]]),
                # ★ 徽章要说清"这条是谁的、能不能改"（V13.7 item 6）：
                #   内置 = 官方的，公共 = 别人的，我发布的 = 自己放出去的。
                #   少了"我发布的"这一档，用户把自己那条标成公共之后
                #   会在"公共库"里看到一条没有任何标记的技能，
                #   分不清哪条是自己的、点删除会不会删错。
                if (builtin)
                  span(class = "badge text-bg-secondary ms-2", "内置")
                else if (!mine)
                  span(class = "badge text-bg-primary ms-2",
                       title = "别人放进公共技能库的，只有作者能改",
                       "公共")
                else if (pub)
                  span(class = "badge text-bg-success ms-2",
                       title = "你放在公共技能库里的，所有人都能看到和勾选",
                       "我发布的")
                else
                  span(class = "badge text-bg-info ms-2",
                       switch(r$source[[1]],
                              upload = "上传", generated = "生成", "自建")),
                tags_html
              ),
              div(class = "dsapp-skill-files",
                frow("file-lines", "正文", body_line),
                frow("up-right-from-square", "来源", src_line),
                if (length(outline))
                  frow("list-ul", "目录",
                       paste(outline, collapse = " / "), "dsapp-skill-file-outline"),
                frow("clock", "时间",
                     sprintf("%s 加入 · %s 修改",
                             substr(r$created_at[[1]] %||% "", 1, 16),
                             substr(r$updated_at[[1]] %||% "", 1, 16))),
                # 配套文件树压在最后一行：上面三行是"这条技能是什么"，
                # 这一块是"它身上还挂着什么"，放最后不打断前者的阅读节奏。
                tree_block
              )
            ),
            div(class = "dsapp-skill-sum",
                if (nzchar(r$summary[[1]])) r$summary[[1]]
                else substr(gsub("\\s+", " ", body), 1, 90)),
            # ★ V13 item 4：内置技能里有几篇是几万字的（一个仓库提炼成一篇），
            #   而挂载之后正文是**整段**进提示词的。不显示体量的话，用户挂了
            #   三篇长文，然后奇怪为什么这个对话"变笨了、还特别慢"。
            #   两千字以下不显示 —— 那才是绝大多数，标出来只是噪声。
            if (nch >= 2000)
              div(class = "small text-muted",
                  sprintf("正文约 %s 字%s", format(nch, big.mark = ","),
                          if (nch >= 20000) "（较长，建议一次只挂一篇）" else ""))
          ),
          div(class = "dsapp-skill-acts",
            act_link(if (mine || builtin) "查看 / 编辑" else "查看",
                     "view", sid, "eye"),
            # 内置技能不能改（见 skills.R 的说明），给一条"另存为我的"，
            # 否则用户想微调内置技能时无路可走 —— 只能自己从头敲一遍。
            # ★ V13.7 item 6：别人放进公共库的那批同理 —— **能读不能写**。
            #   原来这里只判了 builtin，可见性一放宽就会出现"编辑别人的技能、
            #   保存时弹一句「保存失败」"（库里那句 UPDATE 带着 user_id，
            #   改到 0 行；报错文案完全指不到真正的原因）。
            if (builtin || !mine)
              act_link("另存为我的", "fork", sid, "copy")
            else
              act_link("删除", "del", sid, "trash", cls = "dsapp-skill-a-del")
          )
        )
      })

      div(class = "dsapp-skill-list",
        # ⚠️ data-input 挂在这个容器上（不是每行一个）：app.js 那条 toggle
        #    处理器是"找到最近的 [data-input]，把开着的全部报给它"，一个容器
        #    对着一串 details 正是它期待的形态。
        #
        # ⚠️ data-input-order 是**另一个** input（拖完之后的那串 id）。两个
        #    属性挂同一个元素上没问题，但要分得清：一个是"开着哪几个"，
        #    一个是"从上到下是谁"。合成一个的话，一次开合就会把顺序报一遍。
        `data-input` = ns("sk_open"),
        `data-input-order` = ns("sk_order"),
        div(class = "small text-muted mb-2",
            sprintf("共 %d 条。勾选在「言出法随」页输入框上方的「技能」里。%s",
                    nrow(df),
                    if (can_drag) {
                      "点标题展开看详情；下面的 ⠿ 可以拖动排序（键盘：Tab 到它，上下方向键）。"
                    } else if (nzchar(trimws(input$q %||% ""))) {
                      "搜索时不能拖动排序 —— 先清空搜索框。"
                    } else {
                      ""
                    })),
        rows)
    })

    # 行内动作：**一个** input（ns("sk_act")）带 `动作|技能号`，由下面这一个
    # observer 分派。
    #
    # ⚠️ 绝不写成"每行注册一个 observeEvent(ns(paste0('view_', id)))"。
    #    在 renderUI 里动态注册 observer，Shiny **不会**在下次重渲染时把
    #    上一次那批销毁掉 —— 每改一次技能就多一批永不回收的 observer，
    #    而且它们捕获的是**当时那份列表**（技能已被删掉时，点一个残留按钮
    #    会去打开一个不存在的技能）。这个坑本仓库在文件页的产物列表和
    #    设置页的节点名册上各踩过一次，见 mod_files.R:408 那段。
    act_link <- function(label, act, arg, ico = NULL,
                         cls = "dsapp-skill-a") {
      js <- sprintf("Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
                    jsonlite::toJSON(ns("sk_act"), auto_unbox = TRUE),
                    jsonlite::toJSON(paste0(act, "|", arg), auto_unbox = TRUE))
      tags$a(href = "#", class = cls, onclick = js,
             if (!is.null(ico)) icon(ico), " ", label)
    }

    observeEvent(input$sk_act, {
      v <- as.character(input$sk_act %||% "")
      if (!nzchar(v)) return()
      parts <- strsplit(v, "|", fixed = TRUE)[[1]]
      if (length(parts) < 2) return()
      act <- parts[[1]]
      # 技能号来自浏览器，**不能信**：这里只做类型收敛，归属检查在
      # dsapp_skill_get / dsapp_skill_delete 里（见 skills.R 的说明）。
      sid <- suppressWarnings(as.integer(parts[[2]]))
      if (is.na(sid)) return()
      # 第三段是配套文件的**相对路径**（只有 peek 用得到）。
      # ⚠️ 用 paste 把剩下的段拼回去，而不是要求"恰好三段"：
      #    POSIX 的文件名里可以有 `|`，而这里是库里的字符串、没人保证过它
      #    不含。要求恰好三段的表现是"点了某个文件没反应"，且只在少数
      #    文件名上复现 —— 最难查的那一类。
      arg2 <- if (length(parts) > 2L) paste(parts[-(1:2)], collapse = "|") else NULL

      if (act == "peek") {
        # 点开一个配套文件看内容（V13.12 item 13）。
        # 只有"存了内容的文本文件"才给这条路 —— 界面侧只是不给链接，
        # 但输入值是可以伪造的，所以这里**必须**自己再判一次，
        # 二进制/超限的一律当成没有。
        got <- tryCatch(dsapp_skill_file_get(sid, arg2, con = dsapp_db(cfg)),
                        error = function(e) NULL)
        if (is.null(got) || !isTRUE(got$stored) || is.null(got$text)) {
          return(showNotification("这个文件没有随技能保存内容（太大或是二进制）",
                                  type = "warning"))
        }
        showModal(modalDialog(
          title = tagList(icon("file-lines"), " ", got$path),
          size = "l", easyClose = TRUE,
          div(class = "small text-muted mb-2",
              sprintf("%s · 只读（在技能编辑器里不能改，它跟着技能本体走）",
                      dsapp_fmt_bytes(got$bytes))),
          tags$pre(class = "dsapp-skill-pre", got$text),
          footer = modalButton("关闭")
        ))
      } else if (act == "view") {
        # ★ V13.7 item 6：别人的公共技能走**只读预览**，不走编辑器。
        #   走编辑器的话，用户会以为能改（输入框是活的、按钮写着"保存"），
        #   敲完一屏点保存才被拒 —— 那是最气人的一种失败。
        #   内置那条路维持原样（它能改到的只有"另存为我的"，且是老行为）。
        row <- dsapp_skill_get(sid, viewer_id = state$user_id,
                               con = dsapp_db(cfg))
        if (is.null(row)) {
          # ★ V13.7 item 2：原来是一句「刷新一下列表」—— 把平台的缓存陈旧
          #   说成了用户的待办。重新拉一遍列表本来就是平台一秒能做完的事，
          #   直接做掉，然后**陈述**事实（普通消息，不是 error、也不是
          #   warning：这里没有任何东西出错）。
          return(dsapp_notify_stale("这条技能",
                                    refresh = function() sk_ver(sk_ver() + 1L)))
        }
        if (dsapp_skill_owned(row, state$user_id) ||
            isTRUE(row$builtin[[1]] == 1)) {
          open_editor(sid)
        } else {
          view_shared(row)
        }
      } else if (act == "fork") {
        open_editor(NULL, from = sid)
      } else if (act == "del") {
        row <- dsapp_skill_get(sid, viewer_id = state$user_id,
                               con = dsapp_db(cfg))
        if (is.null(row)) {
          # ★ V13.7 item 2：原来是一句「刷新一下列表」—— 把平台的缓存陈旧
          #   说成了用户的待办。重新拉一遍列表本来就是平台一秒能做完的事，
          #   直接做掉，然后**陈述**事实（普通消息，不是 error、也不是
          #   warning：这里没有任何东西出错）。
          return(dsapp_notify_stale("这条技能",
                                    refresh = function() sk_ver(sk_ver() + 1L)))
        }
        ask_delete(sid, row$name[[1]])
      }
    }, ignoreNULL = TRUE)

    # =========================================================================
    # 编辑器（新建 / 编辑 / 另存为 / 生成结果，四条路共用）
    # =========================================================================
    # `edit_id` 是**正在编辑的那条**（NULL = 新建）。
    # `body0` 等是打开时的初值，用来在保存时判断"改没改过" —— 没改就直接关掉，
    # 不用往库里写一次（写一次会把 updated_at 刷新，而那个时间是用来判断
    # "这条技能多久没动过了"的）。
    edit_id <- reactiveVal(NULL)
    # 打开编辑器时选的池。⚠️ 必须是 reactiveVal，不能是 open_editor 里的
    # 局部变量：保存按钮的 handler 是**另一个**作用域（observeEvent(input$f_save)），
    # 看不见 open_editor 的局部量。用局部量的表现是"保存时报 object 'sc' not found"，
    # 而弹窗不关 —— 用户敲的一屏内容还在，但他永远存不进去。
    edit_scope <- reactiveVal("private")
    # 「另存为我的」时**从哪条复制**（NULL = 不是复制来的）。
    #
    # ⚠️ 为什么不在 open_editor 里保存时顺手复制：保存要用户点一下才发生，
    #    而"从哪条复制"是打开编辑器那一刻的事实。存成局部变量的话，f_save
    #    那个作用域看不见它；存成一个普通变量又会被下一个"新建"覆盖 ——
    #    表现是"先点了 A 的另存为、又点了新建、保存出来的是 A 的副本文件"。
    # 配套文件（V13.12 item 13）尤其要跟着走：只复制正文的话，副本里的
    # SKILL.md 会指向一堆**在自己身上不存在**的 templates/ 路径。
    edit_from <- reactiveVal(NULL)

    # ---- 只读预览：别人放进公共库的技能（V13.7 item 6）----
    #
    # 为什么单独一个弹窗而不是把编辑器置灰：Shiny 的 textInput / textAreaInput
    # 要置灰只能往 ... 里塞 disabled 属性，两个控件行为不一致，而且置灰的输入框
    # 在用户看来仍然是"我能改，只是现在不行"。干脆不给输入框 —— 就一段只读的
    # 内容加一个明确的出口（另存为我的）。
    view_target <- reactiveVal(NULL)

    view_shared <- function(row) {
      sid <- as.integer(row$id[[1]])
      view_target(sid)
      nch <- nchar(row$body[[1]] %||% "")
      showModal(modalDialog(
        title = tagList(icon("book-open"), " ", row$name[[1]]),
        size = "l", easyClose = TRUE,
        div(class = "d-flex align-items-center gap-2 flex-wrap mb-2",
          span(class = "badge text-bg-primary", "公共"),
          if (nzchar(row$summary[[1]] %||% ""))
            span(class = "text-muted", row$summary[[1]]),
          span(class = "text-muted small",
               sprintf("· 正文约 %s 字", format(nch, big.mark = ",")))),
        div(class = "dsapp-warn mb-2",
          icon("lock"),
          " 这条技能是别人放进公共库的，你可以看、可以勾选到自己的对话里，",
          tags$b("但不能改"), "。想改就「另存为我的」，复制一份成你自己的。"),
        if (nzchar(row$tags[[1]] %||% ""))
          div(class = "mb-2 small text-muted",
              icon("tags"), " ", row$tags[[1]]),
        tags$pre(class = "dsapp-skill-pre", row$body[[1]] %||% ""),
        footer = tagList(
          modalButton("关闭"),
          actionButton(ns("v_fork"), "另存为我的",
                       class = "btn-primary", icon = icon("copy"))
        )
      ))
    }

    observeEvent(input$v_fork, {
      sid <- view_target()
      removeModal()
      view_target(NULL)
      if (is.null(sid)) return()
      open_editor(NULL, from = sid)
    }, ignoreNULL = TRUE)

    open_editor <- function(sid = NULL, from = NULL, prefill = NULL) {
      nm <- ""; sm <- ""; tg <- ""; bd <- ""
      title <- "新建技能"
      # ★ V13.7 item 6：编辑器里也要能选池。
      #   默认值分三种情况，故意的：
      #   · 编辑已有的        → 跟着它现在的档位（不传 scope 时就等于不改）
      #   · 另存为我的        → private。复制一份的意图是"我想要自己的版本"，
      #                        默认也扔进公共库的话，用户一不留神就把
      #                        半成品推出去了；想发布他自己会勾。
      #   · 新建 / 生成后确认 → 跟着**当前正在看的池**。"我在公共库里点新建"
      #                        这个动作本身就是"我要往公共库加一条"。
      sc <- if (identical(pool(), "public")) "public" else "private"

      if (!is.null(sid)) {
        row <- dsapp_skill_get(sid, viewer_id = state$user_id,
                               con = dsapp_db(cfg))
        if (is.null(row)) {
          return(showNotification("找不到这条技能", type = "error"))
        }
        nm <- row$name[[1]]; sm <- row$summary[[1]]
        tg <- row$tags[[1]]; bd <- row$body[[1]]
        sc <- dsapp_skill_scope_norm(row$scope[[1]] %||% "private")
        title <- "编辑技能"
        edit_id(sid)
      } else if (!is.null(from)) {
        # 另存为我的：**名字要改**，不然会撞上唯一索引（skills.R 里
        # 按账号 + 名字唯一）。加个后缀而不是弹窗问 —— 用户点这一下的
        # 意图很明确，中途再问一次只是多一步。
        row <- dsapp_skill_get(from, viewer_id = state$user_id,
                               con = dsapp_db(cfg))
        if (is.null(row)) {
          return(showNotification("找不到这条技能", type = "error"))
        }
        nm <- paste0(row$name[[1]], "（副本）"); sm <- row$summary[[1]]
        tg <- row$tags[[1]]; bd <- row$body[[1]]
        sc <- "private"
        title <- "另存为我的技能"
        edit_id(NULL)
      } else if (!is.null(prefill)) {
        nm <- prefill$name %||% ""; sm <- prefill$summary %||% ""
        tg <- prefill$tags %||% ""; bd <- prefill$body %||% ""
        title <- "确认技能内容"
        edit_id(NULL)
      } else {
        edit_id(NULL)
      }
      # ⚠️ 放在分支**外面**、showModal **之前**：四个分支各自要设一次的话，
      #    以后加第五个分支（比如"从文件导入"）时漏掉这一句，
      #    表现是"从那个入口新建的技能，池的初值是上一次打开编辑器时留下的" ——
      #    用户会莫名其妙地把自己的一条技能发布出去。
      edit_scope(sc)
      # 同理放在分支外面：`from` 就是 open_editor 的入参，四个分支里只有
      # 「另存为我的」那条会传它，其余传 NULL —— 在这里无条件写一次，
      # 比在每个分支里记得清一次可靠。
      edit_from(from)

      showModal(modalDialog(
        title = title, size = "l", easyClose = FALSE,
        textInput(ns("f_name"), "技能名（在列表和勾选框里显示）",
                  value = nm, placeholder = "例：差异表达分析（DESeq2）"),
        textInput(ns("f_sum"), "一句话说明（可选）",
                  value = sm, placeholder = "例：按 DESeq2 官方流程走，含低表达过滤"),
        textInput(ns("f_tags"), "标签（可选，逗号分隔）",
                  value = tg, placeholder = "例：转录组,差异分析"),
        # ★ 池的选择（V13.7 item 6）。是 radio 不是下拉：只有两个选项，
        #   而且这一项**后果不小**（公共库所有人都看得见），
        #   摊开来比藏在下拉里更容易被看见。
        radioButtons(ns("f_scope"), "存到哪个池",
                     choices = scope_choices, selected = sc),
        textAreaInput(ns("f_body"), "技能内容（写给 AI 的要求）",
                      value = bd, rows = 14, width = "100%",
                      placeholder = paste(
                        "用祈使句写，越具体越好。例如：",
                        "1. 差异分析前先过滤低表达基因……",
                        "2. 出图一律 ggsave，dpi = 300……",
                        sep = "\n")),
        div(class = "small text-muted",
          icon("circle-info"),
          " 这段内容会在勾选它的对话里，随每一轮请求一起发给模型。",
          "写得越具体，效果越稳定；写成泛泛的「认真分析」没有用。"),

        # ---- 配套文件（V13.12 item 13）----------------------------------
        #
        # 只能对**已经存在**的技能做 —— 新技能还没有 id，附件无处可挂。
        # 这也是"给一条老技能补上模板"的正路：用户那条
        # 「Biomamba 教程制作规则」当初上传时 templates/ 被整段丢掉了，
        # 有了这块就不必删掉重建（重建还会拿到一个新 id，对话里勾过的
        # 那些关联会一起没）。
        if (!is.null(edit_id())) {
          fstat <- tryCatch(dsapp_skill_files_stat(edit_id(), con = dsapp_db(cfg)),
                            error = function(e) NULL)
          tagList(
            tags$hr(),
            div(class = "small",
              tags$b("配套文件"),
              if (!is.null(fstat) && fstat$n > 0)
                span(class = "text-muted",
                     sprintf("（现有 %d 个，共 %s）", fstat$n,
                             dsapp_fmt_bytes(fstat$bytes)))
              else span(class = "text-muted", "（还没有）")),
            div(class = "small text-muted mb-1",
              "正文里如果提到 ", tags$code("templates/…"),
              "、", tags$code("references/…"),
              " 这类路径，把那些文件/文件夹选在这里，",
              "勾选这条技能的对话就能在自己的工作区里读到它们。",
              "同名路径以这次选的为准，没选到的旧文件保持不动 ——",
              "所以补一个 templates/ 不会顺手把 references/ 删掉。"),
            # 两个框，和上面的"导入技能"弹窗同一个形状（用户已经认得这套）：
            # ⚠️ 必须是**两个**，不能合成一个。见 www/app.js 里那段说明 ——
            #    `.dsapp-dirupload` 里那个框会被强行加上 webkitdirectory，
            #    加上之后它**只能**选目录、选不了单个文件。合成一个的话，
            #    想挂一份孤零零的 references/style.md 就没路可走了
            #    （得先为它建个文件夹）。
            fileInput(ns("f_files"), NULL, multiple = TRUE, width = "100%",
                      buttonLabel = tagList(icon("file-circle-plus"), " 选择文件"),
                      placeholder = "还没选文件"),
            div(class = "dsapp-dirupload mt-2",
                `data-paths-input` = ns("f_dir_paths"),
                fileInput(ns("f_dir"), NULL, multiple = TRUE, width = "100%",
                          buttonLabel = tagList(icon("folder-tree"), " 选择文件夹"),
                          placeholder = "还没选文件夹")),
            div(class = "small text-muted",
              sprintf("单个文件上限 %s，一条技能合计上限 %s；超限的只记名字不存内容。",
                      dsapp_fmt_bytes(DSAPP_SKILL_FILE_MAX),
                      dsapp_fmt_bytes(DSAPP_SKILL_FILES_MAX))),
            # 想删单个文件？没有"删一个"这个动作 —— 见 f_clear_files 的说明。
            if (!is.null(fstat) && fstat$n > 0)
              div(class = "mt-1",
                actionLink(ns("f_clear_files"),
                           tagList(icon("trash-can"), " 清空全部配套文件"),
                           class = "small text-danger"))
          )
        },
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("f_save"), "保存", class = "btn-primary")
        )
      ))
    }

    observeEvent(input$f_save, {
      r <- dsapp_skill_save(
        id = edit_id(), user_id = state$user_id,
        name = input$f_name %||% "",
        summary = input$f_sum %||% "",
        body = input$f_body %||% "",
        tags = input$f_tags %||% "",
        # 编辑已有的不重设来源；新建的一律 manual（上传/生成那两条路
        # 会各自走自己的保存函数，不走这个按钮）。
        source = "manual",
        # ★ V13.7 item 6：池。`sc` 是打开编辑器时的初值，用户没动过就直接用；
        #   动过就用他选的。**永远传一个明确的值**，不传 NULL ——
        #   这里的语义是"编辑器里显示什么就存什么"，用户在弹窗里看到的
        #   和存进去的必须是同一件事。
        scope = input$f_scope %||% edit_scope(),
        con = dsapp_db(cfg))

      if (!isTRUE(r$ok)) {
        # ⚠️ 弹窗**不关**。关掉的话用户刚写了一屏的内容就没了，
        #    而失败原因多半只是重名 —— 改个名字再点保存就行。
        return(showNotification(r$msg, type = "error", duration = 8))
      }

      # ---- 编辑器里新选的配套文件（V13.12 item 13）----
      #
      # ⚠️ 这里是 **append**，不是整份替换。dsapp_skill_save 的 files 参数
      #    语义是"整份替换"（先 DELETE 再写），拿它来存用户这次补的文件，
      #    会把原有的整套附件删光 —— 而弹窗上没有任何地方提示"保存会删文件"。
      #    改成按路径追加/覆盖之后，"补一个 templates/" 就真的只是补。
      # ⚠️ 编辑已有技能才走这条路。新建时那个 fileInput 根本没渲染
      #    （见 open_editor 里的 if (!is.null(edit_id()))），所以
      #    input$f_files 是 NULL，不会误触发。
      n_add <- 0L; n_skip_add <- 0L
      if (!is.null(edit_id())) {
        # 两个框合并。⚠️ 用 c() 拼起来再一次性 set：分两次 set 的话，
        # 第二次会带着 append 把第一次的结果再叠一遍 —— 同名路径互相覆盖，
        # 结果是对的，但"新增了几个"的计数会虚高，而那个数字要报给用户。
        nf <- c(files_from_input(input$f_files, NULL),
                files_from_input(input$f_dir, input$f_dir_paths))
        if (length(nf)) {
          st <- tryCatch(dsapp_skill_files_set(edit_id(), nf,
                                               con = dsapp_db(cfg),
                                               append = TRUE),
                         error = function(e) NULL)
          if (!is.null(st)) { n_add <- st$n; n_skip_add <- st$skipped }
        }
      }

      # ---- 「另存为我的」要把配套文件一起搬过来（V13.12 item 13）----
      # 复制失败**不算**保存失败：正文已经稳稳落库了，为了几十个附件把
      # 整次保存判死、还把弹窗留着让用户重敲一遍，是更坏的结果。
      # 所以这里只提示，不拦。
      n_copied <- 0L
      src_from <- edit_from()
      if (!is.null(src_from)) {
        n_copied <- tryCatch(
          as.integer(dsapp_skill_files_copy(as.integer(src_from),
                                            as.integer(r$id),
                                            con = dsapp_db(cfg))),
          error = function(e) 0L)
      }

      removeModal()
      edit_id(NULL)
      edit_from(NULL)
      sk_ver(sk_ver() + 1)
      # 三件事都可能发生（补附件 / 复制附件 / 都没发生），文案按实际做成的
      # 那几件拼。只说"已保存"的话，用户补了 40 个文件却看到一句和平时
      # 一模一样的提示，会怀疑到底存进去没有。
      showNotification(
        paste0("已保存",
               if (n_copied > 0L) sprintf("，连同 %d 个配套文件", n_copied) else "",
               if (n_add > 0L) sprintf("，新增 %d 个配套文件", n_add) else "",
               if (n_skip_add > 0L) sprintf("（%d 个超过上限，只记了名字）",
                                            n_skip_add) else ""),
        type = "message")
    })

    # 清空一条技能的全部配套文件。
    #
    # ⚠️ 只做"全清"，不做"删单个"：删单个需要先让用户看见清单并勾选，
    #    那是另一个弹窗和另一套交互；而真正会用到的场景只有一个 ——
    #    "这套附件传错了/不想要了"。做全清，然后把重建这件事交给
    #    编辑器里那个"选择文件/文件夹"（它本来就是追加语义）。
    observeEvent(input$f_clear_files, {
      sid <- edit_id()
      if (is.null(sid)) return()
      dsapp_skill_files_set(sid, list(), con = dsapp_db(cfg))
      sk_ver(sk_ver() + 1)
      removeModal()
      showNotification("配套文件已清空，正文没有动", type = "message")
    }, ignoreNULL = TRUE)

    # =========================================================================
    # 删除
    # =========================================================================
    # 待删的那条。确认弹窗是**异步**的（用户可能过很久才点确定，也可能
    # 直接关掉），所以目标得存在一个 reactiveVal 里，不能靠闭包传 ——
    # 闭包传的话，用户点开 A 的删除框、又点了 B 的删除框，确定下去删的是 A。
    del_target <- reactiveVal(NULL)

    ask_delete <- function(sid, name) {
      showModal(modalDialog(
        title = "确认删除技能",
        p(sprintf("确定删除「%s」吗？", name)),
        tags$ul(class = "small",
          tags$li("技能库里的这条内容会被删掉。"),
          tags$li("已经勾选了它的对话，下次发消息时", tags$b("就不会再用它了"), "。"),
          tags$li("对话内容和产出文件", tags$b("都不受影响"), "。")
        ),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_del"), "删除", class = "btn-danger")
        )
      ))
      del_target(sid)
    }

    observeEvent(input$do_del, {
      sid <- del_target()
      del_target(NULL)
      if (is.null(sid)) return()
      r <- dsapp_skill_delete(sid, state$user_id, con = dsapp_db(cfg))
      removeModal()
      if (!isTRUE(r$ok)) {
        return(showNotification(r$msg, type = "error", duration = 8))
      }
      sk_ver(sk_ver() + 1)
      showNotification("已删除", type = "message")
    })

    # =========================================================================
    # 工具栏：新建 / 上传 / 生成
    # =========================================================================
    # ⚠️ 工具栏上那三个按钮各自是独立的 input，**每一个都要有 handler**。
    #    漏掉一个的表现是"点了完全没反应"，服务端一条日志都没有 —— 浏览器
    #    把 input 发上来了，只是没人接。tests/ui_v8/skills.py 就是靠这个抓
    #    出来的（当时 upload / gen 都接了，就 new 没接）。
    observeEvent(input$new, {
      open_editor()
    })

    observeEvent(input$upload, {
      showModal(modalDialog(
        title = "上传技能文件", size = "l", easyClose = TRUE,
        p(class = "small text-muted mb-2",
          "支持 ", tags$code(".md"), " / ", tags$code(".txt"),
          "。每个文件变成一条技能。文件里可以这样写元信息："),
        tags$pre(class = "dsapp-skill-pre",
"---
name: 差异表达分析
summary: 按 DESeq2 官方流程走
tags: 转录组,差异分析
---

1. 先过滤低表达基因……
2. 出图一律 ggsave……"),
        p(class = "small text-muted",
          "不写也行 —— 那就拿文件里第一个 ", tags$code("# 标题"),
          " 当技能名，再不行就用文件名。"),
        fileInput(ns("up_files"), NULL, multiple = TRUE, width = "100%",
                  accept = c(".md", ".markdown", ".txt"),
                  buttonLabel = "选择文件", placeholder = "还没选文件"),
        # V9 item 12：整个文件夹一起导入。
        # ⚠️ .dsapp-dirupload / data-paths-input 是**功能性的**，见
        #    www/app.js 和 mod_files.R 里同一处写法的说明。
        div(class = "dsapp-dirupload mt-2",
            `data-paths-input` = ns("up_dir_paths"),
            fileInput(ns("up_dir"), NULL, multiple = TRUE, width = "100%",
                      buttonLabel = tagList(icon("folder-tree"), " 选择文件夹"),
                      placeholder = "还没选文件夹")),
        p(class = "small text-muted mt-1 mb-0",
          icon("circle-info"),
          # ★ V13.12 item 13：这段话原来写的是"子目录里的 .md/.txt 会被
          #   一起导入，其他类型自动跳过" —— 那是**老行为**，也正是把用户的
          #   templates/ 整个吃掉的那条规则。现在两种走法并存，得说清楚
          #   分界在哪，否则用户不知道自己那个目录会变成一条还是好几条。
          " 选文件夹时：目录里只要有 ", tags$code("SKILL.md"),
          "，整个目录就导入成**一条**技能，其余文件（模板、参考文档、脚本）",
          "作为配套文件一起存下来；没有 ", tags$code("SKILL.md"),
          " 的目录，则只导入子目录之外的 .md / .markdown / .txt，",
          "其余文件跳过（会报数量）。空文件夹不会被选中（浏览器只上报文件）。"),
        # ★ V13.7 item 6：用户原话「用户上传的时候需要可以选择上传的
        #   skills 池类别」。默认跟着**当前正在看的池**：站在公共库里点上传，
        #   意图多半就是往公共库加；站在我的技能里点，就是给自己加。
        #   ⚠️ 但一定要让他看见并确认 —— 传一批内部流程文档进公共库
        #     是不可逆的（别人可能已经勾走了），所以这一项不给默认藏起来。
        radioButtons(ns("up_pool"), "导入到哪个池",
                     choices = scope_choices,
                     selected = if (identical(pool(), "public")) "public"
                                else "private"),
        uiOutput(ns("up_preview")),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("up_do"), "导入", class = "btn-primary")
        )
      ))
    })

    # 读取一个上传文件，处理编码。
    #
    # ⚠️ V12 item 4 起这份实现搬到了 utils.R 的 dsapp_read_text_file() ——
    #    环境配置上传也要读同一类文件（Windows 记事本存出来的 GBK 文本），
    #    两处各写一份的话，编码这个坑只会修到其中一处。
    read_upload <- function(path) dsapp_read_text_file(path)

    # 能当技能导入的后缀。
    # ⚠️ 文件夹上传时**必须**自己过滤：webkitdirectory 那个框的 accept 属性
    #    各家浏览器行为不一致（有的干脆忽略），一个装满 .csv/.bam 的项目
    #    目录会一股脑全塞进来，然后每个都变成一条几万字的"技能"。
    skill_ext_ok <- function(nm) {
      grepl("\\.(md|markdown|txt)$", nm, ignore.case = TRUE)
    }

    # 一个技能文件夹的"入口文件名"。按 Claude Code 的约定，一个技能目录靠
    # 根下的 SKILL.md 认领，其余文件都是它的配套材料。
    is_skill_main <- function(base) tolower(base) %in% c("skill.md")

    # 读原始字节（配套文件要二进制原样存，不能走 read_upload 那条解码路）。
    read_raw <- function(path) tryCatch(readBin(path, "raw", file.size(path)),
                                        error = function(e) NULL)

    # 把一个 fileInput 的选中项转成 dsapp_skill_files_set 要的 list(path,raw,bytes)。
    #
    # 上传对话框和技能编辑器两处都要做同一件事，且都有两个坑要一起绕：
    #   · 相对路径来自**下标对齐**的另一个输入（webkitdirectory 收不到路径时
    #     就退回文件名，宁可不带目录也不能张冠李戴）；
    #   · 超过单文件上限的**不读**，只登记路径 + 真实大小。
    files_from_input <- function(f, paths) {
      if (is.null(f) || nrow(f) == 0) return(list())
      rels <- rep(NA_character_, nrow(f))
      if (!is.null(paths) && length(paths) == nrow(f)) rels <- as.character(paths)
      rels[is.na(rels)] <- f$name[is.na(rels)]
      out <- list()
      for (i in seq_len(nrow(f))) {
        p <- dsapp_skill_path_norm(rels[[i]])
        if (is.null(p)) next
        sz <- f$size[[i]] %||% NA_real_
        if (is.na(sz)) sz <- tryCatch(file.size(f$datapath[[i]]),
                                      error = function(e) NA_real_)
        if (is.na(sz)) next
        if (sz > DSAPP_SKILL_FILE_MAX) {
          out[[length(out) + 1L]] <- list(path = p, raw = NULL, bytes = sz)
        } else {
          out[[length(out) + 1L]] <- list(path = p, raw = read_raw(f$datapath[[i]]),
                                          bytes = sz)
        }
      }
      out
    }

    # 把"单文件"和"文件夹"两个输入合并成同一串待导入项。
    #
    # ★ V13.12 item 13：文件夹这条路原来**只会留下平铺的 .md**，其它一律
    #   计数跳过。而真实的技能文件夹（用户那份「Biomamba 教程制作规则」就是）
    #   长这样：
    #       biomammba_tutorial/
    #         SKILL.md            ← 正文
    #         templates/…/*.rmd   ← 正文里点名要用的模板
    #         templates/…/*.html
    #   老逻辑把 templates/ 整个丢掉，只把 SKILL.md 存成一条纯文本技能 ——
    #   于是正文里那句「参考 templates/R语言教程/xxx」指向一个**不存在**的
    #   路径，模型只能瞎猜。
    #
    #   现在的口径：**一个顶层目录里只要有 SKILL.md，整个目录就是一个技能**，
    #   其余文件按相对路径存成配套文件。没有 SKILL.md 的目录退回老行为
    #   （平铺 .md 各成一条），这样"传一堆散装 md"这个常见用法不受影响。
    parsed <- reactive({
      out <- list()
      skipped <- 0L

      # 一个顶层目录 → 一条"文件夹技能"。
      # `rows` 是这个目录下的**全部**文件行（含 SKILL.md 自己）。
      make_folder_skill <- function(dir_name, rows) {
        main_i <- which(vapply(rows$name, is_skill_main, logical(1)))
        main_i <- main_i[!grepl("/", rows$rel[main_i], fixed = TRUE)]
        if (!length(main_i)) return(NULL)
        main_i <- main_i[[1]]
        if (isTRUE(rows$size[[main_i]] > 1024 * 1024)) return(NULL)

        txt <- read_upload(rows$datapath[[main_i]])
        if (is.null(txt)) return(NULL)
        s <- dsapp_skill_parse(txt, rows$name[[main_i]])
        s$err <- NULL
        # 名字用 SKILL.md 里的标题（解析不出来才退回目录名）—— 用户认得的是
        # 「Biomamba 教程制作规则」，不是 `biomammba_tutorial`。
        if (!nzchar(s$name %||% "") || identical(s$name, rows$name[[main_i]])) {
          s$name <- dir_name
        }
        s$rel <- rows$rel[[main_i]]

        # 其余文件 → 配套文件。路径**相对这个顶层目录**（把
        # `biomammba_tutorial/` 这一段切掉）—— 正文里写的是
        # `templates/…`，不是 `biomammba_tutorial/templates/…`。
        fs <- list(); n_big <- 0L
        for (k in seq_len(nrow(rows))) {
          if (k == main_i) next
          rp <- rows$rel[[k]]
          sub <- sub("^[^/]+/", "", rp)
          # 嵌套的 SKILL.md（子技能）不当附件：它多半是另一个技能，
          # 塞进来只会让主技能的附件列表里混进一份互相矛盾的正文。
          if (is_skill_main(rows$name[[k]]) &&
              !grepl("/", sub, fixed = TRUE)) next
          if (is.na(sub) || !nzchar(sub)) next
          np <- dsapp_skill_path_norm(sub)
          if (is.null(np)) { skipped <<- skipped + 1L; next }
          sz <- rows$size[[k]]
          if (isTRUE(sz > DSAPP_SKILL_FILE_MAX)) {
            # 大文件**只登记路径，不读它**。读进来再扔会白占几十 MB 内存，
            # 而这一步是同步跑的、跑在主线程上 —— 卡的是所有人。
            fs[[length(fs) + 1L]] <- list(path = np, raw = NULL, bytes = sz)
            n_big <- n_big + 1L
          } else {
            fs[[length(fs) + 1L]] <- list(path = np, raw = read_raw(rows$datapath[[k]]),
                                          bytes = sz)
          }
        }
        s$files <- fs
        s$n_big <- n_big
        s
      }

      take <- function(f, paths, dir_mode) {
        if (is.null(f) || nrow(f) == 0) return(invisible(NULL))
        # 相对路径按**下标**和文件行对齐（两边都是 FileList 的顺序）。
        # 长度对不上就整批不用 —— 宁可把 A 的路径安到 B 头上，不如退回
        # 文件名，那至少只是名字难看，不会张冠李戴。
        rels <- rep(NA_character_, nrow(f))
        if (!is.null(paths) && length(paths) == nrow(f)) {
          rels <- as.character(paths)
        }
        rels[is.na(rels)] <- f$name[is.na(rels)]
        rels <- vapply(rels, function(x) dsapp_skill_path_norm(x) %||% "",
                       character(1))
        # 已经被"文件夹技能"收走的行。用**单独的向量**记，不靠把 rel 清空 ——
        # 后者分不清"收走了"和"路径不合法被归一成空"，会把后者也一起静默吞掉。
        used <- rep(FALSE, nrow(f))

        # ---- 先挑出"带 SKILL.md 的顶层目录"，整目录收成一条技能 ----
        if (isTRUE(dir_mode)) {
          tops <- unique(sub("/.*$", "", rels[grepl("/", rels, fixed = TRUE)]))
          tops <- tops[nzchar(tops)]
          for (d in tops) {
            rows_i <- which(startsWith(rels, paste0(d, "/")))
            if (!length(rows_i)) next
            sub_df <- f[rows_i, , drop = FALSE]
            sub_df$rel <- rels[rows_i]     # make_folder_skill 要按相对路径切
            fs_row <- make_folder_skill(d, sub_df)
            if (is.null(fs_row)) next
            out[[length(out) + 1]] <<- fs_row
            used[rows_i] <- TRUE
          }
        }

        for (i in seq_len(nrow(f))) {
          nm <- f$name[[i]]
          rel <- rels[[i]]
          if (used[[i]]) next              # 被上面的文件夹收走了
          if (!nzchar(rel)) { skipped <<- skipped + 1L; next }
          if (isTRUE(dir_mode) && grepl("/", rel, fixed = TRUE) &&
              !skill_ext_ok(nm)) {
            skipped <<- skipped + 1L
            next
          }
          # 单个文件 1 MB 封顶。技能正文本身另有 2 万字的上限（见 skills.R），
          # 这里挡的是"用户手滑传了一个几百 MB 的日志" —— 那会把整页卡住。
          if (isTRUE(f$size[[i]] > 1024 * 1024)) {
            out[[length(out) + 1]] <<- list(
              name = nm, summary = "", tags = "", body = "", rel = rel,
              err = "超过 1 MB，没有导入")
            next
          }
          txt <- read_upload(f$datapath[[i]])
          if (is.null(txt)) {
            out[[length(out) + 1]] <<- list(
              name = nm, summary = "", tags = "", body = "", rel = rel,
              err = "读不出来")
            next
          }
          s <- dsapp_skill_parse(txt, nm)
          s$err <- NULL
          s$rel <- rel
          out[[length(out) + 1]] <<- s
        }
        invisible(NULL)
      }

      take(input$up_files, NULL, FALSE)
      take(input$up_dir, input$up_dir_paths, TRUE)

      if (!length(out) && !skipped) return(NULL)
      attr(out, "skipped") <- skipped
      out
    })

    output$up_preview <- renderUI({
      ps <- parsed()
      if (is.null(ps) || !length(ps)) return(NULL)
      skipped <- attr(ps, "skipped") %||% 0L
      div(class = "mt-2",
        div(class = "small text-muted mb-1", sprintf("将导入 %d 条：", length(ps))),
        lapply(ps, function(s) {
          # 文件夹导入时同名文件很常见（每个子目录一个 README.md），
          # 只显示文件名的话用户分不清哪条是哪条 —— 把相对路径带上。
          where <- if (!is.null(s$rel) && !is.na(s$rel) &&
                       grepl("/", s$rel, fixed = TRUE)) {
            span(class = "text-muted", " · ", dirname(s$rel))
          }
          if (!is.null(s$err)) {
            return(div(class = "small text-danger",
                       icon("circle-xmark"), " ", s$name, where, " —— ", s$err))
          }
          div(class = "small mb-1",
            icon("circle-check"), " ",
            tags$b(s$name), where,
            if (nzchar(s$summary)) span(class = "text-muted", " · ", s$summary),
            span(class = "text-muted",
                 sprintf("（%d 字）", nchar(s$body))),
            # 文件夹技能：把"还带了几个文件"说出来。用户传的是一个目录，
            # 只回一句"将导入 1 条"会让他以为剩下的都被吞了。
            if (length(s$files %||% list())) {
              span(class = "text-muted",
                   sprintf(" · 另带 %d 个文件%s",
                           length(s$files),
                           if ((s$n_big %||% 0L) > 0)
                             sprintf("（其中 %d 个超过 2 MB，只记名字不存内容）",
                                     s$n_big) else ""))
            })
        }),
        if (skipped > 0) {
          div(class = "small text-muted mt-1",
              icon("circle-info"),
              sprintf(" 另有 %d 个非 .md/.txt 文件已跳过。", skipped))
        }
      )
    })

    observeEvent(input$up_do, {
      ps <- parsed()
      if (is.null(ps) || !length(ps)) {
        return(showNotification("先选文件或文件夹", type = "warning"))
      }
      n_ok <- 0; n_files <- 0L; errs <- character(0)
      # 池的选择在**循环外面**取一次。放在循环里读 input$up_pool 的话，
      # 一批文件走到一半用户改了单选，前面几条私有、后面几条公共 ——
      # 而界面上只有一个"导入中"的提示，他永远不知道分界在哪。
      up_sc <- dsapp_skill_scope_norm(input$up_pool %||% "private")
      for (s in ps) {
        if (!is.null(s$err)) { errs <- c(errs, sprintf("%s：%s", s$name, s$err)); next }
        # 重名时**不覆盖**，加个序号存成新的一条。
        # 覆盖的话用户传两份不同版本的同名文件，第二份会悄悄吃掉第一份；
        # 而"导入"这个动作在用户心里是**增加**，不是替换。
        nm <- s$name
        # ⚠️⚠️ 这里必须**显式**要 "mine" 池（V13.7 item 6）。
        #    my_skills() 现在跟着界面上的池走，而"这个名字是不是已经被我占了"
        #    问的是**我拥有的那一份**，和用户眼下在看哪个池无关。
        #    跟着 pool() 走的话，站在公共库里上传一批同名文件时，
        #    taken 里没有我自己的私有技能 → 不去重名 → INSERT 撞上
        #    (user_id, name) 唯一索引 → 整条报"保存失败，可能重名了"，
        #    而用户看到的是一句没头没脑的失败。
        existing <- dsapp_skills_list(state$user_id, con = dsapp_db(cfg),
                                      pool = "mine")
        if (!is.null(existing) && nrow(existing)) {
          taken <- existing$name[is.na(existing$user_id) |
                                 existing$user_id == (state$user_id %||% NA)]
          k <- 2
          while (nm %in% taken) {
            nm <- sprintf("%s (%d)", s$name, k); k <- k + 1
          }
        }
        r <- dsapp_skill_save(NULL, user_id = state$user_id,
                              name = nm, summary = s$summary,
                              body = s$body, tags = s$tags,
                              source = "upload", scope = up_sc,
                              # ★ V13.12 item 13：文件夹技能把配套文件一并落库。
                              #   走 save() 的 files 参数而不是存完再单独 set() ——
                              #   名字可能因为重名被改成「xxx (2)」，而 r$id 是
                              #   save 自己查回来的那一行，只有在这里传才不会张冠李戴。
                              files = s$files %||% NULL,
                              con = dsapp_db(cfg))
        if (isTRUE(r$ok)) {
          n_ok <- n_ok + 1
          n_files <- n_files + length(s$files %||% list())
        } else errs <- c(errs, sprintf("%s：%s", nm, r$msg))
      }
      # 两个输入框都重置：弹窗虽然关了，但下次打开时如果浏览器认为
      # "选中项没变"，change 不会触发，用户会看到上次那批文件还挂在那里。
      session$sendCustomMessage("dsapp:resetUpload", list(id = ns("up_files")))
      session$sendCustomMessage("dsapp:resetUpload", list(id = ns("up_dir")))

      removeModal()
      sk_ver(sk_ver() + 1)
      if (n_ok > 0) {
        showNotification(
          sprintf("导入了 %d 条技能%s", n_ok,
                  if (n_files > 0) sprintf("，含 %d 个配套文件", n_files) else ""),
          type = "message", duration = 6)
      }
      if (length(errs)) {
        showNotification(paste(errs, collapse = "；"), type = "error", duration = 12)
      }
    })

    # =========================================================================
    # 一句话生成
    # =========================================================================
    # ★ V13.7 item 3：和对话页那条路同一个口径 —— 现查库，别信内存副本。
    #   两处都查过才算"没配 Key"，否则用户会在库里明明有 Key 的时候被支使去
    #   设置页重填一遍（那正是"记忆功能有点问题"的一种形态）。
    key_now <- function() {
      k <- tryCatch(dsapp_api_key_effective(state$user_id, state$vendor,
                                            con = dsapp_db(cfg)),
                    error = function(e) "")
      if (nzchar(k)) return(k)
      state$api_key %||% ""
    }

    observeEvent(input$gen, {
      key <- key_now()
      if (!nzchar(key)) {
        # 没有 Key 就没法生成。**要说清楚去哪填**，不能只报"请先配置模型"——
        # 用户会去设置页翻，而 Key 其实在左栏最下面那个「模型服务」里。
        return(showNotification(
          "还没有配置模型 API Key。左栏「模型服务」那一页里填一把，再回来生成。",
          type = "warning", duration = 10))
      }
      gen_res(NULL)
      showModal(modalDialog(
        title = "用一句话生成技能", size = "l", easyClose = TRUE,
        p(class = "small text-muted mb-2",
          "说说你想要什么效果，模型会把它写成一条技能。",
          "生成完你还能改，确认了才存进库。"),
        textAreaInput(ns("gen_want"), NULL, rows = 4, width = "100%",
                      placeholder = paste(
                        "例：每次做差异分析都按 DESeq2 官方流程走，",
                        "先过滤低表达基因，出图要 300dpi 存成 pdf",
                        sep = "")),
        uiOutput(ns("gen_out")),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("gen_do"), "生成", class = "btn-primary",
                       icon = icon("wand-magic-sparkles"))
        )
      ))
    })

    observeEvent(input$gen_do, {
      want <- trimws(input$gen_want %||% "")
      if (!nzchar(want)) {
        return(showNotification("先用一句话说说你想要什么", type = "warning"))
      }
      key <- key_now()
      if (!nzchar(key)) {
        return(showNotification("还没有配置模型 API Key", type = "warning"))
      }
      if (!is.null(gen_job())) return()   # 已经在跑了，别重复发
      gen_res(NULL)
      # ⚠️ 丢给子进程，不在 Shiny 主进程里同步发。
      #    这是一次完整的 HTTP 请求，几秒到几十秒；在主线里等的话
      #    **所有用户**的界面一起卡住（Shiny Server 开源版一个应用一个 R 进程）。
      #    同一个坑在这个仓库里出现过很多次，见 llm.R 的 dsapp_llm_models_async。
      gen_job(dsapp_skill_gen_async(
        key, want,
        model = state$model, base_url = state$base_url, cfg = cfg,
        # ★ Test_V16.3 item 2：生成技能也是一次出网请求，同样要走用户
        #   自己填的代理。漏了这一处，用户会发现"对话能用了，但让它写技能
        #   就超时"——而那个超时看起来像是模型那边慢。
        proxy = tryCatch(dsapp_proxy_for(state$user_id), error = function(e) NULL)))
    })

    # 轮询。⚠️ 不能写成 `observe({ ... })` 里只读 gen_job() 就 invalidateLater —
    #    那样任务结束后这个 observe 会一直每 500ms 空转一次（gen_job 被置回
    #    NULL 才停），而"置回 NULL"正是下面这个 observe 自己干的。写成
    #    `req(gen_job())` 的形式，句柄一空就整个停下来。
    observe({
      # dsapp-selftest: self-reactive-ok gen_job
      #
      #   ⚠️ 显式豁免。读 gen_job()（下一行）又写它（取完置 NULL）。不会失控
      #     的理由：**写进去的是 NULL**，下一轮第 2 行就 return。读那一侧不能
      #     isolate —— 「生成技能」那个 observeEvent 写 gen_job(句柄) 就是靠
      #     这个依赖把轮询唤醒的（上面那段注释说的"句柄一空就整个停下来"，
      #     前提正是这里读得到它）。
      h <- gen_job()
      if (is.null(h)) return()
      invalidateLater(500)
      r <- dsapp_skill_gen_poll(h)
      if (!isTRUE(r$done)) return()
      gen_job(NULL)
      gen_res(if (isTRUE(r$ok)) list(ok = TRUE, value = r$value)
              else list(ok = FALSE, msg = r$msg %||% "生成失败"))
    })

    output$gen_out <- renderUI({
      if (!is.null(gen_job())) {
        return(div(class = "alert alert-info py-2 small mt-2 mb-0",
          icon("spinner", class = "fa-spin"), " 正在生成，通常十几秒……"))
      }
      r <- gen_res()
      if (is.null(r)) return(NULL)
      if (!isTRUE(r$ok)) {
        return(div(class = "alert alert-danger py-2 small mt-2 mb-0",
          icon("circle-xmark"), " ", r$msg))
      }
      v <- r$value
      div(class = "mt-2",
        div(class = "alert alert-success py-2 small mb-2",
          icon("circle-check"), " 生成好了，下面是模型写的内容。",
          "点「去确认」可以改完再存。"),
        div(class = "dsapp-skill-preview",
          div(class = "dsapp-skill-name", v$name),
          if (nzchar(v$summary %||% ""))
            div(class = "text-muted small", v$summary),
          tags$pre(class = "dsapp-skill-pre", v$body)
        ),
        div(class = "d-flex gap-2 mt-2",
          actionButton(ns("gen_use"), "去确认",
                       class = "btn-sm btn-primary", icon = icon("pen")),
          actionButton(ns("gen_again"), "重新生成",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("rotate"))
        )
      )
    })

    observeEvent(input$gen_use, {
      r <- gen_res()
      if (is.null(r) || !isTRUE(r$ok)) return()
      removeModal()
      # 汇进同一个编辑器 —— 用户看一眼、改两个字再存。直接入库的话，
      # 一条写歪的技能会在之后每一次对话里生效，而它不会自己过期。
      open_editor(NULL, prefill = r$value)
    })

    observeEvent(input$gen_again, {
      gen_res(NULL)
      # 不自动重发：重发要走 gen_do，而那个按钮在弹窗底部、
      # 现在的界面上是"重新生成"这个按钮。直接触发一次更省事，
      # 也不会因为用户改了上面那段描述而用了旧的。
      showNotification("改一下描述，再点「生成」", type = "message")
    })
  })
}
