# Codex Remaining

![CI](https://github.com/zengtao227/codex-remaining/actions/workflows/ci.yml/badge.svg)

**Current release:** [v0.2.0 — download the universal macOS build](https://github.com/zengtao227/codex-remaining/releases/tag/v0.2.0)

A tiny native macOS menu-bar app that keeps your Codex quota visible at a glance.

```text
⚡ 5h 84%  W 67%
```

Click the menu-bar item for 20-cell remaining-quota bars, reset countdowns, last-update status, manual refresh, Launch at Login, and quit.

## Why

Codex exposes 5-hour and weekly limits, but the official TUI status line is only visible while a Codex terminal session is open. Codex Remaining keeps the same two numbers visible wherever you are working.

## Install from GitHub Release

Codex Remaining is a menu-bar-only app. While it is running, it appears at the top of macOS; when you quit the process, the menu-bar item disappears.

1. Download both files from the [v0.2.0 GitHub Release](https://github.com/zengtao227/codex-remaining/releases/tag/v0.2.0):

   ```text
   Codex-Remaining-v0.2.0-universal.zip
   Codex-Remaining-v0.2.0-universal.zip.sha256
   ```

2. Optional but recommended: verify the downloaded archive before opening it.

   ```bash
   cd ~/Downloads
   shasum -a 256 -c Codex-Remaining-v0.2.0-universal.zip.sha256
   ```

   A successful verification ends with:

   ```text
   Codex-Remaining-v0.2.0-universal.zip: OK
   ```

3. Double-click the zip, then move `Codex Remaining.app` into `/Applications`.

4. Launch **Codex Remaining** from Applications or Spotlight. It appears in the macOS menu bar rather than the Dock.

### First launch and macOS Gatekeeper

The current v0.2.0 release is **ad-hoc signed and not Apple-notarized**. macOS may therefore block the first launch because it cannot verify an identified developer/notarization ticket.

Only override that warning if you downloaded the app from this repository's official GitHub Release and you trust the download. Verifying the SHA-256 checksum above provides an additional integrity check against the published release asset.

If macOS blocks the app:

1. Try to open `Codex Remaining.app` once.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section and choose **Open Anyway** for Codex Remaining.
4. Confirm **Open** when macOS asks again.

Apple documents this exception flow for apps that have not been notarized or are from an unidentified developer: <https://support.apple.com/102445>.

macOS then remembers that exception for the app, so subsequent launches can be done normally from Applications or Spotlight. Apple notes that **Open Anyway** is available for about an hour after the blocked launch attempt.

Do **not** disable Gatekeeper globally and do not remove quarantine attributes just to run Codex Remaining. On managed Macs, your organization may prevent security overrides; follow your administrator's policy in that case.

### Launch at Login

Launch at Login is **off by default**. After the app is running, open the Codex Remaining menu and enable **Launch at Login** if you want it to return automatically after signing in to macOS.

V0.2.0 uses Apple's native `SMAppService.mainApp` API. If macOS requires approval, the menu shows that state and provides **Open Login Items Settings…**. No LaunchAgent or helper app is installed by Codex Remaining.

### Launch from Terminal

After installing into `/Applications`:

```bash
open -a "Codex Remaining"
```

During source development:

```bash
./scripts/build-app.sh
open "build/Codex Remaining.app"
```

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

The current v0.2.0 public release is **ad-hoc signed**, not Developer ID signed or Apple-notarized. That is sufficient for development and host acceptance, but it means a freshly downloaded copy may require the one-time **Open Anyway** flow described above.

Developer ID signing/notarization is intentionally deferred. Do not disable Gatekeeper or remove quarantine attributes for this app; use macOS's per-app security exception only if you trust and have verified the official release download.

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

V0.2.0 is the current stable release. Quota display, 30-second refresh, Launch at Login, universal packaging, and the GitHub Release flow are host-accepted. Developer ID signing/notarization is deferred; the current release therefore uses the documented one-time Gatekeeper exception flow. The Codex `app-server` interface remains experimental and may change in future Codex releases.

## License

MIT
