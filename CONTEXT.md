# Codex Remaining — Context

## Product

Codex Remaining is a native macOS menu-bar app that keeps Codex 5-hour and weekly **remaining** quota visible outside the Codex TUI.

Primary UX:

```text
⚡ 5h 84%  W 67%
```

## V1 status

V1 is complete and host-accepted.

Verified on a real Apple Silicon Mac with codex-cli 0.147.0:

- native AppKit menu-bar UI works;
- real `account/rateLimits/read` data matches the displayed 5h/weekly remaining values;
- 30-second refresh works without overlap or leaked child processes;
- one-shot app-server child lifetime is roughly one second on the measured host;
- idle CPU is effectively zero between refreshes and RSS remained stable during the acceptance window;
- transient failures preserve last-good values;
- GitHub macOS CI builds and runs the parser/business-rule self-tests.

Do not reopen the V1 quota/data architecture without a concrete regression.

## Core architecture

### Native menu bar

Use AppKit `NSStatusItem`. `LSUIElement=true` keeps the app out of the Dock and presents it as a menu-bar utility.

### Codex data boundary

Use the installed Codex CLI as the authentication/data boundary:

```text
codex app-server --stdio
  → initialize
  → account/rateLimits/read
```

Never parse Codex credential files, call private ChatGPT endpoints, or scrape local databases/logs.

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

### Refresh lifecycle

Refresh on launch, every 30 seconds, and manually. Each refresh starts one short-lived `codex app-server` child and terminates it after receiving the target JSON-RPC response. The measured V1 host behavior is good enough that there is no current requirement for a persistent app-server connection.

### Last-good behavior

Transient failures retain the last successful snapshot in memory. There is no disk usage cache.

## V1.1 — Distribution and startup UX

V1.1 addresses the concrete product gap discovered after V1: the menu-bar item exists only while the app process is running, and ordinary users should not need to clone/build the project to use it.

### Launch at Login

Use macOS 13+ `ServiceManagement.SMAppService.mainApp`.

Requirements:

- default OFF; never silently register the app;
- menu item reflects the real ServiceManagement state;
- enabled → checked;
- not registered → unchecked;
- requires approval → mixed state plus a visible route to macOS Login Items settings;
- `notFound` remains actionable because ServiceManagement can report it before the system has seen the main-app login item; registration then provides the concrete success/error result;
- unknown future state → disabled with a concise explanation;
- register/unregister failures are surfaced in the menu;
- no LaunchAgent and no helper login app.

The menu state is refreshed whenever the menu opens so changes made in System Settings are reflected immediately.

### Installation model

Normal-user flow:

```text
GitHub Release zip
  → unzip
  → move Codex Remaining.app to /Applications
  → launch from Applications / Spotlight
  → optionally enable Launch at Login from the menu
```

Manual developer launch remains:

```bash
open "build/Codex Remaining.app"
```

### Release packaging

V0.2.0 is the stable released baseline. The signed-distribution candidate is `0.2.1` / build 3; it changes distribution only, not app behavior.

Release packaging produces one universal `arm64 + x86_64` archive so users do not choose an architecture.

Expected asset shape:

```text
dist/Codex-Remaining-v0.2.1-universal.zip
dist/Codex-Remaining-v0.2.1-universal.zip.sha256
```

### Developer ID signing and notarization

Normal source/CI builds remain ad-hoc signed. Public releases must fail closed unless the release workflow has Apple credentials.

The public release path must:

1. import one Developer ID Application `.p12` into a temporary CI keychain;
2. build the universal app;
3. sign with Developer ID Application, Hardened Runtime, and secure timestamp;
4. verify the signature before upload;
5. submit a temporary zip with `notarytool --wait` using an App Store Connect Team API key;
6. require Apple status `Accepted`;
7. staple and validate the ticket on the app;
8. run Gatekeeper assessment;
9. build the public zip only after stapling;
10. re-extract that exact archive and repeat signature, universal-architecture, staple, and Gatekeeper checks.

The workflow supports a manual dry-run that uploads a notarized workflow artifact without creating a GitHub Release. Create the version tag only after that dry-run and a real-Mac launch/Gatekeeper check pass.

Never commit `.p12`/`.p8` credentials, disable Hardened Runtime/Gatekeeper checks, or fall back to ad-hoc signing for a public release.

## Explicitly out of scope for V1.1

- persistent app-server connection
- daemon/service architecture
- LaunchAgent
- helper login app
- settings/preferences window
- notifications
- usage history/graphs
- monthly quota or credits UI
- telemetry
- auto updater
- multi-account support

## Implementation shape

Keep the implementation deliberately small:

```text
Sources/CodexRemaining/main.swift
Info.plist
scripts/build-app.sh
scripts/test.sh
scripts/package-release.sh
.github/workflows/ci.yml
.github/workflows/release.yml
```

Do not split the Swift source into service/controller/repository layers until a concrete maintenance or correctness problem requires it.

## Compatibility risk

`codex app-server` remains experimental. The proportionate compatibility strategy is tolerant decoding and graceful unavailable/error states, not a version matrix or compatibility framework.
