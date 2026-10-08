# -*- coding: utf-8 -*-
"""上线核对：**生产**那一份现在到底跑的是哪一版。

    /home/biomamba/miniconda3/bin/python tests/ui_v17/verify_live.py

为什么要单独有这么一个脚本 —— 本仓的生效闸门（`shiny:::cachedFuncWithFile`
盯着 `app.R` 的 mtime）只决定"**下次请求时**要不要重新 source"，它跟
"线上现在服务的是哪一份"是两件事：

  * `find R/ -newer app.R -name '*.R'` 为空 ⇒ 闸门过了，**但那只说明磁盘状态**；
  * 真正的判据是"浏览器里渲染出来的东西对不对"。

所以这里查两样，**两样都要**：

  1. 页脚的版本号 == 盘上 `R/config.R` 里的 `DSAPP_VERSION`（R 那半边）；
  2. `/YCFS_APP/app.js` 的正文里有本版新增的符号（`www/` 那半边）。

⚠️⚠️ **`www/` 挂在应用根上，不是 `/www/`。** 正确地址是
`/YCFS_APP/app.js`；写成 `/YCFS_APP/www/app.js` 会拿到一个 **404**，
而脚本里那个 `/regex/.test(text)` 对着 404 的正文（`Not Found`）**照样返回
false** —— 于是"两个符号都不在"看起来像是**代码没上线**，其实只是路径错了。
第一版就是这么写的，差点把一次成功的部署判成失败。

只碰登录页：不登录、不建会话、不写任何库。退出码 0 = 线上就是盘上这一版。
"""
import os
import re
import subprocess
import sys
import urllib.request

URL = os.environ.get("DSAPP_LIVE_URL", "http://127.0.0.1:34038/YCFS_APP/")
CONFIG = os.environ.get("DSAPP_CONFIG",
                        "/data3/biomamba/analysis/DS_App/R/config.R")

# 本版必须在线上 www/app.js 里出现的新符号（加一条就跟着加一行）。
# 判"新代码在不在"要挑**只有这一版才有**的字符串，别挑通用写法。
NEED = [
    ("item 1 的静默期常量", r"DSAPP_OFFLINE_QUIET_MS\s*=\s*60000"),
    ("item 3 的现读原文函数", r"dsappPushSendText"),
]


def disk_version():
    with open(CONFIG, encoding="utf-8") as fh:
        m = re.search(r'DSAPP_VERSION\s*<-\s*"([^"]+)"', fh.read())
    return m.group(1) if m else None


def fetch(path):
    """取一份静态资源。**取不到也算一条结果，不许抛出去。**

    ⚠️ 第一版这里直接 `urlopen`，路径写错时整个脚本是**带 traceback 崩掉**的：
    底下那几条 `chk` 一条都不会跑，屏幕上没有任何一条"红" —— 看起来像脚本自己
    坏了，而不像"线上不对"。判据取不到东西时必须**记成红**，这是本仓
    「拿不到元素就跳过一律改红」那条规矩在 Python 侧的样子。
    """
    try:
        with urllib.request.urlopen(URL.rstrip("/") + path, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace"), ""
    except urllib.error.HTTPError as e:
        return e.code, "", "HTTP %s" % e.code
    except Exception as e:                          # noqa: BLE001
        return 0, "", "%s: %s" % (type(e).__name__, e)


def main():
    nchk, nbad = [], []

    def chk(name, ok, extra=""):
        nchk.append(1)
        print("  %s %s%s" % ("\033[32m✓\033[0m" if ok else "\033[31m✗\033[0m",
                             name, ("  " + extra) if extra else ""))
        if not ok:
            nbad.append(name)

    want = disk_version()
    print("盘上 R/config.R 的 DSAPP_VERSION = %s" % want)
    chk("读得到磁盘上的版本号", bool(want))

    # ---- ① R 那半边：页脚 ----
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto(URL, wait_until="domcontentloaded")
        try:
            pg.wait_for_selector(".dsapp-footer-ver", timeout=60000)
            live = pg.inner_text(".dsapp-footer-ver").strip()
        except Exception as e:                      # noqa: BLE001
            live = "<拿不到：%s>" % e
        b.close()
    print("线上页脚渲染出来的      = %s" % live)
    chk("★ 页脚版本 == 磁盘上的版本（R 那半边换代了）",
        live == "V_%s" % want, "" if live == "V_%s" % want else "← 还是旧的")

    # ---- ② www/ 那半边 ----
    st, js, err = fetch("/app.js")
    # ⚠️ `len(js)` 是**字符数**不是字节数 —— `fetch()` 里 `r.read()` 之后又
    #    `.decode("utf-8")` 了。这个文件 34% 是多字节（满篇中文注释），
    #    200479 字节 / 131562 字符，两个数差 69 KB。
    #    2026-10-08 拿 `curl -w '%{size_download}'` 对着这个数看，一度以为
    #    "线上发的 app.js 和盘上不是同一个" —— 哈希一比其实是同一个。
    #    尺子本身没错，错的是单位名；照旧两边都印，省得下一个人再查一遍。
    chk("★ /app.js 拿得到（⚠️ 不是 /www/app.js —— 那个是 404）", st == 200,
        ("http=%s, %d 字符 / %d 字节" % (st, len(js), len(js.encode("utf-8"))))
        if st == 200 else ("拿不到：%s" % err))
    for label, pat in NEED:
        # ⚠️ 上一句已经红的时候，这一批必然是红的 —— **照样逐条记**，
        #    不跳过：跳过就会让"没跑"和"过了"在屏幕上长得一样。
        chk("★ 线上 app.js 里有%s" % label, bool(re.search(pat, js)))

    print()
    if nbad:
        print("\033[31m%d/%d 条没过：%s\033[0m" % (len(nbad), len(nchk), nbad))
        return 1
    print("\033[32m全部通过（%d 条）—— 线上就是盘上这一版\033[0m" % len(nchk))
    return 0


if __name__ == "__main__":
    sys.exit(main())
