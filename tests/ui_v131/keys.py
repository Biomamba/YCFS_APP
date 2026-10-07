# -*- coding: utf-8 -*-
"""V13.1 item 5：API Key 按厂商分别记住，切厂商时自动带出来。

用户原话：
  「填写的api key要有记忆功能，在切换厂商时能直接切换过来，不然每次
    复制API key不好操作」

★ 这一项真正要防的不是"记不住"，是**记错家**：
  切厂商的那一刻，输入框里装的还是上一家的 Key。如果归属按"当前厂商"
  现推，那把 Key 就会被写到新厂商名下 —— 而且是**静默**的：界面上一切
  正常，只有下次切回来才会发现多了一把用不了的 Key，或者更糟，用户切到
  B 家、看到「Key 已记住」、发消息，发出去的是 A 家的 Key，回来一个
  不提厂商的 401。

  所以这一节的关键断言不是"切过去之后框里有值"，而是：
    · 每家的值**各归各家**（A 的值没被抄到 B 名下）
    · 切到没存过的那家，框里**是空的**，不能留着上一家的
    · 数据库里那把"当前生效的 Key"（users.llm_api_key）跟着一起换 ——
      界面换了、库里没换，是这个 bug 最隐蔽的一种形态

★ 为什么每一段都重新查一次库：
  界面上的值只能证明"控件里显示了什么"。用户真正发消息时读的是
  state$api_key，而它来自 users.llm_api_key 那一列。只测界面的话，
  一个"控件换了、列没换"的实现能全绿跑过去。
"""
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (Chk, OUT, enter_app, goto, pick_select,  # noqa: E402
                     r_decrypt, seed_or_die)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

KEY_A = "sk-deepseek-AAAA-1111"
KEY_B = "sk-moonshot-BBBB-2222"


def key_value(page):
    return page.input_value("#model-api_key")


def col(page, uid):
    """users.llm_api_key —— 发消息时真正用的那一把。"""
    return db_col(uid, "llm_api_key")


DB = {"con": None}


# ★ V13.1 item 9 起这两列在库里是**密文**，所以下面两个读函数一律先解再比。
#   不这么做的话，这个脚本会以"7 条断言全红、红的全是 v1: 开头的乱码"的
#   形态失败 —— 看着像加解密把 Key 存坏了，其实是测试在拿密文比明文。
#   解不开时 r_decrypt 给回 None，断言该红还是红（不会假装通过）。


def db_col(uid, name):
    r = DB["con"].execute(
        "SELECT %s FROM users WHERE id = ?" % name, (uid,)).fetchone()
    return None if r is None else r_decrypt([r[0]])[0]


def raw(uid, name):
    """**不**解密，原样返回 —— 专门用来钉"库里躺的确实是密文"。"""
    r = DB["con"].execute(
        "SELECT %s FROM users WHERE id = ?" % name, (uid,)).fetchone()
    return None if r is None else r[0]


def vault(uid):
    """钥匙串里 (厂商 -> Key) 的全貌（值已解密）。"""
    rows = DB["con"].execute(
        "SELECT vendor, api_key FROM user_api_keys WHERE user_id = ?",
        (uid,)).fetchall()
    plain = r_decrypt([v for _k, v in rows])
    return dict((k, p) for (k, _v), p in zip(rows, plain))


def set_vendor(page, value):
    pick_select(page, "model-vendor", value)
    page.wait_for_timeout(1800)


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    email = enter_app(page, nickname="钥匙")
    uid, dbfile = seed_or_die(email)
    DB["con"] = sqlite3.connect(dbfile)
    print("  账号 uid=%s 库=%s" % (uid, dbfile), flush=True)

    goto(page, "settings", wait=4000)
    chk("★ 设置页有厂商下拉和 Key 输入框",
        page.locator("#model-vendor").count() == 1 and
        page.locator("#model-api_key").count() == 1)
    chk("★ 新账号的钥匙串是空的", vault(uid) == {}, extra=vault(uid))

    # ---- 1. 给 deepseek 填一把 -------------------------------------------
    print("\n== 给 DeepSeek 填一把 Key ==", flush=True)
    set_vendor(page, "deepseek")
    page.fill("#model-api_key", KEY_A)
    # textInput 有 250ms 防抖，填完立刻切厂商会丢值（见 tests/ui_v13 的说明）
    page.wait_for_timeout(2500)
    chk("★★ 填完就落进了钥匙串的 deepseek 名下",
        vault(uid).get("deepseek") == KEY_A, extra=vault(uid))
    chk("★★ 而且「当前生效的那把」也跟着变了（users.llm_api_key）",
        col(page, uid) == KEY_A, extra=col(page, uid))
    # 这一条把 item 5 和 item 9 钉在一起：上面两条之所以要解一次密才比得出来，
    # 就是因为库里躺的是密文。哪天加密被关掉，这条会红 —— 而上面两条照样绿。
    chk("★★ 落盘的是**密文**、不是明文（item 9；否则上面两条解密是白解的）",
        str(raw(uid, "llm_api_key") or "").startswith("v1:") and
        KEY_A not in str(raw(uid, "llm_api_key") or ""),
        extra=repr(raw(uid, "llm_api_key"))[:90])

    # ---- 2. 切到 moonshot：框里必须是空的，不能留着上一家的 -------------
    print("\n== 切到 Kimi（没填过）==", flush=True)
    set_vendor(page, "moonshot")
    page.wait_for_timeout(1200)
    chk("★★ 切到没填过的厂商，Key 框是**空的**（留着上一家那把 = 静默用错 Key）",
        key_value(page) == "", extra=repr(key_value(page)))
    chk("★★ 库里「当前生效的那把」也必须是空的"
        "（界面清了、列没清的话，发消息用的还是 DeepSeek 的 Key）",
        not col(page, uid), extra=repr(col(page, uid)))
    chk("★ DeepSeek 那把没被删掉，还在它自己名下",
        vault(uid).get("deepseek") == KEY_A, extra=vault(uid))
    chk("★★ 也没被抄到 moonshot 名下（这就是原来那个 bug 的形态）",
        "moonshot" not in vault(uid), extra=vault(uid))

    # ---- 3. 给 moonshot 填一把 -------------------------------------------
    print("\n== 给 Kimi 填一把 ==", flush=True)
    page.fill("#model-api_key", KEY_B)
    page.wait_for_timeout(2500)
    chk("★★ 两把 Key 各归各家", vault(uid) == {"deepseek": KEY_A,
                                              "moonshot": KEY_B},
        extra=vault(uid))
    chk("★★ 当前生效的那把换成了 Kimi 的", col(page, uid) == KEY_B,
        extra=col(page, uid))

    # ---- 4. 切回去：Key 要自己回来 ---------------------------------------
    print("\n== 切回 DeepSeek：应该自动带出 KEY_A ==", flush=True)
    set_vendor(page, "deepseek")
    page.wait_for_timeout(1500)
    chk("★★ 切回去 Key 自动填好了（用户不用再复制一遍 —— 这就是这一项的需求）",
        key_value(page) == KEY_A, extra=repr(key_value(page)))
    chk("★★ 当前生效的那把也跟着换回 DeepSeek 的", col(page, uid) == KEY_A,
        extra=col(page, uid))
    chk("★★ 来回切一轮之后，两家还是各是各的（没有被互相覆盖）",
        vault(uid) == {"deepseek": KEY_A, "moonshot": KEY_B}, extra=vault(uid))
    chk("★ 也没有多出第三家", len(vault(uid)) == 2, extra=vault(uid))

    # ---- 5. 界面上的文案要说清是哪一家 -----------------------------------
    print("\n== 文案 ==", flush=True)
    try:
        state = page.inner_text("#model-key_state")
    except Exception:
        state = "（读不到 key_state）"
    chk("★ 「Key 已记住」里点明了是哪一家（不然用户没法判断现在用的是谁）",
        "深度求索" in state or "DeepSeek" in state, extra=state[:200])
    chk("★★ 清除按钮写的是「清除全部厂商」，不是光秃秃一个「清除」"
        "（这个按钮真的会把所有厂商的都删掉，藏着说等于让用户以为只删了一把）",
        "全部厂商" in state, extra=state[:200])

    # ---- 6. 清除：全部清掉，并如实报出把数 -------------------------------
    print("\n== 清除 ==", flush=True)
    page.click("#model-forget_key")
    page.wait_for_timeout(2000)
    try:
        notes = " | ".join(page.locator(".shiny-notification").all_inner_texts())
    except Exception:
        notes = "（读不到通知）"
    chk("★★ 清完之后钥匙串是空的", vault(uid) == {}, extra=vault(uid))
    chk("★★ 当前生效的那把也清了", not col(page, uid), extra=repr(col(page, uid)))
    chk("★ 输入框也清空了", key_value(page) == "", extra=repr(key_value(page)))
    chk("★★ 通知里说了清掉的是**几把**（笼统一句「已清除」的话，"
        "用户配过三家而只清了一把也看不出来）",
        "2 把" in notes and "所有厂商" in notes, extra=notes[:200])

    page.screenshot(path=OUT + "/keys.png", full_page=True)
    DB["con"].close()
    br.close()

sys.exit(chk.done())
