# -*- coding: utf-8 -*-
"""V13.6 item 2 / 3 / 4：生成参数不折叠、灰得对、量程自适应、新增 0DaysSCI。

用户原话：
  · item 2「模型服务的生存参数不要折叠，适用的直接出现，不适用的变成灰度就好」
  · item 3「参数范围也需要自适应，避免输入不适用参数值的全款」
  · item 4「加一个0DaysSCI的模型供应商，排名最靠前，获取API的跳转链接是
            https://www.0daysci.com/register?aff=UcNr」
  （「生存参数」是「生成参数」的错字，「全款」是「情况」的错音。）

★ 为什么这三项必须在**真浏览器**里验：
  item 2 是"看得见 / 灰着"这种**渲染结果**——源码里写了对的 class，
  样式表里没有那条规则，用户看到的还是一堆正常控件；
  item 3 的"自适应"落在 sliderInput / numericInput 的 min/max 属性上，
  那是浏览器读的，只有把 DOM 读回来看才算数；
  item 4 的"排名最靠前"是**下拉框里的顺序**，而 selectize 的下拉是打开时
  才铺进 DOM 的（不打开就只能看到空壳）。

★ 对照组一个都不能少：
  · 不支持思考的厂商（moonshot）→ 思考开关**灰着但看得见**
  · 支持思考的厂商（deepseek）→ 思考开关是**真的能点的**
  只测前者的话，"把思考控件对所有厂商都掐掉"照样全绿。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, pick_select   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

REGISTER_URL = "https://www.0daysci.com/register?aff=UcNr"
BASE_URL = "https://api.0daysci.com"


def vendor_options(page):
    """厂商下拉里的选项，**按显示顺序**。

    ⚠️ 一定要先点开：selectize 的下拉框是**打开时才把选项铺进 DOM** 的，
    不打开的话 `.selectize-dropdown .option` 的 count() 是 0 —— 报出来是
    "这个下拉是空的"，而真实原因只是没点开。

    ⚠️ 读的也得是 `.selectize-dropdown`：原生 <select> 被 selectize 清空了
    （它只留一个用来装值的壳），照着 <option> 读会读到空。
    """
    ctrl = page.locator(
        "xpath=//select[@id='model-vendor']/following-sibling::div"
        "[contains(@class,'selectize-control')]")
    ctrl.locator(".selectize-input").click()
    page.wait_for_timeout(700)
    opts = ctrl.locator(".selectize-dropdown .option")
    out = [opts.nth(i).get_attribute("data-value")
           for i in range(opts.count())]
    page.keyboard.press("Escape")
    page.wait_for_timeout(400)
    return out


def num_attrs(page, sel):
    """一个 number 控件的 min / max / step —— 量程就写在这三个属性上。"""
    return page.evaluate("""(s) => {
      var e = document.querySelector(s);
      if (!e) return null;
      return {min: e.getAttribute('min'), max: e.getAttribute('max'),
              step: e.getAttribute('step'), value: e.value};
    }""", sel)


def greyed(page):
    """参数区里灰掉的控件长什么样：(灰的个数, 有没有灰的思考复选框, 文字)。"""
    box = page.locator("#model-temp_ui")
    try:
        txt = box.inner_text()
    except Exception:
        txt = "（读不到 temp_ui）"
    return (page.locator("#model-temp_ui .dsapp-field-disabled").count(),
            page.locator("#model-temp_ui .dsapp-field-disabled .checkbox").count(),
            txt)


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 1000})
    page = ctx.new_page()
    errs = []
    page.on("pageerror", lambda e: errs.append(str(e)))

    enter_app(page, nickname="参数")
    goto(page, "settings", wait=4000)

    # =====================================================================
    print("\n== item 2：不折叠，参数区一进来就在 ==", flush=True)
    # =====================================================================
    chk("★★ 设置页一打开，参数区就在页面上（不用点任何东西展开）",
        page.locator("#model-temp_ui").count() == 1 and
        page.locator("#model-temp_ui").first.is_visible())
    chk("★★ 那个折叠整个没了（DOM 里连 <details> 都不该剩）",
        page.locator("details.dsapp-model-adv").count() == 0 and
        page.locator(".dsapp-rail-model details").count() == 0)
    chk("★ 参数区有一行标题，和上面的 Key/模型控件分得开",
        page.locator(".dsapp-model-params .dsapp-params-head").count() == 1)
    chk("★ 长度上限也在页面上（原来它和温度一起被折在 details 里）",
        page.locator("#model-max_tokens").count() == 1 and
        page.locator("#model-max_tokens").first.is_visible())

    # =====================================================================
    print("\n== item 2 对照组：不支持的厂商，灰着显示而不是消失 ==", flush=True)
    # =====================================================================
    pick_select(page, "model-vendor", "moonshot")
    page.wait_for_timeout(2000)
    n_grey, n_cb, txt = greyed(page)
    chk("★★ moonshot 页面上**看得见**一个「开启思考模式」（灰着，不是消失）",
        n_cb > 0 and "开启思考模式" in txt, extra=txt[:200])
    chk("★★ 但它**不是真控件**：`#model-thinking` 不存在"
        "（真控件会把 FALSE 报上去，用户切回 DeepSeek 时开关自己就关了）",
        page.locator("#model-thinking").count() == 0)
    chk("★★ 灰掉的开关真的点不动（pointer-events: none，不是只调了透明度）",
        page.locator("#model-temp_ui .dsapp-field-disabled").first.evaluate(
            "e => getComputedStyle(e).pointerEvents") == "none")
    chk("★ 而且说明了为什么灰（不然用户以为是自己没点对地方）",
        "没有思考模式这个参数" in txt, extra=txt[:200])
    chk("★ 想了想强度那三个选项也一起灰了（开关都点不动，强度留着能点更怪）",
        "思考强度" in txt and n_grey >= 2, extra="灰了 %d 块" % n_grey)

    # =====================================================================
    print("\n== item 2 对照组：支持的厂商，开关必须是真的能点 ==", flush=True)
    # =====================================================================
    pick_select(page, "model-vendor", "deepseek")
    page.wait_for_timeout(2500)
    chk("★★ deepseek 有**真**的「开启思考模式」开关（不是把所有人一起灰了）",
        page.locator("#model-thinking").count() == 1 and
        page.locator("#model-thinking").first.is_visible())

    # =====================================================================
    print("\n== item 3：量程跟着 (厂商, 模型) 走 ==", flush=True)
    # =====================================================================
    # ⚠️ 这一节**故意不写"某家厂商的上限等于几"**。表里只有 DeepSeek 一条是
    #    有出处的，其余的走默认档；把默认值抄进断言里当"期望"，只能证明
    #    "表没被改坏"，证明不了"自适应"。所以判据是**量程和目录里的表一致**，
    #    表改了这里跟着改 —— 它守的是"UI 真的读了那张表"这条接线。
    a = num_attrs(page, "#model-max_tokens")
    chk("★ 长度上限的 min/max/step 和目录里的默认档逐字一致（不是写死在 UI 里的）",
        a and a["min"] == "512" and a["max"] == "65536" and a["step"] == "512",
        extra=a)
    chk("★ 温度滑块的量程也一样（0 ~ 1.5，步长 0.1）",
        page.evaluate("""() => {
          var e = document.querySelector('#model-temp_ui .js-range-slider');
          return e ? {min: e.getAttribute('data-min'),
                      max: e.getAttribute('data-max'),
                      step: e.getAttribute('data-step')} : null;
        }""") == {"min": "0", "max": "1.5", "step": "0.1"})
    # 换一家再看一遍：量程必须**重新算过**，不能是第一次渲染时定死的。
    pick_select(page, "model-vendor", "qwen")
    page.wait_for_timeout(2500)
    b = num_attrs(page, "#model-max_tokens")
    chk("★★ 换厂商之后量程还在（控件被重建了，min/max 得重新落上）",
        b and b["min"] == "512" and b["max"] == "65536", extra=b)
    chk("★ 前置：真的把值改成越界的那个（改不成的话下面两条是空转）",
        page.evaluate("""() => {
          var e = document.querySelector('#model-max_tokens');
          if (!e) return false;
          e.value = '99999999';
          e.dispatchEvent(new Event('input', {bubbles: true}));
          e.dispatchEvent(new Event('change', {bubbles: true}));
          return true;
        }""") and num_attrs(page, "#model-max_tokens")["value"] == "99999999")
    # ⚠️ 要等过那个 1.5 秒的防抖（"他停手了"）+ 一次往返。等太短的话红的
    #    是测试而不是产品，而报出来的是"值没被拨回来"，看着像功能没做。
    page.wait_for_timeout(5000)
    c = num_attrs(page, "#model-max_tokens")
    chk("★★ 停手之后那个越界值被**拨回**范围里（不是只夹在发出去的请求里）",
        c is not None and c["value"] != "99999999" and int(c["value"]) <= 65536,
        extra=c)
    chk("★ 而且拨到的是上限本身，不是随手的某个数",
        c is not None and int(c["value"]) == 65536, extra=c)

    # =====================================================================
    print("\n== item 4：0DaysSCI 的链接和地址都对 ==", flush=True)
    # =====================================================================
    # ⚠️★ V13.12 item 5：这里原来钉的是"0daysci 排在第一位"（V13.6 时用户
    #    的原话是「排名最靠前」）。V13.12 他给了一份**完整**的排序：
    #    「DeepSeek 排第一，0DaysSCI 排第三，"中转站大全"排第二」——
    #    这是新指令，不是回归。所以"排第几"这条挪去钉新的前三名顺序，
    #    这个文件剩下的部分（链接、base_url、参数自适应）照旧只针对 0daysci。
    opts = vendor_options(page)
    chk("★★ 厂商下拉前三名 = 用户 V13.12 指定的那一份",
        len(opts) >= 3 and opts[:3] == ["deepseek", "relay", "0daysci"],
        extra="前五项：%s" % (opts[:5],))

    pick_select(page, "model-vendor", "0daysci")
    page.wait_for_timeout(2500)

    hrefs = page.locator("#model-key_help a")
    got = [hrefs.nth(i).get_attribute("href") or "" for i in range(hrefs.count())]
    chk("★★ 申请链接就是用户给的那一个（aff 码整串都在，没被截断）",
        REGISTER_URL in got, extra=got)
    chk("★ **只有一条**链接（它本身就是注册页，再冒一条控制台是同一句话写两遍）",
        len(got) == 1, extra=got)
    chk("★ 新标签页打开（不然点一下就把正在跑的对话弄丢了）",
        page.locator("#model-key_help a[target='_blank']").count() == 1)

    base = page.evaluate(
        "() => { var e = document.querySelector('#model-base_url');"
        " return e ? e.value : null; }")
    chk("★★ 接口地址自动填成 https://api.0daysci.com（用户给的原文，不带 /v1）",
        base == BASE_URL, extra="地址栏是 %r" % (base,))
    chk("★ 页面上说清楚了「这是个聚合平台，模型要现拉」（它有静态清单就怪了）",
        "获取模型" in page.inner_text(".dsapp-rail-model"))
    n_models = page.evaluate("""() => {
      var s = document.querySelector('#model-model');
      return s ? s.options.length : -1;
    }""")
    chk("★ 没填 Key 时模型下拉是空的，而不是编几个模型名塞进去"
        "（编的名字用户选中就是 404）", n_models == 0, extra="%d 个选项" % n_models)

    chk("★ 全程没有 JS 报错", not errs, extra=errs[:3])

    page.screenshot(path=OUT + "/params.png", full_page=True)
    br.close()

sys.exit(chk.done())
