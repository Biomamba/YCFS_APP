# -*- coding: utf-8 -*-
"""V13 item 2 / 3 / 6：文件管理区按账号隔离、历史产物补导入、团队管理。

三条用户原话：

  · item 2「比如 brca_result 这个文件夹，我在文件管理区就看不到」
  · item 3「共享会话需要在组内账户可以选择……所以你需要有一个团队管理系统
     和界面」
  · item 6「文件管理区不用所有人可见，每个账号显示自己的管理区就好」

★ 这个脚本和 selftest.R 里那几段的分工：自检验的是**函数**（
  dsapp_sync_backfill 搬了没有、teams.R 存取对不对），这里验的是**用户
  看得见的那一路**——用两个真账号、真浏览器，走的是页面上那几个按钮。
  两边都过才说明"改对了"，只有自检过说明的只是"函数对了"。

★ item 2 的复现方式刻意做成**和用户遇到的一模一样**：产物躺在对话工作区
  里、sync_dirs 里没有它的行 —— 正是"V12 之前跑出来的东西"。然后**不点
  任何按钮**，只是切到文件页，它就该在那儿。补同步是挂在页签上的（见
  mod_files.R 里那段说明），所以"切过去就出现"才是用户要的行为；要是得
  先点一下「导入对话产物」才出来，那用户下次还是会说"我看不到"。

⚠️ 这条脚本会往测试库里**写真数据**（两个账号、一个团队、几个文件）。
   _common.guard() 和 seed_or_die() 两道闸门保证它写的不是线上库。
"""
import os
import shutil
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, DATA_ROOT, OUT, PW, URL, enter_app, goto,  # noqa: E402
                     seed_or_die)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

TAG = str(int(time.time()))[-6:]
EA = "v13a_%s@example.com" % TAG
EB = "v13b_%s@example.com" % TAG
# 甲自己建的文件夹（用来验隔离：乙不该看见）
DIR_A = "A区_%s" % TAG
# 甲那条历史对话的标题 —— 补同步之后它在管理区里的落点就叫这个名字
TITLE_A = "BRCA_%s" % TAG
TEAM = "V13组_%s" % TAG


def tbl(page):
    """文件表格的整块文字。DT 重画时里面会短暂为空，取不到就返回空串。"""
    try:
        return page.inner_text("#files-tbl")
    except Exception:
        return ""


def wait_tbl(page, needle, timeout=25):
    """等表格里出现 needle。DT 是异步渲染的，点完按钮立刻读一定是旧内容。"""
    end = time.time() + timeout
    while time.time() < end:
        if needle in tbl(page):
            return True
        page.wait_for_timeout(400)
    return False


def rows(page):
    return page.locator("#files-tbl table tbody tr")


def click_name_cell(page, needle):
    """点某一行「名称」列。点文件夹的名称 = 进去（mod_files.R 的 cell_clicked）。

    ⚠️ 列下标是 **1**：第 0 列是复选框列（V7 item 9 加的）。点错列的后果
    不是"没反应"——是"点了别的列反而进目录"。
    """
    r = rows(page).filter(has_text=needle).first
    r.locator("td").nth(1).click()
    page.wait_for_timeout(2000)


def notify_text(page, timeout=15):
    """等一条通知出来并把文字读走。通知几秒后自己消失，所以要抢。

    ⚠️ 把所有当前的 `.shiny-notification` **拼起来**读，不要 `page.inner_text`
    单个选择器：页面上同时挂着两条通知时（很常见 —— 上一条还没消失），
    Playwright 的严格模式会判定"选择器命中多个元素"直接抛，被 except 吞掉
    之后返回空串。表现是"通知没出来"，而它明明就在屏幕上。这类假失败比
    漏报贵，因为它会让人去改一个没坏的地方。
    """
    try:
        page.wait_for_selector(".shiny-notification", timeout=timeout * 1000)
        page.wait_for_timeout(500)
        return "\n".join(page.locator(".shiny-notification").all_inner_texts())
    except Exception:
        return ""


def workspace_of(uid, dbp):
    """给这个账号造一条"历史对话"：库里一行 sessions + 工作区里一个产物。

    返回 (sid, 产物的绝对路径)。
    """
    sid = "chat-%s-%s" % (uid, TAG)
    con = sqlite3.connect(dbp)
    con.execute("INSERT INTO sessions (id, title, user_id, created_at, updated_at)"
                " VALUES (?, ?, ?, datetime('now'), datetime('now'))",
                (sid, TITLE_A, uid))
    con.commit()
    con.close()

    ws = os.path.join(DATA_ROOT, "workspaces", "chat-" + sid)
    sub = os.path.join(ws, "brca_result")
    os.makedirs(sub, exist_ok=True)
    csv = os.path.join(sub, "deseq.csv")
    with open(csv, "w") as f:
        f.write("gene,log2FC,padj\nTP53,2.1,0.001\nBRCA1,-1.8,0.004\n")
    return sid, csv


with sync_playwright() as pw:
    br = pw.chromium.launch()

    # =======================================================================
    # 甲：注册 → 建一个自己的文件夹 → 造一条带产物的历史对话
    # =======================================================================
    print("\n== 甲账号 ==", flush=True)
    ca = br.new_context(viewport={"width": 1500, "height": 950})
    pa = ca.new_page()
    enter_app(pa, EA, nickname="甲")
    uid_a, dbp = seed_or_die(EA)
    print("   甲 uid=%s  库=%s" % (uid_a, dbp), flush=True)

    a_root = os.path.join(DATA_ROOT, "files", "u%s" % uid_a)
    chk("甲的管理区一开始是空的（新账号没有文件）",
        not os.path.isdir(a_root) or os.listdir(a_root) == [],
        extra=os.listdir(a_root) if os.path.isdir(a_root) else "目录还没建")

    # ---- 造一条"V12 时代"的历史对话：工作区里有产物，sync_dirs 里没有行 --
    #
    # ★ 这一步**必须在甲第一次打开文件页之前**做完，因为它复现的是一个
    #   时间顺序：产物在**升级之前**就躺在工作区里了，用户升级后第一次
    #   打开文件页才去看。补同步每个 Shiny 会话只跑一次（挂在页签上，
    #   见 mod_files.R），所以先逛一圈文件页、再往工作区里塞东西的话，
    #   补同步那一趟已经过去了 —— 脚本会红在"没自动出现"，而那不是 bug，
    #   是脚本把因果顺序写反了（第一版就是这么红的）。
    #   真实场景里"第一次打开"那次一定晚于产物产生，所以这么摆才对。
    sid, csv = workspace_of(uid_a, dbp)
    con = sqlite3.connect(dbp)
    n_row = con.execute("SELECT COUNT(*) FROM sync_dirs WHERE session_id = ?",
                        (sid,)).fetchone()[0]
    con.close()
    chk("★ 前提：这条历史对话在 sync_dirs 里没有行（= 从没同步过）",
        n_row == 0, extra=n_row)

    # =======================================================================
    # item 2：**不点任何按钮**，第一次切到文件页就该看见
    # =======================================================================
    print("\n== item 2：切过去就出现 ==", flush=True)
    goto(pa, "files", wait=8000)     # 补同步挂在页签上，切过去才跑

    chk("★ 甲能进文件页（不是白屏、也不是「连不上服务器」）",
        pa.locator("#files-tbl").count() == 1)
    chk("★ 第一次切到文件页，历史对话的落点自动出现了（不用点「导入对话产物」）",
        wait_tbl(pa, TITLE_A, timeout=30), extra=tbl(pa)[:300])

    # 进去看：管理区 → 落点 → brca_result → deseq.csv。
    #
    # ⚠️ 落点在**根目录**那一层，`brca_result` 在它**里面** —— 别写成
    #    "根目录的表里应该同时有这两行"。第一版就是这么断言的，看着像
    #    功能没做完，其实只是把层级搞错了。
    if TITLE_A in tbl(pa):
        click_name_cell(pa, TITLE_A)
        chk("★ 点进落点，brca_result 在里面（用户看不到的就是这一层）",
            wait_tbl(pa, "brca_result", timeout=15), extra=tbl(pa)[:300])
        if "brca_result" in tbl(pa):
            click_name_cell(pa, "brca_result")
            chk("★ 再点进 brca_result，deseq.csv 在里面",
                wait_tbl(pa, "deseq.csv", timeout=15), extra=tbl(pa)[:300])
            # 顺着面包屑回根。进去出不来 = 用户照样拿不到文件，
            # 所以"回得去"也是一条要钉的行为。
            pa.click("#files-crumb_0")
            pa.wait_for_timeout(2500)
            chk("★ 点面包屑的「文件管理区」能回到根目录（进得去也出得来）",
                wait_tbl(pa, TITLE_A, timeout=15), extra=tbl(pa)[:250])

    # ---- 手动那个按钮：再导一次要说"没有需要导入的产物"，不能重复搬 ----
    pa.click("text=导入对话产物")
    nt = notify_text(pa)
    chk("★ 再点一次「导入对话产物」：明确说「没有需要导入的产物」（幂等）",
        "没有需要导入的产物" in nt, extra=nt[:160])
    chk("也没有多出「(1)」这样的副本", "(1)" not in tbl(pa), extra=tbl(pa)[:200])

    # ---- 磁盘上真的落在 u<甲>/ 底下 ----
    # 落点目录名由标题决定（dsapp_sync_dir），带 4 位尾巴，所以按前缀找
    hits = [d for d in (os.listdir(a_root) if os.path.isdir(a_root) else [])
            if d.startswith("BRCA_%s" % TAG)]
    chk("★ 产物真的复制到了**甲自己**的管理区目录 data/files/u<甲>/ 底下",
        len(hits) == 1, extra=hits)
    chk("★ 复制出来的是 brca_result/deseq.csv 这个路径，不是被压平的一个文件",
        bool(hits) and os.path.exists(os.path.join(a_root, hits[0],
                                                   "brca_result", "deseq.csv")))

    # ---- 建一个自己的文件夹（后面验隔离要用：乙不该看见它）-------------
    #
    # ⚠️ 填完名字要停一下再点「创建」。Shiny 的 textInput 是**每次按键**
    #    回传的，fill() 刚写完就点按钮的话，服务端那边 `input$new_dir`
    #    还是空串，`req(nzchar(...))` 直接拦掉 —— 表现是"点了没反应"，
    #    不报错、也没日志，看起来像功能坏了（第一版就是这么红的两条）。
    #
    # ⚠️ 建完之后界面会**直接进到新文件夹里**（"建了多级目录却停在原地，
    #    用户还要自己一层层点下去才知道建成了没有"）。所以别指望建完还能
    #    在表里看见它 —— 那时候表里列的是**新文件夹的内容**，空的。
    #    判据得换成面包屑，再点回根确认。第一版就是在这儿红的。
    pa.click("#files-mkdir")
    pa.wait_for_selector("#files-new_dir", timeout=15000)
    pa.wait_for_timeout(800)
    pa.fill("#files-new_dir", DIR_A)
    pa.wait_for_timeout(800)
    pa.click("#files-do_mkdir")

    end = time.time() + 15
    while time.time() < end and DIR_A not in pa.inner_text("#files-crumb"):
        pa.wait_for_timeout(400)
    chk("★ 新建文件夹成功后，面包屑显示人已经在新文件夹里",
        DIR_A in pa.inner_text("#files-crumb"),
        extra=pa.inner_text("#files-crumb")[:200])
    chk("★ 磁盘上真的建出来了（在甲自己的管理区下）",
        os.path.isdir(os.path.join(a_root, DIR_A)),
        extra=os.listdir(a_root) if os.path.isdir(a_root) else "无目录")

    pa.click("#files-crumb_0")
    pa.wait_for_timeout(2500)
    chk("★ 回到根目录，新建的文件夹在表里",
        wait_tbl(pa, DIR_A, timeout=15), extra=tbl(pa)[:250])

    # =======================================================================
    # item 3：团队管理界面
    # =======================================================================
    print("\n== item 3：团队 ==", flush=True)
    con = sqlite3.connect(dbp)
    con.execute("UPDATE users SET is_admin = 1 WHERE id = ?", (uid_a,))
    con.commit()
    con.close()

    # 乙先注册出来，这样建组时才有第二个人可选
    print("\n== 乙账号 ==", flush=True)
    cb = br.new_context(viewport={"width": 1500, "height": 950})
    pb = cb.new_page()
    enter_app(pb, EB, nickname="乙")
    uid_b, _ = seed_or_die(EB)
    print("   乙 uid=%s" % uid_b, flush=True)

    pa.reload(wait_until="domcontentloaded")
    pa.wait_for_selector(".dsapp-shell", timeout=40000)
    pa.wait_for_timeout(2500)
    goto(pa, "admin")

    body = pa.inner_text("body")
    chk("★ 管理页有「团队」这一块", "团队" in body)
    chk("★ 而且说清楚了团队**不是**权限单位",
        "不决定谁能看什么" in body)

    chk("建组表单在（组名输入框）", pa.locator("#admin-team_name").count() == 1)
    grp = pa.locator("#admin-team_members")
    chk("组内账号是一个**可勾选**的清单（不是让人手打邮箱）",
        grp.count() == 1)
    labels = grp.inner_text() if grp.count() else ""
    chk("★ 清单里列着甲和乙（带邮箱，昵称可能重名，邮箱不会）",
        EA in labels and EB in labels, extra=labels[:200])

    # ⚠️ 同样的回传时序：填完组名、勾完人，都要等服务端收全了再点「建组」。
    #    checkboxGroupInput 是**逐个**回传的，勾完最后一个立刻点保存，
    #    服务端可能只收到了一个人 —— 存下去的就是"组内 1 人"。
    pa.fill("#admin-team_name", TEAM)
    pa.wait_for_timeout(700)
    # checkboxGroupInput 的 value 就是 user id，直接按 value 勾最稳 ——
    # 按标签文字找会踩到"昵称可以重名也可以留空"，而邮箱里带 @ 和数字，
    # 拼进 CSS 选择器还要转义。
    for uid in (uid_a, uid_b):
        loc = pa.locator("#admin-team_members input[value='%d']" % uid)
        if loc.count() and not loc.is_checked():
            loc.check()
            pa.wait_for_timeout(500)
    pa.click("#admin-team_save")
    # ⚠️ 管理页的反馈**不是** toast，是页面里那块行内的 `#admin-action_msg`
    #    （mod_admin.R 里 `note()` 走的是 msg()/renderUI，不是
    #    showNotification）。拿 `.shiny-notification` 去等它，等多久都是空 ——
    #    而功能其实是好的（下面那张表的断言一直是过的）。第一版就是这么
    #    红了一条，红的还是个不存在的问题。
    end = time.time() + 15
    amsg = ""
    while time.time() < end:
        try:
            amsg = pa.inner_text("#admin-action_msg")
        except Exception:
            amsg = ""
        if "组内 2 人" in amsg:
            break
        pa.wait_for_timeout(400)
    chk("★ 建组成功，并且回话说清楚了组内有几个人",
        "组内 2 人" in amsg, extra=amsg[:200])

    # 建好的组要出现在上面的表里。判据取"这张表里有没有这一行"，而不是
    # 整页 body 里找"2" —— 页面上到处是 2（时间戳、用量数字），那种断言
    # 永远为真，等于没测。
    def team_rows():
        try:
            return pa.inner_text("#admin-teams_ui")
        except Exception:
            return ""
    end = time.time() + 10
    while time.time() < end and TEAM not in team_rows():
        pa.wait_for_timeout(400)
    tr = team_rows()
    chk("★ 建好的组出现在下面的表里", TEAM in tr, extra=tr[:250])
    row = pa.locator("#admin-teams_ui table tbody tr").filter(has_text=TEAM)
    chk("★ 而且人数写的是 2（不是 0、也不是空）",
        row.count() == 1 and "2" in row.first.inner_text(),
        extra=row.first.inner_text() if row.count() else "没这一行")

    # =======================================================================
    # item 3：共享弹窗里，同组的人是可以勾选的
    # =======================================================================
    print("\n== item 3：共享弹窗 ==", flush=True)
    goto(pa, "chat")
    pa.click("#chat-new_chat")
    pa.wait_for_timeout(2500)

    link = pa.locator("#chat-open_share")
    chk("有对话之后，出现「共享这个对话」入口", link.count() == 1,
        extra=pa.inner_text("body")[-200:])
    if link.count():
        link.click()
        pa.wait_for_selector(".modal-dialog", timeout=15000)
        pa.wait_for_timeout(1200)
        modal = pa.inner_text(".modal-dialog")
        chk("★ 弹窗里有「同组账号」，且把乙列成了可勾选项",
            "同组账号" in modal and EB in modal, extra=modal[:300])
        chk("★ 同时也留了手填邮箱的口子（分享给组外的人）",
            "其它账号" in modal and "一行一个" in modal)
        # 真的勾上乙、保存（同样是等回传：见上面建组那段）
        loc = pa.locator("#chat-share_ids input[value='%d']" % uid_b)
        if loc.count() and not loc.is_checked():
            loc.check()
            pa.wait_for_timeout(700)
        pa.click("#chat-do_share")
        pa.wait_for_timeout(3000)
        nt = notify_text(pa)
        chk("★ 勾选同组账号保存后，共享成功", ("共享" in nt), extra=nt[:200])
        con = sqlite3.connect(dbp)
        n = con.execute("SELECT COUNT(*) FROM session_share WHERE user_id = ?",
                        (uid_b,)).fetchone()[0]
        con.close()
        chk("★ 库里真的写下了「乙可以看甲这个对话」这一行", n == 1, extra=n)

    # =======================================================================
    # item 6：隔离 —— 乙看不见甲的任何东西
    # =======================================================================
    print("\n== item 6：隔离 ==", flush=True)
    goto(pb, "files")
    tb = tbl(pb)
    chk("★ 乙的文件管理区里**没有**甲建的文件夹 %s" % DIR_A, DIR_A not in tb,
        extra=tb[:300])
    chk("★ 乙的文件管理区里**没有**甲那条对话的落点 %s" % TITLE_A,
        TITLE_A not in tb, extra=tb[:300])
    chk("乙看到的是自己的空管理区（或者自己传的东西）",
        "还没有文件" in tb or rows(pb).count() == 0, extra=tb[:200])

    b_root = os.path.join(DATA_ROOT, "files", "u%s" % uid_b)
    b_entries = os.listdir(b_root) if os.path.isdir(b_root) else []
    chk("★ 磁盘上：乙的管理区目录里也没有甲的东西", len(b_entries) == 0,
        extra=b_entries)

    # 反过来：甲还能看见自己的（别修成"谁也看不见"）
    goto(pa, "files")
    chk("★ 反向：甲自己仍然看得见自己那两个（隔离没做成一刀切）",
        wait_tbl(pa, DIR_A, timeout=10) and TITLE_A in tbl(pa),
        extra=tbl(pa)[:300])

    # 乙不是管理员 → 连「管理」页的入口都没有
    goto(pb, "chat")
    pb.wait_for_timeout(800)
    chk("★ 乙（非管理员）侧栏里没有「管理」入口",
        pb.locator("[data-nav='admin']").count() == 0,
        extra=pb.locator(".dsapp-rail").inner_text()[:200]
        if pb.locator(".dsapp-rail").count() else "")

    pa.screenshot(path=OUT + "/teams_files_a.png", full_page=True)
    pb.screenshot(path=OUT + "/teams_files_b.png", full_page=True)
    br.close()

sys.exit(chk.done())
