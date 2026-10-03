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


/// Speaks netcutd's FIFO protocol directly.
///
/// ⌘9 used to spawn the `netcut` shell script, which cost a bash startup
/// (~25 ms) on every press for nothing — the protocol is one line in and one
/// file out. The CLI still exists for terminal use; this is the hot path.
enum NetcutClient {
    static let runDir = "/var/run/netcut"
    static let fifoPath = "\(runDir)/ctl"
    static let protocolNeeded = 8

    struct Reply {
        let ok: Bool
        let lines: [String]
        var text: String { lines.joined(separator: " | ") }
        func has(_ marker: String) -> Bool { lines.contains { $0.hasPrefix(marker) } }
        /// The latch reply carries the cap, so the countdown cannot disagree
        /// with the daemon's own auto-restore.
        var latchedSeconds: Int? {
            guard let line = lines.first(where: { $0.hasPrefix("__latched__") }) else { return nil }
            return Int(line.split(separator: " ").dropFirst().first.map(String.init) ?? "")
        }
    }

    static func installedProtocol() -> Int {
        guard let raw = try? String(contentsOfFile: "\(runDir)/protocol", encoding: .utf8) else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Blocking. Callers run it off the main thread.
    static func request(_ verb: String, arg: String = "-", window: String = "-",
                        mode: String = "-", timeout: TimeInterval = 15) -> Reply {
        let proto = installedProtocol()
        guard proto >= protocolNeeded else {
            return Reply(ok: false, lines: proto == 0
                ? ["error: the netcut helper is not running (run install.sh)"]
                : ["error: the installed helper speaks protocol \(proto), this needs \(protocolNeeded) — re-run install.sh"])
        }

        let id = "\(getpid())-\(UInt64(Date().timeIntervalSince1970 * 1000))"
        let line = "\(verb)|\(arg)|\(window)|\(mode)|\(id)\n"

        // O_NONBLOCK so a missing daemon is an error instead of a hang; a
        // single short line is written atomically either way.
        let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            return Reply(ok: false, lines: ["error: cannot reach the netcut helper (is it running?)"])
        }
        defer { close(fd) }
        let written = line.withCString { strlen($0) }
        guard line.withCString({ write(fd, $0, written) }) == written else {
            return Reply(ok: false, lines: ["error: could not hand the request to the helper"])
        }

        let replyPath = "\(runDir)/reply.\(id)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let body = try? String(contentsOfFile: replyPath, encoding: .utf8) {
                let all = body.split(separator: "\n").map(String.init)
                if all.contains("__done__") {
                    let lines = all.filter { $0 != "__done__" }
                    return Reply(ok: !lines.contains { $0.hasPrefix("error:") }, lines: lines)
                }
            }
            usleep(2000)   // 2 ms: a toggle answers in single-digit milliseconds
        }
        return Reply(ok: false, lines: ["error: the helper did not answer in \(Int(timeout))s"])
    }
}

/// Which key fires a cut. A bare key (no modifier) is only ever registered
/// while the pinned app is frontmost — on its own it would swallow that
/// letter everywhere on the system.
enum KeyBinding: String, CaseIterable {
    case cmd9, q, grave

    var keyCode: UInt32 {
        switch self {
        case .cmd9:  return UInt32(kVK_ANSI_9)
        case .q:     return UInt32(kVK_ANSI_Q)
        case .grave: return UInt32(kVK_ANSI_Grave)
        }
    }
    var modifiers: UInt32 { self == .cmd9 ? UInt32(cmdKey) : 0 }
    var isBare: Bool { modifiers == 0 }
    var label: String {
        switch self {
        case .cmd9:  return "⌘9"
        case .q:     return "Q"
        case .grave: return "`"
        }
    }
    var menuLabel: String {
        switch self {
        case .cmd9:  return "⌘9"
        case .q:     return "Q  (on its own)"
        case .grave: return "`  backtick  (on its own)"
        }
    }

    static var path: String { "\(home)/.config/netcut/key" }

    static func load() -> KeyBinding {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let k = KeyBinding(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .cmd9 }
        return k
    }

    func save() {
        let url = URL(fileURLWithPath: KeyBinding.path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (rawValue + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// How long the block opens each second to keep the peer talking. 0 = a
/// solid block, which the peer stops answering after a few seconds.
enum Pulse {
    static var path: String { "\(home)/.config/netcut/pulse" }
    static func load() -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return (n == 0 || (n >= 10 && n <= 500)) ? n : 0
    }
}

/// How late `delay` mode makes outbound packets, in milliseconds.
enum DelayMs {
    static let fallback = 3000
    static var path: String { "\(home)/.config/netcut/delayms" }
    static func load() -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return fallback }
        return Swift.min(Swift.max(n, 100), 30000)
    }
}

/// Which way the block runs.
///
/// `both` is an ordinary disconnect. `out` leaves the peer's packets arriving
/// while nothing of ours reaches it — a half-open connection, which is the
/// state a server's own timeout handling is easiest to get wrong on. `in` is
/// the mirror.
enum Direction: String, CaseIterable {
    case both, out, `in`, delay

    var label: String {
        switch self {
        case .both:  return "Both ways (a full disconnect)"
        case .delay: return "Delay outbound (you see live, they see you stale)"
        case .out:   return "Outbound only (it cannot send)"
        case .in:    return "Inbound only (it cannot receive)"
        }
    }
    var short: String {
        switch self {
        case .both:  return "both ways"
        case .delay: return "sending late"
        case .out:   return "cannot send"
        case .in:    return "cannot receive"
        }
    }

    static var path: String { "\(home)/.config/netcut/direction" }

    static func load() -> Direction {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let d = Direction(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .both }
        return d
    }

    func save() {
        let url = URL(fileURLWithPath: Direction.path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (rawValue + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// How long a cut lasts before it reconnects itself. One number, shared by
/// the menu, the `netcut seconds` command and the daemon, which clamps it.
enum AutoReconnect {
    static let min = 2, max = 120, fallback = 20
    static var path: String { "\(home)/.config/netcut/seconds" }

    static func load() -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return fallback }
        return Swift.min(Swift.max(n, min), max)
    }

    static func save(_ n: Int) {
        let clamped = Swift.min(Swift.max(n, min), max)
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ("\(clamped)\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - the countdown overlay

enum Placement: String, CaseIterable {
    case topLeft, topRight, bottom

    var label: String {
        switch self {
        case .topLeft:  return "Top left"
        case .topRight: return "Top right"
        case .bottom:   return "Bottom"
        }
    }

    static var path: String { "\(home)/.config/netcut/overlay" }

    static func load() -> Placement {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let p = Placement(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .topRight }
        return p
    }

    func save() {
        let url = URL(fileURLWithPath: Placement.path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (rawValue + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A borderless, click-through window showing how long the cut has left.
/// Joins every Space and sits above full-screen windows, because the app it
/// is counting down for is usually the one filling the screen.
@MainActor
final class CountdownOverlay {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "●")
    /// Set when the cut is one-way, so the overlay never implies a full
    /// disconnect that is not happening.
    var overlayDirectionNote = ""   

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 176, height: 44),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // A HUD material rather than a flat alpha: at 0.82 black the page
        // behind it still read through the card and the text sat on top of
        // whatever happened to be there.
        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 176, height: 44))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.65).cgColor

        dot.font = .systemFont(ofSize: 13, weight: .bold)
        dot.textColor = .systemBlue
        dot.frame = NSRect(x: 14, y: 13, width: 14, height: 18)

        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 32, y: 12, width: 132, height: 20)
        label.lineBreakMode = .byTruncatingTail

        card.addSubview(dot)
        card.addSubview(label)
        w.contentView = card
        return w
    }

    func show(app: String, remaining: Int, placement: Placement) {
        let w = window ?? build()
        window = w
        update(app: app, remaining: remaining)
        position(w, placement)
        w.orderFrontRegardless()
    }

    func update(app: String, remaining: Int) {
        let suffix = overlayDirectionNote.isEmpty ? "" : "  ·  \(overlayDirectionNote)"
        label.stringValue = "\(app)  ·  \(max(0, remaining))s\(suffix)"
    }

    func reposition(_ placement: Placement) {
        guard let w = window, w.isVisible else { return }
        position(w, placement)
    }

    private func position(_ w: NSWindow, _ placement: Placement) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // visibleFrame keeps it clear of the menu bar and the Dock.
        let area = screen.visibleFrame
        let size = w.frame.size
        let margin: CGFloat = 16
        let origin: NSPoint
        switch placement {
        case .topLeft:
            origin = NSPoint(x: area.minX + margin, y: area.maxY - size.height - margin)
        case .topRight:
            origin = NSPoint(x: area.maxX - size.width - margin, y: area.maxY - size.height - margin)
        case .bottom:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + margin)
        }
        w.setFrameOrigin(origin)
    }

    func hide() {
        window?.orderOut(nil)
    }
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
    private let placementItem = NSMenuItem(title: "Countdown", action: nil, keyEquivalent: "")
    private let secondsItem = NSMenuItem(title: "Reconnect after", action: nil, keyEquivalent: "")
    private let keyItem = NSMenuItem(title: "Key", action: nil, keyEquivalent: "")
    private let directionItem = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")

    private var indicator: Indicator = .connected
    private var target: Target = .frontmost
    private var lastFrontmost: NSRunningApplication?
    private var cutInFlight = false
    private var lastResult = "no cut yet"
    private var lastTargetName = "that app"
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyWorks = false
    private var revertWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []

    private var cutStarted = Date.distantPast
    private var statusPoll: Timer?
    private let overlay = CountdownOverlay()
    private var placement = Placement.load()
    private var seconds = AutoReconnect.load()
    private var binding = KeyBinding.load()
    private var direction = Direction.load()
    private var handlerInstalled = false
    private var armed = false
    private var countdown: Timer?
    private var deadline: Date?
    private var downAppName = ""

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        target = loadPinnedTarget()
        buildMenu()
        trackFrontmostApp()
        installSignalHandlers()
        updateArming()
        startSettingsWatch()
        render()
        logLine("started (helper protocol=\(NetcutClient.installedProtocol()), key=\(binding.label), armed=\(armed), countdown=\(placement.label), window=\(seconds)s, direction=\(direction.rawValue))")
        NSApplication.shared.run()
    }

    // MARK: menu

    private func buildMenu() {
        menu.delegate = self
        statusLine.isEnabled = false
        cutItem.target = self
        cutItem.action = #selector(cutNow)
        targetItem.submenu = NSMenu()
        placementItem.submenu = NSMenu()
        secondsItem.submenu = NSMenu()
        keyItem.submenu = NSMenu()
        directionItem.submenu = NSMenu()

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
        menu.addItem(directionItem)
        menu.addItem(keyItem)
        menu.addItem(secondsItem)
        menu.addItem(placementItem)
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
            cutItem.title = "Reconnect \(name)  (\(binding.label))"
        } else {
            cutItem.title = "Cut \(target.describedTarget)  (\(binding.label))"
        }
        cutItem.isEnabled = !cutInFlight
        rebuildTargetMenu()
        seconds = AutoReconnect.load()      // the CLI may have changed it
        if KeyBinding.load() != binding { changeBinding(to: KeyBinding.load()) }
        direction = Direction.load()
        rebuildDirectionMenu()
        rebuildKeyMenu()
        rebuildSecondsMenu()
        rebuildPlacementMenu()
    }

    private var menuHeadline: String {
        switch indicator {
        case .down(let name): return "\(name) is CUT OFF — \(hotKeyLabel) reconnects it"
        case .failed(let why): return "Last: \(why)"
        case .connected:
            if !hotKeyWorks { return "\(binding.label) is NOT registered — see the log" }
            if !armed {
                if case .pinned(_, let name) = target {
                    // Opening this menu takes focus off the target, so
                    // "not armed" is always true while you are reading it.
                    // Say what it means, not what it measures.
                    return "\(binding.label) works while \(name) is in front (not while this menu is)"
                }
                return "\(binding.label) on its own needs an app pinned in Target"
            }
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



    private func rebuildDirectionMenu() {
        guard let sub = directionItem.submenu else { return }
        sub.removeAllItems()
        directionItem.title = "Direction: \(direction.short)"
        for option in Direction.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(pickDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == direction ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(
            title: "Delay keeps the link alive; a one-way block does not",
            action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
    }

    @objc private func pickDirection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Direction(rawValue: raw) else { return }
        direction = option
        option.save()
        logLine("direction set to \(option.rawValue)")
        render()
    }

    private func rebuildKeyMenu() {
        guard let sub = keyItem.submenu else { return }
        sub.removeAllItems()
        keyItem.title = "Key: \(binding.label)"
        for option in KeyBinding.allCases {
            let item = NSMenuItem(title: option.menuLabel, action: #selector(pickKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == binding ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(title: "A key on its own needs an app pinned above",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = KeyBinding(rawValue: raw) else { return }
        changeBinding(to: option)
    }

    private func changeBinding(to option: KeyBinding) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        armed = false
        binding = option
        option.save()
        logLine("key set to \(option.label)")
        updateArming()
        render()
    }

    private func rebuildSecondsMenu() {
        guard let sub = secondsItem.submenu else { return }
        sub.removeAllItems()
        secondsItem.title = "Reconnect after: \(seconds)s"
        var presets = [5, 10, 15, 20, 30, 60]
        if !presets.contains(seconds) { presets.append(seconds); presets.sort() }
        for n in presets {
            let item = NSMenuItem(title: "\(n) seconds", action: #selector(pickSeconds(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n
            item.state = n == seconds ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(pickCustomSeconds), keyEquivalent: "")
        custom.target = self
        sub.addItem(custom)
    }

    @objc private func pickSeconds(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        seconds = n
        AutoReconnect.save(n)
        logLine("auto-reconnect set to \(n)s")
        render()
    }

    @objc private func pickCustomSeconds() {
        let alert = NSAlert()
        alert.messageText = "Reconnect after"
        alert.informativeText = "Seconds a cut app stays offline before it comes back on its own (\(AutoReconnect.min)–\(AutoReconnect.max))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        field.stringValue = "\(seconds)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        seconds = Swift.min(Swift.max(n, AutoReconnect.min), AutoReconnect.max)
        AutoReconnect.save(seconds)
        logLine("auto-reconnect set to \(seconds)s")
        render()
    }

    private func rebuildPlacementMenu() {
        guard let sub = placementItem.submenu else { return }
        sub.removeAllItems()
        placementItem.title = "Countdown: \(placement.label)"
        for option in Placement.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(pickPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == placement ? .on : .off
            sub.addItem(item)
        }
    }

    @objc private func pickPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Placement(rawValue: raw) else { return }
        placement = option
        option.save()
        overlay.reposition(option)
        render()
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
        updateArming()
        render()
    }

    @objc private func pickApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        target = .pinned(bundlePath: path, name: sender.title)
        savePinnedTarget(target)
        updateArming()
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
            MainActor.assumeIsolated {
                self?.lastFrontmost = app
                self?.updateArming()
            }
        }
    }

    private func currentFrontmostApp() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            return app
        }
        return lastFrontmost
    }

    // MARK: the hotkey

    /// The Carbon handler is installed once. The key itself is registered and
    /// unregistered as the frontmost app changes, which is what keeps it from
    /// being taken system wide.
    private func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MainActor.assumeIsolated { sharedAgent?.fire(source: "hotkey") } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    /// Should the key be live right now?
    ///
    /// - While an app is cut: always. A second press has to be able to
    ///   reconnect it whatever he has switched to in the meantime.
    /// - With an app pinned: only while that app is frontmost. This is what
    ///   gives ⌘9 back to Chrome, and what makes a bare key safe at all.
    /// - With nothing pinned: a key with a modifier is always live; a bare
    ///   key never is, because there is no app to scope it to.
    private func shouldBeArmed() -> Bool {
        if case .down = indicator { return true }
        switch target {
        case .frontmost:
            return !binding.isBare
        case .pinned(let path, let name):
            guard let front = currentFrontmostApp() else { return false }
            if let frontPath = front.bundleURL?.path, frontPath == path { return true }
            // A pin may be a bare app name or a .exe rather than a bundle path.
            return (front.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func updateArming() {
        installHotKeyHandler()
        let want = shouldBeArmed()
        guard want != armed else { return }
        if want {
            let id = EventHotKeyID(signature: OSType(0x4E435554), id: 1)   // 'NCUT'
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
            armed = status == noErr
            hotKeyWorks = armed
            if armed {
                logLine("\(binding.label) armed")
            } else {
                logLine("RegisterEventHotKey(\(binding.label)) failed with OSStatus \(status) — another app may own it")
                indicator = .failed("\(binding.label) unavailable (OSStatus \(status))")
            }
        } else {
            if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
            armed = false
            hotKeyWorks = true            // not broken, just not listening here
            logLine("\(binding.label) released")
        }
        render()
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
        // Uses the configured window, so this also proves the agent is
        // reading the same setting the CLI writes.
        seconds = AutoReconnect.load()
        logLine("self-test: dot blue and a \(seconds)s countdown, nothing is being cut")
        downAppName = "self-test"
        indicator = .down("self-test")
        render()
        startCountdownDisplayOnly(seconds: seconds)
    }

    /// The countdown without the network half, so the overlay can be checked
    /// without cutting anything.
    private func startCountdownDisplayOnly(seconds: Int) {
        countdown?.invalidate()
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        overlay.show(app: downAppName, remaining: seconds, placement: placement)
        countdown = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let deadline = self.deadline else { return }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    self.stopCountdown()
                    self.indicator = .connected
                    self.render()
                } else {
                    self.overlay.update(app: self.downAppName, remaining: Int(left.rounded(.up)))
                }
            }
        }
    }


    /// While the dot is blue, confirm every few seconds that the block really
    /// is still up. netcutd lifts a forgotten latch on its own cap, and a dot
    /// still showing blue over a working network would be the one failure
    /// that matters here.
    /// The CLI writes the same settings files the menu does, so re-read them
    /// on a slow timer. Without this a `netcut pin` or `netcut key` would not
    /// take hold until the next app switch.
    private func startSettingsWatch() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pinned = loadPinnedTarget()
                let key = KeyBinding.load()
                self.seconds = AutoReconnect.load()
                self.direction = Direction.load()
                if key != self.binding { self.changeBinding(to: key); return }
                if pinned != self.target { self.target = pinned; self.updateArming(); self.render() }
                else { self.updateArming() }
            }
        }
    }

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
            // Requests now answer in milliseconds, so this window is tiny —
            // but the second press must always be allowed to reconnect.
            logLine("\(source): press while busy — restoring anyway")
            cutInFlight = false
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

        seconds = AutoReconnect.load()
        direction = Direction.load()
        run(arguments: ["--markers", "toggle", bundlePath,
                        "drop:\(direction.rawValue):\(DelayMs.load()):\(Pulse.load())"],
            label: name, seconds: seconds) { [weak self] code, output in
            MainActor.assumeIsolated { self?.finish(name: name, code: code, output: output) }
        }
    }



    private func startRestore(name: String, source: String) {
        cutInFlight = true
        cutStarted = Date()
        logLine("\(source): reconnect \(name)")
        run(arguments: ["--markers", "restore"], label: name) { [weak self] code, output in
            MainActor.assumeIsolated { self?.finish(name: name, code: code, output: output) }
        }
    }

    /// Sends one request to the daemon off the main thread and hands the
    /// reply back on it. No child process: the keypress path is a write to a
    /// FIFO and a poll of one file.
    private func run(arguments: [String], label: String, seconds: Int? = nil,
                     completion: @escaping @Sendable (Int32, String) -> Void) {
        let verb: String, arg: String, mode: String
        switch arguments.first(where: { !$0.hasPrefix("--") }) ?? "status" {
        case "toggle":
            verb = "toggle"
            arg = arguments.count >= 3 ? arguments[2] : "-"
            mode = arguments.count >= 4 ? arguments[3] : "drop"
        case "restore": verb = "restore"; arg = "-"; mode = "-"
        default:        verb = "status";  arg = "-"; mode = "-"
        }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = NetcutClient.request(verb, arg: arg,
                                             window: seconds.map(String.init) ?? "-",
                                             mode: mode,
                                             timeout: verb == "status" ? 5 : 8)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                logLine("\(verb) \(label) -> \(reply.ok ? "ok" : "FAILED") in \(ms)ms: \(reply.text)")
                completion(reply.ok ? 0 : 1, reply.lines.joined(separator: "\n"))
            }
        }
    }

    func networkIs(down: Bool, name: String? = nil, seconds: Int? = nil) {
        defer { updateArming() }      // a live cut keeps the key available everywhere
        revertWork?.cancel()
        if down {
            let who = name ?? lastTargetName
            downAppName = who
            if case .down = indicator {} else { indicator = .down(who) }
            startCountdown(seconds: seconds ?? 20)
            startStatusPolling()
        } else {
            indicator = .connected
            stopCountdown()
            stopStatusPolling()
        }
        render()
    }

    /// The daemon restores on its own cap; this counts the same window down
    /// on screen and asks for the restore when it reaches zero, so the dot
    /// and the overlay clear at the moment the network actually comes back
    /// rather than a sleep-granularity later.
    private func startCountdown(seconds: Int) {
        countdown?.invalidate()
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        overlay.overlayDirectionNote = direction == .both ? "" : direction.short
        overlay.show(app: downAppName, remaining: seconds, placement: placement)
        countdown = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let deadline = self.deadline else { return }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    logLine("countdown reached zero — reconnecting \(self.downAppName)")
                    self.stopCountdown()
                    self.startRestore(name: self.downAppName, source: "timer")
                } else {
                    self.overlay.update(app: self.downAppName, remaining: Int(left.rounded(.up)))
                }
            }
        }
    }

    private func stopCountdown() {
        countdown?.invalidate(); countdown = nil
        deadline = nil
        overlay.hide()
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
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("__") && !$0.isEmpty }
        logLine("netcut exited \(code) in \(Int(Date().timeIntervalSince(cutStarted) * 1000))ms: \(lines.joined(separator: " | "))")
        if code == 0 {
            lastResult = lines.last ?? name
            // The markers already moved the dot; this only covers a reply
            // that carried neither of them.
            if output.contains("__latched__") {
                let cap = output.split(separator: "\n")
                    .first { $0.hasPrefix("__latched__") }
                    .flatMap { Int($0.split(separator: " ").dropFirst().first.map(String.init) ?? "") }
                networkIs(down: true, name: name, seconds: cap ?? 20)
            }
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
            // Hollow when the key is not listening. An unarmed press never
            // reaches this process at all, so the dot is the only thing that
            // can say so beforehand -- and two shades of grey did not.
            glyph = armed ? "●" : "○"
            color = hotKeyWorks ? .tertiaryLabelColor : .systemOrange
            if !hotKeyWorks {
                tooltip = "netcut — \(binding.label) could not be registered"
            } else if armed {
                tooltip = "netcut — connected. \(binding.label) cuts \(target.describedTarget) for \(seconds)s"
            } else if case .pinned(_, let name) = target {
                tooltip = "netcut — waiting for \(name); \(binding.label) does nothing elsewhere"
            } else {
                tooltip = "netcut — \(binding.label) on its own needs an app pinned"
            }
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


nonisolated(unsafe) var sharedAgent: Agent?

// Top-level code runs on the main thread, which is where the agent lives.
MainActor.assumeIsolated {
    let agent = Agent()
    sharedAgent = agent
    agent.run()
}
