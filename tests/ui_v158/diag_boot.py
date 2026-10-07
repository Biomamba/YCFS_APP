#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：注册完之后那一跳到底卡在哪儿。

probe_switch 连着两跑都停在「注册没进主界面（页面文字 0 字）」，而截图是一片
纯色空页。空页 = Shiny 还没连上（UI 是连上之后才画的），所以要么是慢、要么是
连不上。这个脚本把 console / pageerror / 请求失败 / 每秒的 body 长度都打出来，
把"慢"和"坏"分开。
"""
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8951/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                            # noqa: E402
from playwright.sync_api import sync_playwright                 # noqa: E402

T0 = time.time()


def say(*a):
    print("[%7.2fs] %s" % (time.time() - T0, " ".join(str(x) for x in a)),
          flush=True)


email = "v158d_%s@example.com" % str(int(time.time()))[-6:]

with sync_playwright() as pw:
    browser = pw.chromium.launch()
    page = browser.new_context(viewport={"width": 1440, "height": 900}).new_page()
    page.on("console", lambda m: say("  console.%s: %s" % (m.type, m.text[:200])))
    page.on("pageerror", lambda e: say("  **pageerror**: %s" % str(e)[:300]))
    page.on("requestfailed",
            lambda r: say("  请求失败: %s  %s" % (r.url[:90], r.failure)))
    page.on("response",
            lambda r: say("  HTTP %s %s" % (r.status, r.url[:90]))
            if r.status >= 400 or "/websocket" in r.url or "sockjs" in r.url.lower()
            else None)

    page.goto(C.URL, wait_until="domcontentloaded")
    say("goto 完，等 .dsapp-auth")
    page.wait_for_selector(".dsapp-auth", timeout=60000)
    say("登录页出来了")

    if page.locator("#welcome-nickname").count() == 0:
        page.click("#welcome-go_register")
        page.wait_for_selector("#welcome-nickname", timeout=15000)
    page.fill("#welcome-nickname", "V15测试")
    page.fill("#welcome-email", email)
    page.fill("#welcome-phone", "13800000008")
    page.fill("#welcome-field", "转录组")
    page.fill("#welcome-password", C.PW)
    cb = page.locator("#welcome-tos_agree")
    if cb.count() and not cb.is_checked():
        cb.check()
    say("点注册（%s）" % email)
    page.click("#welcome-do_register")
    page.wait_for_selector("#welcome-enter_app", timeout=60000)
    say("恢复码页出来了，点进应用")
    page.click("#welcome-enter_app")

    # 之后一秒一报：body 长度 + shell 在不在 + 有没有遮罩
    for i in range(60):
        try:
            st = page.evaluate("""() => ({
                 txt: (document.body.innerText||"").length,
                 html: (document.body.innerHTML||"").length,
                 shell: !!document.querySelector(".dsapp-shell"),
                 auth: !!document.querySelector(".dsapp-auth"),
                 tos: !!document.querySelector("#tos_gate-do_agree"),
                 off: (document.querySelector("#dsapp-offline")||{}).dataset ?
                      (document.querySelector("#dsapp-offline")||{}).dataset.kind : null,
                 url: location.href})""")
        except Exception as e:
            say("  evaluate 抛了：%s" % str(e).splitlines()[0])
            time.sleep(1)
            continue
        say("t+%2ds txt=%5d html=%6d shell=%s auth=%s tos=%s off=%s"
            % (i, st["txt"], st["html"], st["shell"], st["auth"], st["tos"],
               st["off"]))
        if st["shell"]:
            say("**进主界面了**")
            break
        if st["tos"]:
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            say("  勾了用户须知闸门")
            time.sleep(3)
            continue
        time.sleep(1)

    page.screenshot(path=C.OUT + "/diag_boot.png", full_page=True)
    say("截图 %s/diag_boot.png" % C.OUT)
    browser.close()
