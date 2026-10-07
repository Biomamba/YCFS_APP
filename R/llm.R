# =============================================================================
# LLM 层（DeepSeek，流式）
# =============================================================================
# 为什么这么绕：R 里没有能在 Shiny 单进程模型下"边收边渲染"的非阻塞 HTTP
# 客户端。httr2::req_perform_stream() 是同步阻塞的 —— 直接在 Shiny 进程里
# 调它，整个应用会卡住，其他用户的页面全部无响应。
#
# 所以走这条链路：
#
#     Shiny 主进程                     callr 子进程
#     ────────────                     ────────────
#     起子进程 ───────────────────────▶ 发流式请求
#                                      │ 每收到一个 delta
#                                      ▼ 追加写入 out 文件
#     每 150ms 轮询 out 文件 ◀─────────┘
#     增量渲染到界面
#                                      ▼ 结束后写 status 文件
#     读到 status 就收尾 ◀─────────────┘
#
# 代价是文件轮询有约 150ms 延迟（肉眼看不出），换来的是主进程全程不阻塞。
#
# 子进程是**独立 R 进程**，所以下面的 .dsapp_llm_worker() 必须是自包含的：
# 它不能引用本文件外的任何函数（那些在父进程的内存里，子进程看不见）。
# =============================================================================

#' 子进程里执行的流式请求
#'
#' ⚠️ 这个函数会被序列化后送到全新 R 进程里执行，**不能**引用 DS_App 的其他函数。
#' 所有依赖都必须通过参数传入或用 :: 显式调用。
#'
#' @return 无返回值；一切通过 out_file / status_file 传递
.dsapp_llm_worker <- function(api_key, base_url, model, messages,
                              out_file, status_file, timeout,
                              temperature, max_tokens, reason_file = NULL,
                              thinking = NULL, reasoning_effort = NULL,
                              omit_temperature = FALSE,
                              omit_max_tokens = FALSE,
                              proxy_opts = NULL) {
  write_status <- function(status, error = NULL, usage = NULL,
                           finish_reason = NULL, complete = NULL) {
    tmp <- paste0(status_file, ".tmp")
    writeLines(jsonlite::toJSON(
      list(status = status, error = error, usage = usage,
           finish_reason = finish_reason, complete = complete),
      auto_unbox = TRUE, null = "null"
    ), tmp)
    # 先写临时文件再改名：父进程可能正好在读，直接覆写会让它读到半个 JSON
    file.rename(tmp, status_file)
  }

  con <- NULL
  rcon <- NULL
  tryCatch({
    url <- paste0(sub("/+$", "", base_url), "/chat/completions")

    body <- list(
      model       = model,
      messages    = messages,
      stream      = TRUE,
      # 让服务端在最后一个 chunk 里带上 token 用量
      stream_options = list(include_usage = TRUE)
    )

    # ---- 「不设上限」= 请求体里不带 max_tokens（V13.14 item 22）----------
    #
    # 用户把滑块拉到最右那一格时，他要的是"别替我设上限"。能满足这个要求的
    # 只有一种写法：**不发这个字段**，让服务端用它自己那套默认值。发一个很大
    # 的数（哪怕是 10485760）语义是"上限是一千万"，那是另一个意思，而且大多数
    # 模型会直接 400（超过它的上下文窗口）。
    #
    # ⚠️⚠️ 判据由**父进程**算好传进来（omit_max_tokens），这里**不能**调
    #     dsapp_maxtok_is_unlimited()。这个函数是被 callr 序列化后送到一个
    #     全新 R 进程里跑的（见文件顶部），子进程里没有 DS_App 的任何函数 ——
    #     调了就是 could not find function，而且报在**用户发完消息之后**，
    #     看起来像"发消息这个功能坏了"。和上面 omit_temperature 是同一条
    #     约束、同一个理由，selftest 里那条"子进程函数必须自包含"盯着它。
    if (!isTRUE(omit_max_tokens)) body$max_tokens <- max_tokens

    # ---- 思考模式（DeepSeek）--------------------------------------------
    #
    # 关掉思考模式时才发 temperature：官方原文是「思考模式不支持
    # temperature……设置参数不会报错，但也不会生效」。既然不生效，就别发，
    # 免得后来看日志的人以为它管用。
    #
    # reasoning_effort 是真正管"思考多久/多深"的那个旋钮，取值
    # none / low / high / max（none 等于关掉思考）。旧名 minimal 映射 low，
    # medium / xhigh 映射 high —— 这里只发规范值。
    if (!is.null(thinking)) {
      body$thinking <- list(type = if (isTRUE(thinking)) "enabled" else "disabled")
      if (isTRUE(thinking) && !is.null(reasoning_effort)) {
        body$reasoning_effort <- reasoning_effort
      }
    }
    if (is.null(thinking) || !isTRUE(thinking)) {
      # ⚠️ 有些模型**只接受 temperature = 1**（月之暗面的 kimi-k* 就是，
      #    官方报错原文："invalid temperature: only 1 is allowed for this
      #    model"）。对它们根本不发这个字段：
      #      · 发 0.3 → 400，对话整个用不了（2026-09-16 线上就是这个）
      #      · 发 1   → 能用，但把厂商的一个私有规则写死进了请求里，
      #                 哪天规则变了这里就是一条新的 400
      #      · 不发   → 服务端用它自己的默认值，而"唯一合法的值"必然
      #                 就是它的默认值。这是唯一不需要猜数字的写法。
      #
      # ⚠️⚠️ 判断**由父进程做完再传进来**（omit_temperature），这里**不能**
      #     调 dsapp_model_temp_locked()。这个函数是被 callr 序列化后送到
      #     一个全新 R 进程里跑的（见文件顶部），子进程里没有 DS_App 的任何
      #     函数 —— 调了就是 could not find function，而且报在**用户发完
      #     消息之后**，看起来像"发消息这个功能坏了"。
      #     2026-09-16 就是这么坏的：写这一行的时候忘了这条约束，而自检里
      #     那个假 HTTP 服务是**同进程直接调**这个函数的，压根走不到 callr
      #     那条路上，所以全绿。现在自检里加了一条机械守卫，见 selftest.R
      #     的「子进程函数必须自包含」那一段。
      if (!isTRUE(omit_temperature)) body$temperature <- temperature
    }

    req <- httr2::request(url)
    req <- httr2::req_headers(req,
      Authorization = paste("Bearer", api_key),
      `Content-Type` = "application/json",
      Accept = "text/event-stream"
    )
    req <- httr2::req_body_json(req, body)
    # ---- ★ Test_V16.3 item 2：代理（VPN）------------------------------
    #
    # ⚠️⚠️ 这里**不能**写 `dsapp_proxy_apply(req, ...)`。本函数是被 callr
    #    序列化后送到一个全新 R 进程里跑的（见文件顶部），子进程里没有
    #    DS_App 的任何函数 —— 调了就是 could not find function，而且报在
    #    **用户发完消息之后**，看起来像"发消息这个功能坏了"。和上面
    #    omit_temperature / omit_max_tokens 是同一条约束、同一个理由，
    #    selftest 里那条"子进程函数必须自包含"盯着它。
    #
    #    选项是父进程用 dsapp_proxy_opts() 算好、当参数传进来的一个**纯
    #    list**（一个函数、一个 dsapp_* 名字都没有）。这里只负责贴上去。
    #
    # ⚠️ do.call 而不是 `!!!`：rlang 在这个子进程里**没有**被 library 过，
    #    而 req_options 要的正是"把 list 摊成 ..."这一件事。
    if (length(proxy_opts)) {
      req <- do.call(httr2::req_options, c(list(req), proxy_opts))
    }
    req <- httr2::req_timeout(req, timeout)
    # 关掉 httr2 的自动重试：流式请求重试会让用户看到重复内容，
    # 而且失败原因被吞掉后很难排查。
    req <- httr2::req_retry(req, max_tries = 1)
    # 4xx/5xx 不抛异常，让我们自己读错误体 —— 里面才是真正的报错信息
    req <- httr2::req_error(req, is_error = function(resp) FALSE)

    con <- file(out_file, open = "ab")
    # 思维链单独一个文件。混进正文的话，用户会看到一大段"思考"跟答案糊在
    # 一起；分开写，界面才能把思考过程折叠起来。
    if (!is.null(reason_file)) rcon <- file(reason_file, open = "ab")
    # ⚠️ 缓冲区存 **raw**，不是字符串。SSE 的 chunk 边界和字符边界毫无关系，
    #    一个中文/emoji 被切成两半是常态（1KB 一个 chunk，UTF-8 汉字三个字节）。
    #    先 rawToChar 再拼字符串的话，缓冲区里会留着半个 UTF-8 序列：
    #      * 这条字符串的编码是无效的，strsplit 每次都警告
    #        "input string 1 is invalid UTF-8"（线上日志里刷了满满一屏）；
    #      * 更致命的是 jsonlite::fromJSON 在这种行上直接解析失败 —— 那一行
    #        正文被整条丢掉，正文文件一个字节都写不进去，界面上就永远停在
    #        "正在思考"（.out 是 0 字节、.reason 却有几十 KB，就是这个样子）。
    #    所以缓冲按字节来，只在**完整行**（到 \n 为止）上解码。
    raw_buf <- raw(0)
    # 出错时用来还原 HTTP 错误体。成功路径上根本用不到，所以只留前 256KB ——
    # 对流式正文一直 c() 追加是 O(n²)，长回答会白白烧掉几秒。
    raw_all <- raw(0)
    RAW_ALL_CAP <- 262144L

    append_text <- function(txt) {
      if (!nzchar(txt)) return(invisible(NULL))
      writeBin(charToRaw(txt), con)
      flush(con)   # 不 flush 的话父进程要等缓冲区满才看得到，流式就没意义了
    }

    append_reason <- function(txt) {
      if (is.null(rcon) || !nzchar(txt)) return(invisible(NULL))
      writeBin(charToRaw(txt), rcon)
      flush(rcon)
    }

    # token 用量由服务端在最后一个 chunk 里给出（因为我们发了
    # stream_options.include_usage），形如：
    #   {"choices":[], "usage":{"prompt_tokens":..,"completion_tokens":..}}
    # 注意这个 chunk 的 choices 是**空数组** —— 下面取 delta 之前必须先判空，
    # 否则 obj$choices[[1]] 会下标越界报错，被 tryCatch 吞掉，用量就悄悄丢了。
    usage <- NULL

    # 结束原因。**必须收**，因为它决定"这段代码能不能执行"：
    # finish_reason == "length" 表示回复被 max_tokens 从中间截断了，
    # 最后一个代码围栏多半是半截的。agent 循环如果照跑，就是在跑一段
    # 语法都不完整的脚本，然后拿着莫名其妙的报错去让模型"改错"。
    # 实测服务端在最后一个带 choices 的 chunk 里给这个字段（之后还有
    # 一个只带 usage、choices 为空数组的 chunk）。
    #
    # ⚠️ 2026-09-14 改：**第一个非空值获胜**，不再是最后一个覆盖前面。
    #    原来那版是「一路覆盖着记」，注释里写的理由是"不能只看最后一拍"，
    #    但覆盖式记录恰恰**帮最后一拍掩盖了前面的真因**。线上有个会话
    #    （s-20260912215607-5136）正文只写了 30 个字就断了，落库的
    #    finish_reason 却是 "stop" —— 看起来一切正常，应用一声不吭。
    #    finish_reason 的语义是"这次生成为什么结束"，**有且只有一个**；
    #    厂商多给的那几个（代理补的、结束拍的重复值）才是噪音。
    finish_reason <- NULL

    # 有没有收到 `data: [DONE]`。
    #
    # DeepSeek 的 SSE 会被中间的 CDN / 代理**在响应中途掐断**，而掐断的表现
    # 和正常结束一模一样：连接正常关闭、httpr2 不报错、HTTP 200。区别只在
    # 于**没有 [DONE]**。不区分这两者的话，半截回答会被当成完整回答落库，
    # 用户看到的就是"它说到一半不说了"，而应用认为一切正常 —— 这正是
    # 用户报的"光消耗 token，不返回结果"。
    saw_done <- FALSE

    # SSE 按行解析。chunk 边界可能切在行中间，所以必须留缓冲区，
    # 只处理以 \n 结尾的完整行。
    handle_line <- function(line) {
      if (!startsWith(line, "data:")) return(invisible(NULL))  # 忽略 event:/id:/注释
      payload <- trimws(substring(line, 6))
      if (!nzchar(payload)) return(invisible(NULL))
      if (identical(payload, "[DONE]")) {
        saw_done <<- TRUE
        return(invisible(NULL))
      }

      obj <- tryCatch(jsonlite::fromJSON(payload, simplifyVector = FALSE),
                      error = function(e) NULL)
      if (is.null(obj)) return(invisible(NULL))
      if (!is.null(obj$error)) {
        msg <- obj$error$message
        stop(if (is.null(msg)) "服务端返回了未知错误" else msg)
      }

      # 先收用量：它可能和正文在同一个 chunk，也可能单独一个
      if (!is.null(obj$usage)) usage <<- obj$usage

      if (is.null(obj$choices) || length(obj$choices) == 0) return(invisible(NULL))
      # finish_reason 和 delta 同级。有的厂商在 delta 为 null 的那一拍才给
      # 它，所以要在下面 `d` 的判空**之前**收，否则会被提前 return 掉。
      fr <- obj$choices[[1]]$finish_reason
      if (!is.null(fr) && is.character(fr) && nzchar(fr) &&
          is.null(finish_reason)) finish_reason <<- fr

      d <- obj$choices[[1]]$delta
      if (is.null(d)) return(invisible(NULL))
      # 思考模式下，思维链在 reasoning_content 里，和 content 同级
      if (!is.null(d$reasoning_content) && nzchar(d$reasoning_content)) {
        append_reason(d$reasoning_content)
      }
      if (!is.null(d$content) && nzchar(d$content)) append_text(d$content)
      invisible(NULL)
    }

    resp <- httr2::req_perform_stream(req, callback = function(chunk) {
      if (length(chunk) == 0) return(TRUE)
      if (length(raw_all) < RAW_ALL_CAP) {
        raw_all <<- c(raw_all, chunk[seq_len(min(length(chunk),
                                                 RAW_ALL_CAP - length(raw_all)))])
      }
      raw_buf <<- c(raw_buf, chunk)

      # 按字节找换行；最后一段可能是半行（也可能半个字符），留在缓冲区里
      nl <- which(raw_buf == as.raw(0x0A))
      if (length(nl) > 0) {
        from <- 1L
        for (k in nl) {
          if (k > from) {
            # \r 是 SSE 里常见的行尾，去掉；其余原样交给 handle_line
            line <- tryCatch(rawToChar(raw_buf[from:(k - 1L)]),
                             error = function(e) NULL)
            if (!is.null(line)) handle_line(sub("\r$", "", line))
          }
          from <- k + 1L
        }
        raw_buf <<- if (from <= length(raw_buf)) raw_buf[from:length(raw_buf)]
                    else raw(0)
      }
      TRUE
    }, buffer_kb = 1)

    status <- httr2::resp_status(resp)

    if (status >= 400) {
      # 这时 raw_all 里装的其实是 JSON 错误体，不是 SSE
      body <- tryCatch(rawToChar(raw_all), error = function(e) "")
      msg <- tryCatch({
        e <- jsonlite::fromJSON(body, simplifyVector = FALSE)
        e$error$message %||% body
      }, error = function(e) body)
      write_status("error", error = sprintf("HTTP %d：%s", status, msg))
    } else {
      # 把用量一起写出去。以前这里只写 "done"，usage 参数明明留了位置却
      # 从来没人填 —— 于是界面上永远看不到这次花了多少 token。
      #
      # complete = 收到过 [DONE]。父进程靠它区分"正常结束"和"流被掐断"：
      # status 是 done、HTTP 是 200、正文也写了几个字，这些都可能是半截的。
      write_status("done", usage = usage, finish_reason = finish_reason,
                   complete = saw_done)
    }
  }, error = function(e) {
    write_status("error", error = conditionMessage(e))
  }, finally = {
    if (!is.null(con)) try(close(con), silent = TRUE)
    if (!is.null(rcon)) try(close(rcon), silent = TRUE)
  })
}

#' 发起一次流式对话
#'
#' 非阻塞：立刻返回一个句柄，调用方用 dsapp_llm_poll() 取增量。
#'
#' ⚠️ 句柄是 **environment 而不是 list**，这是个必须记住的坑。
#'
#' dsapp_llm_poll() 要把"读到第几个字节了"记回句柄上，下次轮询接着读。
#' 但 R 的 list 是值语义：函数里写 `handle$read_pos <- size` 改的是**函数内的
#' 那份副本**，调用方手里那个 list 纹丝不动。后果是每次轮询都从文件头重读
#' 一遍，界面上正文被反复叠加 —— 而且因为它不报错，只是内容重复，很难一眼
#' 看出是这里的问题。（V2 一直带着这个 bug，只是那会儿没人真正用对话功能。）
#'
#' environment 是引用语义，改的就是同一份，问题消失。
#'
#' @return environment(proc, out_file, status_file, reason_file, token,
#'                     read_pos, reason_pos)
dsapp_llm_start <- function(api_key, messages, model = NULL,
                            cfg = dsapp_config(),
                            temperature = 0.3, max_tokens = 65536,
                            base_url = NULL,
                            thinking = NULL, reasoning_effort = NULL,
                            proxy = NULL) {
  if (is.null(api_key) || !nzchar(api_key)) {
    stop("尚未填写 API Key")
  }
  # 厂商是在设置页选的，base_url 随会话走，不能只认 cfg 里的默认值。
  if (is.null(base_url) || !nzchar(base_url)) base_url <- cfg$llm$base_url

  run_dir <- cfg$run_dir
  if (!dir.exists(run_dir)) dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)

  token     <- paste0("llm-", as.integer(Sys.time()), "-", sprintf("%05d", sample.int(99999, 1)))
  out_file  <- file.path(run_dir, paste0(token, ".out"))
  stat_file <- file.path(run_dir, paste0(token, ".json"))
  rea_file  <- file.path(run_dir, paste0(token, ".reason"))

  # 先建空文件：父进程第一次轮询时文件必须已存在，否则要多写一堆
  # "文件还不存在"的分支判断。
  file.create(out_file)
  file.create(rea_file)
  unlink(stat_file)

  proc <- callr::r_bg(
    func = .dsapp_llm_worker,
    args = list(
      api_key    = api_key,
      base_url   = base_url,
      model      = model %||% cfg$llm$default_model,
      messages   = messages,
      out_file   = out_file,
      status_file = stat_file,
      timeout    = cfg$llm$timeout,
      temperature = temperature,
      max_tokens = max_tokens,
      reason_file = rea_file,
      thinking   = thinking,
      reasoning_effort = reasoning_effort,
      # 只接受 temperature = 1 的模型（kimi-k*）：判断在**这里**做，
      # 子进程只负责照办。理由见 .dsapp_llm_worker 里那段 ⚠️。
      # ⚠️ 用**解析后**的模型名（和上面 model = 那一行同一个表达式）。用传进来
      #    的裸 model 的话，NULL 会被判成"不锁"，而真正发出去的可能是另一个名字。
      omit_temperature = dsapp_model_temp_locked(
        model %||% cfg$llm$default_model),
      # ★ V13.14 item 22：max_tokens = DSAPP_MAXTOK_UNLIMITED（滑块拉到最右、
      #    或者用户把输入栏清空）时**不发这个字段**。同一个套路：判据在这边
      #    算，子进程只负责照办（理由见 .dsapp_llm_worker 里那段 ⚠️）。
      omit_max_tokens = dsapp_maxtok_is_unlimited(max_tokens),
      # ★ Test_V16.3 item 2：代理选项也在这里算好再传（同一个理由）。
      #    ⚠️ 传的是 dsapp_proxy_opts() 的**结果**（纯 list），不是代理设置
      #       本身 —— 设置里带着明文密匙，而子进程那边根本用不到它，
      #       少传一份就少一份躺在别人的进程内存里。
      #    没配代理时是 NULL，子进程里 `length(NULL) == 0` → 不贴任何选项。
      #    ★ 代理**只挂在这一次请求上**，不是全局设置：这个应用是一个 R
      #      进程服务所有人，全局代理 = 所有用户的请求都从别人的线路出去。
      #      详见 R/proxy.R 顶部那段铁律。
      proxy_opts = dsapp_proxy_opts(proxy)
    ),
    stdout = file.path(cfg$logs_dir, paste0(token, ".log")),
    stderr = file.path(cfg$logs_dir, paste0(token, ".err")),
    supervise = TRUE   # 父进程退出时子进程一起走，避免留下孤儿
  )

  # list2env 转成 environment —— 原因见上面的 ⚠️
  list2env(list(proc = proc, out_file = out_file, status_file = stat_file,
                reason_file = rea_file, token = token,
                read_pos = 0L, reason_pos = 0L),
           parent = emptyenv())
}

#' 读取增量
#'
#' @return list(text = 新增文本, done = 是否结束, error = 错误信息或 NULL)
dsapp_llm_poll <- function(handle) {
  if (is.null(handle)) {
    return(list(text = "", reasoning = "", done = TRUE, error = "无效的会话句柄"))
  }

  # 从上次读到的位置往后读。两个文件（正文 / 思维链）共用这段逻辑。
  # 返回新位置，由调用方写回 handle —— handle 是 environment，写进去才算数。
  read_delta <- function(path, pos) {
    if (is.null(path) || is.null(pos) || !file.exists(path)) {
      return(list(txt = "", pos = pos %||% 0L))
    }
    size <- file.info(path)$size
    if (is.na(size) || size <= pos) return(list(txt = "", pos = pos))
    con <- file(path, open = "rb")
    on.exit(close(con), add = TRUE)
    seek(con, where = pos, origin = "start")
    raw <- readBin(con, "raw", n = size - pos)
    if (length(raw) == 0) return(list(txt = "", pos = pos))
    # ⚠️ pos 只推进到**最后一个完整字符**的末尾，不是推进到 size。
    #    子进程每写完一个 delta 就 flush，这个位置完全可能落在一个汉字的
    #    三个字节中间；从那儿 rawToChar 出来的是无效编码的字符串（界面上
    #    一个乱码方块），而且下一个 delta 的头几个字节会被并进这个残字里，
    #    后面一串跟着错位。多出来的那几个字节留到下一轮再读，那时它们是
    #    完整的。
    d <- dsapp_raw_to_utf8(raw)
    list(txt = d$txt, pos = pos + d$used)
  }

  a <- read_delta(handle$out_file, handle$read_pos)
  handle$read_pos <- a$pos
  new_text <- a$txt

  b <- read_delta(handle$reason_file, handle$reason_pos)
  handle$reason_pos <- b$pos
  new_reason <- b$txt

  # status 文件是子进程写完 out 文件后才写的，所以它存在 = 内容已完整落盘。
  # 先读它再读 out，不会漏掉最后一段。
  done <- FALSE
  error <- NULL
  usage <- NULL
  finish_reason <- NULL
  # 流是否完整。NULL = 子进程没报（老状态文件、或子进程被 OOM 杀掉），
  # 那时不做判断，交给 error 那条路径处理，避免把"未知"说成"被掐断"。
  complete <- NULL
  if (file.exists(handle$status_file)) {
    st <- tryCatch(
      jsonlite::fromJSON(readLines(handle$status_file, warn = FALSE),
                         simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(st)) {
      done <- TRUE
      if (identical(st$status, "error")) error <- st$error %||% "未知错误"
      usage <- st$usage
      # 只认真字符串。jsonlite 把 `{}` 解析成 list()、把数字解析成 numeric，
      # 下游是拿它跟 "length" 做 identical() 的，放个 list() 过去不会报错、
      # 只会永远不相等 —— 那正好是"截断被静默忽略"，最难查的那种。
      fr <- st$finish_reason
      if (is.character(fr) && length(fr) == 1L && !is.na(fr) && nzchar(fr)) {
        finish_reason <- fr
      }
      # jsonlite 把 JSON 的 true/false 解析成 R 的 logical；null 解析成 NULL。
      # 只认真正的 logical，别的一律留 NULL（"没报"和"报了 false"是两回事）。
      cp <- st$complete
      if (is.logical(cp) && length(cp) == 1L && !is.na(cp)) complete <- cp
    }
  }

  # 子进程崩了（比如被 OOM 杀掉）但没来得及写 status —— 不能一直等下去。
  # proc 为 NULL 的句柄也一样：正常流程里 dsapp_llm_start() 必定带上 proc，
  # 没有就是句柄坏了，早点收尾比让界面永远转圈强。
  if (!done && (is.null(handle$proc) || !handle$proc$is_alive())) {
    done <- TRUE
    if (is.null(error)) {
      error <- if (is.null(handle$proc)) {
        "无效的会话句柄。"
      } else {
        "生成进程意外退出。请检查 API Key、网络，或稍后重试。"
      }
    }
  }

  list(text = new_text, reasoning = new_reason, done = done, error = error,
       usage = usage, finish_reason = finish_reason, complete = complete)
}

#' 把单条消息压到 limit 个字符以内（保留头尾，中间省略）
#'
#' 只对**送去模型的那份**生效。数据库里存的仍是全文，界面要显示全文。
dsapp_ctx_trim <- function(txt, limit) {
  if (is.null(txt) || length(txt) == 0 || is.na(txt)) return("")
  n <- nchar(txt)
  if (n <= limit) return(txt)
  head_n <- max(1L, floor(limit * 0.6))
  tail_n <- max(1L, limit - head_n - 60L)
  paste0(substr(txt, 1L, head_n),
         sprintf("\n\n…（此处省略 %d 个字符）…\n\n", n - head_n - tail_n),
         substr(txt, n - tail_n + 1L, n))
}

#' 按**字符预算**组装对话上下文
#'
#' 以前这里是 `tail(hist, 20)`（取最近 20 条）。在 agent 模式下这是错的：
#' 循环每跑一轮就多两条消息（助手写代码 + 工具回结果），第 4 轮那个「最初
#' 的需求」就被挤出窗口了 —— 模型开始忘记用户到底要什么，而它自己不会说
#' 「我忘了」，它会接着编。而且 20 条这个数字和长度没关系：20 条 50 字的
#' 聊天不到 1K 字符，20 条带报错日志的能到 200K 字符，后者直接把上下文顶爆。
#'
#' 所以改成按字符数取，并且**第一条用户消息永远保留** —— 那是原始需求，
#' 丢了整个循环就失去目标。
#'
#' ---- ⚠️ 2026-09-14：逐条裁剪把消息的**配对**拆散了，这是真出过事的 --------
#'
#' 上面那版是「从最新往回，一条一条往预算里塞」。它有两个洞，都在线上咬过人
#' （会话 s-20260912215607-5136「帮我制作一份16s扩增子的分析流程」）：
#'
#'   (a) **拆散 assistant / tool 的配对。** agent 模式下，一条「【执行结果 ·
#'       任务 #7】」是**某条助手消息里那段代码**跑出来的。逐条裁剪会留下结果、
#'       丢掉那段代码，模型拿到一张**没有前因的执行结果**。那个会话最后几轮
#'       模型看到的就是这个：任务 #3、#6、#7 的结果都在，提交它们的消息全不
#'       在 —— 于是它的思维链第一句是「我需要回顾对话历史」，然后只能从
#'       stderr 反推手册是哪个脚本生成的，推不出来，就反复对用户说「上一步
#'       没跑完」「手册还没生成」。用户看到的是：**光烧 token，不解决问题。**
#'
#'   (b) **裁掉了却不告诉模型。** 被省略的那些消息没有任何痕迹，模型默认
#'       自己看到的就是全部历史，于是拿残缺的上下文当完整上下文推理。它不会
#'       说「我看不到那一步」，它会自信地猜。
#'
#' 修法：**按不可拆的单元整块收**（单元 = 一条 user 消息，或一段「assistant
#' 及其后紧跟的 tool」），要么整块要、要么整块不要，配对不会被拆开；真裁掉了
#' 就在缺口处插一条说明，把「这里省略了什么」明确写进上下文。
#'
#' ---- ⚠️ 2026-09-14 二次修正：单元粒度从"轮"细到"一对" ----------------------
#'
#' 第一版修法是按**轮**收的（一轮 = 一条用户消息 + 它后面直到下一条用户消息
#' 之前的全部内容），最后一段无条件保留。配对是保住了，但引入了另一个洞：
#' agent 循环里**最后一段就是最长的那一段** —— 用户只问了一次，后面六轮全是
#' assistant/tool 来回。于是"整段保留"等于"预算完全不生效"，一条几万字的
#' 执行结果照样整个发出去。预算唯一的用处就是不让请求超限，不生效等于没有。
#'
#' 单元细到"一对"之后，规则统一成一句：**从最后往前整单元地收，塞不下就停**。
#' 唯一无条件保留的是最后那**一个**单元（用户这次的提问），这样也不会再出现
#' "一条超长消息把问题本身挤掉"的老毛病。
#'
#' @param hist  db_messages_get() 的结果（列 role / content）
#' @param budget 总字符预算。**默认 NULL = 由单次使用上限推出来**（V15.5 item 6）。
#'   ⚠️ 这里原来写死 48000 字符。那时是对的，因为"能带多少历史进去"在当时
#'   根本没有被建模 —— 48000 是个对**所有**厂商都安全的数。用户第 6 条问的
#'   就是这件事：「需要按照模型的能力自适应更改上下文长度的读条」。
#'   现在预算由 dsapp_ctx_limit()（模型窗口，或用户填的单次使用上限）减去
#'   给回复留的余量算出来，deepseek 的 1M 就真的能带 1M 的历史进去。
#'   显式传一个数仍然有效 —— 自检和测试靠它构造确定性的场景。
#' @param per_msg 单条上限。防止一条超长报错把整个预算吃光。
#'   ⚠️ 会被 budget 压低（小窗口的模型上 12000 字符一条都可能超预算）。
#' @param vendor,model 用来查上下文窗口。不给就退回保守默认（见 models.R）
#' @param limit 用户在「模型服务」页填的单次使用上限；NULL/0 = 跟随模型
#' @return list of list(role =, content =)，可直接接在 system 消息后面
dsapp_build_context <- function(hist, budget = NULL, per_msg = 12000L,
                                vendor = NULL, model = NULL, limit = NULL) {
  if (is.null(hist) || nrow(hist) == 0) return(list())

  # ★ V15.5 item 6：预算不再是一个写死的字符数。
  #
  # ⚠️ 「回复的余量」和「历史的预算」是**同一个数**的两半：单次使用上限减去
  #    留给回复的，才是历史能占的。分成两个各自独立的数就一定会对不上 ——
  #    两边单看都没超，加起来超了，而厂商拒的是整个请求。
  if (is.null(budget)) {
    lim <- dsapp_ctx_limit(vendor, model, limit)
    budget <- dsapp_ctx_char_budget(lim, dsapp_ctx_out_reserve(lim))
  }
  budget <- max(1024L, as.integer(budget[1]))
  # 单条上限不能大过总预算：小窗口的模型上，一条 12000 字符的消息本身就
  # 已经超了，而 dsapp_ctx_trim() 是按 per_msg 截的 —— 不压的话，"总预算"
  # 这一层对小窗口形同虚设。
  per_msg <- max(512L, min(as.integer(per_msg[1]), budget))

  roles <- as.character(hist$role)
  texts <- vapply(as.character(hist$content), dsapp_ctx_trim,
                  character(1), limit = per_msg, USE.NAMES = FALSE)
  n <- length(texts)

  # ---- 切成**不可拆的单元** -------------------------------------------------
  # 边界只取在"配对不可能被拆开"的地方，单元有两类：
  #
  #   1) 一段「assistant 及其后紧跟的 tool」。一条【执行结果 · 任务 #N】是
  #      **某条助手消息里那段代码**跑出来的，拆开就得到一张没有前因的结果。
  #   2) 一条 user 消息，自己一条。库里的角色只有四种：user / assistant /
  #      tool / system；执行结果存的是 "tool" 而不是 "user"，所以这里认出来
  #      的都是真人发的。
  #
  # ⚠️ 粒度为什么必须细到"一对"。上一版是按**轮**（一条用户消息 + 它后面直
  #    到下一次提问之前的全部内容）整段收的，配对确实拆不开了，但它另有一个
  #    更硬的洞：**最后一段是无条件保留的**，而 agent 循环里最后一段恰恰是最
  #    长的那一段 —— 一轮加两条，六轮下来光执行结果就几十万字符，预算被整个
  #    撑爆。而"预算"唯一的用处就是不让请求超限，撑爆了它就是个摆设。
  #    粒度细到对之后，"从后往前能塞多少塞多少"既保得住配对，又真的受约束。
  unit_of <- integer(n)
  u <- 0L
  i <- 1L
  while (i <= n) {
    u <- u + 1L
    if (identical(roles[[i]], "assistant")) {
      j <- i + 1L
      while (j <= n && identical(roles[[j]], "tool")) j <- j + 1L
      unit_of[i:(j - 1L)] <- u
      i <- j
    } else {
      # user 自己一条；开头的孤儿 tool / system（理论上不会有）也自己一条
      unit_of[i] <- u
      i <- i + 1L
    }
  }

  # ---- 从后往前整单元地收 ---------------------------------------------------
  keep <- logical(n)
  used <- 0L
  for (k in rev(seq_len(u))) {
    idx <- which(unit_of == k)
    len <- sum(nchar(texts[idx]))
    # `used > 0L` 这半句是给**最后一条消息**开的特例：不管它多长都要发出去。
    # 它是用户这一次的提问本身（或提问之后最新的一条结果），丢了这轮请求就
    # 没有意义 —— 老代码"一条超长消息把预算吃光"就翻在这里：进了循环它会被
    # break 掉，结果连问题本身都没发出去。
    if (used > 0L && used + len > budget) break
    keep[idx] <- TRUE
    used <- used + len
  }

  # ---- 第一条用户需求：原始目标，任何情况下都要在 ----------------------------
  # 会话短的时候上面已经把它收进来了，没有就单独补上。补的只有它**这一条**，
  # 不带它后面那些内容 —— 第一轮里可能跟着一个两万字的助手长回答，为了它把
  # 预算撑爆不值当。留一条孤零零的需求，也比让模型忘记用户到底要做什么强。
  first_user <- which(roles == "user")[1]
  if (length(first_user) == 1L && !keep[[first_user]]) {
    keep[[first_user]] <- TRUE
    used <- used + nchar(texts[[first_user]])
  }

  # ---- 组装，缺口处插说明 ----------------------------------------------------
  idx <- which(keep)
  out <- vector("list", 0L)
  prev <- 0L
  for (i in idx) {
    if (i > prev + 1L) {
      gap <- setdiff(seq.int(prev + 1L, i - 1L), idx)
      if (length(gap) > 0L) {
        # 说清楚「省略了什么」，模型才知道自己手里这份历史是残缺的。
        # 最后那句是重点：不写的话它会拿残缺的上下文硬推，而它不会说自己
        # 在猜 —— 表现就是反复对用户讲「上一步没跑完」这类无法证实的话。
        tab <- table(roles[gap])
        what <- paste(sprintf("%d 条%s", as.integer(tab),
                              c(user = "用户提问", assistant = "助手回复",
                                tool = "执行结果", system = "系统消息")[names(tab)]),
                      collapse = "、")
        out[[length(out) + 1L]] <- list(
          role = "user",
          content = paste0(
            sprintf("【历史省略】这里原本有 %d 条消息（%s），因为超出上下文预算，",
                    length(gap), what),
            "**没有随本次请求发出**，你现在看不到它们的内容。\n",
            "如果需要其中的信息，请让用户把要求重说一遍、或重新执行一次；",
            "**不要凭猜测回答**，更不要断言某一步「没跑完」「没有生成」——",
            "你看不到不等于它没发生。"))
      }
    }
    # "tool" 是本地角色，不是所有厂商都认。不带 tool_call_id 的
    # role:"tool" 会被好几家直接 400 掉，所以往外发的时候一律降级成
    # user —— 内容里本来就带着「【执行结果 · 任务 #N】」的头，
    # 模型分得清这是执行结果而不是人在说话。
    out[[length(out) + 1L]] <- list(
      role = if (identical(roles[[i]], "tool")) "user" else roles[[i]],
      content = texts[[i]])
    prev <- i
  }
  out
}

#' 拼一次请求要发出去的完整 messages（系统提示 + 对话历史）
#'
#' ★ V13.7 item 5 抽出来的。原来这段长在 mod_chat.R 的 dsapp_llm_begin()
#'   里，和界面状态（rv$ / st$ / input$）混在一处。抽出来是因为**脱离会话的
#'   后台续跑**也要拼同一份上下文（R/detach.R），而两份拼法一定会分叉 ——
#'   分叉的表现是"挂机跑出来的结果和盯着跑出来的不一样"，且没人会去逐字比对
#'   两处拼出来的提示词。
#'
#' ⚠️ 这里**不许碰 shiny**：后台那条路跑在 callr::r_bg 的子进程里，没有会话、
#'    没有 reactive 上下文。所以所有原来从 input$ 读的东西都必须**由调用方
#'    传进来**（vendor / model / target / max_iter）。
#'
#' ⚠️ 参数里**没有** temperature / max_tokens / thinking 这些采样参数。它们
#'    属于"这一次请求怎么发"，不属于"发什么内容"，拼 messages 这个动作不该
#'    知道它们。会话那条路从 state$ 读，后台那条路从库里读，各读各的。
#'
#' @param sid     对话 id。系统提示里的工作区文件清单、挂载的技能都按它查。
#' @param scene   "chat" / "agent"（决定注入哪一套执行模型说明，见 prompts.R）
#' @param target  本次执行的目标，见 utils.R 的 dsapp_target_label()
#' @param user_id 技能是按账号挂的，查它要用
#' @param max_iter 提示词里说的轮数必须和**此刻**的额度一致，否则用户把额度
#'                调高了、模型自己还以为只有 6 轮，会提前收尾
#' @param wall_limit ★ V13.17 item 31：同上的另一半 —— 自动结束时间（秒）。
#'                界面上的滑块和提示词里那句「最多 N 小时」必须同源，
#'                否则模型会按一个不存在的时长安排节奏（拆步骤的粗细、
#'                哪里该省、哪里该等），而两边单看都没错。
#' @return list of list(role =, content =)，可直接交给 dsapp_llm_start()
dsapp_scene_messages <- function(sid, scene = "chat", cfg = dsapp_config(),
                                 target = NULL, user_id = NULL,
                                 max_iter = DSAPP_AGENT_MAX_ITER,
                                 wall_limit = DSAPP_AGENT_WALL_DEF,
                                 vendor = NULL, model = NULL,
                                 ctx_limit = NULL) {
  if (is.null(target)) target <- list(kind = "server", env = "system")
  con <- dsapp_db(cfg)

  # 组装上下文：系统提示 + 取最近若干条。
  # ⚠️ 不要退回 `tail(hist, 20)`。agent 循环每一轮要加两条消息
  # （助手写代码 + 工具回结果），按条数截的话第二轮就把用户最初那句
  # 需求挤出去了，而模型不会说「我忘了」，它会接着编。
  # 见下面的 dsapp_build_context()。
  #
  # ★ V15.5 item 6：预算不再是写死的 48000 字符，而是由「单次使用上限」
  #   （用户填的，或者跟随模型窗口）减去留给回复的余量推出来的。
  #   ⚠️ vendor / model / ctx_limit **必须传下去**：不传的话
  #      dsapp_build_context() 只能退回保守默认，deepseek 的 1M 窗口就白有了
  #      —— 而"读条上说还有 98% 空间"和"只带进去 48000 字符"会同时成立。
  hist <- tryCatch(db_messages_get(sid, con = con), error = function(e) NULL)
  convo <- dsapp_build_context(hist, vendor = vendor, model = model,
                               limit = ctx_limit)

  c(list(list(role = "system",
              content = build_system_prompt(
                scene, cfg,
                target = target,
                # 让提示词里能列出这个对话工作区已有的文件 —— 不然模型看不见
                # 自己上一步的产出，"接着上一步继续"就无从谈起
                # （见 prompts.R 的 build_file_section）
                session_id = sid,
                # 本对话挂载的技能（V8 item 1）。
                # ⚠️ 每一轮都**重新查库**，不在会话里缓存：用户在另一个标签页
                #    里改了挂载、或者刚改完技能正文，回到这里发的下一条消息就
                #    该用新的。缓存的话要维护失效逻辑，而这个查询是一条走主键
                #    的本地 sqlite，便宜到不值得省。
                skills = tryCatch(
                  dsapp_skills_prompt(sid, user_id = user_id, con = con),
                  error = function(e) NULL),
                max_iter = max_iter,
                # ★ V13.17 item 31：自动结束时间，和 max_iter 是同一件事的
                #   两个维度（跑几步 / 跑多久）。同一个理由：不同源的话，
                #   模型按错的时长安排节奏，而且两边单看都对。
                wall_limit = wall_limit,
                # 告诉模型**它自己是谁**（V13.1 item 6）。不给事实的话，中文
                # 语料里"你是什么模型"后面接的大多是 Claude/GPT 的自述。
                vendor = vendor, model = model,
                # ★ V13.12 item 2：把发起人传下去，提示词里的「资源限额」
                #   才会是他的**实际**上限（管理员单独设过的按他的算），
                #   而不是平台默认那一组数 —— 见 prompts.R 里那段说明。
                user_id = user_id))),
    convo)
}

#' 从 usage 对象里取出三个数字
#'
#' 各家的字段名不统一：OpenAI 系（含 DeepSeek）是 prompt_tokens /
#' completion_tokens / total_tokens；有的厂商只给总数，有的给
#' input_tokens / output_tokens。
#'
#' 取不到的字段留 NULL 而不是补 0 —— "这家不报这个数"和"真的是 0"
#' 是两回事，补 0 会让界面显示一个理直气壮的假数字。
#' 三个都取不到就返回 NULL，调用方据此决定"不显示"，而不是显示 0 tokens。
dsapp_usage_numbers <- function(usage) {
  if (is.null(usage) || !is.list(usage)) return(NULL)
  pick <- function(...) {
    for (k in c(...)) {
      v <- usage[[k]]
      if (!is.null(v) && is.numeric(v)) return(as.numeric(v))
    }
    NULL
  }
  pin  <- pick("prompt_tokens", "input_tokens")
  pout <- pick("completion_tokens", "output_tokens")
  tot  <- pick("total_tokens")
  if (is.null(tot)) {
    if (is.null(pin) && is.null(pout)) return(NULL)
    tot <- sum(pin %||% 0, pout %||% 0)
  }
  list(total = tot, prompt = pin, completion = pout)
}

#' 把 usage 对象转成一行给人看的文字
#'
#' 厂商不给用量就返回空串 —— 宁可不显示，也不要显示一个"0 tokens"
#' 让人以为真的没花钱。
dsapp_usage_text <- function(usage) {
  u <- dsapp_usage_numbers(usage)
  if (is.null(u)) return("")
  if (is.null(u$prompt) && is.null(u$completion)) {
    return(sprintf("本次消耗 %s tokens", format(u$total, big.mark = ",")))
  }
  sprintf("本次消耗 %s tokens（输入 %s + 输出 %s）",
          format(u$total, big.mark = ","),
          format(u$prompt %||% 0, big.mark = ","),
          format(u$completion %||% 0, big.mark = ","))
}

#' 中止流式生成
dsapp_llm_abort <- function(handle) {
  if (is.null(handle)) return(invisible(FALSE))
  if (!is.null(handle$proc) && handle$proc$is_alive()) {
    try(handle$proc$kill(), silent = TRUE)
  }
  unlink(c(handle$out_file, handle$status_file, handle$reason_file))
  invisible(TRUE)
}

#' 一次性（非流式）调用
#'
#' 用于短任务：自动生成会话标题、给代码起个名字等。这些场景不需要流式，
#' 走同步请求代码简单得多。
#' ⚠️ `thinking` 的默认值是 NULL（= **不发这个字段**），不是 FALSE。
#'    写 FALSE 的话下面会发出 `"thinking": {"type": "disabled"}` —— 那是
#'    DeepSeek 的私有字段，别的厂商收到未知字段**有的直接 400**。
#'    主对话那条路（dsapp_llm_start）用的就是 NULL 这个约定，这里对齐它。
#'    传 FALSE 是"明确要求关掉"，传 NULL 是"别提这回事"，两者不一样。
dsapp_llm_simple <- function(api_key, messages, model = NULL,
                             cfg = dsapp_config(), max_tokens = 512,
                             temperature = 0.3, base_url = NULL,
                             thinking = NULL, proxy = NULL) {
  .dsapp_llm_once(api_key, messages, model = model, cfg = cfg,
                  max_tokens = max_tokens, temperature = temperature,
                  base_url = base_url, thinking = thinking,
                  proxy = proxy)$text
}

#' 一次性调用，但把整份回应带回来（正文 / 结束原因 / 用量）
#'
#' ★ V13.7 item 5：脱离会话的后台续跑要的就是这一份。它和上面那个
#'   dsapp_llm_simple() 是**同一次请求、同一套拼包逻辑**，区别只在返回值 ——
#'   循环需要 `finish_reason` 才能判断"这一轮是不是被长度截断了"
#'   （dsapp_agent_pick_block 拿它决定回喂的措辞，见 agent.R）。
#'   单独抄一份 HTTP 拼包的话，两条路的请求迟早会不一样（先漏掉的多半是
#'   `reasoning_effort` 这类厂商私有字段），而症状是"挂机跑出来的结果比盯着
#'   跑出来差一截"，根本不会有人往"请求发得不一样"上想。
#'
#' ⚠️ **不要**把这个函数的返回值改回字符串再去改 dsapp_llm_simple 的调用方：
#'    skills.R 那边（给技能起名）只想要正文，多一个 list 只会让它多一层解包。
#'
#' @return list(text, finish_reason, usage)
.dsapp_llm_once <- function(api_key, messages, model = NULL,
                            cfg = dsapp_config(), max_tokens = 512,
                            temperature = 0.3, base_url = NULL,
                            thinking = NULL, reasoning_effort = NULL,
                            proxy = NULL) {
  if (is.null(api_key) || !nzchar(api_key)) stop("尚未填写 API Key")
  if (is.null(base_url) || !nzchar(base_url)) base_url <- cfg$llm$base_url

  url <- paste0(sub("/+$", "", base_url), "/chat/completions")
  req <- httr2::request(url)
  req <- httr2::req_headers(req,
    Authorization = paste("Bearer", api_key),
    `Content-Type` = "application/json"
  )
  body <- list(
    model = model %||% cfg$llm$default_model,
    messages = messages,
    stream = FALSE
  )
  # ★ V13.14 item 22：「不设上限」= 不发这个字段。这里能直接调
  #   dsapp_maxtok_is_unlimited()（**本函数跑在父进程里**，不是 callr 那个
  #   子进程函数，见 llm.R 顶部）。后台续跑那条路（R/detach.R）走的就是这里，
  #   而它读的快照里可能正是一次"不设上限"的会话。
  if (!dsapp_maxtok_is_unlimited(max_tokens)) body$max_tokens <- max_tokens
  # 短任务（起标题之类）默认**关掉思考模式**。开着的话模型会先写一大段
  # 思维链，而 max_tokens 一到就截断，最后可能一个字正文都没返回 ——
  # 花了几十倍的钱和时间，换来一个空字符串。
  if (!is.null(thinking)) {
    body$thinking <- list(type = if (isTRUE(thinking)) "enabled" else "disabled")
  }
  # 思考强度（reasoning_effort）：和流式那条路一个约定 —— 只有真的开了
  # 思考模式才发，而且只在厂商认这个字段时才发（DeepSeek 私有）。
  # 见 llm.R 顶部 .dsapp_llm_worker 里那段说明。
  if (isTRUE(thinking) && !is.null(reasoning_effort)) {
    body$reasoning_effort <- reasoning_effort
  }
  # 短任务这条路也要判（见上面主对话那条的说明）：起标题之类的调用一旦
  # 撞上"只接受 1"的模型，报的错一模一样，而它发生在**用户刚发完消息**
  # 的那一刻，看起来像是消息本身发失败了。
  if (!isTRUE(thinking) &&
      !dsapp_model_temp_locked(body$model)) {
    body$temperature <- temperature
  }

  req <- httr2::req_body_json(req, body)
  # ★ Test_V16.3 item 2：代理。本函数跑在**父进程**里（不是 callr 那个子进程
  #   函数，见 llm.R 顶部），所以可以直接调 dsapp_proxy_apply()。
  #   ⚠️ 只挂在这一个 request 对象上，不是全局 —— 理由见 R/proxy.R 顶部。
  req <- dsapp_proxy_apply(req, proxy)
  # ⚠️ 超时按**这次请求要多少 token** 给。原来是写死的 60 秒 —— 那是按
  #    "起个标题"（max_tokens = 512）定的。后台续跑那条路一次要生成几千
  #    token 的正文加代码，60 秒根本不够，而超时的报错长得和"网络不通"
  #    一模一样，排查时会往错的方向找。512 token 那条路仍然按 60 秒起算。
  # ★ V13.14 item 22：不设上限时 max_tokens 是 0，`ceiling(0 / 20)` 会算出
  #   0 —— 直接 max(60, 0) 虽然也不会崩，但那个 60 秒是按"起个标题"
  #   （max_tokens = 512）定的，用在一次**没有长度上限**的请求上会把正常的
  #   长回答拦腰掐断，而超时的报错长得和"网络不通"一模一样。给一个明确的
  #   兜底档：按 65536 算（≈55 分钟），这条路现在没有调用方传不设上限，
  #   留着是为了将来真有人传的时候不至于撞上一个说不清的超时。
  mt_timeout <- if (dsapp_maxtok_is_unlimited(max_tokens)) 65536 else max_tokens
  req <- httr2::req_timeout(req, max(60, ceiling(mt_timeout / 20)))
  req <- httr2::req_error(req, is_error = function(resp) FALSE)

  resp <- httr2::req_perform(req)
  if (httr2::resp_status(resp) >= 400) {
    body <- httr2::resp_body_string(resp)
    msg <- tryCatch(
      jsonlite::fromJSON(body, simplifyVector = FALSE)$error$message,
      error = function(e) body
    )
    stop(sprintf("HTTP %d：%s", httr2::resp_status(resp), msg))
  }

  out <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  ch <- out$choices[[1]] %||% list()
  list(text = ch$message$content %||% "",
       finish_reason = ch$finish_reason %||% NULL,
       usage = out$usage %||% NULL)
}

#' 列出可用模型
#'
#' 设置页用来验证 Key 是否有效 —— 这比发一条真消息便宜，而且能明确区分
#' "Key 错了"和"模型名写错了"。
#'
#' ★ V13.12 item 1：**这个请求是按接口地址发的，不是按 Key 发的。**
#'   拼出来的永远是 `<base_url>/models`，Key 只进 Authorization 头。
#'   中转站（聚合平台）只要把 base_url 指过去，用的是同一段代码 ——
#'   这也是"应该通过 URL 获取模型"这句话的字面实现。
#'
#'   ⚠️ `api_key` 允许为空。有的中转站 `/models` 是公开的，空 Key 时**不发**
#'      Authorization 头（而不是发一个 `Bearer ` 空串 —— 那有的网关会当成
#'      格式错误直接 400，把"这个接口本来不需要鉴权"误导成"我的 Key 有问题"）。
#'
#'   ⚠️ `base_url` 为空时的兜底（`cfg$llm$base_url`）保留着，但**调用方不该
#'      依赖它**：那是 DeepSeek 的地址，让一个"用户还没填地址"的请求悄悄打到
#'      DeepSeek 上，会拿回一份看起来成功、实际答非所问的清单。
#'      界面那条路（mod_model.R 的 start_verify）现在会先拦住空地址。
dsapp_llm_models <- function(api_key, cfg = dsapp_config(), base_url = NULL,
                             proxy = NULL) {
  if (is.null(base_url) || !nzchar(trimws(base_url))) base_url <- cfg$llm$base_url

  url <- paste0(sub("/+$", "", base_url), "/models")
  req <- httr2::request(url)
  if (!is.null(api_key) && nzchar(trimws(api_key))) {
    req <- httr2::req_headers(req, Authorization = paste("Bearer", trimws(api_key)))
  }
  # ★ Test_V16.3 item 2：拉清单也要走代理 —— 这一条**最容易漏**：模型清单
  #   正是"填代理之前最想拿到的东西"（境外厂商的清单），少了它用户会觉得
  #   "代理只对发消息生效"。
  #   ⚠️ 本函数虽然跑在后台子进程里（那边把 R/*.R 都 source 过，能调
  #      dsapp_* ），代理设置仍然是**父进程**读好传进来的：子进程少读一次
  #      库，就少一条"子进程连到了另一个 data_root"的暗路。
  req <- dsapp_proxy_apply(req, proxy)
  req <- httr2::req_timeout(req, 20)
  req <- httr2::req_error(req, is_error = function(resp) FALSE)

  resp <- httr2::req_perform(req)
  status <- httr2::resp_status(resp)

  # 报错里带上地址：配中转站时最常见的两种失败（打错域名、漏了 /v1）跟
  # "Key 不对"长得一模一样，不给地址的话用户只能反复重填 Key。
  if (status == 401 || status == 403) {
    stop(sprintf("鉴权失败（HTTP %d）：%s。请确认这个地址的 Key 是对的。",
                 status, url))
  }
  if (status == 404) {
    stop(sprintf(paste0("这个地址上没有 /models 接口（HTTP 404）：%s。",
                        "中转站的兼容前缀通常在 /v1，把接口地址改成 ",
                        "%s/v1 再试。"), url, sub("/+$", "", base_url)))
  }
  if (status >= 400) stop(sprintf("请求失败：HTTP %d（%s）", status, url))

  out <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  vapply(out$data, function(m) m$id %||% "", character(1))
}

#' 拉取厂商的模型列表（非阻塞）
#'
#' ⚠️ 为什么要多这一层：dsapp_llm_models() 是一次同步 HTTP 请求，超时 20 秒。
#' 在 Shiny 进程里直接调用它，就等于让**所有用户**陪着一起等 ——
#' Shiny Server 开源版一个应用只有一个 R 进程。厂商接口偶尔要好几秒才回，
#' 网络不通时会耗满整个超时。和代码执行、LLM 对话一样，必须丢到子进程。
#'
#' @return 句柄，交给 dsapp_llm_models_poll()
dsapp_llm_models_async <- function(api_key, base_url, cfg = dsapp_config(),
                                   proxy = NULL) {
  dsapp_bg_start("dsapp_llm_models",
                 list(api_key = api_key, base_url = base_url, proxy = proxy),
                 cfg = cfg, tag = "models")
}

#' 查模型列表拉取结果
#'
#' @return list(done, ok, models, msg)
dsapp_llm_models_poll <- function(handle) {
  r <- dsapp_bg_poll(handle)
  list(done = r$done, ok = r$ok,
       models = as.character(unlist(r$value %||% list())),
       msg = r$msg)
}
