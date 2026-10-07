# tests/ui_v1314 —— Test_V13.14 的浏览器验收

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8914 /tmp/dsapp_v1314

# 2. 跑
python3 tests/ui_v1314/probe_v1314.py        # 退出码 0 = 全绿
```

脚本里的默认值（`URL` = `http://127.0.0.1:8914/`、`APP` = `/tmp/dsapp_v1314/app`、
`OUT` = `/tmp/dsapp_ui_v1314`，见 `_common.py` 顶上）和上面那条命令是**一套**，
起完直接跑就行，不用设环境变量。

> ⚠️ 实例用的是**拷贝**（`cp -a R www app.R selftest.R skills_builtin`），不是软链 ——
> `R/*.R` 和 `www/` 改完之后必须**重跑 make_instance.sh**，否则浏览器看到的还是上一份，
> 症状是"改了没反应"。数据（`/tmp/dsapp_v1314/data`）不会被覆盖，只同步代码。

> ⚠️ 本探针**不需要**假模型服务（`/tmp/mock_llm.py` 那一套）。它一次模型调用都不发，
> 只量界面。"请求体里到底有没有 `max_tokens`"是 `selftest.R` 那边用
> `.chk_fake_llm_srv()` 证掉的，别在这儿重复造。

## 这一版管什么

| 工单 | 一句话 | 断言 |
|---|---|---|
| item 22 | 单次回复上限的最右一格 = **不设上限** | 拖到最右 → 数字栏**空**、那四个字**高亮**；填回 8192 → 高亮灭；再清空 → 高亮回来**且滑块跟着走到最右** |
| item 23 | 帮助页独立到**左侧导航栏** | 左栏有 `help` 且在「设置」后面；点它真的切过去；二维码图真的加载；设置页只剩三个页签、没「帮助」 |
| item 24 | 「还没有 Key**和URL**？」挪到厂商**下面** | 夹在「厂商」和「接口地址」之间，而且**离厂商更近**；文案带「和URL」；申请链接仍是带 aff 的注册入口 |

### 为什么这三条非要在浏览器里再验一遍

自检（`Rscript selftest.R`）已经把源码和数据通路证到位了 —— 连"不设上限时请求体里
**没有** `max_tokens` 这个键"都是拿本机一个假 HTTP 服务收的请求读回来的。浏览器这一边
回答的是**另外三个问题**，它们可以各自单独坏掉而源码级断言全绿：

1. **用户拖得到那一格吗。** 服务端算得再对，滑块拖到头若停在 10485760，用户看到的就是
   "改没生效"。所以这里**真的用鼠标拖**（`pg.mouse.down/move/up`），不调
   `$(sel).data('ionRangeSlider').update({from:...})` —— 从控件内部改值的话，Shiny binding
   收不收得到 onChange 是实现细节，而"拖不动的东西用 update() 照样能测成绿的"。
2. **点下去真的会切页吗。** nav 的 value 对不上时是"点了没反应"，不报错也不进日志。
3. **"上面"是个几何断言。** 只查那行字在不在 DOM 里的话，位置错了照样绿。要量的
   是它夹在「厂商」和「接口地址」之间、并且**离上面更近**（补的那对上下边距就是为这个）。

## 三个坑（都踩过，别再踩）

**1. ★★ 拖滑块之前必须先把元素滚进视口 —— 这是本次唯一一次假失败。**
设置页很长，滑块默认落在 **y = 1104**，而视口高 950 —— 在视口**外面**。Playwright 的
mouse 坐标是视口坐标系，往视口外移动**没有任何元素接收事件**，于是"拖了等于没拖"；
偏偏 `bounding_box()` 照样老老实实返回一组正数，全程不报错。表现极具迷惑性：
**第一次拖不动、第二次又能动**（因为中间那次 `fill()` 顺手把页面滚下去了），
看着像"第一次点击没生效"这种玄学。`drag_slider_to()` 现在先
`scroll_into_view_if_needed()`，并且**把手不在视口里就直接抛异常** —— 宁可炸掉也不要
静悄悄拖空。

**2. ★★ 量这个滑块必须用 `.dsapp-maxtok-slider` 限定范围。**
ionRangeSlider 的结构和想当然的不一样（2026-09-26 dump 出来的）：

```
div.form-group
  label#model-max_tokens_slider-label      ← 0×0
  span.irs.irs--shiny.js-irs-2             ← 真正的控件！是**兄弟节点**
    span.irs > span.irs-line / span.irs-handle.single / …
  input#model-max_tokens_slider            ← 被藏起来的那个，4×4
```

两个后果：(a) `.irs` **不是** `#model-max_tokens_slider` 的子节点，写成
`"#model-max_tokens_slider .irs"` 会一直等到 30 秒超时，报"找不到元素"，看着像滑块
没渲染；(b) 这一页上有**三个** ionRangeSlider（`js-irs-0` 是隐藏对话页那个 0×0 的、
`js-irs-1` 是温度、`js-irs-2` 才是它），裸写 `.irs` 会命中隐藏页那个 0×0 的，
量出来的几何**全是 0** —— 而 0×0 在有些断言里会"看起来像对的"。把手是
`.irs-handle.single`，不是 `.irs-slider`。

**3. 找不到元素就 `click()` = 整个脚本当场没了。**
`pg.click()` 超时抛的是 playwright 的 `TimeoutError`，**后面 item 24 那一段根本跑不到**。
本条真坏掉时，"item 23 红 + item 24 一行都没有"看起来很像"item 24 也一起坏了"，
其实是没跑到。现在点之前先 `count()` 判一下。

## 这一版做过变异验证

按仓库约定，承重最大的几条断言都反向验过 —— **改坏实例副本**（不是源码）看它会不会红：

| 变异 | 结果 |
|---|---|
| `www/app.css` 里 `.dsapp-key-help` 那对边距清零 | item 24 只有「离厂商更近」那条红，`{'above': 24, 'below': 24}` ✔ 正是它该抓的 |
| `R/models.R` 的 `dsapp_maxtok_slider_max()` 退回 `r$max` | item 22 的「滑块也跟着走到最右那一格」红（读到 10485760，应为 10486784）✔ |
| `R/uiprefs.R` 里删掉 `value = "help"` 那一项 | item 23 前两条红 ✔（也正因为这次，第 3 个坑才被发现） |

变异做完**从源码整份拷回去**再跑一遍确认全绿，别把变异留在实例里。

`_common.py` 是共用的：`enter_app()` 建号进应用（返回 email）、`seed_or_die(email)`
拿到 `(uid, db_path)` 并**确认这个实例读的不是线上库**（找不到就硬退出）、
`goto(page, name)` 切页、`pick_select()` 选 selectize（它把原生 select 清空了，
得读 `.selectize-dropdown`，而且**打开时才铺进 DOM**）、`Chk()` 记断言
（`Chk()` 不收参数，`.done()` 返回 0/1，文件末尾一律 `sys.exit(k.done())`）。
