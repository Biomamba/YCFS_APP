---
name: Excalidraw 示意图生成
summary: 程序化生成 .excalidraw 流程/架构/实验设计图，含字段规范、布局规则与自检脚本
tags: 示意图,Excalidraw,流程图,架构图,科研绘图
repo: coleam00/excalidraw-diagram-skill
license: 未标注
---

# Excalidraw 示意图生成

## 什么时候用

用户要**示意图**——实验设计、分析流程、系统架构、决策路径、概念结构——而且要**能再编辑、
能贴进 PPT 或论文**时用它。产物是 `.excalidraw`（一份 JSON），拖进 excalidraw.com 或
编辑器的 Excalidraw 插件就能继续改。火山图、PCA、热图这类**由数据画出来的图**不归它管。

两条判据：**同构检验**——文字全抹掉后，只看形状和连线还能看出概念间的关系吗？看不出就
重画。**教学检验**——看完能学到具体的东西吗，还是只有一堆写着名词的方框？好的图给真实的
名字（工具名、文件名、参数值），不给"输入 → 处理 → 输出"这种空壳。

## 先定深度

| | 概念图 | 技术图 |
|---|---|---|
| 用在 | 讲思路、讲心智模型 | 讲一套真实跑的系统 / 流程 |
| 元素 | 抽象形状 + 标签 | 具体例子 + 真实命名 |
| 例 | "先质控再定量"两个方块 | `fastp --qualified_quality_phred 20` |

技术图**必须**放证据件：真实命令、数据/文件片段写进深色矩形（代码用高亮色、数据用绿字）；
步骤序列画成时间轴（线 + 小圆点 + 自由文字）；真实输入（`ctrl_1..3 / treat_1..3` 这样的
分组表）和输出样子（嵌套矩形模拟表格）直接画出来。原则：**画"它长什么样"，不要只画
"它叫什么"**。

## 设计流程（写 JSON 之前全部做完）

1. **读懂概念**：问"它**做**什么"而不是"它**是**什么"，找出核心转换——什么变成了什么、
   在哪一步变、谁触发谁。
2. **概念映射到图形模式**——形状要长得像它代表的行为：

| 概念的性质 | 模式 | 画法 |
|---|---|---|
| 一对多（源头、根因） | 扇出 | 中心元素 + 多条箭头放射 |
| 多对一（汇总、合并） | 汇聚 | 多个箭头汇到一个输出 |
| 有层级 / 嵌套 | 树 | 竖线 + 横枝 + 自由文字，**不要方框** |
| 有先后顺序 | 时间轴 | 一条线 + 10~20px 小圆点 + 旁边自由文字 |
| 循环 / 迭代 | 环 | 首尾相连的箭头回到起点 |
| 抽象状态、上下文 | 云 | 大小不一、部分重叠的椭圆 |
| 输入 → 变换 → 输出 | 流水线 | 前 / 中 / 后三段，前后形状不同 |
| 两者对比 | 并排 | 两条平行结构，中间留空隙 |
| 阶段分隔 | 断口 | 大留白或虚线把区域切开 |

3. **保证多样性 + 视线顺序**：每个主要概念换一种模式（全篇等大的圆角矩形排成网格 =
   失败）；流向左→右或上→下最稳，只有 hub-and-spoke 才用放射。
4. **容器纪律**（下节）。5. **再写 JSON**（大图分节写）。6. **自检 / 回看**（强制）。

分析场景怎么套：**流程图** = 横向流水线，框里写真实工具名和关键参数，分支用 `diamond`，
并行两条路并排；**实验设计图** = 分组用并排分区（断口或虚线隔开）、时间点用时间轴、
生物学重复用小圆点而不是方框；**架构图** = 虚线分隔线 + 自由标题画出"区"，区内再扇出/
汇聚；**决策图** = `diamond` 分叉，出口用不同语义色。

## 容器纪律：默认不加框

默认用自由文字；只有**这一节的视觉焦点、要和其他元素成一组、有箭头要连到它、形状本身
有含义（菱形=判定）**这几种情况才加容器。**容器检验**：对每个方框问"换成自由文字还行
不行？"行就删掉框；24px 的标题不需要外面再套一个矩形。目标：**带框的文字元素不超过全部
文字元素的 30%**。

| 概念 | 形状 |
|---|---|
| 标签 / 说明 / 细节 | 不加形状（排版本身就是层级） |
| 时间轴节点 | 小椭圆（10~20px），是锚点不是容器 |
| 起点 / 输入 / 触发、终点 / 输出 / 结果 | `ellipse` |
| 判定 / 条件 | `diamond` |
| 处理 / 动作 / 步骤 | `rectangle` |
| 抽象状态 / 上下文 | 大小不一、重叠的 `ellipse` |
| 层级节点 | 线 + 文字，无框 |

**尺寸档位**：主角 300×150（全图只该有一个）；一级 180×90（主干步骤）；二级 120×60
（分支）；小 60×40（附属块）；标记点 10~20px 椭圆（时间轴 / 列表）。**留白就是重要性**：
最重要的元素周围留 200px 以上空白。**连线是必须的**：位置挨着不等于有关系，A 和 B 真有
关系就必须画出箭头或线。

## 颜色只承担语义

每个语义角色固定一对"深描边 + 浅填充"。**不要自己发明颜色**，不属于任何语义的归到
主/中性。

| 语义 | 填充 / 描边 | | 语义 | 填充 / 描边 |
|---|---|---|---|---|
| 主 / 中性 | `#3b82f6` / `#1e3a5f` | | 判定 | `#fef3c7` / `#b45309` |
| 次 | `#60a5fa` / `#1e3a5f` | | 模型 / 算法 | `#ddd6fe` / `#6d28d9` |
| 再次 | `#93c5fd` / `#1e3a5f` | | 未启用（配虚线） | `#dbeafe` / `#1e40af` |
| 起点 / 触发 | `#fed7aa` / `#c2410c` | | 警告 / 重置 | `#fee2e2` / `#dc2626` |
| 终点 / 成功 | `#a7f3d0` / `#047857` | | 错误 | `#fecaca` / `#b91c1c` |

**文字**（做层级，不靠加框）：标题 `#1e40af`、副标题 `#3b82f6`、正文/细节 `#64748b`、
浅底上的字 `#374151`、深底上的字 `#ffffff`。**证据件**统一深底 `#1e293b`。**线**：箭头
颜色跟着**起点元素**的语义色，结构线用 `#1e3a5f` 或 `#64748b`，小圆点填充 `#3b82f6`。
画布背景 `#ffffff`，`opacity` 一律 `100`。

**其它默认值**：`fontFamily: 3`（等宽，全图统一；渲染中文靠字体回退，**能写英文标签就写
英文**，混排时宽度按下面的估算给足）；`fontSize` 16（正文）/ 20~28（标题），小于 14 导出后
看不清；`lineHeight: 1.25`；`roughness: 0`（`1` 只在要手绘草稿感时用）；`strokeWidth`
1=分隔线/树/时间轴、2=常规形状与箭头、3=只给主通路强调；虚线只用于"未启用""规划中"；
`rectangle` 加 `"roundness": {"type": 3}`。

## `.excalidraw` 文件结构

顶层五个键一个都不能少（见下面的完整示例）：`type` 必须是 `"excalidraw"`、`version: 2`、
`source`（"谁写的"标记，**不需要联网**）、`elements`（不能为空）、`appState`（画布背景）
与 `files`（嵌图片用，不嵌留 `{}`）。

**公共字段**

| 字段 | 说明 |
|---|---|
| `id` / `type` | 全局唯一、用可读名（`filt_rect`、`arrow_filt_deseq`）｜`rectangle` / `ellipse` / `diamond` / `arrow` / `line` / `text` |
| `x`, `y` | 未旋转时的**左上角**坐标（像素） |
| `width`, `height` | 尺寸；对 arrow/line 来说是 `points` 的包围盒 |
| `strokeColor` / `backgroundColor` | 描边色 / 填充色（或 `"transparent"`） |
| `fillStyle` / `strokeWidth` / `strokeStyle` | `"solid"` ｜ 1/2/4 ｜ `"solid"` / `"dashed"` / `"dotted"` |
| `roughness` / `opacity` | 0~2 ｜ 0~100（固定 100） |
| `seed` / `versionNonce` | 随机整数，同图内**不要重复**，分节时按节段错开 |
| `angle` / `version` / `isDeleted` | 弧度（通常 0）｜新建写 1｜删元素标 `true`，别从数组里抠掉 |
| `groupIds` / `boundElements` | 同组共用一个字符串 id ｜ 谁绑在我身上：`[{id, type}]` |
| `link` / `locked` | 一般是 `null` / `false` |

**坐标与 z-order**：`x, y` 是左上角，文本元素同理。`arrow`/`line` 的 `points` 是**相对
自身 `x, y`** 的偏移数组（`[[0,0],[80,0]]` = 向右 80px 的水平线），`x, y` 就是第一个点的
绝对位置；曲线用 3 个以上的点；`width`/`height` 要等于这些点的包围盒。**绘制顺序 = 数组
顺序，后面的盖在前面上**，顺序固定为：分区底板 → 形状 → 文字 → **箭头最后**。

**文本元素**独有 `text` / `originalText`（两者一致，**只放能读的文字**，不要 HTML 或转义
符）、`fontSize`、`fontFamily: 3`、`lineHeight: 1.25`、`textAlign`、`verticalAlign`、
`containerId`。`containerId` 为 `null` 是自由文字，写在形状里时填形状 id 并配
`textAlign: "center"` + `verticalAlign: "middle"`。宽度估算（写任何文本前先算，宁可给宽）：
**等宽字体下 ASCII ≈ 0.6 × fontSize/字符，中文/全角 ≈ 1.0 × fontSize/字符**，再加 12px
余量；宽度不够的表现就是文字溢出框外或和邻居叠在一起。

**箭头元素**独有 `points`（相对自身 x,y 的偏移）、`startBinding` / `endBinding`、
`startArrowhead` / `endArrowhead`（`null` / `"arrow"` / `"bar"` / `"dot"` / `"triangle"`）。
`focus` 是箭头接在形状边的哪个位置（0 = 正中），`gap` 是端点与形状边的间隙（2~4px，
给 0 会贴住框线）。

**绑定是双向的（最容易错）**：一条箭头要真正粘在两个形状上，**三处都要写**——① 箭头
自己的 `startBinding.elementId` / `endBinding.elementId`；② **起点形状**的
`boundElements` 里要有 `{"id": "<箭头id>", "type": "arrow"}`；③ **终点形状**里也要有
同一条。形状里的文字同理，**两处都要写**：文字元素的 `containerId` = 形状 id，且形状的
`boundElements` 里有 `{"id": "<文字id>", "type": "text"}`。

只写一半的后果：JSON 里看着连上了，但一拖动就散架、不跟随、不重新走线，文字也不居中
不换行。**要一起选中/移动的一批元素**给它们的 `groupIds` 填同一个字符串；`frame` 是画布
上的"画板"，元素归属还得写额外字段，除非确实要分画板，否则用 `groupIds` 或留白+虚线分区。

## 最小可用示例

```json
{
  "type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
  "appState": { "viewBackgroundColor": "#ffffff", "gridSize": 20 }, "files": {},
  "elements": [
    { "type": "rectangle", "id": "filt", "x": 360, "y": 120, "width": 200, "height": 90,
      "strokeColor": "#1e3a5f", "backgroundColor": "#3b82f6", "strokeWidth": 2,
      "roughness": 0, "roundness": { "type": 3 },
      "boundElements": [{ "id": "filt_t", "type": "text" }, { "id": "a1", "type": "arrow" }] },
    { "type": "text", "id": "filt_t", "x": 370, "y": 155, "width": 180, "height": 20,
      "text": "过滤低表达基因", "originalText": "过滤低表达基因",
      "fontSize": 16, "fontFamily": 3, "lineHeight": 1.25,
      "textAlign": "center", "verticalAlign": "middle",
      "strokeColor": "#374151", "containerId": "filt" },
    { "type": "rectangle", "id": "deseq", "x": 640, "y": 120, "width": 220, "height": 90,
      "strokeColor": "#047857", "backgroundColor": "#a7f3d0", "strokeWidth": 2,
      "roughness": 0, "roundness": { "type": 3 },
      "boundElements": [{ "id": "a1", "type": "arrow" }] },
    { "type": "arrow", "id": "a1", "x": 560, "y": 165, "width": 80, "height": 0,
      "strokeColor": "#1e3a5f", "strokeWidth": 2, "points": [[0, 0], [80, 0]],
      "startBinding": { "elementId": "filt", "focus": 0, "gap": 4 },
      "endBinding": { "elementId": "deseq", "focus": 0, "gap": 4 },
      "startArrowhead": null, "endArrowhead": "arrow" }
  ]
}
```

`deseq` 想有自己的字，照 `filt` + `filt_t` 再补一对。生成它的 Python 片段（**写成函数**，
元素一多就不会四处硬编码坐标）：

```python
import json
LH, ELS = 1.25, []
def est_w(s, fs):                       # ASCII 0.6em / 全角 1.0em
    return int(sum(fs * (1.0 if ord(c) > 0x2E80 else 0.6) for c in s))

def rect(i, x, y, w, h, label, stroke, fill, fs=16):
    t = i + "_t"
    ELS.append({"type": "rectangle", "id": i, "x": x, "y": y, "width": w, "height": h,
                "strokeColor": stroke, "backgroundColor": fill, "strokeWidth": 2,
                "roughness": 0, "roundness": {"type": 3},
                "boundElements": [{"id": t, "type": "text"}]})
    ELS.append({"type": "text", "id": t, "x": x + 10, "y": y + h / 2 - fs * LH / 2,
                "width": w - 20, "height": fs * LH, "text": label, "originalText": label,
                "fontSize": fs, "fontFamily": 3, "lineHeight": LH, "containerId": i,
                "textAlign": "center", "verticalAlign": "middle", "strokeColor": "#374151"})

def arrow(i, x, y, dx, dy, src, dst):
    ELS.append({"type": "arrow", "id": i, "x": x, "y": y, "width": abs(dx), "height": abs(dy),
                "strokeColor": "#1e3a5f", "strokeWidth": 2, "points": [[0, 0], [dx, dy]],
                "startBinding": {"elementId": src, "focus": 0, "gap": 4},
                "endBinding": {"elementId": dst, "focus": 0, "gap": 4},
                "startArrowhead": None, "endArrowhead": "arrow"})
    for e in ELS:                        # 反向绑定必须同一轮补上
        if e["id"] in (src, dst):
            e["boundElements"].append({"id": i, "type": "arrow"})

rect("in", 80, 120, 200, 90, "原始 count 矩阵", "#c2410c", "#fed7aa")
rect("filt", 360, 120, 200, 90, "过滤低表达基因", "#1e3a5f", "#3b82f6")
arrow("a1", 280, 165, 80, 0, "in", "filt")            # x = in.x + in.width
json.dump({"type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
           "elements": ELS, "appState": {"viewBackgroundColor": "#ffffff"}, "files": {}},
          open("flow.excalidraw", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
```

R 版走 `jsonlite`，三个要点：`toJSON(..., auto_unbox = TRUE, na = "null", digits = NA)`
（NULL 字段会被直接丢掉，要显式写 `null` 就传 `NA`）；元素一个个 `list(...)` 构造好再
拼接，**不要用 `c()` 去合带名字的 list**——`c()` 会把元素的字段摊平成一堆散元素。

## 常见坑

| 现象 | 原因 | 怎么避免 |
|---|---|---|
| 拖一个形状，箭头不跟、不走线 | 只写了箭头侧的 binding，形状的 `boundElements` 里没有它 | 建箭头时同一轮把两端形状补上（上面的 `arrow()` 就这么做） |
| 框里的字不居中、不换行、跑到框外 | 只写了 `containerId`，形状里没有这条文字 | 两个方向都写，配 `textAlign/verticalAlign` |
| 中文或长字符串溢出、和邻居叠在一起 | 按"字符数 × 0.6em"算宽度，中文实际接近 1em | 用 `est_w()` 估算，框内文字额外留 20px 内边距，算完跑自检 |
| 文字被底板盖住 / 箭头看不见 | 数组顺序错了 | 顺序固定：底板 → 形状 → 文字 → 箭头最后 |
| 打开报错或元素消失 | `id` 重复，或 `boundElements`/`containerId` 指向不存在的 id | id 用可读名加节前缀，改完跑自检 |
| 方块莫名叠在一起 | 只估了左上角、没算尺寸 | 坐标写具名变量（`ROW1 = 120`），别内联数字 |
| JSON 被截断，或坐标错了难定位 | 想一次输出整张大图；坐标内联在长数组里 | 分节写入、每次补跨节绑定；坐标用具名变量，元素少于 ~30 个直接手写 |

## 大图策略（超过一屏）

**不要一次生成整张图**：① 先建骨架（顶层五键 + 第一节元素）；② **一次一节**，每节单独
一次编辑，专心排布局和留白；③ id 带节前缀（`s1_trigger`、`s3_merge`），`seed`/
`versionNonce` 按节段错开（第 1 节 100xxx、第 2 节 200xxx）；④ 加跨节箭头时**同一轮**就把
两端形状的 `boundElements` 改好；⑤ 收尾通读：跨节箭头两端都绑上了吗、间距是否一边挤一边
空、引用到的 id 都存在吗。

## 验证

**只看 JSON 判断不了图好坏**，生成完必须验证，通常要修 2~4 轮。有浏览器时导出 PNG
**亲眼看**，逐条对：文字被裁或溢出容器、文字与形状重叠、箭头横穿别的元素、箭头落到错的
元素或空白处、标签悬空、间距不匀、这块太空那块太挤、字太小、构图歪。
没有浏览器/外网时用**几何自检**兜住机械性错误：

```python
import json, sys, itertools
def est_w(s, fs): return sum(fs * (1.0 if ord(c) > 0x2E80 else 0.6) for c in s)
def box(e):
    if e["type"] in ("arrow", "line"):
        xs = [e["x"] + p[0] for p in e["points"]]; ys = [e["y"] + p[1] for p in e["points"]]
        return min(xs), min(ys), max(xs), max(ys)
    return e["x"], e["y"], e["x"] + e["width"], e["y"] + e["height"]

d = json.load(open(sys.argv[1], encoding="utf-8"))
els = {e["id"]: e for e in d["elements"] if not e.get("isDeleted")}
bad = []
if d.get("type") != "excalidraw" or not d.get("elements"): bad.append("顶层结构不对")
if len(els) != len(d["elements"]): bad.append("存在重复 id")
for e in els.values():
    if e["type"] == "text":
        if est_w(e["text"], e["fontSize"]) + 12 > e["width"] + 1:
            bad.append("文本 %s 估算宽度超过声明宽度，会溢出" % e["id"])
        c = els.get(e.get("containerId"))
        if c and not any(b["id"] == e["id"] for b in c.get("boundElements") or []):
            bad.append("文本 %s 挂了容器但容器里没有它" % e["id"])
        elif c and est_w(e["text"], e["fontSize"]) > c["width"] - 20:
            bad.append("文本 %s 在容器 %s 里放不下" % (e["id"], c["id"]))
    if e["type"] == "arrow":
        for k in ("startBinding", "endBinding"):
            b = e.get(k) or {}; t = els.get(b.get("elementId"))
            if not t or not any(x["id"] == e["id"] for x in t.get("boundElements") or []):
                bad.append("箭头 %s 的 %s 没有双向绑上" % (e["id"], k))
shapes = [e for e in els.values() if e["type"] in ("rectangle", "ellipse", "diamond")]
for a, b in itertools.combinations(shapes, 2):
    x1, y1, x2, y2 = box(a); u1, v1, u2, v2 = box(b)
    if x1 < u2 and u1 < x2 and y1 < v2 and v1 < y2:
        bad.append("%s 与 %s 范围重叠" % (a["id"], b["id"]))
for e in [x for x in els.values() if x["type"] == "arrow"]:
    pts = [(e["x"] + p[0], e["y"] + p[1]) for p in e["points"]]
    skip = {(e.get("startBinding") or {}).get("elementId"),
            (e.get("endBinding") or {}).get("elementId")}
    for s in shapes:                     # 箭头有没有从别人身上穿过去
        if s["id"] in skip: continue
        x1, y1, x2, y2 = box(s)
        if any(x1 < a[0] + (b[0]-a[0])*k/20 < x2 and y1 < a[1] + (b[1]-a[1])*k/20 < y2
               for a, b in zip(pts, pts[1:]) for k in range(21)):
            bad.append("箭头 %s 穿过 %s" % (e["id"], s["id"]))
print("\n".join("✗ " + m for m in bad) if bad else "✓ 绑定双向、文本不溢出、无重叠、箭头不穿框")
```

自检通过**不等于图就好了**——构图、层级、留白还得靠人眼，能给用户看图时先自己导出 PNG
看一眼再交付。

## 交付物清单

1. `<名字>.excalidraw`：UTF-8 无 BOM 的 JSON，能被 `json.load` / `JSON.parse` 直接解析。
2. `<名字>.png`：能导出就导一份预览（宽度别太小，正文 16px 要看得清），方便贴幻灯片。
3. 回答里说明：图在讲什么、哪几块是主干、哪些数字/文件名是**示例值**，以及自检结果。

## 质量清单

交付前逐条过：技术图有证据件、有"概览 + 分区 + 细节"三层；形状排布同构、主要概念各用
一种模式、没退化成卡片网格；带框元素换成自由文字还行不行、树/时间轴用"线 + 自由文字"、
带框文字占比 < 30%；每条关系都有箭头、重要元素更大更空；`text` 只有可读文字、
`fontFamily: 3`、`roughness: 0`、`opacity: 100`、引用的 id 都存在；跑过自检或渲染回看，
文字没溢出、元素没重叠、间距一致、箭头连对目标、导出尺寸下看得清。

## 来源与许可

本技能改写自 coleam00/excalidraw-diagram-skill（未标注）。原仓库未标注许可证，本条为
方法概述而非原文转载；文中配色值、字段名等为使用该文件格式所必需的技术信息。
