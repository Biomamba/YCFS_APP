# -*- coding: utf-8 -*-
"""V16.5 item 3 + 4：系统提示词编辑器能**新增分类**，而且加了就生效；
   「科研绘图」是内置的一节，正文来自 skills_builtin 下那份 .md。

用户原话（2026-10-05）：
    3、「系统提示词需要能新增分类」
    4、「按照科研绘图Agent通用提示词_清晰美观规范.md新增系统提示词」

★★ 为什么必须有浏览器探针：
  · item 3 的用户动作是"点一颗按钮、填个名字、它就出现在左栏、下一句话
    就带上它" —— 这四步里有三步是**界面**（按钮在不在、弹窗长什么样、新
    加的那一行有没有出现、右栏有没有跳过去），selftest 一条都量不到。
  · item 4 要的是"模型收到的提示词里有这一节"。selftest 量的是
    `build_system_prompt()` 的返回值 —— 而**管理员看到的那一页**是另一个
    入口（`output$pp_full` 自己调一次）。两边分家过一次就是 V15.4 的
    "改了没反应"。

⚠️ 本探针**不**重复 tests/ui_v154/probe_v154.py 里 item8_prompt 钉过的东西
   （改内置节、只读节、占位符填没填、choices 的方向）。那是 V15.4 的冻结
   记录，重合的部分再钉一遍只会让两份记录互相牵着，改一处红两处。
   这里只管 V16.5 多出来的那一层：**自定义分类**。

⚠️ 每条写操作后面都**回库确认**一次（本仓老账：限流/必填的拒绝长得像界面
   坏了 —— 页面上"没画出来"和库里"没写进去"必须在报告里分得开）。

跑法：
    bash tests/ui_v7/make_instance.sh 8974 /tmp/dsapp_v165a
    python3 tests/ui_v165/probe_prompt.py            # 退出码 0 = 全绿
"""
import io
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
TAG = C.TAG
MARK = "★V165标记-%s★" % TAG
LAB = "哨兵分类-%s" % TAG
MD_REL = "skills_builtin/科研绘图Agent通用提示词_清晰美观规范.md"


# ---------------------------------------------------------------------------
# 库 / 登录
# ---------------------------------------------------------------------------
def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def exec_sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def relogin(pg, email):
    """reload 之后把自己弄回主界面。

    ★ 必须 reload：`users.admin_scope` 是 app.R 在**渲染那一刻**算的
      （`dsapp_user_admin_scope(user)`），老会话里还是旧身份 —— 不 reload
      的话后台管理那一页压根不会出现，后面的失败会指向"提示词编辑器没了"。

    ⚠️⚠️ 这里**不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload
      时 cookie 还在 —— 应用直接进主界面，登录页一帧都不出现。拿它等 =
      等一个永远不会来的东西（fake-wait-is-not-a-wait 的又一个形状）。
    """
    pg.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if pg.locator(".dsapp-shell").count():
            return True
        if not submitted and pg.locator("#welcome-email").count():
            pg.fill("#welcome-email", email)
            pg.fill("#welcome-password", C.PW)
            pg.click("#welcome-do_login")
            submitted = True
        pg.wait_for_timeout(1000)
    pg.screenshot(path=OUT + "/01_relogin_failed.png", full_page=True)
    return False


def open_prompt_tab(pg):
    """切到「后台管理 → 提示词」那一格。"""
    C.goto(pg, "admin")
    pg.wait_for_timeout(1200)
    pg.evaluate("""() => {
        var ul = document.getElementById('admin-bs_tab');
        if (!ul) return;
        var a = ul.querySelector('a[data-value="prompt"],' +
                                 'button[data-value="prompt"]');
        if (a) a.click();
    }""")
    pg.wait_for_timeout(1800)


def options(pg):
    return pg.evaluate("""() => [].slice.call(
        document.querySelectorAll('#prompt-pp_part option')).map(function (o) {
            return {v: o.value, t: (o.textContent || '').trim()}; })""")


def norm(s):
    """比字符串之前把空白全去掉。

    ⚠️ 拼出来的全文是 `<pre>` 里的一整段，innerText 里的换行/缩进和正文
      不一定逐字节一样；用"整段 substring"去比会因为一个换行而假红。
      这里比的是**内容**，不是排版。
    """
    return re.sub(r"\s+", "", s or "")


def full_text(pg):
    if pg.locator("#prompt-pp_full").count() == 0:
        return ""
    return pg.inner_text("#prompt-pp_full")


def body_val(pg):
    if pg.locator("#prompt-pp_body").count() == 0:
        return None
    return pg.input_value("#prompt-pp_body")


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()
        ck = C.Chk()
        try:
            email = C.enter_app(pg)
            uid, db = C.seed_or_die(email)
            C.ensure_no_modal(pg)

            # =============================================================
            print("\n=== ⓪ 夹具是干净的（这一轮新造的），而且是这一版的实例 ===",
                  flush=True)
            # =============================================================
            foot = pg.evaluate(
                "() => ((document.body.innerText.match(/Test_V[0-9.]+/) "
                "|| [])[0]) || ''")
            ck("⓪ 页脚写的是 Test_V16.5（连错实例的话这一条先响）",
               foot == "Test_V16.5", "页脚是 %r" % foot)

            exec_sql(db, "UPDATE users SET is_admin = 1, admin_scope = 'platform'"
                         " WHERE id = ?", (uid,))
            ck("⓪ 把自己提成平台管理员之后重新登一次（身份是渲染那一刻算的）",
               relogin(pg, email))
            C.ensure_no_modal(pg)
            open_prompt_tab(pg)

            n_cu = sql(db, "SELECT COUNT(*) FROM prompt_custom")[0][0]
            n_ov = sql(db, "SELECT COUNT(*) FROM prompt_overrides")[0][0]
            ck("★ ⓪ 前提：这一轮开始前 prompt_custom / prompt_overrides 都是空的",
               n_cu == 0 and n_ov == 0,
               "custom=%d overrides=%d（残留的话下面那些数字全都不可信）"
               % (n_cu, n_ov))

            # =============================================================
            print("\n=== ① 左栏：内置 12 节 + 自己加的那 0 节 ===", flush=True)
            # =============================================================
            opts = options(pg)
            print("    左栏：%s" % [o["t"] for o in opts], flush=True)
            ck("① 左栏列了 12 节（V16.5 把「科研绘图」加了进来）",
               len(opts) == 12, "%d 节：%s" % (len(opts), [o["t"] for o in opts]))
            ck("① 其中有一节叫「科研绘图」",
               any("科研绘图" in o["t"] for o in opts),
               [o["t"] for o in opts])
            ck("① 此刻一节自定义分类都没有（它们排在最后，前缀是「自定义 · 」）",
               not any(o["t"].startswith("自定义") for o in opts),
               [o["t"] for o in opts])
            ck("① 值还是常量名（点哪一节就是哪一节）",
               all(re.match(r"^DSPROMPT_[A-Z_]+$", o["v"] or "") for o in opts),
               [o["v"] for o in opts])

            # =============================================================
            print("\n=== ② item 4：科研绘图那一节真的就是那份 .md ===", flush=True)
            # =============================================================
            md = os.path.join(C.APP, MD_REL)
            ck("② （前置）那份 .md 在实例目录里找得到", os.path.exists(md), md)
            lines = []
            if os.path.exists(md):
                with io.open(md, encoding="utf-8") as fh:
                    lines = [l for l in fh.read().splitlines() if l.strip()]
            ck("② （前置）那份 .md 不是空的", len(lines) > 20, "%d 行" % len(lines))

            pg.select_option("#prompt-pp_part", "DSPROMPT_PLOTTING")
            pg.wait_for_timeout(1500)
            body = body_val(pg)
            ck("② ★ 选中它，右栏**有编辑器**（不是只读的那两节）",
               body is not None, "没有 #prompt-pp_body")
            ck("② ★ 正文不是空的（>1000 字：那一节是整份 .md 嵌进来的）",
               body is not None and len(body) > 1000,
               "%d 字" % (len(body) if body else -1))
            if lines and body:
                ck("② ★★ 那份 .md 的**第一行**在正文里（逐字）",
                   norm(lines[0]) in norm(body), "第一行是 %r" % lines[0][:60])
                ck("② ★★ 那份 .md 的**最后一行**也在（说明是整份嵌进来的，"
                   "不是只抄了个标题）",
                   norm(lines[-1]) in norm(body), "最后一行是 %r" % lines[-1][:60])
            ck("② 正文里写着它是**这一轮要出图**才用的规范（不是每轮都念一遍）",
               body is not None and "只要这一轮要出图" in body,
               (body or "")[:80])

            ft = norm(full_text(pg))
            ck("② ★★ 下面那格「拼装后的全文」里也有它（= 模型真的会收到）",
               norm(lines[0]) in ft if lines else False,
               "全文 %d 字" % len(ft))

            # 切到「自动执行」那一档再看一次：两个场景都得有
            sc = pg.locator("#prompt-pp_scene input[value='agent']")
            ck("② （前置）找得到「自动执行」那个场景开关", sc.count() > 0)
            if sc.count():
                sc.first.check()
                pg.wait_for_timeout(2000)
                ft2 = norm(full_text(pg))
                ck("② ★ 切到「自动执行」场景，全文里**也**有这一节"
                   "（两个场景都注入）",
                   (norm(lines[0]) in ft2) if lines else False,
                   "全文 %d 字" % len(ft2))
                pg.locator("#prompt-pp_scene input[value='chat']").first.check()
                pg.wait_for_timeout(1500)

            # =============================================================
            print("\n=== ③ item 3：新增分类（空名字不许加）===", flush=True)
            # =============================================================
            ck("③ （前置）左栏底下那颗「新增分类」在",
               pg.locator("#prompt-pp_add").count() == 1)
            pg.click("#prompt-pp_add")
            pg.wait_for_timeout(1200)
            ck("③ 点开之后弹出了「新增分类」（有名字 + 正文两个框）",
               pg.locator("#prompt-pp_new_label").count() == 1 and
               pg.locator("#prompt-pp_new_body").count() == 1,
               "label=%d body=%d" % (pg.locator("#prompt-pp_new_label").count(),
                                     pg.locator("#prompt-pp_new_body").count()))
            # 名字留空也要给正文：这条兼验"报错之后正文不丢"
            if pg.locator("#prompt-pp_new_body").count():
                pg.fill("#prompt-pp_new_body", MARK + " 空名字这一轮")
            pg.click("#prompt-pp_confirm_add")
            pg.wait_for_timeout(1500)
            still_open = pg.locator("#prompt-pp_new_label").count() == 1
            modal_txt = pg.evaluate(
                "() => (document.querySelector('#shiny-modal')||{}).innerText "
                "|| ''")
            ck("③ ★ 名字空着点「新增」：**弹窗还在**（不是静静地什么都不发生）",
               still_open, "弹窗文本：%r" % modal_txt[:160])
            ck("③ ★ 而且弹窗里**说出了理由**（不报错的话用户以为按钮坏了）",
               "分类名不能是空的" in modal_txt, repr(modal_txt[:200]))
            ck("③ ★ 已经敲进去的正文还在（报一次错要重写一遍的话没人受得了）",
               MARK in (pg.input_value("#prompt-pp_new_body")
                        if pg.locator("#prompt-pp_new_body").count() else ""),
               "正文被清掉了")
            ck("③ ★ 回库确认：**一行都没有写进去**",
               sql(db, "SELECT COUNT(*) FROM prompt_custom")[0][0] == 0)
            # ⚠️ 这个弹窗**故意不关**：④ 就在它上面接着填名字、再点一次「新增」。
            #    「报错之后原地重来」正是用户真正会走的那条路（他要先看见
            #    "名字不能空"，再补上名字），另开一次弹窗反而绕过了这一段。

            # =============================================================
            print("\n=== ④ item 3：正经加一节 → 左栏出现、右栏跳过去、"
                  "全文里立刻就有 ===", flush=True)
            # =============================================================
            pg.fill("#prompt-pp_new_label", LAB)
            pg.fill("#prompt-pp_new_body", MARK + " 这一节是探针加的。")
            pg.click("#prompt-pp_confirm_add")
            pg.wait_for_timeout(2500)

            rows = sql(db, "SELECT key, label, body FROM prompt_custom")
            print("    prompt_custom：%s" % rows, flush=True)
            ck("④ ★★ 回库确认：写进去了一行", len(rows) == 1, rows)
            ck("④ ★★ key 是 DSPROMPT_CUSTOM_<n>，正文一字不差",
               len(rows) == 1 and re.match(r"^DSPROMPT_CUSTOM_\d+$", rows[0][0])
               and rows[0][1] == LAB and MARK in rows[0][2], rows)
            key = rows[0][0] if rows else None

            opts = options(pg)
            mine = [o for o in opts if (o["v"] or "") == key]
            ck("④ ★★ 左栏**当场**多出一行（值就是刚生成的那个 key）",
               len(mine) == 1, "左栏现在：%s" % [o["t"] for o in opts])
            ck("④ ★ 那一行显示的是「自定义 · 分类名」（不是常量名，也不是空行）",
               bool(mine) and mine[0]["t"] == "自定义 · " + LAB,
               mine[0]["t"] if mine else None)
            ck("④ ★ 内置那 12 节一节不少（加的是加，不是替换）",
               sum(1 for o in opts if not o["t"].startswith("自定义")) == 12,
               [o["t"] for o in opts])
            ck("④ ★ 右栏**自动跳到**刚加的这一节（正文就是我们刚写的那句）",
               (body_val(pg) or "").startswith(MARK),
               (body_val(pg) or "")[:80])
            ft = norm(full_text(pg))
            ck("④ ★★★ 下面那格全文里**立刻**出现了这一节（「加了就生效」）",
               norm(MARK) in ft, "全文 %d 字，含标记=%s" % (len(ft), MARK in ft))
            badge = pg.inner_text("#prompt-pp_badge")
            ck("④ ★ 卡头徽标把两个数分开报（这里只该有自定义那一个数）",
               "自定义分类 1 个" in badge and "已改内置" not in badge,
               repr(badge))

            # =============================================================
            print("\n=== ⑤ item 3：改名 + 改正文 → 保存（key 不变、正文跟着变）===",
                  flush=True)
            # =============================================================
            pg.fill("#prompt-pp_label", LAB + "改")
            pg.fill("#prompt-pp_body", MARK + " 改过的正文。")
            pg.click("#prompt-pp_save")
            pg.wait_for_timeout(2200)
            rows = sql(db, "SELECT key, label, body FROM prompt_custom")
            ck("⑤ ★★ 回库确认：还是**同一行**（改名不换 key、不新加一行）",
               len(rows) == 1 and rows[0][0] == key, rows)
            ck("⑤ ★★ 分类名和正文都更新了",
               len(rows) == 1 and rows[0][1] == LAB + "改"
               and "改过的正文" in rows[0][2], rows)
            opts = options(pg)
            ck("⑤ ★ 左栏那一行跟着改了名字",
               any(o["t"] == "自定义 · " + LAB + "改" for o in opts),
               [o["t"] for o in opts])
            ft = norm(full_text(pg))
            ck("⑤ ★ 全文里是**新**正文（旧的那句已经不在）",
               norm("改过的正文") in ft, "全文 %d 字" % len(ft))

            # =============================================================
            print("\n=== ⑥ item 3：删掉这一节（删完页面和库都回到原样）===",
                  flush=True)
            # =============================================================
            ck("⑥ （前置）此刻右栏停在这一节上（不然删的是别人）",
               pg.locator("#prompt-pp_del").count() == 1)
            pg.click("#prompt-pp_del")
            pg.wait_for_timeout(1200)
            mtxt = pg.evaluate(
                "() => (document.querySelector('#shiny-modal')||{}).innerText "
                "|| ''")
            ck("⑥ ★ 先弹一次确认，而且说清楚「删掉就没有了」",
               "没有内置默认可以回退" in mtxt, repr(mtxt[:200]))
            pg.click("#prompt-pp_confirm_del")
            pg.wait_for_timeout(2200)

            ck("⑥ ★★ 回库确认：那一行真的没了",
               sql(db, "SELECT COUNT(*) FROM prompt_custom")[0][0] == 0,
               sql(db, "SELECT key, label FROM prompt_custom"))
            opts = options(pg)
            ck("⑥ ★★ 左栏回到 12 节，自定义那一行不见了",
               len(opts) == 12 and not any(o["t"].startswith("自定义")
                                           for o in opts),
               "%d 节：%s" % (len(opts), [o["t"] for o in opts]))
            ft = norm(full_text(pg))
            ck("⑥ ★★ 全文里也没有了（删了就不发）",
               norm(MARK) not in ft, "全文 %d 字" % len(ft))
            ck("⑥ ★ 右栏跳回了第一节（删掉的正是它，不改的话右栏还停在"
               "一个不存在的 key 上）",
               (body_val(pg) or "") != "" and
               norm(MARK) not in norm(body_val(pg) or ""),
               (body_val(pg) or "")[:60])

            # =============================================================
            print("\n=== ⑦ 收尾：别把夹具弄脏（下一份探针还要用它）===", flush=True)
            # =============================================================
            ck("⑦ 两张表都回到 0 行",
               sql(db, "SELECT COUNT(*) FROM prompt_custom")[0][0] == 0 and
               sql(db, "SELECT COUNT(*) FROM prompt_overrides")[0][0] == 0,
               "custom=%s overrides=%s"
               % (sql(db, "SELECT COUNT(*) FROM prompt_custom")[0][0],
                  sql(db, "SELECT COUNT(*) FROM prompt_overrides")[0][0]))

        finally:
            ss = os.path.join(OUT, "probe_prompt_%s.png" % time.strftime("%H%M%S"))
            try:
                pg.screenshot(path=ss, full_page=True)
                print("  （整页截图 %s）" % ss, flush=True)
            except Exception:
                pass
            br.close()
        sys.exit(ck.done())


main()
