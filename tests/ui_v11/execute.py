# -*- coding: utf-8 -*-
"""V11 item 10：确认执行按钮搬到固定位置之后，**功能**还是通的。

对着一次性实例（8898）跑：

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v11/execute.py

item 10 的原话是「确认执行的按钮不应该在代码框上，而是应该在对话界面的
固定位置，没有方案待确认时是一个灰度颜色，有方案需要确认时点亮」。

★ 为什么这个脚本必须存在：layout.py 量的是那颗按钮**在哪儿**（几何），
  它证明不了"点下去还能跑"。而这次改动动的正是它的挂载点 —— 按钮从代码
  卡片里搬到了固定槽里（V11 在 composer，V12 item 2 起在输出框下沿的
  .dsapp-output-bar），输入 id、事件绑定、"哪一段代码待确认"这条链路全都
  换过一遍。位置对了但点不动，是这次改动最可能出的错，也是几何断言完全
  看不见的那种错。

（这条链路原来由 tests/ui_v8/running.py 覆盖，那一版整个建立在"卡片里有
  一颗按钮"之上，V11 之后已经作废；这里按新界面重写一遍。）
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (APP, DATA_ROOT, OUT, URL, Chk, db_path, enter_app,  # noqa
                     goto_chat)
from playwright.sync_api import sync_playwright

chk = Chk()

# 跑 4 秒：太短的话"正在执行"那一屏还没渲染出来任务就结束了，中间那几条
# 断言会变成看运气。太长的代价是每次跑测试都要等。
CODE = 'cat("v11 execute test start\\n")\nSys.sleep(4)\ncat("v11 done\\n")\n'
MARK = "V11执行用例"


def sql(q, args=()):
    con = sqlite3.connect(db_path())
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def seed_code_message(email, sid, code):
    """造一条带 R 代码块的**助手**消息。

    ⚠️ 代码围栏必须**闭合**（``` 成对）。没闭合的块在界面上是"生成中…"，
    下面 pending_code() 也不会认它 —— 表现是"按钮一直不亮"，而报出来的
    错会指向"按钮坏了"。
    """
    uid = sql("SELECT id FROM users WHERE email = ?", (email,))[0][0]
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    con = sqlite3.connect(db_path())
    con.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    con.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)", (sid, "V11 执行用例", now, now, uid))
    con.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)", (sid, "user", "%s：跑一下这段" % MARK, now))
    con.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)",
                (sid, "assistant",
                 "好的，这段会跑几秒：\n\n```r\n%s```\n\n跑完告诉我。\n" % code,
                 now))
    con.commit()
    con.close()


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    email = enter_app(pg)
    sid = "v11-exec-%s" % int(time.time())
    seed_code_message(email, sid, CODE)

    goto_chat(pg, reload_first=True)
    pg.wait_for_selector(".dsapp-sess", timeout=30000)
    pg.click(".dsapp-sess[data-sid='%s']" % sid)
    pg.wait_for_timeout(3000)

    # =====================================================================
    print("\n== item 10：有代码待确认时，按钮点亮 ==")
    # =====================================================================
    run_btn = pg.locator(".dsapp-code-run")
    chk("★★ 固定位置那颗按钮亮起来了（有待确认的代码）", run_btn.count() == 1,
        "找到 %d 颗 .dsapp-code-run" % run_btn.count())
    if run_btn.count() != 1:
        pg.screenshot(path=os.path.join(OUT, "execute_fail.png"), full_page=True)
        b.close()
        sys.exit(chk.done())

    chk("★ 它是**可点**的（不是那个灰的占位）",
        run_btn.first.is_enabled(), "按钮是 disabled 的")
    # ⚠️ V12 item 2 把这颗按钮从输入区搬到了**输出框内部的下沿**
    #    （.dsapp-output-bar）。这条断言跟着改，但**判据不变**：它必须长在
    #    一个"固定位置"的容器里，而不是代码卡片上。位置本身（贴输出框
    #    下沿、距离多少像素）由 tests/ui_v12/layout.py 量。
    inside = pg.evaluate("""() => {
      const b = document.querySelector('.dsapp-code-run');
      const c = document.querySelector('.dsapp-output-bar');
      const comp = document.querySelector('.dsapp-composer');
      return {bar: !!(b && c && c.contains(b)),
              composer: !!(comp && b && comp.contains(b))};
    }""")
    chk("★ 它在固定位置那颗槽里（V12 起是输出框下沿的动作条）", inside["bar"],
        inside)
    chk("★ 它不在输入区里（也不在代码卡片里）", not inside["composer"], inside)
    chk("★ 卡片上只有「待执行」的标记，没有第二颗执行按钮",
        pg.locator(".dsapp-code-card .dsapp-code-run").count() == 0,
        "卡片里还有 %d 颗" % pg.locator(".dsapp-code-card .dsapp-code-run").count())

    # =====================================================================
    print("\n== item 10：点它 → 任务真的跑起来 ==")
    # =====================================================================
    run_btn.first.click()
    pg.wait_for_timeout(2500)

    live = pg.locator(".dsapp-run-live")
    live_seen = False
    for _ in range(10):
        if live.count() > 0:
            live_seen = True
            break
        pg.wait_for_timeout(700)
    chk("★★ 对话里出现了「正在执行」那一块（用户不必切到任务页去看）",
        live_seen, "没等到 .dsapp-run-live")
    if live_seen:
        txt = live.first.inner_text()
        chk("★ 那块里有实时输出区，而且是**这条对话**的任务",
            "实时输出" in txt, txt[:200])
    chk("★ 点完之后按钮立刻灰下去（没有第二段待确认的代码了）",
        pg.locator(".dsapp-code-run").count() == 0,
        "还剩 %d 颗" % pg.locator(".dsapp-code-run").count())
    chk("★ 灰的那颗还在原地（是变成灰的，不是消失了）—— 而且停止那颗也在",
        pg.locator(".dsapp-output-bar .dsapp-btn-run-off").count() >= 1,
        "动作条里没找到灰按钮")

    # ---- 等它跑完 --------------------------------------------------------
    tid = None
    for _ in range(60):
        r = sql("SELECT id, status FROM tasks WHERE session_id = ?"
                " ORDER BY id DESC LIMIT 1", (sid,))
        if r and r[0][1] in ("success", "failed", "error", "timeout"):
            tid = r[0][0]
            break
        pg.wait_for_timeout(1000)
    chk("★★ 任务真的跑起来了（不是只点亮了个按钮）", tid is not None)
    if tid:
        st, out = sql("SELECT status, stdout FROM tasks WHERE id = ?", (tid,))[0]
        chk("★ 它成功了", st == "success", st)
        chk("★ 执行的是那一段代码（输出里有用例自己的标记）",
            "v11 done" in (out or ""), (out or "")[:200])

    pg.wait_for_timeout(4000)
    body = pg.inner_text(".dsapp-chat-scroll")
    chk("★★ 跑完的结果回到了对话里（成功输出同样要给到用户）",
        "执行结果 · 任务" in body, body[-300:])
    chk("★ 卡片上标了「已执行」", "已执行" in body, body[-300:])
    chk("★ 跑完之后那块「正在执行」收掉了", pg.locator(".dsapp-run-live").count() == 0)

    chk("页面上没有 JS 报错", len(errs) == 0, errs[:3])
    pg.screenshot(path=os.path.join(OUT, "item10_execute.png"), full_page=True)
    b.close()

sys.exit(chk.done())
