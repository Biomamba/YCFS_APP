# -*- coding: utf-8 -*-
"""V13.9 验收：用户那 12 句话，逐条对着**跑起来的界面**验一遍。

    /home/biomamba/miniconda3/bin/python tests/ui_v139/v139.py

★ 为什么这一版要单独写一个验收脚本，而不是复用某个 ui_v13x：

  这一版的 12 条里有 **9 条是"少了 / 错位了 / 不该有"** 类型的（二级菜单没了、
  总是跳回顶部、两个 logo、间距没必要…）。这类问题的共性是：
  **源码里全都在，只有界面不对**。静态断言（selftest.R）一条都拦不住 ——
  它读的是 R 源文件的文本，"这个元素渲染出来多宽、点了之后滚到哪"它看不见。

  所以这个脚本的原则是：能用几何量（getBoundingClientRect / scrollTop /
  innerText / naturalWidth）回答的，就**不读源码**。

⚠️ 数据是**直接塞库**的（同 diag_toc.py）。走界面建对话要么等模型回话、
   要么每轮几十秒，而这里要验的东西和"消息怎么来的"无关。
   ⚠️ sessions.id 是 TEXT 主键（`s-20260913145800-4279` 这种，见 db.R 的
      dsapp_id），**不是**自增整数 —— 留空让它自增会插进三行 id 为 NULL 的
      记录，症状是"侧栏有行、点不动、目录不挂"，看起来像应用坏了。

⚠️⚠️ 塞完库**必须 reload 一次**：侧栏那条列表的轮询键是服务端的心跳，
   绕过应用直接写库不会让它动一下。等是等不来的（试过，40 秒也不出现）。
"""
import base64
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import *            # noqa: F401,F403
from _common import Chk, DATA_ROOT, EMAIL, OUT, URL, db_path   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

C = Chk()

WS_ROOT = os.path.join(DATA_ROOT, "workspaces")
FILES_ROOT = os.path.join(DATA_ROOT, "files")

_SEQ = 0

# 一张真 PNG（1×1 透明）。**不能**塞一段假字节当 .png —— 预览那条路是按
# 扩展名分流、再真的去解码的，假文件会走到"这个文件读不出来"那个兜底，
# 看起来像功能没做。
PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ"
    "DwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

# 一段够长的正文。**故意长**：item 2 要验的是"消息区滚到底之后位置保得住"，
# 消息区不溢出的话那一整条根本没得验（第一版就是栽在这儿 —— 探针找不到
# 可滚动的容器，报出来是"这一条没验到"，读起来像功能坏了）。
# ⚠️ 拼好之后**不要再对它做 `%` 格式化** —— 正文里有字面的百分号（"5.3%"），
#    再 `LONG_MD % k` 会直接 ValueError: unsupported format character。
LONG_MD = "\n".join(
    ["### 质控小结 %d" % i for i in range(1, 13)] +
    ["- 线粒体基因比例中位数 {:.1f}%".format(5 + i * 0.3) for i in range(12)] +
    ["- 建议阈值：percent.mt < 20，nFeature 取 200-6000", "",
     "下一步跑双细胞去除，然后再进标准化。",
     "```r", "p <- FeatureScatter(p, 'nCount_RNA', 'percent.mt')", "```"])


def seed_session(uid, title, n_turns, files=(), reasoning_on=None):
    """塞一个会话 + n 轮问答 + 它自己的工作区产物。返回 sid。"""
    import sqlite3
    global _SEQ
    _SEQ += 1
    sid = "s-%s-%04d" % (time.strftime("%Y%m%d%H%M%S"), _SEQ)
    con = sqlite3.connect(db_path())
    con.execute(
        "INSERT INTO sessions (id, user_id, title, created_at, updated_at) "
        "VALUES (?,?,?,datetime('now'),datetime('now'))", (sid, uid, title))
    for k in range(1, n_turns + 1):
        con.execute(
            "INSERT INTO messages (session_id, role, content, created_at) "
            "VALUES (?,?,?,datetime('now'))",
            (sid, "user", "第 %d 轮：帮我把这批单细胞数据跑一遍质控" % k))
        con.execute(
            "INSERT INTO messages (session_id, role, content, created_at, "
            "reasoning) VALUES (?,?,?,datetime('now'),?)",
            (sid, "assistant", LONG_MD,
             # item 7 要的是"带思考过程"那种气泡：只有 reasoning 非空的助手
             # 消息才会走 dsapp-bubble-wide 那条支路。不塞的话 n_wide 恒为 0，
             # 断言报的是"没有宽版气泡"，而实际是"根本没有思考过程可测"。
             "让我想想第 %d 轮该从哪儿下手：先看质控指标，再决定要不要过滤。"
             % k if k == (reasoning_on or 0) else None))
    con.commit()
    con.close()

    d = os.path.join(WS_ROOT, "chat-" + sid)
    os.makedirs(d, exist_ok=True)
    for rel in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(PNG_1PX)
    return sid


def seed_uploads(uid, names):
    """往这个账号的**文件管理区**里放几个文件（item 10 用）。"""
    d = os.path.join(FILES_ROOT, "u%d" % uid)
    os.makedirs(d, exist_ok=True)
    for nm in names:
        with open(os.path.join(d, nm), "w") as fh:
            fh.write("V13.9 验收用的占位文件：%s\n" % nm)
    return d


def pick_session(page, sid, timeout=40):
    """在侧栏点开某个对话，并等它真的变成当前对话。

    ⚠️ 三步都不能省，每一步都是踩过的：
      1. 先等元素**进了 DOM**。会话列表是轮询拉的，刚塞进库的对话不会立刻
         出现（所以外面先 reload 了一次）；
      2. 再看它是不是已经 `active`。是就别点 —— dsappPickSession 会重载
         整条消息流，白等几秒；
      3. 最后才等 `visible` 再点。⚠️ bslib 把所有 nav_panel 都留在 DOM 里，
         没选中的那些只是 display:none —— 只等 attached 就去点，Playwright
         会一直报 "element is not visible"（元素明明在），而那个报错读起来
         像元素不存在，会把人往错的方向带。
    """
    sel = '.dsapp-sess[data-sid="%s"]' % sid
    page.wait_for_selector(sel, state="attached", timeout=timeout * 1000)
    if "active" in (page.get_attribute(sel, "class") or "").split():
        return True
    page.wait_for_selector(sel, state="visible", timeout=timeout * 1000)
    page.click(sel)
    page.wait_for_timeout(3000)
    return "active" in (page.get_attribute(sel, "class") or "").split()


def ws_names(page):
    """文件页「工作区」那一块里现在列着哪些文件。"""
    return page.eval_on_selector_all(
        ".dsapp-wsrow .dsapp-wsrow-name",
        "els => els.filter(e => e.offsetParent !== null)"
        ".map(e => e.innerText.trim())")


# ⚠️ `.dsapp-page` **不是**文件页的容器 —— 那个类只在 mod_settings /
#    mod_skills / mod_envs 里有，文件页的 UI 是一个光秃秃的 tagList，没有
#    外层 div（见 mod_files_ui）。拿 `.dsapp-page` 去量文件页的东西，量到的
#    其实是**设置页**那一块（bslib 把所有页都留在 DOM 里），于是
#    「提示文案里有没有『小方块』」这种断言会**静悄悄地绿**：设置页里恰好
#    有"勾选"、恰好没有"小方块"。2026-09-21 就是这么被骗过一次 ——
#    和 _common.goto() 那个 value/中文名 的坑是同一类：量错了地方，
#    而失败信息指的全是错地方。
#
# 文件页只能按**页签的 data-value** 定位。所有页签同时在 DOM 里，
# 所以这个限定词不能省。
FILES_PANE = '.tab-pane[data-value="files"]'


def toolbar_text(page):
    return page.inner_text(FILES_PANE)


def inner_pane(page):
    """设置页里**当前选中那一栏**（界面 / 执行 / 账号 / 帮助）的文字。

    ⚠️ 限定词要**两层**，少一层就量到别的东西去：

      · 只写 `.tab-pane.active`：设置页里套着**第二个** tabset（那一排
        界面/执行/账号/帮助），而 bslib 把没选中的页签也留在 DOM 里 ——
        全文档同时命中三个，Playwright 严格模式直接抛
        "resolved to 3 elements"，抛在**读文字**那一步，报错里全是 DOM 结构。
      · 只写 `.dsapp-page .tab-pane.active`：还是不够。`.dsapp-page` 这个类
        **三页都有**（设置/技能/环境，见 mod_settings/mod_skills/mod_envs），
        而技能页那个 `data-value="mine"` 的页签也是 `.tab-pane.active`。
        它排在文档更前面，`.first` 取到的就是它 —— 宽度 0、`inner_text()`
        返回**空串**（隐藏元素没有渲染出来的文字）。于是每一栏量出来都是
        ""，"帮助页没有『保存并开始使用』"这种**否定式**断言反而全绿：
        空串里当然没有那几个字。2026-09-21 就是这么被骗过一轮。

      所以再加一层外层页签的 data-value 把范围锁死在设置页里。
    """
    loc = page.locator('.tab-pane[data-value="settings"] '
                       ".dsapp-page .tab-pane.active")
    return loc.first.inner_text() if loc.count() else ""


def safe_click(loc, page, wait=0):
    """点一个可能被页脚盖住的元素。

    ⚠️ 页面底部那条 `.dsapp-footer` 是**悬停**在内容上的。Playwright 的可操作性
    检查算的是元素中心点在不在最上层 —— 中心点正好落进页脚那一条时，它会一直
    报 "... intercepts pointer events"，读起来像"这个元素点不着"，而实际只是
    "它在屏幕下沿、被页脚压住了"。

    先把它滚到视口正中（`block:'center'`）再点，一次就好。
    ⚠️ 不要直接上 `force=True`：force 只是跳过检查，鼠标照样按在**原来那个
       坐标**上，事件还是落到页脚上 —— 点了个寂寞，而且不报错。
    """
    try:
        loc.scroll_into_view_if_needed(timeout=5000)
    except Exception:
        pass
    try:
        loc.evaluate("e => e.scrollIntoView({block: 'center'})")
        page.wait_for_timeout(250)
    except Exception:
        pass
    loc.click(timeout=15000)
    if wait:
        page.wait_for_timeout(wait)


with sync_playwright() as pw:
    br = pw.chromium.launch(headless=True)
    pg = br.new_page(viewport={"width": 1600, "height": 950})
    errors = []
    pg.on("pageerror", lambda e: errors.append("PAGEERROR: %s" % str(e)[:200]))
    pg.on("console", lambda m: errors.append("%s: %s" % (m.type, m.text[:200]))
          if m.type == "error" else None)

    pg.goto(URL, wait_until="domcontentloaded")
    enter_app(pg)
    uid = seed_or_die(EMAIL)[0]

    # 两个对话，各自的产物名字**故意不一样** —— item 3 验的就是"显示的是
    # 哪一个对话的工作区"，两边名字一样的话，验不出东西来。
    sid_a = seed_session(uid, "V139 甲对话", 4, reasoning_on=2,
                         files=["qc_violin.png", "results/umap.png"])
    sid_b = seed_session(uid, "V139 乙对话", 2, files=["other_only.png"])
    # item 10 多选打包下载用的是**管理区**那张 DT 表（不是工作区列表 ——
    # 工作区那一列压根没有勾选这回事，第一版就把这两块弄混了）。
    seed_uploads(uid, ["v139_up_1.txt", "v139_up_2.txt", "v139_up_3.txt"])

    # ★ 刷新一次，侧栏和管理区才会带上刚塞进去的东西（理由见文件头那段）。
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(6000)
    goto(pg, "chat", wait=3000)
    pg.wait_for_selector('.dsapp-sess[data-sid="%s"]' % sid_a,
                         state="attached", timeout=40000)

    # =========================================================================
    print("\n== item 1：会话的二级菜单（本对话目录）==", flush=True)
    # =========================================================================
    # 闸门以前数的是**用户轮次**（< 3 就不挂），而一轮 DS_App 会长出十几条
    # 消息 —— 用户的长对话 nuser 一直是 1，目录从来没出现过。
    C("（前置）甲对话成了当前对话", pick_session(pg, sid_a),
      pg.inner_text(".dsapp-chat-side")[:100]
      if pg.locator(".dsapp-chat-side").count() else "")
    pg.wait_for_timeout(2000)
    n_toc = pg.locator(".dsapp-toc").count()
    n_item = pg.locator(".dsapp-toc-item").count()
    vis = 0
    if n_toc:
        box = pg.locator(".dsapp-toc").first.bounding_box()
        vis = 1 if (box and box["width"] > 0 and box["height"] > 0) else 0
    C("★★★ 四条消息的对话挂出了二级菜单（以前 4 条消息 / 1 个用户轮次是不挂的）",
      n_toc >= 1 and vis == 1, "n_toc=%d 可见=%d" % (n_toc, vis))
    C("★★ 目录里每一条对应一轮用户提问", n_item == 4, "n_item=%d" % n_item)

    # =========================================================================
    print("\n== item 2：重渲染之后不跳回顶部 ==", flush=True)
    # =========================================================================
    keeper = pg.evaluate("() => typeof window.dsappKeepScroll")
    C("★★ app.js 里的滚动保持器装上了", keeper == "function", keeper)

    scroll_js = """() => {
      const cands = [...document.querySelectorAll('div,section,main')].filter(e => {
        const cs = getComputedStyle(e);
        const vis = e.offsetParent !== null || cs.position === 'fixed';
        return vis && /auto|scroll/.test(cs.overflowY) &&
               e.scrollHeight > e.clientHeight + 40;
      });
      if (!cands.length) return null;
      cands.sort((a,b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight));
      const el = cands[0];
      el.scrollTop = el.scrollHeight;
      const before = el.scrollTop, max = el.scrollHeight - el.clientHeight;
      /* 往里塞一个节点 = 一次"内容变了"，正是原来会把位置顶掉的那一下。
         MutationObserver 是异步投递的，所以给两帧再读。 */
      const d = document.createElement('div');
      d.style.height = '40px';
      d.textContent = '.';
      el.appendChild(d);
      return new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => {
        r({before: before, after: el.scrollTop,
           max: el.scrollHeight - el.clientHeight,
           cls: (el.className || '').toString().slice(0, 40)});
        d.remove();
      })));
    }"""
    r2 = pg.evaluate(scroll_js)
    if r2 is None:
        C("★★ 重渲染之后仍停在底部（原来会被顶回 0）", False,
          "页面上没有可滚动的消息区（这一条没验到）")
    else:
        C("★★ 重渲染之后仍停在底部（原来会被顶回 0）",
          r2["after"] >= r2["max"] - 5,
          "容器=%s 塞节点前 scrollTop=%s / 之后=%s（上限 %s）"
          % (r2["cls"], r2["before"], r2["after"], r2["max"]))

    # =========================================================================
    print("\n== item 3：从言出法随跳文件页，落在**本对话**的专属文件夹 ==", flush=True)
    # =========================================================================
    # 先把 focus_ws 弄成"粘在**乙**对话上" —— 这正是用户撞到的那个状态：
    # 之前在任务页点过一次「在文件区打开」，之后换到哪个对话，文件页都还停在
    # 乙。不清掉的话，下面这一跳落地看到的是乙的产物。
    goto(pg, "files", wait=3500)
    has_pick = pg.locator("select.dsapp-convpick").count() > 0
    C("（前置）文件页顶上有「换个对话看」那个下拉（要两个以上对话才出现）",
      has_pick, toolbar_text(pg)[:120])
    if has_pick:
        pg.select_option("select.dsapp-convpick", sid_b)
        pg.wait_for_timeout(3000)
    stale = ws_names(pg)
    C("（前置）文件页现在粘在**乙**对话上（不等的话下面这条验不到东西）",
      any("other_only" in x for x in stale), stale)

    goto(pg, "chat", wait=3000)
    pick_session(pg, sid_a)
    pg.wait_for_timeout(4000)     # 产物卡片是 2 秒轮询出来的
    C("（前置）甲对话的产物卡片出来了",
      pg.locator(".dsapp-artifacts").count() > 0,
      pg.inner_text(".dsapp-files-col")[:120]
      if pg.locator(".dsapp-files-col").count() else "")
    pg.click(".dsapp-artifacts .card-header a", timeout=15000)   # 「在文件页管理 →」
    pg.wait_for_timeout(4000)
    got = ws_names(pg)
    C("★★★ 落地看到的是**甲**（当前对话）的产物，不是粘住的那个乙",
      any("qc_violin" in x for x in got) and not any("other_only" in x for x in got),
      got)
    C("★ 而且没有那条「正在看 乙对话 的工作区」的定位条（只是切页，没要求定位）",
      pg.locator(".dsapp-focusbar").count() == 0,
      pg.inner_text(".dsapp-focusbar")
      if pg.locator(".dsapp-focusbar").count() else "")

    # =========================================================================
    print("\n== item 4：工作区列表也能预览 ==", flush=True)
    # =========================================================================
    rows = pg.locator(".dsapp-wsrow").filter(has_text="qc_violin.png")
    C("（前置）工作区列表里看得到这个文件", rows.count() > 0, got)
    pv = rows.first.locator(".dsapp-wsrow-act a", has_text="预览")
    C("★★ 「预览」这一颗在（原来只有「下载」「发布」）", pv.count() == 1,
      rows.first.inner_text() if rows.count() else "")

    # ★ 前置条件：卡片**没被压扁**。
    #
    # 这一条是 2026-09-21 补上的，起因是「预览」明明在、却怎么都点不着：
    # V13.2 item 8 那条 `> .card { flex-shrink: 0 }` 漏了 uiOutput 包着的卡
    # （shiny 给那层 wrapper 设了 display:contents，盒子没了、里面的 .card
    # 成了页签的 flex 项，可选择器看的是 DOM，匹配不上）。实测管理区一多
    # 几张表，整张产物卡被压成 2px，.bslib-card{overflow:auto} 把里面连
    # 那行链接一起裁掉。
    #
    # ⚠️ 必须量**卡自己的高度**，不能只量"链接在不在 DOM 里" —— 被裁掉的
    #    元素照样在 DOM 里、`offsetParent` 也照样非空，所以 count() 和
    #    innerText 这类断言**全是绿的**。这正是这一条存在的理由。
    box = pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.innerText.indexOf('qc_violin') >= 0 && x.offsetParent !== null);
      if (!r) return null;
      let p = r, card = null;
      while (p && p.tagName !== 'HTML') {
        if (p.classList.contains('card')) { card = p; break; }
        p = p.parentElement;
      }
      if (!card) return null;
      const cb = card.getBoundingClientRect();
      // 卡体（真正装内容那一层）也要量：卡高了、卡体还是 16px 一样点不着。
      const body = card.querySelector(':scope > .card-body') || card;
      const bb = body.getBoundingClientRect();
      return {card: Math.round(cb.height), body: Math.round(bb.height),
              bodyScroll: body.scrollHeight};
    }""")
    C("★★★ 装产物的那张卡没有被 flex 压扁（压扁了里面的链接就永远点不着）",
      bool(box) and box["card"] >= 60 and box["body"] >= 40,
      box)
    if pv.count():
        safe_click(pv.first, pg, wait=3500)
        C("★★★ 点开真的弹出了预览（不是同一个页面里什么也没发生）",
          pg.locator(".modal.show, .modal[style*='display: block']").count() > 0
          and pg.locator(".modal-body").count() > 0,
          "modal=%d" % pg.locator(".modal").count())
        body = pg.inner_text(".modal-body") if pg.locator(".modal-body").count() else ""
        img_ok = pg.eval_on_selector_all(
            ".modal-body img", "els => els.map(e => e.naturalWidth)") \
            if pg.locator(".modal-body img").count() else []
        C("★★ 预览里真的把这张图解码出来了（不是一句兜底文案）",
          any(w > 0 for w in img_ok), "naturalWidth=%s body=%s" % (img_ok, body[:80]))

        # ---------------------------------------------------------------------
        print("\n== item 8：下载按钮只有一个 logo ==", flush=True)
        # ---------------------------------------------------------------------
        # shiny::downloadButton() **自带** icon = shiny::icon("download")，
        # 再显式塞一个进去就是两个。
        # ⚠️ 判据是"那颗下载按钮里有几个图标"，不是"整个 footer 里有几个图标"
        #    —— footer 里本来就还有一颗「关闭」（无图标）。第一版把 footer 的
        #    按钮数当成 1 来断言，报的是"按钮 2 个"，指错了地方。
        n_ico = pg.eval_on_selector_all(
            ".modal-footer .btn i, .modal-footer .btn svg",
            "els => els.length")
        dl_ico = pg.eval_on_selector_all(
            ".modal-footer a.btn, .modal-footer button.btn",
            "els => els.filter(e => e.innerText.indexOf('下载') >= 0)"
            ".map(e => e.querySelectorAll('i, svg').length)")
        C("★★★ 下载按钮上只有一个图标（用户原话：「去掉一个」）",
          n_ico == 1 and dl_ico == [1], "footer 图标 %d 个 / 下载按钮里 %s"
          % (n_ico, dl_ico))
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(1500)

    # =========================================================================
    print("\n== item 10：多选打包下载 ==", flush=True)
    # =========================================================================
    # 表格 = 文件**管理区**那张 DT 表（`.dsapp-dt-nowrap` 里那张），不是上面
    # 那块工作区列表 —— 工作区那一列压根没有勾选这回事。
    # 老问题有两处：① 提示文案还在教用户点一个早就没有了的"小方块"；
    #              ② 点某一行的「去预览」会在浏览器里 deselect 掉攒好的勾选。
    tbl = pg.locator(FILES_PANE + " .dsapp-dt-nowrap table").first
    n_row = tbl.locator("tbody tr").count()
    C("（前置）管理区里有三行可以勾", n_row >= 3, "n_row=%d" % n_row)
    hint = toolbar_text(pg)
    C("★★ 提示文案不再教用户去点一个不存在的「小方块」",
      "小方块" not in hint and "勾选" in hint,
      [x for x in hint.split("\n") if "勾" in x][:3])

    def click_size_cell(r):
        """点第 r 行的**大小**那一格 = 勾选这一行。
        列序（mod_files.R 的 colnames）：0=去预览、1=名称、2=大小、
        3=修改时间、4=上传者。
        ⚠️ **不能点名称那一格**（第一版就是点的它）：管理区里目录排在前面，
        点名称 = 「进这个目录」（cell_clicked 里 col == 1 那一支），表格当场
        换成下一层的内容、行数变少，第二下就点在空气上 —— 报出来是
        "td 超时"，读起来像表格坏了。而且点进子目录之后那一整段断言量的
        就已经不是原来那一层了。
        点大小格同样落在行内（Select 扩展的 selector 放宽到了整行），
        勾选照样生效，却不会把页面导航走。"""
        safe_click(tbl.locator("tbody tr").nth(r).locator("td").nth(2), pg,
                   wait=800)

    # 勾选数的**准绳是 tr.selected 的行数**，不是按钮上那个括号 ——
    # 按钮上的字是渲染出来的，会被一堆别的东西（重渲染、别的按钮）干扰，
    # 拿它当唯一判据时失败信息只会说"没找到那句话"，说不清勾到底丢没丢。
    def n_sel():
        return tbl.locator("tbody tr.selected").count()

    for r in range(3):
        click_size_cell(r)
    pg.wait_for_timeout(1500)
    t1 = toolbar_text(pg)
    C("★★ 勾三行之后按钮上写着「打包下载（3 项）」",
      "打包下载（3 项）" in t1 and n_sel() == 3,
      "selected=%d 工具栏=%r" % (n_sel(), t1[:200]))

    # 再点某一行的「去预览」——老行为到这一步勾选就只剩一项了。
    #
    # ⚠️ 得挑一个**文件**行。第 0 列在目录上不是"预览"而是"打开它"
    #    （mod_files.R 的 cell_clicked：col==0 时目录走 current_dir），
    #    而管理区的排序是目录在前 —— 第一版点的是第 0 行，那是个目录，
    #    一下就把表格带进了下一层，行数变了、勾也清了，报出来是
    #    "selected=0"，看着像多选功能坏了。
    #    目录名带 📁 前缀（见 mod_files.R 里 名称 那一列的 ifelse）。
    def first_file_row():
        for i in range(tbl.locator("tbody tr").count()):
            nm = tbl.locator("tbody tr").nth(i).locator("td").nth(1).inner_text()
            if "\U0001F4C1" not in nm:
                return i, nm.strip()
        return None, None

    fr, fname = first_file_row()
    C("（前置）管理区里有一个**文件**行可以点预览",
      fr is not None and fr >= 0, "行号=%s 名称=%r" % (fr, fname))
    safe_click(tbl.locator("tbody tr").nth(fr).locator("td").nth(0), pg,
               wait=3000)
    t2 = toolbar_text(pg)
    C("★★★ 点过「去预览」之后，三个勾**一个都没少**",
      n_sel() == 3 and "打包下载（3 项）" in t2,
      "selected=%d 工具栏=%r" % (n_sel(), t2[:200]))

    # 「预览换了目标」这一条原来写的是 `pg.locator(".dsapp-page").count() > 0`
    # —— 拿一个**文件页根本没有的类**去断言，恒为真，等于没验（`.dsapp-page`
    # 只在设置/技能/环境三页，详见 toolbar_text 上面那段）。改成读右栏那张
    # 预览卡的标题，和刚点的那一行比。
    want = fname
    got = pg.locator(FILES_PANE + ' [id$="preview_title"]').inner_text()
    C("★★ 而且预览真的换了目标（右栏标题是刚点的那个文件）",
      want and want in got, "点了 %r，标题 %r" % (want, got))
    if pg.locator(".modal").count():
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(1000)

    # =========================================================================
    print("\n== item 7：思考过程和执行结果同宽 ==", flush=True)
    # =========================================================================
    goto(pg, "chat", wait=3000)
    pick_session(pg, sid_a)
    pg.wait_for_timeout(3000)
    wid = pg.evaluate("""() => {
      const b = [...document.querySelectorAll('.dsapp-bubble')]
                  .filter(e => e.offsetParent !== null);
      const w = e => Math.round(e.getBoundingClientRect().width);
      const wide = b.filter(e => e.classList.contains('dsapp-bubble-wide'));
      return {n: b.length, n_wide: wide.length,
              w_wide: wide.length ? w(wide[0]) : null,
              w_max: b.length ? Math.max(...b.map(w)) : null};
    }""")
    C("（前置）有一条带「思考过程」的助手消息（不然这条没得验）",
      wid["n_wide"] >= 1, wid)
    if wid["n_wide"] and wid["w_max"]:
        C("★★★ 它和消息流里最宽的那个一样宽（不再比别人窄一截）",
          wid["w_wide"] >= wid["w_max"] - 2,
          "wide=%s max=%s 全部=%s" % (wid["w_wide"], wid["w_max"], wid["n"]))

    # =========================================================================
    print("\n== item 9：补点建议不再直接发系统内置的话 ==", flush=True)
    # =========================================================================
    sug = pg.locator("button:has-text('补点建议')")
    C("★★ 「补点建议」这一颗还在原位（V13.8 的「夹在确认执行和停止之间」没被动）",
      sug.count() >= 1, sug.count())
    n_msg_before = pg.locator(".dsapp-bubble").count()
    if sug.count():
        C("★ 没有任务在跑的时候它是灰的（判据是「有没有活干」，和「停止」同一把尺）",
          sug.first.is_disabled(), "disabled=%s" % sug.first.is_disabled())
    if sug.count() and sug.first.is_enabled():
        sug.first.click()
        pg.wait_for_timeout(2500)
        C("★★★ 点开的是**空的输入框**，不是把写死的那句话直接发出去",
          pg.locator("textarea[id$='suggest_text']").count() > 0,
          pg.inner_text(".modal-body")[:100]
          if pg.locator(".modal-body").count() else "没弹窗")
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(1000)
    else:
        C("★★ 没活干的时候点不动（不会有「点了没反应」那种假死）", True, "按钮是灰的")
    n_msg_after = pg.locator(".dsapp-bubble").count()
    C("★★ 全程没有往对话里多出消息", n_msg_after == n_msg_before,
      "%d → %d" % (n_msg_before, n_msg_after))

    # =========================================================================
    print("\n== item 12：帮助页的客服二维码 ==", flush=True)
    # =========================================================================
    goto(pg, "settings", wait=3500)
    pg.click(".dsapp-page .nav-link:has-text('帮助')", timeout=15000)
    pg.wait_for_timeout(2500)
    pane_txt = inner_pane(pg)
    C("★★ 帮助页里有客服二维码那张卡",
      pg.locator(".dsapp-page .card-header:has-text('客服微信')").count() >= 1,
      pane_txt[:150])
    imgs = pg.eval_on_selector_all(
        "img.dsapp-help-img",
        "els => els.filter(e => e.offsetParent !== null)"
        ".map(e => ({w: e.naturalWidth, src: e.getAttribute('src')}))")
    C("★★★ 那张图真的加载出来了（挂在 www/ 下，部署时跟着代码走）",
      len(imgs) >= 1 and imgs[0]["w"] > 0, imgs)
    C("★ 帮助页**没有**「保存并开始使用」（item 11 的另一半）",
      "保存并开始使用" not in pane_txt, pane_txt[-80:])

    # =========================================================================
    print("\n== item 11：保存并开始使用在三栏的底部 ==", flush=True)
    # =========================================================================
    where = {}
    for t in ("界面", "执行", "账号", "帮助"):
        pg.click(".dsapp-page .nav-link:has-text('%s')" % t, timeout=15000)
        pg.wait_for_timeout(2000)
        where[t] = inner_pane(pg)
    C("★★★ 界面 / 执行 / 账号 三栏的底部都有它",
      all("保存并开始使用" in where[t] for t in ("界面", "执行", "账号")),
      {k: ("保存并开始使用" in v) for k, v in where.items()})
    C("★★ 帮助页没有它（用户原话：「不应该出现在帮助页面」）",
      "保存并开始使用" not in where["帮助"], "")

    # =========================================================================
    print("\n== item 6：窗口之间的间隙 ==", flush=True)
    # =========================================================================
    goto(pg, "chat", wait=3000)
    pick_session(pg, sid_a)
    pg.wait_for_timeout(2500)
    gap = pg.evaluate("""() => {
      const m = document.querySelector('.dsapp-chat-main');
      if (!m) return null;
      const col = m.querySelector('.dsapp-chat-col');
      const fil = m.querySelector('.dsapp-files-col');
      if (!col || !fil) return null;
      const r = e => e.getBoundingClientRect();
      return {sep: Math.round(r(fil).left - r(col).right),
              gap: getComputedStyle(m).gap};
    }""")
    C("★★★ 两栏之间只空 12px（原来 28px：11 + 6px 把手 + 11）",
      gap is not None and gap["sep"] <= 16, gap)
    C("★ 分隔条自己没被挤没（它还在，而且还能拖）",
      pg.locator(".dsapp-split-v").count() >= 1, "")

    C("★★ 整场没有 JS 报错", not errors, "\n".join(errors[:4]))
    pg.screenshot(path=OUT + "/v139.png", full_page=True)
    br.close()

sys.exit(C.done())
