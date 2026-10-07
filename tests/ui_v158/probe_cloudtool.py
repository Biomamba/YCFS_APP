#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.8 item 2：云工具页 —— 用户在浏览器里能不能真的把这条流水线跑完。

用户原话：「加一个云工具模块，第一个功能就是能够给这套流程的自动化分析提供
一个GUI，要求有流程的原理、功能介绍，让用户选好参数后可以直接运行、收获结果
并预览，并且能给用户提供进一步的建议」。

★ 为什么非要浏览器这一份（`tests/v158_cloudtool.R` 已经 60/60 了）：
  那一份证的是**纯函数和脚本**（命令拼得对不对、四步在 bash 里跑得通不通）。
  它对下面这些一个字都没说，而它们全是「函数对 ≠ 用户看得见」那一类：
    · `mod_cloudtool_ui()` 从没被求值过（页面树在 output$app_root 的
      renderUI 里，source 阶段一个字符都不会跑）；
    · 参数控件改了 → `P()` 读的是**控件**，这一跳没人验过；
    · 「开始运行」→ `engine$start()` → 任务行 → **下一拍提交下一步** ——
      四步是一条链，链条断在哪一环，界面上的症状都是「卡在第一步」；
    · 收货读的是磁盘上的 CSV，而画表读的是 `tick()`（不挂就会定格）；
    · 产物落在**哪个对话的工作区**（本仓栽过：落错对话，界面完全看不出来）。

四节：
  A 页面骨架：左栏那一项、五张卡、原理里那几个必须说到的词
  B 体检如实：八项齐全，桩环境下 env/ckpt/script 三项**通过**并显示桩路径
  C 真跑：建对话 → 放靶点 → 换档位 → 点「开始运行」→ 四步依次 done
        → 建议出来 → 指标表有行 → 磁盘上真有产物 → 「这个对话跑过的」有它
  D 阴性：一条请求都没打出去（base_url 指着假 LLM，req_n() 必须是 0）

⚠️ 这一份必须用 `tests/ui_v158/run_cloudtool.sh` 起实例（它装桩工具链 +
   四个环境变量）。直接 python3 跑的话，B 段会红在第一行上并**直接说**
   「实例没带 DSAPP_RFD3_ENV 起」—— 那是响的失败，不会伪装成功能坏了。

⚠️ 全程 base_url 指着本机假 LLM，一条请求都不会打到真厂商。
"""
import os
import re
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8951/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158i/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v158")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                          # noqa: E402
from playwright.sync_api import sync_playwright               # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]

STUB = os.path.join(os.path.dirname(C.APP), "cloudstub")
PDB_NAME = "target_pdl1.pdb"
N_DESIGN = 3          # 每个骨架 3 个设计（1 全过 / 1 差一点 / 1 读不出来）


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


def tbox(page, out):
    """某个 output 的可见文字（没有就回空串，别抛）。"""
    try:
        loc = page.locator(out)
        if not loc.count():
            return ""
        return loc.first.inner_text()
    except Exception:
        return ""


def rows(page, out):
    try:
        loc = page.locator("%s table tbody tr" % out)
        return [loc.nth(i).inner_text() for i in range(loc.count())]
    except Exception:
        return []


def pf_rows(page):
    """体检表逐行拆开。

    ⚠️ **不要拿图标字符去判通过与否**：那三个图标是 Font Awesome 的 <svg>，
       innerText 里一个字符都没有 —— `"✓" in row` 永远是 False，
       于是"全过"和"全红"看起来一模一样（本仓：判据要和已知会红的样本对一次）。
       真正的判据是**那行有没有 `→ 怎么办`**（只有不通过的行才画 fix）
       加上图标的 CSS 类。
    """
    return page.evaluate("""() => {
      const box = document.querySelector('#cloudtool-preflight_box');
      if (!box) return [];
      return Array.from(box.querySelectorAll('table tbody tr')).map(tr => {
        const tds = tr.querySelectorAll('td');
        const icon = tr.querySelector('td span');
        return {
          label: (tds[1] ? tds[1].innerText : '').trim(),
          detail: (tds[2] ? tds[2].innerText : '').trim(),
          fix: !!tr.querySelector('td div.text-muted'),
          cls: icon ? icon.className : '',
        };
      });
    }""")


def metric_rows(page):
    """指标表逐行拆成单元格（DT 画的，读 tbody）。"""
    return page.evaluate("""() => {
      const box = document.querySelector('#cloudtool-metrics');
      if (!box) return [];
      return Array.from(box.querySelectorAll('table tbody tr')).map(tr =>
        Array.from(tr.querySelectorAll('td')).map(td => td.innerText.trim()));
    }""")


def wait_for(page, fn, timeout=300, step=1000):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        page.wait_for_timeout(step)
    return False


def sql(db, q, args=()):
    import sqlite3
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def main():
    os.makedirs(C.OUT, exist_ok=True)
    log = open(os.path.join(C.OUT, "probe_cloudtool.log"), "w")
    t0 = time.time()

    def say(*a):
        s = "[%6.1fs] %s" % (time.time() - t0, " ".join(str(x) for x in a))
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    # 桩必须先在磁盘上 —— 实例是带着那几个环境变量起来的，probe 只负责核对
    # 界面上**显示出来的**就是这一套（见 B 段）。
    if not os.path.exists(os.path.join(STUB, "bin", "rfd3")):
        sys.exit("找不到桩工具链 %s。\n"
                 "  这一份要用 `bash tests/ui_v158/run_cloudtool.sh` 跑 —— "
                 "它负责造桩、并把 DSAPP_RFD3_ENV / DSAPP_FOUNDRY_CKPT /\n"
                 "  DSAPP_CLOUD_SCRIPT_DIR / DSAPP_EXEC_GPU 一起交给实例。"
                 % STUB)

    fx = C.FakeLLM()
    say("  假 LLM: %s（全程只打它；本探针预期 req_n 最后是 0）" % fx.url)

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        errs = []
        page.on("pageerror", lambda e: errs.append(str(e)[:300]))
        page.on("console",
                lambda m: errs.append("console.error: %s" % m.text[:300])
                if m.type == "error" else None)

        email = "v158cl_%s@example.com" % str(int(time.time()))[-6:]
        C.enter_app(page, email=email)
        uid, db = C.seed_or_die(email)
        say("  账号 uid=%s 落在 %s" % (uid, db))
        C.seed_llm(uid, fx.url)      # 万一有出网，也只可能打到假 LLM
        say("  已把 base_url 指向假 LLM")

        # ---------------------------------------------------------------- A
        say("")
        say("== A 页面骨架 ==")
        C.goto(page, "cloudtool", wait=3000)
        say("  切到 cloudtool 之后 body %d 字" % len(page.inner_text("body")))

        rail = page.locator(".dsapp-rail-link[data-nav=cloudtool]")
        chk("A1 左栏有「云工具」这一项（data-nav=cloudtool）",
            rail.count() == 1, "count=%d" % rail.count())
        chk("A2 它是**普通用户**可见的（没被 role 挡住）",
            rail.count() == 1 and rail.first.is_visible())

        body = page.inner_text("body")
        for kw in ["生成骨架", "设计序列", "复折叠", "汇总指标"]:
            chk("A3 四步里说到「%s」" % kw, kw in body)
        for kw in ["ipae", "ipTM", "pLDDT"]:
            chk("A4 判读口径里有「%s」" % kw, kw in body)
        chk("A5 说明 10 Å 只是**观察线**（不是成功阈值）",
            "观察线" in body and "10" in body)
        chk("A6 说清楚「拆成四个任务」跑（平台单槽/墙钟）",
            "四个任务" in body)
        heads = [page.locator(".card-header").nth(i).inner_text().strip()
                 for i in range(page.locator(".card-header").count())]
        for want in ["参数", "运行", "结果与建议", "这个对话跑过的"]:
            chk("A7 有「%s」这张卡" % want,
                any(want in h for h in heads), "cards=%r" % (heads,))

        chk("A8 没有对话时提示先去开一个对话",
            "开一个对话" in tbox(page, "#cloudtool-no_ws_hint"))
        chk("A9 没有对话时参数表单不出现（不误报成能跑）",
            tbox(page, "#cloudtool-form_box").strip() == "")

        # ---------------------------------------------------------------- B
        say("")
        say("== B 体检 ==")
        pf = pf_rows(page)
        say("  体检 %d 行：" % len(pf))
        for r in pf:
            say("    [%s] %s → %s" % (r["cls"].replace("small ", ""),
                                      r["label"], r["detail"][:90]))
        chk("B1 体检有 8 项（env/ckpt/input/contig/hotspot/script/gpu/wall）",
            len(pf) == 8, "n=%d" % len(pf))
        for sub in ["RFD3 工具链", "模型权重", "靶点结构", "contig", "热点",
                    "评估脚本", "GPU", "单步时间上限"]:
            chk("B2 体检里有「%s」这一项" % sub,
                any(sub in r["label"] for r in pf))

        # 桩路径必须**显示出来** —— 显示的不是桩路径的话，说明实例没带环境
        # 变量起，后面 C 段跑不动。这里直接停下并说清楚，别让它变成一串
        # 莫名其妙的红。
        envrow = [r for r in pf if "RFD3 工具链" in r["label"]]
        if not envrow or STUB not in envrow[0]["detail"]:
            page.screenshot(path=C.OUT + "/cloudtool_B_env.png", full_page=True)
            sys.exit(
                "实例没带桩工具链起：体检里「RFD3 工具链」那一行是\n  %r\n"
                "  期望里面出现 %s\n"
                "  用 `bash tests/ui_v158/run_cloudtool.sh` 重起实例。"
                % (envrow[0]["detail"] if envrow else "<没有这一行>", STUB))

        def get(sub):
            return [r for r in pf if sub in r["label"]]

        chk("B3 工具链那一项通过，绿图标（不是看着有、其实红的）",
            bool(get("RFD3 工具链")) and not get("RFD3 工具链")[0]["fix"]
            and "text-success" in get("RFD3 工具链")[0]["cls"],
            "%r" % (get("RFD3 工具链")[0] if get("RFD3 工具链") else None,))
        chk("B4 四份权重在桩目录里找到了（那一项不红、不说缺）",
            bool(get("模型权重")) and not get("模型权重")[0]["fix"]
            and "缺" not in get("模型权重")[0]["detail"],
            "%r" % (get("模型权重")[0] if get("模型权重") else None,))
        chk("B5 评估脚本那一项也找到了（桩的 evaluate_rf3.py）",
            bool(get("评估脚本")) and not get("评估脚本")[0]["fix"])
        chk("B6 靶点结构还没选 → 如实说「还没选」且标红",
            bool(get("靶点结构")) and "还没选" in get("靶点结构")[0]["detail"]
            and get("靶点结构")[0]["fix"],
            "%r" % (get("靶点结构")[0] if get("靶点结构") else None,))
        chk("B7 GPU 那一项通过（这台机器有卡 + 账号放行）",
            bool(get("GPU")) and "text-success" in get("GPU")[0]["cls"],
            "%r" % (get("GPU")[0] if get("GPU") else None,))
        chk("B8 墙钟那一项只是提示（warn），不拦路（没有 fix）",
            bool(get("单步时间上限")) and not get("单步时间上限")[0]["fix"])
        chk("B9 contig 与 length 相容那一项算出来了（不是一句未知）",
            bool(get("contig")) and "推出总长" in get("contig")[0]["detail"],
            "%r" % (get("contig")[0] if get("contig") else None,))

        # ---------------------------------------------------------------- C
        say("")
        say("== C 真跑四步 ==")
        C.goto(page, "chat", wait=2500)
        page.click("#chat-new_chat")
        page.wait_for_timeout(3000)
        sids = [page.locator(".dsapp-sess").nth(i).get_attribute("data-sid")
                for i in range(page.locator(".dsapp-sess").count())]
        chk("C1 建了一个对话", len(sids) >= 1, "sids=%r" % (sids,))
        sid1 = sids[0]
        say("  对话 1：%s" % sid1)

        # 把靶点放进这个对话的工作区。
        #
        # ⚠️ 这里**直接写盘**，走的是"用户上传过、而且跑过一次"之后的状态
        #    （executor.R 会把上传区镜像成工作区里的只读软链）。镜像本身是
        #    执行器的功能，别处已经验过；这一份要验的是"云工具页拿到一个
        #    真实存在的输入之后，能不能把它跑完"。
        ws1 = os.path.join(C.DATA_ROOT, "workspaces", "chat-%s" % sid1)
        os.makedirs(ws1, exist_ok=True)
        with open(os.path.join(ws1, PDB_NAME), "w") as fh:
            fh.write("HEADER    TEST TARGET\n"
                     "ATOM      1  N   ALA A  18      11.104  13.207  10.000"
                     "  1.00 50.00           N\nEND\n")
        say("  靶点写进 %s/%s" % (ws1, PDB_NAME))

        # 换一次对话再换回来 —— 表单里的文件下拉是 renderUI 出来的，
        # 只在 ws() 失效时重画。真实的用户也是这么做的（上传完切一下对话）。
        page.click("#chat-new_chat")
        page.wait_for_timeout(2500)
        n_sess = page.locator(".dsapp-sess").count()
        chk("C2 又建了一个对话（用来触发重画）", n_sess >= 2, "n=%d" % n_sess)
        row1 = page.locator('.dsapp-sess[data-sid="%s"]' % sid1)
        chk("C3 会话列表里还能找到对话 1", row1.count() == 1)
        if row1.count():
            row1.first.click()
            page.wait_for_timeout(3000)

        C.goto(page, "cloudtool", wait=3000)
        form = tbox(page, "#cloudtool-form_box")
        chk("C4 有了对话之后参数表单出现了", len(form) > 200,
            "len=%d" % len(form))
        chk("C5 表单里能选到刚放进去的靶点",
            PDB_NAME in form, "form=%r" % form[:300])
        chk("C6 没有工作区时那句提示收起来了",
            tbox(page, "#cloudtool-no_ws_hint").strip() == "")

        opts = page.evaluate(
            """() => Array.from(document.querySelectorAll(
                 'select#cloudtool-input_file option')).map(o => o.value)""")
        chk("C7 下拉候选里就是那个文件", opts == [PDB_NAME], "opts=%r" % (opts,))
        C.pick_select(page, "cloudtool-input_file", PDB_NAME)
        page.wait_for_timeout(1200)

        # 换档位 → 三个数量输入框被刷成那一档的值
        C.pick_select(page, "cloudtool-preset", "quick")
        page.wait_for_timeout(1500)
        vals = {k: page.input_value("#cloudtool-%s" % k)
                for k in ["n_batches", "diffusion_batch_size", "mpnn_seq"]}
        chk("C8 选「快速试跑」把三个数量框刷成 1（档位真的生效）",
            vals == {"n_batches": "1", "diffusion_batch_size": "1",
                     "mpnn_seq": "1"}, "%r" % (vals,))

        # 每个骨架出 3 个设计 —— 这样第 4 步的两套 CSV 各出 3 行
        # （1 全过 / 1 ipae 差一点 / 1 指标空白），才验得到"空值不当 0 分"
        # 这条判读口径在**浏览器里**也是对的。
        page.fill("#cloudtool-diffusion_batch_size", str(N_DESIGN))
        page.press("#cloudtool-diffusion_batch_size", "Tab")
        page.wait_for_timeout(1200)
        chk("C9 每批个数改成了 %d" % N_DESIGN,
            page.input_value("#cloudtool-diffusion_batch_size") == str(N_DESIGN))

        page.click("#cloudtool-check")
        page.wait_for_timeout(4000)
        pf2 = pf_rows(page)
        bad2 = [r for r in pf2 if r["fix"]]
        say("  体检：%d 行，红 %d 行 %r"
            % (len(pf2), len(bad2), [r["label"] for r in bad2]))
        chk("C10 填完参数后体检全过（没有标红的行）", not bad2)

        page.screenshot(path=C.OUT + "/cloudtool_C_before_run.png", full_page=True)
        say("  点「开始运行」")
        page.click("#cloudtool-run")

        def stopped():
            t = tbox(page, "#cloudtool-run_box")
            return "四步都跑完了" in t or "没跑成" in t or "被手动停" in t

        ok = wait_for(page, stopped, timeout=900, step=2000)
        rb = tbox(page, "#cloudtool-run_box")
        say("  run_box：%s" % rb.replace("\n", " / ")[:500])
        chk("C11 四步在 15 分钟内推进到终态", ok, rb[:300])
        chk("C12 四步全部成功（没有没跑成/被停）",
            ("四步都跑完了" in rb) and ("没跑成" not in rb)
            and ("被手动停" not in rb), rb[:300])

        tids = [int(x) for x in re.findall(r"#(\d+)", rb)]
        chk("C13 四个步骤各自有一个任务号", len(tids) >= 4, "tids=%r" % (tids,))
        rowsdb = []
        for tid in tids[:4]:
            r = sql(db, "SELECT status, lang, exit_code FROM tasks WHERE id = ?",
                    (tid,))
            rowsdb.append((tid, r[0] if r else None))
        say("  任务行：%r" % (rowsdb,))
        chk("C14 四个任务在库里都是 success 且退出码 0",
            len(rowsdb) == 4 and all(r and r[0] == "success" and r[2] == 0
                                     for _t, r in rowsdb), "%r" % (rowsdb,))
        chk("C15 任务的语言是 Bash（不是 R）",
            len(rowsdb) == 4 and all(r and r[1] == "Bash"
                                     for _t, r in rowsdb), "%r" % (rowsdb,))

        rn = tbox(page, "#cloudtool-result_note")
        say("  建议：%s" % rn.replace("\n", " / ")[:600])
        chk("C16 结果区给了建议（不是一句还没有结果）",
            len(rn) > 60 and "还没有结果" not in rn, "len=%d" % len(rn))
        chk("C17 建议里带着教学原文的立场（观察线 / 结合≠阻断）",
            ("观察线" in rn) or ("阻断" in rn), rn[:200])

        mr = metric_rows(page)
        say("  指标表 %d 行：%r" % (len(mr), mr[:2]))
        chk("C18 指标表里两套 MPNN 各 %d 条，共 %d 行"
            % (N_DESIGN, N_DESIGN * 2), len(mr) == N_DESIGN * 2,
            "rows=%d" % len(mr))
        if mr:
            hdr_txt = tbox(page, "#cloudtool-metrics")
            chk("C19 表里有那三个判读列（ipae / ipTM / pLDDT）",
                "ipae" in hdr_txt and "ipTM" in hdr_txt
                and "pLDDT" in hdr_txt)
            # 列序：通过/来源/设计/预测/ipae/ipTM/binder_pLDDT/状态/备注
            ipae = []
            for r in mr:
                try:
                    ipae.append(None if len(r) < 5 or r[4] == ""
                                else float(r[4]))
                except ValueError:
                    ipae.append(None)
            nn = [v for v in ipae if v is not None]
            chk("C20 ipae 非空的那几行是**非递减**的（排行榜真的排过）",
                nn == sorted(nn), "%r" % (ipae,))
            chk("C21 指标空白的那两条排在最后（空值没被当成 0 分抢第一名）",
                ipae[:len(nn)] == nn and all(
                    v is None for v in ipae[len(nn):]), "%r" % (ipae,))
            chk("C22 那两行的状态列写的是 error（不是 ok）",
                all(r[7] == "error" for r in mr[len(nn):]) if len(mr) > len(nn)
                else False, "%r" % ([r[7] for r in mr],))
            # ⚠️ 这里的期望值**不是**"一条都不过"：ipae 7.5 那两条三条线
            #    （10 Å / 0.6 / 70）全满足，本来就该打勾。真正要验的是
            #    「通过」这一列**跟着三条线的与**走：12.5 那条只差 ipae
            #    一条线，必须**不**打勾。写成"一条都不过"的话，判据会
            #    永远红（或者反过来，永远绿 —— 两种都等于没验）。
            marked = [(r[4], bool(r[0].strip())) for r in mr]
            chk("C23 「通过」那一列 = 三条观察线的与（7.5 打勾、12.5 不打）",
                all((v == "7.5") == m for v, m in marked),
                "%r" % (marked,))
            chk("C24 打勾的正好是两条（两套 MPNN 各一条）",
                sum(1 for _v, m in marked if m) == 2, "%r" % (marked,))

        # 磁盘上真有产物，而且落在**这个对话**的工作区里
        cloud_dir = os.path.join(ws1, "cloud")
        runs = sorted(os.listdir(cloud_dir)) if os.path.isdir(cloud_dir) else []
        chk("C25 产物目录落在对话 1 的工作区里（<ws>/cloud/<任务名>-<时间>）",
            len(runs) == 1, "runs=%r" % (runs,))
        if runs:
            root = os.path.join(cloud_dir, runs[0])
            n_cif = sum(1 for _r, _d, fs in os.walk(root) for f in fs
                        if f.endswith(".cif"))
            n_csv = sum(1 for _r, _d, fs in os.walk(root) for f in fs
                        if f.endswith(".csv"))
            yml = [f for _r, _d, fs in os.walk(root) for f in fs
                   if f.endswith(".yaml")]
            chk("C26 磁盘上有骨架和预测结构（%d 个 .cif）" % n_cif,
                n_cif >= N_DESIGN * 3)
            chk("C27 两套 MPNN 的指标 CSV 都写出来了（%d 个）" % n_csv,
                n_csv == 2)
            chk("C28 这次生效用的 yaml 留在磁盘上（能对账）", len(yml) == 1,
                "%r" % (yml,))
            # 第一步行里的货真价实：rfd3 目录里就该有 N_DESIGN 个骨架
            rfd3_dir = os.path.join(root, "rfd3", "outputs")
            got = sum(len([f for f in fs if f.endswith(".cif")])
                      for _r, _d, fs in os.walk(rfd3_dir)) \
                if os.path.isdir(rfd3_dir) else -1
            chk("C29 RFD3 那一步真的产出了 %d 个骨架" % N_DESIGN,
                got == N_DESIGN, "got=%d" % got)

        sd = os.path.join(ws1, ".dsapp_cloud")
        st_files = os.listdir(sd) if os.path.isdir(sd) else []
        chk("C30 运行存档写在对话 1 的工作区里", len(st_files) == 1,
            "%r" % (st_files,))
        # 只看**这个账号的**对话 —— 实例是复用的，workspaces/ 底下还留着
        # 之前几轮探针建的账号的目录，把那些算进来就是一条永远红的假断言。
        mine = [r[0] for r in sql(db, "SELECT id FROM sessions WHERE user_id = ?",
                                 (uid,))]
        stray = []
        wroot = os.path.join(C.DATA_ROOT, "workspaces")
        for s in mine:
            d = "chat-%s" % s
            if d != "chat-%s" % sid1 \
                    and os.path.isdir(os.path.join(wroot, d, "cloud")):
                stray.append(d)
        chk("C31 别的对话的工作区里没有这次运行的目录（落错对话是静默的）",
            not stray, "%r" % (stray,))

        rbox = tbox(page, "#cloudtool-runs_box")
        chk("C32 「这个对话跑过的」里列着这次运行",
            bool(runs) and runs[0] in rbox, "rbox=%r" % rbox[:200])

        real = [e for e in errs if "favicon" not in e]
        chk("C33 全程没有 JS 报错", not real, "%r" % (real[:3],))

        # ---------------------------------------------------------------- D
        say("")
        say("== D 阴性 ==")
        chk("D1 一条请求都没打到假 LLM（更没到真厂商）", fx.req_n() == 0,
            "req_n=%d" % fx.req_n())

        page.screenshot(path=C.OUT + "/cloudtool_D_done.png", full_page=True)
        say("")
        say("通过 %d / 失败 %d" % (N_OK[0], N_BAD[0]))
        browser.close()
        fx.stop()
        log.close()
        return 0 if N_BAD[0] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
