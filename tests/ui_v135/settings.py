# -*- coding: utf-8 -*-
"""V13.5 item 7：设置页的二级导航栏。

> 7、设置页面现在太乱了，请弄一个二级导航栏

原来是 7 张卡片按 `layout_columns(col_widths = c(7, 5))` 分两栏铺开。现在按
「界面 / 执行 / 账号 / 帮助」分成四组，每组一页。

★ 为什么只能在这里验：

  ⚠️⚠️ bslib 的 navset(**包括 navset_hidden 和 navset_underline**) 把**所有**
    面板都留在 DOM 里，没选中的那些只是 `display: none`。所以

        page.locator(".card").count()   →  永远是 7

    不管切到哪一页。这和 V13.1/V13.2 那几次"量的全是隐藏元素的 0×0 矩形"
    是同一个坑，只是这次的症状是**数字看着完全正常**。

    所以每一条都必须先**切页**、再**过滤掉 width == 0 的元素**，两个都要做：
    只切页不过滤 → 隐藏页的卡片照样被数进去；只过滤不切页 → 当前页对了，
    但"切过去之后对不对"根本没验到。

★ 这条测的其实是"**分组对不对**"：哪几张卡片在哪一页。把「账号密码」放进
  「界面」页，或者「保存并开始使用」没跟着走，用户是找不到的，而 R 那边
  只看到一堆 card() 竖着堆 —— 看不出分组错没错位。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import APP, Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

C = Chk()

# 当前**可见**的那张设置卡片里的标题文字。
# ⚠️ `getBoundingClientRect().width > 0` 是必须的 —— 见模块开头那段。
VISIBLE_CARDS = """() => {
  var out = [];
  document.querySelectorAll('.dsapp-page .card').forEach(function (c) {
    var r = c.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return;   /* 没选中的 nav_panel 里的 */
    var h = c.querySelector('.card-header, .card-title, h1, h2, h3, h4, h5');
    out.push(((h ? h.innerText : c.innerText) || '').trim().slice(0, 40));
  });
  return out;
}"""

TABS = """() => {
  var out = [];
  document.querySelectorAll('.dsapp-page .nav-underline .nav-link, ' +
                           '.dsapp-page .nav-pills .nav-link, ' +
                           '.dsapp-page ul.nav li a, ' +
                           '.dsapp-page .nav-link').forEach(function (a) {
    var r = a.getBoundingClientRect();
    if (r.width <= 0) return;
    var t = (a.innerText || '').trim();
    if (t && out.indexOf(t) < 0) out.push(t);
  });
  return out;
}"""


def cards(page):
    return page.evaluate(VISIBLE_CARDS)


with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: m.type == "error" and errors.append(m.text))

    email = enter_app(page)
    seed_or_die(email)
    goto(page, "settings")
    page.wait_for_timeout(1500)

    tabs = page.evaluate(TABS)
    C("★★ 设置页有二级导航，而且是**四**个（界面 / 执行 / 账号 / 帮助）",
      len(tabs) >= 4, "量到的标签：%s" % (tabs,))
    for want in ("界面", "执行", "账号", "帮助"):
        C("★★ 二级导航里有「%s」" % want,
          any(want in t for t in tabs), "量到的标签：%s" % (tabs,))

    # ⚠️ 先确认"第一页上确实看得见卡片" —— 否则下面按页比对全是空列表互相比，
    #    永远是"对"的。这是"扫不到东西和没有东西长得一样"的又一个形态。
    first = cards(page)
    C("（前置）切到设置页之后看得见卡片（看得见 0 张 = 下面全是空转）",
      len(first) >= 1, "可见卡片 %s" % (first,))

    # 每一页各点一次，记录这一页**看得见**的卡片。
    # 用文字特征认卡片，不认下标 —— 下标会随排版顺序变，文字不会。
    def click_tab(name):
        for sel in (".dsapp-page .nav-link", ".dsapp-page ul.nav a"):
            loc = page.locator(sel, has_text=name)
            for i in range(loc.count()):
                if loc.nth(i).is_visible():
                    loc.nth(i).click()
                    page.wait_for_timeout(1200)
                    return True
        return False

    seen = {}
    for t in ("界面", "执行", "账号", "帮助"):
        if not any(t in x for x in tabs):
            continue
        C("★ 点得动「%s」这个标签" % t, click_tab(t), t)
        seen[t] = cards(page)

    print("  各页可见的卡片：", flush=True)
    for k, v in seen.items():
        print("    %s → %s" % (k, v), flush=True)

    def has(tab, *keys):
        blob = " ".join(seen.get(tab, []))
        return all(k in blob for k in keys)

    # ⚠️ 下面这几条是"分组**没错位**"的判据。分组错了 R 那边看不出来
    #    （都是一堆 card() 竖着堆），用户却会找不到东西。
    C("★★ 「界面皮肤 / 界面尺寸」在「界面」页",
      has("界面", "皮肤") and has("界面", "尺寸"), seen.get("界面"))
    C("★★ 「硬件选择」在「执行」页（它和皮肤不是一回事）",
      has("执行", "硬件"), seen.get("执行"))
    C("★★ 「账号密码」和「同步」在「账号」页",
      has("账号", "密码") and has("账号", "同步"), seen.get("账号"))
    # ★ V13.9 item 11：用户原话「保存并开始使用不应该出现在帮助页面，而是
    #   应该出现在其它设置页面的底部」。所以这一条**反过来**了 —— 它现在查
    #   的正是"帮助页没有它"。
    #   ⚠️ 三栏都要查，不能只查一栏：那张卡是三份**不同 output id** 的副本
    #      （同一个 id 在 DOM 里出现三次的话 Shiny 只更新第一个，另外两页
    #      会是空的、而且不报错，见 R/mod_settings.R 里 dsapp_back_card 的
    #      那段说明）。少一栏就等于那页底部是空的。
    C("★★★ 「保存并开始使用」在界面/执行/账号三栏的底部，帮助页不再有",
      has("界面", "保存") and has("执行", "保存") and has("账号", "保存")
      and not has("帮助", "保存"), seen)
    # ★ V13.9 item 12：用户原话「帮助页面留一下微信二维码，或者留
    #   Rmarkdown2026开头那个页面」。留的是客服微信二维码那张卡。
    C("★★ 帮助页留了客服二维码那张卡",
      has("帮助", "客服") and has("帮助", "需要帮助"), seen.get("帮助"))

    # ⚠️ 每一页的卡片数**加起来**要等于 11 张 —— 少了说明有一张在分组的时候
    #    被落下了（落在 navset 外面的话它反而会在每一页都显示，见下条）。
    # ★ V13.9：从 7 张变 11 张，差的那 4 张要对得上账：
    #      +3  界面/执行/账号各多一张「保存并开始使用」（item 11）
    #      +1  「执行」页多一张「离开页面之后」（这张更早就有了 —— V13.5
    #           那个实例上跑的是当年的代码，所以那边数出来是 7）
    #      +0  帮助页：搬走了「保存并开始使用」，换进来客服二维码那张
    total = sum(len(v) for v in seen.values())
    C("★★ 四页的卡片加起来是 11 张（少一张 = 分组时落下了）",
      total == 11, "各页 %s，合计 %d" % ({k: len(v) for k, v in seen.items()},
                                        total))
    # 落在 navset **外面**的卡片会在每一页都出现 —— 那是最容易犯的错，
    # 而且看起来"卡片都在"，只是每页都多一张。
    # ⚠️ 3 是现在单页的上限（界面/执行/账号 各 3 张），所以这条只拦得住
    #    "每页都多一张"那种漏法；上面那条合计才是主力。
    C("★★ 没有卡片落在导航外面（落在外面的话每一页都会看见它）",
      all(len(v) <= 3 for v in seen.values()), seen)

    C("★★ 整场没有 JS 报错", not errors, "\n".join(errors[:4]))
    page.screenshot(path=OUT + "/settings.png", full_page=True)
    b.close()

sys.exit(C.done())
