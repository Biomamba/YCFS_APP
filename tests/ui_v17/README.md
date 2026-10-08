# tests/ui_v17 —— 浏览器验收（Test_V17）

V17 是用户报的七条，其中**改到源码的是三条**（另外几条是运维/审计层面的，
报告在归档的 `ARCHIVE.md` 里）。这三条各自都有一条"函数对了但用户那儿不对"
的路，只有浏览器量得到：

| 项 | 用户原话 | 修在哪 | 这一版的探针 |
|---|---|---|---|
| item 1 | 「服务器现在还是经常未响应，这个提示能不能显示的不要这么频繁，即使真的断了，也请间隔一段时间再提示」 | `www/app.js`（静默期闸门） | `probe_quiet.py`（22 条） |
| item 2 | 「文件管理页面的 T2DM–PD…Agen-8251 里面的 data_raw，就是空的，但是它在言出法随页面的文件管理区就是有文件的」 | `R/files.R`（镜像层不回同步） | `tests/v17_mirror.R`（R 侧 22 条）+ `mut_mirror.py` |
| item 3 | 「我打好的汉字，但是点击发送后句尾会有一部分变成拼音，并且少几个字」 | `R/mod_chat.R` + `www/app.js`（发送时客户端现读原文） | `probe_sendtext.py` |
| item 6 | 「注意检查，OA 部分有没有隐私泄露」——审计查出的 H1：文件页的会话下拉能指向**别人的**工作区 | `R/mod_files.R`（补 `db_session_role` 闸） | `probe_files_acl.py` |

## 怎么跑

```bash
bash tests/ui_v7/make_instance.sh 8982 /tmp/dsapp_v17a     # 起隔离实例（V17a）
python3 tests/ui_v17/mkfix_u11.py                          # 把 uid=11 的生产目录**结构**搬进实例
/home/biomamba/miniconda3/bin/python tests/ui_v17/probe_quiet.py        # item 1，22 条
/home/biomamba/miniconda3/bin/python tests/ui_v17/probe_sendtext.py     # item 3
/home/biomamba/miniconda3/bin/python tests/ui_v17/probe_files_acl.py    # item 6
Rscript --no-environ tests/v17_mirror.R .                  # item 2（R 侧，22 条）
Rscript --no-environ selftest.R                            # 静态约定（含 V17 item 1 那一节）
/home/biomamba/miniconda3/bin/python tests/ui_v17/verify_live.py   # ★ 上线之后跑：线上是不是这一版
```

**上线之后**（改完 `R/` 一定要 `touch app.R`，否则 worker 不换代）跑那条
`verify_live.py`：它同时查 R 那半边（页脚版本 == 盘上 `DSAPP_VERSION`）和
`www/` 那半边（线上 `app.js` 里有没有本版的新符号）。**只看
`find R/ -newer app.R` 为空是不够的** —— 那只说明磁盘状态，不说明线上在服务
哪一份。

退出码 0 = 全绿。数据根 `/tmp/dsapp_v17a/data`，截图 `/tmp/dsapp_ui_v17`。

**变异（证明尺子能自己证伪，缺一层就是「自检全绿 ≠ 功能被验过」）**：

```bash
/home/biomamba/miniconda3/bin/python tests/ui_v17/mut_quiet.py         # 5 个变异
/home/biomamba/miniconda3/bin/python tests/ui_v17/mut_sendtext.py      # 3 个变异
/home/biomamba/miniconda3/bin/python tests/ui_v17/mut_files_acl.py     # 1 个变异
/home/biomamba/miniconda3/bin/python tests/ui_v17/mut_selftest_v17.py  # selftest 那 8 个变异
/home/biomamba/miniconda3/bin/python tests/ui_v17/mut_mirror.py        # item 2 的 2 个变异
```

变异一律只动**隔离实例**（`/tmp/dsapp_v17a/app`），仓库一个字节不碰，跑完
`sha256` 逐字节核对还原 —— 开发目录就是生产目录，在仓库里"改坏一下试试"
等于把线上改坏。

> ⚠️ 起实例**一律走 `make_instance.sh`**。仓库根那份 `.Renviron` 会把一个
> /tmp 实例**接到生产库**上，全程不报错、界面无异常。
>
> ⚠️ 这个实例是一个 `shiny::runApp` **单进程**，所以「R 代码只在 worker 换代时
> 生效」在这里的形态是**整个进程重启**才生效。改完 `R/*.R` 必须重跑一次
> `make_instance.sh`（它会先 kill 掉旧实例），只 `page.reload()` 不够。
>
> ⚠️ 端口 8982。8979/8980/8981/8983 是 V16.9–V16.10 的实例，都可能还挂着
> （收尾要拿老探针在上一版上跑对照）。`probe_sendtext.py` 里那条**实例盘上
> 的 `DSAPP_VERSION`** 断言就是兜底的 —— 连错实例时它比"某个选择器找不到"
> 先红，而且报的是真正的原因。

## 每个文件是干什么的

| 文件 | 性质 | 说明 |
|---|---|---|
| `_common.py` | 工具 | `ui_v168/_common.py` 的副本（照老规矩抄、不 import）；默认值已改成 8982 / `dsapp_v17a` / `dsapp_ui_v17` |
| `probe_quiet.py` | 探针 | item 1。**只用登录页** —— 断线状态机是纯前端，不需要账号、不碰任何库 |
| `probe_sendtext.py` | 探针 | item 3。带假 LLM，按住"发送"那一刻的 DOM 值 vs 服务端镜像 |
| `probe_files_acl.py` | 探针 | item 6。两个账号、两份工作区、一个哨兵文件，手工把 `files-pick_conv` 改成对方的会话号 |
| `mkfix_u11.py` | 夹具 | 把 uid=11 生产盘上的**目录结构**照搬进实例（名字 + 层级，文件 1 字节占位）；生产库一律 `mode=ro` |
| `verify_live.py` | 核对 | **上线之后**跑：线上（34038）服务的是不是盘上这一版。R 侧看页脚版本、`www/` 侧看 `app.js` 正文里的新符号。⚠️ 静态资源在 `/YCFS_APP/app.js`，**不是** `/YCFS_APP/www/app.js`（那个 404，而 `.test()` 对着 404 正文照样返回 false —— 会把一次成功的部署判成失败） |
| `diag_u11.py` / `diag_u11b.py` | 诊断 | **不下断言**，只 dump 两个页面的字和结构。本仓规矩：先看清现场，再写判据。⚠️ 登录用的是**实例库**里 uid=11 那行的邮箱（`mkfix_u11.py` 从生产照抄的）—— 脚本**从库里读**，不把真人邮箱写进仓库 |
| `mut_*.py` | 变异 | 见上 |

## ★ 每条为什么非得上浏览器

**item 1（静默期）**：`dsappPromptAllowed/Mark/Owe/Flush` 全是 `app.js` 里的
纯函数，R 侧一条都碰不到。真正要证的也不是"函数返回了对不对"，而是：

* 静默期内`#dsapp-offline-mini` / `#dsapp-offline` **屏幕上真的没多出来**；
* 但 `dsappNet.state` **照样是 `down`** —— 挡的是提示，不是事实（补发队列
  读的就是它，挡错了这里，"断线自动重连"整条路一起完蛋）；
* 被挡下的那条记成**欠账**、由真实的 2 秒看门狗**自己**补上（A3 不主动调
  `flush()`）—— 没有 A3 的话，"闸门生效"和"提示永远丢了"在 A2 里长得一模一样。

**item 3（组字）**：服务端手里的 `input$input` 是**慢一拍的镜像**。纯英文看不
出来（打字到点按钮之间隔着几百毫秒，值早同步过去了）；输入法把这段时间压成
零。探针复现的是**机理**：让 DOM 的值和服务端手里的镜像**故意不一致**，再看
发出去的是哪一个。修复前发的是镜像（= 拼音那份），修复后发的是 DOM 里的原文。

**item 6（越权）**：审计的结论是**读代码**得来的（缺一道 `db_session_role` 闸），
当时没有运行时复现。探针把它补上 —— 而且 3b 那条**不能省**：只断言"看不到甲
的"话，乙那边**根本没有会话**时面板本来就是空的，这条在任何情况下都绿，包括
"这一页整个坏了"。

**item 2**：R 侧的 `tests/v17_mirror.R` 已经把"函数对不对、盘上有没有多出空壳"
验穿了，还得上浏览器的理由写在 `mkfix_u11.py` 的头部 —— 用户报的是"**页面上
看到的东西不对**"，而我在数据层怎么看都是对的。

## ★★ 这些**验不了**（写在这里，免得下一个人把全绿当成"验过了"）

1. **真输入法**。headless Chromium 没有 IME，`compositionstart/update/end`
   是脚本派发的。探针证的是**机理一一对应**（镜像 vs DOM），不是"某台机器上
   某个输入法也这样"。那一条只能靠线上观察。
2. **和体积/内容有关的症状**。`mkfix_u11.py` 只搬**结构**，占位文件是 1 字节
   —— "15 GB 的目录打不开""大文件列表卡住"这类一条都复现不出来。
3. **item 4（`Biomamba_ceshi` 文件页彻底空了）没复现**。用忠实结构副本跑，
   文件页 5 个目录**全都画出来了**，工作区那张卡 4 个会话 309/36/61/52 个文件。
   生产盘 `data/files/u11/` 是 5 个目录 15 GB，文件页那条路**没有审计日志**
   ⇒ 没有证据可查。诚实结论是"未能复现"，不是"已经修好"。
4. **生产上那批镜像空壳没有删**。那是**生产用户数据**，删不删是用户的
   决定；这一版只保证**不再长出新的**。数目**现读**，不抄：

   ```bash
   python3 tests/ui_v17/count_mirror_shells.py        # 只数，不动
   ```

   2026-10-08 归档那一刻的读数是 **133 个**（312 个目录里；里面**有真文件的
   0 个**；另有 21 个空目录是模型自建的，V8 item 7 要保，**不在**这 133 里）。
   ⚠️ 这份 README 早先写过「105 个」—— 那是个**抄错的数**（对着 `u11` 单独
   数过一遍就当成了全体）。`count_mirror_shells.py` 的注释里写着「数字要跟着
   这次的盘走」，指的就是这种。

## 几个坑

* `_common.enter_app()` 只会**注册**新账号；要用**已有**账号登录得自己填
  `#welcome-login_email` / `#welcome-login_password` 再点 `#welcome-do_login`。
* 进对话页先 `C.ensure_no_modal(pg)`：新账号第一次开对话会弹「AI 怎么干活？」，
  它盖在整页上，**所有** click 都报 `intercepts pointer events`，报错指向按钮本身。
* 空文件夹那张表是**另一张表**（`nrow(df) == 0` 时只有一列「提示」），
  所以 `td[1]` 会 undefined —— dump 行的时候要么判列数，要么整行取字。
* `mut_quiet.py` / `mut_sendtext.py` 的**预期红名单先写死**在文件里，跑完比对：
  预期该红的没红 = 探针没劲；预期不该红的红了 = 变异打歪了（改到了别处）。
  第一版 `M2` 就把"静默期过了卡片照出"错写进预期，跑出来判 ❌ ——
  那是**记账写错了**，不是探针没劲。
* `mut_selftest_v17.py` 里**判据从仓库按绝对路径读、被测的 `www/app.js` 从
  cwd 读**。第一版两者都从 cwd 读，而实例里那份 `selftest.R` 是上一版的、
  根本没有「V17 item 1」这一节 ⇒ 8 个变异**全都**报
  `attempt to select less than one element`。那不是"变异没打上"，是**尺子拿错了**。
