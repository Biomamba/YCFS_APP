#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.8 item 3：**对话途中换模型，上下文跟不跟着走？**

用户原话：「3、现在得对话途中切换模型，是否能够继承上下文继续交流？
如果不能，请增加这个功能」。

先说结论（探针证的就是这两条）：

  ① **换模型这一下，对已经开着的对话是当场生效的** —— 不需要刷新页面。
     因为 `state` 是**一个**共享的 reactiveValues（app.R:1587），模型页那个
     observer（R/mod_model.R:607）写它，对话页发消息时读它
     （R/mod_chat.R:1595/1612/1624）。
  ② **上下文是每一轮从库里重新拼的**，不是攒在内存里的会话对象 ——
     R/llm.R:692 `db_messages_get(sid)` → `dsapp_build_context()`。
     所以「换了模型就忘了前面说过什么」在结构上不可能发生：
     换模型换的是**往哪儿发**，不是**发什么**。

⚠️ 这个结论**不能靠读代码下**（本仓的规矩：「函数对」≠「界面对」，而且
   `state$model` 有**两个**真相源，见 Test_V15.7 item 8）。下面三节全部
   从**出网请求体**上取证 —— 假 LLM 把每一个请求原样存进 reqs/：
     · `model` 字段 = 这一轮**实际**用的模型名（不是界面显示的那个）
     · `messages`  = 这一轮**实际**带出去的历史

三节：
  A 换模型 → 第二个请求的 model 真的变了（且没有任何请求漏用旧模型）
  B 第二个请求的 messages 里**带着**第一轮的问和答（上下文继承）
  C 刷新整页（= 用户说的"崩了"）之后再发 → 上下文**还在**（库才是载体）

★ 为什么断言写成"扫窗口里**每一个**请求"而不是"看第 2 个请求"：
  一轮对话不止一个出网请求 —— 起标题那次短请求（R/mod_model.R 里提过）
  也会落进 reqs/。按下标取会取到标题那一条，然后拿它的 model 去断言，
  得到的是一个**看着完全合理的错结论**。所以按"请求体里有没有那个暗号"
  来认，认出来之后再查它的 model。

用法：
    bash tests/ui_v7/make_instance.sh 8951 /tmp/dsapp_v158i
    python3 tests/ui_v158/probe_ctx.py
"""
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8951/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]

# 两个**不可能撞车**的暗号：查上下文带没带，就靠在某条消息里找到它。
# ⚠️ 必须是数字串，不能是"你好"这类词 —— 系统提示词里本来就可能出现
#    常见词，那种命中是白送的（假绿）。
NONCE1 = "739184"
NONCE2 = "526407"
NONCE3 = "481552"


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def db_model(db, uid):
    r = sql(db, "SELECT llm_model FROM users WHERE id = ?", (uid,))
    return (r[0][0] or "") if r else ""


def set_db_model(db, uid, val):
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute("UPDATE users SET llm_model = ? WHERE id = ?", (val, uid))
        con.commit()
    finally:
        con.close()


def body_text(body):
    """把一次请求的 messages 拍平成一整段文本（找暗号用）。"""
    if not isinstance(body, dict):
        return ""
    out = []
    for m in (body.get("messages") or []):
        if not isinstance(m, dict):
            continue
        c = m.get("content")
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    out.append(part["text"])
    return "\n".join(out)


def reqs_with(fx, needle, lo=1):
    """窗口 [lo, req_n] 里，messages 含 needle 的请求号（1 起）。"""
    hits = []
    for i in range(lo, fx.req_n() + 1):
        b = fx.req_body(i)
        if b is not None and needle in body_text(b):
            hits.append(i)
    return hits


def req_models(fx, lo, hi):
    """[lo, hi] 里每个请求的 model 字段。取不到记 '<没取到>'。"""
    out = []
    for i in range(lo, hi + 1):
        b = fx.req_body(i) or {}
        out.append((i, b.get("model")))
    return out


def dismiss_unconfirmed(page, timeout=15):
    """关掉「模型服务还有改动没确认」那个弹窗（**离开模型服务页时弹的**）。

    ★ 它是 V13.11 item 8 那个"未确认改动"提醒（R/mod_model.R:898/922/929）。
      探针里它是**必然**出现的：本探针就是"在下拉里选一个模型、然后走人"。
      点「先这样，稍后再说」（`#model-rail_collapse`）—— 那是"改动已经自动
      存了、小字晚点再更新"那条路，正是我们要的（库里已经变了，上面那条
      断言已经证过）。

    ⚠️ 只认这一个弹窗；文案对不上就返回 False，让调用方去炸 ——
      不要写"见到弹窗就点某个按钮"，那会把别的弹窗一起关掉。
    """
    end = time.time() + timeout
    while time.time() < end:
        if not page.locator("#shiny-modal:visible").count():
            return True
        txt = page.evaluate(
            "() => (document.querySelector('#shiny-modal')||{}).innerText || ''")
        if "没确认" not in txt:
            return False
        btn = page.locator("#model-rail_collapse")
        if btn.count():
            btn.first.click()
            page.wait_for_timeout(1200)
            continue
        page.wait_for_timeout(300)
    return False


def send(page, text, timeout=120):
    """发一条，等这一轮真的跑完。

    ⚠️ 用 `wait_idle`（等 #chat-send 的 disabled 摘掉）而不是"等某个元素
      出现"：后者会在服务端还没画完的时候就返回，后面的动作和服务端重画
      抢跑，报出来的错指向完全无关的地方（fake-wait-is-not-a-wait）。

    ⚠️⚠️ 「AI 怎么干活？」那个首选项弹窗是**后到**的：`goto("chat")` 之后
       `ensure_no_modal()` 当场查是查不到的（那一刻它还没弹），等一拍它就
      盖在整页上了。第一版就栽在这里 —— 第二次发消息时 click 报
       `intercepts pointer events`，**报错指向 #chat-send 本身**，看着像
       "发送按钮坏了"（first-run-onboarding-modal）。所以点失败要**再收
       一次弹窗**再点，而不是直接判死。
    """
    page.wait_for_selector("#chat-input", timeout=30000)
    ensure_no_modal(page)
    page.fill("#chat-input", text)
    try:
        page.click("#chat-send", timeout=8000)
    except Exception:
        ensure_no_modal(page)
        page.click("#chat-send", timeout=25000)
    ok = wait_idle(page, timeout)
    return ok


def busy(page):
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(page, timeout=120):
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:          # 先等它**忙起来**，否则会立刻"不忙"
        if busy(page):
            break
        page.wait_for_timeout(150)
    while time.time() < end:
        if not busy(page):
            page.wait_for_timeout(600)    # 再稳一拍，避开"刚好在两轮之间"
            if not busy(page):
                return True
        page.wait_for_timeout(250)
    return False


def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ★ 为什么非 reload 不可：`state$base_url / model` 是**会话级**的
      （mod_model 那个 observe 从库里读一次）。种完假 LLM 不 reload，已经活着
      的那个会话手里还是老值 —— 空 base_url → 厂商默认地址 → **真厂商**。
      这是本仓明令禁止的。

    ⚠️⚠️ **不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload 时
      cookie 还在，应用**直接进主界面**，登录页一帧都不出现。拿它等等于等一个
      永远不会来的东西 —— 报出来的是「reload 之后还是空白页」，而屏幕上其实
      早就是主界面了。（本仓已记三次；probe_ctx.py 第一版第四次踩，就是卡在
      这里。）所以等的是"两个可能里先到的那个"。
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
    page.screenshot(path=os.path.join(C.OUT, "01_relogin_failed.png"),
                    full_page=True)
    sys.exit("reload 之后 180 秒回不到主界面（cookie 自动登录 + 表单登录都没成）\n"
             "  页面文字 %d 字" % len(page.inner_text("body")))


def ensure_no_modal(page, timeout=10):
    """把那个**只问一次**的「AI 怎么干活？」首选项弹窗关掉。

    ⚠️ 它是新账号第一次开对话时自己弹的（mod_chat.R 的 onboarding），盖在
      整页上 —— 有它在，点 `#chat-send` 会一直报
      「<div id="shiny-modal"> intercepts pointer events」，
      **报错指向的是"发送按钮点不动"**，和真正的原因（一个首选项弹窗）
      隔着十万八千里。

    选「都先别开，我自己盯着」（`#chat-agent_pref_manual`）是刻意的：本探针
    要的是**一轮一问一答**，自动执行开着的话 agent 循环会自己往下跑，后面
    那些"发一条、断言一条"的时序全乱。

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


def main():
    os.makedirs(C.OUT, exist_ok=True)
    log = open(os.path.join(C.OUT, "probe_ctx.log"), "w")

    def say(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    fx = C.FakeLLM()
    say("  假 LLM: %s（全程只打它，一条都不许到真厂商）" % fx.url)

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        email = "v158c_%s@example.com" % str(int(time.time()))[-6:]
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            sys.exit("注册没进去：%s" % e)
        uid, db = C.seed_or_die(email)
        # 厂商用 zhipu：它的静态清单里 glm-4.5-air 和 glm-5.3 都在。
        C.seed_llm(uid, fx.url, vendor="zhipu", model="glm-4.5-air")
        say("  uid=%s  db=%s" % (uid, db))
        # ⚠️⚠️ 这里**必须**用 relogin()，不能 `page.reload()` + `C.wait_awake()`。
        #    第一版就是这么写的，结果**卡满超时**：`wait_awake` 等的是
        #    `.dsapp-auth`（**登录页**的标记），可重载时 cookie 还在，应用
        #    **直接进主界面**，登录页一帧都不出现 —— 等一个永远不会来的东西。
        #    （本仓已经记过三次了：_common.wait_awake、probe_v157.relogin、
        #     probe_model.reload_page 的注释里都写着。这是第四次踩。）
        relogin(page, email)
        ensure_no_modal(page)
        page.wait_for_timeout(1500)

        chk("★ 前提：库里这个账号的模型是 glm-4.5-air",
            db_model(db, uid) == "glm-4.5-air", "库里=[%s]" % db_model(db, uid))

        # 手动模式：一轮 = 一个出网请求，好数。
        C.goto(page, "chat")
        ensure_no_modal(page)
        page.wait_for_timeout(1000)

        # ============ A 节：第一轮，用的必须是旧模型 ======================
        say("\n== A 节：第一轮（glm-4.5-air），暗号 %s ==" % NONCE1)
        fx.set_queue(C.sse("第一轮收到，暗号 %s 记下了。" % NONCE1))
        fx.slow(0.15)
        before = fx.req_n()
        ok = send(page, "请记住这个数字：%s。只回一句收到了。" % NONCE1)
        chk("★ 前提：第一轮跑完了（界面回到不忙）", ok, "等超时了")
        chk("★★ 前提：第一轮**真的**打到了假服务端（没打到就是打去真厂商了）",
            fx.req_n() > before, "发送前 %d 个请求，现在 %d 个"
            % (before, fx.req_n()))

        hit1 = reqs_with(fx, NONCE1, before + 1)
        say("    含暗号 %s 的请求号：%s" % (NONCE1, hit1))
        chk("★★ 前提：能在请求体里认出第一轮那一条（不然下面无从谈起）",
            bool(hit1), "窗口 %d..%d 里一个都没有" % (before + 1, fx.req_n()))
        m1 = (fx.req_body(hit1[0]) or {}).get("model") if hit1 else None
        chk("★★ 第一轮出网的 model 是 glm-4.5-air（界面显示什么不算数，这里才算）",
            m1 == "glm-4.5-air", "实际发出去的是 [%s]" % m1)

        # ============ B 节：对话途中换模型 ================================
        say("\n== B 节：**不关对话**，去「模型服务」把模型换成 glm-5.3 ==")
        C.goto(page, "模型服务")
        ensure_no_modal(page)
        page.wait_for_timeout(1200)
        try:
            C.pick_select(page, "model-model", "glm-5.3")
        except Exception as e:
            say("    pick_select 抛了：%s" % e)
        page.wait_for_timeout(4000)          # 防抖 800ms + 落库
        chk("★★ 前提：下拉里选完之后**库里**也跟着变了（不然下面测的是别的东西）",
            db_model(db, uid) == "glm-5.3", "库里=[%s]" % db_model(db, uid))

        say("\n    回到**同一个**对话（不刷新整页），再发第二轮，暗号 %s" % NONCE2)
        C.goto(page, "chat")
        # ★ 离开模型服务页**必然**弹「模型服务还有改动没确认」（V13.11 item 8）
        #   —— 本探针干的正是"选完就走"。点「先这样，稍后再说」：库里已经
        #   存好了（上面那条断言证过），只是左栏小字还没更新。
        chk("★★ 前提：离开模型服务页弹了「还有改动没确认」（这是预期内的，"
            "点「先这样」继续）", dismiss_unconfirmed(page),
            "没弹，或者弹的是别的窗 —— 别硬关，先看清是什么")
        ensure_no_modal(page)
        page.wait_for_timeout(1000)
        fx.set_queue(C.sse("第二轮收到，暗号 %s。你上一个数字是 %s。"
                           % (NONCE2, NONCE1)))
        req0 = fx.req_n()
        ok2 = send(page, "第二个数字：%s。顺便把我上一个数字复述一遍。" % NONCE2)
        chk("★ 前提：第二轮跑完了", ok2, "等超时了")
        chk("★★ 前提：第二轮也真的打到了假服务端",
            fx.req_n() > req0, "之前 %d 个，现在 %d 个" % (req0, fx.req_n()))

        hit2 = reqs_with(fx, NONCE2, req0 + 1)
        say("    含暗号 %s 的请求号：%s" % (NONCE2, hit2))
        chk("★★ 前提：能认出第二轮那一条", bool(hit2), "窗口里没有")
        if hit2:
            b2 = fx.req_body(hit2[0]) or {}
            say("    第二轮实际发出去的 model = [%s]" % b2.get("model"))
            chk("★★★ 【item 3 主案】对话途中换的模型**当场生效**："
                "第二轮出网用的是 glm-5.3（没刷新页面、没重开对话）",
                b2.get("model") == "glm-5.3",
                "实际发出去的是 [%s]" % b2.get("model"))
            say("    第二轮带出去的 messages 里，第一轮的暗号 %s 出现 %d 次"
                % (NONCE1, body_text(b2).count(NONCE1)))
            chk("★★★ 【item 3 主案】上下文**继承了**：第二轮的 messages 里"
                "带着第一轮那个暗号 %s" % NONCE1,
                NONCE1 in body_text(b2),
                "第二轮带出去的历史里找不到 %s" % NONCE1)
            chk("★★ 而且带着第一轮的**回复**（不只是用户那句话）",
                "第一轮收到" in body_text(b2),
                "只有问、没有答的话，模型接不上话")
            # 换完之后不许有任何一个请求还揣着旧模型名 —— 那说明某一路上
            # state$model 没跟上，而"大部分请求对了"是最难发现的那种坏。
            ms = req_models(fx, req0 + 1, fx.req_n())
            say("    第二轮窗口内每个请求的 model：%s" % ms)
            stale = [i for i, m in ms if m == "glm-4.5-air"]
            chk("★★ 第二轮之后没有任何请求**还在用旧模型**（漏网之鱼最难查）",
                not stale, "这些请求号还在用 glm-4.5-air：%s" % stale)

        # ============ C 节：整页刷新（用户说的"崩了"）之后还在不在 ==========
        say("\n== C 节：整页重载（= 用户说的『崩了』）之后再发一轮，暗号 %s =="
            % NONCE3)
        relogin(page, email)
        ensure_no_modal(page)
        page.wait_for_timeout(1500)
        chk("★ 前提：重载之后界面回来了", page.locator(".dsapp-shell").count() > 0,
            "重载之后还是空白")
        C.goto(page, "chat")
        ensure_no_modal(page)
        page.wait_for_timeout(1000)
        fx.set_queue(C.sse("第三轮收到，暗号 %s。" % NONCE3))
        req1 = fx.req_n()
        ok3 = send(page, "第三个数字：%s。" % NONCE3)
        chk("★ 前提：第三轮跑完了", ok3, "等超时了")
        hit3 = reqs_with(fx, NONCE3, req1 + 1)
        chk("★★ 前提：能认出第三轮那一条", bool(hit3), "窗口里没有")
        if hit3:
            t3 = body_text(fx.req_body(hit3[0]) or {})
            chk("★★ 重载之后上下文**还在**（库才是载体，内存里的丢了不影响）",
                NONCE1 in t3 and NONCE2 in t3,
                "带了 %s=%s / %s=%s"
                % (NONCE1, NONCE1 in t3, NONCE2, NONCE2 in t3))
            m3 = (fx.req_body(hit3[0]) or {}).get("model")
            chk("★★ 而且模型仍然是重载前选的那个 glm-5.3（不许被弹回旧值）",
                m3 == "glm-5.3", "实际发出去的是 [%s]" % m3)

        # ============ D 节：出网 ==========================================
        b1 = sql(db, "SELECT llm_base_url FROM users WHERE id = ?", (uid,))
        base = (b1[0][0] or "") if b1 else ""
        chk("★★ 全程 base_url 指着本机假 LLM（一条请求都没打给真厂商）",
            base == fx.url, "base_url=[%s]（假的是 %s）" % (base, fx.url))
        say("  假 LLM 一共收到 %d 个请求" % fx.req_n())

        browser.close()

    say("\n== 通过 %d / 失败 %d ==" % (N_OK[0], N_BAD[0]))
    log.close()
    fx.stop()
    sys.exit(0 if N_BAD[0] == 0 else 1)


if __name__ == "__main__":
    main()
