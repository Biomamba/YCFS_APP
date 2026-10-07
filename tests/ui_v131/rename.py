# -*- coding: utf-8 -*-
"""V13.1 item 4：会话（对话）更名。

用户原话就一句「会话需要能够更名」。入口是侧栏每一行右边那个铅笔。

★ 为什么这里**直接往库里插对话**，而不是发一条消息聊出来：
  发消息要真的调模型（要 API Key、要等、模型今天心情不好还不行），而这
  几条断言没有一条跟模型有关 —— 要验的是「侧栏那一行能不能改名」。插进去
  的对话和聊出来的对话在侧栏里走的是**同一条渲染路径**（都来自
  db_sessions_list），所以插的足够，而且快、稳、不花钱。contrast.py 里
  那几个代码块也是这么种的，理由一样。

★ 这一项里最要紧的是**权限**那两条：改名和发消息、删除走的是同一条判据
  （dsapp_role_can_write，"能写"），散着判迟早漏一处。所以这里真的开第二
  个账号、真的建一条共享行，去看那一行上**有没有铅笔** —— 不是去读源码
  里写没写 if。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, seed_or_die, EMAIL   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

TAG = str(int(time.time()))[-6:]
EB = "v131b_%s@example.com" % TAG

SID_A = "s-v131a-%s" % TAG          # 要改名的那条
SID_B = "s-v131b-%s" % TAG          # 拿来看"点铅笔会不会顺手切走"的那条
T_OLD = "改名前的老标题"
T_NEW = "改完的新标题"


def add_session(dbp, uid, sid, title, ts):
    con = sqlite3.connect(dbp)
    con.execute("INSERT INTO sessions (id, title, user_id, created_at,"
                " updated_at) VALUES (?,?,?,?,?)", (sid, title, uid, ts, ts))
    con.commit()
    con.close()


def title_of(dbp, sid):
    con = sqlite3.connect(dbp)
    r = con.execute("SELECT title FROM sessions WHERE id = ?", (sid,)).fetchone()
    con.close()
    return r[0] if r else None


def share(dbp, sid, uid, by):
    con = sqlite3.connect(dbp)
    con.execute("INSERT INTO session_share (session_id, user_id, granted_by,"
                " created_at) VALUES (?,?,?,?)",
                (sid, uid, by, "2026-09-16 10:00:00"))
    con.commit()
    con.close()


def row(page, sid):
    return page.locator(".dsapp-sess[data-sid='%s']" % sid).first


def sidetext(page):
    """侧栏现在写了什么。出错时当证据用 —— 所以**不能抛异常**：
    一个"顺便打印一下"的参数把整条脚本带崩，是这类脚本最容易犯的错。"""
    try:
        return page.inner_text("#chat-session_list")[:300]
    except Exception:
        return "（读不到侧栏）"


def active_sid(page):
    a = page.locator(".dsapp-sess.active")
    if a.count() == 0:
        return None
    return a.first.get_attribute("data-sid")


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ca = br.new_context(viewport={"width": 1500, "height": 950})
    pa = ca.new_page()
    enter_app(pa, nickname="甲")
    uid_a, dbp = seed_or_die(EMAIL)
    # 两条：A 旧一点、B 新一点。侧栏按 updated_at 倒序，所以 B 排在前面。
    add_session(dbp, uid_a, SID_A, T_OLD, "2026-09-16 09:00:00")
    add_session(dbp, uid_a, SID_B, "另一条对话", "2026-09-16 09:30:00")
    print("   甲 uid=%s，造了 %s / %s" % (uid_a, SID_A, SID_B), flush=True)

    # ⚠️⚠️ 这里**必须 reload**，不能只 goto("chat")。
    #
    #   侧栏那个 renderUI 只依赖 sess_ver / hist_ver / state$msg_rev ——
    #   它**不知道**库里多了一行。而且 enter_app 一路点完注册，人已经站在
    #   对话页上了（那是默认页），侧栏早就用"0 个对话"渲染过一遍。
    #   于是"插了库 → goto('chat')"看到的还是空列表，而切页本身什么都没
    #   触发（已经在 chat 上，nav 没变）—— 报出来是"侧栏里两条都不在"，
    #   看着像功能坏了，其实是页面没重新读库。
    #   2026-09-16 第一版就是这么红的。
    pa.reload(wait_until="domcontentloaded")
    pa.wait_for_selector(".dsapp-shell", timeout=40000)
    pa.wait_for_timeout(2500)
    goto(pa, "chat", wait=4000)

    chk("★ 侧栏里两条都在", row(pa, SID_A).count() == 1 and
        row(pa, SID_B).count() == 1,
        extra="侧栏现在是：%s" % sidetext(pa))
    chk("★ 名字是库里的原文", T_OLD in row(pa, SID_A).inner_text(),
        extra=row(pa, SID_A).inner_text()[:80])
    chk("★★ 行上有「重命名」铅笔（没有入口 = 用户根本找不到这个功能）",
        row(pa, SID_A).locator("a.dsapp-sess-edit").count() == 1)

    # ---- 先把 B 点成"当前对话" -------------------------------------------
    #
    # 点时间那一行，不点标题：标题和铅笔同在一行，点标题的中心离铅笔近，
    # 万一版面一改就点歪了。时间那一行没有铅笔。
    row(pa, SID_B).locator(".dsapp-sess-time").click()
    pa.wait_for_timeout(2500)
    chk("★ 点会话行能切过去（下面那条的前提）", active_sid(pa) == SID_B,
        extra="当前是 %s" % active_sid(pa))

    # ---- 点铅笔 -----------------------------------------------------------
    #
    # ★★ 这一条盯的是 app.js 里那个 stopPropagation。整个会话行上挂着
    #    dsappPickSession 的 onclick，铅笔在行**里面** —— 不拦冒泡的话，
    #    点铅笔会先切到那个对话、再弹重命名框。用户看到的是"点一下铅笔，
    #    左边的对话莫名其妙跳了"。
    row(pa, SID_A).locator("a.dsapp-sess-edit").click()
    pa.wait_for_selector("#chat-rename_title", timeout=15000)
    pa.wait_for_timeout(1200)
    chk("★★ 点铅笔**不会**顺手把那个对话切成当前（stopPropagation 还在）",
        active_sid(pa) == SID_B, extra="当前是 %s" % active_sid(pa))
    chk("★ 弹出的是重命名框", "重命名" in pa.inner_text(".modal-title"),
        extra=pa.inner_text(".modal-title"))
    chk("★★ 输入框预填的是**库里的原文**（不是短号、不是空的）",
        pa.input_value("#chat-rename_title") == T_OLD,
        extra=repr(pa.input_value("#chat-rename_title")))

    # ---- 空名字要被挡住 ----------------------------------------------------
    #
    # ⚠️ fill 完必须等一下再点。Shiny 的 textInput 是**防抖 250ms** 回传的，
    #    填完立刻点保存，服务端手里还是上一次的值 —— 表现是"改了没反应"。
    pa.fill("#chat-rename_title", "")
    pa.wait_for_timeout(900)
    pa.click("#chat-do_rename")
    pa.wait_for_timeout(1500)
    chk("★ 空名字挡下来了（弹窗还在）",
        pa.locator("#chat-rename_title").count() == 1)
    chk("★ 而且说清楚了为什么", "空" in pa.inner_text("body"))
    chk("★ 库里没被改成空串", title_of(dbp, SID_A) == T_OLD,
        extra=repr(title_of(dbp, SID_A)))

    # ---- 正常改名 ---------------------------------------------------------
    pa.fill("#chat-rename_title", T_NEW)
    pa.wait_for_timeout(900)
    pa.click("#chat-do_rename")
    pa.wait_for_timeout(2500)
    chk("★ 存完弹窗关掉了", pa.locator("#chat-rename_title").count() == 0)
    chk("★★ 库里真的改了", title_of(dbp, SID_A) == T_NEW,
        extra=repr(title_of(dbp, SID_A)))
    chk("★★ 侧栏那一行也跟着变了（不重画的话用户得刷新才看得到）",
        T_NEW in row(pa, SID_A).inner_text(),
        extra=row(pa, SID_A).inner_text()[:80])
    chk("★ 另一条没被误伤", title_of(dbp, SID_B) == "另一条对话")

    # ⚠️ 改名**不应该**把那个对话顶到列表最前面。列表是按 updated_at 倒序排
    #    的，而 db_session_rename 会顺手戳一下 updated_at —— 这是**故意的**
    #    （改完名它确实"动过"），但如果有谁哪天把它改成按 title 排或者
    #    加个"改名的置顶"，用户扫一眼列表会发现顺序莫名其妙变了。
    #    这里只钉住"另一条还在"，不钉顺序：顺序是产品决定，不是对错。

    pa.screenshot(path=OUT + "/rename_a.png", full_page=True)

    # ---- 共享进来的那条：连铅笔都不该有 -----------------------------------
    print("\n== 乙账号（共享只读）==", flush=True)
    cb = br.new_context(viewport={"width": 1500, "height": 950})
    pb = cb.new_page()
    enter_app(pb, EB, nickname="乙")
    uid_b, _ = seed_or_die(EB)
    share(dbp, SID_A, uid_b, uid_a)
    print("   乙 uid=%s，把 %s 共享给了他" % (uid_b, SID_A), flush=True)

    # ⚠️ 必须 reload：上面 enter_app 已经把乙的页面渲染过一遍了，那时候共享行
    #    还不存在。不重载的话看到的是"共享没生效"，而其实是没刷新。
    pb.reload(wait_until="domcontentloaded")
    pb.wait_for_selector(".dsapp-shell", timeout=40000)
    pb.wait_for_timeout(2500)
    goto(pb, "chat", wait=4000)

    r = row(pb, SID_A)
    chk("★ 乙看得到这条共享给他的对话", r.count() == 1)
    chk("★ 而且标了是谁共享的（不标的话他会以为是自己建的）",
        "共享" in r.inner_text(), extra=r.inner_text()[:80])
    chk("★★ 共享进来的这一行**没有**铅笔（画了再拒绝比不画更让人困惑）",
        r.locator("a.dsapp-sess-edit").count() == 0)
    chk("★ 乙自己那条别的对话也不受影响", title_of(dbp, SID_A) == T_NEW)

    pb.screenshot(path=OUT + "/rename_b.png", full_page=True)
    br.close()

sys.exit(chk.done())
