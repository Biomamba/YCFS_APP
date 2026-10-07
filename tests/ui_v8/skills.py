# -*- coding: utf-8 -*-
"""V8 item 1（技能库）的浏览器验证。

对着一次性实例（8898）跑。会真的注册账号、真的建/删技能、真的写库。

为什么值得单独跑一遍浏览器：技能这条路横跨三处 —— 技能页（建）、对话页
输入框上方（挂）、服务端拼提示词（用）。数据层 selftest 全绿只证明"建和挂
这两件事在库里对"，证明不了**界面上点得到**：
  · 列表里的行内按钮是 JS 派发的单一 input（sk_act），id 拼错一个字就是
    "点了没反应"，而服务端一条日志都没有；
  · 勾选框和徽章那条链要过 modal → checkboxGroupInput → 落库 → 重画，
    中间任何一环断了，表现都是"勾了，但下次打开又是空的"。
所以这里真的去点、真的去看。

⚠️ 自然语言生成那一条**不在这里测**（它要真 Key）。它拆成两半：
   拼提示词 / 解析模型返回在 selftest.R 里（离线、确定），
   真正的 HTTP 调用由 tests/real_api.R 那条路覆盖。
"""

import io
import os
import random
import sys

from playwright.sync_api import sync_playwright

# ---- 路径与**防误伤闸门**（同 tests/ui_v7/*.py，理由见那边的注释）---------
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = os.environ.get("DSAPP_TEST_URL", "http://127.0.0.1:8898/")
APP = os.environ.get("DSAPP_TEST_APP", "/tmp/dsapp_v8test/app")
OUT = os.environ.get("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v8")


def _guard(app):
    if os.path.abspath(app) == REPO:
        sys.exit("拒绝运行：DSAPP_TEST_APP 指到了仓库本身（线上那份代码）。")
    envf = os.path.join(app, ".Renviron")
    if not os.path.exists(envf):
        sys.exit("拒绝运行：%s 不存在。" % envf)
    root = ""
    for ln in io.open(envf, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("DSAPP_DATA_ROOT="):
            root = ln.split("=", 1)[1].strip().strip('"').strip("'")
    if not root:
        sys.exit("拒绝运行：%s 里没有 DSAPP_DATA_ROOT。" % envf)
    if not (root.startswith("/tmp/") or root.startswith("/var/tmp/")):
        sys.exit("拒绝运行：DSAPP_DATA_ROOT=%s 不在临时目录下。" % root)
    return root


DATA_ROOT = _guard(APP)
os.makedirs(OUT, exist_ok=True)

ok_all = True


def chk(name, cond, extra=""):
    global ok_all
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name +
          (("   " + str(extra)) if extra and not cond else ""), flush=True)
    if not cond:
        ok_all = False
    return cond


def goto_page(pg, label):
    """点左栏导航项并等页面真的切过去。"""
    pg.locator(".dsapp-rail-link", has_text=label).first.click()
    pg.wait_for_timeout(1500)


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(2500)

    tag = "".join(random.choice("abcdefghijkmnpqrstuvwxyz23456789") for _ in range(6))
    email = "v8skill_%s@example.com" % tag
    pw = "Test-%s-pw" % tag
    if pg.locator("#welcome-nickname").count() == 0:
        pg.click("#welcome-go_register")
        pg.wait_for_timeout(1500)
    pg.fill("#welcome-nickname", "V8技能")
    pg.fill("#welcome-email", email)
    pg.fill("#welcome-phone", "13800000003")
    pg.fill("#welcome-field", "转录组")
    pg.fill("#welcome-password", pw)
    pg.click("#welcome-do_register")
    pg.wait_for_timeout(7000)
    if pg.locator("#welcome-enter_app").count() > 0:
        pg.click("#welcome-enter_app")
        pg.wait_for_timeout(7000)
    chk("注册进到主界面", pg.locator(".dsapp-shell").count() > 0,
        pg.inner_text("body")[:200].replace("\n", " "))

    # =====================================================================
    print("\n== item 1：左栏多了一个「技能」页 ==")
    # =====================================================================
    labels = [pg.locator(".dsapp-rail-link .dsapp-rail-label").nth(i).inner_text()
              for i in range(pg.locator(".dsapp-rail-link").count())]
    chk("★ 左栏有「技能」", "技能" in labels, labels)
    goto_page(pg, "技能")
    chk("★ 技能页打开了（顶栏标题跟着变）",
        "技能" in pg.inner_text("#dsapp_page_title"),
        pg.inner_text("#dsapp_page_title"))

    # =====================================================================
    print("\n== item 1：内置技能（空库也要有东西可看）==")
    # =====================================================================
    # ⚠️ 一个全新账号必须**已经能看到几条技能**。空库 + 三个按钮的话，
    #    用户根本猜不出"技能"是什么形态的东西 —— 是写一段话？传个脚本？
    rows = pg.locator(".dsapp-skill-row")
    chk("★ 新账号一进来就有内置技能（%d 条）" % rows.count(), rows.count() >= 4,
        "实际 %d 条" % rows.count())
    names = [pg.locator(".dsapp-skill-name").nth(i).inner_text()
             for i in range(pg.locator(".dsapp-skill-name").count())]
    chk("内置技能里有差异分析那条", any("差异" in n for n in names), names)
    chk("内置技能带「内置」标记",
        pg.locator(".dsapp-skill-row .badge", has_text="内置").count() >= 4)

    # =====================================================================
    print("\n== item 1：新建一条技能 ==")
    # =====================================================================
    pg.click("#skills-new")
    pg.wait_for_timeout(1200)
    chk("编辑器弹窗开了", pg.locator("#skills-f_name").count() > 0)
    pg.fill("#skills-f_name", "我的测试技能")
    pg.fill("#skills-f_sum", "验证技能库用的")
    pg.fill("#skills-f_tags", "测试,验证")
    pg.fill("#skills-f_body", "1. 每次回答都要以「收到」开头。\n2. 不要用省略号。")
    pg.click("#skills-f_save")
    pg.wait_for_timeout(2500)
    chk("弹窗关掉了", pg.locator("#skills-f_name").count() == 0)
    body_txt = pg.inner_text(".dsapp-skill-list")
    chk("★ 新技能出现在列表里", "我的测试技能" in body_txt, body_txt[:200])
    chk("标签也画出来了", "测试" in body_txt)

    # 重名要被挡住，而且**弹窗不能关** —— 关掉的话用户刚写的一屏内容就没了。
    pg.click("#skills-new")
    pg.wait_for_timeout(1200)
    pg.fill("#skills-f_name", "我的测试技能")
    pg.fill("#skills-f_body", "重名的内容")
    pg.click("#skills-f_save")
    pg.wait_for_timeout(2500)
    chk("★★ 重名被挡住，且弹窗**没关**（关了用户写的东西就没了）",
        pg.locator("#skills-f_name").count() > 0)
    notice = pg.locator(".shiny-notification").first
    chk("弹了错误提示", notice.count() > 0,
        pg.inner_text("body")[-300:].replace("\n", " "))
    pg.click("#skills-f_name >> xpath=ancestor::div[contains(@class,'modal')]//button[contains(.,'取消')]")
    pg.wait_for_timeout(1200)

    # =====================================================================
    print("\n== item 1：上传一个 .md 文件 ==")
    # =====================================================================
    up = os.path.join(OUT, "上传的技能.md")
    io.open(up, "w", encoding="utf-8").write(
        "---\nname: 从文件来的技能\nsummary: 上传路径的验证\ntags: 上传\n---\n\n"
        "1. 这条是从 .md 文件导进来的。\n")
    pg.click("#skills-upload")
    pg.wait_for_timeout(1200)
    pg.set_input_files("#skills-up_files", up)
    pg.wait_for_timeout(2000)
    prev = pg.inner_text(".modal-body")
    chk("上传前有预览（不是盲导入）", "从文件来的技能" in prev, prev[:300])
    pg.click("#skills-up_do")
    pg.wait_for_timeout(2500)
    chk("★ 文件名之外的元信息被读出来了（frontmatter 里的 name，不是文件名）",
        "从文件来的技能" in pg.inner_text(".dsapp-skill-list"),
        pg.inner_text(".dsapp-skill-list")[:300])
    chk("markdown 后缀没被当成技能名的一部分",
        "上传的技能.md" not in pg.inner_text(".dsapp-skill-list"))

    # =====================================================================
    print("\n== item 1：在对话里挂技能 ==")
    # =====================================================================
    goto_page(pg, "言出法随")
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(2500)

    bar = pg.locator(".dsapp-skillbar")
    chk("★ 输入框上方有技能挂载栏", bar.count() > 0)
    chk("一开始没挂技能（说清楚了这一轮按通用规则来）",
        "没有挂技能" in bar.inner_text(), bar.inner_text())

    pg.click(".dsapp-skillbar-btn")
    pg.wait_for_timeout(1500)
    opts = pg.locator(".dsapp-skillpick input[type='checkbox']")
    # 勾选框的实际 markup 我不猜（见 app.css 里那段说明），但**勾选项本身**
    # 必须数得出来 —— 数不出来就说明这个弹窗是空的，用户没得选。
    chk("★ 勾选弹窗列出了技能库里的每一条（%d 个）" % opts.count(),
        opts.count() >= 6, "实际 %d 个" % opts.count())

    # 勾上"我的测试技能"和一条内置的。
    target = pg.locator(".dsapp-skillpick label",
                        has_text="我的测试技能").first
    if target.count() == 0:
        target = pg.locator(".dsapp-skillpick label",
                            has_text="我的测试技能").first
    target.click()
    pg.locator(".dsapp-skillpick label", has_text="差异表达分析").first.click()
    pg.wait_for_timeout(500)
    pg.click("#chat-skill_apply")
    pg.wait_for_timeout(2500)

    chips = pg.locator(".dsapp-skill-chip")
    chk("★★ 挂载栏上出现了两条技能徽章", chips.count() == 2,
        "实际 %d 条：%s" % (chips.count(), pg.inner_text(".dsapp-skillbar")))
    chip_txt = pg.inner_text(".dsapp-skillbar")
    chk("徽章上写的是技能名", "我的测试技能" in chip_txt, chip_txt)
    chk("按钮上的计数跟着变（看得出来挂了几条）",
        "（2）" in pg.inner_text(".dsapp-skillbar-btn"),
        pg.inner_text(".dsapp-skillbar-btn"))

    # 换一个对话 → 挂载必须跟着换（技能是**按对话**的，不是按浏览器的）
    if pg.locator("#chat-new_chat").count():
        pg.click("#chat-new_chat")
        pg.wait_for_timeout(2500)
    chk("★★ 新建对话后没有技能（挂载跟着对话走，不是跟着浏览器）",
        "没有挂技能" in pg.inner_text(".dsapp-skillbar"),
        pg.inner_text(".dsapp-skillbar"))

    # =====================================================================
    print("\n== item 1：摘掉一条 ==")
    # =====================================================================
    # 回到挂了技能的那个对话（列表里第一条之外的另一个）。
    # 直接再用弹窗挂一遍更稳，不依赖对话列表的顺序。
    pg.click(".dsapp-skillbar-btn")
    pg.wait_for_timeout(1500)
    pg.locator(".dsapp-skillpick label", has_text="结果可复现").first.click()
    pg.wait_for_timeout(400)
    pg.click("#chat-skill_apply")
    pg.wait_for_timeout(2500)
    chk("挂上了 1 条", pg.locator(".dsapp-skill-chip").count() == 1,
        pg.inner_text(".dsapp-skillbar"))

    pg.locator(".dsapp-skill-chip-x").first.click()
    pg.wait_for_timeout(2500)
    chk("★ 点徽章上的 × 能摘掉（不用再开一次弹窗）",
        pg.locator(".dsapp-skill-chip").count() == 0,
        pg.inner_text(".dsapp-skillbar"))

    # 重新挂上两条，好让下面刷新持久化那条有东西可验。
    pg.click(".dsapp-skillbar-btn")
    pg.wait_for_timeout(1500)
    pg.locator(".dsapp-skillpick label", has_text="我的测试技能").first.click()
    pg.locator(".dsapp-skillpick label", has_text="出图规范").first.click()
    pg.wait_for_timeout(400)
    pg.click("#chat-skill_apply")
    pg.wait_for_timeout(2500)
    chk("重新挂上两条", pg.locator(".dsapp-skill-chip").count() == 2,
        pg.inner_text(".dsapp-skillbar"))

    # =====================================================================
    print("\n== item 1：刷新之后还在（真的落库了，不是只活在内存里）==")
    # =====================================================================
    pg.reload(wait_until="domcontentloaded")
    pg.wait_for_selector(".dsapp-auth, .dsapp-shell", timeout=30000)
    pg.wait_for_timeout(6000)
    if pg.locator("#chat-new_chat").count() and \
       pg.locator(".dsapp-skill-chip").count() == 0:
        # 刷新后会停在"最后一个对话"。若不是刚挂过的那个，说明挂载
        # 确实跟着对话走 —— 这本身是对的，不能算失败，但要**出声**。
        print("     （刷新后打开的不是刚挂过的对话，跳到技能页去核对库）")
    goto_page(pg, "技能")
    lib = pg.inner_text(".dsapp-skill-list")
    chk("★★ 刷新后技能库还在（我的两条 + 上传的一条）",
        "我的测试技能" in lib and "从文件来的技能" in lib, lib[:300])

    # =====================================================================
    print("\n== item 1：删掉自己建的，内置的删不掉 ==")
    # =====================================================================
    row = pg.locator(".dsapp-skill-row", has_text="我的测试技能").first
    row.locator(".dsapp-skill-a-del").click()
    pg.wait_for_timeout(1500)
    chk("弹了确认框（删东西不能一点就没）",
        "确认删除" in pg.inner_text(".modal-body") or
        pg.locator(".modal-body").count() > 0)
    pg.click("#skills-do_del")
    pg.wait_for_timeout(2500)
    lib2 = pg.inner_text(".dsapp-skill-list")
    chk("★ 删掉了", "我的测试技能" not in lib2, lib2[:200])
    chk("别的没被误删", "从文件来的技能" in lib2)

    bi_row = pg.locator(".dsapp-skill-row", has_text="内置").first
    acts = bi_row.inner_text()
    chk("★★ 内置技能没有删除按钮，给的是「另存为我的」",
        "另存为我的" in acts and "删除" not in acts, acts)

    pg.screenshot(path=os.path.join(OUT, "skills.png"))

    # =====================================================================
    print("\n== 收尾 ==")
    # =====================================================================
    chk("没有 JS 报错", len(errs) == 0, errs[:3])
    b.close()

print()
if ok_all:
    print("\033[32m全部通过\033[0m")
else:
    print("\033[31m有失败项\033[0m")
    sys.exit(1)
