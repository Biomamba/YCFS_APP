# -*- coding: utf-8 -*-
"""V13.1 item 1 / 3：厂商的「申请」和「已有账号拿 Key」是两个页面。

用户原话：
  · item 1「智谱GLM的官网申请链接用这个跳转：https://www.bigmodel.cn/invite?icode=…」
  · item 3「字节豆包的跳转链接用这个：https://volcengine.com/L/yI2tkEV2pds/」

★ 为什么不能只断言"目录里那个字段填对了"：
  这一项改的是**链接**，而链接只有点下去才知道去了哪。字段填对、界面不读
  它，用户看到的还是老链接 —— 这种"数据改了、界面没读"在自检里是完全
  静默的。所以这里真的切到设置页、真的把厂商下拉一个个选过去，读的是
  **浏览器里那个 <a> 的 href**。

★ 为什么还留了一条「控制台」的断言：
  用户给的这两个都是**注册入口**。原来只有 key_url 一个字段，而它指的是
  控制台里的 API Keys 页。直接把它换掉的话，已经有账号的人每次点「申请」
  都会被丢回注册页。所以是两个字段、两条链接，这里两条都钉住。

★ 还有一条"对照组"：没配 invite_url 的厂商（DeepSeek）行为必须**逐字
  不变** —— 只有一个链接，指向原来的 key_url。三个厂商的链接都换成同样
  的写法，才是这一项真正想避免的事。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, pick_select   # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

ZHIPU_INVITE = ("https://www.bigmodel.cn/invite?icode="
                "uGoVkyfgBMhneusLOZCgY2czbXFgPRGIalpycrEwJ28%3D")
DOUBAO_INVITE = "https://volcengine.com/L/yI2tkEV2pds/"


def hrefs(page):
    """key_help 那一块里所有 <a> 的 href，按出现顺序。"""
    a = page.locator("#model-key_help a")
    return [a.nth(i).get_attribute("href") or "" for i in range(a.count())]


def help_text(page):
    try:
        return page.inner_text("#model-key_help")
    except Exception:
        return "（读不到 key_help）"


def pick_vendor(page, value):
    pick_select(page, "model-vendor", value)
    page.wait_for_timeout(1500)


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    enter_app(page, nickname="链接")
    goto(page, "settings", wait=4000)

    chk("★ 设置页有「厂商」下拉和「还没有 Key？」那一块",
        page.locator("#model-vendor").count() == 1 and
        page.locator("#model-key_help").count() == 1)

    # ---- 智谱 -------------------------------------------------------------
    print("\n== 智谱 GLM ==", flush=True)
    pick_vendor(page, "zhipu")
    h = hrefs(page)
    t = help_text(page)
    chk("★ 智谱这一块有**两条**链接（申请 + 控制台）", len(h) == 2,
        extra="拿到 %d 条：%s" % (len(h), h))
    chk("★★ 第一条（「官网申请」）是用户给的那个邀请链接",
        len(h) >= 1 and h[0] == ZHIPU_INVITE, extra=h[:1])
    chk("★★ 而不是原来那个控制台地址（换了才算改完）",
        len(h) >= 1 and "usercenter/proj-mgmt/apikeys" not in h[0])
    chk("★ 第二条还留着控制台（已有账号的人不该被丢回注册页）",
        len(h) >= 2 and "bigmodel.cn/usercenter" in h[1], extra=h[1:2])
    chk("★ 申请那条写的是「官网申请」，不是「控制台」",
        "官网申请" in t and "控制台" in t, extra=t[:160])
    chk("★ 两条都是新标签页打开（不然用户点一下就把正在跑的对话弄丢了）",
        page.locator("#model-key_help a[target='_blank']").count() == 2)
    # 邀请链接带 icode —— 这正是它和普通官网地址的区别，别在别处被截断
    chk("★★ icode 那一整串还在（截断了就是另一个人的邀请码了）",
        len(h) >= 1 and "icode=uGoVkyfgBMhneusLOZCgY2czbXFgPRGIalpycrEwJ28" in h[0])

    # ---- 豆包 -------------------------------------------------------------
    print("\n== 字节豆包 ==", flush=True)
    pick_vendor(page, "doubao")
    h = hrefs(page)
    t = help_text(page)
    chk("★ 豆包这一块有两条链接", len(h) == 2, extra="拿到 %d 条：%s" % (len(h), h))
    chk("★★ 第一条是用户给的那个短链", len(h) >= 1 and h[0] == DOUBAO_INVITE,
        extra=h[:1])
    chk("★ 第二条还留着火山控制台",
        len(h) >= 2 and "console.volcengine.com" in h[1], extra=h[1:2])

    # ---- 对照组：没配 invite_url 的厂商 -----------------------------------
    #
    # DeepSeek 没配 invite_url。它必须还是**一条**链接、指向原来的 key_url ——
    # 「申请」和「控制台」在那里本来就是同一个页面，多冒出一条是重复。
    print("\n== 对照组：DeepSeek ==", flush=True)
    pick_vendor(page, "deepseek")
    h = hrefs(page)
    t = help_text(page)
    chk("★★ 没配 invite_url 的厂商行为**逐字不变**：只有一条链接",
        len(h) == 1, extra="拿到 %d 条：%s" % (len(h), h))
    chk("★ 而且指向原来的 key_url",
        len(h) >= 1 and "platform.deepseek.com/api_keys" in h[0], extra=h[:1])
    chk("★ 也没有多写一句「控制台」（那是同一句话写两遍）", "控制台" not in t,
        extra=t[:160])

    page.screenshot(path=OUT + "/links.png", full_page=True)
    br.close()

sys.exit(chk.done())
