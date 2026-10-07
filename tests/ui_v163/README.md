# tests/ui_v163 —— 浏览器验收（Test_V16.3）

V16.3 是用户 2026-10-04 一口气提的七条。逐字原话在下面那张表里（前六条是同一段
消息里的编号列表，第七条是紧接着的下一条）：

| 项 | 内容 | 谁验 |
|---|---|---|
| item 1 | 补充可支持的国内 / 国际模型厂商 | `selftest.R` 那一节（30 ✓）；地址是**当场实测**出来的，见下 |
| item 2 | 模型服务页加 VPN（代理）设置，订阅密匙同样加密 | `selftest.R` 那节（57 ✓）+ 本目录 `probe_item2.py`（25 ✓） |
| item 3 | 那一行小字是两类功能的提示词，各归各的类 | 本目录 `probe_boxes.py` ②（**自检里一条都没有**，见下） |
| item 4 | 「出错自动修」已经打勾了，上面还有根滑条，冲突 | `selftest.R`（源码）+ `probe_boxes.py` ③（行为） |
| item 5 | 组件太多，用框区分出分类 | `selftest.R`（源码）+ `probe_boxes.py` ①④（**看得见**） |
| item 6 | 消息被折叠时，点导航栏里的消息跳不过去 | `selftest.R`（源码）+ 本目录 `probe_jump.py`（12 ✓） |
| item 7 | 选完厂商就刷新可选模型清单，不用等 Key 有效 | `selftest.R` 那节（21 ✓）+ `probe_item7.py`（15 ✓） |

## 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a
python3 tests/ui_v163/probe_item2.py      # 25 条
python3 tests/ui_v163/probe_item7.py      # 15 条
python3 tests/ui_v163/probe_jump.py       # 12 条
python3 tests/ui_v163/probe_boxes.py      # 22 条
```

退出码 0 = 全绿。数据目录 `/tmp/dsapp_v163a/data`、截图 `/tmp/dsapp_ui_v163`。
换端口/目录用 `DSAPP_TEST_URL` / `DSAPP_TEST_APP` / `DSAPP_TEST_OUT`。

> ⚠️ 起实例**一律走 `make_instance.sh`**，别手搓 rsync。仓库根目录的 `.Renviron`
> 会把一个 /tmp 实例**接到生产库**上，全程不报错、界面无异常（见
> `tests/ui_v7/make_instance.sh` 顶上那段）。
>
> ⚠️ `make_instance.sh` 只同步 `R/` 和 `www/` —— **R 代码只在 worker 换代时
> 生效**。改完 `R/*.R` 之后必须重跑一次 `make_instance.sh`（它会先 `kill` 掉
> 旧实例），否则量到的还是上一份代码，而症状看起来像「改了没反应」。
>
> `_common.py` 是从 `tests/ui_v162/` 抄的副本（不是 import）—— 本仓老规矩：
> 这些脚本要能在「把仓库拷到 /tmp 单独跑」的场景里工作。

## item 1：那 27 家的地址是**当场量出来的**，不是抄报告的

这一条最容易被写成"照着一份调研报告填一遍"，而报告里的地址**会错**：报告给的
潞晨 `key_url`（`https://www.luchentech.com/models-console/api-key`）实测 **404**。

判据只有一条，因为应用拼 URL 的写法就一种：

```
R/models.R 里 dsapp_vendor_base_url() 只 sub 掉尾斜杠，不补也不猜前缀，
所以「base_url 对不对」= POST {base_url}/chat/completions 存不存在。
```

实测脚本（一次性，留在 `/tmp`，没进仓库）：`probe_catalog.py`（`GET /models`
+ `GET {base_url}/zzz_nope9f3a1c` 对照）和 `probe_chatpath.py`（`POST
{base_url}/chat/completions` + 假路径对照）。

**对照探针是必需的**：有些 host 是 WAF / SPA 兜底，任何路径都回 401/403/200，
那样的判据是**空的**。凡是对照也返回同样状态码的（`infini` / `sambanova` /
`groq` / `cerebras` / `together` / `anthropic`），当天那条判据作废，不能当证据。

**故意不收的**（理由写在 `R/models.R` 那 55 行注释里，别重复调研）：
Anthropic（只有 `/v1/messages`，没有 `/v1/chat/completions` → 必 404）、
Cohere（兼容层拒收本应用**总是**发的 `stream_options`）、Azure OpenAI /
Google Vertex / Cloudflare（`base_url` 里带 `{resource}` / `{PROJECT}` 占位符）、
澜舟 / 西湖心辰 / 紫东太初 / 移动 MoMa / 联通元景（平台有，但**没有**自助的
OpenAI 兼容端点 —— 是「待查」，不是「不存在」）。

⚠️ 界面上下拉框用的是**扁平列表**，不是 optgroup。目录里那句「位置就是需求的一部分
…… 不需要也不该有任何额外的排序代码」是有断言钉着的（`v136_choices[1:3]`），
加 optgroup 会同时动到它。

## item 3：**自检一条都没有**，而它看起来像验过了

`selftest.R` 里 grep `基础环境是系统环境` / `自动执行已开启` 是 **0 命中**。
item 4 / item 5 至少在 V16.2 那一节里留了源码断言，item 3 一条都没有 ——
也就是说这一版跑完「3732 ✓ / 0 ✗」的时候，item 3 **没有被验过任何一次**。

这正是本仓栽过四次的形状（V13.17 `wall_limit`、V14 内联丢 `img` 属性、
V16.1 空表只验源码、V16.2 探针选择器写错）。所以 `probe_boxes.py` ② 是补的：

* 正向：「基础环境是系统环境…」在「在哪跑」框里、「自动执行已开启…」在
  「自动执行」框里；
* ★ **反向**（这条才是重点）：两句**都**不许出现在对方的框里。只钉正向的话，
  「拆开」写成「复制一份到两边」照样全绿 —— 而用户看到的还是同一句话说两遍；
* ★ **前置**：「自动执行已开启…」只在自动执行**开着**时才画
  （`output$ctrl_notes` 里那句 `!isTRUE(a$enabled) → return(NULL)`），
  所以探针先把那个开关打开、断言那句真的出现了，再去量它在哪个框里。
  少了这一步，「不在别处」在「它压根没渲染」时也成立 —— 白送。

### item 3 那句话有两种读法，这里选的是哪一种

用户原话：「…这一行话其实是两类功能的提示词，请把他合并到一类里去。」

「合并」字面上是"并到一起"，但**这一行**本身就是两类提示词的混合体，并到一起
等于没动。实现的读法是：**每一句并进它自己那一类**（跟着 item 5 的框走）——
「基础环境是系统环境…」→「在哪跑」那个框；「自动执行已开启…」→「自动执行」那个框。
两个 output 互相独立（改环境那句不再让整行重画，这是拆开白拿的好处）。
若将来用户说的是另一种意思，改的是**位置**，`probe_boxes.py` ② 会立刻红。

## item 4 / 5：源码断言管不了的那一半

`selftest.R` 能查到的：五个勾在同一格、每格包了 `.dsapp-unlim-item`、
`.dsapp-ctrl-box` 这个 class 写在了五个地方。查不到的：

* 勾着的时候那个数字框**到底在不在屏幕上**（`renderUI` 返回 NULL 只是"不画"，
  可它在别的地方露着也是同一个 class）；
* 「就地」是不是真的挨着它自己那个勾；
* 五个框**看不看得出来**是五个框。

`probe_boxes.py` ③ 钉的是「勾着时 `#chat-fix_max_n` 不存在 + 也没露在别处
（矩形非零）」，然后取消勾、量它和**自己那个勾**的中线差（<40px）和左右关系
（用户抱怨的那根"上面那个滑条"在上一行，所以右边这一条不是白写的）。
④ 钉的是 computed style（真落了边框/底色/内边距）+ **五个框两两不重叠** +
每一格都不是 0×0 矩形（防「0×0 的框当然不重叠」）。

## item 6：折起来的消息也要跳得到

`probe_jump.py` 造一段 40 条 × 7000 字的对话，让目录里那条目标**被折叠掉**
（点之前锚点不在 DOM 里 —— 这一条是前置，不然量的是"本来就在"），
然后点目录 → 断言锚点进 DOM、滚进视野、正文画出来、顶部出现「你正在看较早的内容」
横条（sticky 钉住），再点「回到最新」→ 那条又收回去、横条自己消失。

## item 7：自动拉清单的三条闸门

`probe_item7.py` 的重点不是"拉回来了"，是**不该拉的时候一次都不发**：

* 没有 Key 也没有地址的厂商（custom）→ 一个请求都不出去；
* 进页面时厂商本来就有静态清单（deepseek）→ 也不白拉一次；
* ★ 竞态：A 家的应答**后到**时不能顶掉 B 家已经显示的清单
  （把 relay 的 `/models` 拖慢 4 秒，切过去之后立刻切到 custom）。
  这一条**能分辨修没修**：旧代码盖章盖的是"应答落地那一刻的 `input$vendor`"。

## ⚠️ 冻结记录里这一版会红的几条（都实测过，不是猜的）

判据是**拿 V16.2 的归档快照起一个对照实例，同一份脚本跑两遍**：

```bash
bash history_Version/Test_V16.2_20261004/tests/ui_v7/make_instance.sh 8972 /tmp/dsapp_v162ref
DSAPP_TEST_URL=http://127.0.0.1:8972/ DSAPP_TEST_APP=/tmp/dsapp_v162ref/app \
  python3 history_Version/Test_V16.2_20261004/tests/ui_v11/layout.py   # → 6 条红
DSAPP_TEST_URL=http://127.0.0.1:8971/ DSAPP_TEST_APP=/tmp/dsapp_v163a/app \
  python3 tests/ui_v11/layout.py                                       # → 8 条红
```

差的这 2 条就是这一版造成的，**都是 item 5 要的**：

| 红的那条 | 为什么是**故意**的 |
|---|---|
| `item6 ★ 这一排里的抬头是「硬件选择」` | 那一格在 item 5 里拆成了「模型」+「在哪跑」两个框。旧抬头是 V11 的名字，用户这一版要的是**按类别分框** |
| `item4 系统环境那一格在这一排里` | 同一个原因：「系统环境」不再是**一格的抬头**，它是「在哪跑」框里的一个控件（`grab()` 按抬头文字找格子，找不到）。配套的 `item4 系统环境是个下拉框` 仍然**绿** |

另外 6 条（`item6 三个选项`、`item9 sticky`、`item10` ×4）在 **V16.2 快照上就是红的**，
和这一版无关 —— 别把它们记到 V16.3 头上。

`tests/ui_v162/probe_unlim.py` 在本版实例上 **红 1 条**：

```
✗ 滑块拖到最右那一格，旁边那行字还是 '6 轮' —— 那一格是「不设上限」，字得跟着走
```

这是**探针的选择器撞了**，不是应用错了。它的 `label()` 读的是
`.dsapp-ctrl-unlim .dsapp-iter-label` —— **取第一个匹配**。V16.2 时「轮数」那根滑块
在别处，这个选择器只匹配得到时长那一行字；item 4 把轮数也收进了同一个框，
于是它现在匹配到**两个**，DOM 里在前的是轮数那个 → 永远读到「6 轮」。

应用本身是对的，直接量过（`/tmp/check_wall_label.py`）：

```
unlim 框里的 .dsapp-iter-label 文本（全部）: ['6 轮', '2 小时']
拖到最右之后 unlim 框里两个 label           : ['6 轮', '不设上限']
拖到最右之后 .dsapp-wall-slider 里那个 label: ['不设上限']
```

`tests/ui_v162/` 是 V16.2 的冻结记录，**不去回改**。重跑它看到这条红，不是回归。

## 这一版踩到的两个坑（写下来免得下一个探针再踩）

* ★★ **`ensure_no_modal()` 在弹窗还没到的那一瞬间就放行。** 它是"现在看不见
  弹窗 → 返回成功"的写法，而 `showModal` 要走一个服务端来回（100~300 ms）。
  勾上「自动执行」会**再问一次**那个「AI 怎么干活？」弹窗 —— 刚点完开关就调它，
  守卫当场放行，弹窗随后才冒出来压住整页。症状是**十几行之后**的一次
  `.uncheck()` 等满 30 秒超时，报的是「被 `#shiny-modal` 挡住」。
  `probe_boxes.py` 里改成先 `wait_for_timeout(2000)` 再关。
* ★★ **判"弹窗在不在"不能用 `offsetParent`。** Bootstrap 的 `.modal` 是
  `position: fixed`，而固定定位元素的 `offsetParent` **恒为 null** ——
  用它判可见性，一个正盖着整页的弹窗会被判成"不在"。第一版就是这么写的，
  守卫静静地放行，然后在 30 秒后超时。要用 `getBoundingClientRect()`
  （和本仓 `hidden-element-has-zero-rect` 是同一枚硬币的两面）。
* **点「都先别开」会把刚勾上的开关弹回去。** `_common.ensure_no_modal()` 点的
  是 `#chat-agent_pref_manual` → `agent_pref_store(FALSE, FALSE)` → 里面有一句
  `updateCheckboxInput(session, "agent_mode", value = FALSE)`。要保留勾选状态
  得点「就按这个来」（`#chat-agent_pref_save`），见 `close_pref_modal()`。

## 探针验不到 / 自检验不到的那一半

两边**互不替代**（本仓在这上面栽过四次）：

* 自检管：目录里每一家的 `base_url` 字面量、聚合平台没写自家模式、
  `supports_thinking` 只有 deepseek、代理那几个 handler 里没有全局设置、
  落库只有 `dsapp_proxy_save` 一道门、编解码是可逆的……
* 探针管：代理**真的**从假代理身上过去了（HTTP 绝对 URI / SOCKS5 用户名子协商
  都量了）、选中厂商之后下拉里**真的**出现了那一家的模型、折叠的消息**真的**
  跳得过去、五个框**真的**看得出来是五个框。

## 生产库

四条探针跑的都是 `/tmp/dsapp_v163a` 那个实例，它自己的 `app/.Renviron` 里
写着 `DSAPP_DATA_ROOT=/tmp/dsapp_v163a/data`（`make_instance.sh` 生成的，
不是继承来的环境变量 —— 仓库根目录那份 `.Renviron` 指向 `…/DS_App/data`，
手搓 rsync 最容易把实例接到生产库上、全程不报错）。

跑完之后用**只读**连接（`file:…?mode=ro`）核对了生产库：

```
users 8 / sessions 22 / messages 1083 / tasks 382 / agent_runs 1
（count(*) 和 max(id) 一起看 —— 两者不是一个数，`AUTOINCREMENT` + 级联删
 会留空洞，混着比会看出一个不存在的"少了几条"）
```

`messages` / `tasks` 里**最新那几行的 `created_at`（UTC）折成本地时间是
18:31**，早于这一轮探针开跑（19:24 起）—— 也就是说这几条不是探针写进去的。

⚠️ 这里**不断言**"生产库和昨天一模一样"：线上 `/YCFS_APP/` 是给人用的，
随时可能有人在上面跑任务。能说清楚的只有"这一轮测试没往里写"。
