# -*- coding: utf-8 -*-
"""V16.10：对话页的「一键打包下载」（两个根一起打）+ 超限转后台。

跑法（**两个**实例都要先起好）：

    bash tests/ui_v7/make_instance.sh 8980 /tmp/dsapp_v1610a
    bash tests/ui_v1610/make_bg_instance.sh
    python3 tests/ui_v1610/probe_filezip.py

用户原话：「言出法随的文件页面和真正的文件管理页面文件不同步，那意味着你写了
         两套文件展示系统，这是大大的浪费，请同步，并且支持在演出法随的文件
         展示中一键打包下载」。

为什么非得上浏览器 —— R 那一侧已经有 50 条真行为断言
（`tests/v1610_filesui.R` A1–A8，含**真起子进程**跨进程打包），下面这几条
它一条都验不到：

  A. 那颗按钮**真的画出来了**、文案里的 N **真的等于**卡片上列出来的行数。
     （本仓有账：renderUI 没读失效源 → 写库成功但页面一动不动。）
  B. 点一下**真的下下来一个包**，而且包里**两个根的东西都在**。
     R 那侧验的是 `dsapp_zip_write_multi()`；"点按钮 → 服务端算计划 →
     藏着的 downloadLink → clickWhenReady 补点击 → 浏览器落盘"这一整条
     链路它一个字都碰不到（三件套少任何一件都是**静默**失效：空 href 一点
     就导航回首页，用户拿到一个 HTML）。
  C. ★★ 超限那条：按钮**真的**变 disabled、真的出现「正在打包…（已 N 秒）」、
     跑完**真的**变回可点、然后**真的**开始下载。`disabled` 和进度文案都是
     renderUI 里算出来的，静态扫源码看不出它们有没有生效 —— 而失效的形态
     恰恰是"点了没反应"或者"按钮永远转着"。
  D. 而且**同一个量**在点之前先量一遍（那时是旧的），这样"按钮在"和"按钮
     跟着状态变"是同一个视图里的前后两帧，不是一个只测了结果、永远绿的量。

⚠️⚠️ 为什么非要**两个实例**：`DSAPP_ZIP_MAX` 是应用**启动时**读进去的常数，
   一个进程里改不了。而两条路都要验：
     · 8980 = 原样（绝大多数用户走这条：同步打包）；
     · 8981 = `make_bg_instance.sh` 把那个常数改成 **8 字节**的副本
       （超限 → 后台）。⚠️ **8** 是照夹具里**最小那一次勾选**挑的：整层是
       74 字节，而 D 段在「文件」页只勾那两个已发布的文件（9 + 9 = 18 字节）
       —— 取 32 的话 18 < 32，D 段会安安静静地走同步那条路，报出来是
       「点下去按钮没变 disabled」，指向 UI 而不是这个阈值。
   只留后台那条的话，**正常那条一次都没被浏览器验过**。

⚠️⚠️ 种出来的场景必须**两个根都有东西**（`seed_zip.R` 里同步 2 个、留 3 个
   没同步）：文件区那几行带 `files:` 前缀、工作区那几行不带，这正是
   `dsapp_zip_plan_multi()` 存在的唯一理由。全同步过去就退化成单根了，
  而单根那条路文件页已经用了几个月 —— 验了等于没验。
"""
import os
import re
import sqlite3
import subprocess
import sys
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BG_APP = os.environ.get("DSAPP_TEST_APP_BG", "/tmp/dsapp_v1610b/app")
ck = C.Chk()

# 这一层（根）应该有多少**行** —— 和 seed_zip.R 里种的东西一一对应：
#   文件区：analysis.R、sessionInfo.txt                        （2）
#   工作区：差异基因 表.csv、volcano plot.png、README.txt、results/（4）
# ⚠️ 写死是有意的：这个数**不**从夹具那边读过来。从夹具读的话，"卡片少列了
#    一行"和"夹具少种了一个"会一起变，两边一起错就永远看不出来。
N_ROWS = 6
# 包里应该有**几条真文件**（目录条目不算）：
#   文件区 2 + 工作区根 3 + results/figures/ 下 2 = 7
N_FILES = 7


def bg_data_root():
    """第二个实例的 data_root。没起就**硬退出**（不跳过）。

    ⚠️ 跳过的话这条探针在"只起了一个实例"时会"全绿"—— 而它恰恰有一条
       什么都没验到。本仓为"拿不到元素就跳过"记过账。
    """
    try:
        return C.guard(BG_APP)
    except SystemExit:
        sys.exit("❌ 第二个实例（%s）不在。先跑：\n"
                 "     bash tests/ui_v1610/make_bg_instance.sh\n"
                 "   它会把 DSAPP_ZIP_MAX 改成 8 再起在 8981 —— 那条\n"
                 "   「超过上限 → 转后台」的路只有它验得到。" % BG_APP)


def run_seed(app, data_root, email):
    """跑 seed_zip.R，把 `KEY=VALUE` 那几行解析成 dict。

    ⚠️ 必须 `--no-environ`：仓库根那份 `.Renviron` 指着**生产库**，而 Rscript
       会读 **cwd** 的 `.Renviron` 并**盖掉**继承的环境变量（本仓为此在生产
       库里种过东西）。`--no-environ` 之后 data_root 只由命令行给。
    """
    scr = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed_zip.R")
    p = subprocess.run(
        ["Rscript", "--no-environ", scr, app, data_root, email],
        capture_output=True, text=True, cwd=ROOT)
    sys.stdout.write(p.stdout)
    if p.returncode != 0:
        sys.exit("seed_zip.R 退出码 %d：\n%s" % (p.returncode, p.stderr[-2000:]))
    out = {}
    # ⚠️ 字符类里**要有下划线**：`[A-Z]+` 抓不到 `ON_DISK=`（它在 `_` 上断掉，
    #    那一行一个 match 都没有）—— 症状是下面 KeyError，报的位置离真正的
    #    原因（正则写窄了）只差一行。
    for k, v in re.findall(r"^([A-Z_]+)=(.*)$", p.stdout, re.M):
        out[k] = v.strip()
    if "SID" not in out:
        sys.exit("seed_zip.R 没打出 SID，stdout：\n%s" % p.stdout[:2000])
    return out


def rows_in_card(pg):
    """卡片上**列出来的行数**（顺带把另外两个数也数出来当交叉核对）。

    返回 `(行, 缩略图, 全部链接)`。

    ⚠️⚠️ 行认 `a.small.dsapp-file-link`，**不是** `a.dsapp-file-link` ——
       后者**也命中缩略图下面那行文件名**（`dsapp-thumb-cap … dsapp-file-link`，
       `R/mod_chat.R:5486`），而夹具里**就有图**（`volcano plot.png` 在根这一层，
       `results/figures/` 底下还有两张，`art_thumbs()` 是**递归**取的）。
       数出来会是 6+3 而不是 6，而症状是"按钮上的 N 比卡片少三"——
       看着像按钮算错了，其实是这里数多了。
       两个类名都钉在自检里（`selftest.R` 的 V13.11 那一节），不会自己漂。
    ⚠️ 三个数一起返回是**故意的**：单看"行数 == 6"的话，选择器哪天只匹配到
       一部分也会碰巧对上；配上 `行 + 缩略图 == 全部链接` 就漏不掉了。
    """
    try:
        return (pg.locator(".dsapp-artifacts a.small.dsapp-file-link").count(),
                pg.locator(".dsapp-artifacts a.dsapp-thumb-cap").count(),
                pg.locator(".dsapp-artifacts a.dsapp-file-link").count())
    except Exception:
        return -1, -1, -1


def read_btn(pg):
    """那颗按钮：(在不在, 是不是 disabled, 文案)。"""
    loc = pg.locator("#chat-art_zip_ui button")
    if loc.count() == 0:
        return (False, None, "")
    try:
        dis = loc.first.is_disabled()
    except Exception:
        dis = None
    return (True, dis, (loc.first.inner_text() or "").strip())


def btn_n(label):
    """文案里那个「（N 项）」的 N。取不到给 None（调用方报红，不跳过）。"""
    m = re.search(r"（(\d+)\s*项）", label or "")
    return int(m.group(1)) if m else None


def notif_texts(pg):
    try:
        return [t for t in pg.locator(".shiny-notification").all_inner_texts() if t]
    except Exception:
        return []


def entries(path):
    """下载下来的包里有几条**真文件**、条目名分别是什么。

    ⚠️ 用 Python 的 zipfile 读，不回头去问 R —— 产包的是 R，验包的再是 R 的话
       "两边一起错"就看不出来了（比如条目名差一个前缀，`zip_list` 和
       `zip::zip` 是同一套认知）。
    ⚠️ 目录条目（`results/` 这种以 `/` 结尾的）单独摘出去：`include_directories`
       默认是 TRUE，它们在不在**不是**这道题要问的东西，混进来数个数就会
       时多时少。
    """
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
    dirs = [n for n in names if n.endswith("/")]
    files = [n for n in names if not n.endswith("/")]
    return files, dirs


def seed_and_open(pg, url, data_root, nickname, tag):
    """把浏览器指到某个实例上、注册、种场景、进对话页。

    ⚠️ `enter_app` / `seed_or_die` 读的是 `_common` 的**模块级** URL /
       DATA_ROOT，所以这里临时改掉再改回来。不改的话第二个实例那一段会去
       8980 上注册，而库对的是 8981 的 —— 表现为"刚建的账号不在这个库里"，
       看着像实例连错了库。
    """
    save_url, save_root = C.URL, C.DATA_ROOT
    C.URL, C.DATA_ROOT = url, data_root
    try:
        email = C.enter_app(pg, email="v1610%s_%s@example.com" % (tag, C.TAG),
                            nickname=nickname)
        uid, _db = C.seed_or_die(email)
    finally:
        C.URL, C.DATA_ROOT = save_url, save_root
    ck("⓪ %s：注册的新账号落在**这个实例的**库里（uid=%d）" % (tag, uid), uid > 0)

    foot = pg.inner_text("body")
    ck("⓪ %s：页脚版本是 Test_V16.10（连错实例时这条才是真的原因）" % tag,
       "Test_V16.10" in foot, "页面文字里找不到 Test_V16.10")

    # ⚠️ 种完必须**重新加载**：会话列表是登录那一刻拉的一次，不 reload 的话
    #    界面上根本没有这个对话（本仓的老账）。而这里种子是**另一个进程**
    #    写的，当前 Shiny 会话对它一无所知。
    s = run_seed(APP_OF[tag], data_root, email)
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-shell", timeout=120000)
    pg.wait_for_timeout(4000)
    return email, uid, s


APP_OF = {}


def open_chat(pg):
    """切到对话页并等那张卡片出来。"""
    C.goto(pg, "chat")
    # ★ 新账号第一次进对话页有个「AI 怎么干活？」的引导弹窗，它会把**所有**
    #   click 都拦成 `intercepts pointer events` 超时，而报错指向按钮本身。
    C.ensure_no_modal(pg)
    try:
        pg.wait_for_selector(".dsapp-artifacts", timeout=30000)
    except Exception:
        pg.screenshot(path=os.path.join(C.OUT, "no_card.png"), full_page=True)
        sys.exit("❌ 对话页右侧那张产物卡片没出来（截图 %s/no_card.png）。"
                 "多半是那个对话没被自动选中 —— 种子的 updated_at 要比别的"
                 "对话新。" % C.OUT)
    pg.wait_for_timeout(2500)


# =============================================================================
def phase_sync(pg, url, data_root):
    """① 正常那条：原样实例，点一下 → 同步打包 → 落盘。"""
    print("\n\033[36m== A 段：原样实例（同步打包）%s ==\033[0m" % url, flush=True)
    APP_OF["a"] = C.APP
    email, uid, s = seed_and_open(pg, url, data_root, "V1610同步", "a")
    ck("① 种出来的场景**两个根都有东西**（文件区 %s 个 + 工作区独有 %s 个）"
       % (s.get("PUB"), s.get("WS_ONLY")),
       s.get("PUB") == "2" and s.get("WS_ONLY") == "3",
       "PUB=%s WS_ONLY=%s" % (s.get("PUB"), s.get("WS_ONLY")))

    open_chat(pg)
    n_rows, n_thumb, n_all = rows_in_card(pg)
    ck("② 选择器对得上（行 %d + 缩略图 %d == 全部链接 %d）"
       % (n_rows, n_thumb, n_all),
       n_rows >= 0 and n_rows + n_thumb == n_all,
       "对不上就说明卡片的结构变了，下面每条都会跟着错")
    ck("② 卡片上列出了 %d 行（期望 %d，种子的形状说了算）" % (n_rows, N_ROWS),
       n_rows == N_ROWS, "实际 %d 行" % n_rows)

    ok, dis, label = read_btn(pg)
    ck("② ★ 那颗「打包下载」按钮在（#chat-art_zip_ui）", ok,
       "没有这个节点 —— renderUI 没渲染出来")
    ck("② ★ 它现在是**可点**的（一直禁用的话下面那条白验）",
       dis is False, "state=%r" % ((ok, dis, label),))
    # ★★ 按钮上那个 N 和卡片列出来的行数**必须**是同一个数。
    #    ⚠️ 卡片本来就截断到 8 行，所以要拿 ≤8 行的场景来问这个 —— 种子就是
    #       按这个挑的（6 行）。行数超 8 的话这里会拿"8"和"N"比，红得没道理。
    ck("② ★★ 按钮文案里的 N（%s）**等于**卡片列出来的行数（%d）"
       % (btn_n(label), n_rows),
       btn_n(label) == n_rows, "按钮文案：%r" % label)
    # ★ 目录那一行画出来的两个字符串，都不是这张卡片自己写死的 —— 它们来自
    #   `art_level_df()` 过完 `dsapp_files_rows()` 之后的字段（「文件」页那张表
    #   读的是同一个规则；这就是用户说的"两套展示系统"里被合掉的那一半）。
    #   ⚠️ 写死「—」和「文件夹」这两个字面量是**故意的**：这条问的就是
    #      "共享出来的字段有没有真的画到 DOM 上"。字段算对了但页面不动的账
    #      本仓记过（`renderUI` 没读失效源）。
    row_txt = ""
    try:
        row_txt = (pg.locator(".dsapp-artifacts div.border-bottom")
                   .filter(has_text="results").first.inner_text() or "")
        row_txt = " ".join(row_txt.split())
    except Exception:
        pass
    ck("② ★ 目录那一行的体积写「—」、徽标写「文件夹」（%r）" % row_txt,
       "—" in row_txt and "文件夹" in row_txt, row_txt)

    # ---- 点一下，收包 ------------------------------------------------------
    dl_path = os.path.join(C.OUT, "sync.zip")
    got = None
    try:
        with pg.expect_download(timeout=60000) as info:
            pg.locator("#chat-art_zip_ui button").first.click()
        got = info.value
        got.save_as(dl_path)
    except Exception as e:
        ck("③ ★★ 点一下**真的**下下来一个包", False, str(e).splitlines()[0])
        pg.screenshot(path=os.path.join(C.OUT, "no_download.png"), full_page=True)
        return
    ck("③ ★★ 点一下**真的**下下来一个包", True)
    print("      下载名：%s（%d 字节）"
          % (got.suggested_filename, os.path.getsize(dl_path)), flush=True)
    ck("③ 下载名是「…-N项.zip」那个格式（N 就是按钮上那个数）",
       got.suggested_filename.endswith("-%d项.zip" % N_ROWS),
       "实际 %r" % got.suggested_filename)

    files, dirs = entries(dl_path)
    print("      包里的文件：%s" % files, flush=True)
    print("      包里的目录条目：%s" % dirs, flush=True)
    ck("③ ★★ 文件区那一组的东西在包里（analysis.R / sessionInfo.txt）",
       "analysis.R" in files and "sessionInfo.txt" in files)
    ck("③ ★★ 工作区那一组的东西也在（差异基因 表.csv / results 底下那两张图）",
       "差异基因 表.csv" in files and any(x.endswith("top10.png") for x in files),
       "包里没有工作区那份 —— 那就是「静默少打了一组」")
    ck("③ 一共 %d 条真文件（目录条目不算）" % N_FILES,
       len(files) == N_FILES, "实际 %d 条：%s" % (len(files), files))
    ck("③ 子目录里的文件带**正确的路径前缀**（mirror 模式下拼错前缀看不出来）",
       any(x.startswith("results/figures/") for x in files), files)

    # ---- 收尾：按钮不能被这次同步下载搞成禁用 ------------------------------
    ok2, dis2, label2 = read_btn(pg)
    ck("③ ★ 同步那条路走完按钮**还是可点的**（同步那条不该 disable）",
       ok2 and dis2 is False, "state=%r" % ((ok2, dis2, label2),))
    pg.screenshot(path=os.path.join(C.OUT, "a_sync.png"), full_page=True)
    return s


def phase_bg(pg, url, data_root):
    """② 超限那条：常数被改小的实例，点一下 → 转后台 → 落盘。"""
    print("\n\033[36m== B 段：超限实例（转后台）%s ==\033[0m" % url, flush=True)
    APP_OF["b"] = BG_APP
    email, uid, s = seed_and_open(pg, url, data_root, "V1610后台", "b")
    ck("① 同一个场景（文件区 %s + 工作区独有 %s）"
       % (s.get("PUB"), s.get("WS_ONLY")),
       s.get("PUB") == "2" and s.get("WS_ONLY") == "3")

    open_chat(pg)
    n_rows, n_thumb, n_all = rows_in_card(pg)
    ck("② 行数对得上（行 %d + 缩略图 %d == 全部链接 %d，期望 %d 行）"
       % (n_rows, n_thumb, n_all, N_ROWS),
       n_rows == N_ROWS and n_rows + n_thumb == n_all, "实际 %d 行" % n_rows)
    ok, dis, label = read_btn(pg)
    ck("② 按钮在、可点、N 对得上（%s / %d）" % (btn_n(label), n_rows),
       ok and dis is False and btn_n(label) == n_rows, "%r" % ((ok, dis, label),))

    # ---- 点一下：这一下要等**几分钟**（子进程），所以每条状态都得高频抓 -----
    # ⚠️ 抓法照抄 tests/ui_v168：100ms 一轮。`zip_job` 一旦非空，轮询那边的
    #    第一次 `invalidateLater(1000)` 至少要 1 秒后才跑，所以 busy 态**至少**
    #    存在 1 秒 —— 100ms 一轮是稳的。（上一版那条探针第一版就是"点完等 3 秒
    #    再量"，量到的全是"什么都没发生"，而它长得像"按钮根本没变"。）
    dl_path = os.path.join(C.OUT, "bg.zip")
    got, seen = None, {"dis": None, "lab": None, "busy_msg": None}
    try:
        with pg.expect_download(timeout=300000) as info:
            pg.locator("#chat-art_zip_ui button").first.click()
            t0 = time.time()
            # ① 先看状态：disabled + 「正在打包…」
            while time.time() - t0 < 20:
                st = read_btn(pg)
                if st[0] and st[1] is True and seen["dis"] is None:
                    seen["dis"] = st
                if "正在打包" in st[2] and seen["lab"] is None:
                    seen["lab"] = st
                if seen["dis"] is not None and seen["lab"] is not None:
                    break
                pg.wait_for_timeout(100)
            # ② 忙的时候**再点一下** —— 这是"连点两下"那个竞态。
            #    ⚠️ 不能 `locator.click()`：按钮此刻是 disabled 的，Playwright
            #       会一直等到超时（报的是"元素不可点"，看着像按钮坏了）。
            #       这里直接派发那个 input（= 第二下在 renderUI 更新之前到达），
            #       正是 `zip_start_bg()` 里那个忙判断要挡的东西。
            pg.evaluate("() => { if (window.Shiny) Shiny.setInputValue("
                        "'chat-art_zip', Math.random(), {priority:'event'}); }")
            for _ in range(30):
                nt = notif_texts(pg)
                hit = [t for t in nt if "正在打包" in t and "别关这个页面" in t]
                if hit:
                    seen["busy_msg"] = hit[0]
                    break
                pg.wait_for_timeout(100)
            # ③ 等它跑完 + 下载落地
            got = info.value
            got.save_as(dl_path)
    except Exception as e:
        ck("③ ★★ 转后台之后**真的**下下来一个包", False, str(e).splitlines()[0])
        pg.screenshot(path=os.path.join(C.OUT, "no_download_bg.png"),
                      full_page=True)
        return

    ck("③ ★ 点下去按钮**变 disabled**（不 disable = 用户以为没点上，会连点）",
       seen["dis"] is not None, "20 秒里一次都没看到 disabled")
    ck("③ ★ 而且文案变成「正在打包…（已 N 秒 · …）」—— 用户真正看见的东西",
       seen["lab"] is not None, "20 秒里一次都没看到「正在打包」")
    if seen["lab"]:
        print("      忙时文案：%r" % seen["lab"][2], flush=True)
    ck("③ ★★ 忙的时候再点一下会被挡下来（不挡 = 前一个包的句柄被冲掉）",
       seen["busy_msg"] is not None, "没看到「…别关这个页面」那句提示")

    ck("③ ★★ 转后台之后**真的**下下来一个包", True)
    print("      下载名：%s（%d 字节）"
          % (got.suggested_filename, os.path.getsize(dl_path)), flush=True)

    files, dirs = entries(dl_path)
    print("      包里的文件：%s" % files, flush=True)
    ck("③ ★★ 后台打出来的包里**两个根的东西都在**（这是跨进程那条路）",
       "analysis.R" in files and "差异基因 表.csv" in files and
       any(x.endswith("top10.png") for x in files), files)
    ck("③ 一共 %d 条真文件（和同步那条路**一模一样**）" % N_FILES,
       len(files) == N_FILES, "实际 %d 条：%s" % (len(files), files))

    # ---- 跑完必须恢复可点 --------------------------------------------------
    # ⚠️ 这条**必须**先要求"刚才真的 busy 过"（seen["dis"] is not None）。
    #    不加这个前提的话它在**旧代码上也会绿** —— 那些版本从头到尾就没
    #    disable 过，"变回可点"这个条件在第一轮就成立。（本仓老账：变异测试
    #    的变异可能是空转的。）
    # ⚠️ 而且要在**下载之后**再量：解锁那一步（zip_job(NULL)）和
    #    clickWhenReady 是同一条 observer 里先后发生的，早于下载落地量的话
    #    量到的是"还没来得及变"，看着像"按钮永远转着"。
    back, t0 = None, time.time()
    while time.time() - t0 < 60:
        st = read_btn(pg)
        if st[0] and st[1] is False and "正在打包" not in st[2]:
            back = st
            break
        pg.wait_for_timeout(200)
    ck("④ ★★ 跑完按钮自己变回可点（不恢复 = 用户以后再也点不动）",
       seen["dis"] is not None and back is not None,
       "先忙过=%s，恢复=%s，现在 %r"
       % (seen["dis"] is not None, back is not None, read_btn(pg)))
    pg.screenshot(path=os.path.join(C.OUT, "b_bg.png"), full_page=True)
    return s


# =============================================================================
# 「文件」页那张表。⚠️ 必须带 `:visible`：bslib 的 navset_hidden 把**每一页**
#   都留在 DOM 里，`#files-tbl` 在言出法随页也 query 得到 —— 不带 `:visible`
#   摸到的是隐藏表，量出来全是空的，而失败信息会指向"表里没这几行"。
#   （本仓账：`rows.count()` 把藏着的行也数进去 → "行数 1"看着像上传没成功。）
DT = ".dsapp-dt-nowrap:visible table.dataTable"


def dt_rows(pg):
    """文件页表里当前显示的行 → [(名称, 大小), ...]。

    列序（`R/mod_files.R` 的 `shown`）：0=「去预览」按钮 1=名称 2=大小
    3=修改时间 4=上传者 5=`_rel`（隐藏列）。
    """
    out = []
    for tr in pg.locator(DT + " tbody tr").all():
        tds = tr.locator("td")
        nm = " ".join((tds.nth(1).inner_text() or "").split())
        sz = " ".join((tds.nth(2).inner_text() or "").split())
        out.append((nm, sz))
    return out


def phase_files(pg, s):
    """⑤ 跨页比对：「文件」页那一侧读的是不是同一份展示字段。

    前面四段全在**对话页**上量。那些断言在"两页各画各的"的旧代码上**也可能
    全绿** —— 只要两处碰巧长得一样就看不出来。用户报的原话是

        「言出法随的文件页面和真正的文件管理页面文件不同步，那意味着你写了
          两套文件展示系统」

    所以这一段问的是**同一个东西在两个页面上是不是一个说法**：种子里那个
    文件区目录（`DIR`）在文件页这张表上，名称那一格必须带 📁 前缀、大小那一格
    必须写「—」。这两个字符串都由 `dsapp_files_rows()` 一处给（`dt_name` /
    `size_h`），对话页那张卡读的是同一份规则。
    """
    print("\n\033[36m== C 段：「文件」页那一侧（跨页同一个说法）==\033[0m", flush=True)
    d = s.get("DIR", "")
    C.goto(pg, "files")
    pg.wait_for_timeout(3000)
    rows = dt_rows(pg)
    ck("⑤ 文件页那张表出得来、且种出来的目录在里面（%d 行）" % len(rows),
       any(d and d in nm for nm, _ in rows),
       "找的是 %r，表里是 %r" % (d, [nm for nm, _ in rows]))
    hit = [(nm, sz) for nm, sz in rows if d and d in nm]
    if not hit:
        return
    nm, sz = hit[0]
    # ★★ 前缀是 📁（`dt_name`），不是名字本身 —— 文件页的目录靠它和文件区分。
    #    写死这个字面量是**故意的**：这条问的就是"共享出来的字段有没有真的画
    #    到这张表上"。⚠️ `span(a,b)` 的 innerText 是 `"# 1"` 不是 `"#1"`（本仓
    #    账），所以不要在 📁 和名字之间断言空格。
    ck("⑤ ★★ 文件页里这个目录的名字带 📁 前缀（%r）" % nm,
       nm.startswith("📁") and d in nm, nm)
    # ★★ 同一个目录，对话页那张卡上量到的是 `—`（B 段 ② 那条），这里也必须
    #    是 `—`。工作区那支原来给的是**真实字节数**（`20 B`），两页并排看就是
    #    "同样是文件夹，一个写 — 一个写 20 B"。
    ck("⑤ ★★ 文件页里这个目录的体积写「—」（%r）" % sz, sz == "—", sz)
    pg.screenshot(path=os.path.join(C.OUT, "c_files.png"), full_page=True)

    # ---- 进这个目录：里面的**文件**行大小必须是真数 ---------------------------------
    # ⚠️ 反面对照是必须的。只断言"根上那个目录写 —"的话，一个"整张表的大小都
    #    没算"的坏实现照样全绿 —— 而那种坏法用户一眼能看见（每个文件都是 —）。
    #    （本仓账：一条永远绿的断言和永远红的一样没用。）
    # 点「名称」那一格 = 进目录（`R/mod_files.R` 的 `tbl_cell_clicked` col==1）。
    try:
        pg.locator(DT + " tbody tr").filter(has_text=d).first \
          .locator("td").nth(1).click()
    except Exception as e:
        ck("⑤ 点得进这个目录（跨页比对要拿里面的文件当对照）", False,
           str(e).splitlines()[0])
        return
    pg.wait_for_timeout(2500)
    sub = dt_rows(pg)
    ck("⑤ 进目录之后能看到里面那 %d 个文件行（种子里同步过去的就是这些）"
       % len(sub), len(sub) >= 2, sub)
    ck("⑤ ★★ 里面**文件**行的大小是真数、不是「—」（%r）"
       % [x for _, x in sub][:4],
       bool(sub) and all(x and x != "—" for _, x in sub),
       "全是 — 的话说明「目录写 —」那条是被一个坏实现白送的")
    ck("⑤ ★ 里面的行**没有** 📁 前缀（进错层的话这条会红）",
       all(not nm.startswith("📁") for nm, _ in sub), [nm for nm, _ in sub])
    pg.screenshot(path=os.path.join(C.OUT, "c_files_in.png"), full_page=True)


def phase_files_bg(pg, s):
    """⑥ 「文件」页那侧的**转后台**：和对话页共用同一个 `zip_job` / 同一个子进程。

    ⚠️ 为什么非要在浏览器里再走一遍：R 那一侧 A8 已经证明
       `dsapp_bg_start("dsapp_zip_build", …)` 跨进程能打对包 —— 但那是**直接调
       函数**。文件页这条路上真正可能坏的是**接线**：
         * `selected_rows()` 选中的东西有没有真的喂进 `dsapp_zip_plan_multi()`；
         * `output$tbl_tools` 那颗按钮会不会跟着 `zip_job()` 变 disabled
           （它读 `zip_job()` 的那句**必须**是普通读、不能 isolate —— 两处一
           个 isolate 一个不 isolate 是有意的，写反了按钮就永远不 disable）；
         * `output$download` 那个出口拿的是不是 `job$dst`。
       这三条静态扫源码一条都验不到，而它们坏掉的样子都是"点了没反应"。
    """
    print("\n\033[36m== D 段：「文件」页那侧的转后台 ==\033[0m", flush=True)
    d = s.get("DIR", "")
    C.goto(pg, "files")
    pg.wait_for_timeout(3000)
    rows = dt_rows(pg)
    hit = [i for i, (nm, _) in enumerate(rows) if d and d in nm]
    if not hit:
        ck("⑥ 文件页找得到种出来的那个目录", False, [nm for nm, _ in rows])
        return
    # 进目录（点「名称」那一格）
    pg.locator(DT + " tbody tr").nth(hit[0]).locator("td").nth(1).click()
    pg.wait_for_timeout(2500)
    trs = pg.locator(DT + " tbody tr")
    n = trs.count()
    ck("⑥ 进了目录、里面那 2 个文件在（%d 行）" % n, n == 2, "实际 %d 行" % n)
    if n < 2:
        return
    # 勾选：点「大小」那一格（第 2 格）。⚠️ 不能点第 1 格 —— 名称列在目录上
    # 是"进目录"、在文件上是"挪预览指针"，都不产生勾选。
    for i in range(n):
        trs.nth(i).locator("td").nth(2).click()
        pg.wait_for_timeout(400)
    pg.wait_for_timeout(1200)
    lab0 = " ".join((pg.locator("#files-do_download").inner_text() or "").split())
    ck("⑥ 勾了两项之后按钮文案变成「打包下载（2 项）」（%r）" % lab0,
       "2" in lab0 and "打包" in lab0, lab0)
    ck("⑥ 而且现在是**可点**的（一直 disabled 的话下面那条白验）",
       pg.locator("#files-do_download").is_disabled() is False, lab0)

    dl_path = os.path.join(C.OUT, "d_files_bg.zip")
    got, seen = None, {"dis": None, "lab": None}
    try:
        with pg.expect_download(timeout=300000) as info:
            pg.locator("#files-do_download").click()
            t0 = time.time()
            while time.time() - t0 < 20:
                dis = pg.locator("#files-do_download").is_disabled()
                lab = " ".join(
                    (pg.locator("#files-do_download").inner_text() or "").split())
                if dis and seen["dis"] is None:
                    seen["dis"] = lab
                if "正在打包" in lab and seen["lab"] is None:
                    seen["lab"] = lab
                if seen["dis"] and seen["lab"]:
                    break
                pg.wait_for_timeout(100)
            got = info.value
            got.save_as(dl_path)
    except Exception as e:
        ck("⑥ ★★ 文件页点一下也**真的**下下来一个包", False, str(e).splitlines()[0])
        pg.screenshot(path=os.path.join(C.OUT, "d_fail.png"), full_page=True)
        return
    ck("⑥ ★ 点下去按钮变 disabled、文案变「正在打包…」（%r）" % (seen["lab"],),
       seen["dis"] is not None and seen["lab"] is not None,
       "忙过：disabled=%r label=%r" % (seen["dis"], seen["lab"]))
    ck("⑥ ★★ 文件页点一下也**真的**下下来一个包", True)
    files, _dirs = entries(dl_path)
    print("      包里的文件：%s" % files, flush=True)
    # ⚠️ 名字是**带目录前缀**的（`打包下载测试-…/analysis.R`），不是光秃秃的
    #    文件名 —— 文件页这条路的 root 是用户自己的文件区根，`zip::zip(root=)`
    #    就是按那个根拼路径的（老行为，V16.10 没动它）。所以断言用 basename
    #    比：写死整条路径的话，目录名里那个时间戳一变就红。
    base = [os.path.basename(x) for x in files]
    ck("⑥ ★★ 包里是刚勾的那两个（跨页同一个 dsapp_zip_build）",
       "analysis.R" in base and "sessionInfo.txt" in base, files)
    pg.screenshot(path=os.path.join(C.OUT, "d_files_bg.png"), full_page=True)


# =============================================================================
def main():
    root_bg = bg_data_root()
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        try:
            pg = b.new_page(viewport={"width": 1500, "height": 950})
            s = phase_sync(pg, C.URL, C.DATA_ROOT)
            # ★ C 段接在 A 段**同一个页面**上（同一个账号、同一份种子）——
            #   跨页比对要的就是"同一个东西"，另起一个账号种一份新的就没有
            #   可比性了。
            phase_files(pg, s or {})
            pg2 = b.new_page(viewport={"width": 1500, "height": 950})
            s2 = phase_bg(pg2, C.URL_BG, root_bg)
            # ★ D 段接在 B 段**同一个页面、同一份种子**上 —— 它问的是"文件页
            #   那一侧是不是也走同一条后台路"，换一份种子就没有可比性了。
            phase_files_bg(pg2, s2 or {})
        finally:
            b.close()
    return ck.done()


if __name__ == "__main__":
    sys.exit(main())
