# -*- coding: utf-8 -*-
"""V7 item 7/9/10/11 的浏览器验证：文件页。

  item 11  文件管理区（改名 + 置顶）
  item 9   文件区多选 + 多选下载
  item 10  文件夹 / 分组一键打包下载（zip 内容真的对）
  item 7   本对话产物按任务名称分类展开

对着一次性实例（8898）跑。会真的注册账号、真的建目录、真的下载解包。
"""
import io
import os
import random
import subprocess
import sys
import zipfile

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
    pg.wait_for_timeout(2200)


def grab(pg, click_sel, name):
    """点一个会触发下载的东西，存下来，返回本地路径。"""
    path = os.path.join(OUT, name)
    with pg.expect_download(timeout=45000) as info:
        pg.locator(click_sel).first.click()
    info.value.save_as(path)
    return path


os.makedirs(OUT, exist_ok=True)

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1560, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v7f_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    # 库里已经有账号时入口页是**登录页**（mod_welcome.R:233），得先切到注册
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V7文件")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000002")
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

    # 先在言出法随页建一个对话 —— 「本对话产物」那块要有当前对话才出现
    rail(pg, "言出法随")
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(3000)

    # =====================================================================
    print("\n== item 11：叫文件管理区，且在最上面 ==")
    # =====================================================================
    rail(pg, "文件")
    pg.wait_for_timeout(1500)
    body = pg.inner_text("body")
    chk("★★ 页面上不再出现「共享文件区」", "共享文件区" not in body,
        [t for t in body.split("\n") if "共享" in t][:3])
    chk("★★ 出现了「文件管理区」", "文件管理区" in body)

    # 位置：文件管理区那张卡片要在「本对话产物」上面
    y_file = pg.evaluate("""() => {
      const h = [...document.querySelectorAll('.card-header')]
        .find(e => e.innerText.includes('文件管理区'));
      return h ? h.getBoundingClientRect().top + window.scrollY : null;
    }""")
    y_ws = pg.evaluate("""() => {
      const h = [...document.querySelectorAll('.card-header')]
        .find(e => e.innerText.includes('本对话产物'));
      return h ? h.getBoundingClientRect().top + window.scrollY : null;
    }""")
    chk("★★ 文件管理区排在「本对话产物」上面（item 11 的正题）",
        y_file is not None and (y_ws is None or y_file < y_ws),
        "文件管理区 y=%s / 本对话产物 y=%s" % (y_file, y_ws))

    # =====================================================================
    print("\n== item 9/10：文件区多选 + 打包下载 —— **已作废，跳过** ==")
    # =====================================================================
    # ⚠️⚠️ 这一节原来测的是"每行最左边有个方框，勾两行能打包下载"。那个交互
    #    在 V13.5 item 4 被**故意**改掉了：第 0 列不再是 Select 扩展画的空
    #    方框，换成「去预览」四个字（点它 = 清空选择、只选这一行，所以永远
    #    到不了"选中 2 项"）。`#files-tbl td.select-checkbox` 在那张表上
    #    **本来就该是 0 个** —— 留着这几条断言，它报的不是"功能坏了"，
    #    而是"它测的那个设计已经不存在了"，而红着的测试等于没有测试。
    #
    #    覆盖没有丢，搬到了 tests/ui_v135/files.py：
    #      · 第 0 列是「去预览」、且没有 Select 画的 ::before 空方框；
    #      · 选中行读的是 input$tbl_rows_selected（真值，不是按钮上的文字）；
    #      · 表头那个"全选"方框还在、动作条跟着选中行变。
    #    下面 item 7/10 那一节仍然有效，继续跑。
    print("  \033[33m…\033[0m 已作废（V13.5 改掉了每行的选择方式）"
          "—— 覆盖在 tests/ui_v135/files.py", flush=True)


    # =====================================================================
    print("\n== item 7/10：本对话产物按任务分组 + 一键打包 ==")
    # =====================================================================
    # 塞一个对话 + 三个任务 + 工作区文件，并按应用自己的逻辑记产物索引
    r = subprocess.run(["Rscript", "-e", """
for (f in list.files("R", pattern = "[.]R$", full.names = TRUE)) source(f)
cfg <- dsapp_config(); dsapp_init_dirs(cfg)
con <- dsapp_db(cfg)
u <- DBI::dbGetQuery(con, "SELECT id FROM users WHERE email = '%s'")$id[[1]]
sid <- dsapp_id("s")
DBI::dbExecute(con, "INSERT INTO sessions (id, user_id, title, created_at, updated_at)
                     VALUES (?, ?, 'V7 文件测试', datetime('now'), datetime('now'))",
               params = list(sid, as.integer(u)))
d <- dsapp_ws_dir(sid, cfg)
mk <- function(tid, title, status, files) {
  code <- "print(1)"
  DBI::dbExecute(con, paste("INSERT INTO tasks",
    "(session_id, title, lang, code, status, exit_code, created_at)",
    "VALUES (?, ?, 'R', ?, ?, 0, datetime('now'))"),
    params = list(sid, title, code, status))
  tid2 <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS i")$i[[1]]
  for (f in files) {
    p <- file.path(d, f)
    dir.create(dirname(p), showWarnings = FALSE, recursive = TRUE)
    writeLines(paste("from", title), p)
  }
  db_task_files_set(tid2, sid, files, con = con)
  tid2
}
mk(1, "读入表达矩阵", "success", c("expr_clean.csv", "qc.png"))
mk(2, "差异分析", "success", c("results/de_genes.csv", "results/volcano.png"))
mk(3, "富集分析", "running", c("enrich.csv"))
# 一个没有归属的（解压出来的 / 早期文件）
writeLines("orphan", file.path(d, "legacy_note.txt"))
cat(sid, "\\n")
""" % email], capture_output=True, cwd=APP)
    sid = r.stdout.decode().strip().split("\n")[-1]
    print("   seeded session:", sid, r.stderr.decode()[-300:] if r.returncode else "")

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_timeout(3500)
    rail(pg, "文件")
    pg.wait_for_timeout(5000)

    groups = pg.locator("details.dsapp-wsgroup")
    chk("★★ 产物按任务分组了（3 个任务 + 1 组「其他」= 4 组）",
        groups.count() == 4, groups.count())
    txt = pg.inner_text(".dsapp-main-body")
    for t in ["读入表达矩阵", "差异分析", "富集分析", "其他"]:
        chk("★ 分组标题里有「%s」" % t, t in txt)
    # 分组按 task_id **降序**（新任务在前，认不出归属的垫底），所以第一组是
    # 最后建的「富集分析」而不是「读入表达矩阵」。这里要验的是"组名 = 任务名"
    # 这件事本身，不是某一个具体的顺序。
    first_txt = pg.locator("details.dsapp-wsgroup").first.inner_text()
    chk("★★ 组名就是任务名（item 7 的正题）",
        any(t in first_txt for t in ["读入表达矩阵", "差异分析", "富集分析"]),
        first_txt[:120].replace("\n", " "))
    chk("★ 最新的任务排在最前面（新产物不用往下翻）",
        "富集分析" in first_txt, first_txt[:80].replace("\n", " "))

    chk("★ 第一组默认是展开的（全收起的话看着像没有产物）",
        pg.locator("details.dsapp-wsgroup").first.evaluate("e => e.open") is True)
    chk("★★ 收起的那几组，摘要行上仍然写着文件数和体积（收起≠信息丢失）",
        "个文件" in pg.locator("details.dsapp-wsgroup").nth(1).locator("summary").inner_text(),
        pg.locator("details.dsapp-wsgroup").nth(1).inner_text()[:100].replace("\n", " "))

    # 展开「差异分析」那一组，看它的文件
    pg.locator("details.dsapp-wsgroup summary", has_text="差异分析").first.click()
    pg.wait_for_timeout(900)
    dg = pg.locator("details.dsapp-wsgroup", has_text="差异分析").first
    chk("★★ 展开后能看到这个任务产出的文件（含子目录里的）",
        "results/de_genes.csv" in dg.inner_text() and
        "results/volcano.png" in dg.inner_text(),
        dg.inner_text()[:200].replace("\n", " "))

    # ⚠️ 必须用 :text-is（精确匹配）而不是 has_text（子串）——「打包下载」
    #    里也含「下载」两个字，子串匹配会把摘要行那个打包链接一起数进来，
    #    断言就成了恒真。
    # ⚠️ 失败时要把那一格的动作区**原样**打出来。只报"下载=2 发布=0"的话，
    #    下面三种情况长得一模一样，而修法完全不同：
    #      · 文件被标成"已发布"了（那样按设计就只有「下载」）；
    #      · 链接在，但文字不是「发布」（改了文案）；
    #      · 整格没渲染出来（布局坏了）。
    acts = pg.evaluate("""() => {
      const g = [...document.querySelectorAll('details.dsapp-wsgroup')]
        .find(e => e.innerText.includes('差异分析'));
      if (!g) return ['（找不到那一组）'];
      return [...g.querySelectorAll('.dsapp-wsrow-act')].map(e => e.innerHTML);
    }""")
    # ⚠️ 这里原来还断言"每个文件有「发布」"。V12 item 3 之后**不成立了**：
    #    任务产物会自动同步进管理区，同步完 `published` 就是真，而
    #    `ws_row()` 里 `if (!published) ws_act_link("发布", ...)` 是按设计
    #    不渲染的。所以这条只留「下载」这一半（下面「发布」那一整段也一并
    #    作废了，理由写在那边）。
    chk("★ 每个文件都有「下载」", dg.locator("a:text-is('下载')").count() >= 2,
        "下载=%d ｜ 动作区：%s" % (dg.locator("a:text-is('下载')").count(), acts))

    # 点这一组的「打包下载」
    z = grab(pg, "details.dsapp-wsgroup:has-text('差异分析') a:has-text('打包下载')",
             "group.zip")
    with zipfile.ZipFile(z) as zf:
        names = sorted(zf.namelist())
    chk("★★ 一组一键打包下载（item 10 的正题）",
        names == ["results/de_genes.csv", "results/volcano.png"], names)

    # 上面这一下有没有把分组连带收起？（summary 里的链接不该触发切换）
    still = pg.locator("details.dsapp-wsgroup", has_text="差异分析").first
    chk("★★ 点「打包下载」不会把这一组收起来（summary 里的链接不触发折叠）",
        still.evaluate("e => e.open") is True)

    # 单文件下载
    # 同样用 :text-is —— 用 has_text 的话 .first 会命中摘要行的「打包下载」，
    # 下回来一个 zip，拿它当文本读就是 UnicodeDecodeError。
    z = grab(pg, "details.dsapp-wsgroup:has-text('富集分析') a:text-is('下载')",
             "one.csv")
    with open(z, encoding="utf-8") as fh:
        got = fh.read().strip()
    chk("★★ 单个产物也能直接下载，内容是它自己的",
        got == "from 富集分析", got[:60])

    # ---- 「发布」那一段：**已作废，跳过** --------------------------------
    #
    # ⚠️⚠️ 原来这里点「发布」、验 toast、验文件被标成「已发布」。V12 item 3
    #    加了**任务产物自动同步**（sync_dirs，见 R/db.R）之后，这条路的终点
    #    提前了：工作区里的产物在页面渲染时就已经落进管理区、`ws_published`
    #    里已经有行了，于是 `published` 为真，`ws_row()` 里那个
    #    `if (!published) ws_act_link("发布", ...)` **按设计就不渲染**。
    #
    #    也就是说「发布」这个链接在**任务产物**上已经看不到了 —— 这一页
    #    永远是 0 个，断言报的不是"功能坏了"，是"它测的入口已经不存在了"。
    #    （这正是它上一次跑起来时红在这里的原因；实测确认过：那一格的动作区
    #    里只有「下载」，而 ws_published 里已经有自动同步写下的行。）
    #
    #    真正还在用「发布」的是**上传的文件**（对话页那条路），以及
    #    "发布记录会跟着改名一起搬"这件事 —— 后者在
    #    tests/ui_v132/rename_sync.py 里有断言。
    note = pg.locator("#shiny-notification-panel .shiny-notification").all_inner_texts()
    print("  \033[33m…\033[0m 「发布」那三条已作废（V12 起任务产物自动同步，"
          "产物上不再有这个链接）", flush=True)

    chk("没有 JS 运行时错误", not errs, " | ".join(errs[:3]))
    pg.screenshot(path=os.path.join(OUT, "files.png"), full_page=True)
    b.close()

print("\n" + ("全部通过" if ok_all else "有失败项"), flush=True)
sys.exit(0 if ok_all else 1)
