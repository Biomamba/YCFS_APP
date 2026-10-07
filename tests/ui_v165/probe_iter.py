# -*- coding: utf-8 -*-
"""V16.5 item 1：**轮数滑块搬回「自动执行」那一格，而且跟着「开启」走**。

用户原话（2026-10-05）：

    「轮数似乎应该是在自动执行界面，自动执行打开应该就不设置轮数，
      不打开则弹出轮数设置」

两句话各是一半，探针也得**分两半**量：
  · 位置 —— 它在 `.dsapp-ctrl-agent` 那一格里（不是 V16.3 时的
    `.dsapp-ctrl-unlim`）。这一半只有量 DOM 包含关系才分得出来：源码上
    `uiOutput(ns("iter_w"))` 这个字符串在两种位置里一模一样。
  · 联动 —— 「开启」勾上 → 滑块**整个不在 DOM 里**（不是藏起来），而且
    那一格的小字改成「不限轮数」；取消勾 → 滑块回来，值还是刚才那个数。

⚠️ 为什么非要有浏览器探针（`selftest.R` 里已经有 grep）：
   selftest 能证明 `output$iter_w` 里写着 `if (agent_mode_now()) return(NULL)`，
   **证明不了**用户勾上去之后它真的消失了 —— 而这两件事在本仓分家过不止
   一次（见 memory：selftest-green-is-not-coverage）。

★★ 最关键的一条是 ③ 里那句小字，它比"滑块没了"硬得多：
   `output$ctrl_notes` 里那个 `不限轮数 / 最多 N 轮` 是从 **agent 对象** 上
   读的（`it <- a$max_iter`），**不是**从勾上读的。所以它同时钉住了
   「勾一下真的把 a$max_iter 改成 Inf 了」—— 也就是
   `observeEvent(input$agent_mode, ...)` 那一刀。
   少了那一刀的话：界面显示"不限轮数"、agent 还停在滑块那个数上，
   跑满就停，还会往对话里写一句「已经用满了这次给的轮数」。
   ⚠️ 所以 ② 要先**把滑块拖到别的值**，③ 才分辨得出来 —— 不拖的话
   a$max_iter 默认就是 6，而"最多 6 轮"和"不限轮数"本来就不一样，
   但拖到 10 之后，"最多 10 轮"这个错法会**当场现形**。

⑤ 是真跑一轮（假 LLM + 一段能跑的代码）：状态条上那个分母是**循环自己**
   报的（`a$status()$max_iter`）。这是"Inf 真的传到了循环里"的唯一证据 ——
   前面几条量的都是界面读同一个字段。

跑法：
    bash tests/ui_v7/make_instance.sh 8974 /tmp/dsapp_v165a
    python3 tests/ui_v165/probe_iter.py            # 退出码 0 = 全绿
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT


# ---------------------------------------------------------------------------
# 量轮数滑块：它在不在、在**哪一格里**、小字写着几轮
#
# ⚠️⚠️ 判"滑块还在不在"**不能**查 `#chat-agent_iter` 的矩形：Shiny 的
#    sliderInput 画出来的是 ionRangeSlider，那个 <input> 被加上了
#    `.irs-hidden-input`（宽高都是 0）—— 它在的时候矩形也是全 0，
#    拿它当判据的话「滑块没了」和「滑块在」**读到的是同一个东西**，
#    而且这一条会永远是绿的（本仓老账 hidden-element-has-zero-rect 的
#    镜像：那边是"看不见的也有矩形"，这边是"看得见的矩形是 0"）。
#    所以一律量 `.irs`（真正画出来的那个壳）和它外面的 `.dsapp-iter-slider`。
# ---------------------------------------------------------------------------
JS_ITER = r"""
() => {
  const box = document.querySelector('.dsapp-ctrl-agent .dsapp-iter-slider');
  const unlim = document.querySelector('.dsapp-ctrl-unlim');
  const agent = document.querySelector('.dsapp-ctrl-agent');
  const lab = document.getElementById('chat-iter_label');
  const out = {
    slider: !!box,                       // 那一整块（滑块 + 小字）在不在
    in_agent: false, in_unlim: false,    // 在哪一格里（DOM 包含关系）
    irs: false, w: 0, h: 0,
    label: lab ? (lab.innerText || '').trim() : null,
    notes: (document.getElementById('chat-ctrl_notes') || {}).innerText || '',
    // 这一格里**所有**的数字控件（防"滑块没了但别处又冒出一个"）
    n_irs_in_agent: document.querySelectorAll(
        '.dsapp-ctrl-agent .irs--shiny').length,
    foot: ((document.body.innerText.match(/Test_V[0-9.]+/) || [])[0]) || ''
  };
  if (box) {
    if (agent) out.in_agent = agent.contains(box);
    if (unlim) out.in_unlim = unlim.contains(box);
    const irs = box.querySelector('.irs');
    if (irs) {
      const r = irs.getBoundingClientRect();
      out.irs = true; out.w = Math.round(r.width); out.h = Math.round(r.height);
    }
  }
  return out;
}
"""


def iter_state(pg):
    return pg.evaluate(JS_ITER)


def drag_iter(pg, dx):
    """把轮数滑块的把手往右拖 dx 像素。

    ⚠️⚠️ 先 `scroll_into_view_if_needed()`。控件在视口外的时候 mouse 事件
      **无人接收**，而 `bounding_box()` 照样返回正数、全程不报错 ——
      症状是"第一次拖不动、第二次又能动"（本仓老账
      playwright-drag-below-the-fold）。
    """
    handle = pg.locator(".dsapp-ctrl-agent .dsapp-iter-slider .irs-handle").first
    if handle.count() == 0:
        return False
    handle.scroll_into_view_if_needed()
    pg.wait_for_timeout(400)
    b = handle.bounding_box()
    if not b:
        return False
    x, y = b["x"] + b["width"] / 2.0, b["y"] + b["height"] / 2.0
    pg.mouse.move(x, y)
    pg.mouse.down()
    pg.mouse.move(x + dx, y, steps=15)
    pg.mouse.up()
    pg.wait_for_timeout(1800)
    return True


def relogin(pg, email):
    """reload 之后把自己弄回主界面（从 tests/ui_v154/probe_v154.py 搬来）。

    ★ 为什么非 reload 不可：`state$base_url / model` 是**会话级**的，在
      mod_model 的 observe 里从库里读一次。种完假 LLM 不 reload 的话，
      这个已经活着的会话手里还是老值（空 base_url → 厂商默认地址 →
      **真厂商**，2026-10-02 真这么打出去过一条）。

    ⚠️⚠️ 这里**不能**用 wait_awake()：它只认 `.dsapp-auth`，而 reload 时
      cookie 还在 —— 应用直接进主界面，登录页一帧都不出现。拿它等 =
      等一个永远不会来的东西（fake-wait-is-not-a-wait 的又一个形状）。
    """
    pg.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if pg.locator(".dsapp-shell").count():
            return True
        if not submitted and pg.locator("#welcome-email").count():
            pg.fill("#welcome-email", email)
            pg.fill("#welcome-password", C.PW)
            pg.click("#welcome-do_login")
            submitted = True
        pg.wait_for_timeout(1000)
    pg.screenshot(path=OUT + "/01_relogin_failed.png", full_page=True)
    return False


JS_PREF_SAVE = "#chat-agent_pref_save"      # 「就按这个来」= 按当前勾选状态存


def close_pref_modal(pg, timeout=20, save=True):
    """关掉「AI 怎么干活？」那个首选项弹窗，**保留**刚勾上的「自动执行」。

    ⚠️ 和 `C.ensure_no_modal()` 的区别只有按哪个按钮，后果正好相反：
       那个函数点「都先别开」→ 里面有一句
       `updateCheckboxInput(session, "agent_mode", value = FALSE)` ——
       把刚勾上的开关**弹回去**，于是本节要量的那句「不限轮数」跟着消失，
       而且是**异步**消失的，量到哪一步全看时序。

    ⚠️ 必须等弹窗**真的出现**再点：`showModal` 要走一个服务端来回，
       刚点完勾的那一瞬间弹窗还没到，"现在就看不见 → 直接返回成功"的写法
       会当场放行，弹窗随后才冒出来压住整页 —— 症状是十几行之后
       一次 click 等满 30 秒超时，报的是「被 #shiny-modal 挡住」。
    """
    end = time.time() + timeout
    while time.time() < end:
        if pg.locator("#shiny-modal:visible").count() == 0:
            return True
        b = pg.locator(JS_PREF_SAVE if save else "#chat-agent_pref_manual")
        if b.count():
            b.first.click()
            pg.wait_for_timeout(1500)
            continue
        pg.wait_for_timeout(300)
    return pg.locator("#shiny-modal:visible").count() == 0


def set_agent_mode(pg, on):
    """勾 / 取消「开启」，并把随之而来的首选项弹窗处理掉。"""
    cb = pg.locator("#chat-agent_mode")
    if cb.count() == 0:
        return False
    if on and not cb.first.is_checked():
        cb.first.check()
    elif not on and cb.first.is_checked():
        cb.first.uncheck()
    else:
        return True
    pg.wait_for_timeout(2000)          # 等弹窗真的到（见 close_pref_modal）
    close_pref_modal(pg)
    pg.wait_for_timeout(2500)
    return True


def sse_chunks(parts, finish="stop"):
    """把回复切成**好几个** SSE 事件块吐出去。

    ★ 为什么需要：状态条上那个「第 N/M 轮」只在**正在跑**的时候画，整段
      回复一个事件块就吐完的话，采样窗口只有几十毫秒 —— 采不到就会
      **因为没采样而通过**（本仓栽过的"假绿"，见
      mutation-must-change-behavior）。
    """
    import json as _j

    out = ""
    for p in parts:
        out += "data: " + _j.dumps({"choices": [{"delta": {"content": p},
                                                 "finish_reason": None}]}) + "\n\n"
    out += "data: " + _j.dumps({"choices": [{"delta": None,
                                             "finish_reason": finish}]}) + "\n\n"
    return out + "data: [DONE]\n\n"


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1500, "height": 1000})
        pg = ctx.new_page()
        ck = C.Chk()
        try:
            email = C.enter_app(pg)
            uid, db = C.seed_or_die(email)
            C.goto(pg, "chat")
            C.ensure_no_modal(pg)          # 新账号第一次开对话的那个弹窗
            pg.wait_for_selector(".dsapp-ctrl-bar", timeout=30000)
            pg.wait_for_timeout(2000)

            st = iter_state(pg)

            # =================================================================
            print("\n=== ⓪ 连的是不是这一版的实例 ===", flush=True)
            # =================================================================
            # ★ 连错实例的错法是**看起来像测试全绿**（真跑通了，只是跑的
            #   是别人）—— ui_v14 → ui_v1316 那一次差点这么漏过去。
            ck("⓪ 页脚写的是 Test_V16.5（连错实例的话这一条先响）",
               st["foot"] == "Test_V16.5", "页脚是 %r" % st["foot"])

            # =================================================================
            print("\n=== ① 位置：轮数在「自动执行」那一格里（不是在「不设上限」里）===",
                  flush=True)
            # =================================================================
            ck("① （前置）「自动执行」这个勾此刻是**没勾**的（用户原话的那个状态）",
               not pg.locator("#chat-agent_mode").first.is_checked())
            ck("① （前置）轮数那一块在页面上，而且真的画出来了（矩形非零）",
               st["slider"] and st["irs"] and st["w"] > 0 and st["h"] > 0,
               "slider=%s irs=%s w=%s h=%s" % (st["slider"], st["irs"],
                                               st["w"], st["h"]))
            ck("① ★ 它在 `.dsapp-ctrl-agent`（「自动执行」那一格）**里面**",
               st["in_agent"], "in_agent=%s" % st["in_agent"])
            # 反向才是这一条的重点：只钉正向的话，"两边各画一个"照样绿 ——
            # 而用户会看到同一排里有两根轮数滑块。
            ck("① ★ 反过来：它**不在** `.dsapp-ctrl-unlim`（V16.3 时它在那儿）里",
               not st["in_unlim"], "in_unlim=%s" % st["in_unlim"])
            ck("① 「自动执行」那一格里只有**一根**滑块（不是搬过去 + 留一份）",
               st["n_irs_in_agent"] == 1, "irs 个数=%s" % st["n_irs_in_agent"])
            ck("① 小字写着「6 轮」（默认值来自 DSAPP_AGENT_MAX_ITER）",
               st["label"] == "6 轮", "小字是 %r" % st["label"])
            pg.locator(".dsapp-ctrl-bar").screenshot(path=OUT + "/iter_off.png")

            # =================================================================
            print("\n=== ② 先把滑块拖到别的值（给下面「记得住」造一个可分辨的数）===",
                  flush=True)
            # =================================================================
            v0 = st["label"]
            ck("② 拖得动（找得到把手，而且滚进了视口）", drag_iter(pg, 40),
               "找不到 .irs-handle")
            st2 = iter_state(pg)
            v1 = st2["label"]
            ck("② ★ 拖完小字变了（这就是 Shiny 真收到了那个值的证据）",
               v1 != v0 and v1 is not None, "%r → %r" % (v0, v1))
            n1 = None
            if v1 and v1.endswith("轮"):
                try:
                    n1 = int(v1[:-1])
                except ValueError:
                    n1 = None
            ck("② 拖出来的值是 1..20 里的一个整数", n1 is not None and 1 <= n1 <= 20,
               "读到 %r" % v1)

            # =================================================================
            print("\n=== ③ 勾上「开启」→ 滑块整个消失，小字改成「不限轮数」===",
                  flush=True)
            # =================================================================
            ck("③ 勾得上「开启」（顺便把首选项弹窗按当前状态存掉）",
               set_agent_mode(pg, True), "找不到 #chat-agent_mode")
            st3 = iter_state(pg)
            ck("③ ★ 滑块**不在 DOM 里**了（不是藏起来 —— display:none 那种"
               "「藏起来」在本仓栽过：切面板时藏着的 output 从没被求值过）",
               not st3["slider"], "slider=%s" % st3["slider"])
            ck("③ ★ 那一格里也没有第二根滑块露出来",
               st3["n_irs_in_agent"] == 0, "irs 个数=%s" % st3["n_irs_in_agent"])
            # ★★ 这一条是本节的主角：这句小字是从 **agent 对象** 上读的
            #    （a$max_iter），不是从勾上读的 —— 它绿 = 勾一下真的把
            #    a$max_iter 改成 Inf 了。
            ck("③ ★★ 小字写的是「不限轮数」（它读的是 agent 对象，不是那个勾）",
               "不限轮数" in st3["notes"], "小字是 %r" % st3["notes"][:160])
            ck("③ ★★ 而且是**不是**「最多 %s 轮」（少了那一刀就会长这样）" % v1,
               ("最多 %s 轮" % v1) not in st3["notes"] and
               ("最多 %s 轮" % v0) not in st3["notes"],
               "小字是 %r" % st3["notes"][:160])
            pg.locator(".dsapp-ctrl-bar").screenshot(path=OUT + "/iter_on.png")

            # =================================================================
            print("\n=== ④ 取消勾 → 滑块回来，而且记得住刚才那个数 ===", flush=True)
            # =================================================================
            ck("④ 取消得掉「开启」", set_agent_mode(pg, False))
            st4 = iter_state(pg)
            ck("④ 滑块回来了（而且真的画出来了，不是 0×0）",
               st4["slider"] and st4["irs"] and st4["w"] > 0,
               "slider=%s irs=%s" % (st4["slider"], st4["irs"]))
            # ⚠️ 记忆值来自 rv_iter()（勾着的时候 input$agent_iter 是 NULL）。
            #    写成 DSAPP_AGENT_MAX_ITER 的话这里会读回 "6 轮" ——
            #    用户看到的是"我上次设的 10 不见了"。
            ck("④ ★ 值还是刚才那个 %s（rv_iter 记着，不是弹回 6）" % v1,
               st4["label"] == v1, "%r（拖之前是 %r，刚设的是 %r）"
               % (st4["label"], v0, v1))

            # =================================================================
            print("\n=== ⑤ 真跑一轮：状态条上那个分母是「不限」（循环自己报的）===",
                  flush=True)
            # =================================================================
            # 判据是 `#chat-ctrl-notes` 里出现过 `第 N/不限 轮`。那一格读的是
            # a$status()$max_iter —— **循环自己**那份值，不是界面算出来的。
            # ⚠️ 必须有一段**能跑的代码**：回复里没有代码块的话，第 1 轮结束时
            #    a$state 还是 "idle"，而状态条那一支要求 active()（state != idle）
            #    —— 徽章一次都不会画出来，采样采到的全是"没跑"（假绿）。
            fx = C.FakeLLM()
            try:
                fx.set_queue(
                    sse_chunks(["我来跑一下。\n\n```r\n",
                                'cat("v165 ok\\n")\n',
                                "```\n\n跑完了我看结果。"]),
                    sse_chunks(["结果没问题。\n", "到这里就结束了。"]))
                fx.slow(0.35)
                C.seed_llm(uid, fx.url)
                ck("⑤ 种完假 LLM 之后重登一次（base_url 是会话开始那一刻读的）",
                   relogin(pg, email))
                C.goto(pg, "chat")
                C.ensure_no_modal(pg)
                pg.wait_for_selector(".dsapp-ctrl-bar", timeout=30000)
                pg.wait_for_timeout(1500)
                # 重登之后「开启」是库里的偏好推回来的（③ 里存的 TRUE）
                ck("⑤ （前置）重登之后「开启」还是勾着的（偏好存在库里）",
                   pg.locator("#chat-agent_mode").first.is_checked(),
                   "没勾上 —— 那下面那条会量到「循环压根没起来」")
                if not pg.locator("#chat-agent_mode").first.is_checked():
                    set_agent_mode(pg, True)

                pg.fill("#chat-input", "跑一下，看看行不行。")
                pg.click("#chat-send")
                seen_notes, badge = [], None
                end = time.time() + 150
                while time.time() < end:
                    try:
                        txt = pg.evaluate(
                            "() => (document.getElementById('chat-ctrl_notes')"
                            " || {}).innerText || ''")
                    except Exception:
                        txt = ""
                    if txt and (not seen_notes or seen_notes[-1] != txt):
                        seen_notes.append(txt)
                    import re as _re
                    m = _re.search(r"第\s*\d+\s*/\s*(\S+)\s*轮", txt)
                    if m:
                        badge = txt.strip()
                        break
                    pg.wait_for_timeout(250)
                ck("⑤ ★★ 状态条上出现过「第 N/不限 轮」（分母是循环自己报的 max_iter）",
                   badge is not None and "不限" in (badge or ""),
                   "采样到的状态条（按先后）：%s" % seen_notes[-4:])
                ck("⑤ ★ 假服务端真的收到了请求（>0 = 没打到真厂商）",
                   fx.req_n() > 0, "req_n=%s" % fx.req_n())
            finally:
                try:
                    fx.stop()
                except Exception:
                    pass

        finally:
            ss = os.path.join(OUT, "probe_iter_%s.png" % time.strftime("%H%M%S"))
            try:
                pg.screenshot(path=ss, full_page=True)
                print("  （整页截图 %s）" % ss, flush=True)
            except Exception:
                pass
            br.close()
        sys.exit(ck.done())


main()
