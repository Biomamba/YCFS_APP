# -*- coding: utf-8 -*-
"""V13.1 item 2：只接受 temperature = 1 的模型，滑块要真的灰掉。

用户原话：
  「kimi的api显示可用，但实际的HTTP 400：invalid temperature: only 1 is
    allowed for this model」

★ 这一项的坑不在"能不能调通"，而在**界面在骗人**：
  滑块画得好好的、能拖、拖完也存下来了，用户一路拖到 0.3，发出去就是 400。
  "显示可用"和"实际可用"是两回事，所以要断言的是**渲染出来的样子**，
  不是函数返回值 —— 函数返回 FALSE、界面照样画一个能拖的滑块，是完全
  可能的（这一项之前就正是这样）。

★ 为什么要钉"两句不同的话"：
  有两种"温度不生效"，原因完全不同：
    · 思考模式：关掉开关就好了；
    · 模型锁死（kimi-k*）：关什么开关都没用，这个模型压根没有可调的温度。
  写成同一句的话，第二种情况会把用户支去关一个关了也没用的开关，
  然后他会以为是这个应用坏了。所以这里**正着断言一句、反着断言另一句**。

★ 三个对照组，少一个都证明不了问题：
    · moonshot + kimi-k3     → 灰，理由是"模型锁死"
    · qwen + kimi/kimi-k3    → 灰（聚合平台转售的同名模型，带 `厂商/` 前缀）
    · deepseek（思考开）      → 灰，理由是"思考模式"
    · deepseek（思考关）      → **不灰**，滑块能拖
    · qwen + qwen3.8-max     → 从来不灰
  最后两条是防"一刀切"的：把温度对所有厂商都掐掉，前三条照样全绿。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, pick_select   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()


def ctrl_of(page, sel_id):
    return page.locator(
        "xpath=//select[@id='%s']/following-sibling::div"
        "[contains(@class,'selectize-control')]" % sel_id)


def set_model(page, value):
    """在模型下拉里选一个（可能是很长的清单，先打字过滤再点）。"""
    ctrl = ctrl_of(page, "model-model")
    ctrl.locator(".selectize-input").click()
    page.wait_for_timeout(400)
    ctrl.locator("input").first.click()
    page.keyboard.press("Control+A")
    page.keyboard.type(value, delay=40)
    page.wait_for_timeout(900)
    opt = ctrl.locator(".option[data-value=%s]" % json.dumps(value))
    if opt.count() == 0:
        opt = ctrl.locator(".option", has_text=value)
    if opt.count() == 0:
        return False
    opt.first.click()
    page.wait_for_timeout(1400)
    return True


def open_adv(page):
    """（V13.6 起是**空操作**了，函数留着是因为下面所有断言都靠它表意。）

    ⚠️ 改之前：`#model-temp_ui` 在一个**收着的**
    `<details class="dsapp-model-adv">` 里面，必须先点开才读得到文字 ——
    `inner_text()` 对不可见元素返回空串，于是查文案的断言全红，而报出来的
    是"这句话没写"，真实原因却是"你没展开那个折叠"。

    V13.6 item 2 把那个折叠去掉了（用户原话：「生成参数不要折叠」），
    参数区现在**一直在页面上**，所以这里没有东西可展开。
    保留空函数而不是删掉调用点：下面每一处 `open_adv(page)` 后面都跟着
    一条"读得到文字"的断言，那两条合起来才是完整的意图；删掉调用点会让
    "这块内容可见"这件事重新变成一个没人守着的隐含前提。
    """
    return None


def temp_slider_disabled(page):
    """温度**滑块**外面那层灰壳（没有就返回一个 count()==0 的定位器）。

    ⚠️ 不能再用"#model-temp_ui 里随便一个 .dsapp-field-disabled"当判据。
    V13.6 item 2 之后，不支持思考模式的厂商也会在这块里**渲染灰掉的**
    思考开关和思考强度 —— 那些也是 `.dsapp-field-disabled`。老写法会把
    "qwen 有个灰的思考开关"错读成"qwen 的温度滑块被灰了"，于是对照组
    「通义自家的模型不灰」当场变红，而功能其实完全正确。
    所以判据收紧到"灰壳里装着 ionRangeSlider"。
    """
    return page.locator(
        "#model-temp_ui .dsapp-field-disabled:has(.js-range-slider)")


def temp_state(page):
    """温度那一块现在长什么样：(滑块灰没灰, 说明文字)。"""
    box = page.locator("#model-temp_ui")
    try:
        txt = box.inner_text()
    except Exception:
        txt = "（读不到 temp_ui）"
    return temp_slider_disabled(page).count() > 0, txt


def pe(page):
    """被灰掉的那一块的 pointer-events —— 光有 opacity 是骗不了鼠标的。"""
    el = temp_slider_disabled(page)
    if el.count() == 0:
        return None
    return el.first.evaluate(
        "e => getComputedStyle(e).pointerEvents")


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="温度")
    goto(page, "settings", wait=4000)

    chk("★ 设置页有厂商下拉和温度那一块",
        page.locator("#model-vendor").count() == 1 and
        page.locator("#model-temp_ui").count() == 1)
    open_adv(page)
    chk("★ 温度那一块**真的看得见**（inner_text 读不到不可见元素，"
        "下面所有查文案的断言都靠这一步）",
        page.locator("#model-temp_ui").first.is_visible())

    # ---- 1. moonshot + kimi-k3：锁死的模型 ---------------------------------
    print("\n== moonshot + kimi-k3（用户报 400 的那个）==", flush=True)
    pick_select(page, "model-vendor", "moonshot")
    page.wait_for_timeout(1500)
    chk("★ 模型下拉里真的有 kimi-k3（不然下面测的是别的模型）",
        set_model(page, "kimi-k3"), extra="下拉里找不到 kimi-k3")
    grey, txt = temp_state(page)
    chk("★★ kimi-k3 的温度滑块**是灰的**（这一条就是用户报的那个 bug）",
        grey, extra=txt[:200])
    chk("★★ 灰掉之后鼠标真的点不动（pointer-events: none，不是只调了透明度）",
        pe(page) == "none", extra=pe(page))
    chk("★★ 理由写的是「只接受 temperature = 1」",
        "只接受 temperature = 1" in txt, extra=txt[:200])
    chk("★★ 而且**没有**写成「思考模式下温度不生效」"
        "（月之暗面不给思考开关，让用户去关一个不存在的开关最坑）",
        "思考模式下温度不生效" not in txt, extra=txt[:200])
    chk("★ 理由里说明了「请求里不会带温度参数」（用户才知道不是应用坏了）",
        "不会带温度参数" in txt, extra=txt[:200])
    chk("★★ moonshot 这一页没有**能用**的「开启思考模式」开关"
        "（`#model-thinking` 是真控件才会有的 id）",
        page.locator("#model-thinking").count() == 0)
    # V13.6 item 2：原来是**整块不渲染**，用户看到参数区只剩一个温度滑块，
    # 没有任何东西告诉他"这家没有思考模式这回事"。现在改成灰掉 + 说明。
    # 两条一起钉：既不能悄悄把真控件放回来，也不能又退回"不渲染"。
    chk("★ V13.6：不支持思考的厂商，思考开关是**灰着显示**的（不是消失）",
        page.locator("#model-temp_ui .dsapp-field-disabled .checkbox").count() > 0
        and "思考模式" in txt,
        extra=txt[:200])
    chk("★ 而且说明了为什么灰（不然用户会以为是自己没点对地方）",
        "没有思考模式这个参数" in txt, extra=txt[:200])

    # ---- 2. 同厂商的另一个锁死模型，以及同厂商的... 没有不锁的 ------------
    print("\n== moonshot + kimi-k2.6 ==", flush=True)
    if set_model(page, "kimi-k2.6"):
        grey, txt = temp_state(page)
        chk("★ kimi-k2.6 也是灰的（规则是按**模型**判的，不是只钉了 k3 一个）",
            grey and "只接受 temperature = 1" in txt, extra=txt[:200])
    else:
        chk("★ 下拉里找不到 kimi-k2.6", False, extra="清单变了？")

    # ---- 3. 聚合平台转售的同名模型（带 `厂商/` 前缀）----------------------
    #
    # 百炼那边的 `kimi/kimi-k3` 是月之暗面直供的商品，前缀表示"原厂直供"。
    # 这条比 unit test 值钱：它证明**前缀在界面上也被剥掉了** ——
    # 只在函数里剥、渲染时又拿原始字符串去比，是很容易犯的错。
    print("\n== qwen + kimi/kimi-k3（聚合平台转售）==", flush=True)
    pick_select(page, "model-vendor", "qwen")
    page.wait_for_timeout(2000)
    if set_model(page, "kimi/kimi-k3"):
        grey, txt = temp_state(page)
        chk("★★ 带 `kimi/` 前缀的也认出来了（前缀必须先剥掉再比）",
            grey and "只接受 temperature = 1" in txt, extra=txt[:200])
    else:
        chk("★★ 百炼的清单里找不到 kimi/kimi-k3", False,
            extra="DSAPP_RESOLD_MODELS$qwen 变了？")

    # ---- 4. 对照组：qwen 自家的模型，从来不灰 -----------------------------
    print("\n== 对照组：qwen + qwen3.8-max ==", flush=True)
    chk("★ 能选到 qwen3.8-max", set_model(page, "qwen3.8-max"))
    grey, txt = temp_state(page)
    chk("★★ 通义自家的模型**不灰**（不是把温度对所有厂商一刀切了）",
        not grey, extra=txt[:200])
    chk("★ 也不该冒出任何一句「不生效」的说明",
        "不生效" not in txt and "只接受" not in txt, extra=txt[:200])

    # ---- 5. 对照组：deepseek 思考模式开 → 灰；关 → 不灰 -------------------
    print("\n== 对照组：deepseek（思考模式）==", flush=True)
    pick_select(page, "model-vendor", "deepseek")
    page.wait_for_timeout(2000)
    chk("★ deepseek 有「开启思考模式」开关（只有它认这个参数）",
        page.locator("#model-thinking").count() == 1)

    cb = page.locator("#model-thinking")
    if not cb.is_checked():
        cb.check()
        page.wait_for_timeout(1500)
    grey, txt = temp_state(page)
    chk("★★ 思考模式开着的时候，温度是灰的", grey, extra=txt[:200])
    chk("★★ 但理由**换了一句**：「思考模式下温度不生效」"
        "（而不是也说成「只接受 temperature = 1」—— 那会让用户以为关开关没用）",
        "思考模式下温度不生效" in txt, extra=txt[:200])
    chk("★★ 并且没混进模型锁死那句",
        "只接受 temperature = 1" not in txt, extra=txt[:200])
    chk("★ 这句还告诉了用户怎么让它生效（把开关关掉）",
        "关掉" in txt, extra=txt[:200])

    print("\n== 对照组：deepseek 关掉思考模式 ==", flush=True)
    cb.uncheck()
    page.wait_for_timeout(1800)
    grey, txt = temp_state(page)
    chk("★★ 关掉思考开关之后，滑块**回来了**（这一步是可逆的）",
        not grey, extra=txt[:200])
    # 光"滑块还在"证明不了什么（灰掉的那一版滑块也还在）。得真的拖一下，
    # 看那个值有没有动 —— 这是唯一能区分"能调"和"画了个不能调的滑块"的判据。
    # ⚠️ 手柄的类是 `.irs-handle`（ionRangeSlider），不是 `.irs-slider`。
    #    写错的话 count() 是 0，报出来是"找不到滑块"，看着像功能坏了。
    handle = page.locator("#model-temp_ui .irs-handle")
    line = page.locator("#model-temp_ui .irs-line").first
    val = ("() => { var e = document.querySelector('#model-temp_ui .js-range-slider');"
           " return e ? e.value : null; }")
    before = page.evaluate(val)
    bb = line.bounding_box()
    if bb:
        page.mouse.click(bb["x"] + bb["width"] * 0.92, bb["y"] + bb["height"] / 2)
        page.wait_for_timeout(1000)
    after = page.evaluate(val)
    chk("★★ 滑块真的在页面上，而且拖得动（拖完值变了）",
        handle.count() > 0 and pe(page) is None and before != after,
        extra="滑块=%d pointer-events=%s 值 %r -> %r"
              % (handle.count(), pe(page), before, after))

    page.screenshot(path=OUT + "/temp.png", full_page=True)
    br.close()

sys.exit(chk.done())
