# tests/ui_v1312 —— Test_V13.12 的浏览器验收

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8913 /tmp/dsapp_v1312

# 2. 一条一条跑
python3 tests/ui_v1312/probe_lit.py
...
```

脚本里的默认值（`http://127.0.0.1:8913/` + `/tmp/dsapp_v1312/app`，
见 `_common.py` 顶上的 `URL` / `APP` / `OUT`）和上面那条命令是**一套**，
起完直接跑就行，不用设环境变量。

> ⚠️ 实例用的是**拷贝**（`cp -a R www app.R selftest.R skills_builtin`），
> 不是软链 —— `R/*.R` 和 `www/` 改完之后必须**重跑 make_instance.sh**，
> 否则浏览器看到的还是上一份，症状是"改了没反应"。
> 数据（`/tmp/dsapp_v1312/data`）不会被覆盖，只同步代码。

> ⚠️ `probe_quiet.py` / `probe_dirty.py` 还要一个**假的模型服务**：
>
> ```bash
> python3 /tmp/mock_llm.py        # 监听 127.0.0.1:8931，按 OpenAI SSE 吐字
> ```
>
> 没有它的话，"分析进行时"那条会卡在"正在生成…"上等到超时 —— 红线是超时，
> 看着却像 item 20 改坏了。`/tmp/mock_llm.py` 是一次性产物（不在仓库里），
> 重写一份要点：`POST /v1/chat/completions`，`text/event-stream`，
> 每 80ms 吐一小段 `data: {"choices":[{"delta":{"content":"..."}}]}`，
> 结尾 `data: [DONE]`。

## 各条管什么

| 脚本 | 工单 | 一句话 |
|---|---|---|
| `probe_lit.py` | item 16 / 17 / 18 | 已勾技能排最上 + 「看看会发什么」真会滚到预览 + 「告诉 AI 注意事项」预设 |
| `probe_model.py` | item 19 | 模型服务是**独立页**了，而且没丢东西（小字 / 离开提醒都还在） |
| `probe_dirty.py` | item 19 误报 | 服务端自己写进控件的值，不算用户的改动 |
| `probe_quiet.py` | item 20 | 分析进行时**不刷**，但正文 / 字符数 / 秒数照旧在长 |
| `probe_tasks.py` | item 20 | 任务页改成"内容指纹"之后，行号↔id 没串、手动刷新还能强制重查 |
| `probe_back.py` | item 20 顺手 | 设置页三颗「保存并返回对话」各绑各的 id，三页挨个点都要跳回对话页 |

`_common.py` 是共用的：`enter_app()` 建号进应用（返回 email）、
`seed_or_die(email)` 拿到 `(uid, db_path)` 并**确认这个实例读的不是线上库**
（找不到就硬退出）、`goto(page, name)` 切页、`pick_select()` 选 selectize
（它把原生 select 清空了，得读 `.selectize-dropdown`）、`Chk()` 记断言
（`Chk()` 不收参数，`.done()` 返回 0/1，文件末尾一律 `sys.exit(k.done())`）。

## 两条容易写错的地方

**1. 白刷要按 outerHTML 指纹数，不能只数 `outputinvalidated`。**
Shiny 对 `reactiveVal` 的写入**即使值没变**也会让下游失效，所以"重画了多少次"
里混着大量"画出来一个字都没变"的。数次数的探针会得到一个吓人的数字却指不出
病根。`probe_quiet.py` 里两个数都记：次数是现象，指纹才是判据。

**2. 任务列表是 `ORDER BY t.id DESC`（新的在上面）。**
`probe_tasks.py` 一开始照着插入顺序断言"第 1 行 = 我先插的那条"，红的是探针
自己，看着却像"行号串了"。现在用 `row_of(title)` / `pick(title)` 先按标题找行
再点 —— 这一页所有按钮都按**行号**回查 `tasks()`，行号错位不报任何错，
点「删除选中」删掉的会是另一条，所以这条必须验。
