# Lean Review Auto-Check Pilot — 验收条件

试点仓：`codex-remaining`（Claude / Mac）。第二个试点仓：`mealnote`（2026-09-16 已接入，见该仓同名文件）。

**镜像对约束**：`.claude/hooks/lean_review.py` 在两仓**逐字节相同**（`md5 e2cd81a2…`）。
改任何一处必须同步另一处并重新核对 md5——与 `CLAUDE.md` / `AGENTS.md` 的做法一致。
脚本里与仓库相关的只有 `REPO`（从自身路径推导）。

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

### 2026-09-16 补充回归：三项边界修复

第二轮复审又发现三个与“审的是不是当前版本”直接相关的边界，均用临时 Git 仓做确定性复现后修复：

| 场景 | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| staged index 内容 A→B，但 worktree 字节不变 | fingerprint 不变，旧 token 可误签 | **PASS**：fingerprint 改变，旧 token `receipt` exit=1 | index blob identity 纳入 state-hash |
| `porcelain=v1 -z` rename/copy | 第二个 NUL 字段会被误当 status record，产生假路径 | **PASS**：`sample.swift → renamed.swift` 只得到 `renamed.swift` | 按 Git `-z` 双字段格式消费 original path |
| 已 BLOCK 后代码完全 revert 回 session baseline | `pending=true` 导致 `scope=0` 仍继续 BLOCK | **PASS**：SKIP，并清 `pending/block_count/paused` | 空 scope 代表当前已无未审代码义务 |

同时回归确认：会话前已有 dirty/staged 状态仍视为 baseline；本轮提交后 clean worktree 仍会 BLOCK；有效 receipt 可连续 PASS；审后再改仍会过期；pause 在 scope 非空时仍只放行一次并保留义务。

### 2026-09-16 最终复审：两项 Medium 修复

Claude 最终复审发现并确定性复现两项误差，均以最小修改关闭：

| 场景 | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| 有效 receipt 后只改 `README.md` / `.agent/handoff.md` | fingerprint 改变，误报 receipt 过期 | **PASS**：fingerprint 只纳入 `is_code(path)`，两次 Stop 仍 PASS | 非代码路径与 scope 策略一致 |
| Stop/SessionStart 内部异常 | uncaught traceback + 非 2 exit，Claude 放行且日志为空 | **PASS**：error 写入 `log.jsonl`、stderr 可见、hook 返回 0 | CLI 子命令异常仍返回 1，避免把 receipt/review-start 失败当成功 |

回归确认 staged index A→B（worktree 不变）仍改变 fingerprint；clean baseline 下 BLOCK 后完整 revert 仍清 pending 并 SKIP；`py_compile` 与两仓 `cmp` 均通过。

**实现期发现并修掉的两个真实缺陷**：
1. `changed_scope` 最初没减去会话基线，会把**会话开始前就存在的未提交改动**算成本轮变更 → 场景 2 必然误拦。改为按 (path, state-hash) 与基线比对。
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

- [x] 实现（`.claude/hooks/lean_review.py`，332 行，5 个子命令）
- [x] 七类场景实测（全部 PASS，见上表）
- [ ] 试点期观察
- [ ] 决定是否接入 mealnote

## 2026-09-16 独立收尾复审

审查基线：本仓 `a50cefe`（包含 `6393107`、`51cdd0e`），mealnote `44aa33b`（包含 `4e35733`）。接手时两仓工作区干净，hook 字节一致。

复现并最小修复两个 Medium：

1. 有效 receipt 后仅提交 `README.md`，原 fingerprint 因包含 HEAD 提交号而改变，误报过期。改为纳入 HEAD 中代码路径的树条目（路径、mode、对象 ID）；文档提交不影响指纹，真实代码和 staged index 变化仍使其失效。
2. `git mv sample.py retired.md` 会把代码删除误判为无代码变更。改名跨出代码范围时保留源代码路径；已提交范围用 `--no-renames -z` 保留删除端并正确处理带换行的文件名。copy 不视为删除源文件。

实现 diff：每仓 hook +10/-3；无业务代码、配置、规则或新机制改动。新增 `.claude/hooks/test_lean_review.py` 为隔离临时 Git 仓的回归测试，两个仓库使用相同测试。正式运行命令：`python3 .claude/hooks/test_lean_review.py`。

最终验证：

- 本仓 hook **24/24 PASS**；mealnote hook **24/24 PASS**。
- 五项指定问题均覆盖：staged-only 内容变化、真实 Git R/C NUL 双字段、完整 revert 清 pending、未暂存/暂存/已提交的非代码变更、内部 Git/Stop 异常及带换行 reason 的 JSONL 单行性。
- 另覆盖有效 receipt 连续通过、新文件使 receipt 过期、旧 token/缺失输出拒签、已有 dirty 基线、resume、不经审查提交、pause 义务保留与有界退出。
- `./scripts/test.sh`：构建、签名校验、Swift 自测 PASS。`51cdd0e` 的 bundle 版本读取 diff 已检查，未改业务代码。
- mealnote：`npm run lint`（0 errors / 2 历史 warnings）、`npm run typecheck`、`npm test`（22 files / 190 tests）、`npm run build` 均退出 0；本机 Node v23.10.0，未冒称重跑 Node 22 的 CI、数据库或外部服务验收。
- 两仓 hook 与测试 `py_compile`、`git diff --check`、hook `cmp`、测试文件 `cmp`：PASS。
- 新测试 Ruff PASS；原 hook 的 F401（unused `os`）在基线 `a50cefe` 已存在，按本轮禁止风格清理的范围保留。mealnote 两条未使用函数警告与 Vite 配置提示也未改。
- 外部 hook 输入按官方 JSON object 协议验收；非对象 JSON 属非法输入，未为此扩展防御机制。错误日志验证覆盖有效 payload 下的内部失败。

原始失败复现和最终输出：`/tmp/lean-pilot-final-5AD6vN/{before.log,codex-final.log,mealnote-final.log}`。可重跑的测试已入库，不依赖临时日志长期保留。

结论：两项新 Medium 已关闭，最终无剩余 blocking/Medium findings，本轮 pilot correctness 收尾通过。此结论不授权全局 rollout，也不声称 AI 审查判断必然正确；上方早期观察清单保留为历史记录。
