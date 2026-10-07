# 推到 GitHub（Test_V16.10）

这份是**操作单**，照着做即可。树已经 `git init` 并提交好了，只差建仓库和推。

## 一、仓库里放什么

这个仓库 = **Shiny 版**（线上那套的应用本体 + 部署脚本 + 打包工具链 + 自检）。
用户要的三样东西是这样分布的：

| 交付物 | 放在哪 |
|---|---|
| **Shiny 版**（源码，可自建服务器 / 可审计） | 就是这个仓库本身 |
| **Windows 版** | Releases 附件 `DS_App-Windows-Test_V16.10.zip` |
| **macOS 版** | Releases 附件 `DS_App-macOS-arm64-Test_V16.10.zip`、`DS_App-macOS-x86_64-Test_V16.10.zip` |

⚠️ **桌面版的 zip 不要提交进仓库**（每个 150~170 MB，三个加起来 460 MB）。
GitHub 单文件限 100 MB，仓库也不该背这个重量 —— 走 Releases。
`.gitignore` 里已经写了 `*.zip`，双保险。

## 二、推

```bash
# 1) 先在 GitHub 上建一个**空**仓库：Biomamba/YCFS_APP
#    不要勾 "Add a README" / ".gitignore" / "license"（勾了要先 pull）

cd /home/biomamba/dsapp_build/github_YCFS_APP
git remote add origin git@github.com:Biomamba/YCFS_APP.git   # 没配 SSH 就用 https
git push -u origin main
```

## 三、发 Release

Releases → **Draft a new release**

- **Tag**：`Test_V16.10`（点 "Create new tag on publish"）
- **Title**：`Test_V16.10`
- **附件**：把 `~/dsapp_build/release_Test_V16.10/` 里这三个传上去
  - `DS_App-Windows-Test_V16.10.zip`
  - `DS_App-macOS-arm64-Test_V16.10.zip`
  - `DS_App-macOS-x86_64-Test_V16.10.zip`
  - `SHA256SUMS.txt`（顺手传，用户能自己对校验和）

Release 正文可以直接抄 `交付说明.txt`（打包脚本生成的那份，就在 release 目录里）——
里面有三个包的字节数、自检项数、以及"用户怎么用"（含杀软/Gatekeeper 的放行步骤）。

## 四、发完核对三件事

1. 仓库首页的 README 渲染正常（表格、徽章、链接不是裸文本）。
2. 应用页脚那个「获取最新版」指向 `https://github.com/Biomamba/YCFS_APP`
   （单一真相源在 `R/config.R:DSAPP_RELEASE_URL`）—— 点一下，**别是 404**。
   ⚠️ 这个链接**随桌面包一起发出去**：包一旦出门，链接就改不动了，所以
   仓库地址必须是最终的那个。
3. Releases 里三个 zip 能下载，大小和 `SHA256SUMS.txt` 对得上。

## 五、这一版的坑（发给用户时值得写进 Release 正文）

- Windows/macOS 都**没有代码签名**，首次打开会被 SmartScreen / Gatekeeper 拦。
  放行方法在 README 的下载章节里，Release 正文里也该重复一遍。
- macOS 包里用了符号链接省空间，**必须发 zip**（用 `zip -y` 打的），
  不要发解开的文件夹 —— 某些传输方式会把符号链接变成副本或直接丢掉，
  用户那边就是双击没反应。
