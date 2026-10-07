#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：**真·慢速流式**（60 秒吐 20 KB）时，服务端和浏览器各自卡多久。

和 diag_freeze.py 的分工：
  diag_freeze 的 P3 是"假 LLM 一口气吐 30 KB"—— 那是**爆发**，
  200ms 的泵最多采到十几次，量和真实用户（模型一秒吐几十个字、
  一吐一两分钟）不是一回事。

这一份复刻用户那一幕：**慢**流式。每 250ms 一个事件块、一共 250 块、
正文 20 KB，全程约 60 秒。同时量：

  ① 浏览器主线程掉拍（50ms 心跳，>120ms 记一笔）
  ② 服务端响应：每 500ms 一次 fetch，**算"连续多久没有一次响应"**
     —— 这个数超过 16 秒就是用户看到「服务端没有响应」那条提示的条件
  ③ 每 10 秒打一行进度，事后能和 /tmp/dsapp_v158h/prof.log 对齐

配合实例里那份埋点（pump / streaming / history 三个点）看。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    python3 tests/ui_v158/diag_slow.py
"""
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait  # noqa: E402

N_CHUNK = 250          # 事件块数
DELAY = 0.25           # 每块之间等多久 → 全程约 62 秒
CHARS = 80             # 每块多少字 → 正文约 20 KB

INSTRUMENT = r"""
(() => {
  window.__m = {lag: [], ticks: 0, last: performance.now()};
  setInterval(() => {
    const now = performance.now();
    const d = now - window.__m.last; window.__m.last = now; window.__m.ticks++;
    if (d > 120) window.__m.lag.push([Math.round(now), Math.round(d)]);
  }, 50);
  // 服务端响应探针：每 500ms 一次，记录**开始**时刻。响应回来的时刻
  // 由 python 那侧对齐 —— 这里只记"发出去了没回来"的那种。
  window.__rtt = {sent: [], done: 0};
  setInterval(() => {
    const t0 = performance.now();
    window.__rtt.sent.push(Math.round(t0));
    fetch(location.pathname + '?_rtt=' + Date.now(), {cache: 'no-store'})
      .then(() => { window.__rtt.done++; })
      .catch(() => { window.__rtt.done++; });
  }, 500);
})();
"""


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def main():
    fx = C.FakeLLM()
    say("实例 %s  fx=%s" % (C.APP, fx.url))
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        ctx.add_init_script(INSTRUMENT)
        pg = ctx.new_page()
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))

        C.enter_app(pg)
        uid, _ = C.seed_or_die(C.LAST_EMAIL)
        C.seed_llm(uid, fx.url)
        pg.reload(wait_until="domcontentloaded")
        for _ in range(120):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
        C.goto(pg, "chat")
        ensure_no_modal(pg)
        pg.wait_for_timeout(2000)

        # 防火墙（记忆 seed-then-reload-and-firewall）：发消息前先验地址
        C.goto(pg, "model")
        pg.wait_for_timeout(800)
        base = pg.input_value("#model-base_url") if pg.locator("#model-base_url").count() else ""
        say("模型页 base_url = %r" % base)
        if "127.0.0.1" not in (base or ""):
            say("‼️ 地址不是假 LLM，**不发消息**，直接退出（防打到真厂商）")
            br.close(); fx.stop(); sys.exit(2)
        C.goto(pg, "chat")
        ensure_no_modal(pg)

        # 先建一个对话
        if pg.locator(".dsapp-sess").count() == 0:
            pg.locator("text=新建对话").first.click()
            pg.wait_for_timeout(2000)

        # 慢速流式：250 块 × 80 字 ≈ 20 KB，每块隔 0.25 秒
        #
        # ⚠️ 不能用 C.sse_multi —— 那一支的 parts 走的是 **reasoning_content**
        #    （它是给思维链探针用的）。正文要自己拼：一块一个
        #    `delta.content` 事件，最后再补一个 finish_reason=stop 的空 delta。
        #    踩过：拿 sse_multi 当正文用，界面报「这一轮没有产出正文」。
        parts = []
        for i in range(N_CHUNK):
            parts.append(("第 %d 块：这里是一段普通的说明文字，用来模拟模型"
                          "一个词一个词往外吐的样子。\n\n" % i))
        import json as _j
        body = "".join(
            "data: " + _j.dumps({"choices": [{"delta": {"content": p},
                                               "finish_reason": None}]}) + "\n\n"
            for p in parts)
        body += ("data: " + _j.dumps({"choices": [{"delta": None,
                                                   "finish_reason": "stop"}]}) + "\n\n"
                 + "data: [DONE]\n\n")
        fx.set_queue(body)
        fx.slow(DELAY)
        # ⚠️ slow 只对**这一个**队列项生效（队列里只有这一条），
        #    下一条进来之前就会被 no_slow 掉。
        say("\n== 慢速流式开始：%d 块 × %s 秒 ≈ %.0f 秒，正文约 %d KB =="
            % (N_CHUNK, DELAY, N_CHUNK * DELAY, N_CHUNK * len(parts[0]) // 1024))

        t0 = time.time()
        send_wait(pg, "慢一点吐给我看")
        last_n = -1
        while time.time() - t0 < N_CHUNK * DELAY + 40:
            pg.wait_for_timeout(10000)
            el = int(time.time() - t0)
            m = pg.evaluate("() => window.__m ? JSON.parse(JSON.stringify(window.__m)) : null")
            rtt = pg.evaluate("() => window.__rtt")
            n = pg.evaluate("() => (document.getElementById('chat-history')||{}).innerText.length || 0")
            # 服务端"连续多久没响应"：发了但没回来的那批请求里最早的一个
            sent = rtt["sent"] if rtt else []
            done = rtt["done"] if rtt else 0
            stall = 0
            if sent and done < len(sent):
                pending = len(sent) - done
                first_pending = sent[len(sent) - pending]
                stall = (time.time() - t0) * 1000 - first_pending
            say("   t=%3ds 正文 %6d 字（+%5d）｜掉拍 %d（最久 %s ms）｜挂起的 fetch %d 个"
                "｜**服务端已经 %4.0f ms 没回过一次**"
                % (el, n, n - last_n if last_n >= 0 else 0,
                   len(m["lag"]) if m else -1,
                   max([x[1] for x in m["lag"]], default=0) if m else -1,
                   (len(sent) - done) if sent else 0, stall))
            last_n = n
            if n > 0 and "第 %d 块" % (N_CHUNK - 1) in (pg.inner_text("#chat-history")
                                                        if pg.locator("#chat-history").count() else ""):
                say("   全部吐完（用时 %.0f 秒）" % (time.time() - t0))
                break
        say("   假 LLM 收到请求 %d 次，已发事件块 %d"
            % (fx.req_n(), fx.served_n() if hasattr(fx, "served_n") else -1))
        pg.wait_for_timeout(15000)
        m = pg.evaluate("() => window.__m ? JSON.parse(JSON.stringify(window.__m)) : null")
        say("\n整轮：主线程掉拍 %d 次（最久 %s ms）｜正文最终 %d 字"
            % (len(m["lag"]) if m else -1,
               max([x[1] for x in m["lag"]], default=0) if m else -1,
               pg.evaluate("() => (document.getElementById('chat-history')||{}).innerText.length || 0")))
        pg.screenshot(path=os.path.join(C.OUT, "diag_slow_end.png"))
        br.close()
    fx.stop()


if __name__ == "__main__":
    main()
