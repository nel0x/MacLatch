import IOKit.pwr_mgt
import os

/// "Keep Mac awake", equivalent to `caffeinate -i`: holds a power assertion that prevents
/// *idle* system sleep, so background work (agents, builds, downloads) keeps running while
/// the screen is locked. The display may still sleep and the screen still locks.
/// It does not prevent sleep from closing the lid or choosing Sleep manually.
///
/// The kernel releases the assertion automatically if the app quits or crashes.
@MainActor
final class SleepPreventer {
    private var assertionID: IOPMAssertionID?
    private let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "power")

    var isActive: Bool { assertionID != nil }

    /// Returns `false` if the assertion could not be created.
    @discardableResult
    func setActive(_ active: Bool) -> Bool {
        if active {
            guard assertionID == nil else { return true }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString, // kIOPMAssertionTypePreventUserIdleSystemSleep
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MacLatch: keep background work running while the screen is locked" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                log.error("could not create sleep assertion: \(result)")
                return false
            }
            assertionID = id
            log.notice("idle system sleep prevented")
        } else if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
            log.notice("idle system sleep allowed again")
        }
        return true
    }
}
