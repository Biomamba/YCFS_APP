# =============================================================================
# 文献速递的定时订阅（Test_V15.2 item 3）
# =============================================================================
#
# 用户原话：
#   「只手动发，给用户一个界面或者按钮，可以按照关键词设置定时发送任务」
#   「定时到点的那一刻」→ **「自动跑一遍新的，跑完发邮件」**
#
# 也就是：到点了，用这个订阅的关键词**新建一个对话**，把速递跑一遍，
# 跑完把 `文献速递.md` 发到该账号的邮箱。
#
# ---- ⚠️ 这个文件**不许出现任何 Shiny** -------------------------------------
#
# 因为它的主要调用方是**调度器**（run_scheduler.R），而调度器是一个
# 独立的 Rscript，进程里根本没有 Shiny 会话、也没有主进程的内存。
# 这一点和 R/detach.R 是同一条纪律 —— 它的头部写着"子进程看不见主进程的
# 内存"，这里更彻底：连主进程都不一定活着。
#
# 具体后果：
#   · 所有函数只许用 cfg / con / 纯计算，不许出现 reactive / session / input
#   · 原来住在 R/mod_lit.R 里的几个**纯**助手（关键词分割、技能挑选）
#     搬到了这个文件 —— 订阅的新增表单要用它们，而订阅的执行路径
#     （dsapp_lit_tick）也要用关键词分割。留在 mod_lit.R 里的话，
#     调度器一 source 就是 could not find function。
#     ⚠️ 搬过来不是抄一份：mod_lit.R 那边**删掉了**，两边共用这一份。
#
# ---- ⚠️ 时区：这是本文件最容易出错的地方 -----------------------------------
#
# 库里所有时间戳都是 UTC（dsapp_now）。但「每周一早上 8 点」里的 8 点是
# **用户墙上的 8 点**。lit_subs.next_at 一律存**本地**时间字符串
# （cfg$tz），和 UTC 无关。
#
# 拿它和 dsapp_now() 直接比是错的 —— 那会在中国时区把 8 点的任务挪到下午 4 点，
# 而两边单看都没错。所有的比较都走 dsapp_lit_now()。
# =============================================================================

# 一个账号最多能配几条订阅。
#
# 为什么要有上限：每一条到点都会**真的跑一次完整 agent 循环**，烧的是这个
# 账号自己的 token。没有上限的话，一个误操作（或者一个脚本）能在一晚上
# 排几百次检索，账单第二天才发现。
DSAPP_LIT_SUB_MAX <- 10L

# 单次定时运行的最长墙上时间（秒）。到点自动跑，没有任何人在看 ——
# 这是它和"用户点一下"最大的区别。超了就当失败收尾并发失败邮件。
DSAPP_LIT_RUN_WALL <- 3600L

# 调度器每一轮最多认领几条。防的是"积压了几十条，一次 tick 跑一整天"。
DSAPP_LIT_TICK_MAX <- 3L

# 认领之后多久还没收尾，就当那个进程已经死了，放回去重跑。
#
# ⚠️ 口径是 RUN_WALL 的两倍：认领到收尾之间最长就是 RUN_WALL（后台循环自己
#    会到点停），再加等待循环那 120 秒的余量。阈值给小了会把**正在跑**的
#    订阅抢过来重跑 —— 那是真的重复烧 token、重复发信。
DSAPP_LIT_RECLAIM_SEC <- 2 * DSAPP_LIT_RUN_WALL

# ---- 从 mod_lit.R 搬过来的纯助手 -------------------------------------------

#' 关键词的分割
#'
#' 支持换行、中英文逗号、分号、顿号 —— 用户从别处粘一串关键词进来时
#' 这几种分隔符都可能出现。
#'
#' ⚠️ **不按空格切**。"single cell RNA" 是一个概念，按空格切成三个词之后
#'    检索式会变成 `single AND cell AND RNA`，召回的东西完全不是一回事，
#'    而且用户看不出来哪里错了 —— 他只会觉得"搜出来的东西不相关"。
#'    要输入多个关键词就用上面那几种分隔符，界面上写着。
dsapp_lit_keywords <- function(txt) {
  txt <- as.character(txt %||% "")
  parts <- unlist(strsplit(txt, "[\n\r,，;；、]+"))
  parts <- trimws(parts)
  unique(parts[nzchar(parts)])
}

#' 这页能挂的技能（＝内置的那批）
#'
#' 用户要的是"关联一些**文献整理的开源 skills**"，内置技能正是那一批
#' （skills_builtin/*.md，每篇都带上游 repo 和 license）。
#'
#' @return data.frame(id, name, summary) —— 库里没有（还没种上）时返回 NULL
dsapp_lit_skill_choices <- function(con = dsapp_db()) {
  df <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT id, name, summary FROM skills
        WHERE user_id IS NULL AND builtin = 1
        ORDER BY id"),
    error = function(e) NULL)
  if (is.null(df) || !nrow(df)) return(NULL)
  df
}

#' 默认勾上的那几条
#'
#' ★ V13.12 item 14（用户原话）：「文献检索请用这个 skills：
#'   https://github.com/ustc-ai4science/academic-search；文献阅读 skills
#'   可以用这个：https://github.com/917Dhj/DeepPaperNote」。
#'   两条都已做成内置技能（`skills_builtin/<目录>/SKILL.md` 那种文件夹形态，
#'   见 skills.R 里 dsapp_skills_builtin_md 的说明），所以这里按**名字**认 ——
#'   内置技能在库里没有别的身份（user_id IS NULL + name）。
#'
#' ⚠️ 顺序就是 DSAPP_LIT_SKILL_NAMES 的顺序，不是库里的 id 顺序：
#'    勾选框是照着这个顺序铺的，检索那条排在前面对应用户说的先后。
#'    用 `match()` 而不是 `which(%in%)` —— 后者跟着**库**的顺序走，
#'    改动一下种技能的次序，勾选框里的次序就会莫名其妙地变。
#'
#' ⚠️ 认不出来时返回 integer(0) 而不是报错：这两条技能可能还没种进库
#'    （老库升级的那个瞬间），那种情况下"挂不上技能"不该让人用不了这页。
DSAPP_LIT_SKILL_NAMES <- c("academic-search", "deeppapernote")

#' 两条新技能一条都没种上时的退路
#'
#' V13.11 自撰的那条「文献速递」（skills_builtin/literature-digest.md），
#' 内容就是"怎么查公开文献库"，和 academic-search 覆盖面重叠但更短。
#' 留它是为了**老库升级的那个瞬间**：新技能还没 seed 进去时，
#' 这一页至少还能挂上一条讲检索的技能，而不是空着手去检索。
#'
#' ⚠️ 只在整个 DSAPP_LIT_SKILL_NAMES 一条都找不到时才用。两条新技能都在
#'    的时候**不**默认勾它：三套检索说法叠在一起，模型会挑着听。
DSAPP_LIT_SKILL_FALLBACK <- "文献速递"

dsapp_lit_default_skill <- function(choices) {
  if (is.null(choices) || !nrow(choices)) return(integer(0))
  hit <- match(DSAPP_LIT_SKILL_NAMES, choices$name)
  hit <- hit[!is.na(hit)]
  if (length(hit)) return(as.integer(choices$id[hit]))
  fb <- match(DSAPP_LIT_SKILL_FALLBACK, choices$name)
  if (is.na(fb)) return(integer(0))
  as.integer(choices$id[[fb]])
}

#' 已勾上的技能排到最前面（V13.12 item 16）
#'
#' 抽成函数是为了 selftest 能直接盯这条规则 —— 它原本是 renderUI 里的三行
#' 内联代码，改错了只有"打开页面看"才发现。
#'
#' @param ids 技能库里的全部 id（字符，按库里的原序）
#' @param on  已经勾上的 id（字符；NULL = 还没收到前端事件，保持原序）
#' @return 排好序的 id 字符向量。**顺序**变了，**集合**没变。
dsapp_lit_skill_order <- function(ids, on) {
  ids <- as.character(ids)
  if (!length(ids)) return(character(0))
  # NULL（还没点过勾选框）和 character(0)（用户把勾全取消了）是两回事，
  # 这里保持原序 —— "全取消"那条路径下 on 就是空的，下面照样成立。
  if (is.null(on)) return(ids)
  # ⚠️ 前端送上来的值里可能留着**已经删掉的**技能 id（勾了之后管理员把技能
  #    下架），直接拿来排会让 ord 里出现库里没有的 id，渲染时对不上名字。
  on <- intersect(as.character(on), ids)
  c(on, setdiff(ids, on))
}

#' 「告诉 AI 注意事项」的常用预设（V13.12 item 18）
#'
#' 用户原话：「还想让它注意什么（可留空），这部分可以换成"告诉AI注意事项"，
#' 留几个默认常用选项，并依旧支持用户填写自定义」。
#'
#' ⚠️ 这些句子**既是界面上勾选的文字，也是原样写进提示词的那句话** ——
#'    两边共用同一份，改一处不会忘掉另一处（prompts.R 那边是直接拼
#'    `  - <这条>`，不再加工）。所以每条都要写成**对 AI 说的话**
#'    （"不要…"、"优先…"），不能写成名词短语（"综述"、"公开数据"）——
#'    名词短语勾上去，模型只能猜用户想让它干嘛。
#'
#' ⚠️ 不设默认勾选：这一栏的语义是"额外的要求"，默认全空 = 不额外约束，
#'    和原来那个空 textInput 的行为一致。勾上才生效。
DSAPP_LIT_NOTE_PRESETS <- c(
  "不要综述，只要原始研究",
  "优先选有公开数据或代码的",
  "优先近三年的工作",
  "把还没正式发表的预印本也算进来",
  "不要只给摘要结论，把关键实验证据也写出来"
)

#' 「学术前沿订阅」的方向预设（★ V15.5 item 5）
#'
#' 用户原话：「在文献速递里加"学术前沿订阅"子页面」。追问"前沿怎么定"之后
#' 选的是**「复用文献速递那套」** —— 也就是不另做一条检索链路，这一页只负责
#' 把"方向 / 时间窗 / 技能"这三样**预设**填进那套共用的输入框。
#'
#' ⚠️ **值是英文关键词，键是给人看的中文方向名**。理由和 dsapp_lit_prompt
#'    里那条"中文关键词先自己想出英文术语"是同一个：这几个库主要收英文文献，
#'    直接把中文填进检索式基本搜不到东西，而"搜不到"会被误当成"这个方向
#'    没有研究"。预设里直接给英文，是为了**不让用户在这一步上踩坑**。
#'    界面上显示中文名，是为了他勾的时候知道自己在勾什么。
#'
#' ⚠️ 组内是**同一个方向的不同说法**（同义词/子话题），下游是拿
#'    `unlist()` 拍平之后**一起**填进关键词框的 —— 见 mod_lit 的
#'    apply_frontier()。所以这里不要放"互斥的东西"（比如把两个对立方法
#'    放进同一组），那会让检索式变成 `A AND B` 而互相抵消。
#'
#' ⚠️ 每个词里**不要出现逗号、分号、顿号**：填进关键词框之后是按这几个
#'    符号切的（dsapp_lit_keywords），带逗号的词会被劈成两个。
DSAPP_LIT_FRONTIER_PRESETS <- list(
  "单细胞与空间组学" = c("single-cell omics", "spatial transcriptomics",
                         "spatial multi-omics", "cell atlas"),
  "AI 与生物医学大模型" = c("foundation model", "large language model",
                            "biomedical AI", "protein language model"),
  "肿瘤免疫与微环境" = c("tumor microenvironment", "immune checkpoint",
                         "T cell exhaustion", "immunotherapy resistance"),
  "基因编辑与递送" = c("CRISPR screen", "base editing",
                       "lipid nanoparticle", "in vivo delivery"),
  "微生物组与代谢" = c("metagenomics", "gut microbiome",
                       "metabolomics", "microbiome-host interaction"),
  "表观遗传与染色质" = c("single-cell ATAC-seq", "chromatin accessibility",
                         "epigenome", "3D genome")
)

#' 前沿模式默认的时间窗（年）
#'
#' 「前沿」的全部意义就在这个窗口上 —— 不限年份的前沿订阅，跑出来的是
#' 一份综述书单。默认给 1 年：够窄，又不至于一周就空了。
DSAPP_LIT_FRONTIER_WINDOW <- 1L

#' 前沿模式的年窗口选项（界面上的下拉）
#'
#' 值是**往前几年**，0 = 不限。界面文案在这里，换算在 mod_lit 的
#' frontier_years() 里 —— 换算是纯函数，selftest 直接盯它。
DSAPP_LIT_FRONTIER_WINDOWS <- c("最近 1 年" = 1L, "最近 2 年" = 2L,
                                "最近 3 年" = 3L, "不限年份" = 0L)

#' 前沿模式的时间窗 → c(起, 止)
#'
#' @param win   往前几年（0 = 不限）
#' @param today 今天的日期（默认取系统时间；参数化是为了 selftest 能钉死）
#' @return 长度 2 的整数向量；不限时返回 c(NA, NA)（= 不往提示词里写年份）
dsapp_lit_frontier_years <- function(win, today = Sys.Date()) {
  win <- suppressWarnings(as.integer(win)[1])
  if (is.na(win) || win <= 0L) return(c(NA_integer_, NA_integer_))
  this_year <- as.integer(format(as.Date(today), "%Y"))
  c(this_year - win + 1L, this_year)
}

#' 订阅里的技能存成什么、怎么读回来
#'
#' 库里存**逗号分隔的 id 字符串**（跟用户/技能那边的既有约定一致，
#' 不另开一张关联表 —— 一条订阅挂的技能就那么两三个，为它建表不划算）。
dsapp_lit_skills_parse <- function(txt) {
  v <- suppressWarnings(as.integer(unlist(strsplit(
    as.character(txt %||% "")[1], "[,，;；]+"))))
  v <- v[!is.na(v)]
  unique(v)
}

dsapp_lit_skills_paste <- function(ids) {
  ids <- suppressWarnings(as.integer(unlist(ids)))
  ids <- ids[!is.na(ids)]
  if (!length(ids)) return("")
  paste(unique(ids), collapse = ",")
}

# ---- 建表 -------------------------------------------------------------------

dsapp_db_schema_lit <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS lit_subs (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id      INTEGER NOT NULL,
      title        TEXT NOT NULL DEFAULT '',
      keywords     TEXT NOT NULL,
      n_read       INTEGER NOT NULL DEFAULT 3,
      n_skim       INTEGER NOT NULL DEFAULT 5,
      year_from    INTEGER,
      year_to      INTEGER,
      extra        TEXT NOT NULL DEFAULT '',
      skills       TEXT NOT NULL DEFAULT '',
      freq         TEXT NOT NULL DEFAULT 'weekly',
      weekday      INTEGER NOT NULL DEFAULT 1,
      day_of_month INTEGER NOT NULL DEFAULT 1,
      hour         INTEGER NOT NULL DEFAULT 8,
      minute       INTEGER NOT NULL DEFAULT 0,
      enabled      INTEGER NOT NULL DEFAULT 0,
      next_at      TEXT,
      last_at      TEXT,
      last_status  TEXT NOT NULL DEFAULT '',
      last_error   TEXT NOT NULL DEFAULT '',
      last_session TEXT,
      created_at   TEXT NOT NULL,
      updated_at   TEXT NOT NULL
    )")
  # 调度器每一轮就查这一条：enabled=1 且到点了。没有索引的话每 5 分钟
  # 全表扫一遍 —— 表小的时候无所谓，但这是个**每 5 分钟必然发生**的查询，
  # 而 lit_subs 会随着用户增长。
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_litsub_due ON lit_subs(enabled, next_at)")
  # 界面按账号列自己的订阅
  DBI::dbExecute(con,
    "CREATE INDEX IF NOT EXISTS idx_litsub_user ON lit_subs(user_id)")
  invisible(TRUE)
}

# ---- 时间 -------------------------------------------------------------------

#' 现在几点（**本地时区**，不是 dsapp_now 的 UTC）
#'
#' @return POSIXct
dsapp_lit_now <- function(cfg = dsapp_config()) {
  as.POSIXct(Sys.time(), tz = cfg$tz %||% "UTC")
}

#' 把一个 POSIXct 写成 lit_subs 里存的那种字符串（本地时间，不带时区）
dsapp_lit_fmt <- function(t, tz = "UTC") {
  format(as.POSIXct(t, tz = tz), "%Y-%m-%d %H:%M:%S", tz = tz)
}

#' 某个日期所在月有多少天
dsapp_lit_days_in_month <- function(d) {
  d <- as.Date(d)
  first <- as.Date(cut(d, "month"))
  nxt <- seq(first, by = "month", length.out = 2L)[2L]
  as.integer(nxt - first)
}

#' ★ 下一次该跑是什么时候 —— **纯函数，整个订阅功能里最该被测的一块**
#'
#' @param freq         daily / weekly / monthly
#' @param weekday      1=周一 … 7=周日（ISO，不是 R 的 wday）
#' @param day_of_month 1-31
#' @param hour,minute  本地墙上时间
#' @param from         从这个时刻**之后**找（POSIXct）
#' @param tz           时区名
#'
#' @return 本地时间字符串 `%Y-%m-%d %H:%M:%S`；找不到（参数离谱）返回 NA
#'
#' ⚠️⚠️ **判据必须是严格大于 `from`，不能是"大于等于"。**
#'    调度器每 5 分钟 tick 一次，认领时是拿 `next_at <= now` 判到没到点的。
#'    如果这里算出来的是"大于等于"，那么 08:00:00 那一刻认领之后算出的下一个
#'    还是 08:00:00 —— 于是同一个 tick 里、以及之后每一个 tick 里，
#'    它**永远是到点的**。表现是订阅被反复触发、token 一路烧，
#'    而库里 last_status 一直显示成功，看不出任何异常。
#'
#' ⚠️ **monthly 的 29/30/31 会落到当月最后一天。** 2 月没有 31 号，
#'    这时按 28/29 号跑，而不是"这个月跳过"。理由：
#'      · 跳过的话，选了 31 的用户一年只跑 7 次，而他设的是"每月"——
#'        少跑这件事没有任何地方会告诉他。
#'      · 日历应用（以及大多数人的直觉）都是"顺延到月末"。
#'    界面上会把算出来的 next_at 显示出来（"下次：2026-02-28 08:00"），
#'    所以这个顺延是**看得见**的，不是暗箱。
#'
#' ⚠️ 夏令时：跳变那天本地 08:00 可能**不存在**（春季前进一小时）。
#'    `as.POSIXct` 对不存在的墙上时间返回 NA，这里遇到就顺延到下一个匹配的
#'    日子，而不是返回 NA 把整条订阅卡死。
#'    （Asia/Shanghai 没有夏令时，但自托管部署可能在别处。）
dsapp_lit_next_at <- function(freq = "weekly", weekday = 1L, day_of_month = 1L,
                              hour = 8L, minute = 0L,
                              from = Sys.time(), tz = "UTC") {
  freq <- as.character(freq %||% "weekly")[1]
  if (!freq %in% c("daily", "weekly", "monthly")) freq <- "weekly"

  clamp <- function(v, lo, hi, def) {
    v <- suppressWarnings(as.integer(v)[1])
    if (is.na(v)) v <- def
    max(lo, min(hi, v))
  }
  hour   <- clamp(hour, 0L, 23L, 8L)
  minute <- clamp(minute, 0L, 59L, 0L)
  weekday      <- clamp(weekday, 1L, 7L, 1L)
  day_of_month <- clamp(day_of_month, 1L, 31L, 1L)

  tz <- as.character(tz %||% "UTC")[1]
  if (!nzchar(tz)) tz <- "UTC"

  from_ct <- as.POSIXct(from)
  lt <- as.POSIXlt(from_ct, tz = tz)
  # ⚠️ 用 Date 做"加一天"，不要用 POSIXct + 86400：夏令时那天只有 23 或 25
  #    小时，加 86400 秒会跳过或重复一天，循环于是在某个日子上原地打转。
  base_date <- as.Date(sprintf("%04d-%02d-%02d", lt$year + 1900L,
                               lt$mon + 1L, lt$mday))

  matches_day <- function(d) {
    if (identical(freq, "daily")) return(TRUE)
    if (identical(freq, "weekly")) {
      # R 的 wday 是 0=周日；订阅里存的是 ISO（1=周一…7=周日）
      w <- as.POSIXlt(d)$wday
      iso <- if (is.na(w)) NA_integer_ else if (w == 0L) 7L else as.integer(w)
      return(identical(iso, weekday))
    }
    want <- min(day_of_month, dsapp_lit_days_in_month(d))
    identical(as.integer(format(d, "%d")), as.integer(want))
  }

  # 400 天足够覆盖"monthly + 月末顺延 + 夏令时顺延"最坏的情况
  # （最坏也就 62 天左右，留足余量）。
  for (i in 0:400) {
    d <- base_date + i
    if (!isTRUE(matches_day(d))) next
    cand <- suppressWarnings(as.POSIXct(
      sprintf("%s %02d:%02d:00", format(d, "%Y-%m-%d"), hour, minute),
      tz = tz))
    if (is.na(cand)) next                       # 夏令时跳变，这天这个点不存在
    # ★ 严格大于，见上面的说明
    if (cand > from_ct) return(format(cand, "%Y-%m-%d %H:%M:%S", tz = tz))
  }
  NA_character_
}

# ---- 读写（⚠️ 每一条都带 user_id 条件）--------------------------------------

#' 列某个账号的订阅
#'
#' ⚠️ `WHERE user_id = ?` **不是可选的**。这个函数的调用方是界面，
#'    而界面上没有任何东西阻止一个人去看别人的订阅 —— 条件漏了就是
#'    "别人的关键词、别人的邮箱、别人的运行结果"全都露出来，
#'    而页面上看起来完全正常。
dsapp_litsub_list <- function(user_id, cfg = dsapp_config(), con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(user_id) || is.na(user_id)) return(NULL)
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT * FROM lit_subs WHERE user_id = ? ORDER BY id DESC",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  r
}

dsapp_litsub_get <- function(id, user_id, cfg = dsapp_config(), con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(id) || is.na(id) || is.null(user_id) || is.na(user_id)) return(NULL)
  r <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT * FROM lit_subs WHERE id = ? AND user_id = ?",
      params = list(as.integer(id), as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  as.list(r[1, , drop = FALSE])
}

#' 新增一条订阅
#'
#' @return list(ok=, id=, msg=)
dsapp_litsub_add <- function(user_id, keywords, n_read = 3L, n_skim = 5L,
                             year_from = NULL, year_to = NULL, extra = "",
                             skills = integer(0), freq = "weekly",
                             weekday = 1L, day_of_month = 1L,
                             hour = 8L, minute = 0L, enabled = FALSE,
                             title = "", cfg = dsapp_config(), con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(user_id) || is.na(user_id)) {
    return(list(ok = FALSE, msg = "没有账号"))
  }
  kws <- dsapp_lit_keywords(keywords)
  if (!length(kws)) return(list(ok = FALSE, msg = "先填至少一个关键词"))

  n <- tryCatch(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM lit_subs WHERE user_id = ?",
                    params = list(as.integer(user_id)))$n[1],
    error = function(e) 0L)
  if (isTRUE(n >= DSAPP_LIT_SUB_MAX)) {
    return(list(ok = FALSE,
                msg = sprintf("一个账号最多 %d 条订阅，先删掉几条",
                              DSAPP_LIT_SUB_MAX)))
  }

  freq <- as.character(freq %||% "weekly")[1]
  if (!freq %in% c("daily", "weekly", "monthly")) freq <- "weekly"

  nm <- function(v, lo, hi, def) {
    v <- suppressWarnings(as.integer(v)[1])
    if (is.na(v)) v <- def
    max(lo, min(hi, v))
  }
  hour <- nm(hour, 0L, 23L, 8L); minute <- nm(minute, 0L, 59L, 0L)
  weekday <- nm(weekday, 1L, 7L, 1L); dom <- nm(day_of_month, 1L, 31L, 1L)
  n_read <- nm(n_read, 0L, 50L, 3L); n_skim <- nm(n_skim, 0L, 50L, 5L)

  yf <- suppressWarnings(as.integer(year_from)[1])
  yt <- suppressWarnings(as.integer(year_to)[1])
  if (is.na(yf)) yf <- NA_integer_
  if (is.na(yt)) yt <- NA_integer_

  ttl <- trimws(as.character(title %||% "")[1])
  if (!nzchar(ttl)) ttl <- substr(paste(kws, collapse = "、"), 1L, 40L)

  now <- dsapp_now()
  # next_at 只在**开启**时才算。关着的订阅 next_at 是 NULL，
  # 调度器的 WHERE next_at <= ? 天然不会选中它 —— 不需要额外判 enabled。
  nxt <- if (isTRUE(enabled)) {
    dsapp_lit_next_at(freq, weekday, dom, hour, minute,
                      from = dsapp_lit_now(cfg), tz = cfg$tz)
  } else NA_character_

  id <- tryCatch(
    DBI::dbGetQuery(con,
      "INSERT INTO lit_subs
         (user_id, title, keywords, n_read, n_skim, year_from, year_to,
          extra, skills, freq, weekday, day_of_month, hour, minute,
          enabled, next_at, created_at, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       RETURNING id",
      params = list(as.integer(user_id), ttl, paste(kws, collapse = "、"),
                    n_read, n_skim, yf, yt,
                    as.character(extra %||% "")[1],
                    dsapp_lit_skills_paste(skills),
                    freq, weekday, dom, hour, minute,
                    if (isTRUE(enabled)) 1L else 0L, nxt, now, now))$id,
    error = function(e) NULL)
  if (is.null(id) || !length(id)) {
    return(list(ok = FALSE, msg = "订阅没建起来（写库失败）"))
  }
  list(ok = TRUE, id = as.integer(id), msg = "")
}

#' 改一条订阅（只改传进来的字段）
#'
#' @param fields 具名 list，名字必须是 lit_subs 的列名之一。
#'   ⚠️ **白名单**，不是拼字符串：列名来自调用方，直接拼进 SQL 就是注入。
dsapp_litsub_update <- function(id, user_id, fields, cfg = dsapp_config(),
                                con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(id) || is.na(id) || is.null(user_id) || is.na(user_id)) {
    return(list(ok = FALSE, msg = "没有账号"))
  }
  allowed <- c("title", "keywords", "n_read", "n_skim", "year_from", "year_to",
               "extra", "skills", "freq", "weekday", "day_of_month",
               "hour", "minute", "enabled", "next_at", "last_status",
               "last_error", "last_session")
  fields <- fields[names(fields) %in% allowed]
  if (!length(fields)) return(list(ok = FALSE, msg = "没有要改的字段"))

  # 改了频率/时间就要重算 next_at —— 否则界面上"下次运行"还是旧时间，
  # 而调度器按新的判据跑，两边对不上。
  if (any(c("freq", "weekday", "day_of_month", "hour", "minute", "enabled")
          %in% names(fields))) {
    cur <- dsapp_litsub_get(id, user_id, cfg, con)
    if (is.null(cur)) return(list(ok = FALSE, msg = "订阅不存在"))
    g <- function(k) if (k %in% names(fields)) fields[[k]] else cur[[k]]
    en <- isTRUE(as.logical(g("enabled")))
    if (en) {
      fields$next_at <- dsapp_lit_next_at(
        g("freq"), g("weekday"), g("day_of_month"), g("hour"), g("minute"),
        from = dsapp_lit_now(cfg), tz = cfg$tz)
    } else {
      fields$next_at <- NA_character_
    }
    fields$enabled <- if (en) 1L else 0L
  }
  fields$updated_at <- dsapp_now()

  sets <- paste(sprintf("%s = ?", names(fields)), collapse = ", ")
  ps <- unname(fields)
  ps <- c(ps, list(as.integer(id), as.integer(user_id)))
  n <- tryCatch(
    DBI::dbExecute(con,
      sprintf("UPDATE lit_subs SET %s WHERE id = ? AND user_id = ?", sets),
      params = ps),
    error = function(e) 0L)
  # ⚠️ 受影响行数是 0 有两种可能：行不存在，或者**它不属于这个人**。
  #    两种都返回失败，别去区分 —— 区分了就等于告诉调用方"有这么一条订阅，
  #    但不是你的"。
  if (!isTRUE(n > 0L)) return(list(ok = FALSE, msg = "改不动（订阅不存在）"))
  list(ok = TRUE, msg = "")
}

dsapp_litsub_delete <- function(id, user_id, cfg = dsapp_config(), con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(id) || is.na(id) || is.null(user_id) || is.na(user_id)) {
    return(list(ok = FALSE, msg = "没有账号"))
  }
  n <- tryCatch(
    DBI::dbExecute(con,
      "DELETE FROM lit_subs WHERE id = ? AND user_id = ?",
      params = list(as.integer(id), as.integer(user_id))),
    error = function(e) 0L)
  if (!isTRUE(n > 0L)) return(list(ok = FALSE, msg = "删不掉（订阅不存在）"))
  list(ok = TRUE, msg = "")
}

dsapp_litsub_toggle <- function(id, user_id, on, cfg = dsapp_config(),
                                con = NULL) {
  dsapp_litsub_update(id, user_id, list(enabled = isTRUE(on)), cfg, con)
}

# ---- 到点了：跑一遍，然后发邮件 ---------------------------------------------

#' 在某个账号名下找最近几份 `文献速递.md`
#'
#' 给「发到我的邮箱」那个下拉用。**只扫这个人自己的对话** ——
#' 工作区是按对话隔离的，扫别人的等于把别人的产出列出来给他看。
#'
#' @return data.frame(session_id, title, path, mtime, size)，按时间倒序；
#'   一份都没有时返回 NULL
dsapp_lit_find_digests <- function(user_id, cfg = dsapp_config(),
                                   con = NULL, limit = 30L) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  if (is.null(user_id) || is.na(user_id)) return(NULL)
  ss <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT id, title FROM sessions WHERE user_id = ?
        ORDER BY updated_at DESC LIMIT 200",
      params = list(as.integer(user_id))),
    error = function(e) NULL)
  if (is.null(ss) || !nrow(ss)) return(NULL)

  out <- list()
  for (i in seq_len(nrow(ss))) {
    sid <- as.character(ss$id[i])
    # ⚠️ create = FALSE：这个函数只是**看一眼**，不该因为看了就给别人
    #    建出一个空工作区来。
    wd <- dsapp_ws_dir(sid, cfg = cfg, create = FALSE)
    if (is.null(wd) || !dir.exists(wd)) next
    fs <- list.files(wd, pattern = "^文献速递.*\\.md$", full.names = TRUE)
    for (p in fs) {
      fi <- file.info(p)
      if (isTRUE(fi$isdir) || is.na(fi$size) || fi$size <= 0) next
      out[[length(out) + 1L]] <- data.frame(
        session_id = sid,
        title = as.character(ss$title[i] %||% ""),
        path = p, mtime = as.character(fi$mtime),
        size = as.numeric(fi$size), stringsAsFactors = FALSE)
    }
  }
  if (!length(out)) return(NULL)
  df <- do.call(rbind, out)
  df <- df[order(df$mtime, decreasing = TRUE), , drop = FALSE]
  utils::head(df, as.integer(limit))
}

#' 把一份速递排队发到某个账号的邮箱
#'
#' 手动按钮和定时任务**共用这一条** —— 两处各写一遍的话，"手动发的排版
#' 和定时发的不一样"这种问题迟早出现，而且没人会想到去比对两条路径。
#'
#' @param ref 去重键（定时任务传 'lit:<sub_id>:<下次应跑的时刻>'）
#' @return list(ok=, msg=, id=)
dsapp_lit_mail_queue <- function(user_id, md_path, cfg = dsapp_config(),
                                 con = NULL, ref = "", kind = "lit_manual",
                                 subject = NULL, note = "") {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，
  #    而 S4 连接对象**不支持 `[`** —— 直接抛 "object of type 'S4' is not
  #    subsettable"。传了连接的调用方会被自己的 tryCatch 静默吞掉，
  #    症状是"入库全绿、信一封没发"。同类教训见 R/utils.R 里 `%||%`
  #    关于 environment 恒走 fallback 的那一段。
  if (is.null(con)) con <- dsapp_db(cfg)
  u <- tryCatch(dsapp_user_by_id(user_id, con = con), error = function(e) NULL)
  if (is.null(u)) return(list(ok = FALSE, msg = "找不到账号"))
  to <- trimws(as.character(u$email %||% "")[1])
  if (!nzchar(to)) return(list(ok = FALSE, msg = "这个账号没有填邮箱"))

  if (!file.exists(md_path)) {
    return(list(ok = FALSE, msg = "那份速递文件已经不在了"))
  }
  body <- tryCatch(paste(readLines(md_path, warn = FALSE, encoding = "UTF-8"),
                         collapse = "\n"),
                   error = function(e) NULL)
  if (is.null(body) || !nzchar(trimws(body))) {
    return(list(ok = FALSE, msg = "那份速递是空的"))
  }

  if (is.null(subject)) {
    subject <- sprintf("文献速递 · %s",
                       format(as.POSIXct(Sys.time(), tz = cfg$tz %||% "UTC"),
                              "%Y-%m-%d"))
  }
  if (nzchar(note)) body <- paste0(note, "\n\n", body)

  id <- dsapp_mail_enqueue(
    to = to, subject = subject, body_md = body,
    # ⚠️ base_dir 用**文件所在目录**：正文里的 `![](fig1.png)` 是相对它
    #    解析的。传错的话所有图都内联不上，而邮件照样发得出去 ——
    #    收件人看到的是一篇没有图的报告，两边都不报错。
    base_dir = dirname(md_path),
    attach_path = md_path,
    kind = kind, ref = ref, user_id = user_id, cfg = cfg, con = con)

  if (is.na(id)) {
    # ref 撞了 = 这一份早就发过了。不是错误。
    return(list(ok = TRUE, id = NA_integer_, msg = "这一份之前已经发过了"))
  }
  list(ok = TRUE, id = id, msg = "")
}

#' ★ 调度器的每一轮：把到点的订阅跑掉
#'
#' **这是整个订阅功能的执行体**，run_scheduler.R 只调它。
#'
#' `now` 可以注入（自检用），默认是本地当前时间。
#'
#' @return list(ran=, skipped=, notes=)
dsapp_lit_tick <- function(cfg = dsapp_config(), now = NULL,
                           dry_run = FALSE) {
  con <- dsapp_db(cfg)
  now <- now %||% dsapp_lit_now(cfg)
  now_s <- dsapp_lit_fmt(now, cfg$tz)
  notes <- character(0)

  due <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT * FROM lit_subs
        WHERE enabled = 1 AND next_at IS NOT NULL AND next_at <= ?
        ORDER BY next_at LIMIT ?",
      params = list(now_s, as.integer(DSAPP_LIT_TICK_MAX))),
    error = function(e) NULL)

  if (is.null(due) || !nrow(due)) {
    return(list(ran = 0L, skipped = 0L, notes = notes, now = now_s))
  }
  if (isTRUE(dry_run)) {
    return(list(ran = 0L, skipped = nrow(due), notes = due$title, now = now_s))
  }

  ran <- 0L; skipped <- 0L
  for (i in seq_len(nrow(due))) {
    sub <- as.list(due[i, , drop = FALSE])

    # ---- 1. 先原子认领，再干活 ------------------------------------------
    #
    # ⚠️⚠️ **顺序不能反。** 上面那条 SELECT 挡不住并发（两个进程可以同时
    #    读到同一行），真正挡住的是认领那一步 —— 见 dsapp_lit_claim()。
    #
    #     反过来的话（先跑后写）：一轮 tick 从头跑到尾要几十分钟，
    #     而 timer 每 5 分钟就起一个新的 —— 于是同一条订阅会被并发跑
    #     好几遍，每一遍都真的调模型、真的烧 token、真的发一封邮件。
    #     而库里看起来一切正常。
    if (!isTRUE(dsapp_lit_claim(sub, now, cfg = cfg, con = con))) {
      skipped <- skipped + 1L; next
    }
    ran <- ran + 1L

    res <- tryCatch(
      dsapp_lit_run_one(sub, cfg = cfg),
      error = function(e) list(ok = FALSE, msg = conditionMessage(e),
                               session = NA_character_))

    tryCatch(
      DBI::dbExecute(con,
        "UPDATE lit_subs
            SET last_status = ?, last_error = ?, last_session = ?,
                updated_at = ?
          WHERE id = ?",
        params = list(if (isTRUE(res$ok)) "ok" else "failed",
                      substr(as.character(res$msg %||% "")[1], 1L, 500L),
                      as.character(res$session %||% NA_character_)[1],
                      dsapp_now(), as.integer(sub$id))),
      error = function(e) NULL)

    notes <- c(notes, sprintf("#%s %s：%s", sub$id, sub$title,
                              if (isTRUE(res$ok)) "跑完并发信了" else res$msg))
  }
  list(ran = ran, skipped = skipped, notes = notes, now = now_s)
}

#' 原子地认领一条订阅（把 next_at 推到下一次、状态改成 running）
#'
#' ★★ **这是"同一条订阅不会被跑两遍"的唯一保证。**
#'    `dsapp_lit_tick()` 开头那条 SELECT 挡不住并发：两个 tick 进程可以
#'    **同时**读到同一行（读不加锁），然后各跑一遍 —— 各调一次模型、
#'    各烧一次 token、各发一封邮件，而库里看起来完全正常。
#'    挡住它的是这条 UPDATE 是原子的：`WHERE ... AND next_at <= ?` 让第二个
#'    进程受影响行数为 0（next_at 已经被第一个推走了），于是它直接跳过。
#'
#' ⚠️ 条件里**必须**同时有 `id` 和 `next_at`：只留 `id` 的话两个进程都改到
#'    1 行、都认为认领成功。
#'
#' ⚠️ 单独拆成一个函数，是为了让自检**能直接调它两次**来验这个性质。
#'    夹在 tick 中间的话，"第二次认领失败"这件事只能靠"两个进程同时跑"
#'    来验 —— 那在自检里做不出来（要精确控制两个进程在同一个毫秒撞上），
#'    于是这条最关键的不变式就一直没被真正测过。
#'
#' @return TRUE = 认领成功，该跑了；FALSE = 别人抢先了，跳过
dsapp_lit_claim <- function(sub, now, cfg = dsapp_config(), con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，而 S4
  #    连接对象不支持 `[`。理由同 R/mail.R 里那几处，别再合回去。
  if (is.null(con)) con <- dsapp_db(cfg)
  now <- now %||% dsapp_lit_now(cfg)
  n <- tryCatch(
    DBI::dbExecute(con,
      "UPDATE lit_subs
          SET next_at = ?, last_at = ?, last_status = 'running',
              last_error = '', updated_at = ?
        WHERE id = ? AND enabled = 1 AND next_at <= ?",
      params = list(
        dsapp_lit_next_at(sub$freq, sub$weekday, sub$day_of_month,
                          sub$hour, sub$minute, from = now, tz = cfg$tz),
        dsapp_now(), dsapp_now(), as.integer(sub$id),
        dsapp_lit_fmt(now, cfg$tz))),
    error = function(e) 0L)
  isTRUE(n > 0L)
}

#' 把卡在 'running' 的订阅标成失败（调度进程中途死了的收尾）
#'
#' ⚠️⚠️ 为什么非要有这一个：认领（`last_status = 'running'`）和收尾之间
#'    隔着最长 `DSAPP_LIT_RUN_WALL` 秒。这个窗口里进程被弄死（OOM、机器重启、
#'    部署时 `systemctl restart`）的话，那一行就**永远停在 'running'** ——
#'    而 `dsapp_lit_tick()` 只捞 `next_at <= now`，next_at 在认领那一刻已经
#'    推到了下一次，所以它再也不会被捞起来。界面上显示"正在跑"，其实那个
#'    进程早就没了，而且**没有任何东西会告诉用户**。
#'
#' @param older_than 认领之后超过这么多秒还没收尾就算死了。默认的两倍
#'   RUN_WALL 见 `DSAPP_LIT_RECLAIM_SEC` 的说明 —— 给少了会把正在跑的抢过来。
#'
#' @section next_at 故意**不动**：
#'   死了的这一轮不补跑。理由是补跑要防"每 5 分钟重试一次、每次都死在同一个
#'   地方"—— 那会一直烧 token 而用户看不见。改成标红：`last_status = 'failed'`
#'   加一句说明，用户在「文献速递」页看得见，想跑可以自己按那颗按钮。
#'   （对应的另一半在邮件那边：万一 agent 跑完了、只是发信那一步死的，
#'     那封信会停在 'sending'，由 `dsapp_mail_reclaim()` 放回去重发。）
#'
#' @return 标了几条
dsapp_lit_reclaim <- function(cfg = dsapp_config(),
                              older_than = DSAPP_LIT_RECLAIM_SEC, con = NULL) {
  # ⚠️ 不能用 `con %||% dsapp_db(cfg)`：`%||%` 里有 `is.na(a[1])`，而 S4
  #    连接对象不支持 `[`。理由同 R/mail.R 里那几处，别再合回去。
  if (is.null(con)) con <- dsapp_db(cfg)
  cutoff <- format(Sys.time() - older_than, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  n <- tryCatch(
    DBI::dbExecute(con,
      "UPDATE lit_subs
          SET last_status = 'failed',
              last_error = '上一轮跑到一半调度进程就没了（超时或重启），
这一轮没有补跑。想现在跑的话在「文献速递」页按一下那颗按钮。',
              updated_at = ?
        WHERE last_status = 'running' AND last_at IS NOT NULL AND last_at < ?",
      params = list(dsapp_now(), cutoff)),
    error = function(e) 0L)
  as.integer(n %||% 0L)
}

#' 跑一条订阅（建会话 → 挂技能 → 起后台循环 → 等它完 → 把速递发出去）
#'
#' ⚠️ 这个函数**会阻塞到那次 agent 循环结束**（最长 DSAPP_LIT_RUN_WALL 秒）。
#'    调用它的是调度器的 oneshot 进程，不是 Shiny 主进程 —— 别在界面里调。
#'
#' @return list(ok=, msg=, session=)
dsapp_lit_run_one <- function(sub, cfg = dsapp_config()) {
  con <- dsapp_db(cfg)
  uid <- as.integer(sub$user_id)
  kws <- dsapp_lit_keywords(sub$keywords)
  if (!length(kws)) return(list(ok = FALSE, msg = "订阅里没有关键词",
                                session = NA_character_))

  # ---- 该账号的模型配置 ----
  s <- tryCatch(dsapp_settings_get(uid, con = con), error = function(e) list())
  if (!nzchar(as.character(s$vendor %||% "")[1])) {
    return(list(ok = FALSE,
                msg = "这个账号没有配模型服务，定时速递没法跑",
                session = NA_character_))
  }

  # ---- 建会话 + 塞提示词 ----
  ttl <- sprintf("文献速递：%s", paste(kws, collapse = "、"))
  sid <- db_session_create(title = substr(ttl, 1L, 40L), user_id = uid,
                           con = con)

  pr <- dsapp_lit_prompt(
    kws,
    n_read = sub$n_read %||% 3L, n_skim = sub$n_skim %||% 5L,
    years = {
      yf <- suppressWarnings(as.integer(sub$year_from)[1])
      yt <- suppressWarnings(as.integer(sub$year_to)[1])
      if (is.na(yf) && is.na(yt)) NULL
      else c(if (is.na(yf)) NA_integer_ else yf,
             if (is.na(yt)) NA_integer_ else yt)
    },
    extra = as.character(sub$extra %||% "")[1])
  if (!nzchar(pr)) {
    return(list(ok = FALSE, msg = "提示词是空的", session = sid))
  }

  # 定时任务的提示词前面加一句"这是自动跑的" —— 模型无从知道这件事，
  # 而它会影响模型怎么安排节奏（比如要不要在中途问用户问题：问了也没人答）。
  pr <- paste0(
    "【本次是定时订阅自动发起的检索，没有任何人正在看着这个对话。",
    "不要向用户提问、不要等待确认，按下面的要求一路做完，",
    "最后把 `文献速递.md` 写好。】\n\n", pr)

  db_message_add(sid, "user", pr, con = con)

  # 技能：默认挂的 + 订阅里选的，**并集**。
  # ⚠️ 用并集不用覆盖，理由和 mod_chat 那条一样：seed 挂的是用户的默认技能
  #    （比如他自己的教程规则），覆盖掉等于替他把默认技能摘了。
  try(dsapp_session_skills_seed(sid, uid, con = con), silent = TRUE)
  ids <- dsapp_lit_skills_parse(sub$skills)
  if (length(ids)) {
    cur <- tryCatch(dsapp_session_skills(sid, con = con),
                    error = function(e) integer(0))
    try(dsapp_session_skills_set(sid, union(as.integer(cur), ids), uid,
                                 con = con), silent = TRUE)
  }

  # ---- 起后台循环 ----
  ok <- dsapp_detach_start(
    sid, user_id = uid,
    target = list(kind = "server", env = "system"),
    max_iter = DSAPP_AGENT_MAX_ITER,
    wall_limit = DSAPP_LIT_RUN_WALL,
    # ★ V15.5 item 6：ctx_limit = 跟随模型（定时订阅没有"用户填的数"，
    #   它跑在没人看着的时候，用模型自己的窗口最合理）。
    params = list(vendor = s$vendor, model = s$model, base_url = s$base_url,
                  temperature = 0.3, ctx_limit = DSAPP_CTX_FOLLOW),
    scene = "agent", resume = NULL, mode = "full",
    # ★ 定时任务不是"页面关了"，文案要分开（见 dsapp_detach_start 的 scene 参数）
    origin = "schedule", cfg = cfg)

  if (!isTRUE(ok)) {
    return(list(ok = FALSE, msg = "后台循环没起来（可能库里已经有一条在跑）",
                session = sid))
  }

  # ---- 等它收尾 ----
  # ⚠️ 判据是**离开 running**，不是"变成 done"：stopped / orphan / error
  #    同样是收尾，而那几种恰恰是最需要报出来的。
  deadline <- Sys.time() + DSAPP_LIT_RUN_WALL + 120
  repeat {
    Sys.sleep(3)
    r <- dsapp_arun_get(sid, cfg)
    st <- as.character(r$state %||% "")
    if (!identical(st, "running")) break
    if (Sys.time() > deadline) break
  }
  st <- as.character((dsapp_arun_get(sid, cfg))$state %||% "timeout")

  # ---- 找产出，发邮件 ----
  wd <- dsapp_ws_dir(sid, cfg = cfg, create = FALSE)
  md <- NULL
  if (!is.null(wd) && dir.exists(wd)) {
    fs <- list.files(wd, pattern = "^文献速递.*\\.md$", full.names = TRUE)
    if (length(fs)) {
      fi <- file.info(fs)
      md <- fs[which.max(fi$mtime)]
    }
  }

  # ★ 用户选的是「跑完发邮件」，并且**失败也要发**（不然没人知道它失败了）。
  #   所以这里分两条路，但**都发**。
  if (!is.null(md)) {
    q <- dsapp_lit_mail_queue(
      uid, md, cfg = cfg, con = con, kind = "lit_sched",
      # 去重键带上"这一轮本该跑的时刻"，同一条订阅的不同轮次互不干扰，
      # 而同一轮被并发触发时只会入队一次。
      ref = sprintf("lit:%s:%s", sub$id %||% "?", sub$next_at %||% ""),
      note = if (identical(st, "done")) ""
             else sprintf("（这一轮的状态是「%s」，产出可能不完整。）", st))
    if (!isTRUE(q$ok)) {
      return(list(ok = FALSE, session = sid,
                  msg = sprintf("跑完了但没发出去：%s", q$msg)))
    }
  } else {
    # 没有产出 —— 发一封"失败"的信，而不是安静地什么都不做。
    u <- tryCatch(dsapp_user_by_id(uid, con = con), error = function(e) NULL)
    if (!is.null(u) && nzchar(as.character(u$email %||% "")[1])) {
      dsapp_mail_enqueue(
        to = as.character(u$email)[1],
        subject = sprintf("文献速递失败 · %s", paste(kws, collapse = "、")),
        body_md = sprintf(paste0(
          "这一轮的定时检索没有产出 `文献速递.md`。\n\n",
          "- 订阅：%s\n- 关键词：%s\n- 结束状态：%s\n- 对话：%s\n\n",
          "可以到「言出法随」里打开这个对话看看卡在哪一步。"),
          sub$title %||% "", paste(kws, collapse = "、"), st, sid),
        kind = "lit_sched", user_id = uid,
        ref = sprintf("litfail:%s:%s", sub$id %||% "?", sub$next_at %||% ""),
        cfg = cfg, con = con)
    }
    return(list(ok = FALSE, session = sid,
                msg = sprintf("跑完了但没有产出（状态 %s），已发失败提醒", st)))
  }

  if (!identical(st, "done")) {
    return(list(ok = FALSE, session = sid,
                msg = sprintf("速递发了，但结束状态是 %s", st)))
  }
  list(ok = TRUE, msg = "", session = sid)
}
