# Handoff — codex-remaining

## Completed
- 2026-09-16：接入 lean review auto-check 试点（分支 `feat/lean-review-pilot`，commit `8a7077e`）。机制七类场景全绿。
- 2026-09-16：用瘦身判据对**真实代码**做了第一次审查（此前的测试只用 `scratch_probe.swift` 这类探针验证机制，没有审过真实代码）。

## Current State
- 试点分支未合并 main。日志在 `.agent/lean-review/log.jsonl`（gitignore，不入库）。
- 代码规模：`Sources/CodexRemaining/main.swift` 638 行 + 3 个脚本 140 行。整体不臃肿。

## Next Steps（按优先级）
1. **版本号双写**（判据2）：`Info.plist:20` = `0.2.0`，`Sources/CodexRemaining/main.swift:239` 的 initialize JSON 里又硬编码一次 `"version":"0.2.0"`。发版时会漏改一处。修法：从 `Bundle.main` 读 `CFBundleShortVersionString`，失败再回落常量。**低风险，建议做。**
2. **legacy `rateLimits` 兼容路径**（判据4，**待核实，先别删**）：`main.swift:33` 的 `rateLimits` 与 `rateLimitsByLimitId` 并存，`:90-93` 优先取后者。要删必须先确认**支持的 codex-cli 最低版本**——本机 0.147.0 走新字段，不代表所有用户。没有这个结论前保留。
3. **`updateDisplay()` 5h/weekly 两块重复**（判据2）：`main.swift:555-575` 结构相同。提取一个 `applyWindow(_:to:resetItem:)` 可省约 8 行。收益小，**判据6「无需简化」也是合法结论**——不急。
4. **陈旧本地分支**（范围外，只报告）：`signed-notarized-distribution`（本地+远端，已决定永久不合并）、`v0.2.0-distribution`、`archive/local-main-pre-consolidation-20260913`、`docs/install-experience`。删远端分支需要你拍板。

## Key Decisions
- `build-app.sh:95-97` 的 ad-hoc `codesign` **不是**公证残留，是当前发布流程的一部分，保留。
- 付费 Apple Developer Program 已被明确拒绝，`signed-notarized-distribution` 不合并、不打 tag，不要再提证书/公证方案。
