# tests/ui_v171 —— `.skills` 被当成用户产物发出去（Test_V17.1）

**用户没报这一条。** 它是 2026-10-08 做 V17 收尾（生产库权限 + 补齐历史产物）
时踩出来的：跑完 `tests/repair_prod.R` 之后回库核对，发现 u1 的文件管理区里
多出 174 个 `.skills/...` 文件。

## 症状链

```
dsapp_sync_repair()            「盘上快照 − 已发布」的**全量**差集
  └─ dsapp_ws_artifacts()       = dsapp_ws_snapshot() 减 dsapp_ws_is_internal()
       └─ dsapp_ws_snapshot()   用 `find`（为的是不跟软链钻出去）
            └─ find **列点文件**，`.skills/` 底下 175 份文档全在里面
  └─ dsapp_ws_is_internal()    只挡 .Rlib / .venv / .pylib / .dsapp_*，**漏了 .skills**
```

`R/skills.R` 里挡着它的本该是注释那句「`.skills/` 是点目录，`fs::dir_ls` /
`list.files` 默认不列它」—— 那句话**只对列目录的写法成立**。快照用的是 `find`，
从一开始就不成立。已把 `.skills` 点名加进内部目录表，并把那段注释改成指向
真正的守卫（`dsapp_ws_is_internal()`）。

## 为什么线上几个月没漏、偏偏那天漏

三个入口里只有 repair 会全量扫：

| 入口 | 传进去的清单 | 会不会带上 `.skills` |
|---|---|---|
| `R/taskrun.R:399` 任务收尾自动同步 | **本次任务**的产物差集 | 不会（技能文件不是这次任务产出的） |
| `dsapp_sync_backfill()` 打开文件页时跑 | 全量，但**只补没有 `sync_dirs` 行**的对话 | 不会（用过技能的对话早就有那行了） |
| `dsapp_sync_repair()` 手动「导入历史产物」 | **全量**（盘上 − 已发布） | **会** |

⇒ 平时静默，手动补齐时一次全出。库里 175 条点路径行的 `created_at`
**全是 2026-10-08**，没有更早的。

## 这一版做了什么

| 文件 | 改动 |
|---|---|
| `R/executor.R` | `dsapp_ws_is_internal()` 的内部目录表加 `.skills`（整段配，不是 `startsWith`） |
| `R/skills.R` | 把那段**假的**保证注释改掉，指向真正的守卫 |
| `selftest.R` | **5 条**断言：1 条**扩展**已有的谓词断言（`.skills/academic-search/SKILL.md` 进那个向量）+ 1 条整段判 + **3 条端到端**；另改了 **2 处版本号字面量**（见下） |
| `R/config.R` | `Test_V17` → `Test_V17.1` |
| `tests/ui_v171/cleanup_skills_publish.R` | 清掉已经发出去的那些（新增） |
| `tests/ui_v171/mut_skills_internal.py` | 上面 5 条断言的变异测试（新增） |

★ 另外改了 `tests/repair_prod.R:196`：`list.files(..., all.files = FALSE)` →
`TRUE`。那是**同一类**问题的第二个实例（尺子自己少报：它报 525、真值 699），
见 ARCHIVE.md。

### 数断言条数别凭印象

本文件第一版写的是「5 条新断言（1 条谓词扩展 + 1 条整段判 + **3 条端到端**）」，
而当时**只有 4 条** —— 不自洽（1+1+3=5，可端到端只有 2 条）。
判据是直接对着两份归档 diff：

```bash
diff -u history_Version/Test_V17_20261008/selftest.R \
        history_Version/Test_V17.1_20261008/selftest.R
```

第一版数出来 **2 个 hunk / 4 行 `chk(`**；后来补了 A_GUARD（第 5 条）才有 3 条端到端。
**这个数改过两次，所以别再凭它下判断** —— 要就重跑一次 diff。

### ★ 版本号字面量散在两处，改版本号必须一起清

`selftest.R` 里有**两处** `identical(DSAPP_VERSION, "Test_VXX")`：`L18513` 和
`L27302`（后者还带一句 `chk("★★★ DSAPP_VERSION 是 Test_V17", ...)` 的**标签文字**）。
`L18508` 那句注释写着「看它红了就改这**一个**字符串」——**是错的，改一个不够**。
第一次跑自检就红了 L18513 那一条，第二处要等跑到 27000 行才冒出来。

⇒ 改版本号之后：`grep -rn '"Test_VXX"' --include='*.R' .`（引号收尾，
不然 `Test_V17` 会把 `Test_V17.1` 也匹上），确认只剩新版本号。

## 为什么断言要分「谓词」和「端到端」两层

修的是**纯谓词**的洞，这类修复最容易自欺：断言写成
`dsapp_ws_is_internal(".skills/x")` 就全绿了，而真正出事的是**调用点**
（`dsapp_ws_artifacts()` / `build_file_section()`）有没有去调它。
谓词全绿 + 调用点漏一个，屏幕上和"修好了"长得一模一样。

所以 5 个变异里有 **2 个（M3/M4）完全不碰谓词**，只把某一个调用点的过滤拆掉。
它们的作用就是证明"端到端那两条不是谓词那两条的复读机"。

还有 **M5**：谓词、调用点都不动，只把 `dsapp_ws_rlib()` 返回的 `.Rlib` 改名成
`.renv` —— 那正是 `.skills` 这次漏掉的**形状**（手写黑名单 + 加了目录没加表）。
M5 会让 A_GUARD 红、而 A_ART 照样绿 ⇒ 证明 A_GUARD 不是 A_ART 的复读机。

## 怎么跑

```bash
Rscript --no-environ selftest.R                      # 静态 + 端到端（含上面 5 条）
python3 tests/ui_v171/mut_skills_internal.py         # 变异，约 15 分钟（6 份，5 路并行）
python3 tests/ui_v171/mut_skills_internal.py --from-logs   # 不重跑，只读回已有日志复查
```

### ⚠️ 那两条 `.Rlib` 断言会**随机**红，别当成自己改坏了

`install.packages() 不指定 lib 就装进对话库` 和 `重建前 .Rlib 里有东西`
（`selftest.R:1641/1684`，section「每对话增量库（阶段 1.4）」）**真的在子进程里
`R CMD INSTALL` 一个包**。5 路并发跑时安装会失败，而失败只进 stderr ⇒ stdout 里
没有 `FOUND_AT` ⇒ 红。

实测：**单进程**跑（在仓库里跑那次）两条都绿；**5 路并发**跑，上一轮红在 M3、
这一轮红在**基线** —— 位置随机 = 负载决定。所以脚本把它们放进
`UNRELATED_FLAKY`，**基线里多出它们不算脏、某个变异里少了它们也不算"该红没红"**。

（不是"忽略红"：它们是**照报的**，只是不参与差集判定。）

# 清理（已经跑过了，盘和库都归零；留着是为了以后同类问题能照抄）
Rscript --no-environ tests/ui_v171/cleanup_skills_publish.R           # 只报不改
Rscript --no-environ tests/ui_v171/cleanup_skills_publish.R --apply   # 真删
```

### 清理脚本的三个坑（第一版全踩了）

1. **`cfg$files_dir` 不是文件区的根**，它默认是 `data/files/_anon` —— 一个
   **永远是空的**目录（`R/config.R:1232` 故意这么设的：忘了带账号时要
   "错得响、错得安全"）。第一版用它，跑出来"盘上 0 个目录、库里 174+174 行"，
   真 `--apply` 的话会**删光库行而一个文件都不动**，下次谁开管理页
   `dsapp_files_sync_owners()` 又把行登记回来 —— 一次标准**假修**，
   屏幕上还写着「✔ 清干净了」。要的是 `cfg$files_root`。
2. **只判 `dir.exists` 不够**：`_anon` 也是存在的目录。得再判一层结构
   （底下必须有 `u<数字>` 账号区），否则"扫到 0 个"和"路径接错了"长得一样。
3. **两把尺子要互相对**：盘上扫到 0 个而库里有 174+174 行，那两个数不该
   同时成立 —— 这个不对称本身就是"其中一把尺子坏了"的判据，现在它会
   `stop()` 而不是继续删。

### 删除本身的两条纪律

* **先删盘、后删库**。理由**不是**"扫盘会把行登记回来"（这句是错的，
  2026-10-08 查证后改的）：行是 `dsapp_sync_artifacts()`（`R/files.R:2419-2423`）
  在**发布那一刻**写进去的，跟扫盘无关。真正的机制是**盘上文件还在 + 
  `ws_published` 行被删** ⇒ `dsapp_sync_repair()` 的差集里又是这 175 个 ⇒
  谁再点一次「导入历史产物」就重新发布一遍，两处行一起回来。
* ⚠️ 顺带纠正一个想当然：`file_owner` 那半边**本来就自愈** ——
  `dsapp_files_sync_owners()` 走的 `dsapp_shared_scan()` 是
  `find <dir> -type f -not -path '*/.*'`，**按设计不扫点路径**（V13.10 起），
  管理页渲染时还会先跑 `dsapp_files_purge_dotfiles()`。所以那 174 行碰上一次
  管理页就自己没了。**但"它自己会好"≠"清干净了"**：文件还在盘上、
  `ws_published` 还在，用户在文件管理区里**照样看得见**那 175 个东西 ——
  那才是用户能感知的部分。
* **判据只认 `.skills` 这一整段**，不是"任意点路径"。应用自带的
  `dsapp_files_purge_dotfiles()` 取的是后者（理由是"删错点文件的代价是零"），
  但那是**一条更宽的断言**，不该拿它来执行一次范围已经批准过的删除。
  范围外的点路径这个脚本只**报**不删。

## ★ 阴性对照：`data/workspaces/**/.skills` 必须原封不动

文件区那份是**副本**；**工作区里那份才是模型真正读的**
（`R/prompts.R` 明着让模型去读 `.skills/<技能名>/SKILL.md`）。清理只走
`files_root`，绝不进 `ws_root`。清完核对过：文件区 0 个、工作区 4 个目录
174 个文件，两边独立数过。

## 实际读数（2026-10-08 17:2x）

| | 清理前 | 清理后 |
|---|---|---|
| 文件区 `.skills` 目录 / 文件 | 5 / 175（2.072 MB） | **0 / 0** |
| `file_owner` 点路径行 | 174 | **0** |
| `ws_published` 点路径行 | 174 | **0** |
| `file_owner` 总行数 | 1458 | 1284（−174） |
| `ws_published` 总行数 | 545 | 371（−174） |
| 工作区 `.skills`（阴性对照） | 4 目录 / 174 文件 | **4 / 174，未动** |

> ⚠️ 数字**现读**，别抄这份表。生产是活的：查的过程中 u11 就把自己所有
> 对话删了（`sessions` 里只剩一个 17:20 建的），`ws_published` 随之从
> 1261 掉到 545 —— 那是**级联删干净了**（没有孤儿行），不是异常。
> 任何"少了多少行"的结论都要先分清是哪一版/哪一次操作弄的。
