# -*- coding: utf-8 -*-
"""item 8 验收：更新按钮在最底部 + 离开模型服务时提醒未确认的改动。

用户原话：
  8、模型服务的更新按钮可以在最底部，离开模型服务界面时如果有信息更新
     未确认，应该提醒用户确认

这一条验两件事，一件是位置，一件是"收起面板会不会被拦下来"：

  (a) 「更新」按钮要排在**生成参数之后**。原来是夹在「接口地址」和「生成
      参数」中间的，用户填完下面的参数还得往回滚。
  (b) 把左栏那块 <details> 收起来 = 离开模型服务。改过东西再收起，必须
      弹一个确认框；点「继续编辑」留下，点「先收起来」才真的收起。

★ 这条链路上最容易静默失效的一环是 toggle 事件：它**不冒泡**，用普通的
  事件委托（$(document).on / addEventListener 不带 true）一个字都收不到，
  而且不报任何错 —— 表现就是"改了东西收起面板，什么都不发生"。
  所以这条必须真的在浏览器里点一次，光看代码看不出来。
"""
import sys

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import enter_app   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


def modal_open(pg):
    try:
        return pg.eval_on_selector_all(
            ".modal.show, .modal[style*='display: block']",
            "els => els.length > 0")
    except Exception:
        return False


def modal_text(pg):
    # ⚠️ 必须读**整个** .modal，不能只读 .modal-body：页脚那两个按钮
    #    （「继续编辑」/「先收起来」）住在 .modal-footer 里。第一版只读
    #    body，于是"有没有给退路"这两条恒为假 —— 按钮明明在。
    try:
        return pg.inner_text(".modal.show")
    except Exception:
        return ""


def panel_open(pg):
    return pg.evaluate(
        "() => { var d = document.querySelector('details.dsapp-rail-model');"
        " return d ? d.open : null; }")


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    pg = br.new_context(viewport={"width": 1500, "height": 950}).new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:180]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:180])
          if m.type == "error" else None)

    email = enter_app(pg)
    print("登录成功：%s" % email, flush=True)
    pg.wait_for_timeout(3500)

    # ---- (a) 按钮必须在最底部 -------------------------------------------
    print("\n== (a)「更新」按钮的位置 ==", flush=True)
    pg.wait_for_selector("details.dsapp-rail-model", timeout=15000)
    if not panel_open(pg):
        pg.click("details.dsapp-rail-model > summary")
        pg.wait_for_timeout(1200)

    box_btn = pg.eval_on_selector(
        "details.dsapp-rail-model button#model-commit",
        "e => { var r = e.getBoundingClientRect(); return {y: r.top, t: e.innerText.trim()}; }")
    box_params = pg.eval_on_selector(
        "details.dsapp-rail-model .dsapp-model-params",
        "e => e.getBoundingClientRect().top")
    box_base = pg.eval_on_selector(
        "details.dsapp-rail-model input#model-base_url",
        "e => e.getBoundingClientRect().top")
    print("   按钮「%s」y=%.0f / 生成参数 y=%.0f / 接口地址 y=%.0f"
          % (box_btn["t"], box_btn["y"], box_params, box_base), flush=True)
    C("★★★ 更新按钮排在「生成参数」下面（用户原话「可以在最底部」）",
      box_btn["y"] > box_params, "按钮 y=%.0f > 参数 y=%.0f" % (box_btn["y"], box_params))
    C("★★ 也排在「接口地址」下面（原来夹在地址和参数中间）",
      box_btn["y"] > box_base)
    C("★ 按钮文字是「确认」或「更新」（没配过 Key 时是「确认」）",
      box_btn["t"] in ("确认", "更新"), box_btn["t"])
    # 点得到才算数：被别的元素盖住的话 y 再大也没用。
    # ⚠️ 先滚进视野 —— 这块面板很长、按钮在最底下，950px 的视口本来就装不下
    #    它（这正是"最底部"的含义）。不滚就量，量到的是"它在屏幕外"，
    #    那不算缺陷，是测量方法错了。
    pg.eval_on_selector("details.dsapp-rail-model button#model-commit",
                        "e => e.scrollIntoView({block: 'center'})")
    pg.wait_for_timeout(600)
    C("★★ 滚到它之后真的点得到（没被侧栏裁掉、没被别的元素盖住）",
      pg.eval_on_selector(
          "details.dsapp-rail-model button#model-commit",
          "e => { var r = e.getBoundingClientRect();"
          " var t = document.elementFromPoint(r.left + r.width/2, r.top + r.height/2);"
          " return !!(t && (t === e || e.contains(t))); }"))

    # ---- (b1) 没改动时收起，不该弹框 --------------------------------------
    print("\n== (b1) 什么都没改，收起面板不该被打扰 ==", flush=True)
    pg.click("details.dsapp-rail-model > summary")
    pg.wait_for_timeout(2500)
    C("★★ 没收起来？那说明前面根本没展开过", panel_open(pg) is False,
      "open=%s" % panel_open(pg))
    C("★★★ 没改东西时**不许**弹确认框（弹了就是误报，很快会被无视）",
      not modal_open(pg), modal_text(pg)[:80])

    # 重新展开，准备改点东西
    pg.click("details.dsapp-rail-model > summary")
    pg.wait_for_timeout(1500)
    C("★ 能重新展开", panel_open(pg) is True)

    # ---- (b2) 改一样，再收起 → 必须拦下来 --------------------------------
    print("\n== (b2) 改过东西再收起，必须提醒确认 ==", flush=True)
    before = pg.input_value("details.dsapp-rail-model input#model-base_url")
    pg.fill("details.dsapp-rail-model input#model-base_url",
            (before or "") + "x")
    pg.wait_for_timeout(1500)          # 跨过 800ms 的自动保存防抖
    pg.click("details.dsapp-rail-model > summary")
    pg.wait_for_timeout(2500)

    got = modal_open(pg)
    txt = modal_text(pg) if got else ""
    print("   确认框：%s" % (txt.replace("\n", " | ")[:200] if got else "（没出现）"),
          flush=True)
    C("★★★ 改过东西再收起，弹出了确认框", got)
    if got:
        C("★★ 面板被**重新摊开**了（不然用户还得自己回去展开一次）",
          panel_open(pg) is True, "open=%s" % panel_open(pg))
        C("★★ 说清楚了改的是哪一样（接口地址）", "接口地址" in txt)
        # ⚠️ 判据是"文案跟真实行为对得上"。四个框都是 800ms 防抖自动落库的，
        #    写「不会生效」就是假话 —— 实测过，不点也照样生效。
        C("★★★ 文案承认改动会自动保存（不许说「不会生效」这种假话）",
          "自动保存" in txt and "不会生效" not in txt)
        C("★★ 给了「继续编辑」这条路", "继续编辑" in txt)
        C("★★ 也给了「先收起来」这条路（提醒不能变成锁死）", "先收起来" in txt)
        C("★ 文案里没有漏出来的 Markdown 星号", "**" not in txt)

    # ---- (b3)「继续编辑」：框关掉、面板留着 ------------------------------
    if got:
        print("\n== (b3) 点「继续编辑」 ==", flush=True)
        pg.click(".modal.show button:has-text('继续编辑')")
        pg.wait_for_timeout(1500)
        C("★★ 框关掉了", not modal_open(pg))
        C("★★ 面板还开着（他说了要继续编辑）", panel_open(pg) is True)

        # ---- (b4) 再收起 → 又拦一次（提醒不是一次性的）--------------------
        print("\n== (b4) 再收起一次，还得拦 ==", flush=True)
        pg.click("details.dsapp-rail-model > summary")
        pg.wait_for_timeout(2500)
        C("★★★ 还没确认就再收一次，照样拦下来", modal_open(pg))
        C("★★★ 而且没有陷入「收起→重开→收起」的死循环（面板是开着的）",
          panel_open(pg) is True)

        # ---- (b5)「先收起来」：这次真的要收起来 ---------------------------
        print("\n== (b5) 点「先收起来」 ==", flush=True)
        pg.click(".modal.show button:has-text('先收起来')")
        pg.wait_for_timeout(2500)
        C("★★ 框关掉了", not modal_open(pg))
        C("★★★ 这次真的收起来了（按钮的承诺跟行为一致）",
          panel_open(pg) is False, "open=%s" % panel_open(pg))
        # ⚠️ 最要命的一条：服务端主动收起也会触发 toggle。不屏蔽的话
        #    "收起 → 上报 → 发现没保存 → 又展开 + 弹框"会转成死循环，
        #    用户点多少次都关不掉这块面板。
        pg.wait_for_timeout(3000)
        C("★★★ 3 秒后**没有**自己弹回来（服务端那次收起没有回声）",
          panel_open(pg) is False and not modal_open(pg),
          "open=%s modal=%s" % (panel_open(pg), modal_open(pg)))

    # ---- (b6) 点完「更新」，快照要跟着刷新 ---------------------------------
    # ⚠️ 这一条盯的是最容易漏的一步：快照不刷新的话，用户刚点完「更新」再收起
    #    面板，会被问一句"你改了还没更新"—— 而他才刚更新完。提醒一旦开始说
    #    假话，用户就学会无视它了，整个功能等于白做。
    print("\n== (b6) 点完「更新」之后，提醒必须闭嘴 ==", flush=True)
    if panel_open(pg) is not True:
        pg.click("details.dsapp-rail-model > summary")
        pg.wait_for_timeout(1500)
    pg.eval_on_selector("details.dsapp-rail-model button#model-commit",
                        "e => e.scrollIntoView({block: 'center'})")
    pg.wait_for_timeout(400)
    pg.click("details.dsapp-rail-model button#model-commit")
    # 这个账号没有 Key，点完会弹一句「设置已保存。还没填 API Key」。
    # 那也算"确认过了" —— 设置确实存下来了。
    pg.wait_for_timeout(3000)
    if panel_open(pg) is True:            # 有 Key 时保存成功会自动收起
        pg.click("details.dsapp-rail-model > summary")
        pg.wait_for_timeout(2500)
    C("★★★ 刚点完「更新」就收起，不许再问一遍「还没确认」",
      not modal_open(pg), modal_text(pg)[:120])
    C("★ 这时候面板应该正常收起（没人拦）", panel_open(pg) is False,
      "open=%s" % panel_open(pg))

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item8_rail.png")
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
