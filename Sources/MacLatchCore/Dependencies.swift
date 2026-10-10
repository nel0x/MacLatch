/// Triggers the regular macOS lock screen.
///
/// Implementations must never fall back to logout, shutdown, reboot,
/// killing `loginwindow` or similar aggressive actions.
public protocol LockService: Sendable {
    /// `false` if the lock mechanism cannot be used. The guard then refuses to arm.
    var isAvailable: Bool { get }
    func lock() async throws
}

/// Result of a one-time revalidation of the configured key's physical presence.
public enum KeyPresence: String, Equatable, Sendable {
    case present
    case absent
    /// The current state cannot be determined reliably (e.g. a Yubico device
    /// is attached but not yet identified). Treated as "do not lock".
    case uncertain
}

public protocol KeyPresenceChecker: Sendable {
    /// Performs a single, fresh presence check. Must not poll.
    func configuredKeyPresence() async -> KeyPresence
}

/// A cancellable one-shot timer.
public protocol GuardTimer: Sendable {
    func cancel()
}

public protocol GuardTimerScheduler: Sendable {
    /// Runs `action` once after `delay`, unless cancelled first.
    func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> any GuardTimer
}

/// Production scheduler: Swift Concurrency task sleeping on the monotonic `ContinuousClock`.
public struct ContinuousClockTimerScheduler: GuardTimerScheduler {
    public init() {}

    public func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> any GuardTimer {
        let task = Task {
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return // cancelled
            }
            guard !Task.isCancelled else { return }
            await action()
        }
        return TaskTimer(task: task)
    }

    private struct TaskTimer: GuardTimer {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}
