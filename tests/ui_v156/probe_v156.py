# -*- coding: utf-8 -*-
"""tests/ui_v156 —— 「围栏粘在正文后面」的浏览器验收（2026-09-30 线上那个 bug）

用户原话：「**GPT6文献解析这个任务运行到一半，没有转圈，也没有新的提示，
就停在那了，看下是什么bug**」。

现场（**不是推断**，是拿平台自己的解析器把线上那条消息重放了一遍）：

- 会话 `s-20260930161400-4513` 的 message 478，第 1 行长这样：
  `……首次检索预计耗时 1 分钟、内存低于 0.5 GB。```python`
  开围栏**粘在句子末尾**。
- 旧的判据要求开围栏独占行首（`^\\s*``` `），于是整段代码被当成正文：
  `dsapp_agent_pick_block()` 判 `kind="none"`（「回复里没有代码块」）→ 循环
  走了"模型给出了结论"那个出口 → **不执行、不报错、不转圈、不写消息**。
- 同形状的回复此前已经这样静默死过 6 条。

修法（`R/render.R` 的 `dsapp_fence_open()`，两个解析器共用一份判定）：
开围栏可以粘在正文后面，只要它后面到行尾只剩一个语言标注；前面那半句还给
正文。闭合围栏仍然要求独占一行（反过来的话，代码里的 `s <- "```"` 会把
后面半段**静默截掉**，比原来那个 bug 更坏）。

── 这一份探针管三件事（都在**浏览器里**，不是自检那种"函数对了"）──────────
  A 渲染侧（手动模式）：粘着的围栏要长出**代码卡**，而且 composer 里那颗
    「确认执行」要亮。修之前一张卡都没有、按钮压根不渲染 —— 用户看到的是
    一大段"正文"，里面还带着字面的 ```python。
  C **反面**：正文里随口提一个 ``` 不长卡（判据放宽的边界，别修过头）。
  B 循环侧（自动执行 + 本地电脑）：粘着的那一段**真的被执行**（判据是库里
    那条只有循环才写的 tool 消息），外加一条对照 —— 行首围栏的同一段代码
    行为不变（别把正常路径弄坏）。

── 铁律（本仓踩过的，写在每一处需要它的地方）─────────────────────────────
  · 新账号第一次进对话页有个首选项弹窗会把所有 click 吃掉 → `ensure_no_modal()`。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到条件成立，带上限。
  · reload 之后 cookie 直进主界面 → `relogin()` 等的是"两个可能里先到的那个"。
  · 只查界面 = 分不清"没写进去"和"没画出来" → B 的判据回**库**里确认。
  · 隐藏元素的矩形是全 0 → 量按钮之前先确认它在对话页上（这一份不用减法）。
  · 一条出网请求都不许打到真厂商 → 每次发完断言 `fx.req_n()` 涨了。
"""
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402  （必须在 sys.path 之后）

from playwright.sync_api import sync_playwright  # noqa: E402


# =============================================================================
# 断言记账
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
# 夹具：三条回复，形状是这一节的**全部**区别
#
# ⚠️ 三段代码都是无害的（`print(...)` 不命中任何扫描规则），而且都是
#    **闭合**的 Python 块 —— 不闭合的话 pick 会判 "unclosed"，那是另一条
#    回喂路径，验出来的东西和这一节要验的不是一回事。
# =============================================================================

# ★ 实验组：开围栏粘在正文末尾（线上 message 478 的原形，第 1 行一字不改）
_GLUED = ("这篇文章我分两步做。\n\n首次检索预计耗时 1 分钟、内存低于 0.5 GB。"
          "```python\nimport json\nprint(\"glued-ok\")\n```\n")

# 对照组：同一段代码，开围栏独占一行（形状是**标准**的）
_NORMAL = "这段先跑一下：\n\n```python\nprint(\"normal-ok\")\n```\n"

# 反面：正文里**提到**一个反引号三连，但它后面跟的是中文（不是语言标注）
_MENTION = "这一段用 ``` 包起来就行，不用给我代码。\n"

_TOOL_NEEDLE = "执行结果"     # R/agent.R 的 a$try_submit() 只有循环才写


# =============================================================================
# 小工具（照 tests/ui_v155/probe_v155.py 抄，只保留这一份要用的）
# =============================================================================

def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ⚠️ **不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload 时
      cookie 还在，应用**直接进主界面**，登录页一帧都不出现 —— 拿它等等于
      等一个永远不会来的东西。
    """
    page.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if page.locator(".dsapp-shell").count():
            return
        # ⚠️ 登录页和注册页的 id **不是**一套：登录是 `#welcome-login_email`
        #    /`#welcome-login_password`，注册才是 `#welcome-email`。这里原来
        #    只认注册那套 —— cookie 还在的时候（本探针的常态）压根走不到这一
        #    支，所以一直没暴露；一旦真的退到登录页就必然卡满 180 秒，报的是
        #    「reload 之后回不到主界面」，看着像应用坏了。两套都认。
        if not submitted and page.locator("#welcome-login_email").count():
            page.fill("#welcome-login_email", email)
            page.fill("#welcome-login_password", C.PW)
            page.click("#welcome-do_login")
            submitted = True
        page.wait_for_timeout(1000)
    page.screenshot(path=C.OUT + "/01_relogin_failed.png", full_page=True)
    sys.exit("reload 之后 180 秒回不到主界面")


def ensure_no_modal(page, timeout=10):
    """关掉那个只问一次的「AI 怎么干活？」首选项弹窗。

    ⚠️ 它在的时候，**所有** click 都报 `intercepts pointer events`，报错指向
      的是被挡的那个按钮 —— 和真正的原因隔着十万八千里。
    ⚠️ 它点的是「都先别开，我自己盯着」（`#chat-agent_pref_manual`），也就是
      **手动模式**。A / C 两节要的正是这个；B 节要自动执行，走
      `enable_agent_mode()`（它点的是保存那颗，不碰这两个选项）。
    """
    end = time.time() + timeout
    while time.time() < end:
        if page.locator("#shiny-modal:visible").count() == 0:
            return True
        for sel in ("#chat-agent_pref_manual", "#chat-agent_pref_save"):
            b = page.locator(sel)
            if b.count():
                try:
                    b.first.click(timeout=4000)
                    page.wait_for_timeout(1200)
                    break
                except Exception:
                    pass
        page.wait_for_timeout(300)
    return page.locator("#shiny-modal:visible").count() == 0


def enable_agent_mode(page):
    """把「自动执行」勾上，并且按用户的真实路径答完那个首选项弹窗。

    ⚠️ 收尾**不能**用 `ensure_no_modal()`：它点的是「都先别开」，会把刚勾上
      的开关自己按回去 —— 后面那一节测的就成了"自动执行关着"，而它看起来
      和"循环没跑"一模一样（同一个假绿形态）。
    """
    box = page.locator("#chat-agent_mode")
    if box.count() == 0:
        print("    ⚠️ 找不到 #chat-agent_mode", flush=True)
        return False
    if not box.first.is_checked():
        try:
            box.first.check(timeout=8000)
        except Exception:
            try:
                box.first.click(force=True, timeout=5000)
            except Exception:
                page.evaluate("() => Shiny.setInputValue("
                              "'chat-agent_mode', true, {priority: 'event'})")
                print("    ⚠️ 那颗勾是直接发 Shiny 输入勾上的", flush=True)
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
    return page.locator("#chat-agent_mode").first.is_checked()


def sel_value(page, sel):
    """读 <select> 的当前值。**不用 `input_value()`** —— selectize 把原生
    select 藏成 0×0，可操作性检查会一路等到超时。"""
    try:
        return page.eval_on_selector(sel, "e => e.value")
    except Exception:
        return None


def set_target_kind(page, value):
    """把「硬件选择」切成 value。

    ★ 切「本地电脑」不是为了跑代码，是为了让循环**不经过引擎**就能推进：
      `try_submit()` 在 local 那一支写完一条 tool 消息就直接 begin_llm()。
      server 那一支要真的起一个任务（引擎、conda、几十秒），那是另一个
      量级的探针。
    """
    try:
        C.pick_select(page, "chat-target_kind", value)
        page.wait_for_timeout(700)
    except Exception as e:
        print("    ⚠️ 点「硬件选择」没成：%s" % str(e)[:160], flush=True)
    if sel_value(page, "#chat-target_kind") == value:
        return True
    page.evaluate("(v) => Shiny.setInputValue('chat-target_kind', v,"
                  " {priority: 'event'})", value)
    page.wait_for_timeout(700)
    return sel_value(page, "#chat-target_kind") == value


def busy(page):
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(page, timeout=120):
    """等到这一轮真的结束。**不是**"等某个元素出现" —— 那种提前返回的写法
    会让后面的动作和服务端重画抢跑（fake-wait-is-not-a-wait）。"""
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:
        if busy(page):
            break
        page.wait_for_timeout(150)
    while time.time() < end:
        if not busy(page):
            page.wait_for_timeout(700)
            if not busy(page):
                return True
        page.wait_for_timeout(250)
    return False


def send(page, text, timeout=120):
    ensure_no_modal(page, timeout=3)
    page.fill("#chat-input", text)
    page.click("#chat-send")
    ok = wait_idle(page, timeout)
    if not ok:
        page.screenshot(path=C.OUT + "/02_send_timeout.png", full_page=True)
    return ok


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def max_msg_id(db, uid):
    r = sql(db, "SELECT COALESCE(MAX(m.id), 0) FROM messages m"
                " JOIN sessions s ON s.id = m.session_id WHERE s.user_id = ?",
            (uid,))
    return r[0][0] if r else 0


def wait_tool(db, uid, since_id, needle, timeout=30):
    """轮询到"库里出现含 needle 的 tool 消息"。返回 (bool, 说明, 命中的正文)。"""
    end = time.time() + timeout
    rows = []
    while time.time() < end:
        rows = sql(db, "SELECT m.id, m.content FROM messages m"
                       " JOIN sessions s ON s.id = m.session_id"
                       " WHERE s.user_id = ? AND m.role = 'tool' AND m.id > ?"
                       " ORDER BY m.id", (uid, since_id))
        hit = [r for r in rows if needle in (r[1] or "")]
        if hit:
            return True, ("新增 tool 消息 %d 条" % len(rows)), (hit[-1][1] or "")
        time.sleep(0.5)
    return False, ("等了 %d 秒，新增 tool 消息 %d 条，一条都不含「%s」"
                   % (timeout, len(rows), needle)), ""


_CARDS_JS = r"""(lastOnly) => {
    var root = document;
    if (lastOnly) {
        var ms = document.querySelectorAll('.dsapp-msg-assistant');
        if (ms.length) root = ms[ms.length - 1];
    }
    var cards = root.querySelectorAll('.dsapp-code-card');
    var out = [];
    for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var lang = c.querySelector('.dsapp-code-lang');
        var pre  = c.querySelector('pre.dsapp-code');
        var slot = c.querySelector('.dsapp-code-slot');
        var r = c.getBoundingClientRect();
        out.push({
            lang: lang ? (lang.innerText || '').trim() : null,
            code: pre ? (pre.innerText || '') : null,
            status: slot ? (slot.innerText || '').trim() : null,
            w: Math.round(r.width), h: Math.round(r.height)
        });
    }
    return out;
}"""


def cards_info(page, last_only=True):
    """页面上代码卡的信息。

    ⚠️ `last_only` 默认是真：**只看最后一条 assistant 气泡里的卡**。卡片是
       跟着消息走的，整页扫的话，上一节留下的卡会算进这一节 —— V15.6 的探针
       就在这儿误报过一次 C1（反面那一节本该 0 张，读到的却是 A 节那张还在
       DOM 里的卡，而 A 节那张是**对的**）。
    """
    try:
        return page.evaluate(_CARDS_JS, bool(last_only))
    except Exception as e:
        print("    ⚠️ 读代码卡没成：%s" % str(e)[:160], flush=True)
        return []


_LAST_ASSISTANT_JS = r"""() => {
    var els = document.querySelectorAll('.dsapp-msg-assistant');
    if (!els.length) return '';
    return els[els.length - 1].innerText || '';
}"""


def last_assistant_text(page, until=None, timeout=12):
    """**最后一条** assistant 气泡的正文（不含 tool 卡）。

    ⚠️ 用 `innerText` 而不是 `textContent`：后者会把隐藏节点的文字也算进来，
      而这个应用里隐藏的页/节点很多（bslib 把没激活的页也留在 DOM 里）。

    ⚠️ 它会**轮询到画完**再返回，不能读一次就走：正文是流式一段段塞进气泡的，
      早一步读到的就是半句话 —— V15.6 的探针在这里误报过 C2（断言"整句在
      不在"，读到的只有前半句「这一段用」，而库里和渲染函数里那句都是全的）。
      给了 `until` 就等到它出现；没给就等到**连续两次读到的内容一致**。
    """
    end = time.time() + timeout
    prev = ""
    while time.time() < end:
        txt = page.evaluate(_LAST_ASSISTANT_JS)
        if until is not None:
            if until in txt:
                return txt
        elif txt and txt == prev:
            return txt
        prev = txt
        page.wait_for_timeout(300)
    return prev


def run_btn_rect(page):
    """composer 里那颗「确认执行」的矩形。没有 → None。

    ⚠️ 它在**对话页**上才有，而 bslib 把没激活的页也留在 DOM 里 —— 调用方
      都先 `goto(page,"chat")` 过，量的就是看得见的那一颗。
    """
    return page.evaluate(r"""() => {
        var b = document.querySelector('.dsapp-code-run');
        if (!b) return null;
        var r = b.getBoundingClientRect();
        var st = window.getComputedStyle(b);
        return {w: Math.round(r.width), h: Math.round(r.height),
                text: (b.innerText || '').trim(),
                display: st.display, visibility: st.visibility};
    }""")


# =============================================================================
# A. 渲染侧（手动模式）
# =============================================================================

def sec_a_render(page, uid, db, fx):
    print("\n== A. 渲染侧（手动模式）：粘着的围栏要长出代码卡 ==", flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    on = page.locator("#chat-agent_mode").first.is_checked()
    chk("★ 前提：自动执行关着（这一节量的是渲染，循环别自己往下跑）",
        not on, "勾着的话 agent 循环会接手，量到的就不是渲染了")

    fx.set_queue(C.sse(_GLUED))
    n0 = fx.req_n()
    ok = send(page, "解析这篇文章")
    chk("★ 前提：这一轮真的问出去了（假服务端收到了 = 没打到真厂商）",
        ok and fx.req_n() > n0, "req_n %s → %s" % (n0, fx.req_n()))
    page.wait_for_timeout(1500)          # 让渲染层把这一条画完再量

    cards = cards_info(page)
    chk("★★★ A1 代码卡长出来了（修之前这一段是一整片正文，一张卡都没有）",
        len(cards) == 1, "卡片 %d 张：%s" % (len(cards), cards))
    if cards:
        c = cards[0]
        # ⚠️ 不区分大小写比：`.dsapp-code-lang` 的 CSS 里有 text-transform:
        #    uppercase，`innerText` 拿到的是**渲染后**的 "PYTHON"。
        chk("★★ A2 语言标注 = Python（CSS 会把它转成大写，比的时候不区分）",
            (c["lang"] or "").lower() == "python", c)
        chk("★★ A3 代码正文原样在卡片里（含 glued-ok）",
            "glued-ok" in (c["code"] or ""), (c["code"] or "")[:120])
        chk("★★ A4 状态是「待执行」（可执行且已闭合才走到这一格）",
            "待执行" in (c["status"] or ""), c)
        chk("★ A5 卡片有真实尺寸（不是 0 高 —— 隐藏元素的矩形是全 0）",
            c["w"] > 100 and c["h"] > 20, c)

    bt = last_assistant_text(page, until="内存低于 0.5 GB")
    chk("★★ A6 围栏前那句话还在正文里（放宽判据不能把文字吃掉）",
        "内存低于 0.5 GB" in bt, bt[:200].replace("\n", "｜"))
    bt = last_assistant_text(page)          # 稳定后的全文，下一句要用整段
    chk("★★ A7 围栏没有被当正文画出来（气泡里没有字面的 ```python）",
        "```" not in bt, bt[:200].replace("\n", "｜"))

    rb = run_btn_rect(page)
    chk("★★★ A8 composer 里那颗「确认执行」亮了"
        "（修之前 pending_code() 解析出 0 个块 → 整颗按钮根本不渲染）",
        bool(rb) and rb["w"] > 0 and rb["h"] > 0 and rb["text"] == "确认执行",
        rb)


# =============================================================================
# C. 反面：判据放宽的边界
# =============================================================================

def sec_c_negative(page, uid, db, fx):
    print("\n== C. 反面：正文里随口提一个 ``` 不该长代码卡 ==", flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    fx.set_queue(C.sse(_MENTION))
    ok = send(page, "我该怎么做？")
    chk("★ 前提：这一轮问出去了", ok)
    page.wait_for_timeout(1200)

    cards = cards_info(page)
    chk("★★ C1 一句提到 ``` 的正文**不**长代码卡（判据放宽了，但没放宽成"
        "「见到反引号就当围栏」）", len(cards) == 0,
        "卡片 %d 张：%s" % (len(cards), cards))
    bt = last_assistant_text(page, until="包起来就行")
    chk("★ C2 那句话原样在（没被切掉、也没变成代码）", "包起来就行" in bt,
        bt[:160].replace("\n", "｜"))
    rb = run_btn_rect(page)
    chk("★ C3 也没有「确认执行」可点", rb is None or rb["text"] != "确认执行",
        rb)


# =============================================================================
# B. 循环侧（自动执行 + 本地电脑）
# =============================================================================

def _one_loop_round(page, uid, db, fx, tag, reply, expect_tool):
    """发一轮、看循环有没有**真的执行**那段代码。返回 (ok, 说明)。"""
    since = max_msg_id(db, uid)
    # 第二条是"结论"（没有代码块）—— 循环执行完之后要能自己收尾，
    # 否则它会一直要下一轮（队列空了之后假服务端回什么就不由我们说了）。
    fx.set_queue(C.sse(reply), C.sse("跑完了，结论是 %s。" % tag))
    n0 = fx.req_n()
    ok = send(page, "跑一下这段：%s" % tag)
    hit, why, body = wait_tool(db, uid, since, _TOOL_NEEDLE, timeout=30)
    print("    [%s] req %s → %s；%s" % (tag, n0, fx.req_n(), why), flush=True)
    chk("★ 前提：[%s] 这一轮真的问出去了（假服务端收到了）" % tag,
        ok and fx.req_n() >= n0 + 1)
    chk(("★★★ [%s] 循环**真的执行了**那一段（库里那条只有循环才写的 "
         "tool 消息）" % tag if expect_tool else
         "★★ [%s] 对照：行首围栏照旧执行" % tag),
        hit == expect_tool, why)
    return hit, body


def sec_b_loop(page, uid, db, fx):
    print("\n== B. 循环侧（自动执行 + 本地电脑）：粘着的那段也要被执行 ==",
          flush=True)
    print("    判据是**库里的 tool 消息**，不是界面上那枚「第 N/M 轮」徽章 ——"
          " 徽章的观测窗口只有一次 HTTP 往返，漏了是常态。", flush=True)
    C.goto(page, "chat")
    ok = enable_agent_mode(page)
    chk("★ 前提：自动执行开关真的勾上了", ok, "没勾上则这一节测的还是手动模式")
    if not ok:
        return
    ok2 = set_target_kind(page, "local")
    chk("★ 前提：执行目标切成了「本地电脑」（循环不经过引擎就能推进）", ok2,
        "#chat-target_kind = %r" % sel_value(page, "#chat-target_kind"))
    if not ok2:
        return

    # ★ 先跑**对照**（行首围栏）：万一它红了，说明这一节的环境没搭对，
    #   而不是"粘着的那种没被执行" —— 两条红的原因要分得开。
    _one_loop_round(page, uid, db, fx, "行首围栏（对照）", _NORMAL, True)
    _one_loop_round(page, uid, db, fx, "粘着的围栏", _GLUED, True)


# =============================================================================

def enter_with_retry(browser):
    last = None
    for i in range(3):
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        try:
            C.enter_app(page, email="v156_%s_%d@example.com"
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

            # ★ 顺序是故意的：
            #   A、C 都在**手动模式**下跑（进对话页时 `ensure_no_modal()` 已经
            #   把首选项答成「都先别开」）。B 会把自动执行勾上，之后就不适合
            #   再量渲染了 —— 循环会自己往下跑，一问一答的时序全乱。
            sec_a_render(page, uid, db, fx)
            sec_c_negative(page, uid, db, fx)
            sec_b_loop(page, uid, db, fx)

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
