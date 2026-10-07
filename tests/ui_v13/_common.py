# -*- coding: utf-8 -*-
"""tests/ui_v13 共用的几件小事：守卫、注册、切页、几何/配色量取。

和 tests/ui_v12/_common.py 是**两份**而不是一份 import 另一份：这些脚本
要能在"把仓库拷到 /tmp 单独跑"的场景下工作，跨目录 import 在那种场景里
最先坏掉。共用的是思路，不是文件。
"""
import io
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v11test_224730/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v13")


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
EMAIL = "v13_%s@example.com" % TAG
PW = "Test-%s-pw" % TAG


def db_path():
    for r, _d, fs in os.walk(DATA_ROOT):
        for f in fs:
            if f.endswith(".sqlite3"):
                return os.path.join(r, f)
    return None


def enter_app(page, email=None, nickname="V13测试"):
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
    page.fill("#welcome-phone", "13800000008")
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


def seed_or_die(email):
    """确认刚注册的账号真的落在**这个实例的**库里，返回 (uid, db 路径)。

    ⚠️ 找不到就硬退出。那说明这个实例读的不是这份 .Renviron，它多半正
    连着**线上库** —— 后面任何一句写操作都是在动生产数据。
    """
    import sqlite3
    p = db_path()
    if p is None:
        sys.exit("拒绝继续：%s 底下找不到 .sqlite3。" % DATA_ROOT)
    con = sqlite3.connect(p)
    row = con.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    con.close()
    if row is None:
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里。\n"
                 "  说明这个实例读的不是这份 .Renviron —— 停下来，先查它到底\n"
                 "  连着哪个数据目录（很可能就是线上库），别再往下跑了。"
                 % (email, p))
    return row[0], p


PAGES = ["chat", "tasks", "files", "skills", "envs", "settings", "admin"]


def goto(page, name, wait=2500):
    """切到某一页。

    ⚠️ 必须显式切页。bslib 的 navset_hidden 是"所有页都留在 DOM 里、只藏
    不激活"，别的页的控件也都在 —— 不切过去的话，几何/配色断言量的全是
    隐藏元素的 0×0 矩形，报出来的失败会指向完全错误的地方。
    """
    page.evaluate("(v) => window.dsappNav && window.dsappNav(v)", name)
    page.wait_for_timeout(wait)


def set_skin(page, skin):
    """把皮肤切到 skin 并等它真的生效。

    皮肤本身是**客户端**的（见 www/skins.css 顶部），但选哪个是存在库里的
    服务端设置。这里为了快，直接改 <html data-skin> —— 量的就是这个属性
    决定的配色，和走一遍设置页的效果一样。要验"设置页存得下来"是另一个
    脚本的事，不是这个脚本要回答的问题。
    """
    page.evaluate("(s) => document.documentElement.setAttribute('data-skin', s)",
                  skin)
    page.wait_for_timeout(600)


def pick_select(page, sel_id, value):
    """在一个 selectInput 上选值 —— 必须像用户那样点开它自己的下拉。

    ⚠️ `page.select_option('#x', ...)` 对**默认的** selectInput 是无效的：
    Shiny 的 selectInput 默认 `selectize = TRUE`，原生的 <select> 被
    selectize 藏起来（0×0），Playwright 的可操作性检查会一直等到超时，
    报出来的是 "element is not visible" —— 指向的是"这个控件不存在"，
    而真实原因是"你该点的是它旁边那个假下拉"。
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


class Chk(object):
    def __init__(self):
        self.ok = True
        self.n = 0

    def __call__(self, name, cond, extra=""):
        self.n += 1
        print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
              (("   " + str(extra)) if extra and not cond else ""), flush=True)
        if not cond:
            self.ok = False
        return cond

    def done(self):
        print()
        print(("\033[32m全部通过\033[0m" if self.ok else "\033[31m有失败项\033[0m")
              + "（%d 条断言）" % self.n)
        print("截图在 " + OUT)
        return 0 if self.ok else 1
