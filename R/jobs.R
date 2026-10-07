# =============================================================================
# 后台作业
# =============================================================================
# 代码执行必须在独立进程里跑。直接在 Shiny 进程里调 dsapp_run_code() 的话，
# 一段跑 10 分钟的 RunUMAP 会让**所有用户**的页面一起卡死 10 分钟 ——
# Shiny Server 下一个应用只有一个 R 进程，所有会话共享它。
#
# 用 callr::r_bg() 而不是 future/ExtendedTask：子进程里显式 source() 需要的
# R 文件，依赖关系是确定的。future 靠自动识别全局变量来导出，一旦漏掉某个
# 嵌套引用的函数，症状是"任务莫名报 could not find function"，
# 而且只在特定代码路径下出现，很难查。
#
# 子进程和 LLM 流式那边一样，通过文件回传结果。
# =============================================================================

#' 后台进程需要 source 的文件
#'
#' 不含 mod_*.R（那些是 UI，子进程用不到）和 app.R。
dsapp_core_files <- function(app_dir) {
  files <- c("config.R", "utils.R", "db.R", "scanner.R",
             "executor.R", "files.R", "prompts.R", "llm.R", "proxy.R")
  paths <- file.path(app_dir, "R", files)
  paths[file.exists(paths)]
}

#' 子进程入口
#'
#' ⚠️ 序列化后送到全新 R 进程执行，不能引用外部函数。
#'
#' target 决定去哪儿跑：
#'   list(kind = "server", env = "system"|"<环境名>")  —— 本机
#'   list(kind = "remote", remote = list(...))         —— SSH 到用户自己的机器
.dsapp_job_worker <- function(app_dir, code, lang, task_id, result_file,
                              target, session_id = NA_integer_,
                              data_root = NULL) {
  # ---- 数据目录跟着**父进程**，不跟着配置文件重新推导 ----
  #
  # ⚠️ 这一句必须在任何 dsapp_config() 之前跑。子进程是全新的 R，它启动时
  #    会读一次 `<工作目录>/.Renviron`（工作目录就是应用目录），而
  #    **.Renviron 里的值会覆盖继承来的同名环境变量**（R 的既定行为，那份
  #    文件自己顶上也是这么写的）。于是会出现：
  #      · 父进程用 A 目录（比如自检把 DSAPP_DATA_ROOT 指到临时目录），
  #      · 子进程读 .Renviron 拿到 B 目录（真实数据目录），
  #      · 任务把产物写进 B，父进程去 A 里找 —— 什么都没找到，也不报错。
  #    2026-09-14 就是这条让 tests/agent_loop.R 的两条产物断言变红，而
  #    真实的数据目录里凭空多出了测试写下的文件。
  #
  #    运行期 Sys.setenv 是**跑在 .Renviron 之后**的，所以这一句能盖回去。
  #    修在这里而不是在测试里，是因为生产上同样会歪：改完 .Renviron 还没
  #    重启时，子进程会用新目录、父进程还在用旧目录（库连接早就建好了），
  #    表现是"任务成功了但产物不见了"。
  if (!is.null(data_root) && nzchar(as.character(data_root)[1])) {
    Sys.setenv(DSAPP_DATA_ROOT = as.character(data_root)[1])
  }

  write_result <- function(obj) {
    tmp <- paste0(result_file, ".tmp")
    writeLines(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null",
                                force = TRUE), tmp)
    # 先写临时文件再原子改名，避免父进程读到写了一半的 JSON
    file.rename(tmp, result_file)
  }

  tryCatch({
    for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
      # 跳过 UI 模块：它们依赖 shiny，子进程里没必要加载
      if (grepl("^mod_", basename(f))) next
      source(f, local = globalenv())
    }

    kind <- target$kind %||% "server"

    res <- if (identical(kind, "remote")) {
      dsapp_run_remote(code, lang, task_id, target, session_id = session_id)
    } else {
      dsapp_run_code(code, lang, task_id, env_name = target$env %||% "system",
                     session_id = session_id)
    }

    # ⚠️ 本地执行的产物**不再**自动回收进文件管理区。
    #
    # 产物就留在对话工作区里 —— 那本来就是可写、可下载、可发布的地方
    # （见 utils.R 的 dsapp_ws_dir 和 files.R 的 dsapp_publish_artifact）。
    # agent 一次跑六轮，每轮都往共享区倒一遍中间文件的话，「文件」页和
    # 模型下一轮看到的文件清单会一起被淹掉。
    #
    # 远程那条路是例外：产物是 scp 回本机的，本地没有对应的工作区可以放，
    # 所以 dsapp_run_remote 仍然直接收进共享区并把清单放在 res$saved 里。
    saved <- if (!is.null(res$saved)) as.character(unlist(res$saved)) else character(0)

    write_result(list(
      ok = TRUE, status = res$status, exit_code = res$exit_code,
      stdout = res$stdout, stderr = res$stderr, workdir = res$workdir,
      artifacts = as.list(res$artifacts), saved = as.list(saved),
      progress = res$progress, remote_note = res$remote_note,
      env_notes = as.list(res$env_notes %||% character(0)),
      # ★ V13.12 item 8：产物体检的结果。见 executor.R 的
      # dsapp_artifact_check() —— 报的是"这次的分析结论底下没有数据"。
      bad_artifacts = as.list(res$bad_artifacts %||% character(0))
    ))
  }, error = function(e) {
    write_result(list(ok = FALSE, status = "error",
                      stderr = conditionMessage(e)))
  })
}

#' 提交一个执行作业
#'
#' 非阻塞，立刻返回句柄。
dsapp_job_start <- function(code, lang, task_id, cfg = dsapp_config(),
                            target = list(kind = "server", env = "system"),
                            session_id = NA_integer_) {
  result_file <- file.path(cfg$run_dir, paste0("job-", task_id, ".json"))
  unlink(result_file)

  log_base <- file.path(cfg$logs_dir, paste0("job-", task_id))

  proc <- callr::r_bg(
    func = .dsapp_job_worker,
    args = list(app_dir = cfg$app_dir, code = code, lang = lang,
                task_id = task_id, result_file = result_file,
                target = target, session_id = session_id,
                # 子进程不许自己去推导数据目录，用父进程这份（理由见 worker）
                data_root = cfg$data_root),
    stdout = paste0(log_base, ".out"),
    stderr = paste0(log_base, ".err"),
    supervise = TRUE
  )

  list(proc = proc, result_file = result_file, task_id = task_id)
}

#' 查询作业状态
#'
#' @return list(done, result, alive)
dsapp_job_poll <- function(handle) {
  if (is.null(handle)) {
    return(list(done = TRUE, alive = FALSE,
                result = list(ok = FALSE, status = "error",
                              stderr = "无效的作业句柄")))
  }

  if (file.exists(handle$result_file)) {
    res <- tryCatch(
      jsonlite::fromJSON(readLines(handle$result_file, warn = FALSE),
                         simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(res)) {
      return(list(done = TRUE, alive = FALSE, result = res))
    }
  }

  alive <- !is.null(handle$proc) && handle$proc$is_alive()
  list(done = !alive, alive = alive, result = NULL)
}

#' 中止作业
dsapp_job_abort <- function(handle) {
  if (is.null(handle)) return(invisible(FALSE))
  if (!is.null(handle$proc) && handle$proc$is_alive()) {
    try(handle$proc$kill(), silent = TRUE)
  }
  invisible(TRUE)
}

#' 通用后台任务：跑一个"核心层"函数并把返回值带回来
#'
#' 为什么需要它：像「拉厂商模型列表」「测试 SSH 连接」这类操作，本质都是
#' 一次同步网络请求（超时 20–60 秒）。在 Shiny 进程里直接调用，就等于让
#' **所有用户**一起等 —— Shiny Server 开源版一个应用只有一个 R 进程。
#' 和代码执行、LLM 对话一样，必须丢到子进程。
#'
#' fn 必须是 R/ 下定义、且不依赖 shiny 的函数（子进程会把 R/*.R 里
#' 非 mod_ 的文件全部 source 一遍）。
#'
#' @return list(proc, result_file)
dsapp_bg_start <- function(fn, args = list(), cfg = dsapp_config(),
                           tag = "bg") {
  if (!dir.exists(cfg$run_dir)) {
    dir.create(cfg$run_dir, recursive = TRUE, showWarnings = FALSE)
  }
  # ★ V16.10：`logs_dir` 也得建。下面 `r_bg()` 的 stdout/stderr 是指到那里面
  #   的文件 —— 目录不存在时 processx 报的是
  #   「cannot start processx process '/usr/lib/R/bin/R' (system error 2)」，
  #   指向的是 R 解释器本身（它明明在），和真正的原因（日志目录不在）差着
  #   十万八千里。生产上这个目录在应用起步时就建好了，所以一直没露出来；
  #   任何"换个 data_root 起一次性实例"的场景都会撞上（2026-10-07 实测）。
  if (!dir.exists(cfg$logs_dir)) {
    dir.create(cfg$logs_dir, recursive = TRUE, showWarnings = FALSE)
  }
  result_file <- file.path(cfg$run_dir,
                           paste0(tag, "-", dsapp_id("b"), ".json"))
  unlink(result_file)

  proc <- callr::r_bg(
    func = .dsapp_bg_worker,
    args = list(app_dir = cfg$app_dir, fn = fn, args = args,
                result_file = result_file),
    stdout = file.path(cfg$logs_dir, paste0(tag, ".out")),
    stderr = file.path(cfg$logs_dir, paste0(tag, ".err")),
    supervise = TRUE
  )
  list(proc = proc, result_file = result_file, tag = tag)
}

#' 通用后台任务的子进程入口
#'
#' ⚠️ 序列化后送到全新 R 进程执行，不能引用外部函数。
.dsapp_bg_worker <- function(app_dir, fn, args, result_file) {
  write_result <- function(obj) {
    tmp <- paste0(result_file, ".tmp")
    writeLines(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null",
                                force = TRUE), tmp)
    file.rename(tmp, result_file)
  }
  tryCatch({
    for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
      # 跳过 UI 模块：它们依赖 shiny，子进程里没必要加载
      if (grepl("^mod_", basename(f))) next
      source(f, local = globalenv())
    }
    write_result(list(ok = TRUE, value = do.call(fn, args)))
  }, error = function(e) {
    write_result(list(ok = FALSE, msg = conditionMessage(e)))
  })
}

#' 查通用后台任务结果
#'
#' @return list(done, ok, value, msg)
dsapp_bg_poll <- function(handle) {
  if (is.null(handle)) {
    return(list(done = TRUE, ok = FALSE, value = NULL, msg = "无句柄"))
  }
  if (file.exists(handle$result_file)) {
    res <- tryCatch(
      jsonlite::fromJSON(readLines(handle$result_file, warn = FALSE),
                         simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(res)) {
      return(list(done = TRUE, ok = isTRUE(res$ok),
                  value = res$value, msg = res$msg %||% ""))
    }
  }
  alive <- !is.null(handle$proc) && handle$proc$is_alive()
  list(done = !alive, ok = FALSE, value = NULL,
       msg = if (alive) "" else "子进程意外退出")
}

#' 从消息内容里按序号取出代码块
#'
#' ⚠️ 这是安全属性，不是便利函数。
#'
#' 浏览器只会发来一个坐标（"第 42 条消息的第 2 个代码块"），代码内容一律
#' 由服务端从数据库重新读取并重新解析。这样即使有人在浏览器里改了 DOM，
#' 也没法让平台执行一段没被扫描过的代码。
#'
#' @return list(code, lang)；越界或格式不对时返回 NULL
dsapp_extract_block <- function(content, index) {
  blocks <- dsapp_parse_code_blocks(content)
  if (index < 1 || index > length(blocks)) return(NULL)
  blocks[[index]]
}

#' 解析 Markdown 里的围栏代码块
#'
#' ★★ 这个解析器必须和 render.R 的 dsapp_split_segments_raw() 数出**一样多**
#'    的块（mod_chat.R 里那句提醒）：一个决定"界面上画几张代码卡、点哪张
#'    执行哪块"，另一个决定"agent 循环跑哪一块"。两边的围栏判定现在都走
#'    render.R 的 dsapp_fence_open() —— 只有一份规则，才不会各认各的。
#'
#' 返回 list(list(lang=, code=), ...)。
dsapp_parse_code_blocks <- function(content) {
  if (is.null(content) || !nzchar(content)) return(list())

  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]
  blocks <- list()
  i <- 1
  n <- length(lines)

  while (i <= n) {
    # 围栏起始：``` 后跟可选的语言标注（可以粘在正文后面，见 dsapp_fence_open）
    fo <- dsapp_fence_open(lines[i])
    if (!is.null(fo)) {
      i0      <- i
      lang    <- fo$lang
      n_ticks <- fo$ticks
      body <- character(0)
      i <- i + 1
      # 收集到下一个围栏为止（结束围栏仍要求独占一行，且反引号不少于开围栏，
      # 判定和渲染侧共用 render.R 的 dsapp_fence_close()）
      while (i <= n && !dsapp_fence_close(lines[i], n_ticks)) {
        body <- c(body, lines[i])
        i <- i + 1
      }
      closed <- i <= n
      i <- i + 1   # 跳过结束围栏

      if (length(body) == 0 && !closed) {
        # ★ V15.6：空块 + 没闭合 = 不是代码块，是正文里一句以 ``` 收尾的话。
        #   整行跳过就行，别把它后面的正文当块内容吞掉（原来会吞）。
        i <- i0 + 1
      } else if (length(body) > 0) {
        blocks[[length(blocks) + 1]] <- list(
          lang = dsapp_norm_lang(lang),
          # ⚠️ 必须解码，理由见 render.R 里同一处的注释和 utils.R 的
          #    dsapp_decode_uescapes()：模型写的字面 \uXXXX 落在符号位置
          #    时 R 解析不了，task#11 就是这么整段跑不起来的。
          #    这里是**执行**那条路的入口，漏了它测试全绿而线上照挂。
          code = dsapp_decode_uescapes(paste(body, collapse = "\n"))
        )
      }
    } else {
      i <- i + 1
    }
  }
  blocks
}

#' 归一化代码块语言标注
dsapp_norm_lang <- function(lang) {
  l <- tolower(trimws(lang %||% ""))
  if (l %in% c("r", "rscript")) return("R")
  if (l %in% c("python", "py", "python3")) return("Python")
  if (l %in% c("shell", "bash", "sh", "zsh", "console")) return("Bash")
  # 没标注或标了别的（json/txt/...）：不当作可执行代码
  "Text"
}
