# AGENTS.md

## Product

Codex Remaining is a tiny native macOS menu-bar utility that shows remaining Codex quota for the 5-hour and weekly windows.

## Non-negotiable architecture

- Native Swift + AppKit `NSStatusItem`.
- Read quota only through the locally installed Codex CLI: `codex app-server --stdio` → JSON-RPC `account/rateLimits/read`.
- Never read `~/.codex/auth.json`, copy credentials, call private ChatGPT backend endpoints, scrape Codex SQLite/logs, or modify Codex configuration.
- Prefer `rateLimitsByLimitId["codex"]`; fall back to legacy `rateLimits`.
- Identify windows by `windowDurationMins`: 300 = 5h; 10080 = weekly.
- Display remaining quota: `clamp(100 - usedPercent, 0...100)`. Missing/null means unavailable (`--`), never zero.
- Default refresh interval is 30 seconds.
- Each refresh gets a short-lived app-server process. Do not add a daemon, persistent app-server connection, HTTP server, database, disk usage cache, Electron, Node service, or Accessibility dependency.
- Keep last successful values in memory when a refresh fails.

## Scope discipline

V1 needs only:

1. menu-bar text `⚡ 5h NN%  W NN%`;
2. click-to-open 20-cell bars and reset countdowns;
3. last-updated / failure state;
4. manual Refresh;
5. Quit.

Do not add settings, notifications, history, monthly usage, credits UI, telemetry, auto-update, login startup, or account switching without a concrete user request.

Prefer deleting/simplifying over adding abstractions. Keep the main implementation in one Swift source file until a real maintenance or correctness problem justifies splitting it.

## Safety

- Never log raw app-server payloads, prompts, account identifiers, or credential material.
- Unknown fields must be ignored.
- Unknown/missing quota windows must degrade to `--` without crashing.
- A transient fetch failure must not erase last-good values.

## Validation

- `./scripts/build-app.sh` builds the `.app` using the installed Apple toolchain.
- `./scripts/test.sh` builds then runs the binary's in-process parser/self-tests.
- Do not install packages as part of build or test.
- Do not commit/push unless explicitly requested.
