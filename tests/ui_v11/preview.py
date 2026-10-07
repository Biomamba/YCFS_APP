# -*- coding: utf-8 -*-
"""V11 item 1 + item 11：文件预览。

    DSAPP_TEST_APP=/tmp/dsapp_v11test_xxxx/app python3 tests/ui_v11/preview.py

item 1  —— 「预览界面的 html 不能显示渲染后的，是以文本形式展现的，注意其它
           标记语言也要能正常渲染」
item 11 —— 「文件预览只显示前 512KB 是不行的，文本格式可以只显示前 20 行，
           html 文件应该显示完全，小于 20MB 在线预览都可以」

★ 判据必须落在**真的画出来了**上面，不能是"HTML 里有个 iframe"：
  把 src 写错、把 sandbox 属性写死、CSP 拦掉，DOM 里那个 <iframe> 一个
  都不会少 —— 用户看到的是一片空白。所以这里读的是 **iframe 里面的
  document**：渲染成功的标志是"那段 HTML 变成了真的元素"，不是"那段
  HTML 的源码出现在某个地方"。

★ 大文件那两条（3MB 的 HTML 仍然渲染、21MB 的直接拒绝）也必须是浏览器
  里量的。离线断言只能证明源码里没有那个 512 * 1024 了，证明不了它在
  这条路径上真的生效。
"""
import io
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

chk = C.Chk()

# ⚠️ V13.0 起共享区**按账号分了一层**：`files/u<uid>/`（见 R/files.R 的
#    dsapp_files_user_dir，以及同目录下那个 `.migrated_v13` 迁移标记）。
#    `files/` 根下那层只用来放**迁移之前**的历史文件，新账号在文件页里
#    看不到它 —— 这份脚本写于 V11，一直把测试文件直接丢进根下，于是
#    「（前置）四个测试文件都出现在文件列表里」永远是 `[]`，
#    后面的断言全都没跑过。**从 V13.0 起就红着，和 V13.2 无关。**
#
#    所以改成两步：先写进一个**暂存目录**（那里不受应用的 0444 只读保护
#    影响），等账号建出来、拿到 uid 之后再拷进 `files/u<uid>/`。
FILES_BASE = os.path.join(C.DATA_ROOT, "files")
SEED_DIR = os.path.join(C.DATA_ROOT, "_v11_preview_seed")
os.makedirs(SEED_DIR, exist_ok=True)

HTML_MARK = "V11HTML渲染标记"
MD_MARK = "V11Markdown标题"


def ensure_fixture(path, content):
    """把测试文件放到位；**内容一样就原样复用，不重写**。

    ⚠️ 这条不是优化，是这个脚本第二次跑得起来的前提。**放进共享区**的文件
    会被应用设成 0444（只读保护，见 R/files.R），第二次 `open(p,"w")` 直接
    PermissionError —— 报出来的是"测试脚本没权限"，和被测的预览渲染毫无
    关系，照着它查会查到完全不相干的地方去。

    ★ V13.0 起这里写的是**暂存目录**（`_v11_preview_seed`），不在共享区里，
      本来就不受只读保护；这条复用逻辑留着是因为 3MB/21MB 那两个文件
      每次重写纯属浪费。（真正需要 chmod 的是拷进 u<uid>/ 那一步。）

    内容对得上就说明这个文件本来就是上一次同一段代码造的，复用它测的是同一
    件事（下面每条断言认的都是文件里的**标记串**，不是"这次刚写进去的"）。
    """
    if os.path.exists(path):
        try:
            with io.open(path, encoding="utf-8") as f:
                if f.read() == content:
                    return
        except Exception:
            pass
    with open(path, "w") as f:
        f.write(content)


# ---- 1. 一个 3MB 的 HTML ------------------------------------------------------
# 3MB 这个数是挑过的：它**大于**老的 512KB 上限（证明上限真的挪走了），
# 又**小于** 20MB 的新上限（应该照常渲染）。
html_small = os.path.join(SEED_DIR, "v11_preview.html")
ensure_fixture(html_small,
    "<!doctype html><html><head><meta charset='utf-8'>"
    "<title>V11</title></head><body>\n"
    "<h1 id='v11mark'>%s</h1>\n" % HTML_MARK +
    "<script>document.title = 'rendered-by-script';</script>\n"
    "<!-- " + ("填充" * 700000) + " -->\n"          # ≈ 3 MB 的注释
    "<p id='tail'>尾部这一段在 512KB 之外</p>\n"
    "</body></html>\n")

# ---- 2. Markdown --------------------------------------------------------------
md = os.path.join(SEED_DIR, "v11_preview.md")
ensure_fixture(md, "# %s\n\n**粗体**和`代码`都该渲染出来，而不是原样显示星号。\n"
                   % MD_MARK)

# ---- 3. 一个 40 行的文本 -------------------------------------------------------
txt = os.path.join(SEED_DIR, "v11_preview.txt")
ensure_fixture(txt, "".join("第 %d 行内容\n" % i for i in range(1, 41)))

# ---- 4. 一个 21MB 的 HTML（超上限）--------------------------------------------
html_big = os.path.join(SEED_DIR, "v11_big.html")
ensure_fixture(html_big,
    "<!doctype html><html><body><h1>太大了</h1>\n<!-- "
    + "x" * (21 * 1024 * 1024) + " --></body></html>\n")

sizes = {os.path.basename(p): os.path.getsize(p)
         for p in (html_small, md, txt, html_big)}
print("== 造好的文件（%s，稍后拷进 u<uid>/）==" % SEED_DIR)
for k, v in sizes.items():
    print("   %-18s %8.2f MB" % (k, v / 1024.0 / 1024.0))
print("   注意 v11_preview.html 是 %.2f MB —— 老版本 512KB 上限下它会走"
      "「只显示前 512KB」那条路" % (sizes["v11_preview.html"] / 1024.0 / 1024.0))


def open_file(page, name):
    """在文件页勾选一行（DT 的 Select 扩展，复选框那一列是第一列）。

    ⚠️ 每次都要**先清空**上一次的勾选。DT 的 Select 扩展是**多选**的，
    点第二行不会把第一行取消掉；而预览用的是 `selected()` —— 它取的是
    **行号最小的那一个**（见 mod_files.R：预览/打开/改名一次只对一个目标
    有意义）。不清空的话，预览永远停在你第一次点的那个文件上，而这条
    断言会红得像"Markdown 没渲染"。
    """
    page.evaluate("""() => {
      const $ = window.jQuery;
      if ($ && $('#files-tbl table').length) {
        $('#files-tbl table').DataTable().rows().deselect();
      }
    }""")
    page.wait_for_timeout(900)
    row = page.locator("#files-tbl tbody tr", has_text=name).first
    row.locator("td.select-checkbox").click()
    page.wait_for_timeout(2500)


with sync_playwright() as b:
    br = b.chromium.launch()
    ctx = br.new_context(viewport={"width": 1440, "height": 900})
    pg = ctx.new_page()
    C.enter_app(pg, nickname="V11预览")

    # 账号建出来了才有 uid —— 把暂存的四个文件放进**这个账号**的共享区。
    # 放根下是看不见的（见上面那段说明）。
    import shutil
    import sqlite3
    _p = C.db_path()
    if not _p:
        sys.exit("找不到库文件，跑不下去。")
    _c = sqlite3.connect(_p)
    _row = _c.execute("SELECT id FROM users WHERE email = ?", (C.EMAIL,)).fetchone()
    _c.close()
    if _row is None:
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里。" % (C.EMAIL, _p))
    USER_FILES = os.path.join(FILES_BASE, "u%d" % _row[0])
    os.makedirs(USER_FILES, exist_ok=True)
    print("== 拷进账号共享区：%s ==" % USER_FILES)
    for _f in (html_small, md, txt, html_big):
        _dst = os.path.join(USER_FILES, os.path.basename(_f))
        if os.path.exists(_dst):
            os.chmod(_dst, 0o644)   # 上一次跑留下的 0444 只读保护
        shutil.copyfile(_f, _dst)

    pg.evaluate("() => window.dsappNav && window.dsappNav('files')")
    pg.wait_for_timeout(4000)
    # 文件列表不轮询共享区（见 mod_files.R 里 refresh 的说明），要手动刷。
    #
    # ⚠️ 那个刷新按钮**没有 DOM id** —— 它的 onclick 是
    #    Shiny.setInputValue('files-refresh_tbl', Math.random())，也就是
    #    "files-refresh_tbl" 是个**输入名**，不是元素 id。照着名字去
    #    click("#files-refresh_tbl") 会等满超时，报"找不到元素"。
    pg.evaluate("() => Shiny.setInputValue('files-refresh_tbl', Math.random(),"
                " {priority: 'event'})")
    pg.wait_for_timeout(4000)

    names = pg.eval_on_selector_all(
        "#files-tbl tbody tr td:nth-child(2)", "es=>es.map(e=>e.innerText.trim())")
    chk("（前置）四个测试文件都出现在文件列表里",
        all(n in names for n in ("v11_preview.html", "v11_preview.md",
                                 "v11_preview.txt", "v11_big.html")), names)
    if not all(n in names for n in ("v11_preview.html",)):
        sys.exit("文件没上传到位，后面的断言没有意义。列表：%s" % names)

    prev = pg.locator("#files-preview")

    # =====================================================================
    # item 1：HTML 要**渲染**，不是把源码贴出来
    # =====================================================================
    open_file(pg, "v11_preview.html")
    chk("item1 ★ 预览里出现了 iframe（HTML 走的是渲染那条路）",
        pg.locator(".dsapp-preview-frame").count() == 1,
        pg.locator(".dsapp-preview-frame").count())

    # 读 iframe **里面**的 document。sandbox 没给 allow-same-origin，文档
    # 处在一个不透明源里 —— Playwright 走的是浏览器协议，不是注入页面脚本，
    # 所以照样读得到（这一点正是这条断言的价值：手写 JS 是读不到的）。
    fr = None
    for _ in range(20):
        pg.wait_for_timeout(500)
        for f in pg.frames:
            if "preview" in (f.url or "") or f != pg.main_frame:
                try:
                    if f.locator("#v11mark").count():
                        fr = f
                        break
                except Exception:
                    pass
        if fr:
            break

    chk("item1 ★★ iframe 里真的渲染出了那段 HTML（不是一片空白）",
        fr is not None, [f.url[:80] for f in pg.frames])
    if fr:
        chk("item1 ★★ 标记是**元素**，不是转义后的文本（用户原话：不能是文本形式）",
            fr.locator("#v11mark").count() == 1 and
            fr.inner_text("#v11mark").strip() == HTML_MARK,
            fr.content()[:200])
        # 没被 escape 的铁证：源码里那个 <h1 ...> 不该以文本形式出现在页面上
        body_txt = fr.inner_text("body")
        chk("item1 ★ 页面上看不到 `<h1` 这样的源码（转义了就是「文本形式展现」）",
            "<h1" not in body_txt and "&lt;h1" not in body_txt, body_txt[:120])
        chk("item1 里面的脚本能跑（sandbox 留了 allow-scripts，报告要它）",
            fr.title() == "rendered-by-script", fr.title())

    # =====================================================================
    # item 11：3MB 的 HTML **不在** 512KB 那条路上
    # =====================================================================
    if fr:
        chk("item11 ★★ 3MB 的 HTML 是整个渲染的（不是只显示前 512KB）"
            "—— 尾部那段在 512KB 之外，它必须也在",
            fr.locator("#tail").count() == 1,
            "只找到 %d 个 #tail" % fr.locator("#tail").count())

    chk("item11 预览里没有「只显示前 512KB」这类提示",
        "512" not in prev.inner_text(), prev.inner_text()[:200])

    # =====================================================================
    # item 1（续）：Markdown 也要渲染
    # =====================================================================
    open_file(pg, "v11_preview.md")
    md_html = pg.eval_on_selector_all(
        "#files-preview .dsapp-preview-md", "es=>es.map(e=>e.innerHTML)")
    chk("item1 ★ Markdown 也走渲染（有 .dsapp-preview-md）", len(md_html) == 1,
        prev.inner_text()[:200])
    if md_html:
        h = md_html[0]
        chk("item1 ★★ `# 标题` 变成了 <h1>，不是原样的井号",
            "<h1" in h and MD_MARK in h, h[:200])
        chk("item1 ★★ `**粗体**` 变成了 <strong>，不是原样的星号",
            "<strong>" in h and "**" not in h, h[:200])
        chk("item1 ★ 行内代码变成了 <code>",
            "<code>" in h, h[:200])

    # =====================================================================
    # item 11：文本只显示前 20 行
    # =====================================================================
    open_file(pg, "v11_preview.txt")
    t = prev.inner_text()
    n_lines = len([ln for ln in t.splitlines() if ln.strip().startswith("第 ")])
    chk("item11 ★★ 40 行的文本只显示前 20 行（用户原话）",
        n_lines == 20, "显示了 %d 行" % n_lines)
    chk("item11 说明了为什么只有 20 行（不是静默截断）",
        "20" in t, t[:160])
    chk("item11 ★ 不是按 512KB 切的：20 行之外的那些行一行都不该在",
        "第 21 行内容" not in t, t[-120:])

    # =====================================================================
    # item 11：超过 20MB 不给在线预览
    # =====================================================================
    open_file(pg, "v11_big.html")
    t = prev.inner_text()
    chk("item11 ★★ 21MB 的文件不给在线预览，而是明说让下载",
        "超过在线预览上限" in t or "请下载" in t, t[:160])
    chk("item11 ★ 拒绝的时候**没有**渲染 iframe（拒绝了就得真拒绝）",
        prev.locator(".dsapp-preview-frame").count() == 0, t[:160])

    pg.screenshot(path=C.OUT + "/20_preview.png", full_page=True)
    br.close()

sys.exit(chk.done())
