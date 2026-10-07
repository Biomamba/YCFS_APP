# -*- coding: utf-8 -*-
"""tests/ui_v156b —— V15.6 **界面层**那几条的浏览器验收

probe_v156.py 管的是围栏那件事（item 11）。这一份管剩下那些"改的全在界面
上"的条目 —— 它们的共同点是**自检看不见**：

| item | 用户原话 | 自检能验的 | 只能在这儿验的 |
|---|---|---|---|
| 2 | 活人感的提示词刷新的太快了，有新结果出现的时候间隔着刷新即可 | 两道闸那两行代码在 | 静默期里那句话**真的没换** |
| 3 | 正在返回信息的小框现在也会频繁的闪 | 宽限期那行代码在 | 一整轮里 `is-on` **真的没被摘掉过** |
| 7 | 单次上下文进度条前面应该再加一个单次 token 使用进度条 | 节点/类名在 | 它在**左边**、宽度和它自己那个数**对得上** |
| 9/15 | 预览区的图片又裂了，然后等一会又出现了 | 版本号/重试代码在 | 图**真的加载成功**、坏图**真的重试到放弃** |
| 12 | 返回问题的时候只有继续和停止按钮，应该有键入让用户回答 | 三个 id 在 | 敲下去**真的进了库**、草稿**真的没被冲掉** |

── 铁律（都是本仓栽过的）───────────────────────────────────────────────
  · 新账号第一次进对话页有个首选项弹窗把**所有** click 吃掉 → `ensure_no_modal()`。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到条件成立。
  · 一次运行写一个日志（两次写同一个 = 交错成垃圾）；切页必须显式切，
    否则量到的是隐藏页里的 0×0 矩形。
  · **只查界面 = 分不清"没写进去"和"没画出来"** → item 12 那条回**库**里确认。
  · 一条出网请求都不许打到真厂商 → 每轮结束断言 `fx.req_n()` 涨了。
"""
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
# ⚠️ ensure_no_modal 住在 probe_v156.py 里（它讲的是"首选项弹窗挡点击"那件
#    事，和 _common 里那些通用件不是一类）。**不要在这里抄一份** —— 抄一份
#    就会出现两个版本，改了那边这边不知道（本仓在"两个解析器各写一遍"上
#    栽过一次）。
import probe_v156 as P  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402


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


def relogin(page, email):
    """换一份**全新的 Shiny 会话**。

    ⚠️⚠️ 必须 reload，不能只 `goto(page, "chat")`。`seed_llm()` 是把 base_url
      和 Key 写进**库**里，而当前这个会话早就把配置读进内存了 —— 不 reload
      的话界面上一切正常，一发消息却回一句「请先到『模型服务』填写 API Key」
      （实测：D/E/F 三节全红，报的全都指向"读条没画出来""回答框没出来"，
      和真正的原因隔着十万八千里）。
    """
    P.relogin(page, email)
    C.goto(page, "chat")
    page.wait_for_timeout(1200)


def ensure_no_modal(page, timeout=10):
    return P.ensure_no_modal(page, timeout)


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def busy(page):
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(page, timeout=150):
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


def send(page, text, timeout=150):
    ensure_no_modal(page, timeout=3)
    page.fill("#chat-input", text)
    page.click("#chat-send")
    ok = wait_idle(page, timeout)
    if not ok:
        page.screenshot(path=C.OUT + "/b02_send_timeout.png", full_page=True)
    return ok


def user_msgs(db, uid, since_id=0):
    """这个账号**所有会话**里 id > since_id 的用户消息正文（新→旧）。"""
    return sql(db,
               "SELECT m.content FROM messages m JOIN sessions s"
               " ON s.id = m.session_id WHERE s.user_id = ? AND m.role = 'user'"
               " AND m.id > ? ORDER BY m.id DESC", (uid, since_id))


def max_msg_id(db, uid):
    r = sql(db, "SELECT COALESCE(MAX(m.id), 0) FROM messages m"
                " JOIN sessions s ON s.id = m.session_id"
                " WHERE s.user_id = ?", (uid,))
    return r[0][0] if r else 0


# =============================================================================
# item 7：两条读条
# =============================================================================
def bars_state(page):
    """把 `#chat-hint` 里那两条读条读回来。

    ⚠️ 宽度从 **style 属性**里读，不是量矩形：那条 `i` 的宽度是相对父节点
      的百分比，量出来是 px，还要除以父宽才是它写的那个数 —— 多一步换算
      就多一个出错的地方。判据本来就是"服务端写进去的数对不对"。
    ⚠️ 几何（左右顺序）必须量矩形，那个没有别的办法。量之前确认两边都
      **看得见** —— 隐藏元素的矩形是全 0（本仓栽过）。
    """
    return page.evaluate(r"""() => {
      var h = document.querySelector('#chat-hint');
      var tok = h ? h.querySelector('.dsapp-tokbar') : null;
      var ctx = h ? h.querySelector('.dsapp-ctxbar') : null;
      function w(el) {
        if (!el) return null;
        var i = el.querySelector('i');
        if (!i) return null;
        var m = /width\s*:\s*([0-9.]+)\s*%/.exec(i.getAttribute('style') || '');
        return m ? parseFloat(m[1]) : null;
      }
      function box(el) {
        if (!el) return null;
        var r = el.getBoundingClientRect();
        return {x: Math.round(r.left), y: Math.round(r.top),
                w: Math.round(r.width), h: Math.round(r.height)};
      }
      return {
        n_hint: document.querySelectorAll('#chat-hint').length,
        n_tok: document.querySelectorAll('.dsapp-tokbar').length,
        n_ctx: document.querySelectorAll('.dsapp-ctxbar').length,
        text: h ? (h.innerText || '') : null,
        tok_w: w(tok), ctx_w: w(ctx),
        tok_box: box(tok), ctx_box: box(ctx)
      };
    }""")


# ⚠️ 分母**不一定是纯数字**：`dsapp_fmt_tokens_short()` 会把 1048576 写成
#    `1M`（区间读条上显示的就是这个）。只认 [0-9.,] 的话，正则匹配不上，
#    D1 会红成"两条读条都没画出来"，而屏幕上那两条明明在（实测踩过）。
#    括号前面那个空格也时有时无（跨 span 的 innerText），一律 `\s*`。
_NUM_PAT = r"([0-9][0-9.,]*\s*[KMG]?)"
_TOK_RE = re.compile(r"单次\s*≈\s*" + _NUM_PAT + r"\s*/\s*" + _NUM_PAT
                     + r"\s*（\s*(\d+)\s*%）")
_CTX_RE = re.compile(r"上下文\s*≈\s*" + _NUM_PAT + r"\s*/\s*" + _NUM_PAT
                     + r"\s*（\s*(\d+)\s*%）")


def _NUM(s):
    """`1M` / `74,469` / `8,933` → 数字。

    ⚠️ 拿不到单位就**抛**：这一节比的是"分子 ≥ 另一半""两条分母一样"，
      把 `1M` 悄悄当成 1 的话，D8 会以"分母不一样"的形式红，指向完全错的
      地方（真因是这里换算错了）。
    """
    s = (s or "").strip().replace(",", "")
    m = re.match(r"^([0-9.]+)\s*([KMG]?)$", s)
    if not m:
        raise ValueError("认不出这个数：%r" % s)
    return float(m.group(1)) * {"": 1, "K": 1000, "M": 1000000,
                                "G": 1000000000}[m.group(2)]


def wait_bars(page, timeout=45):
    end = time.time() + timeout
    st = None
    while time.time() < end:
        st = bars_state(page)
        if (st["n_hint"] == 1 and st["text"]
                and _TOK_RE.search(st["text"]) and _CTX_RE.search(st["text"])):
            return st
        page.wait_for_timeout(300)
    return st


def sec_d_bars(page, uid, db, fx):
    print("\n== D. item 7：单次 token 读条（排在上下文那条**前面**）==",
          flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    fx.set_queue(C.sse("收到，先算个上下文。"))
    n0 = fx.req_n()
    ok = send(page, "随便问一句，好让读条画出来。")
    chk("★ 前提：这一轮问出去了（假服务端收到了 = 没打到真厂商）",
        ok and fx.req_n() > n0, "wait_idle 超时 / req_n 没涨")

    st = wait_bars(page)
    txt = (st["text"] or "")
    print("    hint: %r" % txt[:200], flush=True)
    print("    条数 tok=%s ctx=%s；宽度 tok=%s%% ctx=%s%%"
          % (st["n_tok"], st["n_ctx"], st["tok_w"], st["ctx_w"]), flush=True)
    print("    位置 tok=%s ctx=%s" % (st["tok_box"], st["ctx_box"]), flush=True)

    m1 = _TOK_RE.search(txt)
    m2 = _CTX_RE.search(txt)
    chk("★★★ D1 两条读条都画出来了", m1 is not None and m2 is not None,
        "hint 文字 %r" % txt[:220])
    if m1 is None or m2 is None:
        return

    chk("★★★ D2 全页只有**一条** `.dsapp-ctxbar`（V15.5 那条探针取的是第一个"
        "匹配，多一条它就会量错元素）", st["n_ctx"] == 1,
        "n_ctx=%s" % st["n_ctx"])

    # ---- 顺序：单次那条在左边、同一行、都看得见 --------------------------
    tb, cb = st["tok_box"], st["ctx_box"]
    chk("★★★ D3 单次读条在上下文读条**左边**（用户原话「前面应该再加一个」）",
        bool(tb and cb) and tb["w"] > 0 and cb["w"] > 0 and tb["x"] < cb["x"],
        "tok=%s ctx=%s" % (tb, cb))
    chk("★★ D4 两条在同一行上（不是被挤到下一行去了）",
        bool(tb and cb) and abs(tb["y"] - cb["y"]) <= 8,
        "tok.y=%s ctx.y=%s" % (tb and tb["y"], cb and cb["y"]))

    # ---- 宽度 = 它自己那个数 ---------------------------------------------
    chk("★★★ D5 单次读条的宽度 = 单次那个百分数（不是抄上下文的）",
        st["tok_w"] is not None
        and abs(st["tok_w"] - float(m1.group(3))) <= 1.0,
        "写的是 %s%%，条宽 %s%%" % (m1.group(3), st["tok_w"]))
    chk("★★★ D6 上下文读条的宽度 = 上下文那个百分数（改完没串台）",
        st["ctx_w"] is not None
        and abs(st["ctx_w"] - float(m2.group(3))) <= 1.0,
        "写的是 %s%%，条宽 %s%%" % (m2.group(3), st["ctx_w"]))

    # ---- 语义：单次 = 上下文 + 回复额度 ----------------------------------
    tok_used, tok_lim = _NUM(m1.group(1)), _NUM(m1.group(2))
    ctx_used = _NUM(m2.group(1))
    print("    单次 %s / %s；上下文 %s" % (tok_used, tok_lim, ctx_used),
          flush=True)
    chk("★★★ D7 单次的分子 ≥ 上下文那一半（它就是「上下文 + 回复额度」）",
        tok_used >= ctx_used, "单次 %s < 上下文 %s" % (tok_used, ctx_used))
    chk("★★★ D8 两条读条共用**同一个分母**（同一个「单次使用上限」）",
        abs(tok_lim - _NUM(m2.group(2))) < 1.0,
        "单次分母 %s vs 上下文分母 %s" % (tok_lim, m2.group(2)))
    chk("★★ D9 单次那条没有超过 100%（超了就是分子里混进了累计值）",
        tok_used <= tok_lim + 1, "%s > %s" % (tok_used, tok_lim))


# =============================================================================
# item 2 / 3：提示词不再按死钟点换、转圈不再闪
# =============================================================================
_WATCH_JS = r"""() => {
  window.__p156 = {t0: Date.now(), samples: [], spin: [], hint: 0,
                   spin_found: 0, box_found: 0};
  var W = window.__p156;
  var spin = document.querySelector('.dsapp-hint-spin');
  W.spin_found = spin ? 1 : 0;
  var hint = document.querySelector('#chat-hint');
  if (spin) {
    new MutationObserver(function (ms) {
      for (var i = 0; i < ms.length; i++)
        W.spin.push({t: Date.now() - W.t0, on: spin.classList.contains('is-on')});
    }).observe(spin, {attributes: true, attributeFilter: ['class']});
  }
  if (hint) {
    /* ⚠️ 数的是 #chat-hint **真的被重画**几次（childList 变动），不是
     *    `shiny:outputinvalidated` —— 后者只要服务端写了 reactiveVal 就算，
     *    哪怕值没变、DOM 一个字节都没动（本仓量过：虚高）。 */
    new MutationObserver(function (ms) { W.hint += ms.length; })
      .observe(hint, {childList: true, subtree: true, characterData: true});
  }
  setInterval(function () {
    var q = document.querySelector('.dsapp-wait-box [data-quips]');
    if (q) W.box_found = 1;
    W.samples.push({
      t: Date.now() - W.t0,
      quip: q ? (q.textContent || '') : null,
      wait: !!document.querySelector('.dsapp-wait-box'),
      spin: spin ? spin.classList.contains('is-on') : null
    });
  }, 250);
  return true;
}"""

_READ_JS = "() => window.__p156"


def sse_with_silence(parts, content, quiet=4):
    """思维链分段吐 → 正文 → **静默**（若干 SSE 注释块）→ 收尾。

    ⚠️ 静默期是这一节的关键：**模型一个字都不吐、但连接还开着**。
      item 2 报的就是这段时长里那句话还在跳（旧写法是纯墙钟 EVEY=3200）。
      SSE 注释块（`: x`）在 R 那边被显式忽略（R/llm.R:195），但假服务端
      按块 sleep（tests/fake_llm.py），所以它就是一个**有连接的空白**。
    """
    import json as _j

    def chunk(o):
        return "data: " + _j.dumps(o) + "\n\n"

    out = ""
    for p in parts:
        out += chunk({"choices": [{"delta": {"reasoning_content": p},
                                   "finish_reason": None}]})
    if content:
        out += chunk({"choices": [{"delta": {"content": content},
                                   "finish_reason": None}]})
    for _ in range(quiet):
        out += ": keepalive\n\n"
    out += chunk({"choices": [{"delta": None, "finish_reason": "stop"}]})
    return out + "data: [DONE]\n\n"


def sec_e_quips(page, uid, db, fx):
    print("\n== E. item 2/3：提示词不再按钟点换、转圈不再闪 ==", flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    # 静默 4 拍 × 3 秒 = 12 秒；EVERY=6500 < 12000，所以旧写法在这 12 秒里
    # 一定会换句（换 3 次以上），而"有新内容才换"的写法一次都不该换。
    # STALE=20000 > 12000，所以静默期也不该被兜底那条触发。
    delay, quiet = 3.0, 4
    fx.slow(delay)
    fx.set_queue(sse_with_silence(
        ["第一段推理。", "第二段推理。", "第三段推理。"],
        "好，结论是 A。", quiet=quiet))
    page.evaluate(_WATCH_JS)
    n0 = fx.req_n()
    ok = send(page, "慢慢想，别急。", timeout=200)
    fx.no_slow()
    chk("★ 前提：这一轮问出去了", ok and fx.req_n() > n0,
        "wait_idle 超时 / req_n 没涨")

    w = page.evaluate(_READ_JS)
    if not w:
        chk("★★★ E0 观测器装上了", False, "window.__p156 不见了")
        return
    samples = w["samples"]
    n_quip = len([s for s in samples if s["quip"]])
    n_wait = len([s for s in samples if s["wait"]])
    print("    采样 %d 条（有提示语 %d 条、在跑 %d 条）；#chat-hint 重画 %d 次"
          % (len(samples), n_quip, n_wait, w["hint"]), flush=True)
    print("    转圈节点找到=%s；class 变动 %d 次"
          % (w["spin_found"], len(w["spin"])), flush=True)

    chk("★★ E0 观测窗口本身有效（转圈节点在、提示语采到过、hint 重画过）",
        w["spin_found"] == 1 and n_quip >= 8 and w["hint"] >= 10,
        "spin_found=%s n_quip=%s hint=%s" % (w["spin_found"], n_quip,
                                             w["hint"]))
    if w["spin_found"] != 1 or n_quip < 8:
        return

    # ---- item 2：静默期里那句话不许换 ------------------------------------
    # 只在**跑着的时候**（.dsapp-wait-box 在）且读到了非空提示语的那些采样点
    # 上算：连续同一句的最长时长。空读数是"节点刚被重画、轮换器还没填字"，
    # 丢掉（不然会数出一堆假变化）。
    runs, cur, start = [], None, None
    for s in samples:
        if not s["wait"] or not s["quip"]:
            continue
        if s["quip"] != cur:
            if cur is not None and start is not None:
                runs.append((cur, s["t"] - start))
            cur, start = s["quip"], s["t"]
        last = s["t"]
    if cur is not None:
        runs.append((cur, last - start))
    n_change = max(0, len(runs) - 1)
    longest = max([d for _q, d in runs], default=0)
    print("    换句 %d 次；同一句最长挂了 %.1f 秒" % (n_change, longest / 1000.0),
          flush=True)
    for q, d in runs:
        print("      · %5.1fs  %r" % (d / 1000.0, q[:28]), flush=True)

    chk("★★★ E1 静默期（模型一个字都没吐）里那句提示语**一次都没换**",
        longest >= 9000,
        "最长只挂了 %.1f 秒（旧写法 EVERY=3200 时不可能超过 ~3.2 秒）"
        % (longest / 1000.0))
    chk("★★★ E2 反过来：整轮里它**换过**（不是冻住了——冻住也能骗过 E1）",
        n_change >= 1, "一次都没换过 = 这条轮换坏了")

    # ---- item 3：转圈的 is-on 不许被摘掉 ---------------------------------
    # 摘掉再挂上 = CSS 动画从 0 度重来 = 用户看到的"闪"。
    # 只在"这一轮跑着"的时间窗里数 —— 轮次结束后关掉是应该的。
    if n_wait:
        t_first = min(s["t"] for s in samples if s["wait"])
        t_last = max(s["t"] for s in samples if s["wait"])
        offs = [r["t"] for r in w["spin"]
                if not r["on"] and t_first <= r["t"] <= t_last]
        # 轮次结束后的那一次关闭是正常的，不算
        print("    跑着的时候 is-on 被摘掉 %d 次（%s）"
              % (len(offs), offs), flush=True)
        chk("★★★ E3 转圈在整轮里**没有闪**（is-on 一次都没被摘掉过）",
            len(offs) == 0, "被摘掉 %d 次：%s" % (len(offs), offs))
        chk("★★ E4 但它是真的转起来了（is-on 挂上过 —— 不是一直没开）",
            any(r["on"] for r in w["spin"]), "class 变动 %s" % w["spin"])
    else:
        chk("★★★ E3 这一轮被观测到在跑（不然 E3 是空过）", False,
            "一个 .dsapp-wait-box 都没采到")

    # ---- item 3 的另一半：小框的**高度**不许跳 ---------------------------
    # ⚠️⚠️ 上面 E3 只盯住了「转圈被摘掉」这一条通道，而**实测它没有鉴别力**：
    #   把 www/app.js 改回 `var spinOn = busySpin;`（去掉宽限期）再跑，E3 照样
    #   绿、`is-on 被摘掉 0 次` 的数字一模一样 —— 因为这一轮里 busy 一直没断过，
    #   宽限期根本没被用到。判据要和**已知会红的样本**对一次，两版给出同一个数
    #   = 这条判据没劲（见 memory「判据没劲」那条）。
    #   用户原话是「正在返回信息的小框现在也会**频繁地闪**」——"小框"才是主语。
    #   真正的通道是另一个：提示词长短不一，长句在窄列里**折成两行**，
    #   `.dsapp-quip` 从 1.25em 变 2.5em，下面那颗转圈跟着上下跳一格，
    #   换一句跳一次。（修法是 app.css 里给它 nowrap + ellipsis。）
    #   所以这一节量的是**几何**：把窗口收窄到长句一定会折行的宽度，盯住
    #   `.dsapp-quip` 和 `.dsapp-wait-box` 的高度 —— 换句期间一个像素都不许动。
    sec_e_wrap(page, uid, db, fx)


_WRAP_JS = r"""() => {
  window.__p156w = {t0: Date.now(), s: []};
  var W = window.__p156w;
  setInterval(function () {
    var q = document.querySelector('.dsapp-wait-box [data-quips]');
    var b = document.querySelector('.dsapp-wait-box');
    if (!q || !b) return;
    var cs = getComputedStyle(q);
    W.s.push({
      t: Date.now() - W.t0,
      vw: window.innerWidth,
      txt: (q.textContent || ''),
      qh: q.getBoundingClientRect().height,
      qw: q.getBoundingClientRect().width,
      bh: b.getBoundingClientRect().height,
      lh: parseFloat(cs.lineHeight) || 0,
      /* 内容比可视区宽多少 —— >0 说明"这一格真的装不下"，那才是
         nowrap 有没有在干活能被看见的地方。 */
      over: q.scrollWidth - q.clientWidth
    });
  }, 250);
  return true;
}"""

# ⚠️⚠️ 为什么要**灌一句超长提示词**，而不是"把窗口收窄"：
#   2026-09-30 实测（/tmp/probe_v156b_k.log 那张表）—— `.dsapp-quip` 的宽度
#   跟窗口**没关系**：视口 1440/900/560/420/320 下量到的都是 126~154 px，
#   也就是**它自己那句话的宽度**（这一格是按内容收缩的，不是撑满的）。
#   于是"把窗口收窄逼它折行"这条路走不通：窗口再窄它也只是跟着缩，
#   永远量不到 overflow > 0，E6/E7 就成了**白送**的绿（两版给同一个数 =
#   判据没劲）。真实提示词里最长的那句（13 个汉字 ≈ 177 px）在这种布局下
#   也永远不会折。
#   所以改成**从内容这一头**压：塞一句 800 px 宽的话进去。它在 420 px 的
#   视口里必然装不下 —— nowrap 在，它就一行（溢出被 ellipsis 吃掉）；
#   nowrap 被删掉，它就折成三行、`.dsapp-quip` 变 3 倍高、下面那颗转圈跟着
#   跳三格。这正是用户说的「小框频繁地闪」，而且**判据有了鉴别力**。
LONG_QUIP = ("正在把你的问题拆成小块逐个核对，"      # 40 个汉字 ≈ 550 px
             "再把每一步的中间结果和文献里的结论对一遍，稍等片刻就好")

_LONG_JS = r"""async (long) => {
  var q = document.querySelector('.dsapp-wait-box [data-quips]');
  var b = document.querySelector('.dsapp-wait-box');
  if (!q || !b) return {err: 'no box'};
  var cs = getComputedStyle(q);
  /* 轮换器每隔 EVERY=6500ms 会把 textContent 换掉，撞上了这次测量就白做。
     写进去之后**核一遍还在不在**，不在就再写一次（最多三次）。 */
  var before = {qh: q.getBoundingClientRect().height,
                bh: b.getBoundingClientRect().height};
  /* 这句话**不折行**时要多宽：canvas 按这一格自己的字体量。
     ⚠️ 别拿 scrollWidth-clientWidth（溢出）当"装不下"的判据 —— 那是反的：
        溢出 > 0 恰恰是 nowrap **在**干活的样子（一行 + ellipsis 裁掉）；
        真折行了溢出反而变成 0。判据必须是"自然宽度 vs 可用宽度"。 */
  var cv = document.createElement('canvas');
  var cx = cv.getContext('2d');
  cx.font = cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize +
            ' ' + cs.fontFamily;
  var nat = cx.measureText(long).width;
  for (var i = 0; i < 3; i++) {
    q.textContent = long;
    await new Promise(function (r) { setTimeout(r, 700); });
    if (q.textContent === long) break;
  }
  return {before: before,
          held: q.textContent === long,
          txt: q.textContent,
          qh: q.getBoundingClientRect().height,
          qw: q.getBoundingClientRect().width,
          bh: b.getBoundingClientRect().height,
          lh: parseFloat(cs.lineHeight) || 0,
          over: q.scrollWidth - q.clientWidth,
          nat: nat,
          ws: cs.whiteSpace,
          avail: b.clientWidth};
}"""


def sec_e_wrap(page, uid, db, fx):
    """item 3：小框（`.dsapp-wait-box`）换句时高度不许跳。

    ⚠️ 这一节的**价值全在 E5 那条前提上**：量到的这一格必须真的装不下那句话，
      否则下面的 E6/E7 是白送的绿。理由和做法见上面 LONG_QUIP 那段注释。
    """
    VIEW_W = 420
    page.set_viewport_size({"width": VIEW_W, "height": 900})

    delay, quiet = 3.0, 5
    fx.slow(delay)
    fx.set_queue(sse_with_silence(
        ["先捋一下。", "再核一遍。", "还得再看看。"],
        "行，就这么办。", quiet=quiet))
    page.evaluate(_WRAP_JS)
    n0 = fx.req_n()
    # ⚠️ 不用 send()：它一等等到整轮结束，那样就没机会在**流式期间**去改
    #    DOM（小框只在生成期间存在，轮次一结束它就没了）。
    ensure_no_modal(page, timeout=3)
    page.fill("#chat-input", "小框再跑一轮。")
    page.click("#chat-send")
    page.wait_for_timeout(2600)                  # 等小框画出来 + 采几句真的
    inj = page.evaluate(_LONG_JS, LONG_QUIP)
    ok = wait_idle(page, 200)
    fx.no_slow()
    page.wait_for_timeout(300)

    s = page.evaluate("() => window.__p156w.s") or []
    page.set_viewport_size({"width": 1440, "height": 900})
    if not ok or fx.req_n() <= n0:
        chk("★ 前提：小框这一轮问出去了", False, "wait_idle 超时 / 没打到假服务端")
        return
    if not inj or inj.get("err"):
        chk("★★★ E5 塞进超长提示词的那一步做成了", False, "inj=%s" % inj)
        return
    print("    真实提示词（视口 %d）：采 %d 条；宽 %.0f~%.0f px、高 %.1f~%.1f、"
          "框高 %.1f~%.1f"
          % (VIEW_W, len(s),
             min([x["qw"] for x in s], default=0),
             max([x["qw"] for x in s], default=0),
             min([x["qh"] for x in s], default=0),
             max([x["qh"] for x in s], default=0),
             min([x["bh"] for x in s], default=0),
             max([x["bh"] for x in s], default=0)), flush=True)
    print("    塞进去 %d 个字：这一格可视宽 %.0f px、内容宽 %.0f px（溢出 %d）"
          % (len(inj["txt"]), inj["qw"], inj["qw"] + inj["over"], inj["over"]),
          flush=True)
    print("    灌进去之后：.dsapp-quip 高 %.1f px（行高 %.1f = %.2f 行）；"
          ".dsapp-wait-box 高 %.1f → %.1f"
          % (inj["qh"], inj["lh"], inj["qh"] / (inj["lh"] or 1),
             inj["before"]["bh"], inj["bh"]), flush=True)

    # ★ 前提：这句话**真的装不下**。装得下的话下面两条是白送的 —— 不报绿。
    if not (inj["held"] and inj["nat"] > inj["avail"]):
        chk("★★★ E5 折行观测窗口**没搭起来** —— E6/E7 记作未验证，不许当绿", False,
            "held=%s 自然宽 %.0f px vs 可用宽 %.0f px（装得下就怎么都不会折）"
            % (inj["held"], inj["nat"], inj["avail"]))
        return
    print("    → 这句话不折行要 %.0f px，而这一格只有 %.0f px：**装不下**，"
          "nowrap 在不在看得出来" % (inj["nat"], inj["avail"]), flush=True)

    chk("★★★ E6 灌进一句装不下的提示词，`.dsapp-quip` 仍然只有**一行**"
        "（折行 = 转圈跟着上下跳 = 用户说的『小框频繁地闪』）",
        inj["qh"] <= inj["lh"] * 1.5,
        "高 %.1f px = %.2f 行（行高 %.1f）—— 折行了"
        % (inj["qh"], inj["qh"] / (inj["lh"] or 1), inj["lh"]))
    # ⚠️ 基准取"真实提示词里最矮的那次框高"（= 一行时的框高），**不是**"灌之前
    #    那一句的框高"：坏版本里那一句本身可能已经在折行了，拿它当基准会碰巧绿。
    bh_1line = min([x["bh"] for x in s], default=inj["before"]["bh"])
    chk("★★★ E7 灌进这句话之后小框总高还是**一行时那么高**",
        inj["bh"] <= bh_1line + 1.0,
        "框高 %.1f px，而一行时是 %.1f px（差 %.1f）"
        % (inj["bh"], bh_1line, inj["bh"] - bh_1line))
    # ★ 这一条用的是**平台自己的提示词**（不是灌进去的那句）：坏版本里框高在
    #   69~103 之间来回摆，就是用户说的"小框频繁地闪"。
    bh_rng = (max([x["bh"] for x in s], default=0) - bh_1line)
    chk("★★★ E8 真实提示词轮换期间，小框高度**一个像素都不动**"
        "（坏版本实测 69↔103，一句一跳）",
        bh_rng <= 1.0, "框高在 %.1f~%.1f 之间摆（差 %.1f px）"
        % (bh_1line, bh_1line + bh_rng, bh_rng))


# =============================================================================
# item 12：回答框（键入回答，不用只点「继续」）
# =============================================================================
_ASK_JS = r"""() => {
  var b = document.querySelector('#chat-ask_box');
  var a = document.querySelector('#chat-ask_reply');
  var s = document.querySelector('#chat-ask_send');
  return {
    exists: !!b, id: b ? b.id : null,
    display: b ? (b.offsetParent === null ? 'none' : 'shown') : null,
    marked: b ? (b.__dsapp_probe === 1) : null,
    value: a ? a.value : null,
    enter: a ? a.getAttribute('data-dsapp-enter') : null,
    send: !!s
  };
}"""


def sec_f_ask(page, uid, db, fx):
    print("\n== F. item 12：模型问一句，用户能敲回去 ==", flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    st0 = page.evaluate(_ASK_JS)
    print("    初始：%s" % st0, flush=True)
    chk("★★★ F1 回答框在 DOM 里、而且是**收着**的（服务端发第一条消息之前）",
        st0["exists"] and st0["display"] == "none",
        "exists=%s display=%s" % (st0["exists"], st0["display"]))
    if not st0["exists"]:
        return
    # 给节点打个记号：真被 renderUI 重画过的话，记号会跟着节点一起消失
    page.evaluate("() => { document.querySelector('#chat-ask_box')"
                  ".__dsapp_probe = 1; }")

    # ---- 让模型问一句 ------------------------------------------------------
    # ⚠️ 判据是 dsapp_asks_confirmation()：结尾是问号（或那几句"把话头递过来"
    #    的说法）。这一句两个都占。
    fx.set_queue(C.sse("要不要继续？"),
                 C.sse("那我再问一次：要不要继续？"),
                 C.sse("好，收到，接着干。"))
    n0 = fx.req_n()
    ok = send(page, "先看一眼数据。")
    chk("★ 前提：这一轮问出去了", ok and fx.req_n() > n0, "wait_idle 超时")
    page.wait_for_timeout(1500)

    st1 = page.evaluate(_ASK_JS)
    print("    问完之后：%s" % st1, flush=True)
    chk("★★★ F2 模型以问句收尾时，回答框自己出来了",
        st1["display"] == "shown", "display=%s" % st1["display"])
    if st1["display"] != "shown":
        return
    chk("★★★ F3 它是**同一个节点**（不是被重画出来的）—— 记号还在",
        st1["marked"] is True, "marked=%s" % st1["marked"])
    chk("★★ 回车出口挂上了（data-dsapp-enter 指到那个 input 名）",
        bool(st1["enter"]) and st1["enter"].endswith("ask_reply_key"),
        "data-dsapp-enter=%r" % st1["enter"])

    # ---- 草稿要活过一整轮重画 ---------------------------------------------
    draft = "草稿别丢-%d" % (int(time.time()) % 100000)
    page.fill("#chat-ask_reply", draft)
    n1 = fx.req_n()
    ok2 = send(page, "再确认一次。")          # 这一轮里 hint 会重画几十次
    chk("★ 前提：第二轮也问出去了", ok2 and fx.req_n() > n1, "wait_idle 超时")
    page.wait_for_timeout(1500)
    st2 = page.evaluate(_ASK_JS)
    print("    第二轮之后：%s" % st2, flush=True)

    # ⚠️ 这两条是**同一个坑的两半**：节点被重画 → 记号没了 **且** 用户敲的
    #    半个句子没了。分开报，是为了失败时能一眼看出是哪一半。
    chk("★★★ F4 一整轮重画之后记号还在（回答框不是 renderUI 画的）",
        st2["marked"] is True, "marked=%s（节点被换掉了）" % st2["marked"])
    chk("★★★ F5 用户敲了一半的草稿没被冲掉",
        st2["value"] == draft, "期望 %r，实际 %r" % (draft, st2["value"]))
    chk("★★ F6 第二个问句来了，框又亮着", st2["display"] == "shown",
        "display=%s" % st2["display"])

    # ---- 敲回车 = 真的发出去（回库确认）----------------------------------
    before = max_msg_id(db, uid)
    n2 = fx.req_n()
    page.focus("#chat-ask_reply")
    page.keyboard.press("Enter")
    ok3 = wait_idle(page, 150)
    page.wait_for_timeout(1200)
    after = max_msg_id(db, uid)
    rows = sql(db, "SELECT m.content FROM messages m JOIN sessions s"
                   " ON s.id = m.session_id WHERE s.user_id = ? AND m.id > ?"
                   " AND m.role = 'user' ORDER BY m.id DESC", (uid, before))
    got = [r[0] for r in rows]
    print("    回车之后库里新增用户消息：%r" % got[:3], flush=True)
    chk("★★★ F7 回车真的把那句话发出去了（**库里**有新行，不是只看界面）",
        any(draft in (g or "") for g in got),
        "新增 %r；after=%s" % (got[:3], after))
    chk("★ 前提：这一轮也真的问出去了", ok3 and fx.req_n() > n2,
        "wait_idle 超时 / req_n 没涨")

    st3 = page.evaluate(_ASK_JS)
    print("    发完之后：%s" % st3, flush=True)
    chk("★★★ F8 发出去之后框收起来了（下一轮真问的时候还会自己出来）",
        st3["display"] == "none", "display=%s" % st3["display"])
    chk("★★★ F9 发出去之后输入框清空了（没清 = 用户得自己删，"
        "被闸门挡下来时会白丢一句）", st3["value"] == "",
        "value=%r" % st3["value"])


# =============================================================================
# item 9 / 15：预览图
# =============================================================================
def make_png(path, w=420, h=300):
    """造一张真 PNG（走 R 的 png() 设备，不手搓字节）。

    ⚠️ 必须是**合法**图片：这一节要断言的是"它真的加载出来了"
      （naturalWidth > 0），一个 0 字节文件只会让断言以另一种方式红。
    ⚠️ 尺寸不能太小：`plot()` 在 80×60 上直接报 `figure margins too large`
      （2026-09-30 实测），那个错误看着像"R 画不了图"，其实是画布塞不下边距。
    """
    import subprocess
    code = ('png(%s, width=%d, height=%d); par(mar=c(4,4,2,1));'
            ' plot(1:3, main="probe"); dev.off()'
            % (repr(path).replace("'", '"'), w, h))
    r = subprocess.run(["Rscript", "-e", code], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    if r.returncode != 0 or not os.path.exists(path):
        sys.exit("造不出测试用 PNG：%s\n%s"
                 % (path, r.stdout.decode("utf-8", "replace")[:400]))
    with open(path, "rb") as fh:
        head = fh.read(8)
    if head != b"\x89PNG\r\n\x1a\n":
        sys.exit("造出来的不是 PNG（头 8 字节 %r）" % head)
    return os.path.getsize(path)


def preview_img_state(page):
    return page.evaluate(r"""() => {
      var img = document.querySelector('#files-preview img.dsapp-img')
             || document.querySelector('img.dsapp-img');
      if (!img) return {found: false};
      var spin = img.nextSibling;
      var has_spin = !!(spin && spin.nodeType === 1 && spin.classList &&
                        spin.classList.contains('dsapp-img-spin'));
      return {found: true,
              src: img.getAttribute('src') || '',
              cls: img.getAttribute('class') || '',
              alt: img.getAttribute('alt') || '',
              state: img.dataset.dsappImgState || '',
              nw: img.naturalWidth || 0,
              complete: !!img.complete,
              is_loading: img.classList.contains('is-loading'),
              is_broken: img.classList.contains('is-broken'),
              has_spin: has_spin};
    }""")


def sec_g_preview(page, uid, db, fx):
    print("\n== G. item 9/15：预览图（版本号 + 转圈 + 自愈重试）==", flush=True)
    fdir = os.path.join(C.DATA_ROOT, "files", "u%d" % uid)
    os.makedirs(fdir, exist_ok=True)
    png = os.path.join(fdir, "probe_fig.png")
    size = make_png(png)
    print("    造了一张真 PNG：%s（%d 字节）" % (png, size), flush=True)

    C.goto(page, "files")
    page.wait_for_timeout(1500)
    ensure_no_modal(page, timeout=3)
    # 让文件列表重读一遍（那张图是刚写进磁盘的）。
    # ⚠️ 那颗「刷新」按钮**没有 id** —— 它是个 onclick，干的就是下面这一句
    #    （R/mod_files.R:120-129）。写成 `page.click("#files-refresh_tbl")`
    #    会一直等到超时，然后打一行警告说"没点上"，而真正的意思是"这个
    #    选择器根本不存在"。
    page.evaluate("() => Shiny.setInputValue('files-refresh_tbl',"
                  " Math.random(), {priority: 'event'})")
    page.wait_for_timeout(2500)

    # 选中那一行（DT 的选中态就是服务端 input$tbl_rows_selected）
    page.evaluate("() => Shiny.setInputValue('files-tbl_rows_selected', [1],"
                  " {priority: 'event'})")
    end = time.time() + 25
    st = {"found": False}
    while time.time() < end:
        st = preview_img_state(page)
        if st.get("found"):
            break
        page.wait_for_timeout(400)

    print("    预览图：%s" % st, flush=True)
    chk("★★★ G1 文件页的预览图挂上了 `dsapp-img`（JS 就是按它找图的）",
        st.get("found") and "dsapp-img" in st.get("cls", ""),
        "cls=%r" % st.get("cls"))
    if not st.get("found"):
        page.screenshot(path=C.OUT + "/b03_no_preview_img.png", full_page=True)
        return
    chk("★★ G2 有 alt（图裂的时候至少知道裂的是哪一张）", bool(st.get("alt")),
        "alt=%r" % st.get("alt"))
    # ⚠️ 参数分隔符是 `?` 还是 `&` 得看前面有没有别的参数（Shiny 自己会带
    #    `nonce=`），所以认 `[?&]v=<数字>`；钉死 `?v=` 的话，这里会红成
    #    "没带版本号"，而屏幕上那个数字明明在（实测踩过）。
    m_v = re.search(r"[?&]v=(\d+)", st.get("src", ""))
    chk("★★★ G3 地址带版本号 `v=<mtime>`（不带 = 文件被覆盖写之后浏览器"
        "永远给你上一版）", m_v is not None,
        "src=%r" % st.get("src", "")[:200])
    if m_v:
        # mtime 是秒级 epoch：拿它和"我们刚写完这个文件"对一下，能认出来
        # 这个数**就是**那个时间戳（不是某个随机 nonce 被当成版本号）。
        age = time.time() - int(m_v.group(1))
        chk("★★ G3b 版本号就是那个文件的 mtime（不是随便一个数）",
            -5 <= age <= 600, "v=%s，距今 %.0f 秒" % (m_v.group(1), age))

    end = time.time() + 20
    while time.time() < end:
        st = preview_img_state(page)
        if st.get("state") in ("ok", "broken"):
            break
        page.wait_for_timeout(300)
    print("    加载结果：state=%s naturalWidth=%s" % (st.get("state"),
                                                    st.get("nw")), flush=True)
    chk("★★★ G4 图**真的加载出来了**（naturalWidth > 0，不是一张碎图）",
        st.get("state") == "ok" and st.get("nw", 0) > 0,
        "state=%s nw=%s" % (st.get("state"), st.get("nw")))
    chk("★★★ G5 加载完之后转圈被收掉了（一直挂着 = 用户以为还在加载）",
        not st.get("has_spin") and not st.get("is_loading"),
        "has_spin=%s is_loading=%s" % (st.get("has_spin"),
                                       st.get("is_loading")))

    # ---- 反面：坏图要自己重试、三次之后说人话 -----------------------------
    # 往 .dsapp-preview-md（markdown 正文，报告插图走的就是它）里塞一张
    # 一定加载不出来的图，看前端那套自愈有没有真的动起来。
    page.evaluate(r"""() => {
      var d = document.createElement('div');
      d.className = 'dsapp-preview-md';
      d.id = 'probe_broken_wrap';
      var i = document.createElement('img');
      i.src = '/definitely-not-here-156.png';
      i.id = 'probe_broken_img';
      d.appendChild(i);
      document.body.appendChild(d);
      window.__p156_broken = {reqs: [], t0: Date.now()};
      new MutationObserver(function (ms) {
        for (var k = 0; k < ms.length; k++)
          window.__p156_broken.reqs.push(
            {t: Date.now() - window.__p156_broken.t0,
             src: i.getAttribute('src')});
      }).observe(i, {attributes: true, attributeFilter: ['src']});
    }""")
    page.wait_for_timeout(1200)
    # ⚠️ 判据要挑**只有"被认出来"才会发生**的那一件事：转圈节点是 app.js 的
    #    `mark()` 插进去的。写成 `dataset.dsappImgRetry != ''` 是假的 ——
    #    JS 那边 `undefined || '0'` 永远给 '0'，一个从没被扫到的图也过。
    st_b0 = page.evaluate(r"""() => {
      var i = document.querySelector('#probe_broken_img');
      var s = i.nextSibling;
      return {state: i.dataset.dsappImgState || '',
              spin: !!(s && s.nodeType === 1 && s.classList &&
                       s.classList.contains('dsapp-img-spin'))};
    }""")
    end = time.time() + 30
    while time.time() < end:
        got = page.evaluate(
            "() => document.querySelector('#probe_broken_img')"
            ".classList.contains('is-broken')")
        if got:
            break
        page.wait_for_timeout(500)
    bs = page.evaluate(r"""() => {
      var i = document.querySelector('#probe_broken_img');
      var s = i.nextSibling;
      return {broken: i.classList.contains('is-broken'),
              loading: i.classList.contains('is-loading'),
              retry: i.dataset.dsappImgRetry || '0',
              state: i.dataset.dsappImgState || '',
              has_spin: !!(s && s.nodeType === 1 && s.classList &&
                           s.classList.contains('dsapp-img-spin')),
              srcs: window.__p156_broken.reqs.map(function (r) { return r.src; })};
    }""")
    print("    坏图：%s" % {k: v for k, v in bs.items() if k != "srcs"},
          flush=True)
    print("    src 变过 %d 次：%s" % (len(bs["srcs"]), bs["srcs"][:5]),
          flush=True)
    # ⚠️ 这一条量的正是 item 15 那句「如果是因为未加载，可以在加载的时候转圈」：
    #    markdown 预览区（报告插图走的就是它）里的图，加载期间必须有转圈。
    #    漏了 .dsapp-preview-md 这个容器的话，这张图**没人管**：不转圈、不重试。
    chk("★★★ G6 markdown 预览区（报告插图那条路）里的图一插进来就被盯上了"
        "（状态是 loading 且转了圈）",
        st_b0["state"] == "loading" and st_b0["spin"],
        "state=%r spin=%s（漏了 .dsapp-preview-md 就会是这个样子）"
        % (st_b0["state"], st_b0["spin"]))
    chk("★★★ G7 坏图自己重试过，而且每次带 `_r=`（不带 = 重试拿的还是同一份"
        "缓存，等于没重试）",
        len([s for s in bs["srcs"] if "_r=" in (s or "")]) >= 2,
        "src 变过 %d 次：%s" % (len(bs["srcs"]), bs["srcs"][:4]))
    chk("★★★ G8 重试到头（3 次）之后收工，画成破图而不是无限转",
        bs["broken"] and not bs["loading"] and not bs["has_spin"],
        "broken=%s loading=%s has_spin=%s" % (bs["broken"], bs["loading"],
                                              bs["has_spin"]))
    page.evaluate("() => { var d = document.getElementById('probe_broken_wrap');"
                  " if (d) d.parentNode.removeChild(d); }")


def restart_instance():
    """把测试实例整个重启一遍，返回一行说明。

    ⚠️ 为什么探针要自己会重启实例：**跑完一轮之后，实例对新会话会变哑**。
      现象固定：`wait_awake` 等 150 秒 `.dsapp-auth` 一直不出现（页面全空），
      而 `curl /` 秒回 200、R 进程 CPU 也在动 —— 不是崩了，是首屏那次 flush
      排不上队。上一轮 `browser.close()` 是**硬关**的，Shiny 那边的会话没走到
      `onSessionEnded`，它名下的定时器（心跳那条 invalidateLater）继续在单线程
      worker 里跳；连着几轮下来，新会话的首屏就被挤在后面。
      2026-09-30 实测：probe_v156b 第 2 轮起，**连着重试 3 次全空**（旧的
      "重来一次就好"不够用了），重启实例之后一次就进。
    ⚠️ 复用 make_instance.sh 而**不是**自己 kill + runApp：那份脚本负责
      「别让实例连上生产库」（.Renviron 那个坑）和端口的旧 pid 清理。
    """
    import subprocess
    app = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v156/app")
    root = os.path.dirname(app)
    port = os.environ.get("DSAPP_TEST_PORT", "8926")
    try:
        r = subprocess.run(["bash", os.path.join(C.REPO, "tests/ui_v7/make_instance.sh"),
                            port, root],
                           capture_output=True, text=True, timeout=420)
        msg = (r.stdout or "").strip().splitlines()[-1:] or ["(无输出)"]
        return "重启实例：%s" % msg[0][:120]
    except Exception as e:                      # noqa: BLE001
        return "重启实例失败：%s" % str(e)[:160]


def _new_ctx(browser):
    """一个干净的浏览器 context（**cookie 也是干净的** —— 那是重点）。"""
    return browser.new_context(viewport={"width": 1440, "height": 900})


def enter_with_retry(browser):
    """注册进主界面，失败就重来（第 2 次还不行就把实例重启一遍）。

    ⚠️⚠️ 必须接 **BaseException**，不能只接 Exception：注册那一步走的是
      `_common.enter_app()`，它失败时是 `sys.exit()`（抛 SystemExit），而
      SystemExit 继承自 BaseException —— 只接 Exception 的话重试**一次都不会
      发生**，直接终止。表现是"这个探针时好时坏"，而每次坏都坏在同一个地方。
    实测（2026-09-30）：连着跑两轮时，后一轮有约一半的概率卡在注册后的
      首屏渲染上 —— 页面全空（截图 /tmp/dsapp_ui_v156/00_register_failed.png
      是一整片底色），`enter_app` 自己等满 90 秒然后退出。上一轮的会话还没
      被回收干净时，单线程的 R worker 把首屏那次渲染排在后面。**重来一次就好**
      （这正是 _common 那段注释里说的"第二跑就好"）。
    ⚠️ 重来要用**换一个邮箱**：第一次可能其实已经在库里建好行了，只是界面没
      转过去；拿同一个邮箱重注册会撞"邮箱已注册"，报出来又是一个误导性的错。
    """
    ctx = _new_ctx(browser)
    last = ""
    for i in range(4):
        email = C.EMAIL if i == 0 else C.EMAIL.replace("@", "-r%d@" % i)
        page = ctx.new_page()
        try:
            page.goto(C.URL, timeout=45000)
            # ⚠️ 万一 cookie 还在（上一轮的 context 没换干净），goto 直接落在
            #    主界面上 —— 那时 `.dsapp-auth` **永远不会出现**，而
            #    `enter_app` 里那句 wait_awake 会报「等了 150 秒还是空白页」。
            #    页面根本不是空白，是"已经进来了"。先认这一种。
            if page.locator(".dsapp-shell").count():
                print("    （cookie 还在，直接就进主界面了）", flush=True)
                C.LAST_EMAIL = email
                return page
            C.wait_awake(page)
            C.enter_app(page, email=email)
            return page
        except BaseException as e:              # noqa: BLE001
            last = str(e)[:400]
            print("    ⚠️ 第 %d 次没进去：%s" % (i + 1, last.splitlines()[0]),
                  flush=True)
            try:
                page.close()
            except Exception:
                pass
            # ★★ 每一次重来都换一个**全新的 context**（cookie 一起清掉）。
            #    2026-09-30 定案：这一条才是"重来一次就好"真正缺的东西。
            #    attempt 1 失败时**服务端其实多半已经把这个账号建好了**
            #    （报错发生在"注册之后、进主界面之前"），cookie 已经落在
            #    context 里；于是 attempt 2 的 goto 直接进了主界面，
            #    而 wait_awake 等的是 `.dsapp-auth` —— 永远等不到，
            #    报出来是「等了 150 秒还是空白页」。**页面不空，是人已经进来了。**
            #    实测（2026-09-30）：连着 3 次全报"空白页"，而同一个实例上
            #    一个干净浏览器 6.3 秒就画出了登录页。
            try:
                ctx.close()
            except Exception:
                pass
            ctx = _new_ctx(browser)
            # 最后一次之前还不行，那才轮到怀疑实例本身 —— 重启它（并把
            # 重启前的 app.log 尾巴打出来，万一是真崩了要看得到）。
            # ⚠️ 重启会**重新同步 www/**（make_instance.sh 的行为），实例里
            #    手工改过的静态文件会被冲掉 —— 做变异测试时要知道这件事。
            if i == 2:
                try:
                    with open(os.environ.get("DSAPP_TEST_APP",
                                             "/tmp/dsapp_v156/app")
                              + ".log") as fh:      # noqa: E501
                        print("      app.log 末几行：%s"
                              % " | ".join(fh.read().splitlines()[-3:]),
                              flush=True)
                except Exception:
                    pass
                print("    %s" % restart_instance(), flush=True)
            # ⚠️ 这里**不能**用 page.wait_for_timeout：page 所属的 context
            #    刚刚被关掉了，那一句抛的是 TargetClosedError（在 try 外面，
            #    直接冒到 main 外面去，整轮崩掉）。用 Python 自己的 sleep。
            time.sleep(3)
    sys.exit("连着 4 次都没进去，最后一次是：\n%s" % last)


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

            # ⚠️ 顺序不是随便排的：
            #   D 要一轮**正常**回复才画得出读条 → 先跑。
            #   E 要慢放 + 静默，跑完把 slow 关掉。
            #   F 会把回答框弄出来、还会真发一条消息，放后面。
            #   G 离开对话页（去文件页），最后跑。
            sec_d_bars(page, uid, db, fx)
            sec_e_quips(page, uid, db, fx)
            sec_f_ask(page, uid, db, fx)
            sec_g_preview(page, uid, db, fx)

            page.screenshot(path=C.OUT + "/b99_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()

    _chk.done()
    print("通过 %d / 失败 %d" % (N_OK[0], N_BAD[0]))
    return 1 if N_BAD[0] else 0


if __name__ == "__main__":
    sys.exit(main())
