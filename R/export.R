# =============================================================================
# 导出到本地电脑
# =============================================================================
# 「分析环境」三个选项里的第一个。
#
# ---- 为什么"在用户本地电脑上运行"不能真的由服务器代办 ----------------------
#
# 这是个浏览器应用，没有、也不可能有在访客电脑上执行代码的能力 ——
# 那正是浏览器沙箱要防的事。任何声称「一键在你电脑上跑」的实现，要么
# 是在服务器上跑（骗人），要么是让用户装一个常驻代理程序（远超本应用
# 的范围，也带来新的信任问题）。
#
# 所以这个选项**如实做成它本来的样子**：服务器把「可运行的一整套东西」
# 打包给你下载 —— 脚本、用到的数据、运行说明、依赖清单 —— 你在自己
# 电脑上解开就能跑。界面上的文案也是这么写的，不玩文字游戏。
#
# 好处是这套东西在本地是可复现的：依赖清单里有版本，别人拿到也能跑。
# =============================================================================

#' 找出代码里引用了哪些共享文件
#'
#' 用文件名做子串匹配。宁可多带上几个也不能漏 —— 漏了的话用户下载回去
#' 一跑就报「文件不存在」，而那时已经离开这个页面了，不好排查。
dsapp_referenced_files <- function(code, cfg = dsapp_config()) {
  files <- list.files(cfg$files_dir, all.files = FALSE, no.. = TRUE)
  files <- files[!dir.exists(file.path(cfg$files_dir, files))]
  if (!length(files)) return(character(0))
  hit <- vapply(files, function(f) grepl(f, code, fixed = TRUE), logical(1))
  files[hit]
}

#' 生成运行说明
dsapp_export_readme <- function(script_name, lang, files, env_name,
                                cfg = dsapp_config()) {
  run_cmd <- switch(lang,
    R      = sprintf("Rscript %s", script_name),
    Python = sprintf("python3 %s", script_name),
    Bash   = sprintf("bash %s", script_name),
    sprintf("Rscript %s", script_name)
  )

  deps <- if (!is.null(env_name) && nzchar(env_name) &&
              !identical(env_name, "system")) {
    pkgs <- dsapp_env_packages(env_name, cfg)
    if (length(pkgs)) {
      paste0(
        "本次分析在服务器上使用的是 conda 环境 **", env_name, "**，包含以下包：\n\n```\n",
        paste(pkgs, collapse = "\n"), "\n```\n\n",
        "下面这个 environment.yml 可以重建一个等价环境：\n\n",
        "```bash\nconda env create -f environment.yml\nconda activate dsapp_export\n```\n")
    } else {
      "本次分析使用系统环境。\n"
    }
  } else {
    paste0(
      "本次分析使用服务器上的**系统环境**。\n\n",
      "- R 版本：", R.version.string, "\n",
      "- 脚本里 `library()` 的包需要你在本地自行安装：",
      "`install.packages(\"包名\")` 或 `BiocManager::install(\"包名\")`\n")
  }

  file_list <- if (length(files)) {
    paste0(paste0("- `", files, "`"), collapse = "\n")
  } else {
    "（脚本没有引用文件管理区里的任何文件）"
  }

  paste0(
    "# Biomamba言出法随生信APP —— 本地运行包\n\n",
    "这个压缩包是从 Biomamba言出法随生信APP 导出的，",
    "目的是让你**在自己的电脑上**运行这段分析。\n",
    "服务器不会、也无法在你的电脑上执行代码 —— 所以这里给的是完整的一套东西，",
    "解开即可运行。\n\n",
    "## 怎么跑\n\n",
    "```bash\n", run_cmd, "\n```\n\n",
    "## 包里的东西\n\n",
    "- `", script_name, "` —— 分析脚本（本次要执行的代码）\n",
    file_list, "\n",
    "- `README.md` —— 本文件\n",
    "- `environment.yml` —— conda 环境定义（用于重建依赖）\n\n",
    "## 依赖说明\n\n",
    deps, "\n",
    "## 注意\n\n",
    "- 脚本里用的是**相对路径**（直接写文件名），所以请在解压后的目录里执行，",
    "不要 `cd` 到别处再跑。\n",
    "- 资源限额（内存、CPU 时间、运行时长）在服务器上是强制的，本地没有这个限制，",
    "但请注意本地机器的实际能力。\n",
    "- 如果脚本开头有 `set.seed()` / `random_state=`，结果是可复现的；",
    "没有的话每次跑出来会有细微差异。\n"
  )
}

#' 生成 environment.yml
dsapp_export_environment <- function(env_name, lang, cfg = dsapp_config()) {
  pkgs <- character(0)
  if (!is.null(env_name) && nzchar(env_name) && !identical(env_name, "system")) {
    all_pkgs <- dsapp_env_packages(env_name, cfg)
    # conda-meta 里混着一堆底层依赖（libgcc-ng 之类），全写进去没意义
    # 而且换平台就解不开。只留用户大概率显式装过的那些。
    noise <- c("^_", "^lib", "^python$", "^pip$", "^setuptools$", "^wheel$",
               "^tzdata$", "^ca-certificates$", "^openssl$", "^ncurses$",
               "^readline$", "^tk$", "^zlib$", "^xz$", "^bzip2$", "^sqlite$",
               "^ld_impl", "^certifi$", "^charset", "^packaging$")
    for (n in noise) all_pkgs <- all_pkgs[!grepl(n, all_pkgs)]
    pkgs <- all_pkgs
  }

  lines <- c(
    "name: dsapp_export",
    "channels:",
    "  - conda-forge",
    "  - bioconda",
    "dependencies:"
  )
  if (length(pkgs)) {
    lines <- c(lines, paste0("  - ", pkgs))
  } else {
    lines <- c(lines,
      "  # 服务器上没有记录到具体的 conda 包。",
      "  # 按脚本里的 library()/import 自己补：",
      "  # - r-base",
      "  # - bioconductor-deseq2",
      "  # - python=3.11",
      "  # - scanpy")
  }
  if (identical(lang, "Python") && !"python" %in% pkgs) {
    lines <- c(lines, "  - python=3.11")
  }

  paste(lines, collapse = "\n")
}

#' 打一个导出包
#'
#' 非阻塞（就是复制几个文件 + 打包，毫秒级），所以直接在 Shiny 进程里做。
#' 真正耗时的只有「文件管理区很大」这一种情况，那种时候会明显卡一下 ——
#' 所以只带上代码里引用到的文件，不是全量。
#'
#' @return list(ok, msg, file, name)
dsapp_export_bundle <- function(code, lang, env_name = "system",
                                cfg = dsapp_config(), label = NULL) {
  stage <- file.path(cfg$export_dir, paste0("stage-", dsapp_id("e")))
  if (!dir.create(stage, recursive = TRUE, showWarnings = FALSE)) {
    return(list(ok = FALSE, msg = "无法创建导出暂存目录"))
  }
  on.exit(unlink(stage, recursive = TRUE, force = TRUE), add = TRUE)

  script <- dsapp_write_script(code, lang, stage)
  script_name <- basename(script)

  # ---- 带上被引用的数据文件 ----
  files <- dsapp_referenced_files(code, cfg)
  copied <- character(0)
  skipped <- character(0)
  for (f in files) {
    src <- file.path(cfg$files_dir, f)
    # 超过 2GB 的不塞进压缩包：打出来用户也下不动，不如让他自己去
    # 文件页单独下载。界面上会提示少了哪些。
    if (file.info(src)$size > 2 * 1024^3) { skipped <- c(skipped, f); next }
    if (isTRUE(file.copy(src, file.path(stage, f), overwrite = TRUE))) {
      copied <- c(copied, f)
    } else {
      skipped <- c(skipped, f)
    }
  }

  writeLines(dsapp_export_readme(script_name, lang, copied, env_name, cfg),
             file.path(stage, "README.md"))
  writeLines(dsapp_export_environment(env_name, lang, cfg),
             file.path(stage, "environment.yml"))

  # ---- 打包 ----
  # 用 zip：Windows/macOS 双击就能解开，生信用户里 Windows 不少。
  stem <- dsapp_safe_name(label %||% sprintf("analysis-%s", format(Sys.time(), "%Y%m%d-%H%M%S")))
  zip_name <- sprintf("%s.zip", stem)
  zip_path <- file.path(cfg$export_dir, zip_name)
  unlink(zip_path)

  old <- setwd(stage)
  on.exit(setwd(old), add = TRUE)
  # zip 不在时的兜底在下面
  ok <- tryCatch({
    utils::zip(zip_path, files = list.files(".", all.files = FALSE, no.. = TRUE),
               flags = "-q -r")
    file.exists(zip_path)
  }, error = function(e) FALSE, warning = function(w) file.exists(zip_path))

  if (!isTRUE(ok)) {
    return(list(ok = FALSE, msg = paste0(
      "打包失败（服务器上可能没有 zip 命令）。\n",
      "可以让管理员装：sudo apt install zip")))
  }

  note <- ""
  if (length(skipped)) {
    note <- sprintf("\n\n⚠️ 以下文件超过 2GB 没有打进包里，请到「文件」页单独下载：%s",
                    paste(skipped, collapse = "、"))
  }

  list(ok = TRUE, file = zip_name, size = file.info(zip_path)$size,
       n_files = length(copied), note = note)
}

#' 清理旧的导出包
#'
#' 导出包是下载完就没用的东西，但没人会回来手动删。启动时清一遍，
#' 免得数据盘被慢慢啃掉。
dsapp_export_gc <- function(cfg = dsapp_config(), max_age_hours = 48,
                            max_total_mb = 2048) {
  d <- cfg$export_dir
  if (!dir.exists(d)) return(invisible(0))
  zips <- list.files(d, pattern = "\\.zip$", full.names = TRUE)
  if (!length(zips)) return(invisible(0))

  info <- file.info(zips)
  removed <- 0

  # 先按时间清
  old <- zips[difftime(Sys.time(), info$mtime, units = "hours") > max_age_hours]
  for (f in old) { unlink(f); removed <- removed + 1 }

  # 还是太大就按时间从旧到新继续删
  left <- setdiff(zips, old)
  if (length(left)) {
    li <- file.info(left)
    total_mb <- sum(li$size, na.rm = TRUE) / 1024^2
    if (total_mb > max_total_mb) {
      ord <- order(li$mtime)
      for (f in left[ord]) {
        if (total_mb <= max_total_mb) break
        total_mb <- total_mb - file.info(f)$size / 1024^2
        unlink(f); removed <- removed + 1
      }
    }
  }
  invisible(removed)
}
