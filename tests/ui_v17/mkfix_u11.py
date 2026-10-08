# -*- coding: utf-8 -*-
"""把 uid=11 在**生产盘上的目录结构**照搬到测试实例里（名字照抄，文件是 1 字节占位）。

为什么要这个东西：用户报的两条（V17 item 2 / item 4）都是"文件管理页面看到的东西
不对"，而我在数据层怎么看都是对的（`files/u11/` 下 5 个目录、15 GB）。**读代码
读不出差异的地方，只能把现场搬过来自己看。**

⚠️⚠️ 只搬**结构**（名字 + 层级），不搬内容：
    · 生产那份是 15 GB，搬不动，而且没必要 —— 要复现的是"列表里有没有这一行"，
      不是"这一行多大"；
    · 占位文件是 1 字节，所以**凡是和体积/内容有关的症状复现不出来**，这一条要
      写在结论里，不能拿"我复现了"当"整个 bug 都复现了"。

⚠️ 生产库一律 `mode=ro` 打开，只读。
"""
import hashlib
import os
import shutil
import sqlite3
import sys
import time

PROD = "/data3/biomamba/analysis/DS_App/data"
INST = "/tmp/dsapp_v17a/data"
UID = 11

PW = "Fixture_V17_pw"
SALT = "fixturev17"


def pw_hash(pw, salt):
    """照抄 R/users.R 的 dsapp_pw_hash：h = sha256(h + salt)，迭代 1000 次。"""
    h = salt + ":" + pw
    for _ in range(1000):
        h = hashlib.sha256((h + salt).encode()).hexdigest()
    return h


def build_tree(src, dst, depth, maxdepth):
    """把 src 下的结构照搬到 dst（目录真建、文件写 1 字节占位）。"""
    n_d = n_f = 0
    os.makedirs(dst, exist_ok=True)
    try:
        names = sorted(os.listdir(src))
    except OSError:
        return 0, 0
    for nm in names:
        s = os.path.join(src, nm)
        d = os.path.join(dst, nm)
        if os.path.islink(s):
            # 软链一律跳过：测试实例里那些目标不存在，建出来是断链，
            # 反而会引入一个现场里没有的变量。
            continue
        if os.path.isdir(s):
            n_d += 1
            if depth < maxdepth:
                a, b = build_tree(s, d, depth + 1, maxdepth)
                n_d += a
                n_f += b
            else:
                os.makedirs(d, exist_ok=True)
        else:
            n_f += 1
            with open(d, "wb") as fh:
                fh.write(b"x")
    return n_d, n_f


def main():
    src_root = os.path.join(PROD, "files", "u%d" % UID)
    dst_root = os.path.join(INST, "files", "u%d" % UID)
    if not os.path.isdir(src_root):
        sys.exit("生产那边没有 %s" % src_root)
    # 夹具要能反复跑（现场搬一次看不出来，改了再搬是常态）。旧的那份**挪走**
    # 而不是删掉 —— 本仓规矩：不替你 rm。
    if os.path.exists(dst_root):
        t = "%s.bak-%s" % (dst_root, time.strftime("%Y%m%d_%H%M%S"))
        shutil.move(dst_root, t)
        print("旧的挪到 %s" % t)

    # ---- 1. 管理区结构（深度 2 够用：根那一层 + 每个会话文件夹里那一层）----
    nd, nf = build_tree(src_root, dst_root, 0, 2)
    print("管理区：建了 %d 个目录、%d 个占位文件 → %s" % (nd, nf, dst_root))

    # ---- 2. 生产那边 uid=11 的会话行，原样搬进来 ----
    pro = sqlite3.connect("file:%s/dsapp.sqlite3?mode=ro" % PROD, uri=True)
    pro.row_factory = sqlite3.Row
    rows = [dict(r) for r in pro.execute(
        "SELECT id, title, created_at, updated_at FROM sessions WHERE user_id=?",
        (UID,))]
    u = dict(pro.execute("SELECT * FROM users WHERE id=?", (UID,)).fetchone())
    pro.close()
    print("会话 %d 条" % len(rows))

    # ---- 3. 工作区也照搬（对话页的文件卡片读的是管理区，但任务页要工作区）----
    for r in rows:
        s = os.path.join(PROD, "workspaces", "chat-" + r["id"])
        d = os.path.join(INST, "workspaces", "chat-" + r["id"])
        if os.path.isdir(s) and not os.path.exists(d):
            a, b = build_tree(s, d, 0, 2)
            print("  工作区 %s：%d 目录 / %d 文件" % (r["id"], a, b))

    # ---- 4. 库：把 uid=11 建成一个密码已知的账号 ----
    inst = sqlite3.connect(os.path.join(INST, "dsapp.sqlite3"))
    cols = [c[1] for c in inst.execute("PRAGMA table_info(users)")]
    u = {k: v for k, v in u.items() if k in cols}
    u["id"] = UID
    u["pass_salt"] = SALT
    u["pass_hash"] = pw_hash(PW, SALT)
    u["status"] = "active"
    # ⚠️ `token` 在库里是 NOT NULL —— 置成 NULL 会当场 IntegrityError。
    #    生产那行本来就有个真 token，照抄过来就行；这里清空是因为它是
    #    **明文 bearer**（本仓有账），不该跟着夹具到处跑。
    u["token"] = ""
    inst.execute("DELETE FROM users WHERE id=?", (UID,))
    inst.execute("INSERT INTO users (%s) VALUES (%s)"
                 % (",".join(u), ",".join("?" * len(u))), list(u.values()))
    for r in rows:
        inst.execute("DELETE FROM sessions WHERE id=?", (r["id"],))
        inst.execute("INSERT INTO sessions (id, title, created_at, updated_at,"
                     " user_id) VALUES (?,?,?,?,?)",
                     (r["id"], r["title"], r["created_at"], r["updated_at"], UID))
    inst.commit()
    inst.close()
    print("\n登录：%s  密码：%s" % (u.get("email"), PW))
    return 0


if __name__ == "__main__":
    sys.exit(main())
