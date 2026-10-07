#!/bin/bash
# =============================================================================
# macOS 启动器（V16.6 item 5）—— 双击这个文件
# =============================================================================
# 双击后 Terminal 会打开、跑这个脚本、起一个本地服务、自动开浏览器。
# 关掉 Terminal 窗口（或按 Ctrl+C）就停止。
#
# ---- 和 run_app.bat 的关系 --------------------------------------------------
#
# 是同一件事的两个平台版本，逻辑刻意保持一致：优先用包里自带的 R，
# 没有才退回机器上的 R，都没有就给人话。改一边的时候记得看另一边。
#
# ⚠️ 两边有**两处必须不同**，别照抄：
#   1. 换行。.bat 必须 CRLF（cmd.exe 按字节偏移找标签），这个**必须 LF**
#      （CRLF 的 shell 脚本会报 `bad interpreter: /bin/bash^M`）。
#   2. 编码。.bat 是纯 ASCII（cmd 用 OEM 代码页，中文变乱码），这个用
#      UTF-8 就行（Terminal 默认就是 UTF-8）。
#
# ---- 关于 Gatekeeper（用户最可能卡住的地方）--------------------------------
#
# 从浏览器/微信/AirDrop 拿到的 zip 会被 macOS 打上 com.apple.quarantine，
# 解压后**双击这个文件会被系统拦住**，提示"无法打开，因为它来自身份不明的
# 开发者"。这不是文件坏了，是系统的隔离标记。两种解法（HOWTO-macOS.txt
# 里也写了）：
#
#     右键点这个文件 → 打开 → 再点一次"打开"          （只需做一次）
#     或者终端里：xattr -dr com.apple.quarantine <解压出来的文件夹>
#
# ⚠️ 这一段是**启动脚本自己不能解决的**：脚本已经被拦住了，它没机会运行。
#    所以只能靠文档，别想着在这里写代码绕过 —— 那正是"检测规避"。
# =============================================================================

# 双击时的工作目录是用户主目录，不是这个脚本所在的地方 —— 必须自己 cd。
cd "$(dirname "$0")" || exit 1

LOCAL_R="./runtime/R/bin/Rscript"

if [ -x "$LOCAL_R" ]; then
  export DSAPP_BUNDLED_R=1
  "$LOCAL_R" run_local.R "$@"
  st=$?
elif command -v Rscript >/dev/null 2>&1; then
  # ---- 没有自带运行时：退回机器上的 R（和 run_app.bat 同一套顺序）----------
  # ⚠️ 顺序不能反。机器上那个 R 十有八九没装依赖包，先用它的话用户看到的是
  #    "there is no package called 'bslib'"，看着像应用坏了。
  Rscript run_local.R "$@"
  st=$?
else
  echo
  echo "  [错误] 既没有自带 R 运行时，机器上也没有 Rscript："
  echo "      $(pwd)/runtime/R/bin/Rscript"
  echo
  echo "  多半是解压时丢了目录结构，或者只把启动器单独拷了出来。"
  echo "  请重新完整解压一次，别把文件单独拖出来。"
  echo
  echo "  也可以自己装一个 R：https://cran.r-project.org/bin/macosx/"
  echo
  read -r -p "  按回车关闭……" _
  exit 1
fi

if [ $st -ne 0 ]; then
  echo
  echo "  [错误] 应用异常退出（退出码 $st），详细信息见上面。"
  echo
fi

# 双击启动时窗口会一闪而过，看不到错误。留一口气让用户读完。
read -r -p "  按回车关闭这个窗口……" _
exit $st
