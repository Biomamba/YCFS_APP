#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V15.13 诊断：**什么都不干的时候，服务端还在往浏览器灌东西吗**（只读）

用户原话（2026-10-03）：「你看一主账号到底为什么频繁断联，并且做任何操作都很卡」。

前面量到的是**生成期间**的流量（probe_streambytes.py：7 KB 的回复推 193 KB）。
但「做什么都卡」是**全天**的感受，不只是生成那几十秒。所以要把另一种可能
分出来：**页面开着、用户不动，服务端是不是一直在发**。

为什么要拿**线上那份真库**：这些量取决于**那条对话有多长**（正文/思维链的
字符数、条数）。造出来的数据量不出用户真正撞上的那一包。真库里的对话是
74 条 / 42 万字这种量级，渲染出来是 MB 级 HTML。

⚠️ 走 sqlite3 的 **backup API**，别用 `cp`：库跑在 WAL 模式，`cp` 只拷主文件 =
   一个**旧快照**（实测少 27 条、不报错、行数看着完全合理）。见 README。
⚠️ 只读：不注册、不发消息、不写库。改密码只改**副本**那份，线上一个字节不动。
⚠️ 要点：量的是「点开一个对话、等它画完、然后**完全不动**」之后的那一段。
   所以每段先等气泡数连着三拍不变（= 画完了），再开始计数。

跑法：
    bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1513r
    sqlite3 <线上库> ".backup '/tmp/dsapp_v1513r/data/dsapp.sqlite3'"
    # 把副本里 uid=1 的密码改成已知值（命令见 README 的 V15.12 一节）
    python3 tests/ui_v158/probe_idlebytes.py
    DSAPP_IDLE_S=20 python3 tests/ui_v158/probe_idlebytes.py    # 每段量多久
"""
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8954/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1513r/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1513")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal                   # noqa: E402

URL = os.environ["DSAPP_TEST_URL"]
OUT = os.environ["DSAPP_TEST_OUT"]
os.makedirs(OUT, exist_ok=True)

EMAIL = os.environ.get("DSAPP_DIAG_EMAIL", "user1@example.com")
PW = os.environ.get("DSAPP_DIAG_PW", "dsapp-probe-REDACTED")
IDLE_S = float(os.environ.get("DSAPP_IDLE_S", "20"))
MAX_SESS = int(os.environ.get("DSAPP_MAX_SESS", "8"))


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def login(page):
    """照抄 diag_wchcpu.py —— 这套账号的入口多一道欢迎页/条款闸。"""
    page.goto(URL, wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-auth", timeout=90000)
    page.wait_for_timeout(1500)
    if page.locator("#welcome-go_login").count():
        page.click("#welcome-go_login")
        page.wait_for_timeout(800)
    page.fill("#welcome-login_email", EMAIL)
    page.fill("#welcome-login_password", PW)
    page.click("#welcome-do_login")
    for _ in range(120):
        page.wait_for_timeout(1000)
        if page.locator(".dsapp-shell").count():
            return
        if page.locator("#tos_gate-do_agree").count():
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            page.wait_for_timeout(3000)
    page.screenshot(path=OUT + "/00_login_failed.png", full_page=True)
    sys.exit("登录没进主界面，页面文字：\n%s" % page.inner_text("body")[:800])


def main():
    recv = {"n": 0, "b": 0}
    navs = []
    with sync_playwright() as pw:
        br = pw.chromium.launch(headless=True)
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        pg.on("load", lambda _: navs.append(time.time()))
        pg.on("pageerror", lambda e: say("  ★ pageerror: %s" % str(e)[:200]))

        cdp = ctx.new_cdp_session(pg)
        cdp.send("Network.enable")
        cdp.on("Network.webSocketFrameReceived",
               lambda p: (recv.__setitem__("n", recv["n"] + 1),
                          recv.__setitem__("b", recv["b"] + len(
                              p.get("response", {}).get("payloadData", "")))))

        login(pg)
        say("== 登录成功（%s）==" % EMAIL)
        pg.wait_for_timeout(3000)
        ensure_no_modal(pg)

        titles = pg.eval_on_selector_all(
            ".dsapp-sess-title", "els => els.map(e => e.innerText.trim())")
        say("会话 %d 个，量前 %d 个" % (len(titles), min(len(titles), MAX_SESS)))
        say("")
        say("%-4s %-26s %9s %8s %10s %9s" %
            ("#", "标题", "气泡", "outerKB", "空闲收B", "折KB/s"))
        rows = []
        for i in range(min(len(titles), MAX_SESS)):
            item = pg.locator(".dsapp-sess").nth(i)
            item.scroll_into_view_if_needed()
            item.click()
            # 等画完：气泡数连着三拍不变（最长 90 秒）
            last, stable, waited = -1, 0, 0.0
            while waited < 90:
                pg.wait_for_timeout(500)
                waited += 0.5
                n = pg.eval_on_selector_all(".dsapp-msg", "e => e.length")
                if n == last and n > 0:
                    stable += 1
                    if stable >= 3:
                        break
                else:
                    stable = 0
                last = n
            # ---- 这一段才是重点：完全不动，只数字节 ----
            pg.wait_for_timeout(1000)          # 让上一次 flush 落干净
            b0, n0, nav0 = recv["b"], recv["n"], len(navs)
            t0 = time.time()
            while time.time() - t0 < IDLE_S:
                pg.wait_for_timeout(500)
            db = recv["b"] - b0
            dn = recv["n"] - n0
            info = pg.evaluate("""() => ({
              msgs: document.querySelectorAll('.dsapp-msg').length,
              kb: Math.round(document.documentElement.outerHTML.length / 1024)})""")
            say("%-4d %-26s %9d %8d %10d %9.2f%s" %
                (i, titles[i][:24], info["msgs"], info["kb"], db,
                 db / 1024.0 / IDLE_S,
                 "  ★整页重载" if len(navs) > nav0 else ""))
            rows.append((titles[i], db, dn))
        say("")
        worst = max(rows, key=lambda r: r[1]) if rows else None
        if worst:
            say("最重的一段：%s —— %.1f 秒里收了 %d B（%d 帧）"
                % (worst[0][:30], IDLE_S, worst[1], worst[2]))
        say("导航（整页重载）次数：%d" % len(navs))
        br.close()


if __name__ == "__main__":
    main()
