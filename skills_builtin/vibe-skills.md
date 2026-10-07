---
name: 科研数据分析全流程方法
summary: 从数据探查、预处理防泄漏、统计检验、建模验证到出版级作图与报告写作的操作流程
tags: 数据分析,预处理防泄漏,统计检验,建模验证,科学可视化,报告写作
repo: foryourhealth111-pixel/Vibe-Skills
license: Apache-2.0
---

# 科研数据分析全流程方法

适用于「拿数据 → 清洗 → 统计/建模 → 出图 → 写报告」整条链路。纯查文献、纯跑某个软件、
只改一段代码逻辑不适用。

> **取舍**：来源技能集共 250+ 条目，本文只整合统计/预处理/建模/可视化/写作五组。
> 通用生产力与软件工程类未纳入；少数可迁移技巧收在第八节并标注适用场景。
> 依赖外网的在线数据库条目在末节列名备查（隔离工作区通常无外网）。

---

## 一、开工前

### 1.1 先探资源再定路线

重计算前先报告 CPU 核数、内存、磁盘余量、有无 GPU：

- 并行 worker：≥8 核用 `核数−2`；4–7 核用 `核数−1`；<4 核串行（并行开销反超收益）
- 内存 <4 GB 必走 zarr/h5py/dask 外存；4–16 GB 且数据 >2 GB 用分块；>16 GB 可直接载入

把「数据多大、内存多少、走哪条路线」说出来，不要试到 OOM 才回头。

### 1.2 EDA：产出可归档报告

固定五步：认扩展名 → 定格式族 → 选读取库 → 跑分析 → 写报告。

| 格式族 | 扩展名 | 读取库 |
|---|---|---|
| 表格 | csv tsv xlsx parquet json | pandas / polars |
| 数组/分块 | npy npz hdf5 zarr mat nc | numpy / h5py / zarr |
| 序列/基因组 | fasta fastq sam bam vcf bed gtf | Biopython / pysam |
| 单细胞 | h5ad loom mtx | scanpy / anndata |
| 化学/结构 | pdb cif sdf mol2 xyz | RDKit / MDAnalysis |
| 质谱/波谱 | mzML mzXML mgf | pyopenms / matchms |
| 影像 | tif nd2 czi dcm nii svs | tifffile / pydicom / histolab |

**报告命名 `{原文件名}_eda_report.md`**，与数据同级。六节必含：① 文件名/大小/时间戳
② 基本属性与格式识别 ③ 格式说明（典型内容、用途、读取库）④ 数据分析（结构维度、统计摘要、
质量评估）⑤ 关键发现（异常模式、可疑点）⑥ 建议（预处理、适配方法、可视化）。

必查项：**表格**—维度、dtype、缺失分布、重复行、描述统计、异常值、相关矩阵；
**序列**—条数、长度分布、GC 含量、质量分；**影像**—维度 XYZCT、位深、值域、通道波长、
像素物理尺寸；**数组**—shape、dtype、统计摘要、无效值。

大文件不全量读：先采样前 N 条，HDF5/NPY 用内存映射，CSV/FASTQ 分块。
**校验元数据自洽性**（声明的维度 vs 实际），不一致写进报告。

### 1.3 目录骨架

```
project/{README.md, src/, data/{raw,processed}/, docs/, outputs/, requirements.txt}
data/DATA_DICTIONARY.md   # 每字段：名称、类型、含义、范围、来源
docs/PROCESS.md           # 流程与决策理由     docs/CHANGELOG.md  # 改动记录
```

**原始数据只读、永不原地改写**；派生落 `processed/`；魔法数字提成命名常量或注明由来。
改已有项目先读懂原结构、沿用原命名，改完更新 CHANGELOG。

---

## 二、预处理：先认清结构，再决定怎么变换

最易出事的一段。核心判据只有一条：**每步变换的作用域（组内/全局）必须与数据分组结构一致。**

### 2.1 四层特征分析

1. **数据类型** `df.dtypes`
2. **特征类型** 二值（`nunique()==2`）保持 0/1；类别 → one-hot 或有序编码；
   连续（`nunique()>10`）→ 标准化
3. **数据结构** 有无分组列（`patient_id`/`session_id`/`batch`）？是否时序？按 `[组,时间]` 排序
4. **物理意义** 写死区间断言，如 `assert df['ph'].between(0,14).all()`

### 2.2 组内还是全局：用 ICC 判

先问目标：**组内相对**（"对这个受试者偏高"）→ 组内；**跨组绝对**（"整体偏高"）→ 全局。拿不准算：

```python
within = df.groupby(g)[col].var().mean()
icc = (df[col].var() - within) / df[col].var()   # icc > 0.5 → 用组内
```

### 2.3 按类型分别处理

**插值必须在组内做**——跨组插值等于把 A 组末点与 B 组首点连起来，最典型的静默错误：

```python
for gid in df['subject_id'].unique():
    m = df['subject_id'] == gid; s = df.loc[m, col]
    pos = np.where(s.notna())[0]
    if len(pos) >= 4:                            # 三次样条至少 4 个有效点
        cs = CubicSpline(pos, s.dropna().values)
        df.loc[m & s.isna(), col] = cs(np.where(s.isna())[0])
```

**标准化同理**：相对分析用组内（`z=+2` 读作"对本组而言高 2 个标准差"），绝对比较用全局。
做完自检——组内标准化的结果每组均值应 ≈0、标准差应 ≈1：

```python
r = df.groupby(g)[f'{col}_std'].agg(['mean','std'])
ok = (r['mean'].abs() < 0.1).all() and r['std'].between(0.9, 1.1).all()
```

**二值变量绝不标准化**（会毁掉 0/1 语义）。**累计量慎用**：`cumsum()` 单调递增、与时间步强相关，
做"近期趋势"要用 `rolling(10, min_periods=1).mean()`。

缩放器按分布选（先算 `skew` 与 `kurtosis`）：`|skew|<0.5` 且 `|kurt|<3` → StandardScaler；
`skew>1`（右偏长尾）→ `log1p` 后 StandardScaler；其它/重离群 → RobustScaler。
另两条告警：`std > mean`（高度偏斜或单位错）；某组缺失率 > 该组样本数 50%。

### 2.4 数据泄漏：十种模式 + 一条黄金判据

**黄金判据**：*预测发生的那一刻，这个值能从库里查到、或只用当时之前的信息算出来吗？* 答"不能"就是泄漏。

| # | 模式 | 正确做法 |
|---|---|---|
| 1 | 先 `fit_transform` 全量再切分 | 先切分；`fit` 训练集，`transform` 测试集 |
| 2 | 全量均值/中位数/众数填缺失 | 统计量只从训练集算，测试集套用 |
| 3 | 全量做 PCA / 降维 | PCA 只在训练集 `fit` |
| 4 | 全量做 target encoding | 分组均值只从训练集 target 算；未见类别回落训练集 target 均值 |
| 5 | 全量做特征选择 | `SelectKBest` / 相关性筛选只在训练集 fit |
| 6 | 时序数据随机切分 | 按时间切：`train = df[df.date < split]` |
| 7 | 未来函数（拿当天全量均值当特征） | 改 expanding / rolling，只用过去 |
| 8 | 事后特征（"催收电话次数"预测违约） | 只用事件发生前就存在的特征 |
| 9 | CV 之前先预处理 | 用 `Pipeline` 包住缩放器，每折自己 fit |
| 10 | 先增广再切分 | 只增广训练集 |

量级参考（判断值不值得回头查）：缩放类泄漏让测试分虚高 2–10%；
**target encoding 泄漏可虚高 20–50% 以上**，优先排查。

离群值：阈值只用训练集算；训练集**删除**，测试集**截断**（生产不能删样本）——
`X_test[col] = X_test[col].clip(lo, hi)`。

预处理做完跑一遍审计，逐条打印：**ID 泄漏**（唯一值占比 >50%）、
**因果倒置**（与 target `|corr|>0.95`）、**数值型编码误用**（`min>1000` 且 `nunique>100`，
如邮编/编号，应作类别）、**全量统计量**（结合切分顺序人工确认）。

### 2.5 验收清单

- [ ] 每个变换的作用域已声明并自检通过；所有 `fit` 都在切分后且只在训练集
- [ ] 二值列未被缩放，类别列已编码，连续列有原始+变换两版
- [ ] 物理区间断言通过；`std>mean` 与组内高缺失告警已处理或说明
- [ ] 没有累计型特征冒充趋势特征
- [ ] **剩余样本量、剩余特征/基因数报出来**

---

## 三、统计推断

### 3.1 选检验

| 情形 | 参数检验 | 非参数替代 |
|---|---|---|
| 两组独立，连续正态 | 独立 t | Mann-Whitney U |
| 两组配对，连续正态 | 配对 t | Wilcoxon 符号秩 |
| 3 组以上独立 | 单因素 ANOVA | Kruskal-Wallis H |
| 3 组以上配对 | 重复测量 ANOVA | Friedman |
| 二分类结局 | 卡方（期望频数<5 用 Fisher 精确） | — |
| 配对二分类 | McNemar | — |
| 两连续变量 | Pearson | Spearman |
| 二分类结局+预测变量 | Logistic 回归 | — |
| 计数结局 | Poisson；过离散用负二项 | — |
| 生存/删失 | Cox / log-rank | — |

n<30 优先非参数或精确方法。**样本量很大时任何微小效应都会"显著"，报告重点必须转向效应量。**

### 3.2 检验前必查假设

| 假设 | 严重度 | 检查 | 违反后补救 |
|---|---|---|---|
| 独立性 | **高**（不查会严重抬高 I 类错误） | 设计审查；时序看 ACF/PACF、Durbin-Watson；嵌套数据算 ICC | 混合效应 / GEE / 时序方法 |
| 正态性 | 中 | n<50 用 Shapiro-Wilk；30≤n<100 以 Q-Q 图为主检验为辅；**n≥100 检验过敏感，只看图** | 轻度且 n>30 可继续；中度改非参数；重度 log/sqrt/Box-Cox 或稳健回归 |
| 方差齐性 | 中 | Levene（对非正态稳健，**不用 Bartlett**）；回归看残差-拟合图 | t→Welch；ANOVA→Welch/Brown-Forsythe；回归→稳健标准误 HC3 / WLS / GLM |

方差比 max/min <2–3 一般可接受，且**组样本量相等时检验本身较稳健**。
回归另查 VIF 与残差图：漏斗形=异方差，弯曲=缺非线性项；`sm.add_constant(X)` 加截距后再算 VIF。

### 3.3 效应量：报了才算完整

**黄金法则：永远和 p 值一起报效应量，并给置信区间。**

| 分析 | 效应量 | 小 | 中 | 大 |
|---|---|---|---|---|
| t 检验 | Cohen's d | 0.20 | 0.50 | 0.80 |
| ANOVA | η² | 0.01 | 0.06 | 0.14 |
| ANOVA | Cohen's f | 0.10 | 0.25 | 0.40 |
| 相关 | r / ρ | 0.10 | 0.30 | 0.50 |
| 回归 | R² | 0.02 | 0.13 | 0.26 |
| 回归 | f² | 0.02 | 0.15 | 0.35 |
| 卡方 | Cramér's V | 0.07 | 0.21 | 0.35 |
| 卡方 2×2 | φ | 0.10 | 0.30 | 0.50 |

多因子 ANOVA 用偏 η² 并追加 ω²（η² 高估，ω² 更无偏）。每组 n<20 用 Hedges' g 代替 d。
**基准只是参考**：物理学科 R²>0.90 才算正常，社会科学 >0.30 已算好；R²=0.30 只解释 9% 方差。

### 3.4 多重比较与缺失数据

多检验必须校正：Bonferroni（最保守）< Holm-Bonferroni < FDR/BH（探索性首选）；
ANOVA 事后用 Tukey HSD。**主要结局与次要/探索性结局分开声明**，别让探索性发现冒充实证结论。

缺失数据先判断机制 MCAR / MAR / MNAR，再选处理：完整案例删除、多重插补、最大似然。
**先说明缺失比例与机制，再选方法。**

### 3.5 功效分析

α=0.05、power=0.80；样本量/效应量/α/power 知三求一。

```python
from statsmodels.stats.power import tt_ind_solve_power
n = tt_ind_solve_power(effect_size=0.5, alpha=0.05, power=0.80, ratio=1.0)
d_min = tt_ind_solve_power(effect_size=None, nobs1=50, alpha=0.05, power=0.80)
```

**事后功效（post hoc power）不要报**——它由 p 值直接决定，p>0.05 时必然很低，无额外信息。
研究完成后要说明检测能力，用**敏感性分析**或效应量置信区间代替。

### 3.6 结果怎么写（APA）

> 组 A（M=75.2, SD=8.5）显著高于组 B（M=68.3, SD=9.2），t(98)=3.82, p<.001, d=0.77, 95% CI [0.36, 1.18]。
> 处理条件对得分有显著主效应，F(2,87)=8.45, p<.001, η²p=.16；Tukey HSD 事后比较显示……
> 学习时长与成绩呈中度正相关，r(148)=.42, p<.001, 95% CI [.27, .55]。
> 回归模型显著预测成绩，F(3,146)=45.2, p<.001, R²=.48；学习时长（β=.52, p<.001）
> 与既往 GPA（β=.31, p<.001）为显著预测因子。

### 3.7 评审他人结论的检查表

- **设计**：能否支撑因果表述？对照是否合适？随机化与盲法如何实施？
- **偏倚**：确认偏倚、HARKing（先看结果再编假设）、发表偏倚、幸存者偏倚、回忆偏倚、社会赞许；流失是否组间差异
- **统计**：做过先验功效吗？多重比较校正了吗？p 值解释对吗（**不显著≠无效应**）？有没有 .05 附近的异常堆积？
- **常见谬误**：相关当因果、忽略均值回归、基础率忽视、德州神枪手、Simpson 悖论（合并子组后方向反转）
- **证据分级**：系统综述/RCT/队列/病例对照/横断面/病例报告。高等级设计≠高质量，糟糕的 RCT
  可能弱于设计良好的观察性研究。GRADE 降级：偏倚风险、不一致性、间接性、不精确、发表偏倚；
  升级：大效应、剂量-反应、混杂方向反而削弱效应

---

## 四、建模

### 4.1 先立基线

写复杂模型前先回答"不用 ML 会怎样"，建**三级基线**：① 统计基线
（分类 `DummyClassifier(strategy='stratified')` 预测多数类；回归预测均值）
② 领域启发式（时序"明天=今天"）③ 价值抬升 `Lift = (模型−基线)/基线`。

判据：**抬升 <5% 就用简单模型**（可解释性胜出）；<10% 要质疑工程成本。

### 4.2 切分

```python
X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, stratify=y, random_state=42)
```

分类必带 `stratify=y`；**有分组列用 GroupKFold**（同一受试者样本不能跨折）；
**时序用 TimeSeriesSplit 或按日期切**，切完断言
`assert X_train['date'].max() < X_test['date'].min()`。

类别不平衡时别盯 accuracy：看 precision/recall/F1/AUC；有成本矩阵时用业务损失函数
（假阴性与假阳性分别计价）。

### 4.3 数据考古

缺失模式先统计，再判断**缺失本身是否有信息量**：
`pd.crosstab(df['x_missing'], df['target'])` 卡方 p<0.05 → 缺失指示变量作为特征保留。
与 target `|corr|>0.95` 的特征立即报警（疑泄漏）。

### 4.4 五阶段建模

1. **画像**：画分布、看类别比例、描述统计、建 dummy 基线
2. **健全性检查**：模型能否过拟合 10 个样本？
   ```python
   model.fit(X_tr[:10], y_tr[:10])
   assert model.score(X_tr[:10], y_tr[:10]) == 1.0, "代码有 bug，不是模型问题"
   ```
   **过拟合不了 10 个样本就是 bug**（标签编码错、预处理错、实现错），先修再调参
3. **扩容量**：加大模型直到训练分 >0.95
4. **加正则**：把训练-验证差距压到 <0.05。有效性排序：数据增广 > Dropout > L2/树约束 > 早停
5. **诊断**：损失震荡→降学习率+warmup+cosine；卡在高损失→查 dead ReLU/梯度消失/损失选错；
   验证损失上升→过拟合回第 4 步；两者都高→欠拟合回第 3 步

**优先稳健而非峰值**：0.85±0.01 优于 0.88±0.05（用 `cross_val_score` 看标准差）。
**调参一次只动一个**，画参数-验证分曲线找拐点。参数直觉：`n_estimators` 超约 100 收益递减；
`max_depth` 过低欠拟合过高过拟合；`min_samples_split`/`min_samples_leaf` 越大正则越强。

| 深度学习 | 树模型 | 线性模型 | 作用 |
|---|---|---|---|
| 加层 | 增大 max_depth | 多项式特征 | 提升容量 |
| Dropout | colsample_bytree | — | 防止依赖单一特征 |
| L2 | lambda/gamma | Ridge | 惩罚大权重 |
| 数据增广 | subsample | SMOTE | 增加多样性 |
| BatchNorm | — | 特征缩放 | 稳定训练 |

### 4.5 消融与解释

**不要用"加上它变好了"证明模块有用**（可能只是参数量变大或初始化运气）；移除该组件重训、
性能确实下降才算数。特征重要性用置换重要性（比内置 `feature_importances_` 可靠），
`n_repeats=10`，重要性 <0.01 可剔除；剔除后必须重训重评。

### 4.6 评价指标

分类：accuracy / precision / recall / F1 / ROC AUC / 混淆矩阵；回归：MSE / RMSE / MAE / R² / MAPE；
聚类：silhouette / Calinski-Harabasz / Davies-Bouldin；生存：C-index、时间依赖 AUC、校准曲线。
比较候选模型时**用同一套指标、同一份切分**，报阈值选择与校准，并说明验证策略的弱点。

---

## 五、实验设计与因果推断

```
有对照组吗？
├─ 没有 → 中断时间序列 ITS（假设：趋势连续）
└─ 有 → 处理单元几个？
        ├─ 单个 → 有多个对照 → 合成控制 SC（假设：凸包，处理单元落在对照范围内）
        │         无对照     → ITS
        └─ 多个 → 双重差分 DiD（假设：平行趋势）
```

DiD/SC 需面板数据（多单元×多时点），ITS 需单单元时间序列。执行：`summary()` 看模型摘要与主结果、
`print_coefficients()` 看系数、`plot()` 看观测值 vs 反事实；稳健性检验（换对照、换时间窗、
安慰剂检验）单独跑并报告。

**实验失败后的处置**：用同一套设计语言做三件事——区分实现/测量错误与设计假设失败 →
指出下一个该被检验的假设 → 定义最小验证实验与继续/修改/放弃的决策规则。不要直接换方法重来。

---

## 六、出版级出图

### 6.1 分辨率与格式

矢量（折线/散点/示意图）用 PDF / EPS / SVG，**首选**；线条图栅格 600–1200 DPI；
照片/显微图 300–600 DPI 的 TIFF / PNG；组合图 300–600 DPI。**绝不用 JPEG**
（有损压缩在文字和线条周围产生伪影）。

```python
fig.savefig('figure1.pdf')                            # 矢量
fig.savefig('figure1.png', dpi=300, bbox_inches='tight')
```

### 6.2 尺寸与字号

单栏 85–90 mm，1.5 栏 114–120 mm，双栏 174–180 mm，最大高 230–240 mm。
刊物：Nature 89/183 mm，Science 55/175 mm，Cell 85/178 mm。
**先按目标刊物栏宽建 figure，不要事后缩放。**

字号（**最终印刷尺寸下**）：轴标签 7–9 pt，刻度 6–8 pt，图例 6–8 pt，面板标号 8–12 pt 粗体；
**任何文字不得小于 5–6 pt**。统一无衬线字体（Arial/Helvetica），全文所有图一致。
标签句首大写+括号带单位：`Time (hours)` 而非 `TIME (HOURS)`。

### 6.3 配色

```python
okabe_ito = ['#E69F00', '#56B4E9', '#009E73', '#F0E442',
             '#0072B2', '#D55E00', '#CC79A7', '#000000']   # 分类首选，色盲友好
plt.rcParams['axes.prop_cycle'] = plt.cycler(color=okabe_ito)
```

备选：Paul Tol bright `['#4477AA','#EE6677','#228833','#CCBB44','#66CCEE','#AA3377','#BBBBBB']`、
Tol muted、Tol high-contrast（仅 3 类）。连续型用感知均匀色图 `viridis`/`cividis`/`plasma`；
发散型用 `RdBu_r`/`PuOr`/`BrBG` 并设 `center=0`。**禁用 `jet` 和 `rainbow`**，避免红绿组合
（约 8% 男性有色觉障碍）。同一处理在不同图中必须同色。
**每张图做灰度测试**——靠线型（实/虚/点）与标记形状（圆/方/三角）区分，不能只靠颜色。

### 6.4 多面板与细节

```python
gs = fig.add_gridspec(2, 2, hspace=0.4, wspace=0.4)
ax.text(-0.15, 1.05, 'A', transform=ax.transAxes, fontsize=10, fontweight='bold', va='top')
```

面板标号：Nature 用小写粗体 `a,b,c` 放左上角；Science/Cell 用 `(A),(B),(C)`。
相关面板尺寸一致、沿边对齐，按从左到右、从上到下排。

数据线 1–2 pt，参考线 0.5–1 pt，坐标轴 0.5–1 pt，误差棒 0.5–1 pt，标记 3–6 pt（大于线宽）。
取消上/右边框（`sns.despine()`），图例默认无框（`frameon=False`），主刻度 4–7 个。

### 6.5 数据表现规范

- **误差棒必须画，并在图注说明是 SD、SEM 还是 CI**，同时给出 n
- **能画个体数据点就画**（散点叠箱线/小提琴），别只给汇总柱
- **柱状图 y 轴从 0 开始**；不用 3D；不加渐变、阴影、装饰
- 同类面板共用坐标范围；截断轴必须显式标注并说明理由
- 显著性标注 `*,**,***`，符号含义写进图注
- 缺一不可：轴标签+单位、n、误差棒定义、统计符号定义

**图注自明模板**：> 图 1. 干预组与对照组 12 周内平均收缩压（SBP）变化。误差棒为均值标准误（SEM）。
星号表示各时间点组间显著差异（\*p<0.05, \*\*p<0.01, \*\*\*p<0.001，双尾 t 检验）。每组 n=48。

### 6.6 常见出图错误

字号过小 / 分辨率不足 / 图表垃圾（多余网格、3D、装饰）/ 配色不当（红绿、低对比）/
缺元素（无轴标签、无单位、无误差棒）/ 同图内或跨图风格不一致 / 数据失真（截断轴、不当尺度、3D）/
JPEG 伪影 / 一张图塞太多序列 / 导出后图例跑到画布外。

---

## 七、写作与交付

### 7.1 IMRAD 与时态

Title（10–15 词）→ Abstract → Introduction → Methods → Results → Discussion → Conclusion →
References → Supplementary。

- **Introduction**（4–5 段）：大背景 → 逐层收窄 → **明确的知识缺口** → 本研究问题/假设
- **Methods**：可复现到别人能重跑（样本、流程、统计方法及理由、设备、伦理）
- **Results**：只陈述不解释，从主要结局到次要结局
- **Discussion**：回扣问题 → 与既有文献比较 → **诚实写局限** → 机制解释 → 意义与未来方向

**时态**：既定事实现在时；前人研究过去时；自己的方法与结果过去时；结论现在时。
**摘要**：100–250 词，结构化（Background 1–2 句 / Methods 2–4 句 / Results 3–5 句 /
Conclusions 1–2 句）；**最后写摘要**；不引文献；必须含关键定量结果。

### 7.2 两阶段写作（铁律：最终稿必须是完整段落，绝不能是项目符号）

**阶段一** 写要点大纲（讲什么论点、引哪篇、放哪个数据、逻辑顺序）——只是脚手架。
**阶段二** 把每个要点扩写成完整句，补过渡词（however / moreover / in contrast / subsequently），
**把引用融进句子**而不是堆在句尾，调整句式长短。

### 7.3 图表 vs 正文

**能用一两句话讲清的就不做图表。** 需要精确数值 → 表格；需要看趋势/关系/分布 → 图。
每个图表必须**自明**（不读正文也能懂）；**正文不重复图表里的所有数字**，只点关键发现并指向图表；
**每 1000 词配 1 个图表**（3000–4000 词 → 3–4 个）；所有图表的字体、配色、术语、标注保持一致。

### 7.4 常见啰嗦（直接替换）

`due to the fact that`→`because`；`in order to`→`to`；`it is important to note that`→删；
`a total of 50 participants`→`50 participants`；`has been shown to be`→`is`；`in the event that`→`if`；
`make a decision`/`perform an analysis`→`decide`/`analyze`。删开场白，去掉无意义强调词
（`very significant`→`significant`），消除歧义代词，检查悬垂修饰语。

### 7.5 报告交付

```
reports/<topic>/{report.md, report.html, report.pdf, figures/, appendix/}
```

**强制阶段顺序**：① **结构先行**——先搭骨架：Executive Summary（结论先行）、Context（问题与约束）、
Methods（数据/流程/参数，可复现）、Results（以图为骨架）、Discussion（意义/局限/建议）、
Appendix（环境/补充图表），**即使简写也必须六节齐全** ② **结果以图为锚**——先出图再围绕图写解释
③ **导出**——HTML 优先 Markdown+静态图；需交互才用 Plotly 出 HTML 并附静态回退；
出 PDF 重点是确认图在最终版面上字体与线宽仍可读；**禁止拿网页截图当 PDF**。

**质量门禁**：结论先行（只读 Executive Summary 就知道要点与建议）/ 可复现 /
图可用（字体统一、色盲友好、格式与 DPI 正确）/ **可追溯：每个结论都能指向某张图、某张表或某段计算**。

### 7.6 汇报幻灯片

**约 1 张/分钟。**

| 时长 | 总页数 | 引言 | 方法 | 结果 | 讨论 | 结论 |
|---|---|---|---|---|---|---|
| 5 min | 5–7 | 1–2 | 0–1 | 2–3 | 1 | 1 |
| 10 min | 10–12 | 2 | 1–2 | 4–5 | 2–3 | 1 |
| 15 min | 15–18 | 2–3 | 2–3 | 6–8 | 3–4 | 1–2 |
| 20 min | 20–24 | 3 | 3–4 | 8–10 | 4–5 | 2 |
| 30 min | 25–30 | 3–4 | 5–6 | 10–12 | 6–8 | 2 |

叙事弧：Hook（30 秒）→ Context（5–10%）→ 问题/缺口（5–10%）→ 方法（15–25%）→
**结果（40–50%）** → 意义（15–20%）→ 收尾（1–2 分钟）。
数据密集页按 2–3 分钟算，标题/分隔页 15–30 秒。**准备 1–2 张备用页**，事先决定超时跳哪几页；
含 Q&A 时内容页减 20–30%。

---

## 八、通用可迁移技巧（附适用场景）

来源技能集里的通用条目，不是分析方法本身，但在长链条分析任务里确实有用。

### 8.1 磁盘当工作记忆（适用：≥3 步、跨多轮工具调用的任务）

项目根目录建三个文件：`task_plan.md`（阶段、进度、决策）、`findings.md`（任何发现，
**每次发现立即写**）、`progress.md`（会话日志、试过什么、报错）。核心是
「**每 2 次查看/搜索操作就把关键结论落到文件**」——多模态信息（图、网页、PDF）不落盘会丢失。
做重大决策前先读 plan 把目标拉回注意力窗口；每阶段结束更新状态、记错误、记改了哪些文件。

**错误处置（三次尝试协议）**：第 1 次诊断并定点修复；第 2 次换方法/换库，
**绝不重复完全相同的失败动作**；第 3 次回头质疑假设、更新计划；**3 次仍失败就升级给人**，
说明试过什么、具体报错是什么。所有错误记表（错误 / 第几次 / 解决方式），避免重蹈覆辙。

### 8.2 完成前验证（适用：任何要声称"做完了"的时刻）

**铁律：没有当场跑出来的验证证据，不许声称完成。**

```
1 确定：什么命令能证明这个断言？  2 运行：完整跑一遍（新鲜、完整）
3 读取：看完整输出、退出码、失败计数  4 核对：输出支持这个断言吗？  5 然后才下断言
```

| 断言 | 需要什么证据 | 什么不算 |
|---|---|---|
| 测试通过 | 测试命令输出 0 失败 | 上次的结果、"应该能过" |
| 构建成功 | 构建命令退出码 0 | linter 通过 |
| bug 已修 | 原始症状的测试通过 | 改了代码 |
| 回归测试有效 | 红-绿循环验证过 | 测试跑过一次通过 |
| 需求已满足 | 逐条对照清单 | 测试通过 |

**危险信号**：出现"应该""大概""看起来"；验证前表达满意（"好了！""完成！"）；
拿局部检查当全部证据。**验证前先说结论就是撒谎，不是高效。**

### 8.3 多源信息任务的透明度（适用：需综合多份材料/文献时）

- **工具失败必须显式处理**：报错后下一段先说明失败类型、给补救策略（重试/换来源/记为已知
  缺口），不许静默继续
- **只引真正取到的来源**，没成功获取的内容不得出现在结果里；维护"已获取来源"清单
- 关键结论至少跨 2 个来源交叉验证，注明一致点与矛盾点
- 收尾前检查：每节都有具体证据、来源都已取到、关键论点已交叉验证、缺口已记录
- 结尾专设 **Limitations & Gaps** 一节；**不要说"已经全面覆盖"**，要说"覆盖了 X 个来源的
  Y 主题，缺 Z 方面"

---

## 九、常见坑

| 现象 | 原因 | 避免方式 |
|---|---|---|
| 测试分数好得不像话 | target encoding / 缩放 / 特征选择在全量上做过 | 切分在前，所有 `fit` 只在训练集；Pipeline 让 CV 每折自己 fit |
| 换个人跑结果不同 | 未固定随机种子；未声明切分方式 | 随机过程写死 `random_state=42`，切分策略写进报告 |
| 组间比较结果诡异 | 全局标准化/插值造成跨组污染 | 先算 ICC，声明作用域，跑组内标准化自检 |
| 连 10 个样本都过拟合不了 | 标签编码错、预处理错、实现 bug | 先跑 10 样本过拟合断言，修 bug 再谈调参 |
| 加了模块变好，删掉也没变差 | 增益来自容量或初始化运气 | 用消融（移除后变差）证明必要性 |
| 复杂模型只比逻辑回归好 1% | 没建基线，误把 1% 当收益 | 先建 dummy+启发式+简单模型三级基线 |
| 时序模型表现异常好 | 随机切分 + 未来函数 | 按时间切分并断言日期边界；rolling/expanding 代替全量聚合 |
| 显著性一大堆但结论站不住 | 多重比较未校正；探索性当验证性报 | 预声明主要/次要结局，FDR 校正，探索性结论明确标注 |
| p>0.05 就说"无效应" | 把不显著当无效应；样本量不足 | 报效应量+置信区间；敏感性分析说明可检测的最小效应 |
| 图被审稿人打回 | 字号过小 / JPEG / 红绿配色 / 缺误差棒 | 按出图检查清单逐条过；先按栏宽建 figure |
| 最终稿全是项目符号 | 把大纲当正文交了 | 两阶段写作，最终稿禁止 bullet |
| 报告读完不知道结论 | 没有结论先行的摘要 | 第一节必须是 Executive Summary，每节能指向具体图表 |

---

## 十、交付物清单

| 类别 | 文件 | 说明 |
|---|---|---|
| 探查 | `{数据名}_eda_report.md` | 六节齐全，含格式说明与建议 |
| 数据 | `data/raw/`（只读）、`data/processed/` | 原始数据永不原地修改 |
| 文档 | `DATA_DICTIONARY.md`、`PROCESS.md`、`CHANGELOG.md` | 字段字典；流程与决策理由；改动记录 |
| 统计 | 结果表（检验量、df、p、效应量、95% CI） | 按 APA 格式 |
| 图 | `figure1.pdf` 等 | 矢量优先；栅格按刊物 DPI；命名 `FirstAuthor_FigN.ext` |
| 图注 | 随图交付 | 自明：n、误差棒定义、显著性符号定义 |
| 建模 | 模型比较表（统一指标、统一切分）、特征重要性表 | 含基线与稳健性（均值±标准差） |
| 报告 | `reports/<topic>/report.md`（+ html/pdf） | 六节结构，结论先行 |
| 汇报 | 幻灯片 + 备用页 | 1 张/分钟，结果占 40–50% |
| 归档 | `figures/`、`appendix/`、`task_plan.md`/`findings.md`/`progress.md` | 长任务的过程记录 |

---

## 附：来源条目索引

**整合进本文的条目**（约 30 个）：`exploratory-data-analysis`、`scientific-data-preprocessing`、
`data-quality-frameworks`、`statistical-analysis`、`scientific-critical-thinking`、
`designing-experiments`、`performing-causal-analysis`、`detecting-data-anomalies`、
`preprocessing-data-with-automated-pipelines`、`ml-data-leakage-guard`、`scikit-learn`、
`ml-pipeline-workflow`、`LQF_Machine_Learning_Expert_Guide`、`splitting-datasets`、
`evaluating-machine-learning-models`、`explaining-machine-learning-models`、
`scientific-visualization`、`creating-data-visualizations`、`visualization-best-practices`、
`data-storytelling`、`scientific-writing`、`scientific-reporting`、`structured-content-storage`、
`planning-with-files`、`verification-before-completion`、`comprehensive-research-agent`、
`skill-creator`、`scanpy`、`pydeseq2`、`biopython`、`scikit-bio`。

**未整合、但同类值得按需查阅的条目**（按组列名）：
统计与数学工具——`statsmodels`、`pymc`、`umap-learn`、`shap`、`aeon`、`scikit-survival`、
`metric-calculator`、`senior-data-scientist`、`statistics-math`、`math-tools`、`sympy`、
`pymoo`、`networkx`、`simpy`、`timesfm-forecasting`；
ML 基础设施——`pytorch-lightning`、`transformers`、`stable-baselines3`、`tensorboard`、
`weights-and-biases`、`torch-geometric`、`torchdrug`、`unsloth`、`evaluating-llms-harness`、
`evaluating-code-models`、`senior-ml-engineer`；
出图备选库——`matplotlib`、`seaborn`、`plotly`、`datavis`、`data-artist`、`theme-factory`、
`markdown-mermaid-writing`；
写作与投稿——`scientific-slides`、`report-generator`、`manuscript-as-code`、
`submission-checklist`、`peer-review`、`venue-templates`、`latex-posters`、
`latex-submission-pipeline`、`pptx-posters`、`scholarly-publishing`、`citation-management`、
`research-grants`、`scholar-evaluation`；
过程与元技能——`brainstorming`、`scientific-brainstorming`、`create-plan`、`writing-plans`、
`jupyter-notebook`、`get-available-resources`、`knowledge-steward`、`digital-brain`、
`file-organizer`、`systematic-debugging`、`context-hunter`；
生信与组学扩展——`pydicom`、`pyopenms`、`matchms`、`rdkit`、`medchem`、`neurokit2`、
`neuropixels-analysis`、`histolab`、`pathml`、`omero-integration`、`lamindb`、`tiledbvcf`、
`gtars`、`etetoolkit`、`pyhealth`、`clinical-reports`、`clinical-decision-support`、`treatment-plans`；
科学计算与数据设施——`dask`、`polars`、`vaex`、`zarr-python`、`geopandas`、`astropy`、
`pymatgen`、`fluidsim`、`matlab`、`markitdown`、`spreadsheet`、`xlsx`、`docx`、`pptx`、`pdf`。

**⚠ 依赖外网或外部服务，隔离工作区通常不可用**（列名备查，不要默认可调）：
`bio-database-evidence`、`geo-database`、`ena-database`、`uniprot-database`、`pubmed-database`、
`chembl-database`、`clinpgx-database`、`metabolomics-workbench-database`、
`imaging-data-commons`、`openalex-database`、`pyzotero`。

**未列入的约 100 个条目**属于通用软件工程（`code-reviewer`、`tdd-guide`、`speckit-*`、
`security-*`、CI/部署类）、媒体与语音、通用生产力与商业数据（`fred-economic-data`、
`edgartools`、`market-research-reports`、`content-research-writer`）、以及技能集自身的运行时
编排（`vibe`、`ralph-loop`、`hive-mind-advanced`、`mcp-integration` 等），与科研数据分析无关。

---

## 来源与许可

本技能改写自 `foryourhealth111-pixel/Vibe-Skills`（Apache-2.0）。
原仓库打包了 250 余个来自不同上游的 SKILL.md，并在 `THIRD_PARTY_LICENSES.md` 与
`config/upstream-lock.json` 中逐条登记了各自的上游许可证（含 MIT、CC0-1.0、Unlicense、
GPL-3.0、NOASSERTION 等），明确声明其 Apache-2.0 许可**不覆盖**上游内容。
本文是按主题重新组织的**方法概述与操作流程**，非原文转载，也未复制任何上游代码或脚本；
保留本说明以符合原仓库的通知保留要求。使用具体方法前，请按目标期刊作者指南与所在机构规范复核相关阈值。
