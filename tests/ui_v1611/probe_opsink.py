#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V16.11 item 2：**写操作的收口点到底收不收得住。**

item 2 的全部产出是一个环形日志（`window.dsappOpLog`，最近 500 条），
**不拦、不改、不排队** —— 真正拦下来是 item 4 的事，那一步要先把"哪些 input
算一个写操作"用真数据看清楚。

要证的两件事，缺一条这个收口点就是白装的：

  ① **它真的盖住了原生绑定。** 这是选 `sendInput` 而不是 `Shiny.setInputValue`
     的**唯一理由**：查 shiny.js（1.10.0）时看到 `ActionButtonInputBinding.subscribe`
     只做 `$el.data("val", val+1); callback(false);`，**压根不碰那个公开函数**；
     `Shiny.setInputValue`（:25431）只被本应用手写的 20 处命中。
     ⇒ B 段拿一个**计数差**来证：点一次原生按钮，收口点涨了，而
     `Shiny.setInputValue` **一次都没被调用**。这不是旁证，是判别性证据。
  ② **零行为改变。** 这个包装包在**每一个**按钮底下，一旦它吞掉或改动什么，
     症状是"某些按钮没反应" —— 那比没有补发严重得多。C 段拿一次完整的问答来证。

  P 段  前置：量的是**新版** app.js；页内包装真的装上了（没有 `__dsappWrapped`
        标记的话，下面每一条都在空转）
  A 段  四条原生路径都进日志：按钮点击 / 打字 / Enter / selectize
  B 段  ★★★ 判别性证据：原生按钮 → 收口点涨、`setInputValue` 计数**不涨**
  C 段  ★★★ 零行为改变：真发一条、假 LLM 真收到、回复真进 #chat-history
  D 段  静置 10 秒日志**不增长**（包装自己触发自己 = 自激，会把日志刷爆）
  E 段  ★★ 日志里**只有值的形状，没有值本身** —— 经过它的东西包括
        api_key 和入口页口令，那些绝不能落在一个谁都能 dump 的数组里

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    cp www/app.js www/app.css /tmp/dsapp_v158h/app/www/
    python3 tests/ui_v1611/probe_opsink.py
"""
import os
import re
import sys

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1611")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "ui_v158"))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import (ensure_no_modal, wait_idle, sql as db_sql,      # noqa: E402
                       send as send_wait)

chk = C.Chk()
os.makedirs(C.OUT, exist_ok=True)
CONS = []
MARK = "ZQ7MARKER"          # E 段用：一个绝不可能出现在别处的串
# ⚠️⚠️ C 段**必须**用自己的串。第一版 C 段复用了 MARK，而 A3（Enter 发送）
#    发的就是 MARK —— 于是"C 段真的发出去了吗"这条断言，在 A3 那一轮就已经
#    被满足了。**变异 M3 把发送路径整个废掉，C1 照样绿**，就是这么来的。
#    一个断言能被别的段落满足，它就不是在测自己那件事。
CSEND = "ZQ7CSEND"


def say(*a):
    print(*a, flush=True)


JS_SINK = """() => {
  var out = { err: null };
  try {
    var app = (window.Shiny && window.Shiny.shinyapp) || null;
    out.has_app  = !!app;
    out.wrapped  = !!(app && app.sendInput && app.sendInput.__dsappWrapped === true);
    out.has_orig = !!(app && app.sendInput && app.sendInput.__dsappOrig);
    out.n        = (window.dsappOpLog || []).length;
    out.last     = (window.dsappOpLog || []).slice(-6);
    out.sid_n    = window.__sid_n === undefined ? null : window.__sid_n;
    out.up       = window.dsappNet ? window.dsappNet.state : null;
  } catch (e) { out.err = String(e); }
  return out;
}"""


def sink(pg):
    try:
        st = pg.evaluate(JS_SINK)
    except Exception as e:
        st = {"err": "evaluate 抛了：%s" % str(e)[:200]}
    return st


def keys_since(pg, n0):
    """第 n0 条之后所有记录的 keys，拍平成一个列表。"""
    return pg.evaluate(
        "() => (window.dsappOpLog || []).slice(%d).map(r => (r.keys || []).join(' '))"
        % n0)


def click_safe(pg, sel, timeout=25000):
    """点之前**先收一次弹窗**。

    ⚠️⚠️ 那个「AI 怎么干活？」首选项弹窗是**后到**的：它在**第一条消息真的发出去
    之后**才弹（本地实测：发之前 `#shiny-modal` 是 0，发完 1.5 秒变 1）。
    所以"进页面时收一次"是不够的 —— 收的时候它还没出生。
    症状是本仓记过好几次的那个：click 报 `intercepts pointer events`，
    **报错指向被点的那个按钮本身**，看着像"按钮坏了"。
    ⚠️ 更阴的一点：`fill()` / `press()` / `evaluate()` **不做命中测试**，
    弹窗挡着也照样能过 —— 于是 A2/A3 全绿、只有 A4 那个 `click` 卡死，
    看起来像"勾选框有问题"。**动作类型不同，同一个遮挡的表现完全不同。**
    """
    ensure_no_modal(pg)
    try:
        pg.click(sel, timeout=8000)
    except Exception:
        ensure_no_modal(pg)
        pg.click(sel, timeout=timeout)


def hist(pg):
    try:
        return pg.inner_text("#chat-history")
    except Exception:
        return ""


def wait_hist(pg, needle, sec=90):
    import time
    t0 = time.time()
    while time.time() - t0 < sec:
        if needle in hist(pg):
            return True
        pg.wait_for_timeout(500)
    return False


with sync_playwright() as pw:
    br = pw.chromium.launch()
    pg = br.new_context(viewport={"width": 1440, "height": 900}).new_page()
    pg.on("console", lambda m: CONS.append("%-7s %s" % (m.type, m.text[:300])))
    pg.on("pageerror", lambda e: CONS.append("PAGEERR %s" % str(e)[:300]))
    fx = C.FakeLLM()
    try:
        # ================= P 段：前置 =================
        say("\n== P 段：先证明量的是新代码，而且包装真的装上了 ==")
        served = pg.request.get(C.URL + "app.js").text()
        chk("P1 ★★★ 正在服务的 app.js 里有 dsappOpWrapSendInput（量的是新代码）",
            "dsappOpWrapSendInput" in served and "__dsappWrapped" in served,
            "服务的那份没有新符号 —— 实例里是 rsync 快照，先 cp 过去")

        email = C.enter_app(pg)
        uid, _db = C.seed_or_die(email)
        C.seed_llm(uid, fx.url)
        # ⚠️⚠️ 种完**必须整页重载**：`state$base_url` 是会话开始那一刻从库里
        #    读一次就记牢的（R/mod_model.R 的 loaded_for()），而我们是先建号
        #    后种库 —— 不重载的话这一页发消息会落到**厂商的默认地址**上去
        #    （2026-10-02 真打出去过一条 401）。
        pg.reload(wait_until="domcontentloaded")
        back_ok = False
        for _ in range(120):
            pg.wait_for_timeout(1000)
            st = sink(pg)
            if pg.locator(".dsapp-shell").count() > 0:
                back_ok = True
                break
        chk("P2 种完重载之后回到了主界面", back_ok, "120 秒没进 shell")
        ensure_no_modal(pg)
        pg.wait_for_selector("#chat-input", timeout=30000)

        st = sink(pg)
        chk("P3 ★★★ sendInput 已经包上了（没有 __dsappWrapped 的话下面全在空转）",
            bool(st) and st.get("wrapped") is True,
            "wrapped=%r has_app=%r err=%r"
            % (st.get("wrapped"), st.get("has_app"), st.get("err")))
        chk("P4 原来的函数被留下来当 orig（卸得掉、也证明不是替换成了空函数）",
            bool(st) and st.get("has_orig") is True,
            "has_orig=%r" % (st.get("has_orig") if st else None))

        # ================= A 段：四条原生路径 =================
        say("\n== A 段：原生绑定（**不碰 Shiny.setInputValue** 的那一类）进不进日志 ==")

        # A1 原生按钮点击。空输入框也发 —— ActionButtonInputBinding 只做
        #    `$el.data("val", val+1); callback(false);`，跟内容无关。
        n0 = (sink(pg) or {}).get("n") or 0
        click_safe(pg, "#chat-send")
        pg.wait_for_timeout(1500)
        got = keys_since(pg, n0)
        chk("A1 ★★★ 点原生按钮（#chat-send）进了日志",
            any("chat-send" in g for g in got), "新增记录=%r" % (got,))
        # ★★ 键的**确切形状**：动作按钮在浏览器这一侧叫 `chat-send:shiny.action`，
        #    后缀是 `valueChangeCallback()` 拼上去的（shiny.js：`id + ":" + type`，
        #    而 ActionButtonInputBinding.getType 回 "shiny.action"）。
        #    服务端看到的是**切掉后缀**的 `chat-send` —— 切在
        #    `shiny:::applyInputHandlers()` 里（`strsplit(name, ":")[[1]][1]`）。
        #    ⇒ item 3 的 DSAPP_OPS 注册表按 input_id 对表时，**必须**先把
        #    冒号后面切掉，否则一个动作按钮都对不上，而且是静默对不上。
        #    这条断言就是钉住这个形状：Shiny 哪天换了写法，这里先红。
        chk("A1b ★★ 键的形状是 `chat-send:shiny.action=…`（冒号后缀，服务端才切掉）",
            any("chat-send:shiny.action=" in g for g in got),
            "新增记录=%r" % (got,))

        # A2 打字（textarea 的 input 事件）
        n0 = (sink(pg) or {}).get("n") or 0
        pg.fill("#chat-input", MARK + " 你好")
        pg.wait_for_timeout(1500)
        got = keys_since(pg, n0)
        chk("A2 ★★ 往输入框打字进了日志（TextareaInputBinding）",
            any("chat-input" in g for g in got), "新增记录=%r" % (got,))

        # A3 Enter 发送（keydown 那条路）
        n0 = (sink(pg) or {}).get("n") or 0
        pg.press("#chat-input", "Enter")
        pg.wait_for_timeout(2000)
        got = keys_since(pg, n0)
        chk("A3 ★★ Enter 发送进了日志",
            any("chat-send" in g for g in got), "新增记录=%r" % (got,))
        # ⚠️ 这一下会真的发出去一条消息（带 MARK），C 段要用的就是它。

        # A4 勾选类原生绑定。
        #
        # ⚠️ 计划里写的是「DT 勾选」，**本地换成了 checkbox**，理由写清楚：
        #    对话页上 `table.dataTable` 的数量是 **0**，其余几张 DT
        #    （文件页 / 任务页 / 管理页）都得先把数据种进去才有行可勾。
        #    而这一条要证的**类别**是一样的：DT 的选中和 checkbox 一样，都是
        #    注册在 `Shiny.inputBindings` 上的原生绑定，走
        #    `InputBatchSender.setInput`，**不碰 `Shiny.setInputValue`** ——
        #    这一点由 B 段那个计数差统一证明，不靠这一条。
        #    ⇒ DT 勾选本身**没验过**，别当成验过（tests/ui_v1611/README.md 里也记了）。
        #
        # ⚠️ 目标要挑**看得见**的：`#chat-model_pick` 那颗 selectize 的原生
        #    `<select>` 是 0x0（selectize 把它藏了），点它等于点一个视口外的
        #    元素 —— 本仓记过：那种情况下 mouse 事件**无人接收**，而
        #    `bounding_box()` 照样返回正数、全程不报错。
        bx = pg.locator("#chat-agent_mode")
        chk("A4 勾选框找得到而且**看得见**（0x0 的点了没人接）",
            bx.count() > 0 and bx.first.is_visible(),
            "count=%d visible=%r" % (bx.count(),
                                     bx.first.is_visible() if bx.count() else None))
        if bx.count() > 0 and bx.first.is_visible():
            n0 = (sink(pg) or {}).get("n") or 0
            click_safe(pg, "#chat-agent_mode")
            pg.wait_for_timeout(1500)
            got = keys_since(pg, n0)
            chk("A4b ★★ 勾选（CheckboxInputBinding）进了日志",
                any("agent_mode" in g for g in got), "新增记录=%r" % (got,))
            # 勾回去：agent_mode 开着会让后面 C 段那条消息走自动执行，
            # 时序全乱（这一条不是洁癖，是本仓"自动执行会把断言搅乱"的老账）。
            click_safe(pg, "#chat-agent_mode")
            pg.wait_for_timeout(1200)

        # ================= B 段：★ 判别性证据 =================
        say("\n== B 段：★★★ 判别性证据 —— 为什么收口点必须是 sendInput ==")
        # 把公开的 Shiny.setInputValue 换成计数器，**再点一次原生按钮**。
        # 如果收口点是 setInputValue，这里会看到计数涨；涨不了就说明这类点击
        # 根本不经过它 —— 那正是"选 sendInput"的全部理由。
        pg.evaluate("""() => {
          window.__sid_n = 0;
          var o = window.Shiny.setInputValue;
          window.Shiny.setInputValue = function () { window.__sid_n++; return o.apply(this, arguments); };
        }""")
        st0 = sink(pg)
        n0, sid0 = st0.get("n") or 0, st0.get("sid_n") or 0
        # ⚠️ 那个首选项弹窗是**后到**的（`ensure_no_modal` 当场查是查不到的，
        #    等一拍它就盖在整页上了），它会拦截**所有** click 并让报错指向
        #    被点的那个按钮本身。本仓记过好几次，这里再收一次。
        click_safe(pg, "#chat-send")
        pg.wait_for_timeout(2000)
        st1 = sink(pg)
        n1, sid1 = st1.get("n") or 0, st1.get("sid_n") or 0
        say("   原生按钮点一下：收口点 %d→%d，Shiny.setInputValue %d→%d"
            % (n0, n1, sid0, sid1))
        chk("B1 ★★★ 收口点涨了（原生按钮确实被它盖住）",
            n1 > n0, "收口点没涨：%d→%d" % (n0, n1))
        chk("B2 ★★★ 而 Shiny.setInputValue **一次都没被调用**",
            sid1 == sid0,
            "setInputValue 涨了 %d 次 —— 那这一条就不是判别性证据了"
            % (sid1 - sid0))

        # ================= C 段：零行为改变 =================
        say("\n== C 段：★★★ 包装有没有改变行为（真发一条，走假 LLM）==")
        # ⚠️ 先把 A 段那一轮**放干净**再取基准数：A3 的 Enter 也是真发消息，
        #    它的 LLM 请求可能还没到。不等的话 C2 数的那个"涨了"可能是 A3 的。
        wait_idle(pg, 90)
        pg.wait_for_timeout(1200)
        n_req = fx.req_n()
        try:
            n_before_send = db_sql(_db,
                                   "SELECT COUNT(*) FROM messages m"
                                   " JOIN sessions s ON s.id = m.session_id"
                                   " WHERE s.user_id = ? AND m.content LIKE ?",
                                   (uid, "%" + CSEND + "%"))[0][0]
        except Exception as e:
            n_before_send = -1
            say("   发前查库失败：%s" % str(e)[:120])
        pg.fill("#chat-input", "")
        pg.wait_for_timeout(500)
        ok = send_wait(pg, CSEND + " 这是一条正常消息")
        landed = wait_hist(pg, CSEND, 90)
        chk("C1 ★★★ 消息真的发出去了、回复真的进了对话区（没被包装吞掉）",
            landed, "90 秒没等到 CSEND 进 #chat-history（send_wait=%r）" % ok)
        # ★★★ 界面会骗人（本仓的账：画出来了不等于写进去了、写进去了不等于
        #     画出来了）。直接回库数：这一条在 messages 里有没有行。
        #     C 段真正要证的是"包装没把这次发送吞掉"，库里有行才是那个证据。
        #
        # ⚠️⚠️ **必须按本次运行的 uid 收口**。第一版写的是
        #     `WHERE content LIKE '%ZQ7CSEND%'`，不带用户 —— 而这个实例的库
        #     **跨轮次留着**，上一轮（基线）已经在库里留了一行 CSEND。
        #     于是变异把发送整个废掉之后，这条断言**照样绿**（数到的是上一轮
        #     那一行）。实测就是这么发生的：C1 红了、C2 红了，C1b 却是绿的。
        #     ⇒ 判据要写成"**发送前 0 条 → 发送后 1 条**"，同一个 uid 前后比。
        #     这样它只可能被**这一轮这一条**满足。
        def csend_rows():
            return db_sql(_db,
                          "SELECT COUNT(*) FROM messages m"
                          " JOIN sessions s ON s.id = m.session_id"
                          " WHERE s.user_id = ? AND m.content LIKE ?",
                          (uid, "%" + CSEND + "%"))[0][0]
        try:
            n_before, n_after = n_before_send, csend_rows()
        except Exception as e:
            n_before, n_after = -1, -1
            say("   查库失败：%s" % str(e)[:120])
        chk("C1b ★★★ 而且**库里真有这一行**（发送前 0 条 → 发送后 1 条，同一个 uid）",
            n_before == 0 and n_after == 1,
            "CSEND 行数 %r → %r（要 0 → 1；发送前不是 0 说明判据被别的东西满足了）"
            % (n_before, n_after))
        chk("C2 ★★ 这一轮只打了**假** LLM（证明没落到厂商地址）",
            fx.req_n() > n_req, "假 LLM 请求数没涨（%d→%d）" % (n_req, fx.req_n()))
        st = sink(pg)
        chk("C3 发消息这件事也在日志里（收口点没漏掉这一条）",
            bool(st) and any("chat-send" in " ".join(r.get("keys") or [])
                             for r in (st.get("last") or [])),
            "最近几条=%r" % (st.get("last") if st else None))

        # ================= D 段：静置不许增长 =================
        say("\n== D 段：静置 10 秒，日志**不许**自己涨（防自激）==")
        # 包装自己触发自己（比如 orig 里又调回包装、或者 $updateConditionals
        # 引起连锁）会把 500 条的环形刷爆，真出事的时候日志里全是垃圾。
        n0 = (sink(pg) or {}).get("n") or 0
        pg.wait_for_timeout(10000)
        n1 = (sink(pg) or {}).get("n") or 0
        chk("D1 ★★★ 静置 10 秒，日志长度没变（涨了 = 自激）",
            n1 == n0, "%d → %d（涨了 %d 条）" % (n0, n1, n1 - n0))

        # ================= E 段：只记形状，不记内容 =================
        say("\n== E 段：日志里只有值的**形状**，没有值本身 ==")
        dump = pg.evaluate("() => JSON.stringify(window.dsappOpLog || [])")
        chk("E1 ★★★ 刚才打进去的那**两**串字都不在日志里（只记形状）",
            MARK not in dump and CSEND not in dump,
            "日志里出现了输入内容 —— 经过它的还有 api_key 和口令")
        chk("E2 ★★ 对照：日志确实记了**长度/类型**（不是把 keys 记空了）",
            re.search(r"chat-input=s\d+", dump) is not None,
            "没有任何 chat-input=sNN 形状的记录 —— 那 E1 就是空送")
        chk("E3 日志条数在环形上限内（不会无限涨内存）",
            (sink(pg) or {}).get("n", 0) <= 500,
            "n=%r" % (sink(pg) or {}).get("n"))

        say("\n---- 浏览器控制台（收口那两句该在这里）----")
        for c in CONS[-25:]:
            say("   " + c)
        pg.screenshot(path=os.path.join(C.OUT, "opsink_C_sent.png"))
        br.close()
    finally:
        fx.stop()
sys.exit(chk.done())
