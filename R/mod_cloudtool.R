# =============================================================================
# 云工具页（★ V15.8 item 2）—— 界面这一层
# =============================================================================
# 用户原话：「加一个云工具模块，第一个功能就是能够给这套流程的自动化分析提供
#           一个GUI，要求有流程的原理、功能介绍，让用户选好参数后可以直接运行、
#           收获结果并预览，并且能给用户提供进一步的建议」。
#
# 第一个工具是结合蛋白设计流水线（RFD3 → ProteinMPNN/SolubleMPNN → RF3 →
# 汇总）。**所有"算什么"的东西都在 R/cloudtool.R 里**（纯函数，能单独测），
# 这一份只做三件事：收控件值、把纯函数的结果画出来、把四步依次提交给执行器。
#
# -----------------------------------------------------------------------------
# ★★ 三条会让人栽跟头的约束（改这一页之前先读这三条）
# -----------------------------------------------------------------------------
#
# 1. `mod_cloudtool_ui()` **不许读 state**。整棵页面树是 `output$app_root`
#    渲染出来的（app.R），那里读一次 state，state 每变一下整个页面就重画一遍
#    —— 症状是"这一页点什么都像在闪"。所有活数据都走 server 里的
#    uiOutput/renderUI。（mod_backstage.R 顶上写着同一件事。）
#
# 2. **执行引擎是全局单槽的**（app.R 的 `dsapp_engine_new`：`e$busy` 一个标志
#    位，全应用共用）。这一页要跑四步，每一步都占着那个槽；别人（包括他自己
#    在对话页发起的执行）在这期间提交不上，会收到「已有任务正在执行」。
#    所以：
#      · 提交前先看 `engine$is_busy()`，忙就等下一拍**重试**，不报错；
#      · 界面上把"这一步在占着执行槽"说清楚（不说的话，用户会以为是卡住了）。
#    ⚠️ 这是平台的既有语义，不是这一页引入的。真要让长流水线不挡别人，得改
#       执行器的模型（多槽/排队），那是另一件事。
#
# 3. **链式推进的观察者里，读 `run_st()` 一律 `isolate()`**。
#    这个观察者每 2 秒醒一次、又要写 `run_st()`；不 isolate 的话它读自己写的
#    值 → 自己把自己失效 → 定时器瞬间烧穿（本仓栽过：reactiveVal 自己读自己
#    会自失效，症状不是卡死而是"定时器疯狂空转然后静默停掉"）。
#
# -----------------------------------------------------------------------------
# ★ 每一步都是**一个普通的平台任务**，所以这一页不另造状态
# -----------------------------------------------------------------------------
# 进度直接读任务行（`db_task_get`）+ 工作区里的 `.dsapp_stdout`（执行器写的
# 实时输出）。**不**自己维护一份"运行到哪了"的影子状态 —— 影子状态和真实执行
# 对不上时，用户看到的是"界面说在跑、其实早就死了"。
#
# 唯一落盘的是**这一步该不该开始**那点元信息（哪几步、参数是什么、每一步的
# 任务号），存在工作区的 `.dsapp_cloud/<id>.rds` 里 —— 它让"浏览器关了再回来"
# 能接着看，也是"第 3 步挂了之后只重跑第 3 步"的依据。
# =============================================================================


# =============================================================================
# 〇、两个"交给 agent"的工具，各自要发出去的那段开场白（★ V16.1 item 4）
# =============================================================================
# 用户原话：「蛋白质设计只是云工具的一部分，做成图标式二级菜单，比如再加一
#           TCGA挖掘工具、单细胞分析工具」。
#
# ★★ V16.6 item 4：这两块**已经改成和结合蛋白设计同一类东西了**。
# 用户原话：「云工具是有GUI的工具，而不是接入言出法随界面给提示词，请按新
# 逻辑制作云工具界面」。所以：
#   · 每个工具点开是**参数表单**（字段定义在 R/cloudrun.R），填完真跑；
#   · 没有执行体的工具明说「未接入执行体」，**不发任何提示词**；
#   · `cloud_go()` / `cloud_go_row()` 那条"新开对话发开场白"的路**整个删了**。
#
# ⚠️ 下面两段 `DSAPP_CLOUD_PLAN_*` 因此**没有调用方了**（原来挂在
#    `input$tcga_go` / `input$sc_go` 那两颗按钮上，按钮也删了）。
#    暂时留着：里面那些"平台特有细节"（GDC 下载清单、01A/11A 编码、
#    Seurat v4/v5 的 API 差异）将来做 GDC 下载执行体时还要用。
#    但**别再往回接** —— 接回去就是把用户否掉的那条路又装上了。
#
# ⚠️⚠️ 下面两段和面板上的文案**必须一起改**。
#     面板里写了"它会带你走 质控→聚类→注释"、发出去的却是另一套步骤，
#     用户看到的就是"说好的事没做" —— 而这种不一致不会有任何报错。
#
# ⚠️ 提示词里**不要**写"请先问我三个问题、我确认了你再开始"。用户已经明确
#    说过不要每步都确认（这条在仓库里记着）。要问的一次问清，问完就往下走。
#
# -----------------------------------------------------------------------------
# ★★ V16.4：面板上「这一套工具是什么」那部分，**不再手写**，改成现读文档
# -----------------------------------------------------------------------------
# 用户原话：「按照 skills_builtin/单细胞云平台Agent工具构建提示词.md 来优化
#           单细胞云工具；按照 TCGA数据库挖掘云平台Agent工具构建提示词.md 来
#           优化 TCGA 数据挖掘模块」。
#
# 那两份 .md 里各有一张**工具能力注册表**（sc 49 个工具 / tcga 58 个）、一套
# 流程铁律、和一组"按目标编排"的路线。这一页现在的做法是：
#   · 界面上的工具名、功能、入参、出参、KB 检索词、铁律、路线 —— 全部**现读**
#     那两份文档（R/cloudtool.R 的 DSAPP_CLOUDREG / dsapp_cloudreg*）；
#   · 点某一行 → 发一段只讲那一个工具的开场白；点某条路线 → 发那一条的编排；
#   · 文档本身作为**内置技能**挂在新建的这个对话上（按名字查 id 传过去），
#     agent 干活时就能翻到参数基线和判读规则。
#
# ⚠️ 上面那两段 `DSAPP_CLOUD_PLAN_*` 保留着，但退居**兜底**：用户说不清要走
#    哪条路线时才点。它们讲的是文档里没有的**平台特有**细节（GDC 下载清单、
#    样本类型编码 01A/11A、Seurat v4/v5 的 API 差异…），所以不是重复。
# ⚠️ 两段兜底提示词的正文仍然和面板上的文案绑在一起 —— 改一段要改两处。
#    面板上那部分动态文案（铁律/路线）反过来不受这条约束：它本来就读文档。
DSAPP_CLOUD_PLAN_TCGA <- "\
【用云工具做一次 TCGA 数据挖掘】

我要用 TCGA（GDC）的公开数据回答一个具体的问题。请你直接带我走完，不要停在\"给个方案\"。
如果下面三件事我还没说清楚，**一次性**问完就往下走，不要一步一问：
  ① 癌种 / 队列（TCGA 的哪个 project，如 TCGA-LUAD）；
  ② 要哪几个组学层（表达 / miRNA / 甲基化 / 拷贝数 / 体细胞突变 / 临床随访），有没有配对正常样本；
  ③ 想回答哪一类问题：预后生存 / 分子分型 / 肿瘤 vs 正常差异 / 免疫浸润 / 靶点关联。

对齐之后按这个顺序推进，每一步先说明\"这一步在排除什么风险\"，别只报进度：
1. 取数 —— 给出 GDC 的下载清单（文件名、大小、用途），说清哪些必须、哪些可选；不要整个 project 全量拉。
2. 质检 —— 先用一句人话讲清「原始计数 / FPKM / FPKM-UQ / 标准化矩阵」的差别和这次该用哪一种；
   核对样本类型编码（01A / 11A 这类）与临床表的对应关系，别把癌旁当肿瘤。
3. 分析 —— 按第 ③ 条选主流方法（生存用 survival + survminer，分型用 ConsensusClusterPlus 或 NMF，
   差异用 DESeq2 / edgeR，免疫浸润用 CIBERSORTx / ESTIMATE）；关键参数给出选择依据，不要随手填数字。
4. 交付 —— 用中文把结论讲清楚：拿到了什么、关键数值是多少、哪些结论成立、哪些不成立。
   ⚠️ 不得为了让结果显著而改阈值或删样本；阴性结果要保留并说明。

⚠️ 开始下载之前，先把\"预计占多少磁盘、大概跑多久\"讲清楚 —— 这句话是交代，不是等我拍板。"

DSAPP_CLOUD_PLAN_SC <- "\
【用云工具做一次单细胞分析】

请带我走完一次单细胞（或单核）转录组分析，不要停在\"给个方案\"。
如果下面三件事我还没说清楚，**一次性**问完就往下走，不要一步一问：
  ① 数据在哪：我这个工作区里的路径，还是公开数据（GEO / 10x 官网）；是 filtered 矩阵、raw 矩阵还是 h5ad；
  ② 物种、组织，以及有没有多个样本 / 批次（这决定了要不要整合）；
  ③ 这次最想回答的问题（分群注释 / 组间差异 / 轨迹 / 细胞通讯 / 转录因子），不必把所有分析都做一遍。

对齐之后按这个顺序推进，每一步先说明\"这一步在排除什么风险\"：
1. 体检数据 —— 读进来之前先看文件结构：哪个版本、是不是稀疏矩阵、barcode 与 feature 对不对得上。
2. 质控 —— 线粒体比例、nFeature/nCount 的双峰、双细胞（scDblFinder / DoubletFinder）、红细胞与核糖体基因；
   阈值要给出**这一批数据**的依据，不要照抄网上的\"5% / 200–2500\"。
3. 主流程 —— 归一化 → 高变基因 → PCA → 整合（多批次必须做，Harmony 或 Seurat 的 CCA/RPCA）→
   聚类（resolution 怎么选的要说出来）→ UMAP。
4. 注释 —— 用 SingleR / CellTypist 打底，再逐群核对 marker；**区分细胞数量与生物学重复**，3 个细胞不等于 3 个重复。
5. 下游 —— 按第 ③ 条做。
6. 交付 —— 用中文把结论讲清楚：拿到了什么、关键数值是多少、哪些结论成立、哪些不成立。
   ⚠️「聚类分离 ≠ 细胞类型不同」，写结论时守住这条。

⚠️ Seurat v4 与 v5 的 API 差别很大，动手前先确认环境里是哪一版；随机种子要显式设置（set.seed / random_state）；
不得编造数值或结果。"


# =============================================================================
# 一、界面
# =============================================================================

mod_cloudtool_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "dsapp-page",

      # ------------------------------------------------- 工具（图标式二级菜单）
      # ★ V16.1 item 4。三个方块，点哪个显示哪块面板。
      #
      # ⚠️⚠️ 切面板**走前端 class 开关，不经过服务端**（www/app.js 里
      #     `dsapp:cloud-tile` 那一段）。理由有两条，第二条是关键：
      #       1) 服务端切面板 = renderUI 重画 = 每点一次都要一个来回；
      #       2) 更要命的是**重画会把参数表单连同用户填的值一起铲掉**
      #          （这页有十几个控件）。用户填了一半去隔壁看一眼再回来，
      #          参数全没了 —— 那比不能切还难受。
      #     三个面板**始终在 DOM 里**，只是 display:none 切换，所以控件和
      #     它们已经填好的值一直活着。
      #
      # ⚠️ 这里**没有**用 bslib 的 navset_tab，也**没有**用 Bootstrap 的
      #    data-bs-toggle="tab"：本仓库的页签体系跟 bootstrap 的 tab 绑定
      #    纠缠得很深（app.R 顶上那四十行写的就是它怎么把左栏点瘫的）。
      #    为了一个页面内的装饰性切换去动那套绑定不划算。
      div(class = "dsapp-cloud-pick",
        div(class = "dsapp-cloud-hint", "云工具 · 选一个开始"),
        div(class = "dsapp-cloud-grid",

          tags$button(type = "button", class = "dsapp-cloud-tile is-active",
            `data-tool` = "design",
            div(class = "dsapp-cloud-ico", icon("dna")),
            div(class = "dsapp-cloud-name", "结合蛋白设计"),
            div(class = "dsapp-cloud-desc",
              "RFdiffusion3 → ProteinMPNN → RF3 的完整流水线，填好参数直接在这台机器上跑"),
            div(class = "dsapp-cloud-tag", "本机计算")
          ),

          tags$button(type = "button", class = "dsapp-cloud-tile",
            `data-tool` = "tcga",
            div(class = "dsapp-cloud-ico", icon("database")),
            div(class = "dsapp-cloud-name", "TCGA 数据挖掘"),
            div(class = "dsapp-cloud-desc",
              "表达矩阵整理、差异表达、KM 生存、单因素 Cox —— 填参数就能跑"),
            div(class = "dsapp-cloud-tag", "本机计算")
          ),

          tags$button(type = "button", class = "dsapp-cloud-tile",
            `data-tool` = "sc",
            div(class = "dsapp-cloud-ico", icon("microscope")),
            div(class = "dsapp-cloud-name", "单细胞分析"),
            div(class = "dsapp-cloud-desc",
              "读入 → 质控 → HVG/PCA → 聚类 → marker → 组间差异，六步都能单独跑"),
            div(class = "dsapp-cloud-tag", "本机计算")
          )
        )
      ),

      # ================================================== 面板一：结合蛋白设计
      div(class = "dsapp-cloud-panel is-active", `data-panel` = "design",

      # ---------------------------------------------------------------- 原理
      card(
        card_header(icon("cloud"), " 云工具 · 结合蛋白设计流水线"),
        card_body(
          class = "py-2",
          p(class = "mb-2",
            "这里跑的是", tags$b("结合蛋白（binder）设计"), "那条被广泛使用的",
            "自动化路线：先用扩散模型在靶点表面的指定位置", tags$b("生成骨架"),
            "，再给每个骨架", tags$b("设计氨基酸序列"),
            "，然后把设计好的序列", tags$b("重新折叠一遍"),
            "，最后把两边的结构叠在一起算指标。",
            "整个过程不需要你写命令 —— 填好参数点「开始运行」，",
            "后面的四步会依次提交、逐步推进。"),

          # 四步分工。写的是"这一步为什么存在"，不是把教学原文抄一遍：
          # 用户要判断"卡在哪一步该怪什么"，靠的正是这几句话。
          tags$ol(class = "mb-3",
            tags$li(tags$b("生成骨架（RFdiffusion3）"),
              " —— 按 contig 描述的形状，在靶点表面生成若干个 binder 骨架。",
              "这一步只出「骨架」（多肽主链），还没有序列。"),
            tags$li(tags$b("设计序列（ProteinMPNN / SolubleMPNN）"),
              " —— 给每个骨架设计出能折叠成这个形状的氨基酸序列。",
              "两套权重各有偏好，一般两个都跑，各出一批候选。"),
            tags$li(tags$b("复折叠（RoseTTAFold3）"),
              " —— 把设计出的序列重新预测一次复合物结构，",
              "这一步产生的 ipae / ipTM / pLDDT 才是判断依据。"),
            tags$li(tags$b("汇总指标"),
              " —— 把上面那步的预测和骨架对齐，算出每个候选的",
              "界面误差（ipae）、双向 ipae、RMSD、ipTM、pLDDT，写成 CSV。")
          ),

          # 判读口径。这一段**必须**和数字一起显示：只给分数线、
          # 不给"它只是观察线"这句话，用户会把它当录取线用。
          div(class = "alert alert-secondary py-2 mb-2",
            tags$b("怎么看结果"),
            tags$ul(class = "mb-0 mt-1",
              tags$li(tags$b("ipae"), "（界面预测误差，Å）：两条链的相对位置有多不",
                "确定，", tags$b("越低越好"), "。一般先看 10 Å 这条线 ——",
                "注意它只是", tags$b("观察线"), "，不是已经验证过的实验成功阈值。"),
              tags$li(tags$b("ipTM"), "：界面姿态的置信度，",
                "> 0.8 高、0.6–0.8 不确定、< 0.6 缺少强支持。",
                "这是 AlphaFold 的通用参考区间，", tags$b("不能当 RF3 已验证的门槛"),
                "。"),
              tags$li(tags$b("binder pLDDT"), "：binder 自己折叠得好不好，",
                "> 90 很好、70–90 可以、50–70 低、< 50 很差。"),
              tags$li("三样要", tags$b("一起看"), "，别拿单独一个分数下结论。")
            )
          ),

          p(class = "text-muted small mb-0",
            "⚠️ 计算上的两件事：", tags$b("第一，"),
            "这套流程必须用 GPU，平台按账号放行（「设置 → 硬件选择」）；",
            tags$b("第二，"),
            "平台一次执行有墙钟上限，所以这四步是", tags$b("拆成四个任务"),
            "依次跑的 —— 第 3 步带续跑（已经算完的不会重算），",
            "而第 1 步没有，被打断就得从头再来。体检里会按你的参数把预计耗时算给你。")
        )
      ),

      # ---------------------------------------------------------------- 参数
      card(
        card_header(icon("sliders"), " 参数"),
        card_body(
          class = "py-2",
          uiOutput(ns("no_ws_hint")),
          uiOutput(ns("preflight_box")),
          uiOutput(ns("form_box"))
        )
      ),

      # ---------------------------------------------------------------- 运行
      card(
        card_header(icon("play"), " 运行"),
        card_body(
          class = "py-2",
          uiOutput(ns("run_box")),
          uiOutput(ns("live_box"))
        )
      ),

      # ---------------------------------------------------------------- 结果
      card(
        card_header(icon("table-list"), " 结果与建议"),
        card_body(
          class = "py-2",
          uiOutput(ns("result_note")),
          DT::DTOutput(ns("metrics")),
          uiOutput(ns("artifacts"))
        )
      ),

      # ----------------------------------------------------- 这个工作区跑过的
      card(
        card_header(icon("clock-rotate-left"), " 这个对话跑过的"),
        card_body(class = "py-2", uiOutput(ns("runs_box")))
      )

      ),  # ← /面板一（结合蛋白设计）

      # ================================================== 面板二：TCGA 数据挖掘
      div(class = "dsapp-cloud-panel dsapp-cloud-hidden", `data-panel` = "tcga",
        card(
          card_header(icon("database"), " 云工具 · TCGA 数据挖掘"),
          card_body(
            class = "py-2",
            # ★ V16.6 item 4：这一段原来是「点按钮 → 新开对话发提示词」。
            #   用户明确否掉了那条路，现在是**每个工具有自己的参数表单**。
            p(class = "mb-2",
              "这一页的工具都", tags$b("有参数表单"), "：在下面的清单里点一行，",
              "在它上面的「工具工作台」里填参数、点运行，产物落在当前对话的",
              "工作区里（「文件」页能看到、能下载）。",
              "没接执行体的工具会明说，", tags$b("不会"), "偷偷把提示词发给谁。"),

            # ★ V16.4 item 2：工具数 / 流程铁律 / 按目标编排的 7 条路线 ——
            #   全部现读 skills_builtin/ 下那份 TCGA 文档，R 这边不抄。
            uiOutput(ns("tcga_plan_area")),

            p(class = "text-muted small mb-0",
              "⚠️ 文档里 GDC 下载那一类工具（要联网、要几十 GB、要先挑队列和",
              "组学层）", tags$b("本版还没有接入执行体"), "—— 点开它会如实告诉你。")
          )
        ),

        # ============================================ 工具工作台（★ V16.6 item 4）
        # ⚠️ 它必须**独立成一个 output**，不能和工具清单共用一个 renderUI：
        #    清单那个跟着搜索框每敲一个字就重画一次，参数表单要是挂在里面，
        #    用户填到一半就被重建、焦点当场丢掉（本仓在"搜索框自己失效自己"
        #    那条注释里记过同样的账）。
        card(
          card_header(icon("sliders"), " 工具工作台"),
          card_body(class = "py-2", uiOutput(ns("tcga_workbench")))
        ),

        card(
          card_header(icon("list"), " 工具清单 · 点一个，让它只做这一件事"),
          card_body(
            class = "py-2",
            # ⚠️ 这两个控件**必须**留在静态 UI 里，不能塞进下面那个 renderUI：
            #    搜索框自己被自己失效的话，用户每敲一个字都重建一次输入框，
            #    焦点当场丢掉（打第二个字就没了）。组下拉另走一个只读文档、
            #    不含任何 input 依赖的 renderUI —— 它只渲染一次。
            div(class = "dsapp-cloud-filters",
              uiOutput(ns("tcga_groupsel")),
              textInput(ns("tcga_q"), "关键词",
                        placeholder = "工具名 / 功能 / 入参 / 出参（survival、CIBERSORT、LASSO…）")),
            uiOutput(ns("tcga_rows")))
        )
      ),

      # ================================================== 面板三：单细胞分析
      div(class = "dsapp-cloud-panel dsapp-cloud-hidden", `data-panel` = "sc",
        card(
          card_header(icon("microscope"), " 云工具 · 单细胞分析"),
          card_body(
            class = "py-2",
            p(class = "mb-2",
              "这一页的工具都", tags$b("有参数表单"), "：在下面的清单里点一行，",
              "在它上面的「工具工作台」里填参数、点运行。",
              "六步连起来就是一条完整链路 —— 读入 → 质控 → 标准化/HVG →",
              "降维聚类 → marker → 组间差异，", tags$b("每一步都能单独重跑"),
              "（改个阈值不用从头再来）。"),

            # ★ V16.4 item 1：同上，现读单细胞那份文档（49 个工具 / 8 条路线）。
            uiOutput(ns("sc_plan_area")),

            p(class = "text-muted small mb-0",
              "⚠️ 数据可以是", tags$b("你已经传进工作区的"),
              "（10x 三文件目录 / .h5 / .h5ad / csv 都认），也可以是公开数据",
              "（GEO / 10x 官网，先下到工作区）。",
              "路径里的空格、中文、`$` 都不会出问题 —— 参数是当数据传进脚本的。")
          )
        ),

        # ============================================ 工具工作台（★ V16.6 item 4）
        card(
          card_header(icon("sliders"), " 工具工作台"),
          card_body(class = "py-2", uiOutput(ns("sc_workbench")))
        ),

        card(
          card_header(icon("list"), " 工具清单 · 点一个，让它只做这一件事"),
          card_body(
            class = "py-2",
            div(class = "dsapp-cloud-filters",
              uiOutput(ns("sc_groupsel")),
              textInput(ns("sc_q"), "关键词",
                        placeholder = "工具名 / 功能 / 入参 / 出参（Harmony、SingleR、monocle…）")),
            uiOutput(ns("sc_rows")))
        )
      )
    )
  )
}


# =============================================================================
# 三、注册表那几块的画法（★ V16.4 item 1 / item 2）
# =============================================================================
# 面板二和面板三共用这一份 —— 两处唯一的差别是 kind（"tcga" / "sc"）。
#
# ★ 为什么这些是**函数**而不是把 HTML 直接写进 mod_cloudtool_ui()：
#   面板本身是静态的（那三条 ⚠️ 见文件头），但工具清单要看文档才知道有多少
#   行。所以静态壳里放 uiOutput，内容在服务端现算 —— 这一层只负责"把结构
#   摆成什么样子"，取数全在 R/cloudtool.R 里。
#
# ⚠️ 每一行的 `data-kind` / `data-key` / `data-plan` 是给前端那一个事件委托
#    读的（www/app.js 的 `.dsapp-cloud-go` 那一段），R 这边**不为每个工具
#    注册一个 observeEvent** ——49+58 个观察者既费内存，又要在文档加一行工具
#    时跟着改。一个 input 收所有点击，靠 data 属性区分。
# =============================================================================

#' 一行工具
#'
#' ★ V16.6 item 4：这一行现在分两种，**按"有没有执行体"分**：
#'   接了执行体的 → 点下去在下面开参数表单，填完真跑，出产物；
#'   没接的       → 点下去只把文档里那几行原样摊开，明说「未接入执行体」，
#'                  **不发任何提示词**（用户原话：「云工具是有GUI的工具，
#'                  而不是接入言出法随界面给提示词」）。
#'
#' ⚠️ 两种都照样带 `dsapp-cloud-go` + `data-kind`/`data-key`：前端那一个事件
#'    委托（www/app.js 的 `.dsapp-cloud-go` 那段）**不用改**，服务端按同一个
#'    `input$tool_go` 分流。少改一处前端 = 少一处"点了没反应"的机会。
mod_cloudtool_tool_row <- function(kind, key, fn, inputs, outputs, kb) {
  s <- function(x) { x <- as.character(x %||% ""); if (is.na(x)) "" else x }
  has <- !is.null(tryCatch(dsapp_cloudx_get(kind, key), error = function(e) NULL))
  div(class = "dsapp-cloud-tool",
    div(class = "dsapp-cloud-tool-hd",
      tags$code(class = "dsapp-cloud-tool-key", s(key)),
      tags$span(class = "dsapp-cloud-tool-fn", s(fn)),
      if (has) tags$span(class = "badge text-bg-success ms-2", "可运行")
      else     tags$span(class = "badge text-bg-secondary ms-2", "未接入执行体")),
    div(class = "dsapp-cloud-tool-meta",
      if (nzchar(s(inputs)))  div(tags$b("入参 "), s(inputs)),
      if (nzchar(s(outputs))) div(tags$b("出参 "), s(outputs)),
      if (nzchar(s(kb)))      div(tags$b("KB "), tags$code(s(kb)))),
    tags$button(type = "button", class = "dsapp-cloud-go dsapp-cloud-row-btn",
      `data-kind` = kind, `data-key` = s(key),
      if (has) "配置并运行" else "看看它要什么")
  )
}

#' 工具数 / 流程铁律 / 按目标编排那几条路线
#'
#' ⚠️ 这个 renderUI **不读任何 input**，所以它只渲染一次。路线按钮是死的，
#'    点了走前端委托那一条（见文件头）。
#' ⚠️ 读不到文档时**不抛错**，画一条警告就把位置让出来：这一页整个挂掉的
#'    话，用户看到的是"云工具页打不开"，真正的原因（文件被删了、权限不对）
#'    一个字都看不到。
mod_cloudtool_plan_area <- function(kind, ns) {
  r <- dsapp_cloudreg(kind)
  if (!isTRUE(r$ok)) {
    return(div(class = "alert alert-warning py-2 mb-2",
      tags$b("读不到工具文档"), "「", r$doc, "」：", r$msg,
      "。下面的按钮仍然可用，但这一页列不出工具。"))
  }
  routes <- r$routes$items
  tagList(
    div(class = "alert alert-secondary py-2 mb-2",
      tags$b(sprintf("这份文档注册了 %d 个工具、分 %d 个组", r$n, length(r$groups))),
      if (nzchar(r$chain))
        div(class = "dsapp-cloud-chain",
            tags$b("流程铁律（不跳步、不乱序）："), r$chain),
      if (length(r$rules))
        tags$ul(class = "mb-0 mt-1", lapply(r$rules, function(x) tags$li(x)))
    ),
    # ★ V16.6 item 4：这几条路线**不再带按钮**了。
    #   以前点一条 = 新开对话 + 把这套流程当提示词发出去，那正是用户否掉的
    #   那条路。路线本身是有用的（它说明这些工具该怎么排先后），所以留着当
    #   **文档**；真要跑，就在下面的工具清单里一个个点、一个个填参数。
    if (length(routes)) tagList(
      div(class = "dsapp-cloud-hint",
          sprintf("按目标编排 · 文档给了 %d 条路线（只作参考：下面每个工具都能单独跑）",
                  length(routes))),
      div(class = "dsapp-cloud-routes",
        lapply(seq_along(routes), function(i) {
          it <- routes[[i]]
          div(class = "dsapp-cloud-route",
            div(class = "dsapp-cloud-route-btn", it$label),
            div(class = "dsapp-cloud-route-txt", it$text))
        })
      )
    )
  )
}

#' 组筛选下拉（只读文档，不含 input 依赖 → 只渲染一次）
mod_cloudtool_group_sel <- function(kind, input_id) {
  r <- dsapp_cloudreg(kind)
  ch <- c("全部（按组看）" = "all")
  for (g in r$groups) {
    ch[[sprintf("%s. %s", g$letter, g$title)]] <- g$letter
  }
  selectInput(input_id, "按组筛选", choices = ch, selected = "all", width = "100%")
}


# =============================================================================
# 二、服务端
# =============================================================================

mod_cloudtool_server <- function(id, state, engine) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ⚠️ `cfg` 是**函数**不是值 —— 理由见 mod_files.R 顶上那段（模块在登录前
    #    就注册好了，那时 state$user_id 还不存在）。用的时候现算。
    cfg <- function() dsapp_config_user(state$user_id, dsapp_config())

    # =========================================================================
    # 云工具的执行体（★ V16.6 item 4）
    # =========================================================================
    # 用户原话：「云工具是有GUI的工具，而不是接入言出法随界面给提示词，
    # 请按新逻辑制作云工具界面」。
    #
    # V16.1~V16.4 那一版是"点一行 → 新开一个对话 → 把一段写好的开场白发
    # 给 agent"（`cloud_go()` / `cloud_go_row()` / `input$tcga_go` …）。
    # **那一段整个删掉了** —— 它和"有 GUI 的工具"是两件事，留着就是两套并存的
    # 真相。参数表单、脚本、产物都在 R/cloudrun.R 里（那一份是纯函数层，
    # 界面这边只管把字段画出来、把值收回来、把任务提交出去）。
    #
    # 一次只跑一个工具（不是面板一那种四步流水线），所以状态就一个小 list，
    # 不需要 cloudtool.R 里那套 steps 存档。
    # =========================================================================
    sel       <- reactiveVal(NULL)   # 选中的工具：list(kind, key)
    tool_st   <- reactiveVal(NULL)   # 这次运行：list(kind, key, root, tid, …)

    # ---- 点一行工具 ---------------------------------------------------------
    # ⚠️ 只有一个 input 收**所有**行的点击，靠 data-kind / data-key 区分
    #    （前端那一个事件委托，见 www/app.js）。文档里加一个工具不用动 R。
    # ⚠️ kind / key 都是浏览器发来的字符串，落进任何地方之前都要自己收一次：
    #    对不上就当没点（**不报错** —— 用户点一下不该看到红字）。
    observeEvent(input$tool_go, {
      m  <- input$tool_go
      k  <- tryCatch(dsapp_cloudreg_kind(m$kind), error = function(e) "")
      ky <- trimws(as.character(m$key %||% "")[1])
      if (!nzchar(k) || is.na(ky) || !nzchar(ky)) return(invisible(NULL))
      sel(list(kind = k, key = ky))
      invisible(NULL)
    }, ignoreInit = TRUE)

    # 上传框旁边那句小字。**在 tool_bench 外面算好**成一个纯字符串：
    # `dsapp_config()` 不是 reactive（每次现算一个 list），所以这里读它
    # 不会给工具表单添任何依赖。上限本身是**整个请求体**的上限
    # （app.R 里的 options(shiny.maxRequestSize)），不是单个文件的上限 ——
    # 一次点多几个文件也会撞上它，文案按「单个文件」说是因为那才是常见死法。
    up_hint <- sprintf("单个文件上限 %s",
                       dsapp_fmt_bytes(dsapp_config()$max_upload_mb * 1024^2))

    # ---- 工作台：选中的那个工具（参数表单 / 或"未接入执行体"）----------------
    #
    # ⚠️ 这一个 output **只**依赖 sel() —— 绝不能顺手读 input$x_*：那等于
    #    "用户每敲一个字就重建一次整个表单"，焦点当场丢掉（打字打到第二个
    #    字符就没了）。这一条在本仓记过两次账（搜索框那次、还有 mod_* 里
    #    那些"读 input 的 renderUI"）。
    tool_bench <- function(k) {
      s <- sel()
      if (is.null(s) || !identical(s$kind, k)) {
        return(div(class = "text-muted small",
          "还没有选工具。在下面的清单里点一行", tags$b("「配置并运行」"),
          "，参数表单会出现在这里。"))
      }
      spec <- dsapp_cloudx_get(s$kind, s$key)
      tl   <- tryCatch(dsapp_cloudreg_find(s$kind, s$key),
                       error = function(e) NULL)
      fn   <- as.character(tl$fn %||% "")[1]
      head <- h6(class = "mb-2",
                 tags$code(s$key),
                 if (nzchar(fn)) tags$span(class = "text-muted", " · ", fn))

      # ---- (a) 没接执行体：把文档原样摊开，明说不能跑 --------------------
      if (is.null(spec)) {
        return(tagList(
          head,
          div(class = "alert alert-warning py-2 mb-2",
            tags$b("未接入执行体。"),
            "这个工具在文档里注册了，但平台这边还没有对应它的可执行脚本 ——",
            "所以它", tags$b("不会跑任何东西"), "，也",
            tags$b("不会把提示词发给谁"), "。",
            "下面几行是文档里原样写的，供你判断它要什么、出什么。"),
          if (!is.null(tl)) tags$ul(class = "small mb-0",
            if (nzchar(fn))                    tags$li(tags$b("功能 "), fn),
            if (nzchar(as.character(tl$inputs %||% "")[1]))
              tags$li(tags$b("入参 "), as.character(tl$inputs)[1]),
            if (nzchar(as.character(tl$outputs %||% "")[1]))
              tags$li(tags$b("出参 "), as.character(tl$outputs)[1]),
            if (nzchar(as.character(tl$kb %||% "")[1]))
              tags$li(tags$b("KB "), tags$code(as.character(tl$kb)[1]))),
          div(class = "text-muted small mt-2",
            "要跑这一类分析，目前请到「对话」页自己说清楚要做什么。")
        ))
      }

      # ---- (b) 有执行体：参数表单 + 运行 ---------------------------------
      w    <- ws()
      opts <- dsapp_cloudx_file_choices(w, spec)
      tagList(
        head,
        p(class = "small text-muted mb-2", spec$about),
        div(class = "dsapp-cloud-form",
          # `up_hint` 是**纯字符串**，在下面按 dsapp_config() 算好 ——
          # ⚠️ 别在这里现读 cfg()：这个 output 的依赖集合必须只有 sel() 和
          #    ws()，多一个就是"用户每敲一个字表单被重建"（见上面那段 ⚠️）。
          lapply(spec$fields,
                 function(f) dsapp_cloudx_field(ns, f, opts, hint = up_hint))),
        div(class = "small text-muted mb-2",
          "产物：", paste(spec$outputs, collapse = " · "),
          if (is.null(w))
            tagList(br(), tags$b(class = "text-danger",
              "当前没有打开的对话 —— 产物要落在对话的工作区里，先去「对话」页开一个。")))
        ,
        actionButton(ns("tool_start"), "开始运行",
                     class = "btn-primary btn-sm", icon = icon("play")),
        # ⚠️ 这一个 id 必须是**按 kind 拼出来的**（`tcga_tool_status` /
        #    `sc_tool_status`）—— 两个面板各有一个工作台，共用一个 id 的话
        #    两块面板会抢同一个 output（后定义的那个赢），而症状是"另一个
        #    面板的日志不显示"，看不出跟 id 撞了有关。
        uiOutput(ns(paste0(k, "_tool_status")))
      )
    }
    output$tcga_workbench <- renderUI(tool_bench("tcga"))
    output$sc_workbench   <- renderUI(tool_bench("sc"))

    # ---- 提交这一次运行 -----------------------------------------------------
    observeEvent(input$tool_start, {
      s <- sel()
      if (is.null(s)) return(invisible(NULL))
      spec <- dsapp_cloudx_get(s$kind, s$key)
      if (is.null(spec)) return(invisible(NULL))
      w <- ws()
      if (is.null(w)) {
        showNotification("先打开一个对话 —— 产物要落在对话的工作区里。",
                         type = "error", duration = NULL)
        return(invisible(NULL))
      }
      vals <- dsapp_cloudx_collect(spec, input)
      b <- tryCatch(dsapp_cloudx_build(s$kind, s$key, vals, w, cfg()),
                    error = function(e)
                      list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(b$ok)) {
        showNotification(paste0("还不能跑：", b$msg %||% "未知原因"),
                         type = "error", duration = NULL)
        return(invisible(NULL))
      }
      # ⚠️ 忙的时候**不排队**，直接告诉用户等一会儿：这里的"排队"要做就得
      #    自己实现一个队列，而面板一那套链式推进已经占了"提交失败就下一拍
      #    重试"这个位置 —— 两套排队机制叠在一起，出问题时的症状是
      #    "点了没反应"，最难查。宁可让用户手点第二次。
      if (engine$is_busy()) {
        showNotification(
          "执行槽正忙（平台同一时刻只跑一个任务）。等它跑完再点一次。",
          type = "warning", duration = 8)
        return(invisible(NULL))
      }
      # 把生成的那份脚本**落到产物目录里**再提交：这样用户能自己打开看
      # "这个工具到底对我做了什么"，也能过两天回来重跑（`bash run.sh`）。
      writeLines(b$code, file.path(b$root, "run.sh"))
      r <- engine$start(
        code = b$code, lang = "Bash",
        title = sprintf("云工具 · %s · %s",
                        DSAPP_CLOUDREG[[s$kind]]$label, s$key),
        session_id = state$chat_session_id %||% NA_character_,
        target = list(kind = "server", env = "system"),
        user_id = state$user_id)
      if (!isTRUE(r$ok)) {
        showNotification(paste0("提交失败：", r$msg %||% "未知原因"),
                         type = "error", duration = NULL)
        return(invisible(NULL))
      }
      tool_st(list(kind = s$kind, key = s$key, root = b$root,
                   tid = r$task_id, status = "running",
                   note = "已提交，正在排队/运行", t0 = dsapp_now()))
      showNotification("已经提交。跑完这里会自动变成结果，日志实时更新。",
                       type = "message", duration = 5)
      invisible(NULL)
    }, ignoreInit = TRUE)

    # =========================================================================
    # ---- 上传数据（★ V16.7 item 4）-----------------------------------------
    # =========================================================================
    # 用户原话：「单细胞云工具里需要支持上传数据来进行分析」。
    #
    # 每个文件字段旁边有两个框（见 dsapp_cloudx_field）：一个普通框选**文件**、
    # 一个 .dsapp-dirupload 框选**文件夹**（10x 数据天然是三文件目录）。
    # 处理完：落「文件」页那个上传区 → 登记归属 → 挂进当前对话工作区
    # → 把下拉的候选刷成新的、并自动选中刚传的那个。
    #
    # ⚠️ 刷新走 **updateSelectInput / updateTextInput**，**不重建** tool_bench：
    #    那个 output 多一个响应式依赖就会"用户每敲一个字表单被重建、焦点丢失"。
    #
    # ⚠️ 观察者是**按注册表生成**的（dsapp_cloudx_file_ids()）：今天有
    #    input / expr / types / clin 四个 id，硬编码的话下次谁加一个字段，
    #    那个字段就静默没有上传框。
    accept_upload <- function(fid, up, paths) {
      s <- sel()
      spec <- if (is.null(s)) NULL else dsapp_cloudx_get(s$kind, s$key)
      fld  <- if (is.null(spec)) NULL else
        Find(function(x) identical(x$id, fid), spec$fields)
      # mode 必须**现查**：同一个 `input` 在 sc_read_data 是 "any"、
      # 在 tcga_expression 是默认的 "file"，按 fid 缓存会张冠李戴。
      mode <- as.character((fld$mode %||% "file"))[1]

      r <- dsapp_cloudx_upload_apply(
        up, cfg(), user_id = state$user_id, ws = ws(), rels = paths,
        mode = mode, con = dsapp_db(cfg()))

      dsapp_audit("file_upload", user = state$user, user_id = state$user_id,
                  target = paste0("cloudtool/", fid),
                  detail = sprintf("%s；%s", r$msg,
                                   paste(utils::head(r$saved, 20), collapse = ", ")),
                  ok = isTRUE(r$ok), session = session, cfg = cfg())

      if (nzchar(r$msg)) {
        showNotification(r$msg, type = if (isTRUE(r$ok)) "message" else "error",
                         duration = if (isTRUE(r$ok)) 5 else NULL)
      }
      if (length(r$failed)) {
        showNotification(paste0("没成的：", paste(r$failed, collapse = "；")),
                         type = "error", duration = NULL)
      }

      # 只有**确实有文件成功落盘**时才动下拉 —— 一个都没成还去刷新，会把
      # 用户已经选好的值冲掉。
      if (isTRUE(r$ok)) {
        ch  <- dsapp_cloudx_choices(dsapp_cloudx_file_choices(ws()))
        sel_v <- r$select
        # ⚠️ `selected` 必须落在 `choices` 里：selectize 的 addItem 第一句是
        #    `if (!self.options.hasOwnProperty(value)) return;` —— 不在候选里
        #    时控件被清空后什么都不加，input$x_<fid> 静默变成 ""，要等到点
        #    「开始运行」才报"还没选"。宁可退回手填那条路。
        if (nzchar(sel_v) && sel_v %in% names(ch)) {
          # ⚠️ id 一律**裸写**：模块 session 的 sendInputMessage 自己会加
          #    前缀，包了 ns() 就变成 cloudtool-cloudtool-x_* —— 消息发到一个
          #    不存在的 id，只在 console 留一句错，界面上完全没反应。
          updateSelectInput(session, paste0("x_", fid),
                            choices = ch, selected = sel_v)
          updateTextInput(session, paste0("x_", fid, "_manual"), value = "")
        } else if (nzchar(sel_v)) {
          updateSelectInput(session, paste0("x_", fid),
                            choices = ch, selected = "__manual__")
          updateTextInput(session, paste0("x_", fid, "_manual"), value = sel_v)
        }
      }

      # 输入框复位：不重置的话连传**同名**文件第二次，浏览器认为没变化、
      # change 不触发，"点了上传没反应"（mod_files.R 里记过这条）。
      session$sendCustomMessage("dsapp:resetUpload",
                                list(id = ns(paste0("x_", fid, "_up"))))
      session$sendCustomMessage("dsapp:resetUpload",
                                list(id = ns(paste0("x_", fid, "_dir"))))
      invisible(NULL)
    }

    # ⚠️ `local()` 不能省：不 force 住 fid，循环变量是**懒求值**的，于是所有
    #    观察者都指到最后一个 id —— 症状是"给「表达矩阵」传文件，「分组表」
    #    的下拉变了"。纯闭包陷阱，没有任何警告。
    for (.fid in dsapp_cloudx_file_ids()) local({
      fid <- .fid
      observeEvent(input[[paste0("x_", fid, "_up")]],
                   accept_upload(fid, input[[paste0("x_", fid, "_up")]], NULL),
                   ignoreNULL = TRUE, ignoreInit = TRUE)
      observeEvent(input[[paste0("x_", fid, "_dir")]],
                   accept_upload(fid, input[[paste0("x_", fid, "_dir")]],
                                 input[[paste0("x_", fid, "_dirpaths")]]),
                   ignoreNULL = TRUE, ignoreInit = TRUE)
    })

    # ---- 盯着这一个任务 -----------------------------------------------------
    # ⚠️ `invalidateLater` **无条件**排在最前面（本仓栽过：条件式注册会让这个
    #    观察者在那条分支上再也不会醒）。空闲时也每 2 秒醒一次 —— 代价是一次
    #    内存里的 reactiveVal 比较，可以忽略。
    # ⚠️ 读 tool_st() 一律 isolate()：这个观察者自己会写它，不隔离就是自失效
    #    （本仓在 reactiveVal 那条账里记过：症状是"定时器瞬间烧穿然后静默停掉"）。
    observe({
      invalidateLater(2000)
      st <- isolate(tool_st())
      if (is.null(st) || !identical(st$status, "running")) return()
      row <- tryCatch(db_task_get(st$tid, con = dsapp_db(cfg())),
                      error = function(e) NULL)
      if (is.null(row)) {
        st$status <- "gone"
        st$note   <- "任务行不见了（可能被删了）"
        tool_st(st); return()
      }
      if (identical(as.character(row$status), "running") ||
          identical(as.character(row$status), "pending")) return()
      st$status <- if (identical(as.character(row$status), "success"))
        "done" else "failed"
      st$exit <- row$exit_code
      st$t1   <- dsapp_now()
      st$note <- if (identical(st$status, "done")) "跑完了"
                 else sprintf("没跑成（%s，退出码 %s）",
                              as.character(row$status),
                              as.character(row$exit_code %||% "?"))
      tool_st(st)
      showNotification(
        if (identical(st$status, "done")) "云工具：跑完了，产物在下面。"
        else "云工具：这一步没跑成，看下面的日志。",
        type = if (identical(st$status, "done")) "message" else "error",
        duration = if (identical(st$status, "done")) 6 else NULL)
    })

    # ---- 运行状态 + 日志 + 产物 ---------------------------------------------
    #
    # ⚠️ 这一个**独立于** tool_bench：它每 2 秒重画一次（日志在长），要是和
    #    参数表单挂在同一个 renderUI 里，用户填到一半就被重建了。
    tool_status_box <- function(k) {
      st <- tool_st()
      if (is.null(st) || !identical(st$kind, k)) return(NULL)
      running <- identical(st$status, "running")
      # 跑着的时候画快一点（日志在长），跑完就停 —— 不让一个每秒重画的
      # 元素一直挂在那儿烧 CPU。
      if (running) invalidateLater(2000)
      log <- tryCatch(dsapp_tail(file.path(st$root, "run.log"),
                                 n = 300, max_bytes = 128 * 1024),
                      error = function(e) "")
      fs <- tryCatch(list.files(st$root), error = function(e) character(0))
      # ⚠️ run.sh / main.py / main.R / run.log 是**过程**文件，不是产物。
      #    混在一起列出来，用户分不清"我该下载哪个"。
      arts <- setdiff(fs, c("run.sh", "main.py", "main.R", "run.log"))
      tagList(
        tags$hr(class = "my-2"),
        div(class = if (running) "alert alert-info py-2 mb-2"
                     else if (identical(st$status, "done"))
                       "alert alert-success py-2 mb-2"
                     else "alert alert-danger py-2 mb-2",
          tags$b(tags$code(st$key)), " · ",
          if (running) tags$span(class = "spinner-border spinner-border-sm me-1"),
          st$note %||% ""),
        if (length(arts)) tagList(
          h6(class = "text-muted small", "产物（在", tags$code("cloud/"),
             "下的这次运行目录里）"),
          tags$ul(class = "small",
            lapply(arts, function(f) tags$li(tags$code(f))))
        ) else if (identical(st$status, "done"))
          div(class = "text-muted small", "这次运行没有写出任何产物文件 —— ",
              "看下面的日志，多半是参数不对。"),
        h6(class = "text-muted small mt-2", "日志"),
        tags$pre(class = "dsapp-pre",
                 if (nzchar(log)) log else "（还没有输出）"),
        actionButton(ns("goto_files"), "在「文件」页打开这个工作区",
                     class = "btn-sm btn-outline-secondary",
                     icon = icon("folder-open"))
      )
    }
    output$tcga_tool_status <- renderUI(tool_status_box("tcga"))
    output$sc_tool_status   <- renderUI(tool_status_box("sc"))

    # ---- 面板二/三下半页（★ V16.4）------------------------------------------
    output$tcga_plan_area <- renderUI(mod_cloudtool_plan_area("tcga", ns))
    output$sc_plan_area   <- renderUI(mod_cloudtool_plan_area("sc", ns))
    output$tcga_groupsel  <- renderUI(mod_cloudtool_group_sel("tcga", ns("tcga_group")))
    output$sc_groupsel    <- renderUI(mod_cloudtool_group_sel("sc", ns("sc_group")))

    # ★★ 这六个 output 的 `suspendWhenHidden` **必须**关掉，否则它们永远是空的。
    #
    # 面板二/三是**一开始就 display:none** 的（那三块面板只切 class，见文件头），
    # 于是 Shiny 那套挂起机制把它们全按下去了：
    #
    #     hidden <- clientData$get(paste0("output_", name, "_hidden"))
    #     if (is.null(hidden)) hidden <- TRUE     # 客户端没报告过 = 当作隐藏
    #     return(hidden && getOutputOption(name, "suspendWhenHidden", TRUE))
    #
    # 中间那行的默认值才是要命的：**客户端没报告过的输出一律按"隐藏"处理**。
    # 而这块面板要等用户点上面那颗图标才显示，在那之前客户端一次都没报告过它
    # —— 所以 `renderUI` 根本不会被调用，`<div>` 一直是空的。
    #
    # ⚠️ 更阴的是切过去之后也**不会**补上：实测（2026-10-04，tests/ui_v164/
    #    probe_cloudreg.py）点开面板等 3 秒，六个 output 的 `output_*_hidden`
    #    全都是 `None`（客户端从没报过），三个看得见的照样是空的、
    #    还挂着 `recalculating`。也就是说这不是"慢一拍"，是**永远不画**。
    #    症状：工具清单一片空白、组下拉不存在、路线按钮一个都没有 ——
    #    而 `selftest.R` 那 40 条全绿（它们查的是 R 函数和源码字符串）。
    #
    # 这一条和 `mod_files.R` 的 `download` 是同一个坑（那边注释更长，写的是
    # 下载按钮的版本）。同一个出口：关掉挂起之后值在会话起步时就算好、下发到
    # 客户端缓存，元素后来才出现也没关系 —— shiny.js 的 `bindOutput` 会把
    # 缓存里的值补上。
    #
    # ⚠️ 关掉之后这六个 output **会在会话起步时就算一遍**：那时 `input$tcga_q`
    #    还不存在（框还没绑上），传进来是 NULL —— `dsapp_cloudreg_table()`
    #    两头都 `%||% ""` 接住了，算出来就是"全部、不筛"。
    #
    # ⚠️⚠️ 这一句**只能放在六个 output 都定义完之后**（现在的位置在文件下面
    #     `output$tcga_rows` 那两行后面）：`outputOptions()` 是**当场**去
    #    output 表里找名字的，找不到不是警告一句就算了，是 `stop()` 抛出去、
    #    **整个 server 起不来**（界面上是一片空白页，R 只在日志里说一句
    #    "cloudtool-tcga_rows is not in list of output objects"）。
    #    2026-10-04 第一版就放在 `groupsel` 后面，`*_rows` 还没注册 —— 实例
    #    直接白屏。

    #' 工具清单的行
    #'
    #' ⚠️ 这一个是**会**跟着 input 重画的（关键词 / 组筛选）。所以它里面不能
    #'    放输入控件 —— 见静态 UI 里那段 ⚠️。
    tool_rows <- function(kind, q, group) {
      r <- dsapp_cloudreg(kind)
      if (!isTRUE(r$ok)) return(NULL)      # 上半页已经报过"读不到文档"了
      df <- dsapp_cloudreg_table(kind, q = q, group = group)
      if (!nrow(df)) {
        return(div(class = "text-muted small py-2",
          "没有匹配的工具。换个关键词，或把组筛选切回「全部」。",
          "（这一页只列文档里注册过的工具 —— 不在表里的做法照样可以让它做，",
          "直接点上面的按钮开个对话说清楚就行。）"))
      }
      tagList(
        div(class = "dsapp-cloud-hint",
            sprintf("这里显示 %d 个 / 共 %d 个工具", nrow(df), r$n)),
        div(class = "dsapp-cloud-tools", `data-go` = ns("tool_go"),
          lapply(seq_len(nrow(df)), function(i) {
            mod_cloudtool_tool_row(kind, df$key[[i]], df$fn[[i]],
                                   df$inputs[[i]], df$outputs[[i]], df$kb[[i]])
          }))
      )
    }
    output$tcga_rows <- renderUI(tool_rows("tcga", input$tcga_q, input$tcga_group))
    output$sc_rows   <- renderUI(tool_rows("sc",   input$sc_q,   input$sc_group))

    # ★★ 六个 output **都定义完了**，现在才轮到关挂起（理由见上面那一大段
    #    ⚠️：`outputOptions()` 当场查名字，查到没有就抛，server 整个起不来）。
    # ★ V16.6 item 4 又加了四个（工作台 + 它的状态区，两个面板各一份）——
    #   它们同样活在**一开始就 display:none** 的面板里，不加进这一串就是
    #   和上面那六个一模一样的下场：永远不画、控制台无错、自检全绿。
    #   ⚠️ `*_tool_status` 是**嵌在工作台的 renderUI 里面**的，一样要关。
    for (o in c("tcga_plan_area", "sc_plan_area", "tcga_groupsel",
                "sc_groupsel", "tcga_rows", "sc_rows",
                "tcga_workbench", "sc_workbench",
                "tcga_tool_status", "sc_tool_status")) {
      outputOptions(output, o, suspendWhenHidden = FALSE)
    }

    #' 当前对话的工作区。没有打开的对话时返回 NULL。
    #'
    #' ⚠️ 这一页的产物必须落在**对话工作区**里（`<ws>/cloud/<任务名>-<时间戳>`）：
    #    产物卡片、「文件」页的"本对话产物"、配额统计认的都是工作区，
    #    另开一处目录的话，用户跑完在别的页面里找不到自己的东西。
    #' ⚠️ create = FALSE：只是"看一眼有没有"，不该因为打开了这一页就凭空
    #    建出一堆空工作区目录。
    ws <- reactive({
      sid <- state$chat_session_id
      if (is.null(sid) || !nzchar(as.character(sid))) return(NULL)
      p <- tryCatch(dsapp_ws_dir(sid, cfg(), create = FALSE),
                    error = function(e) NULL)
      if (is.null(p) || is.na(p)) NULL else p
    })

    #' 这次运行**自己的**工作区（从存档里的 sid 推，不是"现在打开的那个"）
    #'
    #' ⚠️⚠️ 这两个东西在用户切对话时会分开：存档属于对话 A，而
    #'    `state$chat_session_id` 已经变成 B。推进那一段每 2 秒就要落一次盘，
    #'    拿"当前工作区"去落 A 的存档，结果是 A 的进度被写进 B 的目录里 ——
    #'    界面上完全看不出来（两边目录都真实存在、写也都成功），
    #'    只是 A 那个对话里的这次运行再也接不回来了。
    ws_of_st <- function(st) {
      sid <- st$sid
      if (is.null(sid) || !nzchar(as.character(sid))) return(st$root)
      p <- tryCatch(dsapp_ws_dir(sid, cfg(), create = FALSE),
                    error = function(e) NULL)
      if (is.null(p) || is.na(p)) st$root else p
    }

    #' 工作区里可以当靶点的结构文件（下拉候选）
    ws_inputs <- reactive({
      w <- ws()
      if (is.null(w) || !dir.exists(w)) return(character(0))
      fs <- list.files(w, pattern = "\\.(pdb|cif)(\\.gz)?$", recursive = TRUE,
                       ignore.case = TRUE)
      # 内部文件不上候选（.dsapp_* / 点开头的目录是平台自己的东西）
      fs <- fs[!grepl("(^|/)\\.", fs)]
      sort(unique(fs))
    })

    # ---- 参数：控件是唯一真相 ------------------------------------------------
    #
    # 不另存一份 reactiveVal 的参数字典：那样就有两份真相，界面上改一半
    # （比如预设只更新了三个输入框中的一个）时，跑出去的和显示的对不上。
    # 这里的做法是"每次现读控件"，需要存档时（开跑那一刻）再落一份 RDS。
    P <- reactive({
      d <- dsapp_cloud_defaults()
      g <- function(k, dv) {
        v <- input[[k]]
        if (is.null(v)) dv else v
      }
      list(
        preset = as.character(g("preset", "teaching")),
        job    = as.character(g("job", d$job)),
        input  = {
          f <- as.character(g("input_file", ""))
          w <- ws()
          if (!nzchar(f) || is.null(w)) f
          else if (grepl("^(/|~)", f)) f else file.path(w, f)
        },
        contig     = as.character(g("contig", d$contig)),
        length     = as.character(g("length", d$length)),
        hotspots   = as.character(g("hotspots", d$hotspots)),
        step_scale = as.numeric(g("step_scale", d$step_scale)),
        gamma_0    = as.numeric(g("gamma_0", d$gamma_0)),
        n_batches  = as.integer(g("n_batches", d$n_batches)),
        diffusion_batch_size = as.integer(g("diffusion_batch_size",
                                            d$diffusion_batch_size)),
        non_loopy  = isTRUE(g("non_loopy", d$non_loopy)),
        use_mpnn   = isTRUE(g("use_mpnn", d$use_mpnn)),
        use_soluble = isTRUE(g("use_soluble", d$use_soluble)),
        mpnn_seq   = as.integer(g("mpnn_seq", d$mpnn_seq)),
        omit_cys   = isTRUE(g("omit_cys", d$omit_cys)),
        num_steps  = as.integer(g("num_steps", d$num_steps)),
        n_recycles = as.integer(g("n_recycles", d$n_recycles)),
        rf3_batch  = as.integer(g("rf3_batch", d$rf3_batch)),
        es_plddt   = as.numeric(g("es_plddt", d$es_plddt)),
        ipae_cut   = as.numeric(g("ipae_cut", d$ipae_cut)),
        iptm_cut   = as.numeric(g("iptm_cut", d$iptm_cut)),
        plddt_cut  = as.numeric(g("plddt_cut", d$plddt_cut))
      )
    })

    # ---- 体检 ---------------------------------------------------------------
    #
    # 只在**按需**的时候算：里面要探 GPU（`dsapp_host_gpu()` 会起 nvidia-smi
    # 之类的子进程），跟着每次击键算的话，用户每打一个字符就 fork 一次。
    pf <- reactiveVal(NULL)
    do_check <- function() {
      r <- tryCatch(
        dsapp_cloud_preflight(isolate(P()), cfg = cfg(),
                              user_id = isolate(state$user_id), gpu_ok = NULL),
        error = function(e) list(ok = FALSE, items = list(list(
          key = "err", label = "体检本身出错", ok = FALSE, warn = FALSE,
          detail = conditionMessage(e), fix = "把这句话发给管理员。"))))
      pf(r)
      r
    }
    # 登录完成时先自动体检一次（工作区那时可能还没建，input 那一项会是
    # "还没选" —— 这正是要让他看见的）。
    #
    # ⚠️ 触发点选的是 `state$user_id` 而不是"模块初始化那一下"：这个模块是在
    #    **登录之前**无条件注册的（app.R），那一刻 user_id 还是 NULL，
    #    体检会把 GPU 那一项判成"这个账号没被放行"——一句**假话**（那时根本
    #    还不知道是谁）。等它变成真值再算。
    observeEvent(state$user_id, {
      if (!is.null(state$user_id)) do_check()
    }, ignoreNULL = TRUE)

    output$preflight_box <- renderUI({
      r <- pf()
      if (is.null(r)) return(NULL)
      tagList(
        div(class = "d-flex align-items-center gap-2 mb-2",
          actionButton(ns("check"), "重新体检", class = "btn-sm btn-outline-secondary",
                       icon = icon("stethoscope")),
          if (isTRUE(r$ok))
            tags$span(class = "text-success small", icon("circle-check"),
                      " 该准备的都齐了")
          else
            tags$span(class = "text-danger small", icon("circle-exclamation"),
                      " 还有跑不动的项，先看下面标红的")
        ),
        tags$table(
          class = "table table-sm align-middle mb-3",
          tags$thead(tags$tr(tags$th(""), tags$th("检查项"), tags$th("情况"))),
          tags$tbody(lapply(r$items, function(it) {
            # 三种状态各有各的样子：不通过（红）、能跑但要知道（黄）、通过（绿）。
            ic <- if (!isTRUE(it$ok))
                    tags$span(class = "text-danger", icon("circle-xmark"))
                  else if (isTRUE(it$warn))
                    tags$span(class = "text-warning", icon("triangle-exclamation"))
                  else tags$span(class = "text-success", icon("circle-check"))
            tags$tr(
              tags$td(ic),
              tags$td(tags$b(it$label)),
              tags$td(
                div(class = "small", it$detail),
                if (!isTRUE(it$ok) && nzchar(it$fix %||% ""))
                  div(class = "small text-muted", "→ ", it$fix)
              )
            )
          }))
        )
      )
    })
    observeEvent(input$check, { do_check() })

    # ---- 参数表单 -----------------------------------------------------------
    output$form_box <- renderUI({
      d <- dsapp_cloud_defaults()
      w <- ws()
      if (is.null(w)) return(NULL)
      fs <- ws_inputs()
      tagList(
        div(class = "row g-2",
          div(class = "col-md-4",
            selectInput(ns("preset"), "档位",
              choices = stats::setNames(names(DSAPP_CLOUD_PRESETS),
                vapply(DSAPP_CLOUD_PRESETS, function(x) x$label, character(1))),
              selected = "teaching"),
            div(class = "small text-muted mb-2",
                DSAPP_CLOUD_PRESETS$teaching$note)
          ),
          div(class = "col-md-4",
            textInput(ns("job"), "任务名（会进文件名）", value = d$job),
            div(class = "small text-muted", "英文/数字/下划线最稳；中文会被换成 _")
          ),
          div(class = "col-md-4",
            if (length(fs)) {
              selectInput(ns("input_file"), "靶点结构（这个对话里的文件）",
                          choices = fs)
            } else {
              tagList(
                tags$label(class = "form-label", "靶点结构"),
                div(class = "alert alert-warning py-2 small mb-0",
                    "这个对话的工作区里还没有 .pdb/.cif 文件。",
                    "先到「文件」页上传一份靶点结构（上传后在对话里跑一次",
                    "才会镜像进工作区），再回到这里。")
              )
            }
          )
        ),

        tags$hr(class = "my-3"),

        # ---- 设计什么 ----
        h6(class = "text-muted", "设计目标"),
        div(class = "row g-2",
          div(class = "col-md-4",
            textInput(ns("contig"), "contig", value = d$contig),
            div(class = "small text-muted",
                "不带链名的段（70-90）= 要生成的 binder；带链名的段（A18-132）",
                "= 从靶点里保留的部分；/0 表示断开成独立链。")
          ),
          div(class = "col-md-4",
            textInput(ns("length"), "总长（length）", value = d$length),
            div(class = "small text-muted",
                "整条复合物的长度区间，必须和 contig 推出来的对得上（体检会算）。")
          ),
          div(class = "col-md-4",
            textInput(ns("hotspots"), "热点", value = d$hotspots),
            div(class = "small text-muted",
                "写成 A39: CE1,OH（链+残基号: 原子名），多个用分号隔开。",
                "原子名要和结构文件里逐字相同。")
          )
        ),

        tags$hr(class = "my-3"),

        # ---- 怎么生成 ----
        h6(class = "text-muted", "采样（RFD3）"),
        div(class = "row g-2",
          div(class = "col-md-2", numericInput(ns("n_batches"), "批数", d$n_batches, min = 1, step = 1)),
          div(class = "col-md-2", numericInput(ns("diffusion_batch_size"), "每批个数",
                                               d$diffusion_batch_size, min = 1, step = 1)),
          div(class = "col-md-2", numericInput(ns("step_scale"), "step_scale",
                                               d$step_scale, min = 0.1, step = 0.1)),
          div(class = "col-md-2", numericInput(ns("gamma_0"), "gamma_0",
                                               d$gamma_0, min = 0, step = 0.05)),
          div(class = "col-md-4",
            checkboxInput(ns("non_loopy"), "is_non_loopy（不生成含环的结构）",
                          d$non_loopy)
          )
        ),

        tags$hr(class = "my-3"),

        h6(class = "text-muted", "序列设计（MPNN）与复折叠（RF3）"),
        div(class = "row g-2",
          div(class = "col-md-3",
            checkboxInput(ns("use_mpnn"), "ProteinMPNN", d$use_mpnn),
            checkboxInput(ns("use_soluble"), "SolubleMPNN", d$use_soluble),
            checkboxInput(ns("omit_cys"), "设计时不用半胱氨酸（--omit CYS）",
                          d$omit_cys)
          ),
          div(class = "col-md-2", numericInput(ns("mpnn_seq"), "每个骨架几条序列",
                                               d$mpnn_seq, min = 1, step = 1)),
          div(class = "col-md-2", numericInput(ns("num_steps"), "RF3 num_steps",
                                               d$num_steps, min = 1, step = 1)),
          div(class = "col-md-2", numericInput(ns("n_recycles"), "RF3 n_recycles",
                                               d$n_recycles, min = 1, step = 1)),
          div(class = "col-md-3", numericInput(ns("es_plddt"), "早停阈值（pLDDT）",
                                               d$es_plddt, min = 0, max = 1,
                                               step = 0.05))
        ),

        tags$hr(class = "my-3"),

        h6(class = "text-muted", "筛选线（只是观察线，见上面的说明）"),
        div(class = "row g-2",
          div(class = "col-md-3", numericInput(ns("ipae_cut"), "ipae ≤", d$ipae_cut, step = 0.5)),
          div(class = "col-md-3", numericInput(ns("iptm_cut"), "ipTM ≥", d$iptm_cut, step = 0.05)),
          div(class = "col-md-3", numericInput(ns("plddt_cut"), "binder pLDDT ≥",
                                               d$plddt_cut, step = 1)),
          div(class = "col-md-3",
            div(class = "small text-muted mt-4",
                "改这三个只是改「通过」那一列怎么画，不改计算。")
          )
        )
      )
    })

    # 换档位 → 把三个数量输入框刷成那一档的值。
    #
    # ⚠️ 只刷这三个（`dsapp_cloud_apply_preset` 也只动这三个）：采样参数是
    #    "结果长什么样"的开关，跟着数量一起变的话，用户没法用"快速试跑"
    #    预判生产档的行为。
    observeEvent(input$preset, {
      pr <- DSAPP_CLOUD_PRESETS[[input$preset]]
      if (is.null(pr)) return()
      updateNumericInput(session, "n_batches", value = pr$n_batches)
      updateNumericInput(session, "diffusion_batch_size",
                         value = pr$diffusion_batch_size)
      updateNumericInput(session, "mpnn_seq", value = pr$mpnn_seq)
    }, ignoreInit = TRUE)

    # ---- 运行状态 -----------------------------------------------------------
    #
    # `run_st()` = 这一次运行的存档（形状见 cloudtool.R 的 dsapp_cloud_state_*）：
    #   list(id, root, sid, params, steps=list(list(key,status,tid,exit,t0,t1)),
    #        active, note, created)
    run_st <- reactiveVal(NULL)
    tick   <- reactiveVal(0)   # 只用来让结果区跟着刷新（见下面 tick 的说明）

    #' 新开一次运行的存档
    new_run <- function(P0, w) {
      stamp <- format(Sys.time(), "%Y%m%d-%H%M%S")
      root  <- dsapp_cloud_run_root(w, P0, stamp)
      steps <- lapply(dsapp_cloud_steps(P0), function(s)
        list(key = s$key, n = s$n, label = s$label, what = s$what,
             status = "pending", tid = NULL, exit = NULL,
             t0 = NULL, t1 = NULL))
      list(id = basename(root), root = root, sid = state$chat_session_id,
           params = P0, steps = steps, active = TRUE, note = "准备开始",
           created = dsapp_now())
    }

    # ---- 提交一步 -----------------------------------------------------------
    #
    # 提交失败**不**让这一次运行报废：最常见的原因是"引擎正忙"（别人在跑），
    # 那只要等下一拍重试。真正需要用户动手的失败（环境不存在之类）会在任务
    # 行里留下 stderr，界面上如实显示。
    submit_step <- function(st, i) {
      P0 <- st$params
      w  <- st$root
      env_dir <- dsapp_cloud_env_dir(cfg())
      ck_dir  <- dsapp_cloud_ckpt_dir(cfg())
      eval_py <- dsapp_cloud_eval_script(cfg())
      sk <- st$steps[[i]]$key
      code <- dsapp_cloud_step_script(sk, P0, w, env_dir, ck_dir, eval_py)
      r <- engine$start(
        code = paste(code, collapse = "\n"),
        lang = "Bash",
        title = sprintf("云工具 · 第%d步 %s（%s）", i,
                        dsapp_cloud_steps(P0)[[i]]$label, dsapp_cloud_slug(P0$job)),
        session_id = st$sid %||% NA_character_,
        target = list(kind = "server", env = "system"),
        user_id = state$user_id)
      if (!isTRUE(r$ok)) return(list(ok = FALSE, msg = r$msg))
      st$steps[[i]]$tid    <- r$task_id
      st$steps[[i]]$status <- "running"
      st$steps[[i]]$t0     <- dsapp_now()
      st$note <- sprintf("第%d步已提交", i)
      list(ok = TRUE, st = st)
    }

    # ---- 链式推进 -----------------------------------------------------------
    #
    # 每 2 秒醒一次：看当前这一步的任务行结没结束，结束了就提交下一步。
    # ⚠️ 读 run_st() 一律 isolate()（理由见文件头第 3 条）。
    # ⚠️ invalidateLater 必须**无条件**排在最前面：条件式注册会让这个观察者
    #    在某条分支上再也不会醒（本仓在别处栽过）。
    TERMINAL <- c("success", "failed", "timeout", "error")
    observe({
      invalidateLater(2000)
      st <- isolate(run_st())
      if (is.null(st) || !isTRUE(st$active)) return()

      w <- st$root
      # 哪一步是"当前这一步"：第一个还没 done 的
      idx <- which(vapply(st$steps, function(s)
        !identical(s$status, "done"), logical(1)))
      if (!length(idx)) {                 # 全跑完了
        st$active <- FALSE
        st$note <- "四步都跑完了"
        dsapp_cloud_state_save(ws_of_st(st), st)
        run_st(st); tick(isolate(tick()) + 1)
        showNotification("云工具：这次运行的四步都跑完了，结果在下面。",
                         type = "message", duration = 8)
        return()
      }
      i <- idx[[1]]
      cur <- st$steps[[i]]

      # (a) 这一步已经提交了 → 看任务行
      if (identical(cur$status, "running") && !is.null(cur$tid)) {
        row <- tryCatch(db_task_get(cur$tid, con = dsapp_db(cfg())),
                        error = function(e) NULL)
        if (is.null(row)) {
          # 任务行没了（被用户删了？）。如实说，别自己假装还在跑。
          st$steps[[i]]$status <- "failed"
          st$steps[[i]]$exit <- NA_integer_
          st$note <- sprintf("第%d步的任务行不见了（可能被删了）", i)
          dsapp_cloud_state_save(ws_of_st(st), st)
          run_st(st); tick(isolate(tick()) + 1)
          return()
        }
        if (!identical(as.character(row$status), "running") &&
            !identical(as.character(row$status), "pending")) {
          ok <- identical(as.character(row$status), "success")
          st$steps[[i]]$status <- if (ok) "done" else "failed"
          st$steps[[i]]$exit   <- row$exit_code
          st$steps[[i]]$t1     <- dsapp_now()
          st$note <- if (ok) sprintf("第%d步完成", i)
                     else sprintf("第%d步没跑成（%s）", i, row$status)
          dsapp_cloud_state_save(ws_of_st(st), st)
          if (!ok) {
            st$active <- FALSE
            dsapp_cloud_state_save(ws_of_st(st), st)
            run_st(st); tick(isolate(tick()) + 1)
            showNotification(
              sprintf("云工具：第%d步没跑成，看下面的日志。修好之后可以只重跑这一步。", i),
              type = "error", duration = NULL)
            return()
          }
          run_st(st); tick(isolate(tick()) + 1)
          return()   # 下一拍再提交下一步（让这一次写入先落定）
        }
        return()     # 还在跑
      }

      # (b) 这一步还没提交 → 引擎空着就提交
      if (engine$is_busy()) {
        if (!identical(st$note, "等着执行槽空出来（平台同一时刻只跑一个任务）")) {
          st$note <- "等着执行槽空出来（平台同一时刻只跑一个任务）"
          run_st(st)
        }
        return()
      }
      res <- tryCatch(submit_step(st, i), error = function(e)
        list(ok = FALSE, msg = conditionMessage(e)))
      if (!isTRUE(res$ok)) {
        st$note <- sprintf("提交第%d步失败：%s（会自动重试）", i,
                           res$msg %||% "未知原因")
        run_st(st)
        return()
      }
      st <- res$st
      dsapp_cloud_state_save(ws_of_st(st), st)
      run_st(st); tick(isolate(tick()) + 1)
    })

    # ---- 开跑 ---------------------------------------------------------------
    observeEvent(input$run, {
      w <- ws()
      if (is.null(w)) {
        showNotification("先在「言出法随」页开一个对话 —— 结果要落在那个对话的工作区里。",
                         type = "warning", duration = 6)
        return()
      }
      P0 <- P()
      r <- dsapp_cloud_preflight(P0, cfg = cfg(), user_id = state$user_id,
                                 gpu_ok = NULL)
      pf(r)
      if (!isTRUE(r$ok)) {
        bad <- vapply(Filter(function(x) !isTRUE(x$ok), r$items),
                      function(x) x$label, character(1))
        showNotification(
          paste0("先解决体检里这几项：", paste(bad, collapse = "、")),
          type = "error", duration = 8)
        return()
      }
      # 工作区目录可能还不存在（发消息不建目录，见 executor.R）
      dir.create(w, recursive = TRUE, showWarnings = FALSE)
      st <- new_run(P0, w)
      dir.create(st$root, recursive = TRUE, showWarnings = FALSE)
      dsapp_cloud_state_save(w, st)
      run_st(st); tick(isolate(tick()) + 1)
      showNotification("开始了。平台同一时刻只跑一个任务，这几步会依次提交。",
                       type = "message", duration = 6)
    })

    # ---- 中止 ---------------------------------------------------------------
    observeEvent(input$abort, {
      st <- isolate(run_st())
      if (is.null(st) || !isTRUE(st$active)) return()
      idx <- which(vapply(st$steps, function(s)
        identical(s$status, "running"), logical(1)))
      cur_tid <- if (length(idx)) st$steps[[idx[[1]]]]$tid else NULL
      # ⚠️ 只有**这一步是自己的任务**时才按停。引擎是全局单槽，别人提交的
      #    任务此刻可能正占着它 —— 不看这一眼就按，停掉的是别人的任务。
      if (!is.null(cur_tid) && identical(engine$current_task_id(), cur_tid)) {
        engine$abort(reason = "云工具：用户中止")
      }
      if (length(idx)) {
        i <- idx[[1]]
        st$steps[[i]]$status <- "failed"
        st$steps[[i]]$t1 <- dsapp_now()
        st$note <- sprintf("第%d步被手动停掉了", i)
      }
      st$active <- FALSE
      dsapp_cloud_state_save(ws_of_st(st), st)
      run_st(st); tick(isolate(tick()) + 1)
      showNotification("已停。已经算出来的东西留在工作区里，第 3 步之后再跑会跳过它们。",
                       type = "message", duration = 8)
    })

    # ---- 历史运行：看 / 继续 -------------------------------------------------
    observeEvent(input$open_run, {
      st <- dsapp_cloud_state_load(isolate(ws()), input$open_run)
      if (is.null(st)) {
        showNotification("这次运行的存档读不出来了（文件被删了？）",
                         type = "warning", duration = 6)
        return()
      }
      # 看历史时**不**自动接着推进：它可能是几天前挂在那儿的一次。
      st$active <- FALSE
      run_st(st); tick(isolate(tick()) + 1)
    })

    observeEvent(input$resume_run, {
      w <- isolate(ws())
      st <- dsapp_cloud_state_load(w, input$resume_run)
      if (is.null(st)) return()
      # 把"没跑成"的那一步退回 pending，前面 done 的原样留着。
      for (i in seq_along(st$steps)) {
        if (identical(st$steps[[i]]$status, "failed"))
          st$steps[[i]]$status <- "pending"
      }
      st$active <- TRUE
      st$note <- "接着跑"
      dsapp_cloud_state_save(w, st)
      run_st(st); tick(isolate(tick()) + 1)
      showNotification("接着跑。已经算完的步骤不会重来。",
                       type = "message", duration = 6)
    })

    # ---- 运行区 -------------------------------------------------------------
    output$run_box <- renderUI({
      w <- ws()
      if (is.null(w)) {
        return(div(class = "text-muted small",
          "先在「言出法随」页开一个对话。这一页的产物要落在那个对话的工作区里，",
          "这样在「文件」页和产物卡片里才看得到它们。"))
      }
      st <- run_st()
      busy <- engine$is_busy()
      tagList(
        div(class = "d-flex align-items-center gap-2 mb-2",
          actionButton(ns("run"), "开始运行", class = "btn-primary",
                       icon = icon("play")),
          if (!is.null(st) && isTRUE(st$active))
            actionButton(ns("abort"), "停", class = "btn-outline-danger btn-sm",
                         icon = icon("stop")),
          if (busy)
            tags$span(class = "small text-muted", icon("hourglass-half"),
                      " 执行槽正忙（平台同一时刻只跑一个任务）")
          else
            tags$span(class = "small text-muted", icon("circle-check"),
                      " 执行槽空着")
        ),
        if (is.null(st)) {
          div(class = "text-muted small", "还没开始。填好上面的参数，先体检，再点「开始运行」。")
        } else {
          tagList(
            div(class = "small text-muted mb-2",
                "这次运行在：", tags$code(st$root), "　·　", st$note %||% ""),
            tags$table(class = "table table-sm align-middle",
              tags$thead(tags$tr(tags$th("#"), tags$th("这一步"),
                                 tags$th("状态"), tags$th("任务"))),
              tags$tbody(lapply(seq_along(st$steps), function(i) {
                s <- st$steps[[i]]
                tags$tr(
                  tags$td(i),
                  tags$td(div(tags$b(s$label)), div(class = "small text-muted", s$what)),
                  tags$td(dsapp_status_badge(switch(s$status,
                    pending = "pending", running = "running",
                    done = "success", failed = "failed", s$status))),
                  tags$td(if (!is.null(s$tid))
                            tags$span(class = "small", sprintf("#%d", s$tid))
                          else tags$span(class = "text-muted small", "—"))
                )
              }))
            )
          )
        }
      )
    })

    # ---- 实时日志 -----------------------------------------------------------
    #
    # 执行器把子进程的 stdout/stderr 直接写工作区的 .dsapp_stdout（executor.R），
    # tail 一下就能看到进度。长任务只给一个转圈会让人以为卡死了。
    output$live_box <- renderUI({
      invalidateLater(if (engine$is_busy()) 2000 else 8000)
      st <- run_st()
      if (is.null(st)) return(NULL)
      running <- any(vapply(st$steps, function(s)
        identical(s$status, "running"), logical(1)))
      if (!running) return(NULL)
      # ⚠️ 读的是**这次运行自己的**工作区（ws_of_st），不是"现在打开的那个"：
      #    看着对话 A 的一次运行、而当前对话是 B 时，读 B 的 .dsapp_stdout
      #    会把 B 上一次执行的输出当成 A 的进度显示出来 —— 内容真实、
      #    归属是错的，这种错最难发现。
      txt <- tryCatch(dsapp_tail(file.path(ws_of_st(st), ".dsapp_stdout"),
                                 n = 200, max_bytes = 128 * 1024),
                      error = function(e) "")
      tagList(
        h6(class = "text-muted small mt-3", "实时输出（这一步）"),
        tags$pre(class = "dsapp-pre", if (nzchar(txt)) txt else "（还没有输出）")
      )
    })

    # ---- 结果 ---------------------------------------------------------------
    #
    # 收货是纯函数（cloudtool.R 的 dsapp_cloud_harvest），这里只管画。
    # ⚠️ 读 tick() —— 收割要在"某一步刚跑完"时自动刷新，而 harvest 读的是
    #    磁盘上的 CSV（不是响应式值），不挂一个每拍都变的东西就不会重算。
    harvest <- reactive({
      tick()
      st <- run_st()
      if (is.null(st)) return(NULL)
      dsapp_cloud_harvest(st$root, st$params)
    })

    output$result_note <- renderUI({
      h <- harvest()
      if (is.null(h)) return(div(class = "text-muted small", "还没有开始运行。"))
      if (!isTRUE(h$ok)) {
        return(div(class = "text-muted small",
          h$msg %||% "还没有结果。", " ",
          "四步都跑完之后，这里会出现每个候选的 ipae / ipTM / pLDDT 表。"))
      }
      ad <- dsapp_cloud_advise(h, isolate(run_st())$params)
      tagList(
        div(class = "alert alert-info py-2",
          lapply(ad$lines, function(x)
            p(class = "mb-1 small", dsapp_md_inline(x)))
        )
      )
    })

    output$metrics <- DT::renderDataTable({
      h <- harvest()
      if (is.null(h) || !isTRUE(h$ok) || is.null(h$df)) {
        return(DT::datatable(data.frame(提示 = "还没有结果"), options = list(dom = "t"),
                             rownames = FALSE))
      }
      st <- isolate(run_st())
      df <- dsapp_cloud_rank(h$df)
      pass <- dsapp_cloud_pass(df, st$params %||% dsapp_cloud_defaults())
      # ⚠️⚠️ 逐列取的时候**必须**兜住"这一列压根不存在"：汇总脚本是外部
      #    配套脚本，它换了版本、或者某次只写了部分列，`df$notes %>% NULL`，
      #    而 `data.frame(备注 = NULL)` 不是"空一列"，是**零长度** ——
      #    和别的列一起拼就是 "arguments imply differing number of rows"。
      #    那会发生在"用户等了半小时、正要收货"的那一刻（本仓栽过：
      #    paste0 的零长度会变成 1 个）。
      col_chr <- function(nm) {
        v <- if (nm %in% names(df)) df[[nm]] else rep(NA, nrow(df))
        v <- as.character(v); v[is.na(v)] <- ""
        v
      }
      col_num <- function(nm, dig) {
        v <- if (nm %in% names(df)) suppressWarnings(as.numeric(df[[nm]]))
             else rep(NA_real_, nrow(df))
        if (is.na(dig)) v else round(v, dig)
      }
      show <- data.frame(
        通过 = ifelse(pass, "✓", ""),
        来源 = col_chr("source"),
        设计 = col_chr("rfd3_design_id"),
        预测 = col_chr("prediction_id"),
        ipae = col_num("ipae", 2),
        ipTM = col_num("iptm", 3),
        binder_pLDDT = col_num("binder_plddt", 1),
        状态 = col_chr("status"),
        备注 = col_chr("notes"),
        stringsAsFactors = FALSE, check.names = FALSE)
      DT::datatable(show, rownames = FALSE,
                    options = list(pageLength = 15, scrollX = TRUE,
                                   order = list()))
    })

    output$artifacts <- renderUI({
      st <- run_st()
      if (is.null(st)) return(NULL)
      w <- ws()
      tagList(
        h6(class = "text-muted small mt-3", "产物"),
        tags$ul(class = "small",
          tags$li(tags$code(file.path("cloud", basename(st$root)))),
          tags$li("指标表：", tags$code("ProteinMPNN.csv / SolubleMPNN.csv")),
          tags$li("骨架：", tags$code("rfd3/outputs/1/*.cif"),
                  "　预测结构：", tags$code("rf3/1|2/*_model.cif"))
        ),
        # 跳去文件页看/下载。
        # ⚠️ 走 dsapp_nav_to（顶层 session）+ state$focus_ws：模块自己的
        #    session 上跳页是静默失效的（utils.R 里 dsapp_nav_to 那段）。
        if (!is.null(w))
          actionButton(ns("goto_files"), "在「文件」页打开这个工作区",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("folder-open"))
      )
    })

    observeEvent(input$goto_files, {
      st <- isolate(run_st())
      if (is.null(st)) return()
      state$focus_ws <- list(sid = st$sid, name = file.path("cloud", basename(st$root)))
      dsapp_nav_to(state, "files")
    })

    # ---- 这个工作区跑过的 ---------------------------------------------------
    runs_refresh <- reactiveVal(0)
    output$runs_box <- renderUI({
      runs_refresh()
      tick()          # 跑完一步之后这个列表也要跟着更新（新目录出现了）
      w <- ws()
      if (is.null(w) || !dir.exists(w)) {
        return(div(class = "text-muted small", "还没有跑过。"))
      }
      rs <- tryCatch(dsapp_cloud_runs(w), error = function(e) NULL)
      if (is.null(rs) || !nrow(rs)) {
        return(div(class = "text-muted small", "这个对话还没有跑过云工具。"))
      }
      tagList(
        tags$table(class = "table table-sm",
          tags$thead(tags$tr(tags$th("目录"), tags$th("最后改动"), tags$th(""))),
          tags$tbody(lapply(seq_len(nrow(rs)), function(i) {
            r <- rs[i, , drop = FALSE]
            # ⚠️ 用 jsonlite::toJSON 拼值，不用 sprintf("'%s'")：目录名来自
            #    用户填的任务名（已经过 slug 洗过），但这个写法是全仓通用的
            #    那个（见 mod_files.R 的 ws_act_link），照抄不会错。
            js <- function(inp) sprintf(
              "Shiny.setInputValue(%s,%s,{priority:'event'});",
              jsonlite::toJSON(ns(inp), auto_unbox = TRUE),
              jsonlite::toJSON(r$name, auto_unbox = TRUE))
            tags$tr(
              tags$td(tags$code(r$name)),
              tags$td(class = "small text-muted", r$mtime),
              tags$td(
                actionButton(ns("open_run"), "看结果",
                             class = "btn-sm btn-outline-secondary",
                             onclick = js("open_run")),
                actionButton(ns("resume_run"), "接着跑",
                             class = "btn-sm btn-outline-primary",
                             onclick = js("resume_run"))
              )
            )
          }))
        ),
        div(class = "d-flex align-items-center gap-2",
          # 刷新按钮：目录是外部进程（任务）在写，界面上没有别的信号能告诉
          # 这一页"又有一次运行了"。
          actionButton(ns("refresh_runs"), "刷新列表",
                       class = "btn-sm btn-outline-secondary",
                       icon = icon("rotate")),
          div(class = "small text-muted",
            "「接着跑」只重跑没跑成的那一步；已经算完的步骤不会重来。",
            "第 1 步（生成骨架）没有续跑能力，重跑那一批就是从零算。")
        )
      )
    })
    observeEvent(input$refresh_runs, { runs_refresh(isolate(runs_refresh()) + 1) })

    # 一进这一页（或换了对话），把那个工作区里最近一次**还活着**的运行接回来
    # —— 浏览器刷新、换设备打开都能接着看。磁盘上可能有好几份 active=TRUE 的
    # 存档（浏览器直接关了），接最近的那一份。
    #
    # ⚠️ 换对话时必须**重新接一次**（不能"已经有一个 run_st 就什么都不做"）：
    #    上一次的 run_st 属于**上一个**工作区，留着它，界面就会拿 A 的进度
    #    配 B 的工作区显示，而推进那一段还会接着去推 A 的那个运行。
    observeEvent(ws(), {
      w <- ws()
      cur <- isolate(run_st())
      if (is.null(w) || !dir.exists(w)) {
        if (!is.null(cur) && !isTRUE(cur$active)) run_st(NULL)
        return()
      }
      # 已经是**这个**工作区的存档 → 不动它（否则每次 ws 微动就把用户的
      # "看历史"选择顶掉）。
      if (!is.null(cur)) {
        same <- tryCatch(identical(ws_of_st(cur), w), error = function(e) FALSE)
        if (isTRUE(same)) return()
      }
      sts <- tryCatch(dsapp_cloud_state_list(w), error = function(e) list())
      sts <- Filter(function(s) isTRUE(s$active), sts)
      if (!length(sts)) { run_st(NULL); return() }
      # 挑最近改动的那个存档文件（用文件时间，不用存档里的 created 字符串：
      # 那个是给人看的本地时间，拿去 as.POSIXct 还得猜时区）。
      ts <- vapply(sts, function(s) {
        f <- dsapp_cloud_state_path(w, s$id)
        if (file.exists(f)) as.numeric(file.mtime(f)) else 0
      }, numeric(1))
      run_st(sts[[which.max(ts)]])
    }, ignoreNULL = TRUE)

    # ⚠️ 没有工作区时，上面几块的 renderUI 会返回 NULL —— 但**参数区**要
    #    给一句明确的话，不然用户看到的是"这一页什么都没有"。
    output$no_ws_hint <- renderUI({
      if (!is.null(ws())) return(NULL)
      div(class = "alert alert-warning py-2",
        icon("circle-info"), " 这一页要有一个对话才能跑：",
        "产物落在对话的工作区里，这样在「文件」页和产物卡片里才看得到。",
        "先到「言出法随」页开一个对话，再回来。")
    })
  })
}
