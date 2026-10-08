# -*- coding: utf-8 -*-
"""Test_V17.2 item 2：「往下拉，没有最新消息的刷新提示」。

用户原话：
    跳转到历史消息后，往下拉，没有最新消息的刷新提示。

说的是两件事，本探针分开量：

  · **用户在中间**（滚上去读几屏以前的输出）时，下面长出东西来，屏幕上
    一个字都不说 —— 他只会以为"模型没回"。屏幕上该有的那一格叫
    `.dsapp-newmsg`（「↓ 有新消息 / 回到最新」）。
  · **跳到历史消息**之后，顶上那条「你正在看较早的内容 · 后面还有 N 条
    更新的消息」（`.dsapp-hist-focus`）**必须钉在滚动容器顶上**。V17.2
    之前它写了 `position: sticky` 却写在里层 div 上，而 sticky 的偏移被
    限制在**包含块**里 —— 那个壳（uiOutput 渲染出来的 .shiny-html-output）
    高度恰好等于横条自己，于是横条一格都挪不动，跟着内容一起滚走。
    用户"往下拉"的过程里，那条提示就这么没了。

⚠️⚠️ 两条判据都必须**能自己证伪**，否则量了等于没量：

  · 「药丸出现了」不是判据 —— 静态 DOM 里它一直都在（`display:none`
    藏着的），只看"在不在"永远是绿的。所以每一处都同时量
    **可见性（display）+ 文案 + 阴性对照**（贴底时必须一个字都不提示）。
  · 「横条钉住了」也不是判据 —— 元素本来就在那儿。判据是**同一段滚动里
    两个元素位移的差**：横条几乎不动，而普通消息按滚动的像素数往上走。
    只量横条自己的绝对位置，写没写对 sticky 都是同一个数。

⚠️ 量几何前先确认两边都**看得见**：隐藏元素的矩形是全 0，拿它做减法得到的
   数看着完全合理（本仓踩过：143 = 按钮自己的 y）。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (APP, URL, OUT, Chk, enter_app, seed_or_die,  # noqa: E402
                     ensure_no_modal)

from playwright.sync_api import sync_playwright  # noqa: E402

MSG_N = 30            # 种多少条消息
# ⚠️⚠️ 每条必须**真的**写到 6000 字，不能只写"上限"。第一版写的是
#    `("……" * 40)[:4000]` —— 那个乘法只铺出 960 字，[:4000] 一点都没截到，
#    于是 30 条一共 2.9 万字 < 预算 5 万 ⇒ **窗口一条都不裁** ⇒ 目录里第一条
#    的锚点本来就在 DOM 里 ⇒ 点击只是就地滚过去，服务端根本没挪窗口 ⇒
#    「顶上那条横条」永远不出现。而症状看着像"sticky 没生效"。
#    判据：种完回读 `MAX(LENGTH(content))`，必须 > 预算/条数以上的量级。
MSG_LEN = 6000        # 每条多少字（预算 50000 字 ⇒ 窗口只装得下末尾 8 条）


# ---------------------------------------------------------------------------
# 种一份"长对话"：直接写库，不走界面
#
# ⚠️ 为什么不发消息让它自己长：那要配假 LLM、要等流式，而且窗口会一直贴在
#    **末尾** —— 本探针要的恰恰是"跳回中间"那个状态。写库是最短的路，
#    而且写进去的每一行都能回读确认。
# ---------------------------------------------------------------------------
def seed_long_session(uid, db, n=MSG_N, mlen=MSG_LEN):
    con = sqlite3.connect(db)
    sid = "s-%s-9901" % time.strftime("%Y%m%d%H%M%S")
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    # ⚠️ updated_at 必须是"最近"：应用打开时自动选中的是**最近更新**的那条
    #    对话。写成很早的时间，探针会在一个空对话里量滚动 —— 而症状是
    #    "这页根本滚不动"，看着像药丸没写出来。
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)", (sid, "长对话-探针", now, now, uid))
    rows = []
    for i in range(1, n + 1):
        role = "user" if i % 2 == 1 else "assistant"
        head = "第 %d 条（%s）" % (i, role)
        body = head + "。" + ("这是一段用来撑高度、把消息窗口挤出可见范围的话。" * 300)
        body = body[:mlen]
        rows.append((sid, role, body, now))
    con.executemany("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)", rows)
    con.commit()
    # 回读：写库不确认等于没写（本仓那条"每条写操作后面都要回库确认"）。
    got, mx, tot = con.execute(
        "SELECT COUNT(*), MAX(LENGTH(content)), SUM(LENGTH(content))"
        " FROM messages WHERE session_id=?", (sid,)).fetchone()
    first_id = con.execute("SELECT MIN(id) FROM messages WHERE session_id=?",
                           (sid,)).fetchone()[0]
    con.close()
    if got != n:
        sys.exit("种库失败：要 %d 条、库里 %d 条。" % (n, got))
    # ⚠️ 长度也要回读。写短了（见 MSG_LEN 上面那段）窗口就不会裁，
    #    后面的跳转测的就不是"服务端挪窗口"那条路 —— 而它会一路绿。
    if mx < 5000 or tot < 150000:
        sys.exit("种库失败：消息太短（最长 %d 字、合计 %d 字）—— 窗口不会被裁，"
                 "这一跑测不到该测的东西。" % (mx, tot))
    print("  种子：对话 %s · %d 条消息（首条 id=%s）" % (sid, got, first_id), flush=True)
    return sid, first_id


# ---------------------------------------------------------------------------
# 一次把该量的都量回来
#
# ⚠️ 分几次 evaluate 去量会有"两次之间 DOM 变了"的缝；而且判定要的是
#    **同一时刻**的几个数之间的关系（药丸在不在 + 可不可见 + 写的哪句 +
#    贴不贴底），分着量出来的数可能来自两个不同的状态。
# ---------------------------------------------------------------------------
METRICS = r"""
() => {
  var el = document.querySelector('.dsapp-chat-scroll');
  if (!el) return { err: 'no .dsapp-chat-scroll' };
  var pill = el.querySelector('.dsapp-newmsg');
  var box = el.getBoundingClientRect();
  var m = {
    top: el.scrollTop,
    sh: el.scrollHeight,
    ch: el.clientHeight,
    pinned: el.__dsappKeeper ? el.__dsappKeeper.isPinned() : null,
    hasKeeper: !!el.__dsappKeeper,
    boxTop: box.top,
    boxBottom: box.bottom,
    /* 药丸必须是容器的**最后一个**子元素：靠 sticky bottom:0 钉在下沿。
       塞在别处（比如 .dsapp-chat-col 里）就得靠绝对定位猜输入框高度。 */
    pillIsLast: !!pill && el.lastElementChild === pill,
    pill: !!pill
  };
  if (pill) {
    var cs = getComputedStyle(pill);
    var r = pill.getBoundingClientRect();
    m.pillDisp = cs.display;
    m.pillVisible = cs.display !== 'none' && r.height > 0 && r.width > 0;
    m.pillOn = pill.classList.contains('is-on');
    m.pillNew = pill.classList.contains('is-new');
    m.pillBox = { top: r.top, bottom: r.bottom, h: r.height, w: r.width };
    /* innerText 只算**可见**的那一句 —— 两句文案是同时画进 DOM 的，
       由 CSS 按 is-new 挑一条（前端不许改文本，见 app.js 里那段）。 */
    m.pillText = (pill.innerText || '').replace(/\s+/g, ' ').trim();
    m.pillRaw = (pill.textContent || '').replace(/\s+/g, ' ').trim();
  }
  var hf = el.querySelector('.dsapp-hist-focus');
  var hh = el.querySelector('.dsapp-hist-focus-host');
  if (hf) {
    var hr = hf.getBoundingClientRect(), cs2 = getComputedStyle(hf);
    m.histText = (hf.innerText || '').replace(/\s+/g, ' ').trim();
    m.histBox = { top: hr.top, bottom: hr.bottom, h: hr.height, w: hr.width };
    m.histPos = cs2.position;
    m.histVisible = hr.height > 0 && hr.width > 0;
  }
  if (hh) {
    var wr = hh.getBoundingClientRect(), cs3 = getComputedStyle(hh);
    /* ⚠️ 壳（.shiny-html-output）是 display:contents ⇒ **不生成盒子**，
       几何恒为 0×0。这一条是前提断言：sticky 写在它上面是空转，而这正是
       横条当初粘不住的原因（见 www/app.css 那一节的三个实测数）。 */
    m.hostDisp = cs3.display;
    m.hostBox = { top: wr.top, h: wr.height };
  }
  return m;
}
"""


def metrics(page):
    m = page.evaluate(METRICS)
    if m.get("err"):
        sys.exit("量不到滚动容器：%s" % m["err"])
    return m


def scroll_to(page, where):
    """把滚动容器挪到顶/底。scrollIntoView / scrollTo 都会触发 scroll 事件，
    但它是**异步**投递的 —— 挪完立刻读，读到的还是上一拍。"""
    page.evaluate(
        "(w) => { var el = document.querySelector('.dsapp-chat-scroll');"
        " if (w === 'top') el.scrollTop = 0; else el.scrollTop = el.scrollHeight; }",
        where)
    page.wait_for_timeout(400)


def scroll_by(page, px):
    page.evaluate(
        "(d) => { var el = document.querySelector('.dsapp-chat-scroll');"
        " el.scrollTop = el.scrollTop + d; }", px)
    page.wait_for_timeout(400)


def grow(page, px=160):
    """在用户**下面**长出内容来。

    ⚠️ 长在消息那一格（`#chat-history`）里，不是随手往容器里塞一个 div：
    Shiny 增量更新就是这么干的（换掉那一格的 innerHTML），看护器的
    MutationObserver 盯的是 childList + subtree，两种写法都命中，但前一种
    和线上真实发生的形状一样 —— 免得"探针里能过、真跑起来不过"。

    找不到那一格就退回到"插在药丸前面"（同一个父节点、同一个位置关系）。
    """
    return page.evaluate(
        """(px) => {
             var el = document.querySelector('.dsapp-chat-scroll');
             var pill = el.querySelector('.dsapp-newmsg');
             var host = el.querySelector('[id$="-history"]');
             if (!host) host = el;
             var d = document.createElement('div');
             d.className = 'dsapp-probe-grown';
             d.style.height = px + 'px';
             d.textContent = '（探针塞进来的新内容）';
             if (pill && host === el) el.insertBefore(d, pill);
             else host.appendChild(d);
             return d.parentNode === el ? 'scroll' : 'history';
           }""", px)


def cleanup_grown(page):
    page.evaluate(
        "() => { var e = document.querySelectorAll('.dsapp-probe-grown');"
        " for (var i = 0; i < e.length; i++) e[i].remove(); }")
    page.wait_for_timeout(300)


def main():
    ck = Chk()
    with sync_playwright() as pw:
        br = pw.chromium.launch(args=["--no-sandbox"])
        pg = br.new_page(viewport={"width": 1440, "height": 900})
        email = enter_app(pg)
        uid, db = seed_or_die(email)
        print("  账号：%s (uid=%s)" % (email, uid), flush=True)
        seed_long_session(uid, db)

        # 库是刚写的，但页面是注册那会儿画的 —— 刷一次让它去读。
        pg.reload(wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-shell", timeout=60000)
        pg.wait_for_timeout(2500)
        ensure_no_modal(pg)
        pg.wait_for_timeout(1500)

        print("\n\033[36m== A 静态结构：这一格在不在、长在哪儿 ==\033[0m", flush=True)
        m = metrics(pg)
        ck("★ 滚动容器上挂着看护器（没有它「贴不贴底」根本无从判断）",
           m["hasKeeper"] is True, m)
        ck("★ 药丸在 DOM 里（不是「浮标没渲染出来」）", m["pill"] is True, m)
        ck("★★ 它是容器的最后一个子元素（sticky 的包含块才真的是滚动容器）",
           m["pillIsLast"] is True, m)
        ck("★ 默认是藏着的（一出场就白占 ~40px 内容高度，scrollHeight 跟着漂）",
           m["pillVisible"] is False, m)
        ck("★★ 两句文案**同时**画在 DOM 里，由 CSS 挑一条（前端改文本会自激）",
           ("回到最新" in (m.get("pillRaw") or "")) and
           ("有新消息" in (m.get("pillRaw") or "")), m.get("pillRaw"))
        # 页面得真的能滚 —— 滚不动的话下面每一条都会"通过"，而它们通过的
        # 原因是"根本没发生过滚动"。这一条是那些判据的地基。
        ck("★ 这份对话真的能滚（地基：滚不动的话下面全是假绿）",
           m["sh"] > m["ch"] + 300, "sh=%s ch=%s" % (m["sh"], m["ch"]))
        ck("★ 阳性基线：页脚写着 Test_V17.2（不是对着上个版本的实例在跑）",
           "Test_V17.2" in pg.inner_text("body"), "")

        print("\n\033[36m== B 贴底时：一个字都不提示（阴性对照）==\033[0m", flush=True)
        scroll_to(pg, "bottom")
        m = metrics(pg)
        ck("★ 滚到底了（pinned 为真）", m["pinned"] is True, m)
        ck("★★ 贴底时药丸收起（它**不是**常驻的浮标）",
           m["pillVisible"] is False and m["pillOn"] is False, m)

        print("\n\033[36m== C 往上滚：药丸出现，写「回到最新」 ==\033[0m", flush=True)
        scroll_to(pg, "top")
        m = metrics(pg)
        ck("★ 用户现在不在底部", m["pinned"] is False, m)
        ck("★★ 药丸出现且可见（display + 真实矩形，不是零矩形）",
           m["pillVisible"] is True, m)
        ck("★★ 写的是「回到最新」，**不是**「有新消息」（这期间没长过东西）",
           m["pillText"] == "↓ 回到最新" and m["pillNew"] is False, m.get("pillText"))
        ck("★★ 它钉在容器下沿（sticky 生效：下沿贴着可视区底边）",
           abs(m["pillBox"]["bottom"] - m["boxBottom"]) <= 12,
           "药丸底 %s · 容器底 %s" % (m["pillBox"]["bottom"], m["boxBottom"]))
        ck("★ 阴性对照：它在可视区**内**（不是被顶到屏幕外还判可见）",
           m["boxTop"] <= m["pillBox"]["top"] < m["boxBottom"], m)

        print("\n\033[36m== D 在中间的时候，下面长出东西 → 提示「有新消息」==\033[0m",
              flush=True)
        where = grow(pg, 200)
        pg.wait_for_timeout(600)
        m = metrics(pg)
        ck("★ 内容真的长在滚动容器里（长歪了后面量的是别的东西）",
           where in ("scroll", "history"), where)
        ck("★★ 长出东西之后改口叫「有新消息」（用户不在底部，下面确实多了）",
           m["pillNew"] is True and m["pillVisible"] is True, m)
        ck("★★ 而且是**可见的那一句**变了（不是两句都在 DOM 里就算过）",
           "有新消息" in m["pillText"] and "回到最新" in m["pillText"],
           m.get("pillText"))

        print("\n\033[36m== E 阴性对照：贴底时长东西 → 不提示，而且状态复位 ==\033[0m",
              flush=True)
        cleanup_grown(pg)
        scroll_to(pg, "bottom")
        grow(pg, 200)
        pg.wait_for_timeout(600)
        m = metrics(pg)
        ck("★★ 贴底时长东西**不**提示（用户就在底部，新内容在他眼前）",
           m["pillVisible"] is False, m)
        cleanup_grown(pg)
        pg.wait_for_timeout(400)
        scroll_to(pg, "top")
        m = metrics(pg)
        ck("★★ 再滚上去只写「回到最新」——「有新消息」那盏灯被复位过",
           m["pillNew"] is False and m["pillVisible"] is True, m)

        print("\n\033[36m== F 点它：回到底部 ==\033[0m", flush=True)
        grow(pg, 200)
        pg.wait_for_timeout(500)
        m = metrics(pg)
        ck("阳性基线：点之前它写的是「有新消息」（不然下面那条量的是空气）",
           m["pillNew"] is True, m)
        pg.click(".dsapp-newmsg-btn")
        pg.wait_for_timeout(1200)
        m = metrics(pg)
        ck("★★ 点完回到底部（离底 ≤ 40px 那条线以内）",
           m["sh"] - m["top"] - m["ch"] < 40,
           "离底 %s" % (m["sh"] - m["top"] - m["ch"]))
        ck("★★ 点完它自己收起（用户已经在看最新了）",
           m["pillVisible"] is False, m)
        cleanup_grown(pg)
        pg.wait_for_timeout(300)

        print("\n\033[36m== G 跳到历史消息：顶上那条要**钉住** ==\033[0m", flush=True)
        n_toc = pg.locator(".dsapp-toc-item").count()
        ck("★ 目录里列得出条目（跳转的入口在，不然这一节量的是空）",
           n_toc >= 4, "条目 %d 个" % n_toc)
        # 点**最早**那一条：它的锚点必须在窗口外，于是走的是"请服务端把窗口
        # 挪过去"那条路 —— 也正是用户报的那个动作。
        # ⚠️ 前置判据：锚点**不在** DOM 里。在的话 `dsappJumpTo()` 第一句就
        #    命中了，它只就地滚过去、**不**发 toc_jump，服务端根本没挪窗口，
        #    顶上那条横条自然不出现 —— 而症状看起来像"sticky 写错了"。
        #    （第一版就是这么红的：种的消息太短，窗口一条都没裁。）
        first = pg.evaluate(
            "() => { var a = document.querySelectorAll('.dsapp-toc-item');"
            " return a.length ? a[0].getAttribute('data-anchor') : null; }")
        in_dom = pg.evaluate(
            "(id) => !!document.getElementById(id)", first)
        ck("★★ 前置：要跳的那条已经被窗口裁掉了（否则测的不是挪窗口那条路）",
           in_dom is False, "anchor=%s 在 DOM 里=%s" % (first, in_dom))
        # ⚠️ 用 DOM 的 .click()，不用 Playwright 的 click()：后者会先把元素
        #    滚进视口，而它就在滚动容器里，一滚就把"贴不贴底"的状态改了。
        pg.evaluate("() => { var a = document.querySelectorAll('.dsapp-toc-item');"
                    " if (a.length) a[0].click(); }")
        pg.wait_for_timeout(3000)
        m = metrics(pg)
        ck("★★ 顶上那条横条出现了（窗口真的挪到中间去了）",
           m.get("histBox") is not None, m)
        ck("★ 它写清了「后面还有 N 条更新的消息」",
           "后面还有" in (m.get("histText") or ""), m.get("histText"))
        ck("★ 量几何之前先确认它看得见（隐藏元素的矩形是全 0，减法会骗人）",
           m.get("histVisible") is True, m.get("histBox"))
        # 前提断言：壳是 display:contents（不生成盒子）。sticky 写在它上面
        # 是空转 —— 这一条把"为什么不能写在那儿"钉在测试里。
        ck("★ 前提：那个 uiOutput 的壳是 display:contents（所以 sticky 不能写在它上面）",
           m.get("hostDisp") == "contents", m.get("hostDisp"))
        ck("★★ sticky 写在横条**自己**身上（写在壳上时它是 static，粘不住）",
           m.get("histPos") == "sticky", m.get("histPos"))
        before = m

        scroll_by(pg, 300)
        after = metrics(pg)
        moved = after["top"] - before["top"]
        ck("阴性对照：这一段真的滚动了（滚不动的话下面那条恒真）",
           moved > 200, "滚了 %s px" % moved)
        # 判据是**同一段滚动里横条自己动了多少**：写错地方时它动的正好是
        # 整个滚动量（实测 -300px），写对了是 0px —— 两头都能量出来。
        d_hist = after["histBox"]["top"] - before["histBox"]["top"]
        ck("★★ 横条没跟着滚走（sticky 生效：滚了 300px 而它几乎不动）",
           abs(d_hist) < moved * 0.35,
           "滚了 %.0f px，横条动了 %.0f px" % (moved, d_hist))
        ck("★★ 它钉在**滚动容器**的顶边（不是钉在别的什么容器上）",
           abs(after["histBox"]["top"] - after["boxTop"]) <= 12,
           "横条顶 %s · 容器顶 %s" % (after["histBox"]["top"], after["boxTop"]))

        print("\n\033[36m== H 在历史窗口里：药丸回最新，顺带把窗口也带回去 ==\033[0m",
              flush=True)
        m = metrics(pg)
        ck("★ 跳到中间之后用户不在底部（药丸该出来了）", m["pinned"] is False, m)
        ck("★★ 药丸出现（原来这里什么都没有，正是用户报的那一句）",
           m["pillVisible"] is True, m)
        grow(pg, 200)
        pg.wait_for_timeout(600)
        m = metrics(pg)
        ck("★★ 在历史窗口里也能被提示「有新消息」", m["pillNew"] is True, m)
        pg.click(".dsapp-newmsg-btn")
        pg.wait_for_timeout(2500)
        m = metrics(pg)
        ck("★★ 点完窗口回到最新（顶上那条横条消失 = 服务端真的挪回去了）",
           m.get("histBox") is None, m.get("histText"))
        ck("★ 而且人回到了底部", m["sh"] - m["top"] - m["ch"] < 40,
           "离底 %s" % (m["sh"] - m["top"] - m["ch"]))
        ck("★ 药丸收起", m["pillVisible"] is False, m)

        pg.screenshot(path=OUT + "/newmsg_end.png", full_page=False)
        br.close()
    return ck.done()


if __name__ == "__main__":
    sys.exit(main())
