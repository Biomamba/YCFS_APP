# -*- coding: utf-8 -*-
"""V16.6 item 3：删账号到底删干净了没有（用户报的是「文件进了共享区」）。

跑法（实例先起好）：
    bash tests/ui_v7/make_instance.sh 8977 /tmp/dsapp_v166a
    python3 tests/ui_v166/probe_delacct.py

自检里那一组验的是**数据层**（建号 → 塞满 → 删 → 每一张表都是 0、目录没了）。
这里验的是**界面层**，两件事自检够不到：

  A. 「资源与文件」那一栏里新加的「无主管理区目录」那一段真的画出来了
     （renderUI，没有 Shiny 会话就不求值），列得出、清得掉；
  B. 从**后台管理**点删除 → 确认框里的话和实际行为一致 → 删完盘上那个
     目录真的没了（用户的原话就是这件事）。
"""
import os
import sys
import sqlite3
import shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

C.guard(C.APP)
CK = C.Chk()
ROOT = C.DATA_ROOT
FILES = os.path.join(ROOT, "files")


def sql(q, args=()):
    con = sqlite3.connect("file:%s?mode=ro" % C.db_path(), uri=True)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(q, args)]
    finally:
        con.close()


def exec_sql(q, args=()):
    con = sqlite3.connect(C.db_path(), timeout=15)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def relogin(page, email):
    page.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if page.locator(".dsapp-shell").count():
            return
        if not submitted and page.locator("#welcome-email").count():
            page.fill("#welcome-email", email)
            page.fill("#welcome-password", C.PW)
            page.click("button:has-text('登录')")
            submitted = True
        page.wait_for_timeout(1000)
    raise SystemExit("reload 之后回不到主界面")


def tab_click(page, val, nav_id):
    ok = page.evaluate("""([id, v]) => {
        var ul = document.getElementById(id);
        if (!ul) return false;
        var a = ul.querySelector('a[data-value="' + v + '"],' +
                                 'button[data-value="' + v + '"]');
        if (!a) return false;
        a.click();
        return true;
    }""", [nav_id, val])
    page.wait_for_timeout(2500)
    return ok


with sync_playwright() as pw:
    br = pw.chromium.launch()
    pg = br.new_page(viewport={"width": 1500, "height": 1000})
    try:
        email = C.enter_app(pg)
        uid, _root = C.seed_or_die(email)
        exec_sql("UPDATE users SET is_admin=1, admin_scope='platform' WHERE id=?",
                 (uid,))
        relogin(pg, C.LAST_EMAIL)
        C.ensure_no_modal(pg)
        print("uid =", uid, " email =", C.LAST_EMAIL, flush=True)

        # ---- ① 先种一个「无主的管理区目录」（删号之前的历史遗留）----------
        #      用一个几乎不可能撞上的 uid：990001
        orphan_uid = 990001
        orphan = os.path.join(FILES, "u%d" % orphan_uid)
        shutil.rmtree(orphan, ignore_errors=True)
        os.makedirs(orphan)
        with open(os.path.join(orphan, "left_behind.csv"), "w") as f:
            f.write("a,b\n1,2\n")
        CK("① 前置：种下一个无主目录 u%d" % orphan_uid, os.path.isdir(orphan))
        CK("① 前置：确实**没有**这个账号",
           not sql("SELECT 1 FROM users WHERE id=?", (orphan_uid,)))

        C.goto(pg, "admin")
        C.ensure_no_modal(pg)
        CK("① 切到「资源与文件」栏", tab_click(pg, "res", "admin-bs_tab"))
        pg.wait_for_timeout(2500)
        txt = pg.inner_text("body")
        # ⚠️ 判据用的是**源码里那两句话本身**：有目录时是
        #    「盘上有 N 个管理区目录没有对应的账号（共 N 个文件、N MB）。」，
        #    没有时是「没有无主的管理区目录。」。第一版这里猜的是
        #    「无主的管理区目录」—— 那句只在**空**态里出现，于是"有目录"
        #    这一支永远红，而红得像是功能没做。
        CK("① ★★ 无主目录那一段画出来了（renderUI 没会话就不求值）",
           "个管理区目录没有对应的账号" in txt or "没有无主的管理区目录" in txt,
           txt[-400:])
        CK("① ★★★ 种下的那个 u990001 被列出来了（还有几个文件、多大）",
           "u990001" in txt, txt[-400:] if "u990001" not in txt else "")

        # ---- ② 清掉它 -----------------------------------------------------
        pg.check("#admin-orphan_pick input[value='990001']")
        pg.click("button:has-text('清掉勾选的目录')")
        pg.wait_for_timeout(3000)
        CK("② ★★★ 盘上那个目录真的没了", not os.path.isdir(orphan), orphan)
        CK("② ★★ 名单里也没有它了（页面重画过）", "u990001" not in pg.inner_text("body"),
           # ⚠️ 失败时把"它还出现在哪儿"打出来 —— 否则只能看到一句"还在"，
           #    分不清是"没重画"还是"重画了、但别处还留着一份"。
           "\n".join(l.strip() for l in pg.inner_text("body").splitlines()
                     if "u990001" in l)[:300])

        # ---- ③ 造一个真账号（带文件）+ 从后台删掉它 ------------------------
        victim_email = "v166victim_%s@example.com" % C.TAG
        exec_sql("""INSERT INTO users
            (email, nickname, phone, field, pass_salt, pass_hash, created_at,
             is_admin, admin_scope, status)
            VALUES (?, '待删账号', '13700000000', '生信', 'salt1234',
                    'deadbeef', ?, 0, '', 'active')""",
                 (victim_email, "2026-10-05 10:00:00"))
        vid = sql("SELECT id FROM users WHERE email=?", (victim_email,))[0]["id"]
        vdir = os.path.join(FILES, "u%d" % vid)
        shutil.rmtree(vdir, ignore_errors=True)
        os.makedirs(vdir)
        with open(os.path.join(vdir, "mine.csv"), "w") as f:
            f.write("a,b\n9,9\n")
        exec_sql("INSERT OR REPLACE INTO file_owner (name, user_id, created_at)"
                 " VALUES (?,?,?)", ("u%d/mine.csv" % vid, vid,
                                     "2026-10-05 10:00:00"))
        CK("③ 前置：待删账号 + 他的文件都在",
           os.path.isfile(os.path.join(vdir, "mine.csv")))

        # ⚠️⚠️ 种完之后必须让**服务端**重查一遍，而且要**在搜索之前**做。
        #     `act()` 是一个 reactive（只依赖 refresh() / days()），而探针是
        #     拿 sqlite 直接写库的 —— 应用根本不知道多了一行。`C.goto()` 走的
        #     是 window.dsappNav()，那是**前端切页**（Shiny 会话不换），所以
        #     act() 交出来的还是缓存里那份（22 行），而库里已经有 23 个。
        #     症状极具误导性：「筛出 0 个（共 22 个）」—— 看着像"搜索坏了"，
        #     其实是"这一行压根还没进服务端那份名单"，而下面
        #     `tbody tr == 1` 那条还会因为空表占位行**恰好也是 1 行**而变绿。
        #
        #     换一个**新会话**（reload）来失效它。应用自己的那个刷新按钮
        #     （#htadmin-refresh）在「概览」那张卡上、属于另一个外层 tab，
        #     在「用户与权限」这一栏里是隐藏的，Playwright 点不到。
        relogin(pg, C.LAST_EMAIL)
        C.ensure_no_modal(pg)
        C.goto(pg, "admin")
        C.ensure_no_modal(pg)
        CK("③ 切到「用户与权限」栏", tab_click(pg, "users", "admin-bs_tab"))
        pg.wait_for_timeout(2000)
        # 判据现算：库里现在有几个账号，那一句「共 N 个」就得是几个。
        # 写死 23 的话，下次跑（又多一个号）它就红了，而红得毫无信息。
        n_db = sql("SELECT COUNT(*) AS n FROM users")[0]["n"]
        cnt0 = pg.inner_text("#htadmin-count").replace("\n", " ") if pg.locator(
            "#htadmin-count").count() else "(没有 #htadmin-count)"
        CK("③ 前置：新会话看到的账号数 == 库里现在的数（不是上一份缓存）",
           ("共 %d 个" % n_db) in cnt0, "库里 %d 个，页面说「%s」" % (n_db, cnt0))
        # ⚠️ 账号列表是一张 **DT 表**（`DT::renderDataTable(..., selection="single")`），
        #    不是带 radio 的普通表格 —— 第一版按"每行一个 input"去找，
        #    找不到就直接红在"点中了他"。
        #    这里先拿搜索框把他筛出来（表默认一页 15 行，账号一多他就不在第一页），
        #    再点那一行本身。DT 的选中是**行上的 click 事件**。
        pg.fill("#htadmin-kw", victim_email)
        pg.press("#htadmin-kw", "Enter")
        pg.wait_for_timeout(3000)
        # ⚠️ 读表要用 **textContent 或 #htadmin-count**，不能只看 innerText：
        #    这张 DT 出过错的时候是 `visibility: hidden`（htmlwidgets 的错误
        #    处理是 el.style.visibility="hidden"、旧 DOM 原样留着），而
        #    `innerText` 对 visibility:hidden 的元素返回**空串** —— 于是
        #    「表整张消失」和「表里没有这个人」在探针里长得一模一样。
        #    判据用服务端渲染的那句话（`筛出 N 个（共 M 个）`）+ textContent。
        cnt = pg.inner_text("#htadmin-count") if pg.locator(
            "#htadmin-count").count() else "(没有 #htadmin-count)"
        tbl_txt = pg.evaluate(
            "() => {const e=document.getElementById('htadmin-tbl');"
            "return e ? e.textContent : '(没有 #htadmin-tbl)'}")
        CK("③ 前置：搜索把待删账号筛出来了", victim_email in tbl_txt,
           "%s || 表里是：%s || 输入框=%r || Shiny 收到=%r" % (
               cnt.replace("\n", " "), tbl_txt.strip()[:200],
               pg.input_value("#htadmin-kw"),
               pg.evaluate(
                   "() => {const iv=window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues;"
                   "return iv ? iv['htadmin-kw'] : '(no shinyapp)'}")))
        CK("③ ★★ 服务端也认这个筛选（那句话是 renderUI 现算的，不是前端筛的）",
           "筛出 1 个" in cnt, cnt.replace("\n", " "))
        rows = pg.locator("#htadmin-tbl tbody tr")
        CK("③ 前置：筛完只剩一行（不然下面点的可能不是他）", rows.count() == 1,
           "筛出 %d 行" % rows.count())
        rows.first.click()
        pg.wait_for_timeout(1200)
        # DT 选中之后行上会带 .selected（拿它当"真的选中了"的判据，
        # 而不是"我点过了"）。
        CK("③ ★★ DT 那一行真的变成选中态（点没点着要看得见）",
           pg.locator("#htadmin-tbl tbody tr.selected").count() == 1)
        # ⚠️ 按 **id** 点，不要按文字点。`button:has-text('删除用户')` 在这
        #    一页上点不动弹窗（实测：说明文字点到了别的同文案按钮/别的位置），
        #    而报出来的是「等 #shiny-modal 超时」—— 指向弹窗，不指按钮。
        #    这一个是模块自己给的 id（`actionButton(ns("del"), "删除用户")`）。
        pg.click("#htadmin-del")
        pg.wait_for_selector("#shiny-modal:visible", timeout=10000)
        mtxt = pg.inner_text("#shiny-modal")
        CK("③ ★★★ 确认框里明说管理区会一并删除（不是旧那句「不会被删除」）",
           "一并删除" in mtxt and "不会被删除" not in mtxt, mtxt[:200])
        pg.click("#htadmin-confirm_del")
        pg.wait_for_timeout(4000)

        CK("④ ★★★ 账号行没了",
           not sql("SELECT 1 FROM users WHERE id=?", (vid,)))
        CK("④ ★★★ 盘上他那个管理区目录也没了（用户报的就是这一条）",
           not os.path.isdir(vdir), vdir)
        CK("④ ★★ 归属行也没了",
           not sql("SELECT 1 FROM file_owner WHERE user_id=?", (vid,)))
        CK("④ ★★ 界面回执里说清了清了几个文件",
           "个文件" in pg.inner_text("body"))
    finally:
        pg.screenshot(path=C.OUT + "/delacct_final.png", full_page=True)
        br.close()

CK.done()
