# -*- coding: utf-8 -*-
"""变异驱动：证明 tests/v17_mirror.R 那 22 条里，关键的那几条**能被弄红**。

本仓的规矩（栽过很多次）：**全绿不是证据**。一条断言如果拿掉被测的那段
代码还是绿的，它证明的是零，却长得像"探针很强"。所以每写一条关键断言，
都要配一个"把被测代码改坏、它必须红"的对照。

这份文件跑两个变异 —— 因为这个修复有**两半**，各自独立：

  M1「整个闸门拿掉」        → A 节那三条必须红（用户报的那条回来了）
  M2「只认名字，不看软链」  → B1 节那条必须红（同名真产物被误吞）

★ M2 是这份变异里**最有分量**的一个：它杀掉的正是这个修复的**第一版**。
  第一版写的是 `grepl("/", a) && 首段 %in% mirror_names` —— 只看名字和层级。
  它能让 M1 那一组全绿（镜像确实被挡了），却在"模型自建的同名产物"上
  **静默丢文件**。没有 M2，第一版会带着一个漂亮的绿报告上线。

⚠️ 定位一律用**整段精确匹配**，不用行号、不用正则。
   本仓有账（locating-code-by-proximity）：定长窗口会越界读到下一个函数 →
   假红；`sub()` 改的是文件里**第一处**而不是目标处 → 假绿。
⚠️ 每次改完都**回读一个独有字面量**确认打中了 —— 否则"变异没生效"和
   "断言是死的"在输出上长得一模一样。
⚠️ 还原之后对 sha256，逐字节确认。
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

APP = Path("/data3/biomamba/analysis/DS_App")
SRC = APP / "R" / "files.R"

# ---- 被测的那一段（从 R/files.R 里原样抠出来）-------------------------------
GUARD = '''      if (length(mirror_names)) {
        seg <- strsplit(a, "/", fixed = TRUE)[[1]][1]
        if (seg %in% mirror_names) {
          known <- .mirror_cache[[seg]]
          if (is.null(known)) {
            known <- ws_is_mirror(seg)
            assign(seg, known, envir = .mirror_cache)
          }
          if (isTRUE(known)) { skipped <- skipped + 1L; next }
        }
      }
'''

# ---- 两个变异 ---------------------------------------------------------------
# M1：闸门整个变成"永远不挡"。保留 `length(mirror_names)` 那句是为了让
#     `mirror_names` / `ws_is_mirror` 仍然被"用过"，不至于先撞别的错。
M1_FROM = GUARD
M1_TO = '''      if (length(mirror_names)) {
        seg <- strsplit(a, "/", fixed = TRUE)[[1]][1]
        if (FALSE && seg %in% mirror_names) {
          known <- .mirror_cache[[seg]]
          if (is.null(known)) {
            known <- ws_is_mirror(seg)
            assign(seg, known, envir = .mirror_cache)
          }
          if (isTRUE(known)) { skipped <- skipped + 1L; next }
        }
      }
'''
M1_MARK = "if (FALSE && seg %in% mirror_names) {"

# M2：只认名字 —— 这就是这个修复的**第一版**。软链那一半没了。
M2_FROM = GUARD
M2_TO = '''      if (length(mirror_names)) {
        seg <- strsplit(a, "/", fixed = TRUE)[[1]][1]
        if (seg %in% mirror_names) { skipped <- skipped + 1L; next }
      }
'''
M2_MARK = 'if (seg %in% mirror_names) { skipped <- skipped + 1L; next }'

# ---- 期望：每个变异下**必须红**的断言（按文案片段认）------------------------
EXPECT_RED = {
    "M1": [
        "别人的文件夹**没有**在本对话的文件夹里出现",
        "它的子目录也没有",
    ],
    "M2": [
        "模型自建的 `同名区/report.txt` 同步进去了",
    ],
}


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run_test():
    r = subprocess.run(
        ["Rscript", "--no-environ", "tests/v17_mirror.R", "."],
        cwd=str(APP), capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout + r.stderr


def reds(out):
    """把输出里所有 ✗ 那一行的文案抠出来。"""
    got = []
    for ln in out.splitlines():
        # ⚠️ 判据用 ✗ / ✓ 这两个字符本身，不用颜色转义 —— 没 tty 时
        #    R 照样打（say 是 sprintf 到 stderr 的），但颜色码可能被剥掉。
        if "✗" in ln:
            got.append(ln.split("✗", 1)[1].strip())
    return got


def main():
    orig = SRC.read_text(encoding="utf-8")
    h0 = sha(SRC)
    bak = Path(tempfile.mkdtemp()) / "files.R.orig"
    shutil.copy2(SRC, bak)

    # ---- 先确认基线：现在必须是全绿，而且 GUARD 那段能精确匹配到 ----------
    if orig.count(GUARD) != 1:
        sys.exit("夹具坏了：闸门那一段在 R/files.R 里出现 %d 次（要 1 次）"
                 % orig.count(GUARD))
    rc, out = run_test()
    base_red = reds(out)
    print("基线：exit=%d  红名单=%s" % (rc, base_red if base_red else "（无，全绿）"))
    if base_red:
        sys.exit("基线就是红的，先别做变异 —— 那说明红的不是变异造成的")

    bad = 0
    for tag, frm, to, mark in [("M1", M1_FROM, M1_TO, M1_MARK),
                               ("M2", M2_FROM, M2_TO, M2_MARK)]:
        print("\n===== %s =====" % tag)
        body = orig.replace(frm, to, 1)
        if body == orig:
            sys.exit("%s：替换没生效" % tag)
        SRC.write_text(body, encoding="utf-8")

        # ★ 回读独有字面量，确认**打中了目标处**（不是改到了别处 / 没改上）
        back = SRC.read_text(encoding="utf-8")
        if back.count(mark) != 1:
            sys.exit("%s：打中确认失败，%r 出现 %d 次"
                     % (tag, mark, back.count(mark)))
        # 反向确认：原来的写法**确实没了**（否则可能是原地没动）
        print("  打中确认：%r 命中 1 次 ✓" % mark[:48])

        rc, out = run_test()
        got = reds(out)
        print("  exit=%d  红了 %d 条" % (rc, len(got)))
        for g in got:
            print("      → %s" % g)

        for want in EXPECT_RED[tag]:
            hit = any(want in g for g in got)
            if hit:
                print("  \033[32m✓ 该红的红了：%s\033[0m" % want)
            else:
                bad += 1
                print("  \033[31m✗✗✗ 没红！%s —— 这条断言是死的\033[0m" % want)

        # 还原
        SRC.write_text(orig, encoding="utf-8")
        same = sha(SRC) == h0
        print("  还原：逐字节一致 = %s" % same)
        if not same:
            shutil.copy2(bak, SRC)
            sys.exit("%s：还原不一致，已从备份恢复" % tag)

    # ---- 收尾：变异全退掉之后，必须回到全绿 ---------------------------------
    rc, out = run_test()
    fin = reds(out)
    print("\n复原后：exit=%d  红名单=%s" % (rc, fin if fin else "（无，全绿）"))
    if fin or rc != 0:
        bad += 1
        print("\033[31m复原后不是全绿 —— 有东西留在盘上了\033[0m")

    print("\n%s" % ("\033[32m===== 变异全部按预期 =====\033[0m" if bad == 0
                    else "\033[31m===== 有 %d 项不符合预期 =====\033[0m" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
