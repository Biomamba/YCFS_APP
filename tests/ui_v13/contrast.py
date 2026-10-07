# -*- coding: utf-8 -*-
"""V13 item 1：**所有**皮肤下，凡是看得见的字都要看得清。

用户的原话：「claude风格下，报错解读和代码都是黑底黑字。其它界面有类似的
问题请一并解决」。

===== 为什么不能靠读 CSS 源码来验 =====

这一条的根因（见 www/codex.css 里那条被改掉的规则）是：

    pre.dsapp-code { background: #010409 }   ← V6 写死的近黑

V6 的时候全站只有深色一套皮，写死没问题；V8 加了 light / claude / apple
三套**浅色**皮之后，底色还是近黑，而字色走的是 `var(--bs-body-color)`
—— claude 下是 #2b2a27，于是黑底黑字。**没有任何报错**，CSS 语法完全合法。

所以这个脚本不查"CSS 里写了什么"，只查**浏览器算出来的最终颜色**：
把每个有文字的元素的 color 和它往上找到的第一层不透明背景拿出来，
按 WCAG 算对比度。判据是算出来的比值，不是源码里的字符串。

===== 为什么要自己去种一段对话 =====

代码块和报错块只在**对话页渲染出内容之后**才存在。不种的话这一整组检查会
一条都跑不到，而"一条都没跑到"和"全部通过"在输出上长得一模一样 ——
tests/ui_v8/skins.py 的注释里记着同一类坑（当时是没有 API Key，消息压根
不落库）。所以这里直接往测试实例的库里写消息：**渲染路径是同一条**，
而这条路不用调模型、不用等、也不会因为模型今天心情不好而变。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, OUT, PAGES, db_path, enter_app, goto,   # noqa: E402
                     seed_or_die, set_skin)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

SKINS = ["dark", "light", "chatgpt", "claude", "apple"]

# ===========================================================================
# 种进库里的那几段内容
# ===========================================================================
# 每一条都对应界面上一种**有自己底色**的块。少写一种，那种块就永远不在
# 扫描范围里 —— 而扫描范围变小是看不出来的。
ASSISTANT_MD = """给你一段可以直接跑的质控代码。

```python
import scanpy as sc
adata = sc.read_10x_mtx("filtered_feature_bc_matrix")
adata.var["mt"] = adata.var_names.str.startswith("MT-")
sc.pp.calculate_qc_metrics(adata, qc_vars=["mt"], inplace=True)
print(adata.obs[["n_genes_by_counts", "pct_counts_mt"]].describe())
```

跑完之后看一眼 `adata.obs` 里的 `pct_counts_mt`。

```bash
ls -lh results/
head -3 results/qc_summary.csv
```

如果要用现成的脚本，`results/qc.R` 那个版本多做了双细胞检测。

| 指标 | 阈值 | 说明 |
|------|------|------|
| n_genes | 200 | 低于这个数的细胞丢掉 |
| pct_counts_mt | 20% | 高于这个数的多半是死细胞 |

> 注意：阈值要按组织类型调，肿瘤样本的线粒体比例普遍偏高。
"""

# 执行结果（失败）。前缀「状态：失败」是 mod_chat.R 判 is_err 的依据，
# 少了它渲染出来的是成功样式 —— 而成功样式和失败样式的底色不一样，
# 这次要量的正是**失败**那一套。
TOOL_FAIL = """【执行结果 · 任务 #1】
状态：失败（退出码 1）
耗时：3.2 秒  ·  环境：scRNA

$ python qc.py
Traceback (most recent call last):
  File "qc.py", line 3, in <module>
    adata = sc.read_10x_mtx("filtered_feature_bc_matrix")
  File "/opt/envs/scRNA/lib/python3.11/site-packages/scanpy/readwrite.py", line 1import
    raise ValueError(f"Directory not found: {path}")
ValueError: Directory not found: filtered_feature_bc_matrix
"""

TOOL_OK = """【执行结果 · 任务 #2】
状态：成功（退出码 0）
耗时：12.7 秒  ·  环境：scRNA

$ python qc.py
        n_genes_by_counts  pct_counts_mt
count         2700.000000      2700.000000
mean          2412.429630         8.413704
"""

# 任务详情页的 stdout/stderr。stderr 那一段渲染成 `pre.dsapp-pre dsapp-pre-err`。
TASK_STDOUT = """开始质控……
2700 个细胞通过过滤
"""

TASK_STDERR = """Traceback (most recent call last):
  File "qc.py", line 3, in <module>
    adata = sc.read_10x_mtx("filtered_feature_bc_matrix")
ValueError: Directory not found: filtered_feature_bc_matrix
"""

# 平台提示（环境类失败）。走的是另一条渲染分支（没有任务行）。
NOTE_ENV = """【平台提示】
状态：失败 —— 环境问题（由平台自动调试）
找不到 Python 包 `scanpy`。当前环境 spRNA 里没有装它，
已把这个报错交给模型，它会自己决定是装包还是换个写法。
"""


def seed(email):
    """往测试实例的库里写一段对话 + 一条任务，返回 (session id, task id)。

    ⚠️ 任务那一条**不是**可有可无的。`pre.dsapp-pre-err`（报错块，红字）只在
       任务详情页的「标准错误」那一段出现（R/mod_tasks.R:555）—— 对话页里
       根本没有这个元素。不种任务的话，点名检查那一组里的"报错块"会以
       "元素不存在"失败，而那是**用例的问题**不是界面的问题；更糟的情况是
       把它从清单里删掉，于是这个选择器从此没人量，而它正是 codex.css 里
       被写死过 #010409 的五个之一。
    """
    uid, p = seed_or_die(email)
    sid = "v13contrast-%s" % uid
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    con = sqlite3.connect(p)
    cur = con.cursor()
    cur.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    cur.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    cur.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id)"
                " VALUES (?,?,?,?,?)",
                (sid, "V13 配色用例", now, now, uid))
    rows = [
        ("user", "帮我看一下这批 10x 数据的质控要怎么做"),
        ("assistant", ASSISTANT_MD),
        ("tool", TOOL_FAIL),
        ("tool", TOOL_OK),
        ("tool", NOTE_ENV),
        ("assistant", "上面的报错是因为目录名不对。**把路径改成绝对路径**再跑一次。"),
    ]
    for role, content in rows:
        cur.execute("INSERT INTO messages (session_id, role, content, created_at)"
                    " VALUES (?,?,?,?)", (sid, role, content, now))

    cur.execute("DELETE FROM tasks WHERE session_id = ?", (sid,))
    cur.execute(
        "INSERT INTO tasks (session_id, title, lang, code, status, exit_code,"
        " stdout, stderr, created_at, started_at, finished_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (sid, "V13 配色用例 · 质控", "Python", "import scanpy as sc\nsc.pp.qc()",
         "failed", 1, TASK_STDOUT, TASK_STDERR, now, now, now))
    tid = cur.lastrowid
    con.commit()
    con.close()
    return sid, tid


# ===========================================================================
# 扫描器
# ===========================================================================
# 全部在浏览器里算 —— 拿回 Python 再算没有意义，反而要重做一遍
# "半透明色合成到底色上"这件事。
SWEEP_JS = r"""
() => {
  const parse = (c) => {
    const m = String(c).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(x => parseFloat(x));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const over = (f, b) => ({
    r: f.r * f.a + b.r * (1 - f.a),
    g: f.g * f.a + b.g * (1 - f.a),
    b: f.b * f.a + b.b * (1 - f.a), a: 1
  });
  const lum = (c) => {
    const f = (v) => { v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  // 往上找第一层**不透明**的底。半透明的底要一层层合成上去，否则算出来
  // 的比值是假的（偏乐观）—— 皮肤里 --bs-*-bg-subtle 那几个正是半透明。
  const effBg = (el) => {
    let stack = [], node = el;
    while (node && node.nodeType === 1) {
      const c = parse(getComputedStyle(node).backgroundColor);
      if (c && c.a > 0) { stack.push(c); if (c.a >= 1) break; }
      node = node.parentElement;
    }
    stack.push({ r: 255, g: 255, b: 255, a: 1 });   // 兜底：白纸
    let base = stack[stack.length - 1];
    for (let i = stack.length - 2; i >= 0; i--) base = over(stack[i], base);
    return base;
  };
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    if (parseFloat(cs.opacity) < 0.15) return false;
    return true;
  };
  // 只取**自己直接持有文字**的元素。取所有后代的话，一个 <div> 会把里面
  // 每个 <span> 的文字都算一遍，同一个问题报十次。
  const directText = (el) => {
    let s = '';
    for (const n of el.childNodes) if (n.nodeType === 3) s += n.nodeValue;
    return s.trim();
  };
  const out = [];
  for (const el of document.querySelectorAll('body *')) {
    const t = directText(el);
    if (!t) continue;
    if (!vis(el)) continue;
    const cs = getComputedStyle(el);
    const fg0 = parse(cs.color);
    if (!fg0) continue;
    const bg = effBg(el);
    const fg = fg0.a < 1 ? over(fg0, bg) : fg0;
    const L1 = lum(fg), L2 = lum(bg);
    const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
    const px = parseFloat(cs.fontSize);
    const bold = (parseInt(cs.fontWeight) || 400) >= 700;
    // WCAG 的"大字号"：>=18.66px 粗体，或 >=24px
    const large = px >= 24 || (bold && px >= 18.66);
    out.push({
      tag: el.tagName.toLowerCase(),
      cls: (el.className && el.className.baseVal !== undefined
            ? el.className.baseVal : String(el.className || '')).slice(0, 90),
      txt: t.replace(/\s+/g, ' ').slice(0, 42),
      ratio: Math.round(ratio * 100) / 100,
      need: large ? 3.0 : 4.5,
      fg: cs.color, bg: 'rgb(' + Math.round(bg.r) + ',' + Math.round(bg.g) +
          ',' + Math.round(bg.b) + ')',
      px: px
    });
  }
  // 最差的排前面：一屏里真正要看的就那么几条
  out.sort((a, b) => (a.ratio / a.need) - (b.ratio / b.need));
  return out;
}
"""


# 单个元素的对比度。和 SWEEP_JS 用的是同一套算式（这里没法抽公共函数：
# 两个都要在浏览器里跑，而 page.evaluate 每次只送一段源码过去）。
# ⚠️ 改了一处必须改另一处，否则"整页扫描通过、点名检查失败"这种自相矛盾的
#    输出会让人以为是元素选错了。
ONE_JS = r"""
(sel) => {
  const el = document.querySelector(sel);
  if (!el) return null;
  const cs = getComputedStyle(el);
  const parse = (c) => {
    const m = String(c).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(x => parseFloat(x));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const over = (f, b) => ({
    r: f.r * f.a + b.r * (1 - f.a),
    g: f.g * f.a + b.g * (1 - f.a),
    b: f.b * f.a + b.b * (1 - f.a), a: 1
  });
  const lum = (c) => {
    const f = (v) => { v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  let stack = [], node = el;
  while (node && node.nodeType === 1) {
    const c = parse(getComputedStyle(node).backgroundColor);
    if (c && c.a > 0) { stack.push(c); if (c.a >= 1) break; }
    node = node.parentElement;
  }
  stack.push({ r: 255, g: 255, b: 255, a: 1 });
  let base = stack[stack.length - 1];
  for (let i = stack.length - 2; i >= 0; i--) base = over(stack[i], base);
  let fg = parse(cs.color);
  if (fg.a < 1) fg = over(fg, base);
  const L1 = lum(fg), L2 = lum(base);
  return {
    ratio: Math.round(((Math.max(L1, L2) + 0.05) /
                       (Math.min(L1, L2) + 0.05)) * 100) / 100,
    fg: cs.color,
    bg: 'rgb(' + Math.round(base.r) + ',' + Math.round(base.g) + ',' +
        Math.round(base.b) + ')'
  };
}
"""


def open_task_detail(page):
    """在任务页点开第一行，把详情展开（报错块只在那儿）。

    ⚠️⚠️ 要点的**不是行，是第一格**（那列复选框）。R/mod_tasks.R:286 写的是
       `select = list(style = "multi", selector = "td:first-child")` ——
       点标题那几列**不会**选中任何东西，而有选中才有详情。第一版点的是
       `tbody tr`，行找到了、点下去了、`tr.selected` 是 0，详情自然不出来，
       而报错只会说"没看到 pre.dsapp-pre-err"，看着像配色的问题。

    ⚠️ 选择器还必须**限定在当前激活的那一页**（.tab-pane.active）。
       bslib 的 navset_hidden 是"所有页都留在 DOM 里、只藏不激活"，文件页
       和任务页**各有一张 DT 表**，两张都在 DOM 里 —— 不限定的话
       `table.dataTable tbody tr` 的 .first 很可能选到文件页那张表的第一行。
    """
    # ⚠️ 要**重试**。任务页挂着一个 1.5 秒的轮询（mod_tasks.R 里那个
    #    observe），它一刷新就把 DT 整张表重画，而重画会**清掉选中** ——
    #    正好点在这一拍上，勾就被吞了。第一版只点一次，五个皮肤里过了三个，
    #    另外两个"没看到 pre.dsapp-pre-err"，看着像配色问题其实是竞态。
    pane = page.locator(".tab-pane.active")
    for attempt in range(3):
        cell = pane.locator("table.dataTable tbody tr td:first-child").first
        if cell.count() == 0:
            print("      （任务页那张表里一行都没有 —— 种子任务没进去？）")
            return
        try:
            cell.click()
        except Exception as e:                      # noqa: BLE001
            print("      （点任务复选框出错：%s）" % e)
        for _ in range(10):
            if page.locator("pre.dsapp-pre-err").count():
                # ⚠️ 出现还不够，得**稳住**再交回去。轮询那一拍随时会把它
                #    重画掉，交回去之后调用方 eval 到的是 null —— 上一版就是
                #    在这儿炸的（`NoneType` is not subscriptable），
                #    而那行报错看着像测试脚本写错了，不像竞态。
                page.wait_for_timeout(1200)
                if page.locator("pre.dsapp-pre-err").count():
                    return
                break
            page.wait_for_timeout(700)
        if attempt < 2:
            print("      （第 %d 次勾选被表格重画吞掉了，重试）" % (attempt + 1))
    print("      （勾了 3 次都没把详情稳定勾出来）")


def sweep(page, label, chk, floor=3.0, quiet_ok=True):
    """扫一遍当前页面，返回 (最差的那条, 全部低于 floor 的条数)。"""
    rows = page.evaluate(SWEEP_JS)
    bad = [r for r in rows if r["ratio"] < floor]
    under_aa = [r for r in rows if r["ratio"] < r["need"]]
    worst = rows[0] if rows else None

    chk("%s：扫到 %d 个有文字的元素" % (label, len(rows)), len(rows) >= 5,
        "一个都没扫到说明页面没渲染出来，后面的结论都不成立")
    chk("%s：没有一处对比度低于 %.1f:1" % (label, floor), not bad,
        "最差的几条：\n" + "\n".join(
            "      %-6s %-34s %-40s %.2f:1  字%s 底%s"
            % (r["tag"], r["cls"], repr(r["txt"]), r["ratio"], r["fg"], r["bg"])
            for r in bad[:8]))
    if quiet_ok and under_aa:
        print("       （提示：%d 处低于 AA 的 4.5:1，但不低于 %.1f —— 不是"
              "本次要修的问题，先记下）" % (len(under_aa), floor))
    return worst


def main():
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--no-sandbox"])
        pg = b.new_page(viewport={"width": 1600, "height": 1000})
        try:
            email = enter_app(pg)
            sid, tid = seed(email)
            print("  种好的对话：%s（含任务 #%s）" % (sid, tid))

            # ⚠️ 种完之后**必须刷新一次**。侧栏那份会话列表是在进应用那一刻
            #    渲染的，而种消息发生在那之后 —— 不刷新的话，列表里根本没
            #    这一行，点不到，后面所有"代码块渲染出来了吗"的断言全灭，
            #    而整页扫描会照常全绿（空页面上当然没有低对比度的字）。
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=30000)
            pg.wait_for_timeout(3000)

            for skin in SKINS:
                print("\n== 皮肤 %s ==" % skin)
                set_skin(pg, skin)

                # ---- 对话页：代码块 / 报错块 / 平台提示 都在这一页 ----
                goto(pg, "chat", 3000)
                # 选中种好的那条对话。会话行上带 data-sid，点它走的是
                # www/app.js 的 dsappPickSession（和用户手点同一条路）。
                #
                # ⚠️ 点完之后必须**真的等消息渲染出来**再量。种进去的消息
                #    是服务端读库、渲染、websocket 推过来的，中间那一拍
                #    量到的是空页面 —— 而空页面"没有任何低对比度元素"，
                #    于是这一整组会全绿。下面那两条 `pre.dsapp-code` /
                #    `.dsapp-tool-body` 的存在性断言就是拦这个的。
                row = pg.locator("[data-sid='%s']" % sid)
                if row.count():
                    row.first.click()
                else:
                    print("      ⚠️ 侧栏里没找到 %s 那一行（可能不在前几个），"
                          "改用直接构造点击" % sid)
                pg.wait_for_timeout(3000)
                for _ in range(20):
                    if pg.locator("pre.dsapp-code").count():
                        break
                    pg.wait_for_timeout(1000)

                body = pg.inner_text("body")
                chk("★（%s）代码块真的渲染出来了" % skin,
                    pg.locator("pre.dsapp-code").count() > 0,
                    "对话没打开或没渲染。页面开头：" + body[:160].replace("\n", " "))
                chk("★（%s）执行结果块真的渲染出来了" % skin,
                    pg.locator(".dsapp-tool-body").count() > 0,
                    "页面开头：" + body[:160].replace("\n", " "))

                # 逐个量那几处**点名要修的**。
                #
                # ⚠️ 这几条是"就算整页扫描因为阈值放宽而放过了、它们也必须
                #    达标"的那些 —— 用户原话里点名的就是代码和报错解读。
                #    4.5:1 是 WCAG AA 对正文的要求，不是随手挑的数。
                for sel, name in [("pre.dsapp-code", "代码块"),
                                  (".dsapp-tool-body", "执行结果块"),
                                  (".dsapp-tool-result", "执行结果卡"),
                                  (".dsapp-tool-head", "执行结果标题"),
                                  (".dsapp-code-head", "代码卡片头"),
                                  (".dsapp-bubble", "消息气泡")]:
                    if pg.locator(sel).count() == 0:
                        chk("（%s）%s 存在" % (skin, name), False, "元素不存在")
                        continue
                    one = pg.evaluate(ONE_JS, sel)
                    chk("★（%s）%s 的对比度 >= 4.5:1（实测 %.2f）"
                        % (skin, name, one["ratio"] if one else -1),
                        one is not None and one["ratio"] >= 4.5,
                        "%s 字色%s 底色%s" % (name, one and one["fg"], one and one["bg"]))

                sweep(pg, "（%s）对话页" % skin, chk)

                # ---- 其余各页 ----
                for p in PAGES:
                    if p == "chat":
                        continue
                    goto(pg, p, 2500)
                    if pg.locator(".dsapp-page").count() == 0 and \
                       pg.locator(".dsapp-shell").count() == 0:
                        chk("（%s）%s 页打开" % (skin, p), False)
                        continue
                    if p == "tasks":
                        open_task_detail(pg)
                        # 报错块只长在任务详情里（见 seed 的注释）。这里先确认
                        # 它真的渲染出来了，否则下面那条"对比度达标"测的是空气。
                        chk("★（%s）任务详情里的报错块渲染出来了" % skin,
                            pg.locator(".tab-pane.active pre.dsapp-pre-err"
                                       ).count() > 0,
                            "点开任务行之后没看到 pre.dsapp-pre-err")
                        if pg.locator("pre.dsapp-pre-err").count():
                            one = pg.evaluate(ONE_JS, "pre.dsapp-pre-err")
                            # 再判一次 None：这里跟上面那次 count() 之间隔着
                            # 一次 IPC，表格的 1.5s 轮询足够把它重画掉。
                            # 下面那句 chk 的文案是**先算好再传进去**的，所以
                            # `one["ratio"]` 为 None 时会**在断言之前**就抛
                            # TypeError —— 报错指向这行文案，看着像脚本写错，
                            # 其实是被测页面在动。空值一律走 `if one else -1`。
                            chk("★（%s）报错块 的对比度 >= 4.5:1（实测 %.2f）"
                                % (skin, one["ratio"] if one else -1),
                                one is not None and one["ratio"] >= 4.5,
                                "字色%s 底色%s" % (one and one["fg"],
                                                  one and one["bg"])
                                if one else "eval 回来是空的（详情被重画了）")
                    sweep(pg, "（%s）%s 页" % (skin, p), chk)

                pg.screenshot(path=os.path.join(OUT, "contrast_%s.png" % skin),
                              full_page=True)
        finally:
            b.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
