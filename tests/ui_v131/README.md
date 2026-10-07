# tests/ui_v131 —— V13.1 九项改动的浏览器回归

九项里有四项**只有真的发一次请求才验得出来**：

* item 2（kimi 的 HTTP 400）—— 错在**请求体少了一个字段**，服务端返回
  400 只是它的后果。在应用里断言"没报错"要联网要真 Key，而且换一家厂商
  就换一个错误码。所以这一层不查结果，查**发出去的那份请求体**。
* item 5（Key 记忆）—— "记住"和"这次碰巧填对了"在界面上长得一样。
* item 6（模型自我认知）—— 系统提示词对不对，界面上一个字都看不出来。
* item 1 / 3（跳转链接）—— 链接文字写对了不代表 `href` 对。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（默认 8898）
bash tests/ui_v7/make_instance.sh 8898 /tmp/dsapp_v131test

# 2) 五个脚本，各自独立，可以只跑其中一个
python3 tests/ui_v131/links.py    # item 1 / 3    —— 链接跳向哪
python3 tests/ui_v131/temp.py     # item 2        —— 滑块真的灰掉了吗（界面层）
python3 tests/ui_v131/rename.py   # item 4        —— 对话更名
python3 tests/ui_v131/keys.py     # item 5        —— 切厂商时 Key 带不带出来
python3 tests/ui_v131/wire.py     # item 2 / 5 / 6 —— 抓真实请求体
```

playwright 在本机的 miniconda 里：用 `/home/biomamba/miniconda3/bin/python`，
不是系统的 `python3`。退出码 0 = 全绿。

路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8898/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v131test/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v131`（截图） |

⚠️ `make_instance.sh` 把仓库**拷**到 `/tmp`，不是软链。改完代码要显式重跑
一次它，否则你测的是旧代码 —— 症状是"改了之后测试结果一点没变"。

## ⚠️ 前置条件：这次多了一个 —— `.keyring`

V13.1 item 9 起，API Key 在库里是**密文**，钥匙串是实例的 `data/.keyring`。
`keys.py` 和 `wire.py` 都要往库里塞一个 Key 再让它读出来，所以：

* **实例必须有一个能写的 `data/`**（`make_instance.sh` 起的就是）。
* **不要在两个实例之间共用 `data/`。** 密文是跟着钥匙串走的，A 实例写的密文
  拿到 B 实例去解，`dsapp_sec_dec()` 会**正确地**返回 NULL —— 看起来像
  "Key 没记住"，其实是拿错了钥匙串。
* 想手工造一条密文的话，别自己拼 —— 老明文（不带 `v1:` 前缀）本来就能读
  （`dsapp_sec_dec()` 对老明文是原样返回），测试直接塞明文最省事。

## ⚠️ `wire.py` 会起一个本地假服务商

它在一个**后台线程**里跑 `ThreadingHTTPServer`（`127.0.0.1:<随机端口>`），
把抓到的那份请求体存下来给断言用，然后返回一段合法的 SSE。厂商选 `custom`
（base_url 是四家里唯一由用户填的），把 base_url 指向这个假服务器。

三条要知道的：

1. **它不联网。** 抓的是**应用发出去的**那份字节，不需要真 API Key
   （随便填一串就行），也不会把 Key 发到任何地方 —— 目标就是 127.0.0.1。
2. **端口是随机挑的空闲端口**，跑完就关。别把它写死，并行跑两个会撞。
3. **它验的是"发出去什么"，不是"收到什么"。** 这是刻意的：item 2 的 bug
   在**去**的那一路上（多发了一个字段），服务商的 400 只是回声。

## 这九项分别验的是什么

| item | 用户原话 | 在哪验 |
|---|---|---|
| 1 | 「智谱GLM的官网申请链接用这个跳转」 | `links.py` |
| 2 | 「kimi的api显示可用，但实际的HTTP 400：invalid temperature」 | `temp.py` + `wire.py` |
| 3 | 「字节豆包的跳转链接用这个」 | `links.py` |
| 4 | 「会话需要能够更名」 | `rename.py` |
| 5 | 「填写的api key要有记忆功能，在切换厂商时能直接切换过来」 | `keys.py` + `wire.py` |
| 6 | 「我用DS的模型提问它自己的模型是什么，为什么它总是回复自己的claude」 | `wire.py` |
| 7 | 「取消免密登录这种方式」 | **不在这一层** —— `selftest.R` |
| 8 | 「文件管理区不是全站公开的，这个声明要去掉」 | **不在这一层** —— `selftest.R` |
| 9 | 「API Key、远程服务器密码不会明文存到服务器上」 | **不在这一层** —— `selftest.R` |

item 7 / 8 / 9 没有可点的界面行为：7 是"某个分支还走不走得到"，8 是"源码里
那句话还在不在"，9 是"写进 sqlite 的字节是什么"。三样都在 `selftest.R` 里
钉得更死（免密账号被拒 + 拒绝**不计数**、文案逐句核对、加解密往返、以及
**把钥匙串换掉必须解不开**）。浏览器这一层只补了一条：登录页那句提示真的
渲染出来了。

## 写这几个脚本时踩过的坑（别重复踩）

### 一、Shiny 的 selectize：`maxItems = 1` 会让输入框**变成 4px 宽**

`keys.py` / `wire.py` / `temp.py` 都要在模型下拉里填一个**自定义模型名**。
第一版三个脚本一起红，报的是"模型没换过去"，看着像后端 bug，实际原因在
前端：

* Shiny 的 `selectizeInput` 单选时默认 `maxItems = 1`；
* selectize 的 `isFull()` 是 `maxItems !== null && items.length >= maxItems`，
  选中一项之后它认为"满了"，于是把输入框锁成 **4px 宽**；
* 此后**所有键盘输入被静默丢掉**，`fill()` 也不报错。

修法是 `maxItems = 2, mode = "single"`（`mode = "single"` 才真的限一个值，
`maxItems` 只是把输入解锁）。⚠️ 顺带一个 R 侧的知识点：**`maxItems = NULL`
在 R 里写不出来** —— `list(x = NULL)` 会把元素整个删掉，等价于"没传这个
参数"，而 selectize 的默认值正是 1。

### 二、`set_model_free()` 必须**读回来**

上面那个 bug 之所以难查，是因为测试只"填"不"验"，失败信息指向的是下游
（"请求里的 model 还是 kimi-k3"）。现在这个 helper 填完会读一次，读到的
不是想要的就当场打印实际值 —— **失败信息要指向出错的那一步**。

### 三、不要用 `page.reload()` 轮询一个还没醒的 Shiny 页面

冷启动时应用要重新 source 一遍 `R/*.R`，超过 30 秒很正常，而整个界面是
`renderUI("app_root")` 渲出来的 —— 第一次 flush 之前 `body.innerHTML`
**真的是 0 个字符**。

第一版写了个 2 秒一次的 `reload()` 轮询，结果**制造了一个永久空白页**：
每次 reload 都开一个**新的** Shiny session，上一个还没 flush 完就又有新的
进来，谁也跑不完，日志里一条错都没有。这是自己把自己锁死了。

现在的做法在 `_common.wait_awake()` 里：**只等，不 reload**；等满 60 秒还
没醒才 reload 一次。冷启动实测 60 秒内能醒。

### 四、`#model-temp_ui` 读不到文字

它在一个**收起的** `<details class="dsapp-model-adv">` 里，
`inner_text()` 对不可见元素返回空串 —— 不是 bug，是要先展开。同理
`#model-key_state` 那几条也要先把高级区展开。

### 五、ionRangeSlider 的滑块类名是 `.irs-handle`

**不是 `.irs-slider`。** 拖温度滑块时用错类名，Playwright 会一直等一个
不存在的元素直到超时，报的是"元素不可见"，看不出是类名写错了。

### 六、`textInput` / `textAreaInput` 有 250ms 防抖

填完值直接点按钮，`input$xxx` 还是空的，`req(nzchar(...))` 把这次点击静静
丢掉 —— 用户看到的是"点了没反应，刷新又对了"。中间要
`wait_for_timeout(700~900)`。
