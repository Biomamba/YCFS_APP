# tests/ui_v139 —— V13.9 的浏览器验收

V13.9 的十二项里，**十一项**只有真的在浏览器里点一遍才验得出来
（item 5 是历史审计，不在这里；item 4 / item 9 另有一半在
`Rscript selftest.R` 里）—— 而且其中**每一条**都属于"源码看着全对，
界面上就是不对"的那一类：

| 脚本 | 对应工单 |
|---|---|
| `v139.py` | item 1 / 2 / 3 / 4 / 6 / 7 / 8 / 9 / 10 / 11 / 12（36 条断言） |

`diag_toc.py`、`probe_pv.py`、`probe_sel.py`、`probe_tabs.py` **不是**验收
脚本，是一次性的探针（见下面「四个探针」）。跑验收只跑 `v139.py`。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（8899，别和 ui_v137 的 8897、ui_v134 的 8898 撞）
bash tests/ui_v7/make_instance.sh 8899 /tmp/dsapp_v139test

# 2) 跑（playwright 在 miniconda 里，不是系统的 python3）
/home/biomamba/miniconda3/bin/python tests/ui_v139/v139.py
```

退出码 0 = 全绿。路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8899/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v139test/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v139`（截图） |

⚠️ **改了 `R/*.R` 之后必须 `make_instance.sh` 重起一遍。** 这个实例是
`shiny::runApp()` 起来的普通进程，不是 Shiny Server —— 它**不会**热重载。
不改的话症状是"改了代码测试还是老样子"，很容易被当成"改动没生效"。

⚠️ **改了 `www/` 也要重起（或者手动 `cp -a www/. <app>/www/`）。** 这一点和
线上不一样：线上是软链，`www/` 改完就生效；这个副本是**拷出来的一份**，
2026-09-21 就在这上面白跑过一轮 —— 改的是仓库的 `codex.css`，实例读的是
`/tmp/dsapp_v139test/app/www/codex.css`，量出来的几何一点没变。

⚠️ 实例刚起来的第一跑**经常**在注册那一步报「注册没进主界面（页面文字 0 字）」
（首屏是 `renderUI("app_root")`，flush 之前 body 真的是空的）。2026-09-21
那轮连着报了**两次**，第三次才好 —— 别在第 2 次就下结论说注册坏了。
判据是 `app.log` 里有没有 R 报错 + 换一个脚本（比如 `v139.py`）跑一遍还灵不灵。

## ⚠️ 这一版不碰「创建环境」，但实例里配的是**真 conda**

`make_instance.sh` 会把 `DSAPP_CONDA_BIN` 指到
`/home/biomamba/miniconda3/bin/conda`。V13.9 的十二项没有一个会去建环境，
所以这里没做假 conda（`tests/ui_v135/README.md` 里那套 `create`/`install`
文本文件的招数）。**将来要加"点一下建环境"的用例，先照那边做一个假的**，
否则那一下会真的起 mamba 去解 bioconda 的依赖。

## 这一版为什么几乎每条都要浏览器

`bslib::navset_hidden` / `navset_underline` 把**所有**面板都留在 DOM 里，
没选中的只是 `display: none`。所以

```python
page.locator(".tab-pane.active")     # 可能命中 3 个，其中两个是别页的
page.locator(".card").count()        # 永远是全部，不管切到哪一页
```

这一版踩到的**四个**"量错了地方"（每一个的症状都是**断言绿了**，不是红了）：

1. **`.dsapp-page` 不是文件页的容器。** 它只存在于三个页面
   （`mod_envs.R` / `mod_settings.R` / `mod_skills.R`），文件页的 UI 是个裸
   `tagList`。拿它当文件页的范围，读到的其实是**别的页** —— item 10 的
   前置条件因此读到 0 行，而「小方块」那条断言**空转通过**。
   现在用 `.tab-pane[data-value="files"]`。
2. **设置页里有第二个 tabset。** `.tab-pane.active` 在切到设置页之后会同时
   命中技能页的 `data-value="mine"`（DOM 顺序在前、宽度 0）、设置页、帮助页
   三块，`strict mode violation` 直接抛。而且 `.first` 拿到的是那个**宽度 0**
   的，`inner_text()` 是 `''` —— 于是 item 11 报「三栏底部都没有保存按钮」，
   而同一条东西在 `tests/ui_v135/settings.py` 里是绿的。两边都"有理由"，
   说明至少一处量错了地方：现在统一加 `.tab-pane[data-value="settings"]` 前缀。
3. **勾选要点的格子是「大小」不是「名称」。** 点 `td` 第 1 列（名称）会
   **进目录**，第二次点直接超时。`click_size_cell()` 点第 2 列。
4. **第 0 行可能是文件夹。** 「去预览」点在第 0 行上会进目录。
   `first_file_row()` 跳过名字里带 📁 的行。

## 四个探针

留着是因为它们记的是**"怎么发现的"**，不是结论：

| 文件 | 当时在查什么 |
|---|---|
| `diag_toc.py` | item 1：二级菜单到底挂没挂、挂在哪一层 |
| `probe_pv.py` | item 4：那张产物卡被压成 2 像素 —— 逐层量 `getBoundingClientRect()` 才看出是 flex 压的 |
| `probe_sel.py` | item 10：装三个时间点探针（①捕获 ②表上 ③doc冒泡），打印 `rows({selected:true}).count()`，才看出是 **Select 扩展**在行级切换、而不是我们的处理器在清 |
| `probe_tabs.py` | item 11：设置页四个页签各自量到了哪一块（上面第 2 条就是它查出来的） |

⚠️ `probe_pv.py` **刻意不 import `v139.py`**：`v139.py` 的测试体写在模块
顶层，import 它 = 把整场验收跑一遍。需要的常量在探针里各抄了一份。
