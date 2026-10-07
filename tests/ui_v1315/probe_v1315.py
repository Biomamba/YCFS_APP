# -*- coding: utf-8 -*-
"""V13.15 的浏览器验收：item 25 / 26。

两条都是"源码看着全对、界面上就是不对"的那一类，只有真的点一遍才算数：

  · **item 25**（「还没填 Key」的按钮跳到模型服务页）
      自检能证明 `dsapp_goto("model")` 写在源码里、也能证明 nav_panel 里
      真有 value = "model"。它证明不了**点下去真的会切页** —— nav 的 value
      对不上时是"点了没反应"，不报错也不进日志。所以这里把弹窗**真的点出来**、
      按钮**真的按下去**，再回读左栏哪一项是 active。

  · **item 26**（「确认 / 更新」头尾各一颗、同宽）
      "头尾各一颗"和"一样宽"都是**几何断言**。只查 DOM 里有两个按钮的话，
      两颗都挤在底部也照样绿。要量的是：头部那颗确实在「厂商」上方、
      底部那颗确实在「生成参数」下方，而且两颗的宽度和「获取模型」一致。

跑法见 tests/ui_v1315/README.md。退出码 0 = 全绿。
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C
from playwright.sync_api import sync_playwright

Ck = C.Chk()
OUT = C.OUT


def shot(pg, name):
    try:
        pg.screenshot(path=os.path.join(OUT, name))
    except Exception:
        pass


def dismiss_modals(pg):
    """把当前盖着的弹窗关掉（首次进入时可能有别的提示窗）。

    ⚠️ 不关的话，后面 `click("#chat-send")` 会被遮罩接住 —— playwright 报的
       是 "element is not visible / intercepts pointer events"，看着像按钮
       坏了，其实是别的窗没关。（这个应用里 V13.12 item 4 的「AI 怎么干活？」
       是 easyClose 的，点一下外面就没了。）
    """
    for _ in range(4):
        if pg.locator(".modal.show, .modal[style*='display: block']").count() == 0:
            return
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(600)


def wait_for(pg, sel, ms=20000):
    """等元素出现，**超时不抛异常**，只回 False。

    ⚠️ 直接 `pg.wait_for_selector()` 超时抛的是 playwright 的 TimeoutError，
       脚本当场结束 —— **后面那一段根本跑不到**。变异验证时踩到过：把 item 25
       的跳转改回 settings，item 26 开头这一等就炸，输出停在
       "== item 26 ==" 之后一行，看着像"item 26 也一起坏了"，其实只是没跑到。
       （V13.14 记的第 3 个坑是同一个毛病，那次炸在 pg.click() 上。）
       宁可让下面的 count() 断言红，也不要让脚本没了。
    """
    try:
        pg.wait_for_selector(sel, timeout=ms)
        return True
    except Exception:
        return False


def box_of(pg, sel):
    """元素的外框（宽/高/位置），找不到返回 None。"""
    return pg.evaluate(
        """(s) => {
        const e = document.querySelector(s);
        if (!e) return null;
        const b = e.getBoundingClientRect();
        return {x: Math.round(b.x), y: Math.round(b.y),
                w: Math.round(b.width), h: Math.round(b.height)};
      }""", sel)


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        pg = br.new_page(viewport={"width": 1440, "height": 950})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))

        email = C.enter_app(pg)
        C.seed_or_die(email)
        # ⚠️ 这一步是**故意的**：整个 item 25 只在"这个账号一把 Key 都没有"
        #    的时候才走得到。新注册的账号天然就是这个状态，所以这里**不能**
        #    先去模型页填一把占位 Key（别的探针常那么干，为的是绕开闸门）。
        C.goto(pg, "chat", wait=4500)
        dismiss_modals(pg)
        pg.wait_for_selector("#chat-input", timeout=20000)
        pg.wait_for_timeout(1200)

        # =====================================================================
        print("\n== item 25：没填 Key 时那颗按钮跳「模型服务」==", flush=True)
        # =====================================================================
        box = pg.locator("#chat-input")
        box.click()
        box.fill("你好，帮我看看这批数据")
        pg.wait_for_timeout(400)
        if pg.locator("#chat-send").count():
            pg.locator("#chat-send").click()
        pg.wait_for_timeout(2500)
        shot(pg, "25_no_key_modal.png")

        modal = pg.locator(".modal.show").first
        Ck("★★★ 没填 Key 就发消息，弹出了那个提醒窗（没弹的话下面全是空跑）",
           modal.count() >= 1 and modal.is_visible(),
           pg.eval_on_selector_all(".modal", "els => els.length"))
        if modal.count() == 0:
            Ck("★★★ （没有窗，后面的 item 25 断言无法进行）", False)
        mtext = modal.inner_text() if modal.count() else ""
        Ck("★★ 窗里的正文说的是「模型服务」（和按钮指的是同一页）",
           "模型服务" in mtext, mtext[:200])

        # ---- 那颗按钮：标签 + 目的地 ----------------------------------------
        btn = pg.locator("#chat-goto_model")
        Ck("★★★ 按钮的 id 是 chat-goto_model（还是 goto_settings 的话点的是老路）",
           btn.count() == 1, btn.count())
        Ck("★★★ 按钮上写的是「去模型服务」（原来是「去设置」）",
           btn.count() == 1 and "去模型服务" in btn.inner_text(),
           btn.inner_text() if btn.count() else "（没有）")
        Ck("★★ 按钮看着是主操作（btn-primary，蓝色实心）",
           btn.count() == 1
           and "btn-primary" in (btn.get_attribute("class") or ""),
           btn.get_attribute("class") if btn.count() else "（没有）")

        # ---- ★★★ 真的点下去，看它切到哪一页 ---------------------------------
        #
        # ⚠️ 判据是**左栏哪一项 active**，不是"弹窗关掉了"。弹窗关掉只说明
        #    removeModal() 跑了；跳转那一步照样可以静默失败（value 对不上），
        #    而那时弹窗已经没了，看起来像"跳过去了"。
        nav_before = pg.evaluate(
            "() => { const a = document.querySelector('.dsapp-rail-link.active');"
            " return a ? a.getAttribute('data-nav') : null; }")
        if btn.count():
            btn.click()
        pg.wait_for_timeout(4000)
        shot(pg, "25_after_click.png")
        nav_after = pg.evaluate(
            "() => { const a = document.querySelector('.dsapp-rail-link.active');"
            " return a ? a.getAttribute('data-nav') : null; }")
        Ck("★★★ 点下去之后左栏高亮跳到了「模型服务」（不是「设置」）",
           nav_after == "model",
           "点之前 %r → 点之后 %r" % (nav_before, nav_after))
        pane = pg.locator(".tab-pane[data-value='model']")
        Ck("★★ 而且模型服务那一块面板真的**可见**了（高亮跟上、内容没跟上也是白搭）",
           pane.count() >= 1 and pane.first.is_visible(), pane.count())
        Ck("★★ 设置页那一块是**藏起来的**（两个页面同时在就是没切干净）",
           pg.locator(".tab-pane[data-value='settings']").count() == 0
           or not pg.locator(".tab-pane[data-value='settings']").first.is_visible())

        # =====================================================================
        print("\n== item 26：「确认 / 更新」头尾各一颗、同宽 ==", flush=True)
        # =====================================================================
        # ★ 自己切到模型页，**不靠 item 25 那一跳**。两条工单是各自独立的：
        #   item 25 坏掉时（跳转目标写错）页面会停在别处，若这里还指望它，
        #   item 26 会跟着一起红 —— 而它其实好好的，红的是别人。
        C.goto(pg, "model", wait=3000)
        if not wait_for(pg, "#model-commit"):
            print("  ⚠️ 模型服务页没渲染出来，item 26 下面几条会直接判红", flush=True)
        pg.wait_for_timeout(1500)

        top = pg.locator("#model-commit_top")
        btm = pg.locator("#model-commit")
        vfy = pg.locator("#model-verify")
        Ck("★★★ 两颗按钮都在（头部 chat 里那颗叫 model-commit_top）",
           top.count() == 1 and btm.count() == 1 and vfy.count() == 1,
           "top=%d btm=%d verify=%d" % (top.count(), btm.count(), vfy.count()))
        Ck("★★★ 两颗都**可见**（加了但没显示 = 白加）",
           top.count() == 1 and top.is_visible()
           and btm.count() == 1 and btm.is_visible())

        bt, bb, bv = (box_of(pg, "#model-commit_top"),
                      box_of(pg, "#model-commit"),
                      box_of(pg, "#model-verify"))
        Ck("★★★ 三颗按钮宽度一致（「获取模型」是这一页的主按钮，照它做）",
           bool(bt and bb and bv) and bt["w"] == bb["w"] == bv["w"]
           and bv["w"] > 400,
           "头部 %s / 底部 %s / 获取模型 %s"
           % (bt and bt["w"], bb and bb["w"], bv and bv["w"]))

        # ---- 位置：头部那颗在「厂商」上面，底部那颗在「生成参数」下面 --------
        #
        # ⚠️⚠️ 「厂商」的坐标**不能**拿 `#model-vendor` 量（2026-09-26 踩到）：
        #     selectInput 被 app.js 过了一层 selectize，**原生 <select> 是隐藏的**，
        #     它的 getBoundingClientRect() 返回**全 0**。于是 `T.top - V.top` 算出来
        #     正好等于按钮自己的 y（143），看着特别像"按钮排到厂商下面 143px 去了"
        #     —— 一个完全可信的数字，来自一个分母为 0 的减法。源码里按钮明明在厂商
        #     **上方 91px**。
        #     所以这里量的是**看得见**的那两个：厂商的 <label>、以及 selectize 那层壳。
        #     末尾的 vis() 兜底：真量到 0×0 的元素就返回 err，而不是拿去相减。
        # ⚠️ 三组**各自独立**算，缺哪一组就只缺哪一组：整块 return 的话，
        #    "头部按钮没了"会连带把"底部那颗在参数下方"也判红 —— 底部明明好好的。
        #    红的范围必须是**真坏掉的那些**，多红一条就会把人指到错地方。
        geo = pg.evaluate(
            """() => {
            const q = s => document.querySelector(s);
            const box = e => { const r = e.getBoundingClientRect();
                               return {t: r.top, b: r.bottom, w: r.width, h: r.height}; };
            const vis = r => !!r && r.w > 0 && r.h > 0;
            const T = q('#model-commit_top') ? box(q('#model-commit_top')) : null;
            const B = q('#model-commit')     ? box(q('#model-commit'))     : null;
            const P = q('.dsapp-model-params') ? box(q('.dsapp-model-params')) : null;
            const V = [q('#model-vendor-label'),
                       q('#model-vendor + .selectize-control'),
                       q('#model-vendor')]
                      .filter(Boolean).map(box).find(vis) || null;
            const o = {top_btn: !!T, btm_btn: !!B};
            if (T && V) o.top_vs_vendor = Math.round(T.t - V.t);
            else o.err_top = T ? '厂商那一格量不到可见外框' : '头部那颗不在 DOM 里';
            if (B && vis(P)) o.btm_vs_params = Math.round(B.t - P.b);
            else o.err_btm = B ? '生成参数那一块量不到可见外框' : '底部那颗不在 DOM 里';
            if (T) o.top_y = Math.round(T.t);
            if (B) o.btm_y = Math.round(B.t);
            return o;
          }""")
        # ⚠️ 取键一律用 .get()：量不到东西时 geo 是 `{'err': ...}`（**不是 None**），
        #    直接 geo["top_vs_vendor"] 会 KeyError —— 脚本当场没了，后面几条
        #    "点了真的存下去了吗"永远跑不到。宁可这里判红。
        print("  · 量到的几何：%s" % (geo,), flush=True)   # 绿的时候也打，免得只有红才有数
        g_tv = (geo or {}).get("top_vs_vendor")
        g_bp = (geo or {}).get("btm_vs_params")
        g_ty = (geo or {}).get("top_y")
        Ck("★★★ 头部那颗在「厂商」**上方**（负数 = 在上面）",
           g_tv is not None and g_tv < 0, geo)
        Ck("★★★ 底部那颗在「生成参数」**下方**（V13.11 item 8 的结论没被推翻）",
           g_bp is not None and g_bp > 0, geo)
        # ⚠️ 头部那颗必须落在**首屏**里。这一条的正文就是用户说的"防止用户
        #    看不到"—— 加了个按钮但要滚动才看得见，等于没加。
        vh = pg.viewport_size["height"]
        Ck("★★★ 而且头部那颗在**首屏**里（y < 视口高 %d，不用滚动就看得见）" % vh,
           g_ty is not None and g_ty < vh, geo)

        # ---- 标签：两颗说的是同一件事 ---------------------------------------
        lt = top.inner_text().strip() if top.count() else ""
        lb = btm.inner_text().strip() if btm.count() else ""
        Ck("★★★ 两颗按钮的文字一样（一个「确认」一个「更新」会让人以为是两件事）",
           lt == lb and lt in ("确认", "更新"), "头部 %r / 底部 %r" % (lt, lb))
        Ck("★★★ 新账号还没存过 Key，所以现在是「确认」（不是「更新」）",
           lt == "确认", lt)

        # ---- ★★★ 点**头部**那颗，看它是不是真的在干活 ----------------------
        #
        # ⚠️ 这一条是 item 26 最容易坏的一处：新加的那颗按钮 id 写错、或者
        #    observer 忘了接，表现都是"点了没反应"—— 而"点了没反应"和
        #    "点了但本来就没东西要存"在界面上区分不开，只有**状态真的变了**
        #    才算数。这里填一把假 Key 再点，看提示行有没有从"还没填 Key"
        #    变成"已保存"。
        # ⚠️ 每一处都先 count() 再用 —— 元素不在时 inner_text()/click() 都会抛
        #    TimeoutError，脚本一没，后面几条断言连"红"都看不到。
        def txt(sel):
            l = pg.locator(sel)
            return l.inner_text().strip() if l.count() else ""

        hint_before = txt("#model-commit_hint_top")
        if pg.locator("#model-api_key").count():
            pg.locator("#model-api_key").click()
            pg.locator("#model-api_key").fill("sk-fake-v1315-head-button")
        pg.wait_for_timeout(300)
        if top.count():
            top.click()
        pg.wait_for_timeout(3500)
        shot(pg, "26_head_clicked.png")
        hint_after = txt("#model-commit_hint_top")
        hint_btm = txt("#model-commit_hint")
        Ck("★★★ 点**头部**那颗真的存下去了（提示行从「还没填 Key」变了）",
           hint_after != hint_before and "已保存" in hint_after,
           "%r → %r" % (hint_before, hint_after))
        Ck("★★★ 底部那行提示**跟着一起变**（两颗说的是同一件事）",
           "已保存" in hint_btm, hint_btm)
        Ck("★★★ 两颗的标签一起变成了「更新」（只刷一颗会并排出现确认/更新）",
           txt("#model-commit_top") == "更新" and txt("#model-commit") == "更新",
           "头部 %r / 底部 %r" % (txt("#model-commit_top"), txt("#model-commit")))

        # ---- 底部那颗也要能干同样的活 ---------------------------------------
        if pg.locator("#model-api_key").count():
            pg.locator("#model-api_key").fill("sk-fake-v1315-bottom-button")
        pg.wait_for_timeout(300)
        if btm.count():
            btm.click()
        pg.wait_for_timeout(3000)
        Ck("★★★ 点**底部**那颗也存得下去（两颗都活着，不是只有一颗接了线）",
           "已保存" in txt("#model-commit_hint"), txt("#model-commit_hint"))

        Ck("★ 全程没有 JS 报错", not errs, errs[:2])
        br.close()
    return Ck.done()


if __name__ == "__main__":
    sys.exit(main())
