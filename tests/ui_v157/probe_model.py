#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V15.7 item 8：**模型不许被自己那份陈旧副本改回去。**

用户原话：「8、再给你个信息点，页面每次崩溃后模型会从我用的 glm4.5 air 被
刷新为 glm5.3，你看下 app 崩溃与模型是不是有关系」。

结论写在 README 里：**跟崩溃没有因果关系** —— 崩溃只是顺带触发了一次整页
重载，而重载正是"模型下拉还没把值报上来"那个窗口出现的时候。不崩、手动刷新
一样会变。

两个真相源：
    users.llm_model                  ← **发消息用的就是它**（权威）
    user_api_keys(uid, 厂商).model    ← 按厂商存的**副本**
线上现场（uid=11）：两个都是 'glm-5.3'，而用户选的是 'glm-4.5-air'。
链条的三段（详见 README）：① 粘 Key 那个 observer 把当时的 input$model 写进
副本；② 用户改选之后**只有库被更新**，副本留在旧值 → 两边不一致；③ 下次
进页面，下拉还没报值 → 走兜底分支 → 而那个分支**只问副本、从来不问库**
→ 把副本里的旧值推给控件 → 800ms 后防抖把控件里的值**写回库**。

★ 这个探针要证的是**用户看得见的那一面**：自检那一节是"把 handler 抠出来在
  替身沙箱里跑"，它证不了"设置页在真浏览器里还能用、下拉里选得动、选完存得住"。
  本仓的规矩：「函数对」≠「界面对」。

三节：
  A 复现：库里/副本**分歧**时重载页面 → 下拉显示**库**那个，且库不被覆盖
  B 反向：① 库里的名字这家目录**不认** → 副本那一支还接得住（别修成死路）
          ② 用户在下拉里选一个有效的 → 存得住，**不许被库弹回去**
  C 出网：全程 base_url 指着本机假 LLM（一条请求都没打给真厂商）

⚠️ A 节**不能**证明"这次真的走了兜底分支"：如果控件把值报上来了，兜底根本
   不跑，而下拉显示的还是库里的值 —— 两种情况的界面**一模一样**。这个 bug 的
   判别力在自检那一节的酸测试里（撤掉修法 → 主案直接推出 [glm-5.3]）。
   这里的价值是另一面：**真浏览器里这条链路还活着**。

用法：
    bash tests/ui_v7/make_instance.sh 8932 /tmp/dsapp_v160
    python3 tests/ui_v157/probe_model.py
"""
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8932/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v160/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_v160_out")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as C                                     # noqa: E402
from probe_v157 import ensure_no_modal, relogin          # noqa: E402
from playwright.sync_api import sync_playwright          # noqa: E402

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def db_model(db, uid):
    r = sql(db, "SELECT llm_model FROM users WHERE id = ?", (uid,))
    return (r[0][0] or "") if r else ""


def db_base(db, uid):
    r = sql(db, "SELECT llm_base_url FROM users WHERE id = ?", (uid,))
    return (r[0][0] or "") if r else ""


def key_model(db, uid, vendor):
    r = sql(db, "SELECT model FROM user_api_keys WHERE user_id = ? AND vendor = ?",
            (uid, vendor))
    return (r[0][0] or "") if r else ""


def set_db_model(db, uid, val):
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute("UPDATE users SET llm_model = ? WHERE id = ?", (val, uid))
        con.commit()
    finally:
        con.close()


def set_key_model(db, uid, vendor, val):
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute("UPDATE user_api_keys SET model = ? WHERE user_id = ? "
                    "AND vendor = ?", (val, uid, vendor))
        con.commit()
    finally:
        con.close()


def sel_value(page, sel_id):
    """读 selectize 当前的值 —— 读它自己那个假输入框，不是原生 select。

    ⚠️ 原生 <select> 被 selectize 藏起来（0×0）之后**里面的选中项还是旧的**，
       直接读它得到的是一句"看着完全合理的错话"（本仓栽过：hidden-element-
       has-zero-rect / selectize-hides-options）。
    """
    return page.evaluate(
        """(id) => {
             var c = document.querySelector(
               "select#" + id + " + .selectize-control");
             if (!c) return "<没有 selectize 控件>";
             var it = c.querySelector(".selectize-input > input");
             if (it && it.value) return it.value;
             var d = c.querySelector(".selectize-input > div");
             if (d) return (d.getAttribute("data-value") || d.innerText || "").trim();
             return "";
           }""", sel_id)


def wait_dropdown(page, sel_id, want, timeout=20):
    """轮询到下拉显示 want 为止（服务端 updateSelectizeInput 是异步到的）。"""
    end = time.time() + timeout
    got = ""
    while time.time() < end:
        got = sel_value(page, sel_id)
        if got == want:
            return got
        page.wait_for_timeout(250)
    return got


def open_model_page(page):
    C.goto(page, "模型服务")
    ensure_no_modal(page)
    page.wait_for_timeout(1200)


def reload_page(page, email):
    """模拟"崩溃之后那一次重载"：整页重载 + 等界面回来。

    ⚠️⚠️ 这里**必须**用 relogin()，不能自己 `page.reload()` + `C.wait_awake()`。
       第一版就是这么写的，结果**卡满 150 秒后报「重载之后还是空白」** ——
       而屏幕上早就已经是主界面了：`wait_awake` 等的是 `.dsapp-auth`
       （**登录页**的标记），可重载时 cookie 还在，应用**直接进主界面**，
       登录页一帧都不出现。等一个永远不会来的东西，报错还指向"应用的界面没了"
       这个完全无关的方向。`relogin()` 等的是"两种情况里先到的那个"。
       （这条本仓已经记过两次了：_common.wait_awake 和 probe_v157.relogin
       的注释里都写着。）
    """
    relogin(page, email)
    page.wait_for_timeout(1500)


def main():
    os.makedirs(C.OUT, exist_ok=True)
    log = open(os.path.join(C.OUT, "probe_model.log"), "w")

    def say(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    fx = C.FakeLLM()
    say("  假 LLM: %s（这一节不靠它发消息，只借它当一个**不是真厂商**的地址）"
        % fx.url)

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        email = "v157m_%s@example.com" % str(int(time.time()))[-6:]
        try:
            C.enter_app(page, email=email)
        except SystemExit as e:
            sys.exit("注册没进去：%s" % e)
        uid, db = C.seed_or_die(email)
        # 厂商用 zhipu：它的静态清单里 **glm-5.3（第 1 个）和 glm-4.5-air 都在**，
        # 所以"换回第 1 个"这个旧行为在这家身上最容易观察。
        C.seed_llm(uid, fx.url, vendor="zhipu", model="glm-4.5-air")
        say("  uid=%s  db=%s" % (uid, db))
        relogin(page, email)
        ensure_no_modal(page)
        page.wait_for_timeout(1500)

        SEL = "model-model"          # ns("model") + "model"

        # ================= A 节：分歧 + 重载 → 库说了算 ====================
        say("\n== A 节：库 glm-4.5-air、副本 glm-5.3，重载页面 ==")
        set_db_model(db, uid, "glm-4.5-air")
        set_key_model(db, uid, "zhipu", "glm-5.3")
        m0, k0, b0 = db_model(db, uid), key_model(db, uid, "zhipu"), db_base(db, uid)
        chk("★ 前提：库/副本**真的是分歧的**（不然下面两条是白送的）",
            m0 == "glm-4.5-air" and k0 == "glm-5.3",
            "库=[%s] 副本=[%s]" % (m0, k0))
        chk("★★ 前提：base_url 指着本机假 LLM（出网只会打到假的）",
            b0 == fx.url, "base_url=[%s]" % b0)

        reload_page(page, email)
        open_model_page(page)
        got = wait_dropdown(page, SEL, "glm-4.5-air")
        chk("★★★ 用户看得见：下拉显示的是**库**里那个 glm-4.5-air",
            got == "glm-4.5-air", "下拉当前值=[%s]" % got)

        # 防抖 800ms + 落库 + 页面自己那几拍，给足余量再看库
        page.wait_for_timeout(4000)
        m1 = db_model(db, uid)
        chk("★★★ 回归本体：等过防抖之后，库**仍然是** glm-4.5-air"
            "（老代码这里会被副本的 glm-5.3 覆盖掉）",
            m1 == "glm-4.5-air", "库现在=[%s]" % m1)

        # ================= B 节：反向两条 ==================================
        say("\n== B 节①：库里的名字这家目录**不认** → 副本那一支要接得住 ==")
        # glm-9.9 不在 zhipu 的静态清单里 → 控件拿到的初始值就是无效的 →
        # **兜底分支必定会跑**（这一条才真的踩到了那段代码）。
        set_db_model(db, uid, "glm-9.9")
        set_key_model(db, uid, "zhipu", "glm-4.5-air")
        reload_page(page, email)
        open_model_page(page)
        got = wait_dropdown(page, SEL, "glm-4.5-air")
        chk("★★ 库里是清单不认的 glm-9.9 → 落到副本的 glm-4.5-air（这一支没被修死）",
            got == "glm-4.5-air", "下拉当前值=[%s]" % got)

        say("\n== B 节②：用户在下拉里选一个有效的 → 存得住，不许被弹回去 ==")
        set_db_model(db, uid, "glm-5.3")
        reload_page(page, email)
        open_model_page(page)
        got = wait_dropdown(page, SEL, "glm-5.3")
        chk("★ 前提：下拉先显示库里的 glm-5.3（认库）",
            got == "glm-5.3", "下拉当前值=[%s]" % got)
        try:
            C.pick_select(page, SEL, "glm-4.5-air")
        except Exception as e:
            say("    pick_select 抛了：%s" % e)
        page.wait_for_timeout(4000)
        m2 = db_model(db, uid)
        chk("★★★ 用户选了 glm-4.5-air → 库跟着变（用户的动作说了算）",
            m2 == "glm-4.5-air", "库现在=[%s]" % m2)

        # ================= C 节：出网 ======================================
        b1 = db_base(db, uid)
        chk("★★ 全程 base_url 没被改走（一条请求都没打给真厂商）",
            b1 == fx.url, "base_url=[%s]（假的是 %s）" % (b1, fx.url))

        browser.close()

    say("\n== 通过 %d / 失败 %d ==" % (N_OK[0], N_BAD[0]))
    log.close()
    sys.exit(0 if N_BAD[0] == 0 else 1)


if __name__ == "__main__":
    main()
