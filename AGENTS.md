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
raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#de1fb8997539d34ba029064f500f6903b955b5a7' crypto
raco make main.rkt run-tests.rkt
racket run-tests.rkt
racket scripts/check-version.rkt        # 版本对齐门禁
raco rivet schema check rivet-schema.json --json
bash scripts/smoke.sh                   # 冒烟
raco rivet acceptance --json            # 当前平台完整产品验收
```

## 验证与发版

- CI（`ci.yml`）：多平台 Racket matrix 测试 + 版本检查 + schema check + smoke + Linux GTK4 宿主编译门。
- 产品验收（`acceptance.yml`）：三平台分别执行真实 RVT1、原生构建、打包和可访问性驱动的 UI 操作；只有 `raco rivet acceptance --json` 全绿才能宣称完成。
- 发版（`release.yml`）：tag `v*` 触发；门禁 = `racket scripts/check-version.rkt "$GITHUB_REF_NAME"` + CHANGELOG 必须含 `## [x.y.z]` 小节；MSI 走 WiX 5.0.2。
- GUI 无应用内更新器是有意设计（CLI 换装 + 重启），勿当缺口补。

## 仓库特定规矩

- rivet 以不可变提交 pin（当前 `de1fb8997539d34ba029064f500f6903b955b5a7`）消费；升级 pin 须连动 schema check、生成客户端、产品验收与发版工作流。
- 三宿主腿分属对应平台机器；跨平台交互逻辑保持一致是验收项。
- Agent 不得以代码量、单元测试或单个平台截图代替完成证据；涉及 GUI 的改动至少要保留原生控件交互和后端返回值的验收证据。
- 产品不发布到 Racket catalog（家族产品惯例），别把它当库补 pkg 元数据。

## 组合定位（Portfolio placement）

- 轨道与授权：轨道 2 消费买断（专业/团队向）；授权形态：BUSL-1.1 → MIT（2030-10-22 或各版首发四周年，先到者；≤0.7.0 的已发布版本保持 MIT）；商业归属：个人使用永久免费，团队/商业场景（CI 规模化、共享规则包、审计）走官方 Pro。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。
