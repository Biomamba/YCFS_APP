# -*- coding: utf-8 -*-
"""V13.10 冒烟：六个改动在**跑起来的界面**上各验一条。

    bash tests/ui_v7/make_instance.sh 8911 /tmp/dsapp_v1310boot
    DSAPP_TEST_URL=http://127.0.0.1:8911/ \
    DSAPP_TEST_APP=/tmp/dsapp_v1310boot/app \
    DSAPP_TEST_OUT=/tmp/dsapp_ui_v1310 \
    /home/biomamba/miniconda3/bin/python tests/ui_v1310/boot.py

★ 这里**只**冒烟，不做完整验收。完整验收（几何量、长程交互）在
  ui_v139 那一套里已经跑过一遍，V13.10 改的六处里只有三处是新界面
  （报告按钮、滑块+输入栏+建议值、后台报错日志卡片），其余三处是纯服务端
  行为。所以这个脚本回答的是"改完之后应用还起得来、新控件真的画出来了"，
  不是"这六条需求都做对了"—— 后者由 selftest.R 逐条钉字面量。

⚠️ 它**不重新起实例**。跑之前先自己 make_instance.sh，理由同 ui_v139：
  实例是热加载的一次性进程，脚本里再起一份会和已有的抢端口
  （2026-09-23 就撞了一次：make_instance.sh 报"起来了"，紧接着的
  runApp 报 address already in use，而 curl 照样 200 ——
  看着像脚本没问题，其实那个 200 是**前一个**实例给的）。
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "ui_v139"))
from _common import (Chk, DATA_ROOT, EMAIL, OUT, URL,   # noqa: E402
                     enter_app, goto, seed_or_die, wait_awake)

from playwright.sync_api import sync_playwright   # noqa: E402

C = Chk()


def main():
    print("== V13.10 冒烟：%s ==" % URL, flush=True)
    print("   数据目录 %s" % DATA_ROOT, flush=True)

    with sync_playwright() as pw:
        br = pw.chromium.launch(args=["--no-sandbox"])
        pg = br.new_page(viewport={"width": 1440, "height": 900})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))

        # ── 0. 起得来 + 注册进主界面（需求 1 的回归：整页白屏/报错页）
        #
        # ⚠️ enter_app 在实例**刚重启**的头一两次请求上会超时：它内部那个
        #    90 秒的循环是从"点完恢复码页"开始算的，而重启后的第一个
        #    session 要先重跑一遍建库/migrate + 一堆读库的 renderUI。
        #    2026-09-23 连着踩了三次，报的都是「注册没进主界面（页面文字
        #    0 字）」，看着像代码把应用改崩了，其实再跑一次就好。
        #    所以这里**重试**，而不是把这个当成断言失败 —— 但重试次数有上限，
        #    一直失败就是真有问题。
        email = None
        for attempt in range(1, 4):
            try:
                email = enter_app(pg)
                break
            except SystemExit as e:
                print("   第 %d 次注册超时（%s），重来…" % (attempt, str(e)[:60]),
                      flush=True)
                pg.wait_for_timeout(5000)
        if email is None:
            raise SystemExit("连试 3 次都没进主界面 —— 这次是真有问题，"
                             "看 %s/app.log" % os.environ.get("DSAPP_TEST_APP", "?"))
        uid, dbp = seed_or_die(email)
        print("   注册成功 uid=%s" % uid, flush=True)

        body = pg.inner_text("body")
        C(".dsapp-shell 出来了", pg.locator(".dsapp-shell").count() > 0)
        C("首屏**不是**那页报错页",
                 "An error has occurred" not in body
                 and "contact the app author" not in body)

        # 需求 1：平台自己的报错页/日志文件
        #
        # ⚠️ 比的是**增量**，不是"文件是不是空的"：这一个实例反复跑过很多轮，
        #    里面躺着历史记录（还包括我故意复现那次留下的），要求 0 行的话
        #    永远红。真正要回答的是"这一轮有没有新的错"。
        logf = os.path.join(DATA_ROOT, "logs", "app_error.log")

        def errlines():
            if not os.path.exists(logf):
                return 0
            return sum(1 for _ in open(logf, encoding="utf-8", errors="replace"))

        base_err = errlines()
        print("   app_error.log 起始 %d 行（只比增量）" % base_err, flush=True)

        # ── 需求 5：总结并生成报告按钮
        goto(pg, "chat")
        cnt = pg.locator("#chat-report_btn").count()
        C("言出法随页有「总结并生成报告」按钮", cnt > 0)
        if cnt:
            label = pg.locator("#chat-report_btn").inner_text().strip()
            C("按钮文字对得上（%r）" % label, "总结" in label)
            # 它得是**能点**的：被别的元素盖住的话 click 会超时
            pg.locator("#chat-report_btn").click(timeout=8000)
            pg.wait_for_timeout(1500)
            print("   报告按钮可点 ✓", flush=True)

        # ── 需求 6：滑块 + 输入栏 + 建议值
        #
        # ⚠️ 前缀是 **model-** 不是 settings-：参数区住在左栏那个
        #    <details class="dsapp-rail-model"> 里（app.R:791
        #    mod_model_ui("model")），不在"设置"页。而且那个 details 在
        #    **已配好模型时是收起的**（app.R:784 `open = if (saved) NULL`），
        #    收起时子元素仍在 DOM 里（所以 count() 照样数得到），但
        #    bounding_box() 是 0×0 —— 几何断言会全错。所以先展开。
        goto(pg, "chat")
        pg.wait_for_timeout(1500)
        det = pg.locator("details.dsapp-rail-model")
        if det.count() and not det.evaluate("(e) => e.open"):
            det.locator("summary").click()
            pg.wait_for_timeout(1200)
        has_slider = pg.locator("#model-max_tokens_slider").count() > 0
        has_input = pg.locator("#model-max_tokens").count() > 0
        C("长度上限有滑块", has_slider)
        C("长度上限有输入栏", has_input)
        if has_input:
            v = pg.locator("#model-max_tokens").input_value()
            C("输入栏有值（%s）" % v, (v or "").strip().isdigit())
        if has_slider and has_input:
            # ⚠️⚠️ 量的必须是 **.irs**（ionRangeSlider 真正画出来的那玩意），
            #    不是 #model-max_tokens_slider。
            #
            #    Shiny 的 sliderInput 生成的是一个原生 <input>，ionRangeSlider
            #    接管之后把它**藏起来**、在旁边画出 .irs 这一坨。那个原生
            #    input 的 bounding box 恒为 4×4 —— 拿它当"滑块画出来了没有"
            #    的判据，改对了也是红的、改错了也可能是绿的。
            #    （同一个坑的另一个实例见 selectize 藏原生 select。）
            #
            #    2026-09-23 就是先踩了这个：.irs 实测 143×40（滑块好好的），
            #    而断言盯着 4×4 的隐藏 input 报"滑块画不出来"。
            #    ⚠️ 加 .first：ionRangeSlider 自己会在 .irs 里面再套一层
            #    <span class="irs">（143×1，画边框用的），不加 .first 会被
            #    strict mode 判成"匹配到 2 个"直接抛错。那一层不是第二个滑块。
            #    ⚠️⚠️ 还得**先滚进视口**。参数区住在左栏那个 858px 高的滚动
            #    容器里，滑块的 y 实测 1218 —— 而视口只有 900 高。此时
            #    document.elementFromPoint() 直接返回 null（坐标在视口外），
            #    pg.mouse.* 是**视口坐标**、点了个寂寞：值纹丝不动，
            #    看上去像"滑块坏了"，其实只是没点在它身上。
            #    （locator.click() 会自动滚，所以建议值那排是好的 —— 差别就在这。）
            slider = pg.locator(".dsapp-maxtok-slider .irs").first
            slider.scroll_into_view_if_needed()
            pg.wait_for_timeout(600)
            box = slider.bounding_box()
            C("滑块画得出来（%s）" % (("%.0fx%.0f" % (box["width"], box["height"]))
                                     if box else "0×0"),
              bool(box) and box["width"] > 60)
            if box:
                before = pg.locator("#model-max_tokens").input_value()
                # ⚠️ 拖**手柄**（.irs-handle），不是点滑轨。
                #
                #    滑轨上的"点一下跳过去"在这个配置下**没有绑定** ——
                #    2026-09-23 实测：点 .irs / .irs-line / .irs-bar 各 30%~60%
                #    处，手柄一步都不动，值也不动；而拖 .irs-handle 立刻
                #    65536 → 6656。所以要验"滑块能用"，只能拖手柄。
                #    （顺带：手柄的类是 .irs-handle，不是 ionRangeSlider 老文档
                #      里的 .irs-slider —— 按老名字找会拿到 null。）
                hb = pg.locator(".dsapp-maxtok-slider .irs-handle").bounding_box()
                if hb:
                    pg.mouse.move(hb["x"] + hb["width"] / 2,
                                  hb["y"] + hb["height"] / 2)
                    pg.mouse.down()
                    pg.mouse.move(box["x"] + box["width"] * 0.15,
                                  hb["y"] + hb["height"] / 2, steps=20)
                    pg.mouse.up()
                    pg.wait_for_timeout(2000)
                after = pg.locator("#model-max_tokens").input_value()
                C("拖滑块 → 输入栏跟着变（%s → %s）" % (before, after),
                        hb is not None and before != after)
            # ⚠️ 建议值那几个 chip **没有 id** —— 它们的 id 只出现在 onclick
            #    的 Shiny.setInputValue 里（故意的，见 R/mod_model.R 那段注释：
            #    renderUI 重建会换掉一批 id，所以走固定名的 input + 值在消息里）。
            #    按 id 找是找不到的，只能按 class 找。
            chips = pg.locator(".dsapp-maxtok-sug .dsapp-sug-chip").count()
            C("滑块下面有建议值（%d 个）" % chips, chips >= 3)
            if chips:
                # 点一个建议值，输入栏要跟着变 —— 否则它只是个装饰
                b0 = pg.locator("#model-max_tokens").input_value()
                pg.locator(".dsapp-maxtok-sug .dsapp-sug-chip").first.click()
                pg.wait_for_timeout(2000)
                b1 = pg.locator("#model-max_tokens").input_value()
                C("点建议值 → 输入栏跟着变（%s → %s）" % (b0, b1), b0 != b1)

        # ── 需求 3：管理页表格不压住下面的按钮
        #
        # ⚠️ 得先把账号提成管理员，否则管理页根本画不出账号表 —— 而
        #    "看不到表 → 跳过几何检查"会让这条断言永远是绿的，
        #    等于没验。同 ui_v139 的做法：直接改库，不走界面（界面上提权
        #    要点一堆东西，而且改完之后**必须 reload** 才生效）。
        import sqlite3
        cx = sqlite3.connect(dbp)
        cx.execute("UPDATE users SET is_admin = 1, admin_scope = 'platform' "
                   "WHERE id = ?", (uid,))
        cx.commit()
        cx.close()
        pg.reload(wait_until="domcontentloaded")
        pg.wait_for_selector(".dsapp-shell", timeout=60000)
        pg.wait_for_timeout(2500)

        goto(pg, "admin")
        pg.wait_for_timeout(3500)
        # ⚠️ 表格 id 是 **admin-tbl**（"用户"那张卡），不是 admin-users_table。
        #    用户说的"账号表格与下方按钮重叠"就是这一张：它下面**同一张卡里**
        #    跟着「停用/启用」「重置恢复码」「重置密码」「删除账号」四个按钮。
        tbl = pg.locator("#admin-tbl").count()
        if tbl:
            tb = pg.locator("#admin-tbl").bounding_box()
            C("账号表画出来了（%s）" % (("%.0fx%.0f" % (tb["width"], tb["height"]))
                                       if tb else "无尺寸"), bool(tb))
            # 同卡体里、排在表格下面的那四个按钮
            got = []
            for bid in ["toggle", "reset_token", "reset_pw", "delete"]:
                loc = pg.locator("#admin-%s" % bid)
                if not loc.count():
                    continue
                b = loc.bounding_box()
                if b:
                    got.append((bid, b))
            C("表格下面还有动作按钮（%d 个）" % len(got), len(got) >= 3)
            # ★ 核心断言：按钮的顶边不能跑到表格底边上面去
            #   （重叠时按钮会画在表格行上面 —— 两边都没背景色，看着是"糊"）
            bad = [(n, b["y"] - (tb["y"] + tb["height"]))
                   for n, b in got if b["y"] < tb["y"] + tb["height"] - 1]
            gap = min([b["y"] - (tb["y"] + tb["height"]) for _n, b in got],
                      default=None)
            C("没有按钮压在表格上（最小间隙 %s）"
              % ("%.1fpx" % gap if gap is not None else "n/a"), not bad,
              extra=bad)
        else:
            C("管理页能画出账号表（这个账号是平台管理员）", False,
              "没找到 #admin-tbl —— 提权或 reload 没生效？")

        # ── 需求 1：后台页那张「应用报错日志」卡片
        #    （admin_scope=platform 才看得见，上面已经提过权了）
        goto(pg, "htadmin")
        pg.wait_for_timeout(3000)
        has_card = pg.locator("#htadmin-err_log").count() > 0
        C("后台页有「应用报错日志」卡片", has_card)
        if has_card:
            hb = pg.inner_text("body")
            C("卡片说明里指到了 app_error.log", "app_error.log" in hb)

        # ★ 全流程走完之后再看一次：这一轮（注册→每个页面→后台页）不该
        #   往 app_error.log 里加任何东西。后台页那条 `'length = N' in
        #   coercion to 'logical(1)'` 就是这么抓出来的。
        now_err = errlines()
        C("全流程没有新增平台报错（%d → %d）" % (base_err, now_err),
          now_err == base_err)
        if now_err > base_err:
            lines = open(logf, encoding="utf-8", errors="replace").read().splitlines()
            for ln in lines[base_err:base_err + 3]:
                print("     %s" % ln[:150], flush=True)

        C("全程没有 JS 未捕获异常（%d）" % len(errs), not errs)
        for e in errs[:3]:
            print("     %s" % e[:160], flush=True)

        pg.screenshot(path=os.path.join(OUT, "boot.png"), full_page=True)
        br.close()

    return C.done()


if __name__ == "__main__":
    sys.exit(main())
