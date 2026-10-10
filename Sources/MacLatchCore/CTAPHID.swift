/// Minimal CTAPHID framing (FIDO Client to Authenticator Protocol, HID transport),
/// just enough to send one vendor command and read its response.
///
/// Packet layout (64 bytes):
///   init:         CID(4) | CMD(1, bit 7 set) | BCNT(2, big endian) | DATA(57)
///   continuation: CID(4) | SEQ(1, 0...0x7F)                       | DATA(59)
public enum CTAPHID {
    public static let packetSize = 64
    public static let broadcastChannel: UInt32 = 0xFFFF_FFFF

    public static let commandInit: UInt8 = 0x86
    public static let commandKeepAlive: UInt8 = 0xBB
    public static let commandError: UInt8 = 0xBF
    /// Yubico vendor command: read the management "device info" (incl. serial number).
    /// Does not require user presence. Supported by YubiKey firmware 4.1+.
    public static let commandYubiKeyReadConfig: UInt8 = 0xC2

    public enum FramingError: Error, Equatable {
        case payloadTooLarge
        case malformedPacket
        case unexpectedSequence(expected: UInt8, got: UInt8)
        case unexpectedCommand(UInt8)
        case deviceError(code: UInt8)
        case invalidInitResponse
    }

    private static let initDataSize = packetSize - 7
    private static let continuationDataSize = packetSize - 5

    /// Splits one request into 64-byte output reports.
    public static func encode(channel: UInt32, command: UInt8, payload: [UInt8]) throws -> [[UInt8]] {
        let maxPayload = initDataSize + 128 * continuationDataSize
        guard payload.count <= maxPayload else { throw FramingError.payloadTooLarge }

        var packets: [[UInt8]] = []
        var packet = channelBytes(channel) + [command, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        var offset = min(initDataSize, payload.count)
        packet += payload[0..<offset]
        packets.append(padded(packet))

        var sequence: UInt8 = 0
        while offset < payload.count {
            let end = min(offset + continuationDataSize, payload.count)
            packets.append(padded(channelBytes(channel) + [sequence] + payload[offset..<end]))
            offset = end
            sequence += 1
        }
        return packets
    }

    public struct Response: Equatable, Sendable {
        public let command: UInt8
        public let payload: [UInt8]
    }

    /// Reassembles a response from input reports, for one channel.
    /// Packets for other channels and keep-alives are skipped.
    public struct ResponseAssembler: Sendable {
        public let channel: UInt32
        private var command: UInt8?
        private var expectedLength = 0
        private var nextSequence: UInt8 = 0
        private var payload: [UInt8] = []

        public init(channel: UInt32) {
            self.channel = channel
        }

        /// Returns the complete response once all packets have arrived, `nil` while incomplete.
        public mutating func consume(_ packet: [UInt8]) throws -> Response? {
            guard packet.count >= 7 else { throw FramingError.malformedPacket }
            guard readChannel(packet) == channel else { return nil }

            let fifthByte = packet[4]
            if fifthByte & 0x80 != 0 {
                if fifthByte == CTAPHID.commandKeepAlive { return nil }
                if fifthByte == CTAPHID.commandError {
                    throw FramingError.deviceError(code: packet[7])
                }
                command = fifthByte
                expectedLength = Int(packet[5]) << 8 | Int(packet[6])
                nextSequence = 0
                payload = Array(packet[7..<min(packet.count, 7 + min(expectedLength, initDataSize))])
            } else {
                guard command != nil else { throw FramingError.malformedPacket }
                guard fifthByte == nextSequence else {
                    throw FramingError.unexpectedSequence(expected: nextSequence, got: fifthByte)
                }
                nextSequence += 1
                let remaining = expectedLength - payload.count
                payload += packet[5..<min(packet.count, 5 + min(remaining, continuationDataSize))]
            }

            guard let command, payload.count >= expectedLength else { return nil }
            return Response(command: command, payload: Array(payload.prefix(expectedLength)))
        }
    }

    /// Validates a CTAPHID_INIT response and returns the allocated channel.
    public static func channel(fromInitResponse response: Response, nonce: [UInt8]) throws -> UInt32 {
        guard response.command == commandInit, response.payload.count >= 17,
              Array(response.payload[0..<8]) == nonce
        else { throw FramingError.invalidInitResponse }
        return readChannel(Array(response.payload[8..<12]))
    }

    private static func channelBytes(_ channel: UInt32) -> [UInt8] {
        [UInt8(channel >> 24 & 0xFF), UInt8(channel >> 16 & 0xFF), UInt8(channel >> 8 & 0xFF), UInt8(channel & 0xFF)]
    }

    private static func readChannel(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private static func padded(_ packet: [UInt8]) -> [UInt8] {
        packet + [UInt8](repeating: 0, count: packetSize - packet.count)
    }
}
