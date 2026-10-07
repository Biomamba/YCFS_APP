# -*- coding: utf-8 -*-
"""V13.2 item 3 / 4 / 8：卡片里的内容被压扁 / 被兄弟元素盖住。

用户的原话：
  item 3「历史任务的"重跑、停止、删除选中、共享"按钮会与执行记录表格堆叠」
  item 4「"停止」停的是**当前正在执行**"没有渲染成功」
  item 8「服务器健康界面的自适应有问题，只能看到前面一行了，下面的 token
          用量、用户等界面的自适应也出问题了」

★ 这三条是**同一个根因**，所以放在一个脚本里量：

  bslib 的 `card_body()` 默认 `fillable = TRUE`，于是卡体是个 flex 列
  （`.html-fill-container`），而 htmltools 的 fill.css 让带 `html-fill-item`
  的孩子变 `flex:1 1 auto; min-height:0`。DT 的表格恰好带这个类，还额外有
  `.html-fill-container > .html-fill-item.datatables{flex-basis:400px}`
  （DT 自己那条注释写的就是这个死结）。结果是**表格成了卡体里唯一能伸缩的
  孩子**：高度不够时它缩到内容高度以下，画在后面那些 `flex:0 0 auto` 的
  兄弟（按钮行、提示文字）身上。

  ⚠️ 光看"文字在不在页面上"是抓不到的 —— `inner_text("body")` 读的是 DOM
     文本，被压住、被盖住、溢出到裁剪区外的文字**照样读得到**。
     tests/ui_smoke.py 就是这么查的，所以它一直是绿的。这里必须量**几何**。

量什么：对每个相关元素取 getBoundingClientRect + clientHeight/scrollHeight，
然后判两件事 ——
  (a) 兄弟元素之间**不许重叠**（矩形相交）；
  (b) 元素不许被祖先裁剪掉（元素的矩形要落在最近那个 overflow != visible
      的祖先的矩形里）。
"""
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, goto, seed_or_die  # noqa: E402

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

# 量一个元素：矩形 + 自身的滚动状态 + 最近裁剪祖先是谁、裁掉了多少。
PROBE_JS = r"""
(sel) => {
  const el = document.querySelector(sel);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  // 往上找第一个会裁剪的祖先
  let clipper = null, p = el.parentElement;
  while (p) {
    const cs = getComputedStyle(p);
    if (cs.overflowY !== 'visible' || cs.overflowX !== 'visible') { clipper = p; break; }
    p = p.parentElement;
  }
  let clip = null;
  if (clipper) {
    const cr = clipper.getBoundingClientRect();
    // 这个元素有多少像素落在裁剪区之外（下沿最要紧，卡片是往下裁的）
    clip = {
      tag: clipper.tagName + '.' + (clipper.className || '').toString().split(' ')[0],
      below: Math.round(r.bottom - cr.bottom),   // >0 = 下沿被裁掉这么多
      above: Math.round(cr.top - r.top),
    };
  }
  return {
    rect: {top: Math.round(r.top), bottom: Math.round(r.bottom),
           left: Math.round(r.left), right: Math.round(r.right),
           w: Math.round(r.width), h: Math.round(r.height)},
    clientH: el.clientHeight, scrollH: el.scrollHeight,
    visible: r.width > 0 && r.height > 0,
    clip: clip,
  };
}
"""


def probe(page, sel):
    return page.evaluate(PROBE_JS, sel)


def overlap(a, b):
    """两个矩形相交的面积（>0 就是叠上了）。"""
    if not a or not b:
        return 0
    ra, rb = a["rect"], b["rect"]
    dx = min(ra["right"], rb["right"]) - max(ra["left"], rb["left"])
    dy = min(ra["bottom"], rb["bottom"]) - max(ra["top"], rb["top"])
    return dx * dy if dx > 0 and dy > 0 else 0


def seed_session(con, uid, title="布局测试对话"):
    """给这个账号建一条会话，返回 id。

    ⚠️ 必须**属于这个账号**。db_tasks_list() 是按
       `JOIN sessions ON ... AND sessions.user_id = ?` 过滤的（见 R/db.R:931
       那段说明：任务的归属只能从 sessions.user_id 推出来）。第一版拿的是
       "rowid 最大的那条会话"，那是上一个测试账号的，于是塞进去的 14 条任务
       一条都不会显示 —— 表格只有 80px 高，而断言全绿。**空表格不会重叠**，
       这种"因为没数据所以通过"的绿灯比红灯更危险。
    """
    sid = "s-uilayout-%d" % uid
    con.execute("DELETE FROM tasks WHERE session_id = ?", (sid,))
    con.execute("DELETE FROM sessions WHERE id = ?", (sid,))
    con.execute(
        "INSERT INTO sessions (id, title, user_id, created_at, updated_at)"
        " VALUES (?,?,?,?,?)",
        (sid, title, uid, "2026-09-16 10:00:00", "2026-09-16 10:00:00"))
    con.commit()
    return sid


def seed_tasks(con, sid, n=14):
    """直接往库里塞任务行。

    ⚠️ 不跑真任务：真跑一次要起子进程、要等，而且这里要验的是**表格变高之后
       按钮还在不在**，跟任务怎么来的无关。12 行是 pageLength 的默认值，
       塞 14 行就能把表格顶到最高那一页。
    """
    for i in range(n):
        con.execute(
            "INSERT INTO tasks (session_id, title, lang, code, status,"
            " created_at, exit_code) VALUES (?,?,?,?,?,?,?)",
            (sid, "布局测试任务-%02d" % i, "R",
             "print('hello %d')\n" % i,
             "success" if i % 3 else "failed",
             "2026-09-16 10:%02d:00" % i, 0 if i % 3 else 1))
    con.commit()


with sync_playwright() as pw:
    br = pw.chromium.launch()
    ctx = br.new_context(viewport={"width": 1500, "height": 950})
    page = ctx.new_page()
    email = enter_app(page, nickname="布局")
    uid, dbfile = seed_or_die(email)
    con = sqlite3.connect(dbfile)
    # ⚠️ 必须显式提权。**只有全新实例里第一个注册的账号**才是管理员
    #    （R/users.R 里那条"库里没有账号时第一个注册的是管理员"）。这个实例
    #    是复用的，第一个账号早被别的测试脚本占了，于是这个新账号点
    #    「服务器管理」什么都不会发生 —— dsappNav 把事件发给服务端，服务端
    #    一看没权限就不响应，**前端一个报错都没有**。
    #
    #    第一版就是这么中的招：layout.py 是那轮唯一跑过的脚本，它恰好捡到了
    #    "第一个账号"所以看得见管理页；换个顺序（比如先跑了别的脚本）就变成
    #    "找不到服务器健康那张卡"，看着像页面被改坏了。
    con.execute("UPDATE users SET is_admin = 1 WHERE id = ?", (uid,))
    con.commit()
    # ⚠️ 改完库必须**重新载入页面**。is_admin 是登录那一刻读进 state 的，
    #    当前这个 Shiny 会话里还是 0 —— 不刷新的话「服务器管理」点了没反应
    #    （dsappNav 照发，服务端一看没权限就不响应，前端不报错）。
    #    刷新会按登录 cookie 重开会话、重新读一次 users 行。
    page.reload(wait_until="domcontentloaded")
    page.wait_for_timeout(6000)
    sid = seed_session(con, uid)
    seed_tasks(con, sid, 14)
    print("  账号 uid=%s 会话=%s 塞了 14 条任务（已提权为管理员）"
          % (uid, sid), flush=True)

    # ---------------------------------------------------------------- item 3/4
    print("\n== item 3/4：历史任务页 ==", flush=True)
    goto(page, "tasks")
    page.wait_for_timeout(3500)
    page.click("#tasks-refresh")
    page.wait_for_timeout(3000)

    tbl = probe(page, "#tasks-tbl")
    row = probe(page, "#tasks-rerun")
    # ⚠️ 必须限定在**当前激活的页签**里找那句提示。别的页是"留在 DOM 里只藏
    #    不激活"的（bslib navset_hidden），`p.small.text-muted` 在设置页、
    #    环境页各有一堆，`.first` 会先撞上它们的 —— 症状是断言拿到的文本
    #    根本不是任务页那句，看着像"文案改丢了"。
    # ⚠️ 页面上有**两条** `p.small.text-muted.mb-0`：上面那条是 sel_hint
    #    （"勾选每行最左边的方框可以多选…"），下面那条才是「停止」的说明。
    #    `.first` 拿到的是上面那条 —— 断言于是去检查了一句跟本 item 无关的
    #    文案，报"没有当前正在执行"，看着像文案被改丢了。按**内容**定位。
    HINT = ".tab-pane.active p.small.text-muted.mb-0"
    loc = page.locator(HINT).filter(has_text="停止").first
    hint_txt = loc.inner_text()
    hint = page.evaluate("""() => {
      const ps=[...document.querySelectorAll('.tab-pane.active p.small.text-muted.mb-0')];
      const el=ps.find(p=>p.innerText.includes('停止'));
      if(!el) return null;
      const r=el.getBoundingClientRect();
      let clipper=null,p=el.parentElement;
      while(p){const cs=getComputedStyle(p);
        if(cs.overflowY!=='visible'||cs.overflowX!=='visible'){clipper=p;break;} p=p.parentElement;}
      let clip=null;
      if(clipper){const cr=clipper.getBoundingClientRect();
        clip={tag:clipper.tagName,below:Math.round(r.bottom-cr.bottom),above:Math.round(cr.top-r.top)};}
      return {rect:{top:Math.round(r.top),bottom:Math.round(r.bottom),left:Math.round(r.left),
        right:Math.round(r.right),w:Math.round(r.width),h:Math.round(r.height)},
        clientH:el.clientHeight,scrollH:el.scrollHeight,visible:r.width>0&&r.height>0,clip:clip};
    }""")
    print("   表格 : %s" % (tbl and tbl["rect"]), flush=True)
    print("   按钮行: %s" % (row and row["rect"]), flush=True)
    print("   提示  : %s" % (hint and hint["rect"]), flush=True)

    chk("★ 任务表格真的渲染出来了（不然下面量的是空气）",
        bool(tbl and tbl["visible"]), extra=tbl)
    chk("★ 按钮行真的在页面上",
        bool(row and row["visible"]), extra=row)
    chk("★★ 表格和「重跑」按钮**不重叠**（用户报的那一条）",
        overlap(tbl, row) == 0,
        extra="重叠 %d 平方像素" % overlap(tbl, row))
    chk("★★ 「停止」那句提示**没被裁掉**"
        "（在下沿之外 = 用户看不到，但 inner_text 照样读得到）",
        bool(hint) and hint["clip"] and hint["clip"]["below"] <= 0,
        extra=hint)
    print("   提示原文: %r" % hint_txt[:160], flush=True)
    chk("★★ 提示文字里**没有字面的星号**（card_body 不过 markdown，"
        "**当前正在执行** 会原样显示两个星号）",
        hint_txt.count("*") == 0, extra=repr(hint_txt[:160]))
    chk("★ 提示文字确实说了「当前正在执行」（改加粗不能把内容改没）",
        "当前正在执行" in hint_txt, extra=repr(hint_txt[:160]))

    # ---------------------------------------------------------------- item 8
    print("\n== item 8：服务器健康 / token 用量 / 用户 ==", flush=True)
    goto(page, "admin")
    page.wait_for_timeout(4000)

    # 卡片按标题找：这些卡片的 header 里各有一个固定的中文串。
    # ⚠️ 只量**当前页签**里的卡片。bslib 的 navset_hidden 把七个页面全留在
    #    DOM 里、只藏不激活，`.dsapp-main-body .card` 会把另外六页的卡片也
    #    捞进来 —— 它们全是 0×0，混在结果里既刷屏又容易让"找得到某张卡"
    #    这类断言指到错的那一张上。
    cards = page.evaluate(r"""
    () => [...document.querySelectorAll('.tab-pane.active .card')].map((c, i) => {
      const h = c.querySelector('.card-header');
      const b = c.querySelector('.card-body');
      const r = c.getBoundingClientRect();
      const br = b ? b.getBoundingClientRect() : null;
      return {
        i: i,
        title: h ? h.innerText.trim().slice(0, 24) : '(无标题)',
        h: Math.round(r.height),
        bodyClientH: b ? b.clientHeight : -1,
        bodyScrollH: b ? b.scrollHeight : -1,
        // 卡体内部要滚 = 内容被截
        innerScrolls: b ? (b.scrollHeight - b.clientHeight) : 0,
        // 卡片自身要滚 = 连 header 都保不住
        cardScrolls: Math.round(c.scrollHeight - c.clientHeight),
        bodyBottom: br ? Math.round(br.bottom) : 0,
      };
    })
    """)
    for c in cards:
        print("   [%d] %-22s 高=%-4s 卡体 %s/%s 内滚=%s 卡滚=%s"
              % (c["i"], c["title"], c["h"], c["bodyClientH"],
                 c["bodyScrollH"], c["innerScrolls"], c["cardScrolls"]),
              flush=True)

    health = [c for c in cards if "服务器健康" in c["title"]]
    usage = [c for c in cards if "token" in c["title"]]
    users = [c for c in cards if "用户" in c["title"]]

    chk("★ 找得到「服务器健康」那张卡（不然下面的断言全是空转）",
        len(health) == 1, extra=[c["title"] for c in cards])
    chk("★★ 健康卡片**没有内部滚动条**（有的话用户就只看得见第一行）",
        bool(health) and health[0]["innerScrolls"] <= 2,
        extra=health[:1])
    chk("★ 健康卡片自身也没被压出滚动条",
        bool(health) and health[0]["cardScrolls"] <= 2, extra=health[:1])
    chk("★★ token 用量那张卡同理",
        bool(usage) and usage[0]["innerScrolls"] <= 2, extra=usage[:1])
    chk("★★ 用户那张卡同理",
        bool(users) and users[0]["innerScrolls"] <= 2, extra=users[:1])

    page.screenshot(path=OUT + "/layout_admin.png", full_page=True)
    goto(page, "tasks")
    page.wait_for_timeout(1500)
    page.screenshot(path=OUT + "/layout_tasks.png", full_page=True)
    con.close()
    br.close()

sys.exit(chk.done())
