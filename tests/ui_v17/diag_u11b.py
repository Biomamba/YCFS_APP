# -*- coding: utf-8 -*-
"""在文件页里逐个点进去，把每一层的行打出来 —— 用户看到的就是这些。"""
import os
import sqlite3
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v17")
import _common as C                                       # noqa: E402
from playwright.sync_api import sync_playwright            # noqa: E402


def _fixture_email():
    """同 `diag_u11.py`：从实例库读，不把真人邮箱写进仓库。"""
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
    if pg.locator("#welcome-email").count():
        pg.click("#welcome-go_login")
        pg.wait_for_timeout(1200)
    pg.fill("#welcome-login_email", EMAIL)
    pg.fill("#welcome-login_password", PW)
    pg.click("#welcome-do_login")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(3000)
    C.ensure_no_modal(pg)


def rows(pg):
    return pg.evaluate("""() => Array.from(
        document.querySelectorAll('#files-tbl table tbody tr'))
        .map(tr => {
            const tds = tr.querySelectorAll('td');
            // ⚠️ 空目录走的是**另一张只有一列的提示表**（"这个文件夹是空的…"），
            //    所以 td[1] 在这儿是 undefined —— 第一版直接 .innerText 就抛了，
            //    报错还落在和"空目录"毫无关系的地方。
            return tds.length > 1 ? tds[1].innerText.trim() : '(提示) ' + tr.innerText.trim();
        })""")


def crumb(pg):
    return pg.evaluate("""() => {
        const c = document.querySelector('#files-crumb');
        return c ? c.innerText.replace(/\\s+/g, ' ').trim() : '(没有)';
    }""")


def enter(pg, name):
    """点表格里名字含 name 的那一行的第 2 格。

    ⚠️ 那一格**不是链接** —— 进目录靠的是 DT 的 cell click 回调
       （`input$tbl_cell_clicked`，见 mod_files.R 里 col==1 那一支）。
       所以必须点**真的 td 元素**：用 evaluate 里 `a.click()` 是点了个
       不存在的东西，返回 false 而页面一动不动（第一版就是这么写的，
       两个目录都"点不动"，看着像页面坏了）。
    """
    try:
        cell = pg.locator("#files-tbl table tbody tr",
                          has_text=name).first.locator("td").nth(1)
        cell.click(timeout=8000)
    except Exception as e:
        print("     点不动：%s" % str(e).splitlines()[0])
        return False
    pg.wait_for_timeout(3500)
    return True


def main():
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1440, "height": 950})
        try:
            login(pg)
            C.goto(pg, "files")
            pg.wait_for_timeout(3500)
            C.ensure_no_modal(pg)

            for d in ["T2DM–PD公开数据项目：可直接复制的Agen-8251",
                      "按照下面要求完成T2DM–PD公开数据项目： 适-9030"]:
                print("\n===== 进 %s =====" % d)
                print("  点得动吗：", enter(pg, d))
                print("  面包屑：", crumb(pg))
                rr = rows(pg)
                print("  里面 %d 项：%s" % (len(rr), rr))
                print("  工作区卡片：%r" % pg.evaluate("""() => {
                    const c = document.querySelector('#files-ws_card');
                    return c ? c.innerText.replace(/\\s+/g,' ').trim().slice(0,200)
                             : '(没有 #files-ws_card)';
                }"""))
                # 再进 data_raw
                if "data_raw" in " ".join(rr):
                    print("  -- 进 data_raw --")
                    print("     点得动吗：", enter(pg, "data_raw"))
                    print("     面包屑：", crumb(pg))
                    rr2 = rows(pg)
                    print("     里面 %d 项：%s" % (len(rr2), rr2[:12]))
                    # 回退两级
                    pg.go_back()
                    pg.wait_for_timeout(2500)
                # 回到根：用面包屑第一段
                pg.evaluate("""() => {
                    const c = document.querySelector('#files-crumb');
                    const a = c && c.querySelector('a');
                    if (a) a.click();
                }""")
                pg.wait_for_timeout(2500)
        finally:
            pg.screenshot(path="/tmp/u11_drill.png", full_page=True)
            b.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
