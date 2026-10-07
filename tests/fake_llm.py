# 脚本化的假 LLM 服务端：收 POST，按顺序把 <queue>/NNN.txt 的内容当成 SSE 流回出去。
#
# 为什么需要"按顺序"：agent 循环是一轮接一轮请求的。如果每轮都回同一段带
# 代码的回复，循环就永远不会结束，测出来的东西和真实情况毫无关系。用一个
# 队列就能脚本化"第一轮给代码、第二轮给结论"。
#
# 为什么不用 python 自带的 SimpleHTTP：它只认 GET/HEAD，而 llm.R 发的是
# POST —— 会拿到 501，测出来的"失败"跟被测代码毫无关系（这个坑踩过一次）。
#
# 用法（一般由 tests/agent_loop.R 拉起，不用手工跑）：
#     python3 fake_llm.py <queue_dir> <served_counter_file> <port_file> [req_dir]
#
# 端口写 0 = 让内核随便挑一个空闲端口，再把实际端口写进 port_file。
# 固定端口在别人的机器上会撞车，撞了之后报出来的错（连接被拒）和被测代码
# 毫无关系，能把人带到沟里去。
#
# ── V15.3 加的两件事（都是**向后兼容**的，前三个参数的行为一个字节没改）──
#
# 1. **400 模式**：队列目录里放一个 `400.json`，前 `times` 次请求就回真的
#    HTTP 400（而不是 200 + SSE）。
#
#    为什么非要走真 HTTP：V15.3 那个「直接帮我设置」按钮的判据是
#    `dsapp_maxtok_advice(rv$error)`，而 `rv$error` 是 llm.R 从**真实响应体**
#    里抠出来的（`e$error$message`）。自检里拿一个手写的字符串去喂解析器，
#    证明的只是"解析器能解析我自己写的那句话"，不是"厂商那条 400 会变成
#    这句话"（selftest-green-is-not-coverage 的教训）。这里让 httr2 真的收到
#    一个 400、真的读到 body、真的走到 mod_chat 的错误气泡上。
#
#    ⚠️ 回的是 **JSON 错误体**，不是一句纯文本：llm.R:264 会先试
#       `jsonlite::fromJSON(body)$error$message`，解析不出来才退回整段 body。
#       用纯文本的话，被断言的字符串会带上整个 `{"error":{...}}` 外壳，和厂商
#       真实的样子不一样。
#
#    ⚠️ `times` 默认 1 = **只拒第一次**。第二次请求就落回 .txt 队列了 ——
#       这正是要的："学到的上限有没有真的应用到下一次请求上"必须能测。
#       计数写在 `<served_counter_file>.n400` 里，和 served 分开，
#       这样 served_n() 的语义（收到了几次**正常**请求）不受影响。
#
# 2. **记账**：给第 4 个参数就把它当目录，把每次请求的**请求体**存成
#    `req-0001.json`（按到达顺序编号）。测"下一次请求里 max_tokens 是不是
#    真的变了"只能靠它 —— 否则就只能去 grep 被测代码，那又变成自检了。
#    没给这个参数时一个文件都不写，老调用方照旧。
#
# 3. **慢放**（V15.3 浏览器探针要的）：队列目录里放一个 `slow.json`
#    `{"delay": 0.25}`，200 那条路就把 SSE 响应体**按事件块**一块一块写出去，
#    每块之间 sleep 这么久。
#
#    为什么非要有它：思考过程"不闪"的判据是**节点身份指纹** —— 生成期间
#    每 200ms 取一次 `<pre class="dsapp-think-pre">` 的 uuid，断言全程不变、
#    而字数单调增长。要是整个回复在一个 200ms 轮询周期内就吐完了，
#    一次采样都取不到，"指纹不变"会**因为压根没采样而通过** —— 那是假绿
#    （selftest-green-is-not-coverage）。慢放保证流真的横跨好几个 tick。
#
#    ⚠️ 按 `\n\n`（SSE 事件块）切，不是按字节切：HTTP 响应体是流式的，
#       客户端按块解析，切在哪里其实都行；但按事件块切读起来对得上，
#       而且不会把一个事件劈成两半之后自己看不懂。
#    ⚠️ Content-Length 照旧先发。分块写 + 显式 Content-Length 是合法的，
#       客户端会一直读到这个长度为止。
import http.server, socketserver, os, glob, sys, json, time, threading

QUEUE = sys.argv[1]
STATE = sys.argv[2]
PORTFILE = sys.argv[3]
REQDIR = sys.argv[4] if len(sys.argv) > 4 else None

REJ_FILE = os.path.join(QUEUE, "400.json")
REJ_STATE = STATE + ".n400"
REQ_N = 0

# ── V15.7 item 2 加的：**并发**请求 ─────────────────────────────────────────
#
# 原来用的是单线程的 `socketserver.TCPServer`：一次只服务一个连接，第二个
# 请求要等第一个**整条流写完**才被 accept。测「多个会话同时跑」的时候这是
# 致命的 —— B 那一轮会一直等到 A 流完才开始，探针量到的"并行"其实是串行，
# 而且**不报错**：两边都正常出字，只是永远不同时。
# 改成 ThreadingTCPServer（见文件末尾），下面这把锁保证"队列按顺序消费"
# 这条语义**一个字节都没变**：取文件 + 推进服务计数是原子的。
#
# ⚠️ 顺序语义是 agent 循环的前提（第一轮回代码、第二轮回结论）。锁只在
#    "选哪一条 + 计数加一"这一小段里持有，慢放的 sleep **不在**锁里 ——
#    否则两条流又变回串行了。
_LOCK = threading.Lock()


def read_int(path, default=0):
    if os.path.exists(path):
        try:
            return int(open(path).read().strip() or default)
        except ValueError:
            return default
    return default


def slow_delay():
    """`<queue>/slow.json` 里写了 delay 就慢放，没写就是 0（原样一次写完）。"""
    p = os.path.join(QUEUE, "slow.json")
    if not os.path.exists(p):
        return 0.0
    try:
        return float(json.load(open(p)).get("delay", 0))
    except Exception:
        return 0.0


def rejection():
    """该不该回 400？回的话回哪一条？返回 None 表示不拦，走正常队列。"""
    if not os.path.exists(REJ_FILE):
        return None
    try:
        cfg = json.load(open(REJ_FILE))
    except Exception:
        return None
    times = int(cfg.get("times", 1))
    # ⚠️⚠️ 下面这两行有一个**已知的**老 bug，2026-10-04 查 item 7 时发现：
    #    末行 `open(REJ_STATE, "w")` 在实参求值之前就把计数文件清空了，于是
    #    `read_int(...)` 永远读到 0、永远只写 1 —— 结果 `times >= 2` 时第一次
    #    判断就再也涨不上去，**拒信会一直拒下去**，而不是拒 times 次。
    #    （`times = 1`（默认）不受影响：第二次请求 1>=1 成立，照常放行。)
    #
    #    这里**故意没顺手改**：现有几处 `arm_400(..., times=10)`
    #    （tests/ui_v155、tests/ui_v157）的注释写的就是"要每一次请求都回"，
    #    改对之后它们会变成"拒 10 次就放行"，那是**改这些老探针的语义**，
    #    得连它们一起重跑重判，不是这一版该顺手做的事。
    #    要用 times >= 2 的新探针，先照上面 /models 那个计数器的写法修掉它。
    with _LOCK:                       # 读-改-写要原子（并发时不加会把
        if read_int(REJ_STATE) >= times:   # times=1 变成"拒两次"）
            return None
        open(REJ_STATE, "w").write(str(read_int(REJ_STATE) + 1))
    status = int(cfg.get("status", 400))
    # body 可以写成字符串（原样发）或者写成对象（当 JSON 错误体发）
    body = cfg.get("body", "")
    if not isinstance(body, str):
        body = json.dumps(body)
    return status, body.encode()


# ── V16.3 item 7 加的：**GET /models** ─────────────────────────────────────
#
# 背景：item 7 让「换个厂商就自动刷一次可用模型清单」成了常规路径，于是
# `/models` 这条**从来没被假服务端实现过**的接口第一次需要被测。以前没有
# 它也没人发现 —— 那时拉清单只有一个入口（手点「获取模型」），而没有任何
# 探针点过那个按钮。
#
# ⚠️ 默认行为**一个字节都不改**：没有 `<queue>/models.json` 时回 501（就是
#    BaseHTTPRequestHandler 原来的样子）。老调用方谁也不受影响。
#
# 写法两种都收：
#     ["a", "b"]                         —— 就这几个模型
#     {"delay": 3, "data": ["a", "b"]}   —— 顺便慢放（测竞态用）
#
# ⚠️ delay 是为了造出**后发先至**：两个厂商的应答延迟不一样时，先发的那个
#    可能后到。item 7 要修的正是"后到的那份把先到的那份顶掉"，只在两边
#    都在飞的时候才测得到。
MODELS_FILE = os.path.join(QUEUE, "models.json")
MODELS_STATE = STATE + ".models"


def models_cfg():
    """没配就返回 None（= 501）；配了就返回 (ids, delay)。"""
    if not os.path.exists(MODELS_FILE):
        return None
    try:
        cfg = json.load(open(MODELS_FILE))
    except Exception:
        return None
    if isinstance(cfg, dict):
        ids = cfg.get("data", [])
        try:
            delay = float(cfg.get("delay", 0) or 0)
        except (TypeError, ValueError):
            delay = 0.0
    else:
        ids, delay = cfg, 0.0
    return [str(x) for x in ids], delay


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        mc = models_cfg()
        if mc is None:
            # 没配：照旧 501（老行为）
            self.send_response(501)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        ids, delay = mc
        # 计数**在 sleep 之前**加：语义是"服务端收到了几次 /models 请求"，
        # 而不是"答完了几次"。探针用它判"自动拉这一下到底发出去没有"。
        #
        # ⚠️⚠️ 必须先读进变量，**不能**写成
        #       open(P, "w").write(str(read_int(P) + 1))
        #    —— `open(P, "w")` 在**实参求值之前**就把文件清空了，那个写法
        #    每一次都会算出 0+1、永远只写 1。2026-10-04 实测：连打三次，
        #    文件里从头到尾是 "1"，而**三条请求全都答了 200** —— 探针那边
        #    看起来是"服务端只收到一次"，和"请求根本没发出去"长得一模一样，
        #    差点把 item 7 那三条失败判成自动拉没生效。
        with _LOCK:
            n_models = read_int(MODELS_STATE) + 1
            open(MODELS_STATE, "w").write(str(n_models))
        body = json.dumps({"object": "list",
                           "data": [{"id": m, "object": "model"} for m in ids]
                           }).encode()
        if delay > 0:
            time.sleep(delay)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global REQ_N
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n)

        if REQDIR:
            os.makedirs(REQDIR, exist_ok=True)
            with _LOCK:               # 并发时 REQ_N += 1 不是原子的：两条请求
                REQ_N += 1            # 会拿到同一个号，**后写的把先写的覆盖掉**
                nreq = REQ_N          # （req_n() 于是少数一次，而它正是"没打到
            with open(os.path.join(REQDIR,         # 真厂商"的判据）
                      "req-%04d.json" % nreq), "wb") as fh:
                fh.write(raw)

        rej = rejection()
        if rej is not None:
            status, body = rej
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        with _LOCK:      # 「取第几条 + 计数加一」必须原子：并发时两条请求会
            served = read_int(STATE)          # 同时读到同一个 served，**把同
            files = sorted(glob.glob(os.path.join(QUEUE, "*.txt")))
            if served < len(files):           # 一条队列项回两遍**，而
                body = open(files[served], 'rb').read()   # served_n() 会少数
            else:
                # 队列用完了，回一个"没有代码块的最终答复"，让循环自然地停下来，
                # 而不是卡在那里等一个永远不来的响应。
                body = ('data: {"choices":[{"delta":{"content":"（队列已空）"},'
                        '"finish_reason":null}]}\n\n'
                        'data: {"choices":[{"delta":null,"finish_reason":"stop"}]}\n\n'
                        'data: [DONE]\n\n').encode()
            open(STATE, "w").write(str(served + 1))
        # ⚠️ 慢放那段**在锁外面**。包进来的话第二条流要等第一条 sleep 完，
        #    并发又变成串行 —— 而且症状正是这个文件要解决的那个（不报错）。

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        delay = slow_delay()
        if delay <= 0:
            self.wfile.write(body)
        else:
            for chunk in body.split(b"\n\n"):
                self.wfile.write(chunk + b"\n\n")
                self.wfile.flush()
                time.sleep(delay)

    def log_message(self, *a):
        pass


class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True        # 进程退出时别被服务线程吊住


with Srv(("127.0.0.1", 0), H) as httpd:
    open(PORTFILE, "w").write(str(httpd.server_address[1]))
    httpd.serve_forever()
