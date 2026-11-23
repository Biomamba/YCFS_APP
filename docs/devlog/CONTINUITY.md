# YCFS_APP 接续指南（CONTINUITY）

> 给**下一个接手的人或 AI harness**。目标：读完这一页 + `features.json` + `devlog.jsonl` 最近 20 条，
> 就能接着开发，并且能测出「功能有没有丢」。
>
> 本文件的数字来自 **2026-11-23 21:05–21:15 CST 的只读实测**（940 与大禹），
> 另有 2026-11-21/11-22 的基线项沿用旧值并已标注。
> 有疑问先跑一遍 §3 的自检，不要凭记忆改东西。

---

## 0. 一句话现状

- **940 是主位**：`Test V21.67`（代次 `g278`，资产 `V21.55`，库 schema **146**），17/17 单元监控全绿（`OK 17/17 active`），
  DB 同步 `lag=0s`（21:04 两侧 users 624 / sessions 371 / messages 7944 一致）。
- **8 个 worker 已跟随 current**（ExecStart 指向 `generations/g278/dist/dsapp worker`，2026-11-23 20:45 起自动跟随；
  此前被 drop-in 钉在 2026-11-10 封存运行时，导致任务完成界面一直转圈）。
- **代次重启恢复已根治**：sealed revision `r1-533acba36b1fb2d11a5b` 切了 **69 个 unit** 的 ExecStartPre（旧 revision 引用 0），
  g277 连续两次重启成功（recovery=true），current g278 未受影响。
- **大禹是只读备机**：`Test V21.66` / 资产 `V21.54`（2026-11-23 21:0x 实测），单目录（无 hot-gateway/catalog），
  写请求仍 503；**能聊天不能执行**：worker 0 实例、无 Jupyter 实例、无语音、无 34080、无备份 cron、无监控 timer（均已交付未安装）。
- **切换过去会丢功能**（详见 `YCFS_940_vs_大禹_功能对等审计_20261121.md` 与 `features.json` 的 `nodes` 字段），
  但一键切主备已有 **dry-run 默认 + 版本守卫 fail-closed + 边车实测健康上报 + 任务可中止**（V21.63/g274）。
- **直传**：`ycfs-files.biomamba.cn:34080` 仍由 940 提供（TLS 存活、明文 410）；证书 **2027-01-19 到期，无自动续期**
  （需西部数码 API 凭据，否则 2026-12-20 起手工续期）。

---

## 1. 当前生产状态（2026-11-23T21:15+08:00 实测）

### 1.1 拓扑与地址

| 角色 | 地址 / 入口 | 关键点 |
|---|---|---|
| 对外唯一入口 | `https://www.biomamba.cn/YCFS_APP/` | 官网机 `121.40.93.237`；nginx `upstream ycfs_app_edge` |
| 940（主） | `sw2-primary1.xiyoucloud.pro:59416`（用户 `biomamba`） | `hot-gateway` 监听 `127.0.0.1:34039`，读 catalog 转发到当前代 |
| 大禹（备） | `221.213.116.80:12200`（用户 `biomamba_beifen`，**从 940 可免密 ssh**） | 单目录 `ycfs-dr-web`，同样监听 `127.0.0.1:34039`，只读 |
| 官网机隧道出口 | `127.0.0.1:34184`（→940）/ `127.0.0.1:34183`（→大禹） | 看 nginx upstream 的 `down` 参数，不看 IP 顺序；官网机 root 跑 `ycfs-edge-agent` |
| 直传 | `ycfs-files.biomamba.cn:34080` → `119.62.67.134`（=940） | **明文已退役（HTTP 410）**，只剩 HTTPS；域名永远指 940 |

### 1.2 版本（三套号，别混）

| 名字 | 940 | 大禹 | 从哪看 |
|---|---|---|---|
| 二进制版本 | `Test V21.67` | `Test V21.66` | `curl -I 127.0.0.1:34039/YCFS_APP/healthz` 的 `X-Ycfs-Version` |
| 代次 | `g278`（g277 active＝回滚/实验窗口） | 无（单目录） | `/run/ycfs-unit-health/status.json` 的 `hot_web.current`（catalog.json 是 root-only） |
| 资产版本 | `V21.55` | `V21.54` | `curl '…/healthz?format=json'` 的 `asset_version` |
| worker | 8/8 跟随 `g278` | 无实例 | `systemctl show -p ExecStart dsapp-v18-worker@1` / `ps -eo args \| grep 'dist/dsapp worker'` |

> 发布时**同号不同代是常态**（g257/g258 都自报 V21.47）。判断「新代有没有接管」只能靠：
> `catalog.current` + `/proc/<pid>/exe` 的 sha256 + `asset_version`。**页面版本号不算证据。**
> 2026-11-23 一半以上是「合并包」（二进制层 + 资产层同时换），更要注意三样对齐。

### 1.3 数据与同步

| 项 | 值（2026-11-23 21:0x–21:1x 复核） |
|---|---|
| 库 | `v18_schema` 是 k/v 表：`k='version'`、`v=146`（v144 title_source → v145 v18_nodes/v18_node_tasks → v146 v18_node_tasks.mode）；`users=624`、`sessions=371`、`messages=7944` |
| 会话标题 | `sessions.title_source`：auto=370 / user=1（2026-11-23 21:1x 只读）；历史数据迁移后仍是 auto，见 §5 |
| 节点管理 | `v18_nodes` 两行：`n940` primary ok `Test V21.67` / `ndayu` standby ok `Test V21.66`；`v18_node_tasks` 1 行 `state=failed`（13:16 误切事故任务，已被边车 reap 回收） |
| 任务 | `v18_jobs` pending 0（历史 3025 行基线：success 2188 / failed 829 / canceled 6 / error 2） |
| 模型 | 渠道 8（启用 6）、平台模型 505（启用 151）、来源策略 47、账单 43176（带路由 1292）、审计 991（2026-11-21 基线，今日未复核） |
| 同步 | `ycfs-dr-sync-db.timer` active（10 分钟一轮），`lag=0s`，两侧快照 sha 相同（21:04:47）；`ycfs-dr-sync-files.timer` active（11-23 09:43:54 恢复，正在补 11-20 20:34 以来积压） |
| 备份 | 940 crontab 2 条（每日 03:17 + 每 4 小时）+ `backup_keys.sh` + `check_backup.sh`；大禹 **0 条**（backup-sqlite.sh 已交付未装） |
| 磁盘 | `/data3` 8.4T/10T = **89%** |
| 课程镜像 | 三个会话工作区 `课程/`：R 141,584 文件/231G、py 341/83G、spatial 4,880/462G；全部硬链接（零额外磁盘）；文件 444、目录 555（setgid 2555） |

### 1.4 关键路径 / 端口

| 路径或端口 | 说明 |
|---|---|
| `/data3/biomamba/analysis/DS_App/data/dsapp.sqlite3` | 生产库（R 版与 Go 版共用）；`.keyring` / `.secret_key` 同目录，**不能只同步库** |
| `/data3/biomamba/analysis/DS_App/data/.ycfs-read-only` | `0`=可写（主位），`1`=只读（备机）；大禹另有 `.ycfs-read-only-runtime` |
| `/data3/biomamba/analysis/DS_App/data/hot-web-owners/` | hot 网关归属记录（`shiny:shiny 0700`，**非 root 读不到**）；retire 旧代后这里不迁移会全站 503/500 |
| `/data3/biomamba/analysis/ycfs-hot-web/catalog.json` | 控制面（`root:shiny 0750`，非 root 读不到）；`current` 只能由 promote/rollback 改 |
| `/var/lib/ycfs-hot-ui-followup-20261117/generations/gNNN/` | 每一代的完整运行时；实测存在 g255–g278 共 23 个（无 g271，已被合并/退休） |
| `/opt/ycfs-hot-v33-service-identity-20261101/r1-533acba36b1fb2d11a5b/` | 新的 sealed boot revision（root:root、恰好 7 项）；69 个 hot-web unit 的 ExecStartPre 指它 |
| `127.0.0.1:34039` | 网关/app（只监听回环，公网 curl 不到） |
| `0.0.0.0:34038` | 历史对外端口：**只做 301 到 https 主站**（`/YCFS_APP/*` 剥前缀保留路径参数），不再代理应用 |
| `0.0.0.0:34080` | 直传（**仍由 940 提供**）：HTTPS 存活（`/transfer/upload`→401），HTTP 返回 410；证书见 §5 |
| `127.0.0.1:34294` | 语音 ASR/TTS（`/healthz` 无 key 返回 401） |

### 1.5 最近变更（2026-11-23 全天）

- **本批 devlog 区间**：`devlog.jsonl` 第 37–51 条（2026-11-23T10:20–21:12）—— V21.59 消息删除、V21.60 401 守卫、
  热网关归属记录事故、V21.61→V21.63 节点管理+主备切换四守卫、会话标题再覆盖、V21.64 代码者格式、V21.65 notebook 单元渲染/运行、
  V21.66 大会话卡顿、大禹 P0、34080 证书、hot-retire 属主安全、课程硬链接权限、worker 跟随、boot recovery、脚本质量教训、热部署全景。
- **代次线**：g264 → g279（V21.53 → V21.68；asset V21.48 → V21.56）。已上线到 g278（Test V21.67 / asset V21.55）；
  **g279（V21.68 / asset V21.56）21:11 已生成 deploy 脚本、尚未部署**。
- **状态变化**：schema 143 → **146**；worker 从「钉在 2026-11-10 运行时」→ **跟随 current**；
  「代次重启必失败」→ **已修**（sealed revision 切 69 unit）；切换从「点一下=真切」→ **dry-run 默认 + 版本守卫**。

---

## 2. 读什么才能接手（按顺序）

1. **本文件** —— 现状、地址、规矩（约 5 分钟）。
2. **`features.json`** —— **123 条**功能，按 `layer`（web/chat/model/runner/transfer/jupyter/audio/admin/ops）分组；
   每条有 `user_path`（用户怎么走到）、`verify`（怎么验）、`nodes`（940/大禹各自状态）、`known_limits`、`since`、`req_refs`；
   **2026-11-23 起新增/更新条目带 `status`**（deployed / pending_user_confirm / pending_deploy / pending_external / in_progress，
   见 `feature_status_legend`），老条目没有 status、完成度看 `nodes`。
   先看 `nodes` 里不是 `ok` 的条目 —— 那就是「会丢的功能」。
3. **`devlog.jsonl` 最近 20 条** —— 每个版本改了什么、为什么、怎么回滚。
   `tail -n 20 docs/devlog/devlog.jsonl`（一行一条 JSON；`jq -r '.ts+" "+.version+" "+.kind+" "+.title'`）。
4. **台账（不在本仓库）** —— 工作区 `YCFS_APP_核查清单_合并版.md`（需求原话 + 勾选状态）、
   `handoff/`（HANDOFF、运维机制归档、大禹补齐清单、监控说明）、
   `YCFS_940_vs_大禹_功能对等审计_20261121.md`（切换会丢什么，含证据）。
5. 需要动运维时再看：`handoff/YCFS-运维机制归档.md`（发布六步、catalog 形状、切换/同步/502 分诊）。
   2026-11-23 新增的专项材料：`ycfs-boot-recover-fix-20261123/`（boot 恢复修复）、`switchsafe/`（切主备四守卫）、
   `ycfs-dayu-p0-20261123/`（大禹 P0）、`ops/deliver/`（大禹备份/文献 timer/健康监控交付物）。

> 只读三个文件就能接续的最小集合：**CONTINUITY.md → features.json → devlog 最近 20 条**。

---

## 3. 怎么验「功能没丢」

### 3.1 一条命令

```bash
# 在 940 上（默认只跑 http 条目，符合「只读」约定）
python3 docs/devlog/scripts/check_features.py

# 连 cli 条目一起跑（推荐：能覆盖 worker / 语音 / 同步 / 栅栏 / 磁盘 / 代次）
python3 docs/devlog/scripts/check_features.py --include-cli

# 换目标（例如在别的机器上跑同一份清单）
python3 docs/devlog/scripts/check_features.py --base http://127.0.0.1:34039/YCFS_APP
```

- `kind=http`：只做 GET / 空体 POST 的路由存在性探测（未登录时预期 `401/405/409/303`，**不产生业务写入**）。
- `kind=cli`：`systemctl is-active` / `ss` / `df` / `sqlite3 mode=ro` / `grep 二进制标记` 一类只读命令，需要 `--include-cli` 才跑。
- `kind=ui`：不自动跑，输出 `MANUAL`，**必须人工点一次**（需要登录态或管理员身份）。
- 新增/更新条目的 `status` 不参与自动判定；它回答「这条是已上线还是等确认/等部署」。

退出码：`0` 无 FAIL，`1` 有 FAIL，`2` 用法错误。可以直接进 CI/cron 做「功能回归闸门」。

### 3.2 基线快照（历史，勿改）

2026-11-21 11:08 首轮 `--include-cli`：OK=66 FAIL=3 MANUAL=32。3 个 FAIL 为 `ops.switch_script`（absent）、
`ops.files_sync`（inactive）、`ops.legacy_port`（34038 仍监听）。2026-11-23 复核：`ops.files_sync` 已消除（timer active）；
`ops.legacy_port` 判据未改（仍在监听，但已改为只 301 跳转，风险性质变化）；`ops.switch_script` 仍未安装在 940（属官网机脚本）。
**每次发版后重新跑一遍并贴到 devlog 的 verify 里，不要拿旧数字当现状。**

### 3.3 2026-11-23 新增的自动判据（可直接跑）

| 判据 | 命令 | 期望 |
|---|---|---|
| 当前代次 | `python3 -c "import json;print(json.load(open('/run/ycfs-unit-health/status.json'))['hot_web']['current'])"` | `g278` |
| 版本/资产 | `curl -sI 127.0.0.1:34039/YCFS_APP/healthz \| grep -i x-ycfs-version` + `curl -s '…/healthz?format=json'` | `Test V21.67` + `V21.55` |
| schema | `python3 -c "...select v from v18_schema where k='version'"` | `146` |
| worker 跟随 | `systemctl show -p ExecStart dsapp-v18-worker@1` | 含 `generations/g278/dist/dsapp worker` |
| boot revision | `grep -l 'r1-533acba36b1fb2d11a5b' /etc/systemd/system/ycfs-hot-web-g*.service \| wc -l` | `69` |
| 节点注册表 | 只读查 `v18_nodes` | `n940 primary ok` / `ndayu standby ok` |
| 切换演练列 | 只读查 `v18_node_tasks.mode` | 列存在、默认 `dry-run` |
| 会话标题守卫 | `curl -s http://127.0.0.1:34039/YCFS_APP/static/chat.js \| sha256sum \| cut -c1-8` | `8654ead9`（g278 asset） |

### 3.4 MANUAL 怎么处理

`kind=ui` 条目 + 今天新增的 `pending_user_confirm` 条目都要登录/管理员/点击才能确认。建议每次发版挑 8–10 条关键路径人工过一遍
（对话→工具→产物→预览→导出；今日重点：代码者模式单元就地编辑/运行、文件树懒加载、401 跳登录、节点管理演练）。

---

## 4. 改东西的规矩（硬要求）

1. **先读**：`devlog.jsonl` 最近 20 条 + 相关 `features.json` 条目 + 台账里对应需求。没读就改 = 大概率回滚别人的修复。
2. **改完必须追加一条 devlog**（不许改历史行，文件是追加式）：
   ```bash
   python3 docs/devlog/scripts/append_devlog.py \
     --version V21.68 --kind release \
     --title "V21.68（g279）…" \
     --summary "改了什么、为什么、影响面" \
     --files web/static/chat.js,web/asset-urls.json \
     --verify "[940] curl -s '127.0.0.1:34039/YCFS_APP/healthz?format=json' 期望 asset_version=V21.56" \
     --rollback "sudo bash …/deploy_g279_official.sh --rollback" \
     --evidence "catalog.current=g279；asset V21.55→V21.56"
   ```
   `--kind` 只能是 `release / fix / ops / incident / decision`。脚本会：补 `ts`、写前 `json.loads` 复核、
   追加后逐行复核；`--check` 可随时体检。**不要手写 JSONL 行。**
3. **必须跑一次功能自检**：`python3 docs/devlog/scripts/check_features.py --include-cli`。
   FAIL 数比上次多 ⇒ 要么修回去，要么在 `known_limits` 里写清楚「为什么可以红」。
4. **新功能要进 `features.json`**，并且 `verify` 必须真能跑（不确定就 `kind=ui` + `known_limits` 标注，**不许编命令**）；
   新增/更新条目要填 `status`。
5. **不写密钥**：`features.json` / `devlog.jsonl` / 本文件都**不得**出现密码、Token、私钥、`.keyring` 内容。
   只写路径、sha256、判据。
6. **本仓库只放文档**：README/CHANGELOG/docs/images + `docs/devlog/` 的文档与两个只读脚本，**不放产品代码**。
7. **不要整篇重写台账**（`YCFS_APP_核查清单_合并版.md`）：只追加、只改单行，用户会在预览区手勾。

---

## 5. 已知坑（2026-11-23 一天踩出来的，可复用）

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | **启动过的代次重启必失败** | `prepare_boot.py` 见本代 marker ⇒ `resumed=True` ⇒ `client.recover()`；pinned `sqlite_uid_helper.schema140()` 只认 schema 140..143，库已 146 ⇒ `service_sqlite.Refused` | 已用 sealed revision `r1-533acba…` 根治（69 unit 切 ExecStartPre）；**不要再往 sealed 目录写 `__pycache__`**（会破坏 `root_stdlib_guard` roster，整个 revision 起不来）；新代首启不走 recover，所以「首启成功」不代表「重启也成功」 |
| 2 | **worker 落后 70 版** | worker drop-in 写死 2026-11-10 封存运行时，web 已新代 ⇒ 任务完成界面一直转圈、无报错 | 发版后必须跑 `ycfs-workers-follow-current`（部署脚本已内置）；查 `/proc/<pid>/exe` 或 ExecStart 确认跟随 |
| 3 | **retire 移除旧代后归属记录不迁移** | 631 条 `hot-web-owners` 仍指 g270 ⇒ 全站 tick 503/500 | 根治（retire 前迁移归属记录）**未实现**；retire 后马上检查；`hot-web-owners/` 非 root 读不到，排障先拿 root |
| 4 | **会话标题被覆盖（第二回）** | v144 老行全 auto（含 11-22 手工恢复过的手动标题），删光消息再发首条会被自动命名覆盖 | 15:40 已备份 `ycfs-dbbackup-20261123-154024-titlefix.sqlite3`；收紧条件（标题为空/等于默认新会话名才写）**待验证是否进 V21.68**；不要改历史行，先备份库 |
| 5 | **「等待回答」是派生态不是持久态** | 旧删除 4 判据里的 `driveBusy(Phase!=idle)` 会把「停在等确认」误判成在跑 ⇒ 删不掉 | V21.59 起只在真在跑时 409；排查看新增日志 `[v18] delete 拒绝 sid=… 判据=…` |
| 6 | **SSE 401 被网关拦成 410** | 登录失效时 `/api/stream` 不会触发跳转 | 401 守卫靠 1 秒一拍的 `POST /api/chat`；不要指望 SSE 这条通道报 401 |
| 7 | **会话标题/前端资产版本号不能当真** | 页面版本号可能滞后或同号不同代 | 以 `catalog.current` + `/proc/<pid>/exe` sha256 + `asset_version` 三样为准 |
| 8 | **部署脚本自己被 shell 坑** | `printf … \| python3 - <<'PY'` 的 stdin 被 heredoc 吃掉（4 个脚本中招）；shell 与内嵌 Python 两份常量不同步（`NameError: CHAT_SHA`）；断言「看起来一样却不相等」（g276 step4 假失败自动回滚） | 部署脚本必须带：内嵌 helper 与 shell 常量逐项自检、启动前只清本代 boot marker + 重试 3 次 + 打印完整 journal、`diff_sets()` 断不等时打 diff + `od -c` |
| 9 | **批量权限/属主操作会伤人** | `chown -R 555`（数字当用户名）把课程树属主改成不存在的 uid；**无法精确还原原混合属主** | 批量命令先 `--dry-run`/先小目录；课程树已统一 `cwj:cwj`、文件 444/目录 555(setgid) 以让 shiny 可读 |
| 10 | **一键切主备曾经「点一下=真切」** | 13:16 用户点「大禹 切为主」，边车真的跑到 G5 被人工 stop；任务遗留 running | 现在默认 dry-run（v146 mode）、版本守卫 fail-closed、任务可 abort/reap；**真实切换前先核对两边二进制+资产版本** |
| 11 | **版本守卫只看 X-Ycfs-Version** | 大禹资产层比 940 旧时仍可能放行 | 是否把 asset_version 纳入守卫是产品决定；切换前人工比一遍 `asset_version` |
| 12 | **直传域名永远指 940** | 切到大禹后上传/语音直传 100% 失败，闸门查不出 | 34080 迁移需云安全组 + DNS（见 §6）|
| 13 | **证书不会自动续** | 34080 证书 2027-01-19 到期；无 timer/cron，DNS-01 manual 且遗留 TXT；HTTP-01 被云侧过滤 | 拿西部数码 API 凭据做自动续期，否则 2026-12-20 起手工续期 |
| 14 | **hot-retire.service 属主是普通账号** | `biomamba:biomamba` 却以 root 执行 ⇒ 提权面；claim 的 chown 未生效（21:1x 复核仍是 biomamba） | root 窗口执行 `chown root:root /etc/systemd/system/ycfs-hot-retire.service*` 并记 sha256 |
| 15 | **`/data3` 89%** | 旧代目录 + 报告转图（Chromium）会涨 | 盯 `ops.disk`；旧代交给 `ycfs-hot-retire`，**不要手删正在跑的代** |

---

## 6. 下一步（按优先级）

| 优先级 | 事项 | 判据 / 状态 |
|---|---|---|
| P0 | **部署 V21.68（g279 / Test V21.68 / asset V21.56）** | 发布包 `/data3/biomamba/analysis/ycfs-v2169-nb-cells-release-20261123/`（21:11 生成 `deploy_g279_official.sh`）；内容：去底部编辑器、编辑器工具栏隐藏、cell 类型切换、增删/移动单元、修 `unexpected indent`（dedent）。**待部署，未验证** |
| P0 | **标题自动命名收紧条件**是否进 V21.68 | 见 §5#4；部署后人工验：手动改名→删光消息→发首条，标题不被覆盖 |
| P1 | **34080 直传迁移**到可跟随切换的入口 | 需云安全组（`119.62.67.134` 的 34080 放行）+ DNS（CNAME 现指 940）；清单在 `ops/deliver/HANDOFF-DR-CAPABILITIES-20261123.md`。**卡云侧** |
| P1 | **证书自动续期** | 需西部数码 API 凭据；否则 2026-12-20 起手工续期（到期 2027-01-19） |
| P1 | **retire 前迁移 hot-web-owners**（根治 #3） | 当前应急=手工改 generation=current；根治未实现 |
| P1 | **hot-retire 属主 chown root:root**（安全 #14） | 21:1x 复核未生效；root 窗口执行 |
| P2 | **大禹语音评估**（34294 最小 runtime 约 6 G） | GPU 实测剩约 7.8 GiB（24611/32607 MiB 已用），建议暂不装；等用户决策 |
| P2 | **大禹备份/文献 timer/健康监控安装** | 交付物在 `ops/deliver/`；大禹 crontab/timers 实测仍为空 ⇒ 未安装 |
| P2 | **文件预览删除只覆盖文件区** | V21.67 的「选择删除」只在 `area=files`；会话产物（art/lesson）没有既有删除接口，按「不新造写路径」没放入口。要不要做是产品决定 |
| P3 | 大禹 UI 资产层补齐 | 2026-11-23 P0 报告发现：大禹二进制 V21.66 但 `web/` 资产仍是旧的（只有 SMTP 被 env 补上）；切换前要补齐，否则界面功能对不上 |

---

## 7. 这份体系的自我维护

- `features.json` 的 `checked_on` / `updated_at` 在每次全量自检后更新（人工改，别自动写库）。
- `devlog.jsonl` **只追加**；`append_devlog.py --check` 必须保持「坏行 0」。
- 本文件 §1 的数字如果与自检输出不一致，**以自检为准**，并当天修本文件（漂移的文档比没有更危险）。
- 首版建立：2026-11-21，`docs(devlog)` 提交；101 条功能、25 条日志。
  2026-11-23 第一次更新：追加 11 条（第 26–36 条）→ 109 条功能、36 条日志。
  **2026-11-23 晚间更新：追加 15 条（第 37–51 条，V21.59–V21.68 / 运维 / 事故）→ 123 条功能、51 条日志。**
