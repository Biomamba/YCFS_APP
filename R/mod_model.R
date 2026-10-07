# =============================================================================
# 模型服务（左栏的一个独立页）
# =============================================================================
# V6 从 mod_settings.R 里整块搬出来的，对应两条反馈：
#
#   item 5  「模型模块在左侧应该是单独的滑块，不要整个界面一个下滑块」
#           —— 它从设置页里搬了出来，有自己的一条滚动条，主区另有一条。
#           两者互不影响：在设置页往下翻不会把模型控件带走，反过来也一样。
#
#   ⚠️ V13.12 item 19 又挪了一次：从"左栏最下面一块常驻的折叠面板"变成
#      navset 里的一个**普通页**（value = "model"，见 app.R 和 R/uiprefs.R）。
#      于是上面那句"它现在住在左侧栏里"只对了一半 —— 它在左栏**导航里**，
#      但内容渲染在主区，滚动条属于主区。左栏那条滚动条现在归导航那一段
#      （codex.css 的 .dsapp-rail-nav）。
#
#   item 1  「每次进入需要重新填写 API 和 key，请保留记忆功能」
#           —— 设置按账号存在 users 表里（llm_vendor / llm_model /
#           llm_base_url / llm_api_key），登录时直接带出来。
#
# ---- ⚠️ 这一版推翻了「API Key 绝不落盘」------------------------------------------------
#
# V3 到 V5 的代码里写着"API Key 只存在会话内存，不写数据库、不落盘"，
# 那段话现在**不成立了**，凡是在别处还引用它的注释都要一起改，否则下一个
# 读代码的人会照着一条已经不存在的保证去推理。
#
# 代价是真实的，不能因为"是用户要的"就装作没有：
#   · 库文件（data/dsapp.sqlite3）被拷走 = Key 跟着走。备份、误传、
#     有读权限的另一个进程，都在这条路上。
#   · 所以界面上**必须**如实说明，不能沿用旧的"关闭页面即失效"文案 ——
#     那会变成一句假话，而用户会据此把 Key 当成一次性的东西。
#   · 提供「清除已保存的 Key」把选择权交回去。
#
# 还有一条边界没变：Key 存在**服务端**，不在浏览器里。有 root 权限的人
# 仍然能从库里或进程内存里取到 —— 这话 V5 就写着，现在更要写。
#
# ---- 落盘时机 -----------------------------------------------------------------------
#
# 用 debounce(800ms)，不是"每次 input 变化就写库"。理由：api_key 是
# passwordInput，用户粘贴时浏览器会逐字符触发 input 事件的可能性是存在的
# （密码管理器、输入法），逐次写库等于把一把半截的 Key 存进去，而且
# 每次登录都会把那个半截值带回来 —— 症状是"Key 明明填对了，一刷新就报 401"。
# =============================================================================

#' 模型服务页
#'
#' @param id      模块 id
#' @param user_id 当前账号；用来把上次保存的设置预填进控件。
#'                NULL（还没登录）时用出厂默认值。
mod_model_ui <- function(id, user_id = NULL) {
  ns <- NS(id)

  # ⚠️ 这里读库，所以整段包在 tryCatch 里。这个函数的返回值最终会进
  #    renderUI("app_root")，一次读库失败（库被锁、磁盘满）如果直接抛出去，
  #    表现是整个应用空白页 —— 而它本来只是"预填一下上次的设置"。
  s <- tryCatch(dsapp_settings_get(user_id), error = function(e) list())
  if (!is.list(s)) s <- list()

  # ★ Test_V16.3 item 2：代理设置（VPN）。和上面那句同一个理由包在 tryCatch 里
  #   —— 一次读库失败不该让整页变成空白页。
  #   ⚠️ dsapp_proxy_get() **总是**返回一个完整的 list（没设置过 = 一份空的），
  #      所以下面可以直接 px$host / px$port 地用，不用到处判 NULL。
  #   ⚠️ 拿到的 sub_key 是**明文**（库里那份是密文，读的时候已经解开了）。
  #      它**不进** value=，只用来判断"要不要换个提示语"——见下面那个输入框。
  #      明文进 value= 的话，密匙会随 HTML 发到浏览器上，加密就白做了。
  px <- tryCatch(dsapp_proxy_get(user_id), error = function(e) dsapp_proxy_norm(NULL))

  # 存的厂商可能已经被停用（比如 yi 停服时把 enabled 改成了 FALSE）。
  # 直接用会让 selectInput 的 selected 指向一个不存在的选项，控件显示空白。
  #
  # ★★ Test_V15.4 item 1：回落逻辑**只有一份**，在 dsapp_vendor_active() 里，
  #    服务端读设置时调的是同一个函数。从前这里是**唯一**一份，服务端照抄库
  #    里的原值 —— 两边一旦不一致，切厂商 observer 就会把一次"页面初始化"
  #    误判成"用户换了厂商"，顺手把 users.llm_api_key 抹成 NULL。详见那个
  #    函数的函数头，别把这两行抄回来。
  vendor <- dsapp_vendor_active(s$vendor)

  # 模型下拉的初始候选：厂商 /models 接口要联网才知道，这里先用目录里的
  # 静态清单占位（和原来一样）。有存过的模型名就选它 —— 哪怕它不在清单里
  # （selectizeInput 的 create=TRUE 允许任意名）。
  #
  # ★ V13 item 7：候选是**分组**的（本平台在前，别家按原厂分堆）。
  #   selectizeInput 的 choices 传一个具名 list 就是 optgroup，
  #   input$model 拿到的仍然是那个字符串，下游一个字都不用改。
  mgroups <- tryCatch(dsapp_vendor_model_groups(vendor), error = function(e) list())
  mflat <- dsapp_model_groups_flat(mgroups)
  saved_model <- s$model %||% ""
  if (nzchar(saved_model) && !saved_model %in% mflat) {
    # 存过的名字不在清单里（厂商新上的、或者用户手打的）。create=TRUE 允许
    # 任意名，但**选项里没有它**时控件会显示空白 —— 用户以为自己没设过模型。
    # 单独开一组把它摆出来，比塞进「本平台」诚实。
    mgroups <- c(list("当前使用" = saved_model), mgroups)
    mflat <- c(saved_model, mflat)
  }
  if (!nzchar(saved_model) && length(mflat)) saved_model <- mflat[[1]]

  base_url <- s$base_url %||% ""

  # ---- 「确认 / 更新」按钮（V7 item 3；V13.15 item 26 改成**头尾各一颗**）--
  #
  # 用户原话：「更新按钮请在头部和尾部各设置一个，和获取模型按钮一样设置的
  #          宽一些，防止用户看不到」。
  #
  # 背景：V13.11 item 8 应他的要求在"最底部"加过一颗，那颗留着 —— 但这一页
  # 从头到尾一千多像素高，只看得到上半屏的人**根本不知道有这个按钮**，
  # 而它偏偏是唯一一个"填完了"的时刻。头尾各一颗，进来就看得见、填完也
  # 顺手，两头都不落空。
  #
  # ⚠️ 两颗按钮**共用同一个处理函数**（server 里的 do_commit()），不抄两遍
  #    —— 和 mod_settings.R 那三颗「保存并返回对话」是同一个套路。抄两遍的
  #    下场是改了一颗忘了另一颗，而两颗长得一模一样，用户点哪颗都是"看起来
  #    生效了"，很难报出问题来。
  #
  # ⚠️ 底部那颗的 id 仍然是 `commit`，**没有**跟着改成 `commit_bottom`：
  #    `#model-commit` 有外部引用（tests/ui_v1312 的 probe_dirty / probe_quiet
  #    / probe_model 直接点它），改名的收益只有"看着对称"，代价是那几个探针
  #    静默点空、报出来的是超时。不划算。
  #
  # ⚠️ 宽度和「获取模型」一致（`btn-sm w-100`）：那一颗是这一页上唯一一个
  #    "点下去有反应"的按钮，用户在它身上建立了"这一页的按钮就该是这么宽"
  #    的印象。做成 btn-sm 不 w-100 的话，两颗"确认"会比它窄一截，看着像
  #    次要操作 —— 而它其实是这一页的主操作。
  commit_btn <- function(id, hint_id) {
    div(class = "mb-2",
      actionButton(ns(id), if (isTRUE(s$saved)) "更新" else "确认",
                   class = "btn-primary btn-sm w-100",
                   style = "white-space: nowrap;"),
      div(class = "text-center mt-1", uiOutput(ns(hint_id), inline = TRUE)))
  }

  # ★ V13.12 item 19：外面这一层 `div.dsapp-page` + `card()` 是**跟着别的
  #   配置页加的**（技能 / 环境 / 设置 / 文献速递都是这个结构），用户要的
  #   就是"和其它几个侧面导航栏一样的单独页面"。
  #
  #   ⚠️ 不加会怎样，值得写下来：控件本身一个不少、一个不错，但它们是**光着**
  #      铺在主区上的 —— 每个输入框都 width="100%"，于是撑到一千三百多像素宽，
  #      一屏看不到底（「更新」按钮在 y≈910 处）。看着不像一页，像一张被
  #      拉长的表单。原来在 264px 的左栏里，那个 100% 恰好就是"填满这一格"。
  #
  #   ⚠️ 卡片**只包一层**，里面控件的顺序、id、class 一个字都没动 ——
  #      V13.11 item 8 那几条"哪个控件排在哪个前面"的断言（更新按钮必须在
  #      「生成参数」和「接口地址」之后、后面不许再有别的输入控件）全都还
  #      成立，只是整体往里缩了一格。
  div(class = "dsapp-page",
    card(
      card_header(icon("robot"), " 模型与密钥"),
      card_body(
  tagList(
    # 保存状态那一行（"已记住 / 本次有效"）+ 清除按钮
    uiOutput(ns("key_state")),

    # ★ V13.15 item 26：**头部那一颗**「确认 / 更新」。
    #
    #   放在「厂商」之前、状态行之后 —— 这是整页第一个可点控件，不用滚动
    #   就看得见。放在状态行之后是因为那一行说的正是"存没存下来"，
    #   按钮紧跟着它，两句话读起来是一件事。
    commit_btn("commit_top", "commit_hint_top"),

    selectInput(ns("vendor"), "厂商",
                choices = dsapp_vendor_choices(),
                selected = vendor, width = "100%"),

    # ★ V13.14 item 24（用户原话）：「"还没有 Key？去 中转站大全 官网申请"
    #   这个条目应该直接显示在厂商下面，换成"还没有 Key和URL？去 中转站大全
    #   官网申请"」。
    #
    #   ⚠️ 它原来长在**「获取模型」按钮下面**（base_url / api_key / verify
    #      之后）。那个位置是错的：这句话回答的是"我还没有这个东西，去哪
    #      弄"，而用户**看完这句话才知道要去哪弄** —— 所以它得在"选哪家"
    #      旁边，而不是在"我已经填好了，点一下验证"旁边。排在「获取模型」
    #      下面的时候，一个还没注册的人得先往下走三步才看见它。
    #
    #   ⚠️ 文案从「还没有 Key？」改成「还没有 Key和URL？」：中转站那几家
    #      （「中转站大全」这类聚合平台）发的不只是一把 Key，**接口地址也是
    #      从它那儿拿的**（key_url 和 base_url 根本不在同一个域名下，见
    #      R/models.R 里 relay 那一项的说明）。只说 Key 的话，用户在注册页
    #      拿到地址之后不知道该往哪儿填 —— 而「接口地址」输入框就在下面一行。
    #
    #   ⚠️ 整块（申请那条 + 「已有账号去控制台」）一起搬。它们是同一句话的
    #      两半：一个给还没注册的，一个给注册过的。拆开搬会让第二半留在一个
    #      对不上文的位置。
    uiOutput(ns("key_help")),

    # ★ V13.12 item 1：接口地址**从最下面挪到这儿**，而且「获取模型」紧跟着它。
    #
    #   用户原话：「通过 key 获取可用模型不太合理，应该通过 URL 来获取模型，
    #   这样中转站也能够获取」。
    #
    #   这一次请求发往哪个地址，**由这一栏决定**（见下面 start_verify 的说明）
    #   —— 所以控件顺序必须和这个因果关系一致：先看得见地址，再点按钮。
    #   以前地址在最底下（模型下拉、生成参数之后），用户在按钮旁边根本看不到
    #   它，自然会以为"是 Key 决定了去哪家"。
    div(class = "d-flex align-items-end gap-2",
      div(class = "flex-grow-1",
        textInput(ns("base_url"), "接口地址（base_url）",
                  value = base_url, width = "100%")),
      div(class = "mb-3",
        actionButton(ns("fill_base"), "默认地址",
                     class = "btn-link btn-sm p-0 text-decoration-none",
                     style = "white-space: nowrap;"))
    ),

    passwordInput(ns("api_key"), "API Key",
                  value = if (nzchar(s$api_key %||% "")) s$api_key else "",
                  placeholder = "粘贴你的 Key（sk-... 等）",
                  width = "100%"),

    div(class = "mb-2",
      actionButton(ns("verify"), "获取模型",
                   class = "btn-outline-primary btn-sm w-100",
                   style = "white-space: nowrap;")),

    uiOutput(ns("verify_result")),

    # ⚠️ key_help 原来在这儿（「获取模型」下面），V13.14 item 24 挪到
    #    「厂商」下面去了 —— 见上面那一段。别搬回来。

    div(class = "d-flex align-items-end gap-2",
      div(class = "flex-grow-1",
        selectizeInput(ns("model"), "模型",
                       choices = mgroups, selected = saved_model,
                       width = "100%",
                       # ⚠️ maxItems = 2 + mode = "single" 这一对**不能省**，
                       #    看着像写错了，其实是在绕 selectize 的一个坑。
                       #
                       #    Shiny 的单选 selectize 默认 maxItems = 1。selectize 的
                       #    isFull() 是 `maxItems !== null && items.length >= maxItems`，
                       #    选中一个之后它就认为自己**满了**，于是把输入框锁成 4px 宽、
                       #    键盘输入全部丢掉 —— 表现是：模型选过一次之后，**再也打不进
                       #    新的名字**，只能从下拉里挑现成的。
                       #
                       #    对一个正常的下拉这不算事（候选都在列表里）。但这个框是
                       #    create=TRUE 的自由输入：用户手打了一个自定义/中转的模型名，
                       #    想改一个 —— 改不了。2026-09-16 写 V13.1 的线路测试时才撞见，
                       #    当时还以为是测试脚本的问题。
                       #
                       #    为什么不是 maxItems = NULL：R 里 list(maxItems = NULL)
                       #    会**把这个元素删掉**，JSON 里根本没有它，selectize 于是
                       #    退回 element 上的默认值 1，等于没改。所以只能用一个 > 1 的
                       #    数把它顶开 —— 真正保证"只有一个"的是 mode = "single"
                       #    （addItem 会先清掉旧的），maxItems 在这里只负责"别锁输入框"。
                       #
                       #    实测（standalone selectize 页，见 tests/ui_v131）：
                       #      maxItems=1              → 选中后打字全丢
                       #      maxItems=null,mode=single → 能替换（但 R 表达不出来）
                       #      maxItems=2, mode=single   → 能替换 ✅
                       options = list(
                         create = TRUE,
                         maxItems = 2,
                         mode = "single",
                         placeholder = "点上面的「获取模型」拉清单"
                       ))),
    ),

    uiOutput(ns("model_warn")),

    # ---- 生成参数（V13.6 item 2）-------------------------------------------
    #
    # 用户的原话：「模型服务的生成参数不要折叠，适用的直接出现，不适用的
    # 变成灰度就好」。
    #
    # 改之前这里是 tags$details(class = "dsapp-model-adv", ...)：默认收着，
    # 点标题才展开。当初收着的理由写在旧注释里 —— "调一次就不动的东西，
    # 别让侧栏一直滚"。那个理由是以**老用户**为前提的：对第一次配的人来说，
    # 一行"▸ 生成参数"和"这个应用没有这个功能"是分不清的，而他要找的
    # 「思考强度」正好就在里面。摊开。
    #
    # ⚠️ 摊开之后侧栏确实变长了，这是**明知**的取舍，不是漏了：把不适用的
    #    控件**灰掉**而不是藏起来，本来就要占位置 —— 那正是 item 2 要的效果
    #    （"这个参数存在，只是当前这台模型用不上"比"它凭空消失"好解释得多）。
    #    里面的东西按 (厂商, 模型) 自适应，用不上的那些自己会灰。
    div(class = "dsapp-model-params",
      div(class = "dsapp-params-head", icon("sliders"), " 生成参数"),
      # 思考模式 + 思考强度 + 温度 + 长度上限，全在 temp_ui 这一个 renderUI 里。
      # ⚠️ 合成一个输出是有意的：它们的"能不能用"由**同一对** (厂商, 模型)
      #    决定，拆成几个输出就要把同一套判断写几遍，改一处漏一处。
      uiOutput(ns("temp_ui")),
      # 长度上限的提醒单独一个输出：它只依赖 input$max_tokens，跟着打字走。
      # 塞进 temp_ui 的话，用户在输入框里每敲一个数字都会把整块参数区重建
      # 一遍（包括他正在打字的那个框）。
      uiOutput(ns("maxtok_hint"))
    ),

    # ---- 确认 / 更新（V7 item 3；V13.11 item 8 挪到**最底部**）--------------
    #
    # 用户的原话：「模型服务处填好了要有确认按钮，填好了有 key 可以使用时，
    # 确认按钮需要变成更新按钮」。
    #
    # 原来这里是**没有按钮**的：填完就靠 debounce(800ms) 自动落库。自动保存
    # 本身留着（见文件顶部的说明，它防的是"填了半截的 Key"），但它有个说不
    # 清的地方 —— 用户填完 Key 之后没有任何"完成"的时刻，界面上也没有一句
    # "存好了"，只能靠反复刷新页面来确认。这个按钮就是那个时刻。
    #
    # 文字由服务端按「库里到底有没有一把 Key」来定：没有 → 「确认」，
    # 有 → 「更新」。标签由 updateActionButton() 改，**两颗一起改** ——
    # 只改一颗的话，界面上会同时出现一个「确认」和一个「更新」，用户以为
    # 它们做的是两件事。
    #
    # ★ V13.11 item 8：用户原话「模型服务的更新按钮可以在最底部」。
    #   原来是夹在「接口地址」和「生成参数」中间的，而这一块面板的顺序是
    #   Key → 模型 → 地址 → 参数，他真正想按的"填完了"发生在**最后**。
    #   按钮停在半中间，用户填完下面的参数还得往回滚 —— 而更糟的是它看起来
    #   像只对上面那几个框生效。**这一颗留在原地**（V13.15 item 26 只是
    #   在头部**又加了一颗**，没有把它挪回去）。
    #
    # ⚠️ 这一颗必须排在「生成参数」之后 —— selftest 里有一条盯着"它是整页
    #    最后一个可点控件"。加头部那一颗时别顺手把这一条也挪上去。
    #
    # ★★ Test_V16.3 item 2：**它现在不住在这张卡里了**，搬到了整页最底下
    #    （两张卡之后，见下面那个 commit_btn）。
    #
    #    为什么非搬不可：代理那张卡排在它下面之后，"更新"就不再是这一页的
    #    最后一个控件了 —— 用户填完模型、滚到底、点了「更新」，下面还有一整
    #    张卡等着他。而他要表达的是"这一页我弄完了"。V13.11 item 8 那条
    #    「更新按钮可以在最底部」说的就是这个位置，加了第二张卡之后，
    #    "最底部"就得跟着往下走一格。
    #
    #    ⚠️ 搬迁**没有**动它的 id（还是 `commit`）、没有动它调的处理函数
    #       （还是 do_commit，那颗照样把代理一起存下去）。外部引用
    #       `#model-commit` 的那些探针一个都不受影响。
  )
      )   # /card_body
    ),    # /card
    # =======================================================================
    # ★★ Test_V16.3 item 2：代理（VPN）
    # =======================================================================
    #
    # 用户原话：「模型服务里额外加一个VPN设置，用户填写自己的代理地址、端口、
    #           协议信息、订阅密匙后可以访问境外模型和数据，订阅密匙同样需要
    #           加密处理」。
    #
    # ⚠️ 为什么要**单独一张卡**、而不是接着塞进上面那张：它管的是另一件事
    #    （"请求从哪条线路出去"），和上面那张（"往哪儿发、用什么身份发"）
    #    没有从属关系。塞在一起的话，用户会以为它是"某个厂商的附属设置"，
    #    而它其实是**全账号**生效的 —— 换个厂商照样走这条线路。
    #    这也是 item 5 那条"控件要有分类的区分度"在这张页面上的落法：
    #    两张卡 = 两件事，一眼分得开。
    card(
      class = "mt-3",
      card_header(icon("shield-halved"), " 代理（VPN）"),
      card_body(
        # ---- 为什么默认是关的，而且**必须**是关的 ----
        #
        # 这一格默认关，不是保守，是唯一说得通的选择：没填地址端口时它就是
        # 不可用的（dsapp_proxy_ok 会拦），而"默认开着一个没配好的代理"会让
        # **每一次**请求都变成一句 Could not resolve proxy —— 新用户第一次
        # 打开这一页就发现发不出消息。
        checkboxInput(ns("proxy_on"), "启用代理（本账号所有模型请求和代码取数都走它）",
                      value = isTRUE(px$enabled)),

        div(class = "text-muted small mb-2",
          "填自己的代理地址。它是给**境外**模型和数据用的；本机地址（127.0.0.1）",
          "不受影响，永远直连。"),

        div(class = "d-flex gap-2",
          div(class = "flex-grow-1",
            selectInput(ns("proxy_proto"), "协议",
                        choices = dsapp_proxy_choices(DSAPP_PROXY_PROTOCOLS),
                        selected = px$protocol, width = "100%")),
          div(style = "width: 120px;",
            numericInput(ns("proxy_port"), "端口",
                         value = if (is.na(px$port)) NA else px$port,
                         min = 1, max = 65535, step = 1, width = "100%"))
        ),

        textInput(ns("proxy_host"), "代理地址",
                  value = px$host, width = "100%",
                  placeholder = "只填主机名或 IP，例如 proxy.example.com"),

        textInput(ns("proxy_user"), "用户名（可选）",
                  value = px$username, width = "100%",
                  placeholder = "一般留空"),

        passwordInput(ns("proxy_key"), "订阅密匙",
                      value = "", width = "100%",
                      placeholder = if (nzchar(px$sub_key)) "已保存（留空 = 不改）"
                                    else "粘贴服务商给的密匙"),

        selectInput(ns("proxy_keymode"), "密匙用途",
                    choices = dsapp_proxy_choices(DSAPP_PROXY_KEY_MODES),
                    selected = px$key_mode, width = "100%"),

        div(class = "d-flex align-items-end gap-2",
          div(class = "flex-grow-1",
            actionButton(ns("proxy_test"), "测试代理",
                         class = "btn-outline-primary btn-sm w-100",
                         style = "white-space: nowrap;")),
          div(class = "mb-3",
            actionButton(ns("proxy_forget"), "清除",
                         class = "btn-link btn-sm p-0 text-decoration-none",
                         style = "white-space: nowrap;"))
        ),

        uiOutput(ns("proxy_result"))
      )
    ),

    # ---- ★ Test_V16.3 item 2：整页最后那颗「确认 / 更新」-------------------
    # 从上面那张卡里搬下来的（理由见那一处的说明）。它是**整页**最后一个
    # 可点控件，两颗按钮仍然共用 do_commit()。
    commit_btn("commit", "commit_hint")
  )       # /div.dsapp-page
}

mod_model_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    # 这几个控件会因厂商/模型不同被整个重建，重建时对应的 input$ 会短暂变
    # NULL。用 rv 记住最后一次的有效值，否则一换厂商设置就跳回默认。
    #
    # 默认值对齐 DeepSeek 的出厂设置：思考模式开、强度 high —— 和"用户什么都不
    # 改直接调 API"的行为一致，不会让应用里的表现和官方文档对不上。
    # maxtok 是 V13.6 item 3 加的：长度上限原来直接读 input$max_tokens，
    # 而那个控件现在跟着厂商/模型一起重建（量程要变），重建的瞬间 input 是
    # NULL —— 快照规则和温度一样，用 rv 记住最后一次的有效值。
    # ★★ V15.6 item 8：用户原话「模型设置界面把上下文限制和 token 限制功能
    #    都打开吧，默认不限制」。
    #
    #    ⚠️ 这里以前是 `maxtok = 65536`，而它是**盖住** app.R:1608 那句
    #       `ctx_limit = DSAPP_CTX_FOLLOW` 的那一份：模型页加载时走的是
    #       `input$max_tokens %||% rv$maxtok`，控件还没画出来、input 是 NULL，
    #       于是默认值实际由**这个字面量**决定 —— 新会话一进模型页，单次上限
    #       就从"跟随模型（1M）"被悄悄改成 65536。页面上看不出任何异常，
    #       用户只会觉得"这模型怎么这么早就说上下文满了"。
    #
    #    现在换成哨兵本身：滑块停在最右"跟随模型"那一格，输入栏留空，
    #    请求里不带 max_tokens 之外的任何夹取，上限就是模型自己的窗口。
    #    ⚠️ 别把它写回一个具体数字 —— 那等于把"默认不限制"这件事又反悔了，
    #       而且反悔得无声无息（见上面那条：字面量盖住会话状态）。
    rv <- reactiveValues(temp = 0.3, thinking = TRUE, effort = "high",
                         maxtok = DSAPP_MAXTOK_UNLIMITED)

    # 异步任务句柄
    models_job <- reactiveVal(NULL)
    # ★★ V16.3 item 7：这次在飞的请求是**替哪一家**发的。
    #
    #   为什么必须在**发请求那一刻**记下来，而不是等结果回来再读 input$vendor：
    #   一次 /models 往返几十毫秒到二十秒（超时），用户完全来得及在中间换一家。
    #   旧代码是在**结果落地时**才盖章（`vendor = isolate(input$vendor)`），于是
    #   中转站 A 的模型清单会被贴上 B 的标签、当成 B 的清单显示出来 ——
    #   盖错章的清单**比不盖章更坏**：它看起来是"刚查到的、可信的"。
    #   这种"盖在错误的时刻"的章，加 `res$vendor == input$vendor` 这种守卫也
    #   拦不住，因为两个 vendor 在盖章那一刻本来就是相等的。
    models_job_vendor <- reactiveVal(NULL)
    models_res <- reactiveVal(NULL)   # list(ok, models, msg, vendor)

    # =======================================================================
    # 启动：把上次存下来的设置读进 state
    # =======================================================================
    #
    # ⚠️ 这件事**必须**在这儿做，不能指望"用户会去点一下设置页"。
    #    对话页的发消息闸门（mod_chat.R）读的是 state$api_key，而 UI 的
    #    value= 只填了控件、没写 state —— 不在这里补一刀的话，用户登录后
    #    直接进对话页会被告知"请先到设置页填 API Key"，而他明明存过。
    #    这正是 item 1 报的那个症状，别只看控件里有没有值就以为修好了。
    #
    # 只在**账号变化**时重读，不是每次渲染都读：用户在设置页改了 Key 之后
    # 又触发一次重读的话，会把他的新值冲回旧值。
    loaded_for <- reactiveVal(NULL)

    # 输入框里那把 Key **属于哪个厂商**（V13.1 item 5）。
    #
    # 存在的理由：`input$api_key` 只是一串字符，它自己不知道自己是哪一家的。
    # 而这个归属决定了它会被写进钥匙串的哪一行 —— 记错一行就是"切回来时
    # 多了一把用不了的 Key"，而且界面上看不出来。
    #
    # 改动它的地方**只有**下面那个切厂商的 observer（以及载入设置时那次）。
    # 别在别处按 input$vendor 现推：换厂商的那一瞬间 input$vendor 已经是新的
    # 了，而输入框里还是旧的 Key，现推出来的归属正好是反的。
    key_vendor <- reactiveVal(NULL)

    # ★★ V15.4 item 1：从 `observe()` 改成 `observeEvent()`。
    #
    #    ⚠️ 这不只是风格问题：下面的自愈要把 `key_ver` +1（让「已保存」那一行
    #       重画），而**自读自写 reactive 在 observe 块里会把整个应用卡死**
    #       （本仓已有哨兵盯着，selftest 里那条"没有 observe 块自读自写
    #       reactive"当场就抓住了这一版）。`observeEvent` 的 body 不建立
    #       响应式依赖，所以那里 +1 是安全的 —— 仓库里别处的写法也是这个规矩
    #       （见 `key_ver` 定义旁边的说明）。
    #
    #    触发语义没变：原来那个 `observe` 的触发源就是 `state$user_id`。
    #    `ignoreNULL` 默认 TRUE —— 退出登录（uid 变 NULL）时这里本来也是
    #    直接 return，两边等价。
    observeEvent(state$user_id, {
      uid <- state$user_id
      if (is.null(uid)) return()
      # ⚠️ 读的那一侧 isolate()。loaded_for 是"这个账号的设置已经载入过"的
      #    备忘，不是本块的**触发源** —— 触发源是 state$user_id（换账号才该
      #    重载）。裸读它 = 自己写、自己失效、自己再跑一轮，然后靠这一行当场
      #    return 掉。转是只多转一圈，但那一圈纯属白烧。
      if (identical(isolate(loaded_for()), uid)) return()
      loaded_for(uid)

      s <- tryCatch(dsapp_settings_get(uid, con = dsapp_db(cfg)),
                    error = function(e) list())
      # ★ Test_V15.4 item 1：和 UI 用**同一个**回落函数。两边不一致的后果
      #   见 dsapp_vendor_active() 的函数头（会把用户的 Key 抹掉）。
      #
      # ⚠️ 先落进局部变量再写 state，别写成 `state$vendor <- ...` 之后又
      #    `state$vendor` 去读它 —— 那是同一个 observe 块里的自读自写。
      v_act <- dsapp_vendor_active(s$vendor)
      state$vendor   <- v_act
      state$model    <- s$model %||% cfg$llm$default_model
      state$base_url <- dsapp_vendor_base_url(v_act, s$base_url %||% "")

      # ★★ Test_V15.4 item 1：**自愈**。上面读的 s$api_key 是
      #    `users.llm_api_key` 那一列，而原件在钥匙串里 —— 两者不同步时
      #    （列被抹成 NULL、钥匙串还完好）这里会读到空串，于是用户一登录、
      #    还没进设置页，对话页的闸门就告诉他"请先到设置页填 API Key"，
      #    而他明明填过。用户唯一的出路是重新粘一遍，那正是他说的
      #    "因为版本更新付出额外的操作"。
      #
      #    dsapp_api_key_ensure() 做两件事：解得开就把列补回来，并把明文
      #    返回来写进 state。**必须在这是最后一次写 state$api_key 的地方**
      #    （下面那个"状态同步到会话"的 observe 已经不写它了）。
      #
      #    ⚠️ 判据是"解得开"不是"行存在"，理由见那个函数的函数头。
      #    ⚠️ 它写库，所以包一层 —— 自愈失败最多是回到从前的行为（提示去
      #       设置页），不该把整页带崩。
      state$api_key  <- tryCatch(
        dsapp_api_key_ensure(uid, v_act, con = dsapp_db(cfg)),
        error = function(e) s$api_key %||% "")
      key_vendor(v_act)
      # 自愈可能刚刚往库里写了东西（列被补回来）→ 让「已保存」那一行重画。
      # 不写这一句的话，库里已经是"已保存"、界面上还写着"还没填 Key"。
      key_ver(key_ver() + 1)
    })

    # =======================================================================
    # 切厂商：把这家的 Key 换上来（V13.1 item 5）
    # =======================================================================
    #
    # 用户原话：「填写的api key要有记忆功能，在切换厂商时能直接切换过来，
    # 不然每次复制API key不好操作」。
    #
    # ---- 改之前是什么样 ----
    #
    # 全站只有 users.llm_api_key 一列，切厂商时**输入框里留的是上一家的
    # Key**，而下面那个防抖保存会把它原样写到新厂商名下。所以不只是"要重新
    # 粘一遍"这么轻 —— 用户切到 Kimi、看到「Key 已记住」、发一条消息，
    # 发出去的是 DeepSeek 的 Key，回来的 401 里没有一个字提到厂商。
    #
    # ---- 顺序为什么是"先存旧的、再换新的" ----
    #
    # `input$api_key` 此刻装的是**上一个厂商**的 Key。先把这一对
    # (key_vendor(), input$api_key) 落进钥匙串，再切 key_vendor()，
    # 归属就永远不会错。反过来先切、再读输入框，读到的旧值就会被记到新
    # 厂商名下 —— 而这是**静默**的：界面上一切正常，只有下次切回来才会
    # 发现多了一把用不了的 Key。
    #
    # ⚠️ 这个 observer 必须注册在下面那个"状态同步到会话"的 observe **之前**。
    #    Shiny 在同一轮里按创建顺序跑 observer，晚注册的话 state$api_key
    #    会先用旧值同步一次，而 state 是发消息时真正读的那个。
    observeEvent(input$vendor, {
      uid <- state$user_id
      newv <- input$vendor %||% ""
      oldv <- key_vendor()
      if (is.null(uid) || !identical(loaded_for(), uid)) return()
      if (is.null(oldv) || !nzchar(newv) || identical(oldv, newv)) return()

      con <- dsapp_db(cfg)

      # 1) 把输入框里这把钥匙记到**它自己的**厂商名下
      cur <- input$api_key %||% ""
      if (nzchar(cur)) {
        dsapp_api_key_put(uid, oldv, cur,
                          base_url = input$base_url, model = input$model,
                          con = con)
      }

      # 2) 换上新厂商记住的那一套
      key_vendor(newv)
      rec <- dsapp_api_key_recall(uid, newv, con = con)
      # 这三格是**服务端**按钥匙串填回去的，不是用户敲的 —— 所以快照里对应
      # 的格子要跟着刷（见 snap_one 的说明）。不刷的话，用户只是换了个厂商，
      # 提醒框里会连「接口地址」「API Key」「模型」一起列出来，像是他自己改了
      # 四样东西。厂商那一格**不刷**：那确实是他改的，提醒该不该弹就看它。
      updateTextInput(session, "api_key", value = rec$api_key %||% "")
      snap_one("api_key", rec$api_key %||% "")
      if (!is.null(rec$base_url) && nzchar(rec$base_url)) {
        updateTextInput(session, "base_url", value = rec$base_url)
        snap_one("base_url", rec$base_url)
      }
      if (!is.null(rec$model) && nzchar(rec$model)) {
        updateSelectizeInput(session, "model", selected = rec$model)
        snap_one("model", rec$model)
      }

      # 3) 让这一家生效。**必须显式调**：这家没存过 Key 的时候 updateTextInput
      #    推的是空串，而空串在保存那边是"不动"（见 dsapp_settings_save 的
      #    说明），users.llm_api_key 会留着上一家的 Key —— 那正是要修的那个
      #    bug。activate() 会把列写成 NULL，界面才是诚实的。
      dsapp_api_key_activate(uid, newv, con = con)
      state$api_key <- rec$api_key %||% ""
      key_ver(key_ver() + 1)
    }, ignoreInit = TRUE)

    # =======================================================================
    # 「改了但没点更新」的快照（V13.11 item 8）
    # =======================================================================
    #
    # 用户原话：「离开模型服务界面时如果有信息更新未确认，应该提醒用户确认」。
    #
    # 判据是**快照对比**：snap() 记的是"上一次已确认时这四个控件长什么样"，
    # 初始加载后记一次，每次保存成功后再记一次。任何一个对不上 = 有未确认的
    # 改动。
    #
    # ⚠️ 为什么不直接拿控件跟**库里的值**比。库里的值要过一轮归一化才进控件：
    #      厂商停用   → 回落 "deepseek"（mod_model_ui 里那行 if）
    #      模型不在清单 → 补一组「当前使用」再选它
    #      模型名为空  → 取候选清单的第一个
    #      没存过地址  → 显示 ""，而库里可能是 NULL
    #    直接比的话，一个**从没配过**的用户一打开就是"脏"的，每收一次面板弹
    #    一次框 —— 那不是提醒，是骚扰，而且很快就会被当成噪声无视掉。快照比
    #    的是**控件值 vs 控件值**，上面这些归一化一个都碰不到。
    #
    # ⚠️⚠️ 这一段（定义 + 首次记快照）**必须注册在下面那个"状态同步到会话"
    #    之前**。那个 observe 会按 dsapp_model_migrate() 把用户存过的旧模型名
    #    改写成新名字再推给浏览器，而它和"首次记快照"是**同一轮**触发的 ——
    #    晚注册的话，快照记的是改写**前**的值，浏览器随后报上改写后的值，
    #    于是"用户什么都没动，却被问了一句模型改了还没确认"。
    #    同一族的坑还有下面 snap_one() 处理的那些：凡是**服务端自己**写进控件
    #    的值，都不该算成用户的改动。
    snap <- reactiveVal(NULL)

    # 服务端程序式地改了某个控件 → 快照里对应的那一格跟着刷。
    #
    # 为什么非要有这一手：changed_fields() 分不清"框里的值是用户敲的"还是
    # "服务端刚推下去的"，它只比控件当前值和快照。模型下拉尤其容易中招 ——
    # 点「更新」会顺手去拉一次厂商的模型清单（start_verify），清单回来后
    # observeEvent(model_choices()) 发现当前选中的名字不在清单里，会把它换成
    # 清单里的第一个。于是**刚点完更新、用户一个字都没动**，切页却被告知
    # 「模型改了还没确认」。快照跟着推送一起写，这个误报就没有了。
    #
    # ⚠️ 只在快照**已经存在**时改它。快照还没建（四个控件的值还没报齐）时
    #    直接返回，让下面那个 observer 去建 —— 在这里种一个只有一格的快照
    #    更糟：那一格之外的三格会全被算成"改动"。
    snap_one <- function(key, value) {
      s0 <- isolate(snap())
      if (is.null(s0)) return(invisible(FALSE))
      s0[[key]] <- value %||% ""
      snap(s0)
      invisible(TRUE)
    }

    # 这四个控件报上值之后再记快照。⚠️ 四个都要**先读一遍**再判空：读是建立
    # 依赖的唯一方式，把判空写在前面的话，第一次跑（值还没到）就直接返回、
    # 一个依赖都没建，以后值到了也不会再跑 —— 快照永远是 NULL，提醒永远不响。
    observe({
      v <- input$vendor
      m <- input$model
      b <- input$base_url
      k <- input$api_key
      if (!is.null(isolate(snap()))) return()
      # 等 vendor 就够：它是必填的下拉，一定有值。model 在"还没填 Key、候选
      # 清单是空的"时候可能一直是 NULL，等它就等于永远不记快照。
      if (is.null(v)) return()
      snap(list(vendor = v, model = m %||% "",
                base_url = b %||% "", api_key = k %||% ""))
    })

    # ---- 对话页请求换模型（V15.8 item 3）------------------------------------
    #
    # 用户原话：「现在得对话途中切换模型，是否能够继承上下文继续交流？
    #            如果不能，请增加这个功能」。
    #
    # 机制上本来就**能**（上下文在库里，每轮重新拼；见 R/llm.R 的
    # dsapp_scene_messages），浏览器探针实测 20/20 —— 缺的是**入口**：
    # 对话页只能显示在用哪个模型，想换得离开那一页跑一趟「模型服务」。
    # 所以 mod_chat.R 那边加了一格下拉，而它**不自己写库**，只把请求写进
    # `state$model_req`；执行者是这里。
    #
    # ⚠️⚠️ 为什么不干脆让对话页自己写库：写模型这件事除了"改一个字段"，
    #    还牵着 dsapp_model_migrate() 的旧名改写、温度/上下文上限按新模型
    #    重新夹取、800ms 防抖落库、以及 user_api_keys 里那份按厂商存的副本
    #    —— 这四件事现在只在这一处。在别处再写一遍就是**第二个写入者**，
    #    两套规则迟早对不上，而症状是"界面显示的模型和实际出网的模型不是
    #    一个"（V15.7 item 8 正是栽在这个形状上）。
    #
    # ⚠️ 手法是 updateSelectizeInput，即"**替用户动这个控件**"，之后一切照旧：
    #    浏览器把 input$model 报上来 → 下面那条 observe 走完整的迁移/夹取/
    #    防抖 → 落库。这样对话页那条路和用户手动换模型**走的是同一条代码**，
    #    不存在"两条路行为不一致"。
    #
    # ⚠️⚠️ snap_one() 这一句不能省。changed_fields() 分不清"框里的值是用户
    #     敲的还是服务端推下去的"，它只比控件当前值和快照 —— 不刷快照的话，
    #     用户在对话页换个模型，之后每次离开「模型服务」页都会被问一句
    #     「模型改了还没确认」，而那个改动不是他在这一页做的。
    #     （同一个坑在上面 snap_one 的定义处写着，这里是它的第三个调用点。）
    observeEvent(state$model_req, {
      rq <- state$model_req
      if (is.null(rq) || !nzchar(rq$model %||% "")) return()
      # 已经是这个值了就什么都不做：updateSelectizeInput 会让浏览器把值报
      # 回来，不判等的话"对话页说一遍、模型页应一遍"会来回推。
      if (identical(isolate(state$model) %||% "", rq$model)) return()
      snap_one("model", rq$model)
      updateSelectizeInput(session, "model", selected = rq$model)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # =======================================================================
    # 状态同步到会话
    # =======================================================================
    #
    # 原来是 mod_settings.R 里的一个普通 observe（任何 input 变化都会刷一遍），
    # 保持原样搬过来 —— 它是 state 的唯一写入口，改掉触发条件要重新想一遍
    # "控件重建的瞬间 input 会变 NULL"这条（见 rv 的说明）。

    #' 把「单次使用上限」写进 state（★ V16.2 item 2 抽出来的）
    #'
    #' @param mt_want 用户想要的那个值（哨兵 0 = 不设上限 = 跟随模型）
    #' @param vendor  厂商/模型：夹范围要用，原样从调用点传进来
    #'
    #' ⚠️ 抽成函数是因为它现在有**两个**调用点：下面这个 observe()，以及
    #    接收对话页指令的那条 observeEvent。两处各写一份的话，"不设上限
    #    走 FOLLOW、设了数走 clamp"这条规则迟早只在一边被改 —— 而它的
    #    症状是"从对话页设的不设上限会跟随模型，从模型页设的不会"。
    #' ⚠️ 判据是 dsapp_maxtok_is_unlimited()，**不是** `mt_want > 0`：
    #'    NULL / NA / numeric(0) 三种"没取到"都算不设上限（见 models.R 那段），
    #'    写成数值比较会在这三种情况下抛错或静默走错分支。
    apply_ctx_limit <- function(mt_want, vendor) {
      state$ctx_limit <- if (dsapp_maxtok_is_unlimited(mt_want)) {
        DSAPP_CTX_FOLLOW
      } else {
        dsapp_ctx_clamp(vendor, state$model, mt_want)
      }
      invisible(state$ctx_limit)
    }

    observe({
      # ★★ Test_V15.4 item 1：**空厂商一个字节都不许往 state 里写。**
      #
      #    `%||%` 只挡 NULL，**不挡空串**（见 R/utils.R）。控件重建的那一瞬间
      #    `input$vendor` 报上来的可能是 ""，于是这里把 `state$vendor` 写成 ""，
      #    而下游 `dsapp_api_key_effective()` 对空厂商**直接返回 ""** ——
      #    表现就是"对话页让你去设置页填 API Key"，而用户明明填过、库里的列
      #    也好好地有 Key。用户唯一的出路是重新粘一遍（他说的"额外的操作"）。
      #
      #    这一条和下面 `pending()` 那个 observer 里的 `if (!nzchar(p$vendor))`
      #    是**同一条**规矩：厂商下拉永远有选中项，"厂商 = 空"只可能是
      #    "还没报上来"。空的时候跳过，等它报上来这一轮会再跑。
      #
      #    ⚠️ `input$vendor` 已经在上一行读过了（读 = 建立依赖），所以这里
      #       return 掉不会漏掉后续的更新 —— 别把这句挪到读之前。
      v <- input$vendor
      if (is.null(v) || !nzchar(v)) return()
      supports <- dsapp_vendor_supports_thinking(v)

      state$vendor    <- v
      state$base_url  <- dsapp_vendor_base_url(v, input$base_url)

      # ★★ V13.7 item 3：这里**绝不能**再写 `state$api_key <- input$api_key`。
      #
      #   用户原话：「api key 的记忆功能有点问题」。
      #
      #   `input$api_key` 是**浏览器**报上来的值。服务端刚用 updateTextInput
      #   推过去一个新值时，浏览器要等下一次往返才会把新值报回来；在那之前
      #   input$api_key 装的还是**上一家的 Key**。而本 observe 注册在切厂商
      #   那个 observer **之后**，同一轮里后跑 —— 于是它把那边刚从钥匙串里
      #   取出来、刚写好的 state$api_key 当场盖回旧值。
      #
      #   state$api_key 正是发消息时读的那一个（mod_chat 的闸门 + 发送路径），
      #   所以"切完厂商立刻发一条"发出去的是上一家的 Key，而回来的 401 里
      #   一个字都不提厂商 —— 用户只能猜。
      #
      #   去掉之后，state$api_key 只剩**从库里读**的写入口：
      #     · 载入设置（上面）     —— 读 users.llm_api_key
      #     · 切厂商（上面）       —— 读钥匙串里这一家的
      #     · 用户敲进输入框        —— 见下面的 observeEvent(input$api_key)
      #     · 清除 / pending 自愈   —— 置空或读库补回来
      #   浏览器不再是第二个真相源。

      # 用户从旧笔记里抄来的模型名（deepseek-chat 之类）现在是必然报错的。
      # 能确定替代品就当场换掉，并把换的结果写回输入框，让他看得见。
      mg <- dsapp_model_migrate(v, input$model)
      state$model <- mg$model
      if (isTRUE(mg$changed) && !identical(mg$model, input$model)) {
        updateSelectizeInput(session, "model", selected = mg$model)
        # 同上：这一格是服务端替他改的名，不是他改的。
        snap_one("model", mg$model)
      }

      # ★ V13.6 item 3：**在写进 state 的这一刻**把两个参数夹进当前
      #   (厂商, 模型) 的范围。
      #
      #   为什么非要有这一道，光靠控件上那层不够：
      #     · numericInput 的 min/max 只是浏览器侧的校验，粘贴/手打都能越界；
      #     · 真正要命的是**换厂商**：范围跟着变了，而 rv 里还留着上一家的
      #       值。用户在 DeepSeek 上把上限调到 65536，切到一家只支持 8192 的
      #       厂商，滑块量程会变、控件会重建，但 rv$maxtok 还是 65536 ——
      #       下一次发消息就是 400。夹在这里，所有出口（对话页、agent 循环、
      #       起标题那次短请求）读到的都是夹过的值。
      #
      #   ⚠️ 顺序：必须排在 state$model 定下来**之后**。模型档是按模型名匹配
      #      的，拿 input$model 去夹的话，用户手打了已下线的模型名时夹的是
      #      错的范围（真实发出去的是迁移后的那个名字）。
      state$temperature <- dsapp_param_clamp(v, state$model, "temperature",
                                             rv$temp, default = 0.3)
      # ★ V13.14 item 22：滑块拉到最右 / 输入栏被清空 = 不设上限，
      #   写进 state 的是哨兵 0，而且**不能**经过 dsapp_param_clamp ——
      #   那个函数把值夹进 [min, max]，0 会被夹成 min = 1024，于是
      #   "不设上限"在这里静默变成"上限 1K"，一路发到厂商那边。
      #
      #   ⚠️ `input$max_tokens %||% rv$maxtok` 那一句在这里挡的是 **NULL**
      #      （参数区重建的那一瞬间 input 会短暂变 NULL），不是 NA —— 本仓的
      #      `%||%` NULL 和 NA 都挡（见 R/utils.R，第 4 行就是
      #      `if (is.na(a[1])) return(b)`）。
      #
      #      清空输入栏给的是 NA，所以它走的是 rv$maxtok；而 rv$maxtok 在上面
      #      那条 observer 里已经被归一成哨兵 0 了（那条 observer 的
      #      ignoreNULL **挡不住 NA** —— NA 不是 NULL，所以清空会正常触发）。
      #      两条路殊途同归，都落在哨兵上。
      # ★★ V15.5 item 6：这一格的含义**变了**。
      #
      #   改之前它写的是 state$max_tokens（单次**回复**上限），发请求时原样
      #   发给厂商。用户第 6 条问的就是它：「你的单次回复上限是指模型的上下文
      #   长度吗？」—— 不是。它只管回复那一半，而"这次能带多少历史进去"是
      #   另一个写死的数（R/llm.R 的 48000 字符），两者谁也不知道谁。
      #
      #   现在它写的是 state$ctx_limit：**一次请求（上下文 + 回复）合计**
      #   能用多少 token。回复上限不再单独设，由它推出来（models.R 的
      #   dsapp_ctx_plan）。
      #
      #   ⚠️ 夹的范围也跟着换了：原来夹的是 dsapp_param_range(..., "max_tokens")
      #      （厂商那一侧的回复上限，量程 1K ~ 10M），现在夹的是**这个模型自己
      #      的上下文窗口**（deepseek 1M，查不到出处的退回 128K）。
      #      不换的话，"单次使用上限"会被一个管回复的数悄悄夹到 8192。
      #
      #   ⚠️ 哨兵 0 的含义也从「不设上限」变成「跟随模型」。同一个 0，同一套
      #      dsapp_maxtok_is_unlimited()，只是下游 dsapp_ctx_limit() 拿它
      #      去查窗口，而不是"不发 max_tokens 字段"。
      mt_want <- input$max_tokens %||% rv$maxtok

      # ★★ V16.2：**陈旧回发**（定义见上面 maxtok_stale 那段）。
      #
      #    这一格有时候装的**不是**用户输入，是"还没跟上的旧值"—— 对话页刚
      #    下过指令、接收端把这一格按成新值，而浏览器还没回发。那种时候
      #    它是没有资格写真相的：按它写 = 把刚下的指令撤销。
      #
      #    ⚠️ 比较走 all.equal（数值），**不是** identical：这一格从浏览器
      #       报上来的是 double，而 rv$maxtok 可能是整数（常量里带 L），
      #       identical(49152L, 49152) 是 FALSE —— 那样守卫永远不生效，
      #       而症状和没修一模一样，还不报错。
      if (!is.null(maxtok_stale)) {
        x <- suppressWarnings(as.numeric(input$max_tokens)[1])
        if (length(x) == 1L && !is.na(x) &&
            isTRUE(all.equal(x, as.numeric(maxtok_stale)[1]))) {
          mt_want <- rv$maxtok
        } else {
          maxtok_stale <<- NULL     # 这一格已经跟上来了，守卫用完就撤
        }
      }
      apply_ctx_limit(mt_want, v)

      # 不支持思考模式的厂商就别发这两个参数 —— 有的厂商见到未知参数会
      # 直接 400，而不是忽略。
      state$thinking <- if (supports) rv$thinking else NULL
      state$reasoning_effort <- if (supports && isTRUE(rv$thinking)) rv$effort else NULL
    })

    # =======================================================================
    # 落盘（item 1）
    # =======================================================================

    # 保存状态那一行的刷新信号。和 mod_settings 里 pw_ver 是同一个套路：
    # ⚠️ 只能在 observeEvent 里 +1，写进 renderUI 会让 output 依赖自己，
    #    服务端反复重算，浏览器报一串 "output is in an unexpected state"。
    key_ver <- reactiveVal(0)

    # 只在"用户真的改了什么"之后写。`loaded_for()` 还没被设上时（账号刚切
    # 过来、控件还是上一个账号的值）写库，等于把 A 的 Key 抄到 B 名下。
    pending <- reactive({
      list(vendor   = input$vendor %||% "",
           model    = input$model %||% "",
           base_url = input$base_url %||% "",
           api_key  = input$api_key %||% "")
    }) |> shiny::debounce(800)

    # ---- 用户敲进 Key 输入框的每一个字，记到**它自己的**厂商名下 ----------
    #
    # ⚠️ 归属取 key_vendor()，**不是** input$vendor。这两个在这一刻通常一样，
    #    但换厂商的那一瞬间恰好不一样（input$vendor 已是新的、输入框里还是
    #    旧的），而这一句就是决定那把 Key 记到谁名下的地方 —— 取错了是静默
    #    错一位，下次切回来才会发现。为什么不在这里加个标志位去防那个瞬间：
    #    那个瞬间根本不会产生 api_key 事件（事件来自浏览器，而用户此刻在点
    #    下拉框，没在打字），见上面切厂商那段。
    #
    # ⚠️ 不防抖。vault 是一条走主键的本地 UPDATE，比防抖省下来的那点开销
    #    便宜得多；而防抖意味着"刚粘完 Key 就换厂商"会丢掉它 —— 那正好是
    #    用户最常做的动作（粘完 A 家的，去看看 B 家的）。
    observeEvent(input$api_key, {
      uid <- state$user_id
      if (is.null(uid) || !identical(loaded_for(), uid)) return()
      v <- key_vendor()
      if (is.null(v) || !nzchar(v)) return()
      # 空串 = "不要动已存的那把"（和 dsapp_settings_save 同一条规矩）。
      # 真删只有一条路：下面那个「清除」。
      if (!nzchar(input$api_key %||% "")) return()

      con <- dsapp_db(cfg)
      dsapp_api_key_put(uid, v, input$api_key,
                        base_url = input$base_url, model = input$model,
                        con = con)
      # 记住之后立刻让它生效 —— 用户粘完 Key 直接去对话页发消息是很常见的，
      # 那一刻不生效的话他会收到"请先到设置页填 API Key"，而他明明刚填完。
      dsapp_api_key_activate(uid, v, con = con)

      # ★ V13.7 item 3：state 跟着走。
      #
      #   上面那个"状态同步到会话"的 observe 已经不写 state$api_key 了，
      #   这里是**唯一**由用户输入驱动的写入口 —— 少了这一句，用户刚粘完
      #   Key 就去对话页发消息，闸门读到的还是库里那把旧的。
      state$api_key <- input$api_key
      key_ver(key_ver() + 1)
    }, ignoreNULL = TRUE)

    observeEvent(pending(), {
      uid <- state$user_id
      if (is.null(uid) || !identical(loaded_for(), uid)) return()
      p <- pending()

      # ★★ V13.6 item 1：**控件还没把值报上来时，一个字节都不许写。**
      #
      #   原来的守卫只管"账号对不对"（loaded_for == uid），管不住"控件有没有
      #   值"。而这两件事的时序是错开的：
      #
      #     state$user_id 由登录闸门写 → 这个守卫当场就放行了；
      #     而 input$vendor 要等浏览器**把 app_root 渲染出来之后**才有值
      #     （模型面板在 renderUI("app_root") 里），中间隔着一整轮往返。
      #
      #   于是在这个窗口里 pending() 一到期，p$vendor / p$model / p$base_url
      #   全是空串，下面两句就把用户存过的设置**写成空的**：
      #     · settings_save(vendor="", model="", base_url="") —— 厂商/模型/地址没了；
      #     · api_key_activate(uid, "") —— 顺带把 users.llm_api_key 写成 NULL。
      #
      #   为什么"每次退出登录/异端登录"都能撞上：这两条路都是**整页重载**
      #   （退出是 session$reload()，被顶下线是 window.location.replace()）。
      #   重载 = 旧会话的 websocket 断开，Shiny 会把这一端的 input 全部置 NULL
      #   → pending() 失效 → 800ms 后到期，而这时 state$user_id 还好好地指着
      #   那个账号 → 守卫放行 → 抹库。2026-09-17 用 message() 抓到过现场：
      #
      #     [v136dbg] pending fired uid=[7] loaded_for=[7] vendor=[] model=[] base=[] key_len=0
      #     [v136dbg] settings_save uid=[7] vendor=[] model=[] base=[]
      #     [v136dbg] activate uid=[7] vendor=[]
      #     （下一拍浏览器把真值报上来，vendor/model 被写回去，但页面**已经
      #       在库被抹空的那一刻渲染过了** —— 所以输入框里带出来的是空串，
      #       用户手填的中转地址就此永久丢失。）
      #
      #   厂商下拉永远有选中项，"厂商 = 空"只可能是"还没报上来"。所以拿它
      #   当闸门：空就整个跳过，什么都不写。
      if (!nzchar(p$vendor)) return()

      # ⚠️ 这里**不再**把 p$api_key 往库里写（V13.1 item 5 之前是写的）。
      #    写 Key 已经归上面那个 observeEvent(input$api_key) 管，它知道归属；
      #    这里只知道 p$vendor，而防抖之后的那一刻 p$vendor 可能已经换成
      #    别家了 —— 把上一家的 Key 写到这一家名下，正是 item 5 要修的 bug。
      tryCatch(
        dsapp_settings_save(uid, vendor = p$vendor, model = p$model,
                            base_url = p$base_url,
                            con = dsapp_db(cfg)),
        error = function(e) NULL)
      # ★★ Test_V15.8 item 3：模型改了，就把"这一家记住的模型"一起刷成新值。
      #
      #    从前这一份副本只在**用户敲了 Key** 的时候写，所以改一次下拉它就陈旧
      #    一分；而它在**换厂商那一刻被当成权威**（本文件上面
      #    `observeEvent(input$vendor)` 把 recall() 的 model 直接推回下拉）。
      #    生产库里 uid=11 就是现场：库是 qwen3.8-max、副本是 deepseek-flash。
      #    详见 dsapp_api_key_sync_model() 的说明。
      #
      #    ⚠️ 放在 settings_save **之后**：写库为准，副本跟着走。反过来先写副本
      #       的话，settings_save 万一失败（返回 FALSE，它不抛），副本就替库里
      #       记了一个**根本没生效**的值 —— 下次切回来会把它当真。
      tryCatch(
        dsapp_api_key_sync_model(uid, p$vendor, p$model, con = dsapp_db(cfg)),
        error = function(e) FALSE)
      # 让列跟上"当前厂商那把 Key"。这一步同时兜住了另一种情况：切到一家
      # 没存过 Key 的厂商之后，列必须是 NULL，不能留着上一家那把。
      tryCatch(
        dsapp_api_key_activate(uid, p$vendor, con = dsapp_db(cfg)),
        error = function(e) NULL)

      # ★ V13.6 item 1：**自愈**。上面那句 activate 有可能刚刚才把
      #   `users.llm_api_key` 从钥匙串里补回来（列被更早的版本抹成 NULL、
      #   或者被外部的库操作改过）。补回来的是**库**，而内存里的 state$api_key
      #   还是它读库那一刻读到的空值 —— 对话页的闸门读的正是 state$api_key，
      #   于是会出现"库里明明有 Key，发消息却让你去设置页填"。
      #
      #   只在**两边都空**的时候补：state 空 = 没生效的 Key，输入框也空 =
      #   用户此刻没在打字。任何一个不空都说明有更权威的来源（用户刚粘的）。
      if (!nzchar(state$api_key %||% "") &&
          !nzchar(input$api_key %||% "")) {
        s2 <- tryCatch(dsapp_settings_get(uid, con = dsapp_db(cfg)),
                       error = function(e) list())
        if (nzchar(s2$api_key %||% "")) state$api_key <- s2$api_key
      }
      key_ver(key_ver() + 1)
    }, ignoreNULL = TRUE)

    output$key_state <- renderUI({
      key_ver()
      uid <- state$user_id
      if (is.null(uid)) return(NULL)

      s <- tryCatch(dsapp_settings_get(uid, con = dsapp_db(cfg)),
                    error = function(e) list(saved = FALSE))

      # ⚠️ 文案不能写成"关闭页面即失效"。V6 起 Key 是存库的，那句话是假的。
      #
      # V13.1 item 5 起是**按厂商**记的，所以这里得说清楚记的是哪一家 ——
      # 用户切到 Kimi、看到"Key 已记住"，会合理以为是 Kimi 的；而如果那是
      # 上一家留下的，他发出去的消息就会因为用了错的 Key 而 401。
      if (isTRUE(s$saved)) {
        vl <- tryCatch(dsapp_vendor(s$vendor)$label, error = function(e) NULL)
        div(class = "dsapp-key-state is-saved",
          icon("floppy-disk"),
          # V13.2 item 7：用户指定的文案。原来那句写的是"存在服务器上"，
          # 而 V13.1 item 9 起落盘的是密文，所以说"已加密保存"才是准确的。
          " Key 已加密保存（服务商切换时URL和Api会同步切换）",
          # ⚠️ 厂商名**保留**，虽然用户给的新文案里没有它。
          #    V13.1 item 5 特意加上它的理由仍然成立：用户切到 Kimi、看到
          #    "Key 已加密保存"，会合理以为是 Kimi 的；而如果那是上一家留下的，
          #    他发出去的消息就会因为用了错的 Key 而 401。这句是**安全提示**，
          #    不是装饰 —— 要去掉的话请连着 tests/ui_v131/keys.py 里那条断言
          #    一起改（它盯着"这里必须点明是哪一家"）。
          tags$span(class = "dsapp-key-vendor",
                    sprintf("当前：%s", vl %||% s$vendor %||% "当前厂商")),
          # ⚠️ 这个"清除"清的是**所有厂商**的 Key，不只是当前这家。
          #    文案里必须写出来 —— 只写"清除"，用户会以为只删这一把，
          #    然后另外几家的凭据悄悄留在服务器上，而他以为已经清干净了。
          actionLink(ns("forget_key"), "清除全部厂商", class = "ms-1")
        )
      } else {
        # ⚠️ 这里原来写的是「Key 只在本次会话有效 —— 填上之后会替你记住」，
        #    前后两截自相矛盾：前半句是 V5.2 的行为（只在会话内存里），
        #    后半句才是 V6 的行为。**留着前半句就是一句假话**，而且是最坏的
        #    那种 —— 用户会以为 Key 是一次性的，于是放心在公用机器上粘贴。
        #    V6 改了行为却没改这句文案，是 2026-09-14 从界面截图上发现的，
        #    源码里搜"不落盘"是搜不到它的（它没写那三个字）。
        # V13.2 item 7：和上面那条口径一致 —— 说的是**加密**存。
        # 只改上面不改这里的话，同一个开关的两个状态一句说"已加密"、
        # 一句说"存在服务器上"，用户会以为填进去之后是明文。
        div(class = "dsapp-key-state",
          icon("clock"), " 还没保存 Key —— 填上之后会加密存在服务器上，下次自动填好")
      }
    })

    # ---- 「改了但没点更新」的判据（V13.11 item 8）--------------------------
    #
    # snap() 和 snap_one() 定义在上面「状态同步到会话」之前 —— 那里有为什么
    # 必须先注册的完整说明，别把定义挪回这里。

    # 改了哪几样。返回的是**给人看的名字**，直接进确认框。
    changed_fields <- function() {
      s0 <- snap()
      if (is.null(s0)) return(character(0))
      out <- character(0)
      if (!identical(input$vendor   %||% "", s0$vendor))   out <- c(out, "厂商")
      if (!identical(input$model    %||% "", s0$model))    out <- c(out, "模型")
      if (!identical(input$base_url %||% "", s0$base_url)) out <- c(out, "接口地址")
      # ⚠️ 比的是**框里的字**。Key 存过之后密码框是预填好的，所以"没动过"
      #    时它跟快照一样，不会误报；用户重新粘了一把（哪怕内容碰巧相同）
      #    也一样不算改动 —— 那正是我们想要的。
      if (!identical(input$api_key  %||% "", s0$api_key))  out <- c(out, "API Key")
      out
    }

    # ---- 离开这一页时提醒（V13.11 item 8；V13.12 item 19 换了判据）---------
    #
    # 用户原话：「离开模型服务界面时如果有信息更新未确认，应该提醒用户确认」。
    #
    # ⚠️ **判据换过一次，别照抄老注释**：V13.11 那会儿模型服务是左栏最下面
    #    一块常驻的 <details>，不属于任何一页 —— 切页面时它还在原地待着，
    #    所以"离开"只能是"把它折叠收起"，信号由前端上报
    #    （input$rail_model_closed，递增计数）。
    #    V13.12 item 19 把它搬成了独立页，"离开"就是**切页**，信号变成
    #    state$nav（app.R 的 input$nav 那条发布的），那块 <details> 和前端
    #    上报一起删掉了。
    #
    # ⚠️ 为什么提醒是**切走之后**才弹，而不是拦住不让切：bslib 的 navset
    #    在客户端就把页换了，服务端这一拍只可能"已经换完"。拦要改成前端
    #    拦（这一版没做）—— 反正提醒的目的是"提醒"，不是"阻止"，而弹框里
    #    那颗「回去继续编辑」一键就跳回去了。
    #
    # ⚠️ 用 nav_seen 记**上一次**的值，而不是拿 state$nav 跟 "model" 直接比：
    #    每次切页都会进这里，直接比的话"在别的页之间来回切"也会弹框。
    nav_seen <- reactiveVal(NULL)
    observeEvent(state$nav, {
      prev <- nav_seen()
      nav_seen(state$nav)
      # 只有"从模型服务页切走"才算离开（进这一页、以及别的页之间互切都不算）
      if (!identical(prev, "model")) return()
      if (identical(state$nav, "model")) return()
      ch <- changed_fields()
      if (!length(ch)) return()
      showModal(modalDialog(
        title = tagList(icon("triangle-exclamation"),
                        " 模型服务还有改动没确认"),
        tagList(
          p(sprintf("下面这些改过了，但还没点「更新」：%s。",
                    paste(ch, collapse = "、"))),
          # ⚠️ 这句话必须跟**实际行为**对得上，而且这块面板的真实行为不直观：
          #    四个框都由 observeEvent(pending(), …) 在 800ms 防抖后**自动落库**，
          #    state$vendor / state$base_url 也是直接跟着输入走的 —— 所以改完
          #    什么都不点，它照样生效、照样存下来。
          #
          #    第一版这里写的是「「更新」之前这些不会生效，对话那边还在用旧的
          #    设置」—— 那是**一句假话**，而且是会让人做出错误决定的那种：
          #    用户会以为不点就没事，于是放心地把半截配置留在那儿。
          #    写提醒文案之前先把"不点会怎样"真正跑一遍，别照着直觉写。
          #
          #    真话是：不点也不会丢，但有两件事**只有点了才会发生** ——
          #    左栏那一项下面的小字跟着变（那是唯一不进来就看得见的一行字），
          #    以及拿新 Key 真去试一次请求。这两件都值得他点一下。
          p(class = "small text-muted",
            "不点也不会丢，改动会自动保存。但左栏「模型服务」下面那行小字",
            "要等你点了「更新」才会跟着变，新填的 Key 也要点了才会去试一次",
            "能不能用。")
        ),
        easyClose = TRUE,
        footer = tagList(
          actionButton(ns("rail_dismiss"), "回去继续编辑",
                       class = "btn-primary"),
          # ⚠️ 这个按钮**只是关掉提醒，不回滚任何东西**。做成"放弃改动"就得
          #    把四个控件刷回快照值，而 updateSelectInput(vendor) 会触发那个
          #    "切厂商带 base_url 过去"的观察者，把刚刷回去的地址又改成厂商
          #    默认值 —— 结果是点了"放弃"反而多出一次改动。文字的承诺必须跟
          #    行为一致，所以这里说的是"先这样"，不是"放弃"。
          actionButton(ns("rail_collapse"), "先这样，稍后再说",
                       class = "btn-outline-secondary")
        )
      ))
    })

    # 「回去继续编辑」= 跳回模型服务那一页（V13.12 item 19：它现在是普通
    # 的一页，跳转走 dsapp_nav_to —— ⚠️ 必须用它，不能用模块自己的 session，
    # 理由见 R/utils.R 里 dsapp_nav_to 那段：模块 session 上跳页静默失效）。
    observeEvent(input$rail_dismiss, {
      removeModal()
      dsapp_nav_to(state, "model")
    })

    observeEvent(input$rail_collapse, removeModal())

    observeEvent(input$forget_key, {
      uid <- state$user_id
      if (is.null(uid)) return()
      # 返回的是清掉的**把数**（V13.1 item 5：现在是按厂商存的多把）。
      n <- dsapp_settings_forget_key(uid, con = dsapp_db(cfg))
      updateTextInput(session, "api_key", value = "")
      # 输入框被清空**不会**产生 api_key 事件（空串在那边是"不动"），
      # 所以得手动把归属退回默认 —— 不退的话，用户清完再手打一把新 Key，
      # 会被记到清空之前那个厂商名下（通常没问题，但换个厂商再清就错了）。
      key_vendor(state$vendor %||% "deepseek")
      state$api_key <- ""
      # V13.11 item 8：密码框是被**程序**清空的，不是用户改的 —— 不同步快照
      # 的话，清完再收起面板会被问"API Key 改了还没确认"，而那个改动不是他做的。
      snap(list(vendor   = input$vendor   %||% "",
                model    = input$model    %||% "",
                base_url = input$base_url %||% "",
                api_key  = ""))
      key_ver(key_ver() + 1)
      showNotification(
        sprintf("已清除保存在服务器上的 API Key（%d 把，所有厂商）。",
                as.integer(n %||% 0L)),
        type = "message", duration = 6)
    })

    # ---- 确认 / 更新（V7 item 3；V13.15 item 26 变成头尾两颗）---------------

    # ★ V13.15 item 26：两颗按钮（头部 commit_top / 底部 commit）**共用**下面
    #   这两个 id 表，不各写一遍 —— 写两遍的下场是某天只改了其中一颗的标签
    #   或提示，而两颗长得一模一样，界面上的表现只是"有一颗说的是旧话"，
    #   不报错、也说不清是哪一颗。
    #
    #   ⚠️ 底部那颗的 id 仍然是 `commit`（不是 commit_bottom），理由写在
    #      mod_model_ui 里那个 commit_btn() 上面：`#model-commit` 有外部引用。
    COMMIT_BTNS <- c("commit", "commit_top")

    # 按钮文字的来源。它取决于**库里有没有一把 Key**，而不是输入框里有什么，
    # 所以必须每次重新查库 —— 用 key_ver() 当刷新信号（清除按钮、自动保存
    # 都会 +1）。**两颗一起刷**：只刷一颗的话，同一个页面上会并排出现
    # 一个「确认」和一个「更新」，用户会以为它们做的是两件事。
    observe({
      key_ver()
      uid <- state$user_id
      if (is.null(uid)) return()
      s <- tryCatch(dsapp_settings_get(uid, con = dsapp_db(cfg)),
                    error = function(e) list())
      lab <- if (isTRUE(s$saved)) "更新" else "确认"
      for (b in COMMIT_BTNS) updateActionButton(session, b, label = lab)
    })

    # ⚠️ 提示那一行也要两颗都有：它说的"还没填 Key，生成用不了"是**当前状态**，
    #    不是某一颗按钮的附注。只有底部有提示的话，从头部按下去的人不知道
    #    刚才那一下到底成没成（toast 会消失，提示不会）。
    commit_hint_ui <- function() {
      key_ver()
      uid <- state$user_id
      if (is.null(uid)) return(NULL)
      s <- tryCatch(dsapp_settings_get(uid, con = dsapp_db(cfg)),
                    error = function(e) list())
      if (isTRUE(s$saved)) {
        span(class = "small text-muted", "已保存，可直接用")
      } else {
        span(class = "small text-warning", "还没填 Key，生成用不了")
      }
    }
    output$commit_hint     <- renderUI(commit_hint_ui())
    output$commit_hint_top <- renderUI(commit_hint_ui())

    # ★ V13.15 item 26：头尾两颗按钮**共用这一个处理函数**（下面两条
    #   observeEvent 只是把各自那颗的点击接过来）。
    #
    #   ⚠️ 必须是**函数**而不是"把 observer 体抄两遍"：
    #      抄两遍之后，任何一次改动都得记得改两处，而漏改的表现是
    #      "点头部那颗和点底部那颗结果不一样" —— 两颗长得一模一样，
    #      用户报都报不清楚。和 mod_settings.R 那三颗「保存并返回对话」
    #      共用 goto_chat() 是同一个套路。
    do_commit <- function() {
      uid <- state$user_id
      if (is.null(uid)) {
        showNotification("还没登录，无法保存。", type = "warning")
        return()
      }

      # ⚠️ 这里**不走 debounce**，是"点了就立刻写"。这个按钮存在的全部意义
      #    就是给用户一个确定的时刻，再等 800ms 才落库等于没点。
      key <- input$api_key %||% ""
      r <- tryCatch(
        dsapp_settings_save(uid,
                            vendor   = input$vendor %||% "",
                            model    = input$model %||% "",
                            base_url = input$base_url %||% "",
                            # 空输入框不动已存的 Key —— 和自动保存那条同一个
                            # 规矩：用户可能是删了旧的、新的还没粘上。
                            api_key  = if (nzchar(key)) key else NULL,
                            con = dsapp_db(cfg)),
        error = function(e) e)

      # ★ Test_V16.3 item 2：**代理也在这里落库**。
      #
      #   为什么非要挂在这颗按钮上（它明明已经有 800ms 的防抖自动保存）：
      #   这一页的全部意义就是"填完了，有一个确定的时刻"。用户在代理那一块
      #   填完地址端口密匙，然后按「更新」—— 那一刻如果只有上面那张卡被存
      #   下去，他的代理就停在一个"看起来已经填好、实际还没落库"的状态里，
      #   而这一页没有任何东西告诉他这一点。防抖只是**兜底**，不是承诺。
      #
      #   ⚠️ 必须排在下面 `if (!nzchar(key))` 那个提前 return **之前**：
      #      只想配个代理、API Key 留空的人多得是，而他在那条路上点「更新」
      #      会直接返回 —— 代理白填。这一条和 V13.11 item 8 那条
      #      "snap 要排在提前 return 之前"是同一个坑，别踩第二次。
      save_proxy_now()

      # ★ Test_V15.8 item 3：和上面自动落库那条一样，把按厂商记的副本刷成新值。
      #    手动点「更新」这条路如果漏了这一句，用户"改完就点更新"反而留下一个
      #    更陈旧的副本 —— 两条路必须做同一件事（同一个理由见
      #    dsapp_api_key_sync_model()）。
      tryCatch(
        dsapp_api_key_sync_model(uid, input$vendor %||% "", input$model %||% "",
                                 con = dsapp_db(cfg)),
        error = function(e) FALSE)

      # 落进这把 Key **自己的**厂商名下（V13.1 item 5）。用 key_vendor() 不用
      # input$vendor，理由见上面那个 observeEvent(input$api_key)：这一句是
      # 归属的唯一判据，取错了是静默错一位。
      # 放在错误检查**之前**也无妨：写钥匙串自己包了 tryCatch，失败也只是
      # 这把 Key 没记住，不该让"设置已保存"变成一句假话。
      kv <- key_vendor()
      if (nzchar(key) && !is.null(kv) && nzchar(kv)) {
        dsapp_api_key_put(uid, kv, key,
                          base_url = input$base_url, model = input$model,
                          con = dsapp_db(cfg))
      }

      # ★★ Test_V15.4 item 1：让当前厂商生效这一步**不再**被 `nzchar(key)` 包着。
      #
      #   从前整段都在 `if (nzchar(key))` 里面，于是"Key 框是空的"时候点这个
      #    按钮，写钥匙串和让厂商生效**两件事都不做** —— 而 Key 框之所以是空
      #    的，恰恰因为读的是 `users.llm_api_key` 那一列，而那一列可能已经被
      #    抹成了 NULL（原件还在钥匙串里）。于是用户点「更新」，什么也没发生，
      #    界面还是"还没填 Key" —— 他只好重新粘一遍，就是"额外的操作"。
      #
      #    现在无条件走一次 activate()：钥匙串里有就把列补回来（自愈），
      #    没有就照常把列写成 NULL（用户切到一家没填过 Key 的厂商时，界面
      #    必须诚实）。这两种该走哪一条由 activate() 按**库里的现状**自己判，
      #    见它的函数头。
      #
      # ⚠️ 不能写成 `input$vendor %||% kv`（V13.6 item 1 顺手修的）：
      #    `%||%` 只挡 NULL，**不挡空串**。控件没报值时 input$vendor 是 ""
      #    而不是 NULL，于是这个表达式求值成 ""，activate 拿到空厂商 ——
      #    它现在直接返回 FALSE（安全边界），但那样"让当前厂商生效"这件事
      #    就静默没做了。这里显式判空。
      vv <- input$vendor %||% ""
      tgt <- if (nzchar(vv)) vv else (kv %||% "")
      if (nzchar(tgt)) {
        tryCatch(dsapp_api_key_activate(uid, tgt, con = dsapp_db(cfg)),
                 error = function(e) NULL)
        # 内存跟着走。只写库不写 state 的话，用户点完「更新」直接去发消息，
        # 闸门读到的还是旧的 state$api_key —— 库是对的、界面也是对的，
        # 只有真正发出去的那一次是错的。
        state$api_key <- tryCatch(
          dsapp_api_key_effective(uid, tgt, con = dsapp_db(cfg)),
          error = function(e) state$api_key %||% "")
        key_ver(key_ver() + 1)
      }

      if (inherits(r, "error")) {
        # ★ V13.7 item 2：不把 conditionMessage 原文摆给用户（见 selfheal.R
        #   顶部的说明）。原文进审计日志，屏幕上说人话 + 下一步。
        showNotification(
          dsapp_err_user(r, "保存这套模型设置",
                         hint = "刚填的内容还在框里，可以直接再点一次「确认」。"),
          type = "error", duration = 8)
        return()
      }
      key_ver(key_ver() + 1)

      # ★ V13.11 item 8：这一套已经确认过了，把快照刷成刚存下去的样子 ——
      #   不刷的话，用户点完「更新」再收起面板，会被问一句"你改了还没更新"，
      #   而他才刚更新完。**这一行必须排在下面那个提前 return 之前**：
      #   没填 Key 的那条路也是"设置已经存下来了"，同样算确认过。
      snap(list(vendor   = input$vendor   %||% "",
                model    = input$model    %||% "",
                base_url = input$base_url %||% "",
                api_key  = input$api_key  %||% ""))

      if (!nzchar(key)) {
        # 没填 Key：设置本身存下来了，但没有 Key 什么也生成不了。
        showNotification("设置已保存。还没填 API Key —— 填上再点一次这个按钮。",
                         type = "warning", duration = 8)
        return()
      }

      showNotification("已保存，正在验证这把 Key……", type = "message", duration = 4)
      start_verify(key)

      # 保存成功就把左栏那一项下面的**小字**刷新一遍。
      #
      # ★★ 这行字必须更新。它是 app_root 渲染时一次性写死的（只有换账号才
      #    重渲染），不更新的话，用户填完 Key、切回对话页，左栏还写着
      #    「未配置」—— 看起来像保存失败了。（这行字本来就是为"一眼看出在用
      #    哪个模型"存在的，显示过期信息比不显示还糟。V7 item 8 那会儿它是
      #    折叠块的摘要行，V13.12 item 19 之后搬到了导航项下面。）
      #
      #    app.R 那边渲染时用的是 `st$model %||% "已配置"`，这里跟它保持
      #    同一个口径，免得刷新前后两句话对不上。
      #
      # ⚠️ 走 sendCustomMessage 而不是 renderUI：那一项住在 app_root 里，
      #    服务端改不动它当时的 DOM。前端收到 dsapp:rail-sub 只改文字。
      sub <- tryCatch({
        s2 <- dsapp_settings_get(uid, con = dsapp_db(cfg))
        if (isTRUE(s2$saved)) {
          if (nzchar(s2$model %||% "")) s2$model else "已配置"
        } else "未配置"
      }, error = function(e) "已配置")
      session$sendCustomMessage("dsapp:rail-sub", list(sub = sub))
    }

    # 头尾两颗，各接各的点击事件，做的是同一件事。
    observeEvent(input$commit,     do_commit())
    observeEvent(input$commit_top, do_commit())

    # =======================================================================
    # 厂商 / base_url
    # =======================================================================

    # 切厂商时把 base_url 带过去。用户如果改成了中转地址，切回来会被覆盖 ——
    # 这是有意的：留着上一个厂商的地址只会得到莫名其妙的 401。
    #
    # ⚠️ 但**首次加载不能覆盖**：带出来的值是从库里读的（可能是中转地址），
    #    一进来就被厂商默认值盖掉，存过的 base_url 等于白存。
    #    用第一拍跳过实现：控件建好时 input$vendor 就是存过的那个厂商，
    #    这次 observeEvent 的事件是"控件初始化"，不是"用户切厂商"。
    vendor_seen <- reactiveVal(FALSE)
    observeEvent(input$vendor, {
      if (!isTRUE(vendor_seen())) {
        vendor_seen(TRUE)
        models_res(NULL)
        return()
      }

      # ★★ V13.7 item 3：**只在库里没存过这一家的地址时**才推厂商默认值。
      #
      #   用户原话：「api key 的记忆功能有点问题」。这一条是其中丢得最狠的
      #   一半 —— 厂商/模型还能靠默认值兜回来，**手填的中转地址丢了就是永久
      #   丢**，用户只记得"我明明存过"。
      #
      #   怎么丢的：本 observe 注册在切厂商那个 observer **之后**，而浏览器
      #   按**到达顺序**应用 updateTextInput —— 那边刚把这次切过去的那家在
      #   钥匙串里存的地址推下去，这一发厂商默认值紧接着又盖一次，最后留在
      #   输入框里的是默认值；800ms 后防抖保存再把默认值写回库。全程界面上
      #   没有任何异常，"存过"这件事就这么没了。
      #
      #   rec 为 NULL（这家从没存过）时行为不变，仍然是推厂商默认值 ——
      #   不推的话会留着上一家的中转地址，那是另一种 401。
      rec <- tryCatch(
        dsapp_api_key_recall(state$user_id, input$vendor, con = dsapp_db(cfg)),
        error = function(e) NULL)
      if (is.null(rec$base_url) || !nzchar(rec$base_url)) {
        b2 <- dsapp_vendor(input$vendor)$base_url %||% ""
        updateTextInput(session, "base_url", value = b2)
        # V13.12 item 20：这一格也是**服务端**填的，不是用户敲的 —— 不同步快照
        # 的话，只是换了个厂商，提醒框里会连「接口地址」一起列出来。
        snap_one("base_url", b2)
      }
      # 换厂商后原来那批模型名多半不适用，清掉重来
      models_res(NULL)
    }, ignoreInit = FALSE)

    observeEvent(input$fill_base, {
      updateTextInput(session, "base_url",
                      value = dsapp_vendor(input$vendor)$base_url %||% "")
    })

    output$key_help <- renderUI({
      v <- dsapp_vendor(input$vendor)
      url <- v$key_url %||% ""

      # ★ V13.1 item 1 / 3：「申请」和「已有账号去拿 Key」是**两个页面**。
      #
      #   用户给的两个链接都是邀请/注册入口（智谱的 invite?icode=…、
      #   方舟的短链），点进去是注册页。原来只有 key_url 一个字段，
      #   而它指的是控制台里的 API Keys 页 —— 一个还没注册的人点进去
      #   会撞上登录墙。所以申请走 invite_url，控制台仍然走 key_url。
      #
      #   没配 invite_url 的厂商（绝大多数）行为**逐字不变**：那个链接
      #   本来就是控制台，它就是申请入口。
      apply_url <- v$invite_url %||% ""
      if (!nzchar(apply_url)) apply_url <- url

      # ★ V13.14 item 24：整块包一层，只为了要一个**能挂 class 的钩子**。
      #
      #   ⚠️ 这一块现在长在「厂商」正下方（原来在「获取模型」下面）。而
      #      selectInput 那个 .form-group 只有 `margin-bottom`、**没有**
      #      margin-top —— 不干预的话，这块文字离上面 1rem、离下面的「接口
      #      地址」标签 0，看起来像是**接口地址的说明**，而不是厂商的。
      #      所以要在 .dsapp-key-help 上补一对上下边距，把它推回上面那一格
      #      （值在 www/app.css，那里有实测的说明）。
      #
      #   ⚠️ 包的是**整块**（申请链接 / key_note / 聚合平台说明 / 厂商 note），
      #      不是只有那行链接：这几段说的都是"你选的这一家是什么情况"，
      #      拆开搬会让同一件事的说明散在两个地方。
      div(class = "dsapp-key-help",
      tagList(
        if (nzchar(apply_url)) {
          div(class = "small mt-1",
            # ★ V13.14 item 24：文案从「还没有 Key？」改成「还没有 Key和URL？」。
            #   ⚠️ 别只改一句话就把这条工单勾掉 —— 位置也一起改了（这一块现在
            #      在「厂商」正下方，见上面 UI 那一段）。这句话回答的是"我还没
            #      有这个东西，去哪弄"，而用户**看完它才知道要去哪弄**，所以
            #      它得挨着"选哪家"。
            icon("key"), " 还没有 Key和URL？去 ",
            tags$a(href = apply_url, target = "_blank",
                   rel = "noopener noreferrer",
                   class = "fw-semibold",
                   v$label, "官网申请 ",
                   icon("arrow-up-right-from-square", class = "small")),
            # 已经有账号的人不该被丢回注册页。只在两个链接**确实不同**的
            # 时候才多这一条 —— 否则就是把同一句话写两遍。
            if (nzchar(v$invite_url %||% "") && nzchar(url))
              tagList(
                " · ",
                tags$a(href = url, target = "_blank",
                       rel = "noopener noreferrer",
                       class = "fw-semibold",
                       "已有账号去控制台 ",
                       icon("arrow-up-right-from-square", class = "small"))
              )
          )
        },
        # ★ V13.4：note 和 key_note 里的 `**...**` 在**这里**转成 <strong>。
        #
        #   ⚠️ 转的位置只能是这里，不能挪回 models.R：
        #      · models.R 那两段是 paste0() 拼出来的，而 dsapp_md_inline() 返回的
        #        是 htmltools 的 HTML 对象 —— 放进 paste0 的**参数**里会被
        #        as.character() 压成普通字符串、**类就没了**，最后转义出来是
        #        一对字面尖括号（2026-09-06 实测过）。
        #      · 而且 DSAPP_MODEL_CATALOG 是 source 时就求值的常量，models.R 在
        #        list.files() 的字母序里排在 utils.R **前面** —— 在那边调这个函数
        #        就是 could not find function（selftest 和后台子进程走的就是那条路）。
        #
        #   ⚠️ 顺序也不能反：先 paste0 拼完整句、再整体过 dsapp_md_inline()。
        #      它内部是"先转义、再替换 **"，拼好之后转义才盖得住用户数据
        #      （见 R/utils.R 里那段说明）。
        if (nzchar(v$key_note %||% "")) {
          div(class = "small text-muted", dsapp_md_inline(v$key_note))
        },

        # ★ V13 item 7：聚合平台的能力必须**在界面上说出来**。
        #
        #   不说的话，「这个平台的 Key 也能调 DeepSeek」这件事就只存在于
        #   官方文档里，用户在设置页看不到任何迹象 —— 于是他会去另开一个
        #   DeepSeek 账号、再申请一把 Key，做同一件事情，还要多管一份账单。
        #   模型下拉里那几组别家的模型也就变成了没人知道的东西。
        if (dsapp_vendor_is_aggregator(input$vendor)) {
          div(class = "small mt-1",
            icon("layer-group"), " ",
            "聚合平台：同一把 Key、同一个地址也能调别家的模型。",
            "模型下拉里按原厂分了组，", tags$b("本平台的排在最前面"), "。")
        },

        # 目录里每家都写了一段 note（平台停服、接口换地址、哪些名字不能用了），
        # 之前一直没有任何地方渲染它 —— 写了等于没写，用户拿到的只有一句
        # 400/401，然后去搜索引擎上找答案。
        if (nzchar(v$note %||% "")) {
          div(class = "small text-muted mt-1", dsapp_md_inline(v$note))
        },
        if (nzchar(v$extra_note %||% "")) {
          div(class = "small text-muted mt-1",
              icon("circle-info"), " ", v$extra_note)
        }
      )
      )   # /div.dsapp-key-help（V13.14 item 24）
    })

    # ---- 模型下拉 ----
    #
    # 优先用厂商 /models 接口返回的真实清单；没拉到时退回目录里的静态清单。
    # 静态清单只是占位 —— 模型名是厂商随时会改的东西，写死在代码里必然过期。
    #
    # ★ V13 item 7：两条路都**分组**（本平台在前，别家按原厂分堆）。
    #   dsapp_vendor_model_groups() 对两种输入是同一个函数 —— 它认不出来的
    #   名字落进「其它」组，一条都不丢。活清单比静态清单权威，但它同样
    #   可能冒出新名字，所以不能假设它一定认得出来。
    #
    # ★★ V16.3 item 7：**这份活清单必须是当前这一家拉回来的**。
    #
    #   原来这里只判 `ok && length(models)`，不看这份清单属于谁。V16.3 之前
    #   唯一会中途换厂商的动作是用户手点「获取模型」，撞上的窗口很窄；item 7
    #   让**每次切厂商都自动拉一次**之后，这个竞态就成了常规路径：切 A→B，
    #   A 的应答后到，B 的下拉里显示的是 A 的模型名（而这正是用户要修的那件事
    #   的反面 —— 他切了厂商，看到的却不是这一家的清单）。
    #   `vendor` 那一格是**发请求时**盖的章（见 models_job_vendor 的说明），
    #   不相等就一律退回静态目录，宁可显示得少一点也不能张冠李戴。
    model_choices <- reactive({
      res <- models_res()
      if (!is.null(res) && isTRUE(res$ok) && length(res$models) &&
          identical(res$vendor, input$vendor)) {
        return(dsapp_vendor_model_groups(input$vendor, live = res$models))
      }
      dsapp_vendor_model_groups(input$vendor)
    })

    observeEvent(model_choices(), {
      ch <- model_choices()
      flat <- dsapp_model_groups_flat(ch)
      cur <- isolate(input$model) %||% ""

      # ★★ V13.7 item 3：选中的名字**不在这批清单里**时，先问库，别直接退回
      #    清单头一个。
      #
      #    切厂商会把 models_res(NULL) 清掉，本 observe 随即被重算触发，而
      #    此刻 isolate(input$model) 还是**上一家的模型名**。原来那句
      #    `if (!nzchar(cur) && length(flat)) cur <- flat[[1]]` 只兜住了"空"，
      #    兜不住"是别家的名字"—— 于是切厂商那个 observer 刚按库里的记录
      #   把模型选好，这里又把它顶掉，最后停在厂商清单的第一项上。
      #    库里的证据就是这么来的：`users.llm_model = 'glm-4.5'` 而
      #    `user_api_keys.zhipu.model = 'glm-5.3'` —— 两个真相源对不上，
      #    而发消息用的是前者。
      #
      #    ⚠️ 只在"当前这个名字无效"时才去问库。反过来无条件用库里的值的话，
      #       用户在下拉里选好模型、再点「获取模型」拉活清单时，选择会被
      #       弹回上次存的那个 —— 那是比原 bug 更烦人的一种。
      #    ★★★ Test_V15.7 item 8：这段兜底原先**只问钥匙串，从来不问库**，
      #    于是它把两个真相源的主次搞反了。发消息走的是 `users.llm_model`
      #    （见本文件开头 `saved_model <- s$model`），钥匙串那份只是**按厂商
      #    存的副本**；副本陈旧时，用户看到的下拉被改成了副本里的旧值，
      #    下一拍 debounce 再把它写回库 —— 「页面一崩，模型从 glm-4.5-air
      #    自己变成 glm-5.3」就是这么来的，崩不崩其实无关（崩只是重跑了一遍
      #    这段初始化）。库里的现场：`users.llm_model='glm-4.5-air'` 而
      #    `user_api_keys.zhipu.model='glm-5.3'`，后者正是 zhipu 静态清单的
      #    `fallback_models[[1]]`。
      #
      #    ⚠️ 顺序：**库 → 钥匙串 → 清单头一个**，一级比一级弱。
      #    ⚠️ 这里不需要另做"厂商对得上吗"的判断：`flat` 本身就是
      #       `dsapp_vendor_model_groups(input$vendor, ...)` 出来的**按厂商**
      #       的清单，名字在里面就说明这一家的目录认它。
      if (!nzchar(cur) || !cur %in% flat) {
        sv <- tryCatch(
          as.character(dsapp_settings_get(state$user_id,
                                          con = dsapp_db(cfg))$model %||% ""),
          error = function(e) "")
        if (nzchar(sv) && sv %in% flat) {
          cur <- sv
        } else {
          rec <- tryCatch(
            dsapp_api_key_recall(state$user_id, isolate(input$vendor),
                                 con = dsapp_db(cfg)),
            error = function(e) NULL)
          if (!is.null(rec$model) && nzchar(rec$model) && rec$model %in% flat) {
            cur <- rec$model
          } else if (length(flat)) {
            cur <- flat[[1]]
          }
        }
      }
      # ★★ V13.12 item 20：这一格换的是**谁**的值，快照必须跟上。
      #
      #    这是那个"明明刚点了更新，切页却说模型改了还没确认"的现场：点「更新」
      #    会顺手拉一次厂商的模型清单（start_verify），清单回来时当前选中的名字
      #    往往不在里面（比如模型是静态清单里的默认名，而中转站只认自己那几个），
      #    于是这里把它换成清单头一个 —— 用户一个字都没动，快照却还停在旧名字上。
      #
      #    ⚠️ 判据是"控件里现在是不是已经是这个值"，不是"cur 有没有被改过"：
      #       cur 常常等于 isolate(input$model)，那种情况下根本没发生写入，
      #       不动快照才对。
      #    ⚠️ 判据是"**推下去之后控件里会是什么值**"，不是"cur 有没有被改过"。
      #       这两个不等价，而且是**实测**出来的：有一类厂商（中转站那种）
      #       静态目录里一个模型都没有，flat 是空的，于是 cur 原样留着旧名字，
      #       但新选项里没有它 —— selectize 把值**丢掉**，控件变成空。按
      #       "cur 变没变"判的话这里什么都不做，而控件已经从 mock-slow 变成
      #       空了，切页就是一句「模型改了还没确认」。
      after <- if (cur %in% flat) cur else ""
      if (!identical(after, isolate(input$model) %||% "")) {
        snap_one("model", after)
      }
      updateSelectizeInput(session, "model", choices = ch, selected = cur)
    }, ignoreNULL = FALSE)

    output$model_warn <- renderUI({
      m <- input$model %||% ""

      # ★ V16.3 item 7：这一家**一个模型名都给不出来**时，界面得把原因说出来。
      #
      #   中转站 / 自定义这两类的静态目录是空的（`fallback_models` 就是
      #   character(0)）：它们的清单只能现场从 /models 拉。而现场那一拉需要
      #   地址 + Key（下面那个自动拉的 observer 没 Key 就不发请求 —— 见它的
      #   说明），所以"刚选完厂商、还没填 Key"这一刻，下拉框必然是空的。
      #   空下拉框本身不解释任何事，用户看到的是"这个厂商坏了"。这里把话说
      #   明白，顺便告诉他手打模型名这条路是通的。
      #
      #   ⚠️ 必须放在 `if (!nzchar(m))` **之前**：那一刻 m 本来就是空的，
      #      放在后面这段永远轮不到执行 —— 一句永远不显示的提示，和没有
      #      提示在用户那边是同一件事。
      if (!nzchar(m) && !length(dsapp_model_groups_flat(model_choices()))) {
        return(div(class = "alert alert-secondary py-2 small mt-2 mb-0",
          icon("circle-info"), " 这一家没有内置的模型清单：",
          "填好「接口地址」「API Key」之后会自动查询；",
          "也可以直接在下拉框里手动输入模型名。"))
      }

      if (!nzchar(m)) return(NULL)

      # 从旧教程里抄 deepseek-coder 的人不少，直接告诉他换哪个，
      # 比让他对着 400 报错猜要好。
      dep <- dsapp_model_deprecated(input$vendor, m)
      if (!is.null(dep)) {
        return(div(class = "alert alert-warning py-2 small mt-2 mb-0",
          icon("triangle-exclamation"), " 这个模型名已经不能用了：", dep))
      }

      # ⚠️ 和 model_choices() 同一把尺子：这份活清单得是**当前这一家**的。
      #    切厂商之后旧清单还会在 models_res() 里躺一会儿（新请求回来之前），
      #    不判这一下的话，用户会看到「厂商的可用模型列表里没有 glm-5.3」——
      #    拿 A 家的清单去否定 B 家的模型名。
      res <- models_res()
      if (!is.null(res) && isTRUE(res$ok) && length(res$models) &&
          identical(res$vendor, input$vendor) &&
          !m %in% res$models) {
        return(div(class = "alert alert-warning py-2 small mt-2 mb-0",
          icon("triangle-exclamation"),
          sprintf(" 厂商的可用模型列表里没有「%s」。可能是名字写错了，", m),
          "也可能这个 Key 没有开通它。"))
      }
      NULL
    })

    # ---- 拉模型列表（非阻塞）----
    #
    # dsapp_llm_models() 是一次同步 HTTP 请求，超时 20 秒。在 Shiny 进程里
    # 直接调它，所有用户都要陪着等 —— Shiny Server 开源版一个应用只有一个
    # R 进程。所以丢给 dsapp_bg_start() 的子进程。
    # 抽成函数是因为「获取模型」和「确认/更新」两个按钮都要用它。
    # 确认按钮顺手验一次 Key，用户才知道自己刚存下的那把**能不能用** ——
    # 不然"已保存"只是一个动作回执，Valid 与否还得再点一次「获取模型」。
    # ★ V13.12 item 1：**先看地址，再看 Key**。
    #
    #   用户原话：「通过 key 获取可用模型不太合理，应该通过 URL 来获取模型，
    #   这样中转站也能够获取」。
    #
    #   改之前这里的第一道闸是 `if (!nzchar(key))`，返回"请先填入 API Key" ——
    #   于是"去哪家拉"这件事看起来像是由 Key 决定的。真正决定它的是 base_url
    #   （dsapp_llm_models 拼的就是 `<base_url>/models`），Key 只是请求头。
    #
    #   ⚠️ 而且旧代码有个**静默走错门**的坑：`dsapp_vendor_base_url()` 在
    #      地址为空时返回空串，`dsapp_llm_models()` 拿到空串会退回
    #      `cfg$llm$base_url`（= https://api.deepseek.com）。用户选了
    #      「自定义 / 中转代理」（它的 base_url 就是空的）直接点「获取模型」，
    #      请求会**悄悄打到 DeepSeek 去**，拿回一份 DeepSeek 的模型名 ——
    #      看起来"成功了"，但和中转站毫无关系。所以这里宁可停下来要一个地址，
    #      也不让它猜。
    #
    #   ⚠️ Key 允许为空。有的中转站 `/models` 是公开的（没登录也能看清单），
    #      以前那种"没 Key 就不许查"的闸门会把这种情况也挡掉。空 Key 时
    #      llm.R 干脆不发 Authorization 头；真要鉴权，服务端会回 401，
    #      那时给出的提示才是有用的。
    # ★★ V16.3 item 7：多两个可选参数 vendor / url。
    #
    #   理由不是"好看"，是**服务端的 input 比浏览器慢一拍**：updateTextInput
    #   推下去的值，要等下一次往返才出现在 input$base_url 里。切厂商那一刻
    #   自动拉清单时，input$base_url 还是**上一家**的地址 —— 拿它去查，就是
    #   拿 A 家的门牌号问 B 家的清单，而回来的东西会被当成 B 的（item 7 修的
    #   就是这个）。所以自动拉的那条路把钥匙串里记的地址**显式传进来**，
    #   压根不读 input$base_url。
    #   ⚠️ 默认值仍然走 input$，手动点「获取模型」那条路的行为逐字不变：
    #      那时候用户就是照着输入框里的地址查的。
    start_verify <- function(key, url = NULL, vendor = NULL) {
      v <- as.character(vendor %||% input$vendor)[1] %||% ""
      if (is.null(url)) url <- trimws(input$base_url %||% "")
      url <- trimws(as.character(url)[1] %||% "")
      if (!nzchar(url)) url <- trimws(dsapp_vendor(v)$base_url %||% "")
      if (!nzchar(url)) {
        models_res(list(ok = FALSE, models = character(0),
                        msg = paste0("请先填写「接口地址（base_url）」再点获取模型 —— ",
                                     "你选的是自定义厂商，它没有默认地址。"),
                        vendor = v))
        return(invisible(FALSE))
      }
      models_res(NULL)
      # ⚠️ 换掉上一次还没跑完的：一次 /models 最长要等二十秒，用户切两下厂商
      #    就能叠起两个子进程。留着旧的没有意义（它的结果会被 vendor 守卫丢掉），
      #    而 abort 掉省一个进程 + 一个没人读的结果文件。
      try(dsapp_job_abort(models_job()), silent = TRUE)
      # ★ 盖章必须在**发请求这一刻**：结果回来时 input$vendor 可能已经变了。
      models_job_vendor(v)
      # ★ Test_V16.3 item 2：拉清单也要走用户填的代理 —— 境外厂商的清单
      #   正是"填代理之前最想拿到的东西"，少了这一句用户会觉得"代理只对
      #   发消息生效"。父进程读好传进去（子进程少读一次库）。
      #   ⚠️ start_verify 也被自动拉那条路调用（observeEvent(input$vendor)），
      #      所以这里读一次库是**每次换厂商都读**——那是对的：用户可能刚在
      #      这一页打开代理开关，下一拍换厂商就该走代理了。
      models_job(dsapp_llm_models_async(
        key, base_url = url, cfg = cfg,
        proxy = tryCatch(dsapp_proxy_for(state$user_id), error = function(e) NULL)))
      invisible(TRUE)
    }

    observeEvent(input$verify, {
      start_verify(input$api_key %||% "")
    })

    # ---- 选完厂商就自动刷新可用模型清单（V16.3 item 7）----
    #
    # 用户原话：「现在的逻辑是api key有效才会弹出模型选择列表，能不能选择厂商后
    # 就刷新可选模型列表？」
    #
    # 说的是中转站 / 自定义这两类：它们的 `fallback_models` 是空的（见
    # models.R 的目录说明 —— 写死的中转站模型名没有任何意义），所以下拉框
    # 在**拉到活清单之前**必然是空的，而拉活清单原来只有一个入口：手点
    # 「获取模型」。于是"选厂商"和"看到这一家的模型"之间隔着一个用户没理由
    # 知道的按钮。
    #
    # ★ 三个闸门，缺一个就会变成噪音：
    #
    #   ① 这家支持 /models 接口吗。不支持的那几家（qwen/zhipu/ernie/spark/
    #      baichuan，见目录里的 supports_models_api = FALSE）拉一次必然失败 ——
    #      自动拉就会在用户什么都没做的情况下**自动**弹一条红色错误。它们
    #      本来就有静态清单，没有这个需求。
    #   ② 拉得动吗：Key 或地址至少有一个。两个都没有时发出去的是一次
    #      没头没脑的匿名请求，回来的 401 对用户毫无信息量（他还没填 Key 呢，
    #      那不是错误，是顺序）。这一档留给上面 model_warn 那句提示去解释。
    #   ③ 首次进页面只在**静态清单为空**时才拉。有静态清单的那几家一进来就有
    #      东西可选，每次打开页面都去打扰一次厂商接口没必要。
    #      ⚠️ `vendor_seen()` 那个"第一拍"标记不能用 —— 它属于另一个 observer
    #         （负责推 base_url），在这里读它等于偷别人的状态，两个 observer
    #         的注册顺序一改就失效。这里用一次性的自己的标记。
    auto_vendor_seen <- reactiveVal(FALSE)
    observeEvent(input$vendor, {
      first <- !isTRUE(auto_vendor_seen())
      auto_vendor_seen(TRUE)

      v <- input$vendor %||% ""
      if (!nzchar(v)) return()
      if (!dsapp_vendor_has_models_api(v)) return()

      uid <- state$user_id
      if (is.null(uid)) return()
      rec <- tryCatch(
        dsapp_api_key_recall(uid, v, con = dsapp_db(cfg)),
        error = function(e) NULL)
      key <- as.character(rec$api_key %||% "")
      burl <- as.character(rec$base_url %||% "")
      if (!nzchar(key) && !nzchar(burl)) return()   # 闸门 ②

      if (first && length(dsapp_model_groups_flat(
            dsapp_vendor_model_groups(v, live = NULL)))) return()   # 闸门 ③

      start_verify(key, url = burl, vendor = v)
    }, ignoreInit = FALSE)

    observe({
      # dsapp-selftest: self-reactive-ok models_job
      #
      #   ⚠️ 显式豁免。本 observe 读 models_job()（下一行）又写它（取完置
      #     NULL）。不会失控的理由：**写进去的是 NULL**，下一轮第 2 行就
      #     return。读那一侧不能 isolate —— 「拉模型清单」那个 observeEvent
      #     写 models_job(句柄) 就是靠这个依赖把这轮询唤醒的。
      h <- models_job()
      if (is.null(h)) return()
      invalidateLater(500)

      r <- dsapp_llm_models_poll(h)
      if (!isTRUE(r$done)) return()

      models_job(NULL)
      # ★★ V16.3 item 7：盖章用的是**发请求时**记下的那一家，不是此刻的
      #    input$vendor。这一行原来是 `vendor = isolate(input$vendor)`，
      #    也就是"谁在结果回来时被选中，这份清单就算谁的" —— 切厂商的瞬间
      #    在飞的那个请求，回来时会**冒充**新厂商的清单（见 models_job_vendor
      #    的说明）。改完这一格，下游那两个 `identical(res$vendor, input$vendor)`
      #    守卫才真的拦得住东西。
      models_res(list(ok = r$ok, models = r$models, msg = r$msg,
                      vendor = models_job_vendor()))
    })

    output$verify_result <- renderUI({
      res <- models_res()
      # ★ V16.3 item 7：上一个厂商的查询结果不能拿来报**这一家**的状态。
      #   切到一家没有 Key 的厂商时（那种情况自动拉不会发生），下面那句
      #   「Key 有效，取回 12 个模型，下拉框已更新」会原样留着 —— 而那是
      #   上一家的 12 个模型。和 models_res 的章同一个道理：过了期的好消息
      #   比没有消息更容易让人上当。
      if (!is.null(res) && !identical(res$vendor, input$vendor)) res <- NULL
      if (is.null(res)) {
        if (!is.null(models_job())) {
          return(div(class = "alert alert-info py-2 small mt-2 mb-0",
            icon("spinner", class = "fa-spin"),
            " 正在向厂商查询可用模型……"))
        }
        return(NULL)
      }

      if (isTRUE(res$ok)) {
        n <- length(res$models)
        div(class = "alert alert-success py-2 small mt-2 mb-0",
          icon("circle-check"),
          sprintf(" Key 有效，取回 %d 个模型，下拉框已更新。", n))
      } else {
        div(class = "alert alert-danger py-2 small mt-2 mb-0",
          icon("circle-xmark"), " ", res$msg %||% "获取失败",
          div(class = "text-muted mt-1",
            "厂商不支持 /models 接口时，可以直接在下拉框里手动输入模型名。"))
      }
    })

    # =======================================================================
    # 温度 / 思考模式（原 item 5）
    # =======================================================================

    output$maxtok_hint <- renderUI({
      # ⚠️ `[1]` 和 `!isTRUE(is.finite(...))` 都不能省。
      #
      #    `as.numeric(NULL)` 是 numeric(0)，`is.na(numeric(0))` 是 logical(0)，
      #    而 `if (logical(0))` 抛的是 "argument is of length zero"，**不是**
      #    走 else —— 服务端一屏一屏地刷这条 Warning。
      #
      #    这一格真的会是 NULL：V13.6 item 2 之后长度上限住在 renderUI("temp_ui")
      #    里，控件出生之前它不存在；而整页重载（退出登录 / 异端登录被顶下线）
      #    之后 Shiny 会把这一端的 input 全置 NULL —— 正是 item 1 那个时序。
      #    页面看着没事（这只是一行提示），但日志被刷满，真出事时找不到现场。
      mt <- suppressWarnings(as.numeric(input$max_tokens)[1])
      if (!isTRUE(is.finite(mt))) return(NULL)
      th <- dsapp_vendor_supports_thinking(input$vendor %||% "deepseek") &&
            isTRUE(rv$thinking)
      if (!th || mt >= 32768) return(NULL)
      div(class = "dsapp-warn",
        icon("triangle-exclamation"), " 思考模式下思维链也算在这个额度里。",
        sprintf("当前 %d 偏小：思考强度高时，思维链可能把额度全部用光，",
                as.integer(mt)),
        "正文一个字都写不出来，对话页会一直停在「正在思考」。")
    })

    # 一个灰掉的控件长什么样（V13.6 item 2）。
    #
    # ⚠️ 灰掉的控件**必须是静态 HTML**，不能是"照原样渲染一个 Shiny 控件再
    #    遮住"。Shiny 的控件只要在 DOM 里就会把值报上来 —— 给不支持思考的
    #    厂商渲染一个灰掉的 `input$thinking`，它的 FALSE 会写进 rv$thinking，
    #    用户切回 DeepSeek 时思考模式就自己关了，而且**没有任何一步看起来
    #    像出错**。所以这里手写 label/input，不产生任何 input 事件。
    #    （`disabled` 让浏览器画成灰的；外层的 .dsapp-field-disabled 再挡掉
    #    点击 —— 两者都要，disabled 的 input 在有的浏览器上仍然能被 tab 到。）
    # 外层的 .dsapp-field-disabled 管"灰 + 挡住点击"，里面贴着真控件照抄
    # Shiny 的那套 class（form-group / shiny-input-container / checkbox /
    # radio-inline），这样灰掉的样子和真控件**长得一模一样**，只有颜色和
    # 可点性不同 —— 用户一眼就知道"这里本来有个开关"。
    na_box <- function(...) {
      div(class = "dsapp-field-disabled",
        tags$div(class = "form-group shiny-input-container", ...))
    }
    na_check <- function(label) {
      na_box(tags$div(class = "checkbox",
        tags$label(tags$input(type = "checkbox", disabled = NA),
                   tags$span(label))))
    }
    na_radio <- function(label, choices) {
      na_box(
        tags$label(class = "control-label", label),
        tags$div(class = "shiny-options-group",
          lapply(names(choices), function(lbl) {
            tags$div(class = "radio-inline",
              tags$label(tags$input(type = "radio", name = "na_effort",
                                    disabled = NA),
                         tags$span(lbl)))
          })))
    }

    output$temp_ui <- renderUI({
      m <- input$vendor
      supports <- dsapp_vendor_supports_thinking(m)
      th <- supports && isTRUE(rv$thinking)
      # ⚠️ 必须把**当前选中的模型**一起传进去。判"温度生不生效"要看两件事：
      #    厂商开没开思考模式、以及这个模型本身认不认 temperature。
      #    只看厂商的话，月之暗面那类"只接受 1"的模型会显示成可调 ——
      #    用户拖到 0.3，一发消息就是 HTTP 400。
      mdl <- input$model %||% ""
      locked <- dsapp_model_temp_locked(mdl)
      active <- dsapp_temperature_active(m, th, model = mdl)
      vlab <- tryCatch(dsapp_vendor(m)$label, error = function(e) NULL) %||%
        (m %||% "这家厂商")

      # ---- 量程（V13.6 item 3）----
      # ⚠️ 值是 isolate() 读的：rv$temp 由下面拖滑块的 observer 写，裸读它
      #    会让"每拖一下"都重建整块参数区（连带把用户正在输入的长度上限
      #    打回原值）。rv 在这里的作用是**记忆**，不是触发源；触发源是
      #    厂商 / 模型 / 思考模式，那几个变了才该重建。
      tr <- dsapp_param_range(m, mdl, "temperature")
      tval <- dsapp_param_clamp(m, mdl, "temperature",
                                isolate(rv$temp), default = 0.3)
      slider <- sliderInput(ns("temperature"), "温度（temperature）",
                            min = tr$min, max = tr$max, value = tval,
                            step = tr$step)

      # ★★ V15.5 item 6：量程换成**这个模型自己的上下文窗口**。
      #    原来这里读的是 dsapp_param_range(..., "max_tokens")（厂商那一侧的
      #    回复上限，默认档 1K ~ 10M）—— 用户原话是「需要按照模型的能力自适
      #    应更改上下文长度的读条」，所以 deepseek 那一档就该摆到 1M，而不是
      #    所有厂商一律一条 10M 的滑块。
      kr <- dsapp_ctx_range(m, mdl)
      # ★ V13.14 item 22：rv$maxtok 是 0（跟随模型）时**不能**走
      #    dsapp_ctx_clamp —— 那个函数把值夹进 [min, max]，0 会被夹成
      #    min = 1024。于是"跟随模型"会在控件重建的那一瞬间（换厂商、换模型、
      #    开关思考模式）静默变回"上限 1K"，用户看到的是自己设的东西被改了，
      #    而且没有任何提示。
      kval <- if (dsapp_maxtok_is_unlimited(isolate(rv$maxtok))) {
        DSAPP_CTX_FOLLOW
      } else {
        dsapp_ctx_clamp(m, mdl, isolate(rv$maxtok))
      }
      unlim <- dsapp_maxtok_is_unlimited(kval)
      # 量程只在**和默认档不一样**的时候写进标签。都一样还写出来是纯噪音，
      # 而且会让每一家厂商看起来都"特别"。
      # ★ V13.11 item 4：量程**一律写进标签**，而且用短写法（1K ~ 10M）。
      #
      #   原来只在"和默认档不一样"时才写 —— 理由是"都一样还写出来是纯噪音"。
      #   这一版反过来了：默认档从 64K 抬到 10M 之后，**"能到 10M"这件事本身
      #   就是要传达的信息**（用户原话「太保守了，应该以 million 为单位」）。
      #   不写的话，界面上唯一的量程线索是滑块两端那两个小字，而它们窄得
      #   放不下（10,000,000 有 69px，滑块整条才 143px）—— 所以那两个小字
      #   在 app.css 里被藏掉了，量程只从这一行读。
      # ★★ V15.5 item 6：改名。用户原话「那不需要限制单次回复长度了，弄一个
      #    限制单次使用token的长度吧」——
      #    这一格现在是**一次请求（上下文 + 回复）合计**的上限，不是回复长度。
      #    量程来自上面那个 kr（模型窗口），所以标签里那两个数就是"这个模型
      #    最多能到多少"。
      klab <- sprintf("单次使用上限（tokens，%s ~ %s）",
                      dsapp_fmt_tokens_short(kr$min),
                      dsapp_fmt_tokens_short(kr$max))
      # ---- 滑块 + 输入栏（V13.10 item 6）---------------------------------
      #
      # 用户原话：「单次回复 token 上限需要同时有滑块和输入栏，并在滑块上
      # 设置几个建议值」。
      #
      # 三件东西，值永远是同一个：
      #
      #   滑块      max_tokens_slider —— 用来"找感觉"（往右拖是答案更长）
      #   输入栏    max_tokens        —— 用来"填准数"（8192 就是 8192）
      #   建议值    maxtok_pick       —— 滑块下面那排小按钮，一点同时改上面两个
      #
      # ⚠️ **唯一真值仍然是 input$max_tokens**（输入栏）。滑块和建议值都是
      #    "改它的手段"，不是第二份状态 —— 两份状态迟早会不一致，而不一致的
      #    表现是"我明明拖到 32K 了，发出去的还是 8K"，用户完全无从判断该信
      #    哪一个。所以：拖滑块 → updateNumericInput 把数字改掉；点建议值 →
      #    同样改数字。反方向（数字 → 滑块位置）也走 updateSliderInput。
      #
      # ⚠️ 轮子滑块和数字框**不共用 inputId**。共用的话，Shiny 里两个控件
      #    抢同一个 input，最后一个是 NULL（谁后渲染谁说话），而这一块是
      #    renderUI 每次重建的 —— 表现是"有时候滑块没了，有时候数字框没了"。
      #
      # ⚠️ 建议值必须**按当前模型的量程过滤**后再画（dsapp_maxtok_suggestions）：
      #    一个上限只有 8192 的模型，摆一个 32K 的按钮出来，点下去会被夹回
      #    8192 —— 用户看到的是"我点的 32K，它给我 8K"，而不是"这个模型不
      #    支持 32K"。
      sug <- dsapp_maxtok_suggestions(kr)

      # ---- ★ V13.14 item 22：滑块最右那一格是「不设上限」------------------
      #
      # 用户原话：「单次回复上限的最右侧应该是"不设上限"」。
      #
      # ⚠️ 滑块的上界因此不是 kr$max，而是**再高一格**（dsapp_maxtok_slider_max）。
      #    那一格塌成 DSAPP_MAXTOK_UNLIMITED，最终表现是请求体里不带
      #    max_tokens（见 R/llm.R）。"不设上限"能成立靠的正是**不发这个字段**：
      #    任何填得出来的数字都是一个上限，10485760 也是。
      #
      # ⚠️ 输入栏用 **NA**（空框）+ placeholder 表达同一件事。这不是两套状态：
      #    实测过 Shiny 1.10 的 numericInput 绑定，空框到服务端就是 NA，而
      #    updateNumericInput(value = NA) 真的会把框清空 —— 于是"空框"和
      #    "滑块在最右"是同一个值的两种写法，和三件东西一条真值的规矩一致。
      #    空框旁边什么都不写的话，用户会以为是自己把它弄没了，所以那格
      #    常驻一个 placeholder「不设上限」。
      smax <- dsapp_maxtok_slider_max(kr)
      sval <- dsapp_maxtok_to_slider(kval, kr)
      maxtok <- tagList(
        tags$div(class = "dsapp-maxtok-label control-label", klab),
        div(class = "dsapp-maxtok-row",
          div(class = "dsapp-maxtok-slider",
            sliderInput(ns("max_tokens_slider"), NULL,
                        min = kr$min, max = smax, value = sval,
                        step = kr$step, ticks = FALSE, width = "100%"),
            # 右端那一格自己画一行字，不用 ionRangeSlider 的 .irs-max：
            # 那两个标签在 V13.11 被藏掉了（放不下），而且 .irs-max 是库按
            # max= 生成的数字，每次 update 都会重建那个节点 —— 在 JS 里改它的
            # textContent，下一次拖动就没了。自己画一行，谁也覆盖不掉。
            # `.on` 是**渲染那一刻**算的初值，之后由 www/app.js 跟着真值对齐，
            # 和那排建议值 chip 是同一套办法（见 app.js 里那段说明）。
            tags$div(class = "dsapp-maxtok-ends",
              tags$span(class = paste("dsapp-maxtok-end-hi",
                                      if (unlim) "on"),
                        "跟随模型"))
          ),
          # ⚠️ placeholder 只能这样加：numericInput() 没有 ... 参数，
          #    它的 value= 写成 NA 时 htmltools 渲染出来是 value="NA"，
          #    浏览器按"不是合法数字"当成空框（实测过，见 selftest 里那条）。
          htmltools::tagQuery(
            numericInput(ns("max_tokens"), NULL,
                         value = if (unlim) NA_real_ else kval,
                         min = kr$min, max = kr$max, step = kr$step,
                         width = "110px")
          )$find("input")$addAttrs(placeholder = "跟随模型")$allTags()
        ),
        if (length(sug) > 0) {
          # 一排小按钮铺在滑块下面，左右两端和滑块对齐 —— 读起来就是
          # "滑块上标出来的几个刻度"。
          # ⚠️ 用 Shiny.setInputValue 而不是 actionButton：这一块每次
          #    renderUI 重建都会换一批 id，而 actionButton 的 observer 要在
          #    server 里按名字挂 —— 挂一次就固定了，重建之后新按钮没人接。
          #    走一个**固定名字**的 input（maxtok_pick）+ 值带在消息里，
          #    重建多少次都还是那一个 observer（见下面那一节）。
          div(class = "dsapp-maxtok-sug",
            tags$span(class = "dsapp-maxtok-sug-label", "建议"),
            lapply(sug, function(v) {
              tags$button(type = "button",
                class = paste("dsapp-sug-chip",
                              if (isTRUE(all.equal(as.numeric(v),
                                                   as.numeric(kval)))) "on"),
                # ★ V13.11 item 4：把这一档的值挂在元素上，给 app.js 用来
                #   实时对齐选中态。不挂的话只能去解析 onclick 里那串
                #   `Shiny.setInputValue(...)`，改一次消息格式就断。
                #
                # ⚠️ 上面那个 `.on` 是**渲染那一刻**算的，而这一块是
                #    renderUI 且只在厂商/模型/思考模式变化时重建 —— 用户
                #    拖滑块或者直接在输入栏里填个数，高亮**不会**跟着动。
                #    表现是"我明明填的是 4M，亮着的还是 1M"：用户会怀疑
                #    到底哪个才算数。所以服务端渲染初值、app.js 负责之后
                #    的每一次同步（见 www/app.js 末尾那一节）。
                `data-tok` = as.integer(v),
                title = sprintf("%s tokens", format(as.integer(v), big.mark = ",")),
                onclick = sprintf(
                  "Shiny.setInputValue('%s', %d, {priority: 'event'})",
                  ns("maxtok_pick"), as.integer(v)),
                dsapp_fmt_tokens_short(v))
            })
          )
        }
      )

      parts <- list()

      # ---- 思考模式开关（只有 DeepSeek 认这两个参数）----
      #
      # V13.6 item 2：不支持思考的厂商**不再整块消失**，改成灰掉 + 一句为什么。
      # 原来是"不渲染"，用户看到的是参数区只剩一个温度滑块，没有任何东西
      # 提示他"这家没有思考模式这回事"—— 他只会以为这个应用缺功能。
      if (supports) {
        parts <- c(parts, list(
          checkboxInput(ns("thinking"), "开启思考模式",
                        value = isolate(rv$thinking)),
          conditionalPanel(
            condition = sprintf("input['%s'] === true", ns("thinking")),
            radioButtons(ns("reasoning_effort"), "思考强度", inline = TRUE,
              choices = c("低" = "low", "中" = "high", "高" = "max"),
              selected = isolate(rv$effort))
          )
        ))
      } else {
        # 两个一起灰：思考强度是**挂在**思考模式下面的，开关都点了没反应，
        # 强度还留着可点的样子只会让人以为是自己没点对地方。
        parts <- c(parts, list(
          na_check("开启思考模式"),
          na_radio("思考强度", c("低" = "low", "中" = "high", "高" = "max")),
          div(class = "small text-muted",
            icon("circle-info"), " ",
            # ★ V15.7 item 6：用户原话「这个提示太 AI 了」。
            #   改之前是两句：「…没有思考模式这个参数，开了也不认 —— 请求里
            #   不会带它。」+「这一栏灰着是**厂商**的区别，不是本应用没做。」
            #   —— 括号里在解释"我们内部怎么实现的"（参数名、发不发出去）、
            #   还在替自己辩解（"不是本应用没做"）。用户要的是一句话：
            #   **不支持，所以选不了**。
            #
            # ⚠️ 改完之后这句里**没有** markdown 记号了，所以 V13.8 item 4
            #    那个 dsapp_md_inline() 包装也一起去掉了 —— 这条路上
            #    （renderUI → tags$div → DOM）没有 markdown 渲染，留着 `**`
            #    就是两个字面星号。自检钉死了"这一段里不许再出现 `**`"。
            sprintf("%s 的接口不支持思考模式，故此处不可选。", vlab))
        ))
      }

      # ---- 温度 ----
      if (active) {
        parts <- c(parts, list(slider))
      } else {
        # ⚠️ 两种"不生效"的原因**完全不同**，文案不能共用一条：
        #    · 思考模式：厂商规定思考时不认 temperature，关掉开关就能用；
        #    · 温度锁死的模型（kimi-k*）：这个模型压根没有可调的温度，
        #      关什么开关都没用 —— 请求里根本不会带这个参数。
        #    写成同一句的话，第二种情况会把用户支去关一个关了也没用的
        #    开关，然后他会以为是这个应用坏了。
        reason <- if (locked) {
          tagList(icon("circle-info"), " ",
            "这个模型只接受 temperature = 1（厂商的硬性规定）。",
            "请求里不会带温度参数，拖它不会有任何效果。")
        } else {
          tagList(icon("circle-info"), " ",
            "思考模式下温度不生效 —— 厂商的规定，不是本应用的限制。",
            "想让温度生效就把「开启思考模式」关掉。")
        }
        parts <- c(parts, list(
          div(class = "dsapp-field-disabled", slider),
          div(class = "small text-muted", reason)
        ))
      }

      # ---- 长度上限 ----
      #
      # ⚠️ 它**没有**"适用不适用"这一说：任何一家厂商都认 max_tokens，
      #    所以它永远不灰。跟着变的只有**量程**（见上面的 kr）—— 那才是
      #    item 3 说的"范围自适应"。
      parts <- c(parts, list(maxtok))

      tagList(parts)
    })

    # 只在拿到有效值时更新 rv，避免控件被重建的瞬间把值冲成 NULL
    observeEvent(input$temperature, {
      if (!is.null(input$temperature)) rv$temp <- input$temperature
    }, ignoreNULL = TRUE)

    # 长度上限同 temperature：参数区重建的那一瞬间 input$max_tokens 会短暂
    # 变 NULL，裸写 state 的话用户刚设的 8192 会静默跳回 65536。
    #
    # ★ V13.14 item 22：清空输入栏到服务端是 **NA**（不是 NULL，实测过），
    #   所以这条 observer 会正常触发；存进 rv 的**不是 NA 而是哨兵 0** ——
    #   rv$maxtok 是下一次 renderUI 的初值来源，存 NA 的话"这是用户选的
    #   不设上限"和"这个值没取到"在下游长得一模一样（见 models.R 那段说明）。
    observeEvent(input$max_tokens, {
      if (is.null(input$max_tokens)) return()
      rv$maxtok <- if (dsapp_maxtok_is_unlimited(input$max_tokens))
                     DSAPP_MAXTOK_UNLIMITED else input$max_tokens
    }, ignoreNULL = TRUE)

    syncing <- reactiveVal(FALSE)

    # ★★ V16.2：「这一格（input$max_tokens）现在装的还是**被取代的旧值**」。
    #
    #    `updateNumericInput()` 只是把消息**发给浏览器**：服务端手里的
    #    `input$max_tokens` 要等浏览器回发才会变，而那是**下一个来回**的事。
    #    在那之前，只要下面那个 observe()（读 input$max_tokens 的那个）
    #    因为**任何**别的原因重跑一次，它拿到的就是这一格被取代的旧值，
    #    于是按旧值写一遍 state$ctx_limit —— 把刚下的指令当场撤销。
    #
    #    2026-10-04 实测的那一条：在对话页把「上下文 / 单次输出」勾回
    #    "不设上限"，**勾自己弹回来**。TRACE 里是
    #      recv v=0 → apply_ctx_limit want=0（真相写对了）
    #      → bigobserve in.max_tokens=49152 → apply_ctx_limit want=49152（被盖回）
    #      → push unlim=FALSE（两个勾按回"灭"）
    #    全程不报错、自检也看不见：两边各自都"对"，错的是**次序**。
    #
    #    ⚠️ 上面那道 `syncing` 闸挡不住它：闸只管得住**同一拍**里的回发，
    #       而这个陈旧值是从浏览器绕了一圈回来的，落在下一拍。
    #    ⚠️ 存的是"浏览器那份还没跟上的值"（= 改写前 rv$maxtok），不是我们要
    #       写的新值 —— 判据是"读到它就别信"，撤守卫的时机是"读到别的了"。
    #       拿新值当判据的话，这一格清空（NA）那一档永远匹配不上，
    #       守卫就永远撤不掉。
    maxtok_stale <- NULL

    # 滑块 → 数字
    observeEvent(input$max_tokens_slider, {
      if (isTRUE(syncing())) return()
      # ★ V15.5 item 6：量程换成模型窗口（同 temp_ui 里的 kr）。
      r <- dsapp_ctx_range(input$vendor, state$model)
      v <- dsapp_maxtok_from_slider(input$max_tokens_slider, r)
      if (is.null(v)) return()
      cur <- suppressWarnings(as.numeric(input$max_tokens)[1])
      # 和输入栏里已经一样的值就别 update 了 —— 那会让用户正在输入的光标
      # 跳位（数字框被重置）。
      #
      # ★ V13.14 item 22：最右那一格 = 不设上限，到那儿就是把输入栏**清空**。
      #   ⚠️ 比较也要用"是不是不设上限"来比，不能比数值：cur 是 NA 时
      #      `all.equal(NA, 0)` 不是 TRUE，会每拖一下都 update 一次空框。
      if (dsapp_maxtok_is_unlimited(v)) {
        if (dsapp_maxtok_is_unlimited(cur)) return()
        syncing(TRUE)
        updateNumericInput(session, "max_tokens", value = NA)
        syncing(FALSE)
        return()
      }
      if (is.finite(cur) && isTRUE(all.equal(cur, v))) return()
      syncing(TRUE)
      updateNumericInput(session, "max_tokens", value = v)
      syncing(FALSE)
    }, ignoreNULL = TRUE)

    # 数字 → 滑块。**不防抖**：拖滑块是连续的，打数字是离散的，
    # 离散的那一侧每敲一下都该立刻反映到滑块上（看着数字长大、滑块跟着走，
    # 这是这个控件存在的意义）。越界的值交给下面那条 maxtok_settled 拨回，
    # 这里只夹一次，免得 updateSliderInput 拿到范围外的值。
    observeEvent(input$max_tokens, {
      if (isTRUE(syncing())) return()
      r <- dsapp_ctx_range(input$vendor, state$model)
      v <- suppressWarnings(as.numeric(input$max_tokens)[1])
      # ★ V13.14 item 22：输入栏被**清空**（服务端拿到 NA）就是"不设上限"，
      #   滑块滑到最右那一格。
      #
      # ⚠️ 这里**不能**在 v 不是有限数时 return()。原来的写法就是那样，而
      #    清空输入栏恰恰让 v 变成 NA —— 加了不设上限之后，那个 return 的
      #    行为是"用户清空输入栏，界面一动不动"：框空了、滑块还停在 8K、
      #    真值也还是 8K。用户只能觉得这个框坏了。清空是**一个动作**，
      #    要按一个动作去接。
      target <- if (dsapp_maxtok_is_unlimited(v)) dsapp_maxtok_slider_max(r)
                else min(max(v, r$min), r$max)
      cur <- suppressWarnings(as.numeric(input$max_tokens_slider)[1])
      if (is.finite(cur) && isTRUE(all.equal(cur, target))) return()
      syncing(TRUE)
      updateSliderInput(session, "max_tokens_slider", value = target)
      syncing(FALSE)
    }, ignoreNULL = TRUE)

    # 建议值被点。input 的名字是**固定**的（maxtok_pick），值在消息里，
    # 所以参数区重建多少次都还是这一个 observer 在接 —— 见 mod_model.R
    # 里那段 "用 Shiny.setInputValue 而不是 actionButton" 的说明。
    observeEvent(input$maxtok_pick, {
      v <- suppressWarnings(as.numeric(input$maxtok_pick)[1])
      if (!is.finite(v)) return()
      # 再夹一次：按钮是按当时的量程画的，而厂商/模型可能刚换过、renderUI
      # 还没重建完 —— 这一瞬间点下去，旧按钮的值可能已经越界了。
      # ★ V15.5 item 6：夹的是**模型窗口**（dsapp_ctx_clamp），不是厂商那侧的
      #   max_tokens 量程 —— 建议值本身就是按窗口画的（见上面的 sug）。
      v <- dsapp_ctx_clamp(input$vendor, state$model, v)
      # 建议值是"同时改两个控件"，所以这里**绕过** syncing 闸两个都写：
      # 闸是给"一个控件的变化触发另一个"用的，这里是用户直接下的命令。
      syncing(TRUE)
      updateNumericInput(session, "max_tokens", value = v)
      # 对齐到步长（clamp 已经做了），滑块那边再夹一次防它拿到范围外的值。
      updateSliderInput(session, "max_tokens_slider",
                        value = dsapp_ctx_clamp(input$vendor, state$model, v))
      syncing(FALSE)
    }, ignoreNULL = TRUE)

    # =======================================================================
    # ★★ V16.2 item 2：接收对话页发来的「单次使用上限」指令
    # =======================================================================
    #
    # 用户原话：「言出法随下面的对话框需要有直接勾选这些选项不设上限的组件」，
    # 其中的「上下文 / 单次输出」指向的就是这一页那一格。指令从
    # state$maxtok_cmd 过来（见 app.R 那段和 mod_chat.R 的 set_maxtok()）。
    #
    # ⚠️⚠️ 为什么非要有这个接收端，而不是让对话页直接写 state$ctx_limit：
    #    上面那个 observe()（读 input$max_tokens 的那个）是 state$ctx_limit
    #    的**唯一写入口**，它读了一大把 input —— 用户之后只要在**这一页**动
    #    任何一下（拖温度、换厂商、换模型），它就会重跑一遍，拿的是
    #    `input$max_tokens`，也就是**这一页那份旧值**。对话页偷改的值会被
    #    静默盖回去。所以必须让这一页自己知道。
    #
    # ⚠️ 收到之后要做两件事，缺一不可：
    #     ① 改 rv$maxtok（下一次 renderUI 的初值来源，也是"用户选的是什么"
    #        的记忆）；
    #     ② 把页面上那两个控件（滑块 + 数字框）按过去 —— 不做的话，用户从
    #        对话页设完再切到这一页，看到的是旧数字，而那个数字**看起来就是
    #        当前生效的值**（这一页上没有任何别的东西能戳穿它）。
    #
    # ⚠️ 控件可能**根本不存在**（这一页的 renderUI 还没出生）。update* 对
    #    不存在的 input 是个静默空操作 —— 这里可以接受，因为①已经把真相
    #    改了，而控件出生时会拿 rv$maxtok 当初值（见 1651 行那段）。
    #    换句话说：静默失败的那一半，在控件出生时会自己补上。
    #
    # ⚠️ 别去掉那个 rev 判断。同一个值连着发两次（改成 65536 → 改回 …）
    #    在 list 上看起来一模一样，Shiny 的 observeEvent 对同一个 list 值
    #    **不会**触发第二次。
    observeEvent(state$maxtok_cmd, {
      cmd <- state$maxtok_cmd
      if (is.null(cmd)) return()
      v <- cmd$value
      if (is.null(v) || length(v) != 1L || is.na(suppressWarnings(as.numeric(v)))) return()
      v <- as.numeric(v)
      if (identical(rv$maxtok, v)) return()   # 已经是这个值了，一个字节都别动

      # ★★ V16.2：先记下"这一格现在（浏览器那份）写着什么"，再改。
      #    从这一行到浏览器把新值报回来之间，`input$max_tokens` 装的还是它 ——
      #    而下面那个 observe() 会拿它去写真相，等于把刚收到的指令当场撤销
      #    （症状：勾了自己弹回来）。判据和撤守卫的时机见 maxtok_stale 那段。
      #    ⚠️ 必须在 `rv$maxtok <- v` **之前**取：rv 是"这一页记着的值"，
      #       浏览器那份正是它（接收端从不绕过它去写控件）。
      #    ⚠️ `<<-`：这里是一个 handler 函数，`<-` 只会建一个出了这个花括号
      #       就没人看得见的局部变量 —— 守卫会**静默失效**，症状和没修一样。
      maxtok_stale <<- rv$maxtok
      rv$maxtok <- v
      # ①' **立刻**把 state 也写掉，不等浏览器回发。
      #
      #   上面那条 update* 只在控件已经出生时才有效；用户从没打开过这一页
      #    的时候它是个静默空操作，而那时 input$max_tokens 永远不会变，
      #    下面那个 observe() 也就永远不会重跑 —— state$ctx_limit 会停在
      #    旧值上，而对话页那个勾已经亮了。这就是"两边说的不是一回事"。
      #    显式写一次之后，无论控件在不在，真相都是对的；控件真在的话，
      #    浏览器回发会让 observe() 用**同一个公式**再算一遍，结果相同。
      apply_ctx_limit(v, state$vendor %||% input$vendor)

      # ② 把控件按过去。走 syncing 闸：update* 会让浏览器回发 input，
      #    不回闸的话数字框和滑块会互相 update 一轮（值一样，但每一次
      #    updateSliderInput 都会重置 DOM，表现是手感发涩）。
      syncing(TRUE)
      # ⚠️ 量程走 dsapp_ctx_range()，**不是** dsapp_param_range(..., "max_tokens")
      #    —— 那一根是**厂商**那侧的回复上限（1K~10M），而这一格是"单次使用
      #    上限"（模型窗口）。喂错量程的话滑块的上界会变成 10M，
      #    "不设上限"那一格就跑到一个谁也够不着的地方去了。
      kr <- dsapp_ctx_range(state$vendor %||% input$vendor, state$model)
      if (isTRUE(dsapp_maxtok_is_unlimited(v))) {
        # 不设上限在界面上 = 输入栏**清空**（V13.14 item 22，见 2020 行那段）
        updateNumericInput(session, "max_tokens", value = NA)
        updateSliderInput(session, "max_tokens_slider",
                          value = dsapp_maxtok_slider_max(kr))
      } else {
        updateNumericInput(session, "max_tokens", value = v)
        updateSliderInput(session, "max_tokens_slider",
                          value = dsapp_ctx_clamp(state$vendor %||% input$vendor,
                                                  state$model, v))
      }
      syncing(FALSE)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ---- 滑块 / 建议值 → 数字（V13.10 item 6）---------------------------
    #
    # ⚠️ 真值只有 input$max_tokens 一个。滑块动、建议值被点，都只是
    #    "换个方式改那个数字"，改完还是回到 input$max_tokens 这条唯一的路上
    #    （上面那条 observer 写 rv，state 那边读 input$max_tokens）。
    #
    # ⚠️ 防回环用 syncing 这个闸，不是靠"比较值相不相等"。值比较挡不住
    #    这一条：用户拖滑块到 8192（数字变成 8192）→ 数字的 observer 把
    #    滑块 update 到 8192 → 滑块 observer 又跑一遍…… 每一轮值都一样，
    #    看起来无害，但 updateSliderInput 会重置一次 DOM，拖动过程中被重置
    #    的表现是**手感发涩、松手时回跳一格**。闸一关，这一轮直接不动。


    # ★★ V15.5 item 6：这里原来有一个 `observeEvent(state$maxtok_force$rev)`
    #   接收端，负责把厂商 400 里说的 max_tokens 上限**写进用户那一格**。
    #
    #   V15.3 item 2 当时那样做是对的 —— 那时候界面上那格就是发出去的那个数。
    #   现在不是了：那格是「单次使用上限」（一次请求合计多少 token），而厂商
    #   说的是**回复那一侧**的上限。把 8192 写进"单次使用上限"等于把整个上下文
    #   窗口砍到 8192，用户会看到历史忽然全被丢掉，而界面上那句话还说"已经帮
    #   你设好了"。
    #
    #   它真正的归宿是**第四层**（学到的上限）：发送端（R/mod_chat.R 的
    #   input$maxtok_fix）已经调 dsapp_param_learn() 把它写进 model_param_limits
    #   并灌进进程内缓存了，推导出来的 max_tokens 会被它自动夹住
    #   （见 models.R 的 dsapp_ctx_plan）。
    #
    #   ⚠️ 所以这里**故意什么都不做**，而不是留一个空 observer 或者写一个没人
    #      读的 rv$xxx_rev。这一页上没有任何东西会因为"学到了回复上限"而变：
    #      滑块量程是**模型窗口**（与 max_tokens 无关），建议值也是按窗口画的。
    #      留一个看起来在干活的写操作，比什么都不留更糟 —— 下一个人会以为
    #      它在同步什么。

    # ★ V13.6 item 3：填了范围外的值，**停手之后把它拨回范围内**。
    #
    #   state 那一层已经保证了"发出去的请求永远是合法值"（见上面那段）。
    #   但输入框里那个数字**还留着** —— 用户看着 99999999，有理由认为自己
    #   设的就是这个数，直到某天发现回复总是被截断，而没有任何线索指向这里。
    #   两件事都要做：发出去的要对，看得见的也要对。
    #
    #   ⚠️ 必须防抖，而且时长要比"打字"慢。不防抖的话，用户想输 8192、
    #      刚敲下第一个「8」就被拨成 512（低于下限），后面三个字符全白打 ——
    #      而他看到的现象是"这个框不让我打字"，比原来的问题更难查。
    #      1.5 秒的语义是"他停手了"，不是"他手慢"。
    #
    #   ⚠️ 范围用 state$model 算，**不是** input$model：用户手打了已下线的
    #      模型名时，真正发出去的是迁移之后的那个名字，范围得跟它一致。
    #
    #   不会自激：拨回去之后 input$max_tokens 变成合法值，下一拍 debounce
    #   到期时 `x >= r$min && x <= r$max` 成立，当场 return。
    maxtok_settled <- reactive(input$max_tokens) |> shiny::debounce(1500)
    observeEvent(maxtok_settled(), {
      x <- suppressWarnings(as.numeric(maxtok_settled())[1])
      if (!is.finite(x)) return()
      r <- dsapp_ctx_range(input$vendor, state$model)
      if (x >= r$min && x <= r$max) return()
      updateNumericInput(session, "max_tokens",
                         value = dsapp_ctx_clamp(input$vendor, state$model, x))
    }, ignoreNULL = TRUE)

    observeEvent(input$thinking, {
      if (!is.null(input$thinking)) rv$thinking <- isTRUE(input$thinking)
    }, ignoreNULL = TRUE)

    observeEvent(input$reasoning_effort, {
      if (!is.null(input$reasoning_effort)) rv$effort <- input$reasoning_effort
    }, ignoreNULL = TRUE)

    # =======================================================================
    # ★★ Test_V16.3 item 2：代理（VPN）
    # =======================================================================
    #
    # 控件的 id 和界面那边一一对应：proxy_on / proxy_proto / proxy_host /
    # proxy_port / proxy_user / proxy_key / proxy_keymode / proxy_test /
    # proxy_forget。改一处忘一处的话，症状是"开关点了没反应"（而它不报错）。
    #
    # ⚠️ 这里**只写库**，不碰任何全局状态。代理生效靠的是"下一次发请求时
    #    现读一遍库"（dsapp_proxy_for），不是"在这里把它设成全局" ——
    #    这个应用是一个 R 进程服务所有人，设成全局就是所有人的请求都从
    #    填设置的这个人的线路上出去。理由写在 R/proxy.R 顶部，别绕过它。

    # 代理那几个控件报上来的值，拼成一份设置。
    # ⚠️ isolate 由调用方负责（observeEvent 的 body 本来就不建立依赖）。
    proxy_now <- function() {
      list(enabled  = isTRUE(input$proxy_on),
           protocol = input$proxy_proto %||% "socks5h",
           host     = input$proxy_host %||% "",
           port     = input$proxy_port,
           username = input$proxy_user %||% "",
           sub_key  = input$proxy_key %||% "",
           key_mode = input$proxy_keymode %||% "both")
    }

    # 立刻落库。「测试代理」和两颗「确认/更新」都用它 —— 三处必须是同一个
    # 动作，抄三遍的话，漏改的那一处会让用户"点测试是通的、点更新却没存上"。
    save_proxy_now <- function() {
      uid <- state$user_id
      if (is.null(uid)) return(invisible(FALSE))
      p <- proxy_now()
      # ⚠️ 空密匙 = "不要动已存的那个"（dsapp_proxy_save 里的规矩）。
      #    这里显式转成 "" 传下去，**不要**转成 NULL —— NULL 在 DBI 的
      #    params 里会变成 SQL NULL，而那正是"覆盖成空"的意思。两种"空"
      #    在这里长得一样但语义相反，这个仓已经栽过一次（见 %||% 那条）。
      invisible(dsapp_proxy_save(uid, enabled = p$enabled,
                                 protocol = p$protocol, host = p$host,
                                 port = p$port, username = p$username,
                                 sub_key = p$sub_key %||% "",
                                 key_mode = p$key_mode,
                                 con = dsapp_db(cfg)))
    }

    # 防抖自动落库（800ms，和上面 pending() 同一个时长）。
    #
    # ⚠️ 不防抖会怎样：用户在「代理地址」里敲 "proxy.example.com"，每敲一个
    #    字符写一次库 —— 打到第八个字符时，库里存的地址已经能用了，而这时
    #    **别的会话**（另一个标签页、或者正在跑的 agent 循环）现读一遍库，
    #    就会拿这个半截地址去连。防抖不是省性能，是别让半截配置生效。
    proxy_pending <- reactive(proxy_now()) |> shiny::debounce(800)
    observeEvent(proxy_pending(), {
      uid <- state$user_id
      if (is.null(uid)) return()
      # ⚠️ 和 pending() 那条一样的闸门：控件还没把值报上来时（整页重载之后
      #    input 全是 NULL），一个字节都不许写。空地址 + 开着的开关写进去，
      #    等于把用户配好的代理整个抹掉，而且不报错。
      #    判据取「协议」：它是个永远有值的下拉，空只可能是"还没报上来"。
      if (!nzchar(input$proxy_proto %||% "")) return()
      save_proxy_now()
    }, ignoreNULL = TRUE)

    # ---- 「测试代理」 ------------------------------------------------------
    #
    # ⚠️ 必须丢子进程。这是一次真正的网络请求（超时 12 秒），在 Shiny 进程里
    #    同步跑就等于让**所有用户**陪着一起等 —— 和「获取模型」「测试 SSH
    #    连接」是同一条约束（见 R/jobs.R 顶部）。
    proxy_job <- reactiveVal(NULL)
    proxy_res <- reactiveVal(NULL)   # list(ok, msg, ms)

    observeEvent(input$proxy_test, {
      # isolate：handler 里裸读 input 会被 Shiny 记成依赖，于是"改任何一个
      # 代理输入框都会重跑一次连接测试"。要的是点击那一刻的快照。
      p <- isolate(proxy_now())
      if (!dsapp_proxy_ok(p)) {
        proxy_res(list(ok = FALSE, ms = 0,
                       msg = "还没填全：需要「地址」和「端口」，并打开最上面的开关。"))
        return()
      }
      # 先把当前值落库再测：用户点「测试」的意图是"我这套配置行不行"，
      # 而库里那份可能是 800ms 之前的。测完顺手就生效，不用再点一次更新。
      save_proxy_now()
      proxy_res(NULL)
      proxy_job(dsapp_bg_start("dsapp_proxy_test", list(p = p),
                               cfg = cfg, tag = "proxytest"))
    })

    # ⚠️ 这个 observe 裸读自己写的 proxy_job()（拿句柄 → 没完就继续定时 →
    #    取完写 NULL）。它和 mod_settings.R 那两个「同步 / 测试连接」的轮询是
    #    **同一个形状**，也在同一份豁免名单里，理由一样：写进去的是 NULL，
    #    下一轮第 2 行就 return。读那一侧**不能** isolate —— 点「测试代理」时
    #    由 observeEvent 写句柄，靠这个依赖唤醒轮询。
    # dsapp-selftest: self-reactive-ok proxy_job
    observe({
      h <- proxy_job()
      if (is.null(h)) return()
      invalidateLater(500)

      r <- dsapp_bg_poll(h)
      if (!isTRUE(r$done)) return()

      proxy_job(NULL)
      val <- r$value %||% list()
      proxy_res(if (isTRUE(r$ok) && length(val)) {
        list(ok = isTRUE(val$ok), msg = val$msg %||% "", ms = val$ms %||% 0)
      } else {
        list(ok = FALSE, msg = r$msg %||% "测试失败", ms = 0)
      })
    })

    observeEvent(input$proxy_forget, {
      uid <- state$user_id
      if (is.null(uid)) return()
      dsapp_proxy_clear(uid, con = dsapp_db(cfg))
      # 控件一并清空。只清库不清控件的话，用户看到框里还填着，以为没清掉，
      # 而下一拍防抖又会把框里的值**写回库** —— 清了等于没清。
      updateCheckboxInput(session, "proxy_on", value = FALSE)
      updateTextInput(session, "proxy_host", value = "")
      updateTextInput(session, "proxy_user", value = "")
      updateTextInput(session, "proxy_key", value = "")
      updateNumericInput(session, "proxy_port", value = NA)
      proxy_res(list(ok = FALSE, ms = 0, msg = "已清除这个账号的代理设置。"))
    })

    output$proxy_result <- renderUI({
      if (!is.null(proxy_job())) {
        return(div(class = "small text-muted mt-2",
                   icon("spinner", class = "fa-spin"), " 正在测试……"))
      }
      res <- proxy_res()
      if (is.null(res)) return(NULL)
      cls <- if (isTRUE(res$ok)) "text-success" else "text-danger"
      ic  <- if (isTRUE(res$ok)) "circle-check" else "circle-xmark"
      div(class = paste("small mt-2", cls), icon(ic), " ", res$msg %||% "")
    })
  })
}
