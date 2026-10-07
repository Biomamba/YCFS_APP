#!/usr/bin/env bash
# 起一个**带假工具链**的实例，然后跑 probe_cloudtool.py。
#
#   bash tests/ui_v158/run_cloudtool.sh [端口] [目录]
#
# 默认 8951 / /tmp/dsapp_v158i（和 _common.py 的默认值一套）。
#
# ⚠️ 为什么非要这一层壳、不能直接 python3 probe_cloudtool.py：
#    这台机器上**没有** foundry 的四份权重（几 GB，要外网），而云工具页
#    的「开始运行」那一按会**先跑体检、体检不过就拒绝提交任务**
#    （mod_cloudtool.R 的 observeEvent(input$run)）。所以没有权重时，
#    "点按钮 → 四步真跑完 → 收货"这条路一步都走不到。
#
#    这里造一套桩：三个程序的桩 + 四份**空文件**当权重 + 一个占位
#    evaluate_rf3.py。走的是**平台真正的执行器**（起任务、建工作区、
#    写 .dsapp_stdout、落任务行），只有那四个外部程序是假的。
#    换句话说：**这一页和平台的接线**是真的被走了一遍，
#    "RFD3 这一步真的算了"当然没有 —— 那要等权重到位。
#
# ⚠️ 三个环境变量是**继承**进去的，不是写进 .Renviron 的：
#    make_instance.sh 每次都会**重写** app/.Renviron（只留 DATA_ROOT 那几行），
#    往里加行会在下一次同步时被抹掉，症状是"昨天还能跑，今天预检就红了"。
#    导出给子进程则不会被覆盖 —— .Renviron 里没有这几个键，不会遮蔽。
set -euo pipefail

PORT="${1:-8951}"
DIR="${2:-/tmp/dsapp_v158i}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="$DIR/cloudstub"

# ---- 1. 桩工具链 -----------------------------------------------------------
# ⚠️ 判据和真东西一样是"bin/rfd3 可执行"，所以这里要 chmod 0755。
mkdir -p "$STUB/bin" "$STUB/ckpt" "$STUB/script"

cat > "$STUB/bin/rfd3" <<'EOS'
#!/bin/bash
set -u
OUT=""; CK=""; IN=""; NB=1; DB=1
for a in "$@"; do
  case "$a" in
    out_dir=*) OUT="${a#out_dir=}";;
    ckpt_path=*) CK="${a#ckpt_path=}";;
    inputs=*) IN="${a#inputs=}";;
    n_batches=*) NB="${a#n_batches=}";;
    diffusion_batch_size=*) DB="${a#diffusion_batch_size=}";;
  esac
done
[ -f "$CK" ] || { echo "checkpoint not found: $CK"; exit 9; }
[ -f "$IN" ] || { echo "inputs not found: $IN"; exit 9; }
JOB=$(head -2 "$IN" | tail -1 | tr -d " :")
grep -q "^    input: " "$IN" || { echo "yaml 里没有 input"; exit 9; }
mkdir -p "$OUT"
i=0
while [ "$i" -lt "$((NB * DB))" ]; do
  printf "data_x\n" > "$OUT/${JOB}_pd1s_${i}_model_0.cif"
  i=$((i+1))
done
echo "rfd3 桩：写了 $((NB * DB)) 个骨架"
EOS

cat > "$STUB/bin/mpnn" <<'EOS'
#!/bin/bash
set -u
OUT=""; CK=""; SP=""; DC=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out_directory) OUT="$2"; shift 2;;
    --structure_path) SP="$2"; shift 2;;
    --checkpoint_path) CK="$2"; shift 2;;
    --designed_chains) DC="$2"; shift 2;;
    *) shift;;
  esac
done
[ -f "$CK" ] || { echo "mpnn 权重不存在: $CK"; exit 9; }
[ -f "$SP" ] || { echo "输入结构不存在: $SP"; exit 9; }
[ "$DC" = "A" ] || { echo "designed_chains 不是 A: $DC"; exit 9; }
mkdir -p "$OUT"
B=$(basename "$SP" .cif)
printf ">%s, score=1.0\nMKTAYIAK\n" "$B" > "$OUT/$B.fa"
cp -f "$SP" "$OUT/$B.cif"
EOS

cat > "$STUB/bin/rf3" <<'EOS'
#!/bin/bash
set -u
OUT=""; IN=""; CK=""; SE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    out_dir=*) OUT="${1#out_dir=}";;
    inputs=*) IN="${1#inputs=}";;
    ckpt_path=*) CK="${1#ckpt_path=}";;
    skip_existing=True) SE=1;;
  esac
  shift
done
[ -f "$CK" ] || { echo "rf3 权重不存在: $CK"; exit 9; }
mkdir -p "$OUT"
n=0
for f in "$IN"/*.fa; do
  [ -e "$f" ] || continue
  B=$(basename "$f" .fa)
  if [ "$SE" = "1" ] && [ -f "$OUT/${B}_b0_d0_model.cif" ]; then
    echo "skip $B"; continue
  fi
  printf "data_pred\n" > "$OUT/${B}_b0_d0_model.cif"
  n=$((n+1))
done
echo "rf3 桩：预测了 $n 个"
EOS

# 汇总脚本的桩。⚠️ 第一个参数是**脚本路径**（argparse 把它当 argv[0]），
#    不是 flag —— 先 shift 掉，否则会把 ".../evaluate_rf3.py" 报成
#    unknown flag 退出 2，而那一路的失败症状指向"CSV 没写出来"。
cat > "$STUB/bin/python" <<'EOS'
#!/bin/bash
set -u
RF3=""; RFD3=""; PRE=""
SC="$1"; shift
[ -f "$SC" ] || { echo "评估脚本不在: $SC"; exit 9; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rf3-dir) RF3="$2"; shift 2;;
    --rfd3-dir) RFD3="$2"; shift 2;;
    --csv-prefix) PRE="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done
[ -d "$RF3" ] || { echo "rf3 目录不存在: $RF3"; exit 9; }
echo "rfd3_design_id,prediction_id,ipae,ipae_row_receptor_col_binder,ipae_row_binder_col_receptor,receptor_rmsd,binder_rmsd_receptor_aligned,iptm,receptor_plddt,binder_plddt,status,notes" > "$PRE.csv"
i=0
for f in "$RF3"/*_model.cif; do
  [ -e "$f" ] || continue
  B=$(basename "$f" _b0_d0_model.cif)
  i=$((i+1))
  case "$i" in
    1) echo "$B,${B}_b0_d0,7.5,8.1,6.9,1.2,2.0,0.72,88.0,85.0,ok,";;
    2) echo "$B,${B}_b0_d0,12.5,13.1,11.9,1.4,2.2,0.66,86.0,82.0,ok,";;
    *) echo "$B,${B}_b0_d0,,,,,,,55.0,40.0,error,chain selection failed";;
  esac
  [ "$i" -ge 3 ] && break
done >> "$PRE.csv"
echo "写了 $PRE.csv"
EOS

chmod 0755 "$STUB/bin/rfd3" "$STUB/bin/mpnn" "$STUB/bin/rf3" "$STUB/bin/python"
for f in rfd3_latest.ckpt proteinmpnn_v_48_020.pt solublempnn_v_48_020.pt \
         rf3_foundry_01_24_latest_remapped.ckpt; do
  : > "$STUB/ckpt/$f"
done
printf '# 占位。真的 evaluate_rf3.py 不跟着仓库走，要另外拿。\n' \
  > "$STUB/script/evaluate_rf3.py"

# ---- 2. 带着这套桩起实例 ---------------------------------------------------
export DSAPP_RFD3_ENV="$STUB"
export DSAPP_FOUNDRY_CKPT="$STUB/ckpt"
export DSAPP_CLOUD_SCRIPT_DIR="$STUB/script"
# GPU 放行：预检第 7 项读的是"这个账号有没有被放行"，一个刚注册的账号
# 走平台默认值（cfg$exec$gpu = DSAPP_EXEC_GPU，**默认 FALSE**）。
# 这台机器上真的有卡（tests/v158_gpu.R 验过），所以这里给它开上。
export DSAPP_EXEC_GPU=1

echo "== 桩工具链在 $STUB =="
bash "$REPO/tests/ui_v7/make_instance.sh" "$PORT" "$DIR"

exec python3 "$REPO/tests/ui_v158/probe_cloudtool.py"
