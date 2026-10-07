#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量云工具页的图标式二级菜单（V16.1 item 4）。

用户原话：「蛋白质设计只是云工具的一部分，做成图标式二级菜单，比如再加一
           TCGA挖掘工具、单细胞分析工具」。

这一版把云工具页从"一页 = 一条流水线"改成"三个方块 + 三块面板"。要验的有
**三件事**，第三件是最容易写对却坏掉的：

  ① 三个方块都在，点哪块显示哪块面板（另外两块必须是 display:none）；
  ② 「TCGA / 单细胞」两块按约定**不给**「开始运行」，只给「开一个对话」；
  ③ ★★ **切走再切回来，结合蛋白设计那块面板里的参数不能丢**。
     这正是"切面板走前端、不经过服务端"的全部理由（见 R/mod_cloudtool.R
     里那段）：走 renderUI 重画的话，那十几个控件连同用户填好的值会被一起
     铲掉。所以这里不是"顺手检查一下"，而是这条设计的判据。

     判据的写法很讲究：**不能只比 input 的值**。值是浏览器自己记着的，
     节点被换掉之后新节点也会显示同样的值（Shiny 会把它知道的旧值填回去）
     —— 那样量出来的绿是假的。所以在节点上盖一个 JS 属性（`__dsappProbe`），
     切一圈回来再看它还在不在：**只有同一个 DOM 节点才认得这个属性**。

  ④ 两颗「开一个对话」的按钮真的把提示词交给了对话页。走的是文献速递那条
     现成通道（dsapp:lit_go）。判据落在**库**上：点完之后 sessions 里要多出
     一条标题是「TCGA 数据挖掘」的会话，messages 里那条 user 消息要含 "GDC"。
     ⚠️ 只断言"页面跳到对话页了"是不够的：切页那一行（dsappNav）在**服务端
        闸门之前**就执行了，没 Key 的时候照样跳 —— 那种绿等于没验。

用法（实例由 make_instance.sh 起，见 tests/ui_v161/README.md）：
    DSAPP_TEST_URL=http://127.0.0.1:8964/ DSAPP_TEST_APP=/tmp/dsapp_v161j/app \
      python3 tests/ui_v161/probe_cloudtiles.py
"""
import os
import re
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8964/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v161j/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v161")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from _common import ensure_no_modal                     # noqa: E402

BAD = []
TILES = [("design", "结合蛋白设计"), ("tcga", "TCGA 数据挖掘"), ("sc", "单细胞分析")]
PLAN_TCGA_KEY = "GDC"          # 那段开场白里最不可能被改写没的词


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def bad(msg):
    BAD.append(msg)
    say("  ** %s **" % msg)


# 在面板节点上盖一个属性，再看它还在不在 —— 判据是"同一个 DOM 节点"。
STAMP = r"""
(key) => {
  var p = document.querySelector('.dsapp-cloud-panel[data-panel="' + key + '"]');
  if (!p) return {err: 'no panel ' + key};
  p.__dsappProbe = 'kept-' + key;
  var inp = p.querySelector('input, select, textarea');
  if (inp) { inp.__dsappProbe = 'kept-input'; }
  return {stamped: true, hasInput: !!inp,
          inputId: inp ? (inp.id || inp.name || '') : ''};
}
"""
CHECK = r"""
() => {
  var out = {};
  out.panels = {};
  document.querySelectorAll('.dsapp-cloud-panel').forEach(function (p) {
    var k = p.getAttribute('data-panel');
    var r = p.getBoundingClientRect();
    out.panels[k] = {
      hidden: p.classList.contains('dsapp-cloud-hidden'),
      w: Math.round(r.width), h: Math.round(r.height),
      vis: getComputedStyle(p).display !== 'none',
      stamp: p.__dsappProbe || null
    };
  });
  out.tiles = [];
  document.querySelectorAll('.dsapp-cloud-tile').forEach(function (t) {
    out.tiles.push({
      key: t.getAttribute('data-tool'),
      name: (t.querySelector('.dsapp-cloud-name') || {}).textContent || '',
      active: t.classList.contains('is-active')
    });
  });
  /* 当前**可见**那块面板里的 input（第 3 条要盯的就是它） */
  var vis = document.querySelector('.dsapp-cloud-panel:not(.dsapp-cloud-hidden)');
  var inp = vis ? vis.querySelector('input, select, textarea') : null;
  out.visPanel = vis ? vis.getAttribute('data-panel') : null;
  out.visInput = inp ? {id: inp.id || inp.name || '', val: inp.value,
                        stamp: inp.__dsappProbe || null} : null;
  var btn = document.querySelector('.dsapp-cloud-panel:not(.dsapp-cloud-hidden) .btn-primary');
  out.visBtn = btn ? btn.textContent.trim() : null;
  return out;
}
"""
CLICK_TILE = r"""
(key) => {
  var t = document.querySelector('.dsapp-cloud-tile[data-tool="' + key + '"]');
  if (!t) return false;
  t.click();
  return true;
}
"""


def snap(pg):
    return pg.evaluate(CHECK)


def show(st, tag):
    ps = st["panels"]
    say("  [%s] 面板：" % tag + " | ".join(
        "%s=%s%s" % (k, "藏" if v["hidden"] else "显",
                     "" if v["hidden"] else "(%dx%d)" % (v["w"], v["h"]))
        for k, v in sorted(ps.items())))
    say("        可见面板=%s  方块active=%s  那颗主按钮=%r"
        % (st["visPanel"], [t["key"] for t in st["tiles"] if t["active"]],
           st["visBtn"]))


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: errs.append("console." + m.type + ": " + m.text)
              if m.type == "error" else None)

        C.wait_awake(pg)
        C.enter_app(pg, C.EMAIL)
        uid, _db = C.seed_or_die(C.EMAIL)
        say("账号 uid=%s  实例 %s" % (uid, C.URL))

        # ---- 假 LLM：第 4 条要真的把消息发出去，不然量到的是"没 Key"那道闸门
        fx = None
        try:
            fx = C.FakeLLM()
            # 队列摆 3 条同样的：agent 循环一轮接一轮，只摆一条的话第二轮
            # 拿到的是"队列已空"，报出来的错会指向完全无关的地方。
            fx.set_queue(*([C.sse("收到，我按这个顺序开始。")] * 3))
            line = C.seed_llm(uid, fx.url)
            say("假 LLM 起来了：%s" % fx.url)
            # ⚠️ seed_llm 只在"R 没吐 OK"时硬退 —— 它认不出 `uid=NA`。
            #    第一跑就是这么绿的：uid 传成了 (id, db) 那个元组，R 收到 NA、
            #    设置一个字段都没写，而摘要行看着像成功。第 4 条于是变成
            #    "点了没反应"，查了半天是这里。
            if "=NA" in line:
                bad("假 LLM 没种上（%s）—— 第 4 条会变成「点了没反应」" % line)
        except SystemExit as e:
            bad("假 LLM 起不来（第 4 条会退化成只看跳页）：%s" % e)
            fx = None

        # ⚠️⚠️ 种完必须**刷一次页面**。`state$base_url` 是**会话开始那一刻**
        #    读一次就定住的（2026-10-02 真打出去一条 401 才发现的）：先建号
        #    后种库的话，这一跑仍然会去厂商默认地址 —— 而"没 Key / 地址不对"
        #    那道闸门会把发送拦下来，第 4 条于是变成"点了没反应"。
        pg.reload(wait_until="domcontentloaded")
        pg.wait_for_timeout(3000)
        for _ in range(30):
            if pg.locator(".dsapp-shell").count():
                break
            pg.wait_for_timeout(1000)
        if not pg.locator(".dsapp-shell").count():
            bad("种完刷新的那一次没进主界面")

        C.goto(pg, "云工具")
        C.ensure_no_modal(pg)
        C.goto(pg, "云工具")          # 关弹窗可能把页带回去，再切一次
        pg.wait_for_timeout(1500)

        # ================================================== ① 三个方块
        st = snap(pg)
        got = [(t["key"], t["name"].strip()) for t in st["tiles"]]
        say("")
        say("=== ① 图标式二级菜单 ===")
        say("  方块：%s" % (got,))
        for k, name in TILES:
            hit = [n for kk, n in got if kk == k]
            if not hit:
                bad("没有 %s 这个方块" % k)
            elif name not in hit[0]:
                bad("%s 方块的标题是 %r，期望含 %r" % (k, hit[0], name))
        if len(got) != 3:
            bad("方块数 %d，期望 3" % len(got))

        # 打开时：结合蛋白设计那块必须是"显"，另两块必须是"藏"
        if st["visPanel"] != "design":
            bad("打开时可见的是 %r，期望 design" % st["visPanel"])
        for k in ("tcga", "sc"):
            p = st["panels"].get(k) or {}
            if not p.get("hidden"):
                bad("%s 面板打开时就露着（应该是藏起来的）" % k)
        show(st, "打开")

        # ================================================== ③ 盖戳（先盖再切）
        say("")
        say("=== ③ 切走再切回来：面板节点和参数必须还在 ===")
        stamp = pg.evaluate(STAMP, "design")
        say("  盖戳：%s" % stamp)
        if not stamp.get("stamped"):
            bad("盖不上戳：%s" % stamp)
        # ⚠️ 没工作区时 form_box 返回 NULL，面板里一个 input 都没有。
        #    那种情况下这条判据**退化成只看面板子树**，必须说出来 ——
        #    不然"没得可丢"会被读成"没丢"。
        if not stamp.get("hasInput"):
            say("  ⚠️ 这一页现在没有参数控件（没有对话工作区，form_box 是 NULL）——")
            say("     第 3 条这一跑**只验了面板子树没被重画**，没验到参数值本身。")

        # ================================================== ① 点 tcga 方块
        say("")
        say("=== ① 点方块切面板 ===")
        for k, _ in (("tcga", None), ("sc", None), ("design", None)):
            ok = pg.evaluate(CLICK_TILE, k)
            pg.wait_for_timeout(500)
            if not ok:
                bad("点不到 %s 方块" % k)
                continue
            st = snap(pg)
            show(st, "点 " + k)
            if st["visPanel"] != k:
                bad("点了 %s，可见的却是 %r" % (k, st["visPanel"]))
            act = [t["key"] for t in st["tiles"] if t["active"]]
            if act != [k]:
                bad("点了 %s，高亮的方块是 %s" % (k, act))
            for kk, v in st["panels"].items():
                if kk != k and not v["hidden"]:
                    bad("点了 %s，%s 面板还露着" % (k, kk))
                if kk != k and (v["w"] or v["h"]):
                    bad("%s 面板藏起来了却还有 %dx%d 的矩形"
                        % (kk, v["w"], v["h"]))

        st = snap(pg)
        if st["panels"].get("design", {}).get("stamp") != "kept-design":
            bad("转一圈回来，design 面板换了个 DOM 节点（盖的戳没了）—— "
                "用户填好的参数会跟着没")
        else:
            say("  ✓ design 面板还是原来那个节点（盖的戳还在）")
        vi = st.get("visInput")
        if vi is not None:
            if vi.get("stamp") != "kept-input":
                bad("参数控件 %s 换了节点（值会丢）" % vi.get("id"))
            else:
                say("  ✓ 参数控件 %s 还是原来那个（值=%r）"
                    % (vi.get("id"), vi.get("val")))

        # ================================================== ② 两块新面板的按钮
        say("")
        say("=== ② TCGA / 单细胞 两块面板 ===")
        for k, want in (("tcga", "开一个对话"), ("sc", "开一个对话")):
            pg.evaluate(CLICK_TILE, k)
            pg.wait_for_timeout(400)
            st = snap(pg)
            b = (st.get("visBtn") or "")
            say("  %s 面板的主按钮：%r" % (k, b))
            if want not in b:
                bad("%s 面板没有「%s」按钮（拿到的是 %r）" % (k, want, b))
            if "开始运行" in b:
                bad("%s 面板出现了「开始运行」—— 这两块不预置流水线，不该有" % k)
            # 面板里得说清楚点下去会发生什么
            txt = pg.evaluate(
                "() => { var p = document.querySelector("
                "'.dsapp-cloud-panel[data-panel=\"%s\"]');"
                " return p ? p.innerText : ''; }" % k)
            if "新开一个对话" not in txt:
                bad("%s 面板没说清「点下去会新开一个对话」" % k)

        # ================================================== ④ 真发一次
        say("")
        say("=== ④ 点「开一个对话，让它带我挖 TCGA」 ===")
        db = C.db_path()
        before = _titles(db)
        pg.evaluate(CLICK_TILE, "tcga")
        pg.wait_for_timeout(400)
        pg.click(".dsapp-cloud-panel[data-panel='tcga'] .btn-primary")
        # 等库上出现新会话（最多 40 秒）；**查得到行**不算等，要等**新**的那条
        new_sid = None
        for _ in range(40):
            pg.wait_for_timeout(1000)
            cur = _titles(db)
            add = {k: v for k, v in cur.items() if k not in before}
            if add:
                new_sid = list(add.keys())[0]
                break
        if new_sid is None:
            bad("点了之后库里没多出会话（提示词没送到对话页）")
        else:
            title = _titles(db)[new_sid]
            say("  新会话：%s  标题=%r" % (new_sid, title))
            if "TCGA" not in (title or ""):
                bad("新会话标题是 %r，期望含 TCGA" % title)
            body = _first_user_msg(db, new_sid)
            say("  第一条 user 消息：%d 字，开头 %r" % (len(body or ""), (body or "")[:40]))
            if PLAN_TCGA_KEY not in (body or ""):
                bad("发出去的第一条消息里没有 %r —— 送过去的不是那段开场白"
                    % PLAN_TCGA_KEY)
            if len(body or "") < 300:
                bad("第一条消息只有 %d 字，看着不像那份完整的计划"
                    % len(body or ""))
            nav = pg.evaluate(
                "() => { var a = document.querySelector('.dsapp-rail-link.active');"
                " return a ? a.getAttribute('data-nav') : null; }")
            say("  点完之后左栏停在：%r" % nav)
            if nav != "chat":
                bad("点完还停在 %r，没切到对话页" % nav)

        # ============================================================ ⑤ 有工作区时
        # ★ 第 3 条前面那一跑只盖到"面板子树没被重画"，因为新账号没有工作区、
        #   form_box 是 NULL（面板里一个控件都没有）。**"没得可丢"不等于"没丢"**，
        #   所以这里补一个真的有控件的场景：给刚建的那个会话造一个工作区目录，
        #   再回来量参数值本身。
        say("")
        say("=== ⑤ 面板里有真控件时，值必须扛得住来回切 ===")
        if new_sid is None:
            bad("第 4 条没建出会话，第 5 条没得做（参数值这一跑**没验到**）")
        else:
            wsd = os.path.join(C.DATA_ROOT, "workspaces",
                               "chat-" + re.sub(r"[^A-Za-z0-9._-]", "_", new_sid))
            try:
                os.makedirs(wsd, exist_ok=True)
                say("  造好工作区：%s" % wsd)
            except OSError as e:
                bad("造不了工作区：%s" % e)
            C.goto(pg, "云工具")
            pg.wait_for_timeout(2500)
            # ⚠️⚠️ 必须先把 design 那块面板切回来再填。上面第 4 条点了 TCGA 的
            #    方块，切页是**客户端**的事，来回走一趟不会重置它 —— 回到云工具
            #    页时亮着的还是 tcga，design 那块躺在 display:none 里。
            #    这时 #cloudtool-job **在 DOM 里**（count=1），只是不可见，
            #    而 pg.fill() 会一直等到 30 秒超时，报的是
            #    「element is not visible」—— 看着像"表单没渲染出来"，
            #    其实是探针自己站错了面板。
            pg.evaluate(CLICK_TILE, "design")
            pg.wait_for_timeout(500)
            has = pg.locator("#cloudtool-job").count()
            say("  参数表单渲染出来了没有：#cloudtool-job count=%d" % has)
            if not has:
                bad("有工作区了，参数表单还是没渲染 —— 第 5 条没验到"
                    "（别把这句读成「值没丢」）")
            else:
                MARK = "KEEPME_%d" % int(time.time())
                pg.fill("#cloudtool-job", MARK)
                pg.wait_for_timeout(600)
                st0 = pg.evaluate(STAMP, "design")
                # ★★ 戳必须盖在**我们待会儿要读的那一个**控件上。
                #    STAMP 盖的是面板里**第一个** input（那是 cloudtool-preset），
                #    而这里读的是 #cloudtool-job —— 上一跑就是这么写的，结果
                #    报「戳=None」却打了 ✓，等于只验了"值还在"。而**值是最弱的
                #    判据**：节点被换掉之后 Shiny 会把旧值填回新节点，值照样对。
                #    所以补一句，把戳盖到 #cloudtool-job 自己身上。
                pg.evaluate(
                    "() => { var e = document.getElementById('cloudtool-job');"
                    " if (e) e.__dsappProbe = 'kept-job'; }")
                say("  填了 %r，面板戳：%s" % (MARK, st0))
                for k in ("tcga", "sc", "design"):
                    pg.evaluate(CLICK_TILE, k)
                    pg.wait_for_timeout(400)
                v = pg.input_value("#cloudtool-job")
                stmp = pg.evaluate(
                    "() => { var e = document.getElementById('cloudtool-job');"
                    " return e ? (e.__dsappProbe || null) : '<没有这个控件>'; }")
                say("  切一圈回来：#cloudtool-job 的值=%r  戳=%r" % (v, stmp))
                if v != MARK:
                    bad("切一圈回来参数值变成 %r（填的是 %r）—— 用户填好的参数丢了"
                        % (v, MARK))
                elif stmp != "kept-job":
                    bad("参数值还在，但 #cloudtool-job 是**另一个节点**了"
                        "（戳 %r 没了）—— 控件被重建过，只是 Shiny 把旧值填了"
                        "回去；真跑起来时挂在这个控件上的其它状态（焦点、"
                        "selectize 里没提交的选择）已经丢了" % stmp)
                else:
                    say("  ✓ 参数值活着，而且是同一个 DOM 节点")

        if errs:
            bad("浏览器报了 %d 条错，头一条：%s" % (len(errs), errs[0][:200]))
        if fx is not None:
            say("  假 LLM 收到请求数：%s" % fx.req_n())
            fx.stop()
        pg.screenshot(path=os.path.join(C.OUT, "cloudtiles.png"), full_page=True)
        ctx.close()
        br.close()

    say("")
    if BAD:
        say("===== 红 %d 条 =====" % len(BAD))
        for m in BAD:
            say("  · " + m)
        sys.exit(1)
    say("===== 全绿 =====")


def _titles(db):
    con = sqlite3.connect(db, timeout=10)
    try:
        return {r[0]: r[1] for r in
                con.execute("SELECT id, title FROM sessions").fetchall()}
    finally:
        con.close()


def _first_user_msg(db, sid):
    con = sqlite3.connect(db, timeout=10)
    try:
        r = con.execute("SELECT content FROM messages WHERE session_id=? AND role='user' "
                        "ORDER BY rowid LIMIT 1", (sid,)).fetchone()
        return r[0] if r else None
    finally:
        con.close()


if __name__ == "__main__":
    main()
