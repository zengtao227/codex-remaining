# Codex Remaining — Context

## Problem

Codex exposes 5-hour and weekly usage limits, but the official TUI display is session-bound. The desired experience is an always-visible macOS menu-bar indicator that can be glanced at while working in any app.

Primary UX:

```text
⚡ 5h 84%  W 67%
```

The percentages are **remaining**, not consumed.

## Product decisions

### Native menu bar, not a floating window

Use AppKit `NSStatusItem`. A menu-bar item is always visible, requires no window tracking, and directly matches the two-number requirement.

Do not attach to the Codex desktop pet, use Accessibility, or create a floating HUD unless a future concrete requirement justifies it.

### Official local Codex data path

Use the installed Codex CLI as the authentication/data boundary:

```text
codex app-server --stdio
  → initialize
  → account/rateLimits/read
```

Do not parse Codex credential files, call private ChatGPT endpoints, or scrape local databases/logs.

### Window mapping

Prefer `rateLimitsByLimitId["codex"]`; fall back to legacy `rateLimits`.

Map by duration, never by primary/secondary position:

- `300` minutes → 5-hour window
- `10080` minutes → weekly window

For each recognized window:

```text
remaining = clamp(100 - usedPercent, 0...100)
```

Null/missing values mean unavailable and render as `--`.

### 30-second refresh

The default refresh interval is 30 seconds. This is deliberately more frequent than a typical 5-minute quota poll because the 5-hour remaining percentage can change quickly during heavy use, especially near the limit.

The cost remains bounded: one short-lived `codex app-server` process, two JSON-RPC requests, response parsing, then termination. There is no persistent Codex child process.

If later measurement on real hardware shows meaningful cost, change the single refresh constant based on evidence rather than adding adaptive scheduling pre-emptively.

### Last-good behavior

Transient failures keep the last successful values in memory. The detail menu shows the failure while retaining useful quota numbers.

No disk cache in V1. After app restart, if no fresh read succeeds, values are `--`.

## V1 scope

Required:

1. `⚡ 5h NN%  W NN%` menu-bar text.
2. 20-cell remaining bars in the dropdown.
3. Reset countdown for each known window.
4. Refresh on launch and every 30 seconds.
5. Manual Refresh.
6. Last successful update timestamp.
7. Preserve last-good values on transient failure.
8. Quit.

Explicitly out of scope:

- login item / LaunchAgent
- notifications
- graphs/history
- monthly quota or credit/banked-reset UI
- settings/preferences
- telemetry
- auto updater
- multi-account support
- daemon/service architecture
- persistent app-server connection

## Implementation shape

Keep V1 deliberately small:

```text
Sources/CodexRemaining/main.swift
Info.plist
scripts/build-app.sh
scripts/test.sh
```

The single Swift source contains three straightforward sections:

1. response model/parser;
2. short-lived Codex app-server query;
3. AppKit menu-bar controller.

Do not split these into service/controller/repository abstractions until actual code growth or testing pressure demonstrates a need.

## Failure policy

- Codex executable unavailable → show `--`, surface concise error in dropdown.
- Query timeout → keep last-good values if present.
- RPC error → keep last-good values if present.
- Expected response structure unavailable → do not crash; show unavailable values if there is no last-good state.
- Extra/unknown response fields → ignore.
- Unknown duration buckets → ignore.

## Compatibility risk

`codex app-server` is currently experimental. The proportionate compatibility strategy is tolerant decoding plus graceful unavailable/error states, not a version matrix or compatibility framework.

## Public-project intent

The repository is intended to be understandable and auditable by other Codex users. Security/privacy claims should remain narrow and factual: the application delegates credential handling to Codex and does not implement its own authentication path.
