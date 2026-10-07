#!/usr/bin/env bash
# =============================================================================
# 把仓库整理成**能推到 GitHub 的那一份**
# =============================================================================
#
#   bash desktop/pack_github.sh [输出目录]
#       默认输出到 ~/dsapp_build/github_YCFS_APP
#
# 产出：
#   <输出目录>/            一个干净的工作树（**不含**数据、密钥、桌面版大包）
#   <输出目录>/.gitignore  这份树自己的忽略表（写进去，不是从仓库拷）
#   <输出目录>/发布到GitHub.md   推之前先看这份
#
# 然后这个脚本会（如果机器上有 git）就地 `git init` + 一次初始提交。
# **它不联网、不碰 GitHub、不需要凭据** —— 推不推、推到哪，由你决定。
#
# ---- 为什么要单独走一遍，而不是直接 `git init` 在生产目录 ----------------
#
# 因为这个仓库**就是生产目录**（`/srv/shiny-server/YCFS_APP` 是指向它的软链），
# 于是同住着 29 GB 的运行数据、一组 SMTP 明文口令、以及 1.4 GB 的桌面版交付包。
# 在那种目录里 `git add -A` 是**一次不可撤销的泄露**：`git rm` 之后 blob 还在
# 对象库里，而 GitHub 那边可能已经被抓取。
#
# 所以这份脚本的做法是**白名单式地拷出去**，源目录一个字节都不动。
# 拷出去的那棵树里没有 `data/`，也就没有"手滑提交了生产库"这条路。
#
# ⚠️ 输出目录**必须为空或不存在**：脚本不覆盖已有的树（覆盖会让上一次的
#    残留混进这一次，而那正是"某次手滑提交了东西"最容易发生的地方）。
#    要重来就先自己把旧目录挪走 —— 本仓规矩：不替你 `rm`。
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/dsapp_build/github_YCFS_APP}"

VER="$(grep -oP 'DSAPP_VERSION\s*<-\s*"\K[^"]+' "$REPO/R/config.R" | head -1)"
[ -n "$VER" ] || { echo "读不到 R/config.R 里的 DSAPP_VERSION"; exit 1; }
echo "== 版本：$VER"
echo "== 源：$REPO"
echo "== 出：$OUT"

if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "!! $OUT 已经非空。先把它挪走再跑（我不替你删）。" >&2
  exit 1
fi
mkdir -p "$OUT"

# ⚠️⚠️ **尽早 cd 进输出目录**，后面所有相对路径和命令替换都在这里发生。
#    这不是整洁问题，是 2026-10-06 真出过事：`发布到GitHub.md` 那个 heredoc
#    用的是**不加引号**的定界符（`<<RELEASENOTE`，因为里面要展开 $VER / $OUT），
#    于是正文里**没转义的反引号会被当命令执行** —— 而当时 cwd 还是**生产仓库**。
#    那一行写的是「树已经 `git init` 并提交好了」，结果是：
#      · 每次跑打包，都在 `/data3/biomamba/analysis/DS_App/` 里跑一次 `git init`，
#        凭空造出一个空仓库（无提交、无 remote）；
#      · `git init` 的输出被**替换进了交付文件**，发布说明里那一句成了
#        「树已经 Reinitialized existing Git repository in /data3/.../.git/ 并提交好了」。
#    ⇒ 一是转义反引号，二是把 cd 提到最前面（万一以后又漏一个，也只炸输出树）。
#    ⚠️ 本仓另有一条同族的教训：判断 markdown 围栏时，**行中间的 ``` 永远不是围栏**。
cd "$OUT"

# ---- 要排除的，逐条写清理由 ------------------------------------------------
EX=(
  # 运行数据：生产库、上传文件、工作区、日志。29 GB，**绝对不能进公共仓库**。
  "--exclude=/data/"
  # 桌面版交付包 + 它的 tar。1.4 GB + 908 MB，走 GitHub Releases，不进仓库。
  "--exclude=/APP_PC/"
  "--exclude=/APP_PC.tar.gz"
  # 版本归档：54 份整树拷贝，358 MB。是**内部**历史，不是产品的一部分。
  "--exclude=/history_Version/"
  # Shiny 的 sass 缓存（属主是 shiny 用户），构建产物，不是源码。
  "--exclude=/app_cache/"
  # ★ 明文 SMTP 口令就在里面。模板 .Renviron.example 保留，真身永远不进仓库。
  "--exclude=/.Renviron"
  # 本机 Claude Code 的权限白名单，与项目无关。
  "--exclude=/.claude/"
  # ★ 源目录里的 .git（如果哪天有了）。**不能跟着拷** —— 拷过去之后脚本会
  #   看到 `[ -d .git ]` 成立、直接"已经有 .git，跳过 init"，于是输出树带着
  #   **源仓库的历史**被推上去，而不是这一份干净的初始提交。
  #   2026-10-06 就是这么发现源目录里有个空 `.git` 的（是上面那条反引号 bug
  #   造出来的）：输出树里出现了 `.git` 却没有提交。两个 bug 叠在一起才显形。
  "--exclude=/.git"
  # ⚠️ V13 以前的扁平布局残留（2026-09-16 的 R 文件副本），早被 R/ 取代。
  #    37 个文件、全是死代码。2026-10-06 改这份 EX 表时它被误删过一次，
  #    结果那 37 个文件**混进了要推 GitHub 的树**（是拿两次打包的树做 diff
  #    才看出来的：`19a20,56` 多出 37 行）。改这张表之后**务必 diff 一次
  #    前后两棵树**，别只看脚本自己那几行自检 —— 它只查它知道要查的东西。
  "--exclude=/mod_chat.R/"
  # ★ 13 MB 的**第三方教学 HTML**（`RFdiffusion3+MPNN+RoseTTAFold 3 的全流程
  #   教学_修订版_plus(2).html`）—— 用户 2026-10-02 给的参考资料，不是我们的
  #   东西，也不是应用本体。**不进公共仓库**：公开分发别家的教学材料有版权
  #   风险，而且它一个人占了整棵树的一半体积。
  #   ⚠️ 但**目录本身要有** —— `R/cloudtool.R` 的 `dsapp_cloud_eval_script()` 会去
  #   `cloud_tool/evaluate_rf3.py` 找配套脚本（找不到会明说"放哪儿"）。
  #   所以下面会**生成**一份 `cloud_tool/README.md` 当路标，内容我们自己写。
  #   归档那边（`history_Version/archive.sh` 的 SKIP 表）早就不收它，口径一致。
  "--exclude=/cloud_tool/"
  # 一个 bug 截图，不属于要发布的源码。
  "--exclude=/bug/"
  # 杂项
  "--exclude=/.Rhistory" "--exclude=/.RData" "--exclude=/.Rproj.user"
  "--exclude=__pycache__/" "--exclude=*.pyc" "--exclude=*.log"
  "--exclude=/.DS_Store" "--exclude=Thumbs.db"
  # ★ 2026-10-07 加的：改脚本时留下的**临时备份**被原样扛进树里了（7 个
  #   `*.bak-20261007`，差点跟着推上公开仓库）。源目录里当时只有我自己的
  #   这几个，没有别的文件匹配这些模式，所以排掉不会误伤。
  "--exclude=*.bak" "--exclude=*.bak-*" "--exclude=*~"
  "--exclude=*.orig" "--exclude=*.rej" "--exclude=*.swp"
)

echo "== 拷贝（白名单式排除，源目录不动）"
rsync -a --delete "${EX[@]}" "$REPO/" "$OUT/"

# ---- .gitignore：写进这棵树，不从仓库拷 ------------------------------------
# 内容刻意和上面的 EX 对齐：这棵树将来要是被当成普通目录用（有人在里面跑
# 应用、跑自检），那些会重新长出来的东西也不该被提交。
cat > "$OUT/.gitignore" <<'GITIGNORE'
# ---- 运行数据（29 GB，绝对不能进）-----------------------------------------
data/
*.sqlite3
*.sqlite3-wal
*.sqlite3-shm

# ---- 凭据 ------------------------------------------------------------------
.Renviron
.keyring
*.pem
*.key

# ---- 交付包 / 构建产物 ------------------------------------------------------
APP_PC/
APP_PC.tar.gz
*.zip
*.rds
app_cache/
dl/

# ---- 版本归档（内部历史，358 MB）-------------------------------------------
history_Version/

# ---- 本机工具 --------------------------------------------------------------
.claude/
mod_chat.R/
bug/

# ---- 第三方教学材料（不是我们的东西，也不进公共仓库）----------------------
cloud_tool/*.html
cloud_tool/*.htm
cloud_tool/*.pdf
.Rhistory
.RData
.Rproj.user

# ---- 杂项 ------------------------------------------------------------------
__pycache__/
*.pyc
*.log
.DS_Store
Thumbs.db
GITIGNORE

# ---- 发布说明：写进这棵树，推之前照着做 --------------------------------
cat > "$OUT/发布到GitHub.md" <<RELEASENOTE
# 推到 GitHub（$VER）

这份是**操作单**，照着做即可。树已经 \`git init\` 并提交好了，只差建仓库和推。

## 一、仓库里放什么

这个仓库 = **Shiny 版**（线上那套的应用本体 + 部署脚本 + 打包工具链 + 自检）。
用户要的三样东西是这样分布的：

| 交付物 | 放在哪 |
|---|---|
| **Shiny 版**（源码，可自建服务器 / 可审计） | 就是这个仓库本身 |
| **Windows 版** | Releases 附件 \`DS_App-Windows-$VER.zip\` |
| **macOS 版** | Releases 附件 \`DS_App-macOS-arm64-$VER.zip\`、\`DS_App-macOS-x86_64-$VER.zip\` |

⚠️ **桌面版的 zip 不要提交进仓库**（每个 150~170 MB，三个加起来 460 MB）。
GitHub 单文件限 100 MB，仓库也不该背这个重量 —— 走 Releases。
\`.gitignore\` 里已经写了 \`*.zip\`，双保险。

## 二、推

⚠️ **不要在打包机上跑 \`git push\`。** 2026-10-07 实测：那台机器到
\`github.com\` 的 TCP 成功率只有 3/8，\`git push\` 会一直等到超时再退出
（exit 124）；而到 \`api.github.com\` 又快又稳。所以推的是 **Git API**，
既不是 ssh、也不是 git 的 https 传输。

\`\`\`bash
# 1) 先在 GitHub 上建一个**空**仓库：Biomamba/YCFS_APP
#    不要勾 "Add a README" / ".gitignore" / "license"（勾了要先 pull）
# 2) 装凭据（只需一次；token 在**你自己的终端**里粘贴，不回显、不进历史）
bash desktop/setup_github_cred.sh
# 3) 推
python3 desktop/push_via_api.py $OUT --force
\`\`\`

\`--force\` 在这条路上是**快进**，不是覆盖：脚本建的新提交以远端现有提交为
**父提交**，旧提交仍在历史里（只是不再是分支尖）。
推完脚本会自己回读一次 ref 并核对 tree sha —— 看到 \`一致 ✓\` 才算成。

## 三、发 Release

Releases → **Draft a new release**

- **Tag**：\`$VER\`（点 "Create new tag on publish"）
- **Title**：\`$VER\`
- **附件**：把 \`~/dsapp_build/release_$VER/\` 里这三个传上去
  - \`DS_App-Windows-$VER.zip\`
  - \`DS_App-macOS-arm64-$VER.zip\`
  - \`DS_App-macOS-x86_64-$VER.zip\`
  - \`SHA256SUMS.txt\`（顺手传，用户能自己对校验和）

Release 正文可以直接抄 \`交付说明.txt\`（打包脚本生成的那份，就在 release 目录里）——
里面有三个包的字节数、自检项数、以及"用户怎么用"（含杀软/Gatekeeper 的放行步骤）。

## 四、发完核对三件事

1. 仓库首页的 README 渲染正常（表格、徽章、链接不是裸文本）。
2. 应用页脚那个「获取最新版」指向 \`https://github.com/Biomamba/YCFS_APP\`
   （单一真相源在 \`R/config.R:DSAPP_RELEASE_URL\`）—— 点一下，**别是 404**。
   ⚠️ 这个链接**随桌面包一起发出去**：包一旦出门，链接就改不动了，所以
   仓库地址必须是最终的那个。
3. Releases 里三个 zip 能下载，大小和 \`SHA256SUMS.txt\` 对得上。

## 五、这一版的坑（发给用户时值得写进 Release 正文）

- Windows/macOS 都**没有代码签名**，首次打开会被 SmartScreen / Gatekeeper 拦。
  放行方法在 README 的下载章节里，Release 正文里也该重复一遍。
- macOS 包里用了符号链接省空间，**必须发 zip**（用 \`zip -y\` 打的），
  不要发解开的文件夹 —— 某些传输方式会把符号链接变成副本或直接丢掉，
  用户那边就是双击没反应。
RELEASENOTE

# ---- cloud_tool/：只留我们自己写的路标，不留第三方材料 --------------------
# `R/cloudtool.R` 会去这个目录找配套脚本 `evaluate_rf3.py`。目录不能空着
# 不见，否则从 GitHub 部署的人不知道往哪放；但也**不能把那份 13 MB 教学
# HTML 一起发出去**（见上面 EX 里的理由）。
mkdir -p "$OUT/cloud_tool"
cat > "$OUT/cloud_tool/README.md" <<'CLOUDTOOL'
# cloud_tool/ —— 配套脚本的**替换位**

这个目录是**约定位置**，不是代码。找脚本的规则在 `R/cloudtool.R` 的
`dsapp_cloud_eval_script()` 里，它按顺序找这**四**个地方：

1. `$DSAPP_CLOUD_SCRIPT_DIR/evaluate_rf3.py`（运维放的，优先级最高）
2. `<应用目录>/tools/Protein_Design/evaluate_rf3.py` —— **正本在这里**，
   跟着仓库走（也进版本归档）
3. **本目录** `cloud_tool/evaluate_rf3.py`
4. `<应用目录>/script/evaluate_rf3.py`

要换一份自己的 `evaluate_rf3.py`，放进**本目录**（或者设
`DSAPP_CLOUD_SCRIPT_DIR`）就会盖过仓库里那份 —— 不必改仓库。

找不到时界面会在**点按钮之前**的体检里明说缺什么、该放哪儿（见
`dsapp_cloud_preflight()`），不会等跑了几分钟才炸。

> 目录里**不要**放第三方教学材料（那份教学 HTML 有版权顾虑，也不该占
> 半个仓库的体积）。提取出来的规格已经写在 `R/cloudtool.R` 的注释里了。
CLOUDTOOL

# ---- 自检：这棵树里不许有数据、不许有口令 --------------------------------
fail=0
if [ -d "$OUT/data" ]; then echo "!! 树里有 data/"; fail=1; fi
if find "$OUT/cloud_tool" -name '*.html' 2>/dev/null | grep -q .; then
  echo "!! cloud_tool/ 里有 HTML（第三方教学材料不该跟着走）"; fail=1
fi
if [ -e "$OUT/.Renviron" ]; then echo "!! 树里有 .Renviron"; fail=1; fi
if [ -d "$OUT/APP_PC" ]; then echo "!! 树里有 APP_PC/"; fail=1; fi
if [ -d "$OUT/history_Version" ]; then echo "!! 树里有 history_Version/"; fail=1; fi
if [ -d "$OUT/mod_chat.R" ]; then echo "!! 树里有 mod_chat.R/（死代码）"; fail=1; fi

# ★ 反引号体检：`发布到GitHub.md` 的定界符不加引号（正文要展开 $VER/$OUT），
#   所以里面**没转义的反引号会被当命令执行**。2026-10-06 就是这么在生产仓库里
#   跑了一次 `git init`，还把那句话的输出替换进了交付文件。
#   这里钉住"那一行的正文必须原样带反引号"——再有人加 markdown 时漏了转义，
#   这一条会红，而不是让某个命令在源目录里悄悄跑掉。
if ! grep -qF '`git init`' "$OUT/发布到GitHub.md"; then
  echo "!! 发布到GitHub.md 里的 \`git init\` 没原样出现 —— 多半是被当成命令执行掉了"
  grep -n '操作单' "$OUT/发布到GitHub.md" | head -2
  fail=1
fi
# 同族的兜底：交付文件里不该出现任何"命令的输出"味道的东西
if grep -qF 'Git repository in' "$OUT/发布到GitHub.md"; then
  echo "!! 发布到GitHub.md 里混进了 git 的输出（反引号被执行了）"; fail=1
fi
if [ "$fail" = 1 ]; then echo "!! 排除不干净，**不要推**"; exit 1; fi

# ⚠️ 光看目录名不够：口令本身要在**全树正文**里搜一遍。2026-10-06 加这一条，
#    是因为"删掉 .Renviron"只挡住了它自己 —— 一份被拷进别处的副本、
#    或某个验收脚本里写死的一次性口令，都不会因为源文件被排除而消失。
PW="$(grep -oP '^DSAPP_SMTP_PASS=\K.*' "$REPO/.Renviron" 2>/dev/null | head -1 || true)"
if [ -n "$PW" ] && grep -rqF "$PW" "$OUT" 2>/dev/null; then
  echo "!! 树里搜到了 .Renviron 里的 SMTP 口令，**不要推**"
  grep -rlF "$PW" "$OUT" 2>/dev/null | head -5
  exit 1
fi

echo "== 自检通过：无 data/ 、无 .Renviron 、无口令、无大包"
echo "== 树大小：$(du -sh "$OUT" | cut -f1)   文件数：$(find "$OUT" -type f | wc -l)"

# ---- 顺带核对：PC 包在不在、是不是同一个版本 ------------------------------
REL="$HOME/dsapp_build/release_${VER}"
echo
echo "== PC 包（走 Releases，不进仓库）"
if [ -d "$REL" ]; then
  ls -1 "$REL" 2>/dev/null | sed 's/^/   /'
else
  echo "   ⚠️ 还没打：$REL 不存在 —— 先跑 desktop/build_windows_bundle.sh 和"
  echo "      desktop/build_macos_bundle.sh（arm64 / x86_64 各一次）"
fi

# ---- git init（不联网）----------------------------------------------------
if command -v git >/dev/null 2>&1; then
  cd "$OUT"
  if [ ! -d .git ]; then
    git init -q -b main 2>/dev/null || git init -q
    git config user.name  >/dev/null 2>&1 || git config user.name  "YCFS_APP"
    git config user.email >/dev/null 2>&1 || git config user.email "biomamba@biomamba.com.cn"
    git add -A
    git -c commit.gpgsign=false commit -q -m "YCFS_APP ${VER}：言出法随生信分析 Agent（R Shiny）

首个公开版本。包含：
  · Shiny 版应用本体（app.R + R/ + www/ + skills_builtin/）
  · 部署脚本与文档（deploy.sh / DEPLOYMENT.md / SYNC.md）
  · 桌面版打包工具链（desktop/，Windows 与 macOS）
  · 自检与浏览器验收（selftest.R / tests/）

桌面版的成品包（Windows / macOS arm64 / x86_64）在 Releases 里，不在仓库内。" || {
      echo "!! 提交失败，看上面的报错"; exit 1; }
    echo "== 已 git init 并做了一次初始提交（未推送）"
    git log --oneline -1 | sed 's/^/   /'
  else
    echo "== 已经有 .git，跳过 init"
  fi
fi

cat <<EOF

== 完成。接下来：

  1. 在 GitHub 上建一个**空**仓库：Biomamba/YCFS_APP（不要勾 README/.gitignore）
  2. cd $OUT
     git remote add origin git@github.com:Biomamba/YCFS_APP.git   # 或 https 那个
     git push -u origin main
  3. Releases → Draft a new release → tag 填 $VER
     附件上传 $REL/ 里那三个 zip
  4. 仓库根 README 里的徽章、Releases 链接都写成这个仓库，确认一眼

⚠️ 推之前先看 $OUT/发布到GitHub.md。
EOF
