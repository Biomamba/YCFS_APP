# -*- coding: utf-8 -*-
"""V16.5 item 2：**对话框下面那一排设置控件的高度要一致**。

用户原话：「对话框下面的设置组件高度请统一」。

⚠️ 这条是**量出来**的，不是看一眼 CSS 猜出来的。第一版想当然地以为
   "都是下拉框，肯定一样高" —— 而 `www/app.css` 里那条
   `.dsapp-ctrl select.form-select`（本意就是"把这一排压扁"）**一个元素都
   没命中**：Shiny 的 selectInput 默认 `selectize = TRUE`，画出来的是
   `.selectize-control > .selectize-input`，**DOM 里根本没有 <select>**。
   于是这一排的高度一直是各家库的默认值说了算（实测四种控件、四个数：
   下拉框 36.5 / 数字框 26.5 / 滑块 40 / 勾那一行 28）。

判据分三层，**少了任何一层都会漏掉一整类坏法**：
  ① 每个控件自己的高度 —— 漏了它，就会出现"下拉框比旁边高一头"；
  ② 每一**格**（.dsapp-ctrl-box）的高度按行分组后必须相等 —— 漏了它，
     一排格子会顶边参差（用户看到的"高度不一样"一半来自这里）；
  ③ 滑块的**零件**（.irs-handle / .irs-line）必须落在 .irs 自己的盒子里 ——
     ★★ 这一条是针对本版真踩过的坑：只把 `.irs` 的高度改成 26px 是不够的，
     因为库的 `.irs--shiny .irs-handle { top: 17px }` 和我们的
     `.dsapp-ctrl-bar .irs-handle` **权重一样**，而库的 CSS 排在后面 ——
     它赢。结果是"外框 26px、里面按 40px 摆"：轨道贴着盒底、把手整颗冒到
     盒子下面去，压在下一行的字上。**只量外框的话这个 bug 全绿。**

用法：
    python3 tests/ui_v165/probe_heights.py             # 只量，打印一张表
    python3 tests/ui_v165/probe_heights.py --assert    # 量 + 断言（收尾用）

⚠️ 量之前必须先 `ensure_no_modal()`：新账号第一次开对话会弹一个
   「AI 怎么干活？」，它盖在整页上 —— 有它在，所有 click 都报
   「intercepts pointer events」，而报错指向的是被点的那颗按钮。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

ASSERT = "--assert" in sys.argv
WANT = float(os.environ.get("DSAPP_TEST_CTRL_H", "26"))

# 量整排的每一件东西。一律**在 .dsapp-ctrl-bar 里面**取 —— 全页取的话
# 会量到别的页里的同名控件（bslib 把所有页都留在 DOM 里、只藏不激活），
# 而那种错法看起来是"高度没问题"。
JS = r"""
() => {
  const out = [];
  const rect = (el) => {
    const r = el.getBoundingClientRect();
    return {h: Math.round(r.height * 100) / 100,
            w: Math.round(r.width * 100) / 100,
            top: Math.round(r.top * 100) / 100,
            bottom: Math.round(r.bottom * 100) / 100};
  };
  const cs = (el) => {
    const c = getComputedStyle(el);
    // ⚠️ 隐藏元素（别的页里的同名控件）矩形是全 0：拿它做减法得到的数
    //    看着完全合理。所以 display 一起带出来，断言里要挡住它。
    return {disp: c.display, vis: c.visibility, fs: c.fontSize,
            pt: c.paddingTop, pb: c.paddingBottom};
  };
  const put = (label, el, kind, extra) => {
    if (!el) { out.push({label, kind, missing: true}); return; }
    out.push(Object.assign({label, kind, cls: (el.className || '').toString().slice(0, 60)},
                           rect(el), cs(el), extra || {}));
  };

  // ① 控件：下拉框 / 数字框 / 滑块外框 / 勾那一行
  document.querySelectorAll('.dsapp-ctrl-bar select.form-select')
    .forEach((el, i) => put('原生下拉#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar .selectize-input')
    .forEach((el, i) => put('下拉框#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar input.form-control')
    .forEach((el, i) => put('数字框#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar .irs')
    .forEach((el, i) => put('滑块#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar .dsapp-unlim-item')
    .forEach((el, i) => put('勾行#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar .dsapp-agent-bar > .form-group')
    .forEach((el, i) => put('勾行A#' + i, el, 'ctrl'));
  document.querySelectorAll('.dsapp-ctrl-bar .dsapp-skillbar')
    .forEach((el, i) => put('技能格#' + i, el, 'ctrl'));

  // ③ 滑块的零件：必须落在 .irs 自己的盒子里（见文件头 ③）
  // ⚠️ 只取**带 --shiny 皮肤**的那个 `.irs`。页面上每个滑块旁边还有一个
  //    没有皮肤的 `.irs` 空壳（里面只有一条 1px 的 `.irs-line`、没有把手），
  //    它一直是空的、一直没被看见过 —— 把它一起量进来只会让"找不到把手"
  //    变成一条假红。
  document.querySelectorAll('.dsapp-ctrl-bar .irs.irs--shiny').forEach((box, i) => {
    const b = rect(box);
    put('滑块零件·把手#' + i, box.querySelector('.irs-handle'), 'part',
        {boxTop: b.top, boxBottom: b.bottom});
    put('滑块零件·轨道#' + i, box.querySelector('.irs-line'), 'part',
        {boxTop: b.top, boxBottom: b.bottom});
    put('滑块零件·高亮#' + i, box.querySelector('.irs-bar'), 'part',
        {boxTop: b.top, boxBottom: b.bottom});
  });

  // ② 每一格
  document.querySelectorAll('.dsapp-ctrl-bar > .dsapp-ctrl').forEach((el, i) => {
    const r = rect(el);
    out.push({label: '格#' + i + ' ' +
              (((el.querySelector('.dsapp-ctrl-h') || {}).innerText) || '').trim(),
              kind: 'box', h: r.h, w: r.w, top: r.top, bottom: r.bottom,
              disp: getComputedStyle(el).display});
  });

  const bar = document.querySelector('.dsapp-ctrl-bar');
  const barR = bar ? rect(bar) : null;
  const foot = (document.body.innerText.match(/Test_V[0-9.]+/) || [])[0] || '';
  return {items: out, bar: barR, ver: foot};
}
"""


def dump(got, title):
    print("\n=== %s ===" % title)
    print("  %-24s %8s %8s %9s %9s  %s" %
          ("", "h", "w", "top", "bottom", "其它"))
    for it in got["items"]:
        if it.get("missing"):
            print("  %-24s   ✗ 页面上找不到这个控件" % it["label"])
            continue
        extra = " ".join("%s=%s" % (k, it[k]) for k in
                         ("disp", "vis", "fs", "pt", "pb", "cls")
                         if it.get(k) not in (None, ""))
        print("  %-24s %8.2f %8.2f %9.2f %9.2f  %s" %
              (it["label"], it["h"], it["w"], it["top"], it["bottom"], extra))
    if got["bar"]:
        print("  ---- .dsapp-ctrl-bar 总高 %.2f ----" % got["bar"]["h"])


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        pg = br.new_page(viewport={"width": 1440, "height": 900})
        C.enter_app(pg)
        C.seed_or_die(C.LAST_EMAIL)
        C.goto(pg, "chat")
        C.ensure_no_modal(pg)
        pg.wait_for_timeout(1500)

        ck = C.Chk()
        got = pg.evaluate(JS)
        dump(got, "默认状态（四个勾都勾着：只有下拉框 / 滑块 / 勾行）")
        pg.locator(".dsapp-ctrl-bar").screenshot(path=C.OUT + "/bar_default.png")
        first = got
        ck("★ 版本号是 Test_V16.5（连错实例的话这条先响）",
           got["ver"] == "Test_V16.5", "页脚写的是 %r" % got["ver"])

        # ---- 把四个勾取消：数字框和另一根滑块这才出现 -----------------------
        for cid in ("#chat-unlim_ctx", "#chat-unlim_maxtok",
                    "#chat-unlim_wall", "#chat-unlim_fix"):
            loc = pg.locator(cid)
            if loc.count() == 0:
                ck("★ 找得到 %s" % cid, False)
                continue
            lab = loc.first.locator("xpath=ancestor::label[1]")
            (lab.first if lab.count() else loc.first).click()
            pg.wait_for_timeout(800)
        pg.wait_for_timeout(1500)
        got = pg.evaluate(JS)
        dump(got, "取消四个勾（数字框 + 第二根滑块都出来了）")
        pg.locator(".dsapp-ctrl-bar").screenshot(path=C.OUT + "/bar_open.png")

        # =====================================================================
        # 断言
        # =====================================================================
        def items(kind, src=None):
            return [x for x in (src or got)["items"]
                    if x.get("kind") == kind and not x.get("missing")
                    and x.get("vis") != "hidden" and x.get("h", 1) > 0]

        # ---- ① 控件等高 ----------------------------------------------------
        ctrls = items("ctrl")
        names = sorted(set(x["label"].split("#")[0] for x in ctrls))
        ck("★★ （前置）两轮加起来量到了三类以上控件（下拉框/数字框/滑块/勾行）",
           len(names) >= 3, "量到的是 %s" % names)
        by = {}
        for x in ctrls:
            by.setdefault(x["label"].split("#")[0], []).append(x["h"])
        bad = {k: v for k, v in by.items() if any(abs(h - WANT) > 0.5 for h in v)}
        ck("★★★ 每一个控件都是 %.0fpx（下拉框 / 数字框 / 滑块 / 勾那一行）" % WANT,
           not bad, "不是 %.0f 的：%s" % (WANT, bad))
        # ⚠️ 负数对照：这几条是老高度，回归了就说明统一那条规则没生效。
        #    写在这里是因为"统一成 26"和"统一成 36.5"在上一句里同样绿。
        ck("★★ 顺带钉住：整排没有一个是老高度（36.5 / 40 / 28）",
           not any(abs(x["h"] - v) < 0.6 for x in ctrls for v in (36.5, 40.0, 28.0)),
           "还有这些高度：%s" % sorted(set(round(x["h"], 1) for x in ctrls)))

        # ---- ② 同一行的格子必须一样高 --------------------------------------
        boxes = [x for x in got["items"] if x.get("kind") == "box"]
        ck("★ （前置）量到了所有的格子", len(boxes) >= 5, "%d 格" % len(boxes))
        rows = {}
        for b in boxes:
            rows.setdefault(round(b["top"] / 5.0), []).append(b)
        uneven = []
        for _, row in rows.items():
            hs = sorted(set(round(b["h"], 1) for b in row))
            if len(hs) > 1:
                uneven.append([(b["label"].strip(), hs) for b in row])
        ck("★★★ 同一行的每一格**一样高**（顶边也要齐：都是 %.1f）"
           % (boxes[0]["h"] if boxes else 0),
           not uneven, "行内不齐：%s" % uneven)
        tops = {}
        for b in boxes:
            tops.setdefault(round(b["top"] / 5.0), []).append(round(b["top"], 1))
        ck("★★ 同一行的格子**顶边对齐**（原来底对齐，顶边差 29px）",
           all(len(set(v)) == 1 for v in tops.values()),
           "每行的顶边：%s" % list(tops.values()))

        # ---- ③ 滑块的零件不许跑到盒子外面（见文件头 ③）--------------------
        parts = [x for x in got["items"]
                 if x.get("kind") == "part" and not x.get("missing")
                 and x.get("vis") != "hidden"]
        ck("★ （前置）量到了滑块的零件（把手 / 轨道 / 高亮）", len(parts) >= 6,
           "%d 个零件" % len(parts))
        ck("★ （前置）其中**有把手**（没有的话下面那条是在空集上通过）",
           any("把手" in x["label"] for x in parts),
           "量到的是 %s" % [x["label"] for x in parts])
        out_of_box = []
        for x in parts:
            if x["top"] < x["boxTop"] - 0.6 or x["bottom"] > x["boxBottom"] + 0.6:
                out_of_box.append((x["label"], x["top"], x["bottom"],
                                   x["boxTop"], x["boxBottom"]))
        ck("★★★ 滑块的把手和轨道都在滑块自己的盒子里（跑到外面就会压在下一行字上）",
           not out_of_box,
           "冒出去的：%s（顺序是 零件top/零件bottom/盒子top/盒子bottom）"
           % out_of_box)

        # ---- 收尾 ----------------------------------------------------------
        first_boxes = [x for x in first["items"] if x.get("kind") == "box"]
        print("\n  （默认状态那一排的总高：%.2f px；展开之后：%.2f px）"
              % (first["bar"]["h"], got["bar"]["h"]))
        print("  （默认状态下第 1 行有 %d 格）" % len(
            [b for b in first_boxes
             if abs(b["top"] - first_boxes[0]["top"]) < 1]))
        if ASSERT:
            sys.exit(ck.done())
        print("\n（只量不断言；要断言加 --assert）")
        br.close()


main()
