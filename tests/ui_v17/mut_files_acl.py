# -*- coding: utf-8 -*-
"""变异测试：证明 probe_files_acl.py 这把尺子能自己证伪。

只动**隔离实例**（/tmp/dsapp_v17a/app），仓库一个字不碰（跑完核对 sha256）。

★ 这一条变异同时回答两个问题，两个都必须回答：
  1. 尺子活着吗？——拿掉闸门它必须红。
  2. **审计报的那个 H1 是真的吗？**——同一个变异跑出来的，就是"修复前"的
     行为。如果拿掉闸门之后探针**照样绿**，那说明这个越权根本走不通，
     审计的 H1 是**读代码读出来的假警报**，而我已经照着它改了一处代码。
"""
import hashlib
import io
import os
import subprocess
import sys

INST = "/tmp/dsapp_v17a/app"
REPO = "/data3/biomamba/analysis/DS_App"
PY = "/home/biomamba/miniconda3/bin/python"
PROBE = os.path.join(REPO, "tests", "ui_v17", "probe_files_acl.py")

MOD = os.path.join(INST, "R", "mod_files.R")
APPR = os.path.join(INST, "app.R")

OLD = '''      role <- db_session_role(sid, state$user_id,
                              is_admin = dsapp_user_is_platform_admin(state$user),
                              con = dsapp_db(cfg()))
      if (!dsapp_role_can_view(role)) {
        return(showNotification("这个对话不存在，或者没有共享给你",
                                type = "warning", duration = 6))
      }
'''
NEW = '      # 变异：闸门整个拿掉\n'


def sh(p):
    return hashlib.sha256(io.open(p, "rb").read()).hexdigest()


def run_probe():
    r = subprocess.run([PY, PROBE], capture_output=True, text=True,
                       timeout=1200, cwd=REPO)
    red = []
    for ln in r.stdout.splitlines():
        if "✗" in ln:
            red.append(ln.split("✗", 1)[1]
                       .replace("\x1b[0m", "").replace("\x1b[31m", "").strip())
    return red, r.stdout + r.stderr


def main():
    before = sh(MOD)
    orig = io.open(MOD, encoding="utf-8").read()

    red0, out0 = run_probe()
    print("基线红名单 =", red0 if red0 else "（无，全绿）", flush=True)
    if red0:
        print(out0[-2500:])
        return 2

    if OLD not in orig:
        print("⚠️ 找不到要替换的那段（变异没打上）—— 先看看实例里的那份是不是新的")
        return 2
    io.open(MOD, "w", encoding="utf-8").write(orig.replace(OLD, NEW, 1))
    os.utime(APPR, None)          # R/*.R 是 app.R 的 mtime 一变才重新 source
    try:
        red, out = run_probe()
    finally:
        io.open(MOD, "w", encoding="utf-8").write(orig)
        os.utime(APPR, None)

    want = ["甲的哨兵**看不到**（这就是审计里那条越权，现在该被挡住）"]
    miss = [e for e in want if not any(e in x for x in red)]
    print("\n拿掉闸门：%s  （红了 %d 条）"
          % ("✅ 命中" if (red and not miss) else "❌ 不对", len(red)), flush=True)
    for x in red:
        print("     ", ("→" if any(e in x for e in want) else "  "), x)
    if miss:
        print("     ⚠️ 预期该红却没红：", miss)
    if not red:
        print(out[-2500:])

    print("\n还原：逐字节一致 =", sh(MOD) == before, flush=True)
    ok = bool(red) and not miss
    print("\n===== %s =====" % ("符合预期" if ok else "不符合预期"), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
