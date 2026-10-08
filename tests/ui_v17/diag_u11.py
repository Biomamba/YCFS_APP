# -*- coding: utf-8 -*-
"""把 uid=11 的两个页面各自 dump 一遍，看它到底画了什么。

⚠️ 这是**诊断脚本**，不是探针：它不下断言，只把界面上的字和结构打出来。
   本仓的规矩是"先看清现场，再写判据"——判据一旦先写，就会不知不觉
   绕着它去解释现象。
"""
import os
import sqlite3
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v17")
import _common as C                                       # noqa: E402
from playwright.sync_api import sync_playwright            # noqa: E402


def _fixture_email():
    """从**实例库**读夹具账号的邮箱（`mkfix_u11.py` 从生产照抄的那一行）。

    不在仓库里写这个字面量：它是真人的邮箱，而 `desktop/sensitive-patterns`
    里有它 —— 写进来下一步 `pack_github.sh` 就会拒绝打包（那是响的失败，
    不是静默泄漏，但同样是白折腾一趟）。
    """
    db = os.environ.get("DSAPP_FIX_DB", "/tmp/dsapp_v17a/data/dsapp.sqlite3")
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        row = con.execute("SELECT email FROM users WHERE id=11").fetchone()
    finally:
        con.close()
    if not row or not row[0]:
        sys.exit("实例库里没有 uid=11 —— 先跑 mkfix_u11.py；或设 DSAPP_FIX_DB")
    return row[0]


EMAIL = _fixture_email()
PW = "Fixture_V17_pw"


def login(pg):
    pg.goto(C.URL, wait_until="domcontentloaded")
    C.wait_awake(pg)
    pg.wait_for_selector(".dsapp-auth", timeout=30000)
    pg.wait_for_timeout(1500)
    # 注册页 -> 登录页
    if pg.locator("#welcome-email").count():
        pg.click("#welcome-go_login")
        pg.wait_for_timeout(1200)
    pg.fill("#welcome-login_email", EMAIL)
    pg.fill("#welcome-login_password", PW)
    pg.click("#welcome-do_login")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(3000)
    C.ensure_no_modal(pg)


def dump_table(pg, label):
    """文件页那张 DT：行、以及每一行第一格的名字。"""
    print("\n---- %s ----" % label)
    try:
        rows = pg.evaluate("""() => Array.from(
            document.querySelectorAll('#files-tbl table tbody tr'))
            .map(tr => Array.from(tr.querySelectorAll('td'))
                        .map(td => td.innerText.trim()))""")
    except Exception as e:
        rows = [["<取不到: %s>" % e]]
    print("  表里 %d 行" % len(rows))
    for r in rows[:20]:
        print("   ", " | ".join(r[:4]))
    empty = pg.evaluate("""() => {
        const t = document.querySelector('#files-tbl');
        return t ? t.innerText.trim().slice(0, 200) : '(没有 #files-tbl)';
    }""")
    print("  整块文字：%r" % empty)


def main():
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1440, "height": 950})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        try:
            login(pg)
            print("登录后 URL=%s" % pg.url)
            print("导航项：", pg.evaluate("""() => Array.from(
                document.querySelectorAll('.dsapp-nav a, .nav-link, [data-dsapp-nav]'))
                .map(e => (e.getAttribute('data-dsapp-nav') || '') + ':' + e.innerText.trim())
                .filter(x => x.length > 1).slice(0, 20)"""))
            print("页面上的 id 前缀里有 files 的：",
                  pg.evaluate("""() => Array.from(document.querySelectorAll('[id]'))
                      .map(e => e.id).filter(i => i.indexOf('files') === 0).slice(0, 40)"""))

            # ---- 文件页 ----
            C.goto(pg, "files")
            pg.wait_for_timeout(4000)
            C.ensure_no_modal(pg)
            dump_table(pg, "文件页 · 根目录")
            pg.screenshot(path="/tmp/u11_files_root.png", full_page=True)

            # 面包屑：进 Agen-8251
            print("\n---- 面包屑/目录项 ----")
            print(pg.evaluate("""() => Array.from(
                document.querySelectorAll('#files-tbl table tbody tr'))
                .map(tr => tr.innerText.trim()).slice(0, 10)"""))

            # ---- 首页（对话页）的文件卡片 ----
            C.goto(pg, "chat")
            pg.wait_for_timeout(5000)
            C.ensure_no_modal(pg)
            print("\n---- 对话页 · 本对话的文件卡片 ----")
            print(pg.evaluate("""() => {
                const c = document.querySelector('.dsapp-files-col');
                return c ? c.innerText.trim().slice(0, 800) : '(没有 .dsapp-files-col)';
            }"""))
            pg.screenshot(path="/tmp/u11_chat.png", full_page=True)

            print("\nJS 异常：", errs[:5] if errs else "（无）")
        finally:
            b.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
