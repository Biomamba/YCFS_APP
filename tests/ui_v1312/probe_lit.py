# -*- coding: utf-8 -*-
"""V13.12 item 16 / 17 / 18：文献速递那三处改动的浏览器验收。

    bash tests/ui_v7/make_instance.sh 8913 /tmp/dsapp_v1312
    python3 tests/ui_v1312/probe_lit.py

  item 16  已关联的技能显示在最上方
  item 17  「看看会发什么」点了没反应 —— 它只**显示**提示词，不开始检索
  item 18  「还想让它注意什么」换成「告诉 AI 注意事项」：几个常用预设 + 自定义
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
    C.goto(pg, "文献速递")

    # ---------- item 16：勾上的排最上面 ----------
    rows = pg.eval_on_selector_all(
        "#lit-skills .shiny-options-group .checkbox",
        "els => els.map(e => ({"
        "  v: e.querySelector('input').value,"
        "  t: e.querySelector('label').innerText.trim(),"
        "  on: e.querySelector('input').checked}))")
    names = [r["t"] for r in rows]
    on = [r["t"] for r in rows if r["on"]]
    ck("item16 默认勾了 2 条", len(on) == 2, "勾了 %r" % on)
    ck("item16 勾上的排在最前", on and names[:len(on)] == on,
       "前 %d 条是 %r，勾的是 %r" % (len(on), names[:3], on))
    ck("item16 默认那两条确实在（academic-search / deeppapernote）",
       sorted(on) == ["academic-search", "deeppapernote"], on)

    # 勾一条原本在后面的，看它会不会被提到「已勾」那一组里
    idx = [i for i, r in enumerate(rows) if not r["on"]]
    target = rows[idx[-1]]["t"]
    pg.locator("#lit-skills .checkbox", has_text=target).first.locator(
        "input").check()
    pg.wait_for_timeout(2500)
    rows2 = pg.eval_on_selector_all(
        "#lit-skills .shiny-options-group .checkbox",
        "els => els.map(e => ({t: e.querySelector('label').innerText.trim(),"
        " on: e.querySelector('input').checked}))")
    names2 = [r["t"] for r in rows2]
    on2 = [r["t"] for r in rows2 if r["on"]]
    ck("item16 新勾的也被提到上面（%s）" % target,
       len(on2) == 3 and names2[:3] == on2, "前 3 条 %r" % names2[:3])
    ck("item16 一条都没丢", len(names2) == len(names),
       "%d → %d" % (len(names), len(names2)))
    ck("item16 勾选状态没被重画顶掉", len(on2) == 3, on2)

    # 全取消
    for r in rows2:
        if r["on"]:
            pg.locator("#lit-skills .checkbox", has_text=r["t"]).first.locator(
                "input").uncheck()
            pg.wait_for_timeout(600)
    pg.wait_for_timeout(2000)
    on3 = pg.eval_on_selector_all(
        "#lit-skills input[type=checkbox]",
        "els => els.filter(e => e.checked).map(e => e.value)")
    ck("item16 能全取消，不会自己弹回默认", len(on3) == 0, on3)

    # ---------- item 18：告诉 AI 注意事项 ----------
    lab = pg.locator("label[for='lit-extra']").first.inner_text().strip()
    ck("item18 标题是「告诉 AI 注意事项」", lab == "告诉 AI 注意事项", lab)
    presets = pg.eval_on_selector_all(
        "#lit-extra_presets .checkbox label",
        "els => els.map(e => e.innerText.trim())")
    ck("item18 有 5 条预设", len(presets) == 5, presets)
    ck("item18 预设默认都不勾",
       not pg.eval_on_selector("#lit-extra_presets input", "e => e.checked"))

    # ---------- item 17：看看会发什么 ----------
    box = pg.locator("#lit-peek_box")
    ck("item17 一开始没有预览卡片", box.count() == 0 or not box.inner_text().strip())
    pg.fill("#lit-kw", "肝癌\n免疫微环境")
    pg.wait_for_timeout(800)
    before = pg.evaluate("window.scrollY")
    pg.click("#lit-peek")
    pg.wait_for_timeout(3000)
    pre = pg.locator(".dsapp-lit-preview")
    ck("item17 预览卡片渲染出来了", pre.count() == 1)
    if pre.count():
        r = pre.bounding_box()
        vh = pg.evaluate("window.innerHeight")
        ck("item17 预览滚进了视野（y=%.0f, 视口高 %d, scrollY=%.0f）"
           % (r["y"], vh, pg.evaluate("window.scrollY")),
           -50 < r["y"] < vh, "y=%.0f" % r["y"])
        ck("item17 预览里有关键词", "肝癌" in pre.inner_text())
    # 再点一下不能关掉
    pg.click("#lit-peek")
    pg.wait_for_timeout(2000)
    ck("item17 再点一下不会把预览关掉",
       pg.locator(".dsapp-lit-preview").count() == 1)

    # 勾两条预设 + 写一句自定义，预览里都要有
    pg.locator("#lit-extra_presets .checkbox").nth(0).locator("input").check()
    pg.locator("#lit-extra_presets .checkbox").nth(2).locator("input").check()
    pg.fill("#lit-extra", "只看人的样本")
    pg.wait_for_timeout(2500)
    txt = pg.locator(".dsapp-lit-preview").inner_text()
    ck("item18 勾的预设进了提示词", presets[0] in txt and presets[2] in txt,
       presets[0] + " / " + presets[2])
    ck("item18 自定义那句也进了提示词", "只看人的样本" in txt)
    ck("item18 三条各占一行",
       ("  - %s\n" % presets[0]) in txt and ("  - %s" % presets[2]) in txt)

    # 关掉
    pg.click("#lit-peek_close")
    pg.wait_for_timeout(1200)
    ck("item17 ✕ 能关掉", pg.locator(".dsapp-lit-preview").count() == 0)

    # 没填关键词时点预览 → 提示语
    pg.fill("#lit-kw", "")
    pg.wait_for_timeout(800)
    pg.click("#lit-peek")
    pg.wait_for_timeout(1500)
    notes = pg.eval_on_selector_all(
        ".shiny-notification", "els => els.map(e => e.innerText)")
    ck("item17 没关键词时给提示", any("关键词" in n for n in notes), notes)

    pg.screenshot(path=C.OUT + "/lit_1618.png", full_page=True)
    b.close()

sys.exit(ck.done())
