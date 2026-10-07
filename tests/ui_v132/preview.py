# -*- coding: utf-8 -*-
"""V13.2 item 9 / 10：预览弹窗里的图片溢出 + 表格预览报 length zero。

用户的原话：
  item 9 「html预览很好，能够和背景弹窗自适应，但是图片会溢出背景弹窗，
          请做好自适应」
  item 10「表格预览的时候会提示 Error in if (! searchable[j]) next:
          argument is length zero」

两条都发生在**同一个地方** —— 对话页点文件名的那个预览弹窗
（`art_preview_want` → `modalDialog`），所以放在一个脚本里测：
弹窗开一次是图片、再开一次是表格。

★ item 9 的根因不在弹窗上，在两个渲染器的天生差别：
    html 走 `<iframe style="width:100%;height:70vh">`，尺寸是我们写死的；
    图片走 `imageOutput()`，而 `renderImage()` 返回的 list 里**没给
    width/height**，Shiny 就原样吐一个**原始尺寸**的 `<img>`。
  ⚠️ 所以断言不能只查"弹窗里有没有 img" —— 那是查不出来的，
     一张 2400px 的图在 DOM 里、看得见、`inner_text` 也读得到，
     只是它画到弹窗外面去了。必须量**几何**：
     图片的矩形要落在 `.modal-content` 的矩形里。

★ item 10 的根因也不在我们的代码里：DT 服务端过滤 `DT:::dataTablesFilter`
    按列名建 `imap`，列名为空串时该位置记成 `0`，接着 `searchable[0]`
    取出来是 `logical(0)`，`if (!logical(0))` 就报 "argument is length zero"。
    空列名来自 R 自己 `write.csv(df)` 出来的文件 —— 行名那一列的表头是空的，
    而读文件用的是 `check.names = FALSE`（那个必须留着，否则
    `gene name` 会被改成 `gene.name`）。
  ⚠️ 所以这里要真的造一个"R 导出的 csv"（第一格是空表头），
     不能拿手写的、表头齐全的 csv 去测 —— 那样永远是绿的。
"""
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, DATA_ROOT, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 图片要**足够大**，不然"没溢出"这件事毫无意义 —— 800px 的弹窗里放一张
# 200px 的图，改不改代码都是绿的。2400 是 modal-lg（800px）的三倍。
IMG_W, IMG_H = 2400, 1500
IMG_NAME = "oversize_plot.png"
CSV_NAME = "rn_export.csv"
PDF_NAME = "zzz_report.pdf"   # 名字排最后，方便"只勾它一个"


def png_bytes(w, h):
    """造一张 w×h 的渐变 PNG。

    ⚠️ 用渐变而不是随机噪声：随机噪声的 PNG 压不动，2400×1500 会顶到
       十几 MB，直接撞上 DSAPP_THUMB_MAX_BYTES（4MB）就**拿不到缩略图**了，
       而症状是"找不到缩略图"——看起来像界面坏了，其实是测试数据造错了。
       渐变最坏也就几百 KB。
    """
    from PIL import Image
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        r = int(255 * y / max(1, h - 1))
        for x in range(0, w, 1):
            px[x, y] = (r, int(255 * x / max(1, w - 1)), 128)
    import io
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def seed_session(con, uid, title="预览测试对话"):
    """建一条**属于这个账号**的会话，并把 updated_at 顶到最前面。

    ⚠️ 必须属于这个账号：db_sessions_list() 只列"我的 + 共享给我的"，
      不属于的话登录后 rv$session_id 挑不到它，产物卡片根本不出现。
    ⚠️ updated_at 必须比别的会话新：db_sessions_list 按 updated_at 倒序，
      第一条才会被自动选中（mod_chat.R 的 observeEvent(state$user_id)）。
      用的时间戳要**比现有的大**，所以直接取库里最大值 +1 天。
    """
    sid = "s-uipreview-%d" % uid
    row = con.execute("SELECT MAX(updated_at) FROM sessions").fetchone()
    base = row[0] or "2026-09-01 00:00:00"
    con.execute("DELETE FROM tasks WHERE session_id = ?", (sid,))
    con.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    con.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    con.execute(
        "INSERT INTO sessions (id, title, user_id, created_at, updated_at)"
        " VALUES (?,?,?,?,?)",
        (sid, title, uid, base, "2099-01-01 00:00:00"))
    con.commit()
    return sid


def ws_dir(sid):
    return os.path.join(DATA_ROOT, "workspaces", "chat-" + sid.replace("/", "_"))


# 量"这个元素有没有画到那个容器外面去"。
# 容器取 .modal-content（那圈白框），它就是用户眼里的"背景弹窗"。
PROBE_JS = r"""
(sel) => {
  const el = document.querySelector(sel);
  const box = document.querySelector('.modal-content');
  if (!el || !box) return null;
  const r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
  return {
    img: {top: Math.round(r.top), bottom: Math.round(r.bottom),
          left: Math.round(r.left), right: Math.round(r.right),
          w: Math.round(r.width), h: Math.round(r.height)},
    box: {top: Math.round(b.top), bottom: Math.round(b.bottom),
          left: Math.round(b.left), right: Math.round(b.right),
          w: Math.round(b.width), h: Math.round(b.height)},
    // 溢出量：>0 就是画到弹窗外面去了
    overRight: Math.round(r.right - b.right),
    overLeft: Math.round(b.left - r.left),
    overBottom: Math.round(r.bottom - b.bottom),
    overTop: Math.round(b.top - r.top),
    natW: el.naturalWidth || 0,
    natH: el.naturalHeight || 0,
    cssMaxW: getComputedStyle(el).maxWidth,
    cssMaxH: getComputedStyle(el).maxHeight,
    visible: r.width > 0 && r.height > 0,
  };
}
"""

with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()

    # 收集页面上的报错。item 10 报的那个错会以两种形态出现：
    #   * Shiny 的 .shiny-output-error 文本（用户看到的那条）
    #   * 浏览器的 console.error / pageerror
    # 两边都收，断言时一起查。
    console = []
    page.on("console", lambda m: console.append("%s: %s" % (m.type, m.text)))
    page.on("pageerror", lambda e: console.append("pageerror: %s" % e))

    email = enter_app(page, nickname="预览")
    uid, dbfile = seed_or_die(email)
    con = sqlite3.connect(dbfile)
    sid = seed_session(con, uid)
    d = ws_dir(sid)
    os.makedirs(d, exist_ok=True)

    png = png_bytes(IMG_W, IMG_H)
    with open(os.path.join(d, IMG_NAME), "wb") as f:
        f.write(png)
    # ★ 这就是 R 自己 write.csv(data.frame(...)) 出来的形状：
    #   第一行的第一格是空的（行名那一列没有表头）。
    with open(os.path.join(d, CSV_NAME), "w") as f:
        f.write('"","gene","log2FC","padj"\n'
                '"TP53",1.0,2.31,0.001\n'
                '"MYC",2.0,-1.42,0.004\n'
                '"EGFR",3.0,0.77,0.021\n')
    # 最小 PDF。**内容合法不合法无所谓** —— 这一步测的是"那个地址取不取
    # 得到字节"，不是浏览器能不能渲染它（预览走的是 <iframe>，浏览器那边
    # 坏了也不会让断言红）。所以别为了造一个合规 PDF 去引依赖。
    with open(os.path.join(d, PDF_NAME), "wb") as f:
        f.write(b"%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n"
                b"trailer<</Root 1 0 R>>\n%%EOF\n")
    print("  账号 uid=%s 会话=%s" % (uid, sid), flush=True)
    print("  工作区 %s" % d, flush=True)
    print("  塞了 %s（%d×%d，%.0f KB）和 %s（首格空表头）"
          % (IMG_NAME, IMG_W, IMG_H, len(png) / 1024.0, CSV_NAME), flush=True)

    # ⚠️ 必须重新载入。rv$session_id 是模块**初始化时**挑的，刚插进去的会话
    #    这次会话里不存在；不刷新的话产物卡片一直是空的，而断言会以
    #    "找不到缩略图"的形式失败 —— 指向的是界面，不是这里。
    page.reload(wait_until="domcontentloaded")
    page.wait_for_timeout(8000)
    goto(page, "chat")
    page.wait_for_timeout(3000)

    chk("★ 产物卡片出现了（会话挑对了、工作区也扫到了）",
        page.locator(".dsapp-artifacts").count() == 1)

    # ---------------------------------------------------------------- item 9
    print("\n== item 9：图片预览 ==", flush=True)
    thumb = page.locator(".dsapp-artifacts .dsapp-thumb-img").first
    chk("★ 大图有缩略图（说明它没超过 4MB 的缩略图上限，下面量的才是真图）",
        thumb.count() == 1,
        extra="产物卡片里的缩略图个数=%d"
              % page.locator(".dsapp-artifacts .dsapp-thumb-img").count())
    if thumb.count() == 0:
        page.screenshot(path=OUT + "/preview_no_thumb.png", full_page=True)
        print("  产物卡片内容：%r"
              % page.locator(".dsapp-artifacts").inner_text()[:300], flush=True)
        con.close(); br.close(); sys.exit(chk.done())

    thumb.first.click()
    page.wait_for_selector(".modal-content", timeout=15000)
    page.wait_for_timeout(3000)
    chk("★ 点缩略图弹出了预览弹窗",
        page.locator(".modal-content").count() == 1)
    page.screenshot(path=OUT + "/preview_image.png")

    m = page.evaluate(PROBE_JS, ".modal-content .dsapp-preview-img img")
    print("  图片: %s" % (m and m["img"]), flush=True)
    print("  弹窗: %s" % (m and m["box"]), flush=True)
    print("  原图: %s×%s  max-width=%s max-height=%s"
          % (m and m["natW"], m and m["natH"],
             m and m["cssMaxW"], m and m["cssMaxH"]), flush=True)

    chk("★ 弹窗里的 <img> 真的渲染出来了（不是空的 uiOutput）",
        bool(m and m["visible"]), extra=m)
    # ★ 这条是**前提**，不是结论：原图必须比弹窗宽，否则"没溢出"这个结论
    #   是在一张本来就塞得下的图上得出的，等于没测。
    chk("★★ 原图比弹窗宽得多（不改代码它**必然**溢出 —— 这条测的是测试数据）",
        bool(m) and m["natW"] >= m["box"]["w"] * 2,
        extra="原图 %s px，弹窗 %s px" % (m and m["natW"], m and m["box"]["w"]))
    chk("★★★ 图片**没有溢出**弹窗右沿（用户报的那一条）",
        bool(m) and m["overRight"] <= 1, extra="溢出 %s px" % (m and m["overRight"]))
    chk("★★ 也没从左边冒出去",
        bool(m) and m["overLeft"] <= 1, extra="溢出 %s px" % (m and m["overLeft"]))
    chk("★ 竖着也没顶穿（原图 %d 高，弹窗 %d 高）"
        % (IMG_H, m["box"]["h"] if m else 0),
        bool(m) and m["overBottom"] <= 1 and m["overTop"] <= 1,
        extra="下溢 %s px 上溢 %s px"
              % (m and m["overBottom"], m and m["overTop"]))
    # ★ 不许把图压扁。max-width 和 max-height 两个都给、宽高都 auto 才是
    #   "等比缩"，少一个就会拉伸 —— 而拉伸在几何断言里是看不出来的
    #   （矩形照样在弹窗里面，就是人变形了）。
    ratio_ok = bool(m) and m["natW"] and m["natH"] and m["img"]["w"] and m["img"]["h"] \
        and abs((float(m["img"]["w"]) / m["img"]["h"]) -
                (float(m["natW"]) / float(m["natH"]))) < 0.02
    chk("★★ 图是**等比**缩小的，没有被拉扁",
        ratio_ok,
        extra=m and "渲染 %d×%d（比 %.3f），原图 %d×%d（比 %.3f）"
              % (m["img"]["w"], m["img"]["h"],
                 float(m["img"]["w"]) / max(1, m["img"]["h"]),
                 m["natW"], m["natH"], float(m["natW"]) / max(1, m["natH"])))

    page.click(".modal-footer button")
    page.wait_for_timeout(1500)

    # ---------------------------------------------------------------- item 10
    print("\n== item 10：表格预览（首格空表头）==", flush=True)
    link = page.locator(".dsapp-artifacts a.dsapp-file-link",
                        has_text=CSV_NAME).first
    chk("★ 产物卡片里找得到那个 csv", link.count() == 1)
    link.click()
    page.wait_for_selector(".modal-content", timeout=15000)
    page.wait_for_timeout(4000)
    page.screenshot(path=OUT + "/preview_table.png")

    body = page.inner_text(".modal-content")
    print("  弹窗文字: %r" % body[:300], flush=True)
    chk("★ 弹窗里 DT 的表格壳子渲染出来了（.dataTables_wrapper）",
        page.locator(".modal-content .dataTables_wrapper").count() == 1,
        extra="弹窗文字 %r" % body[:200])
    # ★★ 用户报的那一条。
    # ⚠️ 断言查的是**整页**文字，不只弹窗：Shiny 出错时那个 error 块有可能
    #    渲染在 uiOutput 的外面（弹窗体里），只查 .modal-content 会漏。
    whole = page.inner_text("body")
    bad = "argument is length zero"
    chk("★★★ 页面上**没有**「argument is length zero」",
        bad not in whole,
        extra="命中位置 %r" % whole[max(0, whole.find(bad) - 120):
                                     whole.find(bad) + 120])
    chk("★★ 页面上也没有别的 Shiny 渲染错误块（.shiny-output-error）",
        page.locator(".shiny-output-error").count() == 0,
        extra=page.locator(".shiny-output-error").all_inner_texts()[:3])
    chk("★ console 里没有异常",
        not [c for c in console if c.startswith(("error", "pageerror"))],
        extra=[c for c in console if c.startswith(("error", "pageerror"))][:5])

    # 表头读出来核对：空的那一格应该被补成 V1，且其余列名**原样不动**
    ths = page.locator(".modal-content table.dataTable thead th").all_inner_texts()
    ths = [t.strip() for t in ths]
    print("  表头: %s" % ths, flush=True)
    # ⚠️ 前两个 th 是 DT 自己的勾选列/序号列（这里没开），所以直接按内容找。
    chk("★★ 空表头被补成了 V1（不是留空、也不是报错）",
        "V1" in ths, extra=ths)
    chk("★★ 其它列名**原样保留**（补名字不能把 check.names=FALSE 的初衷改掉）",
        "gene" in ths and "log2FC" in ths and "padj" in ths, extra=ths)
    rows = page.locator(".modal-content table.dataTable tbody tr").count()
    chk("★ 数据行也在（3 行）", rows == 3, extra="%d 行" % rows)
    chk("★ 第一列的值没丢（行名 TP53/MYC/EGFR）",
        "TP53" in body and "EGFR" in body, extra=repr(body[:200]))

    # ------------------------------------------------- 顺带：文件页那条路
    # 文件页的图片预览走的是**另一段代码**（mod_files.R 的 `tags$img` +
    # `img-fluid`），不是上面那个弹窗。用户说的是「app中如果有其它问题，请
    # 一并修改」，所以顺手量一下它有没有同样的毛病 —— 同一份工作区、同一张图。
    print("\n== 顺带：文件页的图片预览 ==", flush=True)
    page.click(".modal-footer button")
    page.wait_for_timeout(1200)
    goto(page, "files")
    page.wait_for_timeout(4000)
    # ⚠️ 文件页上有**两**处文件列表，别搞混：
    #   * `.dsapp-wsrow`  = 「本对话产物」（工作区里的，只有 下载/发布/打包下载，
    #                        **没有预览** —— 所以它测不了图片自适应）；
    #   * `#files-tbl`    = 「文件管理区」（发布/上传进来的，点行才有右侧预览）。
    #    第一版直接去 #files-tbl 里找 PNG，找不到就跳过了 —— 因为那个文件还在
    #    工作区里，**没发布过**。测这一步必须先点一次「发布」。
    # ⚠️ 这里的 click 用**原生 DOM 的 .click()**，不用 Playwright 的 locator.click()。
    #    原因：点「发布」之后服务端会 ws_refresh() 重渲染整张卡，那个 <a> 连同
    #    它的父节点一起被换掉。Playwright 的 click 是"先解析元素、再点、再确认
    #    没被替换"，元素在它眼皮底下消失时它会**重试**，而重试时那个「发布」
    #    链接已经变成「已发布」不存在了 —— 于是报 30 秒超时。
    #    实测：三趟跑下来文件**每一次都发布成功了**（data/files/u*/… 里躺着
    #    三份 oversize_plot.png），报错却全是"点了没点着"。原生 click 没有
    #    这套确认，点完就返回。
    acted = page.evaluate(r"""
    (nm) => {
      const rows = [...document.querySelectorAll('.dsapp-wsrow')];
      const r = rows.find(x => x.innerText.includes(nm));
      if (!r) return 'no-row';
      const a = [...r.querySelectorAll('.dsapp-wsrow-act a')]
                  .find(x => x.innerText.trim() === '发布');
      if (!a) return 'already-published';
      a.click();
      return 'clicked';
    }
    """, IMG_NAME)
    print("  发布 %s → %s" % (IMG_NAME, acted), flush=True)
    page.wait_for_timeout(3000)

    # 发布是复制进 `data/files/u<uid>/<会话名>-<n>/`，落在**一层子目录**里，
    # 所以文件管理区第一屏看不到它 —— 得先点进那个文件夹（只有「名称」列
    # 点得动，见 mod_files.R 的 input$tbl_cell_clicked）。
    folder = page.locator("#files-tbl tbody tr", has_text="预览测试对话").first
    if folder.count() == 0:
        print("  （文件管理区里没有那个会话文件夹，跳过）", flush=True)
    else:
        folder.locator("td").nth(1).click()   # 第 1 列 = 名称（第 0 列是复选框）
        page.wait_for_timeout(3000)

    row = page.locator("#files-tbl tbody tr", has_text=IMG_NAME).first
    if row.count() == 0:
        print("  （文件管理区里没列到 %s，跳过 —— 不影响 item 9/10 的结论）"
              % IMG_NAME, flush=True)
    else:
        # ⚠️ 文件行**点名字是不动的**（mod_files.R 里那行 `if (!isTRUE(is_dir)) return()`），
        #    右侧预览取的是**勾选**的第一行。所以点第 0 列那个复选框。
        row.locator("td").nth(0).click()
        page.wait_for_timeout(4000)
        # ⚠️ 容器取 card_body（#files-preview 的父节点）。文件页这块**不是**
        #    弹窗，是右边那张卡；拿 .modal-content 去量只会得到 null。
        f = page.evaluate(r"""
        () => {
          const el = document.querySelector('#files-preview img');
          const box = document.querySelector('#files-preview').parentElement;
          if (!el || !box) return null;
          const r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
          return {
            img: {w: Math.round(r.width), h: Math.round(r.height),
                  right: Math.round(r.right), bottom: Math.round(r.bottom)},
            box: {w: Math.round(b.width), h: Math.round(b.height),
                  right: Math.round(b.right), bottom: Math.round(b.bottom)},
            overRight: Math.round(r.right - b.right),
            overBottom: Math.round(r.bottom - b.bottom),
            src: el.getAttribute('src') || '',
            natW: el.naturalWidth || 0,
            natH: el.naturalHeight || 0,
          };
        }
        """)
        print("  文件页图片: %s / 容器 %s" % (f and f["img"], f and f["box"]),
              flush=True)
        print("  src=%s natural=%s×%s"
              % (f and f["src"][:80], f and f["natW"], f and f["natH"]), flush=True)
        chk("★ 文件页的图片预览也没溢出它所在的容器",
            bool(f) and f["overRight"] <= 1 and f["overBottom"] <= 1,
            extra=f and "右溢 %s 下溢 %s" % (f["overRight"], f["overBottom"]))
        # ★★ 这一条是 2026-09-16 顺手查出来的**真 bug**，不属于用户报的 14 条。
        #    V13.1 item 6 把 /files 静态路由删掉时，漏改了 mod_files.R 里
        #    图片和 PDF 两处，两个预览从 V13.1 起一直是 404：
        #      * `<img>` 渲染成一个十几像素高的碎图（naturalWidth = 0）；
        #      * PDF 是一个空白框。
        #    不报错、不进 console，只有量 naturalWidth 才看得出来。
        chk("★★★ 文件页的图片**真的加载出来了**（不是 404 的碎图）",
            bool(f) and f["natW"] > 0,
            extra="naturalWidth=%s  src=%s"
                  % (f and f["natW"], (f and f["src"])[:70]))
        # 直接把那个地址取一次：200 才算这条预览路真的通。
        # ⚠️ 地址是 **相对**的（`session/<token>/dataobj/...`），要拼上根。
        if f and f["src"]:
            import urllib.request
            full = f["src"] if f["src"].startswith("http") \
                else ("http://127.0.0.1:8898/" + f["src"].lstrip("/"))
            code = "?"
            try:
                code = urllib.request.urlopen(full, timeout=15).getcode()
            except Exception as e:
                code = "ERR %s" % e
            print("  GET %s → %s" % (full[:90], code), flush=True)
            chk("★★ 那个预览地址取回来是 200（不是 404）", code == 200,
                extra=str(code))
        page.screenshot(path=OUT + "/preview_files_img.png")

        # ---- PDF 也走同一条（原来是同一个 bug 的第二处）----
        #
        # ⚠️ 预览取的是**勾选的第一行**（mod_files.R 的 selected()），所以
        #    得先把图片那行的勾去掉，只留 PDF。重进一次文件夹最省事。
        page.locator("#files-tbl tbody tr", has_text=IMG_NAME).first \
            .locator("td").nth(0).click()
        page.wait_for_timeout(800)
        pdfrow = page.locator("#files-tbl tbody tr", has_text=PDF_NAME).first
        if pdfrow.count() == 0:
            print("  （没列到 %s，跳过 PDF 那一半）" % PDF_NAME, flush=True)
        else:
            pdfrow.locator("td").nth(0).click()
            page.wait_for_timeout(3500)
            psrc = page.evaluate(
                "() => { const f = document.querySelector("
                "'#files-preview iframe'); return f ? (f.getAttribute('src')||'') : null; }")
            print("  PDF iframe src=%s" % (psrc or "(没有 iframe)")[:90], flush=True)
            chk("★ 文件页的 PDF 预览渲染出了 iframe",
                bool(psrc), extra=psrc)
            if psrc:
                import urllib.request
                full = psrc if psrc.startswith("http") \
                    else ("http://127.0.0.1:8898/" + psrc.lstrip("/"))
                code = "?"
                try:
                    code = urllib.request.urlopen(full, timeout=15).getcode()
                except Exception as e:
                    code = "ERR %s" % e
                chk("★★★ PDF 的预览地址也是 200（不是 404 的空白框）",
                    code == 200, extra="%s → %s" % (full[:80], code))
            page.screenshot(path=OUT + "/preview_files_pdf.png")

    con.close()
    br.close()

sys.exit(chk.done())
