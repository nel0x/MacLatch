import Darwin
import MacLatchCore
import os

/// Locks the screen via `SACLockScreenImmediate` from the private `login.framework`.
///
/// This is the same mechanism as "Lock Screen" in the Apple menu (Ctrl-Cmd-Q). macOS has no
/// public API for it. It needs no special permission and shows the regular lock screen, which
/// can be unlocked with password, Touch ID, Apple Watch, etc.
///
/// If the symbol cannot be resolved, `isAvailable` is `false` and the guard refuses to arm.
/// There is deliberately no fallback (no logout, no `CGSession -suspend`, no display sleep tricks).
final class MacOSLockService: LockService {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private let lockFunction: LockFunction?
    private let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "lock")

    enum LockError: Error {
        case unavailable
        case failed(status: Int32)
    }

    init() {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else {
            lockFunction = nil
            log.error("SACLockScreenImmediate unavailable; automatic locking disabled")
            return
        }
        lockFunction = unsafeBitCast(symbol, to: LockFunction.self)
    }

    var isAvailable: Bool { lockFunction != nil }

    func lock() async throws {
        guard let lockFunction else { throw LockError.unavailable }
        let status = await MainActor.run { lockFunction() }
        guard status == 0 else { throw LockError.failed(status: status) }
    }
}
