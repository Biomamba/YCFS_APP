# -*- coding: utf-8 -*-
"""Test_V16.2 浏览器验收：言出法随下面那组「不设上限」勾选框。

用户原话（2026-10-04）：

    出错自动修也要默认没上限，言出法随下面的对话框需要有直接勾选这些选项
    不设上限的组件

拆成两句判据：

  item 1  「出错自动修」默认**不设上限**（哨兵 0），只有用户自己设了次数才拦。
  item 2  对话页上有四个勾（上下文 / 单次输出 / 运行时间 / 出错自动修），
          默认全勾 = 全都不设上限；取消勾选 → **就地**出现可填的滑块/数字。

── 为什么这些事非得在浏览器里看 ─────────────────────────────────────────
`selftest.R` 那一节能证明的是"函数算得对、源码接线对"，它证明不了：

  · 四个勾**真的画出来了**、真的默认是勾着的（源码里写了 value = TRUE
    不等于页面上那个框是亮的 —— 中间隔着 renderUI、updateCheckboxInput
    两条路）；
  · 取消勾选**真的**会就地出现控件（那是 renderUI 重建，只有 DOM 能作证）；
  · 对话页设的数**真的**走到了模型服务页那一格（跨模块的指令通道
    state$maxtok_cmd —— 这条链上任何一环断了，两边就各说各话，
    而 selftest 里 grep 到的那几行**照样全绿**）；
  · 只取消**一个**勾时，两个勾真的会一起灭（这一版修掉的那个回归：
    原来算的是"两个勾或起来"，于是只取消一个等于什么都没改）。

── 铁律（本仓踩过的，写在每一处需要它的地方）─────────────────────────────
  · 新账号第一次进对话页有个首选项弹窗会把所有 click 吃掉 → ensure_no_modal()。
  · 通知会盖在控件上 → 动手之前先 clear_notes()。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到**值**对了为止。
  · 「发消息之前要验地址」：state$base_url 是**会话开始那一刻**读一次的，
    种完 LLM 设置必须 reload，否则请求会打到厂商默认地址上去。
  · 隐藏元素的矩形是全 0 → 量几何之前先确认那个东西看得见。
  · 数字不写死：3 / 2 / 8.5 这些从 R 源码里现抠（见 rnum）。
  · 不滤掉 favicon = 资源检查永远染红，一条自己造出来的假问题盖住真问题。

用法（实例由 make_instance.sh 起，见 tests/ui_v162/README.md）：
    bash tests/ui_v7/make_instance.sh 8967 /tmp/dsapp_v162a
    python3 tests/ui_v162/probe_unlim.py          # 退出码 0 = 全绿

换端口/目录用 DSAPP_TEST_URL / DSAPP_TEST_APP / DSAPP_TEST_OUT。
"""
import io
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402
from _common import ensure_no_modal, goto               # noqa: E402

BAD = []


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def bad(msg):
    BAD.append(msg)
    say("  ✗ " + msg)


def ok(msg):
    say("  ✓ " + msg)


# ---------------------------------------------------------------- R 常量
# ⚠️ 不写死 3 / 2 / 8.5。这三个数这一版刚动过（自动修默认从"3 次"改成"不设
#    上限"，时长滑块加了"再高一格"那一档），写死的话探针会在下一个版本里拿
#    旧数去比新代码 —— 报出来的错会指向完全无关的地方（本仓旧账：
#    constant-change-leaves-stale-literals）。
_SRC = ["R/config.R", "R/models.R", "R/utils.R"]
# ⚠️ 只认**行首**的赋值（缩进里的 `x <- 1` 是函数体内部，不算常量）。
#    尾注释**必须单独切掉**：`DSAPP_AGENT_AUTOFIX_MAX    <- 3L     # 窗口内…`
#    这种写法把"值"和"注释"连在一起，正则里写 `[^\n#]+` 会让整行**匹配不上**
#    —— 而匹配不上的表现是"常量找不到"，看着像常量被改名了。
_TOPLVL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)[ \t]*<-[ \t]*(.*)$", re.M)


def _val(raw):
    """切掉 R 的尾注释。只切「空白 + #」——`#` 前面没空白时是值的一部分。"""
    m = re.search(r"[ \t]#", raw)
    return (raw[:m.start()] if m else raw).strip()


def _defs():
    out = {}
    for f in _SRC:
        p = os.path.join(C.REPO, f)
        if not os.path.exists(p):
            sys.exit("探针要读 %s 抠常量，它不在（应用的目录结构变了？）" % p)
        txt = io.open(p, encoding="utf-8").read()
        for m in _TOPLVL.finditer(txt):
            v = _val(m.group(2))
            if not v:
                continue
            out.setdefault(m.group(1), []).append(
                (f, txt[:m.start()].count("\n") + 1, v))
    return out


_DEFS = _defs()


def rnum(name, seen=()):
    """从 R 源码里抠一个常量并算成数（支持引用别的常量）。"""
    if name in seen:
        sys.exit("常量 %s 的定义是个圈：%s" % (name, " -> ".join(seen + (name,))))
    ds = _DEFS.get(name)
    if not ds:
        sys.exit("在 R/ 里找不到常量 %s —— 探针不改判据，先去看看它去哪了"
                 % name)
    # ⚠️ 同名两处、值还不一样：这时"读到哪个"取决于文件顺序，判据会跟着飘。
    #    别猜。（值一样的重复定义无所谓，本仓里 rv 之类的名字到处都是，
    #    所以这条只在**真的被问到**的常量上判，不搞全表检查。）
    if len({v for _, _, v in ds}) > 1:
        sys.exit("常量 %s 有多份**不一样**的定义，探针不猜哪个算数：\n  %s"
                 % (name, "\n  ".join("%s:%d  %s" % t for t in ds)))
    expr = ds[0][2].rstrip("L")
    expr = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\b",
                  lambda m: repr(rnum(m.group(1), seen + (name,))), expr)
    if not re.fullmatch(r"[0-9eE.+\-*/() ]+", expr):
        sys.exit("常量 %s 的值探针算不出来（%s:%d）：%r"
                 % (name, ds[0][0], ds[0][1], ds[0][2]))
    return eval(expr)


AUTOFIX_MAX = rnum("DSAPP_AGENT_AUTOFIX_MAX")
WALL_DEF_H = rnum("DSAPP_AGENT_WALL_DEF") / 3600.0
WALL_UNLIM_H = rnum("DSAPP_AGENT_WALL_SLIDER_UNLIM")
CTX_DEFAULT = rnum("DSAPP_CTX_DEFAULT")


# ---------------------------------------------------------------- JS 片段
# ⚠️ 一律先看**存不存在**，再看可不可见。"就地出现的那个控件"是 renderUI
#    画出来的：没勾的时候它连节点都没有，勾上之后节点才出现。用
#    is_visible() 判"没出现"是错的 —— 隐藏元素的矩形是全 0，而"不存在"和
#    "存在但 0×0"在 Playwright 里是两件事（hidden-element-has-zero-rect）。
JS_EXISTS = "(id) => !!document.getElementById(id)"

JS_RECT = """(id) => { var e = document.getElementById(id);
  if (!e) return null;
  var r = e.getBoundingClientRect();
  var st = getComputedStyle(e);
  return {w: Math.round(r.width), h: Math.round(r.height),
          x: Math.round(r.x), y: Math.round(r.y), disp: st.display}; }"""

JS_CHK = """(id) => { var e = document.getElementById(id);
  return e ? !!e.checked : null; }"""

# ionRangeSlider 把原来的 <input> 换掉了，读 el.value 有可能读到旧值 / 空值。
# 走它自己的实例拿 from，取不到再退回 el.value。
JS_SLIDER = """(id) => { var e = document.getElementById(id);
  if (!e) return null;
  try { var s = window.jQuery && window.jQuery(e).data('ionRangeSlider');
        if (s) return s.result.from; } catch (err) {}
  return parseFloat(e.value); }"""

JS_NUM = """(id) => { var e = document.getElementById(id);
  if (!e) return null;
  var v = (e.value == null ? '' : String(e.value));
  return {raw: v, num: (v === '' ? null : parseFloat(v))}; }"""

JS_TXT = """(sel) => { var e = document.querySelector(sel);
  return e ? (e.innerText || e.textContent || '').replace(/\\s+/g, ' ').trim()
           : null; }"""

# ⚠️ 通知会盖在控件上。默认那一组是"全都不设上限"，第一次进对话页就会弹
#    一条，它压在右下角 —— 不关掉的话点勾选框会一直报
#    「intercepts pointer events」，而报错指向的是那个勾本身，看不出是通知
#    （和那个首选项弹窗是同一类坑：first-run-onboarding-modal-blocks-clicks）。
JS_CLEAR_NOTES = """() => {
  var n = document.querySelectorAll('.shiny-notification');
  var k = 0;
  n.forEach(function (x) {
    var b = x.querySelector('.shiny-notification-close');
    if (b) { b.click(); } else { x.remove(); }
    k++;
  });
  return k; }"""

# ⚠️ 按**节点**记账，不是按文案去重。按文案去重的话，同一句话第二次出现时
#    它不记 —— 于是"这一次到底说没说"就量不出来了，而它报的是绿。
WATCH_NOTES = r"""
() => {
  window.__dsappNotes = [];
  window.__dsappNodes = [];
  var grab = function () {
    document.querySelectorAll('.shiny-notification').forEach(function (n) {
      var t = (n.innerText || '').replace(/\s+/g, ' ').trim();
      var i = window.__dsappNodes.indexOf(n);
      if (i < 0) {
        if (!t) return;
        window.__dsappNodes.push(n);
        window.__dsappNotes.push({t: t});
      } else if (t && window.__dsappNotes[i].t !== t) {
        window.__dsappNotes[i].t = t;
      }
    });
  };
  grab();
  if (window.__dsappNoteObs) window.__dsappNoteObs.disconnect();
  window.__dsappNoteObs = new MutationObserver(grab);
  window.__dsappNoteObs.observe(document.body, {childList: true, subtree: true,
                                                characterData: true});
}
"""


def clear_notes(pg):
    k = pg.evaluate(JS_CLEAR_NOTES)
    if k:
        pg.wait_for_timeout(400)
    return k


def wait_for(pg, fn, timeout=15, step=250):
    """轮询直到 fn() 为真。返回 True/False。

    ⚠️ 不用 wait_for_selector 那种"查得到节点"的等法：这一版关心的是**值**
       （框里那个数、勾的状态），而"查得到行"不等于"值已经到位"
       （fake-wait-is-not-a-wait）。这一轮里 Shiny 要跑两个来回，
       少等一拍就会和它抢跑，报出来的错指向完全无关的地方。
    """
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        pg.wait_for_timeout(step)
    return False


def ck(pg, key):
    return pg.evaluate(JS_CHK, "chat-unlim_" + key)


def exists(pg, cid):
    return pg.evaluate(JS_EXISTS, cid)


def seen(pg, cid):
    """在 DOM 里**而且看得见**。隐藏元素的矩形是全 0，光看节点在不在会把
    "被 display:none 掉"当成"出现了"。"""
    r = pg.evaluate(JS_RECT, cid)
    return bool(r and r["w"] > 2 and r["h"] > 2 and r["disp"] != "none")


def numof(pg, cid):
    v = pg.evaluate(JS_NUM, cid)
    return None if v is None else v["num"]


def set_num(pg, cid, val):
    """往一个 numericInput 里填数并让它**真的报上去**。

    ⚠️ fill() 只触发 input 事件，Shiny 的 numeric 绑定还要一个 change
       （失焦）才发消息。不按 Tab 的话服务端什么都没收到，而下游看起来就是
       "我填了但它没生效"。

    ⚠️ 这里的 id 是**裸 id**（`chat-fix_max_n`），不是 CSS 选择器 ——
       本文件里 exists()/rect 那几个都走 `getElementById(id)`。两边混着用
       的后果是 `pg.click("chat-fix_max_n")` 去找一个叫这个名字的**标签**，
       找不到，30 秒后报 "waiting for locator(chat-fix_max_n)" ——
       报错长得像"那个框没画出来"，其实是我们自己少写了一个 `#`。
       统一在这儿补，别指望每个调用点都记得。
    """
    sel = "#" + cid.lstrip("#")
    pg.click(sel)
    pg.fill(sel, str(val))
    pg.keyboard.press("Tab")
    pg.wait_for_timeout(700)


# Shiny 客户端手里那份"服务端已经收到什么"。和 DOM 是**两份**东西：
# DOM 是"浏览器现在显示什么"，这份是"服务端上一次收到的值"。两者不一致
# 时，红的那一条到底是"真相没改"还是"界面没跟上"，只有把它们并排看才分得开
# （hide-element / nonreactive 那几条记录都是栽在只看了一边）。
JS_INPUTS = """() => { try { return Shiny.shinyapp.$inputValues; }
                        catch (e) { return {}; } }"""


def inputs(pg):
    try:
        return pg.evaluate(JS_INPUTS) or {}
    except Exception:
        return {}


def dump_unlim(pg, tag):
    """把这一格的内外两份状态摊开（红的判据要能自己说清是哪儿不对）。"""
    iv = inputs(pg)
    say("  ── 现场：%s" % tag)
    for k in ("ctx", "maxtok", "wall", "fix"):
        say("     DOM #chat-unlim_%-6s = %-5s   input$chat-unlim_%-6s = %s"
            % (k, ck(pg, k), k, iv.get("chat-unlim_" + k)))
    say("     DOM #chat-maxtok_n    = %-6s   input$chat-maxtok_n    = %s"
        % (numof(pg, "chat-maxtok_n"), iv.get("chat-maxtok_n")))
    # ⚠️ 模型页那一格是**真相的镜子**：空 = state$ctx_limit 是不设上限，
    #    有数 = 还是那个数。它比勾选框可信（勾选框可能只是没跟上）。
    try:
        mt = pg.input_value("#model-max_tokens")
    except Exception as e:
        mt = "<读不到: %s>" % e
    say("     DOM #model-max_tokens = %-6r   input$model-max_tokens = %s"
        % (mt, iv.get("model-max_tokens")))


def click_trace(pg, cid, marks=(0, 150, 400, 1200, 3000)):
    """点一个勾，然后**逐拍**记下 DOM 和服务端各自的状态。

    ⚠️ 点完等 10 秒再看一眼是分不清原因的：那一击没落到 input 上（DOM 一直
       是原值）和落上了又被谁按回去（先变、后弹回），10 秒后看到的**同一个
       值**。中间这几拍就是判据本身 —— 它俩的形状完全不一样：
         · 0 拍就没变 → 这一击根本没生效（谁盖着 / 节点被换掉了 / 命中测试
           通过但事件没到）
         · 中途变过又被弹回 → 是**服务端**有人把它写回去了
    """
    t0 = time.time()
    pg.click("#" + cid.lstrip("#"))
    out = []
    for ms in marks:
        spent = (time.time() - t0) * 1000
        if ms > spent:
            pg.wait_for_timeout(int(ms - spent))
        out.append((ms, ck(pg, cid.replace("chat-unlim_", "")),
                    inputs(pg).get(cid)))
    say("    %s 点后逐拍（t / DOM / 服务端那份）：" % cid)
    for ms, dom, srv in out:
        say("      +%-5dms DOM=%-5s input$=%-5s" % (ms, dom, srv))
    return out


def wait_main(pg, timeout=180):
    """（重新）进页面之后等**主界面**回来。

    ⚠️ 这里**不能**用 C.wait_awake()：它等的是 `.dsapp-auth`（注册/登录那个
       壳），而**带着 cookie 再进页面是直进主界面的** —— 那个壳不会再来，
       于是它白转满 150 秒（中途还会 reload 一次，等于又开一个 Shiny
       session）。本仓有账：first-run-onboarding-modal-blocks-clicks。
       enter_app 结尾本来就要求 `.dsapp-shell`，所以它后面那句 wait_awake
       纯属多余 —— 2026-10-04 实测：一轮探针为此白等 150 秒 × 2。

    上限和 enter_app 里那个 _BOOT_SEC 取同一个数（180）：**慢**和**坏**要分得开。
    """
    end = time.time() + timeout
    while time.time() < end:
        try:
            if pg.locator(".dsapp-shell").count():
                return True
        except Exception:
            pass
        pg.wait_for_timeout(500)
    return False


def busy(pg):
    """这一轮生成还没结束吗？

    ⚠️ 用的是**和 tests/ui_v156 同一个判据**（发送键被禁用），不另起一套 ——
       两套判据不一致的话，"等它结束"和"判断它有没有开始"会打架。
    """
    try:
        return pg.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def wait_idle(pg, timeout=120):
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:
        if busy(pg):
            break
        pg.wait_for_timeout(150)
    while time.time() < end:
        if not busy(pg):
            pg.wait_for_timeout(700)
            if not busy(pg):
                return True
        pg.wait_for_timeout(250)
    return False


def send(pg, text, timeout=120):
    ensure_no_modal(pg, timeout=3)
    pg.fill("#chat-input", text)
    pg.click("#chat-send")
    return wait_idle(pg, timeout)


# ================================================================ ①
FOUR = [("ctx", "上下文"), ("maxtok", "单次输出"),
        ("wall", "运行时间"), ("fix", "出错自动修")]


def sec_a_defaults(pg):
    say("")
    say("=== ① 四个勾都在，而且默认全是勾着的 ===")
    goto(pg, "chat")
    ensure_no_modal(pg)
    clear_notes(pg)

    hit = 0
    for key, label in FOUR:
        v = ck(pg, key)
        if v is None:
            bad("页面上找不到「%s」那个勾（id=chat-unlim_%s）—— 这一组没画出来"
                % (label, key))
        elif not v:
            bad("「%s」默认**不是**勾着的。用户要的是「默认没上限、要用时再"
                "打开」，默认没勾 = 一进来就带着上限" % label)
        else:
            hit += 1
    if hit == 4:
        ok("四个勾都在、都默认勾着：%s" % " / ".join(l for _, l in FOUR))

    # 那一排的小字必须说清楚"上下文和单次输出是同一个值"。不写的话用户会
    # 以为能"上下文不限、输出限死"，而那个组合在这套代码里表达不出来
    # （两个勾指向 state$ctx_limit 一个数）。
    hint = pg.evaluate(JS_TXT, ".dsapp-ctrl-unlim")
    if not hint:
        bad("找不到 .dsapp-ctrl-unlim 那一格（勾选框不在它该在的地方？）")
    elif "上下文" not in hint or "单次输出" not in hint:
        bad("那一格里没写「上下文 / 单次输出」：%r" % hint[:120])
    else:
        ok("那一格的小字点到了上下文 / 单次输出（说明两者是一个值）")

    # ★ 四个都勾着的时候，三个"就地控件"一个都不该在页面上。
    for cid, what in (("chat-maxtok_n", "单次使用上限的数字框"),
                      ("chat-agent_wall", "运行时间的滑块"),
                      ("chat-fix_max_n", "出错自动修次数的数字框")):
        if exists(pg, cid):
            bad("四个勾都勾着，但「%s」还在页面上（%s）—— 它应当是取消勾选"
                "之后才出现的" % (what, cid))
        else:
            ok("勾着的时候没有「%s」" % what)


# ================================================================ ②
def sec_b_untick(pg):
    say("")
    say("=== ② 取消「出错自动修」→ 就地出现可填的次数 ===")
    pg.click("#chat-unlim_fix")
    if not wait_for(pg, lambda: exists(pg, "chat-fix_max_n"), timeout=10):
        bad("取消「出错自动修」之后没有出现那个数字框（就地出现是用户明确选的"
            "形态，不是「回到某个保守默认值、要去别的页面改」）")
        return
    ok("取消勾选之后出现了数字框")

    if not seen(pg, "chat-fix_max_n"):
        bad("那个数字框在 DOM 里但**看不见**（矩形 %s）—— 等于没出现"
            % pg.evaluate(JS_RECT, "chat-fix_max_n"))
    v = numof(pg, "chat-fix_max_n")
    if v is None:
        bad("数字框里没有数（%s）—— 取消勾选之后它必须画着「上次设的那个值」"
            % pg.evaluate(JS_NUM, "chat-fix_max_n"))
    elif abs(v - AUTOFIX_MAX) > 0.01:
        bad("数字框初值是 %s，应当是 DSAPP_AGENT_AUTOFIX_MAX = %g（设了上限"
            "时用这个当默认）" % (v, AUTOFIX_MAX))
    else:
        ok("初值 %g 次 = DSAPP_AGENT_AUTOFIX_MAX" % v)

    # 填一个别的数，看它站不站得住（站不住 = 每拍都被谁按回去）
    set_num(pg, "chat-fix_max_n", 5)
    v2 = numof(pg, "chat-fix_max_n")
    if v2 != 5:
        bad("填了 5 次，过一会儿再看变成了 %s —— 有人在把它按回去" % v2)
    else:
        ok("填 5 次之后站得住")

    # 单位必须写全：那个窗口（半小时）用户看不到，只写"5 次"会被当成
    # "一辈子 5 次"。
    txt = pg.evaluate(JS_TXT, ".dsapp-ctrl-unlim")
    if txt and "分钟" not in txt:
        bad("「出错自动修」那格没写窗口长度（%r）—— 只写次数的话用户会以为"
            "是一辈子 N 次" % txt[:160])
    else:
        ok("写明了窗口（次 / 30 分钟）")

    # 收回去
    pg.click("#chat-unlim_fix")
    if not wait_for(pg, lambda: not exists(pg, "chat-fix_max_n"), timeout=10):
        bad("把勾勾回去之后那个数字框还赖在页面上")


# ================================================================ ③
def sec_c_pair(pg):
    say("")
    say("=== ③ 只取消**一个**勾：两个勾要一起灭（这一版修掉的那个回归）===")
    # ⚠️ 这条是这一版**最容易被写错**的一处。上下文和单次输出指向同一个值，
    #    原来算的是"两个勾或起来"，于是"只取消其中一个"算出来的 want 还是
    #    TRUE —— 那一次点击什么都改不了，而屏幕上那个框已经空了、取消勾选
    #    该出现的数字框也出现了。用户以为收紧了，其实没有。
    if not (ck(pg, "ctx") and ck(pg, "maxtok")):
        bad("前置不成立：动手之前这两个勾应当都是勾着的，实际是 %s / %s"
            % (ck(pg, "ctx"), ck(pg, "maxtok")))
        return

    pg.click("#chat-unlim_ctx")
    if not wait_for(pg, lambda: ck(pg, "ctx") is False, timeout=10):
        bad("点了「上下文」那个勾，它自己却没灭（点不动？）")
        return
    if not wait_for(pg, lambda: ck(pg, "maxtok") is False, timeout=10):
        bad("只取消了「上下文」，但「单次输出」还是勾着的 —— 两个勾指向**同一"
            "个值**（state$ctx_limit），屏幕上却摆出了「上下文不限、输出受限」"
            "这个表达不出来的组合。这就是这一版要修的那个回归。")
    else:
        ok("取消「上下文」之后「单次输出」跟着一起灭了")

    if not wait_for(pg, lambda: exists(pg, "chat-maxtok_n"), timeout=10):
        bad("两个勾都灭了，但那个数字框没出现")
    else:
        v = numof(pg, "chat-maxtok_n")
        if not seen(pg, "chat-maxtok_n"):
            bad("数字框在 DOM 里但看不见（%s）"
                % pg.evaluate(JS_RECT, "chat-maxtok_n"))
        elif v is None:
            bad("数字框里没有数（%s）" % pg.evaluate(JS_NUM, "chat-maxtok_n"))
        else:
            ok("出现了数字框，初值 %s" % v)

    # 点**另一个**勾把它勾回来：两个必须一起亮，而且数字框要收起来。
    pg.click("#chat-unlim_maxtok")
    if not wait_for(pg, lambda: ck(pg, "ctx") and ck(pg, "maxtok"), timeout=10):
        bad("点了「单次输出」把它勾回来，两个勾没有一起亮（%s / %s）"
            % (ck(pg, "ctx"), ck(pg, "maxtok")))
    else:
        ok("点另一个勾也能把这一对一起勾回来")
    if not wait_for(pg, lambda: not exists(pg, "chat-maxtok_n"), timeout=10):
        bad("勾回「不设上限」之后那个数字框还赖在页面上")
    else:
        ok("勾回去之后数字框收起来了")


# ================================================================ ④
def sec_d_model_page(pg):
    say("")
    say("=== ④ 对话页设的数 ⇄ 模型服务页那一格（跨模块指令通道）===")
    pg.click("#chat-unlim_ctx")
    if not wait_for(pg, lambda: exists(pg, "chat-maxtok_n"), timeout=10):
        bad("前置失败：取消勾选之后数字框没出现")
        return
    set_num(pg, "chat-maxtok_n", 32768)

    goto(pg, "model")
    if not wait_for(pg, lambda: exists(pg, "model-max_tokens"), timeout=15):
        bad("模型服务页上没有 #model-max_tokens —— 参数区没渲染出来？")
        return
    got = pg.input_value("#model-max_tokens")
    if got.strip() != "32768":
        bad("对话页把单次使用上限设成 32768，模型服务页那一格显示的却是 %r。"
            "两个页面上写的不是一回事，而用户只看得见自己面前那一个。" % got)
    else:
        ok("模型服务页那一格也是 32768（跨模块那条指令通道通了）")

    # 反方向：**在模型页**改，回对话页那个框要被拨回来。
    # ⚠️ 不做这一步的话，对话页那个框会一直显示上一个数 —— 而它看起来就是
    #    当前生效的值（见 mod_chat.R 里 ctx_settled 那段）。
    set_num(pg, "model-max_tokens", 49152)
    goto(pg, "chat")
    if not wait_for(pg, lambda: numof(pg, "chat-maxtok_n") == 49152, timeout=25):
        bad("在模型服务页把上限改成 49152，回到对话页那个框里还是 %s —— "
            "它看起来就是当前生效的值，而用户没有任何线索能戳穿它"
            % numof(pg, "chat-maxtok_n"))
    else:
        ok("模型页改了值，对话页那个框被拨回 49152（防抖写回生效）")

    # ★ 再勾回"不设上限"：模型页那一格必须**空**（不是 0、不是 1024）。
    #   0 是哨兵、1024 是下限 —— 两个都是"看起来合理"的错答案，而正确的
    #   表现是空框 + placeholder「跟随模型」。
    dump_unlim(pg, "点「上下文」把它勾回来**之前**")
    click_trace(pg, "chat-unlim_ctx")
    if not wait_for(pg, lambda: ck(pg, "ctx") and ck(pg, "maxtok"), timeout=10):
        bad("往回勾的时候两个勾没一起亮")
        dump_unlim(pg, "点完等了 10 秒")
        return
    goto(pg, "model")
    if not wait_for(pg, lambda: pg.input_value("#model-max_tokens").strip() == "",
                    timeout=25):
        bad("在对话页勾回「不设上限」，模型服务页那一格还是 %r —— 应当是**空**"
            "（空框 = 不设上限，见 V13.14 item 22）。换成 0 或者 1024 都是"
            "看着合理但意思全错的答案。"
            % pg.input_value("#model-max_tokens"))
    else:
        ok("勾回不设上限之后，模型页那一格是空的")
    ph = pg.get_attribute("#model-max_tokens", "placeholder")
    if ph and "跟随模型" in ph:
        ok("空框旁边写着「跟随模型」（空着不等于「这个框坏了」）")
    elif ph is None:
        bad("空框上没有 placeholder —— 用户会以为是自己把这个数弄没了")


# ================================================================ ⑤
def sec_e_wall(pg):
    say("")
    say("=== ⑤ 取消「运行时间」→ 出现的滑块**不在最右那一格** ===")
    # ⚠️ 这一条钉的是"取消勾选之后画的是**记着的那个有限时长**（%g 小时），
    #    不是"不设上限"那一格。画成最右那一格的话，用户以为自己设了个时长，
    #    其实一个数都没设 —— 只是把"不设上限"从勾选框挪到了滑块上。
    goto(pg, "chat")
    ensure_no_modal(pg)
    clear_notes(pg)
    pg.click("#chat-unlim_wall")
    if not wait_for(pg, lambda: exists(pg, "chat-agent_wall"), timeout=10):
        bad("取消「运行时间」之后没有出现那个滑块")
        return
    if not seen(pg, "chat-agent_wall"):
        bad("滑块在 DOM 里但看不见（%s）"
            % pg.evaluate(JS_RECT, "chat-agent_wall"))
        return

    def label():
        return pg.evaluate(JS_TXT, ".dsapp-ctrl-unlim .dsapp-iter-label")

    h = pg.evaluate(JS_SLIDER, "chat-agent_wall")
    if h is None:
        bad("读不出滑块当前的值")
    elif abs(h - WALL_UNLIM_H) < 0.001:
        bad("取消勾选之后滑块直接顶在「不设上限」那一格（%g 小时）—— 用户以为"
            "自己设了时长，其实什么都没设" % h)
    elif abs(h - WALL_DEF_H) > 0.001:
        bad("滑块初值是 %g 小时，应当是记忆里的默认值 %g 小时（最后一格是 "
            "%g）" % (h, WALL_DEF_H, WALL_UNLIM_H))
    else:
        ok("滑块初值 %g 小时 = DSAPP_AGENT_WALL_DEF（不是最右那一格 %g）"
           % (h, WALL_UNLIM_H))

    # 旁边那行小字必须跟着念那个时长，不许还写着"不设上限"。
    lbl = label()
    if lbl is None:
        bad("滑块旁边那行字（.dsapp-iter-label）没了")
    elif "不设上限" in lbl:
        bad("滑块明明停在 %g 小时，旁边那行字却写着「不设上限」（%r）—— "
            "界面在说一件代码没在做的事" % (h, lbl))
    else:
        ok("旁边那行字念的是「%s」" % lbl)

    # 拖到最右 → 那行字要变成「不设上限」（换算入口只有一个）。
    #
    # ⚠️ 要**真的拖**（按下 → 移动 → 松开），不是点一下轨道的最右边：
    #    ionRangeSlider 的手柄自己有宽度，点轨道最右侧那一下算出来的值
    #    不一定是 max（实测读到的是初值 2）。那是**手法**没到、不是应用
    #    不对 —— 所以这一条原来只报 ⚠️。拖手柄没有这个问题：拖到哪儿就是
    #    哪儿，而且它就是用户的手势本身。
    # ⚠️ 手柄从**这个**滑块身上找（`closest('.irs')` 里那个），不是页面上
    #    第一个手柄 —— 这一格旁边还有别的控件，拿错了就是在拖另一个东西，
    #    而"拖了没反应"看起来和"应用坏了"一模一样。
    #
    # ⚠️⚠️ 手柄的 class 是 **`.irs-handle`**，不是 `.irs-slider`。
    #    ionRangeSlider 2.3 起把 `.irs-slider` 改名成了 `.irs-handle`
    #    （本机实测：`document.querySelectorAll('.irs-slider').length` = 0，
    #    `.irs-handle` 有 2 个）。只认老名字的话这里**永远**返回 null ——
    #    而当时的写法是"找不到就 ⚠️ 跳过、探针照样全绿"，于是一个**从来没
    #    跑过**的断言长得和"跑过了、通过了"一模一样（正是本仓栽过好几次的
    #    那个形状：假绿）。所以现在：**找不到手柄 = 红**，不再跳过。
    JS_HANDLE = """() => { var t = document.getElementById('chat-agent_wall');
      if (!t) return null;
      var g = t.closest('.irs') || t.parentElement;
      if (!g) return null;
      var s = g.querySelector('.irs-handle') || g.querySelector('.irs-slider');
      if (!s) return null;
      // ⚠️ 先滚进视口：元素在视口外时鼠标事件**没人接收**，而
      //    getBoundingClientRect() 照样返回正数、全程不报错
      //    （症状是"第一次拖不动、第二次又能动"）。
      s.scrollIntoView({block: 'center'});
      var ln = g.querySelector('.irs-line') || g;
      var r = s.getBoundingClientRect(), lr = ln.getBoundingClientRect();
      return {hx: r.x + r.width / 2, hy: r.y + r.height / 2,
              rx: lr.right - 1, ry: lr.y + lr.height / 2}; }"""
    hb = pg.evaluate(JS_HANDLE)
    if not hb:
        bad("找不到这个滑块的手柄（`.irs-handle` 也没有）—— 拖不动。"
            "⚠️ 这条**不许**降级成 skip：一个从没跑过的断言和跑过了一样绿")
    else:
        pg.mouse.move(hb["hx"], hb["hy"])
        pg.mouse.down()
        pg.mouse.move(hb["rx"], hb["ry"], steps=12)
        pg.mouse.up()
        pg.wait_for_timeout(1200)
        h2 = pg.evaluate(JS_SLIDER, "chat-agent_wall")
        lbl2 = label()
        if h2 is None or abs(h2 - WALL_UNLIM_H) > 0.001:
            bad("拖到轨道最右端了，滑块却停在 %s 小时（最后一格是 %g）—— "
                "要么手柄没被拖到（手法），要么换算把最右那一格钳掉了"
                % (h2, WALL_UNLIM_H))
        elif lbl2 is None or "不设上限" not in lbl2:
            bad("滑块拖到最右那一格，旁边那行字还是 %r —— 那一格是"
                "「不设上限」，字得跟着走" % lbl2)
        else:
            ok("拖到最右那一格 → %g 小时，那行字变成了「%s」"
               % (WALL_UNLIM_H, lbl2))

    # 收回去（免得影响截图）
    pg.click("#chat-unlim_wall")


# ================================================================ ⑥
def sec_f_note(pg):
    say("")
    say("=== ⑥ 全都不设上限时，那句提醒要说得对 ===")
    # ⚠️ 提醒是**每个会话说一次**（unlim_noted），所以这里必须换一个 Shiny
    #    会话 —— 上面几节一个会话走到底，不 reload 的话量到的是"没提醒"，
    #    而那是我们自己造成的。
    pg.reload(wait_until="domcontentloaded")
    if not wait_main(pg):
        bad("reload 之后 180 秒还没回主界面 —— 第 ⑥ 节整节不作数")
        return
    goto(pg, "chat")
    ensure_no_modal(pg)

    # ★★ 这里必须发**两条**消息，第一条只为把那个首选项弹窗用掉。
    #
    #   「AI 怎么干活？」那个弹窗和这条提醒**互斥，而且弹窗优先** —— 排这个
    #   序的是 V16.1 item 5（两条同时弹的话，toast 会被全屏遮罩压住，而它
    #   已经被 unlim_noted 记成"说过了"，这一次会话就再也见不到了，见
    #   mod_chat.R 1772 那行）。这个账号是这一轮探针**刚注册**的，库里
    #   agent_asked 还是假 —— 所以第一次发消息走的必然是弹窗那条路。
    #   ⚠️ 只发一条的话，量到的是"没有任何人提醒" —— 那是设计如此，
    #      不是应用坏了（first-run-onboarding-modal-blocks-clicks）。
    if not send(pg, "随便聊聊"):
        bad("第一条消息没在 120 秒内跑完 —— 后面那条提醒的判据不作数了")
        return
    saw_modal = pg.locator(".modal").count() > 0
    say("  第一条消息弹的首选项弹窗在不在：%s（弹窗优先，提醒让位给第二条）"
        % saw_modal)
    ensure_no_modal(pg)
    clear_notes(pg)
    pg.evaluate(WATCH_NOTES)

    if not send(pg, "再聊一句"):
        bad("第二条消息没在 120 秒内跑完 —— 那条提醒的判据不作数了")
    notes = pg.evaluate("() => (window.__dsappNotes || []).map(function (x) {"
                        " return x.t; })")
    live = pg.evaluate(
        "() => Array.from(document.querySelectorAll('.shiny-notification'))"
        ".map(function (n) {"
        " return (n.innerText || '').replace(/\\s+/g, ' ').trim(); })")
    for t in live:
        if t and t not in notes:
            notes.append(t)
    say("  这一轮出现过的通知 %d 条：" % len(notes))
    for t in notes:
        say("    · " + t[:110])
    hit = [t for t in notes if "不设上限" in t]
    if not hit:
        bad("四个勾默认全勾（全都不设上限），但**没有任何人告诉用户** —— "
            "用户要求的是「没上限模式可以先提醒下用户要不要设置」")
        return
    t = hit[0]
    if "勾" not in t:
        bad("提醒里没说怎么收（现在该说的是「把对应的勾去掉」）：%r"
            % t[:140])
    else:
        ok("提醒说了怎么收（去掉对应的勾）")
    # ★ V16.2：「出错自动修」默认不设上限之后，提醒里**不能**再说
    #    "出错会自己停下来" —— 它现在真的不会。写了就是假话。
    if "出错" in t and ("自己停" in t or "自动停" in t):
        bad("提醒里说「出错会自己停下来」—— 这一版之后它不会了，这是假话：%r"
            % t[:160])
    else:
        ok("提醒里没有「出错会自己停下来」那句假话")
    # 只讲风险不讲兜底是吓人，不是提醒。
    if "停止" not in t:
        bad("提醒里没说其实还有东西在兜底（轮数上限 / 随时能按「停止」）—— "
            "只讲风险是吓人：%r" % t[:160])
    else:
        ok("提醒里说了兜底（轮数上限 / 随时停止）")


def main():
    say("V16.2 浏览器验收：%s" % C.URL)
    say("  自动修上限默认 %g / 时长默认 %g 小时 / 滑块最后一格 %g 小时 / "
        "上下文默认 %g" % (AUTOFIX_MAX, WALL_DEF_H, WALL_UNLIM_H, CTX_DEFAULT))
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1500, "height": 950})
        pg = ctx.new_page()
        errs = []
        badres = []
        pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))
        # ⚠️ "Failed to load resource" 这类 console.error **不带 URL** —— 只报
        #    "有个东西 404 了"，看不出是哪一个。所以资源加载失败一律走下面
        #    那个 response 监听（它带 URL），console 那一侧把它滤掉，免得同
        #    一件事报两遍、而带 URL 的那一遍被不带 URL 的那一遍顶掉。
        pg.on("console",
              lambda m: errs.append("console." + m.type + ": " + m.text)
              if (m.type == "error"
                  and "Failed to load resource" not in m.text) else None)
        pg.on("response",
              lambda r: badres.append((r.status, r.url)) if r.status >= 400 else None)

        pg.goto(C.URL, wait_until="domcontentloaded")
        C.enter_app(pg, C.EMAIL)          # 结尾已经要求 .dsapp-shell，不用再等
        uid, db = C.seed_or_die(C.EMAIL)
        say("账号 uid=%s  实例 %s" % (uid, C.URL))

        fx = C.FakeLLM()
        line = C.seed_llm(uid, fx.url)
        if "=NA" in line:
            sys.exit("种 LLM 设置没写进去：%s" % line)
        say("假 LLM：%s" % fx.url)
        # ★★ 必须 reload：state$base_url 是**会话开始那一刻**读一次的。
        #    不 reload 的话第 ⑥ 节那条消息会打到厂商默认地址上去
        #    （2026-10-02 真发生过一条 401）。
        pg.reload(wait_until="domcontentloaded")
        if not wait_main(pg):
            sys.exit("reload 之后 180 秒还没回主界面 —— 看一眼 %s/app.log" % C.APP)

        # ⚠️ 调试时可以只跑其中几节：`V162_SEC=abcd python3 probe_unlim.py`。
        #    各节之间**是有状态的**（③④ 都以上一节留下来的勾选状态为前置），
        #    所以从中间开始跑的那一节很可能因为前置不成立而红 —— 那不是
        #    应用坏了，是跑法不对。默认全跑。
        want = os.environ.get("V162_SEC", "abcdef")
        for flag, fn in (("a", sec_a_defaults), ("b", sec_b_untick),
                         ("c", sec_c_pair), ("d", sec_d_model_page),
                         ("e", sec_e_wall), ("f", sec_f_note)):
            if flag in want:
                fn(pg)

        # 资源加载失败：**带 URL 报**。favicon 是例外，而且只是 favicon ——
        # 浏览器会自作主张地来要一次 /favicon.ico，应用从来没承诺过这个文件
        # （www/ 里没有，也没有路由），它 404 是常态。除它以外任何一个
        # >=400 都是应用该修的东西，一个都不放过。
        skipped = [u for (s, u) in badres if u.endswith("/favicon.ico")]
        real = [(s, u) for (s, u) in badres if not u.endswith("/favicon.ico")]
        if skipped:
            say("  浏览器自己来要过 %d 次 /favicon.ico（404）—— 应用没承诺过"
                "这个文件，不算" % len(skipped))
        if real:
            bad("有 %d 个资源没加载出来：%s"
                % (len(real), ["%s %s" % (s, u) for (s, u) in real[:5]]))
        if errs:
            bad("浏览器报了 %d 条错，头一条：%s" % (len(errs), errs[0][:200]))
        say("  假 LLM 收到请求数：%s" % fx.req_n())
        fx.stop()
        pg.screenshot(path=os.path.join(C.OUT, "v162.png"), full_page=True)
        ctx.close()
        br.close()

    say("")
    if BAD:
        say("===== 红 %d 条 =====" % len(BAD))
        for m in BAD:
            say("  · " + m)
        sys.exit(1)
    say("===== 全绿 =====")


if __name__ == "__main__":
    main()
