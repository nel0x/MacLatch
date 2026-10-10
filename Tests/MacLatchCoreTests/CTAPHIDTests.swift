import Testing
@testable import MacLatchCore

@Suite("CTAPHID framing")
struct CTAPHIDTests {
    @Test func encodesSmallRequestAsSinglePacket() throws {
        let packets = try CTAPHID.encode(channel: 0x0102_0304, command: 0xC2, payload: [])
        #expect(packets.count == 1)
        #expect(packets[0].count == 64)
        #expect(Array(packets[0][0..<7]) == [1, 2, 3, 4, 0xC2, 0, 0])
    }

    @Test func encodesLargeRequestWithContinuationPackets() throws {
        let payload = (0..<100).map { UInt8($0) }
        let packets = try CTAPHID.encode(channel: CTAPHID.broadcastChannel, command: 0x86, payload: payload)
        #expect(packets.count == 2)
        #expect(Array(packets[0][4..<7]) == [0x86, 0, 100])
        #expect(Array(packets[0][7..<64]) == Array(payload[0..<57]))
        #expect(packets[1][4] == 0) // sequence 0
        #expect(Array(packets[1][5..<48]) == Array(payload[57..<100]))
    }

    @Test func roundTripThroughAssembler() throws {
        let payload = (0..<150).map { UInt8($0 & 0xFF) }
        let packets = try CTAPHID.encode(channel: 7, command: 0xC2, payload: payload)
        var assembler = CTAPHID.ResponseAssembler(channel: 7)
        var response: CTAPHID.Response?
        for packet in packets { response = try assembler.consume(packet) }
        #expect(response == CTAPHID.Response(command: 0xC2, payload: payload))
    }

    @Test func assemblerSkipsOtherChannelsAndKeepAlive() throws {
        var assembler = CTAPHID.ResponseAssembler(channel: 7)
        let other = try CTAPHID.encode(channel: 8, command: 0xC2, payload: [1])[0]
        let keepAlive = try CTAPHID.encode(channel: 7, command: CTAPHID.commandKeepAlive, payload: [1])[0]
        #expect(try assembler.consume(other) == nil)
        #expect(try assembler.consume(keepAlive) == nil)
        let real = try CTAPHID.encode(channel: 7, command: 0xC2, payload: [9, 9])[0]
        #expect(try assembler.consume(real) == CTAPHID.Response(command: 0xC2, payload: [9, 9]))
    }

    @Test func assemblerReportsDeviceError() throws {
        var assembler = CTAPHID.ResponseAssembler(channel: 7)
        let error = try CTAPHID.encode(channel: 7, command: CTAPHID.commandError, payload: [0x01])[0]
        #expect(throws: CTAPHID.FramingError.deviceError(code: 0x01)) { try assembler.consume(error) }
    }

    @Test func assemblerRejectsOutOfOrderSequence() throws {
        let packets = try CTAPHID.encode(channel: 7, command: 0xC2, payload: [UInt8](repeating: 1, count: 130))
        var assembler = CTAPHID.ResponseAssembler(channel: 7)
        _ = try assembler.consume(packets[0])
        #expect(throws: CTAPHID.FramingError.self) { try assembler.consume(packets[2]) }
    }

    @Test func initResponseValidatesNonce() throws {
        let nonce: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let payload = nonce + [0xAA, 0xBB, 0xCC, 0xDD] + [2, 5, 4, 3, 0x05]
        let response = CTAPHID.Response(command: CTAPHID.commandInit, payload: payload)
        #expect(try CTAPHID.channel(fromInitResponse: response, nonce: nonce) == 0xAABB_CCDD)
        #expect(throws: CTAPHID.FramingError.invalidInitResponse) {
            try CTAPHID.channel(fromInitResponse: response, nonce: [0, 0, 0, 0, 0, 0, 0, 0])
        }
    }
}

@Suite("YubiKeyDeviceInfo")
struct YubiKeyDeviceInfoTests {
    @Test func parsesSerialFirmwareAndFormFactor() throws {
        let tlvs: [UInt8] = [
            0x01, 0x02, 0x02, 0x3F, // USB supported
            0x02, 0x04, 0x00, 0xBC, 0x61, 0x4E, // serial 12345678
            0x04, 0x01, 0x03, // USB-C keychain
            0x05, 0x03, 0x05, 0x04, 0x03, // firmware 5.4.3
        ]
        let info = try YubiKeyDeviceInfo.parse([UInt8(tlvs.count)] + tlvs)
        #expect(info.serial == 12_345_678)
        #expect(info.formFactor == 0x03)
        #expect(info.displayName == "YubiKey 5 (USB-C)")
    }

    @Test func missingSerialYieldsNil() throws {
        let tlvs: [UInt8] = [0x05, 0x03, 0x05, 0x02, 0x07]
        #expect(try YubiKeyDeviceInfo.parse([UInt8(tlvs.count)] + tlvs).serial == nil)
    }

    @Test func rejectsLengthMismatchAndTruncation() {
        #expect(throws: YubiKeyDeviceInfo.ParseError.lengthMismatch) { try YubiKeyDeviceInfo.parse([5, 0x02]) }
        #expect(throws: YubiKeyDeviceInfo.ParseError.lengthMismatch) { try YubiKeyDeviceInfo.parse([]) }
        #expect(throws: YubiKeyDeviceInfo.ParseError.truncated) { try YubiKeyDeviceInfo.parse([3, 0x02, 0x04, 0x00]) }
    }
}
