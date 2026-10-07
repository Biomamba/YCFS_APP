#!/usr/bin/env Rscript
# =============================================================================
# V15.8 item 1 端到端：这台机器现在有卡了，埋好的 GPU 那条路**真的通了吗**
# =============================================================================
#     Rscript tests/v158_gpu.R            # 在应用目录下跑
#
# ── 要回答的问题 ─────────────────────────────────────────────────────────────
#
# 用户原话：「服务器现在有GPU了，测试一下原来埋得GPU功能和入口能不能正常使用」。
#
# 这套东西是 V14 埋的，埋完之后**从来没在有卡的机器上跑过** —— 线上 8 个账号
# 的 gpu_enabled 全是 NULL（= 跟平台默认），而平台默认 DSAPP_EXEC_GPU 是关的。
# 也就是说：写是写完了，一次都没真用过。「没被用过」和「能用」是两件事。
#
# ── 这份测试和自检的分工 ────────────────────────────────────────────────────
#
# 自检里那一节（V14 item 7）测的是**判据函数**：喂进去 TRUE/FALSE/NULL/NA，
# 看它有没有按约定处理。那证明不了"子进程里真的看得见卡" ——
# 而这一条恰恰是用户问的那件事，也是唯一一条"函数全对但功能是坏的"能藏身的
# 地方（本仓已经栽过两次：selftest-green-is-not-coverage）。
#
# 所以这里四段，一段比一段靠外：
#   A 探测   —— 这台机器上到底有没有卡（dsapp_host_gpu）
#   B 约定   —— 三态怎么变成环境变量（dsapp_exec_env）
#   C 提示词 —— 模型那边被告知的是什么（dsapp_gpu_prompt_line）
#   D **真跑** —— 起一个真子进程，用同一套环境，问它看不看得见卡
#
# ★★ D 是整份测试里唯一有分量的一段。A/B/C 全绿而 D 红，说明"开关写得对、
#    就是没接上"；而 D 绿了才叫"这台机器上的 GPU 功能能用"。
#
# ── 两件必须做对的事 ────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到一个临时目录再 source。仓库根的 .Renviron 把
#     DSAPP_DATA_ROOT 指着**生产库** —— 不指开的话，这份测试会往生产库里
#     建表、写账号。本仓为此栽过（自检泄漏 DSAPP_DATA_ROOT，写进了生产库）。
#
# ⚠️ 一条出网请求都不会有：这份测试只探测本机设备、只起本机子进程。
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

# ---- 先把数据根目录挪走，再 source -----------------------------------------
tmp <- tempfile("dsapp_gpu_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)
# 平台默认**显式**写成关：这一份测的是"每账号那个开关"，不是平台默认。
Sys.unsetenv("DSAPP_EXEC_GPU")

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}
cfg <- dsapp_config()
dsapp_init_dirs(cfg)
say("数据根目录：%s（**不是**生产库）", cfg$data_root)
chk("★ 前提：数据根目录真的是临时目录（指错就是往生产库写东西）",
    !identical(normalizePath(cfg$data_root, mustWork = FALSE),
               normalizePath(file.path(app_dir, "data"), mustWork = FALSE)),
    sprintf("cfg$data_root=%s", cfg$data_root))

# =============================================================================
# A 这台机器上有没有卡
# =============================================================================
say("\n== A 探测：这台机器上有卡吗 ==")
g <- dsapp_host_gpu()
say("  dsapp_host_gpu(): ok=%s kind=%s", g$ok, g$kind)
say("  详情：%s", g$detail)
chk("★★ 前提：这台机器**检测得到** GPU（检测不到的话，下面几段全无意义）",
    isTRUE(g$ok), g$detail)

# nvidia-smi 是另一条独立的证据链：上面那个只看 /dev 节点存不存在，
# 这个问的是**驱动**。两个都对上，才排除"有设备节点但驱动没装"。
smi <- suppressWarnings(system2("nvidia-smi", c("-L"), stdout = TRUE, stderr = FALSE))
smi_ok <- (attr(smi, "status") %||% 0L) == 0L && length(smi) > 0
say("  nvidia-smi -L：%s", if (smi_ok) paste(smi, collapse = " | ") else "（没跑起来）")
chk("★★ 驱动那一侧也认得这张卡（nvidia-smi -L 有输出）", smi_ok)

# =============================================================================
# B 三态 → 环境变量
# =============================================================================
say("\n== B 约定：TRUE / FALSE / NULL / NA 分别怎么变成环境变量 ==")
K <- c("CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES",
       "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES")

# 先看基线：父进程里本来就有的那些值（很可能一个都没有）
base <- Sys.getenv(K, unset = NA_character_)
say("  父进程里这 4 个变量：%s",
    paste(sprintf("%s=%s", K, ifelse(is.na(base), "<未设>", base)), collapse = "  "))

# ⚠️ 取值的写法有个坑：这几个变量在"不该设"的时候**压根不在返回的向量里**，
#    而 `e[["CUDA_VISIBLE_DEVICES"]]` 对不存在的名字是**报错**（subscript out
#    of bounds），不是返回 NULL。第一版就死在这儿 —— 而它死的这一行恰恰是
#    "断言没被设"，报错长得像探针自己写坏了，不像被测的东西有问题。
getk <- function(e, k) if (k %in% names(e)) e[[k]] else "<未设>"
unset <- function(e, k) !(k %in% names(e))
show4 <- function(e) paste(sprintf("%s=[%s]", K, vapply(K, getk, character(1), e = e)),
                           collapse = "  ")

e_false <- dsapp_exec_env(gpu = FALSE)
chk("★★★ 关：4 个变量**全部**被置空（少一个就是在装了那套东西的机器上留口子）",
    all(vapply(K, function(k) identical(getk(e_false, k), ""), logical(1))),
    show4(e_false))

e_true <- dsapp_exec_env(gpu = TRUE)
chk("★★★ 开：**一个都不设**（不设 = 全都看得见；设成 \"0\" 在多卡机上等于替用户挑了一张）",
    all(vapply(K, function(k) unset(e_true, k), logical(1))),
    show4(e_true))

e_null <- dsapp_exec_env(gpu = NULL)
chk(paste0("★★ 不传(NULL)：也不设 ——「不知道」不等于「禁止」（静默屏蔽的症状是",
           "「任务突然跑不动了」，和「这次数据大」在界面上分不开）"),
    all(vapply(K, function(k) unset(e_null, k), logical(1))),
    show4(e_null))

e_na <- dsapp_exec_env(gpu = NA)
chk(paste0("★★ NA（库读失败）：同样不干预 —— 判据必须是 identical(gpu, FALSE)，",
           "写成 !isTRUE(gpu) 就会把 NA 当成关"),
    all(vapply(K, function(k) unset(e_na, k), logical(1))),
    show4(e_na))

# =============================================================================
# C 模型那边被告知的是什么
# =============================================================================
say("\n== C 提示词：模型拿到的那句话 ==")
p_on  <- dsapp_gpu_prompt_line(TRUE)
p_off <- dsapp_gpu_prompt_line(FALSE)
chk(paste0("★★ 开的时候说了「可用」，并且**要求先探测**（放行的是权限，不是",
           "「这台机器上一定插着卡」—— 这两件事在有的部署上并不一致）"),
    grepl("可用", p_on, fixed = TRUE) && grepl("nvidia-smi", p_on, fixed = TRUE))
chk("★★ 关的时候说了「不可用」，并且给出了该找谁（不是让用户去猜报错）",
    grepl("不可用", p_off, fixed = TRUE) && grepl("管理员", p_off, fixed = TRUE))

# =============================================================================
# D 真跑一个子进程，问它看不看得见卡
# =============================================================================
say("\n== D 真跑：同一套环境起子进程，问它看不看得见卡 ==")
say("  （这一段才是「GPU 功能能不能正常使用」的答案，A/B/C 都只是它的前提）")

# 用 python 问，因为真正吃 GPU 的是 python 那一侧；torch 在不在、编的是不是
# CUDA 版，只有问了才知道。
PY <- Sys.which("python3")
chk("★ 前提：找得到 python3", nzchar(PY))

probe_py <- function(env) {
  code <- paste(
    "import os",
    "print('CUDA_VISIBLE_DEVICES=' + repr(os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')))",
    "try:",
    "    import torch",
    "    print('torch=' + torch.__version__)",
    "    print('torch_cuda=' + str(torch.cuda.is_available()))",
    "    print('torch_device_count=' + str(torch.cuda.device_count()))",
    "except Exception as e:",
    "    print('torch=<import failed: %s>' % e)",
    "import shutil, subprocess",
    "if shutil.which('nvidia-smi'):",
    "    r = subprocess.run(['nvidia-smi','-L'], capture_output=True, text=True)",
    "    print('smi=' + r.stdout.strip().replace(chr(10), ' | '))",
    "else:",
    "    print('smi=<not found>')",
    sep = "\n")
  f <- tempfile(fileext = ".py")
  writeLines(code, f)
  # ⚠️ dsapp_exec_env() 返回的是**具名**向量（processx 的 env= 要这个形状），
  #    而 base::system2() 的 env= 要的是 "NAME=value" 字符串。
  #    直接把具名向量递过去 → "error in running command"，而且它不说为什么。
  #    空值要写成 `NAME=`（那正是"看得见 0 张卡"的表达方式），不能丢掉。
  env2 <- if (length(env)) paste0(names(env), "=", env) else character(0)
  out <- suppressWarnings(system2(PY, f, env = env2, stdout = TRUE, stderr = TRUE))
  paste(out, collapse = "\n")
}

say("\n  ---- gpu = FALSE（管理员明确关掉）----")
o_off <- probe_py(e_false)
for (ln in strsplit(o_off, "\n")[[1]]) say("    %s", ln)
chk("★★★ 关掉之后：子进程里 CUDA_VISIBLE_DEVICES 是**空串**",
    grepl("CUDA_VISIBLE_DEVICES=''", o_off, fixed = TRUE), o_off)
chk("★★★ 关掉之后：torch **看不见**卡（is_available() 为 False）",
    grepl("torch_cuda=False", o_off, fixed = TRUE) ||
      grepl("torch=<import failed", o_off, fixed = TRUE),
    "torch 那一行不在预期值上")

say("\n  ---- gpu = TRUE（管理员放行）----")
o_on <- probe_py(e_true)
for (ln in strsplit(o_on, "\n")[[1]]) say("    %s", ln)
chk("★★★ 放行之后：CUDA_VISIBLE_DEVICES **没有被设成空串**（不干预 = 全都看得见）",
    !grepl("CUDA_VISIBLE_DEVICES=''", o_on, fixed = TRUE), o_on)
chk("★★★ 放行之后：子进程真的看得见这张卡（nvidia-smi -L 有输出）",
    grepl("smi=GPU", o_on, fixed = TRUE) || grepl("smi=NVIDIA", o_on, fixed = TRUE),
    "smi 那一行不在预期值上")

# torch 是不是 CUDA 版 —— 这一条**不算失败**，但要如实报出来：
# 开关通了、卡也看得见，而环境里的 torch 是 CPU-only 的话，用户跑到
# torch.cuda.is_available() 还是会得到 False，而他会以为是开关没生效。
say("\n  ---- torch 编的是哪个版本（不影响开关，但影响用户能不能真用上）----")
torch_line <- grep("^torch=", strsplit(o_on, "\n")[[1]], value = TRUE)
torch_cuda <- grep("^torch_cuda=", strsplit(o_on, "\n")[[1]], value = TRUE)
say("    %s   %s", paste(torch_line, collapse = " "), paste(torch_cuda, collapse = " "))
if (length(torch_cuda) && identical(torch_cuda[[1]], "torch_cuda=False")) {
  say("    \033[33m⚠️\033[0m 这台机器看得见卡，但**这个 python 环境里的 torch 是"
      , "CPU 版** ——")
  say("       开关放行之后用户跑到 torch.cuda.is_available() 仍然会是 False。")
  say("       这不是开关的 bug，是环境里装的包不对（要装 CUDA 版的 torch）。")
}

# =============================================================================
# E 每账号那个开关（用户说的「入口」）
# =============================================================================
say("\n== E 入口：每账号的三态开关读写 ==")
# ⚠️ 直接用 SQL 建一行，不走 dsapp_user_create()：那个要昵称/手机/领域四件套，
#    校验规则以后还会变，而这里要的只是一个"能挂开关的账号"。
uid <- tryCatch({
  DBI::dbExecute(dsapp_db(cfg),
    "INSERT INTO users (email, nickname, created_at) VALUES (?, ?, ?)",
    params = list("gputest@example.com", "gputest", format(Sys.time())))
  DBI::dbGetQuery(dsapp_db(cfg),
    "SELECT id FROM users WHERE email = ?",
    params = list("gputest@example.com"))$id[[1]]
}, error = function(e) { say("    建账号失败：%s", conditionMessage(e)); NA_integer_ })
chk("★ 前提：测试账号建出来了（建不出来下面三态没法测）", !is.na(uid), "uid 没拿到")

if (!is.na(uid)) {
  rd <- function() dsapp_user_gpu_enabled(uid, con = dsapp_db(cfg))

  # ⚠️ 这个读取函数的三态是 TRUE / FALSE / **NA**，不是 NULL —— 我第一版按
  #    NULL 断言，红了，而去读它的说明才发现是**故意**的：返回 NA 而不是直接
  #    回落到平台默认，是为了让界面上「跟着平台」和「管理员关的」分得开。
  #    要"合并好的最终值"走 dsapp_limits_for_user()$gpu（下面几条测的就是它）。
  g0 <- rd()
  chk(paste0("★★★ 新账号读出来是 **NA**（= 没设过），而**不是** FALSE —— ",
             "「没说」和「说不许」在读出侧必须是两件事；混成一个就等于把",
             "没配过的账号全都按「禁止」处理"),
      identical(g0, NA), sprintf("读到的是 %s", deparse(g0)))
  chk("★★ 而且 NA 确实**不等于** FALSE（判据写成 isTRUE() 才分得开）",
      !identical(g0, FALSE))

  dsapp_user_set_gpu(uid, TRUE, con = dsapp_db(cfg))
  chk("★★ 写成 TRUE → 读回来是 TRUE", isTRUE(rd()), deparse(rd()))

  dsapp_user_set_gpu(uid, FALSE, con = dsapp_db(cfg))
  chk(paste0("★★★ 写成 FALSE → 读回来是 **FALSE**（不是 NA）—— 库里的 0 和 ",
             "NULL 必须分得开，否则「管理员关掉」会被当成「没设过」而跟着",
             "平台默认又打开"),
      identical(rd(), FALSE), sprintf("读到的是 %s", deparse(rd())))

  # ⚠️ 恢复默认走的是**另一个函数**。dsapp_user_set_gpu(id, NULL) 会把 NULL
  #    当成"不许用"（它只认肯定写法，认不出就当 FALSE），正好和"恢复默认"
  #    相反 —— 这两件事在界面上是两颗不同的按钮。
  dsapp_user_clear_gpu(uid, con = dsapp_db(cfg))
  chk("★★ 恢复平台默认 → 读回来又是 NA（不是被当成 FALSE 存下来）",
      identical(rd(), NA), sprintf("读到的是 %s", deparse(rd())))

  # ---- 用户真正会问的那件事：这一次到底能不能用卡 --------------------------
  # 执行链路读的是 dsapp_gpu_allowed()（= 账号值优先、没设过落回平台默认）。
  # 上面那些三态是"显示用"的，这一条才是"跑任务时用的"。
  def <- isTRUE(cfg$exec$gpu)
  say("  平台默认 DSAPP_EXEC_GPU = %s", def)
  chk("★★★ 没设过的账号 → 跟着平台默认（不是一律 FALSE）",
      identical(dsapp_gpu_allowed(uid, cfg = cfg, con = dsapp_db(cfg)), def),
      sprintf("拿到 %s，平台默认 %s", dsapp_gpu_allowed(uid, cfg = cfg, con = dsapp_db(cfg)), def))

  dsapp_user_set_gpu(uid, TRUE, con = dsapp_db(cfg))
  chk("★★★ 管理员明确放行 → 平台默认关着也照样能用（账号值优先）",
      isTRUE(dsapp_gpu_allowed(uid, cfg = cfg, con = dsapp_db(cfg))))

  dsapp_user_set_gpu(uid, FALSE, con = dsapp_db(cfg))
  chk("★★★ 管理员明确禁止 → 平台默认开着也不给用（0 不能被当成「没设过」）",
      identical(dsapp_gpu_allowed(uid, cfg = cfg, con = dsapp_db(cfg)), FALSE))
}

say("\n== 通过 %d / 失败 %d ==", NOK, nfail)
say("（数据根目录 %s，跑完可以整个删掉）", tmp)
quit(status = if (nfail == 0L) 0L else 1L)
