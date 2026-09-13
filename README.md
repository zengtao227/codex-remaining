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

V0.2.0 adds a universal `arm64 + x86_64` package for distribution:

```bash
./scripts/package-release.sh v0.2.0
```

It produces:

```text
dist/Codex-Remaining-v0.2.0-universal.zip
dist/Codex-Remaining-v0.2.0-universal.zip.sha256
```

The packaging script rejects a tag that does not match `CFBundleShortVersionString`.

A push of a matching `v*` tag triggers `.github/workflows/release.yml`, runs the self-tests, builds the universal archive, and publishes the archive plus SHA-256 checksum to the GitHub Release.

## Signing and notarization

Current local and CI builds are **ad-hoc signed**, not Developer ID signed/notarized. That is sufficient for development and host acceptance, but macOS Gatekeeper may require additional user approval for a downloaded public release.

Do not disable Gatekeeper for this app. A future distribution step can add Developer ID signing and Apple notarization once the required Apple Developer credentials are available.

## Current scope

Included in V0.2.0:

- menu-bar remaining percentages for 5-hour and weekly windows
- 20-cell detail bars and reset countdowns
- 30-second refresh and manual refresh
- last-good values on transient failure
- native Launch at Login control
- universal release packaging
- tag-driven GitHub Release workflow

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

V1 quota display and refresh behavior are host-accepted. V0.2.0 adds startup/distribution UX. The Codex `app-server` interface remains experimental and may change in future Codex releases.

## License

MIT
