# tests/ui_v13 —— V13 七项改动的浏览器回归

`selftest.R` 查的是函数和服务端行为（补同步搬了没有、模型分堆对不对），
查不到"用户点下去会发生什么"。V13 这七项里有一半是**布局和可见性**问题 ——
黑底黑字、按钮压住界面、文件夹看不见 —— 这些只有真浏览器算得出来。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（默认 8898，数据在 /tmp/dsapp_v7test/data）
bash tests/ui_v7/make_instance.sh

# 2) 四个脚本，各自独立，可以只跑其中一个
python3 tests/ui_v13/contrast.py      # item 1        —— 配色对比度
python3 tests/ui_v13/overlap.py       # item 5        —— 布局重叠/命中测试
python3 tests/ui_v13/teams_files.py   # item 2 / 3 / 6 —— 文件区隔离、补导入、团队
python3 tests/ui_v13/skills.py        # item 4        —— 内置技能
```

playwright 在本机的 miniconda 里：用 `/home/biomamba/miniconda3/bin/python`，
不是系统的 `python3`。退出码 0 = 全绿。

`make_instance.sh` 会先杀掉端口上那个旧实例再起新的 —— 不杀的话跑的还是旧
代码，症状是"改了代码测试结果还是老样子"。

路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8898/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v11test_224730/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v13`（截图） |

## ⚠️ 前置条件：`skills_builtin/` 必须在副本里

item 4 的内置技能正文放在仓库根目录的 `skills_builtin/`（11 个 `.md`），
**它是个目录，不在 `app.R` 的 `source()` 列表里**，所以任何"拷贝代码起实例"
的脚本都很容易漏掉它。

漏掉的后果不是报错 —— `dsapp_skills_builtin_md()` 读不到就跳过那一篇（这是
故意的，好让用户自己删掉某篇），表现是**内置技能无声地少了十来条**。
`skills.py` 会因此红一片，而你对着 UI 找半天也看不出哪里坏了。

`tests/ui_v7/make_instance.sh` 和 `deploy.sh` 都已经带上它了。如果你是手写
`cp` 起实例，记得加：

```bash
cp -a "$REPO/skills_builtin" "$APP/"
```

## ⚠️ 三个脚本都会**真的**动数据

`teams_files.py` 会真的注册两个账号、建一个团队、往库里插对话和文件。
所以只能对着一次性副本跑。`_common.guard()` 是闸门：副本的 `DSAPP_DATA_ROOT`
不在 `/tmp` 下就**拒绝启动**。

它拦的是一类真实事故 —— 副本放在 `/tmp`，但副本的 `.Renviron` 里
`DSAPP_DATA_ROOT` 还指着线上那份。而且**闸门看的是 `.Renviron` 这个文件
写了什么，管不了那个实例实际在读哪一份**（R 是相对**启动时的工作目录**找
`.Renviron` 的）。所以每个脚本注册完还要再验一次"刚建的账号出现在
`DATA_ROOT` 里"，见 `_common.seed_or_die()`。

## 这七项分别验的是什么

| item | 用户原话 | 在哪验 |
|---|---|---|
| 1 | 「claude风格下，报错解读和代码都是黑底黑字」 | `contrast.py` |
| 2 | 「比如brca_result这个文件夹，我在文件管理区就看不到」 | `teams_files.py` |
| 3 | 「共享会话需要在组内账户可以选择……需要有团队管理系统和界面」 | `teams_files.py` |
| 4 | 「把这几个skills的内容也内置一下」 | `skills.py` |
| 5 | 「发送按钮会和文件界面重合，调整下布局」 | `overlap.py` |
| 6 | 「文件管理区不用所有人可见，每个账号显示自己的管理区」 | `teams_files.py` |
| 7 | 「千问AI平台是可以提供其它厂商的api接口的……优先显示它自己的接口」 | 不在浏览器层 —— 见 `R/models.R` 和 `selftest.R` 里那一组分组断言 |

item 7 是纯数据/纯函数（哪家的清单里有哪个模型、按什么规则归堆），没有可点
的界面行为，所以钉在 `selftest.R`。**但它的数据是会过期的** —— 转售清单是
查真实文档抄下来的，模型下架、上新都要回来改 `DSAPP_RESOLD_MODELS`。

## 写这类脚本时踩过的坑（别重复踩）

### 一、配色（`contrast.py`）

- **不能靠读 CSS 源码验。** item 1 的根因是一条**语法完全合法**的规则：
  `pre.dsapp-code { background: #010409 }` —— V6 只有深色皮时写死没问题，
  V8 加了浅色皮之后底色还是近黑，而字色走 `var(--bs-body-color)`，于是
  黑底黑字。源码里搜不出任何异常。**只能取浏览器算出来的最终颜色**，按
  WCAG 算对比度。
- **必须自己种一段对话。** 代码块和报错块只在渲染出内容之后才存在于 DOM。
  不种的话整组检查**一条都跑不到**，而"没跑到"和"全通过"在输出上长得一模
  一样。种法是直接往测试库的 `chat_messages` 里写行（不走模型、不用等）。

### 二、布局（`overlap.py`）

- **矩形相交判不出"点不着"。** 要判就判命中测试：取控件中心点问
  `document.elementFromPoint()` 返回的是谁，不是它自己也不是它的后代，
  就是被压住了。
- **但"命中的不是它"有一半是假失败**，要分两种原因：
  1. **祖先** —— elementFromPoint 返回包含 el 的元素。祖先永远画在后代
     **下面**，所以这不可能是"盖住"，真实原因是 el 自己 `pointer-events:
     none` 或者没有盒子。判据：`top.contains(el)` 直接放过。
  2. **兄弟但 `pointer-events: none`** —— 同上，放过。
  第一版没分这两类，报了 7 页 × 5 条的假失败。

### 三、Shiny 交互（`teams_files.py`）

- **`fill()` 完立刻 `click()` 会丢值。** `input$new_dir` 还是 `""`，
  `req(nzchar(...))` 静静地把这次点击丢掉 —— 用户看到的是"点了没反应"。
  中间要 `wait_for_timeout(700~800)`。`checkboxGroupInput` 逐项回传同理。
- **`note()` 在 `mod_admin.R` 里渲的是行内 `#admin-action_msg`，不是
  `.shiny-notification` toast。** 等 toast 会一直等不到。
- **Playwright strict mode：多个 toast 时
  `page.inner_text(".shiny-notification")` 直接抛异常。** 用
  `page.locator(...).all_inner_texts()` 再 join。

### 四、文件页的几条既有行为（找 bug 时会误判成新 bug）

- **`do_mkdir` 建完会进到新目录里**（`current_dir(res$rel)`）。所以建完
  文件夹，表格列的是那个**空文件夹**的内容，不是父目录。想看父目录要点
  面包屑 `#files-crumb_0` 回去。
- **补同步是挂在"文件页页签"上的，一个 Shiny session 只跑一次**
  （`mod_files.R` 里那个 `backfilled <- reactiveVal(FALSE)`）。
  所以测试里那个"历史产物"**必须在第一次访问文件页之前**就在库里 ——
  之后再造，补同步已经跑过了，不会再有第二次。造数据的 helper 要放在
  第一个 `goto(page, "files")` 前面。
- **`dsapp_sync_dir()` 会写 `sync_dirs` 那一行**，它本身就是"第一次同步时
  记下落点"的函数。所以在补同步**之前**调它，这个对话在补同步眼里就已经
  "同步过了"。顺序只有一种写法是对的：

      查前提 → 补同步（只出现一次）→ 才去要落点

  这条在 `selftest.R` 那一段和这里都踩过，表现都是"文件明明搬过去了，
  红的却是没搬"。

### 五、内置技能（`skills.py`）

- **不要量 `page.inner_text("body")` 来断言正文长度。** 技能正文在弹窗的
  `#skills-f_body` **textarea** 里，量整页 body 量到的是列表本身（两千多
  字），于是四万字的正文报"是空壳"。量文本域用 `input_value()`。
- 「内容是空的」和「内容不对」是两码事。前者是 bug（这里能机验），后者是
  编辑问题（要人读）。脚本只验结构：篇数、内置标记、体量提示、搜索、正文
  非空。
