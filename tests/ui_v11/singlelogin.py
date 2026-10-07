# -*- coding: utf-8 -*-
"""V11 item 4b：同一个账号同一时间只允许一个端在用。

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v11/singlelogin.py

★ 为什么这条必须用浏览器验、离线断言一条都不算数：

  这套机制的**全部内容**是"另一个端的下一次心跳会发现自己的 nonce 不是
  当前那一行了，于是把自己这一页换成登录页"。这里面跨了三个地方 ——
  服务端心跳、cookie 里那串 `<token>.<nonce>`、以及 app.js 的
  dsapp:kick 处理器。任何一处对不上，表现都是**什么都没发生**：两端都
  好好地开着，谁也不报错。（而且这恰恰是"静默失效"最舒服的形态：
  离线断言全绿、服务端日志干干净净。）

★ 两端的 nonce 必须真的不一样。用两个 browser context（不是两个 tab）：
  tab 共享 cookie，"第二个 tab 登录"根本不会写第二个 nonce，测了个寂寞。
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

# 心跳间隔由实例上的 DSAPP_LOGIN_POLL_MS 决定（测试实例设成 1.5 秒）。
# 这里给足余量：被踢是"下一次心跳"才发生的，不是即时的。
KICK_WAIT = int(os.environ.get("DSAPP_TEST_KICK_WAIT", "20000"))

chk = C.Chk()

with sync_playwright() as b:
    br = b.chromium.launch()

    # ---- A 端：注册一个新账号 -------------------------------------------------
    ctx_a = br.new_context(viewport={"width": 1280, "height": 800})
    pg_a = ctx_a.new_page()
    C.enter_app(pg_a, nickname="甲端")
    C.goto_chat(pg_a)
    chk("（前置）甲端进到主界面", pg_a.locator(".dsapp-shell").count() > 0)

    tok_a = [c for c in ctx_a.cookies() if c["name"] == "dsapp_token"]
    chk("（前置）甲端拿到了 dsapp_token cookie", len(tok_a) == 1, tok_a)
    nonce_a = tok_a[0]["value"].split(".")[-1] if tok_a else ""
    chk("（前置）★ cookie 值里带着 nonce（`<token>.<nonce>`，不是裸令牌）",
        "." in (tok_a[0]["value"] if tok_a else "") and len(nonce_a) > 8,
        (tok_a[0]["value"][:20] + "…") if tok_a else "")

    # ---- B 端：**另一个** browser context（cookie 不共享）用同一账号登录 ------
    ctx_b = br.new_context(viewport={"width": 1280, "height": 800})
    pg_b = ctx_b.new_page()
    pg_b.goto(C.URL + "?login=1", wait_until="domcontentloaded")
    pg_b.wait_for_selector(".dsapp-auth", timeout=30000)
    pg_b.wait_for_timeout(2000)
    if pg_b.locator("#welcome-login_email").count() == 0:
        pg_b.click("#welcome-go_login")
        pg_b.wait_for_selector("#welcome-login_email", timeout=15000)
        pg_b.wait_for_timeout(800)
    pg_b.fill("#welcome-login_email", C.EMAIL)
    pg_b.fill("#welcome-login_password", C.PW)
    pg_b.click("#welcome-do_login")
    pg_b.wait_for_selector(".dsapp-shell", timeout=40000)
    chk("（前置）乙端用邮箱+密码登录成功", True)

    tok_b = [c for c in ctx_b.cookies() if c["name"] == "dsapp_token"]
    nonce_b = tok_b[0]["value"].split(".")[-1] if tok_b else ""
    chk("★★ 两端拿到的是**不同的** nonce（不然等于没登录第二个端）",
        bool(nonce_b) and nonce_b != nonce_a, "%s vs %s" % (nonce_a, nonce_b))

    # ---- 甲端应该在 ≤2 次心跳内被踢下来 --------------------------------------
    kicked = False
    for _ in range(KICK_WAIT // 1000):
        pg_a.wait_for_timeout(1000)
        if pg_a.locator(".dsapp-kick-note").count():
            kicked = True
            break
        if pg_a.locator(".dsapp-auth").count() and \
                pg_a.locator(".dsapp-shell").count() == 0:
            kicked = True   # 至少是回到登录页了
            break

    chk("★★ 甲端被顶下线了（自己换成了登录页，没有一直开着）", kicked,
        pg_a.inner_text("body")[:200].replace("\n", " | "))

    # ★ 光"回到登录页"是不够的：用户会以为是自己掉线了，第一反应是来问
    #   "是不是坏了"。所以那句话必须在。
    pg_a.wait_for_timeout(1500)
    note = pg_a.locator(".dsapp-kick-note")
    chk("★★ 甲端页面上写清楚了**为什么**（.dsapp-kick-note 那段说明）",
        note.count() == 1 and len(note.inner_text().strip()) > 10,
        note.count() and note.inner_text()[:120])
    if note.count():
        txt = note.inner_text()
        chk("★ 那句话里点明了是「在别的地方登录」（不是「你的密码被改了」这种吓人的说法）",
            "登录" in txt, txt[:120])
    pg_a.screenshot(path=C.OUT + "/10_kicked.png", full_page=False)

    # cookie 必须被**清掉**。留着的话甲端下一次加载会拿着旧 nonce 撞回来，
    # 而服务端只会再踢它一次 —— 表现是登录页反复闪。
    left = [c for c in ctx_a.cookies() if c["name"] == "dsapp_token"]
    chk("★★ 甲端的 cookie 被清掉了（不是只把页面换掉）",
        len(left) == 0 or left[0]["value"].split(".")[-1] != nonce_a,
        left)

    # 地址栏上那个 ?kicked=1 要抹掉。不抹的话，甲端重新登录之后再点"退出登录"
    # （那是一次 reload，地址栏还是这一条）会原样再弹一遍"你在别处登录了" ——
    # 而他这次什么都没发生。
    pg_a.wait_for_timeout(2000)
    chk("★ 地址栏上的 ?kicked=1 被抹掉了（否则下次退出登录会重放这句假话）",
        "kicked=1" not in pg_a.url, pg_a.url)

    # ---- 乙端必须**稳** -------------------------------------------------------
    #
    # 这是整条链上最容易写错的一处：如果 claim 不看 nonce、只看"是不是显式
    # 登录"，那么每次页面刷新都会重新认领一次，两端就会互相顶、无限重载。
    for i in range(3):
        pg_b.reload(wait_until="domcontentloaded")
        pg_b.wait_for_selector(".dsapp-shell", timeout=30000)
        pg_b.wait_for_timeout(4000)
        if pg_b.locator(".dsapp-kick-note").count():
            break
    chk("★★ 乙端刷新三次都还在（自动登录**不认领**，否则两端会互相顶到死）",
        pg_b.locator(".dsapp-kick-note").count() == 0 and
        pg_b.locator(".dsapp-shell").count() > 0,
        pg_b.inner_text("body")[:200].replace("\n", " | "))
    pg_b.screenshot(path=C.OUT + "/11_still_in.png")

    # ---- 反过来：甲端重新登录，该轮到乙端被踢 --------------------------------
    pg_a.goto(C.URL + "?login=1", wait_until="domcontentloaded")
    pg_a.wait_for_selector(".dsapp-auth", timeout=30000)
    pg_a.wait_for_timeout(2000)
    if pg_a.locator("#welcome-login_email").count() == 0:
        pg_a.click("#welcome-go_login")
        pg_a.wait_for_selector("#welcome-login_email", timeout=15000)
        pg_a.wait_for_timeout(800)
    pg_a.fill("#welcome-login_email", C.EMAIL)
    pg_a.fill("#welcome-login_password", C.PW)
    pg_a.click("#welcome-do_login")
    pg_a.wait_for_selector(".dsapp-shell", timeout=40000)

    back = False
    for _ in range(KICK_WAIT // 1000):
        pg_b.wait_for_timeout(1000)
        if pg_b.locator(".dsapp-kick-note").count():
            back = True
            break
    chk("★★ 反过来也成立：甲端重新登录之后，乙端被踢下来（双向，不是单向）",
        back, pg_b.inner_text("body")[:200].replace("\n", " | "))
    chk("★ 甲端自己没事（顶人的那一端不该把自己也顶掉）",
        pg_a.locator(".dsapp-shell").count() > 0 and
        pg_a.locator(".dsapp-kick-note").count() == 0)

    br.close()

sys.exit(chk.done())
