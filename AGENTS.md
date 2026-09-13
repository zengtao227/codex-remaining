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

V1 is complete and host-accepted.

V1.1 adds only the concrete distribution/startup needs that now exist:

1. menu-bar text `⚡ 5h NN%  W NN%` and existing V1 details;
2. native `Launch at Login` using `SMAppService.mainApp`, default off;
3. visible approval state with a shortcut to macOS Login Items settings when required;
4. universal release packaging for arm64 + x86_64;
5. tag-driven GitHub Release packaging.

Do not add a helper login app, LaunchAgent, settings window, notifications, history, monthly usage, credits UI, telemetry, auto-update, or account switching without a concrete user request.

Prefer deleting/simplifying over adding abstractions. Keep the main implementation in one Swift source file until a real maintenance or correctness problem justifies splitting it.

## Safety

- Never log raw app-server payloads, prompts, account identifiers, or credential material.
- Unknown fields must be ignored.
- Unknown/missing quota windows must degrade to `--` without crashing.
- A transient fetch failure must not erase last-good values.

## Validation

- `./scripts/build-app.sh` builds the `.app` using the installed Apple toolchain.
- `./scripts/test.sh` builds then runs the binary's in-process parser/self-tests.
- `./scripts/package-release.sh vX.Y.Z` must reject a tag that does not match `Info.plist` and produce a universal zip + SHA-256 checksum when run on macOS.
- Login startup must use ServiceManagement only; verify register/unregister/status on a real Mac before tagging a release.
- Do not install packages as part of build or test.
- The user has authorized normal commit/push for this project; never force-push or rewrite history.
