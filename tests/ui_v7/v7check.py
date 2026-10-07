# -*- coding: utf-8 -*-
"""V7 三项改动的浏览器验证：item 8 折叠 / item 6 多选删除 / item 2 预览。

对着一次性实例（8898）跑。会真的注册账号、真的插任务、真的删。
"""
import io
import os
import random
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
    pg.wait_for_timeout(2500)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 800})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v7_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    # 库里已经有账号时入口页是**登录页**（mod_welcome.R:233），得先切到注册
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V7测试")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000001")
    pg.fill("#welcome-field", "单细胞转录组")
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
    print("\n== item 8：模型服务不用时收起 ==")
    # =====================================================================
    d = pg.locator("details.dsapp-rail-model")
    chk("模型服务那一格是 <details>（不是 <div>）", d.count() == 1)
    chk("summary 上写了当前状态", d.locator("summary").count() >= 1,
        d.inner_text()[:80] if d.count() else "")
    # ⚠️ .first 一直留着。原来是因为这一格里面**还嵌着**一个 <details>
    #    （生成参数那一块），裸的 summary 会同时命中外层的和内层那个
    #    （strict mode 直接报错）。V13.6 item 2 把内层那个去掉了
    #    （用户原话：「生成参数不要折叠」），现在这一格只有外层一个 ——
    #    .first 就成了"以后再加嵌套也不会误命中"的保险，不用改。
    summ = d.locator("summary").first.inner_text() if d.count() else ""
    chk("★ 一次都没配过 → 默认**展开**（收起来的话没人告诉他得填 Key）",
        d.count() == 1 and d.evaluate("e => e.open") is True, summ)
    chk("★ 未配置时摘要行写的是「未配置」", "未配置" in summ, summ)
    chk("★ summary 没有原生三角（list-style 已去掉）",
        pg.evaluate("""() => {
          const s = document.querySelector('details.dsapp-rail-model > summary');
          if (!s) return 'nope';
          return getComputedStyle(s).listStyleType;
        }""") in ("none", ""))
    chk("★ 收起时不再 flex:1 撑满（否则是一大片空白，看着像坏了）",
        pg.evaluate("""() => {
          const e = document.querySelector('details.dsapp-rail-model');
          e.open = false;
          const g = getComputedStyle(e).flexGrow;
          e.open = true;
          return g;
        }""") == "0")
    # 保存一把 Key（假的不验），看会不会自动收起
    pg.fill(".dsapp-rail-model #model-api_key", "sk-fake-for-layout-test")
    pg.click(".dsapp-rail-model #model-commit")
    pg.wait_for_timeout(3500)
    chk("★★ 保存成功后模型服务自动收起（item 8 的正题）",
        pg.evaluate("""() => {
          const e = document.querySelector('details.dsapp-rail-model');
          return e ? e.open : 'nope';
        }""") is False)
    d = pg.locator("details.dsapp-rail-model")
    summ2 = d.locator("summary").first.inner_text() if d.count() else ""
    chk("★★ 收起后摘要行一眼能看出在用哪个模型（收起来不等于信息丢失）",
        "未配置" not in summ2 and len(summ2.strip()) > 3, summ2)
    chk("★★ 手动点开还能点开（收起不是单向的）", (
        d.locator("summary").first.click(), pg.wait_for_timeout(600))[1] is None and
        d.evaluate("e => e.open") is True)
    d.locator("summary").first.click()
    pg.wait_for_timeout(400)

    # =====================================================================
    print("\n== item 6：任务页多选 + 删除 ==")
    # =====================================================================
    # 先在库里塞几条任务（走应用自己的建库逻辑，别手写 INSERT）
    # ⚠️ source 全部 R/*.R，不要手写清单 —— dsapp_db() 会一路调到
    #    dsapp_db_schema_users()（在 users.R 里），漏一个就是
    #    "could not find function"，而且报错看起来像应用坏了。
    # ⚠️ sessions.updated_at 是 NOT NULL，别只写 created_at。
    # ⚠️ 别用 capture_output=True 把错误吞掉 —— 这一块失败过一次，
    #    表现是后面所有断言一起挂，而真正的原因一个字都没打出来。
    r = subprocess.run(["Rscript", "-e", """
for (f in list.files("R", pattern = "[.]R$", full.names = TRUE)) source(f)
cfg <- dsapp_config(); dsapp_init_dirs(cfg)
con <- dsapp_db(cfg)
u <- DBI::dbGetQuery(con, "SELECT id FROM users WHERE email = '%s'")$id[[1]]
sid <- dsapp_id("s")
DBI::dbExecute(con, "INSERT INTO sessions (id, user_id, title, created_at, updated_at)
                     VALUES (?, ?, 'V7 测试对话', datetime('now'), datetime('now'))",
               params = list(sid, as.integer(u)))
for (i in 1:5) {
  DBI::dbExecute(con, paste("INSERT INTO tasks",
    "(session_id, title, lang, code, status, exit_code, created_at)",
    "VALUES (?, ?, 'R', 'print(1)', ?, 0, datetime('now'))"),
    params = list(sid, paste("测试任务", i),
                  c("success","failed","success","timeout","success")[i]))
}
# 工作区产物 —— item 2 的预览要用它
d <- dsapp_ws_dir(sid, cfg)
writeLines(c("gene,log2fc", "TP53,2.1", "MYC,-1.4"),
           file.path(d, "v7_preview.csv"))
cat(sid, "\\n")
""" % email], capture_output=True, cwd=APP)
    seeded = r.stdout.decode().strip().split("\n")[-1] if r.returncode == 0 else ""
    chk("播数据成功（对话 + 5 条任务 + 1 个工作区产物）", r.returncode == 0 and
        seeded.startswith("s-"), r.stderr.decode()[-400:])

    # 重新载入让任务页拿到新数据
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_timeout(3000)

    # =====================================================================
    print("\n== item 2：点文件名先预览，再由下载按钮决定要不要下 ==")
    # =====================================================================
    # 用户的原话：「点击言出法随页面的文件名，可以先跳转预览，再有下载按钮
    # 决定要不要下载」。这条和文件页那套 downloadButton 是同一个模式
    # （art_dl / art_dl2 也靠 suspendWhenHidden = FALSE + clickWhenReady），
    # 所以文件页那个 href 永远是空的 bug 这里同样中招过，必须一起回归。
    rail(pg, "言出法随")
    pg.wait_for_timeout(3000)
    url_before = pg.url
    link = pg.locator("a.dsapp-file-link", has_text="v7_preview.csv")
    chk("★ 本对话产物里，文件名是个链接", link.count() >= 1, link.count())
    if link.count():
        link.first.click()
        pg.wait_for_timeout(2500)
        chk("★★ 点文件名弹出预览弹窗（没有直接下载、也没有跳走）",
            pg.locator(".modal-content").count() > 0 and pg.url == url_before,
            "modal=%d url_same=%s" % (pg.locator(".modal-content").count(),
                                      pg.url == url_before))
        chk("★ 弹窗标题就是那个文件名",
            "v7_preview.csv" in pg.inner_text(".modal-title"),
            pg.inner_text(".modal-title") if pg.locator(".modal-title").count() else "")
        # ⚠️ 先确认 href 有值再点 —— 空 href 的 <a> 会导航到当前页，
        #    表现为"下载下来一个 HTML"（文件页那个 bug 的同款症状）。
        chk("★★ 弹窗里的下载按钮 href 已就绪（不是空串）",
            (pg.locator("#chat-art_dl2").get_attribute("href") or "") != "",
            pg.locator("#chat-art_dl2").get_attribute("href"))
        dl = os.path.join(OUT, "preview.csv")
        with pg.expect_download(timeout=45000) as info:
            pg.locator("#chat-art_dl2").click()
        info.value.save_as(dl)
        got = open(dl, encoding="utf-8").read()
        chk("★★ 弹窗里下到的就是刚预览的那个文件（不是 HTML、不是空文件）",
            "TP53" in got and "log2fc" in got, got[:80])
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(800)

    rail(pg, "任务")
    pg.wait_for_timeout(1500)

    # ---- 回到任务页 ----
    tbl = pg.locator("#tasks-tbl")
    chk("任务表在", tbl.count() == 1)
    pg.wait_for_timeout(1200)
    chk("★ 每行最左边有复选框列（.select-checkbox）",
        pg.locator("#tasks-tbl td.select-checkbox").count() >= 5,
        pg.locator("#tasks-tbl td.select-checkbox").count())
    # ⚠️ 断言真的 <input>，不是 `th.select-checkbox` 这个**类名** ——
    #    Select 1.7.0 会给表头加类名但不放任何控件，光看类名恒真（假绿）。
    chk("★ 表头有一个**真的**全选方框（不是只有类名）",
        pg.locator("#tasks-tbl th.select-checkbox input.dsapp-selall").count() == 1,
        pg.locator("#tasks-tbl th.select-checkbox").first.evaluate("e => e.outerHTML")[:120])
    chk("★ 勾选前删除按钮写的是「删除选中」",
        "删除选中" in pg.locator("#tasks-delete").inner_text(),
        pg.locator("#tasks-delete").inner_text())

    # 勾两条
    pg.locator("#tasks-tbl td.select-checkbox").nth(0).click()
    pg.wait_for_timeout(700)
    pg.locator("#tasks-tbl td.select-checkbox").nth(1).click()
    pg.wait_for_timeout(1200)
    chk("★★ 勾两条 → 按钮上带出条数（说明 rows_selected 真的喂上来了）",
        "2" in pg.locator("#tasks-delete").inner_text(),
        pg.locator("#tasks-delete").inner_text())
    chk("★★ 勾选状态有文字提示（不说的话用户不知道重跑的是哪一条）",
        "已勾选 2 条" in pg.inner_text("body"),
        [t for t in pg.inner_text("body").split("\n") if "勾选" in t][:3])

    # 点删除 → 弹窗里应该写 2 条
    pg.click("#tasks-delete")
    pg.wait_for_timeout(1200)
    mtxt = pg.inner_text(".modal-content") if pg.locator(".modal-content").count() else ""
    chk("★★ 确认弹窗说的是 2 条", "2 条" in mtxt, mtxt.replace("\n", " ")[:200])
    # 取消，先试「全选」
    pg.locator(".modal-content button", has_text="取消").first.click()
    pg.wait_for_timeout(800)

    # 全选：表头那个框。Select 扩展的表头框点一下是全选
    pg.locator("#tasks-tbl th.select-checkbox").first.click()
    pg.wait_for_timeout(1500)
    n_sel = pg.locator("#tasks-tbl tr.selected").count()
    chk("★★ 表头那个框是全选（一次勾上 5 条）", n_sel == 5, n_sel)
    chk("★★ 全选后按钮上是 5",
        "5" in pg.locator("#tasks-delete").inner_text(),
        pg.locator("#tasks-delete").inner_text())

    # 真的删
    pg.click("#tasks-delete")
    pg.wait_for_timeout(1200)
    pg.locator(".modal-content button", has_text="删除").first.click()
    pg.wait_for_timeout(3000)
    body = pg.inner_text("body")
    chk("★★ 删完有回执", "已删除 5 条" in body,
        [t for t in body.split("\n") if "删除" in t][:3])
    chk("★★ 列表真的空了", pg.locator("#tasks-tbl tr.selected").count() == 0)
    rows = pg.locator("#tasks-tbl tbody tr").count()
    chk("★★ 库里也确实没了（列表只剩占位那一行）", rows <= 1, rows)

    chk("没有 JS 运行时错误", not errs, " | ".join(errs[:3]))
    pg.screenshot(path=os.path.join(OUT, "final.png"), full_page=True)
    b.close()

print("\n" + ("全部通过" if ok_all else "有失败项"), flush=True)
sys.exit(0 if ok_all else 1)
