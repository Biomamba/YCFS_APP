#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：自愈那段代码在 C 段到底跑到哪一步了（只观察，不断言）。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    python3 tests/ui_v158/diag_heal.py
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

PORT = int(re.search(r":(\d+)", C.URL).group(1))
LOG = os.path.join(os.path.dirname(C.APP), "diag_heal_%d.log" % int(time.time()))


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def app_pid():
    out = subprocess.run(["ss", "-ltnp"], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT).stdout.decode("utf-8", "replace")
    for ln in out.splitlines():
        if (":%d " % PORT) in ln:
            m = re.search(r"pid=(\d+)", ln)
            if m:
                return int(m.group(1))
    return None


def start_app():
    fh = open(LOG, "a")
    subprocess.Popen(
        ["/usr/lib/R/bin/exec/R", "-q", "-e",
         'shiny::runApp(port = %d, host = "127.0.0.1", launch.browser = FALSE)' % PORT],
        cwd=C.APP, env=dict(os.environ, R_HOME=os.environ.get("R_HOME", "/usr/lib/R")),
        stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(90):
        time.sleep(1)
        if app_pid() is not None:
            return True
    return False


# 页面里能读到的全部相关状态
JS = """() => {
  var d = document.getElementById('dsapp-offline');
  var out = {
    off: !!d, kind: d ? d.getAttribute('data-kind') : null,
    body: d ? (d.innerText || '').replace(/\\n/g, ' | ') : null,
    connected: (window.Shiny && Shiny.shinyapp) ? !!Shiny.shinyapp.isConnected() : null,
    has_shiny: !!window.Shiny,
    heal_timer: (typeof window.dsappHealTimer === 'undefined') ? 'undefined'
                : (window.dsappHealTimer === null ? null : '有'),
    heal_n: (function(){ try { return sessionStorage.getItem('dsapp_heal'); } catch(e){ return 'ERR'; } })(),
    mark: window.__m || null,
    n: (document.body.innerText || '').length
  };
  return out;
}"""


def main():
    fx = C.FakeLLM()
    say("实例 %s 端口 %d  fx=%s" % (C.APP, PORT, fx.url))
    say("app 日志 %s" % LOG)
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        pg = br.new_context(viewport={"width": 1440, "height": 900}).new_page()
        pg.on("console", lambda m: say("  console.%-7s %s" % (m.type, m.text[:180])))
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))
        pg.on("requestfailed",
              lambda r: say("  请求失败 %s  %s" % (r.url[:70], r.failure)))

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
        fx.set_queue(C.sse(content="第一轮：在的。"))
        send_wait(pg, "在吗")
        pg.wait_for_timeout(3000)
        pg.evaluate("() => { window.__m = 'A段'; }")
        say("A 完：%s" % json.dumps(pg.evaluate(JS), ensure_ascii=False))

        pid = app_pid()
        say("打死 pid=%s" % pid)
        os.kill(pid, signal.SIGKILL)
        for i in range(30):
            pg.wait_for_timeout(1000)
            st = pg.evaluate(JS)
            say("  B t=%2ds %s" % (i, json.dumps(st, ensure_ascii=False)))

        say("拉起服务端 ……")
        up = start_app()
        say("起来了=%s  pid=%s" % (up, app_pid()))
        t0 = time.time()
        for i in range(45):
            pg.wait_for_timeout(2000)
            st = pg.evaluate(JS)
            say("  C t=%3ds %s" % (int(time.time() - t0), json.dumps(st, ensure_ascii=False)))
            if st["mark"] is None:      # 页面被换掉了 = 重载过
                say("  → 页面换了文档（重载了）")
                break
        # 手工从页面里发一个 fetch，看服务器答不答
        try:
            r = pg.evaluate("""async () => {
              try { const r = await fetch('/?_probe_manual=' + Date.now(), {cache:'no-store'});
                    return 'status=' + r.status; }
              catch (e) { return 'ERR ' + e; }
            }""")
            say("  手工 fetch：%s" % r)
        except Exception as e:
            say("  手工 fetch 炸了：%s" % str(e)[:200])
        say("最后：%s" % json.dumps(pg.evaluate(JS), ensure_ascii=False))
        pg.screenshot(path=os.path.join(C.OUT, "diag_heal_end.png"))

        # ---- F：SIGSTOP（服务端"忙/卡住"，TCP 没断）------------------------
        # 给探针 E 段定判据用的：冻住的进程不会发 FIN/RST，所以只可能走
        # "心跳超时 → silent"那条路。要量清楚三件事：
        #   ① socket 在这种状态下能撑多久（撑不到 30 秒的话，E 段就量不了
        #      "哑掉但没断"，只能改成别的东西）；
        #   ② 遮罩是哪种 kind（该是 silent）；
        #   ③ CONT 之后心跳回来，遮罩会不会自己消失（会的话 E 就有了正向判据）。
        navs = []
        pg.on("framenavigated",
              lambda f: navs.append(f.url) if f == pg.main_frame else None)
        say("\n==== F 段：冻住服务端（kill -STOP），看会不会被误当成断线 ====")
        for _ in range(60):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-shell").count():
                break
        pg.evaluate("() => { window.__m = 'F段'; }")
        pid = app_pid()
        say("  STOP pid=%s  导航次数=%d" % (pid, len(navs)))
        os.kill(pid, signal.SIGSTOP)
        t0 = time.time()
        for i in range(30):                       # 60 秒，够看清 socket 会不会死
            pg.wait_for_timeout(2000)
            try:
                st = pg.evaluate(JS)
            except Exception as e:
                st = {"eval炸了": str(e)[:60]}
            say("  F t=%3ds %s" % (int(time.time() - t0), json.dumps(st, ensure_ascii=False)))
        say("  CONT pid=%s" % pid)
        os.kill(pid, signal.SIGCONT)
        t0 = time.time()
        for i in range(15):                       # 30 秒，看它自己好
            pg.wait_for_timeout(2000)
            try:
                st = pg.evaluate(JS)
            except Exception as e:
                st = {"eval炸了": str(e)[:60]}
            say("  G t=%3ds %s" % (int(time.time() - t0), json.dumps(st, ensure_ascii=False)))
        say("  F/G 段导航次数=%d（变了 = 中间被整页重载过）" % len(navs))
        pg.screenshot(path=os.path.join(C.OUT, "diag_stop_end.png"))
        br.close()
    fx.stop()
    if app_pid() is None:
        say("实例没在跑，拉起来：%s" % start_app())


if __name__ == "__main__":
    main()
