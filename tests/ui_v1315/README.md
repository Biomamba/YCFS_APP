# tests/ui_v1315 —— Test_V13.15 的浏览器验收

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8915 /tmp/dsapp_v1315

# 2. 跑
python3 tests/ui_v1315/probe_v1315.py        # 退出码 0 = 全绿
```

脚本里的默认值（`URL` = `http://127.0.0.1:8915/`、`APP` = `/tmp/dsapp_v1315/app`、
`OUT` = `/tmp/dsapp_ui_v1315`，见 `_common.py` 顶上）和上面那条命令是**一套**，
起完直接跑就行，不用设环境变量。

> ⚠️ 实例用的是**拷贝**（`cp -a R www app.R selftest.R skills_builtin`），不是软链 ——
> `R/*.R` 和 `www/` 改完之后必须**重跑 make_instance.sh**，否则浏览器看到的还是上一份，
> 症状是"改了没反应"。

> ⚠️ 实例里 `R/*.R` 只在**进程启动时** source 一次（这里是 `shiny::runApp`，
> 没有线上那套 worker 换代）。所以做完变异验证要**重启实例**才看得到变异生效 ——
> 停旧 pid + 重起、**不重新拷代码**的那一小段脚本见本文件末尾「变异验证」一节。

> ⚠️ 本探针**不需要**假模型服务（`/tmp/mock_llm.py` 那一套）。它一次模型调用都不发，
> 只量界面 + 点按钮。

## 这一版管什么

| 工单 | 一句话 | 断言 |
|---|---|---|
| item 25 | 「还没填 Key」那颗按钮跳**模型服务**页（不是设置页） | 弹窗正文说「模型服务」；按钮 id 是 `chat-goto_model`、写着「去模型服务」；**真的点下去** → 左栏高亮变 `model`、模型面板可见、设置面板藏起来 |
| item 26 | 「确认 / 更新」**头尾各一颗**、和「获取模型」一样宽 | 两颗都在且可见；三颗**宽度一致**；头部那颗在「厂商」**上方**且在**首屏**内；底部那颗仍在「生成参数」下方；两颗文字一致；点**头部**那颗真的存下去（提示行变「已保存」）且**底部提示行一起变**、两颗标签一起变「更新」；点**底部**那颗也存得下去 |

### 为什么这两条非要在浏览器里再验一遍

自检（`Rscript selftest.R`）已经把源码证到位了 —— 它甚至能证明
`nav_panel("模型服务", value = "model")` 真的存在。浏览器这一边回答的是另外三个问题，
它们可以各自单独坏掉而源码级断言全绿：

1. **点下去真的会切页吗。** nav 的 value 对不上时是"点了没反应"，不报错也不进日志。
   所以这里把弹窗**真的点出来**、按钮**真的按下去**，再回读左栏哪一项 active。
   判据是**左栏高亮**，不是"弹窗关掉了"—— 弹窗关掉只说明 `removeModal()` 跑了。
2. **"上方 / 下方 / 一样宽"都是几何断言。** 只查 DOM 里有两个按钮的话，两颗都挤在
   底部也照样绿。"防止用户看不到"这句需求本身就是几何的：头部那颗必须在**首屏**里
   （`y < 视口高 950`），加了个要滚动才看得见的按钮等于没加。
3. **新加的那颗按钮真的接上线了吗。** id 写错、observer 忘接，表现都是"点了没反应"——
   而"点了没反应"和"点了但本来就没东西要存"在界面上区分不开。所以这里填一把假 Key
   再点，看提示行有没有从"还没填 Key"变成"已保存"。

## 三个坑（都踩过，别再踩）

**1. ★★ 量「厂商」的坐标不能拿 `#model-vendor` —— 那个元素是 0×0 的。**
本版唯一一次假失败就是它：探针报「头部那颗在厂商**下方 143px**」，看着是个完全可信的
数字，源码里它明明在厂商**上方 91px**。原因：
`selectInput` 被 `app.js` 过了一层 **selectize**，**原生 `<select>` 是隐藏的**，
`getBoundingClientRect()` 返回**全 0** —— 于是 `T.top - V.top` 算出来正好等于按钮
自己的 y（143）。**一个分母为 0 的减法，结果看着一样很合理。**
现在量的是**看得见**的那两个（厂商的 `<label>`、以及 `#model-vendor + .selectize-control`），
并且 `vis()` 兜底：真量到 0×0 的元素就返回 `err`，绝不拿去相减。
（同一个 selectize 坑在 `_common.py:pick_select()` 里也记着一条。）

**2. ★★ 量不到东西时别让脚本炸 —— 一炸，后面整段都"没跑到"。**
两处都是这么栽的：(a) `pg.wait_for_selector()` 超时抛 `TimeoutError`，
item 25 真坏掉时 item 26 整段跑不到，看起来像"item 26 也一起坏了"；
(b) 几何函数返回的是 `{'err': ...}` 而**不是 `None`**，`geo["top_vs_vendor"]`
直接 `KeyError`。现在：等待走不抛异常的 `wait_for()`，取键一律 `.get()`，
每处使用前先 `count()`。
（V13.14 记的第 3 个坑是同一个毛病，那次炸在 `pg.click()` 上。）

**3. ★ 两条工单的断言必须互不牵连。**
item 26 开头**自己**切到模型页（`C.goto(pg,"model")`），不靠 item 25 那一跳。
否则 item 25 一坏，item 26 跟着红一片 —— 红的是别人，会把人指到错地方。
同理，几何三组（头部 vs 厂商 / 底部 vs 生成参数 / 首屏）**各自独立算**，
缺哪组只缺哪组。

## 这一版做过变异验证

按仓库约定，承重最大的几条断言都反向验过 —— **改坏实例副本**（不是源码，
更不是线上那份）看它会不会红：

```bash
# 改坏（下面两种任选）
sed -i '1177s/dsapp_goto("model")/dsapp_goto("settings")/' /tmp/dsapp_v1315/app/R/mod_chat.R
python3 - <<'PY'
p="/tmp/dsapp_v1315/app/R/mod_model.R"
ls=open(p,encoding="utf-8").read().split("\n")
open(p,"w",encoding="utf-8").write("\n".join(l for l in ls if 'commit_btn("commit_top"' not in l))
PY
# 重启实例（只停/起，**不重新拷代码**，否则变异会被覆盖掉）
OLD="$(ss -ltnp | grep ':8915 ' | grep -oP 'pid=\K[0-9]+')"; kill "$OLD"; sleep 3
cd /tmp/dsapp_v1315/app && R_HOME=/usr/lib/R nohup /usr/lib/R/bin/exec/R -q \
  -e 'shiny::runApp(port = 8915, host = "127.0.0.1", launch.browser = FALSE)' \
  > /tmp/dsapp_v1315/app.log 2>&1 &
# 跑完**一定要拷回来**：bash tests/ui_v7/make_instance.sh 8915 /tmp/dsapp_v1315
```

浏览器探针这一侧（`probe_v1315.py`，21 条）：

| 变异 | 结果 |
|---|---|
| `mod_chat.R` 那处 `dsapp_goto("model")` 改回 `"settings"` | **只有** item 25 的三条红（高亮停在 `settings`、模型面板不可见、设置面板露出来）；item 26 全绿 ✔ 正是它该抓的，也证了坑 3 |
| `mod_model.R` 删掉头部那颗 `commit_btn("commit_top", ...)` | item 26 九条红（两颗都在 / 可见 / 同宽 / 在厂商上方 / 在首屏 / 文字一致 / 标签一起变 / 点头部存不下去…），**底部那三条仍绿** ✔ 头部坏不牵连底部 |

自检这一侧（同一份变异，在实例树里 `cd /tmp/dsapp_v1315/app && Rscript selftest.R`）：

| 变异 | 结果 |
|---|---|
| `dsapp_goto("model")` → `"settings"` | item 25 那节红 **2** 条：「observer 现在跳的是 model」「不再跳设置页了」✔ |
| 删掉头部那颗 `commit_btn("commit_top", ...)` | item 26 那节红 **2** 条：「头尾各一颗」「三个路标都找得到」✔；**V13.11 item 8 整节仍然全绿** ✔ —— 那条路标改对了，而且删头部那颗不会惊动底部那一节 |

> ⚠️ **在实例树里跑自检会多出 2 条 deploy 红，那不是代码问题。**
> 实测确认：`deploy_link.sh --check` 的前提检查要求应用目录下有 `data/`，
> 而实例的 `data/` 在**上一层**（`/tmp/dsapp_v1315/data`），于是脚本在前提检查
> 就退出了（`✗ 没有 data/`），"旧地址还活着"那段根本没跑到。仓库里跑没有这 2 条。
> 看到它们别去改代码 —— 先 `DSAPP_OLDDEST=/tmp/x bash deploy_link.sh --check` 跑一遍看真实原因。

变异做完**从源码整份拷回去**（`make_instance.sh`）再跑一遍，确认 21 条全绿。

## 这一版的自检也补过两处

- `selftest.R` 里 V13.11 item 8 那一节，原来靠 grep **内联字面量**
  `actionButton(ns("commit"))` 当路标。item 26 把底部那颗也改成 `commit_btn()` 画的
  （头尾两颗必须共用一份 markup），字面量就没了 —— 路标返回 -1，下面三条
  "排在……之后"**全部**变成 `-1 > 正数` = FALSE：红是红了，但红的是**路标**、不是**位置**，
  最容易看反。现在认的是调用点 `commit_btn("commit", "commit_hint")`，
  并补了一条反向断言（内联写法不许偷偷回来，回来就是两份 markup）。
- item 25 的全仓扫描最初把 `dsapp_err_user(r, "保存这套模型设置", ...)` 和
  `showNotification("设置已保存。还没填 API Key …")` 也扫成了"指向设置页"。
  判据收紧成必须出现**指路写法**（`「设置」` / `设置页` / `设置 →`）之一。
  判据松一格，假问题就会盖住真问题。

`_common.py` 是共用的：`enter_app()` 建号进应用（返回 email）、`seed_or_die(email)`
拿到 `(uid, db_path)` 并**确认这个实例读的不是线上库**（找不到就硬退出）、
`goto(page, name)` 切页（认 value 也认中文页名，切完回读左栏高亮）、
`pick_select()` 选 selectize、`Chk()` 记断言（`.done()` 返回 0/1）。
