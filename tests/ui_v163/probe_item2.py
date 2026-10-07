# -*- coding: utf-8 -*-
"""V16.3 item 2：模型服务页的代理（VPN）设置 —— 真让它绕一次。

用户原话：「模型服务里额外加一个VPN设置，用户填写自己的代理地址、端口、协议
信息、订阅密匙后可以访问境外模型和数据，订阅密匙同样需要加密处理」。

这一条**不能靠读源码验**。代理写错的样子全都一样：设置页显示「已启用」，
请求却还是从本机 IP 直连出去 —— 中间没有任何一步会失败。所以这条探针起两个
**真的代理服务器**，让流量必须从它们身上过：

  ① 走没走代理：账号的 `base_url` 指到一个**解析不了**的域名
     （`http://proxy-only.invalid:8080`，RFC 2606 的保留 TLD，永远不解析）。
       · 经过代理 → 代理拿到的是域名（HTTP 代理按绝对 URI 收、SOCKS5 按
         域名形式的 CONNECT 收），它**不解析目标主机**，直接答 200；
       · 没经过代理 → curl 去解析那个域名，必然失败。
     也就是说"消息能出来"这件事本身，就是"请求真的从代理走了"的证明。
  ② 两种协议都真跑一遍（HTTP / SOCKS5h）。SOCKS5h 是默认那一档、也是境外
     场景里最常用的一档，而它和 HTTP 代理**是两套完全不同的握手** ——
     只测 HTTP 的话，SOCKS5 那条路写错了照样全绿。
     ★ SOCKS5h 那条还多钉一条：CONNECT 里的目标必须是**域名**（ATYP=3），
       不是解析好的 IP。这正是 socks5h 与 socks5 的分界，也是"DNS 被污染时
       还连得上"的原因。
  ③ 密匙真的用上了：两个假代理都**要求鉴权** —— HTTP 那边缺
     `Proxy-Authorization` 回 407；SOCKS5 那边走 RFC 1929 的用户名/密码
     子协商，不对就拒绝。密匙没传到、或者「密匙用途」映射错了 → 连不上。
  ④ 库里那一格是**密文**：直接读 sqlite（含 -wal），`sub_key` 以 `v1:` 开头、
     明文一个字节都不在库里，而且能解回原文。
  ⑤ 已经存下的密匙**不许回到页面上**：刷新之后输入框是空的（placeholder 说
     「已保存（留空 = 不改）」），页面 HTML 里搜不到明文。
  ⑥ 关掉开关就走直连：反手再发一条，两个假代理**一条新请求都收不到**。
     少了这一条，"代理关不掉"也能全绿 —— 而关不掉的代理比没有代理更糟。

跑法：
    bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a
    python3 tests/ui_v163/probe_item2.py
"""
import base64
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
FAIL = []
NCHECK = [0]

# 假代理必须收到的凭据。key_mode 选「用户名和密码都填它」时，
# dsapp_proxy_opts() 会把密匙同时当成 user 和 pass（curl 只有 user:pass 一种
# 写法，各家订阅服务的鉴权方式不一样 —— 见 R/proxy.R 里 DSAPP_PROXY_KEY_MODES）。
PROXY_KEY = "sk-sub-9xQ2"
EXPECT_AUTH = PROXY_KEY + ":" + PROXY_KEY
PROXY_USER = "u1"

# ⚠️ 这个域名**必须解析不了**，而且**不能**是 127.0.0.1/localhost/::1 ——
#    dsapp_proxy_opts() 里钉死了一条 noproxy，回环永远直连（本地模型、本机
#    服务不该被代理带走，而那个域名解析得了的话这条探针就什么都证明不了）。
GHOST_HOST = "proxy-only.invalid"
GHOST_PORT = 8080
GHOST_URL = "http://%s:%d" % (GHOST_HOST, GHOST_PORT)


def check(name, ok, extra=""):
    NCHECK[0] += 1
    print("  %s %s%s" % ("✅" if ok else "❌", name,
                         ("  — " + extra) if extra else ""), flush=True)
    if not ok:
        FAIL.append(name)
    return ok


class _Base(object):
    def __init__(self):
        self.hits = []
        self.lock = threading.Lock()
        self.n_denied = 0
        self.reply = C.sse("代理这一路通了。")

    def n(self):
        with self.lock:
            return len(self.hits)

    def last(self):
        with self.lock:
            return self.hits[-1] if self.hits else None

    def record(self, **kw):
        kw["at"] = time.time()
        with self.lock:
            self.hits.append(kw)


class FakeHttpProxy(_Base):
    """收**绝对 URI** 的 HTTP 代理，要求 Basic 鉴权，不解析目标主机。

    只要目标域名会被解析，这条测试就失败了：能出字 = 请求是被代理带进来的。
    """

    def __init__(self):
        import http.server
        _Base.__init__(self)
        proxy = self

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _auth(self):
                got = self.headers.get("Proxy-Authorization") or ""
                if not got.lower().startswith("basic "):
                    return None
                try:
                    return base64.b64decode(got.split(None, 1)[1]).decode("utf-8")
                except Exception:
                    return None

            def _handle(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                got = self._auth()
                proxy.record(kind="http", method=self.command, uri=self.path,
                             auth=got, body=body.decode("utf-8", "replace"))
                if got != EXPECT_AUTH:
                    with proxy.lock:
                        proxy.n_denied += 1
                    self.send_response(407)
                    self.send_header("Proxy-Authenticate", 'Basic realm="t"')
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                data = proxy.reply.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_POST = _handle
            do_GET = _handle

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self):
        try:
            self.httpd.shutdown()
            self.httpd.server_close()
        except Exception:
            pass


class FakeSocksProxy(_Base):
    """只做 CONNECT 的 SOCKS5 代理：**要求**用户名/密码（RFC 1929）。

    记录的是 CONNECT 里那个目标 —— 记下 `atyp` 是为了分辨 socks5h 和 socks5：
    socks5h 交上来的是**域名**（ATYP=3），socks5 交上来的是**解析好的 IP**
    （ATYP=1）。境外场景要的正是前者。
    """

    def __init__(self):
        _Base.__init__(self)
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(16)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _accept_loop(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,),
                             daemon=True).start()

    @staticmethod
    def _recv_exact(conn, n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                raise IOError("对端关了")
            buf += chunk
        return buf

    def _serve(self, conn):
        try:
            conn.settimeout(20)
            ver, n = self._recv_exact(conn, 2)
            methods = self._recv_exact(conn, n)
            if ver != 5 or 0x02 not in methods:
                conn.sendall(b"\x05\xff")
                self.record(kind="socks", ok=False, why="没提供用户名/密码方法")
                with self.lock:
                    self.n_denied += 1
                return
            conn.sendall(b"\x05\x02")
            # RFC 1929：1 字节版本 + 长度前缀的用户名 + 长度前缀的密码
            av = self._recv_exact(conn, 2)
            ulen = av[1]
            uname = self._recv_exact(conn, ulen).decode("utf-8", "replace")
            plen = self._recv_exact(conn, 1)[0]
            passwd = self._recv_exact(conn, plen).decode("utf-8", "replace")
            if "%s:%s" % (uname, passwd) != EXPECT_AUTH:
                conn.sendall(b"\x01\x01")
                self.record(kind="socks", ok=False, uname=uname, passwd=passwd)
                with self.lock:
                    self.n_denied += 1
                return
            conn.sendall(b"\x01\x00")
            req = self._recv_exact(conn, 4)
            atyp = req[3]
            if atyp == 1:
                host = socket.inet_ntoa(self._recv_exact(conn, 4))
            elif atyp == 3:
                host = self._recv_exact(conn, self._recv_exact(conn, 1)[0])
                host = host.decode("utf-8", "replace")
            else:
                host = "<atyp=%d>" % atyp
            port = int.from_bytes(self._recv_exact(conn, 2), "big")
            self.record(kind="socks", ok=True, atyp=atyp, host=host, port=port,
                        uname=uname, passwd=passwd)
            conn.sendall(b"\x05\x00\x00\x01" + b"\x00\x00\x00\x00" +
                         (0).to_bytes(2, "big"))
            # 握手完了，后面就是普通 HTTP —— 读掉请求头（+body）再答。
            data = b""
            while b"\r\n\r\n" not in data:
                data += conn.recv(4096)
            head = data.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
            with self.lock:
                self.hits[-1]["http"] = head.splitlines()[0] if head else ""
            body = self.reply.encode("utf-8")
            conn.sendall(b"HTTP/1.1 200 OK\r\n"
                         b"Content-Type: text/event-stream\r\n"
                         b"Content-Length: " + str(len(body)).encode() +
                         b"\r\nConnection: close\r\n\r\n" + body)
        except Exception as e:
            self.record(kind="socks", ok=False, why="握手出错：%s" % e)
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def stop(self):
        try:
            self.srv.close()
        except Exception:
            pass


def set_val(pg, cid, val):
    el = pg.locator("#" + cid)
    el.fill("")
    if val is not None:
        el.fill(str(val))
    pg.wait_for_timeout(200)


def click(pg, sel, **kw):
    """点之前先确认页面上没有压着弹窗。

    ⚠️ 那个「AI 怎么干活？」首选项弹窗是在**第一次发消息那一刻**才弹出来的
       （`maybe_ask_agent_pref()` 挂在发送那条路上），所以"发之前调一次
       `ensure_no_modal()`"根本拦不住它 —— 它比弹窗早一拍。
       抢跑的后果不是"弹窗没关掉"这么温和：它盖在整页上，之后**每一次**
       click 都报「intercepts pointer events」超时，而报错指向被点的那颗
       按钮，和真正的原因隔着十万八千里（本仓老账，2026-10-04 刚又栽一次：
       报的是 `#model-proxy_on` 点不动，其实是弹窗）。
    """
    C.ensure_no_modal(pg)
    pg.click(sel, **kw)


def set_ui_prefs(dbp, uid, **kw):
    """直接往库里种账号的界面偏好（`users.ui_prefs` 那列 JSON）。

    探针拿它把 `agent_asked` 先置上 —— 置上之后那个首选项弹窗**从头到尾
    不会出现**，比"出现了再去关"稳得多（见上面 click() 那段）。
    ⚠️ 这是探针给自己省事，不是应用的行为：应用那边是"答过就不再问"。
    """
    import json as _json
    import sqlite3
    con = sqlite3.connect(dbp)
    try:
        row = con.execute("SELECT ui_prefs FROM users WHERE id = ?",
                          (uid,)).fetchone()
        cur = {}
        if row and row[0]:
            try:
                cur = _json.loads(row[0]) or {}
            except Exception:
                cur = {}
        cur.update(kw)
        con.execute("UPDATE users SET ui_prefs = ? WHERE id = ?",
                    (_json.dumps(cur, ensure_ascii=False), uid))
        con.commit()
    finally:
        con.close()


def proxy_row(dbp, uid):
    import sqlite3
    con = sqlite3.connect(dbp)
    try:
        return con.execute(
            "SELECT enabled, protocol, host, port, username, sub_key, key_mode "
            "FROM user_proxy WHERE user_id = ?", (uid,)).fetchone()
    finally:
        con.close()


def db_blob(dbp):
    """把库文件的字节原样读出来（含 -wal），用来搜"明文有没有落盘"。

    ⚠️ 不能只查 sub_key 那一列：明文可能被别处抄了一份。搜整个文件才说得满。
    ⚠️ 必须连 `-wal` 一起读。库跑在 WAL 模式下，刚写下去的行**还在 WAL
       文件里**，只读主库文件会看不到它（本仓栽过一次：cp 主库 = 旧快照）。
    """
    out = b""
    for suf in ("", "-wal"):
        p = dbp + suf
        if os.path.exists(p):
            with open(p, "rb") as fh:
                out += fh.read()
    return out


def fill_proxy(pg, port, proto):
    """在模型服务页上把代理那一组填成"指向 port 上的假代理"。"""
    C.ensure_no_modal(pg)
    pg.check("#model-proxy_on")
    set_val(pg, "model-proxy_host", "127.0.0.1")
    set_val(pg, "model-proxy_port", port)
    C.pick_select(pg, "model-proxy_proto", proto)
    set_val(pg, "model-proxy_user", PROXY_USER)
    set_val(pg, "model-proxy_key", PROXY_KEY)
    pg.wait_for_timeout(300)
    click(pg, "#model-commit")


def wait_row(dbp, uid, want_enabled, timeout=15):
    t0 = time.time()
    row = None
    # ⚠️ 「等一行出现」不能写成「查得到行」—— 提前返回会让后面每一步都跟
    #    服务端抢跑，而报出来的错指向完全无关的地方（本仓老账）。
    while time.time() - t0 < timeout:
        row = proxy_row(dbp, uid)
        if row and row[0] == want_enabled:
            return row
        time.sleep(0.3)
    return row


def send_msg(pg, text, wait=70):
    """在对话页发一条，等这一轮真的跑完。返回页面文本。

    ⚠️ 判「跑完了」要盯发送键上的 `dsapp-busy`（忙过又空下来），**不能**拿
       正文里有没有「失败/出错」当判据 —— 那些词在设置面板里本来就有
       （「自动修次数」「出错也由 AI 一直修下去」），一进页面就命中，于是
       循环立刻返回、消息还在飞。后果是下一段的第一次发送撞上 disabled 的
       发送键，报「element is not enabled」—— 指向的却是下一段要做的事。
       2026-10-04 就是这么栽的。而且这种假绿特别毒：它让"消息根本没发出去"
       和"发出去了但没走代理"看起来一模一样。
    """
    C.goto(pg, "言出法随")
    pg.wait_for_timeout(1500)
    C.ensure_no_modal(pg)          # 新账号第一次进对话页那个首选项弹窗
    pg.wait_for_timeout(800)
    C.ensure_no_modal(pg)          # 它有时晚一拍才画出来，再确认一次
    # 上一轮要是还在跑，发送键是 disabled —— 等它空下来再发。
    pg.wait_for_selector("#chat-send:not([disabled])", timeout=120000)
    pg.fill("#chat-input", text)
    pg.wait_for_timeout(300)
    click(pg, "#chat-send")
    # ★ 发出去之后**再**看一眼：那个首选项弹窗就是这一刻弹的（第一次发消息
    #   时问「AI 怎么干活？」）。不关掉的话它会一直盖着，下一段的第一次点击
    #   就超时，而报错指向被点的那颗按钮。
    pg.wait_for_timeout(800)
    C.ensure_no_modal(pg)
    saw_busy = False
    t0 = time.time()
    while time.time() - t0 < wait:
        pg.wait_for_timeout(600)
        busy = pg.locator("#chat-send.dsapp-busy").count() > 0
        body = pg.evaluate("() => document.body.innerText") or ""
        if "代理这一路通了" in body:
            break
        if busy:
            saw_busy = True
            continue
        if saw_busy:
            break                  # 忙过又空了 = 这一轮结束（成功或失败）
    C.ensure_no_modal(pg)
    return pg.evaluate("() => document.body.innerText") or ""


def arm(pg, uid):
    """把"这一轮要用的模型设置"重新钉一遍再整页重载。

    ⚠️ 两件事都必须做：
       ① 模型服务页上那颗「更新」会把**界面上**那一套写回库（`input$model`
          在清单没拉回来时是空串）—— 于是刚种进去的模型名被写成空，发消息
          时被「还没选模型」那道闸拦下，看起来像"代理没生效"；
       ② `state$base_url` 是**会话开始那一刻**读一次的，种完库不重载的话
          这一轮用的还是厂商默认地址 —— 那会把请求真的发到公网上去。
    """
    C.seed_llm(uid, GHOST_URL, vendor="deepseek", model="deepseek-flash")
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=60000)
    pg.wait_for_timeout(1500)


def main():
    hp = FakeHttpProxy()
    sp = FakeSocksProxy()
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()
        try:
            C.enter_app(pg)
            uid, dbp = C.seed_or_die(C.LAST_EMAIL)
            # 首选项弹窗的闸门：种上 agent_asked 之后它就不会弹了（见 click()）。
            set_ui_prefs(dbp, uid, agent_asked=True)

            # ★ base_url 指向一个解析不了的域名：能不能出字 = 有没有走代理。
            # ⚠️ vendor/model 必须挑**目录里有**的那一对。用一个编出来的
            #    模型名会栽在下面这条链上：模型下拉里没有它 → input$model 是空
            #    → 「更新」那颗按钮按 `model = input$model %||% ""` 把刚种进去
            #    的模型名**写成空** → 发消息时被"还没选模型"那道闸拦下 ——
            #    假代理收 0 条，报出来像"代理没生效"。2026-10-04 第一次跑就是这么栽的。
            C.seed_llm(uid, GHOST_URL, vendor="deepseek", model="deepseek-flash")
            # ⚠️ state$base_url 是**会话开始那一刻**读一次的（本仓老账）——
            #    种完库必须 reload，否则这一轮对话用的还是厂商默认地址，
            #    而那会把请求真的发到公网上去。
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=60000)
            pg.wait_for_timeout(2000)

            # ---- ① 界面：代理那一块在「模型服务」页 ------------------------
            C.goto(pg, "模型服务")
            pg.wait_for_timeout(1500)
            need = ("model-proxy_on", "model-proxy_proto", "model-proxy_host",
                    "model-proxy_port", "model-proxy_user", "model-proxy_key",
                    "model-proxy_keymode", "model-proxy_test",
                    "model-proxy_forget")
            miss = [c for c in need if pg.locator("#" + c).count() == 0]
            check("① 代理那一组控件都在模型服务页上", not miss, str(miss))
            # 控件必须**看得见**：bslib 把所有页都留在 DOM 里、只藏不激活，
            # 只数 count() 的话"藏在别的页上"也会通过（本仓老账）。
            check("① 而且是真的显示出来了（不是藏在别的页的 DOM 里）",
                  pg.locator("#model-proxy_host").is_visible())

            # ---- ② HTTP 代理：真绕一次 ------------------------------------
            fill_proxy(pg, hp.port, "http")
            row = wait_row(dbp, uid, 1)
            check("② 点「更新」之后库里真的有了这一行（enabled=1）",
                  bool(row) and row[0] == 1, str(row))
            check("② 协议/地址/端口按填的落库（协议选的是 http，不是默认那档）",
                  bool(row) and row[2] == "127.0.0.1" and int(row[3]) == hp.port
                  and row[1] == "http", str(row))

            # ---- ③ 密匙在库里是密文 ---------------------------------------
            check("③ 库里 sub_key 不是明文，而是 v1: 开头的密文",
                  bool(row) and isinstance(row[5], str) and
                  row[5].startswith("v1:") and PROXY_KEY not in row[5],
                  (row[5][:14] + "...") if row and row[5] else str(row))
            blob = db_blob(dbp)
            check("③ 整个库文件（含 -wal）里搜不到明文密匙",
                  PROXY_KEY.encode("utf-8") not in blob,
                  "搜 %d 字节" % len(blob))
            dec = C.r_decrypt([row[5]])[0] if row and row[5] else None
            check("③ 而且是本实例那把钥匙串加的（解得回原文）",
                  dec == PROXY_KEY, "解出来 %r" % (dec,))
            pg.screenshot(path="%s/item2_填好代理.png" % OUT)

            # ---- ④ HTTP 代理那一条路 ---------------------------------------
            # ② 里点过「更新」，而那一页上的厂商/模型/地址是照**界面**存的 ——
            # 为了让 ④ 只测"代理这一件事"，把这一轮要用的设置重新钉一遍
            # （seed_llm 只写设置和钥匙串，**不碰** user_proxy 那张表，
            # 所以刚配好的代理原样留着）。
            arm(pg, uid)
            n0 = hp.n()
            body = send_msg(pg, "走代理这一路，回一句。")
            check("④ HTTP 代理：请求真的从假代理身上过去了（目标解析不了）",
                  hp.n() > n0, "假代理收到 %d 条" % hp.n())
            h = hp.last()
            if h:
                check("④ 而且是以**绝对 URI** 进来的（HTTP 代理的形态）",
                      (h["uri"] or "").startswith(GHOST_URL), str(h["uri"])[:120])
                check("④ 密匙真的送到了代理那头（凭据对得上，没吃到 407）",
                      h["auth"] == EXPECT_AUTH and hp.n_denied == 0,
                      "代理收到 %r，期望 %r，407 x%d"
                      % (h["auth"], EXPECT_AUTH, hp.n_denied))
            check("④ 代理的应答一路回到了对话框里", "代理这一路通了" in body,
                  body[-300:].replace("\n", " "))
            pg.screenshot(path="%s/item2_HTTP代理这一轮.png" % OUT)

            # ---- ⑤ SOCKS5h 那一条路（默认档，境外最常用）------------------
            C.goto(pg, "模型服务")
            pg.wait_for_timeout(1200)
            fill_proxy(pg, sp.port, "socks5h")
            row = wait_row(dbp, uid, 1)
            check("⑤ 切到 socks5h 并落库（端口换成了假 SOCKS5 那个）",
                  bool(row) and row[1] == "socks5h" and int(row[3]) == sp.port,
                  str(row))
            arm(pg, uid)               # 同上：这一轮只测代理这一件事
            n1 = sp.n()
            body = send_msg(pg, "走 SOCKS5 这一路，回一句。")
            check("⑤ SOCKS5：请求真的从假 SOCKS5 代理身上过去了",
                  sp.n() > n1, "收到 %d 条" % sp.n())
            s = sp.last()
            if s:
                check("⑤ 用户名/密码子协商过了（RFC 1929，密匙也对）",
                      s.get("ok") and s.get("uname") == PROXY_KEY and
                      s.get("passwd") == PROXY_KEY and sp.n_denied == 0,
                      str({k: s.get(k) for k in ("ok", "uname", "passwd")}) +
                      " 拒绝 x%d" % sp.n_denied)
                # ★★ 这一条是 socks5h 与 socks5 的分界：CONNECT 里交上来的
                #    必须是**域名**。交上来一个 IP 的话，说明 curl 在本地解析
                #    了它 —— 那正是"DNS 被污染时连不上"的那种配法。
                check("⑤ ★ 而且目标是**域名**形式（ATYP=3，这就是 socks5h）",
                      s.get("atyp") == 3 and s.get("host") == GHOST_HOST,
                      "atyp=%s host=%s port=%s"
                      % (s.get("atyp"), s.get("host"), s.get("port")))
            check("⑤ 代理的应答一路回到了对话框里", "代理这一路通了" in body,
                  body[-300:].replace("\n", " "))
            pg.screenshot(path="%s/item2_SOCKS5代理这一轮.png" % OUT)

            # ---- ⑥ 关掉开关就走直连（代理必须关得掉）---------------------
            C.goto(pg, "模型服务")
            pg.wait_for_timeout(1200)
            C.ensure_no_modal(pg)
            pg.uncheck("#model-proxy_on")
            pg.wait_for_timeout(300)
            click(pg, "#model-commit")
            row2 = wait_row(dbp, uid, 0)
            check("⑥ 关掉开关之后库里 enabled=0（不是只改了界面）",
                  bool(row2) and row2[0] == 0, str(row2))
            # ★★ 这一条**必须先 arm()**。少了它，上面的「更新」会照界面上的
            #    模型名把库里的模型写成空，于是这一条消息被「还没选模型」那道
            #    闸拦在本地 —— **一个字节都没出网**。那时候下面"两个假代理
            #    一条都没收到"当然成立，而它证明的是"消息根本没发"，不是
            #    "代理关掉了"。2026-10-04 第一次跑就是这样白捡了一个绿：
            #    日志里那句「这一次请求没有发出去」就是它留下的脚印。
            arm(pg, uid)
            n2, n3 = hp.n(), sp.n()
            body = send_msg(pg, "这一条应该直连。", wait=40)
            # 前置闸门：先证明这一条**真的出网了**。没有这一条，下面那句
            # 「一条新请求都没有」在"根本没发出去"的世界里同样成立 ——
            # 本仓老账：「等一行出现」写成「查得到行」= 没等。
            #
            # ⚠️ 判据是对话里那张**失败卡**（「厂商那边的原话是…」）：它只有
            #    真的发出去、真的被网络打回来才会写；被本地闸门（「还没选
            #    模型」那种）拦下的一次**连卡片都不写**。
            # ⚠️ 千万别拿通知里那句「这一次请求没有发出去」当判据 —— 那句
            #    对**每一次**失败的请求都会弹（包括真的出网之后失败的这种），
            #    2026-10-04 拿它当闸门，把一个本来有效的绿判成了红。
            tried = ("厂商那边的原话" in body or "没能发出去" in body)
            check("⑥ （前置）这一条真的出网了（有失败卡，不是被本地闸门拦下的）",
                  tried and "还没选模型" not in body,
                  body[-300:].replace("\n", " "))
            check("⑥ 关掉之后两个假代理**一条新请求都没有**（开关是有效的）",
                  hp.n() == n2 and sp.n() == n3,
                  "http %d→%d, socks %d→%d" % (n2, hp.n(), n3, sp.n()))
            # 关掉开关是"暂时不用它"，不是"把配置删了" —— 地址/端口/密匙
            # 必须还在，不然用户下次打开还得重填一遍（密匙还看不见，等于丢了）。
            # 这正是上面「清除」那颗按钮存在的理由：两件事要分开。
            check("⑥ 关掉开关没有把配置抹掉（地址/端口/密匙都还在，下次能直接开）",
                  bool(row2) and row2[2] == "127.0.0.1" and
                  int(row2[3]) == sp.port and str(row2[5]).startswith("v1:"),
                  str(row2)[:120])
            pg.screenshot(path="%s/item2_关掉之后直连.png" % OUT)

            # ---- ⑦ 密匙不许回到页面上 -------------------------------------
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=60000)
            pg.wait_for_timeout(1500)
            C.goto(pg, "模型服务")
            pg.wait_for_timeout(1500)
            kv = pg.input_value("#model-proxy_key")
            check("⑦ 刷新之后密匙框是空的（已存的密文不回填）", kv == "",
                  "框里是 %r" % kv)
            ph = pg.get_attribute("#model-proxy_key", "placeholder") or ""
            # ⚠️ 这一格问的是"还留着没有"，和上一格是两件事：只清控件不删库
            #    的话，用户会以为清掉了，而请求照样绕代理。
            check("⑦ 但 placeholder 告诉用户「已保存」", "已保存" in ph, ph)
            html = pg.evaluate("() => document.documentElement.outerHTML") or ""
            check("⑦ 整页 HTML 里搜不到明文密匙（截图/远程协助都带不出去）",
                  PROXY_KEY not in html, "%d 字符" % len(html))
            pg.screenshot(path="%s/item2_刷新后不回填.png" % OUT)

            # ---- ⑧ 「测试代理」那颗按钮 -----------------------------------
            # 拿一个**没在监听**的端口测：要看到"测试失败"而不是"正在测试…"
            # 卡住（那颗按钮走后台任务，卡住的话说明它跑到 Shiny 进程里去了）。
            set_val(pg, "model-proxy_host", "127.0.0.1")
            set_val(pg, "model-proxy_port", 1)      # 1 号端口上不会有人
            pg.wait_for_timeout(400)
            C.ensure_no_modal(pg)
            pg.check("#model-proxy_on")
            pg.wait_for_timeout(500)
            click(pg, "#model-proxy_test")
            t0 = time.time()
            res = ""
            while time.time() - t0 < 40:
                res = pg.evaluate(
                    "() => (document.getElementById('model-proxy_result')||{})"
                    ".innerText || ''") or ""
                if res and "正在测试" not in res:
                    break
                time.sleep(0.5)
            check("⑧ 测试代理会给出结论（失败也要说出来，不许一直转圈）",
                  bool(res) and "正在测试" not in res, repr(res[:120]))
            check("⑧ 连不上的时候那句话是人话（指出该改哪里）",
                  ("端口" in res or "代理" in res or "连不上" in res),
                  repr(res[:160]))
            pg.screenshot(path="%s/item2_测试代理失败.png" % OUT)

        finally:
            hp.stop()
            sp.stop()
            br.close()

    print("\n=== %d 条断言，%d 条没过 ===" % (NCHECK[0], len(FAIL))
          + ("" if not FAIL else "：%s" % " / ".join(FAIL)), flush=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
