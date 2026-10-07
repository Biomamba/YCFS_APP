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
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://api.github.com"
UA = "dsapp-push-via-api/1"


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


class GH(object):
    def __init__(self, token):
        self.token = token
        self.n = 0

    def __call__(self, method, path, body=None, retries=4, not_found_ok=False):
        """打一次 API。路径是 `/repos/...` 这种（相对 api.github.com）。

        `not_found_ok=True` 时 404 返回 None 而不是当场退出 —— "分支还不存在"
          是个**正常状态**（空仓库就这样），不该让它看起来像出错。
        """
        url = path if path.startswith("http") else API + path
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        last = None
        for attempt in range(retries):
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", "Bearer " + self.token)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("X-GitHub-Api-Version", "2022-11-28")
            req.add_header("User-Agent", UA)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    self.n += 1
                    raw = r.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                detail = e.read().decode("utf-8", "replace")[:400]
                if e.code == 404 and not_found_ok:
                    self.n += 1
                    return None
                # 4xx 是"我们错了"，重试没用；除了 429（限流）和 5xx。
                if e.code < 500 and e.code != 429:
                    die("%s %s → HTTP %d\n%s" % (method, path, e.code, detail))
                last = "HTTP %d: %s" % (e.code, detail)
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

    # ---- 2. 建 blob（并行；这是 90% 的耗时）----------------------------------
    say("建 blob……")

    def one(item):
        mode, path = item
        full = os.path.join(tree, path)
        if mode == "120000":                     # symlink：内容是链接目标本身
            raw = os.readlink(full).encode("utf-8")
        else:
            with open(full, "rb") as f:
                raw = f.read()
        r = gh("POST", "/repos/%s/git/blobs" % args.repo, {
            "content": base64.b64encode(raw).decode("ascii"),
            "encoding": "base64",
        })
        return {"path": path, "mode": mode, "type": "blob", "sha": r["sha"]}

    entries = []
    done = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for e in pool.map(one, files):
            entries.append(e)
            done += 1
            if done % 50 == 0 or done == len(files):
                say("  %d/%d" % (done, len(files)))
    say("blob 建完（API 调用 %d 次）" % gh.n)

    # ---- 3. tree → commit → ref ---------------------------------------------
    t = gh("POST", "/repos/%s/git/trees" % args.repo, {"tree": entries})
    say("tree  %s（%d 项）" % (t["sha"][:10], len(entries)))

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
        gh("PATCH", refpath, {"sha": commit["sha"], "force": True})
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
