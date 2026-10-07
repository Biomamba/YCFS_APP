# -*- coding: utf-8 -*-
"""V13.4 item 7 —— 言出法随的环境下拉框要能看见内置环境。

用户原话：「言出法随的环境界面，并没有同步内置环境，选项里只有系统环境一个」。

这条**必须**在浏览器里验，理由有三条，每一条都能让"后台看着对"的实现在
界面上是坏的：

  1. 下拉框里那一组是 `selectInput(choices = list(...))` 出来的分组。
     R 那边构造对了，不代表它会真的渲染成一组（也可能被拍平成一堆平级
     选项，那样"内置环境"这四个字就丢了）—— 只有真看一眼 DOM 才知道。
  2. 选中内置模板走的是"**拦下来、弹框、把下拉拨回去**"，不是写 state。
     这个拦截写在**另加的一个** observeEvent 里，靠 `tpl:` 前缀和后面那道
     `dsapp_env_selectable()` 锁分工。写反了/顺序反了的症状是：用户点一下
     内置模板，弹出「界面上显示的名字被当成值回传了，这是平台的问题，请把
     这句话截图给管理员」—— 一条纯 UI 的错，R 层面看是"锁正常工作"。
  3. 「开始创建」之后那个下拉框**要自己更新**。它是渲染一次就冻住的
     （V11 把 5 秒轮询删了，见 mod_chat.R 里那段），现在靠 state$env_rev
     事件驱动。这条链路上任何一环断了，界面都表现为"什么都没发生"。

⚠️⚠️ 读 DOM 有一条硬规矩：**要看 selectize 的下拉，不要看原生 `<select>`。**
   selectize 初始化时会把原生 select 里的 option **删干净**，只留一个
   "当前选中项"用来提交表单。2026-09-16 我照着原生 select 写断言，量到的
   是「只有一个 option、没有分组」，看着像 R 那边没生成分组 —— 实际上
   下拉里两组三个选项一个不少，白查了半小时。原生 select 的 value 仍然
   可信（selectize 会 updateOriginalInput），所以"当前选中的是不是它"
   可以读原生，**结构**必须读下拉。

跑法见同目录 README.md。
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (URL, APP, OUT, guard, enter_app, seed_or_die, goto,
                     Chk)  # noqa: F401
from playwright.sync_api import sync_playwright

DATA_ROOT = guard(APP)

# 假 conda 建出来的环境名（见 README：DSAPP_CONDA_BIN 指到 /bin/bash，
# 由 app/ 下那个叫 create 的脚本干活）
SCRNA = "scRNA"
SPATIAL = "spatial"
TPL_SCRMA = "tpl:" + SCRNA
TPL_SPATIAL = "tpl:" + SPATIAL
TPL_LABEL = "内置环境（未创建）"
READY_LABEL = "可用"

# 下拉里各分组的结构： [{label, options:[{value,text}]}]
_DROP_JS = """
(id) => {
  const s = document.getElementById(id);
  if (!s) return null;
  const c = s.parentElement.querySelector('.selectize-control');
  const d = c && c.querySelector('.selectize-dropdown');
  if (!d) return null;
  return Array.from(d.querySelectorAll('.optgroup')).map(g => ({
    label: g.querySelector('.optgroup-header')
             ? g.querySelector('.optgroup-header').textContent : '',
    options: Array.from(g.querySelectorAll('.option')).map(o => ({
      value: o.getAttribute('data-value'), text: o.textContent
    }))
  }));
}
"""

# 不分组的那些选项（没有 .optgroup 包着）。用来验"都建好之后它应该和
# 以前一模一样"——那时候压根不该有分组。
_FLAT_JS = """
(id) => {
  const s = document.getElementById(id);
  if (!s) return null;
  const c = s.parentElement.querySelector('.selectize-control');
  const d = c && c.querySelector('.selectize-dropdown');
  if (!d) return null;
  return Array.from(d.querySelectorAll('.option')).map(o => ({
    value: o.getAttribute('data-value'), text: o.textContent
  }));
}
"""


def _ctrl(page, sel_id):
    return page.locator(
        "xpath=//select[@id='%s']/following-sibling::div"
        "[contains(@class,'selectize-control')]" % sel_id)


def _ensure_open(page, sel_id):
    """★ 读结构之前**必须**把下拉打开。

    ⚠️ selectize 的选项是**打开时才铺进 DOM** 的 —— 没打开过的下拉里
    `.option` 是空的（不是"内容旧"，是压根还没生成）。2026-09-16 第一版
    轮询就是栽在这上面：它每 5 秒读一次 `.option`，读到的永远是空的，
    于是报「构建中那一档没出现过」和「第二个环境没建起来」，而实际上
    它俩都建好了 —— 收尾时 open 一下再看，全都在。
    一个**只在被看见时才存在**的 DOM，不能用"轮询读取"的方式观察。

    ⚠️ 只在下拉**没开着**的时候点：selectize 的输入框是开关，已经开着的
    时候再点一下是**关掉**它，然后下面读到的又是空的。
    """
    c = _ctrl(page, sel_id)
    dd = c.locator(".selectize-dropdown")
    if dd.count() == 0 or not dd.first.is_visible():
        c.locator(".selectize-input").click()
        page.wait_for_timeout(600)


def groups(page, sel_id):
    _ensure_open(page, sel_id)
    return page.evaluate(_DROP_JS, sel_id)


def flat(page, sel_id):
    _ensure_open(page, sel_id)
    return page.evaluate(_FLAT_JS, sel_id) or []


def cur_value(page, sel_id):
    """当前选中值。读原生 select —— selectize 会把它同步成选中项。"""
    return page.evaluate("(id) => { const e = document.getElementById(id);"
                         " return e ? e.value : null; }", sel_id)


def shown(page, sel_id):
    """用户**看到**的那行字（selectize 的 item）。"""
    return page.evaluate("""(id) => {
      const s = document.getElementById(id);
      const c = s && s.parentElement.querySelector('.selectize-control');
      const i = c && c.querySelector('.selectize-input .item');
      return i ? i.textContent : '';
    }""", sel_id)


def open_drop(page, sel_id):
    _ensure_open(page, sel_id)


def click_option(page, sel_id, value):
    """像用户那样点下拉里的选项（含分组里的）。"""
    _ensure_open(page, sel_id)
    ctrl = _ctrl(page, sel_id)
    opt = ctrl.locator(".option[data-value='%s']" % value)
    if opt.count() == 0:
        opt = ctrl.locator(".option", has_text=value)
    opt.first.click()
    page.wait_for_timeout(900)


def option_values(gs):
    return {o["value"] for g in (gs or []) for o in g["options"]}


def main():
    errs = []
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        page = b.new_page(viewport={"width": 1600, "height": 1000})
        page.on("pageerror", lambda e: errs.append(str(e)))

        email = enter_app(page)
        seed_or_die(email)
        c = Chk()

        goto(page, "chat", 3500)
        page.wait_for_timeout(1500)

        sel_id = "chat-target_env"
        c("对话页有环境下拉框 #%s" % sel_id,
          page.locator("#" + sel_id).count() == 1)

        # ---- 1. 下拉里真的有「内置环境（未创建）」这一组 ----
        open_drop(page, sel_id)
        gs = groups(page, sel_id)
        labels = [g["label"] for g in gs or []]
        c("下拉里有分组（不是拍平的一堆选项）", len(gs or []) >= 1,
          "实际分组=%s" % labels)
        c("有「%s」这一组" % TPL_LABEL, TPL_LABEL in labels,
          "实际分组=%s" % labels)
        c("有「%s」这一组" % READY_LABEL, READY_LABEL in labels,
          "实际分组=%s" % labels)

        tpl = next((g for g in (gs or []) if g["label"] == TPL_LABEL), None)
        vals = option_values([tpl] if tpl else [])
        c("这一组里有 scRNA 和 spatial",
          {TPL_SCRMA, TPL_SPATIAL} <= vals, "实际=%s" % sorted(vals))
        c("标签是「单细胞（scRNA）」（中文名在前、环境名在后）",
          tpl is not None and any(
              o["text"].startswith("单细胞") and "scRNA" in o["text"]
              for o in tpl["options"]),
          "实际=%s" % (tpl or {}).get("options"))

        # ⚠️ 值必须是 tpl:<环境名>，不能是裸的 scRNA —— 裸的话它和"真环境"
        #    共用同一个字符串，而 dsapp_env_selectable() 是按磁盘状态判的，
        #    于是同一个值在"建好之前"和"建好之后"含义不同。这条断言就是钉住
        #    这个命名空间的。
        c("内置模板的值都带 tpl: 前缀",
          tpl is not None and all(
              o["value"].startswith("tpl:") for o in tpl["options"]),
          "实际=%s" % (tpl or {}).get("options"))
        c("没有裸的 scRNA / spatial 混在选项里",
          not ({SCRNA, SPATIAL} & {o["value"] for o in flat(page, sel_id)}),
          "实际=%s" % [o["value"] for o in flat(page, sel_id)])

        page.screenshot(path=OUT + "/70_dropdown_groups.png", full_page=False)
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)

        # ---- 2. 点一下内置模板：拨回去 + 弹确认框，且**不能**报那个"平台问题" ----
        before = cur_value(page, sel_id)
        c("点之前选中的是 系统环境", before == "system", "实际=%s" % before)

        click_option(page, sel_id, TPL_SCRMA)
        page.wait_for_timeout(1500)

        c("下拉框被拨回了原来的值（没停在内置模板上）",
          cur_value(page, sel_id) == "system",
          "实际 value=%s 显示=%r" % (cur_value(page, sel_id),
                                     shown(page, sel_id)))
        c("用户看到的那行字也退回去了（不是只有一个内部值回退）",
          "单细胞" not in shown(page, sel_id), "实际=%r" % shown(page, sel_id))

        modal = page.locator(".modal-dialog")
        c("弹出了确认框", modal.count() >= 1)
        mtxt = modal.first.inner_text() if modal.count() else ""
        c("标题说的是「单细胞」这个内置环境",
          "单细胞" in mtxt, "实际=%r" % mtxt[:150])
        c("正文报了要装多少个包（不是一句干巴巴的'要不要建'）",
          "个包" in mtxt, "实际=%r" % mtxt[:200])

        # ⚠️⚠️ 这一条是整段拦截逻辑的**要点**：那道 dsapp_env_selectable()
        #    锁的提示语是"这是平台的问题，请把这句话截图给管理员"。用户正常
        #    点一下内置模板**不该**看到它。拦截顺序写反了就只有这一条会红。
        c("没有误报「平台的问题，请截图给管理员」",
          "平台的问题" not in page.inner_text("body"), "")

        page.screenshot(path=OUT + "/71_confirm_modal.png", full_page=False)

        # ---- 3. 「先不建」：什么都不该发生 ----
        page.click(".modal-dialog button:has-text('先不建')")
        page.wait_for_timeout(1500)
        c("确认框关掉了", page.locator(".modal-dialog").count() == 0)
        c("还在系统环境上", cur_value(page, sel_id) == "system",
          "实际=%s" % cur_value(page, sel_id))

        envs_dir = os.path.join(DATA_ROOT, "envs")
        made = [d for d in (os.listdir(envs_dir) if os.path.isdir(envs_dir) else [])
                if not d.startswith(".")]
        c("「先不建」之后磁盘上没有新环境", SCRNA not in made, "实际=%s" % made)

        # ---- 4. 「开始创建」：通知 + 下拉框自己更新 ----
        click_option(page, sel_id, TPL_SCRMA)
        page.wait_for_timeout(1500)
        c("再点一次还是弹框（拦截没被消费掉）",
          page.locator(".modal-dialog").count() >= 1)
        page.click(".modal-dialog button:has-text('开始创建')")
        page.wait_for_timeout(2000)
        c("确认框关掉了", page.locator(".modal-dialog").count() == 0)

        # 假 conda 会先 mkdir 再睡 7 秒，所以这里能看到「构建中」那一档，
        # 然后它会自己变成可用 —— 这条链路就是 state$env_rev 在推。
        seen_building = False
        seen_ready = False
        t0 = time.time()
        while time.time() - t0 < 75:
            opts = {o["value"]: o["text"] for o in flat(page, sel_id)}
            if SCRNA in opts:
                if "构建中" in opts[SCRNA]:
                    seen_building = True
                else:
                    seen_ready = True
                    break
            page.wait_for_timeout(1000)

        c("建的过程中下拉里出现了 scRNA（构建中）", seen_building)
        c("建完之后那一行自己变成了可用（没有「构建中」后缀）", seen_ready)

        open_drop(page, sel_id)
        gs = groups(page, sel_id)
        tpl = next((g for g in (gs or []) if g["label"] == TPL_LABEL), None)
        vals = option_values([tpl] if tpl else [])
        c("建好的 scRNA 从「内置环境（未创建）」里挪走了",
          TPL_SCRMA not in vals, "实际=%s" % sorted(vals))
        c("「空转」还留在未创建那一组", TPL_SPATIAL in vals,
          "实际=%s" % sorted(vals))
        ready = next((g for g in (gs or []) if g["label"] == READY_LABEL), None)
        c("scRNA 出现在「可用」那一组里（不带后缀 = 真的可用）",
          ready is not None and any(
              o["value"] == SCRNA and "构建中" not in o["text"]
              for o in ready["options"]),
          "实际=%s" % (ready or {}).get("options"))

        page.screenshot(path=OUT + "/72_after_build.png", full_page=False)
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)

        # ---- 5. 选它真的能当环境用（写进 state，不是又弹框） ----
        click_option(page, sel_id, SCRNA)
        page.wait_for_timeout(1500)
        c("选建好的 scRNA 不再弹框", page.locator(".modal-dialog").count() == 0)
        c("下拉框停在 scRNA 上", cur_value(page, sel_id) == SCRNA,
          "实际=%s" % cur_value(page, sel_id))
        c("没有报「无法识别的环境选项」",
          "无法识别的环境选项" not in page.inner_text("body"), "")

        # ---- 6. 把第二个也建了：分组该消失，回到"和以前一模一样" ----
        click_option(page, sel_id, TPL_SPATIAL)
        page.wait_for_timeout(1500)
        if page.locator(".modal-dialog").count():
            page.click(".modal-dialog button:has-text('开始创建')")
        ok2 = False
        t0 = time.time()
        while time.time() - t0 < 75:
            if SPATIAL in {o["value"] for o in flat(page, sel_id)}:
                ok2 = True
                break
            page.wait_for_timeout(1000)
        c("第二个内置环境也建起来了", ok2)
        # 建完之后已经没有任何"未创建"的模板了 → 不该再有分组
        open_drop(page, sel_id)
        page.wait_for_timeout(1200)
        gs = groups(page, sel_id) or []
        c("没有未建模板时下拉不再分组（回到原来的样子）", len(gs) == 0,
          "实际分组=%s" % [g["label"] for g in gs])
        c("两个环境都还在选项里（不分组不等于丢选项）",
          {SCRNA, SPATIAL} <= {o["value"] for o in flat(page, sel_id)},
          "实际=%s" % [o["value"] for o in flat(page, sel_id)])
        page.keyboard.press("Escape")

        # ---- 7. 页面还是活的（state$env_rev 没有把它带进死循环） ----
        #
        # ⚠️ 这一条是冲着 app.R 里那段注释去的：在 observe 里写一个自己也
        #    读的 reactiveValue，会让 flushReact 在**同一次 flush** 里无限
        #    重新排队，整个 R 进程卡死、所有人白屏且不报错。真卡住的话，
        #    下面这个切页会超时/页面不再响应。
        t0 = time.time()
        goto(page, "envs", 3000)
        alive = page.locator("#envs-create_progress, .dsapp-shell").count() >= 0
        c("还能切到「环境」页（进程没被死循环卡死）",
          alive and (time.time() - t0) < 25, "%.1fs" % (time.time() - t0))

        c("浏览器控制台没有 JS 报错", not errs, "实际=%s" % errs[:3])

        b.close()
    return c.done()


if __name__ == "__main__":
    sys.exit(main())
