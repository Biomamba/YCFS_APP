# -*- coding: utf-8 -*-
"""分析进行时：页面**不**刷新，但新内容照旧实时蹦出来。

    python3 tests/ui_v1312/probe_quiet.py

这是 V13.12 item 20 的回归探针。用户原话：

    「分析进行时页面还是会刷新，取消这个机制，实时更新蹦出新结果就好」

"取消刷新"和"实时更新"是一对**互相拉扯**的要求 —— 只做到前者（把定时器
一删了事）会得到一个定格在"正在生成…"的页面：转圈圈在转，字符数一动不动。
本探针就是把这根线两头都钉住：

  1. **不刷**：`shiny:outputinvalidated` 数每个 output 被重画几次，
     再拿 outerHTML 做指纹数"画出来一个字都没变"的白刷 —— 白刷必须接近 0。
     基线（改之前）：24 秒里 chat-hint 重画 145 次、白刷 95 次（66%）。
  2. **还在长**：正文长度、`已输出 N 字符`、`已用 N 秒` 三个数在采样窗口里
     都必须**单调长上去**。其中秒数是纯前端的（app.js 的 dsappElapsedTick），
     字符数是服务端 stream_sig 指纹推的 —— 两条路各自独立，各查各的。

⚠️ 秒数那条断言是这个探针里最容易写错的地方：它**不能**跟正文长度绑在一起
   查。秒数走的是本地时钟，正文可能隔两秒才来一批；把"秒数变了"写成"跟着
   某次重画变"的话，一个正常的实现会被判红。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8913/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v1312/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1312")

from playwright.sync_api import sync_playwright  # noqa: E402
import _common as C  # noqa: E402

MOCK = "http://127.0.0.1:8931/v1"
WINDOW_S = 24

HOOK = """
() => {
  window.__q = {n: {}, same: {}, last: {}};
  $(document).on('shiny:outputinvalidated', function (e) {
    var el = e.target;
    var id = (el && el.id) || '(no-id)';
    window.__q.n[id] = (window.__q.n[id] || 0) + 1;
    var prev = window.__q.last[id];
    setTimeout(function () {
      var now = el ? el.outerHTML : '';
      if (prev !== undefined && now === prev) {
        window.__q.same[id] = (window.__q.same[id] || 0) + 1;
      }
      window.__q.last[id] = now;
    }, 0);
  });
}
"""

SAMPLE = """
() => {
  var body = document.querySelector('#chat-streaming');
  var hint = document.querySelector('#chat-hint');
  var el   = document.querySelector('#chat-hint .dsapp-elapsed');
  var txt  = hint ? (hint.textContent || '') : '';
  var m    = txt.match(/已输出\\s*([0-9,]+)\\s*字符/);
  return {
    body: body ? (body.textContent || '').length : -1,
    chars: m ? parseInt(m[1].replace(/,/g, ''), 10) : -1,
    secs: el ? (el.textContent || '') : '',
    hint: txt.slice(0, 120)
  };
}
"""


def secs_of(s):
    """` · 已用 12 秒` → 12；认不出来给 -1。"""
    m = re.search(r"(\d+)", s or "")
    return int(m.group(1)) if m else -1


def main():
    k = C.Chk()
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1600, "height": 950})
        pg.on("console", lambda m: None)
        e = C.enter_app(pg)
        C.seed_or_die(e)

        C.goto(pg, "model")
        pg.fill("#model-api_key", "sk-mock")
        pg.fill("#model-base_url", MOCK)
        pg.wait_for_timeout(1500)
        pg.locator("#model-commit").click()
        pg.wait_for_timeout(4000)

        C.goto(pg, "chat")
        pg.wait_for_timeout(1500)
        nb = pg.locator("#chat-new_chat")
        if nb.count():
            nb.first.click()
            pg.wait_for_timeout(2000)

        # 模型必须是那个假服务里的 id，否则请求会打到真厂商
        C.pick_select(pg, "#chat-model", "mock-slow") if pg.locator(
            "#chat-model").count() else None

        pg.evaluate(HOOK)
        pg.fill("#chat-input", "随便说点什么，越慢越好")
        pg.wait_for_timeout(500)
        print("发送……", flush=True)
        pg.locator("#chat-send").first.click()

        bodies, chars, secs = [], [], []
        for i in range(WINDOW_S):
            pg.wait_for_timeout(1000)
            s = pg.evaluate(SAMPLE)
            bodies.append(s["body"])
            chars.append(s["chars"])
            secs.append(secs_of(s["secs"]))
            if i % 4 == 0:
                print("  t=%2ds  正文 %5s 字符  已输出 %5s  秒数 %3s"
                      % (i + 1, s["body"], s["chars"], s["secs"]), flush=True)

        d = pg.evaluate("() => window.__q || {}")
        b.close()

    # ---- 1) 不刷：白刷必须接近 0 --------------------------------------------
    print("\n%-24s %8s %8s %8s" % ("output", "重画", "白刷", "占比"), flush=True)
    tot = same = 0
    # ⚠️ 循环变量别叫 k —— 上面那个断言器就叫 k，一覆盖，下面的 k(...) 全变成
    #    "str is not callable"，报错位置还指在断言上，看着像断言本身写错了。
    for oid in sorted(d.get("n", {}), key=lambda x: -d["n"][x]):
        n = d["n"][oid]
        s = d.get("same", {}).get(oid, 0)
        tot += n
        same += s
        print("%-24s %8d %8d %7.0f%%"
              % (oid, n, s, 100.0 * s / n if n else 0), flush=True)
    print("%-24s %8d %8d %7.0f%%"
          % ("合计", tot, same, 100.0 * same / tot if tot else 0), flush=True)

    k("跑起来了（正文确实在长，不是一片空白）",
       bodies and max(bodies) > 40,
       "正文最长 %s 字符" % (max(bodies) if bodies else "—"))
    k("★★★ 正文是**边跑边长**的（至少长了 6 次；涨一次到底就是「假流式」）",
       sum(1 for a, b2 in zip(bodies, bodies[1:]) if b2 > a) >= 6,
       "增长次数 %d，采样 %d 次"
       % (sum(1 for a, b2 in zip(bodies, bodies[1:]) if b2 > a), len(bodies)))
    k("★★★ 「已用 N 秒」自己在走（前端秒表；服务端已经不推它了）",
       secs and max(secs) - min(secs) >= 4,
       "秒数区间 %s..%s" % (min(secs or [0]), max(secs or [0])))
    k("★★★ 「已输出 N 字符」跟着涨（stream_sig 指纹；删了它就定格）",
       chars and sum(1 for a, b2 in zip(chars, chars[1:]) if b2 > a) >= 3,
       "字符数 %s..%s" % (min(chars or [0]), max(chars or [0])))

    # 基线是 145 次 / 95 次白刷。给足余量：重画降到 1/3 以下、白刷降到 1/5 以下。
    n_hint = d.get("n", {}).get("chat-hint", 0)
    s_hint = d.get("same", {}).get("chat-hint", 0)
    k("★★★ chat-hint 不再被定时器推着重画（基线 24 秒 145 次）",
       n_hint <= 48, "这次 %d 次" % n_hint)
    k("★★★ 白刷（画出来一模一样）基本消失（基线 66%）",
       n_hint == 0 or 100.0 * s_hint / n_hint <= 20.0,
       "chat-hint 白刷 %d/%d" % (s_hint, n_hint))
    k("★★ 整页白刷占比也降下来（基线 57%）",
       tot == 0 or 100.0 * same / tot <= 20.0,
       "合计 %d/%d" % (same, tot))

    return k.done()


if __name__ == "__main__":
    sys.exit(main())
