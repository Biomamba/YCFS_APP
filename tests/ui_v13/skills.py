# -*- coding: utf-8 -*-
"""V13 item 4：把 11 个 skills 仓库的内容内置进去。

用户原话：「把这几个 skills 的内容也内置一下」，给了 11 个 GitHub 仓库
（其中一个重复）。定下来的做法是**一个仓库提炼成一篇**，所以内置技能应该
是 11 篇长的 + 原有的 4 篇短的 = 15 篇。

★ 这里只验"用户在页面上真的看得见、能挂载"。正文是抓下来再重写的，自检
  里验不了"内容对不对"（那要人来读），能机验的是**结构**：
    · 11 篇都在，而且都带「内置」标记
    · 几万字的长文有体量提示（挂了长文会让对话变慢，得让人先看见）
    · 搜索能找到它们
    · 详情里读得出正文，不是空壳
  "内容是空的"和"内容不对"是两码事，前者是 bug，后者是编辑问题。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 一个仓库一篇，标题是提炼时定的（见 skills_builtin/ 里那 11 个 .md 的
# frontmatter）。名字变了这里要跟着改 —— 但**别**改成"数量对就行"：
# 数量对而内容串了（比如两篇都来自同一个仓库）是这条测试唯一能挡的错。
EXPECT = [
    "学术论文写作与同行评审",
    "Nature 系投稿级科研出图规范",
    "科研分析规范与 Agent 工作流",
    "科研全学科分析流程库",
    "科研数据分析全流程方法",
    "开放科学产出规范",
    "Excalidraw 示意图生成",
    "把分析流程画成专业图表",
    "长任务无人值守编排",
    "自主研究循环与实验记录规范",
    "科学数据库检索与变异解读",
]


def listtext(page):
    try:
        return page.inner_text("#skills-list_ui")
    except Exception:
        return ""


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="技能")
    goto(page, "skills", wait=4000)

    txt = listtext(page)
    missing = [n for n in EXPECT if n not in txt]
    chk("★ 11 个仓库提炼出来的内置技能都在列表里", not missing,
        extra="缺：%s" % missing)
    chk("★ 列表里带「内置」标记（用户要能分清哪些是自己建的）",
        "内置" in txt)

    # 长文要有体量提示：挂了之后正文整段进提示词，不先说清楚的话，
    # 用户只会觉得"这个对话变笨了、还特别慢"。
    # 页面上写的是「正文约 42,035 字」，可能还带一句"（较长，建议一次只挂一篇）"。
    import re
    sizes = [int(x.replace(",", "")) for x in
             re.findall(r"正文约 ([\d,]+) 字", txt)]
    chk("★ 几万字的长文标了体量（挂上去会让对话变慢，得先看见）",
        len(sizes) >= 10 and max(sizes) > 20000,
        extra="标了体量的有 %d 篇，最大 %s" % (len(sizes), max(sizes) if sizes else "无"))
    chk("★ 最长的那些还多一句提醒「较长，建议一次只挂一篇」",
        "建议一次只挂一篇" in txt, extra=txt[:200])

    # 搜索能找到
    try:
        page.fill("#skills-q", "出图")
        page.wait_for_timeout(1500)
        st = listtext(page)
        chk("★ 搜索「出图」能找到那两篇出图技能",
            "出图" in st and ("Nature" in st or "图表" in st), extra=st[:250])
        page.fill("#skills-q", "")
        page.wait_for_timeout(1200)
    except Exception as e:
        chk("搜索框可用", False, extra=repr(e)[:120])

    # 详情：点「查看 / 编辑」，正文要读得出来（不是空壳、不是"读取失败"）
    #
    # ⚠️ 正文在弹窗里的 `#skills-f_body` **textarea** 里，不在页面上。
    #    第一版点的是行标题、量的是整页 body 的长度 —— 量到 2303 字
    #    （那是列表本身的长度），于是报"正文是空壳"，而正文好好地在
    #    弹窗里躺着。量文本域要用 input_value()。
    row = page.locator(".dsapp-skill-row").filter(has_text="科学数据库检索").first
    chk("能找到「科学数据库检索与变异解读」这一行", row.count() == 1)
    if row.count():
        row.locator("a.dsapp-skill-a", has_text="查看").first.click()
        page.wait_for_selector("#skills-f_body", timeout=15000)
        page.wait_for_timeout(1500)
        body = page.input_value("#skills-f_body")
        chk("★ 点开之后正文真的读出来了（四万字那篇，不是空壳）",
            len(body) > 20000, extra="正文长度 %d" % len(body))
        chk("★ 正文里没出现「读取失败」「文件不存在」这类错误",
            ("读取失败" not in body) and ("文件不存在" not in body))
        chk("★ 弹窗标题是「编辑技能」（内置技能可读，不是打不开）",
            "编辑技能" in page.inner_text(".modal-title"))
        page.keyboard.press("Escape")
        page.wait_for_timeout(1000)

    page.screenshot(path=OUT + "/skills.png", full_page=True)
    br.close()

sys.exit(chk.done())
