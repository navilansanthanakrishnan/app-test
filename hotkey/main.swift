// netcut-hotkey - ⌘9 cuts the network of the application you are in.
//
// A menu-bar agent, no window and no Dock tile. The hotkey is a Carbon
// RegisterEventHotKey, which the window server dispatches before the focused
// app sees the key, so ⌘9 works everywhere and needs no Accessibility grant.
//
// Pressing it returns at once: the indicator in the menu bar turns blue on the
// main thread before anything slow starts, and the cut itself runs as a child
// `netcut` process. Blue means the app's network is down; it clears the moment
// netcutd reports the block lifted.
//
// Target is whatever app is frontmost, or one pinned from the Target menu.

import AppKit
import Carbon.HIToolbox

// MARK: - environment

let home = FileManager.default.homeDirectoryForCurrentUser.path
let logPath = "\(home)/Library/Logs/netcut-hotkey.log"
let pinPath = "\(home)/.config/netcut/target"
let hotKeyLabel = "⌘9"

/// What ⌘9 is attached to, as `netcut pin` left it. Read on every press
/// rather than cached, so a pin set in a shell takes effect immediately.
func loadPinnedTarget() -> Target {
    guard let raw = try? String(contentsOfFile: pinPath, encoding: .utf8) else { return .frontmost }
    let spec = raw.split(separator: "\n").first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    if spec.isEmpty || spec == "frontmost" { return .frontmost }
    var name = (spec as NSString).lastPathComponent
    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    return .pinned(bundlePath: spec, name: name)
}

func savePinnedTarget(_ target: Target) {
    let spec: String
    switch target {
    case .frontmost: spec = "frontmost"
    case .pinned(let path, _): spec = path
    }
    let url = URL(fileURLWithPath: pinPath)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? (spec + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: logPath)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
    FileHandle.standardOutput.write(data)
}

func netcutExecutable() -> String? {
    let candidates = [
        "\(home)/.local/bin/netcut",
        "\(home)/.local/libexec/netcut/netcut",
        "/usr/local/bin/netcut",
    ]
    for path in candidates {
        var resolved = path
        while let link = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved) {
            resolved = link.hasPrefix("/") ? link
                : URL(fileURLWithPath: resolved).deletingLastPathComponent()
                    .appendingPathComponent(link).path
        }
        if FileManager.default.isExecutableFile(atPath: resolved) { return path }
    }
    return nil
}

/// Only one agent at a time. The app can be launched from Spotlight while the
/// background copy is already running, and two of them would fight over ⌘9 —
/// the second registration simply fails and the dot would be dead. The second
/// copy takes the hint and exits.
nonisolated(unsafe) var lockDescriptor: Int32 = -1

func claimSingleInstance() -> Bool {
    let dir = "\(home)/.config/netcut"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fd = open("\(dir)/agent.lock", O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }          // cannot lock: do not block startup
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
    lockDescriptor = fd                          // held for the life of the process
    return true
}

// MARK: - agent

enum Target: Equatable {
    case frontmost
    case pinned(bundlePath: String, name: String)

    var describedTarget: String {
        switch self {
        case .frontmost: return "the frontmost app"
        case .pinned(_, let name): return name
        }
    }
}

/// What the dot means, and nothing else: blue is "that app's network is down
/// right now", grey is "it is connected". Never a progress light.
enum Indicator {
    case connected
    case down(String)
    case failed(String)
}

@MainActor
final class Agent: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "netcut", action: nil, keyEquivalent: "")
    private let cutItem = NSMenuItem(title: "Cut Now", action: nil, keyEquivalent: "")
    private let targetItem = NSMenuItem(title: "Target", action: nil, keyEquivalent: "")
    private let holdItem = NSMenuItem(title: "Hold", action: nil, keyEquivalent: "")

    private var indicator: Indicator = .connected
    private var target: Target = .frontmost
    private var hold = "asap"
    private var lastFrontmost: NSRunningApplication?
    private var cutInFlight = false
    private var lastResult = "no cut yet"
    private var lastTargetName = "that app"
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyWorks = false
    private var revertWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var watchdog: DispatchWorkItem?

    private var cutStarted = Date.distantPast
    private var statusPoll: Timer?
    private var runningProcess: Process?
    private var selfTerminated = false

    func run() {
        guard claimSingleInstance() else {
            logLine("another netcut agent is already running; this copy is exiting")
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        target = loadPinnedTarget()
        buildMenu()
        trackFrontmostApp()
        registerHotKey()
        installSignalHandlers()
        render()
        logLine("started (netcut=\(netcutExecutable() ?? "NOT FOUND"), hotkey=\(hotKeyWorks ? "\(hotKeyLabel) registered" : "FAILED"))")
        NSApplication.shared.run()
    }

    // MARK: menu

    private func buildMenu() {
        menu.delegate = self
        statusLine.isEnabled = false
        cutItem.target = self
        cutItem.action = #selector(cutNow)
        targetItem.submenu = NSMenu()
        holdItem.submenu = NSMenu()

        let restore = NSMenuItem(title: "Restore Network Now", action: #selector(restoreNow), keyEquivalent: "")
        restore.target = self
        let openLog = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        let quit = NSMenuItem(title: "Quit netcut Hotkey", action: #selector(quit), keyEquivalent: "")
        quit.target = self

        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(cutItem)
        menu.addItem(targetItem)
        menu.addItem(holdItem)
        menu.addItem(.separator())
        menu.addItem(restore)
        menu.addItem(openLog)
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        target = loadPinnedTarget()
        statusLine.title = menuHeadline
        if case .down(let name) = indicator {
            cutItem.title = "Reconnect \(name)  (\(hotKeyLabel))"
        } else {
            cutItem.title = "Cut \(target.describedTarget)  (\(hotKeyLabel))"
        }
        cutItem.isEnabled = !cutInFlight
        rebuildTargetMenu()
        rebuildHoldMenu()
    }

    private var menuHeadline: String {
        switch indicator {
        case .down(let name): return "\(name) is CUT OFF — \(hotKeyLabel) reconnects it"
        case .failed(let why): return "Last: \(why)"
        case .connected:
            if !hotKeyWorks { return "\(hotKeyLabel) is NOT registered — see the log" }
            return "Connected. \(lastResult)"
        }
    }

    private func rebuildTargetMenu() {
        guard let sub = targetItem.submenu else { return }
        sub.removeAllItems()
        let frontName = currentFrontmostApp()?.localizedName ?? "none"
        let front = NSMenuItem(title: "Frontmost app  (now: \(frontName))",
                               action: #selector(pickFrontmost), keyEquivalent: "")
        front.target = self
        front.state = target == .frontmost ? .on : .off
        sub.addItem(front)
        sub.addItem(.separator())

        // A pin set from the shell may name something that is not in the
        // running-apps list at all; show it rather than look unset.
        if case .pinned(let path, let name) = target,
           !targetableApps().contains(where: { $0.bundleURL?.path == path }) {
            let item = NSMenuItem(title: name, action: #selector(pickApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = .on
            item.toolTip = path
            sub.addItem(item)
            sub.addItem(.separator())
        }

        for app in targetableApps() {
            guard let path = app.bundleURL?.path else { continue }
            let name = app.localizedName ?? (path as NSString).lastPathComponent
            let item = NSMenuItem(title: name, action: #selector(pickApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.image = app.icon.map { icon in
                let small = NSImage(size: NSSize(width: 16, height: 16))
                small.lockFocus()
                icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                small.unlockFocus()
                return small
            }
            if case .pinned(let pinnedPath, _) = target, pinnedPath == path { item.state = .on }
            sub.addItem(item)
        }
    }

    private func rebuildHoldMenu() {
        guard let sub = holdItem.submenu else { return }
        sub.removeAllItems()
        holdItem.title = "Hold: \(hold == "asap" ? "until it drops" : "\(hold)s")"
        for (label, value) in [("Until it drops (fastest)", "asap"), ("3 seconds", "3"), ("10 seconds", "10")] {
            let item = NSMenuItem(title: label, action: #selector(pickHold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = hold == value ? .on : .off
            sub.addItem(item)
        }
    }

    private func targetableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil
                      && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    @objc private func pickFrontmost() {
        target = .frontmost
        savePinnedTarget(target)
        render()
    }

    @objc private func pickApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        target = .pinned(bundlePath: path, name: sender.title)
        savePinnedTarget(target)
        render()
    }

    @objc private func pickHold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        hold = value
        render()
    }

    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func cutNow() { fire(source: "menu") }

    @objc private func restoreNow() {
        run(arguments: ["restore"], label: "restore") { _, _ in }
    }

    // MARK: frontmost tracking

    private func trackFrontmostApp() {
        lastFrontmost = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.lastFrontmost = app }
        }
    }

    private func currentFrontmostApp() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            return app
        }
        return lastFrontmost
    }

    // MARK: the hotkey

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MainActor.assumeIsolated { sharedAgent?.fire(source: "hotkey") } }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x4E435554), id: 1)   // 'NCUT'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(cmdKey), id,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
        hotKeyWorks = status == noErr
        if !hotKeyWorks {
            logLine("RegisterEventHotKey(\(hotKeyLabel)) failed with OSStatus \(status) — another app may already own it")
            indicator = .failed("\(hotKeyLabel) unavailable (OSStatus \(status))")
        }
    }

    // MARK: signals
    //
    // A menu-bar agent has no other way to be driven from a script, and the
    // indicator is the part worth proving:
    //   kill -USR1  fire a real cut at the current target, as ⌘9 does
    //   kill -USR2  paint the indicator blue for two seconds, cutting nothing
    private func installSignalHandlers() {
        for (sig, handler) in [(SIGUSR1, #selector(signalFire)), (SIGUSR2, #selector(signalSelfTest))] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { _ = self?.perform(handler) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func signalFire() { fire(source: "signal") }

    @objc private func signalSelfTest() {
        logLine("indicator self-test: blue for 2s, nothing is being cut")
        indicator = .down("indicator self-test")
        render()
        revertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .down = self.indicator { self.indicator = .connected; self.render() }
            }
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// While the dot is blue, confirm every few seconds that the block really
    /// is still up. netcutd lifts a forgotten latch on its own cap, and a dot
    /// still showing blue over a working network would be the one failure
    /// that matters here.
    private func startStatusPolling() {
        statusPoll?.invalidate()
        statusPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .down = self.indicator, !self.cutInFlight else { return }
                self.run(arguments: ["status"], label: "status") { [weak self] _, output in
                    MainActor.assumeIsolated {
                        guard let self, case .down = self.indicator else { return }
                        if output.contains("no cut active") {
                            logLine("status poll: the block is gone; dot back to connected")
                            self.indicator = .connected
                            self.render()
                            self.stopStatusPolling()
                        }
                    }
                }
            }
        }
    }

    private func stopStatusPolling() { statusPoll?.invalidate(); statusPoll = nil }

    // MARK: firing

    func fire(source: String) {
        target = loadPinnedTarget()

        // A press while the last one is still running used to be ignored,
        // which meant a stuck request left him cut off and hammering the key
        // to no effect. The second press is always allowed to be the
        // reconnect: cancel whatever is running and restore, which is the
        // one direction that can only ever re-open the network.
        if cutInFlight {
            logLine("\(source): press while busy — cancelling and restoring")
            selfTerminated = true
            runningProcess?.terminate()
            runningProcess = nil
            cutInFlight = false
            watchdog?.cancel()
            startRestore(name: lastTargetName, source: source)
            return
        }

        // Already down: this press is the reconnect, and the target does not
        // matter — netcutd lifts whatever block is up.
        if case .down(let name) = indicator {
            startRestore(name: name, source: source)
            return
        }
        let bundlePath: String
        let name: String
        switch target {
        case .pinned(let path, let pinnedName):
            bundlePath = path; name = pinnedName
        case .frontmost:
            guard let app = currentFrontmostApp(), let path = app.bundleURL?.path else {
                failed("could not tell which app is in front")
                return
            }
            bundlePath = path
            name = app.localizedName ?? (path as NSString).lastPathComponent
        }

        // Blue first, on this turn of the main loop, before anything that can
        // block. This is what makes the keypress feel instant. If the cut
        // then fails, finish() puts the dot back to the truth.
        cutInFlight = true
        cutStarted = Date()
        lastTargetName = name
        indicator = .down(name)
        render()
        logLine("\(source): cut \(name) [\(bundlePath)]")

        run(arguments: ["--markers", "toggle", bundlePath, "drop"], label: name) { [weak self] code, output in
            MainActor.assumeIsolated { self?.finish(name: name, code: code, output: output) }
        }
        armWatchdog(name: name)
    }

    /// A blue dot that outlives the cut would be a lie about the network. If
    /// netcut has not reported the block lifted by the time it must have, the
    /// child is killed and the indicator says so instead of staying blue.
    private func armWatchdog(name: String) {
        let budget: TimeInterval = 6
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.cutInFlight else { return }
                self.runningProcess?.terminate()
                self.failed("\(name): netcut did not report back — use Restore Network Now")
                self.refreshFromDaemon()
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + budget, execute: work)
    }

    private func startRestore(name: String, source: String) {
        cutInFlight = true
        cutStarted = Date()
        logLine("\(source): reconnect \(name)")
        run(arguments: ["--markers", "restore"], label: name) { [weak self] code, output in
            MainActor.assumeIsolated { self?.finish(name: name, code: code, output: output) }
        }
        armWatchdog(name: name)
    }

    /// Launches netcut and streams its output. `__restored__` clears the blue
    /// indicator: the outage is over even though the child is still measuring
    /// how fast the app reconnects.
    private func run(arguments: [String], label: String,
                     completion: @escaping @Sendable (Int32, String) -> Void) {
        guard let netcut = netcutExecutable() else {
            failed("netcut command not found")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: netcut)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin",
                               "HOME": home]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = Collector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            collected.append(chunk)
            if chunk.contains("__restored__") {
                DispatchQueue.main.async { MainActor.assumeIsolated { sharedAgent?.networkIs(down: false) } }
            } else if chunk.contains("__latched__") {
                DispatchQueue.main.async { MainActor.assumeIsolated { sharedAgent?.networkIs(down: true) } }
            }
        }
        process.terminationHandler = { finished in
            let text = collected.text
            DispatchQueue.main.async { completion(finished.terminationStatus, text) }
        }
        do {
            try process.run()
            runningProcess = process
        } catch {
            failed("could not start netcut: \(error.localizedDescription)")
        }
    }

    /// The dot changes the instant netcutd says the network changed, with no
    /// minimum and no animation: blue exactly while the block is up.
    func networkIs(down: Bool, name: String? = nil) {
        revertWork?.cancel()
        if down {
            if case .down = indicator {} else { indicator = .down(name ?? lastTargetName) }
            startStatusPolling()
        } else {
            indicator = .connected
            stopStatusPolling()
        }
        render()
    }

    /// Ask netcutd what is actually true and show that.
    private func refreshFromDaemon() {
        run(arguments: ["status"], label: "status") { [weak self] _, output in
            MainActor.assumeIsolated {
                self?.networkIs(down: !output.contains("no cut active"))
            }
        }
    }

    private func finish(name: String, code: Int32, output: String) {
        cutInFlight = false
        watchdog?.cancel()
        runningProcess = nil
        if selfTerminated {
            selfTerminated = false
            logLine("(that was the cancelled request; asking netcutd what is true)")
            refreshFromDaemon()
            return
        }
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("__") && !$0.isEmpty }
        logLine("netcut exited \(code) in \(Int(Date().timeIntervalSince(cutStarted) * 1000))ms: \(lines.joined(separator: " | "))")
        if code == 0 {
            lastResult = lines.last ?? name
            // The markers already moved the dot; this only covers a reply
            // that carried neither of them.
            if output.contains("__latched__") { networkIs(down: true, name: name) }
            else if output.contains("__restored__") { networkIs(down: false) }
            else { refreshFromDaemon() }
        } else {
            // A daemon refusal says "error: ...". A client-side failure (no
            // helper, stale helper) explains itself on its first line.
            let why = lines.first(where: { $0.hasPrefix("error:") })?
                .replacingOccurrences(of: "error: ", with: "")
                ?? lines.first ?? "netcut failed"
            failed("\(name): \(why)")
        }
    }

    private func failed(_ why: String) {
        cutInFlight = false
        stopStatusPolling()
        lastResult = why
        indicator = .failed(why)
        logLine("failed: \(why)")
        render()
        revertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .failed = self.indicator else { return }
                self.refreshFromDaemon()
            }
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: the indicator

    private func render() {
        let glyph: String
        let color: NSColor
        let tooltip: String
        switch indicator {
        case .connected:
            glyph = "●"
            color = hotKeyWorks ? .tertiaryLabelColor : .systemOrange
            tooltip = hotKeyWorks
                ? "netcut — connected. \(hotKeyLabel) cuts \(target.describedTarget)"
                : "netcut — \(hotKeyLabel) could not be registered"
        case .down(let name):
            glyph = "●"
            color = .systemBlue
            tooltip = "netcut — \(name) is CUT OFF. \(hotKeyLabel) reconnects it"
        case .failed(let why):
            glyph = "●"
            color = .systemRed
            tooltip = "netcut — \(why)"
        }
        statusItem.button?.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [.foregroundColor: color,
                         .font: NSFont.systemFont(ofSize: 15, weight: .bold)])
        statusItem.button?.toolTip = tooltip
    }
}

/// Collects child output off the main thread.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

nonisolated(unsafe) var sharedAgent: Agent?

// Top-level code runs on the main thread, which is where the agent lives.
MainActor.assumeIsolated {
    let agent = Agent()
    sharedAgent = agent
    agent.run()
}
