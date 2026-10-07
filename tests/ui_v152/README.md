# tests/ui_v152 —— Test_V15.2 的浏览器验收（邮件提醒 + 定时订阅）

## 怎么跑

**要跑两遍**，两遍验的不是同一件事。

```bash
# ---------- 第一遍：裸实例（没配 SMTP）----------
bash tests/ui_v7/make_instance.sh 8922 /tmp/dsapp_v152
python3 tests/ui_v152/probe_v152.py        # 退出码 0 = 全绿

# ---------- 第二遍：加上四个**假**的 SMTP 项 ----------
cat > /tmp/dsapp_v152/app/.Renviron <<'EOF'
DSAPP_DATA_ROOT=/tmp/dsapp_v152/data
DSAPP_SMTP_HOST=127.0.0.1
DSAPP_SMTP_PORT=2525
DSAPP_SMTP_USER=probe@example.com
DSAPP_SMTP_PASS=not-a-real-password
DSAPP_SMTP_FROM=probe@example.com
DSAPP_SMTP_FROM_NAME=言出法随
DSAPP_TZ=Asia/Shanghai
EOF
# 重启实例（make_instance.sh 会把 .Renviron 重写掉，所以要在它之后改）
OLD=$(ss -ltnp | grep ':8922 ' | grep -oP 'pid=\K[0-9]+'); kill "$OLD"; sleep 3
cd /tmp/dsapp_v152/app && R_HOME=/usr/lib/R nohup /usr/lib/R/bin/exec/R -q \
  -e 'shiny::runApp(port = 8922, host = "127.0.0.1", launch.browser = FALSE)' \
  > /tmp/dsapp_v152/app.log 2>&1 &

python3 tests/ui_v152/probe_v152.py
```

第一遍走「降级」分支，第二遍走「配齐」分支。脚本自己读实例的 `.Renviron`
判断该走哪一支，不用设环境变量。想换个目录起实例就用
`DSAPP_TEST_APP` / `DSAPP_TEST_OUT` / `DSAPP_TEST_URL` 指过去。

> ⚠️⚠️ **凭据一个字节都不要抄进来。** 上面那四个 SMTP 项是**假的**，写的是
> `127.0.0.1:2525`（一个没人监听的端口）。界面只判"四个非空"，不会去连它；
> 探针也**故意不点**「发一封测试邮件」和「发这一份」那两颗按钮 ——
> 它们会真的把信投出去。真投递那两条路由 `tests/real_mail.R` /
> `tests/real_notify.R` 负责，凭据从 `.Renviron` 借读，不落第二份副本。
>
> ⚠️ 起实例别绕开 `make_instance.sh` 自己 rsync：仓库根目录那份 `.Renviron`
> 的 `DSAPP_DATA_ROOT` 指的是**线上数据目录**，整个拷过去的话实例会**连着
> 生产库**启动 —— 照样能起来、照样监听端口，页面上一点异样都没有。
> 还有：`rsync -a --delete R/ <目标>/` 这种**带尾斜杠的多源**写法会把实例树铲平。
>
> ⚠️ 实例里 `R/*.R` 只在**进程启动时** source 一次。改完 R 代码必须重起实例。

## 这一版管两件工单

| 工单 | 一句话 | 断言 |
|---|---|---|
| item 1 / 3 | 文献速递页多一张「发到我的邮箱」卡 | 见下 |
| item 2 | 言出法随加「跑完发邮件」勾选框；文献速递页加「定时订阅」卡；设置 → 执行 加一张邮件卡 | 见下 |

- 降级分支 **5 条**
- 配齐分支 **41 条**

### 探针回答的问题（按重要性排）

1. **降级路径：没配 SMTP 时，邮件相关的 UI 必须整个不出现。**
   这是 D4（不加开关、用"配没配齐"判断）在界面上的定义，也是这次唯一
   **新增的一类**断言 —— 以前这个应用没有"某些部署少一整块功能"的情况。
   ⚠️ 判据必须认 **`uiOutput` 那个容器 id**（`#lit-mail_lit_card` /
   `#settings-mail_card_wrap`）是不是空的，不能扫页面文字：bslib 把没选中的
   页也留在 DOM 里，`inner_text("body")` 里混着**别的页**的内容，断"没有
   某句话"时只要任何一页留着那几个字就永远红，断"有某句话"时又可能被别的页
   蒙混过去。
2. **两个入口一份真相。**「言出法随」的勾选框和设置页的勾选框改的是
   **同一个键**（`email_task`）。在一边勾上、切到另一边，那一边必须跟着变；
   反过来在另一边取消，切回来也必须变回来。这是"同一份真相"在界面上的定义，
   只有两个页面**同时活着**才验得出来。
3. **每条写操作后面回库确认。** memory 的 `cooldown-looks-like-broken-ui`：
   界面上的"没反应"和"压根没写进去"长得一模一样。订阅的增 / 删 / 开关
   四条动作，每一条都先回库把值读出来。
4. **空列表时「刷新列表」按钮仍然在。** 它原来跟着下拉一起藏在 `else` 分支
   里，于是空列表时按钮也消失 —— 而空列表恰恰是唯一需要按它的时刻，
   卡上那句"点「刷新列表」再看看"成了一句指向不存在按钮的话。这个账号是
   全新的、一份速递都没有，正好是那一刻。
5. **时区写出来了。**「每天早上 8 点」在 UTC 库里是 0 点。界面上不写时区的话
   用户永远不知道他看到的是哪个 8 点。探针断实例 `.Renviron` 里的
   `DSAPP_TZ` 真的出现在卡面上。
6. **每月 31 号的下次运行落在真实存在的一天。** 纯函数的边界测试在
   `selftest.R` 里，这里只确认**界面上算出来的那个时刻**是合法日期
   （9 月只有 30 天 → 顺延到 9-30）。
7. **几何之外的那一类**：表格每次动作都会重画，`sub_pick` 那个 selectize
   跟着重建。重画之后**还能重新选中** —— 这是"点了没反应"最常见的成因。

### 为什么这几条非要在浏览器里再验一遍

自检和 `tests/v152_*.R` 那八个文件已经把**函数层**证到位了：MIME 字节、
RFC 2047、`next_at` 的全部边界、认领的原子性、偏好键、收尾钩子（含变异）、
假 SMTP 端到端、真 SMTP 投递。浏览器这一边回答的是另外几个问题：

1. **"函数对了"和"用户看得见"是两件事。** R 那边能证明
   `dsapp_litsub_add()` 写进去了、`dsapp_uipref_save()` 存下了 ——
   证明不了表格上多了一行、勾选框跟着变了。
2. **降级路径只有把页面开起来才看得见**，它是 `if` 出来的；源码级断言
   只能说"文件里有个 if"。
3. **两个页面同时活着**才谈得上"两个入口一份真相"。
4. **重画会不会把控件连同状态一起冲掉**，只有真 DOM 说了算。

## 三个坑（都踩过）

**1. ★★★ 「等一行出现」写成了「查得到行」，等于没等。**
第一版用的是

```python
row = wait_row("SELECT ... FROM lit_subs WHERE user_id = ? ORDER BY id DESC")
```

而**这条查询在写之前就已经有结果了**（表里本来就有一条），于是它立刻返回。
后果不只是那一条断言红：紧接着的界面动作会和服务端那次重画**抢跑** ——
`sub_add` 成功之后会 bump `subs_rev`，整张 `sub_table` 连同 `sub_pick`
那个 selectize 一起重建，已经点开的下拉被收回去。报出来的是
「下拉里没有选项」，指向的是完全无关的地方，而库里那第二行其实**建得好好的**。

对策：`wait_new(sql, args, known)` 的判据是"**多了一个不在 `known` 里的
id**"，`wait_val(sql, args, want)` 同理。凡是"查得到行"就算过的等待，
都是假等待。

**2. ★★ `page.inner_text(".dsapp-page")` 量到的是 DOM 里排第一的那一页。**
`.dsapp-page` 在**每个模块**上都有一层（chat / lit / settings / …），而
bslib 把没选中的页也留在 DOM 里。第一版拿它做"确实切到设置页了"的反向断言，
红的是探针不是应用。对策：`vis_text()` —— 只拼**可见**的那些。

**3. ★ `pick_select` 是"点开→找选项→点选项"一条直线，超时 30 秒。**
对**会重画**的下拉不能用：重建会把打开状态收回去。对策：本目录自己的
`pick_sub()`，重试若干轮（点开 → 等一下 → 没有选项就重新点）。

## 日志里会看到的那两条告警

跑完配齐分支之后，`/tmp/dsapp_v152/logs/` 下可能有 `mail-*.err`，内容是
连不上 `127.0.0.1:2525`。那是**预期的**：`dsapp_mail_kick()` 起的排空子进程
真的去连了那个假端口。探针不点发信按钮，所以正常情况下一封都不会入队 ——
真看到了 `mail_queue` 里有行，说明有人手点了发信。

## 这一版的自检/离线测试在别处

| 文件 | 管什么 |
|---|---|
| `selftest.R` 的「V15.2」一节 | MIME 纯函数、`next_at` 边界、`lit_subs` 权限、ref 去重、源码级哨兵 |
| `tests/v152_mail_prefs.R` | 偏好键 + 卡片函数（不经过浏览器） |
| `tests/v152_lit_cards.R` | 两张卡片（`shiny::testServer`，真建 DOM） |
| `tests/v152_task_notify.R` | 收尾钩子 + 假 SMTP 端到端 |
| `tests/v152_closeout_guard.R` | 变异：发信抛错不能把任务收尾带崩 |
| `tests/v152_scheduler.R` | 认领原子性 / 回收 / `run_scheduler.R` 本身 |
| `tests/v152_fake_smtp.R` | 假服务器收到的**字节**对不对 |
| `tests/real_mail.R` | 真 SMTP：文献速递（渲染 + 内联图 + 附件） |
| `tests/real_notify.R` | 真 SMTP：任务成功 / 失败两封信 |
