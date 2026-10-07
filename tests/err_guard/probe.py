#!/usr/bin/env python3
"""看三件事：socket 断没断、页面还听不听点击、控制台报了什么。"""
import sys
from playwright.sync_api import sync_playwright

URL, TAG = sys.argv[1], sys.argv[2]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    ev = []
    pg.on("pageerror", lambda e: ev.append("pageerror: " + str(e)[:120]))
    pg.on("console", lambda m: ev.append("console.%s: %s" % (m.type, m.text[:160]))
          if m.type in ("error",) else None)
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_timeout(2000)
    # 记录 socket 断开事件
    pg.evaluate("""() => { window.__disc = [];
        $(document).on('shiny:disconnected', () => window.__disc.push(Date.now()));
        $(document).on('shiny:connected',    () => window.__disc.push('conn')); }""")
    pg.wait_for_timeout(18000)
    disc = pg.evaluate("() => window.__disc")
    conn = pg.evaluate("() => (window.Shiny && Shiny.shinyapp) ? Shiny.shinyapp.isConnected() : null")
    print("%s 15 秒后：isConnected=%s  断开事件=%s" % (TAG, conn, disc[:6]))
    # 还能不能收到点击
    try:
        pg.click("#btn", timeout=5000)
        print("%s 点击已发出" % TAG)
    except Exception as e:
        print("%s ★点击失败★ %s" % (TAG, str(e)[:120]))
    pg.wait_for_timeout(3000)
    for e in ev[:6]:
        print("   " + e)
    b.close()
