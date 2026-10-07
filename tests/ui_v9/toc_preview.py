# -*- coding: utf-8 -*-
"""V9 item 4（图片可点预览）+ item 9（对话侧栏二级目录定位跳转）。

对着一次性实例（8898）跑。会真的注册账号、真的发消息、真的往工作区写图。

★ 为什么不发消息让模型画图：那要真调 API（要钱、要几十秒、还可能因为
  网络失败），而这里要验的是**前端能不能点开预览**，和图画得好不好看无关。
  所以直接往那个对话的工作区目录里写 PNG —— 应用那边的产物扫描
  （reactivePoll，3 秒一轮）会自己发现它们。**不给应用加任何测试专用代码**：
  钩子一旦进了生产代码，它自己就会成为一条没人测的路径。
"""
import io
import os
import random
import struct
import sys
import zlib

from playwright.sync_api import sync_playwright

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


def write_png(path, w=320, h=240, rgb=(60, 140, 220)):
    """手写一个最小合法 PNG。

    不用 PIL：这台机器上有没有装是碰运气的事，而这个函数只有 15 行。
    """
    raw = b""
    for y in range(h):
        raw += b"\x00"                       # 每行的 filter 字节
        for x in range(w):
            # 画个渐变，别是纯色 —— 纯色图看不出"是不是同一张"
            raw += bytes(((rgb[0] + x) % 256, (rgb[1] + y) % 256, rgb[2]))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v9toc_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V9目录")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000004")
    pg.fill("#welcome-field", "单细胞转录组")
    pg.fill("#welcome-password", pw)
    # ⚠️ V9 item 1 之后这一勾是**必须**的：服务端不勾就拒绝注册（前端置灰只是
    #    提示，判据在服务端）。漏掉它的表现不是"注册报错"，而是**注册没发生**
    #    —— 脚本继续往下跑，30 秒后在一个毫不相干的点击上超时。
    pg.check(".dsapp-auth input[type=checkbox]")
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    try:
        pg.wait_for_selector(".dsapp-shell", timeout=30000)
        shell_ok = True
    except Exception:
        shell_ok = False
    chk("注册进到主界面", shell_ok, pg.inner_text("body")[:200].replace("\n", " "))

    pg.locator(".dsapp-rail-link", has_text="言出法随").first.click()
    pg.wait_for_timeout(1500)
    if pg.locator(".dsapp-rail-model #model-api_key").count():
        pg.fill(".dsapp-rail-model #model-api_key", "sk-fake-only-for-layout")
        pg.locator(".dsapp-rail-model #model-commit").click()
        pg.wait_for_timeout(3000)
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(3000)

    sid = pg.evaluate("""() => {
      const el = document.querySelector('.dsapp-sess.active');
      return el ? el.getAttribute('data-sid') : null;
    }""")
    chk("★ 拿到当前对话的 id（工作区是按它命名的）", bool(sid), sid)

    # =====================================================================
    print("\n== item 9：目录要三轮以上才出现 ==")
    # =====================================================================
    chk("★ 空对话里没有目录（少于 3 轮不显示）",
        pg.locator(".dsapp-toc").count() == 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    # ★ 每轮都写长一点。消息流那个容器有 max-height（约 538px），三条短消息
    #   根本撑不满 —— 撑不满就 scrollTop 恒为 0，"点了目录滚上去没有"这条
    #   断言会变成一句永远为真的废话（V9 第一版就是这么骗过自己的）。
    BODY = ("第 %d 轮：请你帮我看看这个数据集的质量。"
            "这批样本来自 %d 个批次，每个批次 3 到 5 个重复，"
            "我想先确认一下线粒体基因比例和核糖体基因比例是否在合理范围，"
            "然后再决定要不要做双细胞去除。麻烦你把判断依据也一起写出来。")
    ta = pg.locator(".dsapp-composer textarea").first
    if ta.count():
        for k in range(3):
            # 多写几行：气泡高一点，容器才真的溢出
            ta.fill("\n".join([BODY % (k + 1, k + 2)] * 4))
            pg.wait_for_timeout(900)
            pg.keyboard.press("Enter")
            pg.wait_for_timeout(6000)
    n_user = pg.locator(".dsapp-msg-user").count()
    chk("★ 发出去 3 条用户消息（实际 %d）" % n_user, n_user >= 3)

    geo = pg.evaluate("""() => {
      const c = document.querySelector('.dsapp-chat-scroll');
      if (!c) return null;
      return {sh: c.scrollHeight, ch: c.clientHeight};
    }""")
    chk("★★ 消息流真的溢出了（scrollHeight %s > clientHeight %s）—— 不溢出的话"
        "下面那条「滚上去了」是永远成立的废话"
        % (geo["sh"] if geo else "?", geo["ch"] if geo else "?"),
        bool(geo) and geo["sh"] > geo["ch"] + 20, geo)

    if n_user >= 3:
        toc = pg.locator(".dsapp-toc")
        chk("★ 有 3 轮之后目录出现了", toc.count() == 1, toc.count())
        items = pg.locator(".dsapp-toc-item")
        chk("★ 目录条数 = 轮数（%d 条 / %d 轮）" % (items.count(), n_user),
            items.count() == n_user, items.count())
        first = items.first.inner_text().replace("\n", " ")
        chk("★ 标签取的是**用户那句话**，不是模型的回答",
            "第 1 轮" in first, first)

        # 先把消息流滚到底，制造"我要回去找上面某一轮"的场景
        pg.evaluate("""() => {
          const c = document.querySelector('.dsapp-chat-scroll');
          if (c) c.scrollTop = c.scrollHeight;
        }""")
        pg.wait_for_timeout(800)
        before = pg.evaluate("""() => {
          const c = document.querySelector('.dsapp-chat-scroll');
          return c ? Math.round(c.scrollTop) : -1;
        }""")

        items.first.click()
        pg.wait_for_timeout(1800)          # smooth 滚动要走一会儿
        after = pg.evaluate("""() => {
          const c = document.querySelector('.dsapp-chat-scroll');
          return c ? Math.round(c.scrollTop) : -1;
        }""")
        chk("★★ 点目录第 1 条 → 消息流滚上去了（%s → %s）" % (before, after),
            after >= 0 and after < before, "scrollTop 没变小")

        vis = pg.evaluate("""() => {
          const c = document.querySelector('.dsapp-chat-scroll');
          const box = c.getBoundingClientRect();
          const a = document.querySelector('.dsapp-toc-item');
          const el = a ? document.getElementById(a.getAttribute('data-anchor')) : null;
          if (!el) return null;
          const r = el.getBoundingClientRect();
          // 最后一条用户消息现在应该已经被甩到视野**外面**了 —— 否则说明
          // 上面那句"滚上去了"只是容器没内容可滚
          const last = [].slice.call(document.querySelectorAll('.dsapp-msg-user')).pop();
          const lr = last ? last.getBoundingClientRect() : null;
          return {top: Math.round(r.top - box.top), id: el.id,
                  lastBottom: lr ? Math.round(lr.bottom - box.top) : null};
        }""")
        chk("★★ 目标那一轮停在视野内（相对滚动区顶部 %s px）"
            % (vis["top"] if vis else "?"),
            vis is not None and -20 <= vis["top"] <= 140, vis)
        chk("★★ 而且最后一条已经被甩到视野外了（%s px，容器高 %s）"
            % (vis["lastBottom"] if vis else "?",
               pg.evaluate("""() => document.querySelector('.dsapp-chat-scroll').clientHeight""")),
            vis is not None and vis["lastBottom"] is not None
            and vis["lastBottom"] > vis["top"] + 200, vis)

        chk("★ 跳过去的那一条在目录里被标成当前项",
            pg.locator(".dsapp-toc-item.active").count() >= 1)

        # 连点两次都要有效 —— 这是 priority:'event' 那条坑的老症状
        items.nth(2).click()
        pg.wait_for_timeout(1600)
        act = pg.evaluate("""() => {
          const a = document.querySelector('.dsapp-toc-item.active');
          const all = [].slice.call(document.querySelectorAll('.dsapp-toc-item'));
          return a ? all.indexOf(a) : -1;
        }""")
        chk("★ 再点第 3 条 → 高亮跟着换过去（index=%s）" % act, act == 2, act)

    # =====================================================================
    print("\n== item 4：缩略图可点开预览 ==")
    # =====================================================================
    ws = os.path.join(DATA_ROOT, "workspaces", "chat-%s" % sid) if sid else None
    if ws:
        os.makedirs(ws, exist_ok=True)
        write_png(os.path.join(ws, "umap_clusters.png"))
        write_png(os.path.join(ws, "volcano.png"), rgb=(200, 80, 90))
        print("    已写入 %s" % ws)
    # 产物是 reactivePoll(3000) 扫出来的，等它一轮
    pg.wait_for_timeout(6000)

    thumbs = pg.locator(".dsapp-thumb-img")
    if thumbs.count() == 0:
        chk("★ 对话里出现了缩略图（否则下面量不到东西）", False,
            "工作区里没有扫到图 —— 检查 %s" % ws)
    else:
        chk("★ 缩略图外层是可点的容器（%d 个）" % thumbs.count(), True)
        chk("★ 点得动是靠 cursor: zoom-in 而不是 pointer（和下面的文件名链接分开）",
            pg.evaluate("""() => getComputedStyle(
              document.querySelector('.dsapp-thumb-img')).cursor""") == "zoom-in")
        chk("★ 键盘够得着（tabindex + role=button）",
            pg.evaluate("""() => {
              const el = document.querySelector('.dsapp-thumb-img');
              return el.getAttribute('tabindex') === '0' &&
                     el.getAttribute('role') === 'button';
            }""") is True)

        thumbs.first.click()
        pg.wait_for_timeout(2200)
        modal = pg.locator(".modal.show")
        chk("★★ 点缩略图 → 弹出了预览", modal.count() >= 1, modal.count())
        if modal.count():
            mtxt = modal.first.inner_text()
            chk("★ 弹窗标题是那个文件名", "png" in mtxt, mtxt[:120].replace("\n", " "))
            chk("★ 弹窗里真的有图（不是「文件不存在」）",
                modal.first.locator("img").count() >= 1 and "不存在" not in mtxt,
                mtxt[:160].replace("\n", " "))
            chk("★ 弹窗里有下载按钮",
                modal.first.locator("button, a").count() >= 2)
            pg.screenshot(path=os.path.join(OUT, "v9_img_preview.png"))
            modal.first.locator("button", has_text="关闭").first.click()
            pg.wait_for_timeout(1000)
            # 关掉再点一次：同一个文件连点两次都要有效
            thumbs.first.click()
            pg.wait_for_timeout(2000)
            chk("★★ 关掉之后再点还能打开（同一个文件连点两次都有效）",
                pg.locator(".modal.show").count() >= 1)
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(600)
            # 点**名字**也要走同一个预览（V7 item 2 那条不能因为这次改动退化）
            pg.locator(".dsapp-thumb-cap").first.click()
            pg.wait_for_timeout(2000)
            chk("★ 点下面的文件名照样预览（V7 item 2 没被改坏）",
                pg.locator(".modal.show").count() >= 1)
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(600)

    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
