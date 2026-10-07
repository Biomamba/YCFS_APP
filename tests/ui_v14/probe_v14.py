# -*- coding: utf-8 -*-
"""Test_V14 的浏览器验收（item 1 / 4 / 5 / 6 / 7）。

    bash tests/ui_v7/make_instance.sh 8917 /tmp/dsapp_v14
    python3 tests/ui_v14/probe_v14.py            # 退出码 0 = 全绿

⚠️ 这一版**不需要假模型**：下面每一条量的都是界面本身，一次模型调用都不发。

为什么自检（`Rscript selftest.R`，2748 条）证过了还要再跑一遍浏览器：

  · item 1 的核心是**拖**。自检只能证明 SPEC 里有 filespage_w、CSS 变量名对得上、
    report() 的后缀字母含 f。它证明不了"按住那条把手往右拉，左边那一栏真的变宽了" ——
    而这中间隔着 pointerdown/pointermove/setPointerCapture 一整套，任何一环断了
    都是**把手还在、拖不动、控制台干净**。
  · item 5 的量是"库里到底种进去几条"。自检能证明三个 SKILL.md 解析得出来，
    证明不了 seed 真的把它们种进了**这个实例的**库、列表真的渲染了出来。
  · item 6 是纯文案：唯一能验的就是"页面上那一刻显示的是哪几个字"。
  · item 7 的界面在**弹窗**里，而弹窗是点出来的。自检能证明源码里有
    radioButtons(ns("lim_gpu"))，证明不了点开之后它真的在那儿、选项真的是三个。
  · item 4 的验收面是 iframe 里那张图**加载出来了没有** —— 只有浏览器知道
    `naturalWidth > 0`。源码级断言最多能证到"内联函数在预览这条路上被调了"。
"""
import io
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

ck = C.Chk()
if os.path.exists(C.OUT):
    for f in os.listdir(C.OUT):
        if f.endswith(".png"):
            os.unlink(os.path.join(C.OUT, f))


def vis(pg, sel):
    """元素可见时返回它的 box，否则 None。

    ⚠️ 一律走这个，不直接 `locator.bounding_box()`：隐藏元素的矩形是**全 0**
    （memory: hidden-element-has-zero-rect），拿它做减法得到的数看着完全合理。
    更糟的是 locator 不存在时 bounding_box() 抛异常，一炸后面整段都"没跑到"。
    """
    try:
        el = pg.locator(sel).first
        if el.count() == 0 or not el.is_visible():
            return None
        return el.bounding_box()
    except Exception:
        return None


def txt(pg, sel):
    try:
        el = pg.locator(sel).first
        return el.inner_text() if el.count() else ""
    except Exception:
        return ""


def _settings_pane(pg):
    """**当前可见的**设置页 pane 的文字。

    ⚠️ 不能量整个 body：bslib 把没选中的 nav_panel 也留在 DOM 里（只藏不激活），
    所以 body 里混着另外三栏的内容，也混着**别的页**的内容。扫整个 body 会
    量到别人的字 —— 断"页面上没有「当前服务器」"时尤其致命：只要任何一页
    留着这五个字，这一条就永远红；反过来断"有某句话"时又可能被别的页蒙混过去。
    """
    try:
        return pg.evaluate("""() => {
          const ps = document.querySelectorAll('.dsapp-page .tab-pane, .dsapp-page .tab-content > div');
          let out = '';
          for (const p of ps) {
            if (p.offsetParent === null && getComputedStyle(p).position !== 'fixed') continue;
            if (!p.innerText) continue;
            out += p.innerText + '\\n';
          }
          return out;
        }""") or ""
    except Exception:
        return ""


# =============================================================================
# item 1：文件管理区 ↔ 预览 之间可以拖着改宽
# =============================================================================
def item01(pg):
    print("\n== item 1：文件页的拖动改宽 ==", flush=True)
    C.goto(pg, "files")
    pg.wait_for_timeout(1500)

    lst = vis(pg, ".dsapp-files-list")
    ck("★★ 文件页画出了 .dsapp-files-list（文件管理区那一栏）", lst is not None)
    if lst is None:
        return
    handle = vis(pg, "#files-split_f")
    ck("★★ 中间那条把手 #files-split_f 在（不是 .dsapp-files-col 那条）",
       handle is not None, "拿到的是 %s" % handle)
    if handle is None:
        return
    ck("★★ 把手在管理区**右边**、预览区**左边**（放错边 = 拖反）",
       handle["x"] >= lst["x"] + lst["width"] - 4 and
       handle["width"] <= 24,
       "list 右缘 %.0f，把手 x %.0f w %.0f"
       % (lst["x"] + lst["width"], handle["x"], handle["width"]))

    prev = vis(pg, ".dsapp-files-prev")
    ck("★★ 预览区在（右半边）", prev is not None)
    ck("★★★ 两栏并排、不重叠（flex 布局真的生效了，不是叠在一起）",
       prev is not None and prev["x"] >= lst["x"] + lst["width"] - 2,
       "list 右缘 %.0f，prev x %.0f"
       % (lst["x"] + lst["width"], prev["x"] if prev else -1))

    w0 = lst["width"]
    # ⚠️ 拖之前先滚进视口（memory: playwright-drag-below-the-fold）：
    #    元素在视口外时 mouse 事件**无人接收**，而 bounding_box() 照样返回
    #    正数、全程不报错。症状是"第一次拖不动、第二次又能动"。
    pg.locator("#files-split_f").first.scroll_into_view_if_needed()
    pg.wait_for_timeout(300)
    b = vis(pg, "#files-split_f")
    cx, cy = b["x"] + b["width"] / 2.0, b["y"] + min(30, b["height"] / 2.0)
    pg.mouse.move(cx, cy)
    pg.mouse.down()
    for k in range(1, 13):
        pg.mouse.move(cx + 120.0 * k / 12.0, cy)
        pg.wait_for_timeout(30)
    pg.mouse.up()
    pg.wait_for_timeout(1200)

    lst2 = vis(pg, ".dsapp-files-list")
    ck("★★★ 往右拖 120px 之后管理区**真的变宽了**（拖得动）",
       lst2 is not None and lst2["width"] > w0 + 60,
       "拖前 %.0f → 拖后 %.0f" % (w0, lst2["width"] if lst2 else -1))

    # ★ 双击复位。这条不能省：只断"能拖宽"的话，一个把宽度永久钉住的实现
    #   照样全绿，而用户会发现回不去了。
    pg.locator("#files-split_f").first.dblclick()
    pg.wait_for_timeout(1200)
    lst3 = vis(pg, ".dsapp-files-list")
    ck("★★ 双击把手恢复默认宽度（420 上下）",
       lst3 is not None and abs(lst3["width"] - 420) <= 24,
       "双击后 %.0f" % (lst3["width"] if lst3 else -1))

    # ★★ 存储：刷新之后还是拖过的那一档宽度。只断"当场变宽"的话，写库那一步
    #    断了也全绿 —— 而用户的抱怨恰恰是"改了下一次进来又回去了"。
    w_drag = lst2["width"] if lst2 else w0
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=40000)
    pg.wait_for_timeout(2500)
    C.goto(pg, "files")
    pg.wait_for_timeout(1500)
    # 双击复位过，所以这里回到默认才是对的 —— 断的是"存的是**复位后**的值"
    lst4 = vis(pg, ".dsapp-files-list")
    ck("★ 刷新之后宽度仍然记得住（默认位）",
       lst4 is not None and abs(lst4["width"] - 420) <= 30,
       "刷新后 %.0f" % (lst4["width"] if lst4 else -1))
    # 再拖一次，然后刷新，这次要记住"宽"的那一档
    if lst4 is not None:
        b = vis(pg, "#files-split_f")
        cx, cy = b["x"] + b["width"] / 2.0, b["y"] + min(30, b["height"] / 2.0)
        pg.mouse.move(cx, cy); pg.mouse.down()
        for k in range(1, 9):
            pg.mouse.move(cx + 90.0 * k / 8.0, cy)
            pg.wait_for_timeout(30)
        pg.mouse.up()
        pg.wait_for_timeout(1200)
        w_saved = (vis(pg, ".dsapp-files-list") or {}).get("width", 0)
        pg.reload(wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-shell", timeout=40000)
        pg.wait_for_timeout(2500)
        C.goto(pg, "files")
        pg.wait_for_timeout(1500)
        w_back = (vis(pg, ".dsapp-files-list") or {}).get("width", 0)
        ck("★★★ 拖完之后刷新，宽度还是拖过的那一档（写进 uipref 了）",
           w_saved > 460 and abs(w_back - w_saved) <= 24,
           "拖后 %.0f → 刷新后 %.0f" % (w_saved, w_back))
        # 复位，别把宽度留给后面的断言
        pg.locator("#files-split_f").first.dblclick()
        pg.wait_for_timeout(1000)


# =============================================================================
# item 4：报告预览里的图片不裂
# =============================================================================
def item04(pg):
    print("\n== item 4：HTML 预览里的图片 ==", flush=True)

    # 造一份**故意用相对路径引图**的 HTML —— 这正是"生成出来的报告"的样子，
    # 也正是原来裂图的那种。把图和 HTML 一起丢进实例的文件管理区。
    png = _tiny_png()
    src = os.path.join(C.OUT, "v14_upload")
    os.makedirs(src, exist_ok=True)
    with io.open(os.path.join(src, "shot.png"), "wb") as f:
        f.write(png)
    with io.open(os.path.join(src, "report.html"), "w", encoding="utf-8") as f:
        f.write(u"<!doctype html><html><head><meta charset='utf-8'>"
                u"<title>t</title></head><body><h1>图</h1>"
                u"<img src='shot.png' id='theimg'>"
                u"<img src='missing.png' id='gone'>"
                u"</body></html>")

    C.goto(pg, "files")
    pg.wait_for_timeout(1200)
    _upload(pg, src)
    pg.wait_for_timeout(2500)

    # 在文件列表里点 report.html 预览
    row = pg.locator("text=report.html").first
    ck("★★ 上传的 report.html 出现在文件管理区里", row.count() > 0)
    if row.count() == 0:
        return
    row.click()
    pg.wait_for_timeout(1500)
    # 预览可能是"点一下看"的链接
    for sel in ("text=预览", "text=看", "text=打开"):
        lk = pg.locator(sel).first
        if lk.count() and lk.is_visible():
            lk.click()
            pg.wait_for_timeout(2500)
            break
    pg.wait_for_timeout(2500)

    # ⚠️ 不用 `locator.content_frame()` —— 这个版本里它是**属性**且返回的是
    #    FrameLocator（不是 Frame），写成 `f.content_frame()` 会报
    #    "'FrameLocator' object is not callable"，而报错发生在**拿到 frame
    #    之后的第一句**，看起来像"iframe 里什么都没有"。要 evaluate 就得拿
    #    真的 Frame，走 pg.frames 里挑那一个。
    frames = [f for f in pg.frames if f != pg.main_frame]
    ck("★★ 点开之后有一个 iframe（预览是它渲染的）", len(frames) > 0,
       "%d 个 frame" % len(frames))
    f = frames[0] if frames else None
    ck("★★ iframe 里确实是我们那份 HTML", f is not None and
       "图" in (f.inner_text("body") or ""), "")
    if f is None:
        return
    # ★★★ 这一条就是 item 4 本身：图片的**自然宽度** > 0 = 真的解码出来了。
    #     裂图（404）时 naturalWidth 是 0，而元素照样在、尺寸照样有 ——
    #     只看"img 在不在"会全绿。
    ok = f.evaluate("""() => {
        var i = document.getElementById('theimg');
        if (!i) return 'no-img';
        if (!i.complete) return 'not-loaded';
        return i.naturalWidth > 0 ? ('ok:' + i.naturalWidth) : 'broken';
    }""")
    ck("★★★ 预览里的图片真的解码出来了（naturalWidth > 0，不是裂图）",
       isinstance(ok, str) and ok.startswith("ok:"), ok)
    src_attr = f.evaluate(
        "() => { var i=document.getElementById('theimg');"
        " return i ? i.getAttribute('src').slice(0, 30) : ''; }")
    ck("★★ 图上写的是 data: URI（不是临时从附件目录里现取）",
       isinstance(src_attr, str) and src_attr.startswith("data:image/"),
       src_attr)
    # 反向：指向不存在的那张图**仍然**是裂的 —— 内联不能"什么都当成好的"，
    # 那会把真问题一起藏掉。
    gone = f.evaluate(
        "() => { var i=document.getElementById('gone');"
        " return i ? i.naturalWidth : -1; }")
    ck("★ 反向：指向不存在文件的图仍然是裂的（内联没有假装成功）",
       gone == 0, gone)


def _tiny_png():
    """一张 1×1 的真 PNG（用来验 naturalWidth）。"""
    import base64
    return base64.b64decode(
        b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
        b"z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


def _upload(pg, src):
    """把 src 目录下的文件塞进文件管理区的上传控件。

    ⚠️ Shiny 的 fileInput 真身是 `<input type=file>`（被 CSS 藏起来），
    Playwright 的 set_input_files 直接对它下手就行 —— 不要点那个漂亮的
    按钮，那是给真人用的。
    """
    inp = pg.locator("input[type=file]").first
    if inp.count() == 0:
        ck("★★ 文件管理区有上传控件", False)
        return
    files = [os.path.join(src, f) for f in sorted(os.listdir(src))]
    inp.set_input_files(files)
    pg.wait_for_timeout(3000)
    ck("★★ 上传控件接住了文件（没有报错弹层）", True)


# =============================================================================
# item 5：三个 HTML 进了技能库
# =============================================================================
def item05(pg):
    print("\n== item 5：技能库里的三份蒸馏笔记 ==", flush=True)
    C.goto(pg, "skills")
    pg.wait_for_timeout(2500)

    names = pg.eval_on_selector_all(
        ".dsapp-skill-name", "els => els.map(e => e.innerText.trim())")
    ck("★★ 技能页画出了技能行（不是一片空白/一句报错）", len(names) >= 12,
       "%d 行" % len(names))
    body = txt(pg, "body")
    ck("★★ 页面上没有 R 原文报错 / 兜底卡片",
       "subscript out of bounds" not in body and
       "An error has occurred" not in body)

    want = [u"教程代码结构化蒸馏", u"文献结构化精读", u"生信基地内容地图"]
    for w in want:
        ck(u"★★★ 技能库里有「%s」（顶层散放 .html 是扫不到的）" % w,
           w in names, " | ".join(names[:30]))
    ck("★ 反向：老的几条还在（没被这次改动挤掉）",
       u"文献速递" in names or u"出图规范" in names or len(names) >= 18,
       " | ".join(names[:30]))

    # 展开一条，确认附件真的在文件树里 —— 只断"名字在列表里"的话，
    # 一个没有附件的空壳 SKILL.md 照样全绿，而用户点开是空的。
    for w in want:
        rows = pg.locator(".dsapp-skillgroup", has_text=w)
        if rows.count() == 0:
            continue
        row = rows.first
        summ = row.locator("summary").first
        if summ.count():
            summ.click()
            pg.wait_for_timeout(900)
        tree = row.locator(".dsapp-skill-tree").first
        files = tree.inner_text() if tree.count() else ""
        ck(u"★★ 「%s」展开后有配套的 .html 附件" % w,
           ".html" in files, files.replace("\n", " / ")[:200])


# =============================================================================
# item 6：算力节点的归属说清楚了
# =============================================================================
def item06(pg):
    print("\n== item 6：这三台机器分别是谁的 ==", flush=True)
    C.goto(pg, "settings")
    pg.wait_for_timeout(1500)
    # 「执行」是设置页里的二级页签，不是左栏那一项。
    #
    # ⚠️ 选择器必须写成 `.dsapp-page .nav-link`：只写 `text=执行` 会先命中
    #    对话页那颗「确认执行」按钮 —— bslib 把所有页都留在 DOM 里（只藏
    #    不激活），而那颗按钮就在文档里排得更靠前。Playwright 于是去点一个
    #    **不可见**的元素，等到 30 秒超时，报的是"元素不可见"，
    #    看起来像"执行页不存在"。
    pg.click(".dsapp-page .nav-link:has-text('执行')", timeout=15000)
    pg.wait_for_timeout(2000)

    # 量的是**这一页的 pane**，不是整个 body：别的页（比如对话页的提示词）
    # 里也可能出现"当前服务器"这种字样，扫整个 body 会量到别人的文字。
    deck = _settings_pane(pg)
    ck(u"★★★ 「当前挂载服务器」被写明是**本站的部署机**，不是你自己的机器",
       u"本站的部署机" in deck and u"不是你的机器" in deck, deck[:400])
    # ⚠️ 这里用的必须是页面上**真正写着**的那两个名字。写成「你自己的服务器 /
    #    你自己的电脑」是 2026-09-28 第一跑的错：那两个名字是**下拉框的选项**
    #    （"远程服务器" / "我的本地电脑"），说明文字里引的是选项名，不是
    #    "你自己的服务器"这种描述。断言照着自己想象中的文案写，红的是探针
    #    而不是应用 —— 这类"断言写错"和"功能坏了"报出来一模一样。
    ck("★★ 另外两项的物主也写了（远程服务器 / 我的本地电脑）",
       u"远程服务器" in deck and u"我的本地电脑" in deck, "")
    ck("★ 部署机的身份给出来了（主机名 / 核数 / 内存）",
       bool(re.search(u"本机\\s+\\S+\\s+·\\s+\\d+\\s+核", deck)) or
       u"核 ·" in deck or u"核 " in deck, "")
    # ⚠️ 反向：老说法不能还留在页面上
    ck("★★ 反向：页面上没有留下「当前服务器」这种相对说法（歧义就是它带来的）",
       u"当前服务器" not in deck, "")


# =============================================================================
# item 7：管理页的 GPU 开关
# =============================================================================
def _ensure_platform_admin(pg):
    """把本轮注册的账号提成平台管理员，返回"现在确实是管理员"。

    ⚠️⚠️ 这一步**不能省**，也不能假定"第一个注册的账号就是管理员"。
       `_common.py` 的 TAG 是时间戳，所以**每跑一轮就是一个新账号**；而
       /tmp/dsapp_v14/data 是跨轮次保留的，平台管理员永远是最早那个（id=1）。
       于是第二轮开始，本轮的账号是**普通用户** —— 左栏根本不渲染「管理区」
       那一项，`goto(pg,"admin")` 的失败表现只是「左栏高亮没跟上」，紧接着
       是「管理页画出了账号表 ✗」。那两句话指向的是"这一版把管理页弄坏了"，
       而真实原因是权限不对。2026-09-28 第一次跑就栽在这里。

    ⚠️ 提权之后**必须 reload**：左栏那一串是服务端按角色渲染的，改库不会
       让已经发出的页面长出新选项。而 reload 之后身份靠 cookie 续上
       （R/utils.R:885 那一段讲的就是这条链路）。
    """
    import sqlite3
    uid, p = C.seed_or_die(C.EMAIL)
    con = sqlite3.connect(p)
    row = con.execute("SELECT is_admin, admin_scope FROM users WHERE id = ?",
                      (uid,)).fetchone()
    ok = bool(row) and row[0] == 1 and (row[1] or "") == "platform"
    if not ok:
        con.execute("UPDATE users SET is_admin = 1, admin_scope = 'platform' "
                    "WHERE id = ?", (uid,))
        con.commit()
        con.close()
        pg.reload(wait_until="domcontentloaded")
        C.wait_awake(pg)
        pg.wait_for_selector(".dsapp-shell", timeout=60000)
        pg.wait_for_timeout(2000)
        return True
    con.close()
    return True


def _msg(pg):
    """管理页上那行操作回执（`#admin-action_msg`）。断言红了的时候，
    它是"服务端到底做了什么"的唯一直接证据。"""
    try:
        return txt(pg, "#admin-action_msg")[:120]
    except Exception as e:
        return "读不到回执: %s" % e


def _select_self(pg):
    """按邮箱筛出本轮账号，选中它那一行；**确认选中真的生效了**再返回。

    ⚠️ 不能点第 1 行：表按 id 升序，第 1 行是**最早那个账号**；而且
       pageLength = 10，跑过十几轮之后本轮那行会翻到第 2 页。
       点错行的后果是"开关开到了别人头上"，而下面读的库是本轮邮箱 ——
       报出来是"选允许 → 库里是 1 ✗"，看着像开关没接上。

    ⚠️⚠️ 点完**必须回读 `tr.selected`**，不能点完就走。DT 的选中是它自己的
       内部状态，`click()` 返回 ≠ 服务端 `input$tbl_rows_selected` 已经是这个
       id；而筛选每敲一次都会让表重画，重画会把选中清掉。抢在重画之前点按钮，
       服务端 `selected()` 读到的还是 NULL —— 于是它走
       `note("先在表里选一个账号。")`，**弹窗根本不出现**。
       2026-09-28 连着栽了两次，两次报出来都是"回显 ✗ []"，而真相是没弹窗。
       所以这里重试到 `tr.selected` 真的出现为止（最多 3 次）。
    """
    kw = pg.locator("#admin-u_kw")
    if kw.count():
        kw.fill("")
        pg.wait_for_timeout(1200)
        kw.fill(C.EMAIL)
        # ⚠️ 等表**画完**再往下走，别用固定 sleep 赌：每敲一次关键词都会让 DT
        #    重画一次，而重画是异步的。固定 sleep 短了就是"我行还没画出来"，
        #    长了也只是把窗口缩小 —— 剩下的那点窗口正好够让"点完选中 → 表格
        #    重画 → 选中被清掉"发生在这个函数返回**之后**，于是错误记在下一
        #    步头上（表现为弹窗不出现 / 保存没生效）。
        try:
            pg.wait_for_function(
                "() => document.querySelectorAll('#admin-tbl tbody tr').length === 1",
                timeout=10000)
        except Exception:
            pass
    rows = pg.locator("#admin-tbl tbody tr")
    if rows.count() != 1:
        # 兜底：按邮箱文字定位，别让"筛选坏了"把后面整段都变成假红。
        rows = pg.locator("#admin-tbl tbody tr", has_text=C.EMAIL)
    if rows.count() == 0:
        return False
    for _ in range(3):
        rows.first.locator("td").nth(1).click()
        pg.wait_for_timeout(1500)
        if pg.locator("#admin-tbl tbody tr.selected").count() > 0:
            return True
    return False


def _open_limits(pg, reselect=True, tries=2):
    """（必要时重选那一行 →）点「配额与资源上限」，返回弹窗里有没有 GPU 那组。

    ⚠️⚠️ 为什么必须能重选：保存之后 `refresh()` 重画账号表，DataTable
       重画**会清掉选中行**，此时 `selected()` 是 NULL，服务端第一句就
       `return(note("先在表里选一个账号。"))` —— **弹窗根本不出现**。
       于是"重新打开弹窗看回显"这一步会静默地什么都没打开，而
       `eval_on_selector_all` 在不存在的东西上返回**空数组、不抛错**，
       "没有勾选项"和"没有弹窗"长得一模一样。2026-09-28 就栽在这里。

    ⚠️ 而且"选中"和"打开弹窗"之间还隔着一跳：筛选引起的重画是异步的，
       它要是落在两者中间，选中就被清掉了，服务端照样不弹窗。所以这里
       **整段重试**（选中 → 点按钮 → 看有没有那三个选项），而不是只重试点。
    """
    for _ in range(max(1, tries)):
        if reselect and not _select_self(pg):
            continue
        btn = pg.locator("#admin-set_quota_limits")
        if btn.count() == 0 or not btn.is_visible():
            return False
        btn.click()
        pg.wait_for_timeout(2000)
        if pg.locator(".modal.show input[name='admin-lim_gpu']").count() == 3:
            return True
    return False


def item07(pg):
    print("\n== item 7：配额与资源里的 GPU 开关 ==", flush=True)
    ck("★★ 本轮账号是平台管理员（不是的话管理页压根不渲染，下面全是假红）",
       _ensure_platform_admin(pg))

    C.goto(pg, "admin")
    pg.wait_for_timeout(2000)

    # ⚠️⚠️ 选择器必须带上 DataTable 的 id `#admin-tbl`，**不能**写 `table`。
    #    bslib 把所有页都留在 DOM 里，`table:first` 命中的是**文件页**那张表
    #    （它的第 0 列正好是「去预览」）—— 于是 Playwright 去点一个隐藏元素、
    #    等 30 秒超时，报"element is not visible"。2026-09-28 第一次跑就栽在
    #    这里，而报错文案（不可见）指向的是"管理页没画出来"，跟真实原因
    #    （拿到了别的页的表）差着十万八千里。
    tbl = pg.locator("#admin-tbl")
    ck("★★ 管理页画出了账号表", tbl.count() > 0 and tbl.first.is_visible())
    if tbl.count() == 0:
        return

    # 选中本轮那一行（细节与坑见 _select_self 的注释）。
    kw = pg.locator("#admin-u_kw")
    if kw.count():
        kw.fill(C.EMAIL)
        pg.wait_for_timeout(2500)
    ck("★★ 筛出来的正好是本轮这一个账号（筛选没生效的话下面点的是别人的行）",
       tbl.locator("tbody tr").count() == 1, tbl.locator("tbody tr").count())
    ck("★★ 账号表里能找到本轮这个账号", _select_self(pg))

    ck("★★ 「配额与资源上限」按钮在",
       pg.locator("#admin-set_quota_limits").count() > 0)
    ok = _open_limits(pg)
    ck("★★ 弹窗打开了", ok)
    if not ok:
        return

    # ★ GPU 那三个选项。读 label，不是 value —— 用户看的是字。
    labels = pg.eval_on_selector_all(
        ".modal.show .shiny-options-group label",
        "els => els.map(e => e.innerText.trim())")
    ck("★★★ 弹窗里有 GPU 三选一（跟着平台默认 / 允许 / 禁止）",
       any(u"GPU" in x for x in labels) or
       pg.locator(".modal.show input[name='admin-lim_gpu']").count() == 3,
       " | ".join(labels))
    radios = pg.locator(".modal.show input[name='admin-lim_gpu']")
    ck("★★★ 并且真的是**三个**选项（勾选框只有两个状态，表达不了「跟着平台默认」）",
       radios.count() == 3, radios.count())

    vals = pg.eval_on_selector_all(
        ".modal.show input[name='admin-lim_gpu']",
        "els => els.map(e => e.value)")
    ck("★★ 三个选项的取值是 default / allow / deny",
       sorted(vals) == ["allow", "default", "deny"], str(vals))

    # 弹窗里如实说了机器上有没有卡 —— 否则管理员打开开关、用户照样失败，
    # 而失败信息看着像"开关没生效"。
    mbody = txt(pg, ".modal.show")
    ck("★★ 弹窗里说了这台机器上有没有 GPU（结论要具体，不是一句套话）",
       (u"未检测到 GPU" in mbody) or (u"检测到" in mbody and u"设备节点" in mbody),
       mbody[-500:])

    # 选「允许」→ 保存 → 库里那一格应该是 1
    pg.locator(".modal.show input[name='admin-lim_gpu'][value='allow']")\
      .first.check(force=True)
    pg.wait_for_timeout(700)
    pg.locator("#admin-confirm_quota_limits").click()
    pg.wait_for_timeout(3000)

    con = sqlite3.connect(C.db_path())
    row = con.execute("SELECT gpu_enabled FROM users WHERE email = ?",
                      (C.EMAIL,)).fetchone()
    con.close()
    # ⚠️ 附带把页面上的回执一起报出来：库里的值不对时，"保存到底跑没跑"
    #    是第一个要回答的问题 —— 服务端在那句回执里写清楚了它认为改了什么
    #    （"GPU 已允许" / 根本没这句 = 保存被 `selected()` 为空挡掉了）。
    #    只看 `(1,)` 这种证据，分不出"没保存"和"保存了但写错值"。
    ck("★★★ 选「允许」并保存之后，库里 gpu_enabled = 1（开关真的接上了）",
       row is not None and row[0] == 1,
       "%s | 回执: %s" % (row, _msg(pg)))

    # 再打开一次：选中态要回显「允许」—— 不落库的话这里会弹回「跟着平台默认」
    #
    # ⚠️⚠️ 必须**重新选一遍那一行**，不能直接再点一次按钮。保存之后
    #    `refresh()` 会把账号表重画，而 DataTable 重画**会清掉选中行** ——
    #    此时 `selected()` 是 NULL，`observeEvent(input$set_quota_limits)`
    #    第一句就 `return(note("先在表里选一个账号。"))`，**弹窗根本不出现**。
    #    2026-09-28 就栽在这里：报出来的是"选中态回显 ✗ []"，看着像"存进去的
    #    值读不回来"，真实原因是弹窗压根没打开。
    #    ⚠️ 而 `[]` 这个证据本身也会骗人：`eval_on_selector_all` 在不存在的
    #    选择器上返回的是**空数组、不抛错** —— "没有勾选项"和"没有弹窗"
    #    长得一模一样。所以下面先断言弹窗在，再读勾选。
    ok2 = _open_limits(pg, reselect=True)
    ck("★★★ 重新打开弹窗（保存会清掉选中行，必须重选，否则弹窗不出现）", ok2)
    sel = pg.eval_on_selector_all(
        ".modal.show input[name='admin-lim_gpu']",
        "els => els.filter(e => e.checked).map(e => e.value)") if ok2 else []
    ck("★★★ 重新打开弹窗，选中态回显「允许」（存进去的值读得回来）",
       sel == ["allow"], str(sel))

    # 换回「跟着平台默认」→ 库里应该是 NULL（不是 0）
    pg.locator(".modal.show input[name='admin-lim_gpu'][value='default']")\
      .first.check(force=True)
    pg.wait_for_timeout(700)
    pg.locator("#admin-confirm_quota_limits").click()
    pg.wait_for_timeout(3000)
    con = sqlite3.connect(C.db_path())
    row = con.execute("SELECT gpu_enabled FROM users WHERE email = ?",
                      (C.EMAIL,)).fetchone()
    con.close()
    ck("★★★ 选「跟着平台默认」写的是 NULL，不是 0（0 是「明确禁止」，两者不能混）",
       row is not None and row[0] is None,
       "%s | 回执: %s" % (row, _msg(pg)))


# =============================================================================
def main():
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={"width": 1600, "height": 1000})
        try:
            C.enter_app(pg)
            C.seed_or_die(C.EMAIL)
            for fn in (item01, item04, item05, item06, item07):
                try:
                    fn(pg)
                except Exception as e:
                    ck("%s 抛异常（后面整段都『没跑到』）" % fn.__name__, False,
                       "%s: %s" % (type(e).__name__, e))
                pg.screenshot(path="%s/%s.png" % (C.OUT, fn.__name__))
        finally:
            br.close()
    return ck.done()


if __name__ == "__main__":
    sys.exit(main())
