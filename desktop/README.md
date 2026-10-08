# Windows / macOS 桌面版打包（V13.2 item 1，V16.11 起走 CI）

用户的原话是（V13.2）：

> 现有这个.bat不行，还要windows固定路径下的R存在才能生效，能不能走预制的APP或环境在.bat里？或者shinyelectron能实现的话直接走这条路

V16.11 item 6 用户又提了一次，这次说得更直白：

> 你的桌面版并不是真正的免安装版，还是需要运行脚本，我需要的是比如windows下就打包成.exe，MacOS就打包成对应的.app这样

⇒ **两条路现在都是通的，而且 exe / .app 是主路**，但只有 zip 那条能在这台
Linux 打包机上**本地**打出来。exe / .app 走 GitHub Actions（`.github/workflows/desktop.yml`），
跑在**真的 Windows** 和**真的 macOS** runner 上，产物挂在 Release 里。

| | 免安装包（`build_*_bundle.sh`） | 安装包 `.exe` / `.app`（`build_exe.R`） |
|---|---|---|
| 用户拿到什么 | 一个文件夹，解压后双击 `run_app.bat` / `run_app.command` | `.exe`：双击安装，开始菜单里多一个 DS_App<br>`.app`：拖进「应用程序」，双击就开 |
| 用户要不要装 R | 不要（便携 R 已在包内） | 不要（同样在包内） |
| 在哪打 | **这台 Linux 上就能组装** | **只能在 CI 上打**（要真 Windows / 真 macOS） |
| 本机命令 | `bash desktop/build_windows_bundle.sh` | 本机**打不了**，见第二节 |
| 体积 | ~150 MB（压缩后） | 240~280 MB |
| 杀毒误报 | 基本没有 | 没有签名证书时**大概率有** |
| 出错时用户看得见什么 | 黑窗口里的全部日志 | 什么都没有，要去 `%APPDATA%` 捞日志 |

**结论：发给用户的是安装包（`.exe` / `.dmg` 里的 `.app`）。** 免安装 zip 留作
"不能装软件 / 要放 U 盘带走"的备选，两份都挂在同一个 Release 上。

⚠️ **这两个产物我只验到"结构对"**（见第六节那张实测表：`.exe` 头是 `MZ`+`PE\0\0`、
`.dmg` 尾是 UDIF 的 `koly`），**没有在真的 Windows / Mac 上双击过** ——
这台机器两个都没有。真机验收清单在第四节，那几条请务必走一遍。

---

## 一、免安装包（本机就能打）

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

## 二、安装包 `.exe` / `.app`（走 CI，本机打不了）

```bash
Rscript desktop/build_exe.R --plat=win --arch=x64 [输出目录]   # 本机会当场停下
Rscript desktop/build_exe.R --plat=mac --arch=arm64 [输出目录]
```

### 怎么出这两个包：推上去，让 GitHub 打

`.github/workflows/desktop.yml` 有四个打包 job + 一个发 Release 的 job：

| job | runner | 产出 |
|---|---|---|
| `win-bundle` | ubuntu | `DS_App-Windows-<版本>.zip`（免安装） |
| `win-exe` | **windows-latest** | `ds-app.Setup.<版本>.exe` ← NSIS 安装包 |
| `mac-bundle` | macos-14 / macos-15-intel | 两个 `DS_App-macOS-*.zip`（免安装） |
| `mac-app` | 同上 | `ds-app-<版本>.dmg`（里面是 `DS_App.app`） |

两条触发路径：

1. **打标签**：`git push origin v17.2` （`on.push.tags: v*`）⇒ 打完之后**一定**发 Release。
2. **手动**：Actions → desktop → Run workflow → 填 `release_tag`（比如 `Test_V17.2`）。
   留空只上传 artifact，**不建 Release**。

⚠️ **artifact 要登录才能下**（公开仓库也一样），Release 附件才是公开的 ——
发给用户的链接只能是 Release。

⚠️ **CI 是从 GitHub 上那份源码打的**，不是从工作目录。本机改完不推上去，
打出来的还是旧版本。

### 为什么在这台仓库机器上跑不了

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
3. **mac 目标在非 macOS 上直接拒绝**：dmg 要 `hdiutil`、签名要 `codesign`，
   都是系统自带、没有替代实现。
4. **连"先在本地打个 Linux 版验证流程"都做不到。** `bundled` 策略要下便携版
   R，而 shinyelectron 的源码里 Linux 那条路是直接 abort 的
   （`Portable R for Linux is not yet supported`）。

`build_exe.R` 开头会把这几条查一遍，**当场停下来说明白**，而不是跑到一半甩一句
electron-builder 的英文栈。加 `--force` 可以硬闯（本机硬闯的结果见下面第四节
那道"假绿"的账）。

**⇒ 所以这台机器上正确的做法是 `git push` + 等 CI**，不是想办法在本机跑通。
想在本机跑的话，得有 wine（`sudo apt install wine64`）+ Node 22，而且 mac 那份
**永远**得在 Mac 上打。

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

## 四、发出去之前，在真机上过一遍这两张表

> ⚠️ 我**没有 Windows 机器、也没有 Mac**。这四个产物是"组装正确、结构验过"，
> **不是"我跑过"**。下面每一条都是"这条不过的话用户当场就废了"，请一条条走。

### 安装包 `.exe`（Windows，**这是现在发给用户的那个**）

- [ ] 双击安装，**能装完**（Windows 会弹「未知发布者」→ 更多信息 → 仍要运行）
- [ ] 装完开始菜单 / 桌面能找到 DS_App，双击**出来的是独立窗口**，不是浏览器
- [ ] 窗口标题、界面中文没有乱码
- [ ] 注册一个账号 → 记下恢复码 → **关掉窗口 → 重开** → 能用同一个账号登录
- [ ] 新建对话，让模型跑一段 R（比如 `print(1+1)`），**能出结果**（自带运行时接上了）
- [ ] 「文件管理」里上传一个**中文名**的 csv，能预览
- [ ] 在一台**没装过 R** 的干净 Windows 上再走一遍上面全部
- [ ] 卸载：控制面板里能卸干净（卸载后 `%APPDATA%\DS_App` 里的数据是你自己的，别删错）
- [ ] 杀毒软件不拦（没签名时这条最容易出问题）

### 安装包 `.dmg`（macOS，**这是现在发给用户的那个**）

- [ ] 双击 `.dmg` 能挂载，里面是一个 `DS_App.app`
- [ ] 拖进「应用程序」，双击打开 —— 会被 Gatekeeper 拦，**右键 →「打开」→ 再点「打开」**能过
- [ ] 窗口起得来、界面中文没有乱码
- [ ] 注册 → 关掉 → 重开，账号还在
- [ ] 跑一个 R 任务能出结果（顺带验 `dsapp_utf8_locale()`：macOS 没有 `C.UTF-8`）
- [ ] 「配额与资源」页面能显示磁盘占用（验 `du` —— BSD `du` 没有 `-b`）
- [ ] Intel 机器上跑那个没有 `arm64` 后缀的 `.dmg`

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

---

## 六、这两个安装包验到什么程度（别再问"是不是真的"）

### 判据：不看名字、不看大小，看产物**自己带的**字节

后缀是打包脚本起的名字，谁都能起。真正的证据在文件头尾：

| 产物 | 判据 | 为什么顶不了包 |
|---|---|---|
| `.exe` | 头两字节 `MZ`，且 `0x3C` 处的 e_lfanew 指过去是 `PE\0\0` | 这是 Windows 装载器认的东西，不是文件名 |
| `.dmg` | **最后 512 字节**的头 4 字节是 `koly` | UDIF 磁盘映像的 trailer，`hdiutil` 认的就是它 |
| `.zip` | 头两字节 `PK` | —— |

**不用下载 1 GB**：这些都在文件的头尾，用 HTTP Range 取几 KB 就够。仓库外面
那份脚本是 `/tmp/gh_probe_assets.py`（没进仓库，要重跑就照上表自己写十几行）。

2026-10-08 在 Release `Test_V16.10` 上实测（**7 个附件全过**）：

```
ds-app.Setup.16.10.0.exe     244.1 MB  ✓  e_lfanew=0xd8 sig=b'PE\x00\x00'
ds-app-16.10.0.dmg           274.4 MB  ✓  尾部 4 字节 b'koly'
ds-app-16.10.0-arm64.dmg     262.1 MB  ✓  尾部 4 字节 b'koly'
DS_App-Windows-Test_V16.10.zip   169.1 MB  ✓  b'PK'
DS_App-macOS-arm64-Test_V16.10.zip 153.7 MB  ✓  b'PK'
DS_App-macOS-x86_64-Test_V16.10.zip 158.7 MB  ✓  b'PK'
```

核对哈希也不要下载：Release 的 asset 对象自带 `digest`（`sha256:…`），
和 `SHA256SUMS.txt` 逐条对、再对一次**双向集合相等**就行。

### 这条闸门被"假绿"骗过八次，别再信 job 的颜色

2026-10-07 之前，workflow 六条 job **连绿八轮，而一个 `.exe`/`.dmg` 都没打出来**。
两层原因叠在一起：

1. `shinyelectron` 把 `DSAPP_VERSION`（`Test_V16.10`）原样塞进 package.json 的
   `version`，electron-builder 抛 `⨯ Invalid version` **当场死**；而它的
   `run_command_safe()` 是 `error_on_status = FALSE`、`build_for_platforms()`
   不看返回码、`validate_build_output()` 发现没有 `dist/` 只打一句 warning，
   紧接着**无条件**打 `✔ Successfully built Electron app`。**失败被吞成成功。**
2. 我们这边唯一的防线是"在 `out/` 下按后缀找产物"，而它被 `node_modules` 里的
   `signtool.exe` / `7z-arm64.exe` 顶了包 ⇒ 找到了"exe"，于是 job 是绿的。

⇒ 现在两道都收紧了：`upload-artifact` 收窄到 `out/exe_out/*/dist/` 并且
`if-no-files-found: error`；Release 那步的摊平改成 `-mindepth 2 -maxdepth 2`
（download-artifact 的布局恒为 `dist/<artifact 名>/<文件>`）**再叠一层名字白名单**，
最后**数一遍是不是 6 个**。

⚠️ 但**别把"改了一层"当成"这类没了"**：同一天，上传那层已经收窄了，摊平那层
还是全局递归 `find dist -name '*.zip'`，于是往公开 Release 上挂了一个
**480 字节的 `example.zip`** —— R 的 `zip` 包自带的测试夹具，藏在 `.app` 里的
便携 R 库树里。**按后缀全局找，必然把依赖当成产品。**
