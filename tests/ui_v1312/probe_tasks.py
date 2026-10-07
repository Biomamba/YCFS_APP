# -*- coding: utf-8 -*-
"""任务页：V13.12 item 20 改成"内容指纹"之后，这一页还得是好用的。

    python3 tests/ui_v1312/probe_tasks.py

任务页那一改动（每 1.5 秒 refresh 加一 → 内容变了才写）有一个很容易看不见的
风险：**行号**。`selected_ids()` 拿 `input$tbl_rows_selected` 直接去 `tasks()`
里取 `df$id`，`current()` 又按"行号最小的那条"决定右栏显示谁（见 mod_tasks.R
里那两段 ⚠️）。改数据来源的时候行号一旦对不上，症状是"勾第 1 行、右栏显示的
是第 3 条"，而这**不报任何错** —— 点「删除选中」的时候删掉的也是另一条。

所以这里造三条真任务（直接写这个**一次性实例**的库，不碰生产库），然后：

  · 三条都在列表里；
  · 勾第 1 行，右栏详情说的就是第 1 条（行号↔id 映射）；
  · 换个筛选能筛掉，清空能还原；
  · 库里新插一条之后点「刷新」看得见（手动那一下必须真的重查）；
  · 静置 6 秒，这一页**一次都不重画**（没有偷偷留一个常驻定时器）。

⚠️ 只往 /tmp 下这个一次性实例的库里写。seed_or_die() 已经确认过这个实例
   读的不是线上库（找不到就硬退出）。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8913/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1312/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1312")

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

SID = "s-v1312item20-taskpage"
TITLES = ["item20 回归：第一条", "item20 回归：第二条", "item20 回归：第三条"]
STATUS = ["success", "failed", "running"]

HOOK = """
() => {
  window.__t = {n: {}, t0: Date.now()};
  $(document).on('shiny:outputinvalidated', function (e) {
    var id = (e.target && e.target.id) || '(no-id)';
    window.__t.n[id] = (window.__t.n[id] || 0) + 1;
  });
}
"""


def now_s():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())


def plant(db, uid):
    """造一条会话 + 三条任务。返回三条的 id（按插入顺序）。"""
    con = sqlite3.connect(db)
    t = now_s()
    con.execute("DELETE FROM tasks WHERE session_id = ?", (SID,))
    con.execute("DELETE FROM sessions WHERE id = ?", (SID,))
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?, ?, ?, ?, ?)", (SID, "item20 任务页回归", t, t, uid))
    ids = []
    for i, (ti, st) in enumerate(zip(TITLES, STATUS)):
        cur = con.execute(
            "INSERT INTO tasks (session_id, title, lang, code, status, created_at,"
            " started_at, finished_at, stdout, stderr, target)"
            " VALUES (?, ?, 'R', ?, ?, ?, ?, ?, ?, ?, 'local') RETURNING id",
            (SID, ti, "cat('第 %d 条\\n')" % (i + 1), st, t,
             t if st != "pending" else None,
             t if st in ("success", "failed") else None,
             "第 %d 条的输出\n" % (i + 1),
             "" if st == "success" else "boom\n"))
        ids.append(cur.fetchone()[0])
    con.commit()
    con.close()
    return ids


def add_one(db, uid, title):
    con = sqlite3.connect(db)
    cur = con.execute(
        "INSERT INTO tasks (session_id, title, lang, code, status, created_at,"
        " target) VALUES (?, ?, 'R', 'cat(1)', 'success', ?, 'local')"
        " RETURNING id", (SID, title, now_s()))
    i = cur.fetchone()[0]
    con.commit()
    con.close()
    return i


def rows(pg):
    """表格里的数据行数（DataTables 的 tbody tr）。"""
    return pg.locator("#tasks-tbl tbody tr").count()


def main():
    k = C.Chk()
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1600, "height": 950})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: errs.append(m.text)
              if m.type == "error" else None)
        e = C.enter_app(pg)
        uid, db = C.seed_or_die(e)
        ids = plant(db, uid)

        C.goto(pg, "tasks")
        pg.wait_for_timeout(2500)

        # 分组默认开着，三条同属一个会话会被折成"组头 + 行"。先关掉再数行，
        # 免得把组头也数进去 —— 这一页本来就给了这个开关（V13.11 item 11）。
        grp = pg.locator("#tasks-f_group")
        if grp.count() and grp.is_checked():
            grp.uncheck()
            pg.wait_for_timeout(1500)

        n0 = rows(pg)
        k("三条任务都列出来了", n0 == 3, "看到 %d 行" % n0)
        txt = pg.inner_text("#tasks-tbl")
        k("★★ 标题对得上", all(t in txt for t in TITLES))

        # ---- 行号 ↔ id ---------------------------------------------------
        #
        # ⚠️ 这是这一页最容易错、又最不容易发现的地方：所有按钮都按**行号**
        #    回查 tasks()。点某一行，右栏必须就是那一行的任务。
        #
        # ⚠️ 探针这里**不能**假定"第 1 行 = 我先插的那条"：列表是
        #    `ORDER BY t.id DESC`（新的在上面），照着插入顺序写断言的话，
        #    红的是探针自己，看着却像"行号串了"。先按标题把行找出来再点。
        def row_of(title):
            r = pg.locator("#tasks-tbl tbody tr")
            for i in range(r.count()):
                if title in r.nth(i).inner_text():
                    return i
            return -1

        def pick(title):
            i = row_of(title)
            if i < 0:
                return None
            pg.locator("#tasks-tbl tbody tr").nth(i).locator("td").first.click()
            pg.wait_for_timeout(1500)
            return pg.inner_text(".dsapp-taskdetail")

        d1 = pick(TITLES[0])
        k("★★★ 勾「第一条」那一行，右栏说的就是第一条（行号↔id 没串）",
          d1 is not None and TITLES[0] in d1 and TITLES[2] not in d1,
          (d1 or "找不到那一行").replace("\n", " ")[:80])

        d3 = pick(TITLES[2])
        k("★★★ 换勾「第三条」那一行，右栏跟着换过去",
          d3 is not None and TITLES[2] in d3 and TITLES[0] not in d3,
          (d3 or "找不到那一行").replace("\n", " ")[:80])

        # ---- 筛选 --------------------------------------------------------
        pg.fill("#tasks-f_kw", "第二条")
        pg.wait_for_timeout(1800)
        n1 = rows(pg)
        k("★★ 搜关键词能筛到 1 条", n1 == 1, "看到 %d 行" % n1)
        pg.click("#tasks-f_clear")
        pg.wait_for_timeout(1800)
        n2 = rows(pg)
        k("★★ 清空筛选能还原 3 条", n2 == 3, "看到 %d 行" % n2)

        # ---- 手动刷新必须真的重查 ----------------------------------------
        #
        # 这一条是"内容指纹"改动的**反向**保险：指纹判"没变化就不写"，
        # 万一连用户手动点的那一下也被判掉，表格就再也刷不出来了。
        add_one(db, uid, "item20 回归：刷新之后才有的第四条")
        pg.wait_for_timeout(600)
        k("★★ 库里新插一条、**没点刷新**时表格不动（指纹在起作用）",
          rows(pg) == 3, "看到 %d 行" % rows(pg))
        pg.click("#tasks-refresh")
        pg.wait_for_timeout(2000)
        n3 = rows(pg)
        k("★★★ 点「刷新」之后第四条出现了（手动那一下是 force）",
          n3 == 4, "看到 %d 行" % n3)

        # ---- 静置：不许有常驻定时器 --------------------------------------
        pg.evaluate(HOOK)
        pg.wait_for_timeout(6000)
        d = pg.evaluate("() => window.__t.n")
        n_tot = sum(d.values())
        k("★★★ 静置 6 秒这一页一次都没重画（没有偷偷留下的定时器）",
          n_tot == 0, "重画 %d 次：%r" % (n_tot, d))

        k("没有 JS 报错", not errs, "; ".join(errs[:3]))
        pg.screenshot(path=C.OUT + "/tasks_after.png", full_page=True)
        b.close()

    # 收尾：把造出来的会话和任务删掉（这个实例的库会在下次 make_instance 时
    # 被覆盖，但留着会让别的探针看到三条来路不明的任务）。
    try:
        con = sqlite3.connect(db)
        con.execute("DELETE FROM tasks WHERE session_id = ?", (SID,))
        con.execute("DELETE FROM sessions WHERE id = ?", (SID,))
        con.commit()
        con.close()
    except Exception:
        pass
    return k.done()


if __name__ == "__main__":
    sys.exit(main())
