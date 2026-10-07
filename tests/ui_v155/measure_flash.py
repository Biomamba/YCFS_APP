#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量「正在生成时屏幕还是会闪」到底是哪一格在动。

这不是验收探针，是**尺子**。它一条断言都不下，只把生成期间浏览器里发生的
事情数出来：

  ① 每个 Shiny 输出格的**重画次数**，以及其中「画出来和上一版一模一样」的
     次数（白刷）。指纹法见 CLAUDE 里那条 —— 光数 `shiny:outputinvalidated`
     会虚高（写 reactiveVal 就算值没变也失效下游），必须配 outerHTML 指纹。
  ② 带 CSS 动画的节点被**换掉**几次。CSS 动画是跟着元素走的：节点一被替换，
     旋转/闪烁就从 0 重新开始 —— 用户看到的不是"在转"，是"在抖"。所以
     「同一个选择器下出现过多少个不同的节点实例」就是"闪"的直接度量。
  ③ 生成期间有没有东西在**位移**。每 100ms 取一次关键元素的
     getBoundingClientRect，位置变过就是"屏幕在动"。

用法：
    bash tests/ui_v7/make_instance.sh 8925 /tmp/dsapp_v155
    python3 tests/ui_v155/measure_flash.py
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402


# ---------------------------------------------------------------------------
# 浏览器侧的仪表
# ---------------------------------------------------------------------------

_ARM_JS = r"""() => {
  if (window.__v155armed) return;
  window.__v155armed = true;

  window.__v155 = {
    /* 每个输出格的重画统计 */
    outs: {},
    /* MutationObserver 一批一批地来：每批里按"最近的带 id 的祖先"归类 */
    t0: performance.now(),
    /* 带 CSS 动画的节点：同一个选择器下见过多少个不同实例 */
    anim: {},
    /* 位移：每 100ms 采一次 */
    rects: {},
    samples: 0
  };

  function ownerOf(node) {
    var el = (node && node.nodeType === 3) ? node.parentElement : node;
    while (el && el !== document.body) {
      if (el.id && (el.id.indexOf('chat-') === 0 || el.id.indexOf('lit-') === 0))
        return el.id;
      if (el.classList &&
          (el.classList.contains('shiny-html-output') ||
           el.classList.contains('shiny-bound-output')))
        return el.id || ('(anon)' + (el.className || '').slice(0, 40));
      el = el.parentElement;
    }
    return '(body)';
  }

  /* 指纹：同一批里同一个格只算一次。
   *
   * ★ childList 和 attributes **必须分开数**：Shiny 的 renderUI 走的是
   *   innerHTML 整体替换（整块 DOM 拆了重建 → 元素身份变了 → CSS 动画归零），
   *   而 app.js 更新 data-secs 走的是 setAttribute（就地改，节点没换）。
   *   两者混在一起数会虚高，量不出"闪"。 */
  var obs = new MutationObserver(function (recs) {
    var hit = {};
    for (var i = 0; i < recs.length; i++) {
      var o = ownerOf(recs[i].target);
      if (o === '(body)') o = 'body:' + (recs[i].target.className || '?');
      var st = hit[o] || (hit[o] = {rebuild: false, attr: false});
      /* characterData 也算"就地改"：文本节点变了不等于元素被换掉 */
      if (recs[i].type === 'childList') st.rebuild = true;
      else st.attr = true;
    }
    Object.keys(hit).forEach(function (o) {
      var el = (o === '(body)' || o.indexOf('body:') === 0)
             ? null : document.getElementById(o);
      var fp = el ? (el.outerHTML || '').length + ':' + hash(el.outerHTML || '')
                  : '-' + Math.random();
      var st = window.__v155.outs[o] ||
               (window.__v155.outs[o] = {n: 0, white: 0, last: null,
                                         rebuild: 0, attr: 0});
      st.n += 1;
      if (hit[o].rebuild) st.rebuild += 1;
      if (hit[o].attr) st.attr += 1;
      if (st.last === fp) st.white += 1;
      st.last = fp;
    });
  });
  obs.observe(document.body, {childList: true, subtree: true,
                              characterData: true, attributes: true});

  function hash(s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return h.toString(36);
  }

  /* ★★ 逐帧看正文那一块：它有没有**缩回去**、有没有**塌掉**。
   *
   * 这是"闪"的最后一道判据。100ms 采一次是不够的 —— 重画是原子操作（拆和
   * 建在同一个任务里），浏览器根本不会画出中间态，所以按 100ms 采样永远
   * 采不到"空一帧"。但**逐帧**（rAF，约 16ms）能把所有真的被画出来的状态
   * 都覆盖到：只要有一次绘制时气泡变矮了或者字变少了，用户就看得见。
   *
   * ⚠️ rAF 回调跑在"DOM 改完、绘制之前"，所以在这里读到的就是**这一帧要画
   *    出去的东西** —— 判据成立。 */
  (function raf() {
    var R = window.__v155;   /* ⚠️ 这一段是 ARM 脚本，这里没有 _SAMPLE 那个 R 局部量 */
    var f = R.frame || (R.frame = {n: 0, shrink: 0, collapse: 0,
                                    lastLen: -1, minH: 1e9, maxLen: 0});
    var b = document.querySelector('#chat-streaming .dsapp-bubble');
    f.n += 1;
    if (b) {
      var len = (b.innerText || '').length;
      var h = b.getBoundingClientRect().height;
      if (len > f.maxLen) f.maxLen = len;
      if (f.lastLen >= 0 && len < f.lastLen - 2) f.shrink += 1;
      f.lastLen = len;
      if (len > 40 && h < f.minH) f.minH = Math.round(h);
      if (len > 40 && h < 8) f.collapse += 1;
    }
    requestAnimationFrame(raf);
  })();
  window.__v155hash = hash;
  window.__v155obs = obs;
}"""


_SAMPLE_JS = r"""() => {
  var R = window.__v155;
  if (!R) return null;
  R.samples += 1;

  /* ① 带动画的节点：盖一次性记号，数"见过几个实例"。
   *
   * ★ 这就是"闪"的直接度量：CSS 动画跟着元素走，元素一换，旋转/闪烁就从 0
   *   重新开始。所以「同一选择器下出现过多少个不同实例」= 动画归零了几次。 */
  var SEL = ['.dsapp-cursor', '.dsapp-wait-spin', '.dsapp-quip',
             '.dsapp-progress-bar', '.dsapp-busy', '.spinner-border',
             '.dsapp-elapsed', '.dsapp-think-pre',
             '#chat-streaming .dsapp-bubble',   /* 正文气泡：整块被换掉几次 */
             '.dsapp-composer-hint .spinner-border'];
  var now = performance.now();
  SEL.forEach(function (s) {
    var els = document.querySelectorAll(s);
    var st = R.anim[s] || (R.anim[s] = {seen: {}, alive: 0, maxAlive: 0,
                                        first: now, last: now, gaps: []});
    st.alive = els.length;
    if (els.length > st.maxAlive) st.maxAlive = els.length;
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (!e.dataset.v155u) {
        e.dataset.v155u = 'u' + Math.random().toString(36).slice(2);
        /* 新实例出现 = 上一次的动画被掐断 */
        st.gaps.push(Math.round(now - st.last));
        st.last = now;
      }
      st.seen[e.dataset.v155u] = 1;
    }
    st.uniq = Object.keys(st.seen).length;
  });

  /* ② 位移：几个"本该钉死不动"的锚点 */
  var ANCH = {'#chat-input': null, '#chat-send': null,
              '.dsapp-chat-page': null, '.dsapp-progress': null};
  Object.keys(ANCH).forEach(function (s) {
    var e = document.querySelector(s);
    var st = R.rects[s] || (R.rects[s] = {moved: 0, last: null, box: null});
    if (!e) { st.gone = true; return; }
    var b = e.getBoundingClientRect();
    var k = [b.x | 0, b.y | 0, b.width | 0, b.height | 0].join(',');
    if (st.last !== null && st.last !== k) st.moved += 1;
    st.last = k; st.box = k;
  });

  /* ★ 顶部那条进度条的 is-on 开合次数。
   *   它是一条**横扫整屏**的高光，被反复开关的话就是"屏幕在闪"。
   *   元素本身不重建（那一条已经修过了），但 class 是切出来的。 */
  var pg = document.querySelector('.dsapp-progress');
  if (pg) {
    var on = pg.classList.contains('is-on');
    var ps = R.pg || (R.pg = {flips: 0, last: null, onSamples: 0, offSamples: 0});
    if (ps.last !== null && ps.last !== on) ps.flips += 1;
    ps.last = on;
    if (on) ps.onSamples += 1; else ps.offSamples += 1;
  }

  /* ③ hint 那一格的可见文本（用户眼睛落的地方） */
  var h = document.getElementById('chat-hint');
  R.hint = h ? (h.innerText || '').slice(0, 120) : null;
  return true;
}"""


def _sse_stream(reason_parts, content_parts, finish="stop"):
    """思维链一段一个事件、正文也**一段一个事件**。

    `C.sse_multi` 只分思维链，正文永远是**一整个**事件 —— 正文一多，
    它在服务端侧就等于"一次到齐"，量不到"正在往外吐"的这段窗口。
    """
    def chunk(o):
        return "data: " + json.dumps(o) + "\n\n"

    out = ""
    for p in reason_parts:
        out += chunk({"choices": [{"delta": {"reasoning_content": p},
                                   "finish_reason": None}]})
    for p in content_parts:
        out += chunk({"choices": [{"delta": {"content": p + "\n\n"},
                                   "finish_reason": None}]})
    out += chunk({"choices": [{"delta": None, "finish_reason": finish}]})
    return out + "data: [DONE]\n\n"


def relogin(page, email):
    page.goto(C.URL, wait_until="domcontentloaded")
    page.wait_for_timeout(1500)
    try:
        page.evaluate("() => localStorage.clear()")
    except Exception:
        pass
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector("#chat-input", timeout=90000)


def ensure_no_modal(page, timeout=8):
    """新账号第一次进对话页有个「AI 怎么干活？」的弹窗，会把所有 click 吃掉。"""
    end = time.time() + timeout
    while time.time() < end:
        try:
            if page.locator(".modal.show").count() == 0:
                return True
            btn = page.locator(".modal.show button")
            if btn.count():
                btn.first.click()
            page.wait_for_timeout(400)
        except Exception:
            page.wait_for_timeout(300)
    return page.locator(".modal.show").count() == 0


def main():
    fx = None
    report = {}
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch()
            page = browser.new_page(viewport={"width": 1440, "height": 900})

            # ⚠️ 这几个测试实例上 `enter_app` 偶尔会在"注册完页面空白"那一关
            #    失败，而这不是本版的回归（V15.2 的实例上同样会）。每次
            #    enter_app 都注册一个新账号，重试是安全的。
            print("== 注册 ==", flush=True)
            email = None
            for i in range(3):
                tag = "%s_%d" % (str(int(time.time()))[-6:], i)
                try:
                    C.enter_app(page, email="v155m_%s@example.com" % tag)
                    email = C.LAST_EMAIL
                    break
                except SystemExit as e:
                    print("  ⚠️ 第 %d 次没进去：%s" % (i + 1, str(e)[:120]),
                          flush=True)
                    time.sleep(3)
            if email is None:
                sys.exit("连着 3 次都没注册进去")
            print("  email=%s" % email, flush=True)
            uid, db = C.seed_or_die(email)

            fx = C.FakeLLM()
            print("  假 LLM: %s" % fx.url, flush=True)
            C.seed_llm(uid, fx.url, model="fake-model")
            relogin(page, email)
            ensure_no_modal(page)

            C.goto(page, "chat")
            ensure_no_modal(page)

            # ★ 正文必须**一小段一个 SSE 事件**地吐。
            #   C.sse_multi 把整段正文塞进一个事件里 —— 那样正文字节在一个
            #   200ms 轮询周期内一次到齐，"正在往外吐"这个过程**一次采样都取
            #   不到**，量出来的重画次数会少得离谱（第一版就是这样，正文只
            #   重画了 4 次）。真实的流式回复是一条一条来的。
            fx.slow(0.25)
            parts = ["先看用户给了什么。", "这一步要确认物种和注释版本。",
                     "然后决定是走比对还是走定量。", "定量的话得先有 count 矩阵。",
                     "还得确认参考基因组对不对。", "最后把步骤写成代码。",
                     "检查一遍依赖装没装。", "再核一遍输出目录。",
                     "再核一遍物种。", "再核一遍参考基因组。",
                     "把参数写进配置。", "好了，可以动笔了。"]
            body_parts = ["第 %d 步大概是这样：先确认输入，再确认参考，"
                          "然后跑一遍，最后把结果收进报告。" % i
                          for i in range(1, 41)]
            fx.set_queue(_sse_stream(parts, body_parts))

            page.evaluate(_ARM_JS)
            page.fill("#chat-input", "想一个分析方案")
            page.click("#chat-send")

            # 采样 40 秒（慢放 0.25 秒一块 × 12 块思考 + 40 块正文 ≈ 13 秒流，
            # 加上首轮的库查询/上下文拼装，40 秒足够覆盖整段）
            t0 = time.time()
            n = 0
            while time.time() - t0 < 40:
                page.evaluate(_SAMPLE_JS)
                n += 1
                time.sleep(0.1)

            out = page.evaluate("""() => {
                var R = window.__v155;
                return {outs: R.outs, anim: R.anim, rects: R.rects,
                        pg: R.pg, frame: R.frame,
                        samples: R.samples, hint: R.hint};
            }""")
            report = out

            print("\n== 采样 %d 次（%.0f 秒）==" % (n, time.time() - t0), flush=True)

            print("\n-- ① 各输出格的重画 --", flush=True)
            print("   %-30s %8s %8s %8s %7s"
                  % ("格", "重建", "就地改", "白刷", "白刷%"), flush=True)
            rows = sorted(out["outs"].items(), key=lambda kv: -kv[1]["n"])
            for k, v in rows:
                pct = (100.0 * v["white"] / v["n"]) if v["n"] else 0
                print("   %-30s %8d %8d %8d %6.0f%%"
                      % (k, v["rebuild"], v["attr"], v["white"], pct),
                      flush=True)

            print("\n-- ② 带动画的节点被换掉几次（= 动画归零几次）--", flush=True)
            print("   %-32s %8s %8s %8s %8s"
                  % ("选择器", "实例数", "同屏最多", "收尾同屏", "中位间隔"), flush=True)
            for k, v in sorted(out["anim"].items(), key=lambda kv: -kv[1]["uniq"]):
                gp = sorted(x for x in v.get("gaps", []) if x > 0)
                med = gp[len(gp) // 2] if gp else 0
                print("   %-32s %8d %8d %8d %7dms"
                      % (k, v["uniq"], v["maxAlive"], v["alive"], med), flush=True)

            print("\n-- ③ 锚点位移 --", flush=True)
            for k, v in out["rects"].items():
                print("   %-22s moved=%-4s box=%s"
                      % (k, v.get("moved"), v.get("box")), flush=True)

            print("\n-- ④ 顶部进度条的开合 --", flush=True)
            pg = out.get("pg") or {}
            print("   开↔关翻转 %s 次；采样中「开着」%s 帧 / 「关着」%s 帧"
                  % (pg.get("flips"), pg.get("onSamples"), pg.get("offSamples")),
                  flush=True)

            print("\n-- ⑤ 正文那一块逐帧（rAF）--", flush=True)
            fr = out.get("frame") or {}
            print("   看了 %s 帧；字数最多 %s；变少过 %s 帧；最矮 %spx；"
                  "塌到 <8px 的 %s 帧"
                  % (fr.get("n"), fr.get("maxLen"), fr.get("shrink"),
                     fr.get("minH"), fr.get("collapse")), flush=True)

            print("\n   hint 收尾文本: %r" % (out.get("hint"),), flush=True)

            with open(C.OUT + "/flash_report.json", "w") as f:
                json.dump(report, f, indent=1, ensure_ascii=False)
            print("\n   报告写到 %s/flash_report.json" % C.OUT, flush=True)

            page.screenshot(path=C.OUT + "/flash_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
