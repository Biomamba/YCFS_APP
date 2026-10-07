# -*- coding: utf-8 -*-
"""V13.2 item 5：面板宽高可以用户自定义，而且要自适应、不许相互堆叠。

用户的原话：
  「侧面导航栏，二级目录中，例如言出法随界面中的输出界面的宽高，能不能
    支持用户自定义？记得做好自适应，不要相互堆叠」

★ 这个脚本回答的是 selftest.R 里那段回答不了的问题：**拖一下，页面真的
  变了吗**。selftest 只能证明"存进去的是 420"，证明不了"420 真的落到了那
  一栏上"。而这一条链路上任何一环断掉（CSS 变量名拼错、var() 的 fallback
  对不上、类没加上、内联值压着样式表），R 那边全是绿的 —— 浏览器不报错。

量什么：
  1. 拖左边那条竖线 → 文件区变宽/变窄，箭头方向对不对（往左拖=变宽）；
  2. 拖下面那条横线 → 输入区变高，输出框变矮，两者之和不变（这是"不要
     相互堆叠"的核心：它们是同一块空间的两种分法，不是各自长高）；
  3. 刷新之后设置还在（这条只有走服务端存库才能过 —— 纯客户端的拖拽
     一定在刷新后弹回默认）；
  4. 拖到极端时自己收住（不出现横向滚动条、两列不重叠）；
  5. 窗口变窄（≤1100px）时两列改成上下叠放、分隔条藏起来。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 量版面：把这一页上和尺寸有关的矩形一次全取回来。
#
# ⚠️ 不加这一层封装、逐个元素 query 的话，每次都要重新取一遍容器宽度，而
#    拖动之后容器宽度是**会变的** —— 拿旧值去算边界，断言就会时对时错。
PROBE = r"""
() => {
  const q = (s) => document.querySelector(s);
  const rect = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.x), y: Math.round(r.y),
             w: Math.round(r.width), h: Math.round(r.height),
             right: Math.round(r.right), bottom: Math.round(r.bottom) };
  };
  const files  = q('.dsapp-files-col');
  const chat   = q('.dsapp-chat-col');
  const main   = q('.dsapp-chat-main');
  const page   = q('.dsapp-chat-page');
  const comp   = q('.dsapp-composer');
  // ⚠️⚠️ 这里必须写 **id**，不能写 `.dsapp-split-v`。
  //    V13.5 给执行历史那条分隔条（#tasks-split_t）也挂了这个类 —— 它确实是
  //    同一种竖条，类名共用是对的 —— 于是裸类名一次匹配到 2 个元素，
  //    Playwright 的 strict mode 直接抛 `resolved to 2 elements`。
  //    （拿 V13.4 的归档跑这份测试是绿的，所以这是"产品改对了、老选择器过时了"，
  //    不是功能坏了。）
  const sv     = q('#chat-split_v');
  const sh     = q('.dsapp-split-h');
  const cs     = getComputedStyle(document.documentElement);
  return {
    files: rect(files), chat: rect(chat), main: rect(main),
    page: rect(page), comp: rect(comp), sv: rect(sv), sh: rect(sh),
    var_w: cs.getPropertyValue('--dsapp-files-w').trim(),
    var_h: cs.getPropertyValue('--dsapp-composer-h').trim(),
    fixed: document.documentElement.classList.contains('dsapp-fixed-composer'),
    // 整页有没有被顶出横向滚动条 —— "不要相互堆叠"最直白的判据
    overflow_x: document.documentElement.scrollWidth -
                document.documentElement.clientWidth,
    sv_display: sv ? getComputedStyle(sv).display : null,
    // 竖线是不是真的在"两列之间"（不是被 flex 挤到别处去了）
    sv_between: !!(files && chat && sv &&
                   sv.getBoundingClientRect().x >= chat.getBoundingClientRect().right - 2 &&
                   sv.getBoundingClientRect().right <= files.getBoundingClientRect().x + 2)
  };
}
"""


def probe(page):
    return page.evaluate(PROBE)


def drag(page, sel, dx, dy, steps=12):
    """按住 sel 拖 (dx, dy)。dx > 0 = 往右拖。

    ⚠️ 不能只发一次 mousemove：处理器里第一下有 `if (!d && !drag.moved) return`，
       而且真实指针本来就是一路小步走的。分步也更接近用户手速，能顺带把
       "只在 pointerdown 时算一次起点" 这种写法暴露出来。
    """
    box = page.locator(sel).bounding_box()
    if not box:
        return False
    cx = box["x"] + box["width"] / 2
    cy = box["y"] + box["height"] / 2
    page.mouse.move(cx, cy)
    page.mouse.down()
    for i in range(1, steps + 1):
        page.mouse.move(cx + dx * i / steps, cy + dy * i / steps)
        page.wait_for_timeout(15)
    page.mouse.up()
    page.wait_for_timeout(900)     # 等上报走完一个来回（存库 + 重发 style）
    return True


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        page = br.new_page(viewport={"width": 1600, "height": 950})
        email = enter_app(page)
        uid, dbp = seed_or_die(email)
        print("  账号 uid=%s  db=%s" % (uid, dbp))

        goto(page, "chat", wait=4000)

        # ---- 0. 前提：分隔条在，而且在正确的位置 ----
        p0 = probe(page)
        if not chk("★ 前提：两条分隔条都渲染出来了",
                   p0["sv"] and p0["sh"] and p0["files"] and p0["comp"], p0):
            br.close()
            return chk.done()
        chk("★ 竖线夹在「输出列」和「文件列」之间（不是浮在别处）",
            p0["sv_between"], p0)

        # ★★ 这一条要单独量，而且必须是 elementFromPoint 而不是 boundingBox。
        #    "分隔条画在正确的位置"和"分隔条点得着"是两回事：被兄弟元素盖住
        #    的时候位置完全正确、矩形也完全正确，就是按下去没反应 ——
        #    2026-09-16 横向那条就是这么坏的（下沿被 composer 压了 3px，
        #    正中间正好在边界上）。这跟 V13 item 5「发送按钮点不着」同类。
        hit = page.evaluate("""() => {
          const out = {};
          for (const k of ['v', 'h']) {
            const el = document.querySelector('.dsapp-split-' + k);
            if (!el) { out[k] = 'missing'; continue; }
            const r = el.getBoundingClientRect();
            const t = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
            out[k] = t === el ? 'self'
                   : (t ? t.tagName + '.' + (t.className || '').toString().split(' ')[0]
                        : 'null');
          }
          return out;
        }""")
        chk("★★ 两条分隔条的**正中间**都点得着（没被兄弟元素盖住）",
            hit["v"] == "self" and hit["h"] == "self", hit)
        chk("★ 默认宽度 320（app.css 里 var() 的 fallback 和 R 那边对得上）",
            abs(p0["files"]["w"] - 320) <= 4,
            "实际 %s，变量 %r" % (p0["files"]["w"], p0["var_w"]))
        chk("★ 默认不干预输入区高度（没加 dsapp-fixed-composer）",
            p0["fixed"] is False and p0["var_h"] in ("0px", ""), p0["var_h"])

        # ---- 1. 往左拖竖线 = 文件区变宽 ----
        drag(page, "#chat-split_v", -120, 0)
        p1 = probe(page)
        chk("★★ 往左拖 120px → 文件区真的变宽了（方向没反）",
            p1["files"]["w"] > p0["files"]["w"] + 60,
            "%d → %d" % (p0["files"]["w"], p1["files"]["w"]))
        chk("★★ 输出列相应变窄，两列**互不重叠**（右沿 ≤ 左沿）",
            p1["chat"]["right"] <= p1["files"]["x"] + 2,
            "输出列右沿 %d / 文件列左沿 %d" % (p1["chat"]["right"], p1["files"]["x"]))
        chk("★ 整页没被顶出横向滚动条",
            p1["overflow_x"] <= 0, "溢出 %d px" % p1["overflow_x"])
        w_after_drag = p1["files"]["w"]

        # ---- 2. 刷新之后还在吗（这条只有真存了库才能过）----
        page.reload(wait_until="domcontentloaded")
        page.wait_for_selector(".dsapp-shell", timeout=60000)
        page.wait_for_timeout(3500)
        goto(page, "chat", wait=2500)
        p2 = probe(page)
        chk("★★★ 刷新之后宽度还在（存到了服务端，不是只改了浏览器上的变量）",
            abs(p2["files"]["w"] - w_after_drag) <= 6,
            "刷新前 %d → 刷新后 %d（变量 %r）"
            % (w_after_drag, p2["files"]["w"], p2["var_w"]))

        # ---- 3. 拖横线 = 调输出框和输入区的分配 ----
        h_before, comp_before = p2["page"]["h"], p2["comp"]["h"]
        drag(page, ".dsapp-split-h", 0, -80)      # 往上拖 = 输入区变高
        p3 = probe(page)
        chk("★★ 往上拖横线 → 输入区变高、输出框变矮（同一块空间的两种分法）",
            p3["comp"]["h"] > comp_before + 30 and
            p3["fixed"] is True and p3["var_h"] not in ("0px", ""),
            "输入区 %d → %d，变量 %r，类 %s"
            % (comp_before, p3["comp"]["h"], p3["var_h"], p3["fixed"]))

        # ★★ 这一条才是用户说的"不要相互堆叠"：上面那两块的**总高度**不该变
        #    （页面本身没有滚动条的话）。
        chk("★★ 拖完之后页面总高没变（不是把谁挤出可视区，是重新分配）",
            abs(p3["page"]["h"] - h_before) <= 4,
            "%d → %d" % (h_before, p3["page"]["h"]))
        chk("★★ 输入区下沿没越过这一页的下边（没被挤到屏幕外面去）",
            p3["comp"]["bottom"] <= p3["page"]["bottom"] + 2,
            "输入区底 %d / 页底 %d" % (p3["comp"]["bottom"], p3["page"]["bottom"]))
        chk("★ 输入框本体还在输入区里面（没被压成 0 高）",
            p3["comp"]["h"] >= 90, "输入区高 %d" % p3["comp"]["h"])

        # ---- 4. 拖到极端：自己收住，不许把版面撑破 ----
        drag(page, "#chat-split_v", -1200, 0, steps=20)   # 一直往左拖到底
        p4 = probe(page)
        chk("★★ 拖到顶天时宽度被封住（没把输出列挤成负数 / 没溢出屏幕）",
            p4["files"]["w"] <= p4["main"]["w"] * 0.62 + 8 and
            p4["chat"]["w"] >= 120 and p4["overflow_x"] <= 0,
            "文件列 %d / 主区 %d，输出列 %d，横向溢出 %d"
            % (p4["files"]["w"], p4["main"]["w"], p4["chat"]["w"],
               p4["overflow_x"]))

        drag(page, ".dsapp-split-h", 0, 900, steps=20)     # 一直往下拖到底
        p5 = probe(page)
        chk("★★ 往下拖到底时输入区收在下限，不会缩没、也不会盖住输出框",
            p5["comp"]["h"] >= 90 and p5["comp"]["y"] >= p5["chat"]["y"] + 60,
            "输入区高 %d，输入区顶 %d / 输出列顶 %d"
            % (p5["comp"]["h"], p5["comp"]["y"], p5["chat"]["y"]))

        # ---- 5. 双击 = 回默认 ----
        box = page.locator("#chat-split_v").bounding_box()
        page.mouse.dblclick(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.wait_for_timeout(1200)
        p6 = probe(page)
        chk("★★ 双击竖线 → 宽度回默认 320",
            abs(p6["files"]["w"] - 320) <= 6,
            "现在 %d，变量 %r" % (p6["files"]["w"], p6["var_w"]))

        box = page.locator(".dsapp-split-h").bounding_box()
        page.mouse.dblclick(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.wait_for_timeout(1200)
        p7 = probe(page)
        chk("★★ 双击横线 → 回到「自动高度」（类摘掉、变量归零）",
            p7["fixed"] is False and p7["var_h"] in ("0px", ""),
            "类 %s，变量 %r" % (p7["fixed"], p7["var_h"]))

        # ---- 6. 键盘那条路（分隔条 tabindex=0）----
        page.locator("#chat-split_v").focus()
        page.wait_for_timeout(300)
        for _ in range(5):
            page.keyboard.press("ArrowLeft")     # 左 = 变宽，每次 10px
            page.wait_for_timeout(120)
        page.wait_for_timeout(900)
        p8 = probe(page)
        chk("★★ 键盘：焦点在竖线上按 5 次左方向键 → 宽了约 50px",
            abs(p8["files"]["w"] - (p6["files"]["w"] + 50)) <= 14,
            "%d → %d（期望约 %d）"
            % (p6["files"]["w"], p8["files"]["w"], p6["files"]["w"] + 50))
        chk("★ 而且焦点没跑（没被自己的重渲染踢掉）",
            page.evaluate("() => document.activeElement && "
                          "document.activeElement.classList.contains('dsapp-split-v')"))

        # ---- 7. 设置页那张卡片 ----
        goto(page, "settings", wait=3000)
        got = page.evaluate("""() => {
          const w = document.querySelector('#settings-pref_files_w');
          const h = document.querySelector('#settings-pref_composer_h');
          return { w: w ? w.value : null, h: h ? h.value : null,
                   reset: !!document.querySelector('#settings-pref_reset') };
        }""")
        chk("★★ 设置页里有宽度/高度两个数字框，值就是刚才拖出来的",
            got["w"] is not None and got["h"] is not None and got["reset"] and
            abs(int(float(got["w"])) - p8["files"]["w"]) <= 8,
            "%s（页面上是 %d）" % (got, p8["files"]["w"]))

        page.fill("#settings-pref_files_w", "640")
        page.locator("#settings-pref_files_w").press("Enter")
        page.wait_for_timeout(1500)
        goto(page, "chat", wait=2500)
        p9 = probe(page)
        chk("★★★ 在设置页填 640 → 言出法随页那一栏真的变成 640",
            abs(p9["files"]["w"] - 640) <= 8,
            "实际 %d（变量 %r）" % (p9["files"]["w"], p9["var_w"]))

        goto(page, "settings", wait=3000)
        page.click("#settings-pref_reset")
        page.wait_for_timeout(1500)
        got2 = page.evaluate("""() => {
          const w = document.querySelector('#settings-pref_files_w');
          return w ? w.value : null;
        }""")
        chk("★★ 「恢复默认」把输入框自己也按回 320（不只是改页面）",
            got2 is not None and abs(int(float(got2)) - 320) <= 2, got2)
        goto(page, "chat", wait=2500)
        p10 = probe(page)
        chk("★★ 而且页面上也跟着回默认了", abs(p10["files"]["w"] - 320) <= 6,
            "实际 %d" % p10["files"]["w"])

        # ---- 8. 窄屏：两列上下叠放，分隔条藏起来 ----
        page.set_viewport_size({"width": 900, "height": 900})
        page.wait_for_timeout(1800)
        p11 = probe(page)
        chk("★★ 窗口 ≤1100px 时竖线隐藏（宽度设置不再适用）",
            p11["sv_display"] == "none", "display=%r" % p11["sv_display"])
        chk("★★ 而且两列改成上下叠放（文件列跑到输出列下面，不是并排挤着）",
            p11["files"]["y"] >= p11["chat"]["bottom"] - 2,
            "输出列底 %d / 文件列顶 %d" % (p11["chat"]["bottom"], p11["files"]["y"]))
        chk("★ 窄屏下也不横向溢出", p11["overflow_x"] <= 0,
            "溢出 %d px" % p11["overflow_x"])
        page.screenshot(path=OUT + "/panels_narrow.png", full_page=True)

        page.set_viewport_size({"width": 1600, "height": 950})
        page.wait_for_timeout(1500)
        page.screenshot(path=OUT + "/panels_wide.png", full_page=True)
        br.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
