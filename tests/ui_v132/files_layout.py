# -*- coding: utf-8 -*-
"""V13.2 item 14：文件管理区的列名要直接跟在面包屑下面。

用户原话：
  「文件管理区的"名称"、"大小"、"修改时间"那些信息应该直接显示在
    「house 文件管理区」那一条的下面」

原来表格上面压着三样东西：拖拽上传区（一个大虚线框）、两行说明、一条 hr，
合计两百多像素。于是"我在哪一层"和"这一层里有什么"要滚动才能对上 ——
而这两件事本来是同一件事的两半。

★ 这条只能量几何：两张卡片里的元素**都在 DOM 里**，`inner_text` 两样都
  读得到，"表格存在"和"面包屑存在"这两条断言在改动前后**都是绿的**。
  要抓的是"中间隔了多少像素"。

顺便钉两件搬动时最容易碰坏的事：
  (a) 上传区现在在表格**下面**（不能只是删掉/藏起来）；
  (b) 拖拽上传仍然能用 —— app.js 的 drop 监听挂在 `.dsapp-dropzone` 上，
      元素搬了位置它跟着走，但一旦谁把类名或层级改了就会**静默失效**
      （浏览器会当成"拖到空白处"，直接打开那个文件、页面跳走）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 量若干元素的矩形 + 它们之间的竖直间距。
#
# ⚠️⚠️ 面包屑和工具栏的 id 在 `uiOutput()` **外面**那层壳上，而 Shiny 给那层
#    壳加了 `display: contents` —— 壳自己**不生成盒子**，`getBoundingClientRect()`
#     对它一律返回 0×0（实测：`#files-crumb` 是 `{top:0,bottom:0,h:0,w:0}`，
#     而它里面的 `.dsapp-crumb-bar` 好好地摆在 y≈150）。
#     第一版就是这么量错的：算出来"隔了 192px"，看着像布局没改成功，
#     其实是被量错了元素。**要量里面的那个真盒子。**
PROBE_JS = r"""
() => {
  const g = (sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return {top: Math.round(r.top), bottom: Math.round(r.bottom),
            h: Math.round(r.height), w: Math.round(r.width)};
  };
  const crumb = g('.dsapp-crumb-bar');            // 见上面那段说明
  const thead = g('#files-tbl thead');
  const tbl   = g('#files-tbl');
  const dz    = g('#files-dropzone');
  // 工具栏同理，量壳里面那个真盒子
  const tools = (() => {
    const w = document.querySelector('#files-tbl_tools');
    if (!w) return null;
    const el = w.firstElementChild;
    if (!el) return {top: 0, bottom: 0, h: 0, w: 0, shell: 'empty'};
    const r = el.getBoundingClientRect();
    return {top: Math.round(r.top), bottom: Math.round(r.bottom),
            h: Math.round(r.height), w: Math.round(r.width)};
  })();
  return {
    crumb: crumb, thead: thead, tbl: tbl, dropzone: dz, tools: tools,
    // 面包屑下沿 → 表头上沿之间隔了多少像素（下面断言量的就是这个）
    gap: (crumb && thead) ? Math.round(thead.top - crumb.bottom) : null,
    // 上传区的上沿 - 表格的下沿：>0 才是"在表格下面"
    dz_below_tbl: (dz && tbl) ? Math.round(dz.top - tbl.bottom) : null,
    // 卡片体里，面包屑壳的**下一个**兄弟是谁 —— 用它证明中间没夹别的东西。
    // ⚠️ 这里量的是**壳**（display:contents 那个），因为要的就是 DOM 顺序；
    //    高度过滤对 contents 壳没意义（它恒为 0），所以不过滤。
    next: (() => {
      const c = document.querySelector('#files-crumb');
      if (!c) return null;
      const n = c.nextElementSibling;
      return n ? (n.id || n.className || n.tagName) : '(没有下一个)';
    })(),
  };
}
"""

with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="文件布局")
    goto(page, "files")
    page.wait_for_timeout(4000)

    m = page.evaluate(PROBE_JS)
    for k in ("crumb", "thead", "tbl", "dropzone", "tools"):
        print("  %-9s %s" % (k, m[k]), flush=True)
    print("  面包屑→表头 %s px ；上传区在表格下方 %s px ；面包屑的下一个兄弟 = %s"
          % (m["gap"], m["dz_below_tbl"], m["next"]), flush=True)

    chk("★ 面包屑和表格都渲染出来了（不然下面量的是空气）",
        bool(m["crumb"] and m["thead"] and m["tbl"]), extra=m)
    chk("★★ 表头紧跟在面包屑下面 —— 中间不超过 90px"
        "（卡片内边距 + DT 外壳那点高度；改之前是 200+）",
        m["gap"] is not None and 0 <= m["gap"] <= 90,
        extra="隔了 %s px" % m["gap"])
    chk("★★ 面包屑的下一个可见兄弟**就是表格**（中间没夹上传区/说明/hr）",
        m["next"] is not None and "tbl" in str(m["next"]).lower(),
        extra="下一个兄弟是 %r" % (m["next"],))
    chk("★★ 上传区还在，而且搬到了**表格下面**",
        m["dropzone"] is not None and m["dz_below_tbl"] is not None
        and m["dz_below_tbl"] > 0,
        extra="上传区 top=%s，表格 bottom=%s"
              % (m["dropzone"] and m["dropzone"]["top"],
                 m["tbl"] and m["tbl"]["bottom"]))
    chk("★ 上传区的两个按钮都还在（上传文件 / 上传文件夹）",
        page.locator("#files-dropzone input[type=file]").count() == 2,
        extra=page.locator("#files-dropzone input[type=file]").count())
    chk("★ 「下载选中」那排工具按钮还在表格下面、上传区上面",
        m["tools"] is not None and m["dropzone"] is not None
        and m["tools"]["top"] >= m["tbl"]["bottom"]
        and m["tools"]["bottom"] <= m["dropzone"]["top"] + 1,
        extra="工具 %s / 上传区 top=%s"
              % (m["tools"] and m["tools"]["bottom"],
                 m["dropzone"] and m["dropzone"]["top"]))

    # ---- 拖拽上传还能用吗 ----
    # ★ 这条是搬动时最容易碰坏的：app.js 靠 `e.target.closest('.dsapp-dropzone')`
    #   找投放目标，再用 `zone.querySelector('input[type=file]')` 拿第一个
    #   input。类名改了、或者文件夹那个 input 被挪到了前面，都会**静默失效**
    #   —— 没有任何报错，表现是"拖进去浏览器直接把文件打开了、页面跳走"。
    #
    # ⚠️ 只造一个 File 塞进去、派发 change，看 input.files 有没有接住。
    #    **不点上传**：这一步验的是"事件能不能落到那个 input 上"，
    #    真的上传是另一回事（而且会往库里写东西）。
    dropped = page.evaluate(r"""
    () => {
      const zone = document.querySelector('#files-dropzone');
      if (!zone) return 'no-zone';
      const input = zone.querySelector('input[type="file"]');
      if (!input) return 'no-input';
      const before = input.files ? input.files.length : 0;
      let dt;
      try { dt = new DataTransfer(); } catch (e) { return 'no-DataTransfer'; }
      dt.items.add(new File(['hello'], 'droptest.txt', {type: 'text/plain'}));
      const ev = new DragEvent('drop', {bubbles: true, cancelable: true,
                                        dataTransfer: dt});
      zone.dispatchEvent(ev);
      return {before: before, after: input.files ? input.files.length : -1,
              name: input.files && input.files[0] ? input.files[0].name : null};
    }
    """)
    print("  拖拽模拟: %s" % (dropped,), flush=True)
    chk("★★ 拖文件到上传区**仍然接得住**（搬位置没把 app.js 那条监听撇下）",
        isinstance(dropped, dict) and dropped["after"] == dropped["before"] + 1
        and dropped["name"] == "droptest.txt",
        extra=dropped)
    # ⚠️ 上一步是直接 dispatch 到 zone 上的。**必须**再验一次"从子元素冒泡上来
    #    也能命中" —— 用户真正拖的时候，target 是 zone 里最里面那个元素
    #    （虚线框里的图标/文字），不是 zone 本身。只测 zone 的话，
    #    哪天谁把 zone 改成"只有 padding 的空壳、内容全在兄弟节点里"，
    #    照样是绿的。
    bub = page.evaluate(r"""
    () => {
      const zone = document.querySelector('#files-dropzone');
      const inner = zone.querySelector('.dsapp-dropzone-icon') || zone;
      const input = zone.querySelector('input[type="file"]');
      let dt; try { dt = new DataTransfer(); } catch (e) { return 'no-DT'; }
      dt.items.add(new File(['x'], 'bubble.txt', {type: 'text/plain'}));
      inner.dispatchEvent(new DragEvent('drop', {bubbles: true,
                            cancelable: true, dataTransfer: dt}));
      return input.files && input.files[0] ? input.files[0].name : null;
    }
    """)
    chk("★★ 从上传区**内部的子元素**拖进来也命中（target 是子元素时的真实路径）",
        bub == "bubble.txt", extra=bub)

    # 顺带：文案不能说没有的路。原来那句「也可以直接拖进文件夹行」是假的。
    dztext = page.inner_text("#files-dropzone")
    print("  上传区文字: %r" % dztext[:120], flush=True)
    chk("★ 上传区里不再宣称「拖进文件夹行」（那条路 app.js 里没有实现）",
        "拖进文件夹行" not in dztext, extra=repr(dztext[:120]))

    page.screenshot(path=OUT + "/files_layout.png", full_page=True)
    br.close()

sys.exit(chk.done())
