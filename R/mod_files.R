# =============================================================================
# 文件页
# =============================================================================
# 文件管理区，所有用户可见。上传的文件存为只读（0444）—— 因为执行时会以
# 软链挂进任务工作目录，可写的话一条 write.csv(df, "同名文件") 就能把
# 原始数据覆盖掉（详见 executor.R 的说明）。
#
# ---- 关于上传入口（V3 重做）--------------------------------------------------
#
# V2 里上传是能用的，但用的是 Shiny 默认渲染：
#
#     <span class="btn btn-default btn-file">选择文件<input type=file .../></span>
#
# 而 bslib/flatly 没给 .btn-default 任何定义，只有个 BS3 兼容 shim 把它
# 映射成灰色；同时 .btn-file 在 bootstrap.min.css 里一条规则都没有，
# 在 shiny-sass.css 里也只有 border-radius。结果是它渲染成一个不起眼的
# 灰色小块，紧挨着一个蓝色的「下载」按钮 —— 视觉上完全不像上传入口，
# 用户会直接认为"只有下载没有上传"。
#
# 所以这里做了三件事：
#   1. buttonLabel 传成带图标的 tagList，并且 CSS 把 .btn-file 提升成主按钮
#   2. 外面包一个虚线拖拽区（拖进来也能传，app.js 里做 files 转移）
#   3. 上传中/成功/失败都在同一处给明确文字反馈，不再只弹一个 toast
# =============================================================================

# 「移动到共享区根目录」在下拉框里的哨兵值。
#
# 根目录对应的目标路径是**空串**，而空串已经被「（不移动）」占住了，所以这里
# 用 "/" 当哨兵，do_move 里再换回空串。
#
# 为什么偏偏是 "/"：它必须是一个**绝不可能**从 dsapp_shared_dirs 出来的值
# （那个函数返回相对路径，开头的分隔符会被剥掉），否则下拉框里会出现两个
# 值相同的选项。而且万一它漏进了 dsapp_rel_segments，会被当成绝对路径当场
# 拒掉 —— 失败的方向是安全的。
DSAPP_MOVE_ROOT <- "/"

mod_files_ui <- function(id) {
  ns <- NS(id)

  tagList(
    # 存储配额条。没设配额时**整块不出现** —— 不限的人看到一个条只会
    # 以为自己也在被计量（见 dsapp_quota_bar 的说明）。
    uiOutput(ns("quota_bar")),

    # 文件管理区在**最上面**（V7 item 11）。它以前叫「文件管理区」、被压在
    # 对话产物下面，用户的原话是「文件管理区就叫文件管理区，应该显示在最
    # 上面」—— 这一页的主语是文件，产物那块是附带的。
    # ★ V14 item 1：这一页原来是一句 `layout_columns(col_widths = c(5, 7))`。
    #
    #   用户原话：「文件管理区和预览之间应该可以拖动改变大小」。
    #   c(5,7) 是 bslib 按 12 栅格算的**百分比**（41.7% / 58.3%），谁也改不了；
    #   而"文件管理区"和"预览"谁该更宽，恰恰是最因人而异的一件事 ——
    #   文件名长的要宽列表，看报告的要宽预览。
    #
    #   换成和对话页/任务页**同一套**东西：一列定宽（`--dsapp-filespage-w`）、
    #   一条分隔条、右边那列吃满。分隔条、拖动、双击回默认、键盘微调全部由
    #   www/app.js 里那份通用引擎提供，这里只负责给出**结构**和那个
    #   `data-dsapp-panel`。
    #
    # ⚠️ 三件事必须同时对，少一件就是"拖了没反应"：
    #     1. 外层要有 .dsapp-files-page（app.js 的 clampFilesPage 按它的宽度
    #        算上限）；
    #     2. 定宽的那一列要有 .dsapp-files-list（app.js 的 current() 量它的
    #        实际宽度当作拖动的起点，量不到就退回默认值 —— 表现是第一次拖动
    #        会跳一下）；
    #     3. 分隔条的 id 结尾必须是 split_ + [vhstmf] 里的一个字母（这里是
    #        `f`），app.js 靠 el.id.replace(/split_[vhstmf]$/, "panel_size")
    #        推 input 名。推不出来就**一声不响**地不上报，控制台干干净净。
    #
    # ⚠️⚠️ 这个量叫 `filespage_w`，**不是** `files_w`。`files_w` 是「言出法随」
    #    那一页右边的产物栏，app.js 的 current() 里量的是 `.dsapp-files-col`；
    #    两者复用同一个键的话，在文件页拖动会去量对话页那一列 —— 那一页此
    #    刻是隐藏的，量出来是 0，于是分隔条一碰就跳到最小值、而且存进库里的
    #    宽度把对话页也改了。两个页面、两条分隔条、两个变量。
    #
    # ⚠️ `.dsapp-files-list` / `.dsapp-files-prev` 上那些 min-width: 0 由
    #    CSS 给（见 www/app.css）：flex 子项的默认 min-width 是 auto = 内容
    #    宽度，而两边都有很宽的东西（文件名列、报告里的代码块），不写这一句
    #    整页会横向溢出。
    div(
    class = "dsapp-files-page",

    div(
    class = "dsapp-files-list",

    card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        span(icon("folder-tree"), " 文件管理区"),
        # ★ V13 item 6：这句原来写的是「所有人可见」。它现在是**反的** ——
        # 管理区按账号隔离了，写"所有人可见"会让用户以为传上去别人看得见，
        # 于是不敢放真数据；而实际是只有他自己。界面上的话必须跟着权限走，
        # 说反了比不说更糟。
        div(class = "d-flex align-items-center gap-2",
          span(class = "small text-muted fw-normal",
               "仅自己可见 · 上传后会自动进入本账号对话的知识范围"),
          # 「导入对话产物」（V13 item 2）。
          #
          # 给的是**手动重跑**的入口：自动补一次只在打开本页时跑一遍
          # （见下面的 backfill observer），而用户可能刚好在那个时刻之前
          # 就把页面开着了；也可能他刚在对话里跑完东西、想立刻看到。
          # 一个能自己按的按钮比"等下一次"可靠得多。
          # ★ V16.9：这个按钮改由 renderUI 画（`output$import_ws_ui`），因为
          #   补齐跑在**后台子进程**里、分钟级，得能显示"正在补齐…"并把按钮
          #   禁掉。⚠️ 下面 UI 函数里那个 uiOutput 只是在**占位** —— 按钮本身
          #   连同它的 onclick 现在在 server 那一侧的 renderUI 里，两处别只改
          #   一处（改了这里没改那里 = 点下去一声不响，因为 input 名对不上）。
          uiOutput(ns("import_ws_ui")),
          # 刷新按钮（V9 item 3）。
          #
          # ⚠️ 这一块**没有**定时轮询（见下面 refresh 的定义：共享区只由本页
          #    的操作驱动）。可它确实会被本页之外的东西改动 —— 对话页的
          #    「发布」就是往这里写，另开一个标签页、或者另一个账号上传也
          #    一样。以前遇到这种情况只有一个办法：刷新整个浏览器页面，
          #    而那会把对话、滚动位置、勾选状态全丢掉。用户要的就是这个
          #    按钮。
          #
          # py-0 + lh-1：卡片头是定高的，按钮用默认行高会把 header 撑高
          # 一格，整页跟着往下挪（V8 item 6 那 47px 的教训）。
          tags$button(
            class = "btn btn-sm btn-outline-secondary py-0 px-2",
            type = "button",
            title = "重新读取文件列表",
            onclick = sprintf(
              "Shiny.setInputValue(%s, Math.random(), {priority:'event'});",
              dsapp_js_str(ns("refresh_tbl"))),
            icon("rotate"))
        )
      ),
      # ★ V13.2 item 14：`fillable = FALSE`。
      #
      # 理由和 mod_tasks.R / mod_admin.R 里那两处是**同一条**（见那里的长注释）：
      # bslib 的 `card_body()` 默认 `fillable = TRUE`，卡体于是成了 flex 列，
      # DT 拿到的 `.html-fill-item` 让它 `flex: 1 1 auto`，而 DT 自己还有一条
      # `.html-fill-container > .html-fill-item.datatables { flex-basis: 400px }`
      # —— **表格空着的时候也是 400 像素高**。
      #
      # 这一张卡上，那 400 像素正好夹在"文件管理区"面包屑和它下面的东西之间：
      # 用户打开一个空目录，看到的是面包屑底下一大片空白，然后是上传区。
      # （顺带，它也是 item 14 那两百多像素里的一部分。）
      #
      # 关掉之后表格按内容长：空目录 60 来像素，有文件时按行数长，
      # 长过一屏就由外面那层 `.dsapp-main-body` 滚（`overflow-y: auto`）。
      card_body(
        fillable = FALSE,
        # ---- 面包屑 ----
        # 共享区有子目录之后，"我在哪一层"必须一直显示着。上传、新建文件夹、
        # 解压去向都跟着它走，藏起来的话用户会在根目录里找自己刚传进
        # 子目录的文件。
        uiOutput(ns("crumb")),

        # ---- 文件表 ----------------------------------------------------------
        # ★ V13.2 item 14：表格**直接跟在面包屑后面**。
        #
        #   用户原话：「文件管理区的"名称"、"大小"、"修改时间"那些信息应该
        #   直接显示在"house 文件管理区"那一条的下面」。
        #
        #   原来表格上面压着拖拽上传区（一个大虚线框）+ 两行说明 + hr，
        #   合计两百多像素，于是"我在哪一层"和"这一层里有什么"得滚动才能
        #   对上 —— 而这两件事本来是同一件事的两半。上传区整个搬到了表格
        #   **下面**，见后面那一段。
        #
        #   ⚠️ 拖拽上传**不受影响**：app.js 的 drop 监听挂在 `.dsapp-dropzone`
        #      上（文档级监听 + closest），跟着元素一起搬，不看位置。
        # ★ V13.5 item 3：外面这层是给「每行不换行 + 过宽就横向滚」用的。
        #   和任务页那条**同一套**（.dsapp-dt-nowrap + autoWidth = FALSE）。
        div(class = "dsapp-dt-nowrap", DT::dataTableOutput(ns("tbl"))),
        # 工具栏是**动态**的（V7 item 9）：按钮上的字要跟着勾选的数量变
        # （「下载选中」/「打包下载（3 项）」），否则用户勾了三行点下载，
        # 拿到一个文件也不知道是坏了还是自己勾错了。
        uiOutput(ns("tbl_tools")),

        # ---- 拖拽 / 点击上传区（表格下面）------------------------------------
        hr(class = "my-3"),
        # 上传进度紧挨着上传区，不留在上面 —— 传完一个文件之后目光就在这一块，
        # 进度条跑到表格顶上（隔着十几行文件）等于没有。
        uiOutput(ns("upload_status")),
        div(
          # ★ `dsapp-dropzone-slim`：搬下来之后那个大虚线框会在卡片底部撑出
          #   一大块空白，而这会儿它是"次要入口"（主入口是表格上面那排工具
          #   按钮和直接拖进这一块）。压成一条横向的窄带，保持拖拽目标可见，
          #   但不跟文件列表抢版面。
          class = "dsapp-dropzone dsapp-dropzone-slim",
          id = ns("dropzone"),
          div(class = "dsapp-dropzone-row",
            div(class = "dsapp-dropzone-icon", icon("cloud-arrow-up")),
            div(class = "dsapp-dropzone-slim-text",
              div(class = "dsapp-dropzone-title",
                  textOutput(ns("drop_title"), inline = TRUE)),
              # ⚠️ 原来这里写的是「也可以直接拖进文件夹行」—— **没有这回事**。
              #    app.js 里唯一的 drop 监听挂在 .dsapp-dropzone 上，拖到某一行
              #    文件夹上是不会触发上传的（文件会当成"拖到页面空白处"被浏览器
              #    打开）。一句话指了一条不存在的路，比不说更坏，所以改成
              #    "拖到这一块"。
              div(class = "dsapp-dropzone-sub",
                  "或者点右边的按钮选择文件 / 文件夹")
            ),
            div(class = "dsapp-dropzone-input",
              fileInput(ns("upload"), NULL, multiple = TRUE,
                        buttonLabel = tagList(icon("upload"), " 上传文件"),
                        placeholder = "尚未选择文件",
                        width = "100%"),
              # V9 item 12：文件夹上传。
              # ⚠️ 外层的 .dsapp-dirupload 和 data-paths-input 是**功能性的**，
              #    不是样式钩子：www/app.js 靠它们给里面的 input 加
              #    webkitdirectory，并把每个文件的相对路径报回
              #    input$upload_dir_paths（Shiny 服务端会把目录成分丢掉，
              #    详见 dsapp_file_save 的 rel 参数说明）。改类名会静默失效。
              #
              # ⚠️ 顺序也不能动：app.js 的 drop 处理器取的是
              #    `zone.querySelector('input[type="file"]')` —— 第一个。把
              #    文件夹那个挪到前面，拖进来的单文件就会走 webkitdirectory
              #    那条路。
              div(class = "dsapp-dirupload",
                  `data-paths-input` = ns("upload_dir_paths"),
                  fileInput(ns("upload_dir"), NULL, multiple = TRUE,
                            buttonLabel = tagList(icon("folder-tree"), " 上传文件夹"),
                            placeholder = "尚未选择文件夹",
                            width = "100%"))
            )
          ),
          helpText(class = "small text-muted mb-0 mt-2",
                   sprintf("单个文件上限 %s。文件夹会按原来的层级存进当前所在的那一层。",
                           dsapp_fmt_bytes(cfg_upload_max())),
                   tags$br(),
                   "空文件夹不会被选中：浏览器只上报文件，不上报空目录。")
        )
      )
    )
    ),

    # 竖分隔条。结构和对话页/任务页那条**一模一样**（www/app.css 的
    # .dsapp-split-v），区别只有两点：id 结尾的字母（f）和 data-dsapp-panel
    # 指的量（filespage_w）。
    #
    # ⚠️ tabindex 是给键盘用户的：焦点落上去之后左右方向键各微调 10px
    #    （见 app.js 的 keydown 分支）。少了它这条分隔条用键盘够不着。
    tags$div(
      class = "dsapp-split-v",
      id = ns("split_f"),
      `data-dsapp-panel` = "filespage_w",
      tabindex = "0", role = "separator",
      `aria-label` = "拖动调整文件管理区的宽度",
      title = "拖动调整宽度（双击恢复默认）"
    ),

    div(
    class = "dsapp-files-prev",

    card(
      card_header(textOutput(ns("preview_title"), inline = TRUE)),
      card_body(class = "p-2", uiOutput(ns("preview")))
    )
    )
    ),

    # 对话产物。只在当前有对话时出现 —— 没有对话就没有工作区，
    # 这块区域整个不存在，而不是显示一个空壳。
    uiOutput(ns("ws_card"))
  )
}

#' 上传上限（字节），仅用于界面提示
cfg_upload_max <- function() {
  dsapp_config()$max_upload_mb * 1024^2
}

mod_files_server <- function(id, state, active = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    # ★★ V13 item 6：**这一个账号的**管理区（data/files/u<N>）。
    #
    # 整页几十处用的都是 `cfg$files_dir`，绑到账号上之后它们自动全部正确 ——
    # 这正是当初把根路径放进 cfg 而不是散在各处的意义。反过来说：这个模块里
    # **任何**绕过 cfg 直接拼 data/files/... 的写法都会绕开隔离，别那么写。
    #
    # ⚠️ state$user_id 在登录完成前是 NULL，那时给的是 _anon（空目录）。
    #    这一页在没登录时本来也不渲染（app.R 的闸门挡着），所以拿到空目录
    #    也无所谓；但**不要**写成 dsapp_config()，那等于隔离没做。
    #
    # ⚠️⚠️ `cfg` 是**函数**，不是值 —— 用的时候写 `cfg()`。
    #
    #    模块的 server 是在**登录之前**就注册好的（app.R 无条件调
    #    mod_files_server），那一刻 state$user_id 还不存在。直接在模块开头
    #    求值读它，reactiveValues 会抛
    #        Can't access reactive value 'user_id' outside of reactive consumer
    #    而这是模块初始化路上抛的 —— 整个应用从第一秒起就起不来，浏览器上
    #    只有一句"与服务器的连接断了"（2026-09-16 测试实例上就是这么挂的）。
    #
    #    所以每次用的时候现算。代价可以忽略：dsapp_config() 本来就不缓存，
    #    每次调用只是拼一遍路径字符串；真正贵的那步 dsapp_db() 有连接缓存
    #    兜着。反过来，读 state$user_id 还**顺带建立了响应式依赖** ——
    #    换账号时用到 cfg() 的那些 render 会自己重算。
    #
    # ⚠️ 别再把它改回一个值。"在模块开头取一次 cfg" 看着更省，实际是把
    #    _anon（所有人共用的那个空目录）在登录前固化下来，而且不报任何错：
    #    用户看到的是"我的文件不见了"，最坏的情况是**看到别人的文件**。
    cfg <- function() dsapp_config_user(state$user_id, dsapp_config())
    # 目录按需建：第一个用到它的账号（通常是注册后第一次打开文件页）要有地方落。
    #
    # ⚠️⚠️ 这里**必须是**一个 observer。原来那行是直接调的：
    #
    #        try(dsapp_files_ensure(state$user_id, cfg()), silent = TRUE)
    #
    #    而这一行在 moduleServer 的函数体里、**不在响应式上下文里** ——
    #    上面那段注释刚说完这件事（`cfg` 正是因为这件事才写成了函数），
    #    结果下一行就把 `cfg()` 直接求值了：里面那句 `state$user_id` 抛
    #        Can't access reactive value 'user_id' outside of reactive consumer
    #    抛出来正好被 `try(silent = TRUE)` **吞掉** —— 不报错、也不建目录。
    #    换句话说：这一行从写下来那天起就没生效过，而它看起来非常正常。
    #
    #    后果不是"少一个目录"这么轻：注册流程**不会**建 data/files/u<N>/
    #    （V13 item 6 那次迁移建出来的是 u1，别的账号一个都没有），于是新账号
    #    第一次上传时，Shiny 只写一句 R 的 Warning
    #        cannot create file '.../files/u37/x.txt', reason 'No such file...'
    #    **服务端不报错、浏览器上还写着 "Upload complete"**，用户看到的是
    #    "传完了，但文件管理区里没有" —— 文件是真的丢了（Shiny 那份临时文件
    #    随后就被清掉）。
    #    2026-09-17 在测试实例上量到：新注册的账号连传三次，`data/files/`
    #    下一个目录都没多出来，file_owner 里一条记录都没有。
    #
    #    ignoreNULL 留着：登录前 state$user_id 是 NULL，那时不该去建 _anon。
    #    换账号（登出再登入）时 user_id 会变，这个 observer 自己会再跑一次。
    observeEvent(state$user_id, {
      if (is.null(state$user_id)) return()
      try(dsapp_files_ensure(state$user_id, cfg()), silent = TRUE)
    }, ignoreNULL = TRUE)

    # 文件列表变化的触发器。上传/删除/重命名后 bump 一下，列表重新读盘。
    # 不用 reactivePoll 是因为没有外部进程会改这个目录，
    # 由本页面自己的操作驱动就够了。
    refresh <- reactiveVal(0)

    # 卡片头上那个刷新按钮（V9 item 3）。上面那句"没有外部进程会改这个
    # 目录"是相对的：改它的不是磁盘上的某个后台程序，但**可以是别的页面**
    #（对话页的「发布」就往这里写）—— 所以手动刷一下是必要的入口。
    observeEvent(input$refresh_tbl, {
      refresh(refresh() + 1)
      showNotification("已重新读取文件列表", type = "message", duration = 2)
    })

    # ★ V14 item 1：分隔条拖完（或键盘调完、双击回默认）报到服务端的那一下。
    #
    # ⚠️ 收的是 **`files-panel_size`**，不是顶层的 `panel_size` —— 上面那条
    #    分隔条的 id 是 ns("split_f")，长这样：`files-split_f`。app.js 的
    #    report() 做的是 `el.id.replace(/split_[vhstmf]$/, "panel_size")`，
    #    **命名空间前缀原样保留**，于是算出来就是带前缀的这个名字。
    #    收错名字的症状不是报错，是**拖完松手宽度弹回去**，控制台干干净净。
    #
    # ⚠️ ignoreNULL / ignoreInit 都要给上：`panel_size` 不是某个控件的值，
    #    是 app.js 用 Shiny.setInputValue 发的普通 input，初始化那一下是 NULL，
    #    不 ignore 的话会拿 NULL 去覆盖用户已经存好的尺寸。
    #
    # ⚠️ 只写报上来的那个键，其余沿用**库里现在的**值 —— dsapp_uipref_save()
    #    收的是一份完整偏好，少给一个键它会把那个键打回默认值（表现在用户
    #    那边就是"拖完文件管理区，对话页的产物栏宽度自己变回 320 了"）。
    observeEvent(input$panel_size, {
      p <- input$panel_size
      if (is.null(p) || !is.list(p)) return()
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      full <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg())),
                       error = function(e) dsapp_uipref_norm(NULL))
      if (!is.null(p$filespage_w)) full$filespage_w <- p$filespage_w
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg())), silent = TRUE)
      state$uipref_rev <- state$uipref_rev + 1L
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- 历史产物补同步（V13 item 2）------------------------------------------
    #
    # 用户原话：「比如 brca_result 这个文件夹，我在文件管理区就看不到」。
    #
    # 成因和判据见 files.R 的 dsapp_sync_backfill（一句话：自动同步是 V12 才
    # 有的，而且只在任务收尾那一刻跑；之前跑出来的产物一直躺在对话工作区里，
    # 用户一个都进不去）。
    #
    # ⚠️ 这里是**渲染路上的一次写盘**，所以三件事必须做到：
    #   1. 只跑一次（once）。跑第二遍虽然幂等（sync_dirs 有行就跳过），但
    #      每次打开这一页都去扫一遍所有对话的工作区，那是白等几秒。
    #   2. 整个包 tryCatch。补同步失败绝不能把文件页弄白屏。
    #   3. **异步**做不了的（Shiny 单线程），所以只在前几次真的有事可做时
    #      提示一句；没事可做就完全静默 —— 一个"已导入 0 个文件"的提示
    #      比不提示更让人困惑。
    backfilled <- reactiveVal(FALSE)
    run_backfill <- function(loud = FALSE) {
      r <- tryCatch(dsapp_sync_backfill(state$user_id, cfg()),
                    error = function(e) NULL)
      refresh(refresh() + 1)
      if (is.null(r)) {
        if (loud) showNotification("导入失败，稍后再试", type = "error")
        return(invisible(FALSE))
      }
      if (r$n_sessions > 0 || loud) {
        showNotification(
          if (r$n_sessions > 0)
            sprintf("已从 %d 个历史对话导入 %d 个产物", r$n_sessions, r$n_files)
          else "没有需要导入的产物（新产物本来就会自动同步）",
          type = "message", duration = 6)
      }
      invisible(TRUE)
    }
    # 自动那一次挂在**页签**上，不挂在模块初始化上（理由见 app.R 里 mod_files_server
    # 那一段）。`ignoreNULL = FALSE` 是必须的：会话刚起来时 input$nav 是 NULL，
    # 默认的 ignoreNULL = TRUE 会把这一次事件整个吞掉，之后页签从 NULL 变成
    # "chat" 时又会触发一次 —— 结果是我们永远等不到那个 "files"。
    observeEvent(if (is.null(active)) "files" else active(), {
      if (backfilled()) return()
      if (!is.null(active) && !identical(active(), "files")) return()
      backfilled(TRUE)
      run_backfill()
    }, ignoreNULL = FALSE)
    # ⚠️ 手动那个按钮的 observer 在这段**末尾**（它要调 run_repair，而那个
    #    函数定义在下面）。

    # ---- 手动补齐：跑在后台子进程里（V16.9）----------------------------------
    #
    # 为什么手动这条路**不能**复用上面的 run_backfill()：
    #
    # `dsapp_sync_backfill()` 的判据是 `sync_dirs` 表（有行就跳过），它只能补
    # 「从来没同步过的对话」。而撞上同步上限、被静默刷掉的那些文件，**恰恰
    # 都发生在已经同步过的对话上**（没同步过的对话根本走不到上限那一步）——
    # 于是 backfill 会精准地跳过每一个需要补的对话。用户看到的就是
    # 「点同步也没用」：点下去只弹一句「没有需要导入的产物」。
    #
    # `dsapp_sync_repair()` 换**盘**当判据（工作区真产物 − 管理区里此刻真在
    # 的那些），所以它补得回来。代价是它比 backfill 慢得多，而且真补起来
    # 可能是几个 G —— 那正好是当初设上限的原因：**跑在主进程里会把所有人的
    # 页面一起冻住**（一个应用一个 R 进程）。所以这里丢给 dsapp_bg_start()。
    #
    # ⚠️ 自动那一次（上面挂在页签上的 observer）**保持走 backfill 不变**：
    #    那是渲染路上的一次写盘，规矩见上面那三条（只跑一次 / 整段 tryCatch /
    #    没事就静默）。分工一句话：**自动走保守，手动走全量。**
    sync_job <- reactiveVal(NULL)   # 后台补齐的句柄；NULL = 没在跑

    # ⚠️⚠️ 子进程的错误原文**一律不上屏**。这条路上有三个来源，它们看着完全
    #     不像同一件事，其实都是同一句英文 `conditionMessage()`：
    #       · 起子进程就失败   → conditionMessage(h)
    #       · 子进程半路死掉   → dsapp_bg_poll() 的 r$msg（R/jobs.R:219 就是
    #                            `msg = conditionMessage(e)`）
    #       · 某个对话出错     → repair 结果的 v$errors（R/files.R:2495 也是
    #                            `sprintf("%s: %s", s, r$msg)`）
    #     它们是英文的、带服务器上的绝对路径和函数名，用户看不懂，也没有任何
    #     能做的动作 —— 贴到屏幕上只会让人以为是自己弄坏了什么，然后来问
    #     「什么是 cannot open file」。
    #
    #     所以：**原文进审计**（管理员在「日志」里查得到，那里才是它该在的
    #     地方），屏幕上只留一句人话 + 一个短代号，用户报障时报代号就能和
    #     日志里那一条对上。自检里那条 ★★★（R/ 里没有把 conditionMessage
    #     原文送到界面）钉的正是这件事 —— 我第一版就是直接把它拼进
    #     showNotification 的，被那条抓了个正着。
    #
    # ⚠️ 顺带记一笔那条自检的**盲区**：它按行扫「同一行里既有 conditionMessage
    #    又有落屏函数」，所以**转手的原文**（上面第 2、3 种）它扫不到 ——
    #    实测它只报了第 1 处，而另外两处一样是原文上屏。V16.9 那一节里因此
    #    另有一条专门钉 `$msg` / `$errors` 去向的断言。
    repair_fail_code <- function(stage, raw) {
      code <- format(Sys.time(), "SR%m%d%H%M%S")
      # audit() 是上面第 570 行那个本地包装（user / user_id / session 都带上）。
      # 它定义在后面，但 R 的函数体是**调用时**才解析自由变量，那时它早就
      # 存在了 —— 这里不会「找不到函数」。
      audit("sync_repair_failed", target = stage,
            detail = sprintf("[%s] %s", code,
                             paste(as.character(raw %||% ""), collapse = " ")),
            ok = FALSE)
      code
    }

    run_repair <- function() {
      # 已经在跑了就别再起一个 —— 两个子进程同时往同一个落点复制，会有一堆
      # `plot(1).png / plot(2).png` 那样的改名产物（dsapp_unique_path 只在
      # 发现"这不是我同步出去的"时才改名，两边同时看到同一个空位时都会改）。
      if (!is.null(sync_job())) {
        showNotification("正在补齐，稍等 —— 跑完会告诉你结果", type = "message",
                         duration = 4)
        return(invisible(FALSE))
      }
      # ⚠️ `cfg` 要**显式传进去**（和 mod_settings 那条同步 worker 一样）：
      #    子进程会从自己的 cwd 读 `.Renviron`，显式传一份能保证它和主进程
      #    用的是同一个 data_root。cfg 是个普通 list，能安全序列化 ——
      #    **绝不能**顺手把 `con`（S4 连接）也塞进 args，那跨不了进程。
      h <- tryCatch(
        dsapp_bg_start("dsapp_sync_repair",
                       args = list(user_id = as.integer(state$user_id),
                                   cfg = cfg()),
                       cfg = cfg(), tag = "syncrepair"),
        error = function(e) e)
      if (inherits(h, "error")) {
        code <- repair_fail_code("起子进程", conditionMessage(h))
        showNotification(
          sprintf("起不了补齐进程（%s），稍后再试；若一直如此，把这个代号发给管理员",
                  code),
          type = "error", duration = 12)
        return(invisible(FALSE))
      }
      sync_job(h)
      invisible(TRUE)
    }

    show_repair_result <- function(r) {
      refresh(refresh() + 1)
      if (is.null(r) || !isTRUE(r$ok)) {
        # ⚠️ 这里**最容易**顺手写成 `paste0("补齐失败：", r$msg)` —— 而 r$msg
        #    就是子进程的 conditionMessage 原文（R/jobs.R:219）。走审计。
        code <- repair_fail_code("子进程半路失败",
                                 r$msg %||% "子进程没有返回结果")
        showNotification(
          sprintf(paste0("补齐中途失败了（%s）—— 已经搬进去的那些不会回滚；",
                         "再点一次补齐，若一直如此把这个代号发给管理员"),
                  code),
          type = "error", duration = 12)
        return(invisible(FALSE))
      }
      v <- r$value %||% list()
      n <- as.integer(v$n_files %||% 0L)
      byt <- as.numeric(v$n_bytes %||% 0)
      # ⚠️ 三种结果要分得开，不能笼统报"完成"：
      #    · 补了东西 → 报数
      #    · 一个都没补，但有文件**正在被写**（recent）→ 说清"稍后再点一次"，
      #      否则用户会以为按钮坏了
      #    · 真的什么都不缺 → 明说，这就是以前那句「没有需要导入的产物」
      #      唯一**成立**的场合
      if (n > 0) {
        msg <- sprintf("已补齐 %d 个文件 · %s", n, dsapp_fmt_bytes(byt))
        if (length(v$blocked_files) > 0)
          msg <- paste0(msg, sprintf("；还有 %d 个没搬动，再点一次补齐",
                                     length(v$blocked_files)))
        showNotification(msg, type = "message", duration = 8)
      } else if (length(v$blocked_files) > 0) {
        # ⚠️ 这一支必须排在下面那个"什么都不缺"**前面**。一个都没搬进来、
        #    但确实有东西没搬成（逐个 file.copy 全失败、或者全被上限挡下），
        #    这时如果说「没有需要补齐的产物（都已经在管理区里了）」，那是
        #    在前一个 bug 上面再盖一个假话 —— 而用户刚点完按钮、正盯着看。
        showNotification(
          sprintf("有 %d 个产物没能搬进来（工作区里有、管理区里没有），请稍后再试；若一直如此请把这句话发给管理员",
                  length(v$blocked_files)),
          type = "warning", duration = 12)
      } else if (as.integer(v$recent %||% 0L) > 0) {
        showNotification(
          sprintf("有 %d 个文件刚被写过，怕复制到半截，这次跳过了 —— 稍后再点一次补齐",
                  as.integer(v$recent)),
          type = "message", duration = 8)
      } else if (length(v$errors) > 0) {
        # 同上：v$errors 每一项都是 "<会话>: <子进程 conditionMessage>"。
        code <- repair_fail_code("有对话出错",
                                 paste(unlist(v$errors), collapse = " | "))
        showNotification(
          sprintf(paste0("有 %d 个对话没补成功（%s）—— 其余的都补进去了；",
                         "把这个代号发给管理员"),
                  length(v$errors), code),
          type = "warning", duration = 12)
      } else {
        showNotification("没有需要补齐的产物（工作区里的文件都已经在管理区里）",
                         type = "message", duration = 6)
      }
      invisible(TRUE)
    }

    # 轮询子进程。形状和 mod_settings.R 里那条一模一样（读句柄 → 没完就继续
    # 定时 → 取完写 NULL）。
    #
    # ⚠️ 顶层这句 `sync_job()` **必须保持是普通读、不能套 isolate()** ——
    #    它就是这个 observer 唯一的启动条件（run_repair 里写 sync_job(h) 时
    #    靠这个依赖把它唤醒）。隔离掉的话它永远不会跑。
    # ⚠️ 写进去的是 NULL，所以下一轮第 2 行就 return，不会自失效失控 ——
    #    自检里那条扫「observe() 裸读自己写的 reactiveVal」的规则要豁免，
    #    标记写在下面这行（豁免要显式写出来，理由见自检里 v134e_exempt 的说明）。
    observe({
      # dsapp-selftest: self-reactive-ok sync_job
      h <- sync_job()
      if (is.null(h)) return()
      invalidateLater(1000)
      r <- tryCatch(dsapp_bg_poll(h), error = function(e) NULL)
      if (!isTRUE(r$done)) return()
      sync_job(NULL)
      show_repair_result(r)
    })

    # 手动那个按钮。放在最后：它要调的 run_repair 定义在上面。
    observeEvent(input$import_ws, { run_repair() }, ignoreNULL = TRUE)

    # 按钮本体的 renderUI（原来是个静态 tags$button，见 UI 里那段注释）。
    # ⚠️ 忙的时候**保留同一个 input id 的按钮**、只是加 disabled 属性，不是
    #    换成一段文字 —— 否则按钮会跳一下，而且失败之后得记得换回来。
    # ⚠️ onclick 那段必须和以前**逐字一致**（input 名对不上就是点了没反应，
    #    而且不报错）。
    output$import_ws_ui <- renderUI({
      busy <- !is.null(sync_job())
      tags$button(
        class = "btn btn-sm btn-outline-secondary py-0 px-2",
        type = "button",
        disabled = if (busy) NA else NULL,
        title = if (busy)
          "正在把工作区里还没进管理区的产物补进来"
        else
          paste0("把对话工作区里的产物补齐到这里",
                 "（含以前被同步上限漏掉的那些；",
                 "也会把你从管理区里删掉的产物带回来）"),
        onclick = if (busy) NULL else sprintf(
          "Shiny.setInputValue(%s, Math.random(), {priority:'event'});",
          dsapp_js_str(ns("import_ws"))),
        icon("file-import"),
        if (busy) " 正在补齐…" else " 导入对话产物")
    })

    # 当前所在的文件夹（相对共享区根目录，"" = 根）。
    # 上传、新建、移动都在这一层里发生 —— 它不是一个纯展示状态，
    # 是**写入坐标**，所以任何可能把它指向一个已消失目录的操作
    # 都要在 files() 里兜住（见下面的回落）。
    current_dir <- reactiveVal("")

    # 共享区是**所有人共用**的，所以这里的每个写操作都要留痕（见 R/audit.R）。
    # 尤其是"被拒绝"的那些：谁的账号在反复试删别人的文件，日志里看得见。
    #
    # ⚠️ 这条路**只记相对路径**，不记文件内容、不记大小 —— 日志是给管理员
    #    查"谁动了什么"用的，不是给他翻别人数据用的。
    audit <- function(action, target = "", detail = "", ok = TRUE) {
      # user 和 user_id 都传：user 那一行负责带出 email（账号以后被删掉时，
      # 日志里"是谁干的"这条线索就靠它），user_id 是主键。
      dsapp_audit(action, user = state$user, user_id = state$user_id,
                  target = target, detail = detail, ok = ok,
                  session = session, cfg = cfg())
    }

    files <- reactive({
      refresh()
      df <- dsapp_files_list(cfg(), current_dir())

      # 当前这一层没了（另一个标签页把它删了、或者管理员在服务器上动了
      # 共享区）。退回根目录，并如实说一句 —— 停在原地的话界面会变成
      # 一张空表，用户以为共享区里的东西全没了。
      if (nrow(df) == 0 && nzchar(current_dir())) {
        p <- dsapp_file_path(current_dir(), cfg(), must_exist = TRUE)
        if (is.null(p) || !dir.exists(p)) {
          current_dir("")
          df <- dsapp_files_list(cfg(), "")
        }
      }
      if (nrow(df) == 0) return(df)

      # 归属是旁挂的（见 users.R）。这里一次查出全部再匹配 —— 逐行查
      # 就是 N 次数据库往返，共享区上百个文件时列表会明显卡顿。
      #
      # ⚠️ 匹配键是 `rel`（相对路径）不是 `name`（这一层的名字）：
      #    file_owner.name 存的是相对路径（见 users.R），拿 basename 去匹配
      #    的话，子目录里的文件会全部显示成"公共" —— 而"公共"意味着人人都
      #    能删。这是权限显示，不能错。
      #
      # ⚠️★ 而且现在还要**去掉账号前缀**：V13 item 6 起 file_owner.name 是
      #    `u3/16S分析/asv_table.csv` 这种形状（前缀的理由见 users.R 的
      #    dsapp_owner_key），而 df$rel 是 `16S分析/asv_table.csv`。不去前缀
      #    的话 match() 全部落空，界面上**每一个**文件都显示「公共」——
      #    比改之前更糟，而且看不出是 bug（"公共"本来就是个合法值）。
      own <- tryCatch(
        DBI::dbGetQuery(dsapp_db(cfg()),
          "SELECT f.name, u.nickname FROM file_owner f
           LEFT JOIN users u ON u.id = f.user_id
           WHERE f.name LIKE ?",
          params = list(paste0(dsapp_owner_key("", state$user_id), "%"))),
        error = function(e) NULL)
      own_rel <- if (is.null(own)) character(0)
                 else substring(own$name, nchar(dsapp_owner_key("", state$user_id)) + 1L)
      df$owner <- if (is.null(own)) "公共"
                  else ifelse(is.na(own$nickname[match(df$rel, own_rel)]),
                              "公共", own$nickname[match(df$rel, own_rel)])
      # 目录的归属单独判：file_owner 只登记**文件**（见 dsapp_files_sync_owners），
      # 目录行永远是"公共"。这对显示是对的（目录本身不归谁），但删除权限
      # 不能只看这一列 —— 见下面 delete 的处理。
      df$owner[df$is_dir] <- "—"
      # 排序在这里做，**只做一次**：表格的行序和 selected() / cell_clicked
      # 取行号用的数据框从此是同一个顺序（理由见 dsapp_files_order 的说明）。
      dsapp_files_order(df)
    })

    # ---- 面包屑 ----
    #
    # 每一段是一个 actionLink，点一下跳到那一层。
    #
    # ⚠️ 这里**不能**按当前路径动态注册 observer。本项目已经踩过一次：
    #    在 observe 里创建 observer，Shiny 不会在下次重跑时销毁上一次
    #    建的那些（settings 页的节点名册有详细说明）。所以这里反过来做 ——
    #    段数是有上限的（DSAPP_CRUMB_MAX），一次性把 0..MAX 号观察器
    #    全注册好，每次重渲染只是换掉链接的文字和目标。多出来的段
    #    渲染成纯文字，走「上一级」或直接点前面的段。
    DSAPP_CRUMB_MAX <- 12L
    # ⚠️ 循环变量**必须**叫一个不会跟别处撞名的名字。
    #
    # 这里原来叫 `k`。R 的 for 循环变量是写在**函数环境**里的，循环跑完
    # 它就留在那儿 —— 于是 `k` 在整个 moduleServer 里一直等于最后一个值
    # （12L），任何闭包都能读到它。下面的 ws_group_ui() 就是这么中招的：
    # 它想拿"这一组的任务号"，写的却是 `k`，于是每个分组上的链接都渲染成
    # 「任务 #12」、点下去也永远跳到 12 号任务 —— 不报错、不告警，只是
    # 悄悄地指向一条不存在（或属于别人）的任务。2026-09-15 靠
    # tests/ui_v8/crossnav.py 真的点了一下才抓到。
    #
    # 改名的意义不是好看：现在再有谁误用 `k`，会当场 "object 'k' not found"，
    # 而不是拿到一个看着像任务号的 12。错得响比错得静好。
    for (crumb_lvl in 0:DSAPP_CRUMB_MAX) {
      local({
        lvl <- crumb_lvl
        observeEvent(input[[paste0("crumb_", lvl)]], {
          cur <- current_dir()
          seg <- dsapp_rel_segments(cur) %||% character(0)
          current_dir(if (lvl <= 0) "" else paste(seg[seq_len(min(lvl, length(seg)))],
                                                  collapse = "/"))
        }, ignoreNULL = TRUE)
      })
    }

    output$crumb <- renderUI({
      seg <- dsapp_rel_segments(current_dir()) %||% character(0)
      # 根目录永远是第一段，且永远可点 —— 迷路时它是最靠得住的那个按钮
      items <- list(actionLink(ns("crumb_0"),
                               tagList(icon("house"), " 文件管理区"),
                               class = "dsapp-crumb"))
      upto <- min(length(seg), DSAPP_CRUMB_MAX)
      if (length(seg)) {
        for (i in seq_len(upto)) {
          items <- c(items, list(span(class = "dsapp-crumb-sep", "/")))
          label <- if (i == length(seg)) {
            tags$b(seg[i])   # 当前这一层加粗，一眼看得出自己在哪
          } else {
            seg[i]
          }
          items <- c(items, list(
            if (i <= DSAPP_CRUMB_MAX) actionLink(ns(paste0("crumb_", i)), label,
                                                 class = "dsapp-crumb")
            else span(class = "dsapp-crumb", label)))
        }
      }
      div(class = "dsapp-crumb-bar", items)
    })

    output$drop_title <- renderText({
      d <- current_dir()
      if (!nzchar(d)) "把文件拖到这里（上传到文件管理区根目录）"
      else sprintf("把文件拖到这里（上传到 %s）", d)
    })

    # ★ V13.5 item 4：服务端**反向**设置勾选。
    #
    #   勾选这件事一直是**单向**的（浏览器 → 服务端）：用户点行，DT 把行号
    #   喂给 input$tbl_rows_selected。而「去预览」按钮要求反过来 —— 服务端
    #   得能说"把第 i 行选上"。
    #
    # ⚠️⚠️ **不能用 `DT::selectRows(proxy, i)`**，它在这张表上永远不生效，
    #   而且不报错。2026-09-17 浏览器实测抓到的：
    #
    #      · 表已经初始化好、`$(el).data('datatable').shinyMethods` 里
    #        有 updateCaption / addRow / reloadData … 唯独**没有 selectRows**；
    #      · DT 的 datatables.js 里，`methods.selectRows` 是包在
    #        `if (inArray(data.selection.mode, ['single','multiple']))` 里的。
    #        这两张表都写着 `selection = "none"`（**必须写** —— DT 自带的行
    #        选中和 Select 扩展是两套实现，同时开着会互相抢，见上面那段），
    #        于是那一整块被跳过。
    #      · 代理消息落到 `console.log("Unknown method " + call.method)` 那一支。
    #        是 log 不是 error —— **控制台不红**，只看 error 的断言全绿，
    #        只有"点一下看看"才分得出来。
    #
    #   改走自定义消息 + Select 扩展自己的 API（`rows().select()` /
    #   `.deselect()`）—— 那两个方法挂在 DataTables API 上，不受上面那个
    #   开关影响。JS 那一侧在 www/app.js 的 "dsapp:selectRows" 处理器里。
    #
    # ⚠️ id 要给**带命名空间**的那个（和 dataTableOutput 的 id 一模一样）：
    #    JS 是 `document.getElementById(m.id)`，给 "tbl" 找不到东西，
    #    表现同样是"点了没反应、控制台不红"。
    #
    # ⚠️ 行号传 **1 基**（R 的下标），JS 那边减 1 —— DataTables 是 0 基的。
    sel_rows <- function(i) {
      rows <- if (is.null(i)) list() else list(as.integer(i))
      try(session$sendCustomMessage("dsapp:selectRows",
                                    list(id = ns("tbl"), rows = rows)),
          silent = TRUE)
      invisible(NULL)
    }

    # ★ V13.9 item 10：「去预览」看的**是哪一个**，和"勾了哪些"是两件事，
    #   所以预览有自己的指针。定义在这里（而不是和 preview_target() 挨着）
    #   是因为下面 `observeEvent(current_dir(), ...)` 那个 observer 会用到它
    #   —— 放后面在运行时也能找到，但读的人会以为找不到。
    pv_pick <- reactiveVal(NULL)      # files() 里的行号，1 基

    # 换目录时清掉选中态。
    #
    # ⚠️ 不清的话，`input$tbl_rows_selected` 会留着上一条路径里的行号，
    #    而 selected() 是拿这个行号去**新目录**的表里取的 —— 于是界面上
    #    一个都没高亮，点「删除」却删掉了新目录里的第 3 个文件。
    #    这类"没选中的东西被删了"是最难向用户解释的一种失败。
    observeEvent(current_dir(), {
      sel_rows(NULL)
      # ★ V13.9 item 10：预览指针同理 —— 它存的是"第几行"，而换目录之后
      #   第 i 行是**另一个文件**了。
      pv_pick(NULL)
    }, ignoreNULL = FALSE)

    # =========================================================================
    # 对话产物
    # =========================================================================
    # 代码执行和产物落地都在对话自己的工作区里（见 utils.R 的 dsapp_ws_dir），
    # 不再自动倒进共享区。这块区域就是给用户看"我这个对话跑出了什么"、
    # 以及把它发布出去的地方。
    #
    # 当前对话是谁由 mod_chat 写进 state$chat_session_id —— 对话页才有
    # "当前对话"这个概念，文件页要用就只能从共享状态里读。
    ws_refresh <- reactiveVal(0)

    # 工作区卡片头上那个刷新按钮（V9 item 3）
    observeEvent(input$refresh_ws, {
      ws_refresh(ws_refresh() + 1)
      showNotification("已重新读取工作区", type = "message", duration = 2)
    })

    # 这一页要显示**哪个**对话的工作区（V8 item 5）。
    #
    # 默认跟着言出法随页的当前对话走。从任务页点「在文件区打开」过来时，
    # state$focus_ws 里带着那条任务**所属**的对话 —— 这一页得能显示别的
    # 对话的工作区，否则"从任务跳到对应文件"就只是"跳到文件页看一眼当前
    # 对话"，而当前对话很可能压根不是那条任务的，跳了个寂寞。
    #
    # ⚠️ 不能靠直接改 state$chat_session_id 来实现。mod_chat 里有一个
    #    observe 一直在把 rv$session_id 往那一格镜像（见 mod_chat.R），
    #    从这边写进去会被它立刻覆盖回来 —— 表现是"点了跳转，文件页闪一下
    #    又变回原样"，而且不报任何错。
    focus_ws <- reactive({
      f <- state$focus_ws
      if (is.list(f) && !is.null(f$sid) && nzchar(f$sid)) f else NULL
    })
    show_sid <- reactive({
      f <- focus_ws()
      if (!is.null(f)) f$sid else state$chat_session_id
    })
    # 跳过来之后界面上必须有一条说明 + 一条退路。两种"跳过来"不一样，
    # 但都需要这条：
    #   * 跳到**别的**对话的工作区 —— 不说的话用户看到的是另一个对话的
    #     产物，却没有任何线索解释为什么；
    #   * 跳到本对话里的某一项 —— 高亮会一直留着（因为 focus_ws 还在），
    #     没有一个"我不看了"的开关，那一行就永远亮着。
    focus_bar <- reactive({
      f <- focus_ws()
      if (is.null(f)) return(NULL)
      same <- identical(f$sid, state$chat_session_id)
      div(class = "dsapp-focusbar",
        icon("crosshairs"), " ",
        if (same) {
          sprintf("已定位到 %s",
                  if (!is.null(f$name) && nzchar(f$name)) f$name else "这个对话的产物")
        } else {
          tagList("正在看 ",
            tags$b(db_session_label(f$sid, con = dsapp_db(cfg()))),
            " 的工作区",
            if (!is.null(f$task_id))
              sprintf("（任务 #%d 的产出）", as.integer(f$task_id)) else "")
        },
        actionLink(ns("focus_back"),
                   if (same) "取消定位" else "回到当前对话",
                   class = "dsapp-focusbar-back")
      )
    })
    observeEvent(input$focus_back, { state$focus_ws <- NULL })

    # ---- 对话选择器（V9 item 5）----------------------------------------------
    #
    # 用户的原话：「不同的对话需要在不同的文件夹里，注意管理区分」。
    #
    # 盘上**已经是**分开的（每个对话一个 workspaces/chat-<sid>/，见 utils.R 的
    # dsapp_ws_dir），缺的是**界面上够不着**：这一页原来只能看"当前对话"的
    # 工作区，想看另一个对话产出过什么，得先跑到言出法随页把那个对话切过去
    # 再回来。分开存了、但只能一个一个看，用户当然觉得"没区分"。
    #
    # 所以这里补的是一个下拉框：所有对话列出来，直接跳。跳转复用 focus_ws
    # 那一套（原来只有"从任务页跳过来"会用），连带把顶部那条"正在看 X 的
    # 工作区 / 回到当前对话"也一并拿到 —— 不会出现"我跳到别的对话去了，
    # 但界面上没有任何迹象"。
    #
    # ⚠️ 统计各对话的占用是**走盘**的（每个工作区一趟递归 list.files），
    #    所以它挂在 30 秒的轮询上，不跟着工作区那 2 秒的轮询走。跟着走的话
    #    20 个对话就是每 2 秒 20 趟目录树 —— 而这一页有一半时间根本没人看
    #    那个数字。
    convs_rev <- reactivePoll(
      30000, session,
      checkFunc = function() {
        # 便宜的那部分：只问"有哪几个对话"。贵的那部分在 valueFunc 里，
        # 而 reactivePoll 只在 checkFunc 的返回值**变了**的时候才调它。
        # ws_refresh() 拼进来是为了让手动刷新能穿透这 30 秒。
        l <- tryCatch(db_sessions_list(state$user_id, con = dsapp_db(cfg())),
                      error = function(e) NULL)
        paste(c(if (is.null(l)) "" else l$id, ws_refresh()), collapse = "|")
      },
      valueFunc = function() {
        l <- tryCatch(db_sessions_list(state$user_id, con = dsapp_db(cfg())),
                      error = function(e) NULL)
        if (is.null(l) || nrow(l) == 0) return(NULL)
        # 只列前 40 个。对话多了之后这个下拉框本来也没法用，而"最近用过的
        # 那些"覆盖了绝大多数真实需求（列表按 updated_at 倒序）。
        l <- utils::head(l, 40)
        l$n_file <- 0L
        l$bytes  <- 0
        for (i in seq_len(nrow(l))) {
          d <- dsapp_ws_dir(l$id[i], cfg(), create = FALSE)
          if (is.na(d) || !dir.exists(d)) next
          fs <- dsapp_ws_snapshot(d, dirs = FALSE)
          if (!length(fs)) next
          fi <- file.info(file.path(d, fs))
          l$n_file[i] <- sum(!is.na(fi$size) & !isTRUE(fi$isdir))
          l$bytes[i]  <- sum(fi$size, na.rm = TRUE)
        }
        l
      })

    observeEvent(input$pick_conv, {
      sid <- as.character(input$pick_conv %||% "")
      if (!nzchar(sid)) return()
      # 选回当前对话 = 取消定位，标题从「对话产物」变回「本对话产物」。
      # 不这么做的话，用户永远回不到"跟着言出法随页走"那个状态。
      if (identical(sid, state$chat_session_id)) {
        state$focus_ws <- NULL
      } else {
        state$focus_ws <- list(sid = sid)
      }
    }, ignoreNULL = TRUE)

    # 从任务页跳过来时，产物行是**重渲染之后**才出现的，这一拍还没有。
    # app.js 那边的 dsapp:flash 会轮询等它出现，所以这里发出去就行。
    #
    # 只在高亮行真的存在时才发（点「在文件区打开」进来时没有具体产物名，
    # 发出去就是一个注定轮询 3 秒然后放弃的选择器）。那种情况下顶部那条
    # focusbar 已经把"在看哪个对话"说清楚了，不需要再闪。
    observeEvent(focus_ws(), {
      f <- focus_ws()
      if (is.null(f) || is.null(f$name) || !nzchar(f$name)) return()
      session$sendCustomMessage("dsapp:flash", list(sel = ".dsapp-wsrow-hit"))
    }, ignoreNULL = TRUE)

    # 工作区的内容会被执行中的任务改动，而改它的不是这个页面 —— 所以
    # 光靠"本页操作后 refresh"是不够的。用 reactivePoll 每 2 秒对一次
    # 摘要（文件数 + 总大小 + mtime 之和），变了才重新读盘。
    #
    # 这个轮询只在「文件」页真的显示着的时候才跑：reactivePoll 靠
    # invalidateLater 驱动，而没被读过的 reactive 不会自己转。切到别的页
    # 时输出被挂起，轮询自然停下。
    ws_groups <- reactivePoll(
      2000, session,
      checkFunc = function() {
        sid <- show_sid()
        if (is.null(sid)) return("")
        d <- dsapp_ws_dir(sid, cfg(), create = FALSE)
        if (is.na(d) || !dir.exists(d)) return("")
        # 递归（工作区里有子目录了）。理由同 mod_chat 里那一处。
        #
        # ⚠️ dirs = TRUE（V8 item 7）。这个摘要决定"要不要重读盘"，而
        #    模型建一个**空**文件夹时，文件数/总字节数/mtime 之和一个都不
        #    变（目录那 4096 字节的目录项大小不在文件列表里）—— 界面就
        #    永远停在旧的那一份，"新建的文件夹看不见"会被坐实成"刷新
        #    也没用"。带上目录之后，目录的数量和 mtime 一起进摘要。
        fs <- dsapp_ws_snapshot(d, dirs = TRUE)
        if (!length(fs)) return("")
        fi <- file.info(file.path(d, fs))
        # ★★ `ws_refresh()` 必须**拼进返回值里**，不能只是在这里读一下。
        #
        #    reactivePoll 的实现是 `rv$cookie <- checkFunc()`，而 reactiveValues
        #    **只有值真的变了**才会让下游失效。所以原来那种"读一下建立依赖"
        #    的写法是没用的：发布之后 ws_refresh 变了 → checkFunc 重跑 →
        #    返回的还是同一串（发布是**把文件复制出工作区**，工作区的
        #    文件数/大小/mtime 一个都没动）→ cookie 没变 → valueFunc 不重跑
        #    →「已发布」标记永远不出现。实测就是这么卡住的。
        #
        #    拼进去之后，ws_refresh 一变返回值就变，强制重算 —— 这也正是
        #    调用方 `ws_refresh(ws_refresh() + 1)` 本来想要的效果。
        # ⚠️ sid 也要拼进去：两个对话的工作区摘要**可能一模一样**（都只有
        #    一个同名的空文件夹），那样从任务页跳过来时 cookie 没变，
        #    valueFunc 不会重跑，界面显示的还是上一个对话的产物 ——
        #    而且看起来完全正常。
        paste(sid, ws_refresh(),
              length(fs), sum(fi$size, na.rm = TRUE),
              sum(as.numeric(fi$mtime), na.rm = TRUE))
      },
      valueFunc = function() {
        sid <- show_sid()
        if (is.null(sid)) return(list())
        # V7 item 7/10：按**任务**分组，不再是平铺一长条。
        #
        # ⚠️ 磁盘是真相、task_files 表只是索引（见 dsapp_ws_groups 的说明），
        #    所以这里仍然以扫盘为准 —— 上面 checkFunc 盯的就是磁盘。
        gs <- tryCatch(dsapp_ws_groups(sid, cfg()), error = function(e) list())
        # ★★ V15.5 item 11：每一组里的文件**按修改时间从新到旧**。
        #
        #   用户原话：「文件管理区也应该是最新的文件默认排在最前面」。
        #   「文件管理区」那张表（files() → dsapp_files_order，V14 item 2）
        #   和对话页右栏那张产出卡早就是"最新在前"了，剩下没跟上的就是**这一块**
        #   —— dsapp_ws_groups 组内是 `order(sub$name)`（按名字排）。按名字排
        #   的后果是"看起来像随机"：刚跑出来的 de_genes.csv 会排在 asv_table.csv
        #   后面，用户在这一组里找一个"我刚产出的东西"要先扫一遍全组。
        #
        #   ⚠️ 排序放在**数据框上**，不放渲染层：这一组的每一行都是拿
        #      g$files$name[i] / size_h[i] / mtime[i] 按**行号**取的
        #      （下面的 ws_group_ui，以及任务页那边同一份数据）。行序和显示
        #      顺序必须是同一个 —— 渲染层再排一遍，下面那些按行号取的值和
        #      界面上的行就对不上了。组内那些动作链接绑的是**名字**
        #      （data-rel = nm）不是行号，所以重排行不动别的。
        #   ⚠️ 顺序函数复用 dsapp_files_order（目录在前、文件按 mtime 从新到旧），
        #      **不要**在这里另写一个 sort：工作区那份 mtime 和文件区是同一个
        #      格式（都是 "%Y-%m-%d %H:%M"），共用一个函数两边才对得上。
        #   ⚠️ 只动了 files 的**顺序**，上面算好的 bytes / n_file / n_dir 不用
        #      重算（同一批行，只是换了次序）。
        #   ⚠️ 排序的**源头**在 executor.R 的 dsapp_ws_groups()（组内
        #      `dsapp_files_order(sub)`）：任务页那张产物列表（mod_tasks.R 的
        #      task_group()）直接调它、不经过这里，所以改在这里的话那边会漏
        #      —— 同一份数据在三个地方显示，规则必须只有一处。
        #      下面这段是**幂等的**保险：同一个函数、同一个数据框，再排一次
        #      结果不变；留着是为了"文件页自己也能保证顺序"，不引入第二套规则。
        for (i in seq_along(gs)) {
          if (!is.null(gs[[i]]$files) && nrow(gs[[i]]$files)) {
            gs[[i]]$files <- dsapp_files_order(gs[[i]]$files)
          }
        }
        gs
      }
    )

    # 存储配额条。刷新节奏跟着文件列表走（上传/删除/发布都会让它变），
    # 不单独起一个定时器 —— 配额只有在这几个动作之后才会变，定时刷是白量磁盘
    # （dsapp_quota_used 内部要跑 du，工作区里几万个小文件是秒级的活）。
    output$quota_bar <- renderUI({
      # 依赖两个既有的刷新信号：共享区的 refresh() 和工作区的 ws_refresh()。
      # 配额只有在这两处动作（上传/删除/解压/发布）之后才会变。
      refresh()
      ws_refresh()
      b <- tryCatch(dsapp_quota_bar(state$user_id, cfg()), error = function(e) NULL)
      if (is.null(b)) return(NULL)

      cls <- if (b$over) "bg-danger" else if (b$near) "bg-warning" else "bg-primary"
      div(class = "dsapp-quota-bar",
        div(class = "d-flex justify-content-between align-items-baseline small",
          span(icon("hard-drive"), " 我的存储空间",
               if (b$over)
                 span(class = "badge bg-danger ms-2", "已超额")
               else if (b$near)
                 span(class = "badge bg-warning text-dark ms-2", "快满了")),
          span(class = "text-muted",
               sprintf("%s / %s（%d%%）", dsapp_fmt_bytes(b$used),
                       dsapp_fmt_bytes(b$quota), b$pct))
        ),
        div(class = "progress mt-1", style = "height:6px;",
          div(class = paste("progress-bar", cls),
              style = sprintf("width:%d%%", max(2, b$pct)))
        ),
        if (b$over)
          div(class = "small text-danger mt-1",
              icon("triangle-exclamation"),
              " 已经超了配额：不能再上传、解压或起新任务。",
              "删掉一些不用的对话或文件管理区里的文件就能继续。")
      )
    })

    # ---- 产物行 / 分组的渲染 ----
    #
    # 每个动作是一个 <a>，点击时把 `动作|参数` 塞进一个**共用**的 input
    # （`ws_act`），由一个 observer 分派。
    #
    # ⚠️ 不给每个文件注册一个 observer。本项目已经踩过一次：在 renderUI 里
    #    动态注册 observer，Shiny 不会在下次重渲染时销毁上一次那批 ——
    #    产物每 2 秒重扫一次，几百个文件就是几百个永不回收的 observer，
    #    而且它们全都指向**上一次**的那份数据（见 settings 页的节点名册）。
    ws_act_link <- function(label, act, arg, ico = NULL, cls = "dsapp-wsrow-a") {
      # ⚠️ `stopPropagation` 不能省。这些链接有的长在 <summary> 里面，而
      #    浏览器对"点 summary 里的任何东西都切换展开"是**默认行为** ——
      #    只写 `return false` 在标准里只保证 preventDefault，各浏览器对
      #    要不要顺带停掉传播并不一致。不停的话，点「打包下载」会同时把
      #    这一组收起来（下载照常开始），看起来像界面在自己动。
      js <- sprintf(paste0("event.stopPropagation();",
                           "Shiny.setInputValue(%s,%s,{priority:'event'});",
                           "return false;"),
                    jsonlite::toJSON(ns("ws_act"), auto_unbox = TRUE),
                    jsonlite::toJSON(paste0(act, "|", arg), auto_unbox = TRUE))
      tags$a(href = "#", class = cls, onclick = js,
             if (!is.null(ico)) icon(ico), " ", label)
    }

    # ★ V16.10：形参从"五个散着的标量"换成**一行** `dsapp_files_rows()` 的
    #   产物。散着传的话，图标名和目录徽标在**调用点**又得各写一遍 —— 那就
    #   等于"收口"之后还留着第二份定义，而且两份漂了之后界面上看不出
    #   （图标名字符串写错不会报错，那一格就一直是空的）。
    #   ⚠️ 保留 `%||%` 兜底：`dsapp_files_rows()` 保证有这四列，但这里的
    #      调用方不止一处，缺列时退化成"按 is_dir 猜"比整行渲染不出来强。
    ws_row <- function(r, published = FALSE, highlight = FALSE) {
      # 目录和文件在界面上是**两种东西**，不是"名字带斜杠的文件"（V8
      # item 7）。三处都不同：
      #   * 图标：文件夹 vs 文件（光靠名字末尾有没有斜杠，一屏扫下来是看不出的）
      #   * 右边那枚标记：目录写「文件夹」而不是「仅本对话」——目录根本
      #     没有"发布"这回事，写「仅本对话」会让用户去找发布按钮
      #   * 动作：目录只能「打包下载」（发布是"把一个文件复制进共享区"，
      #     共享区按文件管，给目录发布按钮点下去只会造出一个假文件）
      nm     <- as.character(r$name %||% "")[1]
      is_dir <- isTRUE(as.logical(r$is_dir %||% FALSE)[1])
      size_h <- as.character(r$size_h %||% "")[1]
      mtime  <- as.character(r$mtime %||% "")[1]
      ico    <- as.character(r$icon %||% (if (is_dir) "folder" else "file"))[1]
      mark   <- as.character(r$mark %||% (if (is_dir) "文件夹" else NA_character_))[1]
      div(class = paste(c("dsapp-wsrow",
                          if (is_dir) "dsapp-wsrow-dir",
                          if (isTRUE(highlight)) "dsapp-wsrow-hit"), collapse = " "),
        `data-rel` = nm,
        span(class = "dsapp-wsrow-name", title = nm,
             icon(ico), " ", nm),
        span(class = "dsapp-wsrow-size", size_h),
        span(class = "dsapp-wsrow-time", mtime),
        span(class = if (published) "dsapp-pill dsapp-pill-on" else "dsapp-pill",
             if (is_dir) mark else if (published) "已发布" else "仅本对话"),
        span(class = "dsapp-wsrow-act",
          if (is_dir) {
            ws_act_link("打包下载", "zipdir", nm, "file-zipper")
          } else {
            tagList(
              # ★★ V13.9 item 4 用户原话：
              #    「言出法随的文件界面也需要支持预览」
              #
              #    这一行原来只有「下载」和「发布」——想看一眼火山图长什么样，
              #    只能先下载、再去浏览器的下载目录里翻。而上面**管理区**
              #    那张表（同一个页面、同一屏之内）点文件名就是预览。
              #    两块地方放的是同一批文件，交互却不一样，用户当然会问。
              #
              #    ⚠️ 排在「下载」**前面**：这三颗的语义是"从轻到重"——
              #       看一眼 / 拿走 / 给别人。把最轻的那个放最前面，用户不会
              #       为了"就想看一眼"去点那个会往硬盘里写东西的按钮。
              ws_act_link("预览", "pv", nm, "magnifying-glass"),
              ws_act_link("下载", "dl", nm, "download"),
              if (!published)
                ws_act_link("发布", "pub", nm, "share-nodes")
            )
          }
        )
      )
    }

    # 一个任务 = 一个可折叠的 <details>（V7 item 7/10 的正题）。
    #
    # 用 <details> 而不是手写折叠 JS：浏览器原生就管键盘、无障碍和
    # "点标题展开"这件事，而这里要的恰好就是这些。收起≠信息丢失 ——
    # 摘要行上写着文件数和总体积，收着也能一眼看出里面有多少东西。
    ws_group_ui <- function(g, idx) {
      n <- nrow(g$files)
      # ★ V16.10：展示字段（图标 / 目录徽标）整组过一次 `dsapp_files_rows()`，
      #   下面按**行号**取 —— 和 `g$files` 逐个字段取是同一个约定。
      g_rows <- dsapp_files_rows(g$files)
      # `0` 代表"认不出归属"的那一组（见 dsapp_ws_groups）。任务号从 1 起，
      # 所以 0 不会和任何真任务撞。
      key <- if (is.na(g$task_id)) 0L else g$task_id
      # 用户手动开合过就以他为准；没动过（input 还没来过）= 第一组展开。
      # 全收起的话，用户看到的第一眼是四行标题，会以为产物列表没了。
      #
      # ★★ `isolate` 不能省，这不是性能优化。不加的话 renderUI 就**依赖**
      #    input$ws_open，于是：开合 → 上报 → 重渲染 → 重新插入带 open 的
      #    <details> → 浏览器再发 toggle → 再上报 → …… 一个停不下来的循环。
      #    （<details> 被插进 DOM 且带 open 属性时是会触发 toggle 的，所以
      #    重渲染本身就是"一次开合"。）实测表现是页面被刷爆、点下载毫无反应。
      #
      #    这里的定位是"**读**上次的状态"而不是"跟着它渲染"：浏览器那侧的
      #    <details> 已经是用户要的样子了，我们只在下次因为别的原因重渲染时
      #    把状态还原回去。所以就该 isolate。
      opened <- shiny::isolate(input$ws_open)
      is_open <- if (is.null(opened)) idx == 1L
                 else as.character(key) %in% as.character(opened)
      # 从任务页跳过来时，那条任务的那一组要**自动展开**（V8 item 5）。
      # 用户点的是"去文件区看这个任务的产物"，落地却看到一排收起的标题、
      # 还要自己找是哪一组，那这一跳等于没跳。
      # ⚠️ 比的是 **key**（= g$task_id，认不出归属时是 0），不是任何别的东西。
      #    这里原来写的是 `k` —— 那是上面面包屑 for 循环漏出来的变量，恒等于
      #    12，于是"从任务页跳过来自动展开那一组"从来没生效过。
      want <- focus_ws()
      if (!is.null(want) && !is.null(want$task_id) && key > 0 &&
          identical(as.integer(want$task_id), as.integer(key))) {
        is_open <- TRUE
      }
      # 高亮：只高亮被点名的那一项，别整组刷一遍色 —— 整组高亮等于没高亮。
      hit <- if (!is.null(want) && !is.null(want$name)) as.character(want$name) else ""
      tagList(
        tags$details(
          class = "dsapp-wsgroup",
          `data-key` = as.character(key),
          # ★ 开合状态必须跨重渲染保住。
          #
          # 这里原来写的是 `open = if (idx == 1L) NA else NULL` —— 第一组
          # 默认展开。看着没问题，直到用户在**别的**组里点「发布」：那个动作
          # 会 ws_refresh() 重渲染整张卡，于是所有组塌回默认，用户刚展开的
          # 那一组没了，连同刚打上的「已发布」标记一起被折叠藏起来 —— 表现
          # 就是"点了发布，界面闪一下，什么都没变"。
          #
          # 现在以用户的手动选择为准（app.js 的 toggle 监听器把打开的组
          # 报进 input$ws_open）；他还没动过时，才回落到"第一组展开"。
          open = if (is_open) NA else NULL,
          tags$summary(class = "dsapp-wsgroup-sum",
            span(class = "dsapp-wsgroup-title",
                 tags$b(if (nzchar(g$title)) g$title else "未命名任务"),
                 if (nzchar(g$status)) dsapp_status_badge(g$status)),
            span(class = "dsapp-wsgroup-meta",
                 # 目录单独说一句。只报"12 个文件"的话，用户扫一眼以为全是
                 # 文件，而其中那个空文件夹正是他来找的东西（V8 item 7）。
                 sprintf("%d 个文件%s · %s%s",
                         g$n_file %||% n,
                         if (isTRUE((g$n_dir %||% 0) > 0))
                           sprintf("、%d 个文件夹", g$n_dir) else "",
                         dsapp_fmt_bytes(g$bytes),
                         if (nzchar(g$time)) paste0(" · ", g$time) else "")),
            # V8 item 5：产物 → 产出它的那条任务。这一组的标题本来就是个
            # 任务名，但名字是模型起的、可能撞车，任务号才是唯一能对上的。
            # 链接上写的、点下去带走的，都必须是**这一组自己的**任务号
            # （key = g$task_id；0 表示认不出归属，那种组不给链接）。
            if (key > 0)
              ws_act_link(sprintf("任务 #%d", key), "gotask", as.character(key),
                          "arrow-up-right-dots", "dsapp-wsgroup-task"),
            ws_act_link("打包下载", "zip", as.character(key),
                        "file-zipper", "dsapp-wsgroup-zip")
          ),
          div(class = "dsapp-wsgroup-body",
            # ★ V16.10：整组过一次 `dsapp_files_rows()`（图标、目录徽标那条
            #   规则），再按行号取 —— 和上面 `n_file`/`bytes` 一样，**按行号**
            #   是这个数组的约定，别在这里另排一次序。
            lapply(seq_len(n), function(i)
              ws_row(g_rows[i, , drop = FALSE], isTRUE(g$files$published[i]),
                     identical(as.character(g$files$name[i]), hit))))
        )
      )
    }

    output$ws_card <- renderUI({
      sid <- show_sid()
      if (is.null(sid)) return(NULL)

      groups <- ws_groups()

      convs <- convs_rev()

      card(
        card_header(
          class = "d-flex justify-content-between align-items-center",
          span(icon("flask"), if (is.null(focus_ws())) " 本对话产物"
               else " 对话产物"),
          div(class = "d-flex align-items-center gap-2",
            # ---- 切对话（V9 item 5）----
            #
            # 用原生 <select> 而不是 selectInput：这一个控件每次重渲染都要
            # 把选中项摆回正确的位置，而 selectInput 是 Shiny 的绑定在管，
            # 重渲染回来的值和用户刚点的值打架时，下拉框会自己跳回去
            # （V9 前面那个「分析环境」的联动坑就是这么来的）。
            # 原生 select 的 selected 属性由我们每次渲染时算准，没有二义。
            local({
              if (is.null(convs) || nrow(convs) < 2) return(NULL)
              opts <- lapply(seq_len(nrow(convs)), function(i) {
                tags$option(
                  value = convs$id[i],
                  selected = if (identical(convs$id[i], sid)) NA else NULL,
                  sprintf("%s%s%s",
                          if (identical(as.character(convs$role[i]), "shared"))
                            sprintf("%s 的 ", convs$owner_name[i]) else "",
                          substr(convs$title[i] %||% "未命名", 1, 18),
                          if (convs$n_file[i] > 0)
                            sprintf("（%d 个文件 · %s）", convs$n_file[i],
                                    dsapp_fmt_bytes(convs$bytes[i]))
                          else "（还没有产物）"))
              })
              tags$select(
                class = "dsapp-convpick",
                title = "每个对话的文件放在各自的工作区里，换一个看",
                onchange = sprintf(
                  "Shiny.setInputValue(%s, this.value, {priority:'event'});",
                  dsapp_js_str(ns("pick_conv"))),
                opts)
            }),
            span(class = "small text-muted fw-normal",
                 paste0(db_session_label(sid, con = dsapp_db(cfg())), " 的工作区")),
            # 工作区这一块本来就有 2 秒轮询（见 ws_groups），但"我刚在另一
            # 个标签页里跑完一个任务"的时候，用户不想等 —— 而且轮询的判据
            # 是文件数/大小/mtime 的摘要，正好撞上"任务写了同名文件、
            # 大小没变"这类情况时会看不出来。手动那一下是兜底。
            tags$button(
              class = "btn btn-sm btn-outline-secondary py-0 px-2",
              type = "button",
              title = "重新读取工作区",
              onclick = sprintf(
                "Shiny.setInputValue(%s, Math.random(), {priority:'event'});",
                dsapp_js_str(ns("refresh_ws"))),
              icon("rotate"))
          )
        ),
        card_body(
          class = "p-2",
          focus_bar(),
          div(class = "small text-muted mb-2",
            "代码在这里执行，产物按产生它的任务分组，默认留在这里 —— ",
            tags$b("只有你点「发布」，文件才会进上面的文件管理区"),
            # ★ V13.1 item 8：这里原来跟了一句「（发布后所有人可见）」。
            #   管理区早就按账号隔离了（data/files/u<N>/），这句是反的 ——
            #   用户会以为发布 = 给全站看，于是该发布的也不敢发布。
            dsapp_md_inline("（发布后进的是**你自己**的文件管理区，别人看不到）。")),
          if (!length(groups)) {
            div(class = "text-muted small p-3",
                icon("inbox"), " 这个对话还没有产出文件。")
          } else {
            # `data-input` 是给 www/app.js 那个 toggle 监听器看的：开合状态要
            # 报回服务端，否则每次重渲染都塌回"只有第一组展开"（详见下面
            # ws_group_ui 里 open 那段的说明）。掛在容器上而不是每个
            # <details> 上，是为了让 app.js 不必知道模块 id。
            div(class = "dsapp-wsgroups", `data-input` = ns("ws_open"),
                lapply(seq_along(groups),
                       function(i) ws_group_ui(groups[[i]], i)))
          },
          # 真正的下载链接。它必须在 DOM 里 ——
          # `dsapp:clickWhenReady` 是 `document.getElementById(...).click()`，
          # 元素不存在时那个自定义消息会静默地什么都不做（约 4 秒后放弃），
          # 表现是"点了下载没反应"，且控制台一声不响。
          div(class = "dsapp-hidden-dl", downloadButton(ns("ws_dl"), "下载"))
        )
      )
    })

    # ---- 产物的下载 / 发布 / 打包 ----
    ws_dl_pick <- reactiveVal(NULL)

    # =========================================================================
    # ★★ V16.10：打包超过同步上限 → 转后台子进程
    # =========================================================================
    #
    # 原来这里的分工是"超了就说清楚、让用户少勾几个"。那条规矩对**勾选下载**
    # 还成立，但对话页那张卡一键就是**整个对话**（没有"少勾几个"这个选项），
    # 于是两页从此走同一条路：`dsapp_zip_build()` 子进程 + 同一个轮询 +
    # 各自的隐藏下载出口。分歧只剩一句文案。
    #
    # ⚠️⚠️ 同步打包是**真的**卡住所有人（一个应用一个 R 进程）：`zip` 是个
    #    子进程，R 在主进程里等它回来，几 G 的目录要几分钟 —— 这几分钟里
    #    **所有访客**的页面都冻着。所以这个上限管的不是磁盘、是别把服务器堵死。
    zip_job <- reactiveVal(NULL)   # list(h, t0, n, bytes, name, dst, out)

    # ★ V16.10：打包这条路失败时**屏幕上只说人话**。
    #
    #   起子进程失败的 `conditionMessage(h)` 和子进程半路失败的 `v$msg` 都是
    #   **英文原文**（带服务器上的绝对路径、函数名），用户看不懂，也没有任何
    #   能做的动作 —— 贴上去只会让人以为是自己弄坏了什么，然后来问
    #   「什么是 cannot open file」。原文进审计（管理员在「日志」里查得到），
    #   屏幕上只留一句人话 + 一个短代号，报障时报代号就能对上那一条。
    #
    #   ⚠️ 这不是我新发明的规矩：V16.9 的 `repair_fail_code()`（上面那条补齐
    #      路）就是同一件事，自检里那条 ★★★「R/ 里没有把 conditionMessage
    #      原文直接送到界面」按行扫「同一行里既有 conditionMessage 又有落屏
    #      函数」—— 我第一版就是直接把它拼进 showNotification 的，当场被那条
    #      抓了个正着（而且它连 `v$msg` 这种**转手**的原文都扫不到，所以这里
    #      两个失败点一起改）。
    zip_fail_code <- function(stage, raw) {
      code <- format(Sys.time(), "ZP%m%d%H%M%S")
      audit("zip_failed", target = stage,
            detail = sprintf("[%s] %s", code,
                             paste(as.character(raw %||% ""), collapse = " ")),
            ok = FALSE)
      code
    }

    # 起一个后台打包。返回 TRUE = 已经转到后台了（调用方**不要**再走同步那条）；
    # FALSE = 没起来（已经弹过错误），调用方也别走同步 —— 那只会再卡一次。
    zip_start_bg <- function(groups, plan, nm, out) {
      # 已经在打包了就退回。三个调用点（右栏分组 / 右栏文件夹 / 勾选下载）共用
      # 一个 `zip_job`，再起一个会把前一个的句柄冲掉 —— 前一个包没人认领，
      # 而用户看到的是"点了两下，下下来一个包"，说不清是哪一个。
      # ⚠️ `isolate()` 是**保险**：这个函数目前只从 `observeEvent` 的 handler
      #    里调，而 handler 本身跑在 isolate 里、读了也不建立依赖；但哪天有人
      #    把它挪进 renderUI，这里一读就会让那个 renderUI 每分钟重画一次。
      #    所以下面那颗按钮的进度文案是**另写一处** `zip_job()` 的普通读。
      if (!is.null(isolate(zip_job()))) {
        showNotification("正在打包，跑完就自动下载 —— 这期间别关这个页面",
                         type = "message", duration = 5)
        return(TRUE)
      }
      cfg_now <- cfg()
      dst <- file.path(cfg_now$run_dir,
                       sprintf("zipbuild-%s.zip", dsapp_id("z")))
      # 顺手清一次上一批的孤儿（用户在"正在打包…"的时候关掉页面，就没人做
      # `content()` 里那个 unlink 了）。不挂定时器 —— 理由见 dsapp_zip_bg_gc。
      try(dsapp_zip_bg_gc(cfg_now$run_dir), silent = TRUE)
      # ⚠️ `cfg` 要**显式传进去**（和补齐那条一样）：子进程会从自己的 cwd
      #    读 .Renviron，显式传一份能保证它和主进程用的是同一个 data_root。
      #    `groups` 是普通 list，能安全序列化 —— **绝不能**顺手把 `con`
      #    （S4 连接）也塞进去，那跨不了进程。
      h <- tryCatch(dsapp_bg_start("dsapp_zip_build",
                                   args = list(groups = groups, dst = dst),
                                   cfg = cfg_now, tag = "zipbuild"),
                    error = function(e) e)
      if (inherits(h, "error")) {
        # ⚠️ 原文走 zip_fail_code（审计），屏幕上只给人话 + 代号。
        code <- zip_fail_code("起子进程", conditionMessage(h))
        showNotification(
          sprintf(paste0("起不了打包进程（%s），稍后再试；",
                         "若一直如此，把这个代号发给管理员"), code),
          type = "error", duration = 12)
        return(FALSE)
      }
      zip_job(list(h = h, t0 = as.numeric(Sys.time()), n = plan$n,
                   bytes = as.numeric(plan$bytes), name = nm, dst = dst,
                   out = out))
      TRUE
    }

    # 轮询子进程。形状和上面 `sync_job` 那条一模一样（读句柄 → 没完就继续
    # 定时 → 取完写 NULL）。
    #
    # ⚠️ 顶层这句 `zip_job()` **必须保持是普通读、不能套 isolate()** ——
    #    它就是这个 observer 唯一的启动条件。隔离掉的话它永远不会跑。
    # ⚠️ **每一个出口都要解锁**：成功 / 子进程报错 / 子进程意外退出，三条都要
    #    写 NULL —— 少一条就是按钮永远转着、用户只能刷新页面。
    observe({
      # dsapp-selftest: self-reactive-ok zip_job
      job <- zip_job()
      if (is.null(job)) return()
      invalidateLater(1000)
      r <- tryCatch(dsapp_bg_poll(job$h), error = function(e) NULL)
      if (!isTRUE(r$done)) return()
      zip_job(NULL)
      v <- r$value %||% list()
      if (!isTRUE(r$ok) || !isTRUE(v$ok)) {
        # ⚠️ `%||%` 判的是 NULL/长度/NA，**不是 nzchar** —— `"" %||% x` 回的是
        #    `""`，挑出来的就是一句空的。逐个挑第一个非空的。
        msg <- c(as.character(v$msg %||% ""), as.character(r$msg %||% ""))
        msg <- msg[nzchar(msg)]
        # ⚠️ 挑出来的那个是**子进程的英文原文**（R/jobs.R 那边就是
        #    `msg = conditionMessage(e)`）—— 走审计，屏幕上只留人话 + 代号。
        #    自检那条按行扫的规则**抓不到这里**（原文是转手的），但规矩一样。
        code <- zip_fail_code("子进程半路失败",
                              if (length(msg)) msg[[1]] else "子进程没有返回结果")
        showNotification(
          sprintf(paste0("打包中途失败了（%s）—— 稍后再点一次；",
                         "若一直如此，把这个代号发给管理员"), code),
          type = "error", duration = 12)
        return()
      }
      # ⚠️ 包在哪是**主进程**记着的（`job$dst`），不是从子进程的返回值里取。
      dst <- job$dst %||% ""
      if (!nzchar(dst) || !file.exists(dst)) {
        showNotification("打包完了，但包不见了（临时目录被清理）",
                         type = "error", duration = 12)
        return()
      }
      # 出口是**谁点的谁**：右栏分组/文件夹那两处走 ws_dl，勾选下载走 download。
      # 两个隐藏的 downloadHandler 各有一套 content()，接的 kind 也不一样。
      if (identical(job$out, "ws_dl")) {
        ws_dl_pick(list(kind = "zipbg", path = dst, name = job$name))
      } else {
        dl_pick(list(kind = "zipbg", path = dst, name = job$name))
      }
      session$sendCustomMessage("dsapp:clickWhenReady", list(id = ns(job$out)))
    })

    # ★ V13.9 item 4：预览弹窗里那个文件。存**已经校验过的路径**而不是光存
    #   相对名 —— 弹窗里的 renderUI / renderDataTable 会在弹出之后被 Shiny
    #   重算好几次，每次都拿名字回去查一遍库是白费的；而且中间文件被删掉时，
    #   存下来的路径能让下面"文件不在了"那条分支说得准（名字还在，路径没了）。
    ws_view <- reactiveVal(NULL)

    output$ws_dl <- downloadHandler(
      # basename：产物名是相对工作区的路径，带 `/` 的下载名会被浏览器
      # 当路径处理（Linux 上失效，Windows 上变成下划线）。
      filename = function() basename((ws_dl_pick() %||% list())$name %||% "download"),
      content = function(file) {
        d <- ws_dl_pick()
        if (is.null(d)) return(invisible())
        # ★ V16.10：后台打好的包直接搬过来（`zipbg`）。**必须排在最前面** ——
        #   下面那个 `!identical(d$kind, "zip")` 的分支会把 zipbg 当成"单个
        #   文件"喂给 dsapp_dl_write()，而它看到不认识的 kind 会去走
        #   `d$path`（zipbg 那份压根没有这个字段）—— 用户拿到一个 0 字节的包，
        #   而且服务端一声不吭。
        if (identical(d$kind, "zipbg")) {
          ok <- dsapp_zip_bg_handoff(file, d$path)
          if (!ok) {
            try(dsapp_audit("ws_zip_download", user = state$user,
                            user_id = state$user_id,
                            target = d$name %||% "", ok = FALSE,
                            detail = "打包好的文件不见了（临时目录被清理）",
                            session = session, cfg = cfg()), silent = TRUE)
          }
          return(invisible())
        }
        # ★ V14 item 3：file / html / zip 三种都交给 dsapp_dl_write()，
        #   三个下载处理器共用那一份（理由见它的说明）。
        #
        # ⚠️ 只有 zip 才要 root，而 html / file 两支的 `d$root` 可能是 NULL
        #    （对话页那条路不传）—— 所以**不能**在这里统一去算 dsapp_ws_dir。
        if (identical(d$kind, "zip") && is.null(d$root)) {
          root <- tryCatch(dsapp_ws_dir(d$sid, cfg(), create = FALSE),
                           error = function(e) NA_character_)
          if (is.na(root) || !dir.exists(root)) return(invisible())
          d$root <- root
        }
        dsapp_dl_write(file, d)
      }
    )
    # ★ 见 `output$download` 上面那段说明：下载链接藏在界面里，
    #   不关掉"隐藏即挂起"的话 href 永远下不来。
    outputOptions(output, "ws_dl", suspendWhenHidden = FALSE)

    observeEvent(input$ws_act, {
      v <- input$ws_act
      req(v, nzchar(v))
      # `|` 是分隔符，而路径里可以有 `|`（合法文件名）。所以只切第一个，
      # 剩下的原样拼回去当参数。
      cut <- regexpr("|", v, fixed = TRUE)
      if (cut < 1) return()
      act <- substr(v, 1, cut - 1)
      arg <- substr(v, cut + 1, nchar(v))

      sid <- show_sid()
      if (is.null(sid)) return()

      # 产物 → 那条任务（V8 item 5）。跳过去之前先把"要看哪条"写进共享
      # 状态，任务页那边收得到才谈得上定位；写不进去也照样跳 —— 跳到任务
      # 列表总比点了没反应强。
      if (identical(act, "gotask")) {
        tid <- suppressWarnings(as.integer(arg))
        if (!is.na(tid)) {
          state$focus_task <- tid
          dsapp_nav_to(state, "tasks")
        }
        return()
      }

      # ★★ V13.9 item 4：工作区里的产物也能先预览再决定拿不拿走。
      #
      # 这里**不重写预览分支**，直接调 dsapp_preview_ui()（R/files.R）——
      # 管理区那份、对话页那份、这份，三处共用同一个函数。理由在 files.R
      # 那段注释里写得很清楚：那七支里每一行都是踩过坑的（体积闸门、CSP、
      # 会话级地址、列名修补），抄一份等于把坑重新挖一遍。
      #
      # ⚠️ 走的是 dsapp_ws_path() 重新校验，不是把浏览器传来的名字直接拼
      #    路径 —— 和下面 "dl" 那一支同一条理由（见 files.R 顶部）。
      if (identical(act, "pv")) {
        p <- dsapp_ws_path(arg, sid, cfg())
        if (is.null(p) || !file.exists(p) || isTRUE(file.info(p)$isdir)) {
          dsapp_notify_stale("这个文件",
                             refresh = function() ws_refresh(ws_refresh() + 1L))
          return()
        }
        ws_view(list(rel = arg, path = p, sid = sid))
        showModal(modalDialog(
          title = tagList(icon("magnifying-glass"), " ", basename(arg)),
          size = "l",
          easyClose = TRUE,
          uiOutput(ns("ws_preview_ui")),
          footer = tagList(
            modalButton("关闭"),
            # ⚠️ 下载那一颗复用列表里那条通路（ws_dl + clickWhenReady），
            #    不另开一个 downloadHandler：两条路各写一遍 filename 规则，
            #    迟早有一条忘了 basename（理由见 output$ws_dl 上面那段）。
            actionButton(ns("ws_pv_dl"), "下载",
                         class = "btn-primary", icon = icon("download"))
          )
        ))
        return()
      }

      if (identical(act, "pub")) {
        r <- dsapp_publish_artifact(arg, sid, cfg())
        audit("file_publish", target = as.character(r$name %||% arg),
              detail = sprintf("来自对话 %s", sid), ok = isTRUE(r$ok))
        if (isTRUE(r$ok)) {
          refresh(refresh() + 1)
          ws_refresh(ws_refresh() + 1)
          showNotification(sprintf("已发布 %s 到文件管理区", r$name),
                           type = "message", duration = 6)
        } else {
          showNotification(r$msg, type = "error", duration = 8)
        }
        return()
      }

      if (identical(act, "dl")) {
        # 走 dsapp_ws_path 而不是直接拼路径：文件名到了浏览器又回来，
        # 中间可以被改（见 files.R 顶部的说明）。
        p <- dsapp_ws_path(arg, sid, cfg())
        if (is.null(p)) {
          # ★ V13.7 item 2：平台自己把列表刷新掉，别让用户去按 F5
          dsapp_notify_stale("这个文件",
                             refresh = function() ws_refresh(ws_refresh() + 1L))
          return()
        }
        # ★ V14 item 3：`arg` 就是工作区相对路径，直接当 rel 传下去 ——
        #   不能让 dsapp_dl_plan 自己去推，工作区里那份常常是指向管理区的
        #   软链，normalizePath 会把它带到管理区上，推出来的相对路径是错的。
        root <- dsapp_ws_dir(sid, cfg(), create = FALSE)
        plan <- dsapp_dl_plan(p, root, rel = arg, name = basename(arg))
        plan$sid <- sid
        ws_dl_pick(plan)
      } else if (identical(act, "zipdir")) {
        # 单个目录打包（V8 item 7）。不能拿 "zip" 那个按**任务**分的处理器
        # 顶 —— 它认的参数是组 key，把目录路径喂进去只会命中"这一组已经
        # 不在了"。
        p <- dsapp_ws_path(arg, sid, cfg())
        if (is.null(p) || !isTRUE(file.info(p)$isdir)) {
          dsapp_notify_stale("这个文件夹",
                             refresh = function() ws_refresh(ws_refresh() + 1L))
          return()
        }
        root <- dsapp_ws_dir(sid, cfg(), create = FALSE)
        if (is.na(root) || !dir.exists(root)) {
          showNotification("工作区已经不在了", type = "error")
          return()
        }
        # 目录下的**文件**才进包。直接把目录名丢给 dsapp_zip_plan 也行
        # （它认目录），但那样打出来的包里会连**没改过名的只读输入软链**
        # 一起被跳过 —— 这里显式列一遍，好在数量为 0 时说人话。
        arts <- tryCatch(dsapp_ws_artifacts(sid, cfg()), error = function(e) NULL)
        rels <- if (is.null(arts)) character(0)
                else arts$name[!arts$is_dir &
                               startsWith(arts$name, paste0(arg, "/"))]
        if (!length(rels)) {
          showNotification("这个文件夹是空的，没有可打包的内容",
                           type = "message", duration = 6)
          return()
        }
        # ★★ V16.10：这里**必须**按后台那道顶盘（`DSAPP_ZIP_BG_MAX`），不能用
        #   默认值。默认值就是 `DSAPP_ZIP_MAX`，而超限时 `dsapp_zip_plan()`
        #    直接回 `ok = FALSE` —— 于是下面那个"超过同步上限 → 转后台"的分支
        #    **永远走不到**：用户看到的还是老那句「少勾几个，或者单个下载」。
        #    ★ 这是探针 D 段抓出来的：文件页那条路从来没进过后台，而静态扫
        #      源码、自检、A 层全绿 —— 因为 `dsapp_zip_plan()` 本身没写错，
        #      错的是**调用点给的预算**。对话页那边一直是对的（它显式传了
        #      `max_bytes = DSAPP_ZIP_BG_MAX`），两边就差这一个参数。
        #    ⚠️ 三处调用点（右栏分组 / 右栏文件夹 / 勾选下载）**都要传** ——
        #      selftest 里有一条按行扫这条约定，漏一处就红。
        plan <- dsapp_zip_plan(rels, root, max_bytes = DSAPP_ZIP_BG_MAX)
        if (!isTRUE(plan$ok)) {
          # ★ V13.7 item 2：`stale` 那一类（勾选的东西在这期间没了）由平台
          #   自己刷新列表，不弹一句「请刷新页面」给用户。其余（超限、全是
          #   只读输入）是**说清楚就行**的事，照原文弹。
          if (isTRUE(plan$stale)) {
            dsapp_notify_stale("选中的文件",
                               refresh = function() ws_refresh(ws_refresh() + 1L))
          } else {
            showNotification(plan$msg, type = "error", duration = 10)
          }
          return()
        }
        zp_nm <- sprintf("%s-%d项.zip",
                         dsapp_safe_name(basename(arg)), plan$n)
        # ★ V16.10：超过同步上限就转后台（见 zip_start_bg 那段说明），
        #   而不是像以前那样一律弹「少勾几个」。
        if (as.numeric(plan$bytes) > DSAPP_ZIP_MAX) {
          zip_start_bg(list(list(root = root, rels = plan$rels, n = plan$n,
                                 bytes = plan$bytes)),
                       plan, zp_nm, "ws_dl")
          return()
        }
        ws_dl_pick(list(kind = "zip", rel = plan$rels, n = plan$n,
                        bytes = plan$bytes, sid = sid, name = zp_nm))
      } else if (identical(act, "zip")) {
        g <- Filter(function(x) identical(as.character(if (is.na(x$task_id)) 0L
                                                       else x$task_id), arg),
                    ws_groups())
        if (!length(g)) {
          # ws_groups 本身就是个 reactivePoll（2 秒一轮），下一次轮询自己
          # 就会把这一组去掉 —— 这里连刷新都不用推，说一句就行。
          dsapp_notify_stale("这一组")
          return()
        }
        g <- g[[1]]
        root <- dsapp_ws_dir(sid, cfg(), create = FALSE)
        if (is.na(root) || !dir.exists(root)) {
          showNotification("工作区已经不在了", type = "error")
          return()
        }
        # 先量一遍再触发下载：超限、文件被删，都要在浏览器开始下载
        # **之前**说清楚，否则用户拿到一个 0 字节的包。
        #
        # 只把**文件**交进去（V8 item 7）：dsapp_zip_plan 认目录，而 zip
        # 打目录是递归的 —— 目录和它里面的文件一起交进去，同一个文件会在
        # 包里出现两次。空目录进不了包，它自己那行的「打包下载」会明说
        # "这个文件夹是空的"，比打出一个空包强。
        plan <- dsapp_zip_plan(g$files$name[!g$files$is_dir], root, max_bytes = DSAPP_ZIP_BG_MAX)
        if (!isTRUE(plan$ok)) {
          if (isTRUE(plan$stale)) {
            dsapp_notify_stale("这一组里的文件",
                               refresh = function() ws_refresh(ws_refresh() + 1L))
          } else {
            showNotification(plan$msg, type = "error", duration = 10)
          }
          return()
        }
        zp_nm <- sprintf("%s-%d项.zip",
                         dsapp_safe_name(g$title), plan$n)
        # ★ V16.10：超限转后台（同上）。
        if (as.numeric(plan$bytes) > DSAPP_ZIP_MAX) {
          zip_start_bg(list(list(root = root, rels = plan$rels, n = plan$n,
                                 bytes = plan$bytes)),
                       plan, zp_nm, "ws_dl")
          return()
        }
        ws_dl_pick(list(kind = "zip", rel = plan$rels, n = plan$n,
                        bytes = plan$bytes, sid = sid, name = zp_nm))
      } else {
        return()
      }
      session$sendCustomMessage("dsapp:clickWhenReady", list(id = ns("ws_dl")))
    })

    # ---- 工作区产物的预览弹窗（V13.9 item 4）--------------------------------
    #
    # 用户原话：「言出法随的文件界面也需要支持预览」。
    #
    # ⚠️ 这里和对话页那个 art_preview_ui 是**两个** renderUI，不是不想合并
    #    —— 合并的前提是各自的 output id 都在同一个命名空间里，而预览里的
    #    表格要 DT::dataTableOutput(ns(...))，那个 id 必须由**模块自己**给。
    #    真正被共用的是下面那句 dsapp_preview_ui()：七种类型怎么渲染、体积
    #    闸门卡在哪、图片怎么不溢出弹窗，全在它一个地方，两边都调它。
    output$ws_preview_ui <- renderUI({
      v <- ws_view()
      if (is.null(v)) return(NULL)
      if (!file.exists(v$path)) {
        # 弹窗开着的时候文件被删了（另一个标签页里删的、任务重跑覆盖了）。
        # 不报错、不装死，说清楚就行。
        return(div(class = "alert alert-warning m-0",
                   "文件不存在 —— 可能已经被删掉或改名了。"))
      }
      size <- file.info(v$path)$size
      head <- div(class = "d-flex justify-content-between align-items-baseline mb-2",
        div(class = "text-truncate", tags$b(v$rel)),
        span(class = "small text-muted ms-2 flex-shrink-0",
             dsapp_fmt_bytes(size)))

      # 体积闸门和管理区同一条线（DSAPP_PREVIEW_MAX_BYTES，见 files.R）。
      # ⚠️ 这一道 dsapp_preview_ui() 自己也会判，但判在**函数里面**、返回的是
      #    NULL，外面接不住"为什么是 NULL"。这里先判一次，是为了让用户看到的
      #    是"超过上限了，请下载"，而不是一句没有主语的"不支持预览"。
      if (!is.na(size) && size > DSAPP_PREVIEW_MAX_BYTES) {
        return(tagList(head, div(class = "alert alert-secondary m-0",
          sprintf("超过在线预览上限 %s，请下载后查看。",
                  dsapp_fmt_bytes(DSAPP_PREVIEW_MAX_BYTES)))))
      }

      shared <- dsapp_preview_ui(
        v$path, session, cfg = cfg(), ns = ns,
        table_render = function(df) DT::dataTableOutput(ns("ws_preview_tbl")))
      if (!is.null(shared)) return(tagList(head, shared))

      # dsapp_preview_ui() 接不住的那两类：压缩包、二进制。
      # 口径和对话页的产物预览保持一致（那边也是这两句），用户在两处看到的
      # 说法必须一样，否则"为什么这里能看那里不能看"又成了一个新问题。
      kind <- dsapp_file_kind(v$rel)
      tagList(head, div(class = "alert alert-secondary m-0",
        if (kind == "archive")
          sprintf("压缩包（%s）。解压请点上面的「下载」拿回去展开。",
                  dsapp_fmt_bytes(size))
        else
          sprintf("这类二进制文件（%s）不支持在线预览，请下载后查看。",
                  dsapp_fmt_bytes(size))))
    })

    # ⚠️ 表格预览必须是自己一个 output：renderUI 里不能嵌套 renderDataTable。
    #    这和下面 output$preview_tbl 是同一个约束、同一种写法，只是喂进去的
    #    路径来源不同（那边是管理区选中的行，这边是弹窗里那个文件）。
    output$ws_preview_tbl <- DT::renderDataTable({
      v <- ws_view()
      req(v, file.exists(v$path))
      df <- dsapp_preview_table(v$path, n = 100)
      req(df)
      DT::datatable(df, rownames = FALSE,
                    options = list(dom = "t", pageLength = 10, scrollX = TRUE))
    })

    # 弹窗 footer 那颗「下载」：复用列表里那条通路（ws_dl + clickWhenReady），
    # 不另开一个 downloadHandler —— 两条路各写一遍 filename 规则，迟早有一
    # 条忘了 basename（理由见 output$ws_dl 上面那段）。
    observeEvent(input$ws_pv_dl, {
      v <- ws_view()
      req(v)
      if (!file.exists(v$path)) {
        return(showNotification("文件不在了。", type = "warning", duration = 6))
      }
      # ★ V14 item 3：`v$rel` 就是工作区相对路径（预览时算好存下来的），
      #   直接当 rel 传给 dsapp_dl_plan —— 这里**更要**传，因为下面那条
      #   fallback 是 normalizePath 推的，而 `v$path` 很可能是指向管理区的
      #   软链（实测数据里工作区产物大量是这种）。
      root <- dsapp_ws_dir(v$sid, cfg(), create = FALSE)
      plan <- dsapp_dl_plan(v$path, root, rel = v$rel, name = basename(v$rel))
      plan$sid <- v$sid
      ws_dl_pick(plan)
      session$sendCustomMessage("dsapp:clickWhenReady", list(id = ns("ws_dl")))
    })

    output$tbl <- DT::renderDataTable({
      df <- files()
      # ★ V16.10：目录在纯文本那一格里长什么样（📁 前缀）、目录的体积怎么
      #   写（"—"），由 `dsapp_files_rows()` 一处说了算 —— 对话页那张卡、
      #   这里这张表、右栏那些行，读的是同一个规则。
      if (nrow(df) == 0) {
        return(DT::datatable(
          # ★ V13.2 item 14：这两句原来写的是「用**上方**按钮上传」——
          #   上传区已经搬到表格下面了，照着这句话往上看是找不到按钮的。
          #   改成**不指方向**的说法（只说控件叫什么）：上传区将来再挪一次，
          #   这句话也还是对的。指向一个不存在的东西比不指更坏。
          data.frame(提示 = if (nzchar(current_dir()))
                       "这个文件夹是空的 —— 把文件拖进来，或点「上传文件」"
                       else "还没有文件 —— 把文件拖进来，或点「上传文件」"),
          options = list(dom = "t", ordering = FALSE),
          rownames = FALSE))
      }

      # ★ V16.10：目录在纯文本那一格里长什么样（📁 前缀）、目录的体积怎么
      #   写（"—"），由 `dsapp_files_rows()` 一处说了算 —— 对话页那张卡、
      #   这里这张表、右栏那些行，读的是同一个规则。
      #   ⚠️ 放在 `nrow(df) == 0` 那道提前返回**后面**：空表走的是另一张
      #      只有一列的提示表，用不上这四个字段。
      frows <- dsapp_files_rows(df)

      # 顺序已经在 files() 里定好了（目录在前、按名字排）。这里**不要**再排
      # 一次 —— 排在这里等于只排了显示的那一份，selected() 拿到的行号还是
      # 按 files() 的顺序取的，两边会对不上。
      shown <- data.frame(
        # ★ V13.5 item 4：第 0 列从「勾选用的小方块」换成「去预览」按钮。
        #
        #   用户原话：「文件管理把勾选用的小方块换成"去预览"按钮」。
        #
        #   原来这一列内容永远是空字符串，方框是 `select-checkbox` 这个类名
        #   用 CSS 画出来的（::before 画框、tr.selected 的 ::after 画 ✓）。
        #   现在里面是**真的文字**，靠 columnDefs 上那个 dsapp-dt-btn 类名
        #   （见下面）渲染成一个按钮的样子，点击由 tbl_cell_clicked 里
        #   col == 0 那一支接住。
        #
        #   ⚠️ 多选**没有丢**，只是换了手势：`.dsapp-dt-nowrap` 那张表的
        #      `select$selector` 从 `td:first-child` 放宽到整行（同 V13.4
        #      item 4 在任务页做的），点行内任意位置 = 勾选这一行。
        #      「下载选中 / 删除（N 项）」要的 input$tbl_rows_selected 照旧。
        #      —— 原来的设计里,方框是唯一的勾选入口,拿掉它就必须补一个,
        #      否则那几个按钮会永远停在"0 项"，而且不报错。
        #
        #   ⚠️ 表头那个"全选"方框**保留**（dsapp_dt_select_all 还是挂在
        #      第 0 列的表头上）。它管的是"整列全选"，和行内的按钮不冲突 ——
        #      而且批量下载/删除全靠它，去掉的话一次删十个文件得点十下。
        sel      = rep("去预览", nrow(df)),
        名称     = frows$dt_name,
        大小     = frows$size_h,
        修改时间 = df$mtime,
        上传者   = df$owner,
        stringsAsFactors = FALSE
      )
      shown$`_rel` <- df$rel   # 隐藏列：把行和相对路径绑死

      DT::datatable(
        shown,
        colnames = c("", "名称", "大小", "修改时间", "上传者", ""),
        # ⚠️ selection = "none" 是**必须的**，不是笔误：DT 自带的行选中
        #    （点行高亮、Ctrl 多选）和 Select 扩展是两套独立实现，同时开着
        #    会互相抢。勾选结果照样喂给 input$tbl_rows_selected —— DT 的
        #    绑定里有一段专门的分支（datatables.js:1007），条件是
        #    `selection.mode === 'none' && !server && 装了 Select 扩展`。
        selection = "none",
        extensions = "Select",
        rownames = FALSE,
        # ⚠️ 下标都变了（V7 item 9 插了 sel 列）：名称是 **1**、_rel 是 **5**。
        #    下面 cell_clicked 的 col 判断跟着一起改了，两处必须同步。
        options = list(
          dom = "tp", pageLength = 12, ordering = TRUE,
          # ★ V13.5 item 3：不换行 + 过宽横向滚，和任务页同一套。理由（含
          #   「为什么不用 DT 自带的 scrollX」）写在 R/mod_tasks.R 那段注释里。
          autoWidth = FALSE,
          # 表头全选方框（Select 1.7.0 没有这个功能，见 dsapp_dt_select_all）
          initComplete = dsapp_dt_select_all(),
          columnDefs = list(
            # ★ V13.5 item 4：第 0 列不再是复选框了。
            #   `select-checkbox` 那个类名去掉了 —— 留着的话 Select 扩展还会
            #   往里画一个 ::before 的空方框，和「去预览」四个字叠在一起。
            #   换成 dsapp-dt-btn：那是个**纯样式**的类名（www/app.css），
            #   把这一格画成按钮的样子。按钮上没有 JS 监听，点击由
            #   tbl_cell_clicked（col == 0）接住 —— 和「点名称进文件夹」
            #   走的是同一条路，不需要 shiny 的 actionButton，
            #   也就不会在 server = FALSE 的 DT 里失效。
            #
            #   orderable = FALSE 保留：这一列是动作列，按它排序没有意义 ——
            #   不关掉的话表头会带 `sorting` 类，点一下按"去预览"三个字排序。
            list(orderable = FALSE, className = "dsapp-dt-btn", targets = 0),
            list(className = "dt-left", targets = "_all"),
            list(visible = FALSE, targets = 5)
          ),
          # style = "multi" + td:first-child：**每次点方框是切换**（勾上/
          # 取消），而不是像文件管理器那样"点一下只留这一个"。
          #
          # ⚠️ 不要改成 "os"。那个模式下普通点击会**清掉**前面勾的，只有
          #    Ctrl/⌘ + 点击才追加 —— 而这里是复选框列，用户的心理模型就是
          #    "一个个勾"，没有理由要求他按住 Ctrl。浏览器实测抓到过：
          #    勾第二个之后按钮上写的是「下载 v7_beta.csv」（只剩一个）。
          #
          # ★ V13.5 item 4：selector 从 "td:first-child" 放宽到整行。
          #
          #   原来限制在第一列，是因为那一列是复选框 —— 点文件名不该误勾
          #   （点名字是想进目录）。现在第一列是「去预览」按钮，再把勾选锁在
          #   这一列上就自相矛盾了：点按钮会切换勾选（点两下就取消了），
          #   而别的地方**一个能勾的地方都没有**。
          #
          #   放宽之后：点行内任意位置 = 勾选这一行，勾选态由 tr.selected 的
          #   底色显示，和任务页（V13.4 item 4）完全一致。
          #   ⚠️ 点文件夹的名字仍然会**进目录**（那是 cell_clicked，另一条
          #      路），同时这一行也会被勾上 —— 和任务页"点标题 = 选中 + 看
          #      详情"是同一个取舍，用户明确要的就是这种"点一下就选中"。
          select = list(style = "multi", selector = "td")
        )
      )
    # ⚠️ `server = FALSE` 不能省，也不是性能取舍。
    #
    #    `renderDT` 的默认值是 server = TRUE，那样 options$serverSide 就是
    #    TRUE，而 DT 前端喂 rows_selected 的那段绑定（datatables.js:1007）
    #    明写着 `data.selection.mode === 'none' && !server && flagSelectExt`
    #    —— server 为真时整段跳过。表现**不是报错**：方框照画、点了照样
    #    高亮（那是 Select 扩展自己画的），只有 input$tbl_rows_selected
    #    永远是空的。于是按钮上的数字永远不动、"下载选中"下的永远是一个
    #    空集合。DT 自己在启动日志里 warning 过一句，很容易被当成噪音。
    }, server = FALSE)

    # ---- 工具栏 ----
    #
    # 按钮上的字跟着勾选数量走。这一条是 V7 item 9 的一半：光把表格改成
    # 多选还不够，用户得**看得见**自己勾了几个、点下去会发生什么
    # （单文件是直接下，多选/目录是打个包）。
    output$tbl_tools <- renderUI({
      r <- selected_rows()
      n <- if (is.null(r)) 0L else nrow(r)
      one_file <- n == 1L && !isTRUE(r$is_dir[1])
      one_dir  <- n == 1L && isTRUE(r$is_dir[1])

      dl_label <- if (n == 0L) "下载选中"
                  else if (one_file) sprintf("下载 %s", basename(r$rel[1]))
                  else if (one_dir) "打包下载这个文件夹"
                  else sprintf("打包下载（%d 项）", n)

      # ★ V16.10：超过同步上限的包转后台打，2 秒的活变成几分钟的活。用户看见
      #   的必须**不是**一个没反应的按钮 —— 进度文案和 disabled 是功能的一部分，
      #   不是装饰（原来超限是当场弹一句"少勾几个"，根本不会等）。
      #   ⚠️ 这句 `zip_job()` 是**普通读**（不是 isolate）：它就是这个 renderUI
      #      的失效源 —— 起包和收包各改一次它，按钮跟着变 enabled/disabled。
      #      `zip_start_bg()` 里那句读**必须**是 isolate 的，两处不一样是有意的。
      #   ⚠️ 不按 `job$out` 过滤：三个入口共用这一个后台位，谁在跑就都锁上
      #      （`zip_start_bg` 起的头，规则和那里保持一致）。
      zj <- zip_job()
      if (!is.null(zj)) {
        # ⚠️ 秒数得**自己**往前走：`zip_job()` 只在起包和收包时各变一次，光靠
        #    它当失效源的话这颗按钮会一直显示"已 0 秒"—— 那比不显示更像卡死。
        #    （打包那条 `observe` 里的 `invalidateLater(1000)` 只唤醒它自己，
        #    不会顺带唤醒这里。）忙完 zip_job 变 NULL，这个 renderUI 被它唤醒、
        #    重跑一遍就不再定时了，不会留一个空转的定时器。
        invalidateLater(1000)
        dl_label <- sprintf("正在打包…（已 %d 秒 · %s）",
                            as.integer(as.numeric(Sys.time()) - zj$t0),
                            dsapp_fmt_bytes(zj$bytes %||% 0))
      }

      tagList(
        div(class = "d-flex flex-wrap gap-2 mt-3",
          actionButton(ns("do_download"), dl_label,
                       class = "btn-sm btn-outline-primary",
                       # ⚠️⚠️ 这里**必须**写 `TRUE`，不能写 `NA`。
                       #   `shiny::actionButton()` 自己有一个 `disabled` 形参，
                       #   它内部是 `disabled = if (isTRUE(disabled)) NA else NULL`
                       #   —— 也就是说传 `NA` 进去，`isTRUE(NA)` 是 FALSE，属性
                       #   被**悄悄丢掉**，按钮永远不变灰。而 `tags$button`
                       #   （本仓另外三处用的那个）没有这层包装，`NA` 就老老实实
                       #   渲染成裸属性。
                       #   ★ 这是探针 D 段抓出来的：文案已经变成「正在打包…」
                       #     而 `is_disabled()` 一直是 False —— 用户能连点，前一个
                       #     包的句柄被冲掉（上面 `zip_start_bg` 那段说的就是这个）。
                       disabled = if (!is.null(zj)) TRUE else NULL,
                       icon = icon(if (one_file) "download" else "file-zipper")),
          actionButton(ns("mkdir"), "新建文件夹",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("folder-plus")),
          actionButton(ns("open"), "打开",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("folder-open")),
          actionButton(ns("move"), "改名 / 移动",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("arrows-up-down-left-right")),
          actionButton(ns("delete"),
                       if (n > 1L) sprintf("删除（%d 项）", n) else "删除",
                       class = "btn-sm btn-outline-danger",
                       icon = icon("trash"))
        ),
        # 真正的下载链接藏在这里 —— downloadButton 的标签改不了
        # （Shiny 的 download-link 绑定没有 receiveMessage），而且直接点
        # 它没有"先检查再决定"的机会：体积超限、选中的东西刚被别人删掉，
        # 这些都得在**浏览器开始下载之前**说清楚，否则用户拿到一个 0 字节
        # 的文件，只会以为下载坏了。所以走"按钮 → 服务端检查 → 触发"。
        div(class = "dsapp-hidden-dl",
            downloadButton(ns("download"), "下载")),
        div(class = "small text-muted mt-2",
            if (n == 0L)
              # ★★ V13.9 item 10：这句话原来是
              #      「勾选左侧的方框可以选中多个；选文件夹会连里面的内容一起打包。」
              #    它**从 V13.5 item 4 起就是错的** —— 那一版按用户要求把左侧
              #    那个勾选小方框换成了「去预览」按钮，从此最左边一列里
              #    一个方框都没有了。
              #
              #    用户照着这句话去做，看到的是「去预览」四个字；点下去不仅
              #    勾不上，还会把已经勾好的清掉（见 www/app.js 那段说明）。
              #    于是"文件页面不能多选打包下载"这个结论就是这么来的 ——
              #    功能一直在，是这句指路的话把人带到了错的地方。
              #
              #    现在这句话只描述**真实存在的手势**：点行内任意位置勾选、
              #    再点一下取消。指一个不存在的东西比不指更坏。
              tagList(icon("circle-info"),
                      " 点每行的任意位置勾选，再点一下取消；勾好多项后点左边那颗按钮打包下载。",
                      tags$br(),
                      " 选文件夹会连里面的内容一起打包。")
            else if (one_file)
              tagList(icon("circle-info"), " 将直接下载这个文件。")
            else if (any(r$is_dir))
              # 目录的体积要 du 才知道，而这里每 2 秒可能重算一次
              # （reactivePoll），不能量。宁可不报数字，也不报一个只算
              # 了文件、漏掉整个子目录的假数。
              tagList(icon("circle-info"),
                      sprintf(" 将打成 1 个 zip（%d 项，含文件夹）。", n))
            else
              tagList(icon("circle-info"),
                      sprintf(" 将打成 1 个 zip（共 %s）。",
                              dsapp_fmt_bytes(sum(r$size, na.rm = TRUE))))),
        if (n == 0L)
          div(class = "small text-muted mt-1",
              icon("circle-info"),
              " 文件夹要清空之后才能删 —— 一次点击不会连带删掉里面别人的数据。")
      )
    })

    # 点击「名称」列里的文件夹 = 进去。这是最自然的手势 —— 用户看到目录
    # 第一反应就是点它，而不是"先选中再找打开按钮"。
    #
    # 用 cell_clicked 而不是 rows_selected：后者是选中态，会被上面那些
    # 按钮共用；把"进目录"挂在选中上，用户为了看权限列随手点一下就被
    # 弹进子目录里了。
    # ⚠️ `col` 是 **0 基**的，而且数的是**数据列**（含隐藏的 `_rel`）。
    #    DT 源码 htmlwidgets/datatables.js 的 tweakCellIndex()：
    #        info.row += 1        ← 行是 1 基
    #        return {row, col: info.column}   ← 列原样给，0 基
    #    写成别的下标的后果不是"点不动"这么简单：
    #    ① 点「名称」列没反应（文件夹进不去），
    #    ② 点别的列**反而**进了文件夹 —— 用户只是想看看它多大。
    #    as.integer() 是防 jsonlite 在某些情况下把数字解析成 double。
    #
    #    V7 item 9 插了复选框列（第 0 列），所以「名称」从 0 变成 **1**。
    #    改表格列定义时必须回来改这里 —— 两处是一对的。
    # ★ V13.5 item 4：「去预览」按钮（第 0 列）。
    #
    #   用户原话：「文件管理把勾选用的小方块换成"去预览"按钮」。
    #
    #   这一列现在装的是**真的按钮**（columnDefs 上的 dsapp-dt-btn 类名画的，
    #   见 www/app.css），点它就切到右栏的预览。走 cell_clicked 而不是给每行
    #   塞一个 shiny::actionButton：后者在 `server = FALSE` 的 DT 里根本不会
    #   被绑定（DT 只对**服务端模式**做 input 绑定），点下去一声不响。
    #
    #   ⚠️ 原来这里还要照顾一件事：预览当时读的是 `selected()`（勾中的第一
    #      行），所以点「去预览」必须**先把这一行勾上**再让预览去读。而 Select
    #      扩展是**切换**语义（再点一下取消），不能直接 `api.row(i).select()`
    #      了事 —— 同一个文件点两次会把勾取消掉、预览反而空了。当时的写法是
    #      "先全部取消、再选这一行"（幂等，但会清掉用户攒的多选）。
    #
    #   ★ V13.9 item 10 起这层顾虑没有了：预览有自己的指针（pv_pick），
    #     点这一列就只是 `pv_pick(i)`，勾选原样不动。那套"先清再选"的写法
    #     已经**删掉**（R 这边和 www/app.js 那边一起）—— 它当初要解决的问题
    #     不存在了，留着它只会继续清用户的勾选。
    observeEvent(input$tbl_cell_clicked, {
      cl <- input$tbl_cell_clicked
      if (is.null(cl$row) || is.null(cl$value)) return()
      df <- files()
      i <- as.integer(cl$row)
      if (is.na(i) || i < 1 || i > nrow(df)) return()

      # 第 0 列 = 「去预览」。目录没有预览可看（预览是读文件内容那七支），
      # 点目录等同于"打开"它 —— 这比"点了没反应"好，而且和名称列的语义一致。
      if (identical(as.integer(cl$col), 0L)) {
        if (isTRUE(df$is_dir[i])) {
          current_dir(df$rel[i])
          return()
        }
        # ★★ V13.9 item 10：**只挪预览指针，一个勾都不动**。
        #
        #    改之前这里什么都不做，全靠 www/app.js 那个点击处理器在浏览器里
        #    写死 `api.rows().deselect(); row.select()` —— 那是为了让预览读到
        #    "刚点的这一行"（当时预览读的就是 selected()）。
        #
        #    代价就是用户报的那一条：勾了三项准备打包，点一下某一项的
        #    「去预览」看看内容，勾选被清得只剩一项。现在预览读
        #    preview_target()（见上面 pv_pick 那一段），服务端自己记得住
        #    "在看哪一个"，就没有理由再去动勾选了。
        #
        #    ⚠️ JS 那一侧同一个处理器也一并改了（www/app.js）：它只对
        #       `.dsapp-dt-btn` 这一列的点击生效，现在改成"不碰勾选"。
        #       两边必须一起改 —— 只改一边的话，浏览器里那一下照旧清空，
        #       服务端这边的克制完全看不出来。
        pv_pick(i)
        return()
      }

      # 点了「名称」列 = 换了个要看的东西。把预览指针挪过去，右栏跟着走
      # （原来靠的是"点名称顺便勾上这一行 + 预览跟 selected()"，现在勾选
      #  和预览分家了，得在这里显式说一声）。
      #
      # ⚠️ 只在**文件**上做：点目录是进目录，右栏那时候显示的是新目录里
      #    还没选中的状态，硬留一个上一层的行号只会对错行。目录那一支在
      #    下面 `return()` 之前顺手把指针清掉。
      if (identical(as.integer(cl$col), 1L) && !isTRUE(df$is_dir[i])) {
        pv_pick(i)
        return()
      }

      if (!identical(as.integer(cl$col), 1L)) return()   # 只有「名称」列
      if (!isTRUE(df$is_dir[i])) return()    # 文件点了不做事
      # 进目录 = 换了一张表，旧的预览指针指向的是**上一层**的第 i 行，
      # 留着只会让右栏在新目录里显示一个对不上的文件（见 preview_target
      # 里那句"指针失效就退回勾选"）。这里显式清掉，比指望那边兜底清楚。
      pv_pick(NULL)
      current_dir(df$rel[i])
    })

    # ---- 上传 ----
    #
    # 单文件和文件夹走的是同一条路。差别只有两处：文件夹要多带一份相对路径
    # （见 dsapp_file_save 的 rel），以及进度条上的措辞。所以抽成一个函数，
    # 两个 observeEvent 各调一次 —— 复制一份出来的话，以后修 bug 只会修到
    # 其中一个，另一个（用户不常走的文件夹那条）就烂在那儿了。
    #
    # @param paths 文件夹上传时浏览器报回来的相对路径向量，顺序和 up 的行
    #   一致；单文件上传传 NULL。
    perform_upload <- function(up, which_input, paths = NULL) {
      n <- nrow(up)

      # 相对路径和文件行靠**下标**对齐（两边都按 FileList 的顺序）。
      # 对不上就退回文件名 —— 宁可平铺，也不能把 A 的路径安到 B 头上：
      # 那会让文件落进别人的目录里，而且看不出错。
      rels <- rep(NA_character_, n)
      if (!is.null(paths) && length(paths) == n) {
        rels <- as.character(paths)
      } else if (!is.null(paths) && length(paths)) {
        used <- rep(FALSE, length(paths))
        for (i in seq_len(n)) {
          hit <- which(!used & basename(paths) == up$name[i])
          if (length(hit)) { rels[i] <- paths[hit[1]]; used[hit[1]] <- TRUE }
        }
      }
      total <- sum(up$size, na.rm = TRUE)
      output$upload_status <- renderUI(
        div(class = "alert alert-info py-2 small",
          icon("spinner", class = "fa-spin"),
          sprintf(" 正在接收 %d 个文件（共 %s）……", n, dsapp_fmt_bytes(total)),
          div(class = "text-muted mt-1",
              "大文件写入需要一点时间，请不要关闭页面。")
        )
      )

      # 上传到**当前所在的这一层**。进目录之前先把它读出来存成局部变量：
      # 下面循环里可能跑几分钟，期间用户完全可能点面包屑换目录，那时
      # 再读 current_dir() 会让同一批文件散落到两个地方。
      target_dir <- current_dir()

      saved <- character(0)
      failed <- character(0)
      for (i in seq_len(n)) {
        res <- dsapp_file_save(
          list(name = up$name[i], datapath = up$datapath[i]), cfg(),
          user_id = state$user_id, dir = target_dir, rel = rels[i])
        if (isTRUE(res$ok)) {
          saved <- c(saved, res$msg)   # res$msg 是相对共享区根的路径
          # 登记归属。共享区对所有登录用户可见，但"谁能改名/删除"看这个。
          # ⚠️ 键必须是**相对路径**（res$msg），和 file_owner.name 的语义
          #    对齐；用 basename 的话子目录里的文件会登记成根目录下的一个
          #    名字，那个名字对应的文件其实不存在 —— 归属行指向空气，
          #    真文件反而无主（人人可删）。
          try(dsapp_file_owner_set(res$msg, state$user_id, con = dsapp_db(cfg())),
              silent = TRUE)
        } else {
          failed <- c(failed, res$msg)
        }
      }

      # 把 input 重置掉。不重置的话，连续上传**同名文件**时第二次不会
      # 触发 input$upload（浏览器认为选中项没变），用户看到的是"点了没反应"。
      session$sendCustomMessage("dsapp:resetUpload", list(id = ns(which_input)))

      # 一次上传记**一行**，文件名列在 target 里（截断到 500 字，见
      # dsapp_audit）。一批 200 个小文件记 200 行只会把日志淹掉，
      # 而管理员想知道的是"谁在什么时候传了一批什么"。
      if (length(saved)) {
        audit("file_upload", target = paste(saved, collapse = "、"),
              detail = sprintf("到 %s，%d 个",
                               if (nzchar(target_dir)) target_dir else "根目录",
                               length(saved)))
      }
      if (length(failed)) {
        audit("file_upload", target = paste(failed, collapse = "、"),
              detail = "上传失败", ok = FALSE)
      }

      output$upload_status <- renderUI({
        if (!length(failed)) {
          div(class = "alert alert-success py-2 small",
            icon("circle-check"),
            sprintf(" 已上传 %d 个文件：%s", length(saved),
                    paste(saved, collapse = "、")),
            div(class = "text-muted mt-1", "现在可以在「言出法随」页让 AI 使用它们了。")
          )
        } else if (!length(saved)) {
          div(class = "alert alert-danger py-2 small",
            icon("circle-xmark"), " 上传失败：",
            paste(failed, collapse = "、"))
        } else {
          div(class = "alert alert-warning py-2 small",
            icon("triangle-exclamation"),
            sprintf(" 成功 %d 个，失败 %d 个。", length(saved), length(failed)),
            div(class = "mt-1", paste(failed, collapse = "、")))
        }
      })
      refresh(refresh() + 1)
    }

    # 大文件（几 GB 的 h5ad/bam）上传要几分钟，期间浏览器有自己的进度条，
    # 但那是 Shiny 的全局进度条，用户不一定注意到。所以进来先给一条
    # "正在接收"，让用户知道点击生效了（在 perform_upload 里）。
    observeEvent(input$upload, {
      req(input$upload)
      perform_upload(input$upload, "upload")
    })

    # 文件夹上传（V9 item 12）。路径走另一条输入 upload_dir_paths，
    # 由 www/app.js 在捕获阶段填好 —— 它在 Shiny 自己那个 change 处理器
    # 之前就发出去了，所以这里读的时候一定已经是这一批的路径。
    observeEvent(input$upload_dir, {
      req(input$upload_dir)
      perform_upload(input$upload_dir, "upload_dir", input$upload_dir_paths)
    })

    # ---- 当前选中 ----
    #
    # 返回的是一整行（含 rel / is_dir / owner），不只是名字：下面每个操作
    # 都要判"这是文件还是目录""我有没有权限动它"，各自再去 files() 里
    # 查一遍行号，迟早会因为排序不一致而对错行。
    #
    # V7 item 9 起是**多选**（Select 扩展的复选框）。两个入口：
    #   * `selected_rows()` —— 勾中的全部，下载和删除用
    #   * `selected()`      —— 只取第一行，预览 / 打开 / 改名移动用
    #     （这三个动作一次只对一个目标有意义，"移动 3 个文件到哪"没有答案）
    selected_rows <- reactive({
      i <- input$tbl_rows_selected
      df <- files()
      if (is.null(i) || length(i) == 0 || nrow(df) == 0) return(NULL)
      i <- i[!is.na(i) & i >= 1 & i <= nrow(df)]
      if (!length(i)) return(NULL)
      # 按行号排序：DT 本来就按表格顺序给，但下面"第一行"要的是**稳定的**
      # 那一条，不能依赖这个实现细节。
      df[sort(i), , drop = FALSE]
    })

    selected <- reactive({
      r <- selected_rows()
      if (is.null(r)) NULL else r[1, , drop = FALSE]
    })

    # ★★ V13.9 item 10：右栏预览**不再寄生在勾选上**。
    #
    #   用户原话：「文件页面需要能够多选打包下载」。
    #
    #   多选本身是好的（实测点名称列连点三下 = 「打包下载（3 项）」），
    #   坏的是**它会被「去预览」悄悄清掉** —— 从 V13.5 item 4 起，那一列
    #   的点击处理器在浏览器里写死了 `api.rows().deselect(); row.select()`，
    #   为的是让预览读到"刚点的这一行"。代价是：用户勾了三项准备打包，
    #   顺手点一下某一项的「去预览」看看内容，回来勾选只剩一项，
    #   按钮从「打包下载（3 项）」变成「下载 xxx.csv」，而且**不报错**
    #   —— 用户只会觉得"这个多选时灵时不灵"。
    #
    #   根子在于"预览谁"和"勾了谁"本来是两件事，被塞进了同一个 reactive。
    #   拆开：预览有自己的指针（pv_pick），勾选归勾选。这样
    #   ① 看预览不动勾选；② 没点过「去预览」时预览仍旧跟着勾选走
    #   （点一行顺便看内容，这个手感要保住）。
    preview_target <- reactive({
      df <- files()
      i <- pv_pick()
      if (!is.null(i) && length(i) == 1 && !is.na(i) &&
          i >= 1 && i <= nrow(df)) {
        return(df[i, , drop = FALSE])
      }
      # 指针失效了（换目录、行数变了）就退回勾选 —— 不抱着一个陈旧的行号
      # 去取新表里的第 i 行，那是"点 A 看见 B"的经典成因。
      selected()
    })

    # 选中的那一行的相对路径（很多地方只用得上这个）
    #
    # ⚠️ 预览那三处（title / preview / preview_tbl）现在读 preview_target()，
    #    其余（打开、改名移动、删除）仍旧读 selected() —— 那些动作的对象
    #    就该是"勾选"，不是"正在看的那一个"。
    selected_rel <- reactive({
      s <- preview_target()
      if (is.null(s)) NULL else s$rel[[1]]
    })

    # 权限：自己的、无主的（公共）随便动，别人的只有管理员能动。
    # 目录没有归属行（file_owner 只登记文件），所以目录对所有人放行 ——
    # 真正的保险是"必须清空才能删"和服务器的目录权限。
    can_edit <- function(rel) {
      dsapp_file_can_edit(rel, state$user, con = dsapp_db(cfg()))
    }

    output$preview_title <- renderText({
      # ★ V13.9 item 10：读 preview_target()，不是 selected() —— 理由见上面
      #   pv_pick 那一段（看预览不该动勾选）。
      s <- preview_target()
      if (is.null(s)) "预览" else s$rel[[1]]
    })

    # ---- 预览 ----
    output$preview <- renderUI({
      # ★ V13.9 item 10：这里原来读 selected()。改成 preview_target() 之后，
      #   预览跟着"刚点的那一行"走，而勾选**原样留着** —— 用户勾了三项准备
      #   打包，中途看一眼某一项的内容，回来那三项还在。
      s <- preview_target()
      if (is.null(s)) {
        return(p(class = "text-muted small p-3", "在左侧选择一个文件查看内容。"))
      }
      if (isTRUE(s$is_dir[[1]])) {
        # 目录没有"预览"这回事。这里给的是里面的条目数和总大小 ——
        # 比一句"这是文件夹"有用：用户点开目录最想知道的就是"里面有多大"。
        rel <- s$rel[[1]]
        p <- dsapp_file_path(rel, cfg())
        inner <- if (is.null(p) || !dir.exists(p)) character(0)
                 else list.files(p, all.files = FALSE, no.. = TRUE)
        sz <- if (length(inner)) sum(file.size(file.path(p, inner)), na.rm = TRUE) else 0
        return(div(class = "p-3",
          p(class = "mb-1", icon("folder-open"), " ", tags$b(rel)),
          p(class = "small text-muted mb-0",
            sprintf("文件夹：%d 个条目，共 %s", length(inner),
                    dsapp_fmt_bytes(sz))),
          if (!length(inner))
            p(class = "small text-muted mb-0", "（空的）")
        ))
      }
      s <- s$rel[[1]]
      path <- dsapp_file_path(s, cfg())
      if (is.null(path)) {
        return(div(class = "alert alert-warning m-3", "文件不存在或名称非法。"))
      }

      size <- file.info(path)$size

      # ★ V13.4 item 5a：html / markdown / image / pdf / table / text / 二进制
      #   那七支整个搬进了 dsapp_preview_ui()（R/files.R）—— 任务页要"点文件名
      #   就预览"，而这几支里每一行都是踩过坑才写成这样的（体积闸门、CSP、
      #   会话级地址、列名修补）。抄一份过去等于把坑重新挖一遍。
      #
      # ⚠️ 搬走的是**函数体**，不是行为：参数原样传，返回的东西一模一样。
      #    唯一的变化是表格那一支通过 table_render 回调拿 DT 的输出 id ——
      #    下面这个 output$preview_tbl 因此一行都没动。
      shared <- dsapp_preview_ui(
        path, session, cfg = cfg(), ns = ns,
        table_render = function(df) DT::dataTableOutput(ns("preview_tbl")))
      if (!is.null(shared)) return(shared)

      kind <- dsapp_file_kind(s)

      if (kind == "archive") {
        # 压缩包不解到共享区，解到**当前对话的工作区**（见 files.R 里
        # dsapp_archive_extract 的说明）。所以这里必须把去向写在按钮旁边，
        # 不然用户点完不知道东西去哪了 —— 共享区里找不到，工作区在哪
        # 他也没概念。
        sid <- state$chat_session_id
        return(div(class = "p-3",
          p(class = "small mb-2",
            sprintf("压缩包（%s）。", dsapp_fmt_bytes(size))),
          if (is.null(sid)) {
            div(class = "alert alert-warning py-2 small mb-0",
              icon("triangle-exclamation"),
              paste0(" 先到「言出法随」页打开一个对话。压缩包会解到那个对话的",
                     "工作区里 —— 文件管理区是平铺的，几百个文件倒进去就没法看了。"))
          } else {
            tagList(
              p(class = "small text-muted",
                sprintf("解压到 %s（本对话的工作区），不会动文件管理区里的原包。",
                        db_session_label(sid, con = dsapp_db(cfg())))),
              actionButton(ns("do_extract"), "解压到本对话工作区",
                           class = "btn-sm btn-primary",
                           icon = icon("file-zipper"))
            )
          }))
      }

      # 二进制：不给预览，引导下载
      div(class = "alert alert-secondary m-3",
          sprintf("二进制文件（%s），不支持在线预览，请下载后查看。",
                  dsapp_fmt_bytes(size)))
    })

    # 表格预览要单独一个 output —— renderUI 里不能嵌套 renderDataTable
    output$preview_tbl <- DT::renderDataTable({
      s <- selected_rel()
      req(s)
      df <- dsapp_preview_table(dsapp_file_path(s, cfg()), n = 100)
      req(df)
      DT::datatable(df, rownames = FALSE,
                    options = list(dom = "t", pageLength = 15, scrollX = TRUE))
    })

    # ---- 下载（单文件直下 / 多选与目录打包）----
    #
    # V7 item 9：以前表格是单选，"下载选中文件"最多只能下一个；选中一个
    # 文件夹点它更糟 —— `file.copy` 一个目录必定失败，浏览器那边静悄悄地
    # 得到一个 0 字节文件，没有任何提示。
    #
    # 现在的分工：`do_download` 按钮负责**先检查再说清楚**（体积超限、
    # 选中的东西刚被别人删掉），检查过了才去触发那个藏着的 downloadButton
    # （Shiny 的 downloadHandler 没有"失败就取消"的钩子，只能这么绕）。
    dl_pick <- reactiveVal(NULL)

    observeEvent(input$do_download, {
      r <- selected_rows()
      if (is.null(r)) {
        showNotification("先在列表里勾选要下载的文件", type = "warning")
        return()
      }
      one_file <- nrow(r) == 1L && !isTRUE(r$is_dir[1])

      if (!one_file) {
        # 打包前先量一遍。量不过去就当场说清楚，别让用户下一个坏包。
        # ★★ V16.10：按后台那道顶盘 —— 理由和上面「右栏分组」那处一模一样
        #    （默认值 = 同步那道顶，超限时 plan 直接 ok=FALSE，下面那个转后台
        #    的分支就成了够不着的死代码）。
        plan <- dsapp_zip_plan(r$rel, cfg()$files_dir, max_bytes = DSAPP_ZIP_BG_MAX)
        if (!isTRUE(plan$ok)) {
          if (isTRUE(plan$stale)) {
            dsapp_notify_stale("选中的文件",
                               refresh = function() refresh(refresh() + 1L))
          } else {
            showNotification(plan$msg, type = "error", duration = 10)
          }
          return()
        }
        zp_nm <- sprintf("%s-%d项.zip",
                         if (nzchar(current_dir()))
                           basename(current_dir()) else "文件管理区",
                         plan$n)
        # ★ V16.10：超过同步上限 → 转后台（同右栏那两处）。这里原来是
        #   "弹一句『少勾几个』"，而勾选下载确实还有"少勾几个"这个选项 ——
        #   但两页对同一件事给两套说法本身就是漂移，而且用户勾了一个大文件夹
        #   时"少勾几个"根本不成立（他就要那个文件夹里的全部）。
        if (as.numeric(plan$bytes) > DSAPP_ZIP_MAX) {
          zip_start_bg(list(list(root = cfg()$files_dir, rels = plan$rels,
                                 n = plan$n, bytes = plan$bytes)),
                       plan, zp_nm, "download")
          return()
        }
        dl_pick(list(kind = "zip", rel = plan$rels, bytes = plan$bytes,
                     n = plan$n, name = zp_nm))
      } else {
        p <- dsapp_file_path(r$rel[1], cfg())
        if (is.null(p)) {
          dsapp_notify_stale("这个文件",
                             refresh = function() refresh(refresh() + 1L))
          return()
        }
        # ★ V14 item 3：管理区这边的 rel 也在手上（就是勾选那一行的
        #   `r$rel`），直接传，别让 dsapp_dl_plan 去推。
        dl_pick(dsapp_dl_plan(p, cfg()$files_dir, rel = r$rel[1],
                              name = basename(r$rel[1])))
      }
      session$sendCustomMessage("dsapp:clickWhenReady", list(id = ns("download")))
    })

    # ★★ 这个 output 的 `suspendWhenHidden` 必须关掉，否则**它永远不会被算出来**。
    #
    # 下载按钮本身是看不见的（`.dsapp-hidden-dl`），点它靠的是
    # `dsapp:clickWhenReady` 在元素上补一次 `.click()` —— 所以它必须在 DOM 里。
    # 而 Shiny 对"看不见的输出"有一套挂起机制（`ShinySession$shouldSuspend`）：
    #
    #     hidden <- clientData$get(paste0("output_", name, "_hidden"))
    #     if (is.null(hidden)) hidden <- TRUE     # 客户端没报告过 = 当作隐藏
    #     return(hidden && getOutputOption(name, "suspendWhenHidden", TRUE))
    #
    # 注意中间那行的默认值：**客户端没报告过的输出一律按"隐藏"处理**。而这个
    # 元素要等 renderUI 渲染出来、被 Shiny 绑定之后，客户端才第一次报告它的
    # 可见性 —— 也就是说在会话刚起步时它必然是"隐藏"的，于是被挂起、值不下发。
    # 结果是 `renderValue` 从没被调用过，`<a>` 的 href 一直是空串。
    #
    # 空 href 的 `<a>` 一点，浏览器就导航到当前地址 —— 用户拿回来一个首页的
    # HTML，而不是文件（这个 bug 在界面上完全不报错，只在下载目录里留一个
    # 打不开的 `.zip`）。把按钮改成可见的也一样：改完还得等客户端把新的可见性
    # 报回服务端，中间那段空窗期点是同样下场的。
    #
    # `outputOptions(suspendWhenHidden = FALSE)` 是官方给的出口。关掉之后值在
    # 会话起步时就算好、下发到客户端缓存，元素后来才出现也没关系 ——
    # 客户端绑定新元素时会把缓存里的值补上（shiny.js 的 `ShinyApp$bindOutput`：
    # `if (this.$values[id] !== void 0) binding.onValueChange(this.$values[id])`）。
    #
    # 下载 URL 是**定值**（downloadHandler 只注册一次，filename/content 是
    # 取文件时才调用的函数），所以一次下发、长期有效，不存在"下到上一次那个
    # 文件"的问题。
    output$download <- downloadHandler(
      # 下载名用 basename：`rel` 里的 `/` 会被浏览器当成路径分隔符
      # （在 Linux 上直接失效，在 Windows 上会被改写成下划线）。
      filename = function() basename((dl_pick() %||% list())$name %||% "download"),
      content = function(file) {
        d <- dl_pick()
        if (is.null(d)) return(invisible())
        # ★ V16.10：后台打好的包（超限那条路）。**必须排在下面那个
        #   `!identical(d$kind, "zip")` 之前** —— 那一支会把 zipbg 当成单个
        #   文件喂给 dsapp_dl_write()，而 zipbg 压根没有 `d$path` 之外的东西，
        #   用户拿到一个 0 字节的包，服务端一声不吭。右栏 `output$ws_dl`
        #   同一个位置有一样的注释（两处都是被这条咬过一次才写的）。
        if (identical(d$kind, "zipbg")) {
          ok <- dsapp_zip_bg_handoff(file, d$path)
          if (!ok) {
            try(dsapp_audit("file_download", user = state$user,
                            user_id = state$user_id,
                            target = d$name %||% "", ok = FALSE,
                            detail = "打包好的文件不见了（临时目录被清理）",
                            session = session, cfg = cfg()), silent = TRUE)
          }
          return(invisible())
        }
        if (!identical(d$kind, "zip")) {
          # ★ V14 item 3：file 和 html 两支都走共用那一份。
          dsapp_dl_write(file, d)
          return(invisible())
        }
        res <- dsapp_zip_write(file, list(ok = TRUE, rels = d$rel,
                                          n = d$n, bytes = d$bytes),
                               cfg()$files_dir)
        if (!isTRUE(res$ok)) {
          # 走到这里说明"检查过之后、打包之前"文件被删了（多标签页下会
          # 发生）。日志留一条，界面上没法再提示了 —— 下载已经开始。
          try(dsapp_audit("file_download", user = state$user,
                          user_id = state$user_id,
                          target = paste(utils::head(d$rel, 5), collapse = "、"),
                          detail = as.character(res$msg %||% ""), ok = FALSE,
                          session = session, cfg = cfg()), silent = TRUE)
        }
      }
    )
    outputOptions(output, "download", suspendWhenHidden = FALSE)

    # ---- 解压 ----
    observeEvent(input$do_extract, {
      s <- selected_rel()
      if (is.null(s)) {
        showNotification("请先选择一个压缩包", type = "warning")
        return()
      }
      sid <- state$chat_session_id
      if (is.null(sid)) {
        showNotification("先到「言出法随」页打开一个对话，再回来解压", type = "warning")
        return()
      }
      # 解压是同步的，大包要几十秒。给个"正在解"的提示，否则用户以为没点上，
      # 会连点好几次 —— 每一次都在工作区里重新解一份。
      showNotification(sprintf("正在解压 %s …", s), type = "message",
                       duration = NULL, id = "dsapp_extract")
      on.exit(removeNotification("dsapp_extract"), add = TRUE)

      r <- dsapp_archive_extract(s, sid, cfg(), user_id = state$user_id)
      # 解压会在工作区里铺开一大堆文件（见 dsapp_archive_extract 的防炸逻辑），
      # 磁盘突然涨起来时这条日志是第一个该看的地方。
      audit("file_extract", target = s, ok = isTRUE(r$ok),
            detail = sprintf("到对话 %s", sid))
      if (!isTRUE(r$ok)) {
        showNotification(r$msg, type = "error", duration = 12)
        return()
      }

      # 成功的那句话由 dsapp_archive_extract 给（含丢了多少软链），这里只补
      # 告警。**不要**在这儿重拼一遍 —— 两处拼同一句话，早晚会有一处忘了改。
      msg <- r$msg
      if (!is.null(r$warn)) {
        msg <- paste0(msg, "；解压程序有告警，个别条目可能没解开")
      }
      showNotification(msg, type = "message", duration = 15)
      # 解出来的东西在工作区里，两个列表都要刷
      refresh(refresh() + 1)
      ws_refresh(ws_refresh() + 1)
    })

    # ---- 打开选中的文件夹 ----
    observeEvent(input$open, {
      s <- selected()
      if (is.null(s)) {
        showNotification("请先在列表里选一个文件夹", type = "warning")
        return()
      }
      if (!isTRUE(s$is_dir[[1]])) {
        showNotification("选中的是文件，不是文件夹", type = "warning")
        return()
      }
      current_dir(s$rel[[1]])
    })

    # ---- 新建文件夹 ----
    observeEvent(input$mkdir, {
      d <- current_dir()
      showModal(modalDialog(
        title = "新建文件夹",
        textInput(ns("new_dir"), "文件夹名字", value = "",
                  placeholder = "例如 GSE123 或 GSE123/raw"),
        div(class = "small text-muted",
            sprintf("建在：%s", if (nzchar(d)) d else "文件管理区根目录"),
            tags$br(),
            "可以敲 ",
            tags$code("GSE123/raw"),
            " 这样一次建多级。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_mkdir"), "创建", class = "btn-primary")
        )
      ))
    })

    observeEvent(input$do_mkdir, {
      nm <- input$new_dir
      req(nm, nzchar(trimws(nm)))
      res <- dsapp_dir_create(current_dir(), trimws(nm), cfg(),
                              user_id = state$user_id)
      removeModal()
      audit("file_mkdir", target = as.character(res$rel %||% nm),
            ok = isTRUE(res$ok),
            detail = if (isTRUE(res$ok)) "" else as.character(res$msg %||% ""))
      if (isTRUE(res$ok)) {
        showNotification(res$msg, type = "message")
        # 建完直接进去。建了多级目录却停在原地，用户还要自己一层层点下去
        # 才知道建成了没有。
        current_dir(res$rel)
      } else {
        showNotification(res$msg, type = "error", duration = 8)
      }
      refresh(refresh() + 1)
    })

    # ---- 改名 / 移动 ----
    #
    # 一个对话框干两件事：改名 = 改路径的最后一段，移动 = 改前面的部分。
    # 在文件系统层面它们本来就是同一个 rename（见 dsapp_entry_move 的说明），
    # 界面上硬拆成两个只会让"改名到别的目录里"这种操作落进缝里。
    observeEvent(input$move, {
      s <- selected()
      if (is.null(s)) {
        showNotification("请先在列表里选一个文件或文件夹", type = "warning")
        return()
      }
      rel <- s$rel[[1]]
      if (!can_edit(rel)) {
        showNotification(
          sprintf("「%s」是别人上传的，只有管理员能改名或移动。", rel),
          type = "warning", duration = 8)
        return()
      }
      dirs <- tryCatch(dsapp_shared_dirs(cfg()), error = function(e) character(0))
      showModal(modalDialog(
        title = if (isTRUE(s$is_dir[[1]])) "改名 / 移动文件夹" else "改名 / 移动文件",
        textInput(ns("move_to"), "新位置", value = rel, width = "100%"),
        div(class = "small text-muted mb-2",
            "改最后一段 = 改名；改前面的部分 = 移动到别的文件夹。"),
        # 下拉里显式给出「共享区根目录」：把文件从子目录里搬回根是常见操作，
        # 而它对应的目标路径是空串 —— 那是「（不移动）」的值，不能复用，
        # 所以给根目录一个哨兵值，在 do_move 里换回空串。
        selectInput(ns("move_dir"), "或直接移动到（保持原名）",
                    choices = c("（不移动）" = "",
                                "文件管理区根目录" = DSAPP_MOVE_ROOT,
                                stats::setNames(dirs, dirs)),
                    width = "100%"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_move"), "确定", class = "btn-primary")
        )
      ))
    })

    observeEvent(input$do_move, {
      s <- selected()
      req(s)
      rel <- s$rel[[1]]
      d <- input$move_dir %||% ""
      keep <- nzchar(d)
      to <- if (keep) d else trimws(input$move_to %||% "")
      # 哨兵换回空串：dsapp_entry_move 的 `to = ""` 配合 keep_name = TRUE
      # 就是"搬回共享区根目录、名字不变"。
      if (identical(to, DSAPP_MOVE_ROOT)) to <- ""
      if (!keep && !nzchar(to)) {
        showNotification("新位置不能为空", type = "warning")
        return()
      }
      res <- dsapp_entry_move(rel, to, cfg(), keep_name = keep)
      removeModal()
      # 被拒绝的移动也要记：改别人的文件会走到这里，那正是需要留痕的时刻。
      audit("file_rename", target = rel, ok = isTRUE(res$ok),
            detail = if (isTRUE(res$ok)) sprintf("→ %s", as.character(res$rel))
                     else as.character(res$msg %||% ""))
      if (isTRUE(res$ok)) {
        showNotification(res$msg, type = "message")
        # 跳到**目标所在的目录**。东西被搬出当前这一层之后，停在原地会
        # 让它看起来凭空消失了 —— 用户的第一反应是"我刚才是不是删掉了"，
        # 然后回去重做一遍。
        # 原地改名时 dirname 就是当前这一层，这一行等于什么都没做。
        d <- dirname(res$rel)
        current_dir(if (identical(d, ".")) "" else d)
      } else {
        showNotification(res$msg, type = "error", duration = 8)
      }
      refresh(refresh() + 1)
    })

    # ---- 删除 ----
    #
    # V7 item 9 起表格是多选的，勾了三行点删除只删掉第一行是最难解释的
    # 一种失败 —— 用户明明看见三个都勾着。所以这里按勾选的全部删，
    # 和任务页的「删除选中」是同一套语义。
    #
    # ⚠️ 有权限的删、没权限的**不删也不阻断**，最后一起报账。整批中止的话
    #    用户得自己一个个试出"哪些是别人的"；默默跳过不说的话他会以为
    #    都删掉了。
    observeEvent(input$delete, {
      r <- selected_rows()
      if (is.null(r)) {
        showNotification("请先在列表里勾选要删除的文件或文件夹", type = "warning")
        return()
      }
      rels <- r$rel
      blocked <- rels[!vapply(rels, can_edit, logical(1))]
      todo <- setdiff(rels, blocked)

      if (!length(todo)) {
        showNotification(
          sprintf("「%s」是别人上传的，只有管理员能删除。",
                  paste(utils::head(blocked, 3), collapse = "、")),
          type = "warning", duration = 8)
        return()
      }

      is_dir <- any(r$is_dir[r$rel %in% todo])
      showModal(modalDialog(
        title = if (length(todo) > 1L) sprintf("确认删除 %d 项", length(todo))
                else if (is_dir) "确认删除文件夹" else "确认删除",
        tagList(
          if (length(todo) == 1L) {
            if (is_dir) sprintf("确定要删除文件夹「%s」吗？", todo)
            else sprintf("确定要删除「%s」吗？此操作不可撤销。", todo)
          } else {
            tagList(
              sprintf("确定要删除这 %d 项吗？此操作不可撤销。", length(todo)),
              div(class = "small text-muted mt-2",
                  paste(utils::head(todo, 12), collapse = "、"),
                  if (length(todo) > 12) sprintf(" 等 %d 项", length(todo)) else NULL)
            )
          },
          if (is_dir)
            div(class = "small text-muted mt-2",
                "文件夹必须是空的才能删。里面有东西的话会提示你先清空 —— ",
                "这一下不会连带删掉别人放在里面的数据。"),
          if (length(blocked))
            div(class = "small text-warning mt-2",
                sprintf("其中 %d 项是别人上传的，会被跳过：%s",
                        length(blocked),
                        paste(utils::head(blocked, 3), collapse = "、")))
        ),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_delete"),
                       if (length(todo) > 1L) sprintf("删除 %d 项", length(todo))
                       else "删除",
                       class = "btn-danger")
        )
      ))
    })

    observeEvent(input$do_delete, {
      r <- selected_rows()
      req(r)
      rels <- r$rel
      todo <- rels[vapply(rels, can_edit, logical(1))]
      if (!length(todo)) { removeModal(); return() }

      ok <- character(0); bad <- character(0)
      for (rel in todo) {
        res <- dsapp_entry_delete(rel, cfg())
        # 删除是共享区里唯一**不可逆**的操作，无论成败都记。
        audit("file_delete", target = rel, ok = isTRUE(res$ok),
              detail = if (isTRUE(res$ok)) "" else as.character(res$msg %||% ""))
        if (isTRUE(res$ok)) ok <- c(ok, rel) else bad <- c(bad, res$msg)
      }
      removeModal()

      if (length(ok)) {
        showNotification(
          if (length(ok) == 1L) sprintf("已删除「%s」", ok)
          else sprintf("已删除 %d 项", length(ok)),
          type = "message", duration = if (length(bad)) 12 else 5)
        # 删掉的正好是当前所在的目录时（不太可能，界面里进不去一个空目录的
        # 父级删除流程，但多标签页下会发生）退回根目录，别停在一个不存在的
        # 目录上 —— 那样整张表会空掉。
        cur <- current_dir()
        if (nzchar(cur) && any(vapply(ok, function(rel)
              identical(cur, rel) || startsWith(cur, paste0(rel, "/")),
              logical(1)))) {
          current_dir("")
        }
      }
      if (length(bad)) {
        showNotification(paste(bad, collapse = "；"), type = "error", duration = 12)
      }
      refresh(refresh() + 1)
    })
  })
}
