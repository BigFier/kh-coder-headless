# kh-coder-headless

让 KH Coder 可以在命令行里跑，不用点界面。

KH Coder 是常用的中日文语料库分析工具，功能全，但只有图形界面。做一次分析要点一串窗口，批量处理基本没法做。这个项目把它的 17 个分析命令变成了命令行调用。

原理是在 `kh_coder.exe` 里塞了一个插件，直接调它自己的分析函数。所以跑出来的结果和手点界面完全一样，同一个 MeCab 分词、同一个 MySQL、同一个 R 绘图的。不是另写一套近似的东西。

[English](README.md)

---

## 怎么用

装完之后是这样：

```
khc words corpus.txt --at 5,20,50,100
```

输出：

```
  freq >=    5  ->  3778 terms
  freq >=   20  ->  1622 terms
  freq >=   50  ->   870 terms
  freq >=  100  ->   507 terms
```

这一步是为了定阈值。KH Coder 画共现网络时词太多会糊，一般 100 到 150 个词比较合适。看上表，大概用 `--min 150` 就行。

然后画图：

```
khc netgraph corpus.txt out/net.png --min 150
```

出来一张共现网络图，PNG 格式，能直接打开看。图上词的大小是词频，连线是共现关系。

再比如查某个词都出现在什么句子里：

```
khc conc corpus.txt 防衛 out/kwic.csv
```

出来一个 CSV，每行一条，左边是前文、中间是关键词、右边是后文。用来判断这个词在语料里的实际用法。

## 安装

需要 Windows，KH Coder 3.x 已经装好，Node.js 18 以上。

KH Coder 本体不在这个包里，因为装完有 7.7 GB，而且是 GPL-2.0 许可，不方便再分发。先去 [官网](https://khcoder.net/dl3.html) 下 Windows 版装上。

然后：

```
git clone https://github.com/BigFier/kh-coder-headless.git
cd kh-coder-headless
node lib/install.mjs
```

安装器做四件事：

1. 找 KH Coder 装在哪（先看环境变量 `KHC_HOME`，再看常见目录，再查注册表，最后看 PATH）
2. 把 `khc_cli.pm` 复制到 `<KH Coder>/plugin_en/`，旧版备份到 `khc_backup/`
3. 生成 `<KH Coder>/khc.cmd`，把你机器上的路径写进去
4. 跑一次 `probe`，看日志确认插件加载成功

如果没自动找到，手动指定：

```
node lib/install.mjs --khc-home "D:\khcoder3"
```

装完可以随时检查环境：

```
node lib/cli.mjs doctor
```

## 17 个命令

| 命令 | 干什么 | 出来什么 |
|---|---|---|
| `words` | 看不同阈值下有多少词 | 终端输出 |
| `freq` | 词频表 | CSV（Shift_JIS 编码） |
| `netgraph` | 共现网络图 | PNG |
| `conc` | 检索词的上下文 | CSV |
| `corresp` | 对应分析，看哪些词区分这些组 | PNG + 坐标 CSV |
| `cls` | 层次聚类树状图 | PNG |
| `mds` | 多维尺度分析 | PNG |
| `som` | 自组织映射 | PNG |
| `topic` | topic model | 3 个 CSV |
| `morpho` | 先做分词预处理 | 内部 |
| `mkoutvar` | 从标题结构建分组变量 | 内部 |
| `crosstab` | 交叉表加卡方 | CSV |
| `codcorresp` | 按 .cod 规则做对应分析 | PNG |
| `bayes` | 朴素贝叶斯，只训练 | 模型文件 |
| `dbtables` | 看语料结构，多少文多少段 | 终端输出 |
| `db` | 列出已有的工程库 | 终端输出 |
| `probe` | 打印运行环境 | 终端输出 |

调参常用的：

```
--min N        最小词频，画图时最有用
--max N        最大词频
--min_df N     至少出现在几个文档里
--edges N      最多画几条边，默认 60
--lang jp|zh   语料是日文还是中文
--engine jieba|mecab   分词引擎，中文默认 jieba，日文默认 mecab
--dict FILE    用户词典
--csv FILE     把图形的坐标导出来
--tani UNIT    按什么单位计数：bun 文、dan 段、h1 到 h5 标题层级
--var h1       分组变量
--topics N     topic model 分几个主题
```

## 几个例子

**想知道哪些词能区分这几组文档**

先建分组变量。语料里如果标题用 `<h1>组名</h1>` 标好了，这样建：

```
khc mkoutvar corpus.txt --var h1 --tani dan
khc corresp  corpus.txt out/ca.png --csv out/coords.csv
```

对应分析会把词和组别画在同一张图上，离得近就说明关系强。坐标 CSV 可以自己重画。

**想看语料的整体结构**

```
khc dbtables corpus.txt
```

输出里有 `bun`（文）、`dan`（段）、`h1` 到 `h5`（各级标题）各多少个。用来确认语料切分对不对。

**日文语料要用用户词典**

日文分词有时候会把复合词切碎，比如「安全保障」切成「安全」和「保障」。想让它们算一个词，就写个 CSV：

```
安全保障,0,0,0,名詞,一般,*,*,*,*,安全保障,アンゼンホショウ,アンゼンホショウ
```

然后加 `--dict`：

```
khc netgraph corpus.txt out/net.png --min 150 --dict mydict.csv
```

格式是 MeCab 的词典格式，13 列。前四列填 0 就行，重点是第 1 列词形、第 5 列词性、第 12、13 列读音。

## 踩过的坑

这些都是实际遇到的，写在代码注释里了，也记在这。

**`freq` 出来的 CSV 是 Shift_JIS，不是 UTF-8。** Excel 打开正常，程序读要按 CP932 解码。

**词频要归一化。** KH Coder 数的是原始次数。一份每年都在变厚的报告，所有词都会显示涨。跨年比较前要先除以总词数。我拿一份七年白皮书试的时候，「防衛産業」原始次数从 46 涨到 167，看着是三倍多，但归一化后只有一倍多，其余是书变厚带来的。

**`cls` 在大语料上会崩。** 5 万多段的日语语料上，63 个词能跑完，170 个词时直接崩，退出码 `0xC000013A`，日志里连个 Perl 报错都没有。词数控制在 100 以内，或者按年切开跑。

**`cls` 出的图特别长。** 281 个词出的是 480×5655 的 PNG，标签全叠在一起看不清。配图还是用 `netgraph` 或者 `corresp`。

**`corresp` 默认不画词标签。** 这个项目修好了。KH Coder 内部建了两个绘图对象，一个带标签一个不带，原代码存的是不带标签那个。改法是取第 0 个，代码在 `plugin/khc_cli.pm` 的 `_cmd_corresp` 附近。

**启动时会弹一个 logo 挡住屏幕。** 一个 400×122 的无边框窗口停在屏幕正中，而且不会自己消失。原因是销毁它的代码只在 Tk 分支里执行，Windows 走不到。启动器会拉起一个 `khsplashkill.exe` 把它关掉，详见 [docs/splash.md](docs/splash.md)。

**`khc.cmd` 必须是纯 ASCII。** cmd.exe 按 OEM 码页读 .cmd 文件，`rem` 注释里有一个中文字符就会破坏解析，而且退出码还是 0，出错也看不出来。我自己踩了两次，安装器现在会断言这一点。

**`plugin_en/` 里不能放 `*.pm.bak`。** KH Coder 扫描插件时会砍掉末 3 个字符，所以 `khc_cli.pm.bak` 会被当成 `use khc_cli.pm` 加载，弹出 plugin error 对话框。无人值守的时候这个框永远点不掉，整个进程卡死。安装器把备份放到 `<KH Coder>/khc_backup/`，发现违规会警告。

## 给 AI agent 用

无界面命令行的用处就在这。agent 不需要什么协议，知道 `khc.cmd` 的路径就能用：

```
语料在 ./corpus.txt，日语，约 500 KB。

1. 跑 khc words corpus.txt --at 5,20,50,100，选一个让词数落在 120 左右的 --min
2. 用这个 --min 跑 khc netgraph，存到 out/net.png
3. 打开 PNG，描述图上的几个词群
```

整个过程 agent 就是在敲命令、读文件。不需要起服务，不占 token。

## 许可

安装器、命令行包装、文档是 MIT。

`plugin/khc_cli.pm` 是 **GPL-2.0**，因为它在运行时链接 KH Coder 的 GPL-2.0 模块。改了再分发的话，GPL-2.0 适用。GPL 全文在 `plugin/COPYING-GPL-2.0.txt`。

KH Coder 本体不在这个包里，它的许可由作者单独规定。
