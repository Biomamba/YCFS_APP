# -*- coding: utf-8 -*-
"""V9 item 5：不同对话的文件要分得开、看得见。

用户的原话是「不同的对话需要在不同的文件夹里，注意管理区分」。

盘上**本来就是**分开的（每个对话一个 workspaces/chat-<sid>/，见 utils.R 的
dsapp_ws_dir）。真正的毛病在界面：文件页原来只能看"当前那个对话"的工作区，
想看另一个对话产出过什么，得先跑到言出法随页把对话切过去再切回来 —— 存是
分开了，用起来像没分开。所以这条验的是**够不够得着**，不是"有没有分开"。

对着一次性实例（8898）跑，会真的注册账号。文件直接写在那个临时数据目录的
工作区里（不走上传接口：这条要验的是"哪个对话的文件显示在哪里"，
上传那一步在 V9 item 12 里另外测过）。

⚠️ 只碰 $DATA_ROOT 底下的工作区（顶上有 _guard 拦一道）。
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
WS_ROOT = os.path.join(DATA_ROOT, "workspaces")
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


def plant(sid, name, text):
    """往某个对话的工作区里放一个文件（模拟它跑出来的产物）。"""
    d = os.path.join(WS_ROOT, "chat-" + str(sid).replace("/", "_"))
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(text)
    return p


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    # -------------------------------------------------------------------
    print("\n== 准备：注册 + 建两个对话，各自放一个同类型但不同名的文件 ==")
    # -------------------------------------------------------------------
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)
    if pg.locator(".dsapp-shell").count():
        if pg.locator("#logout").count():
            pg.click("#logout")
            pg.wait_for_timeout(6000)
        pg.goto(URL + "?login=1", wait_until="domcontentloaded")
        pg.wait_for_timeout(3000)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    if pg.locator("#welcome-nickname").count() == 0 and pg.locator("#welcome-go_register").count():
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1200)
    pg.fill("#welcome-nickname", "分对话测试")
    pg.fill("#welcome-email", "v9scope_%s@example.com" % tag)
    pg.fill("#welcome-phone", "13800000008")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", "Test-%s-pw" % tag)
    pg.check(".dsapp-auth input[type=checkbox]")
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count():
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(6000)
    pg.wait_for_selector(".dsapp-shell", timeout=30000)
    chk("★ 注册并进入主界面", True)

    pg.click("#chat-new_chat")
    pg.wait_for_timeout(2500)
    sid_a = sql("SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1")[0][0]
    pg.click("#chat-new_chat")
    pg.wait_for_timeout(2500)
    sid_b = sql("SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1")[0][0]
    chk("★ 两个对话都建出来了", sid_a != sid_b, (sid_a, sid_b))

    exec_sql("UPDATE sessions SET title = ? WHERE id = ?",
             ("火山图-%s" % tag, sid_a))
    exec_sql("UPDATE sessions SET title = ? WHERE id = ?",
             ("富集分析-%s" % tag, sid_b))
    plant(sid_a, "only_in_A_%s.csv" % tag, "gene,log2FC\nTP53,2.1\n")
    plant(sid_b, "only_in_B_%s.csv" % tag, "term,p\ncell cycle,0.001\n")
    png_b = os.path.join(WS_ROOT, "chat-" + str(sid_b), "plot_B_%s.png" % tag)
    with io.open(png_b, "wb") as f:          # 一个最小的 1x1 PNG，够占位了
        f.write(bytes.fromhex(
            "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
            "890000000a49444154789c6360000002000100ffff03000006000557bfabd400"
            "00000049454e44ae426082"))

    # -------------------------------------------------------------------
    print("\n== 文件页：默认只看当前对话，但能换到别的对话 ==")
    # -------------------------------------------------------------------
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_timeout(6000)
    pg.wait_for_selector(".dsapp-sess", timeout=30000)
    # 进对话 A（列表是 updated_at 倒序，B 在前；按标题找更稳）
    pg.locator(".dsapp-sess", has_text="火山图-%s" % tag).first.click()
    pg.wait_for_timeout(3000)
    # 导航走左侧那个 rail（data-nav 是 nav_panel 的 value，不是标题）
    pg.click('.dsapp-rail-link[data-nav="files"]')
    pg.wait_for_timeout(5000)

    body = pg.inner_text("body")
    chk("★★ 当前对话（A）的产物看得见", ("only_in_A_%s.csv" % tag) in body)
    chk("★★ 另一个对话（B）的产物**没有**混进来",
        ("only_in_B_%s.csv" % tag) not in body and ("plot_B_%s.png" % tag) not in body)
    pg.screenshot(path=os.path.join(OUT, "v9_files_current.png"), full_page=True)

    picker = pg.locator(".dsapp-convpick")
    chk("★★ 有「换一个对话看」的下拉框", picker.count() >= 1, picker.count())
    if picker.count():
        opts = picker.first.locator("option")
        chk("★ 下拉框里列出了两个对话", opts.count() >= 2, opts.count())
        labels = [opts.nth(i).inner_text() for i in range(opts.count())]
        chk("★ 每个对话后面带着它的文件数和体积（不点进去就知道有没有东西）",
            any("个文件" in l for l in labels), labels)
        chk("★ 还没有产物的对话也如实写出来",
            any("还没有产物" in l for l in labels) or all("个文件" in l for l in labels),
            labels)
        chk("★★ 默认选中的是当前对话（下拉框和页面上看的是同一个）",
            picker.first.input_value() == sid_a,
            (picker.first.input_value(), sid_a))

        # 切到 B
        picker.first.select_option(value=sid_b)
        pg.wait_for_timeout(4000)
        body2 = pg.inner_text("body")
        chk("★★ 切过去之后显示的是**B** 的文件",
            ("only_in_B_%s.csv" % tag) in body2 and ("plot_B_%s.png" % tag) in body2,
            body2[-400:].replace("\n", " "))
        chk("★★ A 的文件不再出现（不是两份混在一起显示）",
            ("only_in_A_%s.csv" % tag) not in body2)
        pg.screenshot(path=os.path.join(OUT, "v9_files_other.png"), full_page=True)

        # 顶上的定位条必须说清楚"你现在看的不是当前对话"
        chk("★★ 顶部明说了正在看哪个对话的工作区",
            "富集分析-%s" % tag in body2 and "工作区" in body2,
            [l for l in body2.split("\n") if "工作区" in l][:3])

        # 回到当前对话
        back = pg.locator("#files-focus_back")
        chk("★ 有「回到当前对话」", back.count() >= 1)
        if back.count():
            back.first.click()
            pg.wait_for_timeout(4000)
            body3 = pg.inner_text("body")
            chk("★★ 点「回到当前对话」回到 A 的文件",
                ("only_in_A_%s.csv" % tag) in body3 and
                ("only_in_B_%s.csv" % tag) not in body3,
                body3[-300:].replace("\n", " "))
            chk("★ 下拉框也跟着回到当前对话",
                pg.locator(".dsapp-convpick").first.input_value() == sid_a,
                pg.locator(".dsapp-convpick").first.input_value())

    # -------------------------------------------------------------------
    print("\n== 删除对话要连它自己的文件一起删，不能碰到别的对话 ==")
    # -------------------------------------------------------------------
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_timeout(6000)
    pg.wait_for_selector(".dsapp-sess", timeout=30000)
    pg.locator(".dsapp-sess", has_text="富集分析-%s" % tag).first.click()
    pg.wait_for_timeout(3000)
    pg.click("#chat-del_chat")
    pg.wait_for_timeout(1500)
    if pg.locator("#chat-do_del_chat").count():
        pg.click("#chat-do_del_chat")
        pg.wait_for_timeout(6000)
    dir_b = os.path.join(WS_ROOT, "chat-" + str(sid_b))
    dir_a = os.path.join(WS_ROOT, "chat-" + str(sid_a))
    chk("★★ B 的工作区被删掉了", not os.path.exists(dir_b), dir_b)
    chk("★★ A 的工作区原封不动（删一个对话不能连累另一个）",
        os.path.exists(dir_a) and
        os.path.exists(os.path.join(dir_a, "only_in_A_%s.csv" % tag)), dir_a)
    chk("★ 库里也没有 B 的会话行了",
        len(sql("SELECT 1 FROM sessions WHERE id = ?", (sid_b,))) == 0)

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
