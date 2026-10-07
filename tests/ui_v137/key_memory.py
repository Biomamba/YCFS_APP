# -*- coding: utf-8 -*-
"""V13.7 item 3：「API Key 的记忆功能有点问题」。

用户原话就这一句，没有给复现步骤。查下来是**三个**独立的覆盖，全都出在
「切厂商」这一拍，而且全都**静默** —— 界面上没有任何异常，只有下次切回来
才发现东西没了。

  R1(a) state$api_key 被旧值盖掉
        切厂商的 observer 从钥匙串里取出这一家的 Key、写进 state；紧接着
        「状态同步到会话」那个 observe（注册得更晚，同一轮里后跑）读
        input$api_key —— 而浏览器要等下一次往返才会把新值报回来，此刻装的
        还是**上一家的 Key** —— 当场盖回去。state$api_key 正是发消息时读的
        那一个，于是「切完厂商立刻发一条」发出去的是上一家的 Key。

        ⚠️ 这一条**本脚本测不到**：覆盖是暂态的，浏览器报回新值之后 state
        自己就对了，只在几百毫秒的窗口里发作。修法是让发送路径不再信 state
        而现查库 —— 本脚本测的是**修完之后的那个性质**（下面 R1(a) 那一节），
        覆盖本身由 selftest.R 里一句源码级断言钉住。

  R1(b) base_url 被厂商默认值盖掉（★ 丢得最狠的一条）
        切厂商的 observer 推了库里存的中转地址；vendor_seen 那个 observe
        紧接着又推一次厂商默认值 —— 浏览器按**到达顺序**应用，最后留下的是
        默认值；800ms 后防抖保存再把默认值写回库。厂商/模型还能靠默认值兜
        回来，**手填的地址丢了就是永久丢**。

  R1(c) 模型名被上一家的名字盖掉
        models_res(NULL) 触发 model_choices 重算，那边沿用 isolate(input$model)
        —— 此刻还是上一家的模型名。库里的现场证据：users.llm_model 是
        'glm-4.5' 而 user_api_keys.zhipu.model 是 'glm-5.3'。

★ 为什么必须用真浏览器：这三条的根因都是**时序**（谁先注册、同一轮里谁后
  跑、浏览器按什么顺序应用 update*）。离线断言里「谁先谁后」是我们自己摆的，
  摆了就没在测。R1(a) 尤其如此 ——「input 还停在旧值上」这件事只在真 websocket
  的一次真实往返里存在。

★ 判据为什么必须**解密之后**比：V13.1 item 9 起 Key 是密文，而密文带随机 IV，
  同一把 Key 写两次得到的字符串完全不同。比长度、比前缀都是假判据。
"""
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, OUT, enter_app, goto, pick_select,      # noqa: E402
                     r_decrypt, seed_or_die)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

KEY_DS = "sk-DEEPSEEK-MEMORY-0001"
RELAY = "https://relay.v137.example/v1"
MODEL_DS = "deepseek-v4-pro"
MODEL_KIMI = "kimi-k3"

DB = {"con": None}


def dump(uid):
    """库里那四样到底是什么 —— 原文，不解释。"""
    r = DB["con"].execute(
        "SELECT llm_vendor, llm_model, llm_base_url, llm_api_key "
        "FROM users WHERE id = ?", (uid,)).fetchone()
    return {"vendor": r[0], "model": r[1], "base": r[2],
            "key": r_decrypt([r[3]])[0]}


def vault(uid):
    """钥匙串里 (厂商 -> (Key, 地址, 模型)) 的全貌。"""
    rows = DB["con"].execute(
        "SELECT vendor, api_key, base_url, model FROM user_api_keys "
        "WHERE user_id = ?", (uid,)).fetchall()
    plain = r_decrypt([v for _k, v, _b, _m in rows])
    return dict((k, {"key": p, "base": b, "model": m})
                for (k, _v, b, m), p in zip(rows, plain))


def snap(page):
    """界面上那四个控件此刻的值（不用展开面板，DOM 一直在）。"""
    return page.evaluate("""() => {
      var g = (s) => { var e = document.querySelector(s); return e ? e.value : null; };
      return {key: g('#model-api_key'), vendor: g('#model-vendor'),
              model: g('#model-model'), base: g('#model-base_url')};
    }""")


def set_vendor(page, value, wait=2000):
    pick_select(page, "model-vendor", value)
    page.wait_for_timeout(wait)


def open_panel(page, wait=1000):
    """把「模型服务」那一块展开。

    ⚠️ 必须**每次点完「确认/更新」都重新展一次**：保存成功之后应用会走
    `dsapp:rail-model {open:false}` 把这一块收起来（V7 item 8，故意收的）。
    不收的话控件被 <details> 折叠成不可见，Playwright 的可操作性检查会一直
    等到超时，报出来的是 "element is not visible" —— 指向"这个控件不存在"，
    而真实原因只是"面板关着"。第一次写这个脚本就栽在这儿。
    """
    page.evaluate("() => { var d = document.querySelector('.dsapp-rail-model');"
                  " if (d) d.open = true; }")
    page.wait_for_timeout(wait)


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 1000})
    page = ctx.new_page()
    errs = []
    page.on("pageerror", lambda e: errs.append(str(e)))

    email = enter_app(page, nickname="记忆")
    uid, dbfile = seed_or_die(email)
    DB["con"] = sqlite3.connect(dbfile)
    print("== uid=%s db=%s ==" % (uid, dbfile), flush=True)

    goto(page, "settings", wait=4000)
    open_panel(page)

    # ---- 0. 给 DeepSeek 配一套**非默认**的：手填地址 + 非首选模型 -----------
    print("\n== 给 DeepSeek 配一套非默认的 ==", flush=True)
    set_vendor(page, "deepseek")
    page.fill("#model-api_key", KEY_DS)
    page.wait_for_timeout(2500)          # textInput 有 250ms 防抖
    # ★ 手填的中转地址 —— 用户报的"信息没了"里，这一格是唯一找不回来的
    page.fill("#model-base_url", RELAY)
    page.wait_for_timeout(1500)
    # ★ 换掉默认模型（deepseek-flash 是清单第一项）。这一条是 R1(c) 的对照：
    #   被盖掉时它会退回清单第一项，而第一项恰好等于**没改过**的样子 ——
    #   所以必须挑一个不等于第一项的名字，否则红绿不分。
    pick_select(page, "model-model", MODEL_DS)
    page.wait_for_timeout(1500)
    page.click("#model-commit")
    page.wait_for_timeout(4000)
    open_panel(page)     # 保存成功后这一块会被自动收起，接着要切厂商得先展开

    got = dump(uid)
    chk("（前置）四样都落库了：厂商 / 非默认模型 / 手填地址 / Key",
        got["vendor"] == "deepseek" and got["model"] == MODEL_DS and
        got["base"] == RELAY and got["key"] == KEY_DS,
        extra="vendor=%r model=%r base=%r key=%r"
              % (got["vendor"], got["model"], got["base"], got["key"]))
    chk("（前置）钥匙串里 DeepSeek 那行也带着地址和模型",
        (vault(uid).get("deepseek") or {}).get("base") == RELAY and
        (vault(uid).get("deepseek") or {}).get("model") == MODEL_DS,
        extra=vault(uid))

    # =====================================================================
    print("\n== 切到 Kimi，再切回来 ==", flush=True)
    # =====================================================================
    set_vendor(page, "moonshot")
    kimi = snap(page)
    chk("★ 切到没配过的 Kimi，Key 框是空的（留着上一家那把 = 静默用错 Key）",
        kimi["key"] == "", extra=repr(kimi["key"]))
    chk("★ 而且 Kimi 的地址退回它自己的默认值（不能留着 DeepSeek 的中转地址）",
        kimi["base"] != RELAY and kimi["base"],
        extra=repr(kimi["base"]))

    set_vendor(page, "deepseek")
    page.wait_for_timeout(2500)          # 再等一拍防抖保存落定

    back = snap(page)
    chk("★★★ 切回来，手填的中转地址还在（这一格丢了就是永久丢 —— R1(b)）",
        back["base"] == RELAY, extra="地址栏是 %r" % (back["base"],))
    chk("★★★ 切回来，模型还是当初选的 %s（R1(c)：被盖时会退回清单一头）"
        % MODEL_DS,
        back["model"] == MODEL_DS, extra="模型框是 %r" % (back["model"],))
    chk("★★ 切回来，Key 还是 DeepSeek 那把（R1(a) 的界面侧）",
        back["key"] == KEY_DS, extra=repr(back["key"]))

    page.wait_for_timeout(2000)
    after = dump(uid)
    chk("★★★ 库里的手填地址**没被厂商默认值写回去**（R1(b) 的真正后果）",
        after["base"] == RELAY, extra="库里是 %r" % (after["base"],))
    chk("★★★ 库里的模型也没被写回清单一头（R1(c)）",
        after["model"] == MODEL_DS, extra="库里是 %r" % (after["model"],))
    chk("★★ 库里当前生效的 Key 还是 DeepSeek 那把",
        after["key"] == KEY_DS, extra=repr(after["key"]))
    chk("★ Kimi 那家的记录里**没有**被抄进 DeepSeek 的地址（归属没错位）",
        not (vault(uid).get("moonshot") or {}).get("base"),
        extra=vault(uid))

    # =====================================================================
    print("\n== 再来一轮，防「只是第一次凑巧」==", flush=True)
    # =====================================================================
    # ⚠️ 单次通过说明不了什么：这三条都是时序 bug，而时序 bug 的形态就是
    #    "有时候对"。第二轮多切一次，把"刚好赶上"这条路堵掉。
    set_vendor(page, "qwen")
    set_vendor(page, "deepseek")
    page.wait_for_timeout(2500)
    back2 = snap(page)
    chk("★★★ 二次往返后地址仍然在",
        back2["base"] == RELAY, extra=repr(back2["base"]))
    chk("★★★ 二次往返后模型仍然在",
        back2["model"] == MODEL_DS, extra=repr(back2["model"]))

    # =====================================================================
    print("\n== R1(a)：切到没 Key 的厂商，发消息必须被闸门拦住 ==", flush=True)
    # =====================================================================
    # ★ 这一节钉的是 R1(a) 的**后果**：发消息这条路必须现查库，不能信内存里
    #   那个可能滞后的副本。切到没配 Key 的厂商 → 库里这家是空的 → 闸门弹窗。
    #
    #   ⚠️ 说清楚这一节**没有**钉什么：R1(a) 那个覆盖是**暂态**的 —— 浏览器
    #      过一拍把新值报回来之后 state 自己就对了。所以真浏览器里它只在
    #      "切完厂商立刻发消息"那几百毫秒的窗口里发作，Playwright 抓不住
    #      （验证过：把三处覆盖全改回旧写法重跑本脚本，红了 8 条，但**都不是**
    #      这一条 —— 它自愈了）。
    #
    #      那一条的守卫在 selftest.R 里：一句源码级断言，钉死 mod_model.R 里
    #      不许再出现 `state$api_key <- input$api_key`。釜底抽薪的做法则是
    #      本脚本能测的这个 —— 发送路径读库，于是那一行就算回来也无害。
    #
    #   ⚠️ 这里**不需要**真的联网：闸门在发请求**之前**。
    set_vendor(page, "moonshot")
    page.wait_for_timeout(2000)
    goto(page, "chat", wait=3500)
    page.fill("#chat-input", "这条不该发出去")
    page.wait_for_timeout(500)
    page.click("#chat-send")
    page.wait_for_timeout(3000)

    modal = ""
    try:
        modal = page.inner_text(".modal-content")
    except Exception:
        modal = "（没有弹窗）"
    chk("★★★ 切到没配 Key 的厂商后发消息 → 弹「还不能开始对话」，"
        "而不是拿上一家的 Key 去请求（R1(a)）",
        "还不能开始对话" in modal, extra=modal[:200])
    chk("★ 而且没有把这条消息真的发出去（气泡不落地）",
        "这条不该发出去" not in page.inner_text(".dsapp-shell"),
        extra="输入框里是 %r" % (page.input_value("#chat-input"),))

    chk("★ 全程没有 JS 报错", not errs, extra=errs[:3])

    page.screenshot(path=OUT + "/key_memory.png", full_page=True)
    DB["con"].close()
    br.close()

sys.exit(chk.done())
