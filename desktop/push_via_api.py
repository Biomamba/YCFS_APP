#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一棵 git 工作树**通过 GitHub API** 推上去 —— 不用 `git push`。

    python3 desktop/push_via_api.py <工作树> [--repo owner/name] [--branch main]
                                           [--message "..."] [--dry-run]

=============================================================================
为什么会有这个东西（2026-10-07 实测）
=============================================================================

打包这台机器上 **`github.com:443` 是不通的**，而 `api.github.com` 稳如磐石：

    api.github.com                   200  connect=0.147s total=0.373s   ← 每次都快
    codeload.github.com              301  connect=0.145s
    objects.githubusercontent.com    404  connect=0.278s
    raw.githubusercontent.com        301  connect=0.171s
    github.com                       —— 挂住不动

`github.com` 的 TCP 成功率实测 **3/8**（连八次通三次）。`git push` 要的是一条
持续几十秒的连接，`timeout 60 git push` 直接 exit 124（超时被杀）。

⇒ 所以走 Git Data API：`POST /git/blobs` → `POST /git/trees` → `POST /git/commits`
→ `POST /git/refs`。**全程只碰 api.github.com**，一次 `github.com` 都不访问。

⚠️ 两个仓库的 URL 不一样，别搞混：
     · `https://github.com/o/r.git`      ← git push 走这个（**本机不通**）
     · `https://api.github.com/repos/o/r` ← 这个脚本走这个（通）

=============================================================================
它和 `git push` 有什么不一样（说清楚，免得以为等价）
=============================================================================

· **只出一个 commit**，没有本地历史。对首次发布无所谓（本地那棵树本来也就是
  `pack_github.sh` 现 `git init` 的一次提交）。
· **不碰本地 .git**。文件清单从 `git ls-files` 取（这样 .gitignore 的过滤、
  可执行位、符号链接都自动跟着走），但内容是从**磁盘**现读的，本地索引和
  远端不需要一致。
· **空仓库才有干净路径**：仓库已经有 `refs/heads/<branch>` 时会**拒绝**，
  除非加 `--force`（那会用新 commit 顶掉分支，**旧提交成为孤儿**）。
  这个默认是故意的 —— 顶掉一个已经公开的分支不该是一不留神就发生的事。
"""

import argparse
import base64
import collections
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://api.github.com"
UA = "dsapp-push-via-api/1"

# GitHub 对"内容创建类"请求（/git/blobs 这种，一次创建一个对象）有**独立于**
# 常规配额的次级限流：**80 次/分钟**。留出余量。
BLOBS_PER_MIN = 60


def die(msg):
    print("!! %s" % msg, file=sys.stderr)
    sys.exit(1)


def say(msg):
    print("== %s" % msg, flush=True)


def read_token():
    """从凭据文件里取 token。

    ⚠️ 只读不打印。这个脚本的任何一行输出里都不该出现 token —— 日志是要给人
       看的，也是要进 CI 的。
    """
    path = os.environ.get("DSAPP_GH_TOKEN_FILE", os.path.expanduser("~/.dsapp_gh_cred"))
    if not os.path.exists(path):
        die("没有 %s。先跑 desktop/setup_github_cred.sh（或者设 DSAPP_GH_TOKEN_FILE）。" % path)
    s = open(path).read().strip()
    # 形如 https://<user>:<token>@github.com —— 用 rsplit 从右边切，token 里
    # 万一有 '@' 也不会切错（GitHub 的 token 字符集里没有，但防御一下不亏）。
    m = None
    if "://" in s and "@" in s:
        rest = s.split("://", 1)[1]
        cred, _host = rest.rsplit("@", 1)
        if ":" in cred:
            m = cred.split(":", 1)[1]
    tok = m or s          # 也允许文件里直接就是 token 本身
    if not tok:
        die("%s 里读不出 token" % path)
    return tok


class SoftFail(Exception):
    """`soft=True` 时，一个 4xx 用这个抛出来，交给调用方决定怎么办 ——
    而不是像 die() 那样直接结束进程。给"这条路不行就走另一条"的场合用。"""


class Limiter(object):
    """滑动窗口限流：window 秒内最多 n 次。

    给"内容创建类"请求用。实测撞上的样子（2026-10-07）：8 个线程并发推 454 个
    blob，到第 ~400 个时开始一路

        403 {"message":"You have exceeded a secondary rate limit. ..."}

    ⚠️ 是 **403 不是 429**。把它当"4xx = 请求本身有问题"去 die 的话，等于把
       一次"等一分钟就能过"的推送整个作废。
    """

    def __init__(self, n, window=60.0):
        self.n = n
        self.window = window
        self.t = collections.deque()
        self.lock = threading.Lock()

    def wait(self):
        while True:
            with self.lock:
                now = time.time()
                while self.t and now - self.t[0] > self.window:
                    self.t.popleft()
                if len(self.t) < self.n:
                    self.t.append(now)
                    return
                delay = self.window - (now - self.t[0]) + 0.1
            time.sleep(delay)


class GH(object):
    def __init__(self, token):
        self.token = token
        self.n = 0

    def __call__(self, method, path, body=None, retries=6, not_found_ok=False,
                 soft=False, gate=None):
        """打一次 API。路径是 `/repos/...` 这种（相对 api.github.com）。

        `not_found_ok=True` 时 404 返回 None 而不是当场退出 —— "分支还不存在"
          是个**正常状态**（空仓库就这样），不该让它看起来像出错。
        `soft=True`   时 4xx 抛 SoftFail 而不是退出（给"还有退路"的调用方）。
        `gate=Limiter` 时先过限流闸再发（内容创建类请求必须挂）。
        """
        url = path if path.startswith("http") else API + path
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        last = None
        for attempt in range(retries):
            if gate is not None:
                gate.wait()
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", "Bearer " + self.token)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("X-GitHub-Api-Version", "2022-11-28")
            req.add_header("User-Agent", UA)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=300) as r:
                    self.n += 1
                    raw = r.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                detail = e.read().decode("utf-8", "replace")[:400]
                # ⚠️ 空仓库上取 ref 回的是 **409 "Git Repository is empty."**，
                #    不是 404 —— 实测（2026-10-07）。少认这一个，全新仓库就
                #    永远走不到"建第一个 ref"那一步。
                if e.code in (404, 409) and not_found_ok:
                    self.n += 1
                    return None
                # ★ 次级限流：**等一会儿就能过**，不是"我们错了"。
                #   GitHub 会给 Retry-After；没给就退避。
                if e.code in (403, 429) and "rate limit" in detail.lower():
                    ra = (e.headers.get("Retry-After") or "").strip() \
                        if e.headers else ""
                    wait = float(ra) if ra.isdigit() else 15.0 * (attempt + 1)
                    say("  · 撞上限流，等 %.0f 秒（%s #%d）"
                        % (wait, method, attempt + 1))
                    time.sleep(wait)
                    last = "HTTP %d（限流）" % e.code
                    continue
                # 其余 4xx 是"我们错了"，重试没用。
                if e.code < 500:
                    if soft:
                        raise SoftFail("HTTP %d %s"
                                       % (e.code, detail.replace("\n", " ")[:200]))
                    die("%s %s → HTTP %d\n%s" % (method, path, e.code, detail))
                last = "HTTP %d: %s" % (e.code, detail)
            except SoftFail:
                raise
            except Exception as e:                       # noqa: BLE001
                last = "%s: %s" % (type(e).__name__, e)
            time.sleep(1.5 * (attempt + 1))
        die("%s %s 试了 %d 次都不行 —— %s" % (method, path, retries, last))


def ls_files(tree):
    """从 git 索引取要推的文件清单（模式 + 路径）。

    为什么用 `git ls-files` 而不是 os.walk：
      · .gitignore 的过滤自动生效（不会把 out/、dl/、__pycache__ 推上去）；
      · **可执行位和符号链接** git 已经算好了（100644 / 100755 / 120000），
        不用自己在 Python 里重新推一遍 POSIX 权限语义。
    """
    out = subprocess.run(["git", "-C", tree, "ls-files", "-s", "-z"],
                         capture_output=True, check=True).stdout
    files = []
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode = meta.split(b" ")[0].decode()
        files.append((mode, path.decode("utf-8", "surrogateescape")))
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree", help="工作树目录")
    ap.add_argument("--repo", default="Biomamba/YCFS_APP")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--message", default=None)
    ap.add_argument("--force", action="store_true",
                    help="分支已存在时也推（旧提交会变成孤儿）")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    tree = os.path.abspath(args.tree)
    if not os.path.isdir(os.path.join(tree, ".git")):
        die("%s 不是 git 工作树（没有 .git）" % tree)

    gh = GH(read_token())

    # ---- 0. 身份 + 仓库 ------------------------------------------------------
    me = gh("GET", "/user")
    repo = gh("GET", "/repos/" + args.repo)
    say("身份 %s → %s（%s）" % (me.get("login"), repo["full_name"],
                              "公开" if not repo["private"] else "私有"))

    files = ls_files(tree)
    total = sum(os.path.getsize(os.path.join(tree, p))
                for m, p in files if m != "120000")
    say("要推 %d 个文件，%.1f MB" % (len(files), total / 1024.0 / 1024.0))

    # ---- 1. 分支已存在？先问清楚 ---------------------------------------------
    refpath = "/repos/%s/git/ref/heads/%s" % (args.repo, args.branch)
    # ⚠️⚠️ 单数/复数不是笔误，GitHub 就是这么设计的：
    #       GET    /repos/{o}/{r}/git/ref/{ref}     ← 单数，取一个
    #       PATCH  /repos/{o}/{r}/git/refs/{ref}    ← **复数**，改一个
    #       POST   /repos/{o}/{r}/git/refs          ← 复数，建一个
    #     拿 GET 那个路径去 PATCH 回的是 **404 Not Found**（实测 2026-10-07，
    #     树和提交都建好了、倒在最后一步）。而且在"建新 ref"那条路上它不报错
    #     —— 因为那条走的是 POST /git/refs，本来就是复数。所以只有当分支**已经
    #     存在**、需要 force 更新时才现形。
    refpath_w = "/repos/%s/git/refs/heads/%s" % (args.repo, args.branch)
    cur = gh("GET", refpath, not_found_ok=True)
    exist = (cur or {}).get("object", {}).get("sha")
    if exist and not args.force:
        die("远端 %s 已经有 %s 了（%s）。\n"
            "   要么换个分支名，要么加 --force —— 但 --force 会让现有那个提交\n"
            "   变成孤儿（不是删掉，是没人指向它了）。看清楚再决定。"
            % (args.repo, args.branch, exist[:10]))
    say("远端 %s 分支：%s" % (args.branch, exist[:10] if exist else "（还没有，全新）"))

    if args.dry_run:
        say("--dry-run：到此为止，一个字节都没发。")
        return

    # ---- 1b. ★ 空仓库要先"激活" ----------------------------------------------
    #
    # ⚠️⚠️ 实测（2026-10-07）：**Git Data API 在空仓库上整个是关着的** ——
    #     `POST /git/blobs`、`GET /git/ref/...` 一律回
    #        409 {"message":"Git Repository is empty."}
    #     （注意是 409 不是 404，连 ref 都不给查。）
    #
    #     所以先用 **Contents API** 放一个 README.md 进去 —— 那个接口在空仓库上
    #     是能用的，它会顺手建出第一个提交和默认分支。之后 Git Data API 才打开。
    #
    #     代价是历史里多一个提交（种子 → 全量）。最终**树**是对的：下面推的
    #     tree 是整个根树，README.md 也在里面，所以种子那个提交留下的文件不会
    #     缺、也不会重复。
    if not exist:
        seed = os.path.join(tree, "README.md")
        if not os.path.exists(seed):
            die("远端是空仓库，需要先用 Contents API 放一个文件激活；"
                "但 %s 里没有 README.md，换个种子文件重跑。" % tree)
        say("远端是空仓库 —— 先用 Contents API 放 README.md 把它激活")
        gh("PUT", "/repos/%s/contents/README.md" % args.repo, {
            "message": "初始化仓库（push_via_api.py 的种子提交）",
            "content": base64.b64encode(open(seed, "rb").read()).decode("ascii"),
        })
        time.sleep(2)
        cur = gh("GET", refpath, not_found_ok=True)
        exist = (cur or {}).get("object", {}).get("sha")
        if not exist:
            die("激活之后还是取不到 refs/heads/%s —— Contents API 建到别的分支去了？"
                % args.branch)
        say("激活后 refs/heads/%s = %s" % (args.branch, exist[:10]))

    # ---- 2. 建树 -------------------------------------------------------------
    #
    # ★★ 2026-10-07 第二次实测：**逐个建 blob 会撞 GitHub 的"次级限流"**。
    #
    #    `/git/blobs` 属于"内容创建类"请求，GitHub 给它的配额是**独立的**：
    #    80 次/分钟。8 个线程一起推 454 个文件，一秒就烧穿，然后从第 ~400 个
    #    开始一路 403（实测原文见 Limiter 的注释）。**第一次推送就是这么废掉的。**
    #
    #    但 `/git/trees` 支持**把内容内联**（entry 带 `content` 而不是 `sha`）。
    #    已实测 201。于是 454 次请求变成 **1 次** —— 限流问题从根上没了，而且
    #    快得多（实测起一棵单条树 0.9 秒）。
    #
    #    ⚠️ `content` 得是合法 UTF-8 字符串，所以二进制文件仍然走逐文件建
    #       blob，**并且挂上限流闸**。本仓是 3 个（两个图标 + 一张二维码）。
    def read_raw(mode, path):
        full = os.path.join(tree, path)
        if mode == "120000":                 # symlink：内容是链接目标本身
            return os.readlink(full).encode("utf-8")
        with open(full, "rb") as f:
            return f.read()

    def build_blobs(items):
        """逐文件建 blob（给二进制用，也当内联失败时的退路）。全程限速。"""
        gate = Limiter(BLOBS_PER_MIN)

        def one(item):
            mode, path = item
            r = gh("POST", "/repos/%s/git/blobs" % args.repo, {
                "content": base64.b64encode(read_raw(mode, path)).decode("ascii"),
                "encoding": "base64",
            }, gate=gate)
            return {"path": path, "mode": mode, "type": "blob", "sha": r["sha"]}

        got = []
        with ThreadPoolExecutor(max_workers=4) as pool:
            for i, e in enumerate(pool.map(one, items), 1):
                got.append(e)
                if len(items) > 10 and (i % 25 == 0 or i == len(items)):
                    say("  %d/%d" % (i, len(items)))
        return got

    inline, binary = [], []
    for m, p in files:
        try:
            text = read_raw(m, p).decode("utf-8")
        except UnicodeDecodeError:
            binary.append((m, p))
            continue
        inline.append({"path": p, "mode": m, "type": "blob", "content": text})

    entries = list(inline)
    if binary:
        say("%d 个文件不是 UTF-8（内联不了），逐个建 blob（限速 %d 次/分钟）：%s"
            % (len(binary), BLOBS_PER_MIN,
               "、".join(p for _m, p in binary)))
        entries += build_blobs(binary)

    say("把 %d 个文件的内容内联进 tree（1 次请求，而不是 %d 次）"
        % (len(inline), len(files)))
    t = None
    try:
        t = gh("POST", "/repos/%s/git/trees" % args.repo, {"tree": entries},
               soft=True, retries=2)
    except SoftFail as e:
        say("内联建树被拒（%s）—— 退回逐个建 blob（慢，但一定能过）" % e)
    if t is None:
        say("逐个建 blob，共 %d 个，按 %d 次/分钟大约要 %.1f 分钟……"
            % (len(files), BLOBS_PER_MIN, len(files) / float(BLOBS_PER_MIN)))
        entries = build_blobs(files)
        t = gh("POST", "/repos/%s/git/trees" % args.repo, {"tree": entries})
    say("tree  %s（%d 项，API 调用共 %d 次）" % (t["sha"][:10], len(entries), gh.n))

    # ---- 3. commit → ref -----------------------------------------------------
    msg = args.message or ("YCFS_APP：言出法随生信分析 Agent（R Shiny）\n"
                           "\n经 desktop/push_via_api.py 推送（本机 github.com 不可达）。")
    commit = gh("POST", "/repos/%s/git/commits" % args.repo, {
        "message": msg,
        "tree": t["sha"],
        "parents": [exist] if exist else [],
        "author": {"name": me.get("name") or me["login"],
                   "email": "%s+%s@users.noreply.github.com" % (me["id"], me["login"])},
    })
    say("commit %s" % commit["sha"][:10])

    if exist:
        gh("PATCH", refpath_w, {"sha": commit["sha"], "force": True})
        say("refs/heads/%s 已更新（force）" % args.branch)
    else:
        gh("POST", "/repos/%s/git/refs" % args.repo,
           {"ref": "refs/heads/" + args.branch, "sha": commit["sha"]})
        say("refs/heads/%s 已创建" % args.branch)

    # ---- 4. 回读确认 ---------------------------------------------------------
    # ⚠️ 不信"API 说成功了"。回读一遍远端真实的 ref 和文件数 —— 本仓的规矩是
    #    "写操作后面都要回库核对"，只不过这次"库"在 GitHub 上。
    time.sleep(2)
    back = gh("GET", refpath)
    sha = back["object"]["sha"]
    head = gh("GET", "/repos/%s/commits/%s" % (args.repo, sha))
    say("回读：refs/heads/%s = %s，commit 里的 tree = %s"
        % (args.branch, sha[:10], head["commit"]["tree"]["sha"][:10]))
    if sha != commit["sha"]:
        die("回读拿到的 SHA 和推上去的不一样！远端 = %s 本地 = %s"
            % (sha, commit["sha"]))
    say("一致 ✓   网页：https://github.com/%s/tree/%s" % (args.repo, args.branch))


if __name__ == "__main__":
    main()
