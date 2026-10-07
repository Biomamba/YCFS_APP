#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Test_V16.11 item 6：用户须知的**层次**在屏幕上真的分得出来吗？

用户原话：「6、登录时用户需要确认的信息只有二级标题，请生成对应的一级标题」

改法是：正文里加 4 个 `#` 一级分组（第一部分…第四部分）把十个 `##` 章归纳成
四块，同时把 `www/app.css` 里原来"h1~h6 共用一条规则"拆成三档字号。

⚠️⚠️ 这个探针要挡的是一个**特别容易白送**的假绿：

    只量"三个层级的字号互不相同、而且从大到小"是不够的 —— **浏览器默认样式
    本身就满足它**！Bootstrap 的 reboot 给 h1 2em、h2 1.5em，就算我们的
    `.dsapp-tos-md h1 {…}` 一条都没生效（选择器写错、文件没更新、被后面的
    规则盖掉），量出来照样是"不同且从大到小"。

    所以判据是**绝对像素值**（rem × 根字号），外加一条"这条规则确实在
    document.styleSheets 里"。浏览器默认值（32/24/18.75px）和我们的
    （17/15/14px）差着一倍，混不过去。

两幕：
  A 注册页里的须知（`R/mod_welcome.R:420` 那块，未登录就能到）
  B 登录后的「用户须知」闸门页（`dsapp_tos_gate_ui`）—— 用户说的"登录时"
    就是这一页；而且**这一版所有人都要重新过一次**（正文指纹变了）

用法：
    bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
    cp www/app.css /tmp/dsapp_v158h/app/www/
    cp R/tos.R     /tmp/dsapp_v158h/app/R/
    cp data/user_must_know_V1.txt /tmp/dsapp_v158h/data/
    # ⚠️ R/*.R 是 worker 启动时 source 一次的，必须重启实例；www/ 刷新即可
    python3 tests/ui_v1611/probe_tos.py
"""
import os
import sqlite3
import sys
import time

os.environ.setdefault("DSAPP_TEST_URL", "http://127.0.0.1:8953/")
os.environ.setdefault("DSAPP_TEST_APP", "/tmp/dsapp_v158h/app")
os.environ.setdefault("DSAPP_TEST_OUT", "/tmp/dsapp_ui_v1611")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "ui_v158"))

import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

chk = C.Chk()
os.makedirs(C.OUT, exist_ok=True)

TAG = str(int(time.time()))[-6:]
EMAIL = "v1611tos_%s@example.com" % TAG

# 三档的**期望值**（rem 字面量，和 www/app.css 里写的一一对上）。
# ⚠️ 期望值写成 rem 而不是 px：根字号不一定是 16px（用户缩放过、或者以后
#    有人在 html 上写了 font-size）。量出来的 px 要跟 root_fs × 这个数比。
EXPECT = {
    "doc": 1.0625,   # .dsapp-tos-md > h1:first-child  文档题
    "grp": 0.9375,   # .dsapp-tos-md h1                四个分组
    "h2":  0.8750,   # .dsapp-tos-md h2, … h6          十个章
    "p":   0.8125,   # .dsapp-tos-md                   正文
}
# 浏览器/Bootstrap 默认会给出的 h1/h2 字号（em 倍数）—— 拿来做**负对照**：
# 量出来的数要是落在这附近，说明分层是**默认样式**给的，不是我们的 CSS。
DEFAULT_H1_EM = 2.0
DEFAULT_H2_EM = 1.5

# 在浏览器里把三个层级量一遍。返回的是**原始数据**，判据留在 Python 里 ——
# 免得"量"和"判"写在同一段 JS 里，红了看不出是量的那步错了还是判的那步错了。
MEASURE_JS = r"""
() => {
  const boxes = [...document.querySelectorAll('.dsapp-tos-md')]
      .filter(e => e.getBoundingClientRect().width > 0);
  if (!boxes.length) return {err: '页面上没有可见的 .dsapp-tos-md'};
  const box = boxes[0];
  const cs = e => window.getComputedStyle(e);
  const h1 = [...box.querySelectorAll('h1')];
  const h2 = [...box.querySelectorAll('h2')];
  const ps = [...box.querySelectorAll('p')];
  const one = e => ({text: (e.textContent || '').trim().slice(0, 24),
                     fs: parseFloat(cs(e).fontSize),
                     fw: cs(e).fontWeight});
  // 这条规则**在不在已生效的样式表里** —— 光看文件里有不算，
  // 文件没被加载、被后面的规则盖掉、选择器打错，都会在文件里"有"。
  let ruleInSheets = false;
  try {
    for (const ss of document.styleSheets)
      for (const r of ss.cssRules)
        if (r.selectorText === '.dsapp-tos-md > h1:first-child') ruleInSheets = true;
  } catch (e) { /* 跨域样式表读 cssRules 会抛，忽略 */ }
  return {
    root_fs: parseFloat(cs(document.documentElement).fontSize),
    n_h1: h1.length, n_h2: h2.length, n_p: ps.length,
    first_child: box.firstElementChild ? box.firstElementChild.tagName : null,
    h1: h1.map(one), h2: h2.map(one), p: ps.length ? one(ps[0]) : null,
    rule_in_sheets: ruleInSheets,
  };
}
"""


def measure(page, where):
    """量一次，并把原始数据打出来（红了才有现场可看）。"""
    d = page.evaluate(MEASURE_JS)
    say("  [%s] 量到：%r" % (where, {k: v for k, v in d.items()
                                    if k not in ("h1", "h2")}))
    return d


def say(*a):
    print(*a, flush=True)


def read_sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def write_sql(db, q, args=()):
    # ⚠️ 探针要**写**一次库（把新号退回旧 key 好复现闸门）。
    #    probe_ctx.sql() 是只读的（只 fetchall、不 commit），别拿它来写。
    con = sqlite3.connect(db, timeout=15)
    try:
        con.execute(q, args)
        con.commit()
    finally:
        con.close()


def check(d, where):
    """一条数据、一套判据，两幕共用。"""
    if d.get("err"):
        chk("%s：页面上有可见的须知正文" % where, False, d["err"])
        return
    chk("%s ① 结构：1 个文档题 + 4 个分组 = 5 个 <h1>，10 个 <h2>" % where,
        d["n_h1"] == 5 and d["n_h2"] == 10,
        "n_h1=%r n_h2=%r 前三个 h1=%r" % (d["n_h1"], d["n_h2"],
                                       [h["text"] for h in d["h1"][:3]]))
    chk("%s ② 文档题是**第一个孩子**（CSS 那条规则按 :first-child 认它）"
        % where, d["first_child"] == "H1", "firstElementChild=%r" % d["first_child"])
    chk("%s ③ 那条 `> h1:first-child` 规则确实在生效的样式表里" % where,
        d["rule_in_sheets"] is True, "rule_in_sheets=%r" % d["rule_in_sheets"])

    root = d["root_fs"]
    def px(k):
        return EXPECT[k] * root

    got = {
        "doc": d["h1"][0]["fs"] if d["h1"] else None,
        "grp": d["h1"][1]["fs"] if len(d["h1"]) > 1 else None,
        "h2":  d["h2"][0]["fs"] if d["h2"] else None,
        "p":   d["p"]["fs"] if d["p"] else None,
    }
    want = {k: px(k) for k in EXPECT}
    # ★★ 判据是**绝对像素**，不是"互不相同"。理由见文件头：只判不同的话，
    #    浏览器默认样式（h1 2em=32px / h2 1.5em=18.75px）会白送一个绿。
    chk("%s ④ ★★ 三档字号**等于** CSS 里写的值（不是浏览器默认给的）" % where,
        all(got[k] is not None and abs(got[k] - want[k]) < 0.51 for k in want),
        "量到 %r / 期望 %r（根字号 %r px）" % (got, want, root))
    # 负对照：万一定到默认值附近，把这句话打出来省一轮排查。
    if got["doc"] is not None and abs(got["doc"] - DEFAULT_H1_EM * root) < 0.51:
        say("      ⚠️★ h1 量到了浏览器默认的 %.4gem —— 我们那条规则**没生效**"
            % DEFAULT_H1_EM)
    if got["h2"] is not None and abs(got["h2"] - DEFAULT_H2_EM * root) < 0.51:
        say("      ⚠️★ h2 量到了浏览器默认的 %.4gem —— 我们那条规则**没生效**"
            % DEFAULT_H2_EM)

    chk("%s ⑤ 三档严格递减：文档题 > 分组 > 章 > 正文" % where,
        got["doc"] and got["grp"] and got["h2"] and got["p"] and
        got["doc"] > got["grp"] > got["h2"] > got["p"],
        "doc=%r grp=%r h2=%r p=%r" % (got["doc"], got["grp"], got["h2"], got["p"]))
    chk("%s ⑥ 分组的字重比章重（只差字号的话在 13~15px 这档看不出来）" % where,
        d["h1"][1]["fw"] == "700" and d["h2"][0]["fw"] == "600",
        "grp.fw=%r h2.fw=%r" % (d["h1"][1]["fw"], d["h2"][0]["fw"]))
    # 十个章和四个分组的字号**各自一致** —— 盯"改了一条漏了另一条"
    chk("%s ⑦ 四个分组字号一致、十个章字号一致" % where,
        len({h["fs"] for h in d["h1"][1:]}) == 1 and
        len({h["fs"] for h in d["h2"]}) == 1,
        "grp=%r h2=%r" % ({h["fs"] for h in d["h1"][1:]},
                          {h["fs"] for h in d["h2"]}))


def main():
    log = open(os.path.join(C.OUT, "probe_tos.log"), "w")
    ts = lambda *a: (print(*a, flush=True), print(*a, file=log, flush=True))
    say("实例 %s\n输出 %s\n账号 %s\n" % (C.URL, C.OUT, EMAIL))

    with sync_playwright() as pw:
        br = pw.chromium.launch(args=["--no-sandbox"])
        page = br.new_page(viewport={"width": 1280, "height": 900})
        page.on("console", lambda m: ts("  [console.%s] %s" % (m.type, m.text))
                if m.type in ("error", "warning") else None)

        # ---- 前置：服务的那份 app.css 必须**已经是新版** -------------------
        # ⚠️ 这一条不加的话，「改了 www/ 忘了拷进实例」会让你量到一整套
        #    完全合理的旧数值，然后得出一个方向完全相反的结论。
        css = page.request.get(C.URL + "app.css")
        body = css.text()
        chk("前置①：服务的那份 app.css 含新规则 `> h1:first-child`",
            ".dsapp-tos-md > h1:first-child" in body, "HTTP %d" % css.status)
        chk("前置②：app.css 里 h1 和 h2 是**两条不同**的字号",
            ".dsapp-tos-md h1 {" in body and ".dsapp-tos-md h2," in body,
            "h1 规则=%r" % (".dsapp-tos-md h1 {" in body))

        # ---- 幕 A：注册页 ---------------------------------------------------
        page.goto(C.URL, wait_until="domcontentloaded")
        if not C.wait_awake(page):
            sys.exit("实例没醒")
        page.wait_for_selector(".dsapp-auth", timeout=30000)
        page.wait_for_timeout(1500)
        if page.locator("#welcome-nickname").count() == 0:
            page.click("#welcome-go_register")
            page.wait_for_selector("#welcome-nickname", timeout=15000)
            page.wait_for_timeout(1500)
        d_a = measure(page, "幕A 注册页")
        check(d_a, "幕A 注册页")
        page.screenshot(path=os.path.join(C.OUT, "A_register_tos.png"),
                        full_page=True)

        # ---- 幕 B：登录后的须知闸门 ----------------------------------------
        # ★ 这一版真正的用户后果是：**正文指纹变了 ⇒ 所有老用户的同意作废
        #   ⇒ 下次进来被闸门拦住重新确认**。所以要复现的不是"注册新号"
        #   （新号在注册页勾了框就当场记了同意，根本不会撞闸门 —— 第一版
        #     探针就是这么写错的，量到的是"闸门没出现"，看着像功能坏了）。
        #   复现办法：正常注册 → 把这个号的 tos_version 改回**旧 key**
        #   → reload。这和 26 个老账号库里的状态一模一样。
        page.fill("#welcome-nickname", "V1611须知")
        page.fill("#welcome-email", EMAIL)
        page.fill("#welcome-phone", "13800000009")
        page.fill("#welcome-field", "转录组")
        page.fill("#welcome-password", C.PW)
        cb = page.locator("#welcome-tos_agree")
        if cb.count() and not cb.is_checked():
            cb.check()
        page.click("#welcome-do_register")
        page.wait_for_selector("#welcome-enter_app", timeout=40000)
        page.click("#welcome-enter_app")
        for _ in range(120):
            page.wait_for_timeout(1000)
            if page.locator(".dsapp-shell").count():
                break

        db = C.db_path()
        say("  实例库 %s" % db)
        # ① 注册时勾了框 ⇒ 库里应当**当场**记成**当前**那个 key（含新指纹）
        cur = read_sql(db, "SELECT tos_version FROM users WHERE email = ?",
                      (EMAIL,))
        chk("★★ 幕B：注册页勾一下，库里当场记的就是**新** key（2.1+指纹）",
            cur and str(cur[0][0]).startswith("2.1+"),
            "tos_version=%r" % (cur,))
        new_key = str(cur[0][0]) if cur else ""

        # ② 把这个号退回旧 key（= 26 个老账号现在的状态）
        write_sql(db, "UPDATE users SET tos_version = ? WHERE email = ?",
                  ("2.0+de2e9702", EMAIL))

        page.reload(wait_until="domcontentloaded")
        ok = False
        for _ in range(120):
            page.wait_for_timeout(1000)
            if page.locator("#tos_gate-do_agree").count():
                ok = True
                break
            if page.locator(".dsapp-shell").count():
                break
        chk("★★ 幕B：同意的版本一过期，登录后**真的**被闸门拦住（老用户的实际遭遇）",
            ok, "既没有 #tos_gate-do_agree 也没有 .dsapp-shell，"
                "页面文字 %d 字" % len(page.inner_text("body")))
        if not ok:
            page.screenshot(path=os.path.join(C.OUT, "B_no_gate.png"),
                            full_page=True)
        else:
            page.wait_for_timeout(2000)
            txt = page.inner_text("body")
            # ③ 闸门那句自己报的版本要**自洽**。「同意的是 X 版，当前是 Y 版」
            #    里 X≠Y 才算说清楚了；都印成一样的话用户只会问"那到底变没变"。
            chk("★★ 幕B：页面上那句「同意的是 2.0 版，当前是 2.1 版」"
                "**自洽**（没抬版本号的话这里会印成 2.0/2.0）",
                "同意的是 2.0 版，当前是 2.1 版" in txt,
                "页面里带『同意的是』的那句：%r"
                % [l.strip() for l in txt.splitlines() if "同意的是" in l])
            d_b = measure(page, "幕B 闸门页")
            check(d_b, "幕B 闸门页")
            page.screenshot(path=os.path.join(C.OUT, "B_gate_tos.png"),
                            full_page=True)
            # ④ 同意之后：进得去 + 库里记成新 key
            c = page.locator("#tos_gate-agree")
            if c.count() and not c.is_checked():
                c.check()
            page.click("#tos_gate-do_agree")
            for _ in range(60):
                page.wait_for_timeout(1000)
                if page.locator(".dsapp-shell").count():
                    break
            chk("★ 幕B 收尾：同意之后进得了主界面",
                page.locator(".dsapp-shell").count() > 0,
                "页面文字 %d 字" % len(page.inner_text("body")))
            after = read_sql(db, "SELECT tos_version FROM users WHERE email = ?",
                            (EMAIL,))
            chk("★★ 幕B 收尾：库里换成了新 key（不是「点了没记」）",
                after and str(after[0][0]) == new_key,
                "库里=%r 期望=%r" % (after, new_key))

        page.close()
        br.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
