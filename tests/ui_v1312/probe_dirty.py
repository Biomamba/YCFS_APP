# -*- coding: utf-8 -*-
"""验「服务端自己写的控件值，不算用户的改动」（V13.12 item 20 顺手修的 item 19 误报）。

    python3 tests/ui_v1312/probe_dirty.py

对着 8913 那个一次性实例 + /tmp/mock_llm.py 跑。

复现的现场：
  1. 填 Key + 接口地址 → 点「更新」→ 界面说"已保存，可直接用"
  2. 切到对话页 —— 却被告知「模型改了还没确认」，而用户一个字都没动。
成因是「更新」顺手拉的那次模型清单把选中的模型名换成了清单头一个。

四条断言：
  · 保存完切页        → **不许**弹框
  · 手动改接口地址切页 → **要**弹，而且点名的就是「接口地址」
  · 改了又改回原样    → 值是相等的，弹不弹都算对（记录现象，不断言）
  · 换厂商           → **要**弹（换厂商是用户改的，而且那行小字要点了才变）
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

MOCK = "http://127.0.0.1:8931/v1"
k = C.Chk()


def modal_text(pg):
    m = pg.locator(".modal.show")
    if not m.count():
        return None
    return m.first.inner_text().replace("\n", " / ")


def modal_fields(pg):
    """弹框点名的那几样 —— 只有「…更新」：这一句里有，后面的解释里别去捞。

    ⚠️ 第一版是 `"模型" not in t.split("：")[-1]`，把解释文案里那句
       "左栏「模型服务」下面那行小字"也算了进去 —— 明明只列了「接口地址」，
       断言却红。判据要盯着**那一个分句**，不是整段文字。
    """
    t = modal_text(pg)
    if t is None:
        return None
    for seg in t.split("：")[1:]:
        head = seg.split("。")[0]
        if "、" in head or len(head) < 20:
            return [x for x in head.replace(" ", "").split("、") if x]
    return []


def close_modal(pg, which="#model-rail_collapse"):
    if pg.locator(".modal.show").count():
        pg.locator(which).click()
        pg.wait_for_timeout(900)


with sync_playwright() as pw:
    b = pw.chromium.launch()
    pg = b.new_page(viewport={"width": 1600, "height": 950})
    e = C.enter_app(pg)
    C.seed_or_die(e)

    # ---- 1. 填 Key + 接口地址 → 更新 ----
    C.goto(pg, "model")
    pg.fill("#model-api_key", "sk-mock")
    pg.fill("#model-base_url", MOCK)
    pg.wait_for_timeout(1500)
    pg.locator("#model-commit").click()
    # 等模型清单真的回来（假服务那两个名字铺进下拉），这段就是"误报的现场"
    got = False
    for _ in range(30):
        pg.wait_for_timeout(500)
        if "mock-slow" in pg.inner_html("#model-model + .selectize-control",
                                        timeout=5000):
            got = True
            break
    k("假服务的模型清单铺进了下拉（铺进来才会发生那次改写）", got)
    sel = pg.eval_on_selector(
        "#model-model", "el => el.value") if pg.locator("#model-model").count() else "?"
    print("  下拉里现在选的是：%r" % sel, flush=True)
    pg.wait_for_timeout(1500)

    # ---- 2. 切走：**不该**弹 ----
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    t = modal_text(pg)
    k("★★★ 刚点完「更新」就切页 —— 不许弹「还没确认」", t is None, t or "")
    if t:
        pg.screenshot(path=os.path.join(C.OUT, "modal2_after_save.png"))
    close_modal(pg)

    # ---- 3. 手动改接口地址 → 切走：**该**弹，且点名的就是接口地址 ----
    C.goto(pg, "model")
    pg.fill("#model-base_url", MOCK + "/changed")
    pg.wait_for_timeout(1500)
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    t = modal_text(pg)
    k("★★★ 手动改了接口地址再切页 —— 要弹", t is not None, "没弹")
    if t:
        k("★★★ 而且点名的正是「接口地址」，不夹带别的",
          modal_fields(pg) == ["接口地址"], "%r" % (modal_fields(pg),))
    close_modal(pg)

    # ---- 4. 改回去，值相等 → 现象记录 ----
    C.goto(pg, "model")
    pg.fill("#model-base_url", MOCK)
    pg.wait_for_timeout(1500)
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    t = modal_text(pg)
    print("  （记录）改回原值后切页：%s" % ("弹了" if t else "没弹"), flush=True)
    close_modal(pg)

    # ---- 5. 换厂商 → 该弹（厂商那一格不刷快照就是要保住这个）----
    C.goto(pg, "model")
    C.pick_select(pg, "model-vendor", "0DaysSCI")
    pg.wait_for_timeout(2500)
    C.goto(pg, "chat")
    pg.wait_for_timeout(1500)
    t = modal_text(pg)
    k("★★★ 换了厂商再切页 —— 要弹（左栏那行小字要点了更新才变）",
      t is not None, "没弹")
    if t:
        k("★★ 点名的里面有「厂商」", "厂商" in t, t)
        # ⚠️ 换厂商会顺带把这家记着的地址/Key/模型填上来，那三格是**服务端**
        #    填的 —— 不刷快照的话这里会一口气列出四样，看着像用户改了四样。
        k("★★ 但不该把服务端顺手填的那三样算成用户的改动",
          modal_fields(pg) == ["厂商"], "%r" % (modal_fields(pg),))
    close_modal(pg)

    b.close()
sys.exit(k.done())
