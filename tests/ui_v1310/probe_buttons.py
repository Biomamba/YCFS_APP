# -*- coding: utf-8 -*-
"""探针：在**线上库副本**上把后台页/管理页的每个按钮都点一遍，找整页报错。

不是验收脚本。只打印「点了什么、页面有没有变成整页报错、console 有什么」。
破坏性动作（删除用户）**跳过**，它要的是"有没有整页炸"，不是"删得对不对"。
"""
import sys

from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8902/"
EMAIL = "probe_admin@example.com"
PW = "Probe-9210-pw"
OUT = "/tmp/dsapp_ui_v1310"

ERRS = []


def bad(pg):
    try:
        return "An error has occurred" in pg.inner_text("body")
    except Exception:
        return "??"


def nav(pg, v):
    pg.evaluate("(x) => window.dsappNav && window.dsappNav(x)", v)
    pg.wait_for_timeout(2500)


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
        pg.wait_for_timeout(1500)
        pg.fill("#welcome-login_email", EMAIL)
        pg.fill("#welcome-login_password", PW)
        pg.click("#welcome-do_login")
        for _ in range(40):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
        pg.wait_for_timeout(2500)
        print("登入完成", flush=True)

        # ---- 后台页 ----
        nav(pg, "htadmin")
        rows = pg.locator("#htadmin-tbl tbody tr")
        print("后台表格 %d 行" % rows.count(), flush=True)
        if rows.count():
            rows.first.click()
            pg.wait_for_timeout(2500)

        def click(sel, label, wait=2500, shot=True):
            if pg.locator(sel).count() == 0:
                print("  · %-16s 按钮不存在（可能是权限/条件没到）" % label,
                      flush=True)
                return
            try:
                pg.click(sel, timeout=8000)
            except Exception as e:
                print("  · %-16s 点不动：%s" % (label, str(e)[:120]), flush=True)
                return
            pg.wait_for_timeout(wait)
            b_ = bad(pg)
            print("  · %-16s 整页报错=%s" % (label, b_), flush=True)
            if b_:
                print(pg.inner_text("body")[:600], flush=True)
            if shot:
                pg.screenshot(path="%s/btn_%s.png" % (OUT, label), full_page=True)

        # 资源限制
        click("#htadmin-save_limits", "保存资源上限")
        click("#htadmin-clear_limits", "恢复平台默认")

        # 停用 / 启用（第一次停用、第二次启用回来）
        click("#htadmin-toggle", "停用")
        click("#htadmin-toggle", "启用回来")

        # 更改权限 → 弹窗 → 取消
        click("#htadmin-set_scope", "更改权限", shot=False)
        if pg.locator("#htadmin-confirm_scope").count():
            pg.click("#htadmin-cancel") if pg.locator("#htadmin-cancel").count() \
                else pg.keyboard.press("Escape")
            pg.wait_for_timeout(1200)
            print("  · 更改权限弹窗 已关", flush=True)

        # 重置密码 → 弹窗 → 取消
        click("#htadmin-reset_pw", "重置密码", shot=False)
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(1200)

        # 添加用户 → 弹窗 → 真建一个再停用它
        click("#htadmin-add", "添加用户", shot=False)
        if pg.locator("#htadmin-new_email").count():
            pg.fill("#htadmin-new_nick", "探针新账号")
            pg.fill("#htadmin-new_email", "probe_new_%d@example.com"
                    % (pg.evaluate("Date.now()") % 100000))
            pg.fill("#htadmin-new_pw", "Probe-new-pw-1")
            pg.fill("#htadmin-new_field", "探针")
            pg.click("#htadmin-confirm_add")
            pg.wait_for_timeout(4000)
            print("  · 建账号后 整页报错=%s" % bad(pg), flush=True)
            t = pg.inner_text("body")
            for ln in t.split("\n"):
                if "已创建" in ln or "没设上" in ln:
                    print("      →", ln.strip(), flush=True)
        pg.screenshot(path=OUT + "/btn_after_add.png", full_page=True)

        # ---- 管理页 ----
        nav(pg, "admin")
        arows = pg.locator("#admin-tbl tbody tr")
        print("管理页表格 %d 行" % arows.count(), flush=True)
        if arows.count():
            arows.first.click()
            pg.wait_for_timeout(2500)
        # ⚠️ V13.12 item 3：「设置配额」和「资源上限」两个按钮合并成了
        #    一个 `#admin-set_quota_limits`（「配额与资源上限」）。这里跟着改，
        #    否则这一步会红 —— 而那和被测的功能没有关系。
        for sel, label in [("#admin-toggle", "停用/启用"),
                           ("#admin-set_quota_limits", "配额与资源上限"),
                           ("#admin-reset_pw", "重置密码"),
                           ("#admin-set_email", "改邮箱"),
                           ("#admin-reset_token", "重置恢复码")]:
            click(sel, "admin:" + label, wait=2000, shot=False)
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(1000)

        nav(pg, "settings")
        pg.wait_for_timeout(2000)
        print("设置页 整页报错=%s" % bad(pg), flush=True)

        b.close()

    print("\n=== console / pageerror ===")
    for e in sorted(set(ERRS)):
        print(" -", e)
    if not ERRS:
        print(" （无）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
