# -*- coding: utf-8 -*-
"""Test_V15.2 · 浏览器验收：邮件提醒 + 定时订阅

    bash tests/ui_v7/make_instance.sh 8922 /tmp/dsapp_v152
    python3 tests/ui_v152/probe_v152.py

这一版管两件工单：

  item 1/3  文献速递页多一张「发到我的邮箱」卡
  item 2    「言出法随」页多一个「跑完发邮件」勾选框；文献速递页多一张
            「定时订阅」卡；设置 → 执行 页多一张「邮件提醒」卡

自检和那七个 `tests/v152_*.R` 已经把**函数层**证到位了（MIME 字节、
next_at 边界、认领的原子性、偏好键、收尾钩子、假 SMTP 端到端）。
浏览器这一边回答的是另外几个问题，它们可以各自单独坏掉而 R 那边全绿：

  1. **「函数对了」和「用户看得见」是两件事。** R 那边能证明
     `dsapp_litsub_add()` 写进去了、`dsapp_uipref_save()` 存下了 ——
     证明不了**表格上多了一行**、**勾选框跟着变了**。
  2. **降级路径**：没配 SMTP 的部署里，邮件相关的 UI 必须**整个不出现**
     （D4：不加开关、用"配没配齐"判断）。这一条只有把页面开起来才看得见 ——
     它是 `if` 出来的，源码级断言只能说"文件里有个 if"。
  3. **两个入口一份真相**：「言出法随」的勾选框和设置页的勾选框改的是
     **同一个键**。在一边勾上、切到另一边，那一边必须显示新值 ——
     这是"同一份真相"在界面上的定义。
  4. **写完要回库确认**。memory 的 `cooldown-looks-like-broken-ui` 那条：
     界面上的"没反应"和"压根没写进去"长得一模一样，判断写没写进去不能靠页面。

⚠️ 会**真的注册账号、建订阅、改偏好**，所以只能对着 /tmp 那份实例跑。
   `_common.guard()` 把"指向仓库本身"和"data_root 不在 /tmp 下"直接拦下。

★★ 这个脚本要**跑两遍**，两遍验的不是同一件事：

    第一遍（裸实例，`.Renviron` 里没有 DSAPP_SMTP_*）
        → 走「降级」分支：断言邮件 UI 整块不出现。
        → 订阅卡照常在（跑检索和发不发信是两件独立的事，见 mod_lit.R 里那段）。

    然后给实例加上四个**假**的 SMTP 项（不用真凭据，界面只判"非空"），
    重启实例，再跑一遍：
        → 走「配齐」分支：卡片出现、勾选框能用、订阅的增删改开关全部回库确认。

    假 SMTP 的写法（**别抄生产凭据进来**，见 README）：

        printf 'DSAPP_DATA_ROOT=/tmp/dsapp_v152/data\n'
        printf 'DSAPP_SMTP_HOST=127.0.0.1\nDSAPP_SMTP_PORT=2525\n'
        printf 'DSAPP_SMTP_USER=probe@example.com\n'
        printf 'DSAPP_SMTP_PASS=not-a-real-password\n'
        printf 'DSAPP_SMTP_FROM=probe@example.com\nDSAPP_TZ=Asia/Shanghai\n'
        ) > /tmp/dsapp_v152/app/.Renviron

    ⚠️ 「发一封测试邮件」「发这一份」这两颗按钮**故意不点**：它们会把信真的
       投出去（或者对着一个不存在的服务器重试三次）。那两条路已经由
       tests/v152_fake_smtp.R（假服务器收到字节）和 tests/real_mail.R /
       real_notify.R（真 SMTP）验过了，这里只验"按钮在、地址对"。
"""
import json
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

TAG = C.TAG
EMAIL = "v152_ui_%s@example.com" % TAG

chk = C.Chk()
DB = {"path": None}


def shot(page, name):
    try:
        page.screenshot(path=os.path.join(C.OUT, name + ".png"), full_page=True)
    except Exception:
        pass


# ---- 直接读库 --------------------------------------------------------------
def q(sql, args=()):
    con = sqlite3.connect(DB["path"])
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def ids_of(sql, args=()):
    return set(r[0] for r in q(sql, args))


def wait_new(sql, args=(), known=(), timeout=25):
    """轮询到**出现一个不在 `known` 里的新行**，返回它的 id；超时返回 None。

    ★★ 为什么每条写操作后面都要**回库确认**：界面上的"没反应"和"压根没写
       进去"长得一模一样。少了这一步，被服务端拒掉的写会被误诊成渲染 bug ——
       论坛那一版就是这么红的（10 秒限流把大部分写拒了，看着像楼层没画出来）。

    ⚠️⚠️ 判据必须是"**多了一个**"，不能是"查得到行"。第一版写的是
       `wait_row("SELECT ...")` —— 那条查询在写之前就已经有结果了（表里本来
       就有一条），于是它**立刻返回**，等于没等。后果不只是那一条断言红：
       紧接着的界面动作会和服务端那次重画**抢跑**（`sub_add` 会 bump
       subs_rev → 整张表格连同 `sub_pick` 那个 selectize 一起重建，
       已经点开的下拉被收回去），报出来的是"下拉里没有选项"，
       指向的是完全无关的地方。
    """
    known = set(known)
    end = time.time() + timeout
    while time.time() < end:
        new = ids_of(sql, args) - known
        if new:
            return max(new)
        time.sleep(0.4)
    return None


def wait_val(sql, args, want, timeout=25):
    """轮询到一个**标量**变成 want。判据同样不能是"查得到行"。"""
    end = time.time() + timeout
    while time.time() < end:
        r = q(sql, args)
        if r and r[0][0] is not None and str(r[0][0]) == str(want):
            return True
        time.sleep(0.4)
    return False


def wait_gone(sql, args=(), timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        if not q(sql, args):
            return True
        time.sleep(0.4)
    return False


def pick_sub(page, sid):
    """在「选中一条」那个下拉里选中 id=sid 并点下去。

    ⚠️ 不能直接用 `_common.pick_select`：那个函数是"点开→找选项→点选项"一条
       直线，超时 30 秒。而 `sub_pick` 这个 selectize **每次动作都会被重建**
       （`subs_rev` 一变，整张 `sub_table` 连同它一起重画）—— 重建会把已经
       点开的下拉收回去，于是"点开→找选项"扑空，等 30 秒后报
       "下拉里没有选项"。而真相是"重画把它收了"，跟选项在不在毫无关系。
       所以这里**重试**：点开、等一下、没有选项就重新点一轮。
    """
    ctrl = page.locator(
        "xpath=//select[@id='lit-sub_pick']/following-sibling::div"
        "[contains(@class,'selectize-control')]")
    end = time.time() + 45
    while time.time() < end:
        if ctrl.count():
            try:
                ctrl.first.locator(".selectize-input").click(timeout=5000)
            except Exception:
                page.wait_for_timeout(700)
                continue
            page.wait_for_timeout(500)
            opt = ctrl.first.locator(".option[data-value='%s']" % sid)
            if opt.count():
                try:
                    opt.first.click(timeout=5000)
                    page.wait_for_timeout(600)
                    return True
                except Exception:
                    pass
        page.wait_for_timeout(700)
    return False


# ---- .Renviron：判断这个实例配没配 SMTP -------------------------------------
def env_of(app):
    d = {}
    p = os.path.join(app, ".Renviron")
    if not os.path.exists(p):
        return d
    with open(p, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln or ln.startswith("#") or "=" not in ln:
                continue
            k, v = ln.split("=", 1)
            d[k.strip()] = v.strip().strip('"').strip("'")
    return d


ENV = env_of(C.APP)
SMTP_ON = all(ENV.get(k, "").strip() for k in
              ("DSAPP_SMTP_HOST", "DSAPP_SMTP_USER", "DSAPP_SMTP_PASS",
               "DSAPP_SMTP_FROM"))
TZ = ENV.get("DSAPP_TZ", "") or "UTC"


# ---- DOM 小工具 -------------------------------------------------------------
def out_text(page, out_id):
    """一个 `uiOutput()` 容器里的文字。

    ★★ 为什么认**容器 id** 而不是扫页面文字：bslib 把没选中的 nav_panel
       也留在 DOM 里，`inner_text("body")` 里混着**别的页**的内容。
       断"这张卡不出现"时它尤其致命 —— 只要任何一页留着那五个字，
       这一条就永远红；反过来断"有某句话"时又可能被别的页蒙混过去。
       `uiOutput(ns("x"))` 在 DOM 里就是 `<div id="<模块>-x">`，
       没渲染时它是**空的但不消失**，正好当作"这张卡在不在"的判据。
    """
    loc = page.locator("#" + out_id)
    if loc.count() == 0:
        return None                      # 容器本身都没有（output 都没建）
    return (loc.first.inner_text() or "").strip()


def vis_text(page, sel):
    """**可见的**那些匹配元素的文字拼起来。

    ⚠️ `.dsapp-page` 在**每个模块**上都有一层（chat / lit / settings / …），
       而 bslib 把没选中的页也留在 DOM 里。所以 `page.inner_text(".dsapp-page")`
       量到的是 DOM 里排第一的那一页，跟"用户现在看着哪一页"没有关系 ——
       第一版拿它做"确实切到设置页了"的反向断言，红的是探针不是应用。
    """
    return page.evaluate("""(s) => {
      let out = '';
      for (const e of document.querySelectorAll(s)) {
        if (e.offsetParent === null &&
            getComputedStyle(e).position !== 'fixed') continue;
        out += (e.innerText || '') + '\\n';
      }
      return out;
    }""", sel) or ""


def exists(page, sel):
    return page.locator(sel).count() > 0


def checked(page, sel):
    loc = page.locator(sel)
    if loc.count() == 0:
        return None
    try:
        return loc.first.is_checked()
    except Exception:
        return None


def settings_exec(page):
    """切到设置页的「执行」二级页签。

    ⚠️ 选择器必须带 `.dsapp-page` 前缀：只写 `text=执行` 会先命中对话页那颗
       「确认执行」按钮 —— 所有页都在 DOM 里，而那颗按钮排得更靠前。
       Playwright 于是去点一个**不可见**的元素，等到超时，报的是
       "元素不可见"，看起来像"执行页不存在"。
    """
    C.goto(page, "settings")
    page.wait_for_timeout(1500)
    page.click(".dsapp-page .nav-link:has-text('执行')", timeout=15000)
    page.wait_for_timeout(2000)


# =============================================================================
# 降级：没配 SMTP 时，邮件相关的 UI **整个不出现**
# =============================================================================
def part_degraded(page):
    print("\n== 降级：这个实例没配 SMTP（%s）==" % C.APP, flush=True)

    C.goto(page, "lit")
    page.wait_for_timeout(2000)
    mail_card = out_text(page, "lit-mail_lit_card")
    chk("★★★ 没配 SMTP 时「发到我的邮箱」整张卡不出现",
        not (mail_card or "").strip(),
        repr((mail_card or "")[:120]))
    sub_card = out_text(page, "lit-litsub_card") or ""
    chk("★ 但「定时订阅」卡照常在（跑检索和发不发信是两件独立的事）",
        "定时订阅" in sub_card, repr(sub_card[:120]))
    shot(page, "01_degraded_lit")

    C.goto(page, "chat")
    page.wait_for_timeout(2000)
    # ⚠️ 用 count() 而不是 is_visible()：不切到对话页时那一格也在 DOM 里
    #    （bslib 只藏不激活），可见性是页面切换的产物，和"有没有这个控件"
    #    不是一回事。
    chk("★★★ 没配 SMTP 时「言出法随」那格邮件提醒不出现",
        not exists(page, "#chat-mail_notify"),
        page.locator("#chat-mail_notify").count())
    shot(page, "02_degraded_chat")

    settings_exec(page)
    mc = out_text(page, "settings-mail_card_wrap")
    chk("★★★ 没配 SMTP 时设置页那张邮件卡（连标题）不出现",
        not (mc or "").strip(), repr((mc or "")[:120]))
    chk("★★ 反向：设置页确实切到「执行」栏了（不是量了个空页才说「没有邮件卡」）",
        u"AI 怎么干活" in vis_text(page, ".dsapp-page"),
        repr(vis_text(page, ".dsapp-page")[:200]))
    shot(page, "03_degraded_settings")


# =============================================================================
# 配齐：卡片出现、两个入口一份真相、订阅增删改开关全部回库确认
# =============================================================================
def part_full(page, uid):
    print("\n== 配齐：实例的 .Renviron 里有四个非空 DSAPP_SMTP_* ==", flush=True)

    # ---- 1. 文献速递页那张卡 ------------------------------------------------
    C.goto(page, "lit")
    page.wait_for_timeout(2500)
    mail_card = out_text(page, "lit-mail_lit_card") or ""
    chk("★★ 配齐 SMTP 后「发到我的邮箱」卡出现了",
        "发到我的邮箱" in mail_card, repr(mail_card[:150]))
    chk("★★ 卡上显示的收件地址就是登录邮箱（users.email，不是另填的）",
        EMAIL in mail_card, repr(mail_card[:200]))
    # ★★ 「刷新列表」必须在"一份速递都没有"时**也**在。它原来跟着下拉一起
    #    藏在 else 分支里，于是空列表时按钮也消失 —— 而空列表恰恰是唯一
    #    需要按它的时刻，卡上那句"点「刷新列表」再看看"成了一句指向不存在
    #    按钮的话。这个账号是全新的，一份速递都没有，正好是那一刻。
    chk("★★★ 这个账号一份速递都没有时，「刷新列表」按钮**仍然在**",
        exists(page, "#lit-mail_lit_refresh"))
    chk("★ 反向：没有速递，就**不该**有「发这一份」和下拉克（不然是画了张空下拉）",
        not exists(page, "#lit-mail_lit_go") and
        not exists(page, "#lit-mail_lit_pick"))
    shot(page, "04_full_lit_mail")

    # ---- 2. 两个入口一份真相：先在「言出法随」勾 --------------------------
    C.goto(page, "chat")
    page.wait_for_timeout(2000)
    chk("★★ 配齐 SMTP 后「言出法随」那格出现了", exists(page, "#chat-mail_notify"))
    before = json.loads((q("SELECT ui_prefs FROM users WHERE id = ?", (uid,))
                         [0][0]) or "{}").get("email_task", False)
    chk("★ 起手是关的（新账号默认不发信）", before is False, before)
    if exists(page, "#chat-mail_notify"):
        page.check("#chat-mail_notify")
    ON = ("SELECT json_extract(ui_prefs, '$.email_task') FROM users WHERE id = ?",
          (uid,))
    chk("★★★ 勾上之后**库里真的变成 true**（不是只改了界面）",
        wait_val(ON[0], ON[1], 1),
        q(ON[0], ON[1]))
    shot(page, "05_chat_checked")

    # ---- 3. 切到设置页：那边必须显示**同一个**值 --------------------------
    settings_exec(page)
    mc = out_text(page, "settings-mail_card_wrap") or ""
    chk("★★ 设置页那张邮件卡出现了", "邮件提醒" in mc, repr(mc[:150]))
    chk("★★ 卡上写的收件地址也是登录邮箱", EMAIL in mc, repr(mc[:250]))
    box = checked(page, "#settings-pref_mail_task")
    chk("★★★ 在「言出法随」勾的那一下，设置页这边**跟着是勾的**"
        "（两个入口一份真相）", box is True, box)
    chk("★ 第二个开关（定时订阅发整份）起手是关的",
        checked(page, "#settings-pref_mail_lit") is False)
    shot(page, "06_settings_mail")

    # ---- 4. 反过来：在设置页取消，对话页那边要跟着变 ----------------------
    if box is True:
        page.uncheck("#settings-pref_mail_task")
    chk("★★★ 在设置页取消之后库里变成 false", wait_val(ON[0], ON[1], 0),
        q(ON[0], ON[1]))
    C.goto(page, "chat")
    page.wait_for_timeout(2500)
    chk("★★★ 回到「言出法随」，那一格跟着变成没勾",
        checked(page, "#chat-mail_notify") is False,
        checked(page, "#chat-mail_notify"))
    # 顺手把它勾回来 —— 任务通知的开关留在「开」的状态更像真实用法，
    # 也不影响后面（后面动的是订阅，另一个键）。
    if exists(page, "#chat-mail_notify"):
        page.check("#chat-mail_notify")
    wait_val(ON[0], ON[1], 1)

    # ---- 5. 定时订阅：增（也是"改"，这一版没有单独的编辑动作）------------
    C.goto(page, "lit")
    page.wait_for_timeout(2500)
    sub_card = out_text(page, "lit-litsub_card") or ""
    chk("★★ 「定时订阅」卡在", "定时订阅" in sub_card, repr(sub_card[:120]))
    # ⚠️ 时区要**写出来**。"每天早上 8 点"在 UTC 库里是 0 点，界面上不写时区
    #    的话，用户永远不知道他看到的是哪个 8 点。
    chk("★★ 卡上写明了时区（不然没人知道是哪个 8 点）",
        TZ in sub_card, "%s vs %r" % (TZ, sub_card[:300]))
    chk("★ 起手没有订阅（新账号）",
        "还没有订阅" in (out_text(page, "lit-sub_table") or ""),
        repr((out_text(page, "lit-sub_table") or "")[:80]))

    # ⚠️ 关键词是**上面「检索条件」里那一套**，订阅存的是它。先填关键词，
    #    不然 sub_add 会在服务端被判"上面还没填关键词"直接返回。
    page.fill("#lit-kw", "单细胞 空间转录组")
    page.wait_for_timeout(1200)
    kw_preview = out_text(page, "lit-sub_new_summary") or ""
    chk("★ 「会存下什么」把用户填的关键词切给他看了",
        "单细胞" in kw_preview, repr(kw_preview[:120]))

    page.click("#lit-sub_add")
    new1 = wait_new("SELECT id FROM lit_subs WHERE user_id = ?", (uid,))
    chk("★★★ 点「新建订阅」之后**库里真的多了一行**（回库确认）",
        new1 is not None, new1)
    if new1 is None:
        return
    sid1 = int(new1)
    # ⚠️ 建完服务端会 bump subs_rev → 整张表格重画。等它画完再动界面上
    #    那些会被重画的控件（尤其是 sub_pick 那个 selectize）。
    page.wait_for_timeout(2000)
    row = q("SELECT id, keywords, freq, hour, minute, enabled, next_at"
            " FROM lit_subs WHERE id = ?", (sid1,))[0]
    kws1, freq1, hh1, mm1, en1, next1 = row[1:]
    chk("★★ 存的关键词就是上面填的那串", "单细胞" in (kws1 or ""), kws1)
    chk("★★ 默认频率是每周（表单里的默认值真的传下去了）", freq1 == "weekly", freq1)
    chk("★★ 默认时:分是 8:00", (hh1, mm1) == (8, 0), (hh1, mm1))
    chk("★★ 「建好就打开」默认是勾的 → enabled=1", int(en1) == 1, en1)
    chk("★★★ 一建好就算好了下次运行时刻（模板里「（关着）」那一支不该出现）",
        bool((next1 or "").strip()), next1)
    tbl = out_text(page, "lit-sub_table") or ""
    chk("★★ 表格上真的画出了那行（不是只写进库）",
        "单细胞" in tbl and "每周" in tbl, repr(tbl[:200]))
    chk("★★ 「下次运行」那一栏显示的是算好的时刻，不是「（关着）」",
        (next1 or "")[:16] in tbl, repr(tbl[:250]))
    shot(page, "07_sub_added")

    # ---- 6. 再建一条：不同频率（这就是"改"） ------------------------------
    C.pick_select(page, "lit-sub_freq", "monthly")
    page.fill("#lit-sub_dom", "31")
    page.fill("#lit-sub_hour", "21")
    page.fill("#lit-sub_min", "30")
    page.click("#lit-sub_add")
    new2 = wait_new("SELECT id FROM lit_subs WHERE user_id = ?", (uid,),
                    known=[sid1])
    chk("★★ 第二条建出来了", new2 is not None and int(new2) != sid1, new2)
    sid2 = int(new2) if new2 is not None else sid1
    if new2 is not None:
        page.wait_for_timeout(2000)
        row2 = q("SELECT freq, day_of_month, hour, minute, next_at FROM lit_subs"
                 " WHERE id = ?", (sid2,))[0]
        chk("★★ 频率/号/时刻按表单存下去了（monthly / 31 号 / 21:30）",
            row2[0] == "monthly" and int(row2[1]) == 31 and
            int(row2[2]) == 21 and int(row2[3]) == 30, row2)
        # ★ dom=31 在小月必须顺延到当月最后一天 —— 纯函数的边界测试在
        #   selftest 里，这里只确认**界面上算出来的那个时刻**是真实存在的一天。
        import calendar
        import datetime
        try:
            d = datetime.datetime.strptime((row2[4] or "")[:10], "%Y-%m-%d")
            last = calendar.monthrange(d.year, d.month)[1]
            chk("★★★ 每月 31 号那条的下次运行落在**真实存在的一天**上（小月顺延）",
                d.day == 31 or d.day == last,
                "%s（当月最后一天 %d）" % (row2[4], last))
        except Exception as e:
            chk("★★★ 下次运行是个合法日期", False, "%r %s" % (row2[4], e))
    chk("★ 表格现在真的是两行（不是只在库里有两行）",
        page.locator("#lit-sub_table tbody tr").count() == 2,
        page.locator("#lit-sub_table tbody tr").count())
    shot(page, "08_sub_two")

    # ---- 7. 停用 → 启用（开关，回库确认） ---------------------------------
    chk("★ 能在「选中一条」里选中第一条", pick_sub(page, sid1))
    page.click("#lit-sub_off")
    chk("★★★ 「停用」之后库里 enabled=0（回库确认）",
        wait_val("SELECT enabled FROM lit_subs WHERE id = ? AND user_id = ?",
                 (sid1, uid), 0),
        q("SELECT enabled, next_at FROM lit_subs WHERE id = ? AND user_id = ?",
          (sid1, uid)))
    r = q("SELECT enabled, next_at FROM lit_subs WHERE id = ? AND user_id = ?",
          (sid1, uid))[0]
    chk("★★ 停用之后下次运行清空了（不然它还会被调度器捞走）",
        not (r[1] or "").strip(), r)
    page.wait_for_timeout(1500)
    chk("★★ 表格那一行跟着显示「（关着）」",
        "（关着）" in (out_text(page, "lit-sub_table") or ""),
        repr((out_text(page, "lit-sub_table") or "")[:250]))
    # ⚠️ 表格每次动作都会重画（subs_rev 变了），下拉也跟着重建 —— 第二次动作
    #    前必须**重新选一遍**，不能沿用上一次那个 selectize：重画之后它回到了
    #    第一项，点下去动的会是另一条订阅。
    chk("★ 重画之后还能选中第一条", pick_sub(page, sid1))
    page.click("#lit-sub_on")
    chk("★★★ 「启用」之后库里 enabled=1 而且**又算出了下次运行**",
        wait_val("SELECT enabled FROM lit_subs WHERE id = ? AND user_id = ?",
                 (sid1, uid), 1) and
        bool((q("SELECT next_at FROM lit_subs WHERE id = ?", (sid1,))[0][0] or "")
             .strip()),
        q("SELECT enabled, next_at FROM lit_subs WHERE id = ?", (sid1,)))
    shot(page, "09_sub_toggled")

    # ---- 8. 删除（回库确认那行真的没了） ----------------------------------
    chk("★ 选中第二条", pick_sub(page, sid2))
    page.click("#lit-sub_del")
    chk("★★★ 「删除」之后那一行**真的从库里没了**（不是只在表格里藏起来）",
        wait_gone("SELECT id FROM lit_subs WHERE id = ? AND user_id = ?", (sid2, uid)))
    chk("★★ 另一条**没被误删**（动作认的是选中那条，不是「全删」）",
        bool(q("SELECT id FROM lit_subs WHERE id = ? AND user_id = ?", (sid1, uid))))
    tbl = out_text(page, "lit-sub_table") or ""
    chk("★ 表格上只剩一行", "每月" not in tbl, repr(tbl[:200]))
    shot(page, "10_sub_deleted")

    # ---- 9. 权限：订阅是**按账号**的 --------------------------------------
    #
    # ★★ 这一条在浏览器里再验一次，因为它的坏法最贵：漏一个 `WHERE user_id = ?`
    #    就是"别人的关键词、别人的邮箱、别人的 token"。自检里两个"账号"是
    #    两个 list，验不出"另一个浏览器打开时看到了什么"。
    #
    # ⚠️ 判据要**能红**。第一版写的是 `chk(..., True, "别人的行数 = N")` ——
    #    一个恒真的断言，只是把数字打出来给人看。那不叫断言，叫注释。
    #    这里改成真的比：这个账号的行**恰好**是本轮造的那些，
    #    一条都不多（`user_id` 漏了的话，别人的行会混进来）。
    mine = ids_of("SELECT id FROM lit_subs WHERE user_id = ?", (uid,))
    chk("★★★ 这个账号名下的订阅**恰好**是本轮造的那一条（没有混进别人的行）",
        mine == {sid1}, "mine=%s sid1=%s" % (sorted(mine), sid1))
    # 反向：别的账号的行数在本次跑动里没有变过（这一条要两次采样，只有
    # 一个进程做不到；改成断"没有一行是 user_id 为空的" —— 那是漏了
    # WHERE 时最典型的中间态）。
    chk("★★ 没有一条订阅的 user_id 是空的",
        q("SELECT COUNT(*) FROM lit_subs WHERE user_id IS NULL")[0][0] == 0)


def main():
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1500, "height": 1000})
        page = ctx.new_page()

        C.enter_app(page, email=EMAIL, nickname="V152测试")
        uid, DB["path"] = C.seed_or_die(EMAIL)
        print("\n账号 id=%s  邮箱=%s" % (uid, EMAIL), flush=True)
        print("实例 %s   SMTP：%s   TZ=%s"
              % (C.APP, "配齐" if SMTP_ON else "**没配**", TZ), flush=True)

        if SMTP_ON:
            part_full(page, uid)
        else:
            part_degraded(page)
            print("\n\033[33m下一条：给 %s/.Renviron 加上四个**假**的 "
                  "DSAPP_SMTP_*（见本文件头上的写法），重启实例，再跑一遍 "
                  "—— 那一遍验的是卡片出现、勾选框能用、订阅增删改开关。\033[0m"
                  % C.APP, flush=True)

        shot(page, "99_final")
        browser.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
