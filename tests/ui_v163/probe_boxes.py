# -*- coding: utf-8 -*-
"""V16.3 item 3 / 4 / 5：对话页下方那一排控件的**归类**。

这三条用户原话（2026-10-04）：

  3、「"基础环境是系统环境 ，本对话自己装的包叠加在它上面。  自动执行已开启
     （最多 6 轮 / 不限时长），发送后自动跑，随时可点「停止」。 "这一行话其实
     是两类功能的提示词，请把他合并到一类里去。」
  4、「出错自动修已经打勾了，但是上面还是有个滑条，这冲突了」
  5、「现在对话框下方的组件太多了，请用框区分或者以什么形式让它们具有分类的
     区分度」

为什么这三条**必须**有浏览器探针：

  · item 3 的「合并到一类」改的是**位置**——两句提示词原来拼在同一个 output 的
    同一行里，现在拆成两个 output 各归各的框。源码上两句话都还在、字数没变，
    `selftest.R` 里 grep 得到的东西几乎一样；**只有量位置才分得出来**。
  · item 4 的病根是「勾已经打上了，控件还在别处露着」——这是**同屏关系**问题。
  · item 5 要的是「有区分度」——class 加没加上源码能查，**看不看得出来**查不了。

⚠️ 本探针刻意**不**碰 `tests/ui_v162/probe_unlim.py` 已经钉过的东西（值、
默认勾选状态、防抖、两模块同步）。那一条是 V16.2 的冻结记录，重合的部分
再钉一遍只是让两份记录互相牵着，改一处红两处。

跑法：
    bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a
    python3 tests/ui_v163/probe_boxes.py            # 退出码 0 = 全绿
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
FAIL = []
NCHECK = [0]

BOXES = [("模型", "模型"), ("在哪跑", "在哪跑"), ("技能", "技能"),
         ("自动执行", "自动执行"), ("不设上限", "不设上限")]

# 五格各自的 class（item 5 加的框）。只有前三格有专属 class，后两格靠
# .dsapp-ctrl-box + 抬头文字认。
CLS = {"模型": None, "在哪跑": "dsapp-ctrl-where", "技能": "dsapp-ctrl-skillbox",
       "自动执行": "dsapp-ctrl-agent", "不设上限": "dsapp-ctrl-unlim"}


def check(name, ok, extra=""):
    NCHECK[0] += 1
    print("  %s %s%s" % ("✅" if ok else "❌", name,
                         ("  — " + str(extra)) if extra else ""), flush=True)
    if not ok:
        FAIL.append(name)
    return ok


# 把每一格的 {抬头, 矩形, 文本} 抠出来。抬头取 .dsapp-ctrl-h 的 innerText。
JS_CELLS = """() => {
  const boxes = [...document.querySelectorAll('.dsapp-ctrl-bar .dsapp-ctrl-box')];
  return boxes.map(b => {
    const h = b.querySelector('.dsapp-ctrl-h');
    const r = b.getBoundingClientRect();
    return {head: h ? (h.innerText || '').trim() : null,
            cls: b.className,
            x: r.x, y: r.y, w: r.width, h: r.height,
            mid: r.y + r.height / 2,
            txt: (b.innerText || '')};
  });
}"""

# 某个元素**可见**吗：存在 + 矩形非零（隐藏元素的矩形是全 0，
# 本仓老账 hidden-element-has-zero-rect）。
JS_SEEN = """(sel) => {
  const e = document.querySelector(sel);
  if (!e) return {found: false};
  const r = e.getBoundingClientRect();
  return {found: true, w: r.width, h: r.height, x: r.x, y: r.y,
          mid: r.y + r.height / 2, left: r.left, right: r.right};
}"""


def cells(pg):
    return pg.evaluate(JS_CELLS)


def head_of(pg, kw):
    for c in cells(pg):
        if c["head"] and kw in c["head"]:
            return c
    return None


def seen(pg, sel):
    d = pg.evaluate(JS_SEEN, sel)
    return d if (d.get("found") and d["w"] > 0 and d["h"] > 0) else None


def close_pref_modal(pg, timeout=15):
    """关掉「AI 怎么干活？」那个首选项弹窗，**保留**刚勾上的「自动执行」。

    ⚠️ 和 `C.ensure_no_modal()` 的区别只有按哪个按钮，但后果正好相反：
       那个函数点的是「都先别开，我自己盯着」→ `agent_pref_store(FALSE,FALSE)`
       → 里面有一句 `updateCheckboxInput(session, "agent_mode", value = FALSE)`
       —— 把刚勾上的开关**弹回去**，于是本节要量的那句「自动执行已开启…」
       跟着消失（而且它是**异步**消失的，量到哪一步全看时序）。
       这里点「就按这个来」：它按**当前勾选状态**存，预勾的正是当前状态。

    ⚠️ 必须等弹窗**真的出现**再点。第一版直接调 `ensure_no_modal()`，
       而它是"现在就看不见弹窗 → 直接返回成功"的写法：`showModal` 要走一个
       服务端来回（100~300ms），刚点完开关的那一瞬间弹窗还没到，
       守卫当场放行 —— 弹窗随后才冒出来，压着整页。症状是**十几行之后**的
       一次 `.uncheck()` 等满 30 秒超时，报的是「被 #shiny-modal 挡住」。
    """
    end = time.time() + timeout
    while time.time() < end:
        if pg.locator("#shiny-modal:visible").count() == 0:
            return True
        b = pg.locator("#chat-agent_pref_save")
        if b.count():
            b.first.click()
            pg.wait_for_timeout(1500)
            continue
        pg.wait_for_timeout(300)
    return pg.locator("#shiny-modal:visible").count() == 0


def uncheck(pg, sel_id):
    """取消一个勾，并且等它真的报上去。

    ⚠️ `.uncheck()` 只在 DOM 上点一下；Shiny 的 checkbox 绑定还要一个 change
       事件才发消息。playwright 的 check/uncheck 会派发 change，但**服务端
       落库/重画**还要一个来回 —— 所以后面一律配 wait_for_timeout 再断言。

    ⚠️⚠️ 点之前先确认页面上没有弹窗。本仓的老账：弹窗盖住整页时，click 报的
       是「`#shiny-modal` intercepts pointer events」，**报错指向被点的那个
       控件**，看不出真正的原因；而 `.uncheck()` 会**等满 30 秒**再抛超时。
       这里直接查一次，把弹窗的原文一起报出来 —— 不然下一次还是要去翻
       playwright 的调用日志才认得出。
    """
    # ⚠️⚠️ 可见性判据用**矩形**，不能用 `offsetParent`：Bootstrap 的
    #    `.modal` 是 `position: fixed`，而固定定位元素的 `offsetParent`
    #    恒为 null —— 用它判"在不在"，一个正盖着整页的弹窗会被判成"不在"，
    #    于是这行守卫静静地放行，后面照样等满 30 秒。
    #    （和本仓 `hidden-element-has-zero-rect` 是同一枚硬币的两面：
    #     那边是"看不见的也有矩形"，这边是"看得见的 offsetParent 是 null"。）
    m = pg.evaluate(
        "() => { const e = document.querySelector('#shiny-modal');"
        " if (!e) return '';"
        " const r = e.getBoundingClientRect();"
        " if (!(r.width > 0 && r.height > 0)) return '';"
        " return (e.innerText || '').slice(0, 300); }")
    if m:
        check("（前置）点 %s 之前页面上没有弹窗" % sel_id, False,
              "被这个弹窗挡住了：%r" % m)
        return
    el = pg.locator(sel_id)
    if el.count():
        el.first.uncheck()
    pg.wait_for_timeout(1800)


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()
        try:
            C.enter_app(pg)
            C.ensure_no_modal(pg)
            C.goto(pg, "言出法随")
            pg.wait_for_timeout(2000)
            C.ensure_no_modal(pg)

            # =============================================================
            print("\n=== ① 五格都在，而且每一格有自己的抬头 ===", flush=True)
            # =============================================================
            cs = cells(pg)
            heads = [c["head"] for c in cs if c["head"]]
            check("① 那一排里至少有 5 个带抬头的框（item 5 的「用框区分」）",
                  len(cs) >= 5, "找到 %d 个 .dsapp-ctrl-box" % len(cs))
            check("① 五个类别一个不少：模型 / 在哪跑 / 技能 / 自动执行 / 不设上限",
                  all(any(k in h for h in heads) for k, _ in BOXES),
                  "实际抬头：%s" % heads)
            check("① 抬头是**分类名**，不是把控件名抄了一遍（五个各不相同）",
                  len(set(heads)) == len(heads), "%s" % heads)

            # =============================================================
            print("\n=== ② item 3：两类提示词各归各的框 ===", flush=True)
            # =============================================================
            where = head_of(pg, "在哪跑")
            agent = head_of(pg, "自动执行")
            if not (where and agent):
                check("② 找得到「在哪跑」和「自动执行」这两个框", False,
                      "where=%s agent=%s" % (bool(where), bool(agent)))
            else:
                check("② 找得到「在哪跑」和「自动执行」这两个框", True)

                # ⚠️ 「自动执行已开启…」那句**只在自动执行开着的时候才画**
                #    （output$ctrl_notes 里那句 `!isTRUE(a$enabled) → return(NULL)`）。
                #    进这一页时 ensure_no_modal() 点的是「都先别开」，所以此刻
                #    它是关的 —— 直接去断言那句在哪，量到的是"它哪都不在"，
                #    于是「不在别处」那两条会**白送**（一个不存在的字符串，
                #    当然不在任何一个框里）。先把它打开，再量位置。
                check("② （前置）此刻自动执行是关的，那句提示还没画出来",
                      "自动执行已开启" not in (agent["txt"] or ""),
                      agent["txt"][:120])
                cb = pg.locator("#chat-agent_mode")
                if cb.count():
                    cb.first.check()
                # 勾上「自动执行」是"第一次开启任务"的一种，会**再问一次**
                # 那个首选项弹窗（mod_chat.R 的 maybe_ask_agent_pref），它盖住
                # 整页 → 后面所有 click 都报「#shiny-modal intercepts pointer
                # events」，而报错指向被点的那个控件。
                pg.wait_for_timeout(2000)      # 等弹窗真的到（见 close_pref_modal）
                close_pref_modal(pg)
                pg.wait_for_timeout(2500)

                where = head_of(pg, "在哪跑")
                agent = head_of(pg, "自动执行")
                w_txt, a_txt = where["txt"], agent["txt"]
                # ★ 先证明这句**真的画出来了**。少了这一步，下面那条"不在
                #   「在哪跑」框里"在"它压根没渲染"时也成立 —— 那正是本仓
                #   栽过四次的形状：断言是全绿的，功能其实没验过。
                check("② （前置）打开自动执行之后，那句提示真的出现了",
                      "自动执行已开启" in a_txt, a_txt[:160])
                # 正向：每一句都在**对**的那个框里
                check("② 「基础环境是系统环境…」在「在哪跑」那个框里",
                      "基础环境是系统环境" in w_txt, w_txt[:120])
                check("② 「自动执行已开启…」在「自动执行」那个框里",
                      "自动执行已开启" in a_txt, a_txt[:120])
                # ★ 反向才是这一条的重点：**不许两边都有**。
                #   只钉正向的话，「拆开」写成「复制一份到两边」照样全绿 ——
                #   而用户看到的仍然是同一句话说两遍。
                check("② ★ 反过来：「自动执行已开启…」**不在**「在哪跑」那个框里",
                      "自动执行已开启" not in w_txt,
                      "在哪跑框里出现了自动执行那句：" + w_txt[:160])
                check("② ★ 反过来：「基础环境是系统环境…」**不在**「自动执行」那个框里",
                      "基础环境是系统环境" not in a_txt,
                      "自动执行框里出现了环境那句：" + a_txt[:160])
                # 也不是「两句都掉进了同一个第三方容器」
                check("② 两个 output 是**两个**节点（不是同一行里拼出来的）",
                      pg.locator("#chat-notes_env").count() == 1 and
                      pg.locator("#chat-ctrl_notes").count() == 1 and
                      pg.evaluate(
                          "() => { const a = document.getElementById('chat-notes_env');"
                          " const b = document.getElementById('chat-ctrl_notes');"
                          " return !!a && !!b && !a.contains(b) && !b.contains(a); }"))

            # =============================================================
            print("\n=== ③ item 4：勾着就不该有那个控件（就地，别处也没有）===",
                  flush=True)
            # =============================================================
            # 用户原话是「已经打勾了，但是上面还是有个滑条，这冲突了」。
            # 判据分两半：A. 勾着时那个控件**不存在**；B. 取消勾之后它出现在
            # **自己那个勾的旁边**（「就地」两个字的后一半）。
            fx = pg.locator("#chat-unlim_fix")
            check("③ 前提：「自动修次数」这个勾是勾着的（用户原话的场景）",
                  fx.count() == 1 and fx.first.is_checked(),
                  "count=%d checked=%s" % (fx.count(),
                                           fx.first.is_checked() if fx.count() else None))
            check("③ ★ 勾着的时候，页面上**没有**那个数字框（冲突的就是它）",
                  pg.locator("#chat-fix_max_n").count() == 0,
                  "count=%d" % pg.locator("#chat-fix_max_n").count())
            check("③ ★ 也没有露在别的地方（不是挪走了，是真的没画）",
                  seen(pg, "#chat-fix_max_n") is None)
            # 对照：别把「整个就地控件那一套都没了」当成「这一格没有」 ——
            # 同一个 unlim 框里，取消勾的「运行时间」此刻是有控件的。
            check("③ （对照）同一个框里，没勾的那几项此刻**有**控件 "
                  "（否则上面两条是白送的）",
                  seen(pg, "#chat-agent_wall") is not None or
                  seen(pg, "#chat-agent_iter") is not None,
                  "wall=%s iter=%s" % (bool(seen(pg, "#chat-agent_wall")),
                                       bool(seen(pg, "#chat-agent_iter"))))

            uncheck(pg, "#chat-unlim_fix")
            box = seen(pg, "#chat-fix_max_n")
            check("③ 取消勾之后它出现了（而且真的画出来了，不是 0×0）",
                  box is not None, box)
            if box:
                cb = pg.locator("#chat-unlim_fix").first.bounding_box()
                check("③ ★ 而且是**就地**：和它自己那个勾同一行（中线差 < 一行高）",
                      cb is not None and abs(box["mid"] - (cb["y"] + cb["height"] / 2)) < 40,
                      "勾 mid=%.1f 控件 mid=%.1f"
                      % ((cb["y"] + cb["height"] / 2) if cb else -1, box["mid"]))
                check("③ ★ 并且在勾的**右边**（不是上一行「上面那个滑条」那个位置）",
                      cb is not None and box["x"] > cb["x"],
                      "勾 x=%.1f 控件 x=%.1f" % (cb["x"] if cb else -1, box["x"]))

            # =============================================================
            print("\n=== ④ item 5：框是**看得见**的，不是只有个 class ===", flush=True)
            # =============================================================
            cs = cells(pg)
            style = pg.evaluate("""() => {
              const b = document.querySelector('.dsapp-ctrl-bar .dsapp-ctrl-box');
              if (!b) return null;
              const s = getComputedStyle(b);
              return {bw: parseFloat(s.borderTopWidth) || 0,
                      bc: s.borderTopColor, bg: s.backgroundColor,
                      pad: parseFloat(s.paddingTop) || 0,
                      radius: parseFloat(s.borderTopLeftRadius) || 0};
            }""")
            check("④ 框上真的落了样式（边框或底色，不是只加了个 class 名）",
                  style is not None and
                  (style["bw"] > 0 or style["bg"] not in ("rgba(0, 0, 0, 0)",
                                                          "transparent")),
                  style)
            check("④ 框里有内边距（控件贴着边框的话，「分框」看起来还是一团）",
                  style is not None and style["pad"] > 0, style)
            # 几何：同一排的框**互不重叠**。重叠的话视觉上就是"一个大框里
            # 塞了几坨东西"，和用户要的"分类的区分度"正好相反。
            overlap = []
            for i in range(len(cs)):
                for j in range(i + 1, len(cs)):
                    a, b = cs[i], cs[j]
                    if (a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and
                            a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]):
                        overlap.append((a["head"], b["head"]))
            check("④ ★ 框和框**没有一个重叠**（重叠 = 还是一团）",
                  not overlap, "重叠的：%s" % overlap)

            # 每一格都非零 —— 一个 0×0 的框在几何断言里「不重叠」得太容易了
            zero = [c["head"] for c in cs if c["w"] < 20 or c["h"] < 20]
            check("④ 每一格都有实际大小（防「0×0 的框当然不重叠」）",
                  not zero, "塌掉的：%s" % zero)

        finally:
            ss = os.path.join(OUT, "probe_boxes_%s.png" % time.strftime("%H%M%S"))
            try:
                pg.screenshot(path=ss, full_page=True)
                print("\n截图 %s" % ss, flush=True)
            except Exception as e:
                print("\n截图失败：%s" % e, flush=True)
            br.close()

    print("\n=== %d 条断言，%d 条没过 ===" % (NCHECK[0], len(FAIL)), flush=True)
    for f in FAIL:
        print("  · %s" % f, flush=True)
    sys.exit(1 if FAIL else 0)


main()
