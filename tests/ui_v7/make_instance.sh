#!/usr/bin/env bash
# 起一个**可丢弃的**实例，给 tests/ui_v7/ 那三个浏览器脚本用。
#
#   bash tests/ui_v7/make_instance.sh [端口] [目录]
#
# 默认端口 8898、目录 /tmp/dsapp_v7test —— 和脚本里的默认值是一套，
# 所以起完直接跑脚本就行，不用设任何环境变量。
#
# ⚠️ 为什么要单独拷一份代码、而不是对着仓库跑：
#    这三个脚本会**真的注册账号、插任务、删任务**。对着仓库跑 = 对着线上
#    那份代码跑，而它的数据目录是线上那份。拷贝 + 独立 DSAPP_DATA_ROOT 之后，
#    它们折腾的是 /tmp 下的另一个库，线上一个字节都不动。
#
# ⚠️ R/.Renviron 会**覆盖**继承来的环境变量。副本必须带自己的 .Renviron，
#    否则你以为指到了 /tmp，实际读的还是外面传进来的那份（或者默认值）。
set -euo pipefail

PORT="${1:-8898}"
DIR="${2:-/tmp/dsapp_v7test}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$DIR/app"

if [ -f "$APP/app.R" ]; then
  echo "== 复用已有的副本：$APP（只同步代码，数据不动）=="
fi
mkdir -p "$APP" "$DIR/dl"
cp -a "$REPO/R" "$REPO/www" "$REPO/app.R" "$REPO/selftest.R" "$APP/"
# ⚠️ skills_builtin/ 是**目录**，不在 app.R 的 source 列表里，很容易漏。
#    漏了不会报错：dsapp_skills_builtin_md() 读不到就跳过那一篇（故意的），
#    表现是"内置技能少了十来条"，而 tests/ui_v13/skills.py 会因此红一片。
[ -d "$REPO/skills_builtin" ] && cp -a "$REPO/skills_builtin" "$APP/"
[ -d "$REPO/tests" ] && { mkdir -p "$APP/tests"; cp -a "$REPO/tests/." "$APP/tests/"; }

# ⚠️ 每次同步都要把上一次跑出来的实例停掉 —— 否则它跑的还是旧代码，
#    症状是"改了代码测试还是老样子"，很容易被当成"改动没生效"。
if command -v ss >/dev/null 2>&1; then
  OLD="$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' || true)"
  # ⚠️ 不要用 pkill -f：那个模式会连**当前这个 shell** 一起匹配上并杀掉。
  #    拿到 pid 再 kill 是唯一安全的做法。
  [ -n "${OLD:-}" ] && { echo "== 停掉旧实例 pid=$OLD =="; kill "$OLD" || true; sleep 2; }
fi

cat > "$APP/.Renviron" <<EOF
DSAPP_DATA_ROOT=$DIR/data
EOF
# 这两个只在真正建环境时才用得上，缺了应用照样起得来。本机路径，按需改。
[ -x /home/biomamba/miniconda3/bin/conda ] && \
  echo "DSAPP_CONDA_BIN=/home/biomamba/miniconda3/bin/conda" >> "$APP/.Renviron"
[ -x /home/biomamba/miniforge3/dsapp/bin/python ] && \
  echo "DSAPP_PYTHON=/home/biomamba/miniforge3/dsapp/bin/python" >> "$APP/.Renviron"

echo "== 起实例 http://127.0.0.1:$PORT/ （数据在 $DIR/data）=="
cd "$APP"
# ⚠️ 直接敲 /usr/lib/R/bin/exec/R 的话要自己给 R_HOME，否则
#    "Fatal error: R home directory is not defined"，看着像 R 坏了。
R_HOME="${R_HOME:-/usr/lib/R}" nohup /usr/lib/R/bin/exec/R -q \
  -e "shiny::runApp(port = $PORT, host = \"127.0.0.1\", launch.browser = FALSE)" \
  > "$DIR/app.log" 2>&1 &

for _ in $(seq 30); do
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$PORT " && { echo "== 起来了 =="; exit 0; }
done
echo "== 起不来，日志尾部 =="; tail -20 "$DIR/app.log"; exit 1
