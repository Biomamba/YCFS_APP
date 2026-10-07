# -*- coding: utf-8 -*-
"""V13.11 item 4 验收：单次回复上限以百万为单位、能填到百万级。

    bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311
    /home/biomamba/miniconda3/bin/python tests/ui_v1311/item04_tokens.py

用户原话：「单次 token 设置的太保守了，应该以 million 为单位」。
追问上限定在哪一档，答复是「**上限不设死，交给厂商报错**」——
所以这里验的是"够得着百万" + "界面上读得出量级是百万"，
**不是**"某家厂商的上限等于几"（那是厂商的事，不是这张表的）。

★ 为什么不能只跑 selftest：那边验的是几个纯函数和表。这一条验的是
  **控件真的渲染成了那个样子**——滑块跨度、建议值那排按钮上的字、
  点一下之后输入栏里到底是什么数。滑块能不能拖、chip 点了生不生效，
  只有真浏览器知道。
"""
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    ctx = br.new_context(viewport={"width": 1600, "height": 950})
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:200])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, _ = seed_or_die(email)
    print("uid=%s" % uid, flush=True)
    pg.wait_for_timeout(3000)
    goto(pg, "settings", wait=3000)
    pg.wait_for_timeout(2500)

    print("\n== 标签上直接读得出量级 ==", flush=True)
    label = pg.inner_text(".dsapp-maxtok-label").strip()
    print("   %r" % label, flush=True)
    C("★★★ 量程标签带上了上限，而且写成 M（不是 10485760）",
      "M" in label and "1048576" not in label, label)

    print("\n== 建议值那排按钮 ==", flush=True)
    chips = [c.strip() for c in pg.eval_on_selector_all(
        ".dsapp-sug-chip", "els => els.map(e => e.innerText)")]
    print("   %s" % chips, flush=True)
    C("★★★ 有百万档的按钮，且标签就是 M", "1M" in chips, str(chips))
    C("★★ 小档位还在（模型上限低的时候只剩它们能用）",
      "4K" in chips or "8K" in chips, str(chips))
    C("★★ 没有一个按钮印的是原始数字（4K 而不是 4,096）",
      not any(c.replace(",", "").isdigit() and len(c.replace(",", "")) > 3
              for c in chips), str(chips))

    print("\n== 点「1M」：输入栏真的变成 1048576 ==", flush=True)
    pg.click('.dsapp-sug-chip:text-is("1M")')
    pg.wait_for_timeout(2200)
    v1 = pg.input_value("#model-max_tokens")
    print("   输入栏 = %r" % v1, flush=True)
    C("★★★ 点 1M 之后输入栏是 1048576（不是被夹成别的数）",
      v1.strip() == "1048576", v1)
    on1 = pg.eval_on_selector_all(
        ".dsapp-sug-chip.on", "els => els.map(e => e.innerText.trim())")
    print("   高亮的是 %s" % on1, flush=True)
    C("★ 点完 1M，亮的就是 1M 那一档（不是点完还亮着别的）",
      on1 == ["1M"], str(on1))

    print("\n== 滑块跟着走（拖出来的值不能把它顶回去） ==", flush=True)
    s1 = pg.evaluate("() => { const e = document.querySelector("
                     "'.dsapp-maxtok-slider .irs-single');"
                     " return e ? e.textContent.trim() : null; }")
    print("   滑块上的当前值回显 = %r" % s1, flush=True)
    C("★ 滑块的回显跟着到了百万档", s1 is not None and "1,048,576" in s1, str(s1))

    print("\n== 输入栏能直接填到千万级（上限不设死） ==", flush=True)
    pg.fill("#model-max_tokens", "4194304")
    pg.click(".dsapp-maxtok-label")     # 失焦，让 Shiny 收下这个值
    pg.wait_for_timeout(2500)
    v2 = pg.input_value("#model-max_tokens")
    print("   填 4194304 之后 = %r" % v2, flush=True)
    C("★★★ 填 4M 不会被夹回去（这条就是「上限不设死」）",
      v2.strip() == "4194304", v2)
    on = pg.eval_on_selector_all(
        ".dsapp-sug-chip.on", "els => els.map(e => e.innerText.trim())")
    print("   高亮的是 %s" % on, flush=True)
    C("★ 4M 那个按钮自动变成选中态", on == ["4M"], str(on))

    print("\n== 超大的数也不报错（交给厂商，不是我们拦） ==", flush=True)
    pg.fill("#model-max_tokens", "9999999")
    pg.click(".dsapp-maxtok-label")
    pg.wait_for_timeout(2500)
    v3 = pg.input_value("#model-max_tokens")
    print("   填 9999999 之后 = %r" % v3, flush=True)
    C("★★ 界面上限之内的任意值都收得下", v3.strip() == "9999999", v3)
    on3 = pg.eval_on_selector_all(
        ".dsapp-sug-chip.on", "els => els.map(e => e.innerText.trim())")
    print("   高亮的是 %s" % on3, flush=True)
    C("★★ 填了个不在档位上的数，就一个都不亮（硬凑一档才是骗人）",
      on3 == [], str(on3))

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item4_tokens.png")
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
