#!/bin/bash
# =============================================================================
# Biomamba 言出法随生信 APP（V4）部署脚本
# =============================================================================
# 把当前目录同步到 Shiny Server 的应用目录。
#
#   bash deploy.sh              # 同步
#   bash deploy.sh --check      # 只检查环境，不动文件
#
# Shiny Server 配置（/etc/shiny-server/shiny-server.conf）：
#   run_as shiny;  listen 34038;  site_dir /srv/shiny-server;
# 所以应用目录 /srv/shiny-server/YCFS_APP 对应 http://<host>:34038/YCFS_APP/
# （★ V13.7 item 8：URL 路径就是**目录名**，改名要连软链一起换，见 deploy_link.sh）
#
# ⚠️ /srv/shiny-server 归 shiny:shiny 所有且是 755，普通用户写不进去，
#    这个脚本必须以 root 运行（sudo bash deploy.sh）。
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DSAPP_DEST:-/srv/shiny-server/YCFS_APP}"
APP_URL="${DSAPP_URL:-http://127.0.0.1:34038/YCFS_APP/}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ---- 1. 环境检查 ------------------------------------------------------------
hdr "环境检查"

if [ "$(id -u)" -ne 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  red "✗ 需要 root 权限：sudo bash deploy.sh"
  echo "  （/srv/shiny-server 归 shiny:shiny 所有，普通用户无法写入）"
  exit 1
fi
grn "✓ 权限"

# ⚠️⚠️ 这个脚本和 deploy_link.sh 是**互斥**的两种部署形态，跑错会出事。
#     V5.2 起线上改走软链（$DEST 是指向本目录的软链）。如果已经换成了软链，
#     再跑这个脚本，后面的步骤会全部作用在**本目录自己**身上：
#       · rsync -a --delete "$SRC/" "$DEST/"  → 自己同步到自己（无害但是白跑）
#       · chown -R shiny:shiny "$DEST"        → **把整个开发目录的属主改成
#         shiny**，包括 .Renviron、history_Version/、你自己写的每一个文件。
#         之后你在开发目录里连改个文件都要 sudo。
#     这一步是本脚本里唯一真正危险的动作，所以在**动手之前**就拦下来。
if [ -L "$DEST" ] && [ "$(readlink -f "$DEST")" = "$SRC" ]; then
  red "✗ $DEST 已经是**指向本目录的软链**，说明线上跑的是软链部署。"
  echo "  这个脚本会 rsync 到自己、并 chown -R 整个开发目录，不能跑。"
  echo
  echo "  改代码 → 直接重启就行：sudo systemctl restart shiny-server"
  echo "  真要退回 rsync 模式：先删掉软链（sudo rm ${DEST}），再跑本脚本。"
  exit 1
fi

if ! command -v Rscript >/dev/null; then
  red "✗ 找不到 Rscript"; exit 1
fi
grn "✓ Rscript: $(command -v Rscript)"

# 关键包是否齐全。缺包是部署后最常见的白屏原因，提前查出来。
MISSING=$(Rscript -e '
pkgs <- c("shiny","bslib","httr2","callr","processx","DBI","RSQLite","DT",
          "commonmark","digest","jsonlite","curl","openssl")
miss <- pkgs[!vapply(pkgs, function(p) length(find.package(p, quiet=TRUE)) > 0, logical(1))]
cat(miss, sep=" ")
' 2>/dev/null || echo "RSCRIPT_FAILED")

if [ "$MISSING" = "RSCRIPT_FAILED" ]; then
  red "✗ Rscript 执行失败"; exit 1
elif [ -n "$MISSING" ]; then
  red "✗ 缺少 R 包：$MISSING"
  echo "  安装：sudo Rscript -e 'install.packages(c($(echo "$MISSING" | sed 's/ /","/g;s/^/"/;s/$/"/')))'"
  exit 1
fi
grn "✓ R 依赖齐全"

# ⚠️ 这份清单要和 app.R 顶上那个 source 列表**保持一致**。漏掉一个的后果不是
#    报错而是**静默失效**：app.R 里写的是 `if (file.exists(p)) source(p)`，
#    文件不在就跳过，于是那些函数压根没定义；用到它们的地方（比如启动清理）
#    各自包着 tryCatch，只往日志里写一行"出错"，页面上一切正常。
# ⚠️ www/ 下的文件也要列进来。它们不在 app.R 的 source 列表里（那份列表
#    只管 R/*.R），所以漏一个不会有任何交叉检查兜住 —— 表现是应用能起、
#    功能全在，只是**没有样式**（codex.css 漏掉就是这样：整页裸奔，
#    而服务端日志干干净净）。
for f in app.R selftest.R run_local.R run_app.bat \
         www/app.css www/app.js www/codex.css www/skins.css \
         R/config.R R/crypto.R R/utils.R R/errhand.R R/platform.R R/db.R R/scanner.R R/executor.R R/envs.R \
         R/remote.R R/export.R R/gc.R R/files.R R/prompts.R R/models.R R/llm.R R/proxy.R R/synckey.R R/forum.R R/syncservers.R R/sync.R \
         R/jobs.R R/taskrun.R R/detach.R R/render.R R/envfix.R R/agent.R R/health.R R/filters.R \
         R/users.R R/tos.R R/skins.R R/uiprefs.R R/skills.R R/nodes.R R/audit.R \
         R/logins.R R/teams.R R/share.R R/selfheal.R R/mail.R R/litsub.R \
         R/mod_welcome.R R/mod_admin.R R/mod_htadmin.R R/mod_backstage.R R/mod_prompt.R \
         R/mod_chat.R R/mod_tasks.R R/mod_files.R R/mod_envs.R R/mod_settings.R \
         R/mod_help.R \
         R/mod_model.R R/mod_skills.R R/mod_lit.R R/mod_forum.R \
         R/cloudtool.R R/cloudrun.R R/mod_cloudtool.R; do
  [ -f "$SRC/$f" ] || { red "✗ 源文件缺失：$f"; exit 1; }
done

# ⚠️ skills_builtin/ 是**目录**，不在上面那份文件清单里。V13 item 4 把 11 个
#    仓库的内容提炼成 md 放在那儿，由 dsapp_skills_builtin_md() 在启动时读。
#    它的失败方式和上面那些文件**不一样，但一样安静**：读不到就跳过那一篇
#    （故意的，见那个函数的说明），所以缺了整个目录的表现不是报错，而是
#    "设置页里内置技能少了十来条" —— 没人会因此怀疑部署。
if [ ! -d "$SRC/skills_builtin" ]; then
  red "✗ 源目录缺失：skills_builtin/（内置技能的正文都在这里）"
  exit 1
fi
N_MD=$(ls -1 "$SRC/skills_builtin"/*.md 2>/dev/null | wc -l)
[ "$N_MD" -gt 0 ] || { red "✗ skills_builtin/ 里一篇 .md 都没有"; exit 1; }
grn "✓ 源文件完整（内置技能 $N_MD 篇）"

# 离线自检：解析、模型目录、提示词分流、流式增量读取。
# 这些行为打开页面看不出来，坏了也不报错，只是结果不对 —— 值得每次部署前跑。
#
# ⚠️ 日志必须用 mktemp 建一个**属于本次调用**的文件，不能写死 /tmp/xxx.log。
#
#    写死路径踩过一次，代价是连续两次部署静默失败：开发机上以普通用户跑
#    `deploy.sh --check` 会建出 /tmp/dsapp_selftest.log 并归自己所有；之后
#    用 sudo 跑正式部署时，root 要往 sticky 的 /tmp 下覆盖一个**别人拥有的**
#    文件，内核的 fs.protected_regular 直接拒绝（Ubuntu 默认开）。重定向失败
#    让 Rscript 非零退出，脚本判定"自检未通过"并 exit 1 —— rsync 那一步根本
#    没走到，线上还是旧版本。
#
#    这个失败最坏的地方是**报错指向了错误的方向**：它说"自检未通过"，还会把
#    上一次残留的日志回显出来（满屏 ✓），让人以为是代码有问题，而不是怀疑
#    一个临时文件。所以这里顺带把真实原因也打出来。
ST_LOG="$(mktemp -t dsapp_selftest.XXXXXX.log)"
trap 'rm -f "$ST_LOG"' EXIT
# ⚠️ DSAPP_SKIP_SELFTEST=1 是给**自检自己**用的。
#    selftest.R 里有一条断言要跑 `deploy.sh --check` 去看它认不认软链 —— 而
#    deploy.sh 又会去跑 selftest.R。正常路径上不会转起来（那条断言用的 $DEST
#    是自指软链，闸门排在自检前面就 exit 1 了），但**闸门一旦被改坏**，就会
#    变成"自检 → 部署脚本 → 自检 → …"的无限递归：表现是测试挂死在那儿，
#    而不是干脆地报一条红。一个会挂死的测试比没有测试更糟，所以留这个开关。
if [ -z "${DSAPP_SKIP_SELFTEST:-}" ] && [ -f "$SRC/selftest.R" ]; then
  if (cd "$SRC" && Rscript selftest.R >"$ST_LOG" 2>&1); then
    grn "✓ 自检通过"
  else
    # ⚠️ 光 `tail` 是**不够**的：失败的行可能在任何位置，而末尾往往全是 ✓。
    #    2026-09-13 线上就栽在这上面 —— 自检 866 条，`tail -40` 打出来的全是
    #    绿色，真正的 2 条 ✗ 被截在屏幕外，只剩一句「自检未通过」，完全看不出
    #    哪里坏了。所以：先把所有 ✗ 原样打出来，再补一段尾部上下文。
    red "✗ 自检未通过："
    echo
    grep -n '✗' "$ST_LOG" | sed 's/^/    /' || true
    echo
    echo "  ---- 末尾 20 行 ----"
    sed 's/^/    /' "$ST_LOG" | tail -20
    # 这份日志**不删**：出错时它是唯一的线索，删掉等于逼人从头再跑一遍
    # （自检 866 条，跑一次好几分钟）。
    trap - EXIT
    echo
    ylw "  完整日志保留在：$ST_LOG"
    echo "  （想自己重跑：cd $SRC && Rscript selftest.R）"
    exit 1
  fi
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  hdr "检查完毕（--check 模式未改动任何文件）"
  exit 0
fi

# ---- 2. 同步 ----------------------------------------------------------------
hdr "同步到 $DEST"

mkdir -p "$DEST"

# --exclude data/ ：用户上传的文件、会话记录、执行产物都在这里，
#                  同步时绝不能删。--delete 只清理代码文件。
# --exclude .Renviron ：服务器专属配置，不被开发机上的版本覆盖。
#
# ⚠️ --exclude history_Version/ ：历史版本归档放在源码目录里面，**必须排掉**。
#    它长得像代码（app.R、R/、www/ 一应俱全），rsync 会老老实实全传上去，
#    线上就凭空多出好几份旧应用。更坏的是 `--delete` 的语义会让人以为
#    "线上=源码目录"，将来有人对着 /srv 下那份归档改代码，改的是死文件。
#    归档属于开发机，不属于线上。
#
# ⚠️ --exclude DS_App_V1_python/ ：V1 是 Shiny for Python 版，V5 起**已废弃**
#    （外网端口不方便转发，只维护 R 版）。它的目录结构和 R 版不同名，rsync
#    不会拿它覆盖任何东西，所以留着不致命 —— 但传上去就是又一个"对着死文件
#    改代码"的坑，而且它自带 requirements.txt，将来有人 pip install 一遍就
#    更乱。一并排掉。
#
# ⚠️ 另外三个（.claude/、tests/、deploy.sh 自己）同样是开发机的东西。
#    .claude/ 里是开发时留下的配置和记录；tests/ 是浏览器端回归脚本，
#    依赖 playwright，线上没有也不需要。deploy.sh 自己不必传 —— 传上去
#    以后有人对着 /srv 里那份跑，DEST 又会指回 /srv，白折腾一趟。
rsync -a --delete \
  --exclude 'data/' \
  --exclude '.Renviron' \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '*.log' \
  --exclude 'deploy/' \
  --exclude 'history_Version/' \
  --exclude 'DS_App_V1_python/' \
  --exclude '.claude/' \
  --exclude 'tests/' \
  --exclude 'deploy.sh' \
  "$SRC/" "$DEST/"

grn "✓ 代码已同步"

# ---- 3. 目录与权限 ----------------------------------------------------------
hdr "目录与权限"

# 应用以 shiny 身份运行，数据目录必须归它所有。
#   exports/    本地运行包（「设置 → 分析环境 → 本地电脑」导出用）
#   workspaces/ **每个对话一块地**，也是 V4 真正放环境的地方
#               （R 用 workspace/.Rlib，Python 用 workspace/.venv，首次执行时建）
#   envs/       全局 conda 环境目录。V4 按 item 4 撤掉了全局环境管理，
#               这里保留只是不让老部署的目录凭空消失
# app 启动时 dsapp_init_dirs() 也会建，这里先建一次是为了属主一致 ——
# 别让它由某个偶然的调用者建出来。
mkdir -p "$DEST/data"/{files,work,logs,run,envs,conda_pkgs,exports,workspaces}

# 整个应用目录归 shiny —— 与 /srv/shiny-server 下其他 19 个应用保持一致。
# 改代码请在开发目录改完再跑一次本脚本，不要直接在 /srv 下编辑。
chown -R shiny:shiny "$DEST"
chmod -R u+rwX,go+rX "$DEST"

# 上传的文件挂进工作目录时会 chmod 成 0444，所以 files/ 里的文件
# 是只读的 —— 这是有意的（见 R/executor.R 顶部说明）。

grn "✓ 权限已设置（shiny:shiny）"

if [ ! -f "$DEST/.Renviron" ]; then
  ylw "! 未发现 .Renviron，使用代码内置默认值"
  echo "  数据目录将落在 $DEST/data"
  echo "  如需自定义：cp $SRC/.Renviron.example $DEST/.Renviron && 编辑后重启"
fi

# ---- 4. 重启 ----------------------------------------------------------------
hdr "重启 Shiny Server"

if systemctl is-active --quiet shiny-server 2>/dev/null; then
  systemctl restart shiny-server
  sleep 4
  if systemctl is-active --quiet shiny-server; then
    grn "✓ shiny-server 已重启"
  else
    red "✗ shiny-server 启动失败，查看：journalctl -u shiny-server -n 50"
    exit 1
  fi
else
  ylw "! shiny-server 不在运行，跳过重启"
fi

# ---- 5. 验证 ----------------------------------------------------------------
hdr "验证"

# ⚠️ 同第 1 步：临时文件用 mktemp，别写死路径。
#    这个坑是**双向**的 —— 写死的 /tmp/dsapp_deploy_check.html 先被 sudo 建
#    成 root 所有，之后普通用户跑 --check 就覆盖不了它了。谁先跑谁把对方挡住。
HTML="$(mktemp -t dsapp_deploy_check.XXXXXX.html)"
trap 'rm -f "$ST_LOG" "$HTML"' EXIT

CODE=$(curl -s -o "$HTML" -w '%{http_code}' "$APP_URL" || echo "000")
if [ "$CODE" = "200" ]; then
  grn "✓ $APP_URL → HTTP 200"

  # 静态资源必须能取到，否则页面会是没有样式的白板
  for asset in app.css app.js; do
    AC=$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}${asset}")
    [ "$AC" = "200" ] && grn "  ✓ $asset" || red "  ✗ $asset → HTTP $AC"
  done

  # ⚠️ 这里原来 grep 首页 HTML 里的页签名（对话/任务/文件/环境/设置）。
  #    V5 起界面统一走 renderUI(output$app_root)，**整个在客户端渲染**，
  #    首页 HTML 只有 1KB 的 Shiny 脚手架，永远不会有这些字 —— 这条检查
  #    于是恒为假。2026-09-13 那次部署它报了 5 个 ✗，看着像页面没渲染出来，
  #    其实应用完全正常。**一个恒为假的检查比没有检查更糟**：它会训练人
  #    忽略红色输出。
  #
  #    换成问 SockJS 的 info 端点：这个应答来自**应用的 R 进程本身**，
  #    返回 JSON 才说明进程真的起来了。比 HTTP 200 强 —— 那个 200 是
  #    Shiny Server 给的空壳，底下的 R 进程挂了它照样 200。
  SOCK=$(curl -s -m 10 -w '\n%{http_code}' "${APP_URL}__sockjs__/info" 2>/dev/null || printf '000')
  SC=$(printf '%s' "$SOCK" | tail -1)
  if [ "$SC" = "200" ] && printf '%s' "$SOCK" | grep -q '"websocket"'; then
    grn "  ✓ 应用的 R 进程活着（SockJS 有应答）"
  else
    red "  ✗ 应用进程没有应答（HTTP ${SC}）—— 页面会是白板或一直转圈"
    echo "    排查：journalctl -u shiny-server -n 50"
    echo "          tail -50 /var/log/shiny-server/YCFS_APP-*.log"
  fi
else
  red "✗ $APP_URL → HTTP $CODE"
  echo "  排查："
  echo "    journalctl -u shiny-server -n 50"
  echo "    ls -la $DEST"
  exit 1
fi

hdr "完成"
# ⚠️ V17 item 5：这里原来把对外域名写死了，而本脚本是**要进公开仓库**的
#    （见 desktop/pack_github.sh 的清单）。改成回显本机地址 / 环境变量里
#    那个：域名只对内部发放，不进仓库。
echo "访问地址：${APP_URL}"
echo
echo "首次使用："
echo "  1. 打开「设置」页，选厂商并填入 API Key（只存在浏览器会话内存里）"
echo "     —— 各家的申请入口在设置页里有直达链接"
echo "  2. 到「文件」页上传数据（expr.csv、h5ad 之类）"
echo "  3. 回「对话」页描述分析需求即可 —— 执行环境由平台在后台自动准备，"
echo "     不需要你选，也不需要你配"
echo
echo "V5 要点："
echo "  - 进来先注册（昵称、邮箱、手机号、研究方向），之后这个浏览器自动登录，"
echo "    看到的都是自己的对话和任务；换电脑用「邮箱 + 恢复码/密码」找回"
echo "  - 每个对话一块自己的工作区和环境，首次执行代码时自动创建；"
echo "    「环境」页可以看到这个对话里已经装了什么"
echo "  - 对话里直接能看到这一轮产出的文件，可下载、可发布到共享区"
echo "  - 文件管理区【按账号隔离】（V13 item 6 起）：每个账号只看得到自己的。"
echo "    以前那块公用的内容还在 data/files/_anon/ 里，界面不再列它"
echo "  - 共享是【按对话】给的：对话页点「共享这个对话」，同组账号勾选、"
echo "    组外手填邮箱。团队只决定“默认列出谁”，不决定权限"
echo "  - 内置技能（V13 item 4）在「技能」页，带「内置」标记，可另存为我的"
echo "  - 「设置 → 分析环境」可切到本地电脑（导出运行包）或远程服务器（SSH）"
echo "  - 对话页的「⚡ 自动执行」默认关闭。打开后 AI 会自己跑代码、读回结果、"
echo "    接着做下一步，直到分析完成或需要你决策"
echo "  - 第一个注册的账号自动成为管理员（也可以由 DSAPP_ADMIN_EMAIL 指定），"
echo "    会多出一个「管理」页：用量、磁盘、用户停用/重置/删除、文件归属"
