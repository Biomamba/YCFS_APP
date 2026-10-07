# -*- coding: utf-8 -*-
"""V8 item 4（皮肤）+ item 2（绿底灰字）的浏览器验证。

对着一次性实例（8898）跑。会真的注册账号、真的改皮肤设置。

为什么这个脚本值得单独存在：皮肤这种东西"看着对"和"真的对"差得很远。
换错一个变量，界面**不会报错**，只会某一处字变成看不见的颜色 ——
而那正是 item 2 要来修的那类 bug（绿底灰字，谁都没报错）。
所以这里不检查"CSS 里有没有那个块"，而是**逐个皮肤量对比度**。
"""
import io
import os
import random
import sys

from playwright.sync_api import sync_playwright

# ---- 路径与**防误伤闸门**（同 tests/ui_v7/*.py，理由见那边的注释）---------
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v8")


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


# 取一个元素的**计算后**配色并算 WCAG 对比度。
#
# ⚠️ 必须用 getComputedStyle 而不是读 CSS 文本。皮肤那一层是靠 var() 一层层
#    解析下来的，读源码只能读到 `var(--dsapp-user-fg)` 这种没解析的字符串 ——
#    而 bug 恰恰藏在"这个 var 最终解析成了什么"里。
#
# ⚠️ 半透明色要合成到底色上再算。--bs-primary-bg-subtle 这类如果带 alpha，
#    直接拿 rgba 当不透明色算出来的对比度是假的（偏乐观）。
CONTRAST_JS = r"""
(sel) => {
  const el = document.querySelector(sel);
  if (!el) return null;
  const cs = getComputedStyle(el);
  const parse = (c) => {
    const m = c.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(x => parseFloat(x));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  // 往上找第一个不透明的背景当底
  let bg = parse(cs.backgroundColor);
  let node = el;
  while ((!bg || bg.a === 0) && node.parentElement) {
    node = node.parentElement;
    bg = parse(getComputedStyle(node).backgroundColor);
  }
  if (!bg) bg = { r: 255, g: 255, b: 255, a: 1 };
  const fg = parse(cs.color);
  if (!fg) return null;
  // 把半透明的字色/底色合成到实际底色上
  const over = (f, b) => ({
    r: f.r * f.a + b.r * (1 - f.a),
    g: f.g * f.a + b.g * (1 - f.a),
    b: f.b * f.a + b.b * (1 - f.a)
  });
  const base = bg.a < 1 ? over(bg, { r: 255, g: 255, b: 255 }) : bg;
  const f2 = fg.a < 1 ? over(fg, base) : fg;
  const lum = (c) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); };
    return 0.2126*f(c.r) + 0.7152*f(c.g) + 0.0722*f(c.b);
  };
  const L1 = lum(f2), L2 = lum(base);
  const ratio = (Math.max(L1,L2) + 0.05) / (Math.min(L1,L2) + 0.05);
  return {
    ratio: Math.round(ratio * 100) / 100,
    fg: cs.color, bg: cs.backgroundColor,
    /* 底色的相对亮度。单看对比度分不出"深底浅字"和"浅底深字" ——
       而 item 2 的病根恰恰是底色是**浅色**（深色主题下没被翻过来的
       --bs-primary-bg-subtle），所以这个值要单独断言。 */
    bg_lum: Math.round(L2 * 1000) / 1000,
    skin: document.documentElement.getAttribute('data-skin')
  };
}
"""

SKINS = ["dark", "light", "chatgpt", "claude", "apple"]

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v8skin_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V8皮肤")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000002")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    chk("注册进到主界面", pg.locator(".dsapp-shell").count() > 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    # =====================================================================
    print("\n== 首屏：内联脚本必须先把 data-skin 定下来 ==")
    # =====================================================================
    first = pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
    chk("★ <html> 上有 data-skin（首帧就有，不等 websocket）",
        first in SKINS, first)

    # =====================================================================
    print("\n== item 4：设置页的皮肤选择卡 ==")
    # =====================================================================
    pg.locator(".dsapp-rail-link", has_text="设置").first.click()
    pg.wait_for_timeout(2500)
    cards = pg.locator(".dsapp-skinpick label.radio-inline")
    chk("★ 选择卡渲染出来了（%d 张）" % cards.count(), cards.count() == len(SKINS),
        "实际 %d 张" % cards.count())
    names = [pg.locator(".dsapp-skinpick .dsapp-skin-name").nth(i).inner_text()
             for i in range(cards.count())]
    chk("★ 明亮和黑暗都在（用户说这两个必须要有）",
        "深色" in names and "明亮" in names, names)
    chk("★ ChatGPT / Claude / Apple 也在",
        all(x in names for x in ["ChatGPT", "Claude", "Apple"]), names)
    # 色块必须画出来了 —— 卡片上没有色块的话，用户是盲选
    chips = pg.evaluate(
        "() => document.querySelectorAll('.dsapp-skinpick .dsapp-skin-chips i').length")
    chk("每张卡都有 4 个预览色块（共 %d 个）" % chips,
        chips == len(SKINS) * 4, chips)
    # 键盘可达：原生 radio 藏起来但不能藏成 display:none
    chk("★ 原生 radio 用 opacity 隐藏、但没被 display:none 干掉（否则键盘用不了）",
        pg.evaluate("""() => {
          const i = document.querySelector('.dsapp-skinpick input[type="radio"]');
          if (!i) return 'nope';
          const cs = getComputedStyle(i);
          return cs.display !== 'none' && cs.opacity === '0';
        }""") is True)

    # =====================================================================
    print("\n== item 4：逐个皮肤切过去，量对比度 ==")
    # =====================================================================
    # 先在对话页发一条消息，好让用户气泡真的存在 ——
    # item 2 要修的就是那个气泡，没有气泡就量不到东西。
    #
    # ⚠️ 顺序不能省：**先填一把（假的）API Key**。mod_chat.R:416 有一条闸门
    #    `if (!nzchar(state$api_key)) { dsapp_prompt_settings(); return() }` ——
    #    没有 Key 时它会在**写库之前**就返回，用户消息压根不会落库、更不会
    #    渲染。那样这一整组对比度检查会全部跳过，而"跳过"看起来和"通过"
    #    一模一样（第一版就是这么骗过自己的）。
    #    Key 是假的没关系：这组检查量的是**用户自己发的那条消息**的配色，
    #    它渲染在调用模型之前；后面模型报错弹一个错误气泡，不影响。
    pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
    pg.wait_for_timeout(1500)
    if pg.locator(".dsapp-rail-model #model-api_key").count():
        pg.fill(".dsapp-rail-model #model-api_key", "sk-fake-only-for-layout")
        pg.locator(".dsapp-rail-model #model-commit").click()
        pg.wait_for_timeout(3000)

    # ⚠️ 量气泡必须**站在对话页**量。bslib 的 navset_hidden 是把没选中的
    #    页留在 DOM 里、只让 Shiny **挂起**它们的输出（不是"从 DOM 里摘掉"：
    #    静态元素其实还在）。所以不站过去也不一定拿到 null —— 但拿到的是
    #    **没被服务端更新过的**那份，量出来的颜色是旧的，比 null 更坑。
    #    总之：要量哪个页，就先切到哪个页。
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(3000)
    ta = pg.locator(".dsapp-composer textarea").first
    if ta.count():
        ta.fill("皮肤对比度测试")
        # fill 之后要等一下：Shiny 的 textAreaInput 是防抖上报的，
        # 紧接着按回车时服务端那边 input$input 可能还是空的，
        # 于是 dsapp_chat_send 里的 `if (!nzchar(txt)) return()` 直接吞掉。
        pg.wait_for_timeout(900)
        pg.keyboard.press("Enter")
        pg.wait_for_timeout(4000)
    chk("★★ 对话页上真的有了一条用户消息（否则下面量不到东西）",
        pg.locator(".dsapp-msg-user .dsapp-bubble").count() > 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    for i, sk in enumerate(SKINS):
        # 1) 回设置页点卡片
        pg.locator(".dsapp-rail-link", has_text="设置").first.click()
        pg.wait_for_timeout(1200)
        pg.locator('.dsapp-skinpick input[type="radio"]').nth(i).check(force=True)
        # 400ms 是刻意**紧**的超时：这一条要验证的是"点了立刻生效"。
        # 之前选择卡挂在 app_root 上时整屏会重渲，这里得等好几秒才追上 ——
        # 把等待拉长会把这个 bug 一起藏起来，所以宁可让它红。
        pg.wait_for_timeout(400)
        got = pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
        chk("点「%s」→ 400ms 内 data-skin=%s（不用刷新）" % (sk, sk), got == sk, got)

        # 2) 到对话页量。
        #    顺带验证"切页不丢" —— 这两件事合用一次跳转，但**分别断言**：
        #    合成一条的话，皮肤没生效时会被误报成"切页丢了"。
        pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
        pg.wait_for_timeout(1200)
        chk("★ [%s] 切页后皮肤没丢" % sk,
            pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
            == sk)
        c = pg.evaluate(CONTRAST_JS, ".dsapp-msg-user .dsapp-bubble")
        if c is None:
            chk("★ [%s] 用户气泡量得到" % sk, False, "选择器没命中")
        else:
            chk("★ [%s] 用户气泡对比度 %.2f:1 ≥ 4.5（item 2）" % (sk, c["ratio"]),
                c["ratio"] >= 4.5, "%s on %s" % (c["fg"], c["bg"]))
            # 光看对比度不够：白底黑字对比度也很高。item 2 的病根是
            # **底色是浅色**（--bs-primary-bg-subtle 在深色主题下没翻过来），
            # 所以底色必须也是暗的。
            chk("★ [%s] 用户气泡底色偏暗（item 2 的病根：浅绿底）" % sk,
                c["bg_lum"] < 0.5, c["bg"])
        # 输入框的字也要看得清
        c3 = pg.evaluate(CONTRAST_JS, ".dsapp-composer textarea")
        if c3 is not None:
            chk("★ [%s] 输入框对比度 %.2f:1 ≥ 4.5（item 2 的另一种读法）"
                % (sk, c3["ratio"]), c3["ratio"] >= 4.5,
                "%s on %s" % (c3["fg"], c3["bg"]))

        # 主按钮（发送）。和用户气泡是**同一个坑的另一处**：底色取的是
        # --bs-primary，字色取的是 --dsapp-on-primary，两个都按皮肤换。
        # 只量气泡的话，"按钮上白字看不清"会漏过去（claude 皮肤第一版
        # 就是这样：气泡修好了，主按钮还是 4.23:1）。
        c4 = pg.evaluate(CONTRAST_JS, ".dsapp-composer .btn-primary")
        if c4 is not None:
            chk("★ [%s] 主按钮对比度 %.2f:1 ≥ 4.5" % (sk, c4["ratio"]),
                c4["ratio"] >= 4.5, "%s on %s" % (c4["fg"], c4["bg"]))

        c2 = pg.evaluate(CONTRAST_JS, "body")
        chk("★ [%s] 正文对比度 %.2f:1 ≥ 4.5" % (sk, c2["ratio"]),
            c2["ratio"] >= 4.5, "%s on %s" % (c2["fg"], c2["bg"]))

        pg.screenshot(path=os.path.join(OUT, "skin_%s.png" % sk))

    # 上面那一圈跑完，最后一个点的是 apple。
    LAST = SKINS[-1]

    # =====================================================================
    print("\n== item 4：刷新之后还是它（localStorage 那条路）==")
    # =====================================================================
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(3000)
    after = pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
    chk("★★ 刷新后仍是 %s（首屏内联脚本读到了 localStorage）" % LAST,
        after == LAST, after)
    chk("localStorage 里存了 %s" % LAST,
        pg.evaluate("() => localStorage.getItem('dsapp_skin')") == LAST)

    # =====================================================================
    print("\n== item 4：换台机器也还是它（服务端那条路）==")
    # =====================================================================
    # 这一段才是"按账号记住"的正题。上面那条只证明了 localStorage 记得住 ——
    # 那是**这台浏览器**的事。清掉 localStorage（模拟换一台电脑 / 换浏览器），
    # 服务端必须把它推回来。
    #
    # ⚠️ 清 localStorage 要在**同一个 page** 上做，不能另开一个 context：
    #    新 context 没有登录 cookie，会落在登录页，而登录页根本不渲染主界面，
    #    data-skin 停在 'dark' —— 那样这条检查永远红，且红得没有意义。
    pg.evaluate("() => localStorage.removeItem('dsapp_skin')")
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(3500)
    after2 = pg.evaluate("() => document.documentElement.getAttribute('data-skin')")
    chk("★★ 清掉 localStorage 后仍是 %s（服务端把它推回来了）" % LAST,
        after2 == LAST, after2)
    chk("服务端这条消息也写回了 localStorage",
        pg.evaluate("() => localStorage.getItem('dsapp_skin')") == LAST)

    # =====================================================================
    print("\n== 收尾 ==")
    # =====================================================================
    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
