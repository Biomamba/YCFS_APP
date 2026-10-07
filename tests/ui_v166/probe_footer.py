# -*- coding: utf-8 -*-
"""V16.6 item 6：页脚那个「获取最新版」链接（版本号后面）。

跑法（实例先起好）：
    bash tests/ui_v7/make_instance.sh 8977 /tmp/dsapp_v166a
    python3 tests/ui_v166/probe_footer.py

为什么这件事非得上浏览器：`selftest.R` 那一节已经把 `dsapp_footer_ui()` 渲染
成 HTML 逐字查过了（href / target / rel / 文案 / 顺序 / CSS 里有 nowrap）——
**HTML 里有 ≠ 用户看得见、摸得着**。这一页只回答渲染层答不了的两件事：

  A. 登录页（还没进主界面）上它就画得出来、点得到 —— 页脚是两处共用的，
     只验主界面会漏掉"入口页那一份忘了画"（V6 那次就是这么白屏的）
  B. **页脚没有折成两行**：`.dsapp-footer` 是 `position:fixed`，高度只有
     `--dsapp-footer-h`（宽屏 2.6rem、窄屏 4.4rem，定义在 www/skins.css），
     而 `#app_root` 的 padding-bottom 补的正是这一个数 —— **内容一旦折行，
     页脚会盖住页面底部**，而且只在某些宽度下出现。这是本仓反复强调的那条，
     也是加这个链接唯一的风险。

★ B 段带一个**对照**：往页脚里塞一段很长的假文字，判据必须当场变红（证明它
  真的量得出来"两行"），拿掉之后必须回到绿。本仓规矩：判据要和**已知会红**
  的样本对一次 —— 否则"页脚没折行"可能只是因为这条判据根本没在量。

⚠️ 不点那个链接：它是 `target="_blank"` 指向 github.com 的**真外链**，
   点下去就是往公网发一个请求（本仓栽过：夹具把请求打到了厂商）。
   这里只断言 href/target/rel 三个属性。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

C.guard(C.APP)          # 防止连到生产库
CK = C.Chk()
WANT = "https://github.com/Biomamba/YCFS_APP"

# 量页脚的几何：一次把要用的数都取回来。
# ⚠️ 过滤掉"看得见"的子元素用的是 `getClientRects().length`，不是 offsetParent
#   —— 页脚是 fixed，offsetParent 恒为 null。也用不着 inner_text（隐藏元素
#   的文本是空串，那正是本仓栽过的那个坑：把"藏起来了"和"没画"混成一个）。
MEASURE = r"""
() => {
  const f = document.querySelector('.dsapp-footer');
  if (!f) return {err: '页脚整个不在 DOM 里'};
  const r = f.getBoundingClientRect();
  // 把 --dsapp-footer-h 解析成像素（自定义属性读出来是 "2.6rem" 这种原样字符串）
  const p = document.createElement('div');
  p.style.cssText = 'position:absolute;visibility:hidden;height:' +
    getComputedStyle(document.documentElement).getPropertyValue('--dsapp-footer-h');
  document.body.appendChild(p);
  const varH = p.getBoundingClientRect().height;
  p.remove();
  const kids = [...f.children]
    .filter(e => e.getClientRects().length > 0)
    .map(e => ({cls: String(e.className), top: e.getBoundingClientRect().top,
                h: e.getBoundingClientRect().height}));
  const tops = kids.map(k => k.top);
  const link = f.querySelector('.dsapp-footer-getver');
  const root = document.querySelector('#app_root');
  return {
    h: r.height, topmost: Math.min(...tops), bottommost: Math.max(...tops),
    rows: Math.max(...tops) - Math.min(...tops),
    varH: varH, nkid: kids.length, kids: kids,
    rootPad: root ? parseFloat(getComputedStyle(root).paddingBottom) : null,
    link: link ? {
      href: link.getAttribute('href'), target: link.getAttribute('target'),
      rel: link.getAttribute('rel'),
      // ⚠️ 文案取的是**看得见的那一段**：长短两段都在 DOM 里（CSS 二选一），
      //    用 textContent 会拿到 "获取最新版\n 最新版" 两段拼起来的串 ——
      //    探针第一版就是这么写的，然后自己红了（见文件末尾那段记录）。
      text: [...link.querySelectorAll('span')]
              .filter(s => s.getClientRects().length > 0)
              .map(s => s.textContent.trim()).join(''),
      w: link.getBoundingClientRect().width,
      h: link.getBoundingClientRect().height,
      vis: link.getClientRects().length > 0,
    } : null,
  };
}
"""


def measure(pg):
    m = pg.evaluate(MEASURE)
    assert "err" not in m, "量页脚失败了：%s" % m.get("err")
    return m


def single_row(m, tag):
    """一行 = 所有可见子元素基本在同一条水平线上，且页脚没被撑高。

    ⚠️ 两个数一起看：只量高度的话，一个"折了行但恰好等于 min-height 的
       页脚"会假绿；只量 tops 的话，子元素被撑高（比如换行但 top 一样）也
       漏。两个都过才算一行。
    """
    CK("%s 页脚是一行（子元素 top 差 %.1fpx，阈值 8）" % (tag, m["rows"]),
       m["rows"] < 8.0, "子元素 %d 个" % m["nkid"])
    CK("%s 页脚高度没被撑破（%.1fpx ≤ 变量 %.1fpx）" % (tag, m["h"], m["varH"]),
       m["h"] <= m["varH"] + 1.0)
    # ★ 这条才是"折行"真正的后果：padding-bottom 是按变量给的，页脚一旦比它
    #   高，就压住页面最后一屏 —— 只在某些宽度下出现，最难查的那类。
    CK("%s #app_root 的 padding-bottom 兜得住页脚（%.1f ≥ %.1f）"
       % (tag, m["rootPad"] or -1, m["h"]),
       (m["rootPad"] or -1) >= m["h"] - 1.0)


with sync_playwright() as p:
    br = p.chromium.launch()
    pg = br.new_page(viewport={"width": 1440, "height": 900})
    try:
        pg.goto(C.URL, wait_until="domcontentloaded")
        if not C.wait_awake(pg):
            raise SystemExit("实例一直没醒（登录页 150 秒都没出现）")
        C.ensure_no_modal(pg)

        # ---- A. 登录页上就有 --------------------------------------------------
        CK("A 前置：现在确实停在**登录页**（这一段的全部意义就是入口页）",
           pg.locator(".dsapp-auth").count() > 0)
        m = measure(pg)
        lk = m["link"]
        CK("A ★★★ 登录页的页脚里就有这个链接", lk is not None)
        if lk:
            CK("A ★★★ 而且它**看得见**（矩形不是全 0 —— 隐藏元素量出来是 0）",
               lk["vis"] and lk["w"] > 10 and lk["h"] > 5,
               "w=%.1f h=%.1f" % (lk["w"], lk["h"]))
            CK("A ★★★ href 就是用户给的那个仓库", lk["href"] == WANT,
               repr(lk["href"]))
            CK("A ★★ 新窗口打开 + rel=noopener noreferrer",
               lk["target"] == "_blank" and lk["rel"] == "noopener noreferrer",
               "target=%r rel=%r" % (lk["target"], lk["rel"]))
            CK("A ★★★ 宽屏上是「获取最新版」五个字，不是别的文案",
               lk["text"] == "获取最新版", repr(lk["text"]))
            # 位置：链接在版本号**右边**（用户要的是"版本号后面"）
            pos = pg.evaluate(
                "() => {const v=document.querySelector('.dsapp-footer-ver');"
                "const g=document.querySelector('.dsapp-footer-getver');"
                "if(!v||!g) return null;"
                "return {v: v.getBoundingClientRect().right,"
                "        g: g.getBoundingClientRect().left,"
                "        vt: v.getBoundingClientRect().top,"
                "        gt: g.getBoundingClientRect().top};}")
            CK("A ★★★ 链接在版本号的**右边**、同一行（用户指定的位置）",
               pos and pos["g"] > pos["v"] and abs(pos["gt"] - pos["vt"]) < 8,
               repr(pos))
        single_row(m, "A")

        # ---- B. 对照：折成两行时判据必须红 -----------------------------------
        # 塞一段很长的假文字进页脚 —— 这正好模拟"文案太长/窗口太窄"那个故障。
        pg.evaluate(
            "() => {const f=document.querySelector('.dsapp-footer');"
            "const d=document.createElement('span');"
            "d.id='dsapp-probe-filler';"
            "d.textContent='占位'.repeat(60);"
            "f.appendChild(d);}")
        pg.wait_for_timeout(150)
        m2 = measure(pg)
        CK("B ★★★ 对照：塞长文字进页脚后，**高度判据当场变红**（证明它真的量得出来两行）",
           m2["h"] > m2["varH"] + 1.0 or m2["rows"] >= 8.0,
           "h=%.1f 变量=%.1f rows=%.1f" % (m2["h"], m2["varH"], m2["rows"]))
        CK("B ★★ 对照：而且 padding-bottom 那条也会红（页脚真的比它高了）",
           (m2["rootPad"] or -1) < m2["h"] - 1.0,
           "pad=%.1f h=%.1f" % (m2["rootPad"] or -1, m2["h"]))
        pg.evaluate("() => {const d=document.getElementById('dsapp-probe-filler');"
                    "if(d) d.remove();}")
        pg.wait_for_timeout(150)
        m3 = measure(pg)
        CK("B ★★ 拿掉之后回到一行（对照两侧都试过，判据不是「永远红」）",
           m3["rows"] < 8.0 and m3["h"] <= m3["varH"] + 1.0)

        # ---- C. 换短文案的那一档（768px 以下）--------------------------------
        pg.set_viewport_size({"width": 700, "height": 800})
        pg.wait_for_timeout(400)
        m4 = measure(pg)
        lk4 = m4["link"]
        CK("C ★★ 700px 上链接还在、还看得见",
           lk4 and lk4["vis"] and lk4["w"] > 10)
        if lk4:
            CK("C ★★★ 这一档换成短文案「最新版」（长的那段被 @media 藏了）",
               lk4["text"] == "最新版", repr(lk4["text"]))
            CK("C ★★ 换的只是文案，href 一个字没动", lk4["href"] == WANT)
        single_row(m4, "C")
        pg.screenshot(path=C.OUT + "/footer_700.png", full_page=True)

        # ---- D. 手机宽度：还是一行（这是这一版调过档位的地方）-----------------
        # ⚠️ 480 这一档**必须一行**：加链接之前它是一行，加完之后一度变成两行
        #    （量出来 60.6px > 41.6px），那是这一版自己弄出来的回归。修法是
        #    把「获取最新版→最新版」和旁边那句客服一起提前到 768 那一档换。
        pg.set_viewport_size({"width": 480, "height": 800})
        pg.wait_for_timeout(400)
        m5 = measure(pg)
        CK("D ★★ 480px 上链接仍然在、而且是短文案",
           m5["link"] and m5["link"]["vis"] and m5["link"]["text"] == "最新版",
           repr(m5["link"]["text"] if m5["link"] else None))
        single_row(m5, "D")
        pg.screenshot(path=C.OUT + "/footer_480.png", full_page=True)

        # ---- E. 手机竖屏：放不下就是放不下，但**不许压住内容** ---------------
        # 实测这一档页脚要两行（423px 的内容塞进 376px），而且**加链接之前
        # 就是两行**（B 段那两个对照 + diag 单独摘掉链接量过）。所以这里不断言
        # "一行"，断言的是那条真正要命的性质：预留高度必须兜得住实际高度。
        pg.set_viewport_size({"width": 360, "height": 800})
        pg.wait_for_timeout(400)
        m6 = measure(pg)
        CK("E ★★★ 360px 上预留高度兜得住页脚（--dsapp-footer-h 在窄屏放大过）",
           (m6["rootPad"] or -1) >= m6["h"] - 1.0,
           "pad=%.1f 页脚=%.1f 行差=%.1f" % (m6["rootPad"] or -1, m6["h"],
                                            m6["rows"]))
        CK("E ★★ 而且它真的折了（这条是在记录事实，不是在夸它）",
           m6["rows"] >= 8 or m6["h"] > m6["varH"] + 1,
           "h=%.1f 变量=%.1f" % (m6["h"], m6["varH"]))
        pg.screenshot(path=C.OUT + "/footer_360.png", full_page=True)

        pg.set_viewport_size({"width": 1440, "height": 900})
        pg.wait_for_timeout(400)
        pg.screenshot(path=C.OUT + "/footer_wide.png", full_page=True)
        CK("F ★ 切回宽屏文案又变回「获取最新版」（两个方向都试过）",
           measure(pg)["link"]["text"] == "获取最新版")
    finally:
        pg.screenshot(path=C.OUT + "/footer_final.png", full_page=True)
        br.close()

CK.done()
