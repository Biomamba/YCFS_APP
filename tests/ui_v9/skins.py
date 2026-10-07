# -*- coding: utf-8 -*-
"""V9 item 10：不同皮肤下字体颜色的自适应。

用户的原话：「不同风格皮肤请注意字体颜色的自适应，让字体和背景有反差
能看得清，例如言出法随页面的分析环境选择字就看不清」。

★ 为什么这个脚本要单独存在，而不是并进 tests/ui_v8/skins.py：
  ui_v8 那个只量了 **4 个选择器**（用户气泡 / 输入框 / 主按钮 / body）。
  用户报的「分析环境选择」那一个不在里面 —— 于是 V8 全绿，用户一上手
  就看不见字。**这就是覆盖面的问题，不是某一个选择器的问题**，
  所以这里改成遍历页面上**所有**渲染出来的控件，而不是挑几个。

★ 病根（查清楚了再修的，别只贴个 CSS 补丁）：
  Bootstrap 那份 `:root` 里的 `--bs-*-rgb` 是**编译期**从 bslib 主题算出来
  的字面量，不是 `rgb(from var(...))`，皮肤换了它不跟着变。而且 bslib 的
  深色主题把黑白反着编译（实测 `--bs-black = #E6EDF3`、`--bs-white = #0D1117`），
  于是 `--bs-body-bg-rgb` 里存的其实是**前景**色。
  selectize 编译出来恰好是「字色取 --bs-emphasis-color-rgb、底色取
  --bs-body-bg」—— 两个来源不同步的变量，浅色皮肤下就是白底白字。

  所以下面第一组断言是**变量级**的：对每个皮肤，逐对核对
  `--bs-X` 和 `--bs-X-rgb` 解析出来是不是同一个颜色。这一条能在
  "某个皮肤漏写了一对"的当下就红，而不用等用户来报。

对着一次性实例（8898）跑，会真的注册账号、真的切皮肤。
"""
import io
import os
import random
import sys

from playwright.sync_api import sync_playwright

# ---- 路径与**防误伤闸门**（同 tests/ui_v8/*.py，理由见那边的注释）---------
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v9")


def _guard(app):
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身（线上那份代码）。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("DSAPP_DATA_ROOT="):
            root = ln.split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：%s 里没有 DSAPP_DATA_ROOT。" % envf)
    if not (root.startswith("/tmp/") or root.startswith("/var/tmp/")):
        sys.exit("拒绝运行：DSAPP_DATA_ROOT=%s 不在临时目录下。" % root)
    return root


DATA_ROOT = _guard(APP)
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


SKINS = ["dark", "light", "chatgpt", "claude", "apple"]

# ---- 变量级：--bs-X 和 --bs-X-rgb 必须是同一个颜色 -------------------------
#
# ⚠️ 用 getComputedStyle 读，不是读 CSS 文本。要验的恰恰是"这个 var 最终
#    解析成了什么"，读源码只能读到 `var(--bs-body-bg)` 这种没解析的字符串。
RGB_PAIR_JS = r"""
() => {
  const cs = getComputedStyle(document.documentElement);
  const names = ['body-bg', 'body-color', 'emphasis-color', 'secondary-color',
                 'secondary-bg', 'tertiary-bg'];
  const toRGB = (s) => {
    s = (s || '').trim();
    // ⚠️ 自定义属性拿到的是**指定值**，不是计算后的 rgb()：本体那一边是
    //    `#0d1117` 这样的原样字符串，而 -rgb 那一边是裸的 `13, 17, 23`。
    //    两种形态都要认，否则 -rgb 一律解析成 null，这条断言永远红 ——
    //    而红得没有信息量（第一版就是这么写的）。
    let m = s.match(/^#([0-9a-f]{6})$/i);
    if (m) {
      const n = parseInt(m[1], 16);
      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    m = s.match(/^rgba?\(([^)]+)\)/);
    if (m) return m[1].split(',').slice(0, 3).map(x => Math.round(parseFloat(x)));
    m = s.match(/^(\d+)\s*,\s*(\d+)\s*,\s*(\d+)$/);
    if (m) return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
    return null;
  };
  const out = {};
  for (const n of names) {
    const a = toRGB(cs.getPropertyValue('--bs-' + n));
    const b = toRGB(cs.getPropertyValue('--bs-' + n + '-rgb'));
    out[n] = {
      plain: cs.getPropertyValue('--bs-' + n).trim(),
      rgb: cs.getPropertyValue('--bs-' + n + '-rgb').trim(),
      same: !!(a && b && a[0] === b[0] && a[1] === b[1] && a[2] === b[2])
    };
  }
  return out;
}
"""

# ---- 控件级：把页面上所有可见控件的字/底对比度都量一遍 ---------------------
#
# 这一条是**覆盖面**的修法。挑选择器写死的清单，下次新增一个控件就又漏了；
# 这里由浏览器自己列出"页面上有哪些带字的控件"，逐个量。
#
# 排除的东西和理由：
#   * 隐藏元素（offsetParent === null 且不是 fixed）—— 量了没意义
#   * 纯图标/无字元素 —— 没有字就没有对比度问题
#   * .dsapp-skinpick 里的卡片 —— 那上面是**别的皮肤**的预览色，故意不随
#     当前皮肤走（见 skins.css 里那段说明），量它必红，而且是误报
SCAN_JS = r"""
() => {
  const parse = (c) => {
    const m = (c || '').match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(x => parseFloat(x));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const over = (f, b) => ({
    r: f.r * f.a + b.r * (1 - f.a),
    g: f.g * f.a + b.g * (1 - f.a),
    b: f.b * f.a + b.b * (1 - f.a)
  });
  const lum = (c) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); };
    return 0.2126*f(c.r) + 0.7152*f(c.g) + 0.0722*f(c.b);
  };
  const ratioOf = (el) => {
    const cs = getComputedStyle(el);
    let bg = parse(cs.backgroundColor), node = el;
    while ((!bg || bg.a === 0) && node.parentElement) {
      node = node.parentElement;
      bg = parse(getComputedStyle(node).backgroundColor);
    }
    if (!bg || bg.a === 0) bg = parse(getComputedStyle(document.body).backgroundColor);
    if (!bg) return null;
    const fg = parse(cs.color);
    if (!fg) return null;
    const base = bg.a < 1 ? over(bg, { r: 255, g: 255, b: 255 }) : bg;
    const f2 = fg.a < 1 ? over(fg, base) : fg;
    const L1 = lum(f2), L2 = lum(base);
    return {
      ratio: Math.round(((Math.max(L1,L2) + 0.05) / (Math.min(L1,L2) + 0.05)) * 100) / 100,
      fg: cs.color, bg: cs.backgroundColor
    };
  };
  const visible = (el) => {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    if (parseFloat(cs.opacity) < 0.15) return false;
    const r = el.getBoundingClientRect();
    return r.width > 2 && r.height > 2;
  };
  // 控件 = 用户会去读/点的那几类元素
  const sel = 'button, a, label, input, select, textarea, .selectize-input, ' +
              '.selectize-dropdown, .nav-link, .card-header, .form-text, ' +
              '.text-muted, .small, td, th, h1, h2, h3, h4, h5, h6, p, span';
  // ⚠️ 只量**看得见字**的元素。这几类必须排除，否则全是误报：
  //    · range / checkbox / radio —— el.value 是 "low"/"max"/"on" 这种
  //      机器值，页面上根本不显示；
  //    · ionRangeSlider 的 irs-hidden-input —— 名字里就写着 hidden；
  //    · opacity:0 的垫片（Shiny 的绑定辅助元素）。
  //    第一版没排，结果每个皮肤都报同一批"看不见的字"，真正的问题
  //    （页脚）反而淹在里面。
  const isTextInput = (el) => {
    if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return false;
    const t = (el.getAttribute('type') || 'text').toLowerCase();
    return ['text','search','email','url','tel','password','number'].includes(t);
  };
  const visibleText = (el) => {
    if (el.classList.contains('irs-hidden-input')) return false;
    if (isTextInput(el)) return (el.value || el.placeholder || '').trim();
    if (el.tagName === 'INPUT' || el.tagName === 'SELECT') return '';
    return (el.innerText || '').trim();
  };
  const bad = [], all = [];
  for (const el of document.querySelectorAll(sel)) {
    if (el.closest('.dsapp-skinpick')) continue;      // 皮肤预览卡，见上
    const txt = visibleText(el);
    if (!txt) continue;
    if (el.children.length > 0 && !['BUTTON','A','LABEL','TD','TH'].includes(el.tagName)) {
      // 只量"自己直接装字"的元素。容器元素的字是子元素画的，
      // 拿容器的 color 去量会量出一个页面上根本不存在的组合。
      // childNodes 是 NodeList，没有 .some（第一版就是这么写错的）
      const kids = Array.prototype.slice.call(el.childNodes || []);
      if (!kids.some(n => n.nodeType === 3 && n.textContent.trim())) continue;
    }
    if (!visible(el)) continue;
    const r = ratioOf(el);
    if (!r) continue;
    const rec = {
      tag: el.tagName.toLowerCase(),
      cls: (el.className || '').toString().slice(0, 60),
      id: el.id || '',
      text: txt.slice(0, 24),
      ratio: r.ratio, fg: r.fg, bg: r.bg
    };
    all.push(rec);
    // 4.5:1 是 WCAG AA 的正文门槛。小字（.small / .text-muted / form-text）
    // 也在里面 —— 用户报的「分析环境」那几个字恰恰是小字。
    if (r.ratio < 4.5) bad.push(rec);
  }
  return { n: all.length, bad: bad,
           worst: all.sort((a, b) => a.ratio - b.ratio).slice(0, 6) };
}
"""

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v9skin_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V9皮肤")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000003")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    # ⚠️ V9 item 1 之后这一勾是**必须**的：服务端不勾就拒绝注册（前端的置灰
    #    只是提示，判据在服务端）。漏掉它的表现不是"注册报错"，而是**注册
    #    没发生** —— 脚本继续往下跑，30 秒后在一个毫不相干的点击上超时，
    #    报出来的方向完全是错的。
    pg.check(".dsapp-auth input[type=checkbox]")
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    # ⚠️ 用 wait_for_selector 而不是 count()：注册完到主界面渲染出来是
    #    有间隔的（进主界面后还有一串 output 要算）。快照式地数一下会在
    #    **机器慢的时候**红，而后面每一条又都正常 —— 那种红最容易被当成
    #    "偶发"忽略掉。
    try:
        pg.wait_for_selector(".dsapp-shell", timeout=30000)
        shell_ok = True
    except Exception:
        shell_ok = False
    chk("注册进到主界面", shell_ok,
        pg.inner_text("body")[:200].replace("\n", " "))

    # 填一把假 Key：没有 Key 时对话页不渲染工作区那一整块，
    # 也就量不到「分析环境」那些控件（同 ui_v8/skins.py 里那段说明）。
    pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
    pg.wait_for_timeout(1500)
    if pg.locator(".dsapp-rail-model #model-api_key").count():
        pg.fill(".dsapp-rail-model #model-api_key", "sk-fake-only-for-layout")
        pg.locator(".dsapp-rail-model #model-commit").click()
        pg.wait_for_timeout(3000)
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(3000)

    # 分析环境那一格必须在。它不在的话下面那几条会全部"通过"（量不到 =
    # 不报错），而用户报的就是它 —— 所以先单独确认它渲染出来了。
    chk("★ 对话页的「分析环境」控件在（用户报的就是这一处）",
        pg.locator(".dsapp-target-bar").count() > 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    for i, sk in enumerate(SKINS):
        pg.locator(".dsapp-rail-link", has_text="设置").first.click()
        pg.wait_for_timeout(1200)
        pg.locator('.dsapp-skinpick input[type="radio"]').nth(i).check(force=True)
        pg.wait_for_timeout(500)
        got = pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
        chk("[%s] 皮肤切过去了" % sk, got == sk, got)

        # ---- 第一组：变量成对 ----------------------------------------
        pairs = pg.evaluate(RGB_PAIR_JS)
        broken = [k for k, v in pairs.items() if not v["same"]]
        chk("★ [%s] --bs-*-rgb 全部和本体同色（%d 对）" % (sk, len(pairs)),
            not broken,
            "; ".join("%s: %s vs %s" % (k, pairs[k]["plain"], pairs[k]["rgb"])
                      for k in broken))

        # ---- 第二组：言出法随页上所有控件的对比度 ----------------------
        pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
        pg.wait_for_timeout(1500)

        # 2a) 用户点名的那一处，单独断言（失败了要一眼看出是它）
        env = pg.evaluate("""() => {
          const el = document.querySelector('.dsapp-target-select .selectize-input');
          if (!el) return null;
          const cs = getComputedStyle(el);
          return { color: cs.color, bg: cs.backgroundColor,
                   label: (document.querySelector('.dsapp-target-bar') || {}).innerText };
        }""")
        if env is None:
            chk("★ [%s] 「分析环境」的 selectize 量得到" % sk, False, "选择器没命中")
        else:
            c = pg.evaluate(
                """(sel) => {
                  const el = document.querySelector(sel);
                  const cs = getComputedStyle(el);
                  const parse = (c) => {
                    const m = c.match(/rgba?\\(([^)]+)\\)/);
                    if (!m) return null;
                    const p = m[1].split(',').map(x => parseFloat(x));
                    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
                  };
                  const over = (f, b) => ({ r: f.r*f.a + b.r*(1-f.a),
                                            g: f.g*f.a + b.g*(1-f.a),
                                            b: f.b*f.a + b.b*(1-f.a) });
                  const lum = (c) => { const f = (v) => { v /= 255;
                    return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); };
                    return 0.2126*f(c.r) + 0.7152*f(c.g) + 0.0722*f(c.b); };
                  let bg = parse(cs.backgroundColor), node = el;
                  while ((!bg || bg.a === 0) && node.parentElement) {
                    node = node.parentElement;
                    bg = parse(getComputedStyle(node).backgroundColor);
                  }
                  if (!bg) bg = { r: 255, g: 255, b: 255, a: 1 };
                  const fg = parse(cs.color);
                  const base = bg.a < 1 ? over(bg, { r: 255, g: 255, b: 255 }) : bg;
                  const f2 = fg.a < 1 ? over(fg, base) : fg;
                  const L1 = lum(f2), L2 = lum(base);
                  return { ratio: Math.round(((Math.max(L1,L2)+0.05)/(Math.min(L1,L2)+0.05))*100)/100,
                           fg: cs.color, bg: cs.backgroundColor };
                }""",
                ".dsapp-target-select .selectize-input")
            chk("★★ [%s] 「分析环境」字色对比度 %.2f:1 ≥ 4.5（item 10 的原话）"
                % (sk, c["ratio"]), c["ratio"] >= 4.5,
                "字 %s 底 %s" % (c["fg"], c["bg"]))

        # 2b) 整页扫一遍 —— 这一条才是"自适应"的正题
        scan = pg.evaluate(SCAN_JS)
        # 只报"确实看不见"的（<3.0）。3.0~4.5 之间多半是 .text-muted 这类
        # 次要文字，WCAG 对大字号/次要信息本来就有放宽，一律卡 4.5 会把
        # 这个测试变成噪音源，吵到没人看。
        blind = [x for x in scan["bad"] if x["ratio"] < 3.0]
        chk("★ [%s] 言出法随页没有看不见的字（扫了 %d 个元素）"
            % (sk, scan["n"]), not blind,
            "; ".join("%s.%s「%s」%.2f:1" % (x["tag"], x["cls"], x["text"], x["ratio"])
                      for x in blind[:5]))
        if scan["worst"]:
            print("     最低的几处：" + ", ".join(
                "%s「%s」%.2f" % (x["cls"] or x["tag"], x["text"], x["ratio"])
                for x in scan["worst"][:3]))

        # 2c) 下拉展开之后也要看得清（选中项和下拉项是两套元素，
        #     只治一个是 V8 那次的教训）
        pg.locator(".dsapp-target-select .selectize-input").first.click()
        pg.wait_for_timeout(600)
        drop = pg.evaluate("""() => {
          const d = document.querySelector('.dsapp-target-select .selectize-dropdown');
          if (!d) return null;
          const cs = getComputedStyle(d);
          return { display: cs.display, color: cs.color, bg: cs.backgroundColor,
                   n: d.querySelectorAll('.option').length };
        }""")
        if drop and drop["n"] > 0:
            c = pg.evaluate(
                """(sel) => {
                  const el = document.querySelector(sel);
                  const cs = getComputedStyle(el);
                  const parse = (c) => {
                    const m = c.match(/rgba?\\(([^)]+)\\)/);
                    if (!m) return null;
                    const p = m[1].split(',').map(x => parseFloat(x));
                    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
                  };
                  const over = (f, b) => ({ r: f.r*f.a + b.r*(1-f.a),
                                            g: f.g*f.a + b.g*(1-f.a),
                                            b: f.b*f.a + b.b*(1-f.a) });
                  const lum = (c) => { const f = (v) => { v /= 255;
                    return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); };
                    return 0.2126*f(c.r) + 0.7152*f(c.g) + 0.0722*f(c.b); };
                  let bg = parse(cs.backgroundColor), node = el;
                  while ((!bg || bg.a === 0) && node.parentElement) {
                    node = node.parentElement;
                    bg = parse(getComputedStyle(node).backgroundColor);
                  }
                  if (!bg) bg = { r: 255, g: 255, b: 255, a: 1 };
                  const fg = parse(cs.color);
                  const base = bg.a < 1 ? over(bg, { r: 255, g: 255, b: 255 }) : bg;
                  const f2 = fg.a < 1 ? over(fg, base) : fg;
                  const L1 = lum(f2), L2 = lum(base);
                  return { ratio: Math.round(((Math.max(L1,L2)+0.05)/(Math.min(L1,L2)+0.05))*100)/100,
                           fg: cs.color, bg: cs.backgroundColor };
                }""",
                ".dsapp-target-select .selectize-dropdown .option")
            chk("★ [%s] 下拉项字色对比度 %.2f:1 ≥ 4.5" % (sk, c["ratio"]),
                c["ratio"] >= 4.5, "字 %s 底 %s" % (c["fg"], c["bg"]))
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(300)

        pg.screenshot(path=os.path.join(OUT, "v9_skin_%s.png" % sk))

    # =====================================================================
    print("\n== 设置页也要扫一遍（那边控件最多）==")
    # =====================================================================
    # 用户说的是"不同风格皮肤请注意字体颜色的自适应"，不是"修好某一页"。
    # 设置页是控件密度最高的一页，最能暴露漏网的组合。
    for i, sk in enumerate(SKINS):
        pg.locator(".dsapp-rail-link", has_text="设置").first.click()
        pg.wait_for_timeout(1200)
        pg.locator('.dsapp-skinpick input[type="radio"]').nth(i).check(force=True)
        pg.wait_for_timeout(500)
        scan = pg.evaluate(SCAN_JS)
        blind = [x for x in scan["bad"] if x["ratio"] < 3.0]
        chk("★ [%s] 设置页没有看不见的字（扫了 %d 个元素）" % (sk, scan["n"]),
            not blind,
            "; ".join("%s.%s「%s」%.2f:1" % (x["tag"], x["cls"], x["text"], x["ratio"])
                      for x in blind[:5]))
        pg.screenshot(path=os.path.join(OUT, "v9_settings_%s.png" % sk))

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
