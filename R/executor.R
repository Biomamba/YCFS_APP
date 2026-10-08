# =============================================================================
# 代码执行层
# =============================================================================
# 三层防线（与 V1 一致）：
#   1. 静态扫描     —— scanner.R，提交前拦截明显高危指令
#   2. OS 资源限额 —— 本文件，通过 ulimit 限制 CPU 时间 / 内存 / 文件大小
#   3. 运行时隔离 —— 独立工作目录 + 净化环境变量 + 超时强杀进程组
#
# ⚠️ 必须清楚的边界：应用以 `shiny` 用户运行，代码也在 `shiny` 身份下执行。
# 所以"隔离"的强度等于 `shiny` 用户在系统上的权限 —— 能读的文件它都能读。
# 这不是容器级隔离。真要跑不可信代码，得把应用整体放进容器或虚拟机。
#
# 输入文件的处理是本层的重点：文件管理区的文件以**只读软链**进入工作目录。
# 因为 write.csv(df, "expr.csv") 这种"把结果写回输入同名文件"的写法太常见了，
# 而软链会穿透 —— 不加只读保护，用户上传的原始数据会被静默覆盖。
# =============================================================================

#' 进程额度被占满时，包装脚本给自己留的余量
#'
#' 见 dsapp_wrapper_script 里 `ulimit -u` 那一段。这个数决定"一个任务最少能
#' 新增多少个进程/线程"，取值要盖得住一次正常的 fork 洪峰（R 的 mclapply、
#' make -j、samtools sort -@ 之类），但不能大到让 fork 炸弹有恃无恐。
DSAPP_PROC_HEADROOM <- 64L

#' 探测解释器路径
#'
#' R 直接用 file.path(R.home("bin"), "Rscript")：这就是当前跑着应用的
#' 那个 R，版本和库路径必然一致。靠 PATH 找 Rscript 在 systemd/Shiny Server
#' 环境下经常找不到，或者找到另一个版本的 R，然后库对不上。
#'
#' env_name 非空时**只用**该 conda 环境里的解释器（见 envs.R）。
#'
#' ⚠️ 这里曾经是"找不到就回落到系统解释器"：选了个只装了 Python 的环境跑 R，
#' 会悄悄用系统 R 执行。本意是省事，实际是有害的 —— 用户在「分析环境」里
#' 明确选了这个环境，代码却跑在另一个解释器上，而且**不报错、不留痕**。
#' 用户看到的是"没有 DESeq2 这个包"（因为系统 R 里没装），离真正的原因
#' （跑错解释了）十万八千里，只会觉得应用坏了。
#'
#' 而且 envs.R 的 dsapp_env_summary() 早就把这类环境显示成
#' 「conda 环境 probe（Python）」—— 界面已经告诉用户这里没有 R 了，
#' 执行时又偷偷用系统 R，前后自相矛盾。
#'
#' 所以改成：选了环境就只认这个环境。缺什么解释器就报什么，
#' 由 dsapp_run_code() 给出「到「环境」页补装，或换种语言」的提示。
dsapp_interpreters <- function(cfg = dsapp_config(), env_name = NULL) {
  rscript <- file.path(R.home("bin"), "Rscript")

  py <- Sys.getenv("DSAPP_PYTHON", "")
  if (!nzchar(py)) {
    # ⚠️ Windows 上**没有** python3.exe —— 官方安装包给的是 python.exe，
    #    而 `py` 启动器才是最稳的那个（它认得所有已安装版本）。同一份候选
    #    列表在 Linux 上排前面的是 /usr/bin/python3，在 Windows 上那两个
    #    路径必然不存在，所以两边都列上、按顺序取第一个真的存在的。
    for (cand in c("/usr/bin/python3", "/usr/local/bin/python3",
                   Sys.which("python3"), Sys.which("python"),
                   Sys.which("py"))) {
      if (nzchar(cand) && file.exists(cand)) { py <- cand; break }
    }
  }

  env_bin <- ""
  if (!is.null(env_name) && nzchar(env_name) && !identical(env_name, "system")) {
    it <- dsapp_env_interpreters(env_name, cfg)
    # 赋值而不是"非空才覆盖"：空字符串 = 这个环境里没有该解释器，
    # 那就不该有解释器 —— 见上面 ⚠️ 的说明。
    rscript <- it$rscript
    py      <- it$python
    env_bin <- it$bin_dir
  }

  list(
    R      = if (file.exists(rscript)) rscript else NULL,
    Python = if (nzchar(py) && file.exists(py)) py else NULL,
    # Windows 上没有 /bin/bash（见 R/platform.R）。返回 NULL 之后，
    # 选 Bash 语言会走到"找不到解释器"那条正常提示上，而不是起一个
    # 不存在的路径然后报一句看不懂的 spawn 失败。
    Bash   = dsapp_bash_path(),
    # 前置到 PATH：conda 环境里装的不只是解释器，还有 samtools/bcftools
    # 这类命令行工具。不前置的话脚本里调用它们会 command not found。
    env_bin = env_bin
  )
}

#' 把代码块写入脚本文件
#'
#' name 默认 "main"：导出包和远程暂存目录里，这个文件名是给用户看的
#' （解压出来就是 main.R），别改。本地执行传 ".dsapp_main" —— 工作区是
#' 持久的，脚本留在那儿会让模型在文件清单里看见一个自己没写过的 main.R。
dsapp_write_script <- function(code, lang, workdir, name = "main") {
  ext <- switch(lang,
    R      = ".R",
    Python = ".py",
    Bash   = ".sh",
    ".R"
  )
  path <- file.path(workdir, paste0(name, ext))
  # useBytes：代码里可能有中文注释，不走本地编码转换，原样落盘
  con <- file(path, open = "wb")
  writeBin(charToRaw(enc2utf8(code)), con)
  close(con)
  path
}

#' 本次该用哪个 Python 解释器
#'
#' ⚠️ venv 就绪时必须用 `<venv>/bin/python3`，**不能**直接用基础解释器。
#'
#' 两者其实是同一个二进制 —— venv 里那个只是指向它的符号链接。区别在于
#' **怎么被调起来的**：Python 是靠"可执行文件旁边有没有 pyvenv.cfg"来判断
#' 自己在不在虚拟环境里的。直接 exec 基础解释器 → 找不到 pyvenv.cfg →
#' `sys.prefix` 指向 /usr，venv 里装的包一个都 import 不到。
#'
#' 症状是"我明明装了"：`pip install` 装得进去（PATH 里 venv 的 pip 排第一）、
#' `VIRTUAL_ENV` 也设了、`pip list` 也确实列得出来，**只有真正跑代码的那个
#' 解释器不知道自己该在 venv 里**。不打 `sys.prefix` 根本看不出来。
#'
#' @param base 基础解释器（interp$Python），venv 不可用时回落到它
#' @param libs dsapp_session_libs() 的结果
dsapp_pick_python <- function(base, libs) {
  if (!is.null(libs$venv_bin)) {
    p <- file.path(libs$venv_bin, "python3")
    if (file.exists(p)) return(p)
  }
  base
}

#' 生成带资源限制的包装脚本
#'
#' 为什么要包一层 bash 而不是直接 exec 解释器：ulimit 是 shell 内建命令，
#' processx 没法直接设。用 bash 设完再 exec，解释器就继承了这些限制。
dsapp_wrapper_script <- function(cmd, cfg = dsapp_config(), limits = NULL) {
  k <- if (is.null(limits)) cfg$exec else limits

  # ulimit -v 单位 KB；-t 单位秒；-f 单位 1024 字节块（bash 的规定）
  # 文件大小限制给 2GB，防的是"死循环往文件里写"把磁盘撑爆，
  # 不是限制正常的生信大文件产出。
  #
  # ⚠️ 这里不再直接读 cfg$exec：管理员可以给单个账号另设 CPU/内存/进程数
  #    上限（item 4，见 dsapp_limits_for_user）。合成好的那份从 limits 传进来，
  #    不传则回落平台默认 —— selftest 和几处旧调用点走的就是回落那条路。
  #
  # ⚠️⚠️ `ulimit -u` 那一段不能写成一句光秃秃的 `ulimit -u <N>`。
  #
  #    Linux 的 RLIMIT_NPROC 是**按 uid 全局**算的：内核数的是"这个真实 uid
  #    名下现在一共有多少个线程"，拿总数去比这个上限。而本应用是**一个 uid
  #    （shiny）跑所有人的代码** —— 所以这个上限的作用域不是"这一个任务"，
  #    是"这个应用在跑的所有东西"。
  #
  #    踩到它的样子（2026-09-14，自检里两条安装包的断言变红）：
  #    机器上该 uid 已经有 1500+ 个线程（开发机上是用户自己的进程；线上就是
  #    并发的其他任务）。这时把上限设成 512，连**一次** `pthread_create` 都
  #    过不去 —— R 一加载 OpenBLAS 就报
  #      "blas_thread_init: pthread_create failed ... Resource temporarily
  #       unavailable / RLIMIT_NPROC 512 current, 512 max"
  #    然后整个 install.packages() 失败。而报错里一个字的"配额"都没有，
  #    看起来像包本身坏了。
  #
  #    所以这里先量一下当前 uid 已经有几个线程，取
  #        _np = max(MAX_PROCS, 当前线程数 + 余量)
  #    当前数远小于 MAX_PROCS 时（正常情况），_np 就是 MAX_PROCS 本身，
  #    和以前一模一样；只有额度快被吃满时才会抬高 —— 那时能新增的只剩
  #    "余量"那么多，闸门依然在，只是不再是一道**必然失败**的闸门。
  #
  #    `ps -eL -o uid=` 数的是全系统的线程，用 uid 过滤出自己那份。这台机器
  #    1500 个线程时大约 30ms，相对于一次代码执行可以忽略。ps 不存在或者
  #    数不出来（_amb 非数字）就保持 MAX_PROCS 不动 —— 降级回旧行为，
  #    不能因为量不出来就干脆不设限。
  # ★★ V15.6 item 14：管理员可以把某一项设成「不限制」。落到这个模板上就是
  #    **那条 ulimit 换成 `unlimited`**（bash 内建认这个字面量）。
  #
  #    ⚠️⚠️ 三条死路，别走：
  #      · `ulimit -v 0`  —— 不是"不限制"，是"一个字节都不许分配"，
  #        任务起来的瞬间就死，而且死因看着像内存不够。
  #      · `ulimit -v NA`  —— dsapp_limits_for_user() 交出的是 Inf，
  #        而 `as.integer(Inf)` 是 NA + warning，sprintf("%d", NA) 写出
  #        `ulimit -v NA`。bash 报错 → 被后面的 `2>/dev/null || true` 吞掉
  #        → **限制静默消失**。碰巧等于不限制，但那是运气，不是设计：
  #        同样这条路径遇上别的解析失败就是"限制全没了"。
  #      · 整条不写 —— 一样是"没有限制"，但它和"我们忘了写"长得一模一样；
  #        写 `unlimited` 至少让读日志的人知道这是**有人选了不限制**。
  #
  #   ⚠️ 进程数那一条额外一层：`_amb` 那段唯一的用途是把 _np 抬到
  #      "当前线程数 + 余量"。不限制的时候它没有意义（抬到多少都不设限），
  #      所以整段不生成 —— 少一次 `ps -eL`（全系统扫一遍线程表）。
  unlim <- function(x) isTRUE(dsapp_limit_is_unlimited(x))

  proc_blk <- if (unlim(k$max_procs)) {
    'ulimit -u unlimited 2>/dev/null || true'
  } else {
    sprintf('\
# 该 uid 当前的线程数；量不出来就保持原上限
_amb=$(ps -eL -o uid= 2>/dev/null | grep -c "^[[:space:]]*$(id -u)[[:space:]]*$" 2>/dev/null || true)
_np=%d
case "$_amb" in
  ""|*[!0-9]*) ;;
  *) [ "$_amb" -gt 0 ] && [ $((_amb + %d)) -gt "$_np" ] && _np=$((_amb + %d)) ;;
esac
ulimit -u "$_np" 2>/dev/null || true
',
      as.integer(k$max_procs %||% cfg$exec$max_procs),
      DSAPP_PROC_HEADROOM, DSAPP_PROC_HEADROOM)
  }

  sprintf('\
%s
%s
ulimit -f %d 2>/dev/null || true
%s
ulimit -c 0 2>/dev/null || true
exec %s
',
    # 单位见上面那段（-v 是 KB、-t 是秒）；这两条正是"不限制"会换掉的。
    if (unlim(k$mem_mb)) 'ulimit -v unlimited 2>/dev/null || true'
      else sprintf('ulimit -v %d 2>/dev/null || true', as.integer(k$mem_mb) * 1024L),
    if (unlim(k$cpu_sec)) 'ulimit -t unlimited 2>/dev/null || true'
      else sprintf('ulimit -t %d 2>/dev/null || true', as.integer(k$cpu_sec)),
    2L * 1024L * 1024L,   # 2GB / 1KB 块
    proc_blk,
    cmd
  )
}

#' 净化环境变量
#'
#' 不净化的话，应用进程里的敏感变量（API Key、各类 token）会原样传给
#' 用户代码 —— 随便一句 print(Sys.getenv()) 就能读出来。
#' 只保留跑程序必需的最小集合。
#'
#' libs 是 dsapp_session_libs() 的结果（每对话增量库，见 envs.R）。它是
#' **叠加**在 env_bin 之上的：env_bin 决定"用哪个环境的基础"，libs 决定
#' "这个对话自己新装的东西放哪、从哪先找"。两者的顺序不能反。
#'
#' @param env_bin 选中的 conda 环境的 bin 目录，没有则 ""
#' @param libs    对话增量库，NULL 表示没有对话归属（selftest 等）
#' @param threads BLAS/OMP 线程数上限。NULL 表示取平台配置（cfg$exec$threads）。
#'        显式传值是为了让自检能钉住一个数去断言，不用去猜机器有几核。
#' @param gpu    ★ V14 item 7：这一次执行能不能用 GPU。
#'        **NULL = 不干预**（什么都不设，设备照常可见）—— 这是默认值，
#'        为的是让"和 GPU 无关的调用点"（remote.R 起 ssh 客户端、自检）
#'        保持原样，不因为多了个参数就悄悄改变行为。
#'        FALSE = 屏蔽掉所有 GPU 设备；TRUE = 显式放行（也不设变量）。
#' @param proxy  ★ Test_V16.3 item 2：用户自己填的代理（VPN）设置，
#'        dsapp_proxy_get() 的形状；NULL/没配 = 什么都不设。
#'        「访问境外**数据**」走的正是这一条：R 的 download.file()/curl、
#'        Python 的 requests/urllib/pip 认的是 http_proxy 这一族**环境变量**，
#'        不是 curl 选项 —— 光把 LLM 请求挂上代理，用户代码里那句
#'        `download.file(...)` 照样连不出去。
#'        ⚠️ 只作用于**用户那一段代码的子进程**（调用方把它塞进
#'           processx::process$new(env = ...)），不是 Sys.setenv，
#'           所以不会碰到别的用户、也不会碰到应用自己 —— 理由见 R/proxy.R
#'           顶部那条铁律。
dsapp_exec_env <- function(env_bin = "", libs = NULL, threads = NULL,
                           gpu = NULL, proxy = NULL) {
  keep <- c("PATH", "HOME", "LANG", "LC_ALL", "TZ", "TMPDIR", "USER", "SHELL")
  if (dsapp_is_windows()) {
    # ⚠️ Windows 上不能照搬上面那份名单：
    #    · `SystemRoot` 不给的话，子进程里有些 Winsock/加密相关的调用会直接
    #      失败（"the specified module could not be found" 之类），而报错
    #      指向的是 R 包内部，跟环境变量看着毫无关系；
    #    · 临时目录叫 TEMP/TMP，不叫 TMPDIR —— 少了它，R 会退回到 Windows
    #      目录下建临时文件，多用户机器上还会互相打架；
    #    · PATHEXT 不给，`python` 这种不带扩展名的调用在 cmd 里找不到
    #      （processx 直接 CreateProcess 时相对宽松，但用户的脚本里可能
    #      自己 system() 一层）；
    #    · USERPROFILE / HOMEDRIVE+HOMEPATH 是 Windows 版的 HOME，R 包
    #      （尤其是一堆要写缓存目录的）靠它定位。
    keep <- c(keep, "SystemRoot", "windir", "COMSPEC", "PATHEXT",
              "TEMP", "TMP", "USERPROFILE", "HOMEDRIVE", "HOMEPATH",
              "APPDATA", "LOCALAPPDATA", "NUMBER_OF_PROCESSORS",
              "PROCESSOR_ARCHITECTURE")
  }
  env <- Sys.getenv()[intersect(keep, names(Sys.getenv()))]
  # 强制 UTF-8，避免中文输出变乱码。
  # Windows 上不设这两项：那里的控制台代码页是另一套机制（chcp），
  # 设了 LANG 不起作用，反而让"到底哪边管编码"变得说不清。
  if (!dsapp_is_windows()) {
    loc <- dsapp_utf8_locale()
    env[["LANG"]] <- loc
    env[["LC_ALL"]] <- loc
  }

  # ---- 线程数：必须钉住，不能让库按核数自己开 ----
  #
  # 理由见 R/config.R 的 dsapp_default_threads()。一句话版：执行包装脚本里的
  # `ulimit -u` 在 Linux 上按 **uid** 全局算，而应用是一个 uid 跑所有人的代码，
  # 谁按核数开线程谁就在吃**别人**的进程额度。
  #
  # 这几个变量名要一起给：不同的数学库认不同的名字，而 R 里同一个矩阵运算
  # 可能落在 OpenBLAS / MKL / BLIS / Accelerate 里任意一个上（取决于这台
  # 机器上 R 是怎么编的）。少给一个，就是在那种机器上留一颗雷。
  # NUMEXPR 和 OMP 是 numpy / 各类多线程 C 库认的那两个。
  n <- suppressWarnings(as.integer(threads %||% dsapp_config()$exec$threads))
  if (is.na(n) || n < 1L) n <- 1L
  n <- as.character(n)
  for (k in c("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
              "BLIS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS",
              "OMP_THREAD_LIMIT")) {
    env[[k]] <- n
  }

  # ---- ★ V14 item 7：GPU 开关 -------------------------------------------
  #
  # 关掉时**不是**去拦"用户调 CUDA"这件事（拦不住：他可以起子进程、可以
  # 直接 dlopen libcuda），而是把**设备本身**从子进程的视野里拿掉。
  # 这是唯一一道既拦得住、又不会误伤的闸 —— 各家框架（PyTorch / TF / JAX /
  # cupy / RAPIDS）在初始化时都会读 CUDA_VISIBLE_DEVICES，拿到空串就
  # 一台设备都看不见，`torch.cuda.is_available()` 老老实实返回 False，
  # 代码自己就走 CPU 分支了。用户看到的不是"报了个看不懂的错"，
  # 而是"这段跑得慢"——这正是他该有的体验。
  #
  # ⚠️ 四个变量都要给。它们分属不同的运行时，而同一台机器上"哪个在用"
  #    取决于用户装了什么：
  #      CUDA_VISIBLE_DEVICES   NVIDIA（CUDA / PyTorch / TF / RAPIDS）
  #      NVIDIA_VISIBLE_DEVICES 容器运行时那条链（和上面不是一回事）
  #      ROCR_VISIBLE_DEVICES   AMD ROCm
  #      HIP_VISIBLE_DEVICES    AMD HIP
  #    少给一个，就是在"装了那套东西的机器上"留一个静默的口子。
  #
  # ⚠️⚠️ gpu = TRUE 时**一个变量都不设**，不要"设成 0"。
  #    CUDA_VISIBLE_DEVICES="0" 是"只看得见第 0 张卡"—— 在多卡机器上
  #    等于替用户做了一次选择，而他没有要求过。不设 = 全都看得见，
  #    这才是"允许使用"的字面意思。
  #
  # ⚠️ 只在 gpu 是**确定的逻辑值**时才动。传进来 NA（比如库读失败）时
  #    按"不干预"处理，不按 FALSE —— 静默屏蔽设备造成的现象是"任务突然
  #    跑不动了"，而它在界面上和"这次数据大"完全分不开。真要关，
  #    调用方得给出一个明确的 FALSE。
  #   ⚠️ 判据写成 `identical(gpu, FALSE)` 而不是 `!isTRUE(gpu)`：后者把
  #      NULL 和 NA 也当成"关"（见上一条）。只有调用方**明确**给出 FALSE
  #      才屏蔽。
  if (identical(gpu, FALSE)) {
    for (k in c("CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES",
                "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES")) {
      env[[k]] <- ""
    }
  }

  # ---- ★ Test_V16.3 item 2：用户填的代理 ----------------------------------
  #
  # 「访问境外**数据**」就是这一条：一段 `download.file("https://...")` 或者
  # `pd.read_csv("https://...")` 走的是 libcurl / requests，它们认的是
  # http_proxy / https_proxy / all_proxy 这几个**环境变量**，和 LLM 那边挂的
  # curl 选项毫无关系。少了这一段，用户填了代理之后会发现"AI 能回话了，
  # 但它下载数据还是失败"，而那个失败看起来像是数据源挂了。
  #
  # ⚠️ 只给这一个子进程。这不是 Sys.setenv —— 应用自己、别人的会话都读不到。
  #
  # ⚠️ 放在**最前面**：下面 PATH / R_LIBS_USER 那几段是"必须生效"的，
  #    而这一段只是"用户自己要的"，顺序上先来后到 —— 真撞名了（不可能）
  #    也该是 PATH 赢。
  if (!is.null(proxy)) {
    penv <- tryCatch(dsapp_proxy_env(proxy), error = function(e) character(0))
    for (k in names(penv)) env[[k]] <- penv[[k]]
  }

  if (nzchar(env_bin)) {
    env[["PATH"]] <- paste(env_bin, env[["PATH"]] %||% "/usr/bin:/bin", sep=":")
    # 让 conda 环境里的 Python 知道自己在哪个环境里。缺了它，
    # 某些包（尤其是依赖 sys.prefix 找数据文件的）会定位到别处。
    env[["CONDA_PREFIX"]] <- dirname(env_bin)
    env[["CONDA_DEFAULT_ENV"]] <- basename(dirname(env_bin))
  }

  if (!is.null(libs)) {
    # ---- R：对话自己的包目录 ----
    #
    # R 启动时读这个变量来构造 .libPaths()，且目录不存在会被静默丢掉 ——
    # 所以 .Rlib 一定是在起子进程之前就建好的（见 envs.R 顶部）。
    if (!is.null(libs$rlib)) env[["R_LIBS_USER"]] <- libs$rlib

    # ---- Python：对话自己的虚拟环境 ----
    #
    # 必须排在 env_bin **前面**：venv 里的 python/pip 是这次执行要用的，
    # conda 环境里那一份只是它继承来的基础。反过来的话 pip install 会装进
    # conda 环境 —— 那是所有对话共用的地方，正是要避免的。
    if (!is.null(libs$venv_bin)) {
      env[["PATH"]] <- paste(libs$venv_bin,
                             env[["PATH"]] %||% "/usr/bin:/bin", sep = ":")
      # pip 和一堆构建工具靠它认 venv。不设的话 pip 会去 sys.prefix 找，
      # 而我们是直接 exec 解释器、没跑 activate，它认不出来。
      env[["VIRTUAL_ENV"]] <- libs$venv
    }

    # ---- 回落：venv 建不出来时的 .pylib ----
    #
    # PIP_TARGET 把 pip 的安装目标钉在对话目录里（不设的话它会写 ~/.local，
    # 那是所有对话共用的）。PYTHONPATH 让装进去的包能被 import 到。
    if (!is.null(libs$py_target)) {
      env[["PIP_TARGET"]] <- libs$py_target
      env[["PYTHONPATH"]] <- libs$py_target
    }
  }

  env
}

#' 从输出里解析进度标记
#'
#' 提示词要求模型打印 `PROGRESS: 42`。取最后一个匹配值 —— 日志是追加的，
#' 最后一个才是当前进度。
dsapp_parse_progress <- function(text) {
  if (is.null(text) || !nzchar(text)) return(NULL)
  m <- regmatches(text, gregexpr("PROGRESS:\\s*(\\d{1,3})", text))[[1]]
  if (length(m) == 0) return(NULL)
  v <- suppressWarnings(as.integer(sub(".*?(\\d{1,3}).*", "\\1", m[length(m)])))
  if (is.na(v)) return(NULL)
  max(0L, min(100L, v))
}

#' 执行一段代码
#'
#' 阻塞调用。**必须在后台进程里跑**（见 app.R 里的 ExtendedTask），
#' 否则会卡死整个 Shiny 进程，其他用户的页面全部无响应。
#'
#' session_id 决定在哪个工作区里跑（见 utils.R 的 dsapp_ws_dir）。会给
#' NA 的调用方只有两个：老的 selftest，和没有对话归属的任务 —— 这两种
#' 情况回落到一次性的 task-<id> 目录，行为和改造前一致。
#'
#' @return list(status, exit_code, stdout, stderr, workdir, artifacts, progress)
dsapp_run_code <- function(code, lang = "R", task_id,
                           cfg = dsapp_config(),
                           extra_files = character(0),
                           env_name = NULL,
                           session_id = NA_integer_) {
  # ★ V13 item 6：镜像进工作区的"上传文件"必须是**这个对话主人的**管理区
  #   （下面 dsapp_mirror_shared(cfg$files_dir, workdir) 那一步）。不重绑的话
  #   镜像源是 _anon，工作区里一个输入文件都没有 —— 而模型看到的清单
  #   （prompts.R 的 build_file_section，那边也会重绑）里写着有，于是它会去
  #   read.csv("expr.csv")，拿到 "No such file"，然后反复重试同一段代码。
  #   ★ 这两处必须绑到同一个人身上，否则症状是"清单里有、文件读不到"。
  cfg <- dsapp_config_sid(session_id, cfg)
  interp <- dsapp_interpreters(cfg, env_name)

  # ---- 每对话增量库（见 envs.R 顶部）----
  #
  # ⚠️ 必须在挑解释器**之前**算。Python 的 .venv 一旦就绪，本次就该用 venv
  #    里的解释器跑，而不是基础解释器（理由见 dsapp_pick_python 的 ⚠️）。
  #    同时它也得赶在起子进程之前做完：R 是在启动时读 R_LIBS_USER 构造
  #    .libPaths() 的，目录不存在的那一项会被**静默丢掉**。
  #
  # 按语言按需建：只跑 R 的对话不该为 .venv 那 4 秒买单。
  # base_python 传 interp$Python 而不是重新探测一次 —— venv 必须用**真正
  # 执行这段代码的那个解释器**来建，否则会有两个 Python 打架。
  libs <- dsapp_session_libs(session_id, cfg, lang, base_python = interp$Python)

  # 这个任务是谁发起的 → 他能占多少机器。
  # 拿到之后**先算好**一份合并过的上限（管理员设的优先，没设的用平台默认），
  # 后面 wrapper 直接用。放在这里而不是写在 dsapp_wrapper_script 里：
  # 那个函数是纯函数，selftest 会直接调它，不该让它去碰数据库。
  limits <- tryCatch(
    dsapp_limits_for_user(db_session_owner(session_id, con = dsapp_db()), cfg),
    error = function(e) NULL)

  # ★ V14 item 7：这一次执行能不能用 GPU。
  #
  # 合成发生在 dsapp_limits_for_user() 里（用户没单独设过 → 取平台默认
  # DSAPP_EXEC_GPU），这里只负责把它变成 dsapp_exec_env() 要的那个口吻：
  # **确定的逻辑值**，不是 NULL。传 NULL 是"不干预"，那等于把开关架空。
  #
  # ⚠️ limits 取不到（上面 tryCatch 吞了异常）时按 FALSE 走，也就是屏蔽设备。
  #    机器上 GPU 是最稀缺的东西，而"读不出来"最可能的原因恰恰是数据库不稳
  #    —— 那种时刻更不该放开。这和 dsapp_task_slot_busy 那边"查不出来就按
  #    最保守的一边"是同一个取向。
  gpu_ok <- isTRUE((limits %||% list())$gpu)

  cmd_bin <- switch(lang,
    R      = interp$R,
    Python = dsapp_pick_python(interp$Python, libs),
    Bash   = interp$Bash,
    interp$R
  )
  if (is.null(cmd_bin)) {
    # 报错要指向**下一步动作**，而不是只描述现状。这里最容易混的两种情况：
    # 环境整个没了（被删了/名字拼错了），和环境下缺这个语言的解释器 ——
    # 处理方式完全不同，所以分开说。
    hint <- if (!is.null(env_name) && nzchar(env_name) && !identical(env_name, "system")) {
      if (!dsapp_env_exists(env_name, cfg)) {
        sprintf("选定的 conda 环境 %s 不存在（可能已被删除）。请到「设置 → 硬件选择」重新选一个。",
                env_name)
      } else {
        other <- if (identical(lang, "R")) "Python" else "R"
        sprintf("环境 %s 里没有 %s 解释器，代码没有执行。到「环境」页给它补装，或把这个代码块的语言改成 %s。",
                env_name, lang, other)
      }
    } else {
      sprintf("找不到 %s 解释器", lang)
    }
    return(list(status = "error", exit_code = NA_integer_,
                stdout = "", stderr = hint,
                workdir = NA_character_, artifacts = character(0),
                progress = NULL, env_notes = character(0),
                bad_artifacts = character(0)))
  }


  # ---- 工作目录 ----
  #
  # ⚠️ 这里曾经是 work/task-<id>/，并且**每次执行先 unlink 再重建**。
  #    那个模型下一次执行看不见上一次的任何东西，产物只能靠拷回全局共享区
  #    来传递 —— 而共享区是全应用一份，于是"谁都能看见谁的中间文件"。
  #
  # 现在改成对话工作区（utils.R 的 dsapp_ws_dir），持久、可写：
  #   * 第 2 轮能直接读到第 1 轮写出的文件，"接着上一步继续"才成立
  #   * 产物默认留在里面，不再自动外溢到共享区
  #   * 别人的对话有自己的目录，踩不到这里
  #
  # 没有对话归属的任务（selftest 等）回落到老路径，行为不变。
  workdir <- if (is.na(session_id)) {
    d <- file.path(cfg$work_dir, paste0("task-", task_id))
    if (dir.exists(d)) unlink(d, recursive = TRUE)
    d
  } else {
    dsapp_ws_dir(session_id, cfg)
  }
  dir.create(workdir, recursive = TRUE, showWarnings = FALSE)

  # ---- 挂入上传区的文件（只读软链）----
  # 软链而不是复制：生信数据动辄几个 G，每次执行都复制一份既慢又占空间。
  #
  # ⚠️ 只读保护**不在这里做**。这里曾经对每个文件 Sys.chmod(src, "0444")，
  #    那是让每一次代码执行都去改全局上传区的权限 —— 任务在写共享状态。
  #    现在改成上传落盘时就设成 0444（见 files.R），保护一样在，但只做一次。
  #
  # V5 起共享区有子目录，所以这里换成递归镜像：**目录真建、文件才软链**
  # （理由见 files.R 的 dsapp_mirror_shared —— 一句话：软链目录会穿透写，
  # 一个对话就能往公共共享区里写东西）。
  #
  # 先清断链再挂：共享区里删掉的文件，工作区里那条链就悬空了，会被
  # 当成 0 字节产物列到界面上（见 dsapp_ws_prune_links）。
  dsapp_ws_prune_links(workdir, cfg)
  mirror <- dsapp_mirror_shared(cfg$files_dir, workdir)
  for (f in extra_files) {
    fs <- dsapp_rel_segments(f)
    if (is.null(fs) || !length(fs)) next
    src <- dsapp_path_in(cfg$files_dir, fs, must_exist = TRUE)
    if (is.null(src) || !file.exists(src)) next
    dst <- file.path(workdir, paste(fs, collapse = "/"))
    if (file.exists(dst) || dsapp_is_link(dst)) next
    dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
    # 软链优先，Windows 上建不了链就复制（理由见 R/platform.R）
    dsapp_place_input(src, dst)
  }

  # ---- 技能自带的配套文件（V13.12 item 13）----
  #
  # 一个技能可能是一整个文件夹（SKILL.md + templates/ + references/），正文里
  # 写着"参考 templates/R语言教程 下的文档"。那些文件存在库里、不铺进来的话，
  # 模型拿到的是一个**不存在的路径** —— 它会先报文件不存在，然后自己编一套
  # 模板出来，而用户以为自己已经把这个规范交给它了。
  #
  # ⚠️ 位置必须在**下面那次快照之前**：快照之后再铺，铺出来的文件会被算成
  #    "这次任务的产物"，同步进文件管理区 —— 用户会看到一堆 templates 冒出来
  #    当成自己的成果。铺在快照前，它就是"执行前就有的东西"，和软链进来的
  #    上传文件是同一个待遇。
  #
  # ⚠️ 整段包 tryCatch：技能铺不出来只是"这条技能少了个附件"，绝不能因此
  #    让整个任务起不来。
  if (!is.na(session_id)) {
    tryCatch(dsapp_skill_files_materialize(session_id, workdir, con = dsapp_db(cfg)),
             error = function(e) NULL)
  }

  # ---- 执行前的快照（用来算这次到底产出了什么）----
  #
  # 工作区是持久的，所以"执行完 list.files() 一遍"会把**历史上所有**产物
  # 都算成这一次的。必须前后各拍一张取差集。
  #
  # ⚠️ 必须在挂完软链**之后**拍。软链是这次刚建出来的，拍早了它们就会
  #    出现在差集里，被当成本次产物报到界面上。
  #
  # ⚠️ 递归拍，不是只拍顶层。共享区有子目录之后工作区也有子目录，只拍顶层
  #    的话模型写进 `results/` 的图在产物清单里会缩成一条 "results"。
  #    find 不匹配软链（它 lstat，不跟），镜像进来的只读输入自动被排除，
  #    不用额外过滤。
  #
  # ⚠️ `dirs = TRUE` 要和下面收尾那次**保持一致**（V8 item 7）：两次拍的
  #    范围不一样，差集里就会混进一堆"本来就存在、只是上次没拍"的目录，
  #    被记成这次任务的产物。反过来也一样。这是最容易改漏的一处 ——
  #    改一个忘一个，表现是旧任务的分组里凭空多出几个不相干的文件夹。
  #
  # ⚠️ 拍的是**带戳快照**（mtime + size），不是光有名字的清单。差集要能看出
  #    "这个文件被改写过了" —— 重跑一遍脚本不产生任何**新**文件名，而 V12
  #    起产物要自动同步到共享区，只看新名字的话共享区里会一直留着上一轮的
  #    旧数据。详见 dsapp_ws_stamp 的说明。
  before <- dsapp_ws_stamp(workdir)

  # ---- 落盘脚本并执行 ----
  # name 用 .dsapp_main 而不是 main：工作区是持久的，一个叫 main.R 的文件
  # 会留在那儿被模型看见，而它不是模型写的、也不是用户给的。
  script <- dsapp_write_script(code, lang, workdir, name = ".dsapp_main")
  wrapper <- file.path(workdir, ".dsapp_run.sh")
  cmd_str <- sprintf("%s %s", shQuote(cmd_bin), shQuote(basename(script)))
  # 按任务发起人取资源上限（item 4）。取不到发起人（无主任务、对话已删）
  # 就整个走平台默认 —— dsapp_limits_for_user 里已经把这条兜住了。
  writeLines(dsapp_wrapper_script(cmd_str, cfg, limits = limits), wrapper)

  out_file <- file.path(workdir, ".dsapp_stdout")
  err_file <- file.path(workdir, ".dsapp_stderr")

  # ---- 起进程：有 bash 就走包装脚本，没有就直接 exec 解释器 ----
  #
  # ⚠️ Windows 上没有 bash（见 R/platform.R），`command = "/bin/bash"` 会让
  #    **每一次执行**都失败，而 processx 报的是
  #    "Failed to create process ... 系统找不到指定的文件"，
  #    看起来像解释器路径写错了。所以这里分支，而不是硬写 /bin/bash。
  #
  # ⚠️ 直接 exec 这条路**没有** ulimit（CPU 时间/内存/进程数上限）。这是
  #    Windows 上真没了的东西，不是"以后再说"：界面上要如实告诉用户
  #    （见 dsapp_platform_note）。超时仍然管着 —— processx 的定时强杀
  #    是 R 这边做的，和 ulimit 无关。
  bash <- dsapp_bash_path()
  # ★ Test_V16.3 item 2：发起这段代码的人自己填的代理（VPN）。两条分支
  #   （bash 包装 / 直接 exec）都要带上 —— 只给一条的话，Windows 上
  #   （没有 bash，永远走 else 那条）代理会静默失效，而报出来的是
  #   "数据下载失败"，指不到这里。默认 NULL，没配就是什么都不设。
  exec_proxy <- tryCatch(dsapp_proxy_for(dsapp_cfg_uid(cfg)), error = function(e) NULL)
  p <- if (!is.null(bash)) {
    processx::process$new(
      command = bash,
      args = basename(wrapper),
      wd = workdir,
      stdout = out_file,
      stderr = err_file,
      env = dsapp_exec_env(interp$env_bin, libs, threads = cfg$exec$threads,
                           gpu = gpu_ok, proxy = exec_proxy),
      # 建独立进程组，超时时能连同子进程一起杀干净。
      # 不这么做的话，脚本 fork 出去的后台进程会活下来继续吃资源。
      cleanup_tree = TRUE
    )
  } else {
    processx::process$new(
      command = cmd_bin,
      # 不走 shell 就不能 shQuote：引号会原样变成文件名的一部分。
      args = basename(script),
      wd = workdir,
      stdout = out_file,
      stderr = err_file,
      env = dsapp_exec_env(interp$env_bin, libs, threads = cfg$exec$threads,
                           gpu = gpu_ok, proxy = exec_proxy),
      cleanup_tree = TRUE
    )
  }

  # ⚠️ processx 的 $wait() 返回的是**进程对象本身**（为链式调用设计），
  # 不是逻辑值。写成 `finished <- p$wait(...)` 然后 `if (!finished)` 会报
  # "invalid argument type"，而且每次都报 —— 所有执行都会失败。
  # 判断有没有跑完只能看 is_alive()。
  p$wait(timeout = cfg$exec$timeout * 1000)
  finished <- !p$is_alive()
  timed_out <- FALSE

  if (!finished) {
    timed_out <- TRUE
    p$kill()
    # 给它 2 秒收尾，还没死就强杀
    if (p$is_alive()) {
      Sys.sleep(2)
      if (p$is_alive()) try(p$kill(close_connections = TRUE), silent = TRUE)
    }
  }

  exit_code <- p$get_exit_status()

  # ---- 收集输出 ----
  # 只读末尾：脚本可能打印了几十 MB，全读进来会把内存撑爆。
  #
  # ⚠️ 截断一律留**末尾**（keep = "tail"）。这里以前是留开头的，
  #    而这两步是叠加的："先读末尾 4MB，再保留这 4MB 的开头 512KB" ——
  #    等于取了原始输出的中间一段，两头都不是。脚本跑十分钟然后报错时，
  #    屏幕上最后那句 "Error in ..." / "Traceback" 正好被切掉，留给人
  #    （和模型）的是一堆正常的日志。R 和 Python 的报错都在最末尾，
  #    所以这里必须留尾巴。
  stdout_raw <- dsapp_tail(out_file, n = 5000, max_bytes = 4 * 1024 * 1024)
  stderr_raw <- dsapp_tail(err_file, n = 5000, max_bytes = 1024 * 1024)

  stdout <- dsapp_truncate(stdout_raw, cfg$exec$max_output_kb, keep = "tail")
  stderr <- dsapp_truncate(stderr_raw, cfg$exec$max_output_kb, keep = "tail")

  if (timed_out) {
    stderr <- paste0(stderr, sprintf(
      "\n\n[已强制终止] 运行超过 %d 秒的墙钟上限。\n",
      as.integer(cfg$exec$timeout)))
  }

  # ---- 产物清单 ----
  #
  # 差集，不是"列一遍目录"。工作区是持久的，直接 list 会把这个对话历史上
  # 所有产物都算成这一次的，界面上就会看到一堆和本次执行无关的文件。
  #
  # 名字是**相对工作区的路径**，子目录里的产物带上目录前缀 —— 只给一个
  # basename 的话，两个不同目录下的 plot.png 在卡片上长得一模一样。
  # dirs = TRUE：新造的目录也算这次产出（V8 item 7）。只算文件的话，
  # `dir.create("16S分析/测试文件夹")` 这种"只建目录、还没往里写东西"的
  # 步骤在任务记录里是空白 —— 而模型接下来那轮很可能就是往这个目录里写，
  # 用户回头翻任务时看不到目录是什么时候、由哪一步建的。
  #
  # ★ V12 item 3 起差集**还包括被改写的文件**（dsapp_ws_diff，判据是
  #   mtime/size）。重跑同一个脚本不产生新文件名，但它的产物必须跟着更新
  #   —— 共享区里那一份要覆盖，而不是永远停在第一轮的结果上。
  artifacts <- dsapp_ws_diff(before, dsapp_ws_stamp(workdir))
  # 我们自己塞进去的文件不算产物。它们在快照里本来就是 .dsapp_ 开头的
  # 隐藏文件，find 会列出来（find 不看隐藏属性），所以这里必须挡。
  artifacts <- artifacts[!dsapp_ws_is_internal(artifacts)]
  # 上限。一个批量脚本可能产出几千个文件（每个样本一张图），全塞进任务
  # 记录里既写爆 JSON 又没人看得完。超了如实说 —— 静默截断会让人以为
  # "这次只产出了 200 个"。
  #
  # ⚠️ 数的是"项"（文件 + 目录），不再只数文件。计数不变的话，界面上
  #    "本次产出 N 个文件"和列表里实际的行数会对不上（目录也占行）。
  DSAPP_ARTIFACT_MAX <- 200L
  dropped <- max(0L, length(artifacts) - DSAPP_ARTIFACT_MAX)
  if (dropped > 0L) artifacts <- utils::head(artifacts, DSAPP_ARTIFACT_MAX)

  status <- if (timed_out) {
    "timeout"
  } else if (identical(exit_code, 0L)) {
    "success"
  } else {
    "failed"
  }

  # 如实说明这一次**没有**完全按预期做的事。执行本身成功，所以不能塞进
  # stderr 冒充报错 —— 调用方决定怎么显示（见 jobs.R / app.R / agent.R）。
  notes <- libs$notes
  if (mirror$deep > 0L) {
    notes <- c(notes, sprintf(
      "共享区里有 %d 个目录超过 8 层，没有挂进工作区，里面的文件这次读不到",
      mirror$deep))
  }
  if (dropped > 0L) {
    notes <- c(notes, sprintf(
      "本次产出 %d 项，清单只列了前 %d 项（文件都在工作区里，没有丢）",
      length(artifacts) + dropped, DSAPP_ARTIFACT_MAX))
  }

  # ★ V13.12 item 8：产物体检。见 dsapp_artifact_check() 上面那一段。
  #   ⚠️ 单独一列，**不**并进 env_notes：env_notes 那一摞讲的是"共享区深度"
  #      "清单截断"这种平台自己的碎碎念，渲染成一行灰字；而这里报的是
  #      "这次的分析结论底下没有数据"，要红着脸说出来，而且要让模型看见
  #      自己去修（item 12）。两者混在一起，前者会把后者淹掉。
  # ★ V15.5 item 12：图上画成方框的字（判据在 stderr 里，matplotlib 自己报的）
  #   和空表那条**并进同一个字段**：下游（jobs.R / taskrun.R / agent.R /
  #   render.R）已经有一整条"把它摆到模型眼前"的链路，新开一个字段要在四个
  #   文件里各加一遍，漏一处就是静默不显示。
  #   ⚠️ 两件事的**入口是同一个函数**（dsapp_bad_artifacts），别再在这里
  #      就地 c() 拼接 —— 那样 agent.R 的两条回喂路会再次漏掉新加的那一类。
  bad_artifacts <- dsapp_bad_artifacts(artifacts, workdir, stderr)

  list(
    status     = status,
    exit_code  = exit_code,
    stdout     = stdout,
    stderr     = stderr,
    workdir    = workdir,
    artifacts  = artifacts,
    progress   = dsapp_parse_progress(stdout_raw),
    env_notes  = notes,
    bad_artifacts = bad_artifacts
  )
}

#' 产物体检：这次新产出的文件里，有没有"其实是空的"
#'
#' ★ V13.12 item 8 加的。
#'
#' 用户原话：「"生成分析GLM测试"，这个任务生成出来的很多文件只有表头，
#' 看一下是哪里出了问题，需要架构优化的话请执行」。
#'
#' ---- 现场（data/workspaces/chat-s-20260924135330-0641/tp53_sclc/）--------
#'
#'   tables/sclc_ucologne_2015_tp53_expr.csv   73 字节，`wc -l` = 1
#'   …同样的还有另外 4 个研究的 *_tp53_expr.csv，一共 5 个
#'   raw/sclc_ucologne_2015_tp53_expr.json     **2 字节** —— 就是 `[]`
#'
#' 链路很清楚：cBioPortal 对"这个研究没有这个分子谱"的组合返回一个空数组，
#' 脚本照常 write.csv()，写出一个只有表头的文件；退出码 0，status = success。
#' 平台只看退出码，于是"5 个文件全是空壳"被报成了成功，一路摆到产物清单里。
#' 用户是在报告里看到"候选 98 条 → 剔除后剩 111 条"这种对不上的数字，
#' 才回过头发现底下几张表根本没数据。
#'
#' ---- 为什么这笔账要记在平台这一层，而不是只写进提示词 --------------------
#'
#' 提示词只能**劝**模型"写之前判一下空"，而这件事平台自己就能查，判据还是
#' 确定的：一个 CSV 只有一行就是没有数据。放在执行收尾这里做，不管模型换
#' 什么写法、用什么语言、甚至用户自己贴一段脚本进来手跑，都盖得住。
#' 提示词是劝告，这里是闸门。
#'
#' ⚠️ 只查**这次新产出的**文件（差集已经算好了），不扫全盘：工作区是持久的，
#'    历史上那些空文件早就写下了，每次执行都重报一遍等于天天喊狼来了，
#'    喊到用户对这个提示免疫为止。
#' ⚠️ 只读每个文件的**头两行**，不整份读进来 —— 产物里可能有几个 G 的矩阵。
#' ⚠️ 判据宁可漏、不可错杀：只报"确定是坏的"三种（0 字节 / 有分隔符的单行
#'    表格 / 空 JSON）。一个只有一行的 .txt 日志完全可能是正常的，不报。
#'
#' @param files   差集算出来的产物名（相对工作区）
#' @param workdir 工作区绝对路径
#' @return character(0)（都没问题）或一串给人/给模型看的问题描述
#' @noRd
dsapp_artifact_check <- function(files, workdir, max_check = 60L) {
  files <- as.character(files %||% character(0))
  files <- files[!is.na(files) & nzchar(files)]
  if (!length(files) || is.null(workdir) || is.na(workdir) ||
      !dir.exists(workdir)) {
    return(character(0))
  }
  # 只看文件，不看目录（"只建了目录"是正常的中间状态，见 dsapp_ws_snapshot）
  full <- file.path(workdir, files)
  fi <- file.info(full)
  keep <- !is.na(fi$isdir) & !fi$isdir
  files <- files[keep]; full <- full[keep]
  if (!length(files)) return(character(0))

  # 超出上限就**说明白**没查完，不要静默截断 —— 静默截断会让人以为
  # "没报问题 = 都查过了"。
  skipped <- 0L
  if (length(files) > max_check) {
    skipped <- length(files) - max_check
    files <- utils::head(files, max_check)
    full  <- utils::head(full, max_check)
  }

  # 表头类：这两类才谈得上"只有表头"。.txt 故意不在里面 —— 一行的日志、
  # 一行的时间戳、一行的说明都是正常的，收进来只会天天误报。
  tab_like <- grepl("\\.(csv|tsv|tab)$", files, ignore.case = TRUE)
  json_like <- grepl("\\.json$", files, ignore.case = TRUE)

  bad <- character(0)
  for (i in seq_along(files)) {
    sz <- tryCatch(file.info(full[i])$size, error = function(e) NA_real_)
    if (is.na(sz)) next
    # 0 字节：不管什么后缀都是坏的（空 png、空 pdf 一样打不开）
    if (sz == 0) {
      bad <- c(bad, sprintf("- %s：0 字节，是个空文件", files[i]))
      next
    }
    if (json_like[i]) {
      # ⚠️ JSON 通常很小才需要看内容；大文件直接跳过（不可能是 `[]`）
      if (sz <= 64) {
        head_txt <- tryCatch(paste(readLines(full[i], n = 1L, warn = FALSE),
                                   collapse = ""),
                             error = function(e) NA_character_)
        if (!is.na(head_txt) && grepl("^\\s*(\\[\\s*\\]|\\{\\s*\\}|null)\\s*$",
                                      head_txt, perl = TRUE)) {
          bad <- c(bad, sprintf("- %s：内容是空的（%s），上游什么都没返回",
                                files[i], trimws(head_txt)))
        }
      }
      next
    }
    if (!tab_like[i]) next
    # ⚠️ 读 5 行而不是 2 行：有的导出工具会在最前面留一个空行，只读两行
    #    就会把"空行 + 表头"看成"只有表头"，把一份正常文件报成空的。
    #    多读三行的代价可以忽略（这里本来就只读开头）。
    lines <- tryCatch(readLines(full[i], n = 5L, warn = FALSE),
                      error = function(e) character(0))
    lines <- lines[nzchar(trimws(lines))]
    if (length(lines) == 0L) {
      bad <- c(bad, sprintf("- %s：%s 字节，但一行内容都没有", files[i],
                            format(sz, big.mark = ",")))
      next
    }
    # 只有一行、而且那行里有分隔符 —— 那就是一个表头后面没有数据。
    #
    # ⚠️ 要求"有分隔符"是**故意**的：单列无表头的清单（一行一个基因名）
    #    是合法产物，不看分隔符就会把它误判成空表。宁可漏，不可错杀。
    if (length(lines) == 1L &&
        grepl(",|\t|;", lines[1]) &&
        !grepl("^\\s*#", lines[1])) {
      bad <- c(bad, sprintf("- %s：只有表头、没有数据行（%s 字节）",
                            files[i], format(sz, big.mark = ",")))
    }
  }

  if (skipped > 0L) {
    bad <- c(bad, sprintf("- （另有 %d 个本次产出的文件没有体检，只查了前 %d 个）",
                          skipped, max_check))
  }
  bad
}

#' 图里的文字有没有画成方框（★ V15.5 item 12）
#'
#' 用户拿着这样一张图来的：一张横向条形图，**每一个中文标签都是一个空心
#' 方框**，英文和数字都好好的。任务状态 success、文件也在工作区里，从执行
#' 结果里看不出任何异常。
#'
#' 提示词那一边已经改了三条（代码铁律规则 11、技能文档里的字体清单、
#' 画完自查）。**但提示词只能劝** —— 这件事平台自己就能查，而且判据是确定的：
#' matplotlib 画不出字形时会往 stderr 打一行
#' `UserWarning: Glyph 25968 (\N{CJK UNIFIED IDEOGRAPH-6570}) missing from
#' current font.`，那行字就在我们已经收下来的 stderr 里。
#'
#' ⚠️ 所以这一条和 dsapp_artifact_check() 一样，是**闸门**不是劝告：不管模型
#'    换什么写法、用什么库、甚至用户自己贴一段脚本进来手跑，只要画出了方框，
#'    下一次模型看到的执行结果里就有这一节。见 R/agent.R 里那段说明。
#'
#' ⚠️ 只认 matplotlib 这句原文。别的库（plotnine 底层还是 matplotlib，能盖住；
#'    R 的 cairo 设备不打这种警告）各有各的报法，没有确定的判据就**不猜** ——
#'    宁可漏报，也不要把"某个库打了一句含 font 的普通日志"报成"图坏了"。
dsapp_font_glyph_check <- function(stderr) {
  s <- paste(as.character(stderr %||% ""), collapse = "\n")
  if (!nzchar(s)) return(character(0))
  # ⚠️ 这里的写法**必须**同时盖住 matplotlib 的两代措辞 —— 只认一句的话，
  #    换一个版本这条闸门就变成静默失效（不报错、不显示、自检照绿）：
  #      3.8 及以前：`Glyph 25968 (…) missing from current font.`
  #      3.9+（本机 3.11.1 实测）：`Glyph 25968 (…) missing from font(s) DejaVu Sans.`
  #    实测 3.11.1 那句话里**没有** "current"，写成旧措辞在这台机器上是死代码。
  #   ⚠️ 也别指望"取公共子串 missing from font"能一举两得 —— 旧那句是
  #      `missing from **current** font`，中间那个词一插，公共子串根本不连续。
  #      （这是我自己先写错、被自检抓住的一版。）所以写成 `(current )?` 可选。
  hits <- regmatches(s, gregexpr("Glyph [0-9]+[^\n]*missing from (current )?font",
                                 s, perl = TRUE))[[1]]
  if (!length(hits)) return(character(0))
  # 去重：同一个字每画一次就报一次，一张图能报几百行 —— 全贴给模型是纯噪声，
  # 而它要的信息只有"有几个字没画出来"。
  n <- length(hits)
  uniq <- unique(sub("^Glyph ([0-9]+).*$", "\\1", hits))
  sprintf(paste0(
    "- ⚠️ 本次生成的**图里有字没画出来**（是方框，不是字）：",
    "matplotlib 报了 %d 次 「missing from font」警告",
    "（这些字当前用的字体里没有），涉及 %d 个码位（%s）"),
    n, length(uniq), paste(utils::head(uniq, 8), collapse = ", "))
}

#' 产物体检的**唯一入口**：空表 + 图里的方框，两件事一起查
#'
#' ★ V15.5 item 12 的后半段。这段说明要说清楚，因为它是"闸门写好了却没接上"
#' 这类事故的现场记录：
#'
#' `dsapp_font_glyph_check()` 一开始只挂在 executor.R 的收尾函数里，而**模型
#' 真正看到的那两段回喂文本并不用它** —— agent.R 里两条路（`dsapp_task_result_text`
#' 给历史任务重跑、`a$feed_result` 给循环里的每一轮）都是**各自重算**一遍
#' `dsapp_artifact_check()`。于是字体那条结论只活在收尾函数的返回值里，而那个
#' 返回值在 app.R 的轮询里被丢掉了 —— 一道谁也没看见的闸门。
#'
#' ⚠️ 所以判据只留一个函数：以后不管是"再加一类体检"还是"再多一条回喂路"，
#'    都从这里走。分头拼 `c(dsapp_artifact_check(...), 新检查(...))` 的做法
#'    已经栽过一次了 —— 加的人只会去改他手上那一条路。
#'
#' @param files 产物文件名（相对工作区）
#' @param workdir 工作区目录（空表检查要读文件）
#' @param stderr 这次执行的 stderr（方框检查要读 matplotlib 的警告）。
#'   NULL / 空 = 不做方框检查（比如老任务的行里没有 stderr）。
dsapp_bad_artifacts <- function(files, workdir, stderr = NULL) {
  c(tryCatch(dsapp_artifact_check(files, workdir),
             error = function(e) character(0)),
    tryCatch(dsapp_font_glyph_check(stderr),
             error = function(e) character(0)))
}

# ---- 产物是"给人看"还是"给机器看"（★ V15.5 item 3）------------------------
#
# 用户原话：「我觉得现在的输出功能有问题……整理完之后居然返给用户的是一份
# json 文件，完全没有人类可读性」。
#
# 现场（会话 s-20260930130349-4988）：agent 循环跑完，最后一条 tool 消息的
# 末尾挂着「本次产出的文件」，里面是 step6_candidate_audit.json 这类中间数据。
# 页面把那一串名字渲染成可点预览的 chip（render.R 的 dsapp_run_files_ui），
# 用户看到的就是"这份分析交付给我的是一个 json"。
#
# ---- 为什么抽成一个函数，而不是在 agent.R 里就地写个 if --------------------
#
# 同一条判据有**三个**使用点，而且必须永远一致：
#   · agent.R 的回喂正文（模型照着它决定"我交付了什么"）
#   · render.R 的产物 chip（用户照着它决定"我拿到了什么"）
#   · agent.R 收尾时那条「这一趟全是中间文件」的平台提示
# 抄成三份的话，改一处、另外两处不报错，只是说法不一致 —— 而用户看到的
# 清单和模型看到的清单对不上时，谁也不知道该信哪一份。
#
# ⚠️ 判据只是**后缀**。不看内容、不看大小、不看是谁写的：一个 .json 里当然
#    也可能装着结论，但"用户能不能直接读"这件事由后缀就定死了 —— 要交付，
#    就得把它写成 md / html / 图片 / 表格。
# ⚠️ 两串后缀是**白名单**：没见过的（`.parquet`、`.loom`）一律算中间产物。
#    用排除法的话，将来多一个新后缀就会被吹成"可交付"，而"交付物"这个词
#    是给用户看的 —— 宁可少说一句，也不能给他一个打不开的东西。
# ⚠️ 取后缀用 basename()：产物名是相对路径，直接对整串取"最后一个点"会把
#    目录名里的点当后缀（`v1.2/out` → 后缀成了 `2/out`），静默判错。
DSAPP_ARTIFACT_HUMAN_EXT <- c(
  "md", "html", "htm", "pdf", "docx", "pptx", "txt",
  "png", "jpg", "jpeg", "svg", "csv", "xlsx")

#' 这批产物里，哪些是"人类可读、可以直接交付"的
#'
#' @param files 产物名（相对路径 / 纯文件名 / 目录名）
#' @return 和 files 等长的 logical。**没有后缀的一律 FALSE**（含目录、
#'   含无后缀的二进制）—— 判不出来就不吹，这是这里的默认方向。
dsapp_artifact_is_human <- function(files) {
  files <- as.character(files %||% character(0))
  if (!length(files)) return(logical(0))
  base <- basename(files)
  ext <- rep("", length(base))
  # 要求名字里**真的有**一个点，而不是靠 sub() 匹配不上时原样返回：
  # `sub("^.*\\.", "", "noext")` 返回的是 "noext" 本身，那样一个叫 `md`
  # 的目录就会被当成 markdown 文件。
  has <- !is.na(base) & grepl(".", base, fixed = TRUE)
  ext[has] <- tolower(sub("^.*\\.", "", base[has]))
  ext %in% DSAPP_ARTIFACT_HUMAN_EXT
}

#' 这个工作区路径是"我们自己塞进去的"，不是产物
#'
#' 工作区里有四类不该出现在**任何**面向用户/模型的清单里的东西：
#'   * `.dsapp_*` —— 脚本、stdout/stderr 这些执行脚手架
#'   * `.Rlib` / `.venv` / `.pylib` —— 对话专属的包目录（envs.R 建的），
#'     里面是几千个包文件
#'   * `.dsapp_extract_*` —— 解压用的临时目录
#'   * `.skills` —— 技能配套文件（skills.R 的
#'     `dsapp_skill_files_materialize()` 铺进来的模板 / 参考文档）
#'
#' ⚠️ 必须是**一段一段**地判（路径里任何一段命中就算内部），不能只判开头：
#'    递归快照给出的是 `results/plot.png` 这种相对路径，而内部目录同样
#'    可能出现在子层……虽然我们只在顶层建它们，但判开头这件事一旦有人
#'    改成"模型可以把包目录建在子目录里"就会静默失效，而失效的表现是
#'    "产物列表里冒出几千个 .Rlib/xxx"，不是报错。
#'
#' ⚠️⚠️ **`.skills` 是 2026-10-08 补进来的，别删。** 它原来不在这个表里，
#'    而挡着它的是 skills.R 注释里那句「`.skills/` 是点目录，`fs::dir_ls` /
#'    `list.files` 默认不列它」—— 那句话**只对列目录的写法成立**，而
#'    `dsapp_ws_snapshot()` 用的是 **`find`**（见下面 `dirs = TRUE` 那段，
#'    为了不跟软链钻出去才换的），`find` 是**列点文件**的。于是这条路径
#'    一路通到 `dsapp_ws_artifacts()`：
#'      * 平时不会发作 —— `dsapp_sync_artifacts()` 传的是**本次任务的产物**
#'        （taskrun.R），不含技能文件；`dsapp_sync_backfill()` 又只补
#'        **没有 sync_dirs 行**的对话，用过技能的对话早就有了。
#'      * 一发作就是**全量**：`dsapp_sync_repair()` 的差集是
#'        「盘上快照 − 已发布」，一把把 `.skills/` 底下所有文档捞进用户的
#'        文件管理区（2026-10-08 实测：一次 repair 就往 u1 发了 174 个）。
#'    ⇒ 内部目录的判据**不能依赖"这个写法恰好不列它"**，要点名。
dsapp_ws_is_internal <- function(rel) {
  if (!length(rel)) return(logical(0))
  vapply(rel, function(p) {
    seg <- strsplit(p, "/", fixed = TRUE)[[1]]
    any(seg %in% c(".Rlib", ".venv", ".pylib", ".skills") |
          startsWith(seg, ".dsapp_"))
  }, logical(1), USE.NAMES = FALSE)
}

#' 工作区的快照（相对路径，递归，不跟软链）
#'
#' 给"这次产出了什么"的差集用。用 `find` 而不是 `list.files(recursive =
#' TRUE)`：后者会跟着目录软链钻出去，而且它列出来的名字带 `./` 前缀，
#' 前后两次快照的格式一旦不一致，差集就全错。
#'
#' `dirs = TRUE` 时把**目录**也列进来（V8 item 7）。
#'
#' ★★ 为什么目录必须进快照：这里原来只有 `-type f`，于是**空目录在整个
#'    应用里等于不存在** —— 产物清单、按任务分组的文件页、任务详情的
#'    "本次产物"、给模型看的"本对话已有文件"，四处都看不到它。用户让模型
#'    `dir.create("16S分析/测试文件夹")`，跑完界面上一个字都没有，磁盘上
#'    却真有这个目录。用户 2026-09-15 报的 18S 任务就是这条：
#'    workdir 里躺着 `16S分析/测试文件夹/测试文件夹`（两级都是空的），
#'    而 `dsapp_ws_artifacts()` 返回的 10 行里没有一个是目录。
#'    而"目录里没文件"恰恰是最需要界面确认的情况 —— 模型说建好了，
#'    用户没有任何办法验证。
#'
#'    `-type f -o -type d`：find 会把默认的 `-print` 作用在**整个**表达式
#'    上，等价于 `\( -type f -o -type d \) -print`，所以不用自己加括号
#'    （加了反而要在 shell 里转义，而 system2 是拼字符串走 shell 的）。
#'    软链仍然不进（find 默认 lstat、不跟），上传区镜像进来的只读输入
#'    自动被排除。
#'
#'    ⚠️ 结果里**不含 `d` 自己**。`-type d` 会让根目录自己也匹配上，而它
#'       剥掉前缀之后是空串 —— 不专门扔掉的话产物列表里会多出一行没有
#'       名字的"文件"，点下载得到的是整个工作区的打包。
dsapp_ws_snapshot <- function(d, dirs = FALSE) {
  if (!dir.exists(d)) return(character(0))
  root <- tryCatch(normalizePath(d, mustWork = TRUE),
                   error = function(e) NA_character_)
  if (is.na(root)) return(character(0))
  typ <- if (isTRUE(dirs)) c("-type", "f", "-o", "-type", "d") else "-type f"
  # ⚠️ 交给 find 的是**规范化之后**的 root，不是原来的 d。原来传的是 d
  #    自己，find 就照着 d 的字面样子打印；而剥前缀用的是 normalizePath(d)。
  #    路径里只要有一个软链环节（/tmp 在有些机器上就是软链）两边就对不上，
  #    前缀剥不掉，产物名全变成绝对路径 —— 界面上显示一长串路径，
  #    点下载还找不到文件。
  out <- tryCatch(
    suppressWarnings(system2("find", c(shQuote(root), typ),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  out <- out[nzchar(out)]
  prefix <- paste0(root, .Platform$file.sep)
  out <- out[startsWith(out, prefix)]
  if (!length(out)) return(character(0))
  # substring 而不是 sub：路径里带 `.` `+` `(` 之类字符时正则会把它们当
  # 元字符，`^` 锚不住，前缀就剥不掉（后果同上）。
  sort(substring(out, nchar(prefix) + 1L))
}

#' 工作区的"带戳快照"：相对路径 → mtime
#'
#' ★★ 为什么光有名字不够（V12 item 3）。差集以前是 `setdiff(after, before)`
#'    ——**纯按名字**。名字没变但内容变了的文件，在差集里等于不存在。V11 之
#'    前这只影响界面上的"本次产出"列表（少列一行，没人报），V12 起产物要
#'    **自动同步到共享区**，这条就成了数据错误：
#'
#'      第一轮 `write.csv(df, "de.csv")` → 同步出去，共享区里是 1.2
#'      第二轮改了个参数重跑同一个脚本 → 差集是**空的**
#'      → 同步这一步拿到空清单，什么都不做
#'      → 共享区里那份还是 1.2，而用户刚在对话里看到 2.4
#'
#'    重跑一遍是分析 agent 最常见的动作（模型改个阈值再来一次），所以这不
#'    是个边角情况。用户下载到的是一份看起来正常、但和他以为的不是一回事
#'    的数据 —— 比报错糟得多。
#'
#' ⚠️ 判据是 mtime + size 两个都看。只比 mtime 的话，同一秒内的改写（快速
#'    脚本、粗粒度文件系统）会被漏掉；只比 size 的话，等长的改写会被漏掉。
#'    两个都不变的内容，界面上和下载下来也确实分不出来。
#'
#' ⚠️ 目录也拍（和 dsapp_ws_snapshot 的 dirs = TRUE 对齐）—— 只建目录不写
#'    文件的步骤同样是产出，见 dsapp_ws_snapshot 的说明。
dsapp_ws_stamp <- function(d, dirs = TRUE) {
  fs <- dsapp_ws_snapshot(d, dirs = dirs)
  if (!length(fs)) return(stats::setNames(numeric(0), character(0)))
  info <- suppressWarnings(file.info(file.path(d, fs)))
  # mtime 和 size 拼成一个可比较的数：mtime 秒数为主，size 用小数位带上。
  # 两者都不是 NA 才认，否则这一项就当"没有戳"，回落到按名字判。
  mt <- as.numeric(info$mtime)
  sz <- as.numeric(info$size)
  v <- mt + ifelse(is.na(sz), 0, pmin(sz, 999) / 1000)
  stats::setNames(v, fs)
}

#' 两次带戳快照的差：**新增的** 和 **改过的**
#'
#' @return 相对路径向量（新增排前面，改过的排后面，各自保持原顺序）
dsapp_ws_diff <- function(before, after) {
  if (!length(after)) return(character(0))
  new <- setdiff(names(after), names(before))
  kept <- names(after)[names(after) %in% names(before)]
  chg <- character(0)
  if (length(kept)) {
    b <- before[kept]
    a <- after[kept]
    # !is.na 两边都要判：拍的时候文件可能刚好被删/被换掉，NA 参与比较会
    # 得到 NA，而 `which(NA)` 是空的 —— 静默漏掉一项，不是报错。
    chg <- kept[!is.na(a) & !is.na(b) & a != b]
  }
  c(new, chg)
}

#' 工作区里的产物清单（含大小、类型），给「文件」页的对话产物区用
#'
#' 过滤掉两种不该出现在列表里的东西：
#'   * 上传区软链进来的只读输入 —— 它们不是这个对话的产物
#'   * 我们自己写的临时文件（.dsapp_*）
#'
#' 大文件不在这里挡：用户下载自己的产物是合理需求。挡的是"自动复制到共享区"
#' 那一步的体积（V12 item 3 起自动同步回来了，但带 512M / 300 个的上限，
#' 见 files.R 的 dsapp_sync_artifacts）。界面自己决定怎么展示。
dsapp_ws_artifacts <- function(sid, cfg = dsapp_config()) {
  # ★ V13 item 6：这个函数只用 cfg 干一件事 —— 拿 dsapp_shared_scan() 判
  #   "这个产物发布出去了没有"。那一步必须落在**对话主人**的管理区上，
  #   否则别人的文件会被拿来比对，标记会乱跳（明明发布成功了，标记还停在
  #   「仅本对话」，用户就再点一次）。
  cfg <- dsapp_config_sid(sid, cfg)
  empty <- data.frame(name = character(0), size = numeric(0),
                      size_h = character(0), mtime = character(0),
                      kind = character(0), published = logical(0),
                      is_dir = logical(0),
                      stringsAsFactors = FALSE)
  d <- dsapp_ws_dir(sid, cfg, create = FALSE)
  if (is.na(d) || !dir.exists(d)) return(empty)

  # 递归列**文件和目录**（find 不跟软链，所以上传区镜像进来的只读输入
  # 自动不在里面 —— 它们不是这个对话的产物，见函数头的说明）。
  #
  # ⚠️ 不要退回 list.files 的顶层版本。V5 起工作区里有子目录，只列顶层
  #    会把模型写进 `results/` 的图整个漏掉，界面上看起来"什么都没产出"，
  #    而文件明明就在那儿。
  #
  # ⚠️ dirs = TRUE 是 V8 item 7：不带目录的话，模型建的空文件夹在界面上
  #    完全不存在（详见 dsapp_ws_snapshot 的说明）。带目录之后**多了一列
  #    is_dir**，凡是按大小求和、按个数说话的地方都得把目录摘出去，
  #    否则目录和它里面的文件会被算两遍。
  fs <- dsapp_ws_snapshot(d, dirs = TRUE)
  fs <- fs[!dsapp_ws_is_internal(fs)]
  if (!length(fs)) return(empty)

  info <- file.info(file.path(d, fs))
  keep <- !is.na(info$size)
  fs <- fs[keep]; info <- info[keep, , drop = FALSE]
  if (!length(fs)) return(empty)

  is_dir <- !is.na(info$isdir) & info$isdir

  # 目录的大小不能用 file.info：那是**目录项自己**的大小，Linux 上恒为
  # 4096（跟里面有没有东西、有多少东西都无关）。直接拿它显示的话，
  # 一个空文件夹会写着"4.0 KB"，用户会以为里面有东西。
  #
  # 这里按前缀把子文件的字节数加起来 —— 显示的是"这个文件夹总共占多大"。
  # 空目录老老实实 0。目录里嵌套目录时，内层已经算过一遍，外层再算一遍
  # 是对的（外层本来就该包含内层）。
  sz <- info$size
  if (any(is_dir)) {
    fsz <- info$size[!is_dir]; frel <- fs[!is_dir]
    for (i in which(is_dir)) {
      pfx <- paste0(fs[i], "/")
      sz[i] <- if (length(frel)) sum(fsz[startsWith(frel, pfx)], na.rm = TRUE) else 0
    }
  }

  # 「已发布」= **真的点过发布**，而不是"共享区里有个同名文件"。
  #
  # ★ 这里以前是 `published = fs %in% shared`，拿名字去共享区里比对。两个
  #   方向都会错：
  #     * 漏报 —— 发布落在共享区**根目录**（用 basename），而 `fs` 是工作区
  #       里的**相对路径**。`results/de_genes.csv` 发布出去叫 `de_genes.csv`，
  #       两边永远对不上，子目录里的产物发布完标记还停在「仅本对话」，
  #       用户以为没成功就再点一次，共享区里多出一个 `de_genes1.csv`。
  #     * 误报 —— 只比 basename 的话，`A/expr.csv` 会被当成已经发布过，
  #       而它可能从来没发布过（是别人发布的 `B/expr.csv`）。
  #
  #   所以改成查发布记录（ws_published 表）。**并且还要确认那份文件现在
  #   还在**：用户把共享区里那份删了，标记就该退回「仅本对话」，否则他
  #   会以为东西还在。
  shared <- tryCatch(dsapp_shared_scan(cfg)$files,
                     error = function(e) character(0))
  pubs <- tryCatch(db_ws_pub_map(sid, con = dsapp_db(cfg)),
                   error = function(e) NULL)
  dest <- if (is.null(pubs) || nrow(pubs) == 0) rep(NA_character_, length(fs))
          else pubs$dest[match(fs, pubs$name)]

  # kind 交给 dsapp_file_kind（按扩展名判），但目录没有扩展名 —— 它那边
  # 会落进默认分支。这里直接钉死 "dir"，界面靠它决定画文件夹图标、
  # 给「打包下载」而不是「发布」。
  kinds <- vapply(fs, dsapp_file_kind, character(1))
  kinds[is_dir] <- "dir"

  data.frame(
    name   = fs,
    size   = sz,
    size_h = vapply(sz, dsapp_fmt_bytes, character(1)),
    mtime  = format(info$mtime, "%Y-%m-%d %H:%M"),
    # 原始 mtime（POSIXct，本地时区）。界面上用的是上面那个"到分钟"的
    # 字符串，而 dsapp_ws_groups 判"这个目录是哪次任务建的"要拿它和任务的
    # 起止时刻比 —— 比到分钟的话，同一分钟里紧挨着的两次执行会认错。
    mtime_raw = info$mtime,
    kind   = kinds,
    # 目录不发。发布是"把一个文件复制进共享区"，而共享区是按文件管的
    # （dsapp_shared_scan 也只列文件）。给目录一个「发布」按钮的话，
    # 点下去要么静默失败、要么在共享区里造出一个假的"文件"。目录要给
    # 的是「打包下载」。
    published = !is_dir & !is.na(dest) & dest %in% shared,
    is_dir = is_dir,
    stringsAsFactors = FALSE
  )
}

#' 工作区产物按**任务**分组（V7）
#'
#' 用户的原话：「文件需要以任务名称分类展开」「文件请按任务分类」。
#'
#' 归属来自 task_files 表（见 db.R 的说明），在执行收尾时按当次的产物差集
#' 落库。**最新的任务赢**：同一个路径被后面的任务覆盖时（第二次跑写同名
#' 文件是常态），它属于后一次 —— 否则用户点开旧任务的分组，看到的是新
#' 任务写进去的内容。
#'
#' ⚠️ 磁盘是真相、表是索引：文件被删掉之后表里可能还有行，所以这里以
#'    `dsapp_ws_artifacts()`（真的扫盘）为起点，只拿表去补"是谁写的"。
#'    反过来的话，用户删掉的文件会一直挂在列表里，点下载得到一个空文件。
#'
#' @return 分组列表，每组 list(task_id, title, status, time, files, bytes)。
#'   认不出归属的排在最后（解压出来的、V7 之前就存在的），标题写「其他」。
dsapp_ws_groups <- function(sid, cfg = dsapp_config()) {
  df <- dsapp_ws_artifacts(sid, cfg)
  if (nrow(df) == 0) return(list())

  con <- dsapp_db(cfg)
  map <- tryCatch(db_task_files_map(sid, con = con),
                  error = function(e) NULL)
  df$task_id <- if (is.null(map) || nrow(map) == 0) NA_integer_
                else as.integer(map$task_id[match(df$name, map$name)])

  # ---- 目录的归属：task_files 里没有的，按时间窗口补一次（V8 item 7）------
  #
  # 为什么需要这个补丁，值得写清楚 —— 它是用户 2026-09-15 报的那条
  # 「执行后并没有在文件系统看到新的文件夹」的另一半：
  #
  #   18S 那个会话（s-20260915131728-4498）的任务 #8 **只干了一件事**：
  #   建了个空文件夹 `16S分析/测试文件夹`。当时快照只拍 `-type f`，所以
  #   这次执行的产物差集是**空的**，task_files 里一行都没有（实测：
  #   task_files WHERE task_id=8 → 0 行）。于是文件页既看不到那个文件夹，
  #   也不认为它跟任何任务有关 —— 两个毛病叠在一起，界面上就是"什么都没有"。
  #
  #   改完快照之后新任务会正常记录，但**已经跑过的**那些不会自己长出来：
  #   用户重启服务、打开这个 18S 会话，期待看到的就是那个文件夹挂在 #8 底下。
  #   所以这里补一次。
  #
  # 判据是时间窗口：目录自己的 mtime 落在某条任务的 [created_at, finished_at]
  # 区间里，就归给它。目录是被创建/改名的那一刻被戳上 mtime 的，而这个动作
  # 只可能由当时正在跑的那个任务做；全站同一时刻只有一个任务在跑（见 app.R
  # 的单槽引擎），所以区间不会重叠，最多是"相邻两次首尾相接"。
  #
  # ⚠️ 只补**目录**，不补文件。文件有 task_files 里确切的归属，"按时间猜"
  #    对它是一次降级：一个文件被后来的任务覆盖写之后 mtime 会跟着变，
  #    看着和"最新的任务赢"一致，但 V7 之前写下的老文件 mtime 早就没有
  #    参考价值了。目录没有这个历史包袱 —— V8 之前它们**根本进不了**
  #    task_files，猜是唯一的办法，猜错了也只是分组位置不对，不影响文件本身。
  miss <- is.na(df$task_id) & df$is_dir
  if (any(miss) && !is.null(df$mtime_raw)) {
    win <- tryCatch(DBI::dbGetQuery(con,
      "SELECT id, created_at, finished_at FROM tasks
        WHERE session_id = ? AND status IN ('success','failed','timeout')
        ORDER BY id", params = list(sid)),
      error = function(e) NULL)
    if (!is.null(win) && nrow(win)) {
      # created_at 是 UTC 存的字符串（见 dsapp_now），POSIXct 之后比较的是
      # 绝对时刻，所以这边不用再管时区对不对得上。
      cs <- as.POSIXct(win$created_at, tz = "UTC")
      fin <- ifelse(is.na(win$finished_at) | !nzchar(win$finished_at),
                    win$created_at, win$finished_at)
      fe <- as.POSIXct(fin, tz = "UTC")
      for (i in which(miss)) {
        mt <- df$mtime_raw[i]
        if (is.na(mt)) next
        hit <- which(!is.na(cs) & !is.na(fe) & mt >= cs & mt <= fe)
        # 命中多条时取**最后**一条：重跑会让同一个目录落在多个窗口里
        # （第二次跑不重新建目录，但父目录会因为子文件变动被戳新 mtime），
        # 取新的那条和"最新的任务赢"保持一致。
        if (length(hit)) df$task_id[i] <- as.integer(win$id[hit[length(hit)]])
      }
    }
  }

  # 任务行一次查回来。逐组查是 N 次往返，而这一页在任务跑着的时候每 2 秒
  # 就要重算一次（见 mod_files.R 的 reactivePoll）。
  ids <- sort(unique(df$task_id[!is.na(df$task_id)]), decreasing = TRUE)
  meta <- if (!length(ids)) NULL else tryCatch(
    DBI::dbGetQuery(con, sprintf(
      "SELECT id, title, status, created_at FROM tasks WHERE id IN (%s)",
      paste(as.integer(ids), collapse = ","))),
    error = function(e) NULL)

  # 分组顺序：任务号大的（新的）在前，认不出来的垫底。
  #
  # ⚠️ 用 task_id 排而不是 created_at：同一秒内跑两个任务时时间戳会撞，
  #    而 id 是自增的，天然有序。
  key <- ifelse(is.na(df$task_id), 0L, df$task_id)
  out <- list()
  for (k in sort(unique(key), decreasing = TRUE)) {
    sub <- df[key == k, , drop = FALSE]
    # ★★ V15.5 item 11：组内**最新在前**（不是按名字）。
    #
    #   用户原话：「文件管理区也应该是最新的文件默认排在最前面」。原来这里是
    #   `order(sub$name)` —— 组内字母序，后果是"看起来像随机"：刚跑出来的
    #   de_genes.csv 排在 asv_table.csv 后面，用户在自己这一组里找"我刚产出的
    #   东西"要先扫一遍全组。
    #
    #   ⚠️ 排序必须在这里、在**数据框**上做，不能在渲染层补：任务页
    #      （mod_tasks.R 的 task_group）与文件页右栏（mod_files.R）拿的都是
    #      这一份 `files`，并且**按行号**取 name[i] / size_h[i]。谁那边另外排
    #      一次，显示顺序就和按行号取到的值错开了。
    #      （mod_files.R 里仍留了一遍同样的排序，是幂等的保险，不是第二套规则。）
    #   ⚠️ 复用 dsapp_files_order()，别在这里另写一套 sort —— 另一套迟早跟
    #      文件页那份不一致（工作区与文件区的 mtime 是同一个格式，共用才对得上）。
    sub <- dsapp_files_order(sub)
    # 目录单独标出来：下面算体积要把它摘掉（它的 size 已经含了里面的
    # 文件，一起加就是算两遍），界面上也要按它换一套说法。
    isd <- if (is.null(sub$is_dir)) rep(FALSE, nrow(sub)) else sub$is_dir
    trow <- if (k > 0 && !is.null(meta)) meta[meta$id == k, , drop = FALSE]
            else NULL
    out[[length(out) + 1L]] <- list(
      task_id = if (k > 0) k else NA_integer_,
      title   = if (!is.null(trow) && nrow(trow)) trow$title[1] else "其他",
      status  = if (!is.null(trow) && nrow(trow)) trow$status[1] else "",
      time    = if (!is.null(trow) && nrow(trow))
                  dsapp_fmt_time(trow$created_at[1]) else "",
      files   = sub,
      # ⚠️ 目录不参与求和（V8 item 7）。目录的 size 是"它里面所有文件的
      #    和"，把它和里面的文件一起加起来，同一个字节会被算两遍 ——
      #    一组 7 个文件加起来 10 MB，界面上却写着 20 MB。
      bytes   = sum(sub$size[!isd], na.rm = TRUE),
      n_file  = sum(!isd),
      n_dir   = sum(isd)
    )
  }
  out
}
