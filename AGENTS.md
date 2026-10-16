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
raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.11.0' crypto
raco make main.rkt run-tests.rkt
racket run-tests.rkt
racket scripts/check-version.rkt        # 版本对齐门禁
raco rivet schema check rivet-schema.json --json
bash scripts/smoke.sh                   # 冒烟
```

## 验证与发版

- CI（`ci.yml`）：多平台 Racket matrix 测试 + 版本检查 + schema check + smoke + Linux GTK4 宿主编译门。
- 发版（`release.yml`）：tag `v*` 触发；门禁 = `racket scripts/check-version.rkt "$GITHUB_REF_NAME"` + CHANGELOG 必须含 `## [x.y.z]` 小节；MSI 走 WiX 5.0.2。
- GUI 无应用内更新器是有意设计（CLI 换装 + 重启），勿当缺口补。

## 仓库特定规矩

- rivet 以 pin（`RIVET_PIN` env，当前 v0.11.0）消费；升级 pin 须连动 schema check 与 GTK 编译门。
- 三宿主腿分属对应平台机器；跨平台交互逻辑保持一致是验收项。
- 产品不发布到 Racket catalog（家族产品惯例），别把它当库补 pkg 元数据。
