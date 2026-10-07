# -*- coding: utf-8 -*-
"""V16.9：产物同步不再静默丢弃 / 「导入对话产物」真的补得回来。

跑法（实例先起好）：
    bash tests/ui_v7/make_instance.sh 8979 /tmp/dsapp_v168a
    python3 tests/ui_v168/probe_syncrepair.py

用户原话：「Biomamba_ceshi 页面里，对话页面的文件展示的是全的，但是文件区的
         文件几乎没有，点同步也没用」。

为什么非得上浏览器 —— 这一版 R 那一侧已经有 32 条真行为断言
（`tests/v168_syncfix.R` A1–A7，含盘上核对），下面这几条它一条都验不到：

  A. 按钮**真的**变 disabled、真的出现「正在补齐…」、跑完真的**变回**可点
     —— 少了任何一样，用户看到的就是"点了没反应"或者"按钮永远转着"。
     （`disabled` 是在 renderUI 里算的，静态扫源码看不出它有没有生效。）
  B. 补齐完成那句提示**真的弹出来**、而且报的数是对的 —— 这是整个 V16.9
     的立意（"不再静默"）唯一能被用户看见的地方。
  C. ★★ **界面真的画出来了**：进同步文件夹按名称倒排，第一行必须从
     `seed_0300.txt` 变成 `seed_0360.txt`。库里对了不代表画出来了
     （本仓有账：renderUI 没读失效源 → 写库成功但页面不动）。
  D. 而且**同一个量**在点按钮之前先量一遍（那时它必须是旧的那个值）——
     这样"缺口存在"和"缺口被补上"是同一个视图里的前后两帧，不是一个
     只测了结果、永远绿的量。

⚠️⚠️ 缺口必须由 `seed_overlimit.R` **真调 `dsapp_sync_artifacts()`** 种出来，
   不能在探针里自己往 `data/files/` 拷文件。原因写在那份脚本的头注释里：
   自己拷出来的"缺"缺的恰好是 `sync_dirs` 那一行，而**那一行是这道题的
   全部关键** —— 那样种出来的场景在**旧代码上也是绿的**，整条探针会变成
   "验了个空气"。
"""
import os
import re
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ck = C.Chk()


# =============================================================================
# 库（只读）
# =============================================================================
def q1(sql, args=()):
    con = sqlite3.connect("file:%s?mode=ro" % C.db_path(), uri=True)
    try:
        r = con.execute(sql, args).fetchone()
        return r[0] if r else None
    finally:
        con.close()


def pub_n(sid):
    """这个对话在 `ws_published` 里有多少行 —— 和文件区里"曾经同步过什么"同义。"""
    return q1("SELECT count(*) FROM ws_published WHERE session_id = ?", (sid,))


# =============================================================================
# 种超限场景
# =============================================================================
def run_seed(n_extra):
    """跑 seed_overlimit.R，把 `KEY=VALUE` 那几行解析成 dict。

    ⚠️ 必须 `--no-environ`：仓库根那份 `.Renviron` 指着**生产库**，而 Rscript
       会读 **cwd** 的 `.Renviron` 并**盖掉**继承的环境变量（本仓为此在生产
       库里种过东西）。`--no-environ` 之后 data_root 只由命令行给。
    """
    scr = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "seed_overlimit.R")
    p = subprocess.run(
        ["Rscript", "--no-environ", scr, C.APP, C.DATA_ROOT, C.LAST_EMAIL,
         str(n_extra)],
        capture_output=True, text=True, cwd=ROOT)
    sys.stdout.write(p.stdout)
    if p.returncode != 0:
        sys.exit("seed_overlimit.R 退出码 %d：\n%s" % (p.returncode, p.stderr[-2000:]))
    out = {}
    # ⚠️ 字符类里**要有下划线**：`[A-Z]+` 抓不到 `ON_DISK=`（它会在 `_` 上
    #    断掉，那一行一个 match 都没有）—— 症状是下面 KeyError，报的位置
    #    离真正的原因（正则写窄了）只差一行，也算好找。
    for k, v in re.findall(r"^([A-Z_]+)=(.*)$", p.stdout, re.M):
        out[k] = v.strip()
    if "SID" not in out:
        sys.exit("seed_overlimit.R 没打出 SID，stdout：\n%s" % p.stdout[:2000])
    return out


def relogin(pg, email):
    """reload 之后把自己弄回主界面（**不能**用 wait_awake，它只认 .dsapp-auth）。

    ⚠️ 这里非换一个会话不可：`seed_overlimit.R` 是**另一个进程**往库里写的，
       当前这个 Shiny 会话对那几行一无所知。
    """
    pg.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if pg.locator(".dsapp-shell").count():
            return True
        if not submitted and pg.locator("#welcome-email").count():
            pg.fill("#welcome-email", email)
            pg.fill("#welcome-password", C.PW)
            pg.click("button:has-text('登录')")
            submitted = True
        pg.wait_for_timeout(1000)
    return False


# =============================================================================
# 界面量取
# =============================================================================
NAME_COL = 1     # 表里：0 = 全选框、1 = 名称、2 = 大小……（见 R/mod_files.R 的 shown）


def enter_folder(pg, dirname):
    """点「名称」单元格进那个同步文件夹（`tbl_cell_clicked` 的 col == 1 那一支）。

    ⚠️ 进不去就**红**，不许跳过 —— 后面"界面画出来了没有"全靠它。
    """
    rows = pg.locator("#files-tbl tbody tr")
    for i in range(rows.count()):
        if dirname in (rows.nth(i).inner_text() or ""):
            rows.nth(i).locator("td").nth(NAME_COL).click()
            pg.wait_for_timeout(2500)
            return True
    return False


def sort_name_desc(pg):
    """按「名称」列倒排。

    ⚠️ 为什么要排：这张表的 `dom = "tp"`（R/mod_files.R）—— **没有 info
       元素**，读不到"共 N 条"，每页又只有 12 行。所以要问"最新那批在不在"
       就得让最新那批出现在第一页上。
    ⚠️ 点两下 = 升 → 降。点完**不假定**它生效：调用方拿第一行的名字说话，
       排错了第一行就会是 `seed_0000.txt`，那两种红一眼分得开。
    """
    th = pg.locator("#files-tbl thead th").nth(NAME_COL)
    for _ in range(3):
        try:
            if th.get_attribute("aria-sort") == "descending":
                break
        except Exception:
            pass
        th.click()
        pg.wait_for_timeout(600)
    pg.wait_for_timeout(800)


def first_row_name(pg):
    """倒排之后第一行的「名称」列。取不到就返回 None（调用方报红，不跳过）。"""
    try:
        rows = pg.locator("#files-tbl tbody tr")
        if rows.count() == 0:
            return None
        return (rows.first.locator("td").nth(NAME_COL).inner_text() or "").strip()
    except Exception:
        return None


def notif_texts(pg):
    """当前挂在右下角的通知文本。"""
    try:
        return [t for t in pg.locator(".shiny-notification").all_inner_texts() if t]
    except Exception:
        return []


def _read_btn(loc):
    if loc.count() == 0:
        return (False, None, "")
    try:
        dis = loc.first.is_disabled()
    except Exception:
        dis = None
    return (True, dis, (loc.first.inner_text() or "").strip())


def btn_new(pg):
    """本版那个按钮：`output$import_ws_ui` 用 renderUI 画出来的。

    ⚠️ 这个 id 是**本版才有**的东西。V16.8 的按钮是 UI 函数里一个静态的
       `tags$button`，`#files-import_ws_ui` 那个节点根本不存在 —— 所以下面
       "按钮在"那一条在旧代码上**红**，而那是正确的结果（"后台 + 进度"这件事
       在那一版里不存在）。
    """
    return _read_btn(pg.locator("#files-import_ws_ui button"))


def btn_any(pg):
    """**能点到**的那个按钮：本版按 id 找，旧版退回按文字找。

    ⚠️ 为什么要有这个退回：拿这条探针去跑**上一版归档**做对照时，只认 id 的话
       会直接 `Locator.click: Timeout` 崩掉 —— 于是对照组只能证明"没有这个
       元素"，证明不了"**点了也没用**"。而后者才是用户报的那一句，也是这条
       探针存在的理由。既然要点，就得点到旧的那个按钮上。
       （新代码上两种找法指向同一个按钮，不影响本版的断言。）
    """
    b = pg.locator("#files-import_ws_ui button")
    if b.count() == 0:
        b = pg.locator("button:has-text('导入对话产物')")
    return _read_btn(b)


# =============================================================================
def main():
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1500, "height": 950})
        try:
            email = C.enter_app(pg)
            uid, _db = C.seed_or_die(email)
            ck("⓪ 注册的新账号落在**这个实例的**库里（uid=%d）" % uid, uid > 0)

            # ★ 版本号兜底：连错实例的话这一条比"某个选择器找不到"先红，
            #   而且报的是真正的原因（本仓有账：截图脚本连到上一版实例上，
            #   拍出来的"新版界面"其实是老界面）。
            foot = pg.inner_text("body")
            ck("⓪ ★ 页脚版本是 Test_V16.9（连错实例时这条才是真的原因）",
               "Test_V16.9" in foot,
               "页面文字里找不到 Test_V16.9")

            # ---- 种一个真撞过上限的对话 -------------------------------------
            N_EXTRA = 60          # → 360 个产物，前 300 进得去、后 60 被静默刷掉
            s = run_seed(N_EXTRA)
            sid, n_gen = s["SID"], int(s["GEN"])

            def _int(k):
                """夹具打的是 `NA` 时给 None，不要炸。

                ⚠️ V16.8 上 `BLOCKED` 就是 NA —— 那一版的
                   `dsapp_sync_artifacts()` 根本没有 `blocked` 字段。夹具如实
                   打 NA，让**这条断言**去红（"旧代码里这件事不存在"），
                   而不是让探针在解析那一行崩溃（那看起来像夹具坏了）。
                """
                v = (s.get(k) or "").strip()
                return int(v) if v.lstrip("-").isdigit() else None

            n_pub, n_blk, on_disk = _int("PUB"), _int("BLOCKED"), _int("ON_DISK")
            sdir = s["DIR"]
            # ⚠️ 文件名是 **1-based** 的（`seq_len(n_gen)` → seed_0001..seed_0360）。
            #    写成 `n_gen - 1` 的话期望值是 seed_0359，而真值是 seed_0360
            #    —— 那两条会红，且看起来像"界面没重画"，其实只是我数错了下标。
            last = "seed_%04d.txt" % n_gen
            max_pub = "seed_%04d.txt" % n_pub

            ck("① 种出来的场景**真的撞了上限**（%d 个产物、只同步进 %s 个、被挡 %s 个）"
               % (n_gen, n_pub, n_blk),
               n_blk == N_EXTRA and n_pub == n_gen - N_EXTRA and on_disk == n_pub,
               "GEN=%d PUB=%s BLOCKED=%s ON_DISK=%s"
               % (n_gen, n_pub, n_blk, on_disk))
            ck("① ★ 库里的行数和盘上一致（这道题的基线）",
               pub_n(sid) == n_pub,
               "ws_published=%s 期望 %d" % (pub_n(sid), n_pub))
            ck("① ★ 被挡下的是**字母序最后那批**（所以下面倒排第一行就是判据）",
               max_pub < last, "max_pub=%s last=%s" % (max_pub, last))

            if not relogin(pg, email):
                sys.exit("重新登录失败，后面的界面断言没法量")
            ck("① 重新登录（换一个会话，让服务端看见刚种的那几行）", True)

            # ---- 进文件页，钻进那个同步文件夹 ---------------------------------
            C.goto(pg, "files")
            C.ensure_no_modal(pg)
            pg.wait_for_selector("#files-tbl", timeout=30000)
            pg.wait_for_timeout(2000)
            ck("② ★ 点「名称」进了同步文件夹 %s（进不去 = 下面每条都量不到）" % sdir,
               enter_folder(pg, sdir))

            # ★★ 点按钮**之前**先量一遍：这时第一行必须是"已发布里最大的那个"。
            #    这一条同时验两件事 —— 缺口在界面上真的看得见；倒排真的生效
            #    （排错了第一行会是 seed_0000.txt，报出来一眼分得开）。
            sort_name_desc(pg)
            before = first_row_name(pg)
            ck("② ★★ 补齐前：倒排第一行是「%s」——缺口在界面上看得见，且倒排生效"
               % max_pub,
               before == max_pub, "实际是 %r" % before)

            # ---- 点「导入对话产物」 ------------------------------------------
            ck("③ 按钮在（**本版**那个 renderUI 画出来的）", btn_new(pg)[0],
               "没有 #files-import_ws_ui —— 旧版是静态按钮，没有这个 output")
            ck("③ 点之前按钮是**可点**的（一直禁用的话下面那条白验）",
               btn_any(pg)[1] is False, "state=%r" % (btn_any(pg),))

            pg.locator("#files-import_ws_ui button, "
                       "button:has-text('导入对话产物')").first.click()
            # ⚠️⚠️ 这里**必须高频盯着抓**，不能点完等 3 秒再量。
            #    第一次就是那么写的，`③` 红成 (True, False, '导入对话产物') ——
            #    看着像"按钮根本没变 disabled"，其实**补齐只花了 1 秒**，
            #    那 1 秒的窗口在我量之前就过去了（而同一次运行里 ④⑥ 全都证明
            #    补齐真的跑了：库 300→360、盘 360、提示「已补齐 60 个文件」）。
            #    "没量到"和"没发生"长得一模一样 —— 本仓为这类事记过好几次账。
            #    窗口有多长是可推的：`sync_job` 一旦非空，轮询那边的第一次
            #    `invalidateLater(1000)` 至少要 1 秒后才跑，所以 busy 态**至少**
            #    存在 1 秒。100ms 一轮，稳的。
            seen_dis, seen_lab, t0 = None, None, time.time()
            while time.time() - t0 < 8:
                st = btn_any(pg)
                if st[0] and st[1] is True and seen_dis is None:
                    seen_dis = st
                if "正在补齐" in st[2] and seen_lab is None:
                    seen_lab = st
                if seen_dis is not None and seen_lab is not None:
                    break
                pg.wait_for_timeout(100)
            ck("③ ★ 点下去按钮**变 disabled**（不 disable = 用户以为没点上，会连点）",
               seen_dis is not None, "8 秒里一次都没看到 disabled")
            # ⚠️ 和上面拆成两条：合成一条的话，NA/NULL 那个属性写坏了（只剩
            #    文案在变）和整个 renderUI 没跟上，报出来是同一句话。
            ck("③ ★ 而且文案变成「正在补齐…」（这才是用户真正看见的东西）",
               seen_lab is not None, "8 秒里一次都没看到「正在补齐…」")

            # ---- 等它跑完（给足 3 分钟；正常是秒级）----------------------------
            done_at, t0 = None, time.time()
            while time.time() - t0 < 180:
                pg.wait_for_timeout(1000)
                st = btn_any(pg)
                if st[0] and st[1] is False and "正在补齐" not in st[2]:
                    done_at = time.time() - t0
                    break
            # ⚠️ 这条**必须**先要求"刚才真的 busy 过"（`seen_dis is not None`）。
            #    不加这个前提的话它在**旧代码上也会绿**：V16.8 的按钮从头到尾
            #    就没 disable 过，于是"变回可点"这个条件在第一轮就成立 ——
            #    一条永远绿的断言，长得像验过了"按钮会恢复"。
            #    （本仓老账：变异测试的变异可能是空转的。）
            ck("④ ★★ 补齐跑完、按钮自己变回可点（不恢复 = 用户以后再也点不动）",
               seen_dis is not None and done_at is not None,
               ("先忙过=%s，恢复=%s，现在 %r"
                % (seen_dis is not None, done_at is not None, btn_any(pg))))
            if done_at is not None:
                print("      （后台补齐用了 %.0f 秒）" % done_at, flush=True)

            # ---- 那句提示 -----------------------------------------------
            # ⚠️ 这是 V16.9「不再静默」唯一被用户看见的地方。通知默认 8 秒，
            #    上面那个循环最多等 180 秒，所以这里**可能已经过期** —— 过期
            #    时下面的 ⑤ ⑥ 两条照样成立（界面 + 库都验了），这里只报出来。
            nt = notif_texts(pg)
            hit = [t for t in nt if "补齐" in t]
            if hit:
                ck("④ ★ 完成提示弹出来了，而且报的是「已补齐 %d 个文件」" % n_blk,
                   any(("已补齐 %d 个文件" % n_blk) in t for t in hit),
                   "实际提示：%r" % hit)
            else:
                print("      ⚠️ 通知已经过期（默认 8 秒），这一条按「没赶上」记 ——"
                      " 下面 ⑤⑥ 才是硬判据", flush=True)

            # ---- ★★ 界面真的画出来了吗 ------------------------------------
            C.goto(pg, "files")          # 回来还是那个文件夹（current_dir 在服务端）
            pg.wait_for_timeout(2500)
            sort_name_desc(pg)
            after = first_row_name(pg)
            ck("⑤ ★★ 补齐后：倒排第一行变成「%s」——界面真的重画了" % last,
               after == last, "实际是 %r" % after)

            # ---- 库 / 盘 --------------------------------------------------
            ck("⑥ ★ 库里 ws_published 从 %d 变成 %d" % (n_pub, n_gen),
               pub_n(sid) == n_gen, "现在 %s" % pub_n(sid))
            d = os.path.join(C.DATA_ROOT, "files", "u%d" % uid, sdir)
            n_disk = len(os.listdir(d)) if os.path.isdir(d) else -1
            ck("⑥ ★ 盘上真是 %d 个文件（库说了不算，得数）" % n_gen,
               n_disk == n_gen, "盘上 %d 个：%s" % (n_disk, d))
            # ⚠️ 这一条把三种"没写进去"分开报：库没写 / 盘没写 / 界面没画。
            ck("⑥ ★★ 三个数（界面 / 库 / 盘）指向同一个结论",
               after == last and pub_n(sid) == n_gen and n_disk == n_gen,
               "界面 %r / 库 %s / 盘 %d" % (after, pub_n(sid), n_disk))

            pg.screenshot(path=os.path.join(C.OUT, "v168_syncrepair.png"),
                          full_page=True)
        finally:
            pg.wait_for_timeout(500)
            b.close()
    return ck.done()


if __name__ == "__main__":
    sys.exit(main())
