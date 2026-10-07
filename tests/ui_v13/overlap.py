# -*- coding: utf-8 -*-
"""V13 item 5：**所有**页面上，不该叠在一起的东西有没有叠在一起。

用户的原话是两条：「发送按钮会和文件界面重合，调整下布局」和「请自动查看
其它页面的组间有没有这样的情况」。后半句是重点 —— 它要求的是一个**通用的
扫法**，不是"把发送按钮那一处修好"。所以这个脚本不针对任何具体选择器，
它对每一页做两件事：

  1. **控件被压住了吗**：找出所有可见的可交互元素（button / input / select /
     textarea / a[href] / [onclick]），取它的**中心点**问浏览器
     `document.elementFromPoint()` 返回的是谁。如果返回的不是它自己、
     也不是它的后代，那这个控件就**点不到** —— 用户看到的是"点了没反应"。
     这一条判据很硬：它不关心是谁压的、压了多少像素，只问"点得着吗"。

  2. **不该重叠的盒子重叠了吗**：把可见的"画了东西的盒子"两两求交，
     滤掉祖先/后代（那种重叠是正常的，卡片本来就包着按钮），剩下的报出来。
     这一条会松一些，所以只当线索看，断言用的是第 1 条。

★ 为什么用 elementFromPoint 而不是算矩形相交：矩形相交**根本判不出**
  "点不着"。两个元素可以矩形相交而完全不影响点击（比如父元素、透明覆盖层
  下面那个还是能点）。反过来，矩形不相交也不可能挡住。真正决定用户能不能
  点到的是**命中测试**，那就直接问浏览器要命中测试的结果。

★★ 但"命中的不是它"有两种完全不同的原因，第一版没分清，于是报了 7 页
    × 5 条的**假失败**（2026-09-16 逐一验过）：

     1) **祖先**。elementFromPoint 返回一个包含 el 的元素。祖先永远画在
        后代**下面**，所以这根本不可能是"盖住" —— 真实原因是 el 自己
        `pointer-events: none`，或者它是个没有盒子的行内元素。判据：
        `top.contains(el)` 直接放过。
     2) **被裁掉**。el 的矩形在视口里，但它被某个 overflow 祖先裁了
        （典型的是折叠的 <details>：Chrome 给闭合 details 里的内容**报了
        矩形**，但那里什么都不画）。这时命中的是下面的东西，看着就像
        "被盖住"。判据：把盖住的那个临时 `visibility: hidden` 再问一次
        —— 如果**还是**命不中 el，说明那块地方本来就没画 el，不算数。

   加上这两条之后，"报出来的一定是用户真的点不着的"，这条断言才立得住。
   假失败比漏报更贵：它会让下一个人把整条断言注释掉。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 每一页都要扫。admin 那一页只有管理员看得到，普通测试账号点进去是空的 ——
# 没关系的，扫不到控件就是 0 条，不会误报。
PAGES = ["chat", "tasks", "files", "skills", "envs", "settings", "admin"]

# ===========================================================================
# 第 1 条：可见控件能不能被点到
# ===========================================================================
COVERED_JS = r"""
() => {
  const INTERACTIVE = 'button, input, select, textarea, a[href], [onclick],' +
                      ' [role="button"], .btn, .shiny-input-container input';
  const vis = (el, r) => {
    if (r.width < 2 || r.height < 2) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    if (parseFloat(cs.opacity) < 0.1) return false;
    return true;
  };
  const label = (el) => {
    const cls = (el.className && el.className.baseVal !== undefined
                 ? el.className.baseVal : String(el.className || ''));
    const t = (el.innerText || el.value || el.getAttribute('aria-label') ||
               el.title || '').replace(/\s+/g, ' ').trim().slice(0, 30);
    return el.tagName.toLowerCase() +
           (el.id ? '#' + el.id : '') +
           (cls ? '.' + cls.split(/\s+/).slice(0, 3).join('.') : '') +
           (t ? ' «' + t + '»' : '');
  };
  // 命中的东西算不算"就是 el 本人"。label / selectize 那层壳都算 —— 点在
  // 壳上等于点在控件上（Shiny 的 radioButtons/checkboxInput 都套着 label）。
  const isSelf = (hit, el) => {
    if (!hit) return false;
    if (hit === el || el.contains(hit)) return true;
    if (hit.tagName === 'LABEL' && hit.contains(el)) return true;
    const wrap = hit.closest('label, .selectize-control, .shiny-input-container');
    return !!(wrap && wrap.contains(el));
  };
  const out = [];
  for (const el of document.querySelectorAll(INTERACTIVE)) {
    const r = el.getBoundingClientRect();
    if (!vis(el, r)) continue;
    // 中心点如果在视口外，elementFromPoint 会返回 null —— 那不是"被压住"，
    // 是"没滚到"。这一页本来就不该有滚动条，真有的话下面另有一条断言管。
    const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
    if (cx < 0 || cy < 0 || cx >= innerWidth || cy >= innerHeight) continue;
    const top = document.elementFromPoint(cx, cy);
    if (!top) continue;
    if (isSelf(top, el)) continue;
    // ① 祖先。祖先画在后代下面，不可能是"盖住"（上面注释里的第 1 类）。
    if (top.contains(el)) continue;
    // ② 把盖住的那个藏起来再问一次。还命不中 = 那块地方本来就没画 el
    //    （被 overflow 祖先裁了，或者人在闭合的 <details> 里）。
    const prev = top.style.visibility;
    top.style.visibility = 'hidden';
    const bare = document.elementFromPoint(cx, cy);
    top.style.visibility = prev;
    if (!isSelf(bare, el)) continue;
    const tr = top.getBoundingClientRect();
    out.push({
      el: label(el),
      by: label(top),
      // 压住的面积占这个控件的比例。1.0 = 整个盖住（完全点不着），
      // 0.2 = 只压了一个角（还点得着，但看着是错位的）。
      cover: Math.round(
        (Math.max(0, Math.min(r.right, tr.right) - Math.max(r.left, tr.left)) *
         Math.max(0, Math.min(r.bottom, tr.bottom) - Math.max(r.top, tr.top))) /
        (r.width * r.height) * 100) / 100,
      box: [Math.round(r.x), Math.round(r.y),
            Math.round(r.width), Math.round(r.height)]
    });
  }
  // 完全盖住（>=0.9）的排前面 —— 那些是真的点不着
  out.sort((a, b) => b.cover - a.cover);
  return out;
}
"""

# ===========================================================================
# 第 2 条：盒子两两重叠（只当线索，不作断言）
# ===========================================================================
BOXES_JS = r"""
() => {
  const vis = (el, r) => {
    if (r.width < 8 || r.height < 8) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    if (parseFloat(cs.opacity) < 0.1) return false;
    return true;
  };
  const boxy = [];
  for (const el of document.querySelectorAll('body *')) {
    const r = el.getBoundingClientRect();
    if (!vis(el, r)) continue;
    const cs = getComputedStyle(el);
    const bg = cs.backgroundColor;
    const hasBg = bg && !/rgba\(0, 0, 0, 0\)/.test(bg) &&
                  !/transparent/.test(bg);
    const outOfFlow = cs.position !== 'static';
    // 候选：画了底的盒子，或者**脱离文档流**的盒子（sticky/absolute/fixed）。
    // 只算普通流里的裸 <div> 会得到几千对无意义的重叠。
    if (!hasBg && !outOfFlow) continue;
    if (el.tagName === 'HTML' || el.tagName === 'BODY') continue;
    boxy.push({el, r, outOfFlow, bg});
  }
  const cls = (el) => {
    const c = (el.className && el.className.baseVal !== undefined
               ? el.className.baseVal : String(el.className || ''));
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
           (c ? '.' + c.split(/\s+/).slice(0, 2).join('.') : '');
  };
  const out = [];
  for (let i = 0; i < boxy.length; i++) {
    for (let j = i + 1; j < boxy.length; j++) {
      const A = boxy[i], B = boxy[j];
      if (A.el.contains(B.el) || B.el.contains(A.el)) continue;
      const w = Math.min(A.r.right, B.r.right) - Math.max(A.r.left, B.r.left);
      const h = Math.min(A.r.bottom, B.r.bottom) - Math.max(A.r.top, B.r.top);
      if (w <= 0 || h <= 0) continue;
      const inter = w * h;
      const small = Math.min(A.r.width * A.r.height, B.r.width * B.r.height);
      // 只报"把小的那个盖掉一大半"的。压一个角（<35%）的通常是图标、
      // 角标、气泡尖角之类的有意设计，报了是噪音。
      if (inter / small < 0.35 || inter < 400) continue;
      out.push({
        a: cls(A.el), b: cls(B.el),
        pct: Math.round(inter / small * 100),
        aFlow: A.outOfFlow ? 'out' : 'flow',
        bFlow: B.outOfFlow ? 'out' : 'flow'
      });
    }
  }
  out.sort((a, b) => b.pct - a.pct);
  return out.slice(0, 40);
}
"""


# 把内层滚动区推到底。★ 不滚的话，**首屏以下的内容一条都扫不到** —— 而
# 布局类的毛病（内容放不下、被钉住的横条压住）恰恰都长在页面下半截。
# "只扫首屏"是个看不出来的覆盖缺口：输出照样全绿。
SCROLL_JS = r"""
() => {
  const sels = ['.dsapp-main-body', '.dsapp-chat-scroll',
                '.bslib-sidebar-layout > .sidebar', '.sidebar-content'];
  let moved = 0;
  for (const s of sels) {
    for (const el of document.querySelectorAll(s)) {
      const before = el.scrollTop;
      el.scrollTop = el.scrollHeight;
      if (el.scrollTop !== before) moved++;
    }
  }
  return moved;
}
"""


def scan(page, label, chk, strict=True):
    """扫当前这一页（首屏 + 滚到底各一遍）。strict=True 时把"被盖住的控件"当失败。"""
    cov = page.evaluate(COVERED_JS)

    moved = page.evaluate(SCROLL_JS)
    page.wait_for_timeout(1200)
    cov_bot = page.evaluate(COVERED_JS)
    page.evaluate("() => { for (const el of document.querySelectorAll("
                  "'.dsapp-main-body, .dsapp-chat-scroll')) el.scrollTop = 0; }")
    page.wait_for_timeout(600)

    if moved:
        print("       （页面能滚：内层滚动区 %d 个，已经连底部一起扫过）" % moved)

    # 同一处可能在两遍里都出现，按 (控件, 盖住者) 去重
    seen, cov = set(), cov + cov_bot
    uniq = []
    for c in cov:
        k = (c["el"], c["by"])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(c)
    cov = uniq

    hard = [c for c in cov if c["cover"] >= 0.9]
    soft = [c for c in cov if c["cover"] < 0.9]

    chk("%s：没有被完全盖住的控件" % label, not hard,
        "完全点不着的控件：\n" + "\n".join(
            "      %-52s 被 %-40s 盖住 %d%%" % (c["el"], c["by"], c["cover"] * 100)
            for c in hard[:8]))
    if soft:
        print("       （提示：%d 个控件被压住一角，还点得着 —— 记下来看看"
              "是不是有意的）" % len(soft))
        for c in soft[:4]:
            print("          %-50s 被 %s 压 %d%%"
                  % (c["el"], c["by"], c["cover"] * 100))
    return cov


def main():
    only = sys.argv[1:] or PAGES
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--no-sandbox"])
        # 用一个**矮一点**的视口：重叠类的问题在"内容放不下"的时候才出现，
        # 视口给得越宽松越扫不到东西。1000 高是常见笔记本的可用高度。
        pg = b.new_page(viewport={"width": 1440, "height": 900})
        try:
            enter_app(pg)
            for p in only:
                print("\n== %s 页 ==" % p)
                goto(pg, p, 3000)
                scan(pg, "%s 页" % p, chk)
                boxes = pg.evaluate(BOXES_JS)
                if boxes:
                    print("       （线索：%d 对盒子互相重叠 >=35%%）" % len(boxes))
                    for x in boxes[:6]:
                        print("          %-34s × %-34s  %d%%  [%s/%s]"
                              % (x["a"], x["b"], x["pct"], x["aFlow"], x["bFlow"]))
                pg.screenshot(path=os.path.join(OUT, "overlap_%s.png" % p),
                              full_page=True)
        finally:
            b.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
