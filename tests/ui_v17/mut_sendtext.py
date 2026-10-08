# -*- coding: utf-8 -*-
"""变异测试：证明 tests/ui_v17/probe_sendtext.py 这把尺子能自己证伪。

只动**隔离实例**（/tmp/dsapp_v17a/app），仓库一个字不碰（跑完核对 sha256）。

★ 为什么要三个变异、而不是一个：item 3 的修复是**两半**（客户端把原文送上去、
  服务端优先用它），而客户端那一半又有**两个调用点**（回车 / 点按钮）。
  少打任何一个，"尺子在这条路上是死的"都不会被发现 —— 本仓栽过
  「同一个弱判据修了一处、另一处原样留着」。

⚠️ 判据只认"**该红的红了没有**"：多红的那些是级联（A3/A4 都依赖"发出去的是
   DOM 里的原文"），把它算成"变异打歪了"是记账写错了。
"""
import hashlib
import io
import os
import re
import subprocess
import sys

INST = "/tmp/dsapp_v17a/app"
REPO = "/data3/biomamba/analysis/DS_App"
PY = "/home/biomamba/miniconda3/bin/python"
PROBE = os.path.join(REPO, "tests", "ui_v17", "probe_sendtext.py")
OUT = "/tmp/dsapp_ui_v17"

# ---- 两个变异 ---------------------------------------------------------------
JS = os.path.join(INST, "www", "app.js")
RCHAT = os.path.join(INST, "R", "mod_chat.R")
APPR = os.path.join(INST, "app.R")

MUTS = [
    # ⚠️ 变异必须**逐个调用点**打，不能只打一个就说"客户端那半边验过了"：
    #    两个调用点覆盖两条路，而且这两条路的"会不会被浏览器自己兜住"
    #    完全不同（见下面的说明）。打一个漏一个 = 本仓那句
    #    「同一个弱判据修了一处、另一处原样留着」。
    #
    # ★ 回车那条路是**唯一有劲**的：不失焦 ⇒ 没有原生 change ⇒ 镜像稳稳停在
    #   旧值上。拿掉这一句，发出去的必然是旧值（这里是上一条消息的原文）。
    ("MJ1 回车那条路不再送原文（点按钮那条留着）", JS,
     '  dsappPushSendText(e.target);\n  dsappSendSeq += 1;',
     '  dsappSendSeq += 1;',
     ["库里落的是**汉字版**"]),

    # ★ 点按钮那条路：浏览器在失焦时补一个原生 change，**有时候**能兜住，
    #   所以它红的理由不是"值没送上去"，而是**送上去的是上一条**——
    #   `input$send_text` 是**粘性**的（Shiny 的 input 值不清零），
    #   这一路不推，服务端读到的就是上一次推的那个值。
    #   ⇒ 红，但红在"发出去的是别的消息"，不是"发出去的是拼音"。
    ("MJ2 点按钮那条路不再送原文（回车那条留着）", JS,
     '  dsappPushSendText(dsappIds.input ? document.getElementById(dsappIds.input) : null);',
     '  /* 变异：这一句拿掉 */',
     ["组字结束后再点一次就能发"]),

    ("MR  服务端的判据写成 nzchar（空串被当成「没送」）", RCHAT,
     '      txt <- if (!is.null(extra)) trimws(extra)\n'
     '             else if (!is.null(txt)) trimws(txt)',
     '      txt <- if (!is.null(extra)) trimws(extra)\n'
     '             else if (nzchar(txt %||% "")) trimws(txt)',
     ["框里是空的就一条都不发"]),
]


def sh(p):
    return hashlib.sha256(io.open(p, "rb").read()).hexdigest()


def run_probe():
    r = subprocess.run([PY, PROBE], capture_output=True, text=True, timeout=1200,
                       cwd=REPO)
    red = []
    for ln in r.stdout.splitlines():
        if "✗" in ln:
            red.append(ln.split("✗", 1)[1].replace("\x1b[0m", "").replace("\x1b[31m", "").strip())
    return red, r.stdout + r.stderr


def main():
    before = {f: sh(f) for f in (JS, RCHAT)}
    orig = {f: io.open(f, encoding="utf-8").read() for f in (JS, RCHAT)}

    red0, out0 = run_probe()
    print("基线红名单 =", red0 if red0 else "（无，全绿）")
    if red0:
        print(out0[-2500:])
        return 2

    bad = 0
    for name, path, old, new, expect in MUTS:
        if old not in orig[path]:
            print("\n%s：⚠️ 找不到要替换的那段（变异没打上）" % name)
            bad += 1
            continue
        io.open(path, "w", encoding="utf-8").write(orig[path].replace(old, new, 1))
        # R/*.R 是 app.R 的 mtime 一变才重新 source 的（本仓的生效规则）。
        os.utime(APPR, None)
        try:
            red, out = run_probe()
        finally:
            io.open(path, "w", encoding="utf-8").write(orig[path])
            os.utime(APPR, None)

        miss = [e for e in expect if not any(e in x for x in red)]
        ok = (not miss) and bool(red)
        print("\n%s：%s  （红了 %d 条）" % (name, "✅ 命中" if ok else "❌ 不对", len(red)))
        for x in red:
            print("     ", ("→" if any(e in x for e in expect) else "  "), x)
        if miss:
            print("     ⚠️ 预期该红却没红（尺子在这条上是死的）：", miss)
        if not ok:
            bad += 1
            print(out[-1500:])

    after = {f: sh(f) for f in (JS, RCHAT)}
    print("\n还原：逐字节一致 =", before == after)
    print("\n===== 变异测试：%s =====" % ("全部符合预期" if bad == 0 else "%d 个不对" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
