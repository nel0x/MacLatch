import CoreFoundation
import IOKit.hid
import MacLatchCore

/// Reads the YubiKey device info (including the serial number) over the FIDO HID interface,
/// using the Yubico vendor CTAPHID command. Requires no user touch and no Input Monitoring
/// permission (unlike the OTP keyboard interface).
///
/// Blocking. Call only from a background queue; runs a private run loop mode on that thread.
enum FIDOSerialReader {
    enum ReadError: Error {
        case cannotCreateDevice
        case cannotOpen(IOReturn)
        case sendFailed(IOReturn)
        case timeout
        case unexpectedResponse
        case serialNotAvailable
    }

    private static let runLoopMode = CFRunLoopMode("io.github.nel0x.maclatch.ctaphid" as CFString)

    static func readDeviceInfo(hidService: io_service_t, timeout: Duration = .seconds(2)) throws -> YubiKeyDeviceInfo {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, hidService) else {
            throw ReadError.cannotCreateDevice
        }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw ReadError.cannotOpen(openResult) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let inbox = ReportInbox()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CTAPHID.packetSize)
        defer { buffer.deallocate() }

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, CTAPHID.packetSize,
            { context, _, _, _, _, report, length in
                guard let context else { return }
                let inbox = Unmanaged<ReportInbox>.fromOpaque(context).takeUnretainedValue()
                inbox.packets.append(Array(UnsafeBufferPointer(start: report, count: length)))
            },
            Unmanaged.passUnretained(inbox).toOpaque()
        )
        guard let runLoop = CFRunLoopGetCurrent() else { throw ReadError.cannotCreateDevice }
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, runLoopMode.rawValue)
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, CTAPHID.packetSize, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, runLoopMode.rawValue)
        }

        let deadline = ContinuousClock.now + timeout
        let session = Session(device: device, inbox: inbox, deadline: deadline)

        // 1. Allocate a channel.
        var nonce = [UInt8](repeating: 0, count: 8)
        var rng = SystemRandomNumberGenerator()
        for i in nonce.indices { nonce[i] = rng.next() }
        let initResponse = try session.transact(channel: CTAPHID.broadcastChannel, command: CTAPHID.commandInit, payload: nonce)
        let channel = try CTAPHID.channel(fromInitResponse: initResponse, nonce: nonce)

        // 2. Read the management device info.
        let response = try session.transact(channel: channel, command: CTAPHID.commandYubiKeyReadConfig, payload: [])
        guard response.command == CTAPHID.commandYubiKeyReadConfig else { throw ReadError.unexpectedResponse }

        let info = try YubiKeyDeviceInfo.parse(response.payload)
        guard info.serial != nil else { throw ReadError.serialNotAvailable }
        return info
    }

    private final class ReportInbox {
        var packets: [[UInt8]] = []
    }

    private struct Session {
        let device: IOHIDDevice
        let inbox: ReportInbox
        let deadline: ContinuousClock.Instant

        func transact(channel: UInt32, command: UInt8, payload: [UInt8]) throws -> CTAPHID.Response {
            inbox.packets.removeAll()
            for packet in try CTAPHID.encode(channel: channel, command: command, payload: payload) {
                let result = packet.withUnsafeBufferPointer {
                    // CTAPHID uses no report IDs: report ID 0, 64 bytes of data.
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
                }
                guard result == kIOReturnSuccess else { throw ReadError.sendFailed(result) }
            }

            var assembler = CTAPHID.ResponseAssembler(channel: channel)
            while true {
                while !inbox.packets.isEmpty {
                    if let response = try assembler.consume(inbox.packets.removeFirst()) {
                        return response
                    }
                }
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { throw ReadError.timeout }
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                CFRunLoopRunInMode(runLoopMode, seconds, true)
            }
        }
    }
}
