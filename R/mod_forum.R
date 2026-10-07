# =============================================================================
# 论坛页（V15 item 8）
# =============================================================================
# 用户原话：「加一个论坛页面，用户能交流自己使用过程中的经验或遇到的问题。
# 你需要考虑好同步问题，现有的账户体系是靠什么为枢纽进行同步的？」
#
# 数据层在 R/forum.R（那里有完整的同步设计），这一页只管界面。
#
# ---- 这一页的形状 -----------------------------------------------------------
#
# **单栏，列表 ↔ 详情两态**，用一个 `cur`（当前打开的帖子）切。不是左右
# 分栏，理由：这一页的内容宽度弹性很大（有人贴一屏报错栈，有人就写两行），
# 分栏之后两栏都得迁就对方；而且列表和详情各自都是"一屏读得完"的东西，
# 同时看没有收益。
#
# ---- 三个界面上的取舍 -------------------------------------------------------
#
# 1. **正文走 dsapp_md_html**（R/render.R），不自己拼 HTML。
#    那个函数是"先转义、再 commonmark、再过链接协议白名单"三步 —— 论坛
#    是全应用**唯一**一处"A 写的东西直接渲染给 B 看"的地方，也就是唯一
#    有真正 XSS 面的地方（对话里模型写的东西只给写的人自己看）。所以
#    **一处都不许绕开它**：新加任何显示用户文本的地方，都走它。
#
# 2. **行内的动作走一个共用的 input**（`input$act`，值是 `"动作|参数"`），
#    不是每行注册一个 observer。这是仓库里既有的做法（mod_files.R 的
#    ws_act_link、mod_tasks.R 的 art_link）：renderUI 里逐个注册 observer
#    会留下一批**永不回收**的观察者，而且它们闭包里抓着的是**上一次渲染
#    时**的那份数据 —— 表现是"点了这条，打开的是上一条"。
#
# 3. **软删的楼层留在列表里**（画成"该回复已被删除"），不整段抽掉。
#    抽掉的话楼下的楼层号会变，而"你看 5 楼说的"这句话在别人屏幕上就指向
#    另一条了。这是论坛的通行做法，也和 dsapp_forum_posts 那句 SQL 一致。
# =============================================================================

mod_forum_ui <- function(id) {
  ns <- NS(id)

  # ★ V15.3 item 1：`dsapp-page-flush` 补的是**别处由 card-body 提供的那 1rem
  # 左留白**。论坛页是唯一一个不套 `card()` 的整页（见 www/app.css 里那条
  # 注释），所以只有它顶到窗口左边沿 —— 上面那个标题看起来就是"贴着边写的"。
  div(class = "dsapp-page dsapp-page-flush", id = ns("page"),

    # ---- 顶栏 -------------------------------------------------------------
    div(class = "dsapp-forum-head",
      div(class = "dsapp-forum-head-l",
        tags$h4(class = "dsapp-forum-title", icon("comment-dots"), " 论坛"),
        # ⚠️ V15.5 item 3：div() 里的字符串是纯文本，`**…**` 不会变粗体 ——
        #    用户看到的是星号。要强调就用 tags$b()。
        tags$div(class = "dsapp-forum-sub",
          "说说你踩过的坑、问一句卡住的地方。发出去的内容",
          tags$b("所有用户可见"), "，别贴密钥、别贴别人的数据。")
      ),
      div(class = "dsapp-forum-head-r",
        actionButton(ns("new"), tagList(icon("pen-to-square"), " 发帖"),
                     class = "btn btn-primary btn-sm dsapp-forum-new"),
        actionButton(ns("refresh"), tagList(icon("rotate"), " 刷新"),
                     class = "btn btn-outline-secondary btn-sm")
      )
    ),

    # ---- 筛选行 -----------------------------------------------------------
    #
    # ⚠️ 全部用带命名空间的 id，而且**拼写固定**（cat/q/sort/mine/scope）——
    #    浏览器验收脚本按 id 找它们，改名就是"探针找不到控件"，而那种红
    #    看起来像"这一页没渲染出来"。
    div(class = "dsapp-forum-bar",
      div(class = "dsapp-forum-bar-item",
        selectInput(ns("cat"), NULL,
                    choices = c(c("全部板块" = ""),
                                dsapp_forum_cat_choices(TRUE)),
                    selected = "", width = "150px")
      ),
      div(class = "dsapp-forum-bar-item dsapp-forum-bar-grow",
        textInput(ns("q"), NULL, value = "", placeholder = "搜标题 / 正文 / 标签 / 作者")
      ),
      div(class = "dsapp-forum-bar-item",
        selectInput(ns("sort"), NULL,
                    choices = c("最新回复" = "active", "最新发布" = "new",
                                "回复最多" = "hot", "最多有用" = "like"),
                    selected = "active", width = "130px")
      ),
      div(class = "dsapp-forum-bar-item",
        # ⚠️ 文案必须和**实际筛的东西**一致。这一项筛的是 `author_email`，
        #    也就是"我发的帖子"—— 写成「我参与的」会让用户以为回复过的
        #    帖子也在里面（那要 OR 一个 EXISTS，dsapp_forum_list 那套 where
        #    是且的关系，做不了），找不到自己回复过的帖时会以为是 bug。
        checkboxInput(ns("mine"), "只看我发的", value = FALSE)
      )
    ),

    # ---- 主体：列表 或 详情 ------------------------------------------------
    #
    # ⚠️ **只有一个** output 承担这两种视图。"列表一个 output + 详情一个
    #    output、用 shinyjs 藏一个"那种写法在这里会出两类问题：
    #      · 两个 output 都会渲染（详情那个没有 cur 时会报错）；
    #      · 藏起来的那一份**仍在 DOM 里**，里面的 input id 和显示的那份
    #        重复 —— bslib 把整页留在 DOM 里的那个坑（见 tests/ui_v14 的
    #        README 第 3 条）会在这里再犯一次。
    uiOutput(ns("body"))
  )
}

mod_forum_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config
    con <- function() dsapp_db(cfg())

    # 当前打开的帖子（"node:id"），NULL = 列表视图
    cur <- reactiveVal(NULL)
    # 数据版本号：任何一次写库之后 +1，驱动列表和详情重读。
    # ⚠️ 它是**显式**的失效源，不是"反正 reactive 会自己刷"。这一页读的都是
    #    普通的 DB 查询（不是 reactiveValues），没有它的话发完帖列表不动 ——
    #    用户会以为没发出去，然后再发一遍。
    bump <- reactiveVal(0L)
    # 自动刷新：论坛是别人也能写的地方，不刷新就永远停在打开那一刻。
    # ⚠️ 用 `reactiveTimer` 而不是自己写 `invalidateLater` + `reactiveVal`
    #    自增：后者在这种"定时器 + 自己读自己"的写法下有一个很难查的症状
    #    —— 定时器会瞬间烧穿然后静默停掉（不是卡死，是什么都不再发生）。
    tick <- reactiveTimer(60000)

    user <- function() state$user
    email <- function() dsapp_forum_author(state$user)$email
    # ⚠️ `state` 里**没有** is_admin 这个字段（app.R 里那个 is_admin 是
    #    dsapp_main_ui 的局部变量，只在渲染那一层用）。模块要自己判 ——
    #    写成 `state$is_admin` 的话永远是 NULL，表现是"管理员在这个页面上
    #    看不到任何管理按钮"，而其它页面一切正常。
    is_admin <- function() dsapp_user_is_admin(state$user)

    #' 提示：写在这里的每一句话都会走通知条
    #'
    #' ⚠️ 失败一定要说**为什么**。这一页上"操作没生效"有至少五种原因
    #'    （没登录、限流、不是作者、网络那头的同步还没到、写库失败），
    #'    统一成一句"操作失败"的话，用户唯一能做的就是再点一次。
    said <- function(r, ok_msg = NULL) {
      if (isTRUE(r$ok)) {
        if (!is.null(ok_msg)) showNotification(ok_msg, type = "message", duration = 3)
      } else {
        showNotification(r$msg %||% "操作失败", type = "warning", duration = 6)
      }
      invisible(isTRUE(r$ok))
    }

    # 搜索框防抖（350ms）。
    #
    # ⚠️ 不加的话**每敲一个字**都会重跑一次查询 + 重画整个列表（最多 300 行
    #    HTML，在 R 里一行一行拼出来的）。SQLite 那一下不算什么，贵的是渲染
    #    —— 打字会明显卡顿。350ms 是"停了才查"，正常打字感觉不到延迟。
    # ⚠️ 防抖之后第一次读可能拿到 NULL（`debounce` 在头一次 flush 之前不
    #    发值），所以外面还要兜一层 `%||% ""` —— 不兜的话那句 `nzchar(NULL)`
    #    在列表为空的分支里会抛 "argument is of length zero"。
    q_deb <- shiny::debounce(reactive(input$q), 350L)
    q_now <- reactive({
      v <- q_deb()
      if (is.null(v)) "" else as.character(v)
    })

    # ---- 列表数据 ---------------------------------------------------------
    threads <- reactive({
      tick()            # 自动刷新（见上面那段注释）
      bump()
      u <- user()
      a <- dsapp_forum_author(u)
      dsapp_forum_list(
        category = input$cat %||% "",
        q        = q_now(),
        sort     = input$sort %||% "active",
        # ⚠️ 只筛 author_email（=「我发的」）。`replied_by` 那一项在
        #    dsapp_forum_list 里是**另一个**筛子，两个一起传就是"我发的
        #    而且我回复过的"——对一条新帖来说后半句永远不成立，于是列表
        #    空掉。所以这里二选一，界面上写的也是"我发的"。
        author_email = if (isTRUE(input$mine)) a$email else "",
        viewer_email = a$email,
        is_admin = is_admin(),
        limit = 300L,
        con = con())
    })

    # ---- 列表视图 ---------------------------------------------------------
    list_view <- function() {
      u <- user(); a <- dsapp_forum_author(u)
      df <- threads()
      mine_stat <- dsapp_forum_my_stat(a$email, con = con())

      head <- div(class = "dsapp-forum-mystat",
        sprintf("你发过 %d 条帖、%d 条回复，「有用」点过 %d 次。",
                mine_stat$threads, mine_stat$posts, mine_stat$likes))

      if (is.null(df) || !nrow(df)) {
        return(tagList(head,
          div(class = "dsapp-forum-empty",
            icon("inbox"),
            tags$p(if (nzchar(trimws(q_now())))
                     "没有匹配的帖子，换个词试试。"
                   else "还没有人发帖。第一帖留给你？"),
            actionButton(ns("new2"), tagList(icon("pen-to-square"), " 发帖"),
                         class = "btn btn-primary btn-sm"))))
      }

      rows <- lapply(seq_len(nrow(df)), function(i) {
        r <- df[i, , drop = FALSE]
        key <- dsapp_forum_key(r$origin_node, r$origin_id)
        mine <- .dsapp_forum_email_eq(r$author_email, a$email)
        vis <- dsapp_forum_visible(r$status, is_mod = is_admin(), is_mine = mine)
        div(class = paste("dsapp-forum-row",
                          if (isTRUE(as.integer(r$pinned) == 1L)) "is-pinned" else "",
                          if (!vis) "is-faded" else ""),
          # 整行可点（标题是那个链接，整行的空白区域也能点）
          tags$a(href = "#", class = "dsapp-forum-row-hit",
                 onclick = sprintf(
                   "Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
                   jsonlite::toJSON(ns("act"), auto_unbox = TRUE),
                   jsonlite::toJSON(paste0("open|", key), auto_unbox = TRUE)),
                 `aria-label` = r$title),
          div(class = "dsapp-forum-row-main",
            div(class = "dsapp-forum-row-title",
              if (isTRUE(as.integer(r$pinned) == 1L))
                span(class = "dsapp-forum-pin", icon("thumbtack"), " 置顶"),
              span(class = paste0("dsapp-forum-cat cat-", r$category),
                   icon(dsapp_forum_cat_icon(r$category)),
                   " ", dsapp_forum_cat_label(r$category)),
              if (identical(as.character(r$status), "solved"))
                span(class = "dsapp-forum-solved", icon("circle-check"), " 已解决"),
              if (identical(as.character(r$status), "hidden"))
                span(class = "dsapp-forum-hidden", icon("eye-slash"), " 已隐藏"),
              if (identical(as.character(r$status), "closed"))
                span(class = "dsapp-forum-closed", icon("lock"), " 已关闭"),
              span(class = "dsapp-forum-row-tt", r$title)
            ),
            div(class = "dsapp-forum-row-meta",
              span(class = "dsapp-forum-author", r$author_name %||% "匿名"),
              span(class = "dsapp-forum-dot", "·"),
              span(dsapp_forum_ago(r$updated_at)),
              span(class = "dsapp-forum-dot", "·"),
              span(icon("comment"), " ", as.integer(r$n_replies)),
              span(class = "dsapp-forum-dot", "·"),
              span(icon("thumbs-up"), " ", as.integer(r$n_likes)),
              span(class = "dsapp-forum-dot", "·"),
              span(icon("eye"), " ", as.integer(r$views))
            ),
            if (nzchar(r$tags %||% ""))
              div(class = "dsapp-forum-row-tags",
                lapply(strsplit(r$tags, ",", fixed = TRUE)[[1]],
                       function(t) span(class = "dsapp-forum-tag", t)))
          )
        )
      })
      tagList(head, div(class = "dsapp-forum-list", rows))
    }

    # ---- 详情视图 ---------------------------------------------------------
    detail_view <- function() {
      key <- cur()
      if (is.null(key)) return(NULL)
      # ★★★ 详情视图必须**显式**读 bump()，和列表一样。
      #     不读的话：点了「有用」按钮上的字不变、发完回复楼层不出现、
      #     作者点了「标记已解决」状态不动 —— 全都只在**退回列表再点进来**
      #     之后才看得见。写这一页时这里就没读（文件头上写着 bump
      #     "驱动列表和详情重读"，但实际只有列表读了），V15 的浏览器探针
      #     第一条红的就是它：库里 mark 明明写进去了（`库里的赞记下来了` ✓），
      #     页面上那颗按钮还写着「有用」。自检看不见这一类 —— 它验的是
      #     `dsapp_forum_mark()` 的返回值，不是"谁在什么时候重画"。
      # ⚠️ 这里**故意不读 tick()**。列表读它是为了 60 秒自动刷新（论坛是别人
      #    也会写的地方），但详情跟着 tick 重画的话，用户正在打的那半句回复
      #    会被冲掉 —— renderUI 重画是**换掉整棵 DOM 子树**，textAreaInput
      #    的值只存在于 DOM 里。详情要手动刷就点顶栏那颗「刷新」（它 bump）。
      bump()
      kk <- dsapp_forum_unkey(key)
      u <- user(); a <- dsapp_forum_author(u)
      th <- dsapp_forum_thread(kk[["node"]], kk[["id"]], con = con())
      if (is.null(th)) {
        return(div(class = "dsapp-forum-empty",
          "这条帖子本机没有（可能刚被删掉，或者同步还没到）。",
          actionButton(ns("back0"), " 返回列表", class = "btn btn-sm btn-outline-secondary")))
      }
      mine <- .dsapp_forum_email_eq(th$author_email, a$email)
      can_edit <- dsapp_forum_can_edit(th$author_email, a$email, is_admin())
      st <- as.character(th$status)

      # 详情视图的「有用 / 回复 / 编辑 / 删除」等一律走共用 input$act，
      # 参数是 `动作|帖子key` 或 `动作|帖子key|回复key`。
      like <- dsapp_forum_i_liked("thread", kk[["node"]], kk[["id"]],
                                  a$email, con = con())

      head <- div(class = "dsapp-forum-detail-head",
        actionButton(ns("back"), tagList(icon("arrow-left"), " 返回"),
                     class = "btn btn-sm btn-outline-secondary dsapp-forum-back"),
        div(class = "dsapp-forum-detail-title",
          if (isTRUE(as.integer(th$pinned) == 1L))
            span(class = "dsapp-forum-pin", icon("thumbtack"), " 置顶"),
          span(class = paste0("dsapp-forum-cat cat-", th$category),
               icon(dsapp_forum_cat_icon(th$category)),
               " ", dsapp_forum_cat_label(th$category)),
          if (identical(st, "solved"))
            span(class = "dsapp-forum-solved", icon("circle-check"), " 已解决"),
          if (identical(st, "closed"))
            span(class = "dsapp-forum-closed", icon("lock"), " 已关闭"),
          if (identical(st, "hidden"))
            span(class = "dsapp-forum-hidden", icon("eye-slash"), " 已隐藏"),
          tags$h3(class = "dsapp-forum-detail-tt", th$title)
        ),
        div(class = "dsapp-forum-detail-meta",
          span(class = "dsapp-forum-author", th$author_name %||% "匿名"),
          span(class = "dsapp-forum-dot", "·"),
          span(substr(as.character(th$created_at), 1L, 16L), " UTC"),
          span(class = "dsapp-forum-dot", "·"),
          span(icon("eye"), " ", as.integer(th$views), " 次浏览"),
          if (nzchar(th$tags %||% ""))
            span(class = "dsapp-forum-row-tags",
              lapply(strsplit(th$tags, ",", fixed = TRUE)[[1]],
                     function(t) span(class = "dsapp-forum-tag", t)))
        )
      )

      actbar <- div(class = "dsapp-forum-actions",
        act_btn(if (like) "已标记有用" else "有用",
                if (like) "unlike" else "like", key,
                ico = "thumbs-up",
                cls = if (like) "btn btn-sm btn-success" else "btn btn-sm btn-outline-success"),
        if (can_edit && !identical(st, "closed") && !identical(st, "solved"))
          act_btn("标记已解决", "solved", key, ico = "circle-check",
                  cls = "btn btn-sm btn-outline-primary"),
        if (can_edit && identical(st, "solved"))
          act_btn("取消已解决", "reopen", key, ico = "rotate-left",
                  cls = "btn btn-sm btn-outline-secondary"),
        if (can_edit && !identical(st, "closed"))
          act_btn("关闭回复", "close", key, ico = "lock",
                  cls = "btn btn-sm btn-outline-secondary"),
        if (can_edit)
          act_btn("编辑", "edit", key, ico = "pen", cls = "btn btn-sm btn-outline-secondary"),
        if (can_edit)
          act_btn("删除", "del", key, ico = "trash", cls = "btn btn-sm btn-outline-danger"),
        if (is_admin() && !isTRUE(as.integer(th$pinned) == 1L))
          act_btn("置顶", "pin", key, ico = "thumbtack", cls = "btn btn-sm btn-outline-secondary"),
        if (is_admin() && isTRUE(as.integer(th$pinned) == 1L))
          act_btn("取消置顶", "unpin", key, ico = "thumbtack",
                  cls = "btn btn-sm btn-outline-secondary"),
        if (is_admin() && !identical(st, "hidden") && !identical(st, "deleted"))
          act_btn("隐藏", "hide", key, ico = "eye-slash", cls = "btn btn-sm btn-outline-secondary"),
        if (is_admin() && identical(st, "hidden"))
          act_btn("恢复", "unhide", key, ico = "eye", cls = "btn btn-sm btn-outline-secondary")
      )

      # ⚠️ 这里带上了 `dsapp-preview-md` —— 那不是"文件预览专用"，它是仓库里
      #    **唯一一份**渲染后 markdown 的排版（标题/列表/代码块/表格/行内码，
      #    见 www/app.css）。正文的长相和文件预览本来就该一致，抄第二份的话
      #    以后调了预览那边、论坛这边不会跟着动。用 `.dsapp-forum-*` 那一层
      #    只覆盖两处**确实不同**的：max-height 和 overflow（文件预览是在一个
      #    固定格子里滚动，帖子正文该顺着页面往下流）。
      body <- div(class = "dsapp-preview-md dsapp-forum-detail-body",
        HTML(dsapp_md_html(as.character(th$body %||% ""))))

      # ---- 楼层 ----
      posts <- dsapp_forum_posts(kk[["node"]], kk[["id"]],
                                 viewer_email = a$email,
                                 is_admin = is_admin(), con = con())
      n <- if (is.null(posts)) 0L else nrow(posts)
      floors <- if (n == 0L) {
        div(class = "dsapp-forum-noreply", "还没有回复。")
      } else {
        # 楼层号：只给**顶楼**编号，楼中楼标成"N 楼回复"。编号在两台机器上
        # 必须一致 —— 所以顺序完全由 dsapp_forum_posts 那句 SQL 定（它带了
        # origin_node, origin_id 兜底），这里**不重排**。
        #
        # ⚠️ 用 `reply_to_oid` 有没有值来判"是不是顶楼"，而不是查它的父层
        #    在不在 —— 父层可能已经被删了（软删的行还在，但真被清理掉、
        #    或者引用的是别的机器上一条还没同步过来的回复）。那时按父子
        #    关系判会**把它降级成顶楼**，楼层号整体错位。
        top <- which(!nzchar(as.character(posts$reply_to_oid %||% rep("", n))))
        no <- stats::setNames(seq_along(top), top)
        lapply(seq_len(n), function(i) {
          p <- posts[i, , drop = FALSE]
          pk <- dsapp_forum_key(p$origin_node, p$origin_id)
          pst <- as.character(p$status)
          deleted <- identical(pst, "deleted")
          hidden <- identical(pst, "hidden")
          # 这一层是楼中楼的话，找到它引用的那一层的显示号
          label <- if (i %in% top) {
            as.character(no[[as.character(i)]])
          } else {
            par <- which(as.character(posts$origin_node) ==
                           as.character(p$reply_to_onode) &
                         as.character(posts$origin_id) ==
                           as.character(p$reply_to_oid))
            # 父层自己也是楼中楼的话，`no` 里没有它 —— 退到"回复"，
            # 不编一个假号出来。
            if (length(par) && !is.na(no[as.character(par[1])])) {
              paste0(no[[as.character(par[1])]], " 楼回复")
            } else "回复"
          }
          div(class = paste("dsapp-forum-floor",
                            if (!(i %in% top)) "is-child" else "",
                            if (deleted || hidden) "is-gone" else ""),
            div(class = "dsapp-forum-floor-head",
              # ⚠️ 拼成一个字符串再交给 span()。写成 `span(..., "#", label)`
              #    的话 htmltools 会在两个子节点之间塞**换行+缩进**，浏览器
              #    把那段空白折成一个空格 —— 取出来的文字是 `"# 1"` 而不是
              #    `"#1"`（复制楼层号也会带上那个空格）。
              span(class = "dsapp-forum-floor-no", paste0("#", label)),
              span(class = "dsapp-forum-author", p$author_name %||% "匿名"),
              span(class = "dsapp-forum-dot", "·"),
              span(dsapp_forum_ago(p$created_at)),
              if (hidden) span(class = "dsapp-forum-hidden", " · 已被管理员隐藏"),
              if (deleted) span(class = "dsapp-forum-hidden", " · 已删除")
            ),
            if (deleted || hidden) {
              div(class = "dsapp-forum-floor-gone", "（该回复已删除）")
            } else {
              tagList(
                div(class = "dsapp-preview-md dsapp-forum-floor-body",
                    HTML(dsapp_md_html(as.character(p$body %||% "")))),
                div(class = "dsapp-forum-floor-act",
                  act_btn(sprintf("有用 %d", as.integer(p$n_likes)),
                          if (isTRUE(as.integer(p$i_liked) == 1L)) "punlike" else "plike",
                          pk, ico = "thumbs-up", cls = "dsapp-forum-mini"),
                  if (!identical(st, "closed"))
                    act_btn("回复", "reply", paste0(key, "|", pk),
                            ico = "reply", cls = "dsapp-forum-mini"),
                  if (dsapp_forum_can_edit(p$author_email, a$email, is_admin()))
                    act_btn("删除", "pdel", pk, ico = "trash",
                            cls = "dsapp-forum-mini dsapp-forum-mini-danger"),
                  if (is_admin() && !hidden)
                    act_btn("隐藏", "phide", pk, ico = "eye-slash",
                            cls = "dsapp-forum-mini")
                )
              )
            }
          )
        })
      }

      # ---- 回复框 ----
      composer <- if (identical(st, "closed")) {
        div(class = "dsapp-forum-closed-note", icon("lock"),
            " 这条帖子已关闭，不再接受新回复。")
      } else {
        div(class = "dsapp-forum-composer",
          if (!is.null(replying_to())) {
            div(class = "dsapp-forum-replying",
              icon("reply"), " 正在回复 ", tags$b(replying_to()$name),
              actionButton(ns("cancel_reply"), "取消",
                           class = "btn btn-sm btn-link"))
          },
          textAreaInput(ns("reply_body"), NULL, value = isolate(draft()), rows = 4,
                        placeholder = "写点什么…（支持 Markdown；代码块用三个反引号）"),
          div(class = "dsapp-forum-composer-act",
            actionButton(ns("reply_send"), tagList(icon("paper-plane"), " 回复"),
                         class = "btn btn-primary btn-sm"))
        )
      }

      tagList(head, actbar, body,
              div(class = "dsapp-forum-floor-sep",
                  sprintf("%d 条回复", as.integer(n))),
              div(class = "dsapp-forum-floors", floors),
              composer)
    }

    # 正在回复哪一层（list(kind, key, name)）；NULL = 回复帖子本身
    replying_to <- reactiveVal(NULL)

    # 回复框里的草稿。
    # ⚠️ 为什么需要它：详情视图现在会跟着 bump() 整棵重画（上面那段），
    #    而 renderUI 重画时 textAreaInput 取的是**参数里那个 value**，用户
    #    正在打的字只存在于 DOM 里 —— 不打草稿的话，"读到一半顺手点个有用"
    #    就能把人家写了一半的回复抹掉。
    # ⚠️ 读它的时候必须 `isolate()`。不 isolate 的话每敲一个字都会把
    #    output$body 失效一次 → 整棵子树重画 → 焦点和光标每敲一下丢一次，
    #    比原来的毛病还难受。isolate 之后草稿只在"下一次因为别的原因重画"
    #    时被带上。
    draft <- reactiveVal("")
    observeEvent(input$reply_body, draft(input$reply_body %||% ""),
                 ignoreNULL = FALSE)

    #' 一个动作按钮
    #'
    #' ⚠️ 走共用 input（见文件头第 2 条）。`priority:'event'` 不能省 ——
    #    同一行的按钮连点两次时，值一样的话 Shiny 默认**不触发**
    #    （它按值去重），表现是"点第二次没反应"。
    act_btn <- function(label, act, arg, ico = NULL, cls = "") {
      js <- sprintf(paste0("event.stopPropagation();",
                           "Shiny.setInputValue(%s,%s,{priority:'event'});",
                           "return false;"),
                    jsonlite::toJSON(ns("act"), auto_unbox = TRUE),
                    jsonlite::toJSON(paste0(act, "|", arg), auto_unbox = TRUE))
      tags$a(href = "#", class = paste("dsapp-forum-btn", cls), onclick = js,
             if (!is.null(ico)) icon(ico), " ", label)
    }

    output$body <- renderUI({
      if (is.null(cur())) list_view() else detail_view()
    })

    # 打开一条帖子时把浏览 +1
    #
    # ⚠️ 放在 observer 里而不是 renderUI 里：renderUI 一帧可能跑多次
    #    （自动刷新、窗口变化都会重画），每次都 +1 的话浏览量会**凭空翻几倍**，
    #    而且它是个写库操作，放在渲染路径上还可能和别的写撞在一起。
    observeEvent(cur(), {
      key <- cur()
      if (is.null(key)) return()
      kk <- dsapp_forum_unkey(key)
      dsapp_forum_view(kk[["node"]], kk[["id"]], con = con())
      replying_to(NULL)
      # ⚠️ 草稿也要清 —— 不清的话在 A 帖里写了一半、退出去点开 B 帖，
      #    那半句会跟着搬过去（它现在挂在模块级的 reactiveVal 上）。
      draft("")
      # ⚠️ 不要在这里 bump() —— 那会让"打开详情"触发一次列表重查，
      #    而浏览量的变化**故意不进 updated_at**（R/forum.R §四），
      #    列表上的那个数字本来就不会变。多查一次只是白费。
    }, ignoreNULL = TRUE)

    # ---- 返回 / 刷新 ------------------------------------------------------
    observeEvent(input$back,  cur(NULL))
    observeEvent(input$back0, cur(NULL))
    observeEvent(input$refresh, bump(bump() + 1L))
    observeEvent(input$cancel_reply, replying_to(NULL))

    # ---- 发帖 -------------------------------------------------------------
    new_modal <- function() {
      modalDialog(
        title = tagList(icon("pen-to-square"), " 发新帖"),
        textInput(ns("new_title"), "标题", value = "",
                  placeholder = "一句话说清：什么情况下、出了什么错"),
        selectInput(ns("new_cat"), "板块",
                    choices = dsapp_forum_cat_choices(is_admin()),
                    selected = "share"),
        textInput(ns("new_tags"), "标签（可选，逗号分隔，最多 6 个）", value = "",
                  placeholder = "报错,R语言,环境"),
        textAreaInput(ns("new_body"), "正文（支持 Markdown）", value = "", rows = 10,
                      placeholder = "背景 / 复现步骤 / 报错原文 / 你试过什么"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("new_save"), "发布", class = "btn btn-primary")
        ),
        easyClose = TRUE, size = "l"
      )
    }
    observeEvent(input$new,  showModal(new_modal()))
    observeEvent(input$new2, showModal(new_modal()))

    observeEvent(input$new_save, {
      r <- dsapp_forum_thread_new(
        title = input$new_title, body = input$new_body,
        category = input$new_cat, tags = input$new_tags,
        user = user(), is_admin = is_admin(), cfg = cfg(), con = con())
      if (isTRUE(r$ok)) {
        removeModal()
        # 回到列表并刷新 —— 发完还停在原地的话，用户看不到自己那条，
        # 第一反应是"没发出去"。
        cur(NULL)
        bump(bump() + 1L)
        showNotification("已发布", type = "message", duration = 3)
      } else {
        showNotification(r$msg %||% "发布失败", type = "warning", duration = 6)
      }
    })

    # ---- 回复 -------------------------------------------------------------
    observeEvent(input$reply_send, {
      key <- cur()
      if (is.null(key)) return()
      kk <- dsapp_forum_unkey(key)
      rt <- replying_to()
      r <- dsapp_forum_post_new(
        thread_onode = kk[["node"]], thread_oid = kk[["id"]],
        body = input$reply_body,
        reply_to_onode = if (is.null(rt)) "" else rt$node,
        reply_to_oid   = if (is.null(rt)) "" else rt$id,
        user = user(), cfg = cfg(), con = con())
      if (isTRUE(r$ok)) {
        # ⚠️ 顺序要紧：先清草稿再 bump()。反过来的话重画读到的还是那份旧
        #    草稿（`isolate(draft())`），刚发出去的那句话会被原样贴回输入框。
        draft("")
        updateTextAreaInput(session, "reply_body", value = "")
        replying_to(NULL)
        bump(bump() + 1L)
        showNotification("已回复", type = "message", duration = 3)
      } else {
        showNotification(r$msg %||% "回复失败", type = "warning", duration = 6)
      }
    })

    # ---- 一个 observer 分派所有行内动作 ------------------------------------
    #
    # ⚠️ 值的形状是 `动作|参数`，参数里自己可能带 `|`（回复按钮是
    #    `回复|帖子key|回复key`）。所以切分用**第一个** `|`，剩下的原样
    #    留给各自的解析 —— 按全部 `|` 切再拼回去的写法在参数含 `|` 时
    #    会把它吃掉，而那几个按钮正好是能用的（key 里不会有 `|`，但别赌）。
    observeEvent(input$act, {
      v <- as.character(input$act %||% "")
      if (!nzchar(v)) return()
      cut <- regexpr("|", v, fixed = TRUE)
      if (cut < 1) return()
      act <- substr(v, 1, cut - 1L)
      arg <- substr(v, cut + 1L, nchar(v))
      u <- user(); a <- dsapp_forum_author(u)

      # 两层参数的动作：回复某一层、删/隐藏某一层
      split2 <- function(x) {
        c2 <- regexpr("|", x, fixed = TRUE)
        if (c2 < 1) return(c(x, ""))
        c(substr(x, 1, c2 - 1L), substr(x, c2 + 1L, nchar(x)))
      }

      if (identical(act, "open")) {
        cur(arg)
        return()
      }
      # 帖子级：arg 就是帖子 key
      kk <- dsapp_forum_unkey(arg)
      if (!nzchar(kk[["node"]])) return()

      if (identical(act, "like") || identical(act, "unlike")) {
        said(dsapp_forum_mark("thread", kk[["node"]], kk[["id"]],
                              on = identical(act, "like"), user = u, con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "solved")) {
        said(dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "solved",
                                       user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "reopen")) {
        said(dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "open",
                                       user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "close")) {
        said(dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "closed",
                                       user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "hide")) {
        said(dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "hidden",
                                       user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "unhide")) {
        said(dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "open",
                                       user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "pin")) {
        said(dsapp_forum_thread_pin(kk[["node"]], kk[["id"]], TRUE,
                                    is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "unpin")) {
        said(dsapp_forum_thread_pin(kk[["node"]], kk[["id"]], FALSE,
                                    is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "del")) {
        # ★ 要删哪一条记在 pending_del 里，**不是**从 cur() 现读：弹窗弹出来
        #   之后用户可以先去别处、甚至点开另一条帖子，确认时再读 cur()
        #   删掉的就是**另一条**了。这类 bug 只在"手快"的时候出现，
        #   测试里几乎撞不上。
        pending_del(arg)
        showModal(modalDialog(
          title = "删除这条帖子？",
          "删掉之后不能恢复，而且所有用户都看不到了（包括已经同步出去的那份）。",
          footer = tagList(modalButton("算了"),
            actionButton(ns("del_yes"), "确认删除", class = "btn btn-danger")),
          # ⚠️ 破坏性动作**不用** easyClose：点一下旁边就关掉的话，
          #    "我明明点了删除"和"我点歪了"这两种情况用户分不出来。
          easyClose = FALSE))
      } else if (identical(act, "edit")) {
        th <- dsapp_forum_thread(kk[["node"]], kk[["id"]], con = con())
        if (is.null(th)) return()
        showModal(modalDialog(
          title = tagList(icon("pen"), " 编辑帖子"),
          textInput(ns("edit_title"), "标题", value = as.character(th$title %||% "")),
          selectInput(ns("edit_cat"), "板块",
                      choices = dsapp_forum_cat_choices(is_admin()),
                      selected = as.character(th$category %||% "share")),
          textInput(ns("edit_tags"), "标签", value = as.character(th$tags %||% "")),
          textAreaInput(ns("edit_body"), "正文", rows = 10,
                        value = as.character(th$body %||% "")),
          footer = tagList(modalButton("取消"),
            actionButton(ns("edit_save"), "保存", class = "btn btn-primary")),
          easyClose = TRUE, size = "l"))
      } else if (identical(act, "reply")) {
        # arg = "帖子key|回复key"
        sp <- split2(arg)
        rk <- dsapp_forum_unkey(sp[2])
        nm <- ""
        if (nzchar(rk[["node"]])) {
          pr <- tryCatch(DBI::dbGetQuery(con(),
            "SELECT author_name FROM forum_posts
              WHERE origin_node = ? AND origin_id = ?",
            params = list(rk[["node"]], rk[["id"]])), error = function(e) NULL)
          if (!is.null(pr) && nrow(pr)) nm <- as.character(pr$author_name[1])
        }
        replying_to(list(node = rk[["node"]], id = rk[["id"]], name = nm))
      } else if (identical(act, "plike") || identical(act, "punlike")) {
        said(dsapp_forum_mark("post", kk[["node"]], kk[["id"]],
                              on = identical(act, "plike"), user = u, con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "pdel")) {
        said(dsapp_forum_post_status(kk[["node"]], kk[["id"]], "deleted",
                                     user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      } else if (identical(act, "phide")) {
        said(dsapp_forum_post_status(kk[["node"]], kk[["id"]], "hidden",
                                     user = u, is_admin = is_admin(), con = con()))
        bump(bump() + 1L)
      }
    })

    # 删除确认。`pending_del` 由上面 `del` 那一支写入（理由见那里）。
    pending_del <- reactiveVal(NULL)
    observeEvent(input$del_yes, {
      key <- pending_del()
      if (is.null(key)) return()
      kk <- dsapp_forum_unkey(key)
      r <- dsapp_forum_thread_status(kk[["node"]], kk[["id"]], "deleted",
                                     user = user(), is_admin = is_admin(),
                                     con = con())
      removeModal()
      pending_del(NULL)
      if (isTRUE(r$ok)) { cur(NULL); bump(bump() + 1L); showNotification("已删除", type = "message") }
      else showNotification(r$msg %||% "删除失败", type = "warning", duration = 6)
    })

    observeEvent(input$edit_save, {
      key <- cur()
      if (is.null(key)) return()
      kk <- dsapp_forum_unkey(key)
      r <- dsapp_forum_thread_edit(
        kk[["node"]], kk[["id"]],
        title = input$edit_title, body = input$edit_body,
        category = input$edit_cat, tags = input$edit_tags,
        user = user(), is_admin = is_admin(), con = con())
      if (isTRUE(r$ok)) {
        removeModal(); bump(bump() + 1L)
        showNotification("已保存", type = "message", duration = 3)
      } else {
        showNotification(r$msg %||% "保存失败", type = "warning", duration = 6)
      }
    })
  })
}
