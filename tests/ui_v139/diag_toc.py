# -*- coding: utf-8 -*-
"""诊断：侧栏里的「会话二级菜单」（本对话目录）到底渲染出来没有。

    /home/biomamba/miniconda3/bin/python tests/ui_v139/diag_toc.py

用户 V13.9 item 1 的原话是「会话的二级菜单怎么没了，加回来」。这句有两个
可能的读法，脚本把两者都查一遍、用**实测**而不是读源码来回答：

  A. 目录**根本没渲染**（`dsapp_toc_ui()` 返回了 NULL）—— 那是
     `length(um) < 3` 那道闸门在起作用，或者别的什么把它挡掉了；
  B. 目录渲染了，但**看不见** —— 被侧栏的滚动位置、高度、CSS 挡在视野外。

所以脚本不只数 `.dsapp-toc` 的个数，还要把每一条的边界框（bounding box）
和侧栏可视区一起打出来。只数个数的话，B 会被误判成"没问题"。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import *          # noqa: F401,F403
from _common import EMAIL, OUT, PW, URL   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402


_SEQ = 0


def seed_turns(uid, n_turns, title="目录诊断对话"):
    """直接往库里塞一个会话 + n 轮问答，绕开界面。

    走界面的话每轮都要等模型回话；而这里要验的是「目录渲不渲染」，
    和消息**怎么来的**无关。
    """
    import sqlite3
    import time as _t
    p = db_path()
    con = sqlite3.connect(p)
    con.row_factory = sqlite3.Row
    # ⚠️ sessions.id 是 **TEXT 主键**（`s-20260913145800-4279` 这种，见
    #    db.R 的 dsapp_id），**不是**自增整数。第一版这里照抄 messages 的
    #    写法留空让它自增，插进去的三行 id 全是 NULL —— 于是侧栏渲染出
    #    三条 title 正常、id 为 NA 的会话行，`identical(df$id[i], cur)`
    #    永远为假，目录一次都不挂。看上去像"应用把二级菜单弄丢了"，
    #    其实是这个脚本自己塞了三条坏数据。
    global _SEQ
    _SEQ += 1
    sid = "s-%s-%04d" % (_t.strftime("%Y%m%d%H%M%S"), _SEQ)
    con.execute(
        "INSERT INTO sessions (id, user_id, title, created_at, updated_at) "
        "VALUES (?,?,?,datetime('now'),datetime('now'))", (sid, uid, title))
    for k in range(1, n_turns + 1):
        con.execute(
            "INSERT INTO messages (session_id, role, content, created_at) "
            "VALUES (?,?,?,datetime('now'))",
            (sid, "user", "第 %d 轮：帮我看一下这批单细胞数据的质控指标" % k))
        con.execute(
            "INSERT INTO messages (session_id, role, content, created_at) "
            "VALUES (?,?,?,datetime('now'))",
            (sid, "assistant", "好的，第 %d 轮。" % k))
    con.commit()
    con.close()
    return sid


def report(page, label):
    print("\n---- %s ----" % label)
    info = page.evaluate("""() => {
      const sb = document.querySelector('.dsapp-chat-side, .sidebar, [class*=sidebar]');
      const toc = document.querySelectorAll('.dsapp-toc');
      const tocSess = document.querySelectorAll('.dsapp-toc-sess');
      const det = document.querySelector('.dsapp-toc');
      const box = el => { if (!el) return null; const r = el.getBoundingClientRect();
        return {top: Math.round(r.top), h: Math.round(r.height),
                bottom: Math.round(r.bottom)}; };
      return {
        n_toc: toc.length,
        n_tocSess: tocSess.length,
        toc_box: box(det),
        toc_open: det ? det.hasAttribute('open') : null,
        side_box: box(sb),
        side_scrollTop: sb ? sb.scrollTop : null,
        side_scrollH: sb ? sb.scrollHeight : null,
        side_clientH: sb ? sb.clientHeight : null,
        n_sess: document.querySelectorAll('.dsapp-sess').length,
        vh: window.innerHeight,
        html: det ? det.outerHTML.slice(0, 400) : null,
      };
    }""")
    for k, v in info.items():
        if k != "html":
            print("  %-14s %s" % (k, v))
    if info["html"]:
        print("  html          %s" % info["html"].replace("\n", " ")[:300])


with sync_playwright() as pw:
    br = pw.chromium.launch(headless=True)
    pg = br.new_page(viewport={"width": 1500, "height": 950})
    pg.goto(URL, wait_until="domcontentloaded")
    enter_app(pg)
    uid, _ = seed_or_die(EMAIL)
    print("uid =", uid)

    # 建三个会话：2 轮（应当**不**出目录）、3 轮（应当出）、6 轮（应当出）
    short = seed_turns(uid, 2, "只有两轮")
    just3 = seed_turns(uid, 3, "刚好三轮")
    long_ = seed_turns(uid, 6, "六轮长对话")
    print("seeded:", short, just3, long_)

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(6000)
    report(pg, "首屏（自动选中的是最近那个：六轮长对话）")

    # 逐个点侧栏里的会话行，看目录是不是**跟着切换**
    rows = pg.locator(".dsapp-sess")
    print("\n会话行数：%d" % rows.count())
    for i in range(rows.count()):
        t = (rows.nth(i).get_attribute("title") or "")[:20]
        rows.nth(i).click()
        pg.wait_for_timeout(3500)
        report(pg, "点第 %d 行「%s」之后" % (i + 1, t))

    pg.screenshot(path=OUT + "/diag_toc.png", full_page=True)
    print("\n截图：%s/diag_toc.png" % OUT)
    br.close()
