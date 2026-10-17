# Changelog

## 0.1.0

初次发布。

- 17 个命令的无界面驱动（morpho / words / freq / netgraph / cls / mds / som /
  corresp / topic / conc / mkoutvar / crosstab / codcorresp / bayes / dbtables /
  db / probe）
- 安装器：自动探测 KH Coder、部署插件、生成启动器、跑 probe 验证
- 工作目录改为可配置（`KHC_WORKDIR` 环境变量，默认 `<KHC>/khc_work`），
  不再硬编码到某一台机器的路径
- 修复 `corresp` 不画词标签的问题（取错了 plot 对象）
- 生成器对 `khc.cmd` 做纯 ASCII 断言
- `khc doctor` 环境诊断
