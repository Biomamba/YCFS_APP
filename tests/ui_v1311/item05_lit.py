# -*- coding: utf-8 -*-
"""V13.11 item 5 验收：文献速递版块。

    bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311
    /home/biomamba/miniconda3/bin/python tests/ui_v1311/item05_lit.py

用户原话：「加一个"文献速递"版块，请帮我写好内置提示词，并且可以关联一些
文献整理的开源 skills，可以通过输入一系列关键词，自动返回最相关的 n 篇
文献精读/略读」。

追问"检索怎么做"，选的是「交给 agent 用命令行检索」—— 所以这一条验的是
**这一页把条件收对了、提示词拼对了、活真的交给了对话页**，不验检索结果
（那要真联网、真花 token，是 e2e 不是 UI 验收）。

★ 为什么不只跑 selftest：那边验的是 dsapp_lit_prompt() 拼出来的字符串。
这一条验的是**这一页真的长成了那个样子** —— 关键词切出来几个、勾选框有没有
默认勾上、点「开始检索」之后是不是真的切到了对话页且新对话里躺着那条消息。
"""
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import enter_app, goto, seed_or_die, pick_select  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    ctx = br.new_context(viewport={"width": 1600, "height": 950})
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:200])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, _ = seed_or_die(email)
    print("uid=%s" % uid, flush=True)
    pg.wait_for_timeout(3000)

    print("\n== 左栏有「文献速递」，点得进去 ==", flush=True)
    navs = pg.eval_on_selector_all(
        ".dsapp-rail-link", "els => els.map(e => e.getAttribute('data-nav'))")
    C("★★★ 左栏有 value=lit 的导航项", "lit" in navs, str(navs))
    goto(pg, "lit", wait=3500)
    C("★★ 切过去之后那一页真的激活了",
      pg.eval_on_selector(".dsapp-rail-link.active",
                          "e => e.getAttribute('data-nav')") == "lit")

    print("\n== 关键词的分割（这页最容易悄悄出错的地方） ==", flush=True)
    # 换行 + 中文逗号 + 顿号 + 中英分号混着来，模拟用户从别处粘一串进来
    pg.fill("#lit-kw", "空间转录组，肝癌\n免疫微环境、single cell RNA; PD-1")
    pg.wait_for_timeout(1200)
    chips = pg.eval_on_selector_all(
        ".dsapp-lit-chip", "els => els.map(e => e.innerText.trim())")
    print("   切出来：%s" % chips, flush=True)
    C("★★★ 四种分隔符都认（逗号/换行/顿号/分号）", len(chips) == 5, str(chips))
    C("★★★ 带空格的关键词**没有被切开**（single cell RNA 是一个词）",
      "single cell RNA" in chips, str(chips))
    C("★ 切出来的词都去皮了（没有前导空格）",
      all(c == c.strip() for c in chips), str(chips))

    print("\n== 技能勾选：默认勾上「文献速递」 ==", flush=True)
    boxes = pg.eval_on_selector_all(
        "input[name='lit-skills']",
        "els => els.map(e => ({v: e.value, on: e.checked, "
        "t: e.parentElement.innerText.trim()}))")
    on = [b["t"] for b in boxes if b["on"]]
    names_all = [b["t"] for b in boxes]
    print("   共 %d 条，默认勾上：%s" % (len(boxes), on), flush=True)
    # ⚠️★ 这一段**改过**（V13.12 item 14 + item 16），别照着 V13.11 的说法
    #    修回去。V13.11 时默认勾的是自撰的那一条「文献速递」；V13.12 换成了
    #    上游那两条（academic-search / deeppapernote，见 DSAPP_LIT_SKILL_NAMES），
    #    而且 item 16 之后**勾上的会被提到最前面**（用户原话：
    #    「文献速递已关联的技能请显示在最上方」）。
    #    所以判据从"on == ['文献速递']"变成下面三条 —— 少一条都会漏掉
    #    "默认勾对了但没排在最上面"（那正是 item 16 要修的那个毛病）。
    C("★★★ 默认勾的是上游那两条检索/阅读技能",
      sorted(on) == ["academic-search", "deeppapernote"], str(on))
    C("★★★ 勾上的排在最前面（item 16：已关联的技能显示在最上方）",
      bool(on) and names_all[:len(on)] == on, str(names_all[:4]))
    C("★★ 内置技能都在可选列表里（不止一条）", len(boxes) >= 5, str(len(boxes)))
    sums = pg.inner_text(".dsapp-lit-sums")
    C("★ 勾上的那条把简介显示出来了（用户知道它是干什么的）",
      "文献" in sums or "检索" in sums, sums.replace("\n", " ")[:60])

    print("\n== 提示词预览 ==", flush=True)
    C("★ 没点之前不显示预览框",
      pg.locator(".dsapp-lit-preview").count() == 0)
    pg.click("#lit-peek")
    pg.wait_for_timeout(1200)
    prev = pg.inner_text(".dsapp-lit-preview")
    print("   预览前 160 字：%s" % prev[:160].replace("\n", " "), flush=True)
    C("★★★ 预览里带上了填的篇数（3 篇精读 / 5 篇略读）",
      "3 篇精读" in prev and "5 篇略读" in prev, prev[:80].replace("\n", " "))
    C("★★★ 预览里带上了刚填的关键词",
      "空间转录组" in prev and "single cell RNA" in prev)
    C("★★ 预览里写了要去哪些库查（Europe PMC / PubMed）",
      "Europe PMC" in prev and "PubMed" in prev)
    C("★★ 预览里带上了年份限制", "2021" in prev or "只看" in prev)
    C("★★ 提示词明确要求「不许编」和「摘要不等于全文」",
      "不许编" in prev and "摘要" in prev)
    pg.click("#lit-peek_close")
    pg.wait_for_timeout(800)
    C("★ 关得掉（再点一次就收起）",
      pg.locator(".dsapp-lit-preview").count() == 0)

    # ★★ 先验「发不出去的那条路」。
    #
    #    这个账号此刻**没配 Key**，所以 dsapp_chat_send 会在闸门那里被拦下。
    #    这正是刚写的那段回收逻辑要处理的场景：拦下之后，刚才为了这次检索
    #    建出来的那个空对话必须**收回去**，不能留在列表里。
    #
    #    ⚠️ 这条以前验不到，是因为 dsapp_chat_send() 过去不返回任何东西
    #       （return() 全是裸的），调用方无从知道到底发没发出去。
    print("\n== 没配 Key 时点「开始检索」：拦下来，且不留空对话 ==", flush=True)
    import sqlite3
    db = db_path()

    def session_count():
        c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        n = c.execute("SELECT COUNT(*) FROM sessions WHERE user_id = ?",
                      (uid,)).fetchone()[0]
        c.close()
        return n

    before = session_count()
    pg.fill("#lit-kw", "空间转录组")
    pg.wait_for_timeout(600)
    pg.click("#lit-go")
    pg.wait_for_timeout(7000)
    after = session_count()
    print("   对话数：%d -> %d" % (before, after), flush=True)
    C("★★★ 发不出去时把刚建的对话收回去了（没留下空对话）",
      after == before, "%d -> %d" % (before, after))
    C("★★ 还是切到了对话页（用户看得见提示，不是点完没反应）",
      pg.eval_on_selector(".dsapp-rail-link.active",
                          "e => e.getAttribute('data-nav')") == "chat")
    # 拦下来之后弹的那个「还不能开始对话」框。⚠️ **必须关掉**：它是 modal，
    # 开着的话后面每一次点击都会被它截走，报的是
    # "subtree intercepts pointer events" —— 指向的是模型服务那个下拉，
    # 而真正的原因是这个框还开着。第一版就是栽在这儿。
    C("★★ 弹了「还不能开始对话」（用户知道该去配 Key）",
      pg.locator("#shiny-modal").count() > 0
      and "还不能开始对话" in pg.inner_text("#shiny-modal"))
    pg.click("#shiny-modal .modal-footer button:has-text('稍后再说')")
    pg.wait_for_timeout(1500)
    C("★ 框关得掉", pg.locator("#shiny-modal").count() == 0)

    # ★★ 再配上一把（假的）Key 和模型，走通"真的发出去"那条路。
    #
    #    ⚠️ Key 在库里是**加密**存的（走 dsapp_api_key_put 那条路），
    #    所以不能拿 sqlite3 直接写 —— 只能像用户那样在「模型服务」里填。
    #    填的是假 Key：下面那次请求会 401，但**消息在这之前就已经落库了**
    #    （见 dsapp_chat_send 的顺序：先 db_message_add，再 dsapp_llm_begin），
    #    这条断言要验的正是"消息进没进库"。
    print("\n== 配好 Key 和模型，再点一次 ==", flush=True)
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
    print("   模型栏 = %r" % pg.input_value("#model-model"), flush=True)

    goto(pg, "lit", wait=3000)
    pg.fill("#lit-kw", "空间转录组")
    pg.wait_for_timeout(600)
    pg.click("#lit-go")
    pg.wait_for_timeout(12000)

    C("★★★ 自动切回了「言出法随」那一页",
      pg.eval_on_selector(".dsapp-rail-link.active",
                          "e => e.getAttribute('data-nav')") == "chat",
      pg.eval_on_selector(".dsapp-rail-link.active",
                          "e => e.getAttribute('data-nav')"))

    # ★★ 这一段**查库**，不读页面文字。
    #
    #    ⚠️ 踩过的坑：`pg.inner_text(".dsapp-page")` 取的是 DOM 里**第一个**
    #    `.dsapp-page`。而 navset_hidden 是"所有页都留在 DOM 里、只藏不激活"
    #    （见 _common.goto 的说明），第一个正是**文献速递那一页自己** ——
    #    于是"新对话里有提示词"这条断言，比的是把条件填进去的那一页，
    #    它当然一直绿。断言和被测对象根本不是同一个东西，而它永远不会红。
    #
    #    消息到底进没进库，只有库知道。注册时 _common 已经拿到了数据目录，
    #    这里直接开只读连接问一句。
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    row = con.execute(
        "SELECT s.id, s.title FROM sessions s WHERE s.user_id = ? "
        "ORDER BY s.created_at DESC LIMIT 1", (uid,)).fetchone()
    print("   新对话：%s" % (row,), flush=True)
    C("★★★ 真的新建了一个对话，标题带关键词",
      row is not None and "空间转录组" in (row[1] or ""), str(row))
    msgs = con.execute(
        "SELECT role, content FROM messages WHERE session_id = ? "
        "ORDER BY id", (row[0],)).fetchall() if row else []
    print("   消息数 = %d，第一条角色 = %s"
          % (len(msgs), msgs[0][0] if msgs else "-"), flush=True)
    C("★★★ 新对话里躺着一条 user 消息，就是刚拼的那段提示词",
      bool(msgs) and msgs[0][0] == "user"
      and "空间转录组" in msgs[0][1] and "Europe PMC" in msgs[0][1],
      (msgs[0][1][:80].replace("\n", " ") if msgs else ""))
    # 技能挂上了没有（用户要的「关联文献整理的开源 skills」）
    sk = con.execute(
        "SELECT k.name FROM session_skills ss JOIN skills k ON k.id = ss.skill_id "
        "WHERE ss.session_id = ?", (row[0],)).fetchall() if row else []
    names = [x[0] for x in sk]
    print("   挂上的技能：%s" % names, flush=True)
    # ⚠️★ 同上：V13.12 起默认那两条是 academic-search / deeppapernote。
    #    这里判的是"**勾上的那些**一条不差地挂上了新对话"，不再写死名字 ——
    #    写死名字的版本在默认值一改之后就只会在这一行红，而红的意思到底是
    #    "没挂上"还是"默认值换了"分不出来。
    C("★★★ 勾选的那几条技能真的挂到了新对话上",
      sorted(names) == sorted(on), "%s vs %s" % (names, on))
    con.close()

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item5_lit.png", full_page=True)
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
