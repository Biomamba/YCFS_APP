# =============================================================================
# 文献速递（V13.11 item 5）
# =============================================================================
# 用户的原话：「加一个"文献速递"版块，请帮我写好内置提示词，并且可以关联一些
# 文献整理的开源 skills，可以通过输入一系列关键词，自动返回最相关的 n 篇
# 文献精读/略读」。
#
# 追问过一次"检索到底怎么做"，三个选项里用户选的是
# **「交给 agent 用命令行检索」** —— 于是这一页**不做任何检索**，它只做两件事：
#
#   1. 把用户填的几个条件（关键词、几篇精读、几篇略读、年份、补充要求）
#      拼成一段写得好的提示词（dsapp_lit_prompt，在 R/prompts.R 里）
#   2. 新建一个对话，把这段提示词作为**第一条用户消息**发出去，
#      并把选中的技能挂到那个对话上
#
# 检索本身、筛选、写成 `文献速递.md`，全由 agent 在工作区里做。
#
# ---- 为什么检索不写在这页里 --------------------------------------------------
#
# 见 R/prompts.R 里 dsapp_lit_prompt 顶上那段"为什么是拼一段提示词"。
# 一句话：文献接口会变、检索是个来回的过程、结果要落成文件 —— 这三件事
# agent 循环都比一次性 R 函数做得好。
#
# ---- 这页和对话页的关系 ------------------------------------------------------
#
# **这一页不自己发请求**，它把活交给对话页：新建对话 + 发第一条消息 + 挂技能，
# 三件事都发生在 mod_chat.R 的那条 observeEvent(input$lit_go) 里。
#
# 绕这一道是**故意的**。如果在这里直接调 LLM：
#   * api_key / 模型名 / 执行确认那一整套闸门都得在这儿再实现一遍
#   * 流式输出的渲染、停止按钮、任务记录、token 计数全都没有
#   * 用户看着这页发呆，而他真正想看的东西在"言出法随"那一页里长出来
# 交给对话页之后，上面每一条都是现成的，而且**用户看得见他点了之后发生了什么**。
#
# ⚠️ 通信方式：本模块 sendCustomMessage 给前端 → 前端切页 + 发一个
#    **带命名空间**的 input（chat-lit_go）。不能在 app.js 里硬编码
#    "chat-lit_go" —— 那个前缀是 mod_chat 的命名空间，改了模块 id 就静默失效。
#    所以 id 由 mod_chat 跟着 dsapp:init 一起下发，见那段注释。
# =============================================================================

# ---- 下面这些纯助手搬去 R/litsub.R 了（Test_V15.2）-------------------------
#
#   dsapp_lit_keywords / dsapp_lit_skill_choices / DSAPP_LIT_SKILL_NAMES /
#   DSAPP_LIT_SKILL_FALLBACK / dsapp_lit_default_skill / dsapp_lit_skill_order /
#   DSAPP_LIT_NOTE_PRESETS
#
# ⚠️ **它们不在这里定义了，但这一页照常调它们**（同一个 globalenv，
#    app.R 两份都 source）。
#
# 为什么必须搬走：Test_V15.2 的定时订阅要在**没有 Shiny 的 Rscript**里
# 跑一遍速递（run_scheduler.R，它和 .dsapp_agent_worker 一样跳过所有
# mod_*.R 再 source）。订阅的新增表单要分割关键词、订阅的执行路径也要
# 分割关键词 —— 留在这个文件里的话，调度器一 source 就是
# could not find function，而那个报错完全指不到真正的原因。
#
# ⚠️ 搬走不是抄一份：这两边共用 R/litsub.R 里那一份。
# -------------------------------------------------------------------------

mod_lit_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "dsapp-page",
      # ---- 说明 ----
      card(
        card_header(icon("newspaper"), " 文献速递"),
        card_body(
          class = "py-2",
          p(class = "mb-2",
            "填几个关键词，平台会新建一个对话，让 AI ",
            tags$b("用命令行去公开文献库里检索"),
            "（Europe PMC / PubMed / bioRxiv / Crossref），筛出相关的几篇，",
            "按", tags$b("精读"), "和", tags$b("略读"), "两档整理成 ",
            tags$code("文献速递.md"), " 放在这个对话的工作目录里。"),
          # ★ V13.16 item 27：把"产出是什么体例"摆在页面上。用户原话
          #   「文献阅读的报告不应该是检索文献过程的画外音，而应该是文献阅读
          #   汇报」—— 这条准则写在提示词里是给模型的，写在页面上是给**人**的：
          #   用户得先知道会拿到什么，才好在结果不对时说出来是哪儿不对。
          p(class = "mb-2",
            "报告是一份", tags$b("文献阅读汇报"), "：正文讲的是",
            tags$b("这些文献说了什么"), "（主要结论、关键证据、有没有分歧），",
            "而检索用了哪些库、跑了哪些检索式这类", tags$b("过程信息"),
            "只作为文末的一小段附录，不占正文。"),
          p(class = "text-muted small mb-2",
            "默认会挂上两条技能：",
            tags$b("academic-search"), "（怎么检索、怎么核验、怎么去重）和 ",
            tags$b("deeppapernote"), "（精读一篇时该写到什么程度）。",
            "在下面的「技能」里可以换掉。"),
          p(class = "mb-0 text-muted small",
            "检索过程你可以在对话里全程看到，也能随时打断或让它换个方向重来。"),

          # ---- 两个子页面（★ V15.5 item 5）--------------------------------
          # 用户原话：「在文献速递里加"学术前沿订阅"子页面」。追问之后选的是
          # 「复用文献速递那套」—— 所以这儿**不是**两套表单：切到「学术前沿」
          # 只是把方向预设**填进下面同一套输入框**，往下走的路（开始检索 /
          # 定时订阅 / 发邮件）一条都没分叉。
          #
          # ⚠️ 用 radioButtons 而不是两颗粒子按钮 / navset：选中的是哪一个
          #    由 Shiny 自己管，不需要 JS 去切 class，也不会有"按钮上写着
          #    选中、input 里其实是另一个"这种两套真相。
          tags$div(class = "dsapp-lit-modes",
            radioButtons(ns("mode"), NULL, inline = TRUE,
                         choices = c("关键词检索" = "kw",
                                     "学术前沿订阅" = "frontier"),
                         selected = "kw"))
        )
      ),

      # ---- 检索条件 ----
      card(
        card_header(icon("magnifying-glass"), " 检索条件"),
        card_body(
          class = "py-2",
          # 前沿模式专属那一块。**在条件卡的最上面**，因为它填的正是
          # 下面那些框 —— 顺序反过来（填的在上、被填的在下）用户要点两次
          # 滚动才看得见自己填出了什么。
          uiOutput(ns("frontier_panel")),
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("kw"),
                       "关键词"),
            textAreaInput(ns("kw"), NULL, value = "", rows = 3,
                          width = "100%",
                          placeholder = paste0(
                            "一行一个，或者用逗号 / 顿号隔开。例如：\n",
                            "空间转录组\n肝癌\n免疫微环境")),
            # ⚠️ 这里是 HTML 不是 Markdown：写 `**可以有空格**` 会**原样**
            #    显示成带星号的字。要加粗就用 tags$b()。
            tags$div(class = "dsapp-lit-hint",
              "⚠️ 一个关键词里", tags$b("可以有空格"),
              "（", tags$code("single cell RNA"), " 算一个词）。",
              "多个关键词请用换行或逗号分开。",
              "中文关键词不用自己翻成英文 —— 提示词里已经让 AI 先转成英文再检索。")
          ),
          uiOutput(ns("kw_echo")),

          tags$div(class = "dsapp-lit-row",
            tags$div(class = "dsapp-lit-field",
              tags$label(class = "control-label", `for` = ns("n_read"),
                         "精读几篇"),
              numericInput(ns("n_read"), NULL, value = 3, min = 0, max = 20,
                           step = 1, width = "100%")
            ),
            tags$div(class = "dsapp-lit-field",
              tags$label(class = "control-label", `for` = ns("n_skim"),
                         "略读几篇"),
              numericInput(ns("n_skim"), NULL, value = 5, min = 0, max = 20,
                           step = 1, width = "100%")
            ),
            tags$div(class = "dsapp-lit-field",
              tags$label(class = "control-label", `for` = ns("year_from"),
                         "只看这些年的（可留空）"),
              tags$div(class = "dsapp-lit-years",
                # ⚠️ 留空要写 `value = ""`，**不能**写 `value = NA`：
                #    NA 会被渲染成 `value="NA"`，而 <input type="number">
                #    解析不了它，浏览器控制台每次渲染都报一句
                #    'The specified value "NA" cannot be parsed'。不致命，
                #    但每次打开这一页都刷一条，真出问题时会被埋掉。
                numericInput(ns("year_from"), NULL, value = "",
                             min = 1900, max = 2100, step = 1,
                             width = "100%"),
                span(class = "dsapp-lit-dash", "–"),
                numericInput(ns("year_to"), NULL,
                             value = as.integer(format(Sys.Date(), "%Y")),
                             min = 1900, max = 2100, step = 1,
                             width = "100%")
              )
            )
          ),

          # ---- 告诉 AI 注意事项（item 18）----
          # 从前是一个光秃秃的 textInput「还想让它注意什么（可留空）」：
          # 用户不知道该写什么，空的居多。现在给几条常用的勾选项 + 一条
          # 自己写的输入框，两者**都会**写进提示词（勾的在前）。
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("extra"),
                       "告诉 AI 注意事项"),
            # ⚠️ class 加在**外面包的这层 div** 上：checkboxGroupInput()
            #    没有 `...`（同下面 skill_pick 那段注释），多传的参数会
            #    变成 "unused argument"，UI 直接报错。
            tags$div(class = "dsapp-lit-notes",
              checkboxGroupInput(
                ns("extra_presets"), NULL,
                # 文字和值用同一份（值就是那句要写进提示词的话）——
                # 见 DSAPP_LIT_NOTE_PRESETS 顶上的注释。
                choices = stats::setNames(DSAPP_LIT_NOTE_PRESETS,
                                          DSAPP_LIT_NOTE_PRESETS))),
            textInput(ns("extra"), NULL, value = "", width = "100%",
                      placeholder = "也可以自己写一句，例如：只看人的样本")
          )
        )
      ),

      # ---- 挂哪些技能 ----
      # ⚠️ 外面这层 div 是给「关联技能」那颗按钮当落点的（V15.5 item 4）：
      #    按钮不复制一份技能清单，它把用户**滚到这张卡上**并闪一下 ——
      #    清单只有这一份，两边不会各自长歪。
      div(class = "dsapp-lit-skills-card",
        card(
          card_header(icon("wand-magic-sparkles"), " 关联技能"),
          card_body(
            class = "py-2",
            p(class = "text-muted small mb-2",
              "勾上的技能会挂到新建的那个对话上。内置技能都来自开源仓库，",
              "展开技能页可以看到它们的上游地址和许可。"),
            uiOutput(ns("skill_pick")),
            uiOutput(ns("skill_sums"))
          )
        )
      ),

      # ---- 提交 ----
      card(
        card_body(
          class = "py-2",
          # ★ V15.5 item 4：三颗按钮排在一起。用户原话：「定时订阅按钮可以
          #   直接显示在开始检索按钮旁边」「"看看会发生什么"换成"关联技能"
          #   即可」。
          #
          # ⚠️ 原来第二颗是「看看会发什么」（提示词预览），现在**没有**了 ——
          #    用户要的是"关联技能"，那就不要留一个还在偷偷干别的事的同位置
          #    按钮。预览那条路（peek / peek_box / dsapp:flash 到 .dsapp-lit-preview）
          #    一并删干净，不留半截。
          tags$div(class = "dsapp-lit-actions",
            actionButton(ns("go"), "开始检索",
                         icon = icon("paper-plane"),
                         class = "btn-primary"),
            actionButton(ns("skills_btn"), "关联技能",
                         icon = icon("wand-magic-sparkles"),
                         class = "btn-outline-secondary"),
            actionButton(ns("sub_btn"), "定时订阅",
                         icon = icon("clock"),
                         class = "btn-outline-secondary")
          ),
          p(class = "dsapp-lit-hint mt-2 mb-0",
            icon("circle-info"), " 「关联技能」带你到下面的技能清单；",
            "「定时订阅」展开订阅设置（到点自动跑一遍同样的检索）。",
            "两颗都不发起检索。"),
          uiOutput(ns("go_hint"))
        )
      ),

      # ---- 发到我的邮箱（★ Test_V15.2 item 1）----
      #
      # ⚠️ 整张卡归 output 管：没配 SMTP 的部署里它**连标题都不出现**。
      #    理由同 mod_settings 那张邮件卡（D4：不加开关，用配没配齐判断）。
      uiOutput(ns("mail_lit_card")),

      # ---- 定时订阅（★ Test_V15.2 item 2）----
      #
      # ⚠️ 这张卡**不**跟着 SMTP 藏：到点自动跑一遍检索、把速递留在工作区里，
      #    这件事和"发不发邮件"是两件独立的事。没配邮件只是跑完不发信。
      #
      # ★ V15.5 item 4：它现在**默认收起来**，由上面那颗「定时订阅」按钮
      #   打开（用户原话：「点击后显示设置页面」）。外层那个 div 在打开时才
      #   带上 .dsapp-lit-subopen —— 按钮滚动/flash 找的就是这个只存在于
      #   "打开之后"的选择器，否则会滚到一个还没渲染出来的空盒子上。
      div(class = "dsapp-lit-subwrap", uiOutput(ns("litsub_card")))
    )
  )
}


mod_lit_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config

    kws <- reactive(dsapp_lit_keywords(input$kw))

    # ---- 关键词回显 ----
    # 为什么不直接信任用户填的那串字：他用的是逗号还是换行、中间有没有
    # 多余空格，切出来是几个词只有切了才知道。这排小标签就是**告诉他
    # 我们切成了什么** —— 切错了当场就看得出来，而不是等检索完发现
    # 搜出来的东西驴唇不对马嘴。
    output$kw_echo <- renderUI({
      k <- kws()
      if (!length(k)) return(NULL)
      tags$div(class = "dsapp-lit-chips",
        lapply(k, function(x) span(class = "dsapp-lit-chip", x)),
        span(class = "dsapp-lit-chipcount",
             sprintf("共 %d 个关键词", length(k)))
      )
    })

    # ---- 技能勾选 ----
    choices <- reactive({
      dsapp_lit_skill_choices(con = dsapp_db(cfg()))
    })

    # ⚠️ 用 Shiny 自带的 checkboxGroupInput，**不要**手写 `<input
    #    type="checkbox">`。手写过一版（想在每个选项下面显示简介），
    #    问题是：手写的 checkbox Shiny **不会**自动收成一个 input，
    #    得自己挂 JS 去 setInputValue，还得处理"renderUI 重画之后
    #    监听器没了"和"HTML 上写死的 checked 服务端并不知道"两件事。
    #    简介改用下面那个跟着勾选走的说明块来显示，一样的信息，少一套
    #    要维护的机制。
    # 已经勾上的技能往前提（V13.12 item 16）。
    # 用户原话：「文献速递已关联的技能请显示在最上方」—— 内置技能现在有
    # 19 条，默认勾的那两条（academic-search / deeppapernote）是按 id 排在
    # **最底下**的，而这一块的高度是封顶的（见 codex.css 里 .dsapp-lit-skills
    # 那段），不往上提就得先滚动才看得见自己到底挂了什么。
    #
    # ⚠️ 勾选顺序 ≠ 勾上的先后：前端送上来的值是按 **DOM 顺序**排的
    #    （Shiny 的 checkbox binding 就是按元素顺序取值），所以重排之后
    #    勾中的那批内部仍然保持技能库的原序，只有"勾中/没勾"这两组会换位。
    #    这是故意的：每次点击都按"最近勾的排最前"重排的话，列表会在光标
    #    底下跳，第二次点同一条时很容易点到刚挪过来的另一条上。
    #
    # ⚠️ picked() 用 NULL 表示"还没收到前端事件"，**不是** character(0)。
    #    用 character(0) 当初始值的话，"用户把勾全取消"和"刚进页面"两种
    #    状态分不开 —— 前者会退回默认勾选，表现是"取消不掉，一刷新又回来了"。
    # ⚠️⚠️ `ignoreInit = TRUE` 是**必须的**，实测踩过：observeEvent 默认
    #    ignoreInit = FALSE，也就是**启动时先跑一次**，那时 input$skills 还
    #    是 NULL —— 于是 picked() 立刻被写成 character(0)，第一次 renderUI
    #    读到的就是"用户什么都没勾"，默认那两条根本不勾上。
    #    表现：整张技能表一条都没勾（连 default 都没了），而页面不会报任何错。
    #    实测日志（/tmp 实例，DBG render: picked= def=13,14 on= sel=）：
    #    def 是对的、on 是空的，就是这个 init 抢先跑了一次。
    picked <- reactiveVal(NULL)
    observeEvent(input$skills,
                 picked(as.character(input$skills %||% character(0))),
                 ignoreNULL = FALSE, ignoreInit = TRUE)

    output$skill_pick <- renderUI({
      ch <- choices()
      if (is.null(ch)) {
        return(p(class = "text-muted small mb-0",
                 "技能库还没准备好，这次就不挂技能了 —— 不影响检索。"))
      }
      def <- dsapp_lit_default_skill(ch)
      # ⚠️ class 加在**外面自己包的这层 div** 上，不要写成
      #    `checkboxGroupInput(..., class = "dsapp-lit-skills")` ——
      #    checkboxGroupInput() **没有 `...`**（selectInput 有），
      #    多传的参数是 "unused argument"，renderUI 当场报错、整块
      #    uiOutput 渲染成空。表现是"技能列表一条都没有"，而且页面上
      #    看不出为什么。这一块包起来是为了让 codex.css 限制高度
      #    （16 条内置技能竖排会把「开始检索」顶出屏幕）。
      ids <- as.character(ch$id)
      # 还没收到过前端事件 → 按默认勾选排；收到过 → 按真实勾选排。
      on  <- if (is.null(picked())) as.character(def) else picked()
      ord <- dsapp_lit_skill_order(ids, on)
      # ord 已经保证"勾上的都在前面"，所以 sel 就是 ord 的前若干个。
      sel <- intersect(ord, on)
      tags$div(class = "dsapp-lit-skills",
        checkboxGroupInput(
          ns("skills"), NULL,
          # ⚠️ choices 和 selected 用的是**同一批 id**（ord / sel），顺序不同
          #    但集合相同。只改 choices 不改 selected 的话，重画之后勾选状态
          #    会被 DOM 的默认值（全不勾）顶掉 —— 表现是"点一下，勾全没了"。
          choices  = stats::setNames(ord, as.character(ch$name)[match(ord, ids)]),
          selected = sel))
    })

    # 勾了哪几条 → 把那几条的简介显示出来。
    # ⚠️ 简介不放进选项文字里：checkboxGroupInput 的选项名是**纯文本**，
    #    换行会被 HTML 折叠掉，塞进去只会得到一行特别长的字。
    output$skill_sums <- renderUI({
      ch <- choices()
      if (is.null(ch)) return(NULL)
      ids <- suppressWarnings(as.integer(input$skills))
      ids <- ids[!is.na(ids)]
      if (!length(ids)) {
        return(p(class = "dsapp-lit-hint mb-0",
                 "一条都没勾 —— 这次就按平台的通用规则做检索。"))
      }
      sel <- ch[ch$id %in% ids, , drop = FALSE]
      tags$div(class = "dsapp-lit-sums",
        lapply(seq_len(nrow(sel)), function(i) {
          tags$div(class = "dsapp-lit-sum",
            tags$span(class = "dsapp-lit-sum-name", sel$name[[i]]),
            tags$span(class = "dsapp-lit-sum-txt", sel$summary[[i]] %||% "")
          )
        })
      )
    })

    # 注意事项 = 勾的预设 + 自己写的那句（V13.12 item 18）。
    # ⚠️ 顺序固定成"预设在前、手写在后"，**不按用户的操作顺序**：
    #    预设是通用约束，手写那条通常更具体，放后面读起来才顺。
    # ⚠️ 手写为空时不要送一个 "" 进去：dsapp_lit_prompt 会把它当成一条
    #    空要点，提示词里多出一个光秃秃的 "- "。
    notes_now <- reactive({
      pre <- as.character(input$extra_presets %||% character(0))
      pre <- trimws(pre[!is.na(pre) & nzchar(pre)])
      # 只认得上表里有的：值是前端送上来的，改 DOM 就能塞任意文字进提示词。
      # 危害不大（提示词不是数据），但"浏览器发来的一律当不可信"这条
      # 规矩不该在这儿开口子 —— 和下面技能 id 的校验一个道理。
      pre <- pre[pre %in% DSAPP_LIT_NOTE_PRESETS]
      own <- trimws(as.character(input$extra %||% ""))
      own <- if (length(own) && !is.na(own[1]) && nzchar(own[1])) own[1] else NULL
      c(pre, own)
    })

    prompt_now <- reactive({
      k <- kws()
      if (!length(k)) return("")
      yr <- suppressWarnings(as.numeric(c(input$year_from, input$year_to)))
      yr <- if (all(is.finite(yr))) sort(yr) else NULL
      dsapp_lit_prompt(k, n_read = input$n_read, n_skim = input$n_skim,
                       years = yr, extra = notes_now(),
                       skills = chosen_skill_names())
    })

    # 勾中的技能**名字**。提示词里要按名字点名（见 dsapp_lit_prompt 的
    # `skills` 参数）：挂了 academic-search 就让它按那条技能检索，
    # 挂了 deeppapernote 就说清精读部分照它的证据要求写。
    #
    # ⚠️ 走名字而不是 id：id 是每个库自己种的，提示词里印一个数字
    #    （"按技能 19 检索"）模型完全不知道该干什么。
    # ⚠️ choices() 为 NULL（技能库还没种上）时返回空 —— 提示词就退回
    #    自带的通用检索说明，这条路径不能因为技能库的事整个走不通。
    chosen_skill_names <- reactive({
      ch <- choices()
      ids <- suppressWarnings(as.integer(input$skills))
      ids <- ids[!is.na(ids)]
      if (is.null(ch) || !length(ids)) return(character(0))
      as.character(ch$name[ch$id %in% ids])
    })

    output$go_hint <- renderUI({
      if (!length(kws())) {
        return(p(class = "dsapp-lit-hint mb-0 mt-2",
                 icon("circle-info"), " 先填至少一个关键词。"))
      }
      nr <- suppressWarnings(as.integer(input$n_read)[1])
      ns_ <- suppressWarnings(as.integer(input$n_skim)[1])
      if ((is.na(nr) || nr <= 0) && (is.na(ns_) || ns_ <= 0)) {
        return(p(class = "dsapp-lit-hint mb-0 mt-2",
                 icon("triangle-exclamation"),
                 " 精读和略读都是 0 篇 —— 那就没东西可找了，至少填一个。"))
      }
      NULL
    })

    # ---- 「关联技能」那颗按钮（★ V15.5 item 4）-----------------------------
    #
    # 用户原话：「"看看会发生什么"换成"关联技能"即可」，追问之后选的是
    # 「那颗按钮改名+改功能」—— 它现在显示**当前挂上了哪些技能**。
    #
    # ⚠️ 实现方式是"滚过去 + 闪一下"，**不是**在按钮底下再长一份清单。
    #    技能清单那张卡就在同一页上（.dsapp-lit-skills-card）。复制一份出来
    #    的话，两边的勾选状态得各自维护，而"清单里写着挂了 A、实际挂的是 B"
    #    在屏幕上完全看不出来 —— 这类错这个仓库栽过。
    #
    # ⚠️ dsapp:flash 的 JS 会轮询等元素出现（最多 3 秒），所以这里不用
    #    自己 sleep；选中的元素**始终在页面上**，没有"跨一拍"的问题。
    observeEvent(input$skills_btn, {
      session$sendCustomMessage("dsapp:flash",
                                list(sel = ".dsapp-lit-skills-card"))
    }, ignoreInit = TRUE)

    # =======================================================================
    # 学术前沿订阅（★ V15.5 item 5）
    # =======================================================================
    #
    # 用户原话：「在文献速递里加"学术前沿订阅"子页面」。追问"前沿怎么定"
    # 之后选的是**「复用文献速递那套」**：不另起检索链路，这一页只负责把
    # 「方向 → 英文关键词」「时间窗」「两条默认技能」**填进下面那套共用的
    # 输入框**，之后照常走「开始检索」/「定时订阅」/「发到我的邮箱」。
    #
    # ⚠️ 为什么不给前沿单开一套 input：预览、邮件、定时订阅、技能 id 的
    #    只读校验**全都挂在共用输入上**。单开一套 = 这条链上每一环都要跟着
    #    分叉，而分叉出去的那份没人会记得同步（"两个真相"是这个仓库
    #    反复栽的坑）。
    mode_now <- reactive({
      m <- as.character(input$mode %||% "kw")[1]
      if (identical(m, "frontier")) "frontier" else "kw"
    })

    output$frontier_panel <- renderUI({
      if (!identical(mode_now(), "frontier")) return(NULL)
      tags$div(class = "dsapp-lit-frontier",
        p(class = "text-muted small mb-2",
          icon("bolt"), " 选一个方向，平台会把对应的", tags$b("英文关键词"),
          "和年份", tags$b("填进下面那套条件"),
          "（会覆盖你现在填的关键词），技能自动勾上检索和精读那两条。",
          "填完还能接着手改。"),
        tags$div(class = "dsapp-lit-field",
          tags$label(class = "control-label", `for` = ns("fr_dirs"),
                     "前沿方向"),
          # ⚠️ class 加在外面包的 div 上：checkboxGroupInput() 没有 `...`
          #    （同下面 skill_pick 那段注释）。
          tags$div(class = "dsapp-lit-notes",
            checkboxGroupInput(ns("fr_dirs"), NULL,
                               choices = names(DSAPP_LIT_FRONTIER_PRESETS),
                               selected = names(DSAPP_LIT_FRONTIER_PRESETS)[1]))
        ),
        tags$div(class = "dsapp-lit-field",
          tags$label(class = "control-label", `for` = ns("fr_window"),
                     "时间窗"),
          selectInput(ns("fr_window"), NULL, width = "100%",
                      choices = DSAPP_LIT_FRONTIER_WINDOWS,
                      selected = DSAPP_LIT_FRONTIER_WINDOW)
        )
      )
    })

    # 勾的方向 / 换的时间窗 → 抄进共用输入框。
    # ⚠️ 每一条 update* 的目标都必须**已经在 DOM 里**：关键词框、年份框、
    #    技能勾选框都是静态 UI 或已经渲染过的 renderUI，不会出现"发给一个
    #    还不存在的 input"。技能那一个例外见下面的守卫。
    apply_frontier <- function() {
      dirs <- as.character(input$fr_dirs %||% character(0))
      dirs <- dirs[dirs %in% names(DSAPP_LIT_FRONTIER_PRESETS)]
      if (!length(dirs)) return(invisible(FALSE))
      # ⚠️ unlist 拍平之后要 unique：两个方向里都有 "single-cell" 这类词时
      #    关键词框里会出现两遍，提示词里就是 `x、x`，看着像手滑。
      k <- unique(unlist(DSAPP_LIT_FRONTIER_PRESETS[dirs], use.names = FALSE))
      updateTextAreaInput(session, "kw", value = paste(k, collapse = "\n"))

      yr <- dsapp_lit_frontier_years(input$fr_window %||%
                                       DSAPP_LIT_FRONTIER_WINDOW)
      # ⚠️ 不限年份时 year_from 要送回 ""（**不是** NA）：NA 会被渲染成
      #    value="NA"，浏览器解析不了，控制台每次都报一句（见上面
      #    year_from 那个 numericInput 的注释）。
      updateNumericInput(session, "year_from",
                         value = if (is.na(yr[1])) "" else yr[1])
      updateNumericInput(session, "year_to", value = yr[2])

      # 预设技能 = 这页的默认那两条（academic-search / deeppapernote）。
      ch <- choices()
      def <- if (is.null(ch)) integer(0) else dsapp_lit_default_skill(ch)
      if (length(def)) {
        on <- unique(c(as.character(input$skills %||% character(0)),
                       as.character(def)))
        on <- on[on %in% as.character(ch$id)]
        # ⚠️ 只送 selected，**不**重送 choices：choices 一送就会在浏览器里
        #    重建整个勾选组，而 skill_pick 那个 renderUI 紧接着也会因为
        #    input$skills 变了而重画一遍 —— 两次重建撞在一起时，用户刚点的
        #    那个勾会被后一次顶掉。顺序的事交给 renderUI（它本来就按
        #    dsapp_lit_skill_order 把勾上的往上提）。
        updateCheckboxGroupInput(session, "skills", selected = on)
      }
      invisible(TRUE)
    }
    # ⚠️ ignoreInit = TRUE 在这里是**必须**的：面板一渲染出来，浏览器就会
    #    把 selected 的那一项报上来，那是一次真实的 input 变化（不是 init），
    #    正好用来完成"切到前沿模式就自动填一遍"。
    observeEvent(input$fr_dirs, apply_frontier(), ignoreInit = TRUE)
    observeEvent(input$fr_window, apply_frontier(), ignoreInit = TRUE)

    # ---- 开始检索 ----
    observeEvent(input$go, {
      k <- kws()
      if (!length(k)) {
        return(showNotification("先填至少一个关键词", type = "warning"))
      }
      nr <- suppressWarnings(as.integer(input$n_read)[1])
      ns_ <- suppressWarnings(as.integer(input$n_skim)[1])
      nr <- if (is.na(nr)) 0L else max(0L, nr)
      ns_ <- if (is.na(ns_)) 0L else max(0L, ns_)
      if (nr == 0L && ns_ == 0L) {
        return(showNotification("精读和略读至少填一个大于 0 的篇数",
                                type = "warning"))
      }
      if (is.null(state$user_id) || is.na(state$user_id)) {
        return(showNotification("还没登录，刷新页面再来一次", type = "warning"))
      }

      ids <- suppressWarnings(as.integer(input$skills))
      ids <- ids[!is.na(ids)]
      # ⚠️ 勾选是前端送上来的，**不能信**。这里是只读校验：送来的 id 必须
      #    真的在"这个账号看得见的内置技能"里，否则丢掉。不校验的话，
      #    改一下 DOM 就能把任意技能 id 挂到自己的对话上。危害不算大
      #    （技能是提示词，不是数据），但"浏览器发来的一律当不可信"这条
      #    规矩不该在这儿开个口子。
      ch <- choices()
      ids <- if (!is.null(ch) && length(ids))
        ids[ids %in% as.integer(ch$id)] else integer(0)

      # 标题用关键词拼，但**掐短**：会话列表一行放不下太长，而且
      # 标题只是用来在列表里认人的。
      title <- sprintf("文献速递：%s", paste(k, collapse = "、"))
      title <- substr(title, 1, 28)

      session$sendCustomMessage("dsapp:lit_go", list(
        prompt = prompt_now(),
        title  = title,
        skills = as.integer(ids)
      ))
      showNotification("正在新建对话并开始检索…", type = "message",
                       duration = 4)
    })

    # =======================================================================
    # 发到我的邮箱（★ Test_V15.2 item 1）
    # =======================================================================
    #
    # 和设置页那张测试卡共用 dsapp_mail_ui_watch()（入队 + 轮询回执）。
    #
    # ⚠️ 整张卡在没配 SMTP 时返回 NULL —— 理由见 dsapp_mail_ready 的 D4。
    mail_lit_watch <- dsapp_mail_ui_watch(cfg)

    digests <- reactiveVal(NULL)
    scan_digests <- function() {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        digests(NULL); return(invisible(NULL))
      }
      digests(tryCatch(
        dsapp_lit_find_digests(uid, cfg = cfg(), con = dsapp_db(cfg())),
        error = function(e) NULL))
      invisible(NULL)
    }
    # 登录后扫一次，之后靠「刷新列表」那颗按钮。
    #
    # ⚠️⚠️ 绝不挂 invalidateLater 定时扫。这个扫描要遍历该账号最近 200 个
    #    会话的工作区目录（每个都 list.files 一次），是全站唯一的那个 R 进程
    #    里最贵的一类操作。挂成轮询 = 每开一个页面就每 N 秒遍历一次磁盘，
    #    而"一个 5 秒一次的 du 就能把所有人的页面拖住"这条教训
    #    R/utils.R 里 dsapp_dir_size 那段写着。
    observeEvent(state$user_id, scan_digests(), ignoreNULL = TRUE)
    observeEvent(input$mail_lit_refresh, scan_digests(), ignoreInit = TRUE)

    output$mail_lit_card <- renderUI({
      if (!isTRUE(dsapp_mail_ready(cfg()))) return(NULL)
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return(NULL)
      to <- tryCatch(
        as.character(dsapp_user_by_id(uid, con = dsapp_db(cfg()))$email %||% "")[1],
        error = function(e) "")
      d <- digests()
      card(
        card_header(icon("envelope"), " 发到我的邮箱"),
        card_body(
          class = "py-2",
          if (!nzchar(to)) {
            p(class = "text-muted small mb-0",
              "这个账号没有填邮箱。先到「设置 → 账号」补一个，再来这里发。")
          } else tagList(
            p(class = "text-muted small mb-2",
              "把某一份跑好的速递发到 ", tags$code(to),
              "。正文里的图会一起带过去，Markdown 原件也会作为附件附上。"),
            if (is.null(d) || !nrow(d)) {
              p(class = "text-muted small mb-2",
                "还没找到速递。跑完一次检索之后点「刷新列表」再看看。")
            } else {
              # ⚠️ value 用**路径**，label 给人看。⚠️ 路径来自浏览器，
              #    下面那一段会拿它跟 digests() 里的清单核对 —— 不核对的话，
              #    改一下 DOM 就能让服务器把**别人工作区里的任意文件**当正文
              #    发到这个人的邮箱里去。
              selectInput(ns("mail_lit_pick"), NULL, width = "100%",
                          choices = stats::setNames(
                            d$path,
                            sprintf("%s · %s · %.0f KB",
                                    substr(d$title, 1L, 26L),
                                    substr(d$mtime, 1L, 16L),
                                    d$size / 1024)))
            },
            # ⚠️⚠️ 「刷新列表」**必须**在"一份都没有"时也出现。
            #    它原来跟着下拉一起藏在 else 分支里，于是列表为空时按钮
            #    也消失了 —— 而空列表恰恰是唯一需要按它的时刻，
            #    上面那句"点「刷新列表」再看看"成了一句指向不存在按钮的话。
            div(class = "d-flex gap-2",
              if (!is.null(d) && nrow(d))
                actionButton(ns("mail_lit_go"), "发这一份",
                             icon = icon("paper-plane"),
                             class = "btn-primary btn-sm"),
              actionButton(ns("mail_lit_refresh"), "刷新列表",
                           icon = icon("rotate"),
                           class = "btn-outline-secondary btn-sm")),
            # ⚠️ 回执是**自己一个 output**。并进这张卡的话，每换一次状态
            #    整张卡（连同上面那个下拉）都会重建，用户选的份数会被顶回
            #    第一项 —— 表现是"发完一封信，选择自己跳了"。
            uiOutput(ns("mail_lit_msg"))
          )
        )
      )
    })

    output$mail_lit_msg <- renderUI({
      note <- mail_lit_watch$note()
      uid <- state$user_id
      last <- if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) ""
              else tryCatch(
                dsapp_mail_last_error(uid, cfg = cfg(), con = dsapp_db(cfg())),
                error = function(e) "")
      tagList(
        if (nzchar(note)) tags$div(class = "small mt-2 text-muted", note),
        # 上次失败的原因常驻显示 —— 定时订阅是在没人看着的时候发信的。
        if (nzchar(last))
          tags$div(class = "small mt-2 text-danger",
                   icon("triangle-exclamation"), " 上次发信失败：", last)
      )
    })

    observeEvent(input$mail_lit_go, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        mail_lit_watch$note("请先登录。"); return()
      }
      p <- trimws(as.character(input$mail_lit_pick %||% "")[1])
      if (!nzchar(p)) { mail_lit_watch$note("先选一份速递。"); return() }
      # ★★ 白名单校验：送来的路径必须**真的在这个账号的速递清单里**。
      #    ⚠️ 这不是形式主义 —— 少了这一句，改一下浏览器的 DOM 就能让服务端
      #    把工作区里任意一个文件（包括别人的对话产出的东西）当正文发出去。
      d <- digests()
      if (is.null(d) || !nrow(d) || !(p %in% d$path)) {
        mail_lit_watch$note("这一份已经不在列表里了，点「刷新列表」再来一次。")
        return()
      }
      q <- dsapp_lit_mail_queue(uid, p, cfg = cfg(), con = dsapp_db(cfg()),
                                kind = "lit_manual", ref = "")
      if (!isTRUE(q$ok)) { mail_lit_watch$note(q$msg); return() }
      dsapp_mail_kick(cfg())
      mail_lit_watch$send(q$id)
    }, ignoreInit = TRUE)

    # =======================================================================
    # 定时订阅（★ Test_V15.2 item 2）
    # =======================================================================
    #
    # 这一页只做增删改查；**到点了真正去跑的是 run_scheduler.R**（systemd
    # timer 每 5 分钟起一次），不在这儿、也不在 Shiny 进程里 —— R worker
    # 空闲 5 秒就被杀，任何"挂在页面上的定时器"都不会活到点。
    #
    # ⚠️ 每一行的开关/删除按钮**不做成每行一个 actionButton**。
    #    动态 id 的按钮要配一堆观察器，而"在 observe 里建 observer"是
    #    这个仓库踩过的坑（Shiny 不会帮你销毁上一次建的那些，
    #    见 mod_files.R 里那段面包屑的说明）。改成：表格只读 + 一个单选
    #    + 一排共用按钮，和「历史任务」页那一排（重跑/停止/删除选中）同一个形状。
    subs_rev <- reactiveVal(0L)
    subs <- reactive({
      subs_rev()
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return(NULL)
      tryCatch(dsapp_litsub_list(uid, cfg = cfg(), con = dsapp_db(cfg())),
               error = function(e) NULL)
    })

    sub_note <- reactiveVal("")
    tz_cn <- function() cfg()$tz %||% "UTC"
    freq_cn <- c(daily = "每天", weekly = "每周", monthly = "每月")
    wd_cn <- c("周一", "周二", "周三", "周四", "周五", "周六", "周日")

    # ---- 这张卡默认收起来（★ V15.5 item 4）--------------------------------
    #
    # 用户原话：「定时订阅按钮可以直接显示在开始检索按钮旁边，点击后显示
    # 设置页面」。所以它是一个**按需展开的设置页**，不是常驻在页面底部
    # 的一大块 —— 常驻的话，加上邮件卡和技能卡，这一页要滚三屏才到底，
    # 而「开始检索」和订阅设置本来不该抢同一块屏幕。
    #
    # ⚠️ 默认**关着**还有个实际好处：订阅设置里那排 input（频率、时分、
    #    标题…）在收起时根本不在 DOM 里，不会参与任何 input 变化 ——
    #    也就没有"关着的时候谁把 sub_pick 读成了 NULL"这类问题。
    sub_open <- reactiveVal(FALSE)
    observeEvent(input$sub_btn, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        return(showNotification("登录之后才能建订阅", type = "warning"))
      }
      sub_open(!isTRUE(sub_open()))
      # ⚠️ flash 的选择器必须是**只有打开时才存在**的那个（.dsapp-lit-subopen，
      #    由下面 litsub_card 在打开时挂上）。选 .dsapp-lit-subwrap 的话，
      #    它是常驻的外壳，dsapp:flash 会立刻滚到一个**还是空的**盒子上，
      #    卡片随后才渲染出来 —— 表现是"点了按钮，页面滚了，但看不到东西"。
      if (isTRUE(sub_open())) {
        session$sendCustomMessage("dsapp:flash",
                                  list(sel = ".dsapp-lit-subopen"))
      }
    }, ignoreInit = TRUE)

    # 按钮上的字跟着开合走。不换的话，收起状态下按钮写着「定时订阅」、
    # 打开之后还是这四个字，用户没法知道再点一下会收起来。
    observe({
      updateActionButton(session, "sub_btn",
                         label = if (isTRUE(sub_open())) "收起订阅设置"
                                 else "定时订阅")
    })

    # 订阅自己的那套条件（★ V15.5 item 4 的「提供选项直接加载文献速递
    # 页面的配置」）。默认仍然**跟随上面**（= Test_V15.2 的老行为，
    # 老订阅的语义不变）；选「单独填一套」才露出这几个框。
    sub_src_now <- reactive({
      s <- as.character(input$sub_src %||% "page")[1]
      if (identical(s, "own")) "own" else "page"
    })

    # 「单独填一套」那几个框的初值 / 「加载」按钮抄的，都是**同一段取值**。
    # 抄成一处，两条路才不会各抄各的（比如漏了年份）。
    page_cfg <- function() {
      yr <- suppressWarnings(as.numeric(c(input$year_from, input$year_to)))
      yr <- if (all(is.finite(yr))) sort(yr) else c(NA_real_, NA_real_)
      list(kw = paste(kws(), collapse = "\n"),
           n_read = suppressWarnings(as.integer(input$n_read)[1]),
           n_skim = suppressWarnings(as.integer(input$n_skim)[1]),
           year_from = yr[1], year_to = yr[2])
    }

    load_page_cfg <- function() {
      pc <- page_cfg()
      updateTextAreaInput(session, "sub_kw", value = pc$kw)
      updateNumericInput(session, "sub_n_read",
                         value = if (is.na(pc$n_read)) 3L else pc$n_read)
      updateNumericInput(session, "sub_n_skim",
                         value = if (is.na(pc$n_skim)) 5L else pc$n_skim)
      updateNumericInput(session, "sub_yfrom",
                         value = if (is.na(pc$year_from)) "" else pc$year_from)
      updateNumericInput(session, "sub_yto",
                         value = if (is.na(pc$year_to)) "" else pc$year_to)
      invisible(TRUE)
    }

    observeEvent(input$sub_load, {
      if (!length(kws())) {
        return(showNotification("上面「检索条件」里还没填关键词，没东西可加载",
                                type = "warning"))
      }
      load_page_cfg()
      showNotification("已经把上面「检索条件」现在填的抄过来了，可以接着改。",
                       type = "message", duration = 5)
    }, ignoreInit = TRUE)

    # ⚠️⚠️ 卡片的**框**和**表格**是两个 output，故意的。
    #    合成一个的话，每次 subs_rev 变（启用 / 停用 / 删除 / 新建）整张卡
    #    都会重画，里面「新建一条」那张表单跟着被**重建** —— 用户填了一半的
    #    标题、时分、「建好就打开」全被打回默认值，而屏幕上没有任何提示，
    #    看起来就是"我点了一下删除，刚填的东西自己没了"。
    #    框只依赖登录状态，只有表格依赖 subs_rev。
    output$litsub_card <- renderUI({
      # ★ V15.5 item 4：收起来的时候连卡片都不渲染 —— 它是被上面那颗
      #   「定时订阅」按钮打开的设置页，不是常驻内容。
      if (!isTRUE(sub_open())) return(NULL)
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return(NULL)
      # ⚠️ 时区要**写出来**。"每天早上 8 点"在 UTC 库里是 0 点，界面上不写
      #    时区的话，用户永远不知道他看到的是哪个 8 点。
      #
      # ⚠️ 外面这层 .dsapp-lit-subopen 是**只在打开时**才存在的选择器，
      #    「定时订阅」那颗按钮滚动/flash 找的就是它（见上面那个 observer）。
      div(class = "dsapp-lit-subopen",
      card(
        card_header(
          class = "d-flex justify-content-between align-items-center",
          span(icon("clock"), " 定时订阅"),
          actionButton(ns("sub_close"), NULL, icon = icon("xmark"),
                       class = "btn-sm btn-outline-secondary")
        ),
        card_body(
          class = "py-2",
          # ⚠️ V15.5 item 3：这儿的重点原来写成 `**自己跑一遍新的检索**`，而
          #    `p()` 里的字符串是**纯文本**，Shiny 不会替你渲染 markdown ——
          #    用户看到的就是两个星号。要粗体只有一条路：`strong()`。
          p(class = "text-muted small mb-2",
            "到点了系统", strong("自己跑一遍新的检索"),
            "（用下面「这条订阅用什么条件」里那套），",
            "跑完把速递发到你的邮箱。每次都会真的调模型、烧这个账号的 token，",
            "所以默认关着，要自己打开。时间按 ", tags$code(tz_cn()), " 算。"),

          uiOutput(ns("sub_table")),

          tags$hr(),
          tags$b("新建一条"),

          # ---- 这条订阅用什么条件（★ V15.5 item 4）------------------------
          # 用户原话：「提供选项直接加载文献速递页面的配置」。
          #
          # ⚠️ 默认仍是「跟随上面」= Test_V15.2 的老行为，一个字都没变
          #    （老订阅的语义和界面位置都不动）。「单独填一套」是**新增**
          #    的一条路：让订阅可以跟当前正在看的这个题目不一样 ——
          #    "我在查 A，同时想让系统每周追 B"本来就是最常见的用法。
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("sub_src"),
                       "这条订阅用什么条件"),
            radioButtons(ns("sub_src"), NULL, inline = TRUE,
                         choices = c("跟随上面「检索条件」" = "page",
                                     "单独填一套" = "own"),
                         selected = "page")
          ),
          uiOutput(ns("sub_own_fields")),
          uiOutput(ns("sub_new_summary")),
          div(class = "d-flex gap-3 flex-wrap align-items-end",
            div(style = "min-width:110px",
              selectInput(ns("sub_freq"), "频率",
                          choices = c("每天" = "daily", "每周" = "weekly",
                                      "每月" = "monthly"),
                          selected = "weekly")),
            div(style = "min-width:110px",
              selectInput(ns("sub_wd"), "每周几",
                          choices = stats::setNames(1:7, wd_cn),
                          selected = 1)),
            div(style = "min-width:100px",
              numericInput(ns("sub_dom"), "每月几号", value = 1,
                           min = 1, max = 31, step = 1)),
            div(style = "min-width:90px",
              numericInput(ns("sub_hour"), "时", value = 8,
                           min = 0, max = 23, step = 1)),
            div(style = "min-width:90px",
              numericInput(ns("sub_min"), "分", value = 0,
                           min = 0, max = 59, step = 1)),
            div(class = "mb-3",
              textInput(ns("sub_title"), "标题（可不填）", value = "",
                        placeholder = "默认用关键词"))
          ),
          p(class = "text-muted small",
            "「每周几」只在频率是每周时用，「每月几号」只在每月时用。",
            "每月选了 29/30/31 的话，小月会自动顺延到当月最后一天 ——",
            "建好之后下面「下次运行」显示的就是实际会跑的时刻。"),
          checkboxInput(ns("sub_enabled"), "建好就打开（到点自动跑）",
                        value = TRUE),
          div(class = "d-flex gap-2 align-items-center",
            actionButton(ns("sub_add"), "新建订阅",
                         icon = icon("plus"), class = "btn-primary btn-sm"),
            uiOutput(ns("sub_msg"), inline = TRUE))
        )
      )
      )
    })
    observeEvent(input$sub_close, sub_open(FALSE), ignoreInit = TRUE)

    # 「单独填一套」的那几个框。**只有选了它才渲染** —— 跟随模式下它们
    # 一个字都不该出现在页面上（出现了用户会以为订阅存的是这里填的）。
    #
    # ⚠️⚠️ 初值一律走 `isolate()`。不 isolate 的话这个 renderUI 就依赖
    #    `kws()` / `input$n_read` 这些**上面那张表**的输入：用户在下面改
    #    订阅自己的关键词时，上面但凡动一下，整块会被重建 —— 他刚敲进去的
    #    东西全被打回初值，而屏幕上没有任何提示。这个仓库在定时订阅这张卡上
    #    已经栽过一次同样的事（见上面那段"框和表格是两个 output"）。
    output$sub_own_fields <- renderUI({
      if (!identical(sub_src_now(), "own")) return(NULL)
      pc <- isolate(page_cfg())
      tags$div(class = "dsapp-lit-own",
        tags$div(class = "dsapp-lit-field",
          tags$label(class = "control-label", `for` = ns("sub_kw"),
                     "关键词"),
          textAreaInput(ns("sub_kw"), NULL, rows = 3, width = "100%",
                        value = pc$kw,
                        placeholder = "一行一个，或者用逗号 / 顿号隔开")
        ),
        tags$div(class = "dsapp-lit-row",
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("sub_n_read"),
                       "精读几篇"),
            numericInput(ns("sub_n_read"), NULL, min = 0, max = 20, step = 1,
                         width = "100%",
                         value = if (is.na(pc$n_read)) 3L else pc$n_read)
          ),
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("sub_n_skim"),
                       "略读几篇"),
            numericInput(ns("sub_n_skim"), NULL, min = 0, max = 20, step = 1,
                         width = "100%",
                         value = if (is.na(pc$n_skim)) 5L else pc$n_skim)
          ),
          tags$div(class = "dsapp-lit-field",
            tags$label(class = "control-label", `for` = ns("sub_yfrom"),
                       "只看这些年的（可留空）"),
            tags$div(class = "dsapp-lit-years",
              numericInput(ns("sub_yfrom"), NULL, min = 1900, max = 2100,
                           step = 1, width = "100%",
                           value = if (is.na(pc$year_from)) "" else pc$year_from),
              span(class = "dsapp-lit-dash", "–"),
              numericInput(ns("sub_yto"), NULL, min = 1900, max = 2100,
                           step = 1, width = "100%",
                           value = if (is.na(pc$year_to)) "" else pc$year_to)
            )
          )
        ),
        p(class = "text-muted small mb-2",
          icon("circle-info"), " 技能仍然取上面「关联技能」里勾的那些 —— ",
          "订阅只存关键词、篇数、年份和上面的「注意事项」。"),
        actionButton(ns("sub_load"), "加载文献速递页面的配置",
                     icon = icon("download"),
                     class = "btn-outline-secondary btn-sm")
      )
    })

    # 表格 + 那一排动作按钮。**只有这一段**跟着 subs_rev 重画。
    output$sub_table <- renderUI({
      s <- subs()
      if (is.null(s) || !nrow(s)) {
        return(p(class = "text-muted small mb-0", "还没有订阅。"))
      }
      tagList(
        tags$table(
          class = "table table-sm align-middle dsapp-litsub",
          tags$thead(tags$tr(
            tags$th("关键词"), tags$th("频率"),
            tags$th("下次运行"), tags$th("上次结果"))),
          tags$tbody(lapply(seq_len(nrow(s)), function(i) {
            r <- s[i, , drop = FALSE]
            when <- if (isTRUE(as.integer(r$enabled) == 1L) &&
                        nzchar(r$next_at %||% "")) r$next_at else "（关着）"
            last <- switch(as.character(r$last_status %||% ""),
              ok      = "成功",
              running = "正在跑…",
              failed  = paste0("失败：", substr(r$last_error %||% "", 1L, 60L)),
              "还没跑过")
            tags$tr(
              tags$td(substr(as.character(r$keywords), 1L, 40L)),
              tags$td(sprintf("%s %02d:%02d%s",
                              freq_cn[[as.character(r$freq)]] %||% r$freq,
                              as.integer(r$hour), as.integer(r$minute),
                              if (identical(as.character(r$freq), "weekly"))
                                paste0("（", wd_cn[as.integer(r$weekday)], "）")
                              else if (identical(as.character(r$freq), "monthly"))
                                sprintf("（%d 号）", as.integer(r$day_of_month))
                              else "")),
              tags$td(class = "text-nowrap", when),
              tags$td(class = "small", last)
            )
          }))
        ),
        # ⚠️⚠️ 「选中哪一条」是**一个**下拉，绝不能每行画一个 radioButtons。
        #    每行一个的话页面上会出现 N 个 id 都叫 sub_pick 的容器 ——
        #    HTML 不允许重复 id，而 Shiny 的单选绑定只认**第一个**
        #    `#sub_pick`，于是只有第一行选得动、后面几行点了等于没点，
        #    而且不会报任何错（"看着能用、其实只有第一行有效"）。
        #    ⚠️ 会重画（subs_rev 变了就重建）正是这里要的：删掉一条之后
        #    剩下的选项自动补上，不会指着一个已经不存在的 id 做事。
        #    动作处理器读的是 input$sub_pick 的**当前值**，不另外存一份。
        div(class = "d-flex gap-2 flex-wrap align-items-end",
          div(style = "min-width:240px",
            selectInput(ns("sub_pick"), "选中一条",
                        choices = stats::setNames(
                          as.character(s$id),
                          sprintf("#%s %s%s",
                                  s$id, substr(as.character(s$keywords), 1L, 22L),
                                  ifelse(as.integer(s$enabled) == 1L, "", "（关着）"))))),
          div(class = "mb-3 d-flex gap-2",
            actionButton(ns("sub_on"), "启用",
                         icon = icon("play"), class = "btn-sm btn-outline-success"),
            actionButton(ns("sub_off"), "停用",
                         icon = icon("pause"), class = "btn-sm btn-outline-secondary"),
            actionButton(ns("sub_del"), "删除",
                         icon = icon("trash"), class = "btn-sm btn-outline-danger")))
      )
    })

    # 「会存下什么」的预览。⚠️ 它依赖的是**上面那张表单**的 input，所以
    # 用户在检索条件里改了关键词，这里会跟着变 —— 那正是想要的：
    # 建之前就看清楚到底会存下什么，而不是建完了去表格里比对。
    output$sub_new_summary <- renderUI({
      own <- identical(sub_src_now(), "own")
      if (own) {
        # ⚠️ 这里的 `k` 走的是**订阅自己那套**（sub_kw），不是上面的关键词框 ——
        #    "会存下"这四个字必须说真话，否则用户照着这句核对，看到的正好
        #    是另一套条件（"界面回执说 A、库里是 B"这个仓库栽过）。
        k <- dsapp_lit_keywords(input$sub_kw)
        nr <- suppressWarnings(as.integer(input$sub_n_read)[1])
        ns_ <- suppressWarnings(as.integer(input$sub_n_skim)[1])
        yr <- suppressWarnings(as.numeric(c(input$sub_yfrom, input$sub_yto)))
      } else {
        k <- kws()
        nr <- suppressWarnings(as.integer(input$n_read)[1])
        ns_ <- suppressWarnings(as.integer(input$n_skim)[1])
        yr <- suppressWarnings(as.numeric(c(input$year_from, input$year_to)))
      }
      if (!length(k)) {
        return(p(class = "text-muted small mb-2",
                 icon("circle-info"),
                 if (own) " 还没填关键词，先去上面那个框里填一个。"
                 else " 上面还没填关键词，先去填一个。"))
      }
      ys <- if (all(is.finite(yr))) sprintf("，%d–%d 年", min(yr), max(yr)) else ""
      sk <- chosen_skill_names()
      p(class = "text-muted small mb-2",
        icon("circle-info"), " 会存下：",
        tags$b(paste(k, collapse = "、")),
        sprintf("；精读 %s 篇、略读 %s 篇%s",
                if (is.na(nr)) 3L else nr, if (is.na(ns_)) 5L else ns_, ys),
        if (length(sk)) paste0("；技能 ", paste(sk, collapse = "、")) else "")
    })

    # 三个动作共用一个"取选中那条"的口子。
    # ⚠️ 每个动作都必须 `WHERE user_id = ?` —— 那是 dsapp_litsub_* 内部保证的，
    #    这里只负责把 id 和 uid 一起给它。界面上没有任何东西阻止一个人
    #    改别人的订阅，条件漏了就是"别人的关键词、别人的邮箱"。
    act_on_sub <- function(fn) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        sub_note("请先登录。"); return(invisible(FALSE))
      }
      # ⚠️ 读的是 input 的**当前值**，不另存一份 picked_sub。
      #    另存一份的话就有两个真相，"表格重画了、我记的那个 id 已经没了"
      #    这种时候两边会对不上，而错的那一边（缓存的 id）照样能发命令。
      id <- suppressWarnings(as.integer(input$sub_pick %||% NA)[1])
      if (is.na(id)) { sub_note("先在上面选中一条订阅。"); return(invisible(FALSE)) }
      r <- tryCatch(fn(id, as.integer(uid)), error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      sub_note(if (isTRUE(r$ok)) "" else (r$msg %||% "没成功"))
      # ⚠️ 输了也要刷。不刷的话"其实是权限不够 / 库里没这行"和"按钮没反应"
      #    在屏幕上长得一模一样 —— 表格会一直显示那条其实已经变了的旧状态。
      if (isTRUE(r$ok)) subs_rev(subs_rev() + 1L)
      invisible(isTRUE(r$ok))
    }
    observeEvent(input$sub_on,
                 act_on_sub(function(id, uid)
                   dsapp_litsub_toggle(id, uid, TRUE, cfg = cfg(),
                                       con = dsapp_db(cfg()))),
                 ignoreInit = TRUE)
    observeEvent(input$sub_off,
                 act_on_sub(function(id, uid)
                   dsapp_litsub_toggle(id, uid, FALSE, cfg = cfg(),
                                       con = dsapp_db(cfg()))),
                 ignoreInit = TRUE)
    observeEvent(input$sub_del,
                 act_on_sub(function(id, uid)
                   dsapp_litsub_delete(id, uid, cfg = cfg(),
                                       con = dsapp_db(cfg()))),
                 ignoreInit = TRUE)

    observeEvent(input$sub_add, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        sub_note("请先登录。"); return()
      }
      # ★ V15.5 item 4：条件按「这条订阅用什么条件」那一栏取。
      #    ⚠️ 两条路各取各的，**不要**在同一段里混着读 input —— 混着读
      #    最容易出的错是"关键词取了 A 的、篇数取了 B 的"，而存进去之后
      #    在表格里只显示关键词，这种错要等下次跑到点才暴露。
      own <- identical(sub_src_now(), "own")
      if (own) {
        k <- dsapp_lit_keywords(input$sub_kw)
        if (!length(k)) { sub_note("「单独填一套」里还没填关键词。"); return() }
        nr <- suppressWarnings(as.integer(input$sub_n_read)[1])
        ns_ <- suppressWarnings(as.integer(input$sub_n_skim)[1])
        yr <- suppressWarnings(as.numeric(c(input$sub_yfrom, input$sub_yto)))
      } else {
        k <- kws()
        if (!length(k)) { sub_note("上面还没填关键词。"); return() }
        nr <- suppressWarnings(as.integer(input$n_read)[1])
        ns_ <- suppressWarnings(as.integer(input$n_skim)[1])
        yr <- suppressWarnings(as.numeric(c(input$year_from, input$year_to)))
      }
      yr <- if (all(is.finite(yr))) sort(yr) else c(NA_real_, NA_real_)
      ids <- suppressWarnings(as.integer(input$skills))
      ids <- ids[!is.na(ids)]
      # 技能 id 是前端送上来的，**不能信**：必须是这个账号看得见的内置技能。
      ch <- choices()
      ids <- if (!is.null(ch) && length(ids))
        ids[ids %in% as.integer(ch$id)] else integer(0)

      r <- dsapp_litsub_add(
        as.integer(uid), keywords = paste(k, collapse = "、"),
        n_read = if (is.na(nr)) 3L else nr,
        n_skim = if (is.na(ns_)) 5L else ns_,
        year_from = if (is.na(yr[1])) NULL else as.integer(yr[1]),
        year_to   = if (is.na(yr[2])) NULL else as.integer(yr[2]),
        extra = paste(notes_now(), collapse = "\n"),
        skills = ids,
        freq = input$sub_freq %||% "weekly",
        weekday = input$sub_wd %||% 1L,
        day_of_month = input$sub_dom %||% 1L,
        hour = input$sub_hour %||% 8L,
        minute = input$sub_min %||% 0L,
        enabled = isTRUE(input$sub_enabled),
        title = input$sub_title %||% "",
        cfg = cfg(), con = dsapp_db(cfg()))

      if (!isTRUE(r$ok)) { sub_note(r$msg); return() }
      sub_note("")
      # ⚠️ 建完必须把列表刷出来。不刷的话用户看到的还是旧表格 ——
      #    而"库里有了、页面上没有"和"根本没建成"在屏幕上长得一模一样
      #    （memory：限流/必填的拒绝长得像界面坏了）。
      subs_rev(subs_rev() + 1L)
      showNotification(
        sprintf("订阅建好了%s",
                if (isTRUE(input$sub_enabled)) "，到点会自动跑" else "（现在是关着的）"),
        type = "message", duration = 5)
    }, ignoreInit = TRUE)

    output$sub_msg <- renderUI({
      m <- sub_note()
      if (!nzchar(m)) return(NULL)
      tags$span(class = "small text-danger", icon("triangle-exclamation"), " ", m)
    })
  })
}
