# 📖 Paper-Reading Skill

一站式论文阅读辅助工具，适用于 [Gemini Code Assist / Antigravity](https://cloud.google.com/products/gemini/code-assist) 的 `.agents/skills/` 系统。

## Features

| Phase | 功能 | 产出 |
|-------|------|------|
| 1 | PDF → Markdown（MinerU API） | `markdown/full.md` + `images/` |
| 2 | 全文中文翻译 | `translated/full_cn.md` |
| 3 | 三遍阅读法指南 + 研究报告 | `reading_guide.md` + `report.md` |
| 4 | 质量抽检 | 自动化检查报告 |

## Quick Install

### 方式一：一键安装（推荐）

```powershell
# 在目标工作区根目录运行
git clone https://github.com/<your-username>/paper-reading-skill.git .agents/skills/paper-reading
cd .agents/skills/paper-reading
.\install.ps1 -WorkspaceRoot (Resolve-Path ..\..\..\..)
```

### 方式二：手动安装

```powershell
# 1. Clone 到工作区的 .agents/skills/ 下
git clone <repo-url> <workspace>/.agents/skills/paper-reading

# 2. 配置 MinerU API Token
echo "your-token-here" > <workspace>/.agents/skills/paper-reading/api_key/key.txt
```

## 配置

### MinerU API Token

获取 Token：前往 [MinerU](https://mineru.net/) 注册并获取 API Token。

配置方式（二选一）：

```powershell
# 方式 A：环境变量（推荐，跨工作区共享）
$env:MINERU_API_TOKEN = "your-token-here"
# 持久化到 profile:
# Add-Content $PROFILE 'Set-Item -Path Env:MINERU_API_TOKEN -Value "your-token-here"'

# 方式 B：写入文件（每个工作区独立）
echo "your-token-here" > .agents/skills/paper-reading/api_key/key.txt
```

> ⚠️ `api_key/` 目录已在 `.gitignore` 中，Token **绝不会**被提交到 git。

## Usage

在 Gemini/Antigravity 对话中：

```
/paper-reading docs/my_paper.pdf
帮我阅读这篇论文 papers/attention.pdf
continue    # 继续下一阶段
```

## Requirements

- Python 3.x
- `requests` 库（`pip install requests`）
- MinerU API Token

## 目录结构

```
paper-reading/
├── SKILL.md                # Agent 技能定义（触发条件 + 流程）
├── README.md               # 本文件
├── install.ps1             # 安装脚本
├── .gitignore              # 排除 api_key/
├── api_key/
│   └── key.txt             # MinerU Token（不入库）
├── scripts/
│   ├── mineru_convert.py   # PDF → Markdown 转换
│   └── quality_check.py    # 质量抽检
└── templates/
    ├── reading_guide_template.md
    └── report_template.md
```

## License

MIT
