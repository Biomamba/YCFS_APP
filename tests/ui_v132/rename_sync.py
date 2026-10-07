# -*- coding: utf-8 -*-
"""V13.2 item 6：改对话名 → 文件管理区里那个文件夹跟着改（端到端）。

用户原话：
  「目前改任务名称的时候，文件管理系统中的名称并不能一并修改」

R 层的 selftest 已经把机理验穿了（sync_dirs / file_owner / ws_published
三本账各自搬没搬、撞车加不加序号、没同步过时动不动盘）。这个脚本只回答
**剩下那两个只有浏览器答得了的问题**：

  1. 侧栏那个铅笔走到的确实是 db_session_rename —— 也就是用户**真的**
     点得出来这条链路（R 层是直接调函数的，绕过了 UI）；
  2. 改完之后「文件」页上那一条**显示的就是新名字**，而且点得进去、
     里面的东西还在。库里对了但页面上还是旧名字，对用户来说等于没改。

★ 为什么往库里**直接种**对话 + sync_dirs + 文件夹，而不是聊出来：
  聊一条要真的调模型（要 Key、要等、模型今天心情不好还不行）。种出来的
  和聊出来的在这两条链路上走的是**同一条渲染/改名路径**，所以种的就够。
  （tests/ui_v131/rename.py 里那段说明也是这个理由。）

⚠️ 这里**不断言**新文件夹名叫什么。名字的后半段是对话 id 的尾 4 位，在
   Python 里重算一遍 dsapp_sync_stem 就等于把 R 的算法抄一份 —— 抄错了
   测试会红，而红的是测试不是产品；产品改了拼法它还会跟着错。所以只断言
  **性质**：以新标题开头、旧的那个没了、里面的东西还在。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, DATA_ROOT, EMAIL, OUT, enter_app, goto,   # noqa: E402
                     seed_or_die)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

TAG = str(int(time.time()))[-6:]
SID = "s-v132rs-%s" % TAG
T_OLD = "改名前的老标题"
T_NEW = "改完的新标题"
OLD_DIR = "%s-%s" % (T_OLD, TAG[:4])     # 落点长这样：<标题>-<id 尾4位>
FILE = "de_genes.csv"


def q(dbp, sql, args=()):
    con = sqlite3.connect(dbp)
    try:
        cur = con.execute(sql, args)
        rows = cur.fetchall()
        con.commit()
        return rows
    finally:
        con.close()


def plant(dbp, uid, files_root):
    """种一条"已经同步过"的对话：sync_dirs 有一行、盘上有文件夹、里面有文件。

    这三样缺一不可，缺哪个测的都是别的东西：
      · 少 sync_dirs 那一行 → 改名时函数会走"还没同步过"那条早退分支，
        后面的断言全绿，但**一条都没验到**（这是最容易骗过自己的写法）；
      · 少盘上的文件夹 → 走"文件夹不在盘上，只改了记录"那条分支；
      · 少里面的文件 → 验不了"改名不是复制/不是重建"。
    """
    ts = "2026-09-16 09:00:00"
    q(dbp, "INSERT INTO sessions (id, title, user_id, created_at, updated_at)"
           " VALUES (?,?,?,?,?)", (SID, T_OLD, uid, ts, ts))
    q(dbp, "INSERT INTO sync_dirs (session_id, dir, created_at) VALUES (?,?,?)",
      (SID, OLD_DIR, ts))
    d = os.path.join(files_root, OLD_DIR)
    os.makedirs(os.path.join(d, "results"), exist_ok=True)
    with open(os.path.join(d, FILE), "w") as f:
        f.write("gene,log2FC\nTP53,2.1\n")
    with open(os.path.join(d, "results", "qc.csv"), "w") as f:
        f.write("s,n\n1,2\n")
    # 归属行 / 发布记录也种上：改完名之后它们得跟着搬。R 层验得更细，
    # 这里只取一条当"这条链路在真实例里也走通了"的旁证。
    for rel, dest in ((FILE, FILE), ("results/qc.csv", "results/qc.csv")):
        q(dbp, "INSERT INTO file_owner (name, user_id, created_at)"
               " VALUES (?,?,?)", ("u%d/%s/%s" % (uid, OLD_DIR, rel), uid, ts))
        q(dbp, "INSERT INTO ws_published (session_id, name, dest, created_at)"
               " VALUES (?,?,?,?)", (SID, rel, "%s/%s" % (OLD_DIR, dest), ts))
    return d


def dirs_of(dbp):
    return [r[0] for r in q(dbp, "SELECT dir FROM sync_dirs WHERE session_id = ?",
                            (SID,))]


def owners_of(dbp, uid):
    return [r[0] for r in q(dbp, "SELECT name FROM file_owner WHERE name LIKE ?"
                            " ORDER BY name", ("u%d/%%" % uid,))]


def dests_of(dbp):
    return [r[0] for r in q(dbp, "SELECT dest FROM ws_published WHERE"
                            " session_id = ?", (SID,))]


def rows_of(page):
    """文件页表格里每一行的文字。读不到就返回空 —— 一个"顺便打印一下"的
    参数把整条脚本带崩，是这类脚本最容易犯的错。"""
    try:
        return [page.locator("#files-tbl tbody tr").nth(i).inner_text()
                for i in range(page.locator("#files-tbl tbody tr").count())]
    except Exception:
        return []


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="改名同步")
    uid, dbp = seed_or_die(EMAIL)
    files_root = os.path.join(DATA_ROOT, "files", "u%d" % uid)
    os.makedirs(files_root, exist_ok=True)
    old_path = plant(dbp, uid, files_root)
    print("   uid=%s，种下 %s（盘上 %s）" % (uid, OLD_DIR, old_path), flush=True)

    # ⚠️ 必须 reload，不能只 goto("chat")：侧栏那个 renderUI 不知道库里多了
    #    一行（见 tests/ui_v131/rename.py 里那段更长的说明）。
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-shell", timeout=40000)
    page.wait_for_timeout(2500)
    goto(page, "chat", wait=4000)

    row = page.locator(".dsapp-sess[data-sid='%s']" % SID).first
    chk("★ 前提：侧栏里有这条对话", row.count() == 1)
    chk("★ 前提：行上有重命名铅笔", row.locator("a.dsapp-sess-edit").count() == 1)

    # ---- 走用户真正走的那条路：点铅笔 → 填新名 → 保存 ----
    row.locator("a.dsapp-sess-edit").click()
    page.wait_for_selector("#chat-rename_title", timeout=15000)
    page.wait_for_timeout(1000)
    # ⚠️ fill 完要等一下再点。Shiny 的 textInput 是防抖 250ms 回传的，
    #    填完立刻点保存，服务端手里还是上一次的值 —— 表现是"改了没反应"。
    page.fill("#chat-rename_title", T_NEW)
    page.wait_for_timeout(900)
    page.click("#chat-do_rename")
    page.wait_for_timeout(3000)
    chk("★ 弹窗关掉了（保存成功）",
        page.locator("#chat-rename_title").count() == 0)

    # ---- 库里那本账 ----
    d_now = dirs_of(dbp)
    chk("★★ 库里记的落点只剩一条，而且换成了新标题开头的名字",
        len(d_now) == 1 and d_now[0].startswith(T_NEW + "-"), extra=d_now)
    new_dir = d_now[0] if d_now else ""

    chk("★★★ 盘上是**改名**不是复制：旧文件夹没了，新文件夹里有原来的文件",
        not os.path.exists(old_path)
        and os.path.exists(os.path.join(files_root, new_dir, FILE))
        and os.path.exists(os.path.join(files_root, new_dir, "results", "qc.csv")),
        extra="旧在=%s 新在=%s"
              % (os.path.exists(old_path),
                 os.path.exists(os.path.join(files_root, new_dir, FILE))))

    own = owners_of(dbp, uid)
    chk("★★ 归属行跟着搬了（不搬的话里面每个文件都变成「无主」= 人人可删）",
        all(new_dir in o for o in own) and not any(OLD_DIR in o for o in own),
        extra=own)
    ds = dests_of(dbp)
    chk("★★ 发布记录的落点也换了前缀（不换的话重跑一次任务就多一份重复文件）",
        len(ds) == 2 and all(d.startswith(new_dir + "/") for d in ds),
        extra=ds)

    # ---- 用户看得见的那一面：文件页 ----
    # ⚠️ reload 而不是直接切页：文件页的 renderUI 有自己的依赖，从对话页
    #    切过去不一定重画（bslib 的 navset_hidden 是所有页都留在 DOM 里、
    #    只藏不激活）。重载之后是新 session，一定是按当前库渲染的。
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".dsapp-shell", timeout=40000)
    page.wait_for_timeout(2500)
    goto(page, "files", wait=5000)
    page.wait_for_timeout(2500)

    rows = rows_of(page)
    print("   文件页第一层：%s" % rows, flush=True)
    chk("★★★ 文件管理区里那一条**显示的是新名字**",
        any(T_NEW in r for r in rows), extra=rows)
    chk("★★ 旧名字在页面上**一个都不剩**（留着一行用户会以为改了个寂寞）",
        not any(T_OLD in r for r in rows), extra=rows)

    # 点进去 —— 证明它不只是"一行文字对了"，而是真的指向那个改名后的目录。
    # ⚠️ 点名称那一格（td 序号 1），不是整行：行上有复选框，点错格子会变成
    #    勾选，页面纹丝不动，报出来是"点不进去"。
    target = None
    for i in range(page.locator("#files-tbl tbody tr").count()):
        r = page.locator("#files-tbl tbody tr").nth(i)
        if T_NEW in r.inner_text():
            target = r
            break
    chk("★ 找得到那一行（下面那条的前提）", target is not None)
    if target is not None:
        target.locator("td").nth(1).click()
        page.wait_for_timeout(3500)
        inner = rows_of(page)
        print("   点进去之后：%s" % inner, flush=True)
        chk("★★★ 点得进去，而且改名时搬过去的东西都在里面",
            any(FILE in r for r in inner) and any("results" in r for r in inner),
            extra=inner)

    page.screenshot(path=OUT + "/rename_sync.png", full_page=True)
    br.close()

sys.exit(chk.done())
