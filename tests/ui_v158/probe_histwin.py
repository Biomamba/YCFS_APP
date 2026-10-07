#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量「打开一个几十条的长对话」这一包推了多少字节（V15.11 的第二半）。

背景（2026-10-03 线上取证，只读）：用户那三个最长的对话，
`output$history` 整体渲染出来分别是 **1158 KB / 718 KB / 462 KB** HTML。
而它**每写一条消息、每次 run_cid()/hist_ver()/msg_rev 变化都要整体重渲染**
—— 一轮对话里三四次。用户那条链路实测 ~50 KB/s（RTT 80ms、重传 12%、
cwnd 3），1158 KB ÷ 50 KB/s ≈ **23 秒**，而 node 那侧 SockJS 心跳只给 10 秒
等 pong：超时 → `session.close(3000)`（**干净关闭**）→ 客户端对干净关闭是
**故意不重连**的（shiny-server-client lib/decorators/reconnect.js）→ 自愈
整页重载 → 冷启 worker + 重新下载页面 = 用户看到的**黑屏**。

V15.11 给历史加了窗口（末尾一段 + 「显示更早的消息」），这个脚本量的是
**接线之后**的真实效果，不是 R 层算出来的那个数：
  · 打开长对话这一包，浏览器实际收到多少字节 / 最大一帧多大
  · 页面上真的只画了几条气泡、有没有那颗「显示更早的消息」
  · 点它一次，增量是多少（应该是一份预算，不是"再来 15 条"）
  · 最后一条回复**必须完整**（保底规则：眼前这一轮不许被窗口切掉）
  · 全程有没有 WebSocket close / 整页重载 / 「断联」遮罩

A/B 用法（两个实例，同一份种子数据）：
    # 基线：11:35 那份拷贝，R/ 里还没有 dsapp_hist_window
    DSAPP_TEST_URL=http://127.0.0.1:8961/ DSAPP_TEST_APP=/tmp/dsapp_bytes/app \
      python3 tests/ui_v158/probe_histwin.py
    # 改后：现仓库的拷贝
    DSAPP_TEST_URL=http://127.0.0.1:8962/ DSAPP_TEST_APP=/tmp/dsapp_hw/app \
      python3 tests/ui_v158/probe_histwin.py

⚠️ 直接往实例库写消息（sqlite3）。实例的 DSAPP_DATA_ROOT 由 _common.guard
   核过必须在 /tmp 下 —— 写生产库这件事在这个脚本里走不通，这是故意的。
⚠️ 种完必须 **reload**：会话列表/state 是页面**加载那一刻**读的。
"""
import json
import os
import re
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8962/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_hw/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

N_MSG = int(os.environ.get("DSAPP_HW_MSGS", "74"))      # 消息条数（用户那个最长的是 74）
BIG_KB = int(os.environ.get("DSAPP_HW_BIG_KB", "25"))   # 大回复的正文 KB 数
# 其余回复的 KB 数。6 → 总量约 260 KB；11 → 约 430 KB，和用户那个最长的
# （74 条 / 429 503 字）**同一个量级** —— 这一节量的是字节数，夹具就得
# 在量级上对得上，不然"改前 1158 KB"这个基线根本复现不出来。
FILL_KB = int(os.environ.get("DSAPP_HW_FILL_KB", "11"))
WATCH_S = int(os.environ.get("DSAPP_HW_WATCH", "40"))
TITLE = "长对话压测_%d" % int(time.time())


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def para(n_kb):
    """造一段 n_kb 量级的 markdown 正文（标题/列表/代码块/表格/段落都有）。"""
    parts, i = [], 0
    while sum(len(p) for p in parts) < n_kb * 1024:
        k = i % 5
        if k == 0:
            parts.append("## 第 %d 节 结果解读\n\n样本量 N=%d，主要指标较基线上升 "
                         "12.3%%，置信区间 [1.1, 3.2]，p<0.01。\n\n" % (i // 5 + 1, 100 + i))
        elif k == 1:
            parts.append("- 差异表达基因 %d 个（上调 %d / 下调 %d）\n"
                         "- 富集到通路 %d 条，其中 FDR<0.05 的 %d 条\n\n"
                         % (i * 7, i * 3, i * 4, i, i // 2))
        elif k == 2:
            parts.append("```r\nres_%d <- lm(y ~ x + batch, data = df)\n"
                         "summary(res_%d)$coefficients\n```\n\n" % (i, i))
        elif k == 3:
            parts.append("| 指标 | 处理组 | 对照组 | FC |\n|---|---|---|---|\n"
                         "| mRNA_%d | %.2f | %.2f | %.2f |\n\n" % (i, i * 1.1, i * 0.9, 1.22))
        else:
            parts.append("从上面的结果看，第 %d 组与对照的分离主要由批次效应驱动，"
                         "建议下一轮把 batch 放进协变量，并对低表达基因做一次过滤。\n\n" % i)
        i += 1
    return "".join(parts)


def seed_long(uid, db_path):
    """给 uid 种一个 N_MSG 条的长对话，正文总量贴近用户那个最长的（约 430 KB）。

    ⚠️ 正文里**必须**有一条特别长的（BIG_KB）—— 预算和保底规则的相互作用
       只有在这种数据上才看得出来。
    """
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    sid = "s-pt-%d" % int(time.time())
    big = para(BIG_KB)
    rows = []
    for i in range(N_MSG):
        if i % 2 == 0:
            rows.append(("user", "第 %d 步：帮我把这一步的分析做完，"
                                 "顺便解释一下图上那个离群点。\n" % (i // 2 + 1)))
        elif i in (N_MSG - 3, N_MSG - 5):
            rows.append(("assistant", big))          # 一条大回复
        else:
            rows.append(("assistant", para(FILL_KB)))
    con = sqlite3.connect(db_path, timeout=10)
    # ⚠️⚠️ 还要种一个**小的落地会话**，而且要比长对话更新 —— 应用进对话页时
    #    会自动选中"最近更新的那个"。不种它的话，长对话在**页面加载**时就已经
    #    整体渲染完了（计数器还没清零），量到的就是"点开这一下 3.5 KB、最大帧
    #    0 KB"—— 看着像"这一版把历史改没了"，其实是**没量到**。第一版就栽在
    #    这儿：页面上明明 74 条气泡，而 WS 只有 222 个小于 200 字节的心跳帧。
    small = sid + "-small"
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id) "
                "VALUES (?,?,?,?,?)", (small, "落地会话", now, now, uid))
    con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                "VALUES (?,?,?,?,NULL)", (small, "user", "先放一个短对话在这儿。", now))
    con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                "VALUES (?,?,?,?,NULL)", (small, "assistant", "好，随时开始。", now))
    # 长对话的时间戳往回拨一点：排序上必须**不是**最近的那个。
    older = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 3600))
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id) "
                "VALUES (?,?,?,?,?)", (sid, TITLE, older, older, uid))
    for k, (role, content) in enumerate(rows):
        con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                    "VALUES (?,?,?,?,NULL)", (sid, role, content, now))
    con.commit()
    tot = con.execute("SELECT sum(length(content)) FROM messages WHERE session_id=?",
                      (sid,)).fetchone()[0]
    con.close()
    say("  种好：%s  %d 条消息 / 正文 %d 字（%.0f KB）" % (sid, N_MSG, tot, tot / 1024))
    return sid, tot


# 页面侧：记 WS 帧的到达时刻/大小 + close/nav。和 probe_streambytes.py 同一套
# （本仓的规矩：这些脚本要能单独拷走，宁可抄一份也不跨文件 import）。
INIT = r"""
(function(){
  window.__ws = {n:0, bytes:0, big:[], closes:[], hist:{}};
  var W = window.WebSocket;
  function wrap(ws){
    try {
      ws.addEventListener('message', function(e){
        var b = (typeof e.data === 'string') ? e.data.length
                                             : (e.data && e.data.byteLength) || 0;
        window.__ws.n++; window.__ws.bytes += b;
        if (b > 1024 && window.__ws.big.length < 4000) window.__ws.big.push(b);
        var k = b < 200 ? '<200' : b < 1024 ? '<1K' : b < 4096 ? '<4K'
              : b < 16384 ? '<16K' : b < 65536 ? '<64K'
              : b < 262144 ? '<256K' : '>=256K';
        window.__ws.hist[k] = (window.__ws.hist[k] || 0) + 1;
      });
      ws.addEventListener('close', function(e){
        window.__ws.closes.push([e.code, (e.reason||'').slice(0,60), e.wasClean]);
      });
    } catch(err){ window.__ws.err = String(err); }
  }
  function Patched(url, protocols){
    var ws = (protocols === undefined) ? new W(url) : new W(url, protocols);
    wrap(ws); return ws;
  }
  Patched.prototype = W.prototype;
  ['CONNECTING','OPEN','CLOSING','CLOSED'].forEach(function(k){ Patched[k] = W[k]; });
  window.WebSocket = Patched;
})();
"""

STATE = """() => {
  var d = document.getElementById('dsapp-offline');
  var rows = document.querySelectorAll('.dsapp-sess');
  var more = document.querySelector('.dsapp-hist-more-link');
  var bub = document.querySelectorAll('.dsapp-msg');
  var txt = [];
  bub.forEach(function(b){ txt.push((b.innerText||'').length); });
  return {
    off: d ? d.getAttribute('data-kind') : null,
    ws: JSON.parse(JSON.stringify(window.__ws || {})),
    sess: rows.length,
    more: more ? more.innerText : null,
    bubbles: bub.length,
    first_text: txt.length ? txt[0] : 0,
    last_text: txt.length ? txt[txt.length-1] : 0,
    body: (document.body.innerText || '').length
  };
}"""


def snap(pg, say, tag):
    st = pg.evaluate(STATE)
    ws = st["ws"]
    bigs = ws.get("big", [])
    say("  [%s] 收 %7.1f KB / %d 帧 | 最大帧 %7.1f KB | 气泡 %2d 条 | "
        "「更早」=%s | 末条 %d 字 | 遮罩=%s"
        % (tag, ws["bytes"] / 1024.0, ws["n"],
           (max(bigs) / 1024.0) if bigs else 0.0, st["bubbles"],
           (st["more"] or "无")[:28], st["last_text"], st["off"]))
    return st


def main():
    db = os.path.join(C.DATA_ROOT, "dsapp.sqlite3")
    say("实例 %s  端口 %s" % (C.APP, re.search(r":(\d+)", C.URL).group(1)))
    say("实例库 %s" % db)
    if not os.path.exists(db):
        sys.exit("实例库不存在：%s" % db)

    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))
        navs = []
        pg.on("framenavigated",
              lambda f: navs.append(f.url) if f == pg.main_frame else None)
        pg.add_init_script(INIT)

        C.enter_app(pg, email="hw_%d@example.com" % int(time.time()))
        uid, _ = C.seed_or_die(C.LAST_EMAIL)
        sid, tot = seed_long(uid, db)

        # 种完必须 reload：会话列表是页面加载那一刻读的（老账：种库不 reload，
        # 界面照旧，看着像"种库失败"）。
        pg.reload(wait_until="domcontentloaded")
        for _ in range(120):
            pg.wait_for_timeout(500)
            if pg.locator(".dsapp-shell").count():
                break
        C.goto(pg, "chat")
        ensure_no_modal(pg)
        # ⚠️ 这里**不能**用一个固定秒数等：侧栏是 renderUI，刚 reload 过的
        #    worker 要跑完建库/migrate + 一堆读库的渲染才画得出来。写 1.5 秒
        #    的那一版在实例上量到的是"侧栏 0 行、页面 240 字"——看着像**种库
        #    没生效**，其实只是页面还没画完（本仓老账："等一行出现"写成"查得到
        #    行"= 没等）。
        row = pg.locator(".dsapp-sess", has_text=TITLE).first
        for _ in range(60):                       # 最多等 60 秒
            if row.count():
                break
            pg.wait_for_timeout(1000)
        if not row.count():
            st = pg.evaluate(STATE)
            sys.exit("侧栏里没有种进去的那个对话（侧栏 %d 行，页面 %d 字）"
                     % (st["sess"], st["body"]))
        say("侧栏里找到了「%s」" % TITLE)

        # 计数器清零：只量**点开这个对话**这一下的流量
        pg.evaluate("() => { window.__ws = {n:0,bytes:0,big:[],closes:[],hist:{}}; }")
        nav0 = len(navs)
        t0 = time.time()
        say("\n=== 点开长对话（%d 条 / %.0f KB 正文）===" % (N_MSG, tot / 1024))
        row.click()
        best = None
        while time.time() - t0 < WATCH_S:
            pg.wait_for_timeout(2000)
            st = snap(pg, say, "%2ds" % (time.time() - t0))
            if best is None or st["bubbles"] > best["bubbles"]:
                best = st
            if st["bubbles"] and st["ws"]["n"] > 0 and \
               st["ws"]["bytes"] == best.get("_b", -1) and time.time() - t0 > 8:
                pass
            best["_b"] = st["ws"]["bytes"]
        st1 = pg.evaluate(STATE)

        say("\n=== 结果（打开这一下）===")
        say("浏览器收到的 WS 字节 : %.1f KB（%d 帧）"
            % (st1["ws"]["bytes"] / 1024.0, st1["ws"]["n"]))
        say("帧大小分布           : %s" % json.dumps(st1["ws"].get("hist", {}),
                                                     ensure_ascii=False))
        bigs = sorted(st1["ws"].get("big", []), reverse=True)
        say("最大 5 帧            : %s"
            % json.dumps([round(b / 1024.0, 1) for b in bigs[:5]]))
        say("页面上的气泡         : %d 条（种子是 %d 条）" % (st1["bubbles"], N_MSG))
        say("「显示更早的消息」   : %s" % (st1["more"] or "**没有**"))
        say("第一条气泡正文       : %d 字" % st1["first_text"])
        say("最后一条气泡正文     : %d 字" % st1["last_text"])
        say("WS close / 整页重载  : %s / %d 次"
            % (json.dumps(st1["ws"].get("closes", [])), len(navs) - nav0))
        say("遮罩                 : %s" % st1["off"])
        pg.screenshot(path=os.path.join(C.OUT, "probe_histwin_open.png"))

        if st1["more"]:
            say("\n=== 点一次「显示更早的消息」===")
            pg.evaluate("() => { window.__ws = {n:0,bytes:0,big:[],closes:[],hist:{}}; }")
            nav1 = len(navs)
            pg.click(".dsapp-hist-more-link")
            t1 = time.time()
            while time.time() - t1 < WATCH_S:
                pg.wait_for_timeout(2000)
                st = snap(pg, say, "%2ds" % (time.time() - t1))
                if time.time() - t1 > 10 and st["ws"]["bytes"] == best.get("_b2", -1):
                    break
                best["_b2"] = st["ws"]["bytes"]
            st2 = pg.evaluate(STATE)
            say("增量                 : %.1f KB，气泡 %d → %d 条"
                % (st2["ws"]["bytes"] / 1024.0, st1["bubbles"], st2["bubbles"]))
            say("这次最大帧           : %.1f KB"
                % (max(st2["ws"].get("big", [0]) or [0]) / 1024.0))
            say("WS close / 整页重载  : %s / %d 次"
                % (json.dumps(st2["ws"].get("closes", [])), len(navs) - nav1))
            pg.screenshot(path=os.path.join(C.OUT, "probe_histwin_more.png"))

        br.close()


if __name__ == "__main__":
    main()
