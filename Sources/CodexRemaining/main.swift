import AppKit
import Foundation
import ServiceManagement
import Darwin

private let refreshInterval: TimeInterval = 30
private let fetchTimeout: TimeInterval = 8
private let fiveHourMinutes = 300
private let weeklyMinutes = 10_080

// MARK: - Usage model

private struct UsageWindow: Equatable {
    let remainingPercent: Int
    let resetsAt: Date?
}

private struct UsageSnapshot: Equatable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

private struct RPCEnvelope: Decodable {
    let result: RateLimitsResult?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let code: Int?
    let message: String?
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
}

private struct RateLimitBucket: Decodable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

private enum UsageError: LocalizedError {
    case codexNotFound
    case launchFailed
    case timedOut
    case noResponse
    case rpc(String)
    case unsupportedResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex CLI not found"
        case .launchFailed:
            return "Could not start Codex app-server"
        case .timedOut:
            return "Codex usage query timed out"
        case .noResponse:
            return "Codex app-server returned no usage response"
        case .rpc(let message):
            return "Codex app-server error: \(message)"
        case .unsupportedResponse:
            return "Unsupported Codex rate-limit response"
        }
    }
}

private func clampRemaining(from usedPercent: Double) -> Int {
    let remaining = max(0, min(100, 100 - usedPercent))
    return Int(remaining.rounded())
}

private func parseUsageResponse(_ data: Data) throws -> UsageSnapshot {
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)

    if let rpcError = envelope.error {
        throw UsageError.rpc(rpcError.message ?? "unknown error")
    }

    guard let result = envelope.result else {
        throw UsageError.unsupportedResponse
    }

    let preferredBucket = result.rateLimitsByLimitId?["codex"]
        ?? result.rateLimitsByLimitId?.values.first(where: { $0.limitId == "codex" })
        ?? result.rateLimits

    guard let bucket = preferredBucket else {
        throw UsageError.unsupportedResponse
    }

    var fiveHour: UsageWindow?
    var weekly: UsageWindow?

    for window in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
        guard let duration = window.windowDurationMins,
              let usedPercent = window.usedPercent else {
            continue
        }

        let quota = UsageWindow(
            remainingPercent: clampRemaining(from: usedPercent),
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )

        switch duration {
        case fiveHourMinutes:
            fiveHour = quota
        case weeklyMinutes:
            weekly = quota
        default:
            break
        }
    }

    return UsageSnapshot(fiveHour: fiveHour, weekly: weekly)
}

// MARK: - Codex app-server client

private final class JSONLineWaiter {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var response: Data?
    private var finished = false

    func append(_ data: Data) {
        var shouldSignal = false

        lock.lock()
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)

            guard !line.isEmpty else { continue }
            guard isTargetResponse(line) else { continue }

            response = line
            finished = true
            shouldSignal = true
            break
        }
        lock.unlock()

        if shouldSignal {
            semaphore.signal()
        }
    }

    func finishEOF() {
        lock.lock()
        let shouldSignal = !finished
        finished = true
        lock.unlock()

        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) throws -> Data {
        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            throw UsageError.timedOut
        }

        lock.lock()
        let value = response
        lock.unlock()

        guard let value else {
            throw UsageError.noResponse
        }
        return value
    }

    private func isTargetResponse(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? NSNumber else {
            return false
        }
        return id.intValue == 2
    }
}

private struct CodexClient {
    func fetch() throws -> UsageSnapshot {
        guard let codexURL = findCodexExecutable() else {
            throw UsageError.codexNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let waiter = JSONLineWaiter()

        process.executableURL = codexURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                waiter.finishEOF()
            } else {
                waiter.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw UsageError.launchFailed
        }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-remaining","version":"0.2.0"}}}"#
        let readLimits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#

        do {
            try writeJSONLine(initialize, to: input.fileHandleForWriting)
            try writeJSONLine(readLimits, to: input.fileHandleForWriting)
        } catch {
            throw UsageError.noResponse
        }

        let response = try waiter.wait(timeout: fetchTimeout)
        return try parseUsageResponse(response)
    }

    private func writeJSONLine(_ line: String, to handle: FileHandle) throws {
        guard let data = (line + "\n").data(using: .utf8) else {
            throw UsageError.noResponse
        }
        try handle.write(contentsOf: data)
    }

    private func findCodexExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        if let override = environment["CODEX_BIN"], fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        var directories = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        let home = fileManager.homeDirectoryForCurrentUser.path
        directories.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("codex").path
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // The macOS desktop apps bundle a compatible Codex CLI even when the
        // user's shell PATH is not inherited by a GUI-launched menu-bar app.
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        for relativePath in [
            "Chat" + "GPT.app/Contents/Resources/codex",
            "Codex.app/Contents/Resources/codex"
        ] {
            let url = applications.appendingPathComponent(relativePath)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}

// MARK: - Presentation helpers

private func progressBar(remainingPercent: Int) -> String {
    let clamped = max(0, min(100, remainingPercent))
    let filled = Int((Double(clamped) / 5.0).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
}

private func resetCountdown(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "reset unavailable" }

    let totalSeconds = max(0, Int(date.timeIntervalSince(now)))
    let totalMinutes = totalSeconds / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours >= 24 {
        return "resets in \(hours / 24)d \(hours % 24)h"
    }
    return "resets in \(hours)h \(String(format: "%02d", minutes))m"
}

private func percentText(_ window: UsageWindow?) -> String {
    guard let window else { return "--" }
    return "\(window.remainingPercent)%"
}

// MARK: - Menu bar app

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = CodexClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let titleItem = NSMenuItem(title: "Codex Remaining", action: nil, keyEquivalent: "")
    private let fiveHourItem = NSMenuItem(title: "5h      --", action: nil, keyEquivalent: "")
    private let fiveHourResetItem = NSMenuItem(title: "        reset unavailable", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "Weekly  --", action: nil, keyEquivalent: "")
    private let weeklyResetItem = NSMenuItem(title: "        reset unavailable", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "Last updated --", action: nil, keyEquivalent: "")
    private let failureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let loginSettingsItem = NSMenuItem(title: "Open Login Items Settings…", action: nil, keyEquivalent: "")
    private let loginNoticeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var snapshot: UsageSnapshot?
    private var lastSuccessfulUpdate: Date?
    private var lastAttempt: Date?
    private var refreshInFlight = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        updateLaunchAtLoginMenu()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenu()

        guard let lastAttempt else {
            refresh()
            return
        }
        if Date().timeIntervalSince(lastAttempt) >= refreshInterval {
            refresh()
        }
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                break
            }
            loginNoticeItem.isHidden = true
        } catch {
            loginNoticeItem.title = "⚠︎ Launch at Login: \(error.localizedDescription)"
            loginNoticeItem.isHidden = false
        }

        updateLaunchAtLoginMenu(preserveError: true)
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = "⚡ 5h --  W --"
        button.toolTip = "Codex Remaining"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        [titleItem, fiveHourItem, fiveHourResetItem, weeklyItem, weeklyResetItem, updatedItem, failureItem].forEach {
            $0.isEnabled = false
        }
        failureItem.isHidden = true

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        launchAtLoginItem.isEnabled = true

        loginSettingsItem.action = #selector(openLoginItemsSettings)
        loginSettingsItem.target = self
        loginSettingsItem.isEnabled = true
        loginSettingsItem.isHidden = true

        loginNoticeItem.isEnabled = false
        loginNoticeItem.isHidden = true

        let quitItem = NSMenuItem(title: "Quit Codex Remaining", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true

        menu.addItem(titleItem)
        menu.addItem(.separator())
        menu.addItem(fiveHourItem)
        menu.addItem(fiveHourResetItem)
        menu.addItem(.separator())
        menu.addItem(weeklyItem)
        menu.addItem(weeklyResetItem)
        menu.addItem(.separator())
        menu.addItem(updatedItem)
        menu.addItem(failureItem)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(loginSettingsItem)
        menu.addItem(loginNoticeItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    private func updateLaunchAtLoginMenu(preserveError: Bool = false) {
        let status = SMAppService.mainApp.status

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.isEnabled = true
        loginSettingsItem.isHidden = true
        if !preserveError {
            loginNoticeItem.isHidden = true
        }

        switch status {
        case .enabled:
            launchAtLoginItem.state = .on
        case .notRegistered:
            launchAtLoginItem.state = .off
        case .requiresApproval:
            launchAtLoginItem.state = .mixed
            loginSettingsItem.isHidden = false
            if !preserveError || loginNoticeItem.isHidden {
                loginNoticeItem.title = "Login launch needs approval in System Settings"
                loginNoticeItem.isHidden = false
            }
        case .notFound:
            // ServiceManagement can report notFound before it has ever seen
            // this main-app login item. Keep the control actionable and let
            // register() surface a concrete error if registration is invalid.
            launchAtLoginItem.state = .off
        @unknown default:
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = false
            if !preserveError || loginNoticeItem.isHidden {
                loginNoticeItem.title = "Launch at Login status is unavailable"
                loginNoticeItem.isHidden = false
            }
        }
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        lastAttempt = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let newSnapshot = try self.client.fetch()
                DispatchQueue.main.async {
                    self.applySuccess(newSnapshot)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.applyFailure(message)
                }
            }
        }
    }

    private func applySuccess(_ newSnapshot: UsageSnapshot) {
        snapshot = newSnapshot
        lastSuccessfulUpdate = Date()
        refreshInFlight = false
        failureItem.isHidden = true
        updateDisplay()
    }

    private func applyFailure(_ message: String) {
        refreshInFlight = false
        failureItem.title = "⚠︎ \(message)"
        failureItem.isHidden = false
        updateDisplay()
    }

    private func updateDisplay() {
        let fiveHour = snapshot?.fiveHour
        let weekly = snapshot?.weekly

        statusItem.button?.title = "⚡ 5h \(percentText(fiveHour))  W \(percentText(weekly))"

        if let fiveHour {
            fiveHourItem.title = "5h      \(progressBar(remainingPercent: fiveHour.remainingPercent)) \(fiveHour.remainingPercent)%"
            fiveHourResetItem.title = "        \(resetCountdown(fiveHour.resetsAt))"
        } else {
            fiveHourItem.title = "5h      --"
            fiveHourResetItem.title = "        reset unavailable"
        }

        if let weekly {
            weeklyItem.title = "Weekly  \(progressBar(remainingPercent: weekly.remainingPercent)) \(weekly.remainingPercent)%"
            weeklyResetItem.title = "        \(resetCountdown(weekly.resetsAt))"
        } else {
            weeklyItem.title = "Weekly  --"
            weeklyResetItem.title = "        reset unavailable"
        }

        if let lastSuccessfulUpdate {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            updatedItem.title = "Last updated \(formatter.string(from: lastSuccessfulUpdate))"
        } else {
            updatedItem.title = "Last updated --"
        }
    }
}

// MARK: - Self-tests

private enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SelfTestFailure.failed(message)
    }
}

private func runSelfTests() -> Int32 {
    do {
        let preferred = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":3000}}}}}"#
        let snapshot = try parseUsageResponse(Data(preferred.utf8))
        try require(snapshot.fiveHour?.remainingPercent == 75, "5h remaining should be 75%")
        try require(snapshot.weekly?.remainingPercent == 60, "weekly remaining should be 60%")
        try require(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 2000), "5h reset should come from codex bucket")

        let fallback = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":-5,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":105,"windowDurationMins":10080,"resetsAt":2000}}}}"#
        let fallbackSnapshot = try parseUsageResponse(Data(fallback.utf8))
        try require(fallbackSnapshot.fiveHour?.remainingPercent == 100, "remaining must clamp to 100%")
        try require(fallbackSnapshot.weekly?.remainingPercent == 0, "remaining must clamp to 0%")

        let missingWindow = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":60,"resetsAt":1000},"secondary":null}}}}"#
        let missingSnapshot = try parseUsageResponse(Data(missingWindow.utf8))
        try require(missingSnapshot.fiveHour == nil, "unknown duration must not be treated as 5h")
        try require(missingSnapshot.weekly == nil, "missing weekly window must stay unavailable")

        try require(progressBar(remainingPercent: 50) == "██████████░░░░░░░░░░", "50% bar should contain 10 filled cells")
        try require(progressBar(remainingPercent: 100).count == 20, "progress bar must always contain 20 cells")

        print("PASS: Codex Remaining self-tests")
        return 0
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        return 1
    }
}

if CommandLine.arguments.contains("--self-test") {
    Darwin.exit(runSelfTests())
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
