# -*- coding: utf-8 -*-
"""V8 item 6（执行中的转圈提示框）的浏览器验证。

对着一次性实例（8898）跑。会真的注册账号、真的插一条消息、**真的跑一个任务**。

用户的原话：
    「确定执行任务的时候在言出法随界面对应位置需要有一个转圈的提示框，
      但是不要占据其它操作的位置」

这句话里前半句很好写，后半句才是会写错的地方 —— "加一个提示框"最自然的
写法是**新插一块**（顶部横幅、输入框上方一条、右下角 toast），而新插一块
就意味着别的东西被挤走。他刚点的那颗「确认执行」就在眼前，视线一挪，
"我点的是哪一段"就断线了。

所以这里量的是**几何**，不是"有没有出现转圈"：
  · 卡片自己的外框（x/y/宽/高）在换转圈前后**一模一样**；
  · 转圈出现在卡片头部那一格里，不是卡片的兄弟块；
  · 旁边那颗「复制」的位置也不动。
这三条只能靠真的量 boundingBox 得到 —— 离线断言能证明 HTML 结构对，
证明不了"渲染出来没把别的东西顶开"。

⚠️ 没有 API Key 就造不出模型消息，所以这里**直接往库里插一条带代码块的
   助手消息**。这不是绕过测试，是把"模型说了什么"这个变量固定住 ——
   这条测的是点击之后的界面行为，和模型无关。
"""

import io
import os
import random
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v8")
SQLITE = os.environ.get("DSAPP_SQLITE", "/home/biomamba/miniconda3/bin/sqlite3")


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


def sql(stmt):
    return subprocess.run([SQLITE, DB, stmt], capture_output=True,
                          text=True).stdout.strip()


def sql_file(path):
    """跑一个 .sql 文件。

    ⚠️ 不能把带换行的 SQL 拼成一条命令行参数再传：SQLite 的字符串字面量
       里 `\\n` 是**两个字符**（反斜杠 + n），它不认 C 那套转义。第一版就是
       这么插入的，结果模型消息里躺着字面的 `\\n\\n```r\\n`，代码围栏根本没
       被识别出来 —— 表现是"卡片一个都没有"，看起来像渲染坏了，其实是
       写进去的东西本身就不是 markdown。走文件、用真的换行才作数。
    """
    with open(path, "r", encoding="utf-8") as fh:
        return subprocess.run([SQLITE, DB], stdin=fh, capture_output=True,
                              text=True)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v8run_%s@example.com" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V8转圈")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000004")
    pg.fill("#welcome-field", "转录组")
    pg.fill("#welcome-password", "Test-%s-pw" % tag)
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    chk("注册进到主界面", pg.locator(".dsapp-shell").count() > 0)

    # =====================================================================
    print("\n== item 6：造一段带代码块的消息（点 API 不花钱）==")
    # =====================================================================
    pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
    pg.wait_for_timeout(2000)
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(2500)

    sid = sql("SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1")
    chk("抠到了新对话的 session id", len(sid) > 0, sid)

    # 代码写一个文件出来，好回头确认任务**真的跑了**，而不是只改了个界面。
    sqlf = os.path.join(OUT, "seed.sql")
    with io.open(sqlf, "w", encoding="utf-8") as fh:
        fh.write(
            "INSERT INTO messages (session_id, role, content, created_at)\n"
            "VALUES ('%s', 'assistant',\n"
            "'这段可以直接跑：\n\n"
            "```r\n"
            # ⚠️ 顺序不能反：先睡再写文件。
            #    睡是**必须的** —— 第一版只写文件，任务 200 毫秒就跑完了，
            #    转圈确实出现过，但在我 3 秒后去看之前就已经被撤掉了，
            #    断言红得像是"转圈根本没实现"。
            #    睡在写之前还有第二个作用：跑的这 10 秒里工作区里什么都
            #    没有，消息流末尾不会长出产物卡片，量到的位移就只可能来自
            #    转圈本身，而不是"对话变长了"。写文件放在最后，用来在
            #    收尾时确认任务**真的跑了**。
            "Sys.sleep(10)\n"
            'writeLines("v8item6", "item6_out.txt")\n'
            "```\n"
            "', datetime('now'));\n" % sid)
    r = sql_file(sqlf)
    chk("种子消息写进库了", r.returncode == 0, r.stderr.strip())

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(7000)
    chk("消息渲染出来了，卡片上有「确认执行」",
        pg.locator(".dsapp-code-run").count() >= 1,
        "找到 %d 个" % pg.locator(".dsapp-code-run").count())
    if pg.locator(".dsapp-code-run").count() == 0:
        pg.screenshot(path=os.path.join(OUT, "running_fail.png"))
        b.close()
        sys.exit("没造出可执行的代码卡片，后面的几何测量没有意义。")

    # 点之前：把要盯的几个盒子量下来。
    #
    # ⚠️ 量的是**控件**有没有被挤走，不只是"转圈出现了没有"。
    #    第一版把运行横幅留在主区顶上，实测点一下「确认执行」，输入框和
    #    发送按钮整体下移 47px —— 那正是用户说的"占据其它操作的位置"。
    #    横幅挪进侧栏之后，这一整列（消息区、输入区、按钮）都不该再动。
    card0 = pg.locator(".dsapp-code-card").first.bounding_box()
    copy0 = pg.locator(".dsapp-code-copy").first.bounding_box()
    act0 = pg.locator(".dsapp-code-actions").first.bounding_box()
    comp0 = pg.locator(".dsapp-composer").first.bounding_box()
    send0 = pg.locator("#chat-send").first.bounding_box()
    scr0 = pg.locator(".dsapp-chat-scroll").first.bounding_box()
    art0 = pg.locator(".dsapp-artifacts").count()
    n_cards = pg.locator(".dsapp-code-card").count()

    # =====================================================================
    print("\n== item 6：点「确认执行」→ 原地变转圈 ==")
    # =====================================================================
    pg.locator(".dsapp-code-run").first.click()
    pg.wait_for_timeout(3000)

    run = pg.locator(".dsapp-btn-running")
    chk("★★ 卡片上出现了转圈提示框", run.count() == 1,
        "找到 %d 个" % run.count())
    chk("★ 那颗「确认执行」按钮消失了（是替换，不是并排加一个）",
        pg.locator(".dsapp-code-run").count() == 0,
        "还剩 %d 个" % pg.locator(".dsapp-code-run").count())
    chk("★ 提示框里有真的转圈", run.locator(".spinner-border").count() == 1)
    chk("提示框上写着「执行中」", "执行中" in run.first.inner_text(),
        run.first.inner_text())

    # ---- 几何：这就是"不要占据其它操作的位置"那一条 ----
    card1 = pg.locator(".dsapp-code-card").first.bounding_box()
    copy1 = pg.locator(".dsapp-code-copy").first.bounding_box()
    act1 = pg.locator(".dsapp-code-actions").first.bounding_box()
    comp1 = pg.locator(".dsapp-composer").first.bounding_box()
    send1 = pg.locator("#chat-send").first.bounding_box()
    scr1 = pg.locator(".dsapp-chat-scroll").first.bounding_box()
    art1 = pg.locator(".dsapp-artifacts").count()

    chk("★ 卡片没长高也没变宽（转圈没把卡片撑开）",
        card0 and card1 and
        abs(card0["height"] - card1["height"]) < 1 and
        abs(card0["width"] - card1["width"]) < 1,
        "before=%s after=%s" % (card0, card1))
    chk("★★ 旁边那颗「复制」逐像素没动（转圈没挤走别的操作）",
        copy0 and copy1 and
        abs(copy0["x"] - copy1["x"]) < 1 and abs(copy0["y"] - copy1["y"]) < 1,
        "before=%s after=%s" % (copy0, copy1))
    # 消息区的**内容**长了（这一轮跑出了新文件 → 末尾的产物卡片长出来），
    # 消息区跟着变高、把输入区推下去 —— 这是它本来的行为（对话变长本来就
    # 该往下走），和转圈无关。所以这里先把这个量记下来，再要求：
    # 输入区的位移**完全由消息区变高解释**，多出来的部分必须是 0。
    grew = (scr1["height"] - scr0["height"]) if (scr0 and scr1) else None
    moved = comp1["y"] - comp0["y"]
    print("     （消息区高了 %.0f px，输入区下移 %.0f px，产物卡片 %d → %d）"
          % (grew, moved, art0, art1))
    chk("★★ 输入区没被转圈顶走（位移全部来自消息区变长）",
        comp0 and comp1 and send0 and send1 and
        abs(moved - grew) < 1.5 and
        abs(comp0["height"] - comp1["height"]) < 1 and
        abs(send0["x"] - send1["x"]) < 1 and
        abs((send0["y"] + moved) - send1["y"]) < 1.5,
        "composer %s → %s / send %s → %s / 消息区 %s → %s"
        % (comp0, comp1, send0, send1, scr0, scr1))
    chk("★ 没多出块来（卡片数没变）",
        pg.locator(".dsapp-code-card").count() == n_cards,
        "%d → %d" % (n_cards, pg.locator(".dsapp-code-card").count()))
    chk("★ 转圈占的是原来那颗按钮那一格（落在 code-actions 行内，且高度相当）",
        act0 and act1 and abs(act0["height"] - act1["height"]) < 6,
        "actions before=%s after=%s" % (act0, act1))
    chk("★★ 消息流本身也没被顶下去（运行横幅已经挪进侧栏了）",
        card0 and card1 and abs(card0["y"] - card1["y"]) < 1,
        "卡片 y：%s → %s" % (card0 and card0["y"], card1 and card1["y"]))
    chip = pg.locator(".dsapp-run-chip")
    chk("★ 侧栏里能看到「有任务在跑」（没丢掉这条信息）",
        chip.count() == 1 and "执行中" in chip.first.inner_text(),
        chip.first.inner_text() if chip.count() else "没找到")

    pg.screenshot(path=os.path.join(OUT, "running.png"))

    # =====================================================================
    print("\n== item 6：任务跑完，转圈要自己撤掉 ==")
    # =====================================================================
    # ⚠️ 不主动刷新页面。刷新能把按钮"变回来"，但那证明不了什么 ——
    #    用户不会为了看一眼按钮去按 F5，而一个永远转下去的圈比不显示更糟。
    gone = False
    for _ in range(40):                      # 最多等 40 秒
        pg.wait_for_timeout(1000)
        if pg.locator(".dsapp-btn-running").count() == 0:
            gone = True
            break
    chk("★★ 任务结束后转圈自己消失了（不用刷新页面）", gone)
    chk("★ 按钮回来了，还能再点一次",
        pg.locator(".dsapp-code-run").count() >= 1)

    # ---- 真的跑了吗 ----
    # ⚠️ 工作区在 data/workspaces/chat-<session_id>/ 下，不是 data/work/。
    #    第一版按 "work/<sid>:1" 找，恒找不到 —— 而它的红看起来像"任务没
    #    执行"，实际上那 10 秒的任务成功跑完了、文件也写出来了。
    #    两条路一起查：库里那行任务的状态，和盘上那个文件。
    st = sql("SELECT status FROM tasks WHERE session_id='%s' "
             "ORDER BY id DESC LIMIT 1" % sid)
    found = []
    for dirpath, _dirnames, filenames in os.walk(DATA_ROOT):
        if "item6_out.txt" in filenames:
            found.append(os.path.join(dirpath, "item6_out.txt"))
    chk("★★ 任务真的跑了（库里那条是 success）", st == "success", "status=%s" % st)
    chk("★★ 任务真的写了文件出来（界面之外确实有产出）", len(found) >= 1,
        "在 %s 下没找到 item6_out.txt" % DATA_ROOT)

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
