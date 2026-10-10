/// The externally visible protection state.
///
/// This value is runtime-only. It must never be persisted.
public enum GuardState: String, Equatable, Sendable {
    case unarmed
    case armed
    case pendingLock

    public var displayName: String {
        switch self {
        case .unarmed: "Unarmed"
        case .armed: "Armed"
        case .pendingLock: "Locking…"
        }
    }
}

/// Why the guard is currently unarmed. Informational, except for
/// `.systemSleep`, which suppresses arming until the system has woken up.
public enum UnarmedReason: String, Equatable, Sendable {
    /// Normal idle state: app start, or the configured key is not attached.
    case waitingForKey
    /// The user explicitly disarmed. Only a new insertion re-arms.
    case manualDisarm
    /// The app triggered a screen lock. Only a new insertion re-arms.
    case lockTriggered
    /// Monitor mode: a lock would have been triggered, but was only logged.
    case lockSimulated
    /// The lock backend reported an error. No retry, no fallback.
    case lockFailed
    /// No usable lock backend exists, so arming is refused.
    case lockBackendUnavailable
    /// Revalidation could not decide whether the key is present.
    case presenceUncertain
    /// The system is going to sleep or is asleep.
    case systemSleep
    /// The configured key or a guard setting changed.
    case configurationChanged
}

/// Inputs to the state machine. Delivered serially.
public enum GuardEvent: Equatable, Sendable {
    /// The configured YubiKey was physically attached and positively identified.
    case configuredKeyAttached
    /// The last attached instance of the configured YubiKey was physically removed.
    case configuredKeyRemoved
    /// The user chose "Disarm".
    case manualDisarm
    /// The configured key selection changed.
    case configurationChanged
    case monitorModeChanged(enabled: Bool)
    /// New grace period for the next removal. Negative values are treated as zero.
    case lockDelayChanged(Duration)
    case systemWillSleep
    case systemDidWake
}

/// What the UI needs to render the current state.
public struct GuardSnapshot: Equatable, Sendable {
    public let state: GuardState
    /// Set only while `state == .unarmed`.
    public let unarmedReason: UnarmedReason?
    public let monitorMode: Bool
    /// Configured grace period for the next removal.
    public let lockDelay: Duration
    /// Grace period of the running countdown. Set only while `state == .pendingLock`.
    public let pendingLockDelay: Duration?

    public init(state: GuardState, unarmedReason: UnarmedReason?, monitorMode: Bool, lockDelay: Duration, pendingLockDelay: Duration? = nil) {
        self.state = state
        self.unarmedReason = unarmedReason
        self.monitorMode = monitorMode
        self.lockDelay = lockDelay
        self.pendingLockDelay = pendingLockDelay
    }
}
