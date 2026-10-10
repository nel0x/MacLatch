import Dispatch
import Foundation
import IOKit
import IOKit.hid
import MacLatchCore
import os

/// Event-driven YubiKey monitoring via IOKit notifications. No polling.
///
/// - Physical presence: arrival/termination of `IOUSBHostDevice` with the Yubico vendor ID.
///   The USB device is tracked, not its interfaces, so an interface reset is not a removal.
/// - Identity: when the device's FIDO HID interface appears, the serial number is read once
///   over CTAPHID and attributed to the parent USB device.
/// - Only presence changes of the configured key are forwarded as guard events.
@MainActor
final class YubiKeyMonitor {
    struct DetectedKey: Equatable {
        let serial: UInt32
        let name: String
    }

    private(set) var tracker: DeviceTracker
    private let onEvent: (GuardEvent) -> Void
    private let onChange: (String) -> Void

    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let identificationQueue = DispatchQueue(label: "io.github.nel0x.maclatch.identification", qos: .userInitiated)
    private let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "monitor")

    /// - Parameters:
    ///   - onEvent: guard events for the configured key, in order.
    ///   - onChange: human-readable description of any device change (for the UI's event list).
    init(configuredKey: ConfiguredYubiKey?, onEvent: @escaping (GuardEvent) -> Void, onChange: @escaping (String) -> Void) {
        tracker = DeviceTracker(configuredKey: configuredKey)
        self.onEvent = onEvent
        self.onChange = onChange
    }

    /// One entry per serial. During USB re-enumeration the same key can briefly have two registry entries.
    var detectedKeys: [DetectedKey] {
        var seen = Set<UInt32>()
        return tracker.attachedDevices.compactMap {
            guard case .identified(let serial, let name) = $0.identity, seen.insert(serial).inserted else { return nil }
            return DetectedKey(serial: serial, name: name)
        }
    }

    var unidentifiedCount: Int {
        tracker.attachedDevices.filter { !isIdentified($0) }.count
    }

    func start() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log.error("IONotificationPortCreate failed; monitoring disabled (stays unarmed)")
            onChange("Device monitoring unavailable")
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notificationPort = port

        // Order matters for the initial drain: USB devices first, then their FIDO interfaces.
        addNotification(kIOFirstMatchNotification, matching: Self.usbDeviceMatching()) { monitor, iterator in
            monitor.handleUSBArrivals(iterator)
        }
        addNotification(kIOTerminatedNotification, matching: Self.usbDeviceMatching()) { monitor, iterator in
            monitor.handleUSBTerminations(iterator)
        }
        addNotification(kIOFirstMatchNotification, matching: Self.fidoInterfaceMatching()) { monitor, iterator in
            monitor.handleFIDOArrivals(iterator)
        }
    }

    func setConfiguredKey(_ key: ConfiguredYubiKey?) {
        for event in tracker.setConfiguredKey(key) { onEvent(event) }
    }

    /// One-time revalidation using a fresh IOKit lookup (not a cached view).
    func currentPresence() -> KeyPresence {
        guard let ids = Self.currentUSBDeviceIDs() else { return .uncertain }
        return tracker.presence(currentRegistryIDs: ids)
    }

    // MARK: - Notification handling

    private typealias Handler = @MainActor (YubiKeyMonitor, io_iterator_t) -> Void

    /// Boxes the handler so the C callback can find it.
    private final class CallbackContext {
        weak var monitor: YubiKeyMonitor?
        let handler: Handler
        init(monitor: YubiKeyMonitor, handler: @escaping Handler) {
            self.monitor = monitor
            self.handler = handler
        }
    }

    private var callbackContexts: [CallbackContext] = []

    private func addNotification(_ type: String, matching: CFDictionary, handler: @escaping Handler) {
        guard let notificationPort else { return }
        let context = CallbackContext(monitor: self, handler: handler)
        callbackContexts.append(context)

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            notificationPort, type, matching,
            { refcon, iterator in
                guard let refcon else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated {
                    guard let monitor = context.monitor else { return }
                    context.handler(monitor, iterator)
                }
            },
            Unmanaged.passUnretained(context).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            log.error("IOServiceAddMatchingNotification(\(type, privacy: .public)) failed: \(result)")
            return
        }
        iterators.append(iterator)
        // Drain existing matches; this also arms the notification.
        handler(self, iterator)
    }

    private func handleUSBArrivals(_ iterator: io_iterator_t) {
        forEachService(in: iterator) { service in
            guard let id = Self.registryID(of: service) else { return }
            log.info("Yubico USB device attached (registry \(id))")
            tracker.deviceAttached(registryID: id)
            onChange("YubiKey attached (identifying…)")
        }
    }

    private func handleUSBTerminations(_ iterator: io_iterator_t) {
        forEachService(in: iterator) { service in
            guard let id = Self.registryID(of: service) else { return }
            let name = describe(registryID: id)
            log.info("Yubico USB device removed (registry \(id))")
            let event = tracker.deviceRemoved(registryID: id)
            onChange("\(name) removed")
            if let event { onEvent(event) }
        }
    }

    private func handleFIDOArrivals(_ iterator: io_iterator_t) {
        forEachService(in: iterator) { hidService in
            guard let usbID = Self.usbDeviceRegistryID(ancestorOf: hidService) else {
                log.error("FIDO interface without USB parent device; ignored")
                return
            }
            IOObjectRetain(hidService)
            identificationQueue.async { [weak self] in
                // One retry: another FIDO client (e.g. a browser) may interleave on the broadcast channel.
                var outcome = IdentificationOutcome.failed("not attempted")
                for _ in 0..<2 {
                    do {
                        let info = try FIDOSerialReader.readDeviceInfo(hidService: hidService)
                        outcome = .identified(serial: info.serial!, name: info.displayName)
                        break
                    } catch {
                        outcome = .failed(String(describing: error))
                    }
                }
                IOObjectRelease(hidService)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.identificationFinished(usbID: usbID, outcome: outcome) }
                }
            }
        }
    }

    private enum IdentificationOutcome: Sendable {
        case identified(serial: UInt32, name: String)
        case failed(String)
    }

    private func identificationFinished(usbID: UInt64, outcome: IdentificationOutcome) {
        // Check with the same matching that delivers removal notifications: the device may have
        // been removed meanwhile, and a device that removal monitoring cannot see must never arm.
        guard let visibleIDs = Self.currentUSBDeviceIDs(), visibleIDs.contains(usbID) else {
            log.error("identified device \(usbID) is not visible to USB removal monitoring; not tracking it")
            onChange("YubiKey ignored: removal could not be monitored")
            return
        }
        // Its arrival notification may simply not have been processed yet.
        tracker.deviceAttached(registryID: usbID)

        switch outcome {
        case .identified(let serial, let name):
            let isConfigured = serial == tracker.configuredKey?.serial
            log.info("identified \(name, privacy: .public) \(maskSerial(serial), privacy: .public) (registry \(usbID)), configured: \(isConfigured)")
            let event = tracker.deviceIdentified(registryID: usbID, serial: serial, name: name)
            onChange("\(name) \(maskSerial(serial)) identified\(isConfigured ? " (configured)" : "")")
            if let event { onEvent(event) }
        case .failed(let reason):
            log.error("identification of device \(usbID) failed: \(reason, privacy: .public)")
            tracker.identificationFailed(registryID: usbID)
            onChange("YubiKey could not be identified")
        }
    }

    // MARK: - IOKit helpers

    private func describe(registryID: UInt64) -> String {
        for device in tracker.attachedDevices where device.registryID == registryID {
            if case .identified(let serial, let name) = device.identity { return "\(name) \(maskSerial(serial))" }
        }
        return "YubiKey"
    }

    private func isIdentified(_ device: TrackedYubiKey) -> Bool {
        if case .identified = device.identity { return true }
        return false
    }

    private func forEachService(in iterator: io_iterator_t, _ body: (io_service_t) -> Void) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func usbDeviceMatching() -> CFDictionary {
        // A top-level "idVendor" key alone matches nothing: IOUSBHostDevice applies the USB
        // Common Class Spec rules (idVendor needs idProduct etc.). IOPropertyMatch is a plain
        // property comparison and matches every Yubico device, whatever its product ID.
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = ["idVendor": yubicoVendorID]
        return matching
    }

    private static func fidoInterfaceMatching() -> CFDictionary {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey] = yubicoVendorID
        matching[kIOHIDPrimaryUsagePageKey] = 0xF1D0 // FIDO Alliance
        return matching
    }

    private static func registryID(of entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    private static func usbDeviceRegistryID(ancestorOf service: io_service_t) -> UInt64? {
        var current = service
        IOObjectRetain(current)
        while true {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                let id = registryID(of: current)
                IOObjectRelease(current)
                return id
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS else { return nil }
            current = parent
        }
    }

    /// `nil` if the lookup itself failed (caller treats that as uncertain).
    private static func currentUSBDeviceIDs() -> Set<UInt64>? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, usbDeviceMatching(), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var ids = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let id = registryID(of: service) { ids.insert(id) }
            IOObjectRelease(service)
        }
        return ids
    }
}
