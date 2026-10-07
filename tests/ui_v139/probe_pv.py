# -*- coding: utf-8 -*-
"""一次性探针：「文件页里工作区那一行的『预览』到底点不点得着」。

    /home/biomamba/miniconda3/bin/python tests/ui_v139/probe_pv.py

★ 为什么值得单独写一个：v139.py 跑到 item 4 要三分多钟，而这一颗的失败
  信息（Playwright 的 hit-test 报告）**只说"被谁挡住了"，不说"为什么"**。
  这里把滚动前后、以及各祖先的盒子和可滚性一次性打全，看清楚是
  ①被页脚压住（测试的事）、②被祖先的 overflow 裁掉（版面的事）、还是
  ③压根就有两个同名元素、点的是隐藏的那个（选择器的事）。
"""
import base64
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import *            # noqa: F401,F403
from _common import DATA_ROOT, EMAIL, OUT, URL, db_path   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

# ⚠️ **不能** `from v139 import seed_session` —— v139.py 的测试主体写在模块
#    级的 `with sync_playwright()` 里（它不是库，是一支脚本），import 会把
#    整支验收从头跑一遍，然后探针才开始跑。所以这里把那两个塞库的小函数
#    抄一份（和 _common.py 一样，共用的思路不是共用的文件）。
PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ"
    "DwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
_SEQ = 0


def seed_session(uid, title, n_turns, files=()):
    import sqlite3
    global _SEQ
    _SEQ += 1
    sid = "p-%s-%04d" % (time.strftime("%Y%m%d%H%M%S"), _SEQ)
    con = sqlite3.connect(db_path())
    con.execute("INSERT INTO sessions (id, user_id, title, created_at, "
                "updated_at) VALUES (?,?,?,datetime('now'),datetime('now'))",
                (sid, uid, title))
    for k in range(1, n_turns + 1):
        con.execute("INSERT INTO messages (session_id, role, content, "
                    "created_at) VALUES (?,?,?,datetime('now'))",
                    (sid, "user", "探针第 %d 轮" % k))
        con.execute("INSERT INTO messages (session_id, role, content, "
                    "created_at, reasoning) VALUES (?,?,?,datetime('now'),?)",
                    (sid, "assistant", "探针回复 %d" % k, None))
    con.commit()
    con.close()
    d = os.path.join(DATA_ROOT, "workspaces", "chat-" + sid)
    os.makedirs(d, exist_ok=True)
    for rel in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(PNG_1PX)
    return sid

JS = """() => {
  const out = {rows: [], scrollBoxes: []};
  const rows = [...document.querySelectorAll('.dsapp-wsrow')];
  rows.forEach((r, i) => {
    const rb = r.getBoundingClientRect();
    const vis = r.offsetParent !== null;
    const a = [...r.querySelectorAll('.dsapp-wsrow-act a')]
      .map(x => ({t: x.innerText.trim(), href: x.getAttribute('href'),
                  box: [Math.round(x.getBoundingClientRect().top),
                        Math.round(x.getBoundingClientRect().bottom),
                        Math.round(x.getBoundingClientRect().left),
                        Math.round(x.getBoundingClientRect().right)]}));
    out.rows.push({i, vis, txt: r.innerText.replace(/\\n/g, ' | ').slice(0, 60),
                   box: [Math.round(rb.top), Math.round(rb.bottom)],
                   display: getComputedStyle(r).display, acts: a});
  });
  // 从第一个可见的 wsrow 往上走，记录每一层的盒子 + 可滚性 + overflow
  const first = rows.find(r => r.offsetParent !== null);
  if (first) {
    let p = first;
    while (p && p !== document.documentElement) {
      const s = getComputedStyle(p), b = p.getBoundingClientRect();
      out.scrollBoxes.push({
        cls: (p.className || p.tagName).toString().slice(0, 45),
        box: [Math.round(b.top), Math.round(b.bottom)],
        h: Math.round(b.height),
        ov: s.overflow, oy: s.overflowY, pos: s.position,
        sh: p.scrollHeight, ch: p.clientHeight,
        scrollable: p.scrollHeight > p.clientHeight + 1,
        st: p.scrollTop
      });
      p = p.parentElement;
    }
  }
  out.vh = window.innerHeight;
  return out;
}"""


def dump(pg, tag):
    d = pg.evaluate(JS)
    print("\n---- %s ---- 视口高=%d" % (tag, d["vh"]), flush=True)
    for r in d["rows"]:
        print("  wsrow[%d] vis=%s disp=%s box=%s  %s" %
              (r["i"], r["vis"], r["display"], r["box"], r["txt"]), flush=True)
        for a in r["acts"]:
            print("      a %-4s box=%s" % (a["t"], a["box"]), flush=True)
    for b in d["scrollBoxes"]:
        print("  祖先 %-45s box=%-14s h=%-5s ov=%-7s/%s pos=%-8s "
              "sh=%d ch=%d 可滚=%s st=%d" %
              (b["cls"], b["box"], b["h"], b["ov"], b["oy"], b["pos"],
               b["sh"], b["ch"], b["scrollable"], b["st"]), flush=True)
    return d


with sync_playwright() as pw:
    br = pw.chromium.launch(headless=True)
    pg = br.new_page(viewport={"width": 1600, "height": 950})
    pg.goto(URL, wait_until="domcontentloaded")
    enter_app(pg)
    uid = seed_or_die(EMAIL)[0]
    sid = seed_session(uid, "探针对话", 2,
                       files=["qc_violin.png", "results/umap.png"])
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(6000)
    goto(pg, "files", wait=4000)
    pg.wait_for_timeout(2000)
    pg.screenshot(path=OUT + "/probe_0_before.png", full_page=True)
    dump(pg, "切到文件页、什么都没滚")

    loc = pg.locator(".dsapp-wsrow").filter(has_text="qc_violin.png") \
        .first.locator(".dsapp-wsrow-act a", has_text="预览").first
    print("\n  locator 命中 %d 个" % loc.count(), flush=True)
    try:
        loc.scroll_into_view_if_needed(timeout=5000)
        print("  scroll_into_view_if_needed 成功", flush=True)
    except Exception as e:
        print("  scroll_into_view_if_needed 失败：%s" % str(e)[:200], flush=True)
    dump(pg, "Playwright 滚过之后")

    pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.innerText.indexOf('qc_violin') >= 0 && x.offsetParent !== null);
      r.scrollIntoView({block: 'center'});
    }""")
    pg.wait_for_timeout(400)
    pg.screenshot(path=OUT + "/probe_1_after_scroll.png", full_page=True)
    d = dump(pg, "自己 scrollIntoView({block:center}) 之后")

    # 直接问浏览器：这颗链接的中心点上是谁
    print("\n  elementFromPoint 命中：", pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.innerText.indexOf('qc_violin') >= 0 && x.offsetParent !== null);
      const a = [...r.querySelectorAll('.dsapp-wsrow-act a')]
        .find(x => x.innerText.trim() === '预览');
      const b = a.getBoundingClientRect();
      const cx = Math.round(b.left + b.width / 2), cy = Math.round(b.top + b.height / 2);
      const e = document.elementFromPoint(cx, cy);
      return {cx, cy, hit: e ? (e.tagName + '.' + (e.className||'').toString().slice(0,50)) : null,
              isSelf: e === a};
    }"""), flush=True)

    print("\n  真点一次（15 秒超时）：", flush=True)
    try:
        loc.click(timeout=15000)
        print("    点成功", flush=True)
    except Exception as e:
        print("    点失败：%s" % str(e)[:400], flush=True)
    pg.wait_for_timeout(3000)
    print("  modal 数=%d" % pg.locator(".modal").count(), flush=True)
    pg.screenshot(path=OUT + "/probe_2_after_click.png", full_page=True)

    # =====================================================================
    # 第二段：**照着 v139.py 的走法再走一遍**。
    #
    # 第一段（直接 goto 文件页）点得着；v139.py 是**从言出法随点
    # 「在文件页管理 →」过来的**，而且前面还塞了第二个对话和三个上传文件。
    # 两边的差别只有这些，所以这里把差别补齐 —— 如果这一段也点得着，
    # 那 v139.py 那次失败就是当时那个时刻的一次性状态（要在测试里做兜底）；
    # 如果这一段点不着，说明是"从对话页过来"这条路把版面搞坏了，是**真 bug**。
    # =====================================================================
    print("\n\n======== 第二段：照 v139.py 的走法 ========", flush=True)
    pg.click(".modal .btn-close, .modal [data-bs-dismiss='modal']", timeout=5000) \
        if pg.locator(".modal [data-bs-dismiss='modal']").count() else None
    pg.wait_for_timeout(1000)

    seed_session(uid, "探针乙对话", 2, files=["other_only.png"])
    d = os.path.join(DATA_ROOT, "files", "u%d" % uid)
    for nm in ["probe_up_1.txt", "probe_up_2.txt", "probe_up_3.txt"]:
        with open(os.path.join(d, nm), "w") as fh:
            fh.write("占位\n")
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(6000)
    goto(pg, "chat", wait=4000)
    try:
        pg.click(".dsapp-artifacts .card-header a", timeout=15000)
        print("  点了「在文件页管理 →」", flush=True)
    except Exception as e:
        print("  没点着「在文件页管理 →」：%s" % str(e)[:200], flush=True)
    pg.wait_for_timeout(4000)
    dump(pg, "从对话页过来之后（v139.py 的处境）")

    loc2 = pg.locator(".dsapp-wsrow").filter(has_text="qc_violin.png") \
        .first.locator(".dsapp-wsrow-act a", has_text="预览").first
    print("\n  locator 命中 %d 个" % loc2.count(), flush=True)
    try:
        loc2.scroll_into_view_if_needed(timeout=5000)
        print("  scroll_into_view_if_needed 成功", flush=True)
    except Exception as e:
        print("  scroll_into_view_if_needed 失败：%s" % str(e)[:200], flush=True)
    dump(pg, "滚过之后")
    pg.screenshot(path=OUT + "/probe_3_via_chat.png", full_page=True)
    try:
        loc2.click(timeout=15000)
        print("    点成功", flush=True)
    except Exception as e:
        print("    点失败：%s" % str(e)[:400], flush=True)
    pg.wait_for_timeout(2500)
    print("  modal 数=%d" % pg.locator(".modal").count(), flush=True)
    pg.screenshot(path=OUT + "/probe_4_via_chat_clicked.png", full_page=True)

    # =====================================================================
    # 第三段：**量出生它的那几条 CSS**，再当场试着补一条看看能不能救活。
    #
    # 到这一步症状已经清楚了：整张「本对话产物」卡被压成 2px，内容全在
    # 卡片外面（被 .bslib-card{overflow:auto} 裁掉），所以那一行里的
    # 「预览」永远点不着。剩下要回答的只有一句：**是谁允许它被压扁的**。
    # 猜是没用的（fill 那一套的类名和实际生效的规则经常不是一回事），
    # 所以把链上每一层的 computed style 直接打出来。
    # =====================================================================
    print("\n\n======== 第三段：链上每一层的 computed style ========", flush=True)
    print(pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.offsetParent !== null);
      let p = r, out = [];
      while (p && p.tagName !== 'HTML') {
        const s = getComputedStyle(p), b = p.getBoundingClientRect();
        out.push([(p.tagName + '.' + (p.className || '')).slice(0, 52),
                  'disp=' + s.display,
                  'flex=' + s.flexGrow + '/' + s.flexShrink + '/' + s.flexBasis,
                  'minH=' + s.minHeight,
                  'h=' + s.height,
                  'ov=' + s.overflowY,
                  'rect=' + Math.round(b.height)]);
        p = p.parentElement;
      }
      return out.map(x => '  ' + x.join('  ')).join('\\n');
    }"""), flush=True)

    cards = pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.offsetParent !== null);
      let p = r, out = [];
      while (p && p.tagName !== 'HTML') {
        if (p.classList.contains('card'))
          out.push({h: Math.round(p.getBoundingClientRect().height),
                    parent: (p.parentElement.tagName + '.' +
                             (p.parentElement.className || '')).slice(0, 60),
                    sh: p.scrollHeight, ch: p.clientHeight});
        p = p.parentElement;
      }
      return out;
    }""")
    print("  卡片本身：%s" % cards, flush=True)
    h_before = cards[0]["h"] if cards else -1

    print("\n  ---- 当场补一条 flex-shrink:0 看看 ----", flush=True)
    pg.add_style_tag(content="""
      .dsapp-main-body > .tabbable > .tab-content >
        .tab-pane.active:not(:has(.dsapp-chat-page)) > .shiny-html-output,
      .dsapp-main-body > .tabbable > .tab-content >
        .tab-pane.active:not(:has(.dsapp-chat-page)) > .shiny-html-output > .card,
      .dsapp-main-body > .tabbable > .tab-content >
        .tab-pane.active:not(:has(.dsapp-chat-page)) > .shiny-html-output > .bslib-grid
      { flex: 0 0 auto; }
    """)
    pg.wait_for_timeout(600)
    d3 = dump(pg, "补了 flex-shrink:0 之后")
    cards2 = pg.evaluate("""() => {
      const r = [...document.querySelectorAll('.dsapp-wsrow')]
        .find(x => x.offsetParent !== null);
      let p = r, out = [];
      while (p && p.tagName !== 'HTML') {
        if (p.classList.contains('card'))
          out.push(Math.round(p.getBoundingClientRect().height));
        p = p.parentElement;
      }
      return out;
    }""")
    print("  卡片高度：补之前 %s → 补之后 %s" % (h_before, cards2), flush=True)
    loc3 = pg.locator(".dsapp-wsrow").filter(has_text="other_only.png") \
        .first.locator(".dsapp-wsrow-act a", has_text="预览").first
    try:
        loc3.click(timeout=8000)
        print("  ✓ 补了之后点得着了", flush=True)
    except Exception as e:
        print("  ✗ 补了之后还是点不着：%s" % str(e)[:200], flush=True)
    pg.wait_for_timeout(2500)
    print("  modal 数=%d" % pg.locator(".modal").count(), flush=True)
    pg.screenshot(path=OUT + "/probe_5_after_css_fix.png", full_page=True)
    print("  截图在 " + OUT, flush=True)
    br.close()
