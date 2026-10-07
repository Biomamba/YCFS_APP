# -*- coding: utf-8 -*-
"""V7 剩下三项的浏览器验证：item 1 跳转 / item 3 确认-更新按钮 / item 4 tokens 文案。

对着一次性实例（8898）跑。会真的注册账号、真的往库里插一个对话。
"""
import io
import os
import random
import sqlite3
import subprocess
import sys

from playwright.sync_api import sync_playwright

# ---- 路径与**防误伤闸门** -------------------------------------------------
#
# 三个脚本都会真的注册账号、真的往库里插数据、真的删。所以它们只能对着
# 一份**一次性的副本**跑，绝不能对着线上那份。
#
# 参数走环境变量，默认值就是本节文档里那套一次性实例：
#   DSAPP_TEST_URL  被测实例地址（默认 http://127.0.0.1:8898/）
#   DSAPP_TEST_APP  副本的**应用目录**（要有 R/ 和 .Renviron）
#   DSAPP_TEST_OUT  下载物与截图的落点
#
# ⚠️ 下面那道闸门不能删，它拦的是真实发生过的一类事故：副本放在 /tmp，
#    但副本的 .Renviron 里 `DSAPP_DATA_ROOT` 还指着线上的数据目录 ——
#    于是"跑个测试"就是在往线上库里插账号、插任务，再删掉几条。
#    副本是不是一次性的，**不由它在哪决定，由它的数据目录在哪决定**。
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v7test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v7")


def _guard(app):
    """确认这份副本指向的是一份临时数据；返回它的 DSAPP_DATA_ROOT。"""
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身（线上那份代码）。\n"
                 "  这些脚本会真的注册账号、真的插数据，请先拷一份到 /tmp 再跑。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。\n"
                 "  副本要带自己的 .Renviron（里面写 DSAPP_DATA_ROOT 等），\n"
                 "  否则它读的是继承来的环境变量，指到哪份数据只有天知道。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("DSAPP_DATA_ROOT="):
            root = ln.split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：%s 里没有 DSAPP_DATA_ROOT。" % envf)
    if not (root.startswith("/tmp/") or root.startswith("/var/tmp/")):
        sys.exit("拒绝运行：这份副本的 DSAPP_DATA_ROOT=%s 不在临时目录下。\n"
                 "  这个脚本会真的注册账号、插任务、删任务 —— 只能对着一次性数据跑。\n"
                 "  真要对着别处跑，请先确认那份数据可以被随便改。" % root)
    return root


DATA_ROOT = _guard(APP)
DB = os.path.join(DATA_ROOT, "dsapp.sqlite3")
WS = os.path.join(DATA_ROOT, "workspaces")
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


def rail(pg, title):
    pg.locator(".dsapp-rail-link", has_text=title).first.click()
    pg.wait_for_timeout(2000)


def active_nav(pg):
    return pg.evaluate(
        "() => { const a = document.querySelector('.dsapp-rail-link.active');"
        " return a ? a.getAttribute('data-nav') : null; }")


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 800})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v7r_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V7余项")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000002")
    pg.fill("#welcome-field", "宏基因组")
    pg.fill("#welcome-password", pw)
    # ★ 注册表单上那个「我已阅读并同意《用户须知》」必须勾上（V9 item 1）。
    #   服务端那句 `if (!isTRUE(input$tos_agree))` 才是判据，前端没有任何拦截 ——
    #   不勾就点，页面**停在原地**（而且表单不会被重建，填过的内容还在），
    #   看上去像"注册按钮没反应"。这三个脚本是 V7 写的，那会儿还没有这一条。
    cb = pg.locator("#welcome-tos_agree")
    if cb.count() and not cb.is_checked():
        cb.check()
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    # ★ 用户须知闸门（V9 item 1）：**注册之后**还有第二道 —— 新账号第一次
    #   进主界面之前要先在闸门页上勾一次同意。这和表单上那个勾选框不是同一处。
    #
    # ⚠️ 上面那两段（表单勾选框 + 这道闸门）都是 V13.6 回归时补的，补的是
    #    **测试的漏，不是产品的漏**：这三个脚本是 V7 写的，比 V9 那两道关卡
    #    早了整整两个大版本，从来没走过。少它们时的表现是"注册按钮像没反应 /
    #    一直停在闸门页"，而断言只报一句「注册进到主界面」失败 ——
    #    看着像代码被改崩了，其实是脚本从 V9 起就再没跑通过。
    #    （ui_v131 起各套 _common.py 里的 enter_app 早就有这两段。）
    for _ in range(60):
        pg.wait_for_timeout(1000)
        if pg.locator(".dsapp-shell").count():
            break
        if pg.locator("#tos_gate-do_agree").count():
            c = pg.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            pg.click("#tos_gate-do_agree")
            pg.wait_for_timeout(3000)
    chk("注册进到主界面", pg.locator(".dsapp-shell").count() > 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    # =====================================================================
    print("\n== item 3：模型服务填好了要有确认按钮，有 Key 之后变「更新」 ==")
    # =====================================================================
    # 用户的原话：「模型服务处填好了要有确认按钮，填好了有 key 可以使用时，
    # 确认按钮需要变成更新按钮」。判据是**按钮上的字**，不是"有个按钮"——
    # 一个永远写着"确认"的按钮等于没做这一条。
    # ⚠️ 一律用 text_content() 读按钮上的字，不用 inner_text()。
    #    inner_text() 返回的是**渲染后**的文本，而 item 8 让这一格在存好
    #    Key 之后自动收起 —— 收起的 <details> 里元素不可见，inner_text()
    #    返回空串。用它断言"按钮上写的是更新"会得到一条**假红**：
    #    功能是好的，测试说它坏了。（第一版就是这么误报的。）
    btn = pg.locator(".dsapp-rail-model #model-commit")
    chk("模型服务里有确认按钮", btn.count() == 1)
    lbl0 = (btn.text_content() or "").strip() if btn.count() else ""
    chk("★ 还没配过 Key → 按钮写的是「确认」", lbl0 == "确认", lbl0)
    hint0 = pg.locator(".dsapp-rail-model #model-commit_hint").text_content() or ""
    chk("★ 未配 Key 时旁边就说了「生成用不了」（不点下去就不该以为能用）",
        "还没填" in hint0, hint0.strip())

    pg.fill(".dsapp-rail-model #model-api_key", "sk-fake-for-v7rest")
    pg.wait_for_timeout(3000)          # 自动保存（debounce 800ms）+ 重查库
    pg.click(".dsapp-rail-model #model-commit")
    pg.wait_for_timeout(4000)
    # item 8 让面板保存后自动收起，收着也能读到按钮上的字（DOM 还在）
    lbl1 = (btn.text_content() or "").strip()
    hint1 = pg.locator(".dsapp-rail-model #model-commit_hint").text_content() or ""
    chk("★★ 存下 Key 之后按钮变成「更新」（item 3 的正题）", lbl1 == "更新", lbl1)
    chk("★★ 存下之后旁边写的是「已保存，可直接用」", "已保存" in hint1, hint1.strip())
    chk("★ 按钮还是那一个（没有换 id 重建，旧引用不会指空）",
        pg.locator(".dsapp-rail-model #model-commit").count() == 1)
    # 刷新一次再看：按钮文字来自**库**，不是内存里的标记位
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_timeout(4000)
    lbl2 = (pg.locator(".dsapp-rail-model #model-commit").text_content() or "").strip()
    chk("★★ 刷新页面后仍然是「更新」（文字真的落库了，不是内存里的假象）",
        lbl2 == "更新", lbl2)

    # =====================================================================
    print("\n== item 4：运行提示里的「字」换成 token ==")
    # =====================================================================
    # 用户的原话：「运行提示中的"字"，是不是 token 的意思，如果是，请替换回去」。
    # 这里查的是**代码里那些会出现在运行提示上的文案**，不是随便一个"字"字——
    # 界面上仍然有正当的"字"（昵称 40 字以内、正文只有 N 个字），那说的是
    # 字符数，改掉反而是错的。所以判据落在**用量**和**长度上限**两处。
    lab = pg.locator(".dsapp-rail-model label[for='model-max_tokens']").text_content() or ""
    chk("★ 生成参数里的长度上限写的是 tokens",
        "tokens" in lab and "字" not in lab, lab.strip())
    usage = subprocess.run(
        ["Rscript", "-e",
         'for (f in list.files("R", pattern="[.]R$", full.names=TRUE)) source(f);'
         ' cat(dsapp_usage_text(list(prompt_tokens=1200, completion_tokens=340)), "\\n");'
         ' cat(dsapp_usage_text(list(total_tokens=1540)), "\\n")'],
        capture_output=True, cwd=APP)
    u = usage.stdout.decode().strip()
    chk("★★ 用量文案是「本次消耗 N tokens」（不是 N 个字）",
        usage.returncode == 0 and "tokens" in u and "字" not in u,
        u or usage.stderr.decode()[-300:])
    chk("★ 厂商只给总数时也能显示（不是只在给了明细时才显示）",
        u.count("tokens") == 2, u)

    # =====================================================================
    print("\n== item 1：对话页「在「文件」页看全部」要能跳过去 ==")
    # =====================================================================
    # 用户的原话：「言出法随页面的"在[文件]页查看全部"，无法正常跳转」。
    # 页面上有两个跳转入口：产物卡片右上角的"管理 →"，以及文件多于 8 个时
    # 那句"……还有 N 个，在「文件」页看全部"。**出问题的是后面那句** ——
    # 它原来是一段纯文本，而文案本身在指路，用户就会去点，点不动。
    # 所以这里必须铺到 9 个以上文件才能把那一行走出来。
    r = subprocess.run(["Rscript", "-e", """
for (f in list.files("R", pattern = "[.]R$", full.names = TRUE)) source(f)
cfg <- dsapp_config(); dsapp_init_dirs(cfg)
con <- dsapp_db(cfg)
u <- DBI::dbGetQuery(con, "SELECT id FROM users WHERE email = '%s'")$id[[1]]
sid <- dsapp_id("s")
DBI::dbExecute(con, "INSERT INTO sessions (id, user_id, title, created_at, updated_at)
                     VALUES (?, ?, 'V7 余项测试', datetime('now'), datetime('now'))",
               params = list(sid, as.integer(u)))
d <- dsapp_ws_dir(sid, cfg)
for (i in 1:12) {
  writeLines(c("gene,log2fc", sprintf("G%%02d,%%s", i, i / 10)),
             file.path(d, sprintf("v7r_%%02d.csv", i)))
}
cat(sid, "\\n")
""" % email], capture_output=True, cwd=APP)
    seeded = r.stdout.decode().strip().split("\n")[-1] if r.returncode == 0 else ""
    chk("播数据成功（1 个对话 + 12 个工作区文件）", r.returncode == 0 and
        seeded.startswith("s-"), r.stderr.decode()[-400:])

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_timeout(4000)
    rail(pg, "言出法随")
    pg.wait_for_timeout(3500)

    card = pg.locator(".dsapp-artifacts").first
    chk("本对话产物卡片在", card.count() == 1)
    chk("★ 12 个文件 → 只列 8 个（对话流里不铺开）",
        card.locator(".dsapp-file-link").count() >= 8,
        card.locator(".dsapp-file-link").count())
    txt = card.inner_text()
    chk("★ 剩下 4 个有交代（不声不响吞掉 4 个文件最糟）", "还有 4 个" in txt,
        [t for t in txt.split("\n") if "还有" in t][:2])

    # ★★ 正题：那句话里得有一个**真的 <a>**，点了能到文件页
    seeall = card.locator("a", has_text="在「文件」页看全部")
    chk("★★ 「在「文件」页看全部」是个链接，不是一句死文本（item 1 的病根）",
        seeall.count() >= 1, seeall.count())
    # ★ 两个跳转入口**必须各自有 id**。共用 id 的后果实测过：actionLink
    #   的点击计数是各记各的，两个 <a> 都从 0 起步，第二个链接第一次点击
    #   发出的值和第一个已经发过的值相同，Shiny 判"没变"就不派发 ——
    #   点了没反应。而且重复 id 本身就是非法 HTML，querySelector 只认第一个。
    dup = pg.evaluate("""() => { const m = {};
        document.querySelectorAll('[id]').forEach(e => m[e.id] = (m[e.id] || 0) + 1);
        return Object.entries(m).filter(([k, v]) => v > 1).map(([k]) => k); }""")
    chk("★ 页面上没有重复的 DOM id（重复 id 会让其中一个永远点不动）",
        not dup, dup)

    if seeall.count():
        # 先点右上角那个，再点这句 —— **顺序是故意的**：共用 id 的 bug
        # 只在"后点的那个"上现形，只测一个顺序会漏掉一半。
        mgr0 = card.locator("a", has_text="管理")
        chk("★ 跳转前不在文件页", active_nav(pg) == "chat", active_nav(pg))
        if mgr0.count():
            mgr0.first.click()
            pg.wait_for_timeout(3000)
            chk("★★ 右上角「管理 →」能跳到文件页",
                active_nav(pg) == "files", active_nav(pg))
            rail(pg, "言出法随")
            pg.wait_for_timeout(3000)
        seeall = pg.locator(".dsapp-artifacts a", has_text="在「文件」页看全部")
        seeall.first.click()
        pg.wait_for_timeout(3000)
        chk("★★ 先点过「管理 →」之后，「看全部」仍然能跳（两个入口互不顶掉）",
            active_nav(pg) == "files", active_nav(pg))
        chk("★★ 到了文件页，表真的在那儿（不是空壳页面）",
            pg.locator("#files-tbl").count() == 1)

    chk("没有 JS 运行时错误", not errs, " | ".join(errs[:3]))
    pg.screenshot(path=os.path.join(OUT, "rest.png"), full_page=True)
    b.close()

print("\n" + ("全部通过" if ok_all else "有失败项"), flush=True)
sys.exit(0 if ok_all else 1)
