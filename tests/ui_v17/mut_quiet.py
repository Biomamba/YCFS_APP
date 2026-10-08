# -*- coding: utf-8 -*-
"""变异测试：证明 tests/ui_v17/probe_quiet.py 这把尺子能自己证伪。

只动**隔离实例**（/tmp/dsapp_v17a/app/www/app.js）的那一份，仓库一个字不碰。
每轮：打一个变异 → 跑探针 → 记下红的是哪几条 → 还原。

⚠️ 一个"打进去但不改变行为"的变异证明的是零（本仓栽过：塞进
   `output$thinking_box` 的 draft() 从没被写过，探针全绿却什么也没证明）。
   所以每个变异的**预期红名单**先写死在下面，跑完比对：
   预期该红的没红 = 探针没劲；预期不该红的红了 = 变异打歪了（改到了别处）。
"""
import io, os, shutil, subprocess, sys

TARGET = "/tmp/dsapp_v17a/app/www/app.js"
BAK = "/tmp/dsapp_v17a/app/www/app.js.mutbak"
PROBE = "/data3/biomamba/analysis/DS_App/tests/ui_v17/probe_quiet.py"
PY = "/home/biomamba/miniconda3/bin/python"

MUTS = [
    ("M1 Warn 不装闸门",
     "  if (!dsappPromptAllowed()) { dsappPromptOwe(); return; }\n  dsappOfflineMini(kind === \"silent\" ? \"silent\" : \"down\");",
     "  dsappOfflineMini(kind === \"silent\" ? \"silent\" : \"down\");",
     ["静默期内**不再重播**", "挡下的那条记成欠账"]),

    # ⚠️ M2 的预期红名单里**没有**"静默期一过卡片照出"：M2 破坏的是"静默期内
    #    别说"，不破坏"静默期过了要说"。第一版把它写进预期，跑出来判 ❌ ——
    #    那是**我记账写错了**，不是探针没劲（第二版量过：去掉闸门之后，
    #    静默期之后那一下照样出卡片，本来就该是绿的）。
    ("M2 Escalate 不装闸门",
     "  if (!dsappPromptAllowed()) { dsappPromptOwe(); return false; }\n  dsappOfflineShow(st === \"silent\" ? \"silent\" : \"disconnected\");",
     "  dsappOfflineShow(st === \"silent\" ? \"silent\" : \"disconnected\");",
     ["静默期内铺卡片被挡下", "挡下时也记了欠账"]),

    # M5 是给"静默期一过卡片照出"这条断言配的**阳性对照**：没有它，那条断言
    # 从没红过，我排除不了它是死的（本仓栽过：一条永远通过的检查比没有更糟）。
    ("M5 闸门变成永远关着（卡片再也出不来）",
     "  if (!dsappPromptAllowed()) { dsappPromptOwe(); return false; }",
     "  if (true) { dsappPromptOwe(); return false; }",
     ["静默期一过卡片照出"]),

    ("M3 小条上屏不记账",
     "  dsappPromptMark();\n  if (m && m.parentNode) m.parentNode.removeChild(m);",
     "  if (m && m.parentNode) m.parentNode.removeChild(m);",
     ["记了上屏时刻", "静默期内**不再重播**"]),

    ("M4 回到 up 时把静默期也归零",
     "    dsappPromptOwed = false;\n  } else if (n.state === \"up\") {",
     "    dsappPromptOwed = false;\n    dsappPromptAt = 0;\n  } else if (n.state === \"up\") {",
     ["恢复**没有**把静默期归零", "静默期内**不再重播**"]),
]


def run_probe():
    r = subprocess.run([PY, PROBE], capture_output=True, text=True, timeout=300)
    red = []
    for ln in r.stdout.splitlines():
        if "✗" in ln:                      # ✗
            t = ln.split("✗", 1)[1]
            t = t.replace("\x1b[0m", "").replace("\x1b[31m", "").strip()
            red.append(t)
    return red, r.stdout


def main():
    if not os.path.exists(BAK):
        shutil.copy2(TARGET, BAK)
    orig = io.open(BAK, encoding="utf-8").read()

    red0, out0 = run_probe()
    print("基线红名单 =", red0 if red0 else "（无，全绿）")
    if red0:
        print("基线就红，变异测试没意义 —— 先修探针。")
        return 2

    bad = 0
    for name, old, new, expect in MUTS:
        if old not in orig:
            print("\n%s：⚠️ 找不到要替换的那段（变异没打上，等于没测）" % name)
            bad += 1
            continue
        io.open(TARGET, "w", encoding="utf-8").write(orig.replace(old, new, 1))
        red, out = run_probe()
        io.open(TARGET, "w", encoding="utf-8").write(orig)     # 立刻还原

        # ⚠️ 判据只认"**该红的红了没有**"。多红的那些是级联（提示都重播出来了，
        #    后面几条当然跟着红），把它当成"变异打歪了"是**我的记账写错了**，
        #    第一版就是这么误报的（4 个变异全判 ❌，其实 4 个都命中）。
        miss = [e for e in expect if not any(e in x for x in red)]
        ok = (not miss) and bool(red)
        print("\n%s：%s  （红了 %d 条）" % (name, "✅ 命中" if ok else "❌ 不对", len(red)))
        for x in red:
            print("     ", ("→" if any(e in x for e in expect) else "  "), x)
        if miss:
            print("     ⚠️ 预期该红却没红（探针在这条上是死的）：", miss)
        if not ok:
            bad += 1

    io.open(TARGET, "w", encoding="utf-8").write(orig)
    print("\n还原完毕（和备份逐字节一致 =",
          io.open(TARGET, encoding="utf-8").read() == orig, "）")
    print("\n===== 变异测试：%s =====" % ("全部符合预期" if bad == 0 else "%d 个不对" % bad))
    return 1 if bad else 0


sys.exit(main())
