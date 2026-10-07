---
name: 科学数据库检索与变异解读
summary: 把 DeepMind 科学技能集压成可执行流程：变异解读、蛋白结构、通路调控、药物与文献检索
tags: 变异解读,蛋白结构,通路与调控,药物监管数据,文献检索
repo: google-deepmind/science-skills
license: Apache-2.0
---

# 科学数据检索与分析流程（Google DeepMind 科学技能集整合版）

## 这条技能覆盖什么，什么时候按它走

覆盖九类任务：**变异解读**（频率/临床意义/后果/保守性/调控）、**非编码变异的分子效应**（AlphaGenome）、**表达与蛋白丰度**（GTEx/HPA）、**蛋白序列与结构域**、**三维结构**（PDB/AlphaFold/Foldseek/PyMOL）、**功能注释与通路调控**（GO/Reactome/OLS/Open Targets/STRING/JASPAR/UniBind）、**化合物与监管数据**（ChEMBL/PubChem/openFDA/ClinicalTrials）、**文献检索**（PubMed/Europe PMC/OpenAlex/arXiv/bioRxiv）、**古代文本复原**（Aeneas/Ithaca）。

判断依据：用户提到上述任何一个数据库名、ID 体系（rsID / ENSG / UniProt / CHEMBL / NCT / GO / EFO …）或对应任务动词时，按该主题的流程走，**不要凭记忆作答**。

### 硬前提：这些能力大多依赖远程数据源

上面绝大多数步骤本质是**对远程 API 的查询**。

- **工作区能出网时**，按本文给出的端点与参数直接调用或用 `curl` 取数，把结果写入文件。
- **工作区不能出网时，不要伪造结果**。明确告诉用户"这一步需要访问某个数据库"，然后把能离线完成的部分做完：坐标与 ID 的格式换算、本地文件的解析与汇总、报告撰写、PyMOL 本地渲染、古代文本的本地模型推理（这一节是纯本地计算，不需要网络）。
- 任何情况下都不要用"内部知识"补一个具体标识符（PMID、CID、rsID、ENSG）。查不到就说查不到。

### 两条贯穿全程的铁律

**一、结果一律写文件，不要把大 JSON 打到 stdout。** 这些数据库的原始返回动辄几百 KB 到几 MB（dbSNP 的 `--full` 载荷 50 KB–1 MB，Reactome 单文件上限 1 MB，GTF 类输出可到几十万行）。正确姿势是让脚本带 `--output` 落盘，再用 `jq` 或几行代码把需要的字段抽出来读。终端只留一行状态。

**二、凭据绝不进对话上下文。** 检查某个 key 是否存在用安静模式：

```bash
grep -sq "^NCBI_API_KEY=" ~/.env && echo present || echo missing
```

缺失时不要问用户"把 key 发给我"，而是给出一条用户自己在他终端里跑的命令，并提醒输入会被隐藏：

```bash
printf "Enter NCBI_API_KEY (typing hidden): " && read -s v && echo && echo "NCBI_API_KEY=$v" >> ~/.env
```

禁止 `cat ~/.env`、`echo $VAR`、`printenv`、不带 `-q` 的 `grep`。所有支持 key 的服务（NCBI、openFDA、OpenAlex、AlphaGenome）都是"没有 key 也能用，但有 key 配额高一个量级"，先按无 key 额度规划，超限或拿到 429 时再引导用户配置。

---

## 主题一：人类遗传变异解读

目标：给一个变异，产出一张可解释的证据表（频率、临床意义、预测后果、保守性、调控语境）。

### 步骤

**1. 统一坐标与 ID。** 输入可能是三种形态，先归一到 `chrom:pos:ref>alt`（GRCh38，1-based）：

- 已有 rsID → `dbsnp_cli.py resolve-rsid rs7412` 拿 placements。
- 四值坐标（如 `8 19962213 C T`）→ `dbsnp_cli.py resolve-variant 8 19962213 C T`，**不要**用 `search-region` 反查，那条路是给区间枚举用的。
- HGVS → `dbsnp_cli.py resolve-hgvs 'NC_000008.11:g.19962213del'`，**参数必须用单引号**，否则 shell 会吃掉方括号和特殊字符。
- 需要一次性拿到 SPDI / hgvsg / hgvsc / hgvsp / vcf_string 全套 → Ensembl 的 `/variant_recoder/{species}/{id}` 一次给全，比反复转换省事。

**2. 人群频率（gnomAD）。** GraphQL POST 到 `https://gnomad.broadinstitute.org/api`，变异 ID 形如 `1-55516888-G-GA`（**没有 `chr` 前缀**），默认数据集 `gnomad_r4`。三个子集都要看：`exome`、`genome`、`joint`。频率判读优先看 `faf95.popmax`（最大可信祖源组 AF 的 95% 置信下界）和 `popmax_population`（是哪个祖源），而不是总 AF——一个变异在总人群里罕见、在某个祖源里常见，是完全不同的结论。

**3. 临床意义（ClinVar）。** `clinvar_api.py search --query "TP53[gene] AND \"uncertain significance\"[clinsig]"` 拿 variant_ids，再 `summary --variant_ids ...`，需要细节时 `evidence --variant_id <单个>`。`evidence` 才有坐标（GRCh38 节点）和逐提交者的评述，`summary` 只有摘要。

**4. 分子后果（Ensembl VEP）。** `ensembl_api.py vep 9:21971147:T:C` 或 `vep rs699`。重点字段：`most_severe_consequence`、`transcript_consequences[]` 里的 `consequence_terms`、`sift_prediction/score`、`polyphen_prediction/score`、`am_class/am_pathogenicity`（AlphaMissense）、`lof`、`loeuf`。可以打开插件参数 `AlphaMissense=1, Conservation=1, LoF=loftee, LOEUF=1, NMD=1`。

**5. 保守性与调控语境。**

- 保守性：`get_conservation.py --coordinates "chr1:215867804" --collection vertebrate`。单碱基 SNV 用 phyloP（连续值，可正可负），窗口或功能块用 phastCons（0–1），加 `--conserved-elements` 换成 phastConsElements 看有没有落在已知保守元件里。
- 转录因子结合：`get_tfbs.py --coordinates chr11:1001000-1010000 --tracks encRegTfbsClustered --tf-filter TP53`。
- 调控元件类型：`screen_api.py search --chromosome chr11 --start 5205263 --end 5207263`，看 `pct` 字段是 PLS（启动子样）、pELS（近端增强子样）、dELS（远端增强子样）还是 CTCF-only；再用 `linked-genes` 看它关联到哪些基因。

### 判据与阈值

| 指标 | 默认读法 | 什么时候要改 |
|---|---|---|
| gnomAD `faf95.popmax` | 远低于 1e-5 才算罕见；同时报 `popmax_population` | 研究特定祖源时要看该祖源的 `populations[].af`，不能只看 popmax |
| gnomAD 基因约束 | `oe_lof_upper`（即 LOEUF）越低越不耐受；字段名**不是** `loeuf` | 短基因、注释差的基因约束不可靠，要说明 |
| ClinVar `review_status` | 0–4 星：星数越高越可信，透传字符串自行判读 | 只有 0–1 星的 "Pathogenic" 不能当硬结论 |
| Ensembl `most_severe_consequence` | 多转录本时取最严重的那个 | 同时报 MANE Select 转录本上的后果，二者可能不同 |
| `is_accelerated`（保守性脚本） | 脚本判据是 `mean < -0.3` 或 `min < -2.0` | 这是脚本里的经验阈值，不是数据库官方标准，报告里要写明 |
| ENCODE `is_type_a` | 同时具备 DNase + H3K4me3 + H3K27ac + CTCF 四标记，才算高置信 biosample | 只做细胞类型特异性分析时需要 |

### 坑

- **组装版本混用。** dbSNP 用 RefSeq accession 而非"GRCh38"字符串：GRCh38 = `GCF_000001405.40`，GRCh37 = `GCF_000001405.25`；`search-region` **永远查 GRCh38**，GRCh37 坐标必须先 liftover。Ensembl 靠 `--assembly GRCh37` 或换 `grch37.rest.ensembl.org` 主机。UCSC 用 `hg38/hg19`，ENCODE 用小写 `grch38/mm10`。
- **dbSNP 报 HTTP 500 "ref mismatch"。** 现象是重试永远失败；原因是位置对但参考碱基与该组装不符。改用 `--assembly` 指定正确的 accession，不要机械重试。
- **ClinVar 的非编码变异常返回整个基因区间。** `evidence` 里的坐标是基因跨度而非变异位点；用返回的 `dbsnp_rsid` 走 dbSNP 取精确坐标。
- **CNV 的 `molecular_consequences` 常为空。** 只能靠 `title` 里的 "del"/"dup" 加区间重叠来判断。
- **UCSC 轨道名写错必 400。** `jaspar`、`ReMap` 这类无年份的名字是容器轨道，会直接报错；要写 `jaspar2026`、`jaspar2024`、`ReMapTFs`。先 `list_tracks.py --search "jaspar"` 确认。
- **UCSC 的速率极慢**：每秒 0.05 次请求，即 20 秒一次。批量坐标必须提前算好时间预算，或先合并区间再查。
- **ENCODE 批量 accession 要按 100 个一组切块**，否则 GraphQL 端点直接 HTTP 413。
- **gnomAD 用 `--rsid` 只取第一个命中**，多映射位点会取错；正式分析一律用 `chrom-pos-ref-alt`。
- **Ensembl 的 `external_db` 大小写敏感且不直观**（例如 `UniProt_gn` 而非 `UniProt`）；先查 `/info/external_dbs/{species}`。
- **Ensembl 的 `/overlap/region/` 区域上限 5 Mb**，超出必须切分。
- **负链基因。** 只有 Ensembl 的 `canonical-tss` 会自动处理链方向（正链取 Start、负链取 End）；其余接口都在正链坐标上，负链基因的 TSS、UTR、启动子范围需要自己换算。

### 交付物

`variant_evidence.tsv`，每个变异一行，列：`variant_id, rsid, chrom, pos, ref, alt, gnomad_af_popmax, gnomad_popmax_population, clinvar_significance, clinvar_review_status, vep_most_severe_consequence, sift, polyphen, alphamissense_class, phylop, phastcons, ccre_accession, ccre_class`。配一张按基因或按后果类型分组的汇总图，报告里写清用的组装版本和数据集版本（gnomAD r4、GENCODE v39/v46 等）。

---

## 主题二：非编码变异的分子效应（AlphaGenome）

目标：回答"这个非编码变异在分子层面到底做了什么"。三个层次从轻到重：单变异预测与可视化 → 饱和突变扫描（ISM）→ 全库打分（AVI）。

### 坐标与窗口（最容易错的地方）

- 底层 `genome.Interval` 是 **0-based 半开** `[start, end)`；`genome.Variant` 的位置是 **1-based**（VCF 兼容）；AVI 的命令行一律接受 **1-based 闭区间** `chr:start-end`，内部自己减 1。
- 变异字符串只接受 `chr:pos:ref>alt`（1-based），**不接受** `A:G` 形式，也不接受 rsID。
- 典型窗口：DNASE / ATAC / CHIP_TF / CAGE / PROCAP 取中心 501 bp，CHIP_HISTONE 取 2001 bp，polyA 取 400 bp，CONTACT_MAPS 取 1 MB。常规预测序列长度用 `2**20`，ISM 的上下文用 16 KB，剪接解释的预测区间 resize 到 131072。
- 参考系是 **hg38 + GENCODE v46**。小鼠要用 `organism=MUS_MUSCULUS`。

### 步骤

**1. 单变异效应。** `visualize_variant_effects.py --chrom --pos --ref --alt --gene --tissue --ontology --tracks={splicing|regulatory|all} --view={default|whole_gene}`。图分三档：主图变异 ±1000 bp、detail ±50 bp、whole_gene 加 10000 bp padding（调控分析建议用约 200 bp 的紧窗口）。

**2. 饱和突变扫描。** `analyze_ism.py --chrom --pos --ref --alt --tissue --ontology --modality=<DNASE|CHIP_TF|RNA_SEQ|...> --kmer_length=8 --min_threshold=0.05`。这一步回答"这个位点是不是一个真正的 motif，哪个碱基是关键的"。

**3. 剪接专门解释。** `interpret_splicing.py --chrom --pos --ref --alt --ontology_id --window=1500`。

**4. 批量打分。** `alphagenome_atlas_avi.py query|annotate|region|metadata|gtf`。`annotate -i in.vcf -o out.vcf --top_k=20 --min_phred=15.0` 给 VCF 逐条打分并写 CSQ 串；`region -r chr9:128225990-128226000 --max_window_size=1000` 做窗口扫描（**只做 SNV 替换**，N bp 产生 3N 个 SNV）。

### 判读规则

**幅度分档（`raw_score`）**：`|raw| < 0.1` 无显著；0.1–0.5 弱；0.5–1.0 中等（约 1.4–2 倍）；`> 1.0` 强（超过 2 倍）。RNA-seq 的 raw 近似 log2FC：-1 约等于表达降到一半，-4 约等于降到 1/16。**raw 不是百分比，也不要跨 scorer 比较**。

**分位数（`quantile_score`）**：相对 gnomAD v3 中 MAF>0.01 的常见变异算百分位，饱和在 ±0.999990。做发现性扫描时用 `|quantile| > 0.995`。**高 quantile 但 `|raw| < 0.1` 是"无分子效应"** ——那通常是低表达基因上方差稳定化带来的假象，要如实报"No Significant Effect"，不要硬讲故事。

**AVI Phred 分档**：`Phred = -10*log10(1-quantile)`。≥40 为 top 0.01%，≥30 top 0.1%，≥20 top 1%，≥15 top 3.16%，≥10 top 10%，<10 为后 90%。默认 `--min_phred=15.0` 就是取 top 3% 左右。

**剪接判读**：位点使用率上，`REF>0.5` 且 `ALT<0.1` 判 loss，`REF<0.1` 且 `ALT>0.5` 判 gain，`|diff|>0.05` 才值得报。junction 上，`REF>5` 且 `ALT<1` 判经典剪接丢失 / 外显子跳跃；`ALT>5` 且 `REF<1` 判 cryptic junction。若表达下降（-0.999）远强于剪接信号，主机制应判为转录而非剪接——除非确实出现了新 junction。

**polyA 判读**：3' 端切割位点 400 bp 窗口内，取 distal/proximal isoform ratio 的最大绝对 logFC。3'UTR 变异同时出现高 SPLICE_JUNCTIONS 和 RNA-seq loss，提示 polyA 信号丢失 / read-through，去 ISM 里查 `AATAAA` / `ATTAAA`（反向互补 `TTTATT`）。

**ISM 判读**：字母高度 `< 0.1` 就报"无特异性 motif 破坏"。正值表示激活、负值表示抑制。参考 motif：TATA `TATAAA/TTTATA`、polyA `AATAAA`、donor `GT`、acceptor `AG`、E-box `CACGTG`、GRE `TGTTCT`。

### 坑

- **`score_variant` 不接受 `ontology_terms`**，只能手动在 `adata.var` 里筛；`predict_variant` 才接受这个参数。用错直接报错。
- **列名不是想当然的**：`gene_name` / `output_type`（不是 `gene_symbol` / `modality`）；CHIP_HISTONE 用 `histone_mark` 而不是 `target`；GTF 的 feather 列首字母大写（`Feature/Chromosome/Start/End/Strand`）。过滤前先看 `df.columns`，否则 KeyError。
- **whole_gene 视图对超大基因会崩**（>500 kb，如 USH2A）。改 `--view detail` 或手写查询区域。
- **加 TF 过滤后 RNA-seq / DNase 的行会消失**：`f` 参数里 Assay 组是 OR 逻辑，而 RNA-seq / DNase 没有 `transcriptionFactorCode`。要显式补上 `SCORER_MODALITY:RNA-seq` 和 `SCORER_MODALITY:DNase`。
- **`region` 只做 SNV 替换**。如果原始变异是 indel，必须走 `query` / `annotate`，否则算出来的是一堆无关的 SNV。
- **多转录本歧义**：默认取 MANE Select；`--all_transcripts` 的输出可达几十万行，必须落盘。链方向务必核对（例如 APOA1 在负链，变异落在 TSS 上游 27 bp 仍属于启动子区）。
- **模型局限要主动声明**：snRNA / tRNA / rRNA 的高分位不可信（模型不建模 RNA 二级结构）；变异落在活跃 enhancer 上但 REF/ALT 曲线几乎重合，就是"占据 ≠ 破坏"，如实报无效应；ncRNA、蛋白稳定性、酶活这类机制，**调控分数阴性不能排除致病**。AVI 的输出只讲分子机制，**不得给临床诊断或用药建议**。
- **`metadata` / tracks 目录极大**（catalog 近 1 MB），永远不要无过滤 dump，用 `--top_n=20`。
- **输出规模预算**：`query` 约 0.5–1 秒/变异；`annotate` 约 10 变异/秒（带 track info 约 5/秒），1000 个变异约 2–3 分钟；`region` 窗口越大越慢，N bp 的 TSV 约 3N 行。超过 3 个变异就不要指望 stdout，必须 `-o`。

### 交付物

每个变异一个目录 `analysis_<chrom>_<pos>_<ref>_<alt>/`，内含 `report.md` 与固定命名的图：`plot_{tissue}_{gene}_effects.png`、`plot_{tissue}_{gene}_detail.png`、`plot_{tissue}_{gene}_wholegene.png`、`ism_{tissue}_{modality}.png`。`report.md` 用八节结构：发现摘要 → 基因组语境（变异 / 基因 ENSG / 位置 / 疾病）→ 命中表（列 `Biosample Name | Gene Name | Output Type | Raw Score | Quantile Score`，必须包含疾病相关组织）→ 图（每张 ISM 图单独解读）→ 假设评估（SUPPORTED / REFUTED / PARTIALLY SUPPORTED）→ 主要分子机制 → 局限 → 结论。批量打分另出 `annotated_variants.vcf`（CSQ 串 `Allele|AVI_PHRED|AVI_RAW|AVI_QUANTILE|AVI_TOP_PERCENTILE|AVI_TOP_FEATURE`）、`top_variants.json`、`region_hotspots.tsv`。表格列：`rank, variant, chromosome, position, ref, alt, avi_phred, avi_raw, avi_quantile, top_percentile, top_modality, top_feature_importance`。

给用户看的结果里，每个变异都附一条可点击的 AlphaGenome Atlas 深链：基址 `https://deepmind.google.com/science/alphagenome/atlas`，用参数 `q=chr:pos:ref>alt`、`m∈{locus,entity,variant,motifs}`、`md∈{RNA_SEQ,SPLICE_JUNCTIONS,SPLICE_SITE_USAGE,DNASE}`。把 `i=` 的区间和 `scores=` 都写成有界值，否则页面会卡死。剪接变异必须同时画连续 RNA_SEQ 和 SPLICE_JUNCTIONS 两个轨道。

---

## 主题三：表达与蛋白丰度（GTEx / Human Protein Atlas）

**分工**：GTEx 只做成人正常组织的 mRNA 与 eQTL；HPA 做蛋白层面的 IHC 半定量、亚细胞定位、RNA-蛋白一致性。都没有患病组织、胚胎组织、PTM 数据。

### 步骤

1. **基因符号 → 版本化 ID。** GTEx 用 `gtex_cli.py resolve-gencode-id TNF`，拿到的 `gencode_id` **必须带版本后缀**（`ENSG00000232810.2`），后续所有调用都用它。HPA 用 `hpa_cli.py resolve-ensembl-id ERBB2`，HPA 端点严格基于 Ensembl ID。
2. **组织表达。** `get-median-expression ENSG... --tissues "Whole Blood,Spleen"`，单位是中位 TPM（字段 `median`）；`get-top-expressed-tissues ENSG... --n 5` 本地排序取前几名。
3. **eQTL。** `get-gene-eqtls ENSG... --tissues "Whole Blood"`，或按区域 `get-eqtls-in-region chr17 7000000 7100000 "Esophagus - Muscularis"`。
4. **蛋白层面。** `get-tissue-expression ENSG... --tissues "duodenum,thyroid gland"` 拿 IHC 的 `level`；`get-subcellular-location ENSG...`；`get-atlas-entry ENSG... --format json` 一次取多个列，并补出 `RNA_protein_agreement`（一致性可靠性）。

### 判据与阈值

- IHC 蛋白丰度四级：High / Medium / Low / Not Detected。
- RNA 组织特异性用 **4 倍规则**：`Tissue enriched` = 单一组织比其余全部高 ≥4 倍；`Group enriched` = 2–5 个组织的组比其余全部高 ≥4 倍；`Tissue enhanced` = 比其余组织的**均值**高 ≥4 倍；`Low tissue specificity`；`Not detected`。脑区版把 Tissue 换成 Region。
- IHC 抗体可靠性 `ihc_ab_validation`：`Supported` / `Approved` / `Enhanced - Independent`，其中 Approved 代表高质量 IHC。
- GTEx 的 eQTL 端点只返回"显著"子集（面板阈值由 GTEx 侧定），**不要声称自己设了 NES 或 p 值阈值**。

### 坑

- GTEx 的组织 ID 用下划线（`Esophagus_Muscularis`、`Whole_Blood`），脚本会做归一化，所以 `"Esophagus - Muscularis"` 也能接受；但拼错会直接 `exit(1)` 中断。
- `get-eqtls-in-region` **不分页**（响应里没有 `paging_info`），其余端点用 0-based `page`，靠 `paging_info.numberOfPages` 翻页；每页最多 250 条。区域查询 `end - start` 最大 8 Mb。
- 版本口径要写死在报告里：GTEx 数据集 `gtex_v10`、GENCODE `v39`；HPA 的 `www.proteinatlas.org` 永远是最新版，历史版本要用 `vNN.proteinatlas.org`。skill 自述的组织数（54）与其引用文献（49）不一致，以实际返回的数据集为准。
- HPA 的查询字符串**含空格的值不要加双引号**，加了会破坏查询；子类用 `;` 分隔，同一子类多选用 `,`；布尔用 `AND`/`OR`/`NOT` 加括号。
- 速率：GTEx 每秒 1 次、HPA 每秒 2 次，批量基因要串行排队。

---

## 主题四：蛋白序列、结构域与同源搜索

**先做分工判断**，这四件事不一样：找同源序列用相似性搜索；比较已知同源序列的保守性用 MSA（**至少 2 条**）；有坐标文件找结构类似物用 Foldseek；只是渲染/叠合/测距用 PyMOL。**不要用错工具**——用 BLAST 找结构同源、用 Foldseek 找序列同源，都是典型的返工来源。

### 步骤

**1. 拿序列与元数据（UniProt）。** `uniprot_tools.py count | search | get | stream | map | sparql`。

- 已知 accession 用 `get P04637`；探索用 `search "gene:p53 AND reviewed:true" --limit 5`；批量用 `stream`（上限一千万条，**不支持 `--limit`**）。
- 查询语法：**空格 = AND，逗号是字面量**，多个值要写大写 `OR`：`accession:(P12345 OR P67890)`。字段名是 `protein_name:`（没有 `name:`）、`gene:`、`cc_function:`、`taxonomy_id:`、`reviewed:true`、`xref:PDB`。
- 按 ID 转换用 `map "P04637" --from_db UniProtKB_AC-ID --to_db Gene_Name`，映射方向有严格分档：`UniProtKB_AC-ID` 作为来源可映射到任意目标库；`UniParc` / `Proteome_ID` / `UniRef*` 只能映射到 `UniProtKB` 系列和同名 UniRef；`Gene_Name` 必须带物种 taxId；`UniProtKB` 与 `UniProtKB-Swiss-Prot` **只能作为目标**。
- **精确的全序列检索只有 SPARQL 能做**，REST `/search` 不支持序列字符串。

**2. 找同源序列。** 默认 MMseqs2：`mmseqs2_search.py <序列或FASTA> -o out.md -j out.json`；它走 ColabFold 的接口，通常 2 分钟内出结果，**退出码 2 表示限流或接口失败，应自动回退到 BLAST**。BLAST 用 `uniprot_blast.py <序列> -o out.md -j out.json [--databases ...]`，走 EBI，最长约 15 分钟。

- 库要选对：要人工审编的命中用 `uniprotkb_swissprot`；`uniprotkb` 会把 TrEMBL 的噪声带进来。
- 两个脚本都只保留排序后的前 300 条（`MAX_ALIGNMENT_HITS=300`），缺失的 E-value 记为 1000（即最差）。汇报时取 E-value 升序前 3–5 条。
- 判读看 `Q-Cov`（覆盖查询序列的比例）和 `E-value`（越小越显著），`Seq Identity` 只作演化背景。
- MMseqs2 常只回 UniProt accession 不带描述，那就必须再查一次 UniProt 补功能注释，**不要凭 accession 猜功能**。
- 报告里必须声明用的是 MMseqs2 还是 BLAST、以及用了哪个库。

**3. 同源序列比对（MSA）。** `msa_align.py <输入FASTA> -o <输出>`，走 EBI Clustal Omega。硬限制：**序列数 ≤ 4000、文件 ≤ 4 MB**，输入必须 ≥2 条且每条以 `>` 开头。需要 `USER_EMAIL` 作为作业标识。

比对的百分比必须写清分母，不同分母会给出差异极大的"同一性"：

- `Sequence Coverage = 相同残基数 / 较短序列长度`——判断某个域或片段是否在大蛋白里被完整保留（忽略长序列中的 gap）。
- `Global Identity = 相同残基数 / 总比对列数`——全长长度相近时用，最保守，惩罚所有 indel。
- `Overlap Identity = 相同残基数 / (总列数 − 末端 gap)`——片段对全长、有未对齐尾时用。
- `Conservation Index = 完全保守列数 / 总列数`——看整个家族的核心演化签名。

把已知的功能残基（催化残基、结合 motif）投影到比对的列索引上做局部保守性分析，比只看全局百分比有用得多。

**4. 结构域与家族（InterPro）。** `interpro_client.py fetch` / `count`。**必须用 UniProt accession，不能用基因名**（写 TP53 无效）。

- 典型调用：`fetch entry --source_db interpro --linked_endpoint protein --linked_source_db uniprot --linked_accession P04637 --output domains.jsonl`。
- `page_size` 默认 20、**最大 200**；要计数就用 `page_size=1` 配 `count`，并读顶层的 `count` 字段——**绝不要迭代计数**，几万条会把上下文拖垮。
- 判读：entry 类型分 `domain / family / homologous_superfamily / repeat / active_site / binding_site / conserved_site / ptms`；`homologous_superfamily` 表示结构相似但序列相似度极低。每个成员库命中看 `integrated`（指向整合后的 IPR）、`in_interpro`（false 表示未被整合）、`is_preferred`、`entry_protein_locations.fragments[].start/end`（**可以有多个 fragment，说明域不连续**）以及 `go_terms`（category code F/P/C）。
- **标准签名无命中时必须回退查 InterPro-N**（加 `--flags interpro_n`）。InterPro-N 是深度学习预测，适合暗物质蛋白、串联重复被 HMM 合并/漏检、不连续域、需要精确边界、宏基因组大规模初筛这些场景；**报告里必须声明这是预测而非签名命中**。
- 域架构（IDA）检索是两步：先 `ida_search`（只能打根 `/entry`，不能与非 IDA 参数混用）拿 `ida_id`，再用 `--query_params ida=<ida_id>` 打到 `/protein` 取蛋白。

**5. 取序列的兜底路径（NCBI）。** `ncbi_fetch.py` 有 10 个子命令，按优先级级联：直接 accession（`fetch-protein`）→ CDS 翻译（`cds-translate`）→ PubMed 关联（`pubmed-proteins`）→ locus（`locus-protein`）→ 基因+物种（`gene-protein`）→ 专利（`patent-search`）→ 物种+长度（`organism-length`，`[SLEN]` 精确长度，最后手段）。

- 遇到 `ENSG/ENST/ENSP` 走 Ensembl，遇到 `P/Q/O` 开头的 UniProt 走 UniProt，不要绕到这里。
- `cds-translate` 内部依次尝试：NCBI 预翻译的 CDS 蛋白 → GenBank XML 里的 CDS 注释翻译 → 原始核酸六框架 ORF 搜索。
- 专利序列里 **SEQ ID NO: 2 通常才是主蛋白**，SEQ ID NO: 1 往往是 DNA，高编号是变体。
- 如果返回记录带 `is_genomic: true`（拿到的是基因组记录而非 mRNA/CDS），**翻译结果不可信**，改用同源法。
- 速率：无 key 3 次/秒，有 `NCBI_API_KEY` 10 次/秒。`--retmax` 默认值按子命令不同（`search` 20、`gene-protein`/`locus-protein` 10、`pubmed-proteins`/`patent-search`/`organism-length` 50）。

### 编号偏移警告

涉及信号肽/前体（`precursor`）、isoform、`fragment` 的序列，残基编号与 UniProt canonical 不一致。InterPro 返回的 fragment 坐标、PyMOL 里高亮的 `resi` 号、MSA 的列索引，三者**不可直接互换**，必须先对齐编号来源再解释。

---

## 主题五：三维结构（PDB / AlphaFold / Foldseek / PyMOL）

### 1. 实验结构：检索与下载（RCSB PDB）

- 先拉 schema 再写查询：`fetch_schema.py --api search_structure --output schema.txt`，一次一个关键词地 grep，**不要凭记忆写字段名**。
- `search_pdb.py --query '<JSON>' --return_type entry|polymer_entity|mol_definition`。服务类型有 `text / text_chem / sequence / structure / seqmotif / chemical / full_text`；操作符 `exact_match, equals, exists, contains_phrase, contains_words, in, greater, less`。
- 常用参数：序列相似检索 `evalue_cutoff: 1`、`identity_cutoff: 0.9`、`sequence_type: "protein"`；结构相似检索 `number_of_candidates: 2000`；motif 用 PROSITE 模式（如 `C-x(2,4)-C-x(3)-[LIVMFYWC]-x(8)-H-x(3,5)-H.`）。
- 概念要分清：**entity** 是唯一分子，**chain/instance** 是拷贝（同序列不同链属于同一 entity），**assembly** 是生物学相关集合。链编号有 **label** 和 **auth** 两套方案，脚本和 API 一律用 label，而论文和用户常指 auth，必要时跟用户确认。
- 元数据优先用 GraphQL 取，不要为了几个字段把整套坐标下下来。分辨率优先读 `rcsb_entry_info.resolution_combined`（兼容不同实验方法）；引用优先 `primary_citation` 而不是 `citation`。

### 2. AlphaFold 预测结构：取数与质量评估

端点 `/api/prediction/{UNIPROT}`（每秒 1 次）。

**pLDDT 分档**：>90 very high；70–90 confident；50–70 low；<50 very low。逐残基的 pLDDT 存在 mmCIF 的 **B-factor 列**。判读用比例而不是均值：`frac_confident + frac_very_high ≥ 0.7` 判高置信（若同时 `frac_very_low > 0.15`，追加一句"含显著无序区"）；`≥ 0.4` 判中等（`frac_very_low ≥ 0.3` 时说"结构化域 + 显著无序混合"）；`< 0.4` 且 `frac_very_low ≥ 0.5` 判高度无序。

**PAE 判读**：残基对 PAE `< 5 Å` 记为 confident pairs，报其百分比。结构域切分用 `distance_cutoff=7.0`、滑窗 20、`min_domain_size=40`；全局域合并用 `merge_cutoff=15.0`、边界两侧各回看 30 残基；最终只保留长度 >50 AA 的域。结论口径：1 个域 = 单一刚性域；>1 个 = 多个独立域；0 个 = 完全无序。

**必须转达的警告**：模型没有 canonical 条目而改用最长 isoform；序列超过 2700 AA；高比例 pLDDT < 50。高无序蛋白**不要拿全长去做下游结构分析**（Foldseek、docking、叠合），只截取有序残基区间。

### 3. 结构相似性搜索（Foldseek）

**唯一前置条件：用户必须提供实体 3D 坐标文件（`.cif` / `.mmcif` / `.pdb`）。** 只有序列、基因名或 UniProt ID 时**必须中止**，先想办法拿到结构（AlphaFold 或 PDB）。

- 调用：`search.py <本地坐标文件> -o out.json > out.md`，可加 `--databases pdb100,afdb50`（默认就这两个）。允许的库只有 `afdb50, afdb-swissprot, pdb100, BFVD, mgnify_esm30, cath50, gmgcl_id, bfmd, afdb-proteome`，其它值应立即中止。
- **判读主要看 `Prob`（趋近 1.0 表示极高置信的真结构同源）和 `Q-Cov`**（覆盖整体形状还是只有局部 motif）；`E-value` 与 `Seq Identity` 只作演化背景补充。
- 输出表列：`Target ID | Q-Cov | Prob | E-value | Seq Identity | Aln Length`，取排序后前 300 条。**`TM-score` 不在汇总表里**，不要凭记忆引用它。
- `Target ID` 里内嵌的功能描述是功能分析的主要依据，归纳时按"多数命中是 X，但另有一簇 Y"来表述功能多样性。

### 4. 渲染与定量（PyMOL）

**渲染脚本必须严格按这个初始化顺序**，否则必崩：

```python
import os
os.environ["PYOPENGL_PLATFORM"] = "osmesa"
import pymol
pymol.pymol_argv = ["pymol", "-cq"]
pymol.finish_launching()
from pymol import cmd          # 只能在 finish_launching 之后
```

- **`cmd.fetch()` 必定失败**（工作区通常无外网），必须先 `cmd.load()` 加载已下载的文件。
- 加载后立刻验证 `cmd.count_atoms("all")`，为 0 就报错退出。
- 导出图用 `cmd.png("output/x.png", width=1200, height=900, dpi=150)`；结束时**必须 `cmd.save("output/session.pse")` 然后再 `cmd.quit()`**，否则进程挂死。
- pLDDT 四档着色按 **从低阈值往高阈值依次涂**：`af_very_low` = `0xFF7D45`（<50）、`af_low` = `0xFFDB13`（50–70）、`af_confident` = `0x65CBF3`（70–90）、`af_very_high` = `0x0053D6`（≥90）；选择器写成 `polymer.protein and b > 50` 这种形式。连续谱用 `cmd.spectrum("b","red_white_blue","polymer.protein")`。
- 叠合首选 `cmd.align("model2","model1")`（序列依赖，适合同一性 >40%）；若返回的 `result[1] < 20`（对齐原子数过少）视为差对齐，回退 `cmd.cealign("model1","model2")` 并取 `result['RMSD']` / `result['alignment_length']`。
- 距离用 `cmd.distance(...)` 画，但**必须同时用 `cmd.get_distance(...)` 把数值打印出来**——图只是证据，数值才是结论。
- 结合位点：`cmd.select("binding_site","byres (polymer.protein within 4.0 of target_ligand)")`；极性接触 `cmd.distance("polar_contacts","target_ligand","binding_site",cutoff=3.5,mode=2)`，然后 `cmd.hide("labels","polar_contacts")`；口袋放大 `cmd.zoom("target_ligand | binding_site", buffer=3.0)`。
- 坑：选择名只能字母/数字/下划线且字母开头（`binding site`、`1_ligand` 会崩）；`"chain a"` 与 `"chain A"` 不同；`cmd.distance()` 产生的是 measurement 对象而不是 selection，对它调 `cmd.count_atoms()` 会报错；NMR 或多模型结构做测距/叠合/渲染要限定 `state=1`；CA-only 结构（`count_atoms("name CA") == count_atoms("all")` 时判定）要设 `cmd.set("cartoon_trace", 1)`；对称复合物里 `organic` 会一次选中多个配体导致视角被拉远，用首个原子的 chain/resi 选出单个配体。

### 交付物

`results.json`（检索命中）、`schema_*.txt`（字段确认）、下载的 `.cif`/`.pdb` 坐标、`AF-{accession}-F1-metadata.json` + `.cif` + `_predicted_aligned_error_v6.json`、`*_foldseek_results.md` 与同名 `.json`、`output/*.png` 与 `output/session.pse`、以及 stdout 上的距离/RMSD/原子数表格。

---

## 主题六：功能注释、通路与调控网络

**先选对库，这七个互斥**：基因功能注释 → QuickGO；通路富集与通路层级 → Reactome；靶点-疾病-药物关联 → Open Targets；PPI 与网络富集 → STRING；TF 基序模型 → JASPAR；实验验证的 TF 结合位点 → UniBind；任意本体的 term 与层级校验 → OLS。OLS 只产 ID 与层级，不产富集统计。

### 1. GO 功能注释（QuickGO）

标准两步，**不要拿基因符号直接查注释**：

```bash
quickgo_tool.py geneproduct search --query "PROC" --taxonId 9606
quickgo_tool.py annotation search --geneProductId "UniProtKB:P04070" --evidenceCode "ECO:0000269"
```

- 关键参数：`--geneProductId`、`--goId`、`--goUsage exact|slim|desc`、`--aspect biological_process|molecular_function|cellular_component`、`--evidenceCode`、`--taxonId`、`--qualifier`（enables / part_of / involved_in / acts_upstream_of）、`--limit`（**最大 100，默认 25**）、`--page`。
- 层级查询 `go terms --ids --relation ancestors|descendants|children|complete|paths`；Slim 用 `go slim`。
- **证据码必须过滤**：不加 `--evidenceCode` 会被 IEA 电子注释淹没。实验类用 `ECO:0000269`（EXP，含 IDA/IMP），电子注释是 `ECO:0000501`（IEA）。
- 查父 term 的注释要加 `--goUsage desc` 才会带上子孙；不加 `--taxonId` 会混进所有物种。

### 2. 通路富集（Reactome）

```bash
reactome_analysis.py analyze --data "TP53,BRCA1" --fdr 0.05 --output result.json
```

- **两种分析的输入格式不同**：overrepresentation 是每行一个标识符的纯文本；expression analysis 是带 `#header` 的 TSV，第一列标识符、第二列起是数值。别混。
- **服务端默认不做富集过滤**，`--fdr` / `--pvalue` 是在客户端对已返回页做筛选的，所以**先把 `pageSize` 放大再筛**，否则会漏。
- 未映射的基因用 `token-not-found` / `download-not-found` 取回来**如实报告**，不要静默丢弃——未映射比例高通常说明 ID 体系或物种选错了。
- 接口限速 1 请求/秒；富集结果的 token **7 天后过期**，不要把它当永久 ID 存。
- 通路层级有冗余：顶层通路（如 `R-HSA-1640170` Cell Cycle）和子通路（`R-HSA-69278` Cell Cycle, Mitotic）会同时显著。**画图和钻取优先用子通路**，再用 `event-ancestors` 补上下文，否则同一批基因会在父子通路里重复出现。
- 物种参数注意：文档里给的小鼠/大鼠 taxon 编号与 NCBI 通行值不符，跨物种分析前必须核实。
- 单文件输出上限 1 MB，大结果集要加 `--summary`。

### 3. 本体解析（EMBL-EBI OLS）

- 基址 `https://www.ebi.ac.uk/ols4/api`，**硬上限 5 请求/秒**。工具分 `search_ols.py`、`suggest_ols.py`、`get_term.py`、`get_property.py`、`get_individual.py`、`get_ontology.py`、`get_stats.py`。
- **本体选择规则**：人疾病用 `doid`，表型用 `hp`，基因功能用 `go`，化合物用 `chebi`，解剖用 `uberon`，细胞类型用 `cl`，跨物种才用 `mondo`。
- **不加 `--ontology` 会在 250+ 个本体里搜**，噪音极大且会拿到非权威副本。用 `--defining` 只取定义本体（`GO:0005634` 只来自 GO）。
- 多步查询恰好两步：先用 `search_ols.py --ontology doid --exact --rows 1` 解析，再用 `get_term.py --obo_id DOID:5844 --relations parents` 取层级。不要跨本体乱搜。
- **`parents/children/ancestors/descendants` 只走 is-a 关系**；UBERON 和 CL 必须用 `hierarchical*` 系列（含 part_of、develops_from），否则层级会断。
- `--obo_id` 与 `--iri` 互斥；传 IRI 要双重 URL 编码。`--rows` 默认 10、最大 500；靠返回的 `pagination` 块（`start`、`rows`、`has_more`）判断有没有下一页。

### 4. 靶点-疾病关联（Open Targets）

GraphQL 端点 `https://api.platform.opentargets.org/api/v4/graphql`。

- **ID 体系必须先转换**：靶点用 Ensembl（`ENSG00000169083`，**不能直接传 HGNC symbol**，先 `search` 或 `mapIds`）；疾病用 EFO 或 MONDO；药物用 ChEMBL；变异用 `CHROM_POS_REF_ALT`（`1_154426264_C_T`，工具会自动剥掉 `chr` 前缀）。
- 关键子命令：`get-associated-targets <disease>`、`get-associated-diseases <ensembl>`、`get-target-druggability <ensembl>`（一次返回 tractability 与临床期安全性）、`get-disease-drugs <disease> --min-stage PHASE_3`、`get-l2g <variant> [--study-id]`、`get-credible-sets-near-target <ensembl> [--window 500000]`、`search-disease <query>`、`custom-query`。
- **判读**：`evidences` 是逐条证据记录，`associatedDiseases` 的 `score` 是聚合后的 0–1 关联分，只可排序、**不要自己发明分档阈值或 datatype 权重**。细定位可信集的星级按置信字符串精确匹配：4 星 `SuSiE fine-mapped credible set with in-sample LD`；3 星 `SuSiE fine-mapped credible set with out-of-sample LD`；2 星 `PICS fine-mapped credible set extracted from summary statistics`；1 星 `PICS fine-mapped credible set based on reported top hit`；`Unknown confidence` 无星。
- 坑：`get-l2g` 不带 `--study-id` 会横跨所有可信集，常返回数百条，必须比对 `count` 与实际返回条数，不等就是"结果不完整"。`credibleSets(regions:)` 是对预计算区域串做精确匹配且有缺失数据，找"基因附近"要用 `get-credible-sets-near-target`（按坐标重叠在本地过滤）。`--limit` 默认 50 会静默截断，看到 `_truncated` 标记就放大。

### 5. PPI 网络与富集（STRING）

- `string_cli.py` 的子命令：`map`、`network`、`partners`、`image`、`homology` / `homology-best`、`enrichment`、`ppi-enrichment`、`functional-annotation`、`functional-terms`、`valuesranks-key` / `valuesranks-submit` / `valuesranks-status`。
- **`--species` 是必填项且必须先问用户**，即使输入是 TP53 / BRCA1 也不许默认人类（人 = 9606）。
- **`--required_score` 是 0–1000 的整数阈值，400 = 中等置信**（不是 0–1）。`--network_type` 默认 `functional`，要物理互作用显式传 `physical`。
- 内部 ID 形如 `9606.ENSP...`；**先 `map` 再查可显著加速**，`map` 返回 `queryItem`、`stringId`、`ncbiTaxonId`、`preferredName`。
- `network` 的输出把证据通道分成独立列：`score` 综合、`escore` 实验、`dscore` 数据库、`nscore` 邻域、`fscore` 融合、`pscore` 系统发生、`tscore` 文本挖掘、`ascore` 共表达。汇报时按通道拆开讲，不要只报综合分。
- `enrichment` 输出 `category`、`term`、`p_value`、`fdr`、`description`，**判读用 `fdr < 0.05`**，`p_value` 只作参考。`ppi-enrichment` 返回 `number_of_nodes`、`number_of_edges`、`expected_number_of_edges`、`p_value`——p 小表示这组蛋白相对全蛋白组背景更容易成模块。
- GSEA 式的 values/ranks 是异步三步：取匿名 key → 提交两列 TSV（第一列蛋白 ID、第二列 p 值/logFC/rank）拿 `job_id` → `--wait` 轮询直到 `status: success` 再从 `download_url` 取结果，`--ge_fdr` 默认 0.01。非全表场景别用它，用同步的 `enrichment`。
- 坑：`functional-terms` 用的是 `--term_text` 而不是 `--identifiers`；`--species_b` 是逗号分隔且**不能有空格**；富集背景是 STRING 全蛋白组，不能当成"给定基因集内部富集"来解读。

### 6. TF 基序（JASPAR）

- 先用 `resolve_tf_id --name "JUN" --tax-id 9606` 把基因名解析成 Matrix ID，**不要直接把 symbol 传给 `get_tf_motif`**。Matrix ID 形如 `MA0488.2`，版本号后缀必须带上。
- `get_tf_motif --matrix-id MA0488.2 --format meme`（支持 `json`/`jsonp`/`jaspar`/`meme`/`transfac`/`pfm`/`yaml`）、`get_tf_metadata`、`get_tf_pwm --pseudocount 0.1`、`infer_from_sequence`、`get_tffm`。
- PFM 转 PWM 的公式是 `PPM[b][i] = (PFM[b][i] + pseudocount) / (N_i + 4*pseudocount)`，**`--pseudocount` 是逐碱基伪计数，默认 0.8**（等价教科书里的总伪计数 3.2）。跨工具比较时必须统一 pseudocount，否则扫描阈值不可比。
- 单次查询的基因组窗口**不得超过 100 kb**，脚本对更大区域自动分块。
- 语义：**JASPAR 只表示潜在结合**，细胞类型里到底结不结合要靠 UniBind 或 ChIP 数据支撑。

### 7. 实验验证的 TF 结合位点（UniBind）

- 命令：`list_species` / `list_collections` / `list_cell_lines` / `list_tfs` / `list_datasets` / `get_dataset <id>` / `download_tfbs <id> --output-dir <dir> --format bed|fasta`。
- 过滤参数：`--species "Homo sapiens"`、`--tf-name CTCF`、`--cell-line`、`--collection Permissive|Robust`、`--data-source "ENCODE"`、`--has-pvalue true|false`、`--jaspar-id`。
- 数据集 ID 形如 `EXP047889.HMLE-Twist-ER_breast_cancer.SMAD3`。分页 `--page` / `--page-size`（**最大 1000**）。
- **BED 文件的参考基因组版本没有标注**，不要假定 hg38，落本地做 bedtools 交集前必须用 Ensembl 交叉核对坐标。
- `list_cell_lines` / `list_tfs` 输出极大，必须用 `jq` 抽字段，不要 cat 整个 JSON。

---

## 主题七：化合物、药物与监管数据

**分工**：ChEMBL 管"化合物—靶点—活性—药物—适应症"这条药物发现链；PubChem 管单分子的理化性质、GHS 安全、药理文本、结构检索；openFDA 管美国监管数据（不良事件、召回、标签、审批）；ClinicalTrials.gov 管临床试验注册与入排标准。

### 1. ChEMBL

所有查询走 `chembl_api.py <subcommand> --output <file>`（**`--output` 是必填**）。

- 常用子命令：`molecule`、`target`、`activity`、`drug`、`drug_indication`、`mechanism`、`similarity`、`substructure`、`image`、`assay`、`xref_source`、`chembl_id_lookup`。
- 活性查询后**必须归一化单位**：`activity --filter target_chembl_id=CHEMBL203 standard_type=IC50 --normalize`，输出里会多出 `normalized_value_nM` 和 `normalization_note`。不同研究里的 nM / µM / pM 混在一起直接比较是错的。
- 结构检索（相似度、子结构）在服务端做，`similarity --smiles "..." --similarity 85`，不需要本地 RDKit。
- 跨库定位靶点：`target --filter target_components__accession=P00533`（用 UniProt accession 反查 ChEMBL 靶点）。
- 导出结构：`molecule --id CHEMBL25 --dl_format sdf`；出 2D 图 `image --id CHEMBL25`（默认 SVG 矢量，适合出版）。
- 分页：所有列表端点都有 `--limit` 和 `--offset`（默认只回 5 条），响应里的 `page_meta` 给出 `total_count`。

### 2. PubChem

- `resolve --name "aspirin"`（或 `--inchi`）拿 CID；`properties --cid`；`synonyms`；`safety`（GHS）；`pharmacology`；`view --heading "Crystal Structures"`；`assays --cid`；`xrefs --cid --type PatentID`；`similarity` / `substructure --smiles`；`range --feature molecular_weight --min 400.0 --max 400.05`；`query --path "compound/cid/2244/xrefs/PatentID/JSON"`。
- 底层 PUG-REST 路径结构固定为 `/<domain>/<namespace>/<identifiers>/<operation>/<output>`，例如 `compound/cid/2244/property/MolecularWeight,MolecularFormula/JSON`；Range 搜索写 `compound/molecular_weight/range/400.0/400.05/cids/JSON`。PUG-View 取文本段：`/data/compound/<cid>/JSON?heading=Safety+and+Hazards`（空格换成 `+`）。
- **解析失败时的兜底顺序**：离子或盐 → 改查中性母体化合物；复杂式 → 拆成主要组分或配体分别查；有 SMILES → 改用子结构或相似度搜索。
- 做"某化学物的完整画像"按固定顺序：resolve → properties → safety → pharmacology，最后综合成报告。做"结构类似的化合物作用于哪些靶点"：先 similarity/substructure，人工挑前 5–10 个 CID，再逐个 `assays`，找出共同靶点。

### 3. openFDA

- `openfda_query.py search|count|download --category --endpoint`。类别与端点要配套：`drug`{event, label, ndc, enforcement, drugsfda, shortages}、`device`{510k, classification, event, pma, recall, registrationlisting, udi, ...}、`food`{enforcement, event}、`other`{substance, unii, historicaldocument, nsde}、`animalandveterinary`{event}、`cosmetic`{event}、`tobacco`{problem, ...}、`transparency`{crl}。
- **日期必须写 `YYYYMMDD`**，区间用方括号加 `+TO+`：`receivedate:[20230101+TO+20231231]`。写成 `2023-01-01` 会直接报错。
- **`.exact` 后缀**：查具体商品名、反应术语、厂商名时必加，否则多词值会被拆成词元、返回大量噪声。`count --count_field "patient.reaction.reactionmeddrapt.exact" --summary 10`。如果 `.exact` 查回 0 条，去掉 `.exact` 先看都有哪些变体（很多品牌名带后缀，如 "TYLENOL Extra Strength"），再按完整名字重查。
- **带连字符的 NDC 必须加引号**：`product_ndc:"51285-092"`。不加引号时 `-` 会被当成布尔 NOT，变成 "51285 且非 092"。
- `drug/ndc` 只有**在售**产品；查已停产的要用 `drug/label` 并做整句精确匹配（此时 `openfda` 元数据块可能为空，要从 `package_label_principal_display_panel`、`description` 等标签文本字段读）。
- 分页：`--limit` 最大 1000，`--skip` 最大 25000；`--all_results` 自动翻页但**安全上限 25000 条**。常见药的不良事件量极大，先用日期区间收窄再下载。
- 反应术语用的是 MedDRA 的 Preferred Terms，而 MedDRA 是专有本体、**不在 OLS 里**。要近似它的层级（系统器官分类等）用 HP 或 NCIT 作为代理本体。
- **速率是硬约束**：无 key 240 次/分钟、**1000 次/天**；有 key 120000 次/天。一次多查询工作流就能把无 key 的日额度打光，多步分析前先配好 key。

### 4. ClinicalTrials.gov

- `clinical_trials_api.py search --condition --intervention --status --phase --age-group --study-type --sponsor --has-results --sort --fields --limit --count-total --page-token --advanced`，所有 flag 之间是 AND。
- 枚举值：`--status` ∈ {RECRUITING, COMPLETED, NOT_YET_RECRUITING, ACTIVE_NOT_RECRUITING, ENROLLING_BY_INVITATION, TERMINATED, SUSPENDED, WITHDRAWN}；`--phase` ∈ {PHASE1, PHASE2, PHASE3, PHASE4, EARLY_PHASE1, NA}；`--age-group` ∈ {CHILD(0–17), ADULT(18–64), OLDER_ADULT(65+)}；`--study-type` ∈ {INTERVENTIONAL, OBSERVATIONAL, EXPANDED_ACCESS}。
- **纪律**：先 `--count-total` 看命中量，再决定怎么取；**每次都带 `--fields`**（试验记录极大，用 `"NCTId,BriefTitle,OverallStatus,Phase"` 这种简写别名即可）；`--limit` 范围 1–1000（默认 10）。
- 分页只能用响应里的 `nextPageToken` 原样回传，**不要自己构造**。
- 复杂条件用 Essie 表达式走 `--advanced`：`AREA[Field]Value` 定位字段（`AREA[LocationCountry]United States`），支持 `AND`/`OR`/`NOT`，数值和日期用 `RANGE[min, max]`（如 `AREA[EnrollmentCount]RANGE[500, MAX]`）。
- `get-eligibility <NCT>` 一次拿入排标准、年龄范围、性别要求，是做患者匹配的入口。

### 交付物

化合物表（CID/ChEMBL ID、名称、SMILES/InChIKey、MW、XLogP、TPSA）、活性表（含统一到 nM 的 `normalized_value_nM`）、不良事件计数表（按 MedDRA PT 排序并注明报告总数）、临床试验表（NCT ID、标题、期别、状态、入组人数）。所有计数类结果都要说明数据截取口径（日期区间、limit/skip、是否分页取全）。

---

## 主题八：文献检索与证据汇总

**分工**：PubMed 是生物医学的主库（MeSH 索引、临床试验、与 NCBI 其它库的联动）；Europe PMC 强在开放获取全文和引用网络；OpenAlex 强在计量学与跨学科；arXiv 是物理/数学/CS 预印本；bioRxiv/medRxiv 按日期浏览生命科学预印本。**只有后两者是预印本**，引用前必须与正式版核对。

### 1. PubMed

CLI 形式是 `pubmed_api.py <输出文件> <函数名> <参数>`。主要函数：`search_pubmed`、`fetch_article_abstracts`、`get_full_text_pmc`、`cache_results_history`、`find_linked_biological_data`、`discover_available_links`、`global_database_discovery`、`verify_medical_spelling`、`match_raw_citations`。

**检索语法**：字段标签 `[tiab]`（标题摘要，精度最好）、`[mesh]`、`[pt]`（Publication Type）、`[dp]`/`[pdat]`（日期）、`[crdt]`（入库日期）、`[auid]`（ORCID）、`[ta]`（期刊）、`[sb]`（子集，如 `systematic[sb]`）；邻近搜索 `"gut microbiome"[tiab:~2]`（比 AND 更适合多词概念）；相对日期 `"last 1 months"[dp]`；自定义区间用 `YYYY/MM/DD:YYYY/MM/DD[dp]`。

**检索纪律**（这几条能省掉大量返工）：

- 双引号强制**精确短语**，会排除词序不同和中间隔词的变体。只对解剖部位、化合物名这类"词序有意义"的词组加引号，概念性匹配用邻近搜索。
- 截断 `*` 会**关闭自动词映射（ATM）**，`patholog*` 不会再自动展开成 MeSH。
- 加字段限制后返回 0 条，按这个顺序放宽：去掉 `[tiab]`/`[ti]` 限制 → 用 OR 扩同义词 → 改用 MeSH → 去掉最弱的约束（如把日期放宽到 2 年）。
- 找原始数据（accession、CID）时在检索式后加 `AND (accession[tiab] OR "GenBank"[tiab] OR "supplementary"[tiab])`，可以滤掉只谈概念不给数据的综述。
- 如果用户要找的东西可能不存在，**最多试 3–5 个不同角度的高质量检索式就收敛**，然后如实说没找到，不要无限迭代。

**批量取数（超过约 10 个 PMID 时）**：先用 `cache_results_history` 把 PMID 批量传到 NCBI History Server，拿 `webenv` + `query_key`，再把它传给 `fetch_article_abstracts`（此时 `pmids` 参数传空字符串 `""`）或 `find_linked_biological_data`，一次批量取回。取回后用 shell 管道直接瘦身：

```bash
cat ./full.json | jq '[.[] | {pmid: .pmid, title: .title, abstract: .abstract}]' > ./slim.json
```

超过 10 条摘要时永远先把 field 裁到 `title` + `abstract` 再读进上下文。

**全文**：`get_full_text_pmc <PMID>` 只对 PMC 开放获取子集有效，报错就退回摘要，不要假装读过全文。

**引用匹配**：`match_raw_citations` 用的是 ecitmatch，格式是 7 个管道分隔字段加尾部管道：`journal|year|volume|first_page|author_name|key|`，除 journal 外都可留空。高价值组合是 `journal + author + year`（能解决大部分）或 `journal + volume + first_page`；单独用 year 或 first_page 基本没用。期刊名用 NLM 缩写、去掉句点（`j biol chem` 而不是 `J. Biol. Chem.`）；作者只给第一作者，写成"姓 首字母"小写无句点（`takahashi k`）。ecitmatch 对规整引用的命中率约 70–80%，失败时按这个顺序回退：去掉最不可靠的字段重试 → 用期刊+年份+作者做 `search_pubmed` → 用标题 `[ti]` 检索 → 有 DOI 就直接 `10.1016/xxx[doi]`。

**其它**：`verify_medical_spelling "rhuematoid arthritus"` 在检索前先纠错；`global_database_discovery` 一次告诉你某个词在 NCBI 各库里各有多少命中，用来决定该查哪个库；`find_linked_biological_data` 可以从一篇论文直接跳到它关联的基因、化合物、核酸记录（linkname 用 `discover_available_links` 先查）。

### 2. Europe PMC

`europepmc_api.py search | download_pdf | get_fulltext | get_citations | get_references`。

- **所有查询自动附加 `OPEN_ACCESS:y`**，这是刻意的设计，不要试图覆盖它——检索结果里就不会有非开放获取的条目。
- 语法：`DOI:10.xxxx/yyyy`；`EXT_ID:34265844 AND SRC:MED`（按 PMID 查）；`AUTH:surname initials`；`TITLE:`；`JOURNAL:`；`PUB_YEAR:2024` 或 `FIRST_PDATE:[2023-01-01 TO 2023-12-31]`；`HAS_FT:y`。排序用 `--sort "CITED desc"` 或 `P_PDATE_D desc`。
- 分页用游标：`--max_results`（最大 1000）+ `--cursor`（把上一页的 `nextCursorMark` 原样传回，为空说明到底了）。
- DOI → PDF / PMID → 全文的标准两步：先 search 拿 `results[0].pmcid`，再 `download_pdf` 或 `get_fulltext`（默认纯文本，`--format xml` 拿 JATS 原文）。**下载后必须检查 PDF 非空且未损坏**。
- 引用网络：`get_citations MED 34265844` 和 `get_references MED 34265844`，source 可选 `MED`（PubMed）/`PMC`/`PPR`（预印本）/`PAT`（专利）。
- 限速 1 请求/秒。

### 3. OpenAlex

`openalex_cli.py resolve | get | filter | download-pdf | rate-limit`。

- **先 resolve 再 filter，永远不要按名字过滤**：`resolve authors "Geoffrey Hinton"` 拿到 `A5108093963`，再用 `--filter "authorships.author.id:A5108093963"`。
- filter 语法：逗号 `,` 是 AND、竖线 `|` 是 OR（如 `doi:10.1234/a|10.1234/b|10.1234/c`，一次最多 100 个）；排序 `--sort cited_by_count:desc`；`--group-by` 做聚合（如按 `publication_year` 统计机构产出）；`--sample N --seed M` 取可复现的随机样本。
- **成本要算**：单条 `get` 免费，`filter` 每次 $0.0001，`--search`/`resolve` 每次 $0.001，`download-pdf` 每次 $0.01。用 `--select` 限定字段、`--per-page` 取 5–10（默认 25、最大 100）来控制开销。无 key 的日预算极小（$0.01），只够做几次 `--search`。
- 已知只有付费档能用的过滤字段：`from_updated_date`、`to_updated_date`。
- 错误处理：401/429 都要引导用户配 `OPENALEX_API_KEY`；403 是套餐不够；404 先用 `resolve` 重新解析 ID。**空结果要如实报，并建议换检索词，绝不编造。**

### 4. arXiv

`search_arxiv.py --query "au:einstein AND ti:relativity" --max_results 5`，输出重定向到文件再解析（结果 JSON 很大）。

- 前缀语法：`au:`（作者）、`ti:`（标题）、`abs:`（摘要）、`cat:`（分类）；布尔用 `AND`、`OR`、`ANDNOT`；分页用 `--start`；排序 `--sort_by relevance|lastUpdatedDate|submittedDate` 配 `--sort_order`。
- 已知 arXiv ID 直接 `--id_list 1706.03762v5`。
- **限速是 1 请求 / 3 秒**，脚本已内置。
- 下载：`download_paper.py --id 1706.03762 --format pdf|html`（HTML 只有较新的论文有）；LaTeX 源码 `download_paper_source.py`。**解压 tar.gz 必须解到一个新建的独立目录**，不要在当前工作目录展开。

### 5. bioRxiv / medRxiv

**这不是关键词搜索引擎，是按日期浏览的预印本归档。** 选路：有 DOI 就用 `search_by_doi.py --doi "10.1101/2023.08.15.551388"`（最可靠）；知道大概日期和分类就用 `search_by_dates.py --start_date --end_date --category`，窗口取 **1–4 周**；**只有主题词、没有日期时不要用这个 skill**，先去有全文检索能力的库找到 DOI 再回来取元数据。

- 关键词和作者过滤是**在本地做的**——脚本会把整个日期区间的元数据全部下载再筛。所以宽日期区间（几个月、几年）配 `--keywords` 是头号反模式，会导致上千次 API 调用、超时、被封。**必须同时给窄日期和 `--category`。**
- 分类必须用规定的枚举值（如 bioRxiv 的 `neuroscience`、`genomics`、`bioinformatics`，medRxiv 的 `infectious_diseases`、`oncology` 等），脚本会严格校验。
- 摘要默认被剥掉（省上下文）；要读摘要必须加 `--include_abstracts`。`--match_logic` 默认 `AND`，放宽用 `OR`。
- **这个 skill 不支持下载 PDF**：要全文就先用 DOI 去 Europe PMC 换 PMCID，再用那边的下载。

### 交付物

结果表（列：`pmid/doi, title, authors, journal, year, abstract_snippet, url, oa_status`）、去重后的 BibTeX 或 CSL JSON、以及一段按主题分组的综述式摘要。**所有被引用的论文都必须列出 URL**，并说明每条结论对应哪篇来源。预印本要标注"预印本，未经同行评审"。

---

## 主题九：古代文本复原与归属（Aeneas / Ithaca）

这一节是**纯本地模型推理，不需要联网**，也不允许用网络搜索或外部工具去"补充"或"覆盖"模型输出。

- **标注符号**（先向用户说明再收文本）：`?` = 已知长度的缺口，预测这个位置的字符；`#` = 未知长度的缺口，预测一整段；`-` = 缺失但不需修复的字符；`_` = 未知长度且不需修复的缺失段。
- **预处理**：`preprocess.py --language=latin|greek --input "..."` 或 `--input_file`。拉丁语会转小写、把阿拉伯数字和罗马数字转成 `0`、剥掉编辑用的方括号和圆括号、去标点，只保留 `abcdefghiklmnopqrstuvxyz` 加 `0 . - _ ? # 空格`；希腊语会转小写、去掉重音、转数字记号、做 PHI 清洗（括号归一、sigma 转换），保留希腊字母表加同样的符号集。
- **推理**：`run_inference.py --language latin --input "..." --attribute --restore --contextualize --output_json results.json`。三个任务至少选一个，可任意组合；加 `--embedding` 会额外输出 384 维向量。
- **约束**：输入最短 25 字符（不够就用 `-` 补齐）；不允许连续 `##`，也不允许 `?#` 或 `#?` 相邻。文本超过 750 字符会自动切成有 33% 重叠的窗口分别推理，**地域和年代归属在所有窗口上取平均**，复原和平行文本按窗口拼接。
- **动手前先打招呼**：`?` 超过 10 个，或 `#` 配 `--restore_max_len > 10` 时，要告诉用户耗时——复原时间大致线性增长，约每个 `?` 多 10 秒（5 个约 1 分钟，10 个约 2.5 分钟，30 个约 8 分钟）；输入超过 750 字符会切窗，更慢。两个因素会叠加。**建议一次只修一个损坏区域**，比一次性修多处又快又好。
- **关键参数**：`--restore_beam_width` 默认 100；`--restore_max_len` 默认 15；`--restore_temperature` 默认 1.0（低更保守、高更有创造性）；`--contextualize_top_k` 默认 10；`--window_overlap` 默认 0.33；`--contextualize_exclude_test_valid` 会按内部数字 id 过滤掉测试/验证集文本（`id % 10` 为 3 是测试、4 是验证）。
- **呈现方式**：复原结果把 top-1 里补出来的字符**加粗**，再给 top-10 候选的编号表（排名、文本、分数）；地域归属给 top-10 排名表（排名、地区、分数）并在正文里点出第一名；年代归属报 top year 和加权平均年，描述分布形状（峰值十年、可能区间），**不要把 160 个 bin 全列出来**；平行文本给表（排名、ID、Trismegistos ID、地区、年代区间、分数、链接）并引用 top 命中的全文。显著性都用**词**来总结，不要 dump 原始的逐字符 saliency 数组。年份一律用 BCE/CE 格式。
- 每次都生成 HTML 仪表盘（`visualize_results.py --input results.json --output dashboard.html`）并给用户一个可点击的 http 链接，不要给 `file://` 路径。
- 首次返回结果时要提醒用户引用对应论文（古希腊语引 Ithaca，拉丁语引 Aeneas）以及数据集致谢（见下一节许可说明）。

---

## 贯穿所有主题的工程约定

**一、输出永远落盘，`--limit` 要给显式值。** 所有脚本都带 `--output`，stdout 只留一行"成功写到 <文件>"：一次 API 返回可能几十万行，直出就等于把整轮对话废掉。读完文件后用 `jq` / `jp` 或几行 Python 抽字段。写这类脚本时不要给 `--limit` 设静默默认值——那会让"我以为拿到了全部"变成常态。报告里凡是分页取数的，都要写明用了什么区间、有没有截断标记（`truncated` / `_truncated` / 数量对不上）。

**三、速率限制表**（写批处理脚本时按这个排队，多进程并发要用文件锁保证全局合并计数）：

| 服务 | 限额 |
|---|---|
| NCBI（E-utilities、dbSNP、PubMed、PubChem） | 3 次/秒；带 `NCBI_API_KEY` 10 次/秒 |
| gnomAD | 10 次/**分钟** |
| Ensembl REST | 15 次/秒（遵守 `Retry-After`） |
| UCSC Genome Browser | 0.05 次/秒（20 秒一次） |
| ENCODE SCREEN GraphQL | 10 次/秒 |
| GTEx Portal | 1 次/秒 |
| Human Protein Atlas | 2 次/秒 |
| QuickGO | 10 次/秒 |
| Reactome | 1 次/秒 |
| EMBL-EBI OLS | 5 次/秒 |
| Europe PMC | 1 次/秒 |
| arXiv | 1 次 / 3 秒 |
| AlphaFold DB | 1 次/秒 |
| openFDA | 240 次/分钟；1000 次/天（无 key）或 120000 次/天（有 key） |
| OpenAlex | 无 key 日预算 $0.01（极有限）；有 key 约 10 次/秒 |
| bioRxiv / medRxiv | 无公开数值，脚本内置跨进程节流 |

通用实现要求：用 `time.monotonic()` 计时而不是 `time.time()`；对 5xx 做指数退避重试；429 抛独立的限流错误；重试日志打到 stderr；错误信息里带上 URL 和限额值；对 400/403/404 这类不可重试错误，**把响应体读出来放进错误消息**——接口返回的 "Invalid parameter" 这类信息是自纠错的关键。

**四、分页与硬上限速查**：ClinVar `page_size` ≤ 10000（默认 500）；dbSNP `retmax` ≤ 5000（默认 500）；GTEx 250 条/页；Ensembl 区域 ≤ 5 Mb；GTEx 区域 ≤ 8 Mb；ENCODE 批量 accession 100 个/块；UniBind `page-size` ≤ 1000；QuickGO `--limit` ≤ 100；InterPro `page_size` ≤ 200；OLS `--rows` ≤ 500；ClinicalTrials `--limit` ≤ 1000；openFDA `--limit` ≤ 1000、`--skip` ≤ 25000、自动翻页安全上限 25000；UniProt `stream` 上限一千万条；Reactome token 7 天过期；JASPAR 单次窗口 ≤ 100 kb；MSA ≤ 4000 条序列且 ≤ 4 MB。

**五、ID 转换链**（跨库分析时照这条走，别用基因名硬闯）：基因符号 → UniProtKB（QuickGO `geneproduct`）→ Ensembl（Ensembl `map-id` 或 OLS）→ STRING 内部 ID（`map`）；基因符号 → 版本化 GENCODE ID（GTEx `resolve-gencode-id`）→ HPA 的 Ensembl ID；疾病名 → EFO / MONDO（Open Targets `search-disease` 或 OLS 的 `doid`/`mondo`）；化合物 → CID / ChEMBL ID / InChIKey。

**六、把跑通的流程沉淀成技能。** 一次多步分析做完并且验证有效之后，可以把它固化成一条可复用的流程。做法是**先对话再落笔**，不要一上来就写：先确认流程的目的与范围、输入输出、哪些步骤是刚性的（必须用某个库/某个参数）哪些可以灵活、失败时是问用户还是自动兜底、哪些步骤已被现有能力覆盖（覆盖了就引用，不要重复实现）、接口的速率限制、错误处理策略。把这些问题问清楚、给出设计（名称、步骤、依赖、每个子命令、限流策略、错误策略）并得到确认后再实现，最后用一个真实的输入跑一遍验证。**跳过这轮对话直接写，产出的流程要么太死要么太空。**

**七、报告必须写清口径**：数据库与数据集版本（gnomAD r4、GENCODE v39/v46、GTEx v10、JASPAR 版本后缀）、组装（GRCh38/GRCh37/hg38/mm10）、坐标约定（0-based 半开还是 1-based 闭）、阈值是默认还是自定义、截取区间与分页情况、哪些结论来自预测模型而非实验证据。

---

## 常见坑（跨主题）

| 现象 | 原因 | 避免方式 |
|---|---|---|
| 结果全错但没有任何报错 | 组装版本或物种用错 | 每个请求都显式传组装/物种参数，并在报告里写出来 |
| 同一个"同一性"数字两次不一致 | 分母定义不同 | 注明用的是 Coverage / Global / Overlap 哪个分母 |
| 分数很高但生物学上说不通 | 跨 scorer 比较，或高分位低 raw 的统计假象 | 只在同一 scorer 内比较；high quantile + `|raw|<0.1` 一律报无效应 |
| 富集结果一堆假阳性 | 没过滤 IEA 电子注释或没设 FDR | GO 注释限定 `ECO:0000269`；富集判读用 `fdr < 0.05` |
| 同一批基因在多个通路重复显著 | 通路层级冗余 | 用子通路 + `event-ancestors`，不要用顶层通路 |
| 结果条数比预期少 | `--limit` 的静默默认值或服务端截断 | 显式给 `--limit`，并核对 `count` 与实际返回条数 |
| 残基编号对不上 | 信号肽、isoform、fragment 造成偏移 | 先对齐编号来源，再解释 InterPro 坐标、PyMOL `resi`、MSA 列索引 |
| 拿 accession 直接下功能结论 | MMseqs2 常只回 accession 不带描述 | 回查 UniProt 补注释后再总结 |
| 不良事件计数虚高 | 同一份报告在数据里出现多次 | 计数前按报告 ID 去重，并说明去重口径 |
| 大 JSON 把上下文撑爆 | stdout 直出 | 一切走 `--output`，再用 `jq` 瘦身到最小字段集 |

---

## 一次完整交付应该产出什么

- **数据层**：`*_results.json` / `.jsonl` 原始返回（保留，便于复核）、坐标与 ID 转换表、去重后的实体清单。
- **表**：`variant_evidence.tsv`（变异解读）、命中表（AlphaGenome）、`annotated_variants.vcf` + `top_variants.json` + `region_hotspots.tsv`（批量打分）、化合物/活性/不良事件/临床试验表、文献结果表 + BibTeX。
- **图**：`plot_{tissue}_{gene}_effects.png` / `_detail.png` / `_wholegene.png`、`ism_{tissue}_{modality}.png`、结构渲染 `output/*.png`（含多角度或叠合前后对比）、表达或富集的分组汇总图。图一律落盘为文件（PNG，必要时附 SVG），不要只在对话里描述。
- **结构文件**：下载或预测的 `.cif` / `.pdb`、`session.pse`、Foldseek 的 `.md` + `.json`。
- **报告**：方法（用了哪些库、什么版本、什么参数）、结果（含单位和阈值）、局限（预测 vs 实验、样本量、覆盖度）、引用来源的 URL 清单。
- **口径声明**：组装版本、坐标约定、数据集版本、截断与分页情况、哪些步骤需要联网（如果这次没能联网完成）。

---

## 来源与许可

本技能改写自 `google-deepmind/science-skills`（仓库整体采用 Apache License 2.0；`plugin.json` 亦标注 Apache 2.0）。**这是对仓库内 40 个技能的方法与流程的中文重新组织，不是原文转载。**

**这个仓库按技能分别标注第三方数据源条款**，仓库自带的许可清单逐条列出了每个技能引用的数据源及其使用条款。上面的流程里凡涉及下列数据源，使用时都必须自行核对该数据源当前的条款，本节点名几个要求最明确的：

- **Predicting the Past（Aeneas / Ithaca）**：模型训练数据来自多个第三方铭文数据集，各有自己的许可——Epigraphic Database Roma（EDR）为 CC-BY 4.0；Epigraphic Database Heidelberg（EDH）为 **CC-BY-SA 4.0（带相同方式共享要求）**；Epigraphic Database Clauss-Slaby 的 ETL 仓库为 CC-BY 4.0；古希腊语部分依赖 Packard Humanities Institute 以 "Fair Use" 提供的 Searchable Greek Inscriptions 数据库。**使用其输出必须引用对应论文（古希腊语引 Ithaca，拉丁语引 Aeneas）并完整致谢上述数据集。**
- **AlphaGenome / AlphaFold DB / AlphaGenome Atlas**：分别受各自服务条款约束，AVI 的部分功能需要 API key。
- **gnomAD、GTEx、Human Protein Atlas、UniProt、RCSB PDB、UCSC Genome Browser、STRING、Reactome、JASPAR、UniBind、InterPro、Ensembl、ClinVar、dbSNP、ENCODE**：均在其官网单独声明了使用政策或数据许可（部分要求署名，部分对再分发有限制），批量下载或再发布前请核对其政策页面。
- **ChEMBL、PubChem、openFDA、ClinicalTrials.gov、PubMed / PMC、Europe PMC、OpenAlex、arXiv、bioRxiv / medRxiv**：各有引用规范与速率条款；openFDA 另有独立的授权说明；PubMed / PMC 与 arXiv 要求使用者自行确认所取论文本身的许可。

使用前请就上述各数据源确认自己的使用场景是否合规。
