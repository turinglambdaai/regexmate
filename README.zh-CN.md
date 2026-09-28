# RegexMate

面向人与智能体的正则工作台——用一条跨平台 CLI 完成正则的校验、匹配、解释、替换与绘图，并为编码智能体提供版本化的 JSON 契约。

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文**

## 为什么做这个

现有正则工具要么只在网页里（regex101），要么偏检索（ripgrep），要么沉默寡言（grep）。RegexMate 是一个诚实的小 CLI，把四件事做好，并且原生说 JSON：

- **validate** —— 按 Racket `pregexp` 方言校验语法，报错保持单行
- **match** —— 对文本或 stdin 执行匹配；终端里高亮，管道里结构化
- **explain** —— 用平实的英文或中文逐部分讲解正则
- **replace** —— 带反向引用的替换，并报告替换次数
- **graph** —— 渲染 SVG 铁路图，用于规格文档和代码评审

所有平台都提供独立二进制——目标机器无需安装 Racket。

## 安装

**独立二进制**（Windows / Linux / macOS）：从 [Releases](https://github.com/turinglambdaai/regexmate/releases) 下载压缩包，解压即用。

**Racket 包：**

```bash
raco pkg install https://github.com/turinglambdaai/regexmate
```

**从源码构建**（Racket 9.x）：

```bash
git clone https://github.com/turinglambdaai/regexmate
cd regexmate
raco make main.rkt
racket run-tests.rkt          # 测试套件
raco exe -o regexmate main.rkt  # 产出本地二进制
```

## 快速上手

```console
$ regexmate validate '^\d{3}-\d{4}$' --lang zh
正则表达式: ^\d{3}-\d{4}$
✓ 语法有效

$ regexmate match '\d+' 'abc 123 def 456'
Found 2 match(es):
  at 4-7: "123"
  at 12-15: "456"

$ regexmate explain '(?:\d{2,4}|[a-z]+)(?=x)' --lang zh
正则表达式: (?:\d{2,4}|[a-z]+)(?=x)

组成部分:
  1. [group] (?:\d{2,4}|[a-z]+)
       ← 非捕获组 (?:...): 数字 (\d) × {2,4} | 字符类: [a-z] × +
  2. [lookaround] (?=x)
       ← 正向先行断言 (?=...): 字面量: x

$ regexmate replace '(\w+)@(\w+)' '\1 AT \2' 'mail a@b'
Replaced 1 occurrence(s).
Result: mail a AT b

$ regexmate graph 'ab(c|d)*' -o diagram.svg
SVG 已保存到: diagram.svg
```

## JSON 契约（`regexmate/v1`）

所有命令都接受 `--json`，输出单行信封，字段稳定：`schema`、`command`、`ok`。

```console
$ regexmate match '(\w+)@(\w+)' 'mail a@b' --json
{"command":"match","count":1,"matches":[{"end":8,"groups":[{"end":6,"index":1,"name":null,"start":5,"value":"a"},{"end":8,"index":2,"name":null,"start":7,"value":"b"}],"start":5,"value":"a@b"}],"ok":true,"pattern":"(\\w+)@(\\w+)","schema":"regexmate/v1","text":"mail a@b"}
```

契约规则：

- 区间为绝对下标，`[start, end)` 半开——`end` 不含。
- 捕获组从 1 计数；`name` 字段为将来命名组预留；未参与的组是 `null`，绝不缺键。
- 错误信息是单行字符串（不含换行）。
- `graph --json` 把 SVG 以字符串嵌入；`graph -o FILE --json` 报告 `output` 与 `bytes`。

### 退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功——有匹配 / 语法有效 / 完成替换 |
| `1` | 正则表达式无效 |
| `2` | 用法错误（未知命令或选项） |
| `3` | 语法有效但零匹配 / 零替换 |

## 正则方言

RegexMate 用 Racket 的 `pregexp` 引擎校验与匹配。支持：`. ^ $ * + ? {n,m}`（贪婪与懒惰）、`( ) (?: )`、四种断言 `(?=) (?!) (?<=) (?<!)`、原子组 `(?>)`、标志组 `(?i:…) (?is:…) (?-i:…)`、字符类（区间 / 取反 / POSIX 名 `[:alpha:]`）、转义 `\d \D \w \W \s \S \b \B`、反向引用 `\1`–`\9`、Unicode 类 `\p{…}` / `\P{…}`。

引擎不支持（`validate` 会判为无效）：命名组 `(?<name>…)`、`\A`/`\z` 锚点、`\x41` 十六进制转义。对合法但可视化器尚未覆盖的语法，`explain` 与 `graph` 会优雅降级并提示。

## 本地化

人类可读输出默认英文。`--lang zh` 或环境变量 `REGEXMATE_LANG=zh` 切换全部消息，包括 `explain` 的描述。`NO_COLOR` 关闭 ANSI 高亮。

## 开发

```bash
racket run-tests.rkt      # 单元测试
bash scripts/smoke.sh     # CLI 端到端冒烟
racket scripts/check-version.rkt v1.0.0   # 发布门禁
```

CI 在 Ubuntu、Windows、macOS 三平台 × Racket 9.2 上运行单元测试与冒烟测试；推送 `v*` 标签会构建三平台独立二进制并发布带 SHA-256 校验和的 GitHub Release。

## 项目结构

```
regexmate/
├── main.rkt                 # CLI 入口
├── version.rkt              # 运行时版本（须与 info.rkt 一致）
├── info.rkt                 # Racket 包元数据
├── core/
│   ├── ast.rkt              # 正则 AST 数据结构
│   ├── regex-parser.rkt     # 递归下降解析器（与 pregexp 对齐）
│   ├── regex-engine.rkt     # 基于 pregexp 的匹配 / 替换
│   └── i18n.rkt             # 英/中消息表
├── output/
│   ├── json-format.rkt      # regexmate/v1 信封
│   ├── human-format.rkt     # 双语人类输出 + 解释器
│   ├── highlight.rkt        # ANSI 匹配高亮
│   └── railroad.rkt         # AST → pict → SVG 铁路图
├── tests/                   # rackunit 测试套件
├── scripts/                 # smoke.sh、check-version.rkt
├── docs/                    # 产品主页（GitHub Pages）
└── .github/workflows/       # ci.yml、release.yml
```

## 路线图

- 同一核心之上的桌面 GUI（铁路图、实时匹配表、解释面板）
- MCP server，把正则工具暴露为原生智能体工具
- 方言 lint（灾难性回溯告警、可移植性检查）
- 包管理器分发（Homebrew、winget、AUR）

## 许可证

[MIT](LICENSE)
