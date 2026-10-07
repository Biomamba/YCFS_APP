# =============================================================================
# 系统提示词编辑器（★ V15.4 item 8）
# =============================================================================
# 用户原话：「现在系统默认的提示词是什么？在"后台管理"界面中显示，并支持
#           超级管理员自定义修改」。
#
# 两件事，这一页各占一半：
#   1. **显示**「现在系统默认的提示词是什么」—— 左栏列 12 节，右栏是这一节
#      现在**生效**的正文（改过就是改过的，没改过就是内置默认）；最下面是
#      **拼装后的全文**，也就是模型真正收到的那一整段。
#   2. **改** —— 「保存」写一行覆盖，「恢复默认」删掉那一行。
#
# ⚠️ 只有 10 节能改，另外 2 节（代码铁律的"手动全篇"/"自动执行全篇"）是
#    HEAD + TAIL 拼出来的，界面上列出来但只读。理由写在 R/prompts.R 的
#    DSAPP_PROMPT_PARTS 上面那段：两边都能改的话谁赢就看读的顺序，而界面上
#    会同时显示"已修改"和旧内容。
#
# ★ V16.5 item 3：「新增分类」（用户原话「系统提示词需要能新增分类」）。
#    上面那 12 节是**代码里写死的**，管理员只能改不能加。现在左栏底下多一颗
#    「新增分类」：起个名字 + 写正文 → 存进 prompt_custom 表 → 出现在左栏
#    「自定义 · xxx」那几行里，和内置各节一样**每个请求都注入**。
#    ⚠️ 三个和内置节**不一样**的地方，界面上的措辞必须让管理员看得出来：
#      · 它没有"内置默认"可回退 —— 所以它那颗按钮是「删除这一节」不是
#        「恢复默认」（点下去就是真的没了，弹框里写明了）；
#      · 正文留空 = 这一节不注入（和内置节覆盖成空串同义）；
#      · 它不跟着程序升级走 —— 程序改了默认提示词，它一个字都不变。
#
# ⚠️⚠️ **写操作的闸在服务端，不在 UI。** 这个页签只对平台管理员渲染
#    （R/mod_backstage.R 里的 `if (platform)`），但那只挡"看不见"：一个
#    被降级的人在他开着的标签页里，页签还在，按钮还能点。所以每一条写库的
#    路第一句都是 guard()，而且它现读库（`me()`），**不用 `state$user`** ——
#    快照身份正是"降级之后还能继续改"的那条路。同一个形状见 R/mod_htadmin.R
#    的 guard()/audit()（那里顶部那段注释就是为这件事写的）。
#
# ⚠️ 改的是**每一个请求**发给模型的东西，等于全平台的行为开关。所以：
#   · 每一次写都记一笔审计（谁、哪一节、多长）；
#   · 审计里**不记正文**（不是怕泄密，是它会很长，把操作日志冲得没法读）；
#   · 「保存」之后当场刷本进程的缓存（`dsapp_prompt_put` 内部做了），所以
#     下一个请求就生效，不需要重启 worker。
# =============================================================================

#' 系统提示词编辑器（UI）
#'
#' @param ns 命名空间函数（`NS("prompt")`）。这里收的是**函数**不是 id 字符串：
#'   调用方是 R/mod_backstage.R，它在自己的 UI 树里没有 `session`，拿不到
#'   `session$ns`，只能自己 `NS("prompt")`。
mod_prompt_ui <- function(ns) {
  card(
    card_header(
      class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
      span(icon("wand-magic-sparkles"), " 系统提示词"),
      uiOutput(ns("pp_badge"), inline = TRUE)
    ),
    card_body(
      helpText(class = "small text-muted mb-2",
        "这里是**每一条消息**都会先发给模型的那段说明。左栏选一节，右栏改它。",
        tags$br(),
        "没改过的节跟着程序内置的默认走（以后升级会自动更新）；改过的节",
        tags$b("就固定成你写的那份"), "，不再跟着走 —— 想让它重新跟着走，点「恢复默认」。",
        tags$br(),
        "左栏底下那颗「新增分类」是自己**加**一节（内置那 12 节只能改不能加）。"),
      layout_columns(
        col_widths = c(4, 8),
        div(
          uiOutput(ns("pp_picker")),
          uiOutput(ns("pp_status")),
          div(class = "mt-2",
            actionButton(ns("pp_add"), tagList(icon("plus"), " 新增分类"),
                         class = "btn-outline-primary btn-sm w-100")
          )
        ),
        uiOutput(ns("pp_editor"))
      ),
      uiOutput(ns("pp_msg")),
      tags$hr(),
      # ---- 拼装后的全文（item 8 的"现在系统默认的提示词是什么"）----------
      div(class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
        tags$h6(class = "fw-bold mb-0", icon("file-lines"), " 拼装后的全文"),
        radioButtons(ns("pp_scene"), NULL, inline = TRUE,
                     choices = c("对话" = "chat", "自动执行" = "agent"),
                     selected = "chat")
      ),
      helpText(class = "small text-muted mb-1",
        "这就是模型实际收到的那一整段（发出去时是纯文本，这里为了好读做了折行）。",
        "里面有几节是**每次请求现生成**的，不在这 12 节里、也不可改：",
        "「你实际是什么模型」（按当前选的厂商和模型名）、",
        "「已启用技能」（按这个对话挂了哪些技能）、",
        "「工作环境说明」（按这个对话的工作区、装了哪些包）。"),
      uiOutput(ns("pp_full"))
    )
  )
}

#' 系统提示词编辑器（server）
#'
#' @param id 命名空间，"prompt"（在 app.R 里和另外两组管理员 server 平级注册）。
#' @param state 应用级 state（只读 `state$user_id`；**不要**用它判权限）。
mod_prompt_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns  <- session$ns
    cfg <- dsapp_config()

    # 每次写操作后 +1。全页的每一个 renderUI 都读它 —— 覆盖层是**非响应式**的
    # 进程内缓存（R/prompts.R 的 .dsapp_prompt_env），不读这个的话"保存成功、
    # 界面纹丝不动"，用户会以为没保存上，然后再点一次。
    rev <- reactiveVal(0L)
    msg <- reactiveVal(NULL)

    # 当前操作者的**实时**身份行（理由见文件头那段 ⚠️⚠️）。
    me <- reactive({
      uid <- state$user_id
      if (is.null(uid) || length(uid) != 1 || is.na(uid)) return(NULL)
      tryCatch(dsapp_user_by_id(uid, con = dsapp_db(cfg)), error = function(e) NULL)
    })
    is_platform <- reactive({ dsapp_user_is_platform_admin(me()) })

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

    # 库里现在有哪些覆盖（key -> 那一行）。写在 renderUI 里读，不是顶层读 ——
    # 顶层读等于让整页在启动时查一次库，而且 rev() 变化时不会重读。
    ov_rows <- reactive({
      rev()
      dsapp_prompt_overrides(dsapp_db(cfg))
    })

    # ★ V16.5 item 3：超管自己加的那几节（prompt_custom 表）。
    #   ⚠️ 每次都**现读库**（`dsapp_prompt_custom(con)` 里带 con 就是现读）：
    #      这一页是管理员页，一次主键全表扫描便宜到不值得省；而缓存住的话，
    #      "在另一个标签页里删了一节"就看不见了。
    cu_rows <- reactive({
      rev()
      tryCatch(dsapp_prompt_custom(dsapp_db(cfg)),
               error = function(e) dsapp_prompt_custom_empty())
    })

    # 这一节是不是"拼出来的"（只读）
    is_derived <- function(key) {
      for (p in DSAPP_PROMPT_PARTS) {
        if (identical(p$key, key)) return(isTRUE(p$derived))
      }
      FALSE
    }

    # 这一节是不是**新增**出来的（和内置那 12 节的区别见文件头 ★ V16.5）
    is_custom <- function(key) key %in% cu_rows()$key

    # ---- ★ V16.5：刚加/刚删完，右栏该跟着跳到哪一节 -------------------------
    #
    # ⚠️ 为什么不靠 `updateSelectInput()`：这是"服务端的 input 落下一拍"那个
    #    老坑的又一处。新增之后我们调 updateSelectInput(selected = 新 key)，
    #    而同一拍里 rev() 让 pp_picker 整个**重画**（重画时 selected 读的是
    #    还没更新的 input$pp_part = 旧 key）—— 两条消息谁先到不确定，晚到的
    #    那条赢。压错了的表现是"新增完，右栏还停在原来那一节"，用户以为没加上。
    #    所以跳转这件事**只走一个入口**：这个 reactiveVal。picker 的 selected
    #    和右栏都读它，重画时自然就是对的，没有两条路抢。
    focus <- reactiveVal(NULL)

    # 当前选中的节。⚠️ 校验放在这里而不是"相信 input"：input 是客户端来的，
    #    一个不认识的 key 走到 dsapp_prompt_put() 会被它挡回来（返回 FALSE），
    #    但界面上会先显示"已保存"再显示"没保存"，两句话自相矛盾。
    #    ★ V16.5：认识的 key 现在有**两类** —— 内置那 12 节的常量名，以及
    #    prompt_custom 里那几行。只认前一类的话，点开自己加的那一节会被
    #    "回落到第一节"静默吃掉（右栏显示的是「身份」，保存写的也是身份）。
    cur_key <- reactive({
      k <- as.character(input$pp_part %||% "")[1] %||% ""
      f <- focus()
      if (!is.null(f) && f %in% c(names(DSAPP_PROMPT_DEFAULTS), cu_rows()$key)) {
        k <- f
      }
      if (!k %in% c(names(DSAPP_PROMPT_DEFAULTS), cu_rows()$key)) {
        k <- DSAPP_PROMPT_PARTS[[1]]$key
      }
      k
    })

    # 用户自己在左栏点了别的行 → 放弃 focus（否则会一直把它按在刚加的那一节）
    observeEvent(input$pp_part, {
      f <- focus()
      if (!is.null(f) && !identical(as.character(input$pp_part)[1], f)) focus(NULL)
    }, ignoreNULL = TRUE)

    # ---- 左栏：12 节 + 自己加的那几节 ---------------------------------------
    output$pp_picker <- renderUI({
      # ⚠️⚠️ 这个 choices 的**方向**（谁当名字、谁当值）是这一版最容易写反、
      #    写反了又最难看出来的一处，所以抽去了 R/prompts.R 的
      #    dsapp_prompt_choices()，那里有完整的来龙去脉。**别在这儿就地拼**。
      #    ★ V16.5：自定义那几节同理，走 dsapp_prompt_custom_choices()。
      ch <- c(dsapp_prompt_choices(ov_rows()),
              dsapp_prompt_custom_choices(cu_rows()))
      # selectize = FALSE + size = 全部：渲染成原生的列表框，一眼看全，
      # 不用点开下拉。⚠️ selectize 那个控件打开时才把选项铺进 DOM，做浏览器
      # 探针时得先点开才读得到 —— 这里索性不用它。
      selectInput(ns("pp_part"), NULL, choices = ch,
                  selected = cur_key(), selectize = FALSE,
                  size = length(ch), width = "100%")
    })

    # ---- 左栏：这一节的状态 ------------------------------------------------
    output$pp_status <- renderUI({
      k <- cur_key()
      rows <- ov_rows()
      i <- match(k, rows$key)
      # ★ V16.5 item 3：自己加的那几节 —— 状态和内置节完全不同（没有"内置
      #   默认"这回事），所以单独一段，措辞也点名"不跟程序升级走"。
      if (is_custom(k)) {
        cu <- cu_rows()
        j <- match(k, cu$key)
        who <- as.character(cu$nickname[j] %||% "")[1] %||% ""
        if (is.na(who) || !nzchar(who)) who <- as.character(cu$email[j] %||% "")[1] %||% ""
        if (is.na(who) || !nzchar(who)) who <- "（已删除的账号）"
        nch <- nchar(as.character(cu$body[j] %||% "")[1] %||% "")
        return(div(class = "small mt-2",
          span(class = "text-primary-emphasis",
               icon("plus-circle"), " 自定义分类"),
          tags$br(),
          span(class = "text-muted",
               sprintf("%s · %s", as.character(cu$updated_at[j] %||% "")[1] %||% "", who)),
          tags$br(),
          span(class = "text-muted",
               if (nch > 0) sprintf("正文 %d 字 · 每个请求都注入", nch)
               else "正文是空的 —— 这一节现在**不注入**"),
          tags$br(),
          span(class = "text-muted", "它不跟着程序升级走。")
        ))
      }
      if (is_derived(k)) {
        return(div(class = "small text-muted mt-2",
          icon("circle-info"), " 这一节是**拼出来的**，改它上面的两节就等于改它。"))
      }
      if (is.na(i)) {
        return(div(class = "small text-muted mt-2",
          icon("circle-check"), " 内置默认（没被改过），跟着程序走。"))
      }
      who <- as.character(rows$nickname[i] %||% "")[1] %||% ""
      if (is.na(who) || !nzchar(who)) who <- as.character(rows$email[i] %||% "")[1] %||% ""
      if (is.na(who) || !nzchar(who)) who <- "（已删除的账号）"
      div(class = "small mt-2",
        span(class = "text-warning-emphasis",
             icon("pen-to-square"), " 已自定义"),
        tags$br(),
        span(class = "text-muted",
             sprintf("%s · %s", as.character(rows$updated_at[i] %||% "")[1] %||% "", who))
      )
    })

    # ---- 右栏：编辑器 ------------------------------------------------------
    output$pp_editor <- renderUI({
      k <- cur_key()
      part <- NULL
      for (p in DSAPP_PROMPT_PARTS) if (identical(p$key, k)) part <- p
      body <- dsapp_prompt_get(k) %||% ""

      # ★ V16.5 item 3：自己加的那一节 —— 多一个"分类名"输入框（改名不换
      #   key、不丢正文），按钮换成「删除这一节」（它没有内置默认可回退，
      #   所以那颗「恢复默认」在这儿是句假话）。
      if (is_custom(k)) {
        cu <- cu_rows()
        j <- match(k, cu$key)
        return(tagList(
          tags$h6(class = "fw-bold", sprintf("自定义分类 · %s",
                                             as.character(cu$label[j])[1])),
          textInput(ns("pp_label"), "分类名", width = "100%",
                    value = as.character(cu$label[j])[1]),
          textAreaInput(ns("pp_body"), NULL, rows = 15, width = "100%",
                        value = as.character(cu$body[j])[1] %||% ""),
          div(class = "d-flex gap-2 flex-wrap",
            actionButton(ns("pp_save"), tagList(icon("floppy-disk"), " 保存"),
                         class = "btn-primary btn-sm"),
            actionButton(ns("pp_del"), tagList(icon("trash-can"), " 删除这一节"),
                         class = "btn-outline-danger btn-sm")
          ),
          helpText(class = "small text-muted mt-2 mb-0",
            "保存后", tags$b("立刻生效"), "（下一个请求就用新的），不需要重启。",
            tags$br(),
            "正文留空 = 这一节不注入（分类还在左栏，随时可以再填）。",
            tags$br(),
            "⚠️ 这一节是你自己加的，", tags$b("不跟着程序升级走"),
            "；「删除」是彻底删掉，没有默认可以回退。")
        ))
      }

      if (is_derived(k)) {
        # 只读：显示现在生效的拼装结果 + 它是从哪两节来的
        return(tagList(
          tags$h6(class = "fw-bold", part$label),
          helpText(class = "small text-muted",
            "由 ", paste(part$from, collapse = " + "), " 拼成，不能单独改。"),
          tags$pre(class = "border rounded p-2 small",
                   style = "max-height:420px; overflow:auto; white-space:pre-wrap;",
                   body)
        ))
      }

      tagList(
        tags$h6(class = "fw-bold", part$label),
        if (nzchar(part$hint %||% "")) helpText(class = "small text-muted", part$hint),
        textAreaInput(ns("pp_body"), NULL, value = body, rows = 16, width = "100%"),
        div(class = "d-flex gap-2 flex-wrap",
          actionButton(ns("pp_save"), tagList(icon("floppy-disk"), " 保存"),
                       class = "btn-primary btn-sm"),
          actionButton(ns("pp_reset"), tagList(icon("rotate-left"), " 恢复默认"),
                       class = "btn-outline-secondary btn-sm"),
          actionButton(ns("pp_show_default"), tagList(icon("eye"), " 看一眼内置默认"),
                       class = "btn-outline-secondary btn-sm")
        ),
        helpText(class = "small text-muted mt-2 mb-0",
          "保存后", tags$b("立刻生效"), "（下一个请求就用新的），不需要重启。",
          "清空内容再保存 = 这一节不注入。")
      )
    })

    # ---- 反馈条 ------------------------------------------------------------
    output$pp_msg <- renderUI({ msg() })

    # ---- 卡头徽标：改过几节 -------------------------------------------------
    output$pp_badge <- renderUI({
      n <- nrow(ov_rows())
      m <- nrow(cu_rows())
      if (n <= 0 && m <= 0) {
        return(span(class = "badge text-bg-secondary", "全部为内置默认"))
      }
      # ★ V16.5 item 3：两个数分开报 —— 合成一个"改了 N 节"的话，"我明明
      #   只加了一节"和"我改了内置的一节"看起来是同一件事。
      span(class = "badge text-bg-warning",
           paste(c(if (n > 0) sprintf("已改内置 %d 节", n),
                   if (m > 0) sprintf("自定义分类 %d 个", m)),
                 collapse = " · "))
    })

    # ---- 拼装后的全文 ------------------------------------------------------
    output$pp_full <- renderUI({
      rev()
      scene <- as.character(input$pp_scene %||% "chat")[1] %||% "chat"
      if (!scene %in% c("chat", "agent")) scene <- "chat"
      # ⚠️ 这里**故意**不传 session_id / skills：这一页是"看默认长什么样"，
      #    带进某个对话的工作区清单和技能的话，同一个页面在两个对话里看到的
      #    全文不一样 —— 而管理员要回答的是"系统默认的提示词是什么"。
      #    也因此下面那行说明必须写清楚哪几节是现生成的。
      txt <- tryCatch(
        build_system_prompt(scene = scene, cfg = cfg),
        error = function(e) paste("（拼装失败：", conditionMessage(e), "）"))
      tags$pre(class = "border rounded p-2 small bg-body-tertiary",
               style = "max-height:520px; overflow:auto; white-space:pre-wrap;",
               txt)
    })

    # ---- 写操作 ------------------------------------------------------------
    observeEvent(input$pp_save, {
      if (!guard()) return(invisible(NULL))
      k <- cur_key()
      if (is_derived(k)) {
        return(note("这一节是拼出来的，不能单独保存。改它上面的两节。", "warning"))
      }
      body <- as.character(input$pp_body %||% "")[1] %||% ""
      # ★ V16.5 item 3：自己加的那一节走另一条写库的路（多一个分类名）。
      if (is_custom(k)) {
        lab <- trimws(as.character(input$pp_label %||% "")[1] %||% "")
        if (!nzchar(lab)) {
          return(note("分类名不能是空的（正文可以先留空）。这一节没保存。",
                      "warning"))
        }
        ok <- tryCatch(dsapp_prompt_custom_put(k, lab, body,
                                               user_id = state$user_id,
                                               con = dsapp_db(cfg)),
                       error = function(e) {
                         message("[dsapp] 保存自定义分类失败：", conditionMessage(e))
                         FALSE
                       })
        audit("prompt_custom_put", target = k,
              detail = sprintf("%s · %d 字符", lab, nchar(body)), ok = isTRUE(ok))
        if (!isTRUE(ok)) {
          return(note("没保存上：这一节可能已经在别处被删了，或者库写不进去。操作已经记进日志了。", "danger"))
        }
        rev(rev() + 1L)
        return(note(sprintf("已保存「%s」。下一个请求就用新的。", lab), "success"))
      }
      ok <- tryCatch(dsapp_prompt_put(k, body, user_id = state$user_id,
                                      con = dsapp_db(cfg)),
                     error = function(e) {
                       message("[dsapp] 保存提示词覆盖失败：", conditionMessage(e))
                       FALSE
                     })
      audit("prompt_put", target = k,
            detail = sprintf("%d 字符", nchar(body)), ok = isTRUE(ok))
      if (!isTRUE(ok)) {
        return(note("没保存上：段名不认识或库写不进去。操作已经记进日志了。", "danger"))
      }
      rev(rev() + 1L)
      note(sprintf("已保存「%s」。下一个请求就用新的。", k), "success")
    })

    observeEvent(input$pp_show_default, {
      k <- cur_key()
      # ⚠️ 自己加的那一节没有"内置默认"这回事（按钮也不给它渲染）——真点到
      #    （比如右栏刚换过去、按钮还是上一拍那个）就直说，别弹一个空框。
      if (is_custom(k)) {
        return(note("这一节是你自己加的，没有「内置默认」可看。", "secondary"))
      }
      d <- DSAPP_PROMPT_DEFAULTS[[k]] %||% ""
      showModal(modalDialog(
        title = sprintf("「%s」的内置默认", k),
        size = "l", easyClose = TRUE,
        helpText(class = "small text-muted",
          "这是程序里写死的默认。你如果没改过这一节，模型收到的就是它。"),
        tags$pre(class = "border rounded p-2 small",
                 style = "max-height:60vh; overflow:auto; white-space:pre-wrap;",
                 d),
        footer = modalButton("关闭")
      ))
    })

    # ---- ★ V16.5 item 3：新增一个分类 --------------------------------------
    #
    # 弹框里一起要**名字和正文**：只给名字的话，管理员得先加、再在右栏写、
    # 再保存（三步），中间任何一步以为"加完了"都会留下一节空分类。
    # 正文留空是**允许**的（他就是想先占个位），界面上说清楚"留空 = 不注入"。
    observeEvent(input$pp_add, {
      if (!guard()) return(invisible(NULL))
      showModal(modalDialog(
        title = "新增分类",
        helpText(class = "small text-muted",
          "加出来的这一节会", tags$b("跟着每一个请求"), "发给模型。",
          "名字只是给你自己看的（左栏那一行），正文才是发给模型的东西。"),
        textInput(ns("pp_new_label"), "分类名", width = "100%",
                  placeholder = "例：科研绘图规范"),
        textAreaInput(ns("pp_new_body"), "正文（可以先留空，之后在右栏写）",
                      rows = 8, width = "100%",
                      placeholder = "写在这一节里的话，会原样拼进系统提示词。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("pp_confirm_add"), "新增", class = "btn-primary")
        )
      ))
    })

    observeEvent(input$pp_confirm_add, {
      if (!guard()) return(invisible(NULL))
      lab  <- trimws(as.character(input$pp_new_label %||% "")[1] %||% "")
      body <- as.character(input$pp_new_body %||% "")[1] %||% ""
      if (!nzchar(lab)) {
        # ⚠️ 报错要**回到弹框里**报：note() 画在弹框**后面**，用户根本看不见，
        #    他会以为按钮坏了然后一直点。所以重新弹一次，并把已经敲进去的
        #    正文原样带回来（丢了的话他得再写一遍）。
        return(showModal(modalDialog(
          title = "新增分类",
          div(class = "alert alert-warning py-2 px-3 small mb-2",
              "分类名不能是空的 —— 左栏那一行总得有个字。"),
          textInput(ns("pp_new_label"), "分类名", width = "100%",
                    value = lab, placeholder = "例：科研绘图规范"),
          textAreaInput(ns("pp_new_body"), "正文（可以先留空，之后在右栏写）",
                        rows = 8, width = "100%", value = body),
          footer = tagList(
            modalButton("取消"),
            actionButton(ns("pp_confirm_add"), "新增", class = "btn-primary")
          )
        )))
      }
      key <- tryCatch(
        dsapp_prompt_custom_add(lab, body, user_id = state$user_id,
                                con = dsapp_db(cfg)),
        error = function(e) {
          message("[dsapp] 新增自定义分类失败：", conditionMessage(e))
          ""
        })
      removeModal()
      audit("prompt_custom_add", target = key,
            detail = sprintf("%s · %d 字符", lab, nchar(body)), ok = nzchar(key))
      if (!nzchar(key)) {
        return(note("没加上：库写不进去。操作已经记进日志了。", "danger"))
      }
      rev(rev() + 1L)
      # 跳过去（走 focus 这一个入口，理由见上面 focus 那段 ⚠️）
      focus(key)
      note(sprintf("已新增「%s」%s。", lab,
                   if (nzchar(body)) "，下一个请求就用新的" else
                     "（正文还空着，现在不注入）"), "success")
    })

    # ★ V16.5 item 3：删掉自己加的那一节。
    # ⚠️ 和「恢复默认」分开两颗按钮：那颗的语义是"回到内置默认"，而这一节
    #    **没有**默认可回 —— 点下去字面意义上就没了。措辞混用的话，管理员
    #    会以为删掉还能恢复，等他发现不能的时候东西已经没了。
    observeEvent(input$pp_del, {
      if (!guard()) return(invisible(NULL))
      k <- cur_key()
      if (!is_custom(k)) {
        return(note("这一节是内置的，只能「恢复默认」。", "warning"))
      }
      cu <- cu_rows()
      j <- match(k, cu$key)
      lab <- as.character(cu$label[j])[1] %||% k
      showModal(modalDialog(
        title = sprintf("删除「%s」？", lab),
        "这一节是你自己加的，", tags$b("删掉就没有了 —— 它没有内置默认可以回退。"),
        tags$br(), "已经在模型那边生效的内容也不会因此改变（影响的是**以后**的请求）。",
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("pp_confirm_del"), "删除", class = "btn-danger")
        )
      ))
    })

    observeEvent(input$pp_confirm_del, {
      if (!guard()) return(invisible(NULL))
      k <- cur_key()
      # ⚠️ 兜一层：弹框弹着的时候左栏可能已经换了（他在另一个标签页删了、
      #    或者手快点了别的行），那时 k 已经不是要删的那一节了。
      if (!is_custom(k)) {
        removeModal()
        return(note("这一节已经不在自定义分类里了，没有删。", "warning"))
      }
      ok <- tryCatch(dsapp_prompt_custom_del(k, con = dsapp_db(cfg)),
                     error = function(e) {
                       message("[dsapp] 删除自定义分类失败：", conditionMessage(e))
                       FALSE
                     })
      removeModal()
      audit("prompt_custom_del", target = k, ok = isTRUE(ok))
      if (!isTRUE(ok)) {
        return(note("没删掉：这一节可能已经在别处被删了，或者库写不进去。操作已经记进日志了。", "danger"))
      }
      rev(rev() + 1L)
      # 删掉的正是当前这一节：跳回第一节（picker 重画时按 focus 选，见上面）
      focus(DSAPP_PROMPT_PARTS[[1]]$key)
      note("已删除。下一个请求里就没有这一节了。", "success")
    })

    # 「恢复默认」= 删掉那一行。删之前先弹一次确认：它不可撤销，而且症状是
    # "提示词悄悄变回内置的那份"，不确认的话管理员多半不敢点。
    observeEvent(input$pp_reset, {
      if (!guard()) return(invisible(NULL))
      k <- cur_key()
      if (is_derived(k)) {
        return(note("这一节是拼出来的，没有单独的一行可以恢复。", "warning"))
      }
      if (is_custom(k)) {
        return(note("这一节是自定义分类，没有默认可恢复 —— 用「删除这一节」。",
                    "warning"))
      }
      if (!dsapp_prompt_is_overridden(k)) {
        return(note(sprintf("「%s」本来就是内置默认，不用恢复。", k), "secondary"))
      }
      showModal(modalDialog(
        title = "恢复内置默认？",
        "这一节现在生效的是**别人改过的那一份**（也可能是你自己改的）。",
        tags$br(),
        "恢复之后，它会重新跟着程序内置的默认走 —— 也就是以后升级会跟着更新。",
        tags$br(), tags$b("改过的那份会被删掉，不能撤销。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("pp_confirm_reset"), "恢复默认", class = "btn-danger")
        )
      ))
    })

    observeEvent(input$pp_confirm_reset, {
      if (!guard()) return(invisible(NULL))
      k <- cur_key()
      ok <- tryCatch(dsapp_prompt_clear(k, con = dsapp_db(cfg)),
                     error = function(e) {
                       message("[dsapp] 恢复提示词默认失败：", conditionMessage(e))
                       FALSE
                     })
      removeModal()
      audit("prompt_clear", target = k, ok = isTRUE(ok))
      if (!isTRUE(ok)) {
        return(note("没恢复成：库写不进去。操作已经记进日志了。", "danger"))
      }
      rev(rev() + 1L)
      note(sprintf("「%s」已恢复内置默认。", k), "success")
    })
  })
}
