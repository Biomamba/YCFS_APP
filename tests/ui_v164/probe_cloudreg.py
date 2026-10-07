# -*- coding: utf-8 -*-
"""V16.4：云工具页那两块面板真的在用那两份**工具构建提示词**。

用户原话（2026-10-04）：

  1、「按照 /data3/biomamba/analysis/DS_App/skills_builtin/单细胞云平台Agent
     工具构建提示词.md 来优化单细胞云工具」
  2、「按照 TCGA数据库挖掘云平台Agent工具构建提示词.md 来优化 TCGA 数据挖掘
     模块」

改动本身是"把两份 .md 里的注册表解析出来、画在面板上、点哪一行就把那一个
工具的开场白发出去"。为什么**必须**有浏览器探针，`selftest.R` 那 40 条答不了
的是这五件事：

  · **渲染**：`dsapp_cloudreg_table()` 返回 58 行 ≠ 浏览器上画出来 58 行。
    选择器写错、`renderUI` 的输出名两处对不上、CSS 把它们压成 0 高 —— 三种
    都发生在"函数是对的"之后（本仓老账：自检全绿 ≠ 功能被验过，已栽四次）。
  · **那一页是前端切的**：三块面板一直留在 DOM 里、只切 `display:none`。
    自检里 grep 得到 `data-panel="tcga"`，但那块面板**看得见吗**只有浏览器
    知道。反过来，隐藏元素的矩形是**全 0**（本仓老账
    hidden-element-has-zero-rect），所以"藏起来了"也要单独判一次。
  · **点下去真的会开对话**：这条路是 JS 事件委托 → `Shiny.setInputValue`
    → `observeEvent(input$tool_go)` → `dsapp:lit_go` → mod_chat 建会话。
    五跳，每一跳都能**静默**断掉（`data-go` 名字对不上、nonce 没带、模块
    ns 写死、input 真名改了），而断掉的表现只是"点了没反应"。
  · **写进库里的东西对不对**：标题、开场白、挂上的技能。这三样都是**写操作**，
    按本仓纪律一律回库对账 —— "没写进去"和"没画出来"要分开报
    （限流/必填的拒绝长得像界面坏了，那条老账）。
  · **搜索框打字不丢焦点**：这一页的搜索框是**故意**留在静态 UI 里的
    （放进那个跟着 input 重画的 renderUI 的话，每敲一个字服务端重画一次
    输入框，焦点当场丢）。源码上"它在静态 UI 里"能 grep，**焦点丢没丢**
    只能真的一个字一个字敲。

⚠️ 本探针刻意**不**碰 V15.8/V16.1 已经钉过的东西（`tests/v158_cloudtool.R`
   那份、selftest 里 ⑥⑦ 两组）。重合的部分再钉一遍只是让两份记录互相牵着，
   改一处红两处。

跑法：
    bash tests/ui_v7/make_instance.sh 8973 /tmp/dsapp_v164a
    python3 tests/ui_v164/probe_cloudreg.py          # 退出码 0 = 全绿

⚠️ 端口是 **8973**：8971 上挂着 V16.3 那个实例（收尾要比对"老探针在上一版上
   红不红"，那份得留着），8972 是 V16.2 的对照实例。
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C                                     # noqa: E402
from playwright.sync_api import sync_playwright         # noqa: E402

OUT = C.OUT
FAIL = []
NCHECK = [0]

# 两份文档里署的工具数。selftest 那边数的是**解析器返回的行**，这边数的是
# 浏览器里真的画出来的节点 —— 两条路，同一个数。
WANT = {"tcga": 58, "sc": 49}
# 组数（`## X.`）：下拉里的选项 = 组数 + 1（「全部（按组看）」）
NGROUP = {"tcga": 11, "sc": 6}


def check(name, ok, extra=""):
    NCHECK[0] += 1
    print("  %s %s%s" % ("✅" if ok else "❌", name,
                         ("  — " + str(extra)) if extra else ""), flush=True)
    if not ok:
        FAIL.append(name)
    return ok


# =============================================================================
# 库
# =============================================================================
DBP = [None]


def q(sql, args=()):
    con = sqlite3.connect(DBP[0])
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def q1(sql, args=()):
    r = q(sql, args)
    return r[0][0] if r else None


def wait_db(fn, timeout=30, step=0.4):
    """等一个读库判据成立。

    ⚠️ 不用固定 sleep：写库是**服务端**做的，而它要等浏览器把 input 发上去、
       再走完建会话 / 挂技能 / 发消息三步。固定 sleep 要么白等，要么在慢机器
       上抢跑 —— 抢跑报出来的错会指向后面完全无关的地方（本仓老账
       fake-wait-is-not-a-wait：「等一行出现」写成「查得到行」= 没等）。
    """
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return None


def all_sids():
    return set(r[0] for r in q("SELECT id FROM sessions"))


def new_session(before):
    """比 before 多出来的那个会话 id（多出来不止一个时按 created_at 取最新）。"""
    extra = all_sids() - before
    if not extra:
        return None
    rows = q("SELECT id FROM sessions ORDER BY created_at DESC, rowid DESC")
    for (sid,) in rows:
        if sid in extra:
            return sid
    return None


def title_of(sid):
    r = q("SELECT title FROM sessions WHERE id = ?", (sid,))
    return r[0][0] if r else None


def user_msgs(sid):
    return [c for role, c in q("SELECT role, content FROM messages "
                               "WHERE session_id = ? ORDER BY id", (sid,))
            if role == "user"]


def skill_id(name):
    return q1("SELECT id FROM skills WHERE user_id IS NULL AND builtin = 1 "
              "AND name = ?", (name,))


def attached(sid):
    return [int(r[0]) for r in q("SELECT skill_id FROM session_skills "
                                 "WHERE session_id = ?", (sid,))]


# =============================================================================
# 页面
# =============================================================================
JS_SEEN = """(sel) => {
  const e = document.querySelector(sel);
  if (!e) return {found: false};
  const r = e.getBoundingClientRect();
  return {found: true, w: r.width, h: r.height, x: r.x, y: r.y};
}"""


def seen(pg, sel):
    """看得见吗：存在**且**矩形非零。

    ⚠️ 隐藏元素的矩形是**全 0**（本仓老账），所以"看不见"必须用矩形判；
       反过来 `offsetParent` 对 fixed 元素恒为 null，也不能拿它判"在不在"。
       两个方向各栽过一次，这里只认宽高。
    """
    d = pg.evaluate(JS_SEEN, sel)
    if not d.get("found"):
        return None
    return d if (d["w"] > 0 and d["h"] > 0) else None


def click_tile(pg, key):
    # ⚠️ 先清弹窗再点。⑤ 那一跳会**第一次**进对话页，新账号的
    #    「AI 怎么干活？」首选项弹窗就在那一刻盖上来，而且它盖的是**整页**、
    #    切页也不消失（rail 之间的切换是前端切的，没有 reload）。
    #    不在这里清的话，后面**每一个** click_tile 都会卡满 30 秒再报
    #    「<div id="shiny-modal"> intercepts pointer events」—— 报错指向的是
    #    那块 tile，跟真正的原因（一个首选项弹窗）隔着十万八千里。
    C.ensure_no_modal(pg)
    pg.click('.dsapp-cloud-tile[data-tool="%s"]' % key)
    pg.wait_for_timeout(800)


JS_TILES = """() => {
  const ts = [...document.querySelectorAll('.dsapp-cloud-tile')];
  const ps = [...document.querySelectorAll('.dsapp-cloud-panel')];
  const vis = (e) => { const r = e.getBoundingClientRect();
                       return r.width > 0 && r.height > 0; };
  return {tiles: ts.map(t => ({key: t.getAttribute('data-tool'),
                               act: t.classList.contains('is-active')})),
          panels: ps.map(p => ({key: p.getAttribute('data-panel'),
                                vis: vis(p),
                                hid: p.classList.contains('dsapp-cloud-hidden')}))};
}"""


def tile_stats(pg):
    return pg.evaluate(JS_TILES)


JS_ROWS = """(panel) => {
  const p = document.querySelector('.dsapp-cloud-panel[data-panel="' + panel + '"]');
  if (!p) return {found: false};
  const rows = [...p.querySelectorAll('.dsapp-cloud-tool')];
  return {found: true, n: rows.length,
          keys: rows.map(r => {
            const k = r.querySelector('.dsapp-cloud-tool-key');
            return k ? (k.innerText || '').trim() : '';
          }),
          alltxt: rows.map(r => (r.innerText || '').toLowerCase()),
          kinds: [...new Set(rows.map(r => {
            const b = r.querySelector('.dsapp-cloud-go');
            return b ? b.getAttribute('data-kind') : null;
          }))],
          btn: rows.length ? (rows[0].querySelector('.dsapp-cloud-go').innerText||'').trim() : '',
          // ⚠️ 这句提示要从**工具清单那个 output 里面**取：整块面板里有两个
          //    .dsapp-cloud-hint（上半页路线那条 + 这里"显示 N 个 / 共 M 个"），
          //    `panel.querySelector` 取到的是**上面**那条 —— 它永远不含
          //    "共 58 个"，判据会一直红，而报出来的字符串看着完全合理。
          hint: (function () {
            const o = document.getElementById('cloudtool-' + panel + '_rows');
            const h = o ? o.querySelector('.dsapp-cloud-hint') : null;
            return h ? (h.innerText || '') : '';
          })(),
          empty: (p.querySelector('.text-muted.small.py-2')||{}).innerText || ''};
}"""


def rows_of(pg, panel):
    return pg.evaluate(JS_ROWS, panel)


def wait_rows(pg, panel, pred, timeout=10.0):
    """等到清单**稳定**到满足 pred 再返回 —— 打完字/选完组之后服务端还要
    跑一趟才重画，这中间读到的是**上一次**的 DOM。

    ⚠️ 这不是"把红的等成绿的"：pred 一直不满足就等满 timeout，然后**把最后
       那一次的结果原样返回**，断言照红 —— 只是报出来的数从"像是筛选没生效"
       变成"等满 10 秒之后还是这样"。2026-10-05 实测：搜「zzzz」之后
       200ms 读到的是**没筛的 49 行**，而 400ms 时已经是 0 行 + 那句人话，
       差的就是这一趟往返。
    """
    end = time.time() + timeout
    r = rows_of(pg, panel)
    while time.time() < end and not pred(r):
        pg.wait_for_timeout(250)
        r = rows_of(pg, panel)
    return r


# ⚠️⚠️ selectize 那个控件**不是** select 的祖先：R 画出来的是
#     `<select id="x"></select><div class="selectize-control">…</div>` —— 两个
#     **兄弟**。所以 `.selectize-control:has(#x)` 永远匹配不到（量出来 0 个，
#     看着像"这个控件不存在"）。这里先给那个兄弟挂个临时 id，再用真鼠标点它。
def _ss_mount(pg, sel_id):
    pg.evaluate("""(id) => {
      const s = document.getElementById(id);
      if (!s || !s.parentElement) return false;
      const c = s.parentElement.querySelector('.selectize-control');
      if (!c) return false;
      c.id = 'dsapp-ss-' + id;
      return true;
    }""", sel_id)
    return "dsapp-ss-" + sel_id


def sel_options(pg, sel_id):
    """读一个 selectize 下拉的选项（**先把下拉打开**）。

    ⚠️⚠️ 必须打开：selectize 会把原生 select **清空**（只剩当前选中的那一项），
       选项是打开时才铺进 `.selectize-dropdown` 的（本仓老账
       selectize-hides-options）。不打开就读，读到 0 个 —— 而 0 个看起来跟
       "这个控件本来就是空的"一模一样。R 那一侧是对的（直接调函数有 12 个），
       浏览器这一侧必须先点开。
    """
    mnt = _ss_mount(pg, sel_id)
    pg.click("#%s .selectize-input" % mnt)
    pg.wait_for_timeout(800)
    d = pg.evaluate("""(a) => {
      const sel = document.getElementById(a[0]);
      const ctl = document.getElementById(a[1]);
      const dd = ctl ? ctl.querySelector('.selectize-dropdown') : null;
      const opts = dd ? [...dd.querySelectorAll('.option')] : [];
      return {found: !!sel, n: opts.length,
              texts: opts.map(o => (o.innerText||'').trim()),
              vals: opts.map(o => o.getAttribute('data-value')),
              raw: sel ? sel.options.length : -1};
    }""", [sel_id, mnt])
    return d


def close_ss(pg, sel_id):
    """把下拉收起来（点页面空白处，别点进别的控件）。"""
    pg.keyboard.press("Escape")
    pg.wait_for_timeout(300)


def pick_option(pg, sel_id, value):
    """在下拉里选一个值（按 data-value 点），选完把下拉关掉。"""
    mnt = _ss_mount(pg, sel_id)
    pg.click("#%s .selectize-input" % mnt)
    pg.wait_for_timeout(700)
    ok = pg.evaluate("""(a) => {
      const ctl = document.getElementById(a[1]);
      const dd = ctl ? ctl.querySelector('.selectize-dropdown') : null;
      if (!dd) return false;
      const o = dd.querySelector('.option[data-value="' + a[2] + '"]');
      if (!o) return false;
      o.click();
      return true;
    }""", [sel_id, mnt, value])
    pg.wait_for_timeout(1800)
    return ok


def type_q(pg, sel_id, text, per_char=350):
    """逐字敲进搜索框，返回**每次敲完之后**焦点还在不在这个框上。

    ★ 这是"搜索框留在静态 UI 里"那个设计的**唯一**判据：放进跟着 input
      重画的 renderUI 的话，服务端每收到一个字就重画一次输入框 —— 打第二个
      字的时候那个 <input> 已经被换掉了，焦点跟着没。源码上两处的
      `textInput()` 长得一模一样，只有真的敲才知道。
    """
    pg.locator("#" + sel_id).click()
    pg.wait_for_timeout(300)
    alive = []
    for ch in text:
        pg.keyboard.type(ch)
        pg.wait_for_timeout(per_char)
        cur = pg.evaluate("() => { const a = document.activeElement;"
                          " return a ? (a.id || a.tagName) : null; }")
        alive.append(cur == sel_id)
    return alive


def clear_q(pg, sel_id):
    pg.locator("#" + sel_id).click()
    pg.keyboard.press("Control+a")
    pg.keyboard.press("Backspace")
    pg.wait_for_timeout(1800)


# =============================================================================
def main():
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        ctx = br.new_context(viewport={"width": 1600, "height": 1000})
        pg = ctx.new_page()

        fx = C.FakeLLM()
        # 队列给足：这一跑会开 4 个对话，每个都会真的发一次请求。
        fx.set_queue(*[C.sse("好的，我按这份文档的规矩来做。")] * 8)

        try:
            C.enter_app(pg)
            uid, dbp = C.seed_or_die(C.LAST_EMAIL)
            DBP[0] = dbp
            print("账号 uid=%s，库=%s" % (uid, dbp), flush=True)
            C.seed_llm(uid, fx.url, vendor="deepseek", model="deepseek-flash")
            # ★ 种完必须 reload：state$vendor / state$base_url 是**会话开始
            #   那一刻**读一次的（本仓老账 seed-then-reload-and-firewall）。
            #   不 reload 的话，后面"点一行工具"发出去的请求会打到**厂商默认
            #   地址** —— 而探针照样全绿，因为库里那条消息是写进去了的。
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=60000)
            pg.wait_for_timeout(4000)
            C.ensure_no_modal(pg)

            # =============================================================
            print("\n=== ⓪ 连的是本版实例吗 ===", flush=True)
            # =============================================================
            ver = pg.evaluate(
                "() => { const e = document.querySelector('.dsapp-footer-ver');"
                " return e ? (e.innerText||'').trim() : null; }")
            check("⓪ 页脚版本号是 Test_V16.4（连错实例的话这一条先红）",
                  bool(ver) and "Test_V16.4" in ver, "页脚写着 %r" % ver)

            C.goto(pg, "云工具")
            pg.wait_for_timeout(2500)
            C.ensure_no_modal(pg)

            # =============================================================
            print("\n=== ① 三块面板：一次只看得见一块（前端切） ===", flush=True)
            # =============================================================
            st = tile_stats(pg)
            check("① 页面上有 3 块 tile、3 块面板",
                  len(st["tiles"]) == 3 and len(st["panels"]) == 3,
                  "tiles=%s panels=%s" % ([t["key"] for t in st["tiles"]],
                                          [p["key"] for p in st["panels"]]))
            vis0 = [p["key"] for p in st["panels"] if p["vis"]]
            check("① 进页面时只有一块面板看得见", len(vis0) == 1,
                  "看得见的是 %s" % vis0)
            for k in ("tcga", "sc"):
                click_tile(pg, k)
                st = tile_stats(pg)
                vis = [p["key"] for p in st["panels"] if p["vis"]]
                act = [t["key"] for t in st["tiles"] if t["act"]]
                check("① 点「%s」之后：那块看得见、另两块看不见、tile 高亮跟上"
                      % k, vis == [k] and act == [k],
                      "可见=%s 高亮=%s" % (vis, act))
                hid = [p["key"] for p in st["panels"] if (not p["vis"]) and p["hid"]]
                check("① 另外两块是**真的**被藏起来了（矩形 0 **且**带 hidden 类）",
                      len(hid) == 2, "藏起来的是 %s" % hid)

            # =============================================================
            print("\n=== ② 工具清单真的画出来了 ===", flush=True)
            # =============================================================
            for k in ("tcga", "sc"):
                click_tile(pg, k)
                r = rows_of(pg, k)
                check("② %s 面板上画出了 %d 行工具（文档里就是这个数）"
                      % (k, WANT[k]),
                      r.get("found") and r["n"] == WANT[k],
                      "实际 %s 行；提示原文=%r" % (r.get("n"), (r.get("hint") or "")[:40]))
                check("② %s 每一行都有工具名，按钮上写着「用这个工具」" % k,
                      bool(r.get("keys")) and all(r["keys"]) and
                      "用这个工具" in (r.get("btn") or ""),
                      "第一行 key=%r 按钮=%r" % ((r.get("keys") or [""])[0], r.get("btn")))
                check("② %s 每一行的 data-kind 都是 %s（前端就是靠它分流的）" % (k, k),
                      r.get("kinds") == [k], "实际 %s" % r.get("kinds"))

            # =============================================================
            print("\n=== ③ 按组筛选（selectize 要打开才读得到） ===", flush=True)
            # =============================================================
            click_tile(pg, "tcga")
            o = sel_options(pg, "cloudtool-tcga_group")
            # ⚠️ 判据写 `<= 1` 而不是 `== 0`：selectize 把原生 select 清成
            #    **只剩选中那一项**（这里是默认选中的「全部（按组看）」），
            #    不是全空。写 `== 0` 的话这条会一直红，而报出来的
            #    「原生 option 数=1」看着完全合理 —— 量出来的数是真的，
            #    红的原因是判据把 selectize 的行为记错了一格。
            check("③ 组下拉是 selectize（原生 select 里只剩选中那一项了，"
                  "所以选项要走 .selectize-dropdown 读）",
                  o["found"] and o["raw"] <= 1 and o["n"] > o["raw"],
                  "原生 option 数=%s，下拉里的 option 数=%s" % (o["raw"], o["n"]))
            check("③ 下拉里有 %d 个组 + 「全部」" % NGROUP["tcga"],
                  o["n"] == NGROUP["tcga"] + 1,
                  "%d 个：%s" % (o["n"], o["texts"][:3]))
            check("③ 选项的 value 是组字母（A、B…），不是序号",
                  "all" in o["vals"] and "A" in o["vals"] and "B" in o["vals"],
                  "%s" % o["vals"])
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(400)
            ok = pick_option(pg, "cloudtool-tcga_group", "C")
            r = wait_rows(pg, "tcga", lambda x: 0 < x["n"] < WANT["tcga"])
            check("③ 选 C 组之后行数真的变少了，且提示里写着「共 58 个」",
                  ok and 0 < r["n"] < WANT["tcga"] and "58" in (r.get("hint") or ""),
                  "选了 C：%s 行；%r" % (r["n"], (r.get("hint") or "")[:60]))
            c_keys = r.get("keys") or []
            check("③ 筛出来的是「生存分析与预后模型」那一组（不是别的组）",
                  len(c_keys) >= 5 and all(k.startswith("tcga_") for k in c_keys) and
                  any(("surv" in k or "km" in k or "cox" in k) for k in c_keys),
                  "%d 行：%s" % (len(c_keys), c_keys[:6]))
            pick_option(pg, "cloudtool-tcga_group", "all")
            r = wait_rows(pg, "tcga", lambda x: x["n"] == WANT["tcga"])
            check("③ 切回「全部」行数回到 58", r["n"] == WANT["tcga"], "%d 行" % r["n"])

            # =============================================================
            print("\n=== ④ 关键词筛选 + 打字不丢焦点 ===", flush=True)
            # =============================================================
            click_tile(pg, "sc")
            alive = type_q(pg, "cloudtool-sc_q", "Harmony", per_char=330)
            check("④ 连打 7 个字，**每一个**字之后焦点都还在搜索框里"
                  "（放进 renderUI 的话第二个字就丢）",
                  all(alive), "逐字焦点：%s" % alive)
            r = wait_rows(pg, "sc", lambda x: x["n"] < WANT["sc"])
            check("④ 打完字清单真的筛了（行数变少）",
                  r["n"] < WANT["sc"], "%d 行（共 %d）" % (r["n"], WANT["sc"]))
            check("④ 筛出来的**每一行**都真的含「harmony」"
                  "（拿每一行的全文判，不是只数行数）",
                  r["n"] > 0 and all("harmony" in t for t in r["alltxt"]),
                  "%d 行；不含的：%s"
                  % (r["n"], [k for k, t in zip(r["keys"], r["alltxt"])
                              if "harmony" not in t][:3]))
            # ★ 换一个只可能命中「功能 / 出参」那一列的词：命中列错位的话，
            #   画面上一样"有行"，只有搜一个功能里才有的词才分得出来。
            clear_q(pg, "cloudtool-sc_q")
            alive2 = type_q(pg, "cloudtool-sc_q", "monocle", per_char=330)
            r2 = wait_rows(pg, "sc", lambda x: x["n"] >= 1)
            check("④ 搜「monocle」（这个词在功能/出参列里，不在工具名里）也筛得出来",
                  r2["n"] >= 1 and all("monocle" in t for t in r2["alltxt"]),
                  "%d 行：%s" % (r2["n"], (r2.get("keys") or [])[:4]))
            check("④ 搜「monocle」时焦点同样没丢", all(alive2), "%s" % alive2)
            check("④ 搜索框里显示的就是刚敲进去的那串（输入没被服务端改掉）",
                  pg.input_value("#cloudtool-sc_q") == "monocle",
                  "框里=%r" % pg.input_value("#cloudtool-sc_q"))

            # =============================================================
            print("\n=== ⑤ 点一行工具 → 真的开了一个新对话（回库对账） ===",
                  flush=True)
            # =============================================================
            clear_q(pg, "cloudtool-sc_q")
            r = rows_of(pg, "sc")
            key0 = r["keys"][0]
            fn0 = pg.evaluate("""(k) => {
              const rows = [...document.querySelectorAll(
                '.dsapp-cloud-panel[data-panel="sc"] .dsapp-cloud-tool')];
              const row = rows.find(x => (x.querySelector(
                '.dsapp-cloud-tool-key').innerText||'').trim() === k);
              const f = row ? row.querySelector('.dsapp-cloud-tool-fn') : null;
              return f ? (f.innerText||'').trim() : null;
            }""", key0)
            before = all_sids()
            pg.click('.dsapp-cloud-panel[data-panel="sc"] .dsapp-cloud-tool:first-child '
                     '.dsapp-cloud-go')
            sid = wait_db(lambda: new_session(before), timeout=40)
            check("⑤ 点一行之后库里真的多了一个会话", bool(sid),
                  "会话数 %d → %d" % (len(before), len(all_sids())))
            ttl = title_of(sid) if sid else None
            check("⑤ 新会话的标题是「单细胞分析 · <那一行的功能>」",
                  bool(ttl) and "单细胞分析" in ttl and
                  (not fn0 or fn0[:24] in ttl),
                  "标题=%r；那一行的功能=%r" % (ttl, (fn0 or "")[:40]))
            um = user_msgs(sid) if sid else []
            check("⑤ 新会话里有一条 user 消息（开场白真的发出去了）",
                  len(um) >= 1, "%d 条 user 消息" % len(um))
            body = um[0] if um else ""
            check("⑤ 开场白点名了**这一个**工具（不是泛泛的一段话）",
                  key0 in body, "找 %r；开场白前 120 字：%r" % (key0, body[:120]))
            check("⑤ 开场白里点了技能名 —— 面板上「这套文档挂在你的技能里」"
                  "那句话才不是空话",
                  "单细胞云工具（全能力）" in body, "前 200 字：%r" % body[:200])
            check("⑤ 开场白里带着「不许假装检索过」那三条平台适配说明",
                  "不许假装检索过" in body, "前 300 字：%r" % body[:300])
            sk = attached(sid) if sid else []
            skid = skill_id("单细胞云工具（全能力）")
            check("⑤ 那条技能真的**挂进**了这个新对话（不是只写在提示词里）",
                  bool(skid) and int(skid) in sk,
                  "库里技能 id=%s；这个会话挂的=%s" % (skid, sk))
            pg.wait_for_timeout(2500)
            onchat = pg.evaluate(
                "() => { const a = document.querySelector('.dsapp-rail-link.active');"
                " return a ? a.getAttribute('data-nav') : null; }")
            check("⑤ 点完之后页面自己跳到了「言出法随」（而不是留在云工具页）",
                  onchat == "chat", "左栏高亮=%r" % onchat)
            # ★ 再点**同一行**一次：Shiny 对**相同**的值不重复触发事件
            #   （`Shiny.setInputValue` 老账），靠的就是那个 nonce。
            #   不量这一下的话，"连点两下第二下没反应"这种错法在别处全都看不出来。
            C.goto(pg, "云工具")
            pg.wait_for_timeout(2000)
            click_tile(pg, "sc")
            before_b = all_sids()
            pg.click('.dsapp-cloud-panel[data-panel="sc"] .dsapp-cloud-tool:first-child '
                     '.dsapp-cloud-go')
            sid_b = wait_db(lambda: new_session(before_b), timeout=40)
            check("⑤ 同一行**再点一次**又开出一个新会话（nonce 挡的正是"
                  "「相同值不触发」）",
                  bool(sid_b) and sid_b != sid,
                  "第二次开出来的是 %r" % (title_of(sid_b) if sid_b else None))

            # =============================================================
            print("\n=== ⑥ 点一条路线 → 也开对话，走的就是那一条 ===", flush=True)
            # =============================================================
            C.goto(pg, "云工具")
            pg.wait_for_timeout(2000)
            click_tile(pg, "tcga")
            rts = pg.evaluate("""() => {
              const p = document.querySelector('.dsapp-cloud-panel[data-panel="tcga"]');
              const bs = [...p.querySelectorAll('.dsapp-cloud-route-btn')];
              return {n: bs.length,
                      labels: bs.map(b => (b.innerText||'').trim()),
                      plans: bs.map(b => b.getAttribute('data-plan')),
                      texts: [...p.querySelectorAll('.dsapp-cloud-route-txt')]
                               .map(d => (d.innerText||'').trim())};
            }""")
            check("⑥ TCGA 面板上有 7 条路线按钮，编号 1..7",
                  rts["n"] == 7 and rts["plans"] == [str(i) for i in range(1, 8)],
                  "%d 条，plans=%s" % (rts["n"], rts["plans"]))
            check("⑥ 按钮上是短标签，正文另起一列（不是把整段话塞进按钮）",
                  bool(rts["labels"]) and all(len(x) < 30 for x in rts["labels"]) and
                  all(len(x) > 30 for x in rts["texts"]),
                  "标签=%s" % rts["labels"][:3])
            check("⑥ 路线正文是**完整的**（折行的续行接上了，以句号收尾）",
                  all(x.endswith("。") for x in rts["texts"]),
                  "%d/%d 条以句号结尾"
                  % (sum(x.endswith("。") for x in rts["texts"]), len(rts["texts"])))
            before2 = all_sids()
            pg.click('.dsapp-cloud-panel[data-panel="tcga"] '
                     '.dsapp-cloud-route:nth-child(3) .dsapp-cloud-route-btn')
            sid2 = wait_db(lambda: new_session(before2), timeout=40)
            check("⑥ 点第 3 条路线也开出了新会话", bool(sid2),
                  "标题=%r" % (title_of(sid2) if sid2 else None))
            ttl2 = title_of(sid2) if sid2 else None
            check("⑥ 标题是「TCGA 数据挖掘 · <那条路线的标签>」",
                  bool(ttl2) and ttl2.startswith("TCGA 数据挖掘 · ") and
                  (rts["labels"][2][:24] in ttl2),
                  "标题=%r；按钮上是 %r" % (ttl2, rts["labels"][2]))
            um2 = user_msgs(sid2) if sid2 else []
            b2 = um2[0] if um2 else ""
            check("⑥ 发出去的是**那一条路线**的正文全文（不是第 1 条、也不是截断的）",
                  bool(b2) and rts["texts"][2][:40] in b2,
                  "找 %r；消息前 160 字：%r" % (rts["texts"][2][:40], b2[:160]))
            sk2 = attached(sid2) if sid2 else []
            tkid = skill_id("TCGA 云工具（全能力）")
            check("⑥ TCGA 那条技能挂上了、**单细胞那条没挂**（挂串了就是跨模块串味）",
                  bool(tkid) and int(tkid) in sk2 and
                  int(skid) not in sk2,
                  "tcga 技能 id=%s / sc 技能 id=%s；这个会话挂的=%s"
                  % (tkid, skid, sk2))

            # =============================================================
            print("\n=== ⑦ 搜不到 / 面板切走再切回 / 兜底按钮 ===", flush=True)
            # =============================================================
            C.goto(pg, "云工具")
            pg.wait_for_timeout(2000)
            click_tile(pg, "sc")
            clear_q(pg, "cloudtool-sc_q")
            type_q(pg, "cloudtool-sc_q", "zzzz", per_char=200)
            r = wait_rows(pg, "sc", lambda x: x["n"] == 0)
            check("⑦ 搜不到时给一句人话（不是空白一片）",
                  r["n"] == 0 and "没有匹配的工具" in (r.get("empty") or ""),
                  "%d 行；提示=%r" % (r["n"], (r.get("empty") or "")[:60]))
            clear_q(pg, "cloudtool-sc_q")
            pg.fill("#cloudtool-sc_q", "Seurat")
            pg.wait_for_timeout(1200)
            click_tile(pg, "design")
            pg.wait_for_timeout(500)
            click_tile(pg, "sc")
            pg.wait_for_timeout(800)
            keep = pg.input_value("#cloudtool-sc_q")
            check("⑦ 面板切走再切回，搜索框里的字还在（面板只切 display，不重建）",
                  keep == "Seurat", "切回来后是 %r" % keep)
            clear_q(pg, "cloudtool-sc_q")
            before3 = all_sids()
            pg.click("#cloudtool-sc_go")
            sid3 = wait_db(lambda: new_session(before3), timeout=40)
            ttl3 = title_of(sid3) if sid3 else None
            check("⑦ 兜底按钮「开一个对话…」仍然能开（这是 V16.1 那条旧路）",
                  bool(sid3) and ttl3 == "单细胞分析", "标题=%r" % ttl3)

        finally:
            pg.screenshot(path=OUT + "/cloudreg_end.png", full_page=True)
            fx.stop()
            br.close()

    print("\n== %d 条断言，%d 条红 ==" % (NCHECK[0], len(FAIL)), flush=True)
    for f in FAIL:
        print("   ❌ %s" % f, flush=True)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
