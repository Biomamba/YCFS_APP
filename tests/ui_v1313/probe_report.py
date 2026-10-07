# -*- coding: utf-8 -*-
"""V13.13 item 21：点「总结并生成报告」先弹一窗选格式。

    bash tests/ui_v7/make_instance.sh 8914 /tmp/dsapp_v1313
    python3 /tmp/mock_llm.py 8932 0.02 4     # 快版假模型，见下
    python3 tests/ui_v1313/probe_report.py

用户原话：「点击生成报告时可以选格式：html、ppt、word或其它用户自己填写的
内容」。

⚠️ 为什么这一条要用一个**快**的假模型（间隔 0.02 秒 / 4 块）而不是
   /tmp/mock_llm.py 默认那个：这一页要连着发三次报告，而 `dsapp_chat_send()`
   在 rv$streaming 为真时会把后面的请求挡回去（"正在生成中"）。默认那个假
   服务一次要吐 40 块 × 0.35 秒 ≈ 14 秒，三次就是 40 多秒，而且中间那次被挡
   下来时症状是**"第二个气泡没出现"** —— 看起来像格式选择坏了。

⚠️ 开跑之前这个对话里**必须先有一句话**：`report_btn` 上那道
   「这个对话还没保存，先随便发一句话再试」的闸门是 V13.10 就有的，它挡的
   是 rv$session_id 为空的**新对话**。跳过这一步的话，点按钮什么都不会弹，
   看起来像 item 21 坏了 —— 而真人要生成报告时对话里必然已经有内容。

判据分四组：
  (a) **弹窗长什么样**：四个选项、标签是中文、默认选 HTML；
  (b) **选了就按选的走**：选 Word 之后发出去的那条消息里写的是 .docx，
      不是 .html —— 这是"选项接没接上"的唯一证据；
  (c) **「其它」那一格**：选了才出现；不填会被拦（弹提示 + 弹窗**不关**）；
      填了就原样带进消息里；
  (d) **重新打开**：第二次点按钮，那一格还能再出现一次。
      ⚠️ (d) 是最容易坏的一条：自定义格是 renderUI 出来的，弹窗关掉时
      那个 output 被移除、再打开是一块**新的** DOM。Shiny 要重新渲染它才会
      有内容 —— 不重渲染的话，用户第二次选「其它」，输入框**不见了**，
      而且不报任何错。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8914/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1313/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1313")

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

MOCK = "http://127.0.0.1:8932/v1"
LABELS = ["HTML 网页", "Word 文档", "PPT 演示", "其它（自己填）"]


def modal(pg):
    m = pg.locator(".modal.show")
    return m.first if m.count() else None


def modal_open(pg):
    return pg.locator(".modal.show").count() > 0


def labels(pg):
    """弹窗里四个选项的**显示文字**（读 label，不是 value）。"""
    return pg.eval_on_selector_all(
        ".modal.show .shiny-options-group label",
        "els => els.map(e => e.innerText.trim())")


def pick(pg, value):
    pg.locator(".modal.show input[name='chat-report_fmt'][value='%s']" % value)\
      .first.check(force=True)
    pg.wait_for_timeout(900)


def custom_box(pg):
    b = pg.locator("#chat-report_custom")
    return b.first if b.count() and b.first.is_visible() else None


def bubbles(pg):
    return pg.locator(".dsapp-msg-user .dsapp-bubble")


def last_bubble(pg):
    b = bubbles(pg)
    return b.last.inner_text() if b.count() else ""


def wait_idle(pg, timeout=25):
    """等这一轮生成结束 —— 否则下一条会被"正在生成中"挡回去。"""
    for _ in range(timeout * 4):
        if not pg.locator("#chat-stop").count() or \
           not pg.locator("#chat-stop").first.is_visible():
            return True
        pg.wait_for_timeout(250)
    return False


def notes(pg):
    return pg.eval_on_selector_all(".shiny-notification",
                                   "els => els.map(e => e.innerText)")


def main():
    k = C.Chk()
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1600, "height": 950})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: errs.append(m.text)
              if m.type == "error" else None)
        e = C.enter_app(pg)
        C.seed_or_die(e)

        # ---- 先配好模型服务，否则 dsapp_chat_send() 在闸门那关就返回了，
        #      一条气泡都不会有（而症状看起来像"格式选择坏了"）。
        C.goto(pg, "model")
        pg.fill("#model-api_key", "sk-mock")
        pg.fill("#model-base_url", MOCK)
        pg.wait_for_timeout(1200)
        pg.locator("#model-commit").click()
        for _ in range(30):
            pg.wait_for_timeout(500)
            if "mock-slow" in pg.inner_html("#model-model + .selectize-control",
                                            timeout=5000):
                break
        pg.wait_for_timeout(1200)
        C.goto(pg, "chat")
        pg.wait_for_timeout(2000)

        # ---- 先用一句话把对话建出来 --------------------------------------
        # ⚠️ 这一步不是走过场。`report_btn` 上有 V13.10 就有的那道闸门：
        #    rv$session_id 为空时它弹的是「这个对话还没保存，先随便发一句话
        #    再试」，**根本不弹格式窗**。而 rv$session_id 只在"发出第一条
        #    消息"或"登录后自动打开上次的对话"时才被写上（mod_chat.R:3585
        #    和 :1046）—— 一个刚注册、从没说过话的账号两样都没有。
        #    跳过这一步的话，症状是"点按钮没反应"，看起来像 item 21 坏了，
        #    其实是我们自己没按真实路径走：真人要生成报告时，对话里必然
        #    已经有内容了。
        nb = pg.locator("#chat-new_chat")
        if nb.count():
            nb.first.click()
            pg.wait_for_timeout(2000)
        # 模型得是假服务里那个 id，否则这一句会打到真厂商
        if pg.locator("#chat-model").count():
            C.pick_select(pg, "#chat-model", "mock-slow")
        pg.fill("#chat-input", "先随便聊一句，把这条对话建出来")
        pg.wait_for_timeout(500)
        pg.locator("#chat-send").first.click()
        k("★ 开场那句话发完了（后面才有对话可总结）", wait_idle(pg))

        # ---- (a) 弹窗长什么样 --------------------------------------------
        pg.click("#chat-report_btn")
        pg.wait_for_timeout(1500)
        k("★★★ 点「总结并生成报告」先弹一窗（不再直接开始生成）", modal_open(pg))
        if not modal_open(pg):
            b.close()
            return k.done()

        k("★★★ 四个选项都在，而且标签是中文的那四个",
          labels(pg) == LABELS, "%r" % (labels(pg),))
        val = pg.eval_on_selector(
            ".modal.show input[name='chat-report_fmt']:checked",
            "el => el.value") if pg.locator(
                ".modal.show input[name='chat-report_fmt']:checked").count() else "?"
        # ⚠️ 查的是 **value**（送到服务端的那个），不是标签。V13.12 的默认是
        #    html，item 21 加的是"能选"，不是改默认值。
        k("★★★ 默认选中的是 html（item 21 加的是「能选」，不是改默认）",
          val == "html", "实际 %r" % val)
        k("★★ 没选「其它」时，自填那一格不占地方",
          custom_box(pg) is None)

        # ---- 取消：什么都不该发生 ----------------------------------------
        n0 = bubbles(pg).count()
        pg.locator(".modal.show button[data-dismiss='modal']").first.click()
        pg.wait_for_timeout(1500)
        k("★★★ 点「取消」弹窗关掉", not modal_open(pg))
        k("★★★ 而且没有多出一条消息（取消就是取消）",
          bubbles(pg).count() == n0, "%d -> %d" % (n0, bubbles(pg).count()))

        # ---- (b) 选 Word → 生成 -------------------------------------------
        pg.click("#chat-report_btn")
        pg.wait_for_timeout(1200)
        pick(pg, "docx")
        pg.click("#chat-report_go")
        pg.wait_for_timeout(2500)
        k("★★★ 点「生成」之后弹窗自己关掉", not modal_open(pg))
        t = last_bubble(pg)
        k("★★★ 发出去的那条消息里写的是 分析报告.docx（格式真的接上了）",
          "分析报告.docx" in t, t[-160:].replace("\n", " "))
        # ⚠️ 反向那半同样重要：界面选的是 Word，提示词里就不该还留着 html
        #    那份要求 —— 两份都写进去的话模型会**挑一个**，而挑哪个看运气。
        k("★★★ 同一句话里不再出现 分析报告.html（两份要求会打架）",
          "分析报告.html" not in t)
        k("★★★ Word 那条做法也在（pandoc 命令 + 禁掉 python-docx）",
          "pandoc 报告正文.md -o 分析报告.docx" in t and "python-docx" in t)
        k("★ 这一轮生成正常收尾（下一轮不会被「正在生成中」挡住）",
          wait_idle(pg))

        # ---- (c) 「其它」：不填要拦得住 -----------------------------------
        pg.click("#chat-report_btn")
        pg.wait_for_timeout(1200)
        pick(pg, "other")
        k("★★★ 选了「其它」→ 自填那一格出现了", custom_box(pg) is not None)
        n1 = bubbles(pg).count()
        pg.click("#chat-report_go")
        pg.wait_for_timeout(1800)
        k("★★★ 一个字没填就点「生成」→ 被拦住（弹提示）",
          any("其它" in x for x in notes(pg)), "%r" % (notes(pg),))
        k("★★★ 而且**弹窗还开着**（不然用户得从头再点一遍）", modal_open(pg))
        k("★★★ 也没有偷偷按 html 发出去", bubbles(pg).count() == n1,
          "%d -> %d" % (n1, bubbles(pg).count()))

        # ---- 填上再生成 ---------------------------------------------------
        pg.fill("#chat-report_custom", "一份可以直接贴进公众号的图文")
        pg.wait_for_timeout(600)
        pg.click("#chat-report_go")
        pg.wait_for_timeout(2500)
        k("★★★ 填了之后能发出去，弹窗关掉", not modal_open(pg))
        t2 = last_bubble(pg)
        k("★★★ 用户自己写的那句话原样进了提示词",
          "一份可以直接贴进公众号的图文" in t2, t2[:120].replace("\n", " "))
        k("★★ 自填那一格还带上了「做不了就直说」那条红线",
          "PDF 出不来" in t2 and "后缀名" in t2)
        wait_idle(pg)

        # ---- (d) 重新打开：那一格还得能再出现一次 -------------------------
        pg.click("#chat-report_btn")
        pg.wait_for_timeout(1500)
        k("★★ 重开弹窗时默认又回到 html（不是记着上次的「其它」）",
          pg.eval_on_selector(
              ".modal.show input[name='chat-report_fmt']:checked",
              "el => el.value") == "html")
        pick(pg, "other")
        k("★★★ 第二次选「其它」，自填那一格**又出现了**（renderUI 重渲染）",
          custom_box(pg) is not None,
          "弹窗 HTML：%s" % pg.inner_html(".modal.show")[:200])
        pg.locator(".modal.show button[data-dismiss='modal']").first.click()
        pg.wait_for_timeout(1000)

        k("没有 JS 报错", not errs, "; ".join(errs[:3]))
        pg.screenshot(path=os.path.join(C.OUT, "report_after.png"), full_page=True)
        b.close()
    return k.done()


if __name__ == "__main__":
    sys.exit(main())
