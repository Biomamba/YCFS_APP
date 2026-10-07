# -*- coding: utf-8 -*-
"""探针：对着**线上库的副本**登录一个平台管理员，逐页找整页 "An error has occurred"。

不是验收脚本，是一次性诊断。它只打印「哪一页文字多少、有没有整页报错、
console/pageerror 里有什么」，**不打印任何用户数据**（截断到 200 字）。

用法：
    /home/biomamba/miniconda3/bin/python tests/ui_v1310/probe_clone.py
"""
import sys

from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8902/"
EMAIL = "probe_admin@example.com"
PW = "Probe-9210-pw"
OUT = "/tmp/dsapp_ui_v1310"
PAGES = ["chat", "tasks", "files", "skills", "envs", "settings", "admin",
         "htadmin"]

ERRS = []


def main():
    import os
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        b = p.chromium.launch(headless=True)
        pg = b.new_page(viewport={"width": 1600, "height": 950})
        pg.on("console", lambda m: ERRS.append("console[%s]: %s"
                                               % (m.type, m.text[:300]))
              if m.type == "error" else None)
        pg.on("pageerror", lambda e: ERRS.append("pageerror: %s" % str(e)[:300]))

        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-auth", timeout=90000)
        pg.wait_for_timeout(2000)
        print("登录页出来了", flush=True)

        # 登录表单的 id 见 mod_welcome.R / logins.R
        for sel, val in [("#welcome-login_email", EMAIL), ("#welcome-login_password", PW)]:
            if pg.locator(sel).count():
                pg.fill(sel, val)
            else:
                print("找不到 %s，可用 id：" % sel, flush=True)
                print(pg.eval_on_selector_all(
                    "input", "els => els.map(e => e.id)"), flush=True)
        pg.click("#welcome-do_login")
        pg.wait_for_timeout(6000)
        print("点完登录，页面文字：", flush=True)
        print(pg.inner_text("body")[:800], flush=True)
        pg.screenshot(path=OUT + "/clone_login.png", full_page=True)
        # 用户须知闸门（新账号必过，见 tests/ui_v139/_common.py 的注释）
        for _ in range(40):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
            if pg.locator("#tos_gate-do_agree").count():
                c = pg.locator("#tos_gate-agree")
                if c.count() and not c.is_checked():
                    c.check()
                pg.click("#tos_gate-do_agree")
                pg.wait_for_timeout(3000)
        pg.wait_for_selector(".dsapp-shell", timeout=60000)
        print("登进去了", flush=True)
        pg.wait_for_timeout(3000)

        results = {}
        for name in PAGES:
            pg.evaluate("(v) => window.dsappNav && window.dsappNav(v)", name)
            pg.wait_for_timeout(3500)
            txt = pg.inner_text("body")
            results[name] = txt
            bad = "An error has occurred" in txt
            print("%-9s %6d 字   整页报错=%-5s %s"
                  % (name, len(txt), bad, txt[:150].replace("\n", " / ")
                     if bad else ""), flush=True)
            pg.screenshot(path="%s/clone_%s.png" % (OUT, name), full_page=True)

        # 后台页：把每个筛选/动作都点一遍
        pg.evaluate("(v) => window.dsappNav && window.dsappNav(v)", "htadmin")
        pg.wait_for_timeout(3000)
        for val in ["7", "90", "365", "30"]:
            try:
                pg.select_option("#htadmin-days", val)
                pg.wait_for_timeout(2500)
            except Exception as e:
                print("days=%s 失败 %s" % (val, str(e)[:150]), flush=True)
            t = pg.inner_text("body")
            print("后台 days=%-4s %6d 字 整页报错=%s"
                  % (val, len(t), "An error has occurred" in t), flush=True)

        rows = pg.locator("#htadmin-tbl tbody tr")
        print("后台表格行数 %d" % rows.count(), flush=True)
        if rows.count():
            rows.first.click()
            pg.wait_for_timeout(3000)
            t = pg.inner_text("body")
            print("选中一行后 %d 字 整页报错=%s"
                  % (len(t), "An error has occurred" in t), flush=True)
            pg.screenshot(path=OUT + "/clone_htadmin_sel.png", full_page=True)

        # 管理页也点一遍
        pg.evaluate("(v) => window.dsappNav && window.dsappNav(v)", "admin")
        pg.wait_for_timeout(3000)
        arows = pg.locator("#admin-tbl tbody tr")
        print("管理页表格行数 %d" % arows.count(), flush=True)
        pg.screenshot(path=OUT + "/clone_admin.png", full_page=True)

        b.close()

    print("\n=== console / pageerror ===")
    for e in set(ERRS):
        print(" -", e)
    if not ERRS:
        print(" （无）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
