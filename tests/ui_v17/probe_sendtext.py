# -*- coding: utf-8 -*-
"""V17 item 3：中文输入法"发出去的句尾变拼音、还少几个字"。

用户原话：
  「现在还是有这种情况，我打好的汉字，但是点击发送后句尾会有一部分变成拼音，
    并且少几个字」

机理（读代码得到，探针要证的就是它）：服务端手里的 `input$input` 是**慢一拍的
镜像**。纯英文看不出来 —— 打完字到伸手点按钮之间隔着几百毫秒，值早同步过去了。
中文输入法把这段时间压成零：候选词是在 **click 那一刻**才上屏的，而服务端手上
还是上屏**之前**那一版 —— 句尾是没提交的拼音，末尾那几个字干脆还没进 value。

修法：客户端在按下发送的**同一个 JS 事件里**读 `box.value`，和发送信号一起送
（`dsappPushSendText` → `Shiny.setInputValue(sendText)`），服务端优先用它。

⚠️ 真输入法的时序**在这里复现不出来**（headless Chromium 没有 IME）。这句必须
   写在明处，不然下一个人会把"探针全绿"当成"输入法这条路验过了"。
   能复现、也确实复现了的是**那个机理**：让 DOM 里的值和"服务端手上的镜像"
   故意不一致，再看发出去的是哪一个。修复前发的是镜像（= 拼音那份），修复后
   发的是 DOM 里的原文。症状和机理是一一对应的，所以这一条是硬证据；而"真
   输入法下会不会也这样"只能靠线上观察（写进 README 的"验不了"那一节）。

⚠️ 另有一条**假绿陷阱**：服务端的镜像什么时候是真旧值？如果 `input` 事件根本
   没送到，`input$input` 是**空串**，那就变成"什么都没发出去"——看起来红，
   但红的理由不是我们要证的那条。所以每一步都先 `page.fill()`（真派发 input
   事件）再干等一拍，让镜像**确实**等于旧值，然后才只改 DOM。
"""
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                       # noqa: E402
from _common import FakeLLM, sse                           # noqa: E402
from playwright.sync_api import sync_playwright            # noqa: E402

BOX = "#chat-input"
BTN = "#chat-send"

fails = []


def chk(name, cond, extra=""):
    if cond:
        print("  \033[32m✓\033[0m %s" % name)
    else:
        fails.append(name)
        print("  \033[31m✗ %s\033[0m" % name)
        if extra:
            print("      \033[31m实际是：%s\033[0m" % extra)


def disk_version():
    """实例盘上那份 R/config.R 里的版本号 —— 用来钉住"跟谁在说话"。"""
    p = os.path.join(C.APP, "R", "config.R")
    m = re.search(r'DSAPP_VERSION\s*<-\s*"([^"]+)"', open(p, encoding="utf-8").read())
    return m.group(1) if m else None


def last_user_msg(db, uid):
    """这个账号最近的**那条用户消息**（库里是唯一的事实来源）。"""
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        row = con.execute(
            "SELECT content FROM messages WHERE session_id IN "
            "(SELECT id FROM sessions WHERE user_id = ?) AND role = 'user' "
            "ORDER BY id DESC LIMIT 1", (uid,)).fetchone()
        return row[0] if row else None
    finally:
        con.close()


def n_user_msg(db, uid):
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        return con.execute(
            "SELECT COUNT(*) FROM messages WHERE session_id IN "
            "(SELECT id FROM sessions WHERE user_id = ?) AND role = 'user'",
            (uid,)).fetchone()[0]
    finally:
        con.close()


def set_value_no_event(pg, text):
    """把文字放进输入框，**不派发 input 事件** = 服务端的镜像停在旧值上。

    这就是"候选词刚上屏、镜像还没跟上"那一拍的替身。
    """
    pg.evaluate("""(t) => {
        var b = document.getElementById('chat-input');
        b.value = t;
    }""", text)


def set_value_with_event(pg, text):
    """正常打字：走 Playwright 的 fill，真派发 input 事件。"""
    pg.fill(BOX, text)


def wait_mirror(pg, sec=2.0):
    """等 Shiny 把 input 事件送上去（textarea 绑定带 debounce）。"""
    pg.wait_for_timeout(int(sec * 1000))


def click_send(pg):
    pg.click(BTN)
    pg.wait_for_timeout(1200)


def main():
    ver = disk_version()
    print("实例盘上的版本号 =", ver)
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_context(viewport={"width": 1440, "height": 950}).new_page()
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))

        fx = FakeLLM()
        try:
            email = C.enter_app(pg)
            uid, db = C.seed_or_die(email)
            print("  账号 uid =", uid)
            # ⚠️ 种完库**必须重载**：state$base_url / state$model 是会话开始
            #    那一刻读一次的，不重载的话这一页手里还是"没配 Key"，
            #    点发送会被闸门挡回去（探针会误判成"发送这条路坏了"）。
            C.seed_llm(uid, fx.url)
            pg.goto(C.URL, wait_until="domcontentloaded")
            C.wait_awake(pg)
            C.ensure_no_modal(pg)
            pg.wait_for_selector(BOX, timeout=30000)

            # ---- 前置：这一页跑的确实是**改过的那份**代码 ------------------
            print("\n== 前置（防假绿）==")
            pre = pg.evaluate("""() => ({
                push: typeof dsappPushSendText,
                sendText: dsappIds.sendText || '',
                input: dsappIds.input || '',
                sendKey: dsappIds.sendKey || '',
                foot: (document.querySelector('.dsapp-footer-ver')||{}).innerText || ''
            })""")
            chk("新函数 dsappPushSendText 在（www/app.js 是新的）",
                pre["push"] == "function", pre)
            chk("服务端下发了 sendText（R 那半边也是新的）",
                bool(pre["sendText"]), pre)
            chk("★ 页脚版本 == 实例盘上那份 config.R（没跟错实例）",
                ver and ver in pre["foot"], {"盘上": ver, "页脚": pre["foot"]})
            if fails:
                print("\n前置就红了，后面的都不用跑。")
                return 1

            # ---- A1：正常路径没被弄坏 --------------------------------------
            print("\n== A1：正常打字发送（这条本来就该通）==")
            fx.set_queue(sse("收到。"), sse("收到。"), sse("收到。"),
                         sse("收到。"), sse("收到。"), sse("收到。"))
            n0 = n_user_msg(db, uid)
            set_value_with_event(pg, "先来一句普通的")
            wait_mirror(pg)
            click_send(pg)
            C.ensure_no_modal(pg)
            got = last_user_msg(db, uid)
            chk("库里最后那条用户消息 == 刚打的字",
                got == "先来一句普通的", {"库里": got, "库里条数": (n0, n_user_msg(db, uid))})

            # ---- A2 ★★★：句尾刚上屏那一拍（**回车**那条路）-----------------
            print("\n== A2 ★★★ 镜像里是拼音、DOM 里是汉字（按回车发送）==")
            #
            # 把用户那句话拆成两半：
            #   · 前半段"帮我看看这批shuju" 用 fill 送上去 ⇒ 服务端镜像**确实**
            #     收到了（回读 `dsappOpLog` 能看到 chat-input=s11 那一批）
            #   · 句尾"shuju" → "数据" 只在 DOM 里改，**不派发任何事件**
            # 于是这一拍：镜像 = "帮我看看这批shuju"（拼音版，比真话短）
            #             DOM  = "帮我看看这批数据"（汉字版）
            # 修复前发出去的是镜像那一版 —— 正是"句尾变拼音、还少几个字"。
            #
            # ⚠️⚠️ 为什么这条必须走**回车**而不是点按钮（2026-10-08 实测改的）：
            #    点按钮会先让输入框**失焦**，浏览器在失焦时补一个原生 change，
            #    Shiny 的 textarea 绑定就顺手把当前值送了上去 —— 于是"点按钮"
            #    这条路**本来就被浏览器自己兜住了**，修不修都绿。
            #    （实测：把客户端那半边的修复整个拿掉，点按钮那条照样绿，
            #      而回车那条当场红。日志里看得很清楚：点按钮时先来了
            #      `chat-input=s8` 一批，值已经是对的。）
            #    回车**不失焦**，没有任何 change，镜像就稳稳停在旧值上 ——
            #    这才是用户真正踩的那条路，也是这条断言唯一有劲的走法。
            set_value_with_event(pg, "帮我看看这批shuju")
            wait_mirror(pg, 2.5)
            log0 = pg.evaluate("() => window.dsappOpLog.length")
            set_value_no_event(pg, "帮我看看这批数据")
            dom_now = pg.input_value(BOX)
            chk("前置：DOM 里已经是汉字版（探针自己也要站得住）",
                dom_now == "帮我看看这批数据", dom_now)

            pg.press(BOX, "Enter")
            pg.wait_for_timeout(1500)
            C.ensure_no_modal(pg)
            got = last_user_msg(db, uid)
            chk("★★★ 库里落的是**汉字版**（这一条就是用户要的那个修复）",
                got == "帮我看看这批数据",
                {"库里": got,
                 "对照": "落成「帮我看看这批shuju」= 发出去的还是镜像那一版，没修好"})
            # 界面上也得是汉字版 —— 库对了、界面不对同样是 bug（本仓有账）。
            bubble = pg.evaluate("""() => {
                var ns = document.querySelectorAll('#chat-history .dsapp-msg-user');
                return ns.length ? ns[ns.length-1].innerText : '';
            }""")
            chk("界面上那条气泡也是汉字版", "帮我看看这批数据" in bubble,
                bubble[:120])

            # 顺序：原文那一批必须排在发送信号那一批**前面**。
            # ⚠️ 客户端代码的注释里写的是"同一个 sendInput 批次"，实测**不是**：
            #    它们是同一个 tick 里的两次 setInputValue ⇒ 两个批次、按序到达。
            #    判据只能要**顺序**，要"同批次"就是一条永远红的断言。
            log1 = pg.evaluate("""(s) => window.dsappOpLog.slice(s)
                                     .map(e => e.keys.join(' '))""", log0)
            i_txt = next((i for i, x in enumerate(log1) if "send_text=" in x), -1)
            i_key = next((i for i, x in enumerate(log1) if "send_key" in x), -1)
            chk("★★ 原文那一批**不晚于**发送信号（服务端按到达顺序处理）",
                i_txt >= 0 and i_key >= 0 and i_txt <= i_key,
                {"日志": log1[:6], "send_text 在第": i_txt, "send_key 在第": i_key})

            # ---- A2b：点按钮那条路（回归用，**不区分**修复前后）------------
            print("\n== A2b：点发送按钮（浏览器自己会补 change，这条不区分修复前后）==")
            #
            # ★ 诚实标注：实测把客户端那半边的修复整个拿掉，这条依然绿 ——
            #   点按钮先失焦，浏览器补一个原生 change，Shiny 顺手把当前值送上去。
            #   留着它是为了"修复别把点按钮这条路弄坏"，**不是**修复的证据。
            set_value_with_event(pg, "点按钮这条路再来一次")
            wait_mirror(pg, 2.0)
            set_value_no_event(pg, "点按钮：句尾也换成汉字")
            click_send(pg)
            C.ensure_no_modal(pg)
            got = last_user_msg(db, uid)
            chk("点按钮发出去的也是 DOM 里的原文", got == "点按钮：句尾也换成汉字", got)

            # ---- A3：组字没结束时点发送 = 这一下作废 ------------------------
            print("\n== A3：组字还没结束就点发送（V13.7 item 4 的守卫）==")
            n1 = n_user_msg(db, uid)
            set_value_with_event(pg, "这句不该发出去")
            wait_mirror(pg, 1.2)
            pg.evaluate("""() => {
                var b = document.getElementById('chat-input');
                b.dispatchEvent(new CompositionEvent('compositionstart',
                                                     {bubbles: true}));
            }""")
            composing = pg.evaluate("() => dsappComposing")
            click_send(pg)
            n2 = n_user_msg(db, uid)
            chk("前置：页面确实进了组字态", composing is True, composing)
            chk("★★ 组字中点发送 = 一条都不发（发出去就是拼音，没有任何意义）",
                n2 == n1, {"点之前": n1, "点之后": n2})

            pg.evaluate("""() => {
                var b = document.getElementById('chat-input');
                b.dispatchEvent(new CompositionEvent('compositionend',
                                                     {bubbles: true}));
            }""")
            set_value_no_event(pg, "组字结束之后再点一次")
            click_send(pg)
            C.ensure_no_modal(pg)
            got = last_user_msg(db, uid)
            chk("★★ 组字结束后再点一次就能发（守卫不是把按钮弄死了）",
                got == "组字结束之后再点一次", got)

            # ---- A4：空框就是空框 ------------------------------------------
            print("\n== A4：框里删空了（镜像里还留着上一句）==")
            #
            # ⚠️ 这一条盯的是 R 那半边的判据：`is.null(txt)` 还是 `nzchar(txt)`。
            #    写成 nzchar 的话，客户端明确送上来的**空串**会被当成"没送"，
            #    于是回落到镜像 —— 把用户刚删掉的那句话又发一遍。
            set_value_with_event(pg, "这一句待会儿要删掉")
            wait_mirror(pg, 2.0)
            n3 = n_user_msg(db, uid)
            set_value_no_event(pg, "")
            click_send(pg)
            pg.wait_for_timeout(1500)
            n4 = n_user_msg(db, uid)
            chk("★★ 框里是空的就一条都不发（不许回落到镜像里那句）",
                n4 == n3, {"点之前": n3, "点之后": n4,
                           "库里最后一条": last_user_msg(db, uid)})

            # ---- A5：收尾 ---------------------------------------------------
            print("\n== A5：收尾 ==")
            chk("整场下来页面没抛 JS 异常", not errs, errs[:3])
        finally:
            try:
                pg.screenshot(path=os.path.join(C.OUT, "sendtext_end.png"))
            except Exception:
                pass
            fx.stop()
            b.close()

    print()
    if fails:
        print("\033[31m%d 条没过：\033[0m" % len(fails))
        for f in fails:
            print("   -", f)
        return 1
    print("\033[32m全部通过\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
