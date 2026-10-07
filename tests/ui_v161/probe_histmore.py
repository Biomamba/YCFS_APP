#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在**慢链路**上量「显示更早的消息」：连点 8 次，每次多露出几条、这一包多大。

V16.1 item 2 的现场是「主账号中，对话里显示更早的消息**无法正常加载出来**」。
`tests/ui_v158/probe_histwin.py` 已经在**本地环回**上量过一次（点一次 6→12 条、
286 KB 一帧、没有 close）—— 环回上没有"加载不出来"，所以那一版是绿的。
要复现用户那一幕，两个条件缺一不可：

  ① **链路要慢**。用户那条实测 ~50 KB/s（RTT 80ms、重传 12%、cwnd 3）。
     本脚本用 CDP 的 `Network.emulateNetworkConditions` 把 down/up 压到
     400 kbit/s ≈ 50 KB/s、RTT 80ms。⚠️ 它压的是**套接字那层**，WebSocket
     一起压（这正是要量的那条路）。
  ② **数据要像**。现有那支种子的消息**没有思维链**（reasoning 全是 NULL），
     而线上 uid=1 那三个长对话里思维链占 52%~71%。思维链是
     **折在 `<details>` 里一起发出去的**（render.R/mod_chat.R 的 dsapp_msg_bubble），
     所以它照样吃预算、照样占这一包 —— 不种它，量到的字节数会只有真实的一半，
     "改前"那一幕（1.3 MB 一帧）根本复现不出来。

量的是**浏览器**侧的账，不是 R 层算出来的窗口：
  · 每点一次，页面上多出几条气泡（用户眼里的"加载出来了没有"）
  · 这一包的增量字节 / 最大一帧
  · 有没有 WebSocket close、整页重载、断联遮罩
  · 「显示更早的消息」那颗链接还在不在

⚠️ 判据有**两条**，缺一条这个探针就会在真 bug 面前报绿：

  ① "每一次点击都必须多露出至少一条"。改前 uid=1 那个 27 条的对话实测第
     5/6/7 次点击**一条都不多**（下一条消息 17 万字，比一次的预算增量还大），
     用户看到的就是"点了没反应"。
  ② "**每一包都不能超过 FRAME_MAX_KB**"。这一条是 2026-10-04 补的：改前那一跑
     **报了全绿**，而它当场量到的最大帧是 867.6 KB —— 因为 CDP 的限速
     **不丢包**，而用户那条链路丢 12%，把他那一包打回去的是重传超时。
     判据不落在字节上，能量到"多露出几条"，却量不到"这一包根本没送到"。

   改前（74 条 / 719 KB 的种子）实测：
       打开 257 KB；连点 8 次每次这一包 192 → 298 → 377 → 482 → 588 → 693
       → 773 → 878 KB（最大帧同步涨到 867.6 KB）。**没有任何一次回退**，
       因为改前那个 hist_extra 是个只增不减的计数器 —— 每点一次都把整个
       窗口重发一遍。翻到第 10 屏就是一包 1.5 MB。

用法（实例由 make_instance.sh 起，见 tests/ui_v161/README.md）：
    DSAPP_TEST_URL=http://127.0.0.1:8963/ DSAPP_TEST_APP=/tmp/dsapp_v161i/app \
      python3 tests/ui_v161/probe_histmore.py
"""
import json
import os
import re
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8963/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v161i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v161")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from _common import ensure_no_modal                  # noqa: E402

N_MSG = int(os.environ.get("DSAPP_HM_MSGS", "74"))
FILL_KB = int(os.environ.get("DSAPP_HM_FILL_KB", "6"))    # 正文 KB/条
REA_KB = int(os.environ.get("DSAPP_HM_REA_KB", "7"))      # 思维链 KB/条
CLICKS = int(os.environ.get("DSAPP_HM_CLICKS", "8"))      # 连点几次
KBS = float(os.environ.get("DSAPP_HM_KBS", "50"))         # 链路 KB/s
RTT_MS = int(os.environ.get("DSAPP_HM_RTT", "80"))
SETTLE_S = int(os.environ.get("DSAPP_HM_SETTLE", "45"))   # 每一拍最多等多久
TITLE = "慢链路长对话_%d" % int(time.time())

# ★★ 「这一包不能超过多少」—— 这条判据是 2026-10-04 补上的，补的原因值得记着：
#    改前那一跑（fix 之前）**报了全绿**，而它当场量到的是每点一次涨 ~90 KB、
#    第 8 次最大帧 867.6 KB。原来的判据只有"每次都要多露出消息 / 没有 close /
#    没有重载"，而这三条在**这条模拟链路**上一条都不会红 —— CDP 的
#    emulateNetworkConditions 只压带宽和延迟，**不丢包**，而用户那条链路实测
#    丢 12%；真正把他那一包打回去的是重传超时。于是"探针全绿"和"用户点不开"
#    可以同时成立。判据不落在**字节**上，就量不到这个 bug。
#
#    线怎么定的：线上 `sockjs_heartbeat_delay` = 180 s，用户那条链路实测
#    ~3.65 KB/s，死线 ≈ 3.65 × (180+10) ≈ 694 KB。这里取 400 KB
#    （实测最重的一个真实界面是 368 KB），留一截余量。
FRAME_MAX_KB = float(os.environ.get("DSAPP_HM_FRAME_MAX_KB", "400"))


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def para(n_kb, i0=0):
    """造一段 n_kb 量级的 markdown 正文（标题/列表/代码块/表格/段落都有）。"""
    parts, i = [], i0
    while sum(len(p) for p in parts) < n_kb * 1024:
        k = i % 5
        if k == 0:
            parts.append("## 第 %d 节 结果解读\n\n样本量 N=%d，主要指标较基线上升 "
                         "12.3%%，置信区间 [1.1, 3.2]，p<0.01。\n\n" % (i // 5 + 1, 100 + i))
        elif k == 1:
            parts.append("- 差异表达基因 %d 个（上调 %d / 下调 %d）\n"
                         "- 富集到通路 %d 条，其中 FDR<0.05 的 %d 条\n\n"
                         % (i * 7, i * 3, i * 4, i, i // 2))
        elif k == 2:
            parts.append("```r\nres_%d <- lm(y ~ x + batch, data = df)\n"
                         "summary(res_%d)$coefficients\n```\n\n" % (i, i))
        elif k == 3:
            parts.append("| 指标 | 处理组 | 对照组 | FC |\n|---|---|---|---|\n"
                         "| mRNA_%d | %.2f | %.2f | %.2f |\n\n" % (i, i * 1.1, i * 0.9, 1.22))
        else:
            parts.append("从上面的结果看，第 %d 组与对照的分离主要由批次效应驱动，"
                         "建议下一轮把 batch 放进协变量，并对低表达基因做一次过滤。\n\n" % i)
        i += 1
    return "".join(parts)


def seed(uid, db_path):
    """种一个正文 + 思维链都像线上那样的长对话，另加一个更新的落地会话。"""
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    sid = "s-hm-%d" % int(time.time())
    rows = []
    for i in range(N_MSG):
        if i % 4 == 0:
            rows.append(("user", "第 %d 步：把这一步的分析做完，"
                                 "顺便解释一下图上那个离群点。\n" % (i // 4 + 1), None))
        else:
            rows.append(("assistant", para(FILL_KB, i), para(REA_KB, i)))
    con = sqlite3.connect(db_path, timeout=10)
    # ⚠️ 必须有一个**更新**的落地会话：应用进对话页会自动选中"最近更新的那个"，
    #    不然长对话在页面加载那一刻就整体渲染完了 —— 量到的是"点开只发了 3 KB"，
    #    看着像"这一版把历史改没了"，其实是没量到（ui_v158 第一版栽过）。
    small = sid + "-small"
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id) "
                "VALUES (?,?,?,?,?)", (small, "落地会话", now, now, uid))
    con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                "VALUES (?,?,?,?,NULL)", (small, "user", "先放一个短对话在这儿。", now))
    con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                "VALUES (?,?,?,?,NULL)", (small, "assistant", "好，随时开始。", now))
    older = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 3600))
    con.execute("INSERT INTO sessions (id, title, created_at, updated_at, user_id) "
                "VALUES (?,?,?,?,?)", (sid, TITLE, older, older, uid))
    for role, content, rea in rows:
        con.execute("INSERT INTO messages (session_id, role, content, created_at, reasoning) "
                    "VALUES (?,?,?,?,?)", (sid, role, content, now, rea))
    con.commit()
    tot_c = con.execute("SELECT sum(length(content)) FROM messages WHERE session_id=?",
                        (sid,)).fetchone()[0]
    tot_r = con.execute("SELECT sum(length(COALESCE(reasoning,''))) FROM messages "
                        "WHERE session_id=?", (sid,)).fetchone()[0]
    con.close()
    say("  种好：%s  %d 条 / 正文 %d 字 + 思维链 %d 字 = %.0f KB"
        % (sid, N_MSG, tot_c, tot_r, (tot_c + tot_r) / 1024))
    return sid


# 页面侧：记 WS 帧大小 + close + 整页重载。和 ui_v158 那一套同一份思路
# （本仓规矩：这些脚本要能单独拷走，宁可抄一份也不跨目录 import）。
INIT = r"""
(function(){
  window.__ws = {n:0, bytes:0, big:[], closes:[], hist:{}};
  var W = window.WebSocket;
  function wrap(ws){
    try {
      ws.addEventListener('message', function(e){
        var b = (typeof e.data === 'string') ? e.data.length
                                             : (e.data && e.data.byteLength) || 0;
        window.__ws.n++; window.__ws.bytes += b;
        if (b > 1024 && window.__ws.big.length < 4000) window.__ws.big.push(b);
        var k = b < 200 ? '<200' : b < 1024 ? '<1K' : b < 4096 ? '<4K'
              : b < 16384 ? '<16K' : b < 65536 ? '<64K'
              : b < 262144 ? '<256K' : '>=256K';
        window.__ws.hist[k] = (window.__ws.hist[k] || 0) + 1;
      });
      ws.addEventListener('close', function(e){
        window.__ws.closes.push([e.code, (e.reason||'').slice(0,60), e.wasClean]);
      });
    } catch(err){ window.__ws.err = String(err); }
  }
  function Patched(url, protocols){
    var ws = (protocols === undefined) ? new W(url) : new W(url, protocols);
    wrap(ws); return ws;
  }
  Patched.prototype = W.prototype;
  ['CONNECTING','OPEN','CLOSING','CLOSED'].forEach(function(k){ Patched[k] = W[k]; });
  window.WebSocket = Patched;
})();
"""

STATE = """() => {
  var d = document.getElementById('dsapp-offline');
  var more = document.querySelector('.dsapp-hist-more-link');
  var note = document.querySelector('.dsapp-hist-cap-note');
  var bub = document.querySelectorAll('.dsapp-msg');
  // ⚠️ 只取**第一条**气泡的 innerText。第一版对**每一条**都取，而这个探针
  //    要连点八次、每次窗口都在变大 —— 到第七八次时 DOM 已经几 MB，
  //    每次快照都触发一次全页重排，探针自己卡死在 evaluate 里
  //    （跑满 10 分钟被 timeout 砍掉，日志停在第七次）。
  //    快照要**便宜**，不然量的是探针自己的开销。
  return {
    off: d ? d.getAttribute('data-kind') : null,
    ws: JSON.parse(JSON.stringify(window.__ws || {})),
    more: more ? more.innerText : null,
    note: note ? note.innerText : null,
    bubbles: bub.length,
    first: bub.length ? (bub[0].innerText || '').slice(0, 24) : '',
    // ⚠️ textContent 而不是 innerText：后者要**触发布局**，DOM 几 MB 时
    //    每秒一次的快照就够把探针自己拖垮。这里只要个"页面有没有内容"的量级。
    body: (document.body.textContent || '').length
  };
}"""


def snap(pg):
    return pg.evaluate(STATE)


def wait_quiet(pg, max_s, floor_s=4, quiet_s=3):
    """等这一包收完：连续 quiet_s 秒没有新字节，且至少等了 floor_s 秒。

    ⚠️ ⚠️ 这里**不能**只看"字节数稳住了"就返回。第一版就是这么写的，量到的是
       **点击还没生效**的那两秒：慢链路上一次会话切换要先把历史读出来、渲染、
       再发 —— 之前那几秒链路上本来就一个字节都没有，"稳"得不能再稳。
       报出来的结果是「气泡 2 条 / 没有『更早』链接」，看着像"这一版把历史
       改没了"，其实只是**没等**（本仓老账：「等一行出现」写成「查得到行」）。
       所以调用方一律先等一个**状态真的变了**的信号，再进来等安静。
    """
    t0, last, quiet = time.time(), None, 0
    while time.time() - t0 < max_s:
        pg.wait_for_timeout(1000)
        st = snap(pg)
        b = st["ws"]["bytes"]
        quiet = quiet + 1 if b == last else 0
        last = b
        if quiet >= quiet_s and time.time() - t0 >= floor_s:
            break
    return snap(pg)


def wait_open(pg, title, max_s):
    """等某个会话**真的**被选中 —— `.dsapp-sess.active` 里出现它。"""
    row = pg.locator(".dsapp-sess.active", has_text=title)
    t0 = time.time()
    while time.time() - t0 < max_s:
        if row.count():
            return True
        pg.wait_for_timeout(500)
    return False


def wait_reveal(pg, prev_bubbles, had_link, max_s):
    """等这一次点击的**效果**出现：气泡数变了 / 链接没了 / 冒出上限提示。"""
    t0 = time.time()
    while time.time() - t0 < max_s:
        pg.wait_for_timeout(500)
        st = snap(pg)
        if st["bubbles"] != prev_bubbles:
            return st
        if (had_link and not st["more"]) or st["note"]:
            return st
    return snap(pg)


def report(say, tag, st, navs, nav0):
    say("  [%s] 收 %7.1f KB / %d 帧 | 最大帧 %7.1f KB | 气泡 %2d 条 | "
        "「更早」=%s%s | 遮罩=%s | 重载 +%d"
        % (tag, st["ws"]["bytes"] / 1024.0, st["ws"]["n"],
           (max(st["ws"]["big"]) / 1024.0) if st["ws"]["big"] else 0.0,
           st["bubbles"], (st["more"] or "无")[:26],
           (" / 上限提示" if st["note"] else ""),
           st["off"], len(navs) - nav0))
    return st


def main():
    db = os.path.join(C.DATA_ROOT, "dsapp.sqlite3")
    say("实例 %s  端口 %s" % (C.APP, re.search(r":(\d+)", C.URL).group(1)))
    say("慢链路：%.0f KB/s，RTT %d ms" % (KBS, RTT_MS))
    if not os.path.exists(db):
        sys.exit("实例库不存在：%s" % db)

    fails = []
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1440, "height": 900})
        pg = ctx.new_page()
        pg.on("pageerror", lambda e: say("  **pageerror** %s" % str(e)[:200]))
        navs = []
        pg.on("framenavigated",
              lambda f: navs.append(f.url) if f == pg.main_frame else None)
        pg.add_init_script(INIT)

        # ⚠️ 注册 / 冷加载**不能**在慢链路上做：整页要拉 bootstrap + jquery +
        #    fontawesome 那一堆，50 KB/s 下要几分钟，`enter_app` 会先超时 ——
        #    报出来的是"注册没进主界面"，和 item 2 一点关系都没有。
        #    下面 reload 完、进了对话页**再**把链路压下去：用户那条链路也是
        #    "应用已经开着、只是慢"。
        C.enter_app(pg, email="hm_%d@example.com" % int(time.time()))
        uid, _ = C.seed_or_die(C.LAST_EMAIL)
        seed(uid, db)

        pg.reload(wait_until="domcontentloaded")
        for _ in range(240):
            pg.wait_for_timeout(500)
            if pg.locator(".dsapp-shell").count():
                break
        C.goto(pg, "chat")
        ensure_no_modal(pg)

        row = pg.locator(".dsapp-sess", has_text=TITLE).first
        for _ in range(120):
            if row.count():
                break
            pg.wait_for_timeout(1000)
        if not row.count():
            sys.exit("侧栏里没有种进去的那个对话（页面 %d 字）" % snap(pg)["body"])
        say("侧栏里找到了「%s」" % TITLE)

        nav0 = len(navs)
        # ★ 从这里开始才压链路。CDP 这套是**套接字层**的，WebSocket 一起压。
        cdp = ctx.new_cdp_session(pg)
        cdp.send("Network.enable")
        cdp.send("Network.emulateNetworkConditions", {
            "offline": False,
            "latency": RTT_MS,
            "downloadThroughput": int(KBS * 1024),
            "uploadThroughput": int(KBS * 1024),
            "connectionType": "cellular3g",
        })
        say("\n=== 点开长对话（%d 条 / 正文 %d KB + 思维链 %d KB）==="
            % (N_MSG, N_MSG * FILL_KB, N_MSG * REA_KB))
        t0 = time.time()
        row.click()
        if not wait_open(pg, TITLE, 90):
            sys.exit("点了侧栏那一行，90 秒都没变成 .dsapp-sess.active —— "
                     "这一下根本没切过去（页面 %d 字）" % snap(pg)["body"])
        st = wait_quiet(pg, SETTLE_S)
        report(say, "%4.0fs" % (time.time() - t0), st, navs, nav0)
        base = st["bubbles"]
        say("打开这一包：%.1f KB，最大帧 %.1f KB，气泡 %d 条"
            % (st["ws"]["bytes"] / 1024.0,
               (max(st["ws"]["big"]) / 1024.0) if st["ws"]["big"] else 0.0, base))
        if not st["more"]:
            fails.append("打开后没有「显示更早的消息」—— 种子 %d 条却全渲染了？" % N_MSG)
        pg.screenshot(path=os.path.join(C.OUT, "probe_histmore_open.png"))

        prev = base
        inc = []          # 每一次点击**这一包**有多大（KB），用来看趋势
        say("\n=== 连点 %d 次「显示更早的消息」（慢链路）===" % CLICKS)
        for k in range(1, CLICKS + 1):
            if not pg.locator(".dsapp-hist-more-link").count():
                say("  第 %d 次：链接已经没了（要么全展开、要么到了上限）" % k)
                break
            nav_before = len(navs)
            pg.evaluate("() => { window.__ws = {n:0,bytes:0,big:[],closes:[],hist:{}}; }")
            pg.click(".dsapp-hist-more-link")
            t0 = time.time()
            wait_reveal(pg, prev, True, SETTLE_S)
            st = wait_quiet(pg, SETTLE_S)
            report(say, "%4.0fs" % (time.time() - t0), st, navs, nav_before)
            gain = st["bubbles"] - prev
            mx = (max(st["ws"]["big"]) / 1024.0) if st["ws"]["big"] else 0.0
            say("      → 第 %d 次：增量 %7.1f KB，最大帧 %7.1f KB，气泡 %d（+%d）"
                % (k, st["ws"]["bytes"] / 1024.0, mx, st["bubbles"], gain))
            if gain <= 0:
                fails.append("第 %d 次点击一条都没多露出（气泡仍是 %d）—— 死点击"
                             % (k, st["bubbles"]))
            if mx > FRAME_MAX_KB:
                fails.append("第 %d 次点击的最大帧 %.1f KB 超过 %.0f KB 这条线 —— "
                             "用户那条链路（~50 KB/s、丢包 12%）上，一包到这个量级"
                             "就会被判成断线，症状正是「点了一下、页面自己刷回去了」"
                             % (k, mx, FRAME_MAX_KB))
            inc.append(st["ws"]["bytes"] / 1024.0)
            if st["ws"]["closes"]:
                fails.append("第 %d 次点击期间 WebSocket 被关了：%s"
                             % (k, json.dumps(st["ws"]["closes"])))
            if len(navs) > nav_before:
                fails.append("第 %d 次点击期间整页重载了（%d 次）"
                             % (k, len(navs) - nav_before))
            if st["off"]:
                fails.append("第 %d 次点击期间出现断联遮罩：%s" % (k, st["off"]))
            prev = st["bubbles"]
        pg.screenshot(path=os.path.join(C.OUT, "probe_histmore_end.png"))

        st = snap(pg)
        say("\n=== 收尾 ===")
        say("气泡 %d 条（打开时 %d）| 整页重载 %d 次 | 「更早」=%s | 上限提示=%s"
            % (st["bubbles"], base, len(navs) - nav0,
               st["more"] or "无", st["note"] or "无"))
        if inc:
            say("每一次点击这一包的大小（KB）：%s"
                % " ".join("%.0f" % x for x in inc))
            say("  → 最大 %.0f KB，最小 %.0f KB，末次/首次 = %.2f"
                % (max(inc), min(inc), inc[-1] / max(inc[0], 0.001)))
            # ★ 趋势判据：分屏的**设计目标**就是"每翻一屏的量与翻过几屏无关"。
            #   涨上去的话说明退回成了改前那种"重发整个窗口"。
            #   阈值放 2.0 是给噪声留位置（每屏的条数、长短本来就不齐）；
            #   改前那种形态是 192 → 878 KB，末次/首次 = 4.6，一眼就分得开。
            ratio = inc[-1] / max(inc[0], 0.001)
            if len(inc) >= 3 and ratio > 2.0:
                fails.append("第 %d 次这一包是第 1 次的 %.1f 倍 —— 又变成"
                             "「每点一次重发整个窗口」了（分屏的设计目标是"
                             "每屏一包、跟翻过几屏无关）" % (len(inc), ratio))
        br.close()

    if fails:
        say("\n**红**：")
        for f in fails:
            say("  · %s" % f)
        sys.exit(1)
    say("\n全绿：每次点击都多露出消息；每一包都在 %.0f KB 的线内；"
        "慢链路上没有 close / 重载 / 遮罩。" % FRAME_MAX_KB)


if __name__ == "__main__":
    main()
