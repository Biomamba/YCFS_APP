#!/usr/bin/env Rscript
# =============================================================================
# Test_V15.10：三处性能改动的**语义**验证（缓存可以快，但不许改变结果）
# =============================================================================
#     Rscript tests/v1510_perf.R            # 在应用目录下跑
#
# ── 这一版改了什么 ──────────────────────────────────────────────────────────
#
# 起因是用户那句话：「我看到你更新到15.9了，但是还是会出现页面未响应的状态」。
# 2026-10-02 在本地实例上量出来（复刻线上那个 43 条 / 203 KB 的会话）：
#
#   · 每重画一次历史，R worker 被**独占 1.0–1.5 秒**（服务端埋点实测
#     1.096 / 0.985 / 1.474 s），而浏览器那边的 fetch 就真的等了 4488 ms；
#   · 流式输出时每 200ms 重画一次正文，其中 7.6 ms 是 `dsapp_config()`
#     （它里面藏了一次 `parallel::detectCores()` —— 那是 fork 一个 shell）；
#   · 历史重画里 71% 的时间花在**用户消息**上（15 条 0.329 s），一条缓存都没有。
#
# 四处改动：
#   1. dsapp_config() 按**环境变量全量指纹**缓存；核数另按"进程内只问一次"缓存
#      （R/config.R；R/platform.R 的 dsapp_host_identity 跟着改）
#   2. 用户气泡整条缓存（dsapp_render_user_message，R/render.R）
#   3. 代码卡片整张缓存（dsapp_code_card，R/render.R）
#   4. **关掉 JIT**（app.R）—— 这一条才是「页面未响应」的主因：
#      R 默认 enableJIT(3) 会在一个闭包**第二次被调用之前**给它做字节编译，
#      而 R 的编译器在大函数体上极慢（2000 条语句编一次 1.28 秒，执行只要
#      0.04 秒）。本地实例实测「session 建立 → 第一次 flush 结束」：
#      JIT 3 = 9.11 秒，JIT 0 = 1.50 秒。
#
# ── 为什么这份测试是必要的 ──────────────────────────────────────────────────
#
# 缓存最容易出的错不是"没生效"，而是**冻结**：界面停在一个旧值上，不报错、
# 自检也全绿（本仓栽过：V13.17 的 wall_limit、session-proxy 那两次）。
# 所以这份测试专门盯**失效**：
#   A 组 —— 运行期改了环境变量，配置必须当场跟着变（这条要是坏了，
#           症状是"切了数据根还在往老库里写"，是这一版最危险的错法）
#   B 组 —— 用户气泡：正文变了 key 必须变；换了会话 sid key 必须变
#   C 组 —— 代码卡片：执行状态（待执行/执行中/已执行/黄条）变了 key 必须变
#   D 组 —— 该快的真的快了（否则这场改动白做）
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source：仓库根的 .Renviron 把
#     DSAPP_DATA_ROOT 指着**生产库**。不指开的话，这份测试会往生产库建表。
#     （本仓为此栽过：自检泄漏 DSAPP_DATA_ROOT，写进了生产库。）
#
# ⚠️ 一条出网请求都不会有：全程只在本机算字符串。
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "."

# ⚠️ 必须**先**设，再 source —— 顺序反了就等于拿生产库跑测试
tmp <- file.path(tempdir(), sprintf("v1510_%d", as.integer(Sys.time())))
dir.create(tmp, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)
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

suppressMessages(library(shiny))
al <- readLines("app.R", warn = FALSE)
i <- grep("^[[:space:]]*files <- c\\(", al)[1]
buf <- character(0); depth <- 0L
for (li in i:length(al)) {
  ln <- al[[li]]; buf <- c(buf, ln)
  ch <- strsplit(gsub('"[^"]*"', '""', ln), "")[[1]]
  depth <- depth + sum(ch == "(") - sum(ch == ")")
  if (depth <= 0L) break
}
eval(parse(text = paste(buf, collapse = "\n")))
for (f in files) { p <- file.path("R", f); if (file.exists(p)) source(p, local = globalenv()) }

ms <- function(expr, n = 1L) {
  f <- substitute(expr)
  invisible(eval(f))                       # 预热（含各处的惰性加载）
  t0 <- Sys.time()
  for (k in seq_len(n)) invisible(eval(f))
  as.numeric(difftime(Sys.time(), t0, units = "secs")) / n * 1000
}
bucket_n <- function(b) {
  st <- dsapp_state()
  if (is.null(st$memo) || is.null(st$memo[[b]])) return(0L)
  length(ls(st$memo[[b]]))
}
html <- function(x) paste(as.character(x), collapse = "")

# ---------------------------------------------------------------------------
say("\n== A 组：配置缓存（含运行期改环境变量）==")
# ---------------------------------------------------------------------------
t_cfg <- ms(dsapp_config(), n = 50L)
say("  dsapp_config() = %.3f ms/次（改前实测 7.6 ms）", t_cfg)
chk("★ 配置读完一次之后不再是毫秒级", t_cfg < 2, sprintf("%.3f ms", t_cfg))

cfg <- dsapp_config()
chk("缓存值与现算值一字不差", identical(cfg, .dsapp_config_build()))

A <- file.path(tmp, "rootA"); B <- file.path(tmp, "rootB")
dir.create(A, recursive = TRUE, showWarnings = FALSE)
dir.create(B, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(DSAPP_DATA_ROOT = A); cA <- dsapp_config()
Sys.setenv(DSAPP_DATA_ROOT = B); cB <- dsapp_config()
Sys.setenv(DSAPP_DATA_ROOT = A); cA2 <- dsapp_config()
chk("★★ 设 A 拿到 A", identical(cA$data_root, A), cA$data_root)
chk("★★ 设 B 拿到 B（不是缓存里那个 A）", identical(cB$data_root, B), cB$data_root)
chk("★★ 切回 A 又拿到 A", identical(cA2$data_root, A), cA2$data_root)
chk("★ 两把根的库路径不同", !identical(cA$db_path, cB$db_path))

Sys.setenv(DSAPP_EXEC_THREADS = "3"); t3 <- dsapp_config()$exec$threads
Sys.setenv(DSAPP_EXEC_THREADS = "5"); t5 <- dsapp_config()$exec$threads
chk("★ 藏在默认值里的环境变量也当场生效（DSAPP_EXEC_THREADS）",
    identical(t3, 3) && identical(t5, 5), sprintf("%s → %s", t3, t5))
Sys.unsetenv("DSAPP_EXEC_THREADS")

# 核数：进程内只问一次
t_cores1 <- ms(dsapp_cores(), n = 200L)
chk("★ 核数缓存后是微秒级（detectCores 每次都 fork 一个 shell，6.9 ms）",
    t_cores1 < 0.05, sprintf("%.4f ms", t_cores1))
chk("核数与 detectCores 一致（拿不到就是 NA）", {
  a <- dsapp_cores()
  b <- suppressWarnings(as.integer(parallel::detectCores(logical = TRUE)))
  if (is.na(b) || b < 1L) is.na(a) else identical(a, b)
}, sprintf("cores=%s", dsapp_cores()))
chk("dsapp_default_threads() 仍是 min(8, 核数)",
    identical(dsapp_default_threads(), min(8L, max(1L, dsapp_cores()))))

u <- dsapp_config_user(7L, dsapp_config())
chk("★★ 调用方改自己那份不会污染缓存（files_dir 还是 _anon）",
    identical(basename(dsapp_config()$files_dir), "_anon") &&
      identical(basename(u$files_dir), "u7"),
    sprintf("user=%s base=%s", basename(u$files_dir), basename(dsapp_config()$files_dir)))

# ---------------------------------------------------------------------------
say("\n== B 组：用户气泡缓存 ==")
# ---------------------------------------------------------------------------
t1 <- "请问这个 `expr.csv` 怎么读？"
t2 <- "换一个问题，`meta.csv` 呢？"
h1a <- html(dsapp_render_user_message(t1))
h1b <- html(dsapp_render_user_message(t1))
h2  <- html(dsapp_render_user_message(t2))
chk("★ 同样内容两次，结果一字不差", identical(h1a, h1b))
chk("★★ 正文不同 → 结果不同（key 里有正文）",
    !identical(h1a, h2) && grepl("expr.csv", h1a) && grepl("meta.csv", h2))

# sid 必须进 key：换一个会话就该重算（图地址是**会话私有**的，
# 复用等于把 A 会话的地址发给 B 会话 —— 症状是那个对话里图全裂）
fake_sess <- list(token = "tok-x")
n0 <- bucket_n("userbubble")
invisible(dsapp_render_user_message(t1, fake_sess, "sid-one"))
n1 <- bucket_n("userbubble")
invisible(dsapp_render_user_message(t1, fake_sess, "sid-two"))
n2 <- bucket_n("userbubble")
invisible(dsapp_render_user_message(t1, fake_sess, "sid-two"))
n3 <- bucket_n("userbubble")
chk("★★ 换 sid 会另存一条", n1 == n0 + 1L && n2 == n0 + 2L,
    sprintf("%d → %d → %d", n0, n1, n2))
chk("★ 同一 sid 再来一次不再新增（真的命中了）", n3 == n2, sprintf("%d → %d", n2, n3))

# ---------------------------------------------------------------------------
say("\n== C 组：代码卡片缓存 ==")
# ---------------------------------------------------------------------------
segs <- dsapp_split_segments(paste0("看这段：\n\n```r\nx <- 1\nprint(x)\n```\n\n就这样。"))
cseg <- Filter(function(s) identical(s$type, "code"), segs)[[1]]
card <- function(...) html(dsapp_code_card(cseg, "m1", ...))

idle1 <- card(ran_ids = character(0))
idle2 <- card(ran_ids = character(0))
chk("★ 同样状态两次，结果一字不差", identical(idle1, idle2))
chk("★★ 默认是「待执行」", grepl("待执行", idle1) && !grepl("已执行", idle1))

done <- card(ran_ids = "m1:1")
chk("★★★ ran_ids 变了 → 卡片跟着变（已执行）",
    grepl("已执行", done) && !identical(idle1, done))
run <- card(running_id = "m1:1")
chk("★★★ running_id 命中 → 「执行中」", grepl("执行中", run) && !identical(idle1, run))
noexec <- card(executable = FALSE)
chk("★★ executable = FALSE 时不画状态标签（流式正文还没落库）",
    !grepl("待执行", noexec) && !identical(idle1, noexec))

# 黄条：alert 那一格既是"要不要画"，也是缓存 key 的一部分。
# ⚠️ 用 net_http_lib 那条规则（warn 级）：`rm(list = ls())` 之类**不触发
#    任何规则**，拿它当样本会得到一条"两边都没有黄条"的假绿灯。
wsegs <- dsapp_split_segments("```python\nrequests.post(url, data = d)\n```")
wseg <- Filter(function(s) identical(s$type, "code"), wsegs)[[1]]
warn_on  <- html(dsapp_code_card(wseg, "m2", alert = TRUE))
warn_off <- html(dsapp_code_card(wseg, "m2", alert = FALSE))
chk("★★ alert = FALSE 时不画「请确认后执行」那条黄条",
    grepl("请确认后执行", warn_on) && !grepl("请确认后执行", warn_off))

# 正文变了：整段 seg 都在 key 里，这一条保证以后加字段不会静默漏掉
osegs <- dsapp_split_segments("```r\ny <- 2\n```")
oseg <- Filter(function(s) identical(s$type, "code"), osegs)[[1]]
chk("★★ 代码内容变了 → 卡片变",
    !identical(html(dsapp_code_card(oseg, "m1")), idle1))

# ---------------------------------------------------------------------------
say("\n== D 组：该快的真的快了 ==")
# ---------------------------------------------------------------------------
mk <- function(kb) {
  unit <- "第 %d 段：先说明一下。\n\n```r\nx <- %d\nprint(x)\n```\n\n"
  s <- ""; k <- 0
  while (nchar(s, type = "bytes") < kb * 1024) {
    k <- k + 1; s <- paste0(s, sprintf(unit, k, k))
  }
  s
}
big <- mk(30L)
t0 <- Sys.time(); invisible(dsapp_render_message(big, "stream", executable = FALSE))
cold <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
t0 <- Sys.time(); invisible(dsapp_render_message(big, "stream", executable = FALSE))
hot <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
say("  30 KB / %d 段：冷 %.0f ms，热 %.0f ms", length(dsapp_split_segments(big)), cold, hot)
chk("★★ 同一条正文重画，热的那次至少快 5 倍（缓存真的命中了）",
    hot * 5 < cold, sprintf("冷 %.0f ms / 热 %.0f ms", cold, hot))
chk("★ 热的那次进入毫秒级", hot < 100, sprintf("%.0f ms", hot))

# ---------------------------------------------------------------------------
say("\n== E 组：JIT 关掉了（「页面未响应」的主因）==")
# ---------------------------------------------------------------------------
#
# ⚠️ 这一组必须**真去加载 app.R**，不能只在这份脚本里 source R/*.R 了事 ——
#    JIT 那一段是 app.R 的顶层代码，绕过 app.R 就等于没测到。
#    所以起子进程，让它自己 source("app.R")，回来报当时的 JIT 等级。
#    数据根指到临时目录、--vanilla 挡掉仓库根的 .Renviron（那份指着生产库）。
run_app_check <- function(app_dir, tmp, jit_env = NULL) {
  a <- normalizePath(app_dir)
  script <- file.path(tmp, sprintf("jitboot-%s.R", if (is.null(jit_env)) "def" else jit_env))
  writeLines(c(
    sprintf('setwd(%s)', deparse(a)),
    sprintf('Sys.setenv(DSAPP_APP_DIR = %s)', deparse(a)),
    'suppressMessages(source("app.R"))',
    'cat(sprintf("JIT_LEVEL=%d\\n", compiler::enableJIT(-1)))'
  ), script)
  env <- c(sprintf("DSAPP_DATA_ROOT=%s", file.path(tmp, "jitroot")))
  if (!is.null(jit_env)) env <- c(env, sprintf("DSAPP_JIT=%s", jit_env))
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
                                  c("--vanilla", shQuote(script)),
                                  stdout = TRUE, stderr = TRUE, env = env, timeout = 300))
  m <- regmatches(out, regexpr("JIT_LEVEL=[0-9]+", out))
  if (!length(m)) return(list(ok = FALSE, out = paste(tail(out, 6), collapse = " | ")))
  list(ok = TRUE, level = as.integer(sub("JIT_LEVEL=", "", m[[1]])))
}

d <- run_app_check(app_dir, tmp)
chk("★★ 真加载一遍 app.R：加载完 JIT 已经是 0（默认值下）",
    isTRUE(d$ok) && identical(d$level, 0L),
    if (isTRUE(d$ok)) sprintf("JIT=%d", d$level) else paste("子进程没起来:", d$out))

d3 <- run_app_check(app_dir, tmp, jit_env = "3")
chk("★ DSAPP_JIT=3 能把 R 的默认行为开回来（对照用的口子真的接上了）",
    isTRUE(d3$ok) && identical(d3$level, 3L),
    if (isTRUE(d3$ok)) sprintf("JIT=%d", d3$level) else paste("子进程没起来:", d3$out))

# 口子写错要退回 0：宁可慢一点，也不要一个"看着设了、其实没设"的开关
# （本仓栽过：`%||%` 碰到 S4 连接恒 FALSE 那次）。这一段在本进程里量 ——
# 把 app.R 里那段 local({...}) 原样抠出来跑，顺带证明它是自足的。
app_jit_stanza <- function(p) {
  al <- readLines(p, warn = FALSE)
  i <- grep("compiler::enableJIT(lv)", al, fixed = TRUE)
  if (length(i) != 1L) return(NULL)
  a <- suppressWarnings(max(grep("^local\\(\\{$", al[seq_len(i)])))
  b <- i - 1L + suppressWarnings(min(grep("^\\}\\)$", al[i:length(al)])))
  if (!is.finite(a) || !is.finite(b) || b < a) return(NULL)
  al[a:b]
}
st <- app_jit_stanza("app.R")
chk("★ app.R 里那段 JIT 开关是自足的一段 local({...})",
    !is.null(st) && length(st) >= 3L && any(grepl("^local\\(\\{$", st)),
    sprintf("%s 行", length(st)))
for (bad in c("abc", "-1", "9")) {
  Sys.setenv(DSAPP_JIT = bad)
  invisible(eval(parse(text = paste(st, collapse = "\n"))))
  chk(sprintf("★ DSAPP_JIT=%s（乱写）退回 0，而不是留个假开关", bad),
      identical(compiler::enableJIT(-1), 0L), sprintf("JIT=%d", compiler::enableJIT(-1)))
}
Sys.unsetenv("DSAPP_JIT")
# ⚠️ invisible()：`local({...})` 的返回值是**顶层可见**的，裸 eval 会往输出里
#    打一行 `[1] 0`（看着像测试自己算错了什么，其实只是它把结果打印了出来）。
invisible(eval(parse(text = paste(st, collapse = "\n"))))

# ★★ 机制级：JIT 到底省掉了什么。
#    R 是**第二次调用之前**才编（第一次照样解释执行），所以探针必须调到第二次。
#    判据用 profile 里的编译器帧（cmpfun / genCode / putconst / …）——
#    这一条是确定性的：编了就是编了，采样器不会漏掉几百毫秒的编译。
jit_frames <- function(level, nstmt = 800L) {
  compiler::enableJIT(level)
  code <- paste(sprintf("v%d <- %d + 1", seq_len(nstmt), seq_len(nstmt)), collapse = "; ")
  f <- eval(parse(text = sprintf("function() { %s; v%d }", code, nstmt)))
  caller <- function(g) g()
  invisible(caller(f))                      # 第一次：解释执行，不编
  pf <- file.path(tmp, sprintf("jitprof-%d.out", level))
  suppressWarnings(utils::Rprof(pf, interval = 0.005))
  invisible(caller(f))                      # 第二次：JIT 3 就在这一下编
  utils::Rprof(NULL)
  ln <- readLines(pf, warn = FALSE)
  sum(grepl("cmpfun|genCode|putconst|findCenvVar|tryInline", ln))
}
f3 <- jit_frames(3L)
f0 <- jit_frames(0L)
say("  同一个大闭包第二次调用：JIT 3 采样到 %d 帧编译器，JIT 0 采样到 %d 帧", f3, f0)
chk("★★ JIT 3 下确实要付这笔编译钱（不然这一组就是在测空气）", f3 > 0L,
    sprintf("%d 帧", f3))
chk("★★★ JIT 0 下同一动作一帧编译器都没有（用户等的那几秒就是它）",
    f0 == 0L, sprintf("%d 帧", f0))
invisible(compiler::enableJIT(0L))   # 别把这份测试自己的进程留在 JIT 3 上

say("\n== 通过 %d / 失败 %d ==", NOK, nfail)
say("（数据根目录 %s，跑完可以整个删掉）", tmp)
quit(status = if (nfail == 0L) 0L else 1L)
