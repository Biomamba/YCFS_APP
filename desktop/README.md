# Windows 桌面版打包（V13.2 item 1）

用户的原话是：

> 现有这个.bat不行，还要windows固定路径下的R存在才能生效，能不能走预制的APP或环境在.bat里？或者shinyelectron能实现的话直接走这条路

问的是同一个问题的两条路，这里两条都做了，**但只有第一条是现在就能发货的**。

| | 免安装包（`build_windows_bundle.sh`） | 单文件 exe（`build_exe.R`） |
|---|---|---|
| 用户拿到什么 | 一个文件夹，解压后双击 `run_app.bat` | 一个 `.exe`，双击就是独立窗口 |
| 用户要不要装 R | 不要（便携 R 已在包内） | 不要（同样在包内） |
| 现在能不能出 | **能**，在这台 Linux 上就能组装 | **不能**，见下面「为什么」 |
| 体积 | ~100 MB（压缩后） | 200 MB 起（多了 Electron 内核） |
| 杀毒误报 | 基本没有 | 没有签名证书时**大概率有** |
| 出错时用户看得见什么 | 黑窗口里的全部日志 | 什么都没有，要去 `%APPDATA%` 捞日志 |

**结论：先发免安装包。** exe 那条路等有一台 Windows 机器（或者装上 wine）再走，
套件已经备好了。

---

## 一、免安装包（现在就能用）

```bash
bash desktop/build_windows_bundle.sh [输出目录]     # 默认 ~/dsapp_build
```

产出 `~/dsapp_build/DS_App-Windows-<版本>.zip`。过程是：

1. 下载便携版 Windows R 4.4.3（约 110 MB，`portable-r` 项目发布的现成压缩包）；
2. 从 CRAN 的 `bin/windows/contrib/4.4/` 拉**预编译好的** Windows 包，解压进
   `runtime/R/library`（见 `fetch_win_pkgs.R` —— 里面解释了为什么不能用
   `install.packages(type="win.binary")`）；
3. **把应用本体编成字节码**（V16.6 起：`app.R` + `R/*.R` → `app.rds` +
   `lib.rds`，包里**没有 `R/` 目录**了，见 `build_bytecode.R`）；
4. 平铺复制其余文件（`run_local.R`、`run_app.bat`、`www/`、`skills_builtin/`）；
5. 自检 30 多条，全过才压缩。

全程不需要 Windows、不需要 wine、不需要编译器 —— 只是下载和解压。
跑过一次之后 `~/dsapp_build/dl/` 里有缓存，再跑会快很多。

**改了应用代码之后重新跑一遍就行**，脚本是幂等的。

### 包内布局（别改成 `app/` 子目录）

```
DS_App-Windows-16.6.0/
  run_app.bat          ← 用户双击这个
  run_local.R
  app.R                ← 十几行的加载器（正文不在这里）
  app.rds  lib.rds     ← 应用正文的字节码；**没有 R/ 目录**
  built_with_R.txt     ← 编译用的 R 版本，加载器拿它对指纹
  www/  skills_builtin/  ← 前端和内置技能仍是明文（是数据，不是代码）
  runtime/R/           ← 便携 R + 全部依赖包
  HOWTO-Windows.txt
  data/                ← 第一次启动时自己建
```

⚠️ **「不再是明文」≠「看不到源码」。** R 的字节码里原样留着 AST（R 自己要
拿它做 `deparse`/`print`），`readRDS()` + `deparse()` 就能拿回逐字一样的函数体
—— 实测过。这个包的用处是「没有一坨 `.R` 可以随手翻」+「启动时不用再解析
编译」（顺带消掉 V15.10 那个 JIT 卡顿），**不是保密**。要真保密只能不跑 R，
那是另一个项目。详见 `build_bytecode.R` 顶上那张实测表。

`run_local.R` 是用 `--file=` 反推应用目录的，也就是「`run_local.R` 在哪，
`runtime/` 就得在哪」。把应用塞进 `app/` 子目录、`runtime/` 留在外面的话，
它会去找 `app/runtime/R/bin/Rscript.exe`，找不到，然后退回机器上的系统 R ——
**正好就是用户抱怨的那个行为**。自检里有一条专门钉这个。

---

## 一之二、macOS 免安装包（V16.6 item 5）

```bash
bash desktop/build_macos_bundle.sh [输出目录] [arm64|x86_64]   # 默认 arm64
```

产出 `~/dsapp_build/DS_App-macOS-<arch>-<版本>.zip`。流程和 Windows 那份**逐条
对应**（连变量名都一样），但四处必须不同，每一处都是坑：

| | Windows | macOS |
|---|---|---|
| 启动器 | `run_app.bat`，**CRLF + 纯 ASCII** | `run_app.command`，**LF + 必须有可执行位** |
| 包格式 | CRAN 的 `.zip` | CRAN 的 `.tgz`，解出来是 `libs/*.so` |
| 架构 | 只有 x64 | **arm64 / x86_64 是两份不同的 CRAN 仓库**，拿错=用户那边 `incompatible architecture` |
| 打包 | `zip -qr` | `zip -qry` —— **`-y` 不能省**：不加会把运行时里的符号链接解引用成副本 |

自检里有一条**验回**：打完 zip 再解开一遍，确认可执行位和 19 个符号链接都还在。
zip 的权限位/符号链接是"打的时候对、解的时候丢"的经典事故，而 mac 上启动器
少了可执行位就是双击打不开。

⚠️ **必须在 Mac 上打**（虽然组装本身在 Linux 上也跑得通 —— 已验证）。
⚠️ **没有签名/公证**，用户第一次打开会被 Gatekeeper 拦。这不是 bug，是没买
苹果开发者证书；`HOWTO-macOS.txt` 第二节专门写了三种绕过办法。
⚠️ 这是**单架构**包，要 universal 得下两个架构再 `lipo`，本版不做。

### macOS 那份的验收清单（有 Mac 之后逐条走）

- [ ] 双击 `run_app.command`，Gatekeeper 拦 → 右键→打开 → 能起来
- [ ] 终端窗口里**第一行就是「应用目录」**（不是 `NULL`、不是 `<environment>`）
- [ ] 浏览器自动打开，界面中文不乱码
- [ ] 跑一个 R 任务能出结果（这条会顺带验 `dsapp_utf8_locale()`：
      macOS 没有 `C.UTF-8`，改之前 R 子进程会因 `LC_ALL` 设不上而报错）
- [ ] 「配额与资源」页面能显示磁盘占用（验 `du` —— BSD `du` 没有 `-b`）
- [ ] Intel 机器上跑一次 x86_64 那个包
- [ ] 在一台**没装过 R** 的干净 Mac 上再走一遍上面全部

---

## 二、单文件 exe（套件已备好，但在这台机器上跑不了）

```bash
Rscript desktop/build_exe.R [输出目录]
```

### 为什么在这台机器上不行

都是实测的，不是推测的：

1. ~~Node 版本不够。~~ **这条已经解决了。** `shinyelectron` 0.2.1 要
   Node.js >= 22、npm >= 11.5，而系统 PATH 里那份是 node v12.4.0 / npm 6.9.0。
   已经装了一份独占的：
   ```bash
   PATH=/home/biomamba/dsapp_build/nodeenv/bin:$PATH    # node 26.8.2 / npm 11.19.1
   ```
2. **交叉编译 Windows 要 wine。** electron-builder 往 exe 里塞图标和版本信息
   用的是 `rcedit`（一个 Windows 程序）。这台机器没有 wine，conda-forge 的
   linux-64 也没有（只有个同名的 `untwine`，不是一回事）。
   **这是现在唯一的拦路虎。**
3. **连"先在本地打个 Linux 版验证流程"都做不到。** `bundled` 策略要下便携版
   R，而 shinyelectron 的源码里 Linux 那条路是直接 abort 的
   （`Portable R for Linux is not yet supported`）。

也就是说：**只要有 wine（`sudo apt install wine64`）或者换一台 Windows 机器，
这条路当场就通。** `build_exe.R` 开头会自己把这几条查一遍，**当场停下来说明白**，
而不是跑到一半甩一句 electron-builder 的英文栈。加 `--force` 可以硬闯。

### 换到能打的机器上之后

```bash
# Windows 机器（推荐，原生打包不用 wine）
winget install OpenJS.NodeJS          # 或者去 nodejs.org 下 22+
install.packages("shinyelectron")
Rscript desktop/build_exe.R
```

Linux 上要交叉编译的话先 `sudo apt install wine64`，再把 Node 升到 22。

### 关键设置（改错了会得到一个"能打开但一用就废"的包）

- `runtime_strategy = "bundled"`。**默认值是 `shinylive`** —— 那是把 R 编译成
  WebAssembly 在浏览器里跑，而这个应用要读写文件系统、要起子进程跑 R/Python
  任务、要连 ssh，WASM 里一样都做不到。设错的症状很隐蔽：包能打开、界面能
  看见，一用就废。
- `platform = "win"`（不是 `"windows"`，源码里 `switch` 的是 `win`/`mac`/`linux`）。
- 图标必须是 `.ico`，Windows 那份要含 256×256 那一档。

### `build_exe.R` 里那两个"防泄密"的地方

`export()` 会把 `appdir` **整个**拷进安装包，所以脚本**从来不把仓库目录交给它**
（见 `desktop/_shinyelectron.yml` 顶部那段说明）：它先往临时目录里放一份只含
`app.R`、`R/`、`www/`、`skills_builtin/` 的干净副本，然后检查副本里有没有
`data/`、`history_Version/`、`.Renviron`，有就当场停下。
仓库里的 `data/` 是开发库 —— 真实账号、加密 API Key 的密钥文件、所有人的
对话工作区。打进安装包发出去不是"包大了点"。

---

## 三、`app.ico` 怎么来的

仓库里只有 `data/logo/头像logo2026.09.jpg`（1280×1280）。`.ico` 是这么生成的：

```bash
python3 - <<'PY'
from PIL import Image
src = Image.open("data/logo/头像logo2026.09.jpg").convert("RGBA")
src.save("desktop/app.ico", format="ICO",
         sizes=[(256,256),(128,128),(64,64),(48,48),(32,32),(16,16)])
PY
```

要换图标就改上面这段重跑一次。**256×256 那一档不能省** —— electron-builder
会拿它生成安装包用的图。

---

## 四、发出去之前，在真 Windows 上过一遍这张表

> ⚠️ 我**没有 Windows 机器**。这两个产物是"组装正确、自检全过"，不是"我跑过"。
> 下面每一条都是"这条不过的话用户当场就废了"，请一条条走。

### 免安装包

- [ ] 解压到**带中文和空格的路径**（比如 `D:\我的 软件\DS_App\`），双击 `run_app.bat`
- [ ] 黑窗口里出现「应用目录 / 数据目录」两行，且数据目录在解压出来的文件夹里
- [ ] 浏览器自动打开 `http://127.0.0.1:8899/`，落在**注册**页
- [ ] 注册一个账号 → 记下恢复码 → **关掉黑窗口 → 重新双击** → 能用同一个账号登录（数据落盘了）
- [ ] 新建一个对话，让模型跑一段 R（比如 `print(1+1)`），**能出结果**（自带运行时接上了）
- [ ] 「文件管理」里上传一个中文名的 csv，能预览
- [ ] 技能库里能看到内置技能，能展开成文件夹形态
- [ ] 把这台机器上装的 R **卸载掉或者改名**再试一遍（证明它真的没用系统 R）
- [ ] 杀掉黑窗口 = 服务停掉；再双击能起来（端口没被占死）

### 只读位置（这是 item 1 想解决的核心场景之一）

- [ ] 把整个文件夹放进 `C:\Program Files\` 下面，双击 —— 应该提示「应用目录写不进去」
      并把数据改放到 `%LOCALAPPDATA%\DS_App\data`，**而不是**报"数据库坏了"
- [ ] 从只读的 U 盘/网盘直接双击，同上

### 单文件 exe（等有了再走）

- [ ] 双击能起来，**不是一闪而过**
- [ ] 窗口标题、界面中文没有乱码
- [ ] 注册 → 关掉 → 重开，账号还在
- [ ] 跑一个 R 任务能出结果
- [ ] 杀毒软件不拦（没签名时这条最容易出问题）
- [ ] 在一台**没装过 R** 的干净 Windows 上再走一遍上面全部

---

## 五、已知的坑

- **便携 R 的版本要和 `contrib` 的版本对齐** —— 但**方向是"运行时不能比包旧"**，
  不是"必须逐字相同"。`DSAPP_RUNTIME_RVER=4.4.3` ↔ `bin/windows|macosx/.../contrib/4.4`
  （minor 必须一致）。CRAN 是**陆续**重编的，同一个仓库里 4.4.0/4.4.1/4.4.2/4.4.3
  混着，所以"每个包都等于运行时"这条**永远不可能成立**。
  真实规则来自 R 自己（`base::library` 里的 `testRversion`）：
  `if (R_version_built_under > current) warning(...)` —— **只有包比 R 新才吭声**，
  包比 R 旧完全静默。实测（R 4.4.2，改 `Meta/package.rds` 的 `Built` 一位一位试）：
  4.3.9/4.4.0/4.4.1/4.4.2 无警告，4.4.3/4.5.0 才警告。
  ⚠️ 2026-10-05 之前这里是 `4.4.2`，而 CRAN 当时已经全部改用 4.4.3 编 ——
  两个平台的包都会在用户机器上滚一屏 "was built under R version 4.4.3"。
  自检里那条"Built 分布"就是钉这个的。
- **字节码比到 R 的 minor，不比 patch。** 打包机是 4.4.2、运行时是 4.4.3 是
  **正常且验证过**的组合（`bytecode_app.R` 里有实测记录：4.4.2 打的 `lib.rds`
  在 4.4.3 里 `readRDS` 无警告、`BODY` 仍是 `BCODESXP`、结果一致）。
  ⚠️ 加载器里那个 `key()` **必须先把 `strsplit` 出来的空串滤掉再取两位** ——
  `"R version 4.4.2"` 按非数字切分的第 1 个元素是空串，直接 `[1:2]` 得到的是
  `".4"`，**谁来了都一样**，闸门等于不存在。
- **`run_app.bat` 必须是 CRLF、必须纯 ASCII。** cmd.exe 按字节偏移找 `goto`
  的标签，纯 LF 会出现"跳到半行中间"这种不报错的怪事；中文会按 OEM 代码页
  变成乱码（文件里再写 `chcp 65001` 也救不了已经解析过的行）。所以所有给用户
  看的中文都在 `run_local.R` 里打印。自检有三条钉这个。
- **不要往分发包里塞 `.Renviron` 的 `DSAPP_DATA_ROOT`。** 写了就把数据钉死在
  打包机的路径上。
- **`zip` 的时间戳。** `zip -qr` 保留源文件时间，便携 R 里那些 2024 年的文件
  会让包看起来很旧，这是正常的。
