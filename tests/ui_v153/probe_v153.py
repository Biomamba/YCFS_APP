# -*- coding: utf-8 -*-
"""Test_V15.3 六条改动的浏览器探针。

    python3 tests/ui_v153/probe_v153.py

前置：实例已经起来（见 README.md 里那条 make_instance.sh）。

★ 这个探针和 ui_v152 那批最大的不同：**它会自己拉一个假 LLM 起来**，
  并且把刚注册的那个账号的设置 + 钥匙串都指向那个假服务端。
  理由是 V15.3 有三条改动（思考往外流、md 图片、400 一键修）**只有让对话
  真的跑起来才看得到** —— 只看 DOM 里有没有某个 class 是"去 selftest 里
  grep 关键字"的浏览器版，证明不了用户看得见（selftest-green-is-not-coverage
  已经栽过两次）。

⚠️⚠️ **一条出网请求都不许打到真厂商。** 探针里有两道闸：
      ① seed_llm() 把 base_url 同时写进**设置行和钥匙串**，然后 reload
         页面让新会话从库里读回来；
      ② 每次发完消息断言 `fx.req_n() > 0` —— 假服务端真的收到了。
         真打到厂商的话它一个请求都收不到，这一条会**响**，而不是静默地
         花用户的钱（v153_maxtok_fix.R 就为这个白查了一轮：报出来的错是一句
         401，指向的是"Key 不对"，和真正的原因隔着十万八千里）。

六条改动 → 六组断言的对应关系见每一段的标题。
"""
import os
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
# 小工具
# =============================================================================

def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ★ 为什么探针中间要 reload：`state$base_url / model` 是**会话级**的，在
      mod_model 的 observe 里从库里读一次。种子是在注册之后才写进库的，
      所以那个已经活着的会话手里还是老值（空 base_url → 厂商默认地址 →
      **真厂商**）。reload = 新开一个 Shiny session，它会把种子读回来。
      这是"让配置真的生效"最短的一条路，而且走的是用户自己也会走的动作。

    正常情况 cookie 会自动登录；cookie 这条路过不去（被清、或者换了
    sessionStorage）时才走一遍登录表单。
    """
    page.reload(wait_until="domcontentloaded")

    # ⚠️⚠️ 这里**不能**用 wait_awake()。它只认 `.dsapp-auth`，而 reload 时
    #    cookie 还在 —— 应用会**直接进主界面**，登录页一帧都不出现。
    #    拿 wait_awake 等它等于等一个永远不会来的东西：报出来的是
    #    「reload 之后 120 秒还是空白页」，而屏幕上其实早就是主界面了。
    #    （2026-09-28 为这个白查了一轮 —— 症状指向"服务端卡死"，
    #      实际是**等错了东西**。和 fake-wait-is-not-a-wait 同一个病。）
    #    所以这里等的是"两个可能里先到的那个"：主界面，或者登录表单。
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
      —— 那样会把自己想测的东西一起关掉（技能查看那一段就开着弹窗）。
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
    """服务端说"这一轮还在跑"。见 mod_chat.R 那条 dsapp:busy —— 它把
    `btn.disabled = busy || lock` 写成**真的 disabled 属性**，所以这是
    服务端的判断，不是前端猜的。"""
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(page, timeout=90):
    """等到这一轮真的结束。**不是**"等某个元素出现" —— 那种提前返回的写法
    会让后面的动作和服务端重画抢跑，报出来的错指向完全无关的地方
    （fake-wait-is-not-a-wait）。"""
    end = time.time() + timeout
    # 先等它**忙起来**：点完发送之后服务端要跑一趟才置灰，立刻查的话
    # 十有八九还是"不忙"，于是这个函数等于什么都没等。
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


def ws_dirs():
    """数据目录底下所有的对话工作区，按修改时间从新到旧。"""
    root = os.path.join(C.DATA_ROOT, "workspaces")
    if not os.path.isdir(root):
        return []
    out = []
    for d in os.listdir(root):
        p = os.path.join(root, d)
        if os.path.isdir(p):
            out.append((os.path.getmtime(p), p))
    out.sort(reverse=True)
    return [p for _t, p in out]


def newest_ws(uid):
    """这个账号最新那个对话的工作区目录名（**算出来**，不是找出来的）。

    ⚠️⚠️ 不能"在 workspaces/ 底下挑一个最新目录"：发一条消息**不会**建工作区
      —— `dsapp_ws_dir(create = TRUE)` 只在跑任务（executor.R）或传文件
      （files.R）时才走到。只发消息的话 workspaces/ 是**空的**，于是探针报
      "第一条消息没建出会话"，而会话其实建得好好的（sessions 表里有）。
      目录名也不是随便起的：`dsapp_ws_name(sid)` = `"chat-" + gsub(非
      [A-Za-z0-9._-], "_", sid)`。所以这里照那个规则算，再自己建出来 ——
      和被测代码用的是同一条规则（utils.R 的 dsapp_ws_name）。
    """
    rows = sql(db_path_or_die(), "SELECT id FROM sessions WHERE user_id = ?"
               " ORDER BY rowid DESC LIMIT 1", (uid,))
    if not rows:
        sys.exit("sessions 表里没有 uid=%s 的会话 —— 第一条消息真的发出去了吗？" % uid)
    import re
    sid = rows[0][0]
    name = "chat-" + re.sub(r"[^A-Za-z0-9._-]", "_", sid)
    d = os.path.join(C.DATA_ROOT, "workspaces", name)
    os.makedirs(d, exist_ok=True)
    print("  会话 %s → 工作区 %s" % (sid, d), flush=True)
    return d


def db_path_or_die():
    p = C.db_path()
    if p is None:
        sys.exit("拒绝继续：%s 底下找不到 .sqlite3。" % C.DATA_ROOT)
    return p


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


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def add_skill(db, uid, name, summary, body):
    """往技能库里塞一条，给 item 5（技能查看）当素材。

    ★ 用直接写库而不是走「技能」页的界面：这一条**是夹具，不是被测对象**。
      被测的是"点『查看』之后弹窗里出不出现渲染后的正文"，走五步界面去建
      一条技能只会让探针更脆，不会让它更有说服力。
      写库用的是真表真列（skills 的 DDL 见 R/db.R），不是另造一份。
    """
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute(
            "INSERT INTO skills (user_id, name, summary, body, tags, builtin,"
            " source, scope, created_at, updated_at)"
            " VALUES (?,?,?,?,?,'','custom','private',"
            " datetime('now'), datetime('now'))",
            (uid, name, summary, body, "v153,测试"))
        con.commit()
        rid = con.execute("SELECT id FROM skills WHERE user_id=? AND name=?",
                          (uid, name)).fetchone()
    finally:
        con.close()
    return rid[0] if rid else None


# =============================================================================
# 主流程
# =============================================================================

def enter_with_retry(browser):
    """注册进主界面，最多试 3 次。

    ⚠️ 为什么要重试：这两个测试实例（8918/8922/8923）上，`enter_app` 偶尔会在
       「注册完之后页面空白」那一关失败，而这**不是本版的回归** —— 2026-09-28
       拿 V15.2 那个实例（ui_v152/_common.py，一个字节没改）做对照，同样失败
       （8 秒就返回「注册没进主界面（页面文字 0 字）」）。也就是说它和 V15.3 的
       六条改动无关，是这几个开了一整天的实例自身的老毛病。
       每一次 `enter_app` 都注册一个新账号，所以重试是安全的（不会撞邮箱）。
    """
    last = None
    for i in range(3):
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        try:
            C.enter_app(page, email="v153_%s_%d@example.com"
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
        with sync_playwright() as pw:
            browser = pw.chromium.launch()

            # ---- 0. 注册 + 把账号指向假服务端 ---------------------------------
            print("\n== 0. 注册并把账号指向假服务端 ==", flush=True)
            page = enter_with_retry(browser)
            # ⚠️ enter_with_retry 用的是**每次新建的**邮箱（重试要换一个），
            #    所以这里必须把"这一次真正注册的那个"问回来 —— 后面
            #    seed_or_die / relogin 都靠它。
            email = C.LAST_EMAIL
            uid, db = C.seed_or_die(email)
            print("  uid=%s  db=%s" % (uid, db), flush=True)

            fx = C.FakeLLM()
            print("  假 LLM: %s" % fx.url, flush=True)
            C.seed_llm(uid, fx.url, model="fake-model")
            relogin(page, email)
            # ⚠️ 新账号第一次开对话会弹「AI 怎么干活？」，盖住整页。
            #    不关掉的话后面第一次 `page.click("#chat-send")` 会以
            #    "intercepts pointer events" 超时 —— 报错指向发送按钮，
            #    和真正的原因隔着十万八千里。
            ensure_no_modal(page)

            # ---- 1. item 1：论坛左留白 ----------------------------------------
            item1_forum_padding(page)

            # ---- 2. item 6：md 渲染 + 图片 ------------------------------------
            item6_md_and_images(page, uid, db, fx)

            # ---- 3. item 3：思考往外流、不闪 ----------------------------------
            item3_thinking(page, fx)

            # ---- 4. item 4：三颗按钮只剩一处 ----------------------------------
            item4_buttons(page, fx)

            # ---- 5. item 2：400 → 一键修 --------------------------------------
            item2_maxtok_fix(page, db, uid, fx)

            # ---- 6. item 5：技能查看 ------------------------------------------
            item5_skill_peek(page, uid, db)

            page.screenshot(path=C.OUT + "/99_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()

    return chk.done()


# -----------------------------------------------------------------------------
# item 1：论坛界面的左留白
# -----------------------------------------------------------------------------
def _first_text_x(page, inner=None):
    """量**当前可见那一页**底下第一个"直接写着字"的元素的左边缘 x。

    ⚠️⚠️ 两个坑叠在一起，少一个都会量出看着完全合理的错数：
      · bslib 把**所有**页都留在 DOM 里、只藏不激活 ——
        `document.querySelector('.dsapp-page')` 拿到的是**第一页**（文献速递），
        而它的矩形是全 0。这正是 hidden-element-has-zero-rect 那个坑：
        差值算出来照样是个整数（0 − 0 = 0），不报错。
        所以这里先按 `offsetParent !== null` 筛出**真正可见的那一页**。
      · 只认"直接有文字"的元素（childNodes 里有非空文本节点），不认容器 ——
        容器量到的是外框，而用户看到的留白是**字**离屏幕左边多远。

    量不到就返回 `{err: ...}` 而不是 null：`null` 和"量到了 0"在下游长得
    一模一样，而这两种情况的处置完全不同。
    """
    return page.evaluate("""(inner) => {
        var pages = Array.prototype.filter.call(
            document.querySelectorAll('.dsapp-page'),
            function (e) { return e.offsetParent !== null; });
        if (!pages.length) return {err: '没有可见的 .dsapp-page（切页没切过去？）'};
        if (pages.length > 1) return {err: '同时有 ' + pages.length + ' 页可见'};
        var root = pages[0];
        if (inner) {
            root = root.querySelector(inner);
            if (!root) return {err: '可见的那一页里没有 ' + inner};
        }
        var all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
            var e = all[i];
            if (e.offsetParent === null) continue;
            var r = e.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) continue;
            var t = '';
            for (var j = 0; j < e.childNodes.length; j++) {
                if (e.childNodes[j].nodeType === 3) t += e.childNodes[j].nodeValue;
            }
            if (!t.trim()) continue;
            return {x: r.x, tag: e.tagName, cls: String(e.className).slice(0, 40),
                    text: t.trim().slice(0, 30)};
        }
        return {err: '这一页里找不到带直接文字的元素'};
    }""", inner)


def _show(tag, d):
    if d and "err" not in d:
        print("    %s x=%.1f <%s class=%r> %r"
              % (tag, d["x"], d["tag"], d["cls"], d["text"]), flush=True)
    else:
        print("    %s 量不到：%s" % (tag, (d or {}).get("err", "None")), flush=True)


def item1_forum_padding(page):
    print("\n== item 1：论坛页的左留白 ==", flush=True)

    C.goto(page, "forum")
    # ⚠️ 论坛页也是 renderUI 出来的，切过去之后要给它一拍。
    page.wait_for_timeout(1500)
    f = _first_text_x(page, None)
    _show("论坛", f)

    # 对照组：设置页有 card 外壳，Bootstrap .card-body 的 1rem 就是它的留白，
    # 那是**一直以来的样子**，论坛要跟它对齐。
    C.goto(page, "settings")
    page.wait_for_timeout(1500)
    s = _first_text_x(page, ".card-body")
    _show("设置", s)

    chk("★★ 论坛页量到了一个可见的文字元素（没量到的话下面全是空过）",
        f is not None and "err" not in f, f)
    chk("★★ 设置页 card-body 里也量到了（对照组，它是一直的基准）",
        s is not None and "err" not in s, s)

    if f and s and "err" not in f and "err" not in s:
        chk("★★★ 论坛页文字的左边缘和设置页 card-body 里的**对齐**（±2px）",
            abs(f["x"] - s["x"]) <= 2.0,
            "论坛 %.1f vs 设置 %.1f" % (f["x"], s["x"]))
        # ★ 只比"两边相等"是不够的：两边都是 0 也相等，而 0 正是改之前的样子。
        #   这条把"确实有留白"钉死。
        chk("★★ 而且论坛的留白是**真的存在**的（不是两边都顶到边沿）",
            f["x"] >= 8.0, "论坛 x=%.1f" % f["x"])

    # 结构哨兵：这个类是给"没有 card 外壳"的页面用的。
    #   ⚠️ 数 `.dsapp-page-flush` 要连隐藏页一起数（类名是渲染时写死的），
    #      但**可见**的必须恰好一个 —— 两个都亮着说明有页面没藏干净，
    #      那时候上面量到的 x 也就不作数了。
    flush = page.locator(".dsapp-page-flush").count()
    chk("★★ 论坛页挂着 .dsapp-page-flush", flush == 1, "count=%d" % flush)


# -----------------------------------------------------------------------------
# item 6：md 渲染（HTML 标签 + 图片）
# -----------------------------------------------------------------------------
def item6_md_and_images(page, uid, db, fx):
    print("\n== item 6：md 渲染 + 图片 ==", flush=True)

    C.goto(page, "chat")
    fx.no_slow()
    fx.set_queue(C.sse("好，我看到了。"))
    if not send(page, "第一条：把对话建出来"):
        sys.exit("第一句话没发完 —— 实例日志见 %s/app.log" % C.APP)
    chk("★★ 第 1 次请求打在**假服务端**上（不是真厂商）", fx.req_n() >= 1,
        "假服务端收到 %d 次" % fx.req_n())
    if fx.req_n() == 0:
        sys.exit("假服务端一个请求都没收到 —— 这个账号多半还指着真厂商，"
                 "停下来别再往下跑（后面的消息会花用户的钱）。")

    ws = newest_ws(uid)
    print("  工作区 %s" % ws, flush=True)
    img = tiny_png(os.path.join(ws, "figures", "v153.png"))
    print("  真 PNG %s（%d 字节）" % (img, os.path.getsize(img)), flush=True)

    # 一条消息里同时放三样：白名单标签、工作区里的真图、以及一个越界的图。
    #   ① `<h4>`  —— 用户报的「HTML 标签变字面文字」
    #   ② figures/v153.png —— 用户报的「图片不显示」
    #   ③ ../../etc/passwd —— **模型输出是不可信输入**，这条必须进不去
    fx.set_queue(C.sse("收到。"))
    body = ("<h4>V153标题</h4>\n\n"
            "上面是四级标题。\n\n"
            "![工作区里的图](figures/v153.png)\n\n"
            "![越界的图](../../etc/passwd)\n")
    if not send(page, body):
        sys.exit("第二条没发完")

    # ★ 断言前先等正文真的画出来。**别拿"等一行出现"当等**（fake-wait-is-not-a-wait），
    #   这里等的是"用户那条气泡里的字出现了"，而它就是被断言的那个东西，
    #   没有提前返回的空间：等不到就是失败。
    try:
        page.wait_for_selector(".dsapp-msg-user h4", timeout=20000)
        got_h4 = True
    except Exception:
        got_h4 = False

    h4 = page.evaluate("""() => {
        var e = document.querySelector('.dsapp-msg-user h4');
        return e ? e.textContent.trim() : null;
    }""")
    chk("★★★ `<h4>` 真的变成了 DOM 里的 <h4> 元素（不是一行字面文字）",
        got_h4 and h4 == "V153标题", "h4=%r" % h4)

    # ★ 反面：`&lt;h4&gt;` 那种字面文字还在不在？在的话说明白名单没生效。
    lit = page.evaluate("""() => {
        var e = document.querySelector('.dsapp-msg-user');
        return e ? (e.innerText || '').indexOf('<h4>') >= 0 : false;
    }""")
    chk("★★ 而且同一段文字里**没有**残留的 `<h4>` 字面量", not lit)

    # ---- 图片：判据是 naturalWidth > 0 --------------------------------
    imgs = page.evaluate("""() => {
        var out = [];
        document.querySelectorAll('.dsapp-msg-user img').forEach(function (e) {
            out.push({src: e.getAttribute('src') || '',
                      nw: e.naturalWidth, nh: e.naturalHeight,
                      vis: e.offsetParent !== null});
        });
        return out;
    }""")
    for i, im in enumerate(imgs):
        print("    img[%d] src=%r natural=%dx%d" % (i, im["src"][:90],
                                                    im["nw"], im["nh"]), flush=True)

    good = [i for i in imgs if i["nw"] > 0 and i["nh"] > 0]
    chk("★★★ 工作区里那张图**真的解码出来了**（naturalWidth > 0）",
        len(good) >= 1, "img 总数 %d，解出来的 %d" % (len(imgs), len(good)))
    chk("★★ 而且它的 src 是会话私有的 dataobj 地址（不是原样的相对路径）",
        any("dataobj" in i["src"] for i in good),
        [i["src"][:60] for i in imgs])

    # ---- 安全：越界的那张必须进不去 -----------------------------------
    leak = [i for i in imgs if "passwd" in i["src"] or "etc" in i["src"]]
    chk("★★★ `![](../../etc/passwd)` 没有变成一个指向它的 <img>（包含性校验生效）",
        len(leak) == 0, leak)
    # 反面再钉一次：整个文档里（不止用户气泡）都不许有这个地址。
    anywhere = page.evaluate("""() => {
        var n = 0;
        document.querySelectorAll('img').forEach(function (e) {
            var s = e.getAttribute('src') || '';
            if (s.indexOf('passwd') >= 0 || s.indexOf('/etc/') >= 0) n++;
        });
        return n;
    }""")
    chk("★★★ 整页也没有任何 <img> 指向 /etc/（安全那条不是靠漏渲染过去的）",
        anywhere == 0, "count=%d" % anywhere)


# -----------------------------------------------------------------------------
# item 3：思考过程往外流，而且不闪
# -----------------------------------------------------------------------------
_THINK_PROBE_JS = """() => {
    var el = document.querySelector('.dsapp-think-pre');
    if (!el) return null;
    /* ★ 指纹：第一次见到这个节点时给它盖一个一次性记号。
       节点被换掉的话，新节点上没有这个记号，会被当成另一个 uuid ——
       这正是"闪"的定义（用户在读的那块 DOM 被整块换掉）。 */
    if (!el.dataset.v153u) {
        el.dataset.v153u = 'u' + Math.random().toString(36).slice(2);
    }
    var d = el.closest('.dsapp-think-d');
    return {u: el.dataset.v153u,
            n: (el.textContent || '').length,
            open: d ? d.hasAttribute('open') : null};
}"""


def item3_thinking(page, fx):
    print("\n== item 3：思考过程往外流、不闪 ==", flush=True)

    C.goto(page, "chat")
    # 三个理由都要慢放：
    #   · 整段在一个 200ms 轮询周期内吐完的话，指纹**一次都采不到**，
    #     "uuid 全程不变"会因为没采样而通过（假绿）；
    #   · 思维链要分段，才看得出"字在往外长"；
    #   · 用户报的闪烁本来就是"长期生成时"才有。
    fx.slow(0.35)
    parts = ["先看用户给了什么。", "这一步要确认物种和注释版本。",
             "然后决定是走比对还是走定量。", "定量的话得先有 count 矩阵。",
             "最后把步骤写成代码。", "检查一遍依赖装没装。"]
    fx.set_queue(C.sse_multi(parts, "好，我按这个思路来。"))

    # 统计 thinking_box 这一格被**服务端标记失效**了几次。
    #   ⚠️ 光看这个数会虚高（写 reactiveVal 就算值没变也失效下游），
    #      所以它只当**上界**用，真正的判据是上面的节点指纹。
    #      measure-refresh-by-fingerprint 的教训。
    page.evaluate("""() => {
        window.__v153inv = 0;
        if (window.__v153hooked) return;
        window.__v153hooked = true;
        $(document).on('shiny:outputinvalidated', function (e) {
            if (e && e.name && String(e.name).indexOf('thinking_box') >= 0)
                window.__v153inv++;
        });
    }""")

    page.fill("#chat-input", "想一个分析方案")
    page.click("#chat-send")

    samples = []
    t0 = time.time()
    while time.time() - t0 < 60:
        v = page.evaluate(_THINK_PROBE_JS)
        if v:
            samples.append(v)
        if samples and not busy(page):
            break
        page.wait_for_timeout(180)

    page.wait_for_timeout(400)
    inv = page.evaluate("() => window.__v153inv")

    uu = [s["u"] for s in samples]
    ns = [s["n"] for s in samples]
    print("    采样 %d 次，uuid %d 种，字数 %s" %
          (len(samples), len(set(uu)), ns), flush=True)
    print("    thinking_box 失效 %s 次" % inv, flush=True)

    chk("★★ 采到了思考过程的骨架（没采到的话下面几条全是空过）",
        len(samples) >= 3, "样本 %d" % len(samples))
    if len(samples) >= 3:
        chk("★★★ 全程**只有一个节点** —— 用户在读的那块 DOM 没被换掉",
            len(set(uu)) == 1, "uuids=%s" % sorted(set(uu)))
        chk("★★★ 字数一路只增不减（是往外贴，不是整块重画）",
            all(ns[i] <= ns[i + 1] for i in range(len(ns) - 1)), ns)
        chk("★★ 而且生成期间**真的在长**（至少跨了两个不同的字数）",
            len(set(ns)) >= 2, ns)
        chk("★★ 最后贴出来的字数和思维链对得上",
            max(ns) == sum(len(p) for p in parts),
            "贴出 %d，应该是 %d" % (max(ns), sum(len(p) for p in parts)))
        chk("★ 思考那块是**默认展开**的（用户要的就是看得见它往外走）",
            all(s["open"] for s in samples if s["open"] is not None))

    chk("★★★ thinking_box 没有被反复重画（一次生成 ≤ 6 次失效）",
        inv is not None and inv <= 6, "失效 %s 次" % inv)

    fx.no_slow()
    wait_idle(page, 60)


# -----------------------------------------------------------------------------
# item 4：三颗按钮只剩一处
# -----------------------------------------------------------------------------
_BTN_JS = """() => {
    var vis = function (e) {
        if (e.offsetParent === null) return false;
        var r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    };
    var all = function (sel) {
        var n = 0;
        document.querySelectorAll(sel).forEach(function (e) { if (vis(e)) n++; });
        return n;
    };
    return {
        output_bar: document.querySelectorAll('.dsapp-output-bar').length,
        stop: all('.dsapp-btn-stop'),
        stop_ids: all('[id$="-stop"]'),
        actions: all('.dsapp-actions'),
        confirm: all('.dsapp-actions .dsapp-code-run, .dsapp-actions .dsapp-ask-go'),
        suggest: all('.dsapp-actions .dsapp-btn-suggest'),
        old: document.querySelectorAll('[id$="-stop_task"], [id$="-stop_detach"]').length
    };
}"""


def _btn_report(page, label):
    st = page.evaluate(_BTN_JS)
    print("    [%s] actions=%d stop=%d confirm=%d suggest=%d output_bar=%d"
          % (label, st["actions"], st["stop"], st["confirm"],
             st["suggest"], st["output_bar"]), flush=True)
    return st


def item4_buttons(page, fx):
    print("\n== item 4：三颗按钮挪进会话里 ==", flush=True)

    C.goto(page, "chat")
    page.wait_for_timeout(1000)

    # ---- 静态那一半 -------------------------------------------------------
    n = page.locator(".dsapp-output-bar").count()
    chk("★★★ 那条钉在输出框下沿的 .dsapp-output-bar 已经不存在了", n == 0,
        "count=%d" % n)
    old = page.evaluate("""() => document.querySelectorAll(
        '[id$="-stop_task"], [id$="-stop_detach"]').length""")
    chk("★★★ 第二、第三颗停止按钮（stop_task / stop_detach）也没了", old == 0,
        "count=%d" % old)

    # ---- 空闲态：一颗都不该亮 --------------------------------------------
    wait_idle(page, 30)
    st = _btn_report(page, "空闲")
    chk("★★ 空闲时没有任何动作条露在外面（历史和实时卡片都不该有）",
        st["actions"] == 0, st)

    # ---- 生成中：只有一处、只有一颗停止 ----------------------------------
    fx.set_queue(C.sse("好。"))
    page.fill("#chat-input", "再随便说一句")
    page.click("#chat-send")
    seen = []
    t0 = time.time()
    while time.time() - t0 < 40:
        if busy(page):
            seen.append(page.evaluate(_BTN_JS))
        else:
            if seen:
                break
        page.wait_for_timeout(120)
    chk("★★ 生成期间采到了状态（没采到的话下面几条是空过）", len(seen) >= 1,
        "样本 %d" % len(seen))
    if seen:
        print("    [生成中] actions=%d stop=%d" % (seen[-1]["actions"],
                                                  seen[-1]["stop"]), flush=True)
        # ⚠️ 判据是「**任何时候都不许超过一颗**」，不是「每一拍都必须有一颗」。
        #    点击那一刻 app.js 会**乐观地**先把发送按钮置灰，而动作条要等服务端
        #    真的渲染出那条流式气泡（dsapp_chat_send 里查库+拼上下文+起 callr
        #    子进程，几百毫秒）。这一段里 busy 已经是 TRUE 而气泡还没画出来 ——
        #    那是**渲染延迟**，不是"按钮重复"。写成 ==1 的话量到的是这段延迟，
        #    报出来的失败指向"停止按钮重复"，和真正的原因隔着十万八千里。
        #    真正要钉死的是"重复"：任何一拍出现 2 就是回归。
        chk("★★★ 生成期间可见的停止按钮**从不超过一颗**",
            all(s["stop"] <= 1 for s in seen),
            [s["stop"] for s in seen])
        chk("★★★ 生成期间可见的动作条**从不超过一处**（两处就是「重复」回来了）",
            all(s["actions"] <= 1 for s in seen),
            [s["actions"] for s in seen])
        chk("★★ 而且它**真的出现过**（否则上面两条会「因为一次都没采到」空过）",
            any(s["stop"] == 1 for s in seen),
            [s["stop"] for s in seen])
        n_zero = sum(1 for s in seen if s["actions"] == 0)
        print("    [生成中] %d/%d 拍处在「点了还没渲染出来」的窗口里"
              % (n_zero, len(seen)), flush=True)
        chk("★ 任何一拍都没有 .dsapp-output-bar",
            all(s["output_bar"] == 0 for s in seen))
    wait_idle(page, 60)

    # ---- 每一拍都不许出现两颗 --------------------------------------------
    st2 = _btn_report(page, "生成后")
    chk("★★ 生成结束后可见的停止按钮 ≤ 1", st2["stop"] <= 1, st2)
    chk("★★ `[id$=-stop]` 这种「凡是叫 stop 的都算」的数法也 ≤ 1",
        st2["stop_ids"] <= 1, st2)


# -----------------------------------------------------------------------------
# item 2：HTTP 400 → 「直接帮我设置」
# -----------------------------------------------------------------------------
def item2_maxtok_fix(page, db, uid, fx):
    print("\n== item 2：400 报错上的「直接帮我设置」==", flush=True)

    # 假服务端给的上限。**故意不用 65536** —— 那是应用自己的默认上限，
    # 用它的话"解析出来的数 == 服务端说的数"这句在解析器退化成"返回默认值"
    # 时**照样通过**（v153_maxtok_fix.R 里踩过这个假绿）。
    #
    # ★★ 而且每次跑都换一个**没被用过**的数。理由不是好看：
    #    `model_param_limits` 是**按 (厂商,模型,参数) 全局**存的，没有 user_id
    #    —— 上一轮跑出来的那一行会原样留在库里。固定用 24576 的话，
    #    "点完之后库里有一行 24576"在**这一次点按钮根本没生效**时也成立
    #    （上一轮留下的），而且 R worker 没换代的话进程内存里也还留着它。
    #    换一个新数，这两条路一起堵死。
    used = {int(r[0]) for r in sql(
        db, "SELECT DISTINCT max_value FROM model_param_limits"
            " WHERE param = 'max_tokens'")}
    srv_max = next((v for v in range(20005, 30000) if v not in used), None)
    if srv_max is None:
        sys.exit("model_param_limits 里 20005~29999 都被用过了 —— 换个范围再跑")
    srv_max_s = format(srv_max, ",")
    print("    这一轮用的上限 = %d（库里没用过的）" % srv_max, flush=True)

    C.goto(page, "chat")
    fx.disarm_400()
    fx.set_queue(C.sse("这条不会被执行到。"))
    fx.arm_400("Field 'max_tokens' must be at most %d" % srv_max, times=1)

    page.fill("#chat-input", "这条会被 400 拒掉")
    page.click("#chat-send")
    wait_idle(page, 60)

    chk("★★ 假服务端收到了这次请求（证明错误是本地的假服务端给的）",
        fx.req_n() >= 1, "req=%d" % fx.req_n())

    # ---- 错误气泡 + 按钮 --------------------------------------------------
    try:
        page.wait_for_selector(".dsapp-bubble-err", timeout=20000)
        has_err = True
    except Exception:
        has_err = False
    chk("★★★ 界面上真的出现了一条错误气泡", has_err)

    err_txt = page.evaluate("""() => {
        var e = document.querySelector('.dsapp-bubble-err');
        return e ? (e.innerText || '') : '';
    }""")
    print("    错误气泡：%r" % err_txt[:160], flush=True)
    chk("★★ 气泡里就是假的 400 原文（不是一句笼统的「出错了」）",
        ("max_tokens" in err_txt) and (srv_max_s in err_txt
                                       or str(srv_max) in err_txt), err_txt[:120])

    btn = page.locator("#chat-maxtok_fix")
    chk("★★★ 错误气泡上亮出了「直接帮我设置」按钮", btn.count() == 1,
        "count=%d" % btn.count())
    chk("★★ 按钮是**可见**的（不是渲染出来藏在哪儿）",
        btn.count() == 1 and btn.first.is_visible())
    if btn.count() != 1:
        chk("按钮不在，后面的「点下去会怎样」全部跳过", False)
        return

    label = btn.first.inner_text()
    chk("★ 按钮文案就是用户要的那句「直接帮我设置」", "直接帮我设置" in label, label)

    # ---- 点下去 -----------------------------------------------------------
    # ⚠️ max_tokens **不在库里**（users 表里没有这一列，它是会话级的 Shiny
    #    input）。一开始照着"配置应该是持久化的"想当然去读 users.max_tokens，
    #    报出来的是 `no such column` —— 那是探针自己的错，不是被测代码的。
    #    "记下来了"只有 model_param_limits 那一行；"应用上了"只有出网请求体。
    pre = sql(db, "SELECT count(*) FROM model_param_limits"
                  " WHERE param = 'max_tokens' AND max_value = ?", (srv_max,))
    chk("★★ 点之前库里没有这个上限（否则下面那条会拿上一轮的记录冒充这一轮）",
        pre[0][0] == 0, pre)

    btn.first.click()
    page.wait_for_timeout(5000)

    # ⚠️ 查询条件里**不能写 model='fake-model'**：种进去的模型名会被应用换成
    #    厂商下拉里那个（`dsapp_vendor_models()` 拿不到 /models 列表时退回
    #    fallback_models，`fake-model` 不在里面）—— 实测库里记的是
    #    `deepseek-flash`。探针照着"我种了什么"去查，报出来的是一条
    #    "库里没有那一行"，而那一行其实好好地在，只是键不一样。
    #    所以这里按**值**查（每轮一个没用过的数，见上面），模型名留给下面
    #    和"出网请求里那个名字"对一次 —— 那才是真正要一致的东西。
    row = sql(db, "SELECT vendor, model, param, max_value, source"
                  " FROM model_param_limits"
                  " WHERE param = 'max_tokens' AND max_value = ?", (srv_max,))
    print("    库里那一行 = %s" % (row,), flush=True)
    chk("★★★ 库里真的多了一行「学到的上限」，值就是假服务端说的那个数",
        len(row) == 1 and int(row[0][3]) == srv_max, row)
    chk("★★ 那一行的来源标着 provider_400（是谁教会的，写清楚了）",
        len(row) == 1 and row[0][4] == "provider_400", row)

    # ---- 用户看得见的那一半：模型服务页的「单次回复上限」跟着变了 ----------
    # 用户原话是「自动更改**并应用**新的模型服务配置」。库里那一行只证明
    # "记下来了"，出网请求体只证明"这一次按它发了" —— 用户还要求**配置本身**
    # 被改掉，那一页上的数字就是他自己会去核对的地方。
    C.goto(page, "model")
    # ⚠️ id 是 `model-max_tokens`，不是 `max_tokens` —— 这个模块的命名空间是
    #    "model"（app.R 的 mod_model_ui("model")）。写成 `#max_tokens` 的话
    #    count 永远是 0，而报出来的是"控件读不到"，看着像"配置没应用上"。
    #    控件是渲染出来的，要先等它出现（ui_v1314 那条探针等的就是它）。
    try:
        page.wait_for_selector("#model-max_tokens", timeout=20000)
    except Exception:
        pass
    box = page.locator("#model-max_tokens")
    if box.count() == 0:
        chk("★★ 模型服务页的「单次回复上限」控件能读到（读不到就没法核对）",
            False, "count=0")
    else:
        shown = box.first.input_value()
        cap = box.first.get_attribute("max")
        print("    模型服务页 max_tokens 框 = %r（max 属性 %r）" % (shown, cap),
              flush=True)
        chk("★★★ 模型服务页的「单次回复上限」已经被改成厂商说的那个数",
            str(shown).strip() not in ("", "NA") and
            int(float(shown)) == srv_max, "shown=%r" % shown)
        chk("★★ 而且那个框的硬量程也收到了 %d（不是只有数字变了）"
            % srv_max,
            cap is not None and int(float(cap)) == srv_max, "max=%r" % cap)
    C.goto(page, "chat")
    page.wait_for_timeout(1200)

    # ★★ 这一步才是用户真正要的：「自动更改**并应用**新的模型服务配置」。
    #    库里有那一行只证明"记下来了"，不证明"下一次请求按它发"。
    #    判据只能看出网请求的**请求体**。
    fx.disarm_400()
    fx.set_queue(C.sse("这次通了。"))
    n_before = fx.req_n()
    page.fill("#chat-input", "再试一次")
    page.click("#chat-send")
    ok = wait_idle(page, 60)
    chk("★★ 重发没有再报错", ok)
    chk("★★ 重发确实又打在了假服务端上", fx.req_n() > n_before,
        "req %d → %d" % (n_before, fx.req_n()))

    b = fx.req_body(fx.req_n())
    mt = None
    if isinstance(b, dict):
        mt = b.get("max_tokens")
    print("    最后一次出网请求 max_tokens = %s" % mt, flush=True)
    chk("★★★ 出网请求带的是**学到的那个上限** —— 配置真的应用到请求上了",
        mt is not None and int(mt) == srv_max, "max_tokens=%s" % mt)

    # ★ 上限记在**哪个模型名下**：记错名字 = 下一次换个模型照样 400，而库里
    #   看着"有记录"。判据只能是"出网请求里那个模型名" —— 那才是真正被调用的
    #   那个东西，不是探针自己种进去的名字。
    wire_model = b.get("model") if isinstance(b, dict) else None
    print("    出网请求 model=%r；库里记在 model=%r"
          % (wire_model, row[0][1] if row else None), flush=True)
    chk("★★★ 学到的那一行记在**出网请求里那个模型名**底下",
        len(row) == 1 and wire_model is not None and row[0][1] == wire_model,
        "库里=%s 出网=%s" % (row[0][1] if row else None, wire_model))

    err_again = page.locator(".dsapp-bubble-err").count()
    chk("★ 重发之后错误气泡收了（不是一直挂在那儿）", err_again == 0,
        "count=%d" % err_again)


def _sel_state(page):
    """弹窗里「查看」那一行、以及**整个弹窗**的勾选状态。

    ⚠️ 这一行整块是 `<label>`，浏览器点它里面任何地方都会**翻掉那个勾选框**
      —— 是 label 的默认激活行为，不是冒泡。所以「查看」必须
      preventDefault（光 stopPropagation 拦不住）。这条函数就是它的判据：
      点前点后逐字相同，才算"只看不改"。
    """
    return page.evaluate("""() => {
        var a = document.querySelector('.dsapp-skillpick .dsapp-skillpick-peek');
        var all = [].map.call(
            document.querySelectorAll('.dsapp-skillpick input[type=checkbox]'),
            function (e) { return (e.checked ? '1' : '0'); }).join('');
        if (!a) return {row: null, all: all, name: null};
        // 勾选框和「查看」同属一个 .form-check（shiny 的 checkboxGroupInput
        // 用 choiceNames 时，一行就是一个 .form-check）。就近往上找，
        // 找不到就退回父节点 —— 不写死层级，shiny 换版式也不会错行。
        var row = a.closest('.form-check') || a.closest('label') ||
                  a.parentElement;
        var cb = row ? row.querySelector('input[type=checkbox]') : null;
        return {row: cb ? !!cb.checked : null, all: all,
                name: row ? (row.innerText || '').replace(/\s+/g, ' ').slice(0, 40)
                          : null};
    }""")


# -----------------------------------------------------------------------------
# item 5：技能内容查看
# -----------------------------------------------------------------------------
def item5_skill_peek(page, uid, db):
    print("\n== item 5：技能的「查看」==", flush=True)

    body = ("# 差异表达流程\n\n"
            "## 步骤\n\n"
            "1. 先 `DESeq2::DESeqDataSetFromMatrix`\n"
            "2. 再做 `results()`\n\n"
            "**注意**：样本名要对齐。\n")
    add_skill(db, uid, "V153差异表达", "两组的差异表达流程", body)

    C.goto(page, "chat")
    page.wait_for_timeout(1500)

    pick = page.locator("#chat-skill_pick")
    if pick.count() == 0:
        # 还没有对话的时候这一格是「新建对话后可挂载」，没有按钮。
        fxless_newchat(page)
        pick = page.locator("#chat-skill_pick")
    chk("★★ 对话页上找得到「技能」那颗按钮（夹具前提）", pick.count() >= 1,
        "count=%d" % pick.count())
    if pick.count() == 0:
        chk("按钮不在，后面的查看断言全部跳过", False)
        return

    pick.first.click()
    page.wait_for_timeout(2500)

    rows = page.locator(".dsapp-skillpick .dsapp-skillpick-peek")
    chk("★★ 弹窗里每一行都有「查看」链接", rows.count() >= 1,
        "count=%d" % rows.count())
    if rows.count() == 0:
        chk("没有查看链接，后面的断言全部跳过", False)
        return

    # 勾选状态在点之前 / 之后各读一次。**这是这一条的核心反面断言** ——
    # 「查看」必须只看不改（V15.3 需求原话是"能对技能的内容进行查看"，
    # 不是"点一下就把它勾上"）。
    # ⚠️ 必须**按行**读，不能读弹窗里的第一个勾选框：技能是按名字排的，
    #    探针种进去的那条不一定在第一行。读错行的话，"点前 == 点后"在
    #    「点『查看』把**别的**那一行翻掉了」时**照样通过**（假绿）。
    #    连同"整个弹窗的勾选集合"一起读 —— 那条连"哪一行都不许动"都盖住了。
    before = _sel_state(page)
    # ★ 点之前正文那块**必须是不在的**。不先钉这一条的话，"点完之后正文
    #   在里面"这句在"它本来就一直在里面"时也会通过 —— 而那种情况下
    #   「查看」根本什么都没做。
    peek_before = page.locator(".dsapp-skillpeek-body").count()
    chk("★★ 点之前弹窗里没有技能正文（否则下面那条会假绿）",
        peek_before == 0, "count=%d" % peek_before)

    rows.first.click()
    page.wait_for_timeout(2500)

    after = _sel_state(page)
    print("    点前 %s\n    点后 %s" % (before, after), flush=True)
    chk("★★★ 点「查看」**没有**把那一行的勾选框翻掉（preventDefault 生效）",
        before.get("row") is not None and before.get("row") == after.get("row"),
        "行内勾选 点前=%s 点后=%s（行内是 %r）"
        % (before.get("row"), after.get("row"), before.get("name")))
    chk("★★★ 整个弹窗里**一个勾都没被顺手翻掉**（label 的默认激活行为被挡住了）",
        before.get("all") == after.get("all"),
        "点前=%s 点后=%s" % (before.get("all"), after.get("all")))

    # ---- 正文出来了没有 ---------------------------------------------------
    peek = page.evaluate("""() => {
        var box = document.querySelector('.dsapp-skillpeek-body');
        if (!box) return null;
        return {html: box.innerHTML || '',
                text: (box.innerText || ''),
                h: box.querySelectorAll('h1,h2,h3,h4').length,
                li: box.querySelectorAll('li').length,
                code: box.querySelectorAll('code').length,
                raw_hash: (box.innerText || '').indexOf('##') >= 0};
    }""")
    chk("★★★ 弹窗里出现了技能正文那一块", peek is not None)
    if peek:
        print("    正文 %d 字，标题 %d，列表项 %d"
              % (len(peek["text"]), peek["h"], peek["li"]), flush=True)
        chk("★★★ 显示的是**渲染后**的正文（有真标题元素、真列表项）",
            peek["h"] >= 1 and peek["li"] >= 2, peek and
            {k: peek[k] for k in ("h", "li", "code")})
        chk("★★ 而且看不到 Markdown 的字面记号（`#` / `**` 这些）",
            not peek["raw_hash"], "text=%r" % peek["text"][:80])
        chk("★ 正文里有技能名", "差异表达" in peek["text"] or "步骤" in peek["text"],
            peek["text"][:60])

    # ---- 收起 -------------------------------------------------------------
    close = page.locator(".dsapp-skillpeek-x")
    if close.count():
        close.first.click()
        page.wait_for_timeout(2000)
        gone = page.locator(".dsapp-skillpeek-body").count() == 0
        chk("★ 「收起」之后正文那块收掉了", gone,
            "count=%d" % page.locator(".dsapp-skillpeek-body").count())

    page.screenshot(path=C.OUT + "/10_skill_peek.png", full_page=True)
    # 关掉弹窗，别影响后面的断言
    page.keyboard.press("Escape")
    page.wait_for_timeout(800)


def fxless_newchat(page):
    """没有对话时技能那一格只是个提示。新建一个对话（点那颗按钮）。"""
    for sel in ("#chat-new", "#chat-new_chat", "#chat-do_new"):
        b = page.locator(sel)
        if b.count():
            b.first.click()
            page.wait_for_timeout(2500)
            return


if __name__ == "__main__":
    sys.exit(main())
