# -*- coding: utf-8 -*-
"""V11 界面重排（item 2/3/4/5/6/9/10）的浏览器回归。

对着一次性实例（8898）跑：

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v11/layout.py

为什么非要用浏览器：这一版改的全部是**位置**。「技能和硬件选择并列」这句话
在 HTML 里判不出来 —— 两个控件都在页面上、文字都在，只是隔了 300 像素、
或者一个在另一个下面，离线断言照样全绿。所以判据一律是 getBoundingClientRect
出来的**几何关系**，不是"元素存在"。
"""
import io
import os
import sqlite3
import sys
import time

from playwright.sync_api import sync_playwright

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v11test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v11")


def _guard(app):
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身（线上那份代码）。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("DSAPP_DATA_ROOT="):
            root = ln.split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：%s 里没有 DSAPP_DATA_ROOT。" % envf)
    if not (root.startswith("/tmp/") or root.startswith("/var/tmp/")):
        sys.exit("拒绝运行：DSAPP_DATA_ROOT=%s 不在临时目录下。" % root)
    return root


DATA_ROOT = _guard(APP)
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


TAG = str(int(time.time()))[-6:]
EMAIL = "v11layout_%s@example.com" % TAG
PW = "Test-%s-pw" % TAG


def db_path():
    for r, _d, fs in os.walk(DATA_ROOT):
        for f in fs:
            if f.endswith(".sqlite3"):
                return os.path.join(r, f)
    return None


def seed_conversation(email, rounds=4):
    """往测试实例的库里塞一段**够长**的对话。

    二级目录要 >=3 轮用户消息才出现（见 R/mod_chat.R 的 dsapp_toc_ui）。真
    发四轮得连着调四次模型 —— 又慢又花钱，而且这个脚本要验的是"目录挂在哪
    一行下面"，不是模型会不会回答。所以消息直接写库。
    """
    p = db_path()
    if p is None:
        return None
    con = sqlite3.connect(p)
    cur = con.cursor()
    uid = cur.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    if uid is None:
        con.close()
        return None
    sid = "v11layout-%s" % TAG
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cur.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    cur.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)",
                (sid, "V11 排版用例", now, now, uid[0]))
    for i in range(rounds):
        cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)",
                    (sid, "user", "第 %d 轮：看看这批数据的质控情况" % (i + 1), now))
        cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)",
                    (sid, "assistant",
                     "第 %d 轮的回答。" % (i + 1) +
                     "这是一段够长的正文，用来把左列撑出滚动条。" * 20, now))
    con.commit()
    con.close()
    return sid


with sync_playwright() as b:
    br = b.chromium.launch()
    ctx = br.new_context(viewport={"width": 1440, "height": 900})
    pg = ctx.new_page()

    def enter_app(page):
        """一路点到主界面（.dsapp-shell）。

        这条链比看起来长：注册 → 恢复码页（"我只显示这一次"）→ 用户须知闸门
        （V9 item 1，新账号必须勾选）。少点任何一步都会停在**另一个页面**上，
        而那个页面的地址、标题、样式都和登录页一样 —— 只看"有没有报错"是
        看不出来的，只会看到后面每一条断言都莫名其妙地红。
        """
        page.goto(URL, wait_until="domcontentloaded")
        page.wait_for_selector(".dsapp-auth", timeout=30000)
        page.wait_for_timeout(2000)

        if page.locator("#welcome-nickname").count() == 0:
            page.click("#welcome-go_register")
            page.wait_for_selector("#welcome-nickname", timeout=15000)
            page.wait_for_timeout(1000)
        page.fill("#welcome-nickname", "V11排版")
        page.fill("#welcome-email", EMAIL)
        page.fill("#welcome-phone", "13800000007")
        page.fill("#welcome-field", "转录组")
        page.fill("#welcome-password", PW)
        cb = page.locator("#welcome-tos_agree")
        if cb.count() and not cb.is_checked():
            cb.check()
        page.click("#welcome-do_register")

        # 恢复码页
        page.wait_for_selector("#welcome-enter_app", timeout=40000)
        page.click("#welcome-enter_app")

        # 用户须知闸门（也许不出现：同一浏览器第二次进来就不用再确认）
        for _ in range(40):
            page.wait_for_timeout(1000)
            if page.locator(".dsapp-shell").count():
                return True
            if page.locator("#tos_gate-do_agree").count():
                c = page.locator("#tos_gate-agree")
                if c.count() and not c.is_checked():
                    c.check()
                page.click("#tos_gate-do_agree")
                page.wait_for_timeout(3000)
        return page.locator(".dsapp-shell").count() > 0

    if not enter_app(pg):
        pg.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        txt = pg.inner_text("body")
        sys.exit("注册没进主界面（页面文字 %d 字）：\n%s" % (len(txt), txt[:600]))

    # ★★ 这一步是**安全网**，不是普通的前置检查。
    #
    #    刚注册的账号必须出现在 DATA_ROOT 那个库里。找不到就说明**这个实例
    #    根本没在读这份 .Renviron** —— 它多半正连着另一个数据目录，而那个
    #    目录很可能就是**线上库**。
    #
    #    2026-09-15 真踩到了：启动实例时的工作目录是仓库根，R 在启动时读的是
    #    **仓库那份 .Renviron**（它里面的 DSAPP_DATA_ROOT 指向线上 data/），
    #    而 .Renviron 的值会**覆盖**继承来的同名环境变量 —— 命令行上传的
    #    DSAPP_DATA_ROOT 一声不响地被盖掉了。结果是一次浏览器回归往线上库里
    #    注册了 3 个测试账号。这条断言当时只是一句 ✗，脚本继续往下跑完了全部
    #    用例。所以现在它是**硬退出**。
    sid = seed_conversation(EMAIL)
    if sid is None:
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里。\n"
                 "  说明这个实例读的不是这份 .Renviron —— 停下来，先查它到底\n"
                 "  连着哪个数据目录（很可能就是线上库），别再往下跑了。"
                 % (EMAIL, db_path()))
    # ⚠️ reload 要重试：注册成功之后服务端还会走一次 session$reload() 把模块
    #    状态清干净，那一下和这里的 reload 撞在一起时，Playwright 报的是
    #    net::ERR_ABORTED / "frame was detached" —— 页面本身没问题。
    for attempt in range(4):
        try:
            pg.reload(wait_until="domcontentloaded")
            break
        except Exception as e:
            if attempt == 3:
                raise
            print("  (reload 第 %d 次被服务端那次 reload 撞掉了，重试)"
                  % (attempt + 1))
            pg.wait_for_timeout(3000)
    pg.wait_for_selector(".dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)
    # 落到「言出法随」页。bslib 的 navset_hidden 是"只藏不激活"，别的页也
    # 在 DOM 里 —— 不先切过去的话，下面每一条几何断言量的都是隐藏元素的
    # 0×0 矩形，报出来的失败会指向完全错误的地方。
    pg.evaluate("() => window.dsappNav && window.dsappNav('chat')")
    pg.wait_for_selector(".dsapp-sess", timeout=30000)
    pg.wait_for_timeout(2000)
    # 点开它 —— 二级目录只挂给**当前**会话（见 output$session_list）
    pg.click(".dsapp-sess[data-sid='%s']" % sid)
    pg.wait_for_timeout(3000)

    # =====================================================================
    # item 6：分析环境 → 硬件选择
    # =====================================================================
    bar = pg.locator(".dsapp-ctrl-bar")
    chk("item6 有一排控件（.dsapp-ctrl-bar）", bar.count() == 1, bar.count())
    bar_txt = bar.inner_text() if bar.count() else ""
    chk("item6 ★ 这一排里的抬头是「硬件选择」", "硬件选择" in bar_txt, bar_txt)
    chk("item6 ★ 页面上不再有「分析环境」这个说法（有歧义，已改名）",
        pg.locator("text=分析环境").count() == 0,
        "还有 %d 处" % pg.locator("text=分析环境").count())
    # ⚠️⚠️ 要读 **selectize 的下拉列表**，不能读 <select> 的 options。
    #    Shiny 的 selectInput 默认走 selectize.js，而 selectize **会把原始
    #    <select> 里的 option 全部删掉、只留当前选中那一个**（它就是靠这个
    #    把值同步回去的）。所以 `[...e.options]` 永远只有一项 —— 看上去像
    #    "下拉框里只有一个选项"，其实三个都在，只是不在那个元素里。
    #
    #    而选项列表**要等下拉框展开才会渲染**（selectize 是懒渲染的），
    #    所以先点开，读完再收起来。
    kind_sel = pg.locator(".dsapp-ctrl-bar .selectize-control").first
    kind_sel.locator(".selectize-input").click()
    pg.wait_for_timeout(800)
    kinds = pg.eval_on_selector_all(
        ".dsapp-ctrl-bar .selectize-control:first-of-type .selectize-dropdown",
        "es => es.map(e => [...e.querySelectorAll('.option')]"
        ".map(o => o.textContent.trim()))")
    pg.keyboard.press("Escape")
    pg.wait_for_timeout(300)
    chk("item6 三个选项还是那三个（当前服务器/本地电脑/远程服务器）",
        any(all(t in opts for t in ("当前服务器", "本地电脑", "远程服务器"))
            for opts in kinds), kinds)

    # =====================================================================
    # item 3 / item 4：技能、系统环境都要**并列**在这一排里
    #
    # ★ 判据是几何：同一排 = 三个格子的垂直中线互差不超过一行高，而且
    #   x 坐标严格递增（从左到右排开）。只查"元素在不在"的话，把技能塞回
    #   输入框上方（改之前的样子）照样是绿的。
    # =====================================================================
    geo = pg.evaluate("""() => {
      const cells = [...document.querySelectorAll('.dsapp-ctrl-bar > .dsapp-ctrl')];
      const grab = kw => {
        const c = cells.find(e => (e.querySelector('.dsapp-ctrl-h')||{}).innerText
                                   && e.querySelector('.dsapp-ctrl-h').innerText.includes(kw));
        if (!c) return null;
        const r = c.getBoundingClientRect();
        return {x: r.x, y: r.y, w: r.width, h: r.height, mid: r.y + r.height/2};
      };
      return {n: cells.length, hw: grab('硬件选择'), env: grab('系统环境'),
              sk: grab('技能'), auto: grab('自动执行')};
    }""")
    chk("item3/4 这一排里至少四格（硬件/系统环境/技能/自动执行）",
        geo["n"] >= 4, geo)
    chk("item3 技能那一格在这一排里", geo["sk"] is not None, geo)
    chk("item4 系统环境那一格在这一排里", geo["env"] is not None, geo)
    if geo["sk"] and geo["env"] and geo["hw"]:
        same_row = max(abs(geo["sk"]["mid"] - geo["hw"]["mid"]),
                       abs(geo["env"]["mid"] - geo["hw"]["mid"])) < 40
        chk("item3 ★ 技能和硬件选择**同一排**（中线差 <40px，不是上下堆着）",
            same_row, geo)
        chk("item4 ★ 系统环境和硬件选择**同一排**",
            abs(geo["env"]["mid"] - geo["hw"]["mid"]) < 40, geo)
        chk("item3/4 从左到右排开（x 严格递增）",
            geo["hw"]["x"] < geo["env"]["x"] < geo["sk"]["x"],
            (geo["hw"]["x"], geo["env"]["x"], geo["sk"]["x"]))

    # 系统环境这一格必须是**能选的控件**，不是一行只读小字（item 4 的原话
    # 就是"系统环境也与分析环境选择并列"，并列的是一个选择器）
    env_sel = pg.locator(".dsapp-ctrl-bar select").count()
    chk("item4 系统环境是个下拉框（不是只读文字）", env_sel >= 2,
        "这一排里有 %d 个 select" % env_sel)

    # =====================================================================
    # item 5：轮数滑块
    # =====================================================================
    sl = pg.locator("#chat-agent_iter")
    chk("item5 有一个轮数滑块", sl.count() == 1, sl.count())
    lbl0 = pg.evaluate("""() => {
      const e = document.querySelector('.dsapp-iter-label');
      return e ? e.innerText.trim() : '';
    }""")
    chk("item5 滑块旁边写着当前轮数", bool(lbl0), repr(lbl0))
    # 拖到最右边，看那个小字有没有跟着变 —— 它是个独立 output，写死的话
    # 就是"滑块在动、数字不动"（R/mod_chat.R 里那段注释记的就是这个坑）。
    # ⚠️ 必须**真拖**，不能往 #chat-agent_iter 上写 value 再 dispatchEvent。
    #    Shiny 的 sliderInput 是 ionRangeSlider 画的：原来那个 <input> 被
    #    藏起来当"影子输入"用了，值由插件在拖动结束时写回它。直接改影子
    #    输入的值、再手动派发 input/change，插件根本不知道 —— 页面上滑块
    #    一动不动，服务端收不到新值，而这条断言会红得像是后端写死了文案。
    # ⚠️ 把手那个元素的类是 **.irs-handle**，不是 .irs-slider。ionRangeSlider
    #    2.x 改过名（老版本叫 .irs-slider），网上抄来的选择器多半是旧的 ——
    #    拿着旧名字去 bounding_box() 会**等满超时**再抛错，报的是"找不到
    #    元素"，看起来像滑块根本没渲染出来。
    box = pg.locator(".dsapp-iter-slider .irs-handle").first.bounding_box()
    track = pg.locator(".dsapp-iter-slider .irs-line").first.bounding_box()
    if box and track:
        pg.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        pg.mouse.down()
        pg.mouse.move(track["x"] + track["width"] - 1,
                      box["y"] + box["height"] / 2, steps=12)
        pg.mouse.up()
    pg.wait_for_timeout(2000)
    lbl1 = pg.evaluate("""() => {
      const e = document.querySelector('.dsapp-iter-label');
      return e ? e.innerText.trim() : '';
    }""")
    chk("item5 ★ 拖动滑块之后那个数字跟着变（不是写死的文案）",
        lbl1 != lbl0 or not lbl0, "%r → %r" % (lbl0, lbl1))

    # =====================================================================
    # item 9：言出法随 ↔ 对话文件，分栏 + 固定位置
    # =====================================================================
    g9 = pg.evaluate("""() => {
      const q = s => document.querySelector(s);
      const c = q('.dsapp-chat-col'), f = q('.dsapp-files-col');
      if (!c || !f) return null;
      const rc = c.getBoundingClientRect(), rf = f.getBoundingClientRect();
      const sc = getComputedStyle(f);
      return {cx: rc.x, cright: rc.right, fx: rf.x, fright: rf.right,
              fy: rf.y, fw: rf.width, position: sc.position, top: sc.top,
              overflowY: sc.overflowY};
    }""")
    chk("item9 ★ 主区真的拆成了两列（左右两列都在）", g9 is not None, "抠不到")
    if g9:
        chk("item9 ★ 是**并排**的两列，不是上下（左列的右边 <= 右列的左边）",
            g9["cright"] <= g9["fx"] + 1, g9)
        chk("item9 ★ 右列（对话文件）位置固定：sticky + 不在页首",
            g9["position"] == "sticky" and g9["fy"] > 0, g9)
        chk("item9 右列自己一条滚动条（长产物不推左列）",
            g9["overflowY"] in ("auto", "scroll"), g9)
        pg.screenshot(path=OUT + "/01_two_cols.png", full_page=False)

    # 右列真的出现在视口里，而且**没被页脚压住** —— sticky 的 top 算错时
    # 卡片头会钻到固定导航栏底下，几何上"存在"，看起来是残缺的。
    vp = pg.evaluate("""() => {
      const f = document.querySelector('.dsapp-files-col');
      const r = f.getBoundingClientRect();
      return {top: r.top, bottom: r.bottom, vh: window.innerHeight};
    }""")
    chk("item9 右列整块在视口内（没被导航栏/页脚吃掉）",
        0 < vp["top"] and vp["bottom"] <= vp["vh"] + 40, vp)

    # =====================================================================
    # item 2：二级目录挂在**它自己那条会话**下面
    # =====================================================================
    g2 = pg.evaluate("""() => {
      const act = document.querySelector('.dsapp-sess.active');
      const toc = document.querySelector('.dsapp-toc-sess');
      if (!act || !toc) return null;
      // 目录必须是这条会话那一块的**后代**，而侧栏底部那个老位置不是
      const inSess = act.contains(toc) ||
                     (act.parentElement && act.parentElement.contains(toc) &&
                      toc.compareDocumentPosition(act) & Node.DOCUMENT_POSITION_PRECEDING);
      const ra = act.getBoundingClientRect(), rt = toc.getBoundingClientRect();
      const items = toc.querySelectorAll('a, .dsapp-toc-item, li').length;
      return {inSess: !!inSess, gap: rt.top - ra.bottom, items: items,
              tocTop: rt.top, x: rt.x, ax: ra.x};
    }""")
    chk("item2 ★ 当前会话下面有二级目录（4 轮消息，够阈值）",
        g2 is not None, "没找到 .dsapp-toc-sess")
    if g2:
        chk("item2 ★ 目录紧贴在会话行**下方**（缝隙 <40px，不是侧栏底部）",
            -2 <= g2["gap"] < 40, g2)
        chk("item2 ★ 目录和会话行左对齐（同一个缩进层级）",
            abs(g2["x"] - g2["ax"]) < 30, g2)
        chk("item2 目录里有可点的条目", g2["items"] > 0, g2)
        pg.screenshot(path=OUT + "/02_toc_under_session.png", full_page=False)

    # 换一个会话（没有目录的那个）时，目录不能留在原地 —— 留着就说明它其实
    # 还是"一个固定位置的面板"，只是碰巧画在了那条会话下面
    pg.click("#chat-new_chat")
    pg.wait_for_timeout(3000)
    g2b = pg.evaluate("""() => {
      const act = document.querySelector('.dsapp-sess.active');
      const toc = document.querySelector('.dsapp-toc-sess');
      const a = act ? act.getAttribute('data-sid') : null;
      return {activeSid: a, tocVisible: !!toc &&
              toc.getBoundingClientRect().height > 0 &&
              getComputedStyle(toc).display !== 'none'};
    }""")
    chk("item2 ★ 切到新对话之后目录就不显示了（它是会话的属性，不是固定面板）",
        g2b["activeSid"] != sid and not g2b["tocVisible"], g2b)

    # =====================================================================
    # item 10：确认执行按钮在**输入框那一排的固定位置**，不在代码框上
    # =====================================================================
    g10 = pg.evaluate("""() => {
      const slot = document.querySelector('#chat-confirm_slot');
      const composer = document.querySelector('.dsapp-composer');
      const send = document.querySelector('#chat-send');
      if (!slot) return {slot: false};
      const btn = slot.querySelector('button');
      const rs = slot.getBoundingClientRect(), rb = btn ? btn.getBoundingClientRect() : null;
      const rsend = send ? send.getBoundingClientRect() : null;
      return {
        slot: true,
        inComposer: !!(composer && composer.contains(slot)),
        cls: btn ? btn.className : '',
        disabled: btn ? btn.disabled : null,
        bg: btn ? getComputedStyle(btn).backgroundColor : '',
        color: btn ? getComputedStyle(btn).color : '',
        opacity: btn ? getComputedStyle(btn).opacity : '',
        // 和「发送」并排：同一排（中线差 <20px）
        midDiff: (rb && rsend) ? Math.abs((rb.y+rb.height/2) - (rsend.y+rsend.height/2)) : null,
      };
    }""")
    chk("item10 ★ 确认按钮插槽在输入区（.dsapp-composer）里", g10.get("slot"), g10)
    chk("item10 ★ 没有待确认方案时，它是**灰的**（disabled）",
        g10.get("disabled") is True, g10)
    chk("item10 ★ 灰的样式真的落了地（不是只有 disabled 属性）",
        g10.get("cls", "").find("dsapp-btn-run-off") >= 0,
        g10.get("cls"))
    chk("item10 ★ 它和「发送」在**同一排**（固定位置，不是浮在代码框上）",
        g10.get("midDiff") is not None and g10["midDiff"] < 20, g10)

    # 代码卡片上**不该**再有执行按钮
    cards = pg.evaluate("""() => {
      const cs = [...document.querySelectorAll('.dsapp-code')];
      let btn = 0, slot = 0;
      cs.forEach(c => {
        btn += c.querySelectorAll('.dsapp-code-run, button.dsapp-btn-run').length;
        slot += c.querySelectorAll('.dsapp-code-slot').length;
      });
      return {cards: cs.length, btn: btn, slot: slot};
    }""")
    chk("item10 ★ 代码框里没有执行按钮了（用户原话：不应该在代码框上）",
        cards["btn"] == 0, cards)

    # =====================================================================
    # item 11 / item 1：预览（这一条只在 HTML 文件上验，见 preview.py）
    # =====================================================================

    pg.screenshot(path=OUT + "/03_final.png", full_page=True)
    br.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
print("截图在 " + OUT)
sys.exit(0 if ok_all else 1)
