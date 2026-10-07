#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.8 item 3（下半段）：**在对话页里换模型** —— 加的那一格真的能用吗。

用户原话：「现在得对话途中切换模型，是否能够继承上下文继续交流？如果不能，
请增加这个功能」。

`probe_ctx.py` 回答的是前半句（**能继承**，20/20），它走的是"去「模型服务」
页换、再回来"那条老路。这一份测的是 V15.8 新加的那一格：对话页控制条最左边
的「模型」下拉 —— 用户说的"对话途中切换"就是别为了改一个下拉跑一趟。

★ 为什么非要有这一份（不能拿 probe_ctx 代替）：
  probe_ctx 证的是"**机制**没丢历史"，它对"入口在哪儿"一个字都没说。
  而这一格新引入的风险恰恰全在链路上：对话页只说一句话，真正写库的是
  模型页那条老路（**唯一**的写入者）。中间任何一环断了，症状都是
  "下拉选了、看着也变了、下一轮还是旧模型" —— 而那种 bug
  在代码里读着完全正确（本仓：renderui-needs-explicit-invalidation）。

四节：
  A 这一格在不在、显不显示当前模型（"加了"≠"用户看得见"）
  B 选一个新的 → **库里真的变了**（写操作一律回库确认，不看界面）
  C 下一轮出网用的是**新模型**，而且**上下文还在**（这一条才是用户问的）
  D 换完之后离开「模型服务」页**不许**弹「还有改动没确认」
    （snap_one 那一手 —— 服务端自己推下去的值不算用户的改动）

⚠️ 全程 base_url 指着本机假 LLM，一条请求都不会打到真厂商。

★ 已知的**环境**抖动（不是这一格的 bug）：`enter_app` 那一步偶尔会停在
  「注册没进主界面（页面文字 0 字）」。2026-10-02 量到的样子：整跑只用 8.8 秒
  就退出了（不是等满 180 秒），页面停在 `html=109`（= session$reload() 中间那
  张空页），实例那边的 `auth.log` 只有 `cookie 回执 ok，reload`、**没有**随后
  那次「页面加载」—— 也就是说浏览器压根没再请求一次。
  同一天连续 11 次注册（探针 5 跑 + 单独起 6 次）全过，栽的那 4 次**扎堆**在
  几个探针刚崩过/刚退出之后，所以更像是"上一端断得突然、worker 还在收拾"，
  但**没有证据**，别当成结论。栽了重跑即可；日志里那句「现场：{...}」会把
  当时的 url / html 长度 / cookie / 遮罩一并打出来。
"""
import os
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8951/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                          # noqa: E402
from probe_ctx import (relogin, ensure_no_modal, send, reqs_with, sql)  # noqa: E402
from playwright.sync_api import sync_playwright               # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]

NONCE = "816043"           # 第一轮的暗号：第二轮要能在上下文里找到它
SEL = "chat-model_pick"    # ns("model_pick")


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


def key_model(db, uid, vendor):
    """按厂商存的那份副本。库和副本要一起变，不然就是 V15.7 item 8 那个形状。"""
    r = sql(db, "SELECT model FROM user_api_keys WHERE user_id = ? AND vendor = ?",
            (uid, vendor))
    return (r[0][0] or "") if r else ""


def sel_value(page):
    """读 selectize 当前显示的值 —— 读它自己那个假输入框，不是原生 select。

    ⚠️ 原生 <select> 被 selectize 藏起来（0×0）之后里面还是旧值，直接读它
       得到的是一句"看着完全合理的错话"（selectize-hides-options）。
    """
    return page.evaluate(
        """(id) => {
             var c = document.querySelector("select#" + id + " + .selectize-control");
             if (!c) return "<没有 selectize 控件>";
             var it = c.querySelector(".selectize-input > input");
             if (it && it.value) return it.value;
             var d = c.querySelector(".selectize-input > div");
             if (d) return (d.getAttribute("data-value") || d.innerText || "").trim();
             return "";
           }""", SEL)


def pick(page, want):
    """在下拉里选一个值。selectize 的候选只在**打开时**才铺进 DOM。"""
    page.click("select#%s + .selectize-control" % SEL)
    page.wait_for_timeout(400)
    opt = page.locator(".selectize-dropdown .option",
                       has_text=want).first
    opt.click(timeout=8000)
    page.wait_for_timeout(400)


def main():
    os.makedirs(C.OUT, exist_ok=True)
    log = open(os.path.join(C.OUT, "probe_switch.log"), "w")

    t0 = time.time()

    def say(*a):
        # 带时间戳：这个探针第一版连着两跑停在「注册没进主界面」，而那句话
        # 分不出"慢"和"坏" —— 加上秒数才看得出每一步花了多久。
        s = "[%6.1fs] %s" % (time.time() - t0, " ".join(str(x) for x in a))
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    fx = C.FakeLLM()
    say("  假 LLM: %s" % fx.url)

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        # 出错时能看出是**页面**坏了还是服务端没回：空页面 = Shiny 还没连上
        # （UI 是连上之后才画的），而"连不上"和"画得慢"在截图上是同一张纯色图。
        page.on("pageerror", lambda e: say("  **pageerror**: %s" % str(e)[:200]))
        page.on("console",
                lambda m: say("  console.%s: %s" % (m.type, m.text[:200]))
                if m.type == "error" else None)
        email = "v158s_%s@example.com" % str(int(time.time()))[-6:]
        say("注册 %s" % email)
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            # ★ 这一步**间歇性**失败（约三跑一次），而 enter_app 的原话
            #   「页面文字 0 字」分不出三种情况：还在 session$reload() 中间
            #   （正常，空页是设计如此）、连不上、或者根本没重载。
            #   所以把现场一起打出来 —— 尤其是**那个循环到底跑了多久**。
            try:
                d = page.evaluate("""() => ({
                     url: location.href,
                     html: (document.body.innerHTML||"").length,
                     cookie: document.cookie.length,
                     off: (document.querySelector("#dsapp-offline")||{}).dataset
                          ? (document.querySelector("#dsapp-offline")||{}).dataset.kind
                          : null})""")
            except Exception as ee:
                d = {"evaluate": str(ee).splitlines()[0]}
            page.screenshot(path=os.path.join(C.OUT, "00_switch_register.png"),
                            full_page=True)
            sys.exit("注册没进去：%s\n  现场：%s" % (e, d))
        say("进主界面了")
        uid, db = C.seed_or_die(email)
        # 厂商选 zhipu：它的静态清单里 glm-5.3 和 glm-4.5-air **都在**，
        # 所以"换一个"有得选（厂商清单只有一项的话，这一格没什么可测的）。
        C.seed_llm(uid, fx.url, vendor="zhipu", model="glm-5.3")
        say("  uid=%s db=%s 起始模型=glm-5.3 厂商=zhipu" % (uid, db))

        # ★★ 故意把"按厂商记的副本"种成**生产库 uid=11 的那个坏样子**：
        #    库说 glm-5.3，副本却说 deepseek-flash（连厂商都不是同一家）。
        #    这样下面每条断言都同时是一道回归守卫：
        #      A 节：下拉必须显示**库**里的 glm-5.3，不是副本那个名字
        #            （V15.7 item 8 定的主次：库为准）
        #      B 节：换一次模型之后，副本必须被**治好**成新值
        #            （不治的话，用户切走再切回来，模型会自己变回副本那个名字）
        con = __import__("sqlite3").connect(db, timeout=15)
        con.execute("UPDATE user_api_keys SET model = ? WHERE user_id = ? AND vendor = ?",
                    ("deepseek-flash", uid, "zhipu"))
        con.commit()
        con.close()
        # ⚠️ 回读必须在**页面加载之前**做。第一版把这条断言写在 A 节里，结果读到
        #    的是 glm-5.3 —— 因为那一刻应用已经把它治好了。那不是"种失败"，
        #    是"治得比断言还早"，而断言的**顺序**把这两件事混成了一件。
        k_poison = key_model(db, uid, "zhipu")
        chk("★ 前提：种下去的坏副本真的在库里（不在的话下面那条「治好了」白给）",
            k_poison == "deepseek-flash", "副本=[%s]" % k_poison)
        say("  已把副本种成 [deepseek-flash]（uid=11 在生产库里的样子）")
        relogin(page, email)
        C.goto(page, "chat")
        ensure_no_modal(page)
        page.wait_for_timeout(1500)

        # ================= A 这一格在不在 ==================================
        say("\n== A 节：控制条上有没有这一格、显不显示当前模型 ==")
        # ⚠️ 等的是 selectize 那个**控件**（用户看的），不是原生 <select> ——
        #    原生那个被 selectize 藏起来，永远 0×0，`wait_for_selector` 默认
        #    等 visible，会一直等到超时（报错还会把它打印出来，看着像"元素不在
        #    DOM 里"，其实它好好地在那儿）。第一跑就栽在这儿。
        page.wait_for_selector("select#%s + .selectize-control" % SEL,
                                timeout=15000)
        chk("★★★ 对话页控制条上**有**这一格，而且是**看得见**的"
            "（在 DOM 里不算数，藏起来的一样点不着）",
            page.locator("select#%s + .selectize-control" % SEL).is_visible())
        got = sel_value(page)
        chk("★★★ 它显示的就是当前在用的模型 glm-5.3（不是空白、不是别的）",
            got == "glm-5.3", "显示的是 [%s]" % got)

        m0 = sql(db, "SELECT llm_model FROM users WHERE id = ?", (uid,))[0][0]
        chk("★ 前提：库里也是 glm-5.3，base_url 指着假 LLM（出网打不到真厂商）",
            m0 == "glm-5.3" and
            sql(db, "SELECT llm_base_url FROM users WHERE id = ?",
                (uid,))[0][0] == fx.url,
            "库=[%s]" % m0)
        # ★★★ 这一条是**生产库 uid=11 的现场**：他的副本里躺着 deepseek-flash，
        #     而他一个字都还没改。页面一加载，服务端那次防抖保存就把副本刷成
        #     库里的真值 —— 也就是说他**不需要做任何事**，那颗雷自己就拆了。
        #     （证据：这一跑里 k_poison 是真种进去了的，而这里读到的是 glm-5.3。）
        k0 = key_model(db, uid, "zhipu")
        chk("★★★ 用户什么都没做，坏副本已经被治好了（= 库里的 glm-5.3）"
            "（不治的话，他切走再切回来，模型就会自己变成 deepseek-flash）",
            k0 == "glm-5.3", "副本=[%s]" % k0)

        # ================= B 选一个新的 → 库真的变了 ========================
        say("\n== B 节：在对话页选 glm-4.5-air → 库里跟着变 ==")
        try:
            pick(page, "glm-4.5-air")
        except Exception as e:
            say("    选取动作抛了：%s" % e)
        # 防抖 800ms + 落库 + 页面几拍
        page.wait_for_timeout(4000)
        m1 = sql(db, "SELECT llm_model FROM users WHERE id = ?", (uid,))[0][0]
        chk("★★★ 在**对话页**换的模型**写进库了**（界面变了不代表存住了 —— "
            "写操作一律回库确认）", m1 == "glm-4.5-air", "库现在=[%s]" % m1)

        # 按厂商存的那份副本（user_api_keys.model）**必须一起变**。
        #
        # ★★ 第一版这里写的是"副本本来就该陈旧，别拿它跟库比" —— 那是**错的**，
        #    而错得有价值：查生产库时发现 uid=11（qwen 那个账号）
        #    `users.llm_model='qwen3.8-max'` 而 `user_api_keys.qwen.model=
        #    'deepseek-flash'`，连厂商都不是同一家。这份副本只在"用户敲了 Key"
        #    时才写，所以改下拉会把它越落越远；而它在**换厂商那一刻被当成权威**
        #    （mod_model.R 的 observeEvent(input$vendor) 把 recall() 的 model
        #    直接推回下拉）—— 用户切走再切回来，模型就自己变了。
        #
        #    所以这一条现在是**真的断言**：模型变了，副本跟着变。
        k1 = key_model(db, uid, "zhipu")
        chk("★★★ 按厂商记的那份副本**跟着一起变**（它陈旧的话，用户切走再"
            "切回来时模型会自己变成副本里那个旧名字 —— 生产库 uid=11 就是这个"
            "现场：qwen 名下记着 deepseek-flash）",
            k1 == "glm-4.5-air", "副本=[%s]" % k1)

        # ================= C 下一轮出网 ====================================        say("\n== C 节：下一轮真的用新模型，而且上下文还在 ==")
        fx.set_queue(C.sse("收到。第一轮的回答里那个暗号是 %s。" % NONCE))
        fx.slow(0.0)
        send(page, "记住这个暗号：%s。只回一句「记住了」。" % NONCE)
        i1 = reqs_with(fx, NONCE)
        chk("★★ 前提：第一轮的出网请求记上了（不然下面拿什么比）",
            len(i1) > 0, "假服务端收到 %d 条" % fx.req_n())

        fx.set_queue(C.sse("好的，我还记得。"))
        fx.slow(0.0)
        send(page, "刚才那个暗号是什么？")
        i2 = [i for i in reqs_with(fx, NONCE) if i > max(i1)]
        chk("★★★ 第二轮的请求里**带着第一轮的暗号**（换完模型上下文没丢 —— "
            "这就是用户问的那件事）", len(i2) > 0,
            "第二轮的 messages 里找不到 %s" % NONCE)
        last = fx.req_n()
        used = fx.req_body(last).get("model") if last else None
        chk("★★★ 第二轮出网用的是**新模型 glm-4.5-air**（没刷新页面、没重开对话）",
            used == "glm-4.5-air", "出网用的 model=[%s]" % used)

        # ================= D 不许弹「还有改动没确认」 =======================
        say("\n== D 节：换完之后离开「模型服务」页，不该被问「还有改动没确认」==")
        say("  （那一格是**服务端**替用户推下去的，不是他在模型页上敲的）")
        C.goto(page, "模型服务")
        ensure_no_modal(page)
        page.wait_for_timeout(2000)
        # ★★ 顺带证一件更要紧的事：模型页初始化读的是**库**（`saved_model <-
        #    s$model`），而那份按厂商存的副本此刻是**陈旧**的。V15.7 item 8
        #    之前，启动那次 model_choices() 会拿副本里的旧值把下拉顶回去，
        #    下一拍再写回库 —— 用户什么都没干，模型自己变了。这一段就是它的
        #    回归守卫：进过模型页之后，库里的值**不许**被顶回副本那个旧值。
        m2 = sql(db, "SELECT llm_model FROM users WHERE id = ?", (uid,))[0][0]
        chk("★★★ 进了一趟「模型服务」页之后，库里的模型**还是新的**那个"
            "（陈旧副本不许把新值顶回去 —— V15.7 item 8 的回归守卫）",
            m2 == "glm-4.5-air", "库现在=[%s]" % m2)
        shown = page.evaluate(
            """() => { var s = document.querySelector("select#model-model");
                        if (!s) return "<找不到模型下拉>";
                        return s.options.length ? (s.selectedOptions[0]||{}).text || "" : ""; }""")
        say("    模型页下拉此刻显示：[%s]" % shown)

        C.goto(page, "chat")
        page.wait_for_timeout(1500)
        # 判据和 dismiss_unconfirmed() 对齐（`:visible`）：Shiny 的 #shiny-modal
        # 不一定在弹的时候才进 DOM，只看"存不存在"会把一个隐藏的壳判成弹窗。
        nvis = page.locator("#shiny-modal:visible").count()
        chk("★★★ 离开模型服务页**没有**弹「模型改了还没确认」"
            "（snap_one 那一手：服务端推下去的值不算用户的改动）", nvis == 0,
            "弹窗还在：" + (page.evaluate(
                "() => (document.querySelector('#shiny-modal')||{}).innerText||''"
            ) or "")[:80])

        b1 = sql(db, "SELECT llm_base_url FROM users WHERE id = ?", (uid,))[0][0]
        chk("★★ 全程 base_url 没被改走（一条请求都没打给真厂商）", b1 == fx.url,
            "base_url=[%s]" % b1)

        browser.close()

    say("\n== 通过 %d / 失败 %d ==" % (N_OK[0], N_BAD[0]))
    log.close()
    fx.stop()
    sys.exit(0 if N_BAD[0] == 0 else 1)


if __name__ == "__main__":
    main()
