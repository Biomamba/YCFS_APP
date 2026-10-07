#!/usr/bin/env bash
# 起**第二个**实例：把副本里的 DSAPP_ZIP_MAX 改成很小的值，好让「超过同步上限
# → 转后台」那条路在浏览器里能真的走一遍。
#
#   bash tests/ui_v1610/make_bg_instance.sh [端口] [目录]
#
# 默认 8981 / /tmp/dsapp_v1610b —— 和 probe_filezip.py 里的默认值是一套。
#
# ⚠️⚠️ 为什么要第二个实例：`DSAPP_ZIP_MAX` 是**应用启动时**读进去的常数
#   （`R/files.R:2612`，打包计划在同文件 `dsapp_zip_plan()` 里按它判 ok），
#   一个 R 进程里改不了它。而两条路都得在浏览器里验：
#     · 8980 = 原样 → 同步打包那条（**绝大多数用户**走的就是它）；
#     · 8981 = 常数改小 → 转后台那条。
#   只留后台那条的话，"正常下载"这条路一次都没被浏览器验过；反过来只留
#   8980 的话，转后台那条永远走不到（真实场景要 2 GB）。
#
# ⚠️⚠️ **不能再跑一遍 make_instance.sh** 来重启：那个脚本会 `cp -a` 覆盖
#   `R/`，把我们刚打上的补丁擦掉，而症状是"后台那条路测不出来"——看着像
#   功能坏了。所以这里自己 kill + 按同样的命令行重启。
#
# ⚠️ 阈值取 **8 字节**：夹具（`seed_zip.R`）那些文件每个只有 8~9 字节，整层
#   加起来几十字节。这个数**不能**拍脑袋写大 —— 写 4096 的话夹具压根够不着，
#   实例 B 会安安静静地走同步那条路，而探针那边报的是「按钮一直没变
#   disabled」，指向的是 UI 而不是这个阈值。
#
#   ⚠️⚠️ 2026-10-07 从 32 降到 8：32 对**整层**（74 B）够用，但 D 段是在
#   「文件」页里只勾那两个已发布的文件（9 + 9 = 18 B）—— 18 < 32，它安安静静
#   走了**同步**那条路，而探针报的是「点下去按钮没变 disabled」。
#   8 让两条路（整层 74 B / 勾选 18 B）都真的超限。
#   改这个数**必须同时**想一遍：探针里还有哪条断言是踩着这个阈值成立的
#   （本仓账：改常数要连断言里的字面量一起清）。
set -euo pipefail

PORT="${1:-8981}"
DIR="${2:-/tmp/dsapp_v1610b}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$DIR/app"
SMALL="${DSAPP_TEST_ZIP_SMALL:-8}"

# ---- 1) 先让既有那个脚本把副本拷好、.Renviron 写好、实例起起来 -------------
# 复用它是**故意**的：`.Renviron`（数据目录、conda/python 路径）那几行是它
# 维护的，这里再抄一份就会有两处会漂移的地方。
bash "$REPO/tests/ui_v7/make_instance.sh" "$PORT" "$DIR"

# ---- 2) 打补丁 -------------------------------------------------------------
F="$APP/R/files.R"
[ -f "$F" ] || { echo "❌ 副本里没有 R/files.R：$F"; exit 1; }
BEFORE="$(grep -c '^DSAPP_ZIP_MAX <- ' "$F" || true)"
# ⚠️ 必须**恰好一行**：这个脚本是按行首匹配替换的，两行的话（比如哪天又多出
#    一个同名赋值）只会改掉第一行，而"改了一半"从外面完全看不出来。
[ "$BEFORE" = "1" ] || {
  echo "❌ $F 里以 'DSAPP_ZIP_MAX <- ' 开头的行有 $BEFORE 条（要恰好 1 条）"
  echo "   （说明上游把它挪走/改名了 —— 先看 R/files.R:2612，别硬改）"
  exit 1
}
# ⚠️ 只认行首：`dsapp_zip_plan <- function(..., max_bytes = DSAPP_ZIP_MAX)` 那几行
#    也含这个串，不加锚点会把函数签名一起改掉。
sed -i "s|^DSAPP_ZIP_MAX <- .*\$|DSAPP_ZIP_MAX <- $SMALL|" "$F"
# ⚠️ 打完**必须回读**：sed 没匹配上时退出码是 0（它不报错），补丁静默落空，
#    后面每一条都只是"看起来不对"。本仓为这类事记过账。
GOT="$(grep '^DSAPP_ZIP_MAX <- ' "$F")"
[ "$GOT" = "DSAPP_ZIP_MAX <- $SMALL" ] || { echo "❌ 补丁没落上，现在是：【$GOT】"; exit 1; }
# ⚠️ 顺带确认没把后台那道上限碰坏：它比这个小值**大**才是对的（0.9 MB 的包
#    在实例 A 上能同步打、在实例 B 上要转后台，靠的就是这两个数一大一小）。
BG="$(grep '^DSAPP_ZIP_BG_MAX <- ' "$F" || true)"
echo "== 补丁落上：$GOT（后台顶仍是【${BG:-没找到}】）=="

# ---- 3) 停掉刚起的那个、按同样的命令行重启 --------------------------------
# ⚠️ 不要用 pkill -f：那个模式会把**当前这个 shell** 一起匹配上并杀掉
#    （本仓有账）。拿到 pid 再 kill 是唯一安全的做法。
if command -v ss >/dev/null 2>&1; then
  OLD="$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' || true)"
  [ -n "${OLD:-}" ] && { echo "== 停掉打补丁之前起的那个 pid=$OLD =="; kill "$OLD" || true; }
  # 等端口真的空出来 —— 不等的话新进程会 bind 失败，而日志里那句
  # 「cannot open port」会被后面的启动成功信息盖过去。
  for _ in $(seq 20); do
    ss -ltn 2>/dev/null | grep -q ":$PORT " || break
    sleep 0.5
  done
fi

echo "== 按补丁后的代码重启 http://127.0.0.1:$PORT/ =="
cd "$APP"
# ⚠️ 这两条和 make_instance.sh 里那两行**必须一致**（R_HOME 不给的话是
#    "Fatal error: R home directory is not defined"，看着像 R 坏了；
#    cwd 必须是 $APP，否则 app.R 里那些相对路径全会指错地方）。
R_HOME="${R_HOME:-/usr/lib/R}" nohup /usr/lib/R/bin/exec/R -q \
  -e "shiny::runApp(port = $PORT, host = \"127.0.0.1\", launch.browser = FALSE)" \
  > "$DIR/app.log" 2>&1 &
NEWPID=$!

for _ in $(seq 30); do
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$PORT " && break
done
ss -ltn 2>/dev/null | grep -q ":$PORT " || {
  echo "== 起不来，日志尾部 =="; tail -20 "$DIR/app.log"; exit 1
}

# ---- 4) 报出判据 -----------------------------------------------------------
# 和「R 代码只在 worker 换代时生效」那条判据同源：进程的启动时刻必须**比
# 补丁文件新**，否则跑的还是旧代码，而症状是"改了没反应"。
echo "== 起来了 =="
ls -l --time-style=+%F\ %T "$F" | awk '{print "  补丁文件 mtime：", $6, $7}'
ps -eo pid,lstart,cmd | grep -E "^ *$NEWPID " | grep -v grep || true
echo "  常数：$(grep '^DSAPP_ZIP_MAX <- ' "$F")"
