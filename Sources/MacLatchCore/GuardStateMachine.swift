import os

/// The single source of truth for the protection state.
///
/// Invariants:
/// - Starts `unarmed`. Nothing here is persisted.
/// - Only `configuredKeyAttached` (or a wake with the key verifiably present) can arm.
/// - Arming is refused when no lock backend is usable.
/// - A lock happens only after: armed -> removal -> full grace period -> revalidation says `absent`.
/// - Before the lock is triggered the state becomes `unarmed`, so a lock happens at most
///   once per removal and the user can never end up in a lock loop.
/// - Every pending-lock timer is bound to the pending state that created it; stale timers are ignored.
public actor GuardStateMachine {
    private struct PendingLock {
        let id: UInt64
        /// The delay this timer was started with; later setting changes do not affect it.
        let delay: Duration
        let timer: any GuardTimer
    }

    private enum Phase {
        case unarmed(UnarmedReason)
        case armed
        case pendingLock(PendingLock)
    }

    /// Grace period for the *next* removal. Never negative.
    public private(set) var lockDelay: Duration
    /// Emits the current snapshot on every change. Single consumer (the UI).
    public nonisolated let snapshots: AsyncStream<GuardSnapshot>

    private let lockService: any LockService
    private let presenceChecker: any KeyPresenceChecker
    private let timerScheduler: any GuardTimerScheduler
    private let snapshotContinuation: AsyncStream<GuardSnapshot>.Continuation
    private let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "guard")

    private var phase: Phase = .unarmed(.waitingForKey)
    private var monitorMode: Bool
    private var nextPendingID: UInt64 = 0

    public init(
        lockService: any LockService,
        presenceChecker: any KeyPresenceChecker,
        timerScheduler: any GuardTimerScheduler = ContinuousClockTimerScheduler(),
        lockDelay: Duration = .seconds(3),
        monitorMode: Bool
    ) {
        self.lockService = lockService
        self.presenceChecker = presenceChecker
        self.timerScheduler = timerScheduler
        let lockDelay = max(.zero, lockDelay)
        self.lockDelay = lockDelay
        self.monitorMode = monitorMode
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        snapshotContinuation.yield(Self.makeSnapshot(phase: .unarmed(.waitingForKey), monitorMode: monitorMode, lockDelay: lockDelay))
    }

    deinit {
        snapshotContinuation.finish()
    }

    // MARK: - Public API

    public var state: GuardState { Self.state(of: phase) }

    public var unarmedReason: UnarmedReason? {
        if case .unarmed(let reason) = phase { return reason }
        return nil
    }

    public var snapshot: GuardSnapshot {
        Self.makeSnapshot(phase: phase, monitorMode: monitorMode, lockDelay: lockDelay)
    }

    public func handle(_ event: GuardEvent) async {
        log.info("event: \(String(describing: event), privacy: .public) in state \(self.state.rawValue, privacy: .public)")

        switch event {
        case .configuredKeyAttached:
            handleKeyAttached()

        case .configuredKeyRemoved:
            handleKeyRemoved()

        case .manualDisarm:
            transition(to: .unarmed(.manualDisarm), because: "manual disarm")

        case .configurationChanged:
            transition(to: .unarmed(.configurationChanged), because: "configuration changed")

        case .monitorModeChanged(let enabled):
            monitorMode = enabled
            switch phase {
            case .armed, .pendingLock:
                if !canLock {
                    transition(to: .unarmed(.lockBackendUnavailable), because: "monitor mode off, lock backend unavailable")
                } else {
                    publish()
                }
            case .unarmed:
                publish()
            }

        case .lockDelayChanged(let delay):
            // Applies to the next removal. A running grace period keeps its delay.
            lockDelay = max(.zero, delay)
            log.notice("lock delay set to \(String(describing: self.lockDelay), privacy: .public)")
            publish()

        case .systemWillSleep:
            if case .unarmed(.manualDisarm) = phase { return }
            transition(to: .unarmed(.systemSleep), because: "system will sleep")

        case .systemDidWake:
            await handleWake()
        }
    }

    /// Manual "Test Lock" from the menu. Does not change the guard state.
    public func performTestLock() async {
        if monitorMode {
            log.notice("test lock: monitor mode, would lock now")
            return
        }
        guard lockService.isAvailable else {
            log.error("test lock: lock backend unavailable")
            return
        }
        do {
            try await lockService.lock()
            log.notice("test lock: screen locked")
        } catch {
            log.error("test lock failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Transitions

    private var canLock: Bool { monitorMode || lockService.isAvailable }

    private func handleKeyAttached() {
        switch phase {
        case .unarmed(.systemSleep):
            log.info("ignoring key attach while system is asleep")
        case .unarmed:
            arm(because: "configured YubiKey attached")
        case .armed:
            break
        case .pendingLock:
            arm(because: "configured YubiKey re-attached during grace period")
        }
    }

    private func handleKeyRemoved() {
        guard case .armed = phase else { return }

        nextPendingID += 1
        let id = nextPendingID
        let delay = lockDelay
        let timer = timerScheduler.schedule(after: delay) { [weak self] in
            await self?.lockTimerExpired(id: id)
        }
        log.info("lock timer \(id) started (\(String(describing: delay), privacy: .public))")
        transition(to: .pendingLock(PendingLock(id: id, delay: delay, timer: timer)), because: "configured YubiKey removed")
    }

    private func handleWake() async {
        guard case .unarmed(.systemSleep) = phase else { return }

        let presence = await presenceChecker.configuredKeyPresence()
        log.info("wake revalidation: \(presence.rawValue, privacy: .public)")

        // Events may have been processed while awaiting; only act on the state we checked for.
        guard case .unarmed(.systemSleep) = phase else { return }

        if presence == .present {
            arm(because: "system woke with configured YubiKey present")
        } else {
            transition(to: .unarmed(.waitingForKey), because: "system woke, configured YubiKey not verifiably present")
        }
    }

    private func lockTimerExpired(id: UInt64) async {
        guard case .pendingLock(let pending) = phase, pending.id == id else {
            log.info("ignoring stale lock timer \(id)")
            return
        }

        let presence = await presenceChecker.configuredKeyPresence()
        log.info("revalidation for lock timer \(id): \(presence.rawValue, privacy: .public)")

        // The actor may have processed other events while awaiting the check.
        guard case .pendingLock(let current) = phase, current.id == id else {
            log.info("state changed during revalidation, lock timer \(id) discarded")
            return
        }

        // From here on the timer has fired; it is ours and needs no cancellation.
        switch presence {
        case .present:
            arm(because: "revalidation found configured YubiKey present", cancellingTimer: false)
        case .uncertain:
            transition(to: .unarmed(.presenceUncertain), because: "revalidation uncertain, not locking", cancellingTimer: false)
        case .absent:
            await lockOnce()
        }
    }

    /// Leaves `pendingLock` for `unarmed` *before* locking, so this can run at most once
    /// per removal and nothing can trigger another lock until the key is inserted again.
    private func lockOnce() async {
        if monitorMode {
            transition(to: .unarmed(.lockSimulated), because: "monitor mode: would lock now", cancellingTimer: false)
            return
        }

        transition(to: .unarmed(.lockTriggered), because: "locking screen", cancellingTimer: false)
        do {
            try await lockService.lock()
            log.notice("screen lock triggered")
        } catch {
            log.error("screen lock failed: \(String(describing: error), privacy: .public)")
            // No retry and no fallback. Only update the reason if nothing else happened meanwhile.
            if case .unarmed(.lockTriggered) = phase {
                transition(to: .unarmed(.lockFailed), because: "lock backend error")
            }
        }
    }

    private func arm(because reason: String, cancellingTimer: Bool = true) {
        guard canLock else {
            transition(to: .unarmed(.lockBackendUnavailable), because: "\(reason), but lock backend unavailable", cancellingTimer: cancellingTimer)
            return
        }
        transition(to: .armed, because: reason, cancellingTimer: cancellingTimer)
    }

    /// The only place that assigns `phase`. Leaving `pendingLock` cancels its timer,
    /// except when the transition is made by that timer's own (already fired) callback.
    /// Even an uncancelled stale timer is harmless: `lockTimerExpired` checks the pending ID.
    private func transition(to newPhase: Phase, because reason: String, cancellingTimer: Bool = true) {
        if cancellingTimer, case .pendingLock(let pending) = phase {
            pending.timer.cancel()
            log.info("lock timer \(pending.id) cancelled")
        }
        let from = Self.state(of: phase)
        phase = newPhase
        log.notice("\(from.rawValue, privacy: .public) -> \(Self.state(of: newPhase).rawValue, privacy: .public), reason: \(reason, privacy: .public)")
        publish()
    }

    private func publish() {
        snapshotContinuation.yield(snapshot)
    }

    private static func state(of phase: Phase) -> GuardState {
        switch phase {
        case .unarmed: .unarmed
        case .armed: .armed
        case .pendingLock: .pendingLock
        }
    }

    private static func makeSnapshot(phase: Phase, monitorMode: Bool, lockDelay: Duration) -> GuardSnapshot {
        var reason: UnarmedReason?
        var pendingLockDelay: Duration?
        switch phase {
        case .unarmed(let r): reason = r
        case .armed: break
        case .pendingLock(let pending): pendingLockDelay = pending.delay
        }
        return GuardSnapshot(
            state: state(of: phase),
            unarmedReason: reason,
            monitorMode: monitorMode,
            lockDelay: lockDelay,
            pendingLockDelay: pendingLockDelay
        )
    }
}
