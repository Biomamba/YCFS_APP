# =============================================================================
# 云工具：**跑在本机上的**自动化分析流水线（★ V15.8 item 2）
# =============================================================================
# 用户原话：「加一个云工具模块，第一个功能就是能够给这套流程的自动化分析提供
#           一个GUI，要求有流程的原理、功能介绍，让用户选好参数后可以直接运行、
#           收获结果并预览，并且能给用户提供进一步的建议」。
#
# 第一个工具是结合蛋白设计流水线：
#
#     RFdiffusion3 生成骨架 → ProteinMPNN/SolubleMPNN 设计序列
#       → RoseTTAFold3 复折叠 → evaluate_rf3.py 汇总指标 → 人工筛选
#
# 教学原文（`cloud_tool/RFdiffusion3+MPNN+RoseTTAFold 3的全流程教学_修订版_plus(2).html`）
# 里那四步是一条命令一条命令手敲的：conda activate、cd、mkdir、rfd3 design …、
# for file in …; do mpnn …; done、rf3 fold …、python evaluate_rf3.py …。
# 中间任何一步打错一个参数，症状都要等到几十分钟后看日志才知道。这一页把它们
# 收成一张表单 + 一个「开始运行」。
#
# -----------------------------------------------------------------------------
# 这一份文件里，"能算的"和"要连着界面的"是**分开**的（下面每个函数都标了）
# -----------------------------------------------------------------------------
# ⚠️⚠️ 这个仓库栽过两次「自检全绿 ≠ 功能被验过」。这一页最容易出的正是那一类：
#    参数拼错了、yaml 少一行、命令少一个参数 —— 这些**都不会让界面报错**，
#    只会让几十分钟后的任务失败。
#
#    所以凡是"输入参数 → 输出文本/判据"的东西一律写成**纯函数**（不碰 session、
#    不碰网络、只读磁盘上确实存在的东西），放在这个文件里，由
#    `tests/v158_cloudtool.R` 直接对着断言。界面那一层（mod_cloudtool.R）
#    只负责把控件值收起来、把纯函数的结果画出来。
#
#    ★ 判据：把这一页的"运行"按钮删掉，剩下的东西应该仍然全部可测。
#
# -----------------------------------------------------------------------------
# ★★ 为什么是**一步一个作业**，而不是一个大脚本跑到底
# -----------------------------------------------------------------------------
# 平台的执行器有一条墙钟（`cfg$exec$timeout`，默认 1800 秒 = 30 分钟，
# 见 R/executor.R 的 `p$wait(timeout = ...)`），到点**强杀整个进程组**。
# 这条线是全局的，不随账号走（每账号能设的只有 cpu/mem/procs，见
# `dsapp_limits_for_user()`）。
#
# 而这条流水线按教学原文的参数要跑几十分钟到几小时。所以：
#   · 拆成 4 个作业逐步提交，**每一步各有一次 30 分钟的额度**；
#   · 每一步的产物单独留下 → 界面上能看到"哪一步成了、哪一步没成"。
#
# ⚠️⚠️ 但"拆开"**不等于**"每一步都能续跑"，别把这两件事混成一句好话：
#   · RF3 带 `skip_existing=True`（教学 6.1 那张参数表里唯一一处），
#     重跑**真的**会跳过已经算完的输入；
#   · MPNN 是按骨架一个个调的，重跑会把每个骨架重算一遍（它便宜）；
#   · **RFD3 没有 skip_existing** —— 教学 4.2 那条命令里没有这个参数。
#     被墙钟打断之后重跑第 1 步，这一批是**从头再算**的。
#     所以第 1 步是这四步里唯一"超时=白烧机时"的一步，预检里专门有一条
#     墙钟提示盯着它（见 dsapp_cloud_preflight 的 wall 那一条）。
#
# ⚠️ 这和教学第 8 节说的做法是同一件事：「每一步检查退出状态和预期文件，
#    只有成功的结果才进入下一步；失败、早停和缺失输出的任务要单独保留，
#    便于重跑和统计」。一个几百行的 shell 一把梭反而做不到这一条。
#
# ⚠️ 一条出网请求都不会有。这一页只做两件事：在本机起子进程、读本机磁盘。
# =============================================================================


# =============================================================================
# 一、这台机器上有没有这套流程（探测）
# =============================================================================

#' 找 RFD3 那套工具链所在的 conda 环境
#'
#' 和 `dsapp_find_conda()` 同一个套路（见 R/config.R）：应用以服务身份运行，
#' PATH 里**没有**任何 conda 环境，所以不能靠 `Sys.which("rfd3")`。
#'
#' ⚠️⚠️ **为什么不走 `cfg$envs_root` 那一套**：平台的「环境」页只认
#'    `envs_root` **这一层**目录（`dsapp_envs_list()` 只 list 那一层），而这台
#'    机器上装好的 rfd3 环境在别人的 miniconda 下面，根本不在那棵树里。
#'    改 `envs_root` 是**全平台**的语义（所有账号"我能选哪些环境"都会变），
#'    为了一个页面去动它代价太大。所以这里自带一份候选清单，命中的那个目录
#'    由**生成的脚本自己**前置进 PATH（见 dsapp_cloud_step_script）。
#'
#' 优先级（一级比一级弱）：
#'   1. `DSAPP_RFD3_ENV` —— 运维显式指的，**永远优先**；
#'   2. `<envs_root>/rfd3` —— 管理员在「环境」页里建的那一个（推荐做法：
#'      它归运行身份所有，不依赖某个人的家目录权限）；
#'   3. 候选清单里的几个常见位置 —— 最后一条是**这台机器上实际装着的**
#'      那个（和 config.R 里 `/home/biomamba/miniconda3/bin/conda` 同一类
#'      注释：它是"这台部署的现状"，不是通例）。
#'
#' ⚠️ 判据是**目录 + bin/rfd3 可执行**，不是"目录在不在"：装到一半的环境
#'    目录是有的，`bin/` 里什么都没有。
#'
#' @return 命中的环境目录；一个都没有时返回 `""`（**不报错** —— "这台机器上
#'   没装"是一种正常状态，界面要据此显示"还没装"的引导，而不是弹一个错）。
dsapp_cloud_env_dir <- function(cfg = dsapp_config()) {
  cand <- c(
    Sys.getenv("DSAPP_RFD3_ENV", ""),
    file.path(cfg$envs_root, "rfd3"),
    "/opt/rfd3",
    "/usr/local/rfd3",
    # 这台机器上的现状（见上面第 3 条的说明）
    "/data1/home/wanjiale/miniconda3/envs/rfd3",
    file.path(Sys.getenv("HOME", ""), "miniconda3/envs/rfd3")
  )
  cand <- cand[nzchar(cand)]
  for (d in cand) {
    if (file.exists(file.path(d, "bin", "rfd3"))) return(d)
  }
  ""
}

#' 权重目录（foundry 的 checkpoints）
#'
#' 教学原文用的是 `foundry install base-models --checkpoint-dir ~/.foundry/checkpoints`，
#' 也就是**默认落在运行身份的家目录**。所以这里默认也按那个算，另外认
#' `DSAPP_FOUNDRY_CKPT`。
#'
#' ⚠️ 注意是**运行身份**的家目录，不是当前登录用户的 —— 用交互 shell 装到
#'    自己的 `~/.foundry` 下面，应用是看不见的。这是这一页最容易让人困惑的
#'    一条，所以界面上会把"它找的是哪个目录"**原样显示出来**。
dsapp_cloud_ckpt_dir <- function(cfg = dsapp_config()) {
  d <- Sys.getenv("DSAPP_FOUNDRY_CKPT", "")
  if (nzchar(d)) return(d)
  file.path(Sys.getenv("HOME", ""), ".foundry", "checkpoints")
}

#' 流水线要用到的四份权重（名字取自教学原文，一个字都不能改）
#'
#' ⚠️ 教学原文里这几个文件名是**互相配套**的：RFD3 的是 `rfd3_latest.ckpt`，
#'    MPNN 的是 `*_v_48_020.pt`（48 近邻 / 0.20 Å 骨架噪声），RF3 的是
#'    `rf3_foundry_01_24_latest_remapped.ckpt`。换来源或重新训练的权重需要连
#'    `--is_legacy_weights` 一起核对（教学 5.2 节专门写了这件事），所以这一页
#'    不提供"随便填个权重路径"的自由度 —— 名称对不上就是没装好，直说。
DSAPP_CLOUD_CKPT <- list(
  rfd3    = "rfd3_latest.ckpt",
  mpnn    = "proteinmpnn_v_48_020.pt",
  soluble = "solublempnn_v_48_020.pt",
  rf3     = "rf3_foundry_01_24_latest_remapped.ckpt"
)

#' 评估脚本（教学原文里那个 evaluate_rf3.py）在不在
#'
#' 它是**配套脚本**，不在 foundry 包里面，要另外拿。找这几处：
#'   · `DSAPP_CLOUD_SCRIPT_DIR`（运维放的）；
#'   · 应用目录下的 `tools/Protein_Design/`（**正本**，跟仓库一起走、
#'     也进版本归档）；
#'   · 应用目录下的 `cloud_tool/`（一份指向正本的软链，历史上先落在那里）；
#'   · 应用目录下的 `script/`。
#'
#' ⚠️ `tools/Protein_Design/` 必须留在候选表里，这一条不是"多找一个地方"：
#'    `cloud_tool/` 在 `history_Version/archive.sh` 的 SKIP 表里（那里原本只有
#'    一份 13 MB 的教学 HTML，不是应用本体）。**归档恢复出来的那份没有
#'    `cloud_tool/`** —— 只认那条软链的话，正本明明在归档里躺着，应用却说
#'    "评估脚本没放"。判据：拿一份归档起实例，预检里那一条要是绿的。
#'
#' @return 路径（不管在不在）—— 调用方拿它去 `file.exists()`，报错时也要把
#'   这个路径显示给用户（"放哪儿"才是他能动手的那一步）。
dsapp_cloud_eval_script <- function(cfg = dsapp_config()) {
  cand <- c(
    file.path(Sys.getenv("DSAPP_CLOUD_SCRIPT_DIR", ""), "evaluate_rf3.py"),
    file.path(cfg$app_dir, "tools", "Protein_Design", "evaluate_rf3.py"),
    file.path(cfg$app_dir, "cloud_tool", "evaluate_rf3.py"),
    file.path(cfg$app_dir, "script", "evaluate_rf3.py")
  )
  cand <- cand[nzchar(cand)]
  hit <- cand[file.exists(cand)]
  if (length(hit)) hit[[1]] else cand[[1]]
}


# =============================================================================
# 二、开跑之前的体检（**纯函数**）
# =============================================================================

#' 体检：把"跑不动"的每一条理由在**点按钮之前**摆出来
#'
#' 为什么非要有这一步：这套流程从点下去到出结果要几十分钟，而它最常见的失败
#' 是"环境里少一份权重"或"输入结构的路径写错了"——这两种都会在跑了几分钟
#' 之后才炸，报出来的还是 python 的堆栈。用户看完不知道自己该做什么。
#'
#' @param p 参数字典（`dsapp_cloud_defaults()` 的形状）
#' @param cfg 配置
#' @param user_id 账号 id（用来查 GPU 权限）；`NULL` = 不查这一项
#' @param gpu_ok 逻辑；`NULL` = 自己查，也可以由调用方传进来（便于测试）
#' @return `list(ok = <全部通过?>, items = list(list(key, label, ok, warn, detail, fix)))`
#'   —— `ok = FALSE` 的条目里，`fix` 是**用户/管理员该做什么**，一律写成
#'   一句可执行的话，不留"请联系管理员"这种没有信息量的兜底。
#'   `warn = TRUE` 是第三种状态：**能跑，但你得知道这件事**（目前只有墙钟
#'   那一条用它）—— 把它做成"不通过"会让预检永远红着，用户就学会无视它了。
dsapp_cloud_preflight <- function(p, cfg = dsapp_config(), user_id = NULL,
                                  gpu_ok = NULL) {
  items <- list()
  add <- function(key, label, ok, detail = "", fix = "", warn = FALSE) {
    items[[length(items) + 1L]] <<- list(key = key, label = label,
                                         ok = isTRUE(ok),
                                         warn = isTRUE(warn) && isTRUE(ok),
                                         detail = detail,
                                         fix = if (isTRUE(ok)) "" else fix)
  }

  # ---- 1. 工具链 ---------------------------------------------------------
  env_dir <- dsapp_cloud_env_dir(cfg)
  add("env", "RFD3 工具链（conda 环境）", nzchar(env_dir),
      if (nzchar(env_dir)) env_dir else "没找到",
      paste0("在「环境」页建一个叫 rfd3 的 conda 环境并装上 rc-foundry，",
             "或者由运维设 DSAPP_RFD3_ENV=<环境目录> 指过去。"))

  # ---- 2. 四份权重 -------------------------------------------------------
  ck <- dsapp_cloud_ckpt_dir(cfg)
  need <- unique(unlist(DSAPP_CLOUD_CKPT, use.names = FALSE))
  miss <- need[!file.exists(file.path(ck, need))]
  add("ckpt", "模型权重（4 份）", length(miss) == 0L,
      if (!length(miss)) ck else sprintf("%s 里缺：%s", ck,
                                         paste(miss, collapse = "、")),
      paste0("在装了 rc-foundry 的环境里跑 `foundry install base-models ",
             "--checkpoint-dir ", ck, "` 下载（几 GB，需要外网）。",
             "⚠️ 要用**运行身份**的家目录；用自己账号装到 ~/.foundry 下面",
             "应用是看不见的。"))

  # ---- 3. 输入结构 -------------------------------------------------------
  inp <- as.character(p$input %||% "")[1] %||% ""
  inp_ok <- nzchar(inp) && file.exists(inp)
  add("input", "靶点结构文件（PDB/CIF）", inp_ok,
      if (nzchar(inp)) inp else "还没选",
      "在「文件」页上传一份靶点结构（.pdb/.cif/.cif.gz），再回到这里选它。")

  # ---- 4. contig 与 length 相容 ------------------------------------------
  chk <- dsapp_cloud_contig_check(p$contig, p$length)
  add("contig", "contig 与 length 相容", chk$ok, chk$detail, chk$fix)

  # ---- 5. hotspot 格式 ---------------------------------------------------
  hs <- as.character(p$hotspots %||% "")[1] %||% ""
  hs_ok <- !nzchar(hs) || !is.null(dsapp_cloud_parse_hotspots(hs))
  add("hotspot", "热点写法", hs_ok,
      if (!nzchar(hs)) "（没写热点，RFD3 会自己找位置）" else hs,
      paste0("热点写成 `A39: CE1,OH` 这样：链名 + 残基号，冒号后面是原子名；",
             "多个热点之间用分号隔开。原子名必须和结构文件里**逐字相同**。"))

  # ---- 6. 评估脚本 -------------------------------------------------------
  sc <- dsapp_cloud_eval_script(cfg)
  add("script", "评估脚本 evaluate_rf3.py", file.exists(sc), sc,
      paste0("把配套的 evaluate_rf3.py 放到 ", dirname(sc),
             "（它不在 foundry 包里，要单独拿）。"))

  # ---- 7. GPU 权限 -------------------------------------------------------
  # ⚠️ 三种状态要分开（V14 item 7 定的）：这台机器没卡 / 有卡但这个账号没被
  #    放行 / 有卡且放行。前两种都跑不了，但**该做什么**完全不同 ——
  #    混成一句"GPU 不可用"会让人去找管理员，而机器上根本没有卡。
  hg <- tryCatch(dsapp_host_gpu(),
                 error = function(e) list(ok = FALSE, kind = "none", detail = ""))
  if (!isTRUE(hg$ok)) {
    add("gpu", "GPU", FALSE, hg$detail %||% "这台机器上没有检测到 GPU",
        paste0("这套流程必须用 GPU（RFD3/RF3 都是扩散模型），CPU 上跑不动。",
               "请运维在服务器上装好显卡驱动和 CUDA。"))
  } else {
    ga <- gpu_ok
    if (is.null(ga)) {
      ga <- if (is.null(user_id)) NA
            else tryCatch(dsapp_gpu_allowed(user_id, cfg = cfg),
                          error = function(e) NA)
    }
    add("gpu", "GPU 使用权限", isTRUE(ga),
        as.character(hg$detail %||% ""),
        paste0("这个账号还没被放行用卡。请管理员在「后台管理 → 资源与文件 → ",
               "可调用硬件资源」里把卡开给该账号（每账号一个开关，没设过时",
               "跟着平台默认 DSAPP_EXEC_GPU 走）。"))
  }

  # ---- 8. 墙钟（**提示，不是拦路**）---------------------------------------
  # 平台的执行器有一次执行的墙钟上限（`cfg$exec$timeout`，默认 1800 秒），
  # 到点强杀。而第 1 步（RFD3）是四步里唯一**没有续跑能力**的一步。
  #
  # ⚠️ 不把它做成"不通过"：这四步里前三步都可能合法地接近上限，而红着一条
  #    永远修不好的预检，用户两天就学会无视整张表了。这里只把数字摆出来，
  #    让他自己决定要不要先跑「快速试跑」。
  n_plan <- dsapp_cloud_int(p$n_batches) * dsapp_cloud_int(p$diffusion_batch_size)
  wall   <- as.numeric(cfg$exec$timeout %||% 1800)
  # 教学原文的实测速度：50 个骨架约 10 分钟（4.2 节）。按这个线性估。
  #
  # ⚠️ 阈值取 **0.8** 太晚了：这个线性估计很粗（50 个/10 分钟是教学那台卡上
  #    的数字，换卡就变），而第 1 步**没有续跑** —— 真的撞上墙钟就是白烧。
  #    所以估计值超过额度一半就提示。"生产批量"那档（100 个骨架 ≈ 20 分钟）
  #    落在 30 分钟额度的一半以上 → 会亮，而"教学示例"（50 个 ≈ 10 分钟）不亮。
  est <- n_plan / 50 * 10
  add("wall", "单步时间上限", TRUE,
      sprintf("平台每次执行最多 %d 分钟。这一步计划生成 %d 个骨架，按教学示例的速度（50 个约 10 分钟）估计约 %.0f 分钟。",
              as.integer(wall / 60), n_plan, est),
      warn = est > wall / 60 * 0.5)

  list(ok = all(vapply(items, function(x) x$ok, logical(1))), items = items)
}


# =============================================================================
# 三、参数（**纯函数**）
# =============================================================================

#' 一键预设
#'
#' 教学原文那套参数是"跑一次十分钟、出 50 个骨架"的，直接拿来当默认值的话，
#' 第一次点按钮的人要等十分钟才知道自己参数填错了。所以给三档：
#'
#'   · 快速试跑 —— 1×1，几分钟内能看出"环境通不通"，**只出 1 个骨架**；
#'   · 教学示例 —— 教学原文那套（PD-L1，25×2 = 50 个骨架，约 10 分钟）；
#'   · 生产批量 —— 骨架数和一个骨架的序列数都拉满。
#'
#' ⚠️ 三档之间的差别**只在数量**（n_batches / diffusion_batch_size / mpnn_seq），
#'    采样参数（step_scale / gamma_0 / num_steps / n_recycles）三档一样 ——
#'    那些是"结果长什么样"的开关，不是"跑多久"的开关。把它们跟着数量一起改，
#'    用户就没法用"快速试跑"预判生产档的行为了。
DSAPP_CLOUD_PRESETS <- list(
  quick = list(
    label = "快速试跑",
    note  = paste0("1 个骨架、1 条序列，几分钟。用来确认这条流程在这台机器上",
                   "跑得通，不是用来筛候选的。"),
    n_batches = 1L, diffusion_batch_size = 1L, mpnn_seq = 1L
  ),
  teaching = list(
    label = "教学示例",
    note  = paste0("教学原文那套（PD-L1 靶点）：25×2 = 50 个骨架、每个骨架 ",
                   "1 条序列，约 10 分钟。"),
    n_batches = 25L, diffusion_batch_size = 2L, mpnn_seq = 1L
  ),
  production = list(
    label = "生产批量",
    note  = paste0("100 个骨架、每个骨架 6 条序列（两套 MPNN 各 3 条）—— ",
                   "跑之前先确认卡空着。"),
    n_batches = 50L, diffusion_batch_size = 2L, mpnn_seq = 3L
  )
)

#' 参数的默认值（= 「教学示例」那一档 + 教学原文的采样参数）
#'
#' ⚠️ 默认的 contig / length / hotspot 取的是**教学原文那个 PD-L1 例子**，它
#'    绑死在特定的输入结构上（`A` 链是靶点、`A39` 的 CE1/OH 是热点）。
#'    换靶点必须**整套换掉** —— 换了一半（比如只改 hotspot 不改 contig）会
#'    在 RFD3 预检查或采样时失败，而那时已经过去好几分钟了。
dsapp_cloud_defaults <- function() {
  pr <- DSAPP_CLOUD_PRESETS$teaching
  list(
    preset     = "teaching",
    job        = "pdl1_binder",
    input      = "",
    contig     = "70-90,/0,A18-132",
    length     = "180-210",
    hotspots   = "A39: CE1,OH",
    # RFD3 采样（教学 4.2：低温采样组合，提高可设计性、牺牲多样性）
    step_scale = 3,
    gamma_0    = 0.2,
    n_batches  = pr$n_batches,
    diffusion_batch_size = pr$diffusion_batch_size,
    non_loopy  = TRUE,
    # MPNN
    use_mpnn    = TRUE,
    use_soluble = TRUE,
    mpnn_seq    = pr$mpnn_seq,
    omit_cys    = TRUE,
    # RF3
    num_steps  = 50L,
    n_recycles = 10L,
    rf3_batch  = 1L,
    es_plddt   = 0.5,
    # 筛选线（**只是观察线**，见 dsapp_cloud_advise 里那段说明）
    ipae_cut   = 10,
    iptm_cut   = 0.6,
    plddt_cut  = 70
  )
}

#' 套用一档预设（只动数量那三个键，其余原样保留）
dsapp_cloud_apply_preset <- function(p, key) {
  pr <- DSAPP_CLOUD_PRESETS[[key]]
  if (is.null(pr)) return(p)
  p$preset <- key
  p$n_batches <- pr$n_batches
  p$diffusion_batch_size <- pr$diffusion_batch_size
  p$mpnn_seq <- pr$mpnn_seq
  p
}

#' contig 与 length 相容吗（**纯函数**，吃字符串吐判据）
#'
#' 规则（教学 4.2 节，逐条对着那张 contig 说明表写的）：
#'   · contig 里**没有链名**的那一段（如 `70-90`）= 从头生成，就是 binder；
#'   · 带链名的片段（如 `A18-132`）= 从输入结构里保留的靶点部分；
#'   · `/0` = 断开成独立链（不建肽键）；
#'   · `length` 是**整条复合物**的总长 = binder + 所有保留片段。
#'
#' 判据是**两个区间有交集**，不是"上下限谁大谁小"—— 教学原文专门写了这一条
#' （`length: 680-820` 那个例子里固定部分是 569，加上 120-250 的 binder 得到
#' 689-819，和 680-820 有交集）。
#'
#' @return `list(ok, detail, fix, fixed_lo, fixed_hi, binder_lo, binder_hi)`
dsapp_cloud_contig_check <- function(contig, length_spec) {
  no <- function(detail, fix) {
    list(ok = FALSE, detail = detail, fix = fix,
         fixed_lo = NA_integer_, fixed_hi = NA_integer_,
         binder_lo = NA_integer_, binder_hi = NA_integer_)
  }
  cg <- trimws(as.character(contig %||% "")[1] %||% "")
  if (!nzchar(cg)) {
    return(no("contig 是空的", "填一个 contig，例如 70-90,/0,A18-132"))
  }

  rng <- dsapp_cloud_parse_range(length_spec)
  if (is.null(rng)) {
    return(no(sprintf("length 读不出来：[%s]", length_spec),
              "length 写成 180-210 这样（一个区间）。"))
  }

  parts <- trimws(strsplit(cg, ",", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  fix_lo <- 0L; fix_hi <- 0L; b_lo <- 0L; b_hi <- 0L
  for (p in parts) {
    if (identical(p, "/0")) next
    # 片段 = 可选链名 + 起 + 可选的止。
    #
    # ⚠️⚠️ 两个坑，都是"改完看着更对、其实静默走样"的那种：
    #   1. 链名那一类**不能**写 `[A-Za-z0-9_]`：那样 `70-90` 会被解析成
    #      "链 7、残基 0"，于是 binder 段被当成固定段，总长算出来是另一个数
    #      —— 不报错，只是判据变成假的。链名只收字母/下划线（PDB 的链 ID
    #      也就是这种），数字留给残基号。
    #   2. **不要**用 `(?:...)` / `+?` 这些 Perl 写法：`regexec` 默认走 POSIX
    #      ERE，它们不被当成分组/懒惰量词，捕获组的下标会整体错位
    #      （实测 `(?:-([0-9]+))?` 会让第 4 组变成 `-90`，把减号也吃进去）。
    #      所以这里只用普通括号，并且把下标**对着实测结果**写死。
    m <- regmatches(p, regexec("^([A-Za-z_]+)?([0-9]+)(-([0-9]+))?$", p))[[1]]
    if (!length(m)) {
      return(no(sprintf("contig 里这一段读不出来：[%s]", p),
                paste0("每一段写成 `70-90`（新链）或 `A18-132`（保留靶点）；",
                       "链名写字母，链之间用 /0 断开。")))
    }
    lo <- as.integer(m[[3]]); hi <- if (nzchar(m[[5]])) as.integer(m[[5]]) else lo
    if (is.na(lo) || is.na(hi) || hi < lo) {
      return(no(sprintf("contig 里这一段起止反了：[%s]", p),
                "把小的数写在前面。"))
    }
    # ⚠️⚠️ 两种片段对总长的贡献**不是一回事**，混了会把区间算歪：
    #   · 带链名的（`A18-132`）= 从输入结构里保留的固定片段，贡献的是**个数**
    #     （132-18+1 = 115），上下限加同一个数；
    #   · 不带链名的（`120-250`）= 从头生成的 binder，它自己就是一个**区间**，
    #     贡献的是 120..250 —— 不是"131 个"。
    #
    #   教学原文那个例子就是这么算的：固定部分 569、binder 120-250 →
    #   总长 689-819。写成"个数"的话会得到 569+131 = 700 一个点，
    #   而 `length: 680-820` 那条**相容**判据就会被误判（该过的过不了）。
    n <- hi - lo + 1L
    if (nzchar(m[[2]])) { fix_lo <- fix_lo + n;  fix_hi <- fix_hi + n }
    else                { b_lo <- b_lo + lo;     b_hi <- b_hi + hi }
  }

  lo <- fix_lo + b_lo; hi <- fix_hi + b_hi
  ok <- lo <= rng[[2]] && rng[[1]] <= hi
  list(ok = ok,
       detail = sprintf("contig 推出总长 %d-%d，length 要的是 %d-%d",
                        lo, hi, rng[[1]], rng[[2]]),
       fix = if (ok) "" else sprintf(
         "把 length 改成和 %d-%d 有交集的区间（例如 %d-%d），或者改 contig。",
         lo, hi, lo, hi),
       fixed_lo = fix_lo, fixed_hi = fix_hi, binder_lo = b_lo, binder_hi = b_hi)
}

#' 读一个区间：`"180-210"` / `"180"` / 180 / c(180,210) → c(lo, hi)
#'
#' 读不出来返回 NULL（调用方据此报"这一格填错了"）。
dsapp_cloud_parse_range <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  if (is.numeric(x) && length(x) >= 2) {
    v <- sort(as.integer(x[1:2])); return(c(v[[1]], v[[2]]))
  }
  # ⚠️ 分隔符先**归一化**再匹配，不写成 `([-~到])?` 那种一类里塞几种的写法：
  #    教学里 `length` 是人手敲的，`180-210` / `180~210` / `180 到 210` 都可能
  #    出现，而空白和全角字符在 POSIX 字符类里的行为跟 locale 有关（这个应用
  #    跑在什么 locale 下不由我们决定）。先去掉空白、把 `~`/`到` 换成 `-`，
  #    剩下的就是一个**只有 ASCII 和基本正则**的判据。
  s <- gsub("[[:space:]]+", "", trimws(as.character(x)[1] %||% ""))
  s <- gsub("[~到]", "-", s)
  if (!nzchar(s) || !grepl("^[0-9]+(-[0-9]+)?$", s)) return(NULL)
  v <- suppressWarnings(as.integer(strsplit(s, "-", fixed = TRUE)[[1]]))
  if (length(v) < 1L || anyNA(v)) return(NULL)
  lo <- v[[1L]]; hi <- if (length(v) > 1L) v[[2L]] else v[[1L]]
  if (hi < lo) return(NULL)
  c(lo, hi)
}

#' 解析热点写法：`"A39: CE1,OH"` → data.frame(chain, res, atoms)
#'
#' 认的写法（教学 4.1.1 / 4.2 用的是第一种）：
#'   `A39: CE1,OH`        链 + 残基号，冒号后面是原子名
#'   `A39:CE1,OH`         冒号后面不空格也行
#'   `B128: NZ`           只给一个原子
#'
#' ⚠️ 返回 `NULL` 表示**读不出来**（界面要报错），返回 0 行的 data.frame
#'    表示"没写热点"（合法：RFD3 会自己找位置）。这两件事不能混 —— 混了的话
#'    "用户写错了"会变成"静默地不用热点跑一遍"，那是最坏的一种失败。
#'
#' ⚠️ 为什么在这里解析而不是直接拼进 yaml：教学 4.1.1 专门警告过"原子名称
#'    必须与 PDB 中的名称完全一致"，而写错原子名要到 RFD3 预检查才报错，
#'    报的还是"找不到这个原子"（不会说是哪一行写错了）。解析一遍至少能把
#'    **用户看到的**和**写进 yaml 的**摆在一起给他核对。
dsapp_cloud_parse_hotspots <- function(txt) {
  s <- trimws(paste(as.character(txt %||% ""), collapse = " "))
  if (!nzchar(s)) {
    return(data.frame(chain = character(), res = integer(),
                      atoms = character(), stringsAsFactors = FALSE))
  }
  # 先按分号/换行切成一组，**不能**直接按逗号切 —— 原子名之间也是逗号
  #（`A39: CE1,OH` 里那个逗号是在**同一个**热点里面）。
  grp <- unlist(strsplit(s, "[;\n]+"))
  grp <- trimws(grp[nzchar(trimws(grp))])
  out <- list()
  for (g in grp) {
    # 链名只收字母/下划线，理由同 dsapp_cloud_contig_check 里那两条 ⚠️：
    # 把数字放进链名那一类，`A39` 会被解析成"链 A3、残基 9"。
    m <- regmatches(g, regexec(
      "^([A-Za-z_]+)([0-9]+)[[:space:]]*:[[:space:]]*([A-Za-z0-9,]+)$", g))[[1]]
    if (!length(m)) return(NULL)
    atoms <- trimws(strsplit(m[[4]], ",", fixed = TRUE)[[1]])
    atoms <- atoms[nzchar(atoms)]
    if (!length(atoms)) return(NULL)
    out[[length(out) + 1L]] <- data.frame(
      chain = m[[2]], res = as.integer(m[[3]]),
      atoms = paste(atoms, collapse = ","), stringsAsFactors = FALSE)
  }
  do.call(rbind, out)
}

#' 把参数拼成 RFD3 的输入 YAML（**纯函数**）
#'
#' 逐字对着教学 4.1 那份 `pdl1_rfd3.yaml` 的形状：
#'
#'     pdl1_rfd3:
#'         input: /path/PDL1.pdb
#'         contig: 70-90,/0,A18-132
#'         length: 180-210
#'         select_hotspots:
#'             A39: CE1,OH
#'         infer_ori_strategy: hotspots
#'         is_non_loopy: true
#'
#' ⚠️ 缩进是 **4 个空格**，`select_hotspots:` 下面再缩 4 格 —— hydra/omegaconf
#'    对缩进敏感，缩错了报的是 "Could not parse"，而它不会告诉你是哪一行。
#'
#' @param p 参数
#' @param input 覆盖 `input:` 那一行。**必须**给：脚本会把靶点结构**拷进**
#'   这次的运行目录，yaml 要指向那份拷贝 —— 指向用户原来的路径的话，
#'   他过后挪一下文件（或者从「文件」页删掉），续跑就找不到输入了，
#'   而报错会是 RFD3 那边的"文件不存在"。
dsapp_cloud_yaml <- function(p, input = NULL) {
  job <- dsapp_cloud_slug(p$job)
  inp <- as.character(input %||% p$input %||% "")[1] %||% ""
  cg  <- trimws(as.character(p$contig %||% "")[1] %||% "")
  ln  <- trimws(as.character(p$length %||% "")[1] %||% "")
  hs  <- dsapp_cloud_parse_hotspots(p$hotspots)

  lines <- c(
    "# 由「云工具」页生成（Test_V15.8）。改动请在页面上改，然后重新运行。",
    sprintf("%s:", job),
    sprintf("    input: %s", inp),
    sprintf("    contig: %s", cg),
    sprintf("    length: %s", ln)
  )
  if (!is.null(hs) && nrow(hs) > 0) {
    lines <- c(lines, "    select_hotspots:")
    for (i in seq_len(nrow(hs))) {
      lines <- c(lines, sprintf("        %s%s: %s", hs$chain[[i]], hs$res[[i]],
                                hs$atoms[[i]]))
    }
  }
  c(lines,
    "    infer_ori_strategy: hotspots",
    sprintf("    is_non_loopy: %s",
            if (isTRUE(p$non_loopy %||% TRUE)) "true" else "false"),
    "")
}

#' 任务名 → 能进文件名和目录名的 slug（**纯函数**）
#'
#' ⚠️ 任务名会变成**输出文件名的一部分**（教学原文：`pdl1_rfd3_pd1s_0_model_0`）
#'    和输出目录名。里面出现 `/`、空格、`..` 的时候，轻则文件名奇怪，重则
#'    写到别的目录去。所以一律收成 `[A-Za-z0-9_.-]`，别的字符换成 `_`。
dsapp_cloud_slug <- function(x, default = "design") {
  s <- trimws(as.character(x %||% "")[1] %||% "")
  if (!nzchar(s)) return(default)
  s <- gsub("[^A-Za-z0-9_.-]+", "_", s)
  s <- gsub("^[._]+", "", s)
  if (!nzchar(s)) default else substr(s, 1L, 64L)
}

#' MPNN 的 `--omit` 参数值（**纯函数**）
#'
#' ⚠️ 这是**一个 JSON 数组**当字符串传，不是逗号分隔的列表 ——
#'    教学原文写的是 `--omit '["CYS"]'`。去掉半胱氨酸是教学里的设计选择
#'    （原文：对需要二硫键的设计不适用），所以做成一格开关而不是写死。
#'    注意它只限制**设计位点**的可选氨基酸，不会去动受体里原有的半胱氨酸。
dsapp_cloud_omit_json <- function(p) {
  if (!isTRUE(p$omit_cys %||% TRUE)) return("[]")
  "[\"CYS\"]"
}

#' MPNN 的设计链（**纯函数**，目前是写死的 "A"）
#'
#' 教学 5.3 节：「`--designed_chains "A"` 指定只设计 A 链……本次 RFD3 输出中
#' A 链是 Binder，B 链是受体」。也就是说 **A=设计链这件事是 RFD3 输出的性质**，
#' 不是用户可以随便挑的：RFD3 总是把新生成的 binder 放在最前面那条链，
#' 保留的靶点跟在后面。
#'
#' ⚠️ 所以这里**不**给用户一格自由度。做成可填的话，填错（比如填成 B）的
#'    症状是"跑完全程、指标全是垃圾"—— 受体被重新设计、binder 反而固定，
#'    而 CSV 上不会有任何一行提示这件事。这一格在界面上是**只读展示**。
dsapp_cloud_designed_chain <- function() "A"


#' 数字转字符串（**纯函数**）：3 → "3"，0.2 → "0.2"
#'
#' ⚠️ 绝不出现 `3e+00` 这种写法：hydra 的命令行覆盖参数**不认**科学计数法，
#'    而 `as.character(1e5)` 给的就是 `"1e+05"`。所以走 format 再去掉空格。
dsapp_cloud_num <- function(x, default = "0") {
  if (is.null(x) || !length(x)) return(default)
  v <- suppressWarnings(as.numeric(x[[1]]))
  if (is.na(v)) return(default)
  gsub("\\s+", "", format(v, scientific = FALSE, trim = TRUE))
}

#' 整数那一类的参数（**纯函数**）：夹到 >= 1
dsapp_cloud_int <- function(x, default = 1L) {
  v <- suppressWarnings(as.integer(x %||% default))
  if (is.na(v) || v < 1L) as.integer(default) else v
}


# =============================================================================
# 四、把参数变成命令（**纯函数**）
# =============================================================================
# 拆成 4 步，每步一个作业（理由见文件头）。每一步的脚本都用
#   echo 'STEP <key> BEGIN'  …  echo 'STEP <key> END'
# 包着；界面侧的进度直接读作业的实时日志（工作区里的 .dsapp_stdout），
# **不另外造一套状态** —— 造了就会和真实执行对不上。
#
# ⚠️ 每一步做完都要**数产物**，数不够就 die。不能只看退出码：
#    rfd3/mpnn 有时候退出码 0 但一个产物都没写（通配符没匹配到文件时 bash 会把
#    `*.cif` 原样传下去，见教学 5.1 节那段提醒），那样脚本会带着一个**空目录**
#    往下跑，最后报出来的是"后面某一步失败"，把真正的原因盖掉了。

#' 这次运行的步骤表（顺序 = 执行顺序）
#'
#' @return 每个元素 `list(key, n, label, what)`。
dsapp_cloud_steps <- function(p) {
  uses <- dsapp_cloud_models_on(p)
  list(
    list(key = "rfd3", n = 1L, label = "生成骨架（RFdiffusion3）",
         what = sprintf("按 contig 生成 %d 个 binder 骨架",
                        dsapp_cloud_int(p$n_batches) *
                          dsapp_cloud_int(p$diffusion_batch_size))),
    list(key = "mpnn", n = 2L,
         label = sprintf("设计序列（%s）",
                         paste(vapply(uses, function(u) u$tag, character(1)),
                               collapse = " + ")),
         what = sprintf("每个骨架设计 %d 条序列",
                        dsapp_cloud_int(p$mpnn_seq))),
    list(key = "rf3", n = 3L, label = "复折叠（RoseTTAFold3）",
         what = "用设计出来的序列重新预测复合物结构，拿 ipae / ipTM / pLDDT"),
    list(key = "eval", n = 4L, label = "汇总指标",
         what = "算每个候选的 ipae、双向 ipae、RMSD、ipTM、pLDDT，写成 CSV")
  )
}

#' 这一步开哪几套 MPNN（**纯函数**）
dsapp_cloud_models_on <- function(p) {
  out <- list()
  if (isTRUE(p$use_mpnn %||% TRUE)) {
    out[[length(out) + 1L]] <- list(key = "mpnn", dir = "1", tag = "ProteinMPNN",
                                    ckpt = DSAPP_CLOUD_CKPT$mpnn)
  }
  if (isTRUE(p$use_soluble %||% TRUE)) {
    out[[length(out) + 1L]] <- list(key = "soluble", dir = "2",
                                    tag = "SolubleMPNN",
                                    ckpt = DSAPP_CLOUD_CKPT$soluble)
  }
  out
}

#' 一次运行的目录布局（**纯函数**）—— 测试和界面都拿它当唯一口径
#'
#' 布局跟着教学原文走（`rfd3/outputs/1`、`mpnn/1`、`rf3/1`、`ProteinMPNN.csv`），
#' 这样从这一页跑出来的目录和用户照教学手敲出来的**长得一样**，
#' 出问题时可以拿教学里的命令对着这个目录直接重跑。
dsapp_cloud_layout <- function(root, p) {
  list(
    root = root,
    inputs = file.path(root, "rfd3", "inputs"),
    yaml   = file.path(root, "rfd3", "inputs",
                       paste0(dsapp_cloud_slug(p$job), ".yaml")),
    rfd3   = file.path(root, "rfd3", "outputs", "1"),
    mpnn   = file.path(root, "mpnn"),
    rf3    = file.path(root, "rf3")
  )
}

#' 某一套 MPNN 的输出目录 / 对应的 RF3 目录 / 对应的 CSV 前缀
dsapp_cloud_model_dirs <- function(root, p, u) {
  list(
    mpnn = file.path(root, "mpnn", u$dir),
    rf3  = file.path(root, "rf3", u$dir),
    csv  = file.path(root, paste0(u$tag, ".csv"))
  )
}

#' 生成某一步的 bash 脚本（**纯函数**）
#'
#' @param step "rfd3" / "mpnn" / "rf3" / "eval"
#' @param p 参数
#' @param root 这一次运行的根目录
#' @param env_dir 工具链环境目录（会被前置进 PATH）
#' @param ckpt_dir 权重目录
#' @param eval_py 评估脚本
#' @return 一个字符向量，每项一行
dsapp_cloud_step_script <- function(step, p, root, env_dir, ckpt_dir, eval_py) {
  lay  <- dsapp_cloud_layout(root, p)
  uses <- dsapp_cloud_models_on(p)
  seqs <- dsapp_cloud_int(p$mpnn_seq)
  q <- function(x) shQuote(as.character(x))
  # 四步共用的开头。⚠️ 这里的 `die()` 特意把"重跑这一步即可"写进**给用户看的
  # 那句话**里 —— 墙钟到点被杀、或者中途断电，看到的都是这一行，
  # 而这时候他最需要知道的是"已经算出来的没白算"。
  head <- c(
    "#!/bin/bash",
    "# 由「云工具」页生成（Test_V15.8 item 2）。**不要手改** —— 改了不会同步回界面。",
    "set -u",
    "# ⚠️ 刻意**不用** `set -e`：每一步的失败要自己判（下面的 die 和数产物），",
    "#    因为 rfd3/mpnn 有时候退出码是 0 但一个产物都没写。",
    "",
    sprintf("ROOT=%s", q(root)),
    sprintf("export PATH=%s:$PATH", q(file.path(env_dir, "bin"))),
    "# CUDA_VISIBLE_DEVICES 由平台按账号放行后注入，这里**不动它** ——",
    "# 在多卡机上写死 \"0\" 等于替用户挑了一张卡，而教学 8 节专门提醒过",
    "# \"多卡的显存不会自动合并\"。",
    "",
    "say() { echo \"[$(date +%H:%M:%S)] $*\"; }",
    paste0("die() { echo \"!! $*\"; ",
           "echo '!! 这一步没跑完。修好之后重跑这一步：RF3 会跳过已经算出来的",
           "（skip_existing），RFD3 这一批要重算。'; exit 3; }"),
    "count_files() { ls -1 \"$1\" 2>/dev/null | grep -cE \"\\.(cif|pdb)(\\.gz)?$\"; }",
    ""
  )

  if (identical(step, "rfd3")) {
    src <- as.character(p$input %||% "")[1] %||% ""
    base <- basename(src)
    dst  <- file.path(lay$inputs, base)
    yml  <- dsapp_cloud_yaml(p, input = dst)
    return(c(head,
      "echo 'STEP rfd3 BEGIN'",
      "say '准备目录与输入 YAML'",
      sprintf("mkdir -p %s %s", q(lay$inputs), q(lay$rfd3)),
      # 输入结构**拷进运行目录**：这次运行从此自洽，原文件挪走也不影响续跑
      #（yaml 里写的就是这份拷贝的路径，见 dsapp_cloud_yaml 的 @param input）。
      sprintf("cp -f %s %s/ || die '拷不动输入结构（检查路径和读权限）'",
              q(src), q(lay$inputs)),
      # YAML 用 heredoc 写进运行目录。分隔符**带引号**（'DSAPP_YAML'）→
      # bash 不做变量展开和命令替换，路径里有 $ 或反引号也原样落地。
      sprintf("cat > %s <<'DSAPP_YAML'", q(lay$yaml)),
      yml,
      "DSAPP_YAML",
      sprintf("say 'RFD3 开始（%d 批 × %d 个 = 计划 %d 个骨架）'",
              dsapp_cloud_int(p$n_batches),
              dsapp_cloud_int(p$diffusion_batch_size),
              dsapp_cloud_int(p$n_batches) * dsapp_cloud_int(p$diffusion_batch_size)),
      sprintf("rfd3 design out_dir=%s ckpt_path=%s inputs=%s \\",
              q(lay$rfd3), q(file.path(ckpt_dir, DSAPP_CLOUD_CKPT$rfd3)),
              q(lay$yaml)),
      sprintf("    inference_sampler.step_scale=%s inference_sampler.gamma_0=%s \\",
              dsapp_cloud_num(p$step_scale, "3"),
              dsapp_cloud_num(p$gamma_0, "0.2")),
      sprintf("    n_batches=%d diffusion_batch_size=%d || die 'RFD3 退出码非 0（看上面的日志）'",
              dsapp_cloud_int(p$n_batches),
              dsapp_cloud_int(p$diffusion_batch_size)),
      # 输出可能是 .cif，也可能是 .cif.gz（教学 4.1.2：要 gunzip 一次）。
      sprintf("gunzip -f %s/*.gz 2>/dev/null || true", q(lay$rfd3)),
      sprintf("N=$(count_files %s)", q(lay$rfd3)),
      "say \"RFD3 产出骨架 $N 个\"",
      paste0("[ \"$N\" -ge 1 ] || die 'RFD3 没写出任何结构。常见原因：",
             "contig/hotspot 和输入结构对不上、权重路径不对。'"),
      "echo 'STEP rfd3 END'",
      ""))
  }

  if (identical(step, "mpnn")) {
    dirs <- vapply(uses, function(u) q(file.path(lay$mpnn, u$dir)), character(1))
    L <- c(head,
      "echo 'STEP mpnn BEGIN'",
      sprintf("mkdir -p %s", paste(dirs, collapse = " ")),
      # 先确认上一步真的留下了骨架。⚠️ 不确认的话，通配符没匹配到时 bash 会把
      # `*.cif` 这个**字面量**原样交给 mpnn，它去读一个叫 "*.cif" 的文件 ——
      # 报出来的错和"文件不存在"长得完全不像（教学 5.1 节提醒过这一条）。
      sprintf("D=$(ls -1 %s/*.cif 2>/dev/null | wc -l)", q(lay$rfd3)),
      "say \"输入骨架 $D 个\"",
      "[ \"$D\" -ge 1 ] || die '第 1 步的骨架不在，先跑第 1 步'",
      "")
    for (u in uses) {
      d <- file.path(lay$mpnn, u$dir)
      L <- c(L,
        sprintf("say '%s 开始（每个骨架 %d 条序列）'", u$tag, seqs),
        sprintf("for f in %s/*.cif; do", q(lay$rfd3)),
        "  [ -e \"$f\" ] || break",
        "  say \"  $(basename \"$f\")\"",
        "  mpnn --model_type \"protein_mpnn\" \\",
        "    --structure_path \"$f\" \\",
        sprintf("    --out_directory %s \\", q(d)),
        sprintf("    --batch_size 1 --number_of_batches %d \\", seqs),
        sprintf("    --omit '%s' \\", dsapp_cloud_omit_json(p)),
        "    --is_legacy_weights \"True\" \\",
        # ⚠️ 这里用**双引号**而不是 shQuote()：shQuote 在 Unix 上给的是单引号
        #    （`'A'`），跑起来一样对，但用户拿这一行去和教学原文逐字对照时会
        #    看到一处"不一样"，然后开始怀疑别的行。值是 dsapp_cloud_designed_chain()
        #    返回的固定字面量（"A"），不含任何 shell 元字符。
        sprintf("    --designed_chains \"%s\" \\", dsapp_cloud_designed_chain()),
        sprintf("    --checkpoint_path %s || die '%s 在 %s 上失败'",
                q(file.path(ckpt_dir, u$ckpt)), u$tag, "$(basename \"$f\")"),
        "done",
        sprintf("N=$(ls -1 %s/*.fa 2>/dev/null | wc -l)", q(d)),
        sprintf("say '%s 产出序列文件 $N 个'", u$tag),
        sprintf("[ \"$N\" -ge 1 ] || die '%s 一条序列都没写出来'", u$tag),
        "")
    }
    return(c(L, "echo 'STEP mpnn END'", ""))
  }

  if (identical(step, "rf3")) {
    L <- c(head, "echo 'STEP rf3 BEGIN'", "")
    for (u in uses) {
      md <- dsapp_cloud_model_dirs(root, p, u)
      L <- c(L,
        sprintf("mkdir -p %s", q(md$rf3)),
        sprintf("say 'RF3 开始（输入 %s）'", basename(md$mpnn)),
        "rf3 fold \\",
        sprintf("    inputs=%s \\", q(md$mpnn)),
        sprintf("    ckpt_path=%s \\",
                q(file.path(ckpt_dir, DSAPP_CLOUD_CKPT$rf3))),
        sprintf("    out_dir=%s \\", q(md$rf3)),
        sprintf("    diffusion_batch_size=%d \\", dsapp_cloud_int(p$rf3_batch)),
        sprintf("    num_steps=%d \\", dsapp_cloud_int(p$num_steps, 50L)),
        sprintf("    n_recycles=%d \\", dsapp_cloud_int(p$n_recycles, 10L)),
        sprintf("    early_stopping_plddt_threshold=%s \\",
                dsapp_cloud_num(p$es_plddt, "0.5")),
        "    skip_existing=True \\",
        "    annotate_b_factor_with_plddt=True || die 'RF3 失败（看上面的日志）'",
        # ⚠️ 早停掉的输入**没有**预测结构（教学 6.2 那条 early_stopping 说明），
        #    所以成功数可以少于输入数。这里只要求"至少有一个"，并把差额
        #    如实说给用户听 —— 把早停数藏起来的话，他会以为是自己跑挂了。
        sprintf("N=$(find %s -name '*_model.cif' 2>/dev/null | wc -l)", q(md$rf3)),
        sprintf("M=$(ls -1 %s/*.fa 2>/dev/null | wc -l)", q(md$mpnn)),
        "say \"RF3 产出预测结构 $N 个（输入 $M 条序列；差值是早停掉的）\"",
        "[ \"$N\" -ge 1 ] || die 'RF3 一个预测结构都没写出来'",
        "")
    }
    return(c(L, "echo 'STEP rf3 END'", ""))
  }

  if (identical(step, "eval")) {
    L <- c(head, "echo 'STEP eval BEGIN'", "")
    for (u in uses) {
      md <- dsapp_cloud_model_dirs(root, p, u)
      L <- c(L,
        sprintf("say '汇总 %s'", u$tag),
        # ⚠️ 只传教学原文里出现过的那三个参数（--rf3-dir / --rfd3-dir /
        #    --csv-prefix），一个都不多传。汇总脚本不在这个仓库里，凭空多传
        #    一个它不认的 flag，argparse 会**直接退出** —— 而那要等到前面
        #    三步都跑完才发生（几十块钱的机时之后）。
        sprintf("python %s --rf3-dir %s --rfd3-dir %s --csv-prefix %s || \\",
                q(eval_py), q(md$rf3), q(lay$rfd3),
                q(sub("\\.csv$", "", md$csv))),
        "  say '（汇总脚本返回非 0：有设计算不出指标。CSV 仍然会写出来，看 notes 列）'",
        # 教学 7 节：出现部分失败时脚本**仍然写出 CSV** 并返回 1，
        # 所以判据是"CSV 在不在"，不是退出码。
        sprintf("[ -f %s ] || die '汇总脚本没写出 CSV（看上面的日志）'", q(md$csv)),
        sprintf("say '写出 %s'", basename(md$csv)),
        "")
    }
    return(c(L, "echo 'STEP eval END'", ""))
  }

  stop("未知的步骤：", step)
}


# =============================================================================
# 五、收获结果（**纯函数**）
# =============================================================================

#' 收集这一次运行的结果表
#'
#' 读第 4 步写出来的那两个 CSV（ProteinMPNN.csv / SolubleMPNN.csv），合并成
#' 一张表，每行加一列 `source` 说明它来自哪套权重。
#'
#' ⚠️⚠️ **空白值不能当 0**（教学 7 节专门写的这一条）。第 4 步的 `status` 列
#'    有三种：`ok`（指标齐全）、`partial`（部分指标算不出）、`error`（结构读取
#'    或链选择失败）。后两种的指标列是**空的**，`read.csv` 读进来是 NA ——
#'    如果哪里写一句 `ipae >= 0` 或者把 NA 填成 0，`error` 的行会以"ipae = 0"
#'    的姿态排在**排行榜第一名**。所以下面所有比较都用 `!is.na(x) & x <= cut`。
#'
#' @return `list(ok, msg, df, files, n_ok, n_partial, n_error)`
dsapp_cloud_harvest <- function(root, p = dsapp_cloud_defaults()) {
  uses <- dsapp_cloud_models_on(p)
  files <- vapply(uses, function(u)
    dsapp_cloud_model_dirs(root, p, u)$csv, character(1))
  have <- files[file.exists(files)]
  if (!length(have)) {
    return(list(ok = FALSE, df = NULL, files = files,
                msg = "还没有汇总结果（第 4 步没跑完）",
                n_ok = 0L, n_partial = 0L, n_error = 0L))
  }

  parts <- list()
  for (f in have) {
    d <- tryCatch(utils::read.csv(f, stringsAsFactors = FALSE,
                                  check.names = FALSE),
                  error = function(e) NULL)
    if (is.null(d) || !nrow(d)) next
    d$source <- sub("\\.csv$", "", basename(f))
    parts[[length(parts) + 1L]] <- d
  }
  if (!length(parts)) {
    return(list(ok = FALSE, df = NULL, files = files,
                msg = "CSV 在，但一行都没读出来（文件可能是空的）",
                n_ok = 0L, n_partial = 0L, n_error = 0L))
  }

  # ⚠️ 两套权重的列可能不完全一样（某一份里全是 partial、某些列压根没写），
  #    直接 rbind 会报 "numbers of columns of arguments do not match" ——
  #    而那会发生在"用户已经等了半小时、正要收货"的那一刻。先补齐成并集。
  all_cols <- unique(unlist(lapply(parts, names)))
  for (i in seq_along(parts)) {
    miss <- setdiff(all_cols, names(parts[[i]]))
    for (m in miss) parts[[i]][[m]] <- NA
  }
  df <- do.call(rbind, lapply(parts, function(a) a[all_cols]))

  for (col in c("ipae", "ipae_row_receptor_col_binder",
                "ipae_row_binder_col_receptor", "receptor_rmsd",
                "binder_rmsd_receptor_aligned", "iptm",
                "receptor_plddt", "binder_plddt")) {
    if (col %in% names(df)) {
      df[[col]] <- suppressWarnings(as.numeric(df[[col]]))
    }
  }
  st <- if ("status" %in% names(df)) tolower(trimws(as.character(df$status)))
        else rep("", nrow(df))
  st[is.na(st)] <- ""

  list(ok = TRUE, df = df, files = files, msg = "",
       n_ok = sum(st == "ok"), n_partial = sum(st == "partial"),
       n_error = sum(st == "error"))
}

#' 按 ipae 排序（NA 永远排在最后）
#'
#' ⚠️ `order()` 默认把 NA 放**最后**是 FALSE —— 它会 `na.last = TRUE` 时才放
#'    最后，不写就是 TRUE？不：`order(..., na.last = TRUE)` 才是最后，
#'    而默认确实是 `na.last = TRUE`。这里**显式写出来**，因为这一条的取值
#'    决定了"算不出指标的行"是排在最前面（看着像最好的候选）还是最后面。
dsapp_cloud_rank <- function(df) {
  if (is.null(df) || !nrow(df)) return(df)
  v <- if ("ipae" %in% names(df)) df$ipae else rep(NA_real_, nrow(df))
  df[order(v, na.last = TRUE), , drop = FALSE]
}

#' 按筛选线给每一行打勾（**纯函数**）
#'
#' ⚠️⚠️ 三条线都**只是观察线**，不是已经验证过的实验成功阈值 ——
#'    教学 7 节的原话：「可以把 10 Å 暂时作为这次流程的观察线……但它并非已经
#'    针对 RF3 验证的通用实验成功阈值」；ipTM/pLDDT 那两档也是照抄 AlphaFold
#'    的通用参考区间，原文强调「不能当作 RF3 已验证的固定门槛」。
#'    界面上必须把这句话和数字一起显示，否则用户会拿它当录取线用。
#'
#' @return 逻辑向量（长度 = nrow(df)）；任一指标缺失（NA）就是 FALSE ——
#'   **算不出来 ≠ 通过**。
dsapp_cloud_pass <- function(df, p = dsapp_cloud_defaults()) {
  n <- nrow(df)
  if (is.null(df) || !n) return(logical(0))
  ok <- rep(TRUE, n)
  pick <- function(col) if (col %in% names(df)) df[[col]] else rep(NA_real_, n)
  ipae <- pick("ipae"); iptm <- pick("iptm"); pld <- pick("binder_plddt")
  ok <- ok & !is.na(ipae) & ipae <= as.numeric(p$ipae_cut %||% 10)
  ok <- ok & !is.na(iptm) & iptm >= as.numeric(p$iptm_cut %||% 0.6)
  ok <- ok & !is.na(pld)  & pld  >= as.numeric(p$plddt_cut %||% 70)
  ok
}

#' 给用户下一步的建议（**纯函数**）
#'
#' 用户原话里的最后一条要求就是「能给用户提供进一步的建议」。这里的每一条
#' 都对着教学第 7/8/9 节，不自己编：
#'
#'   · 通过数按"靶点、采样、序列设计、筛选定义"四个变量解释 —— 原文明确写了
#'     "这次记录不足以给出通用的 1% 至 10% 通过率"，所以不给通过率预期；
#'   · 哪一项卡住了就指哪一项（ipae 高 = 界面姿态不确定；ipTM 低 = 姿态缺支持；
#'     binder pLDDT 低 = binder 自己没折叠好）—— 这是教学 7 节那张表的读法；
#'   · 后续工作按第 9 节那张表给（界面检查与对接 / MD / 结合与特异性实验 /
#'     位点与功能验证），并带上那句最重要的提醒：**结合 PD-L1 不等于阻断
#'     PD-1/PD-L1**。
#'
#' @return `list(lines = <给界面逐条画的字符串>, n_pass, best, crit = <每条通过数>)`
dsapp_cloud_advise <- function(h, p = dsapp_cloud_defaults()) {
  if (is.null(h) || !isTRUE(h$ok) || is.null(h$df) || !nrow(h$df)) {
    return(list(lines = character(0), n_pass = 0L, best = NULL, crit = NULL))
  }
  df <- h$df
  pass <- dsapp_cloud_pass(df, p)
  n <- nrow(df)

  ipae <- if ("ipae" %in% names(df)) df$ipae else rep(NA_real_, n)
  iptm <- if ("iptm" %in% names(df)) df$iptm else rep(NA_real_, n)
  pld  <- if ("binder_plddt" %in% names(df)) df$binder_plddt else rep(NA_real_, n)
  crit <- c(
    ipae = sum(!is.na(ipae) & ipae <= as.numeric(p$ipae_cut %||% 10)),
    iptm = sum(!is.na(iptm) & iptm >= as.numeric(p$iptm_cut %||% 0.6)),
    plddt = sum(!is.na(pld) & pld >= as.numeric(p$plddt_cut %||% 70))
  )
  n_calc <- sum(!is.na(ipae))

  rk <- dsapp_cloud_rank(df)
  best <- if (nrow(rk)) rk[1, , drop = FALSE] else NULL

  L <- c(
    sprintf("这次一共 %d 条设计记录：指标完整 %d 条、部分缺失 %d 条、读取或选链失败 %d 条。",
            n, h$n_ok, h$n_partial, h$n_error),
    sprintf("能算出 ipae 的有 %d 条；三条观察线同时满足的有 **%d** 条。", n_calc,
            sum(pass)),
    sprintf("分开看：ipae ≤ %s 的 %d 条，ipTM ≥ %s 的 %d 条，binder pLDDT ≥ %s 的 %d 条。",
            dsapp_cloud_num(p$ipae_cut, "10"), crit[["ipae"]],
            dsapp_cloud_num(p$iptm_cut, "0.6"), crit[["iptm"]],
            dsapp_cloud_num(p$plddt_cut, "70"), crit[["plddt"]]),
    "⚠️ 这三条线只是**观察线**，不是已经验证过的实验成功阈值 —— 教学原文对 10 Å 和 ipTM/pLDDT 那几档都明说了这一点。别拿它们当录取线。"
  )

  # ---- 按数据形状给下一步 ----
  if (h$n_error > 0 || h$n_partial > 0) {
    L <- c(L, sprintf(
      paste0("有 %d 条读不出完整指标（CSV 的 notes 列写了原因）。",
             "先看这一列 —— 常见是预测结构和参考结构的残基编号对不上，",
             "或选链选错了。这些行**不能当 0 分**看待，也不该混进排名。"),
      h$n_error + h$n_partial))
  }
  if (sum(pass) == 0 && n_calc > 0) {
    if (crit[["ipae"]] == 0) {
      L <- c(L, paste0(
        "一条都没过 ipae 观察线：模型对两条链的相对位置没把握。可以回参数页",
        "换 hotspot（挑一个更连续、更可接近的表面，别让热点散在两端）、",
        "或把 contig 里保留的靶点范围收窄到真正的结合表面区域，再跑一批。"))
    } else if (crit[["iptm"]] == 0) {
      # ⚠️ 判据是"**一条都没过** ipTM 那条线"（crit[["iptm"]] == 0），不是
      #    "过 ipTM 的比没过全部筛选的少" —— 后者在 sum(pass) == 0 的前提下
      #    几乎恒真，于是不管数据什么形状都会印这一段，等于没判。
      L <- c(L, paste0(
        "ipae 有过的、但 ipTM 偏低：界面姿态缺强支持。教学 7 节的做法是",
        "**不要单独看某一个分数** —— 把 ipae、ipTM、RMSD 和结构摆在一起看。"))
    }
    if (sum(!is.na(pld) & pld < as.numeric(p$plddt_cut %||% 70)) == n_calc) {
      L <- c(L, paste0(
        "binder 自己的 pLDDT 普遍偏低：问题可能出在骨架而不是序列 ——",
        "先换采样参数（step_scale / gamma_0）或增加骨架数量，再谈序列优化。"))
    }
    L <- c(L, paste0(
      "也可以先把量加上去：现在每个骨架 ",
      dsapp_cloud_int(p$mpnn_seq), " 条序列。教学 8 节说生产任务是",
      "「增加骨架数量，并为每个骨架设计更多序列」。"))
  }
  if (sum(pass) > 0 && !is.null(best)) {
    L <- c(L, sprintf(
      "排名第一的那条：%s（来源 %s），ipae %s、ipTM %s、binder pLDDT %s。",
      as.character(best$prediction_id %||% best$rfd3_design_id %||% "（无编号）"),
      as.character(best$source %||% ""),
      dsapp_cloud_num(best$ipae), dsapp_cloud_num(best$iptm),
      dsapp_cloud_num(best$binder_plddt)))
  }

  L <- c(L,
    "**接下来该做什么**（教学第 9 节那张表，按需要挑，不必每条都做）：",
    "1. 界面检查与补充对接 —— 看 binder 有没有占住预期表面、有没有碰撞，氢键/盐桥/疏水接触是否合理；可以换另一种结构预测模型或对接看看姿态是否一致。对接分数不能证明结合，也不能换算成亲和力。",
    "2. 分子动力学 —— 在选定的力场、溶剂和模拟条件下，复合物和界面接触能不能维持；比较独立重复。单条短轨迹里“没有散开”不足以证明真实结合，MM/PBSA 之类的估计也不能代替实验 K_D。",
    "3. 结合与特异性实验 —— SPR / BLI 或适合体系的结合实验，**一定要设阳性、阴性和非靶蛋白对照**，排查标签效应与非特异吸附。",
    "4. 位点与功能验证 —— 竞争结合、界面突变、必要的结构实验。⚠️ 如果目标是阻断 PD-1/PD-L1：**单纯结合 PD-L1 并不等于具有阻断作用**，还得做相应的竞争或细胞功能实验。",
    sprintf(
      paste0("**记录**：教学 8 节要求每次任务都记下输入数、成功预测数和通过筛选数",
             "（这次是 %d / %d / %d）；每条记录带上靶点、骨架 ID、序列 ID、",
             "MPNN 权重来源、随机种子、软件版本。两套 MPNN 目录里同名的文件",
             "**不是同一条序列**。改了热点或输入结构之后要换新的输出目录，",
             "避免续跑混进旧结果。"),
      n, n_calc, sum(pass))
  )

  list(lines = L, n_pass = sum(pass), best = best, crit = crit)
}


# =============================================================================
# 六、跟界面有关的那一点点（**唯一**碰磁盘状态的部分）
# =============================================================================

#' 这一次运行的根目录
#'
#' 落在**对话工作区**里（`<ws>/cloud/<任务名>-<时间戳>`），不是 data_root 下面
#' 另开一处：产物要能被"产物卡片"和「文件」页看见，而那些都只认工作区。
dsapp_cloud_run_root <- function(ws, p, stamp = NULL) {
  st <- stamp %||% format(Sys.time(), "%Y%m%d-%H%M%S")
  file.path(ws, "cloud",
            sprintf("%s-%s", dsapp_cloud_slug(p$job), st))
}

#' 列这个工作区里已经跑过的几次
#'
#' @return data.frame(dir, name, mtime, size_h)，按时间倒序。
dsapp_cloud_runs <- function(ws) {
  root <- file.path(ws, "cloud")
  if (!dir.exists(root)) {
    return(data.frame(dir = character(), name = character(),
                      mtime = character(), stringsAsFactors = FALSE))
  }
  ds <- list.dirs(root, recursive = FALSE, full.names = TRUE)
  ds <- ds[!grepl("^\\.", basename(ds))]
  if (!length(ds)) {
    return(data.frame(dir = character(), name = character(),
                      mtime = character(), stringsAsFactors = FALSE))
  }
  mt <- file.mtime(ds)
  # 取**最晚**的修改时间：运行中它一直在变，这样列表里能看出哪个是活的。
  mt <- vapply(ds, function(d) {
    f <- list.files(d, recursive = TRUE, full.names = TRUE)
    if (!length(f)) return(as.numeric(file.mtime(d)))
    suppressWarnings(max(as.numeric(file.mtime(f)), na.rm = TRUE))
  }, numeric(1))
  o <- order(mt, decreasing = TRUE)
  data.frame(dir = ds[o], name = basename(ds)[o],
             mtime = format(as.POSIXct(mt[o], origin = "1970-01-01"),
                            "%Y-%m-%d %H:%M"),
             stringsAsFactors = FALSE)
}

#' 运行状态的存档（链式推进用）
#'
#' ⚠️ 用 **RDS** 不用 JSON：这是 R 自己的状态（带嵌套 list、整数、NULL），
#'    JSON 往返会把整数变double、把 NULL 丢掉，而 `p$preset` 之类的字段
#'    丢一个就会让续跑用错参数 —— 那种错不会报，只会让结果和界面上写的
#'    对不上。
#'
#' 存在 `<ws>/.dsapp_cloud/` 下面（点开头 = 内部目录，不进产物清单，
#' 和 `.Rlib` / `.venv` 同一个待遇）。
dsapp_cloud_state_path <- function(ws, run_id) {
  file.path(ws, ".dsapp_cloud", paste0(dsapp_cloud_slug(run_id), ".rds"))
}

dsapp_cloud_state_save <- function(ws, st) {
  d <- file.path(ws, ".dsapp_cloud")
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  p <- dsapp_cloud_state_path(ws, st$id)
  tmp <- paste0(p, ".tmp")
  # 原子改名：界面随时可能在读，直接写目标文件有读半截的窗口。
  saveRDS(st, tmp)
  file.rename(tmp, p)
  invisible(p)
}

dsapp_cloud_state_load <- function(ws, run_id) {
  p <- dsapp_cloud_state_path(ws, run_id)
  if (!file.exists(p)) return(NULL)
  tryCatch(readRDS(p), error = function(e) NULL)
}

dsapp_cloud_state_list <- function(ws) {
  d <- file.path(ws, ".dsapp_cloud")
  if (!dir.exists(d)) return(list())
  fs <- list.files(d, pattern = "\\.rds$", full.names = TRUE)
  out <- lapply(fs, function(f) tryCatch(readRDS(f), error = function(e) NULL))
  out[!vapply(out, is.null, logical(1))]
}



# =============================================================================
# 云工具的**工具注册表**（★ V16.4 item 1 / item 2）
# =============================================================================
# 用户原话（2026-10-04）：
#   1、「按照 …/skills_builtin/单细胞云平台Agent工具构建提示词.md 来优化单细胞云工具」
#   2、「按照 TCGA数据库挖掘云平台Agent工具构建提示词.md 来优化 TCGA 数据挖掘模块」
#
# 这两份文档各有一节「0. 工具能力注册表」，把整套云工具列成表：
# 工具名 · 功能 · 关键入参 · 关键出参 · KB检索词。文档本身是**给 agent 的
# 提示词**，但光把它当技能挂上去只解决了一半 —— 用户在这两个面板上看到的
# 仍然只有一个按钮，他没法知道"这套工具到底有哪些、我要的那个在不在"。
#
# 所以这一节做两件事：
#   ① 把文档里的注册表**解析成结构**（不是把表格抄一份进来）；
#   ② 由结构生成两段可发的开场白：**单个工具**一段、**编排路线**一段。
#
# -----------------------------------------------------------------------------
# ★★ 为什么不把那张表在 R 里手抄一遍
# -----------------------------------------------------------------------------
# 手抄一份的代价是**两份真相**：文档加了工具、改了参数，代码里那份不会动，
# 而界面上看不出来 —— 用户按页面点了一个工具，发给 agent 的却是上一版的名字。
# 解析的代价是"文档改了格式就解析不出来"，但那个**会红**（自检里有覆盖断言），
# 不是静默走样。宁可红，不要静默。
#
# ⚠️⚠️ 解析这种"按表头认列"的表，两处必须写对（都是本仓记过账的坑）：
#    · 列名不在表里时**不许**写 `cols[[列名]]` —— 那是对字符向量取不存在的
#      名字，在 R 里是**硬错误**（"subscript out of bounds"），不是 NULL。
#      一律 match() 到下标再取。
#    · 列的含义跟**表头**走，不跟位置走：这两份文档里 3 列的表格有两种含义
#      （D/E 节是「功能 + KB检索词」，F/K 节是「功能 + 入参 / 出参」）。
#      按位置取的话，F 节的"入参"会被当成 KB 检索词写进提示词里。
#
# ⚠️ 匹配一律 fixed = TRUE 或按行判断：本仓栽过"正则匹配源码静默走样"
#    （没转义的括号是空组、返回 -1），而这里的字符串里全是 `()` 和 `/`。
# =============================================================================

# 两份文档各自的元信息。`skill` 是它作为内置技能的名字（技能页上显示的那个），
# 面板上「开对话」时要按它去库里查 id 挂上 —— 所以它必须和 .md 的
# frontmatter 里的 `name:` **逐字相同**，自检里有一条钉这个。
DSAPP_CLOUDREG <- list(
  sc = list(
    label = "单细胞分析",
    doc   = "单细胞云平台Agent工具构建提示词.md",
    skill = "单细胞云工具（全能力）"
  ),
  tcga = list(
    label = "TCGA 数据挖掘",
    doc   = "TCGA数据库挖掘云平台Agent工具构建提示词.md",
    skill = "TCGA 云工具（全能力）"
  )
)

#' 归一化注册表的名字（不认识的给 sc，并**不**报错）
#'
#' 界面上的值来自浏览器，什么都可能送过来。归一成 sc 是"退化成默认工具台"，
#' 比抛错好：抛错会让整页挂掉，而用户只是想看单细胞那一栏。
dsapp_cloudreg_kind <- function(kind) {
  k <- as.character(kind %||% "sc")[1]
  if (is.na(k) || !nzchar(k) || is.null(DSAPP_CLOUDREG[[k]])) "sc" else k
}

#' 文档在盘上的位置
dsapp_cloudreg_path <- function(kind, dir = NULL) {
  k <- dsapp_cloudreg_kind(kind)
  file.path(dsapp_skills_builtin_dir(dir), DSAPP_CLOUDREG[[k]]$doc)
}

# ---- 小工具：按行扫文档 ------------------------------------------------------

#' 取一个一级标题（`# 5. …`）那一节的正文行（**不含**标题本身）
#'
#' 结束位置是下一个 `# `（一级标题）之前。
dsapp_cloudreg_h1 <- function(lines, pat) {
  i <- grep(pat, lines)
  if (!length(i)) return(character(0))
  i <- i[[1]]
  j <- grep("^#\\s", lines)
  j <- j[j > i]
  end <- if (length(j)) j[[1]] - 1L else length(lines)
  if (end <= i) return(character(0))
  lines[(i + 1L):end]
}

#' 取一段里**第一个**围栏代码块的内容
#'
#' ⚠️ 判围栏只认"这一行的开头（允许前导空格）就是三反引号"。行中间的三反引号
#'    永远不是围栏 —— 本仓栽过一次：按行中间的它去拆，后半句被吃成空代码块，
#'    而库里和渲染函数都是对的（只有判据错）。
dsapp_cloudreg_fence <- function(lines) {
  open <- grep("^\\s*```", lines)
  if (length(open) < 2L) return(character(0))
  a <- open[[1]]
  rest <- open[open > a]
  if (!length(rest)) return(character(0))
  b <- rest[[1]]
  if (b <= a + 1L) return(character(0))
  lines[(a + 1L):(b - 1L)]
}

#' 把一行 Markdown 表格切成单元格（去掉两头的空档和包裹用的反引号）
#'
#' ⚠️⚠️ **先掐掉两头的竖线再切**，不要切完再掐首尾两个元素。
#'    `strsplit()` 会把**结尾的空串丢掉**：`"| a | b |"` 切开是
#'    `c("", " a ", " b ")` 三个（末尾那个空串没了）。所以"切完再去掉首尾"
#'    会**多吃掉一个真格子** —— 5 列的表格读成 4 列，最后一列（KB检索词 /
#'    关键出参）永远是空的，而表头那一行同样少一格、两边正好对齐，
#'    于是它**不报错、不越界**，只是提示词里少一行、界面上少一列。
#'    2026-10-04 写这一节时当场踩到（`sc_read_data` 的 kb 是空的）。
dsapp_cloudreg_cells <- function(ln) {
  x <- trimws(ln)
  if (startsWith(x, "|")) x <- substring(x, 2L)
  if (endsWith(x, "|")) x <- substring(x, 1L, nchar(x) - 1L)
  if (!nzchar(x)) return(character(0))
  cells <- strsplit(x, "|", fixed = TRUE)[[1]]
  if (length(cells) < 2L) return(character(0))
  trimws(gsub("`", "", trimws(cells), fixed = TRUE))
}

#' 解析「0. 工具能力注册表」那张表
#'
#' @return list(groups = list(list(letter, title, tools = list(...))), n = 总数)
#'         每个 tool 是 list(key, fn, inputs, outputs, kb)
dsapp_cloudreg_parse <- function(txt, kind = "sc") {
  kind <- dsapp_cloudreg_kind(kind)
  lines <- strsplit(gsub("\r\n", "\n", as.character(txt %||% "")), "\n",
                    fixed = TRUE)[[1]]

  # 文档里的列名 → 我们的字段名。两份文档、两种 3 列表都在这里对齐。
  cols <- c("工具名" = "key", "功能" = "fn",
            "关键入参" = "inputs", "入参" = "inputs",
            "关键出参" = "outputs", "出参" = "outputs",
            "KB检索词" = "kb")

  out <- list(); gi <- 0L; hdr <- NULL; in_reg <- FALSE
  for (ln in lines) {
    t <- trimws(ln)
    if (grepl("^#\\s", t)) {                    # 一级标题：进/出注册表那一节
      in_reg <- grepl("工具能力注册表", t, fixed = TRUE)
      hdr <- NULL
      next
    }
    if (!in_reg) next
    m <- regmatches(t, regexec("^##\\s+([A-Z])\\.\\s*(.+)$", t))[[1]]
    if (length(m) == 3L) {                      # `## A. 主流程工具（…）`
      out[[length(out) + 1L]] <- list(letter = m[[2]],
                                      title  = trimws(m[[3]]),
                                      tools  = list())
      gi <- length(out)
      hdr <- NULL
      next
    }
    if (!startsWith(t, "|")) next
    cells <- dsapp_cloudreg_cells(t)
    if (!length(cells)) next
    if (identical(cells[[1]], "工具名")) {      # 表头行
      hdr <- cells
      next
    }
    if (gi < 1L || is.null(hdr)) next
    rec <- list(key = "", fn = "", inputs = "", outputs = "", kb = "")
    for (i in seq_along(hdr)) {
      if (i > length(cells)) next
      # ⚠️ match() 而不是 `cols[[hdr[[i]]]]`：名字不在表里时后者是硬错误。
      j <- match(hdr[[i]], names(cols))
      if (is.na(j)) next
      rec[[cols[[j]]]] <- cells[[i]]
    }
    # 工具名必须长得像个函数名（`---` 分隔行、说明文字都在这里被挡掉）
    if (!grepl("^[A-Za-z][A-Za-z0-9_]*$", rec$key)) next
    out[[gi]]$tools[[length(out[[gi]]$tools) + 1L]] <- rec
  }
  list(groups = out,
       n = sum(vapply(out, function(g) length(g$tools), integer(1))))
}

#' 从文档里抠出「1.2 流程铁律」那一行链子和它下面的条目
dsapp_cloudreg_rules <- function(lines) {
  hs <- grep("^##\\s*1\\.2", lines)
  if (!length(hs)) return(list(chain = "", items = character(0)))
  i <- hs[[1]]
  j <- grep("^##\\s", lines); j <- j[j > i]
  end <- if (length(j)) j[[1]] - 1L else length(lines)
  body <- if (end > i) lines[(i + 1L):end] else character(0)
  body <- body[!grepl("^\\s*```", body)]
  nb <- body[nzchar(trimws(body))]
  if (!length(nb)) return(list(chain = "", items = character(0)))
  list(chain = trimws(nb[[1]]),
       items = trimws(sub("^[-*]\\s*", "",
                          nb[grepl("^\\s*[-*]\\s", nb)])))
}

#' 从文档里抠出「5. 流程编排决策」那一节的输入/路线/输出
#'
#' 路线行在文档里长这样（两份文档同构）：
#'     1. 原始矩阵 → 完整走 QC→归一化→降维聚类→注释→下游。
#'     1. 预后模型（最常见）：下载表达+临床 → DEG（或直接全基因/UniCox）→ …
#' 所以"标签"取第一个箭头/冒号之前那截，正文取整行 —— 两者都进提示词。
dsapp_cloudreg_routes <- function(lines) {
  blk <- dsapp_cloudreg_fence(dsapp_cloudreg_h1(lines, "^#\\s*5\\."))
  if (!length(blk)) return(list(intro = "", items = list(), outro = ""))
  x <- trimws(blk)
  hash <- function(p) trimws(paste(x[grepl(p, x)], collapse = " "))
  items <- list()
  # ★★ 一条路线在文档里**会折行**（TCGA 那 7 条各占两行：编号行 + 续行）。
  #    只收编号行的话，发出去的提示词里那条路会在第一行的末尾断掉 ——
  #    而断点正好落在「→」后面，读起来像是本来就写完了。
  #    （2026-10-04 写这一节时踩到：`tcga` 第 1 条只剩到「→ LASSO」。）
  for (ln in x) {
    if (!nzchar(ln)) next
    if (grepl("^输入|^输出", ln)) next        # 这两行单独收成 intro / outro
    if (grepl("^[0-9]+\\s*[.、]\\s*\\S", ln)) {
      items[[length(items) + 1L]] <- trimws(sub("^[0-9]+\\s*[.、]\\s*", "", ln))
    } else if (length(items)) {
      items[[length(items)]] <- paste(items[[length(items)]], ln)
    }
    # 编号行之前的那几行（「决策：」/「按目标路由：」）在这里被丢掉：
    # 它们上面没有 items，走不进任何一条路线。
  }
  items <- lapply(items, function(body) {
    list(label = trimws(sub("\\s*(→|：|:).*$", "", body)), text = body)
  })
  list(intro = hash("^输入"), items = items, outro = hash("^输出"))
}


# ---- 读 + 缓存 ---------------------------------------------------------------

.dsapp_cloudreg_cache <- new.env(parent = emptyenv())

#' 读并解析一份云工具文档
#'
#' 和内置技能一样走**进程内缓存**：这两份文档一共 50 KB 上下，而这一页每次
#' renderUI 都要用它。**故意不做 mtime 失效** —— 文档随代码走，改完要么重启
#' 进程、要么重新 source 本文件（那时这个 env 会重建），两条路都会让缓存失效。
#'
#' ⚠️ 读不出来时**不抛错**，返回 ok = FALSE + 一句话：这一页整个挂掉的话，
#'    用户看到的是"云工具页打不开"，而真正的原因（文档被删了 / 权限不对）
#'    一个字都看不到。
dsapp_cloudreg <- function(kind = "sc", dir = NULL, refresh = FALSE) {
  k <- dsapp_cloudreg_kind(kind)
  meta <- DSAPP_CLOUDREG[[k]]
  key <- paste0(k, "|", dsapp_skills_builtin_dir(dir))
  if (!refresh && !is.null(.dsapp_cloudreg_cache[[key]])) {
    return(.dsapp_cloudreg_cache[[key]])
  }
  p <- dsapp_cloudreg_path(k, dir)
  txt <- tryCatch({
    # ⚠️ suppressWarnings：文件不存在时 readLines 会**先**报一条
    #    "cannot open file ..." 再抛。我们这里把"读不到"当成一条正常分支
    #    （下面 ok = FALSE），那条警告会原样漏到用户的自检输出里，
    #    看着像出了别的事。
    ln <- suppressWarnings(readLines(p, warn = FALSE, encoding = "UTF-8"))
    enc2utf8(paste(ln, collapse = "\n"))
  }, error = function(e) NULL)
  if (is.null(txt) || !nzchar(trimws(txt))) {
    r <- list(kind = k, label = meta$label, skill = meta$skill, doc = meta$doc,
              path = p, ok = FALSE, msg = "读不到这份工具文档（被删了？权限？）",
              groups = list(), n = 0L, tools = list(), chain = "",
              rules = character(0),
              routes = list(intro = "", items = list(), outro = ""))
    .dsapp_cloudreg_cache[[key]] <- r
    return(r)
  }
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  reg   <- dsapp_cloudreg_parse(txt, k)
  # 拍平一份按 key 索引的，供"点某个工具"那条路 O(1) 查
  flat <- list()
  for (g in reg$groups) for (tl in g$tools) {
    tl$group <- g$letter
    tl$group_title <- g$title
    if (!nzchar(tl$key)) next
    flat[[tl$key]] <- tl
  }
  ru <- dsapp_cloudreg_rules(lines)
  r <- list(kind = k, label = meta$label, skill = meta$skill, doc = meta$doc,
            path = p, ok = TRUE, msg = "",
            groups = reg$groups, n = reg$n, tools = flat,
            chain = ru$chain, rules = ru$items,
            routes = dsapp_cloudreg_routes(lines))
  .dsapp_cloudreg_cache[[key]] <- r
  r
}

#' 注册表拍成一张表（给界面画）
#'
#' @param q     关键词（工具名 / 功能 / 入参 / 出参 / KB 检索词里任意一处命中）
#' @param group 只留某一组（""= 全部）
dsapp_cloudreg_table <- function(kind = "sc", q = "", group = "",
                                 dir = NULL, refresh = FALSE) {
  r <- dsapp_cloudreg(kind, dir = dir, refresh = refresh)
  rows <- list()
  for (g in r$groups) for (tl in g$tools) {
    rows[[length(rows) + 1L]] <- data.frame(
      key = tl$key, group = g$letter, group_title = g$title,
      fn = tl$fn, inputs = tl$inputs, outputs = tl$outputs, kb = tl$kb,
      stringsAsFactors = FALSE)
  }
  if (!length(rows)) {
    return(data.frame(key = character(0), group = character(0),
                      group_title = character(0), fn = character(0),
                      inputs = character(0), outputs = character(0),
                      kb = character(0), stringsAsFactors = FALSE))
  }
  df <- do.call(rbind, rows)
  group <- trimws(as.character(group %||% "")[1])
  if (nzchar(group) && !identical(group, "all")) {
    df <- df[df$group == group, , drop = FALSE]
  }
  q <- trimws(as.character(q %||% "")[1])
  if (nzchar(q)) {
    hay <- tolower(paste(df$key, df$fn, df$inputs, df$outputs, df$kb,
                         df$group_title, sep = "\n"))
    # ⚠️ fixed = TRUE：检索词里有 `.` `(` `[` `*`（`sc.pl.umap`、`Read10X`、
    #    `fread` 之类），当正则会静默变味（本仓老账）。
    df <- df[grepl(tolower(q), hay, fixed = TRUE), , drop = FALSE]
  }
  rownames(df) <- NULL
  df
}

#' 按 key 取一个工具的记录（没有就 NULL）
dsapp_cloudreg_find <- function(kind = "sc", key, dir = NULL) {
  k <- dsapp_cloudreg_kind(kind)
  ky <- trimws(as.character(key %||% "")[1])
  if (!nzchar(ky)) return(NULL)
  dsapp_cloudreg(k, dir = dir)$tools[[ky]]
}


# ---- 两段开场白 --------------------------------------------------------------

#' 拼「这一套工具的规矩」那几行（流程铁律 + 条目）
#'
#' ⚠️ 从文档里**现读**，不手抄：文档哪天把「主流程优先 Seurat V5」改成别的，
#'    发出去的提示词要跟着变。手抄一份就是两份真相。
dsapp_cloudreg_rules_txt <- function(kind = "sc", dir = NULL) {
  r <- dsapp_cloudreg(kind, dir = dir)
  c(if (nzchar(r$chain)) paste0("流程铁律（不跳步、不乱序）：", r$chain),
    if (length(r$rules)) paste0("- ", r$rules))
}

#' 每段提示词共用的尾巴：三件在这台机器上必须说清的事
#'
#' ★ 这三条不是客套话，每一条都对着一个真实的失败方式：
#'   ① 文档第 0 节 F 那三个检索工具（`search_kb` / `get_kb_stats` /
#'      `list_sources`）是**外部 MCP 服务**，本平台没有接。不说明的话，
#'      模型会一本正经地"去知识库检索"，然后编一段参数基线出来 ——
#'      而这一段恰恰是用户最信的部分。
#'   ② 这个平台的云工具是"**在工作区里写代码跑**"，不是调后台 API。
#'      不说清的话，模型会给你一段"调用 sc_qc_filter"的伪代码。
#'   ③ 参数不许编。这一条文档 1.3 里写着，这里再钉一遍是因为**对话里的
#'      第一句**最管用。
dsapp_cloudreg_tail <- function(kind = "sc") {
  paste(
    "",
    "⚠️ 三件必须先说清的事：",
    "1. 本平台**没有**外接的知识库检索服务（文档第 0 节 F 里那三个 search_kb /",
    "   get_kb_stats / list_sources 在这里不存在）。上面那些「KB检索词」请拿去",
    "   在**本对话挂载的技能**和**工作区已有的文件**里找；找不到就直说「知识库",
    "   没覆盖这一块」，改用官方文档并标注来源 —— **不许假装检索过**。",
    "2. 这里的云工具 = **你在工作区里写代码、跑出来**，不是调用一个后台接口。",
    "   把代码和**真实的输出**（不是预期的输出）一起给我看。",
    "3. 参数别编：拿不准的**一次性**问清再动手，不要一步一问；",
    "   中途也不要停下来等我确认，做完再汇报。",
    sep = "\n")
}

#' 单个工具的开场白
#'
#' 用户点某一行的「用这个工具」时发出去的那段。它要说清四件事：
#' 这是哪个工具、它吃什么吐什么、文档里对应的检索词、以及别编参数。
dsapp_cloudreg_prompt <- function(kind = "sc", key, dir = NULL) {
  k <- dsapp_cloudreg_kind(kind)
  r <- dsapp_cloudreg(k, dir = dir)
  tl <- dsapp_cloudreg_find(k, key, dir = dir)
  if (is.null(tl)) {
    return(paste0("【", r$label, "云工具】\n\n",
                  "（想用的那个工具「", as.character(key %||% ""),
                  "」在注册表里没找到，按标准流程走一遍。）",
                  dsapp_cloudreg_tail(k)))
  }
  lab <- function(x, title) if (nzchar(x)) paste0(title, x) else NULL
  paste(c(
    sprintf("【%s云工具 · %s】%s", r$label, tl$key, tl$fn),
    sprintf("（工具注册表 %s %s · 这一次只做这一个工具，做完把结果和判读一起给我）",
            tl$group, tl$group_title),
    "",
    lab(tl$inputs,  "它要的输入："),
    lab(tl$outputs, "它该产出："),
    lab(tl$kb,      "文档里的知识库检索词："),
    "",
    paste0("这套文档（《", r$skill, "》）已经挂在这个对话的技能里，",
           "参数基线、判读规则、常见坑都在里面 —— 按它来，"),
    "不要照抄网上的默认值。",
    "",
    dsapp_cloudreg_rules_txt(k, dir = dir),
    dsapp_cloudreg_tail(k)
  ), collapse = "\n")
}

#' 按编排路线开一段开场白
#'
#' @param i 路线序号（1 开始）；越界或文档里那一节读不出来时，退化成
#'          「按标准流程走一遍」——**不报错**，用户点一下不该看到红字。
dsapp_cloudreg_plan <- function(kind = "sc", i = NULL, dir = NULL) {
  k <- dsapp_cloudreg_kind(kind)
  r <- dsapp_cloudreg(k, dir = dir)
  it <- NULL
  if (!is.null(i)) {
    ii <- suppressWarnings(as.integer(i))
    if (!is.na(ii) && ii >= 1L && ii <= length(r$routes$items)) {
      it <- r$routes$items[[ii]]
    }
  }
  head <- if (is.null(it)) {
    sprintf("【%s云工具 · 按标准流程走一遍】", r$label)
  } else {
    sprintf("【%s云工具 · 按目标编排】%s", r$label, it$label)
  }
  # ⚠️ 这三个问题**按 kind 分**：TCGA 那边问「数据在哪/什么形态」是问错了对象
  #    （数据是从 GDC 下的，不是用户手里的文件），而 sc 这边问「哪个癌种」同样
  #    莫名其妙。共用一套问句的话，agent 会把用户往一个不对的方向上带一节。
  asks <- if (identical(k, "tcga"))
    c("  · 癌种 / 队列（TCGA 的哪个 project，如 TCGA-LUAD）；",
      "  · 要哪几个组学层（表达 / miRNA / 甲基化 / 拷贝数 / 体细胞突变 / 临床随访），",
      "    有没有配对正常样本；",
      "  · 想回答哪一类问题：预后生存 / 分子分型 / 肿瘤 vs 正常差异 / 免疫浸润 / 靶点关联。")
  else
    c("  · 数据在哪：我这个工作区里的路径，还是公开数据（GEO / 10x 官网）；",
      "    是 filtered 矩阵、raw 矩阵还是 h5ad；",
      "  · 物种、组织，以及有没有多个样本 / 批次（这决定了要不要整合）；",
      "  · 这次最想回答的问题（分群注释 / 组间差异 / 轨迹 / 细胞通讯 / 转录因子）。")
  paste(c(
    head,
    "",
    "请带我走完这一趟，不要停在「给个方案」。如果下面这些我还没说清楚，",
    "**一次性**问完就往下走，不要一步一问：",
    asks,
    "",
    if (!is.null(it)) c("文档给这条目标的编排是：", it$text, "") else NULL,
    if (nzchar(r$routes$intro))
      paste0("（文档对编排输入的说明：", r$routes$intro, "）") else NULL,
    if (nzchar(r$routes$outro))
      paste0("（文档要求最后交付：", r$routes$outro, "）") else NULL,
    "",
    "每一步先说明「这一步在排除什么风险」，别只报进度。",
    "",
    dsapp_cloudreg_rules_txt(k, dir = dir),
    dsapp_cloudreg_tail(k)
  ), collapse = "\n")
}

#' 这份文档作为**内置技能**在库里的 id（查不到返回 integer(0)）
#'
#' 云工具页开对话时要把这条技能挂上去 —— 文档本身（几十 KB 的注册表 + 判读
#' 规则）就是 agent 干活时要照着看的东西，不挂上去，开场白里那句「这套文档
#' 已经挂在技能里」就是空话。
#'
#' ⚠️ 认的是 `(user_id IS NULL, builtin = 1, name)` 这一组，和
#'    `dsapp_skills_seed()` 种进去时用的是同一组（内置技能在库里没有别的身份，
#'    见 R/skills.R 的说明）。名字取自 `DSAPP_CLOUDREG[[k]]$skill`，自检里
#'    有一条钉着"它和 .md 的 frontmatter `name:` 逐字相同"。
#'
#' ⚠️ 查不到就返回 integer(0)，**不报错**：技能是"锦上添花"（R/skills.R 顶上
#'    那段写的就是这个），数据库里还没种上不该让「开对话」这个动作失败。
#' @param con 一个 DBI 连接（S4）。⚠️ 别写成 `con %||% dsapp_db(cfg)` ——
#'            `%||%` 对 S4 连接会抛错再被吞掉，开关恒失效（本仓老账）。
dsapp_cloudreg_skill_id <- function(kind = "sc", con) {
  k <- dsapp_cloudreg_kind(kind)
  nm <- DSAPP_CLOUDREG[[k]]$skill
  if (is.null(con) || !nzchar(nm)) return(integer(0))
  id <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT id FROM skills WHERE user_id IS NULL AND builtin = 1 AND name = ?",
      params = list(nm))$id,
    error = function(e) NULL)
  if (is.null(id) || !length(id)) return(integer(0))
  as.integer(id[[1]])
}
