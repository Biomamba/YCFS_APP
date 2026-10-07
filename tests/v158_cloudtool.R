#!/usr/bin/env Rscript
# =============================================================================
# V15.8 item 2 端到端：「云工具」那一页拼出来的命令，**真的跑得通吗**
# =============================================================================
#     Rscript tests/v158_cloudtool.R            # 在应用目录下跑
#
# ── 要回答的问题 ─────────────────────────────────────────────────────────────
#
# 用户原话：「加一个云工具模块，第一个功能就是能够给这套流程的自动化分析提供
#           一个GUI，要求有流程的原理、功能介绍，让用户选好参数后可以直接运行、
#           收获结果并预览，并且能给用户提供进一步的建议」。
#
# 这一页的价值全在"拼出来的命令是对的"这一件事上。参数拼错、yaml 少一行、
# 命令少一个 flag —— 这些**都不会让界面报错**，只会让几十分钟后的任务失败，
# 而那时用户看到的是 python 的堆栈。所以这份测试必须**真把脚本跑起来**，
# 不能只对着源码 grep（本仓栽过两次：selftest-green-is-not-coverage）。
#
# ── 四段，一段比一段靠外 ────────────────────────────────────────────────────
#
#   A 判据   —— contig/hotspot/slug 这些纯函数的行为（对着教学原文的数字）
#   B 命令   —— 生成的脚本里**逐字**出现教学原文那些 flag；没出现编造的 flag
#   C **真跑** —— 用桩程序把四步跑一遍，看产物、yaml、收货、建议
#   D 边界   —— 一步什么都没产出时必须**大声失败**；空指标不许当 0 分
#
# ★★ C 是整份测试里唯一有分量的一段。A/B 全绿而 C 红，说明"字符串拼得对、
#    拼出来的东西是坏的" —— 而那正是这一页最可能出的错。
#
# ── 关于桩程序（为什么不是真跑 RFD3）────────────────────────────────────────
#
# 真跑需要 GPU + 4 份权重（几 GB，且这台机器上**没有**：预检会如实报"缺 4 份"）。
# 桩程序只做真程序**在这个流程里被依赖的那部分行为**：按 out_dir/inputs 写出
# 教学原文那种命名的产物、尊重 skip_existing、把权重路径读一遍（路径不对就
# 失败，和我们传参传错了的症状一致）。这样 C 段验的是**我们这一侧**的
# 正确性 —— 那也正是这一页要负责的全部。
#
# ⚠️⚠️ 数据根目录**必须**先指到一个临时目录再 source（仓库根的 .Renviron 把
#    DSAPP_DATA_ROOT 指着**生产库**）。本仓为此栽过一次。
# ⚠️ 一条出网请求都没有。这一份只在本机跑 bash、读写临时目录。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."
setwd(app_dir)

NOK <- 0L; nfail <- 0L
say <- function(...) cat(sprintf(...), "\n", file = stderr())
chk <- function(name, cond, extra = "") {
  if (isTRUE(cond)) { NOK <<- NOK + 1L; say("  \033[32m✓\033[0m %s", name) }
  else {
    nfail <<- nfail + 1L
    say("  \033[31m✗ %s\033[0m   %s", name, extra)
  }
}
sect <- function(x) say("\n\033[36m== %s ==\033[0m", x)

# ---- 先把数据根目录挪走，再 source -----------------------------------------
tmp <- tempfile("dsapp_cloud_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

# ⚠️ source **全部** R/*.R（和 app.R 加载的一样），不是只挑用得到的那几个：
#    `dsapp_config()` 底下还挂着 platform.R 的 dsapp_default_data_root() 等一串，
#    挑着 source 的话第一版就是这样栽的 —— 报错是
#    「could not find function "dsapp_default_data_root"」，而且是在**跑到预检
#    那一段**才炸（前面 A/B/C 三段全绿），看着像"预检写坏了"。
for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

P <- dsapp_cloud_defaults()
P$input <- file.path(tmp, "PDL1.pdb")
writeLines(c("HEADER    TEST", "ATOM      1  N   ALA A  18      0.000   0.000   0.000"),
           P$input)

# =============================================================================
sect("A 判据：纯函数的行为")
# =============================================================================

# ---- contig × length -------------------------------------------------------
r <- dsapp_cloud_contig_check(P$contig, P$length)
chk("默认那套（PD-L1）应当是**相容**的", r$ok, r$detail)
chk("  而且固定段/生成段分得清：binder 70-90、固定 A18-132 = 115",
    identical(r$binder_lo, 70L) && identical(r$binder_hi, 90L) &&
      identical(r$fixed_hi, 115L),
    sprintf("binder=%s-%s fixed=%s-%s", r$binder_lo, r$binder_hi,
            r$fixed_lo, r$fixed_hi))

# ★★ 这一条是**对着教学原文的算术**验的，不是对着我自己的实现验的：
#    教学 4.2 节那个例子说固定部分 569、binder 120-250，总长应当是 689-819。
#    这里最容易错的一步是"binder 段该按个数算还是按区间算" —— 按个数算会
#    得到 700 一个点，判据就变成假的（我第一版就是这么写的）。
r2 <- dsapp_cloud_contig_check(
  "120-250,/0,B20-318,/0,C30-54,C102-127,C138-356", "680-820")
chk("★★ 教学 4.2 那个例子算出 689-819（和原文一致）",
    grepl("689-819", r2$detail, fixed = TRUE) && r2$ok, r2$detail)

chk("  同一个 contig 配 900-950（区间不相交）要判不通过",
    !dsapp_cloud_contig_check(
      "120-250,/0,B20-318,/0,C30-54,C102-127,C138-356", "900-950")$ok)
chk("  起止写反要报出来（不是当成 90-70 一样接受）",
    !dsapp_cloud_contig_check("90-70,/0,A1-5", "180-210")$ok)
chk("  contig 里有一段读不出来要报错",
    !dsapp_cloud_contig_check("70-90,ABC", "180-210")$ok)
chk("  空的 length 要报错（不是静默通过）",
    !dsapp_cloud_contig_check("70-90,/0,A1-5", "")$ok)

# ★ 链名那一类里放数字会让 `70-90` 变成"链 7、残基 0"（我第一版就是这样），
#   于是 binder 段被当固定段 —— 不报错，只是判据变成假的。
rp <- dsapp_cloud_parse_range("180-210")
chk("★ range 解析：`180-210` / `180` / `180到210`",
    identical(rp, c(180L, 210L)) &&
      identical(dsapp_cloud_parse_range("180"), c(180L, 180L)) &&
      identical(dsapp_cloud_parse_range("180到210"), c(180L, 210L)))

# ---- hotspot ---------------------------------------------------------------
h <- dsapp_cloud_parse_hotspots("A39: CE1,OH")
chk("★ 热点 `A39: CE1,OH` → 链 A、残基 39、原子 CE1,OH（不是链 A3、残基 9）",
    !is.null(h) && nrow(h) == 1 && h$chain == "A" && h$res == 39L &&
      h$atoms == "CE1,OH",
    if (is.null(h)) "解析失败" else paste(h$chain, h$res, h$atoms))
h2 <- dsapp_cloud_parse_hotspots("A39: CE1,OH; B128: NZ")
chk("  分号隔开两个热点 → 两行（逗号是**原子名之间**的分隔）",
    !is.null(h2) && nrow(h2) == 2 && h2$chain[[2]] == "B")
chk("★ 空串 = 没写热点（0 行，合法），**不是**解析失败",
    identical(nrow(dsapp_cloud_parse_hotspots("")), 0L))
chk("★ 写坏了（`A39 CE1`、`A39`）= 解析失败（NULL），和上面那条不能混",
    is.null(dsapp_cloud_parse_hotspots("A39 CE1")) &&
      is.null(dsapp_cloud_parse_hotspots("A39")))

# ---- slug / num ------------------------------------------------------------
chk("★ 任务名里的 `/`、空格、`..` 不会跑进路径",
    identical(dsapp_cloud_slug("../../etc/passwd"), "etc_passwd") &&
      identical(dsapp_cloud_slug("pdl1 binder"), "pdl1_binder"),
    dsapp_cloud_slug("../../etc/passwd"))
chk("★ 十万不能写成 1e+05（hydra 不认科学计数法）",
    identical(dsapp_cloud_num(1e5), "100000") &&
      identical(dsapp_cloud_num(0.2), "0.2"),
    dsapp_cloud_num(1e5))

# =============================================================================
sect("B 命令：生成的脚本里有教学原文那些 flag，没有编造的 flag")
# =============================================================================

# 桩目录：bin/ 里放四个假程序，权重和评估脚本也给假的（这一节只看文本）
env_dir <- file.path(tmp, "env"); dir.create(file.path(env_dir, "bin"), recursive = TRUE)
ck_dir  <- file.path(tmp, "ck"); dir.create(ck_dir)
for (f in unlist(DSAPP_CLOUD_CKPT, use.names = FALSE)) {
  writeLines("stub", file.path(ck_dir, f))
}
eval_py <- file.path(tmp, "evaluate_rf3.py"); writeLines("# stub", eval_py)

root <- file.path(tmp, "run1")
S <- lapply(c("rfd3", "mpnn", "rf3", "eval"), function(s)
  paste(dsapp_cloud_step_script(s, P, root, env_dir, ck_dir, eval_py),
        collapse = "\n"))
names(S) <- c("rfd3", "mpnn", "rf3", "eval")

# 逐字对着教学原文那四条命令的 flag 清单（4.2 / 5.3 / 6.1 / 7 节）
want <- list(
  rfd3 = c("rfd3 design", "out_dir=", "ckpt_path=", "inputs=",
           "inference_sampler.step_scale=3", "inference_sampler.gamma_0=0.2",
           "n_batches=25", "diffusion_batch_size=2"),
  mpnn = c("mpnn --model_type \"protein_mpnn\"", "--structure_path",
           "--out_directory", "--batch_size 1", "--number_of_batches 1",
           "--omit '[\"CYS\"]'", "--is_legacy_weights \"True\"",
           "--designed_chains \"A\"", "--checkpoint_path"),
  rf3  = c("rf3 fold", "inputs=", "ckpt_path=", "out_dir=",
           "diffusion_batch_size=1", "num_steps=50", "n_recycles=10",
           "early_stopping_plddt_threshold=0.5", "skip_existing=True",
           "annotate_b_factor_with_plddt=True"),
  eval = c("evaluate_rf3.py", "--rf3-dir", "--rfd3-dir", "--csv-prefix")
)
for (k in names(want)) {
  miss <- want[[k]][!vapply(want[[k]], function(w) grepl(w, S[[k]], fixed = TRUE),
                            logical(1))]
  chk(sprintf("★ %s 那一步的 flag 齐全（教学原文逐字）", k),
      length(miss) == 0, paste("缺:", paste(miss, collapse = ", ")))
}

# ★★ 编造的 flag 比漏掉的更坏：漏掉会当场报错，编造的会**跑到那一步才炸**
#    （前三步的机时已经花掉了）。所以这里把命令行上所有 `--xxx` 抠出来，
#    和教学原文那三个**逐个比**，不是"数得对就行"。
eval_cmd <- grep("^python ", strsplit(S$eval, "\n")[[1]], value = TRUE)
# ⚠️ 字符类里要带**数字**：`--rfd3-dir` 里有 3，写成 `[A-Za-z-]*` 会把它截成
#    `--rfd`（第一版就是这么红的，而红的样子是"多出来两个没见过的 flag"）。
got_flags <- sort(unique(unlist(regmatches(
  eval_cmd, gregexpr("--[A-Za-z][A-Za-z0-9-]*", eval_cmd)))))
chk("★★ eval 那一步**只**传教学原文里出现过的那三个参数（多传一个 argparse 直接退出）",
    # ⚠️ 排序是 sort() 的 ASCII 序：`--rf3-dir` 里那个 3 排在 `--rfd3-dir`
    #    的 d 前面，所以这三个的**先后**看着别扭 —— 第一版是按人眼习惯写的
    #    期望值，于是"代码对、断言错"地红了一次。
    identical(got_flags, c("--csv-prefix", "--rf3-dir", "--rfd3-dir")),
    paste("实际:", paste(got_flags, collapse = " ")))

lay1 <- dsapp_cloud_layout(root, P)
chk("★ 两套 MPNN 各写各的目录（教学 5.3：同名文件不能当成同一条序列）",
    grepl(file.path(lay1$mpnn, "1"), S$mpnn, fixed = TRUE) &&
      grepl(file.path(lay1$mpnn, "2"), S$mpnn, fixed = TRUE))
chk("★ MPNN 读的是 RFD3 的 .cif 输出（教学 5.1：变量名叫 PDB，实际读 cif）",
    grepl(lay1$rfd3, S$mpnn, fixed = TRUE) &&
      grepl("*.cif", S$mpnn, fixed = TRUE))
chk("★ 每一步都数产物再往下走（退出码 0 但没产物是这套程序的常见形态）",
    all(vapply(S, function(x) grepl("die ", x, fixed = TRUE), logical(1))))

# 权重名必须和教学原文一模一样 —— 换一个字就是"没装好"，要当场说，
# 而不是让 rfd3 在几分钟后报"找不到 checkpoint"。
chk("★ 四份权重的名字逐字来自教学原文",
    all(vapply(unlist(DSAPP_CLOUD_CKPT, use.names = FALSE), function(f)
      grepl(f, paste(unlist(S), collapse = "\n"), fixed = TRUE), logical(1))))

# CUDA_VISIBLE_DEVICES 不许多手（多卡机上写死 0 = 替用户挑一张卡）
chk("★ 脚本不自己设 CUDA_VISIBLE_DEVICES（平台按账号注入；写死会挑错卡）",
    !grepl("CUDA_VISIBLE_DEVICES=", paste(unlist(S), collapse = "\n"),
           fixed = TRUE))

# yaml：逐字对着教学 4.1 那份
y <- dsapp_cloud_yaml(P, input = "/x/PDL1.pdb")
chk("★ yaml 的第一行是任务名，缩进 4 格（omegaconf 对缩进敏感）",
    y[[2]] == "pdl1_binder:" && grepl("^    input: /x/PDL1.pdb$", y[[3]]),
    paste(y[1:3], collapse = " / "))
chk("★ 热点那一段缩进 8 格，写法 `A39: CE1,OH`",
    any(grepl("^    select_hotspots:$", y)) &&
      any(grepl("^        A39: CE1,OH$", y)), paste(y, collapse = " | "))
chk("★ yaml 里有 infer_ori_strategy: hotspots 和 is_non_loopy: true",
    any(grepl("^    infer_ori_strategy: hotspots$", y)) &&
      any(grepl("^    is_non_loopy: true$", y)))
chk("★ yaml 的 input 指向**运行目录里的那份拷贝**（原文件挪走也能续跑）",
    grepl(file.path(root, "rfd3", "inputs", "PDL1.pdb"),
          paste(S$rfd3, collapse = "\n"), fixed = TRUE))

# =============================================================================
sect("C 真跑：用桩程序把四步走一遍")
# =============================================================================

# ---- 桩程序 ----------------------------------------------------------------
# 只实现"这个流程依赖的那部分行为"。**故意**做成会读权重路径：传错权重就失败，
# 那正是我们这一侧最可能犯的错。
# ⚠️ 桩程序**不是**都装在 env_dir 里：D 段要拿一个"什么都不产出"的假 rfd3
#    去试"该红的时候红不红"，如果它写进 env_dir 就把真桩覆盖掉了，
#    后面几段会静默地跑在一个空环境上（本仓栽过：自检全绿 ≠ 功能被验过）。
#    所以目标目录是参数。
stub <- function(name, body, dir = file.path(env_dir, "bin")) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  p <- file.path(dir, name)
  writeLines(c("#!/bin/bash", "set -u", body), p)
  Sys.chmod(p, "0755")
  invisible(p)
}

stub("rfd3", c(
  'OUT=""; CK=""; IN=""; NB=1; DB=1',
  'for a in "$@"; do',
  '  case "$a" in',
  '    out_dir=*) OUT="${a#out_dir=}";;',
  '    ckpt_path=*) CK="${a#ckpt_path=}";;',
  '    inputs=*) IN="${a#inputs=}";;',
  '    n_batches=*) NB="${a#n_batches=}";;',
  '    diffusion_batch_size=*) DB="${a#diffusion_batch_size=}";;',
  '  esac',
  'done',
  '[ -f "$CK" ] || { echo "checkpoint not found: $CK"; exit 9; }',
  '[ -f "$IN" ] || { echo "inputs not found: $IN"; exit 9; }',
  # YAML 得真的能读：任务名那行 + input 那行必须在（我们拼错了就当场红）
  'JOB=$(head -2 "$IN" | tail -1 | tr -d " :")',
  'grep -q "^    input: " "$IN" || { echo "yaml 里没有 input"; exit 9; }',
  'mkdir -p "$OUT"',
  'i=0',
  'while [ "$i" -lt "$((NB * DB))" ]; do',
  '  printf "data_x\n" > "$OUT/${JOB}_pd1s_${i}_model_0.cif"',
  '  i=$((i+1))',
  'done',
  # 教学 4.1.2：输出也可能是 .cif.gz，脚本里那一步 gunzip 得管用
  'printf "gzipped\n" | gzip > "$OUT/${JOB}_pd1s_999_model_0.cif.gz"',
  'echo "rfd3 stub 写了 $((NB * DB)) 个结构"'
))

stub("mpnn", c(
  'OUT=""; CK=""; SP=""; OMIT=""; DC=""',
  'while [ "$#" -gt 0 ]; do',
  '  case "$1" in',
  '    --out_directory) OUT="$2"; shift 2;;',
  '    --structure_path) SP="$2"; shift 2;;',
  '    --checkpoint_path) CK="$2"; shift 2;;',
  '    --omit) OMIT="$2"; shift 2;;',
  '    --designed_chains) DC="$2"; shift 2;;',
  '    --number_of_batches) NB="$2"; shift 2;;',
  '    *) shift;;',
  '  esac',
  'done',
  '[ -f "$CK" ] || { echo "mpnn 权重不存在: $CK"; exit 9; }',
  '[ -f "$SP" ] || { echo "输入结构不存在: $SP"; exit 9; }',
  # 只设计 A 链这件事是教学里明说的；桩程序把它当断言：传错就红
  '[ "$DC" = "A" ] || { echo "designed_chains 不是 A: $DC"; exit 9; }',
  'mkdir -p "$OUT"',
  'B=$(basename "$SP" .cif)',
  'printf ">%s, score=1.0\nMKTAYIAK\n" "$B" > "$OUT/$B.fa"',
  'cp -f "$SP" "$OUT/$B.cif"'
))

stub("rf3", c(
  'OUT=""; IN=""; CK=""; SE=0',
  'while [ "$#" -gt 0 ]; do',
  '  case "$1" in',
  '    out_dir=*) OUT="${1#out_dir=}";;',
  '    inputs=*) IN="${1#inputs=}";;',
  '    ckpt_path=*) CK="${1#ckpt_path=}";;',
  '    skip_existing=True) SE=1;;',
  '  esac',
  '  shift',
  'done',
  '[ -f "$CK" ] || { echo "rf3 权重不存在: $CK"; exit 9; }',
  'mkdir -p "$OUT"',
  'n=0',
  'for f in "$IN"/*.fa; do',
  '  [ -e "$f" ] || continue',
  '  B=$(basename "$f" .fa)',
  # ★ skip_existing 的语义：已经有输出的输入**不再算一遍**。这正是"被墙钟
  #   打断之后重跑就是续跑"所依赖的那一条，所以桩程序必须照着实现，
  #   否则 C 段的续跑断言就是假的。
  '  if [ "$SE" = "1" ] && [ -f "$OUT/${B}_b0_d0_model.cif" ]; then',
  '    echo "skip $B"; continue',
  '  fi',
  '  printf "data_pred\n" > "$OUT/${B}_b0_d0_model.cif"',
  '  n=$((n+1))',
  'done',
  'echo "rf3 stub 预测了 $n 个"'
))

# 桩程序版的评估脚本：**故意**照着教学 7 节那张表出列，而且故意留一行
# status=error、指标空白 —— 用来看"空值会不会被当成 0 分"。
stub("python", c(
  'RF3=""; RFD3=""; PRE=""',
  # 第一个参数是**脚本路径**（`python script/evaluate_rf3.py --rf3-dir …`），
  # 它不是 flag —— argparse 把它当 sys.argv[0]。第一版没先 shift 掉它，
  # 于是桩程序报 "unknown flag: .../evaluate_rf3.py" 退出 2，
  # 而那个非 0 被脚本的 `|| say ...` 吃着，一路走到"CSV 没写出来"才炸。
  'SC="$1"; shift',
  '[ -f "$SC" ] || { echo "评估脚本不在: $SC"; exit 9; }',
  'while [ "$#" -gt 0 ]; do',
  '  case "$1" in',
  '    --rf3-dir) RF3="$2"; shift 2;;',
  '    --rfd3-dir) RFD3="$2"; shift 2;;',
  '    --csv-prefix) PRE="$2"; shift 2;;',
  '    *) echo "unknown flag: $1" >&2; exit 2;;',
  '  esac',
  'done',
  '[ -d "$RF3" ] || { echo "rf3 目录不存在: $RF3"; exit 9; }',
  'echo "rfd3_design_id,prediction_id,ipae,ipae_row_receptor_col_binder,ipae_row_binder_col_receptor,receptor_rmsd,binder_rmsd_receptor_aligned,iptm,receptor_plddt,binder_plddt,status,notes" > "$PRE.csv"',
  'i=0',
  'for f in "$RF3"/*_model.cif; do',
  '  [ -e "$f" ] || continue',
  '  B=$(basename "$f" _b0_d0_model.cif)',
  '  i=$((i+1))',
  # 第一条给"全过"的数，第二条给"ipae 差一点"的数，第三条**空指标**。
  '  case "$i" in',
  '    1) echo "$B,${B}_b0_d0,7.5,8.1,6.9,1.2,2.0,0.72,88.0,85.0,ok,";;',
  '    2) echo "$B,${B}_b0_d0,12.5,13.1,11.9,1.4,2.2,0.66,86.0,82.0,ok,";;',
  '    *) echo "$B,${B}_b0_d0,,,,,,,55.0,40.0,error,chain selection failed";;',
  '  esac',
  # 只写前三条。真脚本会对**每条**输入出一行，这里留三条是因为要的形状
  # 就是这三种（全过 / 差一点 / 读不出来），多写只是把同一个断言重复 51 遍。
  '  [ "$i" -ge 3 ] && break',
  'done >> "$PRE.csv"',
  'echo "写了 $PRE.csv"'
))

# ---- 真跑四步（用 bash 起，和平台执行器同一个口吻）-------------------------
run_step <- function(step, root) {
  sc <- file.path(root, paste0(step, ".sh"))
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  writeLines(dsapp_cloud_step_script(step, P, root, env_dir, ck_dir, eval_py), sc)
  out <- suppressWarnings(system2("bash", sc, stdout = TRUE, stderr = TRUE))
  list(code = attr(out, "status") %||% 0L, out = paste(out, collapse = "\n"))
}

root2 <- file.path(tmp, "run2")
res <- list()
for (st in c("rfd3", "mpnn", "rf3", "eval")) {
  res[[st]] <- run_step(st, root2)
  chk(sprintf("★ 第 %d 步真跑通过（bash 退出码 0）",
              match(st, c("rfd3", "mpnn", "rf3", "eval"))),
      identical(as.integer(res[[st]]$code), 0L),
      substr(res[[st]]$out, 1, 400))
}

lay <- dsapp_cloud_layout(root2, P)
n_cif <- length(list.files(lay$rfd3, pattern = "\\.cif$"))
chk("★ 第 1 步的产物落在 rfd3/outputs/1 下（25×2 = 50 个，外加那个 .gz 解出来的 1 个）",
    n_cif == 51L, sprintf("有 %d 个 cif", n_cif))
chk("★ .cif.gz 被 gunzip 了（教学 4.1.2 那一步；不解压后面 MPNN 读不到）",
    !length(list.files(lay$rfd3, pattern = "\\.gz$")) &&
      file.exists(file.path(lay$rfd3, "pdl1_binder_pd1s_999_model_0.cif")))
chk("★ 写进磁盘的 yaml 和 dsapp_cloud_yaml() 逐字一致（heredoc 没走样）",
    identical(readLines(lay$yaml),
              dsapp_cloud_yaml(P, input = file.path(lay$inputs, "PDL1.pdb"))))
chk("★ 两套 MPNN 的序列落在各自的目录（mpnn/1 与 mpnn/2）",
    length(list.files(file.path(root2, "mpnn", "1"), pattern = "\\.fa$")) == 51L &&
      length(list.files(file.path(root2, "mpnn", "2"), pattern = "\\.fa$")) == 51L)
chk("★ RF3 的预测结构写在 rf3/1 与 rf3/2（教学 6 节的目录形状）",
    length(list.files(file.path(root2, "rf3", "1"),
                      pattern = "_model\\.cif$")) == 51L &&
      length(list.files(file.path(root2, "rf3", "2"),
                        pattern = "_model\\.cif$")) == 51L)

# ---- 收货 ------------------------------------------------------------------
h <- dsapp_cloud_harvest(root2, P)
chk("★ 收货：两个 CSV 都读到、合起来 6 行、来源标出来",
    isTRUE(h$ok) && nrow(h$df) == 6L &&
      identical(sort(unique(h$df$source)), c("ProteinMPNN", "SolubleMPNN")),
    if (is.null(h$df)) h$msg else sprintf("%d 行 %s", nrow(h$df),
                                          paste(unique(h$df$source), collapse = ",")))
chk("   status 三态各 2 条（ok / error）",
    h$n_ok == 4L && h$n_error == 2L,
    sprintf("ok=%d partial=%d error=%d", h$n_ok, h$n_partial, h$n_error))

# ★★ 空指标那一行**不能**当 0 分：教学 7 节明写"空白值不能按 0 处理"。
#    当成 0 的话它 ipae=0 会排第一 —— 而它其实是**读取失败**的那一条。
ps <- dsapp_cloud_pass(h$df, P)
chk("★★ 空指标的行既不算通过、也不许排到第一（ipae 得是 NA，不是 0）",
    sum(ps) == 2L && is.na(dsapp_cloud_rank(h$df)$ipae[[1]]) == FALSE &&
      all(is.na(h$df$ipae[h$df$status == "error"])),
    sprintf("通过 %d 条；第一行 ipae=%s", sum(ps),
            dsapp_cloud_rank(h$df)$ipae[[1]]))
# ⚠️ 判据是"整列非递减"，不是"第一名比第二名小"：两套 MPNN 各出一条 7.5，
#    并列第一是**对的**，写成 `<` 会红（第一版就是这么写的）。
rk <- dsapp_cloud_rank(h$df)$ipae
nna <- sum(!is.na(rk))
chk("★ 排名按 ipae 升序（越低越好，教学 7 节的读法），算不出指标的行全排在最后",
    nna == 4L && !is.unsorted(rk[seq_len(nna)]) &&
      all(is.na(rk[-seq_len(nna)])),
    paste(rk, collapse = " "))

# ---- 建议 ------------------------------------------------------------------
ad <- dsapp_cloud_advise(h, P)
txt <- paste(ad$lines, collapse = "\n")
chk("★ 建议里有「这次一共 N 条 / 通过几条」的记账（教学 8 节要求每次记录）",
    grepl("一共 6 条设计记录", txt, fixed = TRUE) && ad$n_pass == 2L,
    substr(txt, 1, 200))
chk("★ 建议里点出了空指标那几条要去读 notes 列，且**不能当 0 分**",
    grepl("notes", txt, fixed = TRUE) && grepl("不能当 0 分", txt, fixed = TRUE))
chk("★★ 建议里明说那三条线只是观察线、不是已验证的阈值（教学原文的立场）",
    grepl("观察线", txt, fixed = TRUE) &&
      grepl("不是已经验证过的实验成功阈值", txt, fixed = TRUE))
chk("★★ 建议里带着教学 9 节那四条后续工作，且写了「结合 ≠ 阻断」那句提醒",
    grepl("界面检查与补充对接", txt) && grepl("分子动力学", txt) &&
      grepl("SPR", txt) && grepl("并不等于具有阻断作用", txt, fixed = TRUE))
chk("★ 建议里提醒了两套 MPNN 同名文件不是同一条序列（教学 8 节）",
    grepl("不是同一条序列", txt, fixed = TRUE))

# =============================================================================
sect("D 边界：该红的时候必须红")
# =============================================================================

# ---- 第 1 步什么都没产出 → 必须大声失败 ------------------------------------
# 这是这套程序最阴的一种失败：退出码 0、日志正常、目录是空的，
# 而脚本会带着空目录往下跑，最后报的是"后面某一步失败"。
empty_env <- file.path(tmp, "env_empty")
stub("rfd3", 'echo "看起来一切正常"; exit 0',
     dir = file.path(empty_env, "bin"))
root3 <- file.path(tmp, "run3")
sc <- file.path(root3, "rfd3.sh")
dir.create(root3, recursive = TRUE, showWarnings = FALSE)
writeLines(dsapp_cloud_step_script("rfd3", P, root3, empty_env, ck_dir, eval_py), sc)
o <- suppressWarnings(system2("bash", sc, stdout = TRUE, stderr = TRUE))
chk("★★ 第 1 步退出码 0 但**一个产物都没有** → 脚本必须非 0 退出（不能带着空目录往下跑）",
    !identical(as.integer(attr(o, "status") %||% 0L), 0L),
    paste(o, collapse = " | "))
chk("  而且那句话要说给用户听：告诉他原因和怎么办",
    any(grepl("没写出任何结构", o)))

# ---- 权重路径不对 → 当场失败（而不是几分钟后）------------------------------
bad_ck <- file.path(tmp, "ck_bad"); dir.create(bad_ck)
root4 <- file.path(tmp, "run4")
sc <- file.path(root4, "rfd3.sh")
dir.create(root4, recursive = TRUE, showWarnings = FALSE)
writeLines(dsapp_cloud_step_script("rfd3", P, root4, env_dir, bad_ck, eval_py), sc)
o <- suppressWarnings(system2("bash", sc, stdout = TRUE, stderr = TRUE))
chk("★ 权重不在那个目录里 → 第 1 步非 0 退出（预检也会拦，这里是第二道）",
    !identical(as.integer(attr(o, "status") %||% 0L), 0L))

# ---- 续跑：RF3 的 skip_existing 真的会跳过 ---------------------------------
before <- length(list.files(file.path(root2, "rf3", "1"), pattern = "_model\\.cif$"))
r3 <- run_step("rf3", root2)
after <- length(list.files(file.path(root2, "rf3", "1"), pattern = "_model\\.cif$"))
chk("★★ 重跑第 3 步：产物数量不变（skip_existing 真的跳过了，没有重复算）",
    identical(res[["rf3"]]$code, 0L) &&
      identical(as.integer(r3$code), 0L) && before == after,
    sprintf("%d -> %d", before, after))
chk("  而且日志里说得出它跳过了（不是默默什么都不做）",
    grepl("skip", r3$out, fixed = TRUE), substr(r3$out, 1, 200))

# ---- 只开一套 MPNN 时，另一套的目录不该被创建 -------------------------------
P1 <- P; P1$use_soluble <- FALSE
root5 <- file.path(tmp, "run5")
for (st in c("rfd3", "mpnn")) {
  sc <- file.path(root5, paste0(st, ".sh"))
  dir.create(root5, recursive = TRUE, showWarnings = FALSE)
  writeLines(dsapp_cloud_step_script(st, P1, root5, env_dir, ck_dir, eval_py), sc)
  system2("bash", sc, stdout = FALSE, stderr = FALSE)
}
chk("★ 只勾 ProteinMPNN 时，mpnn/2 不会被创建（不会留下一个空目录骗人）",
    dir.exists(file.path(root5, "mpnn", "1")) &&
      !dir.exists(file.path(root5, "mpnn", "2")))
l1 <- dsapp_cloud_layout(root5, P1)
s1 <- paste(dsapp_cloud_step_script("rfd3", P1, root5, env_dir, ck_dir, eval_py),
            collapse = "\n")
chk("  步骤表里那一步的名字也跟着只有一套（界面显示的和实际跑的一致）",
    grepl("ProteinMPNN", dsapp_cloud_steps(P1)[[2]]$label, fixed = TRUE) &&
      !grepl("SolubleMPNN", dsapp_cloud_steps(P1)[[2]]$label, fixed = TRUE))

# ---- 建议的两个分支（数据形状不同 → 该说的话不同）--------------------------
# 这两条不走真跑，直接喂形状已知的表：真跑那批数据是"有 2 条过线"的，
# 而分支恰恰只在**一条都没过**的时候才说话 —— 不单独喂的话，那两个分支
# 就是"写在那儿但从来没被执行过"（本仓栽过：自检全绿 ≠ 功能被验过）。
mk <- function(ipae, iptm, pld) list(
  ok = TRUE, n_ok = length(ipae), n_partial = 0L, n_error = 0L,
  df = data.frame(prediction_id = paste0("p", seq_along(ipae)), ipae = ipae,
                  iptm = iptm, binder_plddt = pld, status = "ok",
                  source = "ProteinMPNN", stringsAsFactors = FALSE))
a_ipae <- dsapp_cloud_advise(mk(c(15, 16), c(0.7, 0.75), c(80, 85)), P)
chk("★ 一条都没过 ipae 线 → 建议点的是 hotspot / contig（不是笼统的「再跑一批」）",
    a_ipae$n_pass == 0L &&
      grepl("换 hotspot", paste(a_ipae$lines, collapse = "\n"), fixed = TRUE))
a_iptm <- dsapp_cloud_advise(mk(c(8, 9), c(0.4, 0.45), c(80, 85)), P)
chk("★ ipae 过了但 ipTM 全没过 → 建议说的是「界面姿态缺强支持」",
    a_iptm$n_pass == 0L &&
      grepl("ipTM 偏低", paste(a_iptm$lines, collapse = "\n"), fixed = TRUE))

# ---- 预检：这台机器上应当如实报"缺权重"（而不是假装能跑）--------------------
# ⚠️ 权重目录显式指到一个**空目录**：这条断言问的是"缺权重时会不会如实报"，
#    而不是"这台机器现在装没装"。跟着机器走的话，哪天运维把权重装上了，
#    这条就从"验行为"变成"验环境"了。
Sys.setenv(DSAPP_FOUNDRY_CKPT = file.path(tmp, "ck_none"))
pf <- dsapp_cloud_preflight(P, cfg = dsapp_config(), user_id = NULL, gpu_ok = TRUE)
keys <- vapply(pf$items, function(x) x$key, character(1))
chk("★ 预检覆盖了该看的每一项（环境/权重/输入/contig/热点/脚本/卡/墙钟）",
    all(c("env", "ckpt", "input", "contig", "hotspot", "script", "gpu", "wall") %in%
          keys),
    paste(keys, collapse = ","))
item <- function(x, k) Filter(function(y) y$key == k, x$items)[[1]]
chk("  权重目录是空的 → ckpt 那一条必须不通过，且**说清缺哪几份、怎么办**",
    !item(pf, "ckpt")$ok && nzchar(item(pf, "ckpt")$fix) &&
      grepl("rfd3_latest.ckpt", item(pf, "ckpt")$detail, fixed = TRUE),
    item(pf, "ckpt")$detail)
chk("★ 墙钟那一条是 warn 不是 not-ok（能跑但要知情；红着一条修不好的项＝用户学会无视整张表）",
    item(pf, "wall")$ok)
wall_of <- function(pr) item(dsapp_cloud_preflight(
  dsapp_cloud_apply_preset(P, pr), cfg = dsapp_config(), gpu_ok = TRUE), "wall")
chk("  生产档（100 个骨架 ≈ 20 分钟）落在 30 分钟额度的一半以上 → 亮 warn",
    wall_of("production")$warn)
chk("  快速试跑（1 个骨架）不该亮 warn（亮着不灭的提示＝没有提示）",
    !wall_of("quick")$warn)

# =============================================================================
sect("E 上传：对齐 → 落盘 → 归属 → 挂进工作区（V16.7 item 4）")
# =============================================================================
# 用户原话：「单细胞云工具里需要支持上传数据来进行分析」。
#
# 这一段验的是**用户点完上传之后、点「开始运行」之前**那条路：
#   浏览器给的相对路径对不对得上 → 有没有真落进「文件」页那个区
#   → 归属登记的是不是相对路径 → 工作区里那一条是不是软链、是不是只读。
# 全都能在这里真跑，不需要 Shiny（下面已经在 tmp 里建了自己的库）。

# ⚠️ 保险丝：这一段会**写盘**。先确认数据根目录确实被挪到了临时目录 ——
#    仓库根的 .Renviron 把 DSAPP_DATA_ROOT 指着生产库，而"自检全绿"和
#    "没碰生产"是两件事（本仓为此栽过一次：顶层 {} 里的 on.exit 没执行，
#    泄漏了 DSAPP_DATA_ROOT，两行技能写进了生产库）。
chk("E0 保险丝：数据根目录在临时目录里（不在生产库上跑写操作）",
    startsWith(normalizePath(dsapp_config()$data_root, mustWork = FALSE),
               normalizePath(tmp, mustWork = FALSE)),
    dsapp_config()$data_root)

cfg_e <- dsapp_config_user(1L, dsapp_config())
con_e <- dsapp_db(cfg_e)
dir.create(cfg_e$files_dir, recursive = TRUE, showWarnings = FALSE)

# ---- 造一个像 10x 的文件夹上传（三个文件在 sample1/ 下）--------------------
stage <- file.path(tmp, "up_stage")
dir.create(file.path(stage, "sample1"), recursive = TRUE, showWarnings = FALSE)
for (fn in c("matrix.mtx", "barcodes.tsv", "features.tsv")) {
  writeLines(c("x", "y"), file.path(stage, "sample1", fn))
}
paths <- file.path("sample1", c("matrix.mtx", "barcodes.tsv", "features.tsv"))
up10x <- data.frame(
  name     = c("matrix.mtx", "barcodes.tsv", "features.tsv"),
  datapath = file.path(stage, "sample1", c("matrix.mtx", "barcodes.tsv",
                                           "features.tsv")),
  size     = c(4, 4, 4), stringsAsFactors = FALSE)

# ---- E1/E2 相对路径对齐 ----------------------------------------------------
chk("E1 长度相等 → 按下标对齐",
    identical(dsapp_upload_rels(up10x, paths), paths))
# ⚠️ 这条是**故意和 mod_files.R 不一样**的地方：那边兜底用 hit[1]，
#    在 "sample1/matrix.mtx" 和 "sample2/matrix.mtx" 同名的场景下会张冠李戴
#    （用户拿到的是"跑通了，但用的是另一个样本"）。这里要求它**放弃**。
chk("E2 ★ 长度不等 + 同名重复 → 不许猜（留 NA 平铺，而不是挑第一个）",
    all(is.na(dsapp_upload_rels(up10x, c("matrix.mtx", "matrix.mtx")))))
chk("E2b 长度相等时**按顺序**对齐，不按名字重排（Shiny 和 JS 用的是同一个顺序）",
    identical(dsapp_upload_rels(up10x, c("a/barcodes.tsv", "a/features.tsv",
                                         "a/matrix.mtx")),
              c("a/barcodes.tsv", "a/features.tsv", "a/matrix.mtx")))
chk("E2b2 长度不等 + 名字唯一 → 仍能配对，配不上的留 NA",
    identical(dsapp_upload_rels(up10x, c("a/barcodes.tsv", "a/matrix.mtx")),
              c("a/matrix.mtx", "a/barcodes.tsv", NA_character_)))
chk("E2c 单文件框（paths = NULL）→ 全是 NA（平铺到根目录）",
    all(is.na(dsapp_upload_rels(up10x[1, , drop = FALSE], NULL))))

# ---- E3/E4 传完之后该选中哪个 ----------------------------------------------
chk("E3 单文件上传 → 选中那个文件",
    identical(dsapp_cloudx_pick_after_upload("expr.csv"), "expr.csv"))
chk("E4 ★ 10x 三文件目录（mode=any）→ 选中顶层那个目录",
    identical(dsapp_cloudx_pick_after_upload(paths, mode = "any"), "sample1"))
chk("E4c mode=file + 目录里只有一个文件 → 选那个文件（.h5ad 那类字段传文件夹时）",
    identical(dsapp_cloudx_pick_after_upload(c("d/a.h5ad", "d/sub/x.mtx"),
                                             mode = "file"), "d/a.h5ad"))
# ⚠️ 目录里**多个**文件而字段只要一个文件 —— 选目录（而不是随手挑一个）。
#    选目录是"看得见的错"，用户在下拉里一眼看到是个目录；随手挑一个是
#    "看不见的错"，跑出来的结果没人知道用的是哪个文件。
chk("E4d mode=file + 目录里多个文件 → 选目录（宁可显眼地错，不许静默挑一个）",
    identical(dsapp_cloudx_pick_after_upload(c("d/a.csv", "d/x.mtx"),
                                             mode = "file"), "d"))

# ---- E5~E8 端到端：真存盘 / 真登记 / 真软链 ---------------------------------
ws_e <- file.path(tmp, "workspaces", "chat-probeE1")
r <- dsapp_cloudx_upload_apply(up10x, cfg_e, user_id = 1L, ws = ws_e,
                               rels = paths, mode = "any", con = con_e)
chk("E5 三个文件都存进了共享区（=「文件」页那个区）",
    length(r$saved) == 3L &&
      all(file.exists(file.path(cfg_e$files_dir, r$shared))), r$msg)
chk("E6 ★ 归属登记的是**相对路径**（用 basename 的话文件会变「人人可删」）",
    identical(r$shared, paths) &&
      isTRUE(dsapp_file_owner(r$shared[[1]], con = con_e, user_id = 1L) == 1L),
    paste(r$shared, collapse = ","))
chk("E7 ★ 工作区里是**软链**（不是复制：生信数据是几个 G）",
    all(file.exists(file.path(ws_e, r$shared))) &&
      all(nzchar(Sys.readlink(file.path(ws_e, r$shared)))),
    paste(Sys.readlink(file.path(ws_e, r$shared)), collapse = ","))
chk("E8 ★ 挂过去的那份是**只读**的（原件 0444 是 dsapp_file_save 设的）",
    all(file.access(file.path(ws_e, r$shared), 2L) != 0L))
chk("E8b 目录结构保住了（sample1/ 不是平铺）",
    dir.exists(file.path(ws_e, "sample1")))

# ---- E4b 选中的值必须**真的在候选里**---------------------------------------
# ⚠️ 这一条防的是 selectize 的静默清空：addItem 第一句是
#    `if (!self.options.hasOwnProperty(value)) return;` —— selected 不在
#    choices 里时控件被清空后什么都不加，input$x_<fid> 静默变成 ""，
#    要等到用户点「开始运行」才报"还没选"。
chk("E4b ★ 选中的值必须出现在下拉候选里（否则下拉静默变空）",
    dsapp_cloudx_pick_after_upload(paths, mode = "any") %in%
      names(dsapp_cloudx_file_choices(ws_e)),
    paste(names(dsapp_cloudx_file_choices(ws_e)), collapse = ","))

# ---- E9 没有对话 → 一个字节都不许写 ----------------------------------------
n_before <- length(list.files(cfg_e$files_dir, recursive = TRUE))
r0 <- dsapp_cloudx_upload_apply(up10x, cfg_e, user_id = 1L, ws = NULL,
                                rels = paths, mode = "any", con = con_e)
chk("E9 ★ 没有打开的对话时不落盘、不留半截状态（在写盘之前就拒绝）",
    identical(r0$ok, FALSE) &&
      length(list.files(cfg_e$files_dir, recursive = TRUE)) == n_before &&
      grepl("对话", r0$msg), r0$msg)

# ---- E10 工作区已存在同名 → 不覆盖 -----------------------------------------
# 造的是这一种：工作区里**已经有一份用户自己的 keep.csv**（多半是上一轮
# 跑出来的产物），现在用户又传上来一个同名的。共享区里没有这个东西，所以
# 上传会成功；到镜像那一步才撞名 —— 撞上必须**跳过**，绝不能盖掉。
writeLines("mine", file.path(ws_e, "keep.csv"))
writeLines("uploaded", file.path(stage, "keep.csv"))
r_same <- dsapp_cloudx_upload_apply(
  data.frame(name = "keep.csv", datapath = file.path(stage, "keep.csv"),
             size = 9, stringsAsFactors = FALSE),
  cfg_e, user_id = 1L, ws = ws_e, rels = NULL, mode = "file", con = con_e)
chk("E10 同名文件确实存进了共享区（上传本身是成功的）",
    "keep.csv" %in% r_same$saved, r_same$msg)
chk("E10b ★ 工作区那份**没被覆盖**（那是用户的真实数据，跳过并如实报出来）",
    identical(readLines(file.path(ws_e, "keep.csv")), "mine") &&
      "keep.csv" %in% r_same$skipped,
    paste("skipped =", paste(r_same$skipped, collapse = ",")))

# ---- E11 字段 id 是**按注册表枚举**的，不是硬编码的几个 ---------------------
ids <- dsapp_cloudx_file_ids()
chk("E11 ★ 文件字段 id 覆盖注册表里全部四个（硬编码 = 新字段静默没上传框）",
    all(c("input", "expr", "types", "clin") %in% ids) && length(ids) >= 4L,
    paste(ids, collapse = ","))

# =============================================================================
say("\n== 通过 %d / 失败 %d ==", NOK, nfail)
if (nfail > 0L) quit(status = 1L)
