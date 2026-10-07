# -*- coding: utf-8 -*-
"""V10 item 3：平台 logo（登录页 / 左栏 / 浏览器标签页），比例自适应。

对着一次性实例（8898）跑。

★ 这一版的判据必须是**图真的加载出来了**（naturalWidth > 0），不是
  "HTML 里有个 <img>"。踩过的形态：URL 里的中文文件名没编码 → 404 →
  浏览器画一个破图标 → DOM 里 <img> 照样在、src 照样是对的字符串。
  离线断言一条都不会红。

★ 比例自适应也是量出来的：拿界面上那个盒子的宽高比和图片**原始**宽高比
  比。相等 = 没被拉伸。（object-fit 那类属性只能说明"本该不变形"，
  说明不了"实际没变形"。）
"""
import io
import os
import random
import sys

from playwright.sync_api import sync_playwright

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v10")


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
LOGO_DIR = os.path.join(DATA_ROOT, "logo")
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


# 实例里到底有没有配 logo —— 没配的话下面的断言一条都不成立，
# 那种情况下**要明说**，不能静默跳过（静默跳过 = 看起来全绿）。
imgs = [f for f in os.listdir(LOGO_DIR)
        if os.path.splitext(f)[1].lower() in (".png", ".jpg", ".jpeg", ".svg",
                                              ".webp", ".gif")]
print("== 这个实例的 data/logo/ 里有 %d 张图：%s ==" % (len(imgs), imgs))
if not imgs:
    sys.exit("跳过：%s 里没有图片。先往那儿放一张再跑这个脚本 —— "
             "没有图的时候跑它，跑的全是「回落成图标」那条路。" % LOGO_DIR)


def probe(pg, sel):
    """量一个 logo 盒子：图片是否真的加载出来 + 盒子/原图的宽高比。"""
    return pg.evaluate("""(sel) => {
      const box = document.querySelector(sel);
      if (!box) return {found: false};
      const img = box.querySelector('img');
      if (!img) return {found: true, img: false, html: box.innerHTML.slice(0, 80)};
      const r = box.getBoundingClientRect();
      const ir = img.getBoundingClientRect();
      return {
        found: true, img: true,
        complete: img.complete, nw: img.naturalWidth, nh: img.naturalHeight,
        src: img.getAttribute('src'),
        boxW: Math.round(r.width * 10) / 10, boxH: Math.round(r.height * 10) / 10,
        imgW: Math.round(ir.width * 10) / 10, imgH: Math.round(ir.height * 10) / 10,
        bg: getComputedStyle(box).backgroundColor
      };
    }""", sel)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    # 记下所有失败的网络请求 —— 图片 404 就在这里现形
    bad = []
    pg.on("response", lambda r: bad.append("%d %s" % (r.status, r.url))
          if r.status >= 400 else None)

    # =====================================================================
    print("\n== 入口页（登录/注册）：品牌区那张图 ==")
    # =====================================================================
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)
    if pg.locator(".dsapp-shell").count():
        if pg.locator("#logout").count():
            pg.click("#logout")
            pg.wait_for_timeout(6000)
        pg.goto(URL + "?login=1", wait_until="domcontentloaded")
        pg.wait_for_timeout(2500)
    if pg.locator("#welcome-go_register").count() and \
       pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)

    a = probe(pg, ".dsapp-auth-logo")
    chk("★ 入口页的品牌位是个盒子", a.get("found") is True, a)
    chk("★★ 里面放的是真图（不是回落成 FontAwesome 图标）",
        a.get("img") is True, a)
    chk("★★ 图**真的加载出来了**（naturalWidth > 0）—— "
        "中文文件名没编码的话这里是 0，DOM 里却看不出任何异常",
        a.get("img") and a.get("complete") and a.get("nw", 0) > 0, a)
    chk("★ URL 里非 ASCII 已经百分号编码（裸着塞进 href 就是 404）",
        a.get("img") and a.get("src") and
        all(ord(c) < 128 for c in a["src"]), a.get("src"))

    if a.get("img") and a.get("nw"):
        orig = a["nw"] / float(a["nh"])
        shown = a["imgW"] / float(a["imgH"]) if a["imgH"] else 0
        chk("★★ 图**没有被拉伸**（原图 %d×%d = %.3f，屏幕上 %.0f×%.0f = %.3f）"
            % (a["nw"], a["nh"], orig, a["imgW"], a["imgH"], shown),
            abs(orig - shown) < 0.02, (orig, shown))
        chk("★ 图没有溢出盒子（max-width/height:100%% 那两条在起作用）",
            a["imgW"] <= a["boxW"] + 1 and a["imgH"] <= a["boxH"] + 1, a)
        chk("★ 图也没有小得看不见（盒子填得差不多了）",
            max(a["imgW"] / a["boxW"], a["imgH"] / a["boxH"]) > 0.55, a)
        chk("★★ 有真图时去掉了那层「深色底 + 白图标」的徽章底色",
            a["bg"] in ("rgba(0, 0, 0, 0)", "transparent"), a["bg"])
        # ⚠️ 探针必须挂在 **.dsapp-auth 里面**。那个底色是
        #    `background: var(--auth-btn)`，而 --auth-btn 定义在 .dsapp-auth
        #    作用域下 —— 挂到 document.body 上变量取不到，计算值退化成
        #    transparent，这条断言就永远是红的，而 CSS 一点问题都没有。
        chk("★★ 那层底色**没有**被顺手删掉（没图时要回落成图标，还得靠它）",
            pg.evaluate("""() => {
              const host = document.querySelector('.dsapp-auth-brand')
                        || document.querySelector('.dsapp-auth');
              if (!host) return 'no-host';
              const el = document.createElement('div');
              el.className = 'dsapp-auth-logo';   // 注意：**不带** is-img
              host.appendChild(el);
              const bg = getComputedStyle(el).backgroundColor;
              el.remove();
              return bg;
            }""") not in ("rgba(0, 0, 0, 0)", "transparent", "no-host"))

    pg.screenshot(path=os.path.join(OUT, "v10_logo_auth.png"))

    # =====================================================================
    print("\n== 浏览器标签页图标 ==")
    # =====================================================================
    href = pg.evaluate("""() => {
      const l = document.querySelector('link[rel~="icon"]');
      return l ? l.getAttribute('href') : null;
    }""")
    chk("★★ 有 <link rel=icon>（没有它，标签页上是浏览器默认的那个地球）",
        bool(href), href)
    if href:
        chk("★ favicon 指向的是 logo 那一路（不是空 href）",
            href.startswith("dsapplogo/"), href)

    # =====================================================================
    print("\n== 主界面左栏：品牌位那张小图 ==")
    # =====================================================================
    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v10logo_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0 and \
       pg.locator("#welcome-go_register").count():
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "Logo测试")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000007")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    # ⚠️ V9 item 1 起这一勾是**必须**的：服务端不勾就拒绝注册。漏掉它的表现
    #    不是"注册报错"，而是**注册没发生** —— 脚本继续往下跑，30 秒后在
    #    一个毫不相干的点击上超时，报出来的方向完全是错的。
    pg.check(".dsapp-auth input[type=checkbox]")
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count():
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    try:
        pg.wait_for_selector(".dsapp-shell", timeout=30000)
        shell_ok = True
    except Exception:
        shell_ok = False
    chk("★ 注册进到主界面（否则下面量不到左栏）", shell_ok,
        pg.inner_text("body")[:200].replace("\n", " "))

    r = probe(pg, ".dsapp-rail-logo")
    chk("★★ 左栏品牌位里也是真图，而且真的加载出来了",
        r.get("img") is True and r.get("nw", 0) > 0, r)
    if r.get("img") and r.get("nw"):
        orig = r["nw"] / float(r["nh"])
        shown = r["imgW"] / float(r["imgH"]) if r["imgH"] else 0
        chk("★★ 左栏这张也没被拉伸（原 %.3f / 屏幕 %.3f）" % (orig, shown),
            abs(orig - shown) < 0.02, (orig, shown))
        chk("★ 左栏这张塞得进 28px 的盒子",
            r["imgW"] <= r["boxW"] + 1 and r["imgH"] <= r["boxH"] + 1, r)
        chk("★ 左栏那层底色也去掉了", r["bg"] in ("rgba(0, 0, 0, 0)",
                                                  "transparent"), r["bg"])
        # 品牌名还在旁边 —— 加了图不能把文字挤掉
        chk("★ 「Biomamba」那行字还在（加图不该挤掉品牌名）",
            "Biomamba" in pg.inner_text(".dsapp-rail-brand"),
            pg.inner_text(".dsapp-rail-brand").replace("\n", " "))

    pg.screenshot(path=os.path.join(OUT, "v10_logo_rail.png"))

    chk("★★ 没有 4xx/5xx 的请求（图片 404 会出现在这里）",
        len(bad) == 0, bad[:5])
    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
