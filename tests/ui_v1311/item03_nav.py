# -*- coding: utf-8 -*-
"""V13.11 item 3 验收：左侧全局导航的**项**可以拖着重排，顺序跟着账号存。

    bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311
    /home/biomamba/miniconda3/bin/python tests/ui_v1311/item03_nav.py

用户原话：「最左侧导航栏也需要可以通过拖拽改变位置」。

★ 先分清楚是哪一件事：这条栏上有**两个**可拖的量，V13.5 item 8 就有了
  「拖宽」（把手在栏的右边缘，menu_w），这一版加的是「把里面的入口上下
  挪」（把手是每一项左边那个 ⠿，nav_order）。这条用例盯的是后者 ——
  顺带钉一句"拖宽那条路还在"（两件事共用一条栏，很容易改坏一个）。

★ 为什么不能只跑 selftest：那边的断言看的是**源码里有没有某个调用**。
  这一条真正会翻车的地方是「拖动看着完全正常、松手也没报错，只有刷新之后
  顺序回去了」—— 那正是 report() 在 cleanup() 之后读已被置空的模块变量
  时的表现（写完当场踩到）。源码级断言一条都抓不到它，必须真的拖一次、
  刷新一次、再看页面。

★ 浏览器里怎么"真拖"：这里用**合成的 DragEvent**（带一个共享的
  DataTransfer），而不是 Playwright 的 mouse.down/move/up。理由：HTML5
  拖放不是鼠标事件，mouse 序列在 Chromium 里**不会**触发 dragstart ——
  用它测出来的"没反应"是假的。合成事件走的仍然是页面上那条
  document 级 dragstart/dragover/drop 链路，该链路上的每一句都会被执行，
  唯一没被覆盖的是"浏览器认不认 draggable=true 这个属性"，那一条单独
  用 getAttribute 钉（下面第一组）。
"""
import json
import sqlite3
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import db_path, enter_app, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


ORDER_JS = """() => [...document.querySelectorAll('#dsapp_rail_nav > .dsapp-rail-link')]
  .map(e => e.getAttribute('data-nav'))"""

# 合成一次完整的 HTML5 拖放：dragstart → dragover → drop → dragend。
# where = "before" 落在目标行上半格（插到它前面），"after" 落下半格。
DRAG_JS = """(args) => {
  const [from, to, where] = args;
  const nav = document.querySelector('#dsapp_rail_nav');
  const grip = nav.querySelector('.dsapp-rail-link[data-nav="'+from+'"] .dsapp-rail-grip');
  const over = nav.querySelector('.dsapp-rail-link[data-nav="'+to+'"]');
  if (!grip || !over) return 'missing:' + (grip ? '' : 'grip') + (over ? '' : 'over');
  const dt = new DataTransfer();
  const r = over.getBoundingClientRect();
  const y = where === 'after' ? r.bottom - 3 : r.top + 3;
  grip.dispatchEvent(new DragEvent('dragstart',
    {bubbles: true, cancelable: true, dataTransfer: dt}));
  over.dispatchEvent(new DragEvent('dragover',
    {bubbles: true, cancelable: true, dataTransfer: dt,
     clientX: r.left + 20, clientY: y}));
  over.dispatchEvent(new DragEvent('drop',
    {bubbles: true, cancelable: true, dataTransfer: dt}));
  grip.dispatchEvent(new DragEvent('dragend',
    {bubbles: true, cancelable: true, dataTransfer: dt}));
  return 'ok';
}"""

# 拖到栏**外面**松手（没有 drop，只有 dragend）—— DOM 已经被 dragover
# 挪过了，这时候必须还原，否则用户看到顺序变了、刷新又回去了。
DRAG_AWAY_JS = """(args) => {
  const [from, to] = args;
  const nav = document.querySelector('#dsapp_rail_nav');
  const grip = nav.querySelector('.dsapp-rail-link[data-nav="'+from+'"] .dsapp-rail-grip');
  const over = nav.querySelector('.dsapp-rail-link[data-nav="'+to+'"]');
  const dt = new DataTransfer();
  const r = over.getBoundingClientRect();
  grip.dispatchEvent(new DragEvent('dragstart',
    {bubbles: true, cancelable: true, dataTransfer: dt}));
  over.dispatchEvent(new DragEvent('dragover',
    {bubbles: true, cancelable: true, dataTransfer: dt,
     clientX: r.left + 20, clientY: r.top + 3}));
  grip.dispatchEvent(new DragEvent('dragend',
    {bubbles: true, cancelable: true, dataTransfer: dt}));
  return 'ok';
}"""


def nav_order(uid):
    """直接读库 —— 页面上"看着对"不够，要确认**真的存了**。"""
    con = sqlite3.connect(db_path())
    r = con.execute("SELECT ui_prefs FROM users WHERE id=?", (uid,)).fetchone()
    con.close()
    if not r or not r[0]:
        return None
    return json.loads(r[0]).get("nav_order")


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    ctx = br.new_context(viewport={"width": 1600, "height": 950})
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:200])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, _ = seed_or_die(email)
    print("uid=%s" % uid, flush=True)
    pg.wait_for_timeout(3500)

    print("\n== 把手长对了（能拖的**只有**它） ==", flush=True)
    base = pg.evaluate(ORDER_JS)
    print("   起始顺序: %s" % base, flush=True)
    n_grip = pg.locator(".dsapp-rail-grip").count()
    n_link = pg.locator("#dsapp_rail_nav > .dsapp-rail-link").count()
    print("   把手 %d 个 / 导航项 %d 个" % (n_grip, n_link), flush=True)
    C("★★ 每一项都有一个把手", n_grip == n_link and n_link >= 5,
      "%d vs %d" % (n_grip, n_link))
    C("★★★ 只有把手 draggable=true",
      pg.locator(".dsapp-rail-grip").first.get_attribute("draggable") == "true")
    C("★★★ 整行 draggable=false（<a href> 天生可拖，不关掉就成了"
      "「拖链接」：影子在动、松手什么都没发生）",
      pg.locator("#dsapp_rail_nav > .dsapp-rail-link").first
        .get_attribute("draggable") == "false")
    C("★ 把手能聚焦（否则键盘用户够不着 = 只能靠鼠标）",
      pg.locator(".dsapp-rail-grip").first.get_attribute("tabindex") == "0")
    C("★ 顺序的宿主是顶层 input（进模块就永远收不到）",
      pg.get_attribute("#dsapp_rail_nav", "data-input-order") == "nav_order")

    print("\n== 点把手不该导航（它是 <a> 的孩子，不拦就跳走了） ==", flush=True)
    nav_before = pg.evaluate(
        "() => [...document.querySelectorAll('.dsapp-rail-link.active')]"
        ".map(e => e.getAttribute('data-nav'))")
    pg.click('.dsapp-rail-link[data-nav="settings"] .dsapp-rail-grip')
    pg.wait_for_timeout(2000)
    nav_after = pg.evaluate(
        "() => [...document.querySelectorAll('.dsapp-rail-link.active')]"
        ".map(e => e.getAttribute('data-nav'))")
    C("★★ 点把手不切页", nav_before == nav_after and nav_after == ["chat"],
      "%s -> %s" % (nav_before, nav_after))

    print("\n== 把「设置」拖到最前面 ==", flush=True)
    print("   dispatch: %s" % pg.evaluate(DRAG_JS, ["settings", "chat", "before"]),
          flush=True)
    pg.wait_for_timeout(2500)
    dragged = pg.evaluate(ORDER_JS)
    print("   拖完: %s" % dragged, flush=True)
    C("★★★ 拖完顺序变了（设置到了第一位）",
      dragged[:2] == ["settings", "chat"], str(dragged))
    C("★★★ 顺序**存进库了**", nav_order(uid) == dragged,
      "%s vs %s" % (nav_order(uid), dragged))

    print("\n== 刷新之后还是这个顺序（这一步是这条用例真正要抓的） ==", flush=True)
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(4500)
    after_reload = pg.evaluate(ORDER_JS)
    print("   刷新后: %s" % after_reload, flush=True)
    C("★★★ 刷新后顺序保持（顺序丢了但没有报错 = report 读到了已被置空的变量）",
      after_reload == dragged, str(after_reload))
    C("★ 导航项一个不多一个不少（没有因为重排丢项/重复）",
      sorted(after_reload) == sorted(base), str(after_reload))

    print("\n== 拖到栏外面松手：还原，不留下半个改动 ==", flush=True)
    before_away = pg.evaluate(ORDER_JS)
    pg.evaluate(DRAG_AWAY_JS, ["settings", "envs"])
    pg.wait_for_timeout(2000)
    after_away = pg.evaluate(ORDER_JS)
    print("   %s -> %s" % (before_away, after_away), flush=True)
    C("★★ 没有 drop 就不算数，顺序还原", after_away == before_away,
      str(after_away))
    C("★★ 库里也没被写脏", nav_order(uid) == before_away,
      str(nav_order(uid)))

    print("\n== 键盘：聚焦把手，上下方向键挪一格 ==", flush=True)
    pg.eval_on_selector('.dsapp-rail-link[data-nav="settings"] .dsapp-rail-grip',
                        "e => e.focus()")
    pg.keyboard.press("ArrowDown")
    pg.wait_for_timeout(1800)
    kbd = pg.evaluate(ORDER_JS)
    print("   ↓ 一次: %s" % kbd, flush=True)
    C("★★ 方向键把它往下挪了一格", kbd[:2] == ["chat", "settings"], str(kbd))
    C("★★ 键盘这条路同样存库了", nav_order(uid) == kbd, str(nav_order(uid)))
    # 到顶了再按 ↑ 不能越界（越界的话会插到 <nav> 外面去）
    pg.keyboard.press("ArrowUp"); pg.wait_for_timeout(900)
    pg.keyboard.press("ArrowUp"); pg.wait_for_timeout(1800)
    kbd2 = pg.evaluate(ORDER_JS)
    print("   ↑ 两次: %s" % kbd2, flush=True)
    C("★★ 到顶就停住，不越界、不丢项",
      kbd2[0] == "settings" and sorted(kbd2) == sorted(base), str(kbd2))

    print("\n== 拖宽那条路还在（两件事共用一条栏，别改坏一个） ==", flush=True)
    w0 = pg.evaluate("() => Math.round(document.querySelector('.dsapp-rail')"
                     ".getBoundingClientRect().width)")
    hb = pg.evaluate("() => { const h = document.querySelector('.dsapp-rail-handle');"
                     " if (!h) return null; const b = h.getBoundingClientRect();"
                     " return [Math.round((b.left+b.right)/2),"
                     "         Math.round((b.top+b.bottom)/2)]; }")
    if hb:
        pg.mouse.move(hb[0], hb[1])
        pg.mouse.down()
        for k in range(1, 9):
            pg.mouse.move(hb[0] + 15 * k, hb[1])
            pg.wait_for_timeout(50)
        pg.mouse.up()
        pg.wait_for_timeout(2000)
    w1 = pg.evaluate("() => Math.round(document.querySelector('.dsapp-rail')"
                     ".getBoundingClientRect().width)")
    print("   栏宽 %d -> %d" % (w0, w1), flush=True)
    C("★★ 拖右边缘还能改宽度（menu_w 那条路没被这次的改动弄坏）",
      hb is not None and w1 > w0, "%d -> %d" % (w0, w1))

    print("\n== 「恢复默认」把顺序也一起收回去 ==", flush=True)
    goto(pg, "settings", wait=3000)
    pg.wait_for_timeout(1500)
    pg.click('button:has-text("恢复默认")')
    pg.wait_for_timeout(3000)
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(4500)
    reset = pg.evaluate(ORDER_JS)
    print("   恢复后: %s" % reset, flush=True)
    C("★★ 点「恢复默认」之后回到内置顺序", reset == base,
      "%s vs %s" % (reset, base))

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item3_nav.png", full_page=True)
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
