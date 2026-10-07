# tests/ui_v136 —— V13.6 的浏览器回归

V13.6 的四项里有三项是**界面形态**（不折叠 / 灰掉 / 下拉顺序），一项是
**时序**（退出登录之后库被抹空）。这两类都不在离线断言能覆盖的范围里，
所以单独一套。

## 起实例

```bash
bash tests/ui_v7/make_instance.sh 8896 /tmp/dsapp_v136test
```

`_common.py` 的默认值（8896 / `/tmp/dsapp_v136test/app`）和上面这条命令
是一套，起完直接跑脚本就行，不用设任何环境变量。

⚠️ **`.Renviron` 里要额外加一行**，否则 `logout_key.py` 里"异端登录"那一半
会干等 15 秒一次的心跳：

```
DSAPP_LOGIN_POLL_MS=1500
```

（`tests/ui_v11/singlelogin.py` 也是这么干的，见 `R/logins.R` 里那段说明。
`make_instance.sh` 每次都会重写 `.Renviron`，所以**每次同步完代码都要补**。）

## 两个脚本

| 脚本 | 对应 | 为什么必须用真浏览器 |
| --- | --- | --- |
| `logout_key.py` | item 1 | 根因是"整页重载 → websocket 断开 → input 被置 NULL"，离线造不出来 |
| `params.py` | item 2 / 3 / 4 | 折叠、灰度、量程属性、下拉顺序，全是**渲染结果** |

### `logout_key.py`

用户在工单里给了**两个**触发：「退出登录」和「异端登录」。两条的入口完全
不同（一个点按钮走 `session$reload()`，一个被心跳发现走
`window.location.replace()`），所以两条都真的走一遍 —— 只测一条的话，
"它们最后都走同一段保存代码"就只是个假设。

判据是**解密之后**比：V13.1 item 9 起 Key 是密文，而密文带随机 IV，
同一把 Key 写两次得到的字符串完全不同。比长度、比前缀都是假判据 ——
被换成另一把 Key 照样通过。

### `params.py`

三组对照缺一不可：

* moonshot（不支持思考）→ 思考开关**灰着看得见**，且 `#model-thinking` 不存在；
* deepseek（支持思考）→ 同一个开关是**真能点**的。

只测第一组的话，"把思考控件对所有厂商一起掐掉"照样全绿。

## 两个已经踩过的坑

### 一、`temp_state` 那种"数一数有几个灰块"的判据会过期

`tests/ui_v131/temp.py` 里原来用 `#model-temp_ui .dsapp-field-disabled` 的
**个数**当"温度滑块灰没灰"。V13.6 item 2 之后，不支持思考的厂商也会在这块
里渲染**灰掉的思考开关** —— 那也是 `.dsapp-field-disabled`，于是
"qwen 有个灰的思考开关"被读成"qwen 的温度滑块被灰了"，对照组当场变红，
而功能完全正确。

现在那边的判据收紧成 `:has(.js-range-slider)`（灰壳里装着 ionRangeSlider）。
**这类"数个数"的判据每次加新控件都要重新想一遍**，它不是错，是脆。

### 二、selectize 的下拉是**打开时才铺进 DOM** 的

`params.py` 要断言"厂商下拉的第一项是 0daysci"。不点开就读
`.selectize-dropdown .option` 的话 count() 是 0，报出来是"这个下拉是空的"，
而真实原因只是没点开。同理，要读的也得是 `.selectize-dropdown` ——
原生 `<select>` 被 selectize 清空了，照着 `<option>` 读只会读到空。

## 跑完记得看一眼这个

```bash
grep -c '✗' /tmp/dsapp_ui_v136/*.out    # 有失败项的话脚本自己也会说
```

截图落在 `/tmp/dsapp_ui_v136/`（`params.png` / `logout_key.png`）。
