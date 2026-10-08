#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V15.14：改名和删除这两个入口，用户**看到**的到底是哪个弹窗（只读）

用户原话（2026-10-03）：「主账的会话，点击编辑会话名称后，显示的居然是删除
界面」。

代码侧查尽了的结论是「这条路径一直是对的」—— 铅笔只发 session_rename（38 个
归档版本无一例外）、全应用只有侧栏顶栏那个垃圾桶能弹删除、线上发出去的
app.js/app.css 和仓库逐字节一样。所以**没能复现**。

但自检只能验"函数长什么样"。用户看到的是浏览器。这个探针就是补那一半：
把两个入口都点一遍，把**弹窗里真写着什么**逐字读出来，和侧栏那一行对。

⚠️ 全程只点「取消」。这个脚本**不会**确认任何删除。
   ——「只读」在这里不是"不写库"那么简单：删除框上那个红色按钮就在手边，
      所以下面每一步都显式点名它点的是哪个按钮，不靠 nth(0) 之类的顺序。

⚠️ 判据要能和**已知会红**的样本对上（见 README 的说明）：把「删除对话」改回
   「确认删除」、把正文的点名去掉，这个探针必须红。跑法见文件末尾。

跑法：
    bash tests/ui_v7/make_instance.sh 8954 /tmp/dsapp_v1513r
    sqlite3 <线上库> ".backup '/tmp/dsapp_v1513r/data/dsapp.sqlite3'"
    python3 tests/ui_v158/probe_delmodal.py
"""
import os
import re
import sys

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8954/")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal                   # noqa: E402

URL = os.environ["DSAPP_TEST_URL"]
EMAIL = os.environ.get("DSAPP_DIAG_EMAIL", "user1@example.com")
PW = os.environ.get("DSAPP_DIAG_PW", "dsapp-probe-REDACTED")

FAIL = []
OK = []


def chk(name, cond, extra=""):
    (OK if cond else FAIL).append(name)
    print("  %s %s%s" % ("✓" if cond else "✗", name,
                         ("   —— " + str(extra)) if (extra and not cond) else ""))


def login(pg):
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth", timeout=90000)
    pg.wait_for_timeout(1500)
    if pg.locator("#welcome-go_login").count():
        pg.click("#welcome-go_login")
        pg.wait_for_timeout(800)
    pg.fill("#welcome-login_email", EMAIL)
    pg.fill("#welcome-login_password", PW)
    pg.click("#welcome-do_login")
    for _ in range(120):
        pg.wait_for_timeout(1000)
        if pg.locator(".dsapp-shell").count():
            return
        if pg.locator("#tos_gate-do_agree").count():
            c = pg.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            pg.click("#tos_gate-do_agree")
            pg.wait_for_timeout(3000)
    sys.exit("登录没进主界面，页面文字：\n%s" % pg.inner_text("body")[:800])


def modal_facts(pg):
    """把当前**看得见**的那一个弹窗读成事实：标题 / 正文 / 按钮 / 危险按钮数。

    ⚠️ 读 `display != none` 的那些，不是 `querySelector` 的第一个：Bootstrap
       关掉的弹窗**留在 DOM 里**，直接取第一个会读到上一次那个。
    """
    return pg.evaluate("""() => {
      const vis = Array.from(document.querySelectorAll('.modal'))
        .filter(m => getComputedStyle(m).display !== 'none');
      if (!vis.length) return null;
      const m = vis[vis.length - 1];        // 最上面那个
      const q = s => m.querySelector(s);
      const btns = Array.from(m.querySelectorAll('.modal-footer button'))
        .map(b => ({ txt: b.innerText.trim(), cls: b.className }));
      return {
        title: (q('.modal-title') ? q('.modal-title').innerText : '').trim(),
        body:  (q('.modal-body')  ? q('.modal-body').innerText  : '').trim(),
        btns:  btns,
        danger: btns.filter(b => /btn-danger/.test(b.cls)).length,
        inputs: m.querySelectorAll('input[type=text]').length,
        n: vis.length
      };
    }""")


def click_modal_button(pg, text):
    """按**文字**点弹窗底部的按钮 —— 不按顺序、不按 nth。"""
    pg.locator(".modal-footer button:has-text('%s')" % text).last.click()


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch(headless=True)
        pg = br.new_context(viewport={"width": 1440, "height": 900}).new_page()
        login(pg)
        pg.wait_for_timeout(3500)
        ensure_no_modal(pg)
        pg.wait_for_selector(".dsapp-sess", timeout=30000)

        row = pg.locator(".dsapp-sess").nth(0)
        sid = row.get_attribute("data-sid")
        title = row.locator(".dsapp-sess-title").inner_text().strip()
        print("== 拿第 1 行做样本：sid=%s 侧栏写着 %r ==" % (sid, title))

        # ------------------------------------------------------------------
        print("\n-- ① 铅笔：点它弹出来的必须**不是**删除框 --")
        row.locator(".dsapp-sess-edit").click()
        pg.wait_for_timeout(1800)
        f = modal_facts(pg)
        if f is None:
            chk("点铅笔弹出了弹窗", False, "一个都没弹")
        else:
            print("     标题=%r" % f["title"])
            print("     按钮=%s" % [b["txt"] for b in f["btns"]])
            chk("点铅笔弹出的是「重命名对话」", "重命名" in f["title"], f["title"])
            chk("它**不是**删除框（标题里没有「删除」）",
                "删除" not in f["title"], f["title"])
            chk("它的正文里没有「不可撤销」这类删除措辞",
                "不可撤销" not in f["body"], f["body"])
            chk("它**没有**红色危险按钮", f["danger"] == 0,
                "%d 个 btn-danger" % f["danger"])
            chk("它有一个改名字的输入框，且初值就是这一行的标题",
                f["inputs"] == 1 and title[:20] in
                pg.locator(".modal input[type=text]").last.input_value(),
                pg.locator(".modal input[type=text]").last.input_value()[:60])
            click_modal_button(pg, "取消")
            pg.wait_for_timeout(1200)

        # ------------------------------------------------------------------
        print("\n-- ② 垃圾桶：弹出来的删除框必须点名要删哪一条 --")
        trash_txt = pg.locator("#chat-del_chat").inner_text().strip()
        chk("侧栏的删除按钮**看得见文字**（不再是裸图标）",
            len(trash_txt) > 0, "innerText 是空的")
        print("     它写着 %r" % trash_txt)

        pg.click("#chat-del_chat")
        pg.wait_for_timeout(1800)
        f = modal_facts(pg)
        if f is None:
            chk("点垃圾桶弹出了弹窗", False, "一个都没弹")
        else:
            print("     标题=%r" % f["title"])
            print("     正文=%r" % f["body"][:110])
            print("     按钮=%s" % [b["txt"] for b in f["btns"]])
            chk("删除框的标题是「删除对话」（不是四处共用的「确认删除」）",
                "删除对话" in f["title"], f["title"])
            chk("★★★ 正文点名了要删的是哪一个对话",
                "「" in f["body"] and "」" in f["body"] and
                "确定删除" in f["body"], f["body"][:80])
            # 点名点的必须是**当前选中的那一个**，而且和侧栏一字不差
            cur = pg.locator(".dsapp-sess.active .dsapp-sess-title")
            if cur.count():
                cur_t = cur.first.inner_text().strip()
                m = re.search(r"确定删除「(.*?)」吗", f["body"])
                chk("★★ 正文里那个名字和侧栏当前那一行**一字不差**",
                    bool(m) and m.group(1) == cur_t[:40],
                    "弹窗=%r 侧栏=%r" % (m.group(1) if m else None, cur_t[:40]))
            else:
                print("     （当前没有 active 行，跳过点名核对）")
            chk("它有一个红色危险按钮（破坏性动作要显眼）",
                f["danger"] >= 1)

            # ------------------------------------------------------------------
            print("\n-- ③ 弹窗开着时，侧栏点不穿 --")
            tb = pg.locator("#chat-del_chat").bounding_box()
            hit = pg.evaluate("""([x,y]) => { const e = document.elementFromPoint(x,y);
                return e ? (e.id || e.className.toString().split(' ')[0]) : 'null'; }""",
                              [tb["x"] + tb["width"] / 2, tb["y"] + tb["height"] / 2])
            chk("★ 删除框开着时，垃圾桶本身点不到（被遮罩挡住）",
                "del_chat" not in str(hit), "命中的是 %s" % hit)
            try:
                pg.locator(".dsapp-sess").nth(1).locator(".dsapp-sess-edit").click(timeout=3000)
                pg.wait_for_timeout(1200)
                f2 = modal_facts(pg)
                chk("★ 删除框开着时，别的行的铅笔也点不到",
                    f2 is not None and "重命名" not in f2["title"],
                    "点穿了，现在最上面是 %r" % (f2 or {}).get("title"))
            except Exception:
                chk("★ 删除框开着时，别的行的铅笔也点不到", True)
            # ⚠️ 只点「取消」—— 这个脚本任何时候都不确认删除
            click_modal_button(pg, "取消")
            pg.wait_for_timeout(1200)

        # ------------------------------------------------------------------
        print("\n-- ④ 铅笔的命中区 --")
        # ⚠️ 量之前**先滚进视口**。上面 ③ 那次被挡住的点击会触发 Playwright 的
        #    scroll-into-view，把第一行滚到视口外面去；而 `bounding_box()` 对
        #    离屏元素**照样返回正数**（坐标可以是负的），`elementFromPoint()`
        #    却直接回 null —— 于是"命中区"读出来是好好的 28×28，"中心打到谁"
        #    却是 null。初版就是这么写的，红了一条指向完全无关的地方。
        pen0 = pg.locator(".dsapp-sess").nth(0).locator(".dsapp-sess-edit")
        pen0.scroll_into_view_if_needed()
        pg.wait_for_timeout(400)
        pb = pen0.bounding_box()
        print("     %.0f×%.0f px，中心 (%.0f, %.0f)"
              % (pb["width"], pb["height"],
                 pb["x"] + pb["width"] / 2, pb["y"] + pb["height"] / 2))
        chk("★★ 铅笔命中区 ≥ 24×24（原来是 16×17）",
            pb["width"] >= 24 and pb["height"] >= 24,
            "%.0f×%.0f" % (pb["width"], pb["height"]))
        hitp = pg.evaluate("""([x,y]) => {
            const e = document.elementFromPoint(x,y);
            if (!e) return '视口外/null @' + Math.round(x) + ',' + Math.round(y);
            return e.closest && e.closest('.dsapp-sess-edit') ? 'pencil' :
              (e.tagName + '.' + e.className.toString().split(' ')[0]); }""",
                           [pb["x"] + pb["width"] / 2, pb["y"] + pb["height"] / 2])
        chk("★ 命中区正中心打到的就是铅笔自己", hitp == "pencil", hitp)
        # 命中区大了但被别的元素压在上面的话，等于没放大 —— 四角也点一遍。
        corners = pg.evaluate("""(b) => {
            const pts = [[b.x+2,b.y+2],[b.x+b.width-2,b.y+2],
                         [b.x+2,b.y+b.height-2],[b.x+b.width-2,b.y+b.height-2]];
            return pts.map(([x,y]) => { const e = document.elementFromPoint(x,y);
              return e && e.closest('.dsapp-sess-edit') ? 1 : 0; }); }""", pb)
        chk("★ 命中区四角也都落在铅笔上（没有被谁压着）",
            sum(corners) == 4, "四角命中 %d/4" % sum(corners))

        # ------------------------------------------------------------------
        print("\n-- ⑤ 全程没有确认过任何删除 --")
        left = pg.locator(".dsapp-sess[data-sid='%s']" % sid).count()
        chk("★ 样本那一行**还在**（这个探针只点取消）", left == 1,
            "行不见了 —— 确认删除被点到了")

        br.close()

    print("\n通过 %d 项，失败 %d 项" % (len(OK), len(FAIL)))
    for n in FAIL:
        print("  ✗ %s" % n)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
