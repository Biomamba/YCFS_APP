# -*- coding: utf-8 -*-
"""V16.5 item 5：**云工具暂时只对平台管理者开放，普通用户不显示**。

用户原话（2026-10-05）：

    「云工具暂时只对平台管理者开放，普通用户不显示」

这句要求落在**两个**出口上，探针得各量一次（只量一个的话，另一边写错完全
没症状）：
  · 左栏那一项 —— `DSAPP_NAV_ITEMS` 里 `role = "platform"`，
    经 `dsapp_nav_visible()` 筛；
  · 那一页本身 —— app.R 里 `if (platform_admin) { nav_panel("云工具"…) }`，
    普通用户的 DOM 里**根本不该有这一页**（不是藏起来：navset_hidden 本来
    就把所有页都留在 DOM 里、只藏不激活，所以"藏起来"和"没有"在
    `[data-value]` 上分得开，在 visibility 上分不开 —— 这正是本仓
    hidden-element-has-zero-rect 那条老账的同一类坑）。

★★ 三类账号都要量，缺一不可 —— 尤其**项目管理员**那一档：
   `dsapp_user_is_admin()` 对项目管理员也是 TRUE（他进得去「后台管理」），
   所以拿 `is_admin` 当云工具的闸，症状恰好是"项目管理员也看得见云工具"，
   而**普通用户那一档照样是全绿的**（他本来就什么都看不到）。
   用户说的是"只对平台管理者"，多放一种人就与这句话不符了。

⚠️ 每一档都配了**反向对照**（"这个选择器真的数得到东西吗"）：
   探针选择器写错时，`count() == 0` 这类断言会**静默通过** ——
   本仓栽过（v16.2 有一条探针从没跑过却长得像通过）。所以：
   · 量"普通用户没有 cloudtool 那一页"的同时，必须量到 `[data-value="chat"]` ≥ 1；
   · 量"平台管理员有"的那一档必须真的数到 ≥ 1（选择器坏了两档一起红）。

跑法：
    bash tests/ui_v7/make_instance.sh 8974 /tmp/dsapp_v165a
    python3 tests/ui_v165/probe_nav.py            # 退出码 0 = 全绿
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT


def rail_items(pg):
    """左栏现在有哪几项 —— 回 [(value, 中文名), …]。

    ⚠️ 认 `data-nav`（app.js 的拖拽重排和 dsappNav 都认它），不是认文字：
          文字是 label，改文案就会连带红一片。
    """
    return pg.evaluate(
        "() => Array.from(document.querySelectorAll('.dsapp-rail-link'))"
        ".map(a => [a.getAttribute('data-nav'),"
        "           (a.innerText || '').trim().split('\\n')[0]])")


def rail_vals(pg):
    return [v for v, _t in rail_items(pg)]


def panel_count(pg, value):
    """navset 里 `data-value` = value 的页有几个。

    ⚠️ 判"这一页在不在 DOM 里"只能这么量：bslib 的 navset_hidden 把**所有**
       页都留在 DOM 里（`.tab-pane` 只是加不加 active），所以
       `is_visible()` 对"没有这一页"和"有但没激活"都给 False —— 拿它当判据
       的话，普通用户那一档会因为完全无关的理由变绿。
    """
    return pg.evaluate(
        "(v) => document.querySelectorAll('[data-value=\"' + v + '\"]').length",
        value)


def set_role(db, uid, is_admin, scope):
    """把账号改成某一档（平台管理员 / 项目管理员 / 普通）。"""
    con = sqlite3.connect(db)
    con.execute("UPDATE users SET is_admin=?, admin_scope=? WHERE id=?",
                (1 if is_admin else 0, scope, uid))
    con.commit()
    row = con.execute("SELECT is_admin, admin_scope FROM users WHERE id=?",
                      (uid,)).fetchone()
    con.close()
    return row


def reload_to_shell(pg, email, tries=180):
    """reload 之后回到主界面（cookie 还在时直接进；退回登录页就登一次）。

    ★ 为什么非 reload 不可：`dsapp_main_ui` 是**会话开始那一刻**按当时的
      user 行渲染的（左栏、navset 都在里面）。改完库不 reload 的话，手里
      还是老那一棵树 —— 量到的是"改之前"的界面，而看上去像"改了没生效"。
      这和 memory 里 seed-then-reload 那条是同一个道理。
    """
    pg.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(tries):
        if pg.locator(".dsapp-shell").count():
            pg.wait_for_timeout(1200)
            return True
        if not submitted and pg.locator("#welcome-email").count():
            pg.fill("#welcome-email", email)
            pg.fill("#welcome-password", C.PW)
            pg.click("#welcome-do_login")
            submitted = True
        pg.wait_for_timeout(1000)
    pg.screenshot(path=OUT + "/probe_nav_reload_failed.png", full_page=True)
    return False


def main():
    ck = C.Chk()
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page()
        try:
            email = C.enter_app(pg, email="nav5_%s@example.com" % C.TAG)
            uid, db = C.seed_or_die(email)
            print("  账号 %s（uid=%s）库 %s" % (email, uid, db), flush=True)
            C.ensure_no_modal(pg)

            # ---- ① 普通用户（刚注册的就是）---------------------------------
            vals = rail_vals(pg)
            print("  普通用户左栏：%s" % vals, flush=True)
            ck("① ★★ 普通用户左栏**没有**「云工具」", "cloudtool" not in vals,
               "左栏=%s" % vals)
            ck("① ★ 普通用户左栏也没有「后台管理」（role=\"admin\" 那一档）",
               "admin" not in vals, "左栏=%s" % vals)
            # 反向对照：选择器真的数得到东西（不然上面两条是白送的）
            ck("① ★★ （反向对照）左栏数得到别的项（选择器没写错）",
               len(vals) >= 9 and "chat" in vals and "settings" in vals,
               "只有 %d 项：%s" % (len(vals), vals))
            ck("① ★★ 普通用户左栏里**没有**任何带 data-nav=cloudtool 的入口",
               pg.locator(".dsapp-rail-link[data-nav='cloudtool']").count() == 0)

            # ---- ② 普通用户：那一页**不在 DOM 里** --------------------------
            n_cloud = panel_count(pg, "cloudtool")
            n_chat = panel_count(pg, "chat")
            ck("② ★★★ 普通用户 DOM 里没有 cloudtool 这一页（不是藏起来，是没有）",
               n_cloud == 0, "量到 %d 个 [data-value=cloudtool]" % n_cloud)
            ck("② ★★ （反向对照）同一个选择器数得到 chat 那一页",
               n_chat >= 1, "量到 %d 个 [data-value=chat]（0 = 选择器写错了，"
                            "上面那条是白送的）" % n_chat)
            ck("② ★★ 连它的控件都没渲染（id 前缀 cloudtool- 一个都没有）",
               pg.evaluate("() => document.querySelectorAll('[id^=\"cloudtool-\"]')"
                           ".length") == 0)
            pg.screenshot(path=OUT + "/probe_nav_01_normal.png", full_page=True)

            # ---- ③ 项目管理员：有后台管理、**没有**云工具 --------------------
            # ⚠️ 这一档是这次改动的**要害**：is_admin 对项目管理员也是 TRUE。
            #    用 is_admin 当云工具的闸，这一条当场红，而普通用户那一档
            #    照样全绿 —— 这就是为什么三类账号缺一不可。
            print("  改成项目管理员：%s" % (set_role(db, uid, True, "project"),),
                  flush=True)
            ck("③ （前置）reload 回到主界面", reload_to_shell(pg, email))
            C.ensure_no_modal(pg)
            vals = rail_vals(pg)
            print("  项目管理员左栏：%s" % vals, flush=True)
            ck("③ ★★ 项目管理员左栏**有**「后台管理」", "admin" in vals,
               "左栏=%s" % vals)
            ck("③ ★★★ 项目管理员左栏**没有**「云工具」（is_admin 当闸就会红）",
               "cloudtool" not in vals, "左栏=%s" % vals)
            ck("③ ★★★ 项目管理员 DOM 里也没有那一页",
               panel_count(pg, "cloudtool") == 0)
            pg.screenshot(path=OUT + "/probe_nav_02_project.png", full_page=True)

            # ---- ④ 平台管理员：有，而且页面真的画得出来 ----------------------
            print("  改成平台管理员：%s" % (set_role(db, uid, True, "platform"),),
                  flush=True)
            ck("④ （前置）reload 回到主界面", reload_to_shell(pg, email))
            C.ensure_no_modal(pg)
            vals = rail_vals(pg)
            print("  平台管理员左栏：%s" % vals, flush=True)
            ck("④ ★★★ 平台管理员左栏**有**「云工具」", "cloudtool" in vals,
               "左栏=%s" % vals)
            ck("④ ★★ 而且它排在「论坛」和「技能」之间（表的顺序没被打乱）", (
                "cloudtool" in vals and "forum" in vals and "skills" in vals and
                vals.index("forum") < vals.index("cloudtool") < vals.index("skills")),
                "左栏=%s" % vals)
            n_cloud = panel_count(pg, "cloudtool")
            ck("④ ★★★ 平台管理员 DOM 里有那一页（同一个选择器，这一档数得到）",
               n_cloud >= 1,
               "量到 %d 个 —— 若两档都是 0，说明选择器坏了，不是「没有」" % n_cloud)

            # 真的切过去，并且页面**画出来了**（不是一片空白）
            C.goto(pg, "cloudtool")
            pg.wait_for_timeout(1500)
            # ⚠️⚠️ 量"这一页画出来了"**不能**拿它里面那些容器（preflight_box /
            #    no_ws_hint / run_box …）的矩形当判据：那几个 div 的
            #    `display` 是 **contents**（它们自己不产生盒子，只有里面的
            #    按钮/文字有）。所以"页面好好的"和"页面是空的"在那几个 id 上
            #    读到的**都是 0×0** —— 本仓 hidden-element-has-zero-rect 的
            #    又一个形状（那次的教训是"看不见的也有矩形"，这次反过来）。
            #    判据落在这两处：① 那一片 tab-pane 是 active 且有实打实的文字；
            #    ② 里面对用户可见的控件（「重新体检」那颗按钮）有真矩形。
            pane = pg.locator(".tab-pane[data-value='cloudtool']")
            pcls = (pane.first.get_attribute("class") or "") if pane.count() else ""
            ptxt = pane.first.inner_text() if pane.count() else ""
            ck("④ ★★★ 点过去之后那一页真的渲染了（active + 有内容，不是空白页）",
               pane.count() >= 1 and "active" in pcls and len(ptxt.strip()) > 80,
               "pane count=%d class=%r 文字 %d 字" % (pane.count(), pcls, len(ptxt)))
            btn = pg.locator("#cloudtool-check")
            bb = btn.first.bounding_box() if btn.count() == 1 else None
            ck("④ ★★ 页面里那颗「重新体检」按钮画出来了（有真矩形）",
               bb is not None and bb["width"] > 20 and bb["height"] > 10,
               "按钮 count=%d rect=%s" % (btn.count(), bb))
            ck("④ ★ 页面上写着「云工具」这一页自己的内容（不是别人的页）",
               "云工具" in ptxt or "体检" in ptxt or "工作区" in ptxt,
               "前 120 字：%s" % ptxt.strip().replace("\n", " ")[:120])
            pg.screenshot(path=OUT + "/probe_nav_03_platform.png", full_page=True)
        finally:
            ss = os.path.join(OUT, "probe_nav_%s.png" % time.strftime("%H%M%S"))
            try:
                pg.screenshot(path=ss, full_page=True)
                print("  （整页截图 %s）" % ss, flush=True)
            except Exception:
                pass
            br.close()
        sys.exit(ck.done())


main()
