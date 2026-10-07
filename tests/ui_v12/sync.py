# -*- coding: utf-8 -*-
"""V12 item 3 的端到端回归：任务产物**自动**同步到文件管理区。

用户原话：「任务产生的文件还是不能同步到文件管理区，请设置自动同步」。

为什么是一条端到端而不是又一条离线断言：离线那份（/tmp/sync_probe.R 那一类）
只证明 dsapp_sync_artifacts **被调用时**是对的。这件事在 V3 到 V11 之间一直
"看起来是好的" —— 函数在、参数对、离线跑一遍全绿 —— 真正断掉的是**没有人
调用它**。所以这条测试从浏览器点「确认执行」开始，一路走到共享区的文件真的
躺在磁盘上、并且能在「文件」页里列出来为止。

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v12/sync.py
"""
import os
import sqlite3
import sys
import time
import uuid

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C

TAG = str(int(time.time()))[-6:]
EMAIL = "v12sync_%s@example.com" % TAG
SID = "v12sync-%s" % uuid.uuid4().hex[:8]
TITLE = "V12同步用例"          # 会变成共享区里的文件夹名（截断到 40 字）
FILES_DIR = os.path.join(C.DATA_ROOT, "files")

# 两段代码：第二段把第一段的产物**改名重写**，用来验"重跑覆盖自己上一轮"。
# 这是这次改动里最容易错的一条 —— 落盘的文件被 dsapp_files_protect 改成
# 0444，file.copy(overwrite=TRUE) 会失败，而 R 只发一条 warning、返回 FALSE，
# 任务本身照样报成功。不测这条的话，第二次跑完共享区里还是上一次的旧数据。
BLOCK1 = '''dir.create("results", showWarnings = FALSE)
write.csv(data.frame(gene = c("TP53", "EGFR"), logfc = c(1.2, -0.8)),
          "de.csv", row.names = FALSE)
write.csv(data.frame(n = 3), "results/qc.csv", row.names = FALSE)
cat("第一轮写完了\\n")'''

BLOCK2 = '''dir.create("results", showWarnings = FALSE)
write.csv(data.frame(gene = c("TP53", "EGFR"), logfc = c(2.4, -1.6)),
          "de.csv", row.names = FALSE)
write.csv(data.frame(n = 3), "results/qc.csv", row.names = FALSE)
cat("第二轮写完了\\n")'''


def db(sql, args=()):
    """只读查一下库。连不上（正在写、锁着）就返回 None，调用方自己重试。"""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % C.db_path(), uri=True, timeout=2)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()
    except Exception:
        return None


def seed():
    """塞一个对话：一条用户消息 + 一条带**两段** R 代码的助手消息。

    两段放在**同一条**消息里是有意的：confirm_slot 只看最后一条助手消息，
    跑完第一段之后它会把第二段顶上来（见 mod_chat.R 的 pending_code）。
    分成两条消息也行，但那样第二次点击前得靠 reload 碰运气。

    ⚠️ 找不到账号就硬退出 —— 那说明这个实例读的不是这份 .Renviron。
    """
    con = sqlite3.connect(C.db_path(), timeout=10)
    cur = con.cursor()
    uid = cur.execute("SELECT id FROM users WHERE email = ?", (EMAIL,)).fetchone()
    if uid is None:
        con.close()
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里（这个实例读的不是这份 "
                 ".Renviron）。" % (EMAIL, C.db_path()))
    uid = uid[0]
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cur.execute("DELETE FROM messages WHERE session_id = ?", (SID,))
    cur.execute("DELETE FROM sessions WHERE id = ?", (SID,))
    cur.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)", (SID, TITLE, now, now, uid))
    cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)",
                (SID, "user", "帮我跑一下差异分析，把结果存成文件", now))
    body = ("好的，这一段会写出 `de.csv`：\n\n```r\n%s\n```\n\n"
            "跑完再看这一段（把 logfc 换一组数）：\n\n```r\n%s\n```\n" % (BLOCK1, BLOCK2))
    cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)", (SID, "assistant", body, now))
    con.commit()
    con.close()
    return uid


def wait_task(timeout=150):
    """等**这个对话**的第一个任务跑完，返回它的 id。"""
    end = time.time() + timeout
    tid = None
    while time.time() < end:
        rows = db("SELECT id, status FROM tasks WHERE session_id = ? ORDER BY id",
                  (SID,))
        if rows:
            tid = rows[0][0]
            if rows[0][1] in ("done", "success", "failed", "error", "timeout"):
                return tid, rows[0][1]
        time.sleep(2)
    return tid, None


def click_run(pg, expect_n):
    """点输出框下沿那颗「确认执行」，等到第 expect_n 个任务结束。"""
    pg.wait_for_selector(".dsapp-code-run", timeout=30000)
    pg.click(".dsapp-code-run")
    pg.wait_for_timeout(1500)
    # 未命中高危但命中了提醒规则时，服务端弹一个「仍然执行」的确认框
    if pg.locator("#chat-do_run").count():
        pg.click("#chat-do_run")
    end = time.time() + 150
    while time.time() < end:
        rows = db("SELECT id, status FROM tasks WHERE session_id = ? ORDER BY id",
                  (SID,))
        if rows and len(rows) >= expect_n:
            st = rows[expect_n - 1][1]
            if st in ("done", "success", "failed", "error", "timeout"):
                return rows[expect_n - 1][0], st
        time.sleep(2)
    return None, None


with sync_playwright() as b:
    br = b.chromium.launch()
    ctx = br.new_context(viewport={"width": 1440, "height": 900})
    pg = ctx.new_page()
    chk = C.Chk()

    C.enter_app(pg, email=EMAIL, nickname="V12同步")
    uid = seed()
    C.goto_chat(pg, reload_first=True)
    pg.click(".dsapp-sess[data-sid='%s']" % SID)
    pg.wait_for_timeout(3000)

    # 亮着的「确认执行」= 待确认的代码 —— 这条同时是 item 2 的前置条件：
    # 按钮灰着的时候点它是什么都不会发生的，测试必须在点亮之后才点。
    chk("★ 「确认执行」亮起来了（有代码待确认）",
        pg.locator(".dsapp-code-run").count() > 0)

    # =====================================================================
    # 第一轮：跑完 → 产物自动同步
    # =====================================================================
    tid, st = click_run(pg, 1)
    chk("任务跑完了（不是失败/超时）", st in ("done", "success"),
        "task=%s status=%s" % (tid, st))
    chk("任务挂在**这个对话**上", tid is not None, tid)
    if st not in ("done", "success"):
        pg.screenshot(path=C.OUT + "/sync_failed.png", full_page=True)
        print(pg.inner_text(".dsapp-chat-scroll")[-2000:])

    # 等同步落盘（同步在 e$poll 里、任务收尾之后，比状态落库晚一点）
    end = time.time() + 40
    rows = []
    while time.time() < end:
        rows = db("SELECT dir FROM sync_dirs WHERE session_id = ?", (SID,)) or []
        if rows:
            break
        time.sleep(1)
    chk("★ 库里给这个对话建了同步目录（sync_dirs 有记录）", bool(rows), rows)
    dest = rows[0][0] if rows else None
    # ⚠️ V13.0 起共享区按账号分了一层：`files/u<uid>/<目录>/`，不再是
    #    `files/<目录>/`（见 R/files.R 的 dsapp_files_user_dir，以及同文件里
    #    那个 `.migrated_v13` 迁移）。这份脚本写于 V12，一直按老布局找文件
    #    —— 所以它**从 V13.0 起就红着**，和 V13.2 无关。
    #    2026-09-16 修的是这条测试路径，不是产品代码。
    root = (os.path.join(FILES_DIR, "u%d" % uid, dest) if dest else None)
    if root:
        end = time.time() + 20
        while time.time() < end and not os.path.exists(os.path.join(root, "de.csv")):
            time.sleep(1)

    chk("★ 产物躺在共享区里（files/<目录>/de.csv）",
        bool(root) and os.path.isfile(os.path.join(root, "de.csv")), root)
    chk("★ 子目录结构保留了（results/qc.csv）",
        bool(root) and os.path.isfile(os.path.join(root, "results", "qc.csv")),
        root)
    chk("同步目录名带上了对话标题", bool(dest) and dest.startswith(TITLE), dest)

    if root and os.path.isfile(os.path.join(root, "de.csv")):
        first = open(os.path.join(root, "de.csv")).read()
        chk("第一轮的内容落对了", "1.2" in first, first[:80])
        # 工作区里的内部文件**不许**跟着搬过去
        stray = [f for f in os.listdir(root)
                 if f.startswith(".dsapp") or f == ".Rlib"]
        chk("内部文件（.dsapp_script.R / .Rlib）没被搬过去", not stray, stray)

    pub = db("SELECT dest FROM ws_published") or []
    chk("★ 发布表里有记录（用相对路径，不是绝对路径）",
        any("de.csv" in (r[0] or "") for r in pub),
        [r[0] for r in pub][:6])

    own = db("SELECT 1 FROM file_owner WHERE name LIKE ?", ("%" + (dest or "") + "%",))
    chk("归属记到了这个账号头上", bool(own), own)

    # =====================================================================
    # 文件页里看得见 —— 用户说的"文件管理区"就是这一页
    # =====================================================================
    pg.evaluate("() => window.dsappNav && window.dsappNav('files')")
    pg.wait_for_timeout(4000)
    txt = pg.inner_text(".dsapp-main-body")
    chk("★ 「文件」页的共享区列表里出现了这个文件夹",
        bool(dest) and dest in txt,
        [ln for ln in txt.splitlines() if ln.strip()][:12])
    pg.screenshot(path=C.OUT + "/03_files_page.png", full_page=True)

    # 点「名称」列进目录（服务端只认 col==1，也就是名称列）
    cell = pg.locator("#files-tbl td", has_text=dest) if dest else None
    if cell and cell.count():
        cell.first.click()
        pg.wait_for_timeout(3000)
        txt2 = pg.inner_text(".dsapp-main-body")
        chk("★ 点进文件夹能看到 de.csv",
            "de.csv" in txt2, txt2[:400])
        chk("子目录 results 也在", "results" in txt2, txt2[:400])
        pg.screenshot(path=C.OUT + "/04_files_subdir.png", full_page=True)
    else:
        chk("★ 文件页里能点进这个文件夹", False,
            "DT 表里没找到 %s 那一格" % dest)

    # =====================================================================
    # 第二轮：重跑 → 覆盖自己上一轮，不许堆 de(1).csv
    # =====================================================================
    C.goto_chat(pg)
    pg.click(".dsapp-sess[data-sid='%s']" % SID)
    pg.wait_for_timeout(3000)
    tid2, st2 = click_run(pg, 2)
    chk("第二轮也跑完了", st2 in ("done", "success"), "task=%s st=%s" % (tid2, st2))
    time.sleep(8)
    if root and os.path.isfile(os.path.join(root, "de.csv")):
        second = open(os.path.join(root, "de.csv")).read()
        chk("★ 重跑**覆盖**了上一轮的产物（内容换了）", "2.4" in second, second[:80])
        chk("★ 没有堆出 de(1).csv 之类的副本",
            not [f for f in os.listdir(root) if "(1)" in f or "(2)" in f],
            os.listdir(root))
    else:
        chk("第二轮产物可读", False, root)
    chk("落点没变（还是同一个文件夹）",
        (db("SELECT dir FROM sync_dirs WHERE session_id = ?", (SID,)) or
         [[None]])[0][0] == dest, dest)

    br.close()

print("数据目录 " + C.DATA_ROOT)
sys.exit(chk.done())
