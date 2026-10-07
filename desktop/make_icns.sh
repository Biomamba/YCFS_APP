#!/usr/bin/env bash
# =============================================================================
# 从 desktop/app.png 生成 desktop/app.icns（mac 版单文件应用要的图标）
# =============================================================================
#
#   bash desktop/make_icns.sh
#
# ⚠️ **只能在 macOS 上跑**：用的是 `sips`（缩放）和 `iconutil`（打包 iconset），
#    两个都是系统自带的，装不了、也没有 Linux 版。所以这一步放在 CI 的
#    mac runner 里做，产物不进仓库（`.icns` 是二进制，且随图标变）。
#
# ---- 为什么不用 desktop/app.ico 转 ------------------------------------------
#
# 那份 .ico 里最大只有 256×256（见 desktop/README.md 第三节的生成代码）。
# iconutil 要的最高一档是 512x512@2x = **1024×1024**，拿 256 放大上去是糊的，
# 而且 macOS 的 Dock、启动台都会用那一档。所以源图直接用
#   data/logo/头像logo2026.09.jpg（1280×1280）→ desktop/app.png（1024×1024）。
# 那张 .png 是仓库里的文件（不是 build 产物），因为它本身就是源材料。
#
# ---- iconset 的文件名是**规定死的**，一个都不能少 ----------------------------
#
#   icon_16x16.png  icon_16x16@2x.png(32)   icon_32x32.png  icon_32x32@2x.png(64)
#   icon_128x128.png  icon_128x128@2x.png(256)  ...   icon_512x512@2x.png(1024)
#
# 少一个 iconutil 直接报 "not a valid iconset"，而且**不会告诉你少哪个**。
# 下面这张表是全部十档，改的时候别挑着改。
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/desktop/app.png"
OUT="$REPO/desktop/app.icns"

say() { printf '\033[36m==\033[0m %s\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "这是 $(uname -s)，不是 macOS。sips/iconutil 只有 mac 上有。"
command -v iconutil >/dev/null || die "找不到 iconutil（应该在 /usr/bin 里）。"
command -v sips     >/dev/null || die "找不到 sips（应该在 /usr/bin 里）。"
[ -f "$SRC" ] || die "没有 ${SRC}。它是源材料，应该跟着仓库走；缺了就从 data/logo/头像logo2026.09.jpg 重新生成一张 1024×1024 的。"

# sips 读出来的尺寸。⚠️ 必须是 1024，不是"够大就行" —— 见上面那段。
W="$(sips -g pixelWidth  "$SRC" | awk '/pixelWidth/{print $2}')"
H="$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')"
[ "$W" = "1024" ] && [ "$H" = "1024" ] || die "$SRC 是 ${W}×${H}，必须是 1024×1024。"

SET="$(mktemp -d)/app.iconset"
mkdir -p "$SET"
trap 'rm -rf "$(dirname "$SET")"' EXIT

say "缩放十档 → $SET"
while read -r px name; do
  sips -z "$px" "$px" "$SRC" --out "$SET/$name" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

# 自检：十档一个不少（iconutil 报错时不说是哪一档，前置检查比事后猜便宜）
n=0
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png \
         icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
  [ -s "$SET/$f" ] || die "iconset 里缺 $f —— sips 静默失败了？"
  n=$((n + 1))
done
say "十档齐了（$n/10）"

iconutil -c icns "$SET" -o "$OUT" || die "iconutil 失败（它不会说原因，先看上面十档齐不齐）"
[ -s "$OUT" ] || die "iconutil 说成功了，但 $OUT 是空的。"
say "写出 $OUT  $(wc -c <"$OUT" | tr -d ' ') 字节"
