# -*- coding: utf-8 -*-
"""清点生产文件区里的**镜像空壳**（V17 item 2 的存量）。

    python3 tests/ui_v17/count_mirror_shells.py [data/files]                 # 只数，不动
    python3 tests/ui_v17/count_mirror_shells.py --move-aside <目录> [根]      # 挪走（不删）

`--move-aside` 的规矩（**默认不跑**，要人显式给一个目录才动）：

  · 是**挪走**不是删：每个壳整支搬进 `<目录>/<账号>/…`，原样保留，
    另写一份 `manifest.tsv`（原路径 → 新路径 + 里面有几个文件）；
  · 只挪**最外层**那一个（`u11/A/B` 和 `u11/A/B/C` 都是壳时，挪 A 就够了，
    C 跟着走）—— 不然第二下会去找一个已经不在原处的路径；
  · 里面有**真文件**的一个都不挪（判据的注释里写了为什么）；
  · 目标目录**不许**在文件区里面 —— 挪进去等于没挪，它照样在页面上显示。

背景：执行代码前 `dsapp_mirror_shared()` 把整个文件区映进工作区根（目录真建、
文件软链），任务收尾的快照又把那些**目录**当成产物同步回文件区 ⇒ 每个对话
文件夹里都长出别的对话的空壳。V17 已经把这条环切断（新壳不再产生），
**存量**在盘上还在，清不清是用户的决定 —— 所以这里只数，不删。

判据（和 `R/files.R` 里那道闸门同一个）：

  · 管理区根 = `<data/files>/u<N>/` 顶层的名字（= 对话文件夹名）；
  · 某个目录 D 只要**首段之后**的任意一段命中那份名单，就记成一个壳；
  · 同时数一下它**里面有几个真文件**（壳的典型形态是 0 —— 但**不拿它当判据**：
    模型真的往镜像目录里写过东西时，那个目录也是"名字像壳、里面有货"，
    删掉就是删用户的产物）。

⚠️ 诊断脚本，不下断言。数字要跟着**这次**的盘走，别抄上一次的。
"""
import os
import sys

argv = sys.argv[1:]
aside = None
if argv and argv[0] == "--move-aside":
    if len(argv) < 2:
        sys.exit("用法：count_mirror_shells.py --move-aside <目录> [文件区根]")
    aside = os.path.abspath(argv[1])
    argv = argv[2:]
root = argv[0] if argv else "/data3/biomamba/analysis/DS_App/data/files"

shells = []          # (相对路径, 里面真文件数)
others = []          # 名字不像壳的空目录（模型自建的那类，V8 item 7 要保）
n_all = 0

for u in sorted(os.listdir(root)):
    up = os.path.join(root, u)
    if not os.path.isdir(up) or os.path.islink(up):
        continue
    top = set(n for n in os.listdir(up))
    for dp, dns, fns in os.walk(up):
        for d in dns:
            p = os.path.join(dp, d)
            n_all += 1
            if os.path.islink(p):
                continue
            rel = os.path.relpath(p, up)
            segs = rel.split(os.sep)
            # 首段**之后**的任意一段命中"管理区根上的名字" = 镜像壳
            hit = len(segs) > 1 and any(s in top for s in segs[1:])
            nf = sum(len(f) for _, _, f in os.walk(p))
            if hit:
                shells.append((u + "/" + rel, nf))
            elif nf == 0:
                others.append((u + "/" + rel, nf))

print("扫描根：%s" % root)
print("目录总数 %d" % n_all)
print("镜像壳嫌疑 %d" % len(shells))
print("  其中**里面有真文件**的 %d（这些不是空壳，别顺手删）"
      % sum(1 for _, nf in shells if nf))
print("其余空目录（模型自建，V8 item 7 要保的那类）%d" % len(others))
print()
by_user = {}
for r, _ in shells:
    by_user[r.split("/")[0]] = by_user.get(r.split("/")[0], 0) + 1
print("按账号：%s" % by_user)
print()
print("---- 前 40 条镜像壳 ----")
for r, nf in shells[:40]:
    print("  [%2d 文件] %s" % (nf, r))

# ---- 挪走（只在显式给了 --move-aside 时才走这一段）-------------------------
if aside:
    import shutil
    if os.path.abspath(root) == aside or aside.startswith(os.path.abspath(root) + os.sep):
        sys.exit("目标目录在文件区里面（%s）—— 挪进去等于没挪" % aside)
    todo = sorted([r for r, nf in shells if nf == 0], key=lambda x: x.count("/"))
    moved, skipped, done = [], [], []
    for r in todo:
        if any(r.startswith(d + "/") for d in done):   # 父壳已经整支挪走
            continue
        src = os.path.join(root, r)
        if not os.path.isdir(src):
            skipped.append((r, "原处已经没有了"))
            continue
        dst = os.path.join(aside, r)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)
        moved.append((r, dst)); done.append(r)
    man = os.path.join(aside, "manifest.tsv")
    os.makedirs(aside, exist_ok=True)
    with open(man, "a", encoding="utf-8") as fh:
        for r, d in moved:
            fh.write("%s\t%s\n" % (os.path.join(root, r), d))
    print()
    print("挪走 %d 个（清单：%s）" % (len(moved), man))
    print("跳过 %d 个：%s" % (len(skipped), skipped[:5]))
    print("⚠️ 这是**挪走**不是删除：要还回去就把 manifest 里第二列搬回第一列。")
