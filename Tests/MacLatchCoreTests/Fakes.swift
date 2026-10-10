import Foundation
@testable import MacLatchCore

final class FakeLockService: LockService, @unchecked Sendable {
    private let lock = NSLock()
    private var _lockCount = 0
    let isAvailable: Bool
    let failure: (any Error)?

    init(isAvailable: Bool = true, failure: (any Error)? = nil) {
        self.isAvailable = isAvailable
        self.failure = failure
    }

    var lockCount: Int { lock.withLock { _lockCount } }

    func lock() async throws {
        lock.withLock { _lockCount += 1 }
        if let failure { throw failure }
    }
}

struct FakeLockError: Error {}

final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class FakePresenceChecker: KeyPresenceChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var _presence: KeyPresence
    private var _checkCount = 0

    init(_ presence: KeyPresence = .absent) { _presence = presence }

    var presence: KeyPresence {
        get { lock.withLock { _presence } }
        set { lock.withLock { _presence = newValue } }
    }

    var checkCount: Int { lock.withLock { _checkCount } }

    func configuredKeyPresence() async -> KeyPresence {
        lock.withLock {
            _checkCount += 1
            return _presence
        }
    }
}

/// Records scheduled timers; tests fire them explicitly. No real time passes.
final class ManualTimerScheduler: GuardTimerScheduler, @unchecked Sendable {
    final class Entry: GuardTimer, @unchecked Sendable {
        let delay: Duration
        let action: @Sendable () async -> Void
        private let lock = NSLock()
        private var _isCancelled = false

        init(delay: Duration, action: @escaping @Sendable () async -> Void) {
            self.delay = delay
            self.action = action
        }

        var isCancelled: Bool { lock.withLock { _isCancelled } }
        func cancel() { lock.withLock { _isCancelled = true } }
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []

    var entries: [Entry] { lock.withLock { _entries } }

    func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> any GuardTimer {
        let entry = Entry(delay: delay, action: action)
        lock.withLock { _entries.append(entry) }
        return entry
    }

    /// Fires the most recent timer if it was not cancelled (like the real scheduler).
    func fireLatest() async {
        guard let entry = entries.last, !entry.isCancelled else { return }
        await entry.action()
    }

    /// Fires a timer even if it was cancelled, to simulate a cancellation race.
    func forceFire(_ index: Int) async {
        await entries[index].action()
    }
}
