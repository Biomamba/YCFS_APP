# cloud_tool/ —— 配套脚本的**替换位**

这个目录是**约定位置**，不是代码。找脚本的规则在 `R/cloudtool.R` 的
`dsapp_cloud_eval_script()` 里，它按顺序找这**四**个地方：

1. `$DSAPP_CLOUD_SCRIPT_DIR/evaluate_rf3.py`（运维放的，优先级最高）
2. `<应用目录>/tools/Protein_Design/evaluate_rf3.py` —— **正本在这里**，
   跟着仓库走（也进版本归档）
3. **本目录** `cloud_tool/evaluate_rf3.py`
4. `<应用目录>/script/evaluate_rf3.py`

要换一份自己的 `evaluate_rf3.py`，放进**本目录**（或者设
`DSAPP_CLOUD_SCRIPT_DIR`）就会盖过仓库里那份 —— 不必改仓库。

找不到时界面会在**点按钮之前**的体检里明说缺什么、该放哪儿（见
`dsapp_cloud_preflight()`），不会等跑了几分钟才炸。

> 目录里**不要**放第三方教学材料（那份教学 HTML 有版权顾虑，也不该占
> 半个仓库的体积）。提取出来的规格已经写在 `R/cloudtool.R` 的注释里了。
