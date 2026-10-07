#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.7 item 2 的浏览器验收：**切会话不中断 + 多会话并行**。

用户原话：「我发现切换会话时会中断思考，需要多个会话任务能够同时执行，
并支持用户在会话间切换时不中断」。

自检把 pump_run() 从源码里抠出来、在塞满替身的沙箱里真跑了一遍（"非当前
对话那一拍一次界面都不许碰"）。**但那些替身正是界面本身** —— 它们证明的是
"该调用的调了、不该调用的一次没调"，证明不了：

  · 切走之后那个对话**真的还在跑**（子进程、泵、收尾、落库这一整条）
  · 切回来**真的看得见**它已经吐出来的正文（`show_run()` 那一笔重画）
  · 两个对话**真的同时在跑**（两个 callr 子进程、两条 SSE、两条库写入）
  · 后台那个跑完**真的没动**用户正看着的转圈

四节：
  A 切走不中断：新建对话之后，A 那一轮照样跑完并落库
  B 切回来：还在跑的那个对话，切回去当场看得到已经吐出的正文，并且继续长
  C 并行：A 在跑的时候在 D 里发消息**不被拦**，D 立刻开始吐字，两条都落库
  D 收尾互不干扰：A（后台）跑完的那一刻，D（当前）的转圈还在、正文还在长

⚠️ 铁律（都是本仓栽过的，别"顺手简化"）：
  · 新账号第一次进对话页有 `ensure_no_modal()` 那个弹窗挡点击。
  · 「等一行出现」写成「查得到行」= 没等 —— 一律轮询到条件成立。
  · 界面断言之外**必须回库确认**：只查界面分不清"没写进去"和"没画出来"。
  · 一条出网请求都不许打到真厂商 —— 每节结束断言 `fx.req_n()` 涨了。
  · 一次运行写一个日志；本脚本的产物都在 $DSAPP_TEST_OUT 下。

⚠️ 这一节需要**并发**的假服务端：tests/fake_llm.py 这一版刚从单线程的
   TCPServer 换成 ThreadingTCPServer（见那边的注释）。不换的话第二条请求
   要等第一条流完才被 accept —— "并行"那一节量到的是串行，而且两边都
   正常出字，**不报错**。

用法：
    bash tests/ui_v7/make_instance.sh 8930 /tmp/dsapp_v158
    python3 tests/ui_v157/probe_v157c.py
"""
import json
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8930/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_v158_out")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
# ⚠️ ensure_no_modal 住在 probe_v157.py 里，别在这儿抄一份（抄一份就会
#    出现两个版本，改了一边另一边不知道）。
from probe_v157 import ensure_no_modal                  # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


# =============================================================================
# 正文（每一条回复用一个**记号**：标题是从用户第一句话取的，所以记号只许
# 出现在回复里，不许出现在用户消息里 —— 否则侧栏的标题会把断言弄成假绿）
# =============================================================================

def mk_body(mark, n):
    return ["%s第%d段。" % (mark, i + 1) +
            "这是一段用来把气泡撑长的占位正文，里面没有代码块。" * 2
            for i in range(n)]


def mk_sse(mark, n):
    """一条**分块**的 SSE 应答：每段一个 delta.content。

    ⚠️ 分块是必须的：整段一次性发出去的话，一个 200ms 轮询周期就收完了，
    "流式期间"没有任何采样点 —— 切走/切回这些动作全都落在流**之后**，
    量的东西和想量的东西不是一回事（假绿）。
    """
    def chunk(o):
        return "data: " + json.dumps(o) + "\n\n"

    s = ""
    for p in mk_body(mark, n):
        s += chunk({"choices": [{"delta": {"content": p},
                                 "finish_reason": None}]})
    s += chunk({"choices": [{"delta": None, "finish_reason": "stop"}]})
    return s + "data: [DONE]\n\n"


# =============================================================================
# 小工具
# =============================================================================

def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def msgs(db, sid, role=None):
    q = ("SELECT id, content FROM messages WHERE session_id = ?"
         + (" AND role = ?" if role else "") + " ORDER BY id")
    a = (sid, role) if role else (sid,)
    return sql(db, q, a)


def assistant_hits(db, sid, mark):
    """这个对话里，正文含 mark 的 assistant 消息（id, 字数）。"""
    return [(r[0], len(r[1] or "")) for r in msgs(db, sid, "assistant")
            if mark in (r[1] or "")]


def wait_assistant(db, sid, mark, timeout=90):
    """轮询到"这个对话里落了带记号的回复"为止。**不是**查一次就算等过。"""
    end = time.time() + timeout
    while time.time() < end:
        if assistant_hits(db, sid, mark):
            return True
        time.sleep(0.5)
    return False


def active_sid(page):
    try:
        return page.evaluate(
            "() => { var e = document.querySelector('.dsapp-sess.active');"
            " return e ? (e.getAttribute('data-sid') || '') : ''; }")
    except Exception:
        return ""


def wait_active_sid(page, timeout=20, not_sid=None):
    """轮询到侧栏真的有了"当前对话"为止，返回那个 sid（超时给 ''）。

    ⚠️⚠️ 不能 `send()` 完立刻读一次就断言 —— 会话行是**服务端异步建出来
       再重画侧栏**的，那一刻 `.dsapp-sess.active` 还不存在，读到的是 ''。
        第一版就是这么假的红：正文都在往外流了，断言却说"没有对话号"。
        和「等一行出现」写成「查得到行」是同一个坑（本仓栽过）。

    ⚠️ `not_sid` 是给"刚点了新建对话"那种场合的：那一刻**旧对话还是
       active**（高亮要等服务端画完才搬过去），只等"有个 s- 开头的号"
       会当场拿到旧的那个，后面的 `sid_b != sid_a` 就成了假的红。
    """
    end = time.time() + timeout
    while time.time() < end:
        s = active_sid(page)
        if s.startswith("s-") and s != not_sid:
            return s
        page.wait_for_timeout(200)
    return active_sid(page)


def guard(page, timeout=6):
    """点任何东西**之前**过一遍：那个「AI 怎么干活？」弹窗会**晚到**。

    ⚠️⚠️ 它不是开页面时弹的，是 `dsapp_chat_send()` 里发完第一条消息之后
        才 `showModal()` 的（mod_chat.R:1508，挂在"所有闸门之后"）——
        所以进对话页那次 `ensure_no_modal()` 看到的当然是"没有弹窗"。
        等到第二次点击（新建对话）时它已经盖在整页上了，Playwright 报的是
        `<div id="shiny-modal"> intercepts pointer events`，
        **报错指向被点的那颗按钮**，和真正的原因隔着十万八千里。

    只认这一个已知弹窗；别的照旧炸出来（不顺手 Escape —— 那会连想测的
    东西一起关掉）。返回 True 表示这次关掉了一个。
    """
    end = time.time() + timeout
    while time.time() < end:
        btn = page.locator("#chat-agent_pref_manual")
        if btn.count():
            btn.first.click()
            page.wait_for_timeout(1200)
            return True
        if (page.locator("#shiny-modal:visible").count() == 0
                and page.locator(".modal-backdrop:visible").count() == 0):
            return False
        page.wait_for_timeout(250)
    return False


def click_sess(page, sid, wait=900):
    guard(page)
    el = page.locator('.dsapp-sess[data-sid="%s"]' % sid)
    el.first.click()
    page.wait_for_timeout(wait)


def new_chat(page):
    guard(page)
    page.click("#chat-new_chat")
    # 列表要重画（sess_ver），当前项高亮跟着走。等"当前项真的换了"而不是
    # 等一个固定时长 —— 固定时长在机器被挤的时候会提前返回。
    page.wait_for_timeout(300)


def send(page, text):
    guard(page)
    page.fill("#chat-input", text)
    page.wait_for_timeout(250)
    page.click("#chat-send")


def ans_len(page):
    """**最后一条 assistant 气泡**的字数。

    ⚠️ 必须取最后一个：querySelector 拿的是第一条（可能是历史里的），
    量它等于什么都没量。而且它同时覆盖"历史气泡"和"正在流的那一个"
    （两者的 DOM 结构一样，见 output$streaming 和 output$history）。
    """
    try:
        return page.evaluate(
            "() => { var b = document.querySelectorAll("
            "'.dsapp-msg-assistant .dsapp-bubble');"
            " return b.length ? b[b.length - 1].innerText.length : 0; }")
    except Exception:
        return -1


def where_text(page, needle):
    """这段字**画在哪个元素上**？返回一句人类可读的描述（没找到就空串）。

    ⚠️ 为什么要它：`"贝塔" not in page.inner_text("body")` 只回答"在不在"。
       red 的时候，报出来的东西分不清两种完全不同的情况 ——
         · 落进**侧栏会话列表**（那一栏本来就显示每个对话的摘要，不算漏）
         · 落进**当前对话的消息区**（那就是 item 2 要防的"后台的字画到别人
           身上"，是真 bug）
       两者的修法一个在探针、一个在产品，判据必须自己说清是哪一种。
    """
    try:
        return page.evaluate(
            """(needle) => {
                var hits = [];
                document.querySelectorAll('body *').forEach(function (el) {
                    if (el.children.length) return;          // 只看叶子
                    if ((el.textContent || '').indexOf(needle) < 0) return;
                    var p = el, path = [];
                    while (p && p !== document.body) {
                        path.unshift(p.tagName.toLowerCase() +
                                     (p.id ? '#' + p.id : '') +
                                     (p.className && typeof p.className === 'string'
                                      ? '.' + p.className.trim().split(/\\s+/).join('.')
                                      : ''));
                        p = p.parentElement;
                    }
                    hits.push(path.slice(-4).join(' > '));
                });
                return hits.slice(0, 3).join(' | ');
            }""", needle)
    except Exception as e:
        return "<探针自己出错：%s>" % str(e)[:120]


def wait_ans_len(page, timeout=60, minlen=1):
    """轮询到"最后一条 assistant 气泡有字"为止。"""
    end = time.time() + timeout
    while time.time() < end:
        n = ans_len(page)
        if n >= minlen:
            return n
        page.wait_for_timeout(200)
    return ans_len(page)


def wait_grow(page, was, timeout=30):
    """轮询到"字数比 was 多"为止（正文真的在继续长）。"""
    end = time.time() + timeout
    while time.time() < end:
        n = ans_len(page)
        if n > was:
            return n
        page.wait_for_timeout(300)
    return ans_len(page)


def wait_shrink(page, was, timeout=20):
    """轮询到"最后一条 assistant 气泡的字数比 was 少"为止。

    切走之后当前对话的画面上不该留着上一个对话的正文 —— 但那一笔是
    服务端重画出来的，**不能按固定时长等**（等 800ms 然后一量，
    机器慢的时候量到的还是旧画面，报出来是"没清掉"，其实是"还没画完"）。
    """
    end = time.time() + timeout
    while time.time() < end:
        n = ans_len(page)
        if n < was:
            return n
        page.wait_for_timeout(200)
    return ans_len(page)


def streaming_now(page):
    """当前这个画面上有没有"正在生成"的标志（那颗不闪的光标）。"""
    try:
        return page.locator(".dsapp-cursor").count() > 0
    except Exception:
        return False


def notes(page):
    try:
        return page.evaluate(
            "() => [].slice.call(document.querySelectorAll('.shiny-notification'))"
            ".map(function (e) { return (e.innerText || '').trim(); })")
    except Exception:
        return []


def clear_notes(page):
    try:
        page.evaluate(
            "() => { document.querySelectorAll('.shiny-notification')"
            ".forEach(function (e) {"
            "  var b = e.querySelector('.shiny-notification-close');"
            "  if (b) b.click(); else e.remove(); }); }")
    except Exception:
        pass
    page.wait_for_timeout(300)


def req_delta(fx, n0, what, timeout=30):
    """等假服务端的请求计数**真的涨上去**，再报。

    ⚠️⚠️ 原来是"立刻看一眼"。两处调用点前面那句 `wait_ans_len(page)` 的判据是
       「最后一条 assistant 气泡有字」—— 切回一个**已经答过一轮**的对话时，
       那条旧答案就在屏幕上，于是它**立刻**返回，而这一轮的请求还没发出去，
       delta 恒为 0。2026-10-01 18:14 和 10-02 11:16 两次跑都红在同一条，
       不是偶发。

       症状在另一处调用点上完全不同：C 节前面隔着好几个动作，等它测的时候
       请求早发出去了，于是**绿**。同一个根因，一处红一处绿 —— 只修红的那处
       会把 C 节那条假的绿永远留着。
    """
    end = time.time() + timeout
    d = fx.req_n() - n0
    while d <= 0 and time.time() < end:
        time.sleep(0.2)
        d = fx.req_n() - n0
    chk("（前提）%s：假服务端真的收到了请求（没打到真厂商）" % what, d > 0,
        "等了 %d 秒，req_delta 还是 %d" % (timeout, d))
    return d


# =============================================================================
# 四节
# =============================================================================

def main():
    fx = C.FakeLLM()
    # 队列**按到达顺序**发：谁先发请求谁拿第 1 条。
    #   ① 阿尔法 —— A 的第一条（切走时正在跑的那一轮）
    #   ② 贝塔   —— A 的第二条（切回来那一节）
    #   ③ 伽马   —— C 节里 A 的第三条（先发 → 先拿 → 短，先跑完）
    #   ④ 德尔塔 —— C 节里 D 的那一条（后发 → 长，A 跑完时它还在跑）
    # ⚠️⚠️ 贝塔（A 的第二条）和伽马（A 的第三条）**必须比探针自己那几段等待长**。
    #    原来是 45 段 × 150ms = 6.75 秒，而 B 节从"切到 C"到"切回 A"之间光固定
    #    等待就有 1.5 秒 + 清空轮询，撞上机器慢一点就超过 6.75 秒 —— 于是
    #    "切回来之后正文还在继续长"量到 2556 → 2556（流早跑完了），红的却是
    #    那条断言。2026-10-02 11:33 那次就是这么红的。
    #    现在 140 段 × 150ms = 21 秒：探针自己怎么磨蹭都还在流。
    fx.set_queue(mk_sse("阿尔法", 40), mk_sse("贝塔", 140),
                 mk_sse("伽马", 90), mk_sse("德尔塔", 90))
    fx.slow(0.15)
    print("  假 LLM: %s（4 条队列：40/140/90/90 段，每块 150ms）" % fx.url,
          flush=True)

    res = {}
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        email = "v157c_%s@example.com" % str(int(time.time()))[-6:]
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            sys.exit("注册没进去：%s" % e)
        uid, db = C.seed_or_die(email)
        print("  uid=%s  db=%s" % (uid, db), flush=True)
        C.seed_llm(uid, fx.url)
        # ⚠️ 必须 reload：base_url/Key 是会话级读一次进内存的，不 reload 的话
        #    这个会话手里还是老值（空 base_url → 厂商默认地址 → **真厂商**）。
        from probe_v157 import relogin
        relogin(page, email)
        C.goto(page, "chat")
        ensure_no_modal(page)
        page.wait_for_timeout(1200)

        # ---- A 节：切走不中断 -------------------------------------------------
        print("\n== A 节：切走之后 A 那一轮照样跑完 ==", flush=True)
        clear_notes(page)
        n0 = fx.req_n()
        send(page, "第一条：请写一份完整的分析报告。")
        sid_a = wait_active_sid(page)
        chk("A 节（前提）：发出第一条消息之后有了一个真实的对话号",
            sid_a.startswith("s-"), "sid_a=%r" % sid_a)
        L = wait_ans_len(page, timeout=60)
        chk("A 节（前提）：A 的正文真的在往外流（不是一拍就完）", L > 0,
            "字数=%d" % L)
        req_delta(fx, n0, "A 节")

        new_chat(page)
        sid_b = wait_active_sid(page, not_sid=sid_a)
        chk("★★ 新建对话真的换了一个对话号", sid_b != sid_a and sid_b.startswith("s-"),
            "A=%s B=%s" % (sid_a, sid_b))
        # 切走之后，画面上不该再留着 A 的正文（draft 被换成 B 那一份）
        after = wait_shrink(page, L, timeout=20)
        chk("★★ 切走之后画面上不再显示 A 的正文", after < L,
            "切走前 %d 字，切走后 %d 字" % (L, after))
        chk("★★ 切到 B 之后「正在生成」的标志也没了（B 上没有东西在跑）",
            not streaming_now(page))
        # ★ 核心：A 那一轮在**没人看着**的情况下跑完了，并且落了库
        ok = wait_assistant(db, sid_a, "阿尔法", timeout=90)
        chk("★★★ A 切走之后仍然跑完了（库里有那条带记号的回复）", ok,
            "库里 assistant：%r" % (msgs(db, sid_a, "assistant")[:1],))
        chk("★★★ 那 40 段**一段不少**地落进了库（不是收了一半就丢）",
            bool(assistant_hits(db, sid_a, "阿尔法")) and
            "阿尔法第40段" in msgs(db, sid_a, "assistant")[-1][1],
            "末段在不在=%s" % ("阿尔法第40段" in msgs(db, sid_a, "assistant")[-1][1]))
        chk("★★ A 那一轮的正文**一个字节都没画进 B**（没污染当前这个对话）",
            "阿尔法" not in page.inner_text("body"))
        chk("★★ B 自己的库里一条消息都没有（用户没在 B 里发过东西）",
            msgs(db, sid_b) == [], "B 的消息=%r" % (msgs(db, sid_b),))
        res["A_sid"] = sid_a

        # ---- B 节：切回来看得见已经吐出来的正文 ------------------------------
        print("\n== B 节：切回一个还在跑的对话，看得见已经吐出的正文 ==", flush=True)
        click_sess(page, sid_a)
        back = wait_active_sid(page, timeout=10)
        chk("B 节（前提）：切回了 A", back == sid_a, "当前=%r" % back)
        n1 = fx.req_n()
        send(page, "第二条：接着说。")
        L1 = wait_ans_len(page, timeout=60)
        chk("B 节（前提）：A 的第二次正文开始流了", L1 > 0, "字数=%d" % L1)
        req_delta(fx, n1, "B 节")

        # 切到一个**新建的**对话（C），再从那里切回还在跑的 A
        new_chat(page)
        sid_c = wait_active_sid(page, not_sid=sid_a)
        page.wait_for_timeout(1500)     # 让 A 在后台多吐一会儿
        # ★★ A 在后台吐的字**不许**画进 C（item 2 的核心）。
        #
        # ⚠️⚠️ 判据要**轮询到"没有"为止**，不能切过去瞥一眼。切对话是
        #    "换对象（use_run）+ 照着这一份重画（show_run）"两步，而
        #    `wait_active_sid()` 认的是**第一步**（会话号变了）—— 第二步
        #    还没落地时，`#chat-streaming` 里留着的是上一个对话的正文。
        #    原来写的是「等 1500ms 再看」：撞上就是一条假红，而且**
        #    只在这一节红**（A 节同样的检查前面挂了 wait_shrink、C 节隔了好
        #    几个动作，都躲过去了），看着像"B 节特有的 bug"。
        #    现在改成量**多久清干净**：清得掉就是切换的正常延迟（把秒数
        #    打出来，供以后判断是不是变慢了）；一直清不掉才是真漏。
        #
        # ★ 2026-10-02 12:00 量过了（/tmp/probe_lat.py，三条 24 秒的长流，
        #   各切一次）：点下去 **0.47/0.57/0.50 秒** 落地（侧栏高亮换过去），
        #   而"落地那一刻起旧正文还挂在屏幕上"是 **0.01/0.00/0.01 秒** ——
        #   也就是说用户看得见的那段延迟**只有点击往返那半秒**，切换本身
        #   是干净的。所以这里给 6 秒足够宽：真漏了（像论坛那次）6 秒一定
        #   还挂着，而正常的半秒不会被误判。
        _t0 = time.time()
        while time.time() - _t0 < 6:
            if not where_text(page, "贝塔"):
                break
            page.wait_for_timeout(150)
        where_b = where_text(page, "贝塔")
        _dt = time.time() - _t0
        chk("★★ 在 C 里看不到 A 正在吐的正文（后台的字不许画到当前对话上）",
            not where_b,
            "等了 %.1f 秒仍然画在 %s" % (_dt, where_b))
        if not where_b:
            print("    切到 C 之后 %.2f 秒内清干净（这段延迟是重画的正常开销）"
                  % _dt, flush=True)
        click_sess(page, sid_a)
        L2 = ans_len(page)
        chk("★★★ 切回还在跑的 A：**当场看得见**它已经吐出来的正文（不是空白）",
            L2 > 0, "切回来量到 %d 字" % L2)
        L3 = wait_grow(page, L2, timeout=40)
        chk("★★★ 切回来之后正文还在继续长（那一轮没被切走掐掉）", L3 > L2,
            "%d → %d" % (L2, L3))
        ok = wait_assistant(db, sid_a, "贝塔", timeout=120)
        chk("★★★ A 的第二轮也跑完了、落了库", ok)
        chk("★★ 落库的正文是**整段**（140 段全在）",
            bool(assistant_hits(db, sid_a, "贝塔")) and
            "贝塔第140段" in msgs(db, sid_a, "assistant")[-1][1])
        chk("★ C 里始终没有 A 的消息（那是个空对话）", msgs(db, sid_c) == [],
            "C 的消息=%r" % (msgs(db, sid_c),))

        # ---- C 节：并行 -------------------------------------------------------
        print("\n== C 节：A 在跑的时候，D 里照样能发、两边同时在跑 ==", flush=True)
        click_sess(page, sid_a)
        n2 = fx.req_n()
        send(page, "第三条：再跑一轮。")
        L4 = wait_ans_len(page, timeout=60)
        chk("C 节（前提）：A 的第三条开始流了", L4 > 0, "字数=%d" % L4)
        # ★ A 还在跑的时候，新建 D 并发一条 —— 这一条在 item 2 之前会被
        #   「这个对话正在生成中」挡回去（闸门问的是全局的 rv$streaming）。
        new_chat(page)
        sid_d = wait_active_sid(page, not_sid=sid_a)
        clear_notes(page)
        a_done_before = bool(assistant_hits(db, sid_a, "伽马"))
        chk("C 节（前提）：发 D 这一条的时候，A 那一轮**还没**跑完（否则并行是假的）",
            not a_done_before)
        send(page, "第四条：另起一个任务。")
        page.wait_for_timeout(600)
        chk("★★★ 在 D 里发消息**没有被**「正在生成中」挡回去",
            not any("正在生成中" in x for x in notes(page)),
            "通知=%r" % (notes(page),))
        d_user = [r for r in msgs(db, sid_d, "user")]
        chk("★★★ 那句用户消息真的落进了 D 的库（不是只画在界面上）",
            len(d_user) == 1, "D 的用户消息=%r" % (d_user,))
        req_delta(fx, n2, "C 节（两条请求都到了）")
        L5 = wait_ans_len(page, timeout=60)
        chk("★★★ D 立刻开始吐字了（不用等 A 跑完）", L5 > 0, "字数=%d" % L5)

        # 等 A（后台）跑完 —— 在 D 正流着的时候
        a_ok = wait_assistant(db, sid_a, "伽马", timeout=90)
        chk("★★★ A（后台那个）跑完并落了库", a_ok)
        chk("★★★ A 跑完的那一刻，D **还在流**（两条真的同时在跑）",
            streaming_now(page) or ans_len(page) > L5,
            "光标=%s 字数=%d→%d" % (streaming_now(page), L5, ans_len(page)))
        # ---- D 节：后台收尾不许动当前这个 ------------------------------------
        L6 = wait_grow(page, ans_len(page), timeout=40)
        chk("★★★ 后台跑完没有把当前这个的正文掐掉（切回来之后还在长）",
            L6 > L5, "%d → %d" % (L5, L6))
        chk("★★ A（后台）的正文没画进 D", "伽马" not in page.inner_text("body"))
        d_ok = wait_assistant(db, sid_d, "德尔塔", timeout=120)
        chk("★★★ D 那一轮也跑完了、落了库", d_ok)
        chk("★★★ D 落库的是整段（90 段全在）",
            bool(assistant_hits(db, sid_d, "德尔塔")) and
            "德尔塔第90段" in msgs(db, sid_d, "assistant")[-1][1])
        chk("★★ 最后画面上显示的是 D 的正文（不是 A 的）",
            "德尔塔" in page.inner_text("body"))

        # ---- 收尾：一个对话的回复不许跑进另一个对话 --------------------------
        print("\n== 汇总：三条回复各归各的对话 ==", flush=True)
        by_sid = {sid_a: ["阿尔法", "贝塔", "伽马"], sid_b: [], sid_c: [],
                  sid_d: ["德尔塔"]}
        bad = []
        for sid in by_sid:
            for other_sid, other_marks in by_sid.items():
                if other_sid == sid:
                    continue
                for m in other_marks:
                    # ⚠️ 查的是 **sid 自己** 有没有装着别人的话术。
                    #    写成 `assistant_hits(db, other_sid, m)` 的话，问的就成了
                    #    「别人有没有它自己那条回复」—— 恒真，于是**每一个**有
                    #    期待值的对话都被判成串门（2026-10-01 18:14 那次红的
                    #    就是这个：A 和 D 各被自己那几条话术告了一状，
                    #    而 B/C 期待值是空的，反倒一次都没被点名）。
                    if assistant_hits(db, sid, m):
                        bad.append("%s 里出现了 %s 的回复" % (sid, m))
        chk("★★★ 四个对话的回复没有串门（每条只落在自己那个对话里）",
            not bad, "；".join(bad))
        res["sids"] = {"A": sid_a, "B": sid_b, "C": sid_c, "D": sid_d}
        res["req_n"] = fx.req_n()

        page.screenshot(path=os.path.join(C.OUT, "v157c_final.png"),
                        full_page=False)
        browser.close()
    fx.stop()
    print("\n  话术：A=%s" % res.get("sids"), flush=True)
    return _chk.done()


if __name__ == "__main__":
    sys.exit(main())
