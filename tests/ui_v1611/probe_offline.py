#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V16.11 item 1：**「先等一下」那颗按钮，到底按出了什么。**

要修的那个洞（`www/app.js` 里 dsappOfflineShow 那颗按钮）：

    它原来接的是 `dsappOfflineHide()` —— 把盖住整页的卡片**整个删掉**。
    删完之后页面看着完好无损，用户接着打字、点发送、点运行，而那些点击
    全部打进一个死 socket：
      · `$sendMsg` 把它们 push 进 `$pendingMessages`（shiny.js:23839），
        而那个数组只在 `socket.onopen` 里 flush（:23668）；
      · 本应用**从没调过** `session$allowReconnect`（全仓只有两处注释提过），
        所以 `reconnect()` 永远不会被调 ⇒ 那个数组到整页重载为止没人排空。
    ⇒ 「提醒」于是变成了「骗人」。而**骗人比挡着更糟**：用户以为没事了。

修完之后的语义：

    dsappOfflineDismiss()  用户说"我先等着" → 大卡片收成左下角**常驻**小条，
                           **状态一个字不改**（还是断着），页面照常能看能打字。
    dsappOfflineHide()     真的好了（心跳回来了 / 重连上了）→ 删卡片、删小条、状态归 up。

★★ 2026-10-07 加了**分两档出场**（用户原话：「服务器现在还是经常未响应，这个提示
   能不能显示的不要这么频繁，即使真的断了，也请间隔一段时间再提示」）：

     判死线（DSAPP_PING_DEAD_MS = 30 秒）到了 → **只出左下角小条**；
     从**离开 up 那一刻**再撑 DSAPP_OFFLINE_CARD_MS = 30 秒 → 才铺整页卡片。

   于是 A 段量的东西变了：判死那一刻要断言**卡片不在**（这就是用户要的"别这么
   频繁"），再等它撑够才断言卡片来。E 段同理。

这个探针要证的几件事（缺一条，上面那段就等于没修）：

  P 段  前置：**正在服务的那份 app.js** 里真的有新符号（不然量的是 rsync 快照）
  A 段  `kill -STOP` 冻住服务端 → **先只出小条**（此时卡片必须**不在**）→
        撑够 CARD_MS 才铺卡片 → 卡片上那颗按钮接的**必须是 Dismiss**
  B 段  点它 → 卡片没了、小条在、**状态还是 silent**；熬过 4 拍看门狗大卡片
        **不许**自己弹回来（弹回来 = 那颗按钮白点）；小条**不许**吃鼠标
  C 段  点小条的「详情」→ 大卡片回来、小条让位（两个指示不许同时在）
  D 段  解冻 → 小条**自己**消失（这条钉的是心跳处理器那处旧写法：
        它原来读卡片在不在，用户一 Dismiss 它就再也撤不掉小条了）
  E 段  反面：**真断线**（kill -9）那一档**没有**「先等一下」—— 真断了只能刷新，
        不许给用户一颗"按了就假装没事"的按钮；同样**先小条、后卡片**

⚠️ 本地实例是 `shiny::runApp` 直接起的，**没有 shiny-server-client**（线上才注入）：
   `kill -STOP` 复现的是 silent 的**症状**，不是线上 worker 被回收的机理。
   本文件里没有一条断言在假装验证线上那条路。
⚠️ pid 一律从 `ss -ltnp` 读，**绝不用 `pkill -f`**（它会连自己一起杀，本仓记过）。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    cp www/app.js www/app.css /tmp/dsapp_v158h/app/www/     # ← 纯 www/ 改动
    python3 tests/ui_v1611/probe_offline.py
"""
import os
import re
import signal
import subprocess
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1611")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "ui_v158"))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

chk = C.Chk()
PORT = int(re.search(r":(\d+)", C.URL).group(1))
os.makedirs(C.OUT, exist_ok=True)
LOG = os.path.join(os.path.dirname(C.APP), "app_v1611.log")


def say(*a):
    print(*a, flush=True)


def app_pid():
    """监听这个端口的 R 进程 pid。⚠️ 只认 `ss`，不认 pkill/proc 名匹配。"""
    try:
        out = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True,
                             timeout=10).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if ":%d " % PORT in line:
            m = re.search(r"pid=(\d+)", line)
            if m:
                return int(m.group(1))
    return None


def stop_app():
    """冻住（SIGSTOP）—— TCP 不断、收不到任何 close 事件，只能靠心跳判死。"""
    pid = app_pid()
    if pid is not None:
        os.kill(pid, signal.SIGSTOP)
    return pid


def cont_app():
    pid = app_pid()
    if pid is not None:
        os.kill(pid, signal.SIGCONT)
    return pid


def kill_app():
    pid = app_pid()
    if pid is None:
        return None
    os.kill(pid, signal.SIGKILL)
    for _ in range(20):
        time.sleep(0.5)
        if app_pid() is None:
            break
    return pid


def start_app():
    fh = open(LOG, "a")
    subprocess.Popen(
        ["/usr/lib/R/bin/exec/R", "-q", "-e",
         'shiny::runApp(port = %d, host = "127.0.0.1", launch.browser = FALSE)' % PORT],
        cwd=C.APP, env=dict(os.environ, R_HOME=os.environ.get("R_HOME", "/usr/lib/R")),
        stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(90):
        time.sleep(1)
        if app_pid() is not None:
            return True
    return False


# ---- 页面状态 ---------------------------------------------------------------
# ⚠️ 取不到的字段一律给 None，**不补默认值** —— "没读到"和"真的是假"是两回事。
#    这里最要命的是 state：补个 "up" 会把"根本没读到 dsappNet"判成"恢复了"。
JS_STATE = """() => {
  var out = { err: null };
  try {
    var off  = document.getElementById('dsapp-offline');
    var mini = document.getElementById('dsapp-offline-mini');
    var n    = window.dsappNet || null;
    out.off  = !!off;
    out.kind = off ? off.getAttribute('data-kind') : null;
    out.mini = !!mini;
    out.mini_kind = mini ? mini.getAttribute('data-kind') : null;
    out.state = n ? n.state : null;
    out.since = n ? n.since : null;
    // 2026-10-07 分两档那两条时间线：从**页面里**读，不写死 —— 探针自己要
    // 拿它算"卡片是不是真的等够了才来"（写死的话，改了常数探针还在量老的）。
    out.dead_ms = (typeof DSAPP_PING_DEAD_MS === 'number') ? DSAPP_PING_DEAD_MS : null;
    out.card_ms = (typeof DSAPP_OFFLINE_CARD_MS === 'number') ? DSAPP_OFFLINE_CARD_MS : null;
    out.conn = !!(window.Shiny && window.Shiny.shinyapp &&
                  window.Shiny.shinyapp.isConnected());
    // 「先等一下」那一颗的 onclick **从活的 DOM 上读**，不是读源码
    out.dismiss_onclick = null;
    out.off_buttons = null;
    if (off) {
      var bs = off.querySelectorAll('button');
      out.off_buttons = [];
      for (var i = 0; i < bs.length; i++) {
        var t = (bs[i].innerText || '').trim();
        out.off_buttons.push(t);
        if (t.indexOf('先等一下') >= 0) {
          out.dismiss_onclick = bs[i].getAttribute('onclick');
        }
      }
    }
    // ⚠️ 几何量之前先确认它**看得见**：隐藏元素的矩形是全 0，拿它做减法
    //    会得到一个看着完全合理的数（本仓栽过）。小条在的时候才有矩形。
    out.mini_rect = null;
    out.mini_pe = null;
    if (mini) {
      var r = mini.getBoundingClientRect();
      out.mini_rect = { x: r.x, y: r.y, w: r.width, h: r.height };
      out.mini_pe = getComputedStyle(mini).pointerEvents;
      // 真正决定"点不点得到"的是 elementFromPoint：小条吃了鼠标的话，
      // 返回的就是小条自己（或它的子节点）。
      var cx = r.x + Math.min(8, r.width / 2), cy = r.y + r.height / 2;
      var el = document.elementFromPoint(cx, cy);
      out.at_point = el ? (el.id || el.className || el.tagName) : null;
      out.at_point_in_mini = !!(el && mini.contains(el));
    }
  } catch (e) { out.err = String(e); }
  return out;
}"""


def state(pg, tries=3):
    """取一次页面状态。⚠️ 拿到 {err} 就重试，**别让它把整个脚本炸成"没跑到"**。"""
    for _ in range(tries):
        try:
            st = pg.evaluate(JS_STATE)
        except Exception as e:
            st = {"err": "evaluate 抛了：%s" % str(e)[:200]}
        if st and not st.get("err"):
            return st
        pg.wait_for_timeout(500)
    return st


def wait_for(pg, pred, timeout, what=""):
    """等页面状态满足 pred。返回 (state, 秒数)；超时返回 (最后一次 state, None)。

    ⚠️ 超时**不返回 None 当状态** —— 把最后一次读到的状态带回去，报错里才有
       "现在到底是什么样"，否则一条红只告诉你"没等到"，方向全靠猜。"""
    t0 = time.time()
    st = None
    while time.time() - t0 < timeout:
        st = state(pg)
        if st and pred(st):
            return st, time.time() - t0
        pg.wait_for_timeout(400)
    return st, None


def wait_overlay(pg, timeout, want_kind=None):
    """等 #dsapp-offline 出现（可选：等它变成某一档）。返回 (state, 秒数)。"""
    return wait_for(pg, lambda s: s.get("off") and
                    (want_kind is None or s.get("kind") == want_kind),
                    timeout, "整页卡片")


def wait_mini(pg, timeout, want_kind=None):
    """等左下角小条出现（可选：等它变成某一档）。返回 (state, 秒数)。"""
    return wait_for(pg, lambda s: s.get("mini") and
                    (want_kind is None or s.get("mini_kind") == want_kind),
                    timeout, "小条")


CONS = []

with sync_playwright() as pw:
    br = pw.chromium.launch()
    pg = br.new_context(viewport={"width": 1440, "height": 900}).new_page()
    pg.on("console", lambda m: CONS.append("%-7s %s" % (m.type, m.text[:300])))
    pg.on("pageerror", lambda e: CONS.append("PAGEERR %s" % str(e)[:300]))
    fx = None
    try:
        if app_pid() is None:
            say("实例没在跑，先拉起来……")
            assert start_app(), "起不来，先跑 make_instance.sh"

        # ================= P 段：防假绿前置 =================
        say("\n== P 段：先证明量的是**新代码**，不是 rsync 快照 ==")
        # ⚠️ 本仓栽过：`make_instance.sh` 是 rsync 副本，实例里的 `www/app.js`
        #    跟 `R/*.R` 一样只在重跑那一刻同步。不先证明"服务的是新版"，
        #    后面全绿/全红都可能在说旧代码 —— 而你会以为在测新的。
        served = pg.request.get(C.URL + "app.js").text()
        chk("P1 ★★★ 正在服务的 app.js 里有 dsappOfflineDismiss（量的是新代码）",
            "dsappOfflineDismiss" in served and "dsapp-offline-mini" in served,
            "服务的那份没有新符号 —— 实例里是 rsync 快照，先 cp 过去")
        css = pg.request.get(C.URL + "app.css").text()
        chk("P2 ★★ 正在服务的 app.css 里有 #dsapp-offline-mini 的样式",
            "#dsapp-offline-mini" in css, "小条没有样式 = 它是一条裸 div")

        C.enter_app(pg)
        ensure_no_modal(pg)
        st = state(pg)
        chk("P3 页面里 window.dsappNet 在（item 0 的状态位）",
            bool(st) and st.get("state") == "up",
            "state=%r err=%r" % (st.get("state") if st else None,
                                 st.get("err") if st else None))

        # ================= A 段：分两档 —— 先小条，撑够了才铺卡片 =================
        say("\n== A 段：冻住服务端 → **先只出小条**（卡片必须还没来）→ 撑够才铺卡片 ==")
        # 页面里的两条时间线，下面算"卡片是不是真等够了"要用
        st0 = state(pg)
        dead_ms = (st0 or {}).get("dead_ms")
        card_ms = (st0 or {}).get("card_ms")
        say("   页面里的时间线：判死 %s ms，卡片再等 %s ms" % (dead_ms, card_ms))
        chk("A-1 ★★ 页面里读得到这两条时间线（读不到 = 量的是别的版本，下面全作废）",
            isinstance(dead_ms, (int, float)) and dead_ms > 0 and
            isinstance(card_ms, (int, float)) and card_ms > 0,
            "dead_ms=%r card_ms=%r" % (dead_ms, card_ms))

        stopped = stop_app()
        say("   冻住 pid=%s（TCP 不断、没有 close 事件）" % stopped)
        t_freeze = time.time()
        # ⚠️ 等的是**小条**不是卡片。等卡片的话，这一整段就变成了在验旧的
        #    "一判死就盖住整页" —— 恰好是用户这次要改掉的那个形状。
        st_blip, dt = wait_mini(pg, 60, want_kind="silent")
        # ⚠️ 这一条是**给整段自证资格**的：冻住没报出来，后面什么都没验。
        chk("A0 冻住真的让页面报了（小条出来；没出来 = 这一整段作废）",
            st_blip is not None and dt is not None,
            "60 秒没出现小条（心跳判死坏了？）最后 state=%r mini=%r"
            % ((st_blip or {}).get("state"), (st_blip or {}).get("mini")))
        if dt is not None:
            t_mini = time.time() - t_freeze
            chk("A1 ★★ 小条报的是 silent 那一档（说明确实**没断**）",
                st_blip.get("mini_kind") == "silent",
                "mini_kind=%r conn=%s" % (st_blip.get("mini_kind"),
                                          st_blip.get("conn")))
            say("   判死用了 %.1f 秒；state=%r" % (t_mini, st_blip.get("state")))
            # ★★★ 这一条就是用户要的"别这么频繁"：判死那一刻**不许**有整页卡片。
            chk("A2 ★★★ 判死这一刻**整页卡片不在**（用户要的「别这么频繁」）",
                not st_blip.get("off"),
                "off=%r kind=%r ← 判死就铺卡片 = 用户抱怨的那个形状又回来了"
                % (st_blip.get("off"), st_blip.get("kind")))
            chk("A3 但状态位已经记着 silent（小条不是画着玩的）",
                st_blip.get("state") == "silent",
                "state=%r" % st_blip.get("state"))

            # ---- 撑够 DSAPP_OFFLINE_CARD_MS 才铺卡片 ----
            # ⚠️ 从**小条出现那一刻**起等，而且要多给 20 秒余量：CARD_MS 计的是
            #    "离开 up 之后"，起算点比小条早一点点（同一拍，可以忽略），
            #    但看门狗 2 秒一拍，卡片只会晚不会早。
            # ⚠️ 读不到就按 30 秒算：A-1 已经红过了，这里再炸一次只会把
            #    "没读到常数"报成"脚本崩了"，方向反而丢了。
            card_s = (card_ms / 1000.0) if isinstance(card_ms, (int, float)) else 30.0
            say("   再等卡片（上限 %.0f 秒）……" % (card_s + 25))
            st_card, dt_card = wait_overlay(pg, card_s + 25, want_kind="silent")
            chk("A4 ★★★ 撑够之后整页卡片才来（这就是「间隔一段时间再提示」）",
                dt_card is not None,
                "等了 %.0f 秒还没来；mini=%r off=%r"
                % (card_s + 25, (st_card or {}).get("mini"),
                   (st_card or {}).get("off")))
            if dt_card is not None:
                gap = (time.time() - t_freeze) - t_mini
                say("   判死 → 卡片：又过了 %.1f 秒（页面里写着 %.1f 秒）"
                    % (gap, card_s))
                # ★ 两档之间**真的**隔了那么久（不是常数改了、行为没跟）。
                #   下限取 0.8 倍：看门狗 2 秒一拍 + 我们 0.4 秒一读，误差是有的，
                #   但差一个数量级（比如常数 30 秒而卡片 3 秒就来了）必须抓得到。
                chk("A5 ★★★ 两档之间确实隔了差不多 DSAPP_OFFLINE_CARD_MS",
                    gap >= card_s * 0.8,
                    "实际只隔了 %.1f 秒，页面里写着 %.1f 秒" % (gap, card_s))
                chk("A6 ★★ 卡片上屏时小条让位（两个指示不许同时在）",
                    not st_card.get("mini"),
                    "mini=%r kind=%r" % (st_card.get("mini"),
                                         st_card.get("mini_kind")))
                chk("A7 ★★★ 卡片上那颗按钮接的是 dsappOfflineDismiss()（**这就是那个洞**）",
                    st_card.get("dismiss_onclick") == "dsappOfflineDismiss()",
                    "onclick=%r ← 接回 dsappOfflineHide() 的话，按下去 = 骗人"
                    % st_card.get("dismiss_onclick"))
                chk("A8 卡片报的也是 silent 那一档",
                    st_card.get("kind") == "silent",
                    "data-kind=%r" % st_card.get("kind"))
                st_blip = st_card          # 下面 B 段接着在卡片上操作

            # ================= B 段：点「先等一下」=================
            say("\n== B 段：点「先等一下」—— 页面还活着，但**不许假装好了** ==")
            btn = pg.locator("#dsapp-offline button", has_text="先等一下")
            chk("B0 按钮找得到、点得动（找不到 = 下面全作废）", btn.count() > 0,
                "count=%d" % btn.count())
            if btn.count() > 0:
                btn.first.click()
                pg.wait_for_timeout(1200)
                st = state(pg)
                chk("B1 ★★ 大卡片收起来了（不再盖住整页）",
                    st and not st.get("off"),
                    "off=%r err=%r" % (st.get("off") if st else None,
                                       st.get("err") if st else None))
                chk("B2 ★★★ 左下角出现常驻小条",
                    bool(st) and st.get("mini") and st.get("mini_kind") == "silent",
                    "mini=%r kind=%r" % (st.get("mini") if st else None,
                                         st.get("mini_kind") if st else None))
                chk("B3 ★★★ **状态还是 silent**（按一下不等于好了 —— 这就是「骗人」的分界线）",
                    bool(st) and st.get("state") == "silent",
                    "state=%r ← 变成 up 就是那个洞换了个样子回来了"
                    % (st.get("state") if st else None))

                # ⚠️⚠️ 这一条最值钱：心跳看门狗原来读的是**卡片在不在**
                #     （`getElementById('dsapp-offline')`），用户一 Dismiss
                #     卡片就没了 ⇒ 它每 2 秒把大卡片重新弹回来一次，
                #     那颗按钮**等于白点**。熬 4 拍再量。
                say("   熬 9 秒（看门狗每 2 秒一拍）看大卡片会不会自己弹回来……")
                pg.wait_for_timeout(9000)
                st9 = state(pg)
                chk("B4 ★★★ 熬过 4 拍看门狗，大卡片**没有**自己弹回来",
                    bool(st9) and not st9.get("off"),
                    "off=%r ← 弹回来了 = 那颗按钮白点（看门狗在读卡片）"
                    % (st9.get("off") if st9 else None))
                chk("B5 小条还在（它常驻，不是一闪而过）",
                    bool(st9) and st9.get("mini"),
                    "mini=%r" % (st9.get("mini") if st9 else None))

                # 小条**不许**吃鼠标：它左下角常驻，吃掉的话左侧栏底部/状态栏
                # 会莫名其妙点不动 —— 又一个"看起来是页面坏了"。
                rect = (st9 or {}).get("mini_rect") or {}
                chk("B6 几何量之前先确认小条**看得见**（矩形不是全 0）",
                    bool(rect) and rect.get("w", 0) > 10 and rect.get("h", 0) > 5,
                    "rect=%r ← 0 矩形上做的减法看着完全合理但是假的" % (rect,))
                chk("B7 ★★★ 小条不吃鼠标（pointer-events: none）",
                    bool(st9) and st9.get("mini_pe") == "none",
                    "pointer-events=%r" % (st9.get("mini_pe") if st9 else None))
                chk("B8 ★★★ 小条所在那一点，最上层是**别的东西**（它真的不挡点击）",
                    bool(st9) and st9.get("at_point_in_mini") is False,
                    "那一点上是 %r（是小条自己 = 它挡着）"
                    % (st9.get("at_point") if st9 else None))

                # ================= C 段：「详情」把大卡片要回来 =================
                say("\n== C 段：点小条的「详情」= 大卡片回来、小条让位 ==")
                d = pg.locator("#dsapp-offline-mini .dsapp-offline-mini-btn")
                chk("C0 「详情」按钮在（用户得有路再看一眼全文）", d.count() > 0,
                    "count=%d" % d.count())
                if d.count() > 0:
                    d.first.click()
                    pg.wait_for_timeout(1200)
                    st = state(pg)
                    chk("C1 大卡片回来了", bool(st) and st.get("off"),
                        "off=%r" % (st.get("off") if st else None))
                    chk("C2 ★★ 小条让位了（两个指示**不许**同时在）",
                        bool(st) and not st.get("mini"),
                        "mini=%r ← 同时挂着就是"
                        "'左下角说断着、中间又弹一张说断着'"
                        % (st.get("mini") if st else None))
                    chk("C3 状态还是 silent（看了详情也不代表好了）",
                        bool(st) and st.get("state") == "silent",
                        "state=%r" % (st.get("state") if st else None))

                # ================= D 段：解冻 → 小条要**自己**消失 =================
                say("\n== D 段：解冻 → 小条必须**自己**消失 ==")
                # 先再 Dismiss 一次，让"恢复时要撤掉的那个东西"是**小条**。
                # ⚠️ 这条钉的是心跳处理器那处旧写法：它原来读
                #    `getElementById('dsapp-offline')`，用户一 Dismiss 那个
                #    节点就没了 ⇒ 服务端活过来了、小条却**永远撤不掉**，
                #    左下角一直挂着"在等它回来…"直到用户自己刷新。
                btn2 = pg.locator("#dsapp-offline button", has_text="先等一下")
                if btn2.count() > 0:
                    btn2.first.click()
                    pg.wait_for_timeout(1000)
                st = state(pg)
                chk("D0 恢复前，挂着的是小条（不是大卡片）—— 下面才量得到东西",
                    bool(st) and st.get("mini") and not st.get("off"),
                    "mini=%r off=%r" % (st.get("mini") if st else None,
                                        st.get("off") if st else None))
                say("   解冻 pid=%s" % cont_app())
                gone, t_gone = None, None
                t0 = time.time()
                while time.time() - t0 < 60:
                    st = state(pg)
                    if st and st.get("state") == "up":
                        gone = time.time() - t0
                        break
                    pg.wait_for_timeout(1000)
                chk("D1 ★★★ 心跳回来之后状态归 up（%.1f 秒）" % (gone if gone else -1),
                    gone is not None, "60 秒了还停在 %r"
                    % (st.get("state") if st else None))
                st = state(pg)
                chk("D2 ★★★ 小条**自己**消失了（没让用户手动刷新）",
                    bool(st) and not st.get("mini") and not st.get("off"),
                    "mini=%r off=%r ← 小条赖着不走 = 心跳处理器在读卡片"
                    % (st.get("mini") if st else None,
                       st.get("off") if st else None))
                chk("D3 恢复**不是**靠整页重载（页面是同一个）",
                    pg.evaluate("() => !!window.dsappNet") is True,
                    "window.dsappNet 没了 = 页面被重载过")
                pg.screenshot(path=os.path.join(C.OUT, "offline_D_recovered.png"))

        # ================= E 段：反面 —— 真断线那一档没有这颗按钮 =================
        say("\n== E 段：反面 —— **真断线**（kill -9）先小条、同样不许有「先等一下」==")
        # 真断线是"连接没了"，等下去不会好，只能刷新。给一颗"按了就假装没事"
        # 的按钮，就是把这个洞请回来。
        say("   打死 pid=%s" % kill_app())
        # ⚠️ 这一档**也不许**立刻铺卡片（2026-10-07）：socket 刚收到 close 的
        #    那一秒，线上 shiny-server-client 还在替我们重连（reconnectTimeout
        #    15 秒），一大半的 close 根本轮不到用户看见。
        st_dead = None                 # 下面超时路径也要能走到（别 NameError）
        st_m, dt_m = wait_mini(pg, 20)
        chk("E0 真断线确实报了（小条出来；没出来 = 这一节作废）",
            dt_m is not None,
            "20 秒没出现小条；state=%r mini=%r off=%r"
            % ((st_m or {}).get("state"), (st_m or {}).get("mini"),
               (st_m or {}).get("off")))
        if dt_m is not None:
            chk("E1 ★★ 小条报的是 down 那一档（真断，不是 silent 的猜测）",
                st_m.get("mini_kind") == "down",
                "mini_kind=%r state=%r" % (st_m.get("mini_kind"),
                                           st_m.get("state")))
            chk("E1b ★★★ 刚断这一刻**整页卡片不在**（闪断不该惊动用户）",
                not st_m.get("off"),
                "off=%r ← 一断就铺卡片，线上那些重连就能好的闪断全会弹一次"
                % (st_m.get("off"),))
            # 卡片这一档两条来路：自愈在 DSAPP_HEAL_GRACE_MS(20 秒) 后开口
            # （dsappHealNote 会保证卡片先在），或者撑够 CARD_MS 后看门狗升级。
            # 哪条先到都行，这里只等"卡片来",不问是谁铺的。
            st_dead, dt = wait_overlay(pg, 50)
            chk("E2 撑一会儿之后整页卡片来了（没来 = 真断了还只挂条小字）",
                dt is not None, "50 秒没出现；mini=%r state=%r"
                % ((st_dead or {}).get("mini"), (st_dead or {}).get("state")))
        if st_dead is None:
            st_dead = state(pg)
        if st_dead.get("off"):
            chk("E3 报的是 disconnected 那一档",
                st_dead.get("kind") == "disconnected",
                "data-kind=%r" % st_dead.get("kind"))
            chk("E4 ★★★ 这一档**没有**「先等一下」（真断了只能刷新）",
                st_dead.get("dismiss_onclick") is None,
                "按钮=%r ← 真断线还给「先等一下」，用户按下去就是被骗"
                % (st_dead.get("off_buttons"),))
            chk("E5 但有「刷新页面」那颗（不能把用户锁死）",
                bool(st_dead.get("off_buttons")) and
                any("刷新" in b for b in (st_dead.get("off_buttons") or [])),
                "按钮=%r" % (st_dead.get("off_buttons"),))
        pg.screenshot(path=os.path.join(C.OUT, "offline_E_disconnected.png"))

        say("\n---- 浏览器控制台（dsapp 那几句该在这里）----")
        for c in CONS[-25:]:
            say("   " + c)
        br.close()
    finally:
        if fx:
            fx.stop()
        # ⚠️ 收尾：实例**留活着**（后面的探针还要用），但要保证它确实在跑
        if app_pid() is None:
            say("\n（实例被本探针打死了，正在拉起来……）")
            say("   起来了" if start_app() else "   ⚠️ 没起来，手动跑 make_instance.sh")
sys.exit(chk.done())
