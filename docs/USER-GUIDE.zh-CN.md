# RegexMate 使用指南

[English](USER-GUIDE.md) · **简体中文**

通过 CLI、原生 GUI 或 MCP 在本地验证、测试、解释和检查正则。

## 当前可用状态

按现行 BUSL-1.1 条款提供的免费开发者与 agent 工具，包含仓库许可的内部使用。许可证不是 MIT，免费定位不改变许可条款。

## 平台与安装

提供 macOS、Windows、Linux 桌面与 CLI 发布附件。引擎使用 Racket pregexp，不能据此认定 JavaScript、PCRE 或其他生产引擎语义相同。

从[官方 Releases](https://github.com/turinglambdaai/regexmate/releases)选择明确标注系统和架构的附件，阅读该版本说明并核对附带校验文件。未列出的附件或平台不视为已交付。预览构建可能没有系统发行者签名或公证；不要为安装而关闭系统安全保护。

Windows ZIP 中 CLI 的执行路径随版本而异：已发布的 **v0.8.0** 便携版在压缩包根目录使用 `regexmate.exe`；包含[目录修复（#13）](https://github.com/turinglambdaai/regexmate/issues/13) 的后续构建改用 `bin/regexmate.exe`（macOS/Linux：`bin/regexmate`）。请完整解压，保留 Racket 各平台对应的运行库及独立的 `gui/` 目录。对已安装的旧版 Windows ZIP，经签名验证的 CLI 更新会保留原可执行文件路径，并同步替换旁边的运行库，不会悄悄改变安装位置。单独发布的 Windows 单文件 EXE 是另一种安装与更新模式。

## 第一次使用

1. 先用 regexmate validate 验证模式，再匹配一条合成正例。
2. 用 regexmate test 添加反例与边界样例；将模式用于不可信输入前检查 lint 结果。
3. 供 agent 使用时连接 regexmate mcp，仅授予需要的工具权限，并在最终目标引擎复核模式。

## 数据、备份与恢复

在自己的项目中保存模式夹具、预期结果和生成的 SVG。不要把客户机密放入样本文本或公开 issue。批量替换前保留副本；匹配与 lint 不保证阻止所有性能攻击。

## 联网、密钥与隐私

核心正则处理在本地完成。更新检查、下载及外部 agent 可能联网；提供敏感样本文件前应检查 agent 权限。

## 已知限制

GUI 只读检查更新，实际安装由 CLI 执行。更新后退出并重启 GUI；源码或包安装使用对应更新方式。

## 更新与卸载

先备份数据，再阅读目标版本说明。应用内检查更新不一定能安装当前渠道的更新；按手册区分便携包、系统安装器和源码安装。不要绕过失败的验签或用来源不明的文件覆盖程序。更新失败时保留现有数据与错误信息，使用可信发行包恢复；卸载程序通常不等于删除独立的数据目录，删除个人数据前先确认备份。

## 获得帮助

在 [GitHub Issues](https://github.com/turinglambdaai/regexmate/issues) 反馈，中文或英文均可。提供版本、系统与架构、安装渠道、复现步骤、预期和实际结果。先用合成样本复现；不要附上密钥、授权文件、数据库、原始私密文档或完整日志。公开支持不承诺响应时限。

## 深入阅读

- [命令手册](../docs/guide.html)
- [Agent 工作流](../docs/agents-guide.md)
- [项目说明与开发入口](../README.zh-CN.md)
- [现行许可证](../LICENSE)
