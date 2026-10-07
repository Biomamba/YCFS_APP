#!/usr/bin/env bash
# =============================================================================
# 组装 macOS 免安装分发包（V16.6 item 5）
# =============================================================================
#
#   bash desktop/build_macos_bundle.sh [输出目录] [arm64|x86_64]
#
# 产出：<输出目录>/DS_App-macOS-<arch>-<版本>.zip
# 用户拿到之后：解压 → **双击 run_app.command**。不需要装 R，不需要装任何包。
#
# ---- 和 build_windows_bundle.sh 的关系 --------------------------------------
#
# 同一件事的两个平台版本，布局刻意保持**一模一样**（连变量名都一样），
# 因为 run_local.R 是靠 `--file=` 反推应用目录的，"平铺"这条要求两边共享。
# 改一边的时候请对着另一边看一遍。
#
# 但两边有**四处必须不同**，都是踩过的坑：
#   1. 归档格式：Windows 用 .zip（里面是 .zip 的 R 包），mac 用 .tgz；
#   2. 启动器：run_app.bat 必须 CRLF + 纯 ASCII，run_app.command 必须 LF
#      + 有可执行位（少了可执行位，双击报的是"没有合适的访问权限"）；
#   3. **符号链接**：mac 的 R 运行时里有 symlink（bin/R -> ../lib/libR.dylib
#      那一类）。zip 默认会把 symlink **解引用成普通文件**，解出来能占两倍
#      磁盘、而且以后更新 dylib 时两份会分家。必须 `zip -y`。
#   4. 编译产物是 .so 不是 .dll，而且**架构要对**（arm64 / x86_64 是两份
#      不同的 CRAN 仓库，拿错的表现是用户那边一 library() 报
#      "mach-o file, but is an incompatible architecture"）。
#
# ---- ⚠️⚠️ 我**没有 Mac**，所以这个 zip 是"组装正确"而不是"我跑过" --------
#
# 和 Windows 那份一样：组装本身不需要运行目标平台（R 运行时和 R 包都是
# 现成的二进制，全程只是下载 + 解压 + 换个目录放），所以**在 Linux 上就能
# 把它装出来**，本机也确实跑通过一遍（见 tests/ui_v166/README.md 的 item 5）。
# 但"解出来能不能跑"只有 Mac 上双击一次才知道 —— 见 desktop/README.md
# 末尾那张验收清单。
#
# ⚠️ 另外两件**只有 Mac 上才做得了**的事，别指望这个脚本：
#   · 签名 / 公证。不签名的话用户第一次打开会被 Gatekeeper 拦
#     （右键→打开 可以绕过，HOWTO-macOS.txt 写了）。要正式发布得有
#     Apple Developer 账号 + codesign + notarytool。
#   · universal（同时含 arm64 和 x86_64）的包。这里出的是**单架构**的，
#     要 universal 得把两个架构的包都下下来再 lipo，那是另一件事。
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/dsapp_build}"
ARCH="${2:-arm64}"
# ★ 4.4.2 -> 4.4.3：CRAN 的 macosx/big-sur-<arch>/contrib/4.4 里，最新的那批
#   包是用 R 4.4.3 编的（实测 arm64：31 个）。运行时低于它的话，用户那边
#   **每 library() 一个包就打一句** "was built under R version 4.4.3"。
RVER="${DSAPP_RUNTIME_RVER:-4.4.3}"
RMINOR="${RVER%.*}"                      # 4.4

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "!! 架构只能是 arm64 或 x86_64，收到：$ARCH" >&2; exit 1 ;;
esac

# ⚠️ 取版本号用 sed 而不是 `grep -oP`：**BSD grep 没有 -P**（那是 GNU 的
#    PCRE 扩展），而这个脚本十有八九是在一台 Mac 上跑的 —— 用了它，脚本会
#    在第二行就报 "grep: invalid option -- P"，而错误信息完全指不到版本号上。
VER="$(sed -n 's/.*DSAPP_VERSION[[:space:]]*<-[[:space:]]*"\([^"]*\)".*/\1/p' \
       "$REPO/R/config.R" | head -1)"
[ -n "$VER" ] || die "从 R/config.R 里读不出 DSAPP_VERSION —— 那一行的写法变了？"
NAME="DS_App-macOS-$ARCH-$VER"
STAGE="$OUT/$NAME"
DL="$OUT/dl"
RTGZ="$DL/portable-r-$RVER-macos-$ARCH.tar.gz"
URL="https://github.com/portable-r/portable-r-macos/releases/download/v$RVER/portable-r-$RVER-macos-$ARCH.tar.gz"

say() { printf '\033[36m==\033[0m %s\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$DL"
say "输出：$OUT/$NAME.zip（架构 ${ARCH}）"

# ---- 1. R 运行时 ------------------------------------------------------------
if [ ! -f "$RTGZ" ]; then
  say "下载 macOS 版 R ${RVER}（${ARCH}，约 82 MB，断了会续传）"
  # ⚠️ 和 Windows 那份同理：不用 R 的 download.file()，它默认 60 秒超时。
  curl -L --retry 5 -C - -o "$RTGZ" "$URL"
fi
# ⚠️ 下了一半的 tar.gz 也要能被发现。截断的包解到一半才报错，那时已经
#    建了一堆目录，看起来像"解压代码有问题"。
gzip -t "$RTGZ" 2>/dev/null || die "R 运行时压缩包不完整（${RTGZ}），删掉重跑"

say "解压 R 运行时"
rm -rf "$STAGE"
mkdir -p "$STAGE/runtime"
# ⚠️ 先解到临时目录再搬（和 Windows 那份同一个理由：解出来是
#    portable-r-<版本>-macos-<arch>/ 一层，我们要的是 runtime/R/）。
mkdir -p "$STAGE/.rtmp"
tar -xzf "$RTGZ" -C "$STAGE/.rtmp"
# ⚠️ 这里**不能**用 `find -printf '%h\n'`（Windows 那个脚本原来的写法）：-printf
#    是 GNU find 的扩展，BSD find（也就是 macOS 上那个）根本没有这个选项，
#    报的是 "find: -printf: unknown primary or operator"。
# ⚠️⚠️ 但也不能"找 Rscript、dirname 一层当 R 根"。tar 里同时有
#    `portable-r-*/Rscript`（顶层那个入口）和 `portable-r-*/bin/Rscript`，
#    而顶层那个**恰好排在前面**，所以 `find | head -1` 现在能命中顶层、
#    dirname 正好是 R 根 —— 这是**归档顺序给的运气**，不是我们判对了。
#    换个顺序（或者哪天顶层入口没了）就会把 bin/ 当成 R 根，脚本报
#    "没有 runtime/R/bin/Rscript"，看着像下载的包坏了。
#    判据换成**结构**：哪一层同时有 bin/Rscript 和 library/，哪一层才是 R 根。
root=""
for d in "$STAGE/.rtmp"/*/ "$STAGE/.rtmp"/*/*/; do
  [ -d "$d" ] || continue
  if [ -f "${d}bin/Rscript" ] && [ -d "${d}library" ]; then root="${d%/}"; break; fi
done
[ -n "$root" ] || die "找不到 R 根目录（要同时含 bin/Rscript 和 library/）—— portable-r 的结构变了？"
mv "$root" "$STAGE/runtime/R"
rm -rf "$STAGE/.rtmp"
ls "$STAGE/runtime/R/bin/Rscript" >/dev/null || die "没有 runtime/R/bin/Rscript"
[ -d "$STAGE/runtime/R/library" ] || die "便携版 R 里没有 library/ 目录，依赖包没处装"
# ⚠️ 可执行位是这一步的**核心产物**，不是附带效果。tar 一般会保留，但万一
#    这个 tar.gz 是用奇怪的方式重打的，Rscript 就变成 644 —— 双击启动器
#    时报的是"cannot execute"，而所有文件"都在"。
chmod +x "$STAGE/runtime/R/bin/Rscript" "$STAGE/runtime/R/bin/R" 2>/dev/null || true

# ---- 1b. fontconfig：把**绝对路径**的符号链接改成相对的 ----------------------
#
# ⚠️⚠️ 2026-10-07 发现，而且是**把打好的 zip 拆开逐条看**才看得见的：
#
#   portable R 的包里，runtime/R/fontconfig/fonts/conf.d/ 下有 17 条符号链接，
#   指向
#     /Library/Frameworks/R.framework/Resources/fontconfig/fontconfig/conf.avail/xxx.conf
#   —— 那是**打包机**上的路径（CI runner 刚装完 R）。用户的 Mac 上没装 R，
#   这 17 条**必然全断**，而且断了**不报错**：fontconfig 读不了的 conf 就当它
#   不存在、静默跳过。
#
#   丢的是 49-sansserif.conf / 40-nonlatin.conf / 45-latin.conf 这一批
#   **字族别名与回退**规则。失掉的具体后果我**没有实测**（手上没有一台没装 R 的
#   Mac），能确定的只有两件：① 这 17 条在用户机器上必断；② 断了之后随包发的
#   那份配置被**静默丢弃**、退回 fontconfig 编译进去的默认值。这个应用是中文的、
#   要出图，字体回退正是中文最容易踩的地方 —— 但请把它当**风险**，不要当结论。
#   注意它也**只在从没装过 R 的机器上**才发作：开发机上装了 R，链接是好的，
#   怎么试都复现不出来。
#
#   好消息：真文件**就在包里**（fontconfig/fontconfig/conf.avail/ 那 35 条，
#   核过 zip），所以不用下载任何东西，把链接改成相对路径就行：
#       fonts/conf.d/x.conf  ->  ../../fontconfig/conf.avail/x.conf
#   这样它跟着包走，解压到哪儿都对。
#   （前提是打包末尾 zip 用了 -y 存链接、用户那边解压保留链接 —— 本来就是这样。）
#
#   为什么 Windows 那份不用改：Windows 版的 R 是纯 zip，没有 fontconfig。
FC_D="$STAGE/runtime/R/fontconfig/fonts/conf.d"
FC_A="$STAGE/runtime/R/fontconfig/fontconfig/conf.avail"
if [ -d "$FC_D" ]; then
  fc_abs=0; fc_fixed=0; fc_link=0
  for l in "$FC_D"/*.conf; do
    [ -L "$l" ] || continue
    fc_link=$((fc_link + 1))
    case "$(readlink "$l")" in
      /*) fc_abs=$((fc_abs + 1))
          base="$(basename "$l")"
          if [ -f "$FC_A/$base" ]; then
            ln -sfn "../../fontconfig/conf.avail/$base" "$l"
            fc_fixed=$((fc_fixed + 1))
          fi
          ;;
    esac
  done
  # 把**分母**也打出来：只报"改了 N 条"的话，"链接一条都没有"（上一段整段被
  # 跳过了）在日志里长得和"全部改好了"一模一样。下面那条 chk 会判死，这里先给数。
  say "  fontconfig：conf.d 下符号链接 ${fc_link} 条，其中绝对 ${fc_abs} 条 → 改成相对 ${fc_fixed} 条"
  # 少改一条就是"某些字族回退在用户机器上失效"，而这件事**没有任何报错**，
  # 所以这里直接判死，不留活口。
  [ "$fc_fixed" -eq "$fc_abs" ] || die "fontconfig 有绝对链接没改过来（${fc_abs} 条里只改了 ${fc_fixed} 条）—— 见上面注释：用户机器上会静默失效"
else
  # ⚠️ 走到这儿说明这个运行时里没有 fontconfig（Windows 那份 R 就是纯 zip、
  #    没有 fontconfig，但那是**另一个脚本**的事；macOS 这份一直是有的）。
  #    不 die —— 上游真去掉了 fontconfig 的话这条不该拦发布。但**必须出声**：
  #    安静跳过的话，下面那条 chk 量到 0 条链接也无从判断是"没有了"还是"没做"。
  say "  ⚠️ fontconfig/conf.d 不在这个运行时里（$FC_D）—— 上面那段绝对链接的修复这轮没做"
fi

# ---- 2. R 包（macOS 二进制）------------------------------------------------
say "装依赖包进 runtime/R/library（这一步最慢，第一次要几分钟）"
# 第 3 个参数是完整的 R 版本号，第 4 个是平台 —— fetch_win_pkgs.R 按它选
# CRAN 仓库、选 .tgz、并**验每个 .so 的架构**（见那个脚本里的说明）。
# 第 5 个参数是**包缓存目录**（放 $DL，在 $STAGE 外面）—— 理由和 Windows
# 那份一样：脚本每轮都 `rm -rf $STAGE`，没有缓存的话 64 个包每轮全下，
# 而 CRAN 每轮会抽风掉两三个，重试收敛不了。
Rscript --no-environ "$REPO/desktop/fetch_win_pkgs.R" \
    "$STAGE/runtime/R/library" "$RMINOR" "$RVER" "macos-$ARCH" "$DL"

# ---- 3. 应用本体（平铺到根目录，见文件头那段说明）--------------------------
# ★ V16.6 item 5：和 Windows 那份一样，应用本体是**字节码**，不是 R/ 那堆 .R。
#   打包前先卡版本：字节码跨 R 版本**静默**退化成解释执行，不报错。
say "复制应用文件"
# ⚠️ R.version$minor 是 **"4.3"** 这种带补丁号的（R 4.4.3 -> minor="4.3"），
#    直接 paste 出来是 "4.4.3"；要的是 major.minor，所以先把 minor 的补丁位砍掉。
#
# ⚠️⚠️ 正则**故意写成 `[.]` 而不是 `\\.`**（2026-10-07）。原来写的是
#    `sub("\\..*$", ...)`，在 macOS runner 上 R 收到的是 `"\..*$"` —— **单**反斜杠，
#    当场 `Error: '\.' is an unrecognized escape in character string (<input>:1:40)`，
#    这个 job 一秒都过不去。而同一个写法在 ubuntu 上是好的（win-bundle 全绿）、
#    在本地也是好的，远端文件又逐字节正确 —— 也就是**"谁把 `\\` 吃成了 `\`"
#    这个问题当时没有答案**。
#    `[.]` 是"字符类里只有一个点"，语义和 `\.` 完全等价，而**一个反斜杠都不用**，
#    于是这个 job 不必先等那个答案。
#    （workflow 里留了一步"诊断——单引号里的反斜杠"，就是为了把那个答案问出来。）
BUILD_RVER="$(Rscript --no-environ -e 'cat(paste0(R.version$major, ".", sub("[.].*$", "", R.version$minor)))')"
# ⚠️ 比到 **minor**，不比 patch —— 和 desktop/bytecode_app.R 里那道闸门同一个
#    判据（那里有实测：4.4.2 打的字节码在 4.4.3 里跑，无警告、仍是 BCODESXP）。
[ "$BUILD_RVER" = "${RVER%.*}" ] || die "打包用的 R 是 ${BUILD_RVER}，而包里的运行时是 ${RVER}（minor 不同）。
   字节码跨 minor 版本不保证可用（对不上时 R 会退回解释执行，不一定报错）。
   换一个 ${RVER%.*}.x 的 Rscript 再打。"
say "字节码化（app.R + R/*.R -> app.rds + lib.rds；打包机 R ${BUILD_RVER}，运行时 ${RVER}，同 minor）"
rm -f "$STAGE/app.rds" "$STAGE/lib.rds" "$STAGE/built_with_R.txt"
Rscript --no-environ "$REPO/desktop/build_bytecode.R" "$REPO" "$STAGE"

cp -a "$REPO/run_local.R" "$REPO/run_app.command" "$STAGE/"
cp -a "$REPO/www" "$REPO/skills_builtin" "$STAGE/"
# ⚠️ 不写 `2>/dev/null || true`：原来那样写，文件不见了会**静默**跳过，
#    而这个 txt 是用户手里唯一一份说明（打包脚本最后一行还让 TA 去看它）。
#    Gatekeeper 那件事只能靠文档说，脚本自己救不了（脚本已经被拦住了）。
[ -f "$REPO/desktop/HOWTO-macOS.txt" ] || \
  die "desktop/HOWTO-macOS.txt 不见了 —— 它是用户唯一能看到的说明（尤其 Gatekeeper 那节），不能不发"
cp -a "$REPO/desktop/HOWTO-macOS.txt" "$STAGE/"

# ★ 出厂跳板清单（可选），和 Windows 那份同一套约定。
if [ -f "$REPO/desktop/jump_servers.json" ]; then
  mkdir -p "$STAGE/desktop"
  cp -a "$REPO/desktop/jump_servers.json" "$STAGE/desktop/"
  say "已带上出厂跳板清单 desktop/jump_servers.json"
else
  say "没有 desktop/jump_servers.json —— 分发包不带默认跳板"
fi

# ⚠️ 启动器**必须**是 LF 而且是可执行的。
#    · CRLF 的 shell 脚本报 `bad interpreter: /bin/bash^M` —— 而如果是从
#      Windows 机器上转手过来的、或者被哪个编辑器"顺手统一"成 CRLF 了，
#      症状就是双击一闪而过 + 这么一句看不懂的英文。
#    · 没有可执行位 → 双击报"你没有合适的访问权限"，用户会以为文件坏了。
#      zip **会**存 Unix 权限位，但前提是打包时它就是可执行的，所以在这里设。
# ⚠️ 用 tr 而不是 python3：macOS 上 `python3` 只有在装了 Xcode 命令行工具
#    之后才存在（没装的话那个 /usr/bin/python3 是个会弹安装框的壳），
#    而这个脚本**就是给 Mac 用的**。tr 是一定有的。
tr -d '\r' < "$STAGE/run_app.command" > "$STAGE/.cmd.tmp"
mv "$STAGE/.cmd.tmp" "$STAGE/run_app.command"
chmod 755 "$STAGE/run_app.command"

# ---- 4. 自检（打包前把"少东西"挡在这里）------------------------------------
say "自检"
fail=0
chk() { if eval "$2"; then printf '   ✓ %s\n' "$1"; else printf '   ✗ %s\n' "$1"; fail=1; fi; }

chk "run_app.command 在包根目录"        "[ -f '$STAGE/run_app.command' ]"
chk "run_local.R 和它同层（--file= 靠这个推应用目录）" "[ -f '$STAGE/run_local.R' ]"
chk "★ 启动器可执行（双击靠的就是这一位）" "[ -x '$STAGE/run_app.command' ]"
# ⚠️ 数 CR 的个数，不用 `grep -qU $'\r'`：`-U` 是 GNU grep 的选项，macOS 上
#    那个 BSD grep 不认。tr 是两边都有的。
chk "★ 启动器是 LF（CRLF 会报 bad interpreter）" \
    "[ \$(tr -cd '\r' < '$STAGE/run_app.command' | wc -c) -eq 0 ]"
chk "启动器有 shebang"                   "head -1 '$STAGE/run_app.command' | grep -q '^#!/bin/bash'"
chk "启动器认打包好的运行时"             "grep -q 'runtime/R/bin/Rscript' '$STAGE/run_app.command'"
chk "★ runtime 就在应用目录下（平铺，不是塞进 app/）" \
    "[ -d '$STAGE/runtime/R/library' ]"
chk "Rscript 在"                         "[ -f '$STAGE/runtime/R/bin/Rscript' ]"
chk "★ Rscript 可执行"                   "[ -x '$STAGE/runtime/R/bin/Rscript' ]"
chk "libR.dylib 在（macOS 版 R 的核心）" \
    "[ -n \"\$(find '$STAGE/runtime/R' -maxdepth 3 -name 'libR.dylib' | head -1)\" ]"
# ★ 这条必须有，因为**这个 bug 一声不吭**：断掉的 conf 被 fontconfig 当不存在、
#   静默跳过，要等用户在没装 R 的机器上画图才可能看出来（而且未必看得出来）。
#   判据 = runtime/R 底下**一条指向绝对路径的符号链接都不许有**。
#   为什么判"是不是绝对"而不是"是不是断链"：断不断要在**用户机器上**才知道，
#   而打包机上恰好装着 R ⇒ 绝对链接在**这里**是好的。只有"绝对/相对"这个属性
#   两边一致，所以判它。
# ⚠️ 用 R 写而不是 `find -lname '/*'`：macOS 的 find 是 BSD 的，`-lname` 有没有
#    不保证（这个文件里判 JSON 那一条也是同样的理由换成 R 的）。
#    Sys.readlink() 对非链接返回 ""，`nzchar()` 天然过滤掉。
#
# ⚠️⚠️ 这一条**原本是会空转的**：只判"有没有指向绝对路径的链接"，那么
#    `runtime/R` 整个不在、或者那 17 条链接被删光、或者 list.files 因为权限
#    什么都没列出来 —— 三种情况下 `a` 都是空的 ⇒ **绿**。"一条都没有"和
#    "一条都没问题"在输出里长得一样。按本仓规矩（拿不到就跳过 = 假绿，比红更坏）
#    补两样东西：
#      ① **把数出来的条数打出来**（链接 N 条：绝对 a、相对 r、相对中断链 d）——
#         日志里看得见分母，下一个人不用猜；
#      ② **下限**：链接 < 1 条直接判红。正常的 portable R 里链接是两位数的。
#    顺带补一档**相对但断链**：原来的写法只认"绝对"，而把相对路径拼错
#    （`../../wrong/x.conf`）时它照样是绿的 —— 而 fontconfig 读不到的 conf 是
#    **静默跳过**，所以拼错和断链在用户机器上完全同病。这里按**链接自己的目录**
#    解析相对目标，解析不到就算红。
chk "★ runtime/R 下没有指向绝对路径的符号链接（fontconfig 那 17 条就是这个坑）" \
    "Rscript --no-environ -e 'rr <- \"$STAGE/runtime/R\"; f <- list.files(rr, recursive=TRUE, all.files=TRUE, full.names=TRUE); t <- Sys.readlink(f); L <- nzchar(t); a <- f[L][startsWith(t[L], \"/\")]; r <- f[L][!startsWith(t[L], \"/\")]; tr <- t[L][!startsWith(t[L], \"/\")]; d <- r[!file.exists(file.path(dirname(r), tr))]; cat(sprintf(\"  符号链接 %d 条：绝对 %d、相对 %d、相对中断链 %d\n\", sum(L), length(a), length(r), length(d))); if (length(a)) cat(\"  指向绝对路径的：\", paste(a, collapse=\"  \"), \"\n\"); if (length(d)) cat(\"  相对但断链的：\", paste(d, collapse=\"  \"), \"\n\"); quit(status = if (length(a) || length(d) || sum(L) < 1L) 1L else 0L)'"
chk "app.R 在"                           "[ -f '$STAGE/app.R' ]"
# ★ 这一组是"字节码真的打进去了"。
chk "★ 分发包里**没有** R/ 目录（源码树不该发出去）" "[ ! -e '$STAGE/R' ]"
chk "★ lib.rds 在（R/*.R 的字节码）"     "[ -f '$STAGE/lib.rds' ]"
chk "★ app.rds 在（app.R 的字节码）"     "[ -f '$STAGE/app.rds' ]"
# ⚠️ 比到 **minor**：打包机是 4.4.2、运行时是 4.4.3，这是**正常且验证过**的组合
#    （见 bytecode_app.R 里那道闸门的实测记录）。写成 `^R version $RVER ` 就
#    要求逐字相同，那会让这个包永远打不出来。
chk "★ built_with_R.txt 的 minor 和运行时一致（加载器就是按这个判的）" \
    "grep -q '^R version ${RVER%.*}\\.' '$STAGE/built_with_R.txt'"
chk "★ 包里的 app.R 是那个薄加载器（正文不在里面）" \
    "grep -q 'readRDS' '$STAGE/app.R' && [ \$(wc -l < '$STAGE/app.R') -lt 150 ]"
chk "★ 包里没有任何 .R 源码文件（除加载器和启动器）" \
    "[ -z \"\$(find '$STAGE' -maxdepth 2 -name '*.R' ! -name 'app.R' ! -name 'run_local.R' -not -path '*/runtime/*')\" ]"
chk "★ lib.rds 能被读回来，且里面有几百个对象" \
    "Rscript --no-environ -e 'l <- readRDS(\"$STAGE/lib.rds\"); quit(status = if (length(l) > 200) 0 else 1)'"
if [ -f "$STAGE/desktop/jump_servers.json" ]; then
  # ⚠️ 用 R 验 JSON 而不是 python3：同上，python3 在 Mac 上不保证有，而 R
  #    **一定有**（我们刚刚才用 Rscript 打完包）。jsonlite 也在包里。
  chk "出厂跳板清单是合法 JSON" \
      "Rscript --no-environ -e 'invisible(jsonlite::fromJSON(\"$STAGE/desktop/jump_servers.json\"))'"
  chk "出厂跳板清单里没有凭据"    "! grep -qiE 'pass(word)?|ssh_key|private' '$STAGE/desktop/jump_servers.json'"
fi
chk "www/ 下的文件数和仓库一致" \
    "[ \$(ls '$STAGE/www' | wc -l) -eq \$(ls '$REPO/www' | wc -l) ]"
chk "内置技能在"                       "[ -d '$STAGE/skills_builtin' ]"
chk "★ 没把开发机的数据库带出去" \
    "[ ! -e '$STAGE/data/dsapp.sqlite3' ]"
chk "★ 没把密钥带出去" \
    "[ ! -e '$STAGE/data/.secret_key' ] && [ ! -e '$STAGE/data/.keyring' ]"
for p in shiny bslib RSQLite DT httr2 processx callr digest jsonlite curl; do
  chk "包 $p 装进去了"                 "[ -f '$STAGE/runtime/R/library/$p/DESCRIPTION' ]"
done
# ⚠️ 带编译代码的包必须有 .so，而且**架构要对**。CRAN 的 big-sur-arm64 和
#    big-sur-x86_64 是两份仓库，拿错的话包能解开、DESCRIPTION 也在、
#    .so 也在 —— 只有 file(1) 看得出它不是这个 CPU 的。
#    （fetch_win_pkgs.R 已经全量验过一遍，这里再抽查一个，因为**发布物**上
#      值得再确认一次：那个脚本被人改动过的话，这里会红。）
SOSAMPLE="$STAGE/runtime/R/library/RSQLite/libs/RSQLite.so"
chk "RSQLite.so 在" \
    "[ -f '$SOSAMPLE' ]"
chk "★ RSQLite.so 的架构就是 $ARCH" \
    "file -b '$SOSAMPLE' | grep -q '$ARCH'"
chk "★ RSQLite.so 是 Mach-O（不是 Linux 的 ELF）" \
    "file -b '$SOSAMPLE' | grep -q 'Mach-O'"
# ⚠️ 必须 tr -d '\r'：macOS 发行版里的 DESCRIPTION 是 **CRLF**，不剥掉行尾
#    那个 \r，比出来的是 "4.4.3\r" ≠ "4.4.3"，这条会假红。
chk "R 运行时自己的版本就是 $RVER" \
    "[ \"\$(grep -m1 '^Version:' '$STAGE/runtime/R/library/base/DESCRIPTION' | sed 's/Version: *//' | tr -d '\r')\" = '$RVER' ]"
# ★ 判据是"没有包比运行时**更新**"，不是"全都等于运行时"。理由和实测见
#   build_windows_bundle.sh 里那条的注释（R 自己的 testRversion 只在
#   `built > current` 时 warning，包比 R 旧是完全静默的）。
#   mac 这边尤其明显：big-sur-arm64/contrib/4.4 实测是 4.4.0×4 / 4.4.1×29 /
#   4.4.2×29 / 4.4.3×31 —— "全等于"永远不可能成立。
#
# ⚠️ 版本比较交给 R（numeric_version）。`awk '$0+0 > 4.4'` 把 "4.4.3" 和
#    "4.4.2" 都算成 4.4，正好漏掉要抓的情况，还永远绿。
built_all="$(grep -h '^Built:' "$STAGE/runtime/R/library"/*/DESCRIPTION 2>/dev/null |
             sed 's/Built: R \([0-9.]*\).*/\1/' | tr -d '\r')"
newer="$(printf '%s\n' "$built_all" | Rscript --no-environ -e '
  v <- scan("stdin", what = "", quiet = TRUE); r <- commandArgs(TRUE)[[1]]
  v <- v[nzchar(v)]
  cat(paste(sort(unique(v[numeric_version(v) > numeric_version(r)])), collapse = " "))' "$RVER")"
dist="$(printf '%s\n' "$built_all" | grep -v '^$' | sort | uniq -c |
        awk '{printf "%s:%s ", $2, $1}')"
chk "★ 没有包是**比运行时更新**的 R 编的（Built 分布：${dist}）" "[ -z '$newer' ]"
[ -z "$newer" ] || echo "   比 $RVER 新的：$newer"

# ⚠️ 交叉检查：仓库里每个 R/*.R 都不能混进包（"清单和 rds 对得上"那条已经
#    挪进 build_bytecode.R 了 —— 那里覆盖面更大，对所有平台的包都生效）。
miss=""
for f in "$REPO/R"/*.R; do
  b="$(basename "$f")"
  # ⚠️ 写成 `[ -e ... ] && miss=...` 会踩 set -e：这条 `&&` 列表是循环体最后
  #    一条命令，条件不成立（也就是**正常**情况）时整个列表返回非零。
  if [ -e "$STAGE/R/$b" ]; then miss="$miss $b"; fi
done
chk "★ 清单里的 R/*.R 一个都没混进包${miss:+（混进了：${miss}）}" "[ -z '$miss' ]"

chk "★ run_local.R 找运行时的路径和实际布局对得上" \
    "[ -f \"\$(dirname '$STAGE/run_local.R')/runtime/R/bin/Rscript\" ]"

[ "$fail" -eq 0 ] || die "自检没过，没有打包。上面带 ✗ 的就是问题。"
say "自检全过"

# ---- 5. 打包 ----------------------------------------------------------------
say "压缩（这一步也要一会儿，运行时解出来有 200 MB 上下）"
# ⚠️ -y 不能省：不加的话 zip 会把运行时里的符号链接**解引用**成普通文件副本
#    （体积翻倍，而且以后 dylib 更新时两份会分家）。
( cd "$OUT" && rm -f "$NAME.zip" && zip -qry "$NAME.zip" "$NAME" )
du -h "$OUT/$NAME.zip" | awk '{print "== 好了：" $2 "  " $1}'

# ---- 6. 验回：解出来还能不能跑 ----------------------------------------------
# ⚠️ 这条是**这个脚本里最值钱的一条**：zip 的权限位/符号链接是"打的时候对、
#    解的时候丢"的经典事故（Windows 那边没这个问题，因为 .bat 的权限无所谓，
#    而 mac 的启动器**少了可执行位就是双击打不开**）。所以真解一遍来验。
say "验回：把 zip 解开，确认可执行位和符号链接都还在"
VERIFY="$OUT/.verify-$ARCH"
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
unzip -q "$OUT/$NAME.zip" -d "$VERIFY"
vfail=0
vchk() { if eval "$2"; then printf '   ✓ %s\n' "$1"; else printf '   ✗ %s\n' "$1"; vfail=1; fi; }
vchk "解出来的启动器仍然可执行"     "[ -x '$VERIFY/$NAME/run_app.command' ]"
vchk "解出来的 Rscript 仍然可执行"  "[ -x '$VERIFY/$NAME/runtime/R/bin/Rscript' ]"
# 符号链接：打包前数一遍、解开后数一遍，必须一样多。
# ⚠️ 数量一样不等于**内容**一样（可能是同样的数量、但都被解引用了）——
#    所以底下再用 `-type l` 数一次，两次一起看才作数。
n_link_stage="$(find "$STAGE" -type l | wc -l)"
n_link_unzip="$(find "$VERIFY/$NAME" -type l | wc -l)"
vchk "符号链接数量没变（打包前 ${n_link_stage}，解开后 ${n_link_unzip}）" \
    "[ '$n_link_stage' -eq '$n_link_unzip' ]"
vchk "解出来的 lib.rds 读得动" \
    "Rscript --no-environ -e 'quit(status = if (length(readRDS(\"$VERIFY/$NAME/lib.rds\")) > 200) 0 else 1)'"
rm -rf "$VERIFY"
[ "$vfail" -eq 0 ] || die "验回没过 —— zip 把权限位或符号链接弄丢了，别发这个包。"

echo
echo "包内结构（runtime/R/library 下面不展开）："
( cd "$STAGE" && find . -maxdepth 2 -not -path './runtime/R/library/*' \
    -not -path './runtime/R/library' | sort | head -30 )
echo
echo "把它发给用户，让 TA 解压后双击 run_app.command。"
echo "⚠️ 第一次打开会被 Gatekeeper 拦（未签名）—— 告诉用户：右键→打开→再点打开，"
echo "   或者 xattr -dr com.apple.quarantine <文件夹>。详见 desktop/HOWTO-macOS.txt。"
# ⚠️ 提示里要报**另一个**架构，不能写死。原来这一行写死的是 "x86_64"：
#    打 arm64 包时它是对的，打 **x86_64** 包时它就变成"要另跑一次 x86_64"
#    —— 自己指自己，而真正缺的 arm64 一个字没提。消息写错不会有任何东西
#    变红（自检查的是"包对不对"，不是"提示对不对"），只能靠人读。
if [ "$ARCH" = "x86_64" ]; then
  HERE="Intel";           OTHER="arm64";  OTHER_CN="Apple Silicon"
else
  HERE="Apple Silicon";   OTHER="x86_64"; OTHER_CN="Intel"
fi
echo "⚠️ 这个包是 $ARCH 单架构的，只给 $HERE 机器用。"
echo "   要覆盖 $OTHER_CN 机器，另跑一次："
echo "     bash desktop/build_macos_bundle.sh <输出目录> $OTHER"
