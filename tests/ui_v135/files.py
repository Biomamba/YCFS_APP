# -*- coding: utf-8 -*-
"""V13.5 item 4：文件管理区的勾选小方块换成「去预览」按钮。

> 4、文件管理把勾选用的小方块换成"去预览"按钮

★ 为什么只能在这里验：

  这一条改完之后，**多选并没有消失，只是换了手势** —— 方框没了，改成
  "点行内任意位置 = 勾上这一行"。而"勾选还在不在"完全是个浏览器里的事：

    * `input$tbl_rows_selected` 是 Select 扩展**在浏览器里**算出来再报给
      服务端的。"下载选中" / "删除（N 项）"两个按钮上的数字就是它。
      服务端代码一个字都没改，照样可能全绿，而按钮永远停在「0 项」。

    * ⚠️ 勾选**不能**走服务端。`DT::selectRows(proxy, i)` 在这张表上永远
      不生效而且**不报错**（`selection = "none"` 时 DT 压根不定义
      methods.selectRows，消息落到 `console.log("Unknown method")` 那一支
      —— 是 log 不是 error）。所以「去预览」的勾选是 app.js 里用 Select
      扩展自己的 API 做的。这条只有真的点一下才知道。

    * 还有一条肉眼可见但 R 里看不出来的：第 0 列**不能**再挂
      `select-checkbox` 类名 —— 挂着的话 Select 扩展会往里画一个 ::before
      的空方框，和「去预览」四个字**叠在一起**。这里量的是那一格的实际
      内容宽度和有没有 ::before。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import APP, Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

C = Chk()

# ⚠️⚠️ 表的选择器一律带 `:visible`，**不能**裸写 `.dsapp-dt-nowrap`。
#    任务页和文件页是 bslib 的 navset，**两页的表同时躺在 DOM 里**，不活跃
#    的那页只是 `display:none`。任务页排在前面，所以裸选择器在文件页上量到的
#    是**藏起来的任务表**：
#      * `rows.count()` 把藏着的那些行也数进去 → "行数 1" 看着像上传没成功；
#      * `.first` 拿到的是藏表的第 0 格 → 「去预览」那几条全都在验另一张表。
#    2026-09-17 就是这么白跑一轮的。`:visible` 是 Playwright 自己的伪类。
DT = ".dsapp-dt-nowrap:visible table.dataTable"

# ⚠️⚠️ `:visible` 是 **Playwright 自己的**伪类：`page.locator()` 认，
#    **`document.querySelector()` 不认** —— 传进去不是"找不到返回 null"那么
#    温和，而是直接 `SyntaxError: '...:visible ...' is not a valid selector`，
#    把整个脚本打断（2026-09-17 就是这么断的）。所以 evaluate 里那两处不能
#    复用 DT，走下面这段自己挑「第一个宽度 > 0 的表的第一个格子」。
VIS_TD = """() => {
  var ws = document.querySelectorAll('.dsapp-dt-nowrap');
  for (var i = 0; i < ws.length; i++) {
    if (!(ws[i].getBoundingClientRect().width > 0)) continue;
    var t = ws[i].querySelector('table.dataTable tbody tr td');
    if (t) return t;
  }
  return null;
}"""

TOOLS = "#files-tbl_tools"     # output$tbl_tools：动作条（下载/删除…）+ 下面那行说明
PREVIEW = "#files-preview"     # output$tbl_tools 右边那栏的预览


def sel_rows(page):
    """`input$tbl_rows_selected` —— Select 扩展**在浏览器里**算出来、报给服务端的
    那个值（1-based 行号）。这才是这条要验的链路终点。

    ⚠️⚠️ 为什么不能像原来那样去读按钮上的「（N 项）」：**那个数字只在 n ≥ 2 时
    才出现**。`R/mod_files.R` 的 `output$tbl_tools` 里写得很清楚 ——
    n == 1 且是文件时，下载按钮叫「下载 <文件名>」，删除按钮就叫「删除」，
    **一个数字都没有**。而「去预览」这个手势按设计就是"清空再只选这一行"，
    所以它永远只到 n == 1 —— 用「（N 项）」当判据，等于**这条测试永远读不到
    自己刚做出来的那个状态**，报出来是"按钮上的数字 []"（一个都没匹配上，
    不是 0），看着像功能坏了。2026-09-17 白跑两轮，最后是**截图**里
    行高亮着、右栏预览也对，才发现坏的是判据不是功能。
    """
    return page.evaluate("""() => {
      var v = window.Shiny && Shiny.shinyapp && Shiny.shinyapp.$inputValues;
      if (!v) return null;
      var k = Object.keys(v).filter(function (x) { return /_rows_selected$/.test(x); });
      return k.length ? v[k[0]] : null;
    }""")


def tools_text(page):
    """动作条上的可见文字（按钮标签 + 下面那行说明）。

    它和 sel_rows 是**两个不同环节**：sel_rows 断的是"Select 扩展 → Shiny"，
    这里断的是"Shiny → 用户看得见"。n == 1 时它会变成「下载 <文件名>」，
    正好能验"选中的是不是我点的那一行"。
    """
    return page.evaluate(
        "(s) => { var e = document.querySelector(s);"
        " return e ? e.innerText.replace(/\\s+/g, ' ').trim() : ''; }", TOOLS)


def preview_text(page):
    """右栏预览区的文字。"""
    return page.evaluate(
        "(s) => { var e = document.querySelector(s);"
        " return e ? e.innerText.replace(/\\s+/g, ' ').trim() : ''; }", PREVIEW)


with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: m.type == "error" and errors.append(m.text))

    email = enter_app(page)
    seed_or_die(email)
    goto(page, "files")

    # ---- 先造几个真文件：这张表空着的话下面每条都是空转 -------------------
    import time
    for i in (1, 2, 3):
        # ⚠️ 必须写**具体的 id**，不能写 `input[type=file]`：这一页上有
        #    **两个** file input（单文件 + 文件夹），选择器匹配到多个时
        #    Playwright 不会报错、也**不会**上传 —— 表一直是空的，看起来像
        #    "上传坏了"。2026-09-17 就是这么白跑了一轮。
        page.set_input_files("#files-upload",
                             {"name": "v135_%d.txt" % i,
                              "mimeType": "text/plain",
                              "buffer": ("hello %d\n" % i).encode()})
        page.wait_for_timeout(2500)
    page.wait_for_timeout(1500)

    rows = page.locator(DT + " tbody tr")
    C("（前置）文件管理区里至少有 3 行（表是空的 = 下面全是空转）",
      rows.count() >= 3, "行数 %d" % rows.count())

    # ---- 第 0 列现在是「去预览」四个字，不是空方框 ------------------------
    cell = page.locator(DT + " tbody tr td").first
    C("★★ 第 0 列写的是「去预览」",
      cell.inner_text().strip() == "去预览", repr(cell.inner_text()))
    C("★★ 第 0 列挂的是 dsapp-dt-btn，不是 select-checkbox"
      "（挂着的话会叠一个空方框在四个字上面）",
      "dsapp-dt-btn" in (cell.get_attribute("class") or "") and
      "select-checkbox" not in (cell.get_attribute("class") or ""),
      cell.get_attribute("class"))
    # ⚠️ ::before 就是 Select 扩展画方框用的那个伪元素。它不占布局宽度
    #    （content 是 ""），所以只能直接问浏览器有没有这条规则。
    C("★★ 那一格上没有 ::before 的空方框（Select 扩展画的那个）",
      not page.evaluate("""() => {
        var td = (VIS_TD_FN)();
        if (!td) return false;
        var c = getComputedStyle(td, '::before').content;
        return c && c !== 'none' && c !== 'normal';
      }""".replace("VIS_TD_FN", VIS_TD)), "::before content")
    # 用户得**一眼看出能点**：它取代的是一个方框，方框的"可点"是约定俗成
    # 的，一行光秃秃的文字不是。所以必须有可见的边框或底色。
    C("★ 「去预览」看着像按钮（有底色/描边，不是一行光秃秃的字）",
      page.evaluate("""() => {
        var td = (VIS_TD_FN)();
        if (!td) return false;
        var cs = getComputedStyle(td);
        return cs.cursor === 'pointer' &&
               (cs.boxShadow !== 'none' || cs.backgroundColor !== 'rgba(0, 0, 0, 0)');
      }""".replace("VIS_TD_FN", VIS_TD)))

    # ---- 点一下：只勾这一行，而且预览的是**这一行** -----------------------
    n0 = sel_rows(page)
    C("（前置）一开始没有选中项（input$tbl_rows_selected 应当是空的）",
      not n0, "input$tbl_rows_selected = %s" % (n0,))

    def name_of(i):
        """表里第 i 行的文件名（第 1 格；第 0 格现在是「去预览」）。"""
        return rows.nth(i).locator("td").nth(1).inner_text().strip()

    # 点第 2 行（不是第 1 行）—— 点第 1 行的话"选中的是第一行"和"选中的是
    # 被点的那一行"分不出来，而"点第二行看到第一行内容"正是这条要防的形态。
    nm2 = name_of(1)
    rows.nth(1).locator("td").first.click()
    page.wait_for_timeout(2200)

    C("★★ 点「去预览」之后 input$tbl_rows_selected 变成 [2]（= 勾选真的"
      "传到了服务端，这就是「勾选没丢」）",
      sel_rows(page) == [2], "input$tbl_rows_selected = %s" % (sel_rows(page),))
    # 光有行号还不够：行号对了、内容取错了也有可能。按钮标签里会带上文件名，
    # 正好把"选中的到底是哪一行"一并钉死。
    C("★★ 动作条上写的是**被点那一行**的文件名（%s）" % nm2,
      ("下载 %s" % nm2) in tools_text(page), tools_text(page))

    # Select 扩展是**切换**语义：同一个文件点两次会把勾取消掉，预览反而空了。
    # app.js 那边用"先全清再选这一行"把它做成了幂等。
    rows.nth(1).locator("td").first.click()
    page.wait_for_timeout(2200)
    C("★★ 同一个文件点两次仍然是 [2]（切换语义没被漏掉 → 预览不会空）",
      sel_rows(page) == [2], "input$tbl_rows_selected = %s" % (sel_rows(page),))

    # 换一行：必须**只剩**新点的这一行。不清的话服务端 selected() 取的是
    # "行号最小的那条"，用户点第 3 行会看到第 1 行的内容。
    nm3 = name_of(2)
    pv_before = preview_text(page)
    rows.nth(2).locator("td").first.click()
    page.wait_for_timeout(2200)
    C("★★ 换一行之后是 [3] 而不是 [2, 3]（不清的话用户点第 3 行会看到第 1 行）",
      sel_rows(page) == [3], "input$tbl_rows_selected = %s" % (sel_rows(page),))
    C("★ 右栏的预览跟着换成了第 3 个文件的内容（换了行而预览不动 = 点的是"
      "「上一行」）",
      "hello 3" in preview_text(page) and preview_text(page) != pv_before,
      "预览区：%r" % (preview_text(page)[:80],))
    C("★ 动作条也跟着换成第 3 行的文件名（%s）" % nm3,
      ("下载 %s" % nm3) in tools_text(page), tools_text(page))

    # ---- 表头那个"全选"方框要留着（批量下载/删除全靠它）------------------
    th0 = page.locator(DT + " thead th").first
    C("★ 表头的「全选」方框保留了（去掉的话一次删十个文件得点十下）",
      page.locator(DT + " thead th.select-checkbox, " + DT +
                   " thead th input[type=checkbox]").count() >= 1 or
      "select-checkbox" in (th0.get_attribute("class") or ""),
      "th class=%s" % th0.get_attribute("class"))

    C("★★ 整场没有 JS 报错", not errors, "\n".join(errors[:4]))
    page.screenshot(path=OUT + "/files.png", full_page=True)
    b.close()

sys.exit(C.done())
