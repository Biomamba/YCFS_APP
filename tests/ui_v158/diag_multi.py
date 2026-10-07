#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：**一个 worker 被几个会话同时占住**的时候，旁观的那个页面会怎样。

为什么单开这一份：diag_freeze / diag_slow 都是"一个页面、一个人在动"。
那两条量下来的结论是"服务端最坏卡 5 秒、浏览器最坏掉 340ms" —— 都不够
触发「服务端没有响应」（判据是 16 秒没收到心跳）。可是线上那个用户就是
反复看到页面不能动。

线上和本地有一个**结构上的差别**，前面几个探针全都没覆盖：
    Shiny Server 下，**所有会话共用同一个 R 进程**（本地 runApp 也是），
    而它是单线程的。所以任何一个会话在重画，别的会话就得等。
用户那边的真实情形正是"一个页面开着 + 后台还有对话/任务在跑"。

这份脚本就量这个：开 3 个账号，1 个**旁观**、2 个**同时灌大流式正文**，
每 2 秒记一次旁观页的 fetch 往返 + 掉拍 + 遮罩状态。

判据（只报数，不断言）：
  · 旁观页最长多久没被服务端搭理一次；
  · 有没有跨过 16 秒（跨过了 = 用户看到的就是那条提示）。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    python3 tests/ui_v158/diag_multi.py
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

KB = 25            # 每个灌流会话吐多少 KB
STAMP = int(time.time())

# ⚠️ 卡多久**必须在页面里算**：performance.now() 的原点和 python 的
#    time.time() 不是一个原点，两边相减得到的是个看着很合理的假数
#    （diag_slow 就是这么算的，那个 stall 列别信）。
INSTRUMENT = r"""
(() => {
  window.__m = {lag: [], t0: performance.now()};
  window.__rtt = {sent: [], done: 0, stall: 0, worst: 0};
  let last = performance.now();
  setInterval(() => {
    const now = performance.now();
    const d = now - last; last = now;
    if (d > 120) window.__m.lag.push([Math.round(now), Math.round(d)]);
  }, 50);
  setInterval(() => {
    window.__rtt.sent.push(performance.now());
    fetch(location.pathname + '?_rtt=' + Date.now(), {cache: 'no-store'})
      .then(() => { window.__rtt.done++; }).catch(() => { window.__rtt.done++; });
  }, 500);
  // 每 100ms 重算一次"最老的那个还没回来的请求等了多久" = 服务端沉默时长
  setInterval(() => {
    const r = window.__rtt, pend = r.sent.length - r.done;
    r.stall = pend > 0 ? Math.round(performance.now() - r.sent[r.sent.length - pend]) : 0;
    if (r.stall > r.worst) r.worst = r.stall;
  }, 100);
  // 遮罩：出现/消失都记一笔（带时刻），事后能和灌流时间线对齐
  window.__off = []; let prev = null;
  setInterval(() => {
    const el = document.getElementById('dsapp-offline');
    const k = el ? (el.getAttribute('data-kind') || '?') : null;
    if (k !== prev) {
      window.__off.push([Math.round(performance.now()), prev, k]);
      prev = k;
    }
  }, 200);
})();
"""


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def big_stream(kb):
    """一条 kb 大小的正文，切成 120 个事件块（模拟"吐得快"的厂商）。"""
    unit = ("第 %d 段：这一段是用来把正文撑大的普通文字，里面提到 "
            "results/table.csv、`max_tokens`、figures/plot.png 这些词，"
            "长度差不多一百来字。\n\n")
    text = ""
    i = 0
    while len(text.encode()) < kb * 1024:
        i += 1
        text += unit % i
    step = max(1, len(text) // 120)
    parts = [text[i:i + step] for i in range(0, len(text), step)]
    import json as _j
    body = "".join(
        "data: " + _j.dumps({"choices": [{"delta": {"content": p},
                                           "finish_reason": None}]}) + "\n\n"
        for p in parts)
    body += ("data: " + _j.dumps({"choices": [{"delta": None,
                                               "finish_reason": "stop"}]}) + "\n\n"
             + "data: [DONE]\n\n")
    return body


def open_page(br, fx_url, tag):
    ctx = br.new_context(viewport={"width": 1440, "height": 900})
    ctx.add_init_script(INSTRUMENT)
    pg = ctx.new_page()
    C.enter_app(pg, email="v158multi%s-%s@t.local" % (tag, STAMP))
    uid, _ = C.seed_or_die(C.LAST_EMAIL)
    C.seed_llm(uid, fx_url)
    pg.reload(wait_until="domcontentloaded")
    for _ in range(120):
        pg.wait_for_timeout(1000)
        if pg.locator(".dsapp-shell").count():
            break
    C.goto(pg, "chat")
    ensure_no_modal(pg)
    pg.wait_for_timeout(1500)
    # 防火墙：地址不是本地假 LLM 就**不发消息**（记忆 seed-then-reload-and-firewall）
    C.goto(pg, "model")
    pg.wait_for_timeout(800)
    base = pg.input_value("#model-base_url") if pg.locator("#model-base_url").count() else ""
    if "127.0.0.1" not in (base or ""):
        say("‼️ uid=%s 的 base_url = %r，不是假 LLM —— 停，别打到真厂商" % (uid, base))
        sys.exit(2)
    C.goto(pg, "chat")
    ensure_no_modal(pg)
    if pg.locator(".dsapp-sess").count() == 0:
        pg.locator("text=新建对话").first.click()
        pg.wait_for_timeout(2000)
    return ctx, pg, uid


def main():
    fx = C.FakeLLM()
    say("实例 %s  fx=%s" % (C.APP, fx.url))
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        say("== 起 3 个账号（1 个旁观 + 2 个灌流）==")
        vctx, victim, vuid = open_page(br, fx.url, "a")
        c1, p1, uid1 = open_page(br, fx.url, "b")
        c2, p2, uid2 = open_page(br, fx.url, "c")
        say("   旁观 uid=%s｜灌流 uid=%s / %s" % (vuid, uid1, uid2))

        # 两条大正文轮着放（假 LLM 按请求顺序发队列里的文件，两条都是大正文）
        fx.set_queue(big_stream(KB), big_stream(KB))
        say("== 两支大流式同时开灌（各 %d KB）==" % KB)
        t0 = time.time()
        # ⚠️ 这里**不能**用 probe_ctx.send()：它内部 wait_idle 要等这一轮
        #    跑完才返回，于是第二支是在第一支结束之后才发的 —— 两支队排成
        #    一列，这份探针要测的"并发"根本不存在（第一版就是这么写的）。
        #    只填+点，不等。
        for pg, txt in ((p1, "第一支"), (p2, "第二支")):
            pg.wait_for_selector("#chat-input", timeout=30000)
            ensure_no_modal(pg)
            pg.fill("#chat-input", txt)
            try:
                pg.click("#chat-send", timeout=8000)
            except Exception:
                ensure_no_modal(pg)
                pg.click("#chat-send", timeout=25000)
        say("   两支都按下去了（t0）")

        while time.time() - t0 < 90:
            victim.wait_for_timeout(2000)
            m = victim.evaluate("() => ({lag: window.__m.lag, "
                                "rtt: window.__rtt, off: window.__off})")
            rtt = m["rtt"]
            say("   t=%3ds 旁观页：挂起 fetch %d｜**服务端已沉默 %4d ms（最久 %4d）**"
                "｜掉拍 %d（最久 %s ms）｜遮罩事件 %s"
                % (int(time.time() - t0), len(rtt["sent"]) - rtt["done"],
                   rtt["stall"], rtt["worst"], len(m["lag"]),
                   max([x[1] for x in m["lag"]], default=0),
                   m["off"] or "无"))
        for p in (p1, p2):
            try:
                p.wait_for_timeout(15000)
            except Exception:
                pass
        m = victim.evaluate("() => ({lag: window.__m.lag, "
                            "rtt: window.__rtt, off: window.__off})")
        rtt = m["rtt"]
        say("\n旁观页整轮：主线程掉拍 %d 次（最久 %s ms）｜"
            "**服务端最长沉默 %.0f ms**（16 秒判死）"
            % (len(m["lag"]), max([x[1] for x in m["lag"]], default=0), rtt["worst"]))
        say("遮罩时间线：%s" % (m["off"] or "（整轮没出现过）"))
        say("假 LLM 一共收到 %d 次请求（>0 才说明没打到真厂商）" % fx.req_n())
        victim.screenshot(path=os.path.join(C.OUT, "diag_multi_victim.png"))
        br.close()
    fx.stop()


if __name__ == "__main__":
    main()
