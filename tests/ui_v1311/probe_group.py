# -*- coding: utf-8 -*-
"""item 11 验收：执行历史按「对话 → 里面的每一步」两级展示。

用户原话：
  11、历史任务也按任务标题名称和内部执行的具体任务进行分级展示

改之前：一条对话里 agent 跑的十几步一步一行平铺在表里，标题那半截会话名
还每行重复一遍 —— "上周那个跑失败的是哪一步"只能一行行读。

改之后：同一个对话的任务聚在一起，每组第一行**兼任组标题**（「对话」那列
写着会话名），其余行一个 └。不插假行 —— 这一页所有批量操作都按行号回查
tasks()，插一行就会让"点第 3 行删掉第 4 条"。

这一条真的在浏览器里验：种两个对话共 6 条任务 → 打开执行历史 →
看组是不是挨着的、组标题写没写会话名、└ 有没有、
**关掉开关能不能回到平铺**、以及最要紧的 **勾选/删除认的还是不是同一条**。

⚠️ 为什么必须种数据：真跑一轮要一把能用的 API Key，而且模型每次跑的步数
   都不一样（这一条测的是分组，不是模型）。tasks 表全是明文，可以直接写。
"""
import sqlite3
import sys
import time

sys.path.insert(0, "/data3/biomamba/analysis/DS_App/tests/ui_v1311")
from _common import *            # noqa: F401,F403
from _common import URL, enter_app, seed_or_die, goto, set_skin   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

FAILS = []


def C(name, cond, extra=""):
    print("  %s %s%s" % ("OK  " if cond else "★★★失败★★★", name,
                         ("   [%s]" % extra) if extra else ""), flush=True)
    if not cond:
        FAILS.append(name)


# 两个对话。会话名故意一个长一个短 —— 标题尾巴上拼的是会话名的**前 24 字**，
# 长短两种都得能去掉。
SESS_A = "帮我做一下ANGPTL2-LILRB2这两个基因"
SESS_B = "重新跑一遍富集分析"
SESS_C = "单独问一句"          # 只有一步，不该写「（1 个任务）」

TASKS = [
    # (session_key, 功能名, status)  —— 种进去的顺序**故意和分组顺序相反**，
    # 因为 db_tasks_list 给的是 ORDER BY id DESC（新的在上、会话交错），
    # 平铺视图正是那个样子。分组要把它掰回来。
    ("C", "随便答一句", "success"),
    ("A", "装环境", "success"),
    ("B", "取表达矩阵", "failed"),
    ("A", "差异分析", "success"),
    ("A", "富集分析", "running"),
    ("B", "画火山图", "success"),
]


def make_title(feat, sess):
    """照 dsapp_task_title 的规则拼标题（见 R/utils.R）。

    ⚠️ 必须**照抄**那个规则，不能图省事写成 feat + "_" + sess：
       模块比的是 `"_" + substr(sess, 1, 24)`，而 dsapp_task_title 拼进去的
       是 `substr(feat, 1, 23) + "_" + substr(sess, 1, 24)`（max = 48，
       half = 24）。拼错的话去尾那一步会**静默不生效**（对不上后缀就原样留
       着），而探针会红在"标题里还有会话名"上 —— 指的地方是错的。
    """
    max_, half = 48, 24
    return (feat[:max_ - half - 1] + "_" + sess[:half])[:max_]


def seed(db, uid):
    """种三个对话、六条任务。返回 (key->sid, 按 id 升序的 id 列表)。"""
    con = sqlite3.connect(db)
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    names = {"A": SESS_A, "B": SESS_B, "C": SESS_C}
    sids = {}
    for k, name in names.items():
        sid = "probe11-%s" % k
        con.execute("DELETE FROM tasks WHERE session_id = ?", (sid,))
        con.execute("DELETE FROM sessions WHERE id = ?", (sid,))
        con.execute("INSERT INTO sessions (id, title, created_at, updated_at,"
                    " user_id) VALUES (?,?,?,?,?)", (sid, name, now, now, uid))
        sids[k] = sid
    # ⚠️ 每条的 created_at 递增，保证 id 顺序和 TASKS 里的顺序一致 ——
    #    探针下面靠"哪一组在前面"来判断重排对不对，顺序不能是随机的。
    ids = []
    for i, (k, feat, st) in enumerate(TASKS):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() + i))
        cur = con.execute(
            "INSERT INTO tasks (session_id, title, lang, code, status,"
            " created_at, finished_at) VALUES (?,?,?,?,?,?,?)",
            (sids[k], make_title(feat, names[k]), "R", "cat('x')\n", st, ts,
             ts if st != "running" else None))
        ids.append(cur.lastrowid)
    con.commit()
    con.close()
    return sids, ids


# 我们种的那几条任务，靠**功能名**认（标题里一定含着它，两种视图下都在）。
#
# ⚠️ 不能靠「对话」那一列认。第一版写的是 `c in (SESS_A, SESS_B, SESS_C)` ——
#    那是**元组成员判断**（全等），而组标题那一格写着「会话名（3 个任务）」，
#    全等不成立，于是两条组标题被过滤器悄悄丢掉了，看起来像"分组把行弄丢了"。
#    而且平铺视图下那一列整个是空的，同样的过滤器会把**所有**行都丢掉。
FEATS = [t[1] for t in TASKS]


def rows(pg):
    """表体每一行的 (class, 各格文字)。"""
    return pg.evaluate("""() => {
        var t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
        if (!t) return null;
        return [...t.querySelectorAll('tbody tr')].map(r => ({
            cls: r.className,
            cells: [...r.cells].map(c => (c.innerText || '').trim())
        }));
    }""")


def pick(rs, tcol):
    """只留我们种的那几条（用户可能是复用的账号，库里还有别的任务）。"""
    return [r for r in rs if any(f in r["cells"][tcol] for f in FEATS)]


def col(rs, i):
    return [r["cells"][i] for r in rs]


def heads(pg):
    """表头文字。"""
    return pg.evaluate("""() => {
        var t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
        if (!t) return null;
        return [...t.querySelectorAll('thead th')].map(x => (x.innerText || '').trim());
    }""")


with sync_playwright() as pw:
    br = pw.chromium.launch(args=["--no-sandbox"])
    pg = br.new_context(viewport={"width": 1600, "height": 1000}).new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("console", lambda m: errs.append("console.error: " + m.text[:200])
          if m.type == "error" else None)

    email = enter_app(pg)
    uid, db = seed_or_die(email)
    print("登录成功：%s (uid=%s)" % (email, uid), flush=True)

    sids, ids = seed(db, uid)
    print("   种了 3 个对话 / %d 条任务 id=%s" % (len(ids), ids), flush=True)
    print("   A=%s（3 步）  B=%s（2 步）  C=%s（1 步）"
          % (sids["A"], sids["B"], sids["C"]), flush=True)

    # 期望的行序，直接从 seed 拿到的 id 推出来，不写死数字。
    # TASKS 里第 i 条的 id 是 ids[i]。
    g_a, g_b, g_c = [ids[1], ids[3], ids[4]], [ids[2], ids[5]], [ids[0]]
    # 分组：组间按组里**最新那条**倒序（B 最新 6 > A 最新 5 > C 最新 1），
    # 组内按 id **升序**（执行顺序）。组标题就是每组的第一条。
    want_grouped = g_b + g_a + g_c
    # 平铺：回到 ORDER BY id DESC
    want_flat = sorted(ids, reverse=True)
    print("   期望：分组 %s / 平铺 %s" % (want_grouped, want_flat), flush=True)

    pg.reload()
    pg.wait_for_timeout(4000)
    goto(pg, "tasks")
    pg.wait_for_timeout(3000)

    # ---- (a) 表头多了「对话」这一列 --------------------------------------
    print("\n== (a) 表头 ==", flush=True)
    hs = heads(pg)
    print("   %s" % hs, flush=True)
    C("★★★ 表头里有「对话」这一列（原来只有 ID/标题/…）",
      hs is not None and "对话" in hs)
    C("★ 「对话」排在 ID 后面、标题前面",
      hs is not None and hs.index("对话") == hs.index("ID") + 1)

    tcol, icol, ccol = hs.index("标题"), hs.index("ID"), hs.index("对话")

    # ---- (b) 分组：同组的行挨着，组标题写会话名 ---------------------------
    print("\n== (b) 分组视图 ==", flush=True)
    rs = rows(pg)
    mine = pick(rs, tcol)
    for r in mine:
        print("   [%s] %s" % (r["cls"].replace("odd ", "").replace("even ", ""),
                              " | ".join(r["cells"])), flush=True)

    C("★★★ 六条任务都在表里（分组不许把谁弄丢）",
      len(mine) == len(TASKS), "看到 %d 条" % len(mine))
    # ⚠️ 这是整块里最强的一条：**整张表的行序**必须正好等于推导出来的那个
    #    顺序。只查"同组挨着"的话，组间次序错了也照样绿。
    got = [int(x) for x in col(mine, icol)]
    C("★★★ 整张表的行序 = 组间按最新一条倒序、组内按执行顺序升序",
      got == want_grouped, "得到 %s，期望 %s" % (got, want_grouped))

    conv = col(mine, ccol)
    C("★★★ 「对话」列是「会话名（N 个任务）」的形式，不是一行一个会话名",
      any(SESS_A in c and "3 个任务" in c for c in conv) and
      any(SESS_B in c and "2 个任务" in c for c in conv), str(conv))
    # 组标题 + 它下面的 └ 必须是一段连续的
    for name, n in ((SESS_A, 3), (SESS_B, 2), (SESS_C, 1)):
        i = next((k for k, c in enumerate(conv) if name in c), None)
        C("★★ %s 那组有 %d 行、而且是挨着的" % (name[:8], n),
          i is not None and
          (n == 1 or all(conv[i + j] == "└" for j in range(1, n))),
          "起点 %s" % i)
    C("★ 只有一步的对话不写「（1 个任务）」（那是句废话）",
      any(c == SESS_C for c in conv), str(conv))
    C("★★ 组标题那一行有 dsapp-task-grp-head 这个类（CSS 靠它加粗加底）",
      any("dsapp-task-grp-head" in r["cls"] for r in mine))
    C("★★ 组员那一行有 dsapp-task-grp-sub 这个类",
      any("dsapp-task-grp-sub" in r["cls"] for r in mine))
    # 类必须挂在**对的行**上：第一条应该是 head，它的同组后面几条是 sub
    C("★★★ 类挂对了行：每组第一条是 head、后面的是 sub",
      all(("dsapp-task-grp-head" in mine[i]["cls"]) ==
          (conv[i] != "└") for i in range(len(mine))),
      " | ".join("%s:%s" % (r["cls"].split()[-1][-4:], col(mine, ccol)[i][:6])
                 for i, r in enumerate(mine)))

    # ---- (c) 标题尾巴上那半截会话名被去掉了 -------------------------------
    print("\n== (c) 标题 ==", flush=True)
    titles = col(mine, tcol)
    for t in titles:
        print("   %s" % t, flush=True)
    C("★★★ 标题里不再重复会话名的后半截（去掉了才看得见这一步在干什么）",
      not any(SESS_A[:10] in t for t in titles) and
      not any(SESS_B in t for t in titles), str(titles))
    # ⚠️ 光查"没有了"不够 —— 一个把标题切成空串的实现也能过。功能名必须还在。
    C("★★★ 但功能名还在（去掉的是尾巴，不是把标题切没了）",
      all(any(f == t for f in FEATS) for t in titles), str(titles))

    # ---- (d) 关掉开关 → 回到平铺 -----------------------------------------
    print("\n== (d) 关掉「按对话分组」==", flush=True)
    pg.uncheck("#tasks-f_group")
    pg.wait_for_timeout(2500)
    mine2 = pick(rows(pg), tcol)
    got2 = [int(x) for x in col(mine2, icol)]
    print("   %s" % got2, flush=True)
    # ⚠️ 判据是**行序**，不是"对话列空不空"。原来写的是"不再全挨着"，
    #    而平铺之后对话列整个是空的，那个表达式恒为假 —— 一条注定要红的
    #    断言，和一条注定要绿的断言一样没用。
    C("★★★ 关掉之后回到 ORDER BY id DESC（最新的在上）",
      got2 == want_flat, "得到 %s，期望 %s" % (got2, want_flat))
    C("★★ 关掉之后「对话」列是空的（那一列只在分组视图里有意义）",
      all(c == "" for c in col(mine2, ccol)), str(col(mine2, ccol)))
    C("★ 关掉之后没有任何行还挂着分组的类",
      not any("dsapp-task-grp-" in r["cls"] for r in mine2))
    C("★ 关掉之后标题重新带上完整尾巴（平铺视图里会话名没别处显示）",
      any(SESS_A[:10] in t for t in col(mine2, tcol)),
      str(col(mine2, tcol)))
    pg.check("#tasks-f_group")
    pg.wait_for_timeout(2500)

    # ---- (e) 最要紧的：勾选认的还是不是同一条 -----------------------------
    # ⚠️ 分组是**重排**，而 selected_ids() / current() 都按下标回查 tasks()。
    #    重排要是把行号和数据对错了，表现是"点第 3 行删掉的是第 4 条" ——
    #    真的会删错东西。所以这里不测"能不能勾上"，测**勾的是哪一条**：
    #    勾 B 组的第 2 行，右栏详情里显示的必须是那一条自己的标题。
    print("\n== (e) 勾选认的是哪一条 ==", flush=True)
    mine3 = pick(rows(pg), tcol)
    got3 = [int(x) for x in col(mine3, icol)]
    C("★★ 回到分组视图了（不然下面那条会量在平铺表上）",
      got3 == want_grouped, str(got3))
    # B 组：第 0 行是组标题（取表达矩阵），第 1 行是 └（画火山图）
    b_head = next(k for k, c in enumerate(col(mine3, ccol)) if SESS_B in c)
    want = mine3[b_head + 1]["cells"][tcol]
    want_id = mine3[b_head + 1]["cells"][icol]
    print("   勾 B 组第 2 条：标题 %r，ID 应该是 %s" % (want, want_id), flush=True)
    # ⚠️ 按 **ID** 去 DOM 里找那一行再点，不要用「mine 里的第几个」当下标 ——
    #    mine 是**过滤后**的列表，而这个账号要是还有别的任务行（测试账号是
    #    复用的），两个下标就对不上，点到的会是另一条，而断言照样绿。
    # 点这一行的标题格（DT 的 selector = "td"，点哪儿都能勾上）
    clicked = pg.evaluate("""(args) => {
        var t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
        var trs = [...t.querySelectorAll('tbody tr')];
        var tr = trs.find(r =>
            (r.cells[args.icol].innerText || '').trim() === args.id);
        if (!tr) return false;
        tr.cells[args.tcol].click();
        return true;
    }""", {"id": want_id, "icol": icol, "tcol": tcol})
    C("★★ 找得到那一行并点下去了（找不到的话下面那条会验在没勾上的状态上）",
      clicked is True)
    pg.wait_for_timeout(2500)
    detail = pg.evaluate("""() => {
        var d = document.querySelector('.dsapp-task-detail');
        return d ? (d.innerText || '').slice(0, 300) : null;
    }""")
    print("   右栏详情：%s" % (detail or "")[:160].replace("\n", " / "), flush=True)
    C("★★★ 勾了哪一行，右栏显示的就是那一条（重排没把行号和数据对错）",
      detail is not None and want in detail,
      "想要 %r" % want)
    # 按钮上的计数也要跟上
    n_sel = pg.evaluate("""() => {
        var b = document.querySelector('#tasks-delete');
        return b ? (b.innerText || '').trim() : null;
    }""")
    print("   删除按钮：%r" % n_sel, flush=True)
    C("★★ 删除按钮上的条数跟上了（说明 input$tbl_rows_selected 是有效的）",
      n_sel is not None and "1" in n_sel, str(n_sel))

    # ---- (f) 五款皮肤下组标题都读得出来 -----------------------------------
    # ⚠️ 这条是**真抓到过 bug** 才有的。第一版 CSS 写的是 `background: #f6f8fa`
    #    （写死），浅色皮肤下完全正常 —— 因为那恰好就是 light 皮肤的值。
    #    切到 dark（body-bg #0d1117、文字 #e6edf3）之后，组标题变成
    #    **白底白字、一个字都看不见**。
    #
    #    写代码时用的正是浅色皮肤，肉眼验收撞不上；五个皮肤里坏一个，
    #    不专门量就发现不了。所以这里**逐个皮肤**量对比度。
    print("\n== (f) 五款皮肤下的可读性 ==", flush=True)
    for skin in ("light", "dark", "chatgpt", "claude", "apple"):
        set_skin(pg, skin)
        pg.wait_for_timeout(700)
        worst = pg.evaluate("""() => {
            // WCAG 的相对亮度 / 对比度。一个字读不读得出来就是这两个数。
            function lum(c) {
                var m = c.match(/\\d+(\\.\\d+)?/g).slice(0, 3).map(Number)
                        .map(v => { v /= 255;
                            return v <= 0.03928 ? v / 12.92
                                 : Math.pow((v + 0.055) / 1.055, 2.4); });
                return 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2];
            }
            function ratio(a, b) {
                var l1 = lum(a), l2 = lum(b);
                return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
            }
            var t = document.querySelector('.dsapp-dt-nowrap table.dataTable');
            var out = [];
            [...t.querySelectorAll('tbody tr')].forEach(r => {
                if (!r.classList.contains('dsapp-task-grp-head')) return;
                if (r.cells.length < 4) return;
                var cs = getComputedStyle(r.cells[2]);
                out.push([(r.cells[2].innerText || '').trim().slice(0, 10),
                          Math.round(ratio(cs.color, cs.backgroundColor) * 10) / 10,
                          cs.backgroundColor]);
            });
            return out;
        }""")
        print("   %-8s %s" % (skin, worst), flush=True)
        C("★★★ %s 皮肤下组标题读得出来（对比度 ≥ 3:1，粗体大字的标准）"
          % skin,
          bool(worst) and all(x[1] >= 3.0 for x in worst),
          str(worst))
    set_skin(pg, "light")
    pg.wait_for_timeout(500)

    C("★ 全程没有 JS 报错", not errs, "; ".join(errs[:3]))
    pg.screenshot(path="/tmp/dsapp_ui_v1311/item11_group.png")
    br.close()

print("\n==== %s ====" % ("全部通过" if not FAILS else "%d 项失败" % len(FAILS)))
for f in FAILS:
    print("  ✗ %s" % f)
sys.exit(1 if FAILS else 0)
