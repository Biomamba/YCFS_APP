#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V15.12 诊断：**页面开着不动，它会不会自己重载**（只观察，不断言）。

为什么要有这一条：线上 `data/logs/auth.log` 里，uid=1（user1@example.com）
从 15:49 到 16:41 **每 ~2 分钟整页加载一次**，一直是同一对
「页面加载：cookie 非空 / on_login uid=1 reload=否」。人不会那么准点按 F5。

v15.9 的自愈（`www/app.js` 的 dsappHealStart）在**断线 20 秒后** fetch 探活，
探到了就 `location.reload()`。它的刹车是"3 分钟内最多 3 次"（DSAPP_HEAL_MAX /
DSAPP_HEAL_WINDOW_MS）—— **每 120 秒刷一次正好卡在这个窗口下面**（任一 3 分钟
窗口里只有 2 次），所以它能无限循环下去。这一条就是去量那个循环在不在。

跑法：
    bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1511r
    python3 tests/ui_v158/diag_keeplive.py [秒数]

⚠️ 只读：登录后什么都不点、什么都不发。
"""

import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8954/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1511r/app")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright         # noqa: E402
EMAIL = os.environ.get("DSAPP_DIAG_EMAIL", "user1@example.com")
PW = os.environ.get("DSAPP_DIAG_PW", "dsapp-probe-REDACTED")

URL = os.environ["DSAPP_TEST_URL"]
SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 420

T0 = time.time()


def stamp():
    return "%7.1fs" % (time.time() - T0)


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch(headless=True)
        pg = br.new_page(viewport={"width": 1440, "height": 900})

        pg.on("framenavigated",
              lambda f: print("%s  整页导航 → %s" % (stamp(), f.url[:90]))
              if f == pg.main_frame else None)
        pg.on("console", lambda m: print("%s  console.%s: %s"
                                         % (stamp(), m.type, m.text[:160])))
        pg.on("pageerror", lambda e: print("%s  ★pageerror: %s"
                                           % (stamp(), str(e)[:200])))
        pg.on("requestfailed", lambda r: print("%s  ✗请求失败 %s（%s）"
                                               % (stamp(), r.url[:80],
                                                  r.failure)))
        socks = []

        def on_ws(ws):
            socks.append(ws)
            print("%s  WS 打开 %s" % (stamp(), ws.url[:80]))
            ws.on("close", lambda _: print("%s  WS 关闭" % stamp()))
            ws.on("framereceived", lambda p: print("%s    ← %d 字节 %s"
                                                   % (stamp(), len(p),
                                                      p[:110])))
            ws.on("framesent", lambda p: print("%s    → %d 字节 %s"
                                               % (stamp(), len(p), p[:110])))
        pg.on("websocket", on_ws)

        # ⚠️ 不用 diag_wchcpu.login()：那个函数在等不到 .dsapp-shell 时会
        #    sys.exit —— 而**这里要量的恰恰是"它一直起不来"**。自己走一遍，
        #    失败也继续观察。
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-auth", timeout=90000)
        pg.wait_for_timeout(1500)
        if pg.locator("#welcome-go_login").count():
            pg.click("#welcome-go_login")
            pg.wait_for_timeout(800)
        pg.fill("#welcome-login_email", EMAIL)
        pg.fill("#welcome-login_password", PW)
        pg.click("#welcome-do_login")
        print("%s  == 已点登录，开始空转 %d 秒 ==" % (stamp(), SECS))
        pg.wait_for_timeout(SECS * 1000)
        print("%s  == 结束：共 %d 个 WS、%d 次导航 ==" % (stamp(), len(socks), 0))
        br.close()


if __name__ == "__main__":
    main()
