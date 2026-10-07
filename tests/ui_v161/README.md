# tests/ui_v161 —— 浏览器验收（Test_V16.1）

V16.1 是六件事（用户 2026-10-03 21:51 的原话见 `selftest.R` 里
「Test_V16.1：六件事」那一节的开头，逐字抄的，别改写）。

其中四件在**浏览器里**才算数，所以这个目录里是三个探针：

| 脚本 | 管什么 | 端口 / 目录（默认） |
|---|---|---|
| `probe_histmore.py` | item 2：「显示更早的消息」点得动、而且**不许越点越大** | 8963 / `/tmp/dsapp_v161i` |
| `probe_v161.py` | item 1：回答框的文案和位置；item 5：不设上限时那句提醒；item 6：任务在跑时的痕迹 | 同上 |
| `probe_cloudtiles.py` | item 4：云工具的图标式二级菜单 + 两颗「交给 agent」 | 8964 / `/tmp/dsapp_v161j` |
| `probe_del.py` | item 3：删得掉 / 删不掉时说的**是不是真话** | 8965 / `/tmp/dsapp_v161k` |

## 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8963 /tmp/dsapp_v161i
bash tests/ui_v7/make_instance.sh 8964 /tmp/dsapp_v161j
bash tests/ui_v7/make_instance.sh 8965 /tmp/dsapp_v161k

python3 tests/ui_v161/probe_histmore.py      # 退出码 0 = 全绿
python3 tests/ui_v161/probe_v161.py
DSAPP_TEST_URL=http://127.0.0.1:8964/ DSAPP_TEST_APP=/tmp/dsapp_v161j/app \
  python3 tests/ui_v161/probe_cloudtiles.py
DSAPP_TEST_URL=http://127.0.0.1:8965/ DSAPP_TEST_APP=/tmp/dsapp_v161k/app \
  DSAPP_TEST_OUT=/tmp/dsapp_ui_v161k python3 tests/ui_v161/probe_del.py
```

数据目录 `/tmp/dsapp_v161i/data`、截图 `/tmp/dsapp_ui_v161`。
换目录/端口用 `DSAPP_TEST_URL` / `DSAPP_TEST_APP` / `DSAPP_TEST_OUT`。

> ⚠️ 起实例**一律走 `make_instance.sh`**，别手搓 rsync。仓库根目录的
> `.Renviron` 会把一个 /tmp 实例**接到生产库**上，全程不报错、界面无异常
> （见 `tests/ui_v7/make_instance.sh` 顶上那段）。
>
> ⚠️ `probe_histmore.py` 会开 **CDP 限速**（50 KB/s、RTT 80 ms）来模拟用户那条
> 慢链路。限速只作用于它自己的那个 context，不影响别的探针，但它自己很慢
> （一轮 8 次点击 ≈ 7 分钟）。

## ② 为什么非要重量一遍"这一包多大"

「显示更早的消息点不出来」有两层，**只修第一层会留下一颗定时炸弹**：

* 第一层是明面上的 —— 点了没反应（至少还有 `nrow` 之类的东西能看出来）。
* 第二层是 `hist_extra` 那个**只增不减**的计数器：每点一次，服务端就把
  「窗口 + 已翻出来的全部」整包重发一遍。它**不会报错**，界面上也一切正常，
  只是每点一次的包越来越大，直到某一包越过那条死线。

改之前实测（50 KB/s 的慢链路、74 条 / 正文 444 KB + 思维链 518 KB）：

```
打开这一包      257 KB
点 1..8 次      192 → 298 → 377 → 482 → 588 → 693 → 773 → 878 KB（最大帧 867.6 KB）
```

改之后同一份数据：

```
打开这一包      268 KB
点 1..8 次      140 113 138 113 139 113 140 114 KB（最大帧 140 KB，末次/首次 0.82）
```

★ 所以这个探针有**两条**判据，缺一条它就会在"全绿"里漏掉第二层：
`DSAPP_HM_FRAME_MAX_KB`（单帧上限，默认 400）和"末次/首次 > 2 就算涨"。
基线那一跑报的是**全绿**而实测 867.6 KB —— 因为 CDP 限速**不丢包**，
而用户那条链路丢 12%（见 memory：`slow-link-is-the-network`）。

## ④ 为什么切面板走前端、不重画

「结合蛋白设计」那块面板里有十几个参数控件，值可能是用户填了五分钟的。
用 `renderUI` 重画整块来切面板的话，那些控件连同值会被一起铲掉。
所以 `www/app.js` 里是一个**纯前端**的委托处理器（切 class，不动 DOM 子树）。

判据因此**不能只比 input 的值** —— 值是浏览器自己记着的，节点被换掉之后
新节点也会显示同样的值（Shiny 会把它知道的旧值填回去），那样量出来的绿是
假的。`probe_cloudtiles.py` 的做法是在节点上盖一个 JS 属性（`__dsappProbe`），
切一圈回来再看它还在不在：**只有同一个 DOM 节点才认得这个属性**。

第 ⑤ 节（有工作区、面板里真有控件时）要求先给那个会话造出工作区目录，
否则 `form_box` 是 `NULL`、面板里一个控件都没有 ——「没得可丢」不等于「没丢」。

## ③ 为什么非要第二个标签页

「删不掉」那句话（「这是别人共享给你的对话，删不了」）原来的触发条件里，
**两种（对话已经没了 / 查库抛错）都被压成了同一句**。要让它真的发生，不能靠
"连点两次删除" —— 第二次点的时候侧栏那一格早就重画了。真身是**另一个标签页**：
页 1 的侧栏里那一行是旧的，而库里的行已经被页 2 删掉了。`sessions()` 只依赖
`sess_ver` / `state$user_id` / `cfg()` 三个，**没有任何轮询**，所以页 1 会一直
挂着那一行 —— 这正是用户遇到的那个状态。

⚠️ 页 2 和页 1 **共用一个 context 的 cookie**，所以它一进来就是主界面。
**别拿 `C.wait_awake()` 去等它**：那个函数等的是 `.dsapp-auth`（注册/登录的壳），
它永远不会出现 → 空转到 150 秒超时，中途还每 60 秒 reload 一次（每次 reload
都是新开一个 Shiny session）。探针里那个 `wait_ready()` 就是为这个写的。

⚠️ B 那一路**不该弹窗**：`del_gate` 判出「已经不在了」时返回 `heal = TRUE`，
`observeEvent(input$del_chat)` 遇到 `!ok` 直接 `return(del_gate_notify(...))`。
所以探针里"弹窗没出来"是**对的** —— 傻等 `#shiny-modal` 会超时，而报的错指向
一个根本不存在的 UI 问题（第一版就是这么栽的）。

## 踩过的坑（写在这里，免得下一个人重新踩）

* **切面板是客户端状态，切页不会重置它。** 探针点完 TCGA 的方块又切去对话页、
  再切回云工具时，亮着的仍然是 TCGA，design 那块躺在 `display:none` 里。
  这时 `#cloudtool-job` **在 DOM 里**（`count()` 是 1）只是不可见，`fill()`
  会一直等到 30 秒超时，报 `element is not visible` —— 看着像"表单没渲染出来"，
  其实是探针自己站错了面板。填之前先 `CLICK_TILE("design")`。
* **`elementFromPoint` / 几何断言之前先确认那个东西看得见。** 隐藏元素的矩形
  是全 0，拿它做减法得到的数看着完全合理。
* **点不动先想弹窗。** `.dsapp-ask-box` 那颗发送键「visible, enabled and
  stable」全满足却点不动，报的是它自己 `intercepts pointer events` ——
  真正的原因是一个**后到的**弹窗（进对话页那一刻检查过一次，那时它还没出来）。
  每处 click 之前 `ensure_no_modal()`。
* **`#cloudtool-job` 的盖戳要盖在它自己身上。** `STAMP` 盖的是面板里**第一个**
  input（`cloudtool-preset`），而第 ⑤ 节读的是 `#cloudtool-job` ——
  于是报「戳=None」却打了 ✓，等于只验了"值还在"。
* **改 `selftest.R` 的时候别让它同时在跑。** `Rscript --file=` 是边跑边解析的，
  中途改文件会让它读到半截内容，症状是 `Error: unexpected end of input` ——
  看着像语法错误，其实是并发编辑。
* ★★ **通知记的是"整页累积"，等它必须按序号切开。** `__dsappNotes` 那个数组
  从进页面起一直攒着，B 节记下的那条「已经不在了」在 C 节还躺在里面 ——
  C 节一"等"就立刻命中**旧的那一条**，于是 C 节的通知判据什么都没验，报的却
  是绿。铁证是日志里 C 节自己那份通知列表**是空的**，而它判过了。
  `wait_note(..., since=nts_before)` 就是干这个的：只看这一节新记进来的。
  （和 memory 里「探针很绿但变异是空转的」是同一类：**判据要有牙**。）
* **探针自己造的 404 会把资源检查永远染红。** `probe_v161.py` 开头原来是
  `pg.goto(C.URL + "app")`，而实例把应用挂在 `/` 上 → `/app` 稳定 404。
  它无害（`enter_app` 马上自己 goto 一次），但那条"有资源没加载出来"的断言
  从此**永远红**——一条自己造的假问题盖住真问题。
  ⚠️ 顺带：`console.error` 里的 "Failed to load resource" **不带 URL**，
  只报"有个东西 404 了"。所以资源一律走 `page.on("response")` 收（它带 URL），
  console 那一侧把它滤掉，免得同一件事报两遍、带 URL 的那遍被顶掉。

## 探针验不到的那一半

自检那一节（`selftest.R`）里同样是六件事，但它扫的是**源码**：它能证明
"写了"，证明不了"用户看得见"。这两边**互不替代**，本仓在这上面已经栽过
两次（V13.17 的 `wall_limit`、V14 的内联 `img` 属性都是"自检全绿而功能没被
验过"）。哪一条属于哪一类，`selftest.R` 那一节里每一条自己的注释都写明了。
