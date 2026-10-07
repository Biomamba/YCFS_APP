# =============================================================================
# 入口页：注册 / 登录 / 恢复码 / 强制改密 / 启动过渡
# =============================================================================
# V5 引入。用户第一次进来先填昵称、邮箱、手机号、研究方向，之后这个浏览器
# 就记住了他，再回来直接进主界面，并且能看到自己此前的对话和任务。
#
# ★ V13.1 item 7：密码从"可选"改成"必填"。
#
#   原来这里的理由是"给每个访客加一道强制密码挡不住任何人（想看的随便填个
#   邮箱就能注册），只会让人记不住密码然后反复找你重置"。那个理由在当时
#   成立，因为它默认了**账号里没有值得保护的东西**。
#
#   现在不成立了：库里存着每个账号的 API Key（真金白银买的额度）、
#   每个对话的工作区和产物、以及跑到一半的任务。一个"知道邮箱就能进"的
#   账号，等于把这些东西挂在门口。
#
#   ⚠️ 用户的原话是「取消免密登录这种方式」，选项是「硬切，无密码账号一律
#      拒绝」——所以这不是"默认关掉"，是**整条路删掉**：注册必须设密码
#      （dsapp_user_validate），pass_hash 为空的老账号一律拒绝登录
#      （dsapp_user_auth），出口只有管理员重置或用恢复码。
#
#   界面上那句"不设密码的账号别人填你邮箱就能进"也一并改掉了 —— 那句话
#   描述的是一个已经不存在的选项，留着比不说更糟。
#
# 身份靠两样东西：
#   1. 浏览器 cookie（一年），由 www/app.js 读写。这是主路径，日常无感。
#   2. 恢复码。cookie 丢了（换电脑、清缓存、无痕窗口）时用它认领。
#      注册后**立刻**显示一次，界面上提供复制按钮。
#
# ⚠️ cookie 这条路**不能想当然**：2026-09-13 线上出过"登录成功（audit 里
#    明明记着 ok=1）却弹回登录页"。所以现在写完 cookie 要**读回来确认**，
#    浏览器回了执服务端才 reload 页面（见 app.R 的 awaiting_ack 和 www/app.js
#    的 dsapp:setToken）。禁用了 cookie 的浏览器现在会**明说**，而不是把
#    用户无声地弹回登录页。
#
# 版式参照 ChatGPT：整页就是背景，中间一列窄栏，输入框和按钮是唯一有边界的
# 东西。样式全在 www/app.css 的 .dsapp-auth 那一族里，这里只管结构。
# =============================================================================

#' 底部那段"开始之前"的说明
#'
#' 原来是一个黄底告示框，压在表单上面，很吵。改成默认折起的 details：
#' 该说的话一个字没少（用户有权知道共享区是公开的、没密码的账号不设防），
#' 但不再挡着"我要登录"这条主路。
dsapp_auth_note <- function() {
  tags$details(class = "dsapp-auth-note",
    tags$summary("开始之前，有两件事你需要知道"),
    tags$ul(
      # ★ V13.1 item 8：这条原来写的是「文件管理区是全站公开的。你上传到
      #   「文件」页的数据，其他登录用户也能看到、也能在代码里引用。」
      #   用户的原话就是「文件管理区不是全站公开的，这个声明要去掉」——
      #   而且他说得对：管理区从 V13 起按账号物理隔离（每个账号一个
      #   data/files/u<N>/，见 dsapp_config_user 的 files_dir），
      #   别人的文件连路径都拼不出来。留着这句话，用户会不敢传真数据。
      tags$li(tags$b("文件管理区是按账号隔离的。"),
              "你上传到「文件」页的数据只有你自己能看到，",
              "别人看不到，也不会进到别人的对话里。"),
      # ★ V13.1 item 7：这条原来写的是「不设密码的账号，别人只要填你的
      #   邮箱就能进来；设了密码就只有你能进」——那是**如实**描述当年的
      #   免密登录。免密登录现在整条删了（dsapp_user_auth 里那支已经没了），
      #   所以这句话也必须跟着改：再说"不设密码"就是在描述一个不存在的选项。
      # ★ V15.6 item 6：原文是「注册必须设密码，没有密码进不来；但服务器
      #   管理员始终能读到磁盘上的东西。」用户要求删掉后半句 —— 那是**登录
      #   页**上的须知，读者此刻还没进来，先被告知"管理员能读你的东西"没有
      #   任何可操作的含义，只是劝退。数据边界那句话**没有消失**：它留在了
      #   「设置 → 密码」那一页（R/mod_settings.R），那里才是用户真正需要
      #   判断"要不要往这儿放敏感数据"的地方，上下文也是对的。
      tags$li(tags$b("账号用来记住你的分析，不是保险柜。"),
              "注册必须设密码，没有密码进不来。"),
      # ★ V13.1 item 9：用户原话给的提示词。V6 起 API Key 就按账号存在库里
      #   （原来存的是明文，这句话当时是**假的**）。现在改成加密入库，
      #   这句话才成立 —— 见 R/crypto.R 和 R/users.R 的 dsapp_api_key_put。
      tags$li("你的 API Key、远程服务器密码", tags$b("不会明文存到服务器上"),
              "，若使用异常请在服务商处删除 API Key。",
              tags$span(class = "text-muted",
                "（API Key 存在服务器上是加密的；远程服务器密码只在",
                 "你点「运行」的那几秒里存在于内存和一个随即删掉的临时文件里。）"))
    ),
    tags$p(class = "mt-2 mb-0",
      "分析全部在服务器端完成，浏览器只负责显示。")
  )
}

#' 入口页的外壳：整页居中一列
#'
#' 五个界面（登录、注册、恢复码、强制改密、启动过渡）共用同一套排版。
#' 做成函数是为了**它们不会各自长歪** —— 原来每个界面自己写一遍卡片和
#' 标题，改一次样式要改五处，最后必然不一致。
dsapp_auth_shell <- function(title, body, sub = "", wide = FALSE,
                             logo = "dna", note = NULL) {
  div(class = "dsapp-auth",
    div(class = if (isTRUE(wide)) "dsapp-auth-col dsapp-auth-col-wide"
                else "dsapp-auth-col",
      div(class = "dsapp-auth-brand",
        # V10 item 3：这里原来写死 icon(logo)。现在优先用 data/logo/ 里的
        # 平台 logo，没有图才落回那个图标 —— 回落必须留着，五个界面
        # （登录/注册/恢复码/强制改密/须知）都走这个壳，而它们各自传的
        # logo 名不同（lock / key / file-shield…），那是"没有品牌图时
        # 用来区分场景"的，不能因为加了 logo 就把这层区分删掉。
        dsapp_logo_box("dsapp-auth-logo", logo),
        h1(class = "dsapp-auth-title", title),
        if (nzchar(sub)) p(class = "dsapp-auth-sub", sub)
      ),
      body,
      note
    ),
    # 客服微信。入口页也要有 —— 恰恰是"进不去"的人最需要它。
    #
    # ⚠️ dsapp_footer_ui 定义在 R/utils.R，**不是 app.R**。这件事看起来
    #    只是个"文件放哪儿"的偏好，其实不是：本文件是 source 进 globalenv
    #    的，而 app.R 的顶层不在 globalenv 里，**够不着**放在那儿的函数。
    #    它曾经就在 app.R，后果是登录页整页白屏。详见 utils.R 里那段注释。
    dsapp_footer_ui()
  )
}

dsapp_welcome_ui <- function(id) {
  ns <- NS(id)
  # 整页由 server 按当前视图渲染：标题要跟着视图变（"登录到…" / "创建账号"），
  # 分成几个静态面板再拿 CSS 藏来藏去的话，标题就写不活了。
  uiOutput(ns("auth_page"))
}

# =============================================================================
# 强制改密页
# =============================================================================
# 管理员重置过密码的账号，登录后进不了主界面，先看到这一页。
#
# 为什么是"一整页"而不是一个弹窗：弹窗（哪怕 easyClose = FALSE）在这个
# 应用里会把底下的东西留在页面上，用户会以为自己已经进来了、只是有个框
# 挡着 —— 而这个状态的语义恰恰是"你还没进来"。整页替换没有这个歧义，
# 也不依赖任何前端 JS。
#
# 出口有两条：
#   1. 填「当前密码（管理员给的那个）+ 新密码」——常规路径
#   2. 忘了管理员给的密码 → 用恢复码证明身份，然后直接设新密码
#      （恢复码是这个账号的主凭证，拿它再要求旧密码是自相矛盾的）
# =============================================================================

dsapp_force_pw_ui <- function(id) {
  ns <- NS(id)
  tagList(
    uiOutput(ns("force_pw_page"))
  )
}

mod_force_pw_server <- function(id, state, on_done) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()
    msg <- reactiveVal(NULL)
    use_token <- reactiveVal(FALSE)   # 折起的那条"用恢复码验证身份"

    msg_ui <- function(m) {
      if (is.null(m)) return(NULL)
      div(class = paste("dsapp-auth-msg", if (isTRUE(m$ok)) "is-ok" else "is-error"),
          m$text,
          if (nzchar(m$hint %||% "")) span(class = "dsapp-auth-hint", m$hint))
    }

    output$force_pw_page <- renderUI({
      body <- if (!isTRUE(use_token())) {
        tagList(
          passwordInput(ns("old_pw"), "当前密码",
                        placeholder = "管理员给你的那个"),
          passwordInput(ns("new_pw"), "新密码",
                        placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
          passwordInput(ns("new_pw2"), "再输一次", placeholder = "两次要一样"),
          uiOutput(ns("fp_msg")),
          actionButton(ns("do_change"), "设置新密码并进入",
                       class = "dsapp-btn-primary"),
          div(class = "dsapp-auth-alt",
            actionLink(ns("go_token"), "不知道当前密码？"))
        )
      } else {
        tagList(
          p(class = "dsapp-auth-sub mb-3",
            "恢复码是你注册时保存的那串字符。用它验证过身份之后，",
            "就可以直接设新密码。"),
          textInput(ns("rec_token"), "恢复码"),
          passwordInput(ns("new_pw"), "新密码",
                        placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
          passwordInput(ns("new_pw2"), "再输一次", placeholder = "两次要一样"),
          uiOutput(ns("fp_msg")),
          actionButton(ns("do_change_token"), "验证并设置",
                       class = "dsapp-btn-primary"),
          div(class = "dsapp-auth-alt", actionLink(ns("go_back"), "返回"))
        )
      }
      dsapp_auth_shell(
        "设置一个新密码",
        sub = "管理员重置过这个账号的密码，换成你自己的才能继续",
        logo = "lock", body = body,
        note = p(class = "dsapp-auth-note",
                 icon("circle-info"), " 换好密码之后，管理员手里的那个就失效了。"))
    })

    # 和注册/登录页同一个道理：消息单独一个 output，否则报错会重建表单，
    # 把用户刚敲的两遍新密码清空 —— 而"两次输入不一样"正是这里最常见的
    # 报错，清空之后他要从零再敲两遍。
    output$fp_msg <- renderUI(msg_ui(msg()))

    observeEvent(input$go_token, { msg(NULL); use_token(TRUE) })
    observeEvent(input$go_back,  { msg(NULL); use_token(FALSE) })

    fail <- function(text, hint = "") msg(list(ok = FALSE, text = text, hint = hint))

    # 两个按钮共用的一段。skip_old = TRUE 只从恢复码那条路进来。
    do_change <- function(new1, new2, old, skip_old) {
      uid <- state$user_id
      if (is.null(uid)) return(fail("会话已失效，请重新登录。"))
      if (!identical(new1 %||% "", new2 %||% "")) {
        return(fail("两次输入的新密码不一样。"))
      }
      r <- tryCatch(
        dsapp_user_set_password(uid, new1 %||% "", old_password = old %||% "",
                                skip_old_check = skip_old, con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(r$ok)) return(fail(r$msg))
      msg(NULL)
      on_done()
    }

    observeEvent(input$do_change, {
      do_change(input$new_pw, input$new_pw2, input$old_pw, skip_old = FALSE)
    })

    # 恢复码这条路：先用 token 验明身份，验过了才允许跳过旧密码。
    # 顺序不能反 —— 先改再验的话，任何人都能对着一个别人的会话页面
    # 点一下就把密码换掉。
    observeEvent(input$do_change_token, {
      uid <- state$user_id
      if (is.null(uid)) return(fail("会话已失效，请重新登录。"))
      u <- tryCatch(dsapp_user_by_id(uid, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      if (is.null(u)) return(fail("账号不存在。"))
      if (!identical(as.character(u$token %||% ""),
                     trimws(as.character(input$rec_token %||% "")))) {
        return(fail("恢复码不对。",
                    "它在你注册时显示过一次，形如 a1b2c3…；丢了就找管理员重置。"))
      }
      do_change(input$new_pw, input$new_pw2, NULL, skip_old = TRUE)
    })

    invisible(NULL)
  })
}

#' @param entry_token 反应式：从 URL 参数或 cookie 里取到的令牌
#' @param on_login 回调 function(user, token)
#' @param entry_src 反应式：这个令牌是从哪来的 —— "url" 还是 "cookie"。
#'   单端登录（V11 item 4b）要拿它区分两件**长得一样、处理却相反**的事：
#'     · URL 令牌（`?u=...`）：用户明确的意图是"我要在这个端上用这个账号"，
#'       所以这一端**认领**，把原来那一端顶下线；
#'     · cookie：浏览器自己带的，用户什么都没说。它不是当前那一端时**不认领**
#'       —— 认领的话两个端会互相顶，永远停在"正在加载"。
#'   默认 NULL = 一律按 cookie 处理（也就是"不认领"），方向安全。
mod_welcome_server <- function(id, entry_token, on_login, entry_src = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    auto_tried <- reactiveVal(FALSE)
    # 注册成功、还没点「进入应用」的那一步（见 do_register 里的说明）
    pending <- reactiveVal(NULL)
    # 当前视图："login" / "register" / "token"（恢复码）/ "done"（亮恢复码）
    #
    # ⚠️ 库里一个账号都没有时，开局就落在**注册**页，不是登录页。
    #    V6 把默认模式改成 login 之后这一条是必需的：全新部署上没有任何
    #    账号，停在登录页的话用户填什么都是"密码不对"，而"去注册"是下面
    #    一行小链接 —— 第一次打开这个应用的人根本不知道该点它。
    #    第一个注册的账号自动是管理员（见 dsapp_user_create 的 is_first）。
    #
    #    查一次库放在模块初始化时：这个判断在会话期间不会变（"有没有账号"
    #    只会从 0 变成 1，而那个 1 就是本次会话注册出来的，注册完自然
    #    走到 done 视图去了）。
    no_accounts <- tryCatch(
      DBI::dbGetQuery(dsapp_db(cfg), "SELECT COUNT(*) AS n FROM users")$n[[1]] == 0,
      error = function(e) FALSE)
    view <- reactiveVal(if (isTRUE(no_accounts)) "register" else "login")
    msg  <- reactiveVal(NULL)

    # ---- cookie / URL 里带着令牌进来：直接认领 ----
    observeEvent(entry_token(), {
      tok <- entry_token()
      if (!nzchar(tok)) return()
      if (isTRUE(auto_tried())) return()

      # ⚠️ auto_tried 必须**在这里**才置位，不能提到 nzchar 判断之前。
      #
      #    entry_token() 在页面刚连上时是空串（cookie 还没送过来），而这个
      #    observer 的 ignoreNULL = FALSE，所以它第一拍就会跑一次空值。
      #    提前置位的话，等到真正的 cookie 到达时 auto_tried 已经是 TRUE，
      #    直接 return —— 表现是"注册完跳回注册页，怎么刷新都进不去"，
      #    而服务端一点错都不报。
      #
      #    置位放在这里 = 只有**真的拿一个非空令牌试过一次**才算试过。
      #    仍要置位（而不是简单地每次都试）：令牌失效时下面会清 cookie，
      #    清完 cookie 又会触发一次 entry_token()，不置位就成了死循环。
      auto_tried(TRUE)

      src <- tryCatch(as.character(entry_src() %||% "cookie"),
                      error = function(e) "cookie")
      u <- tryCatch(dsapp_user_by_token(tok, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      if (is.null(u)) {
        # dsapp_user_by_token 是**严格**的：令牌 + "这一端是当前那一端"，
        # 两个都对才认。这里处理它判否之后的三种情况 —— 一锅端成"令牌失效"
        # 是不行的：凭令牌明明找得到人、只是**不是当前那一端**的时候，
        # 用户该看到"你的账号在别处登录了"，而不是莫名其妙回到登录页。
        # 后者会让人以为账号被盗了，或者来问"是不是坏了"。
        u2 <- tryCatch(dsapp_user_by_token_raw(tok, con = dsapp_db(cfg)),
                       error = function(e) NULL)
        if (!is.null(u2) && identical(src, "url")) {
          # ① URL 令牌：用户是**故意**点着这条链接来的（"换台电脑接着用"，
          #    也是 cookie 全丢时的退路）。这不是自动登录，是一次明确的
          #    "我要在这个端上用这个账号" —— 所以往下走通用流程，由
          #    on_login 认领这一端（把原来那一端顶下线）。
          u <- u2
        } else {
          if (!is.null(u2) && dsapp_user_active(u2) &&
              nzchar(dsapp_login_split(tok)$nonce)) {
            # ② 同账号在别处登录了（单端登录把它顶掉了）。说清楚再清 cookie
            #    —— 不清的话，之后每次刷新都会拿这串已经作废的值再试一遍。
            showNotification(
              tagList(icon("right-from-bracket"),
                      " 这个账号刚刚在别的地方登录了，本机已自动退出。",
                      tags$br(),
                      "同一个账号同一时间只允许一个端在用。在这里重新登录，",
                      "会把那边顶下线。"),
              type = "warning", duration = NULL)
          } else if (!is.null(u2) && dsapp_user_active(u2)) {
            # ③ 令牌没问题，但它里面没有"这一端"的信息：V11 之前发出去的
            #    老 cookie（那时还没有单端登录，见 R/logins.R）。
            #    **判否**是刻意的 —— 放行等于给了一条绕开单端限制的路
            #    （手写一个不带点的 cookie 就行）。代价是升级之后每个端
            #    重新登录一次，所以这里要**说一句**，不能让人对着登录页
            #    猜"我怎么掉线了"。
            showNotification("登录状态已更新，请重新登录一次。",
                             type = "message", duration = NULL)
          }
          # ④ 剩下的才是真的失效：令牌过期、被管理员重置、库被换过。
          #    静默清掉，让他重新登录或者注册。
          session$sendCustomMessage("dsapp:clearToken", list())
          return()
        }
      }
      if (!dsapp_user_active(u)) {
        showNotification("这个账号已被停用，请联系管理员", type = "error",
                         duration = NULL)
        session$sendCustomMessage("dsapp:clearToken", list())
        return()
      }
      # reload = FALSE：见 app.R 里 on_login 的说明 —— 这条路是页面刚加载
      # 时凭 cookie 自动进来的，重载一次就会再触发一次自动登录，无限循环。
      on_login(u, tok, reload = FALSE)
    }, ignoreNULL = FALSE)

    # ---- 视图渲染 ----------------------------------------------------------
    # 五个界面共用一个 msg()，不再每个视图各挂一个 output$xxx_msg：
    # 换视图时忘记清消息，就会把上一个视图的报错带到下一个视图上。

    msg_ui <- function(m) {
      if (is.null(m)) return(NULL)
      div(class = paste("dsapp-auth-msg", if (isTRUE(m$ok)) "is-ok" else "is-error"),
          m$text,
          if (nzchar(m$hint %||% "")) span(class = "dsapp-auth-hint", m$hint))
    }

    output$auth_page <- renderUI({
      switch(view(),

        login = dsapp_auth_shell("登录到 Biomamba",
          sub = "言出法随生信分析平台",
          body = tagList(
            textInput(ns("login_email"), "邮箱", placeholder = "name@example.com"),
            # ★ V13.1 item 7：占位符原来是「没设过密码就留空」。免密那条路
            #   删掉之后，留空只会换来一句"这个账号还没有设密码"—— 不如
            #   直接告诉用户这条路已经没有了，以及没有密码时该走哪。
            passwordInput(ns("login_password"), "密码",
                          placeholder = "注册时设的密码"),
            # 和注册页同理：读 msg() 会让报错重建整棵表单，把邮箱清空。
            uiOutput(ns("auth_msg")),
            actionButton(ns("do_login"), "继续", class = "dsapp-btn-primary"),
            div(class = "dsapp-auth-alt",
              actionLink(ns("go_register"), "创建账号"),
              span(class = "dsapp-auth-dot", "·"),
              actionLink(ns("go_token"), "用恢复码")
            )
          ),
          note = dsapp_auth_note()),

        register = dsapp_auth_shell("创建你的账号",
          sub = "用来记住你的对话、任务和文件",
          wide = TRUE,
          body = tagList(
            textInput(ns("nickname"), "昵称", placeholder = "怎么称呼你"),
            textInput(ns("email"), "邮箱", placeholder = "name@example.com"),
            textInput(ns("phone"), "手机号", placeholder = "11 位手机号"),
            textInput(ns("field"), "研究方向",
                      placeholder = "如：单细胞转录组 / 肿瘤免疫"),
            # ★ V13.1 item 7：原来是「密码（选填） / 留空 = 别人填你的邮箱
            #   就能进」。必填之后这两个说法都不成立：留空注册不出账号
            #   （dsapp_user_validate 会挡），而"别人填邮箱就能进"这件事
            #   已经不存在了。占位符改成正面说明它**是干什么的**。
            passwordInput(ns("password"), "密码",
                          placeholder = sprintf("至少 %d 位，登录时要用", DSAPP_PW_MIN)),

            # ---- 用户须知（V9 item 1）----
            #
            # ⚠️ 勾选框必须**在**须知下面，而且中间不能夹别的东西。这是
            #    "我读过上面那段"的勾，把须知折叠起来、或者让它跑到屏幕
            #    外面去，勾的就变成了一个纯形式 —— 而这条同意是要进日志、
            #    以后要能拿出来说事的。
            #
            # ⚠️ 校验放在服务端（见下面 do_register），**不靠**"没勾就把
            #    按钮置灰"。置灰那套要 JS 参与，而注册页是 renderUI 出来的，
            #    每次重渲染都要重新挂一遍 —— 漏挂一次就是"没勾也能提交"，
            #    且不报错。服务端那句 if 才是判据，前端那点效果只是提示。
            div(class = "dsapp-tos-wrap",
              dsapp_tos_body_ui(),
              div(class = "dsapp-tos-meta", dsapp_tos_meta())
            ),
            checkboxInput(ns("tos_agree"),
              tagList("我已阅读并同意上述《用户须知》",
                      tags$span(class = "dsapp-tos-meta",
                                sprintf("（%d 天后需要再确认一次）",
                                        DSAPP_TOS_DAYS))),
              value = FALSE),

            # ⚠️ 这里**不能**直接写 msg_ui(msg())。
            #    这一整页是 renderUI 出来的，一旦它读了 msg()，任何一次
            #    报错都会把整棵表单重建一遍 —— 用户填的昵称/邮箱/密码全没了，
            #    只剩一句错误提示。以前注册很少失败（多半是邮箱重复），
            #    这个坑不明显；V9 加了「不勾须知就拒绝」之后它变成了一条
            #    **人人都会踩**的路径：填完一屏、忘了勾、点一下，全清空。
            #    把消息挪进它自己的 output，表单就不再跟着消息一起重建。
            uiOutput(ns("auth_msg")),
            actionButton(ns("do_register"), "创建账号", class = "dsapp-btn-primary"),
            div(class = "dsapp-auth-alt", actionLink(ns("go_login"), "已有账号"))
          ),
          note = dsapp_auth_note()),

        token = dsapp_auth_shell("用恢复码登录",
          sub = "换电脑、清了缓存、无痕窗口时走这条",
          logo = "key",
          body = tagList(
            textInput(ns("login_email"), "邮箱", placeholder = "name@example.com"),
            textInput(ns("login_token"), "恢复码",
                      placeholder = "注册时给你的那串字符"),
            uiOutput(ns("auth_msg")),
            actionButton(ns("do_token_login"), "继续", class = "dsapp-btn-primary"),
            div(class = "dsapp-auth-alt", actionLink(ns("go_login"), "返回登录"))
          ),
          note = dsapp_auth_note()),

        done = {
          p <- pending()
          if (is.null(p)) {
            # 理论上到不了（done 只在注册成功后进）。真到了就退回注册页，
            # 不留一屏白板。
            view("register"); return(NULL)
          }
          dsapp_auth_shell("保存你的恢复码",
            sub = "换电脑、清缓存、无痕窗口时，凭「邮箱 + 这串码」找回账号",
            logo = "circle-check",
            body = tagList(
              div(class = "d-flex gap-2 align-items-start mb-3",
                div(class = "dsapp-auth-token flex-grow-1",
                    id = ns("token_text"), p$token),
                tags$button(type = "button",
                  class = "btn dsapp-btn-quiet",
                  style = "width:auto;",
                  onclick = sprintf(
                    "dsappCopyText(this, document.getElementById('%s').innerText)",
                    ns("token_text")),
                  icon("copy"))
              ),
              p(class = "dsapp-auth-msg is-error",
                icon("triangle-exclamation"),
                " 只显示这一次，请自行保存。",
                span(class = "dsapp-auth-hint",
                     "丢了就只能找管理员重置，此前的对话还在，但认领不回来。")),
              if (nzchar(p$claimed)) {
                p(class = "small mb-3", style = "color: var(--auth-ok);",
                  icon("wand-magic-sparkles"), " ", p$claimed)
              },
              actionButton(ns("enter_app"), "我已保存，进入应用",
                           class = "dsapp-btn-primary")
            ))
        }
      )
    })

    # 报错信息**单独一个 output**，不跟表单一起渲染。
    #
    # ⚠️ 这不是"顺手拆一下"。它拆掉的是一条很难看的路径：消息原来长在
    #    auth_page 里面，于是 auth_page 依赖 msg() —— 任何一次登录失败都会
    #    重建整棵表单，把用户刚填的邮箱清空，只剩一句"密码不对"。
    #    用户能看到的只是"每次都要重打一遍邮箱"，而原因（renderUI 的依赖）
    #    在界面上完全没有痕迹。V9 的注册须知让这条路径变成人人必踩
    #    （忘了勾 → 报错 → 整屏清空），才暴露出来。
    output$auth_msg <- renderUI(msg_ui(msg()))

    # ---- 视图切换 ----------------------------------------------------------
    go <- function(v) { msg(NULL); view(v) }
    observeEvent(input$go_register, go("register"))
    observeEvent(input$go_login,    go("login"))
    observeEvent(input$go_token,    go("token"))

    # ---- 注册 ----
    observeEvent(input$do_register, {
      # 用户须知（V9 item 1）。**这是判据，不是提示** —— 上面那个勾选框
      # 没有任何前端拦截，不勾也能点到这个按钮。
      if (!isTRUE(input$tos_agree)) {
        return(msg(list(ok = FALSE,
                        text = "请先阅读并勾选同意《用户须知》",
                        hint = "就在密码下面那个方框。这一条是要留档的，不能跳过。")))
      }

      r <- tryCatch(
        dsapp_user_create(input$nickname, input$email, input$phone, input$field,
                          password = input$password %||% "",
                          con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))

      if (!isTRUE(r$ok)) {
        return(msg(list(ok = FALSE, text = r$msg)))
      }
      msg(NULL)

      # 同意日志。**必须在注册成功之后写**（要有 user_id），而且**写失败
      # 不能把注册也判失败** —— 账号已经建好了，此时报"注册失败"是假话，
      # 用户重填一次会撞上"邮箱已注册"。
      #
      # 写不进去的后果只是"这个人下次进来会被再问一遍"，那是可接受的；
      # 但要**说出来**，不能静默 —— 静默的话，日志里少一行而没有任何痕迹，
      # 事后查"这个人到底同意过没有"就无从对证。
      tryCatch(
        dsapp_tos_record(r$user$id, source = "register",
                         ua = session$request$HTTP_USER_AGENT %||% "",
                         con = dsapp_db(cfg)),
        error = function(e) {
          showNotification(
            paste0("账号已创建，但同意记录没能写入（", conditionMessage(e),
                   "）。下次进入应用时会再请你确认一次。"),
            type = "warning", duration = NULL)
        })

      # cookie 先写好再显示恢复码：万一用户看到码就直接关掉标签页，
      # 同一个浏览器下次进来仍然是登录状态，不至于卡在门外。
      # 这里**不等回执** —— 用户接下来还要点一次「进入应用」才 reload，
      # 那一次才走 app.R 里的等待逻辑。这一步失败也由那一次兜住。
      session$sendCustomMessage("dsapp:setToken", list(token = r$token))

      # ⚠️ 这里**不立刻**调 on_login()。
      #
      #    调了的话 app.R 马上把整页换成主界面，恢复码只在一条通知里闪过
      #    几秒 —— 而这串码是 cookie 失效后唯一的退路（浏览器禁用 cookie、
      #    无痕窗口、换电脑都会走到那一步）。宁可多一次点击，也要让它
      #    停在一个必须被看见的位置上。
      pending(list(user = r$user, token = r$token, claimed = r$msg %||% ""))
      view("done")
    })

    observeEvent(input$enter_app, {
      p <- pending()
      if (is.null(p)) return()
      on_login(p$user, p$token)
    })

    # ---- 登录（邮箱 + 密码）----
    # cookie 由 on_login 统一写（它还要等回执才 reload），这里不重复发。
    observeEvent(input$do_login, {
      r <- tryCatch(
        dsapp_user_auth(input$login_email, input$login_password %||% "",
                        con = dsapp_db(cfg), session = session),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(r$ok)) {
        return(msg(list(ok = FALSE, text = r$msg)))
      }
      msg(NULL)
      on_login(r$user, r$token)
    })

    # ---- 登录（邮箱 + 恢复码）----
    observeEvent(input$do_token_login, {
      r <- tryCatch(
        dsapp_user_auth_token(input$login_email, input$login_token,
                              con = dsapp_db(cfg), session = session),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(r$ok)) {
        return(msg(list(ok = FALSE, text = r$msg)))
      }
      msg(NULL)
      on_login(r$user, r$token)
    })

    invisible(NULL)
  })
}
