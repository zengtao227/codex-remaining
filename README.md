# Codex Remaining

![CI](https://github.com/zengtao227/codex-remaining/actions/workflows/ci.yml/badge.svg)

A tiny native macOS menu-bar app that keeps your Codex quota visible at a glance.

```text
⚡ 5h 84%  W 67%
```

Click the menu-bar item for 20-cell remaining-quota bars, reset countdowns, last-update status, manual refresh, Launch at Login, and quit.

## Why

Codex exposes 5-hour and weekly limits, but the official TUI status line is only visible while a Codex terminal session is open. Codex Remaining keeps the same two numbers visible wherever you are working.

## Install and launch

Codex Remaining is a menu-bar-only app. While it is running, it appears at the top of macOS; when you quit the process, the menu-bar item disappears.

For a normal installation, place `Codex Remaining.app` in `/Applications`, then launch it from Applications or Spotlight. From Terminal you can also use:

```bash
open -a "Codex Remaining"
```

During source development:

```bash
./scripts/build-app.sh
open "build/Codex Remaining.app"
```

### Launch at Login

Launch at Login is **off by default**. Enable it from the Codex Remaining menu when you want the app to return automatically after signing in to macOS.

V0.2.0 uses Apple's native `SMAppService.mainApp` API. If macOS requires approval, the menu shows that state and provides **Open Login Items Settings…**. No LaunchAgent or helper app is installed by Codex Remaining.

## Data source and privacy

Codex Remaining does not read Codex credential files, copy access tokens, scrape Codex SQLite logs, or call private ChatGPT backend endpoints.

Each refresh starts the locally installed Codex CLI briefly and asks its `app-server` for the read-only `account/rateLimits/read` result over stdio:

```text
Codex Remaining
      ↓
codex app-server --stdio
      ↓
initialize
      ↓
account/rateLimits/read
      ↓
map 300 min → 5h, 10080 min → weekly
      ↓
remaining = 100 - usedPercent
```

The child process is terminated after the response. No daemon, database, HTTP service, usage-history store, or disk cache is used.

## Refresh behavior

- on launch
- every **30 seconds**
- manual **Refresh**
- opening the menu never starts an overlapping refresh

A failed refresh keeps the last successful values in memory and shows the failure in the dropdown. Before the first successful read, unavailable values are shown as `--`.

Thirty seconds is intentionally the default because the 5-hour limit can change materially during heavy use. V1 host acceptance measured one short-lived app-server child per refresh at roughly one second end-to-end on one Apple Silicon Mac, 0.0% app idle CPU between refreshes, brief low-single-digit CPU during refresh, 40–55 MB RSS, and no leaked/zombie child processes during the observation window. This is one measured host, not a guarantee for every machine or future Codex CLI version.

## Requirements

- macOS 13 or later
- a working `codex` CLI with `app-server` and `account/rateLimits/read`
- Apple Command Line Tools or Xcode only if building from source

The app looks for `codex` in `CODEX_BIN`, the inherited `PATH`, common Homebrew/local install locations, and the CLI bundled in supported OpenAI desktop app locations.

## Build

```bash
./scripts/build-app.sh
```

The default build targets the current Mac architecture and produces:

```text
build/Codex Remaining.app
```

## Test

```bash
./scripts/test.sh
```

The test command builds the app and runs parser/business-rule self-tests without querying your Codex account.

## Package a release

The release package is one universal `arm64 + x86_64` archive:

```bash
./scripts/package-release.sh v0.2.1
```

Without Apple release credentials this produces an ad-hoc-signed validation package. The public release workflow supplies Developer ID/notarization credentials and fails closed if they are missing.

Expected assets:

```text
dist/Codex-Remaining-v0.2.1-universal.zip
dist/Codex-Remaining-v0.2.1-universal.zip.sha256
```

The packaging script rejects a tag that does not match `CFBundleShortVersionString`.

## Signing and notarization

The signed-distribution pipeline uses:

- **Developer ID Application** signing;
- Hardened Runtime;
- a secure signing timestamp;
- Apple's `notarytool` service;
- ticket stapling;
- Gatekeeper assessment of the final extracted archive.

Normal source/CI builds remain ad-hoc signed so contributors don't need Apple credentials. Public releases use the stricter path and do not fall back to ad-hoc signing.

Before creating a tag, the Release workflow can be run manually as a notarized dry-run. It signs/notarizes the candidate and uploads a workflow artifact without publishing a GitHub Release. A `v*` tag repeats the same checks and publishes only after they pass.

See [RELEASING.md](RELEASING.md) for credential setup and the release procedure. Do not disable Gatekeeper for this app.

## Current scope

Included:

- menu-bar remaining percentages for 5-hour and weekly windows
- 20-cell detail bars and reset countdowns
- 30-second refresh and manual refresh
- last-good values on transient failure
- native Launch at Login control
- universal release packaging
- tag-driven GitHub Release workflow
- Developer ID signing/notarization pipeline for public releases

Deliberately not included:

- notifications
- usage history/graphs
- monthly/credit UI
- settings/preferences window
- telemetry
- auto-update
- persistent app-server connection

## Security model

The app delegates authentication to the installed Codex CLI. It never parses or stores Codex credentials itself. Unknown response fields are ignored; unknown or missing limit windows degrade to `--` rather than being treated as zero.

## Project status

V0.2.0 is the current stable released baseline. V0.2.1 is the signed/notarized distribution candidate; it changes the release chain, not the quota/data architecture. The Codex `app-server` interface remains experimental and may change in future Codex releases.

## License

MIT
