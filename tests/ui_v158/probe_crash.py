#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.8 item 4：**页面为什么"崩溃"** —— 量出来，不猜。

用户原话：「4、我用了千问的大模型，页面还是会崩溃」。

⚠️ 先摆清楚 V15.7 item 8 的结论边界：那一条证明的是「模型被刷新回旧值」和
   崩溃**没有因果关系**，它**从没说过崩溃本身被修好了**。崩溃是另一条一直
   开着的 bug，这个探针就是冲它去的。

线上证据（从库里读出来的，不是推断）：
    消息里出现「浏览器页面已关闭」= R worker **还活着**、是**浏览器那一端**
    断了（那句话是 worker 写的，worker 死了就没人写）。今天 uid=11 那个对话
    里出现 5 次，其中两次和一条 18KB 级的 assistant 回复**同一秒**落库。
    → 指向"渲染超大回复把浏览器那一端搞死了"。

这个探针量的是**渲染层**：喂一条和线上同量级（约 18KB、含多个代码块）的
回复，在**流式过程中**采三样东西：

  1. `longtask`（浏览器自己报的"主线程被独占超过 50ms 的事件"）
     —— 累计阻塞时长 / 最长一次。这是"页面没响应"的**直接**度量。
  2. JS 堆大小 + DOM 节点数 —— 是"卡"还是"爆内存"。
  3. `page.evaluate` 的往返耗时 —— 主线程被占住时它会明显变慢，
     这是"用户点不动"的等价物。
  4. `page.on("crash")` —— 真崩了会在这里现身（Chrome 的渲染进程 OOM）。

★ 为什么不能只看"跑完了没有"：卡 5 秒和卡 0.05 秒在功能上**都是"跑完了"**，
  只有把阻塞时长量出来才分得开。而不量的话，这个 bug 永远只能靠用户报。

⚠️⚠️ 第一版（2026-10-02）**绿着撒谎**，记在这里免得重蹈：
   它用 `C.sse(reply)` 把 32507 字符塞进**一个** SSE 事件，只靠 `slow(0.03)`
   把 3 个事件隔开 —— 正文一次到齐。结果是：
     · `#chat-streaming` 60 秒里一直是空的（正文到齐的同时那一轮也结束了）；
     · 三条主案「没被独占 / 累计阻塞<10s / 往返<3s」**全绿** ——
       而它们量的是"什么都没发生"：longtask 0 次、累计 0ms、DOM 峰值 1414。
     · 唯一红的是我顺手写的**前置断言**「正文真的开始流了」。
   这就是本仓记过的「自检全绿 ≠ 功能被验过」。所以这一版：
     · 正文切成 ~100 字符一个事件（`sse_chunks`）—— 才是线上的形状；
     · 「正文真的在流」升格成 ★★★ 地基断言，它红了后面一律不必看；
     · 补了「用户最后看得见什么」（回复落在 `#chat-history` 里）——
       第一版连这个都没有，落库成功 ≠ 界面画出来。
"""

import json
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8952/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158c/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
# 弹窗那两下复用 item 3 的（probe_switch 也是这么导的）：那个「AI 怎么干活？」
# 首选项弹窗的处理只该有一份实现 —— 它炸的时候要 sys.exit 说清楚"压着一个
# **不认识的**弹窗"，自己再抄一份迟早走样。
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]

# 采集器：装一次，之后随时读。用 PerformanceObserver 收 longtask，
# 用 rAF 采样帧间隔（主线程被占住时 rAF 会停摆），用 performance.memory
# 看堆。⚠️ performance.memory 是 Chromium 私有扩展，取不到就记 None，
# **不要**补 0 —— "这家不报这个数"和"真的是 0"是两回事（本仓的老规矩）。
# ⚠️⚠️ 这里原来挂过一版 WebSocket 钩子（page.add_init_script 里替换
#    window.WebSocket，记每条收到的消息），想直接量"服务端多久没说话"。
#    **它收不到东西**：这个应用走的是 SockJS（服务端进程就叫
#    SockJSAdapter.R），SockJS 不经过 window.WebSocket 这个构造器，
#    实测全程 0 条 —— 而当时那两条"服务端没长时间沉默"的断言**照样是绿的**
#    （None > 8000 为假 → 判成"没超"）。又是「自检全绿 ≠ 功能被验过」。
#    已经拆掉，换成不依赖任何钩子的判据：**流式区字数的增长本身就是
#    服务端在说话**（那一格是服务端 renderUI 推下来的），见下面 stall 那段。

_WATCH = r"""
() => {
  window.__dsProbe = {tasks: [], frames: [], heap: [], dom: []};
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) window.__dsProbe.tasks.push(e.duration);
    }).observe({entryTypes: ['longtask']});
  } catch (e) { window.__dsProbe.noLongTask = String(e); }
  let last = performance.now();
  const tick = () => {
    const t = performance.now();
    window.__dsProbe.frames.push(t - last);
    last = t;
    window.__dsProbe.heap.push(
      (performance.memory && performance.memory.usedJSHeapSize) || null);
    window.__dsProbe.dom.push(document.getElementsByTagName('*').length);
    window.__dsRaf = requestAnimationFrame(tick);
  };
  window.__dsRaf = requestAnimationFrame(tick);
  return true;
}
"""

_STOP = r"""
() => {
  if (window.__dsRaf) cancelAnimationFrame(window.__dsRaf);
  const p = window.__dsProbe || {tasks: [], frames: [], heap: [], dom: []};
  const num = (a) => a.filter((x) => typeof x === 'number' && isFinite(x));
  const tasks = num(p.tasks), frames = num(p.frames);
  const heap = num(p.heap), dom = num(p.dom);
  const sum = (a) => a.reduce((x, y) => x + y, 0);
  const mx  = (a) => (a.length ? Math.max(...a) : null);
  return {
    n_task: tasks.length,
    task_total: Math.round(sum(tasks)),
    task_max: mx(tasks) === null ? null : Math.round(mx(tasks)),
    n_frame: frames.length,
    frame_max: mx(frames) === null ? null : Math.round(mx(frames)),
    // 帧间隔 >200ms 的采样点数 = "肉眼可见地卡住"的次数
    n_stall: frames.filter((x) => x > 200).length,
    heap_first: heap.length ? Math.round(heap[0] / 1048576) : null,
    heap_max: heap.length ? Math.round(mx(heap) / 1048576) : null,
    dom_max: dom.length ? mx(dom) : null,
    // 断连/无响应遮罩在**采样结束那一刻**还在不在（过程中出现过没有由
    // 外面逐拍记的 offs 说了算，那一个更准）。
    offline: (() => {
      const d = document.getElementById('dsapp-offline');
      return d ? (d.getAttribute('data-kind') || 'yes') : null;
    })(),
  };
}
"""


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


def big_reply(n_code=2, body=6000):
    """拼一条和线上同量级的大回复。

    线上那条（id=688）是 18880 字符、正文里带着两三个 python 代码块。
    这里按同样的形状造：每个代码块前面一段解释，块内是几十行真代码 ——
    markdown 渲染 + 代码高亮的开销主要就来自这些块。
    """
    parts = ["我需要继续完成数据可行性与供体元数据审计工作。让我创建一个更完整的"
             "脚本，填充实际的数据下载记录：\n"]
    for k in range(n_code):
        parts.append("```python\n")
        parts.append("# 第 %d 段：收集并核对元数据\n" % (k + 1))
        parts.append("import os\nimport pandas as pd\nimport requests\n\n")
        for i in range(40):
            parts.append(
                "def step_%d_%d(manifest_path, out_dir):\n"
                "    # 逐条核对供体编号、文库编号与下载状态，缺失的记进 missing\n"
                "    rows = []\n"
                "    for line in open(manifest_path, encoding='utf-8'):\n"
                "        donor, lib, url = line.strip().split('\\t')\n"
                "        rows.append({'donor': donor, 'library': lib, "
                "'url': url, 'ok': bool(url)})\n"
                "    df = pd.DataFrame(rows)\n"
                "    df.to_csv(os.path.join(out_dir, 'm_%d_%d.tsv'), "
                "sep='\\t', index=False)\n"
                "    return len(df)\n\n" % (k, i, k, i))
        parts.append("```\n\n")
        parts.append("上面的脚本会把第 %d 组结果写进 %s。"
                     "注意要按供体去重，同一份数据不要重复统计。\n\n"
                     % (k + 1, "`m_%d.tsv`" % k))
    # 补到目标字符数（用正文，不再加代码块）
    filler = ("另外，元数据里的年龄字段存在单位不一致的问题，需要在合并前统一，"
              "否则后面的分层分析会整体偏移。这一步要单独记一条日志，"
              "方便回溯是哪一批数据被改动过。\n")
    while sum(len(x) for x in parts) < body * 3:
        parts.append(filler)
    return "".join(parts)


def sse_chunks(text, size=100):
    """把正文切成**很多**小段，一段一个 SSE 事件。

    ★★ 为什么非这样不可（第一版探针就栽在这里）：
       `_common.sse()` 把整段正文塞进**一个** content 事件里，配合 `slow()`
       只是把 3 个事件隔开 0.03 秒 —— 正文**一次到齐**。于是：
        · 页面在**一个轮询周期内**就拿到了全部 32507 字符；
        · 量出来"longtask 0 次、累计阻塞 0ms、最长帧 124ms" —— 一片大好；
        · 而 `#chat-streaming` 60 秒里一直是空的（正文到齐的同时这一轮也
          结束了，那一格已经收掉）—— **三条主案全绿，量的却是"什么都没发生"**。
       这正是本仓记过好几遍的「自检全绿 ≠ 功能被验过」：主案通过不代表它
       **测到了东西**，所以这一版把"正文真的在流"写成了前置断言，它一红
       就把后面那三条的成色全废掉。

    线上的形状是：模型一个字一个字往外吐，服务端每 200ms 轮询一次，每拿到
    新内容就把**整段（越来越长的）正文**重新渲染一遍。所以开销是
    O(轮询次数 × 正文长度)，比"一次巨型渲染"高一个量级 ——
    要量它，就必须真的分很多段吐。
    """
    out = []
    for i in range(0, len(text), size):
        out.append("data: " + json.dumps(
            {"choices": [{"delta": {"content": text[i:i + size]},
                          "finish_reason": None}]}) + "\n\n")
    out.append("data: " + json.dumps(
        {"choices": [{"delta": None, "finish_reason": "stop"}]}) + "\n\n")
    out.append("data: [DONE]\n\n")
    return "".join(out)


def reason_chunks(n_chunk=140, size=90):
    """造一段**很长**的思维链，切成很多段 —— 千问那条路的形状。

    ★ 为什么 item 4 非要有这一幕：用户报的是「用了**千问**的大模型页面还是会
      崩溃」，而 qwen3.8-max 是推理模型 —— `reasoning_content` 在 R/llm.R 里是
      **无条件解析**的（R/llm.R:223-225，跟 thinking/reasoning_effort 那两个
      只有 DeepSeek 认的开关无关），所以千问的思维链会走**思考区**那条路。
      而思考区和正文区是**两条不同的渲染路径**：
        · 正文：服务端 renderUI 推 #chat-streaming（上面那一幕量的就是它）；
        · 思考：session$sendCustomMessage("dsapp:think") → www/app.js 往
          #chat-think_pre 里 appendChild（**不经过任何 renderUI**）。
      只量正文那一幕就下"千问不会崩"的结论，等于没测用户真走的那条路。
    """
    parts = []
    for i in range(n_chunk):
        s = "第 %d 步：先核对序列长度与链的划分，再看结合位点有没有被埋住。" % (i + 1)
        parts.append((s + "这一步要反复确认，不能想当然。" * 8)[:size])
    return parts


# ⚠️ **不要拿图标/中文标签当判据**这条在本仓踩过好几次；这里两个采样器返回的
#    都是**数字**（字符数）和**对象身份**，不依赖任何文案。

# 正文那一格。第三个返回值给 null（这一格没有附加信息）。
_JS_TEXT = r"""
() => {
  const el = document.querySelector('#chat-streaming');
  const d = document.getElementById('dsapp-offline');
  return [el && el.innerText ? el.innerText.length : 0,
          d ? (d.getAttribute('data-kind') || 'yes') : null, null];
}
"""

# 思考那一格。★ 关键在 `__gen`：给当下这个 #chat-think_pre 节点发一个**身份号**，
# 节点被 renderUI 重建的话新节点会拿到新号 —— 一轮下来见过几个号 = 这一格被
# 重画过几次。这正是 V15.4 item 3 修的那个"闪"的根（每 200ms 拆掉重建，
# CSS 动画跟着元素从 0 度重来），也是文字**会不会被重置**的根。
_JS_THINK = r"""
() => {
  const g = window.__dsThink = window.__dsThink || {n: 0, seen: {}};
  const el = document.getElementById('chat-think_pre');
  let n = 0, gen = 0;
  if (el) {
    if (!el.__gen) el.__gen = ++g.n;
    g.seen[el.__gen] = 1;
    gen = el.__gen;
    n = el.textContent.length;
  }
  const d = document.getElementById('dsapp-offline');
  return [n, d ? (d.getAttribute('data-kind') || 'yes') : null,
          {gen: gen, ngens: Object.keys(g.seen).length,
           label: (document.getElementById('chat-think_label') || {}).textContent || '',
           nbox: (document.getElementById('chat-think_n') || {}).textContent || '',
           content: (document.querySelector('#chat-streaming') || {}).innerText ? 1 : 0}];
}
"""


def sample_stream(page, js, limit=240, wait=200):
    """连续采样一格，直到它连续三拍没字。

    ★ 为什么**不看** send 按钮的状态：正文一次到齐时它一闪而过，跟着它走就会
      在"还没开始"的时候退出（第一版探针就是这么绿着撒谎的，见文件头上那段）。
      改成按时间连续采，每一拍记一行 —— 有分歧的时候，这份时间线就是证据本身。

    返回 recs=[(t, 字符数, evaluate 往返秒, 附加对象), …] 和几个汇总。
    """
    t0 = time.time()
    out = {"recs": [], "seen": 0, "worst": 0.0, "offs": set(), "err": None,
           "dur": 0.0}
    idle = 0
    while time.time() - t0 < limit:
        s = time.time()
        try:
            n, off, extra = page.evaluate(js)
            page.evaluate("1")          # 空往返：主线程被占住时它会变慢
        except Exception as e:
            out["err"] = str(e)
            break
        rt = time.time() - s
        out["worst"] = max(out["worst"], rt)
        out["seen"] = max(out["seen"], n or 0)
        if off:
            out["offs"].add(off)
        out["recs"].append((round(time.time() - t0, 2), n or 0, round(rt, 3), extra))
        if n:
            idle = 0
        else:
            idle += 1
            if out["seen"] > 0 and idle >= 3:
                break
        page.wait_for_timeout(wait)
    out["dur"] = time.time() - t0
    return out


def stall_of(recs):
    """服务端"最长一次不出声"有多久。

    判据不依赖任何钩子：#chat-streaming / #chat-think_pre 都是**服务端**推下来
    的内容，字数在长就说明服务端在说话。⚠️ 挂 WebSocket 钩子那版收不到东西
    （这个应用走 SockJS，不经过 window.WebSocket），却又**照样绿** —— 见文件
    头上那段的记录。返回 (增长过的时间点列表, 最长间隔秒)。
    """
    inc = [(t, n) for (t, n, _r, _x) in recs if n > 0]
    stall = 0.0
    if len(inc) >= 2:
        last = inc[0][0]
        for (t, n), (_pt, pn) in zip(inc[1:], inc[:-1]):
            if n > pn:
                stall = max(stall, t - last)
                last = t
    return [t for (t, _n) in inc], stall


def fire(page, text):
    """填字 + 点发送，**不等它跑完**。

    ⚠️ 非等不可的理由反过来了：这个探针要的就是**在流式过程中**采样，等它
       跑完再采样等于什么都没采（见文件头上第一版那段）。

    ★ 点失败要**先收一次弹窗再点**：那个「AI 怎么干活？」首选项弹窗是
      **发出第一条消息之后**才弹的（mod_chat.R 的 dsapp_chat_send，位置在
      所有闸门之后），它会盖在整页上 —— 那时 click 报的是
      「#chat-send intercepts pointer events」，**报错指向发送按钮本身**，
      和真正的原因隔着十万八千里（本仓记过的 first-run-onboarding-modal）。
      第一版这一幕就栽在这儿：大回复流完（65 秒）之后那个弹窗已经在页上，
      第二幕的点击直接超时 30 秒。
    """
    page.wait_for_selector("#chat-input", timeout=30000)
    ensure_no_modal(page)
    page.fill("#chat-input", text)
    try:
        page.click("#chat-send", timeout=8000)
    except Exception:
        ensure_no_modal(page)
        page.click("#chat-send", timeout=25000)


def main():
    os.makedirs(C.OUT, exist_ok=True)
    log = open(os.path.join(C.OUT, "probe_crash.log"), "w")

    def say(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    fx = C.FakeLLM()
    reply = big_reply()
    say("  假 LLM: %s" % fx.url)
    say("  这条回复 **%d 字符**（线上那条 18880）" % len(reply))

    crashed = [False]

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        page.on("crash", lambda _p: crashed.__setitem__(0, True))
        errs = []
        page.on("pageerror", lambda e: errs.append(str(e)))

        email = "v158x_%s@example.com" % str(int(time.time()))[-6:]
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            sys.exit("注册没进去：%s" % e)
        uid, db = C.seed_or_die(email)
        # 线上那个账号就是千问 + qwen3.8-max，这里照着配（地址仍指假服务端）。
        C.seed_llm(uid, fx.url, vendor="qwen", model="qwen3.8-max")
        say("  uid=%s  db=%s  vendor=qwen model=qwen3.8-max" % (uid, db))

        page.reload(wait_until="domcontentloaded")
        for _ in range(180):
            if page.locator(".dsapp-shell").count():
                break
            page.wait_for_timeout(1000)
        C.goto(page, "chat")
        page.wait_for_timeout(1500)

        # ★ 先发一条**小**的，把那个「AI 怎么干活？」首选项弹窗引出来收掉。
        #
        # ⚠️ 它是**发出第一条消息之后**才弹的（mod_chat.R 的 dsapp_chat_send
        #    里，位置在所有闸门之后）。不先处理的话，它会在大回复的**流式过程
        #    中**盖上来 —— 那一幕量到的"阻塞"里就混进了一次弹窗渲染，而那是
        #    "这个账号第一次发消息"才有的一次性事件，不是要测的东西。更糟的是
        #    它还会一直盖在页上，把下一幕的发送按钮挡死。
        #    选「都先别开，我自己盯着」是要的：自动执行开着的话 agent 循环会
        #    自己往下跑，"发一条、量一条"的时序全乱。
        say("\n== 先发一条短的（把首选项弹窗引出来收掉，免得它盖在大回复上）==")
        fx.set_queue(C.sse(content="好。"))
        send_wait(page, "在吗")
        ensure_no_modal(page)
        say("  弹窗收掉了（之后不会再弹：agent_pref 已经存过答案了）")

        # 先量一次**空白页**的基线：没有它，后面的数字说明不了任何事
        # （"阻塞 800ms"是多是少，只有和"什么都不干时"比才知道）。
        page.evaluate(_WATCH)
        page.wait_for_timeout(3000)
        base = page.evaluate(_STOP)
        say("\n== 基线（什么都没跑，3 秒）==")
        say("  longtask 次数=%s 累计=%sms 最长=%sms | rAF 采样=%s 最长帧=%sms"
            % (base["n_task"], base["task_total"], base["task_max"],
               base["n_frame"], base["frame_max"]))
        chk("★ 前提：采集器真的在跑（rAF 采到了样；不然下面全是 0，看着像满分）",
            (base["n_frame"] or 0) > 30, "只采到 %s 帧" % base["n_frame"])

        # ---- 正式：喂那条大回复，全程采集 ------------------------------
        CH = 100                      # 每个 SSE 事件吐多少字符
        DELAY = 0.20                  # 每个事件间隔 —— 比 200ms 的轮询周期略快，
                                      # 于是**每一拍都有新字**、每一拍都重画一次。
                                      # 这正是线上那条路的负载形状，也是要量它的原因。
        n_chunk = (len(reply) + CH - 1) // CH
        say("\n== 发一条，让假模型吐 %d 字符（切成 %d 个 SSE 事件、每个间隔 "
            "%.2fs ≈ 真实流式，全程约 %.0f 秒）=="
            % (len(reply), n_chunk, DELAY, n_chunk * DELAY))
        fx.set_queue(sse_chunks(reply, CH))
        fx.slow(DELAY)

        page.evaluate(_WATCH)
        fire(page, "继续")

        # 采样循环的退出条件：正文出现过**并且**已经连续几拍空了。
        r = sample_stream(page, _JS_TEXT)
        seen_text, worst, samples, offs = r["seen"], r["worst"], r["recs"], r["offs"]
        if r["err"]:
            say("  ⚠️ evaluate 抛了（主线程被占住的信号）：%s" % r["err"])
        say("  跑了 %.1f 秒；正文最长见到 **%d 字符**；evaluate 往返最慢 **%.2f 秒**"
            % (r["dur"], seen_text, worst))
        # 时间线（每 10 拍打一行，别把日志刷爆）
        say("  时间线 (t, 流式区字符数, evaluate 往返秒):")
        for i, s in enumerate(samples):
            if i % 10 == 0 or s[2] > 0.5:
                say("    %6.2fs  流式区=%6d  往返=%.3fs" % s[:3])

        fin = page.evaluate(_STOP)
        fx.no_slow()

        say("\n== 结果（流式全程）==")
        say("  longtask 次数=%s 累计阻塞=%sms 最长一次=%sms"
            % (fin["n_task"], fin["task_total"], fin["task_max"]))
        say("  rAF 采样=%s 帧；最长帧间隔=%sms；>200ms 的卡顿=%s 次"
            % (fin["n_frame"], fin["frame_max"], fin["n_stall"]))
        say("  JS 堆：开始 %sMB → 峰值 %sMB；DOM 节点峰值 %s"
            % (fin["heap_first"], fin["heap_max"], fin["dom_max"]))
        say("  渲染进程崩过：%s；pageerror：%s" % (crashed[0], errs[:2] or "无"))
        # ---- 服务端那一侧：它有没有"长时间不说话" -------------------------
        #
        # 判据不依赖任何钩子：#chat-streaming 那一格是**服务端** renderUI 推下来
        # 的，它的字数在长 = 服务端在说话。把"两次字数增长之间最长隔了多久"
        # 算出来就是服务端的沉默时长。
        #
        # ⚠️ 为什么这比挂钩子可靠：这个应用走 SockJS，挂在 window.WebSocket 上
        #    的钩子一条都收不到（上一版实测 0 条），而当时那两条断言**照样绿**。
        inc, stall = stall_of(samples)
        say("  服务端：流式区字数增长 %d 次；**两次增长之间最长隔了 %.1f 秒**"
            % (len(inc), stall))
        say("  断连遮罩 #dsapp-offline 出现过：%s" % (sorted(offs) or "没有"))

        chk("★★ 前提：假服务端真的收到了这条请求（没收到就是发去真厂商了）",
            fx.req_n() > 0, "req_n=%d" % fx.req_n())
        # ★★ 这一条是**整个文件的地基**：正文没在流的话，下面三条"没卡"
        #    全是废话（第一版就是这样绿的）。它红了，后面就不必看了。
        chk("★★★ 前提：正文**真的在流**（流式区见到过字；不然主案量的是"
            "「什么都没发生」）", seen_text > 200,
            "流式区最多只见到 %d 字符 —— 正文一次到齐的话就是这个样子"
            % seen_text)

        # 用户最后**看得见**什么：这一条第一版压根没有。落库成功 ≠ 界面画出来
        # （本仓的老规矩：「函数对」≠「界面对」）。
        msgs = page.evaluate(
            "() => (document.querySelector('#chat-history') || {}).innerText || ''")
        head = reply[:40]
        chk("★★ 用户看得见：整段回复最后落在消息列表里（不是只在库里）",
            head in msgs, "消息区里找不到开头那句；区内 %d 字符" % len(msgs))

        chk("★★ 页面**没有**崩（渲染进程还活着）", not crashed[0],
            "page.on('crash') 触发了")
        chk("★★★ 【item 4 主案】流式期间主线程**没有被长时间独占**"
            "（最长一次 longtask < 2000ms）",
            (fin["task_max"] or 0) < 2000,
            "最长一次独占 %sms —— 用户那边就是「点了没反应」"
            % fin["task_max"])
        chk("★★★ 【item 4 主案】整段流式下来累计阻塞 < 10 秒",
            (fin["task_total"] or 0) < 10000,
            "累计阻塞 %sms（rAF 最长帧 %sms，卡顿 %s 次）"
            % (fin["task_total"], fin["frame_max"], fin["n_stall"]))
        chk("★★ evaluate 往返最慢一次 < 3 秒（界面全程点得动）",
            worst < 3.0, "最慢一次 %.2f 秒" % worst)

        # ★★ 服务端那一侧，前置断言同样是地基：增长次数太少的话，
        #    下面的"沉默时长"是拿两三个点算出来的，说明不了任何事。
        chk("★★ 前提：流式区的字数**长了很多次**（服务端一直在推）",
            len(inc) > 20, "只长了 %d 次" % len(inc))
        chk("★★★ 【item 4 主案·服务端】R worker **没有长时间说不出话**"
            "（字数两次增长之间最长 < 5 秒；前端看门狗的判死线是 16 秒）",
            stall < 5.0,
            "最长 %.1f 秒没动静 —— 服务端被自己的渲染拖住了" % stall)
        chk("★★★ 【item 4 主案】全程**没有**弹出断连/无响应遮罩"
            "（线上用户看到的「页面崩溃」就是它）", not offs,
            "弹出过：%s" % sorted(offs))

        # =====================================================================
        # 第二幕：**思维链**（千问那一幕）—— 用户报的就是它
        # =====================================================================
        #
        # 上面那一幕量的是正文区。但用户配的是 qwen3.8-max，一个推理模型：
        # reasoning_content 在 R/llm.R 里是**无条件解析**的，于是"模型先想
        # 很久、再开口"——这段时间里页面上在长的是**思考区**，而思考区走的是
        # 另一条渲染路径（sendCustomMessage → app.js 往 #chat-think_pre 里
        # appendChild），跟正文那条 renderUI 完全不搭界。
        # 只量正文就下结论 = 没测用户真走的那条路。
        say("\n" + "=" * 72)
        say("== 第二幕：思维链（qwen 那种「先想很久」的形状）==")
        parts = reason_chunks()
        total = sum(len(p) for p in parts)
        say("  思维链 %d 字符，切成 %d 段；每段一个 SSE 事件、间隔 %.2fs "
            "≈ 全程 %.0f 秒" % (total, len(parts), DELAY, len(parts) * DELAY))

        chk("★★ 前提：第一幕的请求数已经记下来了（下面那个「收到了」要按"
            "增量算，不然第二幕能拿第一幕的请求冒充）", fx.req_n() > 0)
        req0 = fx.req_n()
        page.evaluate("() => { window.__dsThink = {n: 0, seen: {}}; }")
        fx.set_queue(C.sse_multi(parts, content="以上就是我的判断过程，结论如下。\n"))
        fx.slow(DELAY)

        page.evaluate(_WATCH)
        fire(page, "再想一遍")

        r2 = sample_stream(page, _JS_THINK)
        fx.no_slow()
        fin2 = page.evaluate(_STOP)

        seen2, worst2 = r2["seen"], r2["worst"]
        recs2, offs2 = r2["recs"], r2["offs"]
        if r2["err"]:
            say("  ⚠️ evaluate 抛了（主线程被占住的信号）：%s" % r2["err"])
        say("  跑了 %.1f 秒；思考区最长见到 **%d 字符**（服务端一共发了 %d）"
            % (r2["dur"], seen2, total))
        say("  脑区节点身份：%s" % sorted({x[3]["gen"] for x in recs2 if x[3]}))
        say("  longtask 次数=%s 累计阻塞=%sms 最长一次=%sms | rAF 最长帧=%sms "
            "| 堆峰值 %sMB | DOM 峰值 %s"
            % (fin2["n_task"], fin2["task_total"], fin2["task_max"],
               fin2["frame_max"], fin2["heap_max"], fin2["dom_max"]))
        say("  时间线 (t, 思考区字符数, 往返秒, 正文开始了没有):")
        for i, s in enumerate(recs2):
            if i % 10 == 0 or s[2] > 0.5:
                say("    %6.2fs  思考区=%6d  往返=%.3fs  正文=%s"
                    % (s[0], s[1], s[2], (s[3] or {}).get("content")))

        ngens = max([x[3]["ngens"] for x in recs2 if x[3]] or [0])
        # 撤掉采集器，免得下一幕的 longtask 混进这一幕的数
        inc2, stall2 = stall_of(recs2)
        say("  服务端：思考区字数增长 %d 次；两次增长之间最长隔了 %.1f 秒"
            % (len(inc2), stall2))
        say("  断连遮罩出现过：%s" % (sorted(offs2) or "没有"))

        chk("★★ 前提：这一段真的打到了假服务端（按**增量**算，不是看总数）",
            fx.req_n() > req0, "req_n 从 %d 变成了 %d" % (req0, fx.req_n()))
        # ★★★ 地基：思考区没在长的话，下面每一条"没卡"量的都是"什么都没发生"
        #     —— 第一幕第一版就是这么绿着撒谎的，这里不再犯第二次。
        chk("★★★ 前提：思考区**真的在流**（见过 > 1000 字符）", seen2 > 1000,
            "思考区最多只见到 %d 字符" % seen2)
        # 漏字/被重置的判据：光标式追加（st$reason_sent）在正常情况下一字不差。
        chk("★★ 思考区把服务端发出来的**字基本都贴上了**（≥90%，"
            "漏字或被 reset 会在这里露出来）",
            seen2 >= total * 0.9,
            "见到 %d / 服务端发了 %d" % (seen2, total))
        # ★★★ 这一条是"闪屏"的根：V15.4 item 3 修的就是这个节点每 200ms
        #      被拆掉重建（CSS 动画跟着元素从 0 度重来）。重建还会把已经贴上去
        #      的字连同节点一起丢掉。一轮下来只该有**一个**身份号。
        chk("★★★ 思考区节点一轮里**只画过一次**（ngens == 1）—— "
            "被重画就是用户看到的「闪」，字也会跟着丢",
            ngens == 1, "见过 %d 个不同的 #chat-think_pre 节点" % ngens)
        chk("★★★ 【item 4·千问那一幕】思维链流式期间主线程没有被长时间独占"
            "（最长一次 longtask < 2000ms）", (fin2["task_max"] or 0) < 2000,
            "最长一次独占 %sms" % fin2["task_max"])
        chk("★★★ 【item 4·千问那一幕】思维链全程累计阻塞 < 10 秒",
            (fin2["task_total"] or 0) < 10000,
            "累计阻塞 %sms（rAF 最长帧 %sms，卡顿 %s 次）"
            % (fin2["task_total"], fin2["frame_max"], fin2["n_stall"]))
        chk("★★ 思维链期间 evaluate 往返最慢 < 3 秒（界面点得动）",
            worst2 < 3.0, "最慢一次 %.2f 秒" % worst2)
        chk("★★★ 【item 4·千问那一幕】R worker 没有长时间说不出话"
            "（思考区字数两次增长之间最长 < 5 秒）", stall2 < 5.0,
            "最长 %.1f 秒没动静" % stall2)
        chk("★★★ 【item 4·千问那一幕】全程没有弹出断连/无响应遮罩",
            not offs2, "弹出过：%s" % sorted(offs2))
        chk("★★ 页面没有崩（第二幕跑完渲染进程还活着）", not crashed[0],
            "page.on('crash') 触发了")

        # 落库 + 界面上看得见：思维链不是只活在流式那一格里的。
        page.wait_for_timeout(1500)
        row = None
        try:
            con = sqlite3.connect(db)
            con.execute("PRAGMA busy_timeout = 5000")
            row = con.execute(
                "SELECT length(COALESCE(reasoning,'')) FROM messages "
                "WHERE role='assistant' ORDER BY id DESC LIMIT 1").fetchone()
            con.close()
        except Exception as e:
            say("  ⚠️ 查库失败：%s" % e)
        chk("★★ 思维链**落库了**（assistant 那行的 reasoning 长度 ≈ 发出去的）",
            row is not None and row[0] >= total * 0.9,
            "库里 reasoning 长度 = %s，服务端发了 %d" % (row and row[0], total))
        rbody = page.evaluate(
            "() => { const els = document.querySelectorAll('#chat-history "
            ".dsapp-reason-body'); const n = els.length;"
            " return n ? els[n-1].textContent.length : -1; }")
        chk("★★ 用户**看得见**：历史那条消息里带着思考区（.dsapp-reason-body）",
            rbody is not None and rbody >= total * 0.9,
            "历史里最后一个 .dsapp-reason-body 有 %s 字符" % rbody)
        say("  （历史里的思考区是**折叠**的，用 textContent 量；innerText 对"
            "折叠内容返回空 —— 拿 innerText 量会红得莫名其妙）")

        browser.close()

    say("\n== 通过 %d / 失败 %d ==" % (N_OK[0], N_BAD[0]))
    log.close()
    fx.stop()
    sys.exit(0 if N_BAD[0] == 0 else 1)


if __name__ == "__main__":
    main()
