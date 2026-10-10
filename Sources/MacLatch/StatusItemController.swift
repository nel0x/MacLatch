import AppKit
import MacLatchCore

/// Everything the menu needs to render, assembled by `AppController`.
struct StatusViewModel {
    var snapshot: GuardSnapshot
    var pendingLockStarted: ContinuousClock.Instant?
    var configuredKey: ConfiguredYubiKey?
    var detectedKeys: [YubiKeyMonitor.DetectedKey]
    var unidentifiedCount: Int
    var lockBackendAvailable: Bool
    var recentEvents: [String]
    var loginItemState: LoginItem.State
    var isInApplicationsFolder: Bool
    var keepAwake: Bool
}

@MainActor
struct StatusActions {
    var disarm: () -> Void
    var testLock: () -> Void
    var setMonitorMode: (Bool) -> Void
    var setLockDelay: (Int) -> Void
    var useKey: (YubiKeyMonitor.DetectedKey) -> Void
    var forgetKey: () -> Void
    var setKeepAwake: (Bool) -> Void
    var setStartAtLogin: (Bool) -> Void
    var openLoginItemSettings: () -> Void
    var moveToApplications: () -> Void
}

/// Menu bar icon and menu. Status is conveyed by color, symbol shape and text.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let model: () -> StatusViewModel
    private let actions: StatusActions

    private var isMenuOpen = false
    /// The "Locking in …" line, present only while a countdown is shown.
    private var countdownItem: NSMenuItem?
    /// UI-only refresh of the countdown text while the menu is open. Not device polling.
    private var countdownTimer: Timer?

    init(model: @escaping () -> StatusViewModel, actions: StatusActions) {
        self.model = model
        self.actions = actions
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render(model().snapshot)
    }

    func render(_ snapshot: GuardSnapshot) {
        guard let button = statusItem.button else { return }
        let (symbol, color) = Self.appearance(for: snapshot.state)
        let description = "MacLatch: \(snapshot.state.displayName)" + (snapshot.monitorMode ? " (Monitor Mode)" : "")

        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: description))?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading
        button.title = snapshot.state == .pendingLock ? " Locking…" : ""
        button.toolTip = description
        button.setAccessibilityLabel(description)
        refreshIfOpen()
    }

    /// Rebuilds the open menu so it never shows a stale state. Call on any state or device change.
    func refreshIfOpen() {
        guard isMenuOpen else { return }
        rebuild(menu)
        updateCountdownTimer()
    }

    private static func appearance(for state: GuardState) -> (symbol: String, color: NSColor) {
        switch state {
        case .unarmed: ("lock.open.fill", .systemYellow)
        case .armed: ("lock.fill", .systemGreen)
        case .pendingLock: ("lock.trianglebadge.exclamationmark.fill", .systemRed)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        updateCountdownTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        updateCountdownTimer()
    }

    private func updateCountdownTimer() {
        let needed = isMenuOpen && countdownItem != nil
        if needed, countdownTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCountdownText() }
            }
            // .common so it also fires while the menu is tracking events.
            RunLoop.main.add(timer, forMode: .common)
            countdownTimer = timer
        } else if !needed {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func updateCountdownText() {
        countdownItem?.title = Self.countdownText(model())
    }

    private func rebuild(_ menu: NSMenu) {
        let model = model()
        menu.removeAllItems()
        countdownItem = nil

        menu.addItem(header("MacLatch"))
        menu.addItem(statusLine(for: model.snapshot))
        if model.snapshot.state == .pendingLock {
            let countdown = info(Self.countdownText(model))
            countdownItem = countdown
            menu.addItem(countdown)
        }
        for line in detailLines(for: model) { menu.addItem(info(line)) }
        menu.addItem(.separator())

        if let key = model.configuredKey {
            menu.addItem(info("\(key.name)  Serial: \(key.maskedSerial)"))
        } else {
            menu.addItem(info("No YubiKey configured"))
        }
        menu.addItem(lockDelaySubmenu(current: model.snapshot.lockDelay))
        if model.unidentifiedCount > 0 {
            menu.addItem(info("⚠︎ \(model.unidentifiedCount) YubiKey(s) not identified; auto-lock may be skipped"))
        }
        if !model.lockBackendAvailable {
            menu.addItem(info("⚠︎ Lock backend unavailable; cannot arm"))
        }
        menu.addItem(.separator())

        let disarm = item("Disarm") { [actions] in actions.disarm() }
        disarm.isEnabled = model.snapshot.state != .unarmed
        menu.addItem(disarm)

        let monitor = item("Monitor Mode (log only, never lock)") { [actions] in
            actions.setMonitorMode(!model.snapshot.monitorMode)
        }
        monitor.state = model.snapshot.monitorMode ? .on : .off
        menu.addItem(monitor)

        let keepAwake = item("Keep Mac Awake (prevent idle sleep)") { [actions] in
            actions.setKeepAwake(!model.keepAwake)
        }
        keepAwake.state = model.keepAwake ? .on : .off
        keepAwake.toolTip = "Like caffeinate -i: background work keeps running while the screen is locked. The display may still sleep; closing the lid still sleeps the Mac."
        menu.addItem(keepAwake)

        menu.addItem(item(model.snapshot.monitorMode ? "Test Lock (simulated)" : "Test Lock") { [actions] in actions.testLock() })
        menu.addItem(keySubmenu(model))
        menu.addItem(eventsSubmenu(model.recentEvents))
        menu.addItem(.separator())
        for entry in installationItems(model) { menu.addItem(entry) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacLatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusLine(for snapshot: GuardSnapshot) -> NSMenuItem {
        let (_, color) = Self.appearance(for: snapshot.state)
        let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        let label = snapshot.state == .pendingLock ? "YubiKey removed" : snapshot.state.displayName
        text.append(NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 0)]))
        if snapshot.monitorMode {
            text.append(NSAttributedString(string: "  (Monitor Mode)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        let item = NSMenuItem()
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    private func detailLines(for model: StatusViewModel) -> [String] {
        switch model.snapshot.state {
        case .armed:
            return ["Removing the YubiKey locks the screen" + (model.snapshot.monitorMode ? " (simulated)." : ".")]
        case .pendingLock:
            return ["Insert YubiKey or choose Disarm to cancel."]
        case .unarmed:
            guard model.configuredKey != nil else { return ["Choose a YubiKey under “Configure YubiKey”."] }
            switch model.snapshot.unarmedReason {
            case .lockTriggered: return ["Screen was locked. Insert your YubiKey to arm again."]
            case .lockSimulated: return ["Monitor Mode: would have locked. Insert your YubiKey to arm again."]
            case .lockFailed: return ["Locking failed (see log). Insert your YubiKey to arm again."]
            case .manualDisarm: return ["Disarmed. Re-insert your YubiKey to arm again."]
            case .lockBackendUnavailable: return ["Screen lock unavailable on this system."]
            case .presenceUncertain: return ["Key state was unclear, so nothing was locked."]
            default: return ["Insert your YubiKey to arm protection."]
            }
        }
    }

    private static func countdownText(_ model: StatusViewModel) -> String {
        let delay = model.snapshot.pendingLockDelay ?? model.snapshot.lockDelay
        var remaining = delay
        if let started = model.pendingLockStarted {
            remaining = max(.zero, delay - (ContinuousClock.now - started))
        }
        return String(format: "Locking in %.1f seconds…", seconds(remaining))
    }

    private func keySubmenu(_ model: StatusViewModel) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if model.detectedKeys.isEmpty {
            submenu.addItem(info(model.unidentifiedCount > 0 ? "Identifying…" : "No YubiKey detected. Insert one."))
        } else {
            submenu.addItem(info("Detected YubiKeys:"))
            for key in model.detectedKeys {
                let entry = item("Use \(key.name)  \(maskSerial(key.serial))") { [actions] in actions.useKey(key) }
                entry.state = key.serial == model.configuredKey?.serial ? .on : .off
                submenu.addItem(entry)
            }
        }
        if model.configuredKey != nil {
            submenu.addItem(.separator())
            submenu.addItem(item("Forget Configured YubiKey") { [actions] in actions.forgetKey() })
        }
        let parent = NSMenuItem(title: "Configure YubiKey", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func lockDelaySubmenu(current: Duration) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for seconds in SettingsStore.lockDelayOptions {
            var title = Self.lockDelayTitle(seconds)
            if seconds == SettingsStore.defaultLockDelaySeconds { title += " (default)" }
            let entry = item(title) { [actions] in actions.setLockDelay(seconds) }
            entry.state = current == .seconds(seconds) ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(info("Short delays tolerate fewer USB/dock resets."))
        submenu.addItem(info("Changes apply to the next removal."))

        let seconds = Int(current.components.seconds)
        let parent = NSMenuItem(title: "Lock after removal: \(Self.lockDelayTitle(seconds))", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private static func lockDelayTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Immediately"
        case 1: "1 second"
        default: "\(seconds) seconds"
        }
    }

    private func installationItems(_ model: StatusViewModel) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch model.loginItemState {
        case .enabled:
            let entry = item("Start at Login") { [actions] in actions.setStartAtLogin(false) }
            entry.state = .on
            items.append(entry)
        case .disabled:
            items.append(item("Start at Login") { [actions] in actions.setStartAtLogin(true) })
        case .requiresApproval:
            let entry = item("Start at Login: approve in System Settings…") { [actions] in actions.openLoginItemSettings() }
            entry.state = .mixed
            items.append(entry)
        case .unavailable:
            break
        }
        if !model.isInApplicationsFolder, model.loginItemState != .unavailable {
            items.append(item("Move to Applications Folder…") { [actions] in actions.moveToApplications() })
        }
        return items
    }

    private func eventsSubmenu(_ events: [String]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if events.isEmpty { submenu.addItem(info("No events yet")) }
        for event in events.reversed() { submenu.addItem(info(event)) }
        let parent = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    // MARK: - Item helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        item.isEnabled = false
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.isEnabled = true
        return item
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
