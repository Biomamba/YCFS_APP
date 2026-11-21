#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""追加一条开发日志到 docs/devlog/devlog.jsonl（追加式，只增不改）。

参数:
  --version   V21.53
  --kind      release | fix | ops | incident | decision
  --title     一行标题
  --summary   详细说明（可多行，建议一段话）
  --files     改动文件/脚本路径，可重复或用逗号分隔（不要写密钥文件内容）
  --verify    验证命令/判据，可重复；建议带【940】/【官网机】/【大禹】前缀
  --rollback  回滚动作
  --req-refs  对应需求编号（2026-11-21-#2 这种），可重复
  --evidence  证据（版本头 / catalog.current / sha256 / 报告路径）
  --ts        覆盖时间戳（默认 now，带本地时区偏移）
  --file      指定 devlog.jsonl（默认 ../devlog.jsonl 相对本脚本）
  --dry-run   只打印将要追加的那一行
  --check     不追加，只校验已有文件每行都是合法 JSON

行为:
  1. 写前把这一行 json.dumps 后 json.loads 复核；
  2. 追加写（'a'）并 fsync，绝不重写历史行；
  3. 写后逐行 json.loads 复核整个文件，任何一行坏了就报错并以 1 退出
     （此时新增行已经落盘，需人工修）。
"""
from __future__ import print_function

import argparse
import datetime
import json
import os
import sys

KINDS = ("release", "fix", "ops", "incident", "decision")
FIELDS_ORDER = ["ts", "version", "kind", "title", "summary", "files", "verify",
                "rollback", "req_refs", "evidence"]


def local_ts():
    # 不能用 datetime.now().astimezone() 的 ISO 里那串 "+08:00" 之外的格式差异
    now = datetime.datetime.now().astimezone()
    off = now.utcoffset()
    total = int(off.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    return "%s%s%02d:%02d" % (now.strftime("%Y-%m-%dT%H:%M:%S"), sign,
                              total // 3600, (total % 3600) // 60)


def as_list(values):
    out = []
    for v in values or []:
        for part in str(v).split(","):
            part = part.strip()
            if part:
                out.append(part)
    return out


def default_file(script_dir):
    return os.path.abspath(os.path.join(script_dir, "..", "devlog.jsonl"))


def check_file(path):
    bad = 0
    n = 0
    with open(path, "r", encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            s = line.strip()
            if not s:
                continue
            n += 1
            try:
                obj = json.loads(s)
                if "ts" not in obj or "title" not in obj:
                    print("第 %d 行缺 ts/title" % i)
                    bad += 1
            except Exception as exc:              # noqa: BLE001
                print("第 %d 行不是合法 JSON: %s" % (i, exc))
                bad += 1
    print("%s: %d 行，坏行 %d" % (path, n, bad))
    return bad


def main():
    ap = argparse.ArgumentParser(description="追加一条 YCFS 开发日志")
    ap.add_argument("--version", required=False, default="")
    ap.add_argument("--kind", required=False, default="")
    ap.add_argument("--title", required=False, default="")
    ap.add_argument("--summary", required=False, default="")
    ap.add_argument("--files", action="append", default=[])
    ap.add_argument("--verify", action="append", default=[])
    ap.add_argument("--rollback", required=False, default="")
    ap.add_argument("--req-refs", action="append", default=[])
    ap.add_argument("--evidence", required=False, default="")
    ap.add_argument("--ts", required=False, default="")
    ap.add_argument("--file", required=False, default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = args.file or default_file(script_dir)

    if args.check:
        if not os.path.isfile(path):
            print("文件不存在: %s" % path)
            return 2
        return 1 if check_file(path) else 0

    explicit = args.version or args.kind or args.title or args.summary
    if explicit:
        missing = [k for k, v in (("--version", args.version), ("--kind", args.kind),
                                  ("--title", args.title), ("--summary", args.summary)) if not v]
        if missing:
            print("缺参数: %s" % " ".join(missing))
            return 2
    else:
        print("至少要给 --version --kind --title --summary（或用 --check）")
        return 2

    if args.kind not in KINDS:
        print("--kind 只能是 %s" % "/".join(KINDS))
        return 2

    entry = {
        "ts": args.ts or local_ts(),
        "version": args.version,
        "kind": args.kind,
        "title": args.title,
        "summary": args.summary,
        "files": as_list(args.files),
        "verify": as_list(args.verify),
        "rollback": args.rollback,
        "req_refs": as_list(args.req_refs),
        "evidence": args.evidence,
    }
    entry = dict((k, entry[k]) for k in FIELDS_ORDER if k in entry)

    line = json.dumps(entry, ensure_ascii=False)
    # 1) 写前自检：序列化结果必须能被解析回来，且字段齐全
    back = json.loads(line)
    assert back["ts"] == entry["ts"] and back["title"] == entry["title"]
    if len(line.splitlines()) != 1:
        print("序列化后不是单行，拒绝写入")
        return 1

    if args.dry_run:
        print(line)
        return 0

    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)

    need_nl = False
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as fh:
            fh.seek(-1, os.SEEK_END)
            need_nl = fh.read(1) != b"\n"

    # 2) 追加写，绝不重写历史行
    with open(path, "a", encoding="utf-8") as fh:
        if need_nl:
            fh.write("\n")
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())

    print("追加成功: %s" % path)
    print(line)
    # 3) 写后逐行复核
    bad = check_file(path)
    if bad:
        print("警告：文件里有坏行（新增行已落盘，请人工处理）")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
