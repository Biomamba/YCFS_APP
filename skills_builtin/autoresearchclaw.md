---
name: 自主研究循环与实验记录规范
summary: 把研究问题跑成闭环：文献、可证伪假设、实验记录格式、成败判据、迭代停止与产出组织
tags: 研究循环, 假设检验, 实验记录, 迭代决策, 科研写作, 可复现性
repo: aiming-lab/AutoResearchClaw
license: MIT
---

# 自主研究循环与实验记录规范

## 什么时候用这条技能

用户给的是**研究问题**（不是"帮我跑一下这个脚本"），要走完"查文献 → 提假设 →
设计实验 → 跑 → 分析 → 判断是否再来一轮 → 写出来"整条链路时用它。触发语：
"研究 X 对 Y 有没有影响""这个方向能不能出文章""设计一组实验验证某机制"；或一个
对话的任务序列已累积成一条论证线，而非一次性取数。单纯数据处理/画图不适用——
套研究循环更慢。

⚠️ 前提：**每个数字都要能追到一次真实执行**；产不出可复现中间文件的那一步等于没做。

---

## 一、循环的形状

```
A 界定问题    1 立目标 → 2 拆子问题
B 文献        3 检索策略 → 4 收集 → 5【检查点】筛选 → 6 抽知识卡
C 综合        7 聚类找缺口 → 8 生成可证伪假设
D 设计        9【检查点】实验方案 → 10 写代码 → 11 资源排期
E 执行       12 跑 → 13 改-跑-评循环（自愈）
F 分析决策   14 结果分析 → 15 决策：PROCEED / REFINE / PIVOT
G 写作       16 提纲 → 17 初稿 → 18 评审 → 19 修订
H 收尾       20【检查点】质量门 → 21 归档 → 22 导出 → 23 引文核验
```

三个检查点必须停下来看一眼：**文献筛选后**（怕筛掉关键论文，驳回 → 回第 4 步）、
**实验方案定稿后**（基线/指标/消融在此定死，驳回 → 回第 8 步）、**质量门前**（驳回
→ 回第 16 步重写）。第 15 步可触发两个回退环：`REFINE` → 回第 13 步，**假设不动**
只改参数/实现重跑；`PIVOT` → 回第 8 步，**丢弃假设**重生成（前面的工作作废，能
REFINE 就别 PIVOT）。两者都有次数上限（见阈值表），到顶**强制 PROCEED**，把未达标
项作为 caveat 写进产出，不无限循环。

**先文档后代码**：第 1–9 步只产出文档，一行代码都不写——动手前"要测什么、拿什么
当对照、什么结果算支持、什么结果算证伪"必须白纸黑字写下来。

---

## 二、主流程

### 1. 立目标 → `goal.md`

六节固定：`Topic / Scope / SMART Goal / Constraints / Success Criteria /
Generated`；验收标准是**目标可判定**（什么程度算成功、什么情况算失败），写不出
Success Criteria 就是问题没界定清楚，别往下走。

### 2. 拆子问题 → `problem_tree.md`

拆出 **≥3 个子问题并排序**，附风险清单，排序依据（信息量/可行性/依赖）写明。

### 3. 文献：策略 → 收集 → 筛选 → 抽卡

**检索策略** → `search_plan.yaml` + `sources.json` + `queries.json`：定 2–4 个核心
概念并各列同义词，概念间 `AND`、同义词间 `OR`；**≥3 个策略 × 每策略 3–5 条查询，
总查询 ≥8**，查询串是 3–6 个词的短语；覆盖核心主题、相关方法、基准/数据集、理论
基础、应用五面；**确切检索串原样落文件**。选源用本领域主流库（如 PubMed /
Scopus / OpenAlex）；**无外网时**改读本地 PDF/题录库，并在 `sources.json` 里如实
标"离线，未联网核实"。

**纳入/排除标准检索前定好**（年份、语言、文献类型、研究设计）。**筛选**两遍走
（先标题摘要、后全文），逐级记数：命中 → 去重 → 标题摘要排除 → 全文排除（带原因）
→ 最终纳入；这就是 PRISMA 流图，本身是交付物。筛完是**检查点**。

**知识卡**每篇一张落 `cards/`，字段固定：`card_id / title / cite_key / problem /
method / data / metrics / findings / limitations`；`cite_key` 生成后原样贯穿到最终
参考文献。

### 4. 综合 → 假设（`synthesis.md`、`hypotheses.md`）

`synthesis.md`：主题聚类 + **≥2 个研究缺口** + 按优先级排的机会点。是找缺口，
不是写综述。

`hypotheses.md`：**≥2 条可证伪假设**，每条写全四件事——假设陈述（机制型用
"If [操作自变量]，then [预测结果]，because [机制]"）／可测量的预测（**方向 + 大致
量级**，不是"会有差异"）／证伪条件／理由（基于哪几篇）。**显式写出 H0（无效应）
和 H1**——实验目的是拒绝 H0；同一现象提 **2–3 个竞争解释**并各找能区分开的独有
预测；列混杂变量并设计对照；算样本量够不够检出预测效应，事先说清**正结果怎么
结论、零结果怎么结论**。

### 5. 实验方案 → `exp_plan.yaml`（检查点）

必需键：`objectives, datasets, baselines, proposed_methods, ablations, metrics,
risks, compute_budget`。硬约束：

- **基线要有意义**：≥1 个经典方法 + ≥1 个近期 SOTA + ≥1 个"简单但强"的对照
  （线性探针、k-NN 之类），随机基线不算。
- 每个条件写一段 description 说明相对对照改了什么；条件名用 `小写_下划线`
  （指标键直接用它）。
- **消融一次只拿掉一个组件**；**一次只改一个变量**；用标准 train/val/test 划分，
  **绝不在训练集上报测试指标**；指标写清 `direction`，同时报运行时间与内存。

条件数与算力换算（默认单次预算 300 s）：条件数 >100 → 每条件 3–5 个 seed；
>500 → 每因子留 2–3 个代表条件；预算 <300s → 每轮步数 ≤5000，<120s → ≤1000。

### 6. 写代码 + 跑（`experiment/`、`runs/`）

进沙箱前过静态检查：**语法（AST）→ 安全扫描 → 依赖可用性**；安全扫描拦
`subprocess / os.system / eval / exec / shutil / socket` 等危险调用，写了直接被拒。

代码必须有：①**确定性种子**（`numpy.random.seed` / `random.seed`）并把 seed 打进
输出；②**收敛判据**（如目标变化 <1e-8 连续若干轮就停），不是固定跑 N 轮；③**时间
护栏**——主循环前跑一个条件试点打印 `TIME_ESTIMATE: <秒>`，运行中定期查已用时间，
接近预算 80% 时**优雅停止并保存已有结果**。

指标打到 stdout 每行 `name: value`，键名用三段 **`条件名/种子/指标名`**（单 seed
可省中间段）。汇总就是按 `/` 切分来聚合 seed、算均值与离散度的，名字写错后面全是
空表。产物落 `runs/`，日志落 `refinement_log.json`，代码副本落 `experiment_final/`。

### 7. 记录格式（本节是地基）

**每个条件 × 每个 seed × 每个指标都要有一个数，且落成机器可读 JSON**；人读的
markdown 是给分析用的，替代不了它——没有 JSON，判决和图表都没有数据。

**(a) `results.json`** —— 单次运行结果，放**工作区根目录**，只此一份：

```json
{
  "primary_metric": 0.87, "metric_key": "succinate_flux",
  "metrics": {"best_ko_succinate_flux_mmol_gDW_h": 12.4},
  "hypotheses": {
    "h1": {"supported": true, "value": 0.72, "details": "证据字符串 ≥40 字"},
    "h2": {"supported": false, "details": "……"},
    "h3": {"supported": null, "details": "证据不足，无法判定"}},
  "summary": "人能读懂的过程 + 结论叙述",
  "structured_results": {"artifacts": {"figures": ["figures/x.pdf"],
                                       "data": ["output/data/x.csv"]}}
}
```

规则：①数值必须是 JSON number——**不许写 `"NaN"` 字符串、不许塞 numpy 标量**，
缺的用 `null`；②`metrics` 放**全部**数值结果，键名
**自带单位**（`_mmol_gDW_h`、`_1_per_h`、`_sec`）且跨条件可比；③假设判决必须显式，
`supported` 只允许 true/false/null（null = 证据不足），配 `details` 写依据；④下游
**只读一次**这份文件，缺失或格式坏掉整条链归零——写完回头 `json.load()` 验一遍。

**(b) `experiment_summary.json`** —— 全部运行合起来一份：

```json
{"condition_summaries": {"no_dropout": {"n_seeds": 5,
                                        "metrics": {"test_accuracy": 0.931}}},
 "best_run": {"status": "completed", "metrics": {}, "stdout": "…"},
 "total_conditions": 5, "total_metric_keys": 20, "ablation_warnings": []}
```

每个条件的 `metrics` 是**跨 seed 均值**，`n_seeds` 必须 ≥2；汇总前按
`条件/种子/指标` 留一份原始值。`ablation_warnings` 专记"消融条件之间结果完全
一样"——消融跑出相同数字说明改动没生效，是**必须上报的失败**。

**(c) 目录**（可照搬）

`progress/<课题ID>/` 放七份固定阶段文档（立题/方法/理论/实验评估/对比/结论综合/
质量审计），每份开头带 `## Status: PASS/WARN/FAIL`，写不出状态就是没做完。

```
experiments/<课题ID>/
  config.yaml   # 全部参数，唯一真相来源；src/ 放代码
  results/      # metrics.json 逐条指标、run_manifest.json 各条件用时/失败数/
                # 环境、comparison_summary.md、claim_verdicts.json 结论判决
  report/paper.md
  README.md     # 结论 + 复现步骤 + 已知限制
```

**(d) 行式证据表**（比嵌套字典好判读、好统计）→ `results/metrics.json`：

```json
{"topic_id": "S01",
 "metric_rows": [
   {"claim_id": "C1", "method": "proposed", "baseline": "percentile_bootstrap",
    "condition": "student_t_heavy_tailed", "metric": "coverage",
    "value": 0.881, "status": "ok"}]}
```

`status` 记 `ok / failed / timeout / skipped`，**失败行也要写进去**；**每条指标
必须映射到一条事先写好的假设**，映射不上的说明设计有多余项。

**(e) `results/claim_verdicts.json`** —— "结论—理论—实验—对比—限制"串成可追溯链：

```json
[{"claim_id": "C1", "verdict": "supported",
  "theory_support": "在 A1–A3 假设下由推导给出",
  "experimental_support": "在 X–Y 条件下风险更低（附数值）",
  "comparison": "相对基线 B 在指标 M 上更优",
  "limitations": "仅限有限样本；A2 未检验"}]
```

`verdict` 只用 `supported / refuted / inconclusive`，含糊的内容放 `limitations`。

### 8. 分析 → `analysis.md`

固定五节：`Metrics Summary（写真实数值） / Comparative Findings / Statistical
Checks / Limitations / Conclusion`。只引用上一步文件里**真实存在的数**；报了检验
就报**效应量 + 置信区间**；对比在**相同数据条件**下进行（同划分、同预处理、同 seed
集合）；正面解释实验与理论预测不一致之处。三档判据：`PASS` / `WARN`（要披露限制）
/ `FAIL`（缺环节）。

### 9. 决策 → `decision.md`

四节：`Decision / Justification / Evidence / Next Actions`；`Decision` 三选一且必须
**引用具体数值**。发 `reject` 前自查：有效条件数 **<3** 或每条件 seed **<2**；缺
基线或缺待测方法；条件之间结果**完全相同**（消融未生效）；指标出现 NaN/Inf 或贴着
随机水平；时间护栏砍掉大部分条件；退化成合成/假数据。

### 10. 写作与终检

`outline.md` → `paper_draft.md` → `reviews.md` → `paper_revised.md` →
`paper_final.md` → `verification_report.json`。

IMRAD：`Title / Abstract / Introduction / Related Work / Method / Experiments /
Results / Discussion / Limitations / Conclusion`；参考文献自动生成，正文不要自己
造 References 节。字数下限：Abstract 150–250 词，Method 1000–1500 词，
Experiments / Introduction 各 800–1000 词，其余各节 200–800 词，**正文合计
5000–6500 词**（不达标补实质内容，不加水词）；修订**只增不删**，不得短于初稿。

写作纪律：**不要把"环境装不上/依赖冲突/调试日志"当成研究成果写进去**；Method 写
方法不是工作流，Results 报定量结果不是运行状态；每个论断要么有引文要么有本次数据
支撑；**不要把要点列表当最终稿**。

**同行评审**（≥2 个视角）：①是否跑题；②**方法-证据一致性**——论文声称的试验次数、
统计检验、超参、基线是否与实际代码和数据对得上（声称 100 次独立试验而实际只跑
1 次，按严重造假处理）；③篇幅是否达标。评分 1–10：1–3 拒 / 4–5 边缘 / 6–7 弱接收
/ 8–9 接收 / 10 强接收。

**引文核验**（最后一关）：每条文献走四层——会议/期刊 ID 或 arXiv ID 能否查到 →
DOI 能否解析 → 标题能否匹配 → 与正文论断是否**语义相关**；核不实的**直接删掉**
（离线时按本地题录/PDF 逐条核对），结果落 `verification_report.json`。

**归档**：`archive.md` + `bundle_index.json`，教训归六类（questions / literature /
experiments / findings / decisions / reviews）。

---

## 三、判据与阈值

| 判据 | 默认值 | 什么时候改 |
|---|---|---|
| 有效条件数下限 | **≥3** | 探索性课题可降到 2，但产出降级为"初步研究" |
| 每条件 seed 数 | **≥2**（推荐 3，最好 5） | 方差大的加到 5–10，再紧也不低于 2 |
| 单次执行时间预算 | 300 s | 重计算课题按实测放大，同步收敛条件数与步数 |
| 收敛判定（目标变化） | < 1e-8 连续若干轮 | 噪声大的目标放宽容差并说明 |
| REFINE / PIVOT 次数上限 | **2** | 调高会让循环失控；到顶强制 PROCEED + 写 caveat |
| 连续 REFINE 仍无有效指标 | 1 次即强制 PROCEED | 别在这个条件下继续烧算力 |
| 质量门分数 | **7.0 / 10**（文献纳入用 4.0 / 5） | 目标档次高的往上调 |
| 迭代收敛窗口 | 连续 2 轮分数波动 < 0.5 即停 | 分数抖动大时放宽窗口 |
| 全流程迭代上限 | 3 轮（只重跑写作+导出段） | 每轮必须带上一轮评审意见 |
| 实验修复循环 | 3 轮；条件完成率 ≥0.5 | 完成率不到一半说明方案有问题，回去改设计 |
| 效应量参考线 | d 0.2/0.5/0.8；η² 0.01/0.06/0.14 | 领域有惯例用惯例 |
| 统计假设检查 | 正态性 n<50 用 Shapiro-Wilk 否则 Q-Q 图；t/ANOVA 前做 Levene；回归 VIF<5 | 不满足就换非参检验 / Welch / 去掉共线变量 |
| 图规格 | 300 dpi；单栏 3.3–3.5 in，双栏 6.5–7.1 in | 按目标期刊作者指南调 |

**检验怎么选**：两组独立 → 正态用 t、非正态用 Mann-Whitney U；配对 → 正态用配对
t、非正态用 Wilcoxon 符号秩；3+ 组 → 正态用单因素 ANOVA + 事后检验、非正态用
Kruskal-Wallis；关系 → Pearson / Spearman；分类结局 → 卡方 / Fisher 精确；预测 →
线性 / Logistic 回归。**跑多个检验就做校正**（Bonferroni / FDR），探索性分析要
显式标注。

**报告格式**：`t(df) = X.XX, p = .XXX, d = X.XX`；`F(df1, df2) = X.XX, p = .XXX,
η² = .XX`；`r(df) = .XX, p = .XXX [95% CI: .XX, .XX]`；`β = X.XX, SE = X.XX`。
p 报**精确值**（除非 p<.001），受 1 约束的量不写前导零（`p = .032`）；**永远不要**
由"不显著"推出"没有效应"。

---

## 四、实验失败与不达标怎么处理

先**分类**再处理，别一上来就重跑：

`no_conditions` 一个条件都没跑完 → 不可修复，改设计或缩范围；`few_conditions`
只跑通 1–2 个 → 降级"初步研究"或修好重跑；`no_baseline` / `no_proposed` 缺基线
或缺待测方法 → 必须补，否则不可比；`few_seeds` seed 太少 → 补 seed 重跑或明确
降级；`time_guard` 时间护栏砍掉主要结果 → 缩条件数/步数重跑，别拿残缺结果硬写；
`synthetic_data` 回退到合成/假数据 → **降级为技术报告**，不得宣称实验验证；
`code_crash` / `missing_dep` 崩溃或缺依赖 → 定位根因修，别用 try/except 掩盖；
`bad_hyperparams` NaN/Inf/梯度爆炸 → 回源头修逻辑（除零、未初始化、无收敛检查），
**不要吞异常**；`identical_conditions` 消融结果完全相同 → 消融没生效，修实现后
重跑；`dataset_unavailable` / `permission_error` / `gpu_oom` → 换本地数据、缩规模、
降精度。

顺序：**先诊断（拿到真实报错）→ 定向修复 → 重跑同一条件**；修复说明写根因。

**降级规则**：条件 ≥3 且每条件 seed ≥2 → 完整论文；2 个条件 → "初步研究"（标题
和摘要里明说）；≤1 个条件 → 只能"技术报告"；用了合成数据 → 技术报告且不得声称
实证支持。**未达标项不要悄悄删掉**：以 `status: failed` / `verdict:
inconclusive` 留在 `experiment_summary.json` / `claim_verdicts.json` 里，并在
Limitations 逐条说明。任何"太漂亮"的结果（零方差、指标贴着 1.0 或纯随机、消融毫无
差异）都按可疑处理，回查代码。

---

## 五、常见坑

1. **表里混了不同 seed 的数**（均值对不上、方差离谱）：聚合时没按 `条件/种子/指标`
   三段键分组。→ 第一行输出就固定三段命名，先按条件分组再对 seed 求均值；键名在
   设计阶段定死并写进 `exp_plan.yaml`，全流程不改名（否则汇总表大面积空值）。
2. **缺数字时手写一个"看起来合理"的值**（论文里的数在记录里查不到）：只能来自
   `results.json` / `experiment_summary.json`，没有就写 `null` 并说明。
3. **把随机数当实验数据**（曲线特别平滑、差异恰如预期）：禁止用 `random.uniform()`
   模拟下降曲线、硬编码指标、把常量当收敛率——收敛率要定义成
   `迭代次数 / 最大迭代次数` 这类量。
4. **只保留成功条件 + 不记时间开销**（完成率虚高、整批超时）：失败行以
   `status: failed` 入表，失败次数与耗时进 `run_manifest.json`；主循环前跑一个
   条件试点打印 `TIME_ESTIMATE`，80% 预算处优雅停止并落盘已有结果。
5. **把阈值当结论**（"没到 0.95 所以假设不成立"）：判据看**方向和量级是否与预测
   一致**，部分但有说服力的证据给部分认定。
6. **图到投稿才发现不合格 / 只有均值没有离散度**：出图时就定 300 dpi、色盲友好
   调色板（viridis / Okabe-Ito）、不靠颜色单独区分（叠加形状/线型）、坐标轴带
   单位、多面板标 (A)(B)(C)、最小字号 ≥6pt；误差棒必须在图注写明 SEM / SD /
   95% CI，小样本不用条形图，改点图/箱线图叠个体点。

---

## 六、交付物清单

过程文档：`goal.md`、`problem_tree.md`、`search_plan.yaml` + `sources.json` +
`queries.json`、`candidates.jsonl` / `shortlist.jsonl`、`cards/`、`synthesis.md`、
`hypotheses.md`、`exp_plan.yaml`。

实验产物：`experiment/` + `experiment_spec.md`、`runs/`、`refinement_log.json`、
`experiment_final/`、**`results.json`（根目录）**、`experiment_summary.json`、
`results/` 下的 `metrics.json`、`run_manifest.json`、`claim_verdicts.json`。

分析写作：`analysis.md`、`decision.md`、`outline.md` → `paper_draft.md` →
`paper_final.md` 全链、`charts/`、`references_verified.bib` +
`verification_report.json`、`archive.md` + `bundle_index.json`、`README.md`。

**自查三问**：产出文件在不在？格式能不能解析？里面的数字能不能追到一次真实执行？

---

## 来源与许可

本技能改写自 aiming-lab/AutoResearchClaw（MIT License，Copyright (c) 2026
Aiming Lab）。原仓库为英文、内容分散在数十个技能文件与管线文档中，本条为按其方法
体系重新组织的流程性概述，非原文转载。MIT 许可证允许自由使用、修改与再分发，
使用时保留原版权与许可声明即可。
