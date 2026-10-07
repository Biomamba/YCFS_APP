---
name: paper-reading
description: "论文阅读辅助工具。将 PDF 论文通过 MinerU 转换为 Markdown，翻译为中文，生成结构化研究报告和三遍阅读法指南。触发条件：用户提到阅读论文、读论文、paper reading、论文翻译、论文解读、/paper-reading 等。"
summary: 把一篇具体的 PDF 论文完整读下来：转成文字 → 全文翻译 → 三遍阅读法指南 + 研究报告（4 个阶段、产出 4 个文件）
tags: 论文阅读,PDF,全文翻译,三遍阅读法,文献笔记
repo: huicod/paper-reading-skill
license: MIT（README 声明，仓库内无 LICENSE 文件）
metadata:
  version: "0.1.0"
  upstream_commit: "999933b1ea00e45b0ec668b349a72161f8725ece"
  upstream_date: "2026-04-11"
---

> **本平台的适配说明**（下面这段不是上游内容，上游正文从 `# Paper Reading Skill` 开始）
>
> 这条技能来自 [huicod/paper-reading-skill](https://github.com/huicod/paper-reading-skill)
> （MIT，仓库里**没有** LICENSE 文件，许可以它的 README 声明为准）。
> 完整的 `SKILL.md`、`README.md`、`scripts/`、`templates/` 都在。
>
> 上游是给 [Gemini Code Assist / Antigravity](https://cloud.google.com/products/gemini/code-assist)
> 的 `.agents/skills/` 体系写的，有 **7 处**和本平台对不上。不按这里说的来，
> 你会卡在 Phase 1 的第一条命令上，而且卡住的样子是"命令报了个文件找不到"，
> 看不出是宿主不一样：
>
> 1. **产物一律落在本次任务的工作区里**，不要往 `~/` 下面写。工作区是
>    **每个对话一个**的隔离目录，也是用户唯一能看到文件的地方。
>    正文里的 `paper_reading/{论文名}_{时间戳}/` 这个**相对路径照用**
>    （它本来就是相对工作区根目录的），只是别把它理解成某个固定的家目录。
> 2. **MinerU 的 API Token 本平台没有预置，服务器上也没有配过。**
>    所以 Phase 1 有两条路，按用户手上有什么来选：
>
>    - **用户自己有 MinerU Token** → 走上游脚本。先补一个依赖
>      （`mineru_convert.py` 要 `requests`，本平台的 Python 里**没有**装）：
>      `python3 -m pip install requests`。
>      Token 写到**本次任务工作区里**那份技能副本的 `api_key/key.txt`——
>      ⚠️ **不要**写进平台的内置技能目录：那是所有用户共享的一份，
>      别人的对话也读得到。
>    - **用户没有 Token（默认就是这种情况）** → **不要卡住，也不要编一个
>      Token**。用平台自带的 `pypdf` 抽文本（本平台没装 `pdftotext`，
>      但 `pypdf` 有）：
>
>      ```bash
>      python3 - <<'EOF'
>      from pypdf import PdfReader
>      r = PdfReader("论文.pdf")
>      open("markdown/full.md", "w").write(
>          "\n\n".join(p.extract_text() or "" for p in r.pages))
>      EOF
>      ```
>
>      ⚠️ **必须如实告诉用户这条路丢了什么**：抽出来的是**纯文本**，
>      **图片、公式、复杂表格全丢**，双栏排版的阅读顺序也可能错乱。
>      不要因为"反正后面还要翻译"就把这一步说得像是等价的 ——
>      用户据此决定要不要去 MinerU 官网自己转一份，那是他的判断。
>      正文里所有"图片路径 `![](images/xxx.jpg)`"的规则在这条路上
>      **无图可指**，别硬编出图片引用。
>    - 用户**已经给了 Markdown / 纯文本**（自己转好的、或者从网页复制的）
>      → 直接进 Phase 2，不要为了"走完流程"再去做一遍转换。
> 3. **`/paper-reading` 这种斜杠命令在本平台不存在**。触发靠的是自然语言：
>    「帮我读这篇论文」「把这篇翻译成中文」「论文解读」。用户贴一个 PDF
>    路径、或者在「文件」页传了一份 PDF 进来说"读一下这个"，都算。
> 4. **所有脚本路径都相对本 `SKILL.md` 所在目录。** 正文里那些
>    `.agents/skills/paper-reading/scripts/...` 是上游宿主的写法，在本平台
>    一定找不到。先把本技能所在目录 resolve 成绝对路径存起来
>    （比如 `PAPER_READING_ROOT`），再跑
>    `python3 "$PAPER_READING_ROOT/scripts/quality_check.py" <输出目录>`。
> 5. **`install.ps1` 不要运行**（它是 PowerShell 的，从占位仓库地址 clone
>    到 `.agents/skills/`）。`.gitignore` 同理 —— 它记录的是上游仓库的
>    排除规则（`api_key/`、`paper_reading/`），在这儿只是说明性的。
> 6. **正文里的 `view_file` 这类工具名是没有的**，用本平台工作区里能用的
>    读写工具代替（读文件、写文件、跑命令）。
> 7. **和另外两条技能的分工要拎清**，不然用户说"帮我读这篇论文"时
>    三条都想接：
>
>    | 用户想干的事 | 该用哪条 |
>    |---|---|
>    | 「这个方向最近有什么新文章」——还不知道读哪篇 | **文献速递**（先检索、筛出几篇） |
>    | 「把这篇整理成一份精读笔记」——要的是**结论与证据** | **deeppapernote** |
>    | 「把这篇 PDF 完整读下来」——要**全文翻译 + 三遍阅读法指南**，接受 4 个阶段、多轮对话 | **本条** |
>
>    本条是三者里**最重**的一条：一篇文章要跑 4 个 Phase、产出 4 个文件。
>    用户只是想要一段"这篇讲了什么"的答复时，别把它拉进这条流水线。
>
> 四个 Phase 的划分、完整性优先于压缩的翻译原则、三遍阅读法的具体写法、
> 质量抽检的检查项 —— **这些正文和 `templates/` 里的内容才是这条技能的
> 价值**，请照着做。`scripts/quality_check.py` 只用标准库，可以直接跑。

# Paper Reading Skill - 论文阅读辅助工具

## Overview

本 skill 提供一站式论文阅读辅助流程，**拆分为四个独立 Phase（阶段）**。
每个 Phase 是一个自然的对话断点，用户可以在任意 Phase 间暂停或跳过。

| Phase | 名称 | 对话轮次 | 产出 |
|-------|------|---------|------|
| Phase 1 | PDF → Markdown | 1 轮 | `markdown/full.md` + `images/` |
| Phase 2 | 全文翻译 | 1 轮（长论文最多 2 轮） | `translated/full_cn.md` |
| Phase 3 | 阅读指南 + 报告 | 1 轮 | `reading_guide.md` + `report.md` |
| Phase 4 | 质量抽检 | 1 轮 | 抽检报告（对话输出） |

> **产出优先级**：`full_cn.md`（全文翻译）> `reading_guide.md`（阅读指南）> `report.md`（研究报告）

## When to Use This Skill

- 用户指定一篇 PDF 论文并要求阅读/解读
- 用户输入 `/paper-reading <pdf_path>`
- 用户提到"帮我读这篇论文"、"论文翻译"、"论文解读"等

## Input

用户提供一个 PDF 文件路径，可以是：
- 相对路径（相对于工作区根目录）：如 `docs/AIOpsLab.pdf`
- 绝对路径：如 `E:\papers\my_paper.pdf`

## Output Structure

```
paper_reading/
└── {paper_name}_{YYYYMMDD_HHmmss}/
    ├── original.pdf                    # 原始 PDF 副本
    ├── progress.json                   # 进度追踪文件（自动管理）
    ├── markdown/                       # Phase 1 产物
    │   ├── full.md                     # 完整 Markdown（英文原文）
    │   └── images/                     # 提取的图片
    ├── translated/                     # Phase 2 产物
    │   └── full_cn.md                  # 中文翻译版本（含图片引用）
    ├── reading_guide.md                # Phase 3 产物
    └── report.md                       # Phase 3 产物
```

## Progress Tracking

每个论文目录下维护 `progress.json`，记录执行状态：

```json
{
  "paper_name": "gfs",
  "pdf_path": "papers/docs/gfs.pdf",
  "output_dir": "paper_reading/gfs_20260405_235854",
  "phases": {
    "phase1_conversion": "done",
    "phase2_translation": "in_progress",
    "phase3_guides": "pending",
    "phase4_qa": "pending"
  }
}
```

**每次开始时，先读取 `progress.json` 确定从哪里继续。**

---

## Phase 1: PDF → Markdown

### Step 0: 交互确认

```
准备解析论文：{pdf_filename}

请确认（直接回车使用默认值）：
1. MinerU 模型版本：vlm（高精度，默认）/ pipeline（轻量快速）
2. 论文语言：en（默认）| ch | japan | korean 等
3. 输出目录：paper_reading/{paper_name}_{timestamp}/（默认）

是否使用默认设置开始？(Y/n/自定义)
```

### Step 1: 准备工作

1. 验证 PDF 文件存在
2. 提取论文名称 + 生成时间戳
3. 创建输出目录结构
4. 复制 PDF 到 `original.pdf`
5. 创建初始 `progress.json`

### Step 2: MinerU 转换

```bash
# ⚠️ 本平台的路径不是这个 —— 见文首「本平台的适配说明」第 4 条。
#    下面这行的 `.agents/skills/...` 是上游宿主的写法。
python .agents/skills/paper-reading/scripts/mineru_convert.py "<pdf_path>" "<output_dir>/markdown" --model-version vlm --language en
```

**🔒 安全规则：**
- API Token 在 `api_key/key.txt`，由脚本自动读取
- **绝不**将 Token 写入代码、日志、终端或对话中
- `api_key/` 已在 `.gitignore` 排除

> **FALLBACK**: API 失败时可用 MinerU 桌面客户端手动转换

### Step 3: 完成并告知用户

更新 `progress.json`，报告结果并提示进入 Phase 2。

---

## Phase 2: 全文翻译

> **核心原则：一次对话尽量翻译完全文。只有超长论文（>40页）才拆为 2 次。**
>
> **完整性是最高优先级。漏翻、压缩、概括都是不可接受的。每个段落都必须完整翻译。**

### 执行方式

1. 用 `view_file` 分段读取 `markdown/full.md`（每次 ~200 行）
2. 翻译后立即写入/追加到 `translated/full_cn.md`
3. **不要按章节拆分对话**——在同一轮对话中连续读取、翻译、写入，直到全文完成
4. 如果因 token 限制被截断，更新 `progress.json` 记录断点，告知用户 `continue`
5. 正常论文（<25页）应在 1 轮对话内完成全文翻译

### 首次写入

在 `full_cn.md` 顶部添加元信息头：

```markdown
> **翻译信息**
> - 原文：{pdf_filename}
> - 翻译时间：{YYYY-MM-DD HH:mm}
> - 翻译方式：AI 辅助全文翻译
> - 图片位置：../markdown/images/

---
```

### 翻译规则

1. **保持 Markdown 结构**：标题、列表、表格、代码块、图片引用保留原格式
2. **图片路径**：`![](images/xxx.jpg)` → `![](../markdown/images/xxx.jpg)`
3. **术语**：首次出现 `English（中文）`，后续可直接用中文或缩写
4. **代码/公式**：代码块不翻译；LaTeX 保持原样
5. **图表引用**：`Figure 1（图1）`
6. **参考文献**：列表不翻译，正文引用标记保留
7. **跳过章节**：致谢（Acknowledgments）、参考文献（References）、附录中纯数据表等非核心章节**不翻译**，直接保留原文或省略
8. **风格**：学术论文风格，精确客观
8. **完整性**：**每段必须完整翻译，严禁省略/合并/概括**

---

## Phase 3: 阅读指南 + 研究报告

### Step 1: 生成三遍阅读法指南

参照 `templates/reading_guide_template.md` 模板，生成 `reading_guide.md`。

**要求：**

1. **第一遍速读（15-20分钟）**
   - 具体标注读哪些章节段落（§标注）+ 重点图表
   - 自检 QA 3-4题（附答案）
   - **末尾"本遍总结与关键发现"**

2. **第二遍通读（45-60分钟）**
   - 逐章阅读指引 + 概念解释
   - 自检 QA 4-5题（附答案）
   - **末尾"本遍总结与关键发现"**

3. **第三遍精读（60-90分钟）**
   - 数学推导/算法深入 + 复现细节
   - 深度思考问题
   - 自检 QA 3-4题（附答案）
   - **末尾"本遍总结与关键发现"**

### Step 2: 生成研究报告

参照 `templates/report_template.md` 模板，生成 `report.md`。

- 内容必须来自论文实际内容
- 实验结果优先用表格
- 1500-3000 字

---

## Phase 4: 质量抽检

> 所有产出完成后，进行抽样检查确保质量。**不需要逐行全扫描**，挑选代表性片段即可。

### 抽检项目

#### 1. Markdown 转换质量
- 随机抽取 2-3 段原文，与 `full.md` 对比：
  - 文字是否有 OCR 乱码
  - 图片引用是否正确
  - 表格结构是否完整

#### 2. 翻译完整性
- 对比 `full.md` 和 `full_cn.md` 的章节结构（标题数量是否一致）
- 随机抽取 3 个不同章节的段落，检查是否有漏翻或明显缩减
- 验证图片引用路径是否正确指向 `../markdown/images/`

#### 3. 阅读指南 + 报告
- 检查章节号引用是否与论文实际结构一致
- 每遍阅读是否都有"总结与关键发现"
- QA 的答案是否来自论文内容

### 执行抽检

```bash
# ⚠️ 同上：路径按文首「本平台的适配说明」第 4 条换成技能目录。
python .agents/skills/paper-reading/scripts/quality_check.py <output_dir>
```

脚本自动执行以下检查并输出报告：
1. **文件完整性**：4 个产出文件是否存在
2. **章节结构**：对比原文/翻译标题数量、检测缺失章节号
3. **图片引用**：数量对比、路径格式、文件存在性
4. **段落数量**：抽检 3 个章节的段落数（原文 vs 翻译），容差阈值 70%
5. **阅读指南结构**：三遍阅读 + QA + 总结是否完整
6. **研究报告结构**：背景/贡献/实验/评价章节是否存在

如发现问题，修复后重新运行脚本直到全部通过。

---

## Resuming Interrupted Work

如果流程中断，下次用户提到同一论文时：
1. 检查 `paper_reading/` 下已有目录
2. 读取 `progress.json` 确定断点
3. 从中断处继续

## Error Handling

- **PDF 不存在**：提示检查路径
- **API Key 缺失**：提示配置 `api_key/key.txt`
- **MinerU API 失败**：建议用桌面客户端手动转换
- **翻译中断**：progress.json 记录断点，下次自动续接

## Security

- `api_key/key.txt` 中的 Token **绝不**暴露到代码、日志、对话中
- `api_key/` 目录已被 `.gitignore` 排除

## Example Usage

```
用户：/paper-reading docs/AIOpsLab.pdf
用户：帮我阅读这篇论文 docs/attention_is_all_you_need.pdf
用户：continue       （继续翻译 / 下一阶段）
用户：继续翻译 gfs   （恢复中断的翻译）
```
