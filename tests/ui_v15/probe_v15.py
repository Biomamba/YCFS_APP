# -*- coding: utf-8 -*-
"""V15 item 8：论坛页的浏览器验收。

    bash tests/ui_v7/make_instance.sh 8918 /tmp/dsapp_v15
    python3 tests/ui_v15/probe_v15.py

用户原话：「加一个论坛页面，用户能交流自己使用过程中的经验或遇到的问题。
你需要考虑好同步问题，现有的账户体系是靠什么为枢纽进行同步的？」

自检（selftest.R 的 V15 那一节）已经验了**数据层**：建表、CRUD、软删、
LWW、幂等、水位、签名载荷、以及那句"枢纽是 email"。这个脚本只管
**浏览器里真的发生了什么** —— R 那边全绿而页面上是空白的组合，这个仓库里
出现过不止一次。

★ 这个脚本要回答的问题，按重要性排：

  1. **列表真的渲染出帖子了吗**（不是"没有报错"）。
     ⚠️ 这一条不是走过场：写这一页的时候 `dsapp_forum_list()` 的参数绑定
     漏了一个 `?`（SELECT 里 `i_liked` 那个子查询排在 WHERE 之前），SQLite
     报 "Query requires 4 params; 3 supplied"，而那句查询在 tryCatch 里 ——
     表现是**列表永远是空的、一句报错都没有**，页面画的是"还没有人发帖"。
     自检抓到了它；这里再抓一次，因为它是这一页最贵的坏法。
  2. **XSS**：正文里写 `<script>` / `javascript:` / `onerror`，页面上不许有
     任何一个真的生效。论坛是全应用唯一一处"A 写的东西渲染给 B 看"的地方。
  3. **两个账号之间的可见性**：甲发的帖，乙**看得到**（这才是"公共"的定义，
     也是 item 8 那句"用户能交流"的最小可验证形态）。
  4. 发帖 / 回复 / 点赞 点下去**页面上真的变了**（不是"点了没反应"）。
  5. **软删的楼层留在原位**：删掉 1 楼之后，2 楼还是 #2，不许变成 #1。
  6. 几何与配色：正文有高度、板块标签有底色 —— 量之前先确认元素可见，
     隐藏元素返回全 0 矩形，拿它做减法得到的数看着完全合理。

⚠️ 会**真的注册账号、发帖、删帖**，所以只能对着 /tmp 那份实例跑。
   `_common.guard()` 把"指向仓库本身"和"data_root 不在 /tmp 下"直接拦下。
⚠️ 建的是**两个**账号（甲、乙），因为第 3 条断言必须有第二个人。
"""
import datetime
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

TAG = C.TAG
EMAIL_A = "v15_forum_a_%s@example.com" % TAG
EMAIL_B = "v15_forum_b_%s@example.com" % TAG

chk = C.Chk()
DB = {"path": None}


def shot(page, name):
    try:
        page.screenshot(path=os.path.join(C.OUT, name + ".png"), full_page=True)
    except Exception:
        pass


# ---- 直接读库的几件小事 ----------------------------------------------------
#
# ⚠️ 用 sqlite 直读**不是为了绕过界面**，是为了拿到界面上不显示的**行身份**
#    （origin_node / origin_id）—— 行内动作的 input 值是 `动作|node:id`，
#    而那个 key 在 DOM 里只在 onclick 属性里躺着。从库里取比正则抠 onclick
#    稳，而且它顺带确认了"界面上那一行就是库里那一行"。
def q(sql, args=()):
    con = sqlite3.connect(DB["path"])
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def wait_cooldown(email, margin=1.5):
    """等到这个账号距上次发言超过 DSAPP_FORUM_COOLDOWN 秒。

    ★★ 为什么必须有这个：发帖 / 回帖有 **10 秒限流**（R/forum.R 的
    `DSAPP_FORUM_COOLDOWN`，按 author_email 在 forum_threads + forum_posts
    里的 MAX(created_at) 算）。探针要在几秒内连写好几行，于是**大部分写
    会被服务端拒掉** —— 而"被拒掉"和"界面没接上"在页面上**长得一模一样**：
    楼层没多出来。第一版就是这么红的，红的是
    `★★★ 删掉的楼层留在原位`（实际只写进去 1 层），
    查库才看出来少的那些行**压根没进库**（不是没画出来）。
    ⚠️ 这也是为什么下面每条写操作后面都要**回库确认**：判断"写没写进去"
    不能靠页面，否则限流会被误诊成渲染 bug。
    """
    r = q("SELECT MAX(t) FROM (SELECT MAX(created_at) AS t FROM forum_threads"
          " WHERE author_email = ? UNION ALL SELECT MAX(created_at) AS t"
          " FROM forum_posts WHERE author_email = ?)", (email, email))
    if not r or not r[0][0]:
        return
    t0 = datetime.datetime.strptime(r[0][0], "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=datetime.timezone.utc)
    left = 10 - (datetime.datetime.now(datetime.timezone.utc) - t0).total_seconds()
    if left > 0:
        time.sleep(left + margin)


def wait_post(email, body_like, tries=3):
    """写完之后回库确认那一行**真的进去了**（限流的话等一轮再点）。

    ⚠️ 不要把"没写进去"和"没画出来"混成一条红 —— 前者是本探针自己的
    节奏问题，后者才是要抓的 bug。这里的重试只解决前者。
    """
    for _ in range(tries):
        r = q("SELECT COUNT(*) FROM forum_posts WHERE author_email = ?"
              " AND body LIKE ?", (email, "%" + body_like + "%"))
        if r and r[0][0] >= 1:
            return True
        wait_cooldown(email)
    return False


def thread_key(title_like):
    r = q("SELECT origin_node, origin_id FROM forum_threads WHERE title LIKE ?"
          " ORDER BY id DESC LIMIT 1", ("%" + title_like + "%",))
    if not r:
        sys.exit("探针找不到标题含 %r 的帖子 —— 上面某一步没成功。" % title_like)
    return "%s:%s" % (r[0][0], r[0][1])


def post_key(title_like, body_like):
    r = q("SELECT origin_node, origin_id FROM forum_posts WHERE body LIKE ?"
          " AND thread_oid = (SELECT origin_id FROM forum_threads"
          "                   WHERE title LIKE ? ORDER BY id DESC LIMIT 1)"
          " ORDER BY id LIMIT 1", ("%" + body_like + "%", "%" + title_like + "%"))
    if not r:
        sys.exit("探针找不到正文含 %r 的回复。" % body_like)
    return "%s:%s" % (r[0][0], r[0][1])


# ---- 页面动作 --------------------------------------------------------------

def forum_rows(page):
    return page.locator(".dsapp-forum-row")


def row_titles(page):
    """列表上每一行的标题文字。

    ⚠️ 取 `.dsapp-forum-row-tt` 而不是整行的 inner_text：整行会把作者 /
    时间 / 计数一起带进来（它们都是同一行里的 span），断言没法写。
    """
    return [t.strip() for t in page.locator(".dsapp-forum-row-tt").all_inner_texts()]


def open_row(page, idx=0):
    """点开列表第 idx 条（走那个铺满整行的 <a>）。"""
    hit = page.locator(".dsapp-forum-row-hit").nth(idx)
    # ⚠️ 必须先滚进视口。视口外的元素 mouse 事件**无人接收**，而
    #    bounding_box() 照样返回正数、全程不报错（ui_v14 栽过这个坑）。
    hit.scroll_into_view_if_needed()
    page.wait_for_timeout(300)
    hit.click()
    page.wait_for_selector(".dsapp-forum-detail-tt", timeout=15000)
    page.wait_for_timeout(1200)


def back(page, btn="#forum-back"):
    page.click(btn)
    page.wait_for_selector(".dsapp-forum-list, .dsapp-forum-empty", timeout=15000)
    page.wait_for_timeout(1200)


def act(page, verb_arg):
    """按 `动作|参数` 触发一个行内动作。

    走的是**和界面同一条路**（共用的 input$act），所以验的确实是那条路
    本身。`priority:'event'` 要带上 —— 同一行的按钮连点两次时，值一样的话
    Shiny 默认不触发，表现是"点第二次没反应"。
    """
    page.evaluate(
        "(v) => window.Shiny.setInputValue('forum-act', v, {priority:'event'})",
        verb_arg)
    page.wait_for_timeout(1800)


def send_reply(page, text, email, wait=2500):
    """在详情页回一层，并且**回库确认它进去了**。

    ⚠️ 限流那一轮的重试在 `wait_post` 里；这里重试时要把输入框重新填一遍
    （点了一次没成功的话，服务端不会清空它，但重画会 —— 草稿机制会把它带
    回来，只是不能指望，重填最稳）。
    """
    wait_cooldown(email)
    page.fill("#forum-reply_body", text)
    page.click("#forum-reply_send")
    page.wait_for_timeout(wait)
    if wait_post(email, text):
        return True
    page.fill("#forum-reply_body", text)
    page.click("#forum-reply_send")
    page.wait_for_timeout(wait + 1500)
    return wait_post(email, text)


def post_new(page, title, body, cat="share", tags="", email=None):
    if email:
        wait_cooldown(email)
    page.click("#forum-new")
    page.wait_for_selector("#forum-new_title", timeout=15000)
    page.wait_for_timeout(700)
    page.fill("#forum-new_title", title)
    if cat != "share":
        C.pick_select(page, "forum-new_cat", cat)
    if tags:
        page.fill("#forum-new_tags", tags)
    page.fill("#forum-new_body", body)
    page.click("#forum-new_save")
    page.wait_for_timeout(3500)


def text_of(page, sel):
    loc = page.locator(sel)
    if not loc.count():
        return ""
    return loc.first.inner_text().strip()


def visible_h(page, sel):
    """元素的可见高度。**不可见时返回 0**，别拿它做减法。"""
    return page.evaluate(
        "(s) => { var e = document.querySelector(s);"
        " if (!e) return -1;"
        " var r = e.getBoundingClientRect();"
        " if (r.width === 0 && r.height === 0) return 0;"
        " return Math.round(r.height); }", sel)


def main():
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1500, "height": 1000})
        page = ctx.new_page()

        # ================= 甲 =================
        C.enter_app(page, email=EMAIL_A, nickname="论坛甲")
        _uid_a, DB["path"] = C.seed_or_die(EMAIL_A)
        C.goto(page, "forum")
        page.wait_for_selector(".dsapp-forum-head", timeout=20000)
        page.wait_for_timeout(2000)
        shot(page, "01_forum_empty")

        chk("★ 论坛页进得去（左栏高亮切到了 forum）",
            page.evaluate("() => { var a = document.querySelector("
                          "'.dsapp-rail-link.active');"
                          " return !!a && a.getAttribute('data-nav') === 'forum'; }"))
        # ⚠️ 「空列表」这一条**要求实例是干净的**。对着跑过一轮的实例重跑时，
        #    库里已经有旧帖，那句话就不会出现 —— 换成"搜一个不存在的词"，
        #    验的是**同一个** `.dsapp-forum-empty` 元素（只是文案换了一支）。
        n_old = q("SELECT COUNT(*) FROM forum_threads")[0][0]
        if n_old == 0:
            chk("★★ 空列表时给的是「还没有人发帖」，不是一片空白",
                page.locator(".dsapp-forum-empty").count() == 1 and
                "还没有人发帖" in text_of(page, ".dsapp-forum-empty"),
                text_of(page, ".dsapp-forum-empty"))
        else:
            print("  （这个实例里已经有 %d 条旧帖，空态改走「搜不到」那一支）"
                  % n_old)
            page.fill("#forum-q", "zzz-%s-no-such" % TAG)
            page.wait_for_timeout(1500)
            chk("★★ 搜不到时给的是「没有匹配的帖子」，不是一片空白",
                page.locator(".dsapp-forum-empty").count() == 1 and
                "没有匹配" in text_of(page, ".dsapp-forum-empty"),
                text_of(page, ".dsapp-forum-empty"))
            page.fill("#forum-q", "")
            page.wait_for_timeout(1500)
        chk("★ 顶栏、筛选行（板块/搜索/排序/只看我发的）、发帖按钮都在",
            page.locator(".dsapp-forum-head").count() == 1 and
            page.locator("#forum-cat").count() == 1 and
            page.locator("#forum-q").count() == 1 and
            page.locator("#forum-sort").count() == 1 and
            page.locator("#forum-mine").count() == 1 and
            page.locator("#forum-new").count() == 1)
        chk("★ 普通用户**看不到**「公告」这个板块（管理员才有的选项）",
            page.evaluate(
                "() => { var s = document.querySelector('#forum-cat');"
                " if (!s) return null;"
                " return Array.from(s.options).map(o => o.textContent).join('|'); }")
            .find("公告") == -1,
            page.evaluate(
                "() => { var s = document.querySelector('#forum-cat');"
                " return s ? Array.from(s.options).map(o => o.textContent).join('|')"
                "          : ''; }"))

        # ---- 发帖 ---------------------------------------------------------
        T1 = "GC 结果导出成 csv 的正确姿势 %s" % TAG
        post_new(page, T1,
                 "背景：跑完 GC 想导出。\n\n```r\nwrite.csv(x, 'a.csv')\n```\n",
                 cat="share", tags="报错,R语言", email=EMAIL_A)
        shot(page, "02_after_post")

        # ★★★ 整页最贵的坏法：列表查询抛错被 tryCatch 吞掉 → 页面画
        #     "还没有人发帖"，而日志里那行 [dsapp] 论坛列表查询失败没人看得到。
        titles = row_titles(page)
        chk("★★★ 发完帖列表上真的有它了（列表查询没被 tryCatch 吞掉）",
            any(T1 in t for t in titles), repr(titles))
        chk("★★ 刚发的帖排在第一条（默认按最新回复排）",
            bool(titles) and T1 in titles[0], repr(titles[:2]))
        chk("★★ 板块标签画的是「经验分享」，不是空的、也不是原样的 value",
            "经验分享" in text_of(page, ".dsapp-forum-row .dsapp-forum-cat"),
            text_of(page, ".dsapp-forum-row .dsapp-forum-cat"))
        # ⚠️ 必须**限定在第一行里**数：`.dsapp-forum-row .dsapp-forum-tag`
        #    是全页所有行的标签总和，对着跑过一轮的实例重跑时那边还留着
        #    别的帖，数出来会变成 4 —— 红得跟标签功能坏了一样。
        first_row_tags = page.locator(".dsapp-forum-row").first.locator(
            ".dsapp-forum-tag")
        chk("★ 标签串被拆成了两个（逗号分隔的）",
            first_row_tags.count() == 2, first_row_tags.count())
        chk("★ 作者显示的是昵称「论坛甲」，不是邮箱",
            "论坛甲" in text_of(page, ".dsapp-forum-row .dsapp-forum-author"),
            text_of(page, ".dsapp-forum-row .dsapp-forum-author"))

        # ★ 板块标签真的有底色。没有的话是 css 没接上（页面能开、就是裸奔）。
        bg = page.evaluate(
            "() => { var e = document.querySelector('.dsapp-forum-row .dsapp-forum-cat');"
            " if (!e) return ''; var s = getComputedStyle(e);"
            " return s.backgroundColor + '|' + s.borderRadius; }")
        chk("★★ 板块标签有底色和圆角（不是裸文字）",
            bool(bg) and "rgba(0, 0, 0, 0)" not in bg.split("|")[0] and
            bg.split("|")[1] not in ("", "0px"), bg)
        shot(page, "03_row_style")

        # ---- 详情：正文渲染 ------------------------------------------------
        open_row(page, 0)
        chk("★ 点开详情，标题对得上",
            T1 in text_of(page, ".dsapp-forum-detail-tt"),
            text_of(page, ".dsapp-forum-detail-tt"))
        chk("★★ 正文里的 Markdown 代码块真的渲染成了 <pre>",
            page.locator(".dsapp-forum-detail-body pre").count() >= 1,
            page.locator(".dsapp-forum-detail-body pre").count())
        chk("★ 正文区域有高度（不是 0 —— 0 的话是渲染没出东西）",
            visible_h(page, ".dsapp-forum-detail-body") > 10,
            visible_h(page, ".dsapp-forum-detail-body"))
        shot(page, "04_detail")

        # ---- 回复 ----------------------------------------------------------
        chk("★★ 回复真的写进库了（限流没把它挡掉 —— 否则下面几条是空转）",
            send_reply(page, "自己顶一下，我也卡在这儿。", EMAIL_A))
        chk("★★ 回复出现在楼层里",
            page.locator(".dsapp-forum-floor").count() == 1,
            page.locator(".dsapp-forum-floor").count())
        chk("★ 楼层号是「#1」",
            text_of(page, ".dsapp-forum-floor-no") == "#1",
            text_of(page, ".dsapp-forum-floor-no"))
        chk("★ 回复的正文渲染出来了（不是空壳楼层）",
            "自己顶一下" in text_of(page, ".dsapp-forum-floor-body"),
            text_of(page, ".dsapp-forum-floor-body")[:80])
        shot(page, "05_reply")

        # ---- XSS -----------------------------------------------------------
        page.evaluate("() => { window.__v15_xss = 0; }")
        back(page)
        XSS_T = "XSS 探针 %s" % TAG
        post_new(page, XSS_T,
                 "<script>window.__v15_xss = 2;</script>\n\n"
                 "[点我](javascript:window.__v15_xss=3)\n\n"
                 "<img src=x onerror=\"window.__v15_xss=4\">\n",
                 email=EMAIL_A)
        open_row(page, 0)
        page.wait_for_timeout(1500)
        fired = page.evaluate("() => window.__v15_xss")
        body_html = page.evaluate(
            "() => { var e = document.querySelector('.dsapp-forum-detail-body');"
            " return e ? e.innerHTML : '<none>'; }")
        chk("★★★ 正文里的 <script> 没有执行（dsapp_md_html 的转义那一层）",
            fired == 0, "window.__v15_xss=%r" % fired)
        chk("★★★ 渲染出来的 HTML 里没有真的 <script> 标签（转义成了 &lt;script）",
            "<script" not in (body_html or "").lower(), (body_html or "")[:200])
        chk("★★★ javascript: 链接被链接协议白名单拿掉了",
            "javascript:" not in (body_html or "").lower(), (body_html or "")[:300])
        # ⚠️ 这条**不能**去 grep innerHTML 里的 "onerror" —— 转义之后
        #    `<img src=x onerror=...>` 会原样躺在正文里当**文本**显示，
        #    grep 一定命中，于是这条永远红（第一版就是这么写的）。要问的是
        #    "有没有哪个元素真的挂上了事件属性"，只有 DOM 知道。
        chk("★★ onerror 这类内联事件属性也没挂到任何元素上（不是只把尖括号转义了）",
            page.evaluate(
                "() => { var bad = [];"
                " document.querySelectorAll('.dsapp-forum-detail-body *')"
                "   .forEach(function(e){"
                "     for (var i = 0; i < e.attributes.length; i++)"
                "       if (/^on/i.test(e.attributes[i].name))"
                "         bad.push(e.tagName + '@' + e.attributes[i].name); });"
                " return bad.join(','); }") == "",
            "正文里确实有 onerror 这几个字，但它是**文本**（下面这行是 innerHTML）："
            + (body_html or "")[:200])
        shot(page, "06_xss")

        # ---- 点赞 ----------------------------------------------------------
        key_xss = thread_key(XSS_T)
        act(page, "like|" + key_xss)
        chk("★★ 点了「有用」之后按钮变成「已标记有用」（不是点了没反应）",
            "已标记有用" in text_of(page, ".dsapp-forum-actions"),
            text_of(page, ".dsapp-forum-actions")[:140])
        chk("★ 库里的赞记下来了",
            q("SELECT COUNT(*) FROM forum_marks WHERE target_oid = ?"
              " AND value = 1", (key_xss.split(":", 1)[1],))[0][0] == 1)
        shot(page, "07_liked")
        act(page, "unlike|" + key_xss)
        chk("★★ 再点一次取消：按钮变回「有用」，而**行还在**（value=0 不是删行）",
            "已标记有用" not in text_of(page, ".dsapp-forum-actions") and
            q("SELECT COUNT(*) FROM forum_marks")[0][0] == 1,
            text_of(page, ".dsapp-forum-actions")[:140])

        # ---- 软删的楼层留在原位 --------------------------------------------
        #
        # ★ 在**同一条帖**（XSS 那条，现在开着）里回两层，然后把**第一层**
        #   删掉：第二层必须还是 #2。抽掉占位的话它会变成 #1，而"你看 2 楼
        #   说的"这句话在别人屏幕上就指向另一条了 —— 这是楼层号存在的全部
        #   意义。
        #
        # ⚠️ 下文里的 `XSS_T` 就是当前这条帖。别拿 T1 去找楼层 —— 那两层
        #    是回在 XSS 这条上的（第一版写成 T1，post_key 直接找不到行退出）。
        chk("★★ 两层楼都真的写进库了（限流挡掉的话下面整段是空转）",
            send_reply(page, "要被删掉的那一层", EMAIL_A) and
            send_reply(page, "第二层，待会儿要验它的号", EMAIL_A))
        chk("★ 现在有 2 层楼了", page.locator(".dsapp-forum-floor").count() == 2,
            page.locator(".dsapp-forum-floor").count())
        nos_before = [t.strip() for t in
                      page.locator(".dsapp-forum-floor-no").all_inner_texts()]
        chk("★ 楼层号是 #1 #2（顺序由 SQL 定死，两端要一致）",
            nos_before == ["#1", "#2"], repr(nos_before))

        p1_key = post_key(XSS_T, "要被删掉的那一层")
        act(page, "pdel|" + p1_key)
        page.wait_for_timeout(2000)
        chk("★★★ 删掉的楼层**留在原位**（2 层还是 2 层，不是 1 层）",
            page.locator(".dsapp-forum-floor").count() == 2,
            page.locator(".dsapp-forum-floor").count())
        nos_after = [t.strip() for t in
                     page.locator(".dsapp-forum-floor-no").all_inner_texts()]
        chk("★★★ 楼下那一层的号**没有移位**（#2 还是 #2，不是变成 #1）",
            nos_after == ["#1", "#2"], repr(nos_after))
        chk("★★ 被删的那一层画成了「（该回复已删除）」",
            "该回复已删除" in text_of(page, ".dsapp-forum-floors"),
            text_of(page, ".dsapp-forum-floors")[:200])
        chk("★ 被删楼层的正文不再显示（不是把原文留着只加一行字）",
            "要被删掉的那一层" not in text_of(page, ".dsapp-forum-floors"))
        shot(page, "08_soft_delete")

        # ================= 乙：另一个人看不看得到 =================
        #
        # ★ 这是 item 8 那句话的核心：论坛是**公共的**。对话页那种"甲的数据
        #   乙一条也看不到"在这里必须**反过来**。同一个浏览器换个 context
        #   （不共享 cookie），等于换一个人、换一个 Shiny session。
        ctx2 = browser.new_context(viewport={"width": 1500, "height": 1000})
        page2 = ctx2.new_page()
        C.enter_app(page2, email=EMAIL_B, nickname="论坛乙")
        C.seed_or_die(EMAIL_B)
        C.goto(page2, "forum")
        page2.wait_for_selector(".dsapp-forum-head", timeout=20000)
        page2.wait_for_timeout(2500)
        shot(page2, "09_other_user")

        t2 = row_titles(page2)
        chk("★★★ 乙看得到甲发的帖（论坛是公共的 —— 这正是 item 8 要的「交流」）",
            any(T1 in t for t in t2), repr(t2))
        chk("★★ 乙看得到甲那条 XSS 探针（不是只看到自己发的）",
            any(XSS_T in t for t in t2), repr(t2))
        chk("★ 列表上显示的作者是甲（不是「我」或者空白）",
            "论坛甲" in page2.locator(".dsapp-forum-author").first.inner_text(),
            page2.locator(".dsapp-forum-author").first.inner_text())
        chk("★★ 甲统计的那一栏在乙这里是**乙自己的**数（不是照抄甲的）",
            "你发过 0 条帖" in text_of(page2, ".dsapp-forum-mystat"),
            text_of(page2, ".dsapp-forum-mystat"))

        # 找到 XSS 那条并打开
        idx_x = next((i for i, t in enumerate(t2) if XSS_T in t), None)
        chk("★ 找得到甲那条 XSS 帖（找不到后面几条是空转）", idx_x is not None)
        open_row(page2, idx_x or 0)

        # ★★★ 乙看到的楼层**和甲一样多**（2 层，含那条已删的占位）。
        #     这正是"楼层号对谁都一样"在界面上的样子 —— R 那边过滤掉已删行
        #     的话，乙这里会只有 1 层，而且它会是 #1（甲那边它是 #2）。
        chk("★★★ 乙也看得到那条已删楼层的占位（楼层号对谁都不能错位）",
            page2.locator(".dsapp-forum-floor").count() == 2,
            page2.locator(".dsapp-forum-floor").count())
        chk("★★★ 乙这边那条占位仍然是 #1，没被重排",
            [t.strip() for t in
             page2.locator(".dsapp-forum-floor-no").all_inner_texts()] == ["#1", "#2"],
            repr([t.strip() for t in
                  page2.locator(".dsapp-forum-floor-no").all_inner_texts()]))
        chk("★★ 但乙**看不到**被删那条的正文（占位只占位，不是把原文露出来）",
            "要被删掉的那一层" not in text_of(page2, ".dsapp-forum-floors"),
            text_of(page2, ".dsapp-forum-floors")[:200])

        send_reply(page2, "乙来回复：我也遇到了。", EMAIL_B)
        chk("★★ 乙能回复甲的帖（回复框在，而且发出去了）",
            "乙来回复" in text_of(page2, ".dsapp-forum-floors"),
            text_of(page2, ".dsapp-forum-floors")[:200])
        chk("★ 乙那条是 #3（接着往下排，不是从 #1 重来）",
            "乙来回复" in text_of(page2, ".dsapp-forum-floors") and
            [t.strip() for t in
             page2.locator(".dsapp-forum-floor-no").all_inner_texts()][-1] == "#3",
            repr([t.strip() for t in
                  page2.locator(".dsapp-forum-floor-no").all_inner_texts()]))
        shot(page2, "10_other_reply")

        # ---- 乙回到列表：回复数变了 ----------------------------------------
        #
        # ⚠️ 回复数在 `.dsapp-forum-row-meta` 里**没有自己的 class**，
        #    只能按下标取：meta 的子元素是
        #      [0]作者 [1]· [2]时间 [3]· [4]回复数 [5]· [6]赞数 [7]· [8]浏览
        #    改 mod_forum.R 里那段 markup 的话这里要跟着改。
        back(page2)
        page2.wait_for_timeout(1500)
        meta_first = page2.locator(".dsapp-forum-row-meta").first
        replies_txt = meta_first.locator("span").nth(4).inner_text().strip()
        n_db = q("SELECT COUNT(*) FROM forum_posts WHERE status = 'ok'"
                 " AND thread_oid = ?", (thread_key(XSS_T).split(":", 1)[1],))[0][0]
        chk("★★ 列表上的回复数跟着涨了（现算的 n_replies，不是缓存）",
            str(n_db) in replies_txt, "%s vs 库里 %s" % (replies_txt, n_db))
        shot(page2, "11_list_final")
        page2.close()
        ctx2.close()

        # ---- 甲刷新，看到乙的回复 ------------------------------------------
        back(page)
        page.wait_for_timeout(1500)
        shot(page, "12_a_reload")
        browser.close()

    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
