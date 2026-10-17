# Changelog

## 0.2.0

修了一批只在**路径含中文**时才暴露的 bug，加了示例语料。

这一批问题的共同根因：KH Coder 内部的 `open` / `File::Copy` 走 Windows ANSI
代码页，而插件的字符串是 Unicode 的。纯 ASCII 路径下两者恰好一致，所以之前
所有测试都通过了；目录名一带中文就全线失败。

### 修复

- `_fs()` 改为按 **ANSI 代码页**（`Win32::GetACP`）转换。上一版按控制台代码页
  判断，控制台是 UTF-8（cp65001）时不转换，反而把好的改坏了。实测四种编码只有
  cp936 能匹配到文件。
- `kh_project->new()` 收到的是文件系统字节形式，不再传 Unicode 字符串。此前会
  报「要分析的文件不存在」，而文件其实存在。
- `_copy_file()` 两端都做转换。
- 图片保存：KH Coder 内部的 `File::Copy` 无法写入中文路径，改为先存 ASCII 临时
  路径再 rename。
- `_cmd_freq()`：同上，先写临时路径再转换。
- `conc` 的 CSV 写入：`open` 用字节形式。
- 存在性检查 `-e` 全部改用转换后的路径（此前会假报 `exists=no`）。

### 新增

- **`--hinshi` 真正可用**：按词性筛选，支持类名（`Noun,Verb`）或数字 id。
  中文语料不写这个，图上会被「不/就/也/都/很/但」占满。
  实现要点：`gui_widget/hinshi` 的 `selected()` 读的是 `{checks}` 数组，而
  `selection_set()` 只改控件不回写数组，所以必须直接写 `{checks}`。
  另：本机这版 `{name}` 存的是 **id** 不是类名，与公开的 beta 源码不一致，
  两种形式都兼容。
- **`freq` 输出改为带 BOM 的 UTF-8**。原输出是 CP932，简体中文里大量汉字
  CP932 装不下，会被转义成 `\x{8BF4}` 这种字面文本。现在解码后还原转义再
  写 UTF-8。
- **`conc` 清理跨段标记**。跨段落的两截之间会出现 `鈴?`（`?` 是 KH Coder 替换
  非法字节留下的），现在换成空格。
- `examples/quickstart/`：50 段虚构访谈语料 + 三个已跑出的产物 + 逐步说明。

### 已知限制

- `cls` 在 5 万段以上语料、词数超过约 100 时原生崩溃（exit `0xC000013A`，
  日志无 Perl 异常）。
- 断点、对应分析等依赖 R 的输出，标签字体依赖系统，跨机器可能不一致。

## 0.1.0

初次发布。

- 17 个命令的无界面驱动（morpho / words / freq / netgraph / cls / mds / som /
  corresp / topic / conc / mkoutvar / crosstab / codcorresp / bayes / dbtables /
  db / probe）
- 安装器：自动探测 KH Coder、部署插件、生成启动器、跑 probe 验证
- 工作目录改为可配置（`KHC_WORKDIR` 环境变量，默认 `<KHC>/khc_work`）
- 修复 `corresp` 不画词标签的问题（取错了 plot 对象）
- 生成器对 `khc.cmd` 做纯 ASCII 断言
- `khc doctor` 环境诊断
