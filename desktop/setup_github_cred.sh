#!/usr/bin/env bash
# =============================================================================
# 把 GitHub 的推送凭据装好（Fine-grained PAT + HTTPS）
# =============================================================================
#
#   bash desktop/setup_github_cred.sh
#
# ---- 为什么走 HTTPS 而不是 SSH ----------------------------------------------
#
# 2026-10-07 先试的是 SSH 公钥，用户名下粘贴时被 GitHub 判 "Key is invalid"。
# 密钥本身验过是好的（51 字节的合法 ed25519 blob，`ssh-keygen -lf` 读得出
# 指纹），所以是**拷贝那一段**把长 base64 弄坏了 —— 68 个字符中间没有空格，
# 网页软换行一拖选就带进一个真换行。
#
# HTTPS 那条路把"长字符串"从**浏览器**挪到了**终端**：终端粘贴不会插换行，
# 而 `read -s` 连回显都没有（不留在屏幕、不进 shell 历史、不进会话记录）。
#
# ---- 这个脚本会做什么 --------------------------------------------------------
#
#   1. 静默读 token（不回显、不落 shell 历史）；
#   2. **先验后用**：打 api.github.com 确认 ① token 有效 ② 能看见目标仓库
#      ③ 权限里 contents 是 write。验不过就当场停，什么都不写；
#   3. 写 ~/.dsapp_gh_cred（chmod 600），配 git 的 credential.helper 指向它；
#   4. 拿 `git ls-remote` 再走一遍**真正的 git 认证**（API 通不等于 git 通，
#      token 少了 workflow scope 这类问题就在这一步才现形）。
#
# ⚠️ 不把 token 写进 `git remote` 的 URL 里。那种写法 `ps` 看得到、出错时
#    会连着 URL 一起打进日志，而且 `git remote -v` 一敲就露。凭据必须走
#    helper。
#
# ⚠️ credential.helper 配的是 **--global**：输出树是 `pack_github.sh` 每次
#    重新 `git init` 出来的，配在仓库局部的话重打一次就没了。风险可控 ——
#    fine-grained PAT 只授权了 YCFS_APP 这一个仓库，别的仓库拿它也没用。
#
# ---- 跑完之后 ----------------------------------------------------------------
#
#   · 撤销：去 https://github.com/settings/personal-access-tokens 删掉那个
#     token，再 `rm ~/.dsapp_gh_cred`（本仓规矩我不替你 rm）。
#   · 想换 token：重跑这个脚本，它会覆盖。
# =============================================================================
set -euo pipefail

OWNER_REPO="Biomamba/YCFS_APP"
TREE="${DSAPP_GIT_TREE:-$HOME/dsapp_build/github_YCFS_APP}"
CRED="$HOME/.dsapp_gh_cred"

say() { printf '\033[36m==\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[31m ✗\033[0m %s\n' "$*" >&2; }
die() { bad "$*"; exit 1; }

# ---- 1. 静默读 token ---------------------------------------------------------
if [ ! -t 0 ]; then
  die "这个脚本要从终端读 token（read -s），当前 stdin 不是终端。
     在**你自己的终端**里跑；或者先把 token 写进一个文件再 DSAPP_GH_TOKEN_FILE=... 跑。"
fi

TOKEN=""
if [ -n "${DSAPP_GH_TOKEN_FILE:-}" ]; then
  [ -f "$DSAPP_GH_TOKEN_FILE" ] || die "没有 $DSAPP_GH_TOKEN_FILE"
  TOKEN="$(tr -d ' \t\r\n' < "$DSAPP_GH_TOKEN_FILE")"
  say "从 $DSAPP_GH_TOKEN_FILE 读入 token（%d 个字符）" "${#TOKEN}"
else
  printf '把 GitHub token 粘进来，然后回车（不回显、不留在历史里）：\n> '
  read -rs TOKEN
  printf '\n'
  # 终端粘贴偶尔会带进空白/换行，去掉；长度是判"粘全了没有"最便宜的判据。
  TOKEN="$(printf '%s' "$TOKEN" | tr -d ' \t\r\n')"
fi
[ -n "$TOKEN" ] || die "没读到东西。"
say "token 长度 %d 个字符" "${#TOKEN}"

# ---- 2. 先验后用 -------------------------------------------------------------
say "验 token（不写任何东西）"
API="https://api.github.com"

code="$(curl -sS -o /tmp/.dsapp_gh_user.json -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
        "$API/user" || echo 000)"
if [ "$code" != "200" ]; then
  sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/   GitHub 说：\1/p' \
      /tmp/.dsapp_gh_user.json 2>/dev/null || true
  die "token 无效（HTTP $code）。是不是没过期、粘贴时少了字符？"
fi
LOGIN="$(sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/.dsapp_gh_user.json | head -1)"
ok "token 有效，身份是 $LOGIN"

code="$(curl -sS -o /tmp/.dsapp_gh_repo.json -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
        "$API/repos/$OWNER_REPO" || echo 000)"
[ "$code" = "200" ] || die "token 看不见 $OWNER_REPO（HTTP $code）。
     fine-grained token 要在 Repository access 里勾上这个仓库。"
ok "能看见 $OWNER_REPO"

# 权限：fine-grained token 会在仓库对象里回一个 permissions 块。
# ⚠️ 这个块只反映**这个 token 实际生效的**权限，比"我勾了"可信。
if grep -q '"push"[[:space:]]*:[[:space:]]*true' /tmp/.dsapp_gh_repo.json; then
  ok "push 权限：有"
else
  die "$LOGIN 对 $OWNER_REPO 没有 push 权限。
     去 token 设置里把 Contents 改成 Read and write。"
fi

# ---- 3. 装凭据 ---------------------------------------------------------------
umask 077
printf 'https://%s:%s@github.com\n' "$LOGIN" "$TOKEN" > "$CRED"
chmod 600 "$CRED"
ok "写好 $CRED（chmod 600）"

git config --global credential.helper "store --file=$CRED"
ok "credential.helper → store --file=$CRED（--global）"

# ⚠️ 这里**故意不打印** `git config --global --list`：那会把整行凭据路径
#    打出来（虽然没有 token 本身，但没必要）。

# ---- 4. 走一遍真正的 git 认证 -------------------------------------------------
if [ -d "$TREE/.git" ]; then
  say "用真 git 试一次（$TREE）"
  git -C "$TREE" remote set-url origin "https://github.com/$OWNER_REPO.git"
  if out="$(git -C "$TREE" ls-remote --heads origin 2>&1)"; then
    ok "git ls-remote 通了"
    if [ -n "$out" ]; then
      printf '   远端现有分支：\n'; printf '%s\n' "$out" | sed 's/^/     /'
    else
      printf '   远端是空仓库（一个分支都没有）—— 和之前查到的一致\n'
    fi
  else
    bad "git 认证没过："
    printf '%s\n' "$out" | sed 's/^/     /'
    cat >&2 <<'EOS'

   常见的两种：
     · "could not read Username" —— helper 没生效，检查
       git config --global --get-all credential.helper
     · "remote: Permission to ... denied" —— token 的 Contents 不是 write，
       或者 Repository access 没勾这个仓库（fine-grained token 默认是
       "Public repositories only"，而本仓库恰好是公开的，所以这一条**不会
       报权限错、只会表现为推不上去**）。
EOS
    exit 1
  fi
else
  say "（$TREE 还不是 git 仓库，跳过 git 实测 —— 跑完 pack_github.sh 再验）"
fi

echo
ok "凭据装好了。接下来我这边就能推了。"
echo "   撤销：GitHub 上删 token + 手动 rm $CRED"
