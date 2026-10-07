# tests/ui_v1316 —— Test_V13.16 的浏览器验收

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8916 /tmp/dsapp_v1316

# 2. 跑
python3 tests/ui_v1316/probe_v1316.py        # 退出码 0 = 全绿
```

脚本里的默认值（`URL` = `http://127.0.0.1:8916/`、`APP` = `/tmp/dsapp_v1316/app`、
`OUT` = `/tmp/dsapp_ui_v1316`，见 `_common.py` 顶上）和上面那条命令是**一套**，
起完直接跑就行，不用设环境变量。

> ⚠️⚠️ **起实例时别绕开 `make_instance.sh` 自己 rsync。** 这条是这一版新加的、
> 也是最险的一条：仓库根目录下的 `.Renviron` 里 `DSAPP_DATA_ROOT` 指的是
> **线上数据目录**（`/data3/biomamba/analysis/DS_App/data`）。整目录 rsync
> 时如果没排除它，实例会**连着生产库**启动 —— 而它照样能起来、照样监听端口，
> 页面上一点异样都没有。2026-09-26 就这么起过一次（发现后立刻 kill，
> 确认没写进去）。手工拷的话：
>
> ```bash
> rsync -a --delete --exclude '.Renviron' --exclude 'data/' --exclude '.git/' \
>   --exclude 'history_Version/' --exclude '*.log' \
>   /data3/biomamba/analysis/DS_App/ /tmp/dsapp_v1316/app/
> printf 'DSAPP_DATA_ROOT=/tmp/dsapp_v1316/data\n' > /tmp/dsapp_v1316/app/.Renviron
> ```
>
> 另有一个反向的坑：`rsync -a --delete R/ <目标>/` 这种**带尾斜杠的多源**写法，
> 会把 `R/` 的**内容**摊进目标根目录，再把目标里其它东西全删掉（`app.R`、
> `www/`、`selftest.R`……）。实例会起不来，报 `App dir must contain either
> app.R or server.R`。源必须是**仓库根**、并且带尾斜杠。

> ⚠️ 实例里 `R/*.R` 只在**进程启动时** source 一次（这里是 `shiny::runApp`，
> 没有线上那套 worker 换代）。所以做完变异验证要**重启实例**才看得到变异生效 ——
> 只停旧 pid + 重起、**不重新拷代码**的那一小段见「变异验证」一节。

> ⚠️ 本探针**不需要**假模型服务，一次模型调用都不发，只量界面 + 点按钮。

## 这一版管什么

| 工单 | 一句话 | 断言 |
|---|---|---|
| item 27 | 文献速递的产出是「文献阅读汇报」，不是检索过程的画外音 | 页面上写着这句；填关键词 → 点「看看会发什么」→ 预览里明写「文献阅读汇报」「不是检索过程的画外音」「**不要**出现「我先检索了…」」；五节按 **1 这批文献讲了什么 → 2 精读 → 3 略读 → 4 一句话总览 → 5 附：检索记录** 排；老的第 1 节「检索概况」不在 |
| item 28 | 技能页整页渲染崩（`subscript out of bounds`） | 页面上没有那句英文报错、没有 R 原文报错、没有应用自己的兜底卡片；技能行 ≥ 12；`academic-search` / `deeppapernote` 都在；**展开**它们，「来源」是「内置」；有 repo 的那几条「来源」还在 |
| item 29 | 新增内置技能 `paper-reading` | 它出现在列表里；展开看得到文件树（`scripts/`、`templates/` 都在）；树里**没有** `api_key` / `key.txt` |
| item 30 | 技能页「关于技能」换成新介绍 | 新介绍 + 三条例子 + 「本平台支持自定义技能并上传」都在；老的开头没了；**反向**：操作说明一条没少（按对话挂载 / 公共技能库 / 另存为我的） |

### 为什么这几条非要在浏览器里再验一遍

自检（`Rscript selftest.R`）已经把源码证到位了。浏览器这一边回答的是另外几个问题，
它们可以各自单独坏掉而源码级断言全绿：

1. **item 28 崩的是一个 `renderUI`。** 出错时 Shiny 把**那一整块**换成一句报错文本，
   所以表现不是"少了一行"，是"**一条技能都没有**"。而那句话在本地实例上是 R 的原文
   （`subscript out of bounds`），在线（`sanitize_errors` 开着，见 `R/errhand.R`）是
   `An error has occurred. Check your logs or contact the app author for clarification.`
   —— **两句都要断**，只断一句的话另一种线上的表现会漏掉。
2. **"有没有真的画出来"只有浏览器知道。** 自检能证明 `meta` 是 list、能证明每条内置
   技能都取得到 `repo`，但它证明不了 seed 真的把这条技能种进了库、列表真的把它渲染出来了。
3. **item 27 的用户可见面是页面说明 + 预览。** 提示词改了、说明没改、或者预览压根没接上
   提示词，自检全都绿。
4. **item 30 是纯文案改动**，唯一能验的就是"页面上那一刻显示的是哪几个字"。

## 四个坑（都踩过，别再踩）

**1. ★★ 展开过的技能行不会自己合上 —— 全局 `.dsapp-skill-tree` 拿到的是别人的树。**
item 28 那节先展开了 `academic-search`，到 item 29 再写
`pg.locator(".dsapp-skill-tree").first` 时，拿到的**还是 academic-search 那棵树**
（它排在前面）。报出来的是「文件树里没有 `scripts/`」，打出来的却是
`references/ disciplines/ …` —— 看着像 "paper-reading 的配套文件没收进来"。
现在走 `row_tree(pg, name)`：先按 `.dsapp-skill-name` 找到那一行，再在**行内**取树。
（和 V13.15 记的"隐藏元素的矩形是全 0"同一类：**量之前先确认量的是哪一个**。）

**2. ★★ 「来源」那一行在收起的 `<details>` 里，收起时读不到。**
第一版直接在行文本里找 `" · "`，结果 18 行一条都找不到，报的是
「老的那批仍然显示「仓库 · 许可」只有 0 行带来源」，看着像"修 item 28 把来源信息
弄丢了"。技能行是 `<details class="dsapp-skillgroup">`，`来源` 在
`.dsapp-skill-files` 里 —— **先点一下 `summary` 再读**（`expand_src()`）。

**3. ★★ 别让脚本炸 —— 一炸，后面整段都"没跑到"。**
`pg.wait_for_selector()` 超时抛的是 playwright 的 `TimeoutError`，脚本当场结束。
V13.15 变异验证时踩到过：输出停在半路，看着像"后面几条也一起坏了"。
这里等待一律走不抛异常的 `wait_for()`，几何量取走 `vis()` / `.count()` 兜底。
（V13.14、V13.15 也各记过一次，是同一个毛病。）

**4. ★ 条目之间的断言必须互不牵连。**
item 29 / 30 各自 `C.goto` 之前先确认页面上是什么状态，不靠上一条的展开/收起。
item 28 的三组断言（有没有报错 / 列表画出来没有 / 来源那一行对不对）**各自独立算**。

## 这一版做过变异验证

按仓库约定，承重最大的几条断言都反向验过 —— **改坏实例副本**（不是源码，
更不是线上那份）看它会不会红：

```bash
# 变异 A：把 meta 改回 character(0)（item 28 的原样）
python3 -c "
import io;p='/tmp/dsapp_v1316/app/R/skills.R';s=io.open(p,encoding='utf-8').read()
io.open(p,'w',encoding='utf-8').write(s.replace('\n  meta <- list()\n','\n  meta <- character(0)\n'))"

# 变异 B：去掉 paper-reading 的 repo: 行（item 29）
# 变异 C：技能页介绍退回旧文案（item 30）—— 见本版 ARCHIVE.md 里的原命令

# 重启实例（只停/起，**不重新拷代码**，否则变异会被覆盖掉）
bash /tmp/restart_v1316.sh          # 或照抄 tests/ui_v1315/README.md 里那段
```

浏览器探针这一侧（`probe_v1316.py`，31 条）：

| 变异 | 结果 |
|---|---|
| A：`meta <- list()` 改回 `character(0)` | **7 条红**：R 原文报错露出来、技能行 0 行、两条技能都不在、展开读不到来源…… ✔ 正是它该抓的 |
| B+C：去掉 `repo:` + 介绍退回去 | item 29 红 **1** 条（展开后看不到 `huicod/paper-reading-skill`）；item 30 红 **4** 条（新介绍 / 三条例子 / 本平台支持 / 老开头没了）✔；**item 28 那节 11 条仍全绿** ✔ 两块互不牵连 |

> ⚠️ 变异 A 下 **「页面上没有那句英文报错」仍然是绿的** —— 这是对的，不是漏网。
> 本地实例没开 `sanitize_errors`，露出来的是 R 原文，那句英文本来就不会出现。
> 两条分开断就是为了这个。

自检这一侧（同一份变异，在实例树里 `cd /tmp/dsapp_v1316/app && Rscript selftest.R`）：

| 变异 | 结果 |
|---|---|
| A：`meta <- list()` → `character(0)` | item 28 那节红（「每一条内置技能都渲染得出」「meta 里取不存在的键返回 NULL」…）✔ |
| B：去掉 `repo:` | item 29 那节红 **1** 条（有 repo / license）✔，其余 12 条仍绿（配套文件、适配说明那些本来就没动）|
| C：介绍退回旧文案 | item 30 那节红 **7** 条 ✔；**「操作说明原样留着」仍是绿的** ✔ —— 它断的是"没被顺手删掉"，和介绍换没换是两件事 |

> ⚠️ **在实例树里跑自检会多出 2 条 deploy 红，那不是代码问题。**
> 实测确认：`deploy_link.sh --check` 的前提检查要求应用目录下有 `data/`，
> 而实例的 `data/` 在**上一层**（`/tmp/dsapp_v1316/data`），于是脚本在前提检查
> 就退出了（`✗ 没有 data/`），"旧地址还活着"那段根本没跑到。仓库里跑没有这 2 条。
> 看到它们别去改代码。

变异做完**从源码整份拷回去**再跑一遍，确认 31 条全绿。验收时的实测数：
自检 **2688 条全绿**，探针 **31 条全绿**。

## 这一版的自检补了四节

`selftest.R` 里新增 item 27 / 28 / 29 / 30 四节，共 **35** 条（2653 → 2688）。
两处判据的写法值得记一下：

- **判据不能比被测对象大。** item 29 有一条（V13.12 留下的）原来是
  `!grepl("\n5. ", p)` —— 在整个提示词上找"编号到 4 为止"。item 27 把产出结构改成
  5 节之后，第 5 节那行 `5. **附：检索记录**` 正好以 `\n5. ` 开头，这条当场变红，
  而入口表一个字都没动。现在先把提示词切到 `## 产出什么` 之前再查。
- **判据词必须是这一句独有的。** item 27 的节顺序**不能**拿「附：检索记录」当路标 ——
  它在 ★ 说明块和红线里都出现过，量到的是**第一次提及**的位置（在内容节**前面**），
  顺序断言会当场变红，而结构其实是对的。现在量的是编号行本身。
- **markdown 文件不能过 `strip_comments()`。** item 27 要查
  `skills_builtin/literature-digest.md`，而 `#` 在 markdown 里是**标题**不是注释 ——
  剥完整个文件就空了，断言会变成在空字符串上比对（"恒绿"）。
  `R/mod_skills.R` 那种 `.R` 文件才过，而且**必须**过：判据词在注释里也出现过。

`_common.py` 是共用的：`enter_app()` 建号进应用（返回 email）、`seed_or_die(email)`
拿到 `(uid, db_path)` 并**确认这个实例读的不是线上库**（找不到就硬退出）、
`goto(page, name)` 切页（认 value 也认中文页名，切完回读左栏高亮）、
`pick_select()` 选 selectize、`Chk()` 记断言（`.done()` 返回 0/1）。
