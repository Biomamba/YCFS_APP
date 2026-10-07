# tests/ui_v1311 —— Test_V13.11 的浏览器验收

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311

# 2. 一条一条跑
python3 tests/ui_v1311/item01_files.py
...
```

脚本里的默认值（`http://127.0.0.1:8912/` + `/tmp/dsapp_v1311/app`）和上面那条
命令是**一套**，起完直接跑就行，不用设环境变量。

> ⚠️ `www/` 下的东西改完之后要**重跑 make_instance.sh**：实例用的是拷贝
> （`cp -a R www app.R selftest.R skills_builtin`），不重跑的话浏览器看到的
> 还是上一份 CSS/JS —— 症状是"改了没反应"。`R/*.R` 和 `app.R` 同理。
> 数据（`/tmp/dsapp_v1311/data`）不会被覆盖，只同步代码。

## 顺序：这两条**必须放最后**

| 脚本 | 干了什么 |
|---|---|
| `probe_freeze.py` | `kill -9` 服务端进程，测"干净地断" |
| `probe_wedge.py` | `kill -STOP` / `-CONT` 服务端进程，测"半开的断" |

它们测的是断线遮罩（V13.11 item 7），手段就是把服务端打死或冻住。
**测试实例里那个 `shiny::runApp` 进程就是服务器本身**（线上才另有独立 worker），
所以这两条一跑完，实例就没了 —— 后面任何探针都只会得到一屏
`ERR_CONNECTION_REFUSED`。

2026-09-24 就误判过一次：先跑 `probe_freeze` 再跑 `probe_rail` / `probe_wedge` /
`probe_group`，后三条全红，看起来像"这一版把三个功能弄坏了"，其实只是实例被
自己人打死了。现在 `_common.enter_app()` 会在连不上时直接把这句话打出来，
而不是甩一坨 playwright traceback。

被打死之后重起即可：

```bash
bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311
```

## 各条管什么

| 脚本 | 工单 | 一句话 |
|---|---|---|
| `item01_files.py` | item 1 | 本对话文件只显示本对话的文件夹，点文件夹原地展开 |
| `item03_nav.py` | item 3 | 左侧导航可以拖着重排顺序 + 拖边缘改宽度，且能恢复默认 |
| `item04_tokens.py` | item 4 | 单次回复 token 上限按 million 计，任意值都收得下 |
| `item05_lit.py` | item 5 | 文献速递版块能出关键词、能发起检索 |
| `probe_ask.py` | item 10 | 以疑问句结尾时给的是**能点**的确认按钮，不是灰的 |
| `probe_freeze.py` | item 7 | 断线诊断：干净地断 vs 半开的断（**放最后**） |
| `probe_wedge.py` | item 7 | 服务端冻住时前端能不能自己发现（**放最后**） |
| `probe_rail.py` | item 8 | 「更新」按钮在最底部 + 离开模型服务时提醒未确认的改动 |
| `probe_group.py` | item 11 | 执行历史按「对话 → 每一步」两级展示 |

`probe_*` 是诊断/验收，`item*` 是按工单号命名的验收。
