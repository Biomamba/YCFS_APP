#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.12 item 2：**慢链路上的自愈不能变成一个无限重载的圈。**

用户原话（2026-10-03，账号 wchcpu2019@163.com）：
    「这个账号的页面还是崩溃的」—— 它其实没崩，是**每 ~120 秒整页重载一次**，
    一直循环，`data/logs/auth.log` 里 15:49→16:51 一刻没停。

线上取证（`/proc/net/tcp` 的 Send-Q + auth.log，不是推断）：
    · 那个客户端（222.190.61.36）那一段链路实测**中位数 3.65 KB/s**；
    · 首屏一包 152 KB（管理员那几页改懒加载之后 116 KB）→ 排水要 30~40 秒；
    · SockJS 的 websocket 通道 25 秒一次协议级 PING，**10 秒**收不到 pong 就
      `session.close(3000, 'No response from heartbeat')`
      （sockjs/lib/trans-websocket.js:144-159；RStudio 自己的规则文件里也写着
      "that transport protocol has an effective 10 second limit built in"）；
      PING 和业务数据走同一条 TCP 连接 → 排在积压后面 → 必超时；
    · 于是：断线 → 前端 `shiny:disconnected` → 自愈探活成功 → 整页重载 →
      再发一遍 152 KB → 再断。**一个自己喂自己的圈。**
    · 而 V15.11 的刹车口径是"最近 3 分钟刷了 3 次"：**120 秒的节奏下，任意
      180 秒的窗口里最多只装得下 2 次**，刹车永远踩不下去（代码事实，
      `DSAPP_HEAL_WINDOW_MS=180000` / `DSAPP_HEAL_MAX=3`）。

V15.12 把口径换成"**只被'好起来'清零**"的计数，外加每失败一轮退避 20 秒、
外加**手动刷新清零**。这个探针证的就是这四条 —— 全部在真浏览器里、走**真的
断线**（`kill -9` 掉实例；测试实例里 R 进程就是服务器本身，线上才另有 worker）：

  A 段  第 1 次断 → 宽限 20 秒 → 服务端回来 → 该**自动重载**，记 1 笔
  B 段  第 2 次断 → 宽限 40 秒（★ 退避真的生效了才看得到）→ 记 2 笔
  C 段  第 3 次断 → 宽限 60 秒 → 记 3 笔
  D 段  第 4 次断 → ★★★ **不该再重载**，而是把话说清楚（"已经自动重试 3 次…"），
        页面上仍然留着那颗**刷新页面**的按钮
  E 段  点那颗按钮（= 人的手动决定）→ 账清零 → 再断一次：宽限回到 20 秒、
        日志回到"连着第 1 次"（★ 一个自动机制不该把人的手动操作也一起堵死）

⚠️ 判据一律用 `sessionStorage.dsapp_heal` 的**条数**和自愈自己那句 console
   日志，**不用"页面导航了几次"**：应用在 cookie 回执那条路上会
   `session$reload()`（app.R:1290），导航次数里混着它，数出来会虚高
   （本仓在"页面老在刷"那次已经栽过一回，见 measure-refresh-by-fingerprint）。
⚠️ 计时也取 console 那一句的时刻，不取轮询到增量的时刻：轮询撞上导航会漏拍，
   而"漏拍"只会把时间**量长**，退避那几条断言就变成了白送。
⚠️⚠️ 这个探针**分不出新旧两版**，别拿它当对照：D 段那个"第 4 轮停手"在
   V15.11（滑动窗口 180 秒 / 上限 3）下同样成立 —— 因为探针把节奏压到了
   20 秒一次，3 分钟的窗口正好装得下 3 笔。新旧真正的差别在**线上的节奏
   （120 秒一次）**：那里 180 秒的窗口最多只装得下 2 笔，旧版永远数不到 3。
   那份对照用两版的**真代码** + 假时钟跑，见 tests/ui_v158/brake_sim.js
   （`node tests/ui_v158/brake_sim.js`）。

用法：
    bash tests/ui_v7/make_instance.sh 8956 /tmp/dsapp_v1512b
    python3 tests/ui_v158/probe_heal_brake.py
"""
import os
import re
import signal
import subprocess
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8956/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1512b/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

chk = C.Chk()
PORT = int(re.search(r":(\d+)", C.URL).group(1))
# ⚠️ 两次运行别写同一个日志文件（截断 + 各自的 fd 偏移 → 交错成垃圾）。
LOG = os.path.join(os.path.dirname(C.APP), "app_brake_%d.log" % int(time.time()))
CONS = []          # [(时刻, 自愈那句 console 日志)]


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


# ---- 起停实例里的那个 R 进程 ------------------------------------------------
def app_pid():
    """听这个端口的 pid。⚠️ 从 ss 里读，不用 pgrep —— 它会连探针自己一起匹配上。"""
    try:
        out = subprocess.run(["ss", "-ltnp"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT).stdout.decode("utf-8", "replace")
    except Exception:
        return None
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
    for _ in range(120):
        time.sleep(1)
        if app_pid() is not None:
            return True
    return False


def kill_app():
    pid = app_pid()
    if pid is None:
        return None
    os.kill(pid, signal.SIGKILL)
    for _ in range(20):
        time.sleep(0.5)
        if app_pid() is None:
            break
    return pid


# ---- 页面状态 ---------------------------------------------------------------
# ⚠️ 取不到的字段一律 None，**不补默认值**：这里最要命的是 conn/heal_n，
#    补默认值会把"没读到"判成"连着"或"没刷过"（本仓老规矩）。
JS_STATE = """() => {
  var d = document.getElementById('dsapp-offline');
  var raw = null, n = null;
  try {
    raw = sessionStorage.getItem('dsapp_heal');
    n = JSON.parse(raw || '[]').length;
  } catch (e) { n = -1; }
  return {
    conn: !!(window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()),
    off: !!d,
    kind: d ? d.getAttribute('data-kind') : null,
    body: d ? (d.innerText || '') : null,
    btn: !!(d && d.querySelector('button.btn-primary')),
    shell: !!document.querySelector('.dsapp-shell'),
    auth: !!document.querySelector('.dsapp-auth'),
    heal_n: n,
    heal_raw: raw
  };
}"""


def state(pg):
    try:
        return pg.evaluate(JS_STATE)
    except Exception:
        return None          # 多半正在导航，调用方自己判 None


def wait_conn(pg, sec=180):
    """等服务端**回来了且这个页面连上了**（整页重载之后要重新 boot）。"""
    t0 = time.time()
    while time.time() - t0 < sec:
        st = state(pg)
        if st and st.get("conn") and (st.get("shell") or st.get("auth")):
            return st
        pg.wait_for_timeout(1000)
    return None


def wait_overlay(pg, sec):
    t0 = time.time()
    while time.time() - t0 < sec:
        st = state(pg)
        if st and st.get("off"):
            return st, time.time() - t0
        pg.wait_for_timeout(500)
    return None, None


def cons_since(t0):
    """t0 之后自愈打的那几句（它是 reload 前最后一行，时刻最准）。"""
    return [(t, s) for (t, s) in CONS if t >= t0]


def last_strike(pg, t_min, sec=90):
    """等服务端起来之后那一拍：要么重载（console 出日志），要么刹车（提示变字）。

    ⚠️ `t_min` 是**这一轮**的下界（= 重启服务端之前那一瞬）。必须传它，不能
    在函数里自己取 `time.time() - sec` 往回扫：上一轮那句 console 就落在那段
    回扫窗口里 → 函数当场返回**上一轮的时刻** → 这一轮其实一秒都没等，
    `t_hit - t_kill` 量出负数（本仓 2026-10-03 真踩过：-2.6 秒）。负数被
    "等待 ≥ 宽限"那条断言拦下来了，但**拦下来的原因是错的**（看着像退避没生效，
    其实是探针根本没等），后面每一轮的账全跟着错位。

    返回 (kind, 时刻, 提示正文)。kind ∈ {"reload", "brake", "none"}。
    """
    t0 = time.time()
    while time.time() - t0 < sec:
        hits = cons_since(t_min)
        if hits:
            return "reload", hits[0][0], hits[0][1]
        st = state(pg)
        if st and st.get("body") and "已经自动重试" in st["body"]:
            return "brake", time.time(), st["body"]
        pg.wait_for_timeout(1000)
    return "none", None, None


def main():
    say("实例 %s（pid=%s）  日志 %s" % (C.APP, app_pid(), LOG))
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        pg.on("console", lambda m: CONS.append((time.time(), m.text))
              if "自动刷新页面" in (m.text or "") else None)
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))

        C.enter_app(pg)
        st = wait_conn(pg)
        chk("起点：进了主界面且连接正常", st is not None and st.get("heal_n") == 0,
            "" if st is None else st)
        if st is None:
            br.close()
            return chk.done()

        # 每一轮：grace 秒 = 20 + 已失败次数 × 20（和 app.js 里的公式同源）
        rows = []
        for i in (1, 2, 3, 4):
            grace = 20 + (i - 1) * 20
            st = wait_conn(pg, 60)
            n0 = st["heal_n"] if st else None
            t_kill = time.time()
            pid = kill_app()
            ov, dt = wait_overlay(pg, 25)
            chk("第 %d 轮：断线后出现提示（kind=disconnected）" % i,
                ov is not None and ov.get("kind") == "disconnected",
                "pid=%s overlay=%s" % (pid, ov))
            # 服务端还死着：这一段里自愈的探活必然失败 → **不该**有任何重载
            time.sleep(grace + 6)
            n_mid = (state(pg) or {}).get("heal_n")
            chk("第 %d 轮：宽限 %d 秒内服务端没回来 → 一次都不许刷" % (i, grace),
                n_mid == n0, "kill 前后 heal_n = %s → %s" % (n0, n_mid))
            t_up = time.time()          # 这一轮的下界：服务端起来之前那一瞬
            start_app()
            kind, t_hit, body = last_strike(pg, t_up, 90)
            rows.append(dict(i=i, grace=grace, kind=kind, t_kill=t_kill, t_hit=t_hit,
                             n0=n0, body=body))
            st2 = state(pg)
            n1 = st2.get("heal_n") if st2 else None
            say("  第 %d 轮：%s（heal_n %s → %s）" % (i, kind, n0, n1))

            if i <= 3:
                chk("★★ 第 %d 次断线：自动重载了，账记到 %d 笔" % (i, i),
                    kind == "reload" and n1 == i,
                    "kind=%s heal_n=%s（期望 %d）" % (kind, n1, i))
                chk("★ 第 %d 次：日志说得出「这是第几次」（连着第 %d 次）" % (i, i),
                    ("连着第 %d 次" % i) in (body or ""), body)
                # 退避：这一轮从 kill 到重载，至少要等够 grace
                waited = (t_hit - t_kill) if t_hit else None
                chk("★★ 第 %d 次：宽限期是 %d 秒（退避真的进了计算）" % (i, grace),
                    waited is not None and waited >= grace - 2,
                    "kill→重载实测 %.1f 秒" % (waited if waited else -1))
                # ⚠️ 单独一条：负数只可能是探针认错了日志（见 last_strike 的
                #    docstring）。它红了先修探针，别去 R/app.js 里找。
                chk("★ 第 %d 次：那次重载确实发生在本轮之内（不是捡到上一轮的日志）" % i,
                    waited is not None and waited >= 0,
                    "kill→重载实测 %.1f 秒" % (waited if waited else -1))
            else:
                chk("★★★ 第 4 次断线：**不再自动重载**（heal_n 停在 3）",
                    kind == "brake" and n1 == 3,
                    "kind=%s heal_n=%s body=%s" % (kind, n1, (body or "")[:120]))
                st2 = state(pg) or {}
                chk("★★ 停手时把话说清楚了，而不是干等",
                    "已经自动重试" in (st2.get("body") or "") and
                    "网络" in (st2.get("body") or ""), st2.get("body"))
                chk("★ 停手之后仍然留着「刷新页面」那颗按钮（人还能自己试）",
                    bool(st2.get("btn")), st2)

        # ---- E 段：手动刷新 = 人的决定，账必须清零 -------------------------
        say("\n== E 段：点「刷新页面」→ 账清零 → 再断一次该回到「第 1 次」 ==")
        pg.locator("#dsapp-offline button.btn-primary").click()
        st = wait_conn(pg, 120)
        chk("★ 手动刷新后页面回来了，且账已清零",
            st is not None and st.get("heal_n") == 0,
            "" if st is None else "heal_n=%s raw=%s" % (st.get("heal_n"), st.get("heal_raw")))
        if st is not None and st.get("heal_n") == 0:
            t_kill = time.time()
            kill_app()
            wait_overlay(pg, 25)
            time.sleep(20 + 6)
            t_up = time.time()
            start_app()
            kind, t_hit, body = last_strike(pg, t_up, 90)
            st2 = state(pg) or {}
            chk("★★ 清零之后这一轮：宽限回到 20 秒、日志回到「连着第 1 次」",
                kind == "reload" and st2.get("heal_n") == 1 and
                ("连着第 1 次" in (body or "")) and
                (t_hit - t_kill) >= 18,
                "kind=%s heal_n=%s 等了 %.1f 秒 body=%s"
                % (kind, st2.get("heal_n"), (t_hit - t_kill) if t_hit else -1,
                   (body or "")[:120]))

        try:
            pg.screenshot(path=os.path.join(C.OUT, "probe_heal_brake.png"))
        except Exception:
            pass
        br.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
