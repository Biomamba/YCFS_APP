# -*- coding: utf-8 -*-
"""给 selftest.R 里新增的「V17 item 1」那一节做变异测试。

⚠️ 只有读得到 www/app.js 就行 —— 所以把 cwd 指到**隔离实例**（/tmp/dsapp_v17a/app），
   在那儿改。**绝不在仓库里改**：开发目录就是生产目录，改一下线上立刻就变。
   仓库那份从头到尾一个字节都不动（跑完会核对）。

⚠️ **判据（selftest.R）从仓库按绝对路径读，被测的 www/app.js 从 cwd 读**。
   第一版两者都从 cwd 读，而实例里那份 selftest.R 是上一版的、根本没有
   "V17 item 1" 这一节 ⇒ `ti` 是空的，8 个变异**全都**报
   `attempt to select less than one element`。那不是"变异没打上"，是**尺子拿错了**：
   报出来的 ❌ 一个都不能信（所以这里对"跑不起来"单独判，见 run_section 的 rc）。
"""
import io, os, subprocess, sys, hashlib

INST = "/tmp/dsapp_v17a/app"
TARGET = INST + "/www/app.js"
REPO = "/data3/biomamba/analysis/DS_App/www/app.js"
REPO_ST = "/data3/biomamba/analysis/DS_App/selftest.R"
REPO_CFG = "/data3/biomamba/analysis/DS_App/R/config.R"

RUNNER = r'''
suppressMessages(library(shiny))
ok_all <- TRUE; fail_n <- 0L
src <- parse("%(st)s")                 # ← 仓库那份（有 V17 这一节）
wanted <- c("chk","section","strip_comments","strip_js_comments","css_rule",
            "dsapp_block_at","js_code","css_code","DSAPP_PING_MS")
exprs <- c(src, parse("%(cfg)s"))
is_assign <- function(e) is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]])
todo <- wanted
repeat { n <- length(todo)
  for (e in exprs) { if (!is_assign(e)) next
    nm <- as.character(e[[2]])
    if (nm %%in%% todo) { ok <- tryCatch({eval(e, globalenv()); TRUE}, error=function(err) FALSE)
                        if (ok) todo <- setdiff(todo, nm) } }
  if (!length(todo) || length(todo) == n) break }
if (length(todo)) { cat("抠不出:", paste(todo, collapse=","), "\n"); quit(status=2) }
ti <- which(vapply(src, function(e) is.call(e) && identical(e[[1]], as.name("section")) &&
    is.character(e[[2]]) && grepl("V17 item 1", e[[2]]), logical(1)))
if (length(ti) != 1L) { cat("找不到（或不止一个）V17 item 1 那一节，ti =",
                            paste(ti, collapse=","), "\n"); quit(status=2) }
suppressMessages(eval(src[[ti]], globalenv()))
r <- tryCatch({eval(src[[ti+1]], globalenv()); NULL}, error=function(e) e)
if (!is.null(r)) cat("\n[这一节抛了]", conditionMessage(r), "\n")
cat(sprintf("\nSUMMARY %%d\n", fail_n))
''' % {"st": REPO_ST, "cfg": REPO_CFG}

# 一条 = 一个变异。第 4 项是**预期该红的那条断言的名字**（跑完必须出现）。
MUTS = [
    ("M1  静默期缩到 1 秒（比一拍心跳还短 = 等于没装闸门）",
     'var DSAPP_OFFLINE_QUIET_MS = 60000;',
     'var DSAPP_OFFLINE_QUIET_MS = 1000;',
     "静默期 DSAPP_OFFLINE_QUIET_MS 是个正经的间隔"),

    ("M11 记账只记时刻、不勾欠账（被挡下的那条永远补不上）",
     'function dsappPromptMark() {\n  dsappPromptAt = Date.now();\n  dsappPromptOwed = false;\n}',
     'function dsappPromptMark() {\n  dsappPromptAt = Date.now();\n}',
     "「说过了」这个事实只有一个写入口，而且两件事一起写"),

    ("M3  小条上屏不记账",
     '  dsappPromptMark();\n  if (m && m.parentNode) m.parentNode.removeChild(m);',
     '  if (m && m.parentNode) m.parentNode.removeChild(m);',
     "闸门记在**函数里**，而且记在早退之后"),

    ("M9  删掉小条的早退（每 2 秒重画一次 = 自己给自己续期）",
     '  if (m && m.getAttribute("data-kind") === kind) return;\n',
     '  if (false) return;\n',
     "闸门记在**函数里**，而且记在早退之后"),

    ("M2  Escalate 不装闸门",
     '  if (!dsappPromptAllowed()) { dsappPromptOwe(); return false; }\n',
     '',
     "两条**通用**报警路都装了闸门"),

    ("M10 静默期里连状态一起不写（挡的是事实）",
     '  dsappNetSet(kind === "silent" ? "silent" : "down", "dsappOfflineWarn");\n'
     '  /* ★★ V17 item 1：闸门装在这里',
     '  /* ★★ V17 item 1：闸门装在这里',
     "挡的是**提示**，不是**事实**"),

    ("M4  回到 up 时把静默期的钟也归零",
     '    dsappPromptOwed = false;\n  } else if (n.state === "up") {',
     '    dsappPromptOwed = false;\n    dsappPromptAt = 0;\n  } else if (n.state === "up") {',
     "回到 up 只清欠账"),

    # ⚠️ 第一版这里写的是"挪进 else 分支"。那个位置在 dsapp_block_at 抠出来的
    #    块**外面**（它只抠 if 那一支），断言照样绿 —— 而它**本来就该绿**：
    #    断线期间每一拍都走 else，补账照跑。真正会坏事的是挪进**第一支**：
    #    那一支只在断线的第一拍走一次，此后欠账再也没人补。
    ("M6  补账挪进判死那个 if 块的第一支里",
     '      dsappOfflineWarn("silent");\n    } else {',
     '      dsappOfflineWarn("silent");\n      dsappOfflineOwedFlush();\n    } else {',
     "被挡下的那条要有人来补"),

    ("M7  补账先画小条、后问卡片",
     '  if (dsappOfflineEscalate(st)) return; /* 卡片出来了（或本来就挂着），够了 */\n'
     '  dsappOfflineMini(st === "silent" ? "silent" : "down");',
     '  dsappOfflineMini(st === "silent" ? "silent" : "down");\n'
     '  if (dsappOfflineEscalate(st)) return;',
     "补账先问卡片那条路"),

    ("M8  给自愈那条也装上闸门",
     '  if (!document.getElementById("dsapp-offline"))\n    dsappOfflineShow(',
     '  if (!dsappPromptAllowed()) return;\n'
     '  if (!document.getElementById("dsapp-offline"))\n    dsappOfflineShow(',
     "自愈那条**不装**闸门"),
]


def run_section():
    r = subprocess.run(["Rscript", "--no-environ", "-e", RUNNER],
                       capture_output=True, text=True, cwd=INST, timeout=300)
    red = []
    for ln in r.stdout.splitlines():
        if "✗" in ln:
            red.append(ln.split("✗", 1)[1].replace("\x1b[0m", "").replace("\x1b[31m", "").strip())
    # ⚠️ "跑不起来"和"没红"必须分开报 —— 第一版就是把前者当后者，8 条全判 ❌，
    #    看着像"9 条断言全是死的"，其实是尺子根本没找到那一节。
    broke = r.returncode != 0 or "SUMMARY" not in r.stdout
    return red, broke, r.stdout + r.stderr


def main():
    repo_before = hashlib.sha256(open(REPO, "rb").read()).hexdigest()
    orig = io.open(TARGET, encoding="utf-8").read()
    assert orig == io.open(REPO, encoding="utf-8").read(), "实例那份和仓库不一致，先同步"

    red0, broke0, out0 = run_section()
    print("基线红名单 =", red0 if red0 else "（无，全绿）")
    if broke0 or red0:
        print(out0[-2500:]); return 2

    bad = 0
    for name, old, new, expect in MUTS:
        if old not in orig:
            print("\n%s：⚠️ 找不到要替换的那段（变异没打上）" % name); bad += 1; continue
        io.open(TARGET, "w", encoding="utf-8").write(orig.replace(old, new, 1))
        red, broke, out = run_section()
        io.open(TARGET, "w", encoding="utf-8").write(orig)     # 立刻还原

        if broke:
            print("\n%s：⚠️ 尺子没跑起来（这一轮的结论一律不算）" % name)
            print(out[-1200:]); bad += 1; continue

        hit = any(expect in x for x in red)
        print("\n%s：%s" % (name, "✅ 命中（%r 红了）" % expect if hit else "❌ 没红"))
        for x in red:
            print("     红：", x)
        if not hit:
            print(out[-1200:]); bad += 1

    io.open(TARGET, "w", encoding="utf-8").write(orig)
    repo_after = hashlib.sha256(open(REPO, "rb").read()).hexdigest()
    print("\n实例还原 =", io.open(TARGET, encoding="utf-8").read() == orig,
          "｜仓库没被碰 =", repo_before == repo_after)
    print("\n===== %s =====" % ("全部符合预期" if bad == 0 else "%d 个不对" % bad))
    return 1 if bad else 0


sys.exit(main())
