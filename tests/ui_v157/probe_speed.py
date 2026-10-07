#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流式长回复的**卡顿基线**：先量，再改（Test_V15.7 item 1）。

用户原话：「能不能优化下结构，不影响功能的情况下，提升响应速度」。

这一版最容易出事的地方是**流式正文**：每 200ms 把**已经收到的全部正文**
重新渲染一遍（commonmark + 消毒 + 链接化），再整块 innerHTML 塞回浏览器。
正文越长，每一拍越贵，而拍数不变 —— 一篇报告写完，总工作量是 O(n²)。

⚠️⚠️ **这个脚本不改任何东西，它只负责把"改之前"量下来。** 没有基线就
   没有"提升了多少"，只有"我觉得快了" —— 而这一版里最容易骗人的正是
   这个感觉。

量四样东西，都是**浏览器侧**的（服务端快不快，用户只从这四样里感觉得到）：

  1. `longtask` 的次数和总时长 —— 主线程被占住多久（真正的"卡"）
  2. 流式期间 websocket **收到的字节数** —— 整块重发的直接代价
  3. 对话区 DOM 变动次数 —— "重画了几次"
  4. 从发送到正文画完的墙钟时间

用法：
    bash tests/ui_v7/make_instance.sh 8929 /tmp/dsapp_v157p
    python3 tests/ui_v157/probe_speed.py            # 打印基线，写 baseline.json

⚠️ 一条出网请求都不许打真厂商：账号被指向本机的假 LLM，而且发完消息
   断言假服务端**收到了**请求。
"""
import io
import json
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8929/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v157p/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v157p")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from probe_v157 import ensure_no_modal                  # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

# ---- 造一段"像报告那么长"的正文 --------------------------------------------
# 250 个事件块 × 每块约 260 字 ≈ 65 KB。分块是必须的：整段塞进一个 SSE
# 事件的话，服务端一拍就收完了，中间没有任何采样点（假绿）。
N_CHUNK = 250
CHUNK_DELAY = 0.03          # 每块 30ms → 整段流大约 8 秒


def long_body():
    parts = []
    for i in range(N_CHUNK):
        parts.append(
            "第 %d 段。差异表达分析在这一步会对每个基因计算对数倍数变化与"
            "校正后的 P 值，火山图的横轴是 log2FoldChange，纵轴是 "
            "-log10(padj)。阈值取 |log2FC| > 1 且 padj < 0.05 时，"
            "上调基因与下调基因会被分别标成两种颜色。\n\n" % (i + 1))
    return parts


# 在**页面脚本之前**装钩子。⚠️ 必须 add_init_script：Shiny 的 SockJS 在
# 页面加载后很早就把 WebSocket 拿走了，页面起来之后再 patch 就晚了。
INIT_JS = r"""
window.__sp = { lt: 0, lt_ms: 0, ws_in: 0, mut: 0 };
try {
  new PerformanceObserver(function (l) {
    var es = l.getEntries();
    for (var i = 0; i < es.length; i++) { window.__sp.lt += 1;
                                          window.__sp.lt_ms += es[i].duration; }
  }).observe({ entryTypes: ['longtask'] });
} catch (e) { window.__sp.longtask_unsupported = true; }
try {
  var OW = window.WebSocket;
  window.WebSocket = function (u, p) {
    var ws = new OW(u, p);
    ws.addEventListener('message', function (e) {
      try { window.__sp.ws_in += (e.data || '').length; } catch (_) {}
    });
    return ws;
  };
  window.WebSocket.prototype = OW.prototype;
  window.WebSocket.CONNECTING = OW.CONNECTING;
  window.WebSocket.OPEN = OW.OPEN;
  window.WebSocket.CLOSING = OW.CLOSING;
  window.WebSocket.CLOSED = OW.CLOSED;
} catch (e) { window.__sp.ws_hook_failed = true; }
"""


def main():
    fx = C.FakeLLM()
    # ⚠️ C.sse() 拼的是**一整条**应答，这里要的是**很多个事件块**。
    #    自己拼：每个块一个 delta.content，最后补 finish + [DONE]。
    import json as _j

    def chunk(o):
        return "data: " + _j.dumps(o) + "\n\n"

    body = long_body()
    s = ""
    for p in body:
        s += chunk({"choices": [{"delta": {"content": p}, "finish_reason": None}]})
    s += chunk({"choices": [{"delta": None, "finish_reason": "stop"}]})
    s += "data: [DONE]\n\n"
    fx.set_queue(s)
    fx.slow(CHUNK_DELAY)          # 不慢放的话一拍就收完，采不到中间状态
    print("  假 LLM: %s（%d 块 × %d 字 ≈ %d KB，每块 %.0fms）"
          % (fx.url, len(body), len(body[0]), sum(len(p) for p in body) // 1024,
             CHUNK_DELAY * 1000), flush=True)

    res = {}
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        ctx.add_init_script(INIT_JS)
        page = ctx.new_page()
        email = "sp_%s@example.com" % str(int(time.time()))[-6:]
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            sys.exit("注册没进去：%s" % e)
        uid, dbp = C.seed_or_die(email)
        print("  uid=%s  db=%s" % (uid, dbp), flush=True)
        C.seed_llm(uid, fx.url)
        page.reload(wait_until="domcontentloaded")
        C.wait_awake(page)
        ensure_no_modal(page)
        page.wait_for_timeout(1500)

        # 对话区变动计数（重画了几次）
        page.evaluate("""() => {
            const pane = document.querySelector('.dsapp-chat-body')
                      || document.querySelector('.dsapp-msgs')
                      || document.body;
            window.__sp.mut = 0;
            new MutationObserver((ls) => { window.__sp.mut += ls.length; })
              .observe(pane, {childList: true, subtree: true,
                              characterData: true});
            return true;
        }""")

        n0 = fx.req_n()
        box = page.query_selector("#chat-input") or page.query_selector("textarea")
        box.fill("请写一份完整的分析报告。")
        page.wait_for_timeout(300)
        t0 = time.time()
        page.query_selector("#chat-send").click()

        # 等**正文画完**：库里多出一条 assistant（落库=这一轮真的结束了）
        import sqlite3

        def last_asst():
            con = sqlite3.connect(dbp)
            try:
                r = con.execute("select max(id) from messages where "
                                "role='assistant'").fetchone()
                return r[0]
            finally:
                con.close()
        base = last_asst()
        done = False
        peak_chars = 0
        while time.time() - t0 < 180:
            page.wait_for_timeout(500)
            try:
                # ⚠️ 取**最后**一个气泡。querySelector 拿的是第一条（用户那句
                #    "请写一份完整的分析报告"），量它等于什么都没量。
                n = page.evaluate(
                    "() => { const b = document.querySelectorAll('.dsapp-bubble');"
                    " return b.length ? b[b.length-1].innerText.length : 0; }")
                peak_chars = max(peak_chars, n or 0)
            except Exception:
                pass
            if last_asst() != base:
                done = True
                break
        wall = time.time() - t0
        page.wait_for_timeout(1200)          # 让最后几拍收尾

        sp = page.evaluate("() => window.__sp")
        res = {
            "chunks": len(body),
            "body_kb": sum(len(p) for p in body) // 1024,
            "chunk_delay_ms": CHUNK_DELAY * 1000,
            "done": done,
            "wall_sec": round(wall, 2),
            "longtask_n": sp.get("lt"),
            "longtask_ms": round(sp.get("lt_ms", 0), 1),
            "ws_in_kb": round(sp.get("ws_in", 0) / 1024.0, 1),
            "dom_mutations": sp.get("mut"),
            "peak_chars": peak_chars,
            "req_delta": fx.req_n() - n0,
        }
        page.screenshot(path=os.path.join(C.OUT, "speed.png"), full_page=False)
        browser.close()
    fx.stop()

    print("\n== 基线 ==")
    for k in ("body_kb", "wall_sec", "longtask_n", "longtask_ms", "ws_in_kb",
              "dom_mutations", "peak_chars", "req_delta", "done"):
        print("  %-16s %s" % (k, res.get(k)), flush=True)

    # ★ 这一条不是"顺便"，是**前提**：假服务端没收到请求 = 打去了真厂商。
    if res["req_delta"] <= 0:
        sys.exit("假服务端一个请求都没收到 —— 请求打去真厂商了，立刻停。")
    if not res["done"]:
        sys.exit("等了 180 秒那条回复也没落库，这一轮没跑完，基线的数不可信。")

    out = os.path.join(C.OUT, "speed_baseline.json")
    with io.open(out, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(res, ensure_ascii=False, indent=2))
    print("\n写到 %s" % out, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
