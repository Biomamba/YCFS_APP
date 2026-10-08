# =============================================================================
# Biomamba言出法随生信APP —— 生信数据分析助手（R Shiny）
# =============================================================================
# 部署在 /srv/shiny-server/YCFS_APP/，从 http://<host>:34038/YCFS_APP/ 访问。
#
# ★ V13.7 item 8：URL 路径从 /DS_App/ 改成了 /YCFS_APP/。用户的原话是
#   「部署时网站显示的最终文件夹需要从 http://…:34038/DS_App/，变为 YCFS_APP」。
#
# ⚠️ 这条路径**不是应用里的设置**：Shiny Server 的配置是 `location /` +
#    `site_dir /srv/shiny-server`，它对 site_dir 下的每个子目录按**目录名**
#    挂一个 app。所以改 URL = 改那个软链的名字，见 deploy_link.sh 的 DEST。
#    app.R 里没有任何地方拼这个路径，改不改都不影响本文件的行为。
#
# ⚠️ 改名**不会**让旧地址自动作废：只要旧软链还在，/DS_App/ 照样能用 ——
#    而两个 URL 就是两个 R 进程跑同一份库，单端登录会互相顶下线。
#    旧地址要真失效，得 `sudo rm /srv/shiny-server/DS_App`。
#
# ⚠️ 注意别和 R/platform.R:204 那个 `file.path(base, "DS_App")` 搞混：
#    那是 Windows/用户私有**数据目录**的名字（~/.local/share/DS_App），
#    和 URL 无关，**不要动**（selftest 也会盯着它）。
#
# 结构：
#   app.R           —— 入口：主题、路由、跨会话共享的执行引擎
#   R/config.R      —— 配置（全部走环境变量，无硬编码路径）
#   R/platform.R    —— 平台差异（Windows 上没有 bash/ulimit/setsid）
#   R/db.R          —— SQLite（会话/消息/任务）
#   R/scanner.R     —— 代码静态扫描（拦误伤，不是沙箱）
#   R/executor.R    —— 本机受限执行（rlimit + 工作目录隔离 + 只读输入）
#   R/remote.R      —— 远程服务器执行（SSH，密码走 setsid + SSH_ASKPASS）
#   R/envs.R        —— 用户自建 conda 环境
#   R/export.R      —— 「本地电脑」模式：导出可运行包
#   R/models.R      —— 模型目录（各厂商 model 名 + 申请 Key 的官网地址）
#   R/llm.R         —— 流式调用（子进程 + 文件回传）
#   R/jobs.R        —— 后台作业（callr::r_bg）
#   R/render.R      —— 消息渲染（转义规则见文件头）
#   R/mod_*.R       —— 五个页面
#
# ⚠️ Shiny Server 开源版一个应用只有一个 R 进程，所有访客共享它。
# 任何同步的耗时操作（LLM 请求、代码执行、conda 求解）都会卡住**所有人**。
# 所以这些一律走子进程 + 文件回传，父进程只轮询。
# =============================================================================

library(shiny)
library(bslib)

# ★★ V15.10 item 4：关掉 JIT —— 「页面未响应」的主因。
#
# R 默认是 `enableJIT(3)`，意思是在一个闭包**第二次被调用之前**，当场给它做
# 字节编译（第一次还是解释执行，所以"第一次调用"看不出异常 —— 这也是它难查
# 的原因）。本应用的函数又多又大（mod_chat_server 2950 行、mod_admin_server
# 1226 行、mod_files_server 1190 行……），而 R 的字节编译器在**又大又平的**
# 函数体上慢得离谱 —— 实测一个由 `v1 <- 1+1; v2 <- 2+1; …` 拼成的闭包：
#
#     语句条数      编译一次       执行一次
#        500        0.165 s
#       1000        0.419 s
#       2000        1.276 s
#       4000        4.190 s        0.040 s
#
# 于是这笔账落在**每个 worker 世代的第 2 个会话**上，而且只落在它头上：
# `mod_*_server` 每家**每个会话只被调一次**，所以
#
#     第 1 个会话：所有模块 server 都是第一次调用 → 全解释执行 → 正常
#     第 2 个会话：它们全是第二次 → 当场把 16 个模块 server 一起编掉 → 卡住
#     第 3 个会话：早编好了 → 又正常了
#
# 2026-10-02 拿**这份 app.R**（就是现在这份）起实例、浏览器连开三页量到
# （探针：session 建立 → 第一次 flush 结束，也就是用户"点进来"的那一段）：
#
#                       第 1 页     第 2 页       第 3 页
#     JIT 3（R 的默认）  1.291 s   **8.032 s**    0.963 s
#     JIT 0（现在）      1.031 s     1.035 s      1.361 s
#     （JIT 3 复现一遍：  1.295 s   **8.208 s**    0.979 s）
#
# ⚠️⚠️ 「卡的是第 2 页、不是第 1 页」正是它藏了这么久的原因：第一下**永远
#     试不出来**。谁赶上"第 2 页"全看运气 —— 所以用户的原话是"有时候会卡"，
#     而不是"每次都卡"。另一组（43 条 / 203 KB 的真实会话、打了等价开关的
#     实例）结论一致：session → 第一次 flush 9.11 s → 1.50 s；profile 里
#     编译器自己的帧 1021 拍（约 10.2 秒）→ 3 拍。
#
# 而且关掉之后**冷路径反而更快** —— JIT 3 是一边跑一边编，编的时间比省下来
# 的多（真实那个 43 条 / 203 KB 的会话重画一遍）：
#
#                       冷         热
#     JIT 3           0.927 s   0.039 s
#     JIT 0           0.361 s   0.033 s
#
# 热路径的代价量不出来（30 KB 正文重画 17.49 vs 17.76 ms，在噪声里）——
# 因为真正吃 CPU 的那几处（正则、commonmark、digest、SQLite）都在 C 层，
# 解释器开销加不到它们身上。
#
# ⚠️ 为什么这一条尤其要紧：worker **空闲 5 秒就被杀**（Shiny Server 的
#    app_idle_timeout），世代换得很勤 —— 也就是**每隔一会儿就有一个人要当
#    那个"第 2 页"**。不修的话，这道坎每个世代都会重新长出来。
#
# ⚠️ 影响范围只有**本进程里 source 进来的闭包**：包里的函数是安装时就编好的
#    （不受 JIT 影响），callr 起出去的干活子进程是另一个进程（也不受影响）。
#    所以这一刀切不到别处去。
#
# ⚠️ 留 DSAPP_JIT 这个口子是为了以后能对照着量：设成 3 就是 R 的默认行为，
#    设成别的（或乱写）一律退回 0 —— 宁可慢一点，也不要一个"看起来设了、
#    其实没设"的开关（本仓栽过：`%||%` 碰到 S4 连接恒 FALSE 那次）。
local({
  lv <- suppressWarnings(as.integer(Sys.getenv("DSAPP_JIT", "0")))
  if (is.na(lv) || lv < 0L || lv > 3L) lv <- 0L
  compiler::enableJIT(lv)
})

# ---- 载入 -------------------------------------------------------------------

# 显式定一次应用目录，后面所有数据路径都从它推导（见 config.R）。
# Shiny Server 启动应用时工作目录就是应用目录，但显式设置之后，
# 从别处 runApp() 或者被 systemd 以别的 cwd 拉起时也不会推导到错的地方。
if (!nzchar(Sys.getenv("DSAPP_APP_DIR", ""))) {
  Sys.setenv(DSAPP_APP_DIR = normalizePath(getwd(), mustWork = FALSE))
}

# 按依赖顺序 source。mod_*.R 依赖前面的基础层，放最后。
local({
  # ⚠️ platform.R 必须**排在 executor.R 前面**：执行层和远程层到处在调
  #    dsapp_is_windows() / dsapp_bash_path() / dsapp_devnull()，而这些函数
  #    在 source 到它们的那一刻就得已经存在。这个列表是 app.R 自己 source
  #    用的，顺序错了就是"启动即崩"。
  # crypto.R（V13.1 item 9）挨着 config.R：它只依赖 config（要 data_root
  # 定位钥匙串）和 openssl，不依赖别的 DS_App 文件，所以放最前面最安全 ——
  # db.R 的 dsapp_db_migrate_secrets() 和 users.R 的读写路径都要调它，
  # 晚于这两者 source 的话，第一次建连接（dsapp_db_schema 里就跑迁移）
  # 就是 could not find function。
  files <- c("config.R", "crypto.R", "utils.R",
             # errhand.R（V13.10 item 1）紧挨着 utils.R：它是"整页报错"的
             # 兜底，只依赖 config（要 logs_dir）和 utils（dsapp_now / %||%），
             # 别的文件一个都不碰 —— 兜底的东西自己不能有依赖，不然它跟着
             # 一起坏。放在这里是为了让它**先于**任何可能出错的东西存在：
             # app.R 底下 dsapp_err_init() 一调用就要用到它。
             "errhand.R",
             "platform.R", "db.R",
             "scanner.R",
             "executor.R",
             "envs.R", "remote.R", "export.R", "gc.R", "files.R", "prompts.R",
             # sync.R（V13.3 item 2，本地库 ↔ 在线版）紧挨着 remote.R：
             # 它整个传输层就是调 dsapp_ssh_ctx / ssh_push / ssh_pull /
             # ssh_run，**必须**排在 remote.R 后面，否则 source 到它的时候
             # 那些函数还不存在（症状是"启动即崩"）。
             # 排在 gc.R 后面是因为 gc.R 的 dsapp_gc 会调 dsapp_sync_gc
             # （那个是**运行时**调用，所以顺序其实只对 source 时刻的
             # 引用有要求，但挨着放读起来因果清楚）。
             # synckey.R（V13.7 item 7）紧挨着 sync.R：同步包的签名密钥。
             # 它俩是一对 —— sync.R 里每一个 apply 都要用它验签，users.R
             # 登录成功那一刻往里放密钥。**必须在这份列表里**：漏了的后果
             # 见上面 nodes.R / audit.R 那段（静默失效，页面上一片正常）。
             "synckey.R",
             # V15 item 8（论坛）。排在这里是**被依赖**关系决定的：sync.R 的
             # 建包/应用包里各有一段论坛，gen* 与 apply* 都在 forum.R 里。
             "forum.R",
             # syncservers.R（V16.6 item 1）是「信息同步跳板」那张表 +
             # app_settings 这个 KV。sync.R 那边要读"允许同步建号"这个开关
             # （dsapp_sync_allow_create），db.R 的 schema 分发里要建它的两张表
             # —— 两条都是**运行时**调用，所以顺序上只要排在 sync.R / db.R
             # 被调用之前就行。放在这里是因为它和 sync.R 是同一条线上的东西。
             "syncservers.R",
             "sync.R",
             # proxy.R（Test_V16.3 item 2）紧挨着 llm.R：它给 llm.R / executor.R
             # 提供"这一次请求从哪条线路出去"的那几个函数，还负责在 db.R 的
             # schema 分发里建 user_proxy 表。
             # ⚠️ 忘了列在这里的后果**不是报错**：dsapp_db() 跑到
             #    dsapp_db_schema_proxy() 时才是 "could not find function"，
             #    而那已经在建库路上了 —— 表现是"应用起不来"，报错指向 db.R。
             #    2026-10-04 就是这么被 app.R 那条覆盖断言当场逮住的
             #    （自检早说过"R/ 下每个文件都要在这份列表里"）。
             "models.R", "llm.R", "proxy.R", "jobs.R",
             # taskrun.R（V13.7 item 5）紧挨着 jobs.R：它是在 jobs.R 之上
             # 的那一层 —— 提交一次执行、执行结束之后的收尾。拆出来是因为
             # 脱离会话的后台续跑（R/detach.R）要**走同一条路**，不能抄
             # 第二份（抄了就会有一条路少一道闸，而少的那条偏偏是没人盯着
             # 的那条）。理由写在这个文件顶部。
             "taskrun.R",
             # ⚠️ detach.R **必须**列在这里。写它的时候我就漏过一次：那条
             #    「deploy.sh 有没有漏掉 app.R 会 source 的文件」的断言当场
             #    变红，报的是「deploy.sh 有但 app.R 不 source: detach.R」。
             #    所以那条断言查的是**两份清单互相一致**，它救不了"两份都漏"，
             #    但两次都是一份漏、另一份在 —— 这个不对称正是它管用的地方。
             #
             #    它必须在 taskrun.R 之后：里面调的 dsapp_task_submit /
             #    dsapp_task_closeout / dsapp_task_slot_busy 都在那儿。
             "detach.R",
             "render.R",
             # health.R / filters.R 只依赖 utils.R 和 config.R，位置随意；
             # 放这里是为了和别的服务层文件挨着。
             #
             # ⚠️ filters.R 是 #46 加的，当时**漏在了这个列表外面**：本地怎么
             #    跑都对，因为 Shiny 自己会把 R/ 下的文件全部 source 一遍，
             #    这个列表是第二条路。可它一旦是唯一那条路（换启动方式、
             #    换部署形态），mod_tasks_ui 里的 DSAPP_TASK_STATUS_CHOICES
             #    就是"找不到对象"，整个应用起不来。现在由 selftest 盯着
             #    这份列表和 deploy.sh 的清单一一对应，别再靠人记得。
             "health.R", "filters.R",
             # users.R 放在 db.R 之后：它建的表要跟着 db 的 schema 一起补齐，
             # 而且它自己会调 dsapp_db()
             "users.R",
             # tos.R（V9 item 1）紧挨着 users.R：它给 users 表加两列
             # （tos_version / tos_agreed_at）并建 consent_log，属于
             # "账号相关的表结构"，和 users.R 是一套。db.R 的 schema 函数
             # 里调它，所以它必须和 users.R 一样在这份列表里 ——
             # 漏了的后果见下面 nodes.R 那段的说明。
             "tos.R",
             # skins.R（V8 item 4）放这儿：它要读 users.skin，所以得在 users.R
             # 之后；它自己也是一个"服务层"文件（有哪几个皮肤、存哪儿），
             # 颜色全在 www/skins.css，不在 R 这边。
             "skins.R",
             # uiprefs.R（V13.2 item 5）是"面板宽高可自定义"的数据层：有哪
             # 几个尺寸、各自默认/上下限、某账号调成了多少。放在 skins.R
             # 后面 —— 它和皮肤是同一类东西（每账号一份的**外观**偏好），
             # 而且和皮肤一样要往 <html> 上挂 CSS 变量。
             "uiprefs.R",
             # skills.R（V8 item 1）是技能库的数据层 + 拼提示词那一段。
             # 放在 users.R / skins.R 之后、mod_*.R 之前：它自己建表（跟着
             # dsapp_db_schema 一起补齐），对话页和技能页都要调它。
             "skills.R",
             # ⚠️ nodes.R / audit.R 曾经**漏在这份列表外面**：两边（这份列表和
             #    deploy.sh 的清单）都漏了，于是它们互相点头说没问题，而
             #    "R/ 下的文件必须都在这里"这条真正的不变式没人查。
             #    今天不炸只是因为 Shiny 启动时会把 R/ 全部 source 一遍 ——
             #    这份列表是第二条路。它一旦成为唯一那条路（换启动方式、
             #    换部署形态，比如 Rscript app.R），漏掉的文件就是"找不到
             #    对象"，整个应用起不来。selftest 现在盯着这条不变式。
             "nodes.R", "audit.R",
             # logins.R（V11 item 4b，单端登录）放在 users.R / audit.R 附近：
             # 它建 login_sessions（跟着 db.R 的 schema 一起补齐），读的是
             # users.token，写的是"这个账号当前那一端是谁"。db.R 的 schema
             # 函数里调它，所以它必须在这份列表里 —— 漏了的后果见上面
             # nodes.R / audit.R 那段的说明。
             "logins.R",
             # envfix.R（V11 item 8）是"这次失败算不算环境问题"的判定表，
             # agent.R 的 dsapp_agent_tool_text() 直接调它 —— 必须排在
             # agent.R 前面。
             "envfix.R",
             # selfheal.R（V13.7 item 2）是"平台自己能修的就别问用户"那一套。
             # 摆在 envfix.R 旁边是因为两者是一对：envfix 管**任务执行**挂了，
             # selfheal 管**平台自身**挂了（写库、刷新、选环境）。读者不同，
             # 顶部的注释里写明了不许互相调用。两个 mod_* 都在用它，
             # 所以必须在 mod_chat.R 前面。
             "selfheal.R",
             # agent.R 要在 mod_chat.R 之前：后者在 setup 里就实例化状态机
             "agent.R",
             # teams.R（V13 item 3）必须在 share.R 前面：共享弹窗要拿
             # 「谁和我同组」筛那个短名单。
             "teams.R",
             # share.R 是对话共享的唯一实现，对话页和任务页都调它 ——
             # 必须排在两个 mod_*.R 前面
             "share.R",
             # ★ Test_V15.2：mail.R / litsub.R 排在**所有 mod_*.R 之前**、
             #   share.R 之后，这两个位置都是必须的：
             #     · mail.R 要调 dsapp_md_html（render.R）和 dsapp_html_inline
             #       （files.R），那两个都在很前面 —— 排在 share.R 这里够用。
             #     · litsub.R 要调 dsapp_mail_enqueue（mail.R，紧挨着它前面）
             #       和 dsapp_bg_start（jobs.R，也在前面）。
             #   ⚠️ 反过来，这两个文件**不许依赖任何 mod_*.R**：定时任务要在
             #      没有 Shiny 的 Rscript 里 source 它们（run_scheduler.R 和
             #      .dsapp_agent_worker 都是"跳过 mod_ 再 source"），
             #      一旦引用了 UI 模块，调度器就是 could not find function。
             "mail.R", "litsub.R",
             "mod_chat.R", "mod_tasks.R", "mod_files.R", "mod_envs.R",
             # mod_model.R 必须在 mod_settings.R 前面：设置页那张「模型服务」
             # 卡片是**指向**左侧栏的说明，它引用的概念在 mod_model.R 里。
             "mod_model.R", "mod_settings.R",
             # 帮助页（V13.14 item 23）。原来是 mod_settings.R 里的第四个页签，
             # 搬成了左栏独立的一页。挨着 mod_settings.R 放是为了让"它从哪来"
             # 一目了然；顺序上没有依赖（这一页没有 server，也不调别的模块）。
             "mod_help.R",
             # 技能库页（V8 item 1）。放在 mod_chat.R 之后：对话页只调
             # skills.R 里的函数，不调这个模块，所以顺序其实无所谓 ——
             # 挨着放只是为了"技能相关的两个文件在一处"。
             "mod_skills.R",
             # 文献速递（V13.11 item 5）。排在 mod_chat.R 后面是**必须**的：
             # 这一页自己不发送，它把活交给对话页 —— 那三种做法（新建对话、
             # 发第一条消息、挂技能）全在 mod_chat.R 的 lit_go 观察器里，
             # 这里只负责把条件拼成提示词。
             #
             # ⚠️ 新加一个 R/ 下的文件要**同时**改两处（原来是三处，第 3 处
             #    已经不需要人管了，见下）：
             #      1. 这份列表（有断言盯着"覆盖 R/ 下每一个文件"）
             #      2. deploy.sh 的清单（有断言盯着"两份清单互相一致"）
             #    ⚠️ 注意那两条断言**管不着对方**：一份清单漏、另一份也漏，
             #       setequal 照样绿；只有"覆盖 R/ 下每一个文件"那条能抓。
             #       所以改完要按 R/ 目录本身对一遍，不能只看断言绿没绿。
             #
             #    （原第 3 处：selftest.R 顶部那份 mod_*.R 的 source 列表。
             #      V13 之后那里改成了"顺序清单 + 兜底 source 剩下的所有
             #      mod_*"，非 mod_ 的又本来就全 source —— 也就是说自检现在
             #      自己会捡起新文件，不用再改。当年漏掉 mod_lit.R 的表现是
             #      "could not find function mod_lit_ui"，而报错的是 V6 那几条
             #      渲染断言，离现场十万八千里。）
             "mod_lit.R",
             # 论坛（V15 item 8）。**唯一一处"内容本身是公共的"页面** ——
             # 其余模块的数据都按 user_id 归属，只有这里的东西天生是
             # 一人发、多人看。同步的公共段怎么切见 R/forum.R 顶部。
             "mod_forum.R",
             # 入口页（注册/登录）与管理页
             "mod_welcome.R", "mod_admin.R",
             # 后台页（V13.8 item 2）。**只有平台管理员**看得到 ——
             # 账号的增删、级别的升降、硬件资源的分配都在那儿。
             # ⚠️ 它排在 mod_admin.R 后面是刻意的：两页有重叠的动作
             #    （停用、重置密码），共用 R/users.R 里那批函数，
             #    待在一起方便对照着看，顺序本身没有依赖。
             "mod_htadmin.R",
             # ★ V15.4 item 7：把上面两页合成「后台管理」的那一层
             #   （只有 UI：四个子页签把 14 张卡片重新归类）。
             #   ⚠️ 它必须排在 mod_admin.R / mod_htadmin.R **后面** ——
             #      它在自己的 UI 函数里现调 mod_admin_cards() /
             #      mod_htadmin_cards()，那两个函数得先存在。
             #      （真排在前面也不报错，是"点击后台管理页一片空白"，
             #       因为 source 是顺序执行的，那时函数还没定义。）
             "mod_backstage.R",
             # ★ V15.4 item 8：系统提示词编辑器（后台管理的最后一个子页签）。
             "mod_prompt.R",
             # ★ V15.8 item 2：云工具（结合蛋白设计流水线的 GUI）。
             #   cloudtool.R 是那一页的**纯函数层**（参数判据、命令拼接、
             #   结果收割、建议），mod_cloudtool.R 只是它的界面 ——
             #   两份都必须在清单里：漏了 cloudtool.R 的表现是这一页
             #   "could not find function dsapp_cloud_step_script"，
             #   而它是打开页面才炸的，不是启动即崩。
             # ★ V16.6 item 4：云工具的**执行体**注册表。用户原话
             #   「云工具是有GUI的工具，而不是接入言出法随界面给提示词」——
             #   cloudtool.R 只把文档解析成"有哪些工具"，这一份才是
             #   "每个工具点下去拿什么参数、跑什么脚本、出什么产物"。
             #   ⚠️ 它必须排在 cloudtool.R **后面**：文件头就调
             #      `dsapp_cloudreg_kind()`（source 是顺序执行的，
             #      但这里只是定义函数、不调用，真排在前面也不会崩 ——
             #      之所以钉住顺序，是因为自检里会按这个顺序读源码）。
             "cloudtool.R", "cloudrun.R", "mod_cloudtool.R")
  for (f in files) {
    p <- file.path("R", f)
    if (file.exists(p)) source(p, local = globalenv())
  }
})

cfg <- dsapp_config()
dsapp_init_dirs(cfg)

# ★ V13.10 item 1：全局错误兜底，**必须在这里**（任何 session 建立之前）。
#   onUnhandledError 的全局回调只对注册之后新建的 session 生效，放进
#   server() 里就只兜得住那一个 session 了。理由见 R/errhand.R 文件头。
dsapp_err_init()

# Shiny 默认只收 5MB 上传，生信数据动辄几百 MB。这个值必须在这里设，
# 在 server 函数里设已经晚了 —— 请求体在校验时就被拒了。
options(shiny.maxRequestSize = cfg$max_upload_mb * 1024^2)

# ⚠️ V13 item 6：这里原来有一句 `addResourcePath("files", cfg$files_dir)`，
#    文件预览走那条静态路由。**删掉了** —— 管理区按账号隔离之后，静态路由
#    （进程级、对所有登录用户生效）等于把隔离绕过去：换个账号把 URL 里的
#    路径一改就能下载别人的文件。现在预览一律走 session$registerDataObj
#    （见 files.R 的 dsapp_preview_url）。
#
#    别把它加回来。要加也得先想清楚"这个目录是不是所有账号都能看"，
#    而管理区现在的答案永远是否。
# 导出包下载走这个路由（mod_chat.R 里用 "exports/<文件名>"）
if (dir.exists(cfg$export_dir)) {
  addResourcePath("exports", cfg$export_dir)
}
# 平台 logo（V10 item 3）。R/utils.R 的 dsapp_logo_url() 里用 "dsapplogo/<文件名>"
# 引用它。**不能**直接放进 www/ —— 那个目录随代码走（归档、换台机器都带着），
# 而 logo 是这台部署自己的 VI；详见 utils.R 里那段说明。
if (dir.exists(cfg$logo_dir)) {
  addResourcePath("dsapplogo", cfg$logo_dir)
}

# 先给 CPU 采一次基线。管理页的 CPU 使用率是**两次 /proc/stat 采样相减**
# 算出来的，而这里绝不能为了拿第二次采样去 Sys.sleep —— 全站只有一个 R
# 进程，sleep 0.5 秒就是所有人的界面卡 0.5 秒（详见 R/health.R 文件头）。
# 所以基线在启动时取：等管理员第一次打开管理页，差值已经有意义了。
tryCatch(dsapp_health_prime(), error = function(e) NULL)

# ---- 启动清理 ---------------------------------------------------------------

local({
  # 1) 上次进程退出时正在跑的任务，状态会永远停在 "running"，页面上看就是
  #    一个转不完的圈。进程都没了，任务不可能还在跑。
  tryCatch({
    stuck <- DBI::dbGetQuery(dsapp_db(cfg),
      "SELECT id FROM tasks WHERE status = 'running'")
    for (id in stuck$id) {
      db_task_status(id, "error", exit_code = NA_integer_,
                     stderr = "应用重启，任务被中断",
                     con = dsapp_db(cfg))
    }
    if (nrow(stuck) > 0) {
      message(sprintf("[dsapp] 已将 %d 个中断的任务标记为失败", nrow(stuck)))
    }
  }, error = function(e) {
    message("[dsapp] 启动清理跳过：", conditionMessage(e))
  })

  # 1b) 上次进程退出时还"正在后台续跑"的对话（V13.7 item 5）。
  #     和上面那条同一个道理，只是换了一张表：后台续跑的子进程是
  #     callr::r_bg(supervise = TRUE) 起来的，挂在**本进程**上，本进程被
  #     systemctl restart 掉的时候它跟着一起没了。不清的话，对话页顶上会
  #     一直挂着「AI 正在后台接着跑」的横幅，而实际上什么都没有在跑 ——
  #     用户等一整天也等不到结果，还会因为没有「停止」之外的反馈而反复回来刷。
  #
  #     ⚠️ 必须在**会话起来之前**跑（这里是 app.R 顶层，还没有任何会话），
  #        否则用户可能先看到一个假的"正在跑"再看到它消失。
  tryCatch(dsapp_arun_sweep_orphans(cfg), error = function(e) {
    message("[dsapp] 后台续跑清理跳过：", conditionMessage(e))
  })

  # 2) 残留的 SSH 凭据目录。
  #    正常路径下 dsapp_ssh_cleanup() 会删掉它，但进程被 kill -9 就轮不到
  #    清理了。凭据只该活在一次调用的时间里，所以启动时无条件扫一遍。
  #    这个清理是安全属性，不是空间清理 —— 别改成只删旧的。
  tryCatch({
    leftovers <- list.files(cfg$run_dir, pattern = "^\\.ssh-", full.names = TRUE,
                            all.files = TRUE)
    for (d in leftovers) unlink(d, recursive = TRUE, force = TRUE)
    if (length(leftovers)) {
      message(sprintf("[dsapp] 已清理 %d 个残留的 SSH 凭据目录",
                      length(leftovers)))
    }
  }, error = function(e) NULL)

  # 3) 导出包。下载完就没用了，但没人会回来手动删。
  tryCatch({
    n <- dsapp_export_gc(cfg)
    if (n > 0) message(sprintf("[dsapp] 已清理 %d 个过期导出包", n))
  }, error = function(e) NULL)

  # 4) 孤儿工作区和 run/ work/ 里的中转文件（见 R/gc.R 顶部的约束说明）。
  #
  #    ⚠️ 必须排在**第 1 步之后**。第 1 步会把上次残留的 'running' 任务标成
  #       失败，而本步的年龄下限（10 分钟）正是照着"这些任务刚被收尾"设的：
  #       一个还在写结果的子进程留下的文件不该在这一轮被删掉。
  tryCatch({
    g <- dsapp_gc(cfg, min_age_mins = 10)
    if (g$ws_n > 0) {
      message(sprintf("[dsapp] 已清理 %d 个孤儿工作区，释放 %s",
                      g$ws_n, dsapp_fmt_bytes(g$ws_bytes)))
    }
    if (g$scratch_n > 0) {
      message(sprintf("[dsapp] 已清理 %d 个中转文件，释放 %s",
                      g$scratch_n, dsapp_fmt_bytes(g$scratch_bytes)))
    }
    if (isTRUE(g$audit_n > 0)) {
      message(sprintf("[dsapp] 已清理 %d 条过期操作日志", g$audit_n))
    }
    for (e in g$errors) message("[dsapp] 启动清理：", e)
  }, error = function(e) {
    message("[dsapp] 启动清理出错（不影响启动）：", conditionMessage(e))
  })

  # 5) 同步收件箱（V13.3 item 2）。
  #
  #    ★ 为什么服务器这边**没有守护进程**、而是"用的时候才看一眼"：
  #      收件箱里躺着的包，是桌面版通过 scp 放上来的。SYNC.md §4.4 把
  #      "服务器端的收件箱谁来应用"标成了"必须在动手前定"——三条路都勘察
  #      过，结论是不引入常驻进程（理由写在 R/sync.R 顶部第三节）。
  #
  #      关键在于：**服务器上的数据变化，必然是"有人用了网页版"产生的**
  #      （服务器自己不会凭空写对话）。而"有人用了网页版"就意味着这个钩子
  #      已经跑过了。反过来，没人打开网页版的时候，也没人在等新数据 ——
  #      所以"延迟"的上界恰好是"下一次有人看"，也就是这件事真正被需要的
  #      时刻。这是这条设计成立的全部理由，别把它改成轮询。
  #
  #    启动时先跑一次（force = TRUE），是因为这一次的进程内缓存还是空的；
  #    真正的日常触发在 server() 里那个每会话的观察者上。
  #
  # ★ V13.7 item 7：启动这一次**什么都应用不了**，是有意的。同步包要验签，
  #   而密钥只在"某个账号正在登录"的时候才存在于内存里（R/synckey.R）——
  #   进程刚起来时一个账号都没登录，所以这一趟必然把包全部挂起。
  #   它留着只有一个用处：把两边目录配错时产生的"自己发的包"挪走，
  #   免得它们永远躺在收件箱里每轮重试。真正的应用发生在下面的会话里。
  tryCatch({
    n <- dsapp_sync_maybe_apply(cfg, force = TRUE)
    if (n > 0) message(sprintf("[dsapp] 已应用 %d 个同步包", n))
  }, error = function(e) {
    message("[dsapp] 同步收件箱处理失败（不影响启动）：", conditionMessage(e))
  })

  # 6) 学到的参数上限（V15.3 item 2）。
  #
  #    厂商在 400 里说的真实上限（如 "max_tokens must be at most 65536"）由
  #    用户点「直接帮我设置」写进 model_param_limits 表；那一头只能更新
  #    **当时那个进程**的内存（见 R/models.R 的 dsapp_param_learned_put）。
  #    所以每个新进程起来时都要把库里的记录灌一遍，否则下次开新会话量程
  #    又回到 1M，用户会在同一个地方再撞一次 400。
  #
  #    ⚠️ 必须在**会话起来之前**跑：worker 是每个 R 进程一批，用户第一条
  #       消息就可能带着 max_tokens 出去，晚了这一条就用的是旧量程。
  #    ⚠️ 读不出来**不算错**（当作"什么都没学到"）—— 那是安全的那一侧：
  #       量程宽一点顶多让用户再撞一次 400 并当场学会，不会拦住合法请求。
  #       所以这里连同 dsapp_db() 一起包在 tryCatch 里：进程刚起来时库还
  #       没建好也不该让整个 app 起不来。
  tryCatch({
    con <- dsapp_db(cfg)
    if (isTRUE(dsapp_param_learned_load(con))) {
      message("[dsapp] 已载入学到的模型参数上限")
    }
  }, error = function(e) {
    message("[dsapp] 载入参数上限失败（不影响启动）：", conditionMessage(e))
  })

  # 7) 系统提示词的分节覆盖（V15.4 item 8）。
  #
  #    和上一条同一个道理、同一个位置：超管在后台改的是**某一个**会话进程的
  #    内存 + 库，而这条请求可能落在另一个进程上。新进程起来时灌一遍，
  #    "改完刷新一下就生效"才成立。
  #
  #    ⚠️ 读不出来**不算错**：那就用内置默认，正是"没人改过"的样子。
  #       表还没建起来（旧库第一次跑新代码）时也走这一支 —— 建表的活是
  #       dsapp_db() 里的 dsapp_db_schema() 干的，上面那句已经调过了。
  tryCatch({
    con <- dsapp_db(cfg)
    dsapp_prompt_load(con)
  }, error = function(e) {
    message("[dsapp] 载入提示词覆盖失败（用内置默认）：", conditionMessage(e))
  })

  # 8) 信息同步跳板的**出厂清单**（V16.6 item 1）。
  #
  #    桌面版是打包发出去的：一批机器开箱就该知道"默认连哪台中转服务器"，
  #    而这没法靠用户手打（那正是跳板这张表想省掉的事），也没法靠同步包带
  #    （清单里是地址、用户会照着它输 SSH 密码，一份**没签名**的地址清单
  #    等于钓鱼入口 —— 完整取舍写在 R/syncservers.R 第四节）。
  #
  #    所以走**出厂**：打包时把 desktop/jump_servers.json 放进发行目录，
  #    第一次启动种进 sync_servers。**幂等**：表里已经有条目就什么都不做，
  #    管理员删掉一条之后不会下次启动又被推回来。
  #
  #    ⚠️ 读不出来**不算错**：没有这个文件是绝大多数情况（服务器版就没有），
  #       它不该在启动日志里刷出一行像故障的东西。
  tryCatch({
    n <- dsapp_syncservers_seed(cfg = cfg, con = dsapp_db(cfg))
    if (n > 0) message(sprintf("[dsapp] 已从出厂清单种入 %d 条同步跳板", n))
  }, error = function(e) {
    message("[dsapp] 种入出厂跳板清单失败（不影响启动）：", conditionMessage(e))
  })
})

# ---- 执行引擎 ---------------------------------------------------------------

# 整个应用一份（不是每个会话一份）：任务在数据库里是全局的，界面上也应当
# 一致 —— A 用户提交的任务，B 用户打开任务页就能看到它在跑。
#
# 收尾（写数据库、更新状态）由任意一个会话的轮询触发，先到先做，
# 靠 e$handle 置空来保证只做一次。
dsapp_engine_new <- function(cfg) {
  e <- new.env(parent = emptyenv())

  # "是否忙"有两个副本，是有意的：
  #   e$busy  —— 普通逻辑值，是**唯一**的判断依据
  #   e$state —— reactiveValues，只给界面读，驱动"运行中"横幅刷新
  #
  # 判断为什么不用 e$state$running：在响应式上下文之外读 reactiveValues 会
  # 直接报错（"Can't access reactive value outside of reactive consumer"），
  # 而 e$start() 的调用点未必都在 observeEvent 里。用普通标志做判断，
  # 这个函数在任何地方都能调，也好写测试。
  e$busy   <- FALSE
  e$state  <- reactiveValues(running = FALSE, task_id = NULL, label = NULL)
  e$handle <- NULL

  #' 当前是否有任务在跑（非响应式）
  e$is_busy <- function() isTRUE(e$busy)

  #' 引擎此刻占着哪个任务 id（非响应式），空闲时返回 NULL
  #'
  #' agent 循环用它兜底判断"这个任务还归引擎管吗"。光看数据库不够：
  # 那一行可能被用户删了，也可能因为写库失败停在 running。
  # 不要用 e$state$task_id —— 那是 reactiveValues，在响应式上下文之外读
  # 会直接报错（理由见上面 e$busy 的说明）。
  e$current_task_id <- function() {
    if (is.null(e$handle)) NULL else e$handle$task_id
  }

  #' 提交任务。返回 list(ok, msg, task_id)
  #'
  #' target 决定去哪儿跑，见 utils.R 的 dsapp_target_label()：
  #'   list(kind = "server", env = "system"|"<conda 环境名>")
  #'   list(kind = "remote", remote = list(host, port, user, auth, ...))
  #' kind = "local" 不在这里处理 —— 它不执行代码，走 export.R。
  #'
  #' title 传 NULL（默认）就自动起名「任务功能_所属会话」（V9 item 7）。
  #'
  #' ⚠️ 起名放在 dsapp_task_submit() **里面**，不放在各个调用点上。调用点
  #'    有三个（对话页手动执行、agent 自动执行、脱离会话的后台续跑），
  #'    各写一遍的话，将来加第四条路必然漏一个，而漏掉的表现是那一类任务
  #'    又变回「R 代码」—— 界面上看不出哪里错了，只是有些行认不出来。
  #'
  #' ⚠️ 引擎**只管"这一槽腾没腾出来"**（e$busy 是进程内的一个标志位）。
  #'    跨进程的那个约束是另一回事，见 R/taskrun.R 的 dsapp_task_slot_busy()。
  e$start <- function(code, lang, title = NULL, session_id = NA_character_,
                      target = list(kind = "server", env = "system"),
                      user_id = NULL) {
    if (isTRUE(e$busy)) {
      # ★ V16.1 item 6：这句原来只有"已有任务正在执行"，不说是**哪一个**、
      #   也不说去哪儿看。用户的原话正是：「我点确认执行，显示已有任务在执行，
      #   但是我看不到任何提示任务在执行的痕迹」—— 一句拦路的话本身不构成
      #   "痕迹"，它只说"不行"，不告诉他人往哪儿看。
      #
      #   现在把任务号点出来：界面上那颗浮标（output$busy_badge）和侧栏徽章
      #   报的是**同一个号**，两边能对上，用户就知道该去哪儿找。
      #
      # ⚠️ 措辞里那个「正在执行」**不能删**：R/agent.R 的 a$try_submit() 靠
      #    grepl("正在执行", res$msg) 认出"忙"这一类失败（它要据此决定是等
      #    还是当失败），改掉的话两边都变哑巴，而且不报错。
      tid <- tryCatch(e$current_task_id(), error = function(err) NULL)
      return(list(ok = FALSE, msg = if (is.null(tid)) {
        "已有任务正在执行，请等它结束（到「历史任务」页可以看到它的实时输出）"
      } else {
        sprintf("已有任务正在执行（任务 #%s），请等它结束；到「历史任务」页可以看到它的实时输出", tid)
      }))
    }
    # ★ V13.7 item 5：扫描 / 配额 / 环境校验 / 建行 / 起作业这五步已经搬进
    #   R/taskrun.R 的 dsapp_task_submit()。搬家的理由不是"文件太长了"——
    #   是**脱离会话的后台续跑也要走这条路**（R/detach.R），而抄第二份的
    #   代价是"某一条路少一道闸"，且少的那条偏偏没人盯着。
    #   搬走的那些注释（为什么扫描要在唯一入口上、配额为什么只能判"已经
    #   超了"、session_id 为什么决定工作区）都在那边。
    sub <- dsapp_task_submit(code, lang, title = title, session_id = session_id,
                             target = target, user_id = user_id, cfg = cfg)
    if (!isTRUE(sub$ok)) return(list(ok = FALSE, msg = sub$msg))

    tid <- sub$task_id
    handle <- sub$handle
    e$handle <- handle
    e$busy <- TRUE
    e$state$running <- TRUE
    e$state$task_id <- tid
    e$state$label <- dsapp_target_label(target)

    # 起任务留痕。**只记坐标，不记代码**（见 R/audit.R 顶部第 1 条）：
    # 管理员需要知道"谁在什么时候往哪个环境提交了任务"——磁盘和 CPU 突然
    # 被吃满时这是第一条线索 —— 但代码本身是用户的分析内容，不进日志。
    dsapp_audit("task_submit", user_id = user_id, target = sprintf("任务 #%d", tid),
                detail = sprintf("%s · %s · 对话 %s", lang,
                                 dsapp_target_label(target),
                                 session_id %||% "—"),
                cfg = cfg)
    list(ok = TRUE, task_id = tid)
  }

  #' 轮询。返回 NULL（还在跑）或 list(task_id, status)
  e$poll <- function() {
    if (is.null(e$handle)) return(NULL)

    res <- tryCatch(dsapp_job_poll(e$handle),
                    error = function(err) list(done = TRUE, alive = FALSE,
                                               result = NULL))
    if (!isTRUE(res$done)) return(NULL)

    h  <- e$handle
    e$handle <- NULL            # 先置空：保证收尾只做一次
    tid <- h$task_id

    # ⚠️ 状态复位走 on.exit，不能跟着写库走。
    #
    # 下面那句 dsapp_task_closeout() 是会抛的：SQLite 忙过 busy_timeout、
    # 磁盘满、外键冲突都会。它一抛，后面的 e$busy <- FALSE 就永远执行不到 ——
    # 而 e$handle 已经在上面置空了，于是之后每次 poll 都在第一行 return(NULL)，
    # e$busy 永远停在 TRUE：所有新任务被拒，observer 每秒空转一次，"运行中"
    # 的横幅再也不消失。只有重启应用能解。
    #
    # 状态复位和写库本来就是两件事：写库失败顶多任务页少一行记录，引擎该
    # 腾出来还得腾出来。
    on.exit({
      e$busy <- FALSE
      e$state$running <- FALSE
      e$state$task_id <- NULL
      e$state$label <- NULL
    }, add = TRUE)

    # ★ V13.7 item 5：写状态 / 记产物 / 同步进文件管理区这三步搬进了
    #   R/taskrun.R 的 dsapp_task_closeout()，理由和 e$start 那边一样 ——
    #   脱离会话的后台续跑必须走同一条路。原来那些注释（产物索引为什么
    #   要整段包 tryCatch、同步为什么放在下游而不是 executor 里）都在那边。
    dsapp_task_closeout(tid, res$result, cfg = cfg)
  }

  #' 中止
  #'
  #' reason 会写进任务行的 stderr，任务页上要能看出"这是被停掉的"，
  #' 而不是"跑挂了"。
  e$abort <- function(reason = "已手动停止") {
    tid <- if (is.null(e$handle)) NULL else e$handle$task_id
    if (!is.null(e$handle)) {
      dsapp_job_abort(e$handle)
      e$handle <- NULL
    }

    # ⚠️ 中止也必须写终结状态。
    #
    # 以前这里只杀进程、只复位内存，数据库那行永远停在 'running'：任务页上
    # 是一个转不完的圈，要等到下次应用重启被启动清理标成"应用重启，任务被
    # 中断"—— 一句假话，它明明是被用户停掉的。
    #
    # agent 循环更会因此卡死：循环的等待条件是"这一行变成终结态"，而中止过
    # 的行永远不会变。写不进去不该让中止本身失败，所以包 tryCatch。
    if (!is.null(tid)) {
      tryCatch(
        db_task_status(tid, "error", exit_code = NA_integer_,
                       stderr = reason, con = dsapp_db(cfg)),
        error = function(err) NULL)
      # 中止留痕。任务被谁按停的、什么理由（"已手动停止" / "对话已删除" /
      # "应用关闭"），事后看任务页只有一句 stderr，分不出是谁干的。
      dsapp_audit("task_cancel", target = sprintf("任务 #%d", tid),
                  detail = reason, cfg = cfg)
    }

    e$busy <- FALSE
    e$state$running <- FALSE
    e$state$task_id <- NULL
    e$state$label <- NULL
    invisible(TRUE)
  }

  e
}

engine <- dsapp_engine_new(cfg)

# ---- 界面 -------------------------------------------------------------------

#' 主题（codex 风格，item 2）
#'
#' 深色、低饱和、等宽字体打底 —— 参考 codex CLI / 终端 TUI 的观感，
#' 不是"给浅色主题加个暗色开关"。
#'
#' ⚠️ 用 bs_theme() 生成，**不要**改成写死的 CSS。整套 Bootstrap 的
#'    --bs-* 变量都由它算出来（前景/边框/次级背景/各语义色的 -subtle
#'    和 -text-emphasis 变体），app.css 里几十条规则引用的都是这些变量。
#'    手写一套的话，漏掉一个变量就会有一块地方在深色下变成黑字黑底 ——
#'    而且只在某个具体控件上出现，翻遍 CSS 也找不到。
#'
#' ⚠️ 语义色（primary/success/warning/danger）在这套里必须**提亮**。
#'    Bootstrap 默认的 #0d6efd / #dc3545 是给白底配的，放在 #0d1117 上
#'    饱和度刺眼、对比度反而不够。下面这组是照着 GitHub 暗色主题的
#'    取值调的。
#'
#' ⚠️⚠️ 这个函数**必须定义在 app_ui 前面**，不能图省事挪到后头去。
#'    app_ui 是**顶层 tagList**（不是 function），source() 到那一行就当场
#'    把它构造出来，于是 app_ui 里那次 dsapp_theme() 调用是在**源码求值
#'    阶段**发生的 —— 定义在它后面 = "could not find function"，
#'    整个应用起不来（不是某个功能坏掉，是白屏）。
#'    2026-09-14 V6 就这么炸过一次：改主题时把这段挪到了 dsapp_main_ui
#'    旁边，位置看着更"就近"，实际是在 app_ui 后面，runApp 直接退出。
#'
#'    这一条现在有测试守着（selftest 里真的 source 一遍 app.R），
#'    但仍然别挪 —— 那条测试也是刚加的。
dsapp_theme <- function() {
  # 中文优先的字体栈：这一版很多字是中文，只给西文字体会掉进系统默认的
  # 宋体/黑体回退，字重和行高都对不上。
  ui_font <- paste0("system-ui, -apple-system, 'Segoe UI', ",
                    "'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', ",
                    "'Source Han Sans SC', sans-serif")

  bs_theme(
    version = 5,
    # 不用 bootswatch：它的暗色预设（darkly/cyborg）改的是整套字体和圆角，
    # 会和 app.css 里已经调好的间距打架。直接用 bs_theme 给变量。
    bg = "#0d1117", fg = "#e6edf3",
    primary = "#3fb950", secondary = "#8b949e",
    success = "#3fb950", info = "#58a6ff",
    warning = "#d29922", danger = "#f85149",
    base_font = ui_font,
    heading_font = ui_font,
    code_font = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace",
    # 圆角收小：codex 那套是方块感，不是气泡感
    `border-radius` = "6px",
    `border-radius-sm` = "4px",
    `border-radius-lg` = "8px"
  )
}

# ⚠️⚠️ 这一行**不是**可有可无的样式设置。删掉它，左侧栏的每一个导航项都会
#     点不动 —— 不报错，就是没反应。V6 上线前就是这么瘫的。
#
#     链条有四环，任何一环单看都是对的：
#
#     1) bslib 给页签锚点加 class="nav-link" 是靠一个 **render hook**，渲染
#        那一刻才跑，判据是 `getCurrentThemeVersion() >= 4`。
#     2) `getCurrentThemeVersion()` → `shiny::getCurrentTheme()` →
#        就是 Shiny 的 option `bootstrapTheme`。我们的 app_ui 是个裸
#        tagList（不是 fluidPage(theme=)，主界面还是 renderUI 出来的），
#        没人设过这个 option，于是它返回 NULL，bslib 落到 "3"。
#     3) 于是锚点渲染成 BS3 的样子：`<li class=active><a data-toggle=tab>`，
#        **没有 nav-link**。
#     4) 可 Bootstrap 5 的 JS 是加载了的（bs_theme_dependencies），
#        Shiny 的 tab 绑定 `function Tl(){return !window.bootstrap}` 因此
#        走 **BS5 分支**去数 `.nav-link...active` —— 数到 0 个，
#        `getValue()` 直接 `return null`。
#
#     结果：input$nav 永远是 NULL，bslib::nav_select("nav", ...) 静默不生效
#     （它内部 sendInputMessage 到客户端，绑定认不出这个值）。左栏的点击、
#     对话页/设置页里那些 nav_select 跳转，全部一起哑掉。
#
#     2026-09-14 用四组最小复现一步一步逼出来的（见 tests/ 里同名现象的
#     浏览器断言）。**页面渲染看起来完全正常**，所以靠肉眼看是发现不了的：
#     深色主题在、左栏在、页签在，就是点不动。
#
#     这一行只负责"告诉 bslib 现在用的是哪一版"，真正的 CSS/JS 仍然由 app_ui
#     里的 bs_theme_dependencies(dsapp_theme()) 提供，两者都必须有，而且要传
#     **同一个** theme 对象。
#
#     ⚠️ 用 shinyOptions() 而不是 shiny::setCurrentTheme() —— 后者是内部
#     函数（`shiny:::setCurrentTheme`），没导出，写了会直接
#     "not an exported object from 'namespace:shiny'"，应用起不来。
#     它俩的实现是同一件事：`shinyOptions(bootstrapTheme = theme)`。
shiny::shinyOptions(bootstrapTheme = dsapp_theme())

# 样式和脚本用 tagList 包在 page_navbar 外面，不能直接写进 page_navbar(...)。
#
# page_navbar 的 ... 是"导航面板列表"，塞进去别的东西 bslib 会告警
# （"Navigation containers expect a collection of nav_panel()..."），
# 虽然实测内容仍会被 Shiny 提升到 </head> 前、功能正常，但那是在依赖
# 未定义行为 —— 哪天 bslib 改成严格校验就会直接报错。
#
# www/ 目录由 Shiny 自动映射到应用根路径，所以这里用相对路径引用即可。
#
# ⚠️ id = "nav" 是给设置页/对话页互相跳转用的（bslib::nav_select）。
#    这个 id 没有命名空间 —— 模块里调用时要写 "nav" 而不是 ns("nav")。
app_ui <- tagList(
  tags$head(
    # ⚠️ 主题必须在**最顶层**，不能挂在 dsapp_main_ui() 里。V6 起主界面的
    #    返回值是塞进 uiOutput("app_root") 的，而 bootstrap 的 CSS 是
    #    htmlDependency —— 挂在 renderUI 的返回值上时，Shiny 会在渲染那一刻
    #    才把它插进 <head>，位置在任何静态 <link> 之后。登录页（另一棵完全
    #    独立的 UI 树）则完全拿不到主题，会白底黑字地杵在深色应用前面。
    #    放在这里，整个文档只有一份主题。
    bslib::bs_theme_dependencies(dsapp_theme()),

    # ⚠️ 必须走 dsapp_asset（它会挂一个随文件变的 ?v=），不能写裸文件名。
    #    线上踩过：浏览器缓存着旧的 app.js，登录逻辑全在那个文件里，
    #    服务端怎么改都没用。详见 R/utils.R 里 dsapp_asset 的说明。
    tags$link(rel = "stylesheet", href = dsapp_asset("app.css")),
    # codex 风格那层（V6 item 2）。单独一个文件而不是并进 app.css：
    # app.css 里是一整套**浅色**主题下写好的组件样式，两者混在一起之后
    # "这条规则属于哪层"就说不清了。这里只放深色专属的覆盖与新增的
    # 左侧栏/外壳样式。
    tags$link(rel = "stylesheet", href = dsapp_asset("codex.css")),
    # 皮肤那层（V8 item 4）。必须排在 app.css / codex.css **后面** ——
    # 它两个都要覆盖（app.css 里那批写死的浅色组件样式、codex.css 里的左栏）。
    #
    # ⚠️ 但"排在后面"**不足以保证**覆盖：bslib 会把组件自己的 CSS
    #    （bslib-component-css）作为 htmlDependency 插在所有静态 <link>
    #    之后，那部分谁也排不到它后面。所以 skins.css 里的选择器一律带
    #    `:root[data-skin=...]` / `html[data-skin=...]` 这个 (0,2,0) 的前缀，
    #    靠特异性而不是靠顺序赢。改那个文件时不要把这个前缀去掉。
    tags$link(rel = "stylesheet", href = dsapp_asset("skins.css")),

    # ---- 平台 logo（V10 item 3）-------------------------------------------
    #
    # 浏览器标签页上的那个小图标。**放这里而不是 www/ 里塞个 favicon.ico**：
    # 浏览器会自己去找 /favicon.ico 这件事只是惯例，实际生效的是这一行
    # <link rel="icon">；而 www/ 下的东西随代码归档，logo 不随。
    #
    # ⚠️ 没配 logo 时 dsapp_favicon() 返回 NULL，tagList 会把 NULL 直接跳过
    #    —— 不报错，也不留一行空的 <link href="">（那会让某些浏览器去请求
    #    应用根路径当图标，日志里多一堆 404）。
    dsapp_favicon(),

    # ---- 皮肤：**首屏之前**先把 data-skin 定下来 ---------------------------
    #
    # ⚠️ 这段内联 <script> 的位置是有讲究的，别挪到 app.js 里去。
    #    服务端要到 websocket 连上、登录闸门跑完才知道这个账号选的是哪个
    #    皮肤（见下面 server 里那条 observe）。等它把消息发回来，页面早就
    #    画完了 —— 用浅色皮肤的用户每次刷新都会先看见一帧深色，再"啪"地
    #    跳成浅色。内联脚本在解析到这一行时就执行，早于 <body> 里任何内容的
    #    绘制，所以首帧就是对的。
    #
    #    localStorage 是这条路唯一的真相来源，服务端那条消息（dsapp:skin）
    #    负责把两边对齐：换账号 / 换浏览器登录时以服务端为准，写回 localStorage。
    #
    #    ⚠️ 取值要和 R/skins.R 的 DSAPP_SKINS 对得上。这里**不做合法性校验**
    #       （不做也无所谓，CSS 匹配不上就整站回落到深色，不会白屏）——
    #       但拼字符串时一定要挡住引号：localStorage 是用户能改的，
    #       一个带 `"` 的值就能从这个 <script> 里逃出去。
    tags$script(HTML(
      "(function(){try{",
      "var s=localStorage.getItem('dsapp_skin')||'';",
      "if(!/^[a-z0-9_-]{1,24}$/.test(s)) s='dark';",
      "document.documentElement.setAttribute('data-skin',s);",
      "}catch(e){document.documentElement.setAttribute('data-skin','dark');}})();"
    )),

    tags$script(src = dsapp_asset("app.js")),
    tags$title("Biomamba言出法随生信APP")
  ),

  # 主界面不写死在这里，而是由 server 按"当前有没有登录"渲染 ——
  # 没登录时这一格是注册页。见 dsapp_main_ui() 与 server 里的 app_root。
  uiOutput("app_root")
)

#' 左侧栏的一个导航项
#'
#' 为什么不用 bslib::nav_item / navset_pill_list：左侧栏要同时装导航**和**
#' 模型控件，而 bslib 的侧栏导航（page_sidebar / navset_pill_list）只接受
#' 导航项列表，模型块塞进去会被当成一个页签。所以导航这一块自己画，
#' 点击走 app.js 的 dsappNav() → 服务端 nav_select。
dsapp_rail_link <- function(value, icon_name, label, sub = NULL) {
  # ★ V13.12 item 19：多了一个可选的 `sub`（第二行小字）。
  #   加它是因为「模型服务」搬成独立页之后**丢了一样东西**：原来那一格
  #   收起时摘要行写着"当前在用哪个模型 / 未配置"，是全局唯一一处"一眼看出
  #   我在用哪个模型"的地方（V7 item 8 特意为它写了 sub 的更新逻辑）。
  #   搬进页面里就只剩"进那一页才看得见"了，所以把它挂在导航项下面一行。
  tags$a(
    href = "#", class = "dsapp-rail-link", `data-nav` = value,
    # ⚠️ draggable="false" 是**故意**的、V13.11 item 3 加的：<a href> 在浏览器
    #    里**天生可拖**（拖出来是一个链接幽灵图）。不关掉的话，用户想拖排序、
    #    在行上（而不是把手上）按下去，浏览器会接管成"拖这个链接"，然后什么
    #    都不发生 —— 看起来就是"这个功能没做出来"。关掉之后只有把手能拖。
    draggable = "false",
    onclick = sprintf("dsappNav('%s'); return false;", value),
    # ★ V13.11 item 3：拖拽把手。**只有这一小格可拖**，整行不可拖 ——
    #   整行可拖的话"点导航"就变成"开始拖"，而点导航是这一栏的主要用途。
    #   同 www/app.js 里技能那段的做法（HTML5 拖放，见 dsapp_skill_drag）。
    tags$span(class = "dsapp-rail-grip", draggable = "true", `data-nav` = value,
              title = "拖动调整顺序（聚焦后可用上下方向键）",
              # 键盘那条路：Tab 到它，上下方向键挪一格（见 app.js）。
              # ⚠️ 不给 tabindex 就聚焦不了 —— 而"只能用鼠标拖"对键盘用户和
              #    触摸板不好使的人是实打实的用不了（同技能手柄那条）。
              tabindex = "0",
              # ⚠️ 必须把点击拦在这里：它是 <a> 的孩子，不拦的话"按一下把手"
              #    会先冒泡成一次导航点击 —— 用户只是想拖，页面却跳走了。
              #    （拖动本身不触发 click，所以拦住 click 不影响拖。）
              onclick = "event.preventDefault(); event.stopPropagation(); return false;",
              icon("grip-vertical")),
    tags$span(class = "dsapp-rail-ico", icon(icon_name)),
    # ⚠️ 文字包一层是为了让 sub 掉到 label **下面**而不是右边：这一栏最窄
    #    180px，模型名（"deepseek-chat" 这种，还带厂商前缀）横着放在标签
    #    右边必然溢出。.dsapp-rail-txt 是 flex 列。
    # ⚠️ 没有 sub 时**不要**渲染一个空的 span：多了个空行，所有导航项之间
    #    的间距会变得不一样（看上去像"这几项没对齐"）。
    if (is.null(sub)) {
      tags$span(class = "dsapp-rail-label", label)
    } else {
      tags$span(class = "dsapp-rail-txt",
        tags$span(class = "dsapp-rail-label", label),
        tags$span(class = "dsapp-rail-sub", title = sub, sub)
      )
    }
  )
}

#' 主界面（登录之后）
#'
#' 之所以是个函数而不是顶层常量：它要按账号决定显示哪些页（管理页只有
#' 管理员看得到），还要在导航栏右侧放当前账号和退出按钮。
#'
#' ---- V6 结构（item 2 + item 5）---------------------------------------------
#'
#' 从 page_navbar 换成了自己搭的两栏壳：
#'
#'   .dsapp-shell ┌── .dsapp-rail ────┬── .dsapp-main ────────────┐
#'                │ 品牌 / 导航        │ 顶栏（账号、退出）          │
#'                │ ─────────────     │ ────────────────────────  │
#'                │ 模型服务（常驻）    │ navset_hidden 的各页        │
#'                │ ← 自己一条滚动条   │ ← 自己一条滚动条            │
#'                └───────────────────┴───────────────────────────┘
#'
#'   ⚠️ 页签仍然是 **bslib::nav_panel**，只是装进了 navset_hidden。
#'      不能换成"用 renderUI 只渲染当前页"：那会在切页时**销毁**整棵 UI 树，
#'      对话页的滚动位置、输入框里没发出去的字、文件页的上传队列全部丢失。
#'      navset_hidden 把所有页都留在 DOM 里、只藏不激活，行为和 page_navbar
#'      一致（page_navbar 本来也是这么干的）。
#'
#'   ⚠️ nav_panel 的 value 一个都不能改，理由见下面那段原注释。
dsapp_main_ui <- function(user, auth_mode = "login") {
  is_admin <- dsapp_user_is_admin(user)
  # ★ V13.8 item 1：管理页分两级。is_admin 回答的是"进不进得去管理页"
  # （两种管理员都是 TRUE），admin_scope 回答的是"进去之后看得到哪一片"。
  # 两个都要往下传 —— 只传 is_admin 的话，项目管理员会拿到整页。
  admin_scope <- dsapp_user_admin_scope(user)
  # ★ V16.5 item 5：云工具那一项**只给平台管理员**。判据用 dsapp_user_is_platform_admin
  #   （= admin_scope == "platform"），**不是** is_admin —— 后者对项目管理员也
  #   是 TRUE，拿它当闸的话项目管理员也会看见云工具，和用户那句
  #   「只对平台管理者开放」不符。左栏那一侧由 DSAPP_NAV_ITEMS 里的
  #   role = "platform" 管（同一个判据的两个出口，都要改）。
  platform_admin <- dsapp_user_is_platform_admin(user)

  # ⚠️ 这里**不能**用 page_fillable / fillable=TRUE 去撑满视口。
  #    dsapp_main_ui 的返回值是塞进 uiOutput("app_root") 的，renderUI 产出的
  #    <body class="bslib-page-fill"> 在浏览器里会被忽略（body 标签不参与
  #    innerHTML）—— 这一点 V5 已经踩过，当时 fillable = TRUE 事实上从未生效。
  #    所以高度只能由 CSS 自己算：.dsapp-shell { height: calc(100vh - 页脚) }。
  #
  # ⚠️ 页脚要挂在这里（主界面），**不能**挂到 app_ui 上。V5 的页脚是
  #    page_navbar(footer =) 给的，换成自己搭的外壳时它整个掉了 ——
  #    而掉了不会有任何报错：CSS 里 --dsapp-footer-h 还留着，外壳照样
  #    按"下面有个页脚"算高度，于是页面底部空出一条谁也不知道是什么的带子
  #    （V6 改版时真的这样，是自检里那条 footer = 断言抓住的）。
  #    也不能挂 app_ui：那样登录页会出现两个（dsapp_auth_shell 自己带一个）。
  tagList(
    tags$div(class = "dsapp-shell",

    # ======================= 左侧栏 =======================
    tags$aside(class = "dsapp-rail", id = "dsapp_rail",
      tags$div(class = "dsapp-rail-brand",
        # 平台 logo（V10 item 3）。没配图就落回原来的 dna 图标。
        dsapp_logo_box("dsapp-rail-logo", "dna"),
        tags$span(class = "dsapp-rail-name", "Biomamba"),
        tags$span(class = "dsapp-rail-brand-sub", "言出法随生信 APP")
      ),

      # ★ V13.11 item 3：这一栏现在是**从 DSAPP_NAV_ITEMS 渲染出来的**
      #   （表在 R/uiprefs.R），不再是 8 个写死的调用。用户原话：「最左侧
      #   导航栏也需要可以通过拖拽改变位置」——拖宽是 V13.5 item 8 的事
      #   （menu_w），这里加的是**拖着重排顺序**。
      #
      #   三件事在这里合流：
      #     1. 谁看得见 —— 按 role 筛（role 见 DSAPP_NAV_ITEMS）
      #     2. 什么顺序 —— 用户拖出来的 nav_order，没拖过的项接在后面
      #     3. 怎么画   —— dsapp_rail_link（带拖拽把手）
      #
      # ⚠️ 顺序读的是**偏好**，所以这里过一次库（和下面模型服务那块同一个
      #    节奏）。dsapp_main_ui 只在换账号时重渲染一次，不是每帧，
      #    多一条 SELECT 可以接受；而拖完顺序**不需要**重画这一栏 ——
      #    app.js 是直接改 DOM 的，重画反而会把用户拖到一半的状态冲掉。
      #
      # ⚠️ 渲染的项**必须**和下面 navset_hidden 里的 nav_panel 一一对应。
      #    对不上的表现是"点了没反应"（dsappNav 找不到那个 value）。两边
      #    现在都是手写的，靠 selftest.R 那条断言钉着，别只改一边。
      # ⚠️ data-input-order 是 app.js 那段拖拽重排**取上来**的 input 名
      #    （和技能列表那段同一个约定：宿主元素说"顺序报给谁"）。这条栏
      #    不在模块里，所以是裸的 `nav_order` —— 对应 server 里顶层那条
      #    收 `input$nav_order` 的 observer。
      #    ⚠️ 这段注释里**故意不写出那条 observer 的完整调用形状**：写全了
      #       的话 selftest 里"抠出那一整块"的正则先命中的是**注释**，
      #       一路吃到下一个 observer 的结尾，断言就在验一段根本不是它的
      #       文本（写完当场踩到）。同理别在别处抄那句话。
      tags$nav(class = "dsapp-rail-nav", id = "dsapp_rail_nav",
               `data-input-order` = "nav_order",
        local({
          prefs <- tryCatch(dsapp_uipref_get(user$id %||% NULL),
                            error = function(e) dsapp_uipref_norm(NULL))
          # ★ V16.5 item 5：这段判据搬进 R/uiprefs.R 的 dsapp_nav_visible()
          #   了（这里只是调用）。搬家的理由是这段原来是**顶层 UI 里的一段
          #   匿名函数**：自检够不着它，于是"平台管理员才看得见"这件事一次
          #   都没被跑过。判据本身（role 的三档、NA 当没写）见那边。
          vis <- dsapp_nav_visible(DSAPP_NAV_ITEMS,
                                   is_admin = is_admin,
                                   admin_scope = admin_scope)
          by_val <- stats::setNames(
            DSAPP_NAV_ITEMS,
            vapply(DSAPP_NAV_ITEMS, function(x) x$value, character(1)))
          # 「模型服务」那一项下面那行小字（V13.12 item 19）：当前在用哪个
          # 模型 / 还没配。口径和 V7 item 8 那会儿**完全一样** ——
          # mod_model.R 保存成功后发回来的也是同一个口径（"已配置" 兜底），
          # 不保持一致的话，刷新一次前后的两句话会对不上。
          msub <- tryCatch({
            st <- dsapp_settings_get(user$id %||% NULL)
            if (isTRUE(st$saved)) {
              if (nzchar(st$model %||% "")) st$model else "已配置"
            } else "未配置"
          }, error = function(e) "未配置")
          lapply(dsapp_nav_sorted(
                   vapply(vis, function(x) x$value, character(1)),
                   prefs$nav_order),
                 function(v) {
                   it <- by_val[[v]]
                   dsapp_rail_link(it$value, it$icon, it$label,
                                   sub = if (identical(v, "model")) msub)
                 })
        })
      ),

      # ★ V13.12 item 19（用户原话）：「把模型服务换成和其它几个侧面导航栏
      #   一样的单独页面吧」。
      #
      #    这一格原来是**常驻在左栏最下面的一块 <details>**（V3 item 5 加的，
      #    V7 item 8 给它加了"不用时收起"）。改成独立页之后：
      #      · 它现在是上面那排导航项里的一项（value = "model"，见
      #        R/uiprefs.R 的 DSAPP_NAV_ITEMS），由 navset 那一套切页管；
      #      · 「当前在用哪个模型」那行字搬到导航项下面（dsapp_rail_link 的
      #        sub 参数），否则"一眼看出在用哪个模型"这件事就没了；
      #      · V13.11 item 8 的"改了还没确认就离开"改判**切页**（原来判的是
      #        <details> 被收起），见 app.R 底下 state$nav 那条和
      #        mod_model.R 里的 observeEvent(state$nav, …)。
      #
      #    ⚠️ 别再把 mod_model_ui 塞回这一栏。它现在只在一个地方出现：
      #       navset_hidden 里的 nav_panel(value = "model")。同一个模块 id
      #       出现在两处 = 两个同 id 的 Shiny input（"Duplicate input ID"，
      #       控制台会刷，服务端也只认其中一个）。
      #    ⚠️ 这一栏的滚动条随之挪到了 .dsapp-rail-nav 上（见 codex.css）。
    ),

    # ---- 主菜单那条分隔条（V13.5 item 8）---------------------------------
    #
    # 用户原话：「主菜单的宽度也需要能够让用户调整」。
    #
    # ⚠️ 它必须是 .dsapp-shell 的**直接子元素**，而且只能绝对定位 ——
    #    shell 是两列的 grid（主菜单 | 主区），多一个孩子就多一列，主区会被
    #    挤到第三列去。理由和 mod_chat.R 里那条 sess 把手一模一样，
    #    见 codex.css 的 .dsapp-rail-handle。
    #
    # ⚠️ 它**不在任何模块里**，所以 id 没有命名空间前缀，就是 `split_m` ——
    #    app.js 的 report() 按 id 形状算出 input 名 `panel_size`，于是这条
    #    把手报的是**顶层**的 input$panel_size（下面的 observeEvent 收）。
    #    对话页那三条报的是 `chat-panel_size`，两条路互不干扰。
    #    ⚠️ 改 id 的后缀字母之前先看 report() 那个正则，它只认 [vhstm]。
    tags$div(
      class = "dsapp-rail-handle",
      id = "split_m",
      `data-dsapp-panel` = "menu_w",
      tabindex = "0",
      role = "separator",
      `aria-label` = "拖动调整主菜单宽度",
      title = "拖动调整宽度（双击恢复默认）"
    ),

    # ======================= 主区 =======================
    tags$main(class = "dsapp-main",
      tags$div(class = "dsapp-topbar",
        tags$div(class = "dsapp-topbar-title", id = "dsapp_page_title", ""),
        tags$div(class = "dsapp-topbar-right",
          tags$span(class = "dsapp-user",
            icon("circle-user"),
            sprintf(" %s", user$nickname %||% "用户"),
            if (is_admin) tags$span(class = "badge dsapp-badge-admin ms-1", "管理员")
          ),
          # 「直接进入」模式下**不给退出按钮** —— 退出去、重载，立刻又被
          # 自动登回来，用户只会觉得"按钮坏了"。V6 默认已经是 login 模式
          # （见 config.R 的 auth_mode），这个分支只在有人把 .Renviron
          # 改回 auto 时才会走到。
          if (!identical(auth_mode, "auto")) {
            actionLink("logout", tagList(icon("right-from-bracket"), " 退出"),
                       class = "dsapp-logout")
          }
        )
      ),

      tags$div(class = "dsapp-main-body",
        # ⚠️ 每个页签都要写死 value，**不能靠 value 默认等于标题**。
        #    bslib::nav_select() 认的是 value：标题一改（"对话" → "言出法随"），
        #    设置页那个"回到对话页"的按钮就会静默失效 —— 不报错，只是点了没反应。
        #    钉住 value 之后，标题想怎么改都行。
        #
        # ⚠️ 这个 id 必须仍然叫 "nav"：mod_chat.R / mod_settings.R 里有多处
        #    bslib::nav_select("nav", ...)，模块里写的是裸 "nav"（无命名空间）。
        bslib::navset_hidden(
          id = "nav",

          nav_panel("言出法随", value = "chat", mod_chat_ui("chat")),
          # V11 item 8：「任务」改名「历史任务」。
          # ⚠️ value 仍然是 "tasks"，**不能跟着改** —— 见上面那段 ⚠️：
          #    dsapp_goto("tasks") 认的是 value，改了标题没事、改了 value
          #    就是"点了没反应"。用户要改的也只是标题。
          nav_panel("历史任务", value = "tasks", mod_tasks_ui("tasks")),
          nav_panel("文件", value = "files", mod_files_ui("files")),
          # ★ V13.11 item 5：文献速递。检索本身交给 agent 在工作区里用
          #   命令行做（用户选的那条路），这一页只负责收条件、拼提示词、
          #   新建对话 —— 见 R/mod_lit.R 顶上那段。
          nav_panel("文献速递", value = "lit", mod_lit_ui("lit")),
          # ★ V15 item 8：论坛。⚠️ 这一行**必须写成一行**，而且 value 与
          #    R/uiprefs.R 里 DSAPP_NAV_ITEMS 那一项逐字相同 ——
          #    selftest 那条"左栏导航项与 navset 的 value 一一对应"用的是
          #    正则 `nav_panel\("[^"]+", value *= *"[a-z]+"`，换行写就抓不到，
          #    而抓不到的后果是那条断言**静默少比一项**（它比的是集合）。
          nav_panel("论坛", value = "forum", mod_forum_ui("forum")),
          # ★ V15.8 item 2：云工具。⚠️ 和「论坛」一样**必须写成一行**
          #   （selftest 抓 nav_panel 的正则是单行的），value 与
          #   R/uiprefs.R 的 DSAPP_NAV_ITEMS 里那一项逐字相同。
          #   ★ V16.5 item 5：外面套了一层 `if (platform_admin)` —— 用户原话
          #   「云工具暂时只对平台管理者开放，普通用户不显示」。左栏那一侧
          #   靠 DSAPP_NAV_ITEMS 里的 role = "platform"，两处一起生效。
          #   ⚠️ 这一层是**不显示**，不是权限：`mod_cloudtool_server` 照旧
          #      无条件注册（app.R 下面那段 ⚠️ 说的就是这件事），页面自己的
          #      门槛（GPU / 权重 / 执行器体检）一个字没动。
          #   ⚠️ 套 `if` **不影响** selftest 那条"左栏与 navset 一一对应"：
          #      它比的是**源码文本**（正则抓 `nav_panel("…", value = "…"`
          #      这一行），不是 eval 出来的 UI —— 所以它照样数得到 cloudtool，
          #      `setequal` 照样成立。反过来说：**这一行不能折行**，
          #      折了就成了"左栏有、navset 没有"的红，而那句红念起来像是
          #      表里多写了一项，其实只是排版。
          #      真正由自检钉住"普通用户看不见它"的是 V16.5 item 5 那一节
          #      （表里那条 role + 这里这个 `if`），以及浏览器探针
          #      tests/ui_v165/probe_nav.py。
          if (platform_admin) {
            nav_panel("云工具", value = "cloudtool", mod_cloudtool_ui("cloudtool"))
          },
          nav_panel("技能", value = "skills", mod_skills_ui("skills")),
          nav_panel("环境", value = "envs", mod_envs_ui("envs")),
          # ★ V13.12 item 19：模型服务（原来常驻在左栏最下面的那一块）。
          #   ⚠️ 全应用**只有这一处** mod_model_ui("model")。
          nav_panel("模型服务", value = "model",
                    mod_model_ui("model", user_id = user$id %||% NULL)),
          nav_panel("设置", value = "settings", mod_settings_ui("settings")),
          # ★ V13.14 item 23（用户原话：「帮助页面独立到左侧导航栏」）：
          #   原来是设置页里的第四个页签（value 也是 "help"，但那个 value 只
          #   在那一个 navset_underline 内部有效）。现在它是这一层的一页 ——
          #   value 必须和 R/uiprefs.R 里 DSAPP_NAV_ITEMS 那一项**逐字相同**，
          #   对不上的表现是"点了没反应"（dsappNav 找不到那个 value）。
          #   ⚠️ 这一页没有 server，所以这里没有配套的 mod_help_server()。
          nav_panel("帮助", value = "help", mod_help_ui("help")),
          # ★ V15.4 item 7：原来的「管理」和「后台」两页合成这一页
          #   （用户原话：「请合并管理和后台界面，生成一个"后台管理"界面，
          #   原有的组间请以合理的分类生成子界面」）。
          #   左边一栏只有这一项，里面是四个子页签 + 平台专属的「提示词」，
          #   分类与门控见 R/mod_backstage.R 顶上那张表。
          #
          #   ⚠️⚠️ **value 仍然是 "admin"，一个字都不能改**（标题改了，
          #      value 没改，这是有意的）。全仓有多处裸 `nav_select("nav",
          #      "admin")` / `data-nav="admin"` / dsapp_goto 的跳转在认这个
          #      字符串；改成 "backstage" 的症状是"点了没反应"，不报错。
          #      左栏那一项（R/uiprefs.R 的 DSAPP_NAV_ITEMS）同理。
          #   ⚠️ 被删掉的是 `htadmin` 那个 value。老账号的 nav_order 里可能
          #      还留着 "htadmin" —— **无害**：dsapp_nav_sorted 是"按 order
          #      排、order 里没有的接在后面"，多出来的值会被忽略掉。
          #   ⚠️ 这一行**必须写成一行**（selftest 那条"左栏与 navset 一一对应"
          #      的正则抓的是单行），理由和上面「论坛」那一行一样。
          #
          #   ★★ V15.12 item 1：内容**不在首屏发**，第一次切到这一页才渲染。
          #      这不是省事，是在救那个号的命 —— 整页 HTML 是一次发给浏览器
          #      的一包，这一页独独就占 ≈60 KB（admin 31.7K + users 11.6K +
          #      runs 6.3K + overview 3.9K + prompt 3.4K + res 2.7K），
          #      而 SockJS 那条通道有个 10 秒的 pong 期限，一包大到排不完就
          #      会被判死、整页重载、再发一次、再死。完整的账见 server 里
          #      `admin_lazy` 那一段。**value 一个字没动**，跳转照旧。
          if (is_admin) {
            nav_panel("后台管理", value = "admin", uiOutput("admin_lazy_page"))
          }
        )
      )
    )
    ),

    # 页脚（item 7：版本号 + 客服微信）。放在 .dsapp-shell **外面**：
    # 外壳的高度是 calc(100vh - --dsapp-footer-h)，页脚在其中占掉那一截。
    # 放里面的话外壳会多出一条 2.6rem 的滚动。
    dsapp_footer_ui()
  )
}

# ⚠️⚠️ 页脚（dsapp_footer_ui）**故意不定义在这个文件里**，它在 R/utils.R。
#
#    app.R 是**唯一**一个被 Shiny 用 `sys.source(..., envir = new.env(parent
#    = globalenv()))` 之类的方式求值的文件 —— 它的顶层**不在 globalenv 里**。
#    而上面那个 source 循环把 R/*.R 明确送进了 globalenv（`local =
#    globalenv()`）。于是两边隔着一层：
#
#        env_app.R  ──parent──▶  globalenv  ──▶  attached packages
#        （app.R 里的一切）        （R/*.R 里的一切）
#
#    app.R 能看见 R/*.R 的东西（globalenv 是它的父），**反过来不行**。
#    所以任何"定义在 app.R、却被 R/*.R 调用"的函数，一调就是
#    `could not find function`。
#
#    2026-09-14 V6 就是这么炸的：页脚为了 item 7（版本号 + 客服微信）从
#    dsapp_main_ui 里拎了出来，顺手放在 app.R 的定义旁边 —— 主界面那条路
#    完全正常（调用方和定义方都在 env_app.R），**注册/登录页整个白屏**，
#    因为 R/mod_welcome.R 里的 dsapp_auth_shell 在 globalenv 里够不着它。
#    最坏的是这个组合恰好只在"没登录的人"身上出现，而没登录的人看到的
#    就是一句 "could not find function"，没有任何线索指向 app.R。
#
#    判据很简单：**这个函数有没有被 R/ 下的文件调用过**。有 → 放 R/。
#    现在 selftest 里有一条断言在扫这个不变式，别再靠人记得。

# ---- 服务端 -----------------------------------------------------------------

server <- function(input, output, session) {
  # ---- 软错误不判会话死刑（V15.6 item 4）------------------------------------
  #
  # ★★ 用户报的「运行一半弹『与服务器的连接断了』」真正的修法在这儿，心跳
  #    那边一个字没改。机理、实测、副作用都写在 R/errhand.R 那个函数的注释里
  #    （一句话：observe 里一个没人接的错 → Shiny 把整个会话 close 掉 →
  #     socket 断 + 心跳连同其它定时器一起被清 → 前端心跳判死后弹断连提示；
  #     判死线 2026-10-07 从 16 秒抬到 30 秒，且那一刻先出的是左下角小条）。
  #
  # ⚠️ 必须是会话里的**第一件事**：它换的是这个会话自己的 unhandledError，
  #    晚装一步，就可能已经有一个 observer 的错把会话判死了。
  dsapp_err_soften_session(session)

  cfg <- dsapp_config()

  # ---- 同步收件箱（V13.3 item 2）--------------------------------------------
  #
  # ★ 这就是"服务器端的收件箱谁来应用"的答案（SYNC.md §4.4 标了必须在
  #   动手前定的那条）。完整的取舍写在 R/sync.R 顶部第三节，这里只记
  #   落点为什么是这两处：
  #
  #   1) **这里**（会话一开始就跑；上面那个错误守卫之后的第一件事）。桌面版刚 scp 上来的包，得在
  #      这个会话画第一屏之前吃进去 —— 放在 renderUI 之后就等于"用户先看到
  #      一次旧数据，5 秒后才变"，那正是 SYNC.md 担心的"同步了但半天不
  #      生效"。调用本身极便宜：正常情况下就是一次 list.files()，进程内
  #      的指纹缓存会让第二个以后的会话直接返回。
  #   2) **下面那个 5 秒的观察者**。管的是"页面已经开着的时候来了新包"。
  #
  #   两处都包在 try 里：同步是**附加功能**，它坏掉的正确表现是"同步不
  #   生效"，绝不能是"应用打不开"。
  #
  # ★ V13.7 item 7 起，这两处的含义变了：函数内部会按包里的邮箱去内存表
  #   里找同步密钥，**找得到才应用**（R/synckey.R）。所以"谁来触发"不再是
  #   "谁碰巧打开了网页"，而是"**账号本人在线**"——这一趟若是别人在渲染，
  #   他只是白扫一次 list.files()，一个包都不会被应用。
  #   这不是限制，是把触发条件收紧到唯一能验签的那一种情形；原来的理由
  #   （"服务器上的数据变化必然是有人用了网页版产生的"）依然成立。
  try(dsapp_sync_maybe_apply(cfg), silent = TRUE)

  # ---- 账号闸门 -------------------------------------------------------------
  #
  # 入口令牌有两个来源，**URL 参数优先**：
  #   ?u=<token>  —— "换台电脑接着用"的那条链接，也是 cookie 全丢时的退路
  #   cookie      —— 日常路径，由 www/app.js 在页面连上时塞进 dsapp_cookie_token
  #
  # 为什么 URL 优先：用户点了一条带令牌的链接过来，意图非常明确（"我要进
  # 这个账号"）；而 cookie 是上一个用这台电脑的人留下的，那种情况下它更
  # 可能是个错误答案。
  entry_token <- reactive({
    q <- session$clientData$url_search %||% ""
    if (grepl("[?&]u=", q)) {
      tok <- utils::URLdecode(sub("^.*[?&]u=([^&]*).*$", "\\1", q))
      if (nzchar(tok)) return(tok)
    }
    input$dsapp_cookie_token %||% ""
  })

  # 令牌是从哪儿来的（V11 item 4b）。
  #
  # ⚠️ 单端登录要拿它区分两件**长得一样、处理却相反**的事：
  #    · URL 令牌是用户明确的"我要在这个端上用这个账号" → 认领，顶掉原来
  #      那一端；
  #    · cookie 是浏览器自己带的，用户什么都没说 → 不是当前那一端时**不认领**
  #      （认领的话两个端会互相顶，永远停在"正在加载"）。
  #    判定必须和 entry_token 里那两行**同源**，所以是同一段逻辑抄下来的：
  #    分开写的话，以后谁改了 URL 参数的写法，这里会静默地一直返回 "cookie"，
  #    表现就是"换台电脑那条链接点进去，要么进不去、要么把原来那台顶掉"。
  entry_src <- reactive({
    q <- session$clientData$url_search %||% ""
    if (grepl("[?&]u=", q)) {
      tok <- utils::URLdecode(sub("^.*[?&]u=([^&]*).*$", "\\1", q))
      if (nzchar(tok)) return("url")
    }
    "cookie"
  })

  current_user <- reactiveVal(NULL)

  # 被顶下线跳回来时 URL 上带的那个 ?kicked=1（V11 item 4b）。
  # 定义得早、赋值在下面读 qs 那一处 —— renderUI 是首屏 flush 时才跑的，
  # 那时整个 server 体已经跑完，两处都不会落空。
  kicked_flag <- reactiveVal(FALSE)

  # 页面每次加载都把"这个浏览器带了什么令牌来"记一笔。见 R/utils.R 里
  # dsapp_auth_log 的说明：出问题时这是唯一能看到"那一跳"两端的地方。
  observeEvent(input$dsapp_cookie_token, {
    dsapp_auth_log(sprintf("页面加载：cookie %s",
                           if (nzchar(input$dsapp_cookie_token %||% ""))
                             "非空" else "是空的"))
  }, once = TRUE)

  # ---- 登录后的 reload：等浏览器的回执，不许抢跑 ---------------------------
  #
  # ⚠️ reload 之后身份**只剩 cookie 一条路**（state 是 per-session 的，新会话
  #    从零开始）。原来的写法是"发一条 setToken，紧接着 reload" —— 两条
  #    websocket 消息确实有序，但服务端**无从知道**那句话有没有真的落进
  #    document.cookie：浏览器禁用或拦截 cookie 时它会静默丢弃，服务端照样
  #    reload，用户于是被无声地弹回登录页，而 audit_log 里记的是"登录成功"。
  #
  #    改成回执制：浏览器写完 cookie **读回来比对**，回执到了才 reload；
  #    回执说没写成，就**如实告诉用户**（浏览器没保存登录状态），不再假装
  #    登录成功了。
  #
  #    兜底不能省：JS 万一没跑（扩展拦截、老浏览器），没有回执就永远不
  #    reload —— 用户停在登录页上点多少次都没反应，比原来的 bug 更糟。
  #    所以 2 秒等不到就照旧 reload。
  #
  #    ack_n：每次登录 +1。Shiny 对**值相同**的输入不重复触发 observer，
  #    连登两次都是 {ok:true} 的话第二次就哑了 —— 带个序号，每次都不同。
  ack_n     <- reactiveVal(0L)
  awaiting  <- reactiveVal(FALSE)
  ack_since <- reactiveVal(NULL)

  observeEvent(input$dsapp_token_ack, {
    a <- input$dsapp_token_ack
    if (!isTRUE(awaiting()) || !identical(as.integer(a$n), ack_n())) return()
    awaiting(FALSE)
    if (isTRUE(a$ok)) {
      dsapp_auth_log("cookie 回执 ok，reload")
      session$reload()
    } else {
      # ⚠️ 这里**不** reload，但用户已经进来了（on_login 已经把 current_user
      #    置上，主界面就在眼前）。所以文案不能说"进不去" —— 那是在说假话。
      #    真实后果只有一个：**刷新之后要重新登录**。
      #    不 reload 是安全的：这一页的模块是在"未登录"状态下建的，里面没有
      #    上一个账号的东西（要换账号得先退出，而退出本身会 reload）。
      dsapp_auth_log("cookie 回执失败：浏览器拒绝保存，本次会话内有效")
      showNotification(
        tagList(icon("triangle-exclamation"),
                tags$b(" 这个浏览器不让本站保存登录状态。"),
                tags$br(),
                "现在可以照常使用，但", tags$b("刷新页面后需要重新登录"),
                "。常见原因：无痕/隐私窗口、浏览器禁用了 cookie、",
                "或者页面被嵌在别的网站里。"),
        type = "warning", duration = NULL)
    }
  }, ignoreNULL = TRUE)

  observe({
    if (!isTRUE(awaiting())) return()
    invalidateLater(300, session)
    t0 <- ack_since()
    if (!is.null(t0) &&
        as.numeric(difftime(Sys.time(), t0, units = "secs")) >= 2) {
      dsapp_auth_log("cookie 回执超时（2s），按旧行为 reload")
      awaiting(FALSE)
      session$reload()
    }
  })

  # 登录成功的统一入口。
  #
  # ⚠️ 那句 reload 不是保险起见，是**必须的**。
  #    模块的 server 函数在会话建立时就跑起来了，里面攒着一堆和"上一个
  #    账号"有关的状态：对话页当前打开的会话 id、已生成的草稿、agent 状态机、
  #    文件页的选中项……换账号时只改 state$user_id 的话，这些状态会原样
  #    留给下一个账号 —— 表现就是"B 登录后打开对话页，看到的还是 A 的对话"。
  #    重载页面让整个会话（含所有模块状态）重建，是唯一能保证清干净的做法，
  #    比逐个模块写一遍重置逻辑可靠得多（漏一个就漏一个）。
  # ⚠️ reload 参数不是可有可无的开关，它挡的是一个**死循环**：
  #
  #    重新加载页面 → 新会话 → cookie 还在 → 自动登录 → 再 reload → …
  #
  #    浏览器会一直停在"正在加载"，用户看到的是永远进不去（而且不报错）。
  #    所以：**显式**登录（注册完点进入、登录页提交）要 reload，因为那时的
  #    会话已经活着一段时间了，模块里可能攒着上一个账号的东西；**自动**登录
  #    （cookie / URL 令牌）不 reload —— 那个会话是刚建的，模块还没来得及
  #    攒任何东西，白白重载一次只会把循环闭起来。
  # ---- 单端登录：认领这一端（V11 item 4b，见 R/logins.R）-------------------
  #
  # @return nonce（这一端的凭据），或者 NULL 表示"这个部署不启用单端登录"。
  #
  # ⚠️ 要不要**认领**，判据是"递进来的令牌里那个 nonce 是不是就是当前那一行"，
  #    而不是"这次是显式登录还是自动登录"：
  #
  #      对得上（页面刷新、cookie 自动登录）→ 什么都不做。
  #        这一条是**必需**的：每次加载都认领的话，刷新一下就把别的端顶掉，
  #        两个端互相顶，永远停在"正在加载"。
  #      对不上（密码登录、注册完点进入、URL 令牌、以及 V11 之前发出去的
  #        那种不带点的老 cookie）→ 认领。这才是用户说的"登录"这个动作，
  #        它会把别的端顶下线。
  #
  # ⚠️ 老 cookie（不带点）走的是"认领"这一条，代价是升级之后**每个端要重新
  #    登录一次**。这是刻意选的方向：反过来（把"没带 nonce"当成放行）等于给
  #    了一条绕过单端限制的路 —— 手写一个不带点的 cookie 就行。
  #
  # ⚠️⚠️ auth_mode = "auto" 下**整条单端登录都不生效**（这里返回 NULL，
  #    下面那条心跳 observe 也会因为拿不到 nonce 而空转退出）。
  #
  #    那个模式（非默认，见 R/config.R）里所有人共用同一个默认账号，
  #    "一个账号一个端"在那儿是没有意义的 —— 它只会变成"谁打开页面谁就把
  #    别人踢下线"。共享部署上那是灾难，而且这种踢是**静默**的（用户看到的
  #    是"页面自己在刷新"）。静默踢人比并发写坏东西更难查。
  dsapp_login_claim <- function(u, token) {
    if (identical(as.character(cfg$auth_mode %||% "login"), "auto")) return(NULL)

    sp <- dsapp_login_split(token)
    nonce <- sp$nonce
    if (nzchar(nonce) &&
        isTRUE(tryCatch(dsapp_login_owns(u$id, nonce, con = dsapp_db(cfg)),
                        error = function(e) FALSE))) {
      return(nonce)
    }

    # 认领之前先看一眼"原来那一端是谁" —— 顶掉别人的登录是一条要留痕的动作，
    # 而且这条日志是**唯一**能回答"我怎么突然被踢了"的地方：被踢的那一端
    # 身份已经被换掉了，它自己写不进库（写进去反而会把新端的记录搅浑）。
    prev <- tryCatch(dsapp_login_current(u$id, con = dsapp_db(cfg)),
                     error = function(e) NULL)
    nonce <- dsapp_login_start(u$id, ip = dsapp_audit_ip(session),
                               ua = tryCatch(
                                 as.character(session$request$HTTP_USER_AGENT %||% ""),
                                 error = function(e) ""),
                               con = dsapp_db(cfg))
    if (!is.null(prev) && nzchar(nonce)) {
      try(dsapp_audit("login_kick", user = u, session = session, cfg = cfg,
                      detail = sprintf("顶掉 %s 那一端（IP %s）",
                                       dsapp_fmt_time(prev$created_at),
                                       prev$ip %||% "")),
          silent = TRUE)
    }
    nonce
  }

  on_login <- function(u, token, reload = TRUE) {
    state$user_id <- as.integer(u$id)
    state$user <- u
    # 管理员重置过密码的账号先过闸门（见 mod_welcome.R 的强制改密页）。
    # 从**用户行**读而不是从回调参数读：cookie 自动登录那条路不经过
    # 登录表单，拿不到 auth 的返回值，只有库里的这一行是两条路共用的真相。
    state$must_change_pw <- isTRUE(as.logical(u$must_change_pw %||% FALSE))
    try(dsapp_user_touch(u$id, con = dsapp_db(cfg)), silent = TRUE)
    current_user(u)

    nonce <- dsapp_login_claim(u, token)
    state$login_nonce <- nonce
    # cookie 里放的是"令牌 + 这一端"，两段都要（见 R/logins.R 顶部）。
    # 没认领（auth_mode = auto）时发原值 —— 那条路本来就没有"端"的概念。
    cookie <- if (is.null(nonce)) u$token
              else dsapp_login_cookie(u$token, nonce)
    # ⚠️ isolate() 不能省。on_login 有两条调用路径：模块里的 observer（有
    #    响应式上下文）和顶层的"自动进入"（没有）。reactiveValues 在上下文
    #    之外读会抛，而这里的报错原本被 dsapp_auth_log 的 try 吞掉了 ——
    #    表现为这条日志**从来没写进去过**。isolate 在有上下文时不建立依赖，
    #    没有时也只是取值，两边都对。
    dsapp_auth_log(sprintf("on_login uid=%d reload=%s", isolate(state$user_id),
                           if (isTRUE(reload)) "是" else "否"))
    if (!isTRUE(reload)) return(invisible(NULL))

    # 显式登录：cookie 由这里统一写（调用方不再自己发一条），写完等回执。
    n <- ack_n() + 1L
    ack_n(n)
    ack_since(Sys.time())
    awaiting(TRUE)
    # ⚠️ 发下去的是拼好 nonce 的那个值（cookie），不是调用方递进来的 token。
    #    这两个在"认领"那一条路上**一定不同** —— 发原值的话，浏览器存下来的
    #    cookie 里没有这一端的身份，下一次加载就认不出自己，于是又认领一次、
    #    又把别的端顶一遍（刷新一次顶一次，两个端永远在互顶）。
    session$sendCustomMessage("dsapp:setToken",
                              list(token = cookie, ack = "dsapp_token_ack", n = n))
    invisible(NULL)
  }

  # ⚠️ 关于"登录成功后闪回登录页"，这里**不需要**再插一个"正在进入"过渡页。
  #
  #    想过加，实测是死代码：Shiny 把客户端**首批输入**（app.js 在
  #    shiny:connected 里送来的 dsapp_cookie_token）和首屏渲染放在同一批里
  #    处理，且输入先于渲染。所以第一帧渲染时 cookie 已经到了，
  #    entry_token() 的自动登录也已经跑完 —— 过渡页根本没机会显示
  #    （用 Playwright 从 navigation commit 起每 30ms 抓一次，一帧都没抓到）。
  #
  #    真正要堵的是"cookie 压根没写进去"，那由 on_login 的回执制负责：
  #    浏览器写完了**读回来确认**，服务端才 reload。回执没到就不 reload。
  # ---- 用户须知闸门（V9 item 1）--------------------------------------------
  #
  # 每次"进入应用"问一次：同意过没有、同意的是不是当前这一版、是不是超过
  # 7 天了。没通过就整页替换成确认页，过不了这一关就进不了主界面。
  #
  # ⚠️ 为什么是"整页替换"而不是弹窗：弹窗底下压着的是**已经渲染好的主界面**，
  #    用户可以绕过它去点别的东西（bootstrap 的 modal 挡得住鼠标，挡不住
  #    Tab 和直接改 DOM），而这条同意的价值全在"没同意就用不了"上。
  #    和 must_change_pw 用同一套做法，行为一致。
  #
  # ⚠️ 判定是**响应式**（每次都去库里读），不是一个 reactiveVal。用
  #    reactiveVal 的话，它要靠 observer 去填，而 observer 和 app_root 的
  #    执行先后没有约定 —— 用户会看到主界面闪一下再被换成确认页。
  #    读库很便宜（一次索引查询），而且 app_root 本来就很少重渲染。
  tos_ack <- reactiveVal(FALSE)   # 本次会话里刚点过同意
  observeEvent(state$user_id, tos_ack(FALSE), ignoreNULL = FALSE)
  tos_need <- reactive({
    uid <- state$user_id
    if (is.null(uid) || is.na(uid)) return(FALSE)
    if (isTRUE(tos_ack())) return(FALSE)
    # 读库失败时**放行**（need = FALSE）。这个方向是刻意选的：闸门本身
    # 不该成为"应用打不开"的原因 —— 库读不出来的时候，用户对着一个
    # 确认页点一百次也没用，因为他点下去同样写不进去。
    g <- tryCatch(dsapp_tos_gate(uid, con = dsapp_db(cfg)),
                  error = function(e) list(need = FALSE))
    isTRUE(g$need)
  })

  # ---- 单端登录：心跳（V11 item 4b）----------------------------------------
  #
  # 登录之后每 DSAPP_LOGIN_POLL_MS 问一次库："当前那一端还是我吗？"
  # 不是 → 说明同一账号在别处登录了，**这一端整页退出**。
  #
  # ⚠️ 这里是"发现"，不是"阻止"。真正的阻止在 on_login 认领那一行：新端
  #    一写库，旧端的 nonce 就作废了，旧端从这一刻起做什么都是无效的。
  #    心跳只负责让旧端**知道**，并把它带走。
  #
  # ⚠️ 带走的方式是**跳转**（dsapp:kick → 前端清 cookie + 重新打开这一页），
  #    不是在这边上再渲染一个"你被踢了"的页面。理由是善后：这一跳会让
  #    Shiny 结束这个会话，mod_chat.R 的 onSessionEnded 会把 LLM 子进程、
  #    agent 循环、以及**引擎里那个还在跑的任务**一起停掉（那是"多端"最
  #    危险的地方 —— 一个已经被顶掉的端继续往同一个工作区里写东西）。
  #    在这儿另写一份善后逻辑的话，就是两份要同步维护的停机流程。
  #
  # ⚠️ 开销：每个登录着的端每 15 秒一次索引查询（主键查一行）。所有访客
  #    共用同一个 R 进程，这个查询是串行的 —— 所以这个间隔**不要**调小，
  #    它只影响"多久发现"，不影响正确性。见 DSAPP_LOGIN_POLL_MS 的说明。
  observe({
    uid <- state$user_id
    # ⚠️ 这两个都**不能**包 isolate()（和别的 observe 里的规矩正好相反）：
    #    心跳是"登录之后才开始"的，而登录写这两个值的时候这个 observe 早就
    #    建好了 —— 不建立依赖的话，它永远不会因为"刚刚登录了"而醒过来，
    #    只会在别的失效顺手把它带起来时碰运气跑一次。
    #    安全的前提是：这段代码**只读不写**它们（kicked 那个写在下面，
    #    写的是另一个值，而且写完那一拍自己就会重新跑一次、在下一行返回）。
    nonce <- state$login_nonce
    if (is.null(uid) || is.na(uid)) return()
    # 没有 nonce 有两种情况：没登录（uid 也空，上面就返回了），
    # 以及 auth_mode = "auto"（见 dsapp_login_claim：那条路不启用单端登录）。
    # 后者不能空转 —— 那会变成每个会话每 15 秒白跑一次库查询。
    if (is.null(nonce) || !nzchar(nonce)) return()
    if (isTRUE(state$kicked)) return()
    invalidateLater(DSAPP_LOGIN_POLL_MS, session)

    alive <- tryCatch(dsapp_login_owns(uid, nonce, con = dsapp_db(cfg)),
                      error = function(e) TRUE)
    # ⚠️ 读库出错（库锁着、文件被换掉）时**当作还活着**，不踢人。方向是
    #    刻意选的：单端限制是"防并发写坏东西"的，而库读不出来的时候这一端
    #    本来也做不了什么；反过来误踢的话，一次数据库抖动会把所有人踢下线，
    #    而他们看到的是"我的账号在别处登录了"—— 一句会让人去改密码的假话。
    if (isTRUE(alive)) return()

    state$kicked <- TRUE
    dsapp_auth_log(sprintf("uid=%d 被顶下线（nonce 已不是当前那一端）",
                           isolate(state$user_id)))
    session$sendCustomMessage("dsapp:kick", list())
  })

  # ★ V13.10 item 1：整个应用只有**这一个** renderUI 承载界面（注册页、登录页、
  #   强制改密、须知闸门、主界面全在里面）。它一抛异常，Shiny 就把这个 output
  #   的内容整块换成错误文本 —— 而那个 output 就是整页，于是用户看到的是
  #   "左栏、页签、页脚全没了，只剩一句英文报错"。
  #
  #   线上 Shiny Server 的 sanitize_errors 默认开着
  #   （/opt/shiny-server/lib/router/config-router-util.js:57），那一句英文
  #   连真实错误都不含 —— 用户原话里的
  #   "An error has occurred. Check your logs or contact the app author
  #    for clarification." 就是这么来的。
  #
  #   套上 dsapp_err_try 之后：完整错误 + 调用栈进 data/logs/app_error.log
  #   （应用自己的日志，不用 sudo），界面上换成一张人话卡片。**兜的不是
  #   某一个已知的错，而是"任何一处出错都不该把整个应用带走"这件事** ——
  #   具体那一处修没修好不影响这条底线。
  #   ⚠️ 里面这层 `local({...})` **不是**装饰。dsapp_err_try 的 expr 是个惰性
  #      参数，在它自己那个函数帧里被求值；裸写 `return()` 的话，R 会去
  #      "从当前函数返回"，而当前函数是 dsapp_err_try —— 实测直接报
  #      "no function to return from, jumping to top level"，然后被我们
  #      自己的 tryCatch 接住：**登录页会变成那张错误卡片**。
  #      local() 给了它一个真正的函数帧，return() 才是原来那个意思。
  output$app_root <- renderUI({
    dsapp_err_try(
    local({
    u <- current_user()
    if (is.null(u)) {
      # 被顶下线跳回来时 URL 上带着 ?kicked=1（见 dsapp:kick）。先说清楚
      # "你为什么退出来了"，再给登录页 —— 不说的话，用户看到的就是
      # "我什么都没干，怎么退出了"，第一反应是来问"是不是坏了"。
      if (isTRUE(kicked_flag())) {
        return(tagList(dsapp_kicked_notice_ui(), dsapp_welcome_ui("welcome")))
      }
      return(dsapp_welcome_ui("welcome"))
    }
    # 强制改密：先换密码，换完才给主界面。**排在须知前面** —— 一个是
    # "账号不安全"，一个是"条款没确认"，前者更紧急，而且两页都是整页替换，
    # 谁先谁后只是个顺序，不是取舍。
    if (isTRUE(state$must_change_pw)) return(dsapp_force_pw_ui("force_pw"))
    if (isTRUE(tos_need())) return(dsapp_tos_gate_ui("tos_gate"))
    dsapp_main_ui(u, auth_mode = as.character(cfg$auth_mode %||% "login"))
    }),
    where = "app_root",
    on_error = function(e) dsapp_err_page(e, "app_root"))
  })

  # ---- 皮肤（V8 item 4）----------------------------------------------------
  #
  # 首屏那一下由 app_ui 的 head 内联脚本负责（读 localStorage，早于绘制）。
  # 这一条负责**把服务端认的那份推下去**，两者不一致时以服务端为准 ——
  # 换账号、换浏览器、清了 localStorage 之后都靠它对齐。
  #
  # ⚠️ 用 state$user_id 触发而不是 state$user：登录闸门写这两个变量的顺序
  #    没有约定，而 user_id 是模块公认的"已登录"标志（见 mod_model.R 的用法）。
  #
  # ⚠️ 只发一次、发完就不再管。皮肤变了由设置页那条 observe 发（见
  #    mod_settings.R）—— 在这里再监听 state$skin 的话，两次发送会打架，
  #    而且设置页那条才是"用户刚点的"，语义更准。
  observeEvent(state$user_id, {
    uid <- state$user_id
    if (is.null(uid) || is.na(uid)) return()
    sk <- tryCatch(dsapp_skin_get(uid, con = dsapp_db(cfg)),
                   error = function(e) dsapp_skin_default())
    state$skin <- sk
    dsapp_skin_apply(session, sk)
  }, ignoreNULL = TRUE)

  # ---- 左侧栏导航（V6 item 5）----------------------------------------------
  #
  # 左栏的导航项是自己画的 <a>（bslib 的侧栏导航只收导航项，塞不下模型控件），
  # 所以点击要绕一圈：JS 发 dsapp_nav_goto → 这里 nav_select → 回执让前端
  # 更新高亮和标题。
  #
  # ⚠️ 认的还是 nav_panel 的 value。前端 data-nav 里写的那些字符串和
  #    app.R 里 nav_panel(value=) 必须一一对上 —— 对不上的表现是"点了没反应"，
  #    不报错。selftest 里有一条专门查这个。
  observeEvent(input$dsapp_nav_goto, {
    v <- input$dsapp_nav_goto$v %||% ""
    if (!nzchar(v)) return()
    tryCatch(bslib::nav_select("nav", v, session = session),
             error = function(e) NULL)
  }, ignoreNULL = TRUE)

  # 页签真变了才回执（包括模块里调 nav_select 的那些跳转 —— 它们不经过
  # dsapp_nav_goto，左栏高亮不跟着走的话，人会以为"点了没生效"）。
  #
  # ★ V13.12 item 19：顺手把当前页**发布到 state$nav**，给模块用。
  #   第一个用户是 mod_model 的"改了还没确认就离开这一页"（V13.11 item 8）——
  #   模型服务从常驻的左栏块变成了一页，判据也就从"折叠块被收起"变成
  #   "从 model 页切走了"。模块读不到顶层的 input$nav（命名空间会加前缀），
  #   所以照老规矩由顶层收下、经 state 转过去。
  observeEvent(input$nav, {
    v <- as.character(input$nav %||% "chat")
    state$nav <- v
    # ★ V15.12 item 1：第一次切到后台管理才把那一页发下去（见下面 admin_lazy）。
    if (identical(v, "admin")) admin_lazy(TRUE)
    session$sendCustomMessage("dsapp:nav", list(value = v))
  }, ignoreNULL = FALSE)

  # ---- 后台管理那一页：**第一次切过去才渲染**（V15.12 item 1）--------------
  #
  # 2026-10-03 用户报「Biomamba_ceshi 正常了，但 user1@example.com 这个账号
  #   的页面还是崩溃的，请保证所有账号都不会崩溃」。量下来是这样：
  #
  #   · 那个号（uid=1）是**唯一**一个 platform 管理员，比普通号多看得见
  #     「后台管理」那一页。整个 app_root 是一包 HTML 一次发下去的，那一页
  #     实测占 ≈60 KB（admin 31.7K + users 11.6K + runs 6.3K + overview 3.9K
  #     + prompt 3.4K + res 2.7K）—— 首屏 **152.5 KB**，而普通号只有
  #     **112 KB**。
  #   · 那条链路实测中位 **3.65 KB/s**（同一条连接上 Send-Q 的排空速度，
  #     60 秒采样）。按这个速率：25 秒排掉 ≈91 KB。
  #   · SockJS 的 websocket 通道每 25 秒发一个 **WS 协议级 ping**，10 秒内
  #     收不到 pong 就 `close(3000, 'No response from heartbeat')`
  #     （/opt/shiny-server/node_modules/sockjs/lib/trans-websocket.js:144）。
  #     那个 ping 和这一包数据**在同一个 TCP 流里排队** —— 一包大到 25 秒
  #     排不完、剩下的部分又要 10 秒以上才轮到 ping，连接就被判死。
  #   · 于是：152 KB 的号每一轮都被杀 → 自愈整页重载 → 又是 152 KB →
  #     每 ~2 分钟一次，永远好不了（`data/logs/auth.log` 里那个号
  #     15:49→16:51 一直在整页加载）。112 KB 的号正好活在这条线底下。
  #
  #   所以这里不是"优化"，是**把管理员的首页拉回和别的账号一个量级**：
  #   那 6 页他第一眼根本看不见（藏在「后台管理」后面），没道理占首屏的字节。
  #
  #   ⚠️ 是"第一次切过去才渲染"，**不是**"切走就销毁" —— 后者会把子页签、
  #      筛选条件、正在填的表单一起丢掉（同一个坑见 dsapp_main_ui 顶上那段
  #      关于 navset_hidden 的说明）。admin_lazy 只翻一次，翻了就不回退。
  #   ⚠️ 两个 server（mod_admin_server("admin") / mod_htadmin_server("htadmin")）
  #      仍然**无条件注册**（见下面那一段），这里改的只是 UI 什么时候送到
  #      浏览器。所以"先渲染后注册"这类顺序问题不存在。
  #   ⚠️ 占位那块不能省：切过去到渲染回来隔着一个来回，中间是空白的话，
  #      看着就像"点了没反应"（这一版最怕的假象）。
  admin_lazy <- reactiveVal(FALSE)
  output$admin_lazy_page <- renderUI({
    if (!isTRUE(admin_lazy())) {
      # 占位那一小块用现成的 .dsapp-empty，不新加样式（省得又一处要同步的 CSS）
      return(tags$div(class = "dsapp-empty", "正在加载后台管理…"))
    }
    u <- current_user()
    # 双保险：能走到这里说明这一端已经是管理员了，但 UI 闸不该只靠上面那句
    # if (is_admin) —— 那一句算的是**渲染 app_root 那一刻**的身份。
    if (is.null(u) || !dsapp_user_is_admin(u)) return(NULL)
    admin_scope <- dsapp_user_admin_scope(u)
    dsapp_err_try(
      mod_backstage_ui("admin", scope = admin_scope),
      where = "admin_lazy_page",
      on_error = function(e) dsapp_err_page(e, "admin_lazy_page"))
  })

  observeEvent(input$logout, {
    # 退出也要记：日志里"登录 → 退出"成对出现，中间没有退出的那段
    # 就是"这个会话一直开着"，排查共用电脑上的操作时用得上。
    # 放在清空 state 之前 —— 清完就不知道是谁了。
    dsapp_audit("logout", user = state$user, user_id = state$user_id,
                session = session, cfg = cfg)
    # 把这一端让出来（V11 item 4b）。不让的话，这一行会一直指着"那个已经
    # 退出的端"，用户换个浏览器登录之前都得先顶一次自己的登录记录 ——
    # 而那条 login_kick 日志会把"他自己换了个端"记成"有人顶了他"。
    # ⚠️ 带 nonce 只删自己那一行（见 dsapp_login_stop）：不带的话，甲退出
    #    会把乙刚登录写下的那一行删掉，乙下一次心跳就被莫名其妙判下线。
    try(dsapp_login_stop(state$user_id, isolate(state$login_nonce),
                         con = dsapp_db(cfg)), silent = TRUE)
    # ★ 同步密钥跟着登录态一起消失（V13.7 item 7）。不清的话，"退出登录"
    #   就只是把界面切回登录页 —— 进程内存里那份密钥还在，等着被收件箱里
    #   的下一个包用掉。用户对"退出"的预期是**这一端不再代表我了**，
    #   密钥留着就违背了这个预期。
    try(dsapp_synckey_drop(state$user), silent = TRUE)
    state$user_id <- NULL
    state$user <- NULL
    state$must_change_pw <- FALSE
    state$login_nonce <- NULL
    state$kicked <- FALSE
    current_user(NULL)
    # 先让浏览器把 cookie 删掉，再重载。两条消息走同一条 websocket，顺序
    # 有保证；反过来的话重载后 cookie 还在，会立刻自动登录回去。
    session$sendCustomMessage("dsapp:clearToken", list())
    session$reload()
  })

  # 会话级的共享状态。
  #
  # ⚠️ 「绝不落盘」这条 V6 起了变化，分清楚是哪一样：
  #    · API Key —— **现在落盘**了，按账号存进 users.llm_api_key。用户
  #      明确要求"保留记忆功能"，见 R/mod_model.R 顶部那段。
  #      （V13.1 item 9 起落盘的是**密文**，钥匙串在 data_root/.keyring，
  #       见 R/crypto.R。落盘这个事实没变，别把它读成"不落盘"。）
  #    · 远程服务器密码/私钥（state$remote）—— **仍然只存内存**。它不是
  #      我们的 Key，是用户某台机器的登录凭据，泄漏的后果重得多，而且
  #      吊销起来没那么容易。这条没变，别顺手一起改。
  #
  #    不管落不落盘，这些值都只存在**服务端**，不在浏览器里。有 root
  #    权限的人可以从库里或进程内存里取到 —— 界面上不能把话说满。
  state <- reactiveValues(
    # 当前账号（由上面的闸门写入；模块只读）
    user_id = NULL,
    user    = NULL,

    # LLM
    api_key     = "",
    vendor      = "deepseek",     # models.R 里 DSAPP_MODEL_CATALOG 的键
    base_url    = "",             # 留空 = 用该厂商的默认地址
    # ⚠️ 这里曾是 "deepseek-chat"，该模型名已于 2026-07-24 下线。
    # 保持和 config.R 的 default_model 一致；模型目录见 R/models.R。
    model       = "deepseek-flash",
    temperature = 0.3,
    # 思考模式下服务端默认就给 64K 输出预算，而且思维链也算在里面。
    # 给太小会出现"思考没写完就被截断、正文一个字没有"的情况。
    # ★★ V15.5 item 6：这一格原来是 max_tokens（单次**回复**上限，默认
    #   65536），现在是**单次使用上限** —— 一次请求（上下文 + 回复）合计
    #   能用多少 token。默认 DSAPP_CTX_FOLLOW(0) = 跟随模型，也就是
    #   "这个模型自己有多大窗口就用多大"（deepseek 是 1M）。
    #   回复上限不再单独设，由它减掉上下文推出来，见 models.R 的
    #   dsapp_ctx_plan()。
    ctx_limit   = DSAPP_CTX_FOLLOW,

    # ★★ V16.2 item 2：对话页 →「模型服务」页的一次性指令，用来改上面那个
    #   ctx_limit（也就是"单次使用上限"）。
    #
    #   为什么必须走这里、不能由对话页直接写 ctx_limit：那一格的**唯一写入口**
    #   是 mod_model.R 里那个 observe()（它读 input$max_tokens 等一大把
    #   input）。对话页偷偷改的话，用户下一脚踩到模型页（哪怕只是拖了下温度）
    #   就会被那个 observer 用**它自己那份旧值**盖回去 —— 界面上勾还亮着，
    #   实际发出去的又变回旧上限。所以指令要送到模型页，让它自己改。
    #
    #   list(rev = 自增整数, value = 秒…不，token 数；0 = 不设上限)
    #   ⚠️ 带 rev 是因为"改成 65536 → 又改回 65536"这一串在接收端看起来是
    #      同一个 list，光比值判断会漏掉第二次。和 focus_ws 那种"一次性指令"
    #      不同，这个**用完不清**（清了就分不清"没发过"和"发过又清掉了"）。
    maxtok_cmd  = NULL,
    # NULL = 不发这两个参数（非 DeepSeek 厂商用）。DeepSeek 的出厂默认是
    # 思考模式开、强度 high，见 R/models.R 与 R/llm.R 的说明。
    thinking         = TRUE,
    reasoning_effort = "high",

    # 当前正在看的对话。由对话页镜像过来（见 mod_chat_server 里那条 observe），
    # 给「文件」页用来定位对话工作区 —— "当前对话"这个概念只有对话页有，
    # 文件页要展示"本对话产物"就只能读这个。
    # ⚠️ 只读镜像，别在别的模块里改它。
    chat_session_id = NULL,

    # ---- 任务页 ↔ 文件页的互跳（V8 item 5）-------------------------------
    #
    # 用户的原话是「任务和文件管理区还是有点脱钩，让二者更有互动性一些」。
    # 两个方向都要能跳，而"要跳到哪个对话的哪条任务"这件事只有**发起跳转
    # 的那一页**知道 —— 所以过一下共享状态，而不是各页自己猜。
    #
    #   focus_ws   : list(sid=对话id, task_id=任务号, name=产物相对路径)
    #                从任务页跳到文件页时写，文件页据此换工作区、展开对应
    #                那一组、把那个文件高亮出来。文件页的「回到当前对话」
    #                把它清回 NULL。
    #   focus_task : 任务号。从文件页的产物分组跳到任务页时写，任务页据此
    #                选中并滚动到那一行。
    #
    # ⚠️ 这两个是"一次性指令"不是"状态"：接收方处理完就清掉（或在下一次
    #    跳转时被覆盖）。留着不清的话，用户手动切回文件页时会被莫名其妙地
    #    拽回上一个被点过的对话工作区。
    focus_ws   = NULL,
    focus_task = NULL,

    # ---- 对话消息的跨模块版本号（V11 item 8）-----------------------------
    #
    # 对话页的历史用 hist_ver 做版本号，但那个 reactiveVal 是**对话页模块
    # 自己的**，别的模块碰不到。而 item 8 要求「历史任务」页点重跑出来的
    # 结果也写回它所属的那条对话 —— 写是写进去了，对话页却不知道，用户切
    # 回去看见的还是旧的那一屏，得刷新浏览器才出来。表现就是"点了没反应，
    # 刷新又对了"（和 sendCustomMessage 那类 proxy 问题同一个症状）。
    #
    # 所以过一下共享状态：谁往对话里写了消息，谁就把它加一；对话页的历史
    # 和会话列表都依赖它。
    #
    # ⚠️ 这是**本会话**的计数器，不是全局的。state 是每个浏览器会话各一份
    #    （上一格 root_session 的注释里解释了为什么这里的东西都不能跨会话
    #    用）。多标签页同时开着同一账号看同一条对话时，另一个标签页不会跟着
    #    刷 —— 但 item 4b 已经把同账号多端登录禁掉了，同一时刻只有一个。
    msg_rev = 0L,

    # ---- 面板尺寸的跨模块版本号（V13.2 item 5）--------------------------
    #
    # 尺寸有**两个**入口，分住在两个模块里：页面上拖分隔条（mod_chat），
    # 设置页填数字（mod_settings）。两处都要落库，而且落完之后**另一处**
    # 得跟着更新 —— 拖完分隔条，设置页那个数字框里还是旧值；在设置页改了
    # 宽度，页面上纹丝不动。两个方向的症状都是"看起来没保存上"。
    #
    # 过一下共享状态，和上面 msg_rev 是同一个套路：谁存了谁加一，两边都
    # 依赖它，各自重新读一遍库。值本身存 users.ui_prefs，这里只是个信号，
    # 不要在这里存尺寸（两个会话看到的就是两份状态了）。
    uipref_rev = 0L,

    # ★ V13.4 item 7：conda 环境清单一有变化就加一。
    #
    #   用户原话：「言出法随的环境界面，并没有同步内置环境，选项里只有系统
    #   环境一个」。除了"内置模板没列出来"（那是另一处改动），还有一半原因
    #   在这里：对话页那个下拉框是**渲染一次就再也不刷新**的 ——
    #   V11 item 4 把 "每 5 秒 invalidateLater 一次" 那段轮询**故意**删了
    #   （理由见 mod_chat.R 里那段注释：那个定时器每个会话都在空转，而
    #   dsapp_envs_list 是走磁盘的）。删得对，但删完之后就再没有任何东西
    #   能让它更新了 —— 在「环境」页建完环境回到对话页，下拉里还是老样子。
    #
    #   这里补的是**事件驱动**的那一半：谁把环境建好了、谁把环境删了，
    #   谁就把这个数加一；对话页那个 renderUI 依赖它。平时一次都不跑。
    env_rev = 0L,

    # 任务页 → 对话页的"这次挂在环境问题上了，你来接手"（V11 item 8）。
    # 形如 list(sid=, tid=, env=, n=)。n 是序号，理由见 mod_chat 里那条
    # observeEvent 的说明（Shiny 对值相同的输入不重复触发）。
    # 和上面 msg_rev 一样是**本会话**的，用来在同一个浏览器会话的两个模块
    # 之间传话，不跨会话。
    env_fix_req = NULL,

    # ---- 界面皮肤（V8 item 4）--------------------------------------------
    #
    # 这个值**只是服务端的一份镜像**，真正生效的是浏览器上那个
    # `<html data-skin>` 属性（见 www/skins.css）。改 state 不会让界面变样，
    # 必须同时发 dsapp:skin 消息 —— 两条路都在 dsapp_skin_apply() 里。
    #
    # ⚠️ 不要把它当成"当前主题"去参与别处的判断（比如给图表配色）。它是
    #    账号偏好，断线时可能和浏览器上真实生效的那个不一致；要判断"现在
    #    长什么样"，唯一的真相在客户端。
    skin = "dark",

    # 远程节点名册的**会话内**凭据缓存：节点 id → list(password, key_text)。
    # 名册本身（R/nodes.R）只存机器身份，凭据永远不落盘；这个缓存是为了
    # 让同一次会话里来回切两台机器时不用反复重填。模块第一次用到时自己初始化。
    node_creds = list(),

    # 分析环境（item 2）
    #   exec_target: "server" | "local" | "remote"
    #   exec_env   : "system" 或 conda 环境名（仅 exec_target = "server" 时有效）
    exec_target = "server",
    exec_env    = "system",
    remote      = list(host = "", port = 22, user = "", auth = "password",
                       password = "", key_text = "", activate = "",
                       workdir = "", verified = FALSE),

    # ---- 顶层 session（给模块里的跳转用）--------------------------------
    #
    # ⚠️⚠️ 这一格不能删，模块里的页签跳转全靠它。见下面 `state$root_session
    #      <- session` 那段的长注释 —— 用模块自己的 session 跳转是**静默
    #      失效**的（不报错、就是没反应），2026-09-14 用户报的
    #      「在「文件」页管理 →」点不动就是这个。
    root_session = NULL
  )

  # ---- 把**顶层** session 存进 state，给模块里的跳转用 ------------------------
  #
  # ⚠️⚠️ 这不是可有可无的便利。模块里**根本没法**跳到别的页签：
  #
  #   Shiny 的 moduleServer 给模块发的 `session` 是个 session_proxy，它的
  #   `sendInputMessage` 会先把 id 过一遍命名空间：
  #       sendInputMessage = function(inputId, message)
  #         self$sendInputMessage(ns(inputId), message)     # shiny 源码
  #   而 bslib::nav_select("nav", tab) 走的就是 sendInputMessage。于是模块里
  #   发出去的是 "chat-nav" 而不是 "nav" —— 页面上没有这个元素，**什么也不
  #   发生，也不报错**。传 session = session 没用（那个 session 也是代理），
  #   session$parent 也没用（不是父 session，取到的是别的字段）。
  #
  #   2026-09-14 用一个最小 Shiny 应用实测过四种写法，只有「在顶层调
  #   nav_select」跳得动。用户报的「言出法随页面『在「文件」页管理 →』点不
  #   动」就是这个 —— 顺带一提，「去设置」那个按钮当时也是坏的，同一个原因。
  #
  # 放在这里（reactiveValues 之后、模块实例化之前）：这一行只写一次，写在
  # 任何 observer 被创建之前，所以读它的人永远不会被它反过来失效一次。
  #
  # 用的时候：dsapp_nav_to(state, "files")，见 R/utils.R。
  state$root_session <- session

  # ---- 主菜单那条分隔条拖完之后的上报（V13.5 item 8）------------------------
  #
  # ⚠️ 这一条**必须**待在顶层，不能塞进任何一个模块里：
  #    主菜单那条把手（`split_m`）长在 app.R 的外壳里，不在模块里，所以它的
  #    id 没有命名空间前缀，app.js 的 report() 算出来的 input 名就是**顶层**
  #    的 `panel_size`。对话页那三条分隔条算出来的是 `chat-panel_size`
  #    （见 mod_chat.R 里那条同名的 observer），两条路各收各的。
  #
  #    塞进模块的后果不是报错，是**拖完松手宽度弹回去** —— 模块收到的是
  #    `chat-panel_size`，那条永远不会有消息；而这里没有 observer，
  #    `input$panel_size` 谁也不理。控制台干干净净。
  #
  # ⚠️ ignoreNULL / ignoreInit 都要给上：`panel_size` 不是某个控件的值，
  #    是 app.js 用 Shiny.setInputValue 发的普通 input。初始化那一下是 NULL，
  #    不 ignore 的话会拿 NULL 去覆盖用户已经存好的尺寸。
  observeEvent(input$panel_size, {
    p <- input$panel_size
    if (is.null(p) || !is.list(p)) return()
    uid <- state$user_id
    if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
    # 只写报上来的那个键，其余沿用**库里现在的**值 —— dsapp_uipref_save()
    # 收的是一份完整偏好，少给一个键它会把那个键打回默认值（表现在用户那边
    # 就是"拖完主菜单，文件区宽度自己变回 320 了"）。
    full <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                     error = function(e) dsapp_uipref_norm(NULL))
    if (!is.null(p$menu_w)) full$menu_w <- p$menu_w
    # 另外几条理论上不会从这条路上来（它们报的是 chat-panel_size），
    # 但既然消息里带了就一并收下 —— app.js 那边是共用一个 report() 的。
    if (!is.null(p$files_w))    full$files_w    <- p$files_w
    if (!is.null(p$composer_h)) full$composer_h <- p$composer_h
    if (!is.null(p$sess_w))     full$sess_w     <- p$sess_w
    try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg)), silent = TRUE)
    state$uipref_rev <- state$uipref_rev + 1L
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # ---- 主菜单里导航项拖完重排之后的上报（V13.11 item 3）---------------------
  #
  # 和上面那条 `panel_size` 是**同构**的，几条约束也一模一样：必须在顶层
  # （左栏长在 app.R 的外壳里，app.js 报的是裸 `nav_order`，没有命名空间）、
  # 必须 ignoreNULL + ignoreInit（它同样不是控件的值，是 JS 发的普通 input，
  # 初始化那一下是 NULL）。
  #
  # ⚠️ 收到的 ids 是**浏览器发过来的**，不能直接信 —— 它会被存进
  #    `users.ui_prefs`。白名单在 dsapp_uipref_one() 里（`v %in%
  #    DSAPP_NAV_VALUES`），这里和上面那条一样走 dsapp_uipref_save()，
  #    脏值进不了库。
  #
  # ⚠️ **拖完不重画左栏**（不 bump 别的什么 revision）：app.js 是直接改 DOM
  #    完成重排的，重画会把用户刚拖好的那一下闪一下，还可能把他正在进行的
  #    第二次拖动打断。顺序下一次渲染自然就对了（换账号 / 刷新）。
  #    唯一要 bump 的是 uipref_rev —— 设置页那张卡片靠它知道自己该重读。
  observeEvent(input$nav_order, {
    ids <- input$nav_order
    if (!length(ids)) return()
    ids <- as.character(unlist(ids, use.names = FALSE))
    ids <- ids[!is.na(ids) & nzchar(ids)]
    if (!length(ids)) return()
    uid <- state$user_id
    if (is.null(uid) || is.na(suppressWarnings(as.integer(uid)))) return()
    full <- tryCatch(dsapp_uipref_get(uid, con = dsapp_db(cfg)),
                     error = function(e) dsapp_uipref_norm(NULL))
    # ⚠️ 整份换掉，不是并进去 —— 这个值表达的就是"完整顺序"，只发一项
    #    没有意义（同 dsapp_skill_order_set 的约定）。
    full$nav_order <- ids
    try(dsapp_uipref_save(uid, full, con = dsapp_db(cfg)), silent = TRUE)
    state$uipref_rev <- state$uipref_rev + 1L
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # ---- 直接进入（auth_mode = "auto"，非默认；默认是 "login"，见 config.R）----
  #
  # ⚠️ 这一段必须在**模块实例化之前**跑。模块的 server 函数一构造就会读
  #    state（当前账号、当前对话……），放在后面的话它们拿到的还是"没登录"
  #    的那一份，表现就和"换了账号没重载"一模一样 —— 也就是 session$reload()
  #    当初要解决的那个问题。放在前面，那个窗口压根不存在。
  #
  #    它和 on_login(reload = TRUE) 不是重复实现，是两种策略：
  #      · 那条路：页面已经活着、用户中途换了个账号，非重载清不干净；
  #      · 这条路：页面刚生出来、还没有任何账号状态，本来就没有要清的东西。
  #
  #    为什么整件事搬回服务端：登录那一跳原本依赖浏览器执行 app.js（写
  #    cookie、交回执、把 cookie 交回来），而线上那位浏览器里跑的是**缓存
  #    下来的旧 app.js**（那版还没有 cookie 这套东西），于是回执永远不来 →
  #    超时 → 重载 → 新会话没有任何身份 → 回到登录页，反复如此。进门这件事
  #    不该由浏览器的 JS 决定成败。
  #
  #    证据（2026-09-13）：auth.log 里他两次登录前后**一次都没有**"页面加载："
  #    那一行 —— 而那行是 app.js 每次连上都会写给服务端的；我用干净浏览器
  #    打开线上，立刻就有了。服务端认证一直是成功的（audit_log ok=1）。
  # 兜底值跟 config.R 的默认值保持一致 —— 写岔了的表现是"配置里明明是 login，
  # 实际却直接进去了"，而这条路径不会报错。
  auth_mode <- as.character(cfg$auth_mode %||% "login")
  # ⚠️ clientData 是 reactive value，**必须包 isolate()**。裸读会抛
  #    "Can't access reactive value 'url_search' outside of reactive consumer"，
  #    而且是在会话初始化时抛 —— 整个应用起不来，页面只剩一句"与服务器的
  #    连接断了"（写完当场踩到）。
  #    也别改用 session$request$QUERY_STRING：那是**websocket 升级请求**的
  #    查询串，实测是空的（升级请求本来就不带 ?login=1），而 isolate 包住的
  #    clientData 在 server 顶层读就是对的（2026-09-13 用最小例子验过）。
  qs <- tryCatch(as.character(isolate(session$clientData$url_search) %||% ""),
                 error = function(e) "")
  force_login <- grepl("[?&]login=1(&|$)", qs)
  # 被顶下线跳回来的那一趟（见上面 dsapp:kick 那条）。
  #
  # ⚠️ 说完就得把这个参数**从地址栏抹掉**：不清的话，用户登录之后再点
  #    退出登录（那是一次 reload，地址栏还是这一条），会原样再弹一遍
  #    "你的账号在别处登录了"—— 而他这次什么都没发生。
  #    用 onFlushed（首屏渲染完）而不是立刻发：这句话本身要等页面画出来
  #    才有地方显示，先抹掉地址栏再渲染的话，中间那一下刷新会丢消息。
  #
  # ⚠️⚠️ 这里必须用**普通变量** kicked 做判断，不能写成 if (kicked_flag())。
  #    reactiveVal 的读取在响应式上下文之外会抛（rv$get 那层就拦下了，
  #    下面那段注释里的教训是同一个），而会话初始化这一段**不在**响应式
  #    上下文里 —— 抛出去就是整个应用起不来，用户看到的只有一句"与服务器的
  #    连接断了"。2026-09-15 写完当场踩到：自检 900 多条全绿（它读的是
  #    源码文本，不跑会话），一开浏览器白屏。
  kicked <- grepl("[?&]kicked=1(&|$)", qs)
  kicked_flag(kicked)
  if (kicked) {
    session$onFlushed(function() {
      session$sendCustomMessage("dsapp:cleanUrl", list())
    }, once = TRUE)
  }
  # 这里不查 current_user()：到这一行为止它**必然是 NULL**（只有 on_login 会
  # 写它，而此刻还没有任何东西跑过）。真要查也得包 isolate() —— reactiveVal
  # 在响应式上下文之外读同样会抛（rv$get 那层就拦下了，别问我怎么知道的）。
  # 库是全新的（一个账号都没有）时，无论什么模式都必须让人先注册。
  #
  # ⚠️ 这一条是 V6 加的，而且是必需的：V6 把默认模式改成了 "login"
  #    （用户要求"加入用户登录系统，保证可以登入"），而登录页的两个视图
  #    —— 登录和注册 —— 是**同一个页面上的两个 tab**，默认停在"登录"。
  #    全新部署上没有任何账号，用户对着登录表单填什么都是"密码不对"，
  #    而"注册"两个字藏在下面一行小链接里。先落到注册视图，第一个账号
  #    就是管理员（见 dsapp_user_create 的 is_first）。
  no_users <- tryCatch(
    DBI::dbGetQuery(dsapp_db(cfg), "SELECT COUNT(*) AS n FROM users")$n[[1]] == 0,
    error = function(e) FALSE)
  if (isTRUE(no_users)) {
    dsapp_auth_log("库里一个账号都没有，落到注册页")
  } else if (identical(auth_mode, "auto") && !force_login) {
    u <- tryCatch(dsapp_default_user(cfg = cfg, con = dsapp_db(cfg)),
                  error = function(e) NULL)
    if (is.null(u)) {
      # 一个可用账号都没有（全被停用了）。不静默 —— 直接进登录页，
      # 让人看得见发生了什么事，而不是对着一片空白。
      dsapp_auth_log("直接进入失败：库里没有可用账号，回落到登录页")
    } else {
      on_login(u, u$token %||% "", reload = FALSE)
      # 强制改密这道闸门在这里没有意义：自动进入这条路根本不用密码，
      # 所谓"管理员发的临时密码"压根没被使用过。留着它只会把人拦在
      # 改密页上 —— 而用户要的正是"别再拦我"。
      #
      # ⚠️ 判断读的是 u$must_change_pw（一个普通 list），**不是**
      #    state$must_change_pw。reactiveValues 在响应式上下文之外读会抛
      #    "Can't access reactive value ... outside of reactive consumer"，
      #    而且是在会话初始化时抛 —— 现象是整个应用只剩一句"与服务器的连接
      #    断了"（写完当场踩到）。写是安全的，读必须包 isolate()。
      if (isTRUE(as.logical(u$must_change_pw %||% FALSE))) {
        state$must_change_pw <- FALSE
        dsapp_auth_log("直接进入：跳过强制改密（这条路不走密码）")
      }
      dsapp_auth_log(sprintf("直接进入 uid=%d（auth_mode=auto，没有经过登录页）",
                             isolate(state$user_id)))
    }
  }

  # 控件 id 由各模块自己下发（见 mod_chat_server 里的 dsapp:init）——
  # 模块命名空间只有模块自己知道，在这里硬编码 "chat-xxx" 的话，
  # 改模块 id 就会静默失效。

  # ---- 心跳：告诉前端"我还活着"（V13.11 item 7）----------------------------
  #
  # 用户报"页面卡住了，刷新后正常了，也不报任何错"。复现出来了（见
  # tests/ui_v1311/probe_wedge.py）：把 R worker `kill -STOP` 冻住之后，
  # 前端 isConnected() 一直是 true、Shiny 自带遮罩不出现、原本那个
  # shiny:disconnected 处理器也不触发、控制台一条报错都没有 —— 页面看着
  # 完全正常，点什么都石沉大海，**二十秒都反应不过来**。
  #
  # 根因：所有断线检测都挂在 socket 的 close 事件上，而"对端没了"或者
  # "进程被冻住"这两种情况下 TCP 根本不会发 FIN/RST，close 事件永远不来。
  # 浏览器那边**没有**任何办法从连接状态上分辨"服务端在忙"和"服务端没了"。
  #
  # 所以判据只能是"它多久没跟我说话了"。这条 observe 就是那句话：每
  # DSAPP_PING_MS 毫秒发一次心跳，前端连着 DSAPP_PING_DEAD_MS 没收到就报
  # 「服务端没有响应」。两个数在 config.R 里，前端那份在 www/app.js。
  #
  # ⚠️ 这条 observe **必须裸着**（不读任何 reactive）：读一个 reactiveVal
  #    就会建立依赖，而这个 observe 每 4 秒写不了那个值、却每次都要重跑，
  #    结果是它自己把自己反复失效掉 —— 定时器瞬间烧穿，然后静默停掉。
  #    （同一个坑见 R/uiprefs.R 和 mod_chat.R 里那几处 invalidateLater。）
  #
  # ⚠️ 开销：每个开着的页面每 4 秒一条消息，内容是空对象。和上面那条
  #    15 秒一次的库查询比可以忽略，但它**确实是**每个访客都多出来的
  #    一条定时器 —— 所以别再往上加第二条，要加就并进这一条。
  #
  # ⚠️ 它不阻止 Shiny Server 回收空闲 worker：那个 `app_idle_timeout` 数是
  #    "多久没有连接"，不是"事件循环多久没动静"。开着页面本来就钉住 worker
  #    （见 history_Version 里那份部署说明），这里没有改变那件事。
  #
  # ★★ V15.6 第 4 条查清了「运行一半弹『与服务器的连接断了』」是什么：
  #    **这条心跳是症状，不是病因。**
  #
  #    病因在别处：`observe` / `observeEvent` 里抛出**没人接**的错误时，Shiny
  #    的处理是 `session$unhandledError(e, close = TRUE)` —— **把这个会话判
  #    死刑、直接把 socket 关掉**。会话一关，它名下的定时器（包括这条心跳）
  #    全被清掉，前端等不到心跳就报「与服务器的连接断了」，整页点不动
  #    （判死线 2026-10-07 从 16 秒抬到 30 秒，见 www/app.js 顶部那段）。
  #    用户看到的"断连"其实是"服务端刚刚把一个错判成了致命错误"。
  #
  #    2026-09-30 实测（/tmp/hbtest3，同一个进程同一颗炸弹，只换位置）：
  #      · 炸弹放在 renderText 里 → 会话活着、心跳照跳、点击正常（Shiny 自己
  #        就把渲染错误兜住了，画成一张报错卡片）
  #      · 炸弹放在 observe 里    → 心跳停在第 7 跳、onEnded 当场触发、
  #        浏览器收到 shiny:disconnected  ← 就是用户报的那一幕
  #
  #    所以修的是那一头：**软错误不再判会话死刑**（R/errhand.R 的
  #    dsapp_err_soften_session()，由 server() 开头装上）。这里的心跳一个字
  #    都不用改 —— 会话不死，它就照跳。
  observe({
    invalidateLater(DSAPP_PING_MS)
    session$sendCustomMessage("dsapp:ping", list(t = as.numeric(Sys.time())))
  })

  # ⚠️ V13.12 item 19 删掉了这里的一条转发：原来 www/app.js 会把左栏那块
  #    <details> 被收起这件事上报成 input$rail_model_closed（递增计数），
  #    再由这里转进 state 给 mod_model 用。模型服务搬成独立页之后，
  #    "离开"就是**切页**，那个信号由上面 input$nav 那条直接发布
  #    （state$nav），不再需要前端上报 —— 那块 <details> 已经不存在了。

  # 同步收件箱的周期检查（V13.3 item 2）：页面**已经开着**的时候来了新包。
  # 会话开始那一次见 server() 头部 —— 那一次是为了"第一屏就是新的"。
  #
  # 5 秒是挑的：比它更密没有意义（对端的推送本来就是分钟级的），更稀则
  # 用户在页面上等着同步生效时会觉得"点了没反应"。真正的开销只有
  # list.files() —— 有新包才会去读 JSON、写库。
  observe({
    invalidateLater(5000)
    try(dsapp_sync_maybe_apply(cfg), silent = TRUE)
  })

  # 引擎轮询：所有会话都在轮询，谁先发现任务结束谁负责收尾（引擎内部保证
  # 只收尾一次）。任务结束后给当前会话一个提示。
  observe({
    if (!isTRUE(engine$state$running)) return()
    invalidateLater(1000)

    done <- engine$poll()
    if (!is.null(done)) {
      # ★ 只提示**这个会话的主人**。引擎是全局单槽的，谁都可能先发现任务
      #   结束并把 handle 置空 —— 不判归属的话，甲提交了任务，乙的浏览器上
      #   会弹出「任务 #12 执行失败」，连任务号都看得见。乙既没提交过、
      #   也无从处理，这既吵又漏信息。
      #
      # ⚠️ 任务表的归属只能从会话推（tasks 没有 user_id 列，见 db.R 的
      #    db_session_owner 说明）。任务行可能已经被用户删了，那时不提示 ——
      #    "任务没了"本来就不是一条值得弹出来的消息。
      .tid <- done$task_id
      .trow <- tryCatch(db_task_get(.tid, con = dsapp_db(cfg)),
                        error = function(e) NULL)
      .owner <- if (is.null(.trow)) NULL
                else tryCatch(db_session_owner(.trow$session_id[1],
                                               con = dsapp_db(cfg)),
                              error = function(e) NULL)
      .uid <- isolate(state$user_id)
      if (is.null(.owner) || is.null(.uid) || !identical(as.integer(.owner),
                                                         as.integer(.uid))) {
        return()
      }

      if (identical(done$status, "success")) {
        # ★ V12 item 3：产物现在**自动**同步进文件管理区了。这句话必须跟着
        #   改 —— V3 之后它一直写的是"在「文件」页的对话产物里，可下载或
        #   发布"，而自动同步上线之后这个说法会把用户支到一个已经不是
        #   首选的位置去。
        #
        #   仍然如实报数：同步有上限（见 DSAPP_SYNC_MAX_FILES / MAX_BYTES），
        #   被挡下来的那些要说到，不能让用户以为"产出 400 个文件"就全都
        #   在「文件」页里躺着。
        n_art   <- length(done$artifacts)
        n_saved <- length(done$saved)
        sy      <- done$synced %||% NULL
        extra <- if (n_saved > 0) {
          sprintf("，%d 个文件已回传到文件管理区", n_saved)
        } else if (!is.null(sy) && isTRUE(sy$ok) && (sy$n %||% 0L) > 0L) {
          sprintf("，%d 个产出已同步到「文件」页的「%s」",
                  as.integer(sy$n), sy$dir %||% "")
        } else if (!is.null(sy) && (sy$skipped %||% 0L) > 0L) {
          # 一个都没同步过去，但确实有产物 —— 说清楚是在**哪儿**，以及
          # 为什么没同步。
          # ⚠️ Test_V16.9 起 `skipped` 只数**结构性跳过**（工作区内部文件、
          #    指向共享区的软链、目标路径非法）—— 那些本来就**不该**进文件
          #    管理区，不是故障，所以措辞是"未纳入同步"而不是"没能同步"。
          #    原来这里的注释写"多半是超了体积上限"，那条路已搬去 `blocked`。
          sprintf("，产出 %d 个文件（在「文件」页的对话产物里；%d 个未纳入同步）",
                  n_art, as.integer(sy$skipped))
        } else if (n_art > 0) {
          sprintf("，产出 %d 个文件（在「文件」页的对话产物里，可下载或发布）", n_art)
        } else ""

        # ★★ Test_V16.9：被**上限**挡下来的产物必须说出来。
        #
        # 用户原话：「对话页面的文件展示的是全的，但是文件区的文件几乎没有，
        # 点同步也没用」。全库核对下来是 298 个文件、9 GB 没进文件管理区，
        # 而其中 119 个来自同一个对话 —— 从 V12 自动同步上线到 V16.8，
        # **没有任何一个地方说过这件事**。这一段就是把那两个字去掉。
        #
        # ⚠️⚠️ 单独拼、**不并进上面那串 if**。上面第一条 `n_saved > 0` 就
        #    短路了，而"同步了 300 个、另外 50 个被上限刷掉"恰恰是最常见的
        #    形态 —— 并进去等于在唯一真会出事的场景里恰好不吭声。
        #    （同理，`sy` 为 NULL 时下面拿到 0L，不会炸。）
        #
        # 措辞三件事要说全：少了几个、**去哪儿补**、以及**别吓人** ——
        # 文件在工作区里好好的，只是没进管理区。所以用 message 样式
        # （这一支本来就是），不用 warning/error。
        n_blocked <- as.integer(sy$blocked %||% 0L)
        blocked_note <- if (n_blocked > 0L) {
          # ⚠️ 按钮名要**逐字**是界面上那个（`R/mod_files.R` 的
          #    `output$import_ws_ui`：「导入对话产物」）。写一个界面上不存在
          #    的按钮名，用户会挨个找一遍然后放弃 —— 比不说还糟。
          sprintf("；另有 %d 个产出超出单次同步上限，未进「文件」页 —— 到「文件」页点「导入对话产物」就能补上",
                  n_blocked)
        } else ""
        # 增量库没建起来（.Rlib 建不了 / .venv 建不了）时如实说一句。执行
        # 本身是成功的，所以这里不能用 error 样式 —— 那会让用户以为任务挂了。
        # 不说的话，下一次装包的代码会悄悄装到共用位置去。
        note <- if (length(done$env_notes)) {
          paste0("（", paste(done$env_notes, collapse = "；"), "）")
        } else ""
        showNotification(sprintf("任务 #%d 执行完成%s%s%s",
                                 done$task_id, extra, blocked_note, note),
                         type = "message",
                         # 这句话比平时长，8 秒读不完；提示里带着"下一步动作"，
                         # 用户没读到就等于没说。
                         duration = if (n_blocked > 0L) 15 else 8)
      } else if (identical(done$status, "timeout")) {
        showNotification(sprintf("任务 #%d 超时被终止，详情已写在对话里",
                                 done$task_id),
                         type = "warning", duration = 8)
      } else {
        # ⚠️ 原来这句是「执行失败，详见任务页」（V9 item 8）。那是把用户
        #    从出问题的地方**支走** —— 他刚在对话页点完执行，弹一句"去别的
        #    页面看"，而这一页现在就有报错原文和「让 AI 分析这个报错」。
        showNotification(sprintf("任务 #%d 执行失败，报错已写在对话里",
                                 done$task_id),
                         type = "error", duration = 8)
      }
    }
  })

  # 入口页。即使已经登录也要注册它的 server —— moduleServer 的 UI 没渲染
  # 不代表 server 不存在，反过来也一样；不注册的话，退出登录时那一页会
  # 渲染出来但点任何按钮都没反应。
  mod_welcome_server("welcome", entry_token, on_login, entry_src)

  # 强制改密页。改完把闸门打开 —— 不重新登录，用户刚证明过自己是谁
  # （填了旧密码或恢复码），再让他登一次纯属折腾。
  mod_force_pw_server("force_pw", state, function() {
    state$must_change_pw <- FALSE
    # 顺手刷新内存里那份用户行：设置页的「账号密码」卡片读的是**库**，
    # 但 state$user 在别处也被读（比如管理员的判断），保持一致没坏处。
    u <- tryCatch(dsapp_user_by_id(state$user_id, con = dsapp_db(cfg)),
                  error = function(e) NULL)
    if (!is.null(u)) state$user <- u
    showNotification("密码已更新", type = "message")
  })

  # 用户须知确认页（V9 item 1）。和 mod_force_pw_server 一样，**无条件注册** ——
  # 界面没渲染不代表 server 不存在，反过来也一样；不注册的话，被拦到这一页
  # 时点"同意"没有任何反应。
  #
  # 同意之后**不 reload**：用户刚刚在库里留下了记录，把 tos_ack 打开就能进
  # 主界面。reload 一次要多等几秒，还会把"我点了同意"这件事变成一个
  # 白屏加载，看起来像出了问题。
  mod_tos_gate_server("tos_gate", state, function() {
    tos_ack(TRUE)
    dsapp_audit("tos_agree", user = state$user, user_id = state$user_id,
                session = session, cfg = cfg)
    showNotification("已记录你的确认，谢谢", type = "message", duration = 4)
  })

  mod_chat_server("chat", state, engine)
  mod_tasks_server("tasks", state, engine)
  # ⚠️ `active` 是**当前页签**（V13 item 2 加的）。这一页挂着一个"扫一遍所有
  #    对话工作区、把历史产物补同步过来"的活，而它是渲染路上的一次写盘 ——
  #    放在模块初始化时做（也就是**每个人一登录**就做）会让登录明显变慢，
  #    而绝大多数登录根本不看文件页。所以把页签状态传进去，等用户真的点开
  #    「文件」再干。
  #
  #    ⚠️ 不要改成在模块里读 input$nav：模块的 input 是**带命名空间**的
  #       代理，读一个非命名空间的 id 会永远拿到 NULL（见 skills.R / users.R
  #       里关于 session 是 proxy 的说明），表现是"这段代码从来没跑过"。
  mod_files_server("files", state, active = reactive(input$nav))
  mod_skills_server("skills", state)
  mod_envs_server("envs", state, engine)
  # V13.11 item 5：文献速递。这一页**不自己发请求** —— 它把提示词和要挂的
  # 技能交给 mod_chat 那条 lit_go 的路去建对话、发消息（见 R/mod_lit.R 顶上）。
  mod_lit_server("lit", state)
  # V15 item 8：论坛。注册**无条件**做（和 mod_admin / mod_htadmin 同一个
  # 理由）：这一页**所有人都看得见**，没有按角色筛的渲染分支 —— 管理员只是在
  # 页内多几个按钮（置顶/隐藏/公告），而那几个按钮由模块自己按 state$user 判。
  mod_forum_server("forum", state)
  # 模型服务（左侧栏常驻）。必须和 mod_settings 一起注册 —— 它才是
  # state$api_key / model / base_url / temperature / max_tokens 的写入口，
  # 而对话页发消息前读的正是这几个值。
  mod_model_server("model", state)
  mod_settings_server("settings", state)
  mod_admin_server("admin", state, engine)
  # 后台页（V13.8 item 2）。注册**无条件**做，页面本身由 app.R 里那道
  # `identical(admin_scope, "platform")` 决定渲不渲染 —— 模块里的
  # guard() 是另一道（服务端鉴权，见 R/mod_htadmin.R 文件头）。
  # ⚠️ 不要改成 `if (is_admin) mod_htadmin_server(...)`：那样注册与否
  #    取决于**渲染那一刻**的身份，而 state$user 是登录快照 ——
  #    结果是"登录时是普通用户的人，在同一个会话里被提成管理员之后
  #    刷新页面，后台页出来了但点不动"。两道闸各司其职，别合并。
  mod_htadmin_server("htadmin", state, engine)
  # ★ V15.4 item 8：系统提示词编辑器。和上面两组一样**平级**注册，命名空间
  #   就是它 UI 用的那个（R/mod_backstage.R 里 `mod_prompt_ui(NS("prompt"))`）。
  #   ⚠️ 不要改成把它套进某个 moduleServer 里面：嵌套的 moduleServer 加不加
  #      前缀随 Shiny 版本变，错了的症状是"按钮点了没反应、也不报错"。
  #   注册同样无条件（页面渲不渲染由 mod_backstage_ui 那道 UI 闸决定，
  #   模块里每个写操作开头的 guard() 是第二道）。
  mod_prompt_server("prompt", state)

  # ★ V15.8 item 2：云工具。**无条件**注册，理由和上面几组一样 ——
  #   这个模块要拿到 engine（它要把四步依次提交到执行器那个全局单槽里）。
  #   ⚠️ 页面本身对所有登录用户可见；能不能跑由体检那几条（环境/权重/GPU
  #      放行）如实显示，不在这里挡。
  mod_cloudtool_server("cloudtool", state, engine)
}

# ---- 退出 -------------------------------------------------------------------

# 收尾：停掉还在跑的作业（否则执行进程会变成孤儿），
# 并把 WAL 内容合并回主库文件 —— 不做的话强杀进程可能丢掉最近的会话记录。
onStop(function() {
  # reason 要和"用户点了停止"区分开：一个是被停的，一个是应用关了。
  # 注意顺序 —— engine$abort() 要写库，必须赶在 dsapp_db_close() 前面。
  try(engine$abort(reason = "应用关闭，任务被中断"), silent = TRUE)
  try(dsapp_db_close(), silent = TRUE)
})

shinyApp(app_ui, server)
