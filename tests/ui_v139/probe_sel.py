# -*- coding: utf-8 -*-
"""一次性探针：点「去预览」到底有没有把那一行的勾弄丢，以及 app.js 里那段
"按回点击之前的状态"为什么没生效。

    /home/miniconda3/bin/python tests/ui_v139/probe_sel.py

只回答两个问题：
  1. pointerdown 那一刻，`window.__dsappPreClickSel` 有没有被写上
     （没写 = 监听没跑到，写了 = 逻辑跑了但没兜住）；
  2. 那一下点击前后，`tr.selected` 到底怎么变的（一步一步量，不是只看最后）。
"""
import base64
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import *            # noqa: F401,F403
from _common import DATA_ROOT, EMAIL, OUT, URL, db_path   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FILES_PANE = '.tab-pane[data-value="files"]'


with sync_playwright() as pw:
    br = pw.chromium.launch(headless=True)
    pg = br.new_page(viewport={"width": 1600, "height": 950})
    logs = []
    pg.on("console", lambda m: logs.append("%s: %s" % (m.type, m.text[:160])))
    pg.on("pageerror", lambda e: logs.append("PAGEERROR: %s" % str(e)[:200]))

    pg.goto(URL, wait_until="domcontentloaded")
    enter_app(pg)
    uid = seed_or_die(EMAIL)[0]
    d = os.path.join(DATA_ROOT, "files", "u%d" % uid)
    os.makedirs(d, exist_ok=True)
    for nm in ["sel_a.txt", "sel_b.txt", "sel_c.txt"]:
        with open(os.path.join(d, nm), "w") as fh:
            fh.write("x\n")
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(6000)
    goto(pg, "files", wait=4000)
    pg.wait_for_timeout(2500)

    tbl = pg.locator(FILES_PANE + " .dsapp-dt-nowrap table").first
    print("  行数 %d" % tbl.locator("tbody tr").count(), flush=True)

    def n_sel():
        return tbl.locator("tbody tr.selected").count()

    # 点三行的「大小」格 = 勾三行
    for r in range(3):
        loc = tbl.locator("tbody tr").nth(r).locator("td").nth(2)
        loc.scroll_into_view_if_needed(timeout=5000)
        loc.click(timeout=15000)
        pg.wait_for_timeout(700)
        print("    点完第 %d 行：selected=%d" % (r, n_sel()), flush=True)

    # 找一个文件行（目录名带 📁）
    fr = None
    for i in range(tbl.locator("tbody tr").count()):
        nm = tbl.locator("tbody tr").nth(i).locator("td").nth(1).inner_text()
        if "\U0001F4C1" not in nm:
            fr = i
            print("  文件行 = 第 %d 行 %r" % (i, nm.strip()), flush=True)
            break

    # 在三个时刻各插一根探针，看"勾是在哪一层掉的"：
    #   ① document 捕获阶段 —— 最早，Select 扩展还没跑
    #   ② 表格上的冒泡     —— Select 扩展就在这一层（它绑在表上）
    #   ③ document 冒泡    —— app.js 里那个处理器就在这一层，且注册得更早，
    #                        所以同一层里我们是**后**跑的，看到的是它的结果
    pg.evaluate("""() => {
      window.__dbg = [];
      const n = () => {
        const t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
        if (!t || !window.jQuery) return -1;
        try { return window.jQuery(t).DataTable().rows({selected:true}).count(); }
        catch (e) { return -2; }
      };
      document.addEventListener('click', function () {
        window.__dbg.push('①捕获 sel=' + n());
      }, true);
      const t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
      t.addEventListener('click', function () {
        window.__dbg.push('②表上 sel=' + n());
      }, false);
      document.addEventListener('click', function () {
        window.__dbg.push('③doc冒泡 sel=' + n());
      }, false);
    }""")
    print("\n  ---- 点「去预览」 ----", flush=True)
    # 先单独派发一次 pointerdown 看看监听在不在
    pg.evaluate("window.__dsappPreClickSel = 'UNSET'")
    cell = tbl.locator("tbody tr").nth(fr).locator("td").nth(0)
    cell.scroll_into_view_if_needed(timeout=5000)
    print("  点之前 selected=%d，点之前指针=%r"
          % (n_sel(), pg.evaluate("window.__dsappPreClickSel")), flush=True)
    cell.click(timeout=15000)
    pg.wait_for_timeout(1200)
    print("  点之后 selected=%d，指针=%s" % (
        n_sel(), pg.evaluate(
            "() => { var b = window.__dsappPreClickSel;"
            " return b === null ? null : (b && b.idx ? b.idx : String(b)); }")),
        flush=True)
    # 再等一会儿，看服务端重渲染会不会继续改
    pg.wait_for_timeout(3000)
    print("  再等 3 秒 selected=%d" % n_sel(), flush=True)
    print("  三个时刻的探针：%s" % pg.evaluate("window.__dbg"), flush=True)
    print("  点击之后 pointer 变量还在吗：%s" % pg.evaluate(
        "() => { var b = window.__dsappPreClickSel;"
        " return b === null ? 'null' : (b && b.idx ? ('idx=' + b.idx) : String(b)); }"),
        flush=True)
    print("  工具栏 = %r" % pg.inner_text(FILES_PANE)[:120], flush=True)

    print("\n  控制台：", flush=True)
    for x in logs[-15:]:
        print("    " + x, flush=True)
    pg.screenshot(path=OUT + "/probe_sel.png", full_page=True)
    br.close()
