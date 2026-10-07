#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.7 item 7：**页面/会话一断，正在流的那一轮连一个字都不剩。**

线上现场（Biomamba_ceshi / uid=11，2026-10-01，四次一模一样）：
    messages 里 user 那条在、assistant 一条没有；
    data/run/ 里**连 .out 都没留下**（而 .log/.err 在）。
溯源：全仓库只有 dsapp_llm_abort() 会同时删掉 .out/.json/.reason，它只有
四个调用点，其中三个在 mod_chat.R 的 end_run() —— 也就是
`session$onSessionEnded`（关页面 / 标签页被浏览器冻结 / 刷新页面）那条路。

链路：
   会话结束 → end_run() → det="off"（或 finish 但引擎槽里没有任务）
   → dsapp_llm_abort(st$llm) → 杀掉子进程 + unlink(.out/.json/.reason)
   → **st$acc 里已经生成的那几千字，没有任何人写进库**
而同一个文件里的停止按钮（observeEvent(input$stop)）是**存了**的
（`db_message_add(..., paste0(partial, "（已手动停止生成）"))`）——
同一个动作两种待遇，说明这是漏的，不是有意设计的。

★★ 真因（V15.7 修的时候才挖到底，比上面那层深一级）：**整段交接逻辑在
   响应式上下文之外调 `cfg()`，一调就抛。**
     cfg() 是 `dsapp_config_user(state$user_id, dsapp_config())`（mod_chat.R:551），
     读的是响应式值；而 onSessionEnded 的回调跑在会话**已经拆掉之后**，那里
     没有响应式上下文 → `Can't access reactive value 'user_id' outside of
     reactive consumer`。
   要命的是这条路上**每一处**都包着 tryCatch / try(silent = TRUE)，于是：
     · full  档：dsapp_detach_start 起不来 → 静默降级
     · finish档：dsapp_detach_sit 起不来 → 静默降级
     · 连"【平台提示】……循环在此中断"那条 tool 消息都写不进库
   —— V13.7 item 5 那三档「离开页面之后」**从来没有生效过**，全都会掉到
   兜底那一支"什么都停"。用户设了"一路跑完"也没用，而他看不出来：页面关了
   本来就没有界面可看。
   修法：`cfg_end <- isolate(cfg())`（isolate 自己造假上下文，在没有响应式
   上下文的地方能用），回调里所有 cfg() 换成 cfg_end。

   定位它的唯一办法是**埋点**：app.log 里那行 "Can't access reactive value"
   是 message() 打出来的。只看界面和库，这段代码"什么都没做"和"什么都没
   做成功"长得一模一样。

两节：
  A 复现：正文流到一半**关掉页面**，回库看有没有 assistant 消息
  B 对照：不关页面、让它自然跑完 —— 必须有（证明夹具本身是好的，
    否则 A 的红说明不了任何事）

⚠️ 判据必须**回库**，不能只看界面：界面在页面关掉之后什么都没有，
    "没写进去"和"没画出来"在那里根本分不开。

用法：
    bash tests/ui_v7/make_instance.sh 8931 /tmp/dsapp_v159
    python3 tests/ui_v157/probe_disc.py
"""
import json
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8931/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v159/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_v159_out")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from probe_v157 import ensure_no_modal, relogin          # noqa: E402
from playwright.sync_api import sync_playwright          # noqa: E402

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


def mk_sse(mark, n):
    """一条**分块**的 SSE 应答：每段一个 delta.content。

    ⚠️ 分块 + slow() 是必须的：整段一次性发完的话，一个 200ms 轮询周期就
       收完了，"流到一半关页面"这个动作根本落不到流中间（假绿）。
    """
    def chunk(o):
        return "data: " + json.dumps(o) + "\n\n"

    s = ""
    for i in range(n):
        s += chunk({"choices": [{"delta": {"content":
                     "%s第%d段。" % (mark, i + 1) +
                     "这是一段用来把气泡撑长的占位正文。" * 3},
                     "finish_reason": None}]})
    s += chunk({"choices": [{"delta": None, "finish_reason": "stop"}]})
    return s + "data: [DONE]\n\n"


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


def ai_hits(db, sid, mark):
    return [(r[0], len(r[1] or "")) for r in msgs(db, sid, "assistant")
            if mark in (r[1] or "")]


def run_files():
    """data/run/ 里现存的 llm-*.out（正在流的那一轮的指纹）。"""
    d = os.path.join(C.DATA_ROOT, "run")
    try:
        return sorted(f for f in os.listdir(d) if f.endswith(".out"))
    except OSError:
        return []


def run_dir():
    return os.path.join(C.DATA_ROOT, "run")


def active_sid(page):
    try:
        return page.evaluate(
            "() => { var e = document.querySelector('.dsapp-sess.active');"
            " return e ? (e.getAttribute('data-sid') || '') : ''; }")
    except Exception:
        return ""


def wait_active_sid(page, timeout=25, not_sid=None):
    """轮询到侧栏真的有了"当前对话"为止。

    ⚠️ 不能 `send()` 完立刻读一次就断言 —— 会话行是服务端异步建出来再重画
       侧栏的（本仓栽过：正文都在流了，断言却说"没有对话号"）。
    """
    end = time.time() + timeout
    while time.time() < end:
        s = active_sid(page)
        if s.startswith("s-") and s != not_sid:
            return s
        page.wait_for_timeout(200)
    return active_sid(page)


def guard(page, timeout=6):
    """点任何东西之前过一遍：「AI 怎么干活？」那个弹窗是**发完第一条消息
    之后**才弹的（mod_chat.R:1508），不是开页面时弹的。"""
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


def new_chat(page):
    guard(page)
    page.click("#chat-new_chat")
    page.wait_for_timeout(300)


def send(page, text):
    guard(page)
    page.fill("#chat-input", text)
    page.wait_for_timeout(250)
    page.click("#chat-send")


def ans_len(page):
    try:
        return page.evaluate(
            "() => { var b = document.querySelectorAll("
            "'.dsapp-msg-assistant .dsapp-bubble');"
            " return b.length ? b[b.length - 1].innerText.length : 0; }")
    except Exception:
        return -1


def wait_ans_len(page, timeout=60, minlen=1):
    """轮询到"最后一条 assistant 气泡至少有 minlen 个字"为止。

    ⚠️ minlen 不是装饰：A 节要断言的是"**已经生成的那部分**有没有被救下来"，
       只等第一个 delta 的话，救没救都分不出来（一个字的差别看不出来）。
    """
    end = time.time() + timeout
    while time.time() < end:
        n = ans_len(page)
        if n >= minlen:
            return n
        page.wait_for_timeout(200)
    return ans_len(page)


def _unused_open_chat(page):
    """开一个**已经登录过**的页面（cookie 还在），切到对话页。"""
    page.goto(C.URL, wait_until="domcontentloaded")
    if not C.wait_awake(page):
        sys.exit("新开的页面 150 秒还是空白（看一眼 %s/app.log）" % C.APP)
    page.wait_for_timeout(2500)
    C.goto(page, "chat")
    ensure_no_modal(page)
    page.wait_for_timeout(1200)


def wait_assistant(db, sid, mark, timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        if ai_hits(db, sid, mark):
            return True
        time.sleep(0.5)
    return False


def boot(page, email):
    """注册 → 认库 → 指到假 LLM → 重新登录 → 进对话页。"""
    try:
        C.enter_app(page, email=email)
    except SystemExit as e:
        sys.exit("注册没进去：%s" % e)
    uid, db = C.seed_or_die(email)
    C.seed_llm(uid, FX.url)
    # ⚠️ 必须 reload：base_url/Key 是会话级读一次进内存的，不 reload 的话
    #    这个会话手里还是空 base_url → 厂商默认地址 → **真厂商**。
    relogin(page, email)
    C.goto(page, "chat")
    ensure_no_modal(page)
    page.wait_for_timeout(1200)
    return uid, db


def main():
    log = open(os.path.join(C.OUT, "probe_disc.log"), "w")
    def say(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    global FX
    FX = C.FakeLLM()
    # 队列按到达顺序发：① 给 B 节（对照，先发）② 给 A 节（关页面那一轮）
    FX.set_queue(mk_sse("对照乙", 12), mk_sse("断线甲", 40))
    FX.slow(0.5)
    say("  假 LLM: %s（乙 12 段 / 甲 40 段，每块 500ms → 甲约 20 秒）" % FX.url)

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        email = "v157d_%s@example.com" % str(int(time.time()))[-6:]
        uid, db = boot(page, email)
        say("  uid=%s  db=%s  data_root=%s" % (uid, db, C.DATA_ROOT))

        # ================= B 节（对照）：先跑，不关页面 ===================
        #
        # ⚠️ 对照**必须排在前面**，而且**不另开页面**：开第二个页面要重新走
        #    一遍整个应用的初始化，这台机器被别的作业挤着的时候能拖过 150 秒
        #    （本仓记过：load 17 时首屏 90 秒起步），报出来是"新页面一片空白"，
        #    看着像应用坏了。而关掉页面之后的对照本来也没有意义 —— 我们量的
        #    就是"关页面会不会丢掉已经生成的内容"。
        say("\n== B 节（对照）：不关页面，让它自然跑完 ==")
        n0 = FX.req_n()
        send(page, "短的对照问题。")
        sid_b = wait_active_sid(page)
        chk("B（前提）：有了对话号", sid_b.startswith("s-"), "sid_b=%r" % sid_b)
        ok = wait_assistant(db, sid_b, "对照乙", timeout=120)
        chk("★★★ B（对照）：不关页面的那一轮**照样落库**（夹具本身是好的）",
            ok, "assistant=%r" % (msgs(db, sid_b, "assistant")[:1],))
        if ok:
            full = msgs(db, sid_b, "assistant")[-1][1] or ""
            chk("B（对照）：整段都在（末段「对照乙第12段」也在）",
                "对照乙第12段" in full, "末段在=%s" % ("对照乙第12段" in full))
        chk("B（前提）：假服务端收到了请求（没打到真厂商）", FX.req_n() > n0,
            "req_delta=%d" % (FX.req_n() - n0))

        # ================= A 节：流到一半关页面（放最后）==================
        say("\n== A 节：正文流到一半，关掉页面 ==")
        guard(page)
        new_chat(page)
        sid_prev = sid_b
        n0 = FX.req_n()
        before = set(run_files())
        send(page, "请写一份很长的分析报告。")
        sid_a = wait_active_sid(page, not_sid=sid_prev)
        chk("A（前提）：发出消息之后有了一个真实的对话号",
            sid_a.startswith("s-"), "sid_a=%r" % sid_a)
        # ⚠️ 等到正文**攒够**再关：只等到第一个字的话，"救没救下已经生成的
        #    那部分"这件事根本分不出来（差一个字符看不出来）。
        L = wait_ans_len(page, minlen=200)
        chk("A（前提）：正文真的往外流了**一大段**（关之前画面上有 200+ 字）",
            L >= 200, "字数=%d" % L)
        d = FX.req_n() - n0
        chk("A（前提）：假服务端真的收到了请求（没打到真厂商）", d > 0,
            "req_delta=%d" % d)

        news = [f for f in run_files() if f not in before]
        chk("A（前提）：data/run/ 里出现了这一轮的中转文件（.out）",
            len(news) == 1, "新增=%r 全部=%r" % (news, run_files()))
        out_a = news[0] if news else None
        sz_mid = (os.path.getsize(os.path.join(run_dir(), out_a))
                  if out_a else 0)
        chk("A（前提）：那个 .out 已经有内容了（子进程真的在写）",
            sz_mid > 0, "size=%d" % sz_mid)
        chk("A（前提）：用户那条消息已经落库（后面才有资格谈「丢了回复」）",
            len(msgs(db, sid_a, "user")) == 1,
            "user 条数=%d" % len(msgs(db, sid_a, "user")))

        # 关掉这个页面 —— 服务端看到的就是 websocket 断开 → onSessionEnded
        page.close()
        say("  [%.1fs] 页面已关闭（此刻正文 %d 字，.out %d 字节），等 10 秒…"
            % (time.time() % 1000, L, sz_mid))
        time.sleep(10)

        hit = ai_hits(db, sid_a, "断线甲")
        all_ai = msgs(db, sid_a, "assistant")
        chk("★★★ A：关页面之后，**已经生成的那些字还在库里**（assistant 有一条）",
            len(all_ai) > 0,
            "assistant 条数=%d（这一条今天必红：一个字都没留下）" % len(all_ai))
        chk("★★★ A：留下来的是**断线前已经生成的部分**，不是空串",
            bool(hit) or any(len(r[1] or "") > 0 for r in all_ai),
            "命中=%r" % (hit,))
        # ⚠️ 这两条是防"另一种绿"的：只断言"库里有字"的话，一个**事后重问
        #    一次**、把整段答案补上的实现也能过 —— 而那不是这个 bug 的修法
        #    （那会白烧一遍 token，而且用户看到的是第二条答案）。
        #    假 LLM 这一轮一共 40 段（整段约 1800+ 字），关页面时才吐了 4 段
        #    出头（232 字），所以"半截"这个形状是**量得出来**的。
        _txt = (all_ai[-1][1] if all_ai else "") or ""
        chk("★★★ A：留的是断线那一刻的**半截**，不是事后重问的整段",
            0 < len(_txt) < 1200, "长度=%d（整段约 1800+）" % len(_txt))
        chk("A：并且说清了它是什么（带平台注记）",
            "浏览器页面已关闭" in _txt, "注记在=%s" % ("浏览器页面已关闭" in _txt))
        got = run_files()
        still = out_a in got if out_a else False
        say("  data/run/ 现在=%r" % (got,))
        say("  → 那一轮的中转文件 %s（被删掉 = dsapp_llm_abort 跑过）"
            % ("还在" if still else "已消失"))
        say("  A 节回库：user=%d 条，assistant=%d 条，tool=%d 条"
            % (len(msgs(db, sid_a, "user")), len(all_ai),
               len(msgs(db, sid_a, "tool"))))

        browser.close()

    say("\n===== 结论 =====")
    say("A 节（关页面）落库的 assistant 条数 = %d" % len(msgs(db, sid_a, "assistant")))
    say("B 节（不关）  落库的 assistant 条数 = %d" % len(msgs(db, sid_b, "assistant")))
    _chk.done()
    log.close()
    return 0 if N_BAD[0] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
