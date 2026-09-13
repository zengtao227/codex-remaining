# Codex Remaining

![CI](https://github.com/zengtao227/codex-remaining/actions/workflows/ci.yml/badge.svg)

A tiny native macOS menu-bar app that keeps your Codex quota visible at a glance.

```text
⚡ 5h 84%  W 67%
```

Click the menu-bar item for 20-cell remaining-quota bars, reset countdowns, last-update status, manual refresh, and quit.

## Why

Codex already exposes 5-hour and weekly limits, but the official TUI status line is only visible while a Codex terminal session is open. Codex Remaining keeps the same two numbers visible wherever you are working.

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
- opening the menu never starts a duplicate refresh while one is already running

A failed refresh keeps the last successful values in memory and shows the failure in the dropdown. Before the first successful read, unavailable values are shown as `--`.

Thirty seconds is intentionally the default: the 5-hour limit can change materially during heavy use, while one short metadata query every 30 seconds is a very small workload on a modern Mac. There is no permanently running Codex child process.

## Requirements

- macOS 13 or later
- Apple Command Line Tools or Xcode to build from source
- a working `codex` CLI with `app-server` and `account/rateLimits/read`

The app looks for `codex` in `CODEX_BIN`, the inherited `PATH`, common Homebrew/local install locations, and the CLI bundled inside `/Applications/ChatGPT.app` or `/Applications/Codex.app`.

## Build

```bash
./scripts/build-app.sh
```

The built app is placed at:

```text
build/Codex Remaining.app
```

Launch it with:

```bash
open "build/Codex Remaining.app"
```

## Test

```bash
./scripts/test.sh
```

The test command builds the app and runs parser/business-rule self-tests without querying your Codex account.

## Current V1 scope

Included:

- menu-bar remaining percentages for 5-hour and weekly windows
- 20-cell detail bars
- reset countdowns
- 30-second refresh
- last-good values on transient failure
- manual refresh

Deliberately not included:

- login-at-startup
- notifications
- usage history/graphs
- monthly/credit UI
- settings/preferences
- telemetry
- auto-update

## Security model

The app delegates authentication to the installed Codex CLI. It never parses or stores Codex credentials itself. Unknown response fields are ignored; unknown or missing limit windows degrade to `--` rather than being treated as zero.

## Project status

Early V1. The Codex `app-server` interface is experimental and may change in future Codex releases. The app is intentionally small so compatibility fixes remain easy to audit.

## License

MIT
