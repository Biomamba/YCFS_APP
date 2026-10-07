# -*- coding: utf-8 -*-
"""V9 item 2 / 8：执行过程要在言出法随页展示，失败的要有反馈。

对着一次性实例（8898）跑。会真的注册账号、**真的提交代码到执行引擎**
（子进程、工作区、写库全是真的）。唯一被替身的是大模型：助手消息由测试
直接写进那个临时库 —— 那本来就是一个存消息的表，而"这段消息里有一个代码块"
正是执行路径的入口。

为什么不走真的模型：这条需求验的是**平台展示执行过程**，不是模型会不会写
代码。用真模型的话，每次跑的内容都不一样，"报错里有没有出现那句话"这种
断言会随机红。

⚠️ 只碰 $DATA_ROOT 底下的库（顶上有 _guard 拦一道）。
⚠️ 「停止任务」那条**不**在这里测：它要在任务跑着的时候点，而任务跑多久
   取决于机器；写成固定 sleep 的话，在快机器上是"测过了"，在慢机器上
   任务还没起来就已经点完了 —— 那种测试比没有更坏。
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


def add_msg(sid, role, content):
    exec_sql("INSERT INTO messages (session_id, role, content, created_at) "
             "VALUES (?, ?, ?, ?)",
             (sid, role, content, time.strftime("%Y-%m-%d %H:%M:%S")))


def register(pg, tag):
    email = "v9exec_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        if pg.locator("#welcome-go_register").count():
            pg.click("#welcome-go_register")
            pg.wait_for_timeout(1200)
    pg.fill("#welcome-nickname", "执行展示测试")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000006")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    pg.check(".dsapp-auth input[type=checkbox]")     # V9 item 1：须知
    return email


def enter(pg):
    """从入口页进主界面（注册或登录）。返回是否进去了。"""
    if pg.locator("#welcome-do_register").count():
        pg.click("#welcome-do_register")
        pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count():
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(6000)
    try:
        pg.wait_for_selector(".dsapp-shell", timeout=30000)
        return True
    except Exception:
        return False


# ---- 两段被测代码 ---------------------------------------------------------
#
# 成功那段必须跑够久，否则"正在执行"面板在断言轮到它之前就收了 —— 那会让
# 这条测试在快机器上变成永远绿的空断言（toc_preview.py 里踩过一模一样的坑：
# 断言时容器根本没溢出）。
# 失败那段把报错写在**最后一行**，这样"报错原文看得见"才是真的验到了
# （stderr 的末尾才是用户要读的那几行）。
CODE_OK = """```r
cat("开始读数据\\n")
for (i in 1:12) { cat(sprintf("第 %d 步完成\\n", i)); Sys.sleep(1.2) }
write.csv(data.frame(基因 = c("TP53", "EGFR"), 倍数 = c(2.1, 0.4)),
          "volcano_data.csv", row.names = FALSE)
cat("全部完成\\n")
```"""

CODE_BAD = """```r
cat("准备载入表达矩阵\\n")
Sys.sleep(8)
stop("找不到文件：/data/expr_matrix.h5 —— 请确认上传路径")
```"""

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    # -------------------------------------------------------------------
    print("\n== 准备：注册一个账号进主界面 ==")
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
    register(pg, tag)
    chk("★ 注册并进入主界面", enter(pg))

    # 新建对话 —— 这条路不经过大模型，所以不需要 API Key
    pg.wait_for_timeout(2000)
    chk("★ 有「新建对话」按钮", pg.locator("#chat-new_chat").count() >= 1)
    pg.click("#chat-new_chat")
    pg.wait_for_timeout(3000)

    # -------------------------------------------------------------------
    print("\n== 用例 A：执行成功的全过程 ==")
    # -------------------------------------------------------------------
    rs = sql("SELECT id FROM sessions ORDER BY created_at DESC, rowid DESC LIMIT 1")
    sid = rs[0][0] if rs else None
    chk("★ 新对话建出来了", sid is not None, sid)
    if sid:
        add_msg(sid, "user", "帮我读一下表达矩阵然后画个火山图")
        add_msg(sid, "assistant", "先跑这一步看看数据和环境对不对：\n\n" + CODE_OK)
        # 给会话起个**独一无二**的名字，好在卡片上认出来（V9 item 7 的标题是
        # 「任务功能_所属会话」，会话名是其中一半）。
        # ⚠️ 第一版这里断言的是用户那句话里的词，结果永远是红的 —— 任务标题
        #    取的是**会话名**（那时还是默认的"新会话"），不是用户消息。
        exec_sql("UPDATE sessions SET title = ? WHERE id = ?",
                 ("单细胞聚类验证-%s" % tag, sid))
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        # 重载之后默认落回"新建对话"空页，点侧栏里那条进去
        pg.wait_for_selector(".dsapp-sess", timeout=30000)
        pg.click(".dsapp-sess")
        pg.wait_for_timeout(4000)

    run_btn = pg.locator(".dsapp-code-run")
    chk("★★ 代码卡片上有「确认执行」", run_btn.count() >= 1, run_btn.count())
    pg.screenshot(path=os.path.join(OUT, "v9_exec_card.png"), full_page=True)

    if run_btn.count():
        run_btn.first.click()
        # 任务要在 6~7 秒里被断言到"正在执行"。轮询窗口给足。
        seen_live = False
        live_txt = ""
        for _ in range(24):
            pg.wait_for_timeout(500)
            if pg.locator(".dsapp-run-live").count():
                seen_live = True
                live_txt = pg.inner_text(".dsapp-run-live")
                break
        chk("★★ 任务跑起来之后，对话页上出现「正在执行」面板（不用切到任务页）",
            seen_live, pg.inner_text("body")[-300:].replace("\n", " "))
        if seen_live:
            pg.screenshot(path=os.path.join(OUT, "v9_exec_live.png"), full_page=True)
            chk("★ 面板上写着任务号和「正在执行」",
                "正在执行" in live_txt and "#" in live_txt,
                live_txt[:120].replace("\n", " "))
            chk("★ 面板上有实时输出区", "实时输出" in live_txt, live_txt[:200])
            chk("★ 面板上有「停止任务」（不用切页去停）",
                pg.locator(".dsapp-run-stop").count() >= 1)
            # 实时输出**确实在增长**才算数。只断言"有这块 UI"、或者只断言
            # "面板文字变了"是不够的 —— 那个"变"可能只是元信息行里的
            # 「已跑 N 秒」在走，底下的输出一个字都没有。第一版就是这么写的，
            # 结果在一台机器上真跑出过"面板上写着（子进程还没有输出）"
            # 却仍然判绿的情况。
            #
            # ⚠️ 要等。子进程起来本身要 3~5 秒（起解释器 + 挂本对话的包目录），
            #    这段时间里输出区合法地是空的 —— 定死 3 秒去采样就会误判成
            #    "实时输出坏了"。这里等到真的出现输出为止，再验它在**长**。
            seen_out, lines1 = False, 0
            for _ in range(30):
                pg.wait_for_timeout(1000)
                if not pg.locator(".dsapp-run-live").count():
                    break
                txt = pg.inner_text(".dsapp-run-live")
                if "步完成" in txt or "开始读数据" in txt:
                    seen_out = True
                    lines1 = len([l for l in txt.split("\n") if "步完成" in l])
                    break
            chk("★★ 子进程打印的东西实时出现在面板上（不是等跑完才显示）",
                seen_out, pg.inner_text("body")[-200:].replace("\n", " "))

            if seen_out:
                pg.wait_for_timeout(4000)
                txt2 = pg.inner_text(".dsapp-run-live")
                lines2 = len([l for l in txt2.split("\n") if "步完成" in l])
                chk("★★ 并且是**边跑边长**的（%d 行 → %d 行）" % (lines1, lines2),
                    lines2 > lines1, txt2[-200:].replace("\n", " "))

        # 等它跑完（代码里 6 次 1.2 秒 + 写文件）
        got_card = False
        card_txt = ""
        for _ in range(60):
            pg.wait_for_timeout(1000)
            if pg.locator(".dsapp-run:not(.dsapp-run-live)").count() and \
               not pg.locator(".dsapp-run-live").count():
                got_card = True
                card_txt = pg.inner_text(".dsapp-run:not(.dsapp-run-live)")
                break
        chk("★★ 跑完之后结果**留在对话里**（以前只有一句 toast 飘过去）",
            got_card, pg.inner_text("body")[-300:].replace("\n", " "))
        if got_card:
            pg.screenshot(path=os.path.join(OUT, "v9_exec_done.png"), full_page=True)
            chk("★ 卡片上有状态徽章（成功）", "成功" in card_txt, card_txt[:200])
            # 标题 = 「任务功能_所属会话」（V9 item 7）。这里认的是**会话名**
            # 那一半：它上面那段是用来辨认"这是哪个任务"的，两半都得在。
            chk("★ 卡片上写了任务标题，且带着所属会话名（任务功能_所属会话）",
                ("单细胞聚类验证-%s" % tag) in card_txt and "_" in card_txt,
                card_txt[:200].replace("\n", " "))
            chk("★ 卡片上写了耗时", "耗时" in card_txt, card_txt[:250])
            chk("★ 卡片上写了完成时间（V9 item 7）", "完成于" in card_txt)
            chk("★ 卡片上写了这次用的环境和语言", "R" in card_txt)
            # 输出默认是折起来的（12 行以内才展开），点了才看得到
            det = pg.locator(".dsapp-run-out")
            chk("★ 执行输出可展开", det.count() >= 1)
            if det.count():
                det.first.click()
                pg.wait_for_timeout(600)
                chk("★★ 展开后能看到代码打印的内容",
                    "全部完成" in pg.inner_text(".dsapp-run:not(.dsapp-run-live)"),
                    pg.inner_text(".dsapp-run-out")[:200].replace("\n", " "))
            chk("★★ 产出的文件列在卡片上（volcano_data.csv）",
                "volcano_data.csv" in pg.inner_text(".dsapp-run:not(.dsapp-run-live)"),
                card_txt[:300].replace("\n", " "))

    # -------------------------------------------------------------------
    print("\n== 用例 B：任务失败要有反馈，而且能顺着往下走 ==")
    # -------------------------------------------------------------------
    if sid:
        add_msg(sid, "user", "换成真实的矩阵再跑一遍")
        add_msg(sid, "assistant", "再试一次，这次读真实文件：\n\n" + CODE_BAD)
        pg.goto(URL, wait_until="domcontentloaded")
        pg.wait_for_timeout(6000)
        pg.wait_for_selector(".dsapp-sess", timeout=30000)
        pg.click(".dsapp-sess")
        pg.wait_for_timeout(4000)

    btns = pg.locator(".dsapp-code-run")
    chk("★ 第二段代码也有「确认执行」", btns.count() >= 1, btns.count())
    if btns.count():
        btns.last.click()
        fail_txt = ""
        got_fail = False
        for _ in range(70):
            pg.wait_for_timeout(1000)
            el = pg.locator(".dsapp-run-err")
            if el.count() and not pg.locator(".dsapp-run-live").count():
                got_fail = True
                fail_txt = el.last.inner_text()
                break
        chk("★★ 失败的任务在对话里给出了反馈（而不是只弹个 toast）",
            got_fail, pg.inner_text("body")[-300:].replace("\n", " "))
        if got_fail:
            pg.screenshot(path=os.path.join(OUT, "v9_exec_fail.png"), full_page=True)
            chk("★ 标出了「失败」", "失败" in fail_txt, fail_txt[:200].replace("\n", " "))
            # 这条是 item 8 的核心：光说"失败了"没用，得把**报错原文**给出来。
            # 参考 claude 的反馈方式 = 报错本身 + 下一步能做什么。
            chk("★★ 报错原文就在对话里（末尾那几行才是要读的）",
                  "找不到文件" in fail_txt and "expr_matrix.h5" in fail_txt,
                  fail_txt[-260:].replace("\n", " "))
            chk("★ 写清了退出码", "退出码" in fail_txt, fail_txt[:200])
            chk("★★ 给了下一步的出路（让 AI 分析这个报错）",
                pg.locator(".dsapp-run-fix").count() >= 1)
            chk("★ 出错的这两句是**醒目**的（红框），不是混在灰字里",
                pg.evaluate("""() => {
                  const e = document.querySelector('.dsapp-run-err .dsapp-run-head');
                  if (!e) return null;
                  const c = getComputedStyle(e).backgroundColor;
                  const m = c.match(/\\d+/g);
                  if (!m) return null;
                  // 红底：R 分量明显高于 G/B
                  return (+m[0]) > (+m[1]) + 8 && (+m[0]) > (+m[2]) + 8;
                }""") is True)
            # 点「让 AI 分析这个报错」→ 报错应该被填进输入框
            pg.click(".dsapp-run-fix")
            pg.wait_for_timeout(2500)
            box = pg.input_value("#chat-input") if pg.locator("#chat-input").count() else ""
            chk("★★ 点「让 AI 分析」把报错和任务号填进了输入框",
                "expr_matrix.h5" in box and "任务 #" in box, box[:160].replace("\n", " "))
            chk("★ 只是填进去，**没有替用户发出去**（发不发由用户定）",
                "找不到文件" not in pg.inner_text("body")[-200:].replace(box, ""),
                box[:80])

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
