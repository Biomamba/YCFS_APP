# -*- coding: utf-8 -*-
"""V9 item 1：用户须知（注册必勾 / 每 7 天重申 / 同意日志）。

对着一次性实例（8898）跑。会真的注册账号，会**直接改那个临时库**去伪造
"7 天前同意过"和"同意的是旧版本"—— 这两种状态没有别的办法在几秒钟内造出来，
而它们恰恰是这条需求的核心。

⚠️ 只碰 $DATA_ROOT 底下的库，而且跑之前会确认那个目录在 /tmp 下。
   线上那份库是 shiny:shiny 644，我这边连写都写不进去 —— 但还是先拦一道，
   因为"写不进去"报的是权限错，"写错库"报的是没有错。
"""
import io
import os
import random
import sqlite3
import sys
import time

from playwright.sync_api import sync_playwright

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v9")


def _guard(app):
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        if ln.strip().startswith("DSAPP_DATA_ROOT="):
            root = ln.strip().split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：.Renviron 里没有 DSAPP_DATA_ROOT。")
    if not (root.startswith("/tmp/") or root.startswith("/var/tmp/")):
        sys.exit("拒绝运行：DSAPP_DATA_ROOT=%s 不在临时目录下。" % root)
    return root


DATA_ROOT = _guard(APP)
DB = os.path.join(DATA_ROOT, "dsapp.sqlite3")
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


def sql(q, args=()):
    """直接读那个一次性库。WAL 模式，读得到已提交的数据。"""
    con = sqlite3.connect(DB, timeout=5)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def exec_sql(q, args=()):
    con = sqlite3.connect(DB, timeout=5)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def register(pg, tag):
    """在注册页填一份资料。返回 (email, password)。"""
    email = "v9tos_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        if pg.locator("#welcome-go_register").count():
            pg.click("#welcome-go_register")
            pg.wait_for_timeout(1200)
    pg.fill("#welcome-nickname", "须知测试")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000005")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    return email, pw


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    # -------------------------------------------------------------------
    print("\n== 注册页：须知摆在勾选框上面，不勾就注册不了 ==")
    # -------------------------------------------------------------------
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    # 上一个测试可能留下了登录 cookie，先退出来
    if pg.locator(".dsapp-shell").count():
        if pg.locator("#logout").count():
            pg.click("#logout")
            pg.wait_for_timeout(6000)
        pg.goto(URL + "?login=1", wait_until="domcontentloaded")
        pg.wait_for_timeout(3000)
    if pg.locator("#welcome-nickname").count() == 0 and pg.locator("#welcome-go_register").count():
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1200)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email, pw = register(pg, tag)

    tos = pg.locator(".dsapp-tos")
    chk("★ 注册页上有用户须知", tos.count() >= 1, tos.count())
    # ⚠️ V10 起正文换成了 data/user_must_know_V1.txt 里的正式条款，而且改成
  #    **渲染 Markdown**（V9 是把 `##` / `**` 原样打在屏幕上）。所以这里
  #    数的是真的 <h2> 元素 —— `.dsapp-tos-sec` 那个类已经没有了，
  #    留着它这条断言会永远红，而红的原因和"功能坏了"毫无关系。
    secs = pg.locator(".dsapp-tos-md h2")
    chk("★ 须知是分节的（%d 节 <h2>）" % secs.count(), secs.count() >= 8,
        secs.count())
    body = tos.first.inner_text() if tos.count() else ""
    chk("★ 标记真的被渲染了（屏幕上没有字面的 '##'/'**'）",
        "##" not in body and "**" not in body)
    # 这几条是这个产品**特有**的风险。写成"我们重视您的隐私"那种放之四海
    # 皆准的句子的话，用户读不出信息，而这套同意就只剩形式。
    for kw in ["API 密钥", "加密存储", "明文", "转发", "客服微信"]:
        chk("★ 须知里写到了「%s」" % kw, kw in body)
    # ⚠️ 不要钉具体版本号：V9 是 "1.0"、V10 是 "2.0"，下次改条款还会变。
    #    钉死了就是"每次改文案都要来改测试"，而改测试的人多半顺手把它改松。
    #    真正要验的是**这行小字在、而且给的是给人看的那个版本号**
    #    （不是库里存的那串 "2.0+7f3a2c1d"）。
    _meta = (pg.locator(".dsapp-tos-meta").first.inner_text()
             if pg.locator(".dsapp-tos-meta").count() else "")
    chk("★ 版本号显示出来了（而且不带指纹）",
        "版本" in _meta and "+" not in _meta, _meta)
    chk("★ 须知是一块**限高可滚**的区域（不滚的话勾选框会被挤出屏幕）",
        pg.evaluate("""() => {
          const e = document.querySelector('.dsapp-tos');
          return e ? getComputedStyle(e.parentElement).overflowY : null;
        }""") in ("auto", "scroll"))
    # 勾选框必须在须知**下面**
    chk("★ 勾选框排在须知正文下面（先读后勾，顺序不能反）",
        pg.evaluate("""() => {
          const t = document.querySelector('.dsapp-tos');
          const c = document.querySelector('.dsapp-auth input[type=checkbox]');
          if (!t || !c) return null;
          return (t.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
        }""") is True)

    # 不勾就提交
    before_n = sql("SELECT COUNT(*) FROM users")[0][0]
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(4000)
    after_n = sql("SELECT COUNT(*) FROM users")[0][0]
    chk("★★ 不勾同意 → 注册被拒（账号数 %d → %d）" % (before_n, after_n),
        after_n == before_n)
    chk("★ 而且明确说了为什么",
        "用户须知" in pg.inner_text("body"),
        pg.inner_text("body")[:150].replace("\n", " "))
    chk("★ 还停在注册页（没被放进去）", pg.locator(".dsapp-shell").count() == 0)

    # -------------------------------------------------------------------
    print("\n== 勾上注册 → 留一条 source=register 的日志 ==")
    # -------------------------------------------------------------------
    pg.check(".dsapp-auth input[type=checkbox]")
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count():
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    try:
        pg.wait_for_selector(".dsapp-shell", timeout=30000)
        entered = True
    except Exception:
        entered = False
    chk("★ 勾上之后注册成功并进入主界面", entered,
        pg.inner_text("body")[:200].replace("\n", " "))

    uid = sql("SELECT id FROM users WHERE email = ?", (email,))
    uid = uid[0][0] if uid else None
    chk("★ 账号建出来了", uid is not None, uid)

    if uid:
        rows = sql("SELECT version, source, agreed_at FROM consent_log "
                   "WHERE user_id = ? ORDER BY id", (uid,))
        # ⚠️ V10 起库里存的是「显示版本 + 正文指纹」（'2.0+7f3a2c1d'）：
        #    改了条款却忘了抬版本号时，靠指纹也能把人拦下来重新确认。
        #    所以这里认的是**前缀**，不是某一个写死的字符串。
        chk("★★ 同意日志写了一条（source=register，version=2.0+指纹）",
            len(rows) == 1 and rows[0][1] == "register" and
            rows[0][0].startswith("2.0+"), rows)
        u = sql("SELECT tos_version, tos_agreed_at FROM users WHERE id = ?", (uid,))
        chk("★ users 上那两列也补上了（免得每次进应用都扫一遍日志表）",
            u and u[0][0] == rows[0][0] and u[0][1], u)

    # -------------------------------------------------------------------
    print("\n== 7 天之后：老用户被拦下来重新确认 ==")
    # -------------------------------------------------------------------
    if uid:
        # 伪造成"8 天前同意的"。没法等 7 天，只能直接改那个临时库。
        old = time.strftime("%Y-%m-%d %H:%M:%S",
                            time.localtime(time.time() - 8 * 86400))
        exec_sql("UPDATE users SET tos_agreed_at = ? WHERE id = ?", (old, uid))
        n_before = sql("SELECT COUNT(*) FROM consent_log WHERE user_id = ?", (uid,))[0][0]

        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        chk("★★ 超过 7 天 → 被拦在确认页，进不去主界面",
            pg.locator(".dsapp-tos").count() >= 1 and
            pg.locator(".dsapp-shell").count() == 0,
            "shell=%d tos=%d" % (pg.locator(".dsapp-shell").count(),
                                 pg.locator(".dsapp-tos").count()))
        txt = pg.inner_text("body")
        chk("★ 说清了为什么被拦（不是一句干巴巴的「请重新确认」）",
            "7 天" in txt, txt[:200].replace("\n", " "))
        chk("★ 显示上次确认是什么时候", "上次确认" in txt)
        pg.screenshot(path=os.path.join(OUT, "v9_tos_gate.png"))

        # 不勾就点同意 → 不该放行
        pg.click("#tos_gate-do_agree")
        pg.wait_for_timeout(3000)
        chk("★★ 不勾就点「同意并继续」→ 不放行",
            pg.locator(".dsapp-shell").count() == 0)
        chk("★ 且日志**没有**多出来一条（没勾不算同意）",
            sql("SELECT COUNT(*) FROM consent_log WHERE user_id = ?",
                (uid,))[0][0] == n_before)

        pg.check("#tos_gate-agree")
        pg.click("#tos_gate-do_agree")
        pg.wait_for_timeout(6000)
        chk("★★ 勾上再点 → 进主界面了", pg.locator(".dsapp-shell").count() >= 1,
            pg.inner_text("body")[:200].replace("\n", " "))

        rows2 = sql("SELECT source, version FROM consent_log WHERE user_id = ? "
                    "ORDER BY id", (uid,))
        chk("★★ 日志多了一条 source=weekly（不是覆盖，是追加）",
            len(rows2) == n_before + 1 and rows2[-1][0] == "weekly", rows2)
        chk("★ 原来的那条 register 还在（日志只增不改）",
            rows2[0][0] == "register", rows2)

        # -----------------------------------------------------------------
        print("\n== 须知改版：版本对不上就要重新读一遍 ==")
        # -----------------------------------------------------------------
        exec_sql("UPDATE users SET tos_version = '0.9', tos_agreed_at = ? WHERE id = ?",
                 (time.strftime("%Y-%m-%d %H:%M:%S"), uid))
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        chk("★★ 版本对不上 → 重新拦下来（哪怕刚刚才同意过、1 秒都没过）",
            pg.locator(".dsapp-tos").count() >= 1 and
            pg.locator(".dsapp-shell").count() == 0,
            "shell=%d" % pg.locator(".dsapp-shell").count())
        txt = pg.inner_text("body")
        chk("★ 说的是「须知有更新」而不是「超过 7 天」（两种原因不能混）",
            "更新" in txt and "超过 7 天" not in txt, txt[:200].replace("\n", " "))
        chk("★ 并且告诉你上次同意的是哪一版",
            "0.9" in txt, [l for l in txt.split("\n") if "0.9" in l][:2])

        # -----------------------------------------------------------------
        print("\n== 「不同意」要有体面的退路 ==")
        # -----------------------------------------------------------------
        chk("★ 确认页上有「不同意，退出登录」", pg.locator("#tos_gate-do_logout").count() == 1)
        pg.click("#tos_gate-do_logout")
        pg.wait_for_timeout(8000)
        # ⚠️ 断言的是"落回入口页、而且不在确认页上"，**不是**某个具体输入框。
        #    第一版这里写的是 #welcome-email —— 那是**注册**页的邮箱框，而
        #    退出之后落的是登录页（#welcome-login_email）。于是这条断言
        #    在功能完全正常的情况下也是红的，白查了半天。
        chk("★★ 点了之后回到入口页（不是卡在确认页上）",
            pg.locator(".dsapp-auth").count() >= 1 and
            pg.locator(".dsapp-tos").count() == 0 and
            pg.locator(".dsapp-shell").count() == 0,
            "auth=%d tos=%d shell=%d" % (pg.locator(".dsapp-auth").count(),
                                         pg.locator(".dsapp-tos").count(),
                                         pg.locator(".dsapp-shell").count()))
        # cookie 没清掉的话，刷新一下又会被自动登回来 —— 而"不同意"这条
        # 出路就变成了一个永远绕不出去的环（用户只能自己去清浏览器数据）。
        chk("★★ 登录 cookie 真的清掉了（不清就是死循环：reload 又被登回来）",
            "dsapp_token" not in pg.evaluate("() => document.cookie"),
            pg.evaluate("() => document.cookie")[:80])
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(5000)
        chk("★★ 再刷一次仍然进不去（不是「同意/退出」来回弹）",
            pg.locator(".dsapp-shell").count() == 0 and
            pg.locator(".dsapp-tos").count() == 0,
            "shell=%d tos=%d" % (pg.locator(".dsapp-shell").count(),
                                 pg.locator(".dsapp-tos").count()))
        declined = sql("SELECT COUNT(*) FROM audit_log WHERE user_id = ? "
                       "AND action = 'tos_declined'", (uid,))
        chk("★ 拒绝这件事也留了痕（只看同意的话，数据会显示「所有人都同意了」）",
            declined and declined[0][0] >= 1, declined)

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
