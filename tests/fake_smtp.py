#!/usr/bin/env python3
"""假 SMTP 服务器 —— 零依赖，只为证明「`curl::send_mail` 真的把字节送到了收件端」。

    python3 tests/fake_smtp.py <port> <outdir> [--count N] [--timeout SEC]

收到几封就写几个文件到 <outdir>：
    msg_1.eml      DATA 段原文（含 MIME 全部内容）
    msg_1.env      信封：MAIL FROM / RCPT TO
每收一封往 stdout 打一行 `SAVED ...`，起来时打一行 `READY <port>`。

⚠️ 为什么必须有一个假服务器（而不是只看 `ok: TRUE`）：
   Test_V15.2 开发期真的踩过 —— `dsapp_mail_deliver()` 返回 `ok: TRUE`、
   SMTP 应答全绿，而正文里**一张图都没内联上**，收件人看到的是裂图。
   发信返回值只说明"服务器收下了"，不说明"内容是对的"。
   这一步才是 `selftest-green-is-not-coverage` 的正解。

⚠️ 故意**不播 AUTH、不播 STARTTLS**：curl 见到服务器宣告 AUTH 会去认证、
   宣告 STARTTLS 会去升级，两条都要求凭据和证书。这里要的是最笨的通道。
   配套：`DSAPP_SMTP_SSL=no`、`DSAPP_SMTP_USER`/`PASS` 留空
   （`dsapp_mail_send_raw()` 只在非空时才 setopt username/password）。

⚠️ 端口**不能是 465** —— `dsapp_mail_endpoint()` 见 465 会自动补 `smtps://`。

照 `tests/fake_llm.py` 的样子写。Python 3.12 已经删掉 `smtpd`，`aiosmtpd` 也没装，
所以直接用 socket 手写。
"""

import os
import socket
import sys
import threading
import time

CRLF = b"\r\n"
MAX_LINE = 8192          # 单行上限，防一个畸形请求把内存吃光


def handle(conn, outdir, idx, state):
    """服务一条连接。返回 True 表示收到了一封完整的信。

    `state` 是 {"got": int, "want": int} —— 收满 want 就**立刻收工**，
    不等 QUIT。curl 发完 DATA 之后不一定发 QUIT 也不一定马上关连接，
    干等的话 readline() 会一直阻塞到 socket 超时，调用方白等十几秒。
    """
    conn.settimeout(30)
    f = conn.makefile("rb")
    got = False

    def send(s):
        conn.sendall(s.encode("utf-8") + CRLF)

    def save_envelope(mail_from, rcpts):
        with open(os.path.join(outdir, "msg_%d.env" % idx), "w",
                  encoding="utf-8") as fh:
            fh.write("MAIL FROM=%s\n" % mail_from)
            for r in rcpts:
                fh.write("RCPT TO=%s\n" % r)

    send("220 fake ESMTP ready")
    mail_from = ""
    rcpts = []
    in_data = False
    buf = bytearray()

    while True:
        line = f.readline(MAX_LINE)
        if not line:
            break

        if in_data:
            # ★ 透明性（RFC 5321 4.5.2）：正文里以 `.` 开头的行发出来时多一个点，
            #   收的时候要去掉。少了这一步，正文里凡是 "^.." 的行都会多一个点。
            if line in (b".\r\n", b".\n"):
                path = os.path.join(outdir, "msg_%d.eml" % idx)
                with open(path, "wb") as fh:
                    fh.write(bytes(buf))
                save_envelope(mail_from, rcpts)
                send("250 OK queued as fake-%d" % idx)
                print("SAVED %s (%d bytes)" % (path, len(buf)), flush=True)
                got = True
                in_data = False
                buf = bytearray()
                state["got"] += 1
                if state["got"] >= state["want"]:
                    break          # 收满了，不等 QUIT
                continue
            if line.startswith(b".."):
                line = line[1:]
            # 统一成 CRLF：curl 发的是 CRLF，但万一不是，断言不该因此失败
            buf += line.replace(b"\r\n", b"\n").replace(b"\n", CRLF)
            continue

        cmd = line.decode("utf-8", "replace").rstrip("\r\n")
        up = cmd.upper()

        if up.startswith("EHLO"):
            # ⚠️ 只播 SIZE。多播一行 AUTH 或 STARTTLS，curl 就会去做那件事。
            send("250-fake greets you")
            send("250 SIZE 104857600")
        elif up.startswith("HELO"):
            send("250 fake greets you")
        elif up.startswith("MAIL FROM"):
            mail_from = cmd.split(":", 1)[1].strip() if ":" in cmd else ""
            send("250 OK")
        elif up.startswith("RCPT TO"):
            rcpts.append(cmd.split(":", 1)[1].strip() if ":" in cmd else "")
            send("250 OK")
        elif up.startswith("DATA"):
            if not rcpts:
                send("503 need RCPT first")
                continue
            send("354 End data with <CR><LF>.<CR><LF>")
            in_data = True
        elif up.startswith(("RSET", "NOOP")):
            send("250 OK")
        elif up.startswith("QUIT"):
            send("221 Bye")
            break
        else:
            # 认不出来的命令一律 250 —— 假服务器不把关，只要能收完整封信
            send("250 OK")

    try:
        f.close()
    except Exception:
        pass
    try:
        conn.close()
    except Exception:
        pass
    return got


def main():
    args = [a for a in sys.argv[1:]]
    if len(args) < 2:
        print(__doc__)
        return 2
    port = int(args[0])
    outdir = args[1]
    want = 1
    timeout = 60.0
    i = 2
    while i < len(args):
        if args[i] == "--count":
            want = int(args[i + 1]); i += 2
        elif args[i] == "--timeout":
            timeout = float(args[i + 1]); i += 2
        else:
            i += 1

    os.makedirs(outdir, exist_ok=True)
    for name in os.listdir(outdir):
        if name.startswith("msg_"):
            os.remove(os.path.join(outdir, name))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(5)
    srv.settimeout(1.0)
    print("READY %d" % port, flush=True)

    deadline = time.time() + timeout
    state = {"got": 0, "want": want}
    idx = 0
    while state["got"] < want and time.time() < deadline:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        idx += 1
        try:
            handle(conn, outdir, idx, state)
        except Exception as exc:            # 单条连接出错不该拖垮服务器
            print("ERR %s" % exc, file=sys.stderr, flush=True)
    srv.close()
    print("DONE got=%d" % state["got"], flush=True)
    return 0 if state["got"] >= want else 1


if __name__ == "__main__":
    sys.exit(main())
