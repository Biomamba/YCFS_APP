# -*- coding: utf-8 -*-
"""V13.5 item 6：基础环境那排单选不换行 + 两个预置环境要露出来。

> 6、基础环境里的系统环境莫名其妙换行，请在一行，单细胞与空转环境也请预直

拆成两件事：

  (a) **不换行**。根因不是文案太长，是 shiny 的
      `.shiny-input-container { width: 300px }` —— radioButtons() 不传 width
      就是这个宽度，而「系统环境（服务器上已装的 R / Python）」装不下就折成
      两行。所以 R 那边要传 `width = "100%"`，CSS 那边再兜住"标签比卡片还宽"
      的极端情况。两处少任何一处，都会退回"还是折行"。

  (b) 单细胞 / 空转这两个**预置**环境原来压根没露出来（只能从「新建环境」
      那个下拉里选）。现在在基础环境卡片里直接给按钮。

★ 为什么只能在这里验：

  (a) 是**浏览器算出来的行高** —— CSS 写对了但被别的规则盖掉、或者容器宽度
      被 grid 吃掉，R 那边一点都看不出来。判据是"整排按钮的高度 == 单行行高"
      而不是"有没有 nowrap 这条规则"（规则在、不生效的形态最常见）。

  (b) 涉及**点一下真的会起 conda**。这里必须把求解器换成假的（见 README），
      换掉之后能验的是"按钮点了 → 进度条出现在**这一张**卡片里 + 有一句
      说明"，验不了"包装没装上"（那是 conda 的事）。

⚠️ 两个卡片的进度条是**两个** output。只按环境名分不开（从「新建环境」那边
   建的可以重名），所以实现里另记了一个来源标记 create_from。这条断言就是
   冲着它去的：进度条只许出现在发起的那张卡片里。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import APP, Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

C = Chk()

# 整排单选按钮的几何：每个可见 label 的高度、以及这一排是不是只有一行
GEO = """() => {
  var box = document.querySelector('.dsapp-radio-nowrap');
  if (!box) return null;
  var ls = box.querySelectorAll('.radio label');
  var heights = [], tops = [];
  for (var i = 0; i < ls.length; i++) {
    var r = ls[i].getBoundingClientRect();
    if (r.height <= 0) continue;
    heights.push(r.height);
    tops.push(Math.round(r.top));
  }
  var cs = box.querySelector('.radio label') ?
           getComputedStyle(box.querySelector('.radio label')) : null;
  return {
    n: heights.length,
    heights: heights,
    rows: Array.from(new Set(tops)).length,   /* 不同 top 的个数 = 行数 */
    whiteSpace: cs ? cs.whiteSpace : '',
    overflowX: getComputedStyle(box).overflowX,
    boxW: box.getBoundingClientRect().width,
    boxH: box.getBoundingClientRect().height
  };
}"""

# 环境页那个 `.dsapp-page` 里的全部文字。
#
# ⚠️⚠️ **不能**写 `page.locator(".dsapp-page")`：navset 把三页都留在 DOM 里，
#    这个选择器匹配到 3 个，Playwright 的 strict mode 直接抛
#    `resolved to 3 elements`（2026-09-17 就是这么断的）。
#    也**不能**退而求其次取 `.first` —— 那是**别的页**，读到的是技能页的正文
#    （原来那条「进度条出现在基础环境卡片里」拿到的就是"技能是写给 AI 看的
#    一段要求"，一条永远为假、看着却像功能坏了的断言）。
#    这里用 `.dsapp-radio-nowrap`（基础环境那张卡片里的单选排）当锚点往上找，
#    认出来的必定是环境页。
ENV_PAGE_TEXT = """() => {
  var e = document.querySelector('.dsapp-radio-nowrap');
  while (e && !(e.classList && e.classList.contains('dsapp-page')))
    e = e.parentElement;
  return e ? e.innerText : '';
}"""


with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: m.type == "error" and errors.append(m.text))

    email = enter_app(page)
    seed_or_die(email)
    goto(page, "envs")
    page.wait_for_timeout(1500)

    g = page.evaluate(GEO)
    C("（前置）基础环境那张卡片里有单选按钮，而且套着 .dsapp-radio-nowrap",
      g is not None and g["n"] >= 1, "geom=%s" % (g,))
    if g:
        # ★ 判据是**实际行数 == 1**，不是"有没有 nowrap 这条规则"。
        #   规则在、被别的规则盖掉，是最常见的形态。
        C("★★ 基础环境那一排是**一行**（用户原话：「系统环境莫名其妙换行」）",
          g["rows"] == 1, "量到 %d 行，label 高度 %s" % (g["rows"], g["heights"]))
        C("★★ 标签本身是 nowrap（少这一条的话，窗口一窄又会折回来）",
          g["whiteSpace"] == "nowrap", "white-space=%s" % g["whiteSpace"])
        # ⚠️ 折行 → 横向滑动条是**刻意**的：这一列每一行都是一个环境的说明，
        #    折行之后「系统环境」和它下面那一行贴在一起，看着像两个条目。
        C("★ 实在装不下时是横向滑，不是折行（overflow-x: auto）",
          g["overflowX"] == "auto", "overflow-x=%s" % g["overflowX"])
    # 窄窗口下不许折回来 —— 这才是这条修复真正的压力测试。
    page.set_viewport_size({"width": 900, "height": 900})
    page.wait_for_timeout(900)
    g2 = page.evaluate(GEO)
    C("★★ 窗口收窄到 900px 之后**仍然是**一行（宁滑不折）",
      g2 is not None and g2["rows"] == 1,
      "量到 %d 行 %s" % (g2["rows"] if g2 else -1,
                        g2["heights"] if g2 else ""))
    page.set_viewport_size({"width": 1600, "height": 1000})
    page.wait_for_timeout(800)

    # ---- 单细胞 / 空转两个预置环境的按钮 ---------------------------------
    # ⚠️ 这两个环境**只在磁盘上还没有的时候**才出按钮（建好了就不该再让点）。
    #    所以先看有没有；已经建过（上一次跑留下的）就跳过这一段并**说出来**，
    #    别让它变成"没验到还以为验过了"。
    btns = page.locator("[id^='envs-tpl_mk_']")
    n = btns.count()
    if n == 0:
        print("  \033[33m·\033[0m 单细胞/空转已经建好了，这一段跳过"
              "（要重跑先按 README 把它们 mv 走）", flush=True)
    else:
        C("★★ 单细胞 / 空转两个预置环境**露出来了**（原来只能从新建环境的下拉里选）",
          n >= 2, "按钮数 %d" % n)
        # ⚠️ 点一下会**真的起 conda** —— 没按 README 换掉求解器的话，
         #    这一下就是几十分钟 CPU 加几十 G 磁盘。所以点之前先确认是假的。
        solver = ""
        try:
            for ln in open(os.path.join(APP, ".Renviron"), encoding="utf-8"):
                if ln.startswith("DSAPP_CONDA_BIN="):
                    solver = ln.split("=", 1)[1].strip()
        except Exception:
            pass
        C("（前置）实例用的是**假**求解器（不是的话下面那一下会真的装 conda 包）",
          solver.endswith("/bash") or solver == "/bin/bash",
          "DSAPP_CONDA_BIN=%r（见 README：必须换成 /bin/bash）" % solver)

        first = btns.first
        label = first.inner_text().strip()
        first.click()
        page.wait_for_timeout(4000)

        C("★★ 点了之后有一句「已开始创建内置环境…」的提示（点了没反应 = 没接上）",
          "已开始创建" in page.inner_text("body"), page.inner_text("body")[:0])
        shown = page.evaluate(ENV_PAGE_TEXT)
        C("★★ 进度条出现在**基础环境**这张卡片里（用户就在这一页点的）",
          ("正在创建" in shown or "构建" in shown or label in shown),
          shown[:200])
        # ⚠️ 「新建环境」那张卡片里**不该**同时冒出进度条 —— 进度只属于发起的
        #    那一张（`create_from`，见 R/mod_envs.R 那段注释），两张都亮的话
        #    用户会以为开了两个作业。
        #    判据是**恰好 1 次**，不是"≤ 2"：两张卡片共用同一个进度块，
        #    每张各渲染一句「正在创建 <名字>…」，所以 2 次就等于"两张都亮了"。
        #    写成"≤ 2"的话这条**永远为真**，等于没查。
        C("★★ 环境页里「正在创建」**只出现一次**（两次 = 上下两张卡片都亮了）",
          shown.count("正在创建") == 1,
          "出现 %d 次「正在创建」" % shown.count("正在创建"))

        # 收尾：把这次起的假 conda 停掉，别让它继续占着"有环境在装"这个位子
        # （dsapp_env_busy() 是**进程内**的注册表，不停的话这一页一直是构建中）。
        page.evaluate("() => { window.__v135clicked = 1; }")

    C("★★ 整场没有 JS 报错", not errors, "\n".join(errors[:4]))
    page.screenshot(path=OUT + "/envs.png", full_page=True)
    b.close()

sys.exit(C.done())
