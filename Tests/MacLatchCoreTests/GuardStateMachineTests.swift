import Testing
@testable import MacLatchCore

private struct Harness {
    let lockService: FakeLockService
    let presence: FakePresenceChecker
    let timers = ManualTimerScheduler()
    let machine: GuardStateMachine

    init(
        lockService: FakeLockService = FakeLockService(),
        presence: KeyPresence = .absent,
        monitorMode: Bool = false
    ) {
        self.lockService = lockService
        self.presence = FakePresenceChecker(presence)
        machine = GuardStateMachine(
            lockService: lockService,
            presenceChecker: self.presence,
            timerScheduler: timers,
            lockDelay: .seconds(3),
            monitorMode: monitorMode
        )
    }

    /// Drives the machine to `armed` -> removal -> timer expiry with the key absent.
    func armRemoveAndExpire() async {
        await machine.handle(.configuredKeyAttached)
        await machine.handle(.configuredKeyRemoved)
        presence.presence = .absent
        await timers.fireLatest()
    }
}

@Suite("GuardStateMachine")
struct GuardStateMachineTests {
    // Test 1 / Test 7
    @Test func startsUnarmedWithoutKey() async {
        let h = Harness()
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .waitingForKey)
        #expect(h.lockService.lockCount == 0)
        #expect(h.timers.entries.isEmpty)
    }

    @Test func removalWhileUnarmedIsIgnored() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyRemoved)
        #expect(await h.machine.state == .unarmed)
        #expect(h.timers.entries.isEmpty)
    }

    // Test 2 / Test 8 (startup with key present arrives as an attach event)
    @Test func insertingConfiguredKeyArms() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .armed)
    }

    // Test 3
    @Test func removingConfiguredKeyStartsThreeSecondGracePeriod() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        #expect(await h.machine.state == .pendingLock)
        #expect(h.timers.entries.count == 1)
        #expect(h.timers.entries[0].delay == .seconds(3))
        #expect(h.lockService.lockCount == 0)
    }

    // Test 4
    @Test func reinsertBeforeTimeoutCancelsLock() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.configuredKeyAttached)

        #expect(await h.machine.state == .armed)
        #expect(h.timers.entries[0].isCancelled)

        await h.timers.fireLatest() // cancelled: does nothing
        #expect(await h.machine.state == .armed)
        #expect(h.lockService.lockCount == 0)
    }

    // Test 5
    @Test func timeoutWithKeyAbsentLocksExactlyOnceThenUnarmed() async {
        let h = Harness()
        await h.armRemoveAndExpire()

        #expect(h.presence.checkCount == 1) // final revalidation happened
        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .lockTriggered)
    }

    // Test 6 + "no lock loop" regression
    @Test func unlockWithoutKeyStaysUnarmedNoLockLoop() async {
        let h = Harness()
        await h.armRemoveAndExpire()
        #expect(h.lockService.lockCount == 1)

        // User unlocks with password / Touch ID; key stays absent. Wake, sleep, stray
        // removals and refiring the old timer must not lock again.
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.systemWillSleep)
        await h.machine.handle(.systemDidWake)
        await h.machine.handle(.configuredKeyRemoved)
        await h.timers.forceFire(0)

        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)
        #expect(h.timers.entries.count == 1)
    }

    @Test func reinsertAfterLockRearms() async {
        let h = Harness()
        await h.armRemoveAndExpire()
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .armed)
    }

    // Test 9 / 10: identity filtering is covered in DeviceTrackerTests; the machine only
    // ever receives events for the configured key.

    // Test 11
    @Test func usbReconnectDuringGracePeriodRevalidatesPresentAndStaysArmed() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)

        // Re-enumeration happened but its attach event has not been processed yet.
        h.presence.presence = .present
        await h.timers.fireLatest()

        #expect(await h.machine.state == .armed)
        #expect(h.lockService.lockCount == 0)
    }

    @Test func uncertainRevalidationDoesNotLockAndDisarms() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        h.presence.presence = .uncertain
        await h.timers.fireLatest()

        #expect(h.lockService.lockCount == 0)
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .presenceUncertain)
    }

    // Test 12
    @Test func lockBackendUnavailableNeverArms() async {
        let h = Harness(lockService: FakeLockService(isAvailable: false))
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .lockBackendUnavailable)

        await h.machine.handle(.configuredKeyRemoved)
        #expect(h.timers.entries.isEmpty)
        #expect(h.lockService.lockCount == 0)
    }

    @Test func lockFailureEndsUnarmedWithoutRetry() async {
        let h = Harness(lockService: FakeLockService(failure: FakeLockError()))
        await h.armRemoveAndExpire()

        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .lockFailed)
    }

    @Test func staleTimerCannotLockAfterRearmAndSecondRemoval() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved) // timer 0
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved) // timer 1
        #expect(h.timers.entries.count == 2)

        await h.timers.forceFire(0) // old timer fires despite cancellation
        #expect(await h.machine.state == .pendingLock)
        #expect(h.lockService.lockCount == 0)

        await h.timers.fireLatest()
        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)
    }

    @Test func rapidRemoveInsertRemoveSequence() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        for _ in 0..<10 {
            await h.machine.handle(.configuredKeyRemoved)
            await h.machine.handle(.configuredKeyAttached)
        }
        #expect(await h.machine.state == .armed)
        #expect(h.timers.entries.allSatisfy { $0.isCancelled })
        for i in h.timers.entries.indices { await h.timers.forceFire(i) }
        #expect(h.lockService.lockCount == 0)
        #expect(await h.machine.state == .armed)
    }

    @Test func manualDisarmCancelsPendingLockAndStaysUnarmed() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.manualDisarm)

        #expect(await h.machine.state == .unarmed)
        #expect(h.timers.entries[0].isCancelled)
        await h.timers.forceFire(0)
        #expect(h.lockService.lockCount == 0)

        // Survives sleep/wake; only a new insertion re-arms.
        h.presence.presence = .present
        await h.machine.handle(.systemWillSleep)
        await h.machine.handle(.systemDidWake)
        #expect(await h.machine.unarmedReason == .manualDisarm)
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .armed)
    }

    @Test func monitorModeSimulatesLockWithoutLocking() async {
        let h = Harness(lockService: FakeLockService(isAvailable: false), monitorMode: true)
        await h.armRemoveAndExpire()

        #expect(h.lockService.lockCount == 0)
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .lockSimulated)
    }

    @Test func leavingMonitorModeWithoutBackendDisarms() async {
        let h = Harness(lockService: FakeLockService(isAvailable: false), monitorMode: true)
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .armed)

        await h.machine.handle(.monitorModeChanged(enabled: false))
        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .lockBackendUnavailable)
    }

    @Test func sleepCancelsPendingLock() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.systemWillSleep)

        #expect(await h.machine.unarmedReason == .systemSleep)
        await h.timers.forceFire(0)
        #expect(h.lockService.lockCount == 0)
    }

    @Test func attachEventsWhileAsleepDoNotArm() async {
        let h = Harness()
        await h.machine.handle(.systemWillSleep)
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .unarmed)
    }

    @Test func wakeWithKeyPresentRearms() async {
        let h = Harness(presence: .present)
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.systemWillSleep)
        await h.machine.handle(.systemDidWake)
        #expect(await h.machine.state == .armed)
    }

    @Test(arguments: [KeyPresence.absent, .uncertain])
    func wakeWithoutVerifiableKeyStaysUnarmedAndNeverLocks(presence: KeyPresence) async {
        let h = Harness(presence: presence)
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.systemWillSleep)
        await h.machine.handle(.systemDidWake)

        #expect(await h.machine.state == .unarmed)
        #expect(await h.machine.unarmedReason == .waitingForKey)
        #expect(h.timers.entries.isEmpty)
        #expect(h.lockService.lockCount == 0)

        // A later real insertion arms normally.
        await h.machine.handle(.configuredKeyAttached)
        #expect(await h.machine.state == .armed)
    }

    @Test func configurationChangeDisarms() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.configurationChanged)
        #expect(await h.machine.state == .unarmed)
        await h.timers.forceFire(0)
        #expect(h.lockService.lockCount == 0)
    }

    @Test func testLockDoesNotChangeState() async {
        let h = Harness()
        await h.machine.performTestLock()
        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)

        let monitor = Harness(monitorMode: true)
        await monitor.machine.performTestLock()
        #expect(monitor.lockService.lockCount == 0)
    }

    @Test func changedLockDelayAppliesToNextRemoval() async {
        let h = Harness()
        await h.machine.handle(.lockDelayChanged(.seconds(10)))
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        #expect(h.timers.entries[0].delay == .seconds(10))
        #expect(await h.machine.snapshot.pendingLockDelay == .seconds(10))
    }

    @Test func changingLockDelayDuringGracePeriodKeepsRunningTimer() async {
        let h = Harness()
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        await h.machine.handle(.lockDelayChanged(.seconds(15)))

        #expect(await h.machine.state == .pendingLock)
        #expect(!h.timers.entries[0].isCancelled)
        #expect(await h.machine.snapshot.pendingLockDelay == .seconds(3))
        #expect(await h.machine.snapshot.lockDelay == .seconds(15))

        await h.timers.fireLatest()
        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)
    }

    @Test func zeroDelayStillRevalidatesAndLocksExactlyOnce() async {
        let h = Harness()
        await h.machine.handle(.lockDelayChanged(.zero))
        await h.armRemoveAndExpire()

        #expect(h.timers.entries[0].delay == .zero)
        #expect(h.presence.checkCount == 1)
        #expect(h.lockService.lockCount == 1)
        #expect(await h.machine.state == .unarmed)

        await h.machine.handle(.configuredKeyRemoved)
        #expect(h.lockService.lockCount == 1)
    }

    @Test func zeroDelayWithKeyBackAtRevalidationDoesNotLock() async {
        let h = Harness()
        await h.machine.handle(.lockDelayChanged(.zero))
        await h.machine.handle(.configuredKeyAttached)
        await h.machine.handle(.configuredKeyRemoved)
        h.presence.presence = .present
        await h.timers.fireLatest()
        #expect(h.lockService.lockCount == 0)
        #expect(await h.machine.state == .armed)
    }

    @Test func negativeLockDelayIsClampedToZero() async {
        let h = Harness()
        await h.machine.handle(.lockDelayChanged(.seconds(-5)))
        #expect(await h.machine.lockDelay == .zero)
    }

    @Test func snapshotsReflectTransitions() async {
        let h = Harness()
        var iterator = h.machine.snapshots.makeAsyncIterator()
        #expect(await iterator.next()?.state == .unarmed)
        await h.machine.handle(.configuredKeyAttached)
        #expect(await iterator.next()?.state == .armed)
        await h.machine.handle(.configuredKeyRemoved)
        #expect(await iterator.next()?.state == .pendingLock)
    }
}

@Suite("ContinuousClockTimerScheduler")
struct ContinuousClockTimerSchedulerTests {
    @Test func firesAfterDelay() async throws {
        let flag = Flag()
        _ = ContinuousClockTimerScheduler().schedule(after: .milliseconds(20)) { flag.set() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(flag.isSet)
    }

    @Test func cancelledTimerNeverFires() async throws {
        let flag = Flag()
        let timer = ContinuousClockTimerScheduler().schedule(after: .milliseconds(50)) { flag.set() }
        timer.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!flag.isSet)
    }
}
