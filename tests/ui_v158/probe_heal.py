#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.9 item 1：**断线之后，页面能不能自己回来。**

用户原话（2026-10-02，账号 Biomamba_ceshi）：
    「与服务器的连接断了 / 应用可能刚重启或更新过。现在这个页面上的按钮点了
      不会有任何反应。」

线上取证（从库里、从进程表、从 shiny-server 源码读出来的，不是推断）：
    · 21:06:12 一条 2211 字的回复**完整落库**（LLM 那次 status=done）；
    · 21:06:25 `login_sessions.last_seen_at` 还在被心跳写 → 那一刻会话还活着；
    · 21:06:25 之后 socket 断了，**5 秒后 worker 被回收**（`app_idle_timeout`
      默认 5 秒，见 /opt/shiny-server/lib/router/config-router-util.js:55）；
    · worker 的日志文件**没了** —— 而删日志这件事只在 idle 回收那条路上做
      （lib/scheduler/scheduler.js:234），所以那是**空闲回收，不是崩溃**；
    · 今天 `data/logs/app_error.log` 一条都没有 → 不是 R 报错打死的；
    · auth.log 里没有 uid=11 被顶下线那行 → 不是被别的端踢了。

    → 用户看到的不是"应用崩了"，是**一个再也回不来的页面**。

这个探针证的就是最后那句话，以及修完之后它不再成立：

  A 段  先让页面跑活（一问一答，走假 LLM）
  B 段  把服务端进程**打死** —— 断线提示该出现，且是 disconnected 那一种
  C 段  把服务端**拉起来** —— ★★★ 页面该**自己**回来（全程一次都不点）
  D 段  回来之后功能真的还在（再问一轮，还是只打假服务端）
  E 段  反面：**服务端在忙（没断）的时候一个字都不许动**（`kill -STOP` 冻住
        R 进程 60 秒 → 该报 silent、该一次都不重载、解冻后该自己好）

⚠️ B 段之所以必须先看 `kind`：第一版自愈代码是"C 段永远不绿"的 ——
   `disconnected` 挂上 16 秒后，**心跳看门狗**会把它换成 `silent`
   （心跳超时在任何断线里都必然成立），自愈那段当时只认 `disconnected`，
   下一拍就自己把自己关了。看门狗现在不降级了，自愈也不再看 `kind`。
   tests/ui_v158/diag_heal.py 里有那一幕的逐秒记录。

⚠️⚠️ 为什么必须有 C 段：这个应用从来没调过 `session$allowReconnect`，
   Shiny Server 注入的 shiny-server-client 只管**传输层**重连（它连上的是
   一个**新** worker、**新** session），前端那块提示的撤销条件是
   `isConnected()` —— worker 被回收之后这个条件**永远不会**成立。
   所以"用户得手动刷新"不是运气差，是**结构上必然**。C 段量的是这件事。

⚠️ 测试实例里 **R 进程就是服务器本身**（线上才另有独立 worker），所以
   "打死服务端"就是 kill 那个监听 8953 的 pid。绝不用 `pkill -f`（它会
   连自己一起杀，本仓记过）；pid 一律从 `ss -ltnp` 里读。

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    python3 tests/ui_v158/probe_heal.py
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from probe_ctx import ensure_no_modal, send as send_wait   # noqa: E402

chk = C.Chk()
PORT = int(re.search(r":(\d+)", C.URL).group(1))
# ⚠️ 两次运行**别写同一个日志文件**（截断 + 各自的 fd 偏移 → 交错成垃圾）。
LOG = os.path.join(os.path.dirname(C.APP),
                   "app_heal_%d.log" % int(time.time()))
CONS = []          # 浏览器控制台（自愈那两句日志在这里）
PAGES_ = []        # 页面导航次数（判"是不是真的整页重载了"）
MARKS = []         # 重载前打在 window 上的标记，重载后会消失


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


# ---- 起停实例里的那个 R 进程 ------------------------------------------------
def app_pid():
    """听 8953 的那个 pid。⚠️ 从 ss 里读，不用 pgrep（它会连探针自己一起匹配上）。"""
    try:
        out = subprocess.run(["ss", "-ltnp"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT).stdout.decode("utf-8", "replace")
    except Exception:
        return None
    for ln in out.splitlines():
        if (":%d " % PORT) in ln:
            m = re.search(r"pid=(\d+)", ln)
            if m:
                return int(m.group(1))
    return None


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


def stop_app():
    """冻住（SIGSTOP），**不是**打死 —— TCP 不断，收不到任何 close 事件。

    E 段量的是"服务端在跑重活"那一幕：前端**分不出**它和"服务端死了"，
    所以只能靠心跳判死。这一节要证的正是"分不出的那一侧**别乱动**"。"""
    pid = app_pid()
    if pid is not None:
        os.kill(pid, signal.SIGSTOP)
    return pid


def cont_app():
    pid = app_pid()
    if pid is not None:
        os.kill(pid, signal.SIGCONT)
    return pid


# ---- 页面状态 ---------------------------------------------------------------
# ⚠️ 取不到的字段一律给 None，**不补默认值** —— "没读到"和"真的是假"是两回事
#    （本仓老规矩；这里最要命的是 off/shell，补默认值会把"没跑到"判成"恢复了"）。
JS_STATE = """() => {
  var d = document.getElementById('dsapp-offline');
  var mi = document.getElementById('dsapp-offline-mini');
  var nw = window.dsappNet || null;
  var mk = null;
  try { mk = window.__heal_mark || null; } catch (e) {}
  var st = null;
  try { st = sessionStorage.getItem('dsapp_heal'); } catch (e) {}
  return {
    url: location.href,
    off: !!d,
    kind: d ? d.getAttribute('data-kind') : null,
    title: d ? (d.innerText || '').split('\\n')[0] : null,
    body: d ? (d.innerText || '') : null,
    // ★ 2026-10-07 起「报出来了」的第一个信号是左下角**小条**，不是整页卡片
    //   （判死只出小条，撑够 DSAPP_OFFLINE_CARD_MS 才铺卡片）。少读这一项的话，
    //   "冻住没报出来"和"报了、只是先出的小条"就分不开了。
    mini: !!mi,
    mini_kind: mi ? mi.getAttribute('data-kind') : null,
    net: nw ? nw.state : null,
    shell: !!document.querySelector('.dsapp-shell'),
    auth: !!document.querySelector('.dsapp-auth'),
    n: (document.body.innerText || '').length,
    mark: mk,
    heal_n: st,
    heal_timer: (typeof window.dsappHealTimer === 'undefined') ? 'undefined'
                : (window.dsappHealTimer === null ? null : '有')
  };
}"""


def state(pg):
    try:
        return pg.evaluate(JS_STATE)
    except Exception:
        return None          # 多半正在导航，调用方自己判 None


def wait_overlay(pg, sec, mini_ok=True):
    """等服务端"报出来"。

    ★ 2026-10-07 起"报出来"分两档：先小条（判死那一刻），撑够才铺整页卡片。
      `mini_ok=True`（默认）表示**小条也算报出来了** —— 它代表的正是"前端已经
      知道不对劲"这件事，而下面几条要证的（kind、自愈有没有自己收工）都只
      跟这件事有关，跟铺的是哪一档无关。
      要专门等那张卡片的（比如要读卡片标题），传 `mini_ok=False`。"""
    t0 = time.time()
    while time.time() - t0 < sec:
        st = state(pg)
        if st and (st.get("off") or (mini_ok and st.get("mini"))):
            return st, time.time() - t0
        pg.wait_for_timeout(500)
    return None, None


def hist(pg):
    try:
        return pg.inner_text("#chat-history")
    except Exception:
        return ""


def wait_hist(pg, needle, sec=90):
    """等某段文字**真的进到对话区**再断言。

    ⚠️ `send_wait()` 里的 `wait_idle` 先等"忙起来"、等不到就往下走（见
    _common.py 里那段注释），所以它返回 True **不代表这一轮跑完了** ——
    第一次跑这个探针时 A 段就是这么红的："回复没进 #chat-history"，
    而那条回复其实过了十几秒才落库。**没等到**和**没发生**要分得开。"""
    t0 = time.time()
    while time.time() - t0 < sec:
        if needle in hist(pg):
            return True
        pg.wait_for_timeout(500)
    return False


def main():
    say("实例：%s（端口 %d）" % (C.APP, PORT))
    say("app 日志：%s" % LOG)
    fx = C.FakeLLM()
    bad = 0
    try:
        with sync_playwright() as pw:
            br = pw.chromium.launch()
            ctx = br.new_context(viewport={"width": 1440, "height": 900})
            pg = ctx.new_page()
            pg.on("console", lambda m: CONS.append("%-7s %s" % (m.type, m.text[:200])))
            pg.on("pageerror", lambda e: CONS.append("PAGEERR %s" % str(e)[:200]))
            pg.on("framenavigated",
                  lambda f: PAGES_.append(f.url) if f == pg.main_frame else None)

            # ================= A 段 =================
            say("\n== A 段：先把页面跑活 ==")
            email = C.enter_app(pg)
            uid, _db = C.seed_or_die(email)
            C.seed_llm(uid, fx.url)

            # ⚠️⚠️ 种完**必须整页重载**再往下走。`state$base_url` 是
            #   mod_model 的加载器在**会话开始那一刻**从库里读一次就记牢的
            #   （R/mod_model.R:396 + loaded_for() 备忘），而我们是**先建号、
            #   后种库** —— 不重载的话这一页手上还是那个空 base_url，发消息
            #   就会落到**厂商的默认地址**上去。
            #   2026-10-02 就是这么真打出去了一条请求（拿到 401），顺带把
            #   种子里"API Key 被写成行号"那个 bug 一起炸了出来。
            pg.reload(wait_until="domcontentloaded")
            back_ok = False
            for _ in range(120):
                pg.wait_for_timeout(1000)
                st = state(pg)
                if st and st.get("shell"):
                    back_ok = True
                    break
            # ⚠️ 这里等的是 `.dsapp-shell` 而**不是** `wait_awake()` 认的
            #    `.dsapp-auth`：带着 cookie 重载是**直进主界面**的，auth 那一
            #    层根本不会出现，用 `wait_awake` 会一直等到超时。
            chk("A0 种完重载之后回到了主界面（cookie 直进，不用重新登）", back_ok,
                "120 秒没进 shell")

            # ★★ 防火墙：**发消息之前**先验一次"这一页会打到哪儿"。
            #    上面那次 401 的代价是一条真实的出网请求 —— 事后断言拦不住它，
            #    只有发之前查、查不过就退，才叫拦住。模型页那个输入框显示的就是
            #    settings 里存的那个地址（也就是 state$base_url 的来源）。
            C.goto(pg, "model")
            try:
                shown = pg.input_value("#model-base_url", timeout=10000)
            except Exception as e:
                sys.exit("读不到 #model-base_url（%s）—— 没验过地址就不发消息"
                         % str(e).splitlines()[0])
            if ("127.0.0.1:%d" % fx.port) not in (shown or ""):
                sys.exit("拒绝继续：应用当前的 base_url 是 [%s]，不是假 LLM（%s）。\n"
                         "  这一跑会打到真厂商 —— 停下来先查为什么没生效。"
                         % (shown, fx.url))
            say("   防火墙过了：应用当前 base_url = %s" % shown)
            C.goto(pg, "chat")
            ensure_no_modal(pg)

            # 地基：**正在服务的那份 app.js 里有没有这段自愈代码**。
            # ⚠️ 少了这一条，下面 C 段绿了也可能是假绿：实例跑的是老副本，
            #    而"跑的是别人"看起来和"全绿"一模一样（本仓记过好几次）。
            served = pg.evaluate(
                "async () => { const r = await fetch('app.js', {cache:'no-store'});"
                " return await r.text(); }")
            chk("A1 ★★ 实例正在服务的那份 app.js 里有自愈代码（否则后面全是假绿）",
                "dsappHealStart" in served and "DSAPP_HEAL_GRACE_MS" in served,
                "服务到 %d 字符，没找到 dsappHealStart" % len(served))

            fx.set_queue(C.sse(content="第一轮：在的。"))
            send_wait(pg, "在吗")
            ensure_no_modal(pg)
            chk("A2 断线之前一问一答是通的（这段红了后面都不用看）",
                wait_hist(pg, "第一轮：在的。"), "回复没进 #chat-history")
            chk("A3 这一轮只打了假 LLM（没打到真厂商）", fx.req_n() > 0,
                "假 LLM 一个请求都没收到")
            n_req = fx.req_n()
            pg.screenshot(path=os.path.join(C.OUT, "heal_A_alive.png"))

            # 打个标记：整页重载之后它会没（比重载前后 diff DOM 可靠）
            pg.evaluate("() => { window.__heal_mark = 'A段打的'; }")

            # ================= B 段 =================
            say("\n== B 段：把服务端打死（线上那一幕）==")
            pid = kill_app()
            chk("B0 杀之前确实找到了监听 %d 的进程" % PORT, pid is not None,
                "ss -ltnp 里没有 —— 实例没起来？")
            say("   已经 kill -9 %s" % pid)
            # ⚠️ 这里专门等**卡片**（mini_ok=False）：下面 B2/B3 要读 kind 和标题，
            #    而小条那一档的 kind 是 "down"、也没有标题 —— 拿小条当"卡片来了"
            #    会让 B2/B3 报成"提示画错了"，其实只是**还没到**。
            #    （2026-10-07 起 `shiny:disconnected` 先出小条，卡片由自愈在
            #     DSAPP_HEAL_GRACE_MS=20 秒后铺。）
            st, dt = wait_overlay(pg, 40, mini_ok=False)
            chk("B1 服务端没了之后，断线提示出现了", st is not None,
                "等了 40 秒没出现（socket 断没断？看截图）")
            if st:
                say("   遮罩在 %.1f 秒后出现" % dt)
                chk("B2 是 disconnected 那一种（不是 silent —— 那种不能重载）",
                    st.get("kind") == "disconnected", "data-kind=%r" % st.get("kind"))
                chk("B3 标题就是用户看到的那句", "与服务器的连接断了" in (st.get("title") or ""),
                    "标题=%r" % st.get("title"))
            # ⚠️ 熬过**心跳判死**再量一次。心跳超时这条判据在任何断线里
            #    都必然成立，所以看门狗一定会在这时候来敲门 —— 它**不许**把这块
            #    "socket 真的收到了 close"的提示降级成"可能是忙"（那是猜测，
            #    而且会把用户往"等它跑完"这条错路上引）。
            #    第一版自愈就是死在这儿：看门狗一换 kind，自愈下一拍自己收工，
            #    页面从此永远回不来（逐秒记录见 tests/ui_v158/diag_heal.py）。
            # ⚠️⚠️ 这个等待**必须真的跨过判死线**（本仓老账：熬不过那个时间常数
            #    的断言，量到的是"还没来得及发生"，全绿也是白送）。判死线
            #    2026-10-07 从 16 秒改成 30 秒 ⇒ 这里原来那 22 秒会**整段落在
            #    判死之前**，看门狗压根没敲过门，B4 就变成了自说自话。
            #    B1 已经等掉了 ~20 秒（卡片是自愈在宽限期后铺的），再等 40 秒
            #    就是判死之后又过了 30 秒，够它敲好几拍了。
            pg.wait_for_timeout(40000)
            st = state(pg)
            chk("B4 ★★ 熬过心跳判死之后：提示没被降级成 silent、自愈也没自己收工",
                bool(st) and st.get("kind") == "disconnected"
                and st.get("heal_timer") == "有",
                "kind=%r heal_timer=%r" % (st.get("kind") if st else None,
                                           st.get("heal_timer") if st else None))
            pg.screenshot(path=os.path.join(C.OUT, "heal_B_dead.png"))

            # ================= C 段 =================
            say("\n== C 段：把服务端拉起来 —— 页面该自己回来（一次都不点）==")
            up = start_app()
            chk("C1 服务端又听着 %d 了" % PORT, up,
                "90 秒没起来，看 %s" % LOG)
            if up:
                t0 = time.time()
                back, dt2 = None, None
                while time.time() - t0 < 150:
                    st = state(pg)
                    # 页面正在重载时 state() 抛异常 → None，继续等
                    if st and st.get("shell") and not st.get("off"):
                        back, dt2 = st, time.time() - t0
                        break
                    pg.wait_for_timeout(1000)
                chk("C2 ★★★ 页面**自己**换了一份文档（标记没了 = 真的整页重载过）",
                    back is not None and back.get("mark") is None,
                    ("150 秒没回来" if back is None else
                     "页面回来了但标记还在 —— 不是重载，是别的东西在动"))
                if back:
                    say("   服务端起来后 %.1f 秒，页面自己回来了" % dt2)
                    chk("C3 ★★ 重载之后自动登录仍然成立（落回主界面，不用重新登）",
                        back.get("shell") and not back.get("auth"),
                        "shell=%s auth=%s 正文 %d 字" % (back.get("shell"),
                                                        back.get("auth"), back.get("n")))
                    chk("C4 自愈真的跑过（控制台留下那句日志）",
                        any("自动刷新页面" in c for c in CONS),
                        "控制台里没有那句；见下面的控制台清单")
                    chk("C5 重载次数没失控（sessionStorage 里 1~2 次）",
                        (back.get("heal_n") or "[]").count(",") <= 2,
                        "heal=%r" % back.get("heal_n"))
                pg.screenshot(path=os.path.join(C.OUT, "heal_C_back.png"))

            # ================= D 段 =================
            say("\n== D 段：回来之后是真的能用，不是画出来的假页面 ==")
            try:
                ensure_no_modal(pg)
                C.goto(pg, "chat", wait=4000)
                fx.set_queue(C.sse(content="第二轮：回来了。"))
                send_wait(pg, "还在吗")
                chk("D1 恢复之后还能发消息并收到回复",
                    wait_hist(pg, "第二轮：回来了。"), "回复没进 #chat-history")
                chk("D2 这一轮也只打了假 LLM", fx.req_n() > n_req,
                    "假 LLM 的请求数没涨（%d → %d）" % (n_req, fx.req_n()))
            except Exception as e:
                chk("D1 恢复之后还能发消息并收到回复", False, "炸了：%s" % str(e)[:200])

            # ================= E 段 =================
            # 反面：**服务端在忙**（没断）的时候，一个字都不许动。
            #
            # ⚠️ 这一节原来是"CDP 断网 8 秒再放开"（想量"短抖动不该重载"），
            #    本地复现不了，已换掉：本地实例是 `shiny::runApp` 直接起的，
            #    **没有 shiny-server-client**（那是 Shiny Server 注入的），
            #    所以本地一旦 socket 断了就是**永久**断了 —— "抖一下自己接上"
            #    这条路径在本地压根不存在，量出来的只会是个假象。
            #    线上那条路由 20 秒宽限期给传输层重连让路（shiny-server-client
            #    的 reconnectTimeout 是 15 秒），这条**只能靠代码里那个大小关系
            #    保证**，本地没有东西可以证明它 —— 不装作验过。
            #
            #    换成的这一幕不但能复现，而且更要命：`kill -STOP` 冻住 R 进程
            #    —— TCP 还在、**收不到任何 close 事件**，前端只能靠"它 16 秒没
            #    跟我说话"判死。而服务端"在跑一个很重的活"和"死了"在前端长得
            #    一模一样 —— 这正是**重载会把用户正在跑的活扔掉**的那一幕。
            say("\n== E 段：反面 —— 服务端**忙/卡住**（没断）时绝不许整页重载 ==")
            say("   （kill -STOP 冻住 R 进程：TCP 不断、没有 close 事件，")
            say("    只能走\"心跳超时\"那条路。这时候重载 = 扔掉用户正在跑的活。）")
            pg.evaluate("() => { window.__heal_mark = 'E段打的'; }")
            n_nav = len(PAGES_)
            heal_before = (state(pg) or {}).get("heal_n")
            say("   冻住 pid=%s（导航次数基线 %d，heal=%s）"
                % (stop_app(), n_nav, heal_before))
            # ⚠️ 55 秒，不是 40：2026-10-07 起判死线是 30 秒（原来 16 秒），
            #    而且那一刻先出的是**左下角小条** —— 40 秒在这个新时序上贴着边，
            #    一次普通抖动就能把 E0 报成"冻住没报出来"，方向全丢。
            st_blip, dt = wait_overlay(pg, 55)
            say("   冻住之后报出来了：%s（%.1f 秒）" % (bool(st_blip), dt if dt else -1))
            # ⚠️ 这一条是**给 E 段自证资格**的：冻住没报出来，这一节什么都没验，
            #    必须说出来 —— 别让"没触发"混进"没重载"里冒充证据。
            #    （"报出来"两档都算：小条和卡片都在说"前端已经知道不对劲了"，
            #      而这一节要证的是"知道不对劲的时候它**没有**去重载"。）
            chk("E0 冻住真的让页面报出来了（没报 = 这一节作废）",
                st_blip is not None, "55 秒没出现（心跳判死坏了？）")
            if st_blip is not None:
                shown = st_blip.get("kind") or st_blip.get("mini_kind")
                chk("E1 ★★ 报的是 silent 那种（说明确实**没断**，走的另一条路）",
                    shown == "silent" and st_blip.get("net") == "silent",
                    "卡片 kind=%r 小条 kind=%r 状态=%r"
                    % (st_blip.get("kind"), st_blip.get("mini_kind"),
                       st_blip.get("net")))
                # 熬过自愈的宽限期（20 秒）再加两拍 —— 这段时间里自愈一步都不许动
                time.sleep(30)
                st = state(pg)
                chk("E2 ★★★ 熬过自愈宽限期之后：标记还在、一次导航都没有",
                    bool(st) and st.get("mark") == "E段打的"
                    and len(PAGES_) == n_nav,
                    "mark=%r 导航 %d→%d heal=%s→%s"
                    % (st.get("mark") if st else None, n_nav, len(PAGES_),
                       heal_before, st.get("heal_n") if st else None))
                say("   解冻 pid=%s" % cont_app())
                gone = None
                t0 = time.time()
                while time.time() - t0 < 60:
                    st = state(pg)
                    # ★ 2026-10-07：**两档都得撤**。只判 `not off` 的话，
                    #   小条赖在左下角也照样算"消失了"（而它写着"在等它回来…"，
                    #   是一句假话 —— 这正是本仓"节点即事实"那类旧账的形状）。
                    if st and not st.get("off") and not st.get("mini") \
                            and st.get("net") == "up":
                        gone = time.time() - t0
                        break
                    pg.wait_for_timeout(1000)
                chk("E3 解冻之后提示自己消失了（心跳回来了，没用着重载）",
                    gone is not None, "60 秒了还挂着")
                st = state(pg)
                chk("E4 ★★ 解冻之后标记还在 —— 恢复也不是靠整页重载",
                    bool(st) and st.get("mark") == "E段打的",
                    "mark=%r 导航 %d→%d"
                    % (st.get("mark") if st else None, n_nav, len(PAGES_)))
            pg.screenshot(path=os.path.join(C.OUT, "heal_E_busy.png"))

            say("\n---- 浏览器控制台（自愈那几句该在这里）----")
            for c in CONS[-25:]:
                say("   " + c)
            br.close()
    finally:
        fx.stop()
        # ⚠️ 收尾：把实例**留活着**（后面的探针还要用），但要保证它确实在跑
        if app_pid() is None:
            say("\n（实例被本探针打死了，正在拉起来……）")
            say("   起来了" if start_app() else "   ⚠️ 没起来，手动跑 make_instance.sh")
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
