# =============================================================================
# 代码静态扫描
# =============================================================================
# ⚠️ 定位说明（重要，别把它当沙箱）
#
# 这一层拦的是**误伤**，不是**攻击**。
#
# 它真正能防住的场景是：模型幻觉出一段 `unlink("/", recursive=TRUE)`，
# 或者用户从网上抄来的脚本里带着 `rm -rf`。这类"手滑"是真实且高频的。
#
# 它防不住的是：任何有意规避的人。正则匹配对字符串拼接、
# base64 编码、变量替换统统无效 —— `f("r","m"," -rf /")` 就能绕过。
#
# 真正的安全边界在操作系统层面，不在这里：
#   1. 应用以非 root 的 `shiny` 用户运行（写入范围受文件权限约束）
#   2. 每次执行使用独立工作目录（相对路径跑不出去）
#   3. rlimit 限制 CPU 时间 / 内存 / 进程数（见 executor.R）
#
# 所以本模块的产出是"提示与拦截建议"，真正的把关在用户点击【确认执行】
# 那一下。UI 上必须如实告诉用户这一点，不能让人以为点了执行就万无一失。
# =============================================================================

#' 扫描规则表
#'
#' severity:
#'   block —— 明确破坏系统或越权，拒绝提交
#'   warn  —— 可疑，放行但要在界面上提示用户确认
dsapp_scan_rules <- function() {
  r <- function(id, pattern, reason, severity = "block") {
    list(id = id, pattern = pattern, reason = reason, severity = severity)
  }

  list(
    # ---- 破坏性文件操作 ----
    r("rm_root", "rm\\s+(-[a-zA-Z]+\\s+)*/(\\s|$|\\*)",
      "删除根目录"),
    r("rm_rf_broad", "rm\\s+-[a-zA-Z]*r[a-zA-Z]*f?\\s+(-[a-zA-Z]+\\s+)*(/|~|\\$HOME|/home|/data|/srv)",
      "对系统目录或家目录执行递归删除"),
    r("rm_wildcard_root", "rm\\s+-[a-zA-Z]*\\s+/\\*",
      "删除根目录下所有内容"),

    r("mkfs", "\\bmkfs(\\.|\\s|$)", "格式化文件系统"),
    r("dd_dev", "\\bdd\\b.*\\bof\\s*=\\s*/dev/", "向块设备裸写数据"),
    r("shred_dev", "\\bshred\\b.*/dev/", "覆写块设备"),

    # ---- 系统控制 ----
    r("shutdown", "\\b(shutdown|reboot|poweroff|halt)\\b", "关机或重启系统"),
    r("init_runlevel", "\\binit\\s+[06]\\b", "切换运行级别（关机/重启）"),
    r("kill_all", "\\bkill\\s+-9\\s+-1\\b|\\bkillall5\\b", "杀死所有进程"),

    # ---- 权限与提权 ----
    r("sudo", "\\bsudo\\b", "提权执行"),
    r("chmod_root", "chmod\\s+(-[a-zA-Z]+\\s+)*777\\s+/", "把系统目录权限改为 777"),
    r("chown_root", "chown\\s+(-[a-zA-Z]+\\s+)*[^\\s]+\\s+/(\\s|$)", "修改系统目录属主"),

    # ---- 写入系统路径 ----
    r("write_etc", ">\\s*/etc/|\\btee\\s+/etc/", "改写 /etc 下的系统配置"),
    r("write_boot", ">\\s*/boot/", "改写引导分区"),
    r("write_passwd", "/etc/(passwd|shadow|sudoers)", "接触系统账户文件"),
    r("write_sys", ">\\s*/(sys|proc)/", "改写内核接口"),

    # ---- 反弹 shell 与远程执行 ----
    r("dev_tcp", "/dev/tcp/", "反弹 shell 的典型特征"),
    r("nc_exec", "\\b(nc|ncat|netcat)\\b[^\\n]*\\s-[a-zA-Z]*e", "netcat 执行远程命令"),
    r("bash_reverse", "bash\\s+-i\\s+>&", "交互式反弹 shell"),
    r("pipe_shell", "(curl|wget)\\s[^\\n|]*\\|\\s*(ba)?sh", "下载后直接管道执行脚本"),
    r("base64_shell", "base64\\s+-d[^\\n|]*\\|\\s*(ba)?sh", "解码后管道执行脚本"),

    # ---- 持久化 ----
    r("crontab", "\\bcrontab\\b", "修改计划任务（持久化）"),
    r("systemctl", "\\bsystemctl\\b", "操作 systemd 服务"),
    r("rc_local", "/etc/rc\\.local|/etc/init\\.d/", "改写开机启动项"),

    # ---- 凭据与痕迹 ----
    r("ssh_keys", "\\.ssh/(id_rsa|id_ed25519|id_ecdsa|authorized_keys)",
      "读取或改写 SSH 密钥"),
    r("cloud_creds", "\\.aws/credentials|\\.config/gcloud|\\.kube/config",
      "读取云平台凭据"),
    r("env_files", "\\.Renviron|\\.bashrc|\\.profile|\\.bash_history",
      "读取或改写 shell 环境与历史"),
    r("history_tamper", "\\bhistory\\s+-c\\b|\\bunset\\s+HISTFILE|HISTFILE\\s*=",
      "清除或关闭命令历史"),

    # ---- 语言层等价物（R / Python 里绕开 shell 的写法）----
    r("r_unlink_root", "unlink\\s*\\(\\s*[\"']/[\"']\\s*,\\s*recursive\\s*=\\s*TRUE",
      "R：递归删除根目录"),
    r("r_system_rm", "system\\s*\\([^)]*rm\\s+-[a-zA-Z]*r",
      "R：通过 system() 执行递归删除"),
    r("r_file_remove", "file\\.remove\\s*\\([^)]*/etc/", "R：删除系统文件"),
    r("py_rmtree_root", "shutil\\.rmtree\\s*\\(\\s*[\"']/[\"']", "Python：递归删除根目录"),
    r("py_os_system_rm", "os\\.system\\s*\\([^)]*rm\\s+-[a-zA-Z]*r",
      "Python：通过 os.system() 执行递归删除"),
    r("py_subprocess_shell", "subprocess\\.[a-z]+\\s*\\([^)]*shell\\s*=\\s*True",
      "Python：以 shell=True 执行外部命令"),

    # ---- 外发数据（**只记一笔**，不再拦、也不再问；见下面的说明）----
    #
    # ★★ V15.6 item 5：用户的原话是「发起网络请求不需要用户同意，可以直接
    #    执行」。这两条以前是"停下循环弹个确认框"的那一类，现在降到纯记录。
    #
    # ⚠️ 中间那个 `[^\\n|;&]*` 不能写回 `[^\\n]*`（V15.6 item 13）：
    #    `[^\\n]*` 能跨过管道符，于是 `curl -sL URL | tr -d '\\r'` 这种
    #    **本地管道**会被读成"curl 在往外发数据"——`-d` 根本不是 curl 的，
    #    是 tr 的。命中之后弹出的确认框，用户看着一段毫无问题的代码，
    #    唯一能做的就是点「继续」。写成 `[^\\n|;&]*` 之后，`-d` 必须和
    #    `curl|wget` 出现在**同一条命令**里，跨管道就断开了。
    r("exfil_curl_post", "(curl|wget)\\s[^\\n|;&]*(-d|--data|--upload-file|-T)\\s",
      "命令行往外部地址发送数据", severity = "warn"),
    r("net_http_lib", "\\b(requests\\.(post|put)|urllib\\.request\\.urlopen|httr2?::req_)",
      "代码里发起网络请求", severity = "warn"),
    r("rm_any_recursive", "rm\\s+-[a-zA-Z]*r[a-zA-Z]*f?\\s",
      "递归删除，请确认路径正确", severity = "warn")

    # ★ V13.8 item 3：这里原来还有一条
    #     r("install_pkg", "install\\.packages\\s*\\(|pip\\s+install\\s|BiocManager::install",
    #       "会联网安装依赖，沙箱可能无外网权限", severity = "warn")
    #   用户的原话是「联网装包不用风险提示」，删掉了。
    #
    # ⚠️ 别再按"这条提示其实挺有用"把它加回来。它挡住的从来不是危险动作：
    #    装包本来就是这个平台**鼓励**发生的事（每个对话有自己的 R 包目录，
    #    见 prompts.R 的 build_lib_section），而这条 warn 级规则的效果是
    #    「模型写一段 install.packages()，用户被弹窗拦下来做一次他没法判断的
    #    决定」—— 他既不知道装的是什么，也没有"不装"这个选项（不装就跑不动）。
    #    真正的外发风险由 exfil_curl_post / net_http_lib 那两条管，它们才是
    #    "数据要离开这台机器"的信号；装包不是。
    #
    # ⚠️ 受影响的不止手动路径：dsapp_scan_message() 里那句"**请注意**，以下
    #    内容需要你确认"也跟着这条规则走，删掉之后它少一整类触发源。留着
    #    别的 warn 规则，所以那段渲染逻辑不用动。
  )
}

#' 扫描代码
#'
#' 逐行匹配，这样报错能给出准确行号 —— 只说"你的代码里有危险指令"而
#' 不说是哪一行，用户在一百多行的脚本里根本找不到。
#'
#' @return list(blocked = <data.frame>, warnings = <data.frame>)
#'   两个 data.frame 都可能 0 行；列：line, rule, reason, snippet
dsapp_scan_code <- function(code) {
  empty <- data.frame(line = integer(0), rule = character(0),
                      reason = character(0), snippet = character(0),
                      stringsAsFactors = FALSE)

  if (is.null(code) || !nzchar(code)) {
    return(list(blocked = empty, warnings = empty))
  }

  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  rules <- dsapp_scan_rules()

  hits <- list()
  for (rule in rules) {
    # 整段代码先匹配一次做快速排除：绝大多数规则在绝大多数代码上都不命中，
    # 省下的是逐行 regex 的开销（一份 200 行脚本 × 30 条规则）。
    if (!grepl(rule$pattern, code, perl = TRUE, ignore.case = TRUE)) next

    idx <- grep(rule$pattern, lines, perl = TRUE, ignore.case = TRUE)
    for (i in idx) {
      hits[[length(hits) + 1]] <- data.frame(
        line    = i,
        rule    = rule$id,
        reason  = rule$reason,
        severity = rule$severity,
        # 片段截断，避免超长行（比如压缩过的 JS）把界面撑破
        snippet = substr(trimws(lines[i]), 1, 120),
        stringsAsFactors = FALSE
      )
    }
  }

  if (length(hits) == 0) {
    return(list(blocked = empty, warnings = empty))
  }

  all_hits <- do.call(rbind, hits)
  all_hits <- all_hits[order(all_hits$line), , drop = FALSE]
  rownames(all_hits) <- NULL

  list(
    blocked  = all_hits[all_hits$severity == "block",
                        c("line", "rule", "reason", "snippet"), drop = FALSE],
    warnings = all_hits[all_hits$severity == "warn",
                        c("line", "rule", "reason", "snippet"), drop = FALSE]
  )
}

#' 把扫描结果渲染成给用户看的中文说明
#'
#' @param md 要不要保留 `**…**` 这两个加粗记号。**默认保留**，因为这份文本
#'   的主要去向是**回喂给模型**（R/agent.R 里那段 feed_back）—— 那里走的是
#'   正常 markdown 渲染，`**已拒绝执行**` 比"已拒绝执行"更不容易被模型忽略。
#'
#'   弹窗那条路（R/mod_chat.R）是塞进 `<pre>` 的：`<pre>` 原样显示、不渲染
#'   markdown，于是同样这段文本会带着两个字面的星号出现在用户面前。所以那
#'   两处传 `md = FALSE`。
#'
#'   ⚠️ 别把默认值改成 FALSE 去迁就弹窗：回喂那条路才是主要用途，而且模型
#'      看不懂的记号只是"少了点强调"，用户看不懂的记号是"这软件坏了"。
#'      两边各让一步，改的是调用点，不是默认值。
dsapp_scan_message <- function(scan, md = TRUE) {
  fmt <- function(df) {
    paste(sprintf("· 第 %d 行：%s\n    %s", df$line, df$reason, df$snippet),
          collapse = "\n")
  }
  parts <- character(0)
  if (nrow(scan$blocked)) {
    parts <- c(parts, paste0("**已拒绝执行**，命中以下高危指令：\n", fmt(scan$blocked)))
  }
  if (nrow(scan$warnings)) {
    parts <- c(parts, paste0("**请注意**，以下内容需要你确认：\n", fmt(scan$warnings)))
  }
  txt <- paste(parts, collapse = "\n\n")
  # fixed = TRUE：这里是字面量替换，不是正则。写成正则的话 `**` 里的 `*`
  # 会被当成量词，`gsub("**", ...)` 直接是个错的正则（PCRE 里是"前一个字符
  # 重复零次"），而它会不会报错取决于引擎 —— 不去赌这个。
  if (!isTRUE(md)) txt <- gsub("**", "", txt, fixed = TRUE)
  txt
}
