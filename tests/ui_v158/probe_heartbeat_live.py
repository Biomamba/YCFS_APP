#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
V15.12 的最后一环：**线上那条链路真的每 180 秒才 ping 一次吗**（只读）

为什么还要单独量这一下 —— `/etc` 里那行放对了、进程也重启了，仍然可能没生效：
  · 指令写在了 `server{}` / `location{}` 里 → 被 shiny-server 自己的 schema 拒掉；
  · 名字打错 → `Unknown directive`；
  · 改了文件但**没重启**（配置只在 node 主进程启动时读一次，和 R worker 无关）。
前两条我在本地拿 shiny-server 自己的 `readSync`+schema 验过，第三条只能看进程
启动时间。这三条合起来是"应该生效了"，**不是"已经生效了"** —— 本仓栽过的
「自检全绿 ≠ 功能被验过」就是这么来的。所以直接连上去数 ping 的间隔。

原理（都在 node 侧，和 R 无关）：
  transport.js:92   this.heartbeat_delay = server.options.heartbeat_delay
  transport.js:214  setTimeout(x, this.heartbeat_delay) → recv.heartbeat()
  trans-websocket.js:147  ws.ping() 之后 setTimeout(…, 10000)  ← 这个 10 秒写死
  trans-websocket.js:157  session.close(3000, 'No response from heartbeat')
所以 **ping 的间隔 = sockjs_heartbeat_delay，pong 的期限恒为 10 秒**。
旧的 25 秒和新的 180 秒差 7 倍，只看**第一次 ping 什么时候到**就分得开。

用法（要几分钟：第一次 ping 大约在连上后 180 秒才来）：
    python3 tests/ui_v158/probe_heartbeat_live.py
    python3 tests/ui_v158/probe_heartbeat_live.py --url http://127.0.0.1:34038/YCFS_APP/

⚠️ 只读：连一个 SockJS 会话，收到 ping 就回 pong，不发任何业务消息、不登录、
   不写库。它唯一的影响是让那个 R worker 多活几分钟。
⚠️ **判据是"第一次 ping 落在 (60, 300) 秒之间"**：落在 25 秒附近 = 还是旧值；
   超过 300 秒 = 没生效/指令没被读到（回落到默认 25 秒反而会更快，所以"快"
   和"慢"两头都是失败信号，只有 ~180 是成功）。
"""
import argparse
import json
import random
import string
import sys
import threading
import time
import urllib.request

import websocket   # websocket-client

OK_LO, OK_HI = 60.0, 300.0      # 认定的 180 秒落在这个区间里
WAIT_MAX = 330.0                # 等第一次 ping 的上限


# ⚠️ 前缀**不是** `/sockjs/`：shiny-server 把 SockJS 挂在
#    `/opt/shiny-server/lib/proxy/sockjs.js:42` 里写的那个
#    `.*/__sockjs__(/[no]=\w+)?` 上（拿 `/sockjs/info` 去问会吃 404）。
PREFIX = "/__sockjs__"


def sockjs_url(base):
    """按 SockJS 的规矩拼一条 websocket 地址（server_id/session_id 是随机的）。

    ⚠️ info 用 http 问，**握手地址必须是 ws://** —— `WebSocketApp` 拿到
       `http://…` 会在自己的 `parse_url` 里抛 `scheme http is invalid`，
       而且是在后台线程里抛，主线程只看到"60 秒都没连上"，很容易误判成
       服务没起（本脚本第一版就这么栽的）。"""
    base = base.rstrip("/")
    info = json.loads(urllib.request.urlopen(base + PREFIX + "/info",
                                             timeout=30).read().decode())
    if not info.get("websocket"):
        sys.exit("服务端没开 websocket 通道：%s" % info)
    ws_base = "ws://" + base.split("://", 1)[-1]
    srv = "%03d" % random.randint(0, 999)
    sess = "".join(random.choice(string.ascii_lowercase + string.digits)
                   for _ in range(8))
    return ws_base + PREFIX + "/%s/%s/websocket" % (srv, sess)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:34038/YCFS_APP/")
    a = ap.parse_args()

    url = sockjs_url(a.url)
    print("连：%s" % url)
    pings, opened = [], threading.Event()
    t0 = [None]

    def on_open(ws):
        t0[0] = time.time()
        opened.set()
        print("连上了，等着数 ping（第一次大约 180 秒后才来，别急）…")

    def on_ping(ws, data):
        t = time.time() - t0[0]
        pings.append(t)
        print("  ping #%d  t = %.1f 秒" % (len(pings), t))
        try:
            ws.sock.pong(data)          # 必须回，否则 10 秒后就被 close(3000)
        except Exception as e:
            print("  回 pong 失败：%s" % e)

    def on_message(ws, msg):
        # SockJS 的应用层心跳是数据帧 "h"；websocket 通道上真正管判死的是
        # **控制帧 ping**，所以这里只记一笔，不当判据。
        if msg == "h":
            print("  （SockJS 层的 h 帧，t = %.1f 秒）" % (time.time() - t0[0]))

    def on_error(ws, e):
        print("  出错：%s" % str(e)[:200])

    def on_close(ws, code, reason):
        print("  连接关了：code=%s reason=%s" % (code, reason))

    ws = websocket.WebSocketApp(url, on_open=on_open, on_ping=on_ping,
                                on_message=on_message, on_error=on_error,
                                on_close=on_close)
    th = threading.Thread(target=ws.run_forever, kwargs={"ping_interval": 0},
                          daemon=True)
    th.start()

    if not opened.wait(60):
        sys.exit("✗ 60 秒都没连上 —— 先确认服务起没起、URL 对不对")
    deadline = time.time() + WAIT_MAX
    while not pings and time.time() < deadline:
        time.sleep(1)
        if not th.is_alive():
            sys.exit("✗ 连接在等到第一次 ping 之前就关了")
    ws.close()

    if not pings:
        sys.exit("✗ 等了 %.0f 秒一个 ping 都没有 —— 指令多半没被读到" % WAIT_MAX)

    first = pings[0]
    print("\n第一次 ping：**%.1f 秒**" % first)
    if len(pings) > 1:
        gaps = [b - a for a, b in zip(pings, pings[1:])]
        print("间隔：%s" % ", ".join("%.1f" % g for g in gaps))
    if OK_LO < first < OK_HI:
        print("✓ 落在 (%.0f, %.0f) 秒里 —— /etc 那份**真的生效了**"
              % (OK_LO, OK_HI))
        sys.exit(0)
    if first < 30:
        print("✗ 只有 %.1f 秒 ≈ 默认的 25 秒 —— 指令没被读到（位置写错？没重启？）"
              % first)
    else:
        print("✗ %.1f 秒不在认定区间里 —— 别急着下结论，先看是不是改成了别的值"
              % first)
    sys.exit(1)


if __name__ == "__main__":
    main()
