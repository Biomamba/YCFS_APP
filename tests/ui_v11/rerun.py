# -*- coding: utf-8 -*-
"""V11 item 8：重跑的结果要回到它所属的那条对话。

对着一次性实例（8898）跑：

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v11/rerun.py

用户的原话是「实际的成功输出与失败输出都应该在言出法随界面给到用户，
因为环境配置等原因导致任务失败应该让AI自动调试」。

★ 为什么非要用浏览器：这一段改的是**两个页面之间的联动**。「写回对话」
这件事在库里判得出来（一条 tool 消息多出来了），但用户真正会遇到的坏法
是另一种 —— 消息确实写进去了，**对话页不知道**，切回去看见的还是旧的那
一屏，得刷新浏览器才出来。库里的断言对这种情况完全无感，而它在界面上
的表现是"点了没反应，刷新又对了"，和 sendCustomMessage 那类 proxy 问题
一模一样（见项目记忆）。

所以这里一路点到真实界面：在「历史任务」页点重跑 → 切回「言出法随」→
**不刷新**，看那条执行结果有没有自己冒出来。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (APP, DATA_ROOT, OUT, URL, Chk, db_path, enter_app,  # noqa
                     goto_chat, seed_conversation)
from playwright.sync_api import sync_playwright

chk = Chk()

# ★ 这段代码是**故意**跑不起来的：报错文本是 R 缺包的标准说法，平台的
#   环境判定认的就是它。用一段能跑通的代码测不出 item 8 的另一半
#   （「环境配置等原因导致任务失败应该让AI自动调试」）。
BAD_CODE = "library(dsapp_thispkgdoesnotexistzzz)\ncat('never')\n"
BAD_PKG = "dsapp_thispkgdoesnotexistzzz"


def sql(q, args=()):
    con = sqlite3.connect(db_path())
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def goto_page(pg, label, wait=2500):
    pg.locator(".dsapp-rail-link", has_text=label).first.click()
    pg.wait_for_timeout(wait)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))

    email = enter_app(pg)
    sid = seed_conversation(email, rounds=3)
    chk("（前置）测试对话建好了", bool(sid), sid)

    # 往这条对话里塞一条**已经跑完**的任务。不用真跑一遍：这里要验的是
    # "重跑的那一次结果写没写回对话"，不是执行器本身。
    uid = sql("SELECT id FROM users WHERE email = ?", (email,))[0][0]
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    con = sqlite3.connect(db_path())
    con.execute(
        "INSERT INTO tasks (session_id, title, lang, code, status, created_at,"
        " started_at, finished_at, exit_code, stdout, stderr)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (sid, "item8 待重跑", "r", BAD_CODE, "failed", now, now, now, 1, "",
         "Error in library(%s) : there is no package called '%s'"
         % (BAD_PKG, BAD_PKG)))
    con.commit()
    tid = con.execute("SELECT id FROM tasks ORDER BY id DESC LIMIT 1").fetchone()[0]
    con.close()
    chk("（前置）库里有一条失败的任务", bool(tid), tid)

    n_before = sql("SELECT COUNT(*) FROM messages WHERE session_id = ?", (sid,))[0][0]

    # ⚠️ 前面几行是绕过界面直接写库的，服务端一点都不知道 —— 会话列表在
    #    模块初始化那一刻就已经渲染完了。必须**重新加载一次页面**，让它带着
    #    这些行从头渲染。不 reload 的话左栏一条会话都没有，后面每一步都会
    #    卡在"找不到元素"上，而报出来的错会指向"点不中会话"这种错方向。
    goto_chat(pg, reload_first=True)
    pg.wait_for_selector(".dsapp-sess", timeout=30000)
    pg.click(".dsapp-sess[data-sid='%s']" % sid)
    pg.wait_for_timeout(3000)
    before = pg.inner_text(".dsapp-chat-scroll")
    # ⚠️ 界面上的字样是「执行结果 · 任务 #N」，**不带**回喂文本里那对【】——
    #    卡片渲染器会把首行的【…】剥掉当标题（dsapp_tool_sections）。断言写成
    #    `"【执行结果" in ...` 会永远为假，而报出来的错是"结果没写进对话"，
    #    方向完全反了。
    chk("（前置）重跑之前，对话里没有执行结果",
        "执行结果 · 任务" not in before,
        "对话区里已经有执行结果了：%s" % before[-200:])

    # =====================================================================
    # 在「历史任务」页点重跑
    # =====================================================================
    goto_page(pg, "历史任务")
    pg.wait_for_timeout(1500)
    chk("item8 ★ 导航栏上是「历史任务」",
        pg.locator(".dsapp-rail-link", has_text="历史任务").count() >= 1)
    # ⚠️ 必须**点一下刷新**。任务是绕过界面直接塞进库的，而 DT 只在 refresh
    #    这个 reactiveVal 变了才重新查库 —— 切页不会（navset_hidden 是"只藏
    #    不激活"，模块一直活着，切回来时它还是切走前那一屏）。不点的话拿到
    #    的是"还没有执行记录"那一行，而它的唯一一个 <td> 会让下面读第二列的
    #    代码直接超时，报出来的错完全指不到真正的原因。
    pg.click("#tasks-refresh")
    pg.wait_for_timeout(3000)

    rows = pg.locator("#tasks-tbl tbody tr")
    target = None
    for i in range(rows.count()):
        if rows.nth(i).locator("td").nth(1).inner_text().strip() == str(tid):
            target = rows.nth(i)
            break
    chk("（前置）列表里找得到那条任务", target is not None,
        "ID=%s 不在列表里（%d 行）" % (tid, rows.count()))

    if target is not None:
        # ⚠️ 先看勾选状态再点。DT 的 Select 扩展是**抽屉式切换**：已经勾着
        #    的再点一下就取消了。第一版没判状态，每次点完查到 0 个勾选，
        #    看着像"复选框点不动"。
        sel = "#tasks-tbl tr.selected, #tasks-tbl tr.active"
        if pg.locator(sel).count() == 0:
            target.locator("td").first.click()
            pg.wait_for_timeout(1500)
        chk("（前置）那一行勾上了", pg.locator(sel).count() >= 1,
            "勾中 %d 行" % pg.locator(sel).count())

        pg.click("#tasks-rerun")
        pg.wait_for_timeout(3000)

        # 等它跑完。最多 60 秒 —— 这段代码是"包不存在"，R 起手就报错，
        # 正常一两秒的事。
        new_tid = None
        for _ in range(60):
            r = sql("SELECT id FROM tasks WHERE session_id = ? ORDER BY id DESC"
                    " LIMIT 1", (sid,))
            if r and r[0][0] != tid:
                st = sql("SELECT status FROM tasks WHERE id = ?", (r[0][0],))
                if st and st[0][0] in ("success", "failed", "error", "timeout"):
                    new_tid = r[0][0]
                    break
            pg.wait_for_timeout(1000)
        chk("★★ 重跑真的提交了一个新任务", new_tid is not None)
        if new_tid:
            st = sql("SELECT status, stderr FROM tasks WHERE id = ?",
                     (new_tid,))[0]
            chk("★ 它是失败的（这段代码本来就跑不通）", st[0] == "failed", st[0])
            chk("★ 报错是「缺包」那一种", BAD_PKG in (st[1] or ""), st[1])

        # ---- 库里应该已经多了一条 tool 消息 ------------------------------
        msgs = sql("SELECT role, content FROM messages WHERE session_id = ?"
                   " ORDER BY id", (sid,))
        chk("★★ 重跑的结果写进了那条对话",
            len(msgs) == n_before + 1, "消息数 %d → %d" % (n_before, len(msgs)))
        last = msgs[-1] if msgs else ("", "")
        chk("★ 是 tool 角色的气泡", last[0] == "tool", last[0])
        chk("★ 头一行是【执行结果 · 任务 #N】",
            ("【执行结果 · 任务 #%s】" % new_tid) in (last[1] or ""),
            (last[1] or "")[:120])
        # ⚠️ 最后这一条是 item 8 的另一半：判定不跟着一起进对话的话，
        #    模型下一轮读到的就只是一段报错原文，而它的默认反应是把这段
        #    报错转手给用户 —— 正好是用户要求改掉的那个行为。
        chk("★★ 环境判定跟着一起进了对话（模型据此自己修，而不是转手）",
            "平台判定" in (last[1] or ""), (last[1] or "")[-400:])

    # =====================================================================
    # 切回「言出法随」——**不刷新、也不点任何东西**，看它自己冒不冒出来
    # =====================================================================
    #
    # ⚠️ 这里**不能**再点一次那条会话。点它是"用户主动做了个动作"，会顺带
    #    把历史重渲染一遍 —— 于是**没有** state$msg_rev 也照样能过，这条断言
    #    就白写了。要验的恰恰是"什么都没做，它自己就对了"。
    #
    #    （会话在切走之前就已经选中了，rv$session_id 一直指着它。）
    goto_chat(pg)
    pg.wait_for_timeout(2000)

    # 读整个对话滚动区（.dsapp-chat-scroll，见 mod_chat_ui）。
    body = pg.inner_text(".dsapp-chat-scroll") \
        if pg.locator(".dsapp-chat-scroll").count() else pg.inner_text("body")
    chk("★★★ 不刷新页面，重跑的结果就出现在对话里了"
        "（缺 state$msg_rev 的话这里要刷新才看得见）",
        "执行结果 · 任务" in body,
        "对话区里没有执行结果。正文末尾：%s" % body[-300:])
    chk("★★ 失败原文也在（成功失败都要给到用户，不只是「模型看得见」）",
        "there is no package called" in body,
        "报错原文没显示。末尾：%s" % body[-300:])

    # ★ 环境问题在界面上要**单独说一句**：不分的话，"缺一个包"和"这一列
    #   名字写错了"长得一模一样（都是一屏红字 + 一个让 AI 分析的按钮），
    #   用户只能自己猜这次该不该他动手。
    env_box = pg.locator(".dsapp-run-env")
    chk("★★ 卡片上有一块「环境问题」", env_box.count() >= 1,
        "没有 .dsapp-run-env（渲染器没接上这段判定？）")
    env_txt = env_box.first.inner_text() if env_box.count() else ""
    chk("★★ 说清了不用用户动手", "不用做什么" in env_txt or "不用你做什么" in env_txt,
        env_txt)
    chk("★ 给出了是哪一种环境问题（不是一句笼统的「环境有问题」）",
        BAD_PKG in env_txt or "包" in env_txt, env_txt)
    chk("★ 界面上**没有**把写给模型的那段话摊出来"
        "（「不是用户该处理的事」是回喂里的措辞，不该出现在气泡里）",
        "不是用户该处理的事" not in body and "你自己就能修" not in body,
        "气泡里出现了回喂专用的措辞")

    chk("★ 执行结果的条数不多不少（没有重复写两遍）",
        body.count("执行结果 · 任务") == 1,
        "出现 %d 次" % body.count("执行结果 · 任务"))

    chk("页面上没有 JS 报错", len(errs) == 0, errs[:3])
    pg.screenshot(path=os.path.join(OUT, "item8_rerun.png"), full_page=True)
    b.close()

sys.exit(chk.done())
