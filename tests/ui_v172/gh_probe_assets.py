# -*- coding: utf-8 -*-
"""验 Release 上的桌面版附件：**结构 + 集合 + 哈希**三件事，不下载整包。

    python3 tests/ui_v172/gh_probe_assets.py Test_V17.2

为什么要这么验（本仓在这件事上栽过八轮，别只看 CI 的绿勾）：

  · 「有个 244 MB 的 .exe」≠ 它是可执行文件 —— 有同后缀的东西顶包过
    （第七次：CI 六条 job 全绿八轮，产物是 node_modules 里的同名文件）。
    PE 头 `MZ` + `e_lfanew` 指向的 `PE\\0\\0`、dmg **尾部**的 `koly` trailer
    是**产物自己带的**，顶不了。
  · 「六个附件都在」≠ 「只有这六个」 —— 往公开 Release 上发过一个 **480 B 的
    `example.zip`**（R 的 zip 包夹具，藏在 .app 里的便携 R 库树中）。
    所以名字**双向**比：清单里有而附件里没有 ✗，附件里有而清单里没有 ✗。
  · 只查结构不查哈希，就发现不了"文件传坏了/传串了"。

集合与哈希都靠 **`SHA256SUMS.txt` 自己**对（它也是附件之一），所以**不用下载
1.2 GB** 就能逐条核。⚠️ 本仓的老账：`sha256sum` 曾经在**改名前**算，而 GitHub
上传时把名字里的空格换成点 ⇒ 清单里那行指向一个不存在的文件。下面用
`digest` 字段对，正是为了正面撞上这一类。
"""
import io, json, os, re, sys, time, urllib.request

REPO = "Biomamba/YCFS_APP"
tag = sys.argv[1] if len(sys.argv) > 1 else "Test_V17.2"

# 该有的 6 个产物（不含 SHA256SUMS.txt 本身）
WANT = [
    re.compile(r"^ds-app\.Setup\.[\d.]+\.exe$"),      # Windows 安装包
    re.compile(r"^ds-app-[\d.]+\.dmg$"),              # macOS x64 安装包
    re.compile(r"^ds-app-[\d.]+-arm64\.dmg$"),        # macOS arm64 安装包
    re.compile(r"^DS_App-Windows-[\w.]+\.zip$"),      # 免安装
    re.compile(r"^DS_App-macOS-arm64-[\w.]+\.zip$"),
    re.compile(r"^DS_App-macOS-x86_64-[\w.]+\.zip$"),
]


def get(url, a=None, b=None, tries=4):
    """取字节。**必须重试**：这台机器到 github.com 的链路成功率只有 3/8，
        附件下载还要再跳到 objects.githubusercontent.com，一次就成是运气。
        不加这个的话，探针会在"链接抖了一下"时报成"产物结构不对"。"""
    last = None
    for i in range(tries):
        h = {"User-Agent": "t/1"}
        if a is not None:
            h["Range"] = "bytes=%d-%d" % (a, b)
        req = urllib.request.Request(url, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read(), r.headers
        except Exception as e:
            last = e
            time.sleep(2 * (i + 1))
    raise last


def api_blob(asset_id, a=None, b=None):
    """小文件走 API（api.github.com 稳），大文件才走下载地址。"""
    h = {"User-Agent": "t/1", "Accept": "application/octet-stream"}
    if a is not None:
        h["Range"] = "bytes=%d-%d" % (a, b)
    req = urllib.request.Request(
        "https://api.github.com/repos/%s/releases/assets/%d" % (REPO, asset_id),
        headers=h)
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read(), r.headers


def gh(path):
    req = urllib.request.Request("https://api.github.com" + path,
                                 headers={"User-Agent": "t/1",
                                          "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


rels = [r for r in gh("/repos/%s/releases" % REPO) if r["tag_name"] == tag]
if not rels:
    print("\033[31m✗\033[0m 没有 tag = %s 的 Release" % tag)
    sys.exit(1)
rel = rels[0]
assets = {a["name"]: a for a in rel["assets"]}
print("Release %s（%s），附件 %d 个" % (rel["tag_name"], rel["published_at"], len(assets)))
bad = 0

# ---------- 一、名字双向比 ----------
payload = sorted(n for n in assets if n != "SHA256SUMS.txt")
missing = [p.pattern for p in WANT if not any(p.match(n) for n in payload)]
for pat in missing:
    print("  \033[31m✗\033[0m 该有的产物没找到：%s" % pat)
    bad += 1
extra = [n for n in payload if not any(p.match(n) for p in WANT)]
for n in extra:
    print("  \033[31m✗\033[0m 多出来的附件（清单里没有）：%s  %.1f KB" % (n, assets[n]["size"] / 1e3))
    bad += 1
print("  %s 名字：该有 %d 个，实际 %d 个，多 %d 少 %d"
      % ("\033[32m✓\033[0m" if not (missing or extra) else "\033[31m✗\033[0m",
         len(WANT), len(payload), len(extra), len(missing)))

# ---------- 二、SHA256SUMS.txt 对哈希（用 digest，不下载） ----------
if "SHA256SUMS.txt" not in assets:
    print("  \033[31m✗\033[0m 没有 SHA256SUMS.txt，哈希无从核起")
    bad += 1
else:
    txt, _ = api_blob(assets["SHA256SUMS.txt"]["id"])
    sums = {}
    for line in txt.decode("utf-8", "replace").splitlines():
        m = re.match(r"^([0-9a-f]{64})\s+\*?(.+)$", line.strip())
        if m:
            sums[m.group(2).strip()] = m.group(1)
    print("  SHA256SUMS.txt 里 %d 行" % len(sums))
    # 双向：清单 ↔ 附件
    for n in sorted(set(sums) - set(payload)):
        print("  \033[31m✗\033[0m 清单里有、附件里没有：%s（改名前后算的哈希？）" % n)
        bad += 1
    for n in sorted(set(payload) - set(sums)):
        print("  \033[31m✗\033[0m 附件里有、清单里没有：%s" % n)
        bad += 1
    same = [n for n in payload if n in sums]
    diffs = 0
    for n in same:
        d = (assets[n].get("digest") or "").replace("sha256:", "")
        if not d:
            continue
        if d != sums[n]:
            print("  \033[31m✗\033[0m %s 的 sha256 对不上：清单 %s… / 附件 %s…"
                  % (n, sums[n][:12], d[:12]))
            diffs += 1
    bad += diffs
    print("  %s 哈希：%d 个逐条对过（对不上的 %d 个）"
          % ("\033[32m✓\033[0m" if not diffs else "\033[31m✗\033[0m", len(same), diffs))

# ---------- 三、结构（只取头尾几 KB） ----------
for n in payload:
    a = assets[n]
    sz, url = a["size"], a["browser_download_url"]
    ext = n.rsplit(".", 1)[-1].lower()
    try:
        if ext == "exe":
            head, _ = get(url, 0, 65535)
            ok = head[:2] == b"MZ"
            if ok:
                off = int.from_bytes(head[0x3C:0x40], "little")
                sig = head[off:off + 4]
                ok = sig == b"PE\0\0"
                extra_s = "e_lfanew=0x%x sig=%r" % (off, sig)
            else:
                extra_s = "头两字节 %r（不是 MZ）" % head[:2]
        elif ext == "dmg":
            tail, _ = get(url, sz - 512, sz - 1)
            ok = tail[:4] == b"koly"
            extra_s = "尾部 4 字节 %r（koly = UDIF 磁盘映像）" % tail[:4]
        elif ext == "zip":
            head, _ = get(url, 0, 3)
            ok = head[:2] == b"PK"
            extra_s = "头两字节 %r" % head[:2]
        else:
            ok, extra_s = True, "（不验结构）"
    except Exception as e:
        ok, extra_s = False, "取字节失败：%s" % e
    print("  %s %-40s %7.1f MB  %s"
          % ("\033[32m✓\033[0m" if ok else "\033[31m✗\033[0m", n, sz / 1e6, extra_s))
    if not ok:
        bad += 1

print("\n不合格项：%d" % bad)
sys.exit(1 if bad else 0)
