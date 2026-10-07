# -*- coding: utf-8 -*-
"""V16.3 item 7：**选完厂商就刷新可用模型清单**。

用户原话：「现在的逻辑是api key有效才会弹出模型选择列表，能不能选择厂商后
就刷新可选模型列表？」

病根（改之前）：模型下拉的内容有两个来源 —— ① 目录里写死的静态清单
（`fallback_models`），② 现场从厂商 `/models` 拉的活清单。而 ② 只有**一个**
入口：手点「获取模型」。中转站 / 自定义这两类的静态清单是**空的**
（`fallback_models = character(0)`，见 R/models.R），所以"选了厂商"和"看到这一家
有哪些模型"之间隔着一个用户没理由知道的按钮。

这条探针要证明三件事，缺一条都不算修好：

  ① 选完厂商**不用点任何按钮**，下拉框里就出现这一家的活清单 ——
     而且必须是**这一家**的（假服务端按厂商给了不同的名字，张冠李戴看得出来）。
  ② 该拉的时候拉、不该拉的时候**一次都不发**：
       · 没有 Key 也没有地址的厂商（custom）→ 一个请求都不该出去；
       · 进页面时厂商本来就有静态清单（deepseek）→ 也不该白拉一次。
     这两条是"自动"这个词的代价：不加闸门的话，用户什么都没干，
     页面就会自己往厂商接口上打请求、自己弹红字。
  ③ ★ 竞态：A 家的应答**后到**时，不能顶掉 B 家已经显示出来的清单。
     这是 item 7 新开出来的一条路 —— 自动拉让"发出去还没回来就换了厂商"
     从罕见变成了常规。造法：把 relay 的 /models 拖慢 4 秒，切过去之后
     立刻切到 custom（custom 没 Key → 不会发新请求、也就不会打断 relay
     那一次），于是 relay 的应答在 custom 已经选中之后才落地。
     ⚠️ 这一条**能分辨修没修**：旧代码盖章用的是"应答落地那一刻的
        input$vendor"，这份 relay 的清单会被盖上 custom 的章、显示在 custom
        的下拉里 —— 加了 `identical(res$vendor, input$vendor)` 才拦得住。

跑法：
    bash tests/ui_v7/make_instance.sh 8971 /tmp/dsapp_v163a
    python3 tests/ui_v163/probe_item7.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
FAIL = []
NCHECK = [0]

# 每个厂商给一组**只属于它**的名字。断言就靠这几个字符串认人：
# 用"下拉里有没有东西"当判据的话，"显示的是别家的清单"也会通过。
REL = ["relay-alpha", "relay-beta", "relay-gamma"]
ZD  = ["zerod-one", "zerod-two"]


def check(name, ok, extra=""):
    NCHECK[0] += 1
    print("  %s %s%s" % ("✅" if ok else "❌", name,
                         ("  — " + extra) if extra else ""), flush=True)
    if not ok:
        FAIL.append(name)
    return ok


# 读模型下拉的 options。⚠️ 必须读 selectize 实例，不能读原生 <select>：
# 原生那个被 selectize 清空/隐藏了（本仓的老账，见 selectize-hides-options）。
READ = """() => {
  var el = document.getElementById('model-model');
  if (!el) return {err: 'no el'};
  var inst = el.selectize;
  if (!inst) return {err: 'no selectize'};
  return {value: inst.getValue(), opts: Object.keys(inst.options || {})};
}"""


def opts(pg):
    d = pg.evaluate(READ)
    return d.get("opts") or []


def pick_vendor(pg, v):
    """选厂商，并且**回读确认真的是这一家**。

    ⚠️ 为什么非要回读：`_common.pick_select()` 在 data-value 找不到精确匹配时，
       会退回"按文字找 option"，再找不到就点**第一个** —— 那一刻选中的是别家，
       而它一声不吭。这条探针的第一版就把厂商名写成了 `0dayssci`（目录里的真名
       是 `0daysci`，少一个 s），于是种子往一个**不存在的厂商**名下写了把 Key，
       点选时又"成功"选中了列表第一项（0daysci 以数字开头，正好排在最前），
       最后报出来的是「切到 0daysci 之后清单是空的」—— 看着像应用的 bug，
       实际是探针自己拼错了名字，应用那边（没 Key 就不发请求）是对的。
    """
    C.pick_select(pg, "model-vendor", v)
    got = pg.evaluate(
        "() => { var el = document.getElementById('model-vendor');"
        " return el && el.selectize ? el.selectize.getValue() : null; }")
    if got != v:
        sys.exit("❌ pick_vendor(%r)：控件里现在是 %r —— 名字写错了。"
                 "厂商名以下拉里的 data-value 为准（见 R/models.R 的目录键）。"
                 % (v, got))


def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()

        fx_relay = C.FakeLLM()
        fx_0d = C.FakeLLM()
        fx_ds = C.FakeLLM()          # 不配 models.json → /models 回 501
        fx_relay.serve_models(REL)
        fx_0d.serve_models(ZD)

        try:
            C.enter_app(pg)
            uid, dbp = C.seed_or_die(C.LAST_EMAIL)
            print("账号 uid=%s，库=%s" % (uid, dbp), flush=True)
            # 三家各存一把 Key + 地址。**最后一次**写的是 users.llm_vendor，
            # 也就是进页面时选中的那一家 —— 用 deepseek（有静态清单）来验
            # "有静态清单就不白拉"那一条闸门。
            C.seed_llm(uid, fx_relay.url, vendor="relay", model=REL[0])
            C.seed_llm(uid, fx_0d.url, vendor="0daysci", model=ZD[0])
            C.seed_llm(uid, fx_ds.url, vendor="deepseek", model="deepseek-flash")

            # ★ 种完必须 reload：state$vendor / state$base_url 是**会话开始
            #   那一刻**读一次的（本仓的老账）。
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=60000)
            pg.wait_for_timeout(4000)
            C.ensure_no_modal(pg)
            C.goto(pg, "model")
            pg.wait_for_timeout(1500)

            # ---- ③ 闸门：有静态清单的厂商，进页面不白拉 -------------------
            n_ds0 = fx_ds.models_n()
            check("进页面（deepseek，有静态清单）没有自动拉 /models",
                  n_ds0 == 0, "models_n=%d" % n_ds0)
            check("静态清单照常在（deepseek 的下拉不是空的）",
                  len(opts(pg)) >= 1, str(opts(pg)))

            # ---- ① 切到 relay：不点任何按钮，清单自己出现 -----------------
            pick_vendor(pg, "relay")
            pg.wait_for_timeout(6000)
            o = opts(pg)
            check("① 切到 relay 后下拉里出现了**厂商返回的**模型名",
                  all(m in o for m in REL), str(o))
            check("① 而且确实是从 relay 的地址拉的（假服务端收到过 /models）",
                  fx_relay.models_n() >= 1, "models_n=%d" % fx_relay.models_n())
            check("① 没有打到别家去",
                  fx_ds.models_n() == 0 and fx_0d.models_n() == 0,
                  "ds=%d 0d=%d" % (fx_ds.models_n(), fx_0d.models_n()))
            # 自动拉也要有回执：界面上得说一句"取回了 N 个模型"，不然用户
            # 分不清"下拉框里这几个名字是厂商给的"还是"代码里写死的"。
            txt = pg.evaluate("() => document.body.innerText") or ""
            check("① 界面上有一句取回结果（用户看得见这次自动查询发生了）",
                  "取回" in txt)
            pg.screenshot(path="%s/item7_relay自动出清单.png" % OUT)

            # ---- ② 闸门：没 Key 没地址的厂商，一个请求都不发 ---------------
            before = (fx_relay.models_n(), fx_0d.models_n(), fx_ds.models_n())
            pick_vendor(pg, "custom")
            pg.wait_for_timeout(4000)
            after = (fx_relay.models_n(), fx_0d.models_n(), fx_ds.models_n())
            check("② 切到 custom（没 Key、没地址）之后没有发出任何 /models 请求",
                  before == after, "%s -> %s" % (before, after))
            o = opts(pg)
            check("② 上一家的清单没有赖在下拉里",
                  not any(m in o for m in REL), str(o))
            txt = pg.evaluate("() => document.body.innerText") or ""
            check("② 界面把「为什么是空的」说出来了",
                  "没有内置的模型清单" in txt)
            pg.screenshot(path="%s/item7_custom_空清单有解释.png" % OUT)

            # ---- ③ 竞态：A 的应答后到，不许顶掉 B -------------------------
            # 把 relay 的应答拖慢到 4 秒，再切过去；0.6 秒后切到 custom。
            fx_relay.serve_models(REL, delay=4.0)
            n_before = fx_relay.models_n()
            pick_vendor(pg, "relay")
            pg.wait_for_timeout(600)
            pick_vendor(pg, "custom")
            # 等到 relay 那次请求**已经发出**（服务端计数在 sleep 之前就加），
            # 再留够它落地 + 一轮渲染的时间。
            t0 = time.time()
            while fx_relay.models_n() == n_before and time.time() - t0 < 10:
                time.sleep(0.2)
            check("③ 竞态的前半段成立：relay 的那次请求确实发出去了",
                  fx_relay.models_n() > n_before,
                  "models_n=%d" % fx_relay.models_n())
            pg.wait_for_timeout(7000)      # 4 秒的应答 + 轮询 + 渲染
            o = opts(pg)
            check("③ relay 的应答后到，但没有被当成 custom 的清单画出来",
                  not any(m in o for m in REL), str(o))
            txt = pg.evaluate("() => document.body.innerText") or ""
            check("③ 也没有假的好消息「Key 有效，取回 N 个模型」",
                  "Key 有效" not in txt)
            pg.screenshot(path="%s/item7_竞态后到的应答没顶掉.png" % OUT)

            # ---- ① 收尾：再切到 0daysci，清单要换成这一家的 ----------------
            pick_vendor(pg, "0daysci")
            pg.wait_for_timeout(6000)
            o = opts(pg)
            check("① 切到 0daysci 后下拉里是**这一家**的模型",
                  all(m in o for m in ZD), str(o))
            check("① 而且 relay 那批名字一个都不在",
                  not any(m in o for m in REL), str(o))
            check("① 0daysci 的地址确实被请求过",
                  fx_0d.models_n() >= 1, "models_n=%d" % fx_0d.models_n())
            pg.screenshot(path="%s/item7_0daysci.png" % OUT)

        finally:
            for fx in (fx_relay, fx_0d, fx_ds):
                fx.stop()
            br.close()

    print("\n=== %d 条断言，%d 条没过 ===" % (NCHECK[0], len(FAIL))
          + ("" if not FAIL else "：%s" % " / ".join(FAIL)), flush=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
