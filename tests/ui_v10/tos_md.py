# -*- coding: utf-8 -*-
"""V10 item 1 + 2：用户须知按 Markdown 渲染，以及 consent_log 消失后不能锁死用户。

对着一次性实例（8898）跑。会真的注册账号、**直接改那个临时库**。

★ 这个文件里最要紧的一段是最后那个「把 consent_log 整张表删掉」——
  它复现的是 2026-09-15 线上那次事故的用户视角：
      点了「同意并继续」→ 没能记录你的确认（no such table: consent_log）
      → 被须知闸门永久挡在应用外面。
  而当时**自检全绿**：测试实例每次都是新起的进程，连接是新的、表是全的，
  天然走不到那条路上。所以这里必须自己把现场造出来。

⚠️ 只碰 $DATA_ROOT 底下的库，跑之前确认那个目录在 /tmp 下。
   线上那份库我根本写不进去 —— 但"写不进去"报的是权限错，
   "写错库"报的是没有错，后者更贵。
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
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v10")


def _guard(app):
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身（线上那份代码）。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("DSAPP_DATA_ROOT="):
            root = ln.split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：%s 里没有 DSAPP_DATA_ROOT。" % envf)
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
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


def sql(q, args=()):
    con = sqlite3.connect(DB, timeout=10)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def exec_sql(q, args=()):
    con = sqlite3.connect(DB, timeout=10)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def to_login(pg, wait=3000):
    """回到入口页的登录视图（上一个测试可能留了 cookie）。"""
    if pg.locator(".dsapp-shell").count():
        if pg.locator("#logout").count():
            pg.click("#logout")
            pg.wait_for_timeout(6000)
        pg.goto(URL + "?login=1", wait_until="domcontentloaded")
        pg.wait_for_timeout(wait)


def register(pg, tag, nick="须知渲染"):
    email = "v10tos_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        if pg.locator("#welcome-go_register").count():
            pg.click("#welcome-go_register")
            pg.wait_for_timeout(1200)
    pg.fill("#welcome-nickname", nick)
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000006")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    return email, pw


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    # =====================================================================
    print("\n== item 1：须知正文是**渲染过**的 Markdown，不是把标记打在屏幕上 ==")
    # =====================================================================
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)
    to_login(pg)
    if pg.locator("#welcome-nickname").count() == 0 and pg.locator("#welcome-go_register").count():
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)

    tos = pg.locator(".dsapp-tos")
    chk("★ 注册页上有用户须知", tos.count() >= 1, tos.count())

    # ---- 这几条是"渲染了没有"的**唯一**判据：看 DOM，不看源码 ----
    # V9 那版把正文当成纯文本转义 + <br>，屏幕上是一堆字面的 `## 一、服务说明`
    # 和 `**Biomamba 生信基地**`。所以这里数的是**真的元素**。
    h2 = pg.locator(".dsapp-tos-md h2")
    chk("★★ 正文渲染出了标题元素（%d 个 <h2>）—— V9 这里是一个都没有的"
        % h2.count(), h2.count() >= 8, h2.count())
    ols = pg.locator(".dsapp-tos-md ol")
    chk("★★ 十条的编号列表渲染成了 <ol>（%d 个）" % ols.count(),
        ols.count() >= 8, ols.count())
    lis = pg.locator(".dsapp-tos-md li")
    chk("★ 列表项加起来有几十条（%d 条）" % lis.count(), lis.count() >= 30,
        lis.count())
    chk("★ 加粗渲染成了 <strong>（不是字面的两个星号）",
        pg.locator(".dsapp-tos-md strong").count() >= 3,
        pg.locator(".dsapp-tos-md strong").count())

    body = tos.first.inner_text()
    chk("★★ 屏幕上再也看不到字面的 '##'（V9 的症状）", "##" not in body)
    chk("★★ 屏幕上再也看不到字面的 '**'（V9 的症状）", "**" not in body)
    # 反过来：标记没了，内容一个字都不能少 —— 否则修的就是"看不见"而不是"渲染对"
    for kw in ["服务说明", "账号与密钥安全", "使用规范", "费用与计费",
               "数据与隐私", "服务可用性", "账号与服务终止", "知识产权",
               "免责声明", "协议变更与联系我们"]:
        chk("★★ 第「%s」条在页面上" % kw, kw in body)
    for kw in ["Biomamba 生信基地", "Biomamba_zhushou", "加密存储",
               "不以明文形式保存密钥"]:
        chk("★ 正文里的「%s」在页面上" % kw, kw in body)

    # ⚠️ 这条量的是**计算出来的字号**，不是"CSS 里写没写"。
    #    V9 的字号挂在 .dsapp-tos-sec 上，而 V10 换 Markdown 之后那个类
    #    不再生成了 —— 漏搬这两条的话正文会退回 16px，包装盒高度却是固定的
    #    22rem，表现是"一屏能看到的条款少了一大截"。类名、语法全对，
    #    源码级断言一条都不会红。
    fs = pg.evaluate("""() => parseFloat(getComputedStyle(
      document.querySelector('.dsapp-tos-md')).fontSize)""")
    chk("★★ 正文用的是小字号（%.1fpx，不是浏览器默认的 16px）" % (fs or 0),
        fs is not None and 11 <= fs <= 14, fs)
    chk("★ 小标题比正文略大、而且是粗的（不然十条读起来是平的）",
        pg.evaluate("""() => {
          const b = parseFloat(getComputedStyle(
            document.querySelector('.dsapp-tos-md')).fontSize);
          const h = parseFloat(getComputedStyle(
            document.querySelector('.dsapp-tos-md h2')).fontSize);
          const w = getComputedStyle(
            document.querySelector('.dsapp-tos-md h2')).fontWeight;
          return h >= b && (w === '600' || w === '700' || parseInt(w, 10) >= 600);
        }""") is True)
    chk("★ 标题是块级元素（inline 的话会跟正文挤成一行）",
        pg.evaluate("""() => getComputedStyle(
          document.querySelector('.dsapp-tos-md h2')).display""") == "block")
    chk("★ 标题的上下留白被压过（Bootstrap 默认 margin 会把十条撑成几屏空白）",
        pg.evaluate("""() => {
          const e = document.querySelector('.dsapp-tos-md h2');
          const m = parseFloat(getComputedStyle(e).marginTop);
          return m > 0 && m < 24;
        }""") is True)
    # ⚠️ 限高和滚动条都在**外层** .dsapp-tos-wrap 上，不在 .dsapp-tos 自己身上。
    #    问错元素的话计算值是 "visible"，这条就永远是红的，而界面一点问题没有。
    chk("★ 须知仍然是一块**限高可滚**的区域（勾选框不能被挤出屏幕）",
        pg.evaluate("""() => {
          const e = document.querySelector('.dsapp-tos');
          if (!e || !e.parentElement) return null;
          const cs = getComputedStyle(e.parentElement);
          if (cs.overflowY !== 'auto' && cs.overflowY !== 'scroll') return false;
          return parseFloat(cs.maxHeight) > 0 && parseFloat(cs.maxHeight) < 900;
        }""") is True)
    chk("★ 勾选框排在须知正文下面（先读后勾，顺序不能反）",
        pg.evaluate("""() => {
          const t = document.querySelector('.dsapp-tos');
          const c = document.querySelector('.dsapp-auth input[type=checkbox]');
          if (!t || !c) return null;
          return (t.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
        }""") is True)

    meta = pg.locator(".dsapp-tos-meta").first.inner_text()
    chk("★ 版本号显示出来了，而且只是「2.0」这种给人看的形态（不是 2.0+指纹）",
        "2.0" in meta and "+" not in meta, meta)
    pg.screenshot(path=os.path.join(OUT, "v10_tos_md.png"))

    # =====================================================================
    print("\n== 勾上注册 → 日志里存的是带指纹的 key，界面显示的仍是 2.0 ==")
    # =====================================================================
    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email, pw = register(pg, tag)
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
    chk("★ 注册成功并进入主界面", entered,
        pg.inner_text("body")[:200].replace("\n", " "))

    row = sql("SELECT id FROM users WHERE email = ?", (email,))
    uid = row[0][0] if row else None
    chk("★ 账号建出来了", uid is not None, uid)
    if uid:
        rows = sql("SELECT version, source FROM consent_log WHERE user_id = ? "
                   "ORDER BY id", (uid,))
        chk("★★ 日志里存的是「版本+指纹」（'2.0+xxxxxxxx'），不是裸的 '2.0'",
            len(rows) == 1 and rows[0][0].startswith("2.0+") and
            len(rows[0][0]) == len("2.0+") + 8, rows)
        chk("★ source 记的是 register", rows and rows[0][1] == "register", rows)
        u = sql("SELECT tos_version FROM users WHERE id = ?", (uid,))
        chk("★ users.tos_version 和日志里的是同一个 key（物化视图不能和真相分家）",
            u and u[0][0] == rows[0][0], (u, rows))

    # =====================================================================
    print("\n== item 2：把 consent_log 整张表删掉 —— 复现线上那次事故 ==")
    # =====================================================================
    # ★ 这就是 2026-09-15 线上的现场：用户已经登录（cookie 在手），
    #   手里的连接是**上一版代码**建的，表还没建出来。
    #   在这里，"上一版的连接"用"把表删掉"来近似 —— 对新代码来说两者
    #   没有区别：连接对象是活的，库里没有 consent_log。
    if uid:
        # 先伪造一次"7 天前同意过"，这样一进来就会被闸门拦下来（要重新确认）。
        old = time.strftime("%Y-%m-%d %H:%M:%S",
                            time.localtime(time.time() - 8 * 86400))
        exec_sql("UPDATE users SET tos_agreed_at = ? WHERE id = ?", (old, uid))
        exec_sql("DROP TABLE IF EXISTS consent_log")
        left = sql("SELECT name FROM sqlite_master WHERE name = 'consent_log'")
        chk("★ 现场造好了：表不在了，账号还在、也已经登录着",
            len(left) == 0 and uid is not None)

        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        chk("★★ 被须知闸门拦下来（预期行为：超过 7 天要重新确认）",
            pg.locator(".dsapp-tos").count() >= 1 and
            pg.locator(".dsapp-shell").count() == 0,
            "shell=%d tos=%d" % (pg.locator(".dsapp-shell").count(),
                                 pg.locator(".dsapp-tos").count()))
        # 渲染过的那一版在闸门页上同样要成立（两处共用同一个渲染函数）
        chk("★★ 闸门页上的正文也是渲染过的（不是纯文本那版）",
            pg.locator(".dsapp-tos-md h2").count() >= 8,
            pg.locator(".dsapp-tos-md h2").count())

        pg.check("#tos_gate-agree")
        pg.click("#tos_gate-do_agree")
        pg.wait_for_timeout(8000)

        txt = pg.inner_text("body")
        chk("★★★ 点同意 → 进去了，没有出现「没能记录你的确认」"
            "（这就是线上那个 bug 的正面）",
            pg.locator(".dsapp-shell").count() >= 1 and
            "没能记录你的确认" not in txt and "no such table" not in txt,
            txt[:300].replace("\n", " "))
        if "没能记录你的确认" in txt or "no such table" in txt:
            pg.screenshot(path=os.path.join(OUT, "v10_stale_FAILED.png"))
        else:
            pg.screenshot(path=os.path.join(OUT, "v10_stale_ok.png"))

        # 表要真的被补回来，而且这次同意要**留痕** —— 光"让他进去"不算修好：
        # 下次进来还得能查到"他同意过"，否则他会每进一次被拦一次。
        back = sql("SELECT name FROM sqlite_master WHERE name = 'consent_log'")
        chk("★★★ 表被自动补回来了（第二层保险干的事）", len(back) == 1, back)
        if back:
            n = sql("SELECT version, source FROM consent_log WHERE user_id = ?",
                    (uid,))
            chk("★★★ 这次的同意留了痕（表补回来 + 写入成功）",
                len(n) == 1 and n[0][1] == "weekly", n)
            u = sql("SELECT tos_version FROM users WHERE id = ?", (uid,))
            chk("★ users 上那两列也跟着更新了", u and n and u[0][0] == n[0][0], u)

        # 再刷一次：这回不该再被拦 —— 拦了就说明写进去的东西没能对上账
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        chk("★★★ 再刷新一次直接进主界面（同意记录是**对得上**的，不是白写一行）",
            pg.locator(".dsapp-shell").count() >= 1 and
            pg.locator(".dsapp-tos").count() == 0,
            "shell=%d tos=%d" % (pg.locator(".dsapp-shell").count(),
                                 pg.locator(".dsapp-tos").count()))

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
