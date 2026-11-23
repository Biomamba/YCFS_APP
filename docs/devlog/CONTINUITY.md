# YCFS_APP 接续指南（CONTINUITY）

> 给**下一个接手的人或 AI harness**。目标：读完这一页 + `features.json` + `devlog.jsonl` 最近 20 条，
> 就能接着开发，并且能测出「功能有没有丢」。
>
> 本文件里的数字来自 **2026-11-23 09:57–10:05 CST 的只读实测/复核**（940 与大禹）；
> 任务、模型、备份等未复核项沿用 2026-11-21 11:00–11:05 的基线实测。
> 有疑问先跑一遍 §3 的自检，不要凭记忆改东西。

---

## 0. 一句话现状

- **940 是主位**：`Test V21.58`（代次 `g269`，资产 `V21.50`，库 schema `v144`），8 个 worker + 语音 + 加速 + 17 单元监控全绿，DB 同步 `lag=0s`。
- **大禹是只读备机**：`Test V21.51`（资产 `V21.47`），单目录（无 hot-gateway/catalog），写请求 503；
  **能聊天不能执行**：worker disabled（0 实例）、无 Jupyter、无语音、无 34080 直传、无 SMTP、无备份 cron、无监控 timer。
- **切换过去会丢功能**，且大多数不报错（详见 `YCFS_940_vs_大禹_功能对等审计_20261121.md` 与 `features.json` 的 `nodes` 字段）。
- **同步与入口已收口**：两个同步 timer（db/files）都在跑；`ycfs-dr-sync-files.timer` 2026-11-23 09:43:54 已恢复（正在补传 2026-11-20 20:34 以来的积压）；34038 只做 301 跳转、不再明文代理应用；34080 直传仍由 940 提供（TLS 存活、明文 410）。
- 仍缺：一键切换脚本 `ycfs-switch.sh` 至今未安装；备机功能面缺口未补（见 §3.3）。

---

## 1. 当前生产状态（2026-11-23T10:05+08:00 复核）

### 1.1 拓扑与地址

| 角色 | 地址 / 入口 | 关键点 |
|---|---|---|
| 对外唯一入口 | `https://www.biomamba.cn/YCFS_APP/` | 官网机 `121.40.93.237`；nginx `upstream ycfs_app_edge` |
| 940（主） | `sw2-primary1.xiyoucloud.pro:59416`（用户 `biomamba`） | `hot-gateway` 监听 `127.0.0.1:34039`，读 catalog 转发到当前代 |
| 大禹（备） | `221.213.116.80:12200`（用户 `biomamba_beifen`，**从 940 可免密 ssh**） | 单目录 `ycfs-dr-web`，同样监听 `127.0.0.1:34039`，但只读 |
| 官网机隧道出口 | `127.0.0.1:34184`（→940）/ `127.0.0.1:34183`（→大禹） | 看 nginx upstream 的 `down` 参数，不看 IP 顺序 |
| 直传 | `ycfs-files.biomamba.cn:34080` → `119.62.67.134`（=940） | **明文已退役（HTTP 410）**，只剩 HTTPS；域名永远指 940 |

### 1.2 版本（三套号，别混）

| 名字 | 940 | 大禹 | 从哪看 |
|---|---|---|---|
| 二进制版本 | `Test V21.58` | `Test V21.51` | `curl -I 127.0.0.1:34039/YCFS_APP/healthz` 的 `X-Ycfs-Version` |
| 代次 | `g269`（`g268` 仍 active＝回滚窗口） | 无（单目录） | `/run/ycfs-unit-health/status.json` 的 `hot_web.current`（catalog.json 是 root-only） |
| 资产版本 | `V21.50` | `V21.47` | `curl '…/healthz?format=json'` 的 `asset_version` |

> 发布时**同号不同代是常态**（g257/g258 都自报 V21.47）。判断「新代有没有接管」只能靠：
> `catalog.current` + `/proc/<pid>/exe` 的 sha256 + `asset_version`。**页面版本号不算证据。**

### 1.3 数据与同步

| 项 | 值（2026-11-23 10:00–10:03 复核；未复核项为 2026-11-21 基线） |
|---|---|
| 库 | `v18_schema.version=144`（2026-11-23 迁移 v144：`sessions.title_source`）；`users=620`、`sessions=370`、`messages=7930`（2026-11-23 10:03 只读查询） |
| 任务 | `v18_jobs` 3025 行：success 2188 / failed 829 / canceled 6 / error 2 / **pending 0** |
| 模型 | 渠道 8（启用 6）、平台模型 505（启用 151）、来源策略 47、账单 43176（带路由 1292）、审计 991 |
| 同步 | `ycfs-dr-sync-db.timer` active（10 分钟一轮），`lag=0s`，两侧 `.keyring` sha 相同 |
| 文件同步 | `ycfs-dr-sync-files.timer` **active**（2026-11-23 09:43:54 重启，`LastTriggerUSec` 同时间），rsync 正在补传 2026-11-20 20:34 以来的积压；此前最后一次尝试 2026-11-20 20:31:51 被 TERM（`Result=signal/15`） |
| 备份 | 940 crontab 2 条（每日 03:17 + 每 4 小时）+ `backup_keys.sh` + `check_backup.sh`；大禹 **0 条** |
| 磁盘 | `/data3` 8.4T/10T = **89%** |

### 1.4 关键路径 / 端口

| 路径或端口 | 说明 |
|---|---|
| `/data3/biomamba/analysis/DS_App/data/dsapp.sqlite3` | 生产库（R 版与 Go 版共用）；`.keyring` / `.secret_key` 同目录，**不能只同步库** |
| `/data3/biomamba/analysis/DS_App/data/.ycfs-read-only` | `0`=可写（主位），`1`=只读（备机）；大禹另有 `.ycfs-read-only-runtime` |
| `/data3/biomamba/analysis/ycfs-hot-web/catalog.json` | 控制面（`root:shiny 0750`，非 root 读不到）；`current` 只能由 promote/rollback 改 |
| `/var/lib/ycfs-hot-ui-followup-20261117/generations/gNNN/` | 每一代的完整运行时；实测存在 g255…g269（15 代） |
| `127.0.0.1:34039` | 网关/app（只监听回环，公网 curl 不到） |
| `0.0.0.0:34038` | 历史对外端口：**只做 301 到 https 主站**（`/YCFS_APP/*` 剥前缀保留路径参数），不再代理应用 |
| `0.0.0.0:34080` | 直传（**仍由 940 提供**）：HTTPS 存活（`/transfer/upload`→401），HTTP 返回 410 |
| `127.0.0.1:34294` | 语音 ASR/TTS（`/healthz` 无 key 返回 401） |

### 1.5 最近变更（2026-11-22～23 批次）

- **本批 devlog 区间**：`devlog.jsonl` 第 26–36 条（2026-11-21T11:15 起，含 11-21 晚间发布与 11-22～23 进展）——V21.54（g265）→ V21.58（g269）五次发布，外加培训物料硬链接、会话标题现场恢复、34038 明文入口收口、文件同步 timer 恢复、充值看板误判排查、940 镜像端口清单。
- **关键状态变化**：主位 `Test V21.53 / g264 / asset V21.48 / schema 143` → `Test V21.58 / g269 / asset V21.50 / schema 144`；文件同步 timer 从 inactive 恢复为 active；34038 从「明文镜像整个应用」改为「只 301 跳转」。

---

## 2. 读什么才能接手（按顺序）

1. **本文件** —— 现状、地址、规矩（约 5 分钟）。
2. **`features.json`** —— 101 条功能，按 `layer`（web/chat/model/runner/transfer/jupyter/audio/admin/ops）分组；
   每条有 `user_path`（用户怎么走到）、`verify`（怎么验）、`nodes`（940/大禹各自状态）、`known_limits`、`since`、`req_refs`。
   先看 `nodes` 里不是 `ok` 的条目 —— 那就是「会丢的功能」。
3. **`devlog.jsonl` 最近 20 条** —— 每个版本改了什么、为什么、怎么回滚。
   `tail -n 20 docs/devlog/devlog.jsonl`（一行一条 JSON；`jq -r '.ts+" "+.version+" "+.kind+" "+.title'`）。
4. **台账（不在本仓库）** —— 工作区 `YCFS_APP_核查清单_合并版.md`（需求原话 + 勾选状态）、
   `handoff/`（HANDOFF、运维机制归档、大禹补齐清单、监控说明）、
   `YCFS_940_vs_大禹_功能对等审计_20261121.md`（切换会丢什么，含证据）。
5. 需要动运维时再看：`handoff/YCFS-运维机制归档.md`（发布六步、catalog 形状、切换/同步/502 分诊）。

> 只读三个文件就能接续的最小集合：**CONTINUITY.md → features.json → devlog 最近 20 条**。

---

## 3. 怎么验「功能没丢」

### 3.1 一条命令

```bash
# 在 940 上（默认只跑 http 条目，符合「只读」约定）
python3 docs/devlog/scripts/check_features.py

# 连 cli 条目一起跑（推荐：能覆盖 worker / 语音 / 同步 / 栅栏 / 磁盘）
python3 docs/devlog/scripts/check_features.py --include-cli

# 换目标（例如在别的机器上跑同一份清单）
python3 docs/devlog/scripts/check_features.py --base http://127.0.0.1:34039/YCFS_APP
```

- `kind=http`：只做 GET / 空体 POST 的路由存在性探测（未登录时预期 `401/405/409/303`，**不产生业务写入**）。
- `kind=cli`：`systemctl is-active` / `ss` / `df` / `sqlite3 mode=ro` 一类只读命令，需要 `--include-cli` 才跑。
- `kind=ui`：不自动跑，输出 `MANUAL`，**必须人工点一次**（需要登录态或管理员身份）。

退出码：`0` 无 FAIL，`1` 有 FAIL，`2` 用法错误。可以直接进 CI/cron 做「功能回归闸门」。

### 3.2 940 首轮真实结果（2026-11-21 11:08，`--include-cli`，在仓库副本里跑）

```
features: /tmp/YCFFS_APP_verify/docs/devlog/features.json
base    : http://127.0.0.1:34039/YCFS_APP
mode    : http+cli

| layer | OK | FAIL | MANUAL |
|---|---|---|---|
| web | 8 | 0 | 6 |
| chat | 5 | 0 | 7 |
| model | 5 | 0 | 4 |
| runner | 7 | 0 | 6 |
| transfer | 8 | 0 | 2 |
| jupyter | 4 | 0 | 3 |
| audio | 5 | 0 | 2 |
| admin | 8 | 0 | 1 |
| ops | 16 | 3 | 1 |
| **合计** | **66** | **3** | **32** |

汇总: OK=66 FAIL=3 MANUAL=32
```

> 输出里的 `features:` 是仓库副本的绝对路径，随机器而异；数字与判定不受影响。
> 同一份清单在大禹上跑会多出 15 条 FAIL（见 §3.3）——那正是「备机缺」的清单。

**940 上这 3 个 FAIL 都是「真缺」，不是脚本误报：**

| id | 实测 | 是什么 | 影响 / 怎么补 |
|---|---|---|---|
| `ops.switch_script` | `absent` | `/usr/local/sbin/ycfs-switch.sh` 不存在（940 只有 `ycfs-db-sync.sh`、`ycfs-unit-health.sh`） | 计划内切换现在只能手工改 nginx；脚本本体在 `ycfs-switch-hardening-20261120/`，需官网机 root + 一次性 key 安装（台账 2026-11-20-#9） |
| `ops.files_sync` | `inactive`（`Result=signal`，`status=15`） | 文件/工作区同步 timer 自 2026-11-20 20:31 起未成功 | 最近会话的文件在备机缺失（「会话在、文件没了」）；先查 `journalctl -u ycfs-dr-sync-files` 再重跑 `--only files` |
| `ops.legacy_port` | 仍在监听 | `0.0.0.0:34038` 历史对外端口没关（返回 301） | 第二张暴露面；核实后关掉，或加进监控清单 |

> **2026-11-23 复核**：上表 3 条 FAIL 里，`ops.files_sync` 已消除（timer active）；`ops.legacy_port` 的判据仍是「34038 不监听」，实测仍在监听（但已改为只 301 跳转、不再代理应用，风险性质变化，判据本身未改）；`ops.switch_script` 仍未安装。上表是 2026-11-21 的基线快照，未改历史。

其余 66 条 OK 的关键判据（都是这次真跑出来的）：

| 判据 | 实测值 |
|---|---|
| 8 个 worker | `8`，`worker@1` active |
| 队列无积压 | `pending=0`（`canceled=6` 证明取消能力历史上可用） |
| bwrap 沙箱 | `/usr/bin/bwrap`（0.4.0） |
| 语音 | unit active、34294 在听、`/api/voice/asr|tts` 路由存在（409）、`/api/voice/availability` 401 |
| Jupyter | `/jupyter/s/test/` → 303、`jupyter lab` 进程 2 个、bwrap 包着 jupyter |
| 直传 | HTTPS `/transfer/upload` → 401（端点活着）、HTTP 根 → 410（明文已退役）、DNS → `119.62.67.134` |
| 网关 | `hot-gateway` 1 个进程、catalog.current=`g264`、generations=10、hot-retire timer active |
| 监控 | `OK 17/17 active`（`/run/ycfs-unit-health/status.json`） |
| 同步 | db timer active、`lag=0s`、version 比对 `ok` |
| 栅栏 | `.ycfs-read-only=0`（主位可写） |
| 备份 | crontab 命中 2 条（日备 + 4h 备） |
| 磁盘 | 89%（闸门是 <90%） |
| SMTP | 940 = 6 个键；大禹 = 0 |

### 3.3 同一份清单在大禹上跑：备机缺什么（2026-11-21 11:09，4 个 layer）

```
| layer | OK | FAIL | MANUAL |
|---|---|---|---|
| runner | 2 | 5 | 6 |
| transfer | 5 | 3 | 2 |
| jupyter | 1 | 3 | 3 |
| audio | 1 | 4 | 2 |
| **合计** | **9** | **15** | **13** |
```

**备机缺（切换后会坏的功能，全部有实测判据）：**

| id | 大禹实测 | 说明 |
|---|---|---|
| `runner.workers` | `0` | 只有 `ycfs-dr-worker@.service` 模板（disabled），0 实例 ⇒ 任务永远 pending |
| `runner.worker_alive` | `inactive` | 同上 |
| `runner.task_timeout_env` | `0` | worker 环境变量不存在（无实例） |
| `transfer.upload_34080` | `000`（拒连） | 无 34080 监听；域名永远指 940 ⇒ 大禹发的直传 token 到 940 必然 `invalid transfer` |
| `transfer.read` | `404` | 无 `/transfer` 路由 |
| `transfer.http_retired` | `000` | 无该端口 |
| `jupyter.route` | `404` | V21.51 没有 `/jupyter/s/{sid}` 路由 |
| `jupyter.lab` / `jupyter.sandbox` | `0` / `0` | 无 Jupyter 实例 |
| `audio.service` | `inactive` | 未安装语音服务 |
| `audio.port` | `0` | 34294 无监听 |
| `audio.asr` / `audio.tts` | `503` | 路由不在/被栅栏挡；点了必失败 |
| `runner.queue_pending` / `runner.cancel` | python 报错 | 这两条 cli 命令里写死了 **940 的库路径**；备机上路径不存在 ⇒ 不是功能判据，别误读 |

> 在备机上跑自检时注意：`features.json` 里 `cli` 条目的路径默认是 **940 的**（`/data3/...`）。
> 备机上 FAIL 要先看是不是路径问题；`nodes.dayu` 字段才是我们维护的「备机状态」。

### 3.4 MANUAL=32 怎么处理

这 32 条是 `kind=ui`：会话列表、文件树、预览/圈选、主题、移动端、工具调用、代码者模式、
Notebook 面板、语音输入/朗读、任务 OOM/超时、Jupyter 配额/回收、管理员用户页等 ——
都需要登录态或点击。建议每次发版挑 8–10 条关键路径人工过一遍（对话→工具→产物→预览→导出），
其余靠 `--include-cli` + 路由探测兜底。

---

## 4. 改东西的规矩（硬要求）

1. **先读**：`devlog.jsonl` 最近 20 条 + 相关 `features.json` 条目 + 台账里对应需求。没读就改 = 大概率回滚别人的修复。
2. **改完必须追加一条 devlog**（不许改历史行，文件是追加式）：
   ```bash
   python3 docs/devlog/scripts/append_devlog.py \
     --version V21.54 --kind release \
     --title "V21.54（g265）…" \
     --summary "改了什么、为什么、影响面" \
     --files web/static/chat.js,web/asset-urls.json \
     --verify "[940] curl -s '127.0.0.1:34039/YCFS_APP/healthz?format=json' 期望 asset_version=V21.49" \
     --rollback "sudo bash …/deploy_g265_official.sh --rollback" \
     --req-refs 2026-11-21-#2 \
     --evidence "catalog.current=g265；asset V21.48→V21.49"
   ```
   `--kind` 只能是 `release / fix / ops / incident / decision`。脚本会：补 `ts`、写前 `json.loads` 复核、
   追加后逐行复核；`--check` 可随时体检。
3. **必须跑一次功能自检**：`python3 docs/devlog/scripts/check_features.py --include-cli`。
   FAIL 数比上次多 ⇒ 要么修回去，要么在 `known_limits` 里写清楚「为什么可以红」。
4. **新功能要进 `features.json`**，并且 `verify` 必须真能跑（不确定就 `kind=ui` + `known_limits` 标注，
   **不许编命令**）。
5. **不写密钥**：`features.json` / `devlog.jsonl` / 本文件都**不得**出现密码、Token、私钥、`.keyring` 内容。
   只写路径、sha256、判据。
6. **本仓库只放文档**：README/CHANGELOG/docs/images + `docs/devlog/` 的文档与两个只读脚本，**不放产品代码**。
7. **不要整篇重写台账**（`YCFS_APP_核查清单_合并版.md`）：只追加、只改单行，用户会在预览区手勾。

---

## 5. 已知风险与取证缺口

| 项 | 现状 | 建议 |
|---|---|---|
| 直传 34080 永远指 940 | 切到大禹后上传（含头像/录音/朗读）100% 失败，且闸门查不出 | 要么把 34080 代理到大禹，要么切换时同时改 `DSAPP_TRANSFER_BASE_URL` 并禁直传 |
| 备机 0 worker | 切过去任务永远「排队中」 | 先补 `conf/dsapp.env`（现在 0 字节）+ `systemctl enable --now ycfs-dr-worker@{1,2,3}`，跑一条最小 R/Python 验收 |
| 备机无 Jupyter / 语音 / 备份 / 监控 | 见 §3.3 | 按 `handoff/大禹备机补齐清单.md` 的 P0 顺序补；**补完再谈升格** |
| 切换脚本未安装 | 计划内切换只能手工改 nginx | 装 `ycfs-switch-hardening-20261120/install.sh`（官网机 root） |
| `/data3` 89% | 旧代目录 + 报告转图（Chromium）会涨 | 盯 `ops.disk`；旧代交给 `ycfs-hot-retire`，**不要手删正在跑的代** |
| 历史取证缺口 | 台账/交接/复盘里**没有**「930 / 490」事故记录（检索无果） | 如果它们指某台机器或某个窗口，请补一条真实 devlog，不要靠猜 |

---

## 6. 这份体系的自我维护

- `features.json` 的 `checked_on` / `updated_at` 在每次全量自检后更新（人工改，别自动写库）。
- `devlog.jsonl` **只追加**；`append_devlog.py --check` 必须保持「坏行 0」。
- 本文件 §1 的数字如果与自检输出不一致，**以自检为准**，并当天修本文件（漂移的文档比没有更危险）。
- 首版建立：2026-11-21，`docs(devlog)` 提交；101 条功能、25 条历史日志。2026-11-23：追加 11 条（第 26–36 条，V21.54–V21.58 与 2026-11-22～23 运维）→ 共 36 条。
