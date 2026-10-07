# 在 Windows 上跑（V6 item 6）

> ⚠️ **这份是 V6 的方案评估记录，不是给用户的说明。**
> 表里 A/B/C 三条路都要用户**自己装 R** —— 那是当时的问题。
> 现在发给用户的 Windows 版是**免安装包**（自带 R 运行时，解压双击
> `run_app.bat` 就行，用户什么都不用装），见 `README.md` 的「下载与安装」。
> 想重打那个包看 `desktop/README.md`。
>
> 留在这里是因为下面那些结论仍然成立：为什么"让用户改 .bat 里的路径"
> 不是一条路、便携 R 的方案怎么落地、哪些坑（路径带中文、杀软误报）
> 是 Windows 特有的 —— `desktop/` 那套打包脚本就是照这份评估做出来的。

目标不是"能打开看看"，是用户拿到之后**双击就能用本机 CPU 跑真实计算**。
下面三条路都能达到，按"用户要装什么"从少到多排。

---

## 先看结论

| 方案 | 用户拿到什么 | 用户要装什么 | 现在能不能用 |
|---|---|---|---|
| **A. `run_app.bat`**（已实现） | 一个文件夹 | **R**（一次） | ✅ 立即可用 |
| **B. shinyelectron + bundled** | 一个 `.exe` | 什么都不用 | ⚠️ 可行，但要构建/签名 |
| **C. 便携版 R + 批处理** | 一个文件夹 | 什么都不用 | ✅ 立即可用，体积大 |

**建议先发 A。** 它现在就能用、没有任何构建链、出问题能直接看报错。
想给"完全不想装 R"的用户，再考虑 B 或 C —— 但先读完下面那段"为什么 B 没那么省心"。

原来那套「shiny → vbs → exe」现在没有对口的维护中的工具了，见文末的现状核对。

---

## A. `run_app.bat`（已实现，推荐先用这个）

```
DS_App/
├── run_app.bat      ← 双击这个
├── run_local.R
├── app.R
├── R/
└── www/
```

**用户要做的事：**

1. 装 R：<https://cran.r-project.org/bin/windows/base/>
   安装时**保留默认的"Add R to PATH"**（勾掉的话 `run_app.bat` 找不到 Rscript，
   但脚本会明确提示怎么改）。
2. 第一次启动会提示缺包，装一次：
   ```r
   install.packages(c("shiny","bslib","httr2","callr","processx","DBI",
                      "RSQLite","DT","commonmark","digest","jsonlite"))
   ```
   （国内网络慢就先 `options(repos = c(CRAN = "https://mirrors.tuna.tsinghua.edu.cn/CRAN/"))`）
3. 双击 `run_app.bat`。浏览器自动打开 <http://127.0.0.1:8899/>。
4. **第一次落在注册页** —— V6 起本地和服务器走同一套登录。填完就是管理员，
   **恢复码只显示一次**，让用户抄下来。以后换电脑靠它找回。

关掉那个黑窗口就是停止服务。

### 已经处理掉的 Windows 坑

这些都在 `R/platform.R` 里，改动前请先读那个文件顶上的说明：

| 坑 | 处理 |
|---|---|
| 没有 `/bin/bash`、`ulimit` | `dsapp_has_rlimit()` 返回 FALSE，界面上明说"这台机器没有资源限制" |
| 没有 `/dev/null` | `dsapp_devnull()` 给 `NUL` |
| 没有 `/usr/bin/setsid` | `dsapp_setsid_path()` 返回 NULL，远程那一路降级（建议用密钥而不是密码） |
| 普通用户建不了软链 | `dsapp_place_input()` 降级成复制 + 只读属性 |
| `python3.exe` 不存在 | 解释器探测按平台走 |
| `.bat` 里的中文变乱码 | `run_app.bat` **全 ASCII + CRLF**，所有中文提示都从 `run_local.R` 出 |

⚠️ **`.bat` 必须保持 ASCII-only。** cmd.exe 按 OEM 代码页读 `.bat`，
文件里写中文在多数机器上是乱码，而且 `chcp 65001` 救不了**已经解析过**的行。
要在启动时加中文提示，加到 `run_local.R` 里。

⚠️ **Windows 上没有资源限制。** 这不是没做，是做不到：Job Object 那套 R 里没有
绑定，`processx` 也没暴露。所以 Windows 上的代码是以用户自己的账号权限裸跑的。
用户在有这个能力的机器上跑别人的代码之前应该知道这件事 —— `dsapp_platform_note()`
会把这句话显示在界面上。

---

## B. shinyelectron（要真正的 `.exe` 时）

`shinyelectron` 把 Shiny 应用包成 Electron 桌面应用，产出 `.exe`。
**2026-09-14 直接从 CRAN 核对过：`shinyelectron` 0.2.1 在线**
（`available.packages()` 查到的，不是道听途说）。

```r
install.packages("shinyelectron")
library(shinyelectron)
sitrep_shinyelectron()   # 先体检：Node / npm / 构建工具齐不齐
export(appdir = "C:/path/to/DS_App", destdir = "C:/out", platform = "win")
```

### ⚠️ 必须先读这四条

1. **运行时策略只能选 `bundled`，别用默认的 `shinylive`。**
   默认那个把 R 编成 WebAssembly 在浏览器里跑 —— **没有真正的文件系统、
   起不了子进程**，而这个应用的全部价值就是"模型写代码、本机执行"。
   选错的表现是"界面能开、一执行就报错"，而且报得很难懂。
   `bundled` 会带上 R 运行时，用户什么都不用装，代价是体积。
   相关策略对比见包文档：`shinylive` / `bundled` / `auto-download` / `system` / `container`。

2. **作者的自我定位是"原型/实验性"，不建议用于生产。**
   包文档里写得很清楚。发之前自己完整走一遍所有功能，别只验"能打开"。

3. **构建机要装 Node.js（≥22）和 Visual Studio Build Tools。**
   是在**你的**机器上装，不是用户的。`install_nodejs()` 能免管理员装 Node。

4. **不签名的话用户第一次打开会看到 SmartScreen 蓝屏警告**
   （"Windows 已保护你的电脑" → 更多信息 → 仍要运行）。
   想去掉得买代码签名证书，是笔持续开销。**要么签名，要么在说明书里
   写清这一步** —— 否则用户到这一步就放弃了。

### 和这个应用的额外冲突

- **数据目录**：`run_local.R` 默认落在应用目录下的 `data/`。打包成 `.exe`
  之后应用目录在 Program Files 里，**那里不可写**。要么设
  `DSAPP_DATA_ROOT` 指到 `%USERPROFILE%\DS_App`，要么在 `run_local.R` 里
  按平台改默认值 —— **别不改就发**，症状是"启动即报错，说数据目录建不了"。
- **执行引擎起的子进程**：Electron 里跑 R 子进程本身没问题，但
  Electron 崩溃时可能留下僵尸 R 进程（这是 Electron 打包 R 应用的已知问题）。

---

## C. 便携版 R（不想让用户装 R，又不想碰 Electron）

把 R 的 Windows 便携版（Portable R）解压进应用目录，`run_app.bat` 里把
`Rscript` 指向它，连同 `library/` 里预装好的依赖包一起打包。

- 优点：不依赖 Node / VS Build Tools / 代码签名，双击即用，和 A 的代码路径**完全一致**（所以 A 测过的，C 一定也对）。
- 缺点：几百 MB；R 的便携版是社区维护的，要自己确认版本。

适合"用户是实验室里不装软件的同事"这种场景。

---

## 现状核对（2026-09-14）

用户提到以前用「shiny → vbs → exe」。那条路上现在的工具状况：

| 工具 | 状态 |
|---|---|
| **RInno** | ❌ **已从 CRAN 下架（2025）**，作者标记 Unsupported。有 issue 报告它找不到现代 R 版本、Node 下载也失败。**不要再用。** |
| **electricShine** | ❌ 已停更 |
| **shinyelectron** | ⚠️ 在线（0.2.1），但作者标注实验性 —— 见上面 B |
| **DesktopDeployR** | 可用的框架，本质是 C 那一路的自动化 |

也就是说：**当年那条链上的现成工具基本都死了**，现在没有既成熟又免构建的
"一键转 exe"。这就是为什么上面把 A 排在第一位 —— 它在今天是真的能用，
而 B 需要你先接受它的实验性和签名成本。

---

## 测试

Windows 相关的判断集中在 `R/platform.R`，自检里有对应的断言
（`Rscript selftest.R`，不需要 Windows 机器也能跑 —— 断言查的是
"分支有没有写对"，不是"在这台机器上走没走对"）。

`.bat` 的 ASCII-only 约束也有断言盯着：有人往 `run_app.bat` 里写中文，
自检会红。

⚠️ **本机是 Linux，我没有在真 Windows 上跑过。** 上面这些是照 Windows 的
平台差异逐条写 + 逐条加断言的，不是实测结论。第一次发给用户之前，
**请在一台真 Windows 上从零走一遍**（装 R → 装包 → 双击 → 注册 → 跑一段
R 代码 → 看产物），把结果告诉我，我再改这份文档。
