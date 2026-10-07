# -*- coding: utf-8 -*-
"""V12 item 4 的另一半：「一键创建」点下去之后真的会发生什么。

这是**唯一**一条会真的跑 conda 的界面测试，所以单独一个文件 —— 它慢
（解依赖几分钟），不该混进 tests/ui_v12/envs.py 那个每次改界面都要跑的
快套件里。

它建的是一个只有 numpy 的小环境，**不是**单细胞/空转那两个 ——
用户明确说了先别真建那两个（依赖多，solve 要十几分钟）。

⚠️ 建出来的环境落在**这个测试实例自己的** DSAPP_DATA_ROOT/envs 底下
   （/tmp/... ），不会碰到线上那份。所以这个脚本的 guard 和别的几个一样
   重要：DSAPP_DATA_ROOT 不在 /tmp 或 /var/tmp 下就直接拒绝运行。

验的是这条链路上"界面能看见"的部分：
  点按钮 → 立刻返回不卡页面 → 进度面板出现 → 日志在动
  → 建完之后通知 + 环境出现在基础环境列表里（状态是"可用"不是"构建中"）
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, guard, pick_select, APP, DATA_ROOT   # noqa: E402

guard(APP)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

ENV_NAME = "v12probe"
# 只留 conda-forge：bioconda 会让 solve 慢好几倍，而这个探针要验的是
# "按钮→作业→进度→完成"这条链路，不是 solve 有多快。
SPEC = """name: %s
python: 3.11
channels: conda-forge
packages:
  - numpy
""" % ENV_NAME


def goto_envs(page):
    page.evaluate("() => window.dsappNav && window.dsappNav('envs')")
    page.wait_for_timeout(2500)
    page.wait_for_selector("#envs-spec_text", timeout=30000)


def env_status(page, name):
    """从基础环境列表里读某个环境的状态（读页面，不读数据库）。"""
    return page.evaluate("""(nm) => {
      const rows = Array.from(document.querySelectorAll('.dsapp-envrow, tr, .dsapp-env-item'));
      for (const r of rows) {
        if (r.textContent.includes(nm)) return r.textContent.trim().slice(0, 120);
      }
      const b = document.body.innerText;
      const i = b.indexOf(nm);
      return i < 0 ? null : b.slice(i, i + 120);
    }""", name)


def main():
    if os.path.exists(os.path.join(DATA_ROOT, "envs", ENV_NAME)):
        sys.exit("拒绝运行：%s 里已经有 %s 了。先删掉它再跑。"
                 % (os.path.join(DATA_ROOT, "envs"), ENV_NAME))

    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--no-sandbox"])
        pg = b.new_page(viewport={"width": 1600, "height": 1000})
        try:
            enter_app(pg)
            goto_envs(pg)

            # ---- 造一份只有 numpy 的配置 ----
            pg.fill("#envs-spec_text", SPEC)
            pg.wait_for_timeout(1500)
            pv = pg.locator("#envs-spec_preview").inner_text()
            chk("（前置）探针配置解析成了 %s / 1 个包" % ENV_NAME,
                ENV_NAME in pv and "1 个包" in pv, pv[:200])
            chk("（前置）按钮是亮的（名字没重、机器不忙、找得到 solver）",
                pg.locator("#envs-spec_create").count() == 1,
                "按钮没出现 —— 预览里的提示是：" + pv[:300])
            if pg.locator("#envs-spec_create").count() == 0:
                return chk.done()

            # ---- ★ 点下去 ----
            t0 = time.time()
            pg.click("#envs-spec_create")

            # ★ 立刻返回：conda solve 是几分钟到十几分钟的事，这一下要是
            #   同步等，整个应用（所有访客共用一个 R 进程）会一起冻住。
            pg.wait_for_timeout(2500)
            elapsed = time.time() - t0
            chk("★★ 点下去之后页面没卡住（conda 是异步起的，不是同步等）",
                elapsed < 60, "点击后 %.1fs 才回到脚本" % elapsed)
            chk("★★ 点下去之后**立刻**能看到进度面板",
                pg.locator("#envs-create_progress").count() == 1)
            prog = pg.locator("#envs-create_progress").inner_text()
            chk("★★ 进度面板里已经在滚 conda 的日志了",
                len(prog.strip()) > 20, repr(prog[:200]))
            chk("★ 进度面板说清了在等什么（不是一句干巴巴的「请稍候」）",
                any(k in prog for k in ("解", "依赖", "conda", "创建", "下载", "等")),
                prog[:300])
            pg.screenshot(path=os.path.join(OUT, "v12_envs_create_running.png"),
                          full_page=True)

            # ---- ★ 页面还能用（这是异步的全部意义）----
            pg.evaluate("() => window.dsappNav && window.dsappNav('files')")
            pg.wait_for_timeout(1500)
            chk("★★★ 建的过程中还能切到别的页（没把唯一的 R 进程占死）",
                pg.locator(".dsapp-page").count() > 0)
            pg.evaluate("() => window.dsappNav && window.dsappNav('envs')")
            pg.wait_for_timeout(2000)

            # ---- ★ 等它建完 ----
            #
            # ⚠️ 判据是面板里出现「建好了 / 没建起来」，**不是**面板消失。
            #    这一格建完之后是留着的（用户回来还能看到结果和日志尾部），
            #    要等它消失会一直等到超时。
            done = fail = False
            last = ""
            for _ in range(110):                      # 最长约 9 分钟
                pg.wait_for_timeout(5000)
                txt = pg.locator("#envs-create_progress").inner_text() \
                    if pg.locator("#envs-create_progress").count() else ""
                last = txt
                if "建好了" in txt:
                    done = True
                    break
                if "没建起来" in txt:
                    fail = True
                    break
            pg.screenshot(path=os.path.join(OUT, "v12_envs_create_done.png"),
                          full_page=True)
            chk("★★ 作业跑完了（进度面板自己变成结果，不用手动刷新）",
                done, "9 分钟内没出结果。最后一段日志：\n" + last[-800:])
            chk("★★ 建成功了（不是「没建起来」）", done and not fail,
                last[-800:])

            # ---- ★ 建出来的环境在列表里，而且是"可用" ----
            pg.reload(wait_until="domcontentloaded")
            pg.wait_for_selector(".dsapp-shell", timeout=30000)
            pg.wait_for_timeout(3000)
            goto_envs(pg)
            st = env_status(pg, ENV_NAME)
            chk("★★★ 建完的环境出现在「基础环境」列表里", st is not None, st)
            chk("★★ 状态是「可用」，不是「构建中」（后者会让用户不敢选它）",
                st is not None and "构建中" not in st, st)
            chk("★ 列表里报了它的 Python 版本", st is not None and "python" in st.lower(),
                st)

            # ---- ★ 解释器真的在磁盘上、真的能跑 ----
            py = os.path.join(DATA_ROOT, "envs", ENV_NAME, "bin", "python")
            chk("★★ 环境的解释器真的建出来了", os.path.exists(py), py)
            if os.path.exists(py):
                import subprocess
                r = subprocess.run([py, "-c", "import numpy; print(numpy.__version__)"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=120)
                out = r.stdout.decode("utf-8", "replace").strip()
                chk("★★★ 建出来的环境里 numpy 真的能 import（建好了 ≠ 装上了）",
                    r.returncode == 0 and out and "." in out, out[:200])
        except Exception as e:                       # noqa: BLE001
            pg.screenshot(path=os.path.join(OUT, "v12_envs_create_error.png"),
                          full_page=True)
            print("异常：%r" % (e,))
            print("页面文字：\n%s" % pg.inner_text("body")[:1200])
            raise
        finally:
            b.close()
    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
