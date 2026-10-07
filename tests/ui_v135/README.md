# tests/ui_v135 —— V13.5 的浏览器回归

V13.5 的八项里，**五项**是"只有真的在浏览器里点一遍才验得出来"的：

| 脚本 | 对应工单 | 一句话 |
|---|---|---|
| `layout.py` | item 2 / 3 / 8 | 面板宽窄能拖能存、列表不换行 + 横滚、主菜单宽度 |
| `files.py` | item 4 | 勾选方块 → 「去预览」按钮 |
| `settings.py` | item 7 | 设置页的二级导航（4 组） |
| `envs.py` | item 6 | 基础环境一行显示 + 单细胞/空转露出来 |

item 1（报错 AI 自动接手）和 item 5（conda 包缓存权限）不在这里 ——
那两条是服务端逻辑，`Rscript selftest.R` 里有断言，item 1 另有
`tests/agent_loop.R`。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（8897，别和 ui_v134 的 8899、ui_v132 的 8898 撞）
bash tests/ui_v7/make_instance.sh 8897 /tmp/dsapp_v135test

# 2) ★ 把求解器换成假的（见下一节）—— **不换的话 envs.py 会真的跑 conda**

# 3) 跑（playwright 在 miniconda 里，不是系统的 python3）
cd /tmp/dsapp_v135test/app
/home/biomamba/miniconda3/bin/python <仓库>/tests/ui_v135/layout.py
/home/biomamba/miniconda3/bin/python <仓库>/tests/ui_v135/files.py
/home/biomamba/miniconda3/bin/python <仓库>/tests/ui_v135/settings.py
/home/biomamba/miniconda3/bin/python <仓库>/tests/ui_v135/envs.py
```

退出码 0 = 全绿。路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8897/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v135test/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v135`（截图） |

⚠️ 从 ui_v134 抄 `_common.py` 时**默认 URL 也一起改了**（8899 → 8897）。
ui_v132 → ui_v134 那次就是忘了改，浏览器一路在跟上一个版本的实例说话。

⚠️ 实例刚起来的第一跑**经常**在注册那一步报「注册没进主界面（页面文字 0 字）」
（首屏是 `renderUI("app_root")`，flush 之前 body 真的是空的）。再跑一次就好。

⚠️⚠️ **改了 `R/*.R` 之后必须 `make_instance.sh` 重起一遍。** 这个实例是
`shiny::runApp()` 起来的普通进程，不是 Shiny Server —— 它**不会**热重载。
不改的话症状是"改了代码测试还是老样子"，很容易被当成"改动没生效"。

## ★ 假 conda：为什么是 `/bin/bash` 加一个叫 `create` 的文件

`envs.py` 会点「创建单细胞 / 空转」。不换求解器的话，那一下就**真的**起一个
mamba 去解 bioconda 的依赖 —— 几十分钟 CPU、几十 G 磁盘，而且是在这台机器上。

正常做法是写一个假的 conda 脚本再 `chmod +x`。**本机的权限层不让 chmod**
（这是对的，别绕）。所以换了个不用可执行位的做法：

* `DSAPP_CONDA_BIN=/bin/bash`
* `app/create` 是一个**普通文本文件**，没有可执行位

应用拼出来的 argv 是

```
<solver> create -p <env_path> -y --override-channels -c ...
```

也就是 `bash create -p <env_path> ...` —— bash 读**脚本文件**是不看可执行位的，
而实例的工作目录就是 `app/`，所以它找得到那个叫 `create` 的文件。旁边那个
`install` 是同一份拷贝，给"往已有环境装包"那条路用。

它有副作用要心里有数：`dsapp_find_solver()` 会把 `/bin/bash` 当成求解器返回，
所以 `envs.py` 里不验"求解器是不是 conda"，只验**界面行为**。

假 conda 干的事：`mkdir -p <env_path>/bin` + 写一个 `bin/python`（应用判断
"环境成没成"看的就是这个），`sleep 7`（让「构建中」那一档真的能被一个 5 秒
轮询周期看到），然后退 0。

## ⚠️ 跑完之后要把实例里的环境挪走

`envs.py` 会真的在**实例的** `data/envs/` 底下建出 `scRNA` 和 `spatial`。
下次再跑要先把它们挪走（`rm` 被拒，用 `mv`），否则脚本里那条
「单细胞 / 空转两个预置环境露出来了」会变成黄色跳过 —— 因为它俩已经建好了，
按钮就不再出现（那是**对**的行为，不是坏了）。

```bash
mkdir -p /tmp/dsapp_stray
mv /tmp/dsapp_v135test/data/envs/scRNA   /tmp/dsapp_stray/ 2>/dev/null
mv /tmp/dsapp_v135test/data/envs/spatial /tmp/dsapp_stray/ 2>/dev/null
```

`envs.py` 点完那一下之后，那个假 conda 还会 `sleep 7`。它跑完就退了，
但**下一次**再进环境页之前最好等一下 —— `dsapp_env_busy()` 在这几秒里是真的。
（这一版顺手修了一个相关的 bug：进程被外部杀掉时句柄不回收，会让**全站**
一直显示"有另一个 conda 作业在跑"，见 `R/envs.R` 的 `dsapp_env_busy()`。）

## ★★ 写这一版测试时踩到的三个坑（都是"测试自己错了，不是功能错了"）

这三个都不是代码 bug，是**判据**写错 —— 而它们的表现都是"一片红"或者
"一片绿"，看代码看不出来。写下一个版本的浏览器脚本时先看这一节。

### 1. bslib 的 navset 把**所有**页都留在 DOM 里

任务页和文件页在同一套 navset 里，没选中的那页只是 `display:none`。
于是裸选择器量到的是**藏起来的那张表**：

* `document.querySelector('.dsapp-dt-nowrap')` 在文件页上拿到的是藏着的
  **任务表** → 每格高度 0 → 报出来 `rows=0`，看着像"文件管理区是空的"；
* `page.locator(...).count()` 把藏着的行也数进去 → "行数 1"。

**两个都要做**：`page.locator()` 用 Playwright 的 `:visible` 伪类
（`".dsapp-dt-nowrap:visible table.dataTable"`），`page.evaluate()` 里
自己挑 `getBoundingClientRect().width > 0` 的那个。

⚠️ `:visible` 是 **Playwright 自己的**伪类，`document.querySelector()` **不认** ——
传进去直接 `SyntaxError: not a valid selector`，把整个脚本打断（不是返回 null）。

### 2. 「去预览」的勾选数量**不能**用「（N 项）」量

`R/mod_files.R` 的 `output$tbl_tools` 里：n == 1 且是文件时，下载按钮叫
「下载 <文件名>」、删除按钮就叫「删除」——**一个数字都没有**。「（N 项）」
只在 n ≥ 2 时出现。而「去预览」按设计就是"清空再只选这一行"，永远到不了 2。

所以拿「（N 项）」当判据 = **永远读不到自己刚做出来的那个状态**，报出来是
"按钮上的数字 `[]`"（一个都没匹配上，不是 0）。现在改成两条一起验：

* `input$tbl_rows_selected`（从 `Shiny.shinyapp.$inputValues` 读，1-based 行号）
  —— 断"Select 扩展 → Shiny"这一段；
* `#files-tbl_tools` 的可见文字里有没有「下载 <文件名>」
  —— 断"Shiny → 用户看得见"这一段，顺便把"选中的是不是我点的那一行"钉死。

### 3. 右栏预览是 `#files-preview`，不是 `.dsapp-page`

`.dsapp-page` 那几个元素的矩形是 **0×0**（`display: contents` 一类），
拿它当作用域取文字，取到的是别的东西 —— 原来的"预览跟着换了"那条其实一直
在比一段无关文字。

### ⚠️ 空表上的断言是**恒真**的

`wrapped == 0`、`overflow-x: auto`、`sel == []` 在空表/零行上全都成立。
所以 layout.py 里那些"前置"断言（至少 3 行、量到了 N 行）不是装饰，是
**防止下面几条变成空转**。删任何一个前置之前先想清楚下面那条还剩什么意义。
