# -*- coding: utf-8 -*-
"""V12 item 4：环境配置上传 + 内置模板（浏览器端）。

用户原话：「环境也要像 skills 一样可以自动上传配置，帮我预设单细胞/空转环境」

解析那一半（模板在不在、各种形状认不认、版本号去没去）在 selftest.R 里。
这里管的是**界面这一半**，而且专挑"离线断言看不见"的那几条：

  ★ 换模板真的会把文本灌进编辑器
      这一步走的是 updateTextAreaInput(session, ...) + **模块** session。
      这个仓库对"模块 session 上哪些方法能用"有过两种互相矛盾的说法
      （见 utils.R 的 dsapp_session 与 mod_chat.R 里踩过的坑）：
      sendCustomMessage 是静默失效的 —— 不报错、没反应。updateTextAreaInput
      是同类调用，所以必须真的在浏览器里改一次下拉框、读一次框里的内容
      才算验过。离线断言永远测不出这个。

  ★ 上传文件真的会把内容灌进编辑器
      同上，而且这里还多一层：读文件走 dsapp_read_text_file（UTF-8 → GBK
      回退）。探针上传一份 **GBK 编码**的 yaml —— 一份纯 ASCII 的测试文件
      就算读成乱码也看不出来，测不出回退有没有生效。

  ★ 预览跟着编辑器走
      包名要逐个列出来。不列的话解析器把清单读歪了（把注释当包名之类）
      用户看不出来，而 conda 会照着这份清单跑二十分钟再失败。

  ★ 坏配置把「一键创建」变灰，好配置变亮
      "变灰"必须是真的 disabled，不是"看着像灰的但点得动"。

⚠️ 这个脚本**不点「一键创建」**。用户明确说了先别真建那两个环境，而且
   conda 环境是**全站共享**的，在测试实例上建出来会和线上抢同一份
   envs 目录（同一个 DSAPP_DATA_ROOT 才隔离，而真实环境目录是共享的）。
   建的那条路走的是 dsapp_env_create，那条路的断言在 selftest.R 里。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import Chk, OUT, enter_app, guard, pick_select, APP   # noqa: E402

guard(APP)

from playwright.sync_api import sync_playwright   # noqa: E402

chk = Chk()

GBK_YAML = """\
name: gbk_probe_env
channels:
  - conda-forge
dependencies:
  - python=3.10.13
  - numpy=1.26.4
  - pandas
  - pip:
    - scanpy==1.10.0
"""
# 中文注释是为了让这份文件真的是 GBK —— 纯 ASCII 的话"UTF-8 读失败再回退"
# 这条路根本走不到（ASCII 两种编码下字节一样）。
GBK_YAML_CN = GBK_YAML + "# 这是中文注释，用来把文件变成真正的 GBK\npackages_note: 单细胞\n"


def write_gbk(path, text):
    with open(path, "wb") as fh:
        fh.write(text.encode("gbk"))
    return path


def goto_envs(page):
    page.evaluate("() => window.dsappNav && window.dsappNav('envs')")
    page.wait_for_timeout(2500)
    page.wait_for_selector("#envs-spec_text", timeout=30000)


def editor_text(page):
    return page.locator("#envs-spec_text").input_value()


def create_btn(page):
    """返回 (有没有可点的按钮, 有没有灰着的按钮)。"""
    lit = page.locator("#envs-spec_create").count()
    grey = page.evaluate("""() => {
      const b = document.querySelector('#envs-spec_create');
      if (b) return 0;
      const card = document.querySelector('#envs-spec_preview');
      if (!card) return 0;
      return card.querySelectorAll('button[disabled]').length;
    }""")
    return lit, grey


def main():
    gbk_path = write_gbk(os.path.join(OUT, "gbk_env.yaml"), GBK_YAML_CN)

    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--no-sandbox"])
        pg = b.new_page(viewport={"width": 1600, "height": 1000})
        try:
            enter_app(pg)
            goto_envs(pg)

            # ---- 卡片在不在 ----
            body = pg.inner_text("body")
            chk("★ 环境页上有「新建环境」这张卡", "新建环境" in body)
            # ⚠️ 数 #envs-tpl_pick 里的 <option> 是**数不出东西**的：这个
            #    select 被 selectize 接管了，selectize 会把选项搬进自己的
            #    store，原生 <select> 里只留下当前选中的那一个（所以上面那条
            #    以前只能看到 ['单细胞']）。要问的是 selectize 自己那份。
            opts = pg.evaluate("""() => {
              const s = document.getElementById('envs-tpl_pick');
              const sz = s && s.selectize;
              if (!sz) return [];
              // selectize 的 option 对象是 {value, label}；显示文本在 label
              // 上（item 上那个字段才叫 text）—— 取 .text 会得到一串 null。
              return Object.keys(sz.options).map(
                k => sz.options[k].label || sz.options[k].text || k);
            }""")
            chk("★ 下拉框里有「单细胞」「空转」两个模板", len(opts) >= 2, opts)
            chk("★ 两个模板名字就是这两个字", "单细胞" in opts and "空转" in opts, opts)
            chk("★★ 卡片上写清了「建的是全站共享的」",
                "共享" in pg.locator("#envs-create_ui").inner_text())

            # ---- 初值 = 第一个模板 ----
            t0 = editor_text(pg)
            chk("★ 编辑器一打开就装着第一个模板（不是空的）",
                "name:" in t0 and "packages:" in t0, t0[:80])
            chk("★ 初值里那个环境名合法", "name: scRNA" in t0, t0[:200])

            # ---- ★ 换模板：验证 updateTextAreaInput 在模块 session 上真的有效 ----
            pick_select(pg, "envs-tpl_pick", "空转")
            pg.wait_for_timeout(1500)
            t1 = editor_text(pg)
            pg.screenshot(path=os.path.join(OUT, "v12_envs_tpl_spatial.png"), full_page=True)
            chk("★★★ 换到「空转」之后编辑器内容真的变了（模块 session 上的 "
                "updateTextAreaInput 有效，不是静默失效）",
                t1 != t0, "内容没变：%r" % t1[:60])
            chk("★★ 换过去的是**空转那一份**（不是随便变了点什么）",
                "name: spatial" in t1 and "squidpy" in t1,
                t1[:200])
            chk("★ 换模板不带过来上一个模板的包",
                "scrublet" not in t1 and "bbknn" not in t1, t1[:400])
            pick_select(pg, "envs-tpl_pick", "单细胞")
            pg.wait_for_timeout(1200)
            chk("★ 换回去也对（来回切不粘）",
                "name: scRNA" in editor_text(pg), editor_text(pg)[:60])

            # ---- ★ 预览跟着编辑器走 ----
            pv = pg.locator("#envs-spec_preview").inner_text()
            chk("★ 预览里报出了环境名 / Python 版本 / 包个数",
                "scRNA" in pv and "3.11" in pv and "个包" in pv, pv[:200])
            chk("★★ 预览把包名逐个列出来（解析读歪了才看得出来）",
                "scanpy" in pv and "anndata" in pv, pv[:300])
            chk("★ 预览里提醒了「共享」这件事", "共享" in pv, pv[:400])
            chk("★ 好配置时「一键创建」是可点的", pg.locator("#envs-spec_create").count() == 1)

            # ---- ★ 改编辑器 → 预览变 + 坏配置变灰 ----
            pg.fill("#envs-spec_text", "name: myprobe\npython: 3.10\n"
                                       "channels: conda-forge\npackages:\n"
                                       "  - numpy\n  - pandas\n")
            pg.wait_for_timeout(1200)
            pv2 = pg.locator("#envs-spec_preview").inner_text()
            chk("★★ 手改编辑器之后预览跟着变（改一下就要看到解析成什么样）",
                "myprobe" in pv2 and "3.10" in pv2, pv2[:200])
            chk("★ 两个包就报两个包", "2 个包" in pv2, pv2[:200])
            chk("★ 合法名字时按钮还是亮的", pg.locator("#envs-spec_create").count() == 1)

            # 空包清单 → 解析就失败，预览整块换成一句提示，**没有按钮**。
            # （"解析不了"和"解析得了但建不了"是两件事：前者是这份文本本身
            #   读不出东西，后者是名字重了/机器正忙。前者给一句指路的话就够，
            #   摆一个灰按钮反而让人以为点一下能好。）
            pg.fill("#envs-spec_text", "name: myprobe\npython: 3.10\npackages:\n")
            pg.wait_for_timeout(1200)
            lit, grey = create_btn(pg)
            chk("★★ 解析不出包的时候根本没有可点的「一键创建」",
                lit == 0, "lit=%d" % lit)
            pv_bad = pg.locator("#envs-spec_preview").inner_text()
            chk("★★ 而且有一句人话指到 packages: 那一行（只说「不行」等于没说）",
                "packages" in pv_bad, pv_bad[:200])

            # 非法环境名 → 必须变灰
            pg.fill("#envs-spec_text", "name: ../逃逸\npackages:\n  - numpy\n")
            pg.wait_for_timeout(1200)
            lit, grey = create_btn(pg)
            chk("★★ 环境名里带路径时也变灰", lit == 0 and grey >= 1,
                "lit=%d grey=%d" % (lit, grey))
            pv4 = pg.locator("#envs-spec_preview").inner_text()
            chk("★★ 而且说清了是哪一条不合规、去哪一行改"
                "（只说「不行」的话用户只能猜）",
                "环境名不合规" in pv4 and "name:" in pv4, pv4[:300])

            # ---- ★★ 上传文件：GBK ----
            pg.set_input_files("#envs-spec_file", gbk_path)
            pg.wait_for_timeout(2500)
            t2 = editor_text(pg)
            pg.screenshot(path=os.path.join(OUT, "v12_envs_upload_gbk.png"), full_page=True)
            chk("★★★ 上传 GBK 编码的 yaml 之后内容进了编辑器",
                "gbk_probe_env" in t2, t2[:200])
            chk("★★ 中文注释没变成乱码（走了 UTF-8 失败 → GBK 回退那一条路）",
                "这是中文注释" in t2, repr(t2[-80:]))
            chk("★★ 上传进来的每一行都在，没被截断",
                "scanpy" in t2 and "pip:" in t2, t2[-200:])

            # ---- ★★ 上传进来的 conda export 解析得对 ----
            pg.wait_for_timeout(800)
            pv3 = pg.locator("#envs-spec_preview").inner_text()
            chk("★★ 上传的是 conda env export 的输出，也能解析",
                "gbk_probe_env" in pv3, pv3[:200])
            chk("★★ `python=3.10.13` 被认成解释器版本而不是一个叫 python 的包",
                "3.10" in pv3 and " python " not in pv3, pv3[:200])
            chk("★★ 版本号被去掉这件事在预览里**说出来**了",
                "版本" in pv3, pv3[:400])
            chk("★ 解析出来的包名里没有带版本号的残留",
                "numpy=1.26.4" not in pv3 and "scanpy==1.10.0" not in pv3, pv3[:300])
            chk("★ 上传合法配置之后按钮又亮了",
                pg.locator("#envs-spec_create").count() == 1)

        except Exception as e:                       # noqa: BLE001
            pg.screenshot(path=os.path.join(OUT, "v12_envs_error.png"), full_page=True)
            print("异常：%r" % (e,))
            print("页面文字：\n%s" % pg.inner_text("body")[:1500])
            raise
        finally:
            b.close()

    return chk.done()


if __name__ == "__main__":
    sys.exit(main())
