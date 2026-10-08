# =============================================================================
# 对话页
# =============================================================================
# 会话列表 + 消息流 + 代码执行。
#
# 两个性能上的关键决定：
#
# 1. 历史消息和"正在生成的消息"分成两个 renderUI。流式输出每 200ms 轮询一次，
#    如果把整个历史放在同一个 renderUI 里，每 200ms 就要重新渲染几十条消息
#    （每条都要重新扫描代码块、跑一遍 commonmark），长会话会卡到没法用。
#
# 2. 流式渲染时不给执行按钮（executable = FALSE）。消息还没落库，执行按钮
#    要用的坐标（消息 id）还不存在；等回复写进数据库后重渲染，按钮自然出现。
#
# 代码执行只从浏览器收一个坐标，代码内容回数据库重取 —— 见 jobs.R 里
# dsapp_extract_block() 的说明。
# =============================================================================

mod_chat_ui <- function(id) {
  ns <- NS(id)

  # ⚠️ 结果先接住再 append（见函数末尾）：那条竖分隔条要挂到 layout **自己**
  #    身上，而 layout_sidebar() 没有"再塞一个孩子"的参数 —— 它的 `...`
  #    是主区的内容。
  lay <- layout_sidebar(
    fillable = FALSE,
    sidebar = sidebar(
      width = 260,
      open = "always",
      div(class = "d-flex gap-2 mb-3",
        actionButton(ns("new_chat"), "新建对话",
                     class = "btn-primary btn-sm flex-grow-1",
                     icon = icon("plus")),
        # ★★ V15.14：这个按钮原来**只有图标、没有文字**（label = NULL）。
        #   一个 30×31 的红色垃圾桶，紧挨着「新建对话」，而下面是二十来行
        #   每一行右边都挂着一个 16×17 的铅笔 —— 两个都是**裸图标**，
        #   一个是"改个名字"，一个是"删掉整个对话连同工作区"，中间没有任何
        #   文字把它们分开。用户报「点编辑名称弹出了删除界面」，无论他当时
        #   点歪了还是看错了，这个布局都在把这种事故往怀里揽。
        #   加上文字之后，它就不可能再被当成铅笔。
        actionButton(ns("del_chat"), "删除",
                     class = "btn-outline-danger btn-sm",
                     icon = icon("trash"),
                     title = "删除当前对话")
      ),
      # 共享入口（item 7）。放在会话列表上方而不是「设置」页：它作用于
      # **当前这个对话**，和"新建/删除"是同一类操作，摆在一起用户才找得到。
      # 整块由服务端按身份渲染 —— 不是自己的对话、或者没有对话时它不存在。
      uiOutput(ns("share_bar")),

      # 运行中的任务（V8 item 6 挪到这里）。
      #
      # 它原来在主区顶上、消息流的上面。用户点一下「确认执行」，这一条插进来，
      # 整条消息流连同**输入框和发送按钮**一起往下跳 47 像素（实测）——
      # 用户这次的要求里有半句正是冲着这个来的："不要占据其它操作的位置"。
      #
      # 挪进侧栏是因为这一栏**谁都不挤**：消息区、输入区、发送按钮全在另一
      # 列，横幅长出来也好、缩回去也好，它们一个像素都不动。而它要回答的
      # 那个问题（"系统里有没有任务在跑"）在侧栏一样看得见 —— 侧栏是常驻的。
      uiOutput(ns("running_banner")),

      # 二级目录（V9 item 9）现在**不再挂在这里**。
      #
      # V11 item 2：用户的原话是「对话的子目录应该就显示在对应会话下方，
      # 而不是像现在这样的固定位置」。原来它是侧栏底部一块、永远只反映
      # **当前**那个对话，看着像"侧栏自带的一个面板"；而它其实是某一条
      # 会话的属性。现在它跟着会话行走，见 output$session_list。
      uiOutput(ns("session_list"))
    ),

    # ★ V12 item 1：整页包进一个**定高的 flex 列**（.dsapp-chat-page）。
    #
    #   用户原话：「对话框和内容输出框应该挨在一起，现在的间距过大」。
    #   "间距过大"有一半是那排控件卡在中间造成的（已挪走），另一半是**整页比
    #   一屏高**：从 V11 起这一页的内容实测 956px，而视口只有 900px ——
    #   多出来的那 56px 让整页能上下滚，固定页脚正好压在控件那一排上。
    #   用户看到的"间距"里，有一部分其实是"得往下滚才看得见输入框"。
    #
    #   修法是让这一页**自己吃掉一屏**：滚动只发生在消息区内部，输出框、
    #   动作条、输入框、控件排全部钉在原地。见 app.css 的 .dsapp-chat-page。
    #
    # ⚠️ 这个 div 不能省。它能生效的前提是"高度能从一个定高的祖先解出来"
    #    （bslib 的 .main 是 grid 子项，高度是定的），而 .main 的直接子元素
    #    除了这一列还有运行状态条和输入区 —— 不包起来的话，flex 那一套要
    #    分别写给三个兄弟，跑一个任务（状态条长出来）就会把它们挤扁。
    div(class = "dsapp-chat-page",

    # ★ V13.12 item 7：分析中的进度条。
    #
    #   用户原话：「正在分析的时候总是闪屏，换成一个进度条或者转圈的效果吧」。
    #
    #   闪屏的根因是渲染那一路（见 render.R 里 V13.12 item 6 那几段：正文
    #   一多，一次重画要几百毫秒，而它每 200ms 被要求重画一次，主线程一直
    #   喘不过气）。这里补的是用户**要看的那个东西**：一条稳定的进度条。
    #
    #   ⚠️⚠️ 它必须是**静态**的：只在这里渲染一次，之后只由前端切 class。
    #      放进任何一个 renderUI 里都会跟着重画 —— 而 CSS 的跑马灯动画是
    #      "元素一被替换就从头开始"的，5Hz 重画的结果是那道光每 200ms 弹回
    #      起点，比没有还闪。显隐和动画全在 app.css，判断在 app.js。
    div(class = "dsapp-progress", `aria-hidden` = "true",
        div(class = "dsapp-progress-bar")),

    # ★ V13.2 item 5：把用户调过的面板尺寸写成 CSS 变量挂到 <html> 上。
    #
    #   放在这一页的最前面（渲染顺序上）、也在 .dsapp-chat-page 里面 ——
    #   `<style>` 是全局的，放哪个 DOM 位置都生效，这里只是挨着用它的地方。
    #   ⚠️ 别改成往 <head> 里塞或者走 sendCustomMessage：模块 session 是
    #      proxy，sendCustomMessage 在它身上**静默失效**（见 CLAUDE 里那条），
    #      而症状正是"拖了没反应、刷新又对了"。
    uiOutput(ns("size_vars")),

    # 主区拆成左右两列（V11 item 9）。
    #
    # 用户的原话是「言出法随界面和对话文件界面应该分割开，并且有固定位置」。
    # 原来对话流、确认卡、执行进度、产物清单**全在一条竖列**里：产物卡片
    # 每 3 秒重渲染一次，图多的时候有半屏高，把输入框推上推下；用户想一边
    # 看结果一边读模型的话，得在一条列里来回滚。
    #
    # 现在左边是"这一轮在说什么"，右边是"这个对话产出了什么"，各有各的
    # 滚动条，谁也不推谁。
    div(class = "dsapp-chat-main",
      div(class = "dsapp-chat-col",
        div(class = "dsapp-chat-scroll", id = ns("scroll"),
          # ★★ V16.1 item 2：翻回去看的那几屏 —— 「显示更早的消息」的宿主。
          #
          #   用户原话：「主账号中，对话里显示更早的消息**无法正常加载出来**」。
          #
          #   ⚠️⚠️ 为什么是"几屏各占一格"而不是原来那样"一个窗口越点越大"：
          #    改前 `hist_extra` 只增不减，点一次窗口就长一圈，而**每一圈都是
          #    整包重发的**。慢链路上实测点到第七次是 763 KB 一帧（死线 694 KB），
          #    而且从此每一次历史重渲染都还要再发一遍那个 763 KB —— 这个对话
          #    就再也打不开了。数字和整条推理写在 R/config.R 的
          #    DSAPP_HIST_MAX_PAGES 上面。
          #
          #   分屏之后每次点击只发**新那一屏**，单包恒定 ~155 KB，与点了几次无关。
          #
          #   ⚠️ 顺序是**从旧到新**（page_10 … page_1），不能反过来：第一屏装的
          #      是紧挨着窗口上面的那几条（最新翻出来的），它必须**最靠近**
          #      output$history；后面的屏一条比一条旧，往上叠。
          #      写反了不会报错，只是消息顺序整个颠倒。
          #
          # ★ V16.3 item 6：最上面那一条是"你正在看较早的内容 · 回到最新"。
          #   ⚠️ 它必须是 `.dsapp-chat-scroll` 的**第一个**子元素，而且靠
          #      CSS 的 position: sticky 钉在顶上 —— 跳过去之后用户是滚在
          #      中间的，画在别处（比如窗口下面）等于没画。
          uiOutput(ns("hist_focus")),
          # ⚠️ 外层这个 uiOutput 的 id 和里面那个 actionLink 的 id **不能同名**
          #    （两个都叫 hist_more = 页面上两个同 id 的节点，非法 HTML +
          #    按 id 找元素有歧义）。这处是**老代码**，V16.6 加全仓扫描
          #    （selftest 的 ⑧）时才揪出来的：今天没坏只是因为 actionLink
          #    没有 updateActionLink 这种东西，但探针里 `#chat-hist_more`
          #    会直接撞上 strict mode 冲突，而且它挡着后面所有同类的坑。
          #    里面那个 actionLink 仍然叫 hist_more（input$hist_more 不变）。
          uiOutput(ns("hist_more_ui")),
          lapply(rev(seq_len(DSAPP_HIST_MAX_PAGES)), function(k)
            uiOutput(ns(sprintf("hist_page_%d", k)))),
          uiOutput(ns("history")),
          # ★★ V15.3 item 3：思考过程**单独一格**，不再塞在 streaming 气泡里面。
          #
          # ⚠️ 这一格的位置是有讲究的，别顺手挪回去。用户原话：
          #    「现在对话框思考时还是会闪，不要闪，正常往外输出思考过程就行」。
          #    以前它长在 output$streaming 渲染出来的占位气泡**里面**，于是
          #    凡是让那一格重画的东西都会把它一起拆掉重建：思维链每 200ms 的
          #    进度、agent 循环每秒一次的心跳（那颗停止按钮的亮灭要跟着它走）
          #    —— 用户展开的 <details> 被折回去、<pre> 的滚动位置归零，
          #    看起来就是"一直在闪"。
          #    单独一格之后，它的**唯一**重画理由是"新的一轮开始了"，
          #    正文本身靠 www/app.js 的 dsapp:think 处理器往里追加。
          uiOutput(ns("thinking_box")),
          # ★★ V15.4 item 3：正文还没开始时的占位（转圈 + 活人感提示词）。
          #
          # ⚠️ 它是**单独一格**、在 output$streaming **外面**，这是刻意的。
          #    这一格的重画理由只有三个粗粒度事件（开新一轮 / 正文开始 /
          #    本轮结束），而 output$streaming 依赖 draft()，正文字一吐就是
          #    每 200ms 一次。占位气泡长在里面的话，那颗 spinner 和那行提示词
          #    每 200ms 被拆掉重建一次 —— CSS 动画一换元素就从头开始，用户
          #    看到的正是「思考的时候还是在闪屏」。别再嵌回去。
          uiOutput(ns("wait_box")),
          uiOutput(ns("streaming")),
          # ★★ V15.4 item 3：「stream」宿主的动作按钮，从 streaming 气泡里搬
          #    了出来。见 output$stream_actions 上面那段。
          uiOutput(ns("stream_actions")),
          # 内联确认卡放在消息流末尾：它属于"正在进行的这一轮"。放进 composer
          # 里的话会被输入框挤到屏幕外，而它恰恰是循环在等用户的那一步。
          uiOutput(ns("agent_confirm_card")),

          # 「这个对话正在后台继续」（V13.7 item 5）。放在 live_run **上面**：
          # 它讲的是更大的一件事（有个进程在替这个对话干活），而 live_run
          # 讲的是这件事里边那个正在跑的任务。
          uiOutput(ns("detach_bar")),

          # 正在执行的任务（V9 item 2）。和确认卡同理放在消息流末尾 ——
          # 用户的原话是「任务系统定位只是一个记录运行日志的地方，请把执行过程
          # 详细地在言出法随页面展示」：跑一个 RunUMAP 的十几分钟里，用户不该
          # 为了看进度而切到「历史任务」页去。
          uiOutput(ns("live_run"))
        ),

        # ★★ V16.1 item 6：「有任务在跑」的常驻浮标。
        #
        #   用户原话：「我点确认执行，显示已有任务在执行，但是我看不到任何提示
        #   任务在执行的痕迹，那个转圈的效果不能只在模型字符前面显示，对话框中
        #   应该也转圈，但是不能影响我查当前对话的其它内容，或在其它界面的其它
        #   操作」。
        #
        #   上面那张 live_run 卡片**只在任务属于本对话时**才出现（归属判断见
        #   live_run_data），而引擎是**全局单槽**的 —— 任务跑在别的对话里时，
        #   这一整页一个字都不说。用户点「确认执行」被那句"已有任务正在执行"
        #   挡回来，而界面上找不到任何"在执行"的痕迹，说的就是这个空档。
        #
        #   ⚠️⚠️ 三个约束，缺一个就变成用户抱怨的那种东西：
        #     · **不占位**：position:absolute，脱离文档流。它长在消息流的
        #       最后一个子节点后面，但因为是绝对定位，出现/消失都不会让上面
        #       任何一条消息移动一个像素（"不影响我查其它内容"）。
        #     · **不吃点击**：pointer-events:none（同 .dsapp-progress）。消息流
        #       底下压着代码块的复制按钮、图片、链接，浮标盖住的那一小块必须
        #       能穿透过去（"不影响其它操作"）。
        #     · **不重建**：整块由一个 renderUI 画，而它的依赖只有"任务起止"
        #       和"切对话"这两个粗粒度事件 —— 绝不要往里面加秒数/进度之类的
        #       每拍都变的东西。那会让 spinner 的 CSS 动画每次重画都从 0 度
        #       重新开始，用户看到的不是"在转"是"一秒抖一下"（同一个坑在本文件
        #       里已经踩过三次：.dsapp-progress、.dsapp-hint-spin、wait_box）。
        #       秒数要显示的话由前端自己走，参照 dsapp_live_card 的 .dsapp-elapsed。
        #
        #   ⚠️ 它必须是 .dsapp-chat-col 的**直接子节点**（.dsapp-chat-scroll 的
        #      兄弟），不能塞进 .dsapp-chat-scroll 里面 —— 那是滚动容器，
        #      绝对定位的元素会跟着内容一起滚走，任务一跑就看不见了。
        uiOutput(ns("busy_badge")),

        # ---- ★★ Test_V15.3 item 4：这里原来是一条 .dsapp-output-bar -------
        #
        # 用户原话：「停止按钮重复了，可以把确认执行、补点建议、停止按钮都挪到
        # 正在执行的会话里去」。
        #
        # 那条动作条（V12 item 2 加的）钉在输出框下沿，而「停止任务」在实时
        # 卡片里、「停止后台运行」在后台横幅里各有一颗 —— 三颗红按钮同时
        # 可见，用户看到的就是"重复了"。
        #
        # 现在**一处渲染、一处出现**：三颗按钮由 run_actions_ui() 渲染，
        # 挂在哪一处由 action_host() 说了算，任何时刻只有一处可见。
        # 四个挂载点见 action_host() 的说明。
      ),

      # ---- 竖分隔条：调"输出框 ↔ 文件区"的宽（V13.2 item 5）-------------
      #
      # 用户原话：「例如言出法随界面中的输出界面的宽高，能不能支持用户自定义？
      # 记得做好自适应，不要相互堆叠」。
      #
      # ⚠️ 它夹在**两列之间**，是 .dsapp-chat-main 的第三个 flex 子项，
      #    不是任何一列的兄弟或子元素：塞进某一列里的话，拖动时它的宽度会
      #    被那一列的 flex/overflow 重新算一遍，算出来的位置和鼠标对不上，
      #    表现是"拖着拖着自己跑"。
      # ⚠️ `tabindex` + role="separator"：键盘用户也得调得了（左右方向键，
      #    见 app.js 的 dsappInitSplitters）。纯鼠标的东西在这个项目里一向
      #    是要补键盘的。
      div(class = "dsapp-split-v", id = ns("split_v"),
          tabindex = "0", role = "separator",
          `aria-label` = "拖动调整文件区宽度",
          title = "拖动调整宽度（双击恢复默认）"),

      # 右列：本对话的文件（V5 item 3 的产物卡片搬到这里）。
      #
      # ⚠️ 它仍然**不是**一条静态资源路由，仍然走 dsapp_ws_path + 会话级
      #    接口 —— 换的只是排版位置，安全属性一个字没动。
      div(class = "dsapp-files-col",
        uiOutput(ns("artifacts_card"))
      )
    ),

    # ★ V13.8 item 5：这里原来是一条独立的「运行状态条」（uiOutput("run_status")）
    #   —— 一整条横在输出框和输入框之间，每 200ms 重画一次，带着转圈、秒数
    #   和字符数。用户的原话是「运行的时候的刷新效果，在显示 token 那个框刷新
    #   就可以了」，删掉了。
    #
    # ⚠️ 删的是**这一条**，不是"运行中不给反馈"。运行中该说的话一个字没少，
    #    全搬进了输入框左下角那个 hint（它本来就是显示模型 / 温度 / token
    #    用量的那一格）：在干什么、跑了多久、已经产出多少，现在都在那儿。
    #    于是**整页只有一个地方在随生成刷新** —— 用户看一个地方就够了。
    #
    # ⚠️ 别再按"多一个地方显示更保险"加回来。原来那一版的问题不是信息不够，
    #    是同一件事在三个地方各说了一遍（状态条、hint、气泡里的转圈），
    #    每处刷新节奏还不一样（200ms / 前端动画），整页看起来一直在抖。

    # ---- 横分隔条：调"输出框 ↔ 输入框"怎么分这一屏的高（V13.2 item 5）---
    #
    # ★ 用户说的是"输出界面的**高**"。这里调的是**输入区**的高度 —— 效果
    #   一样（往上拖 = 输入区变矮 = 输出框变高），但它才是那个"能调得动"
    #   的量：输出框在现在的版面里已经**吃掉了一整屏剩下的全部空间**
    #   （见 app.css 的 .dsapp-chat-main，flex: 1 1 auto），再给它一个高度
    #   要么没效果、要么在它和输入框之间留一条谁也不知道哪来的空白。
    #
    # ⚠️ 放在 .dsapp-chat-main **外面**、.dsapp-composer **上面**：它是
    #    "这两块怎么分"的那条线，属于 .dsapp-chat-page 这一层。
    div(class = "dsapp-split-h", id = ns("split_h"),
        tabindex = "0", role = "separator",
        `aria-label` = "拖动调整输入区高度",
        title = "拖动调整高度（双击恢复默认）"),

    div(class = "dsapp-composer",

      # 只读提示（item 7）：共享进来的对话在这里说清楚为什么发不出去
      uiOutput(ns("readonly_note")),

      # ★★ V15.6 item 12：它在问你话的时候，就地给一个能打字的框。
      #
      #   用户原话：「返回问题的时候只有继续和停止按钮，应该有键入让用户回答，
      #   类似于 claude 的 chat about this」。
      #   改之前：那种回复尾巴上只有「继续」（发出去的是写死的两个字）和
      #   「停止」。打字当然可以 —— 但只能去下面那个大输入框，而界面上没有
      #   任何地方告诉用户"你可以直接回它"。
      #
      # ⚠️⚠️ 这个节点必须是**静态的**，不能让 renderUI 画。它在用户打字期间
      #    绝不能重建 —— 本仓栽过这个跟头（重画把用户正在打的回复冲掉，
      #    而且不报错，只是字没了）。所以：显隐和提示语由服务端发
      #    `dsapp:askbox` 消息切（见下面那个 observer），正文一个字都不重画。
      # ⚠️ 默认 display:none。服务端在 onFlushed 之后才会发第一条消息，
      #    在那之前它必须是收着的。
      # ⚠️ `data-dsapp-enter` 是给 www/app.js 的通用回车用的：那个处理器
      #    按 id 只认主输入框，这个框不在 dsappIds.input 上。
      div(class = "dsapp-ask-box", id = ns("ask_box"), style = "display:none;",
        div(class = "dsapp-ask-hint",
            icon("comment-dots"),
            # ★ V16.1 item 1：提示语改成「补充点意见：」（用户原话）。
            #   这一份只是**收到服务端第一条消息之前的兜底**，真正显示的是
            #   下面 observer 里发出去那句（app.js 只在 m.hint 存在时才覆写）。
            #   两份必须一起改 —— 只改一份的话，页面加载瞬间闪的是旧文案，
            #   而平时看到的是新的，这种"偶尔闪一下"最难被发现。
            span(id = ns("ask_hint"), "补充点意见：")),
        div(class = "dsapp-ask-row",
          tags$textarea(
            id = ns("ask_reply"), class = "form-control dsapp-ask-input",
            rows = "2",
            placeholder = "回它一句…（Enter 发送，Shift+Enter 换行）",
            `data-dsapp-enter` = ns("ask_reply_key")),
          actionButton(ns("ask_send"), "发送",
                       class = "dsapp-btn dsapp-btn-run",
                       icon = icon("paper-plane")))),

      textAreaInput(ns("input"), NULL, rows = 3, width = "100%",
                    placeholder = "描述你的分析需求，或直接提问…（Enter 发送，Shift+Enter 换行）"),
      # ★ V13.11 item 9：这一排**必须永远是一行**。
      #
      #   用户原话：「「总结并生成报告」和「发送」按钮会在 token 使用的提示
      #   语句变长时换行，请固定按钮为一行」。
      #
      #   原来这里是 `d-flex justify-content-between` 两个 Bootstrap 工具类。
      #   两个 flex 子项在空间不够时**都会收缩**：左边那句提示是纯文本，能
      #   换行；右边那组按钮虽然短，但没有 flex-shrink: 0，于是它先被压窄、
      #   按钮里的字跟着折成两行。提示语越长（带上 token 数、缓存命中数之后
      #   确实很长）按钮越容易变成两行 —— 而"发送"变成两行是没法用的。
      #
      #   ⚠️ 所以约束**不能**只写在按钮上，得写在这一排上：见 app.css 的
      #      .dsapp-composer-foot。那里是 nowrap + 左边可省略号截断 + 右边
      #      flex: 0 0 auto。三个一起才对：只加 nowrap，长提示会把按钮直接
      #      顶出容器右边（横向溢出）；只给按钮加 shrink:0，则左边那句会
      #      把整排撑得比容器还宽，一样溢出。
      div(class = "dsapp-composer-foot mt-2",
        div(class = "dsapp-composer-hint text-muted small",
          # ★★ V15.5 item 8：这一颗转圈**是静态的**，从头到尾一次都不重建。
          #
          #   用户原话：「正在生成时屏幕还是会闪，去掉这个闪烁的功能」。
          #   实测（tests/ui_v155/measure_flash.py，指纹法）：生成期间整页
          #   **只剩这一颗**动画还在被反复归零 —— 25 秒里同一个选择器下出现过
          #   14 个不同的节点实例，中位间隔约 1 秒。别的都已经是 1 个了
          #   （进度条、占位转圈、思考 <pre>、发送按钮上的转圈）。
          #
          #   根因和 V15.4 item 3 那颗 spinnner 一模一样：它原来长在
          #   `output$hint` **里面**，而那一格的依赖是 stream_sig —— 字符数一变
          #   就整块重画（生成期间大约 5Hz）。CSS 动画是跟着元素走的，元素一换
          #   旋转就从 0 度重新开始；用户看到的不是"在转"，是"一秒抖一下"。
          #
          #   改法照抄 `.dsapp-progress` 那一条：**节点放 UI 里（静态），显隐由
          #   www/app.js 切 class**。所以这里只多一个空 span，`output$hint`
          #   里那颗已经删掉。见 app.css 的 .dsapp-hint-spin。
          span(class = "spinner-border spinner-border-sm dsapp-hint-spin me-1",
               role = "status", `aria-hidden` = "true"),
          uiOutput(ns("hint"), inline = TRUE)),
        # ⚠️ V12 item 2 起，这一排**只剩「发送」**，V15.3 item 4 之后依然如此。
        #    「确认执行」「补点建议」「停止」现在长在**会话本身**里（跟着正在
        #    输出的那条气泡、实时卡片或后台横幅走，见 run_actions_ui()）——
        #    用户的原话是「确认执行和停止应该在输出框的内部，跟随输出的内容
        #    一起出现」，后来又说「挪到正在执行的会话里去」。
        #    别再顺手加回来：三颗按钮长在输入区里，用户刚看完代码，还得
        #    越过输入框去找它们。
        div(class = "dsapp-composer-actions",
          # ★ V13.10 item 5：用户原话「加一个总结项目并生成报告的按钮」。
          #
          # ⚠️ 放在「发送」**左边**、同一个右对齐的组里，**不跟那三颗走**。
          #    那三颗（确认执行/补点建议/停止）回答的是"正在跑的这一轮接下来
          #    怎么办"，而这一颗回答的是"这整个对话接下来怎么办"—— 是同类于
          #    「发送」的一次**新的请求**，不是对当前内容的操作，所以它属于
          #    输入区，不属于某一条会话。
          # ⚠️ 这也正是它**不能**塞进 run_actions_ui() 的原因：那一份是"任何
          #    时刻只有一处可见"的，而这一颗要一直在。
          #
          # ⚠️ 次级样式（btn-outline-secondary）：它平常不该抢「发送」的视线。
          actionButton(ns("report_btn"), "总结并生成报告",
                       class = "btn-outline-secondary btn-sm",
                       icon = icon("file-lines")),
          actionButton(ns("send"), "发送",
                       class = "btn-primary btn-sm",
                       icon = icon("paper-plane"))
        )
      ),

      # ---- 一排控件（V11 item 3/4/5/6，V12 item 1 挪到这里）-----------------
      #
      # 用户的原话把这一排说得很清楚：
      #   · item 6「分析环境有歧义，改名为硬件选择」
      #   · item 3「skills 的选择可以和分析环境选择那里并列」
      #   · item 4「系统环境也与分析环境选择并列」
      #   · item 5「轮数可以来一个滑块让用户选择，与分析环境并列」
      #
      # 四件事合成一个判断：这几个选择回答的是**同一个问题** ——
      # "这一轮按什么规矩、在哪儿、跑多久"。
      #
      # ★ V12 item 1 把它们从**输入框上方**挪到了**整页最下方**。用户的
      #   原话：「硬件选择、系统环境这一行应该在最下方」。它原来卡在消息流
      #   和输入框中间，把这两块顶开一大截 —— 同一句话的前半句是「对话框和
      #   内容输出框应该挨在一起，现在的间距过大」，说的就是它。这一排是
      #   "偶尔改一次"的设置，压在整页最底下不挡任何人的视线；
      #   而输入框上面那点空间是用户每一轮都要看的。
      #
      # ⚠️⚠️ 这一排里**不许出现 conditionalPanel**。
      #
      #    上面那条戒律是有来历的：V3 时这里的 conda 环境下拉框曾经挂在
      #    `conditionalPanel(condition = "input.target_kind === 'server'")`
      #    上，用户一改硬件选择，这一格整块重建 → input$target_env 瞬间变
      #    NULL → 写 state 的 observeEvent 把 NULL 当成"回到系统环境"认真
      #    执行一遍。用户只是想把任务发到本地电脑，环境就被悄悄改了，
      #    而且界面上一句话都没说。（当年是靠"这一格改成只读"绕开的，
      #    V11 要求它变成可选的，所以绕法要换 —— 见下面写 state 那条
      #    observeEvent 上的 ignoreNULL。）
      div(class = "dsapp-ctrl-bar",

        # 模型（V15.8 item 3）。用户原话：「现在得对话途中切换模型，是否能够
        # 继承上下文继续交流？如果不能，请增加这个功能」。
        #
        # 答案分两半：**能继承**（探针实测 20/20，见 tests/ui_v158/probe_ctx.py），
        # 但原来**没法在这一页换** —— 想换就得离开这个对话、去「模型服务」页
        # 改、再回来，而离开那一页还会弹一次「还有改动没确认」。
        # 「对话途中切换」要的是别为了改一个下拉跑一趟，所以把它搬到这儿。
        #
        # ⚠️ 放在**最左边**：它决定"这一轮是谁在回答"，比硬件/环境/技能都靠前，
        #    而这一排是从左往右读的。
        #
        # ⚠️ 和别的格一样用 uiOutput 而不是 conditionalPanel（这一排的戒律，
        #    见上面那段）。这一格只依赖 state$vendor，换厂商才重建 ——
        #    不依赖 state$model，否则每次换模型整个 selectize 都会被拆掉重建。
        div(class = "dsapp-ctrl dsapp-ctrl-box",
          span(class = "dsapp-ctrl-h", icon("circle-nodes"), " 模型"),
          div(class = "dsapp-ctrl-body",
            uiOutput(ns("model_slot"))
          )
        ),

        # ★★ V16.3 item 5：「在哪儿跑」这一件事的两半圈进**同一个可见的框**。
        #
        #   用户原话：「现在对话框下方的组件太多了，请用框区分或者以什么形式
        #   让它们具有分类的区分度」。原来这一排是七个平铺的格子，每格头上
        #   一行小字 —— 从「硬件选择」到「系统环境」到「技能」，视觉上完全
        #   一样重，用户读不出哪几格说的是一件事。
        #
        #   ⚠️ 框是**给眼睛看的**，不是新容器：`target_kind` 和 `env_slot`
        #      这两个控件本身、它们的 id、它们外面那两条 observeEvent 的依赖
        #      关系一个字节都没动，只是外面多了一层 div。这一排"不许用
        #      conditionalPanel"那条戒律（见上面）仍然成立。
        #
        # ★ V16.3 item 3：那句「基础环境是系统环境，本对话自己装的包叠加在
        #   它上面。」原来和「自动执行已开启……」挤在**同一行**小字里（同一
        #   个 output 拼出来的两句话），用户的原话是「这一行话其实是两类功能
        #   的提示词」。现在各归各的框：这句跟着「在哪跑」，自动执行那句跟着
        #   「自动执行」。两条是**各自独立的 output**，互不影响。
        div(class = "dsapp-ctrl dsapp-ctrl-box dsapp-ctrl-where",
          span(class = "dsapp-ctrl-h", icon("location-dot"), " 在哪跑"),
          div(class = "dsapp-ctrl-body",
            selectInput(ns("target_kind"), NULL,
                        choices = c("当前服务器" = "server",
                                    "本地电脑" = "local",
                                    "远程服务器" = "remote"),
                        selected = "server", width = "150px"),
            # 系统环境（item 4）。放在**同一格**里，不再是"只读的一行小字"。
            #
            # 直接写在 UI 里（不是 renderUI、不是 conditionalPanel）：这个
            # 控件越少被重建，被重建冲掉值的窗口就越小。conda 环境列表在 UI
            # 函数建起来的那一刻读一次盘（实测 0.5 秒以内，且 sizes = FALSE
            # 不遍历目录树），新建环境之后要刷新页面才出现在这里 —— 这句
            # 代价写在「环境」页的说明里。
            uiOutput(ns("env_slot"))
          ),
          uiOutput(ns("notes_env"))
        ),

        # 技能（V8 item 1 / V11 item 3）。用户的原话是它该和硬件选择并列。
        # ⚠️ 为什么不放在「技能」页里让用户先切过去勾：勾技能这个动作永远是
        #    "我正打算问这个问题、希望它按我的规矩来"的那一刻发生的。
        #    让用户为此切页、勾选、再切回来，绝大多数人第二次就不勾了 ——
        #    功能还在，但没人用。
        div(class = "dsapp-ctrl dsapp-ctrl-box dsapp-ctrl-skillbox",
          span(class = "dsapp-ctrl-h", icon("wand-magic-sparkles"), " 技能"),
          div(class = "dsapp-ctrl-body",
            uiOutput(ns("skill_bar"))
          )
        ),

        # 自动执行。★ V16.3 item 4：这一格里**只剩开关**。
        #
        #   用户原话：「出错自动修已经打勾了，但是上面还是有个滑条，这冲突了」。
        #   他说的就是这一格原来的样子：一个亮着的「出错自动修」旁边杵着一根
        #   「6 轮」的滑块。想看的话两句话是**互相打架**的 —— 勾着说"不限"，
        #   滑块说"最多 6 轮"。这一版把所有**数字**（轮数 / 时长 / 次数）全部
        #   挪进「不设上限」那一组，每个数字都跟着一个勾：勾着 = 这一项没有
        #   上限、就地不出现滑块；取消勾选 = 就地出现能填数的控件。
        #   「自动执行」这一格于是只剩"开不开"这件事，一个数字都不剩。
        #
        # ⚠️ 用 checkboxInput 而不是手写 <input type="checkbox">。手写的那个
        #    长得一样，但 Shiny 的输入绑定不认它（它靠 class 认领控件），
        #    input$agent_mode 永远是 NULL —— 表现是"开关点了没反应"，
        #    而且不报任何错。（form-switch 的样式由 app.css 补。）
        #
        # ⚠️ 「跑完发邮件」也搬进这一格（原来是单独一格）。它和这两个开关是
        #    同一类东西：**要不要**，不是**多少**。而且它本来就是这一格的
        #    收尾动作（跑完了 → 告诉你），和 detach 那张卡放在「离开页面之后」
        #    下面同一个道理。
        div(class = "dsapp-ctrl dsapp-ctrl-box dsapp-ctrl-agent",
          span(class = "dsapp-ctrl-h", icon("robot"), " 自动执行"),
          div(class = "dsapp-ctrl-body dsapp-agent-bar",
            checkboxInput(ns("agent_mode"), label = "开启", value = FALSE),
            # ★ V13.5 item 1：「出错自动修」，**默认勾上**。
            #
            #   用户的原话是「报错需要AI自己解决，而不是用户自己确认」——
            #   所以它的默认值是 TRUE，而且不跟着上面那个「开启」走：任务
            #   挂了之后由 AI 自己读报错、改代码/补依赖、重跑，不需要用户
            #   先点一下确认。
            #
            #   ⚠️ 它**不是**"自动执行"的一个子选项，两者是并列的两件事：
            #      开启       = 没出错也一直往下跑（默认关，花 token）
            #      出错自动修 = 只在挂了之后跑一轮排查（默认开）
            #      合并成一个开关的话，用户要么放弃出错自动修，要么被迫
            #      接受"每轮都自己跑"。
            #   ⚠️ 留一个关得掉的口子是有意的：报错时把模型叫起来要花 token，
            #      而且有些用户就是想自己看报错。默认开 + 能关，比默认开 +
            #      关不掉诚实。
            checkboxInput(ns("agent_fix"), label = "出错自动修", value = TRUE),
            # ⚠️ 没配 SMTP 的部署里这个勾**整个不出现**（连它的格子也不出现）。
            #    这个判断在 UI 函数建起来的那一刻定死，之后一个字节都不动 ——
            #    不是 conditionalPanel（上面那段戒律管的就是它）。
            # ⚠️ 默认值是 FALSE，真正的值由登录后那个 observeEvent 推下来
            #    （和 agent_mode/agent_fix 完全一样：模块建起来的时候
            #    state$user_id 还是 NULL，那时候读库读不到东西）。
            if (isTRUE(dsapp_mail_ready(dsapp_config())))
              checkboxInput(ns("mail_notify"), label = "跑完发邮件", value = FALSE),
            # ★★ V16.5 item 1：轮数滑块**搬回这一格**，而且**跟着「开启」走**。
            #
            #   用户原话：「轮数似乎应该是在自动执行界面，自动执行打开应该就
            #   不设置轮数，不打开则弹出轮数设置」。两句话各是一半：
            #     · 位置：它属于「自动执行」这一格（V16.1 就在这里；V16.3 把
            #       它挪进了「不设上限」那一组，成了第五个勾）；
            #     · 联动：**开启勾上 = 轮数不设上限**（这一格只剩"开不开"），
            #       没勾 = 就地出现滑块，最多跑几轮由这里定。
            #
            #   ⚠️ 为什么这是对的而不是"少给用户一个旋钮"：「开启」的语义就是
            #      "没出错也一直往下跑"（见下面那条注释），给它配一个"跑 6 轮
            #      就停"的上限是自相矛盾的 —— 用户原话那句"冲突了"
            #      （V16.3 item 4 的由头）说的就是这个形状。
            #
            #   ⚠️⚠️ 这里**故意**用 uiOutput（一个 renderUI 画滑块），而滑块
            #      本体必须画在**它自己那个 output** 里、值走 rv_iter()：
            #      直接写死一个 sliderInput 的话，"开启"一勾上它就得消失 ——
            #      而静态控件没法条件出现（conditionalPanel 在本仓是禁的，
            #      见上面那段戒律）。
            #   ⚠️ 它是**这一格**里唯一的数字，位置排在最后：三个"要不要"
            #      （开启 / 出错自动修 / 跑完发邮件）在前，一个"多少"在后。
            uiOutput(ns("iter_w"), inline = TRUE)
          ),
          # 这一格自己的那行小字（V16.3 item 3：它原来和"系统环境"那句挤在
          # 同一行里）。两种内容，互斥：
          #   · 循环正在跑 → 「第 N/M 轮 + 它现在在干什么」的实时进度
          #   · 开着但没在跑 → 「自动执行已开启（…），发送后自动跑，随时可点
          #     「停止」。」
          # ⚠️ output 的 id 沿用 `ctrl_notes`（**没有**跟着改名）：它在
          #    tests/ui_v155、tests/ui_v157 那两份冻结记录里是当锚点用的
          #    （数里面那颗"第 N/M 轮"徽章的出现和消失）。改名的收益只有
          #    "看着整齐"，代价是那两条断言变成"找不到元素"。
          uiOutput(ns("ctrl_notes"))
        ),

        # ★★ V16.2 item 2：「不设上限」勾选组。
        #
        #   用户原话：「言出法随下面的对话框需要有直接勾选这些选项不设上限的
        #   组件」。四个勾 —— 上下文 / 单次输出 / 运行时间 / 出错自动修 ——
        #   **默认全部勾上**（V16.1 item 5 的"默认不设上限"到这里才真正
        #   看得见：在那之前它是"滑块停在最右一格"和"模型页那个数是 0"，
        #   用户没有任何一处能一眼看到"我现在的上限是什么"）。
        #
        #   ⚠️⚠️ 勾选框是**静态**的，和 agent_mode / agent_fix 一样，由服务端
        #      用 updateCheckboxInput() 推到真值上。**不能**用 renderUI 画：
        #      勾选框的值来自 state$ctx_limit / agent 对象，用 renderUI 就等于
        #      "每次真相变一下就把控件拆了重建"——而控件重建的那一瞬间浏览器
        #      会先报一个 NULL 上来，下面那些 observeEvent 会当成"用户取消了
        #      勾选"，然后写回真相……**自己把自己关掉**，且不报错。
        #      （本仓在"重画冲掉用户输入"上栽过，见 .dsapp-ask-box 那段。）
        #
        #   ⚠️ 四个勾**不是四个独立的开关**，它们各自指向一个真实的上限：
        #        上下文 / 单次输出 → 同一个值（state$ctx_limit），动一个另一个
        #                            跟着动 —— 界面上写明了这一点，见下面那句
        #                            小字。**不能**让它们各存各的：那就会出现
        #                            "勾着单次输出、库里上下文还是 65536"，
        #                            而用户以为自己两项都不设限了。
        #        运行时间          → agent 对象的 wall_limit（Inf = 不设上限）
        #        出错自动修        → agent 对象的 fix_max（0 = 不设上限）
        #
        #   ★★ V16.3 item 4：这一版把所有**数字**都收进这一组，每一项都配
        #      一个勾：勾着 = 这一项没有上限、就地不出现控件；取消勾选 =
        #      就地出现能填数的控件。数字（滑块/数字框）从这一组以外**全部
        #      消失**。
        #
        #   ★★ V16.5 item 1：「轮数」**搬回「自动执行」那一格**去 —— 它的
        #      出现与否由「开启」决定（开启 = 不限轮数），不是"这一项要不要
        #      设上限"里的第五项。理由和用户原话见上面「自动执行」那一格。
        #      ⚠️ 仍然是四个勾、四条**默认勾着**的路，一个字都没少 ——
        #         少的是那个**唯一默认不勾**的例外（见 config.R 的
        #         DSAPP_AGENT_ITER_UNLIMITED 那段：那句话现在描述的是
        #         "开启勾着的时候轮数就是不限的"）。
        #
        #   ⚠️⚠️ 四个勾各自**紧跟**自己那个就地控件（而不是四个勾排一排、
        #      控件全堆在末尾）：「就地」二字就是这么来的，堆在末尾的话，
        #      第一个勾的控件离它两三百像素，用户得自己找。
        #      每个就地控件是**各自独立的 uiOutput** —— 一次只重建一格，
        #      拖 A 的滑块不会碰到 B 的（共用一个大 renderUI 的话，任何一格
        #      变化都会把整块拆了重建）。
        #
        #   ⚠️ 就地控件里每个输入都必须带 value（重建会把 input 打成 NULL，
        #      而 NULL 在这里等于"用户什么都没选"）。值一律从下面的 rv_*
        #      记忆里取（见那几条 reactiveVal 的说明）。
        div(class = "dsapp-ctrl dsapp-ctrl-box dsapp-ctrl-unlim",
          span(class = "dsapp-ctrl-h", icon("infinity"), " 不设上限"),
          # ⚠️⚠️ 每一对「勾 + 它的就地控件」外面**必须**有 .dsapp-unlim-item
          #    这一层。原因不是好看，是**换行**：.dsapp-unlim-bar 是 flex-wrap
          #    的，勾和它的控件是**两个** flex 子项 —— 宽度一紧，换行点就会
          #    落在它俩中间（实测：勾在第 1 行最右边、滑块整条掉到第 2 行最
          #    左边），于是"就地"两个字失效，用户看到的是一排勾和一堆控件。
          #    包一层之后这一对**要么一起上、要么一起下**。
          div(class = "dsapp-unlim-bar",
            div(class = "dsapp-unlim-item",
              checkboxInput(ns("unlim_ctx"), label = "上下文", value = TRUE),
              uiOutput(ns("unlim_ctx_w"), inline = TRUE)
            ),
            div(class = "dsapp-unlim-item",
              checkboxInput(ns("unlim_maxtok"), label = "单次输出", value = TRUE)
            ),
            # ★★ V16.5 item 1：「轮数」这个勾**搬出去了**（连同它的滑块一起
            #    回到「自动执行」那一格，改由「开启」决定要不要出现）。
            #    这一组于是回到**四个**勾：上下文 / 单次输出 / 运行时间 /
            #    自动修次数 —— 它们的共同点是"这一项本来有个数、现在不想要了"，
            #    而轮数是"这一项要不要存在"（跟着开启走），不是一类。
            div(class = "dsapp-unlim-item",
              checkboxInput(ns("unlim_wall"), label = "运行时间", value = TRUE),
              uiOutput(ns("unlim_wall_w"), inline = TRUE)
            ),
            # ⚠️ 标签是「自动修次数」，**不是**「出错自动修」：左边「自动执行」
            #    那一格里已经有一个叫「出错自动修」的开关了，两个同名控件在
            #    同一屏上，用户没法在报错时描述自己点的是哪一个
            #    （tests/ui_v162/README.md 里专门记过这个坑）。
            div(class = "dsapp-unlim-item",
              checkboxInput(ns("unlim_fix"), label = "自动修次数", value = TRUE),
              uiOutput(ns("unlim_fix_w"), inline = TRUE)
            )
          )
        ),

      ),

      # ★ V16.3 item 3：这一排下面**不再**有一条共用的说明行了。
      #
      #   原来这里是一个 `uiOutput(ns("ctrl_notes"))`，把三件互不相干的事
      #   （系统环境 / 自动执行的状态 / 循环进度）拼在**同一行**里，用户看到
      #   的就是一句接一句的长话（他的原话：「这一行话其实是两类功能的提示
      #   词」）。现在每一句都跟着自己那一格走：
      #     · 「基础环境是系统环境…」   → 「在哪跑」那个框里（notes_env）
      #     · 「第 N/M 轮 / 自动执行已开启…」→ 「自动执行」那个框里（ctrl_notes）
      #   ⚠️ 位置换了，id 还是 `ctrl_notes`（见上面那一格里的说明：冻结的
      #      探针拿它当锚点）。
    )
    )   # /div.dsapp-chat-page
  )

  # ---- 竖分隔条：调左边那条**任务导航栏**的宽（V13.4 item 6）-------------
  #
  # ★ 用户原话：「言出法随界面的任务导航栏需要支持拖动改变大小」。
  #
  # ⚠️⚠️ 这条把手**不能**像另外两条那样写在内容流里。那一栏是
  #    `layout_sidebar()` 的 sidebar —— bslib 把整页做成一个 **grid**，
  #    列宽由 `grid-template-columns` 定，sidebar 和 main 是两个 grid 子项，
  #    中间**没有第三个格子**可以插把手。
  #
  #    所以它走绝对定位：挂在 .bslib-sidebar-layout 自己身上（bslib 给它
  #    写了 `position: relative`），用 `grid-column: 2/3` 把**包含块**指到
  #    main 那一列的网格区，再 `left: 0` 贴住那一列的左边缘 —— 也就是
  #    sidebar 和 main 之间那条线。见 codex.css 的 .dsapp-sess-handle。
  #
  #    ⚠️ 为什么不干脆把把手放进 sidebar 里：`.bslib-sidebar-layout > .sidebar`
  #       是 `overflow: auto` 的。放进一个 overflow:auto 的盒子里、再让它
  #       跨出盒子边缘（right:-6px 那种写法），跨出去的那一半会被**裁掉**，
  #       留在里面的那一半正好压在 sidebar 自己的滚动条上。整条把手只有
  #       能看到的那一半能点，而且点下去先滚的是列表。
  #
  #    ⚠️ 也正因为它不在内容流里，它不会跟着 .dsapp-chat-page 走 ——
  #       放在这里（layout 的最后一个子元素）是唯一能落到正确包含块的位置。
  lay <- htmltools::tagAppendChild(lay, div(
    class = "dsapp-sess-handle",
    id = ns("split_s"),
    # ★ 给 app.js 认的。那边原来靠 `.dsapp-split-v` / `.dsapp-split-h`
    #   两个类区分调的是谁，现在有两个都是"竖着拖"的把手（文件区、导航栏），
    #   类分不出来了 —— 再靠类去猜，拖导航栏会去改文件区的宽度。
    #   显式写出是哪一个，顺便省掉一串 if。
    `data-dsapp-panel` = "sess_w",
    tabindex = "0",
    role = "separator",
    `aria-label` = "拖动调整任务导航栏宽度",
    title = "拖动调整宽度（双击恢复默认）"
  ))

  lay
}

mod_chat_server <- function(id, state, engine) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    # ★ V13 item 6：这个账号自己的管理区（发布产物、预览上传文件都落在这儿）。
    # 对话页本身不列管理区，但它有两条路会碰到：`发布`（dsapp_publish_artifact，
    # 那边自己会按 sid 再绑一次，双保险）和文件预览（dsapp_preview_url，
    # 走的是 registerDataObj，见那里的说明）。
    #
    # ⚠️⚠️ `cfg` 是**函数**，不是值 —— 用的时候写 `cfg()`。理由和
    #    mod_files.R 里那段一样：模块在**登录之前**就注册好了，在模块开头
    #    直接读 state$user_id 会抛
    #    "Can't access reactive value 'user_id' outside of reactive consumer"，
    #    而那是初始化路上抛的，整个应用起不来（2026-09-16 就是这么挂的）。
    cfg <- function() dsapp_config_user(state$user_id, dsapp_config())

    # ★★ V13.7 item 3：发请求前去库里现取那把该用的 Key。
    #
    #   为什么不直接读 state$api_key（它也是从库里来的）：state 是**缓存**，
    #   而它在"切厂商 / 刚粘完 Key"这两拍里可能还没跟上。取一次库是一次走
    #   主键的本地 SELECT，比起一次 LLM 请求的代价可以忽略；而这个函数存在
    #   的意义就是把"用错 Key"这类**静默**故障堵死 —— 用错厂商的 Key 换来
    #   的 401 里一个字都不提厂商，用户只能靠猜。
    #
    #   state$api_key 仍然照读：两个来源都空才算"没配 Key"。反过来只看
    #   state 的话，会退回"库里明明有 Key 却让你去设置页填"那个老毛病。
    api_key_now <- function() {
      k <- tryCatch(dsapp_api_key_effective(state$user_id, state$vendor,
                                            con = dsapp_db(cfg())),
                    error = function(e) "")
      if (nzchar(k)) return(k)
      state$api_key %||% ""
    }

    # =========================================================================
    # 每个对话一份的运行状态（★★ Test_V15.7 item 2）
    # =========================================================================
    #
    # 用户原话：「我发现切换会话时会中断思考，需要多个会话任务能够同时执行，
    # 并支持用户在会话间切换时不中断」。
    #
    # 改之前 `st` 是「**一个 Shiny 会话**一份」：切对话就 dsapp_chat_abort()，
    # 正在流的那一轮连同 agent 循环一起被掐掉（pick_session 里那句"不做切走了
    # 还在后台跑，v1 不划算"）。现在改成「一个**对话**一份」：
    #
    #   runs[[sid]] —— 那个对话自己的 llm 句柄、累加器、循环、用量……
    #   st          —— **别名**，永远指向「当前正显示的那个对话」那一份
    #
    # ⚠️ st 仍然是模块环境里的**一个名字**，一百多处 `st$xxx` 一个字都不用改：
    #    R 的闭包在**调用时**才回环境里找自由变量，所以 use_run() 换绑之后，
    #    所有 observer / 内部函数看到的当场就是新那一份。
    # ⚠️ 反过来说：**任何改 rv$session_id 的地方都必须紧跟着 use_run(sid)**，
    #    否则 st 还指着上一个对话 —— 那是"往别人的对话里写内容"级别的错，
    #    而且不报错。下面几处赋值点旁边都写了 ⚠️ 记号。
    runs <- new.env(parent = emptyenv())

    # 一个空对话号的壳。rv$session_id 在用户发第一条消息之前就是 NULL，
    # 那段时间也得有一份能读能写的运行状态。
    .new_run <- function(sid) {
      r <- new.env(parent = emptyenv())
      r$sid <- sid
      #   r$llm —— LLM 子进程句柄。不用 reactiveVal：那个在 observe 里读一次
      #            就建立依赖，写回去又会触发自己，直接成环。
      #   r$acc —— 流式文本累加器。同理，在轮询 observer 里读 draft() 再写
      #            draft() 会让自己每收到一个分片就重新触发一次，白跑一轮。
      #   r$reason —— 思维链累加器（思考模式下才有内容）
      r$llm <- NULL
      r$acc <- ""
      r$reason <- ""
      r$pending <- NULL
      r$started <- NULL    # 本次生成是什么时候开始的，用来算耗时
      r$tokens <- 0        # **这个对话**累计 token（厂商不给用量就一直停在 0）
      r$finish_reason <- NULL  # 上一轮 LLM 的结束原因（"length" = 被截断）
      r$scene <- "chat"    # 这一轮用的是哪套提示词场景（见 dsapp_llm_begin）
      r$agent <- NULL      # agent 循环状态机，第一次用到时才建（见 agent_of）
      # "正在提交中"的**按对话**闸门。rv$sending 那个是界面用的，见
      # dsapp_chat_send 里的说明。
      r$sending <- FALSE
      r
    }

    #' 注册表的键
    #'
    #' ⚠️⚠️ **空串不能当键**：`env[[""]]` 抛的是
    #'    `attempt to use zero-length variable name`，而注册表在模块初始化时
    #'    就要建一个"还没有对话"的那份（run_of(NULL)）—— 于是整个 App
    #'    **白屏**，app.log 里那三行堆栈指向 run_of，看不出和"没选对话"
    #'    有什么关系。
    #'
    #'    自检扫的是源码文本，看不见这个（`""` 在语法上完全合法）；
    #'    是浏览器探针第一个撞上的 —— 又一次"自检全绿 ≠ 能跑起来"。
    #'    哨兵用 \001 开头，真会话 id 长这样：s-20260930163809-7945，撞不上。
    run_key <- function(sid) {
      k <- tryCatch(as.character(sid)[1], error = function(e) NA_character_)
      if (length(k) != 1L || is.na(k) || !nzchar(k)) return("\001none")
      k
    }

    #' 取某个对话的运行状态，没有就地建一个
    run_of <- function(sid) {
      k <- run_key(sid)
      r <- runs[[k]]
      if (is.null(r)) {
        r <- .new_run(sid)
        assign(k, r, envir = runs)
      }
      r
    }

    #' 把`当前显示的那一份`换成 sid 的
    #'
    #' ⚠️ 只换显示对象，**不掐任何东西**。上一个对话那一轮还在跑 ——
    #'    泵每一拍会把所有活着的 run 都推一把，只把画面留给这一个。
    use_run <- function(sid) {
      st <<- run_of(sid)
      invisible(st)
    }

    #' 把**画面**对齐到 st 现在指的那一份（★★ Test_V15.7 item 2）
    #'
    #' 改之前，"切对话"这一串（abort + agent$stop + 清 acc/reason/tokens +
    #' draft("")）散在四个赋值点里各写一遍，而且写的是**清空**。现在切成
    #' 两步：use_run(sid) 换对象、show_run() 照着这一份重画一遍。
    #'
    #' ⚠️ 关键是"照着**现在的内容**重画"，不是清空：切回一个还在跑的对话，
    #    应该当场看到它已经吐出来的那些字（draft(r$acc)）和正在想的思维链，
    #    而不是一片空白 —— 那正是 item 2 要的效果。
    #' ⚠️ 只能在响应式上下文里调（写 rv$* 和那几个脉冲）。
    show_run <- function() {
      r <- st
      live <- !is.null(r$llm)
      acc <- r$acc %||% ""
      rea <- r$reason %||% ""
      rv$streaming    <- live
      rv$text_started <- live && nzchar(acc)
      rv$thinking     <- live && !nzchar(acc) && nzchar(rea)
      rv$usage <- ""
      rv$error <- NULL
      rv$ctx   <- r$ctx_plan
      draft(acc)
      # 思考区那一格要重画一次（骨架），而且游标必须归零 —— 让它把
      # **这一份**已经收到的思维链整段重贴一遍。不归零的话下一段增量会从
      # "上一个对话贴到哪儿"接着切，用户看到的是被啃掉一截的思维链
      # （本仓的老毛病，症状是字不对但不报错）。
      think_gen(think_gen() + 1L)
      r$reason_sent <- 0L
      hist_ver(hist_ver() + 1)
      sess_ver(sess_ver() + 1)
    }

    #' 弹通知，非当前对话的加一个标题前缀
    #'
    #' ★★ Test_V15.7 item 2：通知是**没有对话归属**的（showNotification 长在
    #' 会话上），而 item 2 之后后台随时可能有别的对话在跑。不加前缀的话，
    #' 用户在 B 里看着，A 那边弹一句「模型服务余额不足」—— 他只会以为是自己
    #' 刚发的这条出了事。
    run_notify <- function(r, msg, type = "warning", duration = NULL) {
      # ★★ 判据是 `r$sid` / `rv$session_id`，**不是** `identical(r, st)`。
      #    五个调用点全都在 pump_run() 里面，而那里 `st` 被临时换绑成了
      #    "正在推的这个 run"（那一段里 `st$xxx` 的意思是"这一个"）——
      #    拿它跟 r 比，永远相等，于是**前缀一次都没加上过**：
      #    后台那个对话出错时，用户看到的还是一句没有归属的
      #    「模型服务余额不足」，正是这一条要防的误解。
      #    同样的道理见 dsapp_llm_begin 里 cur 的判据（那里用的是同一对）。
      if (!identical(r$sid, rv$session_id)) {
        ttl <- tryCatch(as.character(dsapp_session_raw_title(r$sid) %||% ""),
                        error = function(e) "")
        if (!nzchar(ttl)) ttl <- "另一个对话"
        msg <- sprintf("「%s」%s", ttl, msg)
      }
      showNotification(msg, type = type, duration = duration)
    }

    #' 这个对话自己有没有一轮在路上（发请求那一段也算）
    #'
    #' ⚠️ 判据是**这个 run**，不是 rv$streaming —— 后者是"**屏幕上显示的这个**
    #    在不在生成"。拿 rv$streaming 当发送闸门的话，A 在跑、用户切到 B，
    #    他想在 B 里发消息会被一句「正在生成中」挡回去，而 B 上根本没有东西
    #    在生成 —— 那正是"切了会话就动弹不得"的另一个写法。
    run_busy <- function(sid) {
      r <- run_of(sid)
      !is.null(r$llm) || isTRUE(r$sending)
    }

    #' 所有还在跑的 run（泵要挨个推）
    live_runs <- function() {
      out <- list()
      for (k in ls(runs, all.names = TRUE)) {
        r <- runs[[k]]
        if (!is.null(r$llm)) out[[length(out) + 1L]] <- r
      }
      out
    }

    st <- run_of(NULL)

    rv <- reactiveValues(session_id = NULL, streaming = FALSE, error = NULL,
                         thinking = FALSE,
                         # sending：正在"提交中"（查库+拼上下文+起子进程）。
                         # 这段窗口里 streaming 还没置位，靠它挡住重复提交
                         # （理由见 dsapp_chat_send 里的说明）。
                         # ⚠️ 它是**服务端**的闸门，不是界面状态：它在同一个
                         # flush 里先 TRUE 后 FALSE，渲染层读不到中间的 TRUE，
                         # 所以别指望用它渲染出"正在提交"的提示 —— 那段反馈
                         # 由前端自己做（见 www/app.js 的 dsappSetBusy）。
                         sending = FALSE,
                         usage = "",   # 最近一次生成的 token 用量，给界面显示
                         # ★★ V15.5 item 6：「单次使用上限」这一轮算出来的
                         #   预算（list(limit, used, out, pct)，见 models.R 的
                         #   dsapp_ctx_plan）。写它的地方只有一处 ——
                         #   dsapp_llm_begin() 里发请求之前。
                         #   ⚠️ 读条画的是**拼好的 messages** 占了多少，不是
                         #      库里的历史条数。系统提示（工作区文件清单 +
                         #      技能正文 + 执行模型说明）几万字符是常事，
                         #      只数历史的话读条会常年偏低，一直到超限那一刻
                         #      才跳一下 —— 那正是 item 7 要修的老毛病。
                         ctx = NULL,
                         # ★ V13.12 item 20：这里原来有个 `tick = 0`，轮询每跑
                         #   一次就 +1，只为让「已用 N 秒」走字。删掉了 ——
                         #   它换来的走字代价是**每 200ms 重画一次那一格**，
                         #   而 66% 的重画一个字符都没变。秒数现在由前端自己
                         #   走（app.js 读 data-secs），不花服务端往返。
                         #   见 output$hint 上面那段。
                         #
                         # ★★ V15.4 item 3：正文吐出来了没有。
                         #   「正在生成… / 转圈 / 提示词」那一格（output$wait_box）
                         #   读它来决定自己该不该消失。**没有它的话**，那一格
                         #   只能去读 draft()，于是又变成每 200ms 整块重建 ——
                         #   而重建的正是那颗转圈和那行提示词，用户看到的就是
                         #   "一直在闪"。有这个粗粒度的布尔量，一轮里那一格
                         #   最多重画 3 次（置位、正文开始、本轮结束）。
                         text_started = FALSE,
                         # ★★ V15.4 item 4：这一轮是**用户说的哪句话**触发的。
                         #   错误气泡上的「重新发送」要把那句话原样填回输入框，
                         #   而 output$streaming 里拿不到它（那一格每 200ms
                         #   重画，绝不能在那儿查库）。所以在这里存一份 ——
                         #   写入点是 dsapp_chat_send() 里落库那一行，
                         #   和"这句话真的进了对话"是同一时刻。
                         last_user = "",
                         )
    draft     <- reactiveVal("")  # 正在生成的文本（响应式，驱动流式区域重渲染）
    hist_ver  <- reactiveVal(0)   # 历史消息版本号：变了才重渲染
    sess_ver  <- reactiveVal(0)   # 会话列表版本号
    agent_ver <- reactiveVal(0)   # agent 循环状态版本号（状态条、确认卡）
    # ★★ Test_V15.7 item 2：**有 run 上路了** 的脉冲。
    #
    # 泵（下面那个流式轮询）靠它把自己叫醒。没有它的话：泵在全都没跑的时候
    # 就地 return、invalidateLater 也没排上，于是**再也不会醒** —— 用户在 B 里
    # 发一条消息，A 和 B 都不动，页面上看不出任何异常。（这是 agent.R:1339
    # 记过的同一个坑：条件式注册把定时器永久停掉。）
    #
    # ⚠️ 写它的地方只有两处：dsapp_llm_begin（一轮起来）和泵收尾（一轮结束）。
    #    泵自己**不**依赖它建立长期依赖 —— 活着的时候靠 invalidateLater 续命。
    run_ver   <- reactiveVal(0)

    # 把"当前对话"镜像到共享状态，给「文件」页定位对话工作区用。
    #
    # 用 observe 镜像而不是在四个改 rv$session_id 的地方各写一遍：
    # 那种写法迟早会漏掉一处（新建对话、切对话、删对话、发第一条消息时
    # 隐式建对话，一共四处），而漏掉的表现是文件页显示上一个对话的产物，
    # 不报错，只是内容不对。
    observe({
      state$chat_session_id <- rv$session_id
    })

    # =========================================================================
    # 本对话挂载的技能（V8 item 1）
    # =========================================================================
    # 技能是**按对话**挂的（见 skills.R 顶部那段）：换一个对话就是另一套，
    # 所以这一条跟着 rv$session_id 走，不能挂在 state 上（挂 state 上就成了
    # "这个浏览器所有对话共用一套"，那正是要避免的）。
    #
    # `skill_ver` 是重画脉冲 —— 勾选、摘掉、删技能之后 +1。
    # 没有它的话，用户在这个弹窗里改完，输入框上方那排徽章不会变
    # （它们读的是库，而库变了不是任何一个 reactive 的依赖）。
    skill_ver <- reactiveVal(0)

    # ★ V15.3 item 5：「查看」用的两个小状态。
    #   skill_df   —— 弹窗打开那一刻的技能清单（含 body）。查看正文从它里面
    #                 取，不另查一次库：弹窗开着的时候技能库不会变，再查一次
    #                 只是多一次往返。
    #   skill_open —— 正在查看的那条技能的 id，NULL = 没在查看。
    # ⚠️ 用 reactiveVal 而不是直接读 input$skill_view：弹窗是**每次重开都
    #    重建**的，而 input 的值会一直留着 —— 直接读它的话，重开弹窗会
    #    自动把上次看过的那条又展开一遍，而正文是从**新的** df 里取的，
    #    对得上但没必要。见 skill_pick 里那两行重置。
    skill_df <- reactiveVal(NULL)
    skill_open <- reactiveVal(NULL)

    # ⚠️ ignoreNULL = FALSE：收起（发的是 null）必须也能传进来，
    #    不然点「收起」什么都不会发生 —— 而且不报错。
    observeEvent(input$skill_view, skill_open(input$skill_view),
                 ignoreNULL = FALSE)

    # 当前挂载的技能行（已和技能库对过账）。返回 NULL = 这个对话没挂技能。
    attached_skills <- reactive({
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)
      skill_ver()
      ids <- dsapp_session_skills(sid, con = dsapp_db(cfg()))
      if (!length(ids)) return(NULL)
      df <- dsapp_skills_list(state$user_id, con = dsapp_db(cfg()))
      if (is.null(df) || nrow(df) == 0) return(NULL)
      df[df$id %in% ids, , drop = FALSE]
    })

    output$skill_bar <- renderUI({
      sid <- rv$session_id
      df <- dsapp_skills_list(state$user_id, con = dsapp_db(cfg()))
      n_lib <- if (is.null(df)) 0L else nrow(df)

      if (is.null(sid)) {
        # 还没有对话。技能挂在对话上，这时候没有可挂的地方 —— 说清楚，
        # 而不是把整条藏起来：藏起来的话，一个还没建过对话的用户
        # 根本不知道平台有技能这回事（技能库页在另一个标签里，
        # 他不会无缘无故点进去）。
        if (n_lib == 0) return(NULL)
        # 文字压短的理由见下面 chips 那一段（V12 item 1：一整句会把这一排
        # 挤到第二行）。完整那句话挂在 title 上。
        return(div(class = "dsapp-skillbar dsapp-skillbar-muted small",
          title = "新建一个对话之后，可以在这里挂技能。",
          icon("wand-magic-sparkles"),
          " 新建对话后可挂载"))
      }

      cur <- attached_skills()

      # ⚠️ 排在前面的永远是那个「技能」按钮本身，而不是徽章。
      #    徽章会随挂载数量变宽变窄，按钮跟着左右横跳的话，用户第二次
      #    想点它就得多看一眼 —— 一个位置的控件不该因为别处的状态而移动。
      btn <- actionLink(ns("skill_pick"),
        tagList(icon("wand-magic-sparkles"), " 技能",
                if (!is.null(cur)) sprintf("（%d）", nrow(cur))),
        class = "dsapp-skillbar-btn")

      # ★ V12 item 1：这一格空着的时候，文字从一整句压成三个字。
      #
      #   原来的「没有挂技能 —— 这一轮按通用规则来」有 20 个字宽（实测这一格
      #   274px），把整排挤到第二行去了 —— 一排四格变成两排，多占 60px，
      #   而那一屏本来就紧。用户要的是「硬件选择、系统环境**这一行**」。
      #
      #   被压掉的那句没有丢：它挂在 title 上（鼠标停一下就有），而且下面
      #   ctrl_notes 那行本来就写着"这一轮按什么规矩跑"。
      chips <- if (is.null(cur)) {
        list(span(class = "dsapp-skillbar-none small",
                  title = if (n_lib == 0) "技能库还是空的，去「技能」页建一条"
                          else "没有挂技能 —— 这一轮按通用规则来",
                  if (n_lib == 0) "技能库为空" else "未挂载技能"))
      } else {
        lapply(seq_len(nrow(cur)), function(i) {
          sid_i <- cur$id[[i]]
          js <- sprintf(
            "Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
            jsonlite::toJSON(ns("skill_rm"), auto_unbox = TRUE),
            jsonlite::toJSON(as.character(sid_i), auto_unbox = TRUE))
          span(class = "dsapp-skill-chip",
               title = cur$summary[[i]] %||% "",
               icon("wand-magic-sparkles"),
               cur$name[[i]],
               tags$a(href = "#", class = "dsapp-skill-chip-x",
                      onclick = js, title = "这个对话不再用这条", HTML("&times;")))
        })
      }

      div(class = "dsapp-skillbar", btn, chips)
    })

    observeEvent(input$skill_pick, {
      sid <- rv$session_id
      if (is.null(sid)) return()
      df <- dsapp_skills_list(state$user_id, con = dsapp_db(cfg()))
      if (is.null(df) || nrow(df) == 0) {
        return(showNotification(
          "技能库还是空的。到左栏「技能」页新建一条，或者用一句话生成一条。",
          type = "message", duration = 8))
      }
      cur <- dsapp_session_skills(sid, con = dsapp_db(cfg()))

      # 勾选框的每一条写两行：技能名 + 一句话说明。只写名字的话，
      # "差异分析"和"差异表达分析（DESeq2）"这种近似名字根本分不出来，
      # 用户得靠记忆。内置的额外标一下来源。
      # ★ V15.3 item 5：每一行加一个「查看」。
      #
      # 用户原话：「言出法随界面选择技能时需要能对技能的内容进行查看」。
      # 勾选框上只有名字和一句话说明 —— "差异分析"和"差异表达分析（DESeq2）"
      # 这种近似名字，光看说明还是分不清该勾哪一条；而勾错了是**每一轮**都
      # 带着错的规则跑，代价不小。
      #
      # ⚠️ 直接在弹窗里展开，**不叠第二个弹窗**：Bootstrap 的 modal 叠起来
      #    之后，后一层的关闭会把前一层的滚动锁一起解掉（关掉查看之后整个
      #    页面能滚、而弹窗还开着），而且用户要"看着正文决定勾不勾"，
      #    正文被另一层盖住就白看了。
      #
      # ⚠️ onclick 里 stopPropagation **和** preventDefault 一个都不能少：
      #    这一行整块是 <label>，点它里面的任何地方都会**翻掉那个勾选框**
      #    （label 的默认激活行为，不是冒泡 —— 光 stopPropagation 拦不住，
      #    必须 preventDefault）。用户点「查看」的本意是看一眼，结果顺手把
      #    技能勾上了/取消了，而这个变化要等他点「应用」才生效，
      #    中间完全看不出来。
      names_ <- lapply(seq_len(nrow(df)), function(i) {
        tagList(
          span(class = "dsapp-skillpick-name", df$name[[i]]),
          if (isTRUE(df$builtin[[i]] == 1))
            span(class = "badge text-bg-secondary ms-1", "内置"),
          # ⚠️ priority:'event' 是必须的：连点同一条两次也要有反应
          #    （第一次展开、收起来、再点一次还得展开）。普通优先级下
          #    Shiny 看到值没变就**不发**这个 input，表现是"点第二下没反应"。
          tags$a(href = "#", class = "dsapp-skillpick-peek",
                 title = "看一眼这条技能写了什么（不会改变勾选）",
                 onclick = sprintf(
                   "event.stopPropagation();event.preventDefault();Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
                   jsonlite::toJSON(ns("skill_view"), auto_unbox = TRUE),
                   jsonlite::toJSON(as.character(df$id[[i]]), auto_unbox = TRUE)),
                 icon("eye"), " 查看"),
          if (nzchar(df$summary[[i]]))
            div(class = "dsapp-skillpick-sum", df$summary[[i]])
        )
      })

      # 弹窗一开就把上次查看过的那条收起来，并把这一份 df 交给
      # output$skill_peek —— 正文从它里面取，不再查一次库（弹窗开着的时候
      # 技能库不会变）。
      skill_df(df)
      skill_open(NULL)

      showModal(modalDialog(
        title = "这个对话要用哪些技能", size = "l",
        p(class = "small text-muted",
          dsapp_md_inline("勾上的技能会加进这个对话**之后每一轮**的请求里。"),
          "只影响这个对话 —— 别的对话不受影响。"),
        div(class = "dsapp-skillpick",
          checkboxGroupInput(ns("skill_sel"), NULL,
                             choiceNames = names_,
                             choiceValues = as.character(df$id),
                             selected = as.character(cur))),
        uiOutput(ns("skill_peek")),
        div(class = "small text-muted",
          icon("circle-info"), " 技能内容在「技能」页里改，改完这里立刻生效。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("skill_apply"), "应用", class = "btn-primary")
        )
      ))
    })

    # ★ V15.3 item 5：技能正文的行内查看（接上面那颗「查看」）。
    #
    # 用户选的是「只显示渲染后的」—— 所以这里走 dsapp_md_html()，不摆 Markdown
    # 原文。技能正文本来就是写给模型看的一段规则/流程，渲染出来（标题、列表、
    # 表格）比一堆 `##` 好读得多。
    #
    # ⚠️ dsapp_md_html() 是**先转义再渲染**的（见 render.R 的顺序说明），
    #    所以这里用 HTML() 塞进去是安全的 —— 用户自己写的技能正文里
    #    就算有 <script> 也只会显示成字面文字。
    output$skill_peek <- renderUI({
      id <- skill_open()
      if (is.null(id)) return(NULL)
      df <- skill_df()
      if (is.null(df) || !nrow(df)) return(NULL)
      i <- which(as.character(df$id) == as.character(id))
      if (!length(i)) return(NULL)
      i <- i[[1]]
      body <- as.character(df$body[[i]] %||% "")
      tags_ <- as.character(df$tags[[i]] %||% "")

      div(class = "dsapp-skillpeek",
        div(class = "dsapp-skillpeek-head",
          icon("wand-magic-sparkles"), " ",
          tags$b(as.character(df$name[[i]])),
          if (nzchar(trimws(tags_)))
            span(class = "badge text-bg-light ms-2", tags_),
          span(class = "text-muted small ms-2",
               sprintf("%s 字符", format(nchar(body), big.mark = ","))),
          tags$a(href = "#", class = "dsapp-skillpeek-x ms-auto",
                 title = "收起来",
                 onclick = sprintf(
                   "event.stopPropagation();event.preventDefault();Shiny.setInputValue(%s,null,{priority:'event'});return false;",
                   jsonlite::toJSON(ns("skill_view"), auto_unbox = TRUE)),
                 icon("chevron-up"), " 收起")),
        if (nzchar(trimws(body)))
          div(class = "dsapp-skillpeek-body", HTML(dsapp_md_html(body)))
        else
          div(class = "text-muted small", "这条技能没有正文。"))
    })


    observeEvent(input$skill_apply, {
      sid <- rv$session_id
      if (is.null(sid)) return()
      # 整体替换（见 skills.R 的说明）：界面上看到的就是全量，
      # 照这份全量对齐最不容易出错。
      dsapp_session_skills_set(sid, input$skill_sel, state$user_id,
                               con = dsapp_db(cfg()))
      removeModal()
      skill_ver(skill_ver() + 1)
      n <- length(dsapp_session_skills(sid, con = dsapp_db(cfg())))
      showNotification(
        if (n == 0) "这个对话不再挂任何技能"
        else sprintf("这个对话现在挂了 %d 条技能，下一轮起生效", n),
        type = "message", duration = 5)
    })

    # 点徽章上的 ×：立刻摘掉这一条。
    # 走整体替换而不是"删一行" —— 和上面那个按钮用同一条写路径，
    # 少一条只在特定情况下才走到的分支。
    observeEvent(input$skill_rm, {
      sid <- rv$session_id
      if (is.null(sid)) return()
      drop <- suppressWarnings(as.integer(input$skill_rm))
      if (is.na(drop)) return()
      cur <- dsapp_session_skills(sid, con = dsapp_db(cfg()))
      dsapp_session_skills_set(sid, setdiff(cur, drop), state$user_id,
                               con = dsapp_db(cfg()))
      skill_ver(skill_ver() + 1)
    }, ignoreNULL = TRUE)

    # ⚠️ 这里**不需要**再写一条 observeEvent(rv$session_id, ...) 去刷新徽章。
    #    attached_skills() 自己读了 rv$session_id，切对话时 Shiny 的依赖图
    #    会自动让它失效、连带重画 skill_bar。多写一条的话只是白白多一次
    #    重渲染，还会让人误以为"切对话不会自动更新"。

    # 把本模块控件的真实 id 下发给前端，避免在 app.js 里硬编码命名空间。
    # 必须等 onFlushed：服务端 setup 阶段发的自定义消息会赶在客户端注册
    # 好 handler 之前到达，被直接丢掉。
    session$onFlushed(function() {
      session$sendCustomMessage("dsapp:init", list(
        codeAction    = ns("code_action"),
        pickSession   = ns("pick_session"),
        sessionRename = ns("session_rename"),
        sendKey       = ns("send_key"),
        input         = ns("input"),
        sendBtn       = ns("send"),
        # ★ V13.11 item 5：文献速递页把"新建对话 + 发这段提示词"的活交给
        #   本模块（见 R/mod_lit.R 顶上的说明）。那个页面**不可能**自己
        #   拼出这个名字 —— `chat-` 是本模块的命名空间，它硬编码的话，
        #   这里改一下模块 id 就静默失效。所以和其余几个一样下发。
        litGo         = ns("lit_go"),
        # ★ V15.6 item 12：它问你话时那个回答框（静态节点，显隐由服务端切）。
        askBox        = ns("ask_box"),
        askHint       = ns("ask_hint"),
        askReply      = ns("ask_reply")
      ))
    }, once = TRUE)

    # ---- 会话列表 ----
    sessions <- reactive({
      sess_ver()
      # 列当前账号的对话，**以及别人共享给他的**（item 7）。角色的判定在
      # SQL 里做，这一格只负责把 role/owner_name 带上来给界面用。
      # state$user_id 是响应式依赖：换个账号登录时这一格会自动重算
      # （app.R 那边还会整页重载，双保险）。
      db_sessions_list(user_id = state$user_id, con = dsapp_db(cfg()))
    })

    # ---- 当前对话的身份（item 7）--------------------------------------------
    # 全应用只有这一处判定"我对这个对话能做什么"，界面上的每一个写入口
    # （发送、改名、删除、共享）都必须过它。散着判的话，漏一处就是一个
    # 静默的越权：被共享的人能在别人的对话里跑代码。
    sess_role <- reactive({
      sid <- rv$session_id
      if (is.null(sid)) return("none")
      # 依赖 sess_ver：共享名单变了要重算（owner 刚把这个人加进来/踢出去）
      sess_ver()
      db_session_role(sid, state$user_id,
                      is_admin = dsapp_user_is_platform_admin(state$user),
                      con = dsapp_db(cfg()))
    })
    can_write <- reactive({ dsapp_role_can_write(sess_role()) })
    # 共享进来的对话要显眼地说清楚"这是别人的、你只能看"。
    # 不说的话用户会对着一个发不出消息的输入框反复点，然后以为坏了。
    is_readonly <- reactive({
      dsapp_role_can_view(sess_role()) && !dsapp_role_can_write(sess_role())
    })

    # =========================================================================
    # 内部函数：定义在所有 observer 之前
    # =========================================================================

    #' 删除的准入判定 —— 被拒时要说**真话**
    #'
    #' ★★ V16.1 item 3。返回 list(ok = TRUE)，或者
    #'    list(ok = FALSE, msg =, type =, duration =, heal =)
    #'
    #' 改之前这里只有一句 `if (!can_write())`，而 can_write() 来自 sess_role()，
    #' 那一位把三种处境压成同一个 "none"（见 R/db.R 的 db_session_role_ex）：
    #'   ① 对话真的不在了  ② 查库本身抛错  ③ 确实是别人的对话
    #' 三种都回同一句「这是别人共享给你的对话，删不了」。主账号在①和②下会
    #' 被告知一件不存在的事，然后怎么点都删不掉 —— 用户报的"删除会话显示删不掉"
    #' 就是这一句。
    #'
    #' ⚠️ heal = TRUE 表示"这东西已经不在了，把界面拉回真相"：它**不是**一次
    #    拒绝。用户想删的东西已经没了，此时再把"删不了"甩给他，他会以为是自己
    #    点错了、或者权限出了问题。
    del_gate <- function(sid) {
      ex <- db_session_role_ex(sid, state$user_id,
                               is_admin = dsapp_user_is_platform_admin(state$user),
                               con = dsapp_db(cfg()))
      if (dsapp_role_can_write(ex$role)) return(list(ok = TRUE))
      if (identical(ex$why, "missing")) {
        return(list(ok = FALSE, heal = TRUE, type = "warning", duration = 6,
                    msg = "这个对话已经不在了（可能在别处被删掉了），列表已刷新"))
      }
      if (identical(ex$why, "db-error")) {
        # 库读不出来时**别**再猜权限 —— 报原话，用户（和我们）才有得查。
        return(list(ok = FALSE, heal = FALSE, type = "error", duration = NULL,
                    msg = sprintf("删除失败：读不到这个对话（%s）", ex$err)))
      }
      if (identical(ex$role, "shared")) {
        return(list(ok = FALSE, heal = FALSE, type = "warning", duration = 6,
                    msg = "这是别人共享给你的对话，删不了"))
      }
      # 剩下的 none：owner_id 和 viewer_id 都对不上号（登录态失效之类）
      list(ok = FALSE, heal = FALSE, type = "warning", duration = 6,
           msg = "认不出当前账号（登录态可能已失效），刷新页面试试")
    }

    #' 把 del_gate() 的结论落到界面上
    del_gate_notify <- function(g, sid = NULL) {
      if (isTRUE(g$heal)) {
        # ⚠️ 侧栏的 sessions() 只认 sess_ver / state$user_id / cfg() 三个依赖，
        #    删除动作一个都不碰 → 不 +1 的话被删掉的那一行**会一直挂在列表里**
        #    （库里的行早没了）。用户看到的就是"删了还在"。
        sess_ver(sess_ver() + 1)
        # 屏幕上如果正显示着这条已经不存在的对话，把它放掉：它的角色是 none，
        # 留在那儿用户会在一个"查无此对话"的页面上继续点，什么都按不动。
        if (!is.null(sid) &&
            identical(as.character(sid), as.character(rv$session_id))) {
          rv$session_id <- NULL
          show_run()
          agent_ver(agent_ver() + 1)
        }
      }
      showNotification(g$msg, type = g$type, duration = g$duration)
    }

    #' 掐掉**某个对话**正在跑的这一轮（默认：当前显示的那个）
    #'
    #' ★★ Test_V15.7 item 2：切对话**不再**走这里。它现在只在"这一轮真的要
    #    没了"的地方调：用户点停止、对话被删掉、页面关了。
    #'
    #' ⚠️ 显示层那三行（rv$streaming / rv$thinking / rv$usage）只在掐的是
    #    **屏幕上这个**时才写。写错对象的症状是：用户在 B 点停止，A 的转圈
    #    停了而 B 还在转 —— 反过来也一样，两种都不报错。
    dsapp_chat_abort <- function(r = st) {
      if (!is.null(r$llm)) {
        dsapp_llm_abort(r$llm)
        r$llm <- NULL
      }
      r$acc <- ""
      r$reason <- ""
      r$started <- NULL
      if (identical(r, st)) {
        rv$streaming <- FALSE
        rv$thinking <- FALSE
        # 这一轮没跑完就被掐了，厂商不会给用量。留着上一轮的"本次消耗"
        # 会让人以为那就是刚才这一轮的账，不如清掉。
        rv$usage <- ""
      }
      run_ver(isolate(run_ver()) + 1L)
    }

    #' 当前选定的分析环境（item 2）
    #'
    #' 每次执行时现取，不缓存 —— 用户可能在对话中途改了目标。
    #'
    #' ⚠️ `env` 只读 state，不读 input：这一页**没有**环境选择控件（V3 有，
    #    V4 撤了，V5 把选择放到了「环境」页 —— 那里没有 conditionalPanel
    #    那层"切 A 重建 B"的联动）。这里再写 `input$target_env` 会永远拿到
    #    NULL，`%||%` 一路兜到 "system"，看起来"能跑"，实际是把用户在环境页
    #    选的、以及服务端在 .Renviron 里配的基础环境**静默吃掉**了。
    dsapp_current_target <- function() {
      kind <- input$target_kind %||% "server"
      if (identical(kind, "remote")) {
        return(list(kind = "remote", remote = state$remote))
      }
      if (identical(kind, "local")) {
        return(list(kind = "local"))
      }
      # ★ V13.7 item 2：选中的 conda 环境在**应用外面**被删掉了（运维清理、
      #   或者管理页里删的）—— 那条路不会通知这个会话，于是 state$exec_env
      #   指着一个已经不存在的环境，**每一次**执行都失败在同一处，
      #   而用户看到的是一句「请到「设置 → 硬件选择」重新选一个」。
      #   他上次就是这么选的 —— 把平台的活推回去，还推给一个已经做对的人。
      #
      #   平台查得出来，就自己清掉、回到系统环境，让这次执行**能跑**，
      #   然后说一句「已经换了」。
      #
      #   ⚠️ 环境页那个删除处理器（mod_envs.R）只在"在应用里删"的时候才清
      #      state；这里是另一条路，两边都要有。
      #   ⚠️ 只在真的失效时才说话，而且清完就变 "system"、不会再说第二次 ——
      #      所以哪怕这个函数被渲染路径调到，也不会变成刷屏。
      sel <- state$exec_env %||% "system"
      dg <- tryCatch(dsapp_env_sel_dangling(sel, cfg()),
                     error = function(e) list(dangling = FALSE))
      if (isTRUE(dg$dangling)) {
        state$exec_env <- "system"
        sel <- "system"
        tryCatch(
          showNotification(sprintf(
            paste0("原来选的分析环境 %s 已经不在了（可能被删掉了），",
                   "已经自动切回系统环境 —— 这次照常执行。"), dg$env),
            type = "message", duration = 8),
          error = function(e) NULL)
      }
      list(kind = "server", env = sel)
    }

    #' 跳到别的页签
    #'
    #' 页签 id 是 app.R 里 page_navbar(id = "nav") 定的，**没有命名空间** ——
    #' 模块里要写 "nav" 而不是 ns("nav")，加了前缀会找不到。
    #'
    #' tab 认的是 nav_panel 的 **value**（"chat"/"tasks"/"settings"…），
    #' 不是标题。标题是给人看的，随时会改；value 钉死了才好当坐标用。
    #'
    #' ⚠️ 必须走 dsapp_nav_to()（它用的是**顶层** session），不能
    #'    `bslib::nav_select("nav", tab, session = session)` —— 模块自己的
    #'    session 是代理，会把 id 变成 "chat-nav"，于是静默失效。这里原来就是
    #'    那么写的，「去设置」按钮一直是坏的，只是没人报。见 R/utils.R。
    dsapp_goto <- function(tab) {
      dsapp_nav_to(state, tab)
    }

    #' 「本地电脑」模式：不执行，打一个可运行包给用户下载
    #'
    #' 浏览器应用没有办法在访客的电脑上执行代码（那正是浏览器沙箱要防的
    #' 事）。所以这个模式下给的是完整的一套东西，不是假装执行。文案上也
    #' 如实说清楚，见 export.R 顶部。
    dsapp_chat_export <- function(blk) {
      r <- dsapp_export_bundle(
        blk$code, blk$lang,
        env_name = state$exec_env %||% "system",
        cfg = cfg(),
        label = sprintf("%s-%s", blk$lang, format(Sys.time(), "%Y%m%d-%H%M%S"))
      )

      if (!isTRUE(r$ok)) {
        showNotification(r$msg, type = "error", duration = 12)
        return()
      }

      url <- paste0("exports/", utils::URLencode(r$file))
      showModal(modalDialog(
        title = tagList(icon("box-archive"), " 已在本地运行包"),
        easyClose = TRUE,
        p("代码没有在服务器上执行。按你选的「本地电脑」模式，",
          "这里把运行需要的东西打包好了："),
        tags$ul(class = "small",
          tags$li("分析脚本（本次的代码）"),
          tags$li(sprintf("%d 个脚本里用到的数据文件", r$n_files)),
          tags$li("README.md（怎么跑、依赖怎么装）"),
          tags$li("environment.yml（conda 环境定义）")
        ),
        if (nzchar(r$note)) div(class = "dsapp-warn", r$note),
        tags$p(class = "small text-muted mt-2",
               sprintf("压缩包大小 %s。下载后解压，在解压目录里按 README 执行即可。",
                       dsapp_fmt_bytes(r$size))),
        footer = tagList(
          modalButton("关闭"),
          tags$a(href = url, class = "btn btn-primary",
                 icon("download"), " 下载运行包")
        )
      ))
    }

    # 当前提交出去的那一段代码，形如 "<消息号>:<块序号>"（V8 item 6）。
    # NULL = 没有任务在跑。渲染层拿它决定哪张卡片把「确认执行」换成转圈。
    #
    # 为什么不在前端改：见 render.R 里 dsapp_code_card 的说明 —— 前端改完
    # 没人负责改回来，任务结束按钮会永远停在「已提交」。
    run_cid <- reactiveVal(NULL)

    # ★★ V16.1 item 2：往回翻的那几屏。
    #
    # V15.11 的写法是「点几次就多给几份预算」（hist_extra），问题是那个计数
    # **只增不减**，而窗口是**整包重发**的 —— 点七次就是 763 KB 一帧，而且
    # 从此每一次历史重渲染都还要再发一遍。数字见 R/config.R 的
    # DSAPP_HIST_MAX_PAGES 上面那段。
    #
    # 现在改成**分屏**：每一屏自己一个 reactiveVal，装的是**渲染好的**
    # tagList（点的时候算一次、存下来）。点一次 = 算一屏、存进下一个空格。
    #
    # ⚠️⚠️ **每一屏必须是自己的 reactiveVal**，十格共用一个（比如一个
    #    list 的 reactiveVal）等于没改：Shiny 的 renderUI 只要读到那个
    #    reactive 变了就会重画，填第 2 屏会把第 1 屏也重发一遍。
    #    这条是这一版的核心，改之前先想清楚重画的是哪一格。
    hist_pages <- lapply(seq_len(DSAPP_HIST_MAX_PAGES), function(k) reactiveVal(NULL))
    # 已经填了几屏（也等于"下一次该填第几格"）。
    hist_page_n <- reactiveVal(0L)
    # 页面上**最旧**的那条消息是第几条（1-based）。NULL = 一屏都还没翻，
    # 最旧的就是 output$history 那个窗口的开头。
    # ⚠️ 它必须由"点的时候算出来的那个 start"来写，不能在这里另算一遍 ——
    #    两个地方各算一次，迟早对不上（对不上的表现是翻出来的屏和主窗口
    #    之间**漏掉一条**，界面上看就是"有一段话不见了"）。
    hist_oldest <- reactiveVal(NULL)

    # ★★ V16.3 item 6：**主窗口锚在哪一条**。
    #
    #   用户原话：「消息过多被折叠时，按导航栏里的消息无法跳转」。
    #
    #   病根不在跳转那几行代码上，在**目录和消息流的数据源不是同一个**：
    #   目录列的是库里**全部**消息（db_messages_get 一把全取），而消息流
    #   只渲染末尾那一段（DSAPP_HIST_BUDGET_C）。被折叠起来的那几轮在 DOM
    #   里根本没有对应的元素，而 dsappJumpTo 是 `document.getElementById`
    #   找不到就静默 return false —— 点了没反应，控制台干干净净。
    #
    #   ⚠️⚠️ 修法**不是**"把中间那几屏都取回来"（那是 V16.1 花了一版才拆掉的
    #      那个坑的反面）。实测：库里最长的那个对话 167 条 / 377 万字，
    #      渲染出来 4.9 MB —— 从末尾一路取到第 5 条要点 **74 屏**，而一次
    #      能安全发出去的是 1 屏（~65 KB）。取回来这条路在长对话上
    #      **永远**走不到，却会先把链路顶爆（pong 10 秒 → 断线重连 → 黑屏）。
    #
    #   改成**把窗口挪过去**：`hist_end` 是主窗口**末尾**那一条的序号
    #   （NULL = 跟到最后，也就是一直以来的行为）。跳转 = 把这个末尾挪到
    #   被点的那一条上 —— 窗口是"从末尾往回数一屏"，所以目标**必然**在
    #   里面（dsapp_hist_window 的规则①：最后一条永远收），一次点击的
    #   载荷恒定是一屏，和这条消息有多老**无关**。
    #
    #   代价是明写在界面上的：跳过去之后，比它新的那些消息暂时不在窗口里
    #   （顶部那条常驻横条写着还剩多少条、点一下回最新）。这比"点了没反应"
    #   诚实 —— 后者用户根本不知道发生了什么。
    #
    #   ⚠️ 存的是**序号**不是消息 id：消息只会在末尾追加，已有消息的序号
    #      不会变。存 id 的话每次渲染都要 match 一遍，而且"消息被删掉"时
    #      两边的处理是一样的（都要夹到范围内）。
    hist_end <- reactiveVal(NULL)

    # 每条消息**要渲染出去的全部文字**的字符数。思维链也算 —— 它折在
    # <details> 里，但**照样是发出去的**（理由见下面 output$history 里那段）。
    # ⚠️ NA 要当 0：`NA + 5000` 是 NA，而 dsapp_hist_window 会把 NA 一律当 0，
    #    于是一条"有正文、没思维链"的消息会被算成 0 字、窗口反而放进来更多条。
    hist_chars <- function(msgs) {
      rea <- suppressWarnings(nchar(msgs$reasoning))
      rea[is.na(rea)] <- 0
      nchar(msgs$content) + rea
    }

    # ★★ V16.3 item 6：主窗口**到哪一条为止**，以及从那儿往回数一屏的结果。
    #
    #   ⚠️⚠️ 这个函数是**唯一**的口径：output$history、output$hist_more_ui、
    #      目录跳转三处都从它拿。任何一处自己再算一遍（比如"按末尾算"），
    #      在锚点上就会分叉 —— 界面上看是"翻出来的屏和窗口之间少了一条"或者
    #      "同一条出现了两次"，而两边都不报错。
    #   ⚠️ 锚点存的是序号，越界（换对话、消息被删）时**夹回范围内**，不报错：
    #      夹住最坏是"窗口停在最后一条"，而不夹是拿 NA 去 seq_len() —— 那会
    #      直接报 length 错，整个消息区变红。
    hist_win <- function(msgs) {
      n <- nrow(msgs)
      if (n == 0L) return(list(end = 0L, win = dsapp_hist_window(numeric(0))))
      e <- hist_end()
      e <- if (is.null(e)) n else suppressWarnings(as.integer(e))
      if (length(e) != 1L || is.na(e)) e <- n
      e <- max(1L, min(e, n))
      list(end = e,
           win = dsapp_hist_window(hist_chars(msgs[seq_len(e), , drop = FALSE])))
    }

    hist_clear <- function() {
      # ⚠️ 只在**真的有内容**时才写那个 reactiveVal。reactiveVal 不做等值判断，
      #    写一次就失效一次 —— 一屏都没翻的时候每来一条新消息都白写 10 次、
      #    白重画 10 格（agent 跑起来那是几十次）。写成无条件的话不会有错，
      #    只是把"分屏"省下来的那点开销又还回去一点。
      for (k in seq_along(hist_pages)) {
        if (!is.null(hist_pages[[k]]())) hist_pages[[k]](NULL)
      }
      if (hist_page_n() != 0L) hist_page_n(0L)
      if (!is.null(hist_oldest())) hist_oldest(NULL)
    }
    # ⚠️ 换对话要清空。不清的话：在 A 对话里翻到很旧的地方，切到 B 对话
    #    （只有三条消息）—— 那几屏还挂在 B 上面，看着像"翻页记录会自己乱"。
    #
    # ★ V16.3 item 6：锚点（hist_end）一起清。它是个**序号**，只在它自己那个
    #   对话里有意义 —— 带着它切到别的对话，轻则窗口停在半空中，重则
    #   "切过去看见的是 A 对话中段那几句"（序号越界时会被夹住，不报错）。
    observeEvent(rv$session_id, {
      hist_end(NULL)
      hist_clear()
    }, ignoreInit = TRUE)
    # ⚠️⚠️ 消息一变（新写一条、重跑写回一条）也必须清空，**不能留着**：
    #    主窗口是按"末尾一段"算的，新消息一来它的开头就往后挪一条 ——
    #    而已经翻出来的那几屏是**快照**，边界钉死在老位置上。留着就会
    #    在那条缝上**同时**出现在屏里和主窗口里（重复一条气泡），
    #    或者两边都没有（少一条）。重复/丢失都不报错，只是看着不对。
    #    清空的代价是"翻到一半被打断"，但新消息来的时候用户本来就在看末尾。
    observeEvent(state$msg_rev, hist_clear(), ignoreInit = TRUE)

    observeEvent(input$hist_more, {
      sid <- rv$session_id
      if (is.null(sid)) return()
      k <- hist_page_n() + 1L
      if (k > DSAPP_HIST_MAX_PAGES) return()
      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      if (nrow(msgs) == 0) return()
      ch <- hist_chars(msgs)
      # ★ V16.3 item 6：主窗口现在可能**锚在中间**（用户从目录跳过来的），
      #   所以"主窗口从哪开始"要按 hist_win 的口径算，不能再按末尾算 ——
      #   按末尾算的话，翻出来的第一屏会和锚住的那个窗口重叠一段
      #   （同一条消息在屏里和窗口里各出现一次）。
      base <- hist_win(msgs)$win$start
      # 这一屏装的是"上一屏再往前"的一段；一屏都没翻时就是主窗口前面那一段。
      end <- (hist_oldest() %||% base) - 1L
      if (end < 1L) return()
      # ⚠️ 拿**前缀**去算，不是拿全部：dsapp_hist_window 是"从末尾往回数"的，
      #    直接喂全部算出的是主窗口那一屏。
      w <- dsapp_hist_window(ch[seq_len(end)])
      # ⚠️ 规则① 保证至少一条（倒数第一条永远收），所以这里 start <= end 恒成立，
      #    点一下**一定**多露出至少一条 —— 这正是这一版要修的那个"点了没反应"。
      idx <- seq.int(w$start, end)
      # ⚠️ 在这里（observeEvent 的 handler 里）渲染是**故意的**：observeEvent
      #    的 handler 跑在 isolate 里，所以 hist_body 里那些 reactive 读取
      #    不会给这个 observer 挂上依赖 —— 否则每写一条消息这个 observer
      #    自己就会重跑一遍（而它做的事是往界面上插一屏）。
      hist_pages[[k]](hist_body(idx))
      hist_oldest(w$start)
      hist_page_n(k)
    })


    # 本会话**提交过执行**的段（V11 item 10）。卡片上那个纯展示的状态标签
    # 靠它区分「待执行」和「已执行」。
    #
    # ⚠️ 只活在内存里，不进库。刷新页面就清空 = 旧卡片又显示成「待执行」——
    #    这是**故意的**：库里没有"这段跑过没有"的权威记录，硬去猜（比如拿
    #    任务表按代码内容反查）会在模型原地改两行重发时给出错误答案，而
    #    "保守地当作没跑过"最坏也只是多显示一个可执行的入口，不会骗人。
    ran_ids <- reactiveVal(character(0))

    # 手动执行的收尾凭据（V9 item 2）：list(tid, sid, lang)。
    #
    # 「这一次是用户点「确认执行」发起的」这件事只有这里知道。agent 循环
    # 自己发起的那些会由 agent.R 的 feed_result() 写 tool 消息，两边都写
    # 就会出现一条执行两条气泡。
    #
    # ⚠️ 收尾时**不能**用 engine$current_task_id() 反查是哪个任务：e$poll()
    #    第一件事就是把 e$handle 置空，等 state$running 变成 FALSE 传到界面
    #    时，引擎手里已经什么都没有了（拿到 NULL，和"任务不存在"没法区分）。
    #    提交时抄下来是唯一可靠的办法。
    manual_run <- reactiveVal(NULL)

    #' 手动执行结束后把结果写进对话（V9 item 2）
    #'
    #' 用户的原话是「任务系统定位只是一个记录运行日志的地方，请把执行过程
    #' 详细地在言出法随页面展示」。手动执行这条路以前**一条消息都不写** ——
    #' 代码跑完只有一句 toast 飘过去，结果全在「历史任务」页。同一个对话里，
    #' agent 自动跑的每一步都留在流里，用户自己点的那一下反而什么都不留，
    #' 这说不过去。
    #'
    #' 措辞走 dsapp_agent_tool_text()，和 agent 那条**逐字一致**：同一个对话
    #' 里两种来源的执行结果长得不一样的话，模型读上下文时会以为它们是两种
    #' 东西。
    dsapp_write_run_msg <- function(tid, sid, lang) {
      # 拼文本 + 写库都在 R/agent.R 的 dsapp_task_result_write() 里，
      # 这里只补两件**本模块才有**的事：出错时弹通知、写完戳一下历史/会话
      # 两个版本号让界面重画。（提出来是为了让「历史任务」页的重跑也能写，
      # 见那边的 pending_rerun。）
      # ★ V13.7 item 2：两层自动处理。
      #   1) dsapp_db_retry —— 撞上 SQLite 的 database is locked 就自己等
      #      一会儿再来（`busy_timeout` 之外再给一次机会）。
      #   2) dsapp_err_user —— 真失败了也**不把 conditionMessage 摆到屏幕上**。
      #      那是一句英文原文（"database is locked"），对用户没有信息量，
      #      只会让他以为是自己点错了，而他唯一能做的动作是"再点一次"——
      #      那正是平台该自己做的事。原文进审计日志，界面上说人话。
      ok <- tryCatch(
        dsapp_db_retry(function()
          dsapp_task_result_write(tid, sid, cfg = cfg(), lang = lang)),
        error = function(e) {
          showNotification(
            dsapp_err_user(e, "写入这次执行的结果",
                           hint = "结果是跑完了的，只是记录没存上。可以再点一次重跑。"),
            type = "error", duration = 8)
          FALSE
        })
      if (isTRUE(ok)) {
        hist_ver(hist_ver() + 1)
        sess_ver(sess_ver() + 1)
      }
      invisible(ok)
    }

    dsapp_chat_run <- function(blk, cid = NULL) {
      target <- dsapp_current_target()

      if (identical(target$kind, "local")) {
        dsapp_chat_export(blk)
        return()
      }

      # title 不传：由引擎按「任务功能_所属会话」自动起名（V9 item 7），
      # 详见 utils.R 的 dsapp_task_title。
      res <- engine$start(blk$code, blk$lang,
                          session_id = rv$session_id,
                          target = target,
                          user_id = state$user_id)
      if (!isTRUE(res$ok)) {
        # ★ V16.1 item 6：把卡片上那颗按钮还原回去。
        #
        #   前端点「确认执行」时是**乐观**的：先禁用 + 写上"已提交"，再把动作
        #   发上来（见 www/app.js 的 .dsapp-code-run 委托）。服务端这儿有
        #   好几道闸门会拒（引擎正忙、配额满、工作区不可写、安全检查没过），
        #   拒了只弹一条 toast —— 而 toast 几秒就没了，按钮**永远**停在灰色的
        #   「已提交」：用户看到的是"这一段已经提交了"，可它根本没跑，而且他
        #   再点也点不动，唯一的出路是刷新页面。
        #
        #   用户这一条反馈的原话是「我点确认执行，显示已有任务在执行，但是我看
        #   不到任何提示任务在执行的痕迹」—— 他就是被拒的那一方，而界面上留下
        #   的痕迹恰好是最误导的那种。还原按钮和上面那颗浮标是同一件事的两半。
        #
        #   ⚠️ cid 为 NULL 时（agent 循环那条路不传 cid）不发：发出去也没人认。
        if (!is.null(cid)) {
          session$sendCustomMessage("dsapp:coderun_reset",
                                    list(cid = as.character(cid)))
        }
        showNotification(res$msg, type = "error", duration = 8)
      } else {
        # 跑起来了才记 —— 提交失败（配额满、环境被删、安全检查没过）
        # 的时候卡片上不该出现转圈，那等于告诉用户"在跑了"。
        run_cid(cid)
        # 同一个道理：只有真的提交出去了才标「已执行」。V11 item 10 起这个
        # 标记同时决定 composer 里那颗固定按钮是亮还是灰。
        if (!is.null(cid)) ran_ids(unique(c(ran_ids(), cid)))
        manual_run(list(tid = res$task_id, sid = rv$session_id, lang = blk$lang))
        showNotification(
          sprintf("已提交任务 #%d（%s），执行过程就在这个对话里",
                  res$task_id, dsapp_target_label(target)),
          type = "message", duration = 6)
      }
    }

    #' 缺 API Key 时的提醒（item 3；V13.15 item 25 改跳转目标）
    #'
    #' 直接给一条 toast 的话用户得自己找该去哪一页。这里给一个按钮直接跳过去。
    #'
    #' ★ V13.15 item 25（用户原话）：「现在显示没有填 key 的时候，会跳到设置
    #'   页面，而不是模型页面，这个跳转更新一下」。
    #'
    #'   **文案早就改了，跳转没跟着改** —— 这正是这条反馈的全部内容。V13.12
    #'   item 19 把「模型服务」从设置页里拆成左栏独立的一页时，这个函数里
    #'   上面那三条 `tags$li` 都改成了「模型服务」，唯独下面那颗按钮还是
    #'   `dsapp_goto("settings")`、标签还写着「去设置」。于是用户按提示去
    #'   「模型服务」页填好 Key，回来一点按钮，人被送到**设置页** ——
    #'   而设置页上根本没有填 Key 的地方，只能自己再找一圈。
    #'
    #'   ⚠️ 教训：**改文案的时候要顺着手指数一遍这个函数里所有的落点**
    #'      （文字、按钮标签、跳转 value、id）。文案改了一半是最难查的一种
    #'      坏法 —— 界面上那句提示是对的，照着做的用户反而被带错路，而
    #'      自检里没有任何一条会红（断言当时只钉了那三行字）。
    #'
    #'   ⚠️ 闭环变了：原来是「设置页确认后自动跳回对话页」（那一页底部三颗
    #'      「保存并返回对话」）。「模型服务」页只有一个「确认 / 更新」按钮，
    #'      **不会**自动跳回 —— 填完要点左栏的「言出法随」回去。这是那一页
    #'      本来的行为（从导航栏直接进去也是这样的），不是这里漏了什么。
    dsapp_prompt_model <- function(reason = NULL) {
      showModal(modalDialog(
        title = tagList(icon("circle-exclamation"), " 还不能开始对话"),
        easyClose = TRUE,
        if (!is.null(reason)) p(reason),
        p("对话需要一个大模型的 API Key，当前会话里还没有填。"),
        div(class = "small text-muted",
          tags$ul(class = "mb-0",
            tags$li("打开左栏的", tags$b("「模型服务」"), "页，选择厂商（DeepSeek、通义千问、智谱……）"),
            tags$li("每家的 Key 都要去对应官网申请，那里有直达链接"),
            # ⚠️ 这句原来写的是「Key 只存在当前浏览器会话的内存里，不写数据库、
            #    不落盘」—— V6 起是**假的**，而且是对用户说的假话。
            #    用户会据此以为 Key 是一次性的，在公用机器上随手粘贴。
            #    V6 改了行为必须同时改文案，否则等于骗人。
            tags$li("Key 会", tags$b("按账号存在服务器上"),
                    "（下次打开自动填好）；「模型服务」页里有「清除」可以删掉")
          )
        ),
        footer = tagList(
          modalButton("稍后再说"),
          actionButton(ns("goto_model"), "去模型服务",
                       class = "btn-primary", icon = icon("arrow-right"))
        )
      ))
    }

    #' 把一句话作为用户消息发出去，开始一轮生成
    #'
    #' @param extra 非 NULL 时，用**这一段文字**当作用户消息，而不是输入框里
    #'   的内容。V13.8 item 6 的「补点建议」走这条路（见上面 suggest_prompt）。
    #'
    #'   ⚠️ 走这条路时**不清空输入框**：用户可能正打着一半的字（他点"补点
    #'   建议"只是想插一句，不是想把自己写的丢掉），而输入框是这个应用里
    #'   唯一没有草稿的地方 —— 清掉就找不回来了。这个考虑和 input$prefill_input
    #'   那条（V13.7 item 4 改成"追加"而不是"替换"）是同一个。
    #'
    #' @return **真的发出去了**才返回 TRUE。被下面任何一道闸门拦下、或者
    #'   文本是空的，都返回 FALSE。
    #'
    #'   ★ V13.11 item 5：这个返回值是给文献速递那条路用的。它会先建好
    #'     一个新对话再调这里，如果这一趟被"没配模型"之类的闸门拦下，
    #'     那个刚建出来的对话就成了一条**空对话**留在列表里 —— 用户看到的是
    #'     "我点了开始检索，多出来一个空的对话，什么都没发生"。拿到 FALSE
    #'     的那一方负责把它收回去。
    dsapp_chat_send <- function(extra = NULL) {
      # ⚠️ 这里必须**同时**看 sending。
      #
      # rv$streaming 是在 dsapp_llm_start() 之后才置 TRUE 的，它前面那段
      # （查库、拼上下文、起 callr 子进程）要几百毫秒。Shiny 目前是同步地
      # 一条条处理事件的，这段时间里后来的事件只会排队、不会插进来，所以
      # 单看 rv$streaming 眼下也拦得住 —— 但这个"拦得住"依赖的是"这段代码
      # 中途不会把控制权让出去"这条实现细节。哪天 dsapp_llm_start 改成异步、
      # 或者中间插一个 invalidateLater 分支，防线就当场没了，而且不报错。
      # sending 是显式的"正在提交"标志，不依赖任何假设。
      #
      # ★★ Test_V15.7 item 2：闸门改成问**这个对话自己**忙不忙（run_busy），
      #   不再问全局的 rv$streaming。这一条是 item 2 能不能用的分水岭：
      #   问全局的话，A 在跑、用户切到 B，他在 B 里发消息会被一句「正在生成中」
      #   挡回去 —— 而 B 上根本没有东西在生成，用户只能得出"切了会话就废了"。
      #   改成问 run 之后，A 跑 A 的、B 发 B 的，两个轮询泵各推各的。
      if (run_busy(rv$session_id)) {
        showNotification("这个对话正在生成中，请等它结束或点停止", type = "warning")
        return(FALSE)
      }
      r <- run_of(rv$session_id)
      r$sending <- TRUE
      rv$sending <- TRUE
      # 任何路径退出（包括提前 return）都要复位，否则一次报错之后
      # 发送按钮就永久失灵了
      on.exit({
        r$sending <- FALSE
        rv$sending <- FALSE
      }, add = TRUE)

      txt <- if (is.null(extra)) trimws(input$input %||% "") else trimws(extra)
      if (!nzchar(txt)) return(FALSE)

      # ⚠️ 这是只读的**最终闸门**，不是提示。前端把按钮置灰只是让人看得懂，
      #    绕过去（改 DOM、直接发 send 输入）在这里被挡住。共享进来的人
      #    绝不能在这个对话里写消息 —— 那会往 owner 的对话里插内容、
      #    改标题、烧 owner 的 API 额度，而 owner 完全不知道。
      if (!can_write() && !is.null(rv$session_id)) {
        showNotification(
          "这是别人共享给你的对话，只能查看和下载，不能发言。",
          type = "warning", duration = 6)
        return(FALSE)
      }

      # ★ V13.7 item 3：闸门查的是"库里这一刻有没有可用的 Key"，不是内存里
      #   那个可能滞后的副本（见上面 api_key_now 的说明）。
      if (!nzchar(api_key_now())) {
        dsapp_prompt_model()
        return(FALSE)
      }

      # ★ V13.6 item 4：**模型名是空的就别发**。
      #
      #   以前没有这道闸门，因为每一家厂商的目录里都写着静态模型清单
      #   （fallback_models），state$model 不可能空。0DaysSCI 破了这个前提：
      #   它是聚合平台，模型清单得点「获取模型」现拉（写死在代码里必然过期）。
      #   于是"只填了 Key 就发消息"变成一条走得通的路 —— 带 model="" 打过去，
      #   回来的 400 里只有一句 model is required，指不到设置页的哪一格。
      #   自定义 / 中转代理那家有同样的前提，所以这条闸门对它一样有用。
      if (!nzchar(state$model %||% "")) {
        showNotification(
          "还没选模型：左栏「模型服务」那一页里点一下「获取模型」，再挑一个。",
          type = "warning", duration = 10)
        return(FALSE)
      }

      sid <- rv$session_id
      con <- dsapp_db(cfg())
      if (is.null(sid)) {
        sid <- db_session_create(user_id = state$user_id, con = con)
        rv$session_id <- sid
        # ⚠️ 换了对话号就得跟着换运行状态（见 runs 那一段顶部的 ⚠️）。
        #    这一行原来没有、也不需要一个"st"：改之前 st 是全会话一份，
        #    但现在它按对话分，漏了这一行的话第一条消息会写进那个空壳 run。
        use_run(sid)
      }

      db_message_add(sid, "user", txt, con = con)
      # ★ V16.3 item 6：发新消息 = "我要看这一轮" —— 把主窗口拉回末尾。
      #   ⚠️ 不拉回来的话，用户可能正停在很早以前的那一屏（目录跳过去的），
      #      他刚发的那句话渲染在**另一处**，屏幕上什么动静都没有 ——
      #      看起来就是"发出去了但不见了"。那是个比"点了没反应"更糟的状态：
      #      用户会以为消息丢了，然后再发一遍。
      hist_end(NULL)
      # ★★ V15.4 item 4：错误气泡上的「重新发送」靠它把原文填回输入框。
      #   ⚠️ 写在落库**之后**：被前面那几道闸门挡回去的那几次，用户的话
      #      根本没进对话，不该出现在"重新发送"里。
      rv$last_user <- txt

      # 第一条消息顺手当标题。不用 LLM 生成标题：那是一次同步请求，会把整个
      # R 进程（所有用户）卡住一两秒，换来的一点措辞优化不值这个代价。
      hist <- db_messages_get(sid, con = con)
      if (nrow(hist) == 1) {
        db_session_rename(sid, substr(gsub("[\r\n]+", " ", txt), 1, 24), con = con)
      }

      # ⚠️ 只有"用的是输入框里那句话"时才清空它。extra 那条路（补点建议）
      #    一个字都不许动用户正在打的草稿。
      if (is.null(extra)) updateTextAreaInput(session, "input", value = "")
      hist_ver(hist_ver() + 1)
      sess_ver(sess_ver() + 1)

      # ★ V13.12 item 4：发出第一条消息 = "开启任务"的另一个入口。
      #
      # ⚠️ 位置在**所有闸门之后**。放在前面的话，被"没配 Key""没选模型"
      #    挡下来的那几次也会弹这个窗 —— 用户还没开始做任何事，先被问了一个
      #    关于"以后怎么干活"的问题，而那个问题此刻对他没有意义。
      #
      # ⚠️ 这条路覆盖了「总结并生成报告」和文献速递：它们都走
      #    dsapp_chat_send()，所以只在这一个地方挂就够了。
      #
      # ★ V16.1 item 5：两个提示**互斥**。那个弹窗带一层全屏遮罩，而 toast
      #   的层级和它一样高 —— 同时弹的话，用户可能只看见其中一个，而另一个
      #   已经被 unlim_noted 记成"说过了"，这一次会话就再也见不到它。
      #   所以按"弹了窗就不弹 toast"排。
      if (!isTRUE(maybe_ask_agent_pref())) maybe_warn_unlimited()

      dsapp_llm_begin(sid, if (isTRUE(input$agent_mode)) "agent" else "chat")
      invisible(TRUE)
    }

    #' 发起一轮生成（用户发的、和 agent 循环自己发起的，都走这里）
    #'
    #' @param scene "chat"（手动模式）或 "agent"（自动执行模式）。
    #'   决定注入哪一套执行模型说明，见 prompts.R 的 build_system_prompt。
    dsapp_llm_begin <- function(sid, scene = "chat") {
      r <- run_of(sid)
      # ★★ Test_V15.7 item 2：**是不是屏幕上正在看的那个对话。**
      #
      # ⚠️ 只有它才许动显示层（rv$* 和 draft/think_gen），也只有它才许把 st
      #    抢过去。agent 循环给**别的**对话起一轮的时候（用户在 B 里看着，
      #    A 的循环跑完一步要接着问下一轮）走的是同一条路 —— 不拦的话用户
      #    正在看的 B 会被 A 的思维链和正文当场顶掉。
      # ⚠️ 判据用 r$sid / rv$session_id，**不是** identical(r, st)：B 是新对话
      #    时 st 可能还指着上一个（use_run 在调用点，不在这个函数里）。
      cur <- identical(r$sid, rv$session_id)

      r$acc <- ""
      r$reason <- ""
      r$finish_reason <- NULL   # 上一轮的结束原因不能留到这一轮
      r$started <- Sys.time()
      # ★ V15.13：流式限速那个"上次发送时刻"必须**跟着轮次归零**。
      #   ⚠️ r 是按 sid 复用的（见 run_of）：不归零就带着上一轮的时间戳进新
      #      一轮 —— 用户紧接着发第二条，第一拍会被判成"还没到点"，正文最多
      #      晚 2.4 秒才出现。不报错，症状只是"这轮怎么半天不出字"，很难查。
      #      （自检里那条「第一拍永远立刻发」验的是函数，验不到这里，
      #        所以这行注释就是它唯一的守卫。）
      r$pub_at <- 0
      r$scene <- scene
      # ⚠️ 这一轮已经贴出去多少字。见流程泵里 dsapp:think 的发送处 ——
      #    它按**绝对位置**发增量，所以这个游标必须跟着轮次一起归零。
      r$reason_sent <- 0L
      if (cur) st <<- r

      if (cur) {
        rv$error <- NULL
        rv$thinking <- FALSE
        rv$usage <- ""          # 上一轮的用量不能留到这一轮
        # ★★ V15.4 item 3：新的一轮 —— 正文一个字都还没有，占位那一格该出来了。
        #   和 draft("") 必须同时写：只写 draft 的话，wait_box 会因为
        #   text_started 还停在上一轮的 TRUE 而**不显示**，用户对着空白等
        #   几十秒（不报错，就是没动静）。
        rv$text_started <- FALSE
        draft("")

        # ★★ V15.3 item 3：新的一轮 —— 思考过程那一格**唯一**的重画理由。
        #
        # ⚠️ 必须在这里 +1，不能挪到"收到第一段思维链的时候"。挪过去的话，
        #    骨架会比正文晚一拍出现，而 app.js 是**追加**进 <pre> 的：
        #    那一拍的字会被贴进虚空（元素还不存在），用户看到的思考过程
        #    开头永远缺一块 —— 不报错，只是少字。
        #    在这里 +1 则保证骨架先于任何一段思维链存在。
        # ⚠️ 写的这一侧必须在函数里、读的那一侧（output$thinking_box）在别处，
        #    中间隔着一次 flush，不会自激。
        think_gen(think_gen() + 1L)
      }
      # 叫醒泵。没有它的话，全都没在跑的时候泵已经就地返回了，
      # 这一轮起来也没人推（见 run_ver 的说明）。
      run_ver(isolate(run_ver()) + 1L)

      # ★ V13.7 item 5：拼上下文那一段搬进了 R/llm.R 的
      #   dsapp_scene_messages()，因为**脱离会话的后台续跑要拼同一份**
      #   （R/detach.R）。这里只负责把只有会话才知道的东西喂给它。
      #
      #   ⚠️ 环境事实按**当前选中的分析环境**注入（dsapp_current_target()）：
      #      选定 conda 环境或远程机器后还照本机系统环境写提示词，模型会写出
      #      这台机器上装着、目标上没有的包，用户一点执行就报错。
      #   ⚠️ 轮数（V11 item 5）也要一致：用户把滑块调高了，模型自己还以为
      #      只有 6 轮，会提前收尾。agent 还没建起来时退回默认值。
      #   ⚠️ ★ V13.17 item 31：自动结束时间同理 —— 用户选了 8 小时，提示词里
      #      还写着 2 小时的话，模型会按 2 小时来安排节奏（该拆的步骤合成一步、
      #      该等的分析草草收尾），**跑得完也跑得不好**。同一个道理，
      #      界面上那个数和提示词里那个数必须同源。
      messages <- dsapp_scene_messages(
        sid, scene, cfg(),
        target = dsapp_current_target(),
        user_id = state$user_id,
        # ⚠️ 读的是**这个对话自己**的循环（r$agent），不是 st$agent —— 用户
        #    在 B 里看着、A 的循环在下一次请求时，两者不是同一个对象。
        max_iter = (r$agent$max_iter %||% DSAPP_AGENT_MAX_ITER),
        wall_limit = (r$agent$wall_limit %||% DSAPP_AGENT_WALL_DEF),
        vendor = state$vendor,
        model  = state$model,
        # ★ V15.5 item 6：单次使用上限要**跟到拼上下文那一层**。不传的话
        #   历史预算退回保守默认，而读条会拿这个上限当分母 ——
        #   "读条说才用了 1%"和"历史其实被砍到 48000 字符"同时成立。
        ctx_limit = state$ctx_limit)

      # ★ V15.5 item 6：**这一次请求到底发多少 max_tokens，是算出来的。**
      #
      #   改这个之前，用户那一格滑块直接就是 max_tokens，而"能带多少历史
      #   进去"是另一个写死的数 —— 两者谁也不知道谁，加起来超没超窗口全靠
      #   运气。现在只有一个数（单次使用上限），历史预算和回复上限都从它
      #   推出来（models.R 的 dsapp_ctx_plan），所以不可能对不上。
      #
      #   ⚠️ 用户原话是「不需要限制单次回复长度了」——它的意思是回复长度
      #     不再**单独**设一格控件，不是"回复不设限"。不设限的话，历史把这
      #      一轮撑到 99% 之后模型还会再写 6 万字，整个请求照样超窗口，
      #      而厂商拒的是**整个**请求。
      plan <- dsapp_ctx_plan(messages, state$vendor, state$model,
                             state$ctx_limit)
      # ⚠️ `r$ctx_plan` 是**非响应式**的（r 是个 environment）。这是故意的，
      #    而且和本仓那条"非响应式字段会静默定格"的教训不冲突：这里不需要它
      #    触发任何人 —— 它只被两处读，一处是同一函数里紧接着发请求，一处是
      #    回复结束后的那条说明（那一条本来就会被消息落库重画）。
      #    真需要"读条跟着动"的那个值放 rv$ctx（reactiveVal），见下面。
      r$ctx_plan <- plan
      if (cur) rv$ctx <- plan

      res <- tryCatch(
        dsapp_llm_start(api_key_now(), messages,
                        model = state$model,
                        cfg = cfg(),
                        temperature = state$temperature %||% 0.3,
                        max_tokens = plan$out,
                        # 厂商是设置页选的，base_url 随会话走。不给的话
                        # 换厂商后仍然打到 DeepSeek 的地址上，报一个
                        # 莫名其妙的 401。
                        base_url = state$base_url,
                        # 非 DeepSeek 厂商这两个是 NULL，llm.R 就不会发出去。
                        # 传了未知参数有的厂商直接 400，不能一律带上。
                        thinking = state$thinking,
                        reasoning_effort = state$reasoning_effort,
                        # ★ Test_V16.3 item 2：用户自己填的代理（VPN）。
                        #   发消息这一刻**现读一遍库**，不吃缓存 —— 用户完全
                        #   可能在另一个标签页里刚把代理打开，而那个页面和
                        #   这一页是两个 session（state 各是一份）。
                        #   没配 / 没启用时返回 NULL，llm.R 那边就不挂。
                        #   ⚠️ 只挂这一次请求，不是全局（见 R/proxy.R 顶部）。
                        #
                        #   ⚠️ 整句包在 tryCatch 里、而且**不碰 cfg()**：
                        #      这一段本身就在 dsapp_llm_start 的 tryCatch 里，
                        #      读代理失败要是抛出去，会被外面当成"生成失败"，
                        #      用户看到的是"发消息坏了"（本仓有专门的教训：
                        #      cfg() 在会话结束后会抛）。读不到就当没配代理 ——
                        #      大不了这一次走直连，比"发不出去"好得多。
                        proxy = tryCatch(dsapp_proxy_for(state$user_id),
                                         error = function(e) NULL)),
        error = function(e) e
      )

      if (inherits(res, "error")) {
        if (cur) rv$error <- conditionMessage(res)
        # 循环自己发起的这一轮起不来，循环必须停下来 —— 否则它会永远
        # 停在 generating 状态等一个不会到来的 on_llm_done。
        # ⚠️ 停的是**这个对话自己**的循环。
        if (identical(scene, "agent") && !is.null(r$agent)) {
          r$agent$stop("生成失败，循环已停止")
        }
        run_ver(isolate(run_ver()) + 1L)
        return(invisible(FALSE))
      }

      r$llm <- res
      if (cur) rv$streaming <- TRUE
      run_ver(isolate(run_ver()) + 1L)
      invisible(TRUE)
    }

    #' 把思维链**新长出来的那一段**贴到浏览器上（★ V15.3 item 3）
    #'
    #' 走 session$sendCustomMessage，由 www/app.js 的 dsapp:think 处理器往
    #' <pre> 里追加 —— **不经过 renderUI**，所以贴字这件事不会重建任何 DOM
    #' 节点，用户展开的 <details> 和滚到一半的位置都不会被打断。
    #'
    #' @param force 正文刚开始时用（那一段思维链一个字都没多，只是标签要换）。
    #'   不带 force 的话，没有新字就一个包都不发 —— 每 200ms 发一个空包，
    #'   和每 200ms 重画一次是同一件事的两个写法。
    #'
    #' ⚠️ 增量按**绝对位置**切（st$reason_sent 是"已经贴出去多少字"的游标），
    #'    不是"这一拍收到了什么"。这样即使某一拍没发成、或者连着一拍收到了
    #'    好几段，下一拍自动补齐 —— 不会漏字，也不会重复。
    #' ⚠️ 游标只在 dsapp_llm_begin（新一轮开头）归零。中途任何清空 st$reason
    #'    的地方都必须一起清它，理由见流程泵那一段的注释。
    dsapp_think_append <- function(force = FALSE) {
      total <- nchar(st$reason %||% "")
      sent  <- suppressWarnings(as.integer(st$reason_sent %||% 0L))
      # 游标跑飞了（比正文还长）就当没发过，从头贴一遍 —— 重复好过缺字。
      if (is.na(sent) || sent < 0L || sent > total) sent <- 0L
      if (total <= sent && !isTRUE(force)) return(invisible(FALSE))

      session$sendCustomMessage("dsapp:think", list(
        pre   = ns("think_pre"),
        label = ns("think_label"),
        nbox  = ns("think_n"),
        text  = if (total > sent) substr(st$reason, sent + 1L, total) else "",
        n     = total,
        label_text = if (isTRUE(rv$thinking)) "正在思考…" else "正在组织回答…"))
      st$reason_sent <- total
      invisible(TRUE)
    }

    # =========================================================================
    # 事件
    # =========================================================================

    # ---- item 3：从提醒里跳到**模型服务**页（V13.15 item 25 改的目标）----
    #
    # ⚠️ 认的是 nav_panel 的 **value**（app.R 里 `nav_panel("模型服务",
    #    value = "model", …)`），不是标题 —— 写成 "模型服务" 的表现是
    #    "点了没反应"，不报错也不进日志（app.R 那条注释里记着同一件事）。
    #
    # ⚠️ 跳转必须走 dsapp_goto()（顶层 session 上的 nav_select），不能写成
    #    `bslib::nav_select("nav", "model", session = session)`：模块里那个
    #    session 是代理，发出去的是 "chat-nav"，页面上没这个元素，
    #    **什么也不发生**。理由见 R/utils.R 里 dsapp_nav_to() 那段。
    observeEvent(input$goto_model, {
      removeModal()
      dsapp_goto("model")
    })

    # ---- 分析环境选择器 ----
    #
    # 已按 item 4 撤除：conda 环境下拉框（output$env_select）、配套的
    # observeEvent(input$target_env)、以及每 5 秒把列表刷新的 env_ver 轮询，
    # 三个一起删掉了。
    #
    # ⚠️ env_ver 那一段不只是"没用了"，它还是**必须**删的：那个 observe 靠
    #    invalidateLater(5000) 每 5 秒唤醒一次，把一个 reactiveVal 加一。
    #    它读到的东西已经没人用了，但**唤醒本身还在** —— 每个打开对话页的
    #    会话都永远每 5 秒跑一轮 R 代码。留着就是一份纯开销的常驻定时器。
    #
    #    （顺带记下它当年为什么必须 isolate：不 isolate 的话这个 observe
    #     自己依赖 env_ver，而它每轮都把 env_ver 加一，失效传播会在同一次
    #     flush 里把它无限重新排队；shiny 的 flushReact 是 while 循环没有
    #     轮次上限，整个 R 进程会卡死 —— 而 Shiny Server 开源版所有访客共用
    #     一个 R 进程，于是是一个人打开页面、所有人一起白屏，且不报任何错。）

    observeEvent(input$target_kind, {
      state$exec_target <- input$target_kind %||% "server"
    }, ignoreInit = TRUE)

    # ---- 系统环境选择器（V11 item 4）----------------------------------------
    #
    # 用户的原话是「系统环境也与分析环境选择并列」—— 它原来在这条 bar 上只是
    # 一行只读小字（"系统环境（+ 本对话自己的包，到「环境」页可换）"），
    # 真正的选择在「环境」页。
    #
    # ⚠️⚠️ V3 那次的坑必须在这里堵住，因为"改成只读"这条退路已经被用户
    #    的要求取消了。当年的链路是：
    #        控件挂 conditionalPanel → 用户切硬件选择 → conditionalPanel
    #        整块重建 → input$target_env 短暂变 NULL → 写 state 的
    #        observeEvent **把 NULL 当成一个选择**执行 → 环境被悄悄改回
    #        "系统环境"，界面上一句话都没说。
    #    两道锁，缺一不可：
    #      1. 这个控件**不在**任何 conditionalPanel 里（见 mod_chat_ui 的
    #         dsapp-ctrl-bar），所以它压根不会被重建；
    #      2. 写 state 那条 observeEvent 靠 ignoreNULL = TRUE
    #        （observeEvent 的默认值）挡住 NULL，并且额外挡空串。
    #    第 2 条是真正兜底的那条：只要"NULL 不等于一个选择"这件事成立，
    #    以后谁把这个控件挪进 conditionalPanel 也不会重演。
    #
    # ★ V13.4 item 7 改了这里的三处，用户原话是：「言出法随的环境界面，并没有
    #   同步内置环境，选项里只有系统环境一个」。他说的"内置环境"是「环境」页
    #   那个「内置模板」下拉里的单细胞 / 空转 —— 那几份只是**配置**，磁盘上
    #   `data/envs/` 是空的，所以这个下拉里合理地只有"系统环境"一项。合理，
    #   但用户看不到"平台给我准备了什么"，也就无从下手。
    #
    #   改的是三件事：
    #     ① 内置模板里**还没建**的那几个，单独一组列出来（值加 `tpl:` 前缀）。
    #     ② 选中它们不写 state，而是弹一个"要不要现在建"的确认框。
    #     ③ 这个 renderUI 不再是"渲染一次就冻住"的：它依赖 state$env_rev，
    #        「环境」页建好/删掉环境时会推它一下（见 app.R 里那段注释）。
    #        注意**没有**把当年那个 5 秒轮询加回来，理由见上面。
    output$env_slot <- renderUI({
      # ⚠️ 这一行**没有** isolate，是故意的 —— 它就是下面"建好了要重画"
      #    整条链路的接收端。写 state$env_rev 的那两处分别在建好和删除时。
      state$env_rev
      cur <- isolate(state$exec_env %||% "system")
      df <- tryCatch(dsapp_envs_list(cfg(), sizes = FALSE),
                     error = function(e) NULL)

      # ⚠️⚠️ 值在前、标签在后（utils.R 的 dsapp_choices 把方向写死在参数名上）。
      #    这一行最早写的是 `c("system" = "系统环境")` —— 反的，而且**后果
      #    极重**：控件回传的是"系统环境"这四个字，observeEvent 顺手写进
      #    state$exec_env，执行器拿它去查 conda 环境 → 每次都说"选定的 conda
      #    环境 系统环境 不存在" → **所有任务都跑不起来**，包括模型自己发起的
      #    那些。界面上一片正常，选项文字看着也对，只有执行全挂。
      #    （它还是**默认值**：一进对话页就渲染这个控件，谁都躲不开。）
      choices <- dsapp_choices("system", "系统环境")
      if (!is.null(df) && nrow(df) > 0) {
        for (i in seq_len(nrow(df))) {
          # 构建中/失败的环境也列出来，但把状态缀在名字后面 —— 藏起来的话，
          # 用户刚建完环境在这儿找不到它，会以为没建成。
          sfx <- switch(as.character(df$status[[i]]),
                        ready = "", building = "（构建中）",
                        failed = "（上次构建失败）",
                        sprintf("（%s）", df$status[[i]]))
          choices <- c(choices, dsapp_choices(df$name[[i]],
                                              paste0(df$name[[i]], sfx)))
        }
      }
      # ★ 内置模板里还没建的那几个（V13.4 item 7）。
      #   ⚠️ 值必须带 `tpl:` 前缀，不能直接用环境名。理由不是"好看"：
      #      不带前缀的话它就和一个**真环境**的值长得一模一样，于是
      #      ① dsapp_env_selectable() 那道锁挡不住它（它只认"在磁盘上"，
      #         scRNA 建好之后这个值就合法了，而建好之前不合法 ——
      #         同一个字符串两种含义，取决于磁盘状态，这种值不能进 state）；
      #      ② 将来谁把下面那个分支挪走/改坏，用户点一下就会把 "scRNA"
      #         写进 state$exec_env，然后**每个任务**都报"环境 scRNA 不存在"。
      #      带上前缀，它就是另一个命名空间，永远不会和真环境重名。
      pend <- tryCatch(dsapp_env_templates_pending(cfg()),
                       error = function(e) list())
      tpl_choices <- NULL
      if (length(pend)) {
        tpl_choices <- dsapp_choices(
          vapply(pend, function(t) paste0("tpl:", as.character(t$name %||% "")),
                 character(1)),
          # 标签用模板的中文名（"单细胞"）打头，后面缀上它会建出来的环境名 ——
          # 用户在建环境那一页看到的就是这个名字，对得上。
          vapply(seq_along(pend), function(i)
            sprintf("%s（%s）", names(pend)[[i]],
                    as.character(pend[[i]]$name %||% "")), character(1)))
      }

      # cur 是**值**，所以比对的是 unname()，不是 names()
      if (!(cur %in% c(unname(choices), unname(tpl_choices)))) cur <- "system"

      # 只有真的有"没建的内置模板"时才分组。一个只有 optgroup 的下拉框看着
      # 像个坏掉的控件；平时（都建好了）它应该和以前一模一样。
      if (!is.null(tpl_choices)) {
        choices <- list("可用" = choices, "内置环境（未创建）" = tpl_choices)
      }

      selectInput(ns("target_env"), NULL, choices = choices, selected = cur,
                  width = "170px")
    })

    # ★ V13.4 item 7：选中的是"还没建的内置模板"时走这条路。
    #   ⚠️ 位置很讲究：必须在下面那道 dsapp_env_selectable() **之前**。
    #      因为 "tpl:scRNA" 本来就不是磁盘上的环境，那道锁会（正确地）拒绝它，
    #      然后弹一句"界面上显示的名字被当成值回传了，这是平台的问题" ——
    #      用户只是正常点了一下内置模板，却被告知平台坏了，还会被要求截图。
    #      所以这里先接住它，那道锁留给**真正的故障**（值/标签写反）。
    tpl_pick <- reactiveVal(NULL)

    observeEvent(input$target_env, {
      v <- input$target_env
      if (is.null(v) || !nzchar(v)) return(invisible(NULL))
      if (!startsWith(v, "tpl:")) return(invisible(NULL))

      nm <- sub("^tpl:", "", v)
      # 下拉框先拨回当前真正在用的那个。不拨的话，控件的显示值和 state 就
      # 对不上了 —— 用户点了"取消"，界面上却还写着"单细胞"，他会以为已经
      # 切过去了，直到下一个任务报错才发现。
      updateSelectInput(session, "target_env",
                        selected = isolate(state$exec_env %||% "system"))

      pend <- tryCatch(dsapp_env_templates_pending(cfg()),
                       error = function(e) list())
      hit <- Filter(function(t) identical(as.character(t$name %||% ""), nm), pend)
      if (!length(hit)) {
        # 竞态：列表是上一次渲染时算的，这中间可能已经在「环境」页把它建了。
        # 这时候什么都别做，更别弹"要不要建" —— 建到一半的那个更麻烦。
        #
        # ★ V13.7 item 2：原来这里说的是「列表里刷新一下就能看到它」——
        #   把刷新写成了用户的待办。平台自己就会：推一下 state$env_rev，
        #   output$env_slot 立刻重画，那个环境就作为**真环境**出现在下拉里
        #   （这正是 F5 会做的事，只是不用他去按）。
        #
        # ⚠️ 读的一侧**必须** isolate：这个 observeEvent 的触发源是
        #    input$target_env，但它下面要写 state$env_rev —— 不 isolate 的话
        #    它就同时依赖 env_rev，自己写、自己失效，转一圈再回来。
        #    这个仓库里踩过一次（症状不是卡死，是定时器瞬间烧穿然后静默停掉）。
        state$env_rev <- isolate(state$env_rev %||% 0L) + 1L
        showNotification(sprintf("「%s」已经建好了，下拉框里现在就能选它。", nm),
                         type = "message", duration = 8)
        return(invisible(NULL))
      }
      t <- hit[[1]]
      # ⚠️ 放在这里而不是上面 —— 上面那个分支要提前 return，提前存下 nm
      #    会留下一个悬着的值，而 input$tpl_build 是**任何一次**点击都会
      #    触发的（不只是这一次弹窗的），下次谁点到它就会拿这个旧名字去建。
      tpl_pick(nm)
      showModal(modalDialog(
        title = sprintf("内置环境「%s」还没创建", names(hit)[[1]]),
        div(class = "small",
          p(sprintf("它需要先从 conda 把 %d 个包装上（%s）。",
                    length(t$packages %||% character(0)),
                    paste(utils::head(t$packages %||% character(0), 6), collapse = "、"))),
          p("解依赖要几分钟到十几分钟，这段时间你可以在别的页面正常用，建好之后会自动出现在这个下拉框里。"),
          # 走 dsapp_md_inline() 而不是原样塞进去：模板的 note 是写在
          # envs.R 里的，随时可能带上 `**加粗**`（本来就是这个项目的写法）。
          p(class = "text-muted", dsapp_md_inline(t$note %||% ""))
        ),
        footer = tagList(
          modalButton("先不建"),
          actionButton(ns("tpl_build"), "开始创建", class = "btn-primary")
        )
      ))
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # 确认之后真的去建。建的动作本身是**非阻塞**的（envs.R 那套后台作业），
    # 这里点完立刻返回。
    #
    # ⚠️ 这两个 reactiveVal 必须写在下面那个 observe **上面**。shiny 的
    #    observe() 在创建时就会跑第一次（`if (!suspended) o$run()`），
    #    眼下 env_watch() 是 NULL 所以第一轮提前 return、碰不到 env_tick ——
    #    但那是**巧合**，哪天下面的开头改一行就会变成"object 'env_tick'
    #    not found"。
    env_watch <- reactiveVal(NULL)
    env_tick  <- reactiveVal(0L)

    observeEvent(input$tpl_build, {
      removeModal()
      nm <- tpl_pick()
      tpl_pick(NULL)
      if (is.null(nm) || !nzchar(nm)) return(invisible(NULL))

      pend <- tryCatch(dsapp_env_templates_pending(cfg()),
                       error = function(e) list())
      hit <- Filter(function(t) identical(as.character(t$name %||% ""), nm), pend)
      if (!length(hit)) return(invisible(NULL))
      r <- dsapp_env_create_from_template(hit[[1]], cfg())
      if (!isTRUE(r$ok)) {
        return(showNotification(r$msg %||% "没能开始创建",
                                type = "error", duration = 12))
      }
      showNotification(
        sprintf("已开始创建内置环境 %s。可以离开这一页，建好之后它会自己出现在下拉框里。", nm),
        type = "message", duration = 12)
      state$env_rev <- isolate(state$env_rev %||% 0L) + 1L
      env_watch(nm)
    }, ignoreInit = TRUE)

    # ★ 只在这个会话**自己**发起过一次创建、且那次还没结束时才转。
    #
    # ⚠️ 这不是把当年那个每 5 秒空转的 env_ver 轮询加回来 —— 那一个的毛病
    #    是"永远在跑"，每个打开对话页的会话每分钟都要走 12 次磁盘（见上面
    #    那段注释）。这一个的存活区间是**用户刚点过"开始创建"到那次 conda
    #    跑完**，只存在于点了按钮的那一个会话里，跑完 env_watch(NULL) 立刻
    #    停。没人点按钮的时候它一次都不跑。
    #
    # ⚠️⚠️ 这个 observe 里**不能**裸读它自己会写的任何 reactiveVal。
    #     写了又读就是自己依赖自己，而这个 observe 会立刻被重新排队 ——
    #     invalidateLater(5000) 那个"5 秒后再来"就完全失效了，变成**连着转**
    #     到把上面的上限烧穿为止。
    #
    #     这个坑我在这里踩了两次，第二次才看出来：
    #       ① state$env_rev —— 每轮都要 +1，读的那一侧必须 isolate（下面是）。
    #       ② env_tick   —— 本以为"计数器读一下无所谓"，其实一样。症状很
    #          隐蔽：轮询不是"每 5 秒看一次"，而是一秒钟把 721 次预算全烧完
    #          然后**自己停掉**，于是 conda 那几秒的「构建中」状态一次都看不
    #          到，用户那边表现为"建了个环境，下拉框从头到尾没动静，最后刷新
    #          一下才发现好了"。测试里那条断言红了就是它。
    #     （①那种无上限的会把整个 R 进程卡死 —— flushReact 是 while 循环、
    #      没有轮次上限，Shiny Server 开源版所有访客共用一个进程，于是
    #      一个人点一下、所有人白屏。②有上限，所以只是静默失效。）
    # dsapp-selftest: self-reactive-ok env_watch
    #
    #   ⚠️ 上面那行是给 selftest 的**显式豁免**。这个 observe 读 env_watch()
    #     （第 2 行）又写它（下面 720 次兜底和建完那两处）。它不会失控的
    #     理由是：**写进去的永远是 NULL**，而下一轮第 3 行就 `is.null` 直接
    #     return，不会再往下走到任何一个写点。多跑一轮就停。
    #     读那一侧反而**不能** isolate —— 它就是唤醒源：用户点「开始创建」
    #     时由另一个 observeEvent 写 env_watch(nm)，这里靠这个依赖醒过来。
    observe({
      nm <- env_watch()
      if (is.null(nm)) return()
      # 兜底上限。dsapp_env_progress() 在"应用重启过、状态文件里的 pid 也没了"
      # 这条回退路上会返回 done = FALSE 且永远不变（见那里的说明），撞上它
      # 这个 observe 就成了新的常驻定时器 —— 正是要避免的东西。一小时足够
      # 任何一次 conda solve 跑完了。
      n <- isolate(env_tick())
      isolate(env_tick(n + 1L))
      if (n > 720L) {
        env_watch(NULL)
        return()
      }
      invalidateLater(5000)
      state$env_rev <- isolate(state$env_rev %||% 0L) + 1L

      pr <- tryCatch(dsapp_env_progress(nm, cfg()), error = function(e) NULL)
      if (!is.null(pr) && isTRUE(pr$done)) {
        env_watch(NULL)
        if (isTRUE(pr$ok)) {
          showNotification(
            sprintf("内置环境 %s 建好了 —— 已经出现在环境下拉框里，选它就能用。", nm),
            type = "message", duration = 15)
        } else {
          showNotification(
            sprintf("内置环境 %s 没建起来。到「环境」页看这次创建的日志末尾，那里有原因。", nm),
            type = "error", duration = 20)
        }
      }
    })

    # ⚠️ ignoreNULL = TRUE 是**默认值**，这里显式写出来，因为它是这段代码
    #    的全部意义所在：不写清楚的话，下一个人"顺手"改成 FALSE 就把上面
    #    那个坑原样复刻回来了。空串同理 —— selectInput 在选项被删光时
    #    会回一个 ""，那也不是用户的选择。
    observeEvent(input$target_env, {
      v <- input$target_env
      if (is.null(v) || !nzchar(v)) return(invisible(NULL))
      # ★ 内置模板那条路已经在上面那个 observeEvent 里接住了，这里必须让开。
      #   不让开的话它会走到下面那道锁上被拒 —— 而那道锁的提示语是"界面上
      #   显示的名字被当成值回传了，这是平台的问题，请截图给管理员"。
      #   用户只是点了一下内置模板，不该看到这句话。
      if (startsWith(v, "tpl:")) return(invisible(NULL))
      # 第三道锁（V11 补）：v 必须是**我们列出去过的值**。上面两道锁挡的是
      # "控件重建把 NULL 当成选择"，这一道挡的是另一种更隐蔽的错 —— 选项
      # 的"显示文本 / 回传值"写反了，控件回传的是那串中文描述。
      # 那时候 v 又非空、又不是 NULL，前两道锁一个都不拦，它会一路写进
      # state$exec_env，然后**每个任务**都报"选定的 conda 环境 系统环境
      # 不存在"。见 envs.R 的 dsapp_env_selectable()。
      if (!dsapp_env_selectable(v, cfg())) {
        showNotification(
          sprintf("忽略了一个无法识别的环境选项（%s）—— 界面上显示的名字被当成值回传了，这是平台的问题，请把这句话截图给管理员。", v),
          type = "error", duration = 12)
        return(invisible(NULL))
      }
      state$exec_env <- v
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- 自动执行轮数（V11 item 5；★★ V16.5 item 1 跟着「开启」走）--------
    #
    # 用户的原话是「"最多 6 轮"这个轮数可以来一个滑块让用户选择，与分析
    # 环境并列」。原来 6 是写死在 dsapp_agent_new() 的默认参数和界面文案里的。
    #
    # ★ V16.3 item 4 曾把它挪进「不设上限」那一组（当第五个勾）。
    # ★★ V16.5 item 1 又搬回**「自动执行」那一格**，而"要不要上限"不再由
    #   它自己的勾决定，改由**「开启」**决定。用户原话：
    #     「轮数似乎应该是在自动执行界面，自动执行打开应该就不设置轮数，
    #       不打开则弹出轮数设置」。
    #   ⚠️ 语义上这是自洽的：「开启」= 没出错也一直往下跑，给它配一个
    #      "跑满 N 轮就停"的上限是自相矛盾（V16.3 那句"这冲突了"说的就是
    #      这个形状）；「开启」没勾 = 跑一段就停下等你，这时才有一个
    #      "最多几轮"的额度可谈。
    #
    # ⚠️ 改的是 agent **对象上**的 max_iter，不是某个全局常量。
    #    循环运行到一半时用户把滑块拉到 10，下一轮的判断（a$iter >= a$max_iter）
    #    立刻按新值走 —— 这是有意的：用户拉滑块就是在说"再多跑几轮"。
    #
    # ⚠️⚠️ 「开启」的初值是 **FALSE**，所以它**不能**用 chk_now() ——
    #    那个函数的兜底是"勾着"，是给「不设上限」那一组初值为 TRUE 的勾写的。
    #    用它的话，页面刚打开的那几十毫秒里 max_iter 会被算成 Inf，而屏幕上
    #    那个框明明是空的（本仓那句老话：兜底一律取**控件画出来的那个样子**）。
    agent_mode_now <- function() {
      v <- input$agent_mode
      if (is.null(v) || length(v) != 1L || is.na(v)) return(FALSE)
      isTRUE(v)
    }

    #' 现在生效的轮数上限（Inf = 不设上限）
    #'
    #' ⚠️ 和 agent_wall_hours() / agent_fix_max() **逐字同一个形状**，只把
    #'    闸门从"自己那个勾"换成「开启」：开启勾着 → 滑块不在页面上 → Inf；
    #'    刚取消开启、滑块还没报上来 → 用 rv_iter() 里那个记忆值（不是
    #'    DSAPP_AGENT_MAX_ITER，那会让"关掉开启"这个动作在滑块报上来之前
    #'    什么都没改）。
    agent_iter_now <- function() {
      if (agent_mode_now()) return(DSAPP_AGENT_ITER_UNLIMITED)
      v <- input$agent_iter
      if (is.null(v) || length(v) != 1L ||
          is.na(suppressWarnings(as.numeric(v)))) {
        return(dsapp_iter_value(rv_iter()))
      }
      dsapp_iter_value(v)
    }

    observeEvent(input$agent_iter, {
      n <- agent_iter_now()
      h <- suppressWarnings(as.integer(input$agent_iter))
      if (length(h) == 1L && !is.na(h) && h >= 1L) rv_iter(h)
      if (!is.null(st$agent)) st$agent$max_iter <- n
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★★ V16.5 item 1：「开启」这个勾自己也得写一遍，理由和「运行时间」那条
    #   **逐字**相同 —— 勾上去的时候滑块被拆掉（它的可见性就是跟着这个勾走
    #   的），input$agent_iter 变成 NULL，上面那条 observeEvent
    #   （ignoreNULL = TRUE）就不会再跑。
    #   不补这一刀的话：用户拖到 10 轮 → 勾上「开启」→ 界面显示不限轮数、
    #   agent 还是 10 轮用完就停（而且会走"最后一次收尾机会"那一支，
    #   往对话里写一句「已经用满了这次给的轮数」—— 一句假话）。
    #
    # ⚠️ 这里**只补 max_iter 这一件事**。勾上/勾掉「开启」还有别的后果
    #    （a$enabled、停掉正在跑的那一段、问一次偏好设置），那些在同一文件的
    #    `observeEvent(input$agent_mode, ...)` 里，各自一个观察者、各写各的
    #    —— 合并成一个的话，将来改其中一件事就会顺手带坏另一件。
    #    ⚠️ 两个观察者都会在这次点击里跑，先后无所谓：两边读的都是
    #    agent_iter_now()（它现读 input$agent_mode），算出来的是同一个值。
    observeEvent(input$agent_mode, {
      if (!is.null(st$agent)) st$agent$max_iter <- agent_iter_now()
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- ★★ V16.2 item 2：「不设上限」那一组的几个"记忆" --------------------
    #
    # 这几个 reactiveVal 记的是"上一次设的那个数"，**不是**当前生效的值。
    # 当前生效的值永远在真相那一侧（state$ctx_limit / agent 对象），这几个
    # 只回答一个问题：用户取消勾选时，那个刚出现的控件该画在哪一格？
    #
    # ⚠️ 为什么必须有它们：取消勾选的那一瞬间控件才被建出来，而它的 value
    #    只能来自这里 —— 取 0 或者取一个写死的大数，用户看到的都是"我上次
    #    设的数不见了"。而它们**不能**兼当真相（读它们来判断"现在是不是不设
    #    上限"就是两个真相源，本仓在这上面栽过）。
    #
    # ⚠️ 初值取的是**控件自己那本说明书上的默认值**（2 小时 / 3 次 / 128K /
    #    6 轮），和 config.R 里那几个常量同源 —— 别再各写一份字面量。
    rv_wall_h    <- reactiveVal(DSAPP_AGENT_WALL_DEF / 3600)
    rv_fix_max   <- reactiveVal(as.integer(DSAPP_AGENT_AUTOFIX_MAX))
    rv_maxtok_num <- reactiveVal(as.numeric(DSAPP_CTX_DEFAULT))
    # ★ V16.3 item 4：轮数也进了这一组，记忆同上。
    # ⚠️ V16.5 item 1 之后它服务的控件搬去了「自动执行」那一格，但**记忆的
    #    职责一个字没变**：用户勾上「开启」（滑块被拆掉、input$agent_iter
    #    变成 NULL）时，下次取消勾选要画出来的那个数就是它。
    rv_iter      <- reactiveVal(as.integer(DSAPP_AGENT_MAX_ITER))

    # ---- 自动结束时间滑块（★ V13.17 item 31）--------------------------------
    #
    # 用户原话：「把自动结束时间也让用户选择吧」。原来这个数写死在
    # dsapp_agent_new() 的默认参数里（wall_limit = 7200），界面上看不到。
    #
    # ★ V16.2 item 2：这个滑块从「自动执行」那一格**挪进了「不设上限」那一组**
    #   （见 UI 那里的说明）。现在它只在「运行时间」没勾的时候才在页面上 ——
    #   勾着的时候"时长"这个概念不存在，摆一根写着「不设上限」的滑块只会
    #   让那一排更挤。
    #
    # ⚠️ 和轮数那条**同一个形状**：改的是 agent 对象上的值，不是常量。
    #    循环正跑着用户把它从 2 小时拉到 30 分钟，下一轮判断立刻按新值走。
    #    这是有意的 —— 拉滑块就是在说"别跑太久了"，没有理由等这一轮结束。
    #
    # ⚠️ **必须**经过 dsapp_wall_from_slider()：它一次办两件事 ——
    #    ① 认最右那一格（"不设上限"），把刻度值翻成 Inf；
    #    ② 兜住空向量（NULL / integer(0) / NA，见 utils.R 那段）。
    #    直接 as.numeric() 存进去会让 a$wall_limit 变成 numeric(0)，下一轮
    #    `x > a$wall_limit` 求值成 logical(0)，`if (logical(0))` 在**循环内部**
    #    抛错 —— 堆栈里一个字都看不到"时长没设上"。
    #
    # ⚠️ 别再写成 `dsapp_wall_value(input$agent_wall * 3600)`：那是这一版
    #    之前的写法，8.5 × 3600 = 30600 会被钳成 28800，"不设上限"这一档
    #    永远落不了地（详见 dsapp_wall_from_slider 的说明）。
    #
    # ⚠️⚠️ 三个读它的地方**一律走 agent_wall_hours()**，不许裸读 input$agent_wall。
    #
    #   裸读的话，控件还没绑好（NULL / integer(0) / NA —— 页面刚打开的几十
    #   毫秒里就是这样）会被 dsapp_wall_from_slider() 当成"没给值"，退回
    #   **默认的 2 小时**；而用户眼睛看到的是滑块停在最右那一格「不设上限」。
    #   于是"界面说 A、代码在做 B"，而且不报错、不自检也不红 —— 用户要到
    #   第二天发现挂机的循环停在半路，才第一次知道有这回事。
    #
    #   兜底值取**滑块自己的初值**（DSAPP_AGENT_WALL_SLIDER_UNLIM），不是随便
    #   挑一个安全值：控件还没报上来的时候，滑块上画的正是这个数，界面和
    #   行为至少在这一点上是一致的。
    # ★★★ V16.2 item 2：同一个问题又出现了一次，这次是勾选框。
    #
    #   「运行时间」那个勾**画的是勾上的**（静态 value = TRUE），所以它还没
    #   报上来的时候，代码必须当成"勾着的" —— 当成没勾的话，页面刚打开的那
    #   几十毫秒里 agent 会按 rv_wall_h()（2 小时）建起来，而屏幕上那个勾
    #   明明是亮的。就是上面那一段说的"界面说 A、代码做 B"。
    #   兜底一律取**控件画出来的那个样子**，这是这一整块的规矩。
    #
    #   ★ V16.2：这条规矩现在有四个用户（下面那三个勾 + unlim_detail 那个
    #     renderUI），所以抽成一个函数。**四个勾的初值都是 TRUE**，所以
    #    这一条对这四处是同一个答案。
    chk_now <- function(v) {
      if (is.null(v) || length(v) != 1L || is.na(v)) return(TRUE)
      isTRUE(v)
    }

    unlim_wall_now <- function() chk_now(input$unlim_wall)

    # ★★ V16.2 item 2：这个滑块现在**只在取消勾选时才存在**（它住在
    #   output$unlim_detail 里，见上面 UI 那段）。所以它有两个"没有值"的
    #   时刻，而且含义不同：
    #     · 勾着「不设上限」     → 它压根不在页面上 → 不设上限
    #     · 刚取消勾选、还没报上来 → 它是刚被画出来的，画的是 rv_wall_h()
    #   不区分的话，第二种会被当成第一种，用户一取消勾选就看到 agent 仍然
    #   按 Inf 跑（而他正要设一个 2 小时）。
    agent_wall_hours <- function() {
      if (unlim_wall_now()) return(DSAPP_AGENT_WALL_SLIDER_UNLIM)
      v <- input$agent_wall
      if (is.null(v) || length(v) != 1L ||
          is.na(suppressWarnings(as.numeric(v)))) {
        # ⚠️ 兜底取 rv_wall_h()，**不是** DSAPP_AGENT_WALL_SLIDER_UNLIM ——
        #    后者会让"取消勾选"这个动作在滑块报上来之前什么也没改（还是
        #    不设上限），而屏幕上的勾已经没了。
        return(rv_wall_h())
      }
      v
    }

    observeEvent(input$agent_wall, {
      w <- dsapp_wall_from_slider(agent_wall_hours())
      # ★ V16.2 item 2：记住这个数，供下次"取消勾选"时把滑块画在同一格上。
      h <- suppressWarnings(as.numeric(input$agent_wall))
      if (length(h) == 1L && !is.na(h)) rv_wall_h(h)
      if (!is.null(st$agent)) st$agent$wall_limit <- w
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★★ V16.2 item 2：「运行时间」这个勾自己也得写一遍 —— 勾**上去**的时候
    #   滑块会被拆掉，input$agent_wall 变成 NULL，上面那条 observeEvent
    #   （ignoreNULL = TRUE）就**不会**再跑。不在这里补一刀的话：
    #   用户拖到 2 小时 → 勾回「不设上限」→ 界面显示不设上限、agent 还是
    #   2 小时到点就停。"界面说 A、代码做 B"，而且没有任何东西会红。
    observeEvent(input$unlim_wall, {
      if (!is.null(st$agent)) {
        st$agent$wall_limit <- dsapp_wall_from_slider(agent_wall_hours())
      }
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- ★★ V16.2 item 1：「出错自动修」的次数上限 --------------------------
    #
    # 和 agent_wall_hours() **逐字同一个形状**，包括那三条：
    #   · 勾着「不设上限」→ 数字框不在页面上 → 哨兵 0（= 不设上限）
    #   · 刚取消勾选、还没报上来 → 画的是 rv_fix_max()
    #   · 一律经过 dsapp_fix_max_value() 归一（空向量不能漏进去）
    #
    # ⚠️ 这里**不能**退回 DSAPP_AGENT_AUTOFIX_MAX 当兜底。这一项和时长不一样：
    #    时长的兜底"2 小时"是安全的，次数的兜底"3 次"意味着用户取消勾选、
    #    还没来得及填数字，agent 就已经按 3 次建起来了 —— 而他正要设的是
    #    30 次。和上面同一个规矩：兜底取控件画出来的那个样子。
    unlim_fix_now <- function() chk_now(input$unlim_fix)

    agent_fix_max <- function() {
      if (unlim_fix_now()) return(DSAPP_AGENT_AUTOFIX_UNLIM)
      v <- input$fix_max_n
      if (is.null(v) || length(v) != 1L ||
          is.na(suppressWarnings(as.numeric(v)))) {
        return(dsapp_fix_max_value(rv_fix_max()))
      }
      dsapp_fix_max_value(v)
    }

    observeEvent(input$fix_max_n, {
      n <- suppressWarnings(as.numeric(input$fix_max_n))
      if (length(n) == 1L && !is.na(n) && n >= 1) rv_fix_max(as.integer(floor(n)))
      if (!is.null(st$agent)) st$agent$fix_max <- agent_fix_max()
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # 「出错自动修」那个勾自己也得写一遍，理由和上面「运行时间」那条**逐字**
    # 相同：勾上去的时候数字框被拆掉，input$fix_max_n 变 NULL，
    # 上面那条 observeEvent（ignoreNULL = TRUE）不会再跑。
    observeEvent(input$unlim_fix, {
      if (!is.null(st$agent)) st$agent$fix_max <- agent_fix_max()
      agent_ver(agent_ver() + 1)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- ★★ V16.2 item 2：上下文 / 单次输出 这两个勾 -------------------------
    #
    # ⚠️⚠️ 它俩指向**同一个值**（state$ctx_limit）。App 里没有"单独的上下文
    #    上限"这种东西：单次使用上限 = 一次请求（上下文 + 回复）合计多少
    #    token，不限 = 跟随模型自己的窗口。所以这两个勾要么一起亮、要么
    #    一起灭，**不许各存各的**。
    #
    #    用户明确选的就是这个形态（四项全列、但这两项联动），界面上那句小字
    #    也把这件事写出来了 —— 不然用户会以为可以"上下文不设限、输出限死"，
    #    而那个组合在这套代码里表达不出来。
    #
    # ⚠️ 真相在 state$ctx_limit，**不在**这两个 input 上。下面这条
    #    observeEvent 只做单向推送（真相 → 勾选框）；反方向那条负责
    #   （勾选框 → 真相），两条都在，而且都**先比对再写**。
    #    不比对的话这里就是个自激环：推值 → 浏览器回发 → 当成用户改的 →
    #    再写一遍真相 → 再推……页面上表现为勾选框反复闪。（和 mail_notify
    #    那条是同一个坑，那段注释写得很细。）
    observeEvent(state$ctx_limit, {
      unlim <- isTRUE(dsapp_maxtok_is_unlimited(state$ctx_limit))
      updateCheckboxInput(session, "unlim_ctx",    value = unlim)
      updateCheckboxInput(session, "unlim_maxtok", value = unlim)
      # 顺手记下"最近一个真实的数"，供下次取消勾选时画在数字框里。
      if (!unlim) {
        n <- suppressWarnings(as.numeric(state$ctx_limit))
        if (length(n) == 1L && is.finite(n) && n > 0) rv_maxtok_num(n)
      }
    }, ignoreNULL = TRUE, ignoreInit = FALSE)

    #' 把"单次使用上限"改成 v（v = 哨兵 0 表示不设上限）
    #'
    #' ★★ V16.2 item 2。这条路是**跨模块**的：值的真相和那个滑块都住在
    #'   「模型服务」页（R/mod_model.R 的 rv$maxtok），这一页只能发指令。
    #'
    #' ⚠️⚠️ 为什么要绕这一道，而不是在这里直接改 state$ctx_limit 了事：
    #'    模型页那个 observe()（mod_model.R 里读 input$max_tokens 的那个）
    #'    是 state$ctx_limit 的**唯一写入口**，而且它读的是一大堆 input，
    #'    任何一次温度/厂商/模型的变化都会让它重跑一遍。在这里偷偷改
    #'    state$ctx_limit 的话，用户下一脚踩到模型页（哪怕只是拖了下温度）
    #'    就会被那个 observer 用**它自己那份旧值**盖回去 —— 界面上勾还在，
    #'    实际发出去的又变回旧上限了。所以必须让模型页知道这件事。
    #'
    #' ⚠️ 指令带一个自增的 rev：光靠值判断的话，"改成 65536 → 又改回
    #'    65536"这一串在接收端看起来是同一个 list，第二次不触发。
    set_maxtok <- function(v) {
      cmd <- state$maxtok_cmd
      state$maxtok_cmd <- list(
        rev   = (if (is.null(cmd)) 0L else as.integer(cmd$rev %||% 0L)) + 1L,
        value = as.numeric(v))
    }

    #' 勾选框 → 真相 这一个方向：把这一对**一起**设成 want
    #'
    #' ⚠️⚠️ 逻辑只写这一份，两个勾各挂一条 observeEvent 调它。
    #'    为什么不是"一条 observer 挂两个 input"（那样看着更省）：一条挂两个
    #'    的话，处理的时候**分不出是哪个勾被点的**。原来那版是
    #'    `want <- 或(...)`，于是"只取消其中一个勾"算出来的 want 还是 TRUE，
    #'    那一次点击**什么都改不了**：屏幕上那个框已经空了、取消勾选该出现的
    #'    数字框也出现了，实际跑的还是"不设上限"。用户以为收紧了，其实没有。
    #'    —— 这正是本仓最忌讳的"界面说 A、代码做 B"，而且不报错、不自检也
    #'    不红（源码里那两行长得完全正常）。
    #'    分两条之后，want 就是**用户刚点的那个勾的新值**，没有歧义。
    #'    两个勾指着同一个值这件事没变：定下来之后两个框一起按过去。
    #'
    #' ⚠️ **先比对再写**（两个地方都要）：
    #'    · 推值那半：box 上画的已经是 want 就别再 update —— update 会让浏览器
    #'      回发一次，无脑发就是自激环（和 mail_notify 那条同一个坑）。
    #'    · 写真相那半：真相已经是 want 就一个字节都别动。上面那条推送会把
    #'      这两个 input 按到真值上，浏览器回发时这里会被再叫一次。
    apply_unlim_pair <- function(want) {
      want <- isTRUE(want)
      if (!identical(chk_now(input$unlim_ctx), want))
        updateCheckboxInput(session, "unlim_ctx", value = want)
      if (!identical(chk_now(input$unlim_maxtok), want))
        updateCheckboxInput(session, "unlim_maxtok", value = want)
      now <- isTRUE(dsapp_maxtok_is_unlimited(state$ctx_limit))
      if (!identical(want, now))
        set_maxtok(if (want) DSAPP_MAXTOK_UNLIMITED else rv_maxtok_num())
      invisible(NULL)
    }

    observeEvent(input$unlim_ctx,    apply_unlim_pair(input$unlim_ctx),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    observeEvent(input$unlim_maxtok, apply_unlim_pair(input$unlim_maxtok),
                 ignoreNULL = TRUE, ignoreInit = TRUE)

    # 数字框（取消勾选之后出现的那个）→ 真相。
    # ⚠️ 它只在"没勾"的状态下存在，所以这里不需要再看勾选框的脸色：
    #    勾着的时候它压根不在 DOM 里，这个 observeEvent 也就不会响。
    observeEvent(input$maxtok_n, {
      n <- suppressWarnings(as.numeric(input$maxtok_n))
      if (length(n) != 1L || !is.finite(n) || n <= 0) return(invisible(NULL))
      rv_maxtok_num(n)
      set_maxtok(n)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★★ 反方向：真相变了，把新值**拨回**这个数字框。
    #
    #   为什么非要拨：真相（state$ctx_limit）在**两个**地方各画了一份。
    #   用户在模型页把 32768 改成 65536、切回对话页，这个框里还写着 32768 ——
    #   而它看起来**就是**当前生效的那个数（这一页上没有别的东西能戳穿它）。
    #   和 mod_model.R 那条「越界的值拨回输入框」是同一条规矩：
    #   **发出去的要对，看得见的也要对。**
    #
    #   ⚠️ 必须防抖，理由和那边逐字相同：用户在这个框里打字的时候，
    #      每敲一下都会走到 state 那一趟，不防抖的话刚敲下第一个「3」
    #      就被拨成夹取后的值，后面几位全白打 —— 他看到的是"这个框不让我
    #      打字"，比原来那个问题更难查。1.5 秒的语义是"他停手了"。
    #   ⚠️ 不会自激：拨回去之后 input$maxtok_n 就是真值，下一拍 debounce
    #      到期时 identical(cur, n) 成立，当场 return。
    #      （拨回去会让浏览器回发一次 → 那条 observeEvent 又调一次
    #      set_maxtok → 模型页收到时 `identical(rv$maxtok, v)` 成立、原地
    #      返回，所以链条到这里就断了。）
    #   ⚠️ 不设上限（哨兵）那一档**不动这个框**：那时候它压根不在页面上，
    #      而且"不限"没有数字可拨。
    ctx_settled <- reactive(state$ctx_limit) |> shiny::debounce(1500)
    observeEvent(ctx_settled(), {
      if (isTRUE(dsapp_maxtok_is_unlimited(ctx_settled()))) return(invisible(NULL))
      n <- suppressWarnings(as.numeric(ctx_settled())[1])
      if (!is.finite(n) || n <= 0) return(invisible(NULL))
      cur <- suppressWarnings(as.numeric(input$maxtok_n)[1])
      # 记下来：这才是"下次取消勾选时该画在框里的那个数"。
      rv_maxtok_num(n)
      # ⚠️ 只在**画的不一样**时才 update（update 会让浏览器回发一次）。
      if (!is.finite(cur) || !identical(cur, n))
        updateNumericInput(session, "maxtok_n", value = n)
      invisible(NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- 控件下面那句小字（V11 item 3/4/5/6 合并）----------------------------
    #
    # 这四个控件各自从前都带一句说明（"将在 xx 上执行"、"系统环境（+ 本对话
    # 自己的包）"、"已开启，发送消息后会自动跑"……）。合成一排之后如果还是
    # 四句各自顶在控件下面，整条 bar 会变成两层高、每层四段字，读起来像说明书。
    #
    # 现在合成**一行**：只报当前状态下最该被看见的那一句 ——
    #   正在跑 > 硬件选择的后果 > 环境叠加说明 > 开关状态
    # 优先级是"越可能要出事的越靠前"。
    # ★ V13.12 item 20：「第 N/M 轮 + 那句话」的内容指纹。
    #
    #   原来这一格是 `invalidateLater(2000)` —— 每 2 秒**无条件重画一次**，
    #   哪怕轮次和说明一个字都没变。用户原话：「分析进行时页面还是会刷新，
    #   取消这个机制，实时更新蹦出新结果就好」。
    #
    #   现在改成"轮询照旧，但**变了才重画**"：下面这个 observe 每秒看一眼
    #   a$status()，只有拼出来的串真的变了才写 loop_sig()，renderUI 才跟着
    #   重画。同一轮里那句话反复不变的那些次，一次 DOM 都不碰。
    #   这个套路和 output$detach_bar 的 arun_tick 是同一个（那里已经有）。
    #
    #   ⚠️ 读 loop_sig() 的那一侧必须 isolate()：本 observe 同时读它、写它，
    #      裸读就是自己依赖自己，每轮自己叫醒自己（reactiveval-self-invalidation）。
    #   ⚠️ invalidateLater 的**间隔**可以是变化的，但它本身必须**无条件**排在
    #      判断之前 —— 条件式注册那个坑见 R/agent.R 顶部那段（循环会把定时器
    #      永久停掉，而且一声不吭）。空闲时 5 秒一次、跑起来 1 秒一次，
    #      正好：跑起来要跟手，空闲时别占着所有开着的标签页。
    loop_sig <- reactiveVal("")
    observe({
      a0 <- st$agent
      running <- !is.null(a0) && isTRUE(a0$enabled) && isTRUE(a0$active())
      invalidateLater(if (running) 1000 else 5000)

      cur <- ""
      if (running) {
        s0 <- a0$status()
        # ⚠️ ★ V16.3 item 4：分母用 dsapp_iter_label() —— s$max_iter 可能是
        #    Inf（轮数不设上限），而 sprintf("%d", Inf) 直接抛错。这个
        #    observe 是**每秒**跑一次的心跳，抛在这里等于状态条整个停摆。
        cur <- sprintf("%d/%s|%s", s0$iter %||% 0L,
                       dsapp_iter_label(s0$max_iter %||% DSAPP_AGENT_MAX_ITER),
                       s0$note %||% "")
      }
      if (!identical(cur, isolate(loop_sig()))) loop_sig(cur)
    })

    # ★★ V16.3 item 3：这一格**只管「自动执行」那一件事**。
    #
    #   用户原话：「"基础环境是系统环境，本对话自己装的包叠加在它上面。
    #   自动执行已开启（最多 6 轮 / 不限时长），发送后自动跑，随时可点
    #   「停止」。"这一行话其实是两类功能的提示词，请把他合并到一类里去」。
    #
    #   原来这两句是**同一个 output** 拼出来的一行小字（外加"在本地跑"
    #   "远程没验证"那两句）。现在按类拆开：
    #     · 「在哪跑」那几句 → 下面 output$notes_env（住在那个框里）
    #     · 「自动执行」那几句 → 这一个（住在「自动执行」框里）
    #   ⚠️ 两个 output 各自渲染自己的那一格，**互不影响** —— 这也是拆开的
    #      好处之一：以前改环境那一句会让整行重画。
    output$ctrl_notes <- renderUI({
      agent_ver()

      # 1) 循环正在跑：最要紧的是"它现在在干什么"
      a <- st$agent
      if (!is.null(a) && isTRUE(a$enabled) && isTRUE(a$active())) {
        # 依赖：内容变了才重画（见上面 loop_sig 的说明，别再写 invalidateLater）
        loop_sig()
        s <- a$status()
        # ★ V13.8 item 5：这里原来也有一颗 spinner（waiting/want_run/
        #   generating 三态）。删掉，理由同上 —— "第 N/M 轮"那个徽章加上
        #   s$note 那句话已经说清楚了在干什么，转圈只是重复。
        #
        # ⚠️★ V16.3 item 4：分母走 dsapp_iter_label()，**不能**直接
        #    sprintf("%d", ...) —— 轮数不设上限时它是 Inf，而
        #    `sprintf("%d", Inf)` 抛 "invalid format '%d'"。报错点在渲染
        #    函数里，用户看到的是整块状态条不见了，堆栈里一个字都没提"轮数"。
        return(div(class = "dsapp-ctrl-notes",
          tags$span(class = "badge text-bg-primary me-2",
                    sprintf("第 %d/%s 轮", s$iter,
                            dsapp_iter_label(s$max_iter))),
          span(class = "text-muted", s$note %||% "")))
      }

      # 2) 自动执行开着但没在跑
      if (is.null(a) || !isTRUE(a$enabled)) return(NULL)

      # ★ V13.17 item 31：把那句"最多 N 轮"补成"最多 N 轮 / M 小时"。
      #   两条闸是**并列**的（哪个先到算哪个），只说轮数会让用户以为
      #   时间上没有限制 —— 而他刚在左边把那个数调过。
      #
      # ★ V16.2 item 2：不设上限那一档要单独说。dsapp_wall_label(Inf) 念的
      #   是"不设上限"，直接套进"最多 %d 轮 / %s"会变成
      #    「最多 6 轮 / 不设上限」—— 一句话里自己打自己，而用户是照着
      #    这句话判断"要不要去睡觉"的。
      #
      # ★ V16.3 item 4：轮数那一侧同样有两种说法（数字 / 不限轮数）。
      #   两边**各按各的**拼，四个组合都读得通。
      it <- a$max_iter %||% DSAPP_AGENT_MAX_ITER
      w  <- a$wall_limit %||% DSAPP_AGENT_WALL_DEF
      div(class = "dsapp-ctrl-notes",
        span(class = "text-muted",
          icon("circle-check", class = "text-success"),
          sprintf(" 自动执行已开启（%s / %s），发送后自动跑，随时可点「停止」。",
                  if (isTRUE(dsapp_iter_is_unlimited(it))) "不限轮数"
                  else sprintf("最多 %s 轮", dsapp_iter_label(it)),
                  if (isTRUE(dsapp_wall_is_unlimited(w))) "不限时长"
                  else paste0("最多 ", dsapp_wall_label(w)))))
    })

    # ★★ V16.3 item 3：「在哪跑」那一句（原来和上面那段挤在同一行里）。
    #
    #   ⚠️ 它挂在「在哪跑」那个框里，所以它**读的是 target_kind**，
    #      不是 agent 的状态 —— 两个 output 的依赖各是各的，改一个不会
    #      让另一个重画（这正是拆开的意义）。
    output$notes_env <- renderUI({
      kind <- input$target_kind %||% "server"
      if (identical(kind, "local")) {
        return(div(class = "dsapp-ctrl-notes",
          span(class = "text-muted",
            icon("laptop"),
            " 代码不在服务器执行，点「确认执行」会打包给你下载，在你自己的电脑上跑。")))
      }
      if (identical(kind, "remote")) {
        r <- state$remote %||% list()
        return(div(class = "dsapp-ctrl-notes",
          if (!isTRUE(r$verified))
            span(class = "text-warning",
                 icon("triangle-exclamation"),
                 " 远程服务器还没配置或没验证过，去「设置」页填 IP / 账号并测试连接。")
          else
            span(class = "text-muted",
                 icon("server"),
                 sprintf(" 将在 %s@%s:%s 上执行。", r$user, r$host, r$port))))
      }
      env <- state$exec_env %||% "system"
      div(class = "dsapp-ctrl-notes",
        span(class = "text-muted",
          icon("box"), " ",
          if (identical(env, "system")) "基础环境是系统环境"
          else sprintf("基础环境是 conda 环境 %s", env),
          # 对话自己装的那一层永远叠加在基础环境之上，说一句省得用户以为
          # "换了基础环境 = 我装的包没了"。
          "，本对话自己装的包叠加在它上面。"))
    })

    # ⚠️ 读滑块走 dsapp_iter_value()（不是裸 input$agent_iter）：控件刚被画
    #    出来、值还没报上来的那一拍是 NULL / integer(0)，裸读会让这一格
    #    渲染成 "轮" 或者整块消失。走那个函数 = 兜回 6 轮，和滑块画着的那
    #    一格一致（同一个入口，见 utils.R 里那段三种"看起来像没值"的说明）。
    output$iter_label <- renderText({
      sprintf("%s 轮", dsapp_iter_label(dsapp_iter_value(input$agent_iter)))
    })

    # ★ V13.17 item 31：自动结束时间那三个字。
    #
    # ⚠️ 和 iter_label 一样必须是**单独的 output**，但理由更硬：写死成静态
    #    文本的话，用户把滑块从 2 小时拉到 6 小时、小字还写着"2 小时"，他会
    #    以为没生效（或者更糟：以为真的只跑 2 小时就停了）。轮数那个写错了
    #    顶多多跑几轮，这个写错了影响的是"今晚能不能去睡觉"。
    #
    # ⚠️ 走 dsapp_wall_label() 而不是自己 sprintf —— 提示词里那句
    #    「一次自动执行最多 {{MAXWALL}}」用的是同一个函数，两边永远一个说法。
    #
    # ★ V16.1 item 5：读滑块也走 dsapp_wall_from_slider()（和上面那个
    #   observeEvent 同一个入口）。默认那一格是"不设上限"，这里就显示
    #   「不设上限」四个字 —— 用户看到的必须就是他真的选了的那个东西。
    output$wall_label <- renderText({
      dsapp_wall_label(dsapp_wall_from_slider(agent_wall_hours()))
    })

    # =========================================================================
    # ★★ V16.2 item 2：「不设上限」那一组里，"取消勾选之后就地出现"的控件
    # =========================================================================
    #
    # 用户选的就是这个形态（见需求确认）：取消勾选 → 紧接着出现滑块/数字，
    # 而不是"回到某个保守默认、数字得去别的页面改"。
    #
    # ⚠️⚠️ 这是一个 renderUI，所以它重建的**每一条边**都要想清楚。它在下面
    #    这些值变化时要重画：四个勾选框（要出现/收起对应的控件）。**别的
    #    一律 isolate()**，尤其是 rv_wall_h / rv_fix_max / rv_maxtok_num ——
    #    它们会在用户拖滑块、打数字的时候被改写，裸读等于"每拖一格就把滑块
    #    拆了重建"，表现是拖动被硬生生打断、松手时值回跳。本仓那条
    #    「renderUI 别把正在用的控件重建掉」说的就是这个（见 iter_label
    #    那一段）。
    #
    # ⚠️ 四个勾的"还没报上来"一律当成**勾着**（chk_now），和别处同一条规矩：
    #    画的是勾上的，代码就得当成勾上的。不然页面刚打开的那一瞬间这里会
    #    先把三个控件都画出来、随即又收回去 —— 用户看到的是"这一排闪了一下"。
    # ★★ V16.3 item 4：拆成**一格一个 output**（原来是四个勾共用一个
    #    unlim_detail）。两个理由：
    #      · 「就地」—— 用户取消哪一个勾，控件就出现在那一个勾**旁边**。
    #        堆在末尾的话，第一个勾的控件离它两三百像素，得自己找。
    #      · 一个 output 画所有控件时，任何一格变化都会把整块拆了重建 ——
    #        拖运行时间的滑块会把轮数那根也重建一遍。
    #
    # ⚠️⚠️ 每一格**只读自己那个勾**，别的值一律 isolate()：rv_* 会在用户拖
    #    滑块、打数字的时候被改写，裸读等于"每拖一格就把滑块拆了重建"，
    #    表现是拖动被硬生生打断、松手时值回跳。本仓那条「renderUI 别把正在
    #    用的控件重建掉」说的就是这个。
    #
    # ⚠️ 勾的"还没报上来"：四个初值为 TRUE 的勾一律按**勾着**算（chk_now，
    #    和别处同一条规矩：画的是勾上的，代码就得当成勾上的）。不然页面刚
    #    打开的那一瞬间这里会先画出控件、随即又收回去，用户看到"这一排闪了
    #    一下"。
    #    ★ V16.5 item 1：这段里**不再有例外**了 —— 原来那个例外是「轮数」
    #    （初值 FALSE），它连同自己的滑块一起搬去了「自动执行」那一格，
    #    那里的兜底写成 agent_mode_now()，同样是"兜底取控件画出来的样子"
    #    （画的是没勾 → NULL 一律当没勾）。
    #
    # ---- 单次使用上限（「上下文」/「单次输出」没勾就出现）------------------
    output$unlim_ctx_w <- renderUI({
      # 两个勾指向同一个值，要么一起亮要么一起灭（见 apply_unlim_pair）。
      # 判据写成"任一个没勾就画"：万一哪一拍它俩真的分了叉，画出来比藏起来
      # 诚实 —— 用户至少能看到那个数。
      if (isTRUE(chk_now(input$unlim_ctx)) &&
          isTRUE(chk_now(input$unlim_maxtok))) return(NULL)
      # ⚠️ 只画**一个**框，不画两个：这两个勾指向同一个值。
      #    画两个的话，用户会以为能分别设，而改其中一个另一个不动 ——
      #    那正是这一版要消灭的那种界面。
      div(class = "dsapp-unlim-num",
        tags$span(class = "dsapp-unlim-lbl", "单次使用上限"),
        numericInput(ns("maxtok_n"), NULL,
                     value = isolate(rv_maxtok_num()),
                     min = 1024, step = 1024, width = "120px"),
        tags$span(class = "dsapp-unlim-lbl", "token"),
        # 说清楚它管的是哪些东西 —— 用户是照着这句话决定填多少的。
        tags$span(class = "dsapp-unlim-hint",
                  "（一次请求里上下文 + 回复合计；上下文和单次输出都由它管）"))
    })

    # ---- 轮数（「开启」没勾才出现；★ V16.5 item 1 搬回「自动执行」那一格）----
    #
    # ⚠️ 这一格**只在「开启」没勾的时候**画，判据是 `agent_mode_now()`
    #    —— 和「不设上限」那几格是**同一个形状**（`if (勾着) return(NULL)`），
    #    只是那个勾换成了「开启」。用户原话：「自动执行打开应该就不设置轮数，
    #    不打开则弹出轮数设置」。
    #
    # ⚠️ 依赖只有**一个**：input$agent_mode。值一律 isolate(rv_iter()) ——
    #    裸读 rv_iter() 的话，用户每拖一格都会重建 sliderInput 本身，拖动
    #    会被打断（松手时值还可能回跳一格）。本仓那条「renderUI 别把正在用
    #    的控件重建掉」说的就是这个。
    #
    # ⚠️ 滑块和它下面那行字（iter_label）的 class 一个都别改：app.css 里
    #    .dsapp-iter-label 那条规则管的是"数字从 9 跳到 10 时滑块不左右挪"。
    #    ⚠️★ V16.5：滑块从 .dsapp-ctrl-unlim 搬到了 .dsapp-ctrl-agent，
    #    但这两个 class 一个都没动 —— 搬的是它的**父容器**，不是它自己。
    # ⚠️ 那个"6 轮"的小字是**单独的 output**，不能写成静态的 sprintf ——
    #    它是给用户看"我拉到几了"的，写死了就等于滑块在动、数字不动。
    #    也**不能**把整块包进下面这个 renderUI 的依赖里：那样每拖一格都会
    #    重建 sliderInput 本身，拖动会被打断（松手时值还可能回跳一格）。
    #    只重渲染那一个 span，滑块本体一个字节都不动。
    output$iter_w <- renderUI({
      if (agent_mode_now()) return(NULL)
      div(class = "dsapp-iter-slider",
        title = paste0("自动执行的轮数上限：跑到这么多轮就停下来收尾。",
                       "勾上「开启」= 不限轮数，跑到它给出结论或者没有新进展为止"),
        sliderInput(ns("agent_iter"), NULL,
                    min = 1, max = DSAPP_AGENT_ITER_MAX,
                    value = isolate(rv_iter()), step = 1, ticks = FALSE,
                    width = "150px"),
        uiOutput(ns("iter_label"), inline = TRUE,
                 class = "dsapp-iter-label")
      )
    })

    # ---- 自动结束时间（「运行时间」没勾才出现）------------------------------
    #
    # ⚠️ 这两个 class（dsapp-iter-slider / dsapp-wall-slider + dsapp-iter-label）
    #    是和 app.css 里"数字位数变了滑块不左右挪"那条规则配对的，别顺手
    #    "顺便美化一下"。
    output$unlim_wall_w <- renderUI({
      if (unlim_wall_now()) return(NULL)
      div(class = "dsapp-iter-slider dsapp-wall-slider",
        title = paste0("自动执行的总时长上限：到点就停，不管跑到第几轮。",
                       "最右一格是「不设上限」—— 不设的话它会一直跑到",
                       "轮数用完或者没有新进展为止"),
        sliderInput(ns("agent_wall"), NULL,
                    min = DSAPP_AGENT_WALL_MIN / 3600,
                    max = DSAPP_AGENT_WALL_SLIDER_UNLIM,
                    value = isolate(rv_wall_h()),
                    step = DSAPP_AGENT_WALL_STEP / 3600,
                    ticks = FALSE, width = "150px"),
        uiOutput(ns("wall_label"), inline = TRUE,
                 class = "dsapp-iter-label")
      )
    })

    # ---- 出错自动修的次数（「自动修次数」没勾才出现）------------------------
    #
    # ⚠️ 单位写全（"次 / 30 分钟"）：那个窗口是 config.R 里的
    #    DSAPP_AGENT_AUTOFIX_WINDOW，用户看不到它。只写"3 次"的话，
    #    他会以为是"一辈子 3 次"——而实际上半小时就恢复。
    output$unlim_fix_w <- renderUI({
      if (unlim_fix_now()) return(NULL)
      div(class = "dsapp-unlim-num",
        tags$span(class = "dsapp-unlim-lbl", "出错自动修"),
        numericInput(ns("fix_max_n"), NULL,
                     value = isolate(rv_fix_max()),
                     min = 1, step = 1, width = "80px"),
        tags$span(class = "dsapp-unlim-lbl",
                  sprintf("次 / %d 分钟",
                          as.integer(round(DSAPP_AGENT_AUTOFIX_WINDOW / 60)))),
        tags$span(class = "dsapp-unlim-hint",
                  "（半小时内最多自动接手几次；到点会停下来告诉你）"))
    })

    # =========================================================================
    # 输出
    # =========================================================================

    output$session_list <- renderUI({
      df <- sessions()
      if (nrow(df) == 0) {
        return(p(class = "text-muted small px-2", "还没有对话，点上方新建。"))
      }

      # V11 item 2：目录要挂回它自己那个会话行下面，所以这一块现在也依赖
      # 消息版本号。**不是**每 3 秒抖一次的那种依赖 —— hist_ver 只在真的
      # 有消息增删时变（见上面 hist_ver 的说明）。
      #
      # state$msg_rev 同理，是为 item 8 加的（别的模块往对话里写了消息，
      # 会话列表的排序/时间也要跟着变），见 app.R 里的说明。
      hist_ver()
      state$msg_rev

      cur <- rv$session_id
      lapply(seq_len(nrow(df)), function(i) {
        # ⚠️ 共享来的对话**必须**标出来是谁的。不标的话它和自己的对话在
        #    列表里长得一模一样，用户会以为自己什么时候建过一个同名的，
        #    点进去发现发不出消息，再以为自己把什么东西弄坏了。
        shared <- identical(as.character(df$role[i] %||% ""), "shared")
        row <- tags$div(
          class = paste0("dsapp-sess", if (identical(df$id[i], cur)) " active" else "",
                         if (shared) " dsapp-sess-shared" else ""),
          `data-sid` = df$id[i],
          onclick = "dsappPickSession(this)",
          title = df$title[i],
          # ★ V13.1 item 4：标题和「重命名」铅笔各占一头。铅笔包在一个
          #   flex 行里，不用绝对定位 —— 绝对定位的话标题得自己留出右边
          #   那段空白，而那段空白是随图标宽度变的，迟早对不齐。
          tags$div(class = "dsapp-sess-head",
            tags$div(class = "dsapp-sess-title", substr(df$title[i], 1, 40)),
            # ⚠️ 共享进来的对话**不画**这个铅笔。它本来就是只读的
            #    （见 dsapp_role_can_write），画了再拒绝，比根本不画更让人
            #    困惑：「明明给了按钮，为什么点不动？」
            if (!shared)
              tags$a(class = "dsapp-sess-edit", href = "#",
                     title = "重命名这个对话",
                     onclick = "return dsappRenameSession(this, event);",
                     icon("pen"))
          ),
          tags$div(class = "dsapp-sess-time",
            dsapp_fmt_time(df$updated_at[i]),
            if (shared) tags$span(class = "dsapp-sess-badge",
              icon("share-nodes"), " ",
              if (nzchar(df$owner_name[i] %||% ""))
                sprintf("%s 共享", df$owner_name[i]) else "共享")
          )
        )
        # ★ V11 item 2：当前这个会话的二级目录就挂在**它自己那一行**下面。
        #
        # 用户的原话是「对话的子目录应该就显示在对应会话下方，而不是像现在
        # 这样的固定位置」。改之前它是侧栏底部一个全局块，永远只反映"当前
        # 选中的那个对话"—— 位置固定，和它所描述的对象却隔着十几行，
        # 看起来像侧栏自带的功能，而不是"这条会话的属性"。
        #
        # ⚠️ 只给**当前**会话挂。给每条都挂的话，20 个会话就是 20 棵展开的
        #    目录树，侧栏会长到没法用；而且别的会话的目录点了也跳不过去
        #   （跳转是纯客户端的，目标消息此刻不在 DOM 里，见下面的说明）。
        #
        # ⚠️⚠️ 必须**显式 return()**，不能让这个 if 当函数的返回值。
        #    R 的函数体取**最后一个表达式**的值，而 `if (F)` 在条件不成立时
        #    求值为 NULL、**静默丢掉**上面那个 row —— 于是 lapply 交出来的
        #    只有目录，一条会话行都没有。表现是侧栏全空、写着"还没有对话"，
        #    而对话其实是好的（当前对话是自动选中的，消息流照常显示）。
        #    2026-09-15 写完当场踩到：自检 900 多条全绿（它读的是源码文本，
        #    不跑渲染），浏览器里一眼就看出来了。
        if (identical(df$id[i], cur)) {
          toc <- dsapp_toc_ui(df$id[i])
          if (!is.null(toc))
            return(tagList(row, div(class = "dsapp-toc-sess", toc)))
        }
        row
      })
    })

    # ---- 某个对话的二级目录（V9 item 9 / V11 item 2）-------------------------
    #
    # 用户 V9 的原话：「有时候单个对话比较长，可以在对话导航栏里增加二级目录，
    # 可以做定位跳转」。V11 又提了一条：「对话的子目录应该就显示在对应会话
    # 下方，而不是像现在这样的固定位置」。
    #
    # 「一级」是侧栏里那个会话列表（在哪个对话），这里补的是「二级」：
    # **某一个对话**有哪几轮、各轮在讲什么、点一下跳过去。
    #
    # ⚠️ 从 renderUI 提成普通函数，是 V11 item 2 的**关键**一步：目录不再是
    #    一个"位置固定的 output"，而是会话列表里每行可以调用的一个片段。
    #    留在 output$msg_toc 里的话，它只能有一个位置 —— 而用户要的恰恰是
    #    "跟着那条会话走"。
    #
    # ⚠️ 每条的标签取**用户自己发的那句话**，不是模型的回答。模型的回答
    #    开头常常是"好的，我来帮你……"，几十条排下来长得一模一样，目录
    #    就失去分辨力了；用户发的那句才是这一轮真正的标题。
    #
    # ⚠️ 跳转是**纯客户端**的（app.js 的 dsappJumpTo），不绕服务端。
    #    绕一圈的代价是几百毫秒的延迟 + 一次重渲染，而目标元素此刻**已经
    #    在 DOM 里**（目录就是照着消息流渲染的）—— 没有需要轮询等待的情况。
    #
    # ⚠️ 跳转目标只对**当前打开的**那个对话有效：消息流里只有它的消息。
    #    所以调用方只给当前会话挂（见 output$session_list）。
    dsapp_toc_ui <- function(sid) {
      if (is.null(sid)) return(NULL)

      msgs <- tryCatch(db_messages_get(sid, con = dsapp_db(cfg())),
                       error = function(e) NULL)
      if (is.null(msgs) || !nrow(msgs)) return(NULL)

      um <- which(msgs$role == "user")
      # 短对话不挂。判据是**这个对话有多长**，不是"用户问了几轮"。
      #
      # ★★ V13.9 item 1 用户原话：「会话的二级菜单怎么没了，加回来」。
      #
      #    它没被谁删掉 —— V9 加进来那天起，这道闸门写的就是
      #    `if (length(um) < 3)`，「用户轮次不到 3 就不显示」。而这条判据
      #    是**照着聊天软件**想的：那边一问一答就是两条消息，问够三轮才算
      #    长。DS_App 不是这样 —— 用户问一句，agent 循环要跑十几轮、写库
      #    十几条消息（工具调用、执行结果、模型回答各算一条）。
      #
      #    于是就有了这么一种对话：**20 条消息、跨两天、翻了不知道多少屏，
      #    而用户只问过 1 句** —— `length(um)` 是 1，目录一次都不出现。
      #    用户在自己的长对话里找不到目录，说"怎么没了"，完全是对的。
      #    （这不是推测：生产库里 s-20260920102529-5685 就是这个形状，
      #      20 条消息 / 1 个用户轮次，一直挂不出目录。）
      #
      #    改用**消息总条数**当"长不长"的尺子，和 R/config.R 里那句
      #    「长对话的导航栏支持二级目录」对齐。4 条起 —— 一问一答再加一轮
      #    工具调用就到，正好是"这一屏该滚了"的量级。
      if (!length(um) || nrow(msgs) < 4) return(NULL)

      items <- lapply(seq_along(um), function(k) {
        i <- um[k]
        lab <- dsapp_toc_label(msgs$content[i])
        div(class = "dsapp-toc-item",
            `data-anchor` = dsapp_msg_anchor(ns, msgs$id[i]),
            title = lab,
            # ★ V16.3 item 6：第 2/3 个参数是给"目标还没渲染出来"那条路用的
            #   —— 消息 id（发给服务端，让它把窗口挪过去）和那个 input 的名字。
            #   在 DOM 里找得到时它们一个都用不上（老行为：就地滚过去）。
            onclick = sprintf("return dsappJumpTo(%s, %s, %s);",
                              dsapp_js_str(dsapp_msg_anchor(ns, msgs$id[i])),
                              dsapp_js_str(as.character(msgs$id[i])),
                              dsapp_js_str(ns("toc_jump"))),
            span(class = "dsapp-toc-n", k),
            span(class = "dsapp-toc-t", lab),
            span(class = "dsapp-toc-d", dsapp_fmt_time(msgs$created_at[i])))
      })

      # open = NA 是 htmltools 里"布尔属性存在"的写法，渲染成光秃秃的
      # `open`（实测）。写成 open = TRUE 会得到 open="TRUE"，虽然浏览器
      # 也认，但那是碰巧 —— 顺带说一句 FALSE **不会**去掉属性。
      tags$details(class = "dsapp-toc", open = NA,
        tags$summary(icon("list-ul"),
                     sprintf(" 本对话目录（%d 轮）", length(um))),
        div(class = "dsapp-toc-body", items)
      )
    }

    # ---- 共享入口（item 7）--------------------------------------------------
    # 只在"这是我自己/我管的对话"时出现。被别人共享的对话上不显示 ——
    # 让被共享的人再转手共享给别人，等于授权链自己长出去，
    # 而 owner 完全不知道自己的分析被传到了哪。
    output$share_bar <- renderUI({
      sid <- rv$session_id
      if (is.null(sid) || !dsapp_role_can_write(sess_role())) return(NULL)

      shared <- db_session_share_list(sid, con = dsapp_db(cfg()))
      n <- if (is.null(shared)) 0L else nrow(shared)
      div(class = "dsapp-share-bar",
        actionLink(ns("open_share"), tagList(icon("share-nodes"),
          if (n > 0) sprintf(" 已共享给 %d 个账号", n) else " 共享这个对话"),
          class = "small")
      )
    })

    observeEvent(input$open_share, {
      sid <- rv$session_id
      req(sid)
      # 弹窗打开的那一刻再查一次身份。这个按钮本来就只在有权限时渲染，
      # 但"渲染过"和"现在还有权限"是两回事（共享可能已被撤回、身份可能
      # 已变），而下面的保存是真的会写库的。
      if (!dsapp_role_can_write(sess_role())) {
        return(showNotification("这个对话不是你的，改不了共享名单", type = "warning"))
      }

      # 候选账号的筛选、弹窗的形状都在 R/share.R 里 —— 任务页的共享入口
      # 用的是同一份（item 7：从任务页共享出去的，必须和从这里共享出去的
      # 完全一样）。
      # V13 item 3：候选分两拨 —— 同组的列成勾选框，其它账号手填邮箱。
      cand <- dsapp_share_candidates(state, cfg())
      if (nrow(cand$all) == 0) {
        return(showNotification("系统里还没有别的可用账号可以共享", type = "warning"))
      }
      dsapp_share_modal(
        ns,
        intro = tagList(
          "被共享的账号可以", tags$b("查看"), "这个对话的全部消息、代码和任务，",
          "并下载本对话产出的文件。", tags$b("不能"), "发消息、跑代码、改名或删除。"),
        mates = cand$mates,
        selected = dsapp_share_current_ids(sid, cfg()),
        others = cand$others)
    })

    observeEvent(input$do_share, {
      sid <- rv$session_id
      req(sid)
      if (!dsapp_role_can_write(sess_role())) {
        removeModal()
        return(showNotification("这个对话不是你的，改不了共享名单", type = "warning"))
      }
      col <- dsapp_share_collect(input$share_ids, input$share_emails,
                                 state$user_id, con = dsapp_db(cfg()))
      n <- dsapp_share_save(sid, col$ids, state, cfg())
      removeModal()
      if (is.null(n)) return()
      sess_ver(sess_ver() + 1)
      dsapp_share_notify(col, n)
    })

    # 共享进来的对话：输入框上面明说一句。
    # 不说的话用户会对着一个打不出字的输入框反复点，然后以为坏了 ——
    # 而"发不出去"这件事本身是**对的**，不该看起来像故障。
    output$readonly_note <- renderUI({
      if (!is_readonly()) return(NULL)
      div(class = "dsapp-readonly-note",
        icon("lock"),
        sprintf("这是 %s 共享给你的对话，只能查看和下载，不能发言或执行代码。",
                {
                  nm <- sessions()
                  i <- match(rv$session_id, nm$id)
                  if (!is.na(i) && nzchar(nm$owner_name[i] %||% "")) nm$owner_name[i]
                  else "其他账号"
                })
      )
    })

    #' 把一段消息画成气泡（V16.1 item 2 从 output$history 里拆出来的）
    #'
    #' @param only NULL = 按窗口规则画**末尾一段**（就是 output$history 自己）；
    #'   给一串 1-based 下标 = 只画这几条（「显示更早的消息」翻出来的那几屏）。
    #'
    #' ⚠️ 为什么抽成函数而不是两处各写一遍：这 150 行里全是"气泡要长成什么样"
    #    的口径（哪些按钮、哪条挂动作、代码卡黄条什么时候不画、图片从哪个
    #    会话取），抄成两份 = 两份口径，翻出来的那一屏和主窗口迟早长得不一样。
    # ⚠️ 同一份 msgs 读两遍：翻页时这个函数是在**点击那一刻**被调的
    #    （见上面 observeEvent(input$hist_more)），那时读一次库是应该的；
    #    正常渲染时它就是 output$history 那一次。没有"每拍多读一次库"。
    hist_body <- function(only = NULL) {
      hist_ver()
      # V11 item 8：「历史任务」页点重跑写进来的那条执行结果，对话页要能
      # 当场看见。见 app.R 里 state$msg_rev 的说明 —— hist_ver 是本模块
      # 私有的，别的模块加不动它。
      state$msg_rev
      sid <- rv$session_id
      if (is.null(sid)) {
        return(div(class = "dsapp-empty",
          icon("comments"), br(),
          "新建一个对话，或从左侧选择一个已有对话。"))
      }

      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      if (nrow(msgs) == 0) {
        return(div(class = "dsapp-empty",
          "这个对话还是空的。",
          br(), br(),
          tags$div(class = "text-muted small",
            "可以试试：", br(),
            "「帮我写一段 R 代码，读取 expr.csv 做差异分析并画火山图」")))
      }

      # ---- 执行结果气泡要用的材料（V9 item 2）----------------------------
      #
      # ⚠️ 必须**批量**取，不能逐条 db_task_get()。那个函数是 SELECT *，
      #    含 stdout/stderr 两列（单个任务上限 4 MB + 1 MB）。一个跑过几十次
      #    执行的对话，每发一条新消息都要把几十 MB 读出来再扔掉 —— 界面上
      #    看不出来，只是"聊得越久越卡"。db_tasks_meta() 只取轻量列。
      #
      # ⚠️ 产物的归属从 task_files 表读（一次查全对话），不是扫盘。扫盘要
      #    遍历工作区 + 核对每个文件的 mtime，而这段代码在**每次**新消息
      #    落库时都会跑一遍。
      tool_ids <- vapply(which(msgs$role == "tool"),
                         function(i) dsapp_tool_task_id(msgs$content[i]) %||% NA_integer_,
                         integer(1))
      tool_ids <- tool_ids[!is.na(tool_ids)]
      tmeta <- if (length(tool_ids))
                 tryCatch(db_tasks_meta(tool_ids, con = dsapp_db(cfg())),
                          error = function(e) NULL)
               else NULL
      fmap <- tryCatch(db_task_files_map(sid, con = dsapp_db(cfg())),
                       error = function(e) NULL)

      # ★ V15.3 item 4：动作按钮只挂在**最后一条助手消息**尾巴上。
      #
      # ⚠️ 和 pending_code() / pending_ask() 的口径必须一致：那两个函数也是
      #    "只看最后一条助手消息"。不按同一个口径挑气泡的话，会出现
      #    "按钮亮着、但长在一条几轮之前的旧消息下面"—— 点下去跑的是哪一段，
      #    用户根本看不出来。
      #
      # ⚠️⚠️ 必须用**全部**消息算（不是窗口里那几条）：last_asst 决定动作按钮
      #    长在哪条上，窗口一变它就变 → 按钮会跟着窗口漂。
      asst_idx <- which(msgs$role == "assistant")
      last_asst <- if (length(asst_idx)) asst_idx[length(asst_idx)] else NA_integer_

      # ★★ V15.11：历史只渲染**末尾一段**。
      #
      # 为什么：这一段是整包发出去的，而且每写一条消息、每次 run_cid()/
      # hist_ver()/msg_rev 变化都要整体重渲染 —— 一轮对话里三四次。用户那个
      # 74 条的对话渲染出来是 **1158 KB**，在 50 KB/s 的链路上要 23 秒，
      # 而 node 那侧的 SockJS 心跳只等 10 秒 pong：超时 → close(3000)
      # → 客户端对干净关闭**故意不重连** → 自愈整页重载 → 黑屏。
      # 数字和整条推理链写在 R/config.R 的 DSAPP_HIST_BUDGET_C 上面。
      #
      # ⚠️ 藏起来的只是**渲染**，不是数据：翻上去看靠「显示更早的消息」
      #    那颗按钮，或者用左侧的对话列表/导出 —— 库里一个字都没少。
      #
      # ★ V15.12 item 3：预算里**必须**把思维链一起数进去。
      #   V15.11 只数了 `nchar(msgs$content)`，而思维链是跟正文一起渲染、
      #   一起发下去的（见下面 dsapp_msg_bubble 的 `reasoning =`）—— 线上库
      #   实测它占那一包的 **26%~51%**（uid=1 那个号最重：单个对话光思维链
      #   454 KB，比正文还长）。不数它 = 窗口按 50 KB 收紧，实际发出去 90 KB
      #   —— 那就是"按预算算好了、真发出去的还是超"。同一个漏法在 V14 的
      #   内联图片上也栽过一次（见 DSAPP_HIST_BUDGET_C 的说明）。
      #
      #   ⚠️ NA 要当 0，**不能**让 NA 直接参与加法：`NA + 5000` 是 NA，而
      #      dsapp_hist_window 会把 NA 一律当 0 —— 于是一条"有正文、没思维链"
      #      的消息会被算成 0 字，窗口反而放进来**更多**条。线上 624 条消息
      #      里有 370 条没有思维链，这条路是常态不是边角。
      #      （口径抽在 hist_chars() 里，翻页那一侧用的是**同一个**函数。）
      #
      # ★★ V16.1 item 2：窗口**不再随点击长大**。这里固定按 extra = 0 算，
      #    往回的每一屏由 observeEvent(input$hist_more) 单独渲染、单独发。
      #    改前是 dsapp_hist_window(ch, hist_extra())，那个只增不减的计数
      #    就是"点几次就撑爆几次"的根源（见 config.R 的 DSAPP_HIST_MAX_PAGES）。
      idx <- if (is.null(only)) {
        # ★ V16.3 item 6：末尾由 hist_win 决定（NULL = 跟到最后一条，也就是
        #   一直以来的行为；目录跳转把它挪到被点的那一条上）。
        hw <- hist_win(msgs)
        win <- hw$win
        # ⚠️ 用 shown 判空，不用 seq.int(start, n)：nrow 为 0 时上面已经返回了，
        #    但 seq.int(1, 0) 这种写法在 R 里回的是 c(1, 0)（不是空），
        #    真让它落到那儿就是渲染一条不存在的消息。
        if (win$shown > 0L) seq.int(win$start, hw$end) else integer(0)
      } else {
        as.integer(only)
      }

      c(
        lapply(idx, function(i) {
        # 这一条是不是执行结果、对应哪一行任务
        tid <- if (identical(msgs$role[i], "tool"))
                 dsapp_tool_task_id(msgs$content[i]) else NULL
        trow <- if (!is.null(tid) && !is.null(tmeta))
                  tmeta[tmeta$id == tid, , drop = FALSE] else NULL
        if (!is.null(trow) && nrow(trow) == 0) trow <- NULL
        run_files <- if (!is.null(tid) && !is.null(fmap))
                       fmap$name[fmap$task_id == tid] else character(0)

        dsapp_msg_bubble(msgs$role[i], msgs$content[i], msgs$id[i],
                         # 目录（V9 item 9）跳转的锚点。只给用户消息挂 ——
                         # 见 dsapp_msg_bubble 里的说明。
                         dom_id = if (identical(msgs$role[i], "user"))
                                    dsapp_msg_anchor(ns, msgs$id[i]) else NULL,
                         reasoning = msgs$reasoning[i],
                         # 只认本对话自己的产物当白名单。isolate：名单变了
                         # 上面那个 observer 会 bump hist_ver，不需要这里再
                         # 挂一个每 3 秒抖一次的依赖。
                         file_names = isolate(art_names()),
                         # 正文里提到的文件名，点了先看预览（V7 item 2）。
                         file_input = ns("art_preview_want"),
                         file_title = "点击预览 %s",
                         # 正在跑的那一段，卡片上的状态原地变转圈（V8 item 6，
                         # V11 item 10 之后按钮不在这儿了，转圈还在）。这里读
                         # 它就等于挂上了依赖：任务起止时 run_cid 一变，历史
                         # 自己重渲染，状态自己回来。
                         running_id = run_cid(),
                         # 已经提交过的段，状态标「已执行」而不是「待执行」。
                         ran_ids = ran_ids(),
                         # 执行结果气泡（V9 item 2/8）：任务行 + 这次产出的
                         # 文件 + 「让 AI 分析这个报错」把话填回输入框。
                         task = trow, run_files = run_files,
                         prefill_input = ns("prefill_input"),
                         # ★ V15.4 item 2 前半：失败卡片上那颗「重试这一步」。
                         #   和 prefill_input 是两条不同的通道 —— 那条只填字，
                         #   这条真去把那段代码再跑一遍（见 dsapp_retry_btn 的
                         #   头注，那里写了为什么不合并成一颗）。
                         retry_input = ns("task_retry"),
                         # V13.10 item 4：执行结果卡片要不要走"静默"版。
                         # ⚠️ st$agent$autofix 是**普通字段**（R6 对象里的
                         #    一个值），不是 reactiveVal —— 读它不会建立依赖，
                         #    所以勾选框一改，已经渲染出来的历史卡片不会跟着
                         #    重画。这是**故意的**：哪一次失败该说什么，取决
                         #    于那次失败发生时开关的状态，不取决于用户现在
                         #    勾成什么样（理由见 envfix.R 的
                         #    dsapp_env_user_note 参数注释）。
                         autofix = isTRUE(st$agent$autofix),
                         # ★ V15.3 item 4：动作按钮的"hist"挂载点。
                         # ⚠️ run_actions_ui() 自己会判"该不该长在这里"
                         #    （action_host() 不比配就返回 NULL），所以这里
                         #    只要把候选位置递进去，不用在这儿再判一次 ——
                         #    判两遍就是两份口径，迟早对不上。
                         actions = if (identical(i, last_asst))
                                     run_actions_ui("hist") else NULL,
                         # ★ V15.6 item 13：**正被 agent 内联卡要确认的那一条**，
                         #   不画代码卡上的「请确认后执行」黄条 —— 那两处说的是
                         #   同一件事，用户看到的就是"两个确认框"。
                         #   ⚠️ 判据用消息 id 对（口径见 pending_code() 里那段），
                         #      不是"最后一条"：历史里别的消息该有的黄条照样有。
                         alert = !(isTRUE(agent_wait()) &&
                                   identical(as.character(msgs$id[i]),
                                             as.character(st$agent$pending_mid %||% ""))),
                         # ★ V15.3 item 6：正文里的图片。sid 一起传 —— 它既
                         # 决定图从哪个工作区解析，也进 segtext 的缓存 key。
                         img_session = session, img_sid = sid, img_cfg = cfg())
      }))
    }

    output$history <- renderUI(hist_body())

    # ★★ V16.1 item 2：往回翻的那几屏，**每一屏一格**。
    #
    # ⚠️⚠️ 这里的 `hist_pages[[kk]]()` 是**唯一**的依赖 —— 千万别顺手把
    #    msgs/state$msg_rev 之类的东西读进来"顺便更新一下"。读了就变成
    #    "每次消息变化十格一起重画"，分屏白做（单包又会涨回几百 KB）。
    #    要更新某一屏的内容，写它的那个 reactiveVal，不是改这里的依赖。
    #
    # ⚠️ local() 不能省：循环变量 kk 要在闭包里按值钉住，否则十格全都读
    #    最后一格。
    for (k in seq_len(DSAPP_HIST_MAX_PAGES)) {
      local({
        kk <- k
        output[[sprintf("hist_page_%d", kk)]] <- renderUI(hist_pages[[kk]]())
      })
    }

    # ★★ V16.1 item 2：那颗「↑ 显示更早的消息」/ 翻到头时的说明。
    #
    # 单独一格（不再长在 output$history 里面）：那一位每写一条消息都要整包
    # 重画，链接跟着重建一次；而这里只在"翻了几屏"变化时才真的换内容。
    # ⚠️ 名字要和卡上那个 uiOutput(ns("hist_more_ui")) 逐字相同（理由见那里）。
    #    写成 output$hist_more 的话 Shiny 不报错，只是不填那个 div ——
    #    症状是「↑ 显示更早的消息」那一行**永远不出现**，而自检全绿。
    output$hist_more_ui <- renderUI({
      hist_ver()
      state$msg_rev
      hist_page_n()
      # ★ V16.3 item 6：锚点变了这一格也要重画 —— 它算的是"主窗口上面还有
      #   多少条"，锚点一挪这个数就变了。漏了这一行的话，跳转之后那条
      #   「↑ 显示更早的消息（前面还有 N 条）」里的 N 还是老窗口的数字。
      hist_end()
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)
      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      if (nrow(msgs) == 0) return(NULL)
      base <- hist_win(msgs)$win$start
      oldest <- hist_oldest() %||% base
      hidden <- oldest - 1L
      if (hidden <= 0L) return(NULL)
      if (hist_page_n() >= DSAPP_HIST_MAX_PAGES) {
        # ★ 翻到头了。**不要**再画一颗点了没反应的链接 —— 那正是这一版要修的
        #   那个症状（改前 uid=1 那个 27 条的对话实测第 5/6/7 次点击一条都不多）。
        #   这里如实说清楚：还剩多少、一次能取回多少、库里一条没少。
        return(div(class = "dsapp-hist-more dsapp-hist-cap",
          div(class = "dsapp-hist-cap-note",
            sprintf(paste0("↑ 已经往回翻了 %d 屏，前面还有 %d 条更早的消息。",
                           "一次只取回这么多 —— 这一段太长了，再往上翻会把",
                           "这一包撑过链路的承受上限、页面会自己重连。"),
                    hist_page_n(), hidden),
            tags$br(),
            tags$span(class = "text-muted small",
              "这些消息一条都没丢，还在这个对话里；要通读的话，",
              "可以新建一个对话让它帮你按上面的内容做个小结。"))))
      }
      div(class = "dsapp-hist-more",
        actionLink(ns("hist_more"),
                   sprintf("↑ 显示更早的消息（前面还有 %d 条）", hidden),
                   class = "dsapp-hist-more-link"))
    })

    # ★★ V16.3 item 6：目录点到一条**还没渲染出来**的消息。
    #
    #   用户原话：「消息过多被折叠时，按导航栏里的消息无法跳转」。
    #
    #   前端只在"DOM 里找不到那个锚点"时才发这个事件（找得到时它自己就地
    #   滚过去，一次服务端往返都不花）。这里只做一件事：把主窗口的**末尾**
    #   挪到被点的那一条上 —— 窗口是"从末尾往回数一屏"，所以目标必然落在
    #   里面（dsapp_hist_window 的规则①：最后一条永远收）。
    #
    #   ⚠️ 值里带了一个序号（形如 `123|1696...`），只取 `|` 前面那段。
    #      序号是给 Shiny 看的：**同一个值**重复发是不会再派发的，而
    #      "连着点同一条目录"是很自然的动作。priority:'event' 已经管了这
    #      件事，这个序号是第二道保险 —— 它不要钱，而"点了第二次没反应"
    #      极难查（没有报错、没有日志）。
    #   ⚠️ 拆分一律 `fixed = TRUE`（本仓那条：正则匹配源码/字符串会静默走样）。
    observeEvent(input$toc_jump, {
      raw <- as.character(input$toc_jump %||% "")
      if (!nzchar(raw)) return()
      mid <- strsplit(raw, "|", fixed = TRUE)[[1]][1]
      sid <- rv$session_id
      if (is.null(sid) || is.na(mid) || !nzchar(mid)) return()
      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      if (nrow(msgs) == 0) return()
      i <- match(mid, as.character(msgs$id))
      # 对不上（消息被删了、或者前端拿的是别的对话的 id）：什么都不做，
      # 不报错也不弹窗 —— 这是"翻到一半被删掉"的场景，用户已经在看别处了。
      if (is.na(i)) return()
      # ⚠️ 顺序：先清屏再挪锚点。反过来的话，那几屏会按**新**窗口的边界
      #    重画一次再被清掉，白花一帧的载荷。
      hist_clear()
      hist_end(i)
      # 前端收到之后轮询等那个锚点进 DOM（新的一屏是**同一拍**才发出去的），
      # 再滚过去闪一下。等不到就算了，不会一直转。
      session$sendCustomMessage("dsapp:jump_to",
                                list(id = dsapp_msg_anchor(ns, mid)))
    })

    # ★★ V16.3 item 6：锚在中间时，顶上那条常驻横条（附「回到最新」）。
    #
    #   ⚠️ 它**不是**装饰：跳转之后用户看到的是一段"上下文只有一屏"的内容，
    #      没有这条横条的话他没法知道"下面还有更新"，也没法一键回去 ——
    #      而这正是这一版把窗口挪过去（而不是把中间几屏全取回来）的代价。
    #      代价要写在脸上。
    #   ⚠️ 跟着末尾（hist_end 是 NULL）时它整个不出现，一个像素都不占。
    output$hist_focus <- renderUI({
      hist_ver()
      state$msg_rev
      hist_end()
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)
      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      n <- nrow(msgs)
      if (n == 0L) return(NULL)
      e <- hist_win(msgs)$end
      newer <- n - e
      if (newer <= 0L) return(NULL)
      div(class = "dsapp-hist-focus",
        icon("clock-rotate-left"),
        tags$span(sprintf("你正在看较早的内容 · 后面还有 %d 条更新的消息", newer)),
        actionLink(ns("hist_latest"), "回到最新",
                   class = "dsapp-hist-focus-btn")
      )
    })

    observeEvent(input$hist_latest, {
      hist_clear()
      hist_end(NULL)
    })

    # ---- 固定位置的「确认执行」（V11 item 10）-------------------------------
    #
    # 用户的原话：「确认执行的按钮不应该在代码框上，而是应该在对话界面的
    # 固定位置，没有方案待确认时是一个灰度颜色，有方案需要确认时点亮」。
    #
    # 「待确认的方案」指的是：**最后一条助手消息**里，满足
    #   可执行（R / Python / Bash）+ 已经闭合 + 没被安全扫描拦下 + 还没提交过
    # 的第一段代码。
    #
    # ⚠️ 只看最后一条助手消息，**不回头翻历史**。翻的话按钮会一直亮着
    #    （几条以前没跑过的代码永远够得着），而用户完全不知道它在指哪一段 ——
    #    一个"永远亮着但不知道干什么"的按钮，比灰着更糟。
    #
    # ⚠️ 找不到时返回 NULL，界面渲染成灰色的不可点按钮。这条"灰"是有信息量
    #    的：它同时表示"现在没有要你确认的东西"和"有东西要确认时我会亮"。
    # ★★ V15.6 item 13：agent 循环正**停在一段代码上等用户确认**吗。
    #
    #   用户原话：「执行结果 · 任务 #176 后面出现了两个确认框，思考过程里有个
    #   确认框，又额外出现了一个确认框，不要这种冗余」。
    #
    #   同一个待确认的代码块当时有三条渲染路在画"要你确认"：代码卡上的黄条、
    #   气泡尾部那颗「确认执行」、以及 agent 的内联卡（「这一段需要你确认」
    #   + 继续执行/跳过）。这一版收敛成**一处**：只留内联卡 —— 因为只有它
    #   真的会让循环往下走（气泡那颗点下去弹的是模态确认、走手动执行，
    #   agent 还停在原地等，点了跟没点一样）。
    #
    # ⚠️ st$agent 不是响应式的，agent_ver() 是它的脉冲 —— 少了这一句，
    #    循环状态变了这一格不会重算（本仓的老毛病，见文件顶部"响应式版本号"）。
    agent_wait <- reactive({
      agent_ver()
      a <- st$agent
      !is.null(a) && identical(a$state, "awaiting_user")
    })

    pending_code <- reactive({
      hist_ver()
      agent_ver()
      if (!is.null(run_cid())) return(NULL)      # 正在跑，不给第二段
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)

      msgs <- tryCatch(db_messages_get(sid, con = dsapp_db(cfg())),
                       error = function(e) NULL)
      if (is.null(msgs) || !nrow(msgs)) return(NULL)

      asst <- which(msgs$role == "assistant")
      if (!length(asst)) return(NULL)
      i <- asst[length(asst)]

      # ★★ V15.6 item 13：这一段正被 agent 的内联卡要着确认 —— 这里让位。
      #   （判据用消息 id 对，不用"最后一条助手消息"：口径必须和 agent.R
      #   认领时记下的 pending_mid 一致，否则会出现"卡在等 A 段、
      #    亮的却是 B 段"。）
      if (isTRUE(agent_wait()) &&
          identical(as.character(msgs$id[i]),
                    as.character(st$agent$pending_mid %||% ""))) return(NULL)

      blocks <- dsapp_parse_code_blocks(msgs$content[i])
      if (!length(blocks)) return(NULL)

      # ⚠️ 块序号必须和渲染时用的**同一个**：code_id 是
      #    "<消息号>:<块序号>"，服务端拿到坐标后回库重取、重新解析
      #    （见 jobs.R 的 dsapp_extract_block）。两边数块的方式一旦不一致，
      #    用户点"执行第 2 段"跑起来的是第 3 段 —— 而且两边都不报错。
      #    dsapp_parse_code_blocks 和 dsapp_split_segments 都只给
      #    "body 非空"的围栏编号，所以顺序是对得上的。
      ran <- ran_ids()
      for (k in seq_along(blocks)) {
        b <- blocks[[k]]
        if (!b$lang %in% c("R", "Python", "Bash")) next
        cid <- paste0(msgs$id[i], ":", k)
        if (cid %in% ran) next
        if (nrow(dsapp_scan_cached(b$code)$blocked) > 0) next
        return(list(cid = cid, lang = b$lang, n = k))
      }
      NULL
    })

    # 「现在到底有没有东西可以停」。
    #
    # ⚠️ 两种情况都算：模型正在**生成**（rv$streaming），和**任务/循环**在跑
    #    （engine$state$running 或 agent 活着）。只认后者的话，模型吐字吐到
    #    一半时那颗「停止」是灰的 —— 而那正是用户最常想按它的时候
    #    （等了 40 秒没出结果）。这条以前没写出来是因为停止按钮一直是亮的，
    #    "什么时候该亮"这个问题从来没被问过。
    #
    # ⚠️ 这里**必须**把 engine$state$running 和 rv$streaming 都读成依赖，
    #    否则它一次都不会重算。它们本来是普通值/响应式的混用，读的那一下
    #    就是注册依赖的那一下。
    stoppable <- reactive({
      # ⚠️ agent_ver() 只是**脉冲**，不是判断依据 —— st$agent 不是响应式的，
      #    没有这一句的话，循环自己开始/结束（比如它提交了一个任务、
      #    rv$streaming 已经落了）时这颗按钮不会重算。见 mod_chat.R 顶部
      #    "响应式版本号"那一段的说明。
      agent_ver()
      isTRUE(rv$streaming) ||
        isTRUE(engine$state$running) ||
        (!is.null(st$agent) && isTRUE(st$agent$active())) ||
        # ★ V15.3 item 4：脱离页面的后台续跑也算。见 dsapp_arun_stop() ——
        #   停它是**写一行库**，子进程下一轮开头读一次。
        #   ⚠️ 少了这一条，横幅里那颗停止按钮会**永远是灰的**：后台续跑时
        #      页面上既没在生成、也没有本会话的任务在跑（子进程在另一个
        #      引擎里），上面三条全是 FALSE。用户看着一条"正在后台跑"的
        #      横幅，而唯一的停止按钮点不动。
        identical(arun_tick(), "running")
    })

    # ---- 「它刚才是在问我吗」（V13.11 item 10）-----------------------------
    #
    # 用户原话：
    #   「我现在的会话以疑问句结尾："我可以直接基于它跑建模，跳过数据准备。
    #     要不要继续？"但是并没有让我确认是否继续执行，确认按钮也是灰度的」
    #
    # pending_code() 的判据是"最后一条回复里有没有没跑过的**可执行代码**"。
    # 那条判据对"写代码 → 点一下跑"是对的，但它漏了另一半：agent 停下来问
    # 一句"要不要继续"，同样是**在等你确认** —— 而那种回复里没有代码块，
    # 于是按钮一直灰着，用户没有任何地方可以点。他唯一的办法是自己打字
    # 回一句"继续"，而界面上没有任何提示告诉他可以这么做。
    #
    # 判据本身在 prompts.R 的 dsapp_asks_confirmation() 里（纯函数，自测里
    # 直接喂字符串验），这里只负责决定"要不要亮"。
    #
    # ⚠️ 和 pending_code() 一样**只看最后一条助手消息**，不回头翻历史：
    #    翻的话，几轮之前那个被答过的问题会一直够得着，而用户完全不知道
    #    按钮在指哪一句 —— 一个"永远亮着但不知道干什么"的按钮比灰着更糟。
    #
    # ⚠️ 只看最后一条**并不足以**让它在该熄灭时熄灭：用户点「继续」之后，
    #    "最后一条助手消息"还是那一句问话（新的那条是用户消息）。真正让它
    #    熄灭的是上面那两个 return —— dsapp_chat_send() 会立刻把
    #    rv$streaming 置上，按钮当场变灰。少了那个判断的话，用户点完
    #    「继续」按钮还亮着，他会以为没点上，然后再点一次。
    pending_ask <- reactive({
      hist_ver()
      agent_ver()
      if (!is.null(run_cid())) return(NULL)     # 正在跑，和代码那颗同一条规矩
      # ⚠️ 生成中不给点。模型正吐字吐到一半，那条消息的结尾随时会变 ——
      #    这时候亮一颗「继续」，用户点下去就是往一个正在生成的轮次里插话。
      if (isTRUE(rv$streaming) || isTRUE(rv$sending)) return(NULL)
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)

      msgs <- tryCatch(db_messages_get(sid, con = dsapp_db(cfg())),
                       error = function(e) NULL)
      if (is.null(msgs) || !nrow(msgs)) return(NULL)
      asst <- which(msgs$role == "assistant")
      if (!length(asst)) return(NULL)
      i <- asst[length(asst)]
      if (!isTRUE(dsapp_asks_confirmation(msgs$content[i]))) return(NULL)
      list(row = msgs$id[i])
    })

    # =======================================================================
    # ★★ Test_V15.3 item 4：三颗动作按钮的**唯一一份**渲染
    # =======================================================================
    #
    # 用户原话：「停止按钮重复了，可以把确认执行、补点建议、停止按钮都挪到
    # 正在执行的会话里去」。
    #
    # 改之前的样子：一条钉在输出框下沿的 .dsapp-output-bar 装着三颗（V12
    # item 2），实时卡片里又有一颗「停止任务」（render.R 的 dsapp_live_card），
    # 后台横幅里还有一颗「停止后台运行」（dsapp_detach_banner）。三颗红色
    # 停止按钮同时挂在屏幕上 —— 用户说"重复了"，说的就是这个。
    #
    # 现在的规矩是**一处渲染、一处出现**：
    #   · 只有一个 run_actions_ui()（下面），三颗按钮的 HTML 只写一遍；
    #   · 挂在哪一处由 action_host() 说了算，任何时刻只返回一个宿主；
    #   · 四个挂载点各自只在 `identical(action_host(), "<自己>")` 时渲染。
    #
    # ⚠️ 不要为了"某个宿主里少一颗"而复制一份 run_actions_ui —— 那样停止
    #    按钮就又能同时出现在两处了，正是这一版要拆掉的东西。
    #    哪个宿主显示哪几颗写在 run_actions_ui 里面，是一处真相。

    # 本会话有没有"正在跑、而且归这个对话"的任务。
    #
    # ⚠️ 判据必须和 output$live_run **完全一致**：两处不一致的话，
    #    action_host() 会说"按钮该长在实时卡片上"，而那张卡片压根没渲染 ——
    #    症状是"三颗按钮凭空消失"，而且只在**别的对话**正在跑任务时出现
    #    （引擎是全局单槽的，见 app.R 顶部的说明）。
    #    所以这个值由 live_run_data 那个 observer 顺手算出来，不另起一个轮询。
    live_here <- reactiveVal(FALSE)

    action_host <- reactive({
      # ⚠️ 这几个都是**粗粒度**信号：值只在真的变了的时候才变。
      #    读它们是便宜的，不会让历史消息流每 2 秒重画一次
      #    （live_run_data 每 2 秒更新一次内容，但它**不在这里读**，
      #     只通过 live_here 这个布尔量透出来 —— 见上面）。
      rv$streaming
      rv$sending
      agent_ver()
      arun_tick()

      # ① 正在生成回复：动作跟在**正在吐字的那条气泡**后面
      if (isTRUE(rv$streaming) || isTRUE(rv$sending)) return("stream")
      # ② 有个任务在本对话跑：动作跟在**实时卡片**里
      #    （和「到『历史任务』页看完整日志」并排，那一块本来就是"这一轮怎么
      #     样了"的地方）
      if (isTRUE(live_here())) return("live")
      # ③ 它在等用户确认代码 / 等一句「继续」：动作跟在**最后一条助手气泡**
      #    尾部 —— 那正是用户在读、在决定的那段内容。
      # ★ V15.6 item 13：agent 停在"这一段需要你确认"上时也算 —— 那种情况下
      #   确认入口在内联卡里（所以 pending_code() 让位了），但**停止**还得出得来。
      #   少了这一条，"等确认"期间整条动作栏会凭空消失，用户连停都停不了。
      if (!is.null(pending_code()) || !is.null(pending_ask()) ||
          isTRUE(agent_wait())) return("hist")
      # ④ 有个进程脱离页面在后台替这个对话干活：动作跟在**后台横幅**里。
      #    放最后：横幅自己不依赖 action_host()，它是"更大事"的那一条，
      #    上面三种情况同时成立时，横幅照旧显示，只是没有停止按钮。
      if (identical(arun_tick(), "running")) return("detach")
      NULL
    })

    #' 三颗动作按钮的渲染（唯一一份）
    #'
    #' @param host 调用方**自己是谁**。只有 action_host() 指到它时才渲染 ——
    #'   这一句判断就是"任何时刻只有一处可见"的全部实现。
    #'
    #' 每个宿主显示哪几颗，按"在这里能不能按"来定，不是三颗全都摆一遍：
    #'   · 确认执行 —— 只在 hist（那正是有代码/有问题在等你的地方）
    #'   · 补点建议 —— 只在有东西正在跑的那几处（stream / live / detach）
    #'   · 停止     —— 每一处都给。它是唯一的停止入口（见 input$stop）
    #'
    #' ⚠️ 「没得按时灰着、不隐藏」这条 V12 的老规矩仍然保留：在**同一处**
    #'    内部，按钮的亮灭不改变它占的位置，所以那一行不会左右跳。
    run_actions_ui <- function(host) {
      if (!identical(action_host(), host)) return(NULL)

      confirm_btn <- function() {
        p <- pending_code()
        if (!is.null(p)) {
          return(tags$button(
            class = "dsapp-btn dsapp-btn-run dsapp-code-run",
            type = "button",
            `data-code-id` = p$cid,
            title = sprintf("执行刚写出的那段 %s 代码（第 %d 段）", p$lang, p$n),
            "确认执行"))
        }
        # ★ V13.11 item 10：没有代码可跑，但它在问你话 —— 这时候亮一颗能点的
        #   「继续」。**文案必须换**：还写「确认执行」的话，用户以为点下去是
        #   跑一段他根本找不到的代码。
        a <- pending_ask()
        if (!is.null(a)) {
          return(actionButton(
            ns("confirm_go"), "继续",
            class = "dsapp-btn dsapp-btn-run dsapp-ask-go",
            icon = icon("arrow-right"),
            title = "它刚才问了你一句，点这里回一句「继续」"))
        }
        # ★ V15.6 item 13：agent 正停在内联卡上等确认 —— 确认入口在**那张卡**
        #   里（继续执行 / 跳过）。这里灰着并把话说明白，不再亮第二颗：
        #   那颗点下去走的是"模态确认 + 手动执行"，而循环还停在原地等，
        #   用户点完会以为卡住了（正是他报的"两个确认框"里多余的那一个）。
        if (isTRUE(agent_wait())) {
          return(tags$button(
            class = "dsapp-btn dsapp-btn-run dsapp-btn-run-off",
            type = "button", disabled = "disabled",
            title = "上面那张「这一段需要你确认」的卡片在等你选「继续执行」或「跳过」",
            "确认执行"))
        }
        tags$button(
          class = "dsapp-btn dsapp-btn-run dsapp-btn-run-off",
          type = "button", disabled = "disabled",
          title = "模型写出可执行的代码、或者问你「要不要继续」之后，这里会亮起来",
          "确认执行")
      }

      suggest_btn <- function() {
        if (!suggestable()) {
          return(tags$button(
            class = "dsapp-btn dsapp-btn-run dsapp-btn-run-off",
            type = "button", disabled = "disabled",
            title = "有任务正在跑的时候，这里可以给它补一句说明",
            "补点建议"))
        }
        actionButton(ns("supplement"), "补点建议",
                     class = "dsapp-btn dsapp-btn-suggest",
                     icon = icon("lightbulb"))
      }

      stop_btn <- function() {
        if (!stoppable()) {
          return(tags$button(
            class = "dsapp-btn dsapp-btn-run dsapp-btn-run-off",
            type = "button", disabled = "disabled",
            title = "模型正在生成、或任务正在跑的时候，这里可以停下来",
            "停止"))
        }
        # ⚠️ class 和上面那颗灰的**同一套**（.dsapp-btn），不是 Bootstrap 的
        #    btn-sm —— 两颗按钮并排，一颗 .8rem 一颗 .875rem 的话基线对不齐，
        #    点亮/熄灭切换时整条会轻轻抖一下。
        actionButton(ns("stop"), "停止",
                     class = "dsapp-btn dsapp-btn-stop",
                     icon = icon("stop"))
      }

      tagList(
        div(class = "dsapp-actions",
          if (identical(host, "hist")) confirm_btn(),
          if (!identical(host, "hist")) suggest_btn(),
          stop_btn()
        )
      )
    }

    # 点「继续」= 替用户发一句话。走的是**和用户自己打字完全一样**的那条路
    # （dsapp_chat_send(extra=)）—— 和 lit_go、生成报告是同一条。共用一条路
    # 意味着闸门（正在生成中 / 只读共享 / 没配 Key / 没选模型）一个都不会绕过，
    # 也意味着它天然出现在对话里、进历史、算上下文。
    #
    # ⚠️ 不写成 dsapp_llm_begin()：那是**绕过闸门直接开一轮生成**，只读共享
    #    进来的对话会因此被写进一条 user 消息（往 owner 的对话里插内容）。
    observeEvent(input$confirm_go, {
      dsapp_chat_send(extra = "继续")
    })

    # ★★ V15.6 item 12：它在问你话 → 把输入框上面那个回答框亮出来。
    #
    #   用户原话：「返回问题的时候只有继续和停止按钮，应该有键入让用户回答，
    #   类似于 claude 的 chat about this」。
    #
    # ⚠️ 回答框本身是**静态节点**（见模块 UI 里 .dsapp-ask-box 那段注释），
    #    这里只发一条消息切显隐 —— 用 renderUI 画它的话，历史那一格重画
    #    一次就冲掉用户正在打的字。
    # ⚠️ 依赖就是 pending_ask()（它内部已经读了 hist_ver/agent_ver），不要再
    #    加别的响应式值：这一格盯着整条消息流，多一个依赖就多一次白跑。
    # ⚠️ 提示语**不重复**它问的那句话 —— 那句话就在上面那条气泡里，用户正
    #    看着；抄进来只会让这个框变成一小段会变的正文。
    observe({
      session$sendCustomMessage("dsapp:askbox", list(
        on = !is.null(pending_ask()),
        # ★ V16.1 item 1：用户原话「提示词改为：补充点意见：」。原来那句
        #   「它刚才问了你一句 —— 在下面回它，或者点「继续」」里"它刚才问了
        #   你一句"是废话（那句问题就在上面那条气泡里、用户正看着），
        #   "或者点继续"也不该由这行小字来交代 —— 「继续」那颗按钮自己带着
        #   同样的 tooltip（见 confirm_btn）。这里只留下要用户做的事。
        hint = "补充点意见："))
    })

    # 回答框的两条出口（「发送」按钮 / 回车）**共用一条路**，也就是和用户
    # 自己在大输入框里打字完全一样的那条 dsapp_chat_send(extra=)：
    # 闸门（正在生成中 / 只读共享 / 没配 Key / 没选模型）一个都不会绕过，
    # 那句话也天然进历史、算上下文。
    dsapp_ask_reply <- function() {
      txt <- trimws(input$ask_reply %||% "")
      if (!nzchar(txt)) {
        return(showNotification("先写一句要回它的话", type = "warning",
                                duration = 4))
      }
      ok <- dsapp_chat_send(extra = txt)
      # ⚠️ **发出去了才清空**（clear = TRUE 由前端执行）。被闸门挡下来时
      #    （比如这是别人共享给你的只读会话）把用户刚写的那句话擦掉，
      #    等于让他重打一遍，而他还不知道为什么没发出去。
      if (isTRUE(ok)) {
        session$sendCustomMessage("dsapp:askbox",
                                  list(on = FALSE, clear = TRUE))
      }
    }
    observeEvent(input$ask_send, dsapp_ask_reply())
    # 回车那条路：input 名写在 textarea 的 data-dsapp-enter 属性上，由
    # www/app.js 的通用出口发过来（前端不硬编码命名空间）。
    observeEvent(input$ask_reply_key, dsapp_ask_reply())

    # ---- 「补点建议」（V13.8 item 6；★ V13.9 item 9 换了语义）---------------
    #
    # 位置是 V13.8 定死的、别动：夹在「确认执行」和「停止」之间
    # （用户原话：「确认执行和停止之间，加一个"补点建议"」）。
    #
    # ★★ V13.9 item 9 用户原话：
    #    「补点建议是给正在运行的任务补充的建议，而不是直接发送系统内置关键词」
    #
    #    V13.8 那一版是**点一下就把一句写死的话发出去**：
    #
    #        suggest_prompt <- paste0("先不要写新的分析代码。请基于这个对话…")
    #        observeEvent(input$supplement, dsapp_chat_send(extra = suggest_prompt))
    #
    #    两处都不对：
    #      1. 发出去的是**我们**写的那句话，不是用户想补的那句。用户要的是
    #         "我补一句，它照着改"，不是"你替我提一段要求"；
    #      2. 它走 dsapp_chat_send()，也就是**另起一轮生成**。而任务正在跑的
    #         时候这么干，等于往同一个会话里塞第二次并发生成 —— 撞上
    #         dsapp_chat_send() 开头那道闸门，用户只会看到一句"正在生成中"。
    #
    #    现在：点开一个框让用户自己写，写完**只往库里追加一条 user 消息**。
    #    那个写死的 suggest_prompt 已经删掉了（它不再被发送；留着只会让人
    #    以为它还在起作用）—— 判据也一并从"有回复可聊"换成了"有东西在跑"。
    #
    # ★ 为什么"只追加"就够了 —— 正在跑的那个循环会自己读到：
    #   agent 循环每推进一轮都重新调 dsapp_scene_messages()（R/llm.R:628），
    #   而它每次都是**现查库**（db_messages_get），不是拿会话里的缓存。所以
    #   追加进去的消息，在循环的下一轮上下文里就已经在了。
    #   ⚠️ 反过来千万别在这里补一句 dsapp_llm_begin()：那是**第二次生成**
    #      打在同一个会话上，会和循环自己那一轮抢 —— 这正是 V13.8 那版的病。
    #
    # ⚠️ 追加一条消息**不会**打断循环，也不会让它重置轮次：a$on_llm_done 里
    #    那段"重置 iter / armed"只在 a$state == "idle" 时走（R/agent.R:668），
    #    而循环跑着的时候 state 不是 idle。

    #' 这一颗现在能不能点
    #'
    #' ★ V13.9 item 9 起判据是 **stoppable()** —— 「有没有正在跑的任务」。
    #' 它和「停止」那颗问的是同一个问题，所以复用同一个 reactive：两颗粒子
    #' 永远同亮同灭，不会出现"能停但不能补"这种自相矛盾的中间态。
    #'
    #' ⚠️ 这等于把 agent_ver()（循环心跳，每秒一跳）读成了依赖，比 V13.8 那版
    #'    贵一点 —— 但那正是必要的代价。V13.8 版**故意不读**它，于是
    #'    "循环在跑、只是此刻不在流式输出"的那一拍按钮是亮的，点下去反而发起
    #'    了一次并发生成。判错方向的省钱，不如不省。
    suggestable <- reactive({
      hist_ver()
      rv$sending
      rv$streaming
      if (!can_write()) return(FALSE)
      if (is.null(rv$session_id)) return(FALSE)
      stoppable()
    })

    # ★ V15.3 item 4：这颗按钮的**渲染**已经搬进上面的 run_actions_ui()
    #   （唯一一份）。这里只剩它点下去干什么 —— 那部分和按钮长在哪无关。
    #   灰着/亮着现在由 run_actions_ui 里的 suggest_btn() 决定，判据仍是
    #   suggestable()，没变。
    observeEvent(input$supplement, {
      # ⚠️ 这里必须**再判一次** suggestable()：按钮的亮灭只是上一拍的界面，
      #    而这一排的点击没有前端防重入（不像 .dsapp-code-run 那颗在浏览器里
      #    就 btn.disabled = true 了）。
      if (!suggestable()) {
        return(showNotification("现在没有正在跑的任务可以补充。",
                                type = "message", duration = 6))
      }
      showModal(modalDialog(
        title = tagList(icon("lightbulb"), " 给正在跑的任务补一句"),
        # ⚠️ 空框，不给默认文案：给默认文案就等于把 V13.8 那个"系统内置
        #    关键词"又请回来了 —— 用户多半会直接点确定，绕一圈回到老行为。
        textAreaInput(ns("suggest_text"), NULL, rows = 4, width = "100%",
                      placeholder = paste0(
                        "例如：先别做富集分析，把质控那几张图重画一版。\n",
                        "或者：这个报错我确认过了，换用 cellranger 的结果接着跑。")),
        div(class = "small text-muted",
            "这句话会作为你的消息补进这个对话。正在跑的那一轮",
            tags$b("下一轮就能看到"),
            "，不用等它结束，也不会打断它。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("suggest_do"), "补充进去",
                       class = "btn-primary", icon = icon("paper-plane"))
        ),
        easyClose = TRUE, size = "m"
      ))
    })

    observeEvent(input$suggest_do, {
      txt <- trimws(input$suggest_text %||% "")
      if (!nzchar(txt)) {
        return(showNotification("先写一句要补充的话。",
                                type = "warning", duration = 5))
      }
      sid <- rv$session_id
      if (is.null(sid) || !can_write()) {
        return(showNotification("这个对话现在写不进去。",
                                type = "warning", duration = 6))
      }
      r <- tryCatch({
        db_message_add(sid, "user", txt, con = dsapp_db(cfg()))
        TRUE
      }, error = function(e) e)
      removeModal()
      if (isTRUE(r)) {
        # hist_ver 一变，消息流和会话列表都会重画 —— 用户能立刻看见自己刚补的
        # 那句出现在对话里，这是"补进去了"唯一看得见的证据。
        hist_ver(hist_ver() + 1)
        showNotification("已补充，正在跑的这一轮下一步就会读到。",
                         type = "message", duration = 6)
      } else {
        # ⚠️ 不能把 conditionMessage(r) 直接摆上来（selftest 里有一条
        #    ★★★ 钉着这件事：原文多半是 "database is locked" 这种英文，
        #    对这个用户没有信息量，只会让他以为是自己操作错了）。
        #    走 dsapp_err_user()：界面上是人话，原文进审计日志。
        showNotification(dsapp_err_user(r, "把你补的这句话写进对话"),
                         type = "error", duration = 8)
      }
    })

    # ---- 需要用户确认的代码（awaiting_user）----
    #
    # 内联卡片，不用 showModal —— 理由见下面 input$agent_confirm 的注释。
    output$agent_confirm_card <- renderUI({
      agent_ver()
      a <- st$agent
      if (is.null(a) || !identical(a$state, "awaiting_user")) return(NULL)

      blk <- a$pending
      div(class = "dsapp-confirm-card",
        div(class = "dsapp-confirm-head",
          icon("triangle-exclamation"), " 这一段需要你确认"),
        div(class = "small text-muted mb-2",
          "它要把数据发往外部地址（`curl -d` / `--upload-file` 之类）。",
          "自动执行在这一步停下来等你 —— 上传出去的东西收不回来。"),
        tags$pre(class = "dsapp-tool-body", blk$code %||% ""),
        div(class = "d-flex gap-2 mt-2",
          actionButton(ns("agent_confirm"), "继续执行",
                       class = "btn-sm btn-warning", icon = icon("play")),
          actionButton(ns("agent_deny"), "跳过，让模型换个做法",
                       class = "btn-sm btn-outline-secondary", icon = icon("forward"))
        )
      )
    })

    # =========================================================================
    # 本对话产物（V5 item 3）
    # =========================================================================
    # 用户的原话是「文件管理可以在对话框中显示，这样用户对话的时候就能看到
    # 生成的文件」。以前产物只出现在「文件」页，而人是在对话页干活的 ——
    # 跑完一轮要切页签才知道出了什么，切回来又忘了它叫什么。
    #
    # ★ V13.11 item 1 之后这个 poll 只剩**一个**用处了：给正文里那些自动
    #   变成链接的文件名当名单（art_names → dsapp_linkify_files）。正文里的
    #   名字是**工作区**相对路径（模型写出来时说的就是这个名字），所以这里
    #   仍然读工作区 —— 别顺手把它一起换成文件区，换了之后正文里的链接会
    #   全部指空。右边那张「本对话的文件」卡片走的是另一条路（art_files）。
    #
    #   （原来还有个 art_ver 计数器：用户点「发布」时 +1 用来强制刷新。
    #     发布按钮已经拆了，没人再写它，留着就是一个恒为 0 的假依赖。）
    #
    # ★★ V15.4 item 2：又有一个计数器了，但**这次真的有写入方** ——
    #    `art_refresh` 由右边那张卡片头上的刷新按钮 +1。⚠️ 别看到"计数器"
    #    三个字就把它当成上面那个被删掉的死依赖。
    #    ⚠️ 两个 poll 都要拼它（这里和下面的 art_files）。只拼一个的话，
    #    用户点刷新，一张卡动了、另一张没动 —— 而"没动"的那张看起来和
    #    "你点之前就是这样"完全一样，会被当成偶发。
    art_refresh <- reactiveVal(0L)

    artifacts <- reactivePoll(
      3000, session,
      checkFunc = function() {
        # ★ V15.4 item 2：两个计数器**拼进返回值**里，不是"读一下"。
        #   理由见 R/mod_files.R 里 ws_groups 的 checkFunc 上面那一大段
        #   （`reactivePoll` 内部是 `rv$cookie <- checkFunc()`，而
        #   reactiveValues 只有值真变才失效下游 —— 只读不拼等于没写）。
        #   · dsapp_art_rev()：任务收尾时由 R/taskrun.R 自增，覆盖
        #     "同步动作不改变摘要"（同样大小 / 保留 mtime 的覆盖写）。
        #   · art_refresh()：卡片头上那颗手动刷新按钮。
        # ⚠️ 在**函数第一行**就把它们读掉，然后每条 return 都拼上。
        #    不能只在末尾那个 paste 里拼：这个 checkFunc 有三条提前 return
        #    （没选对话 / 工作区还不存在 / 目录是空的），走那三条时既拼不上、
        #    也没建立对 art_refresh 的依赖 —— 表现是"这时候点刷新按钮完全
        #    没反应"，而那正是用户最会去点它的时候（任务刚跑起来、目录还空）。
        extra <- paste(dsapp_art_rev(), art_refresh())
        sid <- rv$session_id
        if (is.null(sid)) return(extra)
        d <- dsapp_ws_dir(sid, cfg(), create = FALSE)
        if (is.na(d) || !dir.exists(d)) return(extra)
        # ⚠️ 递归摘要。只看顶层的话，模型往 results/ 里覆盖写一张图
        #    （很常见：调一次参数重画一次）完全不改变顶层的文件数和
        #    mtime 之和 —— 界面上的缩略图就一直是上一版，而用户以为
        #    自己看到的是刚跑出来的结果。
        # dirs = TRUE：同 mod_files.R 那一处，模型建一个空文件夹时只有
        # 目录会让摘要变（V8 item 7）。
        fs <- dsapp_ws_snapshot(d, dirs = TRUE)
        if (!length(fs)) return(paste("0 0 0", extra))
        fi <- file.info(file.path(d, fs))
        # 摘要变了才重读盘。大小和 mtime 都算进去：同名文件被覆盖写
        # （很常见，模型经常原地改一个脚本再跑）时，只有 mtime 会变。
        paste(length(fs), sum(fi$size, na.rm = TRUE),
              sum(as.numeric(fi$mtime), na.rm = TRUE), extra)
      },
      valueFunc = function() {
        sid <- rv$session_id
        if (is.null(sid)) return(NULL)
        tryCatch(dsapp_ws_artifacts(sid, cfg()), error = function(e) NULL)
      }
    )

    # 拼内联 onclick 用的 JS 字面量。实现已挪到 utils.R 的 dsapp_js_str ——
    # V9 item 3 在 mod_files.R 里也要用，才发现原来这个函数只活在本模块的
    # 作用域里，别的模块一调就是 "could not find function"。
    js_str <- dsapp_js_str

    # ---- 产物名单（V5 item 5）-----------------------------------------------
    # 正文里提到的文件名要能点。判据用**名单**而不是 artifacts() 本身：
    # 那个 reactivePoll 每 3 秒算一次摘要，模型原地改一个脚本再跑一遍
    # （很常见）摘要就变了 —— 拿它直接驱动历史重渲染的话，对话流每跑一轮
    # 就被整个重建好几次，滚动位置、展开的代码卡片全丢。
    # 名单真的变了才重渲染一次；isolate 读它，不额外引入 3 秒的依赖。
    art_names <- reactiveVal(character())
    observeEvent(artifacts(), {
      nm <- sort(as.character(artifacts()$name %||% character()))
      if (!identical(nm, isolate(art_names()))) {
        art_names(nm)
        hist_ver(hist_ver() + 1)
      }
    }, ignoreNULL = TRUE)

    # ---- 产物缩略图 ---------------------------------------------------------
    # 一轮跑完最想先看的就是图（火山图、UMAP、热图）。要用户为了看一眼图去
    # 点下载、再从浏览器下载目录里翻出来，等于把人从对话里赶出去一趟。
    #
    # ⚠️ 这里**不能**学「文件」页那样用 addResourcePath 的静态路由换速度：
    #    /files 路由指向的是**共享区**（所有人可见，本来就不设防），而工作区
    #    是每个对话私有的。一个不经过 server 函数的静态路由意味着任何人猜到
    #    文件名就能取走别人的产物 —— 而 "volcano.png" 这种名字根本不用猜。
    #    所以走 renderImage：它开的是 /session/<token>/… 的会话级 URL，取不到
    #    别人的 session token。拿路径之前还要过一次 dsapp_ws_path() 校验。
    #
    # 槽位是**固定几个**，不是"有几个图画几个"：Shiny 的输出渲染函数必须在
    # UI 出现之前就注册好，名字得是静态的。多注册的几个返回 NULL 即可
    # （renderImage 显式处理了 NULL，什么都不画）。
    n_thumb_slots <- 4L
    for (i in seq_len(n_thumb_slots)) {
      local({
        k <- i
        output[[paste0("art_thumb", k)]] <- renderImage({
          sid <- rv$session_id
          if (is.null(sid)) return(NULL)
          # 和界面上那份是**同一个函数**挑出来的，第 k 个槽位对应第 k 张图。
          # 各写一遍筛选条件的话，一旦不一致，槽位和文件名就错位了
          # —— 界面上看不出错，只是图不对。
          #
          # ★ V13.11 item 1：这里原来读的是**工作区**那份 artifacts()，现在
          #   跟着卡片一起换成**文件区**当前这一层（art_files()）。两边必须
          #   一起换：混着读的话张数对不上，槽位和文件名当场错位。
          # ★ V15.4 item 2：换成 art_thumbs() —— 卡片和这里都要用**同一个**
          #   函数，理由同上，只是这次的筛选条件复杂了（要递归、要去重名），
          #   各写一遍必然走样。art_thumbs() 定义在 art_files 那个 poll 下面。
          # ★ V15.5 item 10(b)：坐标直接取 tdf$coord —— 它已经**按各自的根**
          #   拼好了（文件区那份带 files: 前缀并补齐了当前层，工作区那份不带
          #   前缀）。在这里再按 rel 现拼一次，就会把工作区那张图拼成文件区
          #   坐标（或者反过来）—— 两边都可能存在同名文件，于是"图裂了"这种
          #   明显的错都不会有，只是显示的是**另一个文件**。
          tdf <- art_thumbs()
          if (is.null(tdf) || nrow(tdf) < k) return(NULL)
          ref <- tdf$coord[[k]]
          p <- dsapp_art_path(ref, sid, cfg())
          if (is.null(p) || is.na(p) || !file.exists(p)) return(NULL)
          list(src = p, contentType = dsapp_image_mime(tdf$name[[k]]),
               alt = tdf$name[[k]])
        }, deleteFile = FALSE)
      })
    }

    # 下载：Shiny 的 downloadHandler 必须挂在**已存在**的输出上，而"点了哪一
    # 行"是运行时才知道的，所以这里分两步 —— 点行 → 服务端渲染出 downloadLink
    # → 前端补一次点击（dsapp:clickWhenReady）。
    art_pick <- reactiveVal(NULL)

    output$art_dl_link <- renderUI({
      n <- art_pick()
      if (is.null(n)) return(NULL)
      div(class = "dsapp-hidden-dl",
          downloadLink(ns("art_dl"), tagList(icon("download"), " ", n)))
    })

    # 两个下载出口（列表里那个小图标 / 预览弹窗里的按钮）走的是同一段逻辑，
    # 抽成一个工厂而不是复制一遍：复制的那份迟早会在改 filename 规则时漏掉
    # （basename 那一行的理由见下）。
    # ★ V14 item 3：下载"给什么"要先算成一份**计划**，filename() 和
    #   content() 都读同一份。
    #
    #   ⚠️ 不能让两边各判一次：下载名是 filename() 单独算的，两边对不上
    #      就是"名字叫 分析报告.md、内容其实是个 zip"这种文件 —— 用户双击
    #      打不开，而且**看不出是谁的错**。所以这里抽成一个函数，
    #      两个回调都调它（算两遍的代价只是多读一次 md 文本）。
    dsapp_art_plan <- function() {
      n <- art_pick()
      # basename：产物名现在是相对工作区的路径（`results/volcano.png`），
      # 直接当下载名的话里面的 `/` 会被浏览器当成路径分隔符 ——
      # 在 Linux 上直接失效，在 Windows 上被改写成下划线。
      # ★ 先过 dsapp_art_label 剥掉 `files:` 前缀（理由见那个函数的说明）。
      lab <- basename(dsapp_art_label(n %||% ""))
      if (!nzchar(lab)) lab <- "download"
      # 文件名绕过一圈浏览器又回来了，必须重新校验（理由见 files.R 顶部）。
      # ★ V13.11 item 1：改用 dsapp_art_path —— 它认两种坐标（工作区 /
      #   文件区），见那个函数上面那段说明。
      p <- tryCatch(dsapp_art_path(n, rv$session_id, cfg()),
                    error = function(e) NULL)
      if (is.null(p)) return(list(kind = "file", path = NULL, name = lab))
      rr <- tryCatch(dsapp_art_root_rel(n, rv$session_id, cfg()),
                     error = function(e) list(root = NULL, rel = NULL))
      dsapp_dl_plan(p, rr$root, rel = rr$rel, name = lab)
    }

    dsapp_art_dl <- function() downloadHandler(
      filename = function() dsapp_art_plan()$name %||% "download",
      content = function(file) {
        d <- dsapp_art_plan()
        if (is.null(d$path)) return(invisible())
        # ★ V14 item 3：三条支路（原样 / 内联 / 打包）共用一份实现。
        dsapp_dl_write(file, d)
      }
    )
    output$art_dl  <- dsapp_art_dl()
    output$art_dl2 <- dsapp_art_dl()   # 预览弹窗里那个

    # ★★ 这三个 output 的 `suspendWhenHidden` 必须关掉 —— 少一个都会有下载
    #    按钮"点了跳回首页"。完整推导见 mod_files.R 里 `output$download`
    #    上面那段，一句话版：Shiny 把**客户端还没报告过可见性的 output**
    #    一律当成隐藏并挂起（`ShinySession$shouldSuspend`），而被挂起的
    #    output 根本不会被算出来，`<a>` 的 href 永远是空串，一点就导航到当前
    #    地址 —— 用户拿到一个 HTML 而不是文件，界面上一声不响。
    #
    #    这三个各自的"看不见"还不一样，所以一个都不能漏：
    #      art_dl_link —— 本身可见，但它渲染出来的 div 是隐藏的；
    #      art_dl      —— 藏在上面那个 div 里，靠 clickWhenReady 补点击；
    #      art_dl2     —— 在预览弹窗里，弹窗是打开时才建 DOM 的，
    #                     会话起步时它压根不存在。
    #    下载 URL 是定值（downloadHandler 只注册一次），关掉挂起之后
    #    一次下发、长期有效。
    outputOptions(output, "art_dl_link", suspendWhenHidden = FALSE)
    outputOptions(output, "art_dl",      suspendWhenHidden = FALSE)
    outputOptions(output, "art_dl2",     suspendWhenHidden = FALSE)

    # =========================================================================
    # ★★ V16.10：整层一键打包下载
    # =========================================================================
    #
    # 用户原话：「言出法随的文件页面和真正的文件管理页面文件不同步，那意味着
    #           你写了两套文件展示系统，这是大大的浪费，请同步，并且支持在
    #           演出法随的文件展示中一键打包下载」。
    #
    # 以前这张卡只能一行一行下（每行右边那个下载图标），而卡片本身只列 8 行
    # —— 一个对话几十个产物时，"全部拿走"在对话页是做不到的，得跳到「文件」
    # 页。文件页那边**早就有**整组打包（`ws_act` 的 `zipdir`/`zip` 两支），
    # 这里补上同一件事，并且和它共用 `R/files.R` 那一份盘点/打包实现。
    #
    # 语义 = **当前这一层的全部行、递归**：目录行由 `dsapp_zip_plan()` 展开成
    # 子树（见 `dsapp_zip_expand()`），所以"在根上点一下 = 整个对话"、"进到
    # `results/` 点 = 那个子目录"。和文件页「选文件夹会连里面的内容一起打包」
    # 是同一条规矩。
    #
    # ⚠️ 这一层是**两个根混在一起**的（文件区那几行带 `files:` 前缀、还没同步
    #    过来的工作区行不带，见 `art_level_merge()`），所以走的是
    #    `dsapp_zip_plan_multi()` 而不是 `dsapp_zip_plan()` —— 后者只认一个
    #    `root`，喂两组坐标进去只会静默丢掉一组。
    #
    # ⚠️ 用到的 `conv_dir()` / `art_here()` / `art_rel_in()` / `art_level_df()`
    #    都定义在**下面**（它们要读 sess_ver / art_files 那几个 reactive）。
    #    R 的闭包按**求值时刻**找变量，这几个 renderUI/observeEvent 都是会话
    #    起来之后才跑的，那时整个 server 函数体已经跑完了 —— 顺序上没问题，
    #    别为了"看着顺眼"把它们搬上来（搬上来就读不到 reactive 了）。
    art_zip_pick <- reactiveVal(NULL)   # 同步那条：盘点好的 plan
    art_zip_job  <- reactiveVal(NULL)   # 后台那条：list(h, t0, n, bytes, name)

    # ★ V16.10：打包失败时**屏幕上只说人话**。
    #
    #   起子进程失败的 `conditionMessage(h)` 和子进程半路失败的 `v$msg` 都是
    #   **英文原文**（带服务器上的绝对路径、函数名），用户看不懂也没有能做的
    #   动作。原文进审计，屏幕上只留一句人话 + 一个短代号 —— 和文件页那条
    #   补齐（`R/mod_files.R` 的 `repair_fail_code()`）是同一条规矩。
    #
    #   ⚠️ 自检里那条 ★★★「R/ 里没有把 conditionMessage 原文直接送到界面」
    #      按行扫「同一行里既有 conditionMessage 又有落屏函数」，抓得住
    #      "当场拼进去"，抓不住**转手**的原文（`v$msg` 就是转手的，它在
    #      R/jobs.R 那边才被赋成 conditionMessage）。所以两个失败点一起改。
    art_zip_fail_code <- function(stage, raw) {
      code <- format(Sys.time(), "ZP%m%d%H%M%S")
      try(dsapp_audit("zip_failed", user = state$user, user_id = state$user_id,
                      target = stage, ok = FALSE,
                      detail = sprintf("[%s] %s", code,
                                       paste(as.character(raw %||% ""),
                                             collapse = " ")),
                      session = session, cfg = cfg()), silent = TRUE)
      code
    }

    # "这一层叫什么"。**只有这一处**：按钮上的字、下载的名字都从它来。
    # 两处各算一遍的话，在 `results/figures` 里就会出现"按钮说 results/、
    # 下下来的叫 figures-12项.zip"——而这两个都是合法字符串，界面上看着
    # 一点都不像 bug。
    #
    # 根目录 → 对话文件夹名；子目录 → **当前这一层**的名字（最后一段）。
    art_zip_base <- function() {
      ri <- art_rel_in()
      seg <- if (is.null(ri) || !nzchar(ri)) {
        cd <- conv_dir()
        if (is.null(cd) || !nzchar(cd)) "" else basename(cd)
      } else strsplit(ri, "/", fixed = TRUE)[[1]]
      if (!length(seg)) return("")
      b <- seg[[length(seg)]]
      if (is.null(b) || is.na(b) || !nzchar(b)) "" else b
    }

    # 下载名。⚠️ 过 `dsapp_safe_name()`：文件夹名里可以有 `/`、空格、中文
    # 标点，而带 `/` 的下载名会被浏览器当路径分隔符（Linux 上直接失效，
    # Windows 上被改写成下划线）。
    art_zip_name <- function(n_items) {
      b <- art_zip_base()
      if (!nzchar(b)) b <- "产物"
      sprintf("%s-%d项.zip", dsapp_safe_name(b), as.integer(n_items))
    }

    # 这颗按钮要能变 disabled，所以是 renderUI 而不是静态 tags。
    # ⚠️ 忙的时候**保留同一个 input id 的按钮**、只加 disabled 属性，不是换成
    #    一段文字 —— 否则按钮会跳一下，而且失败之后得记得换回来（照抄
    #    `R/mod_files.R` 里 `output$import_ws_ui` 那一手）。
    output$art_zip_ui <- renderUI({
      df <- art_level_df()
      if (is.null(df)) return(NULL)
      n <- nrow(df)
      if (n == 0L) return(NULL)
      job <- art_zip_job()
      busy <- !is.null(job)
      where <- art_zip_base()
      # ⚠️ 「项」不是「个文件」：N 是**这一层的行数**，而目录行会被展开成
      #    一整棵子树 —— 说成"个文件"的话，用户点完发现包里多了几百个，
      #    第一反应是"它把不该打的也打进去了"。
      lab <- if (busy) {
        # 进度：后台打包动辄几分钟，没有数字用户会以为它坏了
        # （超过 2G 才走这条路，见 DSAPP_ZIP_MAX / DSAPP_ZIP_BG_MAX）。
        #
        # ⚠️ 秒数得**自己**往前走：`art_zip_job()` 只在起包和收包时各变一次，
        #    光靠它当失效源的话这颗按钮会一直显示"已 0 秒"—— 那比不显示更像
        #    卡死。（打包那条 `observe` 里的 `invalidateLater(1000)` 只唤醒它
        #    自己，不会顺带唤醒这里。）忙完 art_zip_job 变 NULL，这个 renderUI
        #    被它唤醒、重跑一遍就不再定时了，不会留一个空转的定时器。
        invalidateLater(1000)
        el <- max(0, as.numeric(Sys.time()) - as.numeric(job$t0 %||% 0))
        sprintf(" 正在打包…（已 %d 秒 · %s）", as.integer(el),
                dsapp_fmt_bytes(job$bytes %||% 0))
      } else if (!nzchar(where)) {
        sprintf(" 打包下载这个对话的文件（%d 项）", n)
      } else sprintf(" 打包下载 %s/（%d 项）", where, n)
      tags$button(
        class = "btn btn-sm btn-outline-secondary py-0 px-2",
        type = "button",
        disabled = if (busy) NA else NULL,
        title = if (busy)
          "正在把这一层的文件打成一个包，跑完会自己开始下载"
        else
          paste0("把这一层列出的 ", n, " 项打成一个 zip 下载",
                 if (!nzchar(where)) "（文件夹会连里面的内容一起打进包里）"
                 else "（含子文件夹里的内容）"),
        onclick = if (busy) NULL else sprintf(
          "Shiny.setInputValue(%s, Math.random(), {priority:'event'});",
          dsapp_js_str(ns("art_zip"))),
        icon("file-zipper"), lab)
    })

    output$art_zip_link <- renderUI({
      d <- art_zip_pick()
      if (is.null(d)) return(NULL)
      div(class = "dsapp-hidden-dl",
          downloadLink(ns("art_dl_zip"), tagList(icon("download"), " ",
                                                 d$name %||% "download")))
    })

    output$art_dl_zip <- downloadHandler(
      # basename：`name` 已经是 dsapp_safe_name() 洗过的，这里再包一层是
      # 和 `output$art_dl` / `output$ws_dl` 同一个写法，不是多余的。
      filename = function() basename((art_zip_pick() %||% list())$name %||% "download"),
      content = function(file) {
        d <- art_zip_pick()
        if (is.null(d)) return(invisible())
        if (identical(d$kind, "zipbg")) {
          # 后台那条：包已经在盘上了，复制给浏览器之后**立刻删掉** ——
          # 它可能有好几个 G，留着就是拿数据盘换省事。
          # ⚠️ 这里**不写** `art_zip_job(NULL)`：`content()` 不在普通的
          #    reactive 上下文里，从这儿写 reactiveVal 会去 invalidate 一整条
          #    下游（按钮、链接）。解锁那一步在轮询那条路里做完了。
          ok <- dsapp_zip_bg_handoff(file, d$path)
          if (!ok) {
            # 走到这里说明"打包完了、复制之前"那个包没了（临时目录被清）。
            # 界面上没法再提示了 —— 下载已经开始，浏览器那边只会拿到一个
            # 空文件。日志里留一条（同 `R/mod_files.R` 的 `output$download`）。
            try(dsapp_audit("chat_zip_download", user = state$user,
                            user_id = state$user_id,
                            target = d$name %||% "", ok = FALSE,
                            detail = "打包好的文件不见了（临时目录被清理）",
                            session = session, cfg = cfg()), silent = TRUE)
          }
          return(invisible())
        }
        res <- dsapp_zip_write_multi(file, d$plan)
        if (!isTRUE(res$ok)) {
          try(dsapp_audit("chat_zip_download", user = state$user,
                          user_id = state$user_id,
                          target = d$name %||% "",
                          detail = as.character(res$msg %||% ""), ok = FALSE,
                          session = session, cfg = cfg()), silent = TRUE)
        }
      }
    )
    # ★★ 这两条和上面 `art_dl_link` / `art_dl` 是**同一个坑**，理由那段注释
    #    已经写全了，这里只记差别：
    #      art_zip_link —— 会话起步时 `art_zip_pick()` 是 NULL，renderUI 给的是
    #                      NULL 而不是一个隐藏的 div ⇒ 客户端**从没报告过**它
    #                      的可见性 ⇒ 一律按"隐藏"处理 ⇒ 挂起；
    #      art_dl_zip   —— 藏在上面那个 div 里，靠 clickWhenReady 补点击。
    #    ⚠️ 两条都要**各写各的一行**，而且必须在 `output$x <-` 的**后面**
    #       —— 写在前面 = server 起不来 = 整页空白（本仓有账）。
    outputOptions(output, "art_zip_link", suspendWhenHidden = FALSE)
    outputOptions(output, "art_dl_zip",  suspendWhenHidden = FALSE)

    observeEvent(input$art_zip, {
      req(input$art_zip)
      sid <- rv$session_id
      if (is.null(sid)) return()
      if (!is.null(art_zip_job())) {
        showNotification("正在打包，跑完就自动下载 —— 这期间别关这个页面",
                         type = "message", duration = 5)
        return()
      }
      df <- art_level_df()
      if (is.null(df) || !nrow(df)) return()
      cfg_now <- cfg()
      # ⚠️ 只盘**一次**，两个出口共用这一份。按 2G 的门槛盘两遍看着更"直接"，
      #    但那两遍之间文件可能变（任务正在产出），两个 plan 会不一样 ——
      #    于是"算下来能同步打"和"真打的时候超了"会互相矛盾，而这里的
      #    `plan$groups` 是要**原样**交给子进程的。
      plan <- tryCatch(dsapp_zip_plan_multi(as.character(df$coord), sid, cfg_now,
                                            max_bytes = DSAPP_ZIP_BG_MAX),
                       error = function(e) NULL)
      if (is.null(plan) || !isTRUE(plan$ok)) {
        # ★ 和文件页同一条规矩：`stale`（列表陈旧，文件真没了）由平台自己
        #   刷新列表，不弹一句「请刷新页面」给用户；其余（超限、全是只读
        #   输入）是"说清楚就行"的事，照原文弹。
        if (isTRUE(plan$stale)) {
          dsapp_notify_stale("这一层里的文件",
                             refresh = function() art_refresh(art_refresh() + 1L))
        } else {
          showNotification(plan$msg %||% "打不了包", type = "error", duration = 10)
        }
        return()
      }
      nm <- art_zip_name(nrow(df))
      if (as.numeric(plan$bytes) <= DSAPP_ZIP_MAX) {
        art_zip_pick(list(kind = "zip", plan = plan, name = nm))
        session$sendCustomMessage("dsapp:clickWhenReady",
                                  list(id = ns("art_dl_zip")))
        return()
      }
      # ---- 超过同步那道顶：转后台 ------------------------------------------
      # 包有几个 G 时同步打会把**所有访客**的页面卡住（一个应用一个 R 进程，
      # 见 DSAPP_ZIP_MAX 上面那段）。子进程只写一个临时 zip、**不写库**。
      dst <- file.path(cfg_now$run_dir,
                       sprintf("zipbuild-%s.zip", dsapp_id("z")))
      # 顺手清一次上一批的孤儿（用户在"正在打包…"的时候把页面关掉，就没人
      # 做 `content()` 里那个 unlink 了）。不挂定时器 —— 理由见
      # `dsapp_zip_bg_gc()`。
      try(dsapp_zip_bg_gc(cfg_now$run_dir), silent = TRUE)
      h <- tryCatch(dsapp_bg_start("dsapp_zip_build",
                                   args = list(groups = plan$groups, dst = dst),
                                   cfg = cfg_now, tag = "zipbuild"),
                    error = function(e) e)
      if (inherits(h, "error")) {
        # ⚠️ 原文走 art_zip_fail_code（审计），屏幕上只给人话 + 代号。
        code <- art_zip_fail_code("起子进程", conditionMessage(h))
        showNotification(
          sprintf(paste0("起不了打包进程（%s），稍后再试；",
                         "若一直如此，把这个代号发给管理员"), code),
          type = "error", duration = 12)
        return()
      }
      art_zip_job(list(h = h, t0 = as.numeric(Sys.time()), n = plan$n,
                       bytes = as.numeric(plan$bytes), name = nm, dst = dst))
    })

    # 轮询子进程。形状和 `R/mod_files.R` 里那条补齐全一样（读句柄 → 没完就
    # 继续定时 → 取完写 NULL）。
    #
    # ⚠️ 顶层这句 `art_zip_job()` **必须保持是普通读、不能套 isolate()** ——
    #    它就是这个 observer 唯一的启动条件（observeEvent 里写 art_zip_job(h)
    #    时靠这个依赖把它唤醒）。隔离掉的话它永远不会跑。
    # ⚠️ **每一个出口都要解锁**：成功 / 子进程报错 / 子进程意外退出（后者是
    #    `dsapp_bg_poll()` 里 `alive = FALSE` 那一支）—— 少一条就是按钮永远
    #    转着、用户只能刷新页面。
    # ⚠️ 写进去的是 NULL，所以下一轮第 2 行就 return，不会自失效失控。
    #    （自检里扫「observe() 裸读自己写的 reactiveVal」那条规则要豁免，
    #    标记写在下面这行 —— 豁免要显式写出来，理由见自检里 v134e_exempt。）
    observe({
      # dsapp-selftest: self-reactive-ok art_zip_job
      job <- art_zip_job()
      if (is.null(job)) return()
      invalidateLater(1000)
      r <- tryCatch(dsapp_bg_poll(job$h), error = function(e) NULL)
      if (!isTRUE(r$done)) return()
      art_zip_job(NULL)
      v <- r$value %||% list()
      if (!isTRUE(r$ok) || !isTRUE(v$ok)) {
        # ⚠️ `%||%` 判的是 NULL/长度/NA，**不是 nzchar** ——
        #    `"" %||% "子进程意外退出"` 回来的是 `""`，挑出来的就是一句空的。
        #    子进程意外退出时 `dsapp_bg_poll()` 给的正是
        #    `msg = "子进程意外退出"`，所以这里逐个挑第一个非空的。
        msg <- c(as.character(v$msg %||% ""), as.character(r$msg %||% ""))
        msg <- msg[nzchar(msg)]
        # ⚠️ 挑出来的那个是**子进程的英文原文**（R/jobs.R 那边就是
        #    `msg = conditionMessage(e)`）—— 走审计，屏幕上只留人话 + 代号。
        code <- art_zip_fail_code("子进程半路失败",
                                  if (length(msg)) msg[[1]] else "子进程没有返回结果")
        showNotification(
          sprintf(paste0("打包中途失败了（%s）—— 稍后再点一次；",
                         "若一直如此，把这个代号发给管理员"), code),
          type = "error", duration = 12)
        return()
      }
      # ⚠️ 包在哪是**主进程**记着的（`job$dst`），不是从子进程的返回值里取
      #    —— `dsapp_zip_build()` 只回 ok/n/bytes/msg，它**不该**知道主进程
      #    打算把包放到哪、也更不该把那串路径在 JSON 里转一圈。
      dst <- job$dst %||% ""
      if (!nzchar(dst) || !file.exists(dst)) {
        showNotification("打包完了，但包不见了（临时目录被清理）",
                         type = "error", duration = 12)
        return()
      }
      art_zip_pick(list(kind = "zipbg", path = dst, name = job$name))
      session$sendCustomMessage("dsapp:clickWhenReady",
                                list(id = ns("art_dl_zip")))
    })

    # ---- 预览（V7 item 2）---------------------------------------------------
    #
    # 用户的原话：「点击言出法随页面的文件名，可以先跳转预览，再有下载按钮
    # 决定要不要下载」。原来点名字 = 直接下载 —— 而产物多半是图和表，用户
    # 想先看一眼再决定拿不拿走。直接下载等于逼他去浏览器的下载目录里翻。
    #
    # ⚠️ 用弹窗，不把预览塞进对话流。产物卡片在**每一条**助手消息下面都有，
    #    内联展开的话，点开一个文件就把整个对话流顶长一截；更麻烦的是那个
    #    展开态会留在消息里，滑走再回来还在，看起来像消息本身的内容。
    #
    # ⚠️ easyClose 用默认的 TRUE。mod_chat 里另有一个 easyClose = FALSE 的
    #    网关弹窗，那个挡着是有意的（没配 Key 就不该放行）；预览挡着没有任何
    #    理由，必须能按 Esc / 点边上关掉。
    #
    # 预览**不新增静态路由**。工作区是每个对话私有的，一个不经过 server 函数
    # 的静态路由意味着谁猜到文件名谁就能拿走别人的产物 —— "volcano.png" 这种
    # 名字根本不用猜。图和 PDF 分别走 renderImage 与 session$fileUrl()，两者都是
    # 会话级的；表格和文本在服务端读出来变成 HTML，压根不暴露路径。
    art_view <- reactiveVal(NULL)

    # ★ V15.4 item 2：弹窗开着的时候，这个文件可能被**覆盖写**。
    #
    # 用户报的「并没有在言出法随的文件预览界面同步」有一半是这一条：模型
    # 改一个参数、重跑同一段脚本、输出到**同一个文件名**，是这类分析的常态
    # （那一轮对话里 `flag_geometry_*` 就迭代了三版）。而弹窗是纯
    # reactiveVal —— 除了用户自己关掉再点开，**没有任何东西**能让它重画：
    # 图还是上一版，报告还是上一版，看起来和"没重跑"一模一样。
    #
    # 判据是 (路径, 字节数, mtime) 三个一起。⚠️ 少一个都会漏：
    #   · 只比 size → 等长的改写（改个坐标、换个色）看不到；
    #   · 只比 mtime → 同一秒内的改写（脚本几毫秒跑完）看不到。
    #   理由和 executor.R 里 dsapp_ws_diff_stamped 上面写的完全一样。
    #
    # ⚠️ 没打开过预览时它是**空转**的：checkFunc 第一行就 return，不查库、
    #    不 stat。所以它常驻着不碍事，不用去找"弹窗关闭"的回调 —— Shiny
    #    压根不通知服务端 Esc / 点背景关掉这件事。
    art_preview_sig <- function() {
      nm <- art_view()
      if (is.null(nm)) return("")
      p <- tryCatch(dsapp_art_path(nm, rv$session_id, cfg()),
                    error = function(e) NULL)
      if (is.null(p) || !file.exists(p)) return(paste(nm, "gone"))
      fi <- file.info(p)
      paste(nm, fi$size, as.numeric(fi$mtime))
    }
    art_preview_poll <- reactivePoll(
      2000, session,
      checkFunc = art_preview_sig,
      # valueFunc 和 checkFunc 同一份计算：这个 poll 的**唯一**用处就是
      # "签名变了 → 下游重画"，值本身没人读。复用同一个函数是为了不让两份
      # 判据有走样的机会（走样了就是"签名说变了、值说没变"，界面卡住）。
      valueFunc = art_preview_sig)

    output$art_preview_ui <- renderUI({
      nm <- art_view()
      if (is.null(nm)) return(NULL)
      # ★ V15.4 item 2：读一下这个 poll —— 这就是"文件被覆盖写时整格跟着
      #   重画"的机制。下面的 body 分五种，其中有四种自己就会重新读盘
      #   （md/text/table 在服务端读，image 走 renderImage 的 data: URL），
      #   只有 html/pdf 那条 iframe 要吃下面的 cache-buster。
      sig <- art_preview_poll()
      # ★ V13.11 item 1：dsapp_art_path 认两种坐标（工作区 / 文件区）。
      path <- dsapp_art_path(nm, rv$session_id, cfg())
      if (is.null(path) || !file.exists(path)) {
        return(div(class = "alert alert-warning m-0",
                   "文件不存在 —— 可能已经被删掉或改名了。"))
      }
      size <- file.info(path)$size
      # ⚠️ 判类型要用**去掉前缀之后**的名字：`dsapp_file_kind("files:x/y.png")`
      #    的 file_ext 是 "png" 没错，但 `files:x/分析报告.md` 这种带冒号的
      #    名字在 tolower/file_ext 那一关不会被剥掉前缀 —— 现在恰好还能出正确
      #    的扩展名，可一旦前缀里带点号就全错。显式剥一次，别赌。
      nm_kind <- dsapp_art_label(nm)
      kind <- dsapp_file_kind(nm_kind)

      head <- div(class = "d-flex justify-content-between align-items-baseline mb-2",
        div(class = "text-truncate", tags$b(nm)),
        span(class = "small text-muted ms-2 flex-shrink-0",
             dsapp_fmt_bytes(size)))

      # 体积闸门，和「文件」页同一条线（V11 item 11）。理由见 files.R 里
      # DSAPP_PREVIEW_MAX_BYTES 上面那段 —— 这里多一层是因为对话里的产物
      # 是模型自己写的，用户点开之前对大小没有预期。
      if (!is.na(size) && size > DSAPP_PREVIEW_MAX_BYTES) {
        return(tagList(head, div(class = "alert alert-secondary m-0",
          sprintf("超过在线预览上限 %s，请下载后查看。",
                  dsapp_fmt_bytes(DSAPP_PREVIEW_MAX_BYTES)))))
      }

      body <- if (kind == "image") {
        # ★ V13.2 item 9：外面包一层自己的类。
        #
        # ⚠️ 用户的原话是「html 预览很好，能够和背景弹窗自适应，但是图片会
        #    溢出背景弹窗」。原因不在弹窗上：html 走的是 iframe，我们给了
        #    `width:100%; height:70vh`，所以它天生就跟着弹窗走；而图片走的是
        #    `imageOutput()`，`renderImage()` 返回的 list 里**没给 width/height**
        #    —— Shiny 于是渲染成一个**原始尺寸**的 `<img>`，一张 4000px 宽的
        #    图就顶出弹窗去了。
        #
        #    Shiny 自己有一条能救的规则（`.shiny-image-output img.shiny-scalable
        #    { max-width:100%; max-height:100% }`），但它要求渲染时同时给出
        #    width 和 height 才会加上 `shiny-scalable` 这个类 —— 这版 Shiny
        #    的 shiny.min.js 里根本搜不到这个类名，所以那条规则是死的。
        #    不去猜它，直接在 www/app.css 里按自己的类名约束。
        div(class = "dsapp-preview-img",
            imageOutput(ns("art_preview_img"), height = "auto"))

      } else if (kind == "html") {
        # V11 item 1：渲染出来。以前 html 走 text 分支，用户看到的是一整页
        # 源码。沙箱和 CSP 的理由见 files.R 的 dsapp_preview_url —— 这里
        # 比「文件」页更要紧：产物是**模型写的**，用户没理由信任它。
        url <- dsapp_preview_url(session, path, "text/html; charset=utf-8", cfg())
        if (is.null(url)) {
          div(class = "alert alert-secondary m-0", "这个文件读不出来，请下载后查看。")
        } else {
          # ⚠️ `?v=` 是**必要的**，不是保险起见：dsapp_preview_url() 注册的
          #    dataobj 名字是 `pv-<路径和 mime 的 md5>`（见 files.R），而路径
          #    没变 —— 文件被覆盖写之后 URL **一模一样**。Shiny 那个处理器
          #    不发 Cache-Control / ETag / Last-Modified，重画出来的 iframe
          #    src 不变，浏览器要不要吃缓存就变成听天由命了。把签名挂上去，
          #    内容一变 URL 就变，这条不确定性就没有了。
          #    处理器不读查询串，多带一个参数它不管。
          tags$iframe(src = paste0(url, "?v=",
                                   substr(digest::digest(sig, algo = "crc32"),
                                          1, 8)),
                      sandbox = "allow-scripts allow-popups",
                      style = "width: 100%; height: 70vh; border: 0;",
                      class = "dsapp-preview-frame")
        }

      } else if (kind == "markdown") {
        # ★ V13.12 item 9：**渲染全文**。用户原话「md 报告和 html 报告可以
        #   全部渲染，不用只预览前 20 行」—— 报告是拿来读的，截断等于没给。
        #   （html 那条本来就是整份塞进 iframe 的，没有截断，见上面那个分支。）
        full <- dsapp_preview_full(path)
        tagList(
          if (full$truncated)
            p(class = "small text-muted mb-1",
              sprintf("文件太大，只渲染前 %d 行。", DSAPP_PREVIEW_LINES)) else NULL,
          div(class = "dsapp-preview-md",
              HTML(dsapp_md_html(full$text))))

      } else if (kind == "table") {
        df <- dsapp_preview_table(path, n = 100)
        if (is.null(df)) {
          div(class = "alert alert-warning m-0",
              "无法解析为表格。可能是分隔符不是逗号/制表符，或文件不是表格。")
        } else {
          tagList(
            p(class = "small text-muted mb-1",
              sprintf("预览前 %d 行。下载后在本地打开可以看全部。", nrow(df))),
            DT::dataTableOutput(ns("art_preview_tbl")))
        }

      } else if (kind == "text") {
        # V11 item 11：按行取前 20 行，不再是"末尾 512 KB"。
        # 读开头不读末尾，理由见 mod_files.R 同一处。
        h <- dsapp_preview_head(path, DSAPP_PREVIEW_LINES)
        tagList(
          if (h$truncated)
            p(class = "small text-muted mb-1",
              sprintf("只显示前 %d 行。", DSAPP_PREVIEW_LINES)) else NULL,
          tags$pre(class = "dsapp-preview-pre",
                   dsapp_escape(paste(h$lines, collapse = "\n"))))

      } else if (kind == "pdf") {
        # V11：以前走 session$fileUrl()，那是把整个文件 base64 进 data: URL，
        # 所以只能卡 6MB。改用和 HTML 同一条会话级接口后，字节是流过去的，
        # 上限直接跟在线预览的上限（20MB）对齐。
        url <- dsapp_preview_url(session, path, "application/pdf", cfg())
        if (is.null(url)) {
          div(class = "alert alert-secondary m-0", "这个 PDF 读不出来，请下载后查看。")
        } else {
          # `?v=` 的理由同上面 html 那一支。
          tags$iframe(src = paste0(url, "?v=",
                                   substr(digest::digest(sig, algo = "crc32"),
                                          1, 8)),
                      style = "width: 100%; height: 70vh; border: 0;")
        }

      } else {
        div(class = "alert alert-secondary m-0",
            sprintf("%s 文件不支持在线预览，下载后用本地软件打开。",
                    if (kind == "archive") "压缩包" else "这类二进制"))
      }

      tagList(head, body)
    })

    output$art_preview_img <- renderImage({
      # ★ V15.4 item 2：这一格原来只依赖 art_view()，所以文件被覆盖写之后
      #   它**不会重跑** —— 用户看到的还是上一版那张图。
      #   ⚠️ 重跑之后 src 会自动换掉：Shiny 的 session$fileUrl() 是把整个
      #      文件 base64 进 data: URL 的（见 files.R 里 DSAPP_THUMB_MAX_BYTES
      #      上面那段），内容一变 URL 就变，不用自己加 cache-buster。
      art_preview_poll()
      nm <- art_view()
      req(nm)
      p <- dsapp_art_path(nm, rv$session_id, cfg())
      req(p, file.exists(p))
      list(src = p,
           contentType = dsapp_image_mime(dsapp_art_label(nm)),
           alt = dsapp_art_label(nm))
    }, deleteFile = FALSE)

    output$art_preview_tbl <- DT::renderDataTable({
      # ★ V15.4 item 2：同理 —— 表格是服务端在渲染时读出来的，不重跑就永远
      #   是点开那一刻的那一份。
      art_preview_poll()
      nm <- art_view()
      req(nm)
      p <- dsapp_art_path(nm, rv$session_id, cfg())
      req(p)
      df <- dsapp_preview_table(p, n = 100)
      req(df)
      DT::datatable(df, rownames = FALSE,
                    options = list(dom = "t", pageLength = 10, scrollX = TRUE))
    })

    # 列表里那个小图标：直接下载，不预览。它本来就写着"下载"，点它的人
    # 已经决定要拿走了，再弹一次预览是多余的一步。
    observeEvent(input$art_want, {
      req(input$art_want)
      art_pick(input$art_want)
      session$sendCustomMessage("dsapp:clickWhenReady",
                                list(id = ns("art_dl")))
    })

    # 文件名：先预览。弹窗里那个下载按钮用的是同一个 art_pick()，所以这里
    # 必须一起设上 —— 不然用户点开预览再点"下载"，拿到的是上一次点过的文件。
    observeEvent(input$art_preview_want, {
      req(input$art_preview_want)
      nm <- input$art_preview_want
      art_view(nm)
      art_pick(nm)
      showModal(modalDialog(
        # ⚠️ basename() 不够：nm 是产物坐标（`files:对话文件夹/results/x.png`），
        #    坐标正好是"文件夹本身"时 basename 会把整串原样还回来，那串会
        #    直接显示在弹窗标题上。先剥前缀再取末段。
        title = tagList(icon("magnifying-glass"), " ",
                        basename(dsapp_art_label(nm))),
        size = "l",
        easyClose = TRUE,
        uiOutput(ns("art_preview_ui")),
        footer = tagList(
          modalButton("关闭"),
          # ★ V13.9 item 8：这里原来写的是
          #     downloadButton(ns("art_dl2"), tagList(icon("download"), " 下载"), ...)
          #   ——用户原话：「下载按钮有两个logo，去掉一个」。
          #
          #   ⚠️ 根因是 shiny::downloadButton() 自己**带一个默认图标**：
          #        function(outputId, label = "Download", class = NULL, ...,
          #                 icon = shiny::icon("download"))
          #      所以显式再塞一个 icon("download") 进去就是两个。
          #      把标签还原成纯文本，留下的那一个是它默认的那个 ——
          #      而不是反过来去传 icon = NULL，那样按钮上就一个图标都没有了。
          #
          #   ⚠️ 别顺手给别的 downloadButton 也加图标：同页
          #      mod_files.R 那两颗（ws_dl / download）标签都是纯文本，
          #      它们是对的。`downloadLink` 没有 icon 参数，不受这条影响。
          downloadButton(ns("art_dl2"), " 下载", class = "btn-primary")
        )
      ))
    })

    # 产物卡片上两个跳转入口（右上角"管理 →"、文件多于 8 个时那句
    # "看全部"）汇到这里。两个 id 是**必须分开**的，理由见下面那个
    # actionLink 旁边的注释：共用一个 id 会让先点的那个把后点的那个顶掉。
    #
    # 走 dsapp_goto（顶层 session）。原来这里是裸的
    # `bslib::nav_select("nav", "files")`，在模块里被加了命名空间前缀，
    # 点了没反应 —— 2026-09-14 用户报的就是这一条。
    #
    # ★ V13.9 item 3：跳过去之前**先把 focus_ws 清掉**。
    #
    #   用户原话：「本对话的文件显示的不对，没有自动跳转到专属文件夹」。
    #
    #   根因不在这个链接上，而在 state$focus_ws 是个**只写不删**的粘滞状态：
    #   「文件」页显示哪个对话的工作区由 show_sid() 决定（mod_files.R），
    #   而它的取值顺序是 focus_ws **优先于** state$chat_session_id。于是只要
    #   用户之前在任务页点过一次「在文件区打开」（mod_tasks.R 会写 focus_ws），
    #   这一格就永远停在**那条任务所属的对话**上 —— 之后从言出法随页点
    #   「在「文件」页管理 →」，人已经切到新对话了，文件页却还在显示旧对话的
    #   产物，而且不报任何错（focus_bar 那条说明也说不出哪里不对）。
    #
    #   清掉之后 show_sid() 回落到 state$chat_session_id（mod_chat 一直在把
    #   rv$session_id 镜像进去），也就是**当前这个对话**——正是用户要的
    #   「专属文件夹」。不清成"显式设成当前 sid"是**故意的**：那样 focus_bar
    #   会冒出一条"已定位到…／取消定位"，而用户只是正常切了个页，没要求定位。
    #
    # ★ V13.11 item 1：原来这里还有个 keep_focus 开关，给"点对话里的目录行
    #   跳到文件页并停在那一项上"（art_goto）用。那张卡改成**原地进目录**之后
    #   这条路没了 —— 目录行不再往文件页跳，所以清空 focus_ws 成了唯一行为，
    #   参数也就没有存在的理由了（留着会让人以为还有另一条路）。
    dsapp_goto_files <- function() {
      state$focus_ws <- NULL
      dsapp_goto("files")
    }
    observeEvent(input$goto_files,     dsapp_goto_files())
    observeEvent(input$goto_files_all, dsapp_goto_files())

    # ---- 「本对话的文件」卡片的数据源（V13.11 item 1）-----------------------
    #
    # 用户原话：「言出法随页面本对话的文件只显示当前对话所属文件夹即可，
    # 点击文件夹应该直接在本对话文件中进入，而不是跳转文件页面」。
    #
    # ⚠️ 改之前这张卡读的是**工作区**（dsapp_ws_artifacts），而工作区根目录里
    #    有整个文件区的镜像（dsapp_mirror_shared 把用户文件区**整片**映进去：
    #    目录是真建的，文件是软链）。于是"本对话的文件"列出来的是**所有**对话
    #    的文件夹 —— 用户看到别人的东西混在自己的产出里，这正是他要修的那一条。
    #
    # 现在改成：根 = 本对话在文件管理区里的那个文件夹
    # （`data/files/u<N>/<标题>-<尾4位>/`，由 dsapp_sync_dir 定名）。
    # 选文件区而不是"工作区里那个镜像目录"是有意的：镜像只在**执行开始时**
    # 刷新一次，任务刚跑完那一刻它是旧的，用户点进来会看到上一轮的产物；
    # 而文件区就是同步动作的落点，永远是最新的。
    #
    # 两层坐标（文件区 / 工作区）怎么区分，见 files.R 里 dsapp_art_path 的说明。
    art_dir <- reactiveVal(NULL)   # 文件区相对路径；第一段恒为本对话文件夹名

    # 本对话的文件夹名。dsapp_sync_dir 首次调用会**写库**定名，之后只读 ——
    # 所以放在 reactive 里是安全的（依赖不变就不会重算，不会每 3 秒写一次库）。
    #
    # ★★ V15.5 item 10(a)：依赖里**必须**带上 sess_ver（会话版本号）。
    #
    #   用户原话：「新会话的产出仍然不能在对话框右侧实时更新，以前版本还可以
    #   的，现在怎么反而不行了？」—— 有一半就是这一条。
    #
    #   文件夹的名字**会变**：新对话刚建出来时它叫「新会话-4279」（dsapp_sync_dir
    #   第一次被调用时定下），用户发出第一条消息之后，正文落库那一步会顺手把
    #   对话改名（db_session_rename → dsapp_sync_rename），文件夹跟着变成
    #   「差异分析-4279」。而这里原来只依赖 rv$session_id —— 新建对话的那一刻
    #   它就定住了，改名不重算，于是 conv_dir() 一直捏着「新会话-4279」这个
    #   **已经没人用的**文件夹名：卡片拿着它去 dsapp_file_path() 解析出一个
    #   不存在的目录，dsapp_files_list() 老老实实返回空表。
    #
    #   ⚠️ 症状是"这个对话的产出永远是空的"，而且**只有整页刷新才好**（那时
    #      新 session 才重算一次）。卡片头上那颗手动刷新按钮也救不了：它只让
    #      两个 poll 重算摘要，改不了"在看哪个目录"。更坏的是收尾同步会**按新
    #      名字**建目录 —— 盘上东西都在，界面上一个都不显示。
    #
    #   ⚠️ 读 sess_ver() 不是自激：改名、发消息、切对话那几处各自 +1，这里
    #      只读不写，下游（卡片、art_here、那两个 poll）谁都不碰它。
    #      ⚠️ 别把这里换成某个 new.env() 里的字段：读 environment 的字段
    #      **不建立依赖**，值变了也不会重算 —— 那样看着更"轻"，但是静默失效。
    conv_dir <- reactive({
      sess_ver()
      sid <- rv$session_id
      if (is.null(sid) || !nzchar(sid)) return(NULL)
      tryCatch(dsapp_sync_dir(sid, dsapp_config_sid(sid, cfg())),
               error = function(e) NULL)
    })

    # 当前层。夹一层校验：art_dir 里存的路径**必须**在本对话文件夹底下。
    # 换对话之后残留的旧路径（比如切走再切回来）会在这里被拒掉，回落到根。
    art_here <- reactive({
      cd <- conv_dir()
      if (is.null(cd) || !nzchar(cd)) return(NULL)
      d <- art_dir()
      if (is.null(d) || !nzchar(d)) return(cd)
      if (identical(d, cd) || startsWith(d, paste0(cd, "/"))) return(d)
      cd
    })

    # ---- 当前层在"本对话内部"与"工作区里"的两种写法 -------------------------
    #
    # ★ V15.5 item 10：产物有**两个根**（文件区 / 工作区，见 files.R 里
    #   dsapp_art_path 的说明），但"层"是同一个东西：文件区里是
    #   `<对话文件夹>/results`，工作区里就是 `results` —— 收尾同步
    #   （dsapp_sync_artifacts）是把工作区里的那份**原样**复制进对话文件夹的。
    #   ⚠️ 这个换算只写这一处。两处各写一遍 `substring(here, nchar(cd) + 2L)`
    #      迟早会漂一个字符，而漂了之后工作区那一侧会去列一个不存在的目录
    #      —— 不报错、只是空，看起来和"这个对话没有产物"一模一样。
    art_rel_in <- function() {
      here <- art_here()
      cd <- conv_dir()
      if (is.null(here) || is.null(cd) || !nzchar(cd)) return(NULL)
      if (identical(here, cd)) return("")
      if (!startsWith(here, paste0(cd, "/"))) return(NULL)
      substring(here, nchar(cd) + 2L)
    }

    # 当前这一层在**工作区**里对应的目录（可能不存在：任务还没跑到那一步、
    # 或者这个文件夹本来就是别人在文件区里建的）。
    art_ws_level <- function() {
      ri <- art_rel_in()
      sid <- rv$session_id
      if (is.null(ri) || is.null(sid)) return(NULL)
      ws <- tryCatch(dsapp_ws_dir(sid, cfg(), create = FALSE),
                     error = function(e) NULL)
      if (is.null(ws) || is.na(ws) || !dir.exists(ws)) return(NULL)
      if (nzchar(ri)) file.path(ws, ri) else ws
    }

    # 工作区坐标：把"当前层"那一段补回去（工作区这一支**不带** files: 前缀）。
    # ⚠️ 同一个道理：dsapp_art_tree_images() 给的 rel 是相对它自己的 root 的，
    #    少补这一层，坐标会指到工作区根目录下的同名路径上（或者指空）。
    art_ws_ref <- function(rel) {
      ri <- art_rel_in()
      rel <- as.character(rel %||% "")
      if (is.null(ri) || !nzchar(ri)) rel else paste0(ri, "/", rel)
    }

    # ---- ★★ V15.5 item 10(b)：卡片要**并上工作区里还没同步过来的那份** ----
    #
    # 用户原话：「新会话的产出仍然不能在对话框右侧实时更新，以前版本还可以的，
    #           现在怎么反而不行了？」（后半句是这一条）
    #
    # 产物进文件区**只有一条路**：任务收尾时 dsapp_sync_artifacts 复制一次
    # （R/taskrun.R 的 dsapp_task_closeout，那边白纸黑字写着"不在执行途中
    # 同步"）。所以一次任务**跑的过程中**，文件区一个字节都不变 —— 而卡片读的
    # 就是文件区，于是从头到尾一动不动，用户正坐在那儿等它动。V13.10 那版
    # 没事，是因为它直接读工作区；V13.11 为了"别把别的对话的文件夹混进来"
    # 改读文件区，实时性就是那时候丢的。
    #
    # ⚠️ 所以**不能**简单改回读工作区（那就是 V13.11 item 1 修掉的 bug）：
    #    工作区**根目录**里有整个文件区的镜像（dsapp_mirror_shared 把用户文件区
    #    整片映进去：目录真建、文件软链），直接列就会把**所有**对话的文件夹
    #    混进来。
    #
    # 这里的规则是"文件区那份说了算，工作区只补文件区里还没有的"：
    #   · 文件区的行原样在前：坐标、大小、mtime 都是收尾那一步的定稿；
    #   · 只有工作区**独有**的行（按名字去重）跟在后面，它们发给前端时用
    #     **工作区坐标**（不带前缀）—— 预览、下载都认这一支；
    #   · 工作区的**目录**行也用文件区坐标（`files:` + 这一层的相对路径）：
    #     "点目录原地进这一层"那条路一条都不用改，下一层再去工作区里取内容。
    # ⚠️ 排掉镜像那一整片，靠的是"用户文件区**顶层**的条目"这份名单（现算，
    #    不另维护一份）：镜像的根就是文件区根，镜像出来的目录名 = 那里顶层的
    #    名字。镜像进来的**文件**是软链，find -type f 本来就不认它们，所以
    #    只需要排目录/顶层这一段。
    # ⚠️ 同名时以**文件区**为准（不是"以新的为准"）：文件区那份是定稿，而工作区
    #    那份可能正被写。代价是模型原地覆盖写一个**已有**的产物时，那一行的
    #    大小/时间要等收尾才更新 —— 但"多出来的新名字是实时的"，这就够了。
    # ⚠️ 依赖 artifacts() 是**故意**的（不 isolate）：它盯的就是工作区根目录的
    #    递归摘要，每 3 秒已经在算一次了；不读它的话，任务跑着的时候这个 poll
    #    的 cookie 不会变，新产出要等到收尾才冒出来。也**不要**在这里再跑一遍
    #    find 去算工作区摘要 —— 那是把同一件事做两遍（工作区里还躺着 .Rlib /
    #    .venv 这种几千个文件的目录）。
    art_ws_rows <- function(sid) {
      ri <- art_rel_in()
      a <- artifacts()
      if (is.null(ri) || is.null(sid) || is.null(a) || !nrow(a)) return(NULL)
      p <- as.character(a$name)
      # 只要当前这一层：列表的语义是"这一层有什么"，穿透子目录的是缩略图那条路。
      # ⚠️ dirname("x.csv") 是 "."（不是 ""），根那一层拿它对齐。
      cur <- if (nzchar(ri)) ri else "."
      keep <- !is.na(p) & dirname(p) == cur
      if (!any(keep)) return(NULL)
      # cfg_sid 到这一刻才需要（要拿 cfg_sid$files_dir 列出"文件区顶层"那份
      # 名单）。文件区那支的解析不能共用它 —— 那一句有自己的定式，见 valueFunc。
      cfg_sid <- dsapp_config_sid(sid, cfg())
      mirror <- tryCatch(
        list.files(cfg_sid$files_dir, all.files = TRUE, no.. = TRUE),
        error = function(e) character(0))
      keep <- keep & !(sub("/.*$", "", p) %in% mirror)
      if (!any(keep)) return(NULL)
      sub <- a[keep, , drop = FALSE]
      nm <- basename(as.character(sub$name))
      here <- art_here()
      isd <- as.logical(sub$is_dir)
      # ★ V16.10：目录行的坐标要按**它真在哪**发。
      #
      # 原来只有一句"目录用文件区坐标"（因为点目录是原地进这一层，而"层"
      # 是文件区口径）—— 对一个**已经同步过去**的目录是对的；对一个**只在
      # 工作区里**的目录（任务刚跑完、收尾同步还没走到它），那个坐标指向
      # 文件区里一个**不存在**的路径。后果分两半：
      #   · 点它进去：碰巧还能用（卡片的工作区那半边自己会把内容列出来）；
      #   · ★★ 打包整层：`dsapp_zip_plan()` 里 `must_exist` 拿不到就 `next`
      #     —— 整个子目录**静默**从包里消失。
      # 2026-10-07 实测（`tests/ui_v1610` 那条探针就是为它写的）：根上点
      # 「打包下载」，包里只有 5 条、少了 `results/figures/` 底下那两张图，
      # 界面上一个提示都没有 —— 用户拿到一个缺件的包，还以为就是这些。
      #
      # 现在：文件区里真有这一层 → 文件区坐标（进的是那份定稿）；没有 →
      # **工作区坐标**（和上面文件那一支同一条规矩）。两种 `art_open` 都认。
      dir_coord <- vapply(seq_along(nm), function(i) {
        if (!isTRUE(isd[[i]])) return(as.character(sub$name[[i]]))
        fr <- paste0(here, "/", nm[[i]])
        if (file.exists(file.path(cfg_sid$files_dir, fr)))
          dsapp_art_files_ref(fr)
        else as.character(sub$name[[i]])
      }, character(1))
      data.frame(
        name   = nm,
        # rel 仍是**文件区**口径（`<对话文件夹>/这一层/名字`）：合并进来的这
        # 几行要和文件区那几行同列同义，rbind 才是安全的。
        rel    = paste0(here, "/", nm),
        is_dir = isd,
        size   = as.numeric(sub$size),
        size_h = as.character(sub$size_h),
        mtime  = as.character(sub$mtime),
        # 注意工作区那支把目录标成 "dir"、文件区那支标 "folder" —— 这里统一成
        # 文件区的写法，免得下游按 kind 判"是不是目录"时对一半。
        kind   = ifelse(isd, "folder", as.character(sub$kind)),
        # ⚠️ 坐标只有**文件区里真有的**才带 `files:` 前缀 —— 文件和目录都是
        #    这一条规矩（文件那一支的来由见下面那句，目录那一支见上面
        #    `dir_coord` 那一段）。统一按前缀拼的话，工作区独有的东西会被
        #    解析到文件区里一个不存在的位置：点预览什么都不出现、点下载报
        #    一句和下载无关的错、打包**静默少打一份**。
        coord  = dir_coord,
        stringsAsFactors = FALSE)
    }

    # 合并：文件区那些行 + 工作区独有的行。
    # ⚠️ 空表也要带上 coord 列（rbind 按列名对齐，少一列会**报错**，而这条路
    #    上报错就是整张卡片渲染不出来）。
    art_level_merge <- function(df, sid) {
      if (is.null(df)) df <- dsapp_files_empty()
      df$coord <- dsapp_art_files_ref(df$rel)
      ws <- art_ws_rows(sid)
      if (is.null(ws) || !nrow(ws)) return(df)
      # 去重是"名字"级别的：同一份产物两边都有时留文件区那份（理由见上）。
      ws <- ws[!(ws$name %in% df$name), , drop = FALSE]
      if (!nrow(ws)) return(df)
      rbind(df, ws)
    }

    art_df_empty <- function() {
      df <- dsapp_files_empty()
      df$coord <- character(0)
      df
    }

    # ★ V16.10：**当前这一层**的清单，排好序的那一份。
    #
    # 卡片（`output$artifacts_card`）和那颗「打包下载」（`output$art_zip_ui`
    # 和它的处理器）必须读同一份 —— 不然按钮上那个「N 项」和卡片列出来的
    # 行数是两个数（一个忘了合并工作区行、一个忘了排序），而这两个数**没
    # 有任何办法从界面上核对**：用户看到的是"按钮说 12 项、列表里只有 8 行"
    # （卡片本来就截断到 8 行），看起来完全正常。
    #
    # ⚠️ `dsapp_files_order()` 是幂等的（目录在前、文件按 mtime 从新到旧），
    #    所以多过一遍不会改变什么；但**别**指望这一点来省掉卡片那一遍 ——
    #    下面两处都写成读这一个函数，谁也别自己排。
    art_level_df <- reactive({
      df <- art_files()
      if (is.null(df)) df <- art_df_empty()
      # ★ V16.10：展示字段（图标名 / 目录徽标 / 目录体积那一格怎么写）整组过
      #   一次 `dsapp_files_rows()` —— 和「文件」页那张表、右栏那些行读的是
      #   **同一个来源**。两个页面各写一遍 ifelse 就是用户说的"两套文件展示
      #   系统"，而漂一个字（`file-lines` vs `file`、目录留空 vs `—`）在两页
      #   上看着都正常，只有把两页并排看才看得出来。
      #   ⚠️ 它**不负责排序**，所以 `dsapp_files_order()` 那一句还得自己来 ——
      #      "字段"和"顺序"是两件事，少哪一件都是静默的。
      dsapp_files_rows(dsapp_files_order(df))
    })

    # 工作区那一份的摘要，只用来当 cookie 的一部分。
    # ⚠️ 它和文件区那三个数**分别**拼进 cookie，不能先各自求和再拼一个：
    #    文件区删掉一个文件、工作区同时新增一个，两个变化会在求和里互相抵消，
    #    cookie 看着没动，界面就不刷新了。
    art_ws_sig <- function() {
      a <- artifacts()
      if (is.null(a) || !nrow(a)) return("0 0 0")
      paste(nrow(a), sum(a$size, na.rm = TRUE),
            sum(as.numeric(a$mtime_raw), na.rm = TRUE))
    }

    # 当前层的内容。和产物缩略图、正文里的文件名链接共用同一份数据。
    #
    # ⚠️ checkFunc 里读 art_here() **不 isolate**：进/退一层要立刻重算。
    #    isolate 掉的话，用户点了文件夹得等下一个 3 秒才看到内容 ——
    #    "点了没反应"，但 3 秒后又自己对了，是最容易被当成偶发的那类 bug。
    # ⚠️ 摘要要**递归**（dsapp_ws_snapshot(dirs = TRUE)），理由同上面 artifacts
    #    那个 poll：只看顶层的话，模型往子目录里覆盖写一张图摘要不变，
    #    界面就一直是上一版。
    art_files <- reactivePoll(
      3000, session,
      checkFunc = function() {
        # ★ V15.4 item 2：和上面 artifacts 那个 poll 逐字同理 —— 计数器读在
        #   第一行、每条 return 都拼上，别只在末尾拼。见那一段的注释。
        #   ⚠️ 这里读 art_refresh() **不 isolate**：这也是那颗手动刷新按钮
        #      能立刻生效的机制（读它 → 建立依赖 → 值一变这个 poll 马上重跑）。
        extra <- paste(dsapp_art_rev(), art_refresh())
        sid <- rv$session_id
        d <- art_here()
        # ★ V15.5 item 10(b)：每一条 return 都要带上工作区那一份的摘要
        #   （art_ws_sig()，理由见 art_ws_rows() 上面那一段）。这三条提前
        #   return 正是"任务刚跑起来、文件区还什么都没有"的时候 —— 而那时
        #   工作区里可能已经有产出了。少了它，用户盯着的那一格偏偏在最需要
        #   动的几分钟里一动不动。
        if (is.null(sid) || is.null(d)) return(paste("0 0 0", art_ws_sig(), extra))
        dd <- dsapp_file_path(d, dsapp_config_sid(sid, cfg()), must_exist = FALSE)
        if (is.null(dd) || !dir.exists(dd)) return(paste("0 0 0", art_ws_sig(), extra))
        fs <- dsapp_ws_snapshot(dd, dirs = TRUE)
        if (!length(fs)) return(paste("0 0 0", art_ws_sig(), extra))
        fi <- file.info(file.path(dd, fs))
        paste(length(fs), sum(fi$size, na.rm = TRUE),
              sum(as.numeric(fi$mtime), na.rm = TRUE), art_ws_sig(), extra)
      },
      valueFunc = function() {
        sid <- rv$session_id
        d <- art_here()
        if (is.null(sid) || is.null(d)) return(art_df_empty())
        # ⚠️ 这一句是定式：`dsapp_files_list(dsapp_config_sid(sid, cfg()), d)`。
        #    别顺手把 cfg_sid 提出来"省一次查询"—— 文件区是按账号分的，而这里
        #    必须按**对话主人**绑 cfg（共享出去的对话，看页面的人不是主人；用
        #    观看者的 cfg 会去他自己的文件区里找一个不存在的文件夹，表现是
        #    "这个对话一个文件都没有"，而主人那边明明有）。
        #    合并那一支自己会再算一次 cfg_sid —— 它只在**真的有工作区行要并**
        #    的时候才需要（要用它列"文件区顶层"那份名单），平时一次都不多查。
        base <- tryCatch(dsapp_files_list(dsapp_config_sid(sid, cfg()), d),
                         error = function(e) dsapp_files_empty())
        art_level_merge(base, sid)
      }
    )

    # ---- 要出缩略图的那几张（★ V15.4 item 2）------------------------------
    # UI（output$artifacts_card）和那四个 renderImage 槽位**必须**都调
    # 这一个函数。两边各写一遍筛选条件，改了一边漏了另一边，表现是界面上
    # 一个空的缩略图框 —— 不报错，只是什么都不显示，最难查的那类问题。
    # （这段注释原来在 n_thumb_slots 那个循环里，现在筛选条件复杂了
    #  —— 要递归、要去重名 —— 更得只留一处。）
    #
    # ⚠️ 一次卡片渲染里它会被调 1 + 4 次（卡片自己一次，四个槽位各一次）。
    #    每次都跑一遍 find + file.info，看着浪费，但**不要**为了省这个装
    #    缓存：缓存键要么漏掉 dsapp_art_rev()/art_refresh()（刷新按钮就又
    #    失灵了，而且是"有时候灵有时候不灵"），要么就得在这里把
    #    reactivePoll 的 cookie 重算一遍。一次 find 是几毫秒，不值当。
    # 缩略图表的形状统一在这一处：`dsapp_art_tree_images()` 在"没有图"时给的
    # 是一个**不带 mtime、也不带 coord** 的空表，而下游是按列名取的
    # （tdf$name / tdf$coord / …）—— `$` 取不到的列给的是 NULL，不报错，
    # 表现是"图不出来但一切正常"，最难查的那一类。空表也补齐同样的六列。
    # `coord_of` = "把这一支的相对路径拼成坐标"的函数：文件区那支要补上当前层
    # 再包 `files:` 前缀，工作区那支补的是工作区里的层、不带前缀。
    art_thumbs_norm <- function(df, coord_of) {
      if (is.null(df) || !nrow(df)) {
        return(data.frame(name = character(0), rel = character(0),
                          coord = character(0), kind = character(0),
                          size = numeric(0), mtime = numeric(0),
                          stringsAsFactors = FALSE))
      }
      df$coord <- coord_of(df$rel)
      df[, c("name", "rel", "coord", "kind", "size", "mtime"), drop = FALSE]
    }

    art_thumbs <- function() {
      sid <- rv$session_id
      here <- art_here()
      if (is.null(sid) || is.null(here) || !nzchar(here)) {
        return(art_thumbs_norm(NULL, NULL))
      }
      cfg_sid <- dsapp_config_sid(sid, cfg())
      dd <- dsapp_file_path(here, cfg_sid, must_exist = FALSE)
      # ⚠️ `dsapp_art_tree_images()` 给回来的 rel 是**相对它自己的 root** 的
      #    （也就是相对当前这一层），而 `files:` 坐标是相对账号文件区根的 ——
      #    中间差着"当前层"这一段。少拼这一段，`files:results/plot.png` 会被
      #    解析到文件区**根**下的 `results/plot.png`：要么是用户自己传的一份
      #    同名文件（点开看到的是别的东西），要么根本不存在。而**不存在时界面
      #    只是什么都不画**（renderImage 拿到 NULL 就直接返回），不报错、
      #    日志里也没有 —— V15.4 那版的缩略图就这么静默地一直是空的。
      tdf <- art_thumbs_norm(dsapp_art_tree_images(dd, n_max = n_thumb_slots),
                             function(r) dsapp_art_files_ref_in(here, r))
      # ★ V15.5 item 10(b)：工作区那一层也递归取一遍 —— 一次任务**跑的过程中**
      #   文件区里还没有这些图（理由见 art_ws_rows() 上面那一段）。
      #   ⚠️ 两份合并不是"把路径拼一起"就完事：一侧带 files: 前缀、一侧不带，
      #      必须在**各自带上自己的坐标之后**再合并 —— 混着拼必然指到别的文件
      #      上，而且指错的时候不报错。
      wl <- art_ws_level()
      if (!is.null(wl) && dir.exists(wl)) {
        wdf <- art_thumbs_norm(dsapp_art_tree_images(wl, n_max = n_thumb_slots),
                               art_ws_ref)
        # 同一张图两边都有时留**文件区**那份：工作区那版可能正被写，而文件区
        # 那版是收尾同步下来的定稿。
        wdf <- wdf[!(wdf$rel %in% tdf$rel), , drop = FALSE]
        tdf <- rbind(tdf, wdf)
      }
      if (!nrow(tdf)) return(tdf)
      utils::head(tdf[order(-tdf$mtime, tdf$rel), , drop = FALSE], n_thumb_slots)
    }

    # 换对话 → 回到自己文件夹的根。不这么做的话，从上个对话的 results/ 切到
    # 新对话，新对话里没有同名子目录，用户会看到一个空卡片，以为是没产出。
    observeEvent(rv$session_id, art_dir(NULL), ignoreNULL = FALSE)

    # ★ V15.4 item 2：卡片头上那颗手动刷新按钮。
    #   ⚠️ 只自增、不读别的、不写别的 —— 它的全部作用就是让两个 poll 的
    #      checkFunc 返回的字符串发生变化。
    observeEvent(input$art_refresh_btn, {
      art_refresh(art_refresh() + 1L)
      showNotification("已重新读取本对话的文件", type = "message", duration = 2)
    })

    # 原地进子目录（用户点文件夹行）。
    #
    # ⚠️ input 是**客户端可控**的：前端只发本对话文件夹底下的坐标，但服务端
    #    必须自己再判一次，否则构造一个 `files:../../u1/别的东西` 就能让页面
    #    去列别人的文件区。这不是理论风险 —— 这一层的输出会直接渲染成列表。
    observeEvent(input$art_open, {
      nm <- input$art_open
      req(nm)
      cd <- conv_dir()
      if (is.null(cd) || !nzchar(cd)) return()
      # ★ V16.10：**两种坐标都认**（发出方见 `art_ws_rows()` 的 dir_coord）：
      #   · `files:<对话文件夹>/这一层/名字` —— 文件区里真有这一层；
      #   · `<这一层>/名字`（不带前缀）—— 只在工作区里的目录（还没同步）。
      #   换算用的是 `art_rel_in()` 那条既有规矩（文件区是
      #   `<对话文件夹>/results`、工作区就是 `results`），不另立一套。
      rel <- if (startsWith(nm, DSAPP_ART_FILES_PREFIX)) {
        dsapp_art_label(nm)
      } else {
        ri <- art_rel_in()
        paste0(cd, "/",
               if (is.null(ri) || !nzchar(ri)) nm else paste0(ri, "/", nm))
      }
      # ⚠️⚠️ 绝对路径 / `..` 一律拒。`startsWith()` **挡不住**
      #    `<对话文件夹>/../../u1`（它确实以 `<对话文件夹>/` 开头），而这一层
      #    的输出会直接渲染成文件列表 —— 那就等于让人隔着页面列别人的文件区。
      #    `dsapp_rel_segments()` 遇到 `..` / `.` / 前导 `/` / `C:` / `-` 开头
      #    返回 NULL，正是这里要的那道闸。它是本仓唯一的路径校验实现
      #    （`dsapp_path_in()` 只是再接一层软链检查），别在这另写一遍。
      if (is.null(dsapp_rel_segments(rel))) return()
      # ⚠️ input 是**客户端可控**的：前端只发本对话文件夹底下的坐标，但服务端
      #    必须自己再判一次，否则构造一个 `files:../../u1/别的东西` 就能让页面
      #    去列别人的文件区。这不是理论风险 —— 见上。
      if (!identical(rel, cd) && !startsWith(rel, paste0(cd, "/"))) return()
      art_dir(rel)
    })

    # 退回上一层。在根上时是 no-op（卡片上那会儿也不显示这个按钮）。
    observeEvent(input$art_up, {
      here <- art_here()
      cd <- conv_dir()
      if (is.null(here) || is.null(cd) || identical(here, cd)) return()
      parent <- dirname(here)
      if (!nzchar(parent) || identical(parent, ".") ||
          (!identical(parent, cd) && !startsWith(parent, paste0(cd, "/")))) {
        parent <- cd
      }
      art_dir(parent)
    })

    output$artifacts_card <- renderUI({
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)

      cd <- conv_dir()
      if (is.null(cd) || !nzchar(cd)) return(NULL)
      here <- art_here()
      at_root <- identical(here, cd)
      # 当前层相对**文件夹根**的路径（`results/figures`），用来画面包屑
      rel_in <- if (at_root) "" else substring(here, nchar(cd) + 2L)
      crumbs <- c(cd, if (nzchar(rel_in))
        strsplit(rel_in, "/", fixed = TRUE)[[1]] else character(0))

      # 目录在前、文件按修改时间从新到旧 —— 和「文件」页共用同一个顺序函数。
      # 这里虽然没有"按行号取数据"的操作，但两个页面顺序一致本身就是价值。
      # ★ V15.5 item 10(b)：合并进来的工作区行**必须**一起过这个函数 ——
      #   否则它们会一律垫在文件区那几行后面，用户看到的是"刚产出的排在最
      #   底下"，和这一条要的正好相反。两边的 mtime 是同一个格式
      #   （"%Y-%m-%d %H:%M"），排序函数认得。
      # ★ V16.10：这三步（取 → 空表兜底 → 排序）搬进了 `art_level_df()`，
      #   因为那颗「打包下载」按钮要按**同一个数**说「N 项」。读的还是同一份，
      #   只是不再各写一遍。
      df <- art_level_df()

      # 最多列 8 个，多的引导去文件页 —— 这块在对话流里，铺太长会把
      # 输入框顶出屏幕。文件页有完整列表和批量操作。
      n_show <- min(nrow(df), 8L)

      # ---- 缩略图（★ V15.4 item 2 起穿透子目录）-------------------------
      # 原来只挑**下面列表里出现的那几个**图（`dsapp_thumb_pick(df, ...)`）。
      # 用户报「产出之后这一格没同步」之后查明：刷是刷了，但产物几乎总是
      # 落在模型自己建的**子文件夹**里（`<对话>/<项目名>/data/figures/*.png`），
      # 而 `df` 只是当前这一层 —— 于是那一格从头到尾只有一行文件夹，
      # 一张图都不出来。现在图改成从**当前这一层往下递归**取，列表不变。
      # 详见 R/files.R 的 dsapp_art_tree_images。
      #
      # ⚠️ 取法不能是"`files:` + name"：tdf 的 name 在重名时已经是相对路径，
      #    不重名时又只有 basename —— 直接拼的话 `results/volcano.png` 会变成
      #    `files:volcano.png`，指向**另一个文件**，而且不报错。
      #    仍然用 match 回 rel 这一步：name 是给人看的（可能退化成路径），
      #    坐标只认 rel 那一列（★ V15.5 item 10(b) 起是 coord 那一列，它由
      #    art_thumbs() 按各自那一支的根拼好 —— 文件区带前缀、工作区不带）。
      tdf <- art_thumbs()
      imgs <- tdf$name
      too_big <- dsapp_thumb_too_big(tdf)
      img_refs <- tdf$coord[match(imgs, tdf$name)]

      card(class = "dsapp-artifacts",
        card_header(
          class = "d-flex justify-content-between align-items-center",
          # 标题 = 文件夹名（进到子目录之后显示完整面包屑）。
          # ⚠️ text-truncate 要挂在一个**块级**元素上才生效（它是
          #    overflow:hidden + 省略号那一套），span 是行内的，挂上去
          #    没有任何效果，长文件夹名会把右边那个"管理 →"顶出去。
          div(class = "text-truncate",
              icon("folder-open"), " ",
              if (at_root) cd else paste(crumbs, collapse = " / ")),
          # 跳转走服务端的 bslib::nav_select()，不写 JS —— bslib 客户端
          # 有没有暴露 nav_select 是实现细节，写死了会在升级后静默失效
          # （点了没反应，也不报错）。
          # ★ V15.4 item 2：这颗刷新按钮是用户点名要的（原话：「并且也给
          #   用户一个手动刷新的按钮」）。自动刷新那条路（3 秒轮询 + 任务
          #   收尾信号）本来就有，但有两件事它管不着：刚在**另一个标签页**
          #   里跑完的任务、以及"我就是要现在看一眼"这个动作本身 —— 让用户
          #   为一个只读操作等三秒，他只会认为它坏了。
          #
          # ⚠️ 写法**照抄** R/mod_files.R 里工作区卡片头上那颗（V9 item 3），
          #    不是抄个大概：
          #    · 裸 `tags$button` + 手写 onclick，不走 actionLink/actionButton
          #      —— 那两样会走 Shiny 的 input 绑定，而这里要的是**每次都派发**
          #      （见下一条）；
          #    · `Math.random()` 当值。Shiny 的输入绑定**值没变就不派发**，
          #      固定传 1 的话第二次点击服务端收不到 —— 界面上的表现是
          #      "点第一下有用，之后再点就没反应了"，而且不报错；
          #    · priority:'event' 让它在同一个 tick 里立即发出，不排队。
          span(class = "flex-shrink-0 d-flex align-items-center gap-2",
               tags$button(
                 class = "btn btn-sm btn-outline-secondary py-0 px-2",
                 type = "button",
                 title = "重新读取本对话的产物",
                 onclick = sprintf(
                   "Shiny.setInputValue(%s, Math.random(), {priority:'event'});",
                   dsapp_js_str(ns("art_refresh_btn"))),
                 icon("rotate")),
               actionLink(ns("goto_files"), "在「文件」页管理 →", class = "small"))
        ),
        card_body(class = "p-2",
          # 退到上一层。只在子目录里出现 —— 在根上是没有意义的
          #（"返回"到哪去？），多一个永远灰着或者点了没反应的控件不如没有。
          if (!at_root) {
            div(class = "mb-1",
                actionLink(ns("art_up"),
                           tagList(icon("arrow-left"), " 返回上一层"),
                           class = "small"))
          },
          div(class = "small text-muted mb-2",
            "这里只有", tags$b("本对话"), "的产出，别的对话的不会混进来，",
            "别人也看不到。任务跑完会自动同步到这里。"),
          # ★ V16.10：整层一键打包。放在这一句说明的**后面** —— 它是对
          #   "这里有什么"的补充，不是卡片标题的一部分。
          #   ⚠️ 不塞进 card_header：那边已经有标题 + 刷新 + 「在「文件」页
          #      管理 →」，再塞一颗会被挤掉的是标题（`card_header` 那段注释
          #      就是为这件事写的）。
          #   列表为空时 `renderUI` 给 NULL，整行不占位。
          uiOutput(ns("art_zip_ui")),
          if (length(imgs)) {
            div(class = "dsapp-thumbs",
              lapply(seq_along(imgs), function(i) {
                div(class = "dsapp-thumb",
                  # ★ 图片本身可点开预览（V9 item 4）。用户的原话是
                  #   「言出法随页面生成的图片需要能点击预览」。
                  #
                  # ⚠️ onclick 挂在**外层的 div** 上，不挂在 <img> 上：
                  #    renderImage 吐出来的 <img> 是 Shiny 每次重渲时新建的，
                  #    挂它身上的处理器会随着重渲一起丢（而丢的时候不报错，
                  #    表现是"图看得见，点了没反应"）。外层 div 是静态结构，
                  #    点击从 img 冒泡上来照样命中。
                  #
                  # ⚠️ 走的是和下面文件名同一个 input（art_preview_want），
                  #    不另开一条。这样"点图"和"点名字"落到同一个预览弹窗，
                  #    弹窗里那个下载按钮的 art_pick 也早就设好了。
                  div(class = "dsapp-thumb-img",
                      title = sprintf("点击放大预览 %s", imgs[[i]]),
                      # 键盘可达（Tab 停得住、回车/空格能触发）。
                      # div + onclick 默认是鼠标专属的，补上这两个属性之后
                      # 屏幕阅读器也会把它念成"按钮"。
                      tabindex = "0", role = "button",
                      `aria-label` = sprintf("预览 %s", imgs[[i]]),
                      onclick = dsapp_fire(ns("art_preview_want"), img_refs[[i]]),
                      onkeydown = sprintf(
                        "if (event.key === 'Enter' || event.key === ' ') { %s event.preventDefault(); }",
                        dsapp_fire(ns("art_preview_want"), img_refs[[i]])),
                      imageOutput(ns(paste0("art_thumb", i)), height = "auto")),
                  # 缩略图下面的名字可点，省掉"看图 → 去下面列表里找同名那行"
                  # 这一步。点开的是**预览**（V7 item 2），图本身已经在这里
                  # 看过了，用户点名字多半是想放大看细节或确认文件信息。
                  tags$a(class = "dsapp-thumb-cap text-truncate dsapp-file-link",
                         href = "#", title = sprintf("点击预览 %s", imgs[[i]]),
                         onclick = sprintf(
                           "Shiny.setInputValue(%s, %s, {priority:'event'}); return false;",
                           js_str(ns("art_preview_want")), js_str(img_refs[[i]])),
                         imgs[[i]]))
              }))
          },
          # 图太大不给缩略图这件事要说出来。不说的话用户看到"文件在、图没出来"，
          # 第一反应是"是不是没画成"。
          if (length(too_big)) {
            div(class = "small text-muted mb-2",
                sprintf("另有 %d 张图超过 %s，不在这里预览：%s",
                        length(too_big), dsapp_fmt_bytes(DSAPP_THUMB_MAX_BYTES),
                        paste(utils::head(too_big, 3), collapse = "、")))
          },
          lapply(seq_len(n_show), function(i) {
            nm   <- df$name[i]
            is_d <- isTRUE(df$is_dir[i])
            # 发给前端的**不是名字，是坐标**。
            # ⚠️ 必须由这里写死：卡片读的是文件区，而正文里那些自动链接的文件名
            #    读的是工作区，两边根不同。见 files.R 的 dsapp_art_path —— 解析
            #    那一侧只做白名单式分派、不猜。
            # ★ V15.5 item 10(b)：坐标在这一行是**逐行**的 —— 文件区那些行是
            #    `files:` 前缀，工作区里还没同步过来的那几行是不带前缀的工作区
            #    坐标。统一按 `files:` 拼的话，后者会被解析到文件区里一个不存在
            #    的位置：点预览什么都不出现、点下载报的还是一句和下载无关的错。
            ref  <- df$coord[i]
            div(class = "d-flex align-items-center gap-2 py-1 border-bottom",
              # ★ V16.10：图标名 / 徽标文案 / 目录体积都取 `art_level_df()`
              #   过完 `dsapp_files_rows()` 之后的字段，不再在这里写死一份
              #   （「文件」页那张表读的是同一个规则）。
              icon(df$icon[i], class = "text-muted"),
              div(class = "flex-grow-1 text-truncate",
                # 名字是**预览**入口，右边那个下载图标才是直接下载
                # （V7 item 2，用户的原话：「点击文件名，可以先跳转预览，
                # 再有下载按钮决定要不要下载」）。
                #
                # ★ V13.11 item 1：目录的名字点下去**原地进这一层**，不再往
                #   「文件」页跳（用户原话：「点击文件夹应该直接在本对话文件中
                #   进入，而不是跳转文件页面」）。空文件夹尤其需要 —— 它就是
                #   用户来这一趟要找的东西，跳到另一个页面反而把上下文丢了。
                tags$a(class = "small dsapp-file-link", href = "#",
                       title = if (is_d) sprintf("打开文件夹 %s", nm)
                               else sprintf("点击预览 %s", nm),
                       onclick = sprintf(
                         "Shiny.setInputValue(%s, %s, {priority:'event'}); return false;",
                         js_str(ns(if (is_d) "art_open" else "art_preview_want")),
                         js_str(ref)),
                       nm),
                # ★ V16.10：目录的体积那一格写 `—`（原来是**留空**）。两个
                #   页面上这是同一件事的两种写法，而"留空"在行里看着像"这一格
                #   没数据"，用户分不出"目录没有大小"和"大小没算出来"。写法由
                #   `dsapp_files_rows()`/`dsapp_files_list()` 一处说了算
                #   （`size_h` 对目录就是 `—`，文件页那张表一直这么显示）。
                span(class = "text-muted small ms-2", df$size_h[i]),
                if (is_d) {
                  span(class = "badge text-bg-secondary ms-2", df$mark[i])
                }
              ),
              if (is_d) {
                tags$button(
                  class = "btn btn-sm btn-outline-secondary py-0",
                  title = "进入这个文件夹",
                  onclick = sprintf(
                    "Shiny.setInputValue(%s, %s, {priority:'event'}); return false;",
                    js_str(ns("art_open")), js_str(ref)),
                  icon("arrow-right"))
              } else {
                tags$button(
                  class = "btn btn-sm btn-outline-secondary py-0",
                  title = "下载到本地",
                  onclick = sprintf(
                    "Shiny.setInputValue(%s, %s, {priority:'event'}); return false;",
                    js_str(ns("art_want")), js_str(ref)),
                  icon("download"))
              }
            )
          }),
          if (nrow(df) > n_show) {
            # ⚠️ 「在「文件」页看全部」这半句**必须是链接**（V7 item 1）。
            #    原来它是一句纯文本 —— 而文案本身在指路，用户就会去点它，
            #    点不动（2026-09-14 用户报的"无法正常跳转"就是这一条：
            #    页面上唯一能跳的是右上角那个"管理 →"，这句反而最像入口）。
            #    两处跳转共用同一个 goto_files 处理器，不另开一条路径。
            # ⚠️ 这里的 input id **不能**跟右上角那个共用（ns("goto_files")）。
            #    actionLink 每次点击是把自己的 data-val 加一，而两个 <a>
            #    各记各的计数器、都从 0 起步 —— 于是第二个链接的第一次点击
            #    发出的值（1）和第一个链接已经发过的值**一模一样**，
            #    Shiny 判定"输入没变"就不派发，observeEvent 不触发。
            #    症状和用户报的那条一模一样：点了没反应，控制台一声不吭。
            #    （2026-09-15 实测：先点"看全部"再点"管理 →"，后者失效，
            #    反过来也一样。两个入口必须各自有 id，再汇到同一个处理器。）
            div(class = "small text-muted mt-2",
                sprintf("……还有 %d 个，", nrow(df) - n_show),
                actionLink(ns("goto_files_all"),
                           sprintf("在「文件」页看全部 %d 个 →", nrow(df)), class = "small"))
          },
          # 两个隐藏的下载出口并排挂着：`art_dl_link` 是"某一行"的，
          # `art_zip_link` 是"这一层"的（★ V16.10）。两个都必须**在 DOM 里**
          # —— `dsapp:clickWhenReady` 走的是 `getElementById(...).click()`，
          # 元素不存在时那条自定义消息静默地什么都不做（约 4 秒后放弃）。
          div(class = "mt-1", uiOutput(ns("art_dl_link"))),
          div(class = "mt-1", uiOutput(ns("art_zip_link")))
        )
      )
    })

    output$streaming <- renderUI({
      if (is.null(rv$session_id)) return(NULL)

      if (!is.null(rv$error)) {
        # ★ V15.3 item 2：厂商说"你这个参数超了"的时候，就地给一颗按钮。
        #
        # 用户原话：「运行时关于模型设置的问题报错『HTTP 400：Field
        # 'max_tokens' must be at most 65536』能不能直接亮一个按钮『直接帮我
        # 设置』，然后用户点击后就可以自动更改并应用新的模型服务配置」。
        #
        # ⚠️ 判据是 dsapp_maxtok_advice()，它**只认"明确说了上限"的写法**，
        #    认不出来就返回 NULL（宁可不给按钮，也不给一个错的）。特别是
        #    "maximum context length is N tokens" 那一类必须排除 —— 那是总
        #    上下文，调小 max_tokens 治不了它，给按钮就是骗人。
        adv <- tryCatch(dsapp_maxtok_advice(rv$error), error = function(e) NULL)
        return(div(class = "dsapp-msg dsapp-msg-assistant",
          div(class = "dsapp-bubble dsapp-bubble-err",
              icon("triangle-exclamation"), " ", rv$error,
              if (!is.null(adv)) div(class = "dsapp-fix-row",
                actionButton(ns("maxtok_fix"), "直接帮我设置",
                             class = "dsapp-btn dsapp-btn-run",
                             icon = icon("wand-magic-sparkles")),
                tags$span(class = "dsapp-fix-note",
                  sprintf("把这个模型的单次回复上限改成 %s，改完这个模型以后都按它来",
                          format(adv$max, big.mark = ",", scientific = FALSE))))),
              # ★★ V15.4 item 4：报错之后，用户最想做的那件事就是"把刚才那句
              #   话再发一次"。这里给的还是**填回输入框**，不是自动重发 ——
              #   ⚠️ 尤其不能自动重发：这一类报错有一半是"这次请求的参数不对"，
              #      原样再打一次大概率还是同一个错，而用户会白等一轮、
              #      也白花一次调用。填回去他至少能顺手把模型/参数调一下。
              #   原文来自 rv$last_user（发送时存的那一份，见它的说明）。
              if (nzchar(rv$last_user))
                div(class = "dsapp-fix-row",
                    dsapp_resend_btn(ns("prefill_input"), rv$last_user,
                                     title = "把刚才那一句填回输入框，改完再发"))))
      }

      txt <- draft()
      # ★★ V15.4 item 3：这里原来有一整支"正文还没开始"的占位气泡
      #   （`.dsapp-wait` 那行字 + 一个 `.dsapp-cursor`）。它整支搬去了
      #   output$wait_box —— **别再搬回来**。这一格依赖 draft()，正文吐字
      #   期间每 200ms 重画一次；占位气泡长在这里，那颗 spinner 就每 200ms
      #   被拆掉重建一次（CSS 动画随元素重建归零），用户看到的正是
      #   「思考的时候还是在闪屏」。搬出去之后，本格只在**有正文**时才出东西。
      if (!nzchar(txt)) return(NULL)

      # ★★ V15.11：这一拍只发**尾巴**。理由和数字见 DSAPP_STREAM_BUDGET_B
      #   那一段（整条重发 = 长度的平方，实测 7 KB 的回复要发 344 KB）。
      #   以前这里直接 dsapp_render_message(txt, ...) —— 现在按"这一拍最多
      #   发多少字节 HTML"往下试：正文短于窗口就整条发（**和以前一模一样**），
      #   超了就砍到只剩尾巴，并在上面写一行"前文没显示"。
      #   ⚠️ 砍的只是**发出去的这一份**：draft() 一字未动，落库 / 导出 /
      #      上下文 / 以及回复结束后 output$history 的完整渲染都不受影响。
      #   ⚠️ 判据是**渲染出来的字节**，不是字符数 —— 同样 1000 字，一张表
      #      和一个段落渲染出来差好几倍，所以缩窗口这件事必须看实测值。
      draw <- function(s) dsapp_render_message(
        s, "stream", executable = FALSE,
        file_names = isolate(art_names()),
        # 流式正文里的文件名同样先预览
        file_input = ns("art_preview_want"),
        file_title = "点击预览 %s",
        # ★ V15.3 item 6：正在往外吐的正文里出现
        # `![](figures/x.png)` 时也要能显示 —— 否则用户看着一段裂图流过去，
        # 等落库重渲染才出现，中间那几秒像是坏的。
        img_session = session, img_sid = rv$session_id,
        img_cfg = cfg())
      win  <- dsapp_stream_tail(txt, DSAPP_STREAM_WIN_MAX)
      body <- draw(win$text)
      for (i in 1:2) {                 # 最多再缩两次，到下限就认了
        b <- if (is.null(body)) 0L else nchar(as.character(body), type = "bytes")
        if (!isTRUE(win$cut) || length(b) != 1L || is.na(b) ||
            b <= DSAPP_STREAM_BUDGET_B) break
        win  <- dsapp_stream_tail(
          txt,
          max(DSAPP_STREAM_WIN_MIN,
              floor(win$chars * DSAPP_STREAM_BUDGET_B / max(b, 1L) * 0.85)))
        body <- draw(win$text)
      }
      hidden <- nchar(txt) - win$chars

      div(class = "dsapp-msg dsapp-msg-assistant",
        div(class = "dsapp-bubble",
          # 切过窗口就明说一句 —— 不然用户会以为这一轮回复就这么短。
          if (isTRUE(win$cut) && hidden > 0)
            div(class = "dsapp-stream-cut",
                sprintf("…… 前文 %s 字没显示（本轮结束后可看完整回复）",
                        format(hidden, big.mark = ","))),
          body,
          # ★★ V15.4 item 3：这颗光标**不再闪**了（www/app.css 里那条
          #   `animation: dsapp-blink` 已删）。它现在是一个实心方块，语义是
          #   "正文还在往外走"。用户原话：「要求去掉闪屏动画」。
          #   ⚠️ 它同时是 www/app.js 那个进度条的"忙"判据之一，删 class 名
          #      之前先去看那边（搜 dsapp-cursor）。
          if (isTRUE(rv$streaming)) tags$span(class = "dsapp-cursor")))
    })

    # ★ V15.3 item 2：「直接帮我设置」点下去干什么。
    #
    # 用户的原话是「用户点击后就可以自动更改并应用新的模型服务配置」——
    # 所以这里要做三件事，缺一不可：
    #   ① 把学到的上限**写进库**（model_param_limits）—— 不然下次开新会话
    #      又是同一个 400，用户会以为按钮没生效；
    #   ② 让**当前这个进程**当场吃到它（dsapp_param_learn 内部会做）；
    #   ③ （V15.5 item 6 起**不再需要**了。）原来还要把界面上那个 max_tokens
    #      真的改掉；现在界面上那一格是「单次使用上限」，和这里学到的东西
    #      不是同一个量，改它反而会把上下文窗口砍小。见 mod_model.R 里那段。
    # ⚠️ **不**自动重发那条失败的请求。用户说的是"更改并应用配置"，不是
    #    "重试"。悄悄替他花掉一次调用，而且失败原因还可能变，不如让他自己
    #    再发一次 —— 那也是"配置到底生效了没有"最直接的验证。
    observeEvent(input$maxtok_fix, {
      adv <- tryCatch(dsapp_maxtok_advice(rv$error), error = function(e) NULL)
      if (is.null(adv)) {
        return(showNotification(
          "这条报错里没有可以直接套用的上限，请到「模型设置」页手动调整。",
          type = "warning", duration = 8))
      }

      # ⚠️ 再算一次：按钮是**上一拍**画出来的，这中间用户可能已经在「模型
      #    设置」页手动改过、或者另一个会话已经学会了同一个上限。
      #    拿旧数字去写库会把用户自己的改动覆盖掉。
      rng <- tryCatch(dsapp_param_range(state$vendor, state$model, adv$param),
                      error = function(e) NULL)
      adv <- tryCatch(dsapp_maxtok_advice(rv$error, range = rng),
                      error = function(e) NULL) %||% adv

      r <- tryCatch(dsapp_param_learn(
        state$vendor, state$model, adv$param,
        max_value = adv$max,
        source = "provider_400",
        # ⚠️ 只留 200 字符（函数内部还会再截一次）。整段报错原文可能很长，
        #    而这一列是给人看的"这条上限是哪来的"。
        note = substr(gsub("[\r\n\t]+", " ", rv$error %||% ""), 1L, 200L),
        con = dsapp_db(cfg())), error = function(e) e)

      if (!isTRUE(r)) {
        return(showNotification(dsapp_err_user(r, "记住这个上限"), type = "error",
                                duration = 10))
      }

      # ★ V15.5 item 6：这里原来还会推一把 state$maxtok_force，让模型页把
      #   用户那一格 max_tokens **改掉**。现在不改了 —— 那一格是「单次使用
      #   上限」（一次请求合计多少 token），而这里学到的是**回复那一侧**的
      #   上限，把它写进"单次使用上限"等于把上下文窗口砍到 8192。
      #   学到的东西由上面那次 dsapp_param_learn() 生效，它会在
      #   dsapp_ctx_plan() 里夹住推导出来的 max_tokens。
      #   见 R/mod_model.R 里那段说明（搜 maxtok_force）。

      # 错误气泡收起来 —— 它要说的话已经由下面这句通知接上了。
      rv$error <- NULL
      showNotification(
        sprintf(paste0("已记下「%s」的回复上限是 %s，这个模型以后都按它来",
                       "（写进模型配置，重启也还在）。",
                       "「单次使用上限」不用动 —— 回复长度是从它里面自动分的。",
                       "可以重新发送刚才那句话了。"),
                state$model %||% "当前模型",
                format(adv$max, big.mark = ",", scientific = FALSE)),
        type = "message", duration = 12)
    })

    # ★ V13.8 item 5：这一格就是用户说的「显示 token 那个框」，也是**整页
    #   唯一**随生成刷新的地方。
    #
    # ⚠️ 为什么是它：这里本来就写着模型 / 温度 / 用量，是用户想看"这一轮花了
    #    多少"时眼睛会落的地方。原来运行中的进度（转圈、秒数、字符数）分散在
    #    另外两处（输出框下面那条状态条、消息流的气泡），三处刷新节奏还不一样，
    #    整页看起来一直在抖。现在全部收进这一格 —— 其余地方**一次都不重画**。
    #
    # ⚠️ 收进来的代价是这一格会比较长，所以它是 `inline = TRUE` 的 span、排在
    #    输入框左下角，长了也只会往右延伸，不会把输入框顶高。
    #
    # ★★ V13.12 item 20：「已输出 N 字符」的唤醒源。
    #
    # ⚠️ 这一格必须**有一个**内容指纹，不能什么都不挂：出口那几个数字
    #    （st$acc / st$reason 的长度）在 st 这个 new.env() 里，读它们**建不了
    #    依赖**。原来靠 `rv$tick` 每 200ms 强推，那正是"白刷"的来源；指纹
    #    换成"字符数真的变了才推"，重画次数掉下来，走字照旧。
    #    写入点在下面流式轮询那个 observe 里（搜 stream_sig 就能找到）。
    stream_sig <- reactiveVal("")

    # ★★ V15.3 item 3：思考过程那一格的**粗粒度**重画开关。
    #
    # 每发起一轮 +1（写入点只有一处：dsapp_llm_begin）。它和 stream_sig 的
    # 区别是刻意的：stream_sig 是"内容指纹"（每个字都可能让它变），这一格要
    # 的是"**新的一轮**"—— 正文靠 app.js 往 DOM 里追加，根本不经过服务端。
    # ⚠️ 别把它改成"思维链变长了就 +1"：那等于把每 200ms 重画一次换个写法
    #    写回来，用户说的"闪"就是它。
    think_gen <- reactiveVal(0L)

    # ---- 对话途中换模型（V15.8 item 3）--------------------------------------
    #
    # 这一格的问题是"能不能在对话途中换模型、换了还继不继承上下文"。
    # **继承**这一半本来就成立，而且不是"碰巧"：上下文根本不在内存里的会话
    # 对象上，它在 messages 表里，每一轮都由 dsapp_scene_messages() 重新拼
    # （见 R/llm.R 那条路）。换模型只是换了出网请求里的一个字段，动不到历史。
    # 浏览器探针实测 20/20（tests/ui_v158/probe_ctx.py）：在「模型服务」页换完
    # 模型之后**没刷新、没重开对话**，下一轮出网用的就是新模型，messages 里
    # 也带着上一轮的暗号。
    #
    # 所以缺的是**入口**，不是机制。原来这一页只在 output$hint 里"显示"当前
    # 模型，想换得离开对话、跑一趟「模型服务」、回来 —— 而离开那一页还会弹
    # 一次「还有改动没确认」。用户要的"对话途中切换"就是别为改一个下拉跑一趟。
    #
    # ⚠️⚠️ 这一格**绝不自己写库**。全应用写模型只有 mod_model.R 那一处
    #     （迁移旧名、按新模型重新夹取温度/上下文、800ms 防抖落库、同步
    #     user_api_keys 里那份副本）。再写一遍就是第二个写入者，两套规则迟早
    #     对不上，症状是"界面显示的模型和真正出网的模型不是一个"
    #     （V15.7 item 8 就是栽在这个形状上）。这里只发请求，执行在那边。
    output$model_slot <- renderUI({
      v <- state$vendor          # 依赖：**只**认厂商（换厂商才重建这一格）
      mg <- tryCatch(dsapp_vendor_model_groups(v), error = function(e) list())
      cur <- isolate(state$model) %||% ""
      mflat <- tryCatch(dsapp_model_groups_flat(mg),
                        error = function(e) character(0))
      # 存过的名字不在清单里（厂商新上的、或者用户手打的）：单独开一组把它
      # 摆出来。不这么做控件会显示空白，用户以为自己没设过模型
      # —— mod_model_ui 里同一条规矩。
      if (nzchar(cur) && !cur %in% mflat) mg <- c(list("当前使用" = cur), mg)
      selectizeInput(ns("model_pick"), NULL, choices = mg,
                     selected = if (nzchar(cur)) cur else NULL,
                     width = "190px")
    })

    # 别处把模型改了（模型服务页里改的、或者启动时从库里读的）→ 这一格跟着显示。
    # ⚠️ 判等之后才 update：updateSelectizeInput 会让浏览器把值报回来，
    #    不判等就是 chat → state → chat 的自激环。
    observeEvent(state$model, {
      m <- state$model %||% ""
      if (!nzchar(m)) return()
      if (identical(isolate(input$model_pick) %||% "", m)) return()
      updateSelectizeInput(session, "model_pick", selected = m)
    }, ignoreNULL = TRUE)

    # 用户在这一格里选了模型 → 只把请求写进 state，执行交给 mod_model.R。
    # ⚠️ `n` 是给 observeEvent 用的：用户连着两次选同一个名字时，值不变、
    #    reactiveVal 也就不会失效 —— 但那种情况本来也无事可做，所以这里
    #    判等直接返回，不靠 n 去硬触发。留着它是为了日志/排查时能看出
    #    "一共请求过几次"。
    observeEvent(input$model_pick, {
      m <- input$model_pick %||% ""
      if (!nzchar(m)) return()
      if (identical(isolate(state$model) %||% "", m)) return()
      rq <- isolate(state$model_req)
      state$model_req <- list(model = m, n = (rq$n %||% 0L) + 1L)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    output$hint <- renderUI({
      stream_sig()   # 依赖：输出的字符数/思考的字符数变了就重画这一格
      # ★★ V13.12 item 20：这里原来有一行 `if (rv$streaming) rv$tick` ——
      #    它的唯一作用是**每 200ms 强制重画这一格**，好让下面那个「已用 N 秒」
      #    走字。用户原话：「分析进行时页面还是会刷新，取消这个机制，实时更新
      #    蹦出新结果就好」。实测跑一轮：这一格被重画 145 次，其中 95 次画出来
      #    的 HTML **一个字都没变**（66%）。那 95 次不带任何新信息，只把 DOM
      #    换一遍。
      #
      #    去掉之后，这一格的重画**全部**由真内容驱动：字符数变了、状态变了、
      #    用量回来了才重画。秒数由 app.js 那条前端定时器读 data-secs 自己走，
      #    不花任何服务端往返。
      # ⚠️★ V15.5 item 8：这一支和下面那一支里的 `spinner-border` 都**删掉了**，
      #    改由输入框旁边那颗**静态**的 .dsapp-hint-spin 转（见 mod_chat_ui 里
      #    的说明）。别再往这一格加带动画的节点 —— 这一格是 5Hz 重画的，
      #    加什么动画都会变成"一秒抖一下"。
      # ★★ V15.5 item 6：上下文读条。
      #
      #   用户原话：「你的单次回复上限是指模型的上下文长度吗？如果是：需要
      #   按照模型的能力自适应更改上下文长度的读条」。
      #
      #   画的是 rv$ctx —— dsapp_llm_begin() 里按**这一次真正要发出去的
      #   messages** 算出来的（见 models.R 的 dsapp_ctx_plan）。分母是这一次
      #   请求的可用总量：用户填的单次使用上限，或者他没填时的**模型窗口**
      #   （deepseek 是 1M，查不到出处的厂商退回 128K）。
      #
      #   ⚠️ 只在**拿到过 plan** 之后才画。没发过请求时 rv$ctx 是 NULL，
      #      那时候分母只能靠猜，而一个猜出来的百分比比不画更糟。
      # ★★ V15.6 item 7：单次 token 使用读条，排在上下文那条**前面**。
      #
      #   用户原话：「单次上下文进度条前面应该再加一个单次token使用进度条」。
      #
      #   两条的分母是同一个（单次使用上限），分子不同：
      #     · 这条 = used + out，也就是**这一次请求最多会用掉多少** ——
      #       `out` 是给回复留的额度，models.R 的 dsapp_ctx_plan() 算出来的
      #       （保证 used + out ≤ limit）；
      #     · 上下文那条 = used，即要发出去的 messages 占了多少。
      #   摆在一起正好把 item 8 那两件事讲清楚：用户在「模型服务」页看到的
      #   「单次使用上限」是**两半**共用的一个分母，回复额度不是单独设的。
      #
      #   ⚠️ 分子用的是**估算 + 预留**，不是厂商回执里的真实用量 —— 那个数
      #      只在流式协议最后一拍才有（见下面那段的说明），拿它当分子的话，
      #      生成期间这条会一直停在上一轮，用户会以为自己看错了。
      #   ⚠️ 类名是 dsapp-tokbar 不是 dsapp-ctxbar，理由见 app.css 那一段
      #      （探针取的是 .dsapp-ctxbar 的第一个匹配）。
      tok_line <- local({
        p <- rv$ctx
        if (is.null(p) || !is.finite(p$limit %||% NA_real_)) return(NULL)
        tot <- as.numeric(p$used %||% 0) + as.numeric(p$out %||% 0)
        if (!is.finite(tot) || tot < 0) return(NULL)
        tpct <- if (is.finite(p$limit) && p$limit > 0)
          min(100L, as.integer(round(100 * tot / p$limit))) else 0L
        tags$span(
          class = paste("dsapp-ctx", if (tpct >= 85L) "is-full"),
          title = paste0(
            "这是**这一次请求**最多会用掉多少 token，不是累计值。\n",
            "分母 = 单次使用上限：你在「模型服务」页填的那个数；",
            "留空（跟随模型）时就是这个模型自己的上下文窗口。\n",
            "分子 = 上下文 + 回复额度。上下文是本次要发出去的 messages",
            "（系统提示、工作区文件清单、技能正文、对话历史）的估算；",
            "回复额度是平台按剩余空间留出来的那一块，",
            "保证两者加起来不超过分母。\n",
            "⚠️ 两部分都是按字符估算的（中文约 1 字 1 token，英文约 4 字符",
            " 1 token），写成 ≈ 是因为它不是分词器的精确值。"),
          "单次 ≈", dsapp_fmt_tokens_short(tot),
          " / ", dsapp_fmt_tokens_short(p$limit),
          sprintf("（%d%%）", tpct),
          tags$span(class = "dsapp-tokbar",
                    tags$i(style = sprintf("width:%d%%", max(1L, tpct)))))
      })
      ctx_line <- local({
        p <- rv$ctx
        if (is.null(p) || !is.finite(p$limit %||% NA_real_)) return(NULL)
        tags$span(
          # `is-full` 让 CSS 把读条换成红色（.dsapp-ctx.is-full，见 app.css）。
          # 85% 这条线是"该收拾一下这个对话了"的意思，不是"马上会炸"。
          class = paste("dsapp-ctx", if (p$pct >= 85L) "is-full"),
          title = paste0(
            "这是**这一次请求**的上下文占用估算，不是累计值。\n",
            "分母 = 单次使用上限：你在「模型服务」页填的那个数；",
            "留空（跟随模型）时就是这个模型自己的上下文窗口。\n",
            "分子 = 本次要发出去的 messages 估算 token 数，",
            "含系统提示、工作区文件清单、技能正文和对话历史。\n",
            "⚠️ 是按字符估算的（中文约 1 字 1 token，英文约 4 字符 1 token），",
            "写成 ≈ 是因为它不是分词器的精确值。"),
          "上下文 ≈", dsapp_fmt_tokens_short(p$used),
          " / ", dsapp_fmt_tokens_short(p$limit),
          sprintf("（%d%%）", p$pct),
          # 读条本身。宽度就是 pct，CSS 在 app.css 里（.dsapp-ctxbar）。
          tags$span(class = "dsapp-ctxbar",
                    tags$i(style = sprintf("width:%d%%", max(1L, p$pct)))))
      })
      # ⚠️ 两条读条**一起**出现、一起消失：它们读的是同一个 rv$ctx，
      #    分开返回的话，会有一帧只有其中一条（看起来像另一条闪了一下）。
      ctx_line <- if (is.null(tok_line)) ctx_line else
        tagList(tok_line, tags$span(class = "text-muted", " · "), ctx_line)
      ctx_sep <- function(x) if (is.null(x)) NULL else
        tagList(tags$span(class = "text-muted", " · "), x)

      if (isTRUE(rv$sending)) {
        return(tags$span(class = "text-primary", "正在提交…"))
      }
      if (isTRUE(rv$streaming)) {
        # 运行中要说清楚"现在在干嘛"和"已经产出多少"，否则用户面对一个
        # 不动的界面只能靠猜 —— 上一版就是因为没有任何提示，看起来像卡死。
        #
        # ⚠️ 这里数的是**字符**（nchar），不是 token。2026-09-14 用户问过
        #    「这个『字』是不是 token 的意思」—— 不是。写「字」会让人以为是
        #    token（中文里"字"和 token 经常被混着说），所以一律写成「字符」，
        #    并且把这件事挂在 title 上讲明（原来那段说明在状态条里，状态条
        #    删掉之后搬来这里）。真要显示 token 只能等生成结束（流式协议只在
        #    最后一拍给 usage），中途显示的任何 token 数都是编的。
        secs <- if (is.null(st$started)) 0 else
          max(0, as.numeric(difftime(Sys.time(), st$started, units = "secs")))
        n  <- nchar(st$acc %||% "")
        nr <- nchar(st$reason %||% "")
        return(tags$span(
          class = "text-primary",
          title = paste0(
            "正在流式输出，请勿重复发送。上面的秒数和字符数都是**字符**，",
            "不是 token；token 用量等这一轮结束才拿得到",
            "（流式协议只在最后一拍给）。"),
          if (n > 0) sprintf("正在生成…已输出 %s 字符", format(n, big.mark = ","))
          else if (nr > 0) sprintf("模型正在思考…已思考 %s 字符",
                                   format(nr, big.mark = ","))
          else "正在生成…",
          # ⚠️ data-secs 是**服务端画这一格时**的秒数，不是时间戳 —— 前端
          #    拿它当基准自己往下走（理由见 app.js 那段：两边时钟不保证对得上）。
          tags$span(class = "dsapp-elapsed",
                    `data-secs` = sprintf("%.1f", secs),
                    `data-fmt` = "secs",
                    sprintf(" · 已用 %.0f 秒", secs)),
          # ★ V15.5 item 6：生成中也要看得见上下文占了多少。
          # ⚠️ 读的是 rv$ctx（**这一轮开头**算的那一份），不是现算 ——
          #    现算要把整份 messages 重新拼一遍，而这一格是 5Hz 重画的。
          ctx_sep(ctx_line)))
      }
      if (!nzchar(state$api_key %||% "")) {
        # ⚠️ 这里**故意**只看 state，不查库（V13.7 item 3）：
        #    这是个 renderUI，每刷一次就买一次库查询，而它只是个提示条 ——
        #    真正的闸门在上面那个按钮的 handler 里，那儿查得又准又只查一次。
        #    查漏了的代价只是一行字晚一拍才对，不查的代价是每帧一次 SELECT。
        # ⚠️ 文案里的页面名必须是**真正能填 Key 的那一页**（V13.12 item 19 把
        #    「模型服务」从设置页拆出去之后，这句一度还写着「设置」——
        #    和 V13.15 item 25 是同一个根因，见上面 dsapp_prompt_model 那段）。
        return(tags$span(class = "text-warning",
                         "请先到「模型服务」填写 API Key"))
      }
      # 生成结束后把这一步花了多少 token 摆出来（厂商不给用量就不显示）
      parts <- sprintf("模型 %s", state$model %||% "deepseek-flash")
      # 思考模式下温度本来就不生效，标出来只会让人以为它管用
      parts <- if (isTRUE(state$thinking)) paste0(parts, " · 思考模式")
               else sprintf("%s · 温度 %.1f", parts, state$temperature %||% 0.3)
      if (nzchar(rv$usage %||% "")) {
        parts <- paste0(parts, " · ", rv$usage)
        # 累计数只在有数的时候才提，且明确写"累计" —— 单看一轮的用量
        # 没法回答"这个对话一共花了多少"，而那是真正关心成本的那个问题。
        if (st$tokens > 0) {
          parts <- sprintf("%s（本会话累计 %s）", parts,
                           format(st$tokens, big.mark = ","))
        }
      }
      # ★ V15.5 item 6：空闲时也把**上一次**的上下文占用摆在明面上。
      #   只在生成中显示的话，用户是在"发出去之后"才第一次看到它 ——
      #   那就还是 item 7 那个"下一次发消息才知道"的老毛病。
      tagList(tags$span(parts), ctx_sep(ctx_line))
    })

    # ---- 运行状态条（item 8）→ V13.8 item 5 已删 ---------------------------
    #
    # 这一条（output$run_status）原来把四件事摆到明面上：在干嘛、跑了多久、
    # 产出多少、别重复点。用户的原话是「运行的时候的刷新效果，在显示 token
    # 那个框刷新就可以了」—— 信息留着，位置收进 output$hint（见上面的说明）。
    #
    # ⚠️ 顺带说明一条**没变**的约束（删了状态条也得记着）：不要在任何
    #    renderUI 里判断 rv$sending 来显示"正在提交"。它在 dsapp_chat_send()
    #    里先 TRUE 后 FALSE，两次赋值都发生在同一个 flush 之内，而渲染层是在
    #    flush 结束后才读值的，永远只读到最后那个 FALSE。提交中的反馈只能由
    #    前端自己做（app.js 收到点击就立刻把按钮置灰）。
    #    ⚠️ output$hint 里那一段 rv$sending 分支是**同一个道理的反例**吗？
    #       不是 —— 它同样读不到中间那个 TRUE，所以界面上看不到"正在提交…"。
    #       这一支是 V12 就有的历史写法，这版**没有动它**，免得把"删刷新动效"
    #       这件事和"改提交反馈"搅在一起。真要修是另一件事。
    # ---- 面板宽高（V13.2 item 5）-----------------------------------------
    #
    # ★ 为什么用 renderUI 发一段 <style>，而不是 sendCustomMessage：
    #   模块里拿到的是带命名空间的**子 session**，那是个 proxy，
    #   `sendCustomMessage` 在它身上会**静默失效**（CLAUDE 里那条"点了没
    #   反应、刷新又对了"）。`<style>` 是全局的，跟着渲染走，谁渲染都一样。
    #
    # ⚠️ 依赖 state$uipref_rev：拖完分隔条（或设置页改了数字）之后要让这一段
    #    重发一次。不依赖的话，拖动期间靠 JS 直接改 CSS 变量能看见效果，
    #    但**刷新之后**服务端手里还是老值 —— 表现是"拖了、看着生效了、
    #    一刷新弹回去"。
    #
    # ⚠️ 用共享的 state$uipref_rev 而不是本模块自己的 reactiveVal：尺寸有
    #    两个入口，另一个在设置页（mod_settings），它 bump 不到这里的局部
    #    变量。用局部变量的表现是"设置页填了宽度、回对话页没变化"。
    cur_prefs <- reactive({
      state$uipref_rev
      dsapp_uipref_get(state$user_id, con = dsapp_db(cfg()))
    })
    output$size_vars <- renderUI({
      dsapp_uipref_css(cur_prefs())
    })

    # 分隔条拖完（或键盘调完）报到服务端的那一下。
    #
    # ⚠️ `input$panel_size` 是 app.js 用 Shiny.setInputValue 发的**普通**
    #    input，不是某个控件的值 —— 所以这里没有对应的 UI 控件，
    #    `ignoreNULL`/`ignoreInit` 都要给上：初始化那一下是 NULL，
    #    不 ignore 的话会拿 NULL 去覆盖用户已经存好的尺寸。
    observeEvent(input$panel_size, {
      p <- input$panel_size
      if (is.null(p) || !is.list(p)) return()
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      # 只写这一个键，其余沿用**库里现在的**值 —— 用 cur_prefs() 拼一份
      # 完整的送进去，免得漏掉的那个键被重置成默认值。
      full <- cur_prefs()
      if (!is.null(p$files_w))    full$files_w    <- p$files_w
      if (!is.null(p$composer_h)) full$composer_h <- p$composer_h
      # V13.4 item 6：任务导航栏的宽。**和上面两条走同一个 input**（app.js 的
      # report() 按 id 形状算出 panel_size）—— 三条分隔条是同一件事的三个
      # 实例，"哪一条"体现在消息里的**键**上，不在 input 名上。
      # ⚠️ 漏掉这一行的表现：拖完导航栏松手，宽度弹回去。因为上面 full 里
      #    的 sess_w 还是库里那个旧值，写回去等于什么都没改。
      if (!is.null(p$sess_w))     full$sess_w     <- p$sess_w
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg())), silent = TRUE)
      # 加一把，让设置页那张卡也跟着显示新数字（那边 observeEvent 了它）。
      state$uipref_rev <- state$uipref_rev + 1L
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★ V13.8 item 5：output$run_status 整块删掉了 —— 内容（秒数、思考/正文
    #   字符数、别重复发送的说明）全搬进 output$hint。

    # 侧栏里的一枚小徽章，不是整幅横幅 —— 它现在待在 260px 宽的侧栏里，
    # 原来那句"可到「历史任务」页查看实时输出"放不下，压成两行反而把会话列表
    # 推得更远。措辞保留是因为它确实指了条明路：要看实时输出得去任务页。
    output$running_banner <- renderUI({
      if (!isTRUE(engine$state$running)) return(NULL)
      div(class = "dsapp-run-chip", title = "可到「历史任务」页查看实时输出",
        tags$span(class = "spinner-border spinner-border-sm"),
        sprintf("任务 #%s 执行中", engine$state$task_id))
    })

    # ★★ V16.1 item 6：对话框里那颗"有任务在跑"的浮标（UI 在 mod_chat.R 顶部，
    #    .dsapp-chat-col 的最后一个子节点）。
    #
    #   它和上面那颗侧栏徽章是**同一件事的两个位置**，不是重复：侧栏是常驻的，
    #    但它只有 260px 宽、用户正在读消息时视线根本不在那儿；浮标压在消息区
    #    上沿，是"抬头就看得见"的那一份。
    #
    #   ⚠️ 依赖只有 engine$state$running / task_id（任务起止才变）和
    #      rv$session_id / state$user_id（切对话、切账号才变）。**不要**把
    #      cfg() 之外任何每拍都变的东西读进来 —— 理由见 UI 那段注释。
    output$busy_badge <- renderUI({
      if (!isTRUE(engine$state$running)) return(NULL)
      tid <- tryCatch(engine$state$task_id, error = function(e) NULL)
      sid <- rv$session_id

      # 任务行读不到（被删了 / 库忙 / 刚提交还没落库）不是异常，退成一句通用话即可。
      trow <- if (is.null(tid)) NULL else
        tryCatch(db_tasks_meta(tid, con = dsapp_db(cfg())), error = function(e) NULL)
      has <- !is.null(trow) && nrow(trow) > 0

      # ① 是本对话的 —— 判据必须和 live_run_data 里那条**一字不差**，
      #    两处不一致的话会出现"浮标说在别的对话、卡片就长在眼前"这种自相矛盾。
      here <- has && isTRUE(dsapp_task_in_session(trow, sid))

      # ② 不是本对话的：还要再分"我的另一个对话"和"根本不是我的"。
      #    ⚠️ 这个区分不能省。引擎是**全局单槽**的（app.R 顶部：整个应用一份），
      #       不判的话甲会在这里读到乙正在跑的任务名 —— 而"看得到"这件事本身
      #       就是内容泄露（同一个顾虑见 live_run_data 里那段）。
      #    判据复用对话级的唯一角色判据（db.R 的 dsapp_session_role），
      #    查不到一律按"不是我的"处理：宁可少说，不能多说。
      mine <- here
      if (!mine && has) {
        r <- tryCatch(
          db_session_role_ex(as.character(trow$session_id[1]), state$user_id,
                             is_admin = dsapp_user_is_platform_admin(state$user)),
          error = function(e) list(role = "none"))
        mine <- isTRUE(dsapp_role_can_view(r$role))
      }

      txt <- sprintf("任务 #%s 执行中", tid %||% "—")
      if (mine && !here) {
        # ⚠️ NA 必须先换成空串再问 nchar/nzchar：`nchar(NA)` 是 2（把 "NA"
        #    当字符串量），而 `nzchar(NA)` 默认返回 TRUE —— 不换的话标题是 NA
        #    的那一行会在界面上显示成「任务 #12「NA」在另一个对话里执行中」。
        ttl <- as.character(trow$title[1])
        if (length(ttl) != 1L || is.na(ttl)) ttl <- ""
        if (nchar(ttl) > 18L) ttl <- paste0(substr(ttl, 1L, 18L), "…")
        txt <- if (nzchar(ttl)) {
          sprintf("任务 #%s「%s」在另一个对话里执行中", tid, ttl)
        } else {
          sprintf("任务 #%s 在另一个对话里执行中", tid)
        }
      }

      div(class = "dsapp-busy-badge", role = "status",
        `aria-live` = "polite",
        title = "可到「历史任务」页查看实时输出",
        tags$span(class = "spinner-border spinner-border-sm",
                  `aria-hidden` = "true"),
        tags$span(class = "dsapp-busy-badge-txt", txt))
    })

    # ---- 正在执行的任务：实时输出面板（V9 item 2）--------------------------
    #
    # 「任务系统定位只是一个记录运行日志的地方」—— 用户要的是执行过程出现在
    # 对话里，而不是让他切页。这个面板就干这件事：进度、实时 stdout/stderr、
    # 已经跑了多久、以及一个就在手边的「停止」。
    #
    # ⚠️ 轮询的频率是**分档**的（跑的时候 2 秒、闲着 10 秒），而且轮询本身
    #    不做任何重画 —— 只有内容变了才重画。见下面 live_run_data 那段：
    #    "每 2 秒无条件重画一次"正是 V13.12 item 20 要取消的东西。
    # ---- 「这个对话正在后台继续」横幅（V13.7 item 5）------------------------
    #
    # ★ 为什么要有它：用户关页面时选了「接着往下跑」，人走了，进程还在跑。
    #   他回来（可能是第二天）打开这条对话，界面上**什么都不会说** ——
    #   消息静静多出来几条、任务结果多了一张卡，而他完全不知道那是谁在跑、
    #   也不知道还能不能停。这条横幅就是那句说明，外加一个停的入口。
    #
    # ⚠️ 用轮询而不是"打开时读一次"：横幅要能**自己冒出来**。用户开着页面
    #    不动，另一台设备上关了同一条对话（或者他自己在别的标签页关了），
    #    后台进程起来了 —— 这一刻页面上必须出现提示，否则他又没有停的地方。
    arun_tick <- reactiveVal("")
    observe({
      invalidateLater(5000)
      sid <- rv$session_id
      if (is.null(sid)) return()
      cur <- tryCatch({
        r <- dsapp_arun_get(sid, cfg())
        if (is.null(r)) "" else as.character(r$state %||% "")
      }, error = function(e) "")
      # ⚠️ isolate 那个读：这个 observer 同时读、写 arun_tick()，不隔离的话
      #    每 5 秒自己触发自己一次（reactiveval-self-invalidation）。
      #    这里只是"变了才写"，所以正常情况下每 5 秒一次空转，不重绘。
      if (!identical(cur, isolate(arun_tick()))) arun_tick(cur)
    })

    output$detach_bar <- renderUI({
      arun_tick()   # 依赖：后台续跑的状态变了就重画（不然横幅不会自己消失）
      sid <- rv$session_id
      if (is.null(sid)) return(NULL)
      r <- tryCatch(dsapp_arun_get(sid, cfg()), error = function(e) NULL)
      if (is.null(r) || !identical(as.character(r$state %||% ""), "running")) {
        return(NULL)
      }
      # ★ V15.3 item 4：横幅里的动作按钮走统一的 actions（见 run_actions_ui）。
      #   原来那颗「停止后台运行」已经并进 input$stop 的分派里 —— 逻辑没丢。
      dsapp_detach_banner(r, actions = run_actions_ui("detach"))
    })

    # ★★ V13.12 item 20：这一格原来自己挂着 `invalidateLater(2000)` —— 每 2 秒
    #    无条件把整张实时卡片重画一遍，哪怕日志一个字节都没多。用户原话：
    #    「分析进行时页面还是会刷新，取消这个机制，实时更新蹦出新结果就好」。
    #
    #    对这块卡片来说"刷新"的代价比别人大：它里面是一段**可滚动的日志**，
    #    每 2 秒换一次 DOM 就等于每 2 秒把人往上翻的那一屏弹回底部 —— 用户想
    #    回看前面几行输出，根本看不成。
    #
    #    现在的分工是"**变了才重画**"：
    #      · live_run_data 这个 observer 定时看一眼，把要画的东西（元信息 +
    #        两段日志尾巴 + 开始时刻）算好，**只有真的变了才写**进去；
    #      · renderUI 只依赖它，指纹不变就一次 DOM 都不碰。
    #    耗时那一项**不进指纹**（它每秒都在变，进去就等于又回到每 2 秒重画
    #    一次）—— 秒数由前端自己走，见 dsapp_live_card 里那个 .dsapp-elapsed。
    #
    #    ⚠️ invalidateLater 必须**无条件**排在前面。条件式注册会让这个 observer
    #      再也醒不过来，症状是"任务在跑，卡片却停在启动那一刻"—— 那个坑在
    #      R/agent.R 顶部有完整记录。间隔按"有没有在跑"变：不跑的时候 10 秒
    #      一次空转（比原来"不注册"多一点点开销，换来的是任务一开始就立刻
    #      冒出来，不用等下一个定时器）。
    live_run_data <- reactiveVal(NULL)

    observe({
      run <- isTRUE(engine$state$running)
      invalidateLater(if (run) 2000 else 10000)

      sid <- rv$session_id
      tid <- tryCatch(engine$state$task_id, error = function(e) NULL)

      payload <- NULL
      if (run && !is.null(sid) && !is.null(tid)) {
        trow <- tryCatch(db_tasks_meta(tid, con = dsapp_db(cfg())),
                         error = function(e) NULL)
        # ★★ 归属判断不能省。引擎是**全局单槽**的（app.R 顶部：整个应用一份），
        #    不判的话甲会在这里看到乙正在跑的任务名和实时日志 —— 而且卡片上
        #    那个「停止」按下去掐的是乙的任务。见 utils.R 的 dsapp_task_in_session。
        if (!is.null(trow) && nrow(trow) > 0 &&
            isTRUE(dsapp_task_in_session(trow, sid))) {
          # ⚠️ 路径**不能**读 trow$workdir：那一列是任务**结束时**才写进去的
          #    （app.R 里 e$poll 那次 db_task_status），running 时它是 NA。
          #    同样的坑在 mod_tasks.R 里踩过一次 —— 那里整块实时输出因此从来
          #    没渲染过。工作区路径从 session_id 推（utils.R 的 dsapp_ws_dir）。
          wd <- dsapp_ws_dir(sid, cfg(), create = FALSE)
          ok <- !is.na(wd) && dir.exists(wd)
          payload <- list(
            trow = trow,
            out  = if (ok) dsapp_tail(file.path(wd, ".dsapp_stdout"), n = 60,
                                      max_bytes = 64 * 1024) else "",
            err  = if (ok) dsapp_tail(file.path(wd, ".dsapp_stderr"), n = 15,
                                      max_bytes = 16 * 1024) else "",
            started = as.character(trow$started_at[1] %||% ""))
        }
      }
      # ⚠️ 读的那一侧 isolate()：本 observe 同时读它、写它，裸读就是自己依赖
      #    自己，每轮自己叫醒自己（reactiveval-self-invalidation）。
      if (!identical(payload, isolate(live_run_data()))) live_run_data(payload)

      # ★ V15.3 item 4：把"这一格会不会渲染"这件事单独透出一个**布尔量**。
      #
      # ⚠️ 为什么不能让 action_host() 直接读 live_run_data()：那个值每 2 秒
      #    更新一次**内容**（日志尾巴在长），读它的那一格就每 2 秒重画一次。
      #    action_host() 被 output$history 读着 —— 整条消息流跟着每 2 秒重画
      #    一次，正是 V13.12 item 20 花力气拆掉的东西。
      #    布尔量只在**真的翻了**的时候才写，所以下游只在任务起止时重画。
      lh <- !is.null(payload)
      if (!identical(lh, isolate(live_here()))) live_here(lh)
    })

    output$live_run <- renderUI({
      p <- live_run_data()
      if (is.null(p)) return(NULL)

      # ⚠️ 只有这里读 Sys.time() —— 它没有响应式依赖，所以"时间过去了"这件事
      #    不会让这一格重画。这正是要的效果：秒数归前端走。
      elapsed <- if (nzchar(p$started) && !is.na(p$started)) {
        as.numeric(difftime(Sys.time(), as.POSIXct(p$started, tz = "UTC"),
                            units = "secs"))
      } else NA_real_

      # ★ V15.3 item 4：卡片里的动作按钮走统一的 actions（见 run_actions_ui）。
      #   原来那颗「停止任务」已经并进 input$stop 的分派里 —— 逻辑没丢。
      dsapp_live_card(p$trow, p$out, p$err, elapsed = elapsed,
                      actions = run_actions_ui("live"),
                      tasks_input = ns("goto_tasks"))
    })

    observeEvent(input$goto_tasks, dsapp_goto("tasks"))

    # 「让 AI 分析这个报错」（V9 item 8）：把报错填进输入框，不直接发。
    # 发不发、发了要不要补一句话，交回给用户 —— 直接发的话会替用户花掉
    # 一次 token，而这段报错他可能压根不想原样发出去。
    observeEvent(input$prefill_input, {
      txt <- input$prefill_input %||% ""
      if (!nzchar(txt)) return()
      # ★ V13.7 item 4：框里已经有内容时**追加**，不再整体替换。
      #   原来是无条件 `value = txt` —— 用户正在打字（中文输入法组字到一半
      #   更明显）时点这个按钮，已经敲进去的内容会**无声消失**，而且输入框
      #   是唯一没有草稿的地方，丢了就找不回来。
      #   追加之后"发不发"仍然交回给用户，这条原始设计没有变。
      #   ⚠️ 同一段报错连点两次不重复追加：每次都拼一遍的话，框里会堆出
      #      三份一模一样的报错，用户还得自己删。
      cur <- input$input %||% ""
      if (nzchar(trimws(cur))) {
        if (grepl(txt, cur, fixed = TRUE)) return()   # 已经填过了，不重复
        txt <- paste0(cur, "\n", txt)
      }
      updateTextAreaInput(session, "input", value = txt)
      # ★ V15.4 item 4：这条通道现在有**两个**调用方 —— 执行结果卡片上的
      #   「让 AI 分析这个报错」，和消息气泡上的「重新发送」。文案不能再写
      #   "报错已经填进输入框"：重发一条普通消息时弹这句，用户会以为哪里报错了。
      showNotification("已经填进输入框，确认后发送", type = "message", duration = 5)
    })

    # =========================================================================
    # agent 循环（item 9 主体，实现见 R/agent.R）
    # =========================================================================
    #
    # 循环状态的**所有权**在这里划清：
    #   agent.R  —— 什么时候该执行、执行什么、结果怎么回喂（纯逻辑 + 一个心跳）
    #   mod_chat —— 长什么样（开关、状态条、tool 气泡、内联确认卡、停止按钮）
    # 这么切是因为前者的 bug 是"悄悄跑错东西"，后者的 bug 是"看不出来在跑"，
    # 混在一个文件里改其中一边很容易把另一边弄坏。

    #' 取某个对话的循环状态机，没有就地建一个（★★ Test_V15.7 item 2）
    #'
    #' 改之前是模块初始化时**一次性**建一个，全会话共用。那个形状在
    #' "切对话就 abort" 的前提下没问题（反正同时只有一个循环）；item 2 之后
    #' 两个对话可以同时在跑，共用一个的话 A 的循环会被 B 的状态、B 的 sid
    #' 顶掉 —— 症状是"循环跑着跑着写进另一个对话里了"，不报错。
    #'
    #' ⚠️ **懒建**。不再在模块初始化时建：那时还没登录、rv$session_id 还是
    #'    NULL，建出来的那个钩子会永远指着那个空壳 run。代价是每个**开过循环**
    #'    的对话各自带一个每秒一跳的心跳 observer（空闲会话一次几乎为空的
    #'    flush），换来的是循环跟着对话走。
    #'
    #' ⚠️ 只能在**响应式上下文**里调（它内部会 isolate(input$*) 并注册心跳
    #'    observer）。当前调用点全是 observer / observeEvent，没有一个是
    #'    渲染函数 —— 往渲染函数里加调用点会让心跳 observer 被反复重建。
    agent_of <- function(r) {
      if (!is.null(r$agent)) return(r$agent)
      a <- dsapp_agent_new(
        state, engine, session, ns, cfg(),
        # 轮数从滑块拿（V11 item 5）。**建的时候读一次**就够：之后用户再拖
        # 滑块由下面那条 observeEvent 直接改这个对象的 max_iter。
        #
        # ⚠️ 这里**不能**写 `as.integer(input$agent_iter) %||% DSAPP_AGENT_MAX_ITER`。
        #    %||% 判的是 is.null，而滑块还没初始化时 input 是 integer(0)
        #    （长度 0，不是 NULL）—— %||% 会原样放行这个空向量，max_iter 变成
        #    integer(0)，然后 `a$iter >= a$max_iter` 求值成 logical(0)，
        #    而 if(logical(0)) 直接抛错。表现是"新建对话正常、一开自动执行就崩"。
        #
        # ⚠️⚠️ 而且**必须包 isolate()**。裸读 input$agent_iter 会抛
        #    "Can't access reactive value 'agent_iter' outside of reactive
        #    consumer"。（自检读的是源码文本，不跑会话，900 多条全绿也照样
        #    白屏 —— 2026-09-15 和 app.R 里 kicked_flag 那条是同一分钟里踩到
        #    的同一类错。）
        #    包了 isolate 之后这里是"建的时候读一次"，之后用户再拖滑块由
        #    下面那条 observeEvent 改同一个对象的 max_iter，语义不变。
        #
        # ★ V16.3 item 4：改走 agent_iter_now() —— 轮数也可能"不设上限"
        #   （Inf），而裸读 input$agent_iter 在勾着的时候是 NULL、
        #   dsapp_iter_value(NULL) 会兜回 6 轮：用户勾了"不设上限"、
        #   发一句话，循环跑到第 6 轮就停了，还往对话里写一句
        #   「已经用满了这次给的轮数（6 轮）」—— 界面上那个勾还亮着。
        max_iter = isolate(agent_iter_now()),
        # ★ V13.17 item 31：自动结束时间同样"建的时候读一次"。
        # ⚠️ 上面关于 `%||%` 空向量和 isolate() 的两条**逐字**适用于这里。
        # ★ V16.1 item 5：换算走 dsapp_wall_from_slider()，不再在这里 ×3600 ——
        #   旧写法（`dsapp_wall_value(x * 3600)`）认不出"不设上限"那一格，
        #   会让默认档静默退化成 8 小时。理由见那个函数的说明。
        # ⚠️ isolate 那块**仍然要**（理由见上面那两条），但里面读的是
        #   agent_wall_hours()：裸读 input$agent_wall 会在控件还没报上来的
        #   那几十毫秒里退成"2 小时"，而滑块画的是"不设上限"。
        wall_limit = dsapp_wall_from_slider(isolate(agent_wall_hours())),
        # ★ V16.2 item 1：「出错自动修」的次数上限。**默认是不设上限**
        #   （哨兵 0），和上面两个同一个形状：建的时候读一次，之后用户在
        #   「不设上限」那一组里改，由下面那条 observeEvent 直接改这个对象。
        #
        # ⚠️ 同样经过 agent_fix_max() 而不是裸读 input（见那个函数的说明：
        #    控件还没报上来时它是 NULL / integer(0)，裸读会让 a$fix_max 变成
        #    空向量，`if (logical(0))` 在循环内部抛错 —— 和 max_iter 那条
        #    一模一样，只有报错点离得很远）。isolate 的理由同上。
        fix_max = isolate(agent_fix_max()),
        hooks = list(
          # ⚠️⚠️ 这六个钩子**全部**认 r（这个循环自己的对话），一个都不许认
          #    rv$session_id / rv$streaming / st。它们会在"用户早就切到别的
          #    对话去了"的时候被调到（心跳一秒一跳、任务结束时回调），认
          #    显示层的话就是往别人的对话里写消息、把别人的流判成"还在生成"。
          #    —— 这恰恰是 item 2 之前不可能发生、之后就必然发生的事。
          get_sid    = function() r$sid,
          get_target = function() dsapp_current_target(),
          begin_llm  = function(scene) dsapp_llm_begin(r$sid, scene),
          running    = function() !is.null(r$llm),
          # 所有写库都包 tryCatch。循环可能在对话已被删掉的瞬间写一条消息，
          # 那时外键不成立、DBI 直接抛 —— 不包的话整个循环带着错误堆栈停在
          # 半路，界面上只看到状态条不动，没有任何提示。
          add_msg    = function(role, txt) {
            sid <- r$sid
            if (is.null(sid)) return(invisible(NULL))
            tryCatch({
              db_message_add(sid, role, txt, con = dsapp_db(cfg()))
              hist_ver(hist_ver() + 1)
              sess_ver(sess_ver() + 1)
              invisible(TRUE)
            }, error = function(e) {
              showNotification(dsapp_err_user(e, "保存这条消息",
                                              hint = "内容还在，只是没存上。"),
                               type = "error", duration = 8)
              invisible(NULL)
            })
          },
          refresh    = function() {
            agent_ver(agent_ver() + 1)
            hist_ver(hist_ver() + 1)
          }
        ))
      # 开关。默认关闭 —— 会自动跑代码、花 token 的能力不该替用户默认打开。
      #
      # ⚠️★ V13.5 item 1：这两个开关的值必须在**建的时候**从当前界面状态灌
      #    回去，不能只在 observeEvent 里写 —— 否则用户开了自动执行、切一下
      #    对话再切回来，开关的勾还在、行为已经回到关闭状态了。这是"界面上
      #    明明开着却不动"的经典形状。下面那条 observeEvent 管的是"原地改"。
      #    ⚠️ item 2 之后这条更紧了：懒建意味着"切回来"那一刻可能正是第一次
      #       建，不灌的话**每一次**切回来都回到关闭。
      #
      # ⚠️⚠️ **必须包 isolate()**，和上面 max_iter 那条一模一样。裸读会抛
      #    "Can't access reactive value 'agent_mode' outside of reactive
      #    consumer"。2026-09-17 当场踩过：selftest 1900 多条全绿，因为它读
      #    的是源码文本、不跑会话；是 tests/ui_v135 的浏览器脚本第一个冲上来，
      #    报的是"等了 150 秒还是空白页"。
      a$enabled <- isTRUE(isolate(input$agent_mode))
      a$autofix <- if (is.null(isolate(input$agent_fix))) TRUE
                   else isTRUE(isolate(input$agent_fix))
      r$agent <- a
      a
    }

    # ★ V13.12 item 4：勾上「自动执行」也是"第一次开启任务"的一种，要问一次。
    #   先让开关真的生效（agent_of 里那两行）、再问，用户答完之后看到的状态
    #   才是对的。
    observeEvent(input$agent_mode, {
      on <- isTRUE(input$agent_mode)
      a <- agent_of(st)
      a$enabled <- on
      if (!on) a$stop("已关闭自动执行")
      agent_ver(agent_ver() + 1)
      # ★ V16.1 item 5：和上面那条路同一个排法（弹窗优先，toast 让位）。
      if (on && !isTRUE(maybe_ask_agent_pref())) maybe_warn_unlimited()
    }, ignoreInit = TRUE)

    # ★ V13.5 item 1：「出错自动修」。默认开，和上面那个是两件事。
    #
    # ⚠️ 关掉的时候**不要**调 st$agent$stop()。这两件事的语义不一样：
    #    「自动执行」关掉 = "别再自己往下跑了"，把正在跑的那一段停掉是对的；
    #    「出错自动修」关掉 = "以后出错了别自动接手"，而用户完全可能是在
    #    AI 正查着一个报错的时候取消勾选的 —— 那一刻把它掐掉，等于用户
    #    点了个复选框就把正在进行的排查扔了，而界面上只会看到状态条消失。
    #    下一次任务失败时自然会读到这个新值。
    #
    # ⚠️ 用 `isTRUE(input$agent_fix)` 而不是 `input$agent_fix`：控件还没
    #    bind 好时它是 NULL，NULL 写进 a$autofix 会让 kick_env_fix 的第一道
    #    闸 `!isTRUE(a$autofix)` 直接为真 —— 默认开着的东西静默失效。
    observeEvent(input$agent_fix, {
      if (!is.null(st$agent)) st$agent$autofix <- isTRUE(input$agent_fix)
      agent_ver(agent_ver() + 1)
    }, ignoreInit = TRUE)

    # =========================================================================
    # 「AI 怎么干活」—— 第一次问一次，之后按记住的来（V13.12 item 4）
    # =========================================================================
    #
    # 用户原话：「分析过程中的 warring 和报错没有必要返回给用户，请在用户
    # 第一次开启任务时让用户选择是否自动执行和出错自动修，然后记住用户的
    # 默认设置，新会话生效」。
    #
    # 拆成三件事，分别落在三个地方，别把它们混起来：
    #   1. 警告/报错的**显示**   —— R/render.R 的 dsapp_run_card + R/agent.R
    #      的 dsapp_agent_tool_text（判据都在 R/envfix.R）；
    #   2. **默认值**的存取       —— R/uiprefs.R 的 agent_auto / agent_autofix；
    #   3. 第一次**问一次**       —— 就是这一段。
    #
    # ---- 什么时候问 ----------------------------------------------------------
    #
    # 「第一次开启任务时」，具体是两个入口里先发生的那个：
    #   · 用户自己把「自动执行」勾上；
    #   · 用户发出第一条消息（含「总结并生成报告」、文献速递 —— 它们都走
    #     dsapp_chat_send）。
    # 只挂在其中一个上的话，另一条路上的人永远见不到这个设置。
    #
    # ---- 为什么是 easyClose = TRUE -------------------------------------------
    #
    # 它是**非阻塞**的：弹窗出现的时候消息已经发出去了，任务在跑。做成
    # easyClose = FALSE 会把整个会话冻住 —— 而冻结期间用户连「停止」都点不了，
    # 这是拿一个偏好设置换了控制权。点外面关掉就当没答，下次再问。
    agent_pref_asked <- reactiveVal(FALSE)

    # ★ V16.1 item 5：那条「这一次不设上限」的提醒，**每个会话只说一次**。
    #
    # ⚠️ 用普通变量而不是 reactiveVal：它只被 observeEvent 的处理器读写，
    #    没有任何一格 render 依赖它。做成 reactiveVal 反而会多出一堆
    #    "读了它就把下游失效"的边（见本仓那条 reactiveVal 自失效的记录）。
    #    它是"这次会话里说过了没有"，不是状态。
    unlim_noted <- FALSE

    agent_pref_store <- function(auto, autofix) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      # ⚠️ 读改写：dsapp_uipref_save() 收的是**一份完整的偏好**，只给两个键
      #    的话其余全被打回默认 —— 表现是"答完这个弹窗，面板宽度自己变回
      #    去了"。mod_settings.R 的 save_uipref 上面那条注释记的是同一个坑。
      full <- dsapp_uipref_get(uid, con = dsapp_db(cfg()))
      full$agent_auto    <- isTRUE(auto)
      full$agent_autofix <- isTRUE(autofix)
      full$agent_asked   <- TRUE
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg())), silent = TRUE)
      state$uipref_rev <- state$uipref_rev + 1L
      # ⚠️ 光落库不够，还得把这两个复选框**按到新值上**：用户答完弹窗之后
      #    眼前最直接的问题就是"那我现在的开关是什么状态"。只写库的话，
      #    界面上那两个勾还是进来时的老样子，和刚存下的默认值对不上 ——
      #    而弹窗里写的正是"按这个来"。走 update* 而不是直接改 st$agent：
      #    上面那两条 observeEvent 会跟着改 st$agent，只有一条赋值路径。
      updateCheckboxInput(session, "agent_mode", value = isTRUE(auto))
      updateCheckboxInput(session, "agent_fix",  value = isTRUE(autofix))
      showNotification(
        if (isTRUE(auto))
          "记住了：以后新开的对话都自动往下跑，出错也由 AI 自己修。"
        else if (isTRUE(autofix))
          "记住了：以后新开的对话里，AI 出错了会自己接手（但不会自己往下跑）。"
        else
          "记住了：以后新开的对话都不自动跑，报错原样给你看。",
        type = "message", duration = 8)
    }

    maybe_ask_agent_pref <- function() {
      if (isTRUE(agent_pref_asked())) return(invisible(FALSE))
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        return(invisible(FALSE))
      }
      p <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg())),
                    error = function(e) NULL)
      # 读不出来（库抖了一下）就**问**，不要静默跳过：跳过的话这一个用户
      # 永远见不到这个设置，而且没有任何痕迹说明为什么。
      if (!is.null(p) && isTRUE(p$agent_asked)) {
        agent_pref_asked(TRUE)
        return(invisible(FALSE))
      }
      agent_pref_asked(TRUE)

      cur_auto <- isTRUE(isolate(input$agent_mode))
      cur_fix  <- !identical(isolate(input$agent_fix), FALSE)

      showModal(modalDialog(
        title = tagList(icon("robot"), " AI 怎么干活？"),
        easyClose = TRUE,
        p("这个只问一次。之后按你选的来，随时能在「设置 → 执行 → AI 怎么干活」里改。"),
        # ⚠️ 预勾的是**当前这条对话里开关的状态**，不是平台默认值。用户可能
        #    在弹窗出现之前就已经手动勾了「自动执行」—— 那时再按平台默认
        #    预勾一个 FALSE，等于让他重新做一次刚做完的选择。
        checkboxInput(ns("pref_ask_auto"),
                      label = paste0("自动执行：不用每步点确认，AI 自己一轮轮往下做",
                                     "（会持续消耗 token）"),
                      value = cur_auto),
        checkboxInput(ns("pref_ask_autofix"),
                      label = paste0("出错自动修：任务跑挂了之后，AI 自己读报错、",
                                     "改代码或补依赖、然后重跑一遍"),
                      value = cur_fix),
        div(class = "small text-muted",
          tags$ul(class = "mb-0",
            tags$li("两个都不勾 → 每跑一段代码都停下来问你，报错原样摆出来；"),
            tags$li(tags$b("运行过程中的警告"), "（R 的 Warning、Python 的 ",
                    tags$code("UserWarning"), "）三种选法都不显示 —— ",
                    "它们不影响结果，需要的时候能从执行记录那张卡片里翻出来。")
          )
        ),
        footer = tagList(
          actionButton(ns("agent_pref_manual"), "都先别开，我自己盯着"),
          actionButton(ns("agent_pref_save"), "就按这个来",
                       class = "btn-primary", icon = icon("check"))
        )
      ))
      invisible(TRUE)
    }

    #' ★ V16.1 item 5：「不设上限」这一档的提醒。
    #'
    #' 用户原话：「全部默认上下文、运行时间、token 都没上限……没上限模式可以先
    #' 提醒下用户要不要设置」。
    #'
    #' 三件事**这一版只动了运行时间**（上下文和 token 从 V15.6 item 8 起就已经
    #' 是"跟随模型上限"了），但提醒里要一并说 —— 用户问的是"有没有上限"，只答
    #' 三分之一等于没答。
    #'
    #' ⚠️ 只在**真的要开跑**的时候说（勾上自动执行 / 发出第一条消息），不在
    #'    页面加载时说。加载时说的那条，用户还没决定要不要跑东西，读了也不知道
    #'    该干什么；而"马上要跑一个不设时限的东西"这一刻，这句话才有落点。
    #' ⚠️ 每个会话只说一次（unlim_noted）。挂的那两个入口**每发一条消息都会
    #'    走一遍**，不设闸的话它就成了每轮都弹一次的噪音 —— 而噪音的下场是
    #'    用户学会无视所有提示，连真有问题的那些一起无视。
    #' ⚠️ 文案里只报**控件名**（「不设上限」那一组），不描述它在哪儿 ——
    #'    位置会随着版面改，控件名不会，而报位置的那句话一旦过期，用户会
    #'    照着一个不存在的位置找一个不存在的滑块。
    #'
    #' ★★ V16.2 item 2：**这一条的落点变了**。V16.1 那会儿"不设上限"是
    #'    藏着的（时长在滑块最右一格、token 在模型页、出错自动修干脆看不见），
    #'    所以这句话得挨个告诉用户"去哪儿改"。现在对话页上就有一组勾选框，
    #'    四个上限一眼看得全 —— 这句话的作用从"指路"变成"报数 + 指路"，
    #'    指的还是**同一页**上那一组。
    #'
    #' ⚠️ 判据也跟着放宽了：四个上限里**任意一个**是不设上限就说。
    #'    V16.1 那版只看时长，而现在四个勾都是默认勾上的 —— 只看时长的话，
    #'    用户把「运行时间」取消勾选、其余三个还是不限，这个提醒就再也不出现
    #'    了，而那正是他最该被告知一声的时候。
    maybe_warn_unlimited <- function() {
      if (isTRUE(unlim_noted)) return(invisible(FALSE))
      w <- tryCatch(dsapp_wall_from_slider(isolate(agent_wall_hours())),
                    error = function(e) DSAPP_AGENT_WALL_DEF)
      # ⚠️ 三个都包在 isolate 里：这一条会在 observeEvent 里被调，裸读
      #    state$ctx_limit 会把它变成那个 observer 的依赖 —— 用户在模型页
      #    拖一下滑块就把这个会话的"说过了"重置一遍（unlim_noted 是普通
      #    变量，不受影响，但这个函数会被重新叫、然后因为 unlim_noted 直接
      #    返回）。包起来是为了让依赖关系只有写它的那一处说了算。
      # ★ V16.3 item 4：轮数也算一项了。
      # ★★ V16.5 item 1：它的由头从"那一组里的第五个勾"换成了「开启」
      #    —— 判据本身（dsapp_iter_is_unlimited）一个字没变。
      unlim_any <- isTRUE(dsapp_wall_is_unlimited(w)) ||
        isTRUE(dsapp_maxtok_is_unlimited(isolate(state$ctx_limit))) ||
        isTRUE(dsapp_autofix_is_unlimited(isolate(agent_fix_max()))) ||
        isTRUE(dsapp_iter_is_unlimited(isolate(agent_iter_now())))
      if (!unlim_any) return(invisible(FALSE))
      unlim_noted <<- TRUE
      showNotification(
        tagList(
          tags$b("这一次不设上限。"),
          "下面那组「不设上限」的勾现在是亮着的：模型的上下文和单次输出按",
          "模型自己的窗口走，自动执行不限时长，出错也由 AI 一直修下去。",
          # ★ V16.3 item 4：轮数那一项当时是**默认收着**的（那一组里唯一一
          #   个默认不勾的），所以只有用户自己勾上时才提它。
          # ★★ V16.5 item 1：它现在跟着「开启」走 —— 轮数不设上限这件事
          #    **不是**那一组勾里的一个，是「自动执行·开启」的直接后果，
          #    所以说的时候要带上由头。照旧只在真的是不限的时候才提：
          #    无条件写进去就是替用户描述了一个他没做的选择。
          if (isTRUE(agent_mode_now()))
            "自动执行开着，轮数也不设上限，",
          # ★★ V16.5 item 1："去哪儿收"这句话也得跟着分叉：轮数不设上限是
          #    「开启」带来的，而「开启」**不在**那一组勾里 —— 照旧说"把对应
          #    的勾去掉"的话，用户会在那一组里找一个不存在的「轮数」勾，
          #    而正确动作（取消「开启」）一个字都没提。指错路的提示比不指还坏。
          if (isTRUE(agent_mode_now()))
            "要收一收的话：取消「自动执行」的「开启」会把轮数滑块还回来，那一组里的勾去掉也会就地出现能填数的控件。"
          else
            "要收一收的话，把对应的勾去掉 —— 就地会出现能填数的控件。",
          # ⚠️ 把"那什么在兜底"说出来。不说的话，用户会以为"不设上限 = 可能
          #    永远跑下去"，而实际上无新进展自动停、以及随时能按的「停止」
          #    都还在 —— 只讲风险不讲兜底，是在吓人，不是在提醒。
          #    ★ V16.2：最后那道兜底（"出错自动修不限次数"）不设上限之后，
          #    这一段里**不能再写"出错会自己停下来"**了 —— 它现在真的不会。
          #    ★★ V16.3 item 4：轮数也成了"可以不设上限"的一项，所以这句
          #    兜底**不能无条件写"轮数上限"** —— 用户勾上「轮数」之后它就是
          #    一句假话（而这句假话恰恰是用来安慰人的）。按实际状态说：
          tags$br(),
          tags$span(class = "small",
            if (isTRUE(dsapp_iter_is_unlimited(isolate(agent_iter_now()))))
              "「没有新进展就停」照旧生效，随时可以按「停止」。"
            else
              "轮数上限和「没有新进展就停」照旧生效，随时可以按「停止」。")
        ),
        type = "warning", duration = 12)
      invisible(TRUE)
    }

    observeEvent(input$agent_pref_save, {
      agent_pref_store(isTRUE(input$pref_ask_auto), isTRUE(input$pref_ask_autofix))
      removeModal()
    })

    # 「都先别开」= 两个都存 FALSE，**不是**"没答"。区别很重要：存了之后
    # 就不再问了；不存的话这个按钮等于"稍后再说"，而它上面写的是"我自己
    # 盯着" —— 那是一个回答，不是一个推迟。
    observeEvent(input$agent_pref_manual, {
      agent_pref_store(FALSE, FALSE)
      removeModal()
    })

    # 登录之后，把账号里记住的默认值推到那两个复选框上。
    #
    # ⚠️ 必须挂在 state$user_id 上，不能写在模块初始化的时候：登录会
    #    session$reload() 整页重载（见 app.R on_login），重载后模块先建起来，
    #    那一刻 state$user_id 还是 NULL，读一次就永远错过。
    #    （和下面"自动打开上一次的对话"那条是同一个理由。）
    #
    # ⚠️ 只推**默认值**，不管用户当下有没有正在看的对话。这两件事在数据上
    #    本来就是分开的（见 uiprefs.R 里 agent_auto 那段注释）。
    observeEvent(state$user_id, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      p <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg())),
                    error = function(e) NULL)
      if (is.null(p)) return()
      # ★ Test_V15.2：邮件提醒那个勾选框也在这里推初值。
      #   ⚠️ 它**在上面的 agent_asked 判断之前**：那两个勾选框是"你上次怎么
      #     回答的弹窗"，没回答过就不该覆盖；邮件提醒是库里的一个普通设置，
      #     和弹窗没关系，跟着 agent_asked 一起 return 的话，用户在设置页
      #     打开过、回到这里会看到没勾（而库里是勾着的）。
      if (isTRUE(dsapp_mail_ready(cfg())))
        updateCheckboxInput(session, "mail_notify", value = isTRUE(p$email_task))
      if (!isTRUE(p$agent_asked)) return()
      updateCheckboxInput(session, "agent_mode", value = isTRUE(p$agent_auto))
      updateCheckboxInput(session, "agent_fix",  value = isTRUE(p$agent_autofix))
    }, ignoreNULL = TRUE)

    # ---- 邮件提醒那个勾选框（★ Test_V15.2 item 2）---------------------------
    #
    # ★ 和设置页那张卡片改的是**同一个**键（email_task），两个入口，一份真相。
    #
    # ⚠️⚠️ 这里**必须**比对"值到底变了没有"，不能点一次就无脑写一次。理由不是
    #    省一次写库，是断一个环：
    #        勾选框 → 存库 → rev+1 → 下面那个 observeEvent 推新值
    #               → 浏览器回发 input → 又走回这里 ……
    #    只要有一次"值没变也照写、照 bump"，这个环就永远转下去（页面上表现为
    #    勾选框反复闪、库里被反复重写）。值没变就**一个字节都不写**，环到这里
    #    就停了。
    observeEvent(input$mail_notify, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      v <- isTRUE(input$mail_notify)
      # ⚠️ 这里不用 cur_prefs()：它读 state$uipref_rev，而下面那个同步用的
      #    observeEvent 正好也在盯 rev —— 虽然 observeEvent 的 handler 是
      #    isolate 的、不建立依赖，但读一份**不参与本环**的值更不容易看错。
      full <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg())),
                       error = function(e) NULL)
      if (is.null(full)) return()
      if (identical(isTRUE(full$email_task), v)) return()
      # 只改这一个键、其余沿用库里现在的值：dsapp_uipref_save() 收的是一份
      # **完整**的偏好，少给一个键它会把那个键当"没设过"打回默认值 ——
      # 表现是"勾了一下邮件提醒，面板宽度自己变回去了"。
      full$email_task <- v
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg())), silent = TRUE)
      state$uipref_rev <- state$uipref_rev + 1L
    }, ignoreInit = TRUE)

    # 设置页（mod_settings）改了同一个开关 → 把新值推回这一格。
    #
    # ⚠️ 读 input 只用来**比对**，所以裹 isolate()：让它成为依赖的话，
    #    用户自己勾一下就会触发本段、本段又 updateCheckboxInput ——
    #    那是上面那个环的另一个版本。
    #
    # ⚠️ 没配 SMTP 时这一格在 DOM 里根本不存在，updateCheckboxInput 收到的
    #    是对不存在的 id 的操作。加一道 mail_ready 判断，免得每次 rev 变动
    #    都在服务端日志里留一条警告。
    observeEvent(state$uipref_rev, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      if (!isTRUE(dsapp_mail_ready(cfg()))) return()
      p <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg())),
                    error = function(e) NULL)
      if (is.null(p)) return()
      if (!identical(isTRUE(isolate(input$mail_notify)), isTRUE(p$email_task)))
        updateCheckboxInput(session, "mail_notify", value = isTRUE(p$email_task))
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # =========================================================================
    # 事件
    # =========================================================================

    # 登录之后自动打开上一次的对话。
    #
    # item 5 说的是"用户以后可以通过账号加载之前在这个 app 里的操作" ——
    # 只把对话列在左边、让人自己找回来，不算加载；登录后停在空白页，用户
    # 看到的第一眼是"我的东西没了"。这里替他打开最近改动过的那条。
    #
    # ⚠️ 必须挂在 state$user_id 上，**不能**写在模块初始化的时候：
    #    登录会 session$reload() 整页重载（见 app.R on_login），重载后
    #    模块是先建起来的，那时 state$user_id 还是 NULL，读一次就永远
    #    错过。等它真的被写进来再挑。
    # ⚠️ 只在"当前没打开任何对话"时挑。以后要是加了别的入口来写入
    #    user_id，这条不能把用户正看着的对话顶掉。
    observeEvent(state$user_id, {
      uid <- state$user_id
      if (is.null(uid) || !is.null(rv$session_id)) return()
      # db_sessions_list 按 updated_at 倒序，第一条就是最近的
      last <- tryCatch(db_sessions_list(user_id = uid, con = dsapp_db(cfg())),
                       error = function(e) NULL)
      if (is.null(last) || nrow(last) == 0) return()
      # ⚠️ 登录后第一次定位到"最近的那个对话" —— 这一对要一起走
      #    （见 runs 那一段顶部的 ⚠️）。
      use_run(last$id[[1]])
      rv$session_id <- last$id[[1]]
      show_run()
    }, ignoreNULL = TRUE)

    observeEvent(input$pick_session, {
      sid <- input$pick_session
      req(sid)
      if (identical(sid, rv$session_id)) return()
      # 只让点开"我能看的"对话。列表本来就只列这些，但 `data-sid` 是前端
      # 传上来的任意字符串 —— 手改一下就能要求打开别人的对话号。
      # 不查这一步的话，越权发生在**服务端已经读了消息**之后，
      # 界面上看得出来才有鬼。
      role <- db_session_role(sid, state$user_id,
                              is_admin = dsapp_user_is_platform_admin(state$user),
                              con = dsapp_db(cfg()))
      if (!dsapp_role_can_view(role)) {
        return(showNotification("这个对话不存在，或者没有共享给你",
                                type = "warning", duration = 6))
      }
      # ★★ Test_V15.7 item 2：**切走不再掐任何东西。**
      #
      #   原来这里是 dsapp_chat_abort() + st$agent$stop("已切换对话")，
      #   原作者的注释写着「不做"切走了还在后台跑" —— 那要引入一整个新的
      #   状态维度（哪个对话在跑、切回来怎么接、界面上怎么显示），v1 不划算」。
      #   用户现在的原话就是「切换会话时会中断思考，需要多个会话任务能够
      #   同时执行，并支持用户在会话间切换时不中断」—— 那就是要 v2。
      #
      #   现在的分工：use_run 换显示对象、show_run 照着重画；上一个对话那一轮
      #   （连同它的循环）继续跑，泵每一拍把**所有**活着的 run 都推一把，
      #   只把画面留给当前这个。切回去就能看到它已经跑到哪儿了。
      #
      #   ⚠️ 唯一停掉它们的入口只剩「停止」按钮（那本来就是给用户按的）。
      use_run(sid)
      rv$session_id <- sid
      show_run()
    })

    # ★ V13.11 item 5：文献速递页交过来的活 —— 新建对话、挂技能、发提示词。
    #
    # 为什么不在这条里自己写一遍"建对话 + 发消息"：那等于把 dsapp_chat_send
    # 里那几道闸门（正在生成中 / 只读共享对话 / 没 Key / 没选模型）在第二处
    # 再实现一遍 —— 而重复实现的闸门总有一天会漏掉一条，漏掉的那条还正好是
    # "不能往别人的对话里写"这种。
    #
    # ⚠️ 先建对话并把它设成当前对话，**再**调 dsapp_chat_send()。
    #    顺序反了的话，消息会落进**上一个**对话里（dsapp_chat_send 用的是
    #    rv$session_id），用户看到的是"我点了开始检索，结果上一条对话里
    #    多了一堆东西"。
    observeEvent(input$lit_go, {
      m <- input$lit_go
      req(m)
      prompt <- as.character(m$prompt %||% "")
      if (!nzchar(trimws(prompt))) return()

      # ★★ Test_V15.7 item 2：这里原来也 abort + stop 循环。现在**不动**上一个
      #    对话 —— 用户在文献速递页点"开始检索"之前完全可能正让 AI 在另一个
      #    对话里跑分析，那件事没有理由被打断（同 pick_session）。
      #    记着原来在哪个对话 —— 万一下面被闸门拦下、这个新建的要收回去，
      # 得把用户放回他原来待着的地方，而不是扔进一个空白页。
      prev_sid <- rv$session_id

      con <- dsapp_db(cfg())
      sid <- db_session_create(user_id = state$user_id, con = con)
      # 标题由文献速递页拼好送过来（关键词拼的）。落库前**再掐一次**：
      # 那是浏览器发来的字符串，长度不受我们控制。
      #
      # ⚠️ 这里先设一遍只是为了"万一后面出错，列表里也是个像样的名字"，
      #    **真正生效的是下面发完之后那次**。原因见那段注释。
      ttl <- trimws(as.character(m$title %||% ""))
      if (nzchar(ttl)) db_session_rename(sid, substr(ttl, 1, 40), con = con)
      # 默认技能照挂（新对话该有的都有，见 dsapp_session_skills_seed）
      try(dsapp_session_skills_seed(sid, state$user_id, con = con),
          silent = TRUE)

      # 再把文献速递页勾上的那几条**加上去**。
      # ⚠️ 用"并集"而不是"覆盖"：seed 挂的是用户的默认技能（比如他自己
      #    的教程规则），和这次勾的是两回事，覆盖掉等于替他把默认技能摘了。
      ids <- suppressWarnings(as.integer(unlist(m$skills, use.names = FALSE)))
      ids <- ids[!is.na(ids)]
      if (length(ids)) {
        cur <- tryCatch(dsapp_session_skills(sid, con = con),
                        error = function(e) integer(0))
        try(dsapp_session_skills_set(sid, union(cur, ids), state$user_id,
                                     con = con), silent = TRUE)
      }

      # ⚠️ use_run 必须在 rv$session_id **之前或紧随其后**（见 runs 那段的
      #    ⚠️）：这一条下面紧接着就 dsapp_chat_send 了，而那个函数用的正是
      #    st / rv$session_id 这一对。
      use_run(sid)
      rv$session_id <- sid
      show_run()
      skill_ver(skill_ver() + 1)

      # 最后才发。走的是**同一条**发送路径，所以"正在生成中/没 Key/没选
      # 模型"那几道闸门照样拦得住，用户的体会和在输入框里自己发完全一样。
      ok <- dsapp_chat_send(extra = prompt)

      # ★ 发完**再设一次标题**。
      #
      #   ⚠️ 不设这一次的话，标题会被上面那次发送**覆盖掉** ——
      #      dsapp_chat_send() 里有一条"第一条消息顺手当标题"的逻辑
      #      （db_session_rename(sid, substr(txt, 1, 24))），而这条路
      #      发出去的正是那段几百字的检索提示词。实测标题会变成
      #      「做一次**文献速递**：围绕下面的关键词检索，给」——
      #      关键词一个字都看不见，用户在会话列表里根本认不出哪次是哪次。
      #
      #   那条"第一条消息当标题"的逻辑本身是对的（用户自己打的第一句话
      #   确实是最好的标题），所以不动它 —— 这里只在本页这条路走完之后
      #   把标题改回关键词那个，顺序解决问题。
      if (isTRUE(ok) && nzchar(ttl)) {
        db_session_rename(sid, substr(ttl, 1, 40), con = con)
        sess_ver(sess_ver() + 1)
      }

      # ★ 没发出去就把刚建的这个对话收回去。
      #
      #   不回收的话，用户在没配 Key / 没选模型时点「开始检索」，得到的是
      #   **列表里多出来一个空对话**加一句提示。那句提示说的是"去配模型"，
      #   而屏幕上多出来的那个东西没有任何解释 —— 下次再点又是一个。
      #   连着点几次就攒出一串空对话，还得自己去删。
      #
      # ⚠️ 只删**我们刚建的这个**（sid），不碰别的。而且只在这条路上删：
      #    用户在输入框里自己发消息时，对话可能是他早就建好、里面已经有
      #    内容的，那种情况下发不出去也绝不能把对话删掉。
      if (!isTRUE(ok)) {
        try(db_session_delete(sid, con = con, cfg = cfg()), silent = TRUE)
        # 放回原来那个对话（可能是 NULL —— 那本来就还没开始过对话）
        # ⚠️ 这一对要一起走：prev_sid 那一份 run 还原样在 runs 里活着。
        use_run(prev_sid)
        rv$session_id <- prev_sid
        show_run()
      }
    })

    observeEvent(input$new_chat, {
      # ★★ Test_V15.7 item 2：新建对话**不再**掐上一个对话。用户按"新建"
      #    多半就是想开个新话题、把手上这个放着跑完。
      sid <- db_session_create(user_id = state$user_id, con = dsapp_db(cfg()))
      # V11 item 3：新建的对话默认挂上用户上传的那条教程技能
      # （见 skills.R 里 dsapp_default_skill_ids 的说明 —— 按内容认，
      #  不按名字认）。挂不上就静默跳过：技能库空了、用户把那条删了，
      #  都不是"新建对话"该报错的理由。
      try(dsapp_session_skills_seed(sid, state$user_id, con = dsapp_db(cfg())),
          silent = TRUE)
      use_run(sid)
      rv$session_id <- sid
      show_run()
      skill_ver(skill_ver() + 1)
    })

    # ★ V13.1 item 4：对话更名。
    #
    #   用户的原话是「会话需要能够更名」。入口是侧栏每一行右边那个铅笔
    #   （见 output$session_list），点一下把**那一行的** sid 发过来。
    #
    #   ⚠️ 判的是**那个对话**的身份，不是当前打开的这个。铅笔挂在行上，
    #      和 rv$session_id 没有关系 —— 用户完全可以不切过去就改别的对话
    #      的名字，事实上那正是最常见的情况：在列表里扫一眼，看见某条叫
    #      "新会话"的，就地改掉。所以这里不能图省事复用 can_write()：
    #      那个判的是当前对话，而改名请求是对着另一行发的。
    rename_sid <- reactiveVal(NULL)

    # 弹窗里显示的是**库里的原始标题**，不是 db_session_label()。那个函数
    # 在标题为空时会退回成短号（"s-20260913145800-4279"），拿它当输入框的
    # 初值，用户一保存就把一个编号变成了真名字 —— 而他本来只想改个错字。
    dsapp_session_raw_title <- function(sid) {
      v <- tryCatch(
        DBI::dbGetQuery(dsapp_db(cfg()),
                        "SELECT title FROM sessions WHERE id = ?",
                        params = list(as.character(sid)[1]))$title,
        error = function(e) NULL)
      if (length(v) && !is.na(v[[1]])) as.character(v[[1]]) else ""
    }

    # 这个对话现在归不归档我改（纯查询，两处判身份都走它）
    dsapp_can_rename <- function(sid) {
      dsapp_role_can_write(db_session_role(
        sid, state$user_id,
        is_admin = dsapp_user_is_platform_admin(state$user),
        con = dsapp_db(cfg())))
    }

    observeEvent(input$session_rename, {
      sid <- as.character(input$session_rename %||% "")
      if (!nzchar(sid)) return()
      if (!dsapp_can_rename(sid)) {
        return(showNotification("这是别人共享给你的对话，只有作者能改名。",
                                type = "warning", duration = 6))
      }
      rename_sid(sid)
      showModal(modalDialog(
        title = tagList(icon("pen"), " 重命名对话"),
        easyClose = TRUE,
        # label = NULL：弹窗标题已经说明这是什么了，再来一行「名称」是废话。
        textInput(ns("rename_title"), NULL, value = dsapp_session_raw_title(sid)),
        div(class = "small text-muted",
            "改的是左侧列表里显示的名字，对话内容和产物都不受影响。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_rename"), "保存", class = "btn-primary")
        )
      ))
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    observeEvent(input$do_rename, {
      sid <- rename_sid()
      if (is.null(sid)) { removeModal(); return() }

      # ⚠️ 三步都别省。`input$rename_title` 在极端情况下会是 NULL 或长度 0，
      #    而 `nzchar(character(0))` 是 logical(0)，`if (logical(0))` 直接抛
      #    "argument is of length zero" —— 一个改名的空输入把整页打成报错。
      raw <- as.character(input$rename_title %||% "")
      raw <- if (length(raw) && !is.na(raw[1])) raw[1] else ""
      # 换行会在侧栏那一行里把标题撑破，先压成空格。库里存 60 个字：列表
      # 按 40 个字截断显示，留的余量是给鼠标悬停时的 title 提示的。
      new <- substr(trimws(gsub("[\r\n]+", " ", raw)), 1, 60)
      if (!nzchar(new)) {
        return(showNotification("名字不能是空的。", type = "warning", duration = 5))
      }

      # ⚠️ 再判一次身份。弹窗是**客户端**的东西：它开着的时候 owner 可能
      #    已经把人踢出共享名单、或者干脆把对话删了，而弹窗不会因为服务端
      #    状态变了就自己消失。只在开弹窗时判一次的话，这里就留下一条缝：
      #    把弹窗晾着，等权限变了再点保存。
      if (!dsapp_can_rename(sid)) {
        rename_sid(NULL)
        removeModal()
        return(showNotification("这个对话已经不归你改了。",
                                type = "warning", duration = 6))
      }

      db_session_rename(sid, new, con = dsapp_db(cfg()))
      rename_sid(NULL)
      removeModal()
      # 侧栏列表依赖 sess_ver，加一下就重画。**不用**动 hist_ver：名字不在
      # 消息流里，把整段历史重渲染一遍纯属浪费（长对话要几百毫秒）。
      sess_ver(sess_ver() + 1)
      showNotification("已改名", type = "message", duration = 3)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    observeEvent(input$del_chat, {
      sid <- rv$session_id
      if (is.null(sid)) {
        showNotification("没有选中的对话", type = "warning")
        return()
      }
      # 删除是不可逆的，而且会连工作区一起删 —— 被共享的人不能删别人的
      # 对话，哪怕他看得见它。
      # ★ V16.1 item 3：拒绝之前先问清楚「为什么」（见 del_gate 的说明）。
      g <- del_gate(sid)
      if (!isTRUE(g$ok)) return(del_gate_notify(g, sid))
      n <- nrow(db_messages_get(sid, con = dsapp_db(cfg())))
      # 工作区（含 .Rlib / .venv）跟着一起删，所以要把文件数也告诉用户 ——
      # 「12 条消息」听起来无关痛痒，「还有 8 个产出文件」才是他真正要掂量的。
      # 弹窗里不报这个数，用户会在删完之后才发现数据没了。
      nf <- length(dsapp_ws_artifacts(sid, cfg())$name)
      extra <- if (nf > 0) {
        sprintf("，以及工作区里的 %d 个产出文件和这个对话专属的包目录", nf)
      } else {
        "，以及这个对话的工作区和专属包目录"
      }
      # ★★ V15.14：弹窗必须**点名**它要删的是哪一个对话。
      #
      #   用户报的是「点击编辑会话名称后，显示的居然是删除界面」。把代码翻遍
      #   了 —— 铅笔只发 session_rename（38 个归档版本无一例外）、全应用只有
      #   这一个垃圾桶路径能弹删除、弹窗开着时侧栏点不穿 —— 也就是说**这条
      #   路径本身一直是对的**。但这个弹窗有一个真问题：它从头到尾没说它要删
      #   哪一条。标题「确认删除」还和技能/环境/任务/文件四处**共用**，正文写
      #   的是"这个对话"。
      #   于是「我点错了东西」和「它弹错了东西」在用户那边**完全没法区分** ——
      #   他看到的只是一个莫名其妙的删除框，而底下那个"对话"两个字没有任何
      #   指认能力。把标题和正文都点名之后，这种事一眼就能看穿。
      #
      #   ⚠️ 名字取**原始 title**、和侧栏同一列同一个字段（db_sessions_list 直接
      #      回 sessions.title，侧栏 substr(...,1,40)），所以两边永远一字不差。
      #      不用 db_session_label()：那句会包一层「对话「…」」，在正文里读起来
      #      是"删除「对话「…」」"。
      del_title <- tryCatch(
        DBI::dbGetQuery(dsapp_db(cfg()),
                        "SELECT title FROM sessions WHERE id = ?",
                        params = list(as.character(sid)[1]))$title,
        error = function(e) NULL)
      if (!length(del_title) || is.na(del_title[[1]]) || !nzchar(del_title[[1]])) {
        del_title <- "（没有名字的对话）"
      }
      showModal(modalDialog(
        title = tagList(icon("trash"), " 删除对话"),
        sprintf("确定删除「%s」吗？其中 %d 条消息%s将被一并删除，不可撤销。",
                substr(as.character(del_title[[1]]), 1, 40), n, extra),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("do_del_chat"), "删除", class = "btn-danger")
        )
      ))
    })

    observeEvent(input$do_del_chat, {
      sid <- rv$session_id
      req(sid)
      # ★ V16.1 item 3：弹窗是客户端的东西，它开着的时候对话可能已经被删掉了
      #   （另一个标签页、或者侧栏那一格是旧的）。照样要先问清楚为什么。
      g <- del_gate(sid)
      if (!isTRUE(g$ok)) {
        removeModal()
        return(del_gate_notify(g, sid))
      }
      # ⚠️ 删的是**当前显示的这个对话**（sid <- rv$session_id，就在上面），
      #    所以 st / st$agent 指的就是它 —— item 2 之后这里仍然必须停：
      #    循环会在两次心跳之间发现自己的会话没了，然后在上面写一条 tool
      #    消息，撞外键（db.R 开了 foreign_keys），报错堆在后台。
      dsapp_chat_abort()
      # 循环先停**再**删库删文件。反过来的话同上。
      if (!is.null(st$agent)) st$agent$stop("对话已删除")
      # 引擎是全局单槽的：这个对话里可能正有一个任务在某处跑着，而它的工作
      # 目录马上就要被删掉。不停掉的话，进程会继续往一个已经消失的目录里写，
      # 收尾时还会去写一条外键已经不成立的 tasks 行。
      #
      # ⚠️ 只能停**属于这个对话**的任务。current_task_id() 给的是任务号，
      #    不是对话号，直接拿来和 sid 比是错的（两者根本不在一个编号空间里，
      #    偶尔相等纯属巧合）。任务行里有 session_id，查一下才算数。
      #    查不动（DB 出错）就当不是本对话的 —— 宁可留一个跑完会报错的任务，
      #    也不能随手把别人正在跑的任务杀掉。
      tid <- if (is.null(engine)) NULL else engine$current_task_id()
      if (!is.null(tid)) {
        trow <- tryCatch(db_task_get(tid, con = dsapp_db(cfg())),
                         error = function(e) NULL)
        if (dsapp_task_in_session(trow, sid)) {
          engine$abort(reason = "对话已删除")
        }
      }
      db_session_delete(sid, con = dsapp_db(cfg()), cfg = cfg())
      # 工作区放在删库**之后**：删库万一失败（外键、SQLite 忙），会话还在，
      # 这时候把用户的文件删了就成了"对话还在、文件没了"。
      # 反过来先删文件再删库失败，症状更糟。
      freed <- dsapp_ws_delete(sid, cfg())
      removeModal()
      # ★ Test_V15.7 item 2：这一行原来只改 rv$session_id，其余是手写的
      #   "清空 st"。现在 st 按对话分，删掉的那个 run 就该**从注册表里摘掉** ——
      #   不摘的话它那一份（连同 llm 句柄）会留在 runs 里，泵每一拍还会去推
      #   一个已经不存在的对话。
      #   ⚠️ 顺序：先 abort（上面做过）再摘，摘完 use_run(NULL) 换到空壳上。
      k <- run_key(sid)
      if (exists(k, envir = runs, inherits = FALSE)) rm(list = k, envir = runs)
      use_run(NULL)
      rv$session_id <- NULL
      show_run()
      agent_ver(agent_ver() + 1)
      # ★★ V16.1 item 3：这一下是"删不掉"的**主因**，别删。
      #
      #   侧栏的 sessions() 只认三个依赖：sess_ver / state$user_id / cfg()。
      #   删除这一路一个都没碰 → 它把**上一次算出来的**列表原样交回来，
      #   被删掉的那一行于是继续挂在侧栏里（库里的行早就没了、工作区也删了）。
      #   用户看到的是"删了还在"，再点一次那一格 —— 它的角色已经是 none，
      #   于是又被告知「这是别人共享给你的对话，删不了」。
      #   改 rv$session_id 只让侧栏**重画**，不会让它**重算**，两件事。
      sess_ver(sess_ver() + 1)
      showNotification(
        if (is.na(freed)) "已删除（工作区清理未完成，下次启动会再扫一遍）"
        else if (freed > 0) sprintf("已删除，释放 %s", dsapp_fmt_bytes(freed))
        else "已删除",
        type = "message")
    })

    #' 停止按钮（★ V15.3 item 4：全应用**唯一**一颗停止入口）
    #'
    #' 用户原话：「停止按钮重复了」。改之前有三颗停止按钮、三个 input id
    #' （`stop` / `stop_task` / `stop_detach`），各管一段状态。现在合成一个
    #' 入口，按**当前状态**分派 —— 三块逻辑一条没丢，都搬进来了。
    #'
    #' ★★ 分派的顺序**必须和 action_host() 一模一样**，这不是巧合：
    #'    任何时刻屏幕上只有一颗停止按钮，它长在哪个宿主里，就说明用户看到
    #'    的是哪一件事。顺序一旦和 action_host() 对不上，就会出现"看着横幅
    #'    点了停止，停掉的却是页面上正在生成的那条回复"—— 而且两边都不报错。
    #'
    #' ⚠️ 分支① 的判据不能只看 rv$streaming。agent 模式下循环大部分时间都不
    #'    在生成 —— 它在等任务执行（一秒一次的心跳），那时 rv$streaming 是
    #'    FALSE。照只认 rv$streaming 的写法会弹一句「当前没有正在生成的内容」，
    #'    然后什么都不做：用户看着一个在跑的任务，点了停止，界面告诉他没东西
    #'    可停。这一条是 V13 修过的，别改回去。
    observeEvent(input$stop, {
      agent_busy <- !is.null(st$agent) && isTRUE(st$agent$active())

      # ---- ① 正在生成（按钮在正在吐字的那条气泡尾巴上）------------------
      if (isTRUE(rv$streaming) || agent_busy) {

        # 停之前把已经生成的部分存下来 —— 白等了几十秒，
        # 不该因为点了停止就丢掉。
        partial <- st$acc
        reason_partial <- st$reason
        dsapp_chat_abort()
        if (nzchar(trimws(partial)) && !is.null(rv$session_id)) {
          db_message_add(rv$session_id, "assistant",
                         paste0(partial, "\n\n*（已手动停止生成）*"),
                         reasoning = reason_partial, con = dsapp_db(cfg()))
        }
        st$acc <- ""
        st$reason <- ""
        rv$thinking <- FALSE
        draft("")

        if (agent_busy) {
          # 循环自己的状态先复位（否则心跳会接着往下跑），再停引擎。
          # 反过来的话，循环可能在引擎已经腾空、任务行却还没写成终结态的那个
          # 窗口里读到一行 'running'，然后一直等下去。
          st$agent$stop("已手动停止")
          # 引擎是全局单槽的，不能无脑 abort —— 这里只在这个任务确实属于
          # 本对话时才停，理由同 do_del_chat。
          tid <- engine$current_task_id()
          if (!is.null(tid) && !is.null(rv$session_id)) {
            trow <- tryCatch(db_task_get(tid, con = dsapp_db(cfg())),
                             error = function(e) NULL)
            # ⚠️ 判归属必须走 dsapp_task_in_session()，**不能**自己写
            #    `identical(as.integer(a), as.integer(b))`。
            #
            #    这里原来就是这么写的，而它是坏的：会话 id 是 dsapp_id("s")
            #    生成的**字符串**（"s3f9a…"），as.integer() 一律给 NA 并附一句
            #    "NAs introduced by coercion" 警告 —— 两边都是 NA，identical()
            #    于是恒为 TRUE。后果是这个"只停本对话任务"的闸门等于不存在：
            #    引擎是全局单槽的，甲点自己的「停止」会掐掉乙正在跑的那个任务。
            #    而且它只在那句警告里留痕，界面上完全看不出来。
            if (dsapp_task_in_session(trow, rv$session_id)) {
              engine$abort(reason = "已手动停止（自动执行循环）")
            }
          }
          showNotification("已停止自动执行", type = "message", duration = 6)
        }

        hist_ver(hist_ver() + 1)
        sess_ver(sess_ver() + 1)
        agent_ver(agent_ver() + 1)
      }

      # ---- ② 有个任务归本对话在跑（按钮在实时卡片里）--------------------
      #
      # 这一段原来长在 input$stop_task 里，判据和措辞都没动。
      # ⚠️ 和「生成中」分开是有原因的：两者的前置条件完全不同（前者要
      #    rv$streaming，后者只要任务还归本对话）。合在一个 if 里的话，
      #    用户在一个没在生成、只在跑任务的对话里点它，会被告知「当前没有
      #    正在生成的内容」。
      if (isTRUE(live_here())) {
        tid <- tryCatch(engine$current_task_id(), error = function(e) NULL)
        if (is.null(tid)) {
          return(showNotification("任务已经结束了", type = "message", duration = 4))
        }
        # 同 do_del_chat：只停**属于本对话**的任务（引擎全局单槽）
        trow <- tryCatch(db_task_get(tid, con = dsapp_db(cfg())),
                         error = function(e) NULL)
        if (!dsapp_task_in_session(trow, rv$session_id)) {
          return(showNotification("这个任务不属于当前对话，没有停它",
                                  type = "warning", duration = 6))
        }
        engine$abort(reason = "已手动停止（对话页）")
        return(showNotification(sprintf("已停止任务 #%s", tid),
                                type = "message", duration = 6))
      }

      # ---- ③ 有个进程脱离页面在后台替这个对话干活（按钮在横幅里）--------
      #
      # 见 dsapp_detach_banner 的说明 —— 它写的是一行库，不是杀进程。
      # 子进程每一轮开头读一次，读到不是 running 就自己收尾（收尾包括把
      # 正在跑的任务停掉、往对话里留一句说明）。
      # ⚠️ 这里**不能**接 engine$abort()：后台循环活在另一个进程里，掐掉当前
      #    这个任务它只会当成一次失败、接着跑下一轮 —— 用户按了停止，界面上
      #    的任务没了，token 却还在烧，而且再也没有地方能停它。
      if (identical(arun_tick(), "running")) {
        sid <- rv$session_id
        if (is.null(sid)) return()
        dsapp_arun_stop(sid, "你在对话页点了「停止」", cfg = cfg())
        # ⚠️ 立刻把 tick 推一下，不等那 5 秒。子进程收尾还要一会儿，但
        #    「不再接受新的停止指令」这件事是马上生效的 —— 按了没反应，
        #    用户会连点。
        arun_tick("stopped")
        return(showNotification(
          "已通知后台停下。它会先把正在跑的任务收尾，稍后在这条对话里留一句说明。",
          type = "message", duration = 8))
      }

      # ---- ④ 都没有 ------------------------------------------------------
      #
      # 正常情况下走不到这里：按钮在 stoppable() 为 FALSE 时是灰的、点不动。
      # 留着是因为按钮的亮灭只是**上一拍**的界面，这一拍的状态可能已经变了
      # （任务刚好跑完）。说一句比什么都不做要好。
      showNotification("当前没有正在生成的内容", type = "warning")
    })

    # ---- 内联确认卡（agent 的 awaiting_user 状态）----
    #
    # ⚠️ 这里**不能**用 showModal。mod_chat 里已经有一个 easyClose = FALSE 的
    #    确认框（代码执行的警告级），它会把整个会话 UI 冻住 —— agent 模式下
    #    人走开了就无限期挂着，而且界面上看不出是"在等人"还是"卡死了"。
    #    内联卡片不挡别的操作，用户可以直接去别的页签，回来再点。
    observeEvent(input$agent_confirm, {
      if (!is.null(st$agent)) st$agent$confirm()
      agent_ver(agent_ver() + 1)
    })

    observeEvent(input$agent_deny, {
      if (!is.null(st$agent)) st$agent$deny()
      agent_ver(agent_ver() + 1)
    })

    observeEvent(input$send, dsapp_chat_send())

    # ---- 「总结并生成报告」（V13.10 item 5）--------------------------------
    #
    # 走 dsapp_chat_send(extra = ...)，也就是**和用户自己打一段话发出去
    # 完全一样的一条路**。这一点是故意的，不是图省事：
    #
    #   · 所有闸门自动生效 —— 只读访客不能发（can_write）、正在生成时不能
    #     发（rv$streaming）、没配 Key / 没选模型时不能发。自己写一条发送
    #     路径的话，这四道闸门得各写一遍，漏一道就是一个"共享进来的访客
    #     能烧 owner 额度"的洞。
    #   · 那句话会**原样留在对话里**。用户点了一个按钮之后，看得见自己
    #     "说过"什么 —— 报告是怎么要出来的，是可复现、可追溯的。把指令藏
    #     在后台（比如塞进系统提示词）看着更干净，但用户会不知道这份报告
    #     是按什么要求写的，也没法照着重来一遍。
    #
    # ⚠️ 代价是那条用户气泡**很长**（指令 + 项目事实清单）。认了：这份清单
    #    正是报告准确性的来源（见 prompts.R 的 dsapp_report_digest），缩成
    #    一句话的话模型就只能靠自己回忆跑过什么，而它会把自己"打算做的
    #    步骤"写成"已经做完的步骤"。
    # ★ V13.13 item 21：点这颗按钮**不再直接生成**，先弹一窗问格式。
    #
    # 用户原话：「点击生成报告时可以选格式：html、ppt、word或其它用户自己
    # 填写的内容」。
    #
    # ⚠️ 为什么要弹窗而不是在按钮旁边放个下拉框：这颗按钮长在输入区那一排
    #    （见上面 .dsapp-composer-actions 的注释），那一排只有"发送"和它两颗，
    #    是用户每一轮都要看的地方。塞一个常驻的格式下拉进去，等于让一个
    #    "偶尔改一次"的选择天天占着视线 —— 和 V6 把模型服务那块搬走的理由
    #    是同一条。弹窗只在真的要生成报告时出现。
    #
    # ⚠️ 那个"待确认"的 modal 里**不许**读 rv$session_id 之外的东西：
    #    弹窗期间用户还能在背景页面上点别的，任何在这里算出来的东西都可能
    #    在点「生成」时已经过期。所以清单（digest）是在**确认那一刻**才算的，
    #    见下面的 report_go。
    observeEvent(input$report_btn, {
      sid <- rv$session_id
      if (is.null(sid) || !nzchar(sid)) {
        return(showNotification("这个对话还没保存，先随便发一句话再试",
                                type = "warning", duration = 6))
      }
      showModal(modalDialog(
        title = "这份报告要什么格式",
        size = "m",
        # 默认 html：V13.12 item 10 定的是"报告默认直接生成 html"，这一条
        # （item 21）加的是**能选**，不是改默认值。
        radioButtons(ns("report_fmt"), NULL,
                     choices = dsapp_report_format_choices(),
                     selected = "html"),
        # ⚠️ 自填那一格走 renderUI 而不是 conditionalPanel：conditionalPanel
        #    的条件串要手写命名空间（`input['chat-report_fmt']`），写错了
        #    不报错、只是永远不显示。renderUI 读的是模块自己的 input，
        #    没有这层字符串拼接，也就没有拼错的余地。
        uiOutput(ns("report_custom_slot")),
        div(class = "small text-muted mt-2",
          icon("circle-info"), " 格式只影响这一份报告的产物文件，",
          "对话里怎么看、以后怎么改都不受影响。"),
        footer = tagList(
          modalButton("取消"),
          actionButton(ns("report_go"), "生成", class = "btn-primary")
        )
      ))
    })

    # 「其它」那一格：选了才出现。
    output$report_custom_slot <- renderUI({
      if (!identical(input$report_fmt, "other")) return(NULL)
      tagList(
        textInput(ns("report_custom"), NULL,
                  placeholder = "比如：Markdown 源码 / Excel 表格 / 直接贴公众号的图文"),
        div(class = "small text-muted",
          icon("triangle-exclamation"),
          " 这台机器上现成能出的是 HTML、Word、PPT。要别的（比如 PDF）",
          "可以让 AI 换个做法，实在做不了它会直说。")
      )
    })

    # 点「生成」：到这里才去读执行记录、才发那句话。
    observeEvent(input$report_go, {
      sid <- rv$session_id
      if (is.null(sid) || !nzchar(sid)) {
        removeModal()
        return(showNotification("这个对话还没保存，先随便发一句话再试",
                                type = "warning", duration = 6))
      }
      fmt <- input$report_fmt %||% "html"
      custom <- input$report_custom %||% ""

      # ⚠️ 选了「其它」却一个字没填 —— 在这里**拦住**，不要发出去。
      #    不拦的话有两条路，两条都坏：提示词那边会退回"先问问用户要什么"
      #    （用户的观感是"点了生成，AI 反过来问我，可我刚在框里选过啊"），
      #    而如果哪天有人把那个兜底改成退回 html，用户拿到的是他明确没要的
      #    格式，且没有任何提示。
      #    ⚠️ 拦的时候**不关弹窗** —— 关掉的话用户得从头再点一遍，而他只是
      #    漏填了一格。
      if (identical(fmt, "other") &&
          !nzchar(trimws(paste(as.character(custom), collapse = "")))) {
        return(showNotification("选了「其它」，先写一句你要什么格式（比如「Markdown 源码」）",
                                type = "warning", duration = 8))
      }
      removeModal()

      digest <- tryCatch(dsapp_report_digest(sid, con = dsapp_db(cfg())),
                         error = function(e) {
                           # ⚠️ 拿不到清单**不是不发**，是把"没拿到"如实告诉
                           #    模型，让它别硬编。静默发一个空清单的话，它会
                           #    把清单为空理解成"这个项目什么都没做"。
                           paste0("（平台没能读出执行记录：",
                                  conditionMessage(e),
                                  "。请只依据对话历史里你确实看到过的内容来写，",
                                  "看不清的地方直说看不清，不要补全。）")
                         })
      dsapp_chat_send(extra = dsapp_report_prompt(digest, fmt, custom))
    })

    # Enter 发送（Shift+Enter 换行）：app.js 把回车转成这个事件
    observeEvent(input$send_key, dsapp_chat_send())

    # 发送按钮的忙闲以服务端为准。
    #
    # 前端为了让"点了立刻有反应"会自己先置灰（见 app.js 的 dsapp:busy），
    # 但前端不知道这一轮什么时候真的结束 —— 没有这条复位消息，按钮就永久
    # 卡在置灰状态，用户只能刷新页面。所以两边都做：前端管即时反馈，
    # 服务端管最终一致。
    observe({
      busy <- isTRUE(rv$sending) || isTRUE(rv$streaming)
      # lock：共享进来的对话把发送按钮和输入框锁死。**只是界面**，
      # 真正的闸门在 dsapp_chat_send / do_del_chat 里（前端锁得再死，
      # 改一下 DOM 就没了）。
      session$sendCustomMessage("dsapp:busy",
        list(btn = ns("send"), busy = busy, lock = is_readonly()))
    })

    # ---- 流式轮询（★★ Test_V15.7 item 2：从"推一个"改成"推所有")----
    #
    # 改之前：`if (!isTRUE(rv$streaming)) return()` —— 只推**屏幕上显示的那个**
    # 对话。item 2 之后同时可以有好几个对话在生成，只推一个的话，切走的那个
    # 就停在原地了（子进程还在吐字，没人收；等切回来时 dsapp_llm_poll 一次
    # 把积压的全读出来 —— 用户看到的是"切回去之后一大段字突然蹦出来"，
    # 而且中间那些 `res$done` 的收尾逻辑会晚很久才跑）。
    #
    # 现在：**所有**活着的 run 每一拍都推，只把画面留给当前显示的那一个。
    #
    # ⚠️ 唤醒源有**两个**，缺一不可：
    #   · run_ver()      —— 有新的一轮起来了。没有它的话，全都没在跑的时候
    #                       这个 observe 就地 return、定时器也没排上，**再也
    #                       不会醒**（agent.R:1339 记过的同一个坑）。
    #   · invalidateLater —— 只要还有活着的就自己续命，200ms 一拍。
    # ⚠️ `rv$streaming` **不再**是这里的判据。它现在的含义是"**屏幕上这个**
    #    对话在不在生成"，那是显示层的状态，不是泵的开关。
    observe({
      run_ver()
      live <- live_runs()
      if (!length(live)) return()
      invalidateLater(200)

      # ★★ "屏幕上是谁"先抓进一个**本地**变量，再进循环。
      #    pump_run() 的第一件事就是把 st 临时换绑成它正在推的那个 run ——
      #    所以 `identical(r, st)` 这种写法是个陷阱：它是惰性的，会等到
      #    st 已经被换掉之后才求值，恒为 TRUE。抓成 cur 之后，这个表达式
      #    求值的对象跟 st 再没关系了（pump_run 里那道 force(is_cur) 是
      #    第二道保险，两道都在）。
      cur <- st
      for (r in live) pump_run(r, is_cur = identical(r, cur))
    })

    #' 推**一个** run 的一拍：收字、送字、收尾
    #'
    #' @param is_cur 这一份是不是**屏幕上正显示着**的那一份。所有写 rv$* /
    #'   draft() / stream_sig() / dsapp:think 的地方都必须过这道闸 ——
    #'   不过的话，后台那个对话的正文会当场画到用户正在看的那个对话上，
    #'   而两边都不报错。
    #'
    #' ⚠️ 函数体里那一段（原来就是流式轮询的原文）里的 `st$xxx` 是**这个 run**
    #'    的意思：这里先把 st 换绑成 r，跑完再换回去。用换绑而不是把每一处
    #'    `st$` 手改成 `r$`，是因为那一段有六十几处、还夹着大段讲时序的注释，
    #'    手抄一遍只会引进新的错字。
    pump_run <- function(r, is_cur) {
      # ★★★ Test_V15.7 item 2：**第一件事就是 force(is_cur)**，而且必须在
      #    `st <<- r` **之前** —— 这一行是那个 P0 的全部修法，别挪、别删。
      #
      #    调用点写的是 `pump_run(r, is_cur = identical(r, st))`，而 R 的实参是
      #    **惰性**的：那个 identical() 此刻**不求值**，只打包成一个 promise，
      #    带着"在调用者的环境里求值"的地址传进来。下面那行 `st <<- r` 先把
      #    st 改成了 r，等到函数体里第一次真正用到 is_cur（`if (is_cur)`）
      #    才去求值 —— 这时 `identical(r, st)` 已经是 `identical(r, r)`，
      #    **恒 TRUE**。于是这道"只把画面留给当前那一个"的闸门整个失效：
      #    后台那个对话吐出来的字，当场画进用户正在看的那个对话里。
      #
      #    症状（2026-10-02 实测）：在 A 里发一条 → 切到新建的 C，C 的消息区
      #    里长出**A 的正文**，两秒一千多字，一路长到 A 那一轮跑完。不报错、
      #    不 warning、日志干净；服务端埋点只要在函数体**顶部**读一下 is_cur
      #    就会把它"修好"（读一下 = 提前 force），所以一开始三次埋点全显示
      #    `is_cur=FALSE`、看上去服务端完全正确 —— 那三小时是**埋点自己**把
      #    bug 藏起来的（见 tests/ui_v157/README.md）。
      #
      #    ⚠️ 判据不能改成"在 if 那一行再算一遍"：那时候 st 已经是 r 了，
      #       怎么算都是 TRUE。要么在这里 force，要么在调用点先把
      #       `identical(r, st)` 存成一个变量再传进来。两个都做也不亏。
      force(is_cur)
      prev <- st
      st <<- r
      on.exit(st <<- prev, add = TRUE)

      h <- r$llm
      if (is.null(h)) return(invisible(FALSE))

      res <- tryCatch(dsapp_llm_poll(h),
                      error = function(e) list(text = "", reasoning = "",
                                               done = TRUE,
                                               error = conditionMessage(e)))

      # ★ V13.12 item 20：这里原来有一句 `rv$tick <- isolate(rv$tick) + 1`，
      #   200ms 推一次，只为把「已用 N 秒」顶着走。删掉了，秒数改由前端自己
      #   走（app.js 读 data-secs）。这个 observe 本身**不删** —— 它不只是
      #   计时器，它是流式输出的**泵**：dsapp_llm_poll(h) 就是在这一拍里把
      #   子进程已经吐出来的文本收进来的。删了它，一个字都不会流出来。
      #
      #   现在它每 200ms 照样跑，但**不再无条件重画任何东西**：往下的
      #   draft(st$acc) 只在真有新文本时才写，新文本才重画那一格。

      # 思考模式下，模型会先吐一大段思维链，正文要等它写完才开始。
      # 不显示出来的话，用户面对的是一个静止的转圈圈，很容易以为卡死了 ——
      # 尤其 v4-pro 在高强度下能想上一两分钟。
      #
      # ★★ V15.3 item 3：这一段整个改写了。**改的是"怎么把思维链送到屏幕上"，
      #    不是"要不要送"** —— 用户原话是「正常往外输出思考过程就行了」。
      #
      # 改之前：`rv$thinking <- TRUE`（**无条件**，每一拍都写）+ 下一行
      #   `draft(st$acc)`，而 output$thinking_box 依赖 rv$thinking ——
      #   写 reactiveVal 就算值没变也会失效下游（本仓已知），于是那一格
      #   每 200ms 被整块换掉一次：<details> 折回去、<pre> 滚回顶部。
      #   这就是用户说的「思考时还是会闪」。
      #
      # 改之后：
      #   · rv$thinking **只在真的变的时候**才写（下面这个 if）—— 它的用处
      #     只剩"给 hint 那一格的指纹加一位"，不再驱动任何重画；
      #   · 思维链正文走 session$sendCustomMessage("dsapp:think")，由
      #     www/app.js 往 <pre> 里**追加**，服务端一次 DOM 都不碰。
      #
      # ⚠️ st$reason_sent 是"已经贴给浏览器多少字"的游标，按**绝对位置**发
      #    增量。它必须和 st$reason 同生共死：只在 dsapp_llm_begin 里归零
      #    （那一轮开头），中途**任何**清空 st$reason 的地方都得一起清它，
      #    否则下一段增量会从错位的地方切起，用户看到的是被啃掉一截的思维链
      #    —— 不报错，只是字不对。
      # ⚠️⚠️ item 2：`dsapp_think_append()` **绝对不能**给非当前的 run 调。
      #    它发的是 session$sendCustomMessage("dsapp:think", pre = ns("think_pre"))，
      #    而 think_pre 是**屏幕上**那个思考框的 id —— 后台那个对话的思维链
      #    会被贴进用户正在看的对话里。不报错，只是另一个对话开始胡言乱语。
      #    非当前的 run 只累加、不发送；切回去时 show_run() 会把游标归零，
      #    下一拍整段重贴（见 show_run 里的说明）。
      if (nzchar(res$reasoning %||% "")) {
        st$reason <- paste0(st$reason, res$reasoning)
        if (is_cur) {
          if (!isTRUE(rv$thinking)) rv$thinking <- TRUE
          dsapp_think_append()
        }
      }

      if (nzchar(res$text)) {
        # 正文开始了就说明思考结束，把思考区收起来
        if (is_cur && isTRUE(rv$thinking)) {
          rv$thinking <- FALSE
          # 换标签（"正在思考…" → "正在组织回答…"）。force = TRUE：这一拍
          # 思维链一个字都没多，不强制的话这个包根本不发，标签就会一直
          # 停在"正在思考…"，而正文已经在往外走了。
          dsapp_think_append(force = TRUE)
        }
        # ⚠️ 思考区不在这里收：它由 output$thinking_box 自己按 rv$streaming 判。
        #    历史上这里是靠"占位气泡被正文气泡顶替"顺带收掉的，而那一格现在
        #    已经搬出 output$streaming 了（见 thinking_box 的说明）。
        #
        # ★★ V15.4 item 3：占位那一格（转圈 + 提示词）该收了。**必须带
        #    `!isTRUE` 这道闸**：这一支在正文吐字期间每 200ms 跑一次，裸写
        #    等于让 wait_box 每 200ms 重画一次 —— 那颗转圈和那行提示词正是
        #    用户说的"闪"。加闸之后一轮里它最多变一次。
        if (is_cur && !isTRUE(rv$text_started)) rv$text_started <- TRUE
        st$acc <- paste0(st$acc, res$text)
        # ⚠️ 非当前的 run 不写 draft —— draft 驱动的 output$streaming 是**屏幕上**
        #    那一格。后台对话的正文只进 st$acc，切回去时由 show_run() 一次性
        #    补上（照 item 1 的增量方案改的时候，这条界线也别弄丢）。
        #
        # ★★★ V15.13：**按链路吃得住的速度发**，不是"字来了就发"。
        #
        # 这一格是 Shiny 的 renderUI：**每次失效就把整段 HTML 重发一遍**，
        # 没有增量、也没有 diff。而泵是 5 拍/秒，于是只要还在吐字，每拍都要
        # 重发一次"整条已生成正文"。线上实测（ss -tni 数 bytes_sent）：
        # **31.7 KB/s** 持续灌一条只能送 3.65 KB/s 的链路 —— 队列永远排不空，
        # 用户点什么都排在积压后面，这就是「做任何操作都很卡」。
        #
        # 所以这里按**字节/秒**放行（额度、估算、为什么不能用
        # DSAPP_STREAM_BUDGET_B 代替，全写在 dsapp_stream_due 的头注里）。
        # 没到点就**这一拍不发** —— 不写 draft 就不失效，一个字节都不会出去。
        #
        # ⚠️ 顺序不能动：上面那行 `st$acc <- paste0(...)` **必须先跑**。
        #    限速挡的只是"刷新画面"，绝不许挡"把字收进来" —— 把闸提到累加
        #    之前，用户丢的就是正文本身，而且丢得无声无息。
        #    自检里有一条盯着这个先后（搜 dsapp_stream_due）。
        if (is_cur) {
          now <- as.numeric(Sys.time())
          if (dsapp_stream_due(nchar(st$acc %||% ""), st$pub_at %||% 0, now)) {
            draft(st$acc)
            st$pub_at <- now
          }
        }
      }

      # ★★ V13.12 item 20：「已输出 N 字符」那一格的重画开关。
      #
      # ⚠️ 这一行不是装饰，删了那一格就**不再更新**（这是个真踩过的坑）。
      #    st 是 new.env()，`st$acc` / `st$reason` 读起来**没有响应式依赖**
      #    —— 原来那一格能走字，靠的正是被删掉的 `rv$tick` 每 200ms 把它
      #    强行重画一次（顺手重读一遍 st，于是"碰巧"是新的）。tick 拆掉之后
      #    它就成了定格：转圈圈在转、字符数一动不动。
      #
      #    所以这里补一个**真的内容指纹**：字符数变了才写，写了才重画。
      #    和 loop_sig 同一个形状 —— 读的一侧必须 isolate（同时读又写同一个
      #    值会自激）。
      if (is_cur) {
        sig <- sprintf("%d|%d|%s", nchar(st$acc %||% ""), nchar(st$reason %||% ""),
                       if (isTRUE(rv$thinking)) "t" else "-")
        if (!identical(sig, isolate(stream_sig()))) stream_sig(sig)
      }

      if (isTRUE(res$done)) {
        st$llm <- NULL
        # ⚠️ 收尾这一段里的显示层写操作**全部**要过 is_cur。后台那个对话
        #    跑完时把 rv$streaming 置 FALSE 会把用户正在看的那个对话的
        #    转圈停掉（而他那个还在生成）—— 反过来也一样。
        if (is_cur) {
          rv$streaming <- FALSE
          rv$thinking <- FALSE
        }
        # ★ 叫醒泵的那一拍结束了一个 —— 万一这是最后一个，下一拍 live_runs()
        #   就空了，泵会就地返回。run_ver 让"再起来一轮"能重新叫醒它。
        run_ver(isolate(run_ver()) + 1L)

        full <- st$acc
        reason_txt <- st$reason
        # ★★ V15.5 item 7：出错要**当场**说，而且要说进对话里。
        #
        #   用户原话：「内容输出时遇到上下文长度的问题，请立即给出反馈，
        #   而不是在下一次发送消息时才告知用户」。
        #
        #   改之前：res$error 只写进 rv$error（一个**服务端内存里的**
        #   reactiveVal），界面上就是把原来那条错误气泡重画一下。三个后果：
        #     · 刷新页面就没了 —— rv$error 从来不落库；
        #     · agent 循环那边 `is.null(res$error)` 一挡，循环直接停在
        #       generating 上不动，用户看到的是"AI 卡住了"；
        #     · 上下文类错误和别的错误长得一模一样，用户不知道该改什么。
        #
        #   现在：上下文类错误当场 showNotification + **合成一条说明落库**
        #   （刷新之后还在，而且模型下一轮也读得到"上一轮是因为超上下文才没
        #   发出去的"）；同时把厂商说的真实窗口学下来（第四层），下一条消息
        #   就按新的算。
        #
        # ★★ Test_V15.7 item 1：上面那套**只有上下文类**错误有。
        #
        #   用户原话：「user1@example.com这个账号依然是卡住的，任何操作都会
        #   引起页面不响应」。查下来那个账号配的智谱 Key 被厂商**每一次**都拒
        #   （HTTP 429：余额不足或无可用资源包,请充值。），而余额不足这类错误
        #   当时既没有通知、也不落库 —— 对话里只剩下 4 条「继续」和 1 条
        #   「你好」，后面一条回复都没有，看起来就是"发了没反应、页面卡住"。
        #
        #   现在判据换成 dsapp_llm_error_advice()：**任何**非空的厂商报错都
        #   归类、都当场说、都落库（认不出来也照样带着厂商原话落库）。
        #   上下文那一类在它内部原样复用 dsapp_ctx_error_advice()，
        #   包括窗口学习和文案 —— 这里一个字都不用改。
        err_adv <- NULL
        if (!is.null(res$error)) {
          if (is_cur) rv$error <- res$error
          err_adv <- tryCatch(
            dsapp_llm_error_advice(res$error, st$ctx_plan),
            error = function(e) NULL)
          if (!is.null(err_adv)) {
            # ① 学下来：厂商这一次明说了窗口多大。写库 + 进程内当场生效。
            #    ⚠️ 只有上下文那一类才有 `window`，别的类恒为 NULL，
            #       这一挡同时兼作"这段只对 ctx 生效"。
            #    ⚠️ **只往紧里收**。dsapp_param_learn() 本身是覆盖式的，
            #       学到个更大的数它照样记 —— 而"这次报错了"恰恰证明真实的
            #       窗口**不比**我们刚才按的那个大。记大等于没学到，而且下次
            #       还会先按大的算一遍再撞一次墙。
            if (identical(err_adv$kind, "ctx") &&
                !is.null(err_adv$window) &&
                err_adv$window < (st$ctx_plan$limit %||% Inf)) {
              try(dsapp_param_learn(
                state$vendor, state$model, "context_length",
                max_value = err_adv$window, source = "provider_400",
                note = substr(gsub("[\r\n\t]+", " ", res$error), 1L, 200L),
                con = dsapp_db(cfg())), silent = TRUE)
            }
            # ② 当场说。duration = NULL 表示**不自动消失** —— 这一条是
            #    "这一轮什么都没发生"，用户必须看见它，而不是低头两秒就没了。
            #    ⚠️ 走 run_notify：后台那个对话出错时要说清楚是哪个对话。
            run_notify(r, err_adv$notify, type = "error", duration = NULL)
            # ③ 落库。合成成一条 assistant 消息 —— 这样刷新之后还在，
            #    而且模型下一轮读历史时会看到"上一轮为什么没发出去"。
            #    ⚠️⚠️ 落的是 **r$sid**，不是 rv$session_id！item 2 之后这两
            #       个随时可以不是一回事（用户切走了），写成 rv$session_id 的话
            #       后台那个对话的报错会插进**用户正看着的**对话里。
            if (!is.null(r$sid)) {
              mid_err <- tryCatch(
                dsapp_db_retry(function()
                  db_message_add(r$sid, "assistant", err_adv$msg,
                                 con = dsapp_db(cfg()))),
                error = function(e) NULL)
              if (!is.null(mid_err)) {
                hist_ver(isolate(hist_ver()) + 1)
                sess_ver(isolate(sess_ver()) + 1)
              }
            }
            # ⚠️ 这里**不往 full 里拼**。上面已经把它单独落库了，拼进去的话
            #    下面那段"有正文就落库"会把它再存一遍 —— 同一条说明在对话里
            #    出现两次，而且第二次带着前半截失败的回答，看起来像两条消息。
            #    界面那边靠上面那两下 hist_ver/sess_ver 重画，读的是库，
            #    所以用户当场就能看到它。
          }
        }

        # 结束原因。"length" = 服务端在 max_tokens 处掐断了，最后那个代码
        # 围栏很可能是半截的。手动模式下提示用户别直接执行；agent 模式下
        # 由循环接管（不执行，回喂一条「被截断」让模型重发）。
        st$finish_reason <- res$finish_reason %||% NULL
        if (identical(st$finish_reason, "length")) {
          run_notify(r,
            "上一条回复达到长度上限被截断，末尾的代码可能不完整，请确认后再执行",
            type = "warning", duration = 10)
        }

        # ---- 流被掐断 / 只回了一点点 --------------------------------------
        #
        # 2026-09-14 加的。用户报的是「这个会话光消耗 token，不会返回结果」，
        # 查下来（会话 s-20260912215607-5136）最后一条回复只有 30 个字，正文
        # 停在半个词上（"…但上一步没跑完\n\n链"），而落库的 finish_reason 是
        # **"stop"** —— 判不出任何异常，应用一声不吭，用户只能反复重问。
        #
        # DeepSeek 的 SSE 会被 CDN 在响应中途掐断，掐断的样子和正常结束一模
        # 一样（连接正常关闭、HTTP 200），区别只在于**没有 `data: [DONE]`**。
        # 所以判据是下面这两条，缺一不可：
        #
        #   cut_off —— 既没收到 [DONE]、也没有 finish_reason。厂商明确告诉过
        #     我们"结束了"的时候不报，避免误伤那些本来就不发 [DONE] 的厂商
        #     （不发 [DONE] 是很常见的实现差异，单凭这一点报警会天天误报）。
        #
        #   barely  —— finish_reason 说是正常结束，但正文短得不合理，而思考
        #     过程很长。这一条是为上面那个真实案例兜底的：服务端说 "stop"，
        #     我们只能从"这不像是答完了"反推。阈值取得保守（<100 字配 >1500
        #     字思考），宁可漏报也不要在正常的一两句回答上弹警告。
        cut_off <- isFALSE(res$complete) && is.null(st$finish_reason)
        # ⚠️ `nchar(...) > 0` 这个下界不能省。正文**完全为空**是下面
        #    「只有思考、没有正文」那条分支管的事，它会合成一条完整的说明；
        #    这里要是把空正文也认下来，就会先往空串后面接一段话，等轮到下面
        #    那条分支时 `!nzchar(full)` 已经变成 FALSE —— 两条都不走了。
        bare    <- nchar(trimws(full))
        barely  <- !cut_off && !nzchar(res$error %||% "") &&
                   bare > 0L && bare < 100L && nchar(trimws(reason_txt)) > 1500L
        if (cut_off || barely) {
          # 把说明**写进正文**一起落库。只弹通知是不够的：通知几秒就没了，
          # 用户回头翻这个会话，看到的仍然是一条莫名其妙断掉的回复。
          full <- paste0(
            full,
            if (nzchar(trimws(full))) "\n\n---\n\n" else "",
            if (cut_off) {
              paste0("**⚠️ 这条回复没有生成完。**\n\n",
                     "服务端在写完上面这些之后就断开了，",
                     "应用没有收到结束标记（`[DONE]`）—— ",
                     "多半是网络或厂商服务端中途掐断了流。\n\n")
            } else {
              paste0("**⚠️ 这条回复短得不正常。**\n\n",
                     sprintf("模型写了几千字的思考过程，正文却只有 %d 个字。", bare),
                     "服务端把这次生成报成了「正常结束」，所以这不是长度上限的问题，",
                     "多半也是中途断了。\n\n")
            },
            "**怎么办：**\n",
            "- 直接回一句「继续」，让它接着上面写；\n",
            "- 如果反复这样，换一个模型（左栏「模型服务」页）或过一会儿再试 —— ",
            "这种中断通常和厂商当时的负载有关。\n\n",
            "这一轮的思考过程已折叠保存在这条消息上方，可以展开看它想到哪一步。")
          run_notify(r,
            if (cut_off) {
              "上一条回复被中途掐断了（没收到结束标记），内容可能不完整。回一句「继续」可以接着写。"
            } else {
              "上一条回复短得不正常，多半是中途断了。回一句「继续」可以接着写。"
            },
            type = "warning", duration = 15)
        }

        # ---- 只有思考、没有正文 ------------------------------------------
        #
        # 思考模式下思维链**也算进 max_tokens**，高强度思考能一口气把额度
        # 吃光（线上实测 completion_tokens = reasoning_tokens = 8192，
        # finish_reason = "length"），正文一个字都没轮到写。
        #
        # 不处理的话这里是最糟的一种表现：等了几分钟，界面上转过"正在思考"，
        # 然后**什么都没有** —— 正文为空所以不落库，思考过程本来就不落库，
        # 用户面对一个空白的对话，只能得出"这应用坏了"。所以这里合成一条
        # 说明落库，并把思考过程一起存下来（气泡里可折叠展开）。
        if (!nzchar(trimws(full)) && nzchar(trimws(reason_txt))) {
          # ★ V13.14 item 22：上限是"平台设的"还是"厂商截的"要说清楚 ——
          #   后者给不出"把上限调大"这种建议，那是用户照着做也做不出来的。
          # ★ V15.5 item 6：读的是**这一轮真正发出去的**回复上限
          #   （dsapp_ctx_plan 推出来的），不是用户填的单次使用上限 ——
          #   这句说明要告诉用户"回复是被哪个数截断的"，那个数是推导值。
          #   ⚠️ 没发过请求时 st$ctx_plan 是 NULL，退回 state 里那个上限。
          #   ⚠️⚠️ 判据是 `state$ctx_limit`，**不是** `mt_now`。mt_now 是推导
          #      出来的回复额度，它永远是个正数，拿它去判会是恒 FALSE ——
          #      "跟随模型"那一段建议就成了永远走不到的死代码，而界面上
          #      完全看不出来（用户只会看到一句叫他去调一个已经顶到窗口的
          #      数的话，照着做也做不出来）。上一版这里就是这么写错的。
          mt_now <- st$ctx_plan$out %||% state$ctx_limit
          unlim <- dsapp_maxtok_is_unlimited(state$ctx_limit)
          full <- paste0(
            "**这一轮没有产出正文。**\n\n",
            if (identical(st$finish_reason, "length")) {
              if (unlim) {
                paste0("模型的思考过程用完了**厂商那边的**长度上限",
                       "（平台这一侧这一轮还没定出限额），还没开始写正文",
                       "就被截断了。\n\n")
              } else {
                sprintf(paste0("模型的思考过程用完了**这一轮给回复的额度**",
                               "（%s tokens，由「单次使用上限」减掉上下文之后",
                               "算出来的），还没开始写正文就被截断了。\n\n"),
                        dsapp_fmt_maxtok(mt_now))
              }
            } else {
              "模型这一轮只产出了思考过程，没有写正文。\n\n"
            },
            "**怎么办：**\n",
            if (unlim) {
              paste0("- 把「思考强度」调低；\n")
            } else {
              paste0("- 到「模型服务」页把「单次使用上限」调大（它就是回复额度",
                     "的来源，建议 65536 以上），或者把「思考强度」调低；\n")
            },
            "- 也可以把问题拆小一点，再问一次。\n\n",
            "这一轮的思考过程已折叠保存在这条消息上方，可以展开看它想到哪一步。")
          run_notify(r,
            if (unlim) {
              "这一轮只产出了思考过程、没有正文。多半是厂商那边的长度上限被思考用光了，把「思考强度」调低试试。"
            } else {
              "这一轮只产出了思考过程、没有正文。多半是「单次使用上限」留给回复的额度被思考用光了，到「模型服务」页调大即可。"
            },
            type = "warning", duration = 15)
        }
        # token 用量：服务端只在这最后一拍给出来（流式响应里 usage 是
        # 最后单独一个 chunk，前面拿不到），顺手记下给界面显示。
        # 累计数按数值加，不用拼字符串 —— 显示格式以后要改也不用动这里。
        if (is_cur) rv$usage <- dsapp_usage_text(res$usage)
        u <- dsapp_usage_numbers(res$usage)
        # ⚠️ 累加的是**这个对话**的用量（st 此刻就是 r），不是全局的。
        if (!is.null(u)) st$tokens <- st$tokens + u$total

        # 落库。**必须 tryCatch**：这一刻用户正盯着那条刚写出来的回复，
        # 统计写不进去（库锁超时、磁盘满）绝不能连带把回复毁掉 ——
        # 用量是运营数据，回复是用户的劳动成果。
        #
        # 放在 st$started <- NULL **前面**：它后面紧接着是落正文那条路径，
        # 中间一旦 return 或抛异常，这一轮的用量就丢了。
        tryCatch(
          # ⚠️ r$sid（这个对话），不是 rv$session_id（屏幕上那个）
          db_usage_add(state$user_id, r$sid, res$usage,
                       scene = st$scene %||% "", model = state$model %||% "",
                       con = dsapp_db(cfg())),
          error = function(e) NULL)
        st$started <- NULL

        # 出错或正常结束，已生成的内容都照样落库，别让用户白等
        mid <- NULL
        if (nzchar(trimws(full)) && !is.null(r$sid)) {
          mid <- tryCatch(
            dsapp_db_retry(function()
              db_message_add(r$sid, "assistant", full,
                             reasoning = reason_txt, con = dsapp_db(cfg()))),
            error = function(e) {
              run_notify(r,
                dsapp_err_user(e, "保存这次的回复",
                               hint = "回复已经在上面显示出来了，只是没存进历史。可以再发一次。"),
                type = "error", duration = 10)
              NULL
            })
          # ⚠️ 读的那一侧 isolate()。这两个**只是通知**（让消息列表/侧栏重画），
          #    本 observe 不需要依赖它们。不 isolate 就是白搭一次自失效 ——
          #    幸好写完之后这个 run 的 llm 已经是 NULL，下一轮 live_runs()
          #    就不带它了；但那是**碰巧**，不是设计。
          #    ⚠️ 这两下**不管是不是当前对话都要发**：侧栏要给那个对话刷出
          #       新消息，用户切回去才看得到（hist_ver 是全局的显示脉冲，
          #       不是"当前对话专属"）。
          hist_ver(isolate(hist_ver()) + 1)
        }
        st$acc <- ""
        st$reason <- ""
        if (is_cur) draft("")
        sess_ver(isolate(sess_ver()) + 1)

        # ---- agent 循环的入口 ----
        #
        # 放在最后：这一轮的内容必须已经落库（循环要照着库里的消息决定执行
        # 什么），流式状态也必须已经复位（循环紧接着要发起下一轮生成，
        # rv$streaming 还停在 TRUE 的话发送闸门会把它挡回去）。
        #
        # ⚠️★ V13.5 item 1：判据是 `can_loop()`，**不是** `enabled`。
        #    "AI 自己接手排查报错"这一路（agent.R 的 kick_env_fix）在
        #    「自动执行」关着的时候也要能走完一整圈 —— 它把 armed 置真、
        #    叫起模型，模型回的那一轮必须回到这里才算落地。这里仍然写
        #    `enabled` 的话，那一轮会变成一条普通的聊天消息，模型说了什么
        #    都不会被执行，看起来就是"AI 查了半天什么也没干"。
        # ⚠️★ V15.5 item 7：API 出错时**必须把这个循环停掉**。
        #    `is.null(res$error)` 那一挡原来只做到"不把结果喂回去"，
        #    而循环本身还在 running 状态上等一个永远不会来的 on_llm_done ——
        #    用户看到的是"AI 一直在生成"，而它其实早就死了。
        #    上下文类的错误尤其要停：它下一轮必然撞同一堵墙，重试只是白烧
        #    token，而且每一轮都失败得更慢。
        #
        # ⚠️⚠️ Test_V15.7 item 2：这一段里的循环必须是**这个 run 自己的**
        #    （st$agent，而 st 在这一段里就是 r），而且 on_llm_done 还得确认
        #    这一轮就是那个循环在等的。
        #
        #    改之前不可能出错：切对话就 abort，同时只有一个循环。item 2 之后
        #    用户在 B 里手动发一条消息、A 的循环正好 active —— `st$agent` 是
        #    B 的（NULL），这道闸挡住了；但反过来（A 的循环 active，B 那一轮
        #    结束）时，若不比 sid，B 的正文会被喂进 A 的循环，A 会照着 B 的
        #    回答去执行代码。不报错，只是执行了完全无关的东西。
        #
        # ★★★ Test_V16.5 item 1：这里**不能**只读 `r$agent`，勾着的时候
        #    要就地把它建出来（`agent_of()` 就是那个懒建入口，有了就直接
        #    返回，见它自己的说明）。
        #
        #    为什么：循环是"一个对话一个、懒建"的，而它**唯一**的新建入口
        #    是「自动执行」那颗勾的 observeEvent —— 那一刻 `st` 指着的 run
        #    未必就是**这个**对话：
        #      · 用户在还没有对话的页面上勾的「开启」（rv$session_id 还是
        #        NULL、st 指着空壳 run），然后才发第一条消息：建对话走
        #        use_run(sid) 换到**另一个** run 对象，勾出来的那个 agent
        #        留在空壳上，它的钩子读的也永远是空壳（sid 恒为 NULL）；
        #      · 勾着「开启」从 A 切到 B：B 的 run 上从来没人建过。
        #    两种情形的表现一模一样 —— **勾着「自动执行」，模型回了一段带
        #    代码块的方案，然后什么都不执行**，而且状态条那行小字也不出现
        #    （`ctrl_notes` / `loop_sig` 读的都是 `st$agent`）。V16.4 同一行
        #    也是这么写的：不是这一版引入的（老探针都是在"已经有对话"之后
        #    才去勾那颗勾，所以一直没被走到）。2026-10-05 由
        #    tests/ui_v165/probe_iter.py 第 ⑤ 节抓到，埋点原话：
        #      GATE a_null=TRUE r_sid=s-…-0918 can_loop=NA
        #      （同一拍里 st$agent 也在，只是长在另一个 run 上）
        #
        #    ⚠️ 开关**关着就不建**：新建对话默认不带循环这条不能变。
        #      判据走 agent_mode_now()（"开启"那个勾唯一的真相源），包上
        #      isolate —— 裸读会在泵（这个 observe）上挂一条 input 依赖，
        #      以后每点一下那颗勾都白推一拍。
        #    ⚠️ `agent_of()` 必须在响应式上下文里调（它要 isolate(input$*)
        #      并注册心跳）—— 这里是 pump_run，本来就是 observe 里的一拍。
        a <- r$agent
        if (is.null(a) && isTRUE(isolate(agent_mode_now()))) a <- agent_of(r)
        # ⚠️⚠️ `a$sid` 起手**必然是 NULL** —— 它只在 `on_llm_done()` 的 idle
        #    分支里才被写上（agent.R：「已经在跑就说明这一轮是循环自己发起的，
        #    不是新的一轮用户请求」那一支的 else 里）。拿它跟 r$sid 比，等于
        #    要求"循环先跑起来"才肯放行"让循环跑起来"——**第一轮永远进不去**。
        #
        #    2026-10-02 实测（probe_v157 B 节，埋点打出来的原话）：
        #      a_null=FALSE a_sid=<NULL> r_sid=s-…-2225 mine=FALSE can_loop=TRUE
        #    —— 开关勾着、agent 也在、循环也想跑，就卡在这一行。症状是
        #    「勾了自动执行，AI 回了一段带代码块的方案，然后什么都不执行」，
        #    三条断言全红在同一个根因上，而它们看起来像三件事。
        #
        #    闸门要防的是"**别人**那一轮的正文被喂进这个已经在跑的循环"，
        #    所以：没跑过（sid 为 NULL）就放行（它只可能属于持有它的这个 run，
        #    `agent_of()` 是 `r$agent <- a`，一个 run 一个），跑过就必须对得上。
        mine <- !is.null(a) &&
          (is.null(a$sid) ||
             identical(as.character(a$sid), as.character(r$sid)))
        if (!is.null(res$error)) {
          if (mine && isTRUE(a$can_loop())) {
            a$stop(if (identical(err_adv$kind, "ctx"))
                     "上下文超出模型窗口，循环已停止"
                   else
                     paste0("模型调用失败，循环已停止：",
                            substr(as.character(res$error)[1], 1L, 120L)))
          }
        } else if (mine && isTRUE(a$can_loop()) && !is.null(r$sid)) {
          a$on_llm_done(full, st$finish_reason, mid, cut_off = cut_off)
        }
      }
      invisible(TRUE)
    }

    # ★★ V15.3 item 3：思考过程的实时预览（**改写**，原来是每 200ms 重画一次）
    #
    # 用户原话：「现在对话框思考时还是会闪，不要闪，正常往外输出思考过程就行
    # 了」。改之前它是一格 renderUI，依赖 rv$thinking —— 而流式泵每 200ms
    # **无条件**写一次 rv$thinking <- TRUE（写 reactiveVal 就算值没变也会失效
    # 下游，本仓已知），于是这一格的 HTML 每 200ms 被整块换掉一次：用户展开
    # 的 <details> 被折回去、<pre> 的滚动位置归零。看起来就是一直在闪。
    #
    # 现在的分工：
    #   · **骨架**（这一格）只在"新的一轮开始了"时画一次 —— 依赖 think_gen，
    #     一个每轮 +1 的粗粒度计数（见下面的流程泵，写它的地方只有一处）；
    #   · **正文**由 www/app.js 的 dsapp:think 处理器往 <pre> 里贴，
    #     走 session$sendCustomMessage，**不经过任何 renderUI**。
    #
    # ⚠️ 骨架里**不带正文**。带了的话，每次重画都会把已经贴进去的内容重置成
    #    服务端那一刻的快照，而快照和浏览器里那份总会差上一拍 —— 症状是
    #    "思考过程末尾一直在往回缩"。正文只有 app.js 一个写入者。
    #
    # ⚠️ `open`：用户要的是「正常往外输出思考过程就行了」，所以默认展开。
    #    折叠是历史消息（dsapp_msg_bubble 里的 reason_box）那一档的事 ——
    #    那里动辄几千字，铺开会把正文挤到屏幕外；这里是**正在写**的过程，
    #    用户正盯着它看，折起来等于没有。
    output$thinking_box <- renderUI({
      think_gen()   # 依赖：**只有**"新的一轮"才让这一格重画
      if (!isTRUE(rv$streaming)) return(NULL)

      div(class = "dsapp-msg dsapp-msg-assistant",
        div(class = "dsapp-bubble",
          div(class = "dsapp-thinking",
            icon("brain", class = "me-1"),
            # ⚠️ 这两个节点**只由 app.js 改文本**（textContent），不重画。
            #    id 是给 app.js 定位用的，改名要同步改 app.js 里的选择器。
            span(id = ns("think_label"), "正在思考…"),
            span(class = "text-muted ms-2 small", id = ns("think_n")),
            tags$details(class = "mt-1 dsapp-think-d", open = "open",
              tags$summary(class = "small text-muted", "思考过程"),
              tags$pre(class = "dsapp-preview-pre mt-1 dsapp-think-pre",
                       id = ns("think_pre"))))))
    })

    # ★★ V15.4 item 3：正文还没开始时的占位（转圈 + 活人感提示词）
    #
    # 用户原话：「思考的时候还是在闪屏，要求去掉闪屏动画。并在思考的时候加个
    # 转圈的图案，提示用户"模型正在思考"？或者加一些有活人感的提示词」。
    #
    # 「闪」的**根**不在动画本身，在这一格的**重画频率**：改造前它长在
    # output$streaming 的"正文还没开始"那一支里，而那一格依赖 draft()，
    # 流式泵每 200ms 无条件写一次 draft("")（写 reactiveVal 就算值没变也会
    # 失效下游，本仓已知）—— 于是这颗 spinner 每 200ms 被拆掉重建一次。
    # CSS 动画是**跟着元素走**的：元素一换，旋转就从 0 度重新开始。用户看到
    # 的不是"在转"，是"一直在抖"。同理，改造前那里那个 .dsapp-cursor 的
    # blink 动画也是被这样反复归零的。
    #
    # 所以这一格的依赖只有三个**粗粒度**信号，一轮里最多重画 3 次：
    #   · think_gen()       —— 新一轮开始（+1 的唯一写入点见 dsapp_llm_begin）
    #   · rv$streaming      —— 本轮开始 / 结束
    #   · rv$text_started   —— 正文第一个字到了，占位该让位了
    # ⚠️ 这里**不许**读 draft()、stream_sig()、agent_ver()、arun_tick()。
    #    读到任何一个，上面那段推理就全部作废，闪屏原样回来。
    # ⚠️ 这里也**不许**调 run_actions_ui()：action_host() 读了 agent 循环的
    #    心跳（每秒一跳），挂在这里等于让 spinner 每秒重建一次。按钮在下面
    #    单独一格（output$stream_actions）。
    #
    # ⚠️ 提示词只有 app.js 一个写入者（同 think_pre 那条规矩）。骨架里那个
    #    span 是**空的**，每轮换一句由前端 setInterval 做 —— 走服务端轮换
    #    等于把刚拆掉的 200ms 重画又装回来。
    output$wait_box <- renderUI({
      think_gen()             # 依赖①：新一轮
      if (!isTRUE(rv$streaming)) return(NULL)   # 依赖②：本轮
      if (isTRUE(rv$text_started)) return(NULL) # 依赖③：正文已开始
      div(class = "dsapp-msg dsapp-msg-assistant",
        div(class = "dsapp-bubble dsapp-wait-box",
          # `data-quips` 是给 www/app.js 的轮换器读的（分隔符见
          # R/utils.R 的 DSAPP_THINK_QUIP_SEP）。写成属性而不是十个节点：
          # 属性不占 DOM，也不参与重画。
          div(class = "dsapp-wait",
            div(class = "spinner-border spinner-border-sm dsapp-wait-spin",
                role = "status"),
            tags$span("正在生成…")),
          # ⚠️ 这个节点的文本**只由 app.js 改**（textContent）。id 是给
          #    app.js 定位用的，改名要同步改 app.js 里的选择器。
          span(class = "dsapp-quip", id = ns("think_quip"),
               `data-quips` = paste(DSAPP_THINK_QUIPS,
                                    collapse = DSAPP_THINK_QUIP_SEP))))
    })

    # ★★ V15.4 item 3：三颗动作按钮里那个「stream」宿主的挂载点。
    #
    # 它原来长在 output$streaming 的气泡**里面**。搬出来的理由和占位气泡
    # 一模一样：那一格每 200ms 重画，挂在里面的东西跟着一起被拆掉重建 ——
    # 按钮自己不动画，看不出来，但它们**每秒被换掉五次**，用户点「停止」时
    # 手指底下的节点正在被替换（mousedown 和 mouseup 落在两个不同的元素上，
    # click 根本不触发）。搬出来之后它只跟着 action_host() 走。
    #
    # ⚠️ 任何时刻这一组按钮只能渲染一份 —— action_host() 指到别处时这里返回
    #    NULL，所以不会和 live / hist / detach 那三处同时出现。
    output$stream_actions <- renderUI({
      a <- run_actions_ui("stream")
      if (is.null(a)) return(NULL)
      div(class = "dsapp-stream-actions", a)
    })

    # 有新内容就滚到底部
    #
    # ★ V13.9 item 2：这一句**不再是**"防跳顶"的主力 —— 光靠它做不到。
    #   它是独立的一条 websocket 消息，跑到的时候 Shiny 往往还没把新内容换
    #   进 DOM：它按旧内容算出"用户在底部"、滚到底，紧接着内容一换又弹回
    #   顶部。真正的收口在 www/app.js 的看护器里（它在重渲染**之后**才决定
    #   往哪儿滚），这里只负责把"跟不跟"这个意图传过去。
    observe({
      draft(); hist_ver(); rv$error
      session$sendCustomMessage("dsapp:scroll", list(id = ns("scroll")))
    })

    # ★ V13.9 item 2：换对话要**强制**到底部。
    #
    #   用户原话：「会话不要总是刷新到顶部」。看护器默认"用户在翻历史就别动
    #   他"，而这条规则在换对话时是错的 —— 上一个对话读到一半的位置，和
    #   新打开的对话没有任何关系，照搬过去就是"打开一个新对话，人却停在
    #   中间"。所以换对话是少数几个要说 force 的地方之一。
    observeEvent(rv$session_id, {
      session$sendCustomMessage("dsapp:scroll",
                                list(id = ns("scroll"), force = TRUE))
    }, ignoreInit = TRUE)

    # ---- 代码执行 ----
    #
    # 浏览器只发来 "消息id:块序号" 这样的坐标。代码内容从这里回数据库重取、
    # 重新解析、重新扫描 —— 见 jobs.R 里 dsapp_extract_block() 的说明。
    observeEvent(input$code_action, {
      cid <- input$code_action
      req(cid)

      parts <- strsplit(as.character(cid), ":", fixed = TRUE)[[1]]
      mid <- suppressWarnings(as.integer(parts[1]))
      idx <- suppressWarnings(as.integer(parts[2]))
      if (length(parts) != 2 || is.na(mid) || is.na(idx) || idx < 1) {
        showNotification("无效的执行请求", type = "error")
        return()
      }

      sid <- rv$session_id
      if (is.null(sid)) {
        showNotification("没有打开的对话", type = "error")
        return()
      }

      # 只能在当前对话内取消息：坐标越界就拒绝，不做任何"猜测"
      msgs <- db_messages_get(sid, con = dsapp_db(cfg()))
      hit <- which(msgs$id == mid)
      if (length(hit) == 0) {
        # ★ V13.7 item 2：这一条是**界面比库旧**（另一个页签里把这段对话
        #   改过/删过），不是用户做错了什么。重新拉一遍历史就是 F5 会做的事，
        #   平台自己做完 —— 原来那句「请刷新页面后重试」把平台的缓存陈旧
        #   说成了用户的待办。
        dsapp_notify_stale("这条消息",
                           refresh = function() hist_ver(hist_ver() + 1L))
        return()
      }

      blk <- dsapp_extract_block(msgs$content[hit[1]], idx)
      if (is.null(blk)) {
        dsapp_notify_stale("这个代码块",
                           refresh = function() hist_ver(hist_ver() + 1L))
        return()
      }

      # 扫描在这里也要做一遍：dsapp_extract_block 取到的是数据库里的内容，
      # 未必和浏览器上显示的那份一致。
      scan <- dsapp_scan_code(blk$code)
      if (nrow(scan$blocked) > 0) {
        showModal(modalDialog(
          title = "已拒绝执行",
          tags$p("这段代码命中了高危指令，平台不会执行它："),
          tags$pre(class = "dsapp-pre dsapp-pre-err", dsapp_scan_message(scan, md = FALSE)),
          easyClose = TRUE
        ))
        return()
      }

      if (nrow(scan$warnings) > 0) {
        st$pending <- blk
        # 坐标要一起带过去：用户在弹窗里点「仍然执行」时，那段代码才知
        # 道自己是哪张卡片（V8 item 6）。
        st$pending_cid <- cid
        showModal(modalDialog(
          title = "确认执行",
          tags$p("这段代码没有命中高危规则，但有以下情况需要你确认："),
          tags$pre(class = "dsapp-pre", dsapp_scan_message(scan, md = FALSE)),
          easyClose = FALSE,
          footer = tagList(
            modalButton("取消"),
            actionButton(ns("do_run"), "仍然执行", class = "btn-warning")
          )
        ))
        return()
      }

      dsapp_chat_run(blk, cid = cid)
    })

    # 警告级：用户在弹窗里点了"仍然执行"
    observeEvent(input$do_run, {
      blk <- st$pending
      cid <- st$pending_cid
      st$pending <- NULL
      st$pending_cid <- NULL
      removeModal()
      if (is.null(blk)) return()
      dsapp_chat_run(blk, cid = cid)
    })

    # ---- 失败卡片上的「重试这一步」（★ V15.4 item 2 前半）--------------------
    #
    # 用户原话：「你看下最新的"绘制国旗"，任务，报错了，但是却并没有告诉用户
    #           做操作和选择」。
    #
    # 那颗按钮在**历史卡片**上（`R/render.R` 的 dsapp_retry_btn），手上只有
    # 一个任务号，别的什么都没有 —— 代码要从库里回取。这和「历史任务」页的
    # 重跑（R/mod_tasks.R 的 input$rerun）是同一件事，所以走**同一条路**：
    # `engine$start(code, lang, …)`，静态扫描那一层在 engine 里面（见
    # mod_tasks.R 顶部的三层防线说明），结果也一样写回这条对话。
    #
    # ⚠️ 三条自我约束，和任务页那条一模一样，理由不再重复：
    #    1. 只认**本对话**的任务行（t$session_id 对不上就拒绝）——
    #       卡片是画在这条对话里的，但消息可以被共享/迁移，不能想当然；
    #    2. 忙的时候不提交（engine$is_busy()），否则用户点两下排两个；
    #    3. 代码是空的就说清楚（老任务的 code 列可能是空的），
    #       而不是提交一个空脚本然后报一个看不懂的错。
    #
    # ⚠️ 这里**不走** dsapp_chat_run()：那条路第一句就是"目标是本机就改成
    #    导出"，而"重试"的语义是**再跑一遍**，不管用户此刻把执行目标切成了
    #    什么。走 dsapp_chat_run 的话，切到「本机」之后点重试会静默变成
    #    "导出一份脚本"，而用户以为它跑了。
    observeEvent(input$task_retry, {
      tid <- suppressWarnings(as.integer(input$task_retry))
      if (is.na(tid)) return()
      sid <- rv$session_id
      if (is.null(sid)) {
        return(showNotification("没有打开的对话", type = "error"))
      }
      row <- tryCatch(db_task_get(tid, con = dsapp_db(cfg())),
                      error = function(e) NULL)
      if (is.null(row) || !nrow(row)) {
        dsapp_notify_stale("这条执行记录",
                           refresh = function() hist_ver(hist_ver() + 1L))
        return()
      }
      if (!identical(as.character(row$session_id %||% ""),
                     as.character(sid))) {
        return(showNotification(
          sprintf("任务 #%d 不属于这条对话，去「历史任务」页重跑它。", tid),
          type = "warning", duration = 8))
      }
      if (engine$is_busy()) {
        return(showNotification("已有任务在执行，等它跑完再重试这一步。",
                                type = "warning", duration = 8))
      }
      code <- as.character(row$code %||% "")[1] %||% ""
      lang <- as.character(row$lang %||% "R")[1] %||% "R"
      if (!nzchar(trimws(code))) {
        return(showNotification(
          sprintf("任务 #%d 没有留下代码（平台提示那类不算任务），没法重跑。", tid),
          type = "warning", duration = 8))
      }

      res <- engine$start(code, lang,
                          session_id = sid,
                          target = dsapp_current_target(),
                          user_id = state$user_id)
      if (!isTRUE(res$ok)) {
        return(showNotification(res$msg, type = "error", duration = 8))
      }
      # 和 dsapp_chat_run() 同一个套路：记下"这次跑完该写回哪条对话、
      # 挂了该把谁叫起来"。上面那个 observeEvent(engine$state$running) 认的
      # 就是这个 manual_run。
      manual_run(list(tid = res$task_id, sid = sid, lang = lang))
      showNotification(
        sprintf("已重新提交任务 #%d，结果会写回这条对话", res$task_id),
        type = "message", duration = 6)
    })

    # 任务跑完（或被停掉、被中止）之后把转圈撤掉，按钮回来。
    #
    # 光靠 dsapp_chat_run 里那次赋值不够：任务是在引擎的子进程里跑的，
    # 结束这件事只体现在 engine$state$running 上。没人看着它的话，卡片上
    # 的转圈会一直转下去 —— 那比不显示更糟，用户会以为任务卡住了。
    observeEvent(engine$state$running, {
      if (isTRUE(engine$state$running)) return()
      run_cid(NULL)

      # V9 item 2：手动执行跑完了，把结果写进对话。
      #
      # ⚠️ 凭据**先取后清**。写消息那一段要读库、要拼字符串，中间任何一步
      #    报错都会让后面的清理执行不到 —— 而 manual_run 留着不清的话，
      #    下一个跑完的任务会被再写一遍（这一次的 tid 是旧的），
      #    对话里出现两条一模一样的执行记录，且看不出哪条是真的。
      m <- manual_run()
      manual_run(NULL)
      if (!is.null(m)) {
        dsapp_write_run_msg(m$tid, m$sid, m$lang)

        # V11 item 8 / ★ V13.5 item 1：手动执行挂了之后，让模型自己接手排查。
        #
        # ⚠️ 必须**排在 dsapp_write_run_msg() 之后**。反过来的话，模型被叫
        #    起来的那一刻对话里还没有那条执行结果，它只能对着空气排查 ——
        #    而表现和"模型瞎编"一模一样，谁也看不出是顺序错了。
        #
        # ⚠️ 判据重新从**库里那一行**取，不用内存里的东西：任务是在引擎的
        #    子进程里跑的，engine$handle 到这里已经被 e$poll() 置空了。
        #
        # ★ V13.5 item 1 去掉了原来的 `isTRUE(env$is_env)` 这一道：
        #   用户的原话是「报错需要AI自己解决」，没有限定"只有缺包才算"。
        #   现在**任何**失败都会试着把模型叫起来。是不是环境问题仍然算出来
        #   了一起带过去 —— 模型据此决定是说"我来装包重跑"还是"这行代码
        #   写错了，我改"，话术在 envfix.R 里。
        #   ⚠️ 但 status 也得看一下：`status = "success"` 的行不是失败，
        #      不能因为"stderr 里有 warning 文本"就把模型叫起来。
        tryCatch({
          row <- db_task_get(m$tid, con = dsapp_db(cfg()))
          if (!is.null(row) && nrow(row) > 0 &&
              !identical(as.character(row$status %||% ""), "success")) {
            env <- dsapp_env_failure(stderr = row$stderr %||% "",
                                     status = row$status)
            # ⚠️ agent_of(**m$sid**)，不是 agent_of(st)。任务行里写着它属于
            #    哪条对话（`m$sid`），而用户这一刻完全可能正看着另一条 ——
            #    把循环起来在"屏幕上那条"上是错的，模型会对着一条和这次报错
            #    毫无关系的对话排查（改之前是单例循环 + rv$session_id，同一个
            #    毛病，item 2 之后有条件改对了）。
            # ⚠️ 循环现在是**懒建**的（见 agent_of 那段说明）。调用点是
            #    observeEvent，在响应式上下文里，符合它要求的条件。
            agent_of(run_of(m$sid))$kick_env_fix(env, m$tid,
              notify = function(msg, type)
                showNotification(msg, type = type, duration = 15))
          }
        }, error = function(e) NULL)
      }
    }, ignoreInit = TRUE)

    # ---- 别的模块发现任务失败时，也把模型叫起来（V11 item 8 / V13.5 item 1）
    #
    # 「历史任务」页点重跑的那一次，结果同样写回对话（见 mod_tasks 的
    # settle_rerun），它挂了的时候也该由 AI 自己修 —— 用户的原话是
    # 「报错需要AI自己解决」，这句话里没说"只对在对话页点的那次生效"。
    #
    # ⚠️⚠️ 两道锁，缺一不可：
    #   1. **必须**是这个对话（sid 对得上）。agent 是挂在"当前打开的这个
    #      对话"上的（st$agent 用 rv$session_id 当工作上下文），从任务页
    #      触发的那次重跑完全可能属于**另一条**对话。不判的话，模型会跑进
    #      一条不相干的对话里去查一个它没见过的报错，而用户看到的是"另一条
    #      对话自己动起来了"。
    #   2. 用请求里带的序号，不用值本身 —— Shiny 对**值相同**的输入不重复
    #      触发 observer，连着两次一样的环境问题（同样缺同一个包）第二次就
    #      发不出来了（同一个坑见 www/app.js 的 dsappNavSeq）。
    observeEvent(state$env_fix_req, {
      r <- state$env_fix_req
      if (is.null(r)) return()
      # ⚠️ 这道闸不能省：这条请求是**任务页**发过来的，它可能属于另一个
      #    对话 —— 而 agent_of() 是懒建的，无脑建的话会在当前这个对话上
      #    凭空起一个循环。
      if (!identical(as.character(r$sid %||% ""), as.character(rv$session_id %||% "")))
        return()
      # ⚠️ 通知发在**这个会话**里，不是任务页那个会话 —— 模型是被这条对话
      #    叫起来的，说明它"接手了"的那句话就得出现在用户正看着的这条对话
      #    上。发到 mod_tasks 那边的话，用户看到的是任务页弹一句、对话页
      #    静悄悄地开始自己动。
      agent_of(st)$kick_env_fix(r$env, r$tid, notify = function(msg, type)
        showNotification(msg, type = type, duration = 15))
    }, ignoreInit = TRUE)

    # 关闭页面时把还在跑的东西停掉，别留孤儿进程
    #
    # ⚠️ 只杀 LLM 子进程是不够的：agent 循环大部分时间在等一个**任务**跑，
    #    而任务跑在引擎的子进程里，那个进程是全局的、不属于这个会话。
    #    不一起停的话，用户关掉页面、循环没了，任务会继续跑到结束 —— 而且
    #    结束后没有任何人把结果回喂给谁，等于白烧一次机器。
    # ★ V13.7 item 5：预设「离开页面之后」在这里分派。
    #
    # 三档（值存在 users.ui_prefs 的 agent_detach，设置在「执行」那一栏）：
    #   off    —— 下面那段原来的行为，一个字不改
    #   finish —— 正在跑的任务交给守护进程跑完，结果写回对话
    #   full   —— 整个循环交给后台进程接着跑
    #
    # ⚠️ 这段代码跑在**会话正在结束**的路上。它做的每一件事都得是
    #    "发出去就不管了"的（起一个 callr 进程、写一行库）—— 任何需要
    #    后续回调、后续响应式刷新的写法在这里都不会再被跑到。
    session$onSessionEnded(function() {
      # ★★ V15.7 item 7：**这一整段跑在响应式上下文之外，`cfg()` 用不了。**
      #
      #   cfg() 就是 `dsapp_config_user(state$user_id, dsapp_config())`（本文件
      #   551 行）—— 它读 state$user_id 的那一刻会去建响应式依赖。而
      #   onSessionEnded 的回调是在会话**已经拆掉之后**才跑的：那里没有响应式
      #   上下文，`$` 一读就抛
      #     Can't access reactive value 'user_id' outside of reactive consumer
      #
      #   ⚠️ 这个抛错**一点都不响**，因为这条路上每一处都包着 tryCatch /
      #      try(silent = TRUE)。症状不是报错，而是"交接悄悄降级成什么都停"：
      #      off / finish / full 三档全部走不通 —— 用户在设置里选的「离开页面
      #      之后一路跑完」从来没生效过，finish 那条「守着任务跑完」也从来没
      #      生效过，连"【平台提示】……循环在此中断"那条 tool 消息都写不进去。
      #      而页面关掉之后本来就没有界面可看，他只会觉得"又断在半路了"。
      #      （实测：tests/ui_v157/probe_disc.py 跑起来之后，给这一段临时加
      #      message() 埋点，app.log 里抓到的是
      #        Can't access reactive value 'user_id' outside of reactive consumer
      #      那一行。埋点已经撤掉，别去代码里找它。）
      #
      #   ✅ isolate() 会自己造一个假上下文，在没有响应式上下文的地方**能用**
      #      —— 上面读 state$user_id 用的就是它，一直在正常工作。所以整份配置
      #      包一层 isolate 取出来，比"照着 cfg() 再拼一份"可靠：用户配置
      #      将来多一个字段，这里不用跟着改。
      #
      #   ⚠️ 下面**所有** cfg() 都要换成 cfg_end。漏一处 = 那一支静默失效，
      #      而且因为包着 tryCatch，界面上、日志里都不会有任何痕迹。
      cfg_end <- tryCatch(isolate(cfg()), error = function(e) dsapp_config())

      # 预设读不出来时按 finish 走：那是三档里最保守的**有用**选项。
      # 读不出来本身就是异常（库锁、user_id 还没落），这时候既不该
      # 硬停（用户可能正指望它跑完）也不该放开了跑（full 会烧钱）。
      det <- tryCatch({
        uid <- isolate(state$user_id)
        if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) "finish"
        else as.character(
          dsapp_uipref_get(uid, con = dsapp_db(cfg_end))[["agent_detach"]]
          %||% "finish")
      }, error = function(e) "finish")

      # ★ V15.7 item 2：一个页面关掉的时候，**可能有好几个对话同时在跑**
      #   （切会话已经不再中断生成了）。原来这里只认 `st` 那一个对话 ——
      #   其余对话的流式请求会变成孤儿：没人轮询它的句柄，token 照烧，
      #   回复永远不落库，用户回来只看到自己那句话孤零零躺着。
      #   所以改成**按 run 逐个**走同一套交接逻辑，每个对话各自算自己的
      #   "循环还活着吗 / 引擎槽里这个任务是不是我的"。
      targets <- list()
      for (k in ls(runs, all.names = TRUE)) {
        r <- runs[[k]]
        if (!is.null(r$llm) ||
            (!is.null(r$agent) && isTRUE(r$agent$active()))) {
          targets[[length(targets) + 1L]] <- r
        }
      }
      # 显示中的那个对话即使此刻什么都没在跑也要过一遍：引擎槽里可能正卡着
      # 它的一个任务（预设里「让当前任务跑完」那一档就是冲它来的）。
      if (!any(vapply(targets, identical, TRUE, y = st))) {
        targets <- c(list(st), targets)
      }

      # ⚠️ 下面那个 `st <- r` 是**故意的**，不是漏改：这一整段交接逻辑是从
      #    "只处理显示中那个对话"的版本原样搬过来的，里面每一处 `st$` 读的
      #    都是"当前这个 run"。函数内赋值在 R 里是**遮蔽**（一旦函数体里出现
      #    `st <- `，该函数体内所有 `st` 都指这个局部变量），碰不到外面的注册表。
      end_run <- function(r, det) {
      st <- r
      loop_alive <- !is.null(st$agent) && isTRUE(st$agent$active())
      # 循环活着就听循环的（它知道自己挂在哪个对话上）；否则就是本 run 的对话。
      sid_now <- tryCatch(if (loop_alive) st$agent$sid else st$sid,
                          error = function(e) NULL)

      # 引擎是全局单槽的：先确认槽里那个任务**属于本对话**，否则后面
      # 无论停它还是守它，动的都是别人的任务（同 do_del_chat）。
      tid_now <- tryCatch(engine$current_task_id(), error = function(e) NULL)
      if (!is.null(tid_now) && !is.null(sid_now)) {
        trow <- tryCatch(db_task_get(tid_now, con = dsapp_db(cfg_end)),
                         error = function(e) NULL)
        if (!isTRUE(dsapp_task_in_session(trow, sid_now))) tid_now <- NULL
      } else {
        tid_now <- NULL
      }

      # ★★ V15.7 item 7：**断线之前已经吐出来的那部分，必须落库。**
      #
      # 线上现场（Biomamba_ceshi / uid=11，2026-10-01，连续四轮一模一样）：
      #   messages 里 user 那条在、assistant **一条都没有**；
      #   data/run/ 里连 .out 都没留下（而 .log/.err 在）。
      #   文件指纹决定性地指向 dsapp_llm_abort() —— 全仓库只有它同时删
      #   .out/.json/.reason —— 而它在这条路上只有一个来历：
      #     页面关掉（含标签页被浏览器冻结后 websocket 掉线、刷新）
      #     → onSessionEnded → 循环没起来 / 引擎槽里没有本对话的任务
      #     → 落到最下面那条兜底 → 掐掉在飞的流。
      #   那一刻 st$acc 里已经吐出来的几千字**没有任何人写进库**，用户回来
      #   只看到自己那句话孤零零躺着，像"发出去就没反应"。短任务没事、长任务
      #   必死，因为窗口只有流刚开始的那几十秒（那时还没有任何任务在引擎里）。
      #
      # 同一个文件里的停止按钮是**存了**的（observeEvent(input$stop)：
      #   "白等了几十秒，不该因为点了停止就丢掉"）。关页面凭什么更狠？它更
      #   被动 —— 用户根本没点任何东西，甚至可能只是切走了标签页。
      #
      # ⚠️ 只在**不会有人再写**的地方存。这就是下面 full 那一段（主动掐流、
      #    后台拿同一份上下文**重新问一次**）不存的原因：存了同一轮会出现两条
      #    助手消息。判据一句话 —— 这一轮的文字，后面还有没有人会写？
      save_partial <- function(why) {
        # ⚠️ paste(x, collapse = "") 而不是直接拿 st$acc：万一它是个长度 >1
        #    的向量，db_message_add 会**插进去好几行**；万一它长度是 0，
        #    `paste0(character(0), "…")` 会变成长度 1 的 "…"（本仓踩过）。
        p <- tryCatch(paste(st$acc, collapse = ""), error = function(e) "")
        if (!is.character(p) || !length(p) || !nzchar(trimws(p))) {
          return(invisible(FALSE))
        }
        s <- sid_now
        if (is.null(s) || !length(s) || is.na(s) || !nzchar(as.character(s))) {
          s <- tryCatch(st$sid, error = function(e) NULL)
        }
        if (is.null(s) || !length(s) || is.na(s) || !nzchar(as.character(s))) {
          return(invisible(FALSE))
        }
        rc <- tryCatch(paste(st$reason, collapse = ""), error = function(e) NULL)
        # ⚠️ 失败**必须留声**。这个 bug 之所以能活这么久，就是因为这条路上
        #    每一处都包着 try(silent = TRUE)：写不进去和"没什么可写"在日志里
        #    长得一模一样，而这一段跑完页面就没了，用户那边也无从对照。
        tryCatch({
          db_message_add(as.character(s), "assistant",
                         paste0(p, "\n\n*（", why, "）*"),
                         reasoning = rc, con = dsapp_db(cfg_end))
          TRUE
        }, error = function(e) {
          message("[dsapp] 断线时的正文没能落库（对话 ", s, "，",
                  nchar(p), " 字）：", conditionMessage(e))
          FALSE
        })
        invisible(TRUE)
      }

      # ---- full：整个循环交给后台 ----------------------------------------
      #
      # ⚠️ 整段包 tryCatch。这里面的每一个读（state$*、dsapp_current_target()）
      #    都在会话正在被拆掉的当口跑，任何一个抛出来都会**跳过下面那段兜底**，
      #    于是任务既没交接出去、也没被停掉 —— 那正是这个功能最坏的失败方式
      #    （用户以为在挂机，其实什么都没跑）。出错就当没交接成功，往下走。
      started <- if (identical(det, "full") && loop_alive && !is.null(sid_now))
        tryCatch({
          # 先把流式生成掐掉。它累加的文本只活在**本会话**的 st$acc 里，
          # 会话一走就没人收了 —— 留着只是白烧 token。
          # 丢的也不是东西：那条助手消息还没落库，后台会用同一份上下文
          # **重新问一次**，模型重新给一遍。
          # ⚠️ 正因为"重新问一次"，这里**故意不**调 save_partial()（item 7）：
          #    存了就是同一轮出现两条助手消息，一条半截、一条完整。
          #    full 能走通的**唯一**条件是循环真的活着；循环没起来就会落到
          #    下面兜底那一支，那里才是必须存的地方。
          if (!is.null(st$llm)) try(dsapp_llm_abort(st$llm), silent = TRUE)

          # 采样参数**必须快照**：它们是滑块，库里不存。不传的话后台那条路
          # 只能用平台默认值，于是"挂机跑出来的"和"盯着跑出来的"是两次
          # 参数不同的请求 —— 而用户完全无从察觉。
          # ★ V15.5 item 6：快照里带的是**用户填的单次使用上限**，不是推导
          #   出来的 max_tokens。后台那条路会拿它重新拼一次上下文、重新推一次
          #   （见 detach.R 里 dsapp_ctx_plan 那一段）——快照推导值的话，两边
          #   的历史预算会不一样，"盯着跑"和"挂机跑"又成了两次不同的请求。
          prm <- list(temperature      = isolate(state$temperature),
                      ctx_limit        = isolate(state$ctx_limit),
                      thinking         = isolate(state$thinking),
                      reasoning_effort = isolate(state$reasoning_effort),
                      vendor           = isolate(state$vendor),
                      model            = isolate(state$model),
                      base_url         = isolate(state$base_url))
          tgt <- tryCatch(dsapp_current_target(), error = function(e) NULL)
          isTRUE(dsapp_detach_start(
            sid_now, user_id = isolate(state$user_id), target = tgt,
            max_iter = st$agent$max_iter %||% DSAPP_AGENT_MAX_ITER,
            # ★ V13.17 item 31：自动结束时间也要跟着过去。
            #   ⚠️ 这一条**比轮数还要紧**：后台续跑没有界面，用户关页面时
            #      选的是"8 小时"，那它就该按 8 小时跑；漏传的话它拿到默认的
            #      2 小时，用户回来发现"挂机的跑到一半就停了"，而对话里
            #      那句话还说"已达自动结束时间（2 小时）"—— 他明明选的 8。
            wall_limit = st$agent$wall_limit %||% DSAPP_AGENT_WALL_DEF,
            params = prm, scene = "agent",
            # ⚠️ 这三个值是**防重复执行**的关键：循环此刻多半正卡在
            #    "等任务 #N"上，而后台进程里没有任何记忆。不告诉它，它会把
            #    对话里最后一个代码块当成"还没跑过"再执行一遍。
            resume = list(task_id = st$agent$task_id,
                          last_key = st$agent$last_key,
                          iter = st$agent$iter),
            # mode 只影响横幅上那句话怎么写（"AI 接着往下跑" vs "守着任务跑完"）。
            # 这里走的是 full 那条路，所以只能是 "full"。
            mode = "full",
            cfg = cfg_end))
        }, error = function(e) FALSE) else FALSE

      # 起来了就到此为止 —— 收尾的责任已经交给那个进程了。
      # 起不来（callr 挂了、库锁着）就落到下面那一套：老实停掉 + 留一句话。
      if (isTRUE(started)) return(invisible(NULL))

      # ---- finish：守着当前这个任务跑完 -----------------------------------
      if (identical(det, "finish") && !is.null(tid_now)) {
        sitted <- tryCatch(dsapp_detach_sit(tid_now, sid_now,
                                            user_id = isolate(state$user_id),
                                            cfg = cfg_end),
                           error = function(e) FALSE)
        if (isTRUE(sitted)) {
          if (!is.null(st$llm)) try(dsapp_llm_abort(st$llm), silent = TRUE)
          # ★ V15.7 item 7：这一支也**必须**存。守护进程只是守着那个已经在跑
          #   的任务（.dsapp_task_sitter_worker 不会再问一次模型），而循环在
          #   下面那行就停了 —— 在飞的这段正文后面**没有任何人**会写它。
          #   顺序要紧：它得排在下面那条 tool 提示**前面**，否则用户回来看到
          #   的是"任务继续跑完"的说明，然后才是它前面那半截正文，读起来像
          #   倒放。
          save_partial("浏览器页面已关闭，这是断线前已经生成的部分")
          if (loop_alive) try(st$agent$stop("页面已关闭"), silent = TRUE)
          # 这句话是**必须**的：用户回来时看到多出来一条任务结果，
          # 得有东西解释它是哪来的。
          try(db_message_add(sid_now, "tool", paste0(
            "【平台提示】\n浏览器页面已关闭。你在设置里选了「让当前任务跑完」，",
            sprintf("所以正在执行的任务 #%d 会继续跑完，结果稍后写进这条对话。", tid_now),
            "自动执行循环本身停在这里，不会再往下走。"),
            con = dsapp_db(cfg_end)), silent = TRUE)
          return(invisible(NULL))
        }
      }

      # ---- off（以及上面两条路的兜底）：原样 ---------------------------------
      #
      # ★★ V15.7 item 7：**先存后掐**。原来的顺序是直接 dsapp_llm_abort() ——
      #    而它正是线上那个 bug：全仓库只有它会 unlink 掉 .out/.json/.reason，
      #    st$acc 里已经生成的正文却一个字都没落库。掐之前存，是这个 bug 的
      #    正解（只掐不存，长任务必丢；只存不掐，子进程白烧 token）。
      #
      # ⚠️ 存的是**本 run 自己的** acc（st 在这里被 end_run 的形参遮蔽，
      #    见上面 `st <- r` 那段说明），不是屏幕上那个对话的。
      save_partial("浏览器页面已关闭，这是断线前已经生成的部分")
      if (!is.null(st$llm)) try(dsapp_llm_abort(st$llm), silent = TRUE)

      if (loop_alive) {
        sid <- st$agent$sid
        # 留一条记录：用户回来时会看到这个对话在某一轮被中断了，
        # 而不是"莫名其妙少了一段"。
        if (!is.null(sid)) {
          try(db_message_add(sid, "tool", paste0(
            "【平台提示】\n浏览器页面已关闭，自动执行循环在此中断。",
            if (!is.null(st$agent$task_id))
              sprintf("正在执行的任务 #%d 已一并停止。", st$agent$task_id)
            else ""), con = dsapp_db(cfg_end)), silent = TRUE)
        }
        try(st$agent$stop("页面已关闭"), silent = TRUE)

        if (!is.null(tid_now)) {
          try(engine$abort(reason = "页面关闭，任务被中断"), silent = TRUE)
        }
      }
      }

      # ⚠️ 每个 run 各自 tryCatch：一个对话交接失败（库锁、callr 起不来）
      #    不该把排在它后面那些**正跑着别的活儿**的对话一起跳过 —— 那正是
      #    这个功能最坏的失败方式（用户以为在挂机，其实什么都没跑）。
      for (r in targets) {
        # ⚠️ 抛出**必须留声**：原来这里是 `error = function(e) NULL`，于是
        #    "交接成功"和"交接炸了"在日志里完全一样 —— item 7 那个"关页面就
        #    一个字不剩"的 bug 正是从这个洞里漏出去的。
        tryCatch(end_run(r, det), error = function(e)
          message("[dsapp] 页面关闭时的收尾没能走完（对话 ",
                  tryCatch(r$sid, error = function(e2) "?"), "）：",
                  conditionMessage(e)))
      }
    })
  })
}

#' 单条消息气泡
#'
#' ⚠️ "tool" 必须单列一支，**不能**落进助手那一支。助手气泡走的是
#'    dsapp_render_message()，它会把正文里的代码围栏渲染成带【确认执行】
#'    的活卡片 —— 而 tool 消息里的内容是**执行结果的文本**，里面常常包含
#'    报错原文，其中完全可能出现 ``` 这样的字样（比如模型打印了一段
#'    带围栏的模板）。渲染成卡片就变成了一个可以点的"执行"按钮，点下去
#'    执行的是报错信息本身，而这一切看起来完全正常。
#' @param actions ★ V15.3 item 4：挂在这条气泡尾部的动作按钮（由调用方
#'   `run_actions_ui()` 渲染好递进来）。只有**最后一条助手消息**会拿到它 ——
#'   三颗按钮要跟着"正在执行的会话"走，而"正在等你确认的那一段"就是最后一条。
#'   NULL（默认）时尾部什么都不渲染，历史里那些旧气泡走的就是这一条。
dsapp_msg_bubble <- function(role, content, message_id, reasoning = NULL,
                             file_names = NULL, file_input = NULL,
                             file_title = "点击下载 %s", running_id = NULL,
                             ran_ids = NULL, dom_id = NULL,
                             # V9 item 2/8：执行结果气泡用的额外材料。
                             task = NULL, run_files = character(0),
                             prefill_input = NULL, retry_input = NULL,
                             autofix = FALSE,
                             actions = NULL,
                             # ★ V15.3 item 6：正文里的图片要用会话私有的
                             # dataobj 地址才显示得出来，那需要 session。
                             img_session = NULL, img_sid = NULL,
                             img_cfg = NULL,
                             # ★ V15.6 item 13：FALSE = 不画代码卡上那条
                             # 「请确认后执行」黄条（agent 内联卡正在为这一段
                             # 要确认，见 render.R 的 dsapp_code_card）。
                             alert = TRUE) {
  is_user <- identical(role, "user")
  is_tool <- identical(role, "tool")

  # V9 item 9：目录跳转的落点。**只挂在用户消息上** —— 目录列的是轮次，
  # 一轮的标题就是用户那句话，所以跳转目标也只有它。
  # ⚠️ 用 id 属性而不是 data-* ：浏览器的 :target、以及 scrollIntoView
  #    都能直接用，不用先 querySelector 找一遍。
  if (is_tool) {
    return(div(class = "dsapp-msg dsapp-msg-tool",
      div(class = "dsapp-tool-avatar", icon("terminal")),
      div(class = "dsapp-tool-result",
          dsapp_render_tool_message(content, task = task, files = run_files,
                                    preview_input = file_input,
                                    prefill_input = prefill_input,
                                    retry_input = retry_input,
                                    autofix = autofix))
    ))
  }

  # 思维链折叠在助手气泡上方。**必须折叠**：它动辄几千字，展开铺在
  # 对话流里会把正文和代码全挤到屏幕外。用 <details> 而不是 Shiny 的
  # 折叠面板，是因为这是**历史消息**，每次重渲染都要重建 —— 服务端的
  # 展开/收起状态在重渲染后必然丢失，原生 details 由浏览器自己记着。
  reason_box <- if (!is_user && !is.null(reasoning) &&
                    length(reasoning) == 1 && !is.na(reasoning) &&
                    nzchar(reasoning)) {
    tags$details(class = "dsapp-reason",
      tags$summary(icon("brain"), sprintf(" 思考过程（%d 字符）",
                                          nchar(reasoning))),
      tags$div(class = "dsapp-reason-body", reasoning))
  }

  div(class = paste0("dsapp-msg ",
                     if (is_user) "dsapp-msg-user" else "dsapp-msg-assistant"),
    id = dom_id,
    if (!is_user) div(class = "dsapp-avatar", icon("robot")),
    # ★ V13.9 item 7：带「思考过程」的气泡加一个 dsapp-bubble-wide。
    #
    #   用户原话：「思考过程的对话框太窄了，应该跟执行结果窗口统一宽度」。
    #
    #   根因：思维链是**装在气泡里面**的（见上面 reason_box），而 .dsapp-bubble
    #   被 max-width: 82% 卡着 —— 于是思考过程最多只有正文的 82% 宽；而
    #   执行结果走的是 .dsapp-msg-tool 那一支，.dsapp-tool-result 是
    #   `flex: 1 1 auto`，占满整行。同一个屏幕里两个框差 18%，看着就是没对齐。
    #
    #   为什么按"有没有思维链"来决定宽窄，而不是把 82% 整个去掉：
    #   82% 是给**对话**留的呼吸感（右边那 18% 是给头像列和视觉分隔的），
    #   用户没抱怨普通回复太窄。只有思维链那一档在跟下面的执行结果比宽度，
    #   所以只放宽那一档。
    #
    #   ⚠️ 只认 !is_user：用户自己发的气泡不该因为别的原因变宽
    #      （skins.css 里 .dsapp-msg-user .dsapp-bubble 有自己的一套配色，
    #      宽度再跟着变会让左右两侧的留白不对称）。
    div(class = paste0("dsapp-bubble",
                       if (!is_user && !is.null(reason_box))
                         " dsapp-bubble-wide" else ""),
      reason_box,
      if (is_user) dsapp_render_user_message(content,
                                             img_session = img_session,
                                             img_sid = img_sid,
                                             img_cfg = img_cfg),
      # ★★ V15.4 item 4：用户自己的气泡上也挂一颗「重新发送」。
      #   用户原话：「重新发送的话应该直接返回到用户的输入框中」——
      #   所以它做的是"填回输入框"，**不是**"再发一次"：再发一次会替用户
      #   花掉一次调用，而且上一条为什么没答好他可能正是想改一改再发。
      #   ⚠️ 只给 is_user 挂。助手气泡上挂的话，等于给了用户一颗"把我这句
      #      原样再问一遍"的按钮 —— 而问题往往出在他自己的那句话上。
      if (is_user) dsapp_resend_btn(prefill_input, content)
      else dsapp_render_message(content, message_id,
                                file_names = file_names, file_input = file_input,
                                file_title = file_title,
                                running_id = running_id, ran_ids = ran_ids,
                                img_session = img_session, img_sid = img_sid,
                                img_cfg = img_cfg, alert = alert),
      # ★ V15.3 item 4：动作按钮的四个挂载点之一（"hist"）。
      # ⚠️ 它必须在**气泡里面**（用户原话「挪到正在执行的会话里去」）——
      #    摆在气泡外的消息流里就又是一条"钉在某处的工具条"，
      #    正是这一版要拆掉的东西。
      if (!is_user) actions
    )
  )
}

#' 目录（V9 item 9）里一个轮次的跳转锚点
#'
#' 走 ns() 是为了和页面上别的 id 分开：同一个浏览器里开着两个标签页时
#' DOM id 是本页独有的，但模块 id 相同 —— 用 ns() 拼出来的至少和 Shiny
#' 自己生成的那些不会撞。
#'
#' ⚠️ 一定要和 dsapp_msg_bubble 里挂的那个 id 用**同一个函数**算。
#'    两边各写一遍的话，改了其中一处就会变成"点了没反应" —— 而
#'    dsappJumpTo 找不到元素时是静默返回 false 的，不报错。
dsapp_msg_anchor <- function(ns, message_id) {
  ns(paste0("m", message_id))
}

#' 目录里一条的标签：用户那句话的第一行
#'
#' ⚠️ 取**第一个非空行**，不是第一个字符。用户发消息常常先空一行再写正文，
#'    直接取首行会得到一串空白，目录里就是一片空条目。
dsapp_toc_label <- function(content, max = 30L) {
  txt <- content %||% ""
  if (!nzchar(trimws(txt))) return("（空消息）")
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  lines <- lines[nzchar(trimws(lines))]
  lab <- if (length(lines)) dsapp_label_line(lines[[1]]) else ""
  if (!nzchar(lab)) return("（这一轮没有文字）")
  if (nchar(lab) > max) lab <- paste0(substr(lab, 1, max), "…")
  lab
}

#' 执行结果消息的渲染
#'
#' 不解析 Markdown，纯文本 + 首行标题单独提出来当徽章。理由见上面 dsapp_msg_bubble
#' 的 ⚠️：这里的内容是**平台的输出**，不是模型写的文档，按 Markdown 渲染
#' 只会把报错里的符号吃成格式。
dsapp_render_tool_message <- function(content, task = NULL,
                                      files = character(0),
                                      preview_input = NULL,
                                      prefill_input = NULL,
                                      retry_input = NULL,
                                      autofix = FALSE) {
  txt <- content %||% ""
  # 第一行固定是【执行结果 · 任务 #N】或【平台提示】，提出来当标题
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  head <- if (length(lines)) lines[[1]] else ""
  body <- if (length(lines) > 1) paste(lines[-1], collapse = "\n") else ""

  is_err <- grepl("状态：失败|状态：超时|未能执行|已被中止|拒绝执行", txt)

  # V9 item 2：有任务行就走富卡片（标题/元信息/报错/输出/产物分块排版）。
  #
  # ⚠️ 走不了的时候**必须**原样退化成下面那条纯文本路径，不能什么都不显示。
  #    拿不到任务行的情形是真实存在的：任务记录被用户在任务页删了、"未执行"
  #    这类平台提示压根没有任务号、以及 V9 之前落库的那些消息。这条兜底路径
  #    同时是"卡片渲染炸了"的备份 —— 报错内容是用户唯一的线索，不能因为
  #    排版失败就消失。
  if (!is.null(task) && nrow(task) > 0) {
    return(dsapp_run_card(task, txt, files = files,
                          preview_input = preview_input,
                          prefill_input = prefill_input,
                          retry_input = retry_input,
                          autofix = autofix))
  }

  tagList(
    div(class = paste0("dsapp-tool-head",
                       if (is_err) " dsapp-tool-head-err" else ""),
        icon(if (is_err) "circle-xmark" else "square-check"),
        " ", head),
    tags$pre(class = "dsapp-tool-body", body)
  )
}
