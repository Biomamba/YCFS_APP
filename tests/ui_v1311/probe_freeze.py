# -*- coding: utf-8 -*-
"""item 7 诊断：页面"卡住"到底是程序的问题还是浏览器的问题。

只诊断，不改任何东西。做法是**把服务端打死**，看前端那一秒真实发生了什么：

  A. 干净的断（socket 收到 close）—— 杀掉 R worker 就是这一类
  B. 半开的断（socket 没关，但对端已经没了）—— 网络抖动 / 负载均衡静默丢包

两种都测，因为用户看到的现象是"页面还在、按钮点了没反应"，
而这两种断法在前端**长得一模一样**。

⚠️ 2026-10-07 之后这个诊断的读数要重新解读：断线提示**分两档出场**了
（判死只出左下角小条 `#dsapp-offline-mini`，撑够 DSAPP_OFFLINE_CARD_MS
才铺 `#dsapp-offline` 那张整页卡片）。所以「24 秒内 #dsapp-offline 一次都没
出现」**不再等于"前端没报"** —— 那一刻它多半正挂着小条。这个文件是 V13.11
那一刻的逐秒记录，数字是按当时的行为量的，别拿它当现行契约。
"""
import subprocess
import sys
import time

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import URL          # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

EV = []


def ev(tag, extra=""):
    line = "[%7.2fs] %-34s %s" % (time.time() - T0, tag, extra)
    EV.append(line)
    print(line, flush=True)


def worker_pid():
    out = subprocess.run(["pgrep", "-af", "8912"], capture_output=True,
                         text=True).stdout
    for ln in out.splitlines():
        if "runApp" in ln or "shiny" in ln:
            return int(ln.split()[0])
    return None


T0 = time.time()

with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    ctx = br.new_context(viewport={"width": 1400, "height": 900})
    pg = ctx.new_page()

    logs = []
    pg.on("console", lambda m: logs.append("%-6s %s" % (m.type, m.text[:160])))
    pg.on("pageerror", lambda e: logs.append("PAGEERR %s" % str(e)[:160]))

    # 前端有没有在监听断线
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_timeout(2500)

    print("\n=== 探针 1：断线之前，前端是什么状态 ===", flush=True)
    st = pg.evaluate("""() => ({
        connected: !!(window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()),
        overlay: !!document.getElementById('dsapp-offline'),
        shinyOverlay: !!document.getElementById('shiny-disconnected-overlay'),
        hasAllowReconnect: typeof Shiny.shinyapp !== 'undefined'
    })""")
    print("   %s" % st, flush=True)
    ev("断线前 isConnected", st["connected"])

    # ---- A. 杀掉服务端进程（干净的断）----
    pid = worker_pid()
    print("\n=== 探针 2：杀掉 R worker (pid=%s)，看前端多久反应过来 ===" % pid,
          flush=True)
    if pid:
        subprocess.run(["kill", "-9", str(pid)])
    t_kill = time.time()

    got_offline = None
    got_shiny_overlay = None
    for _ in range(120):                      # 最多等 24 秒
        pg.wait_for_timeout(200)
        try:
            s = pg.evaluate("""() => ({
                overlay: !!document.getElementById('dsapp-offline'),
                shinyOverlay: !!document.getElementById('shiny-disconnected-overlay'),
                connected: !!(window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected())
            })""")
        except Exception as e:
            ev("页面已经不能 evaluate 了", str(e)[:80])
            break
        if s["overlay"] and got_offline is None:
            got_offline = time.time() - t_kill
            ev(">>> #dsapp-offline 出现", "%.2fs" % got_offline)
        if s["shinyOverlay"] and got_shiny_overlay is None:
            got_shiny_overlay = time.time() - t_kill
            ev(">>> Shiny 自带遮罩出现", "%.2fs" % got_shiny_overlay)
        if got_offline is not None:
            break

    if got_offline is None:
        ev("!!! 24 秒内 #dsapp-offline 一次都没出现")
    if got_shiny_overlay is None:
        ev("(Shiny 自带遮罩没出现)")

    # 遮罩出来了之后：点底下的按钮还有没有反应
    print("\n=== 探针 3：遮罩之下，按钮还点得动吗 ===", flush=True)
    try:
        vis = pg.eval_on_selector("#dsapp-offline",
                                  "e => ({txt: e.innerText.replace(/\\n/g,' | '), "
                                  "z: getComputedStyle(e).zIndex})")
        print("   遮罩文字：%s" % vis["txt"][:120], flush=True)
        print("   z-index：%s" % vis["z"], flush=True)
    except Exception as e:
        print("   （没有遮罩可读：%s）" % str(e)[:80], flush=True)

    print("\n=== 探针 4：前端这段时间报了什么 ===", flush=True)
    for l in logs[:25]:
        print("   %s" % l, flush=True)
    if not logs:
        print("   （一条都没有）", flush=True)

    br.close()

print("\n=== 结论 ===", flush=True)
print("杀掉 worker 后 #dsapp-offline 出现耗时：%s"
      % ("%.2fs" % got_offline if got_offline is not None else "从未出现"),
      flush=True)
