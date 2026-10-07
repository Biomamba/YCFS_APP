# tests/ui_v7 —— V7 十一项改动的浏览器回归

`selftest.R` 查的是源码结构和服务端行为，查不到"页面上到底长什么样、点了会不会动"。
V7 这十一项**全部**是用户在页面上点出来的，所以每一项都得在真浏览器里验一遍。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（默认 8898，数据在 /tmp/dsapp_v7test/data）
bash tests/ui_v7/make_instance.sh

# 2) 三个脚本，各自独立，可以只跑其中一个
python3 tests/ui_v7/v7files.py    # item 7 / 9 / 10 / 11 —— 文件页
python3 tests/ui_v7/v7check.py    # item 2 / 6 / 8       —— 预览、任务多选删除、模型服务折叠
python3 tests/ui_v7/v7rest.py     # item 1 / 3 / 4       —— 跳转、确认/更新按钮、tokens 文案
```

playwright 在本机的 miniconda 里：用 `/home/biomamba/miniconda3/bin/python`，
不是系统的 `python3`。退出码 0 = 全绿。

路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8898/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v7test/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v7`（下载物 + 截图） |

## ⚠️ 三个脚本都会**真的**动数据

真的注册账号、真的往库里插对话和任务、真的删。所以只能对着一次性副本跑。
每个脚本开头有一道闸门：副本的数据目录（`DSAPP_DATA_ROOT`）不在 `/tmp` 下就
**拒绝启动**。它拦的是一类真实事故 —— 副本放在 `/tmp`，但副本的 `.Renviron`
里 `DSAPP_DATA_ROOT` 还指着线上那份，于是"跑个测试"就是在往线上库里插账号。
**副本是不是一次性的，不由它在哪决定，由它的数据目录在哪决定。**

（`tests/ui_smoke.py` 同理，也必须指向 8898。它注册的账号现在能从
管理页删掉了，但别指望这个 —— 一开始就别对着线上跑。）

## 这十一项分别验的是什么

| item | 用户原话 | 在哪验 |
|---|---|---|
| 1 | 「在[文件]页查看全部，无法正常跳转」 | `v7rest.py` |
| 2 | 「点文件名可以先跳转预览，再有下载按钮决定要不要下载」 | `v7check.py` |
| 3 | 「填好了要有确认按钮……有 key 可以使用时，确认按钮需要变成更新按钮」 | `v7rest.py` |
| 4 | 「运行提示中的"字"，是不是 token 的意思」 | `v7rest.py` |
| 5 | 「光消耗 token，不会返回结果」 | 不在浏览器层 —— 见 `R/llm.R` 的 `saw_done` 和 `R/mod_chat.R` 的 `cut_off` |
| 6 | 「任务界面需要有多选+删除按钮」 | `v7check.py` |
| 7 | 「文件请按任务分类」 | `v7files.py` |
| 8 | 「模型服务菜单不用时请收起」 | `v7check.py` |
| 9 | 「文件区域不能多选下载」 | `v7files.py` |
| 10 | 「以任务名称分类展开，并可以选择父目录一键打包下载」 | `v7files.py` |
| 11 | 「共享文件区就叫文件管理区，应该显示在最上面」 | `v7files.py` |

item 5 的复现要等 CDN 真的掐断流，没法在测试里造；它的判据是**服务端**的
`complete = saw_done` 和正文长度，所以钉在源码与 `agent_loop.R` 那一层。

## 写这类脚本时踩过的坑（别重复踩）

- **`th.select-checkbox` 恒真。** DataTables 的 Select 扩展（1.7.0）会往表头
  加这个**类名**，但不放任何控件、也不绑任何事件。断言"表头有全选"如果只看
  类名，功能完全没做也是绿的。要断言真的 `<input>`。
- **`renderDT` 默认 `server = TRUE`**，此时 Select 扩展的绑定不生效 ——
  复选框画得出来、也高亮，但 `input$tbl_rows_selected` 永远是空的。两张表都要 `server = FALSE`。
- **`inner_text()` 读不到收起的 `<details>` 里的字**，返回空串。用它断言
  "按钮上写的是更新"会得到**假红**（功能好的，测试说坏了）。读文案用
  `text_content()`。
- **两个 `actionLink` 共用同一个 input id = 其中一个点不动。** 每次点击是把自己的
  `data-val` 加一，两个 `<a>` 各记各的、都从 0 起步，第二个链接的第一次点击发出的
  值和第一个已经发过的值一模一样，Shiny 判"输入没变"就不派发。两个入口必须各自有 id。
- **`has_text="下载"` 也会匹配「打包下载」**，会点错元素、下到 zip 再拿去当 csv 解析。
  用 `:text-is()` 精确匹配。
- **裸的 `locator("summary")` 会命中外层和内层的 `<details>`**（strict mode 报错），
  用 `.first`。
- **`pkill -f` 会杀掉当前 shell**（模式把自己也匹配上了）。用
  `ss -ltnp | grep ':PORT'` 拿 pid 再 `kill`。
