# -*- coding: utf-8 -*-
"""V17 item 6（OA 隐私审计查出的 H1）：文件页的会话下拉能不能指向**别人的**工作区。

审计的结论是**读代码**得来的（缺一道 `db_session_role` 闸），当时**没有运行时
复现**（遵守只读约束）。这一条探针把它补上：两个账号、两份工作区、一个哨兵
文件，然后**手工把 `files-pick_conv` 改成对方的会话号**。

修好之后该看到什么（写在跑之前，跑完对一遍）：

  1. 甲自己选自己的会话 → 哨兵文件**列得出来**（正控：这条探针确实看得见它）
  2. 乙选自己的会话      → 只看得见乙的哨兵
  3. 乙把 input 硬改成甲的会话号 →
     a. ★ 甲的哨兵**看不到**（核心）
     b. ★ 乙自己的哨兵**还在**（不是"整个面板空了"——那也是一条会绿的假象）
     c. 弹了一条「这个对话不存在，或者没有共享给你」
     d. 甲的会话标题没出现在乙的页面上
  4. 全程没有 JS 异常

⚠️⚠️ 3b 那条**不能省**。第一版设计里只断言"看不到甲的"，而乙当时**根本没
   有会话**（`state$chat_session_id` 是 NULL）→ 面板本来就是空的 → 那条断言
   在**任何**情况下都绿，包括"这一页坏了"。乙必须有自己的一份、并且看得见，
   这条尺子才有劲。

⚠️ 复现要"知道对方的会话号"这件事**不算防线**：sid 是
   `s-<14 位时间戳>-<4 位随机数>`
   （`R/utils.R:1134`），而命中与否界面上直接可辨（标题、文件数都变了），
   等于给了一个枚举判据。所以不能靠"猜不到"来当安全边界。
"""
import os
import random
import sqlite3
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                       # noqa: E402
from playwright.sync_api import sync_playwright            # noqa: E402

TAG = uuid.uuid4().hex[:6]
SENT_A = "ACL甲的哨兵_%s.txt" % TAG
SENT_B = "ACL乙的哨兵_%s.txt" % TAG
TITLE_A = "ACL甲会话_%s" % TAG
TITLE_B = "ACL乙会话_%s" % TAG

fails = []


def chk(name, cond, extra=""):
    if cond:
        print("  \033[32m✓\033[0m %s" % name, flush=True)
    else:
        fails.append(name)
        print("  \033[31m✗ %s\033[0m" % name, flush=True)
        if extra:
            print("      \033[31m实际是：%s\033[0m" % extra, flush=True)


def now_utc():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())


def mk_session(db, uid, title):
    """照库里的样子插一条会话行。

    ⚠️ 不走界面：本条探针要证的是**授权**，不是"能不能建会话"。直接插一行
       比驱动一轮假 LLM 快得多，也少一串会失败的环节 —— 那些环节一旦红了，
       报出来的错和本探针要回答的问题毫无关系。
    """
    sid = "s-%s-%04d" % (time.strftime("%Y%m%d%H%M%S"),
                         random.randint(1000, 9999))
    t = now_utc()
    con = sqlite3.connect(db)
    try:
        con.execute("INSERT INTO sessions (id, title, created_at, updated_at,"
                    " user_id) VALUES (?,?,?,?,?)", (sid, title, t, t, uid))
        con.commit()
    finally:
        con.close()
    return sid


def mk_sentinel(sid, name):
    """在**这个实例的**工作区里放一个哨兵文件。

    ⚠️ 直接写盘、不走界面：工作区的路径约定是 `dsapp_ws_name(sid)` =
       `chat-<sid>`（`R/utils.R:328`），文件页读的就是盘（磁盘是真相，
       task_files 只是索引）。所以放一个文件进去，文件页就该列出来 ——
       这也正是"甲看得见、乙不该看得见"这条对照的基础。
    """
    d = os.path.join(C.DATA_ROOT, "workspaces", "chat-" + sid)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("哨兵\n")
    return p


def pick(pg, sid):
    """**像攻击者那样**直接写 input —— 这正是要防的那一下。

    界面上那个 <select> 的 onchange 干的就是这一句（`R/mod_files.R:1262`），
    所以这不是"绕过界面"，是把界面那一句原样发一遍、只是值换成了别人的。
    """
    pg.evaluate("""(v) => Shiny.setInputValue('files-pick_conv', v,
                                           {priority: 'event'})""", sid)
    pg.wait_for_timeout(2500)


def ws_rows(pg):
    """当前工作区面板上列出来的文件名。"""
    return pg.evaluate("""() => Array.from(
        document.querySelectorAll('.dsapp-wsrow'))
        .map(e => e.getAttribute('data-rel'))""")


def wait_notice(pg, frag, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        txt = pg.evaluate("""() => Array.from(
            document.querySelectorAll('.shiny-notification'))
            .map(e => e.innerText).join('\\n')""")
        if frag in txt:
            return txt
        pg.wait_for_timeout(300)
    return None


def files_page(pg):
    C.goto(pg, "files")
    pg.wait_for_timeout(1500)


def main():
    print("实例 %s（数据根 %s）" % (C.URL, C.DATA_ROOT), flush=True)
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctxA = b.new_context(viewport={"width": 1440, "height": 950})
        ctxB = b.new_context(viewport={"width": 1440, "height": 950})
        pgA, pgB = ctxA.new_page(), ctxB.new_page()
        errs = []
        pgA.on("pageerror", lambda e: errs.append("甲: " + str(e)))
        pgB.on("pageerror", lambda e: errs.append("乙: " + str(e)))

        try:
            # ---- 两个账号 ---------------------------------------------------
            emailA = "v17_acl_a_%s@example.com" % TAG
            emailB = "v17_acl_b_%s@example.com" % TAG
            C.enter_app(pgA, email=emailA, nickname="ACL甲")
            uidA, db = C.seed_or_die(emailA)
            C.enter_app(pgB, email=emailB, nickname="ACL乙")
            uidB, db2 = C.seed_or_die(emailB)
            print("  甲 uid=%s  乙 uid=%s  库=%s" % (uidA, uidB, db), flush=True)

            print("\n== 前置 ==")
            chk("甲和乙是两个**不同**的账号，而且都落在同一个库里",
                uidA != uidB and db == db2, (uidA, uidB))
            chk("这个实例的数据根不是生产目录（guard 已过）",
                C.DATA_ROOT.startswith("/tmp/"), C.DATA_ROOT)

            sidA = mk_session(db, uidA, TITLE_A)
            sidB = mk_session(db, uidB, TITLE_B)
            pa = mk_sentinel(sidA, SENT_A)
            pb = mk_sentinel(sidB, SENT_B)
            chk("★ 两个哨兵文件都真的落在盘上（正控，不然两边都「看不见」也绿）",
                os.path.exists(pa) and os.path.exists(pb),
                {"甲": pa, "乙": pb})

            # ---- 1. 甲看自己 -------------------------------------------------
            print("\n== 1. 甲选自己的会话（正控）==")
            C.ensure_no_modal(pgA)
            files_page(pgA)
            pick(pgA, sidA)
            ra = ws_rows(pgA)
            chk("★ 甲的工作区面板里**列得出来**自己那个哨兵（尺子看得见它）",
                SENT_A in ra, ra[:8])

            # ---- 2. 乙看自己 -------------------------------------------------
            print("\n== 2. 乙选自己的会话 ==")
            C.ensure_no_modal(pgB)
            files_page(pgB)
            pick(pgB, sidB)
            rb = ws_rows(pgB)
            chk("乙看得见自己的哨兵", SENT_B in rb, rb[:8])
            chk("乙这时候**看不见**甲的哨兵（本来就该如此）",
                SENT_A not in rb, rb[:8])

            # ---- 3. 乙把 input 硬改成甲的会话号 -------------------------------
            print("\n== 3. ★ 乙把 files-pick_conv 改成甲的会话号 ==")
            pick(pgB, sidA)
            rb2 = ws_rows(pgB)
            chk("★★★ 甲的哨兵**看不到**（这就是审计里那条越权，现在该被挡住）",
                SENT_A not in rb2, rb2[:8])
            chk("★★★ 乙自己的哨兵**还在**（不是「面板整个空了」那种假绿）",
                SENT_B in rb2, rb2[:8])
            note = wait_notice(pgB, "没有共享给你")
            chk("★★ 弹了一条「这个对话不存在，或者没有共享给你」",
                note is not None, note)
            body = pgB.evaluate("() => document.body.innerText")
            chk("★★ 甲的会话标题没有出现在乙的页面上",
                TITLE_A not in body, [l for l in body.splitlines()
                                      if TITLE_A in l][:3])

            print("\n== 4. 收尾 ==")
            chk("两个页面都没抛 JS 异常", not errs, errs[:3])
        finally:
            for nm, pg in (("A", pgA), ("B", pgB)):
                try:
                    pg.screenshot(path=os.path.join(C.OUT, "acl_%s.png" % nm))
                except Exception:
                    pass
            b.close()

    print()
    if fails:
        print("\033[31m%d 条没过：\033[0m" % len(fails))
        for f in fails:
            print("   -", f)
        return 1
    print("\033[32m全部通过\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
