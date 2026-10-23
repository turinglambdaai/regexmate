# AGENTS.md

## Authorization decision before implementation

Decision `2026-10-auth-1`: No commercial Permit credentials, Commerce checkout or licensing account. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

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

- 当前决策（2026-10-v2）：免费开发者与 agent 工具。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/regexmate/issues/4)。保留现行 internal production/CI/agent 使用许可。下一步验证 CLI 更新与 GUI 重启交接；Pro 仅规划新增协作/规则包/审计/支持便利。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.
