# -*- coding: utf-8 -*-
"""V12 item 1/2 的浏览器回归：间距、动作条的位置、整页不吃掉一屏。

对着一次性实例（8898）跑：

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v12/layout.py

为什么非要用浏览器：这一版改的全是**几何**。用户那两句原话 ——

    「对话框和内容输出框应该挨在一起，现在的间距过大」
    「确认执行和停止应该在输出框的内部，跟随输出的内容一起出现」

—— 在 HTML 里一个字都判不出来：两颗按钮在页面上、文字也对，只是长在
输入区里而不是输出框里，离线断言照样全绿。所以这里的判据一律是
getBoundingClientRect 出来的**位置关系**，外加一条"整页不出现滚动条"。
"""
import os
import sys
import time

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C

TAG = str(int(time.time()))[-6:]
EMAIL = "v12layout_%s@example.com" % TAG

with sync_playwright() as b:
    br = b.chromium.launch()
    ctx = br.new_context(viewport={"width": 1440, "height": 900})
    pg = ctx.new_page()
    chk = C.Chk()

    C.enter_app(pg, email=EMAIL, nickname="V12排版")
    sid = C.seed_conversation(EMAIL)
    C.goto_chat(pg, reload_first=True)
    pg.click(".dsapp-sess[data-sid='%s']" % sid)
    pg.wait_for_timeout(3000)

    # =====================================================================
    # item 1：输入框和输出框**挨在一起**
    # =====================================================================
    g = pg.evaluate("""() => {
      const q = s => document.querySelector(s);
      const R = e => { if (!e) return null; const r = e.getBoundingClientRect();
        return {top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                h: r.height, w: r.width}; };
      return {
        vh: window.innerHeight,
        col: R(q('.dsapp-chat-col')),
        bar: R(q('.dsapp-output-bar')),
        scroll: R(q('.dsapp-chat-scroll')),
        composer: R(q('.dsapp-composer')),
        textarea: R(q('.dsapp-composer textarea')),
        ctrl: R(q('.dsapp-ctrl-bar')),
        notes: R(q('.dsapp-ctrl-notes')),
        footer: R(q('.dsapp-footer')),
        mainBody: R(q('.dsapp-main-body')),
        // 页面到底能不能滚
        docScroll: document.documentElement.scrollHeight -
                   document.documentElement.clientHeight,
        mbScroll: (() => { const e = q('.dsapp-main-body');
          return e ? e.scrollHeight - e.clientHeight : 0; })(),
      };
    }""")

    chk("item1 ★ 输出框下沿和输入框上沿是贴着的（缝隙 < 2px）",
        g["col"] and g["composer"] and
        abs(g["composer"]["top"] - g["col"]["bottom"]) < 2,
        "col.bottom=%.1f composer.top=%.1f" %
        (g["col"]["bottom"] if g["col"] else -1,
         g["composer"]["top"] if g["composer"] else -1))

    # ★ 这条是这次改动的**根**：V11 时整页比一屏高 56px，页面能上下滚，
    #   固定页脚正好压住最下面那排控件 —— 用户得先滚一下才够得着输入框，
    #   那一段"滚"就是他说的"间距过大"。高度不再由 `100vh - 魔数` 算，
    #   而是顺着 flex 一层层分下来，所以这条断言是"那条链没断"的证据。
    chk("item1 ★ 整页不再需要滚动（内容自己吃掉一屏）",
        g["mbScroll"] <= 2, "main-body 溢出 %dpx" % g["mbScroll"])

    chk("item1 最下面那排控件在**页脚上方**（没被固定页脚压住）",
        g["ctrl"] and g["footer"] and g["ctrl"]["bottom"] <= g["footer"]["top"] + 1,
        "ctrl.bottom=%.1f footer.top=%.1f" %
        (g["ctrl"]["bottom"] if g["ctrl"] else -1, g["footer"]["top"]))

    # 控件排必须在输入框**下面**，而且是这一页最靠下的一块内容
    chk("item1 ★ 硬件选择/系统环境那一排在最下方（输入框之下）",
        g["ctrl"] and g["textarea"] and g["ctrl"]["top"] > g["textarea"]["bottom"],
        "ctrl.top=%.1f textarea.bottom=%.1f" %
        (g["ctrl"]["top"] if g["ctrl"] else -1,
         g["textarea"]["bottom"] if g["textarea"] else -1))
    chk("item1 控件的说明小字在控件**下面**（没被顶到别处去）",
        g["notes"] and g["ctrl"] and g["notes"]["top"] >= g["ctrl"]["bottom"] - 1,
        g["notes"])

    # 四个格子必须**同一排**。实测过一次：技能那一格的空态文案有 20 个字宽，
    # 把「自动执行」挤到了第二行，整排高 124px（一排只要 60px），多出来的
    # 64px 是从消息区里扣的。文案压短之后这条才成立。
    g2 = pg.evaluate("""() => {
      const cells = [...document.querySelectorAll('.dsapp-ctrl-bar > .dsapp-ctrl')];
      const mid = e => { const r = e.getBoundingClientRect(); return r.y + r.height/2; };
      const hs = [...document.querySelectorAll('.dsapp-ctrl-h')].map(e => e.innerText.trim());
      const ys = cells.map(mid);
      return {n: cells.length, hs: hs, ys: ys,
              span: ys.length ? Math.max(...ys) - Math.min(...ys) : -1,
              barH: (document.querySelector('.dsapp-ctrl-bar')||{getBoundingClientRect:0})
                    .getBoundingClientRect().height};
    }""")
    chk("item1 这一排至少四格（硬件/系统环境/技能/自动执行）", g2["n"] >= 4, g2)
    chk("item1 ★ 四格在**同一排**（中线差 < 30px，没有换行）",
        g2["span"] >= 0 and g2["span"] < 30, g2)
    chk("item1 这一排本身不超过一行高（< 80px）", g2["barH"] < 80, g2["barH"])

    pg.screenshot(path=C.OUT + "/01_composer.png", full_page=False)

    # =====================================================================
    # item 2：确认执行 / 停止在**输出框内部**的下沿
    # =====================================================================
    g3 = pg.evaluate("""() => {
      const q = s => document.querySelector(s);
      const R = e => { if (!e) return null; const r = e.getBoundingClientRect();
        return {top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                h: r.height, w: r.width}; };
      const col = q('.dsapp-chat-col'), comp = q('.dsapp-composer');
      const slot = q('#chat-confirm_slot'), stop = q('#chat-stop_slot');
      return {
        col: R(col), bar: R(q('.dsapp-output-bar')),
        scroll: R(q('.dsapp-chat-scroll')),
        confirm: R(slot), stop: R(stop),
        // 结构判据：是不是**后代**，不是"看起来在那儿"
        confirmInCol: !!(col && slot && col.contains(slot)),
        stopInCol: !!(col && stop && col.contains(stop)),
        confirmInComposer: !!(comp && slot && comp.contains(slot)),
        stopInComposer: !!(comp && stop && comp.contains(stop)),
        // 结构判据：在**滚动区外面**（否则内容一长就跟着滚走了）
        confirmInScroll: !!(q('.dsapp-chat-scroll') &&
                            q('.dsapp-chat-scroll').contains(slot)),
        confirmCls: slot && slot.querySelector('button')
                    ? slot.querySelector('button').className : '',
        stopCls: stop && stop.querySelector('button')
                  ? stop.querySelector('button').className : '',
      };
    }""")

    chk("item2 ★ 确认执行在输出框（.dsapp-chat-col）**里面**",
        g3["confirmInCol"], g3)
    chk("item2 ★ 停止也在输出框里面", g3["stopInCol"], g3)
    chk("item2 ★ 两颗都**不在**输入区里了（用户原话：不应该在那儿）",
        not g3["confirmInComposer"] and not g3["stopInComposer"], g3)
    chk("item2 ★ 它们在滚动区**外面**（消息再长也不会被顶出屏幕）",
        not g3["confirmInScroll"], g3)

    if g3["bar"] and g3["col"] and g3["scroll"]:
        chk("item2 ★ 动作条紧贴输出框下沿（差值 < 2px）",
            abs(g3["bar"]["bottom"] - g3["col"]["bottom"]) < 2,
            "bar.bottom=%.1f col.bottom=%.1f" %
            (g3["bar"]["bottom"], g3["col"]["bottom"]))
        chk("item2 ★ 动作条在消息区**下面**（不是浮在上面）",
            g3["bar"]["top"] >= g3["scroll"]["bottom"] - 1,
            "bar.top=%.1f scroll.bottom=%.1f" %
            (g3["bar"]["top"], g3["scroll"]["bottom"]))
        if g3["confirm"] and g3["stop"]:
            chk("item2 两颗按钮**同一排**（中线差 < 6px）",
                abs((g3["confirm"]["top"] + g3["confirm"]["h"] / 2) -
                    (g3["stop"]["top"] + g3["stop"]["h"] / 2)) < 6, g3)

    # 灰着的时候：没有待确认的代码、也没有在跑的东西
    chk("item2 待确认方案时是灰的（.dsapp-btn-run-off）",
        "dsapp-btn-run-off" in g3["confirmCls"], g3["confirmCls"])
    chk("item2 没东西可停时「停止」也是灰的",
        "dsapp-btn-run-off" in g3["stopCls"], g3["stopCls"])

    # 输出框得真是个**框** —— 不然"框内部"这个词没有意义
    box = pg.evaluate("""() => {
      const c = document.querySelector('.dsapp-chat-col');
      const s = getComputedStyle(c);
      return {border: s.borderTopWidth, style: s.borderTopStyle,
              radius: s.borderRadius};
    }""")
    chk("item2 输出框有一圈看得见的边框（'框内部'才有意义）",
        box["style"] != "none" and float(box["border"].replace("px", "")) >= 1, box)

    # =====================================================================
    # 消息真的滚在**输出框内部**，而不是把整页撑开
    # =====================================================================
    inner = pg.evaluate("""() => {
      const s = document.querySelector('.dsapp-chat-scroll');
      return {ovf: getComputedStyle(s).overflowY,
              canScroll: s.scrollHeight - s.clientHeight};
    }""")
    chk("item1 消息区自己有一条滚动条（4 轮长消息，够撑出滚动）",
        inner["ovf"] in ("auto", "scroll") and inner["canScroll"] > 50, inner)

    # 树没断的证据：消息区的高度 = 输出框高度 - 动作条高度
    if g3["col"] and g3["bar"] and g3["scroll"]:
        want = g3["col"]["h"] - g3["bar"]["h"] - 2   # 上下各 1px 边框
        chk("item1 ★ 消息区拿到的正是'分剩下的'高度（flex 链没断）",
            abs(g3["scroll"]["h"] - want) < 3,
            "scroll.h=%.1f 期望≈%.1f" % (g3["scroll"]["h"], want))

    pg.screenshot(path=C.OUT + "/02_output_box.png", full_page=False)
    br.close()

sys.exit(chk.done())
