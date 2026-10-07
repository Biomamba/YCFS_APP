# -*- coding: utf-8 -*-
"""tests/ui_v14 共用的几件小事：守卫、注册、切页、几何量取。

和 tests/ui_v1316/_common.py 是**两份**而不是一份 import 另一份：这些脚本
要能在"把仓库拷到 /tmp 单独跑"的场景下工作，跨目录 import 在那种场景里
最先坏掉。共用的是思路，不是文件。

⚠️ 抄过来时**默认值要一起改**（8917 / dsapp_v14 / dsapp_ui_v14）。
   从 ui_v1316 抄到 ui_v14 这次差点忘了改 —— 那条 URL 默认值必须是
   本版 README 里那条 make_instance.sh 命令建出来的**同一个**实例。
   忘了改的话浏览器一路在跟上一个版本的实例说话，而那种错法**看起来像
   测试全绿**（真跑通了，只是跑的是别人）。
"""
import io
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8917/")
# ⚠️ 默认值要和 tests/ui_v1316/README.md 里那条 make_instance.sh 命令**一模一样**。
#    这里曾经沿用了 ui_v13 那套 /tmp/dsapp_v11test_224730/app，而 README 让
#    人建的是 /tmp/dsapp_v131test —— 照着 README 做的人会在守门那一关被
#    「拒绝运行：…/.Renviron 不存在」挡下来，看起来像闸门坏了。
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v14/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v14")


def guard(app):
    """★ 拦住"对着线上那份代码跑测试"和"数据目录不在临时目录下"。

    ⚠️ 它只看 .Renviron 这个**文件**写了什么，管不了那个实例**实际**在读
    哪一份 .Renviron —— 2026-09-15 就是从这个缝里漏过去的（启动实例时的
    工作目录是仓库根，R 读的是仓库那份，指向线上 data/）。所以每个脚本在
    注册之后还要再验一次"刚建的账号出现在 DATA_ROOT 里"，见 seed_or_die。
    """
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


DATA_ROOT = guard(APP)
os.makedirs(OUT, exist_ok=True)

TAG = str(int(time.time()))[-6:]
EMAIL = "v14_%s@example.com" % TAG
PW = "Test-%s-pw" % TAG


def db_path():
    for r, _d, fs in os.walk(DATA_ROOT):
        for f in fs:
            if f.endswith(".sqlite3"):
                return os.path.join(r, f)
    return None


def wait_awake(page, timeout=150, reload_after=60):
    """★ 等实例**醒过来**，别把冷启动当成"页面坏了"。

    ⚠️ 应用整个 UI 是 renderUI("app_root") 出来的，所以**第一次 flush 完成
    之前 body 是真的空的**（0 字，不是"少"）。而实例刚起来的那一次请求要先
    把 R/*.R + app.R 重新求值、跑一遍建库/migrate，机器上有别的东西在抢 CPU
    时（比如上一轮测试留下的 callr 子进程）能拖过 30 秒。

    2026-09-16 连着两次踩到：脚本报「注册没进主界面（页面文字 0 字）」，
    截图是一片空白，看上去像"代码把应用改崩了"。其实是应用还没醒，
    而报错发生在注册**之后**、离真正的原因最远的地方。

    ⚠️⚠️ 但**别拿 reload 去等** —— 第一版是每 2 秒 reload 一次，结果把自己
    等死了：每 reload 一次就是**新开一个 Shiny session**，而首屏 flush 要
    先跑完建库/migrate + 一堆读库的 renderUI，本来就要几秒；还没 flush 完
    就被下一次 reload 掐掉，于是永远停在空白页 —— 而且日志里一个错都没有，
    看上去比"应用坏了"还像"应用坏了"。等 Shiny 自己推过来就行（websocket
    通了自然会到），reload 只在页面**真的死了**（超过 reload_after 还没动）
    时才用一次。
    """
    end = time.time() + timeout
    sw = time.time()
    while True:
        try:
            if page.locator(".dsapp-auth").count():
                return True
        except Exception:
            pass
        if time.time() > end:
            return False
        if time.time() - sw > reload_after:
            sw = time.time()
            try:
                page.reload(wait_until="domcontentloaded")
            except Exception:
                pass
        page.wait_for_timeout(1000)


def enter_app(page, email=None, nickname="V14测试"):
    """注册一个新账号并一路点到主界面（.dsapp-shell）。"""
    email = email or EMAIL
    # ⚠️ 实例没在跑的时候，page.goto 抛的是 playwright 的 ERR_CONNECTION_REFUSED：
    #    二十行 traceback，只有最后一行能看出是"连不上"，完全看不出是**测试实例
    #    根本没了**。2026-09-24 就栽过这一次：probe_freeze 靠 `kill -9` 服务端
    #    进程来测断线遮罩，而**测试实例里那个 R 进程就是服务器本身**（线上才另有
    #    独立 worker）。它一跑完，后面每个探针都变成这一坨红 —— 看起来像"这一版
    #    把三个功能弄坏了"，实际上只是实例被打死了。
    try:
        page.goto(URL, wait_until="domcontentloaded")
    except Exception as e:
        sys.exit(
            "连不上测试实例 %s\n  %s\n"
            "  · 实例没起来     → bash tests/ui_v7/make_instance.sh 8917 %s\n"
            "  · 刚跑过 probe_freeze / probe_wedge → 那两条会 kill / freeze 掉\n"
            "    服务端进程（测试实例里它就是服务器），实例已经死了。\n"
            "    重新起一次再跑别的探针；顺序上它们必须放**最后**。"
            % (URL, str(e).splitlines()[0],
               os.path.dirname(APP)))
    if not wait_awake(page):
        sys.exit("实例 %s 等了 150 秒还是空白页（冷启动没醒？看一眼 %s/app.log）"
                 % (URL, APP))
    page.wait_for_selector(".dsapp-auth", timeout=30000)
    page.wait_for_timeout(2000)

    if page.locator("#welcome-nickname").count() == 0:
        page.click("#welcome-go_register")
        page.wait_for_selector("#welcome-nickname", timeout=15000)
        page.wait_for_timeout(1000)
    page.fill("#welcome-nickname", nickname)
    page.fill("#welcome-email", email)
    page.fill("#welcome-phone", "13800000008")
    page.fill("#welcome-field", "转录组")
    page.fill("#welcome-password", PW)
    cb = page.locator("#welcome-tos_agree")
    if cb.count() and not cb.is_checked():
        cb.check()
    page.click("#welcome-do_register")

    # 恢复码页（"只显示这一次"）
    page.wait_for_selector("#welcome-enter_app", timeout=40000)
    page.click("#welcome-enter_app")

    # 用户须知闸门（V9 item 1，新账号必须勾选）
    #
    # ⚠️ 这里等的是**首屏 flush**，而它要跑完建库/migrate + 一堆读库的
    #    renderUI。实例刚起来（尤其是 make_instance.sh 刚把它重启过、
    #    页面缓存全冷）的那一次，40 秒是不够的 —— 2026-09-16 每次重启实例后
    #    的第一跑都栽在这儿，报的是「注册没进主界面（页面文字 0 字）」，
    #    看着像注册坏了，其实只是还没画出来；第二跑就好。
    #    90 秒之后还没动静才是真的有问题。
    for _ in range(90):
        page.wait_for_timeout(1000)
        if page.locator(".dsapp-shell").count():
            break
        if page.locator("#tos_gate-do_agree").count():
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            page.wait_for_timeout(3000)
    if not page.locator(".dsapp-shell").count():
        page.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        txt = page.inner_text("body")
        sys.exit("注册没进主界面（页面文字 %d 字）：\n%s" % (len(txt), txt[:600]))
    return email


def seed_or_die(email):
    """确认刚注册的账号真的落在**这个实例的**库里，返回 (uid, db 路径)。

    ⚠️ 找不到就硬退出。那说明这个实例读的不是这份 .Renviron，它多半正
    连着**线上库** —— 后面任何一句写操作都是在动生产数据。
    """
    import sqlite3
    p = db_path()
    if p is None:
        sys.exit("拒绝继续：%s 底下找不到 .sqlite3。" % DATA_ROOT)
    con = sqlite3.connect(p)
    row = con.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    con.close()
    if row is None:
        sys.exit("拒绝继续：刚注册的 %s 不在 %s 里。\n"
                 "  说明这个实例读的不是这份 .Renviron —— 停下来，先查它到底\n"
                 "  连着哪个数据目录（很可能就是线上库），别再往下跑了。"
                 % (email, p))
    return row[0], p


_DEC_R = """
# ⚠️ platform.R 必须在场：V13.2 起 dsapp_config() 会调 dsapp_default_data_root()，
#    而那个函数住在 R/platform.R 里。**这不是顺序问题，是"要么都加载、要么都别加载"**
#    的问题** —— dsapp_config() 是运行时才调用的，所以漏了 platform.R 时
#    source 阶段一切正常，等到真去算 data_root 才报
#    "could not find function"。selftest.R 里有一条断言专门扫这个
#    （「谁 source 了 R/config.R，就得同时 source R/platform.R」），
#    这条就是被它扫出来的 —— 同一个坑在 ui_v137 里也踩过一次。
source("R/platform.R"); source("R/config.R"); source("R/crypto.R")
for (x in readLines(commandArgs(trailingOnly = TRUE)[1], warn = FALSE)) {
  y <- dsapp_sec_dec(x)
  cat(if (is.null(y)) "<NULL>" else y, "\\n", sep = "")
}
"""

_DEC_CACHE = {}


def r_decrypt(values):
    """把库里的密文解回明文（V13.1 item 9 起这两列是密文）。

    ★ 为什么非得真解一次：密文是**随机 IV** 的，同一把 Key 写两次得到的
      字符串完全不同。所以「库里那格是不是 KEY_A」这句断言，在密文世界里
      **没有**"直接比字符串"的写法 —— 要么解出来比，要么退化成
      "非空且以 v1: 开头"，而后者抓不到"deepseek 那格装的是 moonshot 的
      Key"（这才是 item 5 真正要防的形态）。所以这里走真解密。

    ⚠️ **必须在 APP 目录下跑，而且不能自己设 DSAPP_DATA_ROOT。**
      R 启动时会读**当前工作目录**的 .Renviron，并且它的优先级**高于**
      显式设的环境变量。实测（2026-09-16）：

          cd /tmp/dsapp_v1313/app
          DSAPP_DATA_ROOT=/tmp/decoy_nonexistent Rscript -e \\
            'cat(Sys.getenv("DSAPP_DATA_ROOT"))'
          # 打出来的是 /tmp/dsapp_v135test/data —— 显式设的那个被盖掉了

      换句话说：cd 过去就够了，而且**只有** cd 过去才对 —— 解出来的就是
      这个实例自己那份钥匙串解出来的东西。（换成别的目录跑，R 会去读那个
      目录的 .Renviron，拿到另一份 data_root，症状是"解出来全是 NULL"，
      看着像"加解密坏了"。）

    返回和入参等长的列表；解不开的元素是 None。明文里不能有换行
    （一行一把），API Key / 密码都用不着换行。
    """
    vals = list(values)
    need = [v for v in vals if v is not None and v not in _DEC_CACHE]
    if need:
        import subprocess
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix=".txt", dir=OUT)
        with io.open(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(need) + "\n")
        try:
            # ⚠️ 这个 "-e" 不能省。Rscript 的第一个位置参数是**文件名**：
            #    漏掉它，Rscript 会把整段代码当成路径去找，报
            #    "Fatal error: cannot open file 'source(\"R/config.R\")...'"
            #    —— 而且这条错误**不走 stderr**，下面只看 stderr 的话
            #    打出来是一片空白，看着像 Rscript 凭空失败了。
            r = subprocess.run(["Rscript", "-e", _DEC_R.strip(), tmp], cwd=APP,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=120)
            if r.returncode != 0:
                sys.exit("r_decrypt: Rscript 失败（cwd=%s，exit=%d）：\n%s\n%s"
                         % (APP, r.returncode,
                            r.stdout.decode("utf-8", "replace")[:800],
                            r.stderr.decode("utf-8", "replace")[:800]))
            out = r.stdout.decode("utf-8", "replace").split("\n")[:-1]
            if len(out) != len(need):
                sys.exit("r_decrypt: 解出来 %d 条、要的是 %d 条。\n"
                         "  多半是明文里带了换行，把一行的协议撑破了。"
                         % (len(out), len(need)))
            for k, v in zip(need, out):
                _DEC_CACHE[k] = None if v == "<NULL>" else v
        finally:
            os.unlink(tmp)
    return [None if v is None else _DEC_CACHE.get(v) for v in vals]


PAGES = ["chat", "tasks", "files", "lit", "skills", "envs", "model", "settings",
         "help", "admin", "htadmin"]

# 中文页名 → nav 的 value。app.R 里的 nav_panel 是
# `nav_panel("言出法随", value = "chat", ...)` 这种形式，两套名字。
# ★ V13.12 item 19 加了 "model"：模型服务从"左栏常驻的折叠块"变成了
#   一页（用户原话「把模型服务换成和其它几个侧面导航栏一样的单独页面吧」）。
#   在这之前它**不是**一页，`goto(pg, "模型服务")` 会退化成
#   goto(pg, "模型服务") → 不在 PAGES 里 → 硬退出。
PAGE_VALUE = {
    "言出法随": "chat", "历史任务": "tasks", "文件": "files",
    "文献速递": "lit", "技能": "skills",
    "环境": "envs", "模型服务": "model", "设置": "settings",
    # ★ V13.14 item 23：帮助从设置页的第四个页签升成左栏一项。
    #   ⚠️ 忘了加这一行的话，`goto(pg, "帮助")` 会直接 sys.exit ——
    #      那是**响的**失败，比静默留在上一页好。
    "帮助": "help",
    "管理": "admin", "后台": "htadmin",
}


def goto(page, name, wait=2500):
    """切到某一页。**认 value**（"chat" / "settings"），也认中文页名。

    ⚠️ 必须显式切页。bslib 的 navset_hidden 是"所有页都留在 DOM 里、只藏
    不激活"，别的页的控件也都在 —— 不切过去的话，几何/配色断言量的全是
    隐藏元素的 0×0 矩形，报出来的失败会指向完全错误的地方。

    ⚠️⚠️ 传中文页名是 2026-09-21 踩到的坑：`dsappNav()` 收的是 nav 的
       **value**（`dsappNav("files")`），传 "文件" 的话服务端
       `nav_select("nav", "文件")` 找不到那一页 —— **不报错**，只是什么都没
       发生。而 `page.evaluate("... && window.dsappNav(v)")` 那一行本身也不
       会返回任何东西，于是"切页失败"在下游看起来是
       "这个元素怎么不可见 / 这个断言怎么红了"，指的全是错地方。
       实测：`goto(pg,"文件")` 之后人还在言出法随页，而 `.dsapp-wsrow`
       因为 bslib 把隐藏页也留在 DOM 里照样能被 query 到 —— 断言就那么
       静悄悄地在一片隐藏元素上通过了。

    ★ 切完之后**回读一次**：服务端要跑一趟才回执 dsapp:nav，这里等
      高亮真的落到那一项上，免得下游量到的是上一页。
    """
    v = PAGE_VALUE.get(name, name)
    if v not in PAGES:
        sys.exit("goto(): 认不出这一页 %r（value 只认 %s，中文页名见 PAGE_VALUE）"
                 % (name, "/".join(PAGES)))
    page.evaluate("(v) => window.dsappNav && window.dsappNav(v)", v)
    page.wait_for_timeout(wait)
    try:
        page.wait_for_function(
            "(v) => { var a = document.querySelector('.dsapp-rail-link.active');"
            " return !!a && a.getAttribute('data-nav') === v; }",
            arg=v, timeout=8000)
    except Exception:
        # 高亮没跟上不算致命（老皮肤/没装 rail 的版本没有 .dsapp-rail-link），
        # 但要**说出来** —— 静默地留在上一页正是这条注释开头说的那个坑。
        print("  ⚠️ 切到 %s 之后左栏高亮没跟上（可能没切过去）" % v, flush=True)


def set_skin(page, skin):
    """把皮肤切到 skin 并等它真的生效。

    皮肤本身是**客户端**的（见 www/skins.css 顶部），但选哪个是存在库里的
    服务端设置。这里为了快，直接改 <html data-skin> —— 量的就是这个属性
    决定的配色，和走一遍设置页的效果一样。要验"设置页存得下来"是另一个
    脚本的事，不是这个脚本要回答的问题。
    """
    page.evaluate("(s) => document.documentElement.setAttribute('data-skin', s)",
                  skin)
    page.wait_for_timeout(600)


def pick_select(page, sel_id, value):
    """在一个 selectInput 上选值 —— 必须像用户那样点开它自己的下拉。

    ⚠️ `page.select_option('#x', ...)` 对**默认的** selectInput 是无效的：
    Shiny 的 selectInput 默认 `selectize = TRUE`，原生的 <select> 被
    selectize 藏起来（0×0），Playwright 的可操作性检查会一直等到超时，
    报出来的是 "element is not visible" —— 指向的是"这个控件不存在"，
    而真实原因是"你该点的是它旁边那个假下拉"。
    """
    ctrl = page.locator(
        "xpath=//select[@id='%s']/following-sibling::div"
        "[contains(@class,'selectize-control')]" % sel_id)
    ctrl.locator(".selectize-input").click()
    page.wait_for_timeout(500)
    opt = ctrl.locator(".option[data-value='%s']" % value)
    if opt.count() == 0:
        opt = ctrl.locator(".option", has_text=value)
    opt.first.click()
    page.wait_for_timeout(400)


class Chk(object):
    def __init__(self):
        self.ok = True
        self.n = 0

    def __call__(self, name, cond, extra=""):
        self.n += 1
        print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
              (("   " + str(extra)) if extra and not cond else ""), flush=True)
        if not cond:
            self.ok = False
        return cond

    def done(self):
        print()
        print(("\033[32m全部通过\033[0m" if self.ok else "\033[31m有失败项\033[0m")
              + "（%d 条断言）" % self.n)
        print("截图在 " + OUT)
        return 0 if self.ok else 1
