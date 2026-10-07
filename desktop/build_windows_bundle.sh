#!/usr/bin/env bash
# =============================================================================
# 组装 Windows 免安装分发包（V13.2 item 1 —— 用户问的"预制的环境在 .bat 里"）
# =============================================================================
#
#   bash desktop/build_windows_bundle.sh [输出目录]
#
# 产出：<输出目录>/DS_App-Windows-<版本>.zip
# 用户拿到之后：解压 → 双击 run_app.bat。**不需要装 R，不需要装任何包。**
#
# ---- 它解决的是什么 ---------------------------------------------------------
#
# 用户的原话：「现有这个.bat不行，还要windows固定路径下的R存在才能生效」。
# 对。旧版 run_app.bat 靠 `where Rscript` 找机器上的 R，找不到就让人去
# 编辑 .bat、手写一个 C:\Program Files\R\R-4.4.2\... 的路径 —— 那不是
# 用户可以自己完成的操作，而且那个路径一旦跟着 R 升级变了，说明书就过期了。
#
# 这个脚本把「R 运行时 + 这个应用需要的全部 R 包」一起打进分发包，
# run_app.bat 优先用包内那一份。机器上有没有 R 都无所谓。
#
# ---- 为什么这份能在 Linux 上组装出 Windows 用的东西 -------------------------
#
# 因为不需要**运行** Windows：
#   · R 运行时  = portable-r 项目发布的、已经编译好的 Windows R（zip）；
#   · R 包      = CRAN 的 bin/windows/contrib/<版本>/*.zip，里面连 .dll 都是
#                 编译好的。装包 = 解开、放进 library/。
# 全程只是下载和解压（见 fetch_win_pkgs.R 顶部的说明）。
#
# ⚠️ 但**我没有 Windows 机器**，所以这个 zip 是"组装正确"而不是"我跑过"。
#    发出去之前请在一台真 Windows 上双击一次，见 desktop/README.md 末尾
#    那张验收清单。
#
# ---- 包内布局（和仓库保持一致，别自作聪明加一层 app/）----------------------
#
#   DS_App-Windows-16.6.0/
#     run_app.bat          ← 用户双击这个
#     run_local.R          ← 启动器
#     app.R                ← ★ V16.6 起只有十几行：一个读 rds 的加载器
#     app.rds  lib.rds     ← ★ 应用正文的字节码（没有 R/ 目录了）
#     built_with_R.txt     ← 编译用的 R 版本，加载器拿它对指纹
#     www/  skills_builtin/  ← 前端和内置技能仍是明文（是数据，不是代码）
#     runtime/R/           ← 便携版 R + 全部依赖包（版本见下面的 RVER，别再抄死）
#     HOWTO-Windows.txt
#     data/                ← 第一次启动时自己建，不预置
#
# ⚠️ 关于 app.rds/lib.rds：「不再是明文」**不等于**「看不到源码」。R 的字节码
#    里原样留着 AST（R 自己要用它 deparse/print），`readRDS()` + `deparse()`
#    就能拿回逐字一样的函数体。这个包的用处是"没有一坨 .R 可以随手翻" +
#    "启动时不用再解析编译"，不是保密。详见 desktop/build_bytecode.R 顶上那张表。
#
# ⚠️ run_local.R 是用 `--file=` 反推应用目录的（见它自己那段注释），
#    也就是说"run_local.R 在哪，runtime/ 就得在哪"。所以上面**必须是平铺的**：
#    如果把应用塞进 app/ 子目录、runtime/ 留在外面，run_local.R 会去
#    app/runtime/R/bin/Rscript.exe 找运行时 —— 找不到，然后又退回系统 R，
#    也就是用户抱怨的那个行为。这不是风格问题，是能不能跑的问题。
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/dsapp_build}"
# ★ V16.6 item 5：4.4.2 -> **4.4.3**。
#   CRAN 的 bin/windows/contrib/4.4 里，包是**用 R 4.4.3 编译的**（那是 4.4
#   系列最新的补丁版，CRAN 每次重编都跟最新的走）。运行时低于它的话，用户
#   那边**每 library() 一个包就打一句** "package 'xxx' was built under R
#   version 4.4.3" —— 64 个包滚一屏英文，看着像程序坏了。
#   （这个坑一直都在：本文件下面那条 Built 自检本来就该因为它变红。
#     是 V16.6 做 mac 包时才撞出来的，见 tests/ui_v166/README.md item 5。）
RVER="${DSAPP_RUNTIME_RVER:-4.4.3}"
RMINOR="${RVER%.*}"                      # 4.4
# ⚠️ 用 sed 而不是 `grep -oP`：-P 是 GNU 的 PCRE 扩展，BSD grep（macOS）没有。
#    这个脚本在 Linux 上跑没问题，但**完全没有理由**只能在那上面跑 ——
#    买了 Mac 的人会顺手两个包一起打，那时它在第二行就报
#    "grep: invalid option -- P"，而错误信息指不到版本号上。
VER="$(sed -n 's/.*DSAPP_VERSION[[:space:]]*<-[[:space:]]*"\([^"]*\)".*/\1/p' \
       "$REPO/R/config.R" | head -1)"
[ -n "$VER" ] || die "从 R/config.R 里读不出 DSAPP_VERSION —— 那一行的写法变了？"
NAME="DS_App-Windows-$VER"
STAGE="$OUT/$NAME"
DL="$OUT/dl"
RZIP="$DL/portable-r-$RVER-win-x64.zip"
URL="https://github.com/portable-r/portable-r-windows/releases/download/v$RVER/portable-r-$RVER-win-x64.zip"

say() { printf '\033[36m==\033[0m %s\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$DL"
say "输出：$OUT/$NAME.zip"

# ---- 1. R 运行时 ------------------------------------------------------------
if [ ! -f "$RZIP" ]; then
  say "下载 Windows 版 R ${RVER}（约 110 MB，断了会续传）"
  # ⚠️ 不用 R 的 download.file()：它默认 60 秒超时，110 MB 在这条线上必超
  #    （第一次就是这么失败的，报的是 "Timeout of 60 seconds was reached"，
  #    看着像 GitHub 挂了）。
  curl -L --retry 5 -C - -o "$RZIP" "$URL"
fi
# ⚠️ 下了一半的 zip 也要能被发现。截断的 zip 解到一半才报错，那时已经
#    建了一堆目录，看起来像"解压代码有问题"。
unzip -tq "$RZIP" >/dev/null 2>&1 || die "R 运行时 zip 不完整（${RZIP}），删掉重跑"

say "解压 R 运行时"
rm -rf "$STAGE"
mkdir -p "$STAGE/runtime"

# ⚠️ 先解到一个临时目录再搬，不要直接解进 runtime/ 然后"删掉多余的东西"：
#    这个 zip 解出来是 portable-r-<版本>-win-x64/{bin,library,...}，而我们要
#    的是 runtime/R/{bin,library,...}。第一版脚本是"把它 mv 成 R.tmp，再
#    rm -rf runtime/*，再把 R.tmp 改回 R" —— 那个 rm 会把 R.tmp 自己也删掉。
unzip -q "$RZIP" -d "$STAGE/.rtmp"
# ⚠️ 不能用 `find -printf '%h\n'`：-printf 是 GNU find 的扩展，BSD find 没有。
# ⚠️⚠️ 也不能"找 Rscript.exe、dir 一层/两层当 R 根" —— 那是在赌归档顺序。
#    V16.6 改这行时就栽过：原写法是 `-printf '%h\n'`（已经剥了一层）+ 外面
#    再 dirname 一次 = 剥两层；改成普通 find 之后只剩一层 dirname，于是把
#    `bin/` 整个当成了 R 根，脚本报 "没有 runtime/R/bin/Rscript.exe"，
#    看着像下载的 zip 坏了，其实是搬错了目录。
#    判据换成**结构**：哪一层同时有 bin/Rscript.exe 和 library/，哪一层才是 R 根。
root=""
for d in "$STAGE/.rtmp"/*/ "$STAGE/.rtmp"/*/*/; do
  [ -d "$d" ] || continue
  if [ -f "${d}bin/Rscript.exe" ] && [ -d "${d}library" ]; then root="${d%/}"; break; fi
done
[ -n "$root" ] || die "找不到 R 根目录（要同时含 bin/Rscript.exe 和 library/）—— portable-r 的结构变了？"
mv "$root" "$STAGE/runtime/R"
rm -rf "$STAGE/.rtmp"
ls "$STAGE/runtime/R/bin/Rscript.exe" >/dev/null || die "没有 runtime/R/bin/Rscript.exe"
[ -d "$STAGE/runtime/R/library" ] || die "便携版 R 里没有 library/ 目录，依赖包没处装"

# ---- 2. R 包（Windows 二进制）----------------------------------------------
# 装进 runtime/R/library —— 也就是便携版 R 自己的默认库路径，不用再设 R_LIBS。
say "装依赖包进 runtime/R/library（这一步最慢，第一次要几分钟）"
# 第 3 个参数是完整的 R 版本号：fetch_win_pkgs.R 拿它把每个包声明的 R 版本
# 下限对一遍（防"contrib 分档传错、包能解开但一 library() 就报 built for R x.y"）。
# 第 5 个参数是**包缓存目录**：放 $DL（和运行时 zip 一起，在 $STAGE **外面**）。
# ⚠️ 这不是"优化"，是能不能跑完的问题：这个脚本每次开头都 `rm -rf $STAGE`，
#    而 library 就在 $STAGE 里 —— 于是那份"装过的跳过"的续跑逻辑每轮都被
#    连根拔掉，64 个包**每轮全下**。CRAN 实测每轮会抽风掉 2~3 个
#    （`Couldn't connect to server`），一轮全成的概率只有百分之十几，
#    光靠重试收敛不了。有了缓存，第二轮只补缺的那几个。
# ⚠️ 顺带补上 `--no-environ`（mac 那份一直有，这份漏了）：否则 Rscript 会读
#    cwd 的 .Renviron，而那会**盖掉**继承来的环境变量（本仓栽过）。
Rscript --no-environ "$REPO/desktop/fetch_win_pkgs.R" \
    "$STAGE/runtime/R/library" "$RMINOR" "$RVER" "windows" "$DL"

# ---- 3. 应用本体（平铺到根目录，见文件头那段说明）--------------------------
# ★ V16.6 item 5：应用本体**不再是 R/ 那一堆 .R**，而是字节码。
#   打包前先卡一道版本：字节码跨 R 版本**不通用**，而 R 遇到版本不符是
#   **静默回退**到解释执行（不报错、只是慢），不会崩给你看 —— 唯一的防线
#   就是在这里比对。分发包里的 runtime 是 $RVER，所以打包用的这个 Rscript
#   必须也是 $RVER。
say "复制应用文件"
# ⚠️ R.version$minor 是 **"4.3"** 这种带补丁号的（R 4.4.3 -> minor="4.3"），
#    直接 paste 出来是 "4.4.3"；要的是 major.minor，所以先把 minor 的补丁位砍掉。
# ⚠️ 正则写成 `[.]` 而不是 `\\.` —— 这份脚本这条路（ubuntu）上两种写法都能跑，
#    但 mac 那份同一个写法当场炸（详见 build_macos_bundle.sh 里那段注释）。
#    两份保持一致，免得下次改的时候又分叉。
BUILD_RVER="$(Rscript --no-environ -e 'cat(paste0(R.version$major, ".", sub("[.].*$", "", R.version$minor)))')"
# ⚠️ 比到 **minor**，不比 patch —— 和 desktop/bytecode_app.R 里那道闸门同一个
#    判据（那里有实测：4.4.2 打的字节码在 4.4.3 里跑，无警告、仍是 BCODESXP、
#    结果一样）。卡到 patch 的话，打包机是 4.4.2、运行时是 4.4.3，这个包
#    就永远打不出来 —— 而它们本来就能一起用。
[ "$BUILD_RVER" = "${RVER%.*}" ] || die "打包用的 R 是 ${BUILD_RVER}，而包里的运行时是 ${RVER}（minor 不同）。
   字节码跨 minor 版本不保证可用（对不上时 R 会退回解释执行，不一定报错）。
   换一个 ${RVER%.*}.x 的 Rscript 再打，或者把 DSAPP_RUNTIME_RVER 改成 $BUILD_RVER 并重新下运行时。"
say "字节码化（app.R + R/*.R -> app.rds + lib.rds；打包机 R ${BUILD_RVER}，运行时 ${RVER}，同 minor）"
rm -f "$STAGE/app.rds" "$STAGE/lib.rds" "$STAGE/built_with_R.txt"
Rscript --no-environ "$REPO/desktop/build_bytecode.R" "$REPO" "$STAGE"

cp -a "$REPO/run_local.R" "$REPO/run_app.bat" "$STAGE/"
# ⚠️ www/ 和 skills_builtin/ 仍然是明文文件，**照旧要拷** —— 字节码只覆盖
#    R/ 里的代码，前端 js/css 和内置技能的 .md 是数据，不在编译范围内。
cp -a "$REPO/www" "$REPO/skills_builtin" "$STAGE/"
# ⚠️ 不写 `2>/dev/null || true`：那样写的话，文件不见了会**静默**跳过，
#    而这个 txt 是用户手里唯一一份说明（杀软误报那节只能靠它说清楚）。
[ -f "$REPO/desktop/HOWTO-Windows.txt" ] || \
  die "desktop/HOWTO-Windows.txt 不见了 —— 它是用户唯一能看到的说明，不能不发"
cp -a "$REPO/desktop/HOWTO-Windows.txt" "$STAGE/"

# ★ V16.6 item 1：出厂跳板清单（可选）。
#   有 desktop/jump_servers.json 就随包发出去，用户第一次启动时种进
#   sync_servers —— 这样"默认连哪台中转服务器"不用用户手打。
#   ⚠️ 没有也照样出包（自己搭的机器不需要），所以这里不是 die 是提示。
#   ⚠️ 只认 jump_servers.json，不认 .example（模板里那行 host 是占位符）。
if [ -f "$REPO/desktop/jump_servers.json" ]; then
  mkdir -p "$STAGE/desktop"
  cp -a "$REPO/desktop/jump_servers.json" "$STAGE/desktop/"
  say "已带上出厂跳板清单 desktop/jump_servers.json"
else
  say "没有 desktop/jump_servers.json —— 分发包不带默认跳板（照抄 .example 建一份就会有）"
fi

# ⚠️ .bat 必须是 **CRLF**。cmd.exe 解析 goto/标签时是按字节偏移去文件里找的，
#    纯 LF 的批处理在跳转时会出现"跳到半行中间"这种莫名其妙的失败 ——
#    它不会报错，只是执行到奇怪的地方。仓库里那份现在也是 CRLF 了，
#    这里再做一次是幂等的兜底（万一哪天被编辑器改回 LF）。
# ⚠️ 不用 python3：macOS 上的 /usr/bin/python3 是个壳（装了 Xcode 命令行工具
#    才真的能用），而这个脚本没理由只能在 Linux 上跑。tr + awk 两边都有，
#    而且先把已有的 \r 全剥掉再加，**幂等** —— 原来那版也是幂等的，
#    换成"直接追加 \r"就会在文件已经是 CRLF 时写出 \r\r\n。
tr -d '\r' < "$STAGE/run_app.bat" | awk '{printf "%s\r\n", $0}' > "$STAGE/.bat.tmp"
mv "$STAGE/.bat.tmp" "$STAGE/run_app.bat"

# 数据目录：分发包不预置 data/，第一次启动自己建。
# ⚠️ 千万不要把仓库的 data/ 拷进来 —— 那里面是开发机的数据库、API Key 的
#    密钥文件和所有人的工作区。.Renviron 里也不要写 DSAPP_DATA_ROOT：
#    写了就把数据钉死在打包机的路径上了。

# ---- 4. 自检（打包前把"少东西"挡在这里）------------------------------------
say "自检"
fail=0
chk() { if eval "$2"; then printf '   ✓ %s\n' "$1"; else printf '   ✗ %s\n' "$1"; fail=1; fi; }

chk "run_app.bat 在包根目录"           "[ -f '$STAGE/run_app.bat' ]"
chk "run_local.R 和它同层（--file= 靠这个推应用目录）" "[ -f '$STAGE/run_local.R' ]"
# ⚠️ 这三条原来用的是 `grep -U` / `grep -P` —— 都是 **GNU 扩展**，macOS 的
#    BSD grep 不认。其中 -P 那条更阴：grep 会以退出码 2（用法错误）失败，
#    而断言写的是 `! grep -qP ...`，"取反"把**错误**变成了**通过** ——
#    在 Mac 上打包时这条会永远绿，哪怕真的混进了中文。改成 tr / 字符类，
#    两边行为一致。（本仓的老毛病：判据本身没劲，看着像通过。）
chk "run_app.bat 的换行是 CRLF" \
    "[ \$(tr -cd '\r' < '$STAGE/run_app.bat' | wc -c) -gt 0 ]"
chk "run_app.bat 里没有 LF 结尾的行" \
    "[ \$(tr -cd '\r' < '$STAGE/run_app.bat' | wc -c) -eq \$(wc -l < '$STAGE/run_app.bat') ]"
# ⚠️ 判据是"剥掉 ASCII 之后还剩几个字节"，**不是** `grep '[^[:print:][:space:]]'`。
#    后者实测**认不出中文**（GNU grep 在 C locale 下照样把高位字节算成 printable，
#    对 "中文" 返回 0）—— 一条永远绿的检查，比没有检查更坏，因为它长得像通过。
#    tr 这个写法实测：中文 6 字节、纯 ASCII 0 字节、CRLF 的 \r 不算（\015 在
#    \000-\177 里，被一起剥掉）。
chk "run_app.bat 是纯 ASCII（中文会变乱码）" \
    "[ \$(LC_ALL=C tr -d '\000-\177' < '$STAGE/run_app.bat' | wc -c) -eq 0 ]"
chk "run_app.bat 认打包好的运行时"      "grep -q 'runtime\\\\R\\\\bin\\\\Rscript.exe' '$STAGE/run_app.bat'"
chk "★ runtime 就在应用目录下（平铺，不是塞进 app/）" \
    "[ -d '$STAGE/runtime/R/library' ]"
chk "Rscript.exe 在"                   "[ -f '$STAGE/runtime/R/bin/Rscript.exe' ]"
chk "R.dll 在（Windows 版 R 的核心）"   "[ -f '$STAGE/runtime/R/bin/x64/R.dll' ]"
chk "app.R 在"                         "[ -f '$STAGE/app.R' ]"
# ★ V16.6 item 5：这一组是"字节码真的打进去了"，不是"R/ 复制过去了"。
chk "★ 分发包里**没有** R/ 目录（源码树不该发出去）" "[ ! -e '$STAGE/R' ]"
chk "★ lib.rds 在（R/*.R 的字节码）"     "[ -f '$STAGE/lib.rds' ]"
chk "★ app.rds 在（app.R 的字节码）"     "[ -f '$STAGE/app.rds' ]"
# ⚠️ 两条都要记住：
#    · 只比版本号，**不要把 R.version.string 里那个日期写成字面量** ——
#      它长得像个常数，其实是随 R 补丁版发布的日期（本仓栽过「改常数没清
#      字面量」的跟头）；
#    · 比到 **minor**，不比 patch：打包机是 4.4.2、运行时是 4.4.3，这是
#      **正常且验证过**的组合（见 bytecode_app.R 里那道闸门的实测记录）。
#      写成 `^R version $RVER ` 就要求逐字相同，那会让这个包永远打不出来。
chk "★ built_with_R.txt 的 minor 和运行时一致（加载器就是按这个判的）" \
    "grep -q '^R version ${RVER%.*}\\.' '$STAGE/built_with_R.txt'"
# ⚠️ 这条查的是"分发包里那个 app.R 是**加载器**、不是仓库里那份正文"。
#    判据取加载器独有的那行；写成 `[ \$(wc -l) -lt 50 ]` 之类会在正文被别人
#    重排之后假绿。反过来，bin/ 这种大东西也不能被别的检查挡住（见下）。
chk "★ 包里的 app.R 是那个薄加载器（正文不在里面）" \
    "grep -q 'readRDS' '$STAGE/app.R' && [ \$(wc -l < '$STAGE/app.R') -lt 150 ]"
# ⚠️ 源码正文**真的不在**包里。这条要是红了，说明字节码那步被什么人改回
#    `cp -a R/` 了，而其余检查照样全绿。
chk "★ 包里没有任何 .R 源码文件（除加载器和启动器）" \
    "[ -z \"\$(find '$STAGE' -maxdepth 2 -name '*.R' ! -name 'app.R' ! -name 'run_local.R' -not -path '*/runtime/*')\" ]"
# V16.6 item 1：出厂清单要么带着、要么不带，**不许是坏的**。
# 一个格式坏的 jump_servers.json 不会让应用起不来（种不进去而已），
# 所以症状是"说好了默认连官方中转，装完是空的"—— 挡在这里比事后查便宜。
if [ -f "$STAGE/desktop/jump_servers.json" ]; then
  # ⚠️ 用 R 验 JSON，**不用 python3**：这条原来写的是 `python3 -c 'import json'`，
  #    和上面第 174 行那段注释（"macOS 上的 python3 是个壳"）自相矛盾 ——
  #    在 Mac 上打 Windows 包时，这条会因为弹出"要装 Xcode 命令行工具"而失败，
  #    或者更糟：卡在那个弹框上等人点。R 一定有（刚刚才用它打完字节码），
  #    jsonlite 也在包里。（同一件事 mac 那份脚本早就改成 R 了。）
  chk "出厂跳板清单是合法 JSON" \
      "Rscript --no-environ -e 'invisible(jsonlite::fromJSON(\"$STAGE/desktop/jump_servers.json\"))'"
  chk "出厂跳板清单里没有凭据"    "! grep -qiE 'pass(word)?|ssh_key|private' '$STAGE/desktop/jump_servers.json'"
fi
# （原来这里有一条"R/ 下的文件数和仓库一致"。V16.6 item 5 起包里没有 R/ 了，
#   它被上面那组"没有 R/、但有 lib.rds/app.rds"取代 —— 不是删掉了一项检查，
#   是换成了查**更强**的性质：源码树整个不在发布物里。）
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
chk "带编译代码的包有 x64 DLL" \
    "[ -n \"\$(find '$STAGE/runtime/R/library/RSQLite/libs/x64' -name '*.dll' 2>/dev/null)\" ]"
# ⚠️ DLL 的**位数**也要对。i386 的那份也是 .dll，名字还一样，混进去的话
#    报的是 "LoadLibrary failure: %1 is not a valid Win32 application"。
chk "DLL 是 64 位的 PE32+（不是 32 位）" \
    "file '$STAGE/runtime/R/library/RSQLite/libs/x64/RSQLite.dll' | grep -q 'PE32+.*x86-64'"
# ⚠️ 必须 tr -d '\r'：Windows 发行版里的 DESCRIPTION 是 **CRLF**，不剥掉行尾
#    那个 \r，比出来的是 "4.4.3\r" ≠ "4.4.3"，这条会假红（第一版就是这么红的，
#    而 od -c 才看得出来 —— 终端上那个 \r 是看不见的）。
chk "R 运行时自己的版本就是 $RVER" \
    "[ \"\$(grep -m1 '^Version:' '$STAGE/runtime/R/library/base/DESCRIPTION' | sed 's/Version: *//' | tr -d '\r')\" = '$RVER' ]"
# ⚠️★ 更要紧的一条，而且 V16.6 把**判据本身**改对了 —— 原来的写法是
#    "每个包的 Built 都必须**等于** $RVER"，那是**比真实要求更严**的一条，
#    严到不可能满足：CRAN 的 contrib/4.4 是**陆续**重编的，同一个仓库里
#    4.4.0 / 4.4.1 / 4.4.2 / 4.4.3 混着（2026-10-05 实测 mac arm64：
#    4+29+29+31）。要求"全等于"就等于要求 CRAN 停下来等我们。
#
#    真实要求是什么？去看 R 自己的实现（base::library 里的 testRversion）：
#        if (R_version_built_under > current) warning("package %s was built
#            under R version %s")
#    —— **只有"包比 R 新"才吭声**，包比 R 旧是**完全静默**的。
#    实测（本机 R 4.4.2，改 Meta/package.rds 里的 Built 一位一位试）：
#        Built 4.3.9 / 4.4.0 / 4.4.1 / 4.4.2  ->  无警告
#        Built 4.4.3 / 4.5.0                   ->  ⚠️ was built under R version ...
#    所以判据是 `Built > RVER`，不是 `Built == RVER`。旧的那些**报出来**
#    （打印个数），但不算失败 —— 它们是正常现象，不是问题。
#
# ⚠️ 别把这条改回"全等于"：mac 的仓库**永远**不会全等于，那条断言会让
#    mac 包永远发不出去，而它红的时候给的印象是"包有问题"。
# ⚠️ 版本比较**交给 R**（numeric_version），不要用 awk/sort -V 凑：
#    `awk '$0+0 > 4.4'` 把 "4.4.3" 算成 4.4、"4.4.2" 也算成 4.4 —— 正好
#    漏掉这条断言唯一要抓的那种情况，而且它会**静默地**永远绿。
#    `sort -V` 也不是所有平台都有（BSD sort 就没有）。
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

# ⚠️ V16.6 item 5：原来这里有一条"app.R 的 files 清单覆盖了每一个 R/*.R"
#    （在**发布物**上数文件）。分发包里已经没有 R/ 了，这条挪进了
#    build_bytecode.R —— 而且挪过去之后覆盖面**更大**：它现在管的是
#    "仓库里每个 R/*.R 都得在清单里"，对**所有**平台的包都生效，
#    不再是只有 Windows zip 打完才查一次。
#
#    这里改成查"清单和 rds 对得上"：把 app.R 里的 files 清单抽出来，
#    确认这些文件**确实在包外**（源码树没被夹带），且 lib.rds 读得动。
miss=""
for f in "$REPO/R"/*.R; do
  b="$(basename "$f")"
  # ⚠️ 写成 `[ -e ... ] && miss=...` 在这里会踩 set -e：这条 `&&` 列表是循环体
  #    最后一条命令，条件不成立（也就是**正常**情况）时整个列表返回非零 ——
  #    脚本会在"一切正常"时退出。用 if 写，不留这个歧义。
  if [ -e "$STAGE/R/$b" ]; then miss="$miss $b"; fi
done
chk "★ 清单里的 R/*.R 一个都没混进包${miss:+（混进了：${miss}）}" "[ -z '$miss' ]"
# ⚠️ readRDS 一条就够：lib.rds 是 xz 压的，截断/半截的包在这里就会炸，
#    而不是等到用户双击时。它顺便证明了这个 rds 是**这个 R** 写得出的。
chk "★ lib.rds 能被读回来，且里面有几百个对象" \
    "Rscript --no-environ -e 'l <- readRDS(\"$STAGE/lib.rds\"); quit(status = if (length(l) > 200) 0 else 1)'"

# ⚠️ run_local.R 里那句"找 runtime/R/bin/Rscript.exe"是相对**应用目录**写的。
#    这条检查是防"布局又被改回 app/ 子目录"的：真改回去的话，上面那些检查
#    可能还全绿，但用户一双击就退回系统 R 了。
chk "★ run_local.R 找运行时的路径和实际布局对得上" \
    "[ -f \"\$(dirname '$STAGE/run_local.R')/runtime/R/bin/Rscript.exe\" ]"

[ "$fail" -eq 0 ] || die "自检没过，没有打包。上面带 ✗ 的就是问题。"
say "自检全过"

# ---- 5. 打包 ----------------------------------------------------------------
say "压缩（这一步也要一会儿，运行时解出来有 200 MB 上下）"
( cd "$OUT" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )
du -h "$OUT/$NAME.zip" | awk '{print "== 好了：" $2 "  " $1}'
echo
echo "包内结构（runtime/R/library 下面不展开）："
( cd "$STAGE" && find . -maxdepth 2 -not -path './runtime/R/library/*' \
    -not -path './runtime/R/library' | sort | head -30 )
echo
echo "把它发给用户，让 TA 解压后双击 run_app.bat（详见 desktop/README.md 的验收清单）。"
