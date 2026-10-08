# tests/ui_v172 —— 浏览器 / R 侧验收（Test_V17.2）

V17.2 是用户报的四条（都改到了源码），加上两条交付层面的（别把画外音推上
GitHub、桌面版要真安装包）。四条源码改动各自都有一条"函数对了但用户那儿不对"
的路，只有真跑一遍才量得到：

| 项 | 用户原话 | 修在哪 | 这一版的探针 | 条数 |
|---|---|---|---|---|
| item 1 | 「Biomamba_ceshi账号下，会话删除后，文件页面的文件还存在」 | `R/db.R` + `R/files.R`（`dsapp_session_files_purge`） | `t_session_files_purge.R` | **27 条** |
| item 2 | 「跳转到历史消息后，往下拉，没有最新消息的刷新提示」 | `www/app.css` + `www/app.js` + `R/mod_chat.R`（`.dsapp-newmsg` 药丸 / `.dsapp-hist-focus` 吸顶） | `probe_newmsg.py` | 见脚本 |
| item 3 | 「当前系统是否支持跨会话识别文件、上下文？如果不能，我希望做到」 | `R/prompts.R`（`build_file_section` 加来源标记 + 跨会话索引）、`R/db.R`（`dsapp_conv_index`） | `t_cross_session.R` | **26 条** |
| item 4 | 「自动纠错似乎没能正常运行，即使我挂载了『长任务无人值守编排』…这类任务 100% 不需要用户确认」 | `R/detach.R`（挂机档位真去跑自动纠错）、`R/envfix.R`（停止判据只留一处定义） | `t_autofix_unattended.R` | **25 条** |

## 怎么跑

```bash
# 1) 起一个隔离实例（**一律走这个脚本**，别手工 rsync）
bash tests/ui_v7/make_instance.sh 8984 /tmp/dsapp_v172a

# 2) R 侧：三条都不用浏览器，直接对着 /tmp 的数据根跑
Rscript --no-environ tests/ui_v172/t_session_files_purge.R .     # item 1
Rscript --no-environ tests/ui_v172/t_cross_session.R .           # item 3
Rscript --no-environ tests/ui_v172/t_autofix_unattended.R .      # item 4

# 3) 浏览器侧：item 2
/home/biomamba/miniconda3/bin/python tests/ui_v172/probe_newmsg.py

# 4) 静态约定（三条新断言组就在里面）
Rscript --no-environ selftest.R

# 5) ★ 上线之后跑：线上是不是这一版
/home/biomamba/miniconda3/bin/python tests/ui_v17/verify_live.py
```

退出码 0 = 全绿。实例目录 `/tmp/dsapp_v172a/app`、数据根
`/tmp/dsapp_v172a/app/data`、探针截图在 `/tmp/dsapp_ui_v172`。

## 这一版踩到的、下次别忘了的

- ⚠️ **起实例一律走 `make_instance.sh`。** 仓库根那份 `.Renviron` 会把一个
  `/tmp` 实例**接到生产库**上，全程不报错、界面无异常（`instance-rsync-traps`
  那条账）。三个 R 脚本都在 `source()` 之后**自查**
  `startsWith(cfg$data_root, "/tmp/")`，红了立刻停 —— 别把那条守卫删了。
- ⚠️ **实例是单进程 `shiny::runApp`**，所以"改 `R/*.R` 要换代"在这里的形态是
  **整个进程重启**。改完 `R/*.R` 要重跑一次 `make_instance.sh`（它会先 kill
  旧实例），只 `page.reload()` 不够。`www/` 那半边刷新就生效。
- ⚠️ **item 2 的两条判据都必须能自己证伪**，否则量了等于没量：
  - 「药丸出现了」不是判据 —— 静态 DOM 里它**一直都在**（`display:none` 藏着），
    只看"在不在"永远绿。所以同时量 `display` 的计算值和 `.is-new` 的切换。
  - 「横条有 `position: sticky`」也不是判据 —— V17.2 之前它就写着 sticky，
    只是写在**里层 div** 上，而 sticky 的偏移被限制在包含块里；那个壳
    （`uiOutput` 渲染出来的 `.shiny-html-output`，`display: contents`）不生成
    盒子 ⇒ 横条一格都挪不动。判据是**滚动 300px 之后横条动了多少**。
- ⚠️ **item 3 的夹具要盯"归属"**：A 对话的产物**不能**发进 B 的文件夹，否则
  `prov()` 会把 B 的那批也算成 A 的，断言会"通过"但量的根本不是那件事。
- ⚠️ **item 4 的对照组在 `R/detach.R` 的 `mode` 上**：那次事故（uid=11 任务
  #576）落库的是 `mode = "finish"`，归 `.dsapp_task_sitter_worker`；而"全停"
  那一档本来就是设计如此。判据要把**三档**分开量，别拿 `full` 的行为去要求
  `off`。

## 变异

这一版没有单独的 `mut_*.py`：三条 R 脚本里**每一组都自带反证/阴性对照**
（比如 item 1 的「顺序反了就是删不掉」、item 3 的「查不到索引时提示词照样
拼得出来」、item 4 的「同一份 err_body 喂给停止判据要判成 stop」），跑一遍
就等于把尺子对着"该红的输入"验了一次。`selftest.R` 那三条新断言组里也各带
一条"抠不到就是空串、下面会静默全绿"的前置断言。
