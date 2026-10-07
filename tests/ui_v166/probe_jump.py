# -*- coding: utf-8 -*-
"""V16.6 item 1：后台管理 →「信息同步」那一页真的能用吗。

跑法（实例先起好）：
    bash tests/ui_v7/make_instance.sh 8977 /tmp/dsapp_v166a
    python3 tests/ui_v166/probe_jump.py

这一版新增的一整页（后台管理 → 信息同步）。**自检里那一组只能验到
"卡片对象存在、源码里有那句话"** —— renderUI 的内容没有 Shiny 会话就求值
不到，所以下面这些必须由浏览器来回答：

  A. 那一格在不在、画出来没有（不是一片空白）
  B. 「允许同步建号」的开关在不在，默认**关**（这一条最要紧）
  C. 新增一条跳板 → 下拉里真的多了一条 + **回库对账**（界面说成功 ≠ 写进
     去了；本仓栽过"限流拒绝长得像界面坏了"）
  D. 设置页那个跳板下拉能看见刚加的那条，选了之后**地址栏被填上**，而
     **凭据栏一个字节都没动**
  E. 项目管理员看不到这一格

⚠️ 这个脚本**可以重复跑**（实例的库是复用的）：每次用带时间戳的名字，
   并且自己把当前账号提成平台管理员（"第一个注册的才是管理员"这条只在
   第一次跑的时候成立，第二次跑注册出来的是普通用户 —— 不提升的话下面
   会全红，而红的原因跟被测代码毫无关系）。
"""
import os
import sys
import sqlite3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

C.guard(C.APP)
CK = C.Chk()
NAME = "探针跳板" + C.TAG          # 每次跑都不一样，重复跑不会撞唯一索引
HOST = "jump-%s.example.com" % C.TAG
PORT = "2222"
DIR = "/srv/probe/data/sync"


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


def servers_in_db():
    return sql("SELECT id, name, host, port, remote_dir, enabled, is_default "
               "FROM sync_servers ORDER BY id")


def allow_in_db():
    r = sql("SELECT value FROM app_settings WHERE key=?",
            ("sync_allow_create",))
    return None if not r else r[0]["value"]


def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ⚠️ **不能**用 wait_awake()：它只认 `.dsapp-auth`，而 reload 时 cookie
      还在 —— 应用直接进主界面，登录页一帧都不出现，等它等于等一个永远
      不会来的东西（报出来是"120 秒还是空白页"，屏幕上的主界面早就好了）。
      所以等的是"两个可能里先到的那个"。
    """
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
    raise SystemExit("reload 之后回不到主界面（登录页也没出现）")


def tab_click(page, val, nav_id="admin-bs_tab"):
    """点子页签。按 data-value 点，不按文字 —— 文字是显示名，改了文案就
    点不着，而症状是"切过去还是原来那页"。

    ⚠️ 不切过去的话那一页的元素是 `display:none`，Playwright 报的是
      "element is not visible"（等 30 秒超时），而 `inner_text("body")`
      也**看不见**隐藏面板里的字 —— 于是断言红得像"功能没做"，其实只是
      没点那一栏。（V16.4 那个坑的同一族：藏着的 output 一次都不算。）
    """
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


def visible_pane_len(page):
    """当前可见的那个子页有内容吗（"切过去了"和"切过去是空的"要分开）。"""
    return page.evaluate("""() => {
        var ul = document.getElementById('admin-bs_tab');
        if (!ul) return -1;
        var panes = [].slice.call(
            ul.parentElement.querySelectorAll('.tab-pane'));
        var vis = panes.filter(p => p.classList.contains('active'));
        return vis.length === 1 ? vis[0].innerText.trim().length : -1;
    }""")


with sync_playwright() as pw:
    br = pw.chromium.launch()
    pg = br.new_page(viewport={"width": 1500, "height": 1000})
    try:
        email = C.enter_app(pg)
        uid, root = C.seed_or_die(email)
        # 提成平台管理员 —— 身份是 app.R 在**渲染那一刻**算的，老会话里还是
        # 旧身份，所以改完必须 reload。
        exec_sql("UPDATE users SET is_admin=1, admin_scope='platform' WHERE id=?",
                 (uid,))
        relogin(pg, C.LAST_EMAIL)
        C.ensure_no_modal(pg)
        print("uid =", uid, " data_root =", root,
              " email =", C.LAST_EMAIL, flush=True)

        # ---- A. 进后台管理 → 信息同步 -------------------------------------
        C.goto(pg, "admin")
        C.ensure_no_modal(pg)
        CK("A ★ 后台管理页上有「信息同步」这个子页签（按 data-value=sync 点得着）",
           tab_click(pg, "sync"))
        plen = visible_pane_len(pg)
        CK("A ★★ 切过去之后那一页**有内容**（不是切了个空白页）",
           plen > 20, "可见页文字数 = %s" % plen)
        txt = pg.inner_text("body")
        CK("A ★★ 画出来了「信息同步跳板」这张卡",
           "信息同步跳板" in txt)
        CK("A 有「新增跳板」按钮",
           pg.locator("button:has-text('新增跳板')").count() > 0)
        CK("A 五条动作按钮齐（改/默认/启停/删）",
           all(pg.locator("button:has-text('%s')" % t).count() > 0
               for t in ["修改", "设为默认", "启用 / 停用", "删除"]))

        # ---- B. 那个开关默认必须是关的 ------------------------------------
        CK("B ★★ 「允许同步建号」在页面上", "允许同步建号" in txt)
        CK("B ★★★ 库里默认没有把它打开（没设过 = 关，fail-closed）",
           allow_in_db() in (None, "0"), "app_settings=%r" % allow_in_db())
        cb = pg.locator("input#htadmin-sj_allow")
        if cb.count():
            CK("B ★★★ 画出来的勾是**没勾**的", not cb.is_checked())
        else:
            CK("B ★★ 开关被环境变量锁住时画的是徽章而不是勾",
               "被环境变量锁定" in txt)
        CK("B ★ 页面把开着的代价写出来了（删了它 = 让管理员不知情地点开）",
           "拿到校验器等于拿到密码" in txt)

        # ---- C. 新增一条跳板 → 界面 + 回库 ---------------------------------
        before = servers_in_db()
        pg.click("button:has-text('新增跳板')")
        pg.wait_for_selector("#shiny-modal:visible", timeout=10000)
        pg.fill("#htadmin-sj_f_name", NAME)
        pg.fill("#htadmin-sj_f_host", HOST)
        pg.fill("#htadmin-sj_f_port", PORT)
        pg.fill("#htadmin-sj_f_dir", DIR)
        pg.click("#htadmin-sj_save")   # 弹窗的确认键（不是"新增跳板"那个触发键）
        pg.wait_for_timeout(3500)
        after = servers_in_db()
        row = [r for r in after if r["name"] == NAME]
        CK("C ★★ 回库对账：库里真的多了一条（不只看提示条）",
           len(after) == len(before) + 1 and len(row) == 1,
           "before=%d after=%d 命中=%d" % (len(before), len(after), len(row)))
        CK("C 那条的地址/端口/目录逐字对", bool(row) and
           row[0]["host"] == HOST and row[0]["port"] == int(PORT) and
           row[0]["remote_dir"] == DIR, repr(row))
        CK("C ★ 默认位：全表恒有且仅有一条 is_default=1，且第一条才是它",
           sum(1 for r in after if r["is_default"] == 1) == 1 and
           (row[0]["is_default"] == 1) == (len(before) == 0),
           "before=%d default=%s" % (len(before), row[0]["is_default"] if row else "?"))
        pg.wait_for_timeout(1500)
        CK("C ★ 下拉里出现了它（不是「写进库了但页面不动」）",
           NAME in pg.inner_text("body"))

        # ---- C2. 非法地址要被挡住（而且**不许**进库）----------------------
        n0 = len(servers_in_db())
        pg.click("button:has-text('新增跳板')")
        pg.wait_for_selector("#shiny-modal:visible", timeout=10000)
        pg.fill("#htadmin-sj_f_name", NAME + "-非法")
        pg.fill("#htadmin-sj_f_host", "-oProxyCommand=curl evil")
        pg.click("#htadmin-sj_save")   # 弹窗的确认键（不是"新增跳板"那个触发键）
        pg.wait_for_timeout(2500)
        CK("C2 ★★ 选项注入的地址被拒，且**库里没有多出来**",
           len(servers_in_db()) == n0,
           "n0=%d now=%d" % (n0, len(servers_in_db())))
        CK("C2 拒绝的理由写在界面上（不能静默）",
           "非法字符" in pg.inner_text("body"))
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(1200)

        # ---- D. 设置页那个下拉 --------------------------------------------
        C.goto(pg, "settings")
        C.ensure_no_modal(pg)
        # 同步那张卡在「账号」那一栏里，不切过去的话它是 display:none
        CK("D 设置页切到「账号」栏", tab_click(pg, "account", "settings-tab"))
        pg.wait_for_timeout(2000)
        stxt = pg.inner_text("body")
        CK("D ★ 设置页有那个跳板下拉", pg.locator("select#settings-sync_pick").count() > 0)
        CK("D ★ 下拉里有刚加的那条（现读库，不是页面加载那一刻的快照）",
           NAME in stxt)
        # 先清空、再切到"不用跳板"（保证下一次选择是一次**变化**，
        # 否则 select 同一个值未必触发 observeEvent），然后选刚加的那条。
        pg.fill("#settings-sync_host", "")
        pg.fill("#settings-sync_port", "")
        pg.fill("#settings-sync_dir", "")
        pg.select_option("select#settings-sync_pick", value="")
        pg.wait_for_timeout(1200)
        CK("D 前置：清空之后地址栏确实是空的",
           pg.input_value("#settings-sync_host") == "")
        pg.select_option("select#settings-sync_pick", value=str(row[0]["id"]))
        pg.wait_for_timeout(2500)
        CK("D ★★ 选了之后地址栏被填上了",
           pg.input_value("#settings-sync_host") == HOST,
           repr(pg.input_value("#settings-sync_host")))
        CK("D ★★ 端口也填上了",
           pg.input_value("#settings-sync_port") == PORT,
           repr(pg.input_value("#settings-sync_port")))
        CK("D ★★ 目录也填上了",
           pg.input_value("#settings-sync_dir") == DIR,
           repr(pg.input_value("#settings-sync_dir")))
        # ★★★ 下面三条是这张卡存在的**前提**：清单只给地址，凭据永远自己填。
        CK("D ★★★ SSH 密码栏**仍然是空的**（凭据绝不从清单里来）",
           pg.input_value("#settings-sync_pw") == "",
           repr(pg.input_value("#settings-sync_pw")))
        CK("D ★★★ SSH 用户名栏**仍然是空的**",
           pg.input_value("#settings-sync_user") == "",
           repr(pg.input_value("#settings-sync_user")))
        CK("D ★★ 私钥栏也是空的",
           pg.input_value("#settings-sync_key") == "",
           repr(pg.input_value("#settings-sync_key")))

        # ---- E. 项目管理员看不到这一格 ------------------------------------
        exec_sql("UPDATE users SET is_admin=1, admin_scope='project' WHERE id=?",
                 (uid,))
        relogin(pg, C.LAST_EMAIL)
        C.ensure_no_modal(pg)
        C.goto(pg, "admin")
        C.ensure_no_modal(pg)
        etxt = pg.inner_text("body")
        CK("E ★★ 项目管理员的后台里**没有**「信息同步」这一格",
           "信息同步跳板" not in etxt)
        CK("E ★ 而且也没有那个子页签",
           not tab_click(pg, "sync"))
    finally:
        pg.screenshot(path=C.OUT + "/jump_final.png", full_page=True)
        br.close()

CK.done()
