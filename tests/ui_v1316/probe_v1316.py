# -*- coding: utf-8 -*-
"""V13.16 的浏览器验收：item 27 / 28。

两条都属于"自检全绿、界面上还是不对"的那一类：

  · **item 28**（技能页整页渲染崩）
      自检能证明 `meta` 是 list、能证明每条内置技能都取得到 `repo`。
      它证明不了**技能页真的画出来了** —— 崩的是一个 renderUI，出错时
      Shiny 把那一块整个换成一句报错文本，而句子的内容是**线上
      sanitize_errors 换过之后的英文**（本地实例上则是 R 的原文
      "subscript out of bounds"）。两种都不是"少了一行"，是"一条都没有"。
      所以这里真开一次技能页，数技能行、看那两条没有 repo 的技能在不在。

  · **item 27**（文献速递的产出是"文献阅读汇报"，不是检索过程的画外音）
      提示词改了没有、五节的顺序对不对，自检在 R 里就能验。但**用户看到的
      是页面上那句说明和「看看会发什么」弹出来的预览** —— 说明没写、预览
      没接上提示词，自检照样全绿。所以这里真填关键词、真点那颗按钮、
      真读 `.dsapp-lit-preview` 里的字。

跑法见 tests/ui_v1316/README.md。退出码 0 = 全绿。
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C
from playwright.sync_api import sync_playwright

Ck = C.Chk()
OUT = C.OUT

# 线上 sanitize_errors 打开时，用户看到的就是这一句。断它，就是断
# "用户报的那个症状还在不在" —— 光断 "subscript out of bounds" 的话，
# 线上那种表现（被换过文本的）反而漏掉了。
SANITIZED = "An error has occurred"


def shot(pg, name):
    try:
        pg.screenshot(path=os.path.join(OUT, name))
    except Exception:
        pass


def wait_for(pg, sel, ms=20000):
    """等元素出现，**超时不抛异常**，只回 False。

    ⚠️ `pg.wait_for_selector()` 超时抛的是 playwright 的 TimeoutError，
       脚本当场结束 —— **后面那一段根本跑不到**。V13.15 变异验证时踩到过：
       输出停在半路，看着像"后面几条也坏了"，其实只是没跑到。
    """
    try:
        pg.wait_for_selector(sel, timeout=ms)
        return True
    except Exception:
        return False


def body_text(pg):
    try:
        return pg.inner_text("body")
    except Exception:
        return ""


def vis(pg, sel):
    """元素在不在、且真的可见（宽度 > 0）。"""
    try:
        n = pg.locator(sel).count()
        if n == 0:
            return False
        bb = pg.locator(sel).first.bounding_box()
        return bool(bb) and bb["width"] > 0 and bb["height"] > 0
    except Exception:
        return False


def _find_row(pg, name):
    """按技能名找到那一行（找不到返回 None）。"""
    rows = pg.locator(".dsapp-skill-row")
    for i in range(rows.count()):
        r = rows.nth(i)
        try:
            if r.locator(".dsapp-skill-name").first.inner_text().strip() == name:
                return r
        except Exception:
            continue
    return None


def row_tree(pg, name):
    """读某一条技能展开后的**配套文件树**文本（找不到返回 ""）。

    ⚠️ 不能写成 `pg.locator(".dsapp-skill-tree").first` —— 展开过的行**不会
    自动合上**，前面 item 28 展开过的 academic-search 那一棵树还在 DOM 里
    而且排在前面，`.first` 拿到的是**它的**文件树。第一版就是这么错的：
    报的是「文件树里没有 scripts/」，打出来的却是 academic-search 的
    references/ 目录 —— 看着像"paper-reading 的配套文件没收进来"。
    量之前先确认量的是哪一行。
    """
    r = _find_row(pg, name)
    if r is None:
        return ""
    try:
        return r.locator(".dsapp-skill-tree").first.inner_text()
    except Exception:
        return ""


def expand_src(pg, name):
    """展开某一条技能，读它「来源」那一行的值；找不到那条返回 None。

    ⚠️ **必须先展开**。技能行是一个 `<details>`（"文件夹"形态本身），
    「来源」那一行在 `.dsapp-skill-files` 里，**收起时整个不在可见文本里**——
    第一版探针就是直接在**收起**的行文本里找 " · "，结果 18 行一条都找
    不到，报的是「老的那批仍然显示「仓库 · 许可」只有 0 行带来源」，
    看着像"修 item 28 把来源信息弄丢了"，其实只是没点开。
    （和 V13.15 记的"隐藏元素的矩形是全 0"是同一类：量之前先确认它看得见。）
    """
    rows = pg.locator(".dsapp-skill-row")
    for i in range(rows.count()):
        r = rows.nth(i)
        try:
            nm = r.locator(".dsapp-skill-name").first.inner_text().strip()
        except Exception:
            continue
        if nm != name:
            continue
        try:
            if not r.locator("details.dsapp-skillgroup").first.get_attribute("open"):
                r.locator("summary.dsapp-skill-head").first.click()
                pg.wait_for_timeout(600)
            k = r.locator(".dsapp-skill-file-k")
            v = r.locator(".dsapp-skill-file-v")
            for j in range(k.count()):
                if k.nth(j).inner_text().strip() == "来源":
                    return v.nth(j).inner_text().strip()
        except Exception:
            return ""
        return ""
    return None


with sync_playwright() as pw:
    b = pw.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    # 页面上任何一处抛 JS 异常都记下来 —— item 28 崩溃时客户端也会报一条
    jserr = []
    pg.on("pageerror", lambda e: jserr.append(str(e)))

    C.enter_app(pg)
    C.seed_or_die(C.EMAIL)

    # =========================================================================
    print("\n== V13.16 item 28：技能页画得出来（不是一句英文报错）==", flush=True)
    # =========================================================================
    C.goto(pg, "skills", wait=4000)
    if not wait_for(pg, ".dsapp-skill-row", 30000):
        print("  ⚠️ 一条技能行都没有 —— 下面几条会直接判红", flush=True)
    pg.wait_for_timeout(1000)

    txt = body_text(pg)
    shot(pg, "28_skills.png")

    Ck("★★★ 页面上没有那句英文报错（线上 sanitize 之后就是这一句）",
       SANITIZED not in txt)
    Ck("★★★ 页面上也没有 R 的原文报错（本地实例不 sanitize，露的是它）",
       "subscript out of bounds" not in txt)
    Ck("★★★ 也没有应用自己的兜底卡片（说明不是「换了个样子的坏」）",
       pg.locator(".dsapp-err-card").count() == 0 and
       pg.locator(".dsapp-err-page").count() == 0)
    Ck("★ 这一趟没有 JS 异常", len(jserr) == 0, jserr[:2])

    # ★★ 核心：列表真的有内容。原来崩的时候这一块是**空的**（整个 output
    #    被换成报错文本），所以"行数够不够"才是用户看到的那件事。
    rows = pg.locator(".dsapp-skill-row").count()
    nrows = pg.locator(".dsapp-skill-row").all_inner_texts()
    joined = "\n".join(nrows)
    Ck("★★★ 技能列表真的画出来了（≥ 12 行）", rows >= 12, "只有 %d 行" % rows)

    # ★★ 踩坑的那两条必须都在。它们正是"frontmatter 少写 key"的现场。
    Ck("★★★ academic-search 在列表里",
       "academic-search" in joined)
    Ck("★★★ deeppapernote 在列表里",
       "deeppapernote" in joined)

    # ★★ 它们那一行的「来源」不能是空白、更不能崩 —— 应该是「内置」
    #    （没有 repo/license 时的兜底）。
    two = [t for t in nrows
           if "academic-search" in t or "deeppapernote" in t]
    Ck("★★ 那两条带的是「内置」徽章（不是公共 / 自建）",
       len(two) == 2 and all("内置" in t for t in two), two)

    # ★★ 展开看它们那一行的「来源」—— 这正是原来抛错的地方。
    #    没有 repo/license 时应该落到兜底的「内置」两个字。
    s_as = expand_src(pg, "academic-search")
    s_dp = expand_src(pg, "deeppapernote")
    Ck("★★★ 展开后「来源」是「内置」——不是空白、不是报错、也没有多余的 ·",
       s_as == "内置" and s_dp == "内置", [s_as, s_dp])
    shot(pg, "28_skills_expanded.png")

    # ★★ 反向：修法不是"把 meta 清空"。老的那 12 条**仍然**要显示
    #    「仓库 · 许可」—— 清空的话上面全绿、这里全红。
    s_ar = expand_src(pg, "学术论文写作与同行评审")
    s_nd = expand_src(pg, "Nature 系投稿级科研出图规范")
    Ck("★★★ 有 repo 的那几条「来源」还在（不是把所有来源都清掉了）",
       s_ar is not None and "Imbad0202/academic-research-skills" in s_ar and
       "CC-BY-NC-4.0" in s_ar,
       s_ar)
    Ck("★★ 另一条也核对一遍（一条可能是巧合）",
       s_nd is not None and "Yuan1z0825/nature-skills" in s_nd, s_nd)

    # =========================================================================
    print("\n== V13.16 item 29：paper-reading 这条内置技能 ==  ", flush=True)
    # =========================================================================
    # 自检能证明它在盘上、配套文件都在。证明不了**它被种进库、并在列表里
    # 画出来了** —— seed 走的是 (user_id IS NULL, name)，认错了名字的话
    # 界面上就是没有那一条，而不报错。
    Ck("★★★ paper-reading 出现在技能列表里", "paper-reading" in joined)

    s_pr = expand_src(pg, "paper-reading")
    Ck("★★★ 展开后看得到它的文件树（4 个阶段、配套脚本都在里面）",
       s_pr is not None and "huicod/paper-reading-skill" in s_pr, s_pr)
    tree = row_tree(pg, "paper-reading")
    Ck("★★ 文件树里有 scripts/ 和 templates/（正文照着相对路径引用它们）",
       ("mineru_convert.py" in tree) and ("quality_check.py" in tree) and
       ("reading_guide_template.md" in tree) and
       ("report_template.md" in tree),
       tree[:200].replace("\n", " | "))
    # 反向：Token 绝不能跟着技能走。上游把 Token 放在 api_key/key.txt，
    # 收进来就等于把"往共享目录里写密钥"当成了正常做法。
    Ck("★★★ 文件树里没有 api_key / key.txt",
       ("api_key" not in tree) and ("key.txt" not in tree))
    shot(pg, "29_skills_paper_reading.png")

    # =========================================================================
    print("\n== V13.16 item 30：关于技能的新介绍 ==", flush=True)
    # =========================================================================
    Ck("★★★ 新介绍在页面上（AI Agent 体系里，Skill 是什么）",
       "在 AI Agent 体系里" in txt and "独立能力单元" in txt)
    Ck("★★★ 三条「可以和 AI 约定」的例子都在页面上",
       ("300 dpi" in txt) and ("不可由 AI 生成" in txt) and
       ("避免 AI 幻觉" in txt))
    Ck("★★★ 「本平台支持自定义技能并上传」在",
       "自定义技能并上传" in txt)
    Ck("★★★ 老的开头没了（「写给 AI 看的一段要求」）",
       "写给 AI 看的一段要求" not in txt)
    # ★★ 反向的另一半：操作说明一条都不能少。用户说的是换**介绍**，
    #    这几条是这一页的操作说明，删了用户就不知道技能是按对话挂载的。
    Ck("★★★ 操作说明原样留着：按对话挂载 / 两个池 / 另存为我的",
       ("按对话挂载" in txt) and ("公共技能库" in txt) and
       ("另存为我的" in txt))

    # =========================================================================
    print("\n== V13.16 item 27：文献速递的产出是「文献阅读汇报」==", flush=True)
    # =========================================================================
    C.goto(pg, "lit", wait=3500)
    if not wait_for(pg, "#lit-kw", 30000):
        print("  ⚠️ 文献速递页没渲染出来，下面几条会直接判红", flush=True)
    pg.wait_for_timeout(800)

    lit_txt = body_text(pg)
    shot(pg, "27_lit.png")

    # ---- 页面上那句说明（给人看的：先说清会拿到什么）----
    Ck("★★★ 页面上写着报告是一份「文献阅读汇报」",
       "文献阅读汇报" in lit_txt, "")
    Ck("★★ 页面上写明了过程信息只作为文末的一小段附录",
       "只作为文末的一小段附录" in lit_txt or
       "文末的一小段附录" in lit_txt)

    # ---- 真填关键词、真点「看看会发什么」----
    pg.fill("#lit-kw", "single cell hepatocellular carcinoma immunotherapy")
    pg.wait_for_timeout(500)
    if pg.locator("#lit-peek").count():
        pg.click("#lit-peek")
    else:
        print("  ⚠️ 找不到「看看会发什么」那颗按钮", flush=True)
    pg.wait_for_timeout(2500)

    ok_prev = wait_for(pg, ".dsapp-lit-preview", 20000)
    Ck("★★ 点「看看会发什么」之后预览真的出来了", ok_prev)
    prev = ""
    if ok_prev:
        try:
            prev = pg.locator(".dsapp-lit-preview").first.inner_text()
        except Exception:
            prev = ""
    shot(pg, "27_preview.png")

    Ck("★ 前提：预览里有内容（空的话下面几条是空转）", len(prev) > 200,
       "%d 字" % len(prev))

    # ---- 准则本身 ----
    Ck("★★★ 预览里明写这是「文献阅读汇报」",
       "文献阅读汇报" in prev)
    Ck("★★★ 预览里明写「不是检索过程的画外音」",
       "不是检索过程的画外音" in prev)
    Ck("★★★ 预览里明写不许出现「我先检索了…」这样的过程叙述",
       "不要" in prev and "我先检索了" in prev)

    # ---- ★ 节的顺序：内容在前、过程在最后 ----
    # ⚠️ 路标取**编号行**，不取「附：检索记录」这个词 —— 后者在说明块和
    #    红线里都出现过，量到的是第一次提及的位置（在内容节**前面**），
    #    顺序断言会当场变红，而结构其实是对的。
    marks = ["1. **这批文献讲了什么**", "2. **精读**",
             "3. **略读**", "4. **一句话总览**", "5. **附：检索记录**"]
    pos = []
    for m in marks:
        i = prev.find(m)
        pos.append(i)
    Ck("★★★ 五节都找得到（找不到的话下面这条是空转）",
       all(p > 0 for p in pos), pos)
    Ck("★★★ 五节按「内容 → 精读 → 略读 → 总览 → 附：检索记录」排（过程在最后）",
       all(p > 0 for p in pos) and pos == sorted(pos) and len(set(pos)) == 5,
       pos)

    # ---- 反向：老的第 1 节不许回来 ----
    Ck("★★★ 预览里没有老的「检索概况」",
       "检索概况" not in prev)
    Ck("★★ 预览里「附：检索记录」确实排在「一句话总览」之后",
       pos[4] > pos[3] if all(p > 0 for p in pos) else False, pos)

    if jserr:
        print("\n  JS 异常：")
        for e in jserr[:5]:
            print("   ", e[:200])

    b.close()

sys.exit(Ck.done())
