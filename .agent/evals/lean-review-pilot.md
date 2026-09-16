# Lean Review Auto-Check Pilot — 验收条件

试点仓：`codex-remaining`（Claude / Mac，单平台单项目）。第二个试点仓：`mealnote`（已确认要做，等本仓通过后接入）。

## 目标（收窄后的准确表述）

自动发现**未审**或**已过期**的 lean review 并要求 agent 补做。
**不宣称**保证审查结论正确，**不宣称**不可绕过——hook 是补救型 continuation 机制，不是事务式门禁。

## 架构（第一版必须小）

```text
dev-workflow 判据 → lean review → review receipt → Stop hook →  匹配 PASS
                                                              → 缺失/过期 BLOCK → 要求补审
                                        + append-only 运行日志
```

无数据库、无 daemon、无 CI、无独立 orchestration。全部落在本仓 `.claude/` 与 `.agent/lean-review/`，**不进全局 `~/.claude/settings.json`**（全局 Stop 槽已被 `send_usage_telegram.py` 占用，且匹配的 hooks 并行执行、顺序不保证）。

## 实现约束（Codex 三条，验收前提）

1. **Receipt 必须绑定实际审查动作**：不能由模型自行写一个 `{"status":"pass"}`。签发时必须关联实际审查输出文件，并在签发瞬间重算代码指纹；签发期间代码变了，不得为新状态签发成功记录。
2. **「本轮变更」必须可识别**：区分会话开始前已有的修改与本轮新增的修改；**本轮已提交、工作区变干净也不能跳过**。Receipt 与日志自身必须排除在代码指纹之外，否则每次写记录都会让上一次审查失效。**新增文件必须能被发现**，不能只检查 receipt 列出的路径。
3. **等待用户 / 失败退出只代表暂停**：可以正常结束当前回答，但必须保留「尚未审查／验证失败」状态；恢复任务后继续检查，一次 `SKIP` 不清除未完成义务。

### 为什么需要「会话基线」这一份状态（成本最高的部分，须有明确推导）

最省的写法是无状态判定：「工作区有未提交改动 → 要 receipt」。它不够，因为约束 2 明确要求**本轮已提交、工作区变干净也不能跳过**——无状态判定在 agent 提交后会立刻变成 SKIP，恰好放过 BPS 18→31 那一类。
次省的写法是「HEAD 有无覆盖 receipt 的提交」。它对单次会话够用，但无法区分「会话开始前就存在的旧提交/旧改动」和「本轮新增的」，会把历史欠账算成本轮漏审，产生误拦。

因此**只保留一份会话基线**：SessionStart 记 `{session_id, HEAD, fingerprint}`，本轮变更 = 当前状态与该基线之差（跨越提交边界）。
除此之外不再增加状态：pending 义务与 continuation 计数**复用同一个基线文件的字段**，不另起状态机；日志是只读流水，不参与判定。

## 验收场景（七类）

两种验证方式：**整会话**（真实 `claude -p`，证明 harness 会调用并按 decision 行动）／**hook 级**（直接喂 Stop payload，证明判定逻辑正确）。前者已在场景 2/3/7 证明链路通，后者用于确定性地覆盖其余分支。

| # | 场景 | 预期 | 结果 | 证据 |
|---|---|---|---|---|
| 0a | 项目级 Stop hook 会不会触发 | 触发且无需批准 | **PASS** | 冒烟：`stop_hook_active:false`，`$CLAUDE_PROJECT_DIR` 可用 |
| 0b | `decision:block` 能否让会话继续 | 继续，且第二次 `stop_hook_active:true` | **PASS** | 冒烟日志两行 |
| 1 | 正常代码修改 + 有效 review | PASS | **PASS**（hook 级） | `pass \| receipt 覆盖当前状态` |
| 2 | 纯问答 / 只读 | SKIP | **PASS**（整会话） | `skip \| 本轮无代码变更`，213ms |
| 3 | 代码修改 + 没 review | BLOCK | **PASS**（整会话） | 新建 `scratch_probe.swift` → `block \| 本轮有代码变更但没有 receipt`，scope=1 |
| 4a | review 后改已有文件 | BLOCK | **PASS** | `block \| receipt 已过期` |
| 4b | review 后**新增**文件 | BLOCK | **PASS** | scope 从 1→2，证明不是只查 receipt 列出的路径 |
| 4c | 本轮**已提交**后 | BLOCK | **PASS** | 提交后两个文件已不在工作区，scope 仍=2，来自 `baseline_head..HEAD` 差异 |
| 5a | 审查输出文件缺失 | 拒签 | **PASS** | exit=1，`拒签：审查输出文件不存在或为空` |
| 5b | 签发期间代码变了 | 拒签 | **PASS** | exit=1，`token=1a0cb21f… 现在=6a11f4e5…`；随后 stop 仍 block |
| 6 | 明确等待用户 | SKIP，义务保留 | **PASS** | 第1次 `skip`，第2次仍 `block` |
| 7 | continuation 无法收敛 | 有界退出并标注未完成 | **PASS**（整会话） | block×2 → `达到自有上限 2 次，有界退出，仍未完成审查`，早于官方 8 次上限 |
| 断言 | 写 receipt/日志不得自废 | 连续 PASS | **PASS** | 连续两次 stop = `['pass','pass']`；指纹自检写日志前后同为 `ab16223e…` |

**实现期发现并修掉的两个真实缺陷**：
1. `changed_scope` 最初没减去会话基线，会把**会话开始前就存在的未提交改动**算成本轮变更 → 场景 2 必然误拦。改为按 (path, content-hash) 与基线比对。
2. `pause` 的 reason 取了 `argv[3]`（应为 `argv[2]`），传入的原因被丢弃、日志里只剩默认值。
另：`__pycache__` 必须排除在指纹外，否则 hook 每跑一次就自发让 receipt 过期。

补充断言：
- 写 receipt / 写日志这个动作本身**不得**触发场景 4（指纹须排除 `.agent/lean-review/**`）。
- 场景 6 之后的下一个 Stop 仍须检查（义务未清除）。

## 试点期要能回答的问题（日志字段用途）

误拦几次 / 漏拦几次 / 为什么 SKIP / hook 有没有失败 / 平均多花多少时间 / 有没有出现循环。

日志每次 append 一行：`timestamp, platform, project, session, decision(pass|block|skip|error), reason, changed_scope_count, receipt_match, duration_ms`。

## 边界

- 不扩充判据（判据正文仍在 `~/.codex/skills/dev-workflow/SKILL.md`，本试点只消费不修改）。
- 不做 CI、不做全局 rollout、不做独立 Skill。
- Codex 侧暂不做（`stop_hook_active` 语义相近，但非托管 hook 改动后需用户确认信任才生效，且可被禁用——接入时须实测 enabled + trusted，不能只确认配置文件存在）。

## 状态

- [x] 实现（`.claude/hooks/lean_review.py`，281 行，5 个子命令）
- [x] 七类场景实测（全部 PASS，见上表）
- [ ] 试点期观察
- [ ] 决定是否接入 mealnote
