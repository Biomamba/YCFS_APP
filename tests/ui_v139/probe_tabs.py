# -*- coding: utf-8 -*-
"""一次性探针：设置页那四个页签，各自到底量到了哪一块。

    /home/biomamba/miniconda3/bin/python tests/ui_v139/probe_tabs.py

起因：v139.py 的 item 11 报「界面/执行/账号三栏底部都没有『保存并开始使用』」，
而同一条东西在 tests/ui_v135/settings.py 里是绿的 —— 那边数的是**可见卡片**，
这边读的是 `.dsapp-page .tab-pane.active` 的文字。两个说法对不上，说明至少
一处量错了地方。这里把"点了哪个 nav-link、命中几个 pane、pane 的 data-value
是什么、文字长什么样"一次全打出来。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import *            # noqa: F401,F403
from _common import EMAIL, URL   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402


with sync_playwright() as pw:
    br = pw.chromium.launch(headless=True)
    pg = br.new_page(viewport={"width": 1600, "height": 950})
    pg.goto(URL, wait_until="domcontentloaded")
    enter_app(pg)
    seed_or_die(EMAIL)
    goto(pg, "settings", wait=3500)
    pg.wait_for_timeout(2000)

    print("  .dsapp-page 个数 = %d" % pg.locator(".dsapp-page").count(), flush=True)
    print("  .dsapp-page .nav-link = %s" % pg.eval_on_selector_all(
        ".dsapp-page .nav-link",
        "els => els.map(e => e.innerText.trim() + '|' + (e.getAttribute('data-value')||'?'))"),
        flush=True)

    for t in ("界面", "执行", "账号", "帮助"):
        loc = pg.locator(".dsapp-page .nav-link").filter(has_text=t)
        print("\n-- 点「%s」：nav-link 命中 %d 个 --" % (t, loc.count()), flush=True)
        try:
            loc.first.click(timeout=8000)
        except Exception as e:
            print("   点不动：%s" % str(e)[:150], flush=True)
        pg.wait_for_timeout(2000)
        panes = pg.eval_on_selector_all(
            ".dsapp-page .tab-pane",
            "els => els.map(e => [e.getAttribute('data-value'), e.className,"
            " Math.round(e.getBoundingClientRect().width)])")
        print("   .dsapp-page 下的 pane：%s" % panes, flush=True)
        act = pg.eval_on_selector_all(
            ".dsapp-page .tab-pane.active",
            "els => els.map(e => [e.getAttribute('data-value'),"
            " Math.round(e.getBoundingClientRect().width), e.innerText.length])")
        print("   其中 active 的：%s" % act, flush=True)
        txt = pg.locator(".dsapp-page .tab-pane.active").first.inner_text() \
            if pg.locator(".dsapp-page .tab-pane.active").count() else ""
        print("   active pane 的文字 %d 字：%r" % (len(txt), txt[:300]), flush=True)
        print("   文字里有「保存」吗：%s" % ("保存" in txt), flush=True)
        cards = pg.eval_on_selector_all(
            ".dsapp-page .card",
            "els => els.filter(e => e.getBoundingClientRect().width > 0)"
            ".map(e => (e.querySelector('.card-header')||{}).innerText || '')")
        print("   可见卡片的表头：%s" % cards, flush=True)

    pg.screenshot(path="/tmp/dsapp_ui_v139/probe_tabs.png", full_page=True)
    br.close()
