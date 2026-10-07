# -*- coding: utf-8 -*-
"""V13.6 item 1：退出登录 / 异端登录之后，模型服务里的 API 信息不能被清空。

用户原话：
  「每次退出登录或异端登录时api信息会清空，解决一下这个问题」

★ 为什么必须用真浏览器，离线断言一条都不算数：

  根因是**时序**，不是逻辑。整页重载 → 旧会话的 websocket 断开 → Shiny 把
  这一端的 input 全部置 NULL → 800ms 后那个防抖保存到期 → 这几个 NULL 被
  当成"用户把输入框清空了"写进库。"input 被置 NULL"这件事**只在真 websocket
  断开时发生**，离线测试里造不出来 —— 服务端逻辑逐字没错，错的是它拿到的东西。

★ 为什么两个触发都要测：

  用户报的就是两个，而这两条的**入口完全不同**：
    · 退出登录 —— 用户点按钮，走 session$reload()；
    · 异端登录 —— 同一个账号在别处登录，这一端被心跳发现、被
      window.location.replace() 赶下去。
  两条最后都是整页重载，走同一段保存代码。但"走同一段代码"是我们的**假设**，
  而这一项要修的正是"假设了却没验"的那类 bug，所以两条都真的走一遍。

★ 判据为什么是**解密之后**比：

  V13.1 item 9 起 llm_api_key 是密文，而密文是**随机 IV** 的 —— 同一把 Key
  写两次得到的字符串完全不同。所以"库里那格还是原来那把 Key"这句，
  在密文世界里**没有**"直接比字符串"的写法：写没写过、还是不是同一把，
  只能解出来看。（比长度、比前缀都是假判据：被改成另一把 Key 照样通过。）
"""
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, OUT, PW, enter_app, goto, r_decrypt,   # noqa: E402
                     seed_or_die)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

KEY = "sk-V136-LOGOUT-KEY-0001"
RELAY = "https://relay.v136.example/v1"

# 异端登录：实例上的心跳间隔是 1.5 秒（测试实例的 .Renviron 里设的）。
# 被踢是"下一次心跳"才发生的，给足余量。
KICK_WAIT = int(os.environ.get("DSAPP_TEST_KICK_WAIT", "25000"))


def dump(db, uid):
    """库里那四样到底是什么 —— 原文，不解释。"""
    con = sqlite3.connect(db)
    row = con.execute("SELECT llm_vendor, llm_model, llm_base_url, llm_api_key "
                      "FROM users WHERE id = ?", (uid,)).fetchone()
    con.close()
    return {"vendor": row[0], "model": row[1], "base": row[2], "key_enc": row[3]}


def key_plain(rec):
    return r_decrypt([rec["key_enc"]])[0]


def snapshot(pg):
    """界面上那三个控件此刻的值（不用展开面板，DOM 一直在）。"""
    return pg.evaluate("""() => {
      var g = (s) => { var e = document.querySelector(s); return e ? e.value : null; };
      return {key: g('#model-api_key'), vendor: g('#model-vendor'),
              model: g('#model-model'), base: g('#model-base_url')};
    }""")


def why(pg):
    """进不去的时候，把"它当时到底在哪一屏"记下来。

    ⚠️ 没有这几行的话，失败信息只有一句「没进主界面」—— 而这一句离真正的
    原因最远：可能停在空白首屏（还没 flush）、可能停在登录页（按钮没点上）、
    可能停在用户须知的闸门上（那是另一个账号状态）。三种情况的修法完全不同，
    靠"再跑一遍看看"是猜。
    """
    try:
        txt = pg.inner_text("body")
    except Exception:
        txt = "（读不到 body）"
    return "url=%s ｜ 首屏 %d 字：%s" % (pg.url, len(txt), txt[:200].replace("\n", " "))


def login_as(pg, email, seconds=60):
    """在登录页用这个账号进主界面。返回 (进没进去, 走不过去时的现场)。"""
    pg.wait_for_selector(".dsapp-auth", timeout=60000)
    pg.wait_for_timeout(2000)
    if pg.locator("#welcome-login_email").count() == 0:
        pg.click("#welcome-go_login")
        pg.wait_for_selector("#welcome-login_email", timeout=20000)
        pg.wait_for_timeout(1000)
    pg.fill("#welcome-login_email", email)
    pg.fill("#welcome-login_password", PW)
    pg.click("#welcome-do_login")
    for _ in range(seconds):
        pg.wait_for_timeout(1000)
        if pg.locator(".dsapp-shell").count():
            return True, ""
    return False, why(pg)


def relogin(pg, email):
    """从登录页再进一次主界面。"""
    return login_as(pg, email)[0]


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 1000})
    page = ctx.new_page()
    errs = []
    page.on("pageerror", lambda e: errs.append(str(e)))

    email = enter_app(page, nickname="登出")
    uid, db = seed_or_die(email)
    print("== uid=%d db=%s ==" % (uid, db), flush=True)

    # ---- 造出"用户已经配好了"的状态 ---------------------------------------
    goto(page, "settings", wait=3500)
    page.evaluate("() => { var d = document.querySelector('.dsapp-rail-model');"
                  " if (d) d.open = true; }")
    page.wait_for_timeout(800)
    page.fill("#model-api_key", KEY)
    page.wait_for_timeout(1200)
    # ★ 手填的中转地址：用户报的"信息清空"里，**这一格是唯一找不回来的** ——
    #   厂商/模型能靠默认值兜回来，地址是用户自己敲的，抹掉就是抹掉了。
    page.fill("#model-base_url", RELAY)
    page.wait_for_timeout(1200)
    page.click("#model-commit")
    page.wait_for_timeout(4000)

    got = dump(db, uid)
    chk("（前置）四样都落库了：厂商 / 模型 / 手填的中转地址 / Key",
        got["vendor"] == "deepseek" and got["model"] == "deepseek-flash" and
        got["base"] == RELAY and key_plain(got) == KEY,
        extra="vendor=%r model=%r base=%r key=%r"
              % (got["vendor"], got["model"], got["base"], key_plain(got)))

    # =====================================================================
    print("\n== 触发一：退出登录 ==", flush=True)
    # =====================================================================
    page.click("#logout")
    page.wait_for_timeout(8000)
    after = dump(db, uid)
    chk("★★ 退出登录之后**库里的 Key 还在**（用户报的就是这一条）",
        key_plain(after) == KEY,
        extra="解密出来是 %r" % (key_plain(after),))
    chk("★★ 厂商 / 模型 / 手填的地址也都没被抹掉",
        after["vendor"] == "deepseek" and after["model"] == "deepseek-flash"
        and after["base"] == RELAY,
        extra="vendor=%r model=%r base=%r"
              % (after["vendor"], after["model"], after["base"]))

    chk("★ 重新登录进得去", relogin(page, email))
    # ⚠️ **这里不展开面板**。展开会触发一次渲染，把"输入框里到底有没有值"
    #    这个判据搅浑 —— 要问的正是"页面刚渲染出来那一刻它是不是空的"。
    snap0 = snapshot(page)
    chk("★★ 刚进主界面（面板还关着）Key 就已经填好了 —— 不是等展开才补的",
        snap0["key"] == KEY, extra="输入框里是 %r" % (snap0["key"],))
    chk("★★ 手填的中转地址也回来了（这一格丢了就是永久丢）",
        snap0["base"] == RELAY, extra="地址栏是 %r" % (snap0["base"],))

    for tag, wait in (("+5s", 5000), ("+13s", 8000)):
        page.wait_for_timeout(wait)
        got = dump(db, uid)
        chk("★★ 重登 %s 之后库里还是那四样（防抖那一拍没把它抹掉）" % tag,
            got["vendor"] == "deepseek" and got["model"] == "deepseek-flash"
            and got["base"] == RELAY and key_plain(got) == KEY,
            extra="vendor=%r model=%r base=%r key=%r"
                  % (got["vendor"], got["model"], got["base"], key_plain(got)))

    # =====================================================================
    print("\n== 触发二：异端登录（同一账号在别处登录，这一端被踢）==", flush=True)
    # =====================================================================
    ctx_b = br.new_context(viewport={"width": 1280, "height": 800})
    pg_b = ctx_b.new_page()
    pg_b.goto(os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8896/") +
              "?login=1", wait_until="domcontentloaded")
    ok_b, why_b = login_as(pg_b, email)
    chk("（前置）乙端用同一个账号登进来了", ok_b, extra=why_b)

    kicked = False
    for _ in range(KICK_WAIT // 1000):
        page.wait_for_timeout(1000)
        if "kicked=1" in page.url or page.locator(".dsapp-auth").count():
            kicked = True
            break
    chk("（前置）甲端真的被顶下线了（没踢下来的话下面那条是空转）", kicked,
        extra="地址是 %s" % page.url)

    page.wait_for_timeout(6000)
    after = dump(db, uid)
    chk("★★ 被顶下线之后库里的 Key 还在",
        key_plain(after) == KEY, extra="解密出来是 %r" % (key_plain(after),))
    chk("★★ 厂商 / 模型 / 手填的地址也都没被抹掉（异端登录这一路）",
        after["vendor"] == "deepseek" and after["model"] == "deepseek-flash"
        and after["base"] == RELAY,
        extra="vendor=%r model=%r base=%r"
              % (after["vendor"], after["model"], after["base"]))

    chk("★ 被踢之后重新登录进得去", relogin(page, email))
    snap1 = snapshot(page)
    chk("★★ 重新登录后 Key 又填好了（异端登录这一路）",
        snap1["key"] == KEY, extra="输入框里是 %r" % (snap1["key"],))
    chk("★ 地址也还在", snap1["base"] == RELAY, extra="地址栏是 %r" % (snap1["base"],))

    chk("★ 全程没有 JS 报错", not errs, extra=errs[:3])

    page.screenshot(path=OUT + "/logout_key.png", full_page=True)
    br.close()

sys.exit(chk.done())
