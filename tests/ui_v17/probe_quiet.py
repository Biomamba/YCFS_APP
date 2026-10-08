# -*- coding: utf-8 -*-
"""V17 item 1：断线提示的静默期（www/app.js 的 dsappPromptAllowed/Mark/Owe/Flush）。

对着**隔离实例**（/tmp/dsapp_v17a，8982）跑，不碰生产、不碰任何库。
只用登录页 —— 断线状态机是 app.js 里的纯前端东西，不需要登录。

⚠️ 判据怎么才算硬：
  · 每条断言先看**屏幕上的节点**（#dsapp-offline / #dsapp-offline-mini），
    那是用户真正看到的东西；再看 dsappPromptOwed / dsappNet.state 这两个内部量
    来解释"为什么"。只看内部量 = 自己证明自己。
  · "推迟"和"吞掉"必须分开证：被挡下之后**要**能看到欠账被补上（A3），
    没有 A3 的话"闸门生效"和"提示永远丢了"在 A2 里长得一模一样。
  · dsappPromptAt 是模块级的钟，探针直接把它往回拨 61 秒来代替干等 ——
    这是唯一被"作弊"的地方，它只替代**时间流逝**，不替代任何逻辑：
    补账那一下仍然要由真实的 2 秒看门狗自己触发（A3 不主动调 flush）。
"""
import sys, time
from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8982/"

fails = []
# ⚠️ 原来收尾那句是 `print("全部通过（%d 条）" % 0 or "")` —— `%` 先算，
#    于是**永远**打印「全部通过（0 条）」，而 `or ""` 根本没参与。这里补一个
#    真的计数器：条数是这份探针唯一能自证"跑到了多少"的数，印成 0 就等于把
#    「一条都没跑」和「全跑了且全绿」印成同一行（本仓记过账：自检绿 ≠ 被验过）。
nchk = []
def chk(name, cond, extra=""):
    if cond:
        print("  \033[32m✓\033[0m %s" % name)
    else:
        fails.append(name)
        print("  \033[31m✗ %s\033[0m" % name)
        if extra:
            print("      \033[31m实际是：%s\033[0m" % extra)
    nchk.append(cond)

def snap(pg):
    """一次取回所有判据要用的量（节点 + 内部状态）。"""
    return pg.evaluate("""() => ({
        mini:   !!document.getElementById('dsapp-offline-mini'),
        miniKind: (document.getElementById('dsapp-offline-mini')||{}).getAttribute
                  ? document.getElementById('dsapp-offline-mini').getAttribute('data-kind') : null,
        card:   !!document.getElementById('dsapp-offline'),
        cardKind: document.getElementById('dsapp-offline')
                  ? document.getElementById('dsapp-offline').getAttribute('data-kind') : null,
        state:  window.dsappNet.state,
        owed:   !!window.dsappPromptOwed,
        at:     window.dsappPromptAt,
        quiet:  window.DSAPP_OFFLINE_QUIET_MS,
        cardms: window.DSAPP_OFFLINE_CARD_MS
    })""")

def reset(pg):
    """把这一页恢复成"什么都没发生过"，每条断言前都调一次。"""
    pg.evaluate("""() => {
        dsappHealCancel();
        dsappOfflineHide();
        dsappOfflineMiniClear();
        var d = document.getElementById('dsapp-offline');
        if (d && d.parentNode) d.parentNode.removeChild(d);
        window.dsappPromptAt = 0;
        window.dsappPromptOwed = false;
        window.dsappOutageSince = 0;
        window.dsappCardDismissed = false;
    }""")

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_context(viewport={"width": 1280, "height": 900}).new_page()
    logs = []
    pg.on("console", lambda m: logs.append(m.text))
    pg.goto(URL, wait_until="domcontentloaded", timeout=60000)
    pg.wait_for_selector(".dsapp-auth", timeout=60000)

    # ---- 前置：这一页跑的确实是**改过的那份** app.js ------------------------
    have = pg.evaluate("""() => ({
        allowed: typeof dsappPromptAllowed, mark: typeof dsappPromptMark,
        owe: typeof dsappPromptOwe, flush: typeof dsappOfflineOwedFlush,
        quiet: window.DSAPP_OFFLINE_QUIET_MS
    })""")
    print("== 前置（防假绿）==")
    chk("服务的就是新版 app.js（四个新符号都在）",
        all(have[k] == "function" for k in ("allowed", "mark", "owe", "flush")), have)
    chk("DSAPP_OFFLINE_QUIET_MS 是个正经的间隔（>= 判死线的一半，<= 10 分钟）",
        isinstance(have["quiet"], (int, float)) and have["quiet"] >= 15000
        and have["quiet"] <= 600000, have)
    if fails:
        print("\n前置就红了，后面的都不用跑。")
        b.close(); sys.exit(1)
    QUIET = have["quiet"]

    # ---- A1：第一次提示照常出 ------------------------------------------------
    print("\n== A1：第一次提示（闸门不该挡第一条）==")
    reset(pg)
    pg.evaluate("() => dsappOfflineWarn('disconnected')")
    s = snap(pg)
    chk("小条真的画出来了", s["mini"], s)
    chk("状态是 down（闸门不碰状态）", s["state"] == "down", s)
    chk("记了上屏时刻 dsappPromptAt > 0", s["at"] > 0, s)
    chk("没有欠账（这条没被挡）", s["owed"] is False, s)

    # ---- A2：抖动 —— 好了又断，静默期内不该再说一遍 --------------------------
    print("\n== A2：抖动（好了一下又断）——提示不许重播 ==")
    pg.evaluate("() => dsappOfflineHide()")          # 链路自己接上了
    s = snap(pg)
    chk("恢复时小条撤掉、状态归 up", (not s["mini"]) and s["state"] == "up", s)
    chk("恢复**没有**把静默期归零（归零的话闸门等于没有）", s["at"] > 0, s)

    pg.evaluate("() => dsappOfflineWarn('disconnected')")   # 又断了
    s = snap(pg)
    chk("★★★ 静默期内**不再重播**小条（这就是用户要的「不要这么频繁」）",
        not s["mini"], s)
    chk("★★★ 但状态照样是 down —— 挡的是提示，不是事实（补发队列读的就是它）",
        s["state"] == "down", s)
    chk("★★★ 挡下的那条记成欠账，不是丢掉", s["owed"] is True, s)
    chk("屏幕上一个提示都没有（确认不是「换了个地方画」）",
        (not s["mini"]) and (not s["card"]), s)

    # ---- A3：静默期一过，欠的那条要**自己**回来 ------------------------------
    print("\n== A3：静默期到点 —— 欠的提示由看门狗自己补上 ==")
    pg.evaluate("(q) => { window.dsappPromptAt = Date.now() - q - 1000; }", QUIET)
    # ⚠️ 这里**故意不调** dsappOfflineOwedFlush()：等真实的 2 秒看门狗自己跑。
    got, t0 = False, time.time()
    while time.time() - t0 < 6:
        if snap(pg)["mini"]:
            got = True; break
        time.sleep(0.25)
    s = snap(pg)
    chk("★★★ 静默期一到，被挡下的那条**自己**回来了（推迟 ≠ 吞掉）", got, s)
    chk("补上之后欠账清掉", s["owed"] is False, s)
    chk("补上的仍是小条那一档（没被升级成整页卡片）", s["mini"] and not s["card"], s)

    # ---- A4：大卡片也过闸门，而且**过闸门之后仍然出得来** --------------------
    print("\n== A4：整页卡片同样受闸门管，但不许被永久挡住 ==")
    reset(pg)
    # 造一个「已经断够久」的局面：断电时钟往回拨 40 秒（> CARD_MS）
    pg.evaluate("""() => {
        dsappNetSet('down', 'probe');
        window.dsappOutageSince = Date.now() - 40000;
        window.dsappPromptAt = Date.now();      /* 刚刚说过话 → 静默期内 */
    }""")
    r1 = pg.evaluate("() => dsappOfflineEscalate('down')")
    s = snap(pg)
    chk("静默期内铺卡片被挡下（返回 false、屏幕干净）",
        r1 is False and not s["card"], {"ret": r1, **s})
    chk("挡下时也记了欠账", s["owed"] is True, s)

    # ⚠️ 把 r1 那一步留下的卡片**从 DOM 里拿掉**再验 r2：不拿掉的话
    #    "卡片在不在"在 r2 里恒为真（r1 要是漏了它就一直在），r2 就成了一条
    #    永远通过的死断言 —— 变异测试里当场量到过这件事（M2 打进去 r2 照样绿）。
    pg.evaluate("""() => {
        var d = document.getElementById('dsapp-offline');
        if (d && d.parentNode) d.parentNode.removeChild(d);
    }""")
    pg.evaluate("(q) => { window.dsappPromptAt = Date.now() - q - 1000; }", QUIET)
    r2 = pg.evaluate("() => dsappOfflineEscalate('down')")
    s = snap(pg)
    chk("静默期一过卡片照出（返回 true、节点在、内容是 disconnected 那一版）",
        r2 is True and s["card"] and s["cardKind"] == "disconnected", {"ret": r2, **s})
    chk("卡片上屏也勾掉了欠账", s["owed"] is False, s)

    # ---- A5：自愈那条**不走**闸门（它说的是一句新话，说完就真刷新了）--------
    print("\n== A5：自愈的那句说明不受闸门影响 ==")
    reset(pg)
    pg.evaluate("() => { window.dsappPromptAt = Date.now(); }")   # 刚刚才说过话
    pg.evaluate("() => dsappHealNote('探针：正在等服务器回来。')")
    s = snap(pg)
    chk("★★ 静默期内自愈仍然能把卡片铺出来（否则那几句话写进空气里）",
        s["card"], s)
    body = pg.evaluate("""() => {
        var b = document.querySelector('#dsapp-offline .dsapp-offline-body');
        return b ? b.innerText : '';
    }""")
    chk("自愈那句话真的写进了卡片里", "探针：正在等服务器回来。" in body, body[:80])

    # ---- A6：收尾之后不留垃圾 -------------------------------------------------
    print("\n== A6：收尾 ==")
    reset(pg)
    s = snap(pg)
    chk("reset 之后页面干净（无小条、无卡片、状态 up）",
        (not s["mini"]) and (not s["card"]) and s["state"] == "up", s)

    b.close()

print()
if fails:
    print("\033[31m%d 条没过：\033[0m" % len(fails))
    for f in fails:
        print("   -", f)
    sys.exit(1)
print("\033[32m全部通过（%d 条）\033[0m" % len(nchk))
