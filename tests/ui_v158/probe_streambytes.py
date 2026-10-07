#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量「一次长回复，服务端往浏览器推了多少字节」+ 慢链路下的积压。

背景（2026-10-03 线上取证）：用户的链路 RTT 80ms、重传 12%、cwnd 塌到 3，
实测吞吐 ~50 KB/s。而 output$streaming 每 200ms 把**整条消息**重渲染一遍
发过去 —— 单条 29 KB 的回复渲染出来 41 KB HTML，60 秒的回复就是
几百拍 × 平均 20 KB ≈ 数 MB。链路被灌爆 → 服务端发送队列积压 →
① 应用层心跳（4s 一次）被排队拖到 16s 判据之外 → 界面显示"断联"；
② node 的 SockJS 心跳 25s 一次、10s 内收不到 pong 就 close(3000)（干净关闭）
   —— 而客户端对**干净关闭**是**故意不重连**的（decorators/reconnect.js:
   `if (!this._stayClosed && (!e.wasClean || ...))`），于是走自愈 → 整页重载
   → 冷启 worker + 重新下载页面 = 用户看到的"黑屏"。

这个脚本只**量**不断言：
  · WS 收到的总字节 / 峰值速率
  · 实例那条 TCP 连接的 Send-Q 峰值（= 服务端积压）
  · 相邻两帧之间的最大间隔（= 界面"哑掉"多久）
  · WebSocket close 的 code/reason/wasClean、导航次数（= 有没有整页重载）

用法：
    bash tests/ui_v7/make_instance.sh 8961 /tmp/dsapp_bytes
    python3 tests/ui_v158/probe_streambytes.py
    # 慢链路参数可调：
    DSAPP_NET_KBPS=50 DSAPP_NET_LAT=80 python3 tests/ui_v158/probe_streambytes.py
"""
import json
import os
import re
import subprocess
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8961/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_bytes/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

PORT = int(re.search(r":(\d+)", C.URL).group(1))
KBPS = float(os.environ.get("DSAPP_NET_KBPS", "50"))    # 单向吞吐 KB/s
LAT = int(os.environ.get("DSAPP_NET_LAT", "80"))        # 单向延迟 ms
WATCH_S = int(os.environ.get("DSAPP_WATCH_S", "240"))   # 最多观察多久
CHUNKS = int(os.environ.get("DSAPP_CHUNKS", "100"))     # 假 LLM 吐多少块
CHUNK_DELAY = float(os.environ.get("DSAPP_CHUNK_DELAY", "0.25"))
LOG = os.path.join(os.path.dirname(C.APP), "streambytes_%d.log" % int(time.time()))


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def sse_stream(parts):
    """**很多个** content 分片，配 fx.slow() 才是真的"一个字一个字吐"。"""
    out = ""
    for p in parts:
        out += "data: " + json.dumps(
            {"choices": [{"delta": {"content": p}, "finish_reason": None}]}) + "\n\n"
    out += "data: " + json.dumps(
        {"choices": [{"delta": None, "finish_reason": "stop"}]}) + "\n\n"
    return out + "data: [DONE]\n\n"


def make_content(n):
    """造一段长度可控、结构像真回复的 markdown（标题/列表/代码块/表格/段落）。"""
    parts, i = [], 0
    while i < n:
        k = i % 5
        if k == 0:
            parts.append("## 第 %d 节 结果解读\n\n" % (i // 5 + 1)
                         + "样本量 N=%d，主要指标较基线上升 12.3%%，"
                           "置信区间 [%.1f, %.1f]，p<0.01。\n\n" % (100 + i, i * 0.7, i * 0.9 + 3))
        elif k == 1:
            parts.append("- 差异表达基因 %d 个（上调 %d / 下调 %d）\n"
                         "- 富集到通路 %d 条，其中 FDR<0.05 的 %d 条\n" % (i * 7, i * 3, i * 4, i, i // 2))
        elif k == 2:
            parts.append("```r\nres_%d <- lm(y ~ x + batch, data = df)\n"
                         "summary(res_%d)$coefficients\n```\n\n" % (i, i))
        elif k == 3:
            parts.append("| 指标 | 处理组 | 对照组 | FC |\n|---|---|---|---|\n"
                         "| mRNA_%d | %.2f | %.2f | %.2f |\n\n" % (i, i * 1.1, i * 0.9, 1.22))
        else:
            parts.append("从上面的结果看，第 %d 组与对照的分离主要由批次效应驱动，"
                         "建议在下一轮分析里把 batch 放进协变量，"
                         "并对低表达基因做一次过滤。\n\n" % i)
        i += 1
    return parts


# 页面侧：把 WebSocket 包一层，记下**到达时刻**（帧间隔 = 界面哑掉多久）、
# 字节数和 close 的 code/reason/wasClean。
INIT = r"""
(function(){
  window.__ws = {n:0, bytes:0, last:0, maxgap:0, closes:[], t0:performance.now(),
                 big:[], hist:{}};
  var W = window.WebSocket;
  function wrap(ws){
    try {
      ws.addEventListener('message', function(e){
        var t = performance.now();
        var b = (typeof e.data === 'string') ? e.data.length
                                             : (e.data && e.data.byteLength) || 0;
        window.__ws.n++; window.__ws.bytes += b;
        // 大于 1KB 的帧 = 服务端在推**内容**（而不是心跳）；留 (时刻, 大小)
        if (b > 1024 && window.__ws.big.length < 4000)
          window.__ws.big.push([Math.round(t - window.__ws.t0), b]);
        var k = b < 200 ? '<200' : b < 1024 ? '<1K' : b < 4096 ? '<4K'
              : b < 16384 ? '<16K' : b < 65536 ? '<64K' : '>=64K';
        window.__ws.hist[k] = (window.__ws.hist[k] || 0) + 1;
        if (window.__ws.last) {
          var g = t - window.__ws.last;
          if (g > window.__ws.maxgap) window.__ws.maxgap = g;
        }
        window.__ws.last = t;
      });
      ws.addEventListener('close', function(e){
        window.__ws.closes.push([Math.round(performance.now()),
                                 e.code, (e.reason||'').slice(0,60), e.wasClean]);
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
  window.__nav = 0;
  window.__ev = {};
  (function hook(){
    if (!window.jQuery) { setTimeout(hook, 5); return; }
    var d = window.jQuery(document);
    d.on('shiny:connected', function(){ window.__ev.connected = Math.round(performance.now()); });
    d.on('shiny:disconnected', function(){ (window.__ev.disconnected =
        window.__ev.disconnected || []).push(Math.round(performance.now())); });
    d.on('shiny:error', function(){ (window.__ev.err = window.__ev.err || []).push(1); });
  })();
})();
"""

STATE = """() => {
  var d = document.getElementById('dsapp-offline');
  var cur = document.querySelector('.dsapp-cursor');
  var bub = document.querySelectorAll('.dsapp-msg-assistant .dsapp-bubble');
  var last = bub.length ? bub[bub.length-1] : null;
  return {
    off: d ? d.getAttribute('data-kind') : null,
    ws: JSON.parse(JSON.stringify(window.__ws || {})),
    ev: window.__ev || {},
    cursor: !!cur,
    bubbles: bub.length,
    last_html: last ? last.innerHTML.length : 0,
    last_text: last ? (last.innerText || '').length : 0,
    body: (document.body.innerText || '').length
  };
}"""


def sendq(port):
    """实例那条连接的 Send-Q（服务端还有多少字节没发出去）。"""
    try:
        out = subprocess.run(["ss", "-tn", "state", "established"],
                             stdout=subprocess.PIPE).stdout.decode()
    except Exception:
        return []
    qs = []
    for ln in out.splitlines():
        if ":%d " % port in ln:
            f = ln.split()
            try:
                qs.append(int(f[2]))
            except Exception:
                pass
    return qs


def main():
    parts = make_content(CHUNKS)
    total_chars = sum(len(p) for p in parts)
    fx = C.FakeLLM()
    fx.set_queue(sse_stream(parts))
    fx.slow(CHUNK_DELAY)
    say("实例 %s 端口 %d  fx=%s" % (C.APP, PORT, fx.url))
    say("这次的回复：%d 片 × 约 %d 字 = %d 字，片间隔 %.2fs（约 %.0f 秒吐完）"
        % (len(parts), total_chars // len(parts), total_chars,
           CHUNK_DELAY, len(parts) * CHUNK_DELAY))

    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))
        navs = []
        pg.on("framenavigated",
              lambda f: navs.append(f.url) if f == pg.main_frame else None)
        pg.add_init_script(INIT)

        # ⚠️ 每跑一次换一个邮箱：_common.EMAIL 是写死的，同一个实例上跑第二遍
        #    会撞"邮箱已注册"，然后卡在注册页面上（报出来是"页面文字 0 字"，
        #    看着像应用坏了，其实是测试自己的问题）。
        C.enter_app(pg, email="bytes_%d@example.com" % int(time.time()))
        uid, _ = C.seed_or_die(C.LAST_EMAIL)
        C.seed_llm(uid, fx.url)
        pg.reload(wait_until="domcontentloaded")
        for _ in range(120):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
        C.goto(pg, "chat")
        ensure_no_modal(pg)

        # 链路整形：登录/建号那一段不掐，只掐"回复流式输出"这一段（复现用户现场）
        cdp = ctx.new_cdp_session(pg)
        cdp.send("Network.enable")
        recv = {"n": 0, "b": 0}
        sent = {"n": 0, "b": 0}
        cdp.on("Network.webSocketFrameReceived",
               lambda p: (recv.__setitem__("n", recv["n"] + 1),
                          recv.__setitem__("b", recv["b"] + len(p.get("response", {}).get("payloadData", "")))))
        cdp.on("Network.webSocketFrameSent",
               lambda p: (sent.__setitem__("n", sent["n"] + 1),
                          sent.__setitem__("b", sent["b"] + len(p.get("response", {}).get("payloadData", "")))))
        cdp.send("Network.emulateNetworkConditions",
                 {"offline": False, "latency": LAT,
                  "downloadThroughput": int(KBPS * 1024),
                  "uploadThroughput": int(KBPS * 1024),
                  "connectionType": "cellular3g"})
        say("已把这条页面限速到 单向 %.0f KB/s、延迟 %d ms" % (KBPS, LAT))
        pg.wait_for_timeout(1000)
        # 限速生效的判据：让页面自己发一次请求，量它花了多久（不该是毫秒级）
        t_probe = pg.evaluate("""async () => {
          const t0 = performance.now();
          try { await fetch(location.pathname + '?_throttle_probe=' + Date.now(),
                            {cache:'no-store'}); } catch(e) { return -1; }
          return Math.round(performance.now() - t0);
        }""")
        say("限速自检：页面自己发一次请求花了 %s ms（未被限速会是毫秒级 → 说明判据没劲）" % t_probe)

        pg.evaluate("() => { window.__ws = {n:0,bytes:0,last:0,maxgap:0,closes:[],"
                    "t0:performance.now(),big:[],hist:{}}; }")
        recv.update({"n": 0, "b": 0})
        sent.update({"n": 0, "b": 0})
        nav0 = len(navs)

        fx.set_queue(sse_stream(parts))          # 队列可能已被上面那步消耗
        say("\n=== 发送，开始观察（最多 %d 秒）===" % WATCH_S)
        t0 = time.time()
        send_wait(pg, "跑一个完整分析")

        peak_q, peak_q_t = 0, 0
        samples = []
        last_bytes, stall = 0, 0
        while time.time() - t0 < WATCH_S:
            pg.wait_for_timeout(2000)
            el = time.time() - t0
            st = pg.evaluate(STATE)
            q = max(sendq(PORT) or [0])
            if q > peak_q:
                peak_q, peak_q_t = q, el
            rate = (st["ws"]["bytes"] - last_bytes) / 2.0          # 这一拍的瞬时速率
            samples.append((round(el), st["ws"]["bytes"], q, st["off"]))
            say("  t=%3ds 收 %7d B (+%6.1f KB/s) Send-Q=%7d 遮罩=%-12s 帧=%d 最大间隔=%.1fs 气泡=%d(%d字)"
                % (el, st["ws"]["bytes"], rate / 1024.0, q, st["off"], st["ws"]["n"],
                   st["ws"]["maxgap"] / 1000.0, st["bubbles"], st["last_text"]))
            if st["ws"]["bytes"] == last_bytes:
                stall += 2
                # 收干净了、遮罩也退了、也没在吐字 → 结束
                if stall >= 8 and not st["cursor"] and st["last_text"] > 0:
                    say("  （8 秒没有新数据、光标已收，认为这一轮结束）")
                    break
            else:
                stall = 0
            last_bytes = st["ws"]["bytes"]

        end = pg.evaluate(STATE)
        big = end["ws"].get("big", [])
        say("\n=== 结果 ===")
        say("浏览器收到的 WS 字节      : %d B（%.1f KB） 帧数 %d"
            % (end["ws"]["bytes"], end["ws"]["bytes"] / 1024.0, end["ws"]["n"]))
        say("帧大小分布                : %s" % json.dumps(end["ws"].get("hist", {}),
                                                          ensure_ascii=False))
        if big:
            tot = sum(b for _, b in big)
            say("大帧(>1KB)               : %d 个 / %.1f KB，最大 %d B，"
                "时间跨度 %.0f→%.0f s"
                % (len(big), tot / 1024.0, max(b for _, b in big),
                   big[0][0] / 1000.0, big[-1][0] / 1000.0))
            say("  前 12 个大帧 (ms, B)   : %s" % json.dumps(big[:12]))
            say("  后 6 个大帧  (ms, B)   : %s" % json.dumps(big[-6:]))
        say("CDP 侧（含握手/控制帧）   : 收 %d 帧 / %.1f KB     发 %d 帧 / %.1f KB"
            % (recv["n"], recv["b"] / 1024.0, sent["n"], sent["b"] / 1024.0))
        say("峰值速率                  : %.1f KB/s（限速是 %.0f KB/s）"
            % (end["ws"]["bytes"] / max(time.time() - t0, 0.1) / 1024.0, KBPS))
        say("服务端 Send-Q 峰值        : %d B @ t=%ds（>0 且持续 = 积压）" % (peak_q, peak_q_t))
        say("相邻两帧最大间隔          : %.1f s（应用层判据是 16s）" % (end["ws"]["maxgap"] / 1000.0))
        say("WebSocket close 记录      : %s" % json.dumps(end["ws"]["closes"], ensure_ascii=False))
        say("shiny 事件                : %s" % json.dumps({k: v for k, v in end["ev"].items()
                                                          if k != 'connected'}, ensure_ascii=False))
        say("限速自检 / 导航次数       : %s ms / %d 次（>0 次 = 整页重载过）" % (t_probe, len(navs) - nav0))
        say("页面上最后一条回复        : %d 字（正文应有约 %d 字 —— 太少 = 没渲染完）"
            % (end["last_text"], total_chars))
        say("样本（t, 收字节, Send-Q, 遮罩）: %s" % json.dumps(samples[-20:]))
        pg.screenshot(path=os.path.join(C.OUT, "probe_streambytes.png"))
        br.close()
    fx.stop()
    say("假服务端收到请求 %d 次" % fx.req_n())


if __name__ == "__main__":
    main()
