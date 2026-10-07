# -*- coding: utf-8 -*-
"""tests/ui_v11 共用的几件小事：守卫、注册/登录、几何量取。

单独拆出来是因为**这套"进到主界面"的步骤比看起来长**（注册 → 恢复码页 →
用户须知闸门），每一个探针脚本里各抄一份的话，改一次要改五处，而且抄漏
一步的脚本会停在另一个页面上、报出一堆指向错误方向的失败。
"""
import io
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v11test_224730/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v12")


def guard(app):
    """★ 拦住"对着线上那份代码跑测试"和"数据目录不在临时目录下"。

    ⚠️ 它只看 .Renviron 这个**文件**写了什么，管不了那个实例**实际**在读
    哪一份 .Renviron —— 2026-09-15 就是从这个缝里漏过去的（启动实例时的
    工作目录是仓库根，R 读的是仓库那份，指向线上 data/）。所以每个脚本在
    注册之后还要再验一次"刚建的账号出现在 DATA_ROOT 里"，见 seed_or_die。
    """
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


DATA_ROOT = guard(APP)
os.makedirs(OUT, exist_ok=True)

TAG = str(int(time.time()))[-6:]
EMAIL = "v12_%s@example.com" % TAG
PW = "Test-%s-pw" % TAG


def db_path():
    for r, _d, fs in os.walk(DATA_ROOT):
        for f in fs:
            if f.endswith(".sqlite3"):
                return os.path.join(r, f)
    return None


def enter_app(page, email=None, nickname="V12测试"):
    """注册一个新账号并一路点到主界面（.dsapp-shell）。"""
    email = email or EMAIL
    page.goto(URL, wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-auth", timeout=30000)
    page.wait_for_timeout(2000)

    if page.locator("#welcome-nickname").count() == 0:
        page.click("#welcome-go_register")
        page.wait_for_selector("#welcome-nickname", timeout=15000)
        page.wait_for_timeout(1000)
    page.fill("#welcome-nickname", nickname)
    page.fill("#welcome-email", email)
    page.fill("#welcome-phone", "13800000007")
    page.fill("#welcome-field", "转录组")
    page.fill("#welcome-password", PW)
    cb = page.locator("#welcome-tos_agree")
    if cb.count() and not cb.is_checked():
        cb.check()
    page.click("#welcome-do_register")

    # 恢复码页（"只显示这一次"）
    page.wait_for_selector("#welcome-enter_app", timeout=40000)
    page.click("#welcome-enter_app")

    # 用户须知闸门（V9 item 1，新账号必须勾选）
    for _ in range(40):
        page.wait_for_timeout(1000)
        if page.locator(".dsapp-shell").count():
            break
        if page.locator("#tos_gate-do_agree").count():
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            page.wait_for_timeout(3000)
    if not page.locator(".dsapp-shell").count():
        page.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        txt = page.inner_text("body")
        sys.exit("注册没进主界面（页面文字 %d 字）：\n%s" % (len(txt), txt[:600]))
    return email


def goto_chat(page, reload_first=False):
    """切到「言出法随」页并等它渲染出来。

    ⚠️ 必须显式切页。bslib 的 navset_hidden 是"所有页都留在 DOM 里、只藏
    不激活"，别的页的控件也都在 —— 不切过去的话，几何断言量的全是隐藏元素
    的 0×0 矩形，报出来的失败会指向完全错误的地方。
    """
    if reload_first:
        # ⚠️ reload 要重试：注册成功之后服务端还会走一次 session$reload()，
        #    那一下和这里的 reload 撞在一起时 Playwright 报的是
        #    net::ERR_ABORTED / "frame was detached" —— 页面本身没问题。
        for attempt in range(4):
            try:
                page.reload(wait_until="domcontentloaded")
                break
            except Exception:
                if attempt == 3:
                    raise
                page.wait_for_timeout(3000)
        page.wait_for_selector(".dsapp-shell", timeout=30000)
        page.wait_for_timeout(2500)
    page.evaluate("() => window.dsappNav && window.dsappNav('chat')")
    page.wait_for_timeout(3000)


def pick_select(page, sel_id, value):
    """在一个 selectInput 上选值 —— 必须像用户那样点开它自己的下拉。

    ⚠️ `page.select_option('#x', ...)` 对**默认的** selectInput 是无效的：
    Shiny 的 selectInput 默认 `selectize = TRUE`，原生的 <select> 被
    selectize 藏起来（0×0），Playwright 的可操作性检查会一直等到超时，
    报出来的是 "element is not visible" —— 指向的是"这个控件不存在"，
    而真实原因是"你该点的是它旁边那个假下拉"。

    这一条在 tests/ui_v8/ 里踩过：那几个套件用 select_option 驱动
    「模型服务」那一格，结果每次都超时，被当成"控件没渲染出来"查了半天。
    页面代码里 selectize = FALSE 的地方（mod_admin.R 里有一串，理由是空值
    选项会被当成 placeholder 吃掉）才可以反过来用 select_option。
    """
    ctrl = page.locator(
        "xpath=//select[@id='%s']/following-sibling::div"
        "[contains(@class,'selectize-control')]" % sel_id)
    ctrl.locator(".selectize-input").click()
    page.wait_for_timeout(500)
    opt = ctrl.locator(".option[data-value='%s']" % value)
    if opt.count() == 0:
        opt = ctrl.locator(".option", has_text=value)
    opt.first.click()
    page.wait_for_timeout(400)


def seed_conversation(email, rounds=4, sid=None):
    """往测试实例的库里塞一段够长的对话。

    二级目录要 >=3 轮用户消息才出现（见 R/mod_chat.R 的 dsapp_toc_ui）。真
    发四轮得连着调四次模型 —— 又慢又花钱，而这个脚本要验的是"目录挂在哪
    一行下面"，不是模型会不会回答。

    ⚠️ 找不到这个账号就**硬退出**，不是返回 None 就完事：那说明这个实例
    读的不是这份 .Renviron，它多半正连着**线上库**。
    """
    import sqlite3
    p = db_path()
    con = sqlite3.connect(p)
    cur = con.cursor()
    uid = cur.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    if uid is None:
        con.close()
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里。\n"
                 "  说明这个实例读的不是这份 .Renviron —— 停下来，先查它到底\n"
                 "  连着哪个数据目录（很可能就是线上库），别再往下跑了。"
                 % (email, p))
    sid = sid or ("v12-%s" % TAG)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cur.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    cur.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    cur.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)", (sid, "V12 用例", now, now, uid[0]))
    for i in range(rounds):
        cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)",
                    (sid, "user", "第 %d 轮：看看这批数据的质控情况" % (i + 1), now))
        cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)",
                    (sid, "assistant",
                     "第 %d 轮的回答。" % (i + 1) +
                     "这是一段够长的正文，用来把左列撑出滚动条。" * 20, now))
    con.commit()
    con.close()
    return sid


class Chk(object):
    def __init__(self):
        self.ok = True

    def __call__(self, name, cond, extra=""):
        print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
              (("   " + str(extra)) if extra and not cond else ""), flush=True)
        if not cond:
            self.ok = False
        return cond

    def done(self):
        print()
        print("\033[32m全部通过\033[0m" if self.ok else "\033[31m有失败项\033[0m")
        print("截图在 " + OUT)
        return 0 if self.ok else 1
