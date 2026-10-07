# -*- coding: utf-8 -*-
"""探针：后台页（htadmin）到底会不会整页 "An error has occurred"。

不是验收脚本。它只做两件事：
  1. 注册第一个账号（= 平台管理员），依次切到每一页，把 body 文本里
     出现 "An error has occurred" / "错误" 的页记下来；
  2. 专门在后台页上停一会儿、点几个筛选控件，看有没有延迟抛出来的错。

用法：
    /home/biomamba/miniconda3/bin/python tests/ui_v1310/probe_err.py
"""
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import _common as C  # noqa: E402

ERRS = []
TEXTS = {}


def main():
    with sync_playwright() as p:
        b = p.chromium.launch(headless=True)
        pg = b.new_page(viewport={"width": 1600, "height": 950})

        def on_console(m):
            if m.type in ("error",):
                ERRS.append("console: " + m.text[:400])

        def on_pageerror(e):
            ERRS.append("pageerror: " + str(e)[:400])

        pg.on("console", on_console)
        pg.on("pageerror", on_pageerror)

        C.enter_app(pg)
        C.seed_or_die(C.EMAIL)
        print("=== 注册成功，账号 %s ===" % C.EMAIL, flush=True)

        for name in ["chat", "tasks", "files", "skills", "envs", "settings",
                     "admin", "htadmin"]:
            C.goto(pg, name, wait=4000)
            txt = pg.inner_text("body")
            TEXTS[name] = txt
            bad = "An error has occurred" in txt
            print("%-9s 文字 %6d 字   整页报错=%s" % (name, len(txt), bad),
                  flush=True)
            if bad:
                print("    ↓↓↓ 页面内容 ↓↓↓", flush=True)
                print(txt[:1200], flush=True)
            pg.screenshot(path="%s/probe_%s.png" % (C.OUT, name),
                          full_page=True)

        # 后台页：跟几个控件交互，看有没有延迟抛错
        C.goto(pg, "htadmin", wait=3000)
        for sel, val in [("#htadmin-days", "7"), ("#htadmin-days", "90"),
                         ("#htadmin-days", "30")]:
            try:
                pg.select_option(sel, val)
                pg.wait_for_timeout(2500)
            except Exception as e:
                print("选 %s=%s 失败：%s" % (sel, val, str(e)[:200]), flush=True)
            t = pg.inner_text("body")
            print("后台页 days=%s 后：%d 字，整页报错=%s"
                  % (val, len(t), "An error has occurred" in t), flush=True)
            TEXTS["htadmin_" + val] = t

        # 选一行，看 limits 卡
        try:
            rows = pg.locator("#htadmin-tbl tbody tr")
            print("后台表格行数：%d" % rows.count(), flush=True)
            if rows.count():
                rows.first.click()
                pg.wait_for_timeout(2500)
                t = pg.inner_text("body")
                print("选中一行后：%d 字，整页报错=%s"
                      % (len(t), "An error has occurred" in t), flush=True)
                TEXTS["htadmin_row"] = t
        except Exception as e:
            print("点行失败：%s" % str(e)[:300], flush=True)

        pg.screenshot(path=C.OUT + "/probe_htadmin_after.png", full_page=True)
        b.close()

    print("\n=== 捕获到的 console/page 错误 ===")
    for e in ERRS:
        print(" -", e)
    if not ERRS:
        print(" （无）")

    print("\n=== 哪些页的文本里有 'An error has occurred' ===")
    hit = [k for k, v in TEXTS.items() if "An error has occurred" in v]
    print(hit if hit else " （没有）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
