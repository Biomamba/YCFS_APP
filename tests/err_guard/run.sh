#!/usr/bin/env bash
# 起最小复现应用 + 开一个页面干等 25 秒 + 按日志下结论。
#
#   bash tests/err_guard/run.sh [端口] [render|observe|none] [守卫 0|1]
#
# ⚠️ 日志按"端口 + 时间戳"分开写。两次运行写同一个日志会交错成垃圾，
#    而交错出来的日志看上去**完全像是真的**（踩过，见 memory）。
# ⚠️ 别用 pkill -f 收尾：那个模式会连当前这个 shell 一起匹配上并杀掉。
set -euo pipefail
PORT="${1:-8971}"
BOMB="${2:-render}"
GUARD="${3:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%H%M%S)"
LOG="/tmp/dsapp_err_guard_${PORT}_${STAMP}.log"
TAG="port${PORT}_${BOMB}_guard${GUARD}"

echo "== 起应用：$TAG（日志 $LOG）=="
HBLOG="$LOG" BOMB="$BOMB" GUARD="$GUARD" \
  Rscript -e "shiny::runApp('$HERE', port=$PORT, host='127.0.0.1', launch.browser=FALSE)" \
  > "/tmp/dsapp_err_guard_${PORT}_${STAMP}.srv.log" 2>&1 &
PID=$!
sleep 5

python3 "$HERE/probe.py" "http://127.0.0.1:$PORT/" "$TAG" || true
kill "$PID" 2>/dev/null || true
sleep 1

echo
echo "== 判据（看日志）=="
# ⚠️ 判据**不能**用 "有没有 ★会话结束★"：测试最后 kill 掉进程时它也会触发，
#    两种情形长一样。真正分得开的是这两条：
#      · 心跳跳了几次 —— 炸弹在第 6 秒开火、探针总共等 25 秒，健康的话 ≥20
#      · 点击收到没有 —— 探针在 20 秒左右点那一下，会话死了就收不到
#    （onEnded 只当参考信息打出来，不下结论。）
HB=$(grep -c ' hb ' "$LOG" || true)
CLICKS=$(grep -c '收到点击' "$LOG" || true)
if [ "$HB" -ge 15 ] && [ "$CLICKS" -ge 1 ]; then
  echo "  ✓ 会话活着：心跳 $HB 跳、点击收到了（炸弹没把会话带走）"
else
  echo "  ✗ 会话死了：心跳只有 $HB 跳、点击 $CLICKS 次 —— 僵尸点在第 6 秒"
  echo "    （前端这时候就是「与服务器的连接断了」+ 整页点不动）"
fi
grep -q "★会话结束★" "$LOG" && echo "  · onEnded 触发过（测试收尾 kill 也会触发，仅供参考）"
echo
echo "== 日志（$LOG）=="
cat "$LOG"
