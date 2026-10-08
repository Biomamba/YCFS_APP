# -*- coding: utf-8 -*-
"""给 V17.1 那 `.skills 不算产物` 的 4 条断言做变异测试。

    python3 tests/ui_v171/mut_skills_internal.py            # 跑全部（约 10 分钟，5 个进程并行）

## 为什么非要单独做这一遍

V17.1 修的是 `dsapp_ws_is_internal()` 漏了 `.skills` —— 一个**纯谓词**的洞。
这类修复最容易自欺：断言写成 `dsapp_ws_is_internal(".skills/x")` 就全绿了，
而真正出事的是**调用点**（`dsapp_ws_artifacts()` / `build_file_section()`）
有没有去调它。谓词全绿 + 调用点漏一个，屏幕上和"修好了"长得一模一样。

所以 4 个变异里有 2 个（M3/M4）**完全不碰谓词**，只把某一个调用点的过滤
拆掉 —— 它们是用来证明"端到端那两条断言不是谓词那两条的复读机"的。

## A_GUARD 那条为什么不是 A_ART 的复读机

A_ART 只建 `.skills`；A_GUARD 把四个内部点目录都建出来，而且 `.Rlib` / `.venv`
的名字是**现问 getter**（`dsapp_ws_rlib()` / `dsapp_ws_venv()`）的。

* 拆调用点（M3）→ 两条一起红，**这是应该的**（过滤坏了，谁都漏）；
* 但**把 getter 里的 `.Rlib` 改名成 `.renv`**：谓词不会跟着变 ⇒ A_GUARD 红、
  A_ART 照样绿。那正是 2026-10-08 这次漏掉 `.skills` 的形状 ——
  **手写的黑名单 + 加了目录没加表**，所以专门留了一条盯改名。

## 两条纪律（都是这个仓库栽过的）

1. **只在 /tmp 副本里改**。开发目录就是生产目录，在仓库里"改坏一下试试"
   等于把线上改坏。脚本跑完会逐文件 sha256 核对仓库一个字节没动。
2. **预期红名单先写死**，跑完比对：
     * 预期该红的没红 → 探针没劲（断言是死的）；
     * 预期不该红的红了 → 变异打歪了（改到了别处），或者改动有连带。
   两个方向都要报出来，不能只看"红了就行"。

## 副本上那两条**已知的**红（不是本版引入的）

副本里 `deploy_link.sh --check` 会拿自己的 `$SRC`(=副本路径) 跟
`/srv/shiny-server/YCFS_APP` 比，副本天然不是线上那个目录 ⇒ 下面这两条
在**基线**上就是红的。脚本把它们设成基线，再用**差集**判每一个变异
（本仓规矩：旧探针红了先分清是哪一版弄的，比差集，别凭印象）。
"""
import io
import hashlib
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

REPO = "/data3/biomamba/analysis/DS_App"
BASE = "/tmp/mutskills"

# 副本上**可能**红、但和本版无关的两条：`deploy_link.sh --check` 在副本里
# 拿自己的路径跟 `/srv/shiny-server/YCFS_APP` 比，副本天然不是线上那个目录。
# ⚠️ 实测这两条**不是每次**都红（第一版副本红、第二版副本全绿，两份日志逐条
#    diff 只差一个耗时数字 0.018 vs 0.016）⇒ 基线**少于**这个是正常的，
#    多出来才要中止。
KNOWN_BASE_RED = {
    "★★ 部署时认得出一条「还活着的旧地址」，并说明会删掉它",
    "★ 指向别处的旧地址不碰（只删自己建的那条别名）",
}

# ★ 已观测到的**易飘**断言：2026-10-08 只有 M3 那次红了，而它俩在
#   `section("每对话增量库（阶段 1.4）")`（selftest.R:1641/1684），离本版动的
#   那一节（L4447，`section("工作区镜像")`）**2800 行**，夹具也完全不同
#   （`dsapp_ws_rlib(sidA)` vs `mwd`/`mwsid`）。M3 的变异只让
#   `.skills/` 打头的路径多进一次产物清单，**够不着 `.Rlib` 的内容**。
#   ⇒ 判为并发/环境导致的飘，不算在本版头上 —— 但**照报不误**，
#   而且一旦它在**多个**变异里出现，就说明这个判断错了，要重新查。
UNRELATED_FLAKY = {
    "install.packages() 不指定 lib 就装进对话库",
    "重建前 .Rlib 里有东西",
}

# 本版的 4 条断言（预设红名单里用得到；名字要和 selftest.R 里逐字一致）。
# ⚠️ 这 4 条是 `diff -u` 两份归档的 selftest.R 数出来的（2 个 hunk / 4 行 chk），
#    不是估的 —— 本文件原来写「5 条」，把 1 条**扩展**和 2 条端到端数重了。
A_PRED = "★ .Rlib / .venv / .pylib / .skills / .dsapp_* 都不算产物"
A_SEG = "★ `.skills` 是整段判、且子层同样命中（写成 startsWith 会误伤 my.skills）"
A_ART = "★★ 建出 `.skills/` 之后产物清单**一个都没多**（多了就会被补齐发进文件管理区）"
A_PRM = "★★ 模型看到的「本对话已有文件」同样不列 `.skills/`"
A_GUARD = "★★ 四个内部点目录全建出来（两个名字是问 getter 要的），产物清单仍然一个都没多"

# 本版改过的三个文件（跑完核对它们没被动过）
GUARD = ["R/executor.R", "R/skills.R", "selftest.R", "R/prompts.R",
         "R/envs.R", "R/config.R"]

MUTS = [
    dict(
        key="M1",
        desc="内部目录表里把 `.skills` 去掉（= V17.1 修复前的状态）",
        path="R/executor.R",
        old='any(seg %in% c(".Rlib", ".venv", ".pylib", ".skills") |',
        new='any(seg %in% c(".Rlib", ".venv", ".pylib") |',
        want_red=[A_PRED, A_SEG, A_ART, A_PRM, A_GUARD],
    ),
    dict(
        key="M2",
        desc="`.skills` 改用 startsWith 而不是整段配（`.skillsx` 会被误伤）",
        path="R/executor.R",
        old='any(seg %in% c(".Rlib", ".venv", ".pylib", ".skills") |\n'
            '          startsWith(seg, ".dsapp_"))',
        new='any(seg %in% c(".Rlib", ".venv", ".pylib") |\n'
            '          startsWith(seg, ".dsapp_") | startsWith(seg, ".skills"))',
        want_red=[A_SEG],
    ),
    dict(
        key="M3",
        desc="谓词不动，只把 `dsapp_ws_artifacts()` 的过滤拆掉（调用点漏了）",
        path="R/executor.R",
        old="  fs <- fs[!dsapp_ws_is_internal(fs)]",
        new='  fs <- fs[!dsapp_ws_is_internal(fs) | startsWith(fs, ".skills/")]',
        want_red=[A_ART, A_GUARD],
    ),
    dict(
        key="M5",
        desc="谓词不动，把 getter 里的 `.Rlib` 改名成 `.renv`（黑名单跟不上的形状）",
        path="R/envs.R",
        old='  if (is.na(ws)) return(NA_character_)\n  file.path(ws, ".Rlib")',
        new='  if (is.na(ws)) return(NA_character_)\n  file.path(ws, ".renv")',
        # ★ A_GUARD 该红：它就是拿 getter 的返回值去问谓词的。
        #   A_ART 只建 `.skills`，够不着这个改名 ⇒ A_ART **照样绿** ——
        #   这条**就是**在验"A_GUARD 不是 A_ART 的复读机"这句话本身。
        #
        # ⚠️ 下面那三条是**同一个变异的正确连带**，不是打歪（2026-08-10 实测的，
        #    原来只写了 A_GUARD，跑出来报"预期之外红了"）。机理：改名之后
        #    `dsapp_rlib_ensure()` 建出来的是 `.renv`，而谓词里写的还是 `.Rlib`
        #    ⇒ `.renv` 不算内部目录 ⇒ 它**真的**进了产物清单和提示词。
        #    也就是说这三条红得有道理：
        #      · 「R 库路径落在对话工作区里」——它比的就是字面量 `.Rlib`
        #      · 「产物里只有真的产物」——`.renv` 冒出来了（这正是产物清单该有的反应）
        #      · 「提示词说 R 库已创建」——提示词跟着实际目录改口成 `.renv`
        want_red=[A_GUARD,
                  "R 库路径落在对话工作区里",
                  "产物里只有真的产物",
                  "提示词说 R 库已创建"],
    ),
    dict(
        key="M4",
        desc="谓词不动，只把 `build_file_section()` 的过滤拆掉（模型那份清单漏了）",
        path="R/prompts.R",
        old="    own <- own[!dsapp_ws_is_internal(own)]",
        new='    own <- own[!dsapp_ws_is_internal(own) | startsWith(own, ".skills/")]',
        want_red=[A_PRM],
    ),
]

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def make_copy(dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(REPO, dst,
                    ignore=shutil.ignore_patterns("data", "history_Version",
                                                  ".Renviron", "*.log",
                                                  "__pycache__"),
                    symlinks=True)
    # ⚠️ `data/` 被排除是为了不把生产库拷进来，但自检里有 5 条断言读的是
    #    **仓库里那份** `data/user_must_know_V*.txt`（不是 dsapp_tos_file()，
    #    那个在自检进程里因为 data_root 指向临时目录而永远返回 NULL）。
    #    不带它 = 5 条假红，会把差集搅浑。
    os.makedirs(os.path.join(dst, "data"), exist_ok=True)
    for f in os.listdir(os.path.join(REPO, "data")):
        if re.match(r"^user_must_know_V[0-9]+\.txt$", f):
            shutil.copy2(os.path.join(REPO, "data", f),
                         os.path.join(dst, "data", f))


def parse_reds(log):
    reds = []
    for line in io.open(log, encoding="utf-8", errors="replace"):
        line = ANSI.sub("", line).rstrip()
        m = re.match(r"\s*✗\s+(.*?)\s*$", line)
        if m:
            reds.append(m.group(1))
    return reds


def run_one(mut, from_logs=False):
    """建副本 → 打变异 → 跑自检 → 收集红名单。from_logs=True 时只读回已有日志。"""
    d = os.path.join(BASE, mut["key"])
    log = os.path.join(BASE, mut["key"] + ".log")
    if from_logs:
        # ⚠️ 日志不存在要**报错**，不能当成"零条红" —— 那会把"没跑"
        #    判成"全绿"，正是本仓栽过很多次的那种假绿。
        if not os.path.exists(log):
            return dict(key=mut["key"], ok=False, msg="没有 %s，没法复查" % log,
                        reds=[])
        return dict(key=mut["key"], ok=True, desc=mut["desc"], path=mut["path"],
                    old=mut["old"], new=mut["new"], reds=parse_reds(log))
    make_copy(d)

    # ---- 打变异，并且**确认真打上了** ----
    if mut["path"]:
        fp = os.path.join(d, mut["path"])
        src = io.open(fp, encoding="utf-8").read()
        n = src.count(mut["old"])
        if n != 1:
            return dict(key=mut["key"], ok=False,
                        msg="变异串在 %s 里命中 %d 次（要正好 1 次）" % (mut["path"], n),
                        reds=[], missing=[], extra=[])
        io.open(fp, "w", encoding="utf-8").write(src.replace(mut["old"], mut["new"]))
        # 回读**独有字面量**确认打中的是目标处，不是文件里第一处长得像的地方
        back = io.open(fp, encoding="utf-8").read()
        if mut["new"] not in back or mut["old"] in back:
            return dict(key=mut["key"], ok=False, msg="变异没落到盘上", reds=[],
                        missing=[], extra=[])

    with io.open(log, "wb") as fh:
        subprocess.run(["Rscript", "--no-environ", "selftest.R"], cwd=d,
                       stdout=fh, stderr=subprocess.STDOUT)
    reds = parse_reds(log)

    # ⚠️ 这里**不**算 missing/extra：要拿**这一次真正的基线红名单**去比，
    #    而不是拿 KNOWN_BASE_RED 那个"理论上可能红"的集合。基线这次没红的
    #    那两条（它们会飘）要是并进来当预期，就会报成"预期该红却没红"。
    return dict(key=mut["key"], ok=True, desc=mut["desc"], path=mut["path"],
                old=mut["old"], new=mut["new"], reds=reds)


def main():
    before = {f: sha(os.path.join(REPO, f)) for f in GUARD}

    keys = ["M0"] + [m["key"] for m in MUTS]
    jobs = [dict(key="M0", desc="基线（什么都不改）", path=None, old=None,
                 new=None, want_red=[])] + MUTS

    FROM_LOGS = "--from-logs" in sys.argv
    if FROM_LOGS:
        print("--from-logs：不重跑，只读回 %s/M*.log 复查\n" % BASE)
        out = [run_one(j, from_logs=True) for j in jobs]
    else:
        print("跑 %d 份（1 份基线 + %d 个变异），5 个进程并行，每份约 8 分钟…\n"
              % (len(jobs), len(MUTS)))
        with ThreadPoolExecutor(max_workers=5) as ex:
            out = list(ex.map(run_one, jobs))

    print("=" * 78)
    base = next(o for o in out if o["key"] == "M0")
    print("基线红名单：")
    for r in base["reds"]:
        print("    ✗ %s" % r)
    # ⚠️ UNRELATED_FLAKY 那两条**也要从不变量里摘掉**，不只是从 extra 里摘：
    #    它们是"真的在子进程里 R CMD INSTALL 一个包"，5 路并发下会失败，
    #    而失败只进 stderr ⇒ stdout 里没有 FOUND_AT ⇒ 红。
    #    实测：单进程跑（仓库里那次）两条都绿；5 路并发跑，上一轮红在 M3、
    #    这一轮红在基线 —— 位置随机 = 负载决定，不是某一版引入的。
    #    摘干净两头：基线里多出它们不算脏，某个变异里少了它们也不算"该红没红"。
    if set(base["reds"]) - KNOWN_BASE_RED - UNRELATED_FLAKY:
        print("\n\033[31m基线里有预期之外的红 —— 副本不等价，下面的结论一条都不能信。\033[0m")
        print("  多出来的：", sorted(set(base["reds"]) - KNOWN_BASE_RED))
        return 2
    less = sorted(KNOWN_BASE_RED - set(base["reds"]))
    print("  ✔ 基线干净"
          + ("（那两条 deploy_link 假红这次没红，正常）" if less else "")
          + ("（.Rlib 那两条并发装包红了 —— 见上面注释，已摘掉）"
             if set(base["reds"]) & UNRELATED_FLAKY else "") + "\n")

    base_reds = set(base["reds"]) - UNRELATED_FLAKY
    nbad = 0
    for o in out:
        if o["key"] == "M0":
            continue
        want = set(dict((m["key"], m["want_red"]) for m in MUTS)[o["key"]]) | base_reds
        got = set(o["reds"])
        o["missing"] = sorted(want - got)
        o["extra"] = sorted(got - want)
        print("=" * 78)
        print("%s  %s" % (o["key"], o["desc"]))
        print("    改 %s：" % o["path"])
        print("      - %s" % o["old"].replace("\n", "\n        "))
        print("      + %s" % o["new"].replace("\n", "\n        "))
        if not o["ok"]:
            print("    \033[31m✗ 变异没打上：%s\033[0m" % o["msg"])
            nbad += 1
            continue
        delta = sorted(set(o["reds"]) - KNOWN_BASE_RED)
        print("    新红的（相对于基线）：%d 条" % len(delta))
        for r in delta:
            print("        ✗ %s" % r)
        if o["missing"]:
            print("    \033[31m✗ 预期该红却没红：\033[0m")
            for r in o["missing"]:
                print("        %s   ← 这条断言是死的（变异没影响它）" % r)
            nbad += 1
        hard_extra = [r for r in o["extra"] if r not in UNRELATED_FLAKY]
        flaky = [r for r in o["extra"] if r in UNRELATED_FLAKY]
        if flaky:
            print("    \033[33m⚠ 顺带红了（已观测到的易飘，和本版够不着）：\033[0m")
            for r in flaky:
                print("        %s" % r)
        if hard_extra:
            print("    \033[31m✗ 预期之外红了：\033[0m")
            for r in hard_extra:
                print("        %s   ← 变异打歪了，或者有连带\033[0m" % r)
            nbad += 1
        if not o["missing"] and not hard_extra:
            print("    \033[32m✔ 和预期逐条对上\033[0m")

    after = {f: sha(os.path.join(REPO, f)) for f in GUARD}
    print("=" * 78)
    if before != after:
        print("\033[31m✗ 仓库被动过了！\033[0m")
        for f in GUARD:
            if before[f] != after[f]:
                print("    %s  %s -> %s" % (f, before[f][:12], after[f][:12]))
        return 3
    print("\033[32m✔ 仓库 %d 个文件 sha256 逐字节未变（全程只动 /tmp 副本）\033[0m"
          % len(GUARD))

    if nbad:
        print("\033[31m%d 个变异没对上\033[0m" % nbad)
        return 1
    print("\033[32m全部 %d 个变异都和预期对上\033[0m" % len(MUTS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
