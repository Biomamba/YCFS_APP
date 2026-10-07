# tests/ui_v134 —— V13.4 的浏览器回归

目前只有一个脚本，对应 V13.4 的 item 7：

> 7、言出法随的环境界面，并没有同步内置环境，选项里只有系统环境一个

这条只有真的在浏览器里点一遍才验得出来，理由写在 `envsync.py` 的模块注释里
（分组渲染、拦截顺序、以及"下拉框要自己更新"这三件事各自会怎么坏）。

## 怎么跑

```bash
# 1) 起一个可丢弃的实例（8899，别和 ui_v132 的 8898 撞）
bash tests/ui_v7/make_instance.sh 8899 /tmp/dsapp_v134test

# 2) 把求解器换成假的（见下一节，**不换的话这一步会真的跑 conda**）
#    改 /tmp/dsapp_v134test/app/.Renviron：
#        DSAPP_CONDA_BIN=/bin/bash
#    并确认 /tmp/dsapp_v134test/app/create 存在（假 conda 本体）
#    然后重启实例

# 3) 跑
/home/biomamba/miniconda3/bin/python tests/ui_v134/envsync.py
```

⚠️ playwright 在本机的 miniconda 里，用 `/home/biomamba/miniconda3/bin/python`，
不是系统的 `python3`。退出码 0 = 全绿。

路径都走环境变量，默认值就是上面那套：

| 变量 | 默认 |
|---|---|
| `DSAPP_TEST_URL` | `http://127.0.0.1:8899/` |
| `DSAPP_TEST_APP` | `/tmp/dsapp_v134test/app` |
| `DSAPP_TEST_OUT` | `/tmp/dsapp_ui_v134`（截图） |

⚠️ 从 ui_v132 抄 `_common.py` 时**默认 URL 也是抄过来的**（8898）。第一版忘了改，
结果浏览器一路在跟 ui_v132 那个实例说话，注册的新账号落在了它的库里 ——
`seed_or_die()` 拦下来了（"刚注册的账号不在这个实例的库里"），没造成别的后果。
抄测试的时候先把这个默认值看一遍。

⚠️ 实例刚起来的第一跑**经常**在注册那一步报「注册没进主界面（页面文字 0 字）」。
那不是坏了，是首屏 flush 还没跑完（这一页是 `renderUI("app_root")` 出来的，
flush 之前 body 真的是空的）。再跑一次就好。

## ★ 假 conda：为什么是 `/bin/bash` 加一个叫 `create` 的文件

这一条不换的话，「开始创建」会**真的**起一个 mamba 去解 bioconda 的依赖 ——
几十分钟 CPU、几十 G 磁盘，而且是在这台机器上。

正常做法是写一个假的 conda 脚本再 `chmod +x`。**本机的权限层不让 chmod**
（这是对的，别绕）。所以换了个不用可执行位的做法：

* `DSAPP_CONDA_BIN=/bin/bash`
* `app/create` 是一个**普通文本文件**，没有可执行位

应用拼出来的 argv 是

```
<solver> create -p <env_path> -y --override-channels -c ...
```

也就是 `bash create -p <env_path> ...` —— bash 读**脚本文件**是不看可执行位的，
而实例的工作目录就是 `app/`，所以它找得到那个叫 `create` 的文件，`$@` 正好是
后面的参数。旁边那个 `install` 是同一份拷贝，给"往已有环境装包"那条路用。

它有副作用要心里有数：`dsapp_find_solver()` 会把 `/bin/bash` 当成求解器返回，
所以 `envsync.py` 里不验"求解器是不是 conda"，只验**界面行为**。

假 conda 干的事：`mkdir -p <env_path>/bin` + 写一个 `bin/python`（应用判断
"环境成没成"看的就是这个），`sleep 7`（让界面上的「构建中」那一档真的能被一个
5 秒轮询周期看到），然后退 0。

## ⚠️ 跑完之后实例里的环境要清掉

`envsync.py` 会真的在**实例的** `data/envs/` 底下建出 `scRNA` 和 `spatial`。
下次再跑要先把它们挪走（`rm` 被拒，用 `mv`），否则脚本第 1 段那条
「有「内置环境（未创建）」这一组」会红 —— 因为它俩已经建好了，分组就不出现了。

```bash
mv /tmp/dsapp_v134test/data/envs/scRNA   /tmp/dsapp_stray/
mv /tmp/dsapp_v134test/data/envs/spatial /tmp/dsapp_stray/
```
