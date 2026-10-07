# -*- coding: utf-8 -*-
"""Test_V15.7 item 1 的浏览器验收探针：**厂商拒了要说出来**。

    bash tests/ui_v7/make_instance.sh 8927 /tmp/dsapp_v157
    python3 tests/ui_v157/probe_v157.py

★ 这一版只有一条改动，探针只回答一件事：
    **厂商拒绝一次请求之后，用户看不看得见、刷新之后还在不在。**

  用户原话：「wchcpu2019@163.com这个账号依然是卡住的，任何操作都会引起页面
            不响应，帮我看下应该怎么解决这个问题。」
  查下来的真相：那个账号的 Key 被厂商**每一次**都拒
  （HTTP 429：余额不足或无可用资源包,请充值。），而这一类错误当时只在服务端
  内存里闪一下 —— 不弹通知、不落库。对话里剩下 4 条「继续」和 1 条「你好」，
  后面一条回复都没有。用户看到的就是"卡住"。
  （V15.5 item 7 只给**上下文类**错误修好了落库，见 tests/ui_v155/。）

  为什么自检不够：selftest.R 验的是**判据**（哪句话归哪一类、空错误返回 NULL）。
  "用户真的看见了"这件事只有这里验得了 —— 通知是 Shiny 弹的、那条消息是
  库里的，两样都在自检够不着的地方。本仓"自检全绿 ≠ 功能被验过"栽过两次。

三节：
  A. 手动模式：429 余额不足 → 通知当场弹 + 库里多一条说明 + **刷新之后还在**
  B. 自动执行模式：429 → agent 循环被停掉（不是挂在"一直在生成"上干等）
  C. 反面：一次**正常**回复不许冒通知、不许往对话里塞说明（防误报）

── 铁律（都是本仓踩过的，写在每一处需要它的地方）─────────────────────────
  · 新账号第一次进对话页有个首选项弹窗会把所有 click 吃掉
    （报 `intercepts pointer events`，指向的却是按钮本身）→ `ensure_no_modal()`。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到条件成立，带上限。
  · reload 之后 cookie 直进主界面 → `relogin()` 等的是"主界面或登录表单"，
    **不是**只认 `.dsapp-auth` 的 `wait_awake()`。
  · 只查界面 = 分不清"没写进去"和"没画出来" → 凡写操作都回库确认（`sql()`）。
  · 上一次动作留下的通知会被下一次 `wait_notification()` 当场命中 →
    每一节开头 `clear_notifications()`。
  · 断言必须**看着请求真的到了假服务端**（`fx.req_n()` 涨了）才算"没打到真厂商"。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402  （必须在 sys.path 之后）

from playwright.sync_api import sync_playwright  # noqa: E402


# =============================================================================
# 断言记账
#
# ⚠️ 为什么要自己包一层：`C.Chk` 只记"过了几条"，而这份报告要的是
#    「通过 N / 失败 M」。**不能改 _common.py**（别处的探针也在用它），
#    所以在外面数一遍。
# =============================================================================

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
# 小工具（照 tests/ui_v155/probe_v155.py 抄 —— 那些函数每一条注释都是
# 一次踩坑的记录，别在这里"顺手简化"）
# =============================================================================

def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ★ 探针里要 reload 的地方有两处：种完假 LLM、以及 A 节末尾验证"刷新之后
      说明还在"。`state$base_url / model` 是**会话级**的（mod_model 的
      observe 从库里读一次），不 reload 的话已经活着的那个会话手里还是老值
      —— 空 base_url → 厂商默认地址 → **真厂商**。这是本仓明令禁止的
      （见 _common.py 顶部那段）。

    ⚠️⚠️ **不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload 时
      cookie 还在，应用**直接进主界面**，登录页一帧都不出现。拿它等等于等
      一个永远不会来的东西：报出来的是「reload 之后 120 秒还是空白页」，
      而屏幕上其实早就是主界面了。所以等的是"两个可能里先到的那个"。
    """
    page.reload(wait_until="domcontentloaded")

    submitted = False
    for _ in range(180):
        if page.locator(".dsapp-shell").count():
            return
        if not submitted and page.locator("#welcome-email").count():
            page.fill("#welcome-email", email)
            page.fill("#welcome-password", C.PW)
            page.click("#welcome-do_login")
            submitted = True          # 只提交一次，别把失败刷成死循环
        page.wait_for_timeout(1000)
    page.screenshot(path=C.OUT + "/01_relogin_failed.png", full_page=True)
    sys.exit("reload 之后 180 秒回不到主界面（cookie 自动登录 + 表单登录都没成）\n"
             "  页面文字 %d 字" % len(page.inner_text("body")))


def ensure_no_modal(page, timeout=10):
    """把那个**只问一次**的「AI 怎么干活？」首选项弹窗关掉。

    ⚠️ 它是新账号第一次开对话时自己弹的（mod_chat.R 的 onboarding），盖在
      整页上 —— 有它在，点 `#chat-send` 会一直报
      「<div id="shiny-modal"> intercepts pointer events」，
      **报错指向的是"发送按钮点不动"**，和真正的原因（一个首选项弹窗）
      隔着十万八千里。

    选「都先别开，我自己盯着」（`agent_pref_manual`）是刻意的：探针要的是
    **一轮一问一答**，自动执行开着的话 agent 循环会自己往下跑，后面那些
    "发一条、断言一条"的时序全乱。B 节**不能**用这个函数收尾 ——
    见 `enable_agent_mode()`。

    ⚠️ 只处理这一个已知的弹窗。**出现别的弹窗要炸出来**，不要顺手 Escape
      —— 那样会把自己想测的东西一起关掉。
    """
    end = time.time() + timeout
    while time.time() < end:
        if page.locator("#shiny-modal:visible").count() == 0:
            if page.locator(".modal-backdrop:visible").count() == 0:
                return True
        btn = page.locator("#chat-agent_pref_manual")
        if btn.count():
            btn.first.click()
            page.wait_for_timeout(1500)
            continue
        page.wait_for_timeout(300)
    if page.locator("#shiny-modal:visible").count():
        txt = page.evaluate(
            "() => (document.querySelector('#shiny-modal')||{}).innerText || ''")
        sys.exit("页面上压着一个**不认识的**弹窗，探针不猜它是什么：\n%s"
                 % txt[:400])
    return True


def enable_agent_mode(page):
    """把「自动执行」勾上，并且**按用户的真实路径**答完那个首选项弹窗。

    ⚠️ 不能用 `ensure_no_modal()` 收尾：它点的是 `#chat-agent_pref_manual`
      （「都先别开」），那会 `updateCheckboxInput(agent_mode, FALSE)` ——
      刚勾上的开关会被**自己按回去**，后面那一节测的就成了"自动执行关着"，
      而它看起来和"循环停了"一模一样（同一个假绿形态）。

    勾上之后弹窗里 `pref_ask_auto` 预勾的是**当前** `input$agent_mode`，
    所以点 `#chat-agent_pref_save` 存下来的就是 auto = TRUE。
    """
    box = page.locator("#chat-agent_mode")
    if box.count() == 0:
        print("    ⚠️ 找不到 #chat-agent_mode（自动执行那颗勾）", flush=True)
        return False
    if not box.first.is_checked():
        # ⚠️ 三层退路：正常是 check()，它带可操作性检查（有的皮肤把
        #    checkbox 画成 0×0、靠旁边的假开关显示点击）—— 那种情况下
        #    check() 会等到超时。退到 click()、再退到直接发 Shiny 输入。
        try:
            box.first.check(timeout=8000)
        except Exception:
            try:
                box.first.click(force=True, timeout=5000)
            except Exception:
                page.evaluate("() => Shiny.setInputValue("
                              "'chat-agent_mode', true, {priority: 'event'})")
                print("    ⚠️ 那颗勾是直接发 Shiny 输入勾上的（不是点出来的）",
                      flush=True)
        page.wait_for_timeout(800)
    for _ in range(10):
        if page.locator("#chat-agent_pref_save").count():
            page.locator("#chat-agent_pref_save").first.click()
            page.wait_for_timeout(1500)
            break
        page.wait_for_timeout(300)
    end = time.time() + 10
    while time.time() < end and page.locator("#shiny-modal:visible").count():
        page.wait_for_timeout(300)
    chk_on = page.locator("#chat-agent_mode").first.is_checked()
    still = page.locator("#shiny-modal:visible").count()
    if still:
        print("    ⚠️ 首选项弹窗没关掉（还压着 %d 个），后面会点不动"
              % still, flush=True)
    return chk_on


def busy(page):
    """服务端说"这一轮还在跑"。"""
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(page, timeout=90):
    """等到这一轮真的结束。**不是**"等某个元素出现" —— 那种提前返回的写法
    会让后面的动作和服务端重画抢跑，报出来的错指向完全无关的地方
    （fake-wait-is-not-a-wait）。"""
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:
        if busy(page):
            break
        page.wait_for_timeout(150)
    while time.time() < end:
        if not busy(page):
            page.wait_for_timeout(600)   # 再稳一拍，避开"刚好在两轮之间"
            if not busy(page):
                return True
        page.wait_for_timeout(250)
    return False


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def enter_with_retry(browser):
    """注册进主界面，最多试 3 次。

    ⚠️ 为什么要重试：这几个测试实例上，`enter_app` 偶尔会在「注册完之后
      页面空白」那一关失败，而这**不是本版的回归** —— 2026-09-28 拿
      V15.2 那个实例做对照，同样失败。每一次 enter_app 都注册一个新账号，
      所以重试是安全的（不会撞邮箱）。
    """
    last = None
    for i in range(3):
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        try:
            C.enter_app(page, email="v157_%s_%d@example.com"
                        % (str(int(time.time()))[-6:], i))
            return page
        except SystemExit as e:
            last = e
            print("  ⚠️ 第 %d 次注册没进去，重来：%s" % (i + 1, str(e)[:120]),
                  flush=True)
            try:
                page.close()
            except Exception:
                pass
            time.sleep(3)
    sys.exit("连着 3 次都没注册进去，最后一次是：\n%s" % last)


def user_msg_n(db, uid):
    return sql(db, "SELECT COUNT(*) FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'user'", (uid,))[0][0]


def user_msg_ids(db, uid):
    """这个账号所有用户消息的 id（A 节要用"点发送之后新冒出来的那些"）。"""
    return [r[0] for r in sql(
        db, "SELECT m.id FROM messages m JOIN sessions s ON s.id = m.session_id"
            " WHERE s.user_id = ? AND m.role = 'user' ORDER BY m.id", (uid,))]


def last_assistant(db, uid):
    """这个账号**最新**的那条 assistant 消息（id, content）。

    ⚠️ 不查 `sessions` 的"最新会话"，直接按消息排 —— 中间要是新建过一个
      对话（比如某个动作悄悄开了新会话），按会话找会指向另一条对话，
      报出来的错会变成"库里没有那条说明"，和真正的原因（找错了地方）无关。
    """
    rows = sql(db, "SELECT m.id, m.content FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'assistant'"
                   " ORDER BY m.rowid DESC LIMIT 1", (uid,))
    return (None, "") if not rows else (rows[0][0], rows[0][1] or "")


def assistant_since(db, uid, mid):
    """id > mid 的 assistant 消息，按 id 升序。B 节用它数"新落了几条说明"。"""
    return sql(db, "SELECT m.id, m.content FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'assistant' AND m.id > ?"
                   " ORDER BY m.id", (uid, mid))


def notifications(page):
    """屏幕上所有 `.shiny-notification` 的文字。

    ⚠️ 取**全部**，不是第一个命中就下结论（本仓「grep | head 会截断」那条：
      在 Python 里就是"别只取第一个匹配"）。原因很实在：这一页上随时可能
      还挂着别的通知（比如答完首选项弹窗那句「记住了：…」，duration = 8 秒），
      只看第一条就会把"还没弹出来"和"弹了别的"混成一句话报出去。
    """
    try:
        return page.evaluate(
            "() => [].slice.call(document.querySelectorAll('.shiny-notification'))"
            ".map(function (e) { return (e.innerText || '').trim(); })")
    except Exception:
        return []


def clear_notifications(page):
    """把屏幕上已经挂着的 `.shiny-notification` 清掉，返回清掉的条数。

    ⚠️⚠️ 这一步**必须做**，不是打扫卫生：那条通知 `duration = NULL`
      （永不自动消失），而 B 节要在 A 节之后跑。不清的话 B 的
      `wait_notification()` 会**当场命中 A 留下的那条** —— 报出来的是
      "0.0 秒就弹了，完美"，而 B 那个 429 的通知可能压根没弹过。

    ⚠️ 直接摘节点，不点关闭按钮：`.shiny-notification-close` 有的皮肤里被
      藏掉/换了样式，点它会变成一条"点不动"的假红。
    """
    try:
        n = page.evaluate(
            "() => { var els = document.querySelectorAll('.shiny-notification');"
            " var n = els.length;"
            " for (var i = 0; i < els.length; i++) {"
            "   var p = els[i].parentNode; if (p) p.removeChild(els[i]); }"
            " return n; }")
        return n or 0
    except Exception:
        return 0


def wait_notification(page, needle, timeout=90):
    """轮询到某条通知里出现 needle。返回 (命中文本, 从调用起过了几秒)。

    ★ 为什么非要轮询：只查一次的话，服务端的 429 还没回来就查完了 ——
      报出来的是"没弹通知"，而真相是"查早了"（fake-wait-is-not-a-wait）。
    """
    t0 = time.time()
    end = t0 + timeout
    while time.time() < end:
        for t in notifications(page):
            if needle in t:
                return t, time.time() - t0
        page.wait_for_timeout(250)
    return None, time.time() - t0


def page_text(page):
    try:
        return page.inner_text("body")
    except Exception:
        return ""


def sel_value(page, sel):
    """读一个 <select> 的当前值。**不用 `input_value()`** —— 那个要过
    可操作性检查，而 selectize 把原生 select 藏成 0×0，会一路等到超时。"""
    try:
        return page.evaluate(
            "(s) => { var e = document.querySelector(s); return e ? e.value : null; }",
            sel)
    except Exception:
        return None


def set_target_kind(page, value):
    """把「硬件选择」切成 value（B 节要 "local"）。

    ★ 切「本地电脑」**不是为了跑代码**，是为了让循环真的进到"生成中"：
      `try_submit()` 在 local 那一支**不经过引擎**，写完一条 tool 消息就
      `a$state <- "generating"` + `begin_llm()`。于是第二个请求是在循环
      活着的时候撞上 429 的 —— 那才是要停的那个场景。
      默认的 server 那一支要真的起一个任务才推得下去（引擎、conda、几十秒），
      那是另一个量级的探针，而且会把这一节变脆。
    """
    try:
        C.pick_select(page, "chat-target_kind", value)
        page.wait_for_timeout(700)
    except Exception as e:
        print("    ⚠️ 点「硬件选择」没成：%s" % str(e)[:200], flush=True)
    if sel_value(page, "#chat-target_kind") == value:
        return True
    page.evaluate("(v) => Shiny.setInputValue('chat_target_kind', v,"
                  " {priority: 'event'})", value)
    page.wait_for_timeout(700)
    if sel_value(page, "#chat-target_kind") == value:
        print("    ⚠️ 「硬件选择」是直接发 Shiny 输入切的（不是点出来的）",
              flush=True)
        return True
    return False


def arm_after_first_req(fx, req_before, msg, status, timeout=20):
    """**看着第一条请求发出去**，然后才把错误挂上。返回 (挂上了吗, 秒)。

    B 节专用：那一条的用户消息**必须**换回一个 200（回复里有可执行代码块），
    否则循环压根不进运行态，"循环停了"就是一句废话 —— 新旧代码都会过。

    ⚠️⚠️ 而"第一条放行、第二条起全拒"这件事，假服务端的计数器**做不到**：
      `rejection()` 数的是**已经拒了几次**（tests/fake_llm.py:100
      `if read_int(REJ_STATE) >= times: return None`），预置成 n 得到的是
      "前 (times-n) 次被拒" —— 方向正好相反。所以只能看着 `req_n()` 涨了
      再挂。

    ★ 判据是请求**已经落盘**：fake_llm 先写 `req-XXXX.json`、**之后**才裁定
      要不要拒（tests/fake_llm.py:115-125）。所以这时候挂上的错误一定砸在
      **下一条**请求上，也就是循环推着发出来的那条。
    ⚠️ 前提是第一条的响应还在**慢放**（调用方先 `fx.slow()`）：不慢放的话，
      从"第一条到齐"到"循环发出第二条"只有一次 HTTP 往返，这个轮询会输掉，
      而输掉的样子和上面那个坑**一模一样**。
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        if fx.req_n() > req_before:
            fx.arm_400(msg, times=10, status=status)
            return True, time.time() - t0
        time.sleep(0.05)
    return False, time.time() - t0


_LOOP_WATCH_JS = r"""() => {
    if (window.__loopWatch) return window.__loopWatch;
    window.__loopWatch = {seen: false, text: null, n: 0};
    var re = /第\s*[0-9]+\s*\/\s*[0-9]+\s*轮/;
    var scan = function () {
        var els = document.querySelectorAll('.dsapp-ctrl-notes');
        for (var i = 0; i < els.length; i++) {
            var t = els[i].innerText || '';
            if (re.test(t)) {
                window.__loopWatch.seen = true;
                window.__loopWatch.text = t.slice(0, 120);
                window.__loopWatch.n += 1;
            }
        }
    };
    new MutationObserver(scan).observe(document.body,
        {childList: true, subtree: true, characterData: true});
    scan();
    return window.__loopWatch;
}"""


def install_loop_watch(page):
    """装上观察者（在点发送**之前**装）。

    ★★ 侧栏那枚「第 N/M 轮」徽章只在 `a$state != "idle"` 时存在，而
      **用户自己那一轮里 state 一直是 idle** —— 它第一次出现是在第一条回复
      落地、循环接手的那一刻，消失是在第二个请求撞上 429 的那一刻，中间只有
      一次 HTTP 往返（本地回环）。120ms 轮询去抓它，抓不到的样子和"循环压根
      没跑"一模一样。装个 MutationObserver 之后这件事变成**事件驱动**的。
    ⚠️ 观察 document.body 的子树，不是盯 `#chat-ctrl_notes` 自己：Shiny 的
      renderUI 会把那个容器**整个换掉**，盯在旧节点上的观察者跟着一起死。
    """
    try:
        return page.evaluate(_LOOP_WATCH_JS)
    except Exception as e:
        print("    ⚠️ 装循环观察者没成：%s" % str(e)[:200], flush=True)
        return None


def loop_watch(page):
    try:
        return page.evaluate("() => window.__loopWatch || null")
    except Exception:
        return None


def loop_state(page):
    """侧栏那枚徽章**现在**在不在。"""
    try:
        return page.evaluate(r"""() => {
            var el = document.querySelector('#chat-ctrl_notes');
            if (!el) return {found: false, text: null};
            var m = /第\s*[0-9]+\s*\/\s*[0-9]+\s*轮/.exec(el.innerText || '');
            return {found: !!m, text: (el.innerText || '').slice(0, 160)};
        }""")
    except Exception:
        return {"found": None, "text": None}


def loop_fired(db, uid, since_id):
    """循环**确实推过一轮**的耐久证据 —— 库里那条 tool 消息。返回 (bool, 说明)。

    ★ 判据是 R/agent.R 那一支写的内容（「执行结果 · 未执行」＋「本地电脑」）。
      它只在 `a$try_submit()` 里写，而 `try_submit()` 只有**循环接手之后**
      才会被调到（用户自己那一轮里 state 是 idle，走不到那儿）。
    ★ 为什么要它：徽章那次观测窗口只有一次 HTTP 往返，漏了是常态；这一条是
      **落在库里的**，等 30 秒也还在。
    """
    rows = sql(db, "SELECT m.id, m.content FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'tool' AND m.id > ?"
                   " ORDER BY m.id", (uid, since_id))
    hit = [r for r in rows if "未执行" in (r[1] or "")]
    return bool(hit), ("点了发送之后新增 tool 消息 %d 条，其中含「未执行」%d 条"
                       % (len(rows), len(hit)))


# =============================================================================
# 夹具
# =============================================================================

# ★ 用户报的那条 429，**一字不改**（包括那个半角逗号 —— 厂商就是这么发的）。
#   ⚠️ arm_400 收的是 message，外面那层 `{"error":{"message":…}}` 的壳由
#      fake_llm 自己套；纯文本的话界面上那句会带着 `{"error":{…}}` 的壳，
#      和厂商真实的样子不一样（tests/ui_v155 那条注释）。
_BAL_429 = "余额不足或无可用资源包,请充值。"

# 通知正文（R/models.R 的 dsapp_llm_error_advice，balance 那一格）：
#   "模型服务余额不足，这一次请求没有发出去。详见对话里那条说明。"
_NOTE_NEEDLE = "余额不足"

# 落库那条说明（R/models.R 的 dsapp_llm_error_advice，balance 那一格）：
#   "**这一次请求没能发出去：模型服务那边说账户余额不足。**\n\n厂商那边的原话是：\n\n> …"
_DB_NEEDLES = ["没能发出去", "余额不足", "请充值"]

# ★ 自动执行那一段的第一个请求**必须成功**，而且回复里要有一个可执行的
#   代码块 —— 否则循环压根不会进 running，后面"循环停了"就是一句废话。
#   这条回复的形状是按 dsapp_agent_pick_block() 的要求凑的：finish_reason
#   不能是 length、围栏要**闭合**、语言要在 R/Python/Bash 里、而且不能命中
#   扫描规则（`print("hello")` 哪一条都不沾）。
_CODE_REPLY = '这段先跑一下：\n\n```python\nprint("hello")\n```\n'


# =============================================================================
# A. 手动模式：429 余额不足 → 当场说 + 落库 + 刷新还在
# =============================================================================

def a_balance_error(page, uid, db, fx):
    print("\n== A. 手动模式：429 余额不足 → 通知 + 落库 + 刷新还在 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    n_old = clear_notifications(page)
    if n_old:
        print("    清掉屏幕上残留的通知 %d 条" % n_old, flush=True)

    # ★ 429 要**每一次**请求都回：这样"没有偷偷重试成功"才是真的被判过。
    #   times 给 10 —— 够盖住任何重试，也不至于让一个失控的循环无限跑下去。
    C.goto(page, "chat")
    fx.disarm_400()
    fx.arm_400(_BAL_429, times=10, status=429)

    n_user0 = user_msg_n(db, uid)
    ids0 = set(user_msg_ids(db, uid))
    mid0, _c0 = last_assistant(db, uid)
    req0 = fx.req_n()
    print("    点发送之前：用户消息 %d 条、最新 assistant id=%s、"
          "假 LLM 收到 %d 个请求" % (n_user0, mid0, req0), flush=True)

    # ---- 点发送。**从这里开始一条新消息都不许发** -------------------------
    page.fill("#chat-input", "这一条会撞上余额不足。")
    page.click("#chat-send")

    note, dt = wait_notification(page, _NOTE_NEEDLE, timeout=90)
    print("    通知：%r（%.1f 秒）" % ((note or "")[:160], dt), flush=True)

    chk("★★★ 点完发送**不用再发一条消息**，余额不足的通知就自己弹出来了",
        note is not None,
        "等了 90 秒没有；屏幕上的通知：%s" % notifications(page))
    chk("★★ 而且是**立刻**（30 秒内），不是等下一轮才说",
        note is not None and dt < 30, "%.1f 秒" % dt)

    # ★★ 前提：这一轮**真的问出去了** —— 也就是"没打到真厂商"的证明。
    #    少了这一条，一个"发送按钮坏了、什么都没发出去"的实现也会让
    #    下面那些"库里多了一条说明"的断言以别的方式红/绿得莫名其妙。
    chk("★★ 前提：这一轮真的问出去了（假服务端收到了请求 = 没打到真厂商）",
        fx.req_n() > req0, "点之前 %d 个请求，现在 %d 个"
        % (req0, fx.req_n()))

    # ★★ 用户消息恰好 +1：发送是"先落库、再出网"，429 拦的是出网那一步，
    #    用户那句话照样进对话。写成"一条都没多"会红在一个和被测代码无关的
    #    地方，而且看着特别像"这条消息没存上"。
    ids1 = set(user_msg_ids(db, uid))
    new_ids = sorted(ids1 - ids0)
    chk("★★ 出错这一轮里只多了我点发送的那**一条**用户消息"
        "（没有为了让错误冒出来而自动补发/重发）",
        len(new_ids) == 1, "新增用户消息 id：%s" % new_ids)

    # ---- 回库：当场多出一条说明 -------------------------------------------
    #
    # ★ 界面上的通知 `duration = NULL` 是**不落库的**，刷新就没了。用户说的
    #   「卡住」要真的顶用，必须有一条能刷新之后还在的东西 —— 代码里是合成
    #   一条 assistant 消息落库。所以这里**回库确认**（本仓铁律：写操作只看
    #   界面分不清"没写进去"和"没画出来"）。
    mid1, body = last_assistant(db, uid)
    if not (body and all(x in body for x in _DB_NEEDLES)):
        end = time.time() + 30
        while time.time() < end:
            mid1, body = last_assistant(db, uid)
            if body and all(x in body for x in _DB_NEEDLES):
                break
            page.wait_for_timeout(500)
    print("    库里最新 assistant id=%s，正文 %d 字：%r"
          % (mid1, len(body), body[:140]), flush=True)
    chk("★★★ 库里当场多出一条 assistant 说明，正文含「没能发出去」「余额不足」"
        "「请充值」（刷新之后也还在）",
        all(x in body for x in _DB_NEEDLES), "最新 assistant 正文 %r" % body[:300])
    # ⚠️ 判据是"比**我刚发的那条用户消息**还新"，不是"比出错前的上一条
    #    assistant 新" —— 新账号里压根没有上一条 assistant（mid0 是 None），
    #    写成 `mid1 > mid0` 会在一个和被测代码无关的地方红（第一轮就踩了）。
    chk("★★ 那条说明是**这一轮新落**的（id 比我刚发的那条用户消息还大 —— "
        "不是把某条旧消息读了一遍）",
        mid1 is not None and bool(new_ids) and mid1 > new_ids[0],
        "我刚发的用户消息 id=%s，说明的 id=%s" % (new_ids, mid1))

    ok = wait_idle(page, 60)
    chk("★ 出错之后界面回到不忙（发送键不再 disabled）", ok,
        "send_disabled=%s" % page.locator("#chat-send[disabled]").count())

    # ---- 刷新之后还在不在 -------------------------------------------------
    #
    # ★★ 这一条是 A 节里最接近"用户到底看见了什么"的一步：那条说明是
    #    **落库**的，所以刷新之后必须能从历史里画回来。前半段（通知）刷新就
    #    没了是设计如此，真正扛住"卡住"这个观感的是这一条。
    relogin(page, C.LAST_EMAIL)
    page.wait_for_timeout(1500)
    C.goto(page, "chat")
    page.wait_for_timeout(2500)
    ensure_no_modal(page, timeout=3)
    txt = page_text(page)
    chk("★★★ 刷新之后那条说明**还在页面上**（这是「刷新就没」的反面）",
        "余额不足" in txt and "没能发出去" in txt,
        "刷新后对话页正文里找不到；页面 %d 字，含「余额不足」=%s"
        % (len(txt), "余额不足" in txt))

    fx.disarm_400()
    return mid1


# =============================================================================
# B. 自动执行模式：429 → 循环停掉
# =============================================================================

def b_loop_stops(page, uid, db, fx):
    print("\n== B. 自动执行模式：429 → agent 循环被停掉（不是干等）==", flush=True)

    C.goto(page, "chat")
    ok = enable_agent_mode(page)
    chk("★ 前提：自动执行开关真的勾上了", ok, "没勾上则这一节测的还是手动模式")
    if not ok:
        return
    ok2 = set_target_kind(page, "local")
    chk("★ 前提：执行目标切成了「本地电脑」（这样循环不经过引擎就能推进）",
        ok2, "#chat-target_kind = %r" % sel_value(page, "#chat-target_kind"))
    if not ok2:
        return

    n_old = clear_notifications(page)
    if n_old:
        print("    清掉屏幕上残留的通知 %d 条" % n_old, flush=True)

    # ⚠️⚠️ 第 1 个请求**必须放行**：循环是被模型的回复推动的
    #    （on_llm_done → 挑代码块 → try_submit），第一个请求就 429 的话循环
    #    压根没进过 "generating" —— 那时候再断言"循环停了"是一句废话，
    #    新旧代码都会过（**这正是最容易骗过自己的一条**）。
    fx.set_queue(C.sse_multi(["用户想跑点东西，先给他一段能跑的。"], _CODE_REPLY))
    fx.disarm_400()
    fx.slow(1.0)

    mid0, _c0 = last_assistant(db, uid)
    req0 = fx.req_n()
    print("    点发送之前：最新 assistant id=%s、假 LLM 收到 %d 个请求"
          % (mid0, req0), flush=True)

    install_loop_watch(page)

    page.fill("#chat-input", "先跑一段，然后会撞上余额不足。")
    page.click("#chat-send")

    armed, dt_arm = arm_after_first_req(fx, req0, _BAL_429, 429)
    print("    第一条放行之后才挂上 429：%s（%.1f 秒；假 LLM 累计 %d 个请求）"
          % (armed, dt_arm, fx.req_n()), flush=True)
    chk("★★ 前提：第一条请求**真的到了假服务端**（429 挂在它**之后**）"
        " —— 没这一条，下面那个 429 会砸在第一条上，循环根本起不来",
        armed, "等了 20 秒 req_n 还是 %d" % fx.req_n())

    # ★★ 反假绿前提：先确认循环真的推进过。
    t_pre = time.time()
    lw, fired, how = None, False, ""
    while time.time() - t_pre < 30:
        lw = loop_watch(page) or {}
        fired, how = loop_fired(db, uid, mid0)
        if lw.get("seen") and fired:
            break
        page.wait_for_timeout(120)
    lw = loop_watch(page) or {}
    print("    侧栏徽章（事件驱动观察）：seen=%s，命中 %s 次，最后一次 %r"
          % (lw.get("seen"), lw.get("n"), (lw.get("text") or "")[:80]), flush=True)
    print("    库里循环痕迹：%s" % how, flush=True)
    chk("★★ 前提：循环**真的推进过一轮**（库里多了一条「执行结果 · 未执行」的"
        " tool 消息 —— 它只有循环接手之后才会被写）—— 不然下面那条是白送的",
        fired, how)

    note, dt = wait_notification(page, _NOTE_NEEDLE, timeout=90)
    print("    通知：%r（%.1f 秒）" % ((note or "")[:160], dt), flush=True)
    chk("★★★ [自动执行] 余额不足的通知弹出来了", note is not None,
        "等了 90 秒没有；屏幕上的通知：%s" % notifications(page))

    # ★★ "循环停了"的判据：徽章**不在了** + 不再有新的出网请求 + 界面不忙。
    #    旧代码里循环会挂在 generating 上等一个永远不会来的 on_llm_done，
    #    徽章会**一直挂着** —— 那正是用户看到的"AI 一直在生成"。
    st = loop_state(page)
    req_q = fx.req_n()
    page.wait_for_timeout(6000)
    st2 = loop_state(page)
    chk("★★★ [自动执行] 循环**停了**：侧栏「第 N/M 轮」不见了",
        not st2.get("found"),
        "等 6 秒后还在：%r" % (st2.get("text") or "")[:120])
    chk("★★ [自动执行] 而且没有偷偷重试（这 6 秒里假服务端没收到新请求）",
        fx.req_n() == req_q, "之前 %d 个，现在 %d 个" % (req_q, fx.req_n()))
    chk("★★ [自动执行] 界面回到不忙",
        wait_idle(page, 60), "send_disabled=%s"
        % page.locator("#chat-send[disabled]").count())

    rows = assistant_since(db, uid, mid0)
    hit = [r for r in rows if "余额不足" in (r[1] or "")]
    print("    出错那一轮之后新增 assistant 消息 %d 条，其中含「余额不足」%d 条"
          % (len(rows), len(hit)), flush=True)
    chk("★★★ [自动执行] 库里也落了那条说明（循环停了不等于什么都没留下）",
        bool(hit), "新增 %d 条 assistant，没有一条含「余额不足」" % len(rows))

    fx.disarm_400()
    fx.no_slow()


# =============================================================================
# C. 反面：正常回复不许冒通知、不许往对话里塞说明
# =============================================================================
#
# ★ 为什么这一节是必须的：判据放宽（"任何非空报错都要说"）的另一面就是
#   **误报**。没有这一节，一个"每次回复都往对话里塞一条余额不足"的实现
#   能把 A、B 两节全过掉。

def c_no_false_alarm(page, uid, db, fx):
    print("\n== C. 反面：一次正常回复不该冒通知、也不该塞说明 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page, timeout=3)
    n_old = clear_notifications(page)
    if n_old:
        print("    清掉屏幕上残留的通知 %d 条" % n_old, flush=True)

    fx.disarm_400()
    fx.set_queue(C.sse("这是一条再正常不过的回复。"))

    mid0, _c0 = last_assistant(db, uid)
    req0 = fx.req_n()

    page.fill("#chat-input", "回我一句正常的话。")
    page.click("#chat-send")
    ok = wait_idle(page, 90)
    chk("★ 前提：这一轮正常跑完了", ok, "wait_idle 超时")

    page.wait_for_timeout(2000)
    notes = notifications(page)
    bad_note = [t for t in notes if "没能发出去" in t or "余额不足" in t]
    print("    这一轮之后屏幕上的通知：%s" % notes, flush=True)
    chk("★★★ 正常回复**不弹**任何「出错了」的通知", not bad_note,
        "冒出来的通知：%s" % bad_note)

    rows = assistant_since(db, uid, mid0)
    bad_db = [r for r in rows if "没能发出去" in (r[1] or "")]
    txt = [r for r in rows if "再正常不过" in (r[1] or "")]
    print("    新增 assistant %d 条；含「没能发出去」%d 条；含正常回复 %d 条"
          % (len(rows), len(bad_db), len(txt)), flush=True)
    chk("★★★ 正常回复**不往对话里塞**说明（那一轮只有模型自己那条回复）",
        not bad_db, "多出来的说明：%s" % [r[1][:80] for r in bad_db])
    chk("★ 前提：模型那条回复真的落库了（不然上面那条是「什么都没写」白送的）",
        bool(txt), "新增 assistant 里没有一条是模型的正常回复")
    chk("★ 前提：这一轮真的问出去了（假服务端收到了 = 没打到真厂商）",
        fx.req_n() > req0, "%d → %d" % (req0, fx.req_n()))


# =============================================================================
# 主流程
# =============================================================================
#
# ⚠️ 顺序：A → B → C。
#   · B 必须在 A 之后：B 会把「自动执行」打开、把执行目标切成「本地电脑」，
#     那是**会话级**的状态，A 那种"发一条、断言一条"的时序在它之后就不成立
#     （循环会自己往下跑）。
#   · C 必须在 B 之后：C 要的是"自动执行关掉"的一问一答；而且 B 会往库里
#     写 tool 消息，C 数的是"这一轮新落了几条 assistant"，排在后面才干净。
#   · C 放最后还有一个理由：它是唯一一条"什么都不该发生"的断言，前面两节
#     刚把 429 挂上又摘下（`disarm_400()`），残留最容易在这里露出来。
# =============================================================================

def main():
    fx = None
    try:
        print("\n== 0. 注册并把账号指向假服务端 ==", flush=True)

        with sync_playwright() as pw:
            browser = pw.chromium.launch()

            page = enter_with_retry(browser)
            email = C.LAST_EMAIL
            uid, db = C.seed_or_die(email)
            print("  uid=%s  db=%s" % (uid, db), flush=True)

            fx = C.FakeLLM()
            print("  假 LLM: %s" % fx.url, flush=True)
            C.seed_llm(uid, fx.url, model="fake-model")
            relogin(page, email)
            ensure_no_modal(page)

            a_balance_error(page, uid, db, fx)    # A（手动）
            b_loop_stops(page, uid, db, fx)       # B（自动执行）
            c_no_false_alarm(page, uid, db, fx)   # C（反面）

            page.screenshot(path=C.OUT + "/99_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()

    _chk.done()
    print("通过 %d / 失败 %d" % (N_OK[0], N_BAD[0]))
    return 1 if N_BAD[0] else 0


if __name__ == "__main__":
    sys.exit(main())
