/// Yubico's USB vendor ID.
public let yubicoVendorID = 0x1050

/// The YubiKey selected by the user. Only this key drives the state machine.
public struct ConfiguredYubiKey: Codable, Equatable, Sendable {
    public let serial: UInt32
    public let name: String

    public init(serial: UInt32, name: String) {
        self.serial = serial
        self.name = name
    }

    public var maskedSerial: String { maskSerial(serial) }
}

/// "••••5678". Avoids exposing the full serial in UI and logs.
public func maskSerial(_ serial: UInt32) -> String {
    let digits = String(serial)
    return "••••" + String(digits.suffix(4))
}

/// A physically attached Yubico USB device, as known to the tracker.
public struct TrackedYubiKey: Equatable, Sendable {
    public enum Identity: Equatable, Sendable {
        /// Attached, identification not finished yet.
        case pending
        case identified(serial: UInt32, name: String)
        /// Identification failed (e.g. FIDO interface disabled, serial not readable).
        case failed
    }

    /// IORegistry entry ID of the physical USB device (not of an interface).
    public let registryID: UInt64
    public var identity: Identity
}

/// Tracks attached Yubico USB devices by physical USB device and their identities,
/// and turns that into guard events for the configured key only.
///
/// - Only presence edges of the *configured* key produce events
///   (none present -> some present: attached; some present -> none present: removed).
/// - Other YubiKeys never produce events.
/// - Interface resets (re-identification of an already known device) produce no events.
public struct DeviceTracker: Sendable {
    public private(set) var configuredKey: ConfiguredYubiKey?
    private var devices: [UInt64: TrackedYubiKey] = [:]

    public init(configuredKey: ConfiguredYubiKey?) {
        self.configuredKey = configuredKey
    }

    public var attachedDevices: [TrackedYubiKey] {
        devices.values.sorted { $0.registryID < $1.registryID }
    }

    public var isConfiguredKeyAttached: Bool {
        devices.values.contains { isConfigured($0) }
    }

    /// A Yubico USB device appeared. It is unidentified until `deviceIdentified` is called.
    public mutating func deviceAttached(registryID: UInt64) {
        guard devices[registryID] == nil else { return }
        devices[registryID] = TrackedYubiKey(registryID: registryID, identity: .pending)
    }

    /// Identification finished. Ignored unless the USB device is known via `deviceAttached`:
    /// a key may only arm if the removal monitoring can see it, otherwise its removal
    /// would go unnoticed and the tracker would never see the key leave.
    public mutating func deviceIdentified(registryID: UInt64, serial: UInt32, name: String) -> GuardEvent? {
        guard devices[registryID] != nil else { return nil }
        return updatingPresence {
            $0.devices[registryID] = TrackedYubiKey(registryID: registryID, identity: .identified(serial: serial, name: name))
        }
    }

    public mutating func identificationFailed(registryID: UInt64) {
        guard var device = devices[registryID], device.identity == .pending else { return }
        device.identity = .failed
        devices[registryID] = device
    }

    /// The physical USB device was terminated.
    public mutating func deviceRemoved(registryID: UInt64) -> GuardEvent? {
        updatingPresence { $0.devices[registryID] = nil }
    }

    /// Changing the configured key always disarms (`configurationChanged`); the caller then
    /// delivers `configuredKeyAttached` if the new key is already attached.
    public mutating func setConfiguredKey(_ key: ConfiguredYubiKey?) -> [GuardEvent] {
        configuredKey = key
        return isConfiguredKeyAttached ? [.configurationChanged, .configuredKeyAttached] : [.configurationChanged]
    }

    /// Revalidation. `currentRegistryIDs` must come from a fresh IOKit lookup of all
    /// currently attached Yubico USB devices.
    ///
    /// - present: a device that is attached right now is identified as the configured key
    /// - uncertain: some attached Yubico device is unknown or unidentified
    /// - absent: every attached Yubico device is identified as a different key
    public func presence(currentRegistryIDs: Set<UInt64>) -> KeyPresence {
        guard configuredKey != nil else { return .absent }

        var sawUnidentified = false
        for id in currentRegistryIDs {
            guard let device = devices[id] else {
                sawUnidentified = true // attached, but its arrival was not processed yet
                continue
            }
            switch device.identity {
            case .identified:
                if isConfigured(device) { return .present }
            case .pending, .failed:
                sawUnidentified = true
            }
        }
        return sawUnidentified ? .uncertain : .absent
    }

    private func isConfigured(_ device: TrackedYubiKey) -> Bool {
        guard let configuredKey, case .identified(let serial, _) = device.identity else { return false }
        return serial == configuredKey.serial
    }

    private mutating func updatingPresence(_ change: (inout DeviceTracker) -> Void) -> GuardEvent? {
        let before = isConfiguredKeyAttached
        change(&self)
        let after = isConfiguredKeyAttached
        switch (before, after) {
        case (false, true): return .configuredKeyAttached
        case (true, false): return .configuredKeyRemoved
        default: return nil
        }
    }
}
