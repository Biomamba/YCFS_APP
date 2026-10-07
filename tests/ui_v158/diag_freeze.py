#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：**页面未响应**到底卡在哪一侧（只观察，不断言）。

用户原话（2026-10-02 晚，V15.9 上线之后）：
    「我看到你更新到15.9了，但是还是会出现页面未响应的状态」

线上取证：uid=11 的会话 `s-20261001160555-8251`，43 条消息 / 203 KB，
最大单条 18880 字；最后一条活动是 22:34:41（一条 3 秒就成功了的任务）。
用户 22:33:49 和 22:35:57 连着两次「页面加载」—— 他在**手动刷新**。

这个脚本把**那个会话原样搬进本地实例**，然后同时量三样东西：

  ① 浏览器主线程：50ms 的心跳滴答，掉拍 > 120ms 就记一笔（"页面未响应"
     在用户那边就是这一侧的直观感受）；
  ② 服务端：每秒一次 `fetch` 往返。R worker 被某个渲染卡住时，这个数会
     整段鼓起来 —— 它就是"服务端没响应"那块提示的判据本身；
  ③ DOM：`#chat-history` 被重画了多少次。

分三段量：打开这个重会话 / 干放着 / 发一条让假 LLM 吐 30 KB。

⚠️ 只观察、不断言。这个脚本的产出是"卡在哪一侧、卡多久"，不是"过没过"。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    python3 tests/ui_v158/diag_freeze.py
"""
import json
import os
import re
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

PROD_DB = "/data3/biomamba/analysis/DS_App/data/dsapp.sqlite3"
SRC_SID = "s-20261001160555-8251"      # 用户那个 43 条 / 203 KB 的会话

# ⚠️ 量尺必须在**页面脚本之前**装好（init script），否则导航一次就没了。
INSTRUMENT = r"""
(() => {
  window.__m = {lag: [], long: [], rtt: [], mut: 0, ticks: 0,
                last: performance.now(), t0: performance.now()};
  setInterval(() => {
    const now = performance.now();
    const d = now - window.__m.last;
    window.__m.last = now;
    window.__m.ticks++;
    if (d > 120) window.__m.lag.push([Math.round(now), Math.round(d)]);
  }, 50);
  try {
    new PerformanceObserver(l => {
      for (const e of l.getEntries())
        window.__m.long.push([Math.round(e.startTime), Math.round(e.duration)]);
    }).observe({entryTypes: ['longtask']});
  } catch (e) { window.__m.longtask_err = String(e); }
  setInterval(async () => {
    const t0 = performance.now();
    try { await fetch(location.pathname + '?_rtt=' + Date.now(), {cache: 'no-store'}); }
    catch (e) { window.__m.rtt.push([Math.round(t0), -1]); return; }
    const d = performance.now() - t0;
    if (d > 300) window.__m.rtt.push([Math.round(t0), Math.round(d)]);
  }, 1000);
  // #chat-history 一出现就盯着它被改了多少次
  const watch = setInterval(() => {
    const h = document.getElementById('chat-history');
    if (!h) return;
    clearInterval(watch);
    new MutationObserver(ms => { window.__m.mut += ms.length; })
      .observe(h, {childList: true, subtree: true});
  }, 200);
})();
"""


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def clone_session(uid):
    """把线上那个会话的 43 条消息原样插进实例库、挂在这个测试账号名下。

    ⚠️ 生产库**只读**打开（`mode=ro`）。只搬 content/reasoning/role/时间，
    不搬 id —— 消息 id 是 AUTOINCREMENT，插进去自然发新的。"""
    ins = sqlite3.connect(C.db_path())
    prod = sqlite3.connect("file:%s?mode=ro" % PROD_DB, uri=True)
    t = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    sid = "s-clone-%d" % int(time.time())
    ins.execute("delete from sessions where id=?", (sid,))
    ins.execute("insert into sessions (id,title,created_at,updated_at,user_id)"
                " values (?,?,?,?,?)",
                (sid, "【搬来的重会话】" + SRC_SID, t, t, uid))
    rows = prod.execute(
        "select role, content, reasoning, created_at from messages"
        " where session_id=? order by id", (SRC_SID,)).fetchall()
    ins.executemany(
        "insert into messages (session_id, role, content, created_at, reasoning)"
        " values (?,?,?,?,?)",
        [(sid, r[0], r[1], r[3], r[2]) for r in rows])
    ins.commit()
    n = ins.execute("select count(*) from messages where session_id=?",
                    (sid,)).fetchone()[0]
    tot = ins.execute("select sum(length(content)) from messages where session_id=?",
                      (sid,)).fetchone()[0]
    ins.close(); prod.close()
    say("搬完：%s —— %d 条 / %s 字符（uid=%s）" % (sid, n, tot, uid))
    return sid


def snap(pg):
    try:
        return pg.evaluate("() => window.__m ? JSON.parse(JSON.stringify(window.__m)) : null")
    except Exception:
        return None


def report(tag, pg, base):
    m = snap(pg)
    if m is None:
        say("  [%s] 量尺没了（导航过？）" % tag)
        return
    lag = [x for x in m["lag"] if x[0] > base]
    lng = [x for x in m["long"] if x[0] > base]
    rtt = [x for x in m["rtt"] if x[0] > base]
    say("  [%s] 主线程掉拍 %d 次（最久 %s ms）｜长任务 %d 个（最久 %s ms）"
        "｜fetch 慢 %d 次（最久 %s ms）｜history 改动 %d 次"
        % (tag, len(lag), max([x[1] for x in lag], default=0),
           len(lng), max([x[1] for x in lng], default=0),
           len(rtt), max([x[1] for x in rtt], default=0), m["mut"]))
    for x in sorted(lng, key=lambda v: -v[1])[:5]:
        say("       长任务 @%dms 持续 %dms" % (x[0], x[1]))
    for x in sorted(rtt, key=lambda v: -v[1])[:5]:
        say("       fetch   @%dms 用了 %dms" % (x[0], x[1]))


def main():
    fx = C.FakeLLM()
    say("实例 %s  fx=%s" % (C.APP, fx.url))
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        ctx.add_init_script(INSTRUMENT)
        pg = ctx.new_page()
        pg.on("console", lambda m: say("  console.%-7s %s" % (m.type, m.text[:160]))
              if m.type in ("error", "warning") else None)
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))

        C.enter_app(pg)
        uid, _ = C.seed_or_die(C.LAST_EMAIL)
        sid = clone_session(uid)
        C.seed_llm(uid, fx.url)
        pg.reload(wait_until="domcontentloaded")
        for _ in range(120):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
        C.goto(pg, "chat")
        ensure_no_modal(pg)
        pg.wait_for_timeout(2000)

        # ---------- P1：点开这个重会话 ----------
        say("\n== P1 点开那个 43 条 / 203 KB 的会话 ==")
        base = pg.evaluate("() => Math.round(performance.now())")
        t0 = time.time()
        row = pg.locator(".dsapp-sess[data-sid='%s']" % sid)
        say("   会话行 %d 个" % row.count())
        if row.count() == 0:
            say("   ⚠️ 侧栏里没有这一行，退回去看 shell/会话列表")
        else:
            row.first.scroll_into_view_if_needed()
            row.first.click()
        try:
            pg.wait_for_selector("#chat-history .dsapp-msg", timeout=120000)
            say("   点下去到画出第一条消息：%.1f 秒" % (time.time() - t0))
        except Exception as e:
            say("   120 秒都没画出来：%s" % str(e).splitlines()[0])
        pg.wait_for_timeout(15000)
        report("P1 打开后 15 秒", pg, base)
        say("   正文长度：%d 字"
            % len(pg.evaluate("() => (document.getElementById('chat-history')||{}).innerText || ''")))

        # ---------- P2：干放着 ----------
        say("\n== P2 什么都不做，放 20 秒（看有没有人自己在烧 CPU）==")
        base = pg.evaluate("() => Math.round(performance.now())")
        pg.wait_for_timeout(20000)
        report("P2 静置", pg, base)

        # ---------- P3：让假 LLM 吐一条大的 ----------
        say("\n== P3 发一条，假 LLM 吐 200 个事件 / 约 30 KB ==")
        parts = []
        for i in range(200):
            parts.append("第 %d 段：这是一段用来把正文撑大的文字，"
                         "里面还带一个代码块。\n\n```python\nprint(%d)\n```\n\n" % (i, i))
        fx.set_queue(C.sse(content="".join(parts)))
        base = pg.evaluate("() => Math.round(performance.now())")
        t0 = time.time()
        send_wait(pg, "撑大它")
        for i in range(60):
            pg.wait_for_timeout(2000)
            m = snap(pg)
            n = pg.evaluate("() => (document.getElementById('chat-history')||{}).innerText.length || 0")
            say("   t=%3ds 正文 %6d 字｜掉拍 %d｜长任务 %d｜fetch 慢 %d"
                % (int(time.time() - t0), n,
                   len([x for x in m["lag"] if x[0] > base]),
                   len([x for x in m["long"] if x[0] > base]),
                   len([x for x in m["rtt"] if x[0] > base])))
            if "第 199 段" in (pg.inner_text("#chat-history") if pg.locator("#chat-history").count() else ""):
                say("   全部吐完了")
                break
        say("   假 LLM 收到请求 %d 次" % fx.req_n())
        pg.wait_for_timeout(5000)
        report("P3 流式期间", pg, base)
        pg.screenshot(path=os.path.join(C.OUT, "diag_freeze_end.png"))
        br.close()
    fx.stop()


if __name__ == "__main__":
    main()
