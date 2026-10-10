import Testing
@testable import MacLatchCore

@Suite("DeviceTracker")
struct DeviceTrackerTests {
    let configured = ConfiguredYubiKey(serial: 12_345_678, name: "YubiKey 5C NFC")
    let otherSerial: UInt32 = 87_654_321

    @Test func configuredKeyAttachAndRemoveProduceEvents() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        #expect(t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k") == .configuredKeyAttached)
        #expect(t.deviceRemoved(registryID: 1) == .configuredKeyRemoved)
    }

    // Test 9
    @Test func wrongYubiKeyInsertionIsIgnored() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 2)
        #expect(t.deviceIdentified(registryID: 2, serial: otherSerial, name: "other") == nil)
        #expect(!t.isConfiguredKeyAttached)
    }

    // Test 10
    @Test func wrongYubiKeyRemovalIsIgnoredEvenWhileConfiguredKeyAttached() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        _ = t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k")
        t.deviceAttached(registryID: 2)
        _ = t.deviceIdentified(registryID: 2, serial: otherSerial, name: "other")

        #expect(t.deviceRemoved(registryID: 2) == nil)
        #expect(t.isConfiguredKeyAttached)
    }

    @Test func noConfiguredKeyMeansNoEvents() {
        var t = DeviceTracker(configuredKey: nil)
        t.deviceAttached(registryID: 1)
        #expect(t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k") == nil)
        #expect(t.deviceRemoved(registryID: 1) == nil)
        #expect(t.presence(currentRegistryIDs: [1]) == .absent)
    }

    @Test func interfaceResetReidentificationProducesNoEvent() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        _ = t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k")
        // HID/FIDO interface re-enumerated, physical USB device unchanged.
        t.deviceAttached(registryID: 1)
        #expect(t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k") == nil)
        #expect(t.isConfiguredKeyAttached)
    }

    @Test func reenumerationWithOverlappingEntriesDoesNotProduceRemoval() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        _ = t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k")
        // New registry entry identified before the old termination is delivered.
        t.deviceAttached(registryID: 5)
        #expect(t.deviceIdentified(registryID: 5, serial: configured.serial, name: "k") == nil)
        #expect(t.deviceRemoved(registryID: 1) == nil)
        #expect(t.deviceRemoved(registryID: 5) == .configuredKeyRemoved)
    }

    /// Regression: the FIDO interface was visible but the USB device matching was broken,
    /// so the key armed and its removal was never reported.
    @Test func identificationWithoutUSBArrivalNeverArms() {
        var t = DeviceTracker(configuredKey: configured)
        #expect(t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k") == nil)
        #expect(!t.isConfiguredKeyAttached)
        #expect(t.presence(currentRegistryIDs: []) == .absent)
    }

    @Test func disarmThenReplugProducesFreshAttachEvent() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        #expect(t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k") == .configuredKeyAttached)
        #expect(t.deviceRemoved(registryID: 1) == .configuredKeyRemoved)
        t.deviceAttached(registryID: 2)
        #expect(t.deviceIdentified(registryID: 2, serial: configured.serial, name: "k") == .configuredKeyAttached)
    }

    @Test func removalOfUnknownDeviceIsIgnored() {
        var t = DeviceTracker(configuredKey: configured)
        #expect(t.deviceRemoved(registryID: 42) == nil)
    }

    @Test func failedIdentificationNeverArms() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        t.identificationFailed(registryID: 1)
        #expect(!t.isConfiguredKeyAttached)
        #expect(t.deviceRemoved(registryID: 1) == nil)
    }

    @Test func changingConfiguredKeyDisarmsAndReattachesIfPresent() {
        var t = DeviceTracker(configuredKey: nil)
        t.deviceAttached(registryID: 1)
        _ = t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k")
        #expect(t.setConfiguredKey(configured) == [.configurationChanged, .configuredKeyAttached])
        #expect(t.setConfiguredKey(nil) == [.configurationChanged])
    }

    @Test func presenceClassification() {
        var t = DeviceTracker(configuredKey: configured)
        t.deviceAttached(registryID: 1)
        _ = t.deviceIdentified(registryID: 1, serial: configured.serial, name: "k")
        t.deviceAttached(registryID: 2)
        _ = t.deviceIdentified(registryID: 2, serial: otherSerial, name: "other")
        t.deviceAttached(registryID: 3) // pending

        #expect(t.presence(currentRegistryIDs: []) == .absent)
        #expect(t.presence(currentRegistryIDs: [1]) == .present)
        #expect(t.presence(currentRegistryIDs: [2]) == .absent)
        #expect(t.presence(currentRegistryIDs: [2, 3]) == .uncertain)
        #expect(t.presence(currentRegistryIDs: [1, 3]) == .present)
        // Attached in IOKit but arrival not processed yet: cannot decide.
        #expect(t.presence(currentRegistryIDs: [99]) == .uncertain)
        // Tracker still lists 1, but IOKit says it is gone: fresh lookup wins.
        #expect(t.presence(currentRegistryIDs: [2]) == .absent)
    }

    @Test func serialMasking() {
        #expect(maskSerial(12_345_678) == "••••5678")
        #expect(maskSerial(42) == "••••42")
    }
}
