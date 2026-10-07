# =============================================================================
# 云工具的**执行体**注册表（★ V16.6 item 4）
# =============================================================================
# 用户原话（2026-10-05）：
#
#   > 云工具是有GUI的工具，而不是接入言出法随界面给提示词，请按新逻辑制作云工具界面
#
# V16.4 把两份文档里的「0. 工具能力注册表」解析成了结构（R/cloudtool.R 末节），
# 于是界面上 107 个工具**列得出来**了 —— 但点下去做的是「新开一个对话，把一段
# 开场白发出去」。用户这一次明确说不要那样：**云工具就该是有参数表单、有产物、
# 有日志的工具**，不是一个会写提示词的按钮。
#
# 所以这一页现在是**三层叠加**：
#
#   ① 文档层   skills_builtin/*.md          —— 有哪些工具、各自干什么（人写的）
#   ② 解析层   R/cloudtool.R 末节            —— 把 ① 变成结构，界面上列得出来
#   ③ 执行体   **本文件**                    —— key → 参数表单 + 脚本 + 产物
#
# -----------------------------------------------------------------------------
# ★★ 三层是**叠加**的，不是替代关系
# -----------------------------------------------------------------------------
# 没写执行体的工具**照样列在界面上**（走 ②），点开之后那张卡片明说
# 「未接入执行体」并把这个工具的功能/入参/出参原样摆出来 —— **不再往对话里
# 发提示词**。理由：发提示词那条路用户已经明确否掉了，而"点一个没有执行体的
# 工具、界面假装它在跑"比"明说还没接"更糟。
#
# -----------------------------------------------------------------------------
# ★★ key 必须**逐字**等于文档注册表里的工具名
# -----------------------------------------------------------------------------
# 对不上的后果是"界面上永远点不到这个执行体"，而代码看起来完全正常 ——
# 没有报错、没有红字，只是那个工具点开还是「未接入执行体」。自检里有一条
# 拿文档解析结果和本文件的 key 对撞（`dsapp_cloudx_orphans()`）。
#
# -----------------------------------------------------------------------------
# ★★ 参数怎么进脚本：**环境变量**，不是字符串拼进代码里
# -----------------------------------------------------------------------------
# 每个字段的值由 bash 头 `export DSAPP_<字段名大写>=...` 带进去，脚本里用
# `P("min_genes")` / `I("min_genes")` 读。这样做有三个好处：
#   · 脚本正文对每个工具是**常量**（源码扫描/自检能直接读它，不用拼字符串）；
#   · 用户填的东西（路径里有空格、有 `$`、有引号）不会被当成代码执行；
#   · 生成的 `run.sh` 人能看懂、能自己重跑。
# ⚠️ 值的引号一律 `shQuote()`（单引号包裹）。手写 `"'"` 拼接在路径含单引号时
#    会静默拼出另一条命令。
# =============================================================================


# =============================================================================
# 一、环境：这个执行体在哪儿跑
# =============================================================================
# `scRNA` 是应用自己建的环境（`<data_root>/envs/scRNA`，`R/envs.R` 那条路建的），
# 里面有 scanpy / anndata / leidenalg / matplotlib。`""` 表示**平台自带的 R**
# （系统 R + survival/survminer/limma/DESeq2/TCGAbiolinks —— 2026-10-05 在本机
# 逐个 `requireNamespace()` 核过）。
DSAPP_CLOUDX_ENVS <- list(
  scRNA = "scRNA",
  R     = ""
)

#' 执行体要用的环境目录
#'
#' `env` 是**表里的名字**（`spec$env`，如 `"scRNA"` / `"R"`），不是目录名 ——
#' 表把它映射成目录（`R` → `""` = 用平台自带的解释器，不往 PATH 前面塞东西）。
#'
#' @return 目录路径；`""` 表示平台自带的解释器；`NA_character_` 表示用不了
#'   （名字不在表里，或者表里那个目录还不存在）。调用方据此说"这个环境还没建"，
#'   而不是让它跑到一半报一句看不懂的 `python: command not found`。
dsapp_cloudx_env_dir <- function(env, cfg = dsapp_config()) {
  e <- as.character(env %||% "")[1]
  if (is.na(e)) return(NA_character_)
  if (!nzchar(e)) return("")
  # ⚠️ `exact = TRUE` 不能省：`list(scRNA=…)[["sc"]]` 会**部分匹配**到 scRNA
  #    并安安静静地返回它 —— 环境名写错一个字母，症状是"用了另一个环境"，
  #    比报错难查得多。
  nm <- DSAPP_CLOUDX_ENVS[[e, exact = TRUE]]
  if (is.null(nm)) return(NA_character_)
  if (!nzchar(nm)) return("")
  d <- file.path(cfg$envs_root, nm)
  if (!dir.exists(d)) return(NA_character_)
  d
}

#' 环境取不到时，给用户的那句话
dsapp_cloudx_env_msg <- function(env, cfg = dsapp_config()) {
  e <- as.character(env %||% "")[1]
  if (!nzchar(e) || is.null(DSAPP_CLOUDX_ENVS[[e, exact = TRUE]])) {
    return(sprintf("这个工具登记的环境名「%s」不在本版支持的环境表里（有：%s）。",
                   e, paste(names(DSAPP_CLOUDX_ENVS), collapse = " / ")))
  }
  sprintf("这个工具要用的环境「%s」在这台机器上还没建好（找的是 %s）。",
          e, file.path(cfg$envs_root, DSAPP_CLOUDX_ENVS[[e, exact = TRUE]]))
}


# =============================================================================
# 二、字段（参数表单就是这些描述生成的）
# =============================================================================
# ⚠️ 每个字段必须有**默认值**：这一页的哲学是"默认值就是能跑的那一套"，
#    用户什么都不改也应该能跑出一个结果来（哪怕不是他要的那个）。
fx_num <- function(id, label, def, help = "") {
  list(id = id, label = label, type = "num", def = as.numeric(def), help = help)
}
fx_int <- function(id, label, def, help = "") {
  list(id = id, label = label, type = "int", def = as.integer(def), help = help)
}
fx_txt <- function(id, label, def = "", help = "") {
  list(id = id, label = label, type = "txt", def = as.character(def),
       help = help)
}
fx_sel <- function(id, label, choices, def = NULL, help = "") {
  if (is.null(def)) def <- unname(choices[[1]])
  list(id = id, label = label, type = "sel", choices = choices,
       def = as.character(def), help = help)
}
#' 从**工作区**里挑一个文件/目录
#'
#' `mode` 是 "file" / "dir" / "any"；`exts` 是给界面的过滤提示（**不**用来
#' 拦人：用户选的路径要原样交出去，拦错了他只会看到"文件不见了"）。
fx_file <- function(id, label, mode = "file", exts = NULL, def = "",
                    help = "", required = TRUE) {
  list(id = id, label = label, type = "file", mode = mode,
       exts = if (is.null(exts)) character(0) else as.character(exts),
       def = as.character(def), help = help, required = isTRUE(required))
}
fx_genes <- function(id, label, def = "", help = "") {
  list(id = id, label = label, type = "genes", def = as.character(def),
       help = help)
}


# =============================================================================
# 三、脚本骨架（bash 头 + 两种语言的头）
# =============================================================================

#' bash 头：目录、PATH、参数、日志约定
#'
#' ⚠️ 刻意**不用** `set -e`：每一步的失败都要自己判（下面的 `need()`），
#'    因为"退出码 0 但一个产物都没写"在生信工具里是常态。
dsapp_cloudx_head <- function(root, env_dir, vals, rscript = FALSE) {
  q <- function(x) shQuote(as.character(x))
  pv <- unlist(vals, use.names = TRUE)
  pv <- pv[!is.na(names(pv)) & nzchar(names(pv))]
  ex <- if (length(pv)) {
    sprintf("export DSAPP_%s=%s", toupper(names(pv)), vapply(pv, q, character(1)))
  } else character(0)
  c("#!/bin/bash",
    "# 由「云工具」页生成（Test_V16.6 item 4）。**改了不会同步回界面** ——",
    "# 但这一份是可以直接重跑的：cd 到这个目录，bash run.sh 即可。",
    "set -u",
    # ⚠️ `pipefail` 是为了下面「`python main.py | tee` 之后还能判成败」：
    #    不加的话管道的退出码是 `tee` 的（永远是 0），脚本会把一个**失败**
    #    的 Python 当成成功走下去，一路走到"产物不见了"才炸。
    #    （和文件头那句"刻意不用 set -e"不冲突：那条说的是"别让一步失败就
    #     无声中断"，这里管的是"别把失败看成成功"。）
    "set -o pipefail",
    sprintf("ROOT=%s", q(root)),
    sprintf("cd %s || exit 3", q(root)),
    # ★ 每一步的完整输出**自己也留一份**在产物目录里（`run.log`）。
    #   执行引擎另有一份 stdout，但那一份跟着工作区走、会被下一次任务盖掉；
    #   这一份跟**这次运行**走，用户过两天回来还能看到当时报了什么。
    'LOG="$ROOT/run.log"',
    if (!is.na(env_dir) && nzchar(env_dir))
      sprintf("export PATH=%s:$PATH", q(file.path(env_dir, "bin"))),
    "export PYTHONUNBUFFERED=1",
    "export MPLBACKEND=Agg",
    # R 在非 UTF-8 的 locale 下读中文列名会乱码（本仓在 executor.R 里也钉过
    # 这一条）。macOS 上没有 C.UTF-8，所以按顺序试，最后一个能用的生效。
    if (isTRUE(rscript))
      c('export LANG="${LANG:-en_US.UTF-8}"',
        'export LC_ALL="${LC_ALL:-$LANG}"'),
    ex,
    "",
    "say() { echo \"[$(date +%H:%M:%S)] $*\" | tee -a \"$LOG\"; }",
    # ⚠️ 这两句是**给用户看的**，所以要写清楚"现在怎么办"，不是只报错。
    paste0("die() { echo \"!! $*\" | tee -a \"$LOG\"; ",
           "echo '!! 这一步没跑完。上面的日志就是原因；' | tee -a \"$LOG\"; ",
           "echo '!! 改完参数可以重新跑一次（产物目录里已经写出来的东西不会白费）。' ",
           "| tee -a \"$LOG\"; exit 3; }"),
    "need() { [ -e \"$1\" ] || die \"找不到：$1\"; }",
    "")
}

#' Python 段：把正文写进 main.py 再跑
#'
#' ⚠️ 用**带引号的** heredoc 分隔符（`<<'DSAPP_PY'`）→ bash 不做变量展开和命令
#'    替换，正文里的 `$` / 反引号 / 反斜杠原样落地。同时它落成 `main.py`，
#'    用户能自己打开看（"这个工具到底对我做了什么"是可解释性的一部分）。
dsapp_cloudx_py <- function(body, file = "main.py") {
  c(sprintf("cat > %s <<'DSAPP_PY_EOF'", file),
    body,
    "DSAPP_PY_EOF",
    sprintf("say '运行 %s'", file),
    # `| tee -a` 是为了让**看着界面的人**能实时看到输出（只重定向到文件的话
    # 界面上会一直空着，看起来像卡住了）；`set -o pipefail`（在上面）保证
    # Python 的失败不会被 tee 的 0 盖掉。
    sprintf("python %s 2>&1 | tee -a \"$LOG\" || die 'Python 脚本没跑完'", file),
    "")
}

#' R 段：同上
dsapp_cloudx_r <- function(body, file = "main.R") {
  c(sprintf("cat > %s <<'DSAPP_R_EOF'", file),
    body,
    "DSAPP_R_EOF",
    sprintf("say '运行 %s'", file),
    sprintf("Rscript --vanilla %s 2>&1 | tee -a \"$LOG\" || die 'R 脚本没跑完'", file),
    "")
}

#' Python 公用前缀：读参数、安静、Agg 后端
#'
#' ⚠️ `matplotlib.use("Agg")` 必须在 `import matplotlib.pyplot` **之前** ——
#'    服务器上没有 DISPLAY，用默认后端在 `savefig` 时才炸，而且报的是
#'    "no display name and no $DISPLAY environment variable"，看不出跟画图有关。
DSAPP_CLOUDX_PY_HEAD <- c(
  "import os, sys, json, warnings",
  "warnings.filterwarnings('ignore')",
  "import numpy as np, pandas as pd",
  "import matplotlib",
  "matplotlib.use('Agg')",
  "import matplotlib.pyplot as plt",
  "",
  "ROOT = os.environ.get('ROOT') or os.getcwd()",
  "",
  "def P(k, d=''):",
  "    v = os.environ.get('DSAPP_' + k.upper())",
  "    return d if v is None or v == '' else v",
  "",
  "def I(k, d=0):",
  "    try:    return int(float(P(k, d)))",
  "    except Exception: return int(d)",
  "",
  "def F(k, d=0.0):",
  "    try:    return float(P(k, d))",
  "    except Exception: return float(d)",
  "",
  "def B(k, d=False):",
  "    return str(P(k, '1' if d else '0')).lower() in ('1', 'true', 'yes', 'y', 'on')",
  "",
  "def out(*a):",
  "    p = os.path.join(ROOT, *a)",
  "    os.makedirs(os.path.dirname(p), exist_ok=True)",
  "    return p",
  "",
  "def savefig(fig, name, dpi=150):",
  "    p = out(name)",
  "    fig.savefig(p, dpi=dpi, bbox_inches='tight')",
  "    plt.close(fig)",
  "    print('[figure] ' + name)",
  "",
  "def say(*a):",
  "    print('[dsapp]', *a, flush=True)",
  ""
)

#' R 公用前缀
DSAPP_CLOUDX_R_HEAD <- c(
  "suppressWarnings(suppressMessages({",
  "  library(data.table)",
  "}))",
  "ROOT <- Sys.getenv('ROOT', getwd())",
  "P <- function(k, d = '') { v <- Sys.getenv(paste0('DSAPP_', toupper(k)), '');",
  "                         if (!nzchar(v)) d else v }",
  "I <- function(k, d = 0L) { v <- suppressWarnings(as.integer(P(k, d)));",
  "                           if (is.na(v)) as.integer(d) else v }",
  "F <- function(k, d = 0) { v <- suppressWarnings(as.numeric(P(k, d)));",
  "                          if (is.na(v)) as.numeric(d) else v }",
  "B <- function(k, d = FALSE) { v <- tolower(P(k, if (d) '1' else '0'));",
  "                              v %in% c('1','true','yes','y','on') }",
  "# ⚠️ 分隔符按平台试：**macOS 上没有 C.UTF-8**（见 R/executor.R 里同样的账）",
  "sep <- if (grepl('windows', .Platform$OS.type)) ',' else",
  "       if (grepl('darwin', R.version$os)) '\\t' else '\\t'",
  "say <- function(...) cat('[dsapp]', ..., '\\n', sep = '')",
  "out <- function(...) { p <- file.path(ROOT, ...);",
  "                      dir.create(dirname(p), recursive = TRUE,",
  "                                 showWarnings = FALSE); p }",
  "die <- function(...) { cat('!!', ..., '\\n'); quit(status = 3) }",
  "need <- function(p, what = p) if (!file.exists(p)) die('找不到：', what)",
  ""
)

#' 参数值 → 环境变量要的字符向量
#'
#' ⚠️ 全部转成**长度 1 的字符**：`vapply` 的 USE.NAMES 陷阱、以及
#'    `paste0("x:", character(0))` 会变成 `"x:"` 那两条都在本仓记过账。
#'    这里逐个 `as.character(x)[1]` 并补 `%||% ""`。
dsapp_cloudx_flat <- function(vals) {
  if (!length(vals)) return(character(0))
  vapply(vals, function(x) {
    s <- tryCatch(as.character(x %||% "")[1], error = function(e) "")
    if (is.na(s)) "" else s
  }, character(1))
}


# =============================================================================
# 四、单细胞那一套（Scanpy）
# =============================================================================
# 六步都是**同一条链**：读入 → 质控 → 归一化/HVG → 降维聚类 → marker → 组间差异。
# 每一步都能单独跑（输入是一个 .h5ad），也能串起来跑 —— 串起来就是依次点六个
# 工具，前一个的产物在下一次的文件下拉里就能选到。
#
# ⚠️ 为什么不写成"一条流水线四个按钮"：用户要的是**工具**。真实分析里
#    参数是一步步看数据定的（质控阈值看第一张 QC 图，resolution 看第一次
#    UMAP），把四步锁进一条链等于逼着他每次都从头跑。
DSAPP_CLOUDX_SC <- list(

  # ---- 1. 读入 ---------------------------------------------------------------
  sc_read_data = list(
    title = "读入单细胞数据",
    env   = "scRNA",
    about = paste("支持 10x 的三文件目录（matrix.mtx / barcodes / features）、",
                  "10x 的 .h5、以及已经整理好的 .h5ad / .csv。读进来之后算一遍",
                  "基础 QC 指标，方便下一步定阈值。"),
    fields = list(
      fx_file("input", "数据在哪（工作区里的目录或文件）", mode = "any",
              help = "点下拉选，或直接在下面上传（10x 请选文件夹）。"),
      fx_sel("fmt", "格式", c("自动判断" = "auto", "10x 三文件目录" = "10x_mtx",
                              "10x .h5" = "10x_h5", "h5ad" = "h5ad",
                              "csv/tsv 矩阵（行=基因，列=细胞）" = "csv"),
             def = "auto"),
      fx_sel("species", "物种", c("人" = "human", "小鼠" = "mouse"),
             def = "human"),
      fx_txt("name", "产物文件名（不含扩展名）", "raw")
    ),
    outputs = c("raw.h5ad", "read_summary.csv"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import gzip, scanpy as sc",
        "SRC = P('input')",
        "FMT = P('fmt', 'auto')",
        "NAME = P('name', 'raw')",
        "say('源：' + SRC)",
        "",
        "# 自动判断：目录 + matrix.mtx* → 10x；.h5 → 10x_h5；.h5ad → h5ad",
        "def guess(p):",
        "    lp = p.lower()",
        "    if lp.endswith('.h5ad'): return 'h5ad'",
        "    if lp.endswith('.h5'):   return '10x_h5'",
        "    if os.path.isdir(p):     return '10x_mtx'",
        "    if lp.endswith(('.csv', '.tsv', '.txt')): return 'csv'",
        "    return 'h5ad'",
        "",
        "FMT = guess(SRC) if FMT == 'auto' else FMT",
        "say('按 ' + FMT + ' 读')",
        "if not os.path.exists(SRC):",
        "    sys.exit('找不到输入：' + SRC)",
        "",
        "# ★★★ 10x 目录：scanpy **只认压缩过的** `matrix.mtx.gz`。",
        "#   它的分支条件是「有 features.tsv 就走 v3 读取器」，而 v3 读取器直接",
        "#   拼 `matrix.mtx.gz` 去 open —— 用户手里那份如果是解压过的（想看一眼",
        "#   矩阵内容，很常见），拿到的是 `FileNotFoundError: Did not find file",
        "#   …/matrix.mtx.gz`，而文件明明就躺在那个目录里。实测踩到。",
        "#   所以：.gz 齐全才交给 scanpy，未压缩的自己读。",
        "def _open10x(p):",
        "    return gzip.open(p, 'rt') if p.endswith('.gz') else open(p)",
        "",
        "def _pick10x(d, *names):",
        "    for n in names:",
        "        f = os.path.join(d, n)",
        "        if os.path.exists(f):",
        "            return [l.rstrip('\\n').split('\\t') for l in _open10x(f)]",
        "    return None",
        "",
        "def read_10x_plain(d):",
        "    import scipy.io as sio",
        "    M = sio.mmread(os.path.join(d, 'matrix.mtx')).tocsr()",
        "    bc = _pick10x(d, 'barcodes.tsv', 'barcodes.tsv.gz')",
        "    ft = _pick10x(d, 'features.tsv', 'features.tsv.gz',",
        "                  'genes.tsv', 'genes.tsv.gz')",
        "    if bc is None or ft is None:",
        "        sys.exit('10x 目录里缺 barcodes.tsv 或 features.tsv/genes.tsv')",
        "    x = sc.AnnData(M.T.tocsr().astype('float32'))",
        "    x.obs_names = [r[0] for r in bc]",
        "    x.var_names = [(r[1] if len(r) > 1 else r[0]) for r in ft]",
        "    return x",
        "",
        "def find_10x(d):",
        "    # 用户常常指到 CellRanger 的输出根目录，真正的三文件在下一层",
        "    if ('matrix.mtx' in os.listdir(d)) or ('matrix.mtx.gz' in os.listdir(d)):",
        "        return d",
        "    for s in sorted(os.listdir(d)):",
        "        p = os.path.join(d, s)",
        "        if os.path.isdir(p) and (('matrix.mtx' in os.listdir(p))",
        "                                 or ('matrix.mtx.gz' in os.listdir(p))):",
        "            say('指到的是上层目录，实际用 ' + s)",
        "            return p",
        "    return d",
        "",
        "if FMT == '10x_mtx':",
        "    SRC = find_10x(SRC)",
        "    if 'matrix.mtx.gz' in os.listdir(SRC):",
        "        a = sc.read_10x_mtx(SRC, var_names='gene_symbols', cache=False)",
        "    elif 'matrix.mtx' in os.listdir(SRC):",
        "        a = read_10x_plain(SRC)",
        "    else:",
        "        sys.exit('这个目录里没有 matrix.mtx(.gz)：' + SRC)",
        "elif FMT == '10x_h5':",
        "    a = sc.read_10x_h5(SRC)",
        "elif FMT == 'h5ad':",
        "    a = sc.read_h5ad(SRC)",
        "else:",
        "    d = pd.read_csv(SRC, sep=None, engine='python', index_col=0)",
        "    a = sc.AnnData(d.T.astype('float32'))",
        "",
        "# 基因名去重（同名基因会让 rank_genes_groups 报 'Index.duplicated'）",
        "a.var_names_make_unique()",
        "a.obs_names_make_unique()",
        "a.var['mt'] = a.var_names.str.upper().str.startswith('MT-')",
        "sc.pp.calculate_qc_metrics(a, qc_vars=['mt'], percent_top=None,",
        "                           log1p=False, inplace=True)",
        "say('读进来：%d 个细胞 × %d 个基因' % (a.n_obs, a.n_vars))",
        "if a.n_obs == 0 or a.n_vars == 0:",
        "    sys.exit('读出来是空的 —— 检查格式选项对不对')",
        "",
        "s = pd.DataFrame({'metric': ['n_cells', 'n_genes', 'median_genes_per_cell',",
        "                             'median_counts_per_cell', 'median_pct_mt'],",
        "                  'value': [a.n_obs, a.n_vars,",
        "                            float(np.median(a.obs['n_genes_by_counts'])),",
        "                            float(np.median(a.obs['total_counts'])),",
        "                            float(np.median(a.obs['pct_counts_mt']))]})",
        "s.to_csv(out('read_summary.csv'), index=False)",
        "print(s.to_string(index=False))",
        "a.write(out(NAME + '.h5ad'))",
        "say('写出 ' + NAME + '.h5ad')",
        "if NAME != 'raw':",
        "    a.write(out('raw.h5ad'))",
        ""
      ))
    )
  ),

  # ---- 2. 质控 ---------------------------------------------------------------
  sc_qc_filter = list(
    title = "QC 指标计算 + 低质量细胞过滤",
    env   = "scRNA",
    about = paste("按基因数 / 计数 / 线粒体比例三个口径滤掉低质量细胞和空液滴。",
                  "默认值是常见起点，不是标准答案 —— 先看 qc_violin.png 再调。"),
    fields = list(
      fx_file("input", "输入 .h5ad", exts = ".h5ad"),
      fx_int("min_genes", "最少基因数 / 细胞", 200),
      fx_int("min_cells", "一个基因至少在几个细胞里表达", 3),
      fx_int("max_genes", "最多基因数（0 = 不限）", 0),
      fx_int("min_counts", "最少 UMI 数 / 细胞", 500),
      fx_num("max_pct_mt", "线粒体比例上限（%）", 20),
      fx_txt("name", "产物文件名（不含扩展名）", "filtered")
    ),
    outputs = c("filtered.h5ad", "qc_before_after.csv", "qc_violin.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import scanpy as sc",
        "a = sc.read_h5ad(P('input'))",
        "NAME = P('name', 'filtered')",
        "a.var['mt'] = a.var_names.str.upper().str.startswith('MT-')",
        "sc.pp.calculate_qc_metrics(a, qc_vars=['mt'], percent_top=None,",
        "                           log1p=False, inplace=True)",
        "n0 = a.n_obs",
        "",
        "fig, ax = plt.subplots(1, 3, figsize=(12, 3.2))",
        "for k, (c, t) in enumerate([('n_genes_by_counts', 'genes/cell'),",
        "                            ('total_counts', 'counts/cell'),",
        "                            ('pct_counts_mt', '% mito')]):",
        "    ax[k].hist(a.obs[c].values, bins=60, color='#4c78a8')",
        "    ax[k].set_xlabel(t); ax[k].set_ylabel('cells')",
        "fig.suptitle('过滤前（n=%d）' % n0)",
        "savefig(fig, 'qc_violin.png')",
        "",
        "sc.pp.filter_cells(a, min_genes=I('min_genes', 200))",
        "sc.pp.filter_cells(a, min_counts=I('min_counts', 500))",
        "mg = I('max_genes', 0)",
        "if mg > 0:",
        "    a = a[a.obs['n_genes_by_counts'] <= mg].copy()",
        "a = a[a.obs['pct_counts_mt'] <= F('max_pct_mt', 20)].copy()",
        "sc.pp.filter_genes(a, min_cells=I('min_cells', 3))",
        "n1 = a.n_obs",
        "if n1 == 0:",
        "    sys.exit('过滤之后一个细胞都不剩了 —— 阈值太紧，看 qc_violin.png 再调')",
        "print(pd.DataFrame({'stage': ['before', 'after'], 'n_cells': [n0, n1],",
        "                    'n_genes': [int(a.n_vars), int(a.n_vars)]})",
        "      .to_string(index=False))",
        "pd.DataFrame({'stage': ['before', 'after'], 'n_cells': [n0, n1]}",
        "             ).to_csv(out('qc_before_after.csv'), index=False)",
        "say('保留 %d / %d 个细胞（%.1f%%）' % (n1, n0, 100.0 * n1 / max(n0, 1)))",
        "a.write(out(NAME + '.h5ad'))",
        ""
      ))
    )
  ),

  # ---- 3. 归一化 + HVG + PCA --------------------------------------------------
  sc_normalize_hvg = list(
    title = "标准化 + 高变基因 + PCA",
    env   = "scRNA",
    about = paste("归一化 → log1p → 选高变基因 → 缩放 → PCA。",
                  "HVG 名单和每个主成分的解释方差都写成表，画 pca.png。"),
    fields = list(
      fx_file("input", "输入 .h5ad", exts = ".h5ad"),
      fx_num("target_sum", "每个细胞的归一化总量", 10000),
      fx_int("n_top_genes", "高变基因个数", 2000),
      fx_int("n_pcs", "PCA 主成分个数", 30),
      fx_sel("hvg_flavor", "HVG 选法",
             c("seurat（推荐）" = "seurat", "cell_ranger" = "cell_ranger",
               "seurat_v3" = "seurat_v3"), def = "seurat"),
      fx_txt("name", "产物文件名（不含扩展名）", "norm")
    ),
    outputs = c("norm.h5ad", "hvg.csv", "pca.png", "pca_variance.csv"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import scanpy as sc",
        "a = sc.read_h5ad(P('input'))",
        "NAME = P('name', 'norm')",
        "a.layers['counts'] = a.X.copy()",
        "sc.pp.normalize_total(a, target_sum=F('target_sum', 1e4))",
        "sc.pp.log1p(a)",
        "a.raw = a",
        "fl = P('hvg_flavor', 'seurat')",
        "ntop = I('n_top_genes', 2000)",
        "if fl == 'seurat_v3':",
        "    sc.pp.highly_variable_genes(a, n_top_genes=ntop, flavor='seurat_v3',",
        "                                layer='counts')",
        "else:",
        "    sc.pp.highly_variable_genes(a, n_top_genes=ntop, flavor=fl)",
        "hv = a.var[a.var['highly_variable']].copy()",
        "say('高变基因 %d 个' % len(hv))",
        "hv.to_csv(out('hvg.csv'))",
        "a = a[:, a.var['highly_variable']].copy()",
        "sc.pp.scale(a, max_value=10)",
        "npcs = min(I('n_pcs', 30), a.n_obs - 1, a.n_vars - 1)",
        "if npcs < 2: sys.exit('细胞或基因太少，跑不了 PCA')",
        "sc.tl.pca(a, n_comps=npcs, svd_solver='arpack')",
        "vr = a.uns['pca']['variance_ratio']",
        "pd.DataFrame({'PC': np.arange(1, len(vr) + 1),",
        "              'variance_ratio': vr}).to_csv(out('pca_variance.csv'),",
        "                                            index=False)",
        "fig, ax = plt.subplots(figsize=(5, 3.4))",
        "ax.plot(np.arange(1, len(vr) + 1), np.cumsum(vr), marker='o', ms=3)",
        "ax.set_xlabel('PC'); ax.set_ylabel('cumulative variance ratio')",
        "ax.axhline(0.9, ls='--', c='#e45756', lw=1)",
        "savefig(fig, 'pca.png')",
        "say('前 %d 个 PC 累计解释 %.1f%%' % (min(10, len(vr)),",
        "                                     100 * float(np.sum(vr[:10]))))",
        "a.write(out(NAME + '.h5ad'))",
        ""
      ))
    )
  ),

  # ---- 4. 降维聚类 ------------------------------------------------------------
  sc_dimreduce_cluster = list(
    title = "邻接图 → UMAP/tSNE → 聚类",
    env   = "scRNA",
    about = paste("在 PCA 空间上建邻接图，跑 UMAP（或 tSNE）和 Leiden/Louvain 聚类。",
                  "resolution 越大簇越多；0.4~1.2 是常见区间。产物里带每个簇的细胞数。"),
    fields = list(
      fx_file("input", "输入 .h5ad（一般是上一步的 norm.h5ad）", exts = ".h5ad"),
      fx_int("n_pcs", "用几个主成分", 30),
      fx_int("n_neighbors", "邻居数", 15),
      fx_num("resolution", "聚类分辨率", 0.8),
      fx_sel("cluster", "聚类方法", c("leiden" = "leiden", "louvain" = "louvain"),
             def = "leiden"),
      fx_sel("embed", "降维图", c("umap" = "umap", "tsne" = "tsne"),
             def = "umap"),
      fx_txt("name", "产物文件名（不含扩展名）", "clustered")
    ),
    outputs = c("clustered.h5ad", "cluster_sizes.csv", "umap.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import scanpy as sc",
        "a = sc.read_h5ad(P('input'))",
        "NAME = P('name', 'clustered')",
        "npcs = min(I('n_pcs', 30), max(2, a.n_obs - 1))",
        "if 'X_pca' not in a.obsm:",
        "    sc.tl.pca(a, n_comps=npcs, svd_solver='arpack')",
        "sc.pp.neighbors(a, n_neighbors=I('n_neighbors', 15), n_pcs=npcs)",
        "key = P('cluster', 'leiden')",
        "if key == 'louvain':",
        "    sc.tl.louvain(a, resolution=F('resolution', 0.8), key_added='cluster')",
        "else:",
        "    sc.tl.leiden(a, resolution=F('resolution', 0.8), key_added='cluster',",
        "                 flavor='igraph', n_iterations=2, directed=False)",
        "emb = P('embed', 'umap')",
        "if emb == 'tsne':",
        "    sc.tl.tsne(a, n_pcs=npcs, perplexity=min(30.0, max(5.0, (a.n_obs - 1) / 3.0)))",
        "    a.obsm['X_umap'] = a.obsm['X_tsne']",
        "else:",
        "    sc.tl.umap(a)",
        "cnt = a.obs['cluster'].value_counts().sort_index()",
        "pd.DataFrame({'cluster': cnt.index.astype(str),",
        "              'n_cells': cnt.values}).to_csv(out('cluster_sizes.csv'),",
        "                                             index=False)",
        "say('%s 分出 %d 个簇' % (key, len(cnt)))",
        "fig, ax = plt.subplots(figsize=(5.2, 4.4))",
        "xy = a.obsm['X_umap']",
        "for c in cnt.index.astype(str):",
        "    m = (a.obs['cluster'].astype(str) == c).values",
        "    ax.scatter(xy[m, 0], xy[m, 1], s=3, label=c)",
        "    ax.text(np.median(xy[m, 0]), np.median(xy[m, 1]), c,",
        "            fontsize=9, weight='bold')",
        "ax.set_xlabel(emb.upper() + '1'); ax.set_ylabel(emb.upper() + '2')",
        "ax.set_title('%s · %d clusters' % (key, len(cnt)))",
        "ax.legend(markerscale=3, fontsize=7, ncol=2, loc='best', frameon=False)",
        "savefig(fig, 'umap.png')",
        "a.write(out(NAME + '.h5ad'))",
        ""
      ))
    )
  ),

  # ---- 5. marker 基因 ---------------------------------------------------------
  sc_find_markers = list(
    title = "marker / 差异基因识别",
    env   = "scRNA",
    about = paste("按聚类标签在簇之间做差异检验，每个簇出 top N 个 marker。",
                  "用的是 scanpy 的 rank_genes_groups（默认 wilcoxon）。"),
    fields = list(
      fx_file("input", "输入 .h5ad（带聚类标签的）", exts = ".h5ad"),
      fx_txt("groupby", "按哪一列分组", "cluster"),
      fx_sel("method", "检验方法",
             c("wilcoxon" = "wilcoxon", "t-test" = "t-test",
               "logreg" = "logreg"), def = "wilcoxon"),
      fx_int("n_genes", "每个簇取前几个", 50),
      fx_sel("only_pos", "只要上调的",
             c("是" = "1", "否（上下调都要）" = "0"), def = "1"),
      fx_txt("name", "产物文件名（不含扩展名）", "markers")
    ),
    outputs = c("markers.csv", "markers_top.csv", "markers_heatmap.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import scanpy as sc",
        "a = sc.read_h5ad(P('input'))",
        "NAME = P('name', 'markers')",
        "gb = P('groupby', 'cluster')",
        "if gb not in a.obs.columns:",
        "    sys.exit('这一列不在数据里：' + gb + '；有的是：' +",
        "             ', '.join(map(str, a.obs.columns)))",
        "if 'log1p' not in a.uns:",
        "    say('提醒：这份数据看起来没做过 log1p 归一化，结果可能偏斜')",
        "sc.tl.rank_genes_groups(a, groupby=gb, method=P('method', 'wilcoxon'),",
        "                        pts=True)",
        "df = sc.get.rank_genes_groups_df(a, None)",
        "df.to_csv(out('markers.csv'), index=False)",
        "n = I('n_genes', 50)",
        "only = B('only_pos', True)",
        "top = df.groupby('group', group_keys=False).apply(",
        "    lambda d: (d[d['logfoldchanges'] > 0] if only else d).head(n))",
        "top.to_csv(out('markers_top.csv'), index=False)",
        "say('总表 %d 行，每簇前 %d 个已单独存一份' % (len(df), n))",
        "",
        "groups = list(a.obs[gb].astype(str).unique())",
        "genes = (top.sort_values('scores', ascending=False)['names']",
        "            .drop_duplicates().head(30).tolist())",
        "",
        "# ★★★ marker 的名字来自**做检验用的那个矩阵**，不一定是 `a` 自己。",
        "#    上游只要设过 `a.raw`（本仓的「标准化 + HVG」那一步就设了）再筛",
        "#    高变基因，`a.raw` 里是全部基因而 `a.var_names` 只剩高变的 —— 而",
        "#    rank_genes_groups 的 `use_raw` 默认是 None（= 有 raw 就用 raw），",
        "#    于是 df 里的名字全是 raw 的，拿 `a[细胞, 基因]` 去索引就 KeyError。",
        "#    实测踩到：norm.h5ad 的 var 300 个、raw.var 700 个，报的是",
        "#    「Values [G201, G670, …] are not valid obs/var names」。",
        "src = a.raw.to_adata() if a.raw is not None else a",
        "have = set(map(str, src.var_names))",
        "gs = [g for g in genes if str(g) in have]",
        "if len(gs) < 2:",
        "    src, have = a, set(map(str, a.var_names))",
        "    gs = [g for g in genes if str(g) in have]",
        "if len(gs) < 2:",
        "    say('能画热图的 marker 不足 2 个，跳过（表已经写好了）')",
        "else:",
        "    fig, ax = plt.subplots(figsize=(6.5, max(3.0, 0.22 * len(gs))))",
        "    M = np.zeros((len(gs), len(groups)))",
        "    for j, g in enumerate(groups):",
        "        m = (a.obs[gb].astype(str) == g).values",
        "        M[:, j] = np.asarray(src[m, gs].X.mean(axis=0)).ravel()",
        "    M = (M - M.mean(1, keepdims=True)) / (M.std(1, keepdims=True) + 1e-9)",
        "    im = ax.imshow(M, aspect='auto', cmap='RdBu_r', vmin=-2, vmax=2)",
        "    ax.set_xticks(range(len(groups))); ax.set_xticklabels(groups, rotation=90)",
        "    ax.set_yticks(range(len(gs))); ax.set_yticklabels(gs, fontsize=7)",
        "    ax.set_title('top markers（按簇标准化）')",
        "    fig.colorbar(im, ax=ax, shrink=0.6)",
        "    savefig(fig, 'markers_heatmap.png')",
        ""
      ))
    )
  ),

  # ---- 6. 组间差异 ------------------------------------------------------------
  sc_deg = list(
    title = "组间差异表达（两个条件之间）",
    env   = "scRNA",
    about = paste("挑一列分组（比如 treatment / stage）里的两组，做差异表达。",
                  "和 marker 那一步的区别：marker 是簇之间，这一步是你要比的两组之间。"),
    fields = list(
      fx_file("input", "输入 .h5ad", exts = ".h5ad"),
      fx_txt("groupby", "按哪一列分组", "group"),
      fx_txt("group_a", "实验组（名字要和数据里逐字一致）", ""),
      fx_txt("group_b", "对照组", ""),
      fx_sel("method", "检验方法",
             c("wilcoxon" = "wilcoxon", "t-test" = "t-test"),
             def = "wilcoxon"),
      fx_num("min_logfc", "logFC 阈值", 0.5),
      fx_num("max_p", "校正 p 阈值", 0.05),
      fx_txt("name", "产物文件名（不含扩展名）", "deg")
    ),
    outputs = c("deg.csv", "deg_sig.csv", "deg_volcano.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v),
      dsapp_cloudx_py(c(
        DSAPP_CLOUDX_PY_HEAD,
        "import scanpy as sc",
        "a = sc.read_h5ad(P('input'))",
        "NAME = P('name', 'deg')",
        "gb = P('groupby')",
        "A, Bg = P('group_a'), P('group_b')",
        "if gb not in a.obs.columns:",
        "    sys.exit('这一列不在数据里：' + gb)",
        "lv = [str(x) for x in a.obs[gb].astype(str).unique()]",
        "if not A or not Bg:",
        "    sys.exit('要指定两组。这一列里有：' + ', '.join(lv))",
        "for x in (A, Bg):",
        "    if x not in lv:",
        "        sys.exit('数据里没有这个组：' + x + '；有的是：' + ', '.join(lv))",
        "sub = a[a.obs[gb].astype(str).isin([A, Bg])].copy()",
        "sub.obs['_grp'] = sub.obs[gb].astype(str)",
        "sc.tl.rank_genes_groups(sub, groupby='_grp', groups=[A],",
        "                        reference=Bg, method=P('method', 'wilcoxon'))",
        "df = sc.get.rank_genes_groups_df(sub, group=A)",
        "df.to_csv(out('deg.csv'), index=False)",
        "lfc = F('min_logfc', 0.5); pth = F('max_p', 0.05)",
        "sig = df[(df['logfoldchanges'].abs() >= lfc) & (df['pvals_adj'] <= pth)]",
        "sig.to_csv(out('deg_sig.csv'), index=False)",
        "say('%s vs %s：显著 %d / 共 %d' % (A, Bg, len(sig), len(df)))",
        "",
        "fig, ax = plt.subplots(figsize=(5.2, 4.4))",
        "x = df['logfoldchanges'].values; y = -np.log10(np.clip(df['pvals_adj'], 1e-300, 1))",
        "is_sig = (np.abs(x) >= lfc) & (df['pvals_adj'].values <= pth)",
        "ax.scatter(x[~is_sig], y[~is_sig], s=4, c='#bab0ac')",
        "ax.scatter(x[is_sig], y[is_sig], s=5, c='#e45756')",
        "for _, r in sig.reindex(sig['scores'].abs().sort_values(ascending=False).index).head(8).iterrows():",
        "    ax.annotate(str(r['names']), (r['logfoldchanges'],",
        "                -np.log10(max(r['pvals_adj'], 1e-300))), fontsize=7)",
        "ax.axvline(lfc, ls='--', lw=.8, c='#888'); ax.axvline(-lfc, ls='--', lw=.8, c='#888')",
        "ax.axhline(-np.log10(pth), ls='--', lw=.8, c='#888')",
        "ax.set_xlabel('log2 fold change (%s / %s)' % (A, Bg))",
        "ax.set_ylabel('-log10 adj.p')",
        "savefig(fig, 'deg_volcano.png')",
        ""
      ))
    )
  )
)


# =============================================================================
# 五、TCGA / bulk 那一套（平台自带的 R）
# =============================================================================
# ⚠️ 这一套**只吃本地文件**：GDC 的下载（`tcga_download`）要联网、要几十 GB、
#    要挑队列挑组学层，那是另一个量级的事，本版**没有**接入执行体 ——
#    界面上会明说。这里四步是"数据已经在手上之后"最常走的那一段。
#
# 输入约定（界面上也写着）：一张矩阵表，**第一列是基因名，其余列是样本**；
# 生存表是 sample / time / status 三列（status 里 1=死亡 0=删失）。
DSAPP_CLOUDX_TCGA <- list(

  # ---- 1. 表达矩阵整理 --------------------------------------------------------
  tcga_expression = list(
    title = "表达矩阵整理 + ID 转换 + 肿瘤/正常配对",
    env   = "R",
    about = paste("读一张表达矩阵（行=基因，列=样本），去重、可选 log2、按 TCGA",
                  "条码后缀（-01 肿瘤 / -11 正常）标出样本类型，再出一张 PCA 和一张",
                  "分组箱线图。不是 TCGA 条码的样本，可以在下面用正则指定哪边是正常。"),
    fields = list(
      fx_file("input", "表达矩阵（csv/tsv/txt，第一列是基因名）", exts = c(".csv", ".tsv", ".txt", ".gz")),
      fx_sel("value_type", "这一列是什么值",
             c("原始 counts" = "counts", "TPM/FPKM" = "tpm", "已经 log2 过的" = "log2"),
             def = "tpm"),
      fx_sel("log2", "要不要 log2 转换",
             c("自动（counts/TPM 转，log2 值不转）" = "auto", "转" = "1",
               "不转" = "0"), def = "auto"),
      fx_sel("id_type", "行名是什么 ID",
             c("基因名（Symbol）" = "symbol", "Ensembl（ENSG…）" = "ensembl"),
             def = "symbol"),
      fx_txt("normal_pat", "正常样本的列名里含什么（留空 = 只认 TCGA 的 -11/-10）",
             ""),
      fx_txt("name", "产物文件名（不含扩展名）", "expr")
    ),
    outputs = c("expr_matrix.csv", "sample_types.csv", "expr_pca.png",
                "expr_boxplot.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v, rscript = TRUE),
      dsapp_cloudx_r(c(
        DSAPP_CLOUDX_R_HEAD,
        "f <- P('input'); need(f)",
        "d <- fread(f, data.table = FALSE, check.names = FALSE)",
        "if (ncol(d) < 3) die('这张表只有 ', ncol(d), ' 列，看着不像表达矩阵')",
        "g <- as.character(d[[1]])",
        "m <- as.matrix(d[, -1, drop = FALSE])",
        "rownames(m) <- g",
        "m <- m[!is.na(g) & nzchar(g), , drop = FALSE]",
        "say('读入 ', nrow(m), ' 个基因 × ', ncol(m), ' 个样本')",
        "",
        "# 同名基因取表达均值（用 rowsum 而不是 aggregate：快且不排序）",
        "if (anyDuplicated(rownames(m))) {",
        "  keep <- !is.na(rownames(m))",
        "  m <- m[keep, , drop = FALSE]",
        "  m <- rowsum(m, group = rownames(m)) / as.vector(table(rownames(m))[",
        "        unique(rownames(m))])",
        "  say('去重后 ', nrow(m), ' 个基因')",
        "}",
        "# ⚠️ 转数值**不要用 apply()**：apply 回来的时候 **dimnames 没了**（实测",
        "#    rownames 变成 NULL），于是最后 `data.frame(gene = rownames(m), m)`",
        "#    报「arguments imply differing number of rows: 0, 899」—— 报错点在",
        "#    write.csv 上，离真正的原因隔着三行。用 matrix() 重建，名字带过去。",
        "gn2 <- rownames(m)",
        "m <- matrix(suppressWarnings(as.numeric(m)), nrow = length(gn2),",
        "            dimnames = list(gn2, colnames(m)))",
        "if (anyNA(m)) {",
        "  m[is.na(m)] <- 0",
        "  say('⚠️ 表里有非数值单元格，已按 0 处理 —— 检查一下原始文件')",
        "}",
        "",
        "nm <- colnames(m)",
        "# ★ 样本类型：先认 TCGA 条码（第 4 段 = 01/11 那种），认不出再用正则",
        "pat <- P('normal_pat')",
        "st <- rep('tumor', length(nm))",
        "is_tcga <- grepl('^TCGA-[A-Z0-9]{2}-[A-Z0-9]{4}-[0-9]{2}', nm)",
        "if (any(is_tcga)) {",
        "  seg <- sub('^TCGA-[A-Z0-9]{2}-[A-Z0-9]{4}-([0-9]{2}).*$', '\\\\1', nm)",
        "  st[is_tcga] <- ifelse(as.integer(seg) >= 10, 'normal', 'tumor')",
        "  say('按 TCGA 条码标出：', sum(st == 'normal'), ' 正常 / ',",
        "      sum(st == 'tumor'), ' 肿瘤')",
        "}",
        "if (nzchar(pat)) {",
        "  hit <- grepl(pat, nm)",
        "  st[hit] <- 'normal'",
        "  say('按正则「', pat, '」追加标记：', sum(hit), ' 个正常样本')",
        "}",
        "if (!any(st == 'normal'))",
        "  say('⚠️ 一个正常样本都没标出来 —— 下面那张箱线图会只有一组')",
        "",
        "# log2：counts / TPM 转，已经是 log2 的不转（看最大值判）",
        "lg <- P('log2', 'auto')",
        "mx <- suppressWarnings(max(m, na.rm = TRUE))",
        "# ★ 「自动」= **信用户填的那个 value_type**，不拿最大值猜。",
        "#   一开始写的是「最大 > 50 才转」，实测当场就歪了：一张 TPM 矩阵",
        "#   最大值只有 23（基因少 / 低表达子集很常见）→ 不转 → 后面 limma 拿到的",
        "#   是线性值，而阈值是按 log2 填的，火山图上只剩一个基因显著 ——",
        "#   看着像「差异分析跑了但没结果」，其实是单位不一致。",
        "#   用户已经在那栏里明说了这是什么值，就按他说的办；只在**看着不像**的",
        "#   时候说一声（下面两句），并把出口（那一栏可以强制覆盖）写给他。",
        "vt <- P('value_type', 'tpm')",
        "do_log <- if (lg == '1') TRUE else if (lg == '0') FALSE else",
        "          vt %in% c('counts', 'tpm')",
        "if (lg == 'auto' && do_log && mx < 50)",
        "  say('⚠️ 最大值只有 ', round(mx, 1), '，但你说这是 ', vt,",
        "      ' —— 已按 log2(x+1) 处理。若它其实已经是 log2 值，把「要不要 log2」改成「不转」。')",
        "if (lg == 'auto' && !do_log && mx > 100)",
        "  say('⚠️ 最大值有 ', round(mx, 1), '，但你说这是 log2 值 —— 保持原值。',",
        "      '若它其实是 counts/TPM，把「要不要 log2」改成「转」。')",
        # ⚠️ `else` 必须和 `}` **同一行**：R 在行尾看到 `if (…) { … }` 就当成
        #    一整句收工了，下一行孤零零一个 `else` 是语法错误（实测报的是
        #    `unexpected 'else' in "else"`，而且脚本已经跑了一半才炸）。
        "if (do_log) { m <- log2(m + 1); say('已做 log2(x+1)')",
        "} else say('保持原值（最大值 ', round(mx, 1), '）')",
        "",
        "write.csv(data.frame(gene = rownames(m), m, check.names = FALSE),",
        "          out('expr_matrix.csv'), row.names = FALSE)",
        "write.csv(data.frame(sample = nm, type = st), out('sample_types.csv'),",
        "          row.names = FALSE)",
        "",
        "# ---- PCA（取方差最大的 2000 个基因）----",
        "v <- apply(m, 1, stats::var)",
        "top <- order(v, decreasing = TRUE)[seq_len(min(2000, length(v)))]",
        "x <- t(m[top, , drop = FALSE])",
        "x <- scale(x)",
        "x[!is.finite(x)] <- 0",
        "pc <- prcomp(x, center = FALSE, scale. = FALSE)",
        "pct <- round(100 * pc$sdev^2 / sum(pc$sdev^2), 1)",
        "png(out('expr_pca.png'), width = 900, height = 700, res = 130)",
        "cols <- ifelse(st == 'normal', '#4c78a8', '#e45756')",
        "plot(pc$x[, 1], pc$x[, 2], col = cols, pch = 19, cex = 1.1,",
        "     xlab = paste0('PC1 (', pct[1], '%)'),",
        "     ylab = paste0('PC2 (', pct[2], '%)'),",
        "     main = '样本 PCA（按类型着色）')",
        "legend('topright', legend = c('tumor', 'normal'),",
        "       col = c('#e45756', '#4c78a8'), pch = 19, bty = 'n')",
        "dev.off()",
        "",
        "# ---- 分组箱线图（看整体分布对不对）----",
        "png(out('expr_boxplot.png'), width = 1100, height = 700, res = 130)",
        "boxplot(m, las = 2, outline = FALSE, col = ifelse(st == 'normal',",
        "        '#4c78a8', '#e45756'), cex.axis = 0.5,",
        "        main = '每个样本的表达分布', ylab = 'expression')",
        "dev.off()",
        "say('产物：expr_matrix.csv / sample_types.csv / expr_pca.png / expr_boxplot.png')",
        ""
      ))
    )
  ),

  # ---- 2. 差异表达 ------------------------------------------------------------
  tcga_deg = list(
    title = "肿瘤 vs 正常 差异表达",
    env   = "R",
    about = paste("用 limma 在整理好的矩阵上做两组差异（也可以用 wilcoxon 做",
                  "不依赖分布假设的对照）。出 DEG 表、火山图、热图。"),
    fields = list(
      fx_file("expr", "表达矩阵（上一步的 expr_matrix.csv）"),
      fx_file("types", "样本类型表（上一步的 sample_types.csv）"),
      fx_sel("method", "方法",
             c("limma（推荐，需要 log2 后的值）" = "limma",
               "wilcoxon（不假设分布）" = "wilcoxon"), def = "limma"),
      fx_num("min_logfc", "|logFC| 阈值", 1),
      fx_num("max_p", "校正 p 阈值", 0.05),
      fx_txt("name", "产物文件名（不含扩展名）", "deg")
    ),
    outputs = c("deg.csv", "deg_sig.csv", "deg_volcano.png", "deg_heatmap.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v, rscript = TRUE),
      dsapp_cloudx_r(c(
        DSAPP_CLOUDX_R_HEAD,
        "d <- fread(P('expr'), data.table = FALSE, check.names = FALSE)",
        "g <- as.character(d[[1]]); m <- as.matrix(d[, -1, drop = FALSE])",
        "rownames(m) <- g; storage.mode(m) <- 'double'",
        "tp <- fread(P('types'), data.table = FALSE)",
        "if (!all(c('sample', 'type') %in% names(tp)))",
        "  die('类型表要有 sample 和 type 两列，现在是：',",
        "      paste(names(tp), collapse = ', '))",
        "i <- match(colnames(m), as.character(tp$sample))",
        "if (anyNA(i)) die('有 ', sum(is.na(i)), ' 个样本在类型表里找不到')",
        "grp <- factor(as.character(tp$type[i]), levels = c('normal', 'tumor'))",
        "if (nlevels(droplevels(grp)) < 2)",
        "  die('两组里只剩一组了 —— 检查 sample_types.csv')",
        "say('肿瘤 ', sum(grp == 'tumor'), ' / 正常 ', sum(grp == 'normal'))",
        "",
        "if (P('method', 'limma') == 'limma') {",
        "  need_pkg <- requireNamespace('limma', quietly = TRUE)",
        "  if (!need_pkg) die('这台机器上没装 limma')",
        "  des <- model.matrix(~ grp)",
        "  fit <- limma::lmFit(m, des)",
        "  fit <- limma::eBayes(fit)",
        "  tt <- limma::topTable(fit, coef = 2, number = Inf, sort.by = 'P')",
        "  res <- data.frame(gene = rownames(tt), logFC = tt$logFC,",
        "                    AveExpr = tt$AveExpr, p = tt$P.Value,",
        "                    p_adj = tt$adj.P.Val, row.names = NULL)",
        "} else {",
        "  a <- m[, grp == 'tumor', drop = FALSE]; b <- m[, grp == 'normal', drop = FALSE]",
        "  pv <- apply(m, 1, function(x) {",
        "    s <- suppressWarnings(stats::wilcox.test(x[grp == 'tumor'],",
        "                                             x[grp == 'normal'])$p.value)",
        "    if (is.na(s)) 1 else s })",
        "  lfc <- rowMeans(a) - rowMeans(b)",
        "  res <- data.frame(gene = rownames(m), logFC = lfc,",
        "                    AveExpr = rowMeans(m), p = pv,",
        "                    p_adj = stats::p.adjust(pv, 'BH'), row.names = NULL)",
        "}",
        "res <- res[order(res$p_adj, -abs(res$logFC)), ]",
        "write.csv(res, out('deg.csv'), row.names = FALSE)",
        "lfc <- F('min_logfc', 1); pth <- F('max_p', 0.05)",
        "sig <- res[abs(res$logFC) >= lfc & res$p_adj <= pth, ]",
        "write.csv(sig, out('deg_sig.csv'), row.names = FALSE)",
        "say('显著 ', nrow(sig), ' / 共 ', nrow(res), ' 个基因')",
        "",
        "png(out('deg_volcano.png'), width = 900, height = 750, res = 130)",
        "y <- -log10(pmax(res$p_adj, 1e-300))",
        "issig <- abs(res$logFC) >= lfc & res$p_adj <= pth",
        "plot(res$logFC, y, pch = 19, cex = 0.5,",
        "     col = ifelse(issig, '#e45756', '#bab0ac'),",
        "     xlab = 'log2 fold change (tumor / normal)',",
        "     ylab = '-log10 adj.p', main = '火山图')",
        "abline(v = c(-lfc, lfc), lty = 2, col = '#888')",
        "abline(h = -log10(pth), lty = 2, col = '#888')",
        "if (nrow(sig)) {",
        "  lab <- head(sig[order(-abs(sig$logFC)), ], 10)",
        "  text(lab$logFC, -log10(pmax(lab$p_adj, 1e-300)), lab$gene,",
        "       pos = 4, cex = 0.7)",
        "}",
        "dev.off()",
        "",
        "# 热图：显著的里面表达方差最大的 40 个",
        "if (nrow(sig) >= 2) {",
        "  s2 <- head(sig[order(-abs(sig$logFC)), ], 40)",
        "  mm <- m[s2$gene, , drop = FALSE]",
        "  mm <- t(scale(t(mm))); mm[!is.finite(mm)] <- 0",
        # ⚠️ 排序排的是**列**（样本），不是行（基因）：`grp` 是按样本走的，
        "#    写成 `mm[order(grp), ]` 是拿 65 个下标去索引 6 行的矩阵 ——",
        "#    报 `subscript out of bounds`，而它出现在 script 的最后一段。",
        "  o <- order(grp)",
        "  mm <- mm[, o, drop = FALSE]",
        "  png(out('deg_heatmap.png'), width = 1100, height = 900, res = 130)",
        "  heatmap(mm, Colv = NA, Rowv = NA, scale = 'none',",
        "          ColSideColors = ifelse(grp[o] == 'tumor',",
        "                                 '#e45756', '#4c78a8'),",
        "          labCol = FALSE, cexRow = 0.6, margins = c(4, 8),",
        "          main = 'top 差异基因（按样本类型排序）')",
        "  dev.off()",
        "} else say('显著基因不足 2 个，跳过热图')",
        ""
      ))
    )
  ),

  # ---- 3. Kaplan-Meier --------------------------------------------------------
  tcga_km = list(
    title = "Kaplan-Meier 生存曲线",
    env   = "R",
    about = paste("按一个基因（或一列打分）把样本分成高/低两组，画 KM 曲线并算",
                  "log-rank p。输入是表达矩阵 + 生存表（sample/time/status）。"),
    fields = list(
      fx_file("expr", "表达矩阵"),
      fx_file("clin", "生存表（sample / time / status 三列）"),
      fx_genes("genes", "基因（一个或多个，逗号或换行分隔）", "TP53"),
      fx_sel("split", "怎么分组",
             c("中位数" = "median", "上四分位 vs 下四分位" = "quartile",
               "最佳截断点（survminer）" = "cutpoint"), def = "median"),
      fx_sel("unit", "时间单位",
             c("天（自动转月）" = "day", "月" = "month", "年" = "year"),
             def = "day"),
      fx_int("width", "图宽（像素）", 1000)
    ),
    outputs = c("km_stats.csv", "km_<基因>.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v, rscript = TRUE),
      dsapp_cloudx_r(c(
        DSAPP_CLOUDX_R_HEAD,
        "for (p in c('survival', 'survminer'))",
        "  if (!requireNamespace(p, quietly = TRUE)) die('这台机器上没装 ', p)",
        "d <- fread(P('expr'), data.table = FALSE, check.names = FALSE)",
        "g <- as.character(d[[1]]); m <- as.matrix(d[, -1, drop = FALSE])",
        "rownames(m) <- g; storage.mode(m) <- 'double'",
        "cl <- fread(P('clin'), data.table = FALSE)",
        "nm <- tolower(names(cl))",
        "pick <- function(a) { j <- match(a, nm); if (is.na(j)) NA_integer_ else j }",
        "js <- pick('sample'); jt <- pick('time'); jv <- pick('status')",
        "if (anyNA(c(js, jt, jv)))",
        "  die('生存表要有 sample / time / status 三列，现在是：',",
        "      paste(names(cl), collapse = ', '))",
        "sm <- as.character(cl[[js]]); tt <- as.numeric(cl[[jt]])",
        "ev <- as.integer(cl[[jv]])",
        "u <- P('unit', 'day')",
        "if (u == 'day') tt <- tt / 30.44 else if (u == 'year') tt <- tt * 12",
        "ok <- !is.na(tt) & tt > 0 & !is.na(ev)",
        "say('可用样本 ', sum(ok), '（删失 ', sum(ev[ok] == 0), '）')",
        "",
        "gs <- trimws(unlist(strsplit(P('genes'), '[,\\\\s]+')))",
        "gs <- gs[nzchar(gs)]",
        "if (!length(gs)) die('没填基因名')",
        "miss <- setdiff(gs, rownames(m))",
        "if (length(miss)) say('⚠️ 矩阵里没有这些基因，跳过：', paste(miss, collapse = ', '))",
        "gs <- intersect(gs, rownames(m))",
        "if (!length(gs)) die('填的基因一个都不在矩阵里')",
        "",
        "stat <- list()",
        "for (gn in gs) {",
        "  x <- m[gn, ]",
        "  i <- match(sm, colnames(m))",
        "  df <- data.frame(time = tt, ev = ev, x = as.numeric(x[i]))",
        "  df <- df[ok & !is.na(df$x), ]",
        "  if (nrow(df) < 10) { say('⚠️ ', gn, ' 可用样本不足，跳过'); next }",
        "  sp <- P('split', 'median')",
        "  if (sp == 'quartile') {",
        "    q <- quantile(df$x, c(.25, .75))",
        "    df <- df[df$x <= q[1] | df$x >= q[2], ]",
        "    df$grp <- factor(ifelse(df$x >= q[2], 'High', 'Low'),",
        "                     levels = c('Low', 'High'))",
        "  } else {",
        "    df$grp <- factor(ifelse(df$x > median(df$x), 'High', 'Low'),",
        "                     levels = c('Low', 'High'))",
        "  }",
        "  fit <- survival::survfit(survival::Surv(time, ev) ~ grp, data = df)",
        "  dd <- survival::survdiff(survival::Surv(time, ev) ~ grp, data = df)",
        "  pv <- 1 - stats::pchisq(dd$chisq, length(dd$n) - 1)",
        "  hr <- NA_real_",
        "  cx <- tryCatch(survival::coxph(survival::Surv(time, ev) ~ grp, data = df),",
        "                 error = function(e) NULL)",
        "  if (!is.null(cx)) hr <- exp(stats::coef(cx))[[1]]",
        "  stat[[length(stat) + 1]] <- data.frame(",
        "    gene = gn, n = nrow(df), n_high = sum(df$grp == 'High'),",
        "    HR_high_vs_low = hr, logrank_p = pv)",
        "  pl <- survminer::ggsurvplot(fit, data = df, pval = TRUE, risk.table = TRUE,",
        "                              conf.int = TRUE,",
        "                              palette = c('#4c78a8', '#e45756'),",
        "                              legend.labs = c('Low', 'High'),",
        "                              title = paste0(gn, '（', sp, ' 分组）'),",
        "                              xlab = 'time (months)')",
        "  fn <- file.path(ROOT, paste0('km_', gsub('[^A-Za-z0-9_.-]', '_', gn), '.png'))",
        "  png(fn, width = I('width', 1000), height = 800, res = 130)",
        "  print(pl$plot); dev.off()",
        "  say('画好 ', basename(fn), '（p = ', signif(pv, 3), '）')",
        "}",
        "if (!length(stat)) die('一个基因都没画出来')",
        "s <- do.call(rbind, stat)",
        "write.csv(s, out('km_stats.csv'), row.names = FALSE)",
        "print(s)",
        ""
      ))
    )
  ),

  # ---- 4. 单因素 Cox ----------------------------------------------------------
  tcga_unicox = list(
    title = "单因素 Cox 初筛预后基因",
    env   = "R",
    about = paste("对一批基因逐个跑单因素 Cox，出 HR / 95%CI / p 和森林图。",
                  "不上传基因列表时，默认取表达方差最大的前 N 个基因 —— ",
                  "这一步通常是「LASSO 之前」的那一刀。"),
    fields = list(
      fx_file("expr", "表达矩阵"),
      fx_file("clin", "生存表（sample / time / status）"),
      fx_genes("genes", "基因列表（留空 = 取方差最大的前 N 个）", ""),
      fx_int("top_n", "留空时取多少个高变基因", 200),
      fx_num("p_cut", "p 阈值（只影响表里高亮，不删行）", 0.05),
      fx_sel("unit", "时间单位",
             c("天（自动转月）" = "day", "月" = "month", "年" = "year"),
             def = "day"),
      fx_int("forest_n", "森林图画前几个", 25)
    ),
    outputs = c("unicox.csv", "unicox_sig.csv", "unicox_forest.png"),
    script = function(v, ctx) c(
      dsapp_cloudx_head(ctx$root, ctx$env_dir, v, rscript = TRUE),
      dsapp_cloudx_r(c(
        DSAPP_CLOUDX_R_HEAD,
        "if (!requireNamespace('survival', quietly = TRUE)) die('没装 survival')",
        "d <- fread(P('expr'), data.table = FALSE, check.names = FALSE)",
        "g <- as.character(d[[1]]); m <- as.matrix(d[, -1, drop = FALSE])",
        "rownames(m) <- g; storage.mode(m) <- 'double'",
        "cl <- fread(P('clin'), data.table = FALSE); nm <- tolower(names(cl))",
        "js <- match('sample', nm); jt <- match('time', nm); jv <- match('status', nm)",
        "if (anyNA(c(js, jt, jv)))",
        "  die('生存表要有 sample / time / status 三列')",
        "sm <- as.character(cl[[js]]); tt <- as.numeric(cl[[jt]])",
        "ev <- as.integer(cl[[jv]]); u <- P('unit', 'day')",
        "if (u == 'day') tt <- tt / 30.44 else if (u == 'year') tt <- tt * 12",
        "ok <- !is.na(tt) & tt > 0 & !is.na(ev)",
        "i <- match(sm, colnames(m))",
        "ok <- ok & !is.na(i)",
        "say('可用样本 ', sum(ok))",
        "",
        "gs <- trimws(unlist(strsplit(P('genes'), '[,\\\\s]+')))",
        "gs <- gs[nzchar(gs)]",
        "if (!length(gs)) {",
        "  v <- apply(m[, i[ok], drop = FALSE], 1, stats::var)",
        "  gs <- names(sort(v, decreasing = TRUE))[seq_len(min(I('top_n', 200), length(v)))]",
        "  say('没给基因列表，取方差最大的前 ', length(gs), ' 个')",
        "} else {",
        "  miss <- setdiff(gs, rownames(m))",
        "  if (length(miss)) say('⚠️ 矩阵里没有：', paste(head(miss, 10), collapse = ', '))",
        "  gs <- intersect(gs, rownames(m))",
        "}",
        "if (!length(gs)) die('没有可分析的基因')",
        "",
        "res <- vector('list', length(gs)); k <- 0L",
        "for (gn in gs) {",
        "  x <- as.numeric(m[gn, i])",
        "  df <- data.frame(time = tt, ev = ev, x = x)[ok, ]",
        "  df <- df[stats::complete.cases(df), ]",
        "  if (nrow(df) < 10 || stats::sd(df$x) == 0) next",
        "  # 按中位数二分成高低表达（连续值直接进 Cox 也是合法的，但生信惯例",
        "  # 是二分 —— 而且二分的 HR 更好解释成「高表达组的风险倍数」）",
        "  df$g <- as.integer(df$x > stats::median(df$x))",
        "  fit <- tryCatch(survival::coxph(survival::Surv(time, ev) ~ g, data = df),",
        "                  error = function(e) NULL)",
        "  if (is.null(fit)) next",
        "  s <- summary(fit)",
        "  k <- k + 1L",
        "  res[[k]] <- data.frame(gene = gn, HR = s$conf.int[1, 'exp(coef)'],",
        "                         lo = s$conf.int[1, 'lower .95'],",
        "                         hi = s$conf.int[1, 'upper .95'],",
        "                         z = s$coefficients[1, 'z'],",
        "                         p = s$coefficients[1, 'Pr(>|z|)'],",
        "                         n = nrow(df))",
        "}",
        "if (!k) die('一个基因都没跑成')",
        "res <- do.call(rbind, res[seq_len(k)])",
        "res$p_adj <- stats::p.adjust(res$p, 'BH')",
        "res <- res[order(res$p), ]",
        "write.csv(res, out('unicox.csv'), row.names = FALSE)",
        "sig <- res[res$p < F('p_cut', 0.05), ]",
        "write.csv(sig, out('unicox_sig.csv'), row.names = FALSE)",
        "say('跑完 ', nrow(res), ' 个基因，其中 p < ', F('p_cut', 0.05), ' 的 ',",
        "    nrow(sig), ' 个')",
        "",
        "nf <- min(I('forest_n', 25), nrow(res))",
        "h <- res[seq_len(nf), ]",
        "png(out('unicox_forest.png'), width = 950, height = max(400, 26 * nf + 220),",
        "    res = 130)",
        "op <- graphics::par(mar = c(4, 9, 3, 2))",
        "plot(h$HR, nf:1, log = 'x', pch = 19, xlim = range(c(h$lo, h$hi, 1)),",
        "     yaxt = 'n', xlab = 'Hazard ratio（高表达 vs 低表达）', ylab = '',",
        "     main = paste0('单因素 Cox · p 最小的 ', nf, ' 个基因'))",
        "graphics::segments(h$lo, nf:1, h$hi, nf:1)",
        "graphics::abline(v = 1, lty = 2, col = '#888')",
        "graphics::axis(2, at = nf:1, labels = h$gene, las = 1, cex.axis = 0.65)",
        "graphics::par(op)",
        "dev.off()",
        ""
      ))
    )
  )
)


# =============================================================================
# 六、注册表本体 + 取用
# =============================================================================

#' 全部执行体
#'
#' ⚠️ **每次调用重建**（这些函数体不小，但都是闭包，不复制数据）。做成常量的话
#'    自检里想替换一个字段来试错就得去改全局变量，容易污染后面的断言。
dsapp_cloudx_all <- function() {
  list(sc = DSAPP_CLOUDX_SC, tcga = DSAPP_CLOUDX_TCGA)
}

#' 取一个工具的执行体
#'
#' @return list(...)；这个 key 没接执行体时返回 NULL（**不报错** ——
#'   "还没接"是一种正常状态，界面据此画那张「未接入执行体」的卡片）。
dsapp_cloudx_get <- function(kind, key) {
  k <- dsapp_cloudreg_kind(kind)
  ky <- trimws(as.character(key %||% "")[1])
  if (!nzchar(ky)) return(NULL)
  dsapp_cloudx_all()[[k]][[ky]]
}

#' 已接入执行体的 key（界面上一眼看出哪些能真跑）
dsapp_cloudx_keys <- function(kind) {
  k <- dsapp_cloudreg_kind(kind)
  names(dsapp_cloudx_all()[[k]])
}

#' 执行体和**文档注册表**对不上的那些 key
#'
#' ⚠️ 这个函数存在的唯一理由是**被断言**。写错一个字母的症状是"界面上那个
#'    工具永远点不到执行体"，没有报错、没有日志 —— 只有拿文档对撞才发现得了。
#'
#' @return list(missing = 在文档里、没接执行体的 key；
#'               extra   = 接了执行体、文档里没有的 key)
dsapp_cloudx_orphans <- function(kind, dir = NULL) {
  k <- dsapp_cloudreg_kind(kind)
  doc <- names(dsapp_cloudreg(k, dir = dir)$tools)
  mine <- dsapp_cloudx_keys(k)
  list(missing = setdiff(doc, mine), extra = setdiff(mine, doc))
}


# =============================================================================
# 七、参数表单 ↔ 界面（renderUI 那一侧调的就是这几个）
# =============================================================================

#' 文件下拉的候选 = 工作区里扫出来的 + 一个「手填」哨兵
#'
#' ⚠️ 这个哨兵**必须**由这一个函数产出。`dsapp_cloudx_field()` 建下拉时用它，
#'    上传完刷新下拉（`updateSelectInput`）时也要用它 —— 抄第二份就是两份
#'    会各自漂移的常量，而漂移的症状是"上传之后下拉里那个「手填」不见了"，
#'    或者更糟：更新时 `selected` 落在 choices 之外，selectize 静默清空控件
#'    （见 `dsapp_cloudx_pick_after_upload` 的说明）。
#'
#' ⚠️ 下拉里**永远留一个「手填」**：候选是从当前工作区扫出来的，而用户想用的
#'    文件可能是别的对话里的、或者路径太深扫不到。把选择限死在下拉里，他唯一
#'    的出路就变成了"先上传一份一模一样的"。
dsapp_cloudx_choices <- function(opts) {
  c(opts %||% character(0), "（手填下面的路径）" = "__manual__")
}

#' 把一个字段画成控件
#'
#' @param ns   模块的 ns
#' @param f    字段定义（上面 fx_* 造的）
#' @param opts 文件下拉的候选（`dsapp_cloudx_file_choices()` 给的）
#' @param hint 文件字段上传框旁边那句小字（一般是"单个文件上限 XX"）
dsapp_cloudx_field <- function(ns, f, opts = NULL, hint = NULL) {
  id <- ns(paste0("x_", f$id))
  lab <- f$label
  if (nzchar(f$help %||% "")) {
    lab <- tags$span(lab, tags$small(class = "text-muted", paste0("（", f$help, "）")))
  }
  switch(f$type,
    num = numericInput(id, lab, value = f$def, step = 0.1),
    int = numericInput(id, lab, value = f$def, step = 1),
    txt = textInput(id, lab, value = f$def),
    genes = textAreaInput(id, lab, value = f$def, rows = 2,
                          placeholder = "TP53, EGFR, KRAS（逗号或换行分隔）"),
    sel = selectInput(id, lab, choices = f$choices, selected = f$def),
    file = {
      fid <- f$id
      ch  <- dsapp_cloudx_choices(opts)
      tagList(
        selectInput(id, lab, choices = ch,
                    selected = if (f$def %in% ch) f$def else "__manual__"),
        textInput(ns(paste0("x_", fid, "_manual")), NULL, value = f$def,
                  placeholder = "也可以直接把路径粘在这里"),

        # ---- 上传（V16.7 item 4）--------------------------------------------
        #
        # ★ **两个** fileInput，不能合并成一个：
        #   `.dsapp-dirupload` 里的框会被 www/app.js 那个全局 shim 强行加上
        #   `webkitdirectory`，从此**只能选目录**。想同时支持"选单个文件"
        #   就必须另开一个普通的框（mod_skills.R 里踩过同一条）。
        #
        # ⚠️ `.dsapp-dirupload` 这个类名和 `data-paths-input` 这个属性名都是
        #    **功能性的，不是样式钩子** —— 它们在 www/app.js:1220-1292 里被
        #    querySelector 按字面量找。写错一个字母没有编译期检查、没有运行时
        #    检查，症状是"文件夹传上来了，只是全平铺在根目录，结构没了"。
        #    那条 shim 挂在 document 上、而且用 MutationObserver 盯 document.body，
        #    所以**这一页不用改 app.js 一行**它就能生效。
        #
        # ⚠️ 文件夹框要放在单文件框**前面**：本仓的拖拽处理器取的是
        #    `zone.querySelector('input[type="file"]')`（第一个）。云工具页现在
        #    没有拖拽区，但将来有人加一个时，这个顺序是"文件夹优先"的正确姿势。
        div(class = "dsapp-cloud-upload mt-1 mb-2",
          div(class = "dsapp-dirupload",
              `data-paths-input` = ns(paste0("x_", fid, "_dirpaths")),
              fileInput(ns(paste0("x_", fid, "_dir")), NULL,
                        multiple = TRUE, width = "100%",
                        buttonLabel = tagList(icon("folder-tree"), " 上传文件夹"),
                        placeholder = "还没选文件夹")),
          fileInput(ns(paste0("x_", fid, "_up")), NULL,
                    multiple = TRUE, width = "100%",
                    buttonLabel = tagList(icon("upload"), " 上传文件"),
                    placeholder = "还没选文件"),
          div(class = "text-muted small",
              "传上来的会存进「文件」页，并挂进当前对话的工作区，然后自动选中。",
              if (nzchar(hint %||% "")) paste0("（", hint, "）"))
        )
      )
    },
    textInput(id, lab, value = f$def)
  )
}

#' 所有内容为"文件"的字段 id（**按注册表枚举**）
#'
#' ⚠️ 不许硬编码。`fx_file()` 今天有四个 id（input / expr / types / clin），
#'    分属不同工具；界面上的上传观察者是按这个列表生成的，硬编码的话下次
#'    谁加一个字段，那个字段就**静默没有上传框** —— 不报错，只是没有。
#'    做成函数（而不是常量）的理由同 `dsapp_cloudx_all()`：自检里要能
#'    替换一个字段来试错。
dsapp_cloudx_file_ids <- function() {
  ids <- character(0)
  for (k in names(dsapp_cloudx_all())) {
    for (sp in dsapp_cloudx_all()[[k]]) {
      for (f in sp$fields) {
        if (identical(f$type, "file")) ids <- c(ids, f$id)
      }
    }
  }
  unique(ids)
}

#' 传完之后，下拉里该选中哪个值
#'
#' @param shared `dsapp_file_save()` 给出的相对共享区根路径（**也是**它们
#'   挂进工作区之后的相对路径 —— 见 `dsapp_mirror_into_ws()`）
#' @param mode   这个字段的 `fx_file(mode=)`：file / dir / any
#' @return 长度 1 的字符串；"" 表示没有可选的
dsapp_cloudx_pick_after_upload <- function(shared, mode = "file") {
  shared <- as.character(shared)
  shared <- shared[!is.na(shared) & nzchar(shared)]
  if (!length(shared)) return("")
  segs <- strsplit(shared, "/", fixed = TRUE)
  tops <- unique(vapply(segs, `[[`, character(1), 1L))

  # ① 单个文件（路径只有一段）→ 就选它
  if (length(shared) == 1L && length(segs[[1]]) == 1L) return(shared[[1]])

  # ② 一批文件 → 选最上层那个目录。10x 的三文件目录正是这个形状
  #    （sample1/{matrix.mtx,barcodes.tsv,features.tsv}），而 sc_read_data
  #    的 mode="any" 要的就是目录本身。
  if (length(tops) == 1L) {
    if (identical(as.character(mode)[1], "file")) {
      root_only <- shared[vapply(segs, length, integer(1)) == 2L &
                            vapply(segs, `[[`, character(1), 1L) == tops[[1]]]
      if (length(root_only) == 1L) return(root_only[[1]])
    }
    return(tops[[1]])
  }
  # ③ 跨目录（用户混选）→ 选第一个，让用户自己在下拉里改
  shared[[1]]
}

#' 从 input 里把一次运行的参数收齐
#'
#' ⚠️ 文件那一栏有**两个**控件（下拉 + 手填），这里的手填优先 —— 用户既然
#'    动手打了字，那就是他想要的；下拉只是省事的入口。
dsapp_cloudx_collect <- function(spec, input, ns_prefix = "x_") {
  vals <- list()
  for (f in spec$fields) {
    id <- paste0(ns_prefix, f$id)
    if (identical(f$type, "file")) {
      man <- input[[paste0(id, "_manual")]]
      sel <- input[[id]]
      v <- if (!is.null(man) && nzchar(trimws(as.character(man)))) as.character(man)
           else if (!is.null(sel) && !identical(as.character(sel), "__manual__"))
             as.character(sel)
           else as.character(f$def)
      vals[[f$id]] <- trimws(v)
    } else {
      v <- input[[id]]
      vals[[f$id]] <- if (is.null(v)) f$def else v
    }
  }
  dsapp_cloudx_flat(vals)
}

#' 一次运行前的体检
#'
#' ⚠️ 体检**不做**"路径存不存在"之外的判断（比如"这个文件是不是表达矩阵"）：
#'    判错的代价是拦掉一个本来能跑的运行，而用户完全无从绕过。
#'
#' @param ws 当前工作区 —— 文件下拉给的是**工作区相对路径**，不传这个就解不开
#'   （拿 `cfg$ws_root` 去拼是错的：那是所有工作区的**父目录**，拼出来的路径
#'   永远不存在，症状是"明明选了下拉里的文件，它说找不到"）。
#' @return list(ok, msg)
dsapp_cloudx_check <- function(spec, vals, cfg = dsapp_config(), ws = NULL) {
  env <- as.character(spec$env %||% "")[1]
  ed <- dsapp_cloudx_env_dir(env, cfg)
  if (is.na(ed)) return(list(ok = FALSE, msg = dsapp_cloudx_env_msg(env, cfg)))
  for (f in spec$fields) {
    if (!identical(f$type, "file") || !isTRUE(f$required)) next
    p <- vals[[f$id]] %||% ""
    if (!nzchar(p)) {
      return(list(ok = FALSE, msg = sprintf("「%s」还没选。", f$label)))
    }
    # 相对路径按工作区解（下拉里给的就是工作区相对路径）
    if (!grepl("^(/|[A-Za-z]:)", p)) p <- file.path(ws %||% "", p)
    if (!file.exists(p)) {
      return(list(ok = FALSE, msg = sprintf("找不到「%s」：%s", f$label, p)))
    }
  }
  list(ok = TRUE, msg = "")
}

#' 拼一次运行的目录名
#'
#' 沿用 panel 1 的口径（`<ws>/cloud/<名字>-<时间戳>`），产物才能被「文件」页
#' 和产物卡片看见。
dsapp_cloudx_run_root <- function(ws, kind, key, stamp = NULL) {
  dsapp_cloud_run_root(
    ws, list(job = paste0(dsapp_cloudreg_kind(kind), "-", key)), stamp)
}

#' 生成这次运行的完整 bash 代码（提交给执行引擎的就是它）
#'
#' @return list(ok, code, root, msg)
dsapp_cloudx_build <- function(kind, key, vals, ws, cfg = dsapp_config(),
                               stamp = NULL) {
  spec <- dsapp_cloudx_get(kind, key)
  if (is.null(spec)) return(list(ok = FALSE, msg = "这个工具还没有执行体"))
  chk <- dsapp_cloudx_check(spec, vals, cfg, ws)
  if (!isTRUE(chk$ok)) return(list(ok = FALSE, msg = chk$msg))
  root <- dsapp_cloudx_run_root(ws, kind, key, stamp)
  if (!dir.exists(root)) dir.create(root, recursive = TRUE, showWarnings = FALSE)
  env_dir <- dsapp_cloudx_env_dir(spec$env, cfg)
  # 文件字段解成**绝对路径**再交给脚本：脚本的 cwd 是运行目录，
  # 相对路径到那儿就指错了地方。
  vals2 <- vals
  for (f in spec$fields) {
    if (!identical(f$type, "file")) next
    p <- vals[[f$id]] %||% ""
    if (nzchar(p) && !grepl("^(/|[A-Za-z]:)", p)) {
      vals2[[f$id]] <- file.path(ws, p)
    }
  }
  code <- spec$script(vals2, list(root = root, ws = ws, env_dir = env_dir,
                                  cfg = cfg))
  list(ok = TRUE, code = paste(code, collapse = "\n"), root = root,
       spec = spec, msg = "")
}

#' 云工具页的一次上传：落共享区 → 登记归属 → 挂进工作区
#'
#' 用户的原话：「单细胞云工具里需要支持上传数据来进行分析」。落盘位置是
#' **「文件」页那个上传区**（`cfg$files_dir`，按账号隔离），然后再挂进当前
#' 对话的工作区 —— 前者是"我的数据在这里"，后者是"这个工具现在就能用它"。
#'
#' ★ 为什么镜像要**在这里**做掉、而不是等执行器：
#'   `dsapp_mirror_shared()` 全仓只有一个生产调用方（executor.R，执行代码时跑），
#'   而云工具是 `engine$start()` 直接提交任务的，**不走 executor** —— 传进共享区
#'   之后工作区里不会自己出现文件，而 `dsapp_cloudx_file_choices()` 只扫工作区，
#'   于是下拉里扫不到、`dsapp_cloudx_check()` 也解不开相对路径。用户会看到
#'   "传上去了，但选不到"。
#'
#' ★ 为什么不直接调 `dsapp_mirror_shared()`：它递归整个共享区（最深 8 层、
#'   可能上万文件），在交互路径上会卡死整页。这里点名挂几个就够。
#'
#' ★ 能这么写靠一条不变量：`dsapp_mirror_shared` 是把 `cfg$files_dir` **平移到
#'   工作区根**的，所以 `dsapp_file_save()` 返回的 `msg`（相对共享区根）
#'   **恰好等于**挂进工作区后的相对路径。返回结构里仍分 `shared` / `ws_rel`
#'   两个名字 —— 哪天镜像规则改成 `<ws>/upload/`，混用的三处（归属表、下拉、
#'   体检）会同时静默错位。
#'
#' @param upload `input$x_<fid>_up` / `_dir`（Shiny 给的 data.frame）
#' @param rels   浏览器报回来的相对路径，或 NULL（单文件框没有这一条）
#' @param con    `dsapp_db(...)`；测试里可以传一个临时库
#' @return list(ok, saved, shared, ws_rel, failed, select, msg)
#'   ⚠️ 字段一个都不许少：`sprintf("%s", NULL)` 给的是长度 0，界面上就是
#'      一句空白提示、测试里就是一条不打印名字的通过。
dsapp_cloudx_upload_apply <- function(upload, cfg = dsapp_config(),
                                      user_id = NULL, ws = NULL, rels = NULL,
                                      mode = "file", con = dsapp_db(cfg)) {
  res <- list(ok = FALSE, saved = character(0), shared = character(0),
              ws_rel = character(0), skipped = character(0),
              failed = character(0), select = "", msg = "")
  if (is.null(upload) || !NROW(upload)) { res$msg <- "没有收到文件"; return(res) }
  # ⚠️ 没有工作区就**落盘之前**拒绝：否则用户在「文件」页里凭空多出一堆
  #    文件，而他自己以为是在给这个工具传数据。
  if (is.null(ws) || length(ws) != 1L || is.na(ws) || !nzchar(ws)) {
    res$msg <- "先打开一个对话 —— 数据要挂进对话的工作区，云工具才选得到。"
    return(res)
  }
  rels <- dsapp_upload_rels(upload, rels)
  for (i in seq_len(NROW(upload))) {
    r <- dsapp_file_save(list(name = upload$name[i], datapath = upload$datapath[i]),
                         cfg, user_id = user_id, dir = "", rel = rels[[i]])
    if (!isTRUE(r$ok)) {
      res$failed <- c(res$failed, r$msg %||% upload$name[i]); next
    }
    res$saved  <- c(res$saved, r$name)
    res$shared <- c(res$shared, r$msg)
    # 登记归属。⚠️ 键必须是**相对路径**（r$msg），用 basename 的话子目录里的
    #    文件会登记成根目录下的一个名字 —— 查不到 = "无主" = 人人可删。
    #    ⚠️ 参数顺序是 (name, user_id, con)，见 users.R 里那段说明。
    #
    # ⚠️⚠️ `con` 写成**惰性默认参数**（`con = dsapp_db(cfg)`），不要写成
    #     `con = NULL` 再 `con %||% dsapp_db(cfg)`：`%||%` 碰到 S4 连接会
    #     在 `is.na(a[1])` 上抛，而调用点包着 try() → 异常被吞 → 归属**一行
    #     都不写**，函数却照样返回 TRUE。utils.R:47 就写着这条，别改回去。
    #     （2026-10-06 真踩了一次：file_owner 空表，而上传看着完全成功。）
    try(dsapp_file_owner_set(r$msg, user_id, con = con), silent = TRUE)
  }
  if (!length(res$shared)) { res$msg <- "一个都没存进去"; return(res) }
  m <- dsapp_mirror_into_ws(cfg, res$shared, ws, create = TRUE)
  res$ws_rel   <- c(m$placed, m$skipped)
  res$skipped  <- m$skipped
  res$failed   <- c(res$failed, m$failed)
  res$select <- dsapp_cloudx_pick_after_upload(res$shared, mode = mode)
  res$ok     <- length(res$ws_rel) > 0L
  res$msg    <- sprintf("已存 %d 个到「文件」页，%d 个挂进工作区%s",
                        length(res$saved), length(res$ws_rel),
                        if (length(res$failed))
                          sprintf("，%d 个没成", length(res$failed)) else "")
  res
}

#' 工作区里能当输入的文件/目录（给文件下拉用）
#'
#' ⚠️ 只扫**顶层 + 一层子目录**：工作区里可能有几万个文件（跑过任务的都知道），
#'    递归扫一遍会让这一页每次重画都卡住。要更深的路径就用手填那一栏。
dsapp_cloudx_file_choices <- function(ws, spec = NULL) {
  if (is.null(ws) || !dir.exists(ws)) return(character(0))
  rel <- character(0)
  top <- list.files(ws, all.files = FALSE, no.. = TRUE)
  top <- top[!startsWith(top, ".") & top != "cloud"]
  for (t in top) {
    p <- file.path(ws, t)
    if (dir.exists(p)) {
      sub <- list.files(p, all.files = FALSE, no.. = TRUE)
      sub <- sub[!startsWith(sub, ".")]
      rel <- c(rel, t, file.path(t, sub))
    } else {
      rel <- c(rel, t)
    }
  }
  # 最近改动的排前面：刚跑出来的产物就是下一步要选的输入
  rel <- unique(rel)
  mt <- vapply(rel, function(r) {
    as.numeric(suppressWarnings(file.mtime(file.path(ws, r))))[1]
  }, numeric(1))
  rel <- rel[order(mt, decreasing = TRUE, na.last = TRUE)]
  stats::setNames(rel, rel)
}
