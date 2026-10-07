# -*- coding: utf-8 -*-
"""V13.11 item 1 验收：「本对话的文件」卡片只列本对话的文件夹，点文件夹原地进。

    bash tests/ui_v7/make_instance.sh 8912 /tmp/dsapp_v1311
    /home/biomamba/miniconda3/bin/python tests/ui_v1311/item01_files.py

用户原话：「言出法随页面本对话的文件只显示当前对话所属文件夹即可，点击
文件夹应该直接在本对话文件中进入，而不是跳转文件页面」。

★ 为什么不能只跑 selftest：那几条断言看的是**源码里有没有某个调用**，
  而这一条的坑是"代码看着对、列出来的却是别人的文件夹" —— 工作区里恰好
  有整个文件区的镜像（dsapp_mirror_shared 把文件区整片映进去，目录还是
  真建的），所以读工作区**照样能列出东西**，只是列错了地方。必须真的把
  两个根都塞上诱饵、再看页面渲染的是哪一份。
  诱饵用**不同像素尺寸**的合法 PNG：光看"图出没出来"分不出读的是哪个根。
"""
import base64
import os
import sqlite3
import sys
import time

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import DATA_ROOT, OUT, URL, db_path, enter_app, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FILES_ROOT = os.path.join(DATA_ROOT, "files")
WS_ROOT = os.path.join(DATA_ROOT, "workspaces")
PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ"
    "DwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


def png(w, h, val=0):
    """造一张 w×h 的纯色 PNG（不依赖 PIL）。

    ★ 为什么要能造**不同尺寸**的图：两个根（文件区 / 工作区）里放同名文件
      时，光看"图出来了没有"分不出读的是哪一份 —— 两边都是合法 PNG。
      尺寸是能从 naturalWidth 读回来的，于是"读的是哪一份"变成可断言的事。
    """
    import struct
    import zlib

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    raw = b"".join(b"\x00" + bytes([val, val, val]) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) +
            chunk(b"IEND", b""))
_SEQ = 0
FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


def seed_session(uid, title, n_turns=2):
    global _SEQ
    _SEQ += 1
    sid = "i1-%s-%04d" % (time.strftime("%Y%m%d%H%M%S"), _SEQ)
    con = sqlite3.connect(db_path())
    con.execute("INSERT INTO sessions (id, user_id, title, created_at, "
                "updated_at) VALUES (?,?,?,datetime('now'),datetime('now'))",
                (sid, uid, title))
    for k in range(1, n_turns + 1):
        con.execute("INSERT INTO messages (session_id, role, content, "
                    "created_at) VALUES (?,?,?,datetime('now'))",
                    (sid, "user", "第 %d 轮：帮我做一下 ANGPTL2-LILRB2 的分析" % k))
    con.commit()
    con.close()
    return sid


def set_sync_dir(sid, name):
    con = sqlite3.connect(db_path())
    con.execute("INSERT OR REPLACE INTO sync_dirs (session_id, dir, created_at) "
                "VALUES (?,?,datetime('now'))", (sid, name))
    con.commit()
    con.close()


def put(root, rel, data=None):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(data if data is not None else PNG_1PX)
    return p


def card_rows(pg):
    return pg.eval_on_selector_all(
        ".dsapp-artifacts .dsapp-file-link",
        "els => els.filter(e => e.offsetParent !== null).map(e => e.innerText.trim())")


def card_title(pg):
    if not pg.locator(".dsapp-artifacts .card-header").count():
        return ""
    return pg.inner_text(".dsapp-artifacts .card-header").strip()


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    ctx = br.new_context(viewport={"width": 1600, "height": 950})
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:200])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, _ = seed_or_die(email)
    print("uid=%s  DATA_ROOT=%s" % (uid, DATA_ROOT), flush=True)

    title = "帮做一下ANGPTL2-LILRB2"
    sid = seed_session(uid, title)
    tail4 = "".join(c for c in sid.rsplit("-", 1)[-1] if c.isalnum())[:4]
    cdir = "%s-%s" % (title, tail4)
    set_sync_dir(sid, cdir)

    uroot = os.path.join(FILES_ROOT, "u%d" % uid)
    # 本对话的文件夹：1×1 的图，工作区那份诱饵做成 3×3 —— 靠 naturalWidth
    # 就能判出页面读的到底是哪一个根（两边都是合法 PNG，光看"出没出图"分不出）
    put(os.path.join(uroot, cdir), "volcano.png", png(1, 1))
    put(os.path.join(uroot, cdir), "expr.csv", b"gene,log2fc\nANGPTL2,1.2\n")
    put(os.path.join(uroot, cdir), "results/umap.png", png(1, 1))
    put(os.path.join(uroot, cdir), "results/qc.txt", b"qc ok\n")
    # 诱饵 1：文件区根目录下**别人的**对话文件夹（改之前会混进来）
    put(os.path.join(uroot, "别人的对话-9999"), "secret.txt", b"not yours\n")
    # 诱饵 2：工作区里两个**同名**文件 —— 坐标要是漏了 files: 前缀，
    #        解析就会落到工作区，渲染出来的是这两份 3×3 的
    put(os.path.join(WS_ROOT, "chat-" + sid), "volcano.png", png(3, 3))
    put(os.path.join(WS_ROOT, "chat-" + sid), "results/umap.png", png(3, 3))

    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(4000)
    goto(pg, "chat", wait=2500)
    pg.wait_for_selector('.dsapp-sess[data-sid="%s"]' % sid,
                         state="attached", timeout=40000)
    sel = '.dsapp-sess[data-sid="%s"]' % sid
    if "active" not in (pg.get_attribute(sel, "class") or "").split():
        pg.wait_for_selector(sel, state="visible", timeout=30000)
        pg.click(sel)
    pg.wait_for_timeout(6000)
    pg.wait_for_selector(".dsapp-artifacts", timeout=40000)

    print("\n== 根：卡片标题 = 对话文件夹名，内容 = 它这一层 ==", flush=True)
    t0 = card_title(pg)
    print("   标题: %r" % t0, flush=True)
    rows0 = card_rows(pg)
    print("   行  : %s" % rows0, flush=True)
    C("★★★ 标题是**本对话的文件夹名**", cdir in t0, t0)
    C("★★★ 列出了本对话文件夹的内容（含子目录 results）",
      "volcano.png" in rows0 and "expr.csv" in rows0 and "results" in rows0,
      str(rows0))
    C("★★★ **没有**别人的对话文件夹混进来（改之前正是这个症状）",
      not any("别人的对话" in r for r in rows0), str(rows0))
    C("★ 也没有工作区镜像里的其它杂项",
      not any(r in ("workspaces", "packages", "logs") for r in rows0), str(rows0))
    C("★ 卡片上没有「发布/已同步」那套按钮",
      pg.locator(".dsapp-artifacts .fa-share-nodes").count() == 0)
    C("★ 根上没有「返回上一层」（根上返回没有意义）", "返回上一层" not in pg.inner_text(".dsapp-artifacts"))

    print("\n== 点 results：原地进这一层，不跳页 ==", flush=True)
    url0 = pg.url
    nav0 = pg.eval_on_selector_all(
        ".dsapp-rail-link.active", "els => els.map(e => e.getAttribute('data-nav'))")
    pg.click('.dsapp-artifacts .dsapp-file-link:has-text("results")')
    pg.wait_for_timeout(3500)
    t1 = card_title(pg)
    rows1 = card_rows(pg)
    print("   标题: %r" % t1, flush=True)
    print("   行  : %s" % rows1, flush=True)
    nav1 = pg.eval_on_selector_all(
        ".dsapp-rail-link.active", "els => els.map(e => e.getAttribute('data-nav'))")
    C("★★★ 还在言出法随页（没有跳去「文件」页）",
      nav1 == nav0 and nav1 == ["chat"], "nav %s -> %s" % (nav0, nav1))
    C("★★★ URL 没变（原地展开，不是导航）", pg.url == url0, pg.url)
    C("★★★ 进了 results：列出的是它这一层",
      "umap.png" in rows1 and "qc.txt" in rows1 and "volcano.png" not in rows1,
      str(rows1))
    C("★★ 标题变成面包屑（文件夹名 / results）",
      cdir in t1 and "results" in t1, t1)
    C("★★ 子目录里出现「返回上一层」",
      "返回上一层" in pg.inner_text(".dsapp-artifacts"))

    print("\n== 点 返回上一层：回到根 ==", flush=True)
    pg.click('.dsapp-artifacts a:has-text("返回上一层")')
    pg.wait_for_timeout(3500)
    t2 = card_title(pg)
    rows2 = card_rows(pg)
    print("   标题: %r" % t2, flush=True)
    print("   行  : %s" % rows2, flush=True)
    C("★★★ 回到根：标题和内容都回去了",
      cdir in t2 and "results" not in t2.split("/")[-1] and
      "volcano.png" in rows2 and "results" in rows2, "%r %s" % (t2, rows2))
    C("★ 回到根之后「返回上一层」又收起来了",
      "返回上一层" not in pg.inner_text(".dsapp-artifacts"))

    print("\n== 缩略图点开的是**文件区**那份（坐标写死前缀，不是同名的工作区文件） ==",
          flush=True)
    nat0 = pg.eval_on_selector_all(
        ".dsapp-artifacts .dsapp-thumb-img img",
        "els => els.filter(e => e.offsetParent !== null).map(e => e.naturalWidth)")
    print("   根上缩略图的 naturalWidth: %s" % nat0, flush=True)
    C("★★★ 缩略图取的是**文件区**那份 1×1（工作区有同名的 3×3 诱饵）",
      1 in nat0 and 3 not in nat0, str(nat0))
    pg.click('.dsapp-artifacts .dsapp-thumb-cap:has-text("volcano.png")')
    pg.wait_for_timeout(3000)
    has_modal = pg.locator(".modal-body").count() > 0
    C("★★ 点缩略图名字弹出了预览", has_modal)
    pg.keyboard.press("Escape")
    pg.wait_for_timeout(1200)

    print("\n== 进 results 之后缩略图跟着换层（槽位和文件名不能错位） ==", flush=True)
    pg.click('.dsapp-artifacts .dsapp-file-link:has-text("results")')
    pg.wait_for_timeout(3500)
    nat1 = pg.eval_on_selector_all(
        ".dsapp-artifacts .dsapp-thumb-img img",
        "els => els.filter(e => e.offsetParent !== null).map(e => e.naturalWidth)")
    print("   results 里缩略图的 naturalWidth: %s" % nat1, flush=True)
    C("★★★ 子目录里的缩略图也是**文件区**那份 1×1", 1 in nat1 and 3 not in nat1,
      str(nat1))

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item1_root.png", full_page=True)
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
