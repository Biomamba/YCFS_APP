# =============================================================================
# 远程服务器执行（SSH）
# =============================================================================
# 用户在设置页填 IP / 端口 / 账号 / 密码或私钥，代码就在那台机器上跑。
#
# ---- 密码认证是怎么做到的 ----------------------------------------------------
#
# 这台机器上是 OpenSSH 8.2p1，没有 SSH_ASKPASS_REQUIRE（8.4 才有），
# 也没装 sshpass。但老版本 ssh 有个行为可以利用：**当没有 controlling tty
# 且设置了 SSH_ASKPASS 时，它会去执行 SSH_ASKPASS 指定的程序来要密码**。
#
# 所以密码认证走这条路：
#
#     setsid -w ssh ...        # setsid 脱离控制终端 → 触发 askpass 分支
#       + SSH_ASKPASS=<临时脚本>  # 脚本的唯一作用是把密码打到 stdout
#       + stdin < /dev/null       # 断掉从终端读密码的可能，防止挂起
#
# 这个方案在本机 sshd 上实测过：askpass 脚本确实被调用
# （日志留下 "nobody@127.0.0.1's password:" 一条），认证链路通。
#
# ---- 凭据怎么放的 ------------------------------------------------------------
#
# 沿用 API Key 的约定：**只用会话内存，不落库、不落盘**。
#
# 但"完全不碰磁盘"在技术上做不到 —— ssh 需要一个文件来放私钥，
# 也需要一个文件来当 SSH_ASKPASS 脚本。折中是：
#
#   * 临时目录建在 data_root/run/ 下，权限 0700，路径带随机后缀
#   * 私钥文件 0600，askpass 脚本 0700
#   * 命令一结束（无论成功失败）立刻 unlink 整个目录 —— 见 on.exit
#   * 目录名以 .ssh- 开头，方便运维一眼认出来是可以删的残留
#
# ⚠️ 老实说清楚边界：这和 API Key 是同一个问题 —— 进程内存和临时文件里
# 有明文，**root 能读到**。没有登录机制的应用里，任何落盘的凭据都等于
# 对所有人开放。所以远程凭据也只在单个浏览器会话的内存里活着。
#
# ---- 走 ssh 的代码还要不要静态扫描 -------------------------------------------
#
# 要。远程那台机器是用户自己的，炸了不心疼，但扫描还挡着另一件事：
# 用户自己手滑。保持一致的行为比"远程就放松"更好预期。扫描发生在
# 引擎入口（app.R 的 e$start），对三种目标一视同仁。
# =============================================================================

#' 准备一次 SSH 调用的上下文
#'
#' 建临时目录、写私钥/askpass 脚本、拼公共参数。
#' 调用方必须用 on.exit(dsapp_ssh_cleanup(ctx)) 保证凭据被删掉。
#' @return list(ok, ctx) 或 list(ok=FALSE, msg)
dsapp_ssh_ctx <- function(target, cfg = dsapp_config()) {
  r <- target$remote %||% list()
  host <- trimws(r$host %||% "")
  user <- trimws(r$user %||% "")
  port <- suppressWarnings(as.integer(r$port %||% 22))
  auth <- r$auth %||% "password"

  if (!nzchar(host)) return(list(ok = FALSE, msg = "远程主机地址为空"))
  if (!nzchar(user)) return(list(ok = FALSE, msg = "远程用户名不能为空"))
  if (is.na(port) || port < 1 || port > 65535) {
    return(list(ok = FALSE, msg = "端口应是 1-65535 之间的数字"))
  }
  # 主机名只允许字母数字点横线冒号（IPv6 用冒号），挡掉往 ssh 参数里
  # 塞 -oProxyCommand=... 这类选项注入（以短横线开头的主机名会被 ssh
  # 当成选项解析）。
  #
  # ★ V16.6：判据搬进了 `dsapp_remote_host_ok()`（R/syncservers.R）。
  #   搬家的原因是**同一套判据在本仓有三份拷贝**（这里一份、R/nodes.R 一份、
  #   同步跳板本来会写第三份），而三份拷贝的危险不是啰嗦，是**它们会分叉**：
  #   改了一处忘了另一处，症状是"从这条路进得来、从那条路进不来"。
  #   ⚠️ 那个函数里记着 perl = TRUE 那个坑（不写 perl 的话字符类会提前收尾，
  #      把**所有**主机名都挡掉，看着像在正常拦截）。
  if (!dsapp_remote_host_ok(host)) {
    return(list(ok = FALSE, msg = "主机地址含非法字符"))
  }
  if (!grepl("^[A-Za-z0-9_.-]+$", user) || grepl("^-", user)) {
    return(list(ok = FALSE, msg = "用户名含非法字符"))
  }

  if (!file.exists(cfg$ssh$bin)) {
    return(list(ok = FALSE, msg = sprintf("找不到 ssh：%s", cfg$ssh$bin)))
  }

  # 凭据暂存目录。0700 + 随机后缀，命令结束就删。
  tmp <- file.path(cfg$run_dir, paste0(".ssh-", dsapp_id("x")))
  if (!dir.create(tmp, recursive = TRUE, showWarnings = FALSE)) {
    return(list(ok = FALSE, msg = "无法创建临时目录来存放连接凭据"))
  }
  Sys.chmod(tmp, mode = "0700")

  # known_hosts 单独放一份，不污染 shiny 用户的 ~/.ssh。
  # 不共享是有意的：多台远程机器混在一个文件里，主机密钥变了很难排查。
  known_hosts <- file.path(cfg$data_root, "ssh_known_hosts")

  common <- c(
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", sprintf("UserKnownHostsFile=%s", known_hosts),
    "-o", "LogLevel=ERROR",
    "-p", as.character(port)
  )

  env <- dsapp_exec_env()
  askpass_path <- NULL

  if (identical(auth, "key")) {
    key_text <- r$key_text %||% ""
    if (!nzchar(trimws(key_text))) {
      unlink(tmp, recursive = TRUE)
      return(list(ok = FALSE, msg = "选择了密钥认证，但没有填入私钥内容"))
    }
    if (!grepl("-----BEGIN [A-Z ]*PRIVATE KEY-----", key_text)) {
      unlink(tmp, recursive = TRUE)
      return(list(ok = FALSE, msg = "私钥格式不对（缺少 -----BEGIN ... PRIVATE KEY----- 开头）"))
    }
    key_file <- file.path(tmp, "id_key")
    con <- file(key_file, open = "wb")
    writeBin(charToRaw(key_text), con)
    close(con)
    if (!grepl("\n$", key_text)) {
      # 有些粘贴方式会吃掉结尾换行，而 OpenSSH 对此很敏感
      cat("\n", file = key_file, append = TRUE)
    }
    Sys.chmod(key_file, mode = "0600")

    common <- c(common,
                "-i", key_file,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey",
                # 密钥认证下绝不允许回退到交互式提问，否则会挂住
                "-o", "BatchMode=yes")
  } else {
    pwd <- r$password %||% ""
    if (!nzchar(pwd)) {
      unlink(tmp, recursive = TRUE)
      return(list(ok = FALSE, msg = "选择了密码认证，但密码为空"))
    }
    askpass_path <- file.path(tmp, "askpass.sh")
    # 密码写在脚本里而不是参数里：进程列表（ps）对同机器所有用户可见，
    # 密码出现在 argv 里就等于公开了。
    # 单引号包裹 + 转义内部的单引号，避免密码里的引号截断脚本。
    writeLines(c(
      "#!/bin/bash",
      sprintf("printf '%%s\\n' %s", shQuote(pwd))
    ), askpass_path)
    Sys.chmod(askpass_path, mode = "0700")

    env[["SSH_ASKPASS"]] <- askpass_path
    # 老版本 ssh 会检查 DISPLAY 来判断"有没有图形界面可以弹窗"，
    # 不设的话可能直接放弃 askpass 去读终端。设成任意值即可。
    env[["DISPLAY"]] <- ":0"
    # 显式禁掉 BatchMode —— 它和 askpass 是互斥的
    common <- c(common,
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=password,keyboard-interactive")
  }

  list(ok = TRUE, ctx = list(
    tmp = tmp, env = env, common = common, askpass = askpass_path,
    target = sprintf("%s@%s", user, host), port = port,
    user = user, host = host, activate = trimws(r$activate %||% ""),
    workdir = trimws(r$workdir %||% "")
  ))
}

#' 删掉暂存的凭据
dsapp_ssh_cleanup <- function(ctx) {
  if (is.null(ctx) || is.null(ctx$tmp)) return(invisible(FALSE))
  unlink(ctx$tmp, recursive = TRUE, force = TRUE)
  invisible(TRUE)
}

#' 拼一个 ssh 命令的 processx 调用参数
#'
#' @param remote_cmd 在远程执行的命令字符串
#' @param stdin_devnull 是否把 stdin 接到 /dev/null
dsapp_ssh_argv <- function(ctx, remote_cmd, cfg = dsapp_config()) {
  ssh_args <- c(ctx$common, ctx$target, remote_cmd)

  if (is.null(ctx$askpass)) {
    # 密钥认证：不需要 setsid，也没有会挂起的交互提问
    return(list(command = cfg$ssh$bin, args = ssh_args,
                use_setsid = FALSE, devnull = FALSE))
  }

  # 密码认证：需要脱离控制终端，否则 ssh 会去读终端而不用 askpass。
  #
  # ⚠️ setsid 是 Linux 上的东西，**没有也要能跑**：找不到就退回直接起 ssh，
  #    只是把 stdin 接到空设备（下面 devnull 那条），效果上足够挡住
  #    "ssh 去读终端"这条路。Windows 上这个功能整体是降级的 ——
  #    OpenSSH 客户端是有的，但 setsid 没有，所以密码认证可能在某些情况下
  #    卡在提问上。密钥认证不受影响，本地运行建议用密钥。
  sid <- dsapp_setsid_path()
  if (is.null(sid)) {
    list(command = cfg$ssh$bin, args = ssh_args,
         use_setsid = FALSE, devnull = TRUE)
  } else {
    list(command = sid, args = c("-w", cfg$ssh$bin, ssh_args),
         use_setsid = TRUE, devnull = TRUE)
  }
}

#' 在远程跑一条命令（阻塞）
#'
#' ⚠️ 和本地执行一样，必须在子进程里调用。见 jobs.R。
#' @return list(ok, exit_code, stdout, stderr)
dsapp_ssh_run <- function(ctx, remote_cmd, timeout = 300,
                          cfg = dsapp_config()) {
  spec <- dsapp_ssh_argv(ctx, remote_cmd, cfg)

  out_f <- tempfile("sshout", tmpdir = ctx$tmp)
  err_f <- tempfile("ssherr", tmpdir = ctx$tmp)

  p <- tryCatch(
    processx::process$new(
      command = spec$command,
      args    = spec$args,
      # stdin 接 /dev/null 是密码认证方案的必要条件：断掉从终端读密码的
      # 可能。不接的话 ssh 在某些路径下会等一个永远不会来的输入。
      stdin   = if (spec$devnull) dsapp_devnull() else "",
      stdout  = out_f,
      stderr  = err_f,
      env     = ctx$env,
      cleanup_tree = TRUE
    ),
    error = function(e) e
  )

  if (inherits(p, "error")) {
    return(list(ok = FALSE, exit_code = NA_integer_, stdout = "",
                stderr = paste0("无法启动 ssh：", conditionMessage(p))))
  }

  p$wait(timeout = timeout * 1000)
  timed_out <- p$is_alive()
  if (timed_out) {
    p$kill()
    if (p$is_alive()) { Sys.sleep(1); try(p$kill(close_connections = TRUE), silent = TRUE) }
  }

  list(
    ok        = !timed_out && identical(p$get_exit_status(), 0L),
    exit_code = p$get_exit_status(),
    stdout    = dsapp_tail(out_f, n = 5000, max_bytes = 4 * 1024 * 1024),
    stderr    = dsapp_tail(err_f, n = 5000, max_bytes = 1024 * 1024),
    timed_out = timed_out
  )
}

#' 测试远程连接
#'
#' 设置页的「测试连接」按钮用。尽量把失败原因翻译成人话 ——
#' ssh 的原始报错（Host key verification failed / Permission denied）
#' 对不熟悉的人没什么指导意义。
dsapp_ssh_test <- function(target, cfg = dsapp_config()) {
  prep <- dsapp_ssh_ctx(target, cfg)
  if (!isTRUE(prep$ok)) return(list(ok = FALSE, msg = prep$msg))

  ctx <- prep$ctx
  on.exit(dsapp_ssh_cleanup(ctx), add = TRUE)

  probe <- dsapp_ssh_probe()

  r <- dsapp_ssh_run(ctx, probe, timeout = 60, cfg = cfg)

  if (isTRUE(r$timed_out)) {
    return(list(ok = FALSE, msg = sprintf(
      "连接 %s:%d 超时。检查 IP/端口是否正确、防火墙是否放行。",
      ctx$host, ctx$port)))
  }
  if (!grepl("DSAPP_OK", r$stdout, fixed = TRUE)) {
    err <- trimws(r$stderr)
    hint <- if (grepl("Permission denied", err, ignore.case = TRUE)) {
      "认证失败：账号、密码或私钥不正确。"
    } else if (grepl("Connection refused", err, ignore.case = TRUE)) {
      "端口拒绝连接：确认 sshd 在监听该端口。"
    } else if (grepl("Host key verification failed", err, ignore.case = TRUE)) {
      "主机密钥校验失败：目标机器重装过或指纹变了。"
    } else if (grepl("No route to host|Network is unreachable", err, ignore.case = TRUE)) {
      "网络不可达：确认本机能访问该 IP。"
    } else if (grepl("Could not resolve", err, ignore.case = TRUE)) {
      "主机名解析失败。"
    } else if (!nzchar(err)) {
      "连接失败，ssh 没有给出错误信息。"
    } else {
      "连接失败。"
    }
    return(list(ok = FALSE, msg = paste0(hint, "\n\nssh 原始输出：\n", err)))
  }

  # ⚠️ 逐行匹配，别用 sub(".*host=([^\\s]+).*", ...) 那种写法。两个坑叠在一起：
  #
  #   1. R 默认的 TRE 正则里，**方括号内部的 \s 不是空白**，而是字面量 s。
  #      于是 [^\s]+ 的真实含义是"不是字母 s 的字符"，一路吃到 s 就断。
  #      "/usr/bin/python3" 因此被截成 "/u"，远端解释器探测完全失效 ——
  #      而方括号**外**的 \s 又是正常工作的。正是这种内外不一致让它难被发现。
  #   2. 默认模式下 . 会匹配换行，.* 一跨行，抓出来的东西横跨好几行。
  #
  # 逐行匹配（(?m)^...$）两个问题都没有。
  line_val <- function(txt, key) {
    m <- regmatches(txt, regexpr(sprintf("(?m)^%s=(.*)$", key), txt, perl = TRUE))
    if (!length(m)) return("")
    sub(sprintf("^%s=", key), "", m)
  }
  host_line <- line_val(r$stdout, "host")
  user_line <- line_val(r$stdout, "user")

  # 把 bin:xxx=/path 抽出来给界面显示。
  # 用 sub 分别取名字和路径，而不是 strsplit("=")：路径里本来就可能带 =。
  bins <- regmatches(r$stdout,
                     gregexpr("(?m)^bin:[a-z0-9]+=.*$", r$stdout, perl = TRUE))[[1]]
  bin_list <- if (length(bins)) {
    setNames(sub("^bin:[a-z0-9]+=", "", bins, perl = TRUE),
             sub("^bin:([a-z0-9]+)=.*$", "\\1", bins, perl = TRUE))
  } else character()

  list(ok = TRUE, bins = bin_list,
       msg = sprintf("连接成功：%s@%s（%s:%d）",
                     user_line, host_line, ctx$host, ctx$port))
}

#' scp 的公共参数
#'
#' 和 ssh 几乎一样，只有端口不同：ssh 用 -p，scp 用 -P（大写）。
dsapp_scp_common <- function(ctx) {
  common <- ctx$common
  port_i <- which(common == "-p")
  if (length(port_i)) common[port_i] <- "-P"
  # 密码认证下也要显式允许交互提问，否则 setsid + askpass 那套不生效
  if (!is.null(ctx$askpass)) common <- c(common, "-o", "BatchMode=no")
  common
}

#' 拼一个 scp 命令的 processx 调用参数
#'
#' ⚠️ 返回的 args **不含**可执行文件本身 —— processx 的 command 已经指定了它。
#'
#' 这里踩过一个很能骗人的坑：push/pull 里曾经写成
#' `process$new(command = scp, args = c(scp, args))`，
#' 于是真正执行的命令行是 `/usr/bin/scp /usr/bin/scp -o ConnectTimeout=15 ...`。
#' scp 把第一个参数当成"要传的源文件"，参数解析乱掉之后**回落到交互式密码
#' 提问**，最终报出来的是 "Permission denied (publickey,password)"。
#' 看起来像密钥填错了或者密码不对，实际和凭据毫无关系 —— 只是可执行文件
#' 被写了两遍。凡是"报错指向凭据、但凭据明明是对的"的情况，都值得先怀疑
#' 参数拼装。
dsapp_scp_argv <- function(ctx, args, cfg = dsapp_config()) {
  # 和 dsapp_ssh_argv 同一套规则（setsid 没有就退回直接起，至少把 stdin
  # 接空设备）—— 两处必须一致，否则会出现"ssh 能连上但 scp 挂住"。
  if (is.null(ctx$askpass)) {
    return(list(command = cfg$ssh$scp, args = args,
                use_setsid = FALSE, devnull = FALSE))
  }
  sid <- dsapp_setsid_path()
  if (is.null(sid)) {
    list(command = cfg$ssh$scp, args = args, use_setsid = FALSE, devnull = TRUE)
  } else {
    list(command = sid, args = c("-w", cfg$ssh$scp, args),
         use_setsid = TRUE, devnull = TRUE)
  }
}

#' 把本地文件推到远程
dsapp_ssh_push <- function(ctx, local_dir, remote_dir, files, cfg = dsapp_config()) {
  if (!length(files)) return(list(ok = TRUE))
  if (!file.exists(cfg$ssh$scp)) {
    return(list(ok = FALSE, msg = "找不到 scp"))
  }

  args <- c(dsapp_scp_common(ctx),
            file.path(local_dir, files),
            sprintf("%s:%s/", ctx$target, remote_dir))
  spec <- dsapp_scp_argv(ctx, args, cfg)

  err_f <- tempfile("scperr", tmpdir = ctx$tmp)
  p <- tryCatch(processx::process$new(
    command = spec$command, args = spec$args,
    stdin = if (spec$devnull) dsapp_devnull() else "",
    stdout = tempfile("scpout", tmpdir = ctx$tmp), stderr = err_f,
    env = ctx$env, cleanup_tree = TRUE
  ), error = function(e) e)

  if (inherits(p, "error")) {
    return(list(ok = FALSE, msg = conditionMessage(p)))
  }
  p$wait(timeout = 30 * 60 * 1000)
  if (p$is_alive()) { p$kill(); return(list(ok = FALSE, msg = "上传到远程超时")) }

  if (!identical(p$get_exit_status(), 0L)) {
    return(list(ok = FALSE,
                msg = paste0("上传失败：\n", dsapp_tail(err_f, n = 30))))
  }
  list(ok = TRUE)
}

#' 从远程取回文件
dsapp_ssh_pull <- function(ctx, remote_dir, local_dir, cfg = dsapp_config()) {
  if (!file.exists(cfg$ssh$scp)) return(list(ok = FALSE, msg = "找不到 scp"))
  dir.create(local_dir, recursive = TRUE, showWarnings = FALSE)

  # -r 递归取回整个工作目录，本地再筛掉输入文件和脚本。
  #
  # ⚠️ 源路径**不能**加 "/." 后缀。`host:dir/.` 是想要"只取目录内容、
  # 不套一层目录"的常见写法，但本机的 OpenSSH 8.2 直接报
  #     error: unexpected filename: .
  # 于是产物一个都取不回来。写不带后缀的 `host:dir` 就好：它会多套一层
  # 同名目录，而下游的 list.files(recursive = TRUE) 本来就按 basename 取，
  # 多这一层没有任何影响。
  args <- c("-r", dsapp_scp_common(ctx),
            sprintf("%s:%s", ctx$target, remote_dir),
            local_dir)
  spec <- dsapp_scp_argv(ctx, args, cfg)

  err_f <- tempfile("scperr", tmpdir = ctx$tmp)
  p <- tryCatch(processx::process$new(
    command = spec$command, args = spec$args,
    stdin = if (spec$devnull) dsapp_devnull() else "",
    stdout = tempfile("scpout", tmpdir = ctx$tmp), stderr = err_f,
    env = ctx$env, cleanup_tree = TRUE
  ), error = function(e) e)

  if (inherits(p, "error")) return(list(ok = FALSE, msg = conditionMessage(p)))
  p$wait(timeout = 30 * 60 * 1000)
  if (p$is_alive()) { p$kill(); return(list(ok = FALSE, msg = "从远程取回文件超时")) }

  if (!identical(p$get_exit_status(), 0L)) {
    return(list(ok = FALSE, msg = paste0("取回产物失败：\n", dsapp_tail(err_f, n = 30))))
  }
  list(ok = TRUE)
}

#' 「测试连接」时在远端跑的探测脚本
#'
#' ⚠️ 必须用 \n 拼接，不能用 "; "。用 "; " 会拼出
#'     for b in ...; do; w=$(...); done
#' 而 `do;` 是**语法错误**（do 后面必须直接跟命令），远端 bash 会报
#'     syntax error near unexpected token `;'
#' 后果是「测试连接」在**任何**配置下都失败，报出来的却是远端 shell 的
#' 语法错 —— 看着像对方机器有问题，其实是本地拼字符串拼坏了。
#'
#' 单独抽成函数是为了 selftest.R 能用 `bash -n` 静态检查它 —— 这类错误
#' 不连一次远程根本发现不了。
dsapp_ssh_probe <- function() {
  paste(
    "echo DSAPP_OK",
    "echo \"host=$(hostname)\"",
    "echo \"user=$(whoami)\"",
    "echo \"pwd=$(pwd)\"",
    # 探测远程有哪些解释器，后面执行要用
    "for b in Rscript python3 python conda mamba; do",
    "  w=$(command -v $b 2>/dev/null) && echo \"bin:$b=$w\"",
    "done",
    "exit 0",
    sep = "\n"
  )
}

#' 问出远程用户的主目录
#'
#' 必须真的去问一句，不能想当然地用 "~"。见 dsapp_run_remote 里的说明。
dsapp_ssh_home <- function(ctx, cfg = dsapp_config()) {
  r <- dsapp_ssh_run(ctx, "echo $HOME", timeout = 30, cfg = cfg)
  if (!isTRUE(r$ok)) return("")
  # 取最后一行非空输出：有些机器的 .bashrc 会先打点别的东西出来
  lines <- trimws(strsplit(r$stdout, "\n", fixed = TRUE)[[1]])
  lines <- lines[nzchar(lines)]
  h <- if (length(lines)) lines[length(lines)] else ""
  if (!grepl("^/", h)) "" else h
}

#' 在远程服务器上执行一段代码
#'
#' 与 dsapp_run_code 返回同样的结构，调用方（jobs.R）不用区分两种目标。
#'
#' 流程：建远程工作目录 → 传输入文件 → 传脚本 → 跑 → 取回整个目录 → 清理。
dsapp_run_remote <- function(code, lang = "R", task_id, target,
                             session_id = NULL,
                             cfg = dsapp_config()) {
  # ★ V13 item 6：远程那条路的产物是 scp 回来直接落进**文件管理区**的
  #   （下面 `dest <- dsapp_unique_path(cfg$files_dir, a)`），所以这里
  #   必须绑到发起这个任务的账号上。绑不上的话会落进 _anon —— 一个永远
  #   是空的占位目录：文件确实复制进去了，只是谁也看不见，而且不报错。
  cfg <- dsapp_config_user(
    if (is.null(session_id)) NA_integer_
    else tryCatch(db_session_owner(session_id, con = dsapp_db(cfg)),
                  error = function(e) NA_integer_), cfg)
  prep <- dsapp_ssh_ctx(target, cfg)
  if (!isTRUE(prep$ok)) {
    return(list(status = "error", exit_code = NA_integer_, stdout = "",
                stderr = prep$msg, workdir = NA_character_,
                artifacts = character(0), progress = NULL))
  }
  ctx <- prep$ctx
  on.exit(dsapp_ssh_cleanup(ctx), add = TRUE)

  # 远程根目录：用户没指定就用 <home>/dsapp_runs
  #
  # ⚠️ 不能直接把 "~/dsapp_runs" 交给 shQuote()。shQuote 会加上单引号，
  # 而**单引号里的 ~ 不做展开**，于是 mkdir 老老实实建了一个名字就叫 "~"
  # 的目录；紧接着 scp 走的是另一条展开路径，认的是 /home/xxx/dsapp_runs，
  # 于是报 "No such file or directory"。看起来像路径不存在或者没权限，
  # 实际是波浪号没被展开 —— 两处对 ~ 的处理方式不一致才露的馅。
  # 索性先问出真实的 home，之后全程用绝对路径。
  home <- dsapp_ssh_home(ctx, cfg)
  if (!nzchar(home)) {
    return(list(status = "error", exit_code = NA_integer_, stdout = "",
                stderr = "无法确定远程用户的主目录。请确认 SSH 能正常登录。",
                workdir = NA_character_, artifacts = character(0),
                progress = NULL))
  }
  remote_root <- if (!nzchar(ctx$workdir)) {
    file.path(home, "dsapp_runs")
  } else if (grepl("^~", ctx$workdir)) {
    sub("^~", home, ctx$workdir)          # 用户填了 ~/xxx
  } else if (grepl("^/", ctx$workdir)) {
    ctx$workdir                            # 用户填了绝对路径
  } else {
    file.path(home, ctx$workdir)           # 用户填了相对路径，挂到 home 下
  }
  remote_wd <- sprintf("%s/task-%s", remote_root, task_id)

  # ---- 本地暂存目录：待传的文件 + 取回的产物 ----
  stage <- file.path(cfg$work_dir, sprintf("remote-%s", task_id))
  if (dir.exists(stage)) unlink(stage, recursive = TRUE)
  dir.create(stage, recursive = TRUE, showWarnings = FALSE)

  # 输入文件复制一份到暂存区（不是软链 —— scp 会跟随软链但我们要控制方向）
  inputs <- character(0)
  for (f in list.files(cfg$files_dir, all.files = FALSE, no.. = TRUE)) {
    src <- file.path(cfg$files_dir, f)
    if (dir.exists(src)) next
    if (isTRUE(file.copy(src, file.path(stage, f), overwrite = TRUE))) {
      inputs <- c(inputs, f)
    }
  }

  script_name <- basename(dsapp_write_script(code, lang, stage))

  # ---- 建远程目录 ----
  mk <- dsapp_ssh_run(ctx, sprintf("mkdir -p %s", shQuote(remote_wd)), 60, cfg)
  if (!isTRUE(mk$ok)) {
    return(list(status = "error", exit_code = NA_integer_, stdout = "",
                stderr = paste0("无法在远程创建工作目录：\n", mk$stderr),
                workdir = NA_character_, artifacts = character(0),
                progress = NULL))
  }

  # ---- 传文件 ----
  push <- dsapp_ssh_push(ctx, stage, remote_wd, c(inputs, script_name), cfg)
  if (!isTRUE(push$ok)) {
    return(list(status = "error", exit_code = NA_integer_, stdout = "",
                stderr = push$msg, workdir = NA_character_,
                artifacts = character(0), progress = NULL))
  }

  # ---- 拼远程执行命令 ----
  #
  # 用户在设置里可以给一段「激活环境的命令」（比如
  # `source ~/miniconda3/bin/activate myenv`）。远程那台机器装了什么
  # 我们无从得知，让用户自己给一句 shell 片段，比我们猜要可靠得多。
  interp <- switch(lang, R = "Rscript", Python = "python3", Bash = "bash", "Rscript")
  if (identical(lang, "Bash")) {
    run_line <- sprintf("bash %s", shQuote(script_name))
  } else {
    # 解释器优先用 PATH 里的；没有就试 conda base；再没有就报错
    run_line <- sprintf(
      'if command -v %s >/dev/null 2>&1; then %s %s; else echo "远程找不到 %s" >&2; exit 127; fi',
      interp, interp, shQuote(script_name), interp)
  }

  activate <- if (nzchar(ctx$activate)) paste0(ctx$activate, " && ") else ""

  # 资源限制在远程也加一道：那台机器是用户的，但一个死循环同样会把
  # 它拖垮。ulimit 用 || true 兜底，某些受限 shell 里设不了。
  remote_cmd <- sprintf(
    "cd %s && %s{ ulimit -v %d 2>/dev/null || true; ulimit -t %d 2>/dev/null || true; %s; }",
    shQuote(remote_wd), activate,
    as.integer(cfg$exec$mem_mb) * 1024L,
    as.integer(cfg$exec$cpu_sec),
    run_line
  )

  run <- dsapp_ssh_run(ctx, remote_cmd, timeout = cfg$exec$timeout, cfg = cfg)

  # ---- 取回产物 ----
  pull_dir <- file.path(stage, ".result")
  dir.create(pull_dir, recursive = TRUE, showWarnings = FALSE)
  # 取回失败不致命（stdout 已经拿到了），但**不能一声不吭** ——
  # 之前这里就是静默忽略，结果 "/." 后缀导致的取回失败没人发现，
  # 用户只看到"产物是空的"，无从判断是没产出还是没取回来。
  pull_note <- ""
  pull <- dsapp_ssh_pull(ctx, remote_wd, pull_dir, cfg)
  if (!isTRUE(pull$ok)) {
    pull_note <- paste0("\n[提示] 产物回传失败，下面可能看不到远程生成的文件。\n",
                        pull$msg, "\n")
  }

  # 远程目录用完即删：那是用户的机器，别留垃圾
  try(dsapp_ssh_run(ctx, sprintf("rm -rf %s", shQuote(remote_wd)), 60, cfg),
      silent = TRUE)

  pulled <- list.files(pull_dir, recursive = TRUE, all.files = FALSE, no.. = TRUE)
  artifacts <- setdiff(basename(pulled),
                       c(script_name, inputs, "main.R", "main.py", "main.sh"))

  # 产物按名字回收进文件管理区，方便任务页直接下载
  saved <- character(0)
  for (a in artifacts) {
    hit <- list.files(pull_dir, pattern = paste0("^", gsub("([.\\\\+*?\\[^\\]$()])", "\\\\\\1", a), "$"),
                      recursive = TRUE, full.names = TRUE)
    if (!length(hit)) next
    src <- hit[[1]]
    if (dir.exists(src) || file.info(src)$size > 512 * 1024^2) next
    dest <- dsapp_unique_path(cfg$files_dir, a)
    if (isTRUE(file.copy(src, dest, overwrite = FALSE))) {
      # 和其它写入共享区的地方一样设只读（见 files.R 的 dsapp_files_protect）。
      # 远程这条路是唯一"自动"进共享区的了 —— 文件是从用户的机器 scp 回来
      # 的，本地没有工作区可以放它们。
      dsapp_files_protect(dest)
      saved <- c(saved, basename(dest))
    }
  }

  # keep = "tail"：和本地执行一致，报错在输出的最末尾（见 utils.R 的说明）
  stdout <- dsapp_truncate(run$stdout, cfg$exec$max_output_kb, keep = "tail")
  stderr <- paste0(dsapp_truncate(run$stderr, cfg$exec$max_output_kb,
                                  keep = "tail"), pull_note)

  status <- if (isTRUE(run$timed_out)) {
    "timeout"
  } else if (isTRUE(run$ok)) {
    "success"
  } else {
    "failed"
  }
  if (identical(status, "timeout")) {
    stderr <- paste0(stderr, sprintf(
      "\n\n[已强制终止] 远程执行超过 %d 秒。\n", as.integer(cfg$exec$timeout)))
  }

  list(
    status = status, exit_code = run$exit_code,
    stdout = stdout, stderr = stderr,
    # 远程执行的现场在用户自己的机器上，本地没有对应的 workdir
    workdir = NA_character_,
    artifacts = artifacts, saved = saved,
    progress = dsapp_parse_progress(run$stdout),
    remote_note = sprintf("在 %s 上执行", ctx$target)
  )
}
