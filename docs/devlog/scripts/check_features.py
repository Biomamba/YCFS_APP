#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""YCFS_APP 功能自检（只读）。

读 docs/devlog/features.json，把 verify.kind=http 的条目逐条跑一遍，输出
OK / FAIL / MANUAL 表与汇总。默认只跑 http；--include-cli 才会跑 cli 条目
（cli 条目也全部是只读命令：systemctl is-active / ss / df / sqlite3 mode=ro）。

用法:
  python3 check_features.py                          # 在本机（默认 127.0.0.1:34039）
  python3 check_features.py --base http://127.0.0.1:34039/YCFS_APP
  python3 check_features.py --include-cli            # 连 cli 条目一起跑
  python3 check_features.py --layer web,ops           # 只跑某些 layer
  python3 check_features.py --json-out /tmp/x.json    # 机器可读结果
  python3 check_features.py --list                    # 只列出条目，不执行

匹配规则（verify.expect）:
  "200"            stdout 去掉首尾空白后必须等于 200
  "303|401|405"    任一即可
  "re:^OK 17/17"   对 stdout 做正则 search
  其它             字符串相等

退出码: 0 = 无 FAIL；1 = 有 FAIL；2 = 用法/文件错误。
只读保证：不改库、不写配置、不重启服务；http 探测全是 GET 或空体 POST 的
「路由存在性」探测（未登录时预期 401/405/409/303，不产生业务写入）。
"""
from __future__ import print_function

import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_BASE = "http://127.0.0.1:34039/YCFS_APP"
STATUS = []


def load_features(path):
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    if isinstance(doc, list):
        return {"features": doc}
    if not isinstance(doc, dict) or "features" not in doc:
        raise ValueError("features.json 形状不对：既不是数组，也没有 features 字段")
    return doc


def find_features(explicit, script_dir):
    if explicit:
        return explicit
    cands = [
        os.path.join(script_dir, "..", "features.json"),
        os.path.join(script_dir, "features.json"),
        "features.json",
        os.path.join("docs", "devlog", "features.json"),
    ]
    for c in cands:
        c = os.path.abspath(c)
        if os.path.isfile(c):
            return c
    raise SystemExit("找不到 features.json；用 --features 指定")


def match(expect, out):
    exp = (expect or "").strip()
    out = (out or "").strip()
    if exp.startswith("re:"):
        try:
            return re.search(exp[3:], out) is not None
        except re.error as exc:
            return False
    if "|" in exp:
        return out in [p.strip() for p in exp.split("|")]
    return out == exp


def run_cmd(cmd, timeout):
    """返回 (stdout, note)。只读命令；超时/异常不抛。"""
    try:
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        try:
            raw, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            raw, _ = proc.communicate()
            return raw.decode("utf-8", "replace"), "timeout(%ss)" % timeout
        out = raw.decode("utf-8", "replace")
        if proc.returncode != 0:
            return out, "rc=%d" % proc.returncode
        return out, ""
    except Exception as exc:                      # noqa: BLE001 - 自检不允许崩
        return "", "exec-error:%s" % exc


def main():
    ap = argparse.ArgumentParser(description="YCFS_APP 功能自检（只读）")
    ap.add_argument("--features", help="features.json 路径")
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="替换命令里的 %s" % DEFAULT_BASE)
    ap.add_argument("--include-cli", action="store_true",
                    help="同时执行 verify.kind=cli 的只读命令")
    ap.add_argument("--layer", help="只跑这些 layer，逗号分隔")
    ap.add_argument("--id", help="只跑这些 id，逗号分隔")
    ap.add_argument("--timeout", type=int, default=20, help="单条命令超时秒数")
    ap.add_argument("--json-out", help="把结果写成 JSON")
    ap.add_argument("--list", action="store_true", help="只列条目，不执行")
    ap.add_argument("--quiet", action="store_true", help="只打印表尾汇总")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = find_features(args.features, script_dir)
    doc = load_features(path)
    feats = doc["features"]

    only_layers = set(x.strip() for x in args.layer.split(",")) if args.layer else None
    only_ids = set(x.strip() for x in args.id.split(",")) if args.id else None

    rows = []
    for f in feats:
        if only_layers and f.get("layer") not in only_layers:
            continue
        if only_ids and f.get("id") not in only_ids:
            continue
        kind = (f.get("verify") or {}).get("kind", "ui")
        if kind == "ui" or not (f.get("verify") or {}).get("cmd"):
            rows.append((f, "MANUAL", "-", "kind=ui（人工确认）"))
            continue
        if kind == "cli" and not args.include_cli:
            rows.append((f, "MANUAL", "-", "kind=cli（未加 --include-cli）"))
            continue
        if kind not in ("http", "cli"):
            rows.append((f, "MANUAL", "-", "未知 kind=%s" % kind))
            continue
        cmd = f["verify"]["cmd"].replace(DEFAULT_BASE, args.base)
        if args.list:
            rows.append((f, "LIST", kind, cmd))
            continue
        out, note = run_cmd(cmd, args.timeout)
        ok = match(f["verify"].get("expect"), out)
        got = out.strip().replace("\n", " | ")
        if len(got) > 70:
            got = got[:67] + "..."
        verdict = "OK" if ok else "FAIL"
        detail = got if got else "(no output)"
        if note:
            detail = "%s [%s]" % (detail, note)
        rows.append((f, verdict, kind, detail))

    if not args.quiet:
        for f, verdict, kind, detail in rows:
            print("[%-4s] %-9s %-34s %s" % (verdict, kind, f["id"], detail))
        print("")

    counts = {"OK": 0, "FAIL": 0, "MANUAL": 0, "LIST": 0}
    per_layer = {}
    for f, verdict, _kind, _d in rows:
        counts[verdict] = counts.get(verdict, 0) + 1
        lay = per_layer.setdefault(f.get("layer", "?"), {"OK": 0, "FAIL": 0, "MANUAL": 0})
        lay[verdict] = lay.get(verdict, 0) + 1

    print("features: %s" % os.path.abspath(path))
    print("base    : %s" % args.base)
    print("mode    : http%s" % ("+cli" if args.include_cli else " only"))
    print("")
    print("| layer | OK | FAIL | MANUAL |")
    print("|---|---|---|---|")
    for lay in ["web", "chat", "model", "runner", "transfer", "jupyter", "audio", "admin", "ops"]:
        if lay in per_layer:
            c = per_layer[lay]
            print("| %s | %d | %d | %d |" % (lay, c.get("OK", 0), c.get("FAIL", 0), c.get("MANUAL", 0)))
    print("| **合计** | **%d** | **%d** | **%d** |" % (counts["OK"], counts["FAIL"], counts["MANUAL"]))
    print("")
    print("汇总: OK=%d FAIL=%d MANUAL=%d" % (counts["OK"], counts["FAIL"], counts["MANUAL"]))

    fails = [f["id"] + " -> " + d for f, v, _k, d in rows if v == "FAIL"]
    if fails:
        print("")
        print("FAIL 明细:")
        for x in fails:
            print("  - " + x)

    if args.json_out:
        payload = {
            "features_file": os.path.abspath(path),
            "base": args.base,
            "include_cli": args.include_cli,
            "counts": counts,
            "rows": [{"id": f["id"], "layer": f.get("layer"), "verdict": v,
                      "kind": k, "detail": d} for f, v, k, d in rows],
        }
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print("json -> %s" % args.json_out)

    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
