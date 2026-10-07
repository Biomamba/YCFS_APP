# -*- coding: utf-8 -*-
"""浏览器端冒烟（V6）：把「用户在页面上看得见的东西」逐条查一遍。

    python3 tests/ui_smoke.py [http://127.0.0.1:8898/]

为什么要有这一层：selftest.R 查的是**源码和服务端行为**，查不到"页面上到底
长什么样"。栽过两次，都是只查源码时全程绿的：

  · 2026-09-14 导航栏"固定"：CSS 里 `position: sticky` 写得好好的，selftest
    也断言了，但真浏览器里算出来是 relative —— app.css 排在 Bootstrap
    前面，同样特异性的 `.navbar{position:relative}` 后到，把 sticky 盖掉了。
  · 2026-09-14 注册/登录页白屏：页脚函数 dsapp_footer_ui 被放进了 app.R，
    而 app.R 的顶层**不在 globalenv 里**（Shiny 给它套了一层），R/mod_welcome.R
    里的调用方够不着它。主界面完全正常，**只有没登录的人看到白屏**。
    源码级断言全绿 —— 因为两边的源码都"写对了"。

这个脚本依赖 playwright（本机在 miniconda3 的 python3.9 里），线上没有也
不需要，所以 deploy.sh 把它连同 tests/ 一起排除在同步之外。

⚠️ 它会**真的注册一个账号**，所以必须指向一个可丢弃的实例。默认端口 8898
   是留给它的（用一份代码副本 + 独立 DSAPP_DATA_ROOT 起，见文件末尾说明）。
   别对着线上那台跑 —— 会往真库里塞一个测试账号。
"""
import sys
from playwright.sync_api import sync_playwright

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8898/"
OUT = "/tmp/dsapp_ui"
ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


def rail(pg, title):
    """按左侧栏的文本切页（不用 role，见文件头说明）"""
    pg.locator(".dsapp-rail-link", has_text=title).first.click()
    pg.wait_for_timeout(2200)


with sync_playwright() as p:
    b = p.chromium.launch()
    # ⚠️ 视口刻意压矮（900 → 620）：item 5 要验的是"左栏里那格自己滚"，
    #    而内容不够高时它压根不溢出，scrollHeight == clientHeight，
    #    断言会**因为没得滚而假绿**。620 是照着 1366x768 的笔记本取的。
    pg = b.new_page(viewport={"width": 1440, "height": 620})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    body0 = pg.inner_text("body")

    # =====================================================================
    # item 3：登录系统 —— 先注册一个账号（空库必然落在注册页）
    # =====================================================================
    chk("item3 空库落在**注册**页（不是登录页，否则新部署没人进得去）",
        "创建你的账号" in body0, body0[:200].replace("\n", " "))

    # 页脚在两个入口页上都要在 —— 没进门的人恰恰最需要客服微信
    chk("item7 注册页上就有版本号 V_6.0.0", "V_6.0.0" in body0)
    chk("item7 注册页上就有客服微信号", "Biomamba_zhushou" in body0)

    import random
    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "uitest_%s@example.com" % tag
    pw = "Test-%s-pw" % tag

    pg.fill("#welcome-nickname", "冒烟测试")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000000")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(6000)

    # 注册之后**还有一步**：恢复码展示页（"只显示这一次"），要显式确认。
    # 这说明前面那段白屏 bug 修好之后，这条链是能一路走到底的。
    if pg.locator("#welcome-enter_app").count() > 0:
        code_txt = pg.inner_text("body")
        # ⚠️ 长度是 **48**，不是 40：恢复码来自 dsapp_token(24) —— 24 字节
        #    过一遍 paste0("%02x") 出来是 48 个十六进制字符。这里原先写 40，
        #    页面明明显示了恢复码却报红。**改的是断言，不是代码。**
        chk("item3 注册后给出恢复码（换电脑靠它找回账号）",
            len([w for w in code_txt.split() if len(w) == 48 and
                 all(c in "0123456789abcdef" for c in w)]) > 0,
            code_txt[:200].replace("\n", " "))
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(6000)

    body1 = pg.inner_text("body")
    logged_in = pg.locator(".dsapp-shell").count() > 0
    chk("item3 注册后真的进到主界面（不是弹回登录页）", logged_in,
        body1[:200].replace("\n", " "))

    if not logged_in:
        # 进不去就没有后面可测的了，把现场留下来
        pg.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        print("\n注册没能进主界面，后面的检查全部跳过。页面文字：\n" + body1[:800])
        b.close()
        sys.exit(1)

    # =====================================================================
    # item 3（续）：换一个干净的浏览器上下文**用邮箱+密码登录**一次。
    # 注册能进不代表登录能进 —— 两条路走的服务端代码不一样，用户说的
    # "保证可以登入"指的是这条。
    # =====================================================================
    ctx2 = b.new_context(viewport={"width": 1440, "height": 620})
    pg2 = ctx2.new_page()
    pg2.goto(URL + "?login=1", wait_until="domcontentloaded")
    pg2.wait_for_selector(".dsapp-auth", timeout=30000)
    pg2.wait_for_timeout(2500)
    t2 = pg2.inner_text("body")
    chk("item3 干净浏览器打开是**登录**页（auth_mode 默认 login）",
        "登录到 Biomamba" in t2 or "邮箱" in t2, t2[:200].replace("\n", " "))
    pg2.fill("#welcome-login_email", email)
    pg2.fill("#welcome-login_password", pw)
    pg2.click("#welcome-do_login")
    pg2.wait_for_timeout(6000)
    chk("item3 ★ 用邮箱+密码能从登录页进主界面",
        pg2.locator(".dsapp-shell").count() > 0,
        pg2.inner_text("body")[:200].replace("\n", " "))
    pg2.screenshot(path=OUT + "/01_login_ok.png")
    ctx2.close()

    # =====================================================================
    # item 2：codex 风格（深色）
    # =====================================================================
    theme = pg.evaluate("""() => {
      const cs = getComputedStyle(document.body);
      return { bg: cs.backgroundColor, fg: cs.color,
               shell: !!document.querySelector('.dsapp-shell'),
               rail: !!document.querySelector('.dsapp-rail') };
    }""")
    chk("item2 深色底（body 背景是暗的）",
        theme["bg"] and theme["bg"] not in ("rgb(255, 255, 255)", "rgba(0, 0, 0, 0)"),
        theme)
    chk("item2 外壳是两栏（.dsapp-shell + .dsapp-rail 都在）",
        theme["shell"] and theme["rail"], theme)

    # 等宽字体：codex 那套的观感基础
    mono = pg.evaluate("""() => {
      const e = document.querySelector('.dsapp-rail, .dsapp-main');
      return e ? getComputedStyle(e).fontFamily : '';
    }""")
    chk("item2 字体栈里带了等宽/系统中文字体", "mono" in mono or "YaHei" in mono or
        "PingFang" in mono, mono)

    # =====================================================================
    # item 5：左栏里模型那一格**自己一条滚动条**
    # =====================================================================
    geo = pg.evaluate("""() => {
      const q = s => document.querySelector(s);
      const m = q('.dsapp-rail-model'), r = q('.dsapp-rail'),
            sh = q('.dsapp-shell'), mb = q('.dsapp-main-body');
      if (!m || !r) return null;
      return {
        mOverflowY: getComputedStyle(m).overflowY,
        mScrollH: m.scrollHeight, mClientH: m.clientHeight,
        rScrollH: r.scrollHeight, rClientH: r.clientHeight,
        rOverflowY: getComputedStyle(r).overflowY,
        shScrollH: sh.scrollHeight, shClientH: sh.clientHeight,
        mbOverflowY: mb ? getComputedStyle(mb).overflowY : '',
        mbScrollH: mb ? mb.scrollHeight : 0,
        mbClientH: mb ? mb.clientHeight : 0,
      };
    }""")
    chk("item5 抠到了左栏和模型格（抠不到下面全是假绿）", geo is not None)

    if geo:
        chk("item5 模型格 overflow-y 是 auto/scroll（它才是滚动容器）",
            geo["mOverflowY"] in ("auto", "scroll"), geo["mOverflowY"])
        chk("item5 ★ 模型格的内容**真的溢出了**（否则下面那条是假绿）",
            geo["mScrollH"] > geo["mClientH"] + 4,
            "scrollH=%s clientH=%s" % (geo["mScrollH"], geo["mClientH"]))
        chk("item5 ★ 整条左栏**不**自己滚（scrollHeight 不超出 clientHeight）",
            geo["rScrollH"] <= geo["rClientH"] + 4,
            "scrollH=%s clientH=%s" % (geo["rScrollH"], geo["rClientH"]))

        # 行为验证：在模型格里滚，主区不能跟着动 —— 这才是用户那句
        # 「不要整个界面一个下滑块」的真正含义。
        moved = pg.evaluate("""() => {
          const m = document.querySelector('.dsapp-rail-model');
          const mb = document.querySelector('.dsapp-main-body');
          const before = { m: m.scrollTop, mb: mb ? mb.scrollTop : -1,
                           win: window.scrollY };
          m.scrollTop = 120;
          return { after_m: m.scrollTop, before_m: before.m,
                   before_mb: before.mb, after_mb: mb ? mb.scrollTop : -1,
                   before_win: before.win, after_win: window.scrollY };
        }""")
        chk("item5 ★ 模型格滚得动（scrollTop 真的变了）",
            moved["after_m"] > moved["before_m"] + 10, moved)
        chk("item5 ★ 滚模型格时主区纹丝不动（两条滚动条互不影响）",
            moved["after_mb"] == moved["before_mb"] and
            moved["after_win"] == moved["before_win"], moved)
        pg.evaluate("() => { document.querySelector('.dsapp-rail-model').scrollTop = 0; }")

    # 整页不许出现"一个下滑块"：文档本身不能滚
    doc = pg.evaluate("""() => ({ h: document.documentElement.scrollHeight,
                                  c: document.documentElement.clientHeight })""")
    chk("item5 ★ 整个页面没有通到底的那一条滚动条",
        doc["h"] <= doc["c"] + 4, doc)

    pg.screenshot(path=OUT + "/02_chat.png")

    # =====================================================================
    # item 4：管理页（第一个注册的账号就是管理员）
    # =====================================================================
    nav_txt = " ".join(pg.locator(".dsapp-rail-link").all_inner_texts())
    chk("item4 第一个账号是管理员，左栏多出「管理」", "管理" in nav_txt, nav_txt)

    # ⚠️ 切页之后要等**内容真的进来**。这一页绝大多数卡片是 uiOutput /
    #    renderUI 出来的，点完立刻 inner_text 只会拿到空壳 —— 而"抠不到"
    #    在下面的断言里表现为"缺内容"，方向就偏了（会让人去改管理页，
    #    实际是测试读得太早）。等一个只可能在渲染完之后才出现的文本。
    rail(pg, "管理")
    try:
        pg.wait_for_function(
            "() => document.body.innerText.includes('各用户的任务运行情况')",
            timeout=20000)
    except Exception:
        pass
    pg.wait_for_timeout(800)
    admin_txt = pg.inner_text("body")
    chk("item4 管理页打得开", len(admin_txt) > 100)

    # 用户原话里的三件事，逐条按**名字**验，不用"沾边就算"的关键词海。
    # 关键词海的问题是：卡片少了一半它照样绿。
    chk("item4 ① 各用户的任务运行情况", "各用户的任务运行情况" in admin_txt,
        admin_txt[:300].replace("\n", " "))
    chk("item4 ② 账密修改（用户表 + 停用/重置入口）",
        "用户" in admin_txt and
        any(k in admin_txt for k in ("停用", "重置", "删除账号")),
        admin_txt[:300].replace("\n", " "))
    chk("item4 ③ 硬件资源分配（配额 / 资源上限按钮）",
        "设置配额" in admin_txt and "资源上限" in admin_txt,
        admin_txt[:300].replace("\n", " "))
    pg.screenshot(path=OUT + "/03_admin.png", full_page=True)

    # =====================================================================
    # item 7：页脚 —— 每个页面上都在，且固定在底部
    # =====================================================================
    fpos = pg.eval_on_selector_all(
        ".dsapp-footer", "es => es.map(e => getComputedStyle(e).position).join(',')")
    chk("item7 登录后的页脚仍然固定在底部", "fixed" in fpos, fpos or "(没有)")

    # =====================================================================
    # 其余页签打得开 + 每个页面都有页脚
    # =====================================================================
    for name in ("任务", "文件", "环境", "设置"):
        rail(pg, name)
        pg.screenshot(path=OUT + "/04_%s.png" % name, full_page=True)
        t = pg.inner_text("body")
        chk("页签「%s」打得开" % name, len(t) > 50)
        chk("item7 「%s」页上页脚还在（版本号+微信）" % name,
            "V_6.0.0" in t and "Biomamba_zhushou" in t, t[-200:].replace("\n", " "))

    # ---- app.css / codex.css 里有没有**真的**被 Bootstrap 盖掉的声明 --------
    #
    # 这条检查问的是："同名选择器 + 同属性 + 不同值"时，浏览器最后听谁的。
    # 答：选择器文本一样 → 特异性一样 → **只看谁在 <head> 里靠后**。
    #
    # ⚠️⚠️ 所以必须**先量出每张表的真实下标**，不能靠印象。2026-09-14 这里
    #     误报过，根因就是印象错了：www/app.css 里那段 nav.navbar 的注释写着
    #     "Bootstrap 排在 app.css 后面"—— 那是 V6 之前的情形（主题挂在
    #     dsapp_main_ui() 里，等 renderUI 才插进 <head>）。V6 把主题提到了
    #     顶层 tags$head（app.R 里 bs_theme_dependencies 那一段），顺序反了
    #     过来。实测（同一次会话里量 document.styleSheets）：
    #         [2] bootstrap.min.css  [3] app.css  [4] codex.css
    #     **我们在后面，是我们赢** —— 检查器却照旧前提把 codex.css 的
    #     .page-link 报成"被 Bootstrap 盖掉"，连续红了两轮。
    #
    #     这条同时说明：**"源码里写了"和"浏览器里生效"是两件事**，而
    #     "哪张表靠后"同样是件要量的事，不是读一眼 <head> 就能断言的。
    hits = pg.evaluate("""() => {
      const idx = {};
      for (let i = 0; i < document.styleSheets.length; i++) {
        const h = (document.styleSheets[i].href || '');
        for (const f of ['bootstrap.min.css', 'app.css', 'codex.css'])
          if (h.includes(f) && !(f in idx)) idx[f] = i;
      }
      const grab = (frag) => {
        const m = {};
        for (const s of document.styleSheets) {
          if (!(s.href||'').includes(frag)) continue;
          let rules; try { rules = s.cssRules; } catch(e) { continue; }
          for (const r of rules) {
            if (!r.selectorText || !r.style) continue;
            for (const sel of r.selectorText.split(',')) {
              const k = sel.trim();
              m[k] = m[k] || {};
              for (const prop of r.style) {
                // ⚠️ 空值必须跳过，否则又是假阳性：`background: var(--x)`
                //    这种简写会在 r.style 里展开出一堆长写属性名，没显式写过
                //    的那些取出来是空串。于是 codex.css 的简写 background 撞上
                //    Bootstrap 的 background-color 时，会被报成"值不一样" ——
                //    实际简写生效，两条都不算冲突。
                const v = r.style.getPropertyValue(prop);
                if (!v) continue;
                m[k][prop] = v +
                  (r.style.getPropertyPriority(prop) ? ' !important' : '');
              }
            }
          }
        }
        return m;
      };
      const bs = grab('bootstrap.min.css');
      const out = [];
      for (const frag of ['app.css', 'codex.css']) {
        // 我们排在 Bootstrap 后面 → 同特异性下我们赢，不存在"被盖掉"。
        if (!(frag in idx) || !('bootstrap.min.css' in idx) ||
            idx[frag] > idx['bootstrap.min.css']) continue;
        const own = grab(frag);
        for (const sel in own) {
          if (!bs[sel]) continue;
          for (const prop in own[sel])
            if (prop in bs[sel] && bs[sel][prop] !== own[sel][prop])
              out.push(frag + ': ' + sel + ' {' + prop + ': ' + own[sel][prop] +
                       '}  被 Bootstrap 的 ' + bs[sel][prop] + ' 盖掉');
        }
      }
      return { hits: out, idx: idx };
    }""")
    chk("app.css / codex.css 里没有被 Bootstrap 盖掉的声明",
        not hits["hits"],
        " / ".join(hits["hits"][:4]) + "   (表序 %s)" % hits["idx"])
    # 顺便把"顺序"本身钉住 —— 上面那条一旦因为顺序反转而静默失效，
    # 这里是唯一会出声的地方。
    order = hits["idx"]
    chk("★ 样式表顺序仍是 Bootstrap 在前、app.css/codex.css 在后（上面那条的前提）",
        all(k in order for k in ("bootstrap.min.css", "app.css", "codex.css")) and
        order["app.css"] > order["bootstrap.min.css"] and
        order["codex.css"] > order["bootstrap.min.css"], order)

    chk("没有 JS 运行时错误", not errs, " | ".join(errs[:3]))
    b.close()

print("\n" + ("全部通过" if ok_all else "有失败项"), flush=True)
sys.exit(0 if ok_all else 1)
