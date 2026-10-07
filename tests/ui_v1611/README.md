# `ui_v1611` —— Test_V16.11 的浏览器探针

这一版在做的是一件事：**开发服务器时不时断联，页面上的操作要有保障**。
拆成几块，每块一个探针。

| 探针 | 管什么 | 备注 |
|---|---|---|
| `probe_offline.py` | **断线提示怎么出场**（先小条、隔一段时间才铺整页卡片）+「先等一下」那颗按钮按下去到底发生了什么 | 37 条断言；会把实例的 R 进程 `kill -STOP` / `kill -9` |
| `probe_opsink.py` | 写操作的收口点（`Shiny.shinyapp.sendInput` 包装）到底收不收得住 —— **只观测，不拦不排队** | item 2；真正拦下来是 item 4 的事 |
| `probe_tos.py` | 《用户须知》的三档层次在屏幕上真的分得出来（绝对像素值，不是"互不相同"） | item 6 |

跑法都是（它们不能和其他探针共用实例 —— 会打死 R 进程）：

```bash
bash tests/ui_v7/make_instance.sh 8953 /tmp/dsapp_v158h
cp www/app.js www/app.css /tmp/dsapp_v158h/app/www/     # 纯 www/ 改动
python3 tests/ui_v1611/probe_offline.py
```

> ⚠️ `make_instance.sh` 是 **rsync 副本**：实例里的 `www/` 和 `R/` 都停在
> 建实例那一刻。所以每个探针的 P 段都先断言"**正在服务的那份** app.js 里有
> 新符号" —— 不然量的是旧代码，而全绿看起来一模一样。

---

## 断线提示的出场时序（2026-10-07 起，`probe_offline.py` 的现行契约）

用户原话：

> 「服务器现在还是经常未响应，这个提示能不能显示的不要这么频繁，
>   即使真的断了，也请间隔一段时间再提示」

改之前是**一判死就铺盖住整页的卡片**，而判死线只有 16 秒 —— 服务端在跑重活
（渲染报告 / 装包 / 跑模型）时它自己的事件循环就被钉住，心跳自然停，于是用户
被一整页遮罩吓了好几次，而绝大多数情况下它会自己好。

现在是**两档**：

| 时刻 | 屏幕上是 | 依据 |
|---|---|---|
| 判死线到（`DSAPP_PING_DEAD_MS` = **30 秒**没收到心跳） | **只出左下角小条**（`#dsapp-offline-mini`，不遮鼠标、不挡点击） | `dsappOfflineWarn()` |
| 从**离开 up 那一刻**再撑 `DSAPP_OFFLINE_CARD_MS` = **30 秒** | 才铺整页卡片（`#dsapp-offline`） | `dsappOfflineEscalate()` |
| `shiny:disconnected`（socket 真收到 close） | 同样**先小条**；卡片由自愈在 `DSAPP_HEAL_GRACE_MS` = 20 秒后铺（`dsappHealNote`），一句信息都不少 | 那 20 秒里 shiny-server-client 还在替我们重连 |

用户点过「先等一下」（`dsappOfflineDismiss`）之后，**这一轮不再自动铺卡片**
（`dsappCardDismissed`）—— 小条照挂（"还没好"这件事没被这一下点击改变），
状态也一个字不改。

### 本地验不了的两件事（**不装作验过**）

1. **BRC 的 15 秒缓冲 + CONTINUE 去重**（`BufferedResendConnection`）——
   本地实例是 `shiny::runApp` 直接起的，**没有 shiny-server-client**（那是
   Shiny Server 注入的），socket 一断就永远断了。所以"闪断期间点的东西被
   传输层自己补上"这条路，本地没有任何东西能证明它。
   ⇒ 时序上只能靠**代码里的大小关系**保证：判死线(30s) 必须大于 BRC 的重连
   窗口(`reconnectTimeout` 15s)，否则闪断还没轮到传输层自己好，我们就先报了。
   `selftest.R` 里有一条盯着这个大小关系。
2. **`shiny:disconnected` 在线上到底什么时候到**——本地 `kill -9` 是立刻到；
   线上要等 shiny-server-client 把 15 秒重连窗口走完才轮到它。这就是上面
   "先小条"那一条的由来，`probe_heal.py` 的 E 段量的是本地能复现的那一半。

> 顺带：`tests/ui_v1311/probe_freeze.py` 是 V13.11 的逐秒诊断，里面
> 「24 秒内 `#dsapp-offline` 一次都没出现」**不等于"前端没报"** —— 那一刻它
> 多半正挂着小条。那个文件的数字是按当时的行为量的，别拿它当现行契约。
