# KH Coder 下载

本项目**不含** KH Coder 本体，需要先自己装。

## 从这里下

**https://pan.baidu.com/s/1K24bPGdrR4YEbkxW1X3GuA?pwd=2cre**

提取码已包含在链接里（`pwd=2cre`），点开直接下。

## 怎么装

1. 打开上面的链接，下载安装包
2. 双击安装，一路点「下一步」
3. **用默认路径**，不要改——改到别处安装器可能找不到
4. 装完回来运行 `node lib/install.mjs`

## 装到哪儿去了

默认是这两处之一，安装器会自动找：

- `D:\khcoder3\`
- `C:\khcoder3\`

找不到的话，手动告诉安装器：

```bash
node lib/install.mjs --khc-home "你实际装的目录"
```

## 也可以从官网下

https://khcoder.net/dl3.html —— 选 Windows 版（含 MySQL 与 R 的一体包）。

## 为什么不在这个仓库里

KH Coder 装完约 **7.7 GB**，其中 6.6 GB 是它自带的 MySQL 和 R。塞不进 Git 仓库，也不该塞——它是樋口耕一的独立项目，以 GPL-2.0 授权，有自己的发布节奏。详见 [README 的免责声明](README.md#免责声明)。
