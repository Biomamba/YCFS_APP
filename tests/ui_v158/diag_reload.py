#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断：**一次普普通通的注册，页面会不会自己 reload 一次？为什么？**

起因：diag_multi 跑 registration 的时候页面**中途变成全黑空白**、body 一个字
都没有，报「注册没进主界面（页面文字 0 字）」。手动重放同一段代码却正常 ——
两次唯一的差别是**页面被导航了两次**（playwright 的 framenavigated 打了
两行同一个 URL）。app.js 里能引发 reload 的只有两处：

  · 312 行那个「刷新页面」按钮（没人点）
  · 446 行 `dsappHealStrike()` 之后的 `window.location.reload()`
    —— 它只在 `shiny:disconnected`（socket 真收到 close）之后才会跑到

所以问题就变成：**这次注册期间 socket 是不是断过？** 断过 = 用户那边
「与服务器的连接断了 / 应用可能刚重启或更新过」的一模一样的机制，
只是发生在一个"什么都不该出问题"的场景里。

怎么取证（reload 会清掉 window 上的东西，所以证据必须存得住）：
  · `performance.getEntriesByType('navigation')[0].type` —— 'reload'
    还是 'navigate'，分清"自己刷的"和"页面点出来的"；
  · sessionStorage（**跨 reload 存活**）里记：见过几次 `#dsapp-offline`、
    什么 kind、以及每次的心跳沉默时长；
  · 每个页面加载都记一笔时间戳 → 得到完整的页面生命周期时间线。

用法：
    python3 tests/ui_v158/diag_reload.py [URL]
"""
import os
import sys
import time

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8953/"
os.environ.setdefault("DSAPP_TEST_URL", URL)
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

# ⚠️ 这个脚本在**每一个** document 里都会跑一遍（包括 reload 之后的那个），
#    所以它只做"追加记录"，绝不清空任何东西。
WATCH = r"""
(() => {
  try {
    const S = window.sessionStorage;
    const bump = (k, v) => {
      const cur = JSON.parse(S.getItem('__diag') || '{"navs":[],"off":[],"n":0}');
      if (k === 'nav') cur.navs.push(v);
      else cur.off.push(v);
      S.setItem('__diag', JSON.stringify(cur));
    };
    const nav = performance.getEntriesByType('navigation')[0];
    bump('nav', {t: Math.round(Date.now()), type: nav ? nav.type : '?'});
    // 心跳沉默：app.js 自己的看门狗每 2 秒查一次 dsappLastPing，这里跟着查
    let lastSeen = null, prevKind = null;
    setInterval(() => {
      const el = document.getElementById('dsapp-offline');
      const k = el ? (el.getAttribute('data-kind') || '?') : null;
      if (k !== prevKind) {
        bump('off', {t: Math.round(Date.now()), from: prevKind, to: k});
        prevKind = k;
      }
    }, 200);
  } catch (e) { /* 记录本身绝不许把页面搞坏 */ }
})();
"""


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def main():
    say("目标 %s" % URL)
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        ctx.add_init_script(WATCH)
        pg = ctx.new_page()
        pg.on("framenavigated",
              lambda f: say("   NAV → %s（%s）" % (f.url[:70], time.strftime("%H:%M:%S"))))
        pg.on("pageerror", lambda e: say("   PAGEERROR %s" % str(e)[:200]))

        # ★ 光看"导航了两次"分不出是谁干的 —— `location.reload` 在 Chrome 里
        #   是 [LegacyUnforgeable]，包装不了。但 CDP 的 Network 域会把每个
        #   请求的 **initiator 调用栈**一起报出来：谁调的、在哪个文件第几行。
        cdp = ctx.new_cdp_session(pg)
        cdp.send("Network.enable")

        def on_req(ev):
            try:
                # ⚠️ 资源类型在事件的**顶层** key `type`，不在 `request` 里
                #    （写进 request 里的话永远拿到 None，一条都打不出来 —— 第一版
                #     就是这么静默漏掉的）。
                if ev.get("type") != "Document":
                    return
                r = ev.get("request", {})
                ini = ev.get("initiator", {}) or {}
                fr = ((ini.get("stack") or {}).get("callFrames") or [{}])[0]
                say("   DOC %s ← initiator=%s %s:%s"
                    % (r.get("url", "")[:60], ini.get("type"),
                       (fr.get("url") or "?").split("/")[-1], fr.get("lineNumber")))
            except Exception as e:
                say("   (cdp 解析失败 %s)" % e)

        cdp.on("Network.requestWillBeSent", on_req)
        t0 = time.time()
        try:
            C.enter_app(pg, email="diagreload-%d@t.local" % int(t0))
            say("== 注册走完了，用时 %.1fs ==" % (time.time() - t0))
        except SystemExit as e:
            say("== 注册失败（%.1fs）：%s ==" % (time.time() - t0, str(e)[:300]))
        pg.wait_for_timeout(3000)
        d = pg.evaluate("() => JSON.parse(sessionStorage.getItem('__diag') || 'null')")
        say("页面生命周期（每个 document 各一行）：")
        for n in (d or {}).get("navs", []):
            say("   t=%s type=%s" % (time.strftime("%H:%M:%S", time.localtime(n["t"] / 1000)),
                                     n["type"]))
        say("遮罩变迁：")
        for o in (d or {}).get("off", []):
            say("   t=%s %s → %s" % (time.strftime("%H:%M:%S", time.localtime(o["t"] / 1000)),
                                     o["from"], o["to"]))
        if not (d or {}).get("off"):
            say("   （一个遮罩都没出现）")
        say("最终：shell=%d auth=%d body=%d 字"
            % (pg.locator(".dsapp-shell").count(), pg.locator(".dsapp-auth").count(),
               len(pg.inner_text("body"))))
        br.close()


if __name__ == "__main__":
    main()
