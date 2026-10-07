# -*- coding: utf-8 -*-
"""V8 item 5（任务区 ↔ 文件区互通）的浏览器验证。

对着一次性实例（8898）跑。会真的注册账号、真的跑一个任务、真的来回跳。

用户的原话是「任务和文件管理区还是有点脱钩，让二者更有互动性一些，例如
可以通过文件或文件夹跳回对应的任务，或者通过对应任务，直接跳转到对应
文件管理区」。这句话里的每一条都是**跨页**的：一个页面上写对了、另一个
页面收不到，界面上就是"点了没反应"，服务端一条日志都没有。

所以这里必须真的点、真的看落地页：
  · 文件页的产物分组 →「任务 #N」→ 任务页停在那条任务上（还闪一下）；
  · 任务页的产物 →「在文件区看」/「在文件区打开」→ 文件页，且**是那条
    任务所属对话**的工作区，不是"当前对话"的 —— 这是最容易写错的一处：
    跳过去看一眼当前对话的产物，用户会以为自己点错了；
  · 对话页的目录行 → 文件页并停在那一条上（这一条也顺带盯 item 7）。

⚠️ 跨页跳转是服务端调 bslib::nav_select 完成的（见 utils.R 的 dsapp_nav_to）。
   模块里用带命名空间的 nav_select 点了没反应 —— 2026-09-14 用户报过这一条。
   所以断言只能落在"页面真的换了"上，源代码里写没写对看不出来。
"""

import io
import os
import random
import re
import subprocess
import sys

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


def goto_page(pg, label, wait=2500):
    pg.locator(".dsapp-rail-link", has_text=label).first.click()
    pg.wait_for_timeout(wait)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V8互通")
    pg.fill("#welcome-email", "v8nav_%s@example.com" % tag)
    pg.fill("#welcome-phone", "13800000005")
    pg.fill("#welcome-field", "转录组")
    pg.fill("#welcome-password", "Test-%s-pw" % tag)
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    chk("注册进到主界面", pg.locator(".dsapp-shell").count() > 0)

    # =====================================================================
    print("\n== 先造一条真的有产物的任务 ==")
    # =====================================================================
    goto_page(pg, "言出法随")
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(2500)

    sid = sql("SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1")
    chk("抠到了新对话的 session id", len(sid) > 0, sid)
    with io.open(os.path.join(OUT, "nav_seed.sql"), "w", encoding="utf-8") as fh:
        fh.write(
            "INSERT INTO messages (session_id, role, content, created_at)\n"
            "VALUES ('%s', 'assistant',\n"
            "'这轮跑一下：\n\n"
            "```r\n"
            'dir.create("results_v8", showWarnings = FALSE)\n'
            'writeLines("png", "results_v8/volcano.png")\n'
            'writeLines("a,b\\n1,2", "expr_norm.csv")\n'
            "```\n"
            "', datetime('now'));\n" % sid)
    with open(os.path.join(OUT, "nav_seed.sql"), encoding="utf-8") as fh:
        subprocess.run([SQLITE, DB], stdin=fh, capture_output=True, text=True)

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=30000)
    pg.wait_for_timeout(7000)
    chk("种子消息渲染成了可执行卡片", pg.locator(".dsapp-code-run").count() >= 1)
    if pg.locator(".dsapp-code-run").count() == 0:
        b.close()
        sys.exit("没造出可执行卡片，后面的跨页断言没有意义。")

    pg.locator(".dsapp-code-run").first.click()
    pg.wait_for_timeout(3000)
    # 等任务跑完（转圈消失 = 引擎空闲）
    for _ in range(40):
        if pg.locator(".dsapp-btn-running").count() == 0:
            break
        pg.wait_for_timeout(1000)
    pg.wait_for_timeout(4000)
    tid = sql("SELECT id FROM tasks WHERE session_id='%s' ORDER BY id DESC "
              "LIMIT 1" % sid)
    chk("任务跑完了（库里查得到）", sql("SELECT status FROM tasks WHERE id=%s" % tid)
        == "success", "tid=%s" % tid)
    if not tid:
        b.close()
        sys.exit("没有任务行，跨页跳转没有目标。")

    # =====================================================================
    print("\n== 文件页 → 任务页（产物 → 产出它的那条任务）==")
    # =====================================================================
    goto_page(pg, "文件")
    chk("文件页打开了", "文件" in pg.inner_text("#dsapp_page_title"),
        pg.inner_text("#dsapp_page_title"))
    chk("★ 产物分组里有「任务 #%s」这个入口" % tid,
        pg.locator(".dsapp-wsgroup-task", has_text=tid).count() >= 1,
        "分组里没找到任务链接：%s" % pg.inner_text("body")[:200])

    # 落地那一下闪的高亮（dsapp:flash）2.6 秒后自己把 class 摘掉，而这里
    # 要等 3.5 秒让页面落稳 —— 直接查 document.querySelector('.dsapp-flash')
    # **必然是空**（第一版就是这么写的，红得像是这个功能没实现）。所以先挂
    # 个 MutationObserver 盯着，回头问它"刚才闪过没有"，与等待时长无关。
    pg.evaluate("""() => {
      window.__dsappFlash = false;
      new MutationObserver(function () {
        if (document.querySelector('.dsapp-flash')) window.__dsappFlash = true;
      }).observe(document.body, {subtree: true, attributes: true,
                                 attributeFilter: ['class']});
    }""")
    pg.locator(".dsapp-wsgroup-task").first.click()
    pg.wait_for_timeout(3500)
    chk("★★ 真的跳到了任务页（不是点了没反应）",
        "任务" in pg.inner_text("#dsapp_page_title"),
        pg.inner_text("#dsapp_page_title"))
    chk("★ 任务详情卡展开了那条任务",
        pg.locator(".dsapp-taskdetail").count() >= 1 and
        ("#%s" % tid) in pg.inner_text(".dsapp-taskdetail"),
        pg.inner_text(".dsapp-taskdetail")[:200] if
        pg.locator(".dsapp-taskdetail").count() else "没有详情卡")
    # 闪一下是给"跳过来之后看哪儿"用的，见上面挂的那个 observer
    chk("★ 落地时闪了一下（不然跳过来不知道该看哪儿）",
        pg.evaluate("()=>!!window.__dsappFlash"))
    # 详情卡认的是"被勾中的那一行"。列表里那一行是不是真的勾上了，决定了
    # 详情卡是显示这条任务、还是"在左侧选择一条记录查看详情"。
    chk("★ 列表里那一行真的勾上了（不是只把详情卡画出来）",
        pg.locator("#tasks-tbl tr.selected, #tasks-tbl tr.active").count() >= 1,
        "被勾中的行数：%d" % pg.locator(
            "#tasks-tbl tr.selected, #tasks-tbl tr.active").count())

    # =====================================================================
    print("\n== 任务页 → 文件页（产物可点、可跳回）==")
    # =====================================================================
    chk("★ 任务详情里列出了产物",
        pg.locator(".dsapp-taskart").count() >= 2,
        "找到 %d 个" % pg.locator(".dsapp-taskart").count())
    chk("★ 产物里有那个文件夹（item 7 的目录也在）",
        pg.locator(".dsapp-taskart-dir").count() >= 1)
    chk("★ 有「在文件区打开」按钮", pg.locator("#tasks-open_ws").count() == 1)

    # ---- 路一：点**某一个产物**上的「去文件区看」 ------------------------
    # 这条路带的产物名，落地应该点名那一个 —— 不是把用户扔进一堆文件里
    # 让他自己找。产物行的名字取第一行（详情卡里列的是一份有序列表）。
    art0 = pg.locator(".dsapp-taskart").first
    art0_name = art0.locator(".dsapp-taskart-name").first.inner_text().strip()
    art0.locator("a", has_text="去文件区看").first.click()
    pg.wait_for_timeout(3500)
    chk("★★ 跳回了文件页", "文件" in pg.inner_text("#dsapp_page_title"),
        pg.inner_text("#dsapp_page_title"))
    chk("★★ 文件页上有「定位说明」条（不然用户不知道自己在看谁的产物）",
        pg.locator(".dsapp-focusbar").count() >= 1,
        pg.inner_text("body")[:200])
    chk("★ 点的是哪个产物，落地就点名哪个（%s）" % art0_name,
        pg.locator(".dsapp-focusbar").count() >= 1 and
        art0_name in pg.inner_text(".dsapp-focusbar"),
        pg.inner_text(".dsapp-focusbar") if
        pg.locator(".dsapp-focusbar").count() else "没有定位条")
    chk("★ 被点名的那一行高亮出来了",
        pg.locator(".dsapp-wsrow-hit").count() >= 1)

    # 退路：定位条上那个"回到当前对话 / 取消定位"必须真的有用，
    # 否则 focus_ws 会一直留着，那一行永远亮着。
    bar = pg.locator(".dsapp-focusbar")
    if bar.count():
        bar.locator("a, button").first.click()
        pg.wait_for_timeout(3000)
        # ⚠️ extra 参数是**先算再传**的，定位条一旦真的消失了，这里再去
        #    inner_text 就会等满 30 秒然后抛异常 —— 断言通过反而把测试打挂。
        #    所以必须先判在不在。
        chk("★ 点「回到当前对话」之后定位条消失了（有退路）",
            pg.locator(".dsapp-focusbar").count() == 0,
            pg.inner_text(".dsapp-focusbar")
            if pg.locator(".dsapp-focusbar").count() else "")

    # =====================================================================
    print("\n== 对话页 → 文件页（目录行点得动）==")
    # =====================================================================
    goto_page(pg, "言出法随")
    pg.wait_for_timeout(2000)
    card = pg.locator(".dsapp-artifacts")
    chk("★ 对话页的产物卡片在", card.count() >= 1,
        pg.inner_text("body")[:200])
    if card.count():
        # ⚠️ 必须**精确**匹配 "results_v8"。用 has_text="results_v8"（子串）
        #    会先撞上缩略图下面那行说明文字 —— 它写的是
        #    "results_v8/volcano.png"，也含 "results_v8"，而且排在文件列表
        #    **前面**，`.first` 拿到的就是它。那是「预览」入口（点开一个
        #    modal），不是「跳去文件页」入口。第一版就是这么写的：点完页面
        #    没换、反而弹出一个预览框，然后那个 modal 挡住后面所有的点击，
        #    后半段全红 —— 看起来像跳转坏了，其实是点错了元素。
        dirlink = pg.locator(".dsapp-artifacts .dsapp-file-link").filter(
            has_text=re.compile(r"^results_v8$"))
        chk("★ 产物卡片里有那个文件夹", dirlink.count() >= 1,
            "卡片里没找到 results_v8（精确匹配那一条）")
        if dirlink.count():
            dirlink.first.click()
            pg.wait_for_timeout(3500)
            chk("★★ 从对话里点文件夹 → 落到文件页",
                "文件" in pg.inner_text("#dsapp_page_title"),
                pg.inner_text("#dsapp_page_title"))
            chk("★★ 而且是**停在那一条上**（不是扔到一堆产物里自己找）",
                pg.locator(".dsapp-focusbar").count() >= 1 and
                ("results_v8" in pg.inner_text(".dsapp-focusbar")),
                pg.inner_text(".dsapp-focusbar") if
                pg.locator(".dsapp-focusbar").count() else "没有定位条")

    # =====================================================================
    print("\n== 最要命的一条：从**别的**对话的任务跳过来 ==")
    # =====================================================================
    # 上面那几条路都测不出"跳到的是不是当前对话" —— 任务本来就属于当前对话，
    # 落对了落错了都是同一个工作区。所以这里先**新开一个对话**把"当前对话"
    # 挪走，再回头去点那条旧任务的「在文件区打开」。写错的话用户会被扔进
    # 自己当前那个空工作区，看到"什么都没有"，还以为产物丢了 —— 而界面上
    # 没有任何地方会报错。
    #
    # ⚠️ 这一段必须放在**最后**：它会把"当前对话"换成新的空对话，后面再想
    #    看 results_v8 就得先切回去。第一版把它插在中间，后面那段"对话页 →
    #    文件页"就找不到产物卡片了 —— 红得像是跳转坏了，其实是测试自己
    #    把上下文换掉了。
    goto_page(pg, "言出法随")
    pg.wait_for_timeout(2000)
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(2500)
    sid2 = sql("SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1")
    chk("★ 换到了另一个对话（当前对话已经不是那条任务的了）",
        len(sid2) > 0 and sid2 != sid, "sid=%s sid2=%s" % (sid, sid2))

    goto_page(pg, "任务")
    pg.wait_for_timeout(2000)
    rows = pg.locator("#tasks-tbl tbody tr")
    target = None
    for _i in range(rows.count()):
        if rows.nth(_i).locator("td").nth(1).inner_text().strip() == str(tid):
            target = rows.nth(_i)
            break
    chk("★ 任务列表里点得中那条任务", target is not None,
        "列表里没找到 ID=%s 那一行" % tid)
    if target is not None:
        # 第一列是复选框列（Select 扩展），点它等于勾上这一行。
        #
        # ⚠️ 抽屉式切换：点一下是**切换**，不是"只留这一个"。而从文件页
        #    跳过来那次已经把它勾上了（DT 的输出在切页时只是挂起，没重建，
        #    勾选还在），这里再点一下就是把它**取消**。
        #    第一版就是这么写的：每次点完都查到 0 个勾选，看着像"复选框
        #    根本点不动"，其实是被自己点掉的。所以先看状态，没勾才点。
        sel = "#tasks-tbl tr.selected, #tasks-tbl tr.active"
        if pg.locator(sel).count() == 0:
            target.locator("td").first.click()
            pg.wait_for_timeout(1500)
        chk("★ 那一行是勾上的", pg.locator(sel).count() >= 1,
            "勾中的行数：%d" % pg.locator(sel).count())
        chk("★ 勾上之后详情卡展开了它",
            ("#%s" % tid) in pg.inner_text(".dsapp-taskdetail"),
            pg.inner_text(".dsapp-taskdetail")[:200])

        pg.locator("#tasks-open_ws").first.click()
        pg.wait_for_timeout(4000)
        chk("★★ 跳到了文件页", "文件" in pg.inner_text("#dsapp_page_title"),
            pg.inner_text("#dsapp_page_title"))
        bar2 = pg.inner_text(".dsapp-focusbar") \
            if pg.locator(".dsapp-focusbar").count() else ""
        # 两种写法都算对，但**"已定位到 这个对话的产物"不算** ——
        # 那句话恰恰就是"跳到当前对话去了"的意思。
        chk("★★ 说的是「在看另一个对话的工作区」，不是「这个对话的产物」",
            ("的工作区" in bar2) and ("任务 #%s" % tid) in bar2, bar2)
        chk("★★ 看到的确实是那条任务的产出（不是新对话的空工作区）",
            pg.locator(".dsapp-wsrow", has_text="results_v8").count() >= 1 or
            pg.locator(".dsapp-wsrow", has_text="expr_norm.csv").count() >= 1,
            "文件页上看不到 results_v8 / expr_norm.csv")

        # 退路：得能走回当前对话
        if pg.locator(".dsapp-focusbar").count():
            pg.locator(".dsapp-focusbar-back").first.click()
            pg.wait_for_timeout(3000)
            chk("★ 点「回到当前对话」之后定位条消失了（有退路）",
                pg.locator(".dsapp-focusbar").count() == 0,
                pg.inner_text(".dsapp-focusbar")
                if pg.locator(".dsapp-focusbar").count() else "")

    pg.screenshot(path=os.path.join(OUT, "crossnav.png"))
    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
