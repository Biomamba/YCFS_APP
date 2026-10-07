# =============================================================================
# 设置页
# =============================================================================
# 这一页在 V3 里被重写过，对应四条反馈：
#
#   item 4  模型选择有误 —— V2 只有硬编码的 deepseek-chat / deepseek-reasoner
#           两项，既不全也不知道去哪儿申请 Key。现在改成：选厂商 → 自动带出
#           base_url → 填 Key → 点「获取可用模型」直接问厂商的 /models 接口。
#           厂商目录和申请入口在 models.R。
#
#   item 5  温度是啥意思 —— V2 只写了一句"建议 0.2–0.4"，没说温度是什么。
#           现在把"它是什么/怎么调/和速度无关"讲清楚，并且对不生效的模型
#           （deepseek-reasoner）直接灰掉，免得用户调半天发现没用。
#
#   item 2  三种分析环境 —— 当前服务器（可指定 conda 环境）/ 本地电脑（导出
#           运行包）/ 远程服务器（SSH）。远程要 IP、端口、账号、密码或私钥。
#
#   item 3  设置好后跳回对话 —— 底部「保存并返回对话」按钮。
#
# ---- 这一页现在还剩什么（V6）-------------------------------------------------
#
#   V6 把「模型服务」整张卡片搬去了一块常驻面板（mod_model.R，V13.12 item 19
#   起是左栏一个独立的页）—— 用户的要求是
#   "模型模块在左侧应该是单独的滑块"，而它同时是 item 1（按账号记住
#   API Key）的落点，两件事必须在同一处实现。
#
#   所以这一页剩下：分析环境（本机/本地/远程 SSH）、账号密码、跳回对话。
#
# ---- 安全性 ----------------------------------------------------------------
#
# ⚠️ **SSH 密码/私钥**仍然只存在会话内存里（state$remote），不落盘 ——
#    这一条没变，理由也不变：它不是"我们的 Key"，是用户某台机器的登录凭据，
#    泄漏的后果比一个能随时吊销的 API Key 重得多。
#
# ⚠️ 但 **API Key 从 V6 起是落盘的**（按账号存进 users.llm_api_key）。
#    这是用户明确要求的（"请保留记忆功能"），原来的"不落盘"结论被推翻了。
#    不要在这份文件里再写"API Key 只存在内存中"—— 那是假的，
#    而假的安全承诺比没有承诺更糟。当前的边界写在 mod_model.R 顶部。
#
# ★ V13.1 item 9：落盘的那一份**是密文**（R/crypto.R）。这改变了"泄漏了
#   会怎样"，但**没有**改变"它是落盘的"这件事 —— 上一条依然成立，
#   别因为加了密就把话说回去。
# =============================================================================

#' 「保存并开始使用」那张卡（V13.9 item 11）
#'
#' 用户原话：「保存并开始使用不应该出现在帮助页面，而是应该出现在其它设置
#' 页面的底部」。所以它从「帮助」页搬到了「界面 / 执行 / 账号」三页各自的
#' **底部** —— 改完皮肤、改完硬件、改完密码，出口就在手边，不用先想到
#' "得去帮助页才有那个按钮"。
#'
#' ⚠️ 做成一个函数、调三次，而不是抄三遍：这三份里任何一句文案改了，
#'    抄出来的另外两份不会跟着改，而它们在**不同的页签**上，用户要来回
#'    翻才看得出来不一致。
#'
#' ⚠️ `key` 是这份副本的**后缀**，三份必须各不相同（"ui" / "exec" / "account"）。
#'    里面两个 id 都由它拼出来：
#'
#'      · `ready_badge_<key>` —— 就绪徽章那个 **output**。同一个 output id 在
#'        DOM 里出现三次的话，`document.getElementById` 只拿得到第一个，Shiny
#'        也只更新第一个 —— 另外两页上那块永远是空的，而且不报错。
#'      · `back_to_chat_<key>` —— 那个按钮的 **input**。★ V13.12 item 20 修：
#'        原来三份共用 `back_to_chat` 一个 id，功能上是通的（三个都绑到同一个
#'        `input$back_to_chat`，点哪个都跳），所以一直没人发现 —— 但 Shiny 每次
#'        重新绑定都会往控制台打一条
#'        `Duplicate input ID was found ... "settings-back_to_chat": 3 inputs`。
#'        实测跑一轮生成能刷出 156 条。那是**噪音**，而它长得像是真出了事，
#'        排查别的问题时会被它带着跑偏（这次就是）。
#'
#' @param ns 模块的命名空间函数
#' @param key 这份副本的后缀（"ui" / "exec" / "account"）
dsapp_back_card <- function(ns, key) {
  card(
    card_header(icon("circle-check"), " 保存并开始使用"),
    card_body(
      p(class = "small text-muted",
        "设置是即时生效的，不需要点保存。这个按钮只是把你送回「言出法随」页 —— ",
        "对话创建失败时从提醒里跳过来，改完点它就能直接回去继续。"),
      actionButton(ns(paste0("back_to_chat_", key)), "保存并返回对话",
                   class = "btn-primary w-100",
                   icon = icon("arrow-left")),
      uiOutput(ns(paste0("ready_badge_", key)))
    )
  )
}

mod_settings_ui <- function(id) {
  ns <- NS(id)

  # ★ V13.5 item 7：设置页改成**二级导航**。
  #
  #   用户原话：「设置页面现在太乱了，请弄一个二级导航栏」。
  #
  #   原来是一张 7/5 的两栏大杂烩：左栏四张卡（皮肤、尺寸、硬件、同步）、
  #   右栏三张卡（密码、返回、帮助），一共七张卡片平铺在一屏里，没有任何
  #   分组。左右两栏的高度还各自独立，"同步"和"账号密码"这两件毫不相干的事
  #   在视觉上并排着，找东西只能靠扫。
  #
  #   现在按**用户来这一页要干的事**分成三组，栏目标题就是那件事：
  #
  #     界面 —— 看着舒服（皮肤、尺寸）
  #     执行 —— 代码在哪跑（硬件选择 / 远程服务器）
  #     账号 —— 谁在用（账号密码、本地库 ↔ 在线版同步）
  #
  #   ★ V13.14 item 23：原来还有第四组「帮助」，搬去左栏独立成页了
  #     （见 R/mod_help.R）。它从来不是"改什么"这一类事。
  #
  #   ⚠️ 用 navset_underline 而**不是** navset_hidden，也不用 tabsetPanel：
  #      这一页的栏目标签是要给用户当导航看的，下划线那款是 bootstrap 的
  #      标准"页内次级导航"长相，和左侧主导航（竖排 rail）不会打架。
  #
  #   ⚠️ 每个 nav_panel 里仍然是**一张一张的 card 竖着堆**，不是两栏。
  #      和「环境」页保持一致 —— 那一页也是这么堆的。恢复成 layout_columns
  #      就会退回"两张卡并排、各自长短不一"的老样子。
  #
  #   ⚠️ 和 navset_hidden 一样，**没被选中的 nav_panel 仍然在 DOM 里**
  #      （bootstrap 的 .tab-pane 只是 display:none）。所以：
  #        * 各张卡里的 input 全都照样 bind，服务端拿到的东西和改之前一样；
  #        * 浏览器里做断言/取元素时必须按"可见宽度 > 0"过滤，
  #          document.querySelector('.dsapp-...') 会先撞上隐藏栏里的那个。
  #
  #   ⚠️ 这里**不能**出现任何对 state$ 的读取（理由见下面皮肤卡片那段长
  #      注释：这棵树跑在 output$app_root 里，读一下 state 就等于让整个应用
  #      外壳跟着重渲）。四个 nav_panel 的标题和 value 都是常量。
  tagList(
    div(class = "dsapp-page",
      navset_underline(
        id = ns("tab"),

        # ======================= 界面 =======================
        nav_panel("界面", value = "ui", icon = icon("palette"),
        # ---- 界面皮肤（V8 item 4）----
        #
        # ⚠️ 这一页**不要**再出现模型控件。V6 把「模型服务」整张卡片搬去了
        #    模型服务页（mod_model.R），V8 item 3 又把这里剩下的那张**说明卡**
        #    也删了 —— 用户的原话是「模型服务已经在主导航栏里了，设置中的
        #    模型服务可以去掉了」。留着说明卡的话，设置页里永远有一格写着
        #    "模型服务"，而点开什么都没有，比没有更让人困惑。
        #    模型设置的唯一入口是「模型服务」那一页（mod_model.R）。
        #    ⚠️ V13.12 item 19 起它在左栏导航里，不再是常驻的那一块。
        # ⚠️⚠️ 选择卡必须走 uiOutput，**不能**在这里直接写
        #     `dsapp_skin_picker(ns, selected = state$skin)`。
        #
        #     这一整棵 UI 树是 dsapp_main_ui() 的返回值，而它跑在
        #     output$app_root 这个 renderUI 里面 —— 在这里读 state$skin，
        #     就等于让**整个应用外壳**（左栏、对话页、任务页、文件页……）
        #     依赖于"当前皮肤"。于是用户每点一次皮肤卡片，服务端就把整个
        #     主界面重渲一遍；重渲出来的新 radio 又会自己 bind 一次、把
        #     input$skin 再报一遍，observer 再跑一轮……
        #
        #     症状不是报错，而是**点下去半天没反应**：2026-09-15 实测，
        #     连点五个皮肤，浏览器上的 data-skin 一直停在初始值，几秒之后
        #     才陆续追上（最后一个是 apple，所以刷新后看到的是 apple）。
        #     查了半天才定位到是这一行 —— 因为 dsapp:skin 那条消息确实是
        #     发出来了的，只是排在整屏重渲后面。
        #
        #     拆成独立 output 之后，它的依赖只剩 state$user_id：切皮肤不会
        #     重渲，切账号才会。DB 直读而不是读 state$skin，和上面 pw_card
        #     是同一个理由（state$user 是登录那一刻的快照）。
        card(
          card_header(icon("palette"), " 界面皮肤"),
          card_body(
            p(class = "text-muted small mb-2",
              "选一个你看着舒服的。", tags$b("即时生效"),
              "，不用保存、不用刷新，并且按账号记住 —— 下次换台机器登录还是它。"),
            uiOutput(ns("skin_card"))
          )
        ),

        # ---- 面板尺寸（V13.2 item 5）----
        #
        # 和皮肤卡片同一个形状，理由也一样：**必须是自己一个 output**。
        # 直接把它写进上面那棵静态 UI 里的话，数字框的值只能来自
        # renderUI，而 renderUI 一重渲整个设置页就跟着重渲 —— 上面皮肤
        # 那段长注释里记的那个"连点五个皮肤，界面上一直不动"的 bug 会原样
        # 复现一遍（那是 2026-09-15 实测出来的，不是理论担心）。
        #
        # 拆开之后它的依赖只剩 state$user_id。拖完分隔条回到设置页，这里的
        # 数字是新的 —— 靠的是"切回来时这块会重新渲染"，不是靠依赖 rev
        # （为什么不能依赖它，见下面 output$uipref_card 那段）。
        card(
          card_header(icon("arrows-left-right"), " 界面尺寸"),
          card_body(uiOutput(ns("uipref_card")))
        )
        ,
        # ★ V13.9 item 11：改完就走 —— 出口挂在每一页自己的底部。
        dsapp_back_card(ns, key = "ui")
        ),  # /nav_panel 界面

        # ======================= 执行 =======================
        nav_panel("执行", value = "exec", icon = icon("microchip"),
        # ---- 分析环境（item 2）----
        card(
          card_header(icon("microchip"), " 硬件选择"),
          card_body(
            p(class = "text-muted small mb-2",
              "代码在哪里执行。这个选择在「言出法随」页也能随时切换。"),

            radioButtons(ns("target_kind"), NULL, inline = TRUE,
              choices = c("当前挂载服务器" = "server",
                          "我的本地电脑"   = "local",
                          "远程服务器"     = "remote"),
              selected = "server"),

            # ★ V14 item 6：把「这三台分别是谁的机器」直接写在选项下面。
            #
            # 用户的原话：「需要告诉我用户所在的算力节点，是用户自有服务器，
            # 还是我的部署服务器」。代码里这个答案是明确的（target$kind 默认
            # "server"，见 utils.R 的 dsapp_target_label），但**界面上从来没
            # 说过** —— 用户看到的是「当前挂载服务器」，而"挂载"是个平台内部
            # 才懂的说法。歧义是真的会造成损失的：他可能以为"当前服务器"就是
            # 自己以前配过的那台，于是把几个 G 的原始数据传到自己根本连不上
            # 的机器上，或者反过来，以为数据在自己手里、其实在平台的盘上。
            #
            # ⚠️ 主机名 / 核数 / 内存写出来**不是**信息泄露：用户本来就能在
            #    上面跑任意代码（`system("hostname")` 一行的事）。这里要补的
            #    是「归属」这个语义，不是把人家的机器藏起来。
            div(class = "dsapp-note small mb-2",
              icon("circle-info"), " ",
              tags$b("「当前挂载服务器」= 本站的部署机"), "（",
              dsapp_host_identity()$label, "），", tags$b("不是你的机器"),
              " —— 选它的时候代码就在这台机器上跑，吃的是平台的 CPU / 内存 /",
              "磁盘，数据也落在平台的盘上。",
              tags$br(),
              "另外两项才是你自己的机器：", tags$b("「远程服务器」"),
              "是你自己的 SSH 主机（代码在那边跑），", tags$b("「我的本地电脑」"),
              "只是把脚本和依赖清单打包给你下载（代码在服务器上一行都不跑）。"),

            # -- 当前服务器 --
            #
            # ⚠️ 这里原本是一个 conda 环境下拉框（item 4 撤掉）。用户的
            #    要求是"环境不需要用户选择，在后台执行任务的时候自动生成"。
            #
            #    撤掉它不只是少一个控件：原来那个下拉框让用户从**全局共享
            #    的 conda 环境**里挑一个来跑自己的任务，这跟"每个对话一块
            #    隔离的工作区和环境"是直接冲突的 —— 两个人选了同一个环境，
            #    一个人 pip install 就能改掉另一个人的依赖版本，而且这种
            #    污染是静默的，出问题时没人会想到去查"你当时选了哪个环境"。
            #
            #    现在环境由 dsapp_session_libs() 按对话惰性生成（见 envs.R
            #    的 dsapp_venv_ensure / dsapp_rlib_ensure），用户在对话里
            #    第一次执行任务时自动建好，之后复用。界面上只需要说清楚这件事。
            conditionalPanel(
              condition = sprintf("input['%s'] === 'server'", ns("target_kind")),
              p(class = "small text-muted mb-0",
                icon("wand-magic-sparkles"), " 运行环境由平台自动准备，",
                dsapp_md_inline("不需要选择。第一次执行时会为**这个对话**单独建一套，"),
                "之后复用；在「环境」页装的包也只装进这一套里，不影响别人。")
            ),

            # -- 本地电脑 --
            conditionalPanel(
              condition = sprintf("input['%s'] === 'local'", ns("target_kind")),
              div(class = "dsapp-warn",
                icon("circle-info"), " 浏览器里的网页没法直接在你自己的电脑上跑代码",
                "（那正是浏览器沙箱要拦的事）。选这一项时，平台会把「分析脚本 +",
                "脚本用到的数据文件 + README + environment.yml」打成一个压缩包给你下载，",
                "你在自己电脑上解压、按 README 装好依赖再跑。"),
              p(class = "small text-muted mb-0",
                "适合：本机已经装好 RStudio / conda，只是想让 AI 把代码和依赖清单写出来。")
            ),

            # -- 远程服务器 --
            conditionalPanel(
              condition = sprintf("input['%s'] === 'remote'", ns("target_kind")),
              remote_form_ui(ns)
            )
          )
        ),

        # ---- 离开页面之后（V13.7 item 5）----
        #
        # ⚠️ 和上面那张「界面尺寸」同一个形状：**必须是自己一个 output**。
        #    直接写进静态 UI 的话，选中态只能来自 renderUI，而 renderUI 一
        #    重渲整页就跟着重渲（那条长注释在 mod_settings.R 上面皮肤那段，
        #    记的是一个实测出来的 bug，不是理论担心）。
        #
        # ⚠️ 放在「执行」这一栏，不放在「界面」：它管的是**执行**怎么收场，
        #    和像素没有任何关系。放错栏的表现是用户找不到它 —— 而找不到的
        #    那一档恰恰是"页面关掉之后还在花钱"的那个开关。
        card(
          card_header(icon("person-walking-dashed-line-arrow-right"),
                      " 离开页面之后"),
          card_body(uiOutput(ns("detach_card")))
        ),

        # ---- AI 怎么干活（V13.12 item 4）----
        #
        # ⚠️ 放在「离开页面之后」**下面**，不放在它上面：那一档是"页面关掉
        #    之后还在不在花钱"，风险等级更高，第一眼要看到的是它。
        #
        # ⚠️ 同样是自己一个 output。理由和上面两张一样，见本文件皮肤那段。
        card(
          card_header(icon("robot"), " AI 怎么干活"),
          card_body(uiOutput(ns("agent_card")))
        ),

        # ---- 邮件提醒（★ Test_V15.2 item 2）----
        #
        # ⚠️⚠️ 外框也归 output 管（`mail_card_wrap` 而不是把 card() 写死在这里）。
        #    没配 SMTP 的部署（Windows 便携包、用户自托管）里
        #    `dsapp_mail_ready(cfg)` 是 FALSE，那一整张卡**连标题都不出现** ——
        #    否则用户会看到一张写着"邮件提醒"、点进去每个按钮都必然报错的卡。
        #    这是 D4「不加开关、用配没配齐判断」的直接后果：界面不该露出一个
        #    它自己知道做不成的事。
        uiOutput(ns("mail_card_wrap")),

        dsapp_back_card(ns, key = "exec")
        ),  # /nav_panel 执行

        # ======================= 账号 =======================
        nav_panel("账号", value = "account", icon = icon("user-shield"),
        # ---- 本地库 ↔ 在线版同步（V13.3 item 2）----
        #
        # ⚠️ 顺序是"先密码、后同步"：这一栏标题叫「账号」，密码是这一栏里
        #    唯一和"账号会不会被人冒用"有关的东西，而"没设密码"正是这个
        #    应用默认、也最容易被忽略的状态 —— 它得在第一眼看到的位置。
        #    （原来它在右栏最上面，理由就是这个，改成二级导航时保留。）
        card(
          card_header(icon("lock"), " 账号密码"),
          card_body(uiOutput(ns("pw_card")))
        ),

        card(
          card_header(icon("arrows-rotate"), " 本地库 ↔ 在线版同步"),
          card_body(sync_card_ui(ns))
        )
        ,
        dsapp_back_card(ns, key = "account")
        )   # /nav_panel 账号
        # ⚠️ 这里原来还有第四个页签「帮助」（V13.5 item 7 分的四组之一）。
        #    ★ V13.14 item 23（用户原话：「帮助页面独立到左侧导航栏」）把它
        #    搬走了 —— 现在是左栏 DSAPP_NAV_ITEMS 里的一项（value = "help"），
        #    内容整个搬到了 R/mod_help.R，**一个字都没改**。
        #
        #    搬的理由（写在 mod_help.R 顶部，这里留一句免得有人"顺手搬回来"）：
        #    这一页的三个页签是按"用户来这一页要**改**什么"分的（界面 / 执行 /
        #    账号），而帮助是"出问题了怎么办"—— 它不是同一类事。而且"设置"
        #    这两个字在用户心里是"改我自己的东西"，出事时没人会先想到点它。
        #    V13.9 item 11 把「保存并开始使用」从帮助页赶去那三栏底部，说的
        #    也是同一件事：这一页不该混进"改设置"的职责，反过来同样成立。
      )     # /navset_underline
    )       # /div.dsapp-page
  )
}

# ---------------------------------------------------------------------------
# 同步卡片（V13.3 item 2）
# ---------------------------------------------------------------------------
#
# 用户原话（V13.2 工单 item 2）：「如何解决 exe 和在线版本的数据库统一问题？
# 例如用户信息、任务会话」。方案的取舍全部写在 R/sync.R 顶部，这里只放
# 界面和"哪些东西**不**同步"的如实交代。
#
# ★ 为什么这段文案必须写清楚"任务和文件不同步"：用户点了一次同步、发现
#   历史任务页还是空的，会以为同步坏了 —— 而它没坏。任务行指向的产物文件
#   只在跑过它的那台机器上（见 R/sync.R 顶部第一节），同步一行任务过去，
#   那边点开就是空的，比不同步更糟。**说清楚**比"看起来功能更全"重要。
sync_card_ui <- function(ns) {
  tagList(
    p(class = "text-muted small mb-2",
      "把", tags$b("对话和账号"), "同步到另一台机器（比如网页版），",
      "两边都能看到同一批对话。"),

    # ⚠️ 这句是这条功能的**边界**，不是免责声明。删掉它 = 让用户以为
    #    他跑过的分析也跟着走了。
    div(class = "alert alert-secondary small py-2 px-3 mb-3",
      icon("circle-info"), " ",
      tags$b("任务、文件、环境、API Key 不同步。"),
      "它们指向的东西（产物文件、conda 环境、钥匙串）只存在于跑过它的那台",
      "机器上，搬过去只会得到一条点不开的空记录。同步的是「",
      tags$b("对话"), "」，不是「", tags$b("算过的东西"), "」。"),

    # ---- 目标机器 ----
    #
    # ⚠️ 这两个动作链接是有必要的，不是锦上添花：桌面版上"要同步到的那台
    #    服务器"和上面「硬件选择 → 远程服务器」里配的**通常就是同一台**，
    #    没有这个链接，用户得把地址、用户名、密码原样再敲一遍。
    div(class = "d-flex justify-content-between align-items-center mb-2",
      span(class = "fw-bold small", icon("server"), " 目标机器"),
      span(class = "small",
        actionLink(ns("sync_from_remote"), "用上面「远程服务器」填的")
      )
    ),

    # ★ V16.6 item 1：管理员登记好的跳板，从这里选一台，地址/端口/目录
    #   一次性填好，不用手打。
    #
    #   ⚠️ 只有**地址**是自动填的。用户名/密码/私钥仍然要自己填 —— 那是
    #      另一条策略（R/nodes.R:12-24）：凭据不写库、不落盘、不过网。
    #      这个下拉里**永远不会有**凭据，别哪天"顺手"加一个"记住密码"。
    #
    #   ⚠️ 用 uiOutput 现读库，不用在 sync_card_ui 里直接查：那个函数是
    #      **每次渲染 UI 跑一次**的普通函数，在里面查库等于把"这台机器有
    #      哪些跳板"冻在页面加载那一刻 —— 管理员刚加的那条要刷新才出现。
    # ⚠️ 这个 uiOutput 的 id 必须和里面 renderUI 画出来的那个 selectInput 的 id
    #    **不一样**。两个都叫 sync_pick 的话会渲染出**两个同 id 的节点**：
    #    uiOutput 是 `<div id="settings-sync_pick">`，里面的
    #    selectInput(ns("sync_pick")) 是 `<select id="settings-sync_pick">`。
    #    今天"能用"只是因为没人按 id 找它；一旦有人调
    #    updateSelectInput(session, "sync_pick", ...)，Shiny 走
    #    document.getElementById 拿到的是**外层那个 div**（它身上没有 input
    #    binding）→ 更新静默失效、不报错。探针里 `#settings-sync_pick` 也会
    #    直接撞上 strict mode 冲突。所以外层叫 _ui，select 仍然叫 sync_pick
    #    （input$sync_pick 不变）。
    uiOutput(ns("sync_pick_ui")),
    div(class = "d-flex gap-2",
      div(style = "flex:3 1 0; min-width:0;",
        textInput(ns("sync_host"), NULL, placeholder = "服务器地址，如 1.2.3.4")),
      div(style = "flex:1 1 0; min-width:0;",
        textInput(ns("sync_port"), NULL, value = "22"))
    ),
    textInput(ns("sync_user"), NULL, placeholder = "SSH 用户名"),
    radioButtons(ns("sync_auth"), NULL, inline = TRUE,
      choices = c("密码" = "password", "私钥" = "key"), selected = "password"),
    conditionalPanel(
      condition = sprintf("input['%s'] === 'password'", ns("sync_auth")),
      passwordInput(ns("sync_pw"), NULL, placeholder = "SSH 登录密码")
    ),
    conditionalPanel(
      condition = sprintf("input['%s'] === 'key'", ns("sync_auth")),
      textAreaInput(ns("sync_key"), NULL, rows = 3,
                    placeholder = "把私钥文件全文粘进来（含 BEGIN/END 行）")
    ),

    # ---- 远端同步目录 ----
    #
    # ⚠️ 这一栏看着多余，其实是**必须有**的：同步包要放进服务器的
    #    data 目录（应用跑在 shiny 用户下，和 ssh 进来的用户不是同一个
    #    $HOME，所以没法按 $HOME 猜 —— 详见 R/sync.R 文件头第五节）。
    #    猜错的后果是**两边永远见不着面、谁都不报错**，所以宁可让用户填。
    textInput(ns("sync_dir"), NULL, value = DSAPP_SYNC_REMOTE_DIR_DEFAULT,
              placeholder = "/srv/shiny-server/YCFS_APP/data/sync"),
    p(class = "small text-muted mb-2",
      icon("folder-tree"), " 服务器上 YCFS_APP 的 data 目录下的 sync 子目录，",
      "就是 .Renviron 里 DSAPP_DATA_ROOT 后面加 /sync。",
      tags$br(),
      "改这一栏等于换一个同步对象（水位重算、数据重传一遍，不会丢）。"),

    # ★ 凭据的边界必须写明。这里和上面「我的服务器」那张卡片是**同一条**
    #   策略（R/nodes.R:12-24）：不写库、不落盘，只活在这次会话的内存里。
    #   V13.3 立项时专门问过用户要不要"加密存盘以便无人值守"，
    #   用户选了**不松动这条策略** —— 别再自作主张加"记住密码"。
    p(class = "small text-muted mb-2",
      icon("shield-halved"), " 密码/私钥只存在这次会话的内存里，不写数据库、不落盘；",
      "关掉页面就要重填。"),

    actionButton(ns("sync_do"), "立即同步", class = "btn-primary w-100",
                 icon = icon("arrows-rotate")),
    uiOutput(ns("sync_status"))
  )
}

# ---------------------------------------------------------------------------
# 远程服务器表单（拆出来只是因为 UI 主体太长）
# ---------------------------------------------------------------------------
remote_form_ui <- function(ns) {
  tagList(
    # ---- 名册 ----
    #
    # 放在表单**之前**：用户的动线是"先挑一台机器"，挑完表单就填好了；
    # 放后面的话，他得先看见一张要手填的表才知道下面还有个名册。
    div(class = "dsapp-node-roster",
      div(class = "d-flex justify-content-between align-items-center mb-2",
        span(class = "fw-bold small", icon("server"), " 我的服务器"),
        span(class = "small text-muted",
             "凭据不保存在名册里，载入后还要填一次密码/私钥")
      ),
      uiOutput(ns("node_list")),
      div(class = "d-flex gap-2 align-items-end mt-2 flex-wrap",
        div(style = "flex:1 1 200px; min-width:180px;",
          textInput(ns("node_name"), NULL, placeholder = "给这台机器起个名字，如「实验室 4090」")
        ),
        actionButton(ns("node_save"), "保存当前表单",
                     class = "btn-sm btn-outline-primary mb-3",
                     icon = icon("floppy-disk"))
      )
    ),

    tags$hr(),

    layout_columns(
      col_widths = c(6, 3, 3),
      textInput(ns("rm_host"), "主机 / IP", placeholder = "192.168.1.10"),
      numericInput(ns("rm_port"), "端口", value = 22, min = 1, max = 65535),
      textInput(ns("rm_user"), "用户名", placeholder = "root")
    ),

    radioButtons(ns("rm_auth"), "认证方式", inline = TRUE,
                 choices = c("密码" = "password", "私钥" = "key"),
                 selected = "password"),

    conditionalPanel(
      condition = sprintf("input['%s'] === 'password'", ns("rm_auth")),
      passwordInput(ns("rm_password"), "登录密码", width = "100%")
    ),

    conditionalPanel(
      condition = sprintf("input['%s'] === 'key'", ns("rm_auth")),
      textAreaInput(ns("rm_key"), "私钥内容",
                    rows = 5, width = "100%",
                    placeholder = "-----BEGIN OPENSSH PRIVATE KEY-----\n..."),
      helpText(class = "small text-muted",
               dsapp_md_inline("把私钥文件**全文**粘进来（含首尾的 BEGIN/END 行）。"))
    ),

    textInput(ns("rm_activate"), "激活环境的命令（可选）", width = "100%",
              placeholder = "source ~/miniconda3/bin/activate myenv"),
    helpText(class = "small text-muted",
             paste0("远程机器上怎么进你的 conda/venv 环境。不填就用系统默认的 ",
                    "Rscript / python3。这台服务器不代为管理远程环境，",
                    "只负责在你给的环境里跑代码。")),

    textInput(ns("rm_workdir"), "远程工作目录（可选）", width = "100%",
              placeholder = "~/dsapp_runs"),
    helpText(class = "small text-muted",
             "留空则用 ~/dsapp_runs/task-<编号>，任务结束即删。"),

    div(class = "d-flex align-items-center gap-2 mt-1",
      actionButton(ns("rm_test"), "测试连接",
                   class = "btn-outline-primary btn-sm",
                   icon = icon("plug-circle-check")),
      uiOutput(ns("rm_test_badge"), inline = TRUE)
    ),

    uiOutput(ns("rm_test_result")),

    div(class = "dsapp-warn mt-2",
      icon("shield-halved"), " 密码/私钥只存在这次会话的内存里，不写数据库、不落盘。",
      "执行时 ssh 需要临时落一个凭据文件（权限 0600、随机目录名），",
      "命令一结束无论成败立刻删除；应用每次启动也会清掉残留。")
  )
}

mod_settings_server <- function(id, state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    cfg <- dsapp_config()

    # 异步任务句柄（远程连接测试）
    #
    # ⚠️ models_job / models_res 和 rv（温度/思考模式）在 V6 跟着模型卡片
    #    一起搬到 mod_model.R 了。这里只剩 SSH 这一对。
    ssh_job    <- reactiveVal(NULL)
    ssh_res    <- reactiveVal(NULL)   # list(ok, msg, bins)

    # =======================================================================
    # 界面皮肤（V8 item 4）
    # =======================================================================
    #
    # 三件事，顺序不能反：改内存里的 state$skin → 推到浏览器 → 落库。
    #
    # ⚠️ 落库放最后，而且**不因为它失败就把界面退回去**。用户点的是"我要
    #    这个皮肤"，那个诉求当场就该被满足；存不上是服务端的事，下回登录
    #    会退回上一个。反过来做（先落库、成功才换）的话，库一抖用户就看着
    #    卡片弹回去，而屏幕上没有任何东西告诉他为什么。
    #
    # ⚠️ 推给浏览器要传**顶层** session（state$root_session），不是这里的
    #    session。模块的 session 是带命名空间的，sendCustomMessage 发出去的
    #    消息名会被加前缀，app.js 按 "dsapp:skin" 注册的处理器收不到 ——
    #    表现是"点了没反应，也不报错"（和 dsapp_nav_to 同一个坑）。
    observeEvent(input$skin, {
      sk <- dsapp_skin_norm(input$skin)
      state$skin <- sk
      # ⚠️⚠️ 这里**不能**写 `state$root_session %||% session`。
      #
      #    `%||%` 的定义是 `if (is.null(a) || length(a) == 0 || is.na(a[1])) b else a`
      #    （R/utils.R:5），而 **session 是 R6 对象 = environment，R 对
      #    environment 的 length() 恒为 0**。于是这个表达式永远走 `b` 那一支，
      #    静默地退回模块自己的 session —— 不报错、不告警，看着完全正常。
      #
      #    症状：点皮肤卡片**毫无反应**（2026-09-15 实测，10 秒内 data-skin
      #    一次都没变过），但库里已经存上了 —— 因为 dsapp_skin_save() 走的是
      #    另一条路。刷新一下又对了（app.R 那条顶层 observe 用的是真·root
      #    session）。"改完没反应、刷新才生效"是这类 bug 的典型长相。
      #
      #    这个坑对**所有**拿着 session/环境去 `%||%` 的写法都成立，不止这一处。
      #    要判空就老老实实写 is.null()。
      dsapp_skin_apply(if (is.null(state$root_session)) session else state$root_session,
                       sk)
      uid <- state$user_id
      if (!is.null(uid) && !is.na(uid)) {
        try(dsapp_skin_save(uid, sk, con = dsapp_db(cfg)), silent = TRUE)
      }
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # 选择卡本身。依赖**只有** state$user_id —— 见 mod_settings_ui 里那段
    # 长注释：这里多依赖一个 state$skin，整个主界面就会跟着重渲。
    output$skin_card <- renderUI({
      uid <- state$user_id
      sel <- if (is.null(uid) || is.na(uid)) dsapp_skin_default() else
        tryCatch(dsapp_skin_get(uid, con = dsapp_db(cfg)),
                 error = function(e) dsapp_skin_default())
      dsapp_skin_picker(ns, selected = sel)
    })

    # =======================================================================
    # 面板尺寸（V13.2 item 5）
    # =======================================================================
    #
    # 和皮肤相反：尺寸**不做即时预览**。用户在数字框里敲 "4"，中间那一格是
    # 个半成品，拿它去改版面只会让页面抖一下再抖回来。这里落库 + 广播，
    # 由 mod_chat 那段 renderUI 统一把新尺寸发下去（它是尺寸唯一的出口，
    # 这样刷新前刷新后是同一份值）。
    #
    # ⚠️ 只写**这一个**键，其余沿用库里现在的值：dsapp_uipref_save() 收的是
    #    一份完整的偏好，少给一个键它会把那个键当"没设过"打回默认值 ——
    #    表现是"改完宽度，输入区高度自己变回自动了"。
    save_uipref <- function(which, value) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      full <- dsapp_uipref_get(uid, con = dsapp_db(cfg))
      full[[which]] <- value
      try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg)), silent = TRUE)
      state$uipref_rev <- state$uipref_rev + 1L
    }

    observeEvent(input$pref_sess_w,     save_uipref("sess_w", input$pref_sess_w),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    observeEvent(input$pref_files_w,    save_uipref("files_w", input$pref_files_w),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    observeEvent(input$pref_composer_h, save_uipref("composer_h", input$pref_composer_h),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    # V13.5 item 8 / item 2：主菜单、历史任务页执行历史栏。
    observeEvent(input$pref_menu_w,     save_uipref("menu_w", input$pref_menu_w),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    observeEvent(input$pref_tasks_w,    save_uipref("tasks_w", input$pref_tasks_w),
                 ignoreNULL = TRUE, ignoreInit = TRUE)
    # V14 item 1：文件页「文件管理区 ↔ 预览」。
    observeEvent(input$pref_filespage_w, save_uipref("filespage_w", input$pref_filespage_w),
                 ignoreNULL = TRUE, ignoreInit = TRUE)

    observeEvent(input$pref_reset, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      def <- dsapp_uipref_norm(NULL)
      try(dsapp_uipref_save(uid, def, con = dsapp_db(cfg)), silent = TRUE)
      # ⚠️ 除了广播，还得把这几个输入框**自己**的值按回去。光靠 output 重渲
      #    是没用的：renderUI 重建的是数字框的 DOM，而 input$pref_files_w
      #    在这之后仍然是用户刚填的那个数，用户看到的也还是它。不按回去的
      #    表现是"点了恢复默认，页面确实回去了，设置页这几个框还写着 420"。
      #
      # ⚠️ 加了 pref_sess_w 就必须在这里也加一行 —— 漏掉的表现只出现在
      #    那一个框上（另外两个都回去了，就它没回去），看着像"这个框坏了"。
      updateNumericInput(session, "pref_sess_w",     value = def$sess_w)
      updateNumericInput(session, "pref_files_w",    value = def$files_w)
      updateNumericInput(session, "pref_composer_h", value = def$composer_h)
      updateNumericInput(session, "pref_menu_w",     value = def$menu_w)
      updateNumericInput(session, "pref_tasks_w",    value = def$tasks_w)
      updateNumericInput(session, "pref_filespage_w", value = def$filespage_w)
      state$uipref_rev <- state$uipref_rev + 1L
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★ 卡片本身。依赖**只有** state$user_id。
    #
    # ⚠️ 别在这里读 state$uipref_rev 来同步"在页面上拖出来的新尺寸"。看着
    #    很合理，实际是个焦点杀手：数字框每敲一下都会走 save_uipref() →
    #    rev 加一 → 这里重渲 → 用户正在打字的那个框被**重建**，光标和还没
    #    输完的内容一起没。敲 "420" 会变成敲一下丢一下。
    #
    #    拖出来的值怎么显示到这儿？**不用特意管**：Shiny 会把隐藏页面上的
    #    output 挂起（suspendWhenHidden 默认就是 TRUE），在言出法随页拖完
    #    再切到设置页，这块是重新渲染的，读到的已经是新值。切回来这一下
    #    天然就是同步点。
    output$uipref_card <- renderUI({
      uid <- state$user_id
      p <- if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
             dsapp_uipref_norm(NULL)
           } else {
             tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                      error = function(e) dsapp_uipref_norm(NULL))
           }
      dsapp_uipref_card(ns, p)
    })

    # ★ 「离开页面之后」那张卡片（V13.7 item 5）。
    #
    # ⚠️ 单独一个 output，不能和上面那张共用：共用的话 radio 每选一次都会
    #    连带把数字框整块重建一遍（同一个焦点杀手，反过来也一样）。
    #
    # ⚠️ 依赖也只有 state$user_id。别读 state$uipref_rev —— 点了 radio
    #    本来就要立刻重渲一次才能看到选中态，而 Shiny 自己会把选中态画上，
    #    不需要重渲。
    output$detach_card <- renderUI({
      uid <- state$user_id
      p <- if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
             dsapp_uipref_norm(NULL)
           } else {
             tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                      error = function(e) dsapp_uipref_norm(NULL))
           }
      dsapp_detach_card(ns, p)
    })

    # 选了就存。⚠️ 必须走 save_uipref()（只写这一个键），不能自己拼一份
    # 完整的偏好存进去 —— 那样会把另外几个键打回默认值，表现是"改完这个
    # 开关，面板宽度自己变回去了"。同一个坑，save_uipref 上面那段写着。
    observeEvent(input$pref_detach, {
      save_uipref("agent_detach", input$pref_detach)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)

    # ★ V13.12 item 4：「AI 怎么干活」那张卡片。
    #
    # ⚠️ 和 detach_card 同一个形状，理由也一样（自己一个 output、只依赖
    #    state$user_id）。
    output$agent_card <- renderUI({
      uid <- state$user_id
      p <- if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
             dsapp_uipref_norm(NULL)
           } else {
             tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                      error = function(e) dsapp_uipref_norm(NULL))
           }
      dsapp_agent_pref_card(ns, p)
    })

    # ⚠️ 勾选框用 isTRUE(...)：input$ 在控件还没 bind 好时是 NULL，直接写进
    #    库里会存一个 NULL —— jsonlite 把它序列化成 `{}`，下次读回来
    #    dsapp_uipref_one 判不出是逻辑值，落到 def。表现是"设置页勾了，
    #    刷新又回去了"，且不报错。
    #
    # ⚠️ 这里**不写** agent_asked。用户在设置页改主意不等于"他还没被问过"，
    #    写进去会让弹窗判定跟着变 —— 那个键只有一个地方写：弹窗自己。
    observeEvent(input$pref_agent_auto,
                 save_uipref("agent_auto", isTRUE(input$pref_agent_auto)),
                 ignoreInit = TRUE)
    observeEvent(input$pref_agent_autofix,
                 save_uipref("agent_autofix", isTRUE(input$pref_agent_autofix)),
                 ignoreInit = TRUE)

    # =======================================================================
    # 邮件提醒（★ Test_V15.2 item 2）
    # =======================================================================
    #
    # ★ 没配 SMTP 就**整张卡都不出现**（连 card() 的外框都由 output 给）。
    #   `dsapp_mail_ready()` 判的是"四个字段配没配齐"，不是某个开关 —— 这样
    #   不存在"开关开着但没配 host"的半成品状态，Windows 便携包和用户自托管
    #   的部署上也就不会露出一个点了必然报错的按钮。
    #
    # ⚠️ 每个会话算一次就够：cfg 是会话级常量，dsapp_config() 读的是进程的
    #    环境变量，会话中途不会变。
    mail_ok <- isTRUE(dsapp_mail_ready(cfg))

    output$mail_card_wrap <- renderUI({
      if (!mail_ok) return(NULL)
      card(
        card_header(icon("envelope"), " 邮件提醒"),
        card_body(uiOutput(ns("mail_card")))
      )
    })

    # ⚠️⚠️ 这张卡**读** state$uipref_rev（和上面两张不一样，它们是故意不读的）。
    #    因为「言出法随」页的控制栏里也有同一个开关，用户在那边勾了、再切到
    #    这一页，卡片必须显示新值 —— 不读 rev 的话它停在会话开始那一刻的样子，
    #    显示的是"用户以为已经改掉"的旧值。
    #
    #    读 rev 会引来一个经典的自失效环（重渲 → 控件重发 input → observer
    #    存一遍 → rev+1 → 又重渲）。**环是在 observer 那一侧断的**：见
    #    `mail_pref_changed()`，值没变就一个字节都不写。所以就算 Shiny 在重渲
    #    之后照发一次 input，那一次也是空转。
    output$mail_card <- renderUI({
      state$uipref_rev          # ← 依赖，故意的，理由见上
      uid <- state$user_id
      p <- dsapp_uipref_norm(NULL)
      email <- ""
      if (!is.null(uid) && !is.na(suppressWarnings(as.integer(uid)))) {
        p <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                      error = function(e) dsapp_uipref_norm(NULL))
        email <- tryCatch(
          as.character(dsapp_user_by_id(uid, con = dsapp_db(cfg))$email %||% "")[1],
          error = function(e) "")
      }
      dsapp_mail_pref_card(ns, p, email)
    })

    # 值真的变了才写。★ 这是上面那个自失效环唯一的断点 —— 别为了"少查一次库"
    # 把这次比对删掉：删了之后界面上勾选框会闪烁、库里被反复重写，而且
    # 症状随 Shiny 版本变（有的版本重渲后不重发 input，看着一切正常）。
    mail_pref_changed <- function(which, value) {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
      cur <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                      error = function(e) dsapp_uipref_norm(NULL))
      if (identical(isTRUE(cur[[which]]), isTRUE(value))) return(invisible(FALSE))
      save_uipref(which, isTRUE(value))
      invisible(TRUE)
    }
    observeEvent(input$pref_mail_task,
                 mail_pref_changed("email_task", input$pref_mail_task),
                 ignoreInit = TRUE)
    observeEvent(input$pref_mail_lit,
                 mail_pref_changed("email_lit_done", input$pref_mail_lit),
                 ignoreInit = TRUE)

    # ---- 「发一封测试邮件」--------------------------------------------------
    #
    # ★ 走的是**和真信完全同一条路**：入队 → kick → 子进程排空 → SMTP。
    #   不在这里直接调 dsapp_mail_send_raw()：那样"测试通过"只证明了本进程
    #   能连上，证明不了后台那条通路（.Renviron 有没有被子进程读到、队列
    #   认领对不对）是通的 —— 而那才是真信要走的路。
    #
    # ⚠️ 入队 + 轮询回执那套在 dsapp_mail_ui_watch() 里，**和文献速递页
    #    共用一份**（两处各写一遍的话，迟早只有一处被修）。
    mail_watch <- dsapp_mail_ui_watch(cfg)

    output$mail_test_msg <- renderUI({
      state$uipref_rev
      note <- mail_watch$note()
      uid <- state$user_id
      last <- if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) ""
              else tryCatch(dsapp_mail_last_error(uid, cfg = cfg, con = dsapp_db(cfg)),
                            error = function(e) "")
      tagList(
        if (nzchar(note)) tags$div(class = "small mt-2 text-muted", note),
        # ⚠️ 上次失败的原因**常驻**显示，不能只在点了按钮之后才出现 ——
        #    定时订阅是在没人看着的时候发信的，失败时页面根本没开。
        #    "静默放弃"是这个仓库反复踩过的坑。
        if (nzchar(last))
          tags$div(class = "small mt-2 text-danger", icon("triangle-exclamation"),
                   " 上次发信失败：", last)
      )
    })

    observeEvent(input$mail_test, {
      uid <- state$user_id
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        mail_watch$note("请先登录。"); return()
      }
      to <- tryCatch(
        as.character(dsapp_user_by_id(uid, con = dsapp_db(cfg))$email %||% "")[1],
        error = function(e) "")
      if (!nzchar(to) || !grepl("@", to, fixed = TRUE)) {
        mail_watch$note("这个账号没有填邮箱，先到「账号」那一栏补上。"); return()
      }
      # ⚠️ ref 留空：测试信**故意不去重**，用户点几次就发几封。
      #    用 ref 的话第二次点会静默什么都不做（入队被唯一索引挡掉），
      #    表现就是"按钮失灵"，而错误信息在库的另一头。
      id <- dsapp_mail_enqueue(
        to = to,
        subject = sprintf("【言出法随】测试邮件（%s）",
                          format(Sys.time(), "%Y-%m-%d %H:%M")),
        body_md = paste0(
          "这是一封测试邮件，用来确认你的邮箱能收到「言出法随」的信。\n\n",
          "- 收件地址：", to, "\n",
          "- 发送时间：", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n\n",
          "收到这封信说明链路是通的。没收到的话先看看垃圾邮件箱。\n"),
        kind = "test", ref = "", user_id = as.integer(uid),
        cfg = cfg)
      dsapp_mail_kick(cfg)
      mail_watch$send(id)
    }, ignoreInit = TRUE)

    # =======================================================================
    # 本地库 ↔ 在线版同步（V13.3 item 2）
    # =======================================================================
    #
    # ★ 整轮同步跑在**子进程**里（dsapp_bg_start → R/sync.R 的
    #   dsapp_sync_worker）。绝不能在本进程里同步跑：一次同步要 scp 好几个
    #   来回，而全站只有一个 R 进程，在这儿阻塞等于所有人一起卡住 ——
    #   R/health.R:26 那段注释骂的就是这个写法。
    #
    # ★ 凭据**不进 state**，只从 input 里现读、现拼成 target 交给子进程。
    #   input 是浏览器的会话状态，关掉页面就没了，边界和 state 一样；
    #   区别是它不会在本进程的内存里多留一份。这是 V13.3 立项时用户明确
    #   选的"不落盘"那条路，别再顺手加"记住密码"。
    sync_job <- reactiveVal(NULL)
    sync_res <- reactiveVal(NULL)
    sync_rev <- reactiveVal(0)

    observeEvent(input$sync_from_remote, {
      updateTextInput(session, "sync_host", value = input$rm_host %||% "")
      updateTextInput(session, "sync_port",
                      value = as.character(input$rm_port %||% 22))
      updateTextInput(session, "sync_user", value = input$rm_user %||% "")
      updateRadioButtons(session, "sync_auth",
                         selected = if (identical(input$rm_auth, "key")) "key"
                                    else "password")
      updateTextInput(session, "sync_pw", value = input$rm_password %||% "")
      updateTextAreaInput(session, "sync_key", value = input$rm_key %||% "")
    }, ignoreInit = TRUE)

    # ---- 管理员登记的跳板（V16.6 item 1）----------------------------------
    #
    # ⚠️ 这个下拉**只填地址**，一个字都不碰凭据那一栏。理由见上面
    #    「我的服务器」那张卡那条策略：凭据不写库、不落盘、不过网。
    #
    # ⚠️ 现读库（renderUI），不是 UI 函数里查一次：管理员刚加的那条应当
    #    在下一次渲染就出现，而不是"要刷新页面"。
    # ⚠️ 名字要和卡上那个 uiOutput(ns("sync_pick_ui")) 逐字相同 ——
    #    写成 output$sync_pick 的话 Shiny 不报错，只是**不填那个 div**，
    #    于是"设置页没有这个下拉"，而自检全绿。
    output$sync_pick_ui <- renderUI({
      r <- tryCatch(dsapp_syncservers_list(only_enabled = TRUE,
                                           cfg = dsapp_config(),
                                           con = dsapp_db(dsapp_config())),
                    error = function(e) NULL)
      if (is.null(r) || !nrow(r)) return(NULL)
      dflt <- dsapp_syncserver_default(cfg = dsapp_config(),
                                       con = dsapp_db(dsapp_config()))
      ch <- c("（不用跳板，自己填）" = "",
              stats::setNames(as.character(r$id),
                              sprintf("%s（%s）", r$name, r$host)))
      tagList(
        selectInput(ns("sync_pick"), NULL, width = "100%", selectize = FALSE,
                    choices = ch,
                    selected = if (is.null(dflt)) "" else as.character(dflt$id)),
        p(class = "small text-muted mb-2",
          icon("tower-broadcast"), " 这一列来自后台管理页登记的跳板清单。",
          "选一条只填地址；", tags$b("SSH 用户名和密码永远要自己填"),
          "，不写库、不落盘。")
      )
    })

    # ⚠️ `ignoreInit` **故意不写**（默认 FALSE）。下拉在渲染时带着"默认
    #    跳板"那个选中值，这一条 observer 因此在会话开头**自己触发一次**,
    #    把地址填好 —— 桌面版第一次打开就该是这样（出厂清单里就一条，
    #    用户不该还要再点一下）。写成 ignoreInit = TRUE 的话，下拉显示着
    #    「官方中转」而下面三个框是空的，看着像坏了。
    observeEvent(input$sync_pick, {
      id <- suppressWarnings(as.integer(input$sync_pick %||% NA))
      # 选回「（不用跳板，自己填）」时**不清空**已经填好的东西 ——
      # 用户很可能只是想在这条地址上改一个字，清掉等于罚他重打一遍。
      if (is.na(id)) return()
      one <- tryCatch(dsapp_syncserver_get(id, cfg = dsapp_config(),
                                           con = dsapp_db(dsapp_config())),
                      error = function(e) NULL)
      if (is.null(one)) return()
      # 只在还空着的时候填。会话开头这一条会自己跑一次（那时确实是空的），
      # 但将来万一有谁让它多跑一次，也不该把用户已经改过的地址冲掉。
      if (!nzchar(trimws(input$sync_host %||% ""))) {
        updateTextInput(session, "sync_host", value = one$host %||% "")
      }
      if (!nzchar(trimws(input$sync_port %||% ""))) {
        updateTextInput(session, "sync_port",
                        value = as.character(one$port %||% 22))
      }
      if (nzchar(one$remote_dir %||% "")) {
        updateTextInput(session, "sync_dir", value = one$remote_dir)
      }
    })

    output$sync_status <- renderUI({
      sync_rev()
      res <- sync_res()
      uid <- isolate(state$user_id)
      u   <- isolate(state$user)

      # ---- 正在跑 ----
      if (!is.null(res) && identical(res$state, "running")) {
        return(p(class = "small text-muted mt-3 mb-0",
                 icon("spinner", class = "fa-spin"), " 正在同步，别关这个页面…"))
      }
      # ---- 刚跑完 ----
      if (!is.null(res) && identical(res$state, "done")) {
        v <- res$value %||% list()
        # ⚠️ V15.5 item 3：msg 是**我们自己写的**，里面带 `**强调**`（见下面
        #    need_login 那条）。div() 不渲染 markdown，直接塞进去用户看到的是
        #    星号 —— 过 dsapp_md_inline() 才会变成 <strong>。
        if (!isTRUE(v$ok)) {
          return(div(class = "alert alert-danger small mt-3 mb-0",
                     icon("circle-xmark"), " 同步失败：",
                     dsapp_md_inline(v$msg %||% "原因不明")))
        }
        return(div(class = "alert alert-success small mt-3 mb-0",
          icon("circle-check"), " ", dsapp_md_inline(v$msg %||% "同步完成"),
          if (isTRUE(v$truncated))
            tagList(tags$br(),
              tags$b("这一轮只传了一部分"), "（单轮有上限）。再点一次",
              "「立即同步」接着传剩下的。") else NULL))
      }

      # ---- 还没同步过：报一下本机标识和待应用的包 ----
      if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) {
        return(p(class = "small text-muted mt-3 mb-0", "登录后可用。"))
      }
      em <- (u$email %||% "")
      st <- tryCatch(dsapp_sync_status(em, remote_dir = input$sync_dir %||% "",
                                       cfg = cfg),
                     error = function(e) NULL)
      if (is.null(st)) {
        return(p(class = "small text-muted mt-3 mb-0", "读不到同步状态。"))
      }
      s <- st$state
      p(class = "small text-muted mt-3 mb-0",
        "本机标识 ", tags$code(st$node), tags$br(),
        if (nzchar(st$peer_node %||% ""))
          tagList("对端机器 ", tags$code(st$peer_node), tags$br()) else NULL,
        if (nzchar(s$last_at %||% ""))
          sprintf("上次同步：%s（%s）", s$last_at, s$note %||% "")
        else "还没同步过。",
        if (nzchar(st$in_at %||% ""))
          tagList(tags$br(), "已收到对端到 ", tags$code(st$in_at)) else NULL,
        if (st$pending_inbox > 0)
          tagList(tags$br(), sprintf("收件箱里还有 %d 个包待应用。",
                                     st$pending_inbox)) else NULL)
    })

    observeEvent(input$sync_do, {
      u <- isolate(state$user)
      uid <- isolate(state$user_id)
      em <- trimws(u$email %||% "")
      if (!nzchar(em)) {
        sync_res(list(state = "done", value = list(ok = FALSE,
                                                    msg = "请先登录")))
        sync_rev(sync_rev() + 1)
        return()
      }
      host <- trimws(input$sync_host %||% "")
      if (!nzchar(host)) {
        sync_res(list(state = "done", value = list(ok = FALSE,
                                                   msg = "请先填服务器地址")))
        sync_rev(sync_rev() + 1)
        return()
      }
      rdir <- trimws(input$sync_dir %||% "")
      if (!nzchar(rdir)) rdir <- DSAPP_SYNC_REMOTE_DIR_DEFAULT
      if (!grepl("^/", rdir)) {
        sync_res(list(state = "done", value = list(
          ok = FALSE, msg = "「远端同步目录」要填绝对路径（以 / 开头）。")))
        sync_rev(sync_rev() + 1)
        return()
      }
      target <- list(remote = list(
        host     = host,
        port     = suppressWarnings(as.integer(input$sync_port %||% 22)),
        user     = trimws(input$sync_user %||% ""),
        auth     = if (identical(input$sync_auth, "key")) "key" else "password",
        password = input$sync_pw %||% "",
        key_text = input$sync_key %||% ""
      ))
      # 先在本进程里校验一遍参数（主机名白名单等在 dsapp_ssh_ctx 里）。
      # 提前挡掉的好处是"填错了"能立刻回话，不用等子进程起完再报。
      bad <- tryCatch(dsapp_ssh_ctx(target, cfg), error = function(e) NULL)
      if (is.null(bad) || !isTRUE(bad$ok)) {
        sync_res(list(state = "done", value = list(
          ok = FALSE, msg = (bad$msg %||% "连接参数不合法"))))
        sync_rev(sync_rev() + 1)
        return()
      }

      sync_res(list(state = "running"))
      sync_rev(sync_rev() + 1)
      # ★ 同步密钥必须在**这里**（主进程）取出来，当成参数交给子进程
      #   （V13.7 item 7）。子进程的内存密钥表是空的 —— 让它自己去取，
      #   拿到的是空串，然后每一轮都会报"需要重新登录"，而人明明登录着。
      #   取不到就**不起子进程**：省得白跑一趟 scp 再回来报错。
      skey <- tryCatch(dsapp_synckey_get(em), error = function(e) "")
      if (!nzchar(skey)) {
        sync_res(list(state = "done", value = list(
          ok = FALSE, need_login = TRUE,
          msg = paste0(
            "拿不到同步密钥，这一轮没有开始。\n",
            "同步包要签名（否则任何人往收件箱里放个文件，就能把内容塞进你的",
            "账号），而密钥是从登录密码现推的、只放在内存里 —— ",
            "请退出后用**密码**重新登录一次（恢复码登录不经过密码，推不出密钥），",
            "然后再点同步。"))))
        sync_rev(sync_rev() + 1)
        return()
      }
      h <- tryCatch(
        dsapp_bg_start("dsapp_sync_worker",
                       args = list(cfg = cfg, target = target,
                                   email = em, user_id = as.integer(uid),
                                   remote_dir = rdir, key = skey),
                       cfg = cfg, tag = "sync"),
        error = function(e) e)
      if (inherits(h, "error")) {
        sync_res(list(state = "done", value = list(
          ok = FALSE, msg = paste0("起不了后台进程：", conditionMessage(h)))))
        sync_rev(sync_rev() + 1)
        return()
      }
      sync_job(h)
    }, ignoreInit = TRUE)

    # 轮询子进程。只在这个会话**自己发起过**同步时才转 —— 别的会话发起的
    # 那一轮由它自己收，这里不掺和（同步是用户手动触发的，不是后台常驻）。
    #
    # ⚠️ 顶层这句 `sync_job()` **必须保持是普通读、不能套 isolate()** ——
    #    它就是这个 observer 唯一的启动条件（上面 observeEvent 里写
    #    sync_job(h) 时靠这个依赖把它唤醒）。隔离掉的话它永远不会跑。
    #
    # ⚠️ 而下面那句 `sync_rev(...)` 的**读**那一侧就必须 isolate()：这个
    #    observer 自己会写 sync_rev，不隔离就是"自读自写" —— 自检里有一条
    #    专门扫这个（自检里搜「全仓没有 observe() 裸读自己写的 reactiveVal」；
    #    这里不写行号 —— 行号会随着自检本身长大而漂，2026-09-16 这一处就已经
    #    从 1570 漂到一万多行了，留着比删掉更误导）。那类写法真的会让应用空转。
    observe({
      # dsapp-selftest: self-reactive-ok sync_job, ssh_job
      #
      #   ⚠️ 显式豁免，**两个**句柄轮询共用这一行（另一个在下面"测试连接"
      #     那里）。两个都是同一个形状：读句柄 → 还没完就继续定时 → 取完写
      #     NULL。不会失控的理由：**写进去的是 NULL**，下一轮第 2 行就 return。
      #     读那一侧不能 isolate —— 点「同步」「测试连接」时由 observeEvent
      #     写句柄，靠这个依赖唤醒轮询。
      h <- sync_job()
      if (is.null(h)) return()
      invalidateLater(1000)
      r <- dsapp_bg_poll(h)
      if (!isTRUE(r$done)) return()
      sync_job(NULL)
      sync_res(list(state = "done", value = r$value %||%
                      list(ok = FALSE, msg = r$msg %||% "子进程没有返回结果")))
      sync_rev(isolate(sync_rev()) + 1)
    })

    # =======================================================================
    # 账号密码（item：修改 / 补设密码）
    # =======================================================================
    #
    # 两种状态，表单长得不一样：
    #   没设过密码 → 只有「新密码 + 确认」（"当前密码"那一栏根本不存在；
    #                让人对着一个空格子猜"这里该填什么"是最没必要的为难）
    #   设过了     → 多一栏「当前密码」，改之前先证明你知道
    #
    # 状态从库里读，不从 state$user 读：state$user 是登录那一刻的快照，
    # 而改完密码要立刻反映在界面上。
    # 改完密码后重新渲染这张卡片的信号。只是个计数器。
    #
    # ⚠️ 它**只能**在 observeEvent 里被 +1，绝不能在 renderUI 里面写。
    #    在渲染函数里写 reactiveVal 会让这个 output 依赖它自己 → 自己把
    #    自己标脏，服务端反复重算，浏览器那边报一连串
    #    "progress message for ... but the output is in an unexpected state"。
    #    卡片本身每次都直接读库，不需要缓存一份状态。
    pw_ver <- reactiveVal(0)
    pw_msg <- reactiveVal(NULL)

    output$pw_card <- renderUI({
      pw_ver()
      uid <- state$user_id
      if (is.null(uid)) return(p(class = "small text-muted", "请先登录。"))
      u <- tryCatch(dsapp_user_by_id(uid, con = dsapp_db(cfg)),
                    error = function(e) NULL)
      st <- dsapp_user_pw_state(u)

      tagList(
        div(class = "small mb-2",
          if (st$has) {
            tagList(icon("circle-check"), " 这个账号", tags$b("已设密码"),
              "：别人拿你的邮箱进不来。")
          } else {
            tagList(icon("triangle-exclamation", class = "text-warning"),
              " 这个账号", tags$b("没设密码"),
              "：别人只要填你的邮箱就能进来看到你的所有对话。",
              "设一个密码，这种情况就不存在了。")
          }
        ),

        # 已设密码才有「当前密码」这一栏
        if (st$has)
          passwordInput(ns("pw_old"), "当前密码",
                        placeholder = "改密码要先填现在这个"),

        div(class = "dsapp-welcome-grid",
          passwordInput(ns("pw_new"), "新密码",
                        placeholder = sprintf("至少 %d 位", DSAPP_PW_MIN)),
          passwordInput(ns("pw_new2"), "再输一次", placeholder = "两次要一样")
        ),
        uiOutput(ns("pw_match")),

        # ⚠️ 这里必须说明白：密码管的是"别人能不能用你的账号"，管不了
        #    "数据安全"。用户以为自己设了密码，就可以往里放病人的数据 ——
        #    那是这个应用给不了的承诺。
        #
        # ★ V13.1 item 8：原来这句写的是「不改变文件管理区对所有人可见」。
        #   管理区早就按账号隔离了，那句是**反的** —— 而且方向很坏：它把
        #   用户吓到不敢放数据的同时，又暗示了"设密码也没用"。实际边界是
        #   另一回事：文件确实只有你能看到，但**服务器管理员能**（文件就在
        #   磁盘上，root 一直读得到），API Key 也在库里。这句话要挡的是
        #   "把这里当合规数据仓库"，不是"别人会看到"。
        p(class = "small text-muted",
          "密码只挡「谁能登进这个账号」。文件管理区是", tags$b("按账号隔离的"),
          "，别人看不到你的文件；但服务器管理员始终能读到磁盘上的东西，",
          "所以别把这里当合规的数据仓库用。要放敏感数据，先看首页那段说明。"),

        actionButton(ns("pw_save"),
                     if (st$has) "修改密码" else "设置密码",
                     class = "btn-primary w-100",
                     icon = icon("lock")),
        uiOutput(ns("pw_feedback"))
      )
    })

    output$pw_feedback <- renderUI(pw_msg())

    observeEvent(input$pw_save, {
      uid <- state$user_id
      if (is.null(uid)) return()

      # 两次输入的一致性在**这里**判，不在 dsapp_user_set_password 里 ——
      # 那个函数是三个入口共用的，"确认框"是表单层的事，管理员重置那条路
      # 只有一栏，不该被要求填两遍。
      if (!identical(input$pw_new %||% "", input$pw_new2 %||% "")) {
        pw_msg(div(class = "alert alert-danger py-2 px-3 mt-3 mb-0 small",
                   icon("triangle-exclamation"), " 两次输入的新密码不一样。"))
        return()
      }

      r <- tryCatch(
        dsapp_user_set_password(uid, input$pw_new %||% "",
                                old_password = input$pw_old %||% "",
                                con = dsapp_db(cfg)),
        error = function(e) list(ok = FALSE, msg = conditionMessage(e)))

      if (!isTRUE(r$ok)) {
        pw_msg(div(class = "alert alert-danger py-2 px-3 mt-3 mb-0 small",
                   icon("triangle-exclamation"), " ", r$msg))
        return()
      }
      pw_msg(NULL)
      pw_ver(pw_ver() + 1)     # 让卡片重新读一遍库（按钮文字/字段会变）
      showNotification(r$msg, type = "message")
      # 密码框里留着明文没有意义，清掉
      updateTextInput(session, "pw_old", value = "")
      updateTextInput(session, "pw_new", value = "")
      updateTextInput(session, "pw_new2", value = "")
    })

    # 两次输入要一致 —— 打字的时候就提示，不用等点了保存才知道白填一遍。
    #
    # ⚠️ 这条提示写在**自己的 output** 里，不写进 pw_msg：那个值是"上一次
    #    操作的结果"，和"当前输入状态"是两回事。共用一个的话，用户改对了
    #    之后那句旧警告还挂在那里（这条 observe 不匹配就什么都不写），
    #    看起来像"改了也没用"。
    output$pw_match <- renderUI({
      a <- input$pw_new %||% ""; b <- input$pw_new2 %||% ""
      if (!nzchar(a) || !nzchar(b) || identical(a, b)) return(NULL)
      div(class = "small text-warning mt-1",
          icon("circle-info"), " 两次输入的新密码不一样。")
    })
    # =======================================================================
    # 分析环境（item 2）
    # =======================================================================

    observeEvent(input$target_kind, {
      state$exec_target <- input$target_kind %||% "server"
    }, ignoreInit = FALSE)

    # -----------------------------------------------------------------------
    # conda 环境选择 —— 在「环境」页，不在这里
    # -----------------------------------------------------------------------
    #
    # 设置页原本有一个 output$server_env_ui（conda 环境下拉框）和配套的
    # observeEvent(input$server_env)，item 4 时删掉了。V5 把"选基础环境"
    # 加回来，但**装在「环境」页**（见 mod_envs.R），不在这里。
    #
    # 为什么不放回来：设置页这个位置是**远程目标表单**的一部分，环境下拉
    # 得靠 conditionalPanel 挂在 target_kind 上。conditionalPanel 在切换
    # 时会把整块重建，重建瞬间 input$server_env 短暂变 NULL，而写 state 的
    # observeEvent 会把 NULL 当成"回到系统环境"认真地执行一遍 —— 用户只是
    # 想切一下目标机，环境就被悄悄改了（V3 踩过这个坑，mod_chat.R 里那段
    # ⚠️ 记的是同一件事）。环境页没有这层联动，选就是选。
    #
    # state$exec_env 仍然只有环境页一个写入者；这里保留这段说明是为了让
    # 下一个想"顺手加个下拉框"的人先看到上面这两段。

    # ---- 远程表单 → state ----
    #
    # 全部即时同步到会话状态，没有「保存」这一步 —— 用户从提醒跳过来改完
    # 直接点返回对话，多点一次保存只会多一个忘记点的机会。
    #
    # ⚠️ rm_values() 刻意做成"读 input 的普通函数"，而不是去读 state$remote。
    # 下面那个 observe 既要写 state$remote、又要算它有没有被改过；如果算指纹
    # 时再去读 state$remote，这个 observe 就成了自己的触发源，会无限自激。
    rm_values <- function(v) {
      list(
        host     = trimws(v$rm_host %||% ""),
        port     = suppressWarnings(as.integer(v$rm_port %||% 22)),
        user     = trimws(v$rm_user %||% ""),
        auth     = v$rm_auth %||% "password",
        password = v$rm_password %||% "",
        key_text = v$rm_key %||% "",
        activate = trimws(v$rm_activate %||% ""),
        workdir  = trimws(v$rm_workdir %||% "")
      )
    }

    # ---- 名册 ----
    #
    # 凭据的会话内缓存：节点 id → list(password, key_text)。
    # **只活在内存里**，关掉页面就没了。它存在的唯一理由是"在同一个会话里
    # 来回切两台机器不用反复重填" —— 不是"帮用户记住密码"。
    #
    # 放在 state 上而不是模块局部：state 的生存期就是这个浏览器会话
    # （见 app.R 的说明），正是我们要的那个边界。
    # ⚠️ 读 state 必须包 isolate()。`state` 是 reactiveValues，**在响应式
    #    上下文之外读它会直接抛错**（"Can't access reactive value ... outside
    #    of reactive consumer"）。这一行在模块初始化时跑，不是响应式上下文 ——
    #    裸读的后果不是这一处坏掉，而是整个应用的 UI 渲染不出来：app.R 的
    #    renderUI 在 server 里执行，模块初始化一抛异常，页面就只剩一个空壳。
    if (is.null(isolate(state$node_creds))) state$node_creds <- list()

    nodes_ver <- reactiveVal(0)

    nodes <- reactive({
      nodes_ver()
      dsapp_nodes_list(state$user_id, con = dsapp_db(cfg))
    })

    # 把表单填成某个节点的样子。凭据从会话缓存里补 —— 有就填上，没有就留空
    # 并让用户知道还要填一次。
    apply_node <- function(node, creds) {
      updateTextInput(session, "rm_host", value = node$host %||% "")
      updateNumericInput(session, "rm_port", value = as.integer(node$port %||% 22))
      updateTextInput(session, "rm_user", value = node$username %||% "")
      updateRadioButtons(session, "rm_auth",
                         selected = if (identical(node$auth, "key")) "key" else "password")
      updateTextInput(session, "rm_activate", value = node$activate %||% "")
      updateTextInput(session, "rm_workdir", value = node$workdir %||% "")
      updateTextInput(session, "node_name", value = node$name %||% "")
      updateTextInput(session, "rm_password", value = creds$password %||% "")
      updateTextAreaInput(session, "rm_key", value = creds$key_text %||% "")
    }

    output$node_list <- renderUI({
      df <- nodes()
      if (is.null(df) || nrow(df) == 0) {
        return(p(class = "text-muted small mb-1",
                 "还没有保存过服务器。填好下面的表单，起个名字点「保存当前表单」，",
                 "以后就能一键载入。"))
      }
      lapply(seq_len(nrow(df)), function(i) {
        nid  <- as.integer(df$id[[i]])
        is_d <- as.integer(df$is_default[[i]]) == 1L
        n    <- as.list(df[i, , drop = FALSE])
        div(class = "d-flex justify-content-between align-items-center border-bottom py-2",
          div(class = "text-truncate",
            tags$b(n$name),
            if (is_d) span(class = "badge bg-primary ms-2", "默认"),
            div(class = "small text-muted text-truncate",
                dsapp_node_label(n),
                if (nzchar(n$workdir %||% ""))
                  sprintf(" · %s", n$workdir),
                if (!is.na(n$last_ok_at %||% NA) && nzchar(n$last_ok_at %||% ""))
                  sprintf(" · 上次连通 %s", dsapp_fmt_time(n$last_ok_at)))
          ),
          div(class = "d-flex gap-1 flex-shrink-0",
            actionButton(ns(paste0("node_load_", nid)), "载入",
                         class = "btn-sm btn-outline-primary"),
            if (!is_d)
              actionButton(ns(paste0("node_def_", nid)), NULL,
                           icon = icon("thumbtack"),
                           class = "btn-sm btn-outline-secondary",
                           title = "设为默认"),
            actionButton(ns(paste0("node_del_", nid)), NULL,
                         icon = icon("trash"),
                         class = "btn-sm btn-outline-danger",
                         title = "删除")
          )
        )
      })
    })

    # 每个节点一组按钮。
    #
    # ⚠️ 这里是本项目里唯一一处"按数据行数动态注册 observer"的地方，有个
    #    必须记住的前提：**在 observe 里创建 observer，Shiny 不会在下次重跑
    #    时销毁上一次创建的那些**。所以天真的写法（每次重渲染都 for 一遍
    #    注册）会让点一次「载入」触发 N 次 —— 节点列表每变一次就多一层，
    #    用户看到的是弹出一串重复的通知、并且真的往数据库写了 N 次。
    #
    #    做法：用 registered 记住**已经注册过哪些 id**，每个 id 只注册一次。
    #    id 用的是 SQLite 的自增主键（AUTOINCREMENT 不复用），所以删掉再新建
    #    不会撞上旧 id。已经删掉的节点留下的 observer 永远等不到它的输入，
    #    不会再触发；它们的数量上限是"这次会话里见过的节点总数"，是个位数。
    registered <- new.env(parent = emptyenv())

    observe({
      df <- nodes()
      if (is.null(df) || nrow(df) == 0) return()
      for (i in seq_len(nrow(df))) {
        nid <- as.integer(df$id[[i]])
        key <- paste0("n", nid)
        if (isTRUE(registered[[key]])) next
        registered[[key]] <- TRUE

        local({
          id <- nid
          observeEvent(input[[paste0("node_load_", id)]], {
            node <- dsapp_node_get(id, state$user_id, con = dsapp_db(cfg))
            if (is.null(node)) return()
            creds <- state$node_creds[[as.character(id)]]
            apply_node(node, creds %||% list())
            ssh_res(NULL)   # 换了机器，上一次的测试结论作废
            showNotification(
              if (is.null(creds))
                sprintf("已载入「%s」。凭据不在名册里，请补填密码/私钥后点「测试连接」。",
                        node$name)
              else sprintf("已载入「%s」（凭据取自本次会话）。", node$name),
              type = "message", duration = 8)
          })
          observeEvent(input[[paste0("node_def_", id)]], {
            dsapp_node_set_default(id, state$user_id, con = dsapp_db(cfg))
            nodes_ver(nodes_ver() + 1)
          })
          observeEvent(input[[paste0("node_del_", id)]], {
            dsapp_node_delete(id, state$user_id, con = dsapp_db(cfg))
            state$node_creds[[as.character(id)]] <- NULL
            showNotification("已删除这个节点。", type = "message", duration = 5)
            nodes_ver(nodes_ver() + 1)
          })
        })
      }
    })

    # 表单还空着的时候，用默认节点把它填上。
    #
    # **只在空的时候填**：不覆盖用户已经敲进去的东西。自动填一份配置最糟的
    # 失败方式是"把我刚改了一半的表单冲掉了"，而那时我正看着屏幕、以为它
    # 记下了我敲的内容。
    observeEvent(nodes(), {
      df <- nodes()
      if (is.null(df) || nrow(df) == 0) return()
      if (nzchar(isolate(rm_values(input))$host %||% "")) return()
      d <- dsapp_node_default(state$user_id, con = dsapp_db(cfg))
      if (is.null(d)) return()
      apply_node(d, state$node_creds[[as.character(as.integer(d$id))]] %||% list())
    }, ignoreNULL = TRUE)

    observeEvent(input$node_save, {
      r <- isolate(rm_values(input))
      nm <- trimws(input$node_name %||% "")
      if (!nzchar(nm)) {
        showNotification("先给这台机器起个名字（在「保存当前表单」左边）。",
                         type = "warning", duration = 8)
        return()
      }
      res <- dsapp_node_save(state$user_id,
                             c(r, list(name = nm, note = "")),
                             con = dsapp_db(cfg))
      showNotification(res$msg, type = if (isTRUE(res$ok)) "message" else "error",
                       duration = 8)
      if (isTRUE(res$ok)) {
        # 顺手把凭据放进会话缓存：用户刚填完就保存，紧接着载入这台机器时
        # 不该再问一遍。
        state$node_creds[[as.character(res$id)]] <-
          list(password = r$password %||% "", key_text = r$key_text %||% "")
        nodes_ver(nodes_ver() + 1)
      }
    })

    observe({
      r <- rm_values(input)
      sig <- dsapp_remote_sig(r)
      res <- ssh_res()

      r$verified <- isTRUE(res$ok) && identical(res$sig, sig)
      # 远程探测到的解释器位置，注入提示词用（见 prompts.R）
      r$bins <- res$bins %||% character()
      state$remote <- r
    })

    observeEvent(input$rm_test, {
      # isolate：handler 里读 input 会被 Shiny 记成依赖，导致"改任何一个
      # 输入框都会重跑一次连接测试"。这里要的是点击那一刻的快照。
      r <- isolate(rm_values(input))
      if (!nzchar(r$host %||% "")) {
        ssh_res(list(ok = FALSE, msg = "请先填远程主机地址"))
        return()
      }
      ssh_res(NULL)
      # 连接测试最长 60 秒（ConnectTimeout 15 + 探测命令），同样不能
      # 在 Shiny 进程里同步跑
      ssh_job(dsapp_bg_start("dsapp_ssh_test",
                             list(target = list(kind = "remote", remote = r)),
                             cfg = cfg, tag = "sshtest"))
    })

    observe({
      h <- ssh_job()
      if (is.null(h)) return()
      invalidateLater(500)

      r <- dsapp_bg_poll(h)
      if (!isTRUE(r$done)) return()

      ssh_job(NULL)
      val <- r$value %||% list()
      cur <- isolate(rm_values(input))
      ssh_res(list(ok = isTRUE(r$ok) && isTRUE(val$ok),
                   msg = if (isTRUE(r$ok)) (val$msg %||% "") else (r$msg %||% "测试失败"),
                   bins = val$bins %||% character(),
                   sig = dsapp_remote_sig(cur)))

      # 连上了才把凭据放进会话缓存、并记一次连通时间。
      # **失败不缓存**：把一份连不上的密码记下来，下次载入时它会静默填进去，
      # 用户以为已经配好了，实际是个死配置。
      if (isTRUE(r$ok) && isTRUE(val$ok)) {
        df <- tryCatch(dsapp_nodes_list(state$user_id, con = dsapp_db(cfg)),
                       error = function(e) NULL)
        if (!is.null(df) && nrow(df) > 0) {
          hit <- which(df$host == cur$host &
                       as.integer(df$port) == as.integer(cur$port) &
                       df$username == cur$user)
          if (length(hit)) {
            nid <- as.character(as.integer(df$id[[hit[[1]]]]))
            state$node_creds[[nid]] <-
              list(password = cur$password %||% "", key_text = cur$key_text %||% "")
            dsapp_node_touch_ok(as.integer(nid), state$user_id, con = dsapp_db(cfg))
            # ⚠️ 读的那一侧 isolate()：这里只是**通知**名册重画，本 observe
            #    不需要依赖 nodes_ver（它靠 ssh_job() 醒过来）。不 isolate 就
            #    是白搭一次自失效，靠下面没有别的写才没出事。
            nodes_ver(isolate(nodes_ver()) + 1)
          }
        }
      }
    })

    output$rm_test_badge <- renderUI({
      if (!is.null(ssh_job())) {
        return(span(class = "small text-muted",
                    icon("spinner", class = "fa-spin"), " 正在连接……"))
      }
      res <- ssh_res()
      if (is.null(res)) {
        return(span(class = "small text-muted", "还没测过"))
      }
      if (isTRUE(res$ok)) {
        span(class = "small text-success", icon("circle-check"), " 已连接")
      } else {
        span(class = "small text-danger", icon("circle-xmark"), " 连接失败")
      }
    })

    output$rm_test_result <- renderUI({
      res <- ssh_res()
      if (is.null(res)) return(NULL)

      if (isTRUE(res$ok)) {
        bins <- res$bins %||% character()
        return(div(class = "alert alert-success py-2 small mt-2 mb-0",
          icon("circle-check"), " ", res$msg,
          if (length(bins)) {
            div(class = "text-muted mt-1",
              "远程可用的解释器：",
              paste(sprintf("%s → %s", names(bins), unname(bins)), collapse = "；"))
          } else {
            div(class = "text-muted mt-1",
              "远程没找到 Rscript / python3。代码提交后会失败，",
              "请先在远程装好，或在上面的「激活环境的命令」里把环境加进 PATH。")
          }
        ))
      }

      div(class = "alert alert-danger py-2 small mt-2 mb-0",
        icon("circle-xmark"), " ", res$msg %||% "连接失败")
    })

    # =======================================================================
    # 跳回对话（item 3）
    # =======================================================================
    #
    # ⚠️ 原来这里还有一个把模型控件同步进 state 的 observe（vendor /
    #    api_key / base_url / temperature / max_tokens / model / thinking）。
    #    V6 整块搬去了 mod_model.R —— 那是 state 里模型字段的**唯一**写入口。
    #    别因为"这个函数里 state$api_key 被读了"就把写也加回来：两处写
    #    同一个字段，行为取决于两个模块谁先加载，界面上完全看不出来。

    # ★ V13.9 item 11：这张卡现在挂在**三个**页签的底部（见 dsapp_back_card），
    #   所以徽章要注册三个 output —— 同一个 id 在 DOM 里出现三次的话，
    #   getElementById 只拿得到第一个，另外两页那块永远是空的，且不报错。
    #
    # ⚠️ 渲染体只写一份（ready_badge_body），三个 output 都调它。抄三份的
    #    话，改一处判据（比如以后加"环境是否已就绪"）只会改到其中一个，
    #    而症状是"在「界面」页看着是灰的、到「账号」页又绿了"。
    ready_badge_body <- function() {
      key_ok <- nzchar(state$api_key %||% "")

      # 「本地电脑」模式不需要能连上的执行环境，只要模型能用就能出代码
      tgt <- state$exec_target %||% "server"
      tgt_ok <- switch(tgt,
        server = TRUE,
        local  = TRUE,   # 只是打包下载，不执行
        remote = isTRUE((state$remote %||% list())$verified),
        TRUE
      )

      item <- function(ok, yes, no) {
        div(class = if (ok) "text-success small" else "text-danger small",
            icon(if (ok) "circle-check" else "circle-xmark"), " ",
            if (ok) yes else no)
      }

      tagList(
        hr(class = "my-2"),
        item(key_ok, "模型已配置", "还没填 API Key，对话无法开始"),
        item(tgt_ok,
             sprintf("运行环境就绪：%s", dsapp_target_label(state_current_target(state))),
             if (identical(tgt, "remote"))
               "远程服务器还没测试通过，任务会失败 —— 点上面的「测试连接」"
             else "运行环境未就绪")
      )
    }

    # ★ V13.12 item 20：这里从"只注册三个徽章 output"扩成"徽章 + 按钮成对注册"。
    #
    #   按钮的 id 原来是三份共用一个 `back_to_chat`（见 dsapp_back_card 的说明），
    #   功能上通，但 Shiny 每次重新绑定都打一条 Duplicate input ID 的警告，实测
    #   跑一轮能刷 156 条 —— 排查别的问题时被它带偏过一次。现在跟着 key 分开，
    #   三个按钮就变成三个各不相同的 input，得**各自**接一条跳转。
    #
    #   ⚠️ 三份共用同一个处理函数（goto_chat），不抄三遍 —— 理由和徽章那边
    #      一模一样：抄三份的话，以后改跳转逻辑只会改到其中一个，症状是
    #      "在「界面」页点它跳得动、到「账号」页点了没反应"。
    goto_chat <- function() {
      # ⚠️ 认的是 nav_panel 的 value（"chat"），不是标题「言出法随」。
      #    标题一改这个名字就找不到了，而且不报错、只是点了没反应。
      # ⚠️ 必须走 dsapp_nav_to（顶层 session）。`session = session` 在这里
      #    是**假的修法** —— 模块的 session 是代理，会把 id 加上模块前缀，
      #    结果一样是静默失效。见 R/utils.R 的说明。
      dsapp_nav_to(state, "chat")
      if (!nzchar(state$api_key %||% "")) {
        showNotification("还没填 API Key，回到对话页后仍然无法开始生成。",
                         type = "warning", duration = 6)
      } else {
        showNotification("设置已生效，可以继续对话了。",
                         type = "message", duration = 4)
      }
    }

    for (.k in c("ui", "exec", "account")) {
      local({
        kk <- .k
        output[[paste0("ready_badge_", kk)]] <- renderUI(ready_badge_body())
        observeEvent(input[[paste0("back_to_chat_", kk)]], goto_chat())
      })
    }

    # 顶栏那个「硬件选择」栏位要显示当前选择，需要一个 state 形状的 target
    state_current_target <- function(st) {
      list(kind = st$exec_target %||% "server",
           env  = st$exec_env %||% "system",
           remote = st$remote %||% list())
    }

    # ---- 跳回对话页 ----
    #
    # 三个按钮的处理函数在**上面**那个循环里（goto_chat）—— 它和三份徽章
    # output 是成对注册的，搬回来这里就只剩一个按钮接得上了。
    # 页签 id 是 app.R 里 page_navbar(id = "nav") 定的，**没有命名空间** ——
    # 模块里要写 "nav" 而不是 ns("nav")，加了前缀会找不到。

    # =======================================================================
    # 服务器环境（只读）—— 已按 item 3 撤除
    # =======================================================================
    #
    # 这里原本有一个 output$env_info，渲染上面那张「服务器环境」表。
    # 卡片没了，渲染器也必须一起删：renderUI 挂在 output 上不会有任何
    # 报错，留着就是一段没人调用、却仍在维护的代码，下一个人会以为
    # 界面上还有这么一块表，改它、测它，全是白费。
    #
    # ⚠️ 同时提醒：`dsapp_interpreters(cfg)` 的**零参调用**（不传 env_name）
    #    在这里是取"系统解释器"的意思。item 4 之后执行链路不再接受用户的
    #    环境选择，这个函数在别处怎么调要跟着一起看，别把这里的用法当成范例。
  })
}

#' 远程配置的指纹
#'
#' 用来判断「测过的那个配置」还是不是「现在这个配置」—— 用户测完连接又
#' 改了 IP，verified 就该失效。
#'
#' 只取会影响连通性的字段，且**不包含密码/私钥原文**（只看有没有填）——
#' 指纹会被存进 ssh_res() 反复比较，没必要让凭据在其中多留一份。
#'
#' 入参是配置本身（一个 list），不是 state —— 调用方在写 state$remote 的
#' observe 里用它，去读 state 会自激。
dsapp_remote_sig <- function(r) {
  paste(r$host %||% "", r$port %||% 22, r$user %||% "",
        r$auth %||% "", nzchar(r$password %||% ""),
        nzchar(r$key_text %||% ""), sep = "|")
}
