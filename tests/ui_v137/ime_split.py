# -*- coding: utf-8 -*-
"""V13.7 item 4（输入法）与 item 1（可拖拽处的边界）。

用户原话：
  item 4：「经常输入的是汉语，但是放到对话框里变成拼音了」
  item 1：「可拉动调整界面大小的地方都太不明显了，请做一个明显的边界」

★ 两条都必须用真浏览器：

  item 4 的根因是 **composition 事件**。它不是我们代码里的一个分支，而是
  浏览器/输入法在组字期间派发的一串真实事件（compositionstart →
  若干 input → compositionend），而且回车选字时那个 keydown **照样带着
  key === "Enter"**。离线断言里根本没有 composition 这个概念，写不出来。

  item 1 是**渲染结果**。CSS 的伪元素（::before / ::after）压根不在 DOM 里，
  只能靠 getComputedStyle 去问浏览器。

★ item 4 的判据为什么用「设置弹窗」当信号：

  这个账号故意**不配 API Key**。于是「发送路径真的被走到了」这件事有一个
  确定的、不依赖网络的证据：闸门弹出「还不能开始对话」。反过来，如果
  回车被组字守卫吃掉了，就什么都不会发生。
  既有区分度，又不用真的发一次 LLM 请求。

⚠️ 本脚本里凡是引号，一律用「」。这个仓库已经栽过两次：往 Python / R 的
   字符串字面量里写全角引号，会被规整成 ASCII 引号，当场把外层字符串截断，
   报出来的是语法错误，而眼睛看到的是一句通顺的中文注释。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, seed_or_die     # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 组字期间 textarea 里的「内容」—— 没上屏的拼音，正是用户报的那个东西。
PINYIN = "nihao"

# 对话页上的四条把手。五条里的最后一条（任务页）在下面单独看。
HANDLES = [
    (".dsapp-rail-handle", "col-resize"),
    (".dsapp-sess-handle", "col-resize"),
    (".dsapp-split-v",     "col-resize"),
    (".dsapp-split-h",     "row-resize"),
]


def probe_handles(page):
    """把每条把手的**静止态**（没 hover、没聚焦、没拖动）读回来。"""
    return page.evaluate("""(sels) => {
      var out = [];
      sels.forEach(function (s) {
        var el = document.querySelector(s);
        if (!el) { out.push({sel: s, missing: true}); return; }
        var cs  = getComputedStyle(el);
        var bef = getComputedStyle(el, "::before");
        var aft = getComputedStyle(el, "::after");
        var r   = el.getBoundingClientRect();
        out.push({
          sel: s, missing: false,
          cursor: cs.cursor,
          w: Math.round(r.width), h: Math.round(r.height),
          /* 线（::before）：常驻可见 = 有一个真的背景色 */
          lineBg: bef.backgroundColor,
          /* 把手（::after）：常驻可见 = 有背景色 **且** opacity 大于 0 */
          gripBg: aft.backgroundColor, gripOpacity: aft.opacity,
          gripW: aft.width, gripH: aft.height
        });
      });
      return out;
    }""", [s for s, _c in HANDLES])


def is_painted(bg):
    """background-color 是不是「真的看得见」。

    transparent / rgba(0,0,0,0) 都算看不见。⚠️ 不能只比字符串
    "rgba(0, 0, 0, 0)"：同一件事不同浏览器的写法不一样（有的给
    transparent、有的给全零 rgba），比字面量会漏判。
    """
    if not bg or bg == "transparent":
        return False
    if bg.startswith("rgba"):
        parts = bg[bg.index("(") + 1:bg.index(")")].split(",")
        return len(parts) == 4 and float(parts[3]) > 0.01
    return True


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 1000})
    page = ctx.new_page()
    errs = []
    page.on("pageerror", lambda e: errs.append(str(e)))

    email = enter_app(page, nickname="输入法")
    seed_or_die(email)

    # =====================================================================
    print("\n== item 1：五条把手在**静止态**就得看得见 ==", flush=True)
    # =====================================================================
    # ★ 用户报的是「太不明显」。所以判据必须是**静止态**下的表现 ——
    #   原来那版是「常驻全透明、hover 才显一条色带」，拿 hover 去测的话，
    #   旧代码照样全绿，等于什么都没测。
    #
    # ⚠️ 页面宽度 1500，刻意高于 app.css 里那个 @media (max-width: 1100px)：
    #    窄屏下两条分隔条是 display: none（两栏叠起来了，拖也没用），
    #    在那种宽度上量到的是 0×0 的矩形，报出来的失败会指向完全错误的地方。
    goto(page, "chat", wait=4000)
    hs = probe_handles(page)

    for i, (sel, want_cursor) in enumerate(HANDLES):
        h = hs[i]
        chk("（前置）%s 在页面上" % sel, not h.get("missing"))
        if h.get("missing"):
            continue
        chk("★ %s 静止态就有边界线（不是 hover 才出现）" % sel,
            is_painted(h["lineBg"]),
            extra="::before 的背景是 %r" % (h["lineBg"],))
        chk("★ %s 静止态就有把手" % sel,
            is_painted(h["gripBg"]) and float(h["gripOpacity"] or 0) > 0.01,
            extra="::after bg=%r opacity=%r" % (h["gripBg"], h["gripOpacity"]))
        chk("★ %s 的光标告诉用户这儿能拖" % sel,
            h["cursor"] == want_cursor, extra="光标是 %r" % (h["cursor"],))
        chk("★ %s 有够大的可点面积（太细拖不准）" % sel,
            min(h["w"], h["h"]) >= 5, extra="%dx%d" % (h["w"], h["h"]))
        chk("（前置）%s 的把手画出来了（6px 胶囊那一档）" % sel,
            h["gripW"] and h["gripH"], extra="%rx%r" % (h["gripW"], h["gripH"]))

    # 五条里的最后一条在任务页。它和对话页那条结构一模一样（mod_tasks.R
    # 里写着「和对话页那条一模一样」），但**页面不同** —— 只测对话页的话，
    # 任务页那条漏掉样式照样全绿。
    goto(page, "tasks", wait=3500)
    t = page.evaluate("""() => {
      var el = document.querySelector('.dsapp-task-page > .dsapp-split-v');
      if (!el) return null;
      var bef = getComputedStyle(el, '::before');
      var aft = getComputedStyle(el, '::after');
      var cs  = getComputedStyle(el);
      return {lineBg: bef.backgroundColor, gripBg: aft.backgroundColor,
              gripOpacity: aft.opacity, cursor: cs.cursor,
              w: Math.round(el.getBoundingClientRect().width)};
    }""")
    chk("★★ 任务页那条分隔条也在页面上", t is not None, extra=repr(t))
    chk("★★ 而且它同样常驻可见（线 + 把手都画出来了）",
        t is not None and is_painted(t["lineBg"]) and is_painted(t["gripBg"]) and
        float(t["gripOpacity"] or 0) > 0.01, extra=repr(t))
    chk("★ 光标也是 col-resize", t is not None and t["cursor"] == "col-resize",
        extra=repr(t))
    chk("★ 量到的宽度是真的 6px（不是被 display:none 藏掉的 0）",
        t is not None and t["w"] >= 5, extra=repr(t))

    goto(page, "chat", wait=3500)

    # =====================================================================
    print("\n== item 4：组字期间的回车是「选字上屏」，不是发送 ==", flush=True)
    # =====================================================================
    # ⚠️ 这几条**不用** page.keyboard：Playwright 的键盘走的是浏览器的真实
    #    输入管线，CDP 会带着真实的 composing 状态替我们把组字结束掉，
    #    构造不出「候选窗还开着、拼音还在框里」这个中间态。所以直接派发带
    #    isComposing 的 KeyboardEvent —— 我们要问的正是「收到这样一个事件时
    #    应用怎么办」，而那正是用户输入法实际派发的东西。
    #
    # ⚠️ 所有事件都必须 bubbles: true：app.js 里这两个监听器都挂在 document
    #    上（组字标志还是**捕获阶段**），不冒泡就一个都到不了。
    def compose_start():
        page.evaluate("""(v) => {
          var b = document.querySelector('#chat-input');
          b.focus();
          b.value = v;
          b.dispatchEvent(new CompositionEvent('compositionstart',
                            {bubbles: true, data: v}));
          b.dispatchEvent(new Event('input', {bubbles: true}));
        }""", PINYIN)

    def compose_end(text):
        page.evaluate("""(t) => {
          var b = document.querySelector('#chat-input');
          b.value = t;
          b.dispatchEvent(new CompositionEvent('compositionend',
                            {bubbles: true, data: t}));
          b.dispatchEvent(new Event('input', {bubbles: true}));
        }""", text)

    def key(k, keycode, composing):
        page.evaluate("""(o) => {
          var b = document.querySelector('#chat-input');
          b.dispatchEvent(new KeyboardEvent('keydown',
            {key: o.k, code: o.k, keyCode: o.c, isComposing: o.i,
             bubbles: true, cancelable: true}));
        }""", {"k": k, "c": keycode, "i": composing})

    def has_prompt():
        """「还不能开始对话」那个闸门弹窗**此刻可见**吗。

        ⚠️ 不能写成 `page.inner_text(".modal-content")`：那个选择器取的是
        **第一个**匹配。弹过一次再关掉之后，那个 .modal 还留在 DOM 里
        （Bootstrap 只是把它 display:none），文字还在 —— 于是"刚弹过一个"
        和"现在正弹着"读出来一模一样，上面每一条断言都会假绿。
        所以逐个 modal 看它**自己**是不是被藏起来了。
        """
        return page.evaluate("""() => {
          var ms = document.querySelectorAll('.modal');
          for (var i = 0; i < ms.length; i++) {
            var cs = getComputedStyle(ms[i]);
            if (cs.display === 'none' || cs.visibility === 'hidden') continue;
            var c = ms[i].querySelector('.modal-content');
            if (c && c.innerText.indexOf('还不能开始对话') >= 0) return true;
          }
          return false;
        }""")

    def dismiss():
        """把闸门弹窗关掉，并**确认**它真的关了。

        ⚠️ 少了这一步，弹窗自带的那层 backdrop 会把后面每一次点击都吃掉 ——
        item 4c 就是这么假绿的：4b 在变异版里弹了窗，4c 那一下根本没点到
        按钮上，于是"没发出去"看着像守卫生效，其实什么都没发生。
        """
        page.evaluate("""() => {
          var b = Array.prototype.filter.call(
            document.querySelectorAll('.modal button'),
            function (x) { return x.textContent.indexOf('稍后再说') >= 0; })[0];
          if (b) b.click();
        }""")
        page.wait_for_timeout(900)
        page.evaluate("""() => {
          Array.prototype.forEach.call(
            document.querySelectorAll('.modal-backdrop'),
            function (e) { e.parentNode && e.parentNode.removeChild(e); });
          document.body.classList.remove('modal-open');
          document.body.style.removeProperty('overflow');
          document.body.style.removeProperty('padding-right');
        }""")
        page.wait_for_timeout(400)

    def box():
        return page.input_value("#chat-input")

    def sends():
        """发送路径被走到了几次。

        ★ 这是**纯客户端**的判据，当场就有。

        为什么必须有它：读弹窗要等服务端往返，而服务端处理这次发送时读的是
        `input$chat-input` —— 我们刚刚用 JS 直接塞进去的那个值，可能还在路上。
        那时候"没有弹窗"就分不清是「守卫拦住了」还是「守卫没拦住、但服务端
        看到的是空的」。这两个在界面上长得一模一样，而只有前者是对的。
        （变异验证里 4a / 4c 就是这么假绿的：把守卫整条删掉，它们照样绿。）

        dsappSetBusy(true) 只在两处被调用：Enter 的发送处理器、以及点发送
        按钮那个补视觉反馈的处理器 —— 两处都**只**在"这次操作要发消息"时
        才走得到。所以数它就是数"发送路径被走到了"。
        """
        return page.evaluate("() => window.__dsappSends")

    # 探针：把 dsappSetBusy 包一层来计数。装在切页之后、任何触发之前。
    page.evaluate("""() => {
      window.__dsappSends = 0;
      var orig = window.dsappSetBusy;
      window.dsappSetBusy = function (busy) {
        if (busy === true) window.__dsappSends += 1;
        return orig.apply(this, arguments);
      };
    }""")

    # ⚠️ compose_start/end 之后那 900ms：让服务端真的收到我们塞进去的值。
    #    少了它，后面所有"没弹窗"的判据都分不清是哪种"没弹窗"。
    SETTLE = 900

    # ---- 4a. 组字中敲回车：不能发出去，也不能把「上屏」吃掉 ---------------
    compose_start()
    page.wait_for_timeout(SETTLE)
    chk("（前置）组字中，框里确实放着没上屏的拼音 %r" % PINYIN,
        box() == PINYIN, extra=repr(box()))

    mark = sends()
    key("Enter", 13, True)
    page.wait_for_timeout(1500)

    chk("★★★ 组字中的回车**根本没走到发送路径**（发出去的就是拼音 —— "
        "用户报的就是这个）",
        sends() == mark, extra="发送路径被走了 %d 次" % (sends() - mark))
    chk("★★★ 界面上也什么都没发生（没弹闸门）",
        not has_prompt(), extra="框里是 %r" % (box(),))
    chk("★★★ 而且拼音还在框里（preventDefault 没把「选字上屏」吃掉 —— "
        "吃掉的话症状是「汉字怎么都打不出来」，更难查）",
        box() == PINYIN, extra=repr(box()))

    # ---- 4b. 只剩 keyCode === 229 这一条兜底时也得拦住 --------------------
    # ★ 先把组字结束掉，让 dsappComposing 归位 —— 否则拦下它的是那个标志，
    #   229 这一支根本没被走到（三个条件都在，等于一个都没测）。
    #   框里**故意留着拼音**：万一 229 那一支被删掉，"nihao" 就会真的发出去，
    #   这条断言当场变红。
    compose_end(PINYIN)
    page.wait_for_timeout(SETTLE)
    mark = sends()
    key("Enter", 229, False)
    page.wait_for_timeout(1500)
    chk("★★ 部分 Windows 输入法把 keyCode 报成 229 时，只靠这一条也拦得住",
        sends() == mark and not has_prompt(),
        extra="走了 %d 次，框里是 %r" % (sends() - mark, box()))
    dismiss()          # 万一弹了（变异版），别让 backdrop 吃掉下一节

    # ---- 4c. 组字中点「发送」按钮：这次点击作废 ---------------------------
    compose_start()
    page.wait_for_timeout(SETTLE)
    mark = sends()
    page.click("#chat-send", force=True)
    page.wait_for_timeout(1500)
    chk("★★★ 组字中鼠标点「发送」也不发（有输入法在 mousedown 那一刻才上屏，"
        "点下去会抢在 compositionend 前面）",
        sends() == mark and not has_prompt(),
        extra="走了 %d 次，框里是 %r" % (sends() - mark, box()))
    # ⚠️ 对照项：先确认这一下**真的点在了按钮上**。否则「没发出去」可能只是
    #    因为点歪了或被挡住了，那是另一回事（V13 item 5 那个「发送按钮点不着」）。
    chk("★ （对照）那个按钮是点得着的，不是「点不着所以没发」",
        page.evaluate("""() => {
          var b = document.querySelector('#chat-send');
          if (!b) return false;
          var r = b.getBoundingClientRect();
          var el = document.elementFromPoint(r.left + r.width/2,
                                             r.top + r.height/2);
          return !!(el && (el === b || b.contains(el) || el.contains(b)));
        }"""))

    # ---- 4d. 组字结束后必须能正常发送 ------------------------------------
    # ★ 没有这一条的话，「把发送整个禁掉」也能让上面三条全绿。
    dismiss()
    compose_end("你好")
    page.wait_for_timeout(SETTLE)
    mark = sends()
    key("Enter", 13, False)
    page.wait_for_timeout(2500)
    chk("★★★ 组字结束后回车照常走发送路径（守卫没把发送永久掐死）",
        sends() > mark, extra="走了 %d 次" % (sends() - mark))
    chk("★★★ 而且真的一路走到了服务端（闸门弹出来了）",
        has_prompt(), extra="框里是 %r" % (box(),))

    chk("★ 全程没有 JS 报错", not errs, extra=errs[:3])

    page.screenshot(path=OUT + "/ime_split.png", full_page=True)
    br.close()

sys.exit(chk.done())
