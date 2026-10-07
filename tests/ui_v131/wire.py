# -*- coding: utf-8 -*-
"""V13.1 的「线上那一根线」：把请求**真的**发出去，再看它长什么样。

★ 为什么非要有这么一个脚本
  item 2 的用户原话是「kimi的api显示可用，但实际的HTTP 400」——「显示可用」
  和「实际可用」是两件事，而**界面测试只能证明前一件**。温度滑块画对了、
  Key 框填对了、厂商选对了，一路上全都是绿的，而发出去的 JSON 里照样可能
  带着一个会把请求打死的 temperature。
  所以这一节不看界面，只看**假 LLM 服务端收到的那具尸体**。

★ 一次跑完三个 item（它们最后都落在同一个请求体上）
  · item 2：只接受 temperature=1 的模型，请求体里**不能有** temperature 这个键
  · item 5：切厂商之后，Authorization 里那把 Key 必须是**这一家**的
  · item 6：system 消息里要写明模型**自己是谁**（不然它会照着训练语料
            答"我是 Claude"）

★ 为什么用自定义/中转那个厂商
  只有它的 base_url 是空的、可以由用户随便填 —— 于是能把请求打到本机这个
  假服务上。别的厂商地址是写死的官方域名，真发出去就是拿用户的额度去撞墙。

★ 为什么服务端是本进程里的一个线程
  和 R 那边的自检不一样：那里 R 是**单线程阻塞**在请求上的，httpuv 的回调
  要事件循环转起来才跑，同进程必然死锁（见 selftest.R 里那段说明）。
  Python 这边 GIL 让线程照常跑，一个后台线程就够了，不用起子进程。
"""
import http.server
import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, pick_select   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

SSE = ('data: {"choices":[{"delta":{"content":"收到。"},"finish_reason":null}]}\n\n'
       'data: {"choices":[{"delta":null,"finish_reason":"stop"}]}\n\n'
       'data: {"usage":{"prompt_tokens":11,"completion_tokens":2,'
       '"total_tokens":13}}\n\n'
       'data: [DONE]\n\n').encode()

LOCK = threading.Lock()
SEEN = []          # 收到过的请求：dict(body=..., auth=..., path=...)


class Capture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            body = {"__raw__": raw.decode("utf-8", "replace")}
        with LOCK:
            SEEN.append({"path": self.path,
                         "auth": self.headers.get("Authorization") or "",
                         "body": body})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(SSE)))
        self.end_headers()
        self.wfile.write(SSE)

    def log_message(self, *a):
        pass          # 别把每个请求都打到测试输出里


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Capture)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/v1" % PORT
print("  假 LLM 服务在 %s" % BASE, flush=True)


def last():
    with LOCK:
        return SEEN[-1] if SEEN else None


def wait_for(n, timeout=45):
    """等第 n 个请求到（含）。返回 True/False，不抛。"""
    end = time.time() + timeout
    while time.time() < end:
        with LOCK:
            if len(SEEN) >= n:
                return True
        time.sleep(0.3)
    return False


def sysmsg(req):
    for m in req["body"].get("messages") or []:
        if m.get("role") == "system":
            return m.get("content") or ""
    return ""


def model_now(page):
    """现在这个框里**真的**是什么模型名。"""
    return page.evaluate("() => document.querySelector('#model-model').value")


def set_model_free(page, value):
    """在模型下拉里手打一个清单里没有的名字（create=TRUE 允许）。

    ★ 为什么打完要**回读一次**
      这里原来打完就走，不回读。于是当"改不进去"（见下面那段 maxItems 的说明）
      发生时，脚本继续往下跑，最后在「请求体里应该有 temperature」那一条上
      报红 —— 而真正的原因是**模型压根没换成 deepseek-v4-pro，发出去的还是
      kimi-k3**，kimi-k3 本来就不带 temperature。断言红在了离病因十万八千里的
      地方，extra 里也只有一串 body 的 key，看不出是哪个模型。
      一个"失败信息会指错方向"的测试比没有测试更费时间。
    """
    ctrl = page.locator(
        "xpath=//select[@id='model-model']/following-sibling::div"
        "[contains(@class,'selectize-control')]")
    ctrl.locator(".selectize-input").click()
    page.wait_for_timeout(400)
    ctrl.locator("input").first.click()
    page.keyboard.press("Control+A")
    page.keyboard.type(value, delay=40)
    page.wait_for_timeout(700)
    opt = ctrl.locator(".option[data-value=%s]" % json.dumps(value))
    if opt.count() == 0:
        page.keyboard.press("Enter")     # 让 selectize 现场建一个
    else:
        opt.first.click()
    page.wait_for_timeout(1200)
    got = model_now(page)
    if got != value:
        # 不抛，让调用方自己断言（这里只把实情报出来）
        print("  ⚠️ 模型没设成 %r，框里现在是 %r" % (value, got), flush=True)
    return got


KEY_A = "sk-wire-deepseek-AAAA"
KEY_B = "sk-wire-moonshot-BBBB"


def send_chat(page, text):
    page.fill("#chat-input", text)
    page.wait_for_timeout(600)
    page.click("#chat-send")
    page.wait_for_timeout(500)


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="线路")
    goto(page, "settings", wait=4000)

    # ---- 把应用指到本机的假服务上 ---------------------------------------
    pick_select(page, "model-vendor", "custom")
    page.wait_for_timeout(1500)
    page.fill("#model-base_url", BASE)
    page.wait_for_timeout(600)
    set_model_free(page, "kimi-k3")     # 只接受 temperature=1 的那个
    chk("★★ 自定义模型名真的写得进去（自由输入框选过一次之后还能改 —— "
        "selectize maxItems=1 会把输入框锁死，只能从下拉里挑）",
        model_now(page) == "kimi-k3", extra=repr(model_now(page)))
    page.fill("#model-api_key", KEY_A)
    page.wait_for_timeout(2500)

    # ---- 回对话页，发一条 --------------------------------------------------
    goto(page, "chat", wait=2500)
    page.click("#chat-new_chat")
    page.wait_for_timeout(2500)
    send_chat(page, "你好")

    got = wait_for(1)
    r1 = last()
    chk("★★ 请求真的打到了本机的假服务上（base_url 被用上了，没跑到官方域名去）",
        got and r1 is not None and "/chat/completions" in r1["path"],
        extra=(r1 or {}).get("path"))

    if got and r1:
        b = r1["body"]
        # ---- item 5：用的是这一家的 Key ----------------------------------
        chk("★★ 请求头里带的是**这一家**的 Key（不是上一家的、也不是空）",
            KEY_A in r1["auth"], extra=r1["auth"][:40])
        chk("★ 模型名原样发出去了", b.get("model") == "kimi-k3",
            extra=b.get("model"))
        chk("★ 是流式请求", b.get("stream") is True, extra=b.get("stream"))

        # ---- item 2：真的没有 temperature --------------------------------
        chk("★★★ kimi-k3 的请求体里**没有** temperature 这个键"
            "（用户报的 HTTP 400 就是它 —— 界面绿不绿和它无关）",
            "temperature" not in b, extra=sorted(b.keys()))

        # ---- item 6：system 里说了它是谁 ---------------------------------
        sp = sysmsg(r1)
        chk("★★★ system 消息里写明了模型自己是谁（不给它事实，它就照训练语料"
            "答「我是 Claude」）",
            "你实际是什么模型" in sp and "kimi-k3" in sp,
            extra=sp[:200])
        chk("★★ 而且明确禁止它自称 Claude/GPT 那些",
            "不要" in sp and "Claude" in sp, extra=sp[:200])
        chk("★ system 里没有把它说成别家（不是「你是 Claude」那种模板）",
            "你是 Claude" not in sp and "You are Claude" not in sp)

    # ---- 换一个**不在锁定名单**里的模型，温度必须回来 ---------------------
    print("\n== 换成 deepseek-v4-pro（温度该带着）==", flush=True)
    goto(page, "settings", wait=3500)
    set_model_free(page, "deepseek-v4-pro")
    page.wait_for_timeout(1200)
    goto(page, "chat", wait=2500)
    send_chat(page, "再来一条")

    chk("★ 第二个请求到了", wait_for(2))
    r2 = last()
    if r2:
        chk("★★★ 对照组：换了个模型，temperature **回来了**"
            "（不是把所有请求的温度都掐了）",
            "temperature" in r2["body"], extra=sorted(r2["body"].keys()))
        chk("★★ 而且 system 里的模型名跟着换成了新的"
            "（提示词里的身份必须和这次真正发出去的模型一致）",
            "deepseek-v4-pro" in sysmsg(r2) and "kimi-k3" not in sysmsg(r2),
            extra=sysmsg(r2)[:160])

    # ---- 切厂商之后再发：Key 要跟着换 -------------------------------------
    print("\n== 切一次厂商，看 Key 有没有跟着换 ==", flush=True)
    n_before = len(SEEN)
    goto(page, "settings", wait=3500)
    page.fill("#model-api_key", KEY_A)          # 先确保 A 家在框里
    page.wait_for_timeout(2000)
    # 切走再切回来（走的正是用户抱怨的那条路：每次都要重新复制一遍）
    pick_select(page, "model-vendor", "deepseek")
    page.wait_for_timeout(2000)
    pick_select(page, "model-vendor", "custom")
    page.wait_for_timeout(2000)
    page.fill("#model-base_url", BASE)          # 自定义厂商的地址不会被记住的那份覆盖
    page.wait_for_timeout(800)
    chk("★★ 切回自定义那家，Key 自动带回来了（用户不用再复制一遍）",
        page.input_value("#model-api_key") == KEY_A,
        extra=repr(page.input_value("#model-api_key")))

    goto(page, "chat", wait=2500)
    send_chat(page, "切回来再发一条")
    chk("★ 第三个请求到了", wait_for(n_before + 1))
    r3 = last()
    if r3:
        chk("★★★ 切回来之后发出去的还是 A 家的 Key"
            "（不是空、也不是 B 家那把）",
            KEY_A in r3["auth"], extra=r3["auth"][:40])
        chk("★ 地址也还是本机假服务（切厂商没把 base_url 弄丢）",
            "/chat/completions" in r3["path"], extra=r3["path"])

    page.screenshot(path=OUT + "/wire.png", full_page=True)
    br.close()

srv.shutdown()
sys.exit(chk.done())
