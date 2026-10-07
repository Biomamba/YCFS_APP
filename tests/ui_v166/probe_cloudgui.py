# -*- coding: utf-8 -*-
"""V16.6 item 4：云工具改成真 GUI —— 浏览器这一侧才看得见的几件事。

跑法（实例先起好）：
    bash tests/ui_v7/make_instance.sh 8977 /tmp/dsapp_v166a
    python3 tests/ui_v166/probe_cloudgui.py

用户原话：「云工具是有GUI的工具，而不是接入言出法随界面给提示词，请按新
         逻辑制作云工具界面」。

改之前：TCGA / 单细胞那两块里点**任何一行**，走的是
`sendCustomMessage("dsapp:lit_go")` —— 新开一个对话、把一段提示词发出去。
改之后：点一行出**参数表单**，填完真跑；文档里注册了但还没有执行体的那些
明说「未接入执行体」，**不发任何提示词**。

为什么非得上浏览器：`selftest.R` 那一组只能验到"函数对、源码里有那句话"。
下面这几条它一条都验不到 ——

  A. 这一页**还画得出来**（`outputOptions()` 的顺序坑：写在 output 定义
     *前面* = `stop()` = **整页白屏**，而 R 只在日志里说一句）
  B. 徽章数对得上：58 个工具里 4 个「可运行」、54 个「未接入执行体」
  C. 点一行出**表单**，而且 ★★ **回库对账：没有新建会话、没有新消息**
     —— 这一条是 `tests/ui_v164/probe_cloudreg.py` 那条断言的**反面**
     （它当时验的是"点一行 → 多一个会话 + 一条 user 消息"，正是用户要废掉
     的行为）。老探针照旧红着，那是**记录**，不回改。
  D. 点「未接入执行体」那一行：明说不能跑，**没有**「开始运行」按钮
  E. 真跑一次：种一张表达矩阵进工作区 → 下拉里选得到 → 点开始运行 →
     库里的任务行 success + 产物落盘 + 状态区把产物列出来

⚠️ 这一页的三块面板是**前端 `display:none` 切的**（www/app.js 的
   `.dsapp-cloud-tile` 那一段），所以：
   · 不点那颗图标，面板里的元素矩形是 **0×0**（本仓老账：隐藏元素的矩形
     是全 0），量出来的数看着完全合理；
   · 面板里那 10 个 output 必须 `suspendWhenHidden = FALSE`，否则**永远
     不画**（V16.4 实测：等 3 秒、客户端从没报告过 `output_*_hidden`，
     三个看得见的照样是空的）。
"""
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import _common as C

C.guard(C.APP)
ck = C.Chk()

# 执行体在这一版的映射（R/cloudrun.R 的 DSAPP_CLOUDX_TCGA / _SC）。
# ⚠️ 这两个数字**要和 R 那边对得上**：写死在这里是有意的 —— 从 R 现读一遍
#    等于拿被测代码验被测代码。真加了执行体就回来改这里，改的时候顺手确认
#    清单总数（58 / 49）没变。总数从**页面**上读（`#cloudtool-<p>_rows` 里
#    那句"显示 N 个 / 共 M 个"）。
WANT_TOTAL = {"tcga": 58, "sc": 49}
WANT_RUN = {
    "tcga": ["tcga_expression", "tcga_deg", "tcga_km", "tcga_unicox"],
    "sc": ["sc_read_data", "sc_qc_filter", "sc_normalize_hvg",
           "sc_dimreduce_cluster", "sc_find_markers", "sc_deg"],
}
# 拿来验"未接入执行体"的那两行（随便挑文档里有、执行体里没有的）
NOEXEC = {"tcga": "tcga_lasso", "sc": "sc_cellchat"}


# =============================================================================
# 库
# =============================================================================
def q(sql, args=()):
    con = sqlite3.connect("file:%s?mode=ro" % C.db_path(), uri=True)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def q1(sql, args=()):
    r = q(sql, args)
    return r[0][0] if r else None


def exec_sql(sql, args=()):
    con = sqlite3.connect(C.db_path(), timeout=15)
    try:
        con.execute(sql, args)
        con.commit()
    finally:
        con.close()


def relogin(pg, email):
    """reload 之后把自己弄回主界面。

    ⚠️ **不能**用 `C.wait_awake()`：它只认 `.dsapp-auth`，而 reload 时 cookie
       还在 —— 应用直接进主界面，登录页一帧都不出现，等它等于等一个永远
       不会来的东西（报出来是"150 秒还是空白页"，屏幕上的主界面早就好了）。
       所以等的是"两个可能里先到的那个"。这一段和 probe_jump.py 里那份是
       同一个东西（本仓规矩：脚本之间**抄**不 import）。
    """
    pg.reload(wait_until="domcontentloaded")
    submitted = False
    for _ in range(180):
        if pg.locator(".dsapp-shell").count():
            return True
        if not submitted and pg.locator("#welcome-email").count():
            pg.fill("#welcome-email", email)
            pg.fill("#welcome-password", C.PW)
            pg.click("button:has-text('登录')")
            submitted = True
        pg.wait_for_timeout(1000)
    return False


def counts():
    """三张表一起数。

    ⚠️ 只数 `sessions` 不够：那条被废掉的老路是"建会话 + 发消息"，两条都
       要能看见。而 `tasks` 是 ⑥ 那一段的判据（真跑要留一行任务）。
    """
    return (q1("SELECT count(*) FROM sessions"),
            q1("SELECT count(*) FROM messages"),
            q1("SELECT count(*) FROM tasks"))


def newest_sid(uid):
    r = q("SELECT id FROM sessions WHERE user_id = ? "
          "ORDER BY created_at DESC, rowid DESC LIMIT 1", (uid,))
    return r[0][0] if r else None


# =============================================================================
# 页面
# =============================================================================
JS_PANELS = """() => {
  const vis = e => { const r = e.getBoundingClientRect();
                     return r.width > 0 && r.height > 0; };
  return [...document.querySelectorAll('.dsapp-cloud-panel')].map(p => ({
    key: p.getAttribute('data-panel'),
    hid: p.classList.contains('dsapp-cloud-hidden'),
    vis: vis(p)}));
}"""

JS_ROWS = """(panel) => {
  const p = document.querySelector('.dsapp-cloud-panel[data-panel="' + panel + '"]');
  if (!p) return {found: false};
  const rows = [...p.querySelectorAll('.dsapp-cloud-tool')];
  const K = r => (((r.querySelector('.dsapp-cloud-tool-key') || {}).innerText) || '').trim();
  const B = r => (((r.querySelector('.badge') || {}).innerText) || '').trim();
  const T = r => (((r.querySelector('.dsapp-cloud-go') || {}).innerText) || '').trim();
  return {found: true, n: rows.length,
          keys: rows.map(K),
          runs:   rows.filter(r => B(r) === '可运行').map(K),
          noexec: rows.filter(r => B(r) === '未接入执行体').map(K),
          run_btn:   rows.filter(r => B(r) === '可运行').map(T),
          noexec_btn: rows.filter(r => B(r) === '未接入执行体').map(T),
          /* ⚠️ 这一句要从**工具清单那个 output 里面**取：整块面板里还有另一条
             .dsapp-cloud-hint（上半页"路线只作参考"那条），`panel.querySelector`
             取到的是**上面**那条 —— 它永远不含"共 58 个"，判据会一直红，而
             报出来的字符串看着完全合理。（ui_v164 那版记过同一笔。） */
          hint: (function () {
            const o = document.getElementById('cloudtool-' + panel + '_rows');
            const h = o ? o.querySelector('.dsapp-cloud-hint') : null;
            return h ? (h.innerText || '') : '';
          })()};
}"""


def rows_of(pg, panel):
    return pg.evaluate(JS_ROWS, panel)


JS_BENCH = """(panel) => {
  const vis = e => { if (!e) return false; const r = e.getBoundingClientRect();
                     return r.width > 0 && r.height > 0; };
  const w = document.getElementById('cloudtool-' + panel + '_workbench');
  const st = document.getElementById('cloudtool-tool_start');
  const stb = document.getElementById('cloudtool-' + panel + '_tool_status');
  return {found: !!w,
          txt: w ? (w.innerText || '') : '',
          n_ctl: w ? w.querySelectorAll('input, select, textarea').length : -1,
          /* 「开始运行」那颗按钮在**当前选中的那块面板**里，另一个面板的
             工作台画的是"还没选工具"那句占位话，所以同一时刻只有一个。 */
          start: !!st, start_vis: vis(st),
          start_txt: st ? (st.innerText || '').trim() : '',
          file_sel: !!document.getElementById('cloudtool-x_input'),
          file_man: !!document.getElementById('cloudtool-x_input_manual'),
          /* V16.7 item 4：两个上传框。folder 那个**只有** .dsapp-dirupload
             里的框才带 webkitdirectory（www/app.js 的全局 shim 加的），
             所以这两个属性是"文件夹上传真的接上了"的判据。 */
          file_up:  !!document.getElementById('cloudtool-x_input_up'),
          file_dir: !!document.getElementById('cloudtool-x_input_dir'),
          dir_ok: (function () {
            const el = document.getElementById('cloudtool-x_input_dir');
            if (!el) return false;
            const box = el.closest('.dsapp-dirupload');
            return !!(box && box.getAttribute('data-paths-input'));
          })(),
          paths_input: (function () {
            const el = document.getElementById('cloudtool-x_input_dir');
            const box = el ? el.closest('.dsapp-dirupload') : null;
            return box ? (box.getAttribute('data-paths-input') || '') : '';
          })(),
          status_found: !!stb,
          status_txt: stb ? (stb.innerText || '') : ''};
}"""


def bench_of(pg, panel):
    return pg.evaluate(JS_BENCH, panel)


def sel_selected(pg, sel_id):
    """读下拉**当前显示的那个值**（不打开下拉）。

    ⚠️ 不能用原生 `select.value` —— selectize 把原生 select 清空之后，值
       是记在它自己的 `.selectize-input` 文字上的（本仓老账
       selectize-hides-options）。这里读的是控件真的**显示给用户**的东西。
    """
    mnt = _ss_mount(pg, sel_id)
    return pg.evaluate("""(m) => {
      const ctl = document.getElementById(m);
      if (!ctl) return '';
      const i = ctl.querySelector('.selectize-input');
      return i ? (i.innerText || '').trim() : '';
    }""", mnt)


def set_folder_files(pg, sel_id, paths):
    """往 `.dsapp-dirupload` 那个框里塞一个**文件夹**（连同 webkitRelativePath）。

    ⚠️ Playwright 的 `set_input_files` 对 `webkitdirectory` 的框传目录会失败
       （那个属性是浏览器自己按"用户选了整个目录"填 files 的，脚本造不出来）。
       所以走 DataTransfer + 手工派发 change —— 和 www/app.js 里那个拖拽
       处理器用的是**同一套手势**，这样才真的验到那条 shim。
    """
    files = []
    for p in paths:
        with open(p, "rb") as f:
            files.append((os.path.basename(os.path.dirname(p)) + "/" +
                          os.path.basename(p), f.read()))
    # ⚠️ 返回值必须**来自浏览器**，不能 `return len(files)` —— 这个框不存在的
    #    时候 evaluate 会（在元素为 null 的分支里）返回 false，而调用方拿到的
    #    却是"塞进去了 3 个"，那条断言就永远绿。本仓栽过太多次"探针里拿不到
    #    元素就跳过/返回默认值"（selftest-green-is-not-coverage）：一条**不可能
    #    红**的断言和没写是一样的，而且更坏 —— 它长得像覆盖过。
    n = pg.evaluate("""(a) => {
      const el = document.getElementById(a[0]);
      if (!el) return false;
      const dt = new DataTransfer();
      for (const [name, text] of a[1]) {
        dt.items.add(new File([text], name.split('/').pop(),
                              {type: 'text/plain'}));
      }
      /* webkitRelativePath 是只读的，只能在 File 上重新定义 */
      let i = 0;
      for (const [name] of a[1]) {
        Object.defineProperty(dt.files[i], 'webkitRelativePath',
                              {value: name});
        i++;
      }
      el.files = dt.files;
      el.dispatchEvent(new Event('change', {bubbles: true}));
      return dt.files.length;
    }""", [sel_id, files])
    return n


def click_tile(pg, key):
    """点上面那颗图标。

    ⚠️ 先清弹窗（`ensure_no_modal`）：这一跳会**第一次**进对话页，新账号的
       「AI 怎么干活？」首选项弹窗就在那一刻盖上来，而且它盖的是**整页**。
       不在这里清的话，后面每一个 click 都会卡满 30 秒再报
       「intercepts pointer events」，报错指向那个按钮本身。
    """
    C.ensure_no_modal(pg)
    pg.click('.dsapp-cloud-tile[data-tool="%s"]' % key)
    pg.wait_for_timeout(900)


def click_row(pg, panel, key):
    """点工具清单里的某一行（按 key 找，不按序号）。"""
    idx = pg.evaluate("""(a) => {
      const p = document.querySelector('.dsapp-cloud-panel[data-panel="' + a[0] + '"]');
      if (!p) return -1;
      const rows = [...p.querySelectorAll('.dsapp-cloud-tool')];
      return rows.findIndex(r => {
        const k = r.querySelector('.dsapp-cloud-tool-key');
        return k && (k.innerText || '').trim() === a[1];
      });
    }""", [panel, key])
    if idx < 0:
        return False
    pg.locator('.dsapp-cloud-panel[data-panel="%s"] .dsapp-cloud-tool'
               % panel).nth(idx).locator('.dsapp-cloud-go').click()
    pg.wait_for_timeout(1500)
    return True


def wait_bench(pg, panel, pred, timeout=12.0):
    """等到工作台**稳定**到满足 pred。

    ⚠️ 点完那一行服务端要跑一趟才重画，这中间读到的是**上一次**的 DOM。
       不是"把红的等成绿的"：等满就把最后那次原样返回，断言照红。
    """
    end = time.time() + timeout
    d = bench_of(pg, panel)
    while time.time() < end and not pred(d):
        pg.wait_for_timeout(300)
        d = bench_of(pg, panel)
    return d


# ---- selectize（文件下拉）---------------------------------------------------
# ⚠️⚠️ selectize 控件**不是** select 的祖先：R 画出来的是
#     `<select id="x"></select><div class="selectize-control">…</div>` —— 两个
#     **兄弟**。`.selectize-control:has(#x)` 永远匹配不到（量出来 0 个，看着
#     像"这个控件不存在"）。先给那个兄弟挂个临时 id，再用真鼠标点它。
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
    """读下拉的选项（**必须先把下拉打开**）。

    ⚠️ selectize 会把原生 select **清空**（只剩当前选中那一项），选项是打开
       时才铺进 `.selectize-dropdown` 的（本仓老账 selectize-hides-options）。
       不打开就读，读到 0 个 —— 而 0 个看起来跟"这个控件本来就是空的"一样。
    """
    mnt = _ss_mount(pg, sel_id)
    pg.click("#%s .selectize-input" % mnt)
    pg.wait_for_timeout(800)
    return pg.evaluate("""(a) => {
      const ctl = document.getElementById(a[1]);
      const dd = ctl ? ctl.querySelector('.selectize-dropdown') : null;
      const opts = dd ? [...dd.querySelectorAll('.option')] : [];
      return {n: opts.length,
              texts: opts.map(o => (o.innerText || '').trim())};
    }""", [sel_id, mnt])


def pick_option(pg, sel_id, text):
    """在下拉里按**文字**选一项（选项的 data-value 和显示文字是同一个东西
    时才行 —— 文件下拉正是这种）。选完关掉下拉。"""
    mnt = _ss_mount(pg, sel_id)
    pg.click("#%s .selectize-input" % mnt)
    pg.wait_for_timeout(700)
    ok = pg.evaluate("""(a) => {
      const ctl = document.getElementById(a[1]);
      const dd = ctl ? ctl.querySelector('.selectize-dropdown') : null;
      if (!dd) return false;
      const o = [...dd.querySelectorAll('.option')].find(
        x => (x.innerText || '').trim() === a[2]);
      if (!o) return false;
      o.click();
      return true;
    }""", [sel_id, mnt, text])
    pg.wait_for_timeout(1200)
    if not ok:
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(300)
    return ok


# =============================================================================
# 夹具：一张小的表达矩阵
#   列名按 TCGA 条码编（`-01` 肿瘤 / `-11` 正常），这样脚本那条"按条码标
#   样本类型"的分支真的会走；顺带塞两个重名基因，走一遍去重。
# =============================================================================
def make_matrix(path, n_gene=40, n_tumor=6, n_normal=6):
    rows = []
    names = ["G%03d" % i for i in range(n_gene)]
    names[7] = names[6]                      # 重名 → 走 rowsum 去重那条
    samples = (["TCGA-AA-%04d-01A" % i for i in range(1, n_tumor + 1)] +
               ["TCGA-AA-%04d-11A" % i for i in range(1, n_normal + 1)])
    rows.append("gene," + ",".join(samples))
    for gi, g in enumerate(names):
        vals = []
        for si in range(len(samples)):
            # 造一点结构：肿瘤那边 +20，让 PCA 两组分得开、箱线图有得看
            base = 50 + gi * 3
            vals.append(str(base + (20 if si < n_tumor else 0) + (si % 3)))
        rows.append(g + "," + ",".join(vals))
    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")
    return len(names), len(samples)


def wait_task(tid, timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        r = q("SELECT status, exit_code FROM tasks WHERE id = ?", (tid,))
        if r and r[0][0] in ("success", "failed", "error", "canceled"):
            return r[0]
        time.sleep(1.5)
    return None


# =============================================================================
def main():
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1500, "height": 950})
        try:
            email = C.enter_app(pg)
            uid, _db = C.seed_or_die(email)

            # ★★ 云工具那一页**只给平台管理员**（V16.5 item 5：`DSAPP_NAV_ITEMS`
            #    里那条 `role = "platform"`，连同 app.R 里同判据的那个出口）。
            #    刚注册的号是普通用户 —— 不提升的话 `goto(pg, "cloudtool")`
            #    会**静静地留在上一页**（`dsappNav()` 找不到那个 value 不报错），
            #    而后面每一句几何断言都量在别的页面上，报出来的是"这个元素
            #    找不到"，跟真正的原因隔着十万八千里。
            #    ⚠️ 提升完必须**重新登录**：这份 UI 是 `output$app_root` 在
            #    会话起步时按当时那个 user 渲染的，reactive 不会自己知道库里
            #    那一行变了。
            exec_sql("UPDATE users SET is_admin = 1, admin_scope = 'platform' "
                     "WHERE id = ?", (uid,))
            ck("⓪ 把自己提成平台管理员并重新登录（云工具只给平台管理员）",
               relogin(pg, email))

            # ---- 先开一个对话：产物要落在**对话工作区**里，没有打开的对话
            #      这一页会拒绝运行（那句提示本身也是要验的东西之一）。
            C.goto(pg, "chat")
            C.ensure_no_modal(pg)
            pg.click("#chat-new_chat")
            pg.wait_for_timeout(3000)
            sid = newest_sid(uid)
            ck("① 先开了一个对话（后面真跑那一段要有工作区）",
               bool(sid), "sessions 里最新的 sid = %r" % sid)

            ws = os.path.join(C.DATA_ROOT, "workspaces", "chat-%s" % sid)

            # ★ V16.7 item 4：**不再**把矩阵直接写进工作区。
            #   那是上一版的走法，也是这次要补的那个洞的证据 —— 界面当时
            #   根本没法把一个文件交给云工具，探针只好绕过整个 UI 往盘上写。
            #   现在文件先落在工作区**外面**的暂存目录，由 ④ 那一段通过
            #   上传框真的传进去。
            #   ⚠️ 工作区目录也因此**不自己建**了：正是要验"上传会把它建出来"
            #     （应用只在提交任务那一刻建它，见 R/executor.R）。
            stage = os.path.join(C.OUT, "upload_stage")
            os.makedirs(stage, exist_ok=True)
            csv_name = "probe_expr.csv"
            n_gene, n_smp = make_matrix(os.path.join(stage, csv_name))
            ck("① 暂存目录里备了一张表达矩阵（%d 基因 × %d 样本，"
               "列名是 TCGA 条码）—— 等 ④ 通过界面上传进去" % (n_gene, n_smp),
               os.path.exists(os.path.join(stage, csv_name)), stage)
            ck("① 此刻工作区里**还没有**这个文件（证明 ④ 那一份是传进去的）",
               not os.path.exists(os.path.join(ws, csv_name)), ws)

            # ★ 基线：**在我们自己开完对话之后**取。取早了会把"① 这一步
            #   自己建的会话"算进后面的增量里（假红）。
            base = counts()

            # =============================================================
            print("\n=== ⓪ 这一页还画得出来吗（outputOptions 顺序坑 = 白屏）===",
                  flush=True)
            # =============================================================
            C.goto(pg, "cloudtool")
            foot = pg.evaluate(
                "() => ((document.body.innerText.match(/Test_V[0-9.]+/) "
                "|| [])[0]) || ''")
            # ⚠️ 期望值从**实例的** R/config.R 现读，不再写死字面量。
            #    写死的话每次发版都要回来改一次，而漏改的症状是"探针红了",
            #    报出来的却像是云工具坏了（本仓有账：改常数要连断言里的
            #    字面量一起清）。这一条问的是"**我连上的是我以为的那个实例吗**"
            #    —— 那正是"页面上的版本号 == 这个实例自己的版本号"。
            #    读不到就当成空串 → 下面必红，不会静默通过。
            want_ver = ""
            try:
                with open(os.path.join(C.APP, "R", "config.R"),
                          encoding="utf-8", errors="replace") as f:
                    m = re.search(r'DSAPP_VERSION\s*<-\s*"([^"]+)"', f.read())
                    want_ver = m.group(1) if m else ""
            except Exception as e:
                print("     读不到实例的 config.R：%s" % e)
            ck("⓪ 页脚版本 == 实例 R/config.R 里的版本（连错实例的话这一条先响）",
               bool(want_ver) and foot == want_ver,
               "页脚 %r / 实例期望 %r" % (foot, want_ver))
            body = pg.inner_text("body")
            ck("⓪ 云工具页有内容（不是白屏）", len(body) > 200,
               "页面文字 %d 字" % len(body))
            pans = pg.evaluate(JS_PANELS)
            ck("⓪ 三块面板都在，默认只显示第一块（结合蛋白设计）",
               [p["key"] for p in pans] == ["design", "tcga", "sc"] and
               pans[0]["vis"] and not pans[1]["vis"] and not pans[2]["vis"],
               pans)

            # =============================================================
            print("\n=== ① 两个「文档面板」：清单画得出来、徽章数对得上 ===",
                  flush=True)
            # =============================================================
            for panel in ("tcga", "sc"):
                click_tile(pg, panel)
                pans = pg.evaluate(JS_PANELS)
                ck("① 点「%s」那颗图标 → 它显示、另外两块藏起来" % panel,
                   [p["key"] for p in pans if p["vis"]] == [panel], pans)

                end = time.time() + 20
                r = rows_of(pg, panel)
                while time.time() < end and not r.get("n"):
                    pg.wait_for_timeout(400)
                    r = rows_of(pg, panel)
                ck("① %s：工具清单画出来了（%d 行）" % (panel, r.get("n", 0)),
                   r.get("n", 0) > 0, r.get("hint", "")[:120])
                m = re.search(r"共\s*(\d+)\s*个", r.get("hint", ""))
                ck("① %s：清单自报的条目数是 %d" % (panel, WANT_TOTAL[panel]),
                   bool(m) and int(m.group(1)) == WANT_TOTAL[panel],
                   "hint=%r" % r.get("hint", "")[:120])

                ck("① %s：标「可运行」的正好是那 %d 个"
                   % (panel, len(WANT_RUN[panel])),
                   sorted(r.get("runs", [])) == sorted(WANT_RUN[panel]),
                   r.get("runs"))
                ck("① %s：其余 %d 个标「未接入执行体」"
                   % (panel, WANT_TOTAL[panel] - len(WANT_RUN[panel])),
                   len(r.get("noexec", [])) ==
                   WANT_TOTAL[panel] - len(WANT_RUN[panel]),
                   "数出来 %d 个" % len(r.get("noexec", [])))
                ck("① %s：能跑的那几行按钮写「配置并运行」、其余写「看看它要什么」"
                   % panel,
                   set(r.get("run_btn", [])) == {"配置并运行"} and
                   set(r.get("noexec_btn", [])) == {"看看它要什么"},
                   {"run": sorted(set(r.get("run_btn", []))),
                    "noexec": sorted(set(r.get("noexec_btn", [])))})

            # =============================================================
            print("\n=== ② 点一行 → 出的是**参数表单**，不是新会话 ===",
                  flush=True)
            # =============================================================
            # 这一条是 ui_v164/probe_cloudreg.py 那条断言的**反面**：
            # 它当时验的是"点一行 → 回库对账：多了一个会话 + 一条 user 消息"
            # ——那正是用户要废掉的行为。改判据，不回改那份冻结记录。
            click_tile(pg, "tcga")
            ok = click_row(pg, "tcga", "tcga_expression")
            ck("② 点中「tcga_expression」那一行", ok)
            d = wait_bench(pg, "tcga",
                           lambda x: x["start"] and x["n_ctl"] > 0)
            ck("② 工作台画出了参数表单（%d 个控件）" % d["n_ctl"],
               d["n_ctl"] >= 5, d["txt"][:200])
            ck("② 表单里有「开始运行」那颗按钮，而且看得见",
               d["start"] and d["start_vis"],
               "start=%s vis=%s txt=%r" % (d["start"], d["start_vis"],
                                           d["start_txt"]))
            ck("② 文件那一栏是「下拉 + 手填」两个控件",
               d["file_sel"] and d["file_man"], d)
            # ⚠️ 「不含某个词」这种判据**必须**先要求它有内容：工作台一片空白
            #    时（挂起没关 = 永远不画）空串里当然没有"提示词"，这一条会
            #    **假绿**。2026-10-05 拿真变异验过：把工作台那四个 output 从
            #    `suspendWhenHidden = FALSE` 那串里摘掉，上面两条红了、这一条
            #    照样绿 —— 加了这个 `len(...) > 20` 之后三个一起红。
            ck("② 没有把它画成「要发提示词」的样子（工作台里不再有开场白）",
               len(d["txt"]) > 20 and "提示词" not in d["txt"] and
               "言出法随" not in d["txt"], d["txt"][:200])
            now = counts()
            ck("② ★ 回库对账：点这一行**没有**新建会话、没有新消息、没有新任务",
               now == base, "之前 %s → 现在 %s" % (base, now))

            # =============================================================
            print("\n=== ③ 文档里有、执行体里没有的那一行：明说不能跑 ===",
                  flush=True)
            # =============================================================
            for panel in ("tcga", "sc"):
                if panel == "sc":
                    click_tile(pg, "sc")
                key = NOEXEC[panel]
                ok = click_row(pg, panel, key)
                d = wait_bench(pg, panel,
                               lambda x: "未接入执行体" in x["txt"])
                ck("③ %s：点「%s」→ 工作台明说「未接入执行体」" % (panel, key),
                   ok and "未接入执行体" in d["txt"], d["txt"][:200])
                # ⚠️ 这里同样要先确认**工作台本身画出来了**：一片空白时
                #    `start` 当然也是 False，那这一条就是白送的绿。
                ck("③ %s：这时**没有**「开始运行」按钮（点了也不该跑）"
                   % panel, bool(d["txt"].strip()) and not d["start"],
                   "txt=%r start=%s" % (d["txt"][:80], d["start"]))
                ck("③ %s：它同时说清楚「不跑任何东西、也不发提示词」" % panel,
                   "不会把提示词发给谁" in d["txt"] or
                   "不会跑任何东西" in d["txt"], d["txt"][:200])
            now = counts()
            ck("③ ★ 回库对账：点这些行照样**不建会话、不发消息**",
               now == base, "之前 %s → 现在 %s" % (base, now))

            # =============================================================
            print("\n=== ④ 真跑一次：种进去的那张矩阵 → 产物落盘 ===", flush=True)
            # =============================================================
            click_tile(pg, "tcga")
            click_row(pg, "tcga", "tcga_expression")
            d = wait_bench(pg, "tcga", lambda x: x["start"])

            # ★★★ V16.7 item 4：**从界面上传**，不再绕过去直接写盘。
            #     用户原话：「单细胞云工具里需要支持上传数据来进行分析」。
            ck("④ 文件字段旁边有「上传文件」和「上传文件夹」两个框",
               d["file_up"] and d["file_dir"], d)
            ck("④ ★ 文件夹框外层挂着 .dsapp-dirupload + data-paths-input"
               "（拼错 = 文件夹上传静默退化成平铺，没有任何报错）",
               d["dir_ok"] and d["paths_input"].endswith("x_input_dirpaths"),
               "data-paths-input = %r" % d["paths_input"])

            # ⚠️ 先在旁边的**文本框**里填一个非默认值。上传之后它必须还在
            #    —— 这是"上传没有把整个表单重建"唯一的判据，而表单一旦被
            #    重建，用户是**打字打到一半焦点就丢**，不会有任何报错。
            pg.fill("#cloudtool-x_name", "myexpr")
            pg.wait_for_timeout(300)

            pg.set_input_files("#cloudtool-x_input_up",
                               os.path.join(stage, csv_name))
            pg.wait_for_timeout(3500)

            ck("④ ★ 上传后下拉**自动选中**了刚传的那个文件（不是靠手填那条捷径）",
               csv_name in sel_selected(pg, "cloudtool-x_input"),
               "下拉现在显示 %r" % sel_selected(pg, "cloudtool-x_input"))
            ck("④ ★★ 上传**没有重建表单**：先前填进去的产物名还在"
               "（重建的话用户是打字打到一半焦点就丢，不报错）",
               pg.input_value("#cloudtool-x_name") == "myexpr",
               "现在是 %r" % pg.input_value("#cloudtool-x_name"))
            # 回盘对账：共享区（「文件」页那个区）里有一份真身，
            # 工作区里那一条是**软链**指过去 —— 不是复制。
            shared = os.path.join(C.DATA_ROOT, "files", "u%d" % uid, csv_name)
            ck("④ ★ 文件真的落进了「文件」页那个上传区",
               os.path.exists(shared), shared)
            ck("④ ★ 工作区里那一条是**软链**，指向共享区那份",
               os.path.islink(os.path.join(ws, csv_name)) and
               os.path.exists(os.path.join(ws, csv_name)),
               os.path.join(ws, csv_name))
            # ⚠️ 工作区目录在此之前是**不存在**的（① 那一段刻意没建它）
            ck("④ 上传把工作区目录建出来了（懒建：不建的话下拉永远是空的）",
               os.path.isdir(ws), ws)

            # 连传**同一个文件**第二次：输入框没复位的话浏览器认为没变化、
            # change 不触发，"点了上传没反应"（mod_files.R 里记过这条）。
            n_before2 = len(os.listdir(os.path.join(C.DATA_ROOT, "files",
                                                    "u%d" % uid)))
            pg.set_input_files("#cloudtool-x_input_up",
                               os.path.join(stage, csv_name))
            pg.wait_for_timeout(3500)
            ck("④ ★ 连传同一个文件第二次仍然触发（说明输入框被复位了）",
               len(os.listdir(os.path.join(C.DATA_ROOT, "files",
                                           "u%d" % uid))) > n_before2,
               "共享区文件数 %d → %d"
               % (n_before2,
                  len(os.listdir(os.path.join(C.DATA_ROOT, "files",
                                              "u%d" % uid)))))
            # 第二次上来的是 probe_expr(1).csv（同名不覆盖），把它选回来，
            # 后面真跑用原来那份。
            said = pick_option(pg, "cloudtool-x_input", csv_name)
            ck("④ 下拉里列得出工作区里那张矩阵", said,
               sel_options(pg, "cloudtool-x_input")["texts"][:10])

            opts = sel_options(pg, "cloudtool-x_input")
            ck("④ 候选里有刚传上去的那一份",
               csv_name in [t.strip() for t in opts["texts"]],
               opts["texts"][:10])
            pg.keyboard.press("Escape")
            pg.wait_for_timeout(300)
            picked = pick_option(pg, "cloudtool-x_input", csv_name)
            ck("④ 在下拉里真的选中了它（不是走手填那条捷径）", picked)

            before_tid = q1("SELECT max(id) FROM tasks")
            C.ensure_no_modal(pg)
            pg.click("#cloudtool-tool_start")
            pg.wait_for_timeout(2000)
            ck("④ 点了「开始运行」之后，任务行多了一行（引擎真的收到了）",
               (q1("SELECT max(id) FROM tasks") or 0) > (before_tid or 0),
               "max(id): %s → %s" % (before_tid,
                                     q1("SELECT max(id) FROM tasks")))
            d = wait_bench(pg, "tcga", lambda x: x["status_found"])
            ck("④ 状态区画出来了（这一步在跑 / 跑完了就在这儿报）",
               d["status_found"], d["txt"][:200])

            tid = q1("SELECT max(id) FROM tasks")
            row = wait_task(tid)
            ck("④ 库里那一行跑成 success（不是 pending 也不是 failed）",
               row is not None and row[0] == "success",
               "task #%s → %s" % (tid, row))

            # 产物：目录名是 `<ws>/cloud/tcga-tcga_expression-<时间戳>`
            runs = sorted([p for p in
                           os.listdir(os.path.join(ws, "cloud"))
                           if p.startswith("tcga-tcga_expression-")]
                          if os.path.isdir(os.path.join(ws, "cloud")) else [])
            ck("④ 产物的运行目录建出来了", bool(runs), runs[-3:])
            root = os.path.join(ws, "cloud", runs[-1]) if runs else None
            got = sorted(os.listdir(root)) if root else []
            ck("④ 四个产物都在盘上（expr_matrix.csv / sample_types.csv / "
               "两张 png）",
               all(x in got for x in ("expr_matrix.csv", "sample_types.csv",
                                      "expr_pca.png", "expr_boxplot.png")),
               got)
            ck("④ 生成的那份脚本也留着（用户能打开看它到底干了什么）",
               "run.sh" in got, got)
            log = ""
            if root and os.path.exists(os.path.join(root, "run.log")):
                log = open(os.path.join(root, "run.log"),
                           encoding="utf-8", errors="replace").read()
            ck("④ run.log 里有 log2 那一步的回执（证明跑的是这张表）",
               "已做 log2" in log or "保持原值" in log, log[-300:])

            # 进「文件」页那条路：状态区里那颗按钮在，点了跳得过去
            d = wait_bench(pg, "tcga", lambda x: "产物" in x["status_txt"])
            ck("④ 状态区把产物列出来了（不是只写一句「跑完了」）",
               "expr_matrix.csv" in d["status_txt"] and
               "run.sh" not in d["status_txt"],
               d["status_txt"][:300])
            ck("④ 状态区里有「在「文件」页打开这个工作区」那颗按钮",
               "在「文件」页打开" in d["status_txt"],
               d["status_txt"][:200])

            # =============================================================
            print("\n=== ⑤ 文件夹上传：10x 三文件目录（.dsapp-dirupload 的唯一验法）===",
                  flush=True)
            # =============================================================
            # 单细胞的 10x 数据天然是**一个目录三个文件**，用户选的正是
            # 那个目录。这一段的判据必须是"目录结构保住了" —— 只看"文件在
            # 不在"的话，平铺（`<ws>/matrix.mtx` 而不是 `<ws>/sample1/matrix.mtx`）
            # 照样绿，而那正是这一类改动最容易出的错。
            up_dir = os.path.join(stage, "sample1")
            os.makedirs(up_dir, exist_ok=True)
            for fn in ("matrix.mtx", "barcodes.tsv", "features.tsv"):
                with open(os.path.join(up_dir, fn), "w") as f:
                    f.write("%%MatrixMarket\n1 1 1\n1 1 1\n")
            three = [os.path.join(up_dir, fn)
                     for fn in ("matrix.mtx", "barcodes.tsv", "features.tsv")]

            click_tile(pg, "sc")
            click_row(pg, "sc", "sc_read_data")
            d = wait_bench(pg, "sc", lambda x: x["start"])
            ck("⑤ 单细胞的「读入」工作台画出来了", d["start"], d["txt"][:200])

            n = set_folder_files(pg, "cloudtool-x_input_dir", three)
            pg.wait_for_timeout(4000)
            ck("⑤ 往文件夹框里塞了 3 个文件（带 webkitRelativePath）", n == 3)

            ck("⑤ ★★ 目录结构保住了：工作区里是 sample1/matrix.mtx，"
               "**不是**平铺的 matrix.mtx",
               os.path.isfile(os.path.join(ws, "sample1", "matrix.mtx")) and
               not os.path.exists(os.path.join(ws, "matrix.mtx")),
               "ws/sample1 = %r" % (sorted(os.listdir(os.path.join(ws, "sample1")))
                                    if os.path.isdir(os.path.join(ws, "sample1"))
                                    else "（目录不存在）"))
            ck("⑤ ★ 共享区里也是带目录的那一份（归属登记要用相对路径）",
               os.path.isfile(os.path.join(C.DATA_ROOT, "files", "u%d" % uid,
                                           "sample1", "matrix.mtx")))
            ck("⑤ ★ 下拉自动选中的是那个**目录**（10x 要的就是目录，不是某个文件）",
               "sample1" in sel_selected(pg, "cloudtool-x_input"),
               "下拉现在显示 %r" % sel_selected(pg, "cloudtool-x_input"))
            ck("⑤ 三个文件一个不少",
               all(os.path.isfile(os.path.join(ws, "sample1", fn))
                   for fn in ("matrix.mtx", "barcodes.tsv", "features.tsv")))

            pg.screenshot(path=os.path.join(C.OUT, "v166_cloudgui.png"),
                          full_page=True)
        finally:
            pg.wait_for_timeout(500)
            b.close()
    return ck.done()


if __name__ == "__main__":
    sys.exit(main())
