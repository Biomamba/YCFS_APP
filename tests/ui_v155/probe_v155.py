# -*- coding: utf-8 -*-
"""Test_V15.5 四条改动的浏览器验收探针。

    bash tests/ui_v7/make_instance.sh 8925 /tmp/dsapp_v155
    python3 tests/ui_v155/probe_v155.py

★ 这个探针**只回答五件事**，每条都对应一句用户原话：

  ── A. item 6：上下文读条存在，而且里面那个数是**真的算出来的** ────────
     用户原话：「你的单次回复上限是指模型的上下文长度吗？如果是：需要按照
               模型的能力自适应更改上下文长度的读条」（R/mod_chat.R:3722）
     验：`#chat-hint` 里出现「上下文 ≈… / …（N%）」；N 是 0~100 的数字；
         `.dsapp-ctxbar > i` 的 style 宽度和 N 对得上（差 ≤1）；
         **同一条对话里发第二条更长的消息之后 used 会变大** ——
         这一条是"真算的、不是写死的常量"的唯一判据。

  ── B. item 6：量程按**这个模型自己的窗口**自适应 ──────────────────────
     用户原话：同上（「按照模型的能力自适应」），R/models.R:1190 那段。
     验：模型服务页上把厂商设成 deepseek 之后，**渲染出来的**标签文字
         `单次使用上限（tokens，1K ~ 1M）` 里那个上界是 **1M**
         （dsapp_fmt_tokens_short(1048576) 的写法），不是所有厂商一律的 10M。
     ⚠️ 这一条必须在 C **之前**跑，而且跑之前要清掉库里的"学到的窗口"，
        理由见 `item6b_range()` 的头注。取不到标签时**不许伪造通过**，
        降级路径写在那个函数里。

  ── C. item 7：超上下文**当场**反馈 + 落库 + 循环停 ─────────────────────
     用户原话：「内容输出时遇到上下文长度的问题，请立即给出反馈，而不是在
               下一次发送消息时才告知用户」（R/mod_chat.R:5104）
     验：假 LLM 回一个真 HTTP 400（body 就是厂商那种
         `maximum context length is 65536 tokens...`）之后，
         ① `.shiny-notification` **当场**出现 —— 判据是点完 `#chat-send`
            之后**不再动输入框、不再点发送**，就等它自己弹出来。
            ⚠️ 回库数用户消息时期望的是 **+1**（我点的那条），不是 +0 ——
               发送是"先落库、再出网"（R/mod_chat.R:1273），400 拦的是
               出网那一步，用户那句话照样进对话。写成 +0 会红在数数上；
         ② 库里当场多出一条 assistant 说明（正文含「没能发出去」「上下文」）
            —— 这是"刷新之后也还在"的证明；
         ③ 界面回到不忙（`#chat-send` 不再 disabled、没有 `.dsapp-cursor`）。
     手动模式（`agent_mode` 关）与自动执行模式各验一遍。自动执行那一节
     判"循环停了"用**三样一起**：侧栏那句「第 N/M 轮」不见了（它是
     `a$state != "idle"` 的唯一可见证据 —— 旧代码里循环会卡在 generating
     上，那句话**一直挂着**）、不再有新的出网请求、界面持续不忙。
     ⚠️ 为了让循环**真的进过运行状态**，那一节的第 1 个请求必须成功
        （队列里放一条带可执行代码块的回复），并把执行目标切成「本地电脑」
        （agent.R 的 local 那一支不经过引擎就能把循环推到下一轮生成）。
        第一个请求就 400 的话循环从没起来过，"循环停了"会白送 —— 这是
        本节最容易骗过自己的一条，专门配了前提断言盯着：
          · 400 **不是**事先挂好的，而是"看着第一条发出去之后再挂"
            （`arm_after_first_req()` 里写了为什么预置计数器做不到这件事）；
          · 前提判据是**库里那条「执行结果 · 未执行」的 tool 消息**
            （`loop_fired()`：只有循环接手才会被写，耐久），外加一个
            MutationObserver 盯着的侧栏徽章（`install_loop_watch()`：
            直接观测，但窗口只有一次 HTTP 往返，可能量不到）。

  ── D. item 8：生成期间输入框那颗转圈只应该有**一个实例** ───────────────
     用户原话：「正在生成时屏幕还是会闪，去掉这个闪烁的功能」
               （R/mod_chat.R:462）
     验：照 tests/ui_v155/measure_flash.py 那把尺子 —— 给带 CSS 动画的节点
         盖一次性 `dataset` 记号，数"同一个选择器下出现过多少个不同实例"。
         `.dsapp-composer-hint .spinner-border` 在**整段生成期间 == 1**
         （改之前实测 14）；屏幕上别的 `spinner-border` 也不许反复重建。
     ⚠️ 这一条单独看会**假绿**：节点 `display:none` 的时候实例数恒为 1。
        所以另配两条"这段采样真的落在生成期间""那颗转圈真的亮着"的断言。

  ── E. item 12：图里的方框会被平台**抓出来**，并摆到模型眼前 ─────────────
     用户原话：「这个图片里生成的文字是有问题的，想一个新的提示词并应用以
               杜绝这个问题」。截图是一张横向条形图，**每一个中文标签都是
               一个空心方框**（英文和数字是好的），根因是技能文档里写死了
               一份不含中文字形的字体清单（skills_builtin/nature-skills.md）。
     验：让平台真的跑一段**故意不设中文字体**的 matplotlib 代码
         （`_TOFU_CODE`），然后查执行结果（**库里的 tool 消息**，不是界面
         卡片）：出现「产出有问题」那一节，而且那一节里说得出"字没画出来"
         （`missing from current font` 或「方框」）。
         **反面对照**：同一张图设好中文字体（文泉驿微米黑）再画一遍，这一节
         **不许**出现 —— 没有这条对照，"那一节永远都在"（比如体检把每张
         PNG 都报一遍）也会让上面两条绿。
     ⚠️ 这一节会把 `tofu.png`（和对照的 `ok.png`）**留在工作区里**，这是
        故意的：工作区本来就该留下跑过的东西。
     ⚠️ 缺字形警告的**原文随 matplotlib 版本变**（≤3.8 是
        `missing from current font`，≥3.9 是 `missing from font(s) X`），
        所以这一节不猜那句话长什么样：把 stderr 里真实命中过的那一行原样
        打出来，好判断卡在"平台没看见"还是"看见了没认出来"。
     ⚠️ 这一节有**三次独立的红**，别混着读：执行器认没认出来 / 回喂链路
        有没有把它带上（tool 消息）/ 渲染层分不分得出这一节。后两个的理由
        写在 item12_tofu() 和 tool_section() 的注释里。

── 铁律（都是本仓踩过的，写在每一处需要它的地方）─────────────────────────
  · 新账号第一次进对话页有个首选项弹窗会把所有 click 吃掉
    （报 `intercepts pointer events`，指向的却是按钮本身）→ `ensure_no_modal()`。
  · 「等一行出现」写成「查得到行」= 没等 → 一律轮询到条件成立，带上限。
  · reload 之后 cookie 直进主界面 → `relogin()` 等的是"主界面或登录表单"，
    **不是**只认 `.dsapp-auth` 的 `wait_awake()`。
  · 只查界面 = 分不清"没写进去"和"没画出来" → 凡写操作都回库确认（`sql()`）。
  · 数 `shiny:outputinvalidated` 会虚高 → 这里一律用 DOM **实例指纹**。
"""
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402  （必须在 sys.path 之后）

from playwright.sync_api import sync_playwright  # noqa: E402


# =============================================================================
# 断言记账
#
# ⚠️ 为什么要自己包一层：`C.Chk` 只记"过了几条"，而这份报告要的是
#    「通过 N / 失败 M」。**不能改 _common.py**（别处的探针也在用它），
#    所以在外面数一遍。
# =============================================================================

_chk = C.Chk()
N_OK = [0]
N_BAD = [0]

# B 是不是**真的**验成了（验收报告里要能一眼看见）。取不到标签而降级的那条
# 路会把这里置 False —— 降级不等于通过。
B_VERIFIED = [False]


def chk(name, cond, extra=""):
    r = _chk(name, cond, extra)
    if cond:
        N_OK[0] += 1
    else:
        N_BAD[0] += 1
    return r


# =============================================================================
# 小工具（照 tests/ui_v154/probe_v154.py 抄，只改了函数名冲突的地方）
# =============================================================================

def relogin(page, email):
    """reload 之后把自己弄回主界面。

    ★ 探针里要 reload 的地方只有一处：种完假 LLM。`state$base_url / model`
      是**会话级**的（mod_model 的 observe 从库里读一次），不 reload 的话
      已经活着的那个会话手里还是老值 —— 空 base_url → 厂商默认地址 →
      **真厂商**。这是本仓明令禁止的（见 _common.py 顶部那段）。

    ⚠️⚠️ **不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload 时
      cookie 还在，应用**直接进主界面**，登录页一帧都不出现。拿它等等于等
      一个永远不会来的东西：报出来的是「reload 之后 120 秒还是空白页」，
      而屏幕上其实早就是主界面了。所以等的是"两个可能里先到的那个"。
    """
    page.reload(wait_until="domcontentloaded")

    submitted = False
    for _ in range(180):
        if page.locator(".dsapp-shell").count():
            return
        if not submitted and page.locator("#welcome-email").count():
            page.fill("#welcome-email", email)
            page.fill("#welcome-password", C.PW)
            page.click("#welcome-do_login")
            submitted = True          # 只提交一次，别把失败刷成死循环
        page.wait_for_timeout(1000)
    page.screenshot(path=C.OUT + "/01_relogin_failed.png", full_page=True)
    sys.exit("reload 之后 180 秒回不到主界面（cookie 自动登录 + 表单登录都没成）\n"
             "  页面文字 %d 字" % len(page.inner_text("body")))


def ensure_no_modal(page, timeout=10):
    """把那个**只问一次**的「AI 怎么干活？」首选项弹窗关掉。

    ⚠️ 它是新账号第一次开对话时自己弹的（mod_chat.R 的 onboarding），盖在
      整页上 —— 有它在，点 `#chat-send` 会一直报
      「<div id="shiny-modal"> intercepts pointer events」，
      **报错指向的是"发送按钮点不动"**，和真正的原因（一个首选项弹窗）
      隔着十万八千里。

    选「都先别开，我自己盯着」（`agent_pref_manual`）是刻意的：探针要的是
    **一轮一问一答**，自动执行开着的话 agent 循环会自己往下跑，后面那些
    "发一条、断言一条"的时序全乱。item 7 的自动执行那一段**不能**用这个
    函数收尾 —— 见 `enable_agent_mode()`。

    ⚠️ 只处理这一个已知的弹窗。**出现别的弹窗要炸出来**，不要顺手 Escape
      —— 那样会把自己想测的东西一起关掉。
    """
    end = time.time() + timeout
    while time.time() < end:
        if page.locator("#shiny-modal:visible").count() == 0:
            if page.locator(".modal-backdrop:visible").count() == 0:
                return True
        btn = page.locator("#chat-agent_pref_manual")
        if btn.count():
            btn.first.click()
            page.wait_for_timeout(1500)
            continue
        page.wait_for_timeout(300)
    if page.locator("#shiny-modal:visible").count():
        txt = page.evaluate(
            "() => (document.querySelector('#shiny-modal')||{}).innerText || ''")
        sys.exit("页面上压着一个**不认识的**弹窗，探针不猜它是什么：\n%s"
                 % txt[:400])
    return True


def enable_agent_mode(page):
    """把「自动执行」勾上，并且**按用户的真实路径**答完那个首选项弹窗。

    ⚠️ 不能用 `ensure_no_modal()` 收尾：它点的是 `#chat-agent_pref_manual`
      （「都先别开」），那会 `updateCheckboxInput(agent_mode, FALSE)` ——
      刚勾上的开关会被**自己按回去**，后面那一节测的就成了"自动执行关着"，
      而它看起来和"循环停了"一模一样（同一个假绿形态）。

    勾上之后弹窗里 `pref_ask_auto` 预勾的是**当前** `input$agent_mode`，
    所以点 `#chat-agent_pref_save` 存下来的就是 auto = TRUE。
    """
    box = page.locator("#chat-agent_mode")
    if box.count() == 0:
        print("    ⚠️ 找不到 #chat-agent_mode（自动执行那颗勾）", flush=True)
        return False
    if not box.first.is_checked():
        # ⚠️ 三层退路：正常是 check()，它带可操作性检查（有的皮肤把
        #    checkbox 画成 0×0、靠旁边的假开关显示点击）—— 那种情况下
        #    check() 会等到超时。退到 click()、再退到直接发 Shiny 输入。
        #    最后那层是"绕过界面点一下"，只在这里用：这一节要验的是**发出去
        #    之后的行为**，不是这颗勾本身好不好点；用了它会打出来。
        try:
            box.first.check(timeout=8000)
        except Exception:
            try:
                box.first.click(force=True, timeout=5000)
            except Exception:
                page.evaluate("() => Shiny.setInputValue("
                              "'chat-agent_mode', true, {priority: 'event'})")
                print("    ⚠️ 那颗勾是直接发 Shiny 输入勾上的（不是点出来的）",
                      flush=True)
        page.wait_for_timeout(800)
    # 首选项弹窗（只问一次）。等它出来 —— 不出说明这个账号已经答过了
    # （`ensure_no_modal()` 在前面某一节替它答过一次就属于这一种）。
    for _ in range(10):
        if page.locator("#chat-agent_pref_save").count():
            page.locator("#chat-agent_pref_save").first.click()
            page.wait_for_timeout(1500)
            break
        page.wait_for_timeout(300)
    # 弹窗关干净了再往下走：`.modal-backdrop` 还在的话，后面第一次
    # `page.fill("#chat-input")` 会被它吃掉（报的是 "intercepts pointer events"，
    # 指向的却是输入框）。
    end = time.time() + 10
    while time.time() < end and page.locator("#shiny-modal:visible").count():
        page.wait_for_timeout(300)
    chk_on = page.locator("#chat-agent_mode").first.is_checked()
    still = page.locator("#shiny-modal:visible").count()
    if still:
        print("    ⚠️ 首选项弹窗没关掉（还压着 %d 个），后面会点不动"
              % still, flush=True)
    return chk_on


def busy(page):
    """服务端说"这一轮还在跑"。

    ⚠️ `#chat-send` 只在对话页有，但 bslib 把没激活的页也留在 DOM 里 ——
      隐藏元素的 `disabled` 读出来照样是 True，那会让 `wait_idle` 永远等
      下去。所以这里只在**对话页**上量（调用方都先 goto 过）。
      真正"看得见"的那一颗由前端 `.dsapp-busy` / `disabled` 一起表达，
      服务端那一下由 `rv$streaming` 表达（mod_chat.R 的 dsapp:busy 消息）。
    """
    try:
        return page.locator("#chat-send[disabled]").count() > 0
    except Exception:
        return False


def busy_signals(page):
    """"界面还在忙"的三个信号，分开看 —— 报失败时要能看出是哪一个没退。"""
    try:
        return {
            "send_disabled": page.locator("#chat-send[disabled]").count() > 0,
            "cursor": page.locator(".dsapp-cursor").count() > 0,
            "wait_box": page.locator(".dsapp-wait").count() > 0,
        }
    except Exception:
        return {"send_disabled": None, "cursor": None, "wait_box": None}


def wait_idle(page, timeout=90):
    """等到这一轮真的结束。**不是**"等某个元素出现" —— 那种提前返回的写法
    会让后面的动作和服务端重画抢跑，报出来的错指向完全无关的地方
    （fake-wait-is-not-a-wait）。"""
    end = time.time() + timeout
    t0 = time.time()
    while time.time() - t0 < 20:
        if busy(page):
            break
        page.wait_for_timeout(150)
    while time.time() < end:
        if not busy(page):
            page.wait_for_timeout(600)   # 再稳一拍，避开"刚好在两轮之间"
            if not busy(page):
                return True
        page.wait_for_timeout(250)
    return False


def send(page, text, timeout=90):
    ensure_no_modal(page, timeout=3)
    page.fill("#chat-input", text)
    page.click("#chat-send")
    ok = wait_idle(page, timeout)
    if not ok:
        page.screenshot(path=C.OUT + "/02_send_timeout.png", full_page=True)
    return ok


def sql(db, q, args=()):
    con = sqlite3.connect(db, timeout=15)
    try:
        return con.execute(q, args).fetchall()
    finally:
        con.close()


def enter_with_retry(browser):
    """注册进主界面，最多试 3 次。

    ⚠️ 为什么要重试：这几个测试实例上，`enter_app` 偶尔会在「注册完之后
      页面空白」那一关失败，而这**不是本版的回归** —— 2026-09-28 拿
      V15.2 那个实例做对照，同样失败。每一次 enter_app 都注册一个新账号，
      所以重试是安全的（不会撞邮箱）。
    """
    last = None
    for i in range(3):
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        try:
            C.enter_app(page, email="v155_%s_%d@example.com"
                        % (str(int(time.time()))[-6:], i))
            return page
        except SystemExit as e:
            last = e
            print("  ⚠️ 第 %d 次注册没进去，重来：%s" % (i + 1, str(e)[:120]),
                  flush=True)
            try:
                page.close()
            except Exception:
                pass
            time.sleep(3)
    sys.exit("连着 3 次都没注册进去，最后一次是：\n%s" % last)


def clear_learned_windows():
    """把库里"学到的上下文窗口"清干净，**B 才有意义**。

    ⚠️⚠️ `model_param_limits` 是**全局表**（没有 user_id，键是
      (vendor, model, param)，见 R/models.R:1663 的建表语句和本仓
      「学到的上限表是全局的」那条教训）。而 item 7 那一节会往
      (deepseek, <模型名>, context_length) 写一条 **65536**（厂商在 400 里
      说的窗口就是它，`dsapp_param_learn()` 把"只往紧里收"的那一个记下来）。

      留着的话，在**同一个实例上第二次**跑这个探针时，`dsapp_ctx_limit()`
      会先命中那一行 —— 滑块量程变成 "1K ~ 64K"，B 红，而红的原因和被测
      代码毫无关系（是上一轮探针留下的毒）。

    ⚠️ 它只清 `context_length` 这一种 param，别的（max_tokens 那些）不动：
      那些是别的探针/自检的夹具，顺手清掉会污染它们。

    ⚠️ 还有一层它清不掉的：`dsapp_param_learned_put()` 写的**进程内缓存**
      （R/models.R:1755）。那个只在这个 R 进程里活着，而 worker 空闲几秒就
      被回收，所以换一轮探针基本是新进程。真撞上了，B 的失败信息里会把
      标签原文和库里那一行一起打出来，用来把这两种原因分开。
    """
    p = C.db_path()
    if p is None:
        return []
    con = sqlite3.connect(p, timeout=15)
    try:
        try:
            rows = con.execute(
                "SELECT vendor, model, max_value FROM model_param_limits"
                " WHERE param = 'context_length'").fetchall()
        except sqlite3.OperationalError:
            return []          # 表还没建（全新库）—— 那本来就是干净的
        if rows:
            con.execute("DELETE FROM model_param_limits"
                        " WHERE param = 'context_length'")
            con.commit()
        return rows
    finally:
        con.close()


def learned_windows(db):
    """库里"学到的上下文窗口"（`model_param_limits` 里 param = context_length）。

    ⚠️ 表可能还没建（实例刚起来、schema 还没 migrate）—— 那种情况**不是**
      "库里是脏的"，是"还没到那一步"。所以返回 [] 而不是抛出去：抛的话
      探针会崩在这一行，报出来的是 sqlite 的 "no such table"，
      和被测的东西毫无关系。
    """
    try:
        return sql(db, "SELECT vendor, model, max_value FROM model_param_limits"
                       " WHERE param = 'context_length'")
    except sqlite3.OperationalError:
        return []


def user_msg_n(db, uid):
    return sql(db, "SELECT COUNT(*) FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'user'", (uid,))[0][0]


def last_assistant(db, uid):
    """这个账号**最新**的那条 assistant 消息（id, content）。

    ⚠️ 不查 `sessions` 的"最新会话"，直接按消息排 —— 中间要是新建过一个
      对话（比如某个动作悄悄开了新会话），按会话找会指向另一条对话，
      报出来的错会变成"库里没有那条说明"，和真正的原因（找错了地方）无关。
    """
    rows = sql(db, "SELECT m.id, m.content FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'assistant'"
                   " ORDER BY m.rowid DESC LIMIT 1", (uid,))
    return (None, "") if not rows else (rows[0][0], rows[0][1] or "")


def notifications(page):
    """屏幕上所有 `.shiny-notification` 的文字。

    ⚠️ 取**全部**，不是第一个命中就下结论（本仓「grep | head 会截断」那条：
      在 Python 里就是"别只取第一个匹配"）。原因很实在：这一页上随时可能
      还挂着别的通知（比如答完首选项弹窗那句「记住了：…」，duration = 8 秒），
      只看第一条就会把"还没弹出来"和"弹了别的"混成一句话报出去。
    """
    try:
        return page.evaluate(
            "() => [].slice.call(document.querySelectorAll('.shiny-notification'))"
            ".map(function (e) { return (e.innerText || '').trim(); })")
    except Exception:
        return []


def clear_notifications(page):
    """把屏幕上已经挂着的 `.shiny-notification` 清掉，返回清掉的条数。

    ⚠️⚠️ 这一步**必须做**，不是打扫卫生：上下文那条通知 `duration = NULL`
      （R/mod_chat.R:5145，永不自动消失），而 C 这一节要跑**两遍**
      （手动、自动）。不清的话第二遍的 `wait_notification()` 会**当场命中
      第一遍留下的那条** —— 报出来的是"0.0 秒就弹了，完美"，而第二个 400
      的通知可能压根没弹过。这是本仓"两次运行写同一个日志会交错"的同一类
      错：不隔离上一次动作的残留，断言就会量到别人的东西上。

    ⚠️ 直接摘节点，不点关闭按钮：`.shiny-notification-close` 有的皮肤里被
      藏掉/换了样式，点它会变成一条"点不动"的假红。节点摘掉之后 Shiny 自己
      那条到期移除会作用在空集合上，是 no-op。
    """
    try:
        n = page.evaluate(
            "() => { var els = document.querySelectorAll('.shiny-notification');"
            " var n = els.length;"
            " for (var i = 0; i < els.length; i++) {"
            "   var p = els[i].parentNode; if (p) p.removeChild(els[i]); }"
            " return n; }")
        return n or 0
    except Exception:
        return 0


def wait_notification(page, needle, timeout=90):
    """轮询到某条通知里出现 needle。返回 (命中文本, 从调用起过了几秒)。

    ★ 为什么非要轮询：只查一次的话，服务端的 400 还没回来就查完了 ——
      报出来的是"没弹通知"，而真相是"查早了"（fake-wait-is-not-a-wait）。
    """
    t0 = time.time()
    end = t0 + timeout
    while time.time() < end:
        for t in notifications(page):
            if needle in t:
                return t, time.time() - t0
        page.wait_for_timeout(250)
    return None, time.time() - t0


# =============================================================================
# A. item 6：上下文读条里的数是**真算的**
# =============================================================================

# 服务端那句是
#   sprintf("上下文 ≈%s / %s（%d%%）", fmt(used), fmt(limit), pct)
# （R/mod_chat.R:3746-3749）。`≈` 是刻意的：它是估算不是分词。
_CTX_RE = re.compile(
    r"上下文\s*≈\s*(?P<used>[^/]+?)\s*/\s*(?P<limit>[^（(]+?)\s*"
    r"[（(]\s*(?P<pct>\d+)\s*%\s*[)）]")


def parse_tok(s):
    """把 `dsapp_fmt_tokens_short` 的输出还原成一个数。

    那个函数的三种写法（R/models.R:1427）：
      · "1.5M" / "2M"   —— n >= 1048576
      · "64K"           —— n >= 1024 且**正好**是 1024 的整数倍
      · "65,536"        —— 其余（带千分位）
    所以 "K"/"M" 要乘回去，逗号要去掉。
    ⚠️ 这是**近似**还原（"1.4M" 丢掉了尾巴）。下面那条"used 变大"的断言
      因此要求的是"变大"，不是"等于某个数" —— 近似的精度足够支撑它，
      只要第二条消息真的明显更长（见 `item6a_ctxbar()` 里那段）。
    """
    if s is None:
        return None
    s = s.strip().replace(",", "").replace("，", "")
    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([KkMm]?)$", s)
    if not m:
        return None
    v = float(m.group(1))
    u = m.group(2).upper()
    if u == "K":
        v *= 1024.0
    elif u == "M":
        v *= 1048576.0
    return v


def ctx_state(page):
    """从 `#chat-hint` 里把读条读回来（文字 + 那条 `i` 的 style 宽度）。

    ⚠️ 宽度是从 **style 属性**里读的，不是量 `<i>` 的矩形：那条 `i` 的
      宽度是相对父节点（`.dsapp-ctxbar`，固定 46px）的百分比，量出来的
      px 要先除以 46 才能比 —— 多一步换算就多一个出错的地方。
      判据要的本来就是"服务端写进去的那个数对不对"。
    """
    return page.evaluate(r"""() => {
        var hs = document.querySelectorAll('#chat-hint');
        var bar = document.querySelector('.dsapp-ctxbar');
        var i   = document.querySelector('.dsapp-ctxbar > i');
        var w = null;
        if (i) {
            var mm = /width\s*:\s*([0-9.]+)\s*%/.exec(i.getAttribute('style') || '');
            if (mm) w = parseFloat(mm[1]);
        }
        var br = bar ? bar.getBoundingClientRect() : null;
        return {
            n_hint: hs.length,
            text: hs.length ? (hs[0].innerText || '') : null,
            bar_w: w,
            has_bar: !!bar,
            bar_box: br ? Math.round(br.width) + 'x' + Math.round(br.height) : null
        };
    }""")


def wait_ctx(page, timeout=45):
    """轮询到读条形如 `上下文 ≈… / …（N%）` 且那条 `i` 有宽度。

    ⚠️ 只在 `rv$ctx` **拿到过 plan** 之后才画（R/mod_chat.R:3730）——
      第一次发消息之前它压根不存在。所以这里必须等，而不是查一次。
    """
    end = time.time() + timeout
    st = None
    while time.time() < end:
        st = ctx_state(page)
        if (st["n_hint"] == 1 and st["text"] and st["has_bar"]
                and st["bar_w"] is not None and _CTX_RE.search(st["text"])):
            return st
        page.wait_for_timeout(300)
    return st


def item6a_ctxbar(page, uid, db, fx):
    print("\n== A. item 6：上下文读条里的数是真算的 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    # ---- 第一条：短消息 ----------------------------------------------------
    fx.set_queue(C.sse("收到，第一条。"))
    ok = send(page, "第一条：短问题。")
    chk("★ 前提：第一条消息真的发出去了", ok, "wait_idle 超时")

    st1 = wait_ctx(page)
    txt1 = st1["text"] or ""
    print("    hint 第 1 次：%r（#chat-hint %d 个，条宽 %s）"
          % (txt1[:160], st1["n_hint"], st1["bar_w"]), flush=True)

    m1 = _CTX_RE.search(txt1)
    chk("★★★ 输入框左下角出现了「上下文 ≈… / …（N%）」这一行",
        m1 is not None and st1["n_hint"] == 1,
        "hint 文字 %r（#chat-hint %d 个）" % (txt1[:200], st1["n_hint"]))
    if m1 is None:
        # 没这一行，后面三条全都没有意义 —— 直接停在这里，别报一串假红
        return None

    pct1 = int(m1.group("pct"))
    used1 = parse_tok(m1.group("used"))
    lim1 = parse_tok(m1.group("limit"))
    print("    解析：used=%s limit=%s pct=%d" % (used1, lim1, pct1), flush=True)

    chk("★★★ 百分比是个 0~100 的数字（不是占位符/空串）",
        0 <= pct1 <= 100, "N=%r（原文 %r）" % (pct1, m1.group(0)))
    chk("★★ 那个 used / limit 也是数（不是 `—` 这类退化输出）",
        used1 is not None and lim1 is not None and lim1 > 0,
        "used=%r limit=%r" % (m1.group("used"), m1.group("limit")))
    # 读条里那条 `i` 的宽度是**服务端写进 style 的**：sprintf("width:%d%%",
    # max(1L, p$pct))（R/mod_chat.R:3752）。所以 0% 会被画成 1% —— 差 1 是
    # 设计里就有的，判据给的就是"差 ≤ 1"。
    chk("★★★ 读条那条 `i` 的宽度和 N 对得上（差 ≤ 1）",
        st1["bar_w"] is not None and abs(st1["bar_w"] - pct1) <= 1,
        "style 宽度 %r vs N=%d" % (st1["bar_w"], pct1))

    # ★★ N 是不是**真的按那两个数算的**：服务端那句是
    #      pct = min(100L, as.integer(round(100 * used / lim)))   （models.R:1278）
    #    ⚠️ 少了这一条，"N 是个写死的 3%、宽度也画 3%"能同时过上面两条 ——
    #      它们是自洽的，只是和 used/limit 无关。
    #    ⚠️ 容差：used / limit 到了 M 那一档会被写成 "1.4M" 这种一位小数
    #      （±5 万 token），换算回百分比能差好几个点，所以那一档放宽。
    #      小数值这一档（几千、几万 token）是**整数带千分位**，一模一样。
    tol = 1.0 if max(used1 or 0, lim1 or 0) < 1048576 else 6.0
    ratio_ok = (used1 is not None and lim1 not in (None, 0)
                and abs(pct1 - 100.0 * used1 / lim1) <= tol)
    chk("★★★ N 确实等于 used / limit（不是另写死的数）", ratio_ok,
        "N=%d，而 100*%s/%s = %.1f（容差 %.1f）"
        % (pct1, used1, lim1, 100.0 * (used1 or 0) / (lim1 or 1), tol))
    # 反面：读条在 DOM 里但**没画出来**（父节点塌了/被藏了）时上面那条照样过。
    # 它的高度是 CSS 里写死的 6px、宽度 46px，所以这里量得到 46x6 才算真在。
    chk("★ 那条读条是**看得见**的（46x6 的小横条，不是 0×0）",
        st1["bar_box"] not in (None, "0x0"), "bar_box=%s" % st1["bar_box"])

    # ---- 第二条：明显更长 --------------------------------------------------
    #
    # ★★★ 这一条是**整节的要害**：百分比和宽度都可能只是一个常数在自洽
    #     （画死一个 3% + width:3% 就能全过）。只有"发的东西变多了，那个数
    #     跟着变大"能证明它是**按这一次真正要发出去的 messages 算的**。
    #
    # ⚠️ 第二条必须**明显**更长（这里一千多字）。`dsapp_fmt_tokens_short`
    #    会把 1M 写成 "1.4M" 那种带一位小数的形式，还原出来是近似的 ——
    #    只多几十个 token 的话，四舍五入之后可能一模一样，那条断言就会
    #    因为**精度**而红，和被测的东西无关。
    long_line = ("第二条：这条故意写得很长。" + "这是一段用来把上下文撑起来的废话。" * 60)
    fx.set_queue(C.sse("收到，第二条。"))
    ok = send(page, long_line)
    chk("★ 前提：第二条消息也发出去了", ok, "wait_idle 超时")

    st2 = wait_ctx(page)
    txt2 = st2["text"] or ""
    print("    hint 第 2 次：%r" % txt2[:160], flush=True)
    m2 = _CTX_RE.search(txt2)
    chk("★★★ 第二条之后读条还在（没被生成过程弄丢）", m2 is not None,
        "hint 文字 %r" % txt2[:200])
    if m2 is None:
        return None

    used2 = parse_tok(m2.group("used"))
    print("    解析：used=%s（第 1 次是 %s），涨了 %s"
          % (used2, used1, (used2 - used1) if (used1 is not None
                                               and used2 is not None) else "?"),
          flush=True)
    chk("★★★ 同一条对话里，发完第二条更长的消息之后 used **变大了**"
        "（= 它是真算的，不是写死的常量）",
        used1 is not None and used2 is not None and used2 > used1,
        "第 1 次 used=%s（%r），第 2 次 used=%s（%r）"
        % (used1, m1.group("used"), used2, m2.group("used")))
    # ★★ "变大"还不够：一个**和内容无关**的计数器（会话累计、跑了多久、
    #   消息条数 × 常数）也会单调变大，而且照样过上面那一条。
    #   上面那段废话是一千多字，估算器按"中文 1 字 1 token"（models.R:1113）
    #   至少要加 1000 —— 所以涨的幅度得是**那个量级**，不是"涨了一点"。
    #   ⚠️ 阈值只给 200（真值 ≈1040），留足余量：这里判的是量级，
    #     不是精确的分词数（那是另一件不该由浏览器探针管的事）。
    delta = (used2 - used1) if (used1 is not None and used2 is not None) else None
    chk("★★ 而且涨的幅度和真塞进去的那一千多字是一个量级（≥200 tokens）",
        delta is not None and delta >= 200,
        "涨了 %s（第 2 条正文 %d 字）" % (delta, len(long_line)))
    return {"used1": used1, "used2": used2, "pct1": pct1,
            "pct2": int(m2.group("pct"))}


# =============================================================================
# B. item 6：滑块量程按**这个模型自己的窗口**自适应
# =============================================================================

def r_const(name, default=None):
    """从**被测实例**的 R 源码里读一个顶层常量（`NAME <- 4096L` 这种）。

    ★ 为什么要读源码而不是把数字抄进探针：那个下界是应用**自己**定的
      （R/models.R 的 DSAPP_CTX_MIN_TOTAL，被 dsapp_ctx_range() 当滑块的
      min 用，R/models.R:1249）。抄成字面量的话，哪天应用调了它，红的是
      "量程按模型自适应"那一条 —— 看起来像功能坏了，实际只是测试没跟上：
      V15.5 这一版正好把它从 1024 提到了 4096，第一轮探针就是这么红的。

    ⚠️ 读的是 **C.APP**（/tmp 那个实例）里的那份，不是开发仓库的：界面上
      渲染的是实例正在跑的那份代码，两边不一致时以**它**为准。
    """
    pat = re.compile(r"(?m)^\s*%s\s*<-\s*([0-9]+)\s*L?\s*(?:#.*)?$"
                     % re.escape(name))
    for f in sorted(os.listdir(os.path.join(C.APP, "R"))
                    if os.path.isdir(os.path.join(C.APP, "R")) else []):
        if not f.endswith(".R"):
            continue
        p = os.path.join(C.APP, "R", f)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                m = pat.search(fh.read())
        except OSError:
            continue
        if m:
            return int(m.group(1))
    return default


def item6b_range(page, uid, db):
    print("\n== B. item 6：deepseek 那一档的量程应该到 1M ==", flush=True)

    # ★ 先回库看一眼有没有"学到的窗口"残留 —— 有的话量程本来就不该是 1M，
    #   那条断言会红在一个和被测代码无关的地方。清掉 + 说出来。
    left = learned_windows(db)
    chk("★ 前提：库里没有残留的 context_length（清干净了才量得准）",
        left == [], "残留 %s" % (left,))

    C.goto(page, "model")
    page.wait_for_timeout(1500)

    # 厂商设成 deepseek。⚠️ 走 pick_select：selectInput 默认 selectize = TRUE，
    # 原生的 <select> 是 0×0 的，`page.select_option` 会一直等到超时，
    # 报的是 "element is not visible"（指向"这个控件不存在"）。
    try:
        C.pick_select(page, "model-vendor", "deepseek")
    except Exception as e:
        print("    ⚠️ 选厂商这一步没成：%s" % str(e)[:200], flush=True)
    page.wait_for_timeout(2500)

    labels = page.eval_on_selector_all(
        ".dsapp-maxtok-label", "els => els.map(e => e.innerText || '')")
    vend = ""
    try:
        vend = page.input_value("#model-vendor")
    except Exception:
        pass
    print("    厂商控件=%r；.dsapp-maxtok-label × %d：%s"
          % (vend, len(labels), [l.strip()[:80] for l in labels]), flush=True)

    if not labels:
        # ---- 降级路径：取不到就是"没验成"，**不许伪造通过** ----------------
        body = page.inner_text("body")
        chk("★ B 降级：模型页上取不到 `.dsapp-maxtok-label`（量程那格没渲染）",
            False,
            "页面上有「单次使用上限」这几个字吗：%s；正文 %d 字"
            % ("单次使用上限" in body, len(body)))
        print("    ⚠️⚠️ **B 没验成**：界面上取不到那一格，降级成"
              "「标签存不存在」也没过。量程自适应这件事这一轮**没有验过**。",
              flush=True)
        B_VERIFIED[0] = False
        return

    # 降级的那半：标签文字的开头对不对（这一条无论能不能拿到量程都成立）
    head_ok = all(l.strip().startswith("单次使用上限（tokens，") for l in labels)
    chk("★★ 标签文字是「单次使用上限（tokens，… ~ …）」（改名生效）",
        head_ok, [l.strip()[:80] for l in labels])

    rng = [re.search(r"单次使用上限（tokens，\s*([^~]+?)\s*~\s*([^）]+)）", l)
           for l in labels]
    if not all(rng):
        chk("★★★ 从**渲染出来的标签**里读出了量程（… ~ …）", False,
            [l.strip()[:80] for l in labels])
        print("    ⚠️⚠️ **B 没验成**：标签在，但形状不对，读不出量程。",
              flush=True)
        B_VERIFIED[0] = False
        return

    lo = [m.group(1).strip() for m in rng]
    hi = [m.group(2).strip() for m in rng]
    print("    量程（渲染出来的文字）：%s" % list(zip(lo, hi)), flush=True)

    # ★★★ 判据是**文字**，不是源码：读的是浏览器里画出来的那一行。
    #     deepseek 的窗口在本仓是有出处的（DSAPP_CTX_VENDOR$deepseek =
    #     1048576L，R/models.R:1053），而 dsapp_fmt_tokens_short(1048576)
    #     出来正好是 "1M"。改之前那条滑块是所有厂商一律 "1K ~ 10M"。
    chk("★★★ 上界是 **1M**（= 这个模型自己的窗口，不是所有厂商一律的 10M）",
        all(h == "1M" for h in hi), "上界 %s" % hi)

    # ★★ 下界：**不写死**。把应用自己那个常量从被测代码里读出来再比 ——
    #    写死的话，改了常量红的是这一条，而它看起来像"量程没自适应"。
    floor_tok = r_const("DSAPP_CTX_MIN_TOTAL")
    chk("★ 前提：读得到 R/models.R 里的 DSAPP_CTX_MIN_TOTAL"
        "（下面那条判据的下界就是它）",
        floor_tok is not None, "在 %s/R/*.R 里没找到这个名字" % C.APP)
    want_lo = ("%dK" % (floor_tok // 1024)) if (floor_tok or 0) >= 1024 else None
    chk("★★ 下界就是**这个应用自己的下限**（DSAPP_CTX_MIN_TOTAL=%s → 画成 %r），"
        "不是所有厂商一律的 1K" % (floor_tok, want_lo),
        bool(want_lo) and all(l == want_lo for l in lo), "下界 %s" % lo)

    if all(h == "1M" for h in hi):
        B_VERIFIED[0] = True
    else:
        # 红的时候把"是不是上一轮学的窗口在捣鬼"一起打出来，省一轮排查。
        print("    ⚠️ B 红。库里的 context_length：%s（空的话就不是它）"
              % (learned_windows(db),), flush=True)


# =============================================================================
# D. item 8：生成期间那颗转圈只该有**一个实例**
#
# ★ 尺子照 tests/ui_v155/measure_flash.py 搬：给带 CSS 动画的节点盖一次性
#   `dataset` 记号，数"同一个选择器下出现过多少个不同的节点实例"。
#   CSS 动画是**跟着元素走**的 —— 节点一被替换，Bootstrap 那条
#   `animation: .75s linear infinite` 的旋转就从 0 度重新开始，用户看到的
#   不是"在转"，是"一秒抖一下"。所以"实例数"就是"闪"的直接度量。
#
# ⚠️⚠️ 这个度量单独用会**假绿**：节点 `display:none` 的时候实例数恒为 1，
#    而 `.dsapp-hint-spin` 默认就是 `display:none`（app.css:687）。
#    所以下面配了两条"这段采样真的落在生成期间"和"那颗转圈真的亮着"的
#    断言 —— 没有它们，把 index.html 里那颗 span 删掉都能全绿。
# =============================================================================

_ARM_JS = r"""() => {
  if (window.__v155p) return;
  window.__v155p = {anim: {}, samples: 0, busy: 0,
                    spin_on: 0, spin_visible: 0};
}"""

_SAMPLE_JS = r"""() => {
  var R = window.__v155p;
  if (!R) return null;
  R.samples += 1;

  var SEL = ['.dsapp-composer-hint .spinner-border',   /* 主角 */
             '.dsapp-hint-spin',                       /* 同一个东西的别名 */
             '.spinner-border',                        /* 全页聚合 */
             '.dsapp-wait-spin',                       /* 占位气泡里那颗 */
             '.dsapp-run-chip .spinner-border',        /* 侧栏"任务执行中" */
             '.dsapp-btn-running .spinner-border',
             '.dsapp-cursor', '.dsapp-progress'];      /* 另外两处动画 */
  var now = performance.now();
  SEL.forEach(function (s) {
    var els = document.querySelectorAll(s);
    var st = R.anim[s] || (R.anim[s] = {seen: {}, alive: 0, maxAlive: 0});
    st.alive = els.length;
    if (els.length > st.maxAlive) st.maxAlive = els.length;
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (!e.dataset.v155u) {
        /* 第一次见到这个节点 = 一个新实例。上一次的动画到此为止。 */
        e.dataset.v155u = 'u' + Math.random().toString(36).slice(2);
      }
      st.seen[e.dataset.v155u] = 1;
    }
    st.uniq = Object.keys(st.seen).length;
  });

  /* ★ 那颗转圈**真的亮着**过没有。`is-on` 由 www/app.js 的忙闲 tick 切
     （app.js:2373），而它跟着 `.dsapp-cursor / .dsapp-wait` 走。 */
  var sp = document.querySelector('.dsapp-composer-hint .spinner-border');
  if (sp && sp.classList.contains('is-on')) {
    R.spin_on += 1;
    var r = sp.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) R.spin_visible += 1;
  }

  /* 采样点自己记一份忙闲，用来证明"这段采样落在生成期间" */
  var b = document.querySelector('#chat-send');
  var isBusy = !!(b && b.disabled);
  if (isBusy) R.busy += 1;
  return {samples: R.samples, busyNow: isBusy};
}"""


def item8_spinner(page, uid, db, fx):
    print("\n== D. item 8：生成期间那颗转圈只该有一个实例 ==", flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    # 慢放：整段回复在一个 200ms 轮询周期里吐完的话，**一次采样都取不到**，
    # "实例数 == 1"会因为没采样而通过（假绿）。0.4 秒一块 × 二十来块 ≈ 十几秒。
    fx.slow(0.4)
    parts = ["先看用户给了什么。", "这一步要确认物种和注释版本。",
             "然后决定是走比对还是走定量。", "定量的话得先有 count 矩阵。",
             "还得确认参考基因组对不对。", "最后把步骤写成代码。",
             "检查一遍依赖装没装。", "再核一遍输出目录。",
             "再核一遍物种。", "再核一遍参考基因组。",
             "把参数写进配置。", "好了，可以动笔了。"]
    fx.set_queue(C.sse_multi(parts, "好，我按这个思路来。"))

    page.evaluate(_ARM_JS)
    page.fill("#chat-input", "想一个分析方案")
    page.click("#chat-send")

    n, last = 0, None
    t0 = time.time()
    while time.time() - t0 < 150:
        last = page.evaluate(_SAMPLE_JS)
        n += 1
        if last and n > 8 and not last["busyNow"]:
            break                       # 生成结束了，而且至少采了 1.2 秒
        page.wait_for_timeout(150)
    fx.no_slow()

    out = page.evaluate("() => window.__v155p")
    anim = out["anim"]
    print("    采样 %d 次（%.1f 秒），其中「忙」的 %d 次；"
          "那颗转圈亮着 %d 次、真的占位 %d 次"
          % (n, time.time() - t0, out["busy"], out["spin_on"],
             out["spin_visible"]), flush=True)
    for k in sorted(anim, key=lambda s: -anim[s]["uniq"]):
        v = anim[k]
        print("      %-36s 实例 %2d  同屏最多 %d  收尾同屏 %d"
              % (k, v["uniq"], v["maxAlive"], v["alive"]), flush=True)

    # ---- 反假绿两条 --------------------------------------------------------
    chk("★ 前提：这段采样真的落在生成期间（忙的样本 ≥ 5）",
        out["busy"] >= 5, "忙样本 %d / 共 %d" % (out["busy"], out["samples"]))
    chk("★ 前提：那颗转圈**真的亮着**过（`is-on` 且占位，≥ 3 个样本）"
        "—— 不然下面那条「实例 == 1」是 display:none 白送的",
        out["spin_visible"] >= 3,
        "亮着 %d 次、占位 %d 次" % (out["spin_on"], out["spin_visible"]))

    # ---- 主角 --------------------------------------------------------------
    key = ".dsapp-composer-hint .spinner-border"
    a = anim.get(key) or {"uniq": None, "maxAlive": None, "alive": None}
    chk("★★★ `.dsapp-composer-hint .spinner-border` 全程**只有 1 个实例**"
        "（改之前实测 14）",
        a["uniq"] == 1, "实例数 %s（同屏最多 %s）" % (a["uniq"], a["maxAlive"]))
    chk("★★ 而且同屏从来没有同时出现过两颗", a["maxAlive"] == 1,
        "maxAlive=%s" % a["maxAlive"])

    # ---- 别的 spinner-border -------------------------------------------------
    others = sorted(anim)
    spinners = [s for s in others if "spinner-border" in s and s != key]
    uniqs = {s: anim[s]["uniq"] for s in spinners}
    print("    别的 spinner-border：%s" % uniqs, flush=True)
    print("    不算 spinner 的那两处（只报不改）：%s"
          % {s: anim[s]["uniq"] for s in others if "spinner-border" not in s},
          flush=True)

    # ★ 判据给到 4 而不是 1：占位气泡那颗（`.dsapp-wait-spin`）是**允许**
    #   重建的 —— 它那一格一轮里最多重画 3 次（think_gen / rv$streaming /
    #   rv$text_started 三个粗粒度信号，见 R/mod_chat.R:5424 那段说明），
    #   每次重画换一个节点是设计内的事。而"每秒抖一下"那颗是 14。
    # ⚠️ 这条只扫 **spinner-border**（用户第 8 条说的就是它）。`.dsapp-cursor`
    #   / `.dsapp-progress` 不在这条的判据里，它们只是被打印出来 ——
    #   那两处是 V15.4 item 3 的地盘，把它们混进来只会让这条在别的地方红。
    bad = {s: n for s, n in uniqs.items() if n > 4}
    chk("★★ 屏幕上别的 spinner-border 没有在**反复**重建（每个 ≤ 4 个实例）",
        not bad, "超标的 %s；全部 %s" % (bad, uniqs))
    # 任务没在跑的时候，这两颗根本不该存在（0 个实例才是对的）
    for s in (".dsapp-run-chip .spinner-border",
              ".dsapp-btn-running .spinner-border"):
        v = anim.get(s)
        chk("★ 没跑任务时 `%s` 不该出现" % s,
            v is None or v["uniq"] <= 1, v)

    page.wait_for_timeout(500)


# =============================================================================
# C. item 7：超上下文**当场**反馈 + 落库 + 循环停
# =============================================================================

# ★ 这句话是**照厂商真实报错的形状**写的（用户贴出来的那种）。
#   ⚠️ 必须是 JSON 错误体 `{"error":{"message":...}}`，不是一句纯文本：
#      llm.R 会先试 `fromJSON(body)$error$message`，解析不出来才退回整段
#      body（R/llm.R:262-267）—— 纯文本的话界面上那句会带着 `{"error":{…}}`
#      的壳，和厂商真实的样子不一样。`_common.FakeLLM.arm_400()` 收的正是
#      **message**，外面那层壳由 fake_llm.py 自己套（它支持这件事）。
_CTX_400 = ("This model's maximum context length is 65536 tokens. "
            "However, your messages resulted in 81234 tokens.")

# 通知正文（R/mod_chat.R:5151）：
#   "上下文超出模型窗口，这一次请求没有发出去。已把窗口改成 65,536，下一条就按新的算。"
_NOTE_NEEDLE = "上下文超出模型窗口"

# 落库那条说明的开头（R/models.R:1896 的 dsapp_ctx_error_advice）：
#   "**这一次请求没能发出去：上下文超了。**\n\n厂商那边的原话是：\n\n> …"
_DB_NEEDLES = ["没能发出去", "上下文"]

# ★ 自动执行那一段的第一个请求**必须成功**，而且回复里要有一个可执行的
#   代码块 —— 否则循环压根不会进 running，后面"循环停了"就是一句废话。
#   这条回复的形状是按 dsapp_agent_pick_block() 的要求凑的（R/agent.R:127）：
#   finish_reason 不能是 length、围栏要**闭合**、语言要在 R/Python/Bash 里、
#   而且不能命中扫描规则（`print("hello")` 哪一条都不沾）。
_CODE_REPLY = '这段先跑一下：\n\n```python\nprint("hello")\n```\n'


def loop_state(page):
    """侧栏那枚「第 N/M 轮」徽章还在不在 —— **循环跑没跑起来的直接观测**。

    ⚠️ 不能数 `.badge` 之类宽选择器：`#chat-ctrl_notes` 的另一支（没在跑
      那一支）里也有别的节点，数出来的数不代表循环状态。这里匹配那句
      **独有**的文案 `sprintf("第 %d/%d 轮", ...)`（R/mod_chat.R:1866）。

    ⚠️ `innerText` 用 `\\s*` 而不是直接比字符串：本仓量过 `span(a,b)` 的
      innerText 是 `"# 1"` 不是 `"#1"`（子节点之间会夹空格），
      "第 1/30 轮" 在不同浏览器/皮肤下也可能带空格。
    """
    return page.evaluate(r"""() => {
        var el = document.querySelector('#chat-ctrl_notes');
        if (!el) return {found: false, text: null, w: 0};
        var m = /第\s*[0-9]+\s*\/\s*[0-9]+\s*轮/.exec(el.innerText || '');
        var r = el.getBoundingClientRect();
        return {found: !!m, text: (el.innerText || '').slice(0, 160),
                w: Math.round(r.width)};
    }""")


def wait_loop_badge(page, want, timeout=25):
    """轮询到「第 N/M 轮」出现（want=True）或消失（want=False）。

    ★ 为什么间隔要短到 120ms：本地电脑那一支是**同步**走完的（写一条 tool
      消息 → 立刻发起下一次请求，R/agent.R:694-703），从"循环跑起来"到
      "撞上 400"只有一次 HTTP 往返。查一次是查不到的。
    """
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        last = loop_state(page)
        if last["found"] == want:
            return True, last, time.time() - t0
        page.wait_for_timeout(120)
    return False, last, time.time() - t0


def sel_value(page, sel):
    """读一个 <select> 的当前值。**不用 `input_value()`** —— 那个要过
    可操作性检查，而 selectize 把原生 select 藏成 0×0，会一路等到超时
    （报出来的是 "element is not visible"，指向"这个控件不存在"）。"""
    try:
        return page.eval_on_selector(sel, "e => e.value")
    except Exception:
        return None


def set_target_kind(page, value):
    """把「硬件选择」切成 value（这一节要 "local"）。

    ★ 切「本地电脑」**不是为了跑代码**，是为了让循环真的进到"生成中"：
      `try_submit()` 在 local 那一支**不经过引擎**，写完一条 tool 消息就
      `a$state <- "generating"` + `begin_llm()`。于是第二个请求是在循环
      活着的时候撞上 400 的 —— 那才是 V15.5 item 7 要停的那个场景。
      默认的 server 那一支要真的起一个任务才推得下去（引擎、conda、几十秒），
      那是另一个量级的探针，而且会把这一节变脆。

    ⚠️ 走真实的 selectize 下拉。取不到才退到直接发 Shiny 输入，并且打出来。
    """
    try:
        C.pick_select(page, "chat-target_kind", value)
        page.wait_for_timeout(700)
    except Exception as e:
        print("    ⚠️ 点「硬件选择」没成：%s" % str(e)[:200], flush=True)
    if sel_value(page, "#chat-target_kind") == value:
        return True
    page.evaluate("(v) => Shiny.setInputValue('chat-target_kind', v,"
                  " {priority: 'event'})", value)
    page.wait_for_timeout(700)
    if sel_value(page, "#chat-target_kind") == value:
        print("    ⚠️ 「硬件选择」是直接发 Shiny 输入切的（不是点出来的）",
              flush=True)
        return True
    return False


def arm_after_first_req(fx, req_before, timeout=20):
    """**看着第一条请求发出去**，然后才把 400 挂上。返回 (挂上了吗, 秒)。

    自动执行那一支专用：那一条的用户消息**必须**换回一个 200（回复里有可执行
    代码块），否则循环压根不进运行态，"循环停了"就是一句废话 —— 新旧代码都会
    过。这是本节最容易骗过自己的一条（见本节头注）。

    ⚠️⚠️ 而"第一条放行、第二条起全拒"这件事，假服务端的计数器**做不到**：
      `rejection()` 数的是**已经拒了几次**（tests/fake_llm.py:100
      `if read_int(REJ_STATE) >= times: return None`），预置成 n 得到的是
      "前 (times-n) 次被拒" —— 方向正好相反。第一轮探针就是
      `seed_rej_counter(fx, 1)` 配 times=10：第一条照样吃 400、循环压根没
      起来，而屏幕上看不出任何异常（那条 400 的通知长得很正常）。

    ★ 判据是请求**已经落盘**：fake_llm 先写 `req-XXXX.json`、**之后**才裁定
      要不要拒（tests/fake_llm.py:115-125）。所以这时候挂上的 400 一定砸在
      **下一条**请求上，也就是循环推着发出来的那条。
    ⚠️ 前提是第一条的响应还在**慢放**（调用方先 `fx.slow()`）：不慢放的话，
      从"第一条到齐"到"循环发出第二条"只有一次 HTTP 往返，这个轮询会输掉，
      而输掉的样子和上面那个坑**一模一样**（第一条也吃 400），排查要重来一遍。
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        if fx.req_n() > req_before:
            fx.arm_400(_CTX_400, times=10)
            return True, time.time() - t0
        time.sleep(0.05)
    return False, time.time() - t0


# ★★ 侧栏那枚「第 N/M 轮」徽章只在 `a$state != "idle"` 时存在
#    （R/agent.R:627 `a$active <- function() !identical(a$state, "idle")`），
#    而**用户自己那一轮里 state 一直是 idle** —— 它第一次出现是在第一条回复
#    落地、循环接手的那一刻，消失是在第二个请求撞上 400 的那一刻，中间只有
#    一次 HTTP 往返（本地回环）。120ms 轮询去抓它，抓不到的样子和"循环压根
#    没跑"一模一样，而这一节的结论全建在"循环跑过"上。
#    装个 MutationObserver 之后这件事变成**事件驱动**的，一次也不会漏。
# ⚠️ 观察 document.body 的子树，不是盯 `#chat-ctrl_notes` 自己：Shiny 的
#    renderUI 会把那个容器**整个换掉**，盯在旧节点上的观察者跟着一起死。
_LOOP_WATCH_JS = r"""() => {
    if (window.__loopWatch) return window.__loopWatch;
    window.__loopWatch = {seen: false, text: null, n: 0};
    var re = /第\s*[0-9]+\s*\/\s*[0-9]+\s*轮/;
    var scan = function () {
        var els = document.querySelectorAll('.dsapp-ctrl-notes');
        for (var i = 0; i < els.length; i++) {
            var t = els[i].innerText || '';
            if (re.test(t)) {
                window.__loopWatch.seen = true;
                window.__loopWatch.text = t.slice(0, 120);
                window.__loopWatch.n += 1;
            }
        }
    };
    new MutationObserver(scan).observe(document.body,
        {childList: true, subtree: true, characterData: true});
    scan();
    return window.__loopWatch;
}"""


def install_loop_watch(page):
    """装上观察者（在点发送**之前**装）。"""
    try:
        return page.evaluate(_LOOP_WATCH_JS)
    except Exception as e:
        print("    ⚠️ 装循环观察者没成：%s" % str(e)[:200], flush=True)
        return None


def loop_watch(page):
    try:
        return page.evaluate("() => window.__loopWatch || null")
    except Exception:
        return None


def loop_fired(db, uid, since_id):
    """循环**确实推过一轮**的耐久证据 —— 库里那条 tool 消息。返回 (bool, 说明)。

    ★ 判据是 R/agent.R:723-731 那一支写的内容（「执行结果 · 未执行」＋
      「本地电脑」）。它只在 `a$try_submit()` 里写，而 `try_submit()` 只有
      **循环接手之后**才会被调到（用户自己那一轮里 state 是 idle，走不到
      那儿；函数名也说明了这一点）。
    ★ 为什么要它：徽章那次观测窗口只有一次 HTTP 往返，漏了是常态；这一条是
      **落在库里的**，等 30 秒也还在。有了它，"循环跑过"这件事就不再依赖
      采样运气 —— 上面那个徽章断言红了只说明观测量不到，不代表功能坏了。
    """
    rows = sql(db, "SELECT m.id, m.content FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? AND m.role = 'tool' AND m.id > ?"
                   " ORDER BY m.id", (uid, since_id))
    hit = [r for r in rows if "未执行" in (r[1] or "")]
    return bool(hit), ("点了发送之后新增 tool 消息 %d 条，其中含「未执行」%d 条"
                       % (len(rows), len(hit)))


def item7_ctx_error(page, uid, db, fx, agent=False):
    tag = "自动执行模式" if agent else "手动模式"
    print("\n== C. item 7（%s）：超上下文当场反馈 + 落库 + 循环停 ==" % tag,
          flush=True)

    C.goto(page, "chat")
    if agent:
        ok = enable_agent_mode(page)
        chk("★ 前提：自动执行开关真的勾上了", ok, "没勾上则这一节测的还是手动模式")
        if not ok:
            return
        ok2 = set_target_kind(page, "local")
        chk("★ 前提：执行目标切成了「本地电脑」（这样循环不经过引擎就能推进）",
            ok2, "#chat-target_kind = %r" % sel_value(page, "#chat-target_kind"))
        if not ok2:
            return
    else:
        ensure_no_modal(page)

    # ★ 400 要**每一次**请求都回：这样"循环没有偷偷重试"才是真的被判过，
    #   而不是靠"第二次侥幸成功"。times 给 10 —— 够盖住任何重试，也不至于
    #   让一个失控的循环无限跑下去（下面有超时）。
    #
    # ⚠️ 先把上一节留下的通知摘干净（这一节跑两遍，那条通知是永久的）。
    #    不清的话这一节的"当场弹出"会量到上一节那条 —— 见 clear_notifications。
    n_old_note = clear_notifications(page)
    print("    清掉屏幕上残留的通知 %d 条" % n_old_note, flush=True)

    # ⚠️⚠️ 自动执行那一支的**第 1 个请求必须放行**：循环是被模型的回复推动的
    #    （on_llm_done → 挑代码块 → try_submit），第一个请求就 400 的话循环
    #    压根没进过 "generating" —— 那时候再断言"循环停了"是一句废话，
    #    新旧代码都会过（**这正是最容易骗过自己的一条**）。
    #    所以队列里的这条回复带着一个可执行代码块（`_CODE_REPLY`）。
    fx.set_queue(C.sse_multi(["用户想跑点东西，先给他一段能跑的。"],
                             _CODE_REPLY))
    if agent:
        # 400 **不在**这里挂：先慢放，等第一条真的发出去了再挂 —— 理由和
        # "为什么不能预置计数器"都写在 arm_after_first_req() 里。
        fx.disarm_400()
        fx.slow(1.0)
    else:
        fx.arm_400(_CTX_400, times=10)

    n_user0 = user_msg_n(db, uid)
    mid0, _c0 = last_assistant(db, uid)
    req0 = fx.req_n()
    print("    点发送之前：用户消息 %d 条、最新 assistant id=%s、"
          "假 LLM 收到 %d 个请求" % (n_user0, mid0, req0), flush=True)

    # ★ 装上循环观察者（必须在点发送之前：徽章第一次出现紧跟着第一条回复）
    if agent:
        install_loop_watch(page)

    # ---- 点发送。**从这里开始一条新消息都不许发** -------------------------
    page.fill("#chat-input", "这一条会撞上上下文窗口。")
    page.click("#chat-send")
    click_t = time.time()

    if agent:
        armed, dt_arm = arm_after_first_req(fx, req0)
        print("    第一条放行之后才挂上 400：%s（%.1f 秒；假 LLM 累计 %d 个请求）"
              % (armed, dt_arm, fx.req_n()), flush=True)
        chk("★★ 前提：第一条请求**真的到了假服务端**（400 挂在它**之后**）"
            " —— 没这一条，下面那个 400 会砸在第一条上，循环根本起不来",
            armed, "等了 20 秒 req_n 还是 %d" % fx.req_n())

    # ★★ 自动执行那一支的**反假绿前提**：先确认循环真的推进过。
    #    第 1 个请求 200（回复里有代码块）→ on_llm_done 挑中它 →
    #    try_submit() 走 local 那一支 → 写 tool 消息 + 立刻发第 2 个请求。
    #    没有这一步，"循环停了"会因为**它从来没起来过**而白送。
    #
    #    判据两样，分开报（别混成一句）：
    #      ① 库里的 tool 消息 —— **耐久证据**，循环接手才会被写；
    #      ② 侧栏徽章被观察者看见过 —— 直接观测，但窗口只有一次 HTTP 往返。
    if agent:
        t_pre = time.time()
        lw, fired, how = None, False, ""
        while time.time() - t_pre < 30:
            lw = loop_watch(page) or {}
            fired, how = loop_fired(db, uid, mid0)
            if lw.get("seen") and fired:
                break
            page.wait_for_timeout(120)
        lw = loop_watch(page) or {}
        print("    侧栏徽章（事件驱动观察）：seen=%s，命中 %s 次，最后一次 %r"
              % (lw.get("seen"), lw.get("n"), (lw.get("text") or "")[:80]),
              flush=True)
        print("    库里循环痕迹：%s（%.1f 秒）" % (how, time.time() - t_pre),
              flush=True)
        chk("★★ [自动执行] 前提：循环**真的推进过一轮**（库里多了一条"
            "「执行结果 · 未执行」的 tool 消息 —— 它只有循环接手之后才会"
            "被写）—— 不然下面那条是白送的", fired, how)
        chk("★ [自动执行] 顺带观测：侧栏「第 N/M 轮」徽章**被看见过**"
            "（窗口只有一次 HTTP 往返，这一条红了只说明观测量不到，"
            "功能坏没坏看上面那条）", bool(lw.get("seen")), lw)

    note, dt = wait_notification(page, _NOTE_NEEDLE, timeout=90)
    print("    通知：%r（%.1f 秒）" % ((note or "")[:160], dt), flush=True)

    # ⚠️ 这三条**同时**成立才算"当场"：通知出来了、没再发消息、界面回空闲。
    chk("★★★ [%s] 点完发送**不用再发一条消息**，错误通知就自己弹出来了"
        % tag, note is not None,
        "等了 90 秒没有；屏幕上的通知：%s" % notifications(page))
    chk("★★ [%s] 而且是**立刻**（30 秒内），不是等下一轮才说" % tag,
        note is not None and dt < 30, "%.1f 秒" % dt)

    # ★★ 这里量的是**"只多了我点发送的那一条"**，不是"一条都没多"。
    #
    #    ⚠️ 我第一版写的是 `== n_user0`，那是错的：发送是**先落库、再出网**
    #       （R/mod_chat.R:1273，在所有闸门之后、`dsapp_llm_start()` 之前），
    #       400 拦的是出网那一步，用户那句话照样进对话。所以正确的期望是
    #       **恰好 +1**。写成"一条都没多"会红在一个和被测代码无关的地方，
    #       而且看着特别像"这条消息没存上"，实际是我数错了。
    #
    #    ★ 那这条还测得到"不是'再发一条才知道'"吗？测得到 —— 靠的是
    #      `wait_notification()` **返回的那一刻**就回库数一次（下面这一行），
    #      而不是等到最后一起数。那一刻若用户被要求再发一条才被告知，
    #      界面上不会有这条通知（旧代码里 res$error 只写进 rv$error，
    #      刷新就没、也不落库），通知这一条就过不去。
    n_user1 = user_msg_n(db, uid)
    chk("★★ [%s] 出错这一轮里只多了我点发送的那**一条**用户消息"
        "（没有为了让错误冒出来而自动补发/重发）" % tag,
        n_user1 == n_user0 + 1,
        "点之前 %d 条、通知到的这一刻 %d 条（期望 %d）"
        % (n_user0, n_user1, n_user0 + 1))

    # ---- 回库：当场多出一条说明 -------------------------------------------
    #
    # ★ 界面上的通知 `duration = NULL` 是**不落库的**，刷新就没了。用户说的
    #   「立即给出反馈」要真的顶用，必须有一条能刷新之后还在的东西 ——
    #   代码里是合成一条 assistant 消息落库（R/mod_chat.R:5160）。
    #   所以这里**回库确认**（本仓铁律：写操作只看界面分不清"没写进去"
    #   和"没画出来"）。
    mid1, body = last_assistant(db, uid)
    if not (body and all(x in body for x in _DB_NEEDLES)):
        end = time.time() + 30
        while time.time() < end:
            mid1, body = last_assistant(db, uid)
            if body and all(x in body for x in _DB_NEEDLES):
                break
            page.wait_for_timeout(500)
    print("    库里最新 assistant id=%s，正文 %d 字：%r"
          % (mid1, len(body), body[:120]), flush=True)
    chk("★★★ [%s] 库里当场多出一条 assistant 说明，正文含「没能发出去」"
        "和「上下文」（刷新之后也还在）" % tag,
        all(x in body for x in _DB_NEEDLES),
        "最新 assistant 正文 %r" % body[:300])
    chk("★★ [%s] 而且那条是**新的**（不是把上一轮的回答又数了一遍）" % tag,
        mid1 is not None and mid0 is not None and mid1 > mid0,
        "之前最新 id=%s，之后 %s" % (mid0, mid1))

    # ---- 界面回到不忙 -------------------------------------------------------
    #
    # ★ 轮询到"真的不忙"，但**立刻返回**（不忙的时候不该白等）：
    #   `wait_idle()` 反过来先花 20 秒等它**忙**起来 —— 那是给"刚点完发送"
    #   用的，这里已经确定结束了，用它只会白烧 20 秒。
    def _not_busy(s):
        return (s["send_disabled"] is False and s["cursor"] is False
                and s["wait_box"] is False)

    end = time.time() + 30
    sig = busy_signals(page)
    while time.time() < end and not _not_busy(sig):
        page.wait_for_timeout(300)
        sig = busy_signals(page)
    print("    忙闲信号：%s" % sig, flush=True)
    chk("★★★ [%s] 界面回到了不忙（#chat-send 不再 disabled、没有 "
        ".dsapp-cursor / .dsapp-wait）—— 不是卡在生成中" % tag,
        _not_busy(sig), sig)

    # ---- 循环停没停 ---------------------------------------------------------
    #
    # ★★★ 这一节的**要害**只有自动执行那一支有。判据是三个一起看，
    #   最重要的一条是**屏幕上那枚徽章**：
    #
    #   · `#chat-ctrl_notes` 里那句「第 N/M 轮」**已经没了** ——
    #     它是 `a$state != "idle"` 的唯一可见证据（R/mod_chat.R:1856）。
    #     旧代码那一支（`is.null(res$error)` 只做到"不把结果喂回去"）里，
    #     循环会**停在 generating 上等一个永远不会来的 on_llm_done** ——
    #     `active()` 一直是 TRUE，这句「第 1/30 轮」就**一直挂在屏幕上**，
    #     用户看到的是"AI 一直在生成"，而它其实早就死了。
    #     ⚠️ 这一条之所以有判别力，靠的是上面那条"循环真的进过运行状态"的
    #        前提断言 —— 没有它，从没起来过的循环也能让这条变绿。
    #   · 假 LLM **一个请求都没再收到**：循环要是还在跑，它迟早会再来一次，
    #     而 400 是**每次都回**的（times=10），`req_n()` 会一直涨。
    #   · 界面在这 15 秒里**一次都没忙过** —— 挡住"停了又自己起来"。
    stopped, st_gone, dt_gone = (True, None, 0.0)
    if agent:
        stopped, st_gone, dt_gone = wait_loop_badge(page, want=False, timeout=20)
        print("    循环徽章已消失：%s（%.1f 秒）%r"
              % (stopped, dt_gone, (st_gone or {}).get("text")), flush=True)

    seen_busy, r0 = False, fx.req_n()
    t0 = time.time()
    while time.time() - t0 < 15:
        s = busy_signals(page)
        if s["send_disabled"] or s["cursor"] or s["wait_box"]:
            seen_busy = True
        page.wait_for_timeout(500)
    r1, s1 = fx.req_n(), busy_signals(page)
    print("    静置 %.0f 秒：假 LLM 请求 %d → %d；期间忙过=%s；收尾 %s"
          % (time.time() - t0, r0, r1, seen_busy, s1), flush=True)

    if agent:
        chk("★★★ [%s] 循环**停了**：侧栏那句「第 N/M 轮」不见了"
            "（旧代码里它会一直挂在那儿 = 用户看到'AI 一直在生成'）" % tag,
            stopped, "收尾时 #chat-ctrl_notes = %r" % ((st_gone or {}).get("text"),))
        chk("★★★ [%s] 而且静置 15 秒不再有新的出网请求"
            "（不是一直在重试同一堵墙）" % tag, r1 == r0,
            "请求 %d → %d" % (r0, r1))
        chk("★★★ [%s] 这 15 秒里界面也**一次都没再忙过**" % tag,
            not seen_busy and _not_busy(s1), "期间忙过=%s；收尾 %s"
            % (seen_busy, s1))
    else:
        # 手动模式也把"没有偷偷重试"记一笔，只是不作为 item 7 的判据。
        chk("★ [%s] 手动模式下也没有偷偷重试（静置 15 秒请求数不变）" % tag,
            r1 == r0, "请求 %d → %d" % (r0, r1))

    fx.disarm_400()
    # ⚠️ 自动执行那一支挂了 slow.json（arm_after_first_req 的前提），收尾
    #    一定要摘掉：这一节是最后一节，但**探针会被单节重跑**，留着的话
    #    下一次跑别的节时所有 200 都变成慢放，超时会红在一堆无关的地方。
    fx.no_slow()
    print("    这一节耗时 %.1f 秒" % (time.time() - click_t), flush=True)


# =============================================================================
# E. item 12（V15.5）：图里的方框会被平台抓到，并摆到模型眼前
# =============================================================================
#
# 用户原话：「这个图片里生成的文字是有问题的，想一个新的提示词并应用以杜绝
# 这个问题」。截图是一张横向条形图 —— **每一个中文标签都是一个空心方框**，
# 英文和数字却是好的（所以粗看还挺正常）。根因不在"模型忘了设字体"，而在
# 我们自己的技能文档里写死了一份不含中文字形的清单
# （skills_builtin/nature-skills.md 第 77 行：Arial / Helvetica / DejaVu
# Sans —— 这三款在 Linux 上都没有 CJK 字形，而 matplotlib 不做逐字回退）。
#
# 提示词那一半（R/prompts.R 的「代码铁律 规则 11」+【运行环境】里新增的
# 「中文字体」一节）验的是"模型听不听话"，那件事没法用探针判；这一节验的是
# **闸门那一半**：不管代码是谁写的（模型写的、用户自己贴的），只要图画出了
# 方框，平台自己就该抓到，并把结论摆到模型眼前。
#
# 做法：让平台真的跑一段**不设中文字体**的 matplotlib 代码，然后查三件事：
#   ① 执行结果里出现「产出有问题」这一节（R/agent.R:307 的 art_bad）；
#   ② 那一节里说得出"字没画出来"（`missing from current font` / 「方框」）；
#   ③ **反面对照**：同一张图，这次设好中文字体再画一遍，这一节**不许**出现。
#
# ⚠️ ③ 不能省。只验"出现了"的话，"这一节永远都在"（比如体检把每张 PNG 都
#    报一遍）也会让 ①② 变绿 —— 而"永远都在"比漏报更难发现，它看起来像是
#    "功能好得很"。
#
# ⚠️ "执行结果"以**库里的 tool 消息**为正本，不是界面上的卡片：模型下一轮
#    读到的就是那条消息（R/agent.R 的 dsapp_agent_tool_text 拼、
#    db_message_add 落库），界面卡片只是它的一种渲染（R/render.R 的
#    dsapp_run_card）。两处都可能各自坏掉，所以两条都查 —— 而且这两条是
#    **三次独立的红**：执行器有没有认出来 / 回喂链路有没有把它带上 /
#    渲染层分不分得出这一节（第三者见 tool_section() 的注释，是个老坑）。
#
# ---- 触发方式：假 LLM 吐代码块 → 点助手气泡里的「执行」 ---------------------
#
# ★ "跑一段 python 并拿到执行结果"这条路在 tests/ui_v154/probe_v154.py 里
#   **有现成的**（`item2_artifacts()`，599-673 行），这里照抄它的形状：
#     fx.set_queue(C.sse("...```python ... ```...")) → send() →
#     page.locator(".dsapp-code-run").last.click() → _dismiss_confirm() →
#     等结果。v154 等的是界面上的产物卡片，这里等的是库里新的 tool 消息。
#
# ⚠️ 执行目标必须是「当前服务器」（这一节的默认值）。切成「本地电脑」的话
#    dsapp_chat_run() 走的是 dsapp_chat_export()（R/mod_chat.R:1116-1119）
#    —— 它**只导出脚本、不执行**，这一节会以"等不到执行结果"的样子全红，
#    而红的原因和 item 12 一点关系都没有。所以下面第一条就是目标断言。

# 故意**不设** font.sans-serif：默认的 DejaVu Sans 没有中文字形，savefig
# 时 matplotlib 会往 stderr 打一串
#   `...: UserWarning: Glyph 25968 (...6570...) missing from ...font...`
# 那行字就是平台要抓的判据（R/executor.R 的 dsapp_font_glyph_check）。
_TOFU_CODE = """\
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

fig, ax = plt.subplots(figsize=(5, 2))
ax.barh(["中文标签", "第二个类目"], [3, 5])
ax.set_xlabel("数量")
fig.tight_layout()
fig.savefig("tofu.png", dpi=100)
print("saved tofu.png")
"""

# 反面对照：同一张图，这次按 R/prompts.R「中文字体」那一节的写法把字体按
# **文件**加载进来（addfont 绕开字体索引，名字也现取 —— 不写死"WenQuanYi
# Micro Hei"，免得字体文件的家族名和文件名不一致时静默失效）。
_OK_CODE_TPL = """\
import matplotlib
matplotlib.use("Agg")
from matplotlib import font_manager as fm
import matplotlib.pyplot as plt

FONT = {font!r}
fm.fontManager.addfont(FONT)
plt.rcParams["font.sans-serif"] = [fm.FontProperties(fname=FONT).get_name()]
plt.rcParams["axes.unicode_minus"] = False

fig, ax = plt.subplots(figsize=(5, 2))
ax.barh(["中文标签", "第二个类目"], [3, 5])
ax.set_xlabel("数量")
fig.tight_layout()
fig.savefig("ok.png", dpi=100)
print("saved ok.png")
"""

_TOFU_REPLY = ("画一张中文的横向条形图：\n\n```python\n" + _TOFU_CODE + "```\n")

# ★★ 对照那一段也要**带围栏**：`run_block_and_wait()` 是把这段文字当成助手
#    回复直接塞进队列的（`fx.set_queue(C.sse(reply))`），而「执行」按钮要
#    `pending_code()` 从**围栏**里解析出可执行块（R/mod_chat.R:2291）。少了
#    围栏，这条回复就是一段纯文本的 python —— 界面上没有按钮、库里也没有
#    可执行块，报出来却是"助手气泡里没有出现新的「执行」按钮"（看着像平台
#    坏了）。第一轮探针就是这么红的：库里那条消息（id=23）是**光秃秃的
#    python 源码**。`_TOFU_REPLY` 一直是带围栏的，这个模板漏了。
_OK_REPLY_TPL = ("再画一张，这次字体设好：\n\n```python\n"
                 + _OK_CODE_TPL + "```\n")


def _dismiss_confirm(page):
    """代码块触发「确认执行」弹窗时把它点掉（照 tests/ui_v154/probe_v154.py
    585 行那份抄）。

    探针跑的都是自己写的安全代码，但平台扫出来的 warning 未必为 0
    （scanner 判"要用户确认"就会挡一下），挡着的话点执行等于没点 ——
    而症状是"等不到执行结果"，看着像被测代码没工作。
    """
    for _ in range(12):
        if page.locator("#shiny-modal:visible").count() == 0:
            return
        b = page.locator("#chat-do_run")
        if b.count():
            b.first.click()
            page.wait_for_timeout(800)
            return
        page.wait_for_timeout(300)


def newest_sid(db, uid):
    """这个账号最新一条消息所属的会话 id（= 工作区目录名里的那一段）。"""
    rows = sql(db, "SELECT m.session_id FROM messages m"
                   " JOIN sessions s ON s.id = m.session_id"
                   " WHERE s.user_id = ? ORDER BY m.rowid DESC LIMIT 1", (uid,))
    return None if not rows else rows[0][0]


def ws_dir(sid):
    """这次对话的工作区在磁盘上的位置（找不到返回 None）。

    ⚠️ 不写死 `<DATA_ROOT>/workspaces/chat-<sid>`：ws_root 可以被
      DSAPP_WS_ROOT 改掉（R/config.R:772），写死了哪天改了就是"文件明明
      在、这条却说不在"。按名字在数据目录下找一层最稳 —— 名字的算法照抄
      R/utils.R 的 dsapp_ws_name()（非 [A-Za-z0-9._-] 一律换成 `_`）。

    ⚠️ 深度剪枝：工作区里有 .venv（上万个文件），不剪的话光这一步就能
      走几十秒。
    """
    if not sid:
        return None
    want = "chat-" + re.sub(r"[^A-Za-z0-9._-]", "_", sid)
    base_depth = C.DATA_ROOT.count(os.sep)
    for root, dirs, _files in os.walk(C.DATA_ROOT):
        if os.path.basename(root) == want:
            return root
        if root.count(os.sep) - base_depth >= 3:
            dirs[:] = []
    return None


def pick_cjk_font():
    """本机上含中文字形的字体文件（反面对照要用它）。

    ⚠️ 顺序和理由见 R/prompts.R 的 dsapp_cjk_fonts()：**不能只看 $HOME**
      （线上跑在 shiny 用户下，而文泉驿装在 /home/biomamba/.fonts），
      也不能随便挑一个 .ttf —— 这台机器上 Droid Sans Fallback **没有
      ASCII 和数字**，拿它当主字体是"中文好了、数字全变方框"。
      所以先认那个已知可用的（文泉驿微米黑），扫盘时也只认名字里带
      CJK/Hei/Song/Kai/Noto…SC 这些的。

    找不到返回 None —— 那条路上这一节会**说清楚"对照做不了"**，不许假装
    通过（没有对照的"没出现"是假绿）。
    """
    known = "/home/biomamba/.fonts/wqy-microhei/wqy-microhei.ttc"
    if os.path.exists(known):
        return known
    import fnmatch
    pats = ["*wqy*", "*WenQuanYi*", "*hei*", "*Hei*", "*song*", "*Song*",
            "*kai*", "*Kai*", "*cjk*", "*CJK*", "*NotoSansSC*",
            "*Noto*Sans*SC*", "*SourceHan*", "*DroidSansFallback*"]
    for d in ("/home/biomamba/.fonts", "/root/.fonts",
              "/usr/share/fonts", "/usr/local/share/fonts"):
        if not os.path.isdir(d):
            continue
        for root, dirs, files in os.walk(d):
            for f in files:
                if not f.lower().endswith((".ttc", ".ttf", ".otf")):
                    continue
                if any(fnmatch.fnmatch(f, p) for p in pats):
                    return os.path.join(root, f)
    return None


def tool_section(txt, prefix="产出有问题"):
    """从 tool 消息正文里取一个小节（`--- 标签 ---` 之间的那几行）。

    ⚠️ 判据必须**限定在这一节里**：同一条正文里还有 stderr 那一节，它也可能
      含 `missing from current font`（警告没被摘掉的时候）—— 拿整条消息去
      grep，会在"这一节根本没出现"的时候绿。这正是本仓"正则匹配源码会静默
      走样"那条教训的同类：范围错了，结论就错了，而且不报错。

    ⚠️⚠️ 这里的切法**故意和 R/render.R 的 dsapp_tool_sections() 不一样**。
      那个函数认的分隔行是 `^--- .+ ---$` —— 收尾那三个减号**前面要有空格**。
      而 agent.R 拼出来的小节标签是

          --- 本次产出的文件（人类可读，可以直接交给用户）---
          --- 产出有问题（平台体检，下面这些**不能当作结果交出去**）---
          --- 平台提示（已自动放行）---

      收尾是 `）---`，**没有空格**，所以 R 那边一个都认不出来。实测（拿线上
      一条真消息，messages.id=364，跑真实的 dsapp_tool_sections()）：解析
      出来只有一个小节 `stdout（末尾）`，产物清单和「产出有问题」整段都被
      并进了它里面 —— 也就是说 `dsapp_sec_get(secs, "产出有问题")` 恒为
      NULL，卡片上那块 `.dsapp-run-badart` **永远不渲染**。那是 R 侧的 bug
      （另一个坑，报告里单独写），不是正文的形态问题。

      这一节要判的是"模型有没有看到这段话"，所以这里按**正文本来的形态**切：
      一行以 `--- ` 开头、以 `---` 结尾就算分隔行。
    """
    cur, buf = None, []
    for ln in (txt or "").split("\n"):
        if len(ln) > 6 and ln.startswith("--- ") and ln.endswith("---"):
            if cur is not None:
                break                     # 下一节开始，收工
            if ln[4:].rstrip("-").strip().startswith(prefix):
                cur = ln[4:]
            continue
        if cur is not None:
            buf.append(ln)
    return None if cur is None else "\n".join(buf)


def task_of(db, uid, txt):
    """从 tool 消息正文里认出它说的是哪个任务，再把那一行读出来。

    ⚠️ 先认正文头一行的 `任务 #N`（dsapp_agent_tool_text 拼上去的），认不出
      来才退回"这个账号最新的那一行"。退回是**兜底**不是等价物：同时跑着
      别的任务时，"最新那一行"完全可能是另一条 —— 那时候断言的就不是这条
      消息说的事了。
    """
    m = re.search(r"任务\s*#\s*(\d+)", txt or "")
    if m:
        rows = sql(db, "SELECT id, status, exit_code, stderr FROM tasks"
                       " WHERE id = ?", (int(m.group(1)),))
        if rows:
            return rows[0]
    rows = sql(db, "SELECT t.id, t.status, t.exit_code, t.stderr FROM tasks t"
                   " JOIN sessions s ON s.id = t.session_id"
                   " WHERE s.user_id = ? ORDER BY t.rowid DESC LIMIT 1", (uid,))
    return rows[0] if rows else None


def run_block_and_wait(page, db, uid, fx, reply, say, max_wait=180):
    """假 LLM 吐一段带代码块的回复 → 点「执行」→ 等结果写回**库里**。

    返回 dict(rid, text, sid, secs, n_btn)：rid 是那条 tool 消息的 rowid，
    等不到就是 None。

    ★ 这条路就是 tests/ui_v154/probe_v154.py 的 `item2_artifacts()`（599-673
      行），只把"等界面上的产物卡片自己刷出来"换成"等库里出现新的 tool
      消息"。两点照抄的原因：
        · 点的是 `.dsapp-code-run`，**不是** composer 里那颗发送键；
        · 点完要 `_dismiss_confirm()` —— 平台可能先弹一个「确认执行」。

    ⚠️ 轮询而不是查一次：本仓 fake-wait-is-not-a-wait 那条 —— 任务要起进程、
      要先建对话的 python venv（第一次跑 python 的对话尤其慢），
      30 秒起步是常态。这里等到 tool 消息**落库**为止（最多 180 秒）。

    ⚠️ 用 `rowid > before` 而不是"最新一条 tool 消息"：后者在上一节刚写过
      一条的时候会把**上一条**当成本次的结果 —— 那种错法看着像"结果出来了"，
      实际量的是别人。before 取的是**全表**的最大 rowid（不限用户）。
    """
    before = sql(db, "SELECT COALESCE(MAX(rowid), 0) FROM messages")[0][0]
    n_before = page.locator(".dsapp-code-run").count()

    fx.set_queue(C.sse(reply))
    send(page, say)

    # 等那颗「执行」按钮长出来（send() 回来时历史可能还没重画完）。
    end = time.time() + 30
    while page.locator(".dsapp-code-run").count() <= n_before and time.time() < end:
        page.wait_for_timeout(300)
    runs = page.locator(".dsapp-code-run")
    n_now = runs.count()
    if n_now <= n_before:
        print("    ⚠️ 助手气泡里没有出现新的「执行」按钮（现有 %d 颗）" % n_now,
              flush=True)
        return dict(rid=None, text="", sid=newest_sid(db, uid), secs=0.0,
                    n_btn=n_now)
    runs.last.click()
    _dismiss_confirm(page)

    t0 = time.time()
    while time.time() - t0 < max_wait:
        rows = sql(db, "SELECT m.rowid, m.content, m.session_id"
                       " FROM messages m JOIN sessions s ON s.id = m.session_id"
                       " WHERE s.user_id = ? AND m.role = 'tool' AND m.rowid > ?"
                       " ORDER BY m.rowid DESC LIMIT 1", (uid, before))
        if rows:
            return dict(rid=rows[0][0], text=rows[0][1] or "",
                        sid=rows[0][2], secs=time.time() - t0, n_btn=n_now)
        page.wait_for_timeout(1000)
    return dict(rid=None, text="", sid=newest_sid(db, uid),
                secs=time.time() - t0, n_btn=n_now)


def item12_tofu(page, uid, db, fx):
    print("\n== E. item 12：图里的方框会被平台抓到，并摆到模型眼前 ==",
          flush=True)

    C.goto(page, "chat")
    ensure_no_modal(page)

    # ---- 前提：执行目标必须是「当前服务器」 ---------------------------------
    if sel_value(page, "#chat-target_kind") != "server":
        set_target_kind(page, "server")
    kind = sel_value(page, "#chat-target_kind")
    chk("★ 前提：执行目标是「当前服务器」——「本地电脑」那一支只导出、不执行"
        "（那样这条会红在和 item 12 无关的地方）",
        kind == "server", "#chat-target_kind = %r" % kind)
    if kind != "server":
        return

    sid = newest_sid(db, uid)
    # ⚠️⚠️ 工作区**现在还没建**：目录是第一次执行的时候才建的，发消息不建
    #    （dsapp_ws_dir() 的 create 参数）。这一节开头就 walk 一遍必然扑空
    #    —— 第一轮探针就是这么红的（"连工作区都没定位到"），而它的图其实
    #    好好地躺在 <DATA_ROOT>/workspaces/chat-<sid>/ 里。
    #    所以：位置**等第一段跑完再定位**（下面那处）。
    print("    会话 %s（新账号新对话：工作区在这一节第一次执行之前不存在）"
          % sid, flush=True)

    # ---- ① 故意画一张"方框图" ----------------------------------------------
    r1 = run_block_and_wait(page, db, uid, fx, _TOFU_REPLY, "跑一下这个",
                            max_wait=180)
    print("    第一段（不设中文字体）：tool 消息 rowid=%s，%.0f 秒"
          % (r1["rid"], r1["secs"]), flush=True)
    chk("★★ 前提：这段 python 跑完了，执行结果写回了库里（不是只提交了任务）",
        r1["rid"] is not None,
        "等了 180 秒；助手气泡里的执行按钮 %d 颗" % r1["n_btn"])
    if r1["rid"] is None:
        return

    trow = task_of(db, uid, r1["text"])
    err = (trow[3] or "") if trow else ""
    if trow:
        print("    任务 #%s：status=%s exit=%s；stderr 前 300 字：\n%s"
              % (trow[0], trow[1], trow[2], err[:300]), flush=True)
    chk("★★ 前提：任务状态是 success（这段 python 真的跑完了，"
        "不是解释器/依赖挂了）",
        bool(trow) and str(trow[1]) == "success", trow)

    # ★ 这一条是"平台**手里有过**证据"的证明：缺字形的警告真的打进了
    #   stderr（执行器收下来的就是这个）。它红了 = 这段 python 在这台机器上
    #   根本没画出方框，下面所有结论都不成立（比如解释器换了、字体装上了）。
    warn_line = ""
    for ln in err.split("\n"):
        if "Glyph" in ln and "missing from" in ln:
            warn_line = ln.strip()
            break
    print("    解释器真实打出来的缺字形警告：%r" % warn_line[:200], flush=True)
    if warn_line:
        # 版本差异只打印、不断言（判据在平台那一侧，不在这条探针里）：
        # matplotlib ≤3.8 = "missing from current font"，≥3.9 = "from font(s) X"。
        print("      ↳ 这句的原文形态：%s"
              % ("`missing from current font`（≤3.8 那种写法）"
                 if "missing from current font" in warn_line
                 else "`missing from font(s) …`（≥3.9 那种写法）"), flush=True)
    chk("★★ 前提：stderr 里**真的**有缺字形警告（`Glyph … missing from …`）"
        " —— 这条红了说明这段 python 没画出方框，下面的结论不成立",
        bool(warn_line),
        "stderr 前 300 字：%r" % err[:300])

    # ---- 回工作区确认图真的落盘了（把"没跑出来"和"没报出来"分开）-----------
    # ★ 到这里第一段已经跑完，工作区目录**现在**才存在 —— 见上面那处注释。
    ws = ws_dir(sid)
    print("    工作区（第一段跑完才建出来的）：%s" % ws, flush=True)
    chk("★★ 前提：能定位到这次对话的工作区（下面的落盘确认要它）",
        ws is not None, "sid=%r；在 %s 下按 chat-<sid> 找" % (sid, C.DATA_ROOT))

    png = os.path.join(ws, "tofu.png") if ws else None
    if png:
        # ⚠️ 体积只在文件真在的时候量 —— 写成 `getsize(png) if landed else ...`
        #    也不行：extra 是**先求值再传进去**的，文件不在就抛 FileNotFoundError，
        #    而那个异常会把这一节的结论整个吃掉（看着像"探针没跑到"）。
        landed = os.path.exists(png)
        size = os.path.getsize(png) if landed else 0
        chk("★★ 回工作区确认：图真的产出来了（tofu.png 存在且非空，"
            "不是夹具塞的）",
            landed and size > 0,
            "%s：%s" % (png, ("%d 字节" % size) if landed else "不存在"))
    else:
        chk("★★ 回工作区确认：图真的产出来了（tofu.png 存在且非空，"
            "不是夹具塞的）", False, "连工作区都没定位到")

    # ---- ② 平台有没有把这件事摆到模型眼前 -----------------------------------
    sec = tool_section(r1["text"], "产出有问题")
    chk("★★★ 执行结果里出现了「产出有问题」这一节"
        "（平台自己的体检，不是提示词里的劝告）",
        sec is not None,
        "tool 消息 %d 字，头 160：%r" % (len(r1["text"]), r1["text"][:160]))
    body = sec or ""
    chk("★★★ 那一节里说得出**字没画出来**（`missing from current font` 或"
        "「方框」字样）—— 没有它，模型和用户都看不出图坏了",
        ("missing from current font" in body) or ("方框" in body),
        "那一节正文：%r" % body[:300])

    if sec is None:
        # ★ 红的时候要多说一句：把"平台没看见 / 看见了没认出来 / 认出来了
        #   没摆出来"三件事分开量。少这一句，报告里只能说"这一节没出现"。
        print("    ⚠️ 这一节没出现。正文里的三种痕迹："
              "\n      · tool 消息里出现过「方框/missing from」字样吗：%s"
              "\n      · stderr 那一节还在吗：%s（成功时警告会被摘掉，"
              "换成一句「N 条警告已被平台收走」：%s）"
              "\n      · stderr 里那句真警告是：%r"
              % (any(k in r1["text"] for k in ("方框", "missing from")),
                 tool_section(r1["text"], "stderr") is not None,
                 "已被平台收走" in r1["text"], warn_line[:200]), flush=True)

    # ---- 用户那一侧：卡片上一样看得见 ---------------------------------------
    # ⚠️ 按**任务号**认卡片，不按"最后一张"：跑任务期间页面上还有别的
    #    `.dsapp-run`（live 那张），按"最后一张"取可能取到它不是我们要的那张
    #    —— 而那种错法报出来是"卡片上没有这一节"，指向渲染，实际是选错了节点。
    #
    # ⚠️⚠️ 这一条和上面两条**可能各自红**，别混着读：
    #    · 上面两条红 = 平台没抓到 / 抓到了没摆到模型眼前（执行器 + 回喂链）；
    #    · 这一条单独红 = R/render.R 的 dsapp_tool_sections() 分不出这一节
    #      （它认的分隔行是 `^--- .+ ---$`，而这一节的收尾是 `）---`，
    #      前面没有空格 —— 见 tool_section() 的注释，附了线上真消息的实测）。
    #      那是个**一直都在**的坑：V13.12 item 8 的「空表」那一版同样
    #      渲染不出来。
    tid1 = trow[0] if trow else None
    card1 = (page.locator(".dsapp-run").filter(has_text="任务 #%s" % tid1)
             if tid1 is not None else page.locator(".dsapp-run"))
    n_bad, t0 = 0, time.time()
    while time.time() - t0 < 20:
        n_bad = card1.first.locator(".dsapp-run-badart").count()
        if n_bad:
            break
        page.wait_for_timeout(500)
    chk("★★ 而且用户那张执行卡片上也看得见这一节（`.dsapp-run-badart`）"
        " —— 同一条链路的另一半（渲染）",
        n_bad > 0,
        "任务 #%s 的卡片里没有；页面上 .dsapp-run %d 张"
        % (tid1, page.locator(".dsapp-run").count()))

    # ---- ③ 反面对照：同一张图，这次设好中文字体 -----------------------------
    font = pick_cjk_font()
    print("    反面对照要用的中文字体文件：%r" % font, flush=True)
    chk("★ 前提：本机找得到含中文字形的字体文件（找不到这条对照做不了，"
        "而「没出现」在没有对照时是假绿）",
        bool(font), "扫过 /home/biomamba/.fonts 等目录")
    if not font:
        return

    r2 = run_block_and_wait(page, db, uid, fx, _OK_REPLY_TPL.format(font=font),
                            "再画一张，这次字体设好", max_wait=180)
    print("    第二段（设好中文字体）：tool 消息 rowid=%s，%.0f 秒"
          % (r2["rid"], r2["secs"]), flush=True)
    chk("★★ 前提：对照这一版也真的跑完了（库里多了一条执行结果）",
        r2["rid"] is not None, "等了 180 秒")
    if r2["rid"] is None:
        return

    trow2 = task_of(db, uid, r2["text"])
    err2 = (trow2[3] or "") if trow2 else ""
    warn2 = [ln.strip() for ln in err2.split("\n")
             if "Glyph" in ln and "missing from" in ln]
    if trow2:
        print("    对照任务 #%s：status=%s exit=%s；stderr 前 200 字：\n%s"
              % (trow2[0], trow2[1], trow2[2], err2[:200]), flush=True)
    chk("★★ 前提：对照这一版**真的**没有缺字形警告（字体设对了）"
        " —— 这条红了，下面那条「没出现」就是假绿",
        not warn2, warn2[:2])

    if ws:
        ok_png = os.path.join(ws, "ok.png")
        print("    对照的图 ok.png：%s"
              % (("存在，%d 字节" % os.path.getsize(ok_png))
                 if os.path.exists(ok_png) else "不在"), flush=True)

    sec2 = tool_section(r2["text"], "产出有问题")
    print("    对照那条 tool 消息 %d 字；「产出有问题」这一节：%s"
          % (len(r2["text"]), "有" if sec2 is not None else "没有"), flush=True)
    chk("★★★ 反面对照：字体设对之后，这一节**不出现**"
        " —— 没有它，「那一节永远都在」也会让上面两条绿",
        sec2 is None,
        "对照的 tool 消息里还是有：%r" % (sec2 or "")[:300])

    tid2 = trow2[0] if trow2 else None
    page.wait_for_timeout(2500)
    card2 = (page.locator(".dsapp-run").filter(has_text="任务 #%s" % tid2)
             if tid2 is not None else None)
    n_bad2 = card2.first.locator(".dsapp-run-badart").count() if card2 else 0
    chk("★★ 对照那张卡片上也没有这一节（渲染这一侧同样不误报）",
        n_bad2 == 0,
        "任务 #%s 的卡片里有 %d 个 .dsapp-run-badart" % (tid2, n_bad2))

    print("    ⚠️ 这一节会在工作区里留下两张图：tofu.png（故意画坏的）和"
          " ok.png（对照）—— 都是跑出来的，不是夹具塞的。", flush=True)


# =============================================================================
# 主流程
# =============================================================================
#
# ⚠️⚠️ **顺序是有理由的，别换**：
#   · B 必须在 C 之前 —— C 会把厂商在 400 里说的窗口（65536）学进
#     model_param_limits，而 dsapp_ctx_limit() 是"学到过的优先"
#     （R/models.R:1104）。C 之后再量，deepseek 的量程会变成 "1K ~ 64K"，
#     B 必红，而那是这一节自己造成的。
#   · D 在 A 之后：A 只是读 `#chat-hint`，不影响生成时序；反过来 D 会把
#     上下文撑大，A 的"used 变大"就分不清是谁的功劳了。
#   · E 必须在 C 之前 —— C 的自动执行那一支会把执行目标切成「本地电脑」，
#     而那一支在 dsapp_chat_run() 里**只导出、不执行**（R/mod_chat.R:1116），
#     E 要等的是一个真的跑出来的执行结果，切过去之后就再也等不到了。
#     它对 A/D 没有要求：E 只是多跑两个任务、多写几条消息，A 的"used 变大"
#     量的是它自己那两条消息之间，D 的采样在 E 之前就结束了。
#   · C 放最后：它会往库里写"学到的窗口"，是这一轮里唯一有副作用的动作。
# =============================================================================

def main():
    fx = None
    try:
        # ★ 0. 先清库（在注册之前就能做 —— 它只要 db 路径，不要账号）。
        left = clear_learned_windows()
        print("\n== 0. 注册并把账号指向假服务端 ==", flush=True)
        if left:
            print("  清掉了上一轮学到的窗口：%s" % (left,), flush=True)

        with sync_playwright() as pw:
            browser = pw.chromium.launch()

            page = enter_with_retry(browser)
            email = C.LAST_EMAIL
            uid, db = C.seed_or_die(email)
            print("  uid=%s  db=%s" % (uid, db), flush=True)

            fx = C.FakeLLM()
            print("  假 LLM: %s" % fx.url, flush=True)
            C.seed_llm(uid, fx.url, model="fake-model")
            relogin(page, email)
            ensure_no_modal(page)

            item6b_range(page, uid, db)          # B（必须在 C 之前）
            item6a_ctxbar(page, uid, db, fx)     # A
            item8_spinner(page, uid, db, fx)     # D
            item12_tofu(page, uid, db, fx)       # E（必须在 C 之前）
            item7_ctx_error(page, uid, db, fx, agent=False)   # C（手动）
            item7_ctx_error(page, uid, db, fx, agent=True)    # C（自动执行）

            page.screenshot(path=C.OUT + "/99_final.png", full_page=True)
            browser.close()
    finally:
        if fx is not None:
            fx.stop()

    _chk.done()
    print("通过 %d / 失败 %d" % (N_OK[0], N_BAD[0]))
    if not B_VERIFIED[0]:
        print("\033[33m⚠️ B（量程按模型自适应）**没有验成** —— 见上面那一节，"
              "别把它当成通过。\033[0m")
    return 1 if N_BAD[0] else 0


if __name__ == "__main__":
    sys.exit(main())
