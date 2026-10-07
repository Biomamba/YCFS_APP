# -*- coding: utf-8 -*-
"""V13.5 item 2 / 3 / 8：面板宽窄自定义 + 列表不换行。

    item 2、执行历史和任务详情的宽窄需要用户能自定义
    item 3、执行历史的列表每行不允许换行，如果过宽，请增加整个列表的滑动条。
            文件管理区的列表同理
    item 8、主菜单的宽度也需要能够让用户调整

★ 为什么这三条只能在这里验、selftest 验不了：

  1. 它们量的都是**浏览器算出来的几何**（`getBoundingClientRect`、
     `scrollWidth`）。CSS 写对了但被别的规则盖掉、或者 grid 的某一列把宽度
     吃掉，R 那边一条都看不出来。V13.5 item 8 的实现就是"绝对定位 + 直接子
     元素"这种**结构**上的要求，错了的表现是"拖了没反应"而不是报错。

  2. 「拖完刷新还在不在」是**一条链路**：浏览器报 → Shiny input →
     observeEvent → 写库 → 下次渲染写回 CSS 变量。中间断一环，看到的都是
     "当场是对的、刷新打回原形" —— 只有真的刷新一次才分得出来。

⚠️ 拖动用 `mouse.move` 分几步走，别一步到位：app.js 的 pointermove 里有
   `if (!drag) return`，而 drag 是 pointerdown 里设的。一步到位的 move 在
   headless 下**偶尔**会和 pointerdown 抢，表现为"拖了但没动"。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (APP, Chk, OUT, URL, enter_app, goto, seed_or_die)  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

C = Chk()

# 从 CSS 变量读当前宽度 —— 这是**唯一**的真相来源（app.js 只改这个变量，
# 元素的实际宽度由 CSS 算）。读元素宽度的话，页面窄的时候会被 grid 的
# min-width 卡住，量到的是"被卡住的值"，会和刚拖的值对不上。
VAR = ("(n) => parseFloat(getComputedStyle(document.documentElement)"
       ".getPropertyValue('--dsapp-' + n).trim()) || 0")


def var(page, name):
    return page.evaluate(VAR, name)


def seed_rows(uid, n=6):
    """往**这个实例的**库里直接塞几行任务记录，返回塞了几行。

    ★ 为什么要有这一步：item 3 要验的是「过宽就给整个列表加滑动条」。
      **空表上这条是恒真的** —— 没有行就没有单元格，`不换行` 和 `能滚`
      都成立，跑出来是绿的，而修复其实一行都没验到。2026-09-17 第一版就是
      这样：任务表只有 1 行（还是窄的），量出来 scrollW == clientW，
      报的是"窗口收窄之后没溢出" —— 看着像 CSS 写错了。

      所以这里塞的是**故意很长**的标题：长标题正是这条修复的全部意义所在
      （短内容本来就不换行、也不需要滚）。

    ⚠️ 直连 sqlite 而不是"真的跑一个任务"：跑任务要起 R 子进程、等它跑完，
      而且**跑出来的内容宽度不可控**。这里是**布局**测试，要的是可控的宽度。
    ⚠️ 只动 /tmp 下这份实例的库（`_common.guard()` 已经拦过一道，见它的
      说明），线上库一个字节都不碰。
    """
    import sqlite3
    from _common import db_path
    p = db_path()
    if p is None:
        return 0
    long_title = ("差异表达分析 —— 用 DESeq2 跑一遍 brca 全转录组的 "
                  "TP53 / BRCA1 / BRCA2 / MYC / KRAS 这一批基因并画火山图")
    con = sqlite3.connect(p)
    try:
        # ⚠️⚠️ `session_id` 必须指向一条**真的存在的会话行**。任务页的查询是
        #    `JOIN sessions s ON s.id = t.session_id`（不是 LEFT JOIN），
        #    会话行不存在的任务会被**静默丢掉** —— 2026-09-17 第一版就是这么
        #    写的（`session_id = 'v135-seed'`），塞进去 6 行、页面上还是 1 行，
        #    而库里 `SELECT COUNT(*)` 数得到 51 行。
        #    之所以是 JOIN 不是 LEFT JOIN：任务的归属只能从 sessions.user_id
        #    推出来，没有会话行就无从判断它是谁的（见 R/db.R 那段注释）。
        row = con.execute("SELECT id FROM sessions WHERE user_id = ? "
                          "ORDER BY updated_at DESC, id DESC LIMIT 1",
                          (uid,)).fetchone()
        if row is None:
            # 注册流程会建一个默认会话，正常不会走到这儿；真没有就自己建一个，
            # 否则下面插进去的任务一条都显示不出来。
            sid = "chat-v135seed-%d" % uid
            con.execute("INSERT INTO sessions (id, title, created_at,"
                        " updated_at, user_id) VALUES (?,?,?,?,?)",
                        (sid, "V13.5 布局测试", "2026-09-17 01:00:00",
                         "2026-09-17 01:00:00", uid))
        else:
            sid = row[0]
        for i in range(n):
            con.execute(
                "INSERT INTO tasks (session_id, title, lang, code, status,"
                " exit_code, stdout, stderr, workdir, created_at, started_at,"
                " finished_at, target) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, "%s（第 %d 次）" % (long_title, i + 1), "R",
                 "library(DESeq2)\n", "success", 0, "", "", "/tmp",
                 "2026-09-17 01:0%d:00" % i, "2026-09-17 01:0%d:01" % i,
                 "2026-09-17 01:0%d:30" % i, "local"))
        con.commit()
        return n
    finally:
        con.close()


def drag(page, sel, dx, dy=0, steps=8):
    """按住分隔条往 (dx, dy) 拖。返回拖前/拖后的 CSS 变量值由调用方读。"""
    h = page.locator(sel)
    h.scroll_into_view_if_needed()
    box = h.bounding_box()
    if box is None:
        return None
    cx = box["x"] + box["width"] / 2
    cy = box["y"] + box["height"] / 2
    page.mouse.move(cx, cy)
    page.mouse.down()
    for i in range(1, steps + 1):
        page.mouse.move(cx + dx * i / steps, cy + dy * i / steps)
        page.wait_for_timeout(30)
    page.mouse.up()
    page.wait_for_timeout(700)
    return box


with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: m.type == "error" and errors.append(m.text))

    email = enter_app(page)
    uid, _db = seed_or_die(email)

    # =====================================================================
    # item 8：主菜单宽度
    # =====================================================================
    goto(page, "chat")
    rail = page.locator("#split_m")
    C("★★ 主菜单那条分隔条在 DOM 里，而且挂着 data-dsapp-panel=menu_w",
      rail.count() == 1 and
      rail.get_attribute("data-dsapp-panel") == "menu_w",
      "count=%d attr=%s" % (rail.count(), rail.get_attribute("data-dsapp-panel")
                            if rail.count() else "-"))
    # ⚠️ 它必须是 .dsapp-shell 的**直接子元素**：shell 是两列的 grid，
    #    多一个孩子就多一列，主区会被挤到第三列去。
    C("★★ 它是 .dsapp-shell 的直接子元素（放进里面会多出一列，主区被挤走）",
      rail.evaluate("el => el.parentElement.classList.contains('dsapp-shell')"),
      rail.evaluate("el => el.parentElement.className"))

    before = var(page, "menu-w")
    drag(page, "#split_m", 60)
    after = var(page, "menu-w")
    C("★★ 往右拖主菜单变宽（左边那组：往右 = 变宽，和文件区相反）",
      after > before + 20, "%.0f → %.0f" % (before, after))

    # ★ 键盘那条路是**第二份**符号表（和 dragDelta 分开写的）。
    #   V13.5 加 tasks_w 时正是漏了这一处，症状是"鼠标拖对、按键反"。
    page.locator("#split_m").focus()
    k0 = var(page, "menu-w")
    page.keyboard.press("ArrowRight")
    page.wait_for_timeout(400)
    k1 = var(page, "menu-w")
    C("★★ 键盘右方向键也是变宽（和拖动同一套符号，不是反的）",
      k1 > k0, "%.0f → %.0f" % (k0, k1))
    page.keyboard.press("ArrowLeft")
    page.wait_for_timeout(400)
    C("★ 左方向键变窄", var(page, "menu-w") < k1,
      "%.0f → %.0f" % (k1, var(page, "menu-w")))

    # ★ 刷一次才知道有没有真的写进库。report() 靠 id 形状算 input 名
    #   （`split_m` → `panel_size`），正则里少一个 m 的表现就是这里打回原形。
    kept = var(page, "menu-w")
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-shell", timeout=60000)
    page.wait_for_timeout(2500)
    C("★★ 刷新之后宽度还在（不在 = 压根没上报到服务端，而控制台不会报错）",
      abs(var(page, "menu-w") - kept) < 2,
      "刷新前 %.0f、刷新后 %.0f" % (kept, var(page, "menu-w")))

    # =====================================================================
    # item 2：执行历史 / 任务详情那条分隔条
    # =====================================================================
    goto(page, "tasks")
    th = page.locator("#tasks-split_t")
    C("★★ 执行历史那条分隔条在，data-dsapp-panel=tasks_w",
      th.count() == 1 and th.get_attribute("data-dsapp-panel") == "tasks_w",
      "count=%d" % th.count())
    tb = var(page, "tasks-w")
    drag(page, "#tasks-split_t", 70)
    ta = var(page, "tasks-w")
    C("★★ 往右拖执行历史变宽",
      ta > tb + 20, "%.0f → %.0f" % (tb, ta))
    page.locator("#tasks-split_t").focus()
    page.keyboard.press("ArrowRight")
    page.wait_for_timeout(400)
    C("★★ 键盘右方向键同样是变宽（V13.5 就漏过这一处，症状是「拖对、按键反」）",
      var(page, "tasks-w") > ta, "%.0f → %.0f" % (ta, var(page, "tasks-w")))

    # ⚠️ 执行历史宽了，任务详情那一栏就得**跟着窄** —— 它俩是同一条 grid 的
    #    两列。只验左边变宽的话，"两列一起变宽把卡片顶破"这种错法看不出来。
    det = page.evaluate(
        "() => { var e = document.querySelector('.dsapp-task-detail');"
        " return e ? e.getBoundingClientRect().width : -1; }")
    C("★ 任务详情那一栏跟着让位（同一条 grid 的两列）", 0 < det < 1600,
      "detail=%.0f" % det)

    # =====================================================================
    # item 3：列表不换行 + 横向滚动条
    # =====================================================================
    def table_geom(page, sel):
        # ⚠️⚠️ 必须挑**看得见的**那一个，不能 `querySelector`（取第一个）。
        #    任务页和文件页是 bslib 的 navset，**两页的表都在 DOM 里**，
        #    不活跃的那页只是 display:none。任务页排在前面，所以在文件页上
        #    `querySelector('.dsapp-dt-nowrap')` 拿到的是**藏起来的任务表**：
        #    每格高度都是 0 → 走 `r.height <= 0 → continue` → 报出来
        #    rows=0、scrollW=0、clientW=0，看着像"文件管理区是空的"。
        #    2026-09-17 就是这么白跑一轮的（同一个坑 files.py 也踩了，
        #    它报的"行数 1"其实是藏着的任务表里那一行）。
        #    判据用宽度 > 0：display:none 的元素宽度是 0。
        return page.evaluate(
            "(s) => { var all = document.querySelectorAll(s), w = null;"
            " for (var i = 0; i < all.length; i++) {"
            "   if (all[i].getBoundingClientRect().width > 0) { w = all[i]; break; } }"
            " if (!w) return null;"
            " var t = w.querySelector('table.dataTable'); if (!t) return null;"
            " var th = t.querySelectorAll('tbody td');"
            " var one = 0, two = 0;"
            " for (var i = 0; i < th.length; i++) {"
            "   var r = th[i].getBoundingClientRect();"
            "   if (r.height <= 0) continue;"
            "   var cs = getComputedStyle(th[i]);"
            "   var lh = parseFloat(cs.lineHeight) || 0;"
            "   var pad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);"
            "   if (lh > 0 && r.height > lh + pad + 4) two++;"
            "   one++;"
            " }"
            " return { rows: one, wrapped: two,"
            "   scrollW: w.scrollWidth, clientW: w.clientWidth,"
            "   overX: getComputedStyle(w).overflowX,"
            "   tableW: t.getBoundingClientRect().width }; }", sel)

    # ⚠️⚠️ 下面那几条在**一张空表**上是恒真的：没有行就没有单元格，
    #    `wrapped == 0` 和 `overflow-x: auto` 都成立，而"不换行"根本没被验到。
    #    2026-09-17 第一版就是这样：任务表只有 1 行、文件表 0 行，一条红一条
    #    **假绿**（红的那条报的是"窗口收窄之后没溢出"，看着像 CSS 写错了）。
    #    所以先往实例的库里塞几行**故意很长**的记录，再量 —— 长标题正是这条
    #    修复的全部意义所在（短内容本来就不换行、也不需要滚）。
    n_seed = seed_rows(uid)
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-shell", timeout=60000)
    goto(page, "tasks")
    page.wait_for_timeout(2000)

    g = table_geom(page, ".dsapp-dt-nowrap")
    C("（前置）塞了 %d 行之后表里真的有行（空表上下面几条是恒真的）" % n_seed,
      g is not None and g["rows"] >= n_seed, "geom=%s" % (g,))
    if g:
        C("★★ 每一行都不换行 —— 用**故意很长**的标题量（长标题是这条修复的"
          "全部意义所在）",
          g["wrapped"] == 0, "换行单元格 %d / %d" % (g["wrapped"], g["rows"]))
        # ★ 用户原话是「如果过宽，请增加整个列表的滑动条」。所以有两种都对：
        #   内容比容器宽 → 能滚；内容比容器窄 → 不滚也行。**错的是**
        #   "内容宽了却撑破卡片"（overflow-x 不是 auto）和"内容宽了却挤成一团"
        #   （被 DT 的 width:100% 钉死）。这里两条一起判。
        C("★★ 内容比容器宽时容器真的能滚（scrollWidth > clientWidth）",
          g["scrollW"] > g["clientW"] + 4 and g["overX"] == "auto",
          "scrollW=%.0f clientW=%.0f overflow-x=%s"
          % (g["scrollW"], g["clientW"], g["overX"]))
        C("★ 表格没有被钉死在容器宽度上（width: auto；钉死的话列被压窄、"
          "文字糊到隔壁，永远不溢出）",
          g["tableW"] >= g["clientW"] - 1,
          "table=%.0f client=%.0f" % (g["tableW"], g["clientW"]))

    # 文件管理区同理 —— 用户原话「文件管理区的列表同理」。
    # ⚠️ 先传两个**长文件名**，否则这张表是空的，下面那条又是恒真。
    goto(page, "files")
    for nm in ("v135_%s_a_very_long_file_name_for_the_nowrap_check.txt" % uid,
               "v135_%s_another_extremely_long_name_to_force_overflow.txt" % uid):
        # ⚠️ 具体的 id，不是 `input[type=file]` —— 这一页有两个 file input，
        #    选择器匹配到多个时**上传静默不发生**，见 files.py 里那段说明。
        page.set_input_files("#files-upload",
                             {"name": nm, "mimeType": "text/plain",
                              "buffer": b"x\n"})
        page.wait_for_timeout(2500)
    page.wait_for_timeout(1500)

    gf = table_geom(page, ".dsapp-dt-nowrap")
    C("（前置）文件管理区那张表也量到了（空表上下面那条是恒真的）",
      gf is not None and gf["rows"] >= 2, "geom=%s" % (gf,))
    if gf:
        C("★★ 文件管理区同样一行不换行 + 横向可滚",
          gf["wrapped"] == 0 and gf["overX"] == "auto",
          "换行 %d / %d，overflow-x=%s"
          % (gf["wrapped"], gf["rows"], gf["overX"]))
    page.set_viewport_size({"width": 1600, "height": 1000})
    page.wait_for_timeout(700)

    C("★★ 整场没有 JS 报错（控制台红了说明上面某条是「碰巧看着对」）",
      not errors, "\n".join(errors[:4]))
    page.screenshot(path=OUT + "/layout.png", full_page=True)
    b.close()

sys.exit(C.done())
