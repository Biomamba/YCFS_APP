---
name: 科研全学科分析流程库
summary: 生信组学、化学药物、统计建模、可视化成图与文献写作的可执行流程、参数与判据
tags: 生信组学,统计分析,可视化成图,文献写作,化学信息学,科研方法
repo: K-Dense-AI/scientific-agent-skills
license: MIT
---

# 科研全学科分析流程库

## 什么时候用这条技能

用户让你做**真实的科研数据分析**——一批测序数据、化合物表、临床或实验数据、文献列表，
要你写代码跑出结论、出图、写报告——时按这条走。它给的不是"有哪些工具"，而是
**每步调什么函数、参数取多少、做完查什么、结果落哪**。四条贯穿全场的原则：

1. **可复现优先**：固定种子、钉住工具与参考版本（组装、注释、包），命令行写进产物目录。
2. **质量卡点在分析之前**：QC、假设检查、坐标与单位校验是流程步骤，不是可选装饰。
3. **判据先行**：显著性阈值、接受标准、暴露指标、检验方法必须在看数据之前定下来并写出来；
   看完数据再挑检验或阈值就是 p-hacking，哪怕是无意的。
4. **说清边界**：样本量不够就说不够，外推不了就不外推，不从关联推因果。

工作区隔离无网络时改用**本地文件 + 本地实现**（本地 GMT 做离线富集、本地注释代替在线
查询），并把"这一步降级了"写进结果。

---

## 一、生信与组学

### 1.1 bulk RNA-seq 端到端

链路固定：**FastQC/trim → 比对定量（STAR/Salmon）→ 计数矩阵 → 差异表达 → 通路富集 →
出图**。上游二选一，别混：

- 路径 A（推荐）`nf-core/rnaseq`：内部已做 tximport，直接取
  `*-salmon.merged.gene_counts_length_scaled.tsv` 进差异表达。
- 路径 B：`fastqc` → `fastp` → `salmon quant -l A --gcBias --seqBias`
  （或 STAR `--quantMode GeneCounts`）→ featureCounts。

先校验样本表：每组 ≥3 个生物学重复、批次与处理不混杂。**计数矩阵桥接**（唯一没有现成
下游工具的一步）：Salmon 输出用 `pytximport` 聚合到基因层
（`counts_from_abundance="length_scaled_tpm"`，需 `tx2gene`）；STAR 读每个
`ReadsPerGene.out.tab` 并**按链特异性选列**；featureCounts 解析合并矩阵。输出
`counts.csv`（基因 × 样本，**整数**）与每样本一行 metadata。**Salmon/RSEM 的估计值必须
四舍五入成整数**，因为 PyDESeq2 要求整数计数。做完必看：比对率、重复率、rRNA 比例、
PCA 与样本距离热图、p 值直方图。

### 1.2 差异表达（PyDESeq2）

```python
counts_df = pd.read_csv("counts.csv", index_col=0).T      # 样本 × 基因
genes = counts_df.columns[counts_df.sum(axis=0) >= 10]    # 低表达过滤
metadata["condition"] = pd.Categorical(metadata["condition"],
                                       categories=["control", "treated"])
dds = DeseqDataSet(counts=counts_df[genes], metadata=metadata,
                   design="~batch + condition", refit_cooks=True)
dds.deseq2()
ds = DeseqStats(dds, contrast=["condition", "treated", "control"]); ds.summary()
```

- 设计公式**调整变量在前**：`~batch + condition`；对比格式 `[变量, 检验水平, 参照水平]`。
- 显著性用 `padj < 0.05`（BH），再叠加 `|log2FC| > 1` 得"显著且效应大"子集。
- `ds.lfc_shrink(coeff="condition[T.treated]")` **只用于排序和画图**，p 值仍基于未收缩估计。
- 产物含 `baseMean/log2FoldChange/lfcSE/stat/pvalue/padj`；要留可移植对象用
  `dds.to_picklable_anndata().write_h5ad(...)`，别读来历不明的 pickle。
- "一个显著基因都没有"时按序查：离散度、size factor、原始 p 最小 20 个基因，
  再考虑效应量小 / 变异大 / n 不够 / 批次与离群点。

### 1.3 通路与基因集富集

**先选方法**：阈值化基因列表 → ORA（`gp.enrichr`）；全量排序表 → preranked GSEA；
矩阵 + 分组 → GSEA；要每样本一个分数 → `gp.ssgsea`/`gp.gsva`；自定义背景或非模式生物 →
g:Profiler `domain_scope='custom'`。

- GSEA **用 `stat` 列排序**，不用 `log2FoldChange`（低计数基因上极不稳定；无 `stat` 用
  `sign(LFC) * -log10(p)`）；**绝不能先阈值化再喂 GSEA**。
- `gp.prerank(..., min_size=15, max_size=500, permutation_num=1000, seed=123)`——
  **必须设 seed**，否则 p 值不可复现。
- **背景必须是"本实验里可能被检出的基因"**，用全基因组会系统性抬高显著性。
- **ID 统一到符号**（人用大写、小鼠 Title case）："什么都没显著"最常见的原因就是
  ID 命名空间不匹配，不是生物学没信号。
- 库选 2–4 个贴问题的（Hallmark 主题 → GO:BP 机制 → KEGG/Reactome 通路）；
  **FDR 在单库内算**，跑 10 个库等于做 10 倍检验。
- 过滤用 `Adjusted P-value`/`FDR q-val`，**同时看 overlap 基因数与基因集大小**
  （1 个基因命中 2000 基因的集合也会"显著"）；GO 按相似度去冗余只报代表项。
  画图用 `gp.dotplot`/`barplot`/`enrichment_map`。

### 1.4 单细胞（Scanpy）

QC → 归一化 → 降维 → 聚类 → marker → 注释 → 保存：

```python
adata = sc.read_10x_mtx("10x_dir/")        # 或 read_10x_h5 / read_h5ad
adata.raw = adata                           # 过滤基因前先存原始
sc.pp.filter_cells(adata, min_genes=200); sc.pp.filter_genes(adata, min_cells=3)
sc.pp.normalize_total(adata, target_sum=1e4); sc.pp.log1p(adata)
sc.pp.highly_variable_genes(adata, n_top_genes=2000)
sc.pp.pca(adata, n_comps=40); sc.pp.neighbors(adata, n_neighbors=15)
sc.tl.umap(adata); sc.tl.leiden(adata, resolution=0.5)
sc.tl.rank_genes_groups(adata, "leiden", method="wilcoxon")
```

参数：`min_genes` 200–500（核转录组/低质量细胞多时下调）、`min_cells` 3–10（稀有类型
多时下调）、`pct_counts_mt` 5–20%（心肌、肝等高线粒体组织放宽）、`target_sum=1e4`、
`n_top_genes` 2000–3000、`n_pcs` 看方差比图拐点（不要固定 50）、`n_neighbors` 10–30、
`resolution` 0.4–1.2（**一次跑多个**再定粒度）。

- **Leiden 代替 Louvain**（`sc.tl.louvain` 已弃用）；需 `scanpy[leiden]` 装图算法依赖。
- **跨条件 DE 不要用 `rank_genes_groups` 的 p 值**——把细胞当独立重复就是伪重复。
  按 **样本 × 细胞类型** 把原始计数聚合成 pseudobulk，再走 PyDESeq2。
- 画表达图用 `use_raw=True`；出图统一走 `sc.settings.autosave` + `figdir`。
- 整合用 harmony/bbknn/combat（`batch_key` 指定样本列）；双细胞检测（Scrublet）
  前后都要报细胞数。
- 主产物 `.h5ad`；`.rds`（Seurat/SingleCellExperiment）**先在 R 里转 h5ad** 再读。
  索引对齐：`adata.obs["x"] = ext.set_index("cell_id").loc[adata.obs_names, "v"]`，
  直接赋值会因顺序不一致静默错位。

### 1.5 坐标与变异表示（最易静默出错）

**一条坐标是三个事实：数字、写它的约定、所依据的组装版本。**

- 转换：1-based inclusive → 0-based half-open 用 `start-1, end`；反向用 `start+1, end`。
  **end 永远不动**，两个数都变的转换一定是错的。
- 0-based：BED、bedGraph、bigWig、narrowPeak、BAM/CRAM 二进制 POS、
  PSL/genePred/refFlat、PyRanges。
- 1-based：GFF3、GTF、VCF、SAM 文本 POS、WIG、Picard interval_list、GRanges、
  samtools/UCSC/Ensembl 区域字符串。
- **变异不是区间**：VCF indel 的 `POS` 是**锚定碱基**（事件前一个未改变的碱基），
  同一缺失可写成 `chr1:7:CAC:C`、`chr1:3:CAC:C`、`chr1:2:GCA:G`。比较/去重/查库之前
  必须**先 trim 到最简、再左对齐**；多等位记录**先拆分再规范化**。
- `REF` 与 FASTA 不符（`MISMATCH`）= 变异与参考不是同一组装，
  **停下查 contig，不要调坐标**。
- 按主染色体长度判别 GRCh37/GRCh38；**GRCh37 与 hg19 只在线粒体上不同**
  （16569 vs 16571 bp），核坐标一致——混用能跑通，只有 mtDNA 结果是错的。
- 自检信号：GFF/GTF 出现 `start_below_one`（0-based 数据写进了 1-based 文件）、BED 里
  大量零长度特征、越界、contig 命名混用、BED12 `blockStarts` 写成绝对坐标、allele 未 trim。
- 转录本坐标不能与基因组坐标手算互转：`c.1` 是起始 ATG 的 A，没有 `c.0`，5'UTR 为负、
  3'UTR 带 `*`，GFF phase 是"到下一密码子要去掉的碱基数"而非 `start % 3`；
  用 VEP 或 `bcftools csq` 转。
- 报告时坐标旁永远写组装版本：`chr7:5,530,601-5,530,625 (GRCh38)`。

### 1.6 pysam 与序列文件

**数值坐标是 0-based half-open**（`fetch("chr1", 99, 199)` 取 100 个碱基），
**区域字符串是 1-based inclusive**（`fetch(region="chr1:100-199")`）。VCF 记录同时暴露
两套：`record.pos` 1-based、`record.start` 0-based 含、`record.stop` 0-based 不含；
**`VariantFile.fetch()` 的数值坐标仍是 0-based**。

```python
with pysam.AlignmentFile("sample.bam", "rb") as bam:
    for read in bam.fetch("chr1", 1_000, 2_000):
        if read.is_unmapped or read.is_secondary or read.is_supplementary:
            continue
        if read.mapping_quality < 30:
            continue
```

- `fetch()` 只给与区间**重叠**的记录；按文件顺序流式读全部（含未比对）用
  `fetch(until_eof=True)`，不需索引。
- `count()` 默认 `read_callback="nofilter"`；`count_coverage()` 默认碱基质量 15；
  `pileup()` 默认 min_base_quality 约 13、`max_depth=8000`。要精确区间必须
  `truncate=True` 并显式写出过滤条件。
- 写文件：合法 header、**保留排序顺序**（否则索引不可用）、先设 `query_sequence` 再设
  `query_qualities`、写后 `pysam.samtools.quickcheck()` 校验。
- Tabix 需**坐标排序 + BGZF**（普通 gzip 不行）；CRAM 默认写 3.1，
  **显式传 `reference_filename=`**；`threads=` 只加速压缩解压，不并行化 Python 层分析。
- **Biopython**：先确认格式再解析；1.86 起 `Bio.HMM`/`Bio.MarkovModel`/`Bio.Application`
  已移除，`PairwiseAligner` 默认 gap 分数由 0 改为 -1（会改变返回的对齐数目）。

### 1.7 覆盖度与表观（deepTools）

先用小区域（`--region chr1:1-10000000`）试参数再全量。

- **ChIP-seq：`--extendReads 200`**，多数情况加 `--ignoreDuplicates`；
  做深入分析前先跑 `plotFingerprint` 看富集。
- **RNA-seq：绝不 extend reads**（会跨剪接位点）；链特异用
  `--filterRNAstrand forward/reverse`，但先确认建库方向再解释链标签。
- **ATAC-seq：`alignmentSieve --ATACshift`** 做 Tn5 校正（等价 `--shift 4 -5 5 -4`
  并过滤为 proper pair），碎片长度分布应呈核小体阶梯。
- 归一化在同一比较内一致（bin 用 CPM、基因用 RPKM）；**GC 校正后不要再用
  `--ignoreDuplicates`**；BAM 与 BED 的组装版本必须一致。

### 1.8 系统发生

**MAFFT 比对 →（TrimAl 去坏列）→ IQ-TREE 2 建树 → ETE3 分析/画图**。

- MAFFT 方法：<200 条 `linsi`/`einsi`；<1000 条 `fftnsi`；>1000 条 `fftns`/`--auto`；
  >10000 条 `--retree 1`。
- **`iqtree2 -s aln.fasta --prefix X -m TEST -B 1000 -T 4`**：`-m TEST` 自动选模型，
  `-B 1000` 超快自举；DNA 常用 `GTR+G4`/`HKY+G4`，蛋白 `LG+G4`/`WAG+G4`/`Q.pfam+G4`；
  >5000 条换 FastTree（`-nt -gtr` 或 `-lg`，快 10–100 倍）。
- **树必须定根**（外群或 midpoint）；输出 `.treefile` + `.log` + 统计量
  （叶数/内部节点数/总枝长/叶间距离）。病毒与细菌序列建树前查重组（RDP4/GARD）。

### 1.9 其余条目要点

- **TileDB-VCF**：**沿用 VCF 的 1-based 坐标**；批量摄入设内存预算，相近区域查询要合并，
  多写者会损坏数据集。
- **scvi-tools / scvelo**：都要求**原始计数**、过滤低计数基因、把批次与供体等已知技术因素
  `setup_anndata` 注册进去；scvelo 需 unspliced 层覆盖、**细胞数 ≥2000**，
  先 stochastic 再上 dynamical，箭头方向的生物学连贯性本身就是 QC。
- **geniml / gtars**：先过安全闸门与坐标/组装契约，本地审计（组装、校验和、供体泄漏）
  再跑模型，并单独检查模型与 universe 的兼容性。
- 纯在线条目（gget、bioservices、onekgpd、cellxgene-census、alphagenome、
  genomic-intelligence、waypoint-bio 等）在无网工作区不可用；接口返回一律视为不可信数据。

---

## 二、化学、药物与结构

### 2.1 分子表示（RDKit / datamol）

- **外部来源分子先标准化**：`dm.standardize_mol(mol, disconnect_metals=True,
  normalize=True, reionize=True)`；解析失败返回 `None`，**每次 `to_mol` 后都要判空**。
- 解析异常用 `Chem.DetectChemistryProblems()` 诊断；依赖氢的性质先 `AddHs()`；
  画图与 3D 分析前要区分 2D/3D 坐标。
- **SMARTS 里未指定的属性匹配任何东西**，该限定的都要限定；`MolSuppliers` 不是线程安全的，
  不要跨线程共享。交换用 SMILES/SDF。
- 指纹：Morgan/ECFP（通用相似性）、MACCS（快、维度低）、atom pair（含距离）。
  Butina 聚类适合 ~1000 个分子，更大规模用 `dm.pick_diverse()`。

### 2.2 药物相似性与结构告警（medchem）

```python
rfilter = mc.rules.RuleFilters(rule_list=["rule_of_five", "rule_of_oprea",
                                          "rule_of_cns", "rule_of_leadlike_soft"])
df = rfilter(mols=mols, n_jobs=-1)                  # 含 pass_all / pass_any / 各规则布尔
nibr = mc.structural.NIBRFilters()(mols=mols, n_jobs=-1)   # severity >= 10 默认排除
```

- 查询语言：`mc.query.QueryFilter('MATCHRULE("rule_of_five") AND NOT HASALERT("pains")
  AND HASPROP("tpsa", <=, 90)')`，支持 `MATCHRULE`/`HASALERT`/`HASPROP`/`HASGROUP`/
  `HASSUBSTRUCTURE` 与 `AND/OR/NOT`。
- 复杂度用 ZINC-15 分位：`complexity_filter(mols, complexity_metric="bertz", limit="99")`。
- 告警与规则组合使用，并**保留 `status`/`reasons`/`severity` 列做审计**。
  上市药经常违反 Ro5，前药与天然产物是常见例外，别把规则当判决。

### 2.3 分子机器学习

- **必须用骨架切分**（`dc.splits.ScaffoldSplitter()`）：随机切分会把相似分子同时放进训练
  与测试集，指标虚高——这是本领域最典型的泄漏。
- 顺序：随机森林 + 循环指纹做基线 → XGBoost/LightGBM → 深度学习（>5K 样本）→ GNN
  （>10K 样本）；小数据优先迁移学习。GNN 打不过指纹时先补数据、加 epoch、换
  AttentiveFP/DMPNN，而不是继续堆层。
- 特征与目标都归一化（`NormalizationTransformer(transform_y=True)`），
  且**只在训练集 fit，再 transform 测试集**；不平衡数据用 `BalancingTransformer`。
- 大数据集（>100K 分子）分块；**特征配置落盘**
  （`transformer.to_state_yaml_file("config.yml")`），否则特征复现不了。

### 2.4 对接与虚拟筛选（DiffDock）

- 适用：小分子配体（约 100–1000 Da）、类药有机分子、<20 残基小肽、单/多链蛋白；
  **不适合**蛋白–蛋白对接、大肽、共价对接、膜蛋白。
- **输出的是构象，不是亲和力**——置信度只用于初步排序，不能当最终决策。每个复合物生成
  10–40 个样本再排序；低置信度普遍偏低通常意味着配体异常、结合位点不清或蛋白柔性大。
  蛋白结构先查缺失残基、去掉远处水分子；配体用规范 SMILES。

### 2.5 分子动力学

**先能量最小化**（原始 PDB 有立体冲突）→ **NVT 平衡 50–100 ps** → **NPT 平衡
100–500 ps** → 生产；分析只取平衡后轨迹，**丢掉前 20–50%**。加氢键约束用 2 fs，
做氢质量重分配（HMR）可到 4 fs；溶剂化体系用周期性边界，带电体系静电用 PME 而非截断。

### 2.6 质谱（matchms / pyopenms）

版本敏感，老例程会直接报错：用 `ModifiedCosineGreedy`/`ModifiedCosineHungarian`
（`ModifiedCosine` 已移除）；**不要调 `add_losses()`**，改用 `spectrum.losses`/
`compute_losses(...)`/`NeutralLossesCosine`；**`SpectrumProcessor` 不可调用**，用
`process_spectrum()`/`process_spectra()`，后者返回 `(processed_spectra, report)`；
`Scores.scores` 是 `StackedSparseArray`，`scores_by_query()` 返回
`(reference_spectrum, score_record)` 对；参数名用 `spectra`。
**不要加载不可信来源的 pickle。**

### 2.7 结构、材料与其他

- **蛋白语言模型（ESM）**：生成从小模型起步，temperature 控多样性（0 确定 / 1 多样）；
  embedding 批处理并缓存，算相似度前先归一化；生成序列要用结构预测或实验验证。
- **代谢建模（COBRApy）**：改动模型用上下文管理器；先 `model.slim_optimize()` 验可行性；
  优化后**检查解状态是否 `optimal`**；FVA 需要时用 loopless FVA 并合理设
  `fraction_of_optimum`；交换与长期存储用 SBML。
- **量子计算、符号计算、仿真、材料（pymatgen）** 见索引。共同纪律：先在小规模上验证
  模型/电路/网格的正确性再放大，把收敛性、守恒量、网格无关性当流程步骤。

---

## 三、统计、实验设计与机器学习

### 3.1 统计分析：假设检查 + 效应量 + 完整报告

1. **先定问题**：假设、结局、预测变量、设计（独立/配对、几组），**此刻就定下检验方法**。
2. **看数据**：每组 n、均值、SD、中位数、缺失数，**先画原始数据**；组间样本量不等、
   缺失、地板/天花板效应、离群点都会改变该用哪个检验，要主动报出来。
3. **选检验**：两组独立连续正态 → 独立 t（否则 Mann-Whitney U）；两组配对 → 配对 t
   （否则 Wilcoxon 符号秩）；二分类 → 卡方或 Fisher；≥3 组独立 → 单因素 ANOVA（否则
   Kruskal-Wallis）；≥3 组配对 → 重复测量 ANOVA（否则 Friedman）；两连续变量 → Pearson
   （否则 Spearman）；连续结局 + 预测变量 → 线性回归；二分类结局 → Logistic 回归。
4. **查假设**：正态性（Shapiro-Wilk + Q-Q 图，**n ≥ 100 时以 Q-Q 图为准**，检验会过分
   敏感）、方差齐性（Levene）、线性、回归诊断（残差图 + Breusch-Pagan + Durbin-Watson
   + VIF）。方差不齐：t 用 **Welch**（`pg.ttest(..., correction='auto')`）、ANOVA 用
   Welch/Brown-Forsythe、回归用稳健标准误（HC3）。正态性轻度违反且每组 n>30 可继续用
   参数检验。**假设违反要同时报告"原计划"和"改用什么"**。
5. **跑检验 + 必带效应量**：d 小/中/大 = 0.20/0.50/0.80；η²_p = 0.01/0.06/0.14；
   r = 0.10/0.30/0.50；R² = 0.02/0.13/0.26；Cramér's V = 0.07/0.21/0.35（约定值，
   不是定律）。效应的**置信区间**用
   `pg.compute_esci(stat=d, nx=..., ny=..., eftype='cohen')`（`compute_effsize_from_t`
   只给点估计，不给 CI）。
6. **按 APA 报告**：描述统计（M、SD、n）→ 检验名 + 统计量 + df + **精确 p 值**
   （`p = .034`，只有小于 .001 才写 `p < .001`）→ 效应量 + 95% CI → 假设检查结果 →
   **所有计划内的分析，含不显著的**。

统计诚信：区分确证性与探索性；不为显著性换检验或换子组；多重比较用 Tukey HSD 或
Holm/BH 并说明用了哪个；**不显著 ≠ 无效应**（小 n 时做敏感性分析或等价性检验）；
**大 n 下微小效应也会 p<.001**，解释要以效应量开头；丢缺失值前先判断缺失机制，非 MCAR
考虑多重插补；设种子、报版本、留可运行脚本。

### 3.2 功效分析与样本量

**n、效应量、α、power** 四个量固定任意三个第四个就定了。

- **效应量不许编**，优先级：最小重要效应（SESOI）> 试点/既往研究估计**并收缩**
  （发表偏倚与赢家诅咒会系统性高估）> 约定值（必须说明是约定）。
- **必须做敏感性分析**：给区间和功效曲线，而不是一个数。
- **绝不做事后（observed）power**——它是 p 值的确定性函数。研究已做完要问"能检出多大
  效应"，报**敏感性分析（MDE）**或效应的置信区间。
- 默认 α=0.05 双侧、power=0.80（确证性/临床可用 0.90）。
- 四个容易忘的校正：**多重比较**（按校正后的 α/m 重算 n，或直接对 FDR/FWER 程序模拟）；
  **脱落**（`n_enroll = ceil(n_analyzed / (1 - dropout_rate))`，20% 脱落要多招 25%）；
  **聚类/设计效应**（`DEFF = 1 + (m-1)·ICC`，m 为簇大小）；**非均衡分配**（传 `ratio=`）。
- 没有闭式解的（logistic/Poisson 回归、混合模型、簇随机、生存分析、中介、交互）一律
  **模拟**：生成数据 → 用真正计划用的模型分析 → 重复 ≥1000 次（接近 80% 用 5000–10000），
  power = 显著比例，并报蒙特卡洛 CI。

### 3.3 实验设计（数据收集之前）

Fisher 三原则：**随机化、重复、区组化**。选设计：比较少数既定条件 → 完全随机；有已知
干扰因素（天/批次/位点）→ **随机区组**；单位能依次接受所有条件 → **交叉/重复测量**；
只能整群随机 → **簇随机**（在簇层面分析）；筛 ≥5 因子 → **部分因子/Plackett-Burman**；
量化主效应与交互 → **全因子 2^k**；找最优（有曲率）→ **响应面（中心复合/Box-Behnken）**；
连续空间仿真 → **拉丁超立方**。

随机化与 DOE 生成必须**带种子并落盘**：`block_randomization(n=60, arms=[...], seed=42)`
（小样本 <100 或连续入组时简单随机会失衡，**用置换区组保证全程均衡**）；
`stratified_block_randomization({...}, arms=[...], ratio=(2,1), seed=42)` 额外平衡预后因素；
`cluster_randomization([...], seed=42)` 用于干预在群体层面实施；
`arm_balance(sched)` 复查每组计数后 `to_csv("allocation_schedule.csv")`。
DOE：`two_level_factorial`（全 2^3）、`plackett_burman`（筛 7 因子）、`central_composite`
（带曲率优化）；因子用真实区间 `{"temp_C": (20,60), "conc_mM": (1,10)}` 传入，
**运行顺序默认随机**，避免因子与时间漂移混淆。

会毁掉研究的结构性错误：**伪重复**（3 只鼠 × 100 细胞是 n=3 不是 n=300，重复必须在处理
被随机化的那一层）；干扰变量混杂（周一全处理、周二全对照）；随机化缺失或被破坏；
没有同期对照；批次效应被当成生物学（**绝不能让批次与条件对齐**）；板边/位置效应；
部分因子设计忽略别名结构；两级设计里找曲率最优。

---

## 四、可视化与交付物

### 4.1 出图总原则

**先把科学含义表达对，再谈好不好看。**

- 不修改、隐藏、编造或选择性增强数据；保留原始表/图、排除规则、缺失编码、归一化、
  分箱、图像调整与随机种子。
- 用位置做主要编码；柱状/面积图**一般要包含零基线**；点线图可非零但要说明断轴。
- **不确定度必须命名**（SD/SE/CI/百分位/后验），并说明 n 与**重复的单位**。
- 缺失、零、删失、被排除是四件事，要能区分；不要静默连接缺失点。
- 面积/体积**按面积/体积缩放**，不是按半径/直径；对数轴标出底数与变换并说明零与负值
  怎么处理；分箱/平滑记录边界与方法；归一化写公式与参照，且**各面板范围一致**。
- 双轴尽量改成上下对齐面板；非用不可时说明单位，不能人为制造"看着相关"。
- 颜色**必须冗余编码**（颜色 + 形状/线型/阴影/直接标注）；对照度按渲染后实际尺寸检查：
  正文 4.5:1、大文本 3:1、**理解所必需的图形对象 3:1**；颜色不能是唯一线索。
- **不要声称某个调色板/DPI/格式让图"无障碍"或"符合期刊要求"**——那是编辑判断。

### 4.2 Matplotlib / Seaborn 实操

```python
fig, ax = plt.subplots(figsize=(89/25.4, 60/25.4),   # 期刊单栏宽用毫米换算
                       layout="constrained")
ax.plot(x, y, marker="o", label="Observed")
ax.set(xlabel="Time (hours)", ylabel="Response (unit)"); ax.legend()
fig.savefig("fig1.pdf"); fig.savefig("fig1.png", dpi=600)
```

- 生产代码用**面向对象接口**（`fig, ax = plt.subplots()`），`pyplot` 状态机只用于探索。
- `layout="constrained"` 支持 colorbar、嵌套 GridSpec、subfigure；**用了它之后不要再调
  `tight_layout()`**，那会把它关掉。需要精确物理尺寸时**不要用 `bbox_inches="tight"`**。
- DPI：屏幕 72–100、网页 150、印刷/投稿 300（成品 600 更稳）。
- 顺序色 viridis/plasma/inferno、发散色 coolwarm/RdBu（要有意义的中心）、定性色
  tab10/Set3；**避免 jet 这类非感知均匀的彩虹色**。带中心的发散映射用
  `TwoSlopeNorm(vmin=-2, vcenter=0, vmax=5)`；缺失值用 `cmap.with_extremes(bad="#777777")`；
  对数用 `LogNorm`/`SymLogNorm`；大数据量 `rasterized=True` 压体积。
- Seaborn 0.13+：`sns.lineplot(..., errorbar=("ci", 95), n_boot=5000, seed=...)`、
  `sns.barplot(..., estimator="median", errorbar=("ci", 95))`——**必须传 seed 和 n_boot**
  才能复现自助 CI；不要直接改 seaborn 内部 artist 列表。轴级函数（`scatterplot`/
  `lineplot`）配合自定义布局，图级函数（`relplot`/`displot`）用 `col=`、`col_wrap=` 分面。
- 导出后**必须回读文件检查**：尺寸、DPI、格式、字体是否嵌入、是否裁剪、图例与比例尺。
  SVG 用 `svg.fonttype="none"` 保留可编辑文本但字体不嵌入，`"path"` 保外观但丢文本。

### 4.3 示意图与文档

- **默认用 Mermaid（文本图）当图表的唯一真相来源**：可 diff、可改、可被 AI 解析；
  Mermaid 源码必须保留并提交。选对图型：流程/判定用 flowchart，交互用 sequence，
  数据模型用 ER，状态机用 state，时间线用 gantt/timeline，构思用 mindmap，
  多维对比用 quadrant/radar，流量用 sankey；加 `accTitle`/`accDescr`。
- **AI 生成的示意图只有 PNG**（没有矢量、没有 DPI 控制），生成随机、迭代次数上限很低。
  提示词要明确布局方向（"vertical flow, one box per row, generous spacing"）、明确连线
  （"arrow from RAF to MEK labelled phosphorylation"）、明确组件与数量，并**逐个检查拼写**
  ——拼错标签是图像模型最常见的失败；交付前对照审阅日志的分数与 critique。
- 幻灯片：每页要有强视觉元素、3–4 条要点、每条 4–6 个词、字号 24–28pt、留白 40–50%、
  高对比（7:1 优先）、布局有变化；**演讲是主体，幻灯片是视觉支撑**。
- 交付 Word/PowerPoint/Excel/PDF 时**必须回读产物验证**（文字溢出、占位符残留、公式重算、
  图表引用）。投稿格式要求时效性极强：确认到具体期刊/年份/赛道/阶段，打开官方作者指南
  并记录链接与查看日期；**不要靠改旧文件名的年份推断模板名**。
- 地理空间数据（GeoPandas 等）：精确坐标、地址、地块边界、轨迹都是敏感信息，默认只报
  计数、类别、粗粒度范围与脱敏标识符；CRS 显式声明；每个派生产物带来源校验和、CRS、
  操作参数、谓词与行数核对。

---

## 五、文献、写作与评审

### 5.1 检索、综述与引用

- **至少 3 个数据库**并纳入预印本服务器；**记录一切**：检索式、日期、结果数，落盘到
  `sources/`，否则综述不可复现。先试点检索再细化检索式。
- 筛选照 PRISMA 式计数：标题 → 摘要 → 全文，**记录每条排除理由**；系统综述建议双人
  独立筛选。综合时**按主题组织而不是逐条罗列研究**；明确比较、指出冲突、评估质量、
  标出空白。明确写出检索日期——所有引用必须验证。
- 引用管理：元数据不要盲信，抽取后抽样核对原始来源；**`@article` 条目不允许缺
  volume/pages/DOI**；多库结果合并后**去重 + 统一 key**（`--rekey`）；DOI 要验证；
  预印本已正式发表的更新为期刊版本；特殊字符正确转义否则 LaTeX 编译会崩。

### 5.2 科研写作（证据绑定）

**分阶段**：起草、证据核验、投稿批准是三个独立阶段，由人负责科学决策与最终批准。
**绝不编造**：引用/DOI/PMID/URL/引文原文、结果与数值、样本量与分母、方法与版本、注册号
与伦理批件、作者与贡献、资助与利益冲突、数据/代码可用性。**用显式的"缺失/未核实/不适用"
占位，不要用看起来合理的套话填充。**

- 来源分配 `E` 编号（`source_manifest.json`），论断分配 `C` 编号（`claims.csv`），
  数值/方法/结局/结果分配 `N/M/O/R` 编号（`consistency_manifest.json`）；CSV 里存论断
  文本的哈希而非原文。起草时把标记带进正文：`[claim:C001] [evidence:E001,E002]`。
- **每条事实性或数值性论断都要映射到已核实的证据 ID**；核实必须由人打开原始来源、
  确认命题与定位、核对书目信息并记录核实人与时间。**搜索摘要、模型总结、记忆、
  他人参考文献表都不能算核实。**
- 报告规范按实际设计选：随机试验 → CONSORT 2025 / SPIRIT 2025；系统综述 → PRISMA 2020；
  观察性 → STROBE；诊断准确性 → STARD；预测模型 → TRIPOD+AI；病例报告 → CARE；
  动物研究 → ARRIVE 2.0；质量改进 → SQUIRE 2.0；卫生经济 → CHEERS 2022。
- 方法学与结果要**交叉核对**并登记重复出现的数值与方法–结果映射，跑一致性检查，
  **每个不一致都要人工解释**（可能是分析集不同，但必须写出来，不能静默归一）。
- 正文之外还要逐条核实：伦理与知情同意、注册与方案、资助与赞助方角色、利益冲突、
  作者贡献与致谢、数据/代码/材料可用性、AI 使用披露。
- 图表要绑来源：链到源数据、代码、变换与证据 ID，与正文数值对齐；要有单位、分母、
  样本量、不确定度、分析人群、替代文本与非颜色线索，并在**最终尺寸**下人工检查。
- **只有责任人可以**：解决科学歧义、批准作者顺序与声明、批准对外披露或传输、标记
  "可投稿"、去掉草稿水印、授权提交。

保密底线：未发表稿件、评审材料、敏感/受限数据、个人健康信息，未经明确授权与政策审查
（期刊/机构/资助方/伦理/合同/法律/数据使用）**不得送到外部服务**；"删掉明显的人名"
不算去标识化。

### 5.3 同行评审

**评审前先过闸门**：确认授权（出版方/编辑/作者）、核对目标期刊的评审与保密与 AI 政策、
记录利益冲突与能力边界与需要的专科评审；**默认本地处理**，授权不清就不要看稿件内容。
绝不把未发表内容上传到公开模型/搜索引擎/语法工具/查重服务；不冒充被指派的评审人；
不编造稿件细节或评审结论；**不宣布属于编辑或评审组的决定**。

评审顺序：① 问题与目标量 → ② 设计与推断单位 → ③ 抽样、分配、对照、盲法、时点 →
④ 样本量或精度论证 → ⑤ 纳入/排除/脱落/缺失 → ⑥ 分析与设计是否匹配、假设 →
⑦ 多重性与预设定 → ⑧ 效应估计、不确定度、分母、危害 → ⑨ 解释、因果、外推。
再看可复现性与透明度（方案/注册/分析计划是否一致、数据与 accession、软件与参数版本、
代码与种子）、伦理与诚信（审批、同意、隐私、资助、利益冲突、作者贡献；**只描述可观察
的证据，不指控、不调查作者**，可信疑虑走保密编辑渠道）、图表与引用。

**每条意见写全五要素**：位置、观察、依据或判据、为什么重要、请求的动作；严重性分级
（关键/重要/次要）。要求补做实验时必须"是支撑核心结论所必需且与范围相称"，能用收窄范围、
澄清、敏感性分析、更正或加局限性说明解决的就不要求新实验。**给作者的意见**与
**给编辑的保密意见**分开，普通批评不要只放在保密栏。

### 5.4 批判性思维与假设

- 七个能力面：方法学批判（设计/对照/混杂）、偏倚识别（选择/测量/发表/认知）、统计评估
  （功效、多重性、p 值误用、效应量）、证据质量（研究层级、可重复性、推断强度）、
  逻辑谬误、研究设计改进、论点评估（区分"展示了什么"与"断言了什么"）。
- 提意见的方式：先说优点；**具体**（指明"表 2 显示…"、引用问题原句）；**相称**（区分致命
  缺陷与次要局限）；**标准一致**；承认不确定性。
- 假设生成的红线：绝不把假设/机制/因果/引用/表面模式说成已证实的证据；绝不因为"快速检索
  没找到"就宣称新颖；不从关联、时间先后、预测精度或模型输出推因果；不提供个体诊疗建议；
  **不自动给科学假设打分、排名、取舍**。

---

## 六、临床、医学数据与实验平台

### 6.1 PK/PD 建模

三条铁律：① **先固定暴露指标与分析人群再算任何东西**——AUC(0-t)、AUC(0-inf)、稳态
AUC(0-tau)、Cavg 是不同量，看完数字再选指标就是把阴性研究变阳性的方式。
② **结构模型、变异模型、协变量模型是三个独立决定**：先诊断哪类错了，别用加房室去吸收
本应建模的周期间变异。③ **收敛 ≠ 可识别**：RSE 200%、两参数相关 0.99 意味着数据分不开
它们，而**参数表看起来完全正常**，所以每次拟合都要同时报 RSE 与参数相关性。

- **NCA 的 λz 选择**：从最后三个可定量点向前扩，只有**校正 R²** 改善超过 0.0001 才保留
  更长窗口（普通 R² 单调上升，必然选最长窗）；**Tmax 及之前的点永远不合格**。
- **外推超过 20% 就报警**；稳态报 AUC(0-tau) 而不是 AUCinf。
- **房室模型别只看 AIC**（小样本下惩罚偏弱、会选过参数化模型），同时看 BIC、F 检验与
  各参数 RSE。**残差符号成串（runs test 显著）= 结构性错设，加权修不好**；残差异方差
  但符号随机才是权重错了。参数在**对数尺度**估计；PK 默认加权 `1/y²`（恒定 CV），
  同方差的 PD 终点上不适用。
- **模拟看群体分布**：报 p5/p25/中位/p75/p95 与达标比例；按典型患者调剂量会让约一半人群
  落在目标错误一侧。
- **暴露–反应**：报 `fraction_of_emax_reached`；**平台期不在数据范围内时 Emax 与 EC50
  是强相关的外推值**，不能当独立估计引用。C-QTc 检验**双侧 90% CI 上界**对 10 ms。
- **BE 三种互不通用判据**：平均 BE（90% CI ⊂ 80.00–125.00%）、EMA ABEL（上限
  69.84–143.19%，点估计仍需在 80–125%，且**需重复设计**）、FDA RSABE（Hyslop 标度化
  线性界）。样本量受**假定 GMR 影响远大于 CV**：把 0.95 假定成 1.00 会让 N 约减半。
- **异速放大**：<2 岁单靠体型会高估清除率数倍，必须加成熟度项（Anderson-Holford，
  需 PMA 周数），体积不受成熟度影响；FIH 除 MRSD 外，对激动剂类免疫调节药还要算
  MABEL 取较低者。
- **DDI（ICH M12）**：R1 ≥ 1.02（肝）/ ≥ 11（肠）、R2 ≥ 1.25（TDI）、R3 ≤ 0.8（诱导）。
  **阴性有意义，阳性只是进一步研究的触发信号，不是临床幅度预测。**
- **TDM 的 MAP 贝叶斯优于"谷浓度对人群参数"或对数线性回归**；**单点无法分离清除率与
  分布容积**，不敏感的参数只是退回先验。

**只计算、诊断、结构化，不下结论**：不判定生物等效、不选剂量、不改患者方案、
不判定无 QT 风险，也不替代药代专家与监管审评。

### 6.2 医学影像与切片

**DICOM（pydicom）**：

- `dcmread(path, stop_before_pixels=True, specific_tags=[...])` 读元数据，用最小允许列表；
  `force=True` 只绕过文件头校验，**不证明字节是合法 DICOM**。
- **绝不 `print(ds)`/`repr(ds)`、不把元素值写日志或导出全量 JSON**——元数据、私有元素、
  覆盖层、结构化内容、文件名、像素都可能含 PHI；日志只走允许列表 + 聚合。
- 像素变换顺序：`apply_modality_lut(frame, ds)` → `apply_voi_lut(..., ds, index=0)`；
  MONOCHROME1 可能需呈现反转，Palette Color 要 `apply_color_lut()`；
  **定量分析绝不能按单帧 min/max 归一化**。
- 多帧形状：灰度单帧 `(rows, cols)`、灰度多帧 `(frames, rows, cols)`、彩色单帧
  `(rows, cols, samples)`、彩色多帧 `(frames, rows, cols, samples)`。
- 去标识（PS3.15）要**递归**进每个 sequence item；UID 替换一对一且跨范围一致（结构 UID
  不能换）；像素与烧录标注不能靠"元数据里没有"推断干净；要重建 File Meta 与前导码。
  **删标签的脚本不等于任何合规**，确定性假名密钥等于再识别密钥，按机密管理。

**WSI（histolab）**：先看缩略图与金字塔层级，**提取前必须用 `locate_mask()`/
`locate_tiles()` 预览**；多组织块用 `TissueMask`、单块用 `BiggestTissueBoxMask`；
`tissue_percent` 常用 70–90；随机取样设种子；染色差异大用 Macenko/Reinhard 归一化；
tile 出来后做模糊/伪影/失焦过滤。

**神经电生理（Neuropixels）**：先查漂移（**> ~10 μm 会明显降低分选质量**）；
Neuropixels 1.0 用 `phase_shift` 校正采样偏移；高通 `freq_min` 300–400 Hz；质量阈值
`snr` 3–5、`isi_violations_ratio` 0.01–0.5、`presence_ratio` 0.5–0.95；
**自动 curation 只是起点不是裁决**，关键实验导出到 Phy 人工复核。

**生理信号（NeuroKit2）**：定位是研究与教学工具箱，**不得把输出呈现为诊断、治疗建议、
监护决策或报警**，不得当作医疗器械的验证/认证/监管证据，也不得据此声称某个生理构念在
新传感器/新方案/新人群上被有效测量。

### 6.3 临床与真实世界数据

- **依赖/药物敏感性（DepMap）**：当前 CRISPR 分析用 **Chronos** 分数（不是 DEMETER2）；
  区分"泛必需"与"癌选择"；**必须用表达数据交叉验证**（不表达的基因会显示为非必需）；
  细胞系识别用 DepMap ID（名字有歧义）；注意拷贝数放大导致的假必需；关联做 FDR 校正。
- **临床文档类条目**（clinical-reports、treatment-plans、clinical-decision-support）：
  只产出**研究、评估、文档与治理类产物**，必须显式标注**"草稿——不得用于临床、签名、
  归档或提交"**，只从已核实的授权来源事实填充。绝不：诊断、推荐或调整治疗、计算患者
  个体剂量、分诊/告警、做患者个体临床决策、支持床旁实时运行、替代专业判断、声称 FDA
  授权或任何合规。请求一旦可能影响某个人的诊疗，**停下来交给有执照的医疗专业人员**。
- **本体与受控词表**：把自由文本的组织/细胞类型/疾病/表型/实验/化学/物种/发育阶段解析到
  术语 ID 并校验 CURIE；元数据（GEO/ENA/BioSample/CELLxGENE/HCA/ISA-Tab）提交前统一到
  受控词表。

---

## 七、方法验证、法规就绪与实验自动化

### 7.1 分析方法验证（ICH Q2(R2)/Q14、ICH M10、USP、CLSI）

- **两条铁律**：① 先定框架与需要哪些验证特性；② **接受标准必须在采数之前写下来**。
  Q2(R2) 刻意几乎不给数值标准（来自规格、分析目标概况 Q14 §3 或开发数据）；
  **ICH M10 是例外，它给明确数字，且色谱法与配体结合法不同**。
- Q2(R2) Table 1 按**被测属性**（不是按技术）决定要求：含量测定 → 专属性、响应、准确度、
  重复性、中间精密度；限度试验 → 专属性 + 检出限；鉴别 → 只有专属性。Table 2 范围：
  含量测定 80–120%；含量均匀度 70–130%；杂质从报告阈值到规格的 120%。
- 线性：不能拿 r² 当线性证据，要看**反算浓度误差**（如 `--max-back-calc-error 2`）；
  宽范围曲线用 `1/x²` 加权；**上三分位残差方差超下三分位 10 倍以上**就报异方差。
- 准确度/精密度：**精密度在每个水平内估计，绝不跨水平合并**；用一元随机效应模型拆出
  重复性与中间精密度——重复性 0.07% RSD 看着很好，中间精密度 1.65%（大 23 倍）才是
  常规表现，**把日内数字当方法精密度会低估一个数量级以上**。建议用
  `--require-ci-within-limit` 要求**整个置信区间**落在限内，而不是均值擦边。
- 检出限/定量限：σ 取法不同（回归残差 SD / 截距 SD / 空白 SD）会让 QL 估计差 1.9 倍，
  **必须同时报告数值和所用方法**，并在限附近确认；杂质方法的 QL 必须 ≤ 报告阈值。
- 生物分析（ICH M10）逐条不同，`--modality` 无默认值：

  | | 色谱法 | 配体结合法 |
  |---|---|---|
  | 校正曲线容差 | ±15%，LLOQ 处 ±20% | ±20%，LLOQ/ULOQ 处 ±25% |
  | 准确度 / 精密度 | ±15% / ≤15% CV（LLOQ 处 ±20%/≤20%） | ±20% / ≤20% CV（LLOQ/ULOQ 处 ±25%/≤25%） |
  | 设计 | 4 个 QC 水平、每批 5 重复、≥3 批跨 ≥2 天 | 5 个 QC 水平、每批 3 重复、≥6 批跨 ≥2 天 |
  | 总误差 | 无此判据 | ≤30%，LLOQ/ULOQ 处 ≤40% |
  | ISR 一致性 | ±20%，≥2/3 重复 | ±30%，≥2/3 重复 |

  批次判定还有条容易漏的规则：**至少 2/3 的 QC 在容差内，且每个水平至少 50% 在容差内**
  ——整体比例达标但某个水平全军覆没，仍是不合格批次。
- **方法转移/比对**：`p > 0.05` 说明不了等价，**不能用"没有显著差异"当等价结论**。
  用 **TOST** 检验真差值落在预设界内；回归用 **Deming**（要声明误差方差比）或
  **Passing–Bablok**（非参数、抗离群），普通 OLS 假设参照值无误差会把斜率往零偏；
  还要检查**比例偏倚**。
- **这个技能只规划与计算，不下结论**：不判定方法已验证、不放行批次、不接受或拒绝数据、
  不关闭调查，也不替代分析员、技术复核人、质量部门或监管机构。

### 7.2 标准与合规就绪（ISO 13485/14971/17025/15189）

只产出**供授权人评审的草稿证据准备材料**。它不能：认证或认可任何东西；判定法规适用性、
器械分类、报告性、符合性路径、上市许可；替代管理层、实验室主任、质量负责人、授权签字人、
RA/QA、法律顾问、监管与认可机构；验证方法、计算或批准测量不确定度、建立计量溯源性、
设定风险可接受准则；也**不能从模板、清单、文件名、关键词、文档数量或脚本结果去推断实施
情况、能力、符合性或就绪度**。未决事项要保留为阻塞项，不要替用户"解决"。注意区分保证
轨道：ISO 认证、实验室认可、FDA QMSR 检查、CLIA 认证、MDSAP、EU MDR/IVDR 边界各不相同
——**实验室是被认可（accredited）而不是被认证**，ISO 15189 认可也不满足 CLIA。

### 7.3 不确定度与单位

① 输入时挂单位、只在输出时脱单位，转换在函数边界做，**不在计算中间转**。
② 先写出**测量模型**（包括估计值为零的修正项——漏一项就是漏掉它的不确定度）。
③ 每个输入给四样：估计值、标准不确定度、分布来源、自由度。
④ **Type B 换算用对除数**：证书的扩展不确定度除以声明的 k；矩形界限除以 √3。
⑤ 合并前识别相关性（同一标准器、同一仪器、同一拟合得到的输入都相关）。
⑥ 算灵敏系数，预算从 `c_i · u(x_i)` 读，而不是原始不确定度。
⑦ **线性化要检验**：同时跑蒙特卡洛，按 JCGM 101 第 8 条比较；不通过时报告蒙特卡洛结果。
⑧ **k 由有效自由度选**，不靠习惯。⑨ 先舍入不确定度，再把估计值舍入到同一位小数。
⑩ 说明这个 `±` 是什么（标准还是扩展、k 多少、覆盖概率、方法）；报之前做量级自检。

### 7.4 实验室自动化平台

**液体处理（PyLabRobot / Opentrons）的硬边界：绝不自动连接、初始化、回零、移动、加热、
振荡、离心、泵送或开关物理设备；也不要靠改环境变量或配置把模拟计划变成真机运行。**
模拟成功不等于可以上机。任何授权的真机运行前，必须有受训人员逐项确认：后端/设备身份/
固件/传输方式/台面与协议版本；物理台面与资源树逐个对上（载架、适配器、盖子、板、吸头架、
废液、朝向、条码、每个占用坐标）；校准、示教、运动包络、碰撞风险、夹爪与通道间隙；
源身份与实际体积、死体积、目标容量、吸头类型与滤芯兼容性、通道映射、单位、高度、速率、
液类、吹出/混匀、污染边界；防护门、废液容量、急停、PPE、生物与化学安全及安全中止恢复
流程。**追踪器状态只是记账不是传感**，证明不了液体或吸头真的存在；可视化器不建模物理。

---

## 八、判据与阈值速查

| 场景 | 默认 / 阈值 | 什么时候改 |
|---|---|---|
| 低表达基因过滤（bulk DE） | 总计数 ≥ 10 | 深度很低时下调并报出剩余基因数 |
| DE 显著性 | `padj < 0.05`（BH） | 叠加 `\|log2FC\| > 1` 得"显著且效应大" |
| GSEA 参数 | `min_size=15, max_size=500, permutation_num=1000, seed=123` | 必设 seed |
| scRNA 质控 | `min_genes` 200–500、`min_cells` 3–10、`pct_counts_mt` 5–20% | 核转录组；心肌/肝放宽 |
| scRNA 聚类 | `n_top_genes` 2000–3000、`n_neighbors` 10–30、`resolution` 0.4–1.2 | `n_pcs` 看方差比拐点 |
| 假设检验 | α=0.05 双侧、power=0.80 | 确证性、临床用 0.90 |
| 效应量基准 | d 0.2/0.5/0.8；η²_p 0.01/0.06/0.14；r 0.1/0.3/0.5 | 是约定，不是定律 |
| 正态性判断 | n<30 组内 Shapiro + Q-Q | n≥100 时以 Q-Q 图为准 |
| 方差不齐 | t→Welch；ANOVA→Welch/Brown-Forsythe；回归→HC3 | — |
| 聚类设计效应 | `DEFF = 1+(m-1)·ICC` | 簇随机化直接上模拟 |
| NCA λz 窗口 | 校正 R² 改善 > 0.0001 才延长；排除 ≤Tmax | 外推 > 20% 报警 |
| 平均 BE | 90% CI ⊂ 80.00–125.00% | ABEL 上限 69.84–143.19%（需重复设计） |
| ICH M12 基本模型 | R1 ≥ 1.02（肝）/≥ 11（肠）；R2 ≥ 1.25；R3 ≤ 0.8 | C-QTc 看双侧 90% CI 上界 vs 10 ms |
| ICH M10 容差 | 色谱 ±15%/±20%（LLOQ）；配体结合 ±20%/±25% | `--modality` 必须显式指定 |
| WSI `tissue_percent` | 70–90% | 组织碎片多时下调 |
| 出图 | 印刷 300+ dpi；正文对比度 4.5:1、关键图形 3:1 | — |

---

## 九、常见坑（按现象查）

| 现象 | 原因 | 怎么避免 |
|---|---|---|
| 富集"什么都没显著" | Ensembl ID 没转符号 / 物种大小写错 | 富集前先转换并统一大小写 |
| 富集结果太好 | ORA 背景用了全基因组 | 背景用"实验本可检出的基因" |
| DE 结论不稳 | 每组 <3 重复 / 批次与条件混杂 | 补重复优先于加深度；随机化并建模批次 |
| 计数对不上 | 链特异性选错列，静默丢掉约一半读段 | `salmon -l A` 或先推断链性；核对分配比例 |
| DESeq2 报错或结果离谱 | 喂了 TPM/FPKM 或非整数 | 只喂原始（或 length-scaled）整数计数 |
| 坐标比对丢匹配 | indel 未规范化（未 trim、未左对齐） | 先 trim 到最简再左对齐，再比较/去重 |
| REF 与 FASTA 不一致 | 变异与注释不是同一组装 | 停下查 contig，不要调坐标 |
| 流程只错 mtDNA | GRCh37 与 hg19 线粒体长度差 2 bp | 明确声明组装版本 |
| 单细胞跨条件 DE 的 p 值太小 | 把细胞当独立重复（伪重复） | 聚合成 pseudobulk 再走 DE |
| h5ad 元数据错位 | obs 直接赋值，索引顺序不一致 | 一律 `set_index(...).loc[adata.obs_names]` |
| 分子 ML 指标虚高 | 随机切分导致同类分子跨集 | 一律骨架切分 |
| 小数据上 GNN 打不过指纹 | 数据量不足 | >10K 样本再上 GNN，否则迁移学习 |
| 模型评估偏乐观 | 标准化/特征选择在切分之前做了 | 全放进 Pipeline，只在训练折 fit |
| 贝叶斯采样不可信 | R-hat > 1.01、ESS 低、有发散 | 提高 `target_accept`；非中心化参数化 |
| 回归结论错 | 忘了加常数项 / 用 OLS 处理二分类 | `sm.add_constant()`；按结局类型选模型 |
| 方法转移"证明"了等价 | 用 `p > 0.05` 当等价证据 | 用 TOST + Deming/Passing-Bablok |
| QL 数字不可比 | σ 取法不同且未声明、未确认 | 报数值 + 方法 + 在限附近确认 |
| 精密度被高估 | 把日内重复性当成方法精密度 | 随机效应拆出中间精密度，水平内估计 |
| PK 参数表看着正常但不可用 | 收敛 ≠ 可识别 | 同时报 RSE 与参数相关性 |
| 结构分析出错 | 未生成对应坐标、未加氢 | 3D 分析前 `AddHs()` + 嵌入优化 |
| 图像被期刊退回 | 只有 PNG、无 DPI 控制、标签拼错 | 逐标签人工核对；最终尺寸下检查 |
| 图表"看着相关" | 双轴 / 非零基线 / 面积按半径缩放 | 改对齐面板；面积按面积缩放；披露断轴 |
| DICOM 泄露隐私 | 打印 Dataset / 导出全量 JSON / 未递归去标识 | 最小允许列表 + 聚合 + 递归 + 专家核验 |
| 不小心指挥了真机 | 把仿真成功当成可上机 | 真机前逐项人工确认 + 干跑 |

---

## 十、一次做完该产出什么

- **通用**：可运行脚本（带种子与版本记录）；原始数据只读保留，派生结果另存；一份含
  "已扫描范围/截断说明/局限"的结果说明。
- **bulk RNA-seq**：`counts.csv`（整数，基因 × 样本）、metadata、DE 结果表、富集结果表
  （含库名与日期）、MultiQC 报告、火山图/MA 图/样本距离热图/PCA/富集点图。
- **单细胞**：`.h5ad`（含 leiden、UMAP、注释列）、每个 cluster 的 marker CSV、figures
  目录、pseudobulk 矩阵（如需跨条件 DE）。
- **统计与实验**：清洗后数据表 + 分析脚本；描述统计表；检验结果（统计量、df、精确 p、
  效应量 + CI）；假设检查结果；功效或敏感性分析；随机化/DOE 布局 CSV（带种子）。
- **文献与写作**：检索台账（检索式/日期/计数）、来源清单、论断–证据映射表、核验记录、
  稿件草稿与草稿水印、一致性检查输出；引用文件经去重与字段补全。
- **图**：矢量（PDF/SVG）+ 位图（PNG 600 dpi）双份；导出后回读检查的记录；来源数据与
  变换说明。
- **临床/法规类**：显式标注的草稿产物、来源事实清单、未决事项（保留为阻塞项）、
  "需由谁做什么授权评审"的说明。
- **实验自动化类**：模拟与规划产物、资源树与台面核对清单、操作前确认清单；
  未经授权不产出任何真机执行结果。

---

## 十一、其余条目索引

本技能**深度覆盖了四类**：生信与组学主流程、化学/药物/结构的可本地计算部分、统计与
实验设计、可视化与文献写作；**未展开的条目**按名检索其 SKILL.md 即可。全部 166 条：

**生信与组学（37）** bulk-rnaseq, pydeseq2, scanpy, anndata, scvi-tools, scvelo,
arboreto, cellxgene-census, biopython, pysam, scikit-bio, bioservices, gget, deeptools,
geniml, gtars, tiledbvcf, polars-bio, zarr-python, phylogenetics, etetoolkit, flowio,
onekgpd, alphagenome, genomic-intelligence, waypoint-bio, genomic-coordinates,
pathway-enrichment, nextflow, pacsomatic, bids, depmap, primekg, ncats-arax,
ontology-term-resolution, pathogen-variant-surveillance, folklore-variant-evidence

**化学、药物、结构与材料（29）** rdkit, datamol, medchem, molfeat, deepchem, torchdrug,
diffdock, molecular-dynamics, rowan, pytdc, matchms, pyopenms, esm, glycoengineering,
adaptyv, tamarind, cobrapy, pymatgen, astropy, qiskit, cirq, pennylane, qutip, sympy,
matlab, fluidsim, openpiv, simpy, lab-hardware-cad

**统计、机器学习与数据工程（28）** statistical-analysis, statistical-power,
experimental-design, scikit-learn, scikit-survival, statsmodels, pymc, shap, umap-learn,
pymoo, aeon, timesfm-forecasting, pytorch-lightning, transformers, stable-baselines3,
pufferlib, torch-geometric, optimize-for-gpu, dask, polars, vaex, networkx,
uncertainty-and-units, modal, datalad, lamindb, get-available-resources,
exploratory-data-analysis

**可视化、图表与文档交付（19）** scientific-visualization, matplotlib, seaborn,
markdown-mermaid-writing, scientific-schematics, infographics, generate-image,
scientific-slides, latex-posters, pptx-posters, venue-templates, docx, pptx, xlsx, pdf,
markitdown, liteparse, geopandas, geomaster

**文献、写作、评审与科研方法（26）** scientific-writing, peer-review, literature-review,
citation-management, scientific-critical-thinking, hypothesis-generation,
scientific-brainstorming, scholar-evaluation, research-grants, research-lookup,
paper-lookup, paperclip, bgpt-paper-search, paperzilla, pyzotero, open-notebook,
exa-search, parallel-web, market-research-reports, hypogenic, arbor, what-if-oracle,
consciousness-council, dhdna-profiler, autoskill, usfiscaldata

**临床、医学影像与实验平台（27）** clinical-reports, clinical-decision-support,
treatment-plans, pkpd-modeling, relsa-severity-assessment, pydicom, histolab, pathml,
deepspot-m, pyhealth, neurokit2, neuropixels-analysis, imaging-data-commons,
analytical-method-validation, iso-standards-readiness, database-lookup, pylabrobot,
opentrons-integration, ginkgo-cloud-lab, protocolsio-integration, benchling-integration,
labarchive-integration, omero-integration, dnanexus-integration, latchbio-integration,
pi-agent, hugging-science

其中 `statistical-analysis`、`statistical-power`、`experimental-design`、`pydeseq2`、
`pathway-enrichment` 的引用文件（`references/`）含更细的判定表：检验选择指南、效应量换算、
模拟功效模板、设计类型（交叉/裂区/拉丁方/簇）、多重比较方法（BH vs g:SCS vs Bonferroni）
与出图规范，需要深度时优先读这几个。

---

## 来源与许可

本技能改写自 K-Dense-AI/scientific-agent-skills（MIT）。

该仓库整体以 MIT 发布，但**逐条目许可不统一**，改写时只使用方法与流程描述、未转载原文：
其中 4 个 Office/PDF 文档条目（docx、pptx、xlsx、pdf）另附 "Proprietary / LICENSE.txt"，
源自 Anthropic 的 skills 仓库，其使用受你与 Anthropic 之间的协议约束；
`deepspot-m` 为 PolyForm-Noncommercial-1.0.0（非商用）、`what-if-oracle` 为
CC BY-NC-SA 4.0（非商用）、`cobrapy`/`etetoolkit`/`bioservices` 为 GPL 系列、
`rowan` 为需 API key 的专有服务、`primekg`/`phylogenetics`/`glycoengineering` 标注为
Unknown。这些条目本文仅以名称索引，未复制其内容；若需按其操作，请先确认其自身许可条款。
仓库自带的数据库类条目依赖外部网络服务，在隔离工作区中不可用。
