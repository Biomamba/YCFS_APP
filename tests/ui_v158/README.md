# tests/ui_v158 —— 浏览器验收（Test_V15.8 + V15.9 + V15.10）

V15.8 的四件事里，三件要在**浏览器里**才算数：GPU 入口、切模型、云工具页。
R 那一层的验收在 `tests/v158_gpu.R`（23/23）和 `tests/v158_cloudtool.R`（60/60）。

V15.9 只有一件事（线上账号 `Biomamba_ceshi` 报「与服务器的连接断了」），
浏览器探针 `probe_heal.py` 就放在这个目录里 —— 它跟 V15.8 那几个共用
`_common.py` 和同一套起实例的做法，单开一个 `ui_v159/` 只会多一份要同步的
副本（本仓已经因为 `_common.py` 有 6 份副本吃过亏，见下面那条坑）。

V15.10 也只有一件事：用户报「还是会出现**页面未响应**」。那一轮全是**诊断**
（`diag_*.py`，只观察不断言），结论落在 `app.R` 的一个开关上（见下面
「V15.10：页面未响应」那一节）；R 那一层的验收在 `tests/v1510_perf.R`（32/32）。

| 脚本 | 管什么 | 条数 | 端口/目录（默认） |
|---|---|---|---|
| `probe_ctx.py` | item 3 上半：换模型**继承上下文** | 20 | 8951 / `/tmp/dsapp_v158i` |
| `probe_switch.py` | item 3 下半：对话页那一格能换模型 | 13 | 同上 |
| `probe_cloudtool.py` | item 2：云工具页**真跑完四步** | 67 | 同上 |
| `probe_crash.py` | item 4：千问那件事的**有界阴性**结论 | 24 | 8952 / `/tmp/dsapp_v158c` |
| `probe_heal.py` | **V15.9**：断线之后页面能不能**自己回来** | 21 | 8953 / `/tmp/dsapp_v158h` |
| `diag_boot.py` | 诊断：注册完那一跳卡在哪儿（只诊断，不断言） | — | 同上（8952） |
| `diag_heal.py` | 诊断：自愈跑到哪一步 / 冻住服务端会怎样（只诊断） | — | 同上（8953） |
| `diag_freeze.py` | **V15.10** 诊断：把用户那个 43 条 / 203 KB 的会话原样搬进实例，量「页面未响应」卡在哪一侧 | — | 同上（8953） |
| `diag_slow.py` | **V15.10** 诊断：**慢**流式（60 秒吐 20 KB）那一幕 —— 和 `diag_freeze` 的"一口气 30 KB"不是一回事 | — | 同上 |
| `diag_multi.py` | **V15.10** 诊断：一个 worker 被**几个会话**同时占住时，旁观那个页面会怎样 | — | 同上 |
| `diag_reload.py` | **V15.10** 诊断：一次普通注册，页面会不会自己 reload（`dsappHealStrike` 那条路） | — | 同上 |

## 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8951 /tmp/dsapp_v158i
python3 tests/ui_v158/probe_ctx.py          # 退出码 0 = 全绿
python3 tests/ui_v158/probe_switch.py

# probe_crash 用另一个端口/目录（默认值写死在它自己头上，改 env 可覆盖）：
bash tests/ui_v7/make_instance.sh 8952 /tmp/dsapp_v158c
python3 tests/ui_v158/probe_crash.py

# probe_heal 又是另一个（它要把服务端 kill -9 / kill -STOP，不能和别的共用）：
bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
python3 tests/ui_v158/probe_heal.py
```

> ⚠️ `probe_heal.py` **会把这个实例上的 R 进程打死再拉起来**（B/C 段就是干
> 这个的）。它跑完会自己把实例拉回来，但**别拿它跟别的探针并行跑**。
> `diag_heal.py` 同理会打死一次、冻住一次。

**云工具那一支不一样**，要走它自己的壳：

```bash
bash tests/ui_v158/run_cloudtool.sh 8951 /tmp/dsapp_v158i
```

> ⚠️ **为什么云工具非要一个壳**：这台机器上**没有** foundry 的四份权重
> （几 GB，要外网），而「开始运行」会**先跑体检、体检不过就拒绝提交任务**。
> `run_cloudtool.sh` 造一套桩工具链（rfd3 / mpnn / rf3 / python 四个桩程序 +
> 四份空文件当权重 + 占位 `evaluate_rf3.py`），并把四个环境变量
> （`DSAPP_RFD3_ENV` / `DSAPP_FOUNDRY_CKPT` / `DSAPP_CLOUD_SCRIPT_DIR` /
> `DSAPP_EXEC_GPU`）**导出给子进程**再起实例 —— 它走的是**平台真正的执行器**
> （起任务、建工作区、写 `.dsapp_stdout`、落任务行），只有那四个外部程序是假的。
> 直接 `python3 probe_cloudtool.py` 的话 B 段会红在第一行，并直接说
> 「实例没带 DSAPP_RFD3_ENV 起」—— 响的失败，不会伪装成功能坏了。
>
> ⚠️ 那四个变量**不能写进 `app/.Renviron`**：`make_instance.sh` 每次都会重写
> 那个文件，加进去的行下一次同步就没了，症状是「昨天还能跑，今天预检就红了」。

数据目录 `/tmp/dsapp_v158i/data`、截图 `/tmp/dsapp_ui_v158`。
换目录/端口用 `DSAPP_TEST_URL` / `DSAPP_TEST_APP` / `DSAPP_TEST_OUT`。

## 这一版在验什么

- **item 1** GPU：入口在不在、「设置 → 硬件选择」那个开关**写没写进库**、
  放行之后任务里真的能看见卡（`tests/v158_gpu.R` + `probe_switch.py` 的 D 段）。
- **item 2** 云工具：原理/功能说明、参数表单、体检八项、**四步依次真跑**、
  收货表（空值不当 0 分）、建议、产物落在**这个对话**的工作区。
- **item 3** 对话途中切模型：能继承上下文（`probe_ctx`），而且对话页那一格
  真的能用（`probe_switch`）—— 写库的是模型页那条老路，这一格只是入口。
- **item 4** 千问/崩溃：见 `probe_crash.py` 顶上的说明，那一份给的是**有界的
  阴性结论**，不是「已修复」。它量**两幕**：正文区（≈32K 字符、切成 326 个
  SSE 事件）和**思维链**（12.6K 字符、140 段）—— 后者才是千问那条路
  （`reasoning_content` 在 `R/llm.R` 里是无条件解析的，而思考区走的是
  `sendCustomMessage` → `www/app.js` 往 `#chat-think_pre` 追加，**和正文那条
  renderUI 不是同一条渲染路径**）。
- **V15.9** item 1 断线自愈：`kill -9` 服务端 → 断线提示出现（且是 `disconnected`
  那一种）→ **页面自己整页重载回来**、自动登录仍成立、回来之后还能发消息；
  反面：`kill -STOP` **冻住**服务端（TCP 没断，只可能走"心跳判死"）→ 该报
  `silent`、**一次都不许重载**（那会把用户正在跑的活扔掉）、解冻后该自己好。
- **V15.10** 页面未响应：**R 的 JIT**，不是应用里哪一段自己慢。四条 `diag_*`
  探针量完"服务端最坏卡多久 / 浏览器最坏掉多少拍"都够不着 16 秒那条判据，
  真正的账在**每个 worker 世代的第 2 个会话**那一段（8.0 s → 1.0 s，见下）。R 层验收在
  `tests/v1510_perf.R`（32/32：配置缓存 11 条、用户气泡 4 条、代码卡片 7 条、
  速度 2 条、JIT 8 条）。

## V15.10：页面未响应 —— 根因是 **R 的 JIT**

用户原话（2026-10-02 晚，V15.9 上线之后）：「我看到你更新到15.9了，但是还是
会出现页面未响应的状态，请解决这个问题，否则不用做其它任何更新」。

**四条 `diag_*` 探针全是"有界的阴性"**：服务端最坏卡 5 秒、浏览器最坏掉
340 ms、多会话互挤也够不着"16 秒没收到心跳"那条判据。也就是说，**卡的地方
不在这几条路里**。回头去 profile 线上 worker，采到的调用栈里排第一的是：

```
compiler:::tryCmpfun → cmpfun → genCode → putconst → findCenvVar → tryInline
```

也就是 **R 自己在给函数做字节编译**。R 默认 `enableJIT(3)`，语义是：一个闭包
**第二次被调用之前**，当场给它做字节编译（第一次仍是解释执行 —— 所以"第一次
打开"看不出异常，这正是它一直没被怀疑的原因）。而 R 的字节编译器在**又大又平**
的函数体上超线性地慢（`v1 <- 1+1; v2 <- 2+1; …` 拼出来的闭包实测）：

| 语句条数 | 编译一次 | 执行一次 |
|---|---|---|
| 500 | 0.165 s | |
| 1000 | 0.419 s | |
| 2000 | 1.276 s | |
| 4000 | 4.190 s | 0.040 s |

本应用 `mod_chat_server` 2950 行、`mod_admin_server` 1226 行、`mod_files_server`
1190 行……16 个模块 server 编一遍合计 **5769 ms**（`mod_chat_server` 一家
1462 ms）。**worker 空闲 5 秒就被杀**（Shiny Server 的 `app_idle_timeout`），
所以这不是"启动一次"的开销 —— 用户离开一会儿再回来、worker 换成下一代，
就得**再付一次**。这才是"有时候会卡"的来源。

端到端 A/B —— **拿仓库里那份真 `app.R`**（就是现在这份），用
`DSAPP_JIT` 这个开关起实例，浏览器连开三页，量每一页
「`server()` 建立 → 第一次 flush 结束」（= 用户"点进来卡住"的那一段）：

| 每一页的 session_ready | 第 1 页 | 第 2 页 | 第 3 页 |
|---|---|---|---|
| **JIT 0**（V15.10 起） | 1.031 s | **1.035 s** | 1.361 s |
| **JIT 3**（R 默认，V15.9 及以前） | 1.291 s | **8.032 s** | 0.963 s |
| JIT 3 复现一遍 | 1.295 s | **8.208 s** | 0.979 s |

⚠️⚠️ **卡的是第 2 页，不是第 1 页** —— 这一条是关键，也是它藏了这么久的原因：
JIT 编一个闭包是在它**第二次被调用之前**，而 `mod_*_server` 每家**每个会话
只被调一次**。所以：

- 第 1 页：所有模块 server 都是**第一次**调用 → 全解释执行 → 1.29 s，**正常**；
- 第 2 页：它们全是第二次 → 当场把 16 个模块 server 一起编掉 → **8.0 s**；
- 第 3 页：早就编好了 → 0.96 s，又正常了。

也就是说，**每个 worker 世代里恰好有一个倒霉的人**要等这 8 秒 —— 而 worker
空闲 5 秒就被杀（`app_idle_timeout`），世代换得很勤。这就是"有时候会卡"：
它不是慢，是**间歇性的**，而且第一下永远试不出来。

早先还有一组（拿 43 条 / 203 KB 的真实会话、在打了等价开关的实例上量的）：
`session 建立 → 第一次 flush` **9.110 s → 1.498 s**，打开重会话
`history 43` 0.924 s → 0.459 s，profile 里编译器自己的帧 1021 拍 → **3 拍**，
profile 总忙时 27.5 s → 19.7 s；真实会话冷路径重画 0.927 s → 0.361 s。
两组数一致（8.0 ≈ 9.1），互相印证。

热路径的代价**量不出来**（30 KB 正文重画 17.49 vs 17.76 ms，在噪声里）——
真正吃 CPU 的那几处（正则、commonmark、digest、SQLite）都在 C 层，JIT 本来也
编不到它们。所以这一刀是净赚。

⚠️ 影响范围只有**本进程里 source 进来的闭包**：包里的函数是安装时就编好的，
callr 起出去的干活子进程是另一个进程，都切不到。

**怎么复核**（`DSAPP_JIT` 这个口子就是留给这件事的）：

```bash
# 它俩必须在**各自全新的进程**里跑 —— enableJIT(0) 不会把已经编好的闭包
# 退回解释，同一个进程里先 3 后 0 量出来的结论是假的（第一版 A/B 就这么错过）。
DSAPP_JIT=3 Rscript <探针>     # R 的默认行为
DSAPP_JIT=0 Rscript <探针>     # 现在线上跑的这个
```

另外三处是**同一类**的东西（同一样东西在一次重画里被重复算），一起改的：

| # | 位置 | 原来 | 现在 |
|---|---|---|---|
| 1 | `dsapp_config()` | 7.6 ms/次 × 全仓 245 处；其中 6.9 ms 是 `dsapp_cores()` 那句 fork | 按**环境变量全量指纹**缓存，≈0.3 ms |
| 2 | 用户气泡 | 45 条 / 203 KB 的会话重画一遍，user 那 15 条占 0.329 s（71%） | 按 (正文, 会话 sid) 缓存 |
| 3 | 代码卡片 | 流式时每 200 ms 全量重画，卡片本身重拼 HTML | 按 (段, 消息, 执行状态) 缓存 |

⚠️ 第 1 条的指纹**必须是全量 `Sys.getenv()`**，不能手挑几个 `DSAPP_*`：
运行期确实会改环境变量（`R/jobs.R:53`、`R/detach.R:463/894` 切数据根），
手挑的清单会随着以后新增一个读取项**静默过期**，症状是往错误的数据目录里
写东西、还不报错。selftest 里「运行期换数据根，`dsapp_config()$data_root`
必须跟着换」那条钉的就是这里。

⚠️ 缓存的坑**不是变慢，是定格**：key 里少一个字段 → 命中旧结果、界面不动、
**不报错**。所以验收里每一条都要**反向**再验一次（换掉那个字段，结果必须真
跟着变）—— 只验"第二次和第一次一样"是没劲的，不缓存也满足。`tests/v1510_perf.R`
的 B/C 两组和 selftest 的 V15.10 段都是这个形状。

## 五条踩过的坑（改这些脚本之前先看）

> ⚠️⚠️ **种完库必须整页 `reload()`，发消息前还要验一次地址**（2026-10-02，
> `probe_heal.py` 就是这么真打出去一条请求的）。`state$base_url` 是模型页的
> 加载器在**会话开始那一刻**读一次就记牢的（`R/mod_model.R` 里 `loaded_for()`
> 备忘），而探针永远是**先建号、后种库** —— 不重载的话这一页手上还是空地址，
> 发消息时 `state$base_url` 是 `""` → 落到**厂商的默认地址**上。这次的代价是
> 一条打到 `api.deepseek.com` 的 401。
> 现在探针在发消息**之前**先读 `#model-base_url`，不含假 LLM 的
> `127.0.0.1:<port>` 就 `sys.exit` —— 事后断言拦不住已经出网的那一条。
> 另外：**假 LLM 不校验 `Authorization`**，所以"Key 是垃圾"这件事在任何探针里
> 都看不见，只有打到真厂商才会冒出 401（顺带把下面那个种子 bug 一起炸了出来）。

> ⚠️ **`_SEED_R` 里的循环变量不能叫 `k`**（`_common.py` 及 5 份同源副本，
> V15.9 一起改的）。种子的 `k <- a[5]` 是 API Key，后面那段"把 `files <- c(...)`
> 逐行拼起来"的循环原来写的是 `for (k in i:length(al))` —— **把 Key 覆盖成了
> 行号**，而 `app.R` 里那个块正好收在第 245 行，于是库里存的 Key 就是字符串
> `"245"`。现在循环变量叫 `li`，写库前还有一道 `stop()` 守卫。
> ⚠️ 六个副本要一起改：`ui_v153`~`ui_v157` 各一份 + `ui_v158` 一份。

> ⚠️ **本地实例里"断线"是永久的**，别在本地量"抖一下自己接上"。
> 本地是 `shiny::runApp` 直接起的，**没有 shiny-server-client**（那是 Shiny
> Server 注入的），socket 一断就再也没有东西会把它接回来。
> `probe_heal.py` 的 E 段原来就是"CDP 断网 8 秒再放开"，本地复现不了、
> 量出来的全是假象，已换成 `kill -STOP`（那一幕本地能真复现，而且更要命）。
> 线上那条"短抖动交给传输层"的路，只有代码里那个大小关系能保证
> （20 秒宽限期 > shiny-server-client 的 `reconnectTimeout` 15 秒）。

> ⚠️ **图标不能当判据**。体检表那三个状态图标是 Font Awesome 的 `<svg>`，
> `innerText` 里一个字符都没有 —— `"✓" in row` 永远 False，于是「全过」和
> 「全红」看起来一模一样。真正的判据是**那行有没有 `→ 怎么办`**（只有不通过
> 的行才画 fix），加上图标的 CSS 类。云工具探针里 `pf_rows()` 就是干这个的。

> ⚠️ **别让断言扫到别人的目录**。实例是复用的，`workspaces/` 底下还留着
> 前几轮探针建的账号的目录 —— 「别的对话里有没有这次运行的痕迹」这种断言
> 必须先在库里把**这个账号的** `sessions.id` 查出来，只查那几个。

## 已知的环境抖动（不是功能坏了）

> ⚠️ **第一跑常常「注册没进主界面（页面文字 0 字）」**，第二跑就好 ——
> 冷启动 flush 慢，不是注册坏了（`_common.py` 里那段注释有实测：正常 4.7 秒，
> 被挤的时候能拖过 90 秒）。上限已经放宽到 180 秒
> （`DSAPP_TEST_BOOT_SEC`），**慢**和**坏**要分得开。

> ⚠️ **探针被强行打断之后，同一个实例上连着三次注册都停在空白页**（2026-10-02
> 实测：`probe_crash` 第一版在第二幕超时崩掉、浏览器没走 `browser.close()`，
> 之后三次跑都在同一个地方报「注册没进主界面（页面文字 0 字）」；别的脚本
> 在同一个实例上照样能注册进去，**重起实例之后连续两次 24/0**）。
> 机制没查清 —— 记在这里是因为那句报错会把注意力全引到「注册」上，
> 而它其实和注册没关系。**跑炸过一次就重起实例**（`make_instance.sh`）。

> ⚠️⚠️ 起实例**别绕开 `make_instance.sh`**：仓库根那份 `.Renviron` 指的是**线上
> 数据目录**，拷过去实例会连着生产库启动，起来、监听、界面全都正常。
>
> ⚠️ **只有 `www/` 是刷新即变**；`R/*.R` 只在**进程启动时** source 一次。
> 改完 R 必须重起实例。**开着的页面会把老 worker 钉住**。
>
> ⚠️ 两次运行别写同一个日志文件（截断 + 各自的 fd 偏移 → 交错成垃圾）。

## 线上核对：`verify_v1510_live.py`（2026-10-03 新增）

对着**线上** 34038 量「导航开始 → 服务端第一次 flush 走完」的脚本，**只读**：
连开 3 个全新会话，只加载登录页 —— 不注册、不登录、不发消息、不写库
（线上不许跑会建账号的探针，见 `_common.guard()`）。

```bash
/home/biomamba/miniconda3/bin/python tests/ui_v158/verify_v1510_live.py        # 线上
DSAPP_PROBE_URL=http://127.0.0.1:8961/ ... verify_v1510_live.py               # 本地实例（对照）
```

⚠️⚠️ **判据是 `shiny:idle`，不是 `shiny:sessioninitialized`**。2026-10-03 实测：
JIT 3 下第 2 个会话服务端卡 **7.26 s**，而 `sessioninitialized` **0.15 s 就响** ——
它早于 `server()` 把那 16 个模块 server 注册完。拿它当判据，**卡 7 秒和没卡量出来
是同一个数**（第一版探针就是这样：控制组和线上双双"全绿"）。
这个错是靠"**已知会红的样本必须先红一次**"抓出来的 —— 拿 `DSAPP_JIT=3` 的实例
跑，判据不红就说明判据没劲，而不是代码好。

量到的样子：

| 三页的 idle（s） | 第 1 页 | 第 2 页 | 第 3 页 |
|---|---|---|---|
| 线上（V15.10，JIT 0） | 1.179 | 1.160 | 1.176 |
| 本地实例 `DSAPP_JIT=3`（对照） | 1.452 | **8.276** | 1.117 |

⚠️ 对照必须**各起一个全新进程**：`enableJIT(0)` 不会把已编好的闭包退回解释，
同一个进程里先 3 后 0 量出来的结论是假的。
服务端那一侧的对应量法：在**实例副本**的 `app.R` 里，`mod_chat_server(...)` 之前
和 `mod_cloudtool_server(...)` 之后各插一行计时（JIT 3 下量到 `0.62 / 7.28 / 0.57 s`）。

---

## V15.12：那个「页面崩溃」= 每 120 秒一次的整页重载圈（2026-10-03）

用户原话：「Biomamba_ceshi 现在正常了，但是 wchcpu2019@163.com 这个账号的页面
还是崩溃的，**请保证所有账号都不会崩溃**」。

### 它到底是什么

不是白屏、不是报错 —— 是**每 ~120 秒整页重载一次、永远停不下来**。
`data/logs/auth.log` 里那个号 15:49→16:51 一直是一对
「页面加载：cookie 非空 / on_login uid=1 reload=否」。人不会那么准点按 F5。

链条（每一环都有取证，结论存档在 `R/config.R` 的「V15.12：慢链路」那一段）：

1. 那个号是**唯一**的 platform 管理员，比普通号多看得见「后台管理」那一页，
   而那 6 页是**随首屏一起**发下去的 ≈60 KB（admin 31.7K + users 11.6K +
   runs 6.3K + overview 3.9K + prompt 3.4K + res 2.7K）→ 首屏 **152.5 KB**，
   普通号 112 KB；
2. 那条链路实测**中位 3.65 KB/s**（`/proc/net/tcp` 上 Send-Q 的排水速率，
   60 秒采样；峰值 37.6 KB/s）；
3. SockJS 的 websocket 通道每 **25 秒**发一个协议级 PING，**10 秒**内收不到
   pong 就 `session.close(3000, 'No response from heartbeat')`
   （`sockjs/lib/trans-websocket.js:144-159`，写死的，配置改不了）；
4. PING 和业务数据**走同一条 TCP 流** → 它排在积压后面 → 25 秒排不掉 152 KB
   → 必超时（断的那一刻队列里还压着 51 800 ~ 67 200 字节，紧接着源端口就换了）；
5. 而客户端对**干净关闭**是**故意不重连**的
   （`shiny-server-client/lib/decorators/reconnect.js`：
   `if (!this._stayClosed && (!e.wasClean || (e.code >= 4600 && e.code < 4700)))`
   —— 3000 既不是 `wasClean=false`、也不在 46xx，直接进 CLOSED）；
6. → 我们自己的自愈（V15.9）整页重载 → 再发一遍 152 KB → 再断。
   **一个自己喂自己的圈。**

### 改了什么

| # | 改哪 | 一句话 |
|---|---|---|
| ① | `app.R` 的 `admin_lazy` | 后台管理那 6 页**第一次切过去才渲染** |
| ② | `R/mod_chat.R` 的 `output$history` | 窗口预算把**思维链**一起数进去（它占那一包 26%~51%） |
| ③ | `www/app.js` 的 `dsappHeal*` | 刹车换成「只被好起来清零」的计数 + 每轮退避 20 秒 + 手动刷新清零 |
| ④ | `/etc/shiny-server/shiny-server.conf` | `sockjs_heartbeat_delay 180;` —— **不在仓库里**，见 `DEPLOYMENT.md` |

⚠️ ①②③ 只是**把那个圈转得慢一点**；④ 才是让它不再发生的那一半：
判死的条件是「一包字节数 > 链路速率 × (心跳周期 + 10)」，180 秒给出 694 KB 的
判死线，而**实测今天最重的一屏是 368 KB**（外壳 ≈115 KB + uid=11 那个正在写的
长对话的窗口 252.5 KB）→ 余量 1.9 倍（120 秒只有 1.29 倍，所以没停在 120）。
**只上代码不改 /etc，等于没修。**

⚠️ 「外壳」这个数在不同次测量里落在 **112~116 KB**（第一次线上取证是 112 KB，
后来那次是 115/116 KB；差在量点，不是代码变了）—— 判死线是 694 KB，
这点差别不影响任何结论，**别为了对齐它去改文档里的另一个数**。
`meas_firstpaint.R` 量的是**窗口**那一块，外壳要自己加上去。

⚠️⚠️ ④ **不是**对任意大的一包都成立：窗口里「最末尾两条永远渲染」是免预算的，
实测单条消息最大渲染出 384 KB（那条 34 万字的回复），理论上最坏的一屏 ≈880 KB。
量它的两个脚本**已经进仓库**（`SQLITE_RO` 只读打开，不写一个字节）：

```bash
cd /data3/biomamba/analysis/DS_App
Rscript tests/ui_v158/meas_worstmsg.R     # 单条消息渲染字节数 → 那个"底"有多高
Rscript tests/ui_v158/meas_firstpaint.R   # 每个账号登录时自动打开的那个会话，整屏多少字节
# 要量实例（而不是线上库）：加 DSAPP_MEAS_DB=/tmp/dsapp_v1512b/data/dsapp.sqlite3
```

⚠️ `meas_firstpaint.R` 必须按**每人最近更新的那个会话**算 —— 应用登录后自动
选中的就是它（`db_sessions_list()` 是 `ORDER BY updated_at DESC` 取第一条）。
拿一个"更早的"会话去量，数看着合理，但没人会看到那一屏。
2026-10-03 的读数：uid=1 → 126.9K（V15.11 口径）/ 45.2K（V15.12 口径）；
最重的是 uid=11 那个正在写的会话，252.5K（两条免预算的大消息撑着）→ 整屏 368 KB。
⚠️ **这个数会随时间变**：同一个号十分钟后再量是 49.6K（它末尾几条恰好都很小，
窗口反而放进来 4 条）。别拿两次读数不一样当"量错了"——要盯的是**当天见过的最大值**
（368 KB），判死线是 694 KB。

真正的解法是给单条消息的渲染封顶（超长折叠、点开再取），那是产品改动，还没做。

### 怎么验

```bash
# 断线四轮 + 手动刷新（真 kill -9 服务端，不是 mock）
bash tests/ui_v7/make_instance.sh 8956 /tmp/dsapp_v1512b
python3 tests/ui_v158/probe_heal_brake.py

# 新旧刹车在**线上真实节奏（120 秒）**下的对照（拿两版的真代码 + 假时钟）
node tests/ui_v158/brake_sim.js

# 纯 R 的那一半：Rscript selftest.R 的 == Test_V15.12 == 那一节

# ★ /etc 那行到底生效没有 —— **别信"放对了"，直接数线上的 ping**
#   第一次 WS 控制帧 ping 落在 ~180 秒 = 生效；~25 秒 = 指令没被读到。
#   要几分钟（180 秒才来第一个 ping），只读、不登录不写库。
python3 tests/ui_v158/probe_heartbeat_live.py
python3 tests/ui_v158/probe_heartbeat_live.py --url http://127.0.0.1:8961/
```


⚠️⚠️ `probe_heal_brake.py` **分不出新旧**：它必须把 4 轮压到几分钟（20 秒一次），
而那个节奏下 V15.11 的滑动窗口同样会踩刹车。别拿它的绿去说"旧版也没事"——
新旧对照只能看 `brake_sim.js`（它的两组输出里，120 秒那组旧版是
「自动重载 8 次、刹车从没踩下去」）。

### 诊断脚本（只观察、不断言）

`diag_wchcpu.py`（用**真库**里那个账号一个会话一个会话地打开，量用户真正撞上的
那一包）和 `diag_keeplive.py`（页面开着不动，它会不会自己重载）。两个都要求
实例里放的是**线上那份库**：

```bash
bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1511r

# ⚠️ 必须走 sqlite3 的 backup API —— 库跑在 WAL 模式，`cp` 只拷主文件 =
#    一个**旧快照**（实测少 27 条、不报错、行数看着完全合理）
sqlite3 /data3/biomamba/analysis/DS_App/data/dsapp.sqlite3 \
        ".backup '/tmp/dsapp_v1511r/data/dsapp.sqlite3'"
# 对一次账：两边一起打印（只打一边看不出"少没少"）
sqlite3 /data3/biomamba/analysis/DS_App/data/dsapp.sqlite3 "select count(*), max(id) from messages;"
sqlite3 /tmp/dsapp_v1511r/data/dsapp.sqlite3            "select count(*), max(id) from messages;"

# 把 uid=1 的密码改成探针知道的那个 —— **只在副本上改**，线上那份一个字节不动
cd /data3/biomamba/analysis/DS_App && Rscript -e '
for (f in list.files("R", pattern="[.]R$", full.names=TRUE)) source(f, encoding="UTF-8")
con <- DBI::dbConnect(RSQLite::SQLite(), "/tmp/dsapp_v1511r/data/dsapp.sqlite3")
salt <- "testv1511probe"; h <- dsapp_pw_hash("dsapp-probe-2019", salt)
sql <- sprintf("UPDATE users SET pass_salt=%s, pass_hash=%s, must_change_pw=0 WHERE id=1",
               DBI::dbQuoteString(con, salt), DBI::dbQuoteString(con, h))
cat("影响行数 =", DBI::dbExecute(con, sql), "\n"); DBI::dbDisconnect(con)'

python3 tests/ui_v158/diag_wchcpu.py     # 登录邮箱 wchcpu2019@163.com / dsapp-probe-2019
```

⚠️ 探针**只读**：不注册、不发消息、不写库。用线上库只是为了"量到他真正撞上的
那一包"，不是拿线上做实验。

## V15.13：流式正文按链路吃得住的速度发（2026-10-03）

### 它是什么

`output$streaming` 是 `renderUI`：写一次 `draft()` 就把**整段已生成正文**重新渲染成
一个 HTML 包发下去，Shiny 没有输出级 diff。泵 5 拍/秒，于是正文越长、每秒灌给浏览器
的字节越多。线上实测**持续 31.7 KB/s**，而那条链路只能送 **3.65 KB/s**（中位，
见上一节）—— 超订 8 倍以上。后果就是用户那两句原话：

* 发送队列永远排不空 → 点什么都排在积压后面 →「**做任何操作都很卡**」；
* 队列一满 SockJS 的 ping 迟到 → `close(3000)` → 整页重载 →「**频繁断联**」。

⚠️ 已有的那条 `DSAPP_STREAM_BUDGET_B` **管不到这里**：`output$streaming` 的收缩循环
退出条件是 `!isTRUE(win$cut) || ...`，正文短于 `DSAPP_STREAM_WIN_MAX` 时 `cut` 恒为
FALSE，**第一轮就 break**。那条预算是给"长到要切窗口"的正文用的。

### 改了什么

`R/render.R` 新增 `dsapp_stream_due(n_chars, pub_at, now)`：估这一拍要发多少字节，
再算"最早什么时候能发下一拍"。调用点（`R/mod_chat.R` 泵里）从无条件 `draft(st$acc)`
改成先并字、再问闸。常数在 `R/config.R`：`DSAPP_STREAM_RATE_B <- 2500` 等。

⚠️ **不发 ≠ 丢字**：调用点在这一步**之前**就把新文本并进 `st$acc` 了，这里只决定
"要不要把画面刷新一遍"。一轮结束走的是 `output$history`（读库重渲染），和这一格无关。

### 怎么验（本机 A/B，同一个场景、同一条 6179 字回复）

| | 浏览器收到的 WS 字节 | 其中大帧(>1KB) | 帧数 |
|---|---|---|---|
| 改之前（V15.12） | 198,276 B（193.6 KB） | 28 个 / **140.2 KB** | 2626 |
| 改之后（V15.13） | 150,677 B（147.1 KB） | 28 个 / **97.3 KB** | 2576 |

大帧字节 **−30.6%**，总量 −24.1%。闸的指纹很明显：改之前那些 5073 / 6729 / 7112 B 的
帧，改之后变成一串整齐的 **1241 B**。

⚠️⚠️ **这个本机数字把效果说小了 5 倍左右，别拿它当结论**：假 LLM 是一坨一坨吐字的
（~270 字/秒、**约 1 秒一坨**），而泵是 5 拍/秒 → 每 5 拍里只有 1 拍手里有新字，
`draft()` 也只写 1 次。真模型下**每个 tick 都有新字**，被闸挡掉的才是线上那个 31.7 KB/s。
（想在本机复现生产形态：把片间隔压到 0.1s 左右。）

日志：`/tmp/dsapp_bytes_before2_1791022140.log`、`/tmp/dsapp_bytes_after2_1791022467.log`。

### 线上核对（2026-10-03 20:42，`ss -tni`）

```
[::ffff:222.190.61.36]:10151  retrans 122609/1025889 = 11.95%  cwnd:4  rtt:78.3ms  Send-Q 34
[::ffff:222.190.61.36]:11252  retrans 696924/5212260 = 13.37%  cwnd:3  rtt:71.8ms  Send-Q 0
```

**Send-Q 是 0** —— 这是这条修复的靶心：以前它是长期满的（`busy:518536ms`、
cwnd 被压到 3）。同时这条链路**每一跳都在丢 12~13% 的包**（正常 <1%），
`dsack_dups:95`、`reord_seen:65`。所以：

* 超订（我们代码的锅）**已经消掉了** —— 队列不再堆积；
* 但**链路本身烂**是另一回事，`cwnd:3` 是丢包压出来的，不是我们压出来的。
  刷新一屏仍要按 RTT(75ms) × 重传 走，这是客户端到服务器之间那段路的问题，
  改 R 代码改不动它。

## V15.14：「点编辑会话名称，弹出来的却是删除界面」（2026-10-03）

### 结论先说：**没能复现，而且这条路径从来就是对的**

查过的东西，一条条列在这里，免得下次再从零查一遍：

| 查什么 | 结果 |
|---|---|
| 点铅笔发出哪些 input | 只有 `chat-session_rename`（四条路径各点一遍，含 active 行、非 active 行、取消删除框之后再点） |
| 全应用谁能弹删除框 | 只有侧栏顶栏那个垃圾桶 → `observeEvent(input$del_chat)` |
| 38 个归档版本的铅笔 | `onclick` 全是 `return dsappRenameSession(this, event);` |
| `dsappRenameSession` 本身 | md5 `2c8fcc58`，从 V13.1 到现役**一字不差** |
| 线上真的发出去的 `app.js`/`app.css` | 和仓库**逐字节一样**（`curl` 下来对 md5） |
| 铅笔正中心谁接住了这一击 | `I.fas < A.dsapp-sess-edit < …`，就是铅笔自己 |
| 铅笔和垃圾桶的几何关系 | 同一列，y 差 **154~161 px**；侧栏**整体一起滚**，滚到哪都不撞 |
| 弹窗开着时侧栏能不能点穿 | 不能。Bootstrap 遮罩挡住整页，Playwright 实测点不到 |
| 全应用 35 个 `showModal` | 每个删除框都有自己明确的标题，没有"像编辑其实是删除"的 |
| 主账号的页面会话 | `login_sessions.created_at = 2026-09-27 02:57:08` —— 页面开了**六天** |

### 但那个弹窗有一个真缺陷 —— 它不说要删哪一条

原话是 `sprintf("确定删除这个对话吗？其中 %d 条消息%s…")`，**从头到尾没有点名**，
标题「确认删除」还和技能/环境/任务/文件四处**共用**。于是「我点错了东西」和
「它弹错了东西」在用户那边**完全没法区分** —— 他看到的只是一个莫名其妙的删除框。
这才是他报的那句话。

### 改了什么

1. 删除框标题 → `tagList(icon("trash"), " 删除对话")`，正文 → `确定删除「标题」吗？`。
   名字取 `sessions.title` **原样**（和侧栏 `db_sessions_list` 同一列同一字段），
   所以两边一字不差；不用 `db_session_label()`（它会再包一层「对话「…」」）。
2. 侧栏那个删除按钮补上文字「删除」。它原来是 `label = NULL` —— 一个 30×31 的
   红色裸图标，紧挨着「新建对话」，而下面二十来行每行右边都挂着一个同样裸着的
   铅笔。两个裸图标，一个"改名字"、一个"删掉整个对话连同工作区"。
3. 铅笔命中区 16×17 → 28×28（**负 margin 撑开，行高不动**），常驻透明度 .4 → .55。

### 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1513r
sqlite3 /data3/biomamba/analysis/DS_App/data/dsapp.sqlite3 \
        ".backup '/tmp/dsapp_v1513r/data/dsapp.sqlite3'"
# 改副本里 uid=1 的密码（命令同上，换路径）
python3 tests/ui_v158/probe_delmodal.py      # 16 项
Rscript selftest.R                            # == Test_V15.14 == 那一节，12 项
```

⚠️ 这个探针**只点「取消」**，任何一步都不确认删除；最后一条断言就是"样本那一行
还在"，用来兜住"探针自己把数据删了"。

### 两条踩过的坑

**① 量几何之前先滚进视口。** ③ 那次被挡住的点击会触发 Playwright 的
scroll-into-view，把第一行滚出视口；而 `bounding_box()` 对离屏元素**照样返回
正数**（坐标可以是负的），`elementFromPoint()` 却回 `null`。于是"命中区"读出来
是好好的 28×28，"中心打到谁"却是 `null` —— 红的那条指向完全无关的地方。

**② 变异测试的变异必须"还能渲染"。** 第一版变异把正文的 `%s` 从格式串里删掉
但没删对应的参数，`sprintf` 直接抛

```
Error in sprintf: invalid format '%d'; use format %s for character objects
  81: observe [R/mod_chat.R#5502]  <observer:observeEvent(input$del_chat)>
```

observer 整个中断 → 连弹窗都没弹 → 探针在"点垃圾桶弹出了弹窗"上红了。**它证明
的是"observer 会中断"，不是"探针抓得住错标题"**。改成"格式串合法、只是不说名字"
之后才真正打在 ★★★ 那两条上。判据：变异跑完 `grep -c 'Error in' 实例日志` 必须是 0。
