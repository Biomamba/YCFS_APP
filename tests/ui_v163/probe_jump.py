# -*- coding: utf-8 -*-
"""V16.3 item 6：目录里点一条**被折叠掉的**消息，要真的跳过去。

用户原话：「消息过多被折叠时，按导航栏里的消息无法跳转」。

病根（改之前）：目录列的是库里**全部**消息（db_messages_get 一把全取），
而消息流只渲染末尾一段（DSAPP_HIST_BUDGET_C）。被折叠的那几轮在 DOM 里
根本没有元素，而 dsappJumpTo 是 `getElementById` 找不到就静默 return
false —— 点了没反应，控制台干干净净。

这条探针要**造出那个形状**才测得到：种一个足够长的对话，让它的开头
落在窗口之外，然后点目录里那一条。

★ 判据分三段，缺一段这条探针就是假的：
  ① 目标锚点在点击**之前**确实不在 DOM 里（不然测的是老路径：就地滚动，
     那条路本来就好用）；
  ② 点击**之后**它出现在 DOM 里，而且**滚进了视野**（只看"在 DOM 里"
     抓不到"画在下面看不见"）；
  ③ 顶上那条「你正在看较早的内容」横条在，点「回到最新」能回到末尾。
     ⚠️ 这一段是这一版**新增的代价**（跳过去 = 比它新的那些暂时不在窗口
     里）。代价必须看得见，否则用户会以为"后面的消息没了"。

跑法：
    bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a
    python3 tests/ui_v163/probe_jump.py
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
FAIL = []
NCHECK = [0]


def check(name, ok, extra=""):
    NCHECK[0] += 1
    print("  %s %s%s" % ("✅" if ok else "❌", name,
                         ("  — " + extra) if extra else ""), flush=True)
    if not ok:
        FAIL.append(name)
    return ok


def seed_long_chat(uid, dbp, n=40, chars=7000):
    """种一个"开头被折叠掉"的对话，返回 (session_id, [message_id...])。

    ⚠️ 直接写库，不走界面：界面发消息要先有可用的 Key + 一次真请求，
       而这里要测的是**渲染**，不是"能不能发出去"。
    ⚠️ 每条 chars 个字：窗口预算是 50000 字（DSAPP_HIST_BUDGET_C），
       7000 字一条 = 一屏只装得下七八条 —— 40 条里绝大多数都在窗口外。
       用小消息种的话窗口会一口气全收下，这条探针就变成了"点一条**已经在
       DOM 里**的目录项"，测的是另一条路（而且永远是绿的）。
    """
    now = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    sid = "s-%s-v163jump" % time.strftime("%Y%m%d%H%M%S")
    con = sqlite3.connect(dbp)
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?, ?, ?, ?, ?)",
                (sid, "跳转测试（%d 条）" % n, now, now, uid))
    ids = []
    for i in range(n):
        role = "user" if i % 2 == 0 else "assistant"
        # 每一轮带一句**唯一**的编号，断言里要按它认人：只按"第几条"认的话，
        # 渲染顺序一变就会指到别的消息上（而那种错法看起来是"跳对了"）。
        body = "第 %d 条 %s。%s" % (i + 1, role, ("内容 " * (chars // 3)))
        cur = con.execute(
            "INSERT INTO messages (session_id, role, content, created_at)"
            " VALUES (?, ?, ?, ?)", (sid, role, body, now))
        ids.append(cur.lastrowid)
    con.commit()
    con.close()
    return sid, ids


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()
        C.enter_app(pg)
        uid, dbp = C.seed_or_die(C.LAST_EMAIL)
        print("账号 uid=%s，库=%s" % (uid, dbp), flush=True)

        sid, ids = seed_long_chat(uid, dbp)
        print("种好对话 %s（%d 条，每条 7000 字）" % (sid, len(ids)), flush=True)

        # ★ 种完必须**重新加载**：会话列表是登录那一刻拉的一次，
        #   不 reload 的话界面上根本没有这个对话（本仓的老账）。
        pg.reload(wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-shell", timeout=60000)
        pg.wait_for_timeout(4000)
        C.ensure_no_modal(pg)

        # 应用会自动选中**最近更新**的那个对话；这里只有这一个，等它打开。
        try:
            pg.wait_for_selector(".dsapp-toc-item", timeout=30000)
        except Exception:
            pg.screenshot(path="%s/jump_没有目录.png" % OUT)
            sys.exit("❌ 目录没出来（.dsapp-toc-item 一个都没有）——"
                     "要么对话没被打开，要么 TOC 的闸门把它挡了。"
                     "看一眼 %s/jump_没有目录.png" % OUT)

        items = pg.locator(".dsapp-toc-item")
        n_item = items.count()
        check("目录出来了（%d 轮）" % n_item, n_item >= 3)

        # ① 点**第一条**（最早那一轮）。它在窗口外面是这条探针的前提。
        first = items.first
        anchor = first.get_attribute("data-anchor")
        mid = pg.evaluate(
            "(id) => { var el = document.getElementById(id);"
            " return el ? (el.getAttribute('data-mid') || '') : '__MISSING__'; }",
            anchor)
        check("① 目标锚点此刻**不在** DOM 里（点之前）",
              mid == "__MISSING__", "anchor=%s" % anchor)

        # 折叠区里那句话不该出现在**消息流**里 —— 不然"不在 DOM"这句就说不通。
        #
        # ⚠️⚠️ 只查 .dsapp-chat-scroll，**不能**查 document.body.innerText：
        #    目录那一栏里每一条的标签就是用户那句话的第一行（dsapp_toc_label），
        #    所以 "第 1 条 user" 这几个字在**侧栏**里一直都在。第一版就是这么
        #    写的，报了一个假红 —— 判据选错了地方，看上去像"折叠没生效"。
        body_txt = pg.evaluate(
            "() => { var b = document.querySelector('.dsapp-chat-scroll');"
            " return b ? b.innerText : ''; }") or ""
        check("① 被折叠的那条正文没画进消息流", "第 1 条 user" not in body_txt)

        first.click()
        # 服务端要跑一趟（把窗口挪过去）+ 一帧重渲染，再轮到前端轮询
        try:
            pg.wait_for_function(
                "(id) => !!document.getElementById(id)", arg=anchor, timeout=25000)
        except Exception:
            pg.screenshot(path="%s/jump_跳不过去.png" % OUT)
            sys.exit("❌ 点了目录第一条，等 25 秒那个锚点还是没进 DOM。"
                     "看一眼 %s/jump_跳不过去.png" % OUT)

        pg.wait_for_timeout(2500)   # smooth 滚动走完
        check("② 点击之后锚点进了 DOM", True)

        # ② 而且要看得到：锚点在滚动容器里、贴着顶
        geo = pg.evaluate("""(id) => {
          var el = document.getElementById(id);
          var box = document.querySelector('.dsapp-chat-scroll');
          if (!el || !box) return {err: 'missing'};
          var a = el.getBoundingClientRect(), b = box.getBoundingClientRect();
          return {dy: Math.round(a.top - b.top), h: Math.round(a.height),
                  bh: Math.round(b.height), vis: a.bottom > b.top && a.top < b.bottom};
        }""", anchor)
        check("② 目标滚进了视野（不是画在下面看不见）",
              isinstance(geo, dict) and geo.get("vis") is True
              and abs(geo.get("dy", 9999)) < 120, str(geo))

        # 屏幕上真的出现那句话（DOM 里有 ≠ 用户看得见）
        txt2 = pg.evaluate("() => document.body.innerText") or ""
        check("② 那一轮的正文画出来了", "第 1 条 user" in txt2)

        # ③ 顶上那条横条 + 「回到最新」
        bar = pg.locator(".dsapp-hist-focus")
        check("③ 「你正在看较早的内容」横条在", bar.count() == 1)
        if bar.count() == 1:
            check("③ 横条在视野里（sticky 钉住了）", bar.first.is_visible())
            print("     横条文字：%s"
                  % (bar.first.inner_text() or "").replace("\n", " "), flush=True)
        latest = pg.locator("#chat-hist_latest")
        check("③ 「回到最新」在", latest.count() == 1)

        pg.screenshot(path="%s/jump_跳过去.png" % OUT)
        if latest.count() == 1:
            latest.first.click()
            pg.wait_for_timeout(2500)
            gone = pg.evaluate(
                "(id) => !document.getElementById(id)", anchor)
            check("③ 点「回到最新」之后那条又收回去了", bool(gone))
            check("③ 横条自己消失了",
                  pg.locator(".dsapp-hist-focus").count() == 0)
            tail = pg.evaluate("() => { var b = document.querySelector('.dsapp-chat-scroll');"
                               " return b ? b.innerText.indexOf('第 40 条 assistant') >= 0 : false; }")
            check("③ 末尾那一条重新看得见", bool(tail))
            pg.screenshot(path="%s/jump_回到最新.png" % OUT)

        br.close()

    print("\n=== %d 条断言，%d 条没过 ===" % (NCHECK[0], len(FAIL))
          + ("" if not FAIL else "：%s" % " / ".join(FAIL)), flush=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
