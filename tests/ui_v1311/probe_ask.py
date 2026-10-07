# -*- coding: utf-8 -*-
"""item 10 验收：会话以疑问句结尾时，要有一颗**能点**的「继续」。

用户原话：
  10、我现在的会话以疑问句结尾："我可以直接基于它跑建模，跳过数据准备。
      要不要继续？"但是并没有让我确认是否继续执行，确认按钮也是灰度的

根因：「确认执行」那颗按钮的判据一直是"最后一条回复里有没有没跑过的**可执行
代码**"。agent 停下来问一句"要不要继续"时没有代码块，判据不成立，按钮就
一直灰着 —— 用户没有任何地方可以点。

这一条真的在浏览器里验：种一条以问句结尾的助手消息 → 打开那个对话 →
看那颗按钮**亮没亮**、是什么字 → 点它 → 看那句话有没有真的发出去。

⚠️ 为什么必须种数据而不是让模型自己说：真跑一轮要一把能用的 API Key，
   而且模型每次的话都不一样（这一条测的是判据，不是模型）。
   messages 表是明文，可以直接写；api_key 那两列才是密文（要加密钥串，
   所以那条路只能走界面，见下面配假 Key 的那段）。
"""
import sqlite3
import sys
import time

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import URL, enter_app, seed_or_die, pick_select   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


ASK_TAIL = "我可以直接基于它跑建模，跳过数据准备。要不要继续？"
PLAIN_TAIL = "分析已经跑完了，结果都在 results/ 目录下。"


def seed_session(db, uid, title, user_txt, asst_txt):
    con = sqlite3.connect(db)
    sid = "probe10-%s" % title
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    con.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    con.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)", (sid, title, now, now, uid))
    con.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)", (sid, "user", user_txt, now))
    con.execute("INSERT INTO messages (session_id, role, content, created_at)"
                " VALUES (?,?,?,?)", (sid, "assistant", asst_txt, now))
    con.commit()
    con.close()
    return sid


def slot(pg):
    """确认槽位那颗按钮的 (文字, 能不能点, 类名)。"""
    return pg.evaluate("""() => {
        var b = document.querySelector('.dsapp-inputbar .dsapp-btn-run,'
                                     + ' #confirm_slot button, .dsapp-actions button');
        if (!b) {
            var all = document.querySelectorAll('button');
            for (var i = 0; i < all.length; i++) {
                var t = (all[i].innerText || '').trim();
                if (t === '确认执行' || t === '继续') { b = all[i]; break; }
            }
        }
        if (!b) return null;
        return { text: (b.innerText || '').trim(),
                 disabled: !!b.disabled,
                 cls: b.className };
    }""")


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    pg = br.new_context(viewport={"width": 1500, "height": 950}).new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:180]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:180])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, db = seed_or_die(email)
    print("登录成功：%s (uid=%s)" % (email, uid), flush=True)
    pg.wait_for_timeout(2500)

    # 先配一把假 Key + 模型 —— 点「继续」要真的走通 dsapp_chat_send 的闸门。
    # 假 Key 会 401，但消息在发请求**之前**就已经落库了。
    print("\n== 先配一把假 Key（点「继续」要能过闸门）==", flush=True)
    if not pg.evaluate("() => { var d = document.querySelector("
                       "'details.dsapp-rail-model'); return d ? d.open : false; }"):
        pg.click("details.dsapp-rail-model > summary")
        pg.wait_for_timeout(1200)
    pg.fill("#model-api_key", "sk-test-not-a-real-key")
    pick_select(pg, "model-vendor", "deepseek")
    pg.wait_for_timeout(800)
    ctrl = pg.locator("xpath=//select[@id='model-model']/following-sibling::div"
                      "[contains(@class,'selectize-control')]")
    ctrl.locator(".selectize-input").click()
    pg.wait_for_timeout(400)
    pg.keyboard.type("deepseek-chat")
    pg.wait_for_timeout(600)
    pg.keyboard.press("Enter")
    pg.wait_for_timeout(800)
    pg.click("#model-commit")
    pg.wait_for_timeout(3000)
    pg.keyboard.press("Escape")
    pg.wait_for_timeout(500)

    sid_ask = seed_session(db, uid, "问句会话", "我想跳过数据准备。", ASK_TAIL)
    sid_plain = seed_session(db, uid, "陈述会话", "跑完了吗？", PLAIN_TAIL)
    print("   种了两条会话：%s / %s" % (sid_ask, sid_plain), flush=True)

    pg.reload()
    pg.wait_for_timeout(4000)
    goto(pg, "chat")
    pg.wait_for_timeout(2500)

    # ---- (a) 陈述式结尾：按钮该是灰的「确认执行」 -------------------------
    print("\n== (a) 陈述式结尾（没有问句）==", flush=True)
    pg.click(".dsapp-sess[data-sid='%s']" % sid_plain)
    pg.wait_for_timeout(3000)
    s = slot(pg)
    print("   按钮：%s disabled=%s" % (s["text"] if s else None,
                                       s["disabled"] if s else None), flush=True)
    C("★★ 还是灰着的「确认执行」（没有问句就不该亮）",
      s is not None and s["text"] == "确认执行" and s["disabled"])

    # ---- (b) 疑问句结尾：必须是一颗能点的「继续」 -------------------------
    print("\n== (b) 疑问句结尾（用户原话那句）==", flush=True)
    pg.click(".dsapp-sess[data-sid='%s']" % sid_ask)
    pg.wait_for_timeout(3500)
    s = slot(pg)
    print("   按钮：%s disabled=%s cls=%s"
          % (s["text"] if s else None, s["disabled"] if s else None,
             s["cls"] if s else None), flush=True)
    C("★★★ 疑问句结尾时，按钮是**能点**的", s is not None and not s["disabled"])
    C("★★★ 文字是「继续」，不是「确认执行」"
      "（写「确认执行」的话用户以为要跑一段他找不到的代码）",
      s is not None and s["text"] == "继续", s["text"] if s else None)
    C("★ 它确实在对话页的确认槽位里（不是页面别处的按钮撞名）",
      s is not None and "dsapp-ask-go" in (s["cls"] or ""), s["cls"] if s else None)

    # ---- (c) 点它 = 真的把「继续」发出去 ----------------------------------
    print("\n== (c) 点「继续」==", flush=True)
    if s is not None and not s["disabled"]:
        pg.click(".dsapp-ask-go")
        pg.wait_for_timeout(4000)
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        rows = con.execute(
            "SELECT role, content FROM messages WHERE session_id = ? "
            "ORDER BY id", (sid_ask,)).fetchall()
        con.close()
        print("   库里这个会话现在有 %d 条：%s"
              % (len(rows), " | ".join("%s:%s" % (r[0], r[1][:16]) for r in rows)),
              flush=True)
        C("★★★ 点下去真的往这个对话里发了一句「继续」",
          len(rows) >= 3 and rows[2][0] == "user" and rows[2][1].strip() == "继续")
        C("★★ 发出去的那句走的是正常路径（用户消息排在助手消息后面，顺序没乱）",
          len(rows) >= 3 and rows[0][0] == "user" and rows[1][0] == "assistant")
    else:
        C("★★★ 点下去真的往这个对话里发了一句「继续」", False, "按钮不可点，跳过了")

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item10_ask.png")
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
