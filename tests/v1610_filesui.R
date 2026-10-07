#!/usr/bin/env Rscript
# =============================================================================
# Test_V16.10 端到端：两个文件展示收口 + 跨根一键打包
# =============================================================================
#     cd /data3/biomamba/analysis/DS_App
#     Rscript --no-environ tests/v1610_filesui.R .
#
# ── 要回答的问题 ─────────────────────────────────────────────────────────────
#
# 用户原话：「言出法随的文件页面和真正的文件管理页面文件不同步，那意味着你写了
#           两套文件展示系统，这是大大的浪费，请同步，并且支持在演出法随的文件
#           展示中一键打包下载」。
#
# 侦察的结论是**数据层本来就只有一套**（两个页面都调 dsapp_files_list()），
# 真正漂的是展示层的三处（目录怎么标 / 文件用什么图标 / 目录的大小），
# 加上"对话页那张卡片只能一个个下"。所以这份测试盯的是两件事：
#
#   * A1/A2 —— 收口真的收住了、坐标真的自洽了；
#   * A3–A7 —— 跨根打包**真的把两个根的东西都装进去了**。
#
# ★★ A2 与 A4 是整份里唯一有分量的两条：
#    · A2 在改之前**是红的**（实测 file.exists(file.path(root, rel)) = FALSE，
#      见下面那段说明）—— 一条改前改后都绿的断言证明不了任何事；
#    · A4 用 zip_list() 验**两组条目都在**，而不是"文件存在且不为 0 字节"
#      —— 一个只装了第一组的包完全满足后者。
#    A7 是 A4 的反例对照：同一条判据喂给一个坏掉的 plan 必须红。本仓有账：
#    「一个不改变行为的变异证明的是零，却长得像探针很强」。
#
# ── 三个坑，照旧 ────────────────────────────────────────────────────────────
#
# ⚠️⚠️ 数据根目录**必须**先指到临时目录再 source，而且整份脚本**必须用
#    `Rscript --no-environ` 跑**：仓库根的 .Renviron 把 DSAPP_DATA_ROOT 指着
#    生产库，而 Rscript 会读 **cwd** 的 .Renviron 并**盖掉**继承的环境变量
#    —— 只设环境变量是**不隔离**的（本仓为此在生产库里种过东西）。
# ⚠️ 一条出网请求都没有。这一份只在本机读写临时目录。
# ⚠️ 断言里**不写上限常数的字面量**：从 globalenv 里读 DSAPP_ZIP_MAX。
#    本仓有账：改常数漏改断言，红的那条报的错指向完全无关的地方。
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
sect <- function(x) say("\n\033[36m== %s ==\033[0m", x)

# ---- 先把数据根挪走，再 source ---------------------------------------------
tmp <- tempfile("dsapp_filesui_")
dir.create(tmp, recursive = TRUE)
Sys.setenv(DSAPP_DATA_ROOT = tmp)

for (f in list.files(file.path(app_dir, "R"), full.names = TRUE)) {
  source(f, local = globalenv())
}

cfg0 <- dsapp_config()
# ⚠️ 兜底自查：source 之后配置里那个 data_root 必须还在 /tmp 里。
#    这一条要是红的，**立刻停下** —— 下面每一次写盘都会落在生产目录上。
if (!startsWith(cfg0$data_root, "/tmp/")) {
  stop(sprintf("拒绝对着非 /tmp 的 data_root 跑：%s", cfg0$data_root))
}

# ---- 夹具 -------------------------------------------------------------------
stamp <- as.integer(Sys.time())
mail  <- sprintf("filesui%d@example.org", stamp)
reg <- dsapp_user_create("打包测试", mail, sprintf("139%08d", stamp %% 1e8), "测试",
                         password = "test-only-1234", password2 = "test-only-1234")
if (!isTRUE(reg$ok)) stop(reg$msg)
con <- dsapp_db(cfg0)
uid <- as.integer(dsapp_user_by_email(mail, con = con)$id)
sid <- db_session_create("打包与展示测试会话", user_id = uid, con = con)
cfg <- dsapp_config_user(uid, cfg0)

# 文件管理区里本对话的那个文件夹
fd_rel <- dsapp_sync_dir(sid, cfg)
fd_abs <- file.path(cfg$files_dir, fd_rel)
dir.create(file.path(fd_abs, "sub"), recursive = TRUE, showWarnings = FALSE)
writeLines("aaa", file.path(fd_abs, "a.txt"))            # 3 B
writeLines("bbbb", file.path(fd_abs, "sub", "b.txt"))    # 4 B

# 工作区
wd <- dsapp_ws_dir(sid, cfg, create = TRUE)
writeLines("ccccc", file.path(wd, "ws1.txt"))            # 5 B
dir.create(file.path(wd, "out"), showWarnings = FALSE)
writeLines("dddddd", file.path(wd, "out", "ws2.txt"))    # 6 B

# 工作区子目录里的**软链**：指向文件管理区里的只读输入。
# 这一条是 V16.10 修的那件事 —— 以前目录是整条丢给 zip 的，zip 跟随软链，
# 于是"只读输入不进产物包"那条设计**只在顶层成立**。
link_from <- file.path(wd, "out", "readonly_link.txt")
linked <- tryCatch(file.symlink(file.path(fd_abs, "a.txt"), link_from),
                   warning = function(w) FALSE, error = function(e) FALSE)
has_link <- isTRUE(dsapp_is_link(link_from))

ZIPMAX <- get("DSAPP_ZIP_MAX", envir = globalenv())
ZIPBG  <- get("DSAPP_ZIP_BG_MAX", envir = globalenv())

ref_files <- function(rel) dsapp_art_files_ref(file.path(fd_rel, rel))

# =============================================================================
sect("A1  展示字段收口：目录/文件各怎么标，只有一处说了算")
# =============================================================================
d <- dsapp_files_list(cfg, fd_rel)
d <- dsapp_files_order(d)
r <- dsapp_files_rows(d)

chk("A1.1 原有列一个不少（rel/size_h/mtime 是 DT 和行号绑定的依据）",
    all(c("name", "rel", "is_dir", "size", "size_h", "mtime", "kind") %in% names(r)),
    paste(names(r), collapse = ","))
chk("A1.2 追加且只追加 icon/mark/action/dt_name 四列",
    all(sort(setdiff(names(r), names(d))) == sort(c("icon", "mark", "action", "dt_name"))),
    paste(setdiff(names(r), names(d)), collapse = ","))
chk("A1.3 行数、行序一个没动（显示的行 == 数据框第 i 行，这是所有按行号取数的前提）",
    nrow(r) == nrow(d) && identical(r$name, d$name))

dir_i  <- which(r$is_dir); file_i <- which(!r$is_dir)
chk("A1.4 目录 = folder 图标 + 「文件夹」徽标 + open",
    length(dir_i) > 0 &&
      all(r$icon[dir_i] == "folder") && all(r$mark[dir_i] == "文件夹") &&
      all(r$action[dir_i] == "open"),
    paste(r$icon[dir_i], r$mark[dir_i], r$action[dir_i], collapse = " | "))
chk("A1.5 文件 = file 图标 + 没有徽标 + preview",
    length(file_i) > 0 &&
      all(r$icon[file_i] == "file") && all(is.na(r$mark[file_i])) &&
      all(r$action[file_i] == "preview"),
    paste(r$icon[file_i], r$mark[file_i], r$action[file_i], collapse = " | "))
# ⚠️ 这里比的是**规则**，不是把 📁 再抄一遍 —— 抄一遍就等于有了第二份定义，
#    而这份测试要证明的恰恰是"只有一份定义"。
chk("A1.6 DT 那一列（纯文本，塞不进 <i>）的名字和 mark 同源",
    all(r$dt_name[dir_i] == paste0("\U0001F4C1 ", r$name[dir_i])) &&
      all(r$dt_name[file_i] == r$name[file_i]),
    paste(r$dt_name, collapse = " | "))
chk("A1.7 目录的体积写「—」（文件区那支本来就对，所以这条只是把现状钉住）",
    all(r$size_h[dir_i] == "—"), paste(r$size_h[dir_i], collapse = " | "))
# ★★ A1.7b：真正要挡的是**工作区那一支**。
#   `dsapp_ws_artifacts()` 给目录的是**真实字节数**（`20 B`），而文件区那支给
#   的是 `—`。两边合并到对话页同一张卡片上之后，用户看到的是"同样是文件夹，
#   一行写 20 B、一行写 —"，分不出哪个才算数 —— 这正是用户报的"两套展示
#   系统"里最后剩下的一处。
#   ★ 这条是**浏览器探针抓出来的**（`tests/ui_v1610` 里"目录那一行写 —"
#     红在 `results 20 B 文件夹` 上）：自检只能验"函数写好了没"，验不到
#     "两个来源合起来长什么样"。
ws_like <- data.frame(
  name = c("out", "x.txt"), rel = c("out", "x.txt"),
  is_dir = c(TRUE, FALSE), size = c(20, 3),
  size_h = c("20 B", "3 B"),
  mtime = c("2026-10-07 11:00", "2026-10-07 11:00"),
  kind = c("dir", "file"), stringsAsFactors = FALSE)
wl <- dsapp_files_rows(ws_like)
chk("A1.7b ★★ 工作区那支的目录体积也被改写成「—」（不改就是两页两个数）",
    identical(wl$size_h, c("—", "3 B")), paste(wl$size_h, collapse = " | "))
chk("A1.7c ★ 文件那一格一个字不动（兜底别把文件也一起改了）",
    identical(wl$size_h[2], "3 B"))

# 0 行的路：文件区是空的（新对话）—— 少一列就是"整张卡片渲染不出来"
e <- dsapp_files_rows(dsapp_files_empty())
chk("A1.8 空表也带齐四列（0 行的对话是最常见的状态）",
    nrow(e) == 0 && all(c("icon", "mark", "action", "dt_name") %in% names(e)),
    paste(names(e), collapse = ","))
# 手搓夹具（只有 name/is_dir）——dsapp_files_order() 的注释里记着同一件事：
# 调用方不止 dsapp_files_list()，少一列不能抛 "argument lengths differ"
f <- data.frame(name = c("x", "y"), is_dir = c(TRUE, FALSE), stringsAsFactors = FALSE)
fr <- tryCatch(dsapp_files_rows(f), error = function(er) er)
chk("A1.9 缺列的调用方不炸（退化成文件，不抛 argument lengths differ）",
    !inherits(fr, "error") && identical(fr$icon, c("folder", "file")),
    if (inherits(fr, "error")) conditionMessage(fr) else "")
chk("A1.10 幂等：连过两遍不会多出 icon.1 之类的列",
    identical(names(dsapp_files_rows(r)), names(r)))

# =============================================================================
sect("A2  产物坐标 → (root, rel) 必须自洽")
# =============================================================================
# ★★ 这一条**改之前是红的**。实测（2026-10-07，改前）：
#      coord = files:<对话文件夹>/nsclc_data/LUAD_clinicalMatrix.tsv
#      root  = …/data/files/u1/<对话文件夹>
#      rel   = <对话文件夹>/nsclc_data/LUAD_clinicalMatrix.tsv   ← 相对 files_dir
#      file.exists(file.path(root, rel))          → FALSE
#      file.exists(file.path(cfg$files_dir, rel)) → TRUE
#    `dsapp_dl_plan()` 的 @param rel 明写「path 相对 root 的路径」，所以违反
#    契约的是这一边。可达路径是"文件区里的 .md 且有本地依赖"（那种才走
#    kind="zip"），而 dsapp_art_dl 的 content() **不看返回值** ⇒ 用户拿到
#    一个缺件的包，界面一声不吭。
for (sub in c("a.txt", "sub/b.txt", "sub")) {
  rr <- dsapp_art_root_rel(ref_files(sub), sid, cfg)
  ok <- !is.null(rr$root) && !is.null(rr$rel) &&
        file.exists(file.path(rr$root, rr$rel))
  chk(sprintf("A2.1 files:%-10s → file.path(root, rel) 真的落在盘上", sub), ok,
      sprintf("root=%s rel=%s", rr$root %||% "NULL", rr$rel %||% "NULL"))
}
# 坐标就是"对话文件夹本身"那一支（length(parts) == 1，root = files_dir）
rr0 <- dsapp_art_root_rel(dsapp_art_files_ref(fd_rel), sid, cfg)
chk("A2.2 坐标是对话文件夹本身时也自洽（那一支本来是对的，别被一起改坏）",
    identical(rr0$rel, fd_rel) && dir.exists(file.path(rr0$root, rr0$rel)),
    sprintf("root=%s rel=%s", rr0$root %||% "NULL", rr0$rel %||% "NULL"))
# 工作区那一支不能被误伤
rrw <- dsapp_art_root_rel("out/ws2.txt", sid, cfg)
chk("A2.3 工作区坐标原样透传（rel 不做任何剥离）",
    identical(rrw$rel, "out/ws2.txt") && file.exists(file.path(rrw$root, rrw$rel)),
    sprintf("root=%s rel=%s", rrw$root %||% "NULL", rrw$rel %||% "NULL"))
# 和另一个入口说的是同一件事
# ⚠️ 这里要**重新算**一次 rr：上面那个 for 循环跑完之后 rr 停在最后一个 sub
#    （"sub"），直接拿来用比的是"目录 vs 文件"—— 一条永远红的断言。
rr_b <- dsapp_art_root_rel(ref_files("sub/b.txt"), sid, cfg)
p1 <- dsapp_art_path(ref_files("sub/b.txt"), sid, cfg)
chk("A2.4 和 dsapp_art_path() 指的是同一个文件",
    !is.null(p1) && !is.null(rr_b$root) &&
      identical(normalizePath(p1),
                normalizePath(file.path(rr_b$root, rr_b$rel))),
    sprintf("%s vs %s", p1 %||% "NULL", file.path(rr_b$root %||% "?", rr_b$rel %||% "?")))

# =============================================================================
sect("A3  跨根盘点：两个根分别成组，预算跨组累计")
# =============================================================================
coords <- c(ref_files("a.txt"), ref_files("sub/b.txt"), "ws1.txt", "out/ws2.txt")
mp <- dsapp_zip_plan_multi(coords, sid, cfg)
chk("A3.1 ok", isTRUE(mp$ok), mp$msg %||% "")
chk("A3.2 分成两组（文件区 / 工作区）", length(mp$groups) == 2L,
    sprintf("groups=%d", length(mp$groups)))
chk("A3.3 组的顺序 = 坐标里首次出现的顺序（先出现的组赢那条规则靠它）",
    length(mp$groups) == 2L && identical(mp$groups[[1]]$root, fd_abs),
    if (length(mp$groups)) mp$groups[[1]]$root else "")
chk("A3.4 总 bytes = 各组之和（不是某一组）",
    isTRUE(all.equal(mp$bytes, sum(vapply(mp$groups, function(g) g$bytes, numeric(1))))),
    sprintf("%s vs %s", mp$bytes,
            sum(vapply(mp$groups, function(g) g$bytes, numeric(1)))))
chk("A3.5 n = 各组条目数之和", mp$n == 4, sprintf("n=%s", mp$n))
chk("A3.6 rel 都是相对各自 root 的（没有一个是绝对路径）",
    all(!grepl("^/", unlist(lapply(mp$groups, function(g) g$rels)))))
# ⚠️ 预算必须是**跨组累计**的：三个各 0.9 倍上限的组，合起来 2.7 倍，
#    逐组判的话三组全过 —— 而主 R 进程照样被堵死。这里把预算压到只够一组。
mp_small <- dsapp_zip_plan_multi(coords, sid, cfg, max_bytes = 4)
chk("A3.7 预算跨组累计（压到 4 B 时整单拒绝）", !isTRUE(mp_small$ok),
    sprintf("ok=%s", isTRUE(mp_small$ok)))
chk("A3.8 拒绝时说得出来（不是 stale 那种「让用户刷新」的空话）",
    isTRUE(mp_small$stale == FALSE) && nzchar(mp_small$msg %||% ""),
    sprintf("stale=%s msg=%s", mp_small$stale, mp_small$msg %||% ""))

# =============================================================================
sect("A4  真的打出来：zip_list() 里**两组条目都在**")
# =============================================================================
dst <- file.path(tmp, "multi.zip")
wr <- dsapp_zip_write_multi(dst, mp)
chk("A4.1 打包返回 ok", isTRUE(wr$ok), wr$msg %||% "")
chk("A4.2 包真的落在盘上且不为空",
    file.exists(dst) && !is.na(file.size(dst)) && file.size(dst) > 0,
    sprintf("size=%s", if (file.exists(dst)) file.size(dst) else "不存在"))

# ★★ 判据是**条目的路径**，不是"文件存在且 > 0 字节" —— 一个只装了第一组
#    （文件管理区那 2 个）的包完全满足后者。`zip::zip_append` 的 mode 默认是
#    "mirror"（match.arg 取第一个），mirror / cherry-pick 的差别正好落在
#    条目的前缀上，所以这里必须看路径。
entries <- tryCatch(zip::zip_list(dst)$filename, error = function(e) character(0))
chk("A4.3 包读得出来、条目不空", length(entries) > 0,
    sprintf("%d 条", length(entries)))
want <- c("a.txt", "sub/b.txt", "ws1.txt", "out/ws2.txt")
miss <- setdiff(want, entries)
chk("A4.4 ★ 两个根的条目**都在**包里", length(miss) == 0,
    sprintf("缺：%s ｜ 包里有：%s", paste(miss, collapse = ","),
            paste(entries, collapse = ",")))
chk("A4.5 条目名是相对路径（root 逐组生效了，没退化成绝对路径）",
    all(!grepl("^/", entries)) && !any(grepl(tmp, entries, fixed = TRUE)),
    paste(entries, collapse = " | "))

# =============================================================================
sect("A5  子目录里的软链不进包（V16.10 修的那件事）")
# =============================================================================
if (!has_link) {
  chk("A5.0 夹具：造出一个指向文件管理区的软链", FALSE,
      sprintf("file.symlink 失败：%s", link_from))
} else {
  chk("A5.0 夹具：软链真的建出来了", TRUE)
  chk("A5.1 顶层软链不进 plan（老行为，别被改坏）",
      !isTRUE(dsapp_zip_plan(c("out/readonly_link.txt"), wd)$ok))
  # ★ 这条是重点：**目录**里的软链。以前目录整条丢给 zip，zip 跟随软链，
  #   于是文件管理区里那份只读输入被复制进包 —— 不报错、也没有任何提示。
  pin <- dsapp_zip_plan(c("out"), wd)
  chk("A5.2 选中目录时，目录里的软链不在 rels 里",
      isTRUE(pin$ok) && !any(grepl("readonly_link", pin$rels)),
      paste(pin$rels, collapse = " | "))
  chk("A5.3 目录里其余的真文件仍然在（收窄了，没把整个目录一起丢掉）",
      isTRUE(pin$ok) && "out/ws2.txt" %in% pin$rels,
      paste(pin$rels, collapse = " | "))
  # ⚠️ 期望值从**盘上**读，不写字面量：`writeLines("dddddd")` 写的是
  #    "dddddd\n" = 7 B 而不是注释里那个 6（第一版就是照注释写的，红了一条
  #    和"软链被跳过"毫无关系的断言）。判据是"等于真文件的体积"，更硬的
  #    那条是"不等于真文件 + 软链指向的那份"—— 后者才是这条测试的要害。
  ws2_sz <- file.size(file.path(wd, "out", "ws2.txt"))
  tgt_sz <- file.size(file.path(fd_abs, "a.txt"))
  chk("A5.4 体积 = 目录里真文件之和（不含被跳过的软链指向的那份）",
      isTRUE(all.equal(as.numeric(pin$bytes), as.numeric(ws2_sz))) &&
        !isTRUE(all.equal(as.numeric(pin$bytes), as.numeric(ws2_sz + tgt_sz))),
      sprintf("bytes=%s，真文件=%s，加上软链目标就是 %s",
              pin$bytes, ws2_sz, ws2_sz + tgt_sz))
  dst2 <- file.path(tmp, "dironly.zip")
  dsapp_zip_write_multi(dst2, dsapp_zip_plan_multi("out", sid, cfg))
  e2 <- tryCatch(zip::zip_list(dst2)$filename, error = function(e) character(0))
  chk("A5.5 盘上核一遍：包里真的没有那条软链（不是只断言了 plan）",
      !any(grepl("readonly_link", e2)) && any(grepl("ws2.txt", e2)),
      paste(e2, collapse = " | "))
}
# 选一个**里面全是只读输入**的目录：要说得出人话，不能掉进"刷新一下页面"
only_links <- file.path(tmp, "onlylinks")
if (dir.exists(only_links)) unlink(only_links, recursive = TRUE)
dir.create(only_links)
invisible(file.symlink(file.path(fd_abs, "a.txt"), file.path(only_links, "l1.txt")))
invisible(file.symlink(file.path(fd_abs, "sub", "b.txt"), file.path(only_links, "l2.txt")))
pl <- dsapp_zip_plan("onlylinks", tmp)
chk("A5.6 目录里的东西全被跳过时：不是 stale（刷新一百遍也没用，那是设计如此），而是人话",
    !isTRUE(pl$ok) && isFALSE(pl$stale) && nzchar(pl$msg %||% ""),
    sprintf("ok=%s stale=%s msg=%s", pl$ok, pl$stale, pl$msg %||% ""))
chk("A5.7 而且报得出被跳过的是「只读输入」这件事（不是笼统的「打不了包」）",
    grepl("只读输入", pl$msg %||% "", fixed = TRUE), pl$msg %||% "")

# =============================================================================
sect("A6  上限参数化没改默认：不带 max_bytes 时行为一个字没变")
# =============================================================================
# 常数的**真实值**，断言里一律用它，不写字面量（本仓有账：改常数漏改断言，
# 红的那条报的错指向完全无关的地方）。
chk("A6.1 dsapp_zip_plan 的 max_bytes 默认值**就是** DSAPP_ZIP_MAX 本身",
    identical(eval(formals(dsapp_zip_plan)$max_bytes), ZIPMAX),
    sprintf("%s vs %s", format(eval(formals(dsapp_zip_plan)$max_bytes)), format(ZIPMAX)))
chk("A6.2 dsapp_zip_plan_multi 的默认值也是它",
    identical(eval(formals(dsapp_zip_plan_multi)$max_bytes), ZIPMAX))
chk("A6.3 后台那道硬顶比同步那道大（不然「转后台」这个设计不成立）",
    ZIPBG > ZIPMAX, sprintf("%s vs %s", format(ZIPBG), format(ZIPMAX)))

# 真造一个超限的：稀疏文件，apparent size = 上限 + 1，实际只占一个块。
# ⚠️ 不这么造的话，"造一个 2 GB 的文件"就是真写 2 GB —— 测试会因为磁盘红。
big <- file.path(wd, "big.bin")
c2 <- file(big, "wb"); seek(c2, ZIPMAX + 1); writeBin(as.raw(0L), c2); close(c2)
p_over <- dsapp_zip_plan("big.bin", wd)
chk("A6.4 不带 max_bytes 时，超过 DSAPP_ZIP_MAX 仍然拒绝（老行为）",
    !isTRUE(p_over$ok), sprintf("ok=%s", isTRUE(p_over$ok)))
chk("A6.5 拒绝的理由里报的是**真实的上限值**（从源头读的那个）",
    grepl(dsapp_fmt_bytes(ZIPMAX), p_over$msg %||% "", fixed = TRUE),
    p_over$msg %||% "")
p_bg <- dsapp_zip_plan("big.bin", wd, max_bytes = ZIPBG)
chk("A6.6 把预算放大到后台那道顶，同一个文件就过得去了（「转后台」确实有路）",
    isTRUE(p_bg$ok), p_bg$msg %||% "")
unlink(big)

# =============================================================================
sect("A7  反例对照：把 A4 那条判据喂给一个坏掉的 plan，必须红")
# =============================================================================
# 一条永远绿的断言和一条永远红的同样没用。这里不是"再断言一次 A4"，
# 而是**证明 A4 的判据会红** —— 用一个第二组 root 不存在的 plan。
same_check <- function(d, want) length(setdiff(want, tryCatch(
  zip::zip_list(d)$filename, error = function(e) character(0)))) == 0L

broken <- list(ok = TRUE, groups = list(
  list(root = fd_abs, rels = c("a.txt"), n = 1L, bytes = 3),
  list(root = file.path(tmp, "no_such_root"), rels = c("ghost.txt"),
       n = 1L, bytes = 1)))
dst3 <- file.path(tmp, "broken.zip")
if (file.exists(dst3)) unlink(dst3)
rb <- tryCatch(dsapp_zip_write_multi(dst3, broken),
               error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
# 坏的这一组打不进去 → 判据要么报"缺 ghost.txt"，要么整个 tryCatch 炸掉，
# 两条路都算"判据红了"。
red <- !isTRUE(rb$ok) || !same_check(dst3, c("a.txt", "ghost.txt"))
chk("A7.1 第二组 root 不存在时，同一条判据**会红**（证明 A4 不是白送的绿）",
    red, sprintf("write ok=%s msg=%s", isTRUE(rb$ok), rb$msg %||% ""))
chk("A7.2 而且不是靠「悄悄少打一组」混过去的（要么报错、要么判据抓到缺件）",
    !isTRUE(rb$ok) || !same_check(dst3, c("a.txt", "ghost.txt")))

# =============================================================================
sect("A8  主进程 ↔ 子进程那道缝：dsapp_bg_start(\"dsapp_zip_build\", ...)")
# =============================================================================
# ★ 这一段验的是**调用约定**，不是 zip 本身（zip 在 A4/A5 已经验过）。
#   缝这一侧最容易错、也最难发现的正是调用约定：`dsapp_bg_start()` 是
#   `do.call(fn, args)` 调的，形参名对不上就是子进程里一句
#   "unused argument" / "argument ... is missing"，而**主进程**这边只看到
#   「子进程意外退出」—— 一句和真正原因毫无关系的话。
#   2026-10-07 这一版就是把 `dsapp_zip_build(args)` 改成了
#   `dsapp_zip_build(groups, dst)`：写成 `function(args)` 的话调用点得写成
#   `args = list(args = list(...))`，那种一层套一层迟早有人漏。
#
# ⚠️⚠️ 这一段会**真的起一个子进程**。子进程 source 的是 `cfg$app_dir` 下的
#    R/*.R（真仓库），而它的 cwd 是本测试进程的 cwd = 仓库根 ⇒ 它会读到仓库
#    根那份 `.Renviron`（指着**生产** data_root）。之所以安全，是因为
#    `dsapp_zip_build()` 那条路上**一次都不调 `dsapp_config()`/`dsapp_db()`**，
#    而且 R/*.R 在 source 时没有任何顶层副作用（2026-10-07 逐个 parse 核过）。
#    A8.5 把这个前提**本身**也钉住 —— 它一变，这一段就从"安全"变成
#    "子进程拿着生产 data_root 跑"，而这条路上没有任何东西会提醒你。
# ⚠️ 扫的是**函数体**，不是整个函数 —— `dsapp_zip_plan_multi(coords, sid,
#    cfg = dsapp_config())` 那个默认值就在形参表里，而 R 的默认值是**惰性**的：
#    调用方给了 cfg（子进程那条路根本走不到这里，它收的是**数据**不是坐标）
#    它就一次都不求值。把形参表也扫进去的话，这条断言会为一件从未发生的事
#    恒红 —— 一条永远红的断言和一条永远绿的同样没用。
bg_dep <- function(f) paste(deparse(body(f)), collapse = "\n")
chain <- list(build = dsapp_zip_build, write = dsapp_zip_write_multi,
              expand = dsapp_zip_expand, plan = dsapp_zip_plan,
              multi = dsapp_zip_plan_multi)
touch_cfg <- vapply(chain, function(f)
  grepl("dsapp_config(", bg_dep(f), fixed = TRUE) ||
  grepl("dsapp_db(", bg_dep(f), fixed = TRUE), logical(1))
chk("A8.5 打包这一条链上没有任何一处读配置/连库（子进程安全的**前提**）",
    !any(touch_cfg),
    sprintf("命中：%s", paste(names(chain)[touch_cfg], collapse = ", ")))

if (!requireNamespace("callr", quietly = TRUE)) {
  chk("A8.0 夹具：callr 在场（dsapp_bg_start 靠它起子进程）", FALSE, "没装 callr")
} else {
  bd1 <- file.path(tmp, "bg1"); bd2 <- file.path(tmp, "bg2", "deep")
  dir.create(bd1, recursive = TRUE, showWarnings = FALSE)
  dir.create(bd2, recursive = TRUE, showWarnings = FALSE)
  writeLines("x", file.path(bd1, "x.txt"))
  writeLines("yy", file.path(bd2, "y.txt"))
  bg_groups <- list(list(root = file.path(tmp, "bg1"), rels = "x.txt",
                         n = 1L, bytes = 2),
                    list(root = file.path(tmp, "bg2"), rels = "deep/y.txt",
                         n = 1L, bytes = 3))
  bg_dst <- file.path(cfg$run_dir, "zipbuild-v1610test.zip")
  h <- tryCatch(dsapp_bg_start("dsapp_zip_build",
                               args = list(groups = bg_groups, dst = bg_dst),
                               cfg = cfg, tag = "zipbuild"),
                error = function(e) e)
  # ⚠️ 这一条红的时候先看 `logs_dir` 在不在：不在的话 processx 报的是
  #    「cannot start processx process '/usr/lib/R/bin/R' (system error 2)」
  #    —— 指着 R 解释器（它明明在），和真正的原因（日志目录不存在）差着
  #    十万八千里。V16.10 给 `dsapp_bg_start()` 补了一句 dir.create 兜住它，
  #    但"换个 data_root 起一次性实例"时会第一个撞上这里。
  chk("A8.0 子进程起得来", !inherits(h, "error"),
      if (inherits(h, "error")) conditionMessage(h) else "")
  if (!inherits(h, "error")) {
    r <- NULL
    for (i in 1:120) {
      r <- tryCatch(dsapp_bg_poll(h), error = function(e) NULL)
      if (isTRUE(r$done)) break
      Sys.sleep(0.25)
    }
    chk("A8.1 子进程跑完了、而且是成功", isTRUE(r$done) && isTRUE(r$ok),
        sprintf("done=%s ok=%s msg=%s", isTRUE(r$done), isTRUE(r$ok),
                r$msg %||% ""))
    chk("A8.2 返回值是 dsapp_zip_build 那份结构（形参名对上了才有它）",
        isTRUE(r$value$ok) && identical(as.integer(r$value$n), 2L),
        sprintf("value$ok=%s n=%s msg=%s", isTRUE(r$value$ok),
                r$value$n %||% "NULL", r$value$msg %||% ""))
    # ★ 判据是**条目**，不是"文件存在"：`n=2` 也可能是两个根都指到同一份
    #   文件上（root 传错时就是这样，而且不报错）。
    bg_entries <- tryCatch(zip::zip_list(bg_dst)$filename,
                           error = function(e) character(0))
    chk("A8.3 ★ 跨进程打出来的包里两个根的东西都在、路径也各自成立",
        all(c("x.txt", "deep/y.txt") %in% bg_entries),
        paste(bg_entries, collapse = " | "))
    try(unlink(bg_dst), silent = TRUE)
  }
}

# ---- 小结 -------------------------------------------------------------------
say("")
if (nfail > 0L) {
  say("\033[31m%d 条红 / %d 条绿\033[0m", nfail, NOK)
  quit(status = 1L)
}
say("\033[32m全部 %d 条绿\033[0m", NOK)
