# tests/ui_v15 —— Test_V15 的浏览器验收（论坛页）

## 怎么跑

```bash
# 1. 起一个可丢弃的实例（数据在 /tmp，线上一个字节都不动）
bash tests/ui_v7/make_instance.sh 8918 /tmp/dsapp_v15

# 2. 跑
python3 tests/ui_v15/probe_v15.py        # 退出码 0 = 全绿
```

脚本里的默认值（`URL` = `http://127.0.0.1:8918/`、`APP` = `/tmp/dsapp_v15/app`、
`OUT` = `/tmp/dsapp_ui_v15`，见 `_common.py` 顶上）和上面那条命令是**一套**，
起完直接跑就行，不用设环境变量。

换个目录起实例（比如想每次都从空库开始）就用三个环境变量指过去，
不用改代码：

```bash
bash tests/ui_v7/make_instance.sh 8918 /tmp/dsapp_v15r2
DSAPP_TEST_APP=/tmp/dsapp_v15r2/app DSAPP_TEST_OUT=/tmp/dsapp_ui_v15r2 \
  python3 tests/ui_v15/probe_v15.py
```

> ⚠️⚠️ **起实例时别绕开 `make_instance.sh` 自己 rsync。** 仓库根目录下的
> `.Renviron` 里 `DSAPP_DATA_ROOT` 指的是**线上数据目录**。整目录 rsync 时
> 如果没排除它，实例会**连着生产库**启动 —— 而它照样能起来、照样监听端口，
> 页面上一点异样都没有。手工拷的话：
>
> ```bash
> rsync -a --delete --exclude '.Renviron' --exclude 'data/' --exclude '.git/' \
>   --exclude 'history_Version/' --exclude '*.log' \
>   /data3/biomamba/analysis/DS_App/ /tmp/dsapp_v15/app/
> printf 'DSAPP_DATA_ROOT=/tmp/dsapp_v15/data\n' > /tmp/dsapp_v15/app/.Renviron
> ```
>
> 另有一个反向的坑：`rsync -a --delete R/ <目标>/` 这种**带尾斜杠的多源**写法，
> 会把 `R/` 的**内容**摊进目标根目录，再把目标里其它东西全删掉（`app.R`、
> `www/`、`selftest.R`……）。实例会起不来，报 `App dir must contain either
> app.R or server.R`。源必须是**仓库根**、并且带尾斜杠。

> ⚠️ 实例里 `R/*.R` 只在**进程启动时** source 一次。**改完 R 代码必须重起
> 实例**才看得到 —— 而 `make_instance.sh` 会从仓库重新拷一份（于是变异会被
> 覆盖掉）。这两件事的取舍见下面「变异验证」一节。

> ⚠️ 本探针**不需要**假模型服务，一次模型调用都不发，只量界面 + 点按钮。
> 但它会**真的注册账号、发帖、回帖、点赞、删回复**，所以只能对着 /tmp 那份
> 实例跑：`_common.guard()` 把"指向仓库本身"和"data_root 不在 /tmp 下"直接拦下。

## 这一版只管一件工单

| 工单 | 一句话 | 断言 |
|---|---|---|
| item 8 | 加一个论坛页面，用户能交流经验/问题（并且想清楚同步） | 42 条，见下 |

同步那一半（枢纽是 `users.email`、公共段、`(origin_node, origin_id)`、
软删不留墓碑……）**不在这个探针里** —— 那些是数据层的事，
`selftest.R` 的 V15 那一节直接断言，考据结论写在 `SYNC.md` 第九节。

### 探针回答的六个问题（按重要性排）

1. **列表真的渲染出帖子了吗**（不是"没有报错"）。
   ⚠️ 这不是走过场：写这一页的时候 `dsapp_forum_list()` 的参数绑定漏了一个
   `?`（SELECT 里 `i_liked` 那个子查询排在 WHERE 之前），SQLite 报
   `Query requires 4 params; 3 supplied`，而那句查询在 `tryCatch` 里 ——
   表现是**列表永远是空的、一句报错都没有**，页面画的是"还没有人发帖"。
   自检抓到了它；这里再抓一次，因为它是这一页最贵的坏法。
2. **XSS**：正文里写 `<script>` / `javascript:` / `onerror`，页面上不许有
   任何一个真的生效。论坛是全应用唯一一处"A 写的东西渲染给 B 看"的地方。
3. **两个账号之间的可见性**：甲发的帖，乙**看得到**（这才是"公共"的定义，
   也是 item 8 那句"用户能交流"的最小可验证形态）。
4. 发帖 / 回复 / 点赞 点下去**页面上真的变了**（不是"点了没反应"）。
5. **软删的楼层留在原位**：删掉 1 楼之后，2 楼还是 #2，不许变成 #1。
6. 几何与配色：正文有高度、板块标签有底色 —— 量之前先确认元素可见，
   隐藏元素返回全 0 矩形，拿它做减法得到的数看着完全合理。

### 为什么这几条非要在浏览器里再验一遍

自检已经把**数据层**证到位了：建表、CRUD、软删、LWW、幂等、水位、签名载荷。
浏览器这一边回答的是另外几个问题，它们可以各自单独坏掉而源码级断言全绿：

1. **"函数对了"和"用户看得见"是两件事。** 自检能证明
   `dsapp_forum_mark()` 写进去了、`dsapp_forum_posts()` 返回 3 行 ——
   它证明不了**页面上那颗按钮换了字**、**新楼层画出来了**。
   这一版真栽在这儿：见下面第 4 条。
2. **XSS 只有浏览器知道。** 自检能验 `dsapp_md_html()` 的返回值里没有
   `<script`，但"页面上有没有哪个元素挂上了 `onerror`"是 DOM 的事。
3. **跨账号可见性**要两个 session。自检里两个"账号"是两个 list，
   验不出"乙那个浏览器打开这个页面时看到了什么"。
4. **几何与配色**同理：`renderUI` 崩掉时 Shiny 把**那一整块**换成一句报错，
   表现不是"少了一行"而是"一条都没有"。

## 四个坑（都踩过，别再踩）

**1. ★★★ 发帖/回帖有 10 秒限流，而"被限流"和"界面没接上"长得一模一样。**
`DSAPP_FORUM_COOLDOWN = 10`，按 `author_email` 在 `forum_threads` +
`forum_posts` 里的 `MAX(created_at)` 算。探针要在几秒内连写好几行，于是
**大部分写会被服务端拒掉** —— 楼层没多出来，看着像渲染 bug。

第一版就是这么红的，红的是 `★★★ 删掉的楼层留在原位`（实际只写进去 1 层）。
查库才看出来：少的那些行**压根没进库**，不是没画出来。

对策是这一版加的 `wait_cooldown(email)`（从库里算出还差几秒，等够再点）+
`wait_post(email, body)`（写完**回库确认那一行真的进去了**，没进去就等一轮
再点一次）。**每条写操作后面都要回库确认** —— 判断"写没写进去"不能靠页面。

**2. ★★★ 详情视图当时没读 `bump()`：库里写了，页面上什么都不动。**
`output$body` 的列表那一支通过 `threads()` 间接读了 `bump()`，详情那一支
**谁都没读** —— 而文件头上写着 bump "驱动列表和详情重读"。于是点「有用」
按钮上的字不变、发完回复楼层不出现、作者点「标记已解决」状态不动，
全都只在**退回列表再点进来**之后才看得见。

⚠️ 它**躲过了自检**：那条 `dsapp_forum_mark()` 的断言验的是返回值，绿的。
自检看不见"谁在什么时候重画"。这一版在 `selftest.R` 里补了三条源码级哨兵
（详情必须读 `bump()`、必须**不**读 `tick()`、草稿必须 `isolate`），
但真正的证明仍然只有这个探针。

修的时候连带一处：详情整棵重画会把 `textAreaInput` 里**正在打的字**冲掉
（值只存在于 DOM 里）。所以加了模块级的 `draft`，读的时候 `isolate()` ——
不 isolate 的话每敲一个字重画一次，焦点和光标每敲一下丢一次。

**3. ★★ 楼层号取出来是 `"# 1"` 不是 `"#1"`。**
`span(class = "dsapp-forum-floor-no", "#", label)` —— htmltools 会在两个子节点
之间塞**换行 + 缩进**，浏览器把那段空白折成一个空格。视觉上一样，取出来的
文字多一个空格（复制楼层号也会带上）。改成 `paste0("#", label)` 一个字符串节点。

**4. ★★ 别拿 `innerHTML` 去 grep 一个"应该被转义掉"的东西。**
第一版这条写成 `"onerror" not in body_html`。而转义之后
`<img src=x onerror=...>` 会**原样躺在正文里当文本显示**，grep 一定命中 ——
于是这条永远红。要问的是"有没有哪个元素真的挂上了事件属性"：

```python
page.evaluate("""() => { var bad = [];
  document.querySelectorAll('.dsapp-forum-detail-body *').forEach(function(e){
    for (var i = 0; i < e.attributes.length; i++)
      if (/^on/i.test(e.attributes[i].name)) bad.push(e.tagName); });
  return bad.join(','); }""")
```

另外两条小一点的，同一个病根（**选择器没限定到"那一行"**）：

- `★★ 空列表时给的是「还没有人发帖」`要求实例是**干净的**。对着跑过一轮的
  实例重跑时库里已经有旧帖，这句话不会出现 —— 现在改成走"搜一个不存在的词"
  那一支（同一个 `.dsapp-forum-empty` 元素，只是文案换了）。
- `★ 标签串被拆成了两个`用的是 `.dsapp-forum-row .dsapp-forum-tag`，那是
  **全页所有行的标签总和**。重跑时数出来是 4。现在限定在
  `.dsapp-forum-row` 的第一行里数。

## 这一版做过变异验证

按仓库约定，承重最大的断言反向验过 —— **改坏实例副本**（不是源码，更不是
线上那份）看它会不会红。变异要能生效，重起实例时**不能**从仓库重新拷：

```bash
cat > /tmp/restart8918.sh <<'SH'
OLD="$(ss -ltnp 2>/dev/null | grep ":8918 " | grep -oP 'pid=\K[0-9]+' || true)"
[ -n "${OLD:-}" ] && { kill "$OLD" || true; sleep 2; }
cd /tmp/dsapp_v15/app
R_HOME=/usr/lib/R nohup /usr/lib/R/bin/exec/R -q \
  -e 'shiny::runApp(port = 8918, host = "127.0.0.1", launch.browser = FALSE)' \
  > /tmp/dsapp_v15/app.log 2>&1 &
SH
```

| 变异 | 改哪儿 | 结果 |
|---|---|---|
| A：把 `detail_view()` 里的 `bump()` 删掉（**就是上面第 2 条那个真 bug**）| 实例的 `R/mod_forum.R` | 红 **13** 条，正是"点下去页面没变"那一族：`★★★ 删掉的楼层留在原位`、`★★★ 楼下那一层的号没有移位`、`★★ 点了「有用」之后按钮变成「已标记有用」`、`★★ 乙能回复甲的帖`、`★ 乙那条是 #3`…… ✔ |

> ★ 变异 A 有一条信息量很大的对照：`★★ 回复真的写进库了` 和
> `★ 库里的赞记下来了` **照样全绿** —— 写库那条路是好的，坏的是"写完谁重画"。
> 这两类原因只看数据库是分不开的，这正是浏览器探针存在的理由。

变异做完**从仓库整份拷回去**（直接再跑一次 `make_instance.sh`）再跑一遍。
验收时的实测数：自检 **2851 条全绿**（`EXIT=0`），探针 **42 条全绿**。

## 这一版的自检补了一节

`selftest.R` 里新增 **78** 条（2773 → 2851），是 V15 那一节：

- **数据层**：三张表的建表/索引、`(origin_node, origin_id)` 的行身份、
  软删终态、`views` 不进同步也不算 `updated_at`、点赞的自然主键 + `value=0`
  取消、`LIKE` 通配符转义、排序键两端一致、`deleted` 行是**终态**。
- **同步段**：`forum_at` 一个水位管三张表、`LIMIT max+1` 只用来判"还有没有"
  且不推进水位、包的水位不进 `updated_at`、`forum` **不在** `DSAPP_SYNC_USER_COLS`
  里、签名载荷里两处新增（`req_from_forum` / `forum`）、未来水位取不到东西、
  重发的行是上一次收集的子集（**不是**"取不到" —— `_rewind` 会按
  `DSAPP_SYNC_OVERLAP_SEC` 故意回退，重叠窗口里的行**会**再发一遍，这是
  幂等吸收的设计，不是 bug）。
- **考据题**：`author_uid` / `user_id` 不许出现在同步收集段里（那是本地号，
  发出去对端会认错人）。
- **界面安全面**：`mod_forum.R` 里每一处 `HTML(` 都必须是 `dsapp_md_html()`
  的返回值；管理员判据是 `dsapp_user_is_admin(state$user)`，`state` 里**没有**
  `is_admin` 这个字段。
- **浏览器探针那个 bug 的源码级哨兵**（详情读 `bump()`、不读 `tick()`、
  草稿 `isolate`、楼层号单节点）。

⚠️ 写这一节时连踩两次同一个坑：**扫源码查"不许出现某个写法"时，那个写法
往往正好写在解释"为什么不能这么写"的注释里**（`p.status = 'ok'`、
`state$is_admin`、`该回复已被删除`）。不剥注释的话断言永远红，而且红得毫无
信息量。`v15_forum_src` / `v15_mod_src` 现在都是 `drop_comment_lines()` 之后
再拼的。

⚠️ 顺带说一句剥注释的**副作用**（是好的那种）：它让一条**假绿**露了出来 ——
`★★★ 软删的楼层在列表里保留占位` 原先查的是 `该回复已被删除`，而那个字符串
只存在于 `mod_forum.R` 的**头部注释**里，代码里真正渲染的是 `（该回复已删除）`。
也就是说它一直在验我的设计说明，不是实现。

## 写断言时的两个 R 坑（V14 那版记过，这版又用上了）

- **`strsplit()` 会把结尾那个空字段吃掉**，而 `writeLines()` 写完**会再补一个
  结尾换行**，所以按行比对要显式写 `c(..., "")`。
- **别用 `identical()` 比带中文的字符向量**，它连 `Encoding` 属性一起比
  （`readLines` 读回来的带 UTF-8 标记，拼出来的字面量是 unknown，内容一样也判
  FALSE），`==` 才会先把两边归到同一种编码。

`_common.py` 是共用的：`enter_app()` 建号进应用、`seed_or_die(email)` 拿到
`(uid, db_path)` 并**确认这个实例读的不是线上库**（找不到就硬退出）、
`goto(page, name)` 切页（认 value 也认中文页名，切完回读左栏高亮）、
`pick_select` 走 selectize、`txt()` 取元素文字、`Chk()` 记断言（`.done()` 返回 0/1）。
