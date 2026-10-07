#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V16.1 里那两件**只有浏览器才看得见**的事（item 1 和 item 6）。

自检那一节（selftest.R 的「Test_V16.1：六件事」）扫的是源码，它只能证明
"写了"，证明不了"用户看得见"。这一份补的就是那一半。

── item 1 ──────────────────────────────────────────────────────────────────
用户原话：「"它刚才问了你一句 —— 在下面回它，或者点「继续」"这个框应该在
          对话框内部，提示词改为："补充点意见："」

判据三条，缺一条都不算做到：
  A1 提示语就是「补充点意见：」，而且**全页**再也找不到旧那句
     （旧那句在 UI 里还有一份"兜底"副本，最容易漏改）；
  A2 那个框在 **.dsapp-composer 里面**（`closest()` 不是 null）；
  A3 ★★ 而且看起来是**焊在一起的一整块**：它的下沿贴着主输入框的上沿、
     左右对齐。只把它挪进 DOM 而不管边距的话，中间会留一道缝、四个圆角
     两两相对 —— 那在用户眼里仍然是"两个框"。
  A4 回它一句真的发得出去（落库），发完框自己收起来。

── item 6 ──────────────────────────────────────────────────────────────────
用户原话：「我点确认执行，显示已有任务在执行，但是我看不到任何提示任务在
          执行的痕迹……不能影响我查当前对话的其它内容，或在其它界面的其它操作」

判据四条：
  B1 任务真的在跑的时候，对话框里有一颗浮标，而且写着任务号；
  B2 ★★ 它**不占版面**：把它 display:none 掉，对话滚动区和输入区的几何
     一个像素都不变（`position:absolute` 的直接后果）；
  B3 ★★ 它**不吃点击**：拿它中心点去做 elementFromPoint，命中的必须是
     它底下那个东西，不是它自己（`pointer-events:none` 的直接后果）；
  B4 任务结束之后它自己消失（一直挂着 = 又一次"看不到痕迹"的反面）。

── 铁律（本仓踩过的，写在每一处需要它的地方）─────────────────────────────
  · 新账号第一次进对话页有个首选项弹窗会把所有 click 吃掉 → ensure_no_modal()。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到条件成立，带上限。
  · 「发消息之前要验地址」：state$base_url 是**会话开始那一刻**读一次的，
    种完 LLM 设置必须 reload，否则请求会打到厂商默认地址上去。
  · 只查界面 = 分不清"没写进去"和"没画出来" → 判据一律回**库**里确认。
  · 隐藏元素的矩形是全 0 → 量几何之前先确认那个东西看得见。

用法（实例由 make_instance.sh 起，见 tests/ui_v161/README.md）：
    DSAPP_TEST_URL=http://127.0.0.1:8963/ DSAPP_TEST_APP=/tmp/dsapp_v161i/app \
      python3 tests/ui_v161/probe_v161.py
"""
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8963/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v161i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v161")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from _common import ensure_no_modal                     # noqa: E402

BAD = []
OLD_HINT = "在下面回它"
NEW_HINT = "补充点意见："
# 那段"跑起来要一会儿"的代码。8 秒是刻意的：浮标要在**任务正在跑**的时候
# 才看得到，太短的话轮询还没转完任务就结束了，报出来是"浮标没出现"。
SLOW_CODE = 'Sys.sleep(8)\ncat("busy-probe done\\n")'
NEEDLE = "busy-probe done"


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def bad(msg):
    BAD.append(msg)
    say("  ** %s **" % msg)


# ---------------------------------------------------------------- JS 片段
ASK = r"""
() => {
  var box  = document.querySelector('.dsapp-ask-box');
  var comp = document.querySelector('.dsapp-composer');
  var o = {found: !!box,
           hasAsk: !!(comp && comp.classList.contains('dsapp-has-ask')),
           oldHintOnPage: (document.body.innerText || '').indexOf('在下面回它') >= 0};
  var ta = comp ? comp.querySelector('textarea.form-control:not(.dsapp-ask-input)')
                : null;
  if (ta) {
    var q = ta.getBoundingClientRect();
    o.ta = {left: Math.round(q.left), right: Math.round(q.right),
            top: Math.round(q.top), bottom: Math.round(q.bottom),
            w: Math.round(q.width)};
  }
  if (box) {
    var r  = box.getBoundingClientRect();
    var st = window.getComputedStyle(box);
    o.rect = {left: Math.round(r.left), right: Math.round(r.right),
              top: Math.round(r.top), bottom: Math.round(r.bottom),
              w: Math.round(r.width), h: Math.round(r.height)};
    o.disp = st.display;
    o.vis  = st.visibility;
    o.inside = !!box.closest('.dsapp-composer');
    var h = box.querySelector('.dsapp-ask-hint');
    o.hint = h ? (h.innerText || '').replace(/\s+/g, ' ').trim() : null;
    o.hasInput = !!box.querySelector('textarea.dsapp-ask-input');
    var b = box.querySelector('.dsapp-btn-run');
    o.btn = b ? (b.innerText || '').replace(/\s+/g, ' ').trim() : null;
  }
  return o;
}
"""

BADGE = r"""
() => {
  var b  = document.querySelector('.dsapp-busy-badge');
  var sc = document.querySelector('.dsapp-chat-scroll');
  var cp = document.querySelector('.dsapp-composer');
  var geo = function (e) {
    if (!e) return null;
    var r = e.getBoundingClientRect();
    return {top: Math.round(r.top), h: Math.round(r.height),
            left: Math.round(r.left), w: Math.round(r.width)};
  };
  var o = {found: !!b, scroll: geo(sc), composer: geo(cp)};
  if (!b) return o;
  var r  = b.getBoundingClientRect();
  var st = window.getComputedStyle(b);
  o.rect = {x: Math.round(r.left), y: Math.round(r.top),
            w: Math.round(r.width), h: Math.round(r.height)};
  o.pos  = st.position;
  o.pe   = st.pointerEvents;
  o.disp = st.display;
  o.txt  = (b.innerText || '').replace(/\s+/g, ' ').trim();
  o.parent = b.parentElement
    ? (b.parentElement.className || b.parentElement.tagName) : null;
  if (sc) {
    var s = sc.getBoundingClientRect();
    o.overScroll = !(r.bottom <= s.top || r.top >= s.bottom);
  }
  if (o.rect.w > 0 && o.rect.h > 0) {
    var cx = o.rect.x + Math.floor(o.rect.w / 2);
    var cy = o.rect.y + Math.floor(o.rect.h / 2);
    var hit = document.elementFromPoint(cx, cy);
    o.hit = hit ? (hit.className || hit.tagName) : null;
    o.hitIsBadge = !!(hit && (hit === b || b.contains(hit)));
  }
  return o;
}
"""

def busy(pg):
    """这一轮生成还没结束吗？

    ⚠️ 用的是**和 tests/ui_v156 同一个判据**（发送键被禁用），不另起一套 ——
       两套判据不一致的话，"等它结束"和"判断它有没有开始"会打架，
       表现成偶发的一秒级抢跑（本仓的 fake-wait-is-not-a-wait）。
    """
    try:
        return pg.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def wait_ask(pg, want=True, timeout=60):
    """轮询到回答框的显隐**真的**变成想要的样子。

    ⚠️ 不写成"查得到 .dsapp-ask-box 这个节点" —— 它是**静态节点**（一直在
       DOM 里，靠 class 切显隐），那样写会立刻返回，量到的是一个 display:none
       的框：矩形全 0、inside 也照样为真，后面几条会以最误导的方式变绿。
    """
    end = time.time() + timeout
    last = None
    while time.time() < end:
        st = pg.evaluate(ASK)
        last = st
        vis = st.get("found") and st.get("disp") != "none" and \
            st.get("rect", {}).get("h", 0) > 0
        if vis == want:
            return st
        pg.wait_for_timeout(250)
    return last


def wait_badge(pg, want=True, timeout=60):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        st = pg.evaluate(BADGE)
        last = st
        vis = st.get("found") and st.get("disp") != "none" and \
            st.get("rect", {}).get("h", 0) > 0
        if vis == want:
            return st
        pg.wait_for_timeout(250)
    return last


def send(pg, text, timeout=120):
    ensure_no_modal(pg, timeout=3)
    pg.fill("#chat-input", text)
    pg.click("#chat-send")
    return wait_idle(pg, timeout)


def wait_idle(pg, timeout=120):
    """等到这一轮真的结束。见 _common 里的说明：提前返回 = 没等。"""
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:
        if busy(pg):
            break
        pg.wait_for_timeout(150)
    while time.time() < end:
        if not busy(pg):
            pg.wait_for_timeout(700)
            if not busy(pg):
                return True
        pg.wait_for_timeout(250)
    return False


def sec_a_askbox(pg, uid, db, fx):
    say("")
    say("=== ① 回答框：文案 + 在输入区里 + 真的焊在一起 ===")
    C.goto(pg, "chat")
    ensure_no_modal(pg)

    st = pg.evaluate(ASK)
    say("  没问话的时候：found=%s hasAsk=%s 旧文案在页面上=%s"
        % (st.get("found"), st.get("hasAsk"), st.get("oldHintOnPage")))
    # ⚠️ 这一条是"静态节点"的反面保险：如果哪天有人把它改成 renderUI 画，
    #    没问话时它压根不该在 DOM 里 —— 那属于另一种退化，先记下来。
    if not st.get("hasAsk"):
        ok = (not st.get("found")) or st.get("disp") == "none" or \
            st.get("rect", {}).get("h", 0) == 0
        if not ok:
            bad("没在问话，回答框却是显示着的（会挡住输入框）")

    # 让模型回一句"结尾是问号"的话 —— dsapp_asks_confirmation() 就是按这个判的。
    fx.set_queue(C.sse("数据我看到了，一共 3 组、每组 6 个样本。\n\n"
                       "要不要我先把这三组的批次效应校正掉再往下做？"))
    ok = send(pg, "先看看这份数据")
    if not ok:
        bad("这一轮没在时限内收尾，后面的判据可能都是时序噪声")

    st = wait_ask(pg, True, timeout=60)
    say("  问完之后：" + repr({k: st.get(k) for k in
                              ("found", "hasAsk", "hint", "inside", "disp")}))
    if not (st.get("found") and st.get("disp") != "none"
            and st.get("rect", {}).get("h", 0) > 0):
        bad("模型问了话，回答框没亮（用户要的「在下面回它」没有入口）")
        return

    # ---- A1 文案 ----------------------------------------------------------
    say("  提示语：%r" % st.get("hint"))
    if st.get("hint") != NEW_HINT:
        bad("提示语是 %r，用户要的是 %r" % (st.get("hint"), NEW_HINT))
    if st.get("oldHintOnPage"):
        bad("页面上还能找到旧那句「%s」" % OLD_HINT)
    if not st.get("hasInput"):
        bad("框里没有输入的地方（用户只能看，回不了）")

    # ---- A2/A3 位置 -------------------------------------------------------
    if not st.get("inside"):
        bad("这个框**不在** .dsapp-composer 里（用户要的是「在对话框内部」）")
    else:
        r, t = st.get("rect"), st.get("ta")
        say("  框：%s" % repr(r))
        say("  主输入框：%s" % repr(t))
        if not t:
            bad("找不到主输入框，没法量「是否焊在一起」")
        else:
            # 上下沿要对上（-1px 是 CSS 里那道"把缝收掉"的负边距）
            d_v = t["top"] - r["bottom"]
            d_l = abs(t["left"] - r["left"])
            d_r = abs(t["right"] - r["right"])
            d_w = abs(t["w"] - r["w"])
            say("  上沿差=%+d px  左差=%d  右差=%d  宽差=%d"
                % (d_v, d_l, d_r, d_w))
            if not (-3 <= d_v <= 1):
                bad("框的下沿和输入框的上沿差 %+d px —— 中间有缝，用户看到的是"
                    "「两个框」" % d_v)
            if max(d_l, d_r, d_w) > 2:
                bad("左右没对齐（左差 %d / 右差 %d / 宽差 %d）"
                    % (d_l, d_r, d_w))

    # ---- A4 回它一句真的发得出去 -----------------------------------------
    say("  %r 那颗按钮是：%r" % (NEW_HINT, st.get("btn")))
    mark = "PROBE_ASK_%d" % int(time.time())
    fx.set_queue(C.sse("好，那我先做批次校正。"))
    # ⚠️ 点之前再收一次弹窗。第一跑就栽在这儿：`.dsapp-ask-box` 那颗按钮
    #    「visible, enabled and stable」全都满足，却点不动 ——
    #    报的是 `<div id="shiny-modal"> … intercepts pointer events`，
    #    指向的是这颗按钮，而真正的原因是一个**后到的**弹窗（ensure_no_modal
    #    在进入对话页那一刻检查过一次，那时它还没出来）。
    #    ⚠️ 它只认那一个已知的首选项弹窗，遇到不认识的会直接把它的正文打出来
    #       然后退出 —— 那是刻意的（见 _common.py 里的说明），别改成"顺手
    #       Escape 一下"，那样会把自己想测的东西一起关掉。
    ensure_no_modal(pg, timeout=5)
    pg.fill(".dsapp-ask-input", mark)
    pg.wait_for_timeout(300)
    ensure_no_modal(pg, timeout=5)
    btn = pg.locator(".dsapp-ask-box .dsapp-btn-run")
    if not btn.count():
        bad("回答框里找不到发送按钮")
    else:
        btn.first.click()
        wait_idle(pg, timeout=120)
        hits = sql(db, "SELECT content FROM messages WHERE role='user' "
                       "AND content LIKE ?", ("%" + mark + "%",))
        say("  回完之后库里带这条标记的 user 消息：%d 条" % len(hits))
        if not hits:
            bad("回的那句话没进库（%r）—— 点发送什么都没发生" % mark)
        st2 = wait_ask(pg, False, timeout=30)
        if st2.get("found") and st2.get("disp") != "none" \
                and st2.get("rect", {}).get("h", 0) > 0:
            bad("回完之后回答框还亮着（用户会以为没发出去，再点一次）")


def sec_b_badge(pg, uid, db, fx):
    say("")
    say("=== ⑥ 任务在跑的时候，对话框里要有痕迹 ===")
    C.goto(pg, "chat")
    ensure_no_modal(pg)

    st = pg.evaluate(BADGE)
    if st.get("found") and st.get("rect", {}).get("h", 0) > 0:
        bad("还没跑任务，浮标就亮着")
        return

    # 先让模型给一段"跑起来要一会儿"的代码，再点「确认执行」。
    fx.set_queue(C.sse("好的，这段会跑 8 秒：\n\n```r\n%s\n```\n\n"
                       "跑完告诉我。" % SLOW_CODE))
    ok = send(pg, "跑一段慢的给我看看")
    if not ok:
        bad("这一轮没在时限内收尾（后面可能全是时序噪声）")
    runb = pg.locator(".dsapp-code-run")
    n = runb.count()
    say("  「确认执行」按钮：%d 颗" % n)
    if not n:
        bad("没有「确认执行」可点 —— 前提没成立，第 6 条**没验到**")
        return

    runb.first.click()
    st = wait_badge(pg, True, timeout=60)
    vis = st.get("found") and st.get("rect", {}).get("h", 0) > 0
    say("  任务跑起来之后：found=%s rect=%s pos=%r pe=%r"
        % (st.get("found"), st.get("rect"), st.get("pos"), st.get("pe")))
    say("        文字=%r  父节点=%r  压在滚动区上=%s"
        % (st.get("txt"), st.get("parent"), st.get("overScroll")))
    if not vis:
        bad("任务在跑，对话框里**看不到任何痕迹** —— 这正是用户报的那一件事")
        # 还是要等它跑完，别把后面几节留在一个半跑着的状态里
        pg.wait_for_timeout(12000)
        return

    # ---- B1 有任务号 ------------------------------------------------------
    if "任务" not in (st.get("txt") or ""):
        bad("浮标上没写是什么任务：%r" % st.get("txt"))
    if not st.get("overScroll"):
        bad("浮标**没有**压在对话区上（看着像另开了一块地方放它）")

    # ---- B2 不占版面 ------------------------------------------------------
    # ★★ 判据是**几何**，不是 position 这个字符串：把对话框的滚动区和输入区
    #    在"有浮标 / 浮标 display:none"两种状态下各量一次矩形的**高度**。
    #    absolute 的话两次一模一样；换成 static/relative 的话下面那块会被顶
    #    下去，高度当场变。
    #    ⚠️ 只查 computed style 里写着 "absolute" 是不够的 —— 那证明的是
    #       "CSS 写了"，用户关心的是"我的消息有没有被顶跑"。
    h1 = {"scroll": st.get("scroll"), "composer": st.get("composer")}
    pg.evaluate("() => { var b = document.querySelector('.dsapp-busy-badge');"
                " if (b) b.style.display = 'none'; }")
    pg.wait_for_timeout(200)
    st_hidden = pg.evaluate(BADGE)
    h0 = {"scroll": st_hidden.get("scroll"), "composer": st_hidden.get("composer")}
    pg.evaluate("() => { var b = document.querySelector('.dsapp-busy-badge');"
                " if (b) b.style.display = ''; }")
    pg.wait_for_timeout(200)
    say("  浮标在 / 浮标藏：滚动区 %s → %s ；输入区 %s → %s"
        % (h1["scroll"], h0["scroll"], h1["composer"], h0["composer"]))
    for k in ("scroll", "composer"):
        if h1[k] != h0[k]:
            bad("把浮标藏起来之后 %s 的几何变了（%s → %s）—— 它占了版面，"
                "用户正在看的消息会被顶跑" % (k, h1[k], h0[k]))

    # ---- B3 不吃点击 ------------------------------------------------------
    say("  浮标中心点命中的是：%r（是浮标自己吗：%s）"
        % (st.get("hit"), st.get("hitIsBadge")))
    if st.get("hitIsBadge"):
        bad("浮标把底下的东西挡住了（elementFromPoint 命中的是它自己）——"
            "它压着的复制按钮 / 链接会点不动")
    if st.get("pe") != "none":
        bad("computed 的 pointer-events 是 %r，不是 none" % st.get("pe"))

    # ---- B4 跑完自己消失 --------------------------------------------------
    end = time.time() + 60
    gone = False
    while time.time() < end:
        s = pg.evaluate(BADGE)
        if not (s.get("found") and s.get("rect", {}).get("h", 0) > 0):
            gone = True
            break
        pg.wait_for_timeout(500)
    say("  任务跑完之后浮标消失：%s" % gone)
    if not gone:
        bad("任务已经结束了，浮标还挂在上面 —— 那是另一种「看不到痕迹」")
    # 顺带回库确认这段代码**真的跑过**（不然上面量的可能是一个空壳浮标）。
    # ⚠️ 列名是 stdout / stderr，**没有** output 那一列 —— 第一跑就是照
    #    "output" 写的，最后一行抛 sqlite3.OperationalError，前面二十几条
    #    全绿的结果被一个收尾查询带崩了（退出码 1，看着像断言失败）。
    hits = sql(db, "SELECT id, status, length(stdout) FROM tasks "
                   "WHERE stdout LIKE ?", ("%" + NEEDLE + "%",))
    say("  库里写着 %r 的任务行：%s" % (NEEDLE, hits))
    if not hits:
        bad("库里没有跑出 %r 的任务行 —— 上面量的那个浮标背后没有真任务"
            % NEEDLE)


WATCH_NOTES = r"""
() => {
  /* ⚠️ 按**节点**记账，不是按文案去重（同 tests/ui_v161/probe_del.py 里那段
   *   说明）：按文案去重的话，同一句话第二次出现时它不记 —— 于是"这一次
   *   到底说没说"就量不出来了，而它报的是绿。 */
  window.__dsappNotes = [];
  window.__dsappNodes = [];
  var grab = function () {
    document.querySelectorAll('.shiny-notification').forEach(function (n) {
      var t = (n.innerText || '').replace(/\s+/g, ' ').trim();
      var i = window.__dsappNodes.indexOf(n);
      if (i < 0) {
        if (!t) return;
        window.__dsappNodes.push(n);
        window.__dsappNotes.push({t: t});
      } else if (t && window.__dsappNotes[i].t !== t) {
        window.__dsappNotes[i].t = t;
      }
    });
  };
  grab();
  if (window.__dsappNoteObs) window.__dsappNoteObs.disconnect();
  window.__dsappNoteObs = new MutationObserver(grab);
  window.__dsappNoteObs.observe(document.body, {childList: true, subtree: true,
                                                characterData: true});
  return true;
}
"""


def sec_c_unlimited_note(pg, uid, db, fx):
    """item 5 的后半句：「没上限模式可以先提醒下用户要不要设置」。

    ⚠️ 提醒是**每个会话只说一次**（mod_chat.R 的 unlim_noted），A/B 两节
       早就把它用掉了 —— 所以这一节必须先 reload 换一个 Shiny 会话，
       否则量到的是"没有提醒"，而那是我们自己造成的。
    ⚠️ 通知几秒后就自己消失，**轮询很容易整段错过** —— 这里挂一个
       MutationObserver 把出现过的每一条都记下来，等的是"记录里有没有"，
       而不是"此刻屏幕上有没有"。
    """
    say("")
    say("=== ⑤ 不设上限时，要有人告诉用户一声 ===")
    pg.reload(wait_until="domcontentloaded")
    C.wait_awake(pg)
    C.goto(pg, "chat")
    ensure_no_modal(pg)
    pg.evaluate(WATCH_NOTES)

    fx.set_queue(C.sse("好，我看看。"))
    send(pg, "随便聊聊")
    # 两个来源都要看：日志记的是"出现过"（通知几秒后自己消失，只查屏幕会
    # 整段错过），屏幕给的是"此刻还在"（只查日志则完全押在 Observer 上）。
    notes = pg.evaluate("() => (window.__dsappNotes || []).map(function (x) {"
                        " return x.t; })")
    live = pg.evaluate(
        "() => Array.from(document.querySelectorAll('.shiny-notification'))"
        ".map(function (n) {"
        " return (n.innerText || '').replace(/\\s+/g, ' ').trim(); })")
    for t in live:
        if t and t not in notes:
            notes.append(t)
    say("  这一轮出现过的通知 %d 条：" % len(notes))
    for t in notes:
        say("    · " + t[:100])
    hit = [t for t in notes if "不设上限" in t]
    if not hit:
        bad("默认就是不设上限，但**没有任何人告诉用户** —— 用户要求的是"
            "「没上限模式可以先提醒下用户要不要设置」")
    else:
        # ⚠️ 提醒里必须同时有"怎么收"和"什么还在兜底"。只说风险的那一版
        #    会把人吓到去设一个没必要的上限（见 mod_chat.R 里那段说明）。
        t = hit[0]
        if "自动结束时间" not in t:
            bad("提醒里没说怎么改：%r" % t[:120])
        if "停止" not in t and "兜底" not in t:
            bad("提醒里没说「其实还有东西在兜底」（只讲风险 = 吓人）：%r"
                % t[:120])


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        errs = []
        badres = []
        pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))
        # ⚠️ "Failed to load resource" 这类 console.error **不带 URL** —— 只报
        #    "有个东西 404 了"，看不出是哪一个。所以资源加载失败一律走下面
        #    那个 response 监听（它带 URL），console 那一侧把它滤掉，免得同
        #    一件事报两遍、而带 URL 的那一遍被不带 URL 的那一遍顶掉。
        pg.on("console",
              lambda m: errs.append("console." + m.type + ": " + m.text)
              if (m.type == "error"
                  and "Failed to load resource" not in m.text) else None)
        pg.on("response",
              lambda r: badres.append((r.status, r.url)) if r.status >= 400 else None)

        # ⚠️ 这里原来是 `pg.goto(C.URL + "app")` —— C.URL 是
        #    "http://127.0.0.1:8963/"，拼出来是 `/app`，而这个实例把应用
        #    挂在 `/` 上，于是它稳定 404。它本身无害（enter_app 马上会自己
        #    goto 一次），但它会**把资源检查那一条永远染红** —— 一条自己造
        #    出来的假问题盖住真问题，正是这个仓最怕的那种绿/红。
        #    要预热实例就照下面这么写：goto 那个真地址。
        pg.goto(C.URL, wait_until="domcontentloaded")
        C.enter_app(pg, C.EMAIL)
        C.wait_awake(pg)
        uid, db = C.seed_or_die(C.EMAIL)
        say("账号 uid=%s  实例 %s" % (uid, C.URL))

        fx = C.FakeLLM()
        line = C.seed_llm(uid, fx.url)
        if "=NA" in line:
            sys.exit("种 LLM 设置没写进去：%s" % line)
        say("假 LLM：%s" % fx.url)
        # ★★ 必须 reload：state$base_url 是**会话开始那一刻**读一次的。
        #    不 reload 的话这一轮会打到厂商默认地址上去（2026-10-02 真发生过）。
        pg.reload(wait_until="domcontentloaded")
        C.wait_awake(pg)

        sec_a_askbox(pg, uid, db, fx)
        sec_b_badge(pg, uid, db, fx)
        sec_c_unlimited_note(pg, uid, db, fx)

        # 资源加载失败：**带 URL 报**。favicon 是例外，而且只是 favicon ——
        # 浏览器会自作主张地来要一次 /favicon.ico，应用从来没承诺过这个文件
        # （www/ 里没有，也没有路由），它 404 是常态。除它以外任何一个
        # >=400 都是应用该修的东西，一个都不放过。
        skipped = [u for (s, u) in badres if u.endswith("/favicon.ico")]
        real = [(s, u) for (s, u) in badres if not u.endswith("/favicon.ico")]
        if skipped:
            say("  浏览器自己来要过 %d 次 /favicon.ico（404）—— 应用没承诺过"
                "这个文件，不算" % len(skipped))
        if real:
            bad("有 %d 个资源没加载出来：%s"
                % (len(real), ["%s %s" % (s, u) for (s, u) in real[:5]]))
        if errs:
            bad("浏览器报了 %d 条错，头一条：%s" % (len(errs), errs[0][:200]))
        say("  假 LLM 收到请求数：%s" % fx.req_n())
        fx.stop()
        pg.screenshot(path=os.path.join(C.OUT, "v161.png"), full_page=True)
        ctx.close()
        br.close()

    say("")
    if BAD:
        say("===== 红 %d 条 =====" % len(BAD))
        for m in BAD:
            say("  · " + m)
        sys.exit(1)
    say("===== 全绿 =====")


if __name__ == "__main__":
    main()
