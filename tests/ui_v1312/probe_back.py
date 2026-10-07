# -*- coding: utf-8 -*-
"""设置页三个「保存并返回对话」：各绑各的，点了都要跳回对话页。

    python3 tests/ui_v1312/probe_back.py

V13.12 item 20 顺手修的：那三份卡原来共用 `back_to_chat` 一个 input id。
功能上通（三个绑同一个 input，点哪个都跳），但 Shiny 每次重新绑定都打一条
Duplicate input ID 的警告 —— 实测跑一轮生成刷 156 条，排查别的问题时会被
它带着跑偏。

拆成三个 id 之后**风险换了个方向**：万一某个 key 的 observeEvent 没接上，
那一页的按钮就变成"点了没反应"。而另外两页是好的，所以只点一页根本试不
出来。这条探针三页挨个点。

⚠️ 设置页的四个页签**都在 DOM 里**（没选中的只是 display:none，见
   mod_settings_ui 顶上那段说明）—— 所以取按钮必须按可见性过滤，
   否则点到的是隐藏那一页上的。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8913/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1312/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1312")

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

KEYS = ["ui", "exec", "account"]
TABS = {"ui": "界面", "exec": "执行", "account": "账号"}


def on_chat(pg):
    """当前是不是对话页 —— 认输入框，不认标题文字。"""
    box = pg.locator("#chat-input")
    return box.count() > 0 and box.first.is_visible()


def main():
    k = C.Chk()
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1600, "height": 950})
        dups = []
        pg.on("console", lambda m: dups.append(m.text)
              if "Duplicate input ID" in m.text else None)
        e = C.enter_app(pg)
        C.seed_or_die(e)
        C.goto(pg, "settings")
        pg.wait_for_timeout(2500)

        # 三个 input id 都在，而且**各只有一个** —— 这才是"不重复绑定"。
        cnt = pg.evaluate("""(keys) => {
          var o = {};
          keys.forEach(function (k) {
            o[k] = document.querySelectorAll("[id='settings-back_to_chat_" + k + "']").length;
          });
          o['__old__'] = document.querySelectorAll("[id='settings-back_to_chat']").length;
          return o;
        }""", KEYS)
        k("★★★ 三个按钮各一个 id，老的那个已经不在了",
          all(cnt[key] == 1 for key in KEYS) and cnt.get("__old__") == 0,
          repr(cnt))

        dups.clear()
        for key in KEYS:
            # 先切到那一页
            tab = pg.locator("a.nav-link", has_text=TABS[key]).first
            tab.click()
            pg.wait_for_timeout(1200)
            btn = pg.locator("[id='settings-back_to_chat_%s']" % key)
            vis = btn.count() and btn.first.is_visible()
            k("★★ 「%s」页底部那个按钮在（可见）" % TABS[key], vis)
            if not vis:
                continue
            btn.first.click()
            pg.wait_for_timeout(2500)
            k("★★★ 点「%s」页那个按钮 → 回到对话页" % TABS[key], on_chat(pg))
            C.goto(pg, "settings")
            pg.wait_for_timeout(2000)

        k("★★★ 整场没有 Duplicate input ID 警告（基线是每轮 156 条）",
          not dups, "；".join(d[:60] for d in dups[:2]))

        pg.screenshot(path=C.OUT + "/settings_back.png", full_page=True)
        b.close()
    return k.done()


if __name__ == "__main__":
    sys.exit(main())
