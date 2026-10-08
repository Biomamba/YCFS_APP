#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V15.12 诊断：**user1@example.com 那个账号的页面为什么崩**。

用户原话（2026-10-03，V15.11 上线之后）：
    「Biomamba_ceshi 现在正常了，但是 user1@example.com 这个账号的页面
      还是崩溃的，请保证所有账号都不会崩溃」。

⚠️ 和 `probe_crash.py` 的关系：那一条量的是**渲染层**（喂一条 18 KB 的回复，
   看 longtask / 堆 / 往返耗时），用的是**造出来的**数据；这一条不一样 ——
   它把**线上那份真库**拷进实例，用**那个账号本人**登录，一个会话一个会话地
   打开，量的是"用户真正会撞上的那一包"。

只诊断，不断言（同 diag_* 的规矩）：打印一张表，人在上面读。

跑法：
    bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1511r
    # 把线上库拷进去、把 uid=1 的密码改成已知值（见 README「V15.12」一节）
    python3 tests/ui_v158/diag_wchcpu.py

⚠️ 这个脚本**只读**：不注册、不发消息、不写库。登录用的是实例副本里那个
   被改过密码的账号，线上那份库一个字节都不动。
"""

import json
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8954/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1511r/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1512")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal                   # noqa: E402

URL = os.environ["DSAPP_TEST_URL"]
OUT = os.environ["DSAPP_TEST_OUT"]
os.makedirs(OUT, exist_ok=True)

EMAIL = os.environ.get("DSAPP_DIAG_EMAIL", "user1@example.com")
PW = os.environ.get("DSAPP_DIAG_PW", "dsapp-probe-REDACTED")

# 采集器：装一次，之后随时读。和 probe_crash.py 同一套口径 ——
# PerformanceObserver 收 longtask、rAF 采帧间隔、performance.memory 看堆。
# ⚠️ 取不到的记 None，**不要**补 0（"这家不报"和"真的是 0"是两回事）。
_WATCH = r"""
() => {
  window.__lt = {n: 0, ms: 0, max: 0};
  window.__frames = {n: 0, last: performance.now(), max: 0};
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) {
        window.__lt.n += 1;
        window.__lt.ms += e.duration;
        if (e.duration > window.__lt.max) window.__lt.max = e.duration;
      }
    }).observe({entryTypes: ["longtask"]});
  } catch (e) { window.__lt = null; }
  const tick = (t) => {
    const d = t - window.__frames.last;
    if (d > window.__frames.max) window.__frames.max = d;
    window.__frames.last = t; window.__frames.n += 1;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  window.__snap = () => ({
    lt: window.__lt,
    frames: {n: window.__frames.n, max: window.__frames.max},
    nodes: document.getElementsByTagName("*").length,
    heap: (performance.memory ? performance.memory.usedJSHeapSize : null),
    html_kb: Math.round(document.documentElement.outerHTML.length / 1024),
    msgs: document.querySelectorAll(".dsapp-msg").length,
    reason: document.querySelectorAll(".dsapp-reason-body").length,
    reason_chars: Array.from(document.querySelectorAll(".dsapp-reason-body"))
                       .reduce((a, e) => a + (e.textContent || "").length, 0),
  });
  window.__reset = () => {
    window.__lt = {n: 0, ms: 0, max: 0};
    window.__frames = {n: 0, last: performance.now(), max: 0};
  };
}
"""


def login(page):
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
            break
        if page.locator("#tos_gate-do_agree").count():
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            page.wait_for_timeout(3000)
    if not page.locator(".dsapp-shell").count():
        page.screenshot(path=OUT + "/00_login_failed.png", full_page=True)
        sys.exit("登录没进主界面，页面文字：\n%s" % page.inner_text("body")[:800])


def walk_pages(pg, events):
    """逐页走一遍（含**后台管理**这一页）—— 这个账号是唯一一个
    `admin_scope='platform'` 的管理员，而普通账号（Biomamba_ceshi）看不到
    那几页。差别要是在页面上，就得先把每一页都打开量一遍。"""
    import _common as C
    print("\n%-14s %7s %8s %9s %8s %9s %9s" %
          ("页面", "节点", "堆MB", "阻塞ms", "最长ms", "outerKB", "耗时s"))
    for v in C.PAGES:
        pg.evaluate("() => window.__reset()")
        t0 = time.time()
        pg.evaluate("(v) => window.dsappNav && window.dsappNav(v)", v)
        pg.wait_for_timeout(4000)
        dt = time.time() - t0
        s = pg.evaluate("() => window.__snap()")
        print("%-14s %7d %8.1f %9.0f %8.0f %9d %9.1f" %
              (v, s["nodes"], (s["heap"] or 0) / 1048576,
               s["lt"]["ms"] if s["lt"] else -1,
               s["lt"]["max"] if s["lt"] else -1, s["html_kb"], dt))
        if events["crash"]:
            print("   ★★ 走到 %s 这一页时渲染进程崩了" % v)
            break
        if events["pageerror"]:
            print("   ★ pageerror：%s" % events["pageerror"][-1][:200])


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "sessions"
    events = {"crash": [], "pageerror": [], "console_error": [], "reload": []}
    with sync_playwright() as pw:
        br = pw.chromium.launch(headless=True,
                                args=["--enable-precise-memory-info"])
        pg = br.new_page(viewport={"width": 1440, "height": 900})
        pg.on("crash", lambda _: events["crash"].append(time.time()))
        pg.on("pageerror", lambda e: events["pageerror"].append(str(e)[:300]))
        pg.on("console", lambda m: events["console_error"].append(m.text[:300])
              if m.type == "error" else None)
        pg.on("load", lambda _: events["reload"].append(time.time()))
        # ⚠️ 必须包成 IIFE。写成裸箭头函数的话 add_init_script 只是把它**求值**
        #    一下就完事（表达式语句），什么都没装上 —— 而报错要等到第一次
        #    `window.__snap is not a function` 才出现，看着像"探针写错了"。
        pg.add_init_script("(%s)()" % _WATCH)

        login(pg)
        print("== 登录成功 ==")
        ensure_no_modal(pg)

        if mode == "pages":
            walk_pages(pg, events)
            pg.screenshot(path=OUT + "/02_pages.png", full_page=False)
            print("\n崩溃 %d 次 / pageerror %d 条 / console.error %d 条"
                  % (len(events["crash"]), len(events["pageerror"]),
                     len(events["console_error"])))
            for e in events["pageerror"][:10]:
                print("  pageerror:", e)
            for e in events["console_error"][:10]:
                print("  console.error:", e)
            br.close()
            return

        # 会话列表：只读标题，不点开 —— 先看**首屏**本身有多重
        pg.wait_for_timeout(3000)
        titles = pg.eval_on_selector_all(
            ".dsapp-sess-title", "els => els.map(e => e.innerText.trim())")
        s0 = pg.evaluate("() => window.__snap()")
        print("首屏：DOM %s 节点 / 堆 %.1f MB / outerHTML %s KB / JS 报错 %d"
              % (s0["nodes"], (s0["heap"] or 0) / 1048576, s0["html_kb"],
                 len(events["pageerror"])))
        print("会话 %d 个" % len(titles))

        print("\n%-4s %-30s %7s %8s %9s %8s %9s %7s" %
              ("#", "标题", "节点", "堆MB", "阻塞ms", "最长ms", "推理字", "气泡"))
        rows = []
        for i in range(len(titles)):
            item = pg.locator(".dsapp-sess").nth(i)
            item.scroll_into_view_if_needed()
            pg.evaluate("() => window.__reset()")
            t0 = time.time()
            item.click()
            # 等历史落定：气泡数连续两拍不变，最长 60 秒
            last, stable, waited = -1, 0, 0
            while waited < 60:
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
            dt = time.time() - t0
            s = pg.evaluate("() => window.__snap()")
            rows.append((i, titles[i], s))
            print("%-4d %-30s %7d %8.1f %9.0f %8.0f %9d %7d   (%.1fs)"
                  % (i, titles[i][:30], s["nodes"],
                     (s["heap"] or 0) / 1048576, s["lt"]["ms"] if s["lt"] else -1,
                     s["lt"]["max"] if s["lt"] else -1,
                     s["reason_chars"], s["msgs"], dt))
            if events["crash"]:
                print("   ★★ 浏览器渲染进程崩了（page.on('crash')）")
                break

        pg.screenshot(path=OUT + "/01_last_session.png", full_page=False)
        print("\n== 汇总 ==")
        print("崩溃 %d 次 / pageerror %d 条 / console.error %d 条 / load %d 次"
              % (len(events["crash"]), len(events["pageerror"]),
                 len(events["console_error"]), len(events["reload"])))
        for e in events["pageerror"][:10]:
            print("  pageerror:", e)
        for e in events["console_error"][:10]:
            print("  console.error:", e)
        with open(OUT + "/diag_wchcpu.json", "w") as f:
            json.dump({"rows": [[r[0], r[1], r[2]] for r in rows],
                       "events": {k: len(v) for k, v in events.items()},
                       "pageerrors": events["pageerror"][:20]}, f,
                      ensure_ascii=False, indent=1)
        br.close()


if __name__ == "__main__":
    main()
