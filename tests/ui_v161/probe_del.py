#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""item 3 —— 「删除会话时显示删除不掉」。

用户原话：「主账号中，删除会话时显示删除不掉」。

## 病根（改之前）

`del_gate` 之前只有一句 `if (!can_write())`，而 can_write() 来自 sess_role()，
那一格把三种**完全不同**的处境压成同一个 "none"（见 R/db.R 的
`db_session_role_ex`）：

    ① 对话真的不在了      ② 查库本身抛错      ③ 确实是别人的对话

三种都回同一句「这是别人共享给你的对话，删不了」。于是主账号在 ① 和 ② 下会
被告知一件**不存在的事**，然后怎么点都删不掉 —— 这就是用户报的那一句。

  · ① 的正确处置是"把它从列表里放掉"（heal），**不是**拒绝；
  · ② 的正确处置是把库的原话报出来，让人有得查；
  · 只有 ③ 才是真的拒绝。

## 这个探针怎么让 ① 真的发生

①不是靠"删两次"造出来的（第二次点的时候那一行早就没了，`sess_ver` 一变
侧栏就重画了）。**真身是"另一个标签页"**：页 1 的侧栏里那一行是**旧的**，
而库里的行已经被页 2 删掉了。用户报的场景（多开、或者侧栏停在旧状态）就是
这个。会话列表 `sessions()` 只依赖 sess_ver / state$user_id / cfg() 三个，
**没有任何轮询** —— 所以页 1 会一直挂着那一行，直到有人 +1。

三条路都要走一遍：

  A. 自己的对话，自己删        —— 该删掉，且**不许**弹任何拒绝
  B. 点删除时它已经被别处删了  —— 该 heal（说真话 + 把那行放掉）
  C. 弹窗开着的时候被别处删了  —— 同上，且弹窗要先收掉

## 判据（这个仓栽过的地方，逐条对着写）

* **"没写进去"和"没画出来"必须分开报。** 每次写操作后面都回库确认一次
  （memory: `cooldown-looks-like-broken-ui`、`fake-wait-is-not-a-wait`）。
* **拒绝长得像界面坏了。** 所以不光要断"库里的行没了"，还要断"屏幕上那一行
  也没了" —— 只断前者的话，B/C 两条路的病（`sess_ver` 没 +1，行**一直挂在
  列表里**）会整条溜过去，而库里一切正常。
* **等通知要等"出现过"，不是等"此刻在不在"。** 通知几秒后自己消失，轮询很
  容易整段错过 → 挂 MutationObserver 记下每一条（同 probe_v161 的 ⑤ 节）。
* **B/C 的"前置"必须成立才算数。** 页 2 删完之后要先确认页 1 的 DOM 里那一行
  **还在**（不然量的是"本来就没了"，白送一条绿）。

用法：
    bash tests/ui_v7/make_instance.sh 8965 /tmp/dsapp_v161k
    python3 tests/ui_v161/probe_del.py
退出码 0 = 全绿。
"""

import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from _common import ensure_no_modal                     # noqa: E402

BAD = []

# 改之前那句（三种处境共用）。它在 ① 和 ② 下出现 = 报了一件不存在的事。
OLD_WRONG = "别人共享给你的对话"
# ① 的正确说法（R/mod_chat.R del_gate 里 missing 那一条）
HEAL_MSG = "已经不在了"
# ③ 真·别人的对话才该说的那句
SHARED_MSG = "别人共享给你的对话，删不了"


def say(*a):
    print(*a, flush=True)


def bad(msg):
    BAD.append(msg)
    say("  ✗ " + msg)


def sql(db, q, args=()):
    con = sqlite3.connect(db)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


# --------------------------------------------------------------------------
# 通知：把**出现过**的每一条都记下来
# --------------------------------------------------------------------------
WATCH = r"""
() => {
  /* ⚠️ 这是一个**按节点记账**的流水，不是"按文案去重的集合"。
   *
   * 去重那版（`indexOf(t) < 0` 才 push）有两个方向都会骗人：
   *   · 同一句话**第二次**出现时它不记 —— 于是"这一节到底说没说"量不出来
   *     （B 和 C 说的就是同一句话，C 因此被判成"什么都没说"）；
   *   · 反过来，跨节看的时候旧的那条又一直在，不按序号切开就会从旧记录里
   *     "等"到（C 之前那版就是这么白捡了一条绿）。
   * 两个毛病同一个根：**它记的不是"什么时候说过什么"**。
   * 现在按通知**节点**记账（`__dsappSeen` 是挂在节点上的标记），同一句话在
   * 不同时刻各算一条；Shiny 把文字慢慢填进去的那几拍用 in-place 更新跟上。 */
  window.__dsappNotes = [];
  window.__dsappNodes = [];
  var grab = function () {
    document.querySelectorAll('.shiny-notification').forEach(function (n) {
      var t = (n.innerText || '').replace(/\s+/g, ' ').trim();
      var i = window.__dsappNodes.indexOf(n);
      if (i < 0) {
        if (!t) return;
        window.__dsappNodes.push(n);
        window.__dsappNotes.push({t: t});
      } else if (t && window.__dsappNotes[i].t !== t) {
        window.__dsappNotes[i].t = t;
      }
    });
  };
  grab();
  if (window.__dsappNoteObs) window.__dsappNoteObs.disconnect();
  window.__dsappNoteObs = new MutationObserver(grab);
  window.__dsappNoteObs.observe(document.body, {childList: true, subtree: true,
                                                characterData: true});
  return true;
}
"""

READ_NOTES = ("() => (window.__dsappNotes || []).map(function (x) { return x.t; })")

# 此刻**还在屏幕上**的那几条。日志记的是"出现过"，这个是"现在看得见" ——
# 两个都要查：通知几秒后自己消失，只查屏幕会整段错过；只查日志则依赖
# Observer 没漏拍。判据要的是"用户看没看见过"，两者取并集才对得上。
LIVE_NOTES = ("() => Array.from(document.querySelectorAll('.shiny-notification'))"
              ".map(function (n) {"
              " return (n.innerText || '').replace(/\\s+/g, ' ').trim(); })")


def wait_note(pg, needle, since=0, timeout=25):
    """等到一条含 `needle` 的通知。返回 (原文, 从哪儿看到的)，等不到 (None, "")。

    ⚠️⚠️ `since` **不能省**。`__dsappNotes` 是整页累积的（Observer 一直挂着），
    B 节记下的那条「已经不在了」在 C 节仍然躺在列表里 —— 不按序号切开的话，
    C 节会**立刻**从旧记录里"等"到那一条，于是 C 节的通知判据什么都没验，
    而它报的是绿。

    ⚠️ 两个来源都要查（见 LIVE_NOTES 那段）：只查屏幕会错过自己消失掉的，
    只查日志则完全押在 Observer 上。返回第二个值是**从哪儿看到的** ——
    排查时"它到底出现过没有"和"是不是一直挂着"是两个不同的问题。
    """
    end = time.time() + timeout
    while time.time() < end:
        for t in pg.evaluate(LIVE_NOTES):
            if needle in t:
                return t, "屏幕上"
        for t in pg.evaluate(READ_NOTES)[since:]:
            if needle in t:
                return t, "日志里（已消失）"
        pg.wait_for_timeout(200)
    return None, ""


def notes(pg):
    return pg.evaluate(READ_NOTES)


# --------------------------------------------------------------------------
# 侧栏
# --------------------------------------------------------------------------
SIDS = ("() => Array.from(document.querySelectorAll('.dsapp-sess'))"
        ".map(e => e.getAttribute('data-sid'))")


def row_titles(pg):
    return pg.evaluate(
        "() => Array.from(document.querySelectorAll('.dsapp-sess')).map("
        "e => ({sid: e.getAttribute('data-sid'),"
        "       t: (e.querySelector('.dsapp-sess-title')||{}).innerText || ''}))")


def wait_row(pg, sid, want=True, timeout=20):
    """等侧栏里那一行出现 / 消失。**等的是状态变化，不是"查一次"**
    （memory: `fake-wait-is-not-a-wait`）。"""
    end = time.time() + timeout
    while time.time() < end:
        if (sid in pg.evaluate(SIDS)) == want:
            return True
        pg.wait_for_timeout(200)
    return False


def send(pg, text, timeout=120):
    ensure_no_modal(pg, timeout=3)
    pg.fill("#chat-input", text)
    pg.click("#chat-send")
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 25:
        if pg.locator("#chat-send[disabled]").count():
            break
        pg.wait_for_timeout(150)
    while time.time() < end:
        if not pg.locator("#chat-send[disabled]").count():
            pg.wait_for_timeout(700)
            if not pg.locator("#chat-send[disabled]").count():
                return True
        pg.wait_for_timeout(250)
    return False


def click_del(pg, confirm, expect_modal=True):
    """点「删除」；confirm=True 时再点弹窗里那颗红色的。

    ⚠️ 弹窗是**后到的**（进页面时检查过一次，那时它还没出来）。
       memory: `first-run-onboarding-modal-blocks-clicks`。

    ★ `expect_modal=False` 是 B 那条路要的：`del_gate` 判出"这个对话已经不在
      了"时返回的是 `heal = TRUE`，而 `observeEvent(input$del_chat)` 遇到
      `!ok` 是 **`return(del_gate_notify(...))`** —— 它**根本不弹窗**，直接
      说真话 + 把那行放掉。所以 B 里"弹窗没出来"是**对的**，探针要是傻等
      `#shiny-modal` 就会超时，报的错还指向一个根本不存在的 UI 问题。
      （第一版就是这么栽的：15 秒超时，traceback 最后一行是
      `waiting for locator("#shiny-modal") to be visible`。）
    """
    ensure_no_modal(pg, timeout=3)
    pg.click("#chat-del_chat")
    if not expect_modal:
        pg.wait_for_timeout(1500)
        return pg.locator("#shiny-modal").count() > 0
    pg.wait_for_selector("#shiny-modal", timeout=15000)
    pg.wait_for_timeout(400)
    if confirm:
        pg.click("#chat-do_del_chat")
        pg.wait_for_timeout(500)
    return True


def wait_ready(pg, timeout=180):
    """等「要么进主界面、要么看到登录页」。

    ⚠️⚠️ **不能拿 C.wait_awake() 来等第二个标签页。** 它等的是 `.dsapp-auth`
    （那个注册/登录的壳），而第二个标签页和第一个**共用一个 context 的
    cookie** —— 它一进来就是主界面，`.dsapp-auth` 那个节点**永远不会出现**。
    于是 wait_awake 会一路空转到 150 秒超时，而且中途每 60 秒 reload 一次
    （见它自己的 reload_after）—— 每一次 reload 都是**新开一个 Shiny
    session**，白烧一遍首屏 flush。三次调用就是七分半钟，看着像"卡死了"。
    """
    end = time.time() + timeout
    while time.time() < end:
        try:
            if (pg.locator(".dsapp-shell").count()
                    or pg.locator(".dsapp-auth").count()):
                return True
        except Exception:
            pass
        pg.wait_for_timeout(500)
    return False


def login_page(pg, email):
    """同一 context 里的第二个标签页：cookie 在，多半直进主界面。"""
    pg.goto(C.URL, wait_until="domcontentloaded")
    wait_ready(pg)
    for _ in range(60):
        if pg.locator(".dsapp-shell").count():
            return True
        if pg.locator("#welcome-do_login").count():
            pg.fill("#welcome-login_email", email)
            pg.fill("#welcome-login_password", C.PW)
            pg.click("#welcome-do_login")
            pg.wait_for_timeout(2000)
            continue
        pg.wait_for_timeout(1000)
    return pg.locator(".dsapp-shell").count() > 0


def new_chat_with_msg(pg, fx, text):
    """发一句话造一个新对话，返回 (sid, title)。"""
    fx.set_queue(C.sse("收到。"))
    ensure_no_modal(pg, timeout=3)
    pg.click("#chat-new_chat")
    pg.wait_for_timeout(800)
    send(pg, text)
    rows = row_titles(pg)
    if not rows:
        sys.exit("发完消息侧栏里一条对话都没有 —— 后面的判据没法做")
    # 最近更新的排最前（db_sessions_list 的顺序），所以 [0] 就是刚建的这个
    return rows[0]["sid"], rows[0]["t"]


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        errs = []
        pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))

        C.enter_app(pg, C.EMAIL)
        C.wait_awake(pg)
        uid, db = C.seed_or_die(C.EMAIL)
        say("账号 uid=%s  实例 %s  库 %s" % (uid, C.URL, db))

        fx = C.FakeLLM()
        line = C.seed_llm(uid, fx.url)
        if "=NA" in line:
            sys.exit("种 LLM 设置没写进去：%s" % line)
        # ★★ 必须 reload：state$base_url 是会话开始那一刻读一次的。
        pg.reload(wait_until="domcontentloaded")
        C.wait_awake(pg)
        pg.evaluate(WATCH)

        # ==================================================================
        say("")
        say("=== A. 自己的对话，自己删（用户报的那条路）===")
        C.goto(pg, "chat")
        ensure_no_modal(pg)
        pg.evaluate(WATCH)
        sid_a, title_a = new_chat_with_msg(pg, fx, "A 用来说一句话")
        say("  建好了 sid=%s 标题=%r" % (sid_a, title_a))
        n_before = sql(db, "SELECT count(*) FROM sessions WHERE id=?", (sid_a,))[0][0]
        if n_before != 1:
            bad("前置不成立：库里查不到这个对话（%d 行）" % n_before)
        click_del(pg, confirm=True)

        gone = wait_row(pg, sid_a, want=False, timeout=20)
        n_after = sql(db, "SELECT count(*) FROM sessions WHERE id=?", (sid_a,))[0][0]
        say("  库里 %d → %d 行；侧栏那一行消失=%s"
            % (n_before, n_after, gone))
        if n_after != 0:
            bad("★ 点了删除，库里的行**还在**（%d 行）—— 删除真的没生效" % n_after)
        elif not gone:
            bad("★ 库里删掉了，但侧栏那一行**还挂着** —— 用户看到的就是"
                "「删不掉」；这是 sess_ver 没 +1 的老病")
        nts = notes(pg)
        wrong = [t for t in nts if OLD_WRONG in t]
        if wrong:
            bad("★ 删自己的对话，却弹了「%s」—— 报了一件不存在的事"
                % wrong[0][:80])
        say("  这一轮的通知 %d 条" % len(nts))

        # ==================================================================
        say("")
        say("=== B. 点删除时它已经被别处删了（①，heal 那条路）===")
        # 页 2 先进来，省得 B 的等待里再叠一次冷启动
        pg2 = ctx.new_page()
        if not login_page(pg2, C.EMAIL):
            sys.exit("第二个标签页没进主界面 —— B/C 两条路做不到")
        pg2.evaluate(WATCH)
        C.goto(pg2, "chat")
        ensure_no_modal(pg2)

        sid_b, title_b = new_chat_with_msg(pg, fx, "B 用来说一句话")
        say("  页 1 建好了 sid=%s 标题=%r" % (sid_b, title_b))
        if not wait_row(pg, sid_b, want=True, timeout=15):
            bad("前置不成立：页 1 侧栏里没有刚建的那一行")

        # 页 2 刷新拿到最新的列表，然后把这个对话删掉
        pg2.reload(wait_until="domcontentloaded")
        wait_ready(pg2)
        C.goto(pg2, "chat")
        ensure_no_modal(pg2)
        pg2.evaluate(WATCH)
        if not wait_row(pg2, sid_b, want=True, timeout=20):
            sys.exit("页 2 的侧栏里找不到 %s —— 两个标签页没看到同一个账号" % sid_b)
        pg2.click(".dsapp-sess[data-sid='%s']" % sid_b)
        pg2.wait_for_timeout(1500)
        click_del(pg2, confirm=True)
        if not wait_row(pg2, sid_b, want=False, timeout=20):
            bad("前置不成立：页 2 自己都没删掉（那 B 量不到东西）")
        say("  页 2 已经删掉；库里现在 %d 行"
            % sql(db, "SELECT count(*) FROM sessions WHERE id=?", (sid_b,))[0][0])

        # ★★ 前置：页 1 的 DOM 里那一行**必须还在** —— 不在了就说明
        #    页 1 自己在轮询（本仓的 sessions() 没有轮询），那 B 是白送的绿。
        still = sid_b in pg.evaluate(SIDS)
        say("  页 1 的侧栏里那一行还在吗：%s（这是 B 的前提）" % still)
        if not still:
            bad("★ 前置不成立：页 1 的侧栏自己把那一行放掉了 —— 那样量到的"
                "「heal 生效」是白送的（并且说明列表在轮询，本仓不该有）")

        nts_before = len(notes(pg))
        # ★ 这一下**不该弹窗**：闸门认出"它已经不在了"，直接说真话并把那行
        #   放掉。弹窗出来了反而是红 —— 说明闸门放它过去了。
        popped = click_del(pg, confirm=False, expect_modal=False)
        if popped:
            bad("★ 对话已经不在了，点删除却**弹出了确认框** —— 闸门没拦住，"
                "用户会一路点到「删除」然后收到一句莫名其妙的错")
        got, where = wait_note(pg, HEAL_MSG, since=nts_before, timeout=25)
        nts = notes(pg)[nts_before:]
        say("  页 1 这一轮的通知（看到它的地方：%s）：" % (where or "——"))
        for t in nts:
            say("    · " + t[:110])
        if not got:
            if any(OLD_WRONG in t for t in nts):
                bad("★ 说的是「%s」—— 正是用户报的那句。对话明明只是**不在了**，"
                    "却告诉他这是别人的对话" % OLD_WRONG)
            else:
                bad("★ 什么都没说（通知 %d 条）—— 用户点完删除，界面上"
                    "一点反应都没有" % len(nts))
        if any(SHARED_MSG in t for t in nts):
            bad("★ 出现了「%s」—— 这不是共享，是①" % SHARED_MSG)
        healed = wait_row(pg, sid_b, want=False, timeout=20)
        say("  页 1 那一行被放掉了=%s" % healed)
        if not healed:
            bad("★ 说的是真话，但那一行**还挂在侧栏里** —— 用户会一直点它。"
                "heal 的整个意义就是「把界面拉回真相」")

        # ==================================================================
        say("")
        say("=== C. 弹窗开着的时候被别处删了（do_del_chat 那道闸）===")
        sid_c, title_c = new_chat_with_msg(pg, fx, "C 用来说一句话")
        say("  页 1 建好了 sid=%s 标题=%r" % (sid_c, title_c))
        if not wait_row(pg, sid_c, want=True, timeout=15):
            bad("前置不成立：页 1 侧栏里没有刚建的那一行")

        # 页 1 把删除弹窗**开在那儿**（这一下会过闸），然后页 2 把它删掉
        ensure_no_modal(pg, timeout=3)
        pg.click("#chat-del_chat")
        pg.wait_for_selector("#shiny-modal", timeout=15000)
        pg.wait_for_timeout(400)
        say("  页 1 的弹窗开着：%s"
            % pg.locator("#shiny-modal").inner_text().replace("\n", " ")[:70])

        pg2.reload(wait_until="domcontentloaded")
        wait_ready(pg2)
        C.goto(pg2, "chat")
        ensure_no_modal(pg2)
        if not wait_row(pg2, sid_c, want=True, timeout=20):
            sys.exit("页 2 的侧栏里找不到 %s" % sid_c)
        pg2.click(".dsapp-sess[data-sid='%s']" % sid_c)
        pg2.wait_for_timeout(1500)
        click_del(pg2, confirm=True)
        wait_row(pg2, sid_c, want=False, timeout=20)
        say("  页 2 已经删掉；库里现在 %d 行"
            % sql(db, "SELECT count(*) FROM sessions WHERE id=?", (sid_c,))[0][0])

        nts_before = len(notes(pg))
        pg.click("#chat-do_del_chat")          # 页 1 点下那个已经过期的「删除」
        got, where = wait_note(pg, HEAL_MSG, since=nts_before, timeout=25)
        nts = notes(pg)[nts_before:]
        say("  页 1 这一轮的通知（看到它的地方：%s）：" % (where or "——"))
        for t in nts:
            say("    · " + t[:110])
        if not got:
            bad("★ 弹窗开着的时候对话被别处删了，点确认后**没有**说真话"
                "（通知 %d 条）" % len(nts))
        if any(OLD_WRONG in t for t in nts):
            bad("★ 说的是「%s」—— 用户报的那句又回来了" % OLD_WRONG)
        # 弹窗必须收掉：不收的话它会一直盖在页面上，而它要删的东西已经没了
        pg.wait_for_timeout(600)
        modal = pg.locator("#shiny-modal").count()
        vis = False
        if modal:
            vis = pg.evaluate(
                "() => { var m = document.getElementById('shiny-modal');"
                " if (!m) return false;"
                " var r = m.getBoundingClientRect();"
                " return r.width > 0 && r.height > 0; }")
        say("  弹窗还在吗：count=%s 可见=%s" % (modal, vis))
        if vis:
            bad("★ 对话已经没了，删除弹窗**还开着** —— 用户只能对着一个"
                "删不掉的框反复点")
        if not wait_row(pg, sid_c, want=False, timeout=20):
            bad("★ C 这条路里侧栏那一行没被放掉")

        # ==================================================================
        say("")
        say("=== 收尾 ===")
        rest = sql(db, "SELECT id, title FROM sessions WHERE user_id=?",
                   (uid,))
        say("  库里这个账号还剩 %d 个对话：%s"
            % (len(rest), [r[1][:22] for r in rest]))
        for sid in (sid_a, sid_b, sid_c):
            if sql(db, "SELECT count(*) FROM sessions WHERE id=?", (sid,))[0][0]:
                bad("★ %s 还在库里" % sid)
        left = pg.evaluate(SIDS)
        say("  页 1 侧栏里还剩 %d 行：%s" % (len(left), [str(x)[:8] for x in left]))
        for sid in (sid_a, sid_b, sid_c):
            if sid in left:
                bad("★ %s 还挂在页 1 的侧栏里" % sid)
        if errs:
            bad("浏览器报了 %d 条错，头一条：%s" % (len(errs), errs[0][:200]))

        pg.screenshot(path=os.path.join(C.OUT, "del.png"), full_page=True)
        fx.stop()
        ctx.close()
        br.close()

    say("")
    if BAD:
        say("===== 红 %d 条 =====" % len(BAD))
        for m in BAD:
            say("  · " + m)
        sys.exit(1)
    say("===== 全绿 =====")


if __name__ == "__main__":
    main()
