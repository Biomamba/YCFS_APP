# -*- coding: utf-8 -*-
"""V13.14 的浏览器验收：item 22 / 23 / 24。

这三条都属于"源码看着全对、界面上就是不对"的那一类，只有真的点一遍才算数：

  · **item 22**（单次回复上限的最右一格 = 不设上限）
      Rscript selftest.R 那一边已经证到了"请求体里真的没有 max_tokens"
      （它拿本机一个假 HTTP 服务收的请求读回来的）。**这一边回答的是另一个
      问题**：用户拖得到那一格吗、拖到之后那两个控件（滑块 / 数字框）显示的
      是同一件事吗。这两件事可以各自单独坏掉 —— 滑块停在 10485760 而输入框
      已经空了，或者反过来，看起来都像"这次改动没生效"。

  · **item 23**（帮助页独立到左侧导航栏）
      自检只能证明"左栏表里有 help、设置页里没有帮助页签"。它证明不了
      **点下去真的会切过去**（nav 的 value 对不上时是"点了没反应"，
      而不报错），也证明不了旧入口真的消失了。所以这里两种入口**都去点**。

  · **item 24**（"还没有 Key和URL？"挪到厂商下面）
      "上面"是个几何断言。要量的是：那行字夹在「厂商」和「接口地址」之间，
      而且**离上面更近** —— 补那对上下边距就是为了这个。只查文字在不在
      DOM 里的话，位置错了也照样绿。

跑法见 tests/ui_v1314/README.md。退出码 0 = 全绿。
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C
from playwright.sync_api import sync_playwright

Ck = C.Chk()
OUT = C.OUT

# 滑块那一格的量程（R/models.R 的 DSAPP_PARAM_DEFAULTS$max_tokens）：
#   min = 1024, max = 10485760, step = 1024  →  滑块最右 = max + step
SLIDER_TOP = 10485760 + 1024


def shot(pg, name):
    try:
        pg.screenshot(path=os.path.join(OUT, name))
    except Exception:
        pass


def rail_items(pg):
    """左栏所有导航项的 [中文, value]，按显示顺序。"""
    return pg.eval_on_selector_all(
        ".dsapp-rail-link",
        "els => els.map(e => [(e.querySelector('.dsapp-rail-label')||{}).textContent,"
        " e.getAttribute('data-nav')])")


# ⚠️⚠️ 量这个滑块**必须**用 `.dsapp-maxtok-slider` 这个容器来限定范围。
#    ionRangeSlider 的结构和想当然的不一样（2026-09-26 实测，dump 出来的）：
#
#      div.form-group
#        label#model-max_tokens_slider-label      ← 0×0
#        span.irs.irs--shiny.js-irs-2             ← 真正的控件！是**兄弟节点**
#          span.irs > span.irs-line / span.irs-handle.single / …
#        input#model-max_tokens_slider            ← 被藏起来的那个，4×4
#
#    两个坑：(a) `.irs` **不是** `#model-max_tokens_slider` 的子节点 ——
#    写成 `"#model-max_tokens_slider .irs"` 会一直等到超时，报出来的是
#    "找不到元素"，看着像滑块没渲染；(b) 这一页上有**三个** ionRangeSlider
#    （js-irs-0 是对话页那个 0×0 的、js-irs-1 是温度、js-irs-2 才是它），
#    裸写 `.irs` 会命中**隐藏页**里那个 0×0 的，量出来的几何全是 0 ——
#    而 0×0 的 box 在有些断言里会"看起来像对的"。
SLIDER_BOX = ".dsapp-maxtok-slider"


def drag_slider_to(pg, frac):
    """把 ionRangeSlider 的把手**真的拖**到轨道 frac 处（0=最左 1=最右）。

    ⚠️ 不用 JS 调 `$(sel).data('ionRangeSlider').update({from:...})`：
       那是从**控件内部**改值，Shiny 的 binding 会不会收到 onChange 是
       实现细节；而这一条要验的恰恰是"用户拖得动"。拖不动的东西，
       用 update() 照样能测成绿的。

    ⚠️⚠️ **先滚进视口再量坐标**（2026-09-26 踩到，花了半天）：
       设置页很长，滑块默认落在 **y=1104**，而视口高 950 —— 在视口**外面**。
       Playwright 的 mouse 坐标是视口坐标系，往视口外移动**没有任何元素接收
       事件**，于是"拖了等于没拖"；偏偏 `bounding_box()` 照样老老实实返回
       一组正数，rail / handle 都量得到，全程不报错。表现是**第一次拖不动、
       第二次又能动**（因为中间那次 `fill()` 顺手把页面滚下去了）——
       看着像"第一次点击没生效"这种玄学。
    """
    box = pg.locator(SLIDER_BOX).first
    box.scroll_into_view_if_needed()
    pg.wait_for_timeout(250)
    rail = pg.locator(SLIDER_BOX + " .irs-line").first.bounding_box()
    h = pg.locator(SLIDER_BOX + " .irs-handle").first.bounding_box()
    if not rail or not h:
        return None
    vw, vh = pg.viewport_size["width"], pg.viewport_size["height"]
    y = h["y"] + h["height"] / 2.0
    x0 = h["x"] + h["width"] / 2.0
    # 把手必须真的在视口里。不在就说明上面那次 scroll 没起作用（比如被
    # 一个 overflow 容器夹住了）——这时候宁可炸掉，也不要"静悄悄拖空"。
    if not (0 <= x0 <= vw and 0 <= y <= vh):
        raise RuntimeError(
            "把手不在视口内 (%.0f, %.0f)，视口 %dx%d —— 滚动没生效，"
            "再拖下去就是假绿" % (x0, y, vw, vh))
    x1 = rail["x"] + rail["width"] * frac
    if frac >= 1.0:
        # 拖到轨道右端**再多一点**：正好压线的话，不同 DPR / 亚像素下可能
        # 停在倒数第二格 —— 而"拖到头却不是不设上限"正是这次要抓的失败。
        x1 += 20
    x1 = min(x1, vw - 4.0)
    pg.mouse.move(x0, y)
    pg.mouse.down()
    # 分几步走：一步到位的话 ionRangeSlider 只看到一次 mousemove，
    # 拖动过程中那几个中间态就测不到了（而"松手回跳一格"正是那个阶段的事）。
    for i in range(1, 9):
        pg.mouse.move(x0 + (x1 - x0) * i / 8.0, y)
        pg.wait_for_timeout(30)
    pg.mouse.up()
    pg.wait_for_timeout(700)
    return rail


def slider_from(pg):
    """回读 ionRangeSlider 自己认为的当前值。"""
    return pg.evaluate(
        """() => {
        const i = document.querySelector('#model-max_tokens_slider');
        if (!i || !window.jQuery) return null;
        const d = window.jQuery(i).data('ionRangeSlider');
        return d ? d.result.from : null;
      }""")


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        pg = br.new_page(viewport={"width": 1440, "height": 950})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))

        email = C.enter_app(pg)
        C.seed_or_die(email)
        C.goto(pg, "model", wait=4000)

        # =====================================================================
        print("\n== item 22：单次回复上限的最右一格 = 不设上限 ==", flush=True)
        # =====================================================================
        pg.wait_for_selector("#model-max_tokens", timeout=20000)
        pg.wait_for_timeout(1500)

        box = pg.locator("#model-max_tokens")
        end_lab = pg.locator(".dsapp-maxtok-end-hi")
        Ck("★★ 数字输入栏和「不设上限」那行字都在（不在的话下面全是空跑）",
           box.count() == 1 and end_lab.count() >= 1,
           "box=%d lab=%d" % (box.count(), end_lab.count()))
        Ck("★★★ 那行字写的就是「不设上限」（用户看到的就是这四个字）",
           (end_lab.first.inner_text().strip() == "不设上限")
           if end_lab.count() else False,
           end_lab.first.inner_text() if end_lab.count() else "（没有）")

        # ---- 把滑块拖到最右 --------------------------------------------------
        before = box.input_value()
        rail = drag_slider_to(pg, 1.0)
        after = box.input_value()
        shot(pg, "22_slider_far_right.png")
        Ck("★★★ 拖到最右之后数字栏**空了**（不是留着一个 10,486,784）",
           after == "", "拖之前 %r → 拖之后 %r" % (before, after))
        Ck("★★★ 而且「不设上限」那四个字**高亮**了（.on）",
           pg.locator(".dsapp-maxtok-end-hi.on").count() >= 1,
           pg.eval_on_selector_all(
               ".dsapp-maxtok-end-hi",
               "els => els.map(e => e.className)"))

        # ---- 那行字真的落在轨道右端下方（不是另一句跟在后面的说明）---------
        if rail and end_lab.count():
            geo = pg.evaluate(
                """() => {
                const l = document.querySelector('.dsapp-maxtok-end-hi');
                const r = document.querySelector('.dsapp-maxtok-slider .irs-line');
                if (!l || !r) return null;
                const a = l.getBoundingClientRect(), b = r.getBoundingClientRect();
                return {right_gap: Math.round(b.right - a.right),
                        below: Math.round(a.top - b.bottom),
                        lab_right: Math.round(a.right), rail_right: Math.round(b.right)};
              }""")
            Ck("★★ 那行字在滑轨**下方**、且右端贴着轨道右端（右对齐）",
               bool(geo) and geo["below"] >= -6 and abs(geo["right_gap"]) <= 30,
               geo)

        # ---- 填一个正常值：高亮必须灭掉（不然它就是个常亮的装饰）------------
        box.click()
        box.fill("8192")
        box.press("Tab")
        pg.wait_for_timeout(1200)
        Ck("★★★ 填了 8192 之后「不设上限」的高亮**灭掉**（常亮的话等于没提示）",
           pg.locator(".dsapp-maxtok-end-hi.on").count() == 0,
           pg.eval_on_selector_all(".dsapp-maxtok-end-hi",
                                   "els => els.map(e => e.className)"))
        Ck("★★ 而且这一轮没有把 8192 冲掉（写回的是同一个数）",
           box.input_value().strip() in ("8192", "8,192"),
           box.input_value())

        # ---- 清空输入栏：滑块要跟着走到最右 ---------------------------------
        #
        # ⚠️ 这一条是这次改动里最容易坏的一处：那条 observer 原来有个
        #    `if (!is.finite(v)) return()`，而"清空"恰好让 v 变成 NA ——
        #    留着那个 return 的表现是**界面一动不动**（框空了、滑块还在 8K），
        #    用户只能觉得这个框坏了。
        box.click()
        box.press("Control+a")
        box.press("Delete")
        pg.wait_for_timeout(1500)
        shot(pg, "22_cleared.png")
        Ck("★★★ 清空输入栏之后「不设上限」的高亮回来了",
           pg.locator(".dsapp-maxtok-end-hi.on").count() >= 1,
           pg.eval_on_selector_all(".dsapp-maxtok-end-hi",
                                   "els => els.map(e => e.className)"))
        Ck("★★★ 滑块也跟着走到最右那一格了（不是停在 8K 不动）",
           slider_from(pg) == SLIDER_TOP,
           "滑块读到 %r，最右那一格是 %d" % (slider_from(pg), SLIDER_TOP))

        # ---- 来回切几次不许发散（拖右 → 填数 → 拖右）------------------------
        box.click()
        box.fill("65536")
        box.press("Tab")
        pg.wait_for_timeout(900)
        drag_slider_to(pg, 1.0)
        Ck("★★ 第二次拖到最右，数字栏还是空的（不会来回切几次就发散）",
           box.input_value() == "", box.input_value())

        # =====================================================================
        print("\n== item 23：帮助页在左侧导航栏 ==", flush=True)
        # =====================================================================
        items = rail_items(pg)
        vals = [v for _t, v in items]
        labels = [t.strip() if t else "" for t, _v in items]
        Ck("★★★ 左栏里有「帮助」这一项（data-nav = help）",
           "help" in vals and "帮助" in labels, items)
        Ck("★★ 它排在「设置」后面（配置类挨着，管理员那两项仍在最下面）",
           "help" in vals and "settings" in vals
           and vals.index("help") > vals.index("settings")
           and (("admin" not in vals) or vals.index("help") < vals.index("admin")),
           vals)

        # ---- 点它：真的切过去 -------------------------------------------------
        #
        # ⚠️ 先判存在再点。`click()` 找不到元素时抛的是 playwright 的
        #    TimeoutError，**整个脚本当场就没了** —— 后面 item 24 那一段根本
        #    跑不到。本条真的坏掉时，"item 23 红 + item 24 一行都没有"看起来
        #    很像"item 24 也一起坏了"，其实是没跑到。（2026-09-26 做变异验证
        #    时踩的：把左栏的 help 拿掉，日志就在这一行断掉。）
        if pg.locator(".dsapp-rail-link[data-nav='help']").count():
            pg.click(".dsapp-rail-link[data-nav='help']")
        pg.wait_for_timeout(3500)
        shot(pg, "23_help_page.png")
        Ck("★★★ 点左栏的「帮助」真的切到了那一页（value 对不上就是点了没反应）",
           pg.evaluate(
               "() => { const a = document.querySelector('.dsapp-rail-link.active');"
               " return a ? a.getAttribute('data-nav') : null; }") == "help")
        pane = pg.locator(".tab-pane[data-value='help']")
        Ck("★★ 帮助页那块面板是**可见**的（不是还藏在别的页里）",
           pane.count() >= 1 and pane.first.is_visible(),
           pane.count())
        Ck("★★★ 客服二维码那张图真的加载出来了（搬页最容易把 www/ 的路径搬丢）",
           pg.eval_on_selector_all(
               "img.dsapp-help-img",
               "els => els.filter(e => e.offsetParent !== null)"
               ".map(e => ({w: e.naturalWidth, src: e.getAttribute('src')}))"),
           "（上面那行是全部 img.dsapp-help-img）")
        help_txt = pane.first.inner_text() if pane.count() else ""
        Ck("★★ 使用说明和版本号都在这一页上",
           ("应用版本" in help_txt) and ("文件管理区" in help_txt),
           help_txt[:200])
        Ck("★★★ 这一页上**没有**「保存并开始使用」（V13.9 item 11 的结论）",
           "保存并开始使用" not in help_txt, help_txt[-120:])

        # ---- 设置页里的旧入口真的没了 ----------------------------------------
        C.goto(pg, "settings", wait=3500)
        tabs = pg.eval_on_selector_all(
            "#settings-tab .nav-link",
            "els => els.map(e => e.textContent.trim())")
        Ck("★★★ 设置页只剩三个页签，而且**没有**「帮助」了（搬一半 = 两个入口）",
           len(tabs) == 3 and not any("帮助" in t for t in tabs), tabs)
        Ck("★★ 三个页签还是 界面 / 执行 / 账号（不是把别的一起删了）",
           all(any(k in t for t in tabs) for k in ("界面", "执行", "账号")), tabs)

        # =====================================================================
        print("\n== item 24：「还没有 Key和URL？」在厂商下面 ==", flush=True)
        # =====================================================================
        C.goto(pg, "model", wait=3500)
        pg.wait_for_timeout(1200)
        hint = pg.locator(".dsapp-key-help")
        Ck("★ key_help 那一块在（改名/挪走的话下面是空跑）", hint.count() >= 1)
        htxt = hint.first.inner_text() if hint.count() else ""
        Ck("★★★ 文案是「还没有 Key和URL？去 」（多出来的「和URL」是有实义的）",
           "还没有 Key和URL？" in htxt and "还没有 Key？" not in htxt,
           htxt[:120])

        # ---- 几何：夹在「厂商」和「接口地址」之间，且**离厂商更近** ---------
        geo = pg.evaluate(
            """() => {
            const q = s => document.querySelector(s);
            const h  = q('.dsapp-key-help');
            const v  = q('#model-vendor');
            const b  = q('#model-base_url');
            const vr = v && v.closest('.form-group') ? v.closest('.form-group') : v;
            const br = b && b.closest('.form-group') ? b.closest('.form-group') : b;
            if (!h || !vr || !br) return null;
            const H = h.getBoundingClientRect(), V = vr.getBoundingClientRect(),
                  B = br.getBoundingClientRect();
            return {above: Math.round(H.top - V.bottom),   // 离厂商多远
                    below: Math.round(B.top - H.bottom)};  // 离接口地址多远
          }""")
        Ck("★★★ 它夹在「厂商」和「接口地址」之间（不是排在「获取模型」下面了）",
           bool(geo) and geo["above"] >= -2 and geo["below"] >= -2, geo)
        Ck("★★★ 而且**离厂商更近**（不补那对上下边距的话它会贴着接口地址，"
           "看着像接口地址的说明）",
           bool(geo) and geo["above"] < geo["below"],
           geo)
        shot(pg, "24_key_help.png")

        # ---- 链接还是对的那两个：申请 → 注册入口 -----------------------------
        C.pick_select(pg, "model-vendor", "relay")
        pg.wait_for_timeout(2500)
        htxt2 = pg.locator(".dsapp-key-help").first.inner_text()
        hrefs = pg.eval_on_selector_all(
            ".dsapp-key-help a", "els => els.map(e => e.getAttribute('href'))")
        Ck("★★ 切到「中转站大全」之后那句话里带的是它的名字",
           "中转站大全" in htxt2 and "官网申请" in htxt2, htxt2[:140])
        Ck("★★★ 申请那条链接仍然是用户给的注册入口（带 aff 的邀请参数）",
           any("api.ocean-way.top/sign-up" in h for h in hrefs), hrefs)
        Ck("★★ 而且新位置下面就是「接口地址」（那句话说的 URL 就在眼皮底下）",
           pg.evaluate(
               """() => {
                const h = document.querySelector('.dsapp-key-help');
                const b = document.querySelector('#model-base_url');
                if (!h || !b) return null;
                const H = h.getBoundingClientRect(), B = b.getBoundingClientRect();
                return Math.round(B.top - H.bottom);
              }""") is not None)

        Ck("★ 全程没有 JS 报错", not errs, errs[:2])
        br.close()
    return Ck.done()


if __name__ == "__main__":
    sys.exit(main())
