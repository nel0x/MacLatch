import AppKit
import MacLatchCore
import os

/// Wires the components together:
///
///     YubiKeyMonitor ──events──▶ GuardStateMachine ──▶ LockService
///                                        │
///                                        └──snapshots──▶ StatusItemController
@MainActor
final class AppController {
    private let settings = SettingsStore()
    private let lockService = MacOSLockService()
    private let sleepPreventer = SleepPreventer()
    private let machine: GuardStateMachine
    private let eventContinuation: AsyncStream<GuardEvent>.Continuation
    private var monitor: YubiKeyMonitor!
    private var statusItem: StatusItemController!

    private var snapshot: GuardSnapshot
    private var pendingLockStarted: ContinuousClock.Instant?
    private var recentEvents: [String] = []
    private let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "app")

    init() {
        let presence = MonitorPresenceChecker()
        machine = GuardStateMachine(
            lockService: lockService,
            presenceChecker: presence,
            lockDelay: settings.lockDelay,
            monitorMode: settings.monitorMode
        )
        snapshot = GuardSnapshot(state: .unarmed, unarmedReason: .waitingForKey, monitorMode: settings.monitorMode, lockDelay: settings.lockDelay)

        // A single ordered queue into the actor: events are handled strictly one after another.
        let (events, continuation) = AsyncStream.makeStream(of: GuardEvent.self)
        eventContinuation = continuation
        Task { [machine] in
            for await event in events { await machine.handle(event) }
        }

        monitor = YubiKeyMonitor(
            configuredKey: settings.configuredKey,
            onEvent: { [continuation] event in continuation.yield(event) },
            onChange: { [weak self] message in self?.record(message) }
        )
        presence.monitor = monitor

        statusItem = StatusItemController(model: { [unowned self] in viewModel() }, actions: makeActions())
    }

    func start() {
        log.notice("MacLatch starting, monitor mode: \(self.settings.monitorMode), lock backend available: \(self.lockService.isAvailable)")
        record("Started" + (settings.monitorMode ? " (Monitor Mode)" : ""))
        if !lockService.isAvailable { record("Lock backend unavailable") }

        Task { [machine] in
            for await snapshot in machine.snapshots { self.apply(snapshot) }
        }
        observeSleepWake()
        monitor.start()
        if settings.keepAwake { setKeepAwake(true) }

        // After the status item is up and monitoring runs (it continues during modal dialogs).
        DispatchQueue.main.async { [weak self] in self?.onboarding.run() }
    }

    private var onboarding: Onboarding {
        Onboarding(settings: settings, record: { [weak self] message in self?.record(message) })
    }

    // MARK: - State

    private func apply(_ new: GuardSnapshot) {
        let old = snapshot
        snapshot = new
        if new.state == .pendingLock, old.state != .pendingLock { pendingLockStarted = .now }
        if new.state != .pendingLock { pendingLockStarted = nil }

        if new.state != old.state || new.unarmedReason != old.unarmedReason {
            var line = "State: \(new.state.displayName)"
            if new.unarmedReason == .lockSimulated { line = "Would lock now. " + line }
            if let reason = new.unarmedReason, new.state == .unarmed { line += " (\(reason.rawValue))" }
            record(line)
        }
        statusItem.render(new)
    }

    private func record(_ message: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        recentEvents.append("[\(time)] \(message)")
        if recentEvents.count > 25 { recentEvents.removeFirst(recentEvents.count - 25) }
        statusItem?.refreshIfOpen()
    }

    private func viewModel() -> StatusViewModel {
        StatusViewModel(
            snapshot: snapshot,
            pendingLockStarted: pendingLockStarted,
            configuredKey: settings.configuredKey,
            detectedKeys: monitor.detectedKeys,
            unidentifiedCount: monitor.unidentifiedCount,
            lockBackendAvailable: lockService.isAvailable,
            recentEvents: recentEvents,
            loginItemState: LoginItem.state,
            isInApplicationsFolder: AppInstallation.isInApplicationsFolder,
            keepAwake: sleepPreventer.isActive
        )
    }

    // MARK: - Actions

    private func makeActions() -> StatusActions {
        StatusActions(
            disarm: { [unowned self] in send(.manualDisarm) },
            testLock: { [machine] in Task { await machine.performTestLock() } },
            setMonitorMode: { [unowned self] enabled in
                settings.monitorMode = enabled
                record("Monitor Mode \(enabled ? "on" : "off")")
                send(.monitorModeChanged(enabled: enabled))
            },
            setLockDelay: { [unowned self] seconds in
                settings.lockDelaySeconds = seconds
                record("Lock delay set to \(seconds) s")
                send(.lockDelayChanged(settings.lockDelay))
            },
            useKey: { [unowned self] key in
                let configured = ConfiguredYubiKey(serial: key.serial, name: key.name)
                settings.configuredKey = configured
                record("Configured \(key.name) \(configured.maskedSerial)")
                monitor.setConfiguredKey(configured)
            },
            forgetKey: { [unowned self] in
                settings.configuredKey = nil
                record("Configured YubiKey removed from settings")
                monitor.setConfiguredKey(nil)
            },
            setKeepAwake: { [unowned self] enabled in setKeepAwake(enabled) },
            setStartAtLogin: { [unowned self] enabled in onboarding.setStartAtLogin(enabled) },
            openLoginItemSettings: { LoginItem.openSystemSettings() },
            moveToApplications: { [unowned self] in onboarding.offerMoveToApplications() }
        )
    }

    private func setKeepAwake(_ enabled: Bool) {
        settings.keepAwake = enabled
        if sleepPreventer.setActive(enabled) {
            record(enabled ? "Keep Mac awake: on (idle sleep prevented)" : "Keep Mac awake: off")
        } else {
            record("Keep Mac awake could not be enabled")
        }
        statusItem.refreshIfOpen()
    }

    private func send(_ event: GuardEvent) {
        eventContinuation.yield(event)
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let continuation = eventContinuation
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            continuation.yield(.systemWillSleep)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            continuation.yield(.systemDidWake)
        }
    }
}

/// Bridges the state machine's revalidation request to the main-actor monitor.
private final class MonitorPresenceChecker: KeyPresenceChecker, @unchecked Sendable {
    // Set once during setup on the main actor, only read on the main actor afterwards.
    @MainActor weak var monitor: YubiKeyMonitor?

    func configuredKeyPresence() async -> KeyPresence {
        await MainActor.run { monitor?.currentPresence() ?? .uncertain }
    }
}
