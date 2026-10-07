# -*- coding: utf-8 -*-
"""tests/ui_v164 共用的几件小事：守卫、注册、切页、几何量取、假 LLM。

这一份是 **ui_v163/_common.py 的副本**（再往前是 ui_v161 ← ui_v158 ←
ui_v157 ← ui_v153），按本仓的老规矩：**两份**而不是一份 import 另一份 ——
这些脚本要能在"把仓库拷到 /tmp 单独跑"的场景下工作，跨目录 import 在那种
场景里最先坏掉。共用的是思路，不是文件。

⚠️ 抄过来时**默认值已经改过**（8973 / dsapp_v164a / dsapp_ui_v164），
   和 tests/ui_v164/README.md 里那条 make_instance.sh 命令一套。
   那条 URL 默认值必须是本版 README 里那条命令建出来的**同一个**实例。
   忘了改的话浏览器一路在跟上一个版本的实例说话，而那种错法**看起来像
   测试全绿**（真跑通了，只是跑的是别人）—— ui_v1316 → ui_v14 那一次就是
   这么差点漏过去的；ui_v162 → ui_v163 那次是照着那条教训改的。
   ⚠️ 这一版**端口换成了 8973**（原来是 8971）：8971 上还挂着 V16.3 那个
   实例（收尾要比对"老探针在上一版上红不红"，那份实例得留着），8972 是
   V16.2 的对照实例。探针里另有一条**版本号**断言兜底（页脚必须是
   Test_V16.4）—— 万一连错实例，它比"某个选择器找不到"先红，而且报的是
   真正的原因。
   ★ 本版真栽过一次**同一类**的：截图脚本用着 v162 的默认 URL(8967)，
   而 8967 上还挂着一个上个版本的实例 —— 拍出来的"新版界面"其实是老界面，
   报的是"`.dsapp-ctrl-box` 数出来是 0"。判据要连**版本**一起验
   （见 probe_ctrl.py 里的 `#chat-unlim_iter` 存在性检查）。

★ V153 相对 V152 多出来的，是**假 LLM 那一套**（见文件末尾 FakeLLM /
  seed_llm）：V15.3 的三条改动（思考流式、md 图片、400 一键修）只有让对话
  真的跑起来才看得到，而真的跑起来就必须有个应答的东西。这一段是照
  tests/v153_maxtok_fix.R 的隔离纪律抄的 —— **只打假服务端**，
  凭据只从环境变量/库里来，绝不为了"跑通"去碰真厂商。
"""
import io
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8973/")
# ⚠️ 默认值要和 tests/ui_v158/README.md 里那条 make_instance.sh 命令**一模一样**。
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v164a/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v164")


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
EMAIL = "v164_%s@example.com" % TAG
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


# ★ 最近一次 enter_app **真正用的**那个邮箱。
#   V153 的探针会给 enter_app 传一个每次新建的邮箱（重试要换一个，否则第二次
#   会撞上"这个邮箱已经注册过"），于是调用方不能再假定它就是 EMAIL ——
#   而后面 seed_or_die / 表单登录都要用真的那个。ent 记在这里，问它就行。
LAST_EMAIL = None


def enter_app(page, email=None, nickname="V15测试"):
    """注册一个新账号并一路点到主界面（.dsapp-shell）。"""
    global LAST_EMAIL
    email = email or EMAIL
    LAST_EMAIL = email
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
            "  · 实例没起来     → bash tests/ui_v7/make_instance.sh 8918 %s\n"
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
    #
    # ⚠️⚠️ 2026-09-30 又栽了一轮（probe_v156b 连着重试 3 次全空），这次量过：
    #    这台机器上**别的用户的 10 个 R 作业**常驻（load average 17），
    #    正常情况这一跳只要 4.7 秒（`/tmp/dsapp_enter_timing.py` 实测），
    #    但被挤的时候能拖过 90 秒 —— 而报出来的还是「页面文字 0 字」，
    #    看着像注册坏了。所以上限放宽到 180 秒：**慢**和**坏**要分得开。
    #    真坏的话 180 秒一样是空页面 + 截图，诊断信息一个字都不少。
    #    想改回去/改更长：`DSAPP_TEST_BOOT_SEC=90`。
    _BOOT_SEC = int(os.environ.get("DSAPP_TEST_BOOT_SEC", "180"))
    for _ in range(_BOOT_SEC):
        page.wait_for_timeout(1000)
        if page.locator(".dsapp-shell").count():
            break
        if page.locator("#tos_gate-do_agree").count():
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            page.wait_for_timeout(3000)
    # ★ V16.1：**冷实例的第一跑**会栽在这儿，而且栽得很有规律 ——
    #   注册那一步全都成功了（恢复码页面出来了、点得动），点完「进入应用」
    #   页面就是一片空白，等满 180 秒也不出来。日志里一个错都没有，
    #   截图是纯背景色。同一份代码在**第二跑**上 3 秒就进主界面。
    #   2026-10-04 连着在 8966 / 8963 两个刚 make_instance 起来的实例上复现，
    #   两次都是"第一跑空、第二跑好"。
    #   所以这里不硬退，先**重来一次**：回首页 —— cookie 还在的话直接进主界面；
    #   要是退回了登录页，就用刚注册的那个邮箱 + 密码登进去（注册那一步确实
    #   是成功的，账号在库里）。
    #   ⚠️ 重试**只做一次**：真坏了（改坏了 UI、服务端起不来）第二跑照样是空页，
    #      那时候再硬退，诊断信息一个字都不少。
    if not page.locator(".dsapp-shell").count():
        page.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        txt = page.inner_text("body")
        print("  ** 第一跑没进主界面（页面文字 %d 字），重来一次 **" % len(txt),
              flush=True)
        try:
            page.goto(URL, wait_until="domcontentloaded")
        except Exception:
            pass
        for _ in range(_BOOT_SEC):
            page.wait_for_timeout(1000)
            if page.locator(".dsapp-shell").count():
                break
            if page.locator("#welcome-do_login").count():
                page.fill("#welcome-login_email", email)
                page.fill("#welcome-login_password", PW)
                page.click("#welcome-do_login")
                page.wait_for_timeout(2000)
                continue
            if page.locator("#tos_gate-do_agree").count():
                c = page.locator("#tos_gate-agree")
                if c.count() and not c.is_checked():
                    c.check()
                page.click("#tos_gate-do_agree")
                page.wait_for_timeout(3000)
    if not page.locator(".dsapp-shell").count():
        page.screenshot(path=OUT + "/00_register_failed.png", full_page=True)
        txt = page.inner_text("body")
        sys.exit("注册没进主界面（重试一次也没用；页面文字 %d 字）：\n%s"
                 % (len(txt), txt[:600]))
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


# ★ V15.4 item 7：「后台」和「管理」合并成一项，「htadmin」这个 nav value
#   已经**不存在**了。名字留在这张表里的话，`goto(pg, "htadmin")` 不会
#   报错 —— 它会调 dsappNav("htadmin")，而那个 value 找不到，于是**静静
#   留在上一页**，后面所有几何断言都量在别人的元素上。所以删掉。
# ★ V15.8 item 2：加了 "cloudtool"（云工具）。⚠️ 名字漏在这张表里的症状和
#   上面 "htadmin" 那条注释里写的一模一样：goto(pg, "cloudtool") 不报错，
#    只是**静静留在上一页**，后面所有几何断言都量在别人的元素上。
PAGES = ["chat", "tasks", "files", "lit", "forum", "cloudtool", "skills",
         "envs", "model", "settings", "help", "admin"]

# 中文页名 → nav 的 value。app.R 里的 nav_panel 是
# `nav_panel("言出法随", value = "chat", ...)` 这种形式，两套名字。
# ★ V13.12 item 19 加了 "model"：模型服务从"左栏常驻的折叠块"变成了
#   一页（用户原话「把模型服务换成和其它几个侧面导航栏一样的单独页面吧」）。
#   在这之前它**不是**一页，`goto(pg, "模型服务")` 会退化成
#   goto(pg, "模型服务") → 不在 PAGES 里 → 硬退出。
PAGE_VALUE = {
    "言出法随": "chat", "历史任务": "tasks", "文件": "files",
    "文献速递": "lit",
    # ★ V15 item 8：论坛。**普通用户也看得见**（没有 role 限制）。
    "论坛": "forum",
    # ★ V15.8 item 2：云工具。同样是普通用户可见的页。
    "云工具": "cloudtool",
    "技能": "skills",
    "环境": "envs", "模型服务": "model", "设置": "settings",
    # ★ V13.14 item 23：帮助从设置页的第四个页签升成左栏一项。
    #   ⚠️ 忘了加这一行的话，`goto(pg, "帮助")` 会直接 sys.exit ——
    #      那是**响的**失败，比静默留在上一页好。
    "帮助": "help",
    # ★ V15.4 item 7：两页合并，左栏只剩「后台管理」，value 仍然是 "admin"
    #   （全仓多处裸 nav_select("nav","admin") 认的是它）。
    "后台管理": "admin", "管理": "admin",
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


# =============================================================================
# 假 LLM：V15.3 的三条改动只有让对话真的跑起来才看得到
#
# ⚠️⚠️ **这里的一切都只打 127.0.0.1 上那个假服务端。**
#    2026-09-28 写 tests/v153_maxtok_fix.R 时栽过一次：夹具里模型页把
#    `state$base_url` 换回了 `https://api.deepseek.com`，而**库里存着真 Key**，
#    于是测试真的打到了厂商、真的花了一次钱，报出来的错是一句 401。
#    探针里对付它的办法有两条，两条都要：
#      · `seed_llm()` 把 base_url 一起写进**设置行和钥匙串**（不是只写一个）；
#      · 发完消息之后断言 `fx.req_n() > 0`（假服务端真的收到了）。
#        真打到厂商的话假服务端一个请求都收不到，这一条会**响**。
# =============================================================================

# 服务端吐一个 SSE 事件块。和 tests/v153_maxtok_fix.R 里的 sse() 同一形状。
def sse(content=None, reasoning=None, finish="stop"):
    import json as _j

    def chunk(o):
        return "data: " + _j.dumps(o) + "\n\n"

    out = ""
    if reasoning:
        out += chunk({"choices": [{"delta": {"reasoning_content": reasoning},
                                   "finish_reason": None}]})
    if content:
        out += chunk({"choices": [{"delta": {"content": content},
                                   "finish_reason": None}]})
    out += chunk({"choices": [{"delta": None, "finish_reason": finish}]})
    return out + "data: [DONE]\n\n"


def sse_multi(reason_parts, content=None, finish="stop"):
    """思维链**分成好几段**吐出来，每段一个 SSE 事件。

    ★ 为什么要分段：思考过程"不闪"的判据是"字在往外长、而节点没被换掉"。
      整段思维链塞进**一个**事件的话，它要么还没到、要么一次到齐 ——
      中间没有任何"正在长"的采样点，"单调增长"那句就退化成了
      "一次跳到底"，抓不到"整块重画"。配上 FakeLLM.slow() 才有意义。
    """
    import json as _j

    def chunk(o):
        return "data: " + _j.dumps(o) + "\n\n"

    out = ""
    for p in reason_parts:
        out += chunk({"choices": [{"delta": {"reasoning_content": p},
                                   "finish_reason": None}]})
    if content:
        out += chunk({"choices": [{"delta": {"content": content},
                                   "finish_reason": None}]})
    out += chunk({"choices": [{"delta": None, "finish_reason": finish}]})
    return out + "data: [DONE]\n\n"


class FakeLLM(object):
    """拉一个 tests/fake_llm.py 起来，并且能脚本化它的应答。

    用法：
        fx = FakeLLM()
        fx.set_queue(sse("你好。"))
        fx.arm_400("Field 'max_tokens' must be at most 24576")
        ... fx.url ...
        fx.stop()

    ⚠️ 队列**按顺序**应答（第 N 次请求吃第 N 个文件），和 agent_loop.R 一致：
       agent 循环是一轮接一轮的，每轮都回同一段带代码的回复就永远不会结束。
    """

    def __init__(self, workdir=None):
        import subprocess
        import tempfile

        self.dir = tempfile.mkdtemp(prefix="dsapp_v158_fx_",
                                    dir=workdir or None)
        self.queue = os.path.join(self.dir, "queue")
        self.reqs = os.path.join(self.dir, "reqs")
        os.makedirs(self.queue)
        os.makedirs(self.reqs)
        self.state = os.path.join(self.dir, "served")
        pf = os.path.join(self.dir, "port")
        script = os.path.join(REPO, "tests", "fake_llm.py")
        if not os.path.exists(script):
            sys.exit("找不到 %s" % script)
        self.proc = subprocess.Popen(
            ["python3", script, self.queue, self.state, pf, self.reqs],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        port = None
        for _ in range(200):
            if os.path.exists(pf):
                port = open(pf).read().strip()
                if port:
                    break
            if self.proc.poll() is not None:
                sys.exit("fake_llm.py 没起来就退了：\n%s"
                         % self.proc.stderr.read().decode("utf-8", "replace"))
            time.sleep(0.05)
        if not port:
            self.stop()
            sys.exit("fake_llm.py 起来了但没写端口文件（%s）" % pf)
        self.port = int(port)
        self.url = "http://127.0.0.1:%d" % self.port

    # ---- 脚本化应答 --------------------------------------------------------
    def set_queue(self, *items):
        """把队列换成这几条（按顺序应答）。

        ⚠️ 只清 `*.txt`。**不清 `400.json` / `slow.json`** —— 那两个是和队列
           正交的开关，一起清掉的话"先摆队列再放 400"和"先放 400 再摆队列"
           会得到不同结果，而那种差异没有任何理由，纯粹是自找的
           （tests/v153_maxtok_fix.R 就为这个顺序白查了一轮）。
        """
        for f in os.listdir(self.queue):
            if f.endswith(".txt"):
                os.unlink(os.path.join(self.queue, f))
        for i, t in enumerate(items, 1):
            with io.open(os.path.join(self.queue, "%03d.txt" % i), "w",
                         encoding="utf-8") as fh:
                fh.write(t)
        # 计数器要一起归零，否则"换了队列"之后第 1 条取不到（会从上次的位置
        # 接着数下去，而队列又短了 —— 表现成"回的是队列已空"）。
        try:
            os.unlink(self.state)
        except OSError:
            pass

    def _json(self, name, obj):
        import json as _j
        with io.open(os.path.join(self.queue, name), "w",
                     encoding="utf-8") as fh:
            fh.write(_j.dumps(obj))

    def arm_400(self, msg, times=1, status=400):
        """前 times 次请求回**真** HTTP 400，错误原文就是 msg。

        ⚠️ 必须是 JSON 错误体（`{"error":{"message":...}}`），不是一句纯文本：
           llm.R 会先试 `fromJSON(body)$error$message`，解析不出来才退回整段
           body —— 纯文本的话界面上的那句话会带着 `{"error":{...}}` 的壳，
           和厂商真实的样子不一样。
        """
        self._json("400.json",
                   {"status": status, "times": times,
                    "body": {"error": {"message": msg,
                                       "type": "invalid_request_error"}}})
        try:
            os.unlink(self.state + ".n400")
        except OSError:
            pass

    def disarm_400(self):
        try:
            os.unlink(os.path.join(self.queue, "400.json"))
        except OSError:
            pass

    def slow(self, delay=0.25):
        """SSE 按事件块慢放，每块之间 sleep delay 秒。

        ★ 为什么需要：思考"不闪"的判据是**节点身份指纹**，要靠生成期间反复
          采样。整段回复在一个 200ms 轮询周期内就吐完的话一次都采不到，
          "指纹不变"就会**因为没采样而通过** —— 假绿。
        """
        self._json("slow.json", {"delay": delay})

    def no_slow(self):
        try:
            os.unlink(os.path.join(self.queue, "slow.json"))
        except OSError:
            pass

    # ---- /models（V16.3 item 7）--------------------------------------------
    def serve_models(self, ids, delay=0.0):
        """让这个假服务端把 `GET /models` 答成这几个模型名。

        ⚠️ 不调它的话 `/models` 回的是 501（fake_llm.py 原来的行为）——
           501 在 dsapp_llm_models() 那边是 `status >= 400` → 抛错 → 界面上
           一条红字。所以"这条探针没走过 /models"和"走过了但答案不对"看起来
           是两回事，别混。
        ⚠️ `delay` 是给竞态用的：先发的那家慢、后发的那家快，才造得出
           "后到的应答属于上一家"那个形状（见 probe_item7.py）。
        """
        self._json("models.json", {"delay": delay, "data": list(ids)})

    def models_n(self):
        """假服务端一共收到几次 `GET /models`。
        0 和 >0 的区别就是"自动拉这一下到底发出去没有"。"""
        try:
            return int(open(self.state + ".models").read().strip())
        except Exception:
            return 0

    # ---- 记账 --------------------------------------------------------------
    def req_n(self):
        """假服务端一共收到几次请求。**断言它 > 0 就是"没打到真厂商"的证明。**"""
        try:
            return len([f for f in os.listdir(self.reqs) if f.endswith(".json")])
        except OSError:
            return 0

    def req_body(self, i):
        """第 i 次请求的请求体（1 起）。拿去断言 max_tokens 这类出网参数。"""
        import json as _j
        p = os.path.join(self.reqs, "req-%04d.json" % i)
        if not os.path.exists(p):
            return None
        try:
            return _j.loads(io.open(p, encoding="utf-8").read())
        except Exception:
            return None

    def served_n(self):
        try:
            return int(open(self.state).read().strip())
        except Exception:
            return 0

    def stop(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


_SEED_R = r"""
# 把**这个实例的**库里那个账号指向假服务端。
#
# ⚠️ 必须在 APP 目录下跑：R 读的是**当前工作目录**的 .Renviron，而且它的
#    优先级高于显式设的环境变量（不是猜的，tests/ui_v152/_common.py 的
#    r_decrypt 里记着实测过程）。cd 过去就够了，而且只有 cd 过去才对。
#
# ⚠️⚠️ 三个都要写、一个都不能少：
#      · dsapp_settings_save  —— users 那一行（state$vendor/model/base_url 从这来）
#      · dsapp_api_key_put    —— 钥匙串那一行（**base_url 也存了一份**）
#      · dsapp_api_key_activate —— 把钥匙串那一行认成"当前用的这把"
#    只写第一个的话 api_key_now() 读到空、退回 state$api_key；
#    只写前两个的话"当前用的是哪把"没更新。
a <- commandArgs(trailingOnly = TRUE)
uid <- as.integer(a[1]); v <- a[2]; m <- a[3]; u <- a[4]; k <- a[5]

# 照 app.R 的原样把 R/*.R 加载起来。**顺序从 app.R 里读出来**，不另抄一份
# —— 抄一份就会有"清单改了、这里没改"的那一天，症状是某个函数找不到。
#
# ⚠️ 取这段要用**数括号**，不能找"单独一行的 `)`"。app.R 里最后一项是
#    `"mod_htadmin.R")` —— 收尾的括号和最后一个元素在**同一行**上，
#    找独立右括号会一路找到几百行之外某个不相干的 `)`，然后 parse 报
#    `<text>:168:1: unexpected '}'`（2026-09-28 就是这么栽的，
#    而那个错指向的是"app.R 语法有问题"，和真正的原因毫无关系）。
al <- readLines("app.R", warn = FALSE)
i <- grep("^[[:space:]]*files <- c\\(", al)[1]
if (is.na(i)) stop("app.R 里找不到 files <- c( ... )")
buf <- character(0); depth <- 0L
# ⚠️⚠️ 循环变量**不能叫 k**：上面 `k <- a[5]` 是 API Key，这个循环会把
#    它覆盖成**行号**（app.R 里 files <- c(...) 收在第 245 行 → 库里存的
#    Key 就是字符串 "245"，2026-10-02 实测）。这个错**在探针里看不见** ——
#    假 LLM 不校验 Authorization，所以每条断言照样全绿；只有请求真的打到
#    厂商时才会冒出一个 401，而那时候钱已经花了。
for (li in i:length(al)) {
  ln <- al[[li]]
  buf <- c(buf, ln)
  # 先把字符串字面量抠掉，免得元素里出现括号把计数带偏
  ch <- strsplit(gsub('"[^"]*"', '""', ln), "")[[1]]
  depth <- depth + sum(ch == "(") - sum(ch == ")")
  if (depth <= 0L) break
}
if (depth != 0L) stop("app.R 里 files <- c( 的括号没配对")
eval(parse(text = paste(buf, collapse = "\n")))
for (f in files) { p <- file.path("R", f); if (file.exists(p)) source(p, local = globalenv()) }

# ★ 写库之前钉一条判据：k 必须还是命令行传进来的那把。
#   上面那个错能活这么久，就是因为**没有任何一步会因为它而失败**。
if (!identical(as.character(k), as.character(a[5]))) {
  stop("seed: k 被覆盖了（现在是 [", k, "]），拒绝把它当成 API Key 写进库")
}

cfg <- dsapp_config(); dsapp_init_dirs(cfg); con <- dsapp_db(cfg)
dsapp_settings_save(uid, vendor = v, model = m, base_url = u, api_key = k, con = con)
dsapp_api_key_put(uid, v, k, base_url = u, model = m, con = con)
dsapp_api_key_activate(uid, v, con = con)

# 回读一次，确认真的落进去了 —— 上面三个函数都是"静默返回 FALSE"的
# （参数不对就当没调用），不回读的话失败长成"后面某一步莫名其妙"。
r <- DBI::dbGetQuery(con, "SELECT llm_vendor, llm_model, llm_base_url FROM users WHERE id = ?",
                     params = list(uid))
cat("OK\n")
cat(sprintf("uid=%s vendor=%s model=%s base_url=%s\n", uid,
            r$llm_vendor[1], r$llm_model[1], r$llm_base_url[1]))
"""


def seed_llm(uid, base_url, vendor="deepseek", model="fake-model",
             api_key="fake-key-v157"):
    """把 uid 这个账号的设置 + 钥匙串都指向 base_url（假服务端）。

    返回 R 打印的那一行摘要；出问题就 sys.exit（带着 R 的原文）。
    """
    import subprocess
    import tempfile
    fd, tmp = tempfile.mkstemp(suffix=".R", dir=OUT)
    os.close(fd)
    with io.open(tmp, "w", encoding="utf-8") as fh:
        fh.write(_SEED_R)
    try:
        r = subprocess.run(
            ["Rscript", tmp, str(uid), vendor, model, base_url, api_key],
            cwd=APP, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=300)
    finally:
        os.unlink(tmp)
    so = r.stdout.decode("utf-8", "replace")
    se = r.stderr.decode("utf-8", "replace")
    if r.returncode != 0 or "OK" not in so:
        sys.exit("seed_llm 失败（cwd=%s，exit=%d）：\n--- stdout ---\n%s\n"
                 "--- stderr ---\n%s" % (APP, r.returncode, so[:1500], se[:1500]))
    line = [l for l in so.splitlines() if l.startswith("uid=")]
    print("  种子：" + (line[0] if line else so.strip()), flush=True)
    return line[0] if line else so.strip()

# ★ V16.1：从 tests/ui_v158/probe_ctx.py **原样搬过来**的。
# 搬来而不是 import：这些脚本要能在"把仓库拷到 /tmp 单独跑"的场景里工作，
# 跨目录 import 在那种场景里最先坏掉（本仓的老账，_common.py 已经因此有 7 份副本）。
# 它测的是 V15.8 item 3，但**每个**要进对话页发消息的探针都得先过它这一关。
def ensure_no_modal(page, timeout=10):
    """把那个**只问一次**的「AI 怎么干活？」首选项弹窗关掉。

    ⚠️ 它是新账号第一次开对话时自己弹的（mod_chat.R 的 onboarding），盖在
      整页上 —— 有它在，点 `#chat-send` 会一直报
      「<div id="shiny-modal"> intercepts pointer events」，
      **报错指向的是"发送按钮点不动"**，和真正的原因（一个首选项弹窗）
      隔着十万八千里。

    选「都先别开，我自己盯着」（`#chat-agent_pref_manual`）是刻意的：本探针
    要的是**一轮一问一答**，自动执行开着的话 agent 循环会自己往下跑，后面
    那些"发一条、断言一条"的时序全乱。

    ⚠️ 只处理这一个已知的弹窗。**出现别的弹窗要炸出来**，不要顺手 Escape
      —— 那样会把自己想测的东西一起关掉。
    """
    end = time.time() + timeout
    while time.time() < end:
        if page.locator("#shiny-modal:visible").count() == 0:
            if page.locator(".modal-backdrop:visible").count() == 0:
                return True
        btn = page.locator("#chat-agent_pref_manual")
        if btn.count():
            btn.first.click()
            page.wait_for_timeout(1500)
            continue
        page.wait_for_timeout(300)
    if page.locator("#shiny-modal:visible").count():
        txt = page.evaluate(
            "() => (document.querySelector('#shiny-modal')||{}).innerText || ''")
        sys.exit("页面上压着一个**不认识的**弹窗，探针不猜它是什么：\n%s"
                 % txt[:400])
    return True
