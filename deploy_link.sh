#!/bin/bash
# =============================================================================
# 把 Shiny 的应用目录换成指向**这个文件夹**的软链（V5 item 8）
# =============================================================================
#   sudo bash deploy_link.sh              # 换软链 + 退役旧地址 + 重启 + 验证
#   sudo bash deploy_link.sh --check      # 只体检，不动任何东西
#   sudo bash deploy_link.sh --keep-v1    # 不停那三个 V1 留下的 systemd 单元
#   sudo bash deploy_link.sh --keep-old   # 保留旧地址 /srv/shiny-server/DS_App
#
# 和 deploy.sh 的区别：
#   deploy.sh      —— rsync 一份副本到 /srv/shiny-server/YCFS_APP，两份文件
#   deploy_link.sh —— /srv/shiny-server/YCFS_APP 变成指向本目录的软链，**只有一份**
#
# 为什么要换成软链：用户在开发目录里改的代码，重启就是线上，不用再"改完记得
# 部署一次"。代价是**开发目录从此就是生产目录** —— 在这里 rm 一个文件，
# 线上立刻少一个文件。改坏了要回滚，见脚本末尾打印的那两行命令。
#
# ⚠️ 换软链之前必须先把旧目录里的 data/ 搬过来。旧目录一旦被 mv 走，软链指向
#    的新目录如果没有 data/，应用会**建一个空库** —— 表现是"所有账号都没了、
#    对话全空了"，而数据其实还在旁边那个 .pre_v5_* 里躺着。这个脚本因此
#    **拒绝在没有 data/ 的情况下开跑**（除非给 --allow-empty-data）。
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ★ V13.7 item 8：目录名从 DS_App 改成 YCFS_APP。
#
# ⚠️ 这两个变量的值**就是 URL 路径**：Shiny Server 的配置是
#    `location /` + `site_dir /srv/shiny-server`，它对每个子目录按**目录名**
#    挂一个 app，所以 `http://<host>:34038/DS_App/` 里的 `DS_App` 不是一个
#    应用内的设置，而是软链自己的名字。改 URL = 改这里的目录名 + 重启。
#
# ⚠️ 换了名字**不会**让旧地址自动 404：旧的 `/srv/shiny-server/DS_App` 软链
#    如果还在，它照样能用 —— 而两个 URL 就是**两个 R 进程**，同一份库。
#    单端登录是"一个账号一行 login_sessions"，两边会互相把对方顶下线。
#    ★ V13.11 item 13 起，本脚本会顺手把这条旧软链删掉（见下面 2b 段）；
#    想留着就加 --keep-old。删的是软链，目标目录和数据都不受影响。
DEST="${DSAPP_DEST:-/srv/shiny-server/YCFS_APP}"
APP_URL="${DSAPP_URL:-http://127.0.0.1:34038/YCFS_APP/}"
STAMP="$(date +%Y%m%d%H%M%S)"
CHECK_ONLY=0
KEEP_V1=0
KEEP_OLD=0
ALLOW_EMPTY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --keep-v1) KEEP_V1=1 ;;
    --keep-old) KEEP_OLD=1 ;;
    --allow-empty-data) ALLOW_EMPTY=1 ;;
    *) echo "未知参数：$a"; exit 2 ;;
  esac
done

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  red "✗ 需要 root：sudo bash deploy_link.sh"
  echo "  （/srv/shiny-server 归 shiny:shiny 所有，普通用户换不了里面的东西）"
  exit 1
fi

# ---- 0. 换软链的前提：新目录得是一份能跑的应用 ------------------------------
hdr "前提检查"

if [ ! -f "$SRC/app.R" ]; then
  red "✗ 这里不像应用目录（没有 app.R）：$SRC"; exit 1
fi
grn "✓ 应用目录：$SRC"

if [ ! -d "$SRC/data" ]; then
  if [ "$ALLOW_EMPTY" -eq 1 ]; then
    ylw "! 没有 data/ —— 按 --allow-empty-data 继续，应用会建一个空库"
  else
    red "✗ 没有 data/ —— 换过去会让应用建一个**空库**，账号和对话全不见"
    echo "  先把它准备好："
    echo "    rsync -a --exclude 'logs/' $DEST/data/ $SRC/data/"
    echo "  确认过确实要从零开始，再加 --allow-empty-data"
    exit 1
  fi
fi
[ -f "$SRC/data/dsapp.sqlite3" ] && grn "✓ 数据库在位（$(stat -c%s "$SRC/data/dsapp.sqlite3") 字节）" \
  || ylw "! 没有 data/dsapp.sqlite3，应用首次启动会新建"

# ⚠️ DSAPP_SKIP_SELFTEST=1 是给**自检自己**用的，和 deploy.sh 里那个同一个道理。
#    ★ V13.11 item 13 起，selftest.R 里有一条断言要真的跑一次
#    `deploy_link.sh --check`（去验 2b 那段认不认得出旧地址），而本脚本又会去
#    跑 selftest.R —— 不加这个开关就是"自检 → 部署脚本 → 自检 → …"挂死。
#    一条会挂死的测试比没有测试更糟。
#
# 自检：源码层面能查的错都在里面。--check 也跑（这正是它存在的意义）。
if [ -z "${DSAPP_SKIP_SELFTEST:-}" ] && [ -f "$SRC/selftest.R" ]; then
  ST_LOG="$(mktemp -t dsapp_link_selftest.XXXXXX.log)"
  if (cd "$SRC" && Rscript selftest.R >"$ST_LOG" 2>&1); then
    grn "✓ 自检通过（$(grep -c '✓' "$ST_LOG") 条）"
    rm -f "$ST_LOG"
  else
    red "✗ 自检未通过："
    grep -n '✗' "$ST_LOG" | sed 's/^/    /' || true
    echo "  ---- 末尾 20 行 ----"
    sed 's/^/    /' "$ST_LOG" | tail -20
    ylw "  完整日志：$ST_LOG"
    exit 1
  fi
fi

# ---- 1. 数据目录的权限 ------------------------------------------------------
# 应用以 shiny 身份跑，数据目录必须它能写。用 ACL 而不是 chown：
#   · 属主还是 biomamba，你在开发目录里照样能直接看库、清文件；
#   · 不动 other 位，不给"系统里任何其他用户"开门。
# -d（default）那一条是给**将来新建的**文件用的 —— 少了它，应用新建的
# 工作区目录又变成 shiny 写不进去。
hdr "数据目录权限"
DAT="$SRC/data"
OWNER="${SUDO_USER:-biomamba}"
if [ "$CHECK_ONLY" -eq 1 ]; then
  # --check 承诺"不动任何东西"，所以这里只报现状、不改。查当前的 ACL。
  if command -v getfacl >/dev/null; then
    if getfacl -p "$DAT" 2>/dev/null | grep -q '^user:shiny:'; then
      grn "✓ data/ 已经给 shiny 授了权（--check 不改动）"
    else
      ylw "! data/ 还没有 shiny 的 ACL —— 正式跑的时候会设上"
    fi
  else
    ylw "! 没有 getfacl，查不了"
  fi
else
  mkdir -p "$DAT"/{files,work,logs,run,envs,conda_pkgs,exports,workspaces}
  if command -v setfacl >/dev/null; then
    # 6 个 root 所有的日志文件会让 setfacl 返回非零（它们是 V1 的 systemd 单元
    # 写的，见下一步）。那不是失败，别让它把整个脚本带停。
    setfacl -R  -m u:shiny:rwX -m u:"$OWNER":rwX "$DAT" || true
    setfacl -R -d -m u:shiny:rwX -m u:"$OWNER":rwX "$DAT" || true
    grn "✓ ACL 已设置（shiny 与 $OWNER 都有读写权）"
  else
    ylw "! 没有 setfacl，退化成 chown shiny:shiny"
    chown -R shiny:shiny "$DAT"
  fi
fi

# 真的以 shiny 身份试写一次。**这一步不能省**：ACL 看着对、路径上某一层
# 没有 o+x 的时候，应用起得来但一写库就报错，而报错在浏览器里只显示
# "与服务器的连接断了"。
if [ "$CHECK_ONLY" -eq 0 ]; then
  probe="$DAT/.dsapp_write_probe.$$"
  if runuser -u shiny -- touch "$probe" 2>/dev/null; then
    rm -f "$probe"; grn "✓ shiny 用户能往 data/ 里写东西"
  else
    red "✗ shiny 用户写不了 $DAT —— 应用能起来但一保存就失败"
    echo "  查：namei -l $DAT"
    exit 1
  fi
fi

# ---- 2. V1 留下的三个 systemd 单元 ------------------------------------------
# dsapp-web / dsapp-worker@1 / dsapp-worker@2 是 Shiny for Python 时代（V1）的
# 单元，指向已经不存在的 app.py。它们正处于 auto-restart 崩溃循环里，以 root
# 身份每几秒往 data/logs/ 写一次报错 —— 已经攒了几 M，而且会一直涨。
# 不处理的话，"data/logs 越来越大"这件事会被误认为是新版本的问题。
hdr "V1 遗留的 systemd 单元"
if [ "$KEEP_V1" -eq 1 ]; then
  ylw "! 按 --keep-v1 跳过"
elif ! command -v systemctl >/dev/null; then
  ylw "! 没有 systemctl，跳过"
else
  # ⚠️ 要查**两处**。2026-09-14 实测：dsapp-worker@1/@2 是模板单元
  #    dsapp-worker@.service 的实例，而 list-unit-files 只认模板本身
  #    （显示成 `indirect`），拿 "dsapp-worker@1.service" 去查是空的 ——
  #    于是脚本会漏掉两个正在崩溃重启的 worker，只报 web 那一个。
  #    list-units --all 才看得到实例。
  # ⚠️ `|| true` 不能省。这两条命令在 systemd 够不着的地方（没有 dbus 的
  #    容器、user namespace 里的假 root、systemctl 被换掉）会**非零退出**，
  #    而它们在 `set -e` 下是赋值语句 —— 症状是整个部署脚本在这里**一声不吭
  #    地中止**，最后一行停在「== V1 遗留的 systemd 单元 ==」，什么原因都不说。
  #    2026-09-24 实测：这一步正是自检里那两条行为测在 `unshare -r` 下变红的
  #    原因，查了半天才发现不是断言的错、是脚本自己死在这儿。
  #    "查不到单元"本身不该阻止部署 —— 顶多是少停一个 V1 的老服务。
  UNITS=""
  for u in dsapp-web.service dsapp-worker@1.service dsapp-worker@2.service; do
    listed="$(systemctl list-unit-files "$u" --no-legend 2>/dev/null || true)"
    loaded="$(systemctl list-units --all "$u" --no-legend 2>/dev/null || true)"
    if [ -n "$listed" ] || [ -n "$loaded" ]; then
      UNITS="$UNITS $u"
    fi
  done
  if [ -z "$UNITS" ]; then
    grn "✓ 没有这几个单元"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    ylw "! 发现：$UNITS（正在崩溃重启，--check 没动它们）"
    echo "  它们是 V1（Python 版）的，日志写进 $DAT/logs/"
    echo "  正式跑的时候会 disable --now 掉它们"
  else
    ylw "! 发现：$UNITS"
    echo "  它们是 V1（Python 版）的，正在崩溃重启，日志写进 $DAT/logs/"
    # disable --now 是可逆的：想恢复就 systemctl enable --now <名字>。
    # 只停不删 —— 单元文件留在 /etc/systemd/system/ 里，随时能看、能恢复。
    for u in $UNITS; do
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    still="$(systemctl list-units --no-legend ${UNITS} 2>/dev/null | grep -c 'running\|activating' || true)"
    if [ "${still:-0}" = "0" ]; then
      grn "✓ 已停用（单元文件保留，恢复：systemctl enable --now <名字>）"
      # 这几个日志是 root 写的，普通用户删不掉；顺手清掉，免得管理页把
      # "8 M 的报错"算成应用的磁盘占用。
      rm -f "$DAT"/logs/web.err "$DAT"/logs/web.out \
            "$DAT"/logs/worker-1.err "$DAT"/logs/worker-1.out \
            "$DAT"/logs/worker-2.err "$DAT"/logs/worker-2.out 2>/dev/null || true
    else
      ylw "! 还有在跑的，重启后自己看一眼：systemctl status $UNITS"
    fi
  fi
fi

# ---- 2b. 旧地址还活着吗 -----------------------------------------------------
#
# ★ V13.11 item 13：光建新软链不够。旧的 /srv/shiny-server/DS_App 只要还在，
#    它就是一个**同样能用**的地址 —— 两个 URL 拉起两个 R 进程，读同一份库，
#    而单端登录是"一个账号一行 login_sessions"：两边会互相把对方顶下线，
#    症状是"莫名其妙要我重新登录"。用户改完名第一眼看到的也是旧地址还能开，
#    会以为"改名没生效"。
#
# ⚠️ 只删**指向同一个 $SRC 的软链**。那是我们自己建过的别名，删掉不碰任何
#    数据（软链不是目录，rm 它不会递归进目标）。指向别处的软链、或者是个
#    真目录，一律不碰，只把命令打出来让用户自己决定 —— 那不是我们建的。
OLDDEST="${DSAPP_OLDDEST:-/srv/shiny-server/DS_App}"
OLD_ALIAS=0
OLD_OTHER=""
if [ "$OLDDEST" != "$DEST" ]; then
  if [ -L "$OLDDEST" ]; then
    # ⚠️ readlink -f 对着**断掉的**软链会返回空 + 非零退出码，而这里是
    #    `set -e` 下的赋值语句 —— 不加 `|| true` 就是整个脚本在这儿静默中止。
    old_cur="$(readlink -f "$OLDDEST" 2>/dev/null || true)"
    if [ "$old_cur" = "$SRC" ]; then
      OLD_ALIAS=1
    else
      OLD_OTHER="${old_cur:-<断链>}"
    fi
  elif [ -e "$OLDDEST" ]; then
    # 只放"为什么不是我们的别名"，路径由调用处再打一遍 —— 塞进同一个变量
    # 会印成「…（/srv/…/DS_App（不是软链，是个真目录））」，两层括号套在一起。
    OLD_OTHER="<不是软链，是个真目录>"
  fi
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$OLD_ALIAS" = "1" ]; then
    ylw "! 旧地址还活着：$OLDDEST → $SRC"
    echo "  两个地址 = 两个 R 进程 = 同一份库，登录会互相顶掉。"
    echo "  正式跑的时候会删掉这条软链：rm $OLDDEST"
  elif [ -n "$OLD_OTHER" ]; then
    ylw "! $OLDDEST 存在，但不是指向这里的软链（$OLD_OTHER），脚本不会动它"
  else
    grn "✓ 没有多余的旧地址"
  fi
  # ★ Test_V15.2：定时订阅那个 timer 装了没有。
  #
  # ⚠️ 判据用 is-active（**定时器活着**），不是 is-enabled。enabled 只说明
  #    "开机自启"，一个 enabled 但 failed 的 timer 照样是 enabled ——
  #    而 failed 的症状就是"订阅到点了没人跑"，界面上完全看不出来
  #    （下次运行时间那一栏会停在一个过去的时刻，但那要用户自己去看）。
  if command -v systemctl >/dev/null; then
    if systemctl is-active --quiet dsapp-lit.timer 2>/dev/null; then
      grn "✓ 定时订阅的 timer 在跑（dsapp-lit.timer）"
      systemctl list-timers dsapp-lit.timer --no-legend 2>/dev/null \
        | awk '{print "  下次触发：" $1, $2, $3}' || true
    elif [ -e /etc/systemd/system/dsapp-lit.timer ]; then
      ylw "! dsapp-lit.timer 装了但没在跑 —— 订阅到点不会有人管"
      echo "  起来：sudo systemctl enable --now dsapp-lit.timer"
      echo "  看原因：systemctl status dsapp-lit.timer"
    else
      ylw "! 没装 dsapp-lit.timer —— 定时订阅不会自己跑"
      echo "  装：sudo bash deploy_link.sh（不带 --check）"
    fi
  fi

  hdr "检查完毕（--check 未改动任何文件、未重启服务）"
  exit 0
fi

# ---- 3. 换软链 --------------------------------------------------------------
hdr "把 $DEST 换成指向 $SRC 的软链"

BACKUP=""
if [ -L "$DEST" ]; then
  cur="$(readlink -f "$DEST")"
  if [ "$cur" = "$SRC" ]; then
    grn "✓ 已经是指向这里的软链，不用换"
  else
    ylw "! 原本指向 $cur，改指向 $SRC"
    ln -sfn "$SRC" "$DEST"
    grn "✓ 软链已更新"
  fi
else
  if [ -e "$DEST" ]; then
    # ⚠️ 是 mv 不是 rm。旧目录里可能还留着没搬过来的东西，而且"换软链失败
    #    要能原样退回去"这件事只有在旧目录还在的时候才成立。
    BACKUP="${DEST}.pre_v5_${STAMP}"
    mv "$DEST" "$BACKUP"
    grn "✓ 旧目录挪到了 $BACKUP（**没有删**，确认新版没问题后可以自己清掉）"
  else
    grn "✓ $DEST 本来就不存在"
  fi
  ln -sfn "$SRC" "$DEST"
  grn "✓ 软链已建立：$DEST → $SRC"
fi

# ---- 3b. 定时订阅的 systemd timer（★ Test_V15.2）----------------------------
#
# 每 5 分钟起一次 run_scheduler.R（oneshot）：把到点的文献速递订阅跑掉、
# 把邮件队列排空。**它不常驻** —— R 是单线程的，一个"睡 5 分钟看一眼"的
# 常驻进程既占着内存又要自己实现调度循环，而 systemd 的 timer 已经做完了
# 这件事，还带日志和 `systemctl list-timers`。
#
# ⚠️⚠️ 单元名**不能**叫 dsapp-web / dsapp-worker@* —— 上面第 2 段会把那三个
#    名字 `disable --now` 掉（它们是 V1 遗留的崩溃循环）。撞名的话这个新
#    单元会被自己的部署脚本停掉，而且是在**同一次**部署里。
#
# ⚠️ WorkingDirectory 是**必须的**：子进程读 cwd 的 .Renviron 来定位
#    data_root 和 SMTP 配置，而 .Renviron 里的值会**盖掉**继承来的环境变量。
#    指错目录的症状是"调度器连上了另一个库、或者根本没配 SMTP，但一切正常没报错"。
#
# ⚠️ User= 取的是**仓库属主**，不写死 biomamba：换台机器部署、或者换个人
#    维护的时候，写死的那个名字会让单元起不来（"Failed to determine user"），
#    而那和"订阅没到点"在界面上长得一模一样。
hdr "定时订阅的 timer（dsapp-lit）"
LIT_UNIT=/etc/systemd/system/dsapp-lit.service
LIT_TIMER=/etc/systemd/system/dsapp-lit.timer
OWNER="$(stat -c '%U' "$SRC" 2>/dev/null || echo root)"
GROUP="$(stat -c '%G' "$SRC" 2>/dev/null || echo root)"
if ! command -v systemctl >/dev/null; then
  ylw "! 没有 systemctl，跳过（定时订阅在这台机器上不会自己跑）"
else
  # ⚠️ 没配 SMTP 也照样装：定时订阅本身（跑检索、留一份速递在工作区里）和
  #    发信是两件事，没配邮件只是不发信，不该因此连调度都不做。
  #    这和界面上的 D4 判断（没配 SMTP 就不显示邮件卡片）不冲突：
  #    那边藏的是"点了必然报错的按钮"，这边藏的是"功能本身不出结果"。
  cat > "$LIT_UNIT" <<UNIT
[Unit]
Description=DS_App 定时文献速递调度器（oneshot，跑一轮就退）
Documentation=file://$SRC/run_scheduler.R

[Service]
Type=oneshot
WorkingDirectory=$SRC
ExecStart=/usr/bin/Rscript $SRC/run_scheduler.R
User=$OWNER
Group=$GROUP
# ⚠️ 一轮最多 DSAPP_LIT_TICK_MAX 条订阅、每条最长 DSAPP_LIT_RUN_WALL 秒，
#    所以这个值要给得比那大得多。给短了 systemd 会在半路 SIGTERM ——
#    而那种死法留下的正是"卡在 running"那种行（run_scheduler.R 里的
#    reclaim 认得出来，但那一轮白跑了、token 白烧了）。
TimeoutStartSec=4h
# 日志进 journal：journalctl -u dsapp-lit -n 50
StandardOutput=journal
StandardError=journal
UNIT
  cat > "$LIT_TIMER" <<'UNIT'
[Unit]
Description=每 5 分钟跑一次 DS_App 的文献速递调度器

[Timer]
# ⚠️ 用 *:0/5 而不是 OnUnitActiveSec=5min：后者是"上一次跑完之后再过 5 分钟"，
#    于是每一轮的间隔 = 5 分钟 + 上一轮跑的时间，越拖越偏；而且机器重启后
#    间隔会重新算。*:0/5 是墙钟上的 0/5/10/... 分，重启后立刻对齐。
OnCalendar=*:0/5
# 机器关机期间错过的那些，开机后补跑一次就够（别补 20 次）
Persistent=true
Unit=dsapp-lit.service

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  if systemctl enable --now dsapp-lit.timer >/dev/null 2>&1; then
    grn "✓ dsapp-lit.timer 已装上并启动（每 5 分钟一 tick）"
    echo "  下次触发：$(systemctl list-timers dsapp-lit.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}' || echo '查不到')"
    echo "  看日志：journalctl -u dsapp-lit -n 50 --no-pager"
  else
    ylw "! 单元写好了但没起来，自己看一眼：systemctl status dsapp-lit.timer"
  fi
fi

# ---- 4. 重启 ----------------------------------------------------------------
hdr "重启 Shiny Server"
if systemctl is-active --quiet shiny-server 2>/dev/null; then
  systemctl restart shiny-server
  sleep 5
  systemctl is-active --quiet shiny-server && grn "✓ 已重启" || {
    red "✗ shiny-server 没起来"; }
else
  ylw "! shiny-server 不在运行，跳过重启"
fi

# ---- 5. 验证 ----------------------------------------------------------------
hdr "验证"
HTML="$(mktemp -t dsapp_link_check.XXXXXX.html)"
CODE="$(curl -s -o "$HTML" -w '%{http_code}' "$APP_URL" || echo 000)"
OK=0
if [ "$CODE" = "200" ]; then
  grn "✓ $APP_URL → HTTP 200"
  for asset in app.css app.js; do
    AC="$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}${asset}")"
    [ "$AC" = "200" ] && grn "  ✓ $asset" || red "  ✗ $asset → HTTP $AC"
  done
  # 问 SockJS 的 info：应答来自**应用的 R 进程本身**。比 HTTP 200 强 ——
  # 那个 200 是 Shiny Server 给的空壳，底下的 R 进程挂了它照样 200。
  SOCK="$(curl -s -m 10 -w '\n%{http_code}' "${APP_URL}__sockjs__/info" 2>/dev/null || printf 000)"
  SC="$(printf '%s' "$SOCK" | tail -1)"
  if [ "$SC" = "200" ] && printf '%s' "$SOCK" | grep -q '"websocket"'; then
    grn "  ✓ 应用的 R 进程活着"
    OK=1
  else
    red "  ✗ 应用进程没有应答（HTTP $SC）"
    echo "    排查：journalctl -u shiny-server -n 50"
    echo "          tail -50 /var/log/shiny-server/YCFS_APP-*.log"
  fi
else
  red "✗ $APP_URL → HTTP $CODE"
fi
rm -f "$HTML"

if [ "$OK" != "1" ]; then
  echo
  red "验证没过。上面的排查信息先看一眼；要立刻退回旧版本："
  if [ -n "$BACKUP" ]; then
    echo "    rm $DEST && mv $BACKUP $DEST && systemctl restart shiny-server"
  else
    echo "    （这次没有产生备份目录：$DEST 本来就是软链，改回去即可）"
  fi
  exit 1
fi

# ---- 6. 旧地址退役 ----------------------------------------------------------
#
# ★ V13.11 item 13：**只有等到新地址真的验证通过了，才去删旧别名。**
#
# ⚠️ 这一步的位置很要紧，放过两个地方都不对：
#    · 排在"建新软链"之后、"重启/验证"之前 —— 重启一旦失败（或者像今天这样
#      脚本在别处中止），用户就落得**两个地址都没有**：新的没生效、旧的被删了。
#      这是线上唯一入口，不能有这种窗口。
#    · 排在验证失败分支里 —— 那就永远不会执行。
#    只有"新地址 HTTP 200 且 R 进程应答"之后再删，才不可能出现两个都没有。
#
# ⚠️ 删之前再确认一次它还是**指向本目录的软链**。从上面那次检测到这里隔了
#    重启 + 若干秒，中间理论上可以变（比如有人手动改了）。多花一次 readlink
#    换"绝不误删别人东西"，值。
if [ "$OLD_ALIAS" = "1" ]; then
  if [ "$KEEP_OLD" = "1" ]; then
    ylw "! 保留了旧地址（--keep-old）：$OLDDEST —— 两边会互相顶登录，心里有数就行"
  else
    now_cur="$(readlink -f "$OLDDEST" 2>/dev/null || true)"
    if [ "$now_cur" = "$SRC" ]; then
      rm -f "$OLDDEST"
      grn "✓ 旧地址已退役：删掉了软链 $OLDDEST（目标目录和数据都没动）"
    else
      ylw "! $OLDDEST 在这几步之间变了（现在指向 ${now_cur:-<断链>}），没动它"
    fi
  fi
elif [ -n "$OLD_OTHER" ]; then
  ylw "! $OLDDEST 不是指向这里的软链（$OLD_OTHER），没动它"
  echo "  要让它也失效：先确认它指向哪儿，再 sudo rm $OLDDEST"
fi

hdr "完成"
echo "公网访问：http://sw2-primary1.xiyoucloud.pro:34038/YCFS_APP/"
echo
echo "从此这个文件夹就是线上：在这里改代码 → sudo systemctl restart shiny-server"
echo "（改 CSS/JS 的话浏览器可能缓存着旧的，页面里的 ?v= 会随文件变，一般不用管）"
if [ -n "$BACKUP" ]; then
  echo
  ylw "旧目录还留着：$BACKUP"
  echo "确认新版没问题之后可以清掉它腾空间（里面有一份当时的 data/）："
  echo "    du -sh $BACKUP && rm -rf $BACKUP"
fi
