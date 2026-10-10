/// The subset of the YubiKey management "device info" structure that we use.
///
/// Encoding: one length byte, followed by that many bytes of TLV records
/// (1-byte tag, 1-byte length, value).
public struct YubiKeyDeviceInfo: Equatable, Sendable {
    public var serial: UInt32?
    public var firmware: (major: UInt8, minor: UInt8, patch: UInt8)?
    public var formFactor: UInt8?

    public enum ParseError: Error, Equatable {
        case lengthMismatch
        case truncated
    }

    private enum Tag {
        static let serial: UInt8 = 0x02
        static let formFactor: UInt8 = 0x04
        static let firmwareVersion: UInt8 = 0x05
    }

    public init(serial: UInt32? = nil, firmware: (major: UInt8, minor: UInt8, patch: UInt8)? = nil, formFactor: UInt8? = nil) {
        self.serial = serial
        self.firmware = firmware
        self.formFactor = formFactor
    }

    public static func == (lhs: YubiKeyDeviceInfo, rhs: YubiKeyDeviceInfo) -> Bool {
        lhs.serial == rhs.serial
            && lhs.formFactor == rhs.formFactor
            && lhs.firmware.map { [$0.major, $0.minor, $0.patch] } == rhs.firmware.map { [$0.major, $0.minor, $0.patch] }
    }

    public static func parse(_ data: [UInt8]) throws -> YubiKeyDeviceInfo {
        guard let declared = data.first, Int(declared) == data.count - 1 else {
            throw ParseError.lengthMismatch
        }

        var info = YubiKeyDeviceInfo()
        var index = 1
        while index < data.count {
            guard index + 1 < data.count else { throw ParseError.truncated }
            let tag = data[index]
            let length = Int(data[index + 1])
            let start = index + 2
            guard start + length <= data.count else { throw ParseError.truncated }
            let value = Array(data[start..<start + length])

            switch tag {
            case Tag.serial where length == 4:
                info.serial = UInt32(value[0]) << 24 | UInt32(value[1]) << 16 | UInt32(value[2]) << 8 | UInt32(value[3])
            case Tag.formFactor where length >= 1:
                info.formFactor = value[0]
            case Tag.firmwareVersion where length == 3:
                info.firmware = (value[0], value[1], value[2])
            default:
                break
            }
            index = start + length
        }
        return info
    }

    /// Human-readable name such as "YubiKey 5 (USB-C)". Cosmetic only, never used for identity.
    public var displayName: String {
        var name = "YubiKey"
        if let firmware { name += " \(firmware.major)" }
        if let formFactor, let description = Self.formFactorDescription(formFactor) {
            name += " (\(description))"
        }
        return name
    }

    private static func formFactorDescription(_ code: UInt8) -> String? {
        switch code & 0x0F {
        case 0x01: "USB-A"
        case 0x02: "USB-A Nano"
        case 0x03: "USB-C"
        case 0x04: "USB-C Nano"
        case 0x05: "USB-C/Lightning"
        case 0x06: "USB-A Bio"
        case 0x07: "USB-C Bio"
        default: nil
        }
    }
}
