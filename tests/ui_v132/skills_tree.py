# -*- coding: utf-8 -*-
"""V13.2 item 11 / 12 / 13：技能列表的文件夹形态、多选、排序与拖拽。

用户的原话：
  item 11「skills界面只能打开看到文字，建议以文件夹的形式，这样能展示
           skills的更多内置文件信息」
  item 12「skills选择界面建议支持多选」
  item 13「skills需要能够支持按照名称、时间等信息进行排序，并且可以拖拽
           自定义顺序」

★ item 12 在 V13.1 里**看起来**已经支持了（那个弹窗用的是
  checkboxGroupInput，源码上就是多选）。但"源码上是多选"和"用户勾了三条
  真的挂上三条"是两回事 —— 勾选值怎么送到服务端、服务端怎么存，中间任何
  一环只认一个值，用户看到的就是"选了一个另一个就掉了"。所以这里**实测**：
  勾三条、应用、数徽章。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

ROW = ".dsapp-skill-list > .dsapp-skill-row"


def rows_of(page):
    """当前屏幕上从上到下的技能名。"""
    return page.evaluate("""() => Array.from(
        document.querySelectorAll('.dsapp-skill-list > .dsapp-skill-row'))
        .map(r => { const n = r.querySelector('.dsapp-skill-name');
                    return n ? n.innerText.trim() : null; })
        .filter(Boolean)""")


def ids_of(page):
    return page.evaluate("""() => Array.from(
        document.querySelectorAll('.dsapp-skill-list > .dsapp-skill-row'))
        .map(r => { const h = r.querySelector('.dsapp-skill-drag');
                    return h ? h.getAttribute('data-id') : null; })
        .filter(Boolean)""")


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        page = br.new_page(viewport={"width": 1500, "height": 950})
        email = enter_app(page)
        uid, dbp = seed_or_die(email)
        print("  账号 uid=%s  db=%s" % (uid, dbp))

        # 建三条自己的技能（内容各不相同，好认）
        import sqlite3
        con = sqlite3.connect(dbp)
        now = "2026-09-16 20:00"
        for nm, sm in (("甲技能", "第一条"), ("乙技能", "第二条"), ("丙技能", "第三条")):
            con.execute(
                "INSERT INTO skills (user_id, name, summary, body, tags, builtin,"
                " source, created_at, updated_at) VALUES (?,?,?,?,?,0,'manual',?,?)",
                (uid, nm, sm,
                 "# %s\n\n## 甲节\n正文\n\n## 乙节\n更多正文\n" % nm,
                 "自检", now, now))
        con.commit()
        con.close()

        goto(page, "skills", wait=3500)

        # ---- 0. 前提 ----
        names0 = rows_of(page)
        chk("★ 前提：技能列表渲染出来了（内置那批 + 刚建的三条）",
            len(names0) >= 4 and "甲技能" in names0, names0)
        chk("★ 每条技能都有一个「文件夹」（<details>），不是一行纯文字",
            page.locator(".dsapp-skill-list details.dsapp-skillgroup").count()
            == page.locator(ROW).count())

        # ---- 1. item 11：展开看到的是"文件信息" ----
        row = page.locator(ROW, has_text="甲技能").first
        det = row.locator("details.dsapp-skillgroup")
        chk("★ 刚打开时是收起的（一屏能看到全部技能，而不是被详情撑开）",
            det.evaluate("d => d.open") is False)

        row.locator("summary").click()
        page.wait_for_timeout(600)
        chk("★★ 点一下标题就展开了（<details> 原生，不依赖 JS）",
            det.evaluate("d => d.open") is True)

        files = row.locator(".dsapp-skill-file")
        labels = row.locator(".dsapp-skill-file-k").all_inner_texts()
        chk("★★ 展开之后列的是这个技能**自己的**文件信息，不是一句废话",
            files.count() >= 3 and "正文" in labels and "目录" in labels
            and "时间" in labels, labels)
        vals = row.locator(".dsapp-skill-file-v").all_inner_texts()
        chk("★★ 正文那行带字数和节数（50 KB 的长文在列表上要是只写个名字，"
            "用户没法判断里面讲没讲他要的那件事）",
            any("字" in v and "节" in v for v in vals), vals)
        chk("★★ 目录那行是这个技能的各节标题（来自正文的 ## 小节）",
            any("甲节" in v and "乙节" in v for v in vals), vals)

        # 内置那条要有"从哪个 .md 来的 / 上游仓库 / 许可"
        b = page.locator(ROW, has_text="学术论文写作与同行评审").first
        if b.count() == 0:
            b = page.locator(ROW).filter(has_text="内置").first
        b.locator("summary").click()
        page.wait_for_timeout(600)
        bvals = b.locator(".dsapp-skill-file-v").all_inner_texts()
        chk("★★★ 内置技能展开后能看到它的 .md 文件名和上游仓库/许可"
            "（这些都不在库里，是现从 skills_builtin/ 查的）",
            any(".md" in v for v in bvals) and
            any("/" in v and "·" in v for v in bvals), bvals)

        # ---- 2. 展开状态在重画之后还在 ----
        #
        # ⚠️ 这一条防的是"存一条技能 / 换个排序之后，用户刚展开的那一条
        #    连同里面的信息一起塌回去" —— 和产物分组踩过的是同一个坑。
        page.locator("#skills-q").fill("技能")
        page.wait_for_timeout(1200)
        page.locator("#skills-q").fill("")
        page.wait_for_timeout(1500)
        still = page.locator(ROW, has_text="甲技能").first.locator(
            "details.dsapp-skillgroup").evaluate("d => d.open")
        chk("★★ 搜索过滤再清空之后，刚展开的那条还是展开的",
            still is True, still)

        # ---- 3. item 13：排序 ----
        # ⚠️ 比的是**整串**而不是"首个元素变了没"：自定义顺序里内置技能
        #    本来就排在前面（builtin DESC），而内置那批的名字里有
        #    "Excalidraw…"「Nature…」这种以 ASCII 开头的，按名称排也在前面 ——
        #    首位恰好可以是同一条，拿首元素当判据会假红。
        cust_ids = ids_of(page)
        page.select_option("#skills-sk_sort", "name")
        page.wait_for_timeout(2000)
        names_n = rows_of(page)
        chk("★★ 选「按名称」之后列表真的按名称排了",
            names_n == sorted(names_n), names_n[:5])
        chk("★ 而且顺序和「自定义」时不一样（不是选了什么都没发生）",
            ids_of(page) != cust_ids,
            "%s → %s" % (cust_ids[:5], ids_of(page)[:5]))
        # ⚠️ 旁边那句"按住 ⠿ 拖动"只在自定义时才成立。它和方向按钮一样，
        #    是**当前排法的函数** —— 写死一次不重画的话，用户切到「名称」
        #    之后它还挂在那儿教人去拖一个已经拖不动的列表。
        row_txt = page.inner_text(".dsapp-page .card-body")
        chk("★★ 切到「名称」之后，「按住 ⠿ 拖动」那句提示跟着消失了",
            "拖动可以自己排顺序" not in row_txt)

        page.click("#skills-sk_dir")
        page.wait_for_timeout(2000)
        names_d = rows_of(page)
        chk("★★ 点一下方向按钮 → 倒过来",
            names_d == sorted(names_d, reverse=True), names_d[:5])

        page.select_option("#skills-sk_sort", "updated")
        page.wait_for_timeout(1800)
        chk("★ 「最近修改」不抛、条数不变", len(rows_of(page)) == len(names_n))

        # 刷新之后排序选择还在（存的是账号偏好，不是浏览器上的一个临时值）
        page.reload(wait_until="domcontentloaded")
        page.wait_for_selector(".dsapp-shell", timeout=60000)
        page.wait_for_timeout(3500)
        goto(page, "skills", wait=2500)
        chk("★★ 刷新之后仍然是「最近修改」倒序（排序是按账号存下来的）",
            page.eval_on_selector("#skills-sk_sort", "e => e.value") == "updated",
            page.eval_on_selector("#skills-sk_sort", "e => e.value"))

        # ---- 4. item 13：拖拽 ----
        page.select_option("#skills-sk_sort", "custom")
        page.wait_for_timeout(2500)
        # ⚠️ 走到这里 desc 还是 TRUE（上面点过一次方向按钮）。切到自定义时
        #    要把它复位 —— 否则「方向」这个按钮一边被置灰、一边顶着个
        #    「↓ 倒序」，和眼前这份拖出来的顺序没有半点关系。
        dir_txt = page.inner_text("#skills-sk_dir")
        chk("★★ 切回自定义之后方向按钮不再顶着「↓ 倒序」（自定义没有正倒序）",
            "倒序" not in dir_txt, dir_txt)
        order0 = ids_of(page)
        chk("★ 切回自定义之后可以拖（手柄是 draggable 的）",
            page.locator(".dsapp-skill-drag[draggable='true']").count() == len(order0),
            "%d 个手柄 / %d 行" % (
                page.locator(".dsapp-skill-drag[draggable='true']").count(),
                len(order0)))

        # ★ 真拖：把第二行拖到第一行的位置。
        #
        # ⚠️ 别用 mouse.down/move/up 硬凑 —— HTML5 的 drag 事件由浏览器自己
        #    合成，直接挪鼠标不产生 dragstart。drag_to() 才是那条路。
        #
        # ⚠️⚠️ 源和目标**必须都在当前视口里同时看得见**。
        #    Playwright 的 drag_to() 会先给源元素 scrollIntoView、量一次坐标，
        #    再给目标元素 scrollIntoView、又量一次。目标是列表第一行时，第二次
        #    滚动把容器拉回顶部，而鼠标还按着第一次量出来的坐标 —— 于是**按下
        #    的是别的行**。2026-09-16 实测：拖最后一行（id 19）到第一行，动的
        #    却是第 6 行（id 12），报上来的顺序是"12 跑到第一、19 原地没动"，
        #    看起来像服务端把 id 认错了，其实是测试自己按错了地方。
        #    挑相邻的两行就没有这个位移。
        #
        # ⚠️ "拖的是哪一条"要**现从 DOM 上读**，不能拿 order0 的快照当答案：
        #    存排序偏好会 bump 计数器 → list_ui 重画，快照随时可能过期。
        src = page.locator(ROW).nth(1).locator(".dsapp-skill-drag")
        src_id = src.get_attribute("data-id")
        src.drag_to(page.locator(ROW).first)
        page.wait_for_timeout(2500)
        order1 = ids_of(page)
        chk("★★★ 往上拖一行 → 它到了第一位，而且一条不多一条不少",
            bool(order1) and order1[0] == src_id
            and sorted(order1) == sorted(order0),
            "%s → %s（拖的是 %s）" % (order0[:4], order1[:4], src_id))

        # 反过来往下拖一次：上面那条走的是"插到目标前面"那一支，这一条走
        # "插到目标后面"。两支都在 app.js 里，只测一支等于没测另一半。
        src2 = page.locator(ROW).first.locator(".dsapp-skill-drag")
        src2_id = src2.get_attribute("data-id")
        src2.drag_to(page.locator(ROW).nth(2))
        page.wait_for_timeout(2500)
        order2 = ids_of(page)
        chk("★★★ 往下拖一行 → 它确实往下挪了，而且一条不多一条不少",
            bool(order2) and order2.index(src2_id) > 0
            and sorted(order2) == sorted(order1),
            "%s → %s（拖的是 %s）" % (order1[:4], order2[:4], src2_id))
        order1 = order2     # 后面断言"刷新之后还在"用的是最后这一份

        page.reload(wait_until="domcontentloaded")
        page.wait_for_selector(".dsapp-shell", timeout=60000)
        page.wait_for_timeout(3500)
        goto(page, "skills", wait=2500)
        chk("★★★ 刷新之后拖出来的顺序还在（存到了服务端）",
            ids_of(page) == order1,
            "%s → %s" % (order1[:3], ids_of(page)[:3]))

        # 键盘那条路：聚焦手柄，上方向键挪一格
        page.locator(ROW).nth(1).locator(".dsapp-skill-drag").focus()
        page.wait_for_timeout(300)
        second_id = ids_of(page)[1]
        page.keyboard.press("ArrowUp")
        page.wait_for_timeout(2000)
        chk("★★ 键盘：焦点在手柄上按上方向键 → 这一行往上挪了一格",
            ids_of(page)[0] == second_id,
            "%s / 期望首位 %s" % (ids_of(page)[:2], second_id))

        # 搜索时不给拖（报了也只是个子集，会把没显示的挤出名次）
        page.locator("#skills-q").fill("技能")
        page.wait_for_timeout(1500)
        chk("★★ 搜索框里有字时手柄置灰、不给拖（否则会把没显示的那些挤出名次）",
            page.locator(".dsapp-skill-drag[draggable='true']").count() == 0 and
            page.locator(".dsapp-skill-drag.is-off").count() > 0)
        page.locator("#skills-q").fill("")
        page.wait_for_timeout(1500)

        # ---- 5. item 12：多选（实测，不是看源码）----
        goto(page, "chat", wait=3000)
        # ⚠️ 没有对话的时候技能条是灰的（"新建对话后可挂载"）—— 必须先建一个。
        page.click("#chat-new_chat")
        page.wait_for_timeout(3500)
        page.click("#chat-skill_pick")
        page.wait_for_timeout(1500)
        boxes = page.locator("#chat-skill_sel input[type='checkbox']")
        chk("★★ 技能选择弹窗里是**复选框**（不是单选）", boxes.count() >= 3,
            boxes.count())
        for i in (0, 1, 2):
            boxes.nth(i).check()
            page.wait_for_timeout(200)
        checked = page.locator("#chat-skill_sel input[type='checkbox']:checked").count()
        chk("★★ 勾三个，三个都保持勾上（勾一个掉一个是这类控件最常见的坏法）",
            checked == 3, checked)
        page.click("#chat-skill_apply")
        page.wait_for_timeout(2500)
        chips = page.locator(".dsapp-skill-chip").count()
        chk("★★★ 应用之后，这个对话上挂了 3 条（徽章数对得上）", chips == 3, chips)

        page.reload(wait_until="domcontentloaded")
        page.wait_for_selector(".dsapp-shell", timeout=60000)
        page.wait_for_timeout(4000)
        goto(page, "chat", wait=3000)
        chk("★★ 刷新之后还是 3 条（不是只挂在浏览器上）",
            page.locator(".dsapp-skill-chip").count() == 3,
            page.locator(".dsapp-skill-chip").count())

        goto(page, "skills", wait=2500)
        page.screenshot(path=OUT + "/skills_tree.png", full_page=True)
        br.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
