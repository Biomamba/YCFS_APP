# -*- coding: utf-8 -*-
"""item 7 诊断 + 验收：服务端**还活着但不应答**的时候，页面能不能自己发现。

背景（用户原话）：「刚才页面卡住了，刷新后正常了，看一下是程序的问题还是
浏览器的问题，请debug」。

★ 先说结论，再说怎么验的：
  * **干净地断**（socket 收到 close）—— 本来就是好的，0.21 秒出遮罩。
  * **服务端不应答**（半开的连接 / 进程被冻住 / 主线程被占住）—— 修之前
    **完全测不出来**：isConnected() 一直是 true、Shiny 自带遮罩不出现、
    控制台一条报错都没有，页面看着完全正常，点什么都没反应。

  后半句就是用户看到的东西。根因是所有断线检测都挂在 socket 的 close 事件
  上，而这两种情况下 TCP 根本不发 FIN/RST，close 事件永远不来。

★ `kill -STOP` 恰好同时造出这两种：进程被冻住、不读 socket、也不关它。
  这是最接近"服务端卡住了"的复现方式，而且不依赖任何真实负载。

修法见 app.R 那条心跳 observe + www/app.js 的看门狗。这一条验的就是它：
  1. 正常时不误报（心跳在走，遮罩不许出现）
  2. 冻住之后 20 秒内必须报出来
  3. 解冻之后必须**自己消失**（不许变成"必须刷新"）
"""
import subprocess
import sys
import time

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import URL, enter_app   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


def worker_pid():
    out = subprocess.run(["pgrep", "-af", "8912"], capture_output=True,
                         text=True).stdout
    for ln in out.splitlines():
        if "runApp" in ln:
            return int(ln.split()[0])
    return None


def overlay_kind(pg):
    return pg.evaluate("""() => {
        var d = document.getElementById('dsapp-offline');
        return d ? (d.getAttribute('data-kind') || '?') : null;
    }""")


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    pg = br.new_context(viewport={"width": 1500, "height": 950}).new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:180]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:180])
          if m.type == "error" else None)

    email = enter_app(pg)
    print("登录成功：%s" % email, flush=True)
    pg.wait_for_timeout(3000)

    # ---- 1. 正常时不误报 ----
    print("\n== 1. 正常运行时不许误报（心跳在走，遮罩不能出现）==", flush=True)
    seen = []
    for _ in range(10):                    # 20 秒，跨过 16 秒判死线好几倍
        pg.wait_for_timeout(2000)
        seen.append(overlay_kind(pg))
    print("   20 秒里采样到的遮罩状态：%s" % sorted(set(map(str, seen))), flush=True)
    C("★★★ 心跳正常时**一次都不许**弹遮罩（否则就是误报）",
      all(s is None for s in seen), str(sorted(set(map(str, seen)))))

    # ---- 2. 冻住服务端 ----
    pid = worker_pid()
    print("\n== 2. kill -STOP 冻住 R worker (pid=%s) ==" % pid, flush=True)
    subprocess.run(["kill", "-STOP", str(pid)])
    t0 = time.time()
    got = None
    while time.time() - t0 < 30:
        pg.wait_for_timeout(1000)
        k = overlay_kind(pg)
        if k is not None:
            got = time.time() - t0
            break
    C("★★★ 服务端不应答时，前端在 30 秒内自己报了警",
      got is not None, "%.1fs" % got if got else "30 秒内一直没报")
    if got:
        C("★★ 报的是「服务端没有响应」那一版（不是「连接断了」）",
          overlay_kind(pg) == "silent", str(overlay_kind(pg)))
        C("★★ 判死时间在合理区间（不许一抖就报，也不许等太久）",
          10 <= got <= 25, "%.1fs" % got)
        txt = pg.inner_text("#dsapp-offline")
        print("   遮罩文字：%s" % txt.replace("\n", " | ")[:170], flush=True)
        C("★★ 说清楚了「按钮点了没反应」（用户知道这时候点没用）",
          "不会有任何反应" in txt)
        # ⚠️ 这里是 HTML 不是 Markdown：写 ** 会原样显示成星号。断言里
        #    顺手挡一道 —— 这类错字面上看不出来，只有渲染出来才露馅。
        C("★ 遮罩里没有漏出来的 Markdown 星号", "**" not in txt)
        C("★ 给了「先等一下」这条路（服务端可能只是在忙）",
          "先等一下" in txt)
        C("★ 也给了刷新这条路", "刷新页面" in txt)

    # ---- 3. 解冻：遮罩必须自己消失，不许变成"必须刷新" ----
    print("\n== 3. kill -CONT 解冻，看它能不能自己恢复 ==", flush=True)
    subprocess.run(["kill", "-CONT", str(pid)])
    t1 = time.time()
    gone = None
    while time.time() - t1 < 30:
        pg.wait_for_timeout(1000)
        if overlay_kind(pg) is None:
            gone = time.time() - t1
            break
    C("★★★ 服务端缓过来之后遮罩**自己消失**（不是逼用户刷新）",
      gone is not None, "%.1fs" % gone if gone else "30 秒后还挂着")

    # ---- 4. 页面真的能用了 ----
    print("\n== 4. 恢复之后，页面是真能用，还是只剩个空壳 ==", flush=True)
    ok = False
    try:
        pg.click(".dsapp-rail-link[data-nav='tasks']", timeout=6000)
        pg.wait_for_timeout(3000)
        active = pg.eval_on_selector_all(
            ".dsapp-rail-link.active", "els => els.map(e => e.dataset.nav)")
        ok = active == ["tasks"]
    except Exception as e:
        print("   点不动：%s" % str(e)[:90], flush=True)
    C("★★★ 恢复后点导航真的切页了（服务端在正常处理输入）", ok)

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item7_wedge.png")
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
