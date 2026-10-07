#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
V15.10 上线核对（默认对着**线上** 34038 跑）。

⚠️ 只读：只加载登录页 —— **不注册、不登录、不发消息、不写库**。
   连开 3 个全新会话，量每个会话「导航开始 → 服务端第一次 flush 走完」。
   JIT 3（旧代码）下第 2 个会话要 ~7-8 s；JIT 0（V15.10）下三个都是零点几秒。

⚠️⚠️ 判据是 **shiny:idle**，不是 `shiny:sessioninitialized`：
   2026-10-03 实测（本地实例 + 服务端插桩，JIT 3）：第 2 个会话服务端
   `modules=7.26s`，而 sessioninitialized 在 **0.18 s** 就响了 —— 它早于
   `server()` 把 16 个模块 server 注册完。用错了判据的话，卡 7 秒和没卡
   量出来是同一个数（这一版第一版就是这么错的，靠"已知会红的样本必须红"
   才发现：拿 DSAPP_JIT=3 的实例跑，判据照样全绿）。

⚠️ 服务端那一侧的对应探针（起本地实例时用，见下方"怎么复核"）：
   在实例副本的 app.R 里把 16 个 `mod_*_server()` 那一段前后各插一行计时，
   JIT 3 下会看到 `modules=0.69s / 7.26s / 0.57s`，JIT 0 下三行都是零点几秒。

跑法：
  /home/biomamba/miniconda3/bin/python tests/ui_v158/verify_v1510_live.py
对照（本地实例，已知会红的样本）：
  DSAPP_PROBE_URL=http://127.0.0.1:8961/ ... verify_v1510_live.py
"""
import json
import os
import sys
import time

from playwright.sync_api import sync_playwright

# 默认打线上。对着本地实例做对照（已知会红的样本）时：
#   DSAPP_PROBE_URL=http://127.0.0.1:8961/ python verify_v1510_live.py
URL = os.environ.get("DSAPP_PROBE_URL", "http://127.0.0.1:34038/YCFS_APP/")
IDLE_TIMEOUT_MS = int(os.environ.get("DSAPP_PROBE_IDLE_MS", "120000"))

# 在页面脚本之前埋钩子：Shiny 的事件是 jQuery 事件，而 jQuery 是随 shiny.min.js
# 后到的，所以要轮询等它。（window.__t0 用 performance.now()，和事件同一时基。）
INIT = r"""
window.__t0 = performance.now();
window.__ev = {};
window.__seq = [];
(function hook(){
  if (!window.jQuery) { setTimeout(hook, 5); return; }
  var j = window.jQuery, d = j(document);
  function note(name){
    var t = performance.now();
    window.__seq.push([name, Math.round(t)]);
    if (window.__ev[name] === undefined) window.__ev[name] = t;
  }
  d.on('shiny:connected',          function(){ note('connected'); });
  d.on('shiny:sessioninitialized', function(){ note('sessinit'); });
  d.on('shiny:busy',               function(){ note('busy'); });
  d.on('shiny:idle',               function(){ note('idle'); });
  d.on('shiny:value',              function(){ note('value'); });
  d.on('shiny:outputinvalidated',  function(){ note('invalidated'); });
})();
"""


def _ms(ev, t0p, name):
    if t0p is None or name not in ev:
        return None
    return round((ev[name] - t0p) / 1000.0, 3)


def one(browser, idx):
    ctx = browser.new_context()
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(INIT)
    t0 = time.time()
    pg.goto(URL, wait_until="commit")
    try:
        pg.wait_for_function("() => window.__ev && window.__ev.idle !== undefined",
                             timeout=IDLE_TIMEOUT_MS)
        got = True
    except Exception:
        got = False
    t_ready = time.time() - t0
    ev = pg.evaluate("() => window.__ev || {}")
    seq = pg.evaluate("() => window.__seq || []")
    t0p = pg.evaluate("() => window.__t0 || null")
    try:
        ver = pg.inner_text(".dsapp-footer-ver").strip()
    except Exception:
        ver = ""
    body = pg.inner_text("body")[:60].replace("\n", " ")
    out = {
        "page": idx,
        "idle_s": _ms(ev, t0p, "idle"),          # ★ 判据：服务端第一次 flush 走完
        "wall_s": round(t_ready, 3),
        "sessinit_s": _ms(ev, t0p, "sessinit"),  # ⚠️ 早于模块注册，别拿它当判据
        "busy_s": _ms(ev, t0p, "busy"),
        "connected_s": _ms(ev, t0p, "connected"),
        "ver": ver,
        "got_idle": got,
        "body": body,
        "seq": [[n, round((t - t0p) / 1000.0, 3)] for n, t in seq[:10]] if t0p else [],
        "js_err": errs or None,
    }
    ctx.close()
    return out


def main():
    print(f"# 目标: {URL}")
    rows = []
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=True)
        for i in (1, 2, 3):
            rows.append(one(b, i))
        b.close()
    print(json.dumps(rows, ensure_ascii=False, indent=2))

    vers = {r["ver"] for r in rows}
    ok_ver = vers == {"V_Test_V15.10"}
    idle = [r["idle_s"] for r in rows]
    ok_got = all(r["got_idle"] for r in rows)
    # 判据：第 2/3 页不许比第 1 页慢出一大截（旧代码下第 2 页 ≈ 7-8 s）
    ok_no_freeze = ok_got and max(idle) < 3.0 and (max(idle) - min(idle)) < 2.0
    print(f"\n版本号 {sorted(vers)}  一致且 = V_Test_V15.10: {ok_ver}")
    print(f"三页 idle（服务端第一次 flush 走完）: {idle}  没有 7-8 秒冻结: {ok_no_freeze}")
    if not ok_got:
        print("⚠️ 有页面始终没等到 shiny:idle —— 判据没量到，不能当成通过")
    return 0 if (ok_ver and ok_no_freeze) else 1


if __name__ == "__main__":
    sys.exit(main())
