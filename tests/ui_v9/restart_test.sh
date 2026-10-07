#!/usr/bin/env bash
# 把仓库同步到一次性实例（8898）并重启它。
#
# ⚠️ 这份实例的 app 目录是一份**拷贝**，不是软链 —— 线上那份才是软链。拷贝是
#    有意的：测试会真的注册账号、真的改库、真的跑代码，任何一步出岔子都不该
#    碰到仓库本身（tests/ui_v9/*.py 顶部的 _guard 拦的是同一件事）。
#
# ⚠️ 杀进程必须走 `ss` 拿 pid 再 kill。**不要用 pkill -f** —— 那个模式串会
#    匹配到我自己这条 shell 的命令行，等于把自己打死（踩过）。
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${DSAPP_TEST_APP:-/tmp/dsapp_v8test/app}"
PORT="${DSAPP_TEST_PORT:-8898}"
LOG="${DSAPP_TEST_LOG:-/tmp/dsapp_v8test/app.log}"

if [ "$APP" = "$REPO" ]; then
  echo "拒绝运行：测试实例目录指到了仓库本身（$REPO）" >&2
  exit 1
fi
[ -d "$APP" ] || { echo "测试实例目录不存在：$APP" >&2; exit 1; }

# 1) 同步代码。只拷代码，**不碰** .Renviron（里面是这台实例自己的数据目录）
for d in R www tests; do
  [ -d "$REPO/$d" ] && { mkdir -p "$APP/$d"; cp -r "$REPO/$d/." "$APP/$d/"; }
done
# selftest.R 会读根目录下这些文件（部署清单 / 启动脚本的清单对比），少一个
# 就是 "cannot open the connection" —— 而且是在跑完一大半之后才报。
for f in app.R deploy.sh deploy_link.sh run_app.bat run_local.R selftest.R; do
  [ -f "$REPO/$f" ] && cp "$REPO/$f" "$APP/$f"
done

# 2) 停掉旧的
PID="$(ss -ltnp 2>/dev/null | sed -n "s/.*:$PORT .*pid=\([0-9]*\).*/\1/p" | head -1)"
if [ -n "${PID:-}" ]; then
  kill "$PID" 2>/dev/null
  for _ in $(seq 1 40); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
  done
  kill -9 "$PID" 2>/dev/null
fi

# 3) 起新的
cd "$APP" || exit 1
nohup R -q -e "shiny::runApp(port = $PORT, host = '127.0.0.1', launch.browser = FALSE)" \
  > "$LOG" 2>&1 &
echo "started pid=$! port=$PORT log=$LOG"

for _ in $(seq 1 60); do
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "$PORT 已就绪"; exit 0
  fi
  sleep 1
done
echo "启动超时，看 $LOG" >&2
tail -20 "$LOG" >&2
exit 1
