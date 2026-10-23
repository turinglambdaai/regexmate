# AGENTS.md

RegexMate——agent 时代的正则工作台（validate/match/explain/replace/graph/batch-test/lint，版本化 JSON 契约 + MCP server），Racket 引擎 + 三宿主原生 GUI。

## 结构

- `core/` — Racket 引擎核心；`server/` — MCP/服务侧
- `app/` — 引擎入口（`main.rkt`）；`tests/` — Racket 测试（`run-tests.rkt` 驱动）
- `macos-host/`（SwiftUI）、`windows/`（WinUI3）、`linux/`（GTK4）— 三宿主腿，对应平台机器独占开发
- `scripts/`、`build/`、`branding/`、`docs/`；`compiled/`、`output/`、`dist/` 为本地产物不提交

## 常用命令

```bash
# 引擎测试（CI 同款）
raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#1ebb3ac09ed2e23eeb0a91cbec6e689aac01ab1a' crypto
raco make main.rkt run-tests.rkt
racket run-tests.rkt
racket scripts/check-version.rkt        # 版本对齐门禁
raco rivet schema check rivet-schema.json --json
raco rivet doctor --release             # rivet 发布门禁（生成物新鲜度/pin/更新API关键词）
raco rivet generate                     # 重生成客户端后: Kotlin 客户端在 .rivet/ 下被 ignore，须 git add -f
bash scripts/smoke.sh                   # 冒烟
raco rivet acceptance --json            # 当前平台完整产品验收
```

## 验证与发版

- CI（`ci.yml`）：多平台 Racket matrix 测试 + 版本检查 + schema check + rivet 发布门禁（`doctor --release`）+ smoke + Linux GTK4 宿主编译门。
- 产品验收（`acceptance.yml`）：三平台分别执行真实 RVT1、原生构建、打包和可访问性驱动的 UI 操作，并把 `acceptance --json` 报告落盘上传；`matrix` 作业用 `raco rivet matrix` 把三份报告折成单一跨平台裁决。只有全绿才能宣称完成。
- 发版（`release.yml`）：tag `v*` 触发；门禁 = `racket scripts/check-version.rkt "$GITHUB_REF_NAME"` + CHANGELOG 必须含 `## [x.y.z]` 小节 + `raco rivet doctor --release`；MSI 走 WiX 5.0.2。
- GUI 无应用内更新器是有意设计（CLI 换装 + 重启），勿当缺口补。

## 仓库特定规矩

- rivet 以不可变提交 pin（当前 `1ebb3ac09ed2e23eeb0a91cbec6e689aac01ab1a`，即 v0.12.0）消费，三个工作流与本文档同步换 pin；升级 pin 须连动 schema check、生成客户端（重生成后 Kotlin 客户端在 `.rivet/` 下被 ignore，须 `git add -f`）、产品验收与发版工作流。rivet 安装步骤一律字面写 pin，不经 env 间接（doctor 只扫字面文本）。
- 三宿主腿分属对应平台机器；跨平台交互逻辑保持一致是验收项。
- Agent 不得以代码量、单元测试或单个平台截图代替完成证据；涉及 GUI 的改动至少要保留原生控件交互和后端返回值的验收证据。
- 产品不发布到 Racket catalog（家族产品惯例），别把它当库补 pkg 元数据。

## 组合定位（Portfolio placement）

- 轨道与授权：轨道 2 消费买断（专业/团队向）；授权形态：BUSL-1.1 → MIT（2030-10-22 或各版首发四周年，先到者；≤0.7.0 的已发布版本保持 MIT）；商业归属：现行 LICENSE 已允许个人及内部生产、CI、agent 使用；未来官方 Pro 仅为新增团队共享规则包、协作审计和支持便利收费，不按企业身份追收既有使用权。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/regexmate/issues/4)。保留现行 internal production/CI/agent 使用许可。下一步验证 CLI 更新与 GUI 重启交接；Pro 仅规划新增协作/规则包/审计/支持便利。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。
