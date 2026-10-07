# -*- coding: utf-8 -*-
"""V13.12 item 19：模型服务搬成**独立页**之后的浏览器验收。

用户原话：「把模型服务换成和其它几个侧面导航栏一样的单独页面吧」。

    bash tests/ui_v7/make_instance.sh 8913 /tmp/dsapp_v1312
    python3 tests/ui_v1312/probe_model.py

⚠️ 「和其它几个一样」是这一条的判据，所以这里的断言分两半：
   **像一页**（左栏有那一项、点得动、切过去、当前项高亮、控件在主区）
   和**没丢东西**（V7 item 8 那行"一眼看出在用哪个模型"的小字还在，
   V13.11 item 8 的"改了没确认就离开要提醒"还在，只是判据换成了切页）。
   只验前半截的话，把这一页做成一个空壳子也是绿的。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

ck = C.Chk()

with sync_playwright() as pw:
    b = pw.chromium.launch()
    pg = b.new_page(viewport={"width": 1600, "height": 950})
    email = C.enter_app(pg)
    C.seed_or_die(email)

    # ---------- (a) 左栏里有这一项，而且和其它项长得一样 ----------
    items = pg.eval_on_selector_all(
        ".dsapp-rail-link",
        "els => els.map(e => ({v: e.getAttribute('data-nav'),"
        " t: (e.querySelector('.dsapp-rail-label, .dsapp-rail-txt') || e)"
        "      .innerText.trim().split('\\n')[0]}))")
    vals = [i["v"] for i in items]
    ck("item19 左栏有「模型服务」这一项", "model" in vals, vals)
    ck("item19 它和其它导航项用同一套 class（不是另画的一个）",
       pg.locator('.dsapp-rail-link[data-nav="model"]').count() == 1)
    # ⚠️ 位置是用户会直接感觉到的那一半："和其它几个侧面导航栏一样"——
    #    插在「环境」和「设置」之间（配置页归配置页那一段）。
    ck("item19 排在「环境」之后、「设置」之前",
       vals.index("envs") < vals.index("model") < vals.index("settings"), vals)
    # ⚠️ 原来那块 <details> 必须**整个**没了：留着的话模型控件会在两个地方
    #    各渲染一套（同 id 的 Shiny input 出现两次，服务端只认其中一个）。
    ck("item19 左栏里没有第二套模型控件（原来的折叠块删干净了）",
       pg.locator(".dsapp-rail .dsapp-rail-model").count() == 0 and
       pg.locator(".dsapp-rail input[type=password]").count() == 0)
    ck("item19 全页只有一套 API Key 输入框",
       pg.locator("input[type=password][id$='api_key']").count() == 1,
       pg.locator("input[type=password][id$='api_key']").count())

    # ---------- (b) 点得动，而且真的切过去了 ----------
    # ⚠️ 用真·点击，不用 dsappNav()：这一条要验的正是"用户点它会发生什么"。
    pg.locator('.dsapp-rail-link[data-nav="model"]').click()
    pg.wait_for_timeout(2500)
    ck("item19 点一下能切到模型服务页",
       pg.eval_on_selector(".dsapp-rail-link.active",
                           "e => e.getAttribute('data-nav')") == "model")
    # ⚠️ 别用 `#nav .tab-pane.active` 之类猜 bslib 的 DOM 结构：navset_hidden
    #    是"所有页都留在 DOM 里、只藏不激活"，藏法（display:none / hidden 属性 /
    #    换 class）随版本变，猜错的话报的是 "Failed to find element" ——
    #    看起来像"这一页没渲染"，其实只是选择器猜错了。判"用户看得见"最直接。
    ck("item19 别页的控件**藏起来了**（切页不是只挪了个高亮）",
       not pg.locator("#chat-input").is_visible())
    # ⚠️ 别拿 `#model-vendor` 判可见：那是 selectize 藏起来的原生 select
    #    （0×0），is_visible() 恒为 False —— 见 _common.pick_select 那段。
    ck("item19 控件在主区、看得见",
       pg.locator("#model-commit").is_visible() and
       pg.locator("#model-api_key").is_visible() and
       pg.locator("#model-vendor + .selectize-control").count() == 1)
    ck("item19 顶栏标题跟着换了（切页要通知前端改标题）",
       "模型" in pg.inner_text("#dsapp_page_title"),
       pg.inner_text("#dsapp_page_title"))

    # ---------- (c) V7 item 8 那行小字还在 ----------
    sub = pg.locator('.dsapp-rail-link[data-nav="model"] .dsapp-rail-sub')
    ck("item19 导航项下面挂着当前模型那行小字", sub.count() == 1)
    ck("item19 新账号还没配过 → 写「未配置」",
       sub.count() == 1 and sub.inner_text().strip() == "未配置",
       sub.inner_text().strip() if sub.count() else "(没渲染)")
    # ⚠️ 只有它这一项有第二行。都带的话左栏每一项高度都不一样，看起来像没对齐。
    ck("item19 别的导航项没有第二行（高度才齐）",
       pg.locator(".dsapp-rail-sub").count() == 1,
       pg.locator(".dsapp-rail-sub").count())

    # ---------- (d) 改动没确认就离开 → 提醒 ----------
    # 换一个厂商，**不点「更新」**，然后切走。
    C.pick_select(pg, "model-vendor", "0DaysSCI")
    pg.wait_for_timeout(1200)
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    modal = pg.locator(".modal.show, .modal[style*='display: block']")
    ck("item19 改了没确认就切走 → 弹提醒", modal.count() >= 1)
    txt = modal.first.inner_text() if modal.count() else ""
    ck("item19 提醒里点名了**改了哪一样**（只说「有改动」等于让用户自己回去找）",
       "厂商" in txt, txt.replace("\n", " / ")[:120])
    ck("item19 文案承认改动会自动保存（不许写「不会生效」那种假话）",
       "自动保存" in txt and "不会生效" not in txt)

    # 「回去继续编辑」要**跳回模型服务页**
    pg.locator("#model-rail_dismiss").click()
    pg.wait_for_timeout(2500)
    ck("item19 「回去继续编辑」跳回了模型服务页",
       pg.eval_on_selector(".dsapp-rail-link.active",
                           "e => e.getAttribute('data-nav')") == "model")

    # 「先这样，稍后再说」只关掉提醒，不跳页
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    modal = pg.locator(".modal.show, .modal[style*='display: block']")
    ck("item19 再切走还会提醒（不是只提醒一次）", modal.count() >= 1)
    if modal.count():
        pg.locator("#model-rail_collapse").click()
        pg.wait_for_timeout(1200)
        ck("item19 「先这样」关掉提醒之后**留在原页**（不是被拽回模型页）",
           pg.eval_on_selector(".dsapp-rail-link.active",
                               "e => e.getAttribute('data-nav')") == "chat")

    # ---------- (e) 点「更新」之后小字要跟着变 ----------
    C.goto(pg, "model")
    pg.fill("#model-api_key", "sk-test-item19-not-a-real-key")
    pg.locator("#model-commit").click()
    pg.wait_for_timeout(4000)
    sub2 = pg.locator('.dsapp-rail-link[data-nav="model"] .dsapp-rail-sub')
    got = sub2.inner_text().strip()
    ck("item19 点完「更新」小字不再写「未配置」", got != "未配置", got)
    # ⚠️ 这一条是整条消息链路的验收：服务端 sendCustomMessage → app.js 改
    #    textContent。**不刷新页面**就能看到变化才算通 —— 刷新一下才变的话，
    #    用户嘴边那句就是"保存了但上面那行字不动"。
    pg.wait_for_timeout(500)

    # ---------- (f) 改完之后不再弹提醒（快照刷新了）----------
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    ck("item19 确认过之后再切走不再弹框（否则每次切页都弹，很快就没人看了）",
       pg.locator(".modal.show, .modal[style*='display: block']").count() == 0)
    # 别的页之间互切也不该弹（判的是"从模型页离开"，不是"切页"本身）
    C.goto(pg, "files")
    pg.wait_for_timeout(1500)
    ck("item19 别的页之间互切不弹（判据是离开模型页，不是任何一次切页）",
       pg.locator(".modal.show, .modal[style*='display: block']").count() == 0)

    pg.screenshot(path=C.OUT + "/model_page.png", full_page=True)
    b.close()

sys.exit(ck.done())
