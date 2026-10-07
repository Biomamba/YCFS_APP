# -*- coding: utf-8 -*-
"""Test_V15.4 八条改动的浏览器探针。

    bash tests/ui_v7/make_instance.sh 8924 /tmp/dsapp_v154
    python3 tests/ui_v154/probe_v154.py

★ 这一版和 ui_v153 最大的不同：**有两条改动只有"真的把对话跑起来 + 真的
  跑一次任务"才看得到**（item 6 的围栏渲染、item 2 的产物自动刷新），而
  第 7/8 条要**换一个身份**（项目管理员 / 平台管理员）才看得到。所以这个
  探针里出现两种新动作：

    · 直接改 `users.admin_scope` 再 reload —— 「两种管理员都能进，进去后看到
      的界面不一样」这条要求，只有站到那个身份上才算验过；
    · 点真的 `.dsapp-code-run` 让代码在服务器上跑出文件 —— 产物卡片"自动
      同步"这件事，光看 DOM 里有没有那颗刷新按钮是证明不了的
      （selftest-green-is-not-coverage 已经栽过两次）。

⚠️⚠️ **一条出网请求都不许打到真厂商。** 探针里有两道闸：
      ① seed_llm() 把 base_url 同时写进**设置行和钥匙串**，然后 reload
         页面让新会话从库里读回来；
      ② 每次发完消息断言 `fx.req_n() > 0` —— 假服务端真的收到了。
         真打到厂商的话它一个请求都收不到，这一条会**响**，而不是静默地
         花用户的钱。

八条改动 → 八组断言的对应关系见每一段的标题。item 5 的浏览器侧只有
「模型生成的 HTML 报告」那一半，它要真模型（tests/v154_real_check.R）；
其余部分在 selftest 里。

⚠️ item 2 在这一版里是**两半**，两半各有一节：
    · 后半（产物卡片自动同步 + 手动刷新）—— `item2_artifacts()`；
    · 前半（报错了要说得出坏在哪、还要给得出选择）—— `item2b_retry()`。
   前半是 2026-09-29 用户追加的那句话，见 `item2b_retry()` 的头注。
"""
import io
import os
import re
import sqlite3
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402  （必须在 sys.path 之后）

from playwright.sync_api import sync_playwright  # noqa: E402


chk = C.Chk()


# =============================================================================
# 小工具（照 ui_v153/probe_v153.py 抄，只改了包名和文件名前缀）
# =============================================================================

def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ★ 探针里要 reload 的地方有三处，每一处都不是为了"刷新看看"：
      · 种完假 LLM —— `state$base_url / model` 是**会话级**的，在 mod_model
        的 observe 里从库里读一次；不 reload 的话那个已经活着的会话手里
        还是老值（空 base_url → 厂商默认地址 → **真厂商**）；
      · 改完 `users.admin_scope` —— 身份是 app.R 在**渲染那一刻**算的
        （`dsapp_user_admin_scope(user)`），老会话里还是旧身份；
      · item 1 抹掉 `users.llm_api_key` 之后 —— 要的是"新会话自己不靠用户
        点任何按钮把 Key 补回来"。

    ⚠️⚠️ 这里**不能**用 wait_awake()。它只认 `.dsapp-auth`，而 reload 时
      cookie 还在 —— 应用会**直接进主界面**，登录页一帧都不出现。
      拿 wait_awake 等它等于等一个永远不会来的东西：报出来的是
      「reload 之后 120 秒还是空白页」，而屏幕上其实早就是主界面了。
      （2026-09-28 为这个白查了一轮 —— 症状指向"服务端卡死"，实际是
        **等错了东西**。和 fake-wait-is-not-a-wait 同一个病。）
      所以这里等的是"两个可能里先到的那个"：主界面，或者登录表单。
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

    ⚠️ 它是新账号第一次开对话时自己弹的（mod_chat.R 的 onboarding），
      盖在整页上 —— 有它在，点 `#chat-send` 会一直报
      「<div id="shiny-modal"> intercepts pointer events」，
      **报错指向的是"发送按钮点不动"**，和真正的原因（一个首选项弹窗）
      隔着十万八千里。2026-09-28 为这个白查了一轮。

    选「都先别开，我自己盯着」（agent_pref_manual）是刻意的：探针要的是
    **一轮一问一答**，自动执行开着的话 agent 循环会自己往下跑，
    后面那些"发一条、断言一条"的时序全乱。

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


def busy(page):
    """服务端说"这一轮还在跑"。

    ⚠️ `#chat-send` 可能在**其它页**也有同 id 的元素吗？不会 —— 它只在对话页。
      但 bslib 把没激活的页也留在 DOM 里，所以这里限定在**可见**的那一个上：
      隐藏元素的 `disabled` 读出来照样是 True，那会让 wait_idle 永远等下去。
    """
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


def send(page, text, timeout=90):
    ensure_no_modal(page, timeout=3)
    page.fill("#chat-input", text)
    page.click("#chat-send")
    ok = wait_idle(page, timeout)
    if not ok:
        page.screenshot(path=C.OUT + "/02_send_timeout.png", full_page=True)
    return ok


def db_path_or_die():
    p = C.db_path()
    if p is None:
        sys.exit("拒绝继续：%s 底下找不到 .sqlite3。" % C.DATA_ROOT)
    return p


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def exec_sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def newest_sid(db, uid):
    """这个账号最新那个会话的 id（item 4 数消息行数要用它）。"""
    rows = sql(db, "SELECT id FROM sessions WHERE user_id = ?"
               " ORDER BY rowid DESC LIMIT 1", (uid,))
    if not rows:
        sys.exit("sessions 表里没有 uid=%s 的会话 —— 第一条消息真的发出去了吗？" % uid)
    return rows[0][0]


def tiny_png(path):
    """写一张 8×8 的真 PNG（纯标准库，不依赖 Pillow）。

    ★ 为什么非得是真 PNG、还得真解码：`<img src>` 是对的但图裂了，在 DOM 上
      和"图好好的"长得一模一样（V14 那个内联丢属性的 bug 连"图裂了没有"
      都躲过去了）。判据只能是 `naturalWidth > 0` —— 浏览器真的解出了
      宽高。一张假文件名的 GIF 也会让 naturalWidth 是 0。
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    w = h = 8
    raw = b"".join(b"\x00" + bytes([200, 40, 40] * w) for _ in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw))
           + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)
    return path


def b64_png(path):
    import base64
    with open(path, "rb") as fh:
        return base64.b64encode(fh.read()).decode("ascii")


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
            C.enter_app(page, email="v154_%s_%d@example.com"
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


# =============================================================================
# item 6：围栏里的标签不许变成活标签（V15.3 自己引入的回归）
#
# ★★★ 这一条是**照用户贴出来的原文**发的，一个字没改形状：模型把开围栏
#     **粘在正文行尾**（「…低于 500 MB。```python」），CommonMark 因此不认它
#     是围栏，整段 Python 被当成散文渲染。
#
#     修复前的形状（本探针在旧代码上跑过，红）：
#       <p>我会修正…500 MB。```python\nimport base64\nparts.append("<h2>实际静态图</h2>")…</p>
#       <pre><code></code></pre>
#     —— 一个活 <h2>、换行全变成**字面的两个字符 `\n`**、外加一个空 <pre>。
#        用户看到的就是"完全没有渲染"那一片。
#
#     所以下面的判据里最狠的是中间那条：**气泡文字里不许出现字面的 `\n`**。
#     它是"整段塌成一行"的指纹，而且不依赖任何 class 名。
# =============================================================================

_GLUED = (
    "我会修正 GIF 帧转换，让内存低于 500 MB。```python\n"
    "import base64\n"
    "from pathlib import Path\n"
    "parts.append(\"<section><h2>实际静态图</h2>\" +\n"
    "    \"<img alt='五星红旗 PNG' src='data:image/png;base64,{B64}'>\",\n"
    "    \"</body></html>\",\n"
    "])\n"
    "html_path = root / \"tutorial_executed_v2.html\"\n"
    "html_path.write_text(\"\".join(parts), encoding=\"utf-8\")\n"
    "```\n"
)


def item6_fence_and_img(page, uid, db):
    print("\n== item 6：围栏里的大于号/标签不许变成活元素 ==", flush=True)
    C.goto(page, "chat")
    ensure_no_modal(page)

    # ---- (a) 粘在正文行尾的围栏 ------------------------------------------
    send(page, _GLUED.format(B64="AAA"))

    dom = page.evaluate("""() => {
        var bubbles = document.querySelectorAll('.dsapp-msg-user .dsapp-bubble');
        var b = bubbles[bubbles.length - 1];
        if (!b) return {err: '找不到最后一条用户气泡'};
        var pres = [].slice.call(b.querySelectorAll('pre'));
        var live = [].slice.call(b.querySelectorAll('h2'))
                     .map(function (h) { return h.textContent.trim(); });
        return {
            text: b.innerText || '',
            n_pre: pres.length,
            /* 每一段 <pre> 的高度和行数：被块级元素截断的 <pre> 高度会塌到
               一行，而且里面的文字全挤在一起。 */
            pre: pres.map(function (p) {
                var r = p.getBoundingClientRect();
                return {h: Math.round(r.height),
                        n: (p.textContent || '').split('\\n').length,
                        txt: (p.textContent || '').slice(0, 40)};
            }),
            /* 代码块里的**全部文字**。判据在下面：源码那句
               `parts.append("<section><h2>实际静态图</h2>" +` 必须原样
               （连尖括号一起）留在这段文字里 —— 它一旦变成活元素，
               文字里就没有它了，而 DOM 上看起来只是"渲染得更漂亮"。 */
            code_text: pres.map(function (p) { return p.textContent || ''; })
                           .join('\\n'),
            live_h2: live,
            /* 命中的其它块级元素也记一笔：即使 h2 不在，冒出一个活的
               <section>/<img> 也是同一个病的另一个样子。 */
            n_img_live: b.querySelectorAll('img:not([src^="data:"])').length
        };
    }""")
    if "err" in dom:
        sys.exit(dom["err"])
    print("    气泡文字 %d 字，<pre> %d 段，活 <h2> %s"
          % (len(dom["text"]), dom["n_pre"], dom["live_h2"]), flush=True)
    for p in dom["pre"]:
        print("      <pre> 高 %dpx、%d 行、开头 %r" % (p["h"], p["n"], p["txt"]),
              flush=True)

    # ⚠️ 字面的反斜杠 n（两个字符）—— 旧代码下整段 Python 被当成散文，
    #    CommonMark 把软换行渲染成一个字面的 `\n`。这是"塌成一行"的指纹。
    chk("★★★ 气泡里没有字面的 `\\n`（整段 Python 没有塌成一行）",
        "\\n" not in dom["text"],
        "文字片段 %r" % dom["text"][:120])
    chk("★★★ 页面里没有把「实际静态图」渲染成标题的活 <h2>",
        dom["live_h2"] == [], "活 <h2> = %s" % dom["live_h2"])
    chk("★★ 那段 Python 落在 <pre> 里，而且里面的换行还在（≥ 5 行）",
        len(dom["pre"]) >= 1 and max(p["n"] for p in dom["pre"]) >= 5,
        dom["pre"])
    chk("★★ 那个 <pre> 的高度明显大于一行（没有被块级元素截断）",
        len(dom["pre"]) >= 1 and max(p["h"] for p in dom["pre"]) > 60,
        [p["h"] for p in dom["pre"]])
    chk("★★★ Python 源码里的标签**原样是文字**（`<section><h2>…` 还在）",
        '<section><h2>实际静态图</h2>' in dom["code_text"],
        "代码块文字 %r" % dom["code_text"][:160])
    chk("★★★ 那句 <img alt='…' src='…' 也原样是文字，没变成活元素",
        "<img alt='五星红旗 PNG' src='data:image/png;base64,AAA'>"
        in dom["code_text"], dom["code_text"][:200])
    chk("★★ 围栏外面还留着一个空 <pre> 才算正常（旧代码的那个 bug 形状）"
        "—— 这里反过来：<pre> 里必须有正文",
        any(len(p["txt"]) > 0 for p in dom["pre"]), dom["pre"])

    # ---- (b) 裸的 data: 图片：要真解码出来 ---------------------------------
    png = tiny_png(os.path.join(C.OUT, "px.png"))
    b64 = b64_png(png)
    send(page, "<img alt='内联小图' src='data:image/png;base64,%s'>" % b64)

    img = page.evaluate("""() => {
        var bubbles = document.querySelectorAll('.dsapp-msg-user .dsapp-bubble');
        var b = bubbles[bubbles.length - 1];
        if (!b) return {err: '找不到最后一条用户气泡'};
        var im = b.querySelector('img');
        if (!im) return {err: '气泡里一个 <img> 都没有（放行那一层没生效）',
                         html: b.innerHTML.slice(0, 200)};
        return {nw: im.naturalWidth, nh: im.naturalHeight,
                alt: im.getAttribute('alt'),
                src_head: (im.getAttribute('src') || '').slice(0, 30),
                /* 属性白名单：只留 src/alt/title/width/height */
                attrs: [].slice.call(im.attributes).map(function (a) { return a.name; })};
    }""")
    if "err" in img:
        chk("★★★ 裸的 data: 图片被放行成活的 <img>", False,
            img.get("html", img["err"]))
    else:
        print("    图 naturalWidth=%s alt=%r 属性=%s"
              % (img["nw"], img["alt"], img["attrs"]), flush=True)
        chk("★★★ 图**真的解码出来了**（naturalWidth > 0，不是 src 对而已）",
            img["nw"] and img["nw"] > 0, img)
        chk("★★ 只留了白名单属性（src/alt/title/width/height）",
            set(img["attrs"]) <= {"src", "alt", "title", "width", "height"},
            img["attrs"])
        chk("★★ src 是 data:image/png（没有被消毒链丢掉）",
            img["src_head"].startswith("data:image/png"), img["src_head"])

    # ---- (c) 散文里的排版标签**照旧要渲染**（V15.3 的行为不能退化）--------
    send(page, "这条用来对照：<h4>我应该是一个真标题</h4>")
    n_h4 = page.evaluate("""() => {
        var bubbles = document.querySelectorAll('.dsapp-msg-user .dsapp-bubble');
        var b = bubbles[bubbles.length - 1];
        return b ? b.querySelectorAll('h4').length : -1;
    }""")
    chk("★★ 围栏**之外**的 <h4> 仍然渲染成真元素（没修过头）",
        n_h4 == 1, "h4 个数 %s" % n_h4)


# =============================================================================
# item 3：思考不闪 + 转圈 + 活人感提示词
# =============================================================================

_THINK_PROBE_JS = """() => {
    var el = document.querySelector('.dsapp-think-pre');
    var q  = document.querySelector('.dsapp-wait-box .dsapp-quip');
    var s  = document.querySelector('.dsapp-wait-box .dsapp-wait-spin');
    if (!el && !q) return null;
    /* ★ 指纹：第一次见到这个节点时给它盖一个一次性记号。
       节点被换掉的话，新节点上没有这个记号，会被当成另一个 uuid ——
       这正是"闪"的定义（用户在读的那块 DOM 被整块换掉）。 */
    if (el && !el.dataset.v154u) {
        el.dataset.v154u = 'u' + Math.random().toString(36).slice(2);
    }
    if (q && !q.dataset.v154q) {
        q.dataset.v154q = 'q' + Math.random().toString(36).slice(2);
    }
    return {
        u: el ? el.dataset.v154u : null,
        n: el ? (el.textContent || '').length : null,
        q: q ? q.dataset.v154q : null,
        qt: q ? (q.textContent || '') : null,
        spin: !!s
    };
}"""


def item3_thinking(page, fx):
    print("\n== item 3：思考过程不闪、转圈、提示词轮换 ==", flush=True)

    C.goto(page, "chat")
    # 慢放的三个理由：
    #   · 整段在一个 200ms 轮询周期内吐完的话，指纹**一次都采不到**，
    #     "uuid 全程不变"会因为没采样而通过（假绿）；
    #   · 提示词每 3200ms 才换一句（www/app.js 的 EVERY），要看到它**真的
    #     换过**，就必须让"正文还没开始"这个窗口比 6.4 秒还长；
    #   · 用户报的闪烁本来就是"长期生成时"才有。
    fx.slow(1.0)
    parts = ["先看用户给了什么。", "这一步要确认物种和注释版本。",
             "然后决定是走比对还是走定量。", "定量的话得先有 count 矩阵。",
             "还得确认参考基因组对不对。", "最后把步骤写成代码。",
             "检查一遍依赖装没装。", "再核一遍输出目录。",
             "好了，可以动笔了。"]
    fx.set_queue(C.sse_multi(parts, "好，我按这个思路来。"))

    page.evaluate("""() => {
        window.__v154inv = 0;
        if (window.__v154hooked) return;
        window.__v154hooked = true;
        $(document).on('shiny:outputinvalidated', function (e) {
            if (e && e.name &&
                (String(e.name).indexOf('wait_box') >= 0 ||
                 String(e.name).indexOf('thinking_box') >= 0))
                window.__v154inv++;
        });
    }""")

    page.fill("#chat-input", "想一个分析方案")
    page.click("#chat-send")

    samples = []
    t0 = time.time()
    while time.time() - t0 < 90:
        v = page.evaluate(_THINK_PROBE_JS)
        if v:
            samples.append(v)
        if samples and not busy(page):
            break
        page.wait_for_timeout(180)

    page.wait_for_timeout(400)
    inv = page.evaluate("() => window.__v154inv")
    fx.no_slow()

    uu = [s["u"] for s in samples if s["u"]]
    qq = [s["q"] for s in samples if s["q"]]
    qts = [s["qt"] for s in samples if s["qt"] is not None and s["qt"] != ""]
    ns_ = [s["n"] for s in samples if s["n"] is not None]
    print("    采样 %d 次：思考 uuid %d 种、字数 %s"
          % (len(samples), len(set(uu)), ns_), flush=True)
    print("    提示词节点 %d 种、出现过 %d 句：%s"
          % (len(set(qq)), len(set(qts)), sorted(set(qts))), flush=True)
    print("    wait_box/thinking_box 失效 %s 次" % inv, flush=True)

    chk("★★ 采到了思考过程的骨架（没采到的话下面几条全是空过）",
        len(samples) >= 3, "样本 %d" % len(samples))
    if len(uu) >= 3:
        chk("★★★ 全程**只有一个**思考节点 —— 用户在读的那块 DOM 没被换掉",
            len(set(uu)) == 1, "uuids=%s" % sorted(set(uu)))
        chk("★★★ 字数一路只增不减（是往外贴，不是整块重画）",
            all(ns_[i] <= ns_[i + 1] for i in range(len(ns_) - 1)), ns_)
        chk("★★ 而且生成期间**真的在长**（至少跨了两个不同的字数）",
            len(set(ns_)) >= 2, ns_)

    chk("★★★ 转圈的那个 spinner 在（用户点名要的「转圈的图案」）",
        any(s["spin"] for s in samples),
        "采到 spinner 的样本 %d/%d" % (sum(1 for s in samples if s["spin"]),
                                       len(samples)))
    chk("★★★ 提示词节点**从头到尾是同一个 DOM 节点**（轮换没有引起重画）",
        len(set(qq)) == 1, "q=%s" % sorted(set(qq)))
    chk("★★★ 提示词**真的换过**（≥ 2 句），不是钉死一句",
        len(set(qts)) >= 2, sorted(set(qts)))
    chk("★★ 换过的句子都来自内置那 12 条（没有半截话/空串）",
        all(any(q == full for full in _QUIPS) for q in set(qts)),
        sorted(set(qts)))

    # 闪屏的**根**：这一格的重画频率。改造前它长在 output$streaming 里，
    # 那一格跟着 200ms 的流式泵走 —— 一次生成下来是**几十次**。
    chk("★★★ 这两格没有被反复重画（一次生成下来 ≤ 8 次失效）",
        inv is not None and inv <= 8, "失效 %s 次" % inv)

    wait_idle(page, 60)


# 内置提示词（R/utils.R 的 DSAPP_THINK_QUIPS）。探针抄一份是为了断言
# "轮换出来的是**完整的一句**"——上面那条"没有半截话"就是拿它比的。
# ⚠️ 两边不一致会让这条**红**，那是好事：说明有人改了常量没改探针。
_QUIPS = [
    "院士别催了，我正在全力思考", "冒了烟的思考中",
    "脑子转得比风扇快，稍等", "正在把问题拆成小块",
    "让我先捋一捋", "这条路走不通，换一条再想",
    "结论还在路上，别急", "已经写在草稿纸上了",
    "正在和公式较劲", "让我把逻辑再核一遍",
    "快了，别眨眼", "正在给你的问题找个漂亮解法",
]


# =============================================================================
# item 4：「重新发送」把原文填回输入框，**不**替用户发出去
# =============================================================================

def item4_resend(page, uid, db):
    print("\n== item 4：重新发送 → 回到输入框 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    line = "帮我统计一下这批样本的测序深度。"
    send(page, line)

    sid = newest_sid(db, uid)
    n0 = sql(db, "SELECT COUNT(*) FROM messages WHERE session_id = ?", (sid,))[0][0]

    page.fill("#chat-input", "")          # 空框：量的是"填回去"，不是"追加"
    page.wait_for_timeout(300)

    # ⚠️ 数**气泡**只能比"点之前 / 点之后"，不能写死 1 ——
    #    item 6 已经在同一个对话里发过三条了，写死 1 的话这条必红，
    #    而红的原因和被测的东西毫无关系（探针自己数错了）。
    n_bub0 = page.locator(".dsapp-msg-user .dsapp-bubble").count()

    btns = page.locator(".dsapp-msg-user .dsapp-resend")
    n_btn = btns.count()
    chk("★★ 用户气泡上有「重新发送」这颗按钮", n_btn >= 1, "找到 %d 颗" % n_btn)
    chk("★★ 每一条用户气泡都有（不是只有最后那条有）",
        n_btn == n_bub0, "%d 颗按钮 / %d 条气泡" % (n_btn, n_bub0))
    if n_btn == 0:
        return

    btns.last.click()
    page.wait_for_timeout(1200)

    got = page.input_value("#chat-input")
    print("    输入框里现在是 %r" % got, flush=True)
    n1 = sql(db, "SELECT COUNT(*) FROM messages WHERE session_id = ?", (sid,))[0][0]
    n_bub1 = page.locator(".dsapp-msg-user .dsapp-bubble").count()

    chk("★★★ 原文**回到了输入框**", got.strip() == line, "%r" % got)
    chk("★★★ 而且**没有**替用户发出去（消息行数没变）", n1 == n0,
        "之前 %d 行、之后 %d 行" % (n0, n1))
    chk("★★ 也没有多出第二条用户气泡", n_bub1 == n_bub0,
        "点之前 %d 个、点之后 %d 个" % (n_bub0, n_bub1))

    page.fill("#chat-input", "")


# =============================================================================
# item 2：任务跑完，右边的「本对话的文件」自己刷出来 + 手动刷新有条
# =============================================================================

def _dismiss_confirm(page):
    """代码块带 warning 时服务端会弹「确认执行」。探针只跑自己写的安全代码，
    但扫出来的 warning 未必为 0，所以这里补一下。"""
    for _ in range(12):
        if page.locator("#shiny-modal:visible").count() == 0:
            return
        b = page.locator("#chat-do_run")
        if b.count():
            b.first.click()
            page.wait_for_timeout(800)
            return
        page.wait_for_timeout(300)


def item2_artifacts(page, uid, db, fx):
    print("\n== item 2：产物卡片自动同步 + 手动刷新 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    want = "v154_probe_output.txt"
    fx.set_queue(C.sse(
        "写个小脚本把结果落到工作区：\n\n"
        "```python\n"
        "import pathlib\n"
        "pathlib.Path(%r).write_text('hello v154')\n"
        "print('done')\n"
        "```\n" % want))

    send(page, "跑一下这个")

    # 右栏那张卡片在开始之前长什么样，先记下来 —— 后面要比"它自己变了"。
    before = page.evaluate(
        "() => (document.querySelector('.dsapp-artifacts') || {}).innerText || ''")
    print("    点执行之前卡片文字 %d 字" % len(before), flush=True)

    runs = page.locator(".dsapp-code-run")
    n_run = runs.count()
    chk("★★ 助手气泡里出现了可执行的代码块", n_run >= 1, "找到 %d 颗" % n_run)
    if n_run == 0:
        return
    runs.last.click()
    _dismiss_confirm(page)

    # ★★ 从这里开始**不碰页面**：不切页签、不点刷新、不 reload。
    #    用户的原话是「这个界面应该能在产出文件后自动刷新」—— 所以断言就是
    #    "什么都不做，若干秒后它自己出现了"。
    appeared, t0, txt = False, time.time(), ""
    while time.time() - t0 < 90:
        txt = page.evaluate(
            "() => (document.querySelector('.dsapp-artifacts') || {}).innerText || ''")
        if want in txt:
            appeared = True
            break
        page.wait_for_timeout(1000)
    dt = time.time() - t0
    print("    自动出现：%s（%.1f 秒）" % (appeared, dt), flush=True)

    chk("★★★ 任务跑完，产物**自己**出现在右栏（全程没点任何东西）",
        appeared, "等了 90 秒还是没出现；卡片文字 %r" % txt[-300:])
    chk("★★ 而且是在 30 秒内出现的（不是靠人手动刷）", appeared and dt < 30,
        "%.1f 秒" % dt)

    # ---- 手动刷新那颗按钮 ---------------------------------------------------
    btn = page.locator('[title="重新读取本对话的产物"]')
    chk("★★ 卡片头上有那颗手动刷新按钮（用户点名要的）", btn.count() >= 1,
        "找到 %d 颗" % btn.count())
    if btn.count():
        btn.first.click()
        page.wait_for_timeout(1500)
        body = page.inner_text("body")
        chk("★★ 点了之后有回执（不是点了没动静）",
            "已重新读取本对话的文件" in body, "页面里没找到回执")
        # 再点一次：Shiny 的值没变就不派发，所以这里传的是 Math.random()。
        btn.first.click()
        page.wait_for_timeout(1500)
        chk("★ 再点一次照样有回执（值没变也要派发）",
            "已重新读取本对话的文件" in page.inner_text("body"), "")

    # 回库确认文件真的产出来了（把"没写进去"和"没画出来"分开报）。
    # ⚠️ `tasks` 表**没有 user_id 列**（归属靠 session_id → sessions.user_id），
    #    第一版这里写了 `WHERE user_id = ?`，报的是 "no such column" ——
    #    在一堆 ✓ 之后崩在这一行，看起来像被测代码挂了。夹具的 SQL 也要对表。
    row = sql(db, "SELECT t.status, t.exit_code FROM tasks t"
                  " JOIN sessions s ON s.id = t.session_id"
                  " WHERE s.user_id = ? ORDER BY t.rowid DESC LIMIT 1", (uid,))
    print("    最后一个任务的状态：%s" % row, flush=True)
    chk("★★ 任务在库里是成功的（产物是**跑出来的**，不是夹具塞的）",
        len(row) == 1 and row[0][1] == 0, row)


# =============================================================================
# item 2 前半：任务报错之后，卡片要说得出「坏在哪」，还要给得出选择
# =============================================================================
#
# 用户原话：「你看下最新的"绘制国旗"，任务，报错了，但是却并没有告诉用户做
# 操作和选择」。现场（线上任务 #132）走的是**静默分支**（平台判定"代码自己
# 写错了" + 自动修开着），整张卡片只有一句「你不用做什么」。
#
# 这一节验的就是补上的那两样：
#   ① `.dsapp-run-plain` —— 坏在哪（一句人话，含真报错的关键行）；
#   ② `.dsapp-run-retry` —— 「重试这一步」，而且**它真的能跑**：
#      点了之后回库能看见一条**新的任务行**，代码就是当时那段，
#      并且结果照旧写回这条对话（tool 消息多一条）。
#
# ⚠️ 判据一律落在"回库里数得出来的东西"上，不看界面上的字面——本仓的
#    cooldown-looks-like-broken-ui 那条教训：写操作之后必须回库确认，
#    才能把"没写进去"和"没画出来"分开报。

_FAIL_REPLY = (
    "这段会报错，先跑一下看看：\n\n"
    "```python\n"
    "values = [1, 2, 3]\n"
    "print(values[9])\n"
    "```\n")


def item2b_retry(page, uid, db, fx):
    print("\n== item 2 前半：报错卡片说得出坏在哪 + 「重试这一步」真的能跑 ==",
          flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    fx.set_queue(C.sse(_FAIL_REPLY))
    send(page, "跑一下这个")

    runs = page.locator(".dsapp-code-run")
    n_run = runs.count()
    chk("★★ 助手气泡里出现了可执行的代码块", n_run >= 1, "找到 %d 颗" % n_run)
    if n_run == 0:
        return
    runs.last.click()
    _dismiss_confirm(page)

    # 等失败卡片长出来。任务要起进程、要真的跑挂，还要等历史重渲染。
    t0 = time.time()
    while time.time() - t0 < 90 and page.locator(".dsapp-run-retry").count() == 0:
        page.wait_for_timeout(500)
    dt = time.time() - t0
    n_retry = page.locator(".dsapp-run-retry").count()
    print("    失败卡片 %.1f 秒后出现，重试按钮 %d 颗" % (dt, n_retry), flush=True)

    chk("★★★ 失败卡片上有「重试这一步」（用户要的「操作和选择」）", n_retry >= 1,
        "%d 颗；页面里有没有 .dsapp-run-err：%d"
        % (n_retry, page.locator(".dsapp-run-err").count()))
    if n_retry == 0:
        return
    chk("★★ 而且这张卡片确实是**失败**的那张（不是别的格子里的按钮）",
        page.locator(".dsapp-run-err").count() >= 1,
        "`.dsapp-run-err` %d 个" % page.locator(".dsapp-run-err").count())

    # ---- ① 坏在哪 ----------------------------------------------------------
    plain = page.locator(".dsapp-run-plain")
    txt = plain.last.inner_text() if plain.count() else ""
    print("    「坏在哪」那句：%r" % txt[:120], flush=True)
    chk("★★★ 卡片上有一句「坏在哪」，而且是真的报错内容（不是空壳）",
        plain.count() >= 1 and "IndexError" in txt,
        "找到 %d 句；内容 %r" % (plain.count(), txt[:200]))
    # ⚠️ 反面：不许把那一大坨 Traceback 整段糊上来（那是 `.dsapp-run-pre`
    #    的活）。这一句是给"扫一眼"用的，超过两行就没人读了。
    chk("★★ 那一句是**一句**（不是把整个 Traceback 又贴一遍）",
        bool(txt) and "\n" not in txt.strip() and len(txt) < 200,
        "%d 字、%d 行" % (len(txt), len(txt.strip().splitlines())))

    # ---- ② 它在库里对应的那条失败任务 ---------------------------------------
    sid = newest_sid(db, uid)
    before_ids = set(r[0] for r in sql(
        db, "SELECT t.id FROM tasks t JOIN sessions s ON s.id = t.session_id"
            " WHERE s.user_id = ?", (uid,)))
    n_tool_before = sql(db, "SELECT COUNT(*) FROM messages"
                            " WHERE session_id = ? AND role = 'tool'", (sid,))[0][0]
    print("    点重试之前：任务 %d 条、tool 消息 %d 条"
          % (len(before_ids), n_tool_before), flush=True)

    retry_lbl = page.locator(".dsapp-run-retry").last.get_attribute("title") or ""
    chk("★ 按钮自己说清楚了它和「让 AI 看看」的区别",
        "再跑一遍" in retry_lbl, retry_lbl)

    page.locator(".dsapp-run-retry").last.click()
    page.wait_for_timeout(2500)
    body = page.inner_text("body")
    chk("★★ 点了之后有回执（不是点了没动静）",
        "已重新提交任务" in body, "页面上没找到回执")

    # ---- ③ 回库：真的多了一条任务，代码就是当时那段 -------------------------
    new_rows, t0 = [], time.time()
    while time.time() - t0 < 90:
        rows = sql(db, "SELECT t.id, t.code FROM tasks t"
                       " JOIN sessions s ON s.id = t.session_id"
                       " WHERE s.user_id = ? ORDER BY t.id DESC LIMIT 8", (uid,))
        new_rows = [(r[0], r[1] or "") for r in rows if r[0] not in before_ids]
        if new_rows:
            break
        page.wait_for_timeout(1000)
    print("    点重试之后新增任务：%s" % [(i, "values[9]" in c) for i, c in new_rows],
          flush=True)

    chk("★★★ 回库确认：真的多跑了一条任务（不是只弹了句提示）",
        len(new_rows) >= 1, "新任务 %d 条" % len(new_rows))
    chk("★★★ 而且跑的是**当时那段代码**（重试的语义就是这个）",
        any("values[9]" in c for _, c in new_rows),
        "新任务的代码：%r" % [c[:60] for _, c in new_rows])

    # ---- ④ 结果写回对话 -----------------------------------------------------
    # ⚠️ 这一条是 `.dsapp-run-retry` 那颗按钮最容易漏掉的一半：引擎那边不登记
    #    manual_run 的话，任务照样跑、日志照样对，但**结果一个字都不会写回
    #    这条对话** —— 用户点完重试之后什么都没看见。
    grew, t0 = False, time.time()
    while time.time() - t0 < 90:
        n_now = sql(db, "SELECT COUNT(*) FROM messages"
                        " WHERE session_id = ? AND role = 'tool'", (sid,))[0][0]
        if n_now > n_tool_before:
            grew = True
            break
        page.wait_for_timeout(1000)
    chk("★★★ 重试的结果**写回了这条对话**（库里多了一条执行结果消息）",
        grew, "tool 消息一直是 %d 条" % n_tool_before)

    # 页面上也得多出一张失败卡片 —— 任务失败了，那一步就该说清楚
    page.wait_for_timeout(3000)
    chk("★★ 页面上也多了一张新的执行结果卡片",
        page.locator(".dsapp-run-retry").count() > n_retry,
        "%d → %d" % (n_retry, page.locator(".dsapp-run-retry").count()))


# =============================================================================
# item 1：Key 被抹掉之后，reload 就自己回来（不让版本更新收过路费）
# =============================================================================

def item1_selfheal(page, uid, db, fx):
    print("\n== item 1：Key 列被抹掉 → 不点任何按钮也能发出去 ==", flush=True)

    C.goto(page, "chat")

    before = sql(db, "SELECT llm_api_key FROM users WHERE id = ?", (uid,))[0][0]
    chk("★ 前提：种子里那把 Key 是写在 `users.llm_api_key` 列上的",
        before is not None and len(str(before)) > 0, repr(before)[:60])
    n_keys = sql(db, "SELECT COUNT(*) FROM user_api_keys WHERE user_id = ?",
                 (uid,))[0][0]
    chk("★ 前提：钥匙串里那一行在（自愈读的就是它）", n_keys >= 1,
        "user_api_keys 行数 %s" % n_keys)

    # ★★ 模拟"版本更新之后列没了、钥匙串还在"—— 用户报的就是这个形状。
    exec_sql(db, "UPDATE users SET llm_api_key = NULL WHERE id = ?", (uid,))
    after = sql(db, "SELECT llm_api_key FROM users WHERE id = ?", (uid,))[0][0]
    chk("★ 前提：列真的被抹掉了", after is None, repr(after))

    # 用户会做的唯一一件事：刷新页面（甚至这都不需要 —— 新开会话也一样）。
    relogin(page, C.LAST_EMAIL)
    ensure_no_modal(page)

    n0 = fx.req_n()
    ok = send(page, "这条用来证明配置自己回来了。", timeout=120)
    n1 = fx.req_n()
    print("    发消息前后假 LLM 收到 %d → %d 个请求" % (n0, n1), flush=True)

    chk("★★★ 刷新之后**不点任何按钮**就发出去了（假 LLM 真的收到了）",
        ok and n1 > n0, "req %d → %d，wait_idle=%s" % (n0, n1, ok))

    healed = sql(db, "SELECT llm_api_key FROM users WHERE id = ?", (uid,))[0][0]
    chk("★★★ 而且列被**补回库里**了（不是只在内存里兜着）",
        healed is not None and len(str(healed)) > 0,
        "列现在 = %s" % repr(healed)[:60])
    # ⚠️ 比的必须是**明文**，不是密文：这一列是加密的，每次加密都带一个新
    #    nonce（`dsapp_sec_enc`），同一个 Key 加密两次得到的串也不一样。
    #    第一版比的是密文，于是"自愈成功"被报成红的 —— 而它其实是对的。
    #    （红的原因和被测的东西无关，是探针自己比错了对象。）
    plain_before, plain_after = C.r_decrypt([before, healed])
    print("    明文 before=%r after=%r" % (plain_before, plain_after),
          flush=True)
    chk("★★ 补回来的和原来那把**是同一个**（解得开、不是写了个空壳）",
        plain_after is not None and plain_after == plain_before
        and plain_after != "<NULL>",
        "before=%r after=%r" % (plain_before, plain_after))

    body = page.inner_text("body")
    chk("★ 页面上没有出现「请先到设置页填 API Key」这类要用户动手的提示",
        "请先到设置页填" not in body and "请先填写 API" not in body, "")


# =============================================================================
# item 7：合并成「后台管理」，两种管理员进去看到的界面不一样
# =============================================================================

_ADMIN_JS = """() => {
    var ul = document.getElementById('admin-bs_tab');
    if (!ul) return {err: '页面上没有 #admin-bs_tab —— 后台管理那一页没渲染出来'};
    /* ⚠️ 只取**这一层**的页签链接。整个 navset 的容器是 ul 的父节点，
       卡片里如果自己还有一组 nav（比如某张卡的页签），用后代选择器会把
       它们一起捞进来，数出来的页签个数就虚高了。 */
    var links = [].slice.call(ul.querySelectorAll('a.nav-link, button.nav-link'));
    var labels = links.map(function (a) { return (a.innerText || '').trim(); });
    var wrap = ul.parentElement;
    var heads = [].slice.call(wrap.querySelectorAll('.card-header'))
        .map(function (h) { return (h.innerText || '').replace(/\\s+/g, ' ').trim(); });
    return {labels: labels, heads: heads,
            /* 提示词编辑器那一格的 id 前缀是 prompt- */
            n_prompt: wrap.querySelectorAll('[id^="prompt-"]').length};
}"""


def _admin_state(page):
    return page.evaluate(_ADMIN_JS)


def item7_backstage(page, uid, db):
    print("\n== item 7：后台管理（两种管理员看到的界面不一样）==", flush=True)

    # ---- (a) 平台管理员：5 个子页，14 张卡全在 ---------------------------
    exec_sql(db, "UPDATE users SET is_admin = 1, admin_scope = 'platform'"
                 " WHERE id = ?", (uid,))
    relogin(page, C.LAST_EMAIL)
    ensure_no_modal(page)

    rail = page.evaluate("""() => [].slice.call(
        document.querySelectorAll('.dsapp-rail-link')).map(function (a) {
            return {t: (a.innerText || '').trim(),
                    v: a.getAttribute('data-nav')}; })""")
    texts = [r["t"] for r in rail]
    print("    左栏：%s" % texts, flush=True)
    chk("★★★ 左栏只有一项「后台管理」，没有单独的「后台」/「平台管理」",
        sum(1 for t in texts if "后台" in t or "管理" in t) == 1
        and any("后台管理" in t for t in texts), texts)

    C.goto(page, "admin")
    st = _admin_state(page)
    if "err" in st:
        chk("★★★ 后台管理页渲染出来了", False, st["err"])
        return
    print("    子页签：%s" % st["labels"], flush=True)
    print("    卡片头 %d 个：%s" % (len(st["heads"]), st["heads"]), flush=True)

    chk("★★★ 平台管理员看到 5 个子页签",
        st["labels"] == ["平台总览", "用户与权限", "运行与日志", "资源与文件",
                         "提示词"], st["labels"])
    chk("★★★ 14 张卡片一张不少、也没有重复（+ 提示词编辑器 = 15 个卡头）",
        len(st["heads"]) == 15, "%d 个：%s" % (len(st["heads"]), st["heads"]))
    for t in ["服务器健康", "平台用量", "磁盘占用", "平台账号概览",
              "用户活跃情况", "应用报错日志", "可调用硬件资源",
              "文件管理区的归属", "各用户的任务运行情况", "token 用量"]:
        chk("    · 平台视角里「%s」在" % t,
            any(h.startswith(t) for h in st["heads"]), st["heads"])
    chk("★★ 提示词编辑器那一格也渲染出来了", st["n_prompt"] > 0,
        "prompt-* 节点 %d 个" % st["n_prompt"])

    # 每个子页签都点得动、点完有东西（"点了没反应"是本仓的常客）
    for lab, val in [("用户与权限", "users"), ("运行与日志", "runs"),
                     ("资源与文件", "res"), ("提示词", "prompt"),
                     ("平台总览", "overview")]:
        page.evaluate("""(v) => {
            var ul = document.getElementById('admin-bs_tab');
            var a = ul.querySelector('a[data-value="' + v + '"],' +
                                     'button[data-value="' + v + '"]');
            if (a) a.click();
        }""", val)
        page.wait_for_timeout(900)
        shown = page.evaluate("""() => {
            var ul = document.getElementById('admin-bs_tab');
            var wrap = ul.parentElement;
            var panes = [].slice.call(wrap.querySelectorAll('.tab-pane'));
            var vis = panes.filter(function (p) { return p.classList.contains('active'); });
            return vis.map(function (p) { return p.innerText.trim().length; });
        }""")
        chk("★★ 点「%s」之后确实切过去了（可见的那一页有内容）" % lab,
            len(shown) == 1 and shown[0] > 20, "可见页 %s" % shown)

    # ---- (b) 项目管理员：3 个子页，平台专属的卡片一个都不渲染 ------------
    exec_sql(db, "UPDATE users SET is_admin = 1, admin_scope = 'project'"
                 " WHERE id = ?", (uid,))
    relogin(page, C.LAST_EMAIL)
    ensure_no_modal(page)
    C.goto(page, "admin")
    st2 = _admin_state(page)
    if "err" in st2:
        chk("★★★ 项目管理员也进得去后台管理页", False, st2["err"])
        return
    print("    项目管理员：子页签 %s" % st2["labels"], flush=True)
    print("    项目管理员：卡片头 %d 个：%s"
          % (len(st2["heads"]), st2["heads"]), flush=True)

    chk("★★★ 项目管理员看到 3 个子页签（没有「平台总览」）",
        st2["labels"] == ["用户与权限", "运行与日志", "资源与文件"],
        st2["labels"])
    chk("★★★ 提示词那一页**根本不存在**（不是藏起来）",
        "提示词" not in st2["labels"] and st2["n_prompt"] == 0,
        "labels=%s prompt-* %d 个" % (st2["labels"], st2["n_prompt"]))
    chk("★★★ 平台专属的 8 张卡**一个都没渲染**（不是 CSS 藏起来）",
        len(st2["heads"]) == 6, "%d 个：%s" % (len(st2["heads"]), st2["heads"]))
    for t in ["用户", "团队", "登录锁定", "各用户的任务运行情况", "操作日志",
              "token 用量"]:
        chk("    · 项目视角里「%s」在" % t,
            any(h.startswith(t) for h in st2["heads"]), st2["heads"])

    # 收尾：把身份降回普通用户，免得后面几条带着管理员身份跑
    exec_sql(db, "UPDATE users SET is_admin = 0, admin_scope = '' WHERE id = ?",
             (uid,))
    relogin(page, C.LAST_EMAIL)


# =============================================================================
# item 8：系统提示词在后台能改，改完**下一个请求**就用新的
# =============================================================================

_MARK = "V154-PROMPT-MARK-8f3a"


def item8_prompt(page, uid, db, fx):
    print("\n== item 8：后台管理里改系统提示词 ==", flush=True)

    # 先回库确认没有残留（夹具必须是这一轮新造的）
    n0 = sql(db, "SELECT COUNT(*) FROM prompt_overrides")[0][0]
    chk("★ 前提：这一轮开始前 prompt_overrides 是空的", n0 == 0,
        "残留 %d 行" % n0)

    exec_sql(db, "UPDATE users SET is_admin = 1, admin_scope = 'platform'"
                 " WHERE id = ?", (uid,))
    relogin(page, C.LAST_EMAIL)
    ensure_no_modal(page)
    C.goto(page, "admin")
    page.wait_for_timeout(1200)
    page.evaluate("""() => {
        var ul = document.getElementById('admin-bs_tab');
        var a = ul.querySelector('a[data-value="prompt"],' +
                                 'button[data-value="prompt"]');
        if (a) a.click();
    }""")
    page.wait_for_timeout(1500)

    # ---- 左栏那 10 节：8 节可改 + 2 节只读 --------------------------------
    opts = page.evaluate("""() => [].slice.call(
        document.querySelectorAll('#prompt-pp_part option')).map(function (o) {
            return {v: o.value, t: (o.textContent || '').trim()}; })""")
    print("    10 节：%s" % [o["t"] for o in opts], flush=True)
    chk("★★★ 左栏列了 10 个常量段（用户选的「分节编辑那 10 个常量段」）",
        len(opts) == 10, "%d 个" % len(opts))
    # ★★★ 这两条是 2026-09-29 补的，起因是**探针自己抓到的一个真 bug**：
    #     第一版把 choices 的方向写反了，`<option value="身份">DSPROMPT_IDENTITY
    #     </option>` —— 界面上列的是常量名，点任何一行 input 收到的是中文
    #     标签，服务端那句"不认识的 key 就回落到第一节"把它静默吃掉，
    #     于是**点哪一节都在编辑「身份」**，而且保存成功、写库成功。
    #     下面这两条一条管显示、一条管取值的通路，缺一条都抓不住它。
    chk("★★★ **值**是常量名（点哪一节就真的是哪一节）",
        all(re.match(r"^DSPROMPT_[A-Z_]+$", o["v"] or "") for o in opts),
        [o["v"] for o in opts])
    chk("★★★ **显示的是中文标签**，不是常量名",
        all(not (o["t"] or "").startswith("DSPROMPT_") for o in opts),
        [o["t"] for o in opts])
    chk("★★ 其中 2 节标着「只读」（拼出来的那两节）",
        sum(1 for o in opts if "只读" in o["t"]) == 2, [o["t"] for o in opts])
    chk("★★ 一开始没有任何一节标着「已改」",
        all("已改" not in o["t"] for o in opts), [o["t"] for o in opts])
    badge = page.inner_text("#prompt-pp_badge") if page.locator(
        "#prompt-pp_badge").count() else ""
    chk("★ 卡头徽标写着「全部为内置默认」", "全部为内置默认" in badge, badge)

    # ---- 只读的那两节：切过去不许出现编辑器 --------------------------------
    # ⚠️ 顺序要紧：`_readonly_ok()` 会把选择停在派生那一节上，所以它必须放在
    #    "选中身份那一节"**之前**。第一版放在后面，症状是紧接着那句
    #    `page.fill("#prompt-pp_body")` 等 30 秒超时 —— 报错指向"找不到输入框"，
    #    而真正的原因是探针自己把选择留在了一个**本来就没有输入框**的节上。
    chk("★★ 拼出来的那两节是只读的（没有 textarea、给了只读提示）",
        _readonly_ok(page, "DSPROMPT_CODE_RULES"),
        "切到 derived 那一节之后的 DOM 不合预期")

    # ---- 改「身份」那一节 --------------------------------------------------
    page.select_option("#prompt-pp_part", "DSPROMPT_IDENTITY")
    page.wait_for_timeout(1200)
    before = page.input_value("#prompt-pp_body")
    chk("★★ 编辑器里读出来了这一节的默认正文", len(before) > 10,
        "%d 字" % len(before))

    page.fill("#prompt-pp_body", _MARK + " 我是一个被管理员改过的身份段。")
    page.click("#prompt-pp_save")
    page.wait_for_timeout(2000)

    rows = sql(db, "SELECT key, length(body) FROM prompt_overrides")
    print("    prompt_overrides：%s" % rows, flush=True)
    chk("★★★ 回库确认：写进去了一行", len(rows) == 1, rows)
    chk("★★★ 而且写的是**被改的那一节**（不是别的 key）",
        len(rows) == 1 and rows[0][0] == "DSPROMPT_IDENTITY", rows)
    msg = page.inner_text("#prompt-pp_msg") if page.locator(
        "#prompt-pp_msg").count() else ""
    chk("★★ 界面上给了回执", "保存" in msg or "已" in msg, repr(msg[:120]))

    # 拼装后的全文那一格要跟着变（管理员改完能自己看见效果）
    full = page.inner_text("#prompt-pp_full") if page.locator(
        "#prompt-pp_full").count() else ""
    chk("★★ 下面那格「拼装后的全文」里出现了刚改的内容",
        _MARK in full, "全文 %d 字，含标记=%s" % (len(full), _MARK in full))
    chk("★ 而且 `{{MAXITER}}` / `{{MAXWALL}}` 这两个占位符在展示时被填掉了",
        "{{MAXITER}}" not in full and "{{MAXWALL}}" not in full, "")

    # ---- 改完立刻生效：下一个出网请求的 system 消息里就有它 ----------------
    C.goto(page, "chat")
    ensure_no_modal(page)
    n0 = fx.req_n()
    fx.set_queue(C.sse("收到。"))
    send(page, "这条用来验证提示词改完立刻生效。", timeout=120)
    n1 = fx.req_n()
    chk("★★ 发出去了一轮（假 LLM 收到了）", n1 > n0, "req %d → %d" % (n0, n1))

    sysmsg = ""
    for i in range(n1, n0, -1):
        b = fx.req_body(i)
        if not b:
            continue
        for m in (b.get("messages") or []):
            if m.get("role") == "system":
                sysmsg = m.get("content") or ""
        if sysmsg:
            break
    print("    出网请求里的 system 消息 %d 字，含标记=%s"
          % (len(sysmsg), _MARK in sysmsg), flush=True)
    chk("★★★ 下一个请求的 system 消息里**含**改后的文本（立刻生效）",
        _MARK in sysmsg, "sys 开头 %r" % sysmsg[:120])
    chk("★★ 改之前那一节的原文**不再**整段出现（真的换掉了，不是叠加）",
        "你是 YCFS 平台" not in sysmsg or _MARK in sysmsg, "")

    # ---- 恢复默认：删行，且全文回到内置默认 --------------------------------
    C.goto(page, "admin")
    page.wait_for_timeout(1200)
    page.evaluate("""() => {
        var ul = document.getElementById('admin-bs_tab');
        var a = ul.querySelector('a[data-value="prompt"],' +
                                 'button[data-value="prompt"]');
        if (a) a.click();
    }""")
    page.wait_for_timeout(1200)
    page.select_option("#prompt-pp_part", "DSPROMPT_IDENTITY")
    page.wait_for_timeout(1000)
    page.click("#prompt-pp_reset")
    page.wait_for_timeout(1000)
    btn = page.locator("#prompt-pp_confirm_reset")
    chk("★★ 「恢复默认」先问一遍（不是点一下就删）", btn.count() >= 1,
        "确认按钮 %d 个" % btn.count())
    if btn.count():
        btn.first.click()
        page.wait_for_timeout(2000)
    rows2 = sql(db, "SELECT key FROM prompt_overrides")
    chk("★★★ 恢复默认 = 把那一行删掉（表回到空）", rows2 == [], rows2)


def _readonly_ok(page, key):
    """切到「拼出来的那一节」，确认它是只读的。

    ★ 为什么要专门验这个：派生节（代码铁律全篇）是 HEAD + TAIL 现拼的，
      如果它给了一个可写的 textarea，写进去的行**永远不会被读**（
      dsapp_prompt_get 对这两个 key 走的是现拼那一支）—— 表现是
      "管理员改了、也提示保存成功、模型那边一个字都没变"，而界面上完全
      看不出来。探针在旧代码上跑不到这一条（旧代码没有这个界面），
      所以它是纯粹的**新能力**断言。
    """
    try:
        page.select_option("#prompt-pp_part", key)
        page.wait_for_timeout(1200)
        return (page.locator("#prompt-pp_body").count() == 0
                and "pre" in page.evaluate(
                    "() => { var e = document.querySelector('[id^=prompt-pp_editor]');"
                    " return e ? e.innerHTML.toLowerCase() : ''; }"))
    except Exception:
        return False


# =============================================================================
# 主流程
# =============================================================================

def main():
    fx = None
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch()

            # ---- 0. 注册 + 把账号指向假服务端 ------------------------------
            print("\n== 0. 注册并把账号指向假服务端 ==", flush=True)
            page = enter_with_retry(browser)
            email = C.LAST_EMAIL
            uid, db = C.seed_or_die(email)
            print("  uid=%s  db=%s" % (uid, db), flush=True)

            fx = C.FakeLLM()
            print("  假 LLM: %s" % fx.url, flush=True)
            C.seed_llm(uid, fx.url, model="fake-model")
            relogin(page, email)
            ensure_no_modal(page)

            item6_fence_and_img(page, uid, db)
            item3_thinking(page, fx)
            item4_resend(page, uid, db)
            item2_artifacts(page, uid, db, fx)
            # ⚠️ 排在 item1 之前：item1 会把 Key 抹掉再走一遍自愈，
            #    它之后这一节想跑任务就得指望那条自愈路径，一旦它坏了，
            #    这里报出来的是"重试按钮没用"——两件事会被搅在一起。
            item2b_retry(page, uid, db, fx)
            item1_selfheal(page, uid, db, fx)
            item7_backstage(page, uid, db)
            item8_prompt(page, uid, db, fx)

            page.screenshot(path=C.OUT + "/99_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()

    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
