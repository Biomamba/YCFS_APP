# tests/ui_v165 —— 浏览器验收（Test_V16.5）

V16.5 是用户 2026-10-05 提的六条（前四条是同一段消息里的编号列表，第 5 条是
紧接着的下一条，第 6 条是再下一条）：

| 项 | 内容（用户原话） | 谁验 |
|---|---|---|
| item 1 | 轮数似乎应该是在自动执行界面，自动执行打开应该就不设置轮数，不打开则弹出轮数设置 | `selftest.R` §item 1（源码）+ 本目录 `probe_iter.py`（**22 ✓**） |
| item 2 | 对话框下面的设置组件高度请统一 | `selftest.R`（V16.2 那节里**换了真相源**的一条 + 反向一条）+ `probe_heights.py`（**10 ✓**） |
| item 3 | 系统提示词需要能新增分类 | `selftest.R` §item 3（源码 + 库 + 版本号）+ `probe_prompt.py`（**42 ✓**） |
| item 4 | 按照科研绘图Agent通用提示词_清晰美观规范.md 新增系统提示词 | `selftest.R` §item 4（正文与那份 .md 逐字比） |
| item 5 | 云工具暂时只对平台管理者开放，普通用户不显示 | `selftest.R` §item 5（源码 + **行为**）+ `probe_nav.py`（**18 ✓**） |
| item 6 | 把国际模型的选项也都接入 | **无改动** —— 经核实 17 家国际厂商本来就在厂商下拉框里；用户 2026-10-05 回话「国际模型已经有了就不用重复布置了」 |

## 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8974 /tmp/dsapp_v165a
python3 tests/ui_v165/probe_iter.py         # 22 条（item 1，含真跑一轮）
python3 tests/ui_v165/probe_prompt.py       # 42 条（item 3 / 4）
python3 tests/ui_v165/probe_heights.py      # 10 条（item 2，量高度）
python3 tests/ui_v165/probe_nav.py          # 18 条（item 5，三类账号）
python3 tests/ui_v165/probe_heights.py --assert   # 高度那 10 条走断言模式（推荐）
```

退出码 0 = 全绿。数据目录 `/tmp/dsapp_v165a/data`、截图 `/tmp/dsapp_ui_v165`。
换端口/目录用 `DSAPP_TEST_URL` / `DSAPP_TEST_APP` / `DSAPP_TEST_OUT`。

> ⚠️ 起实例**一律走 `make_instance.sh`**，别手搓 rsync。仓库根目录的 `.Renviron`
> 会把一个 /tmp 实例**接到生产库**上，全程不报错、界面无异常（见
> `tests/ui_v7/make_instance.sh` 顶上那段）。
>
> ⚠️ `make_instance.sh` 只同步 `R/` 和 `www/` —— **R 代码只在 worker 换代时
> 生效**。改完 `R/*.R` 之后必须重跑一次 `make_instance.sh`（它会先 `kill` 掉
> 旧实例），否则量到的还是上一份代码，而症状看起来像「改了没反应」。
>
> `_common.py` 是从 `tests/ui_v163/` 抄的副本（不是 import）—— 本仓老规矩：
> 这些脚本要能在「把仓库拷到 /tmp 单独跑」的场景里工作。

## item 1：滑块搬回「自动执行」那一格，而且**跟着「开启」走**

`probe_iter.py` 分四段量：位置（在 `.dsapp-ctrl-agent` 那一格里）、联动
（勾上 → 滑块**不在 DOM 里**、小字变「不限轮数」）、记忆（取消勾 → 值还是刚才
拖的那个数）、真跑（状态条上那个分母是循环自己报的 `a$status()$max_iter`）。

第 ⑤ 段是真跑一轮（假 LLM + 一段能跑的代码）—— 那是"Inf 真的传到了循环里"的
唯一证据：前面几条量的都是**界面读同一个字段**，界面和 agent 分家过好几次。

## item 5：三类账号缺一不可，**项目管理员**那一档是要害

`probe_nav.py` 拿同一个账号依次改成 普通 → 项目管理员 → 平台管理员，
每次都 `reload`（`dsapp_main_ui` 是**会话开始那一刻**按当时的 user 行渲染的，
不 reload 量到的是"改之前"那棵树）：

| 账号 | 左栏云工具 | 左栏后台管理 | DOM 里有那一页 |
|---|---|---|---|
| 普通用户 | ✗ | ✗ | ✗（`[id^=cloudtool-]` 一个都没有） |
| 项目管理员 | ✗ | ✓ | ✗ |
| 平台管理员 | ✓ | ✓ | ✓ 且真的画出来 |

★ 为什么非得有**项目管理员**那一档：`dsapp_user_is_admin()` 对他也是 TRUE
（他进得去「后台管理」）。拿它当云工具的闸，症状恰好是"项目管理员也看得见云工具"
—— 而**普通用户那一档照样全绿**（他本来就什么都看不到）。用户说的是"只对平台
管理者"，多放一种人就与这句话不符。

★ 每一档都配了**反向对照**（"这个选择器真的数得到东西吗"）：探针选择器写错时
`count() == 0` 会**静默通过**，本仓栽过（V16.2 有一条探针从没跑过却长得像通过）。
所以量"普通用户没有那一页"的同时必须量到 `[data-value=chat]` ≥ 1；量"平台管理员有"
的那一档必须真的数到 ≥ 1 —— 选择器坏了两档一起红。

### 两个量法上的坑（这一节踩到的）

* ★★ **判"那一页在不在 DOM 里"只能数 `[data-value=…]`。** bslib 的
  `navset_hidden` 把**所有**页都留在 DOM 里（只是加不加 `active`），所以
  `is_visible()` 对"没有这一页"和"有但没激活"都给 False —— 拿它当判据，
  普通用户那一档会因为完全无关的理由变绿。
* ★★ **`#cloudtool-preflight_box` 那几个容器的矩形恒为 0×0**，不是因为它藏起来了，
  而是因为它们的 `display` 是 **`contents`**（自己不产生盒子，只有里面的按钮/文字有）。
  第一版就是拿它的 `bounding_box()` 当"页面画出来了"的判据，红了一条 ——
  而它红的意思是"这一页是空白页"，差得很远。判据改成：那一片 `.tab-pane` 是
  `active` 且有 80 字以上的内容 + 里面那颗「重新体检」按钮有真矩形。
  （本仓 `hidden-element-has-zero-rect` 那条老账的**反面**：那次是"看不见的也有矩形"，
  这次是"看得见的矩形是 0"。）

## item 3 / 4：分类能加，正文跟那份 .md 逐字一致

`probe_prompt.py` 走完整条路：新建一节 → 改名 → 改正文 → 看它进全文 →
删掉 → **回库确认**（两张表各回到 0 行）。每一步写操作后面都回库核一次
（"没写进去"和"没画出来"要分得开 —— 本仓 `cooldown-looks-like-broken-ui`）。

item 4 的正文来源是仓库里那份
`skills_builtin/科研绘图Agent通用提示词_清晰美观规范.md`，`selftest.R` 那节是
**逐字比**（不是比长度）。

## ⚠️ 冻结记录里这一版会红的一条

`tests/ui_v163/probe_boxes.py`（V16.3 的冻结记录）在 V16.5 实例上 **22 条里红 1 条**，
在 V16.3 参照实例（8971）上是 22/0：

```
✗ ③ （对照）同一个框里，没勾的那几项此刻**有**控件
```

这一条**是 item 1 要的**：`probe_boxes.py` 的 ② 段会把 `#chat-agent_mode`
勾上再往下走，而 item 1 之后「开启」勾着就**不再画轮数滑块**了 —— 那条断言编码的
是 V16.5 之前的规矩。冻结记录**不回改**；反过来，`probe_iter.py` 的 ④ 段
（滑块回来 + 记得住刚才那个数）在同一个实例上是绿的，两件事互相印证。

跑法（对照实例）：

```bash
bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a     # V16.3 那一份
DSAPP_TEST_URL=http://127.0.0.1:8974/ DSAPP_TEST_APP=/tmp/dsapp_v165a/app \
  python3 tests/ui_v163/probe_boxes.py                       # → 1 红
DSAPP_TEST_URL=http://127.0.0.1:8971/ DSAPP_TEST_APP=/tmp/dsapp_v163a/app \
  python3 tests/ui_v163/probe_boxes.py                       # → 0 红
```

## item 5 在自检里为什么必须**真跑**函数

判据原来内联在 `app.R` 的 UI 里（`dsapp_main_ui()` 函数体里的一段匿名
`Filter`）。`selftest.R` **从不 eval 那个函数**，于是"平台管理员才看得见"这件事
一次都没被跑过 —— 而它写反了的症状只有拿两类账号各登一次才发现。

V16.5 把它搬进 `R/uiprefs.R` 的 `dsapp_nav_visible(items, is_admin, admin_scope)`，
自检那一节就能拿**夹具**直接调它（普通 / 项目管理员 / 平台管理员 / NA / 认不出来的
role 各一条），并且钉住 app.R 里那颗 `if (platform_admin)` 用的是
`dsapp_user_is_platform_admin()` 而**不是** `is_admin`。

⚠️ 扫 `app.R` 那一侧**要先剥注释**：注释里逐字写着 `if (platform_admin)` /
`nav_panel("云工具"…)`，不剥的话扫到的全是注释 —— 而"扫到注释"和"扫到代码"
在这些判据上长得一模一样（本仓 `scan-source-strip-comments`）。

## 这一版自检里那个**中断**（写下来免得下一个探针再踩）

item 1 的收尾闸门读的是 `agent_mode_now()` —— 而那个函数**定义在
`mod_chat_server` 里面**。V15.7 那个 pump 沙箱的 parent 是 `globalenv`，够不着它：

```
Error in agent_mode_now() : could not find function "agent_mode_now"
Calls: <Anonymous> -> isTRUE -> isolate / Execution halted
```

**源码里多读一个模块内部的函数，沙箱就得补一个替身；而"忘了补"的症状是整份自检
在那里**中断**（不是红一条）** —— 日志末尾只有一句 Error，前面三千多条全绿。
修法是给沙箱补 `agent_mode_now` / `agent_of` 两个替身，并新增 §⑥：勾着「开启」时
收尾那一拍**就地**为**被推的那个对话**建出循环（`st` 故意指向别人），
没勾时一次都不建。

## 生产库

四条探针跑的都是 `/tmp/dsapp_v165a` 那个实例，它自己的 `app/.Renviron` 里写着
`DSAPP_DATA_ROOT=/tmp/dsapp_v165a/data`（`make_instance.sh` 生成的，不是继承来的
环境变量）。每个探针在注册之后都会 `seed_or_die()`：刚注册的账号不在这个实例的
库里就**硬退出** —— 那说明它连的是生产库。

跑完用**只读**连接（`file:…?mode=ro`）核对生产库，`count(*)` 和 `max(id)` 一起看
（两者不是一个数：`AUTOINCREMENT` + 级联删会留空洞，混着比会看出一个不存在的
"少了几条"）。数字见 `history_Version/Test_V16.5_*/ARCHIVE.md`。

⚠️ 这里**不断言**"生产库和昨天一模一样"：线上 `/YCFS_APP/` 是给人用的，随时可能
有人在上面跑任务。能说清楚的只有"这一轮测试没往里写"。
