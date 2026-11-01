import Foundation
import Testing

@testable import RackyProtocol

@Suite struct FrameCodecTests {
    private func lengthPrefix(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    // MARK: Limites

    @Test func limitsAreCanonical() {
        #expect(ProtocolLimits.maxFrameLength == 1_048_576)
        #expect(ProtocolLimits.clientQueueLimit == 2_097_152)
        #expect(ProtocolLimits.handshakeTimeout == .seconds(2))
        #expect(ProtocolLimits.coalesceBytes == 65_536)
        #expect(FrameCodec.maxOutputBytes == 1_048_576 - 1 - 24)
        #expect(FrameCodec.maxInputBytes == 1_048_576 - 1 - 17)
    }

    @Test func frameWithLengthAboveOneMiBIsRejectedOnEncode() {
        let big = Frame.output(OutputFrame(sessionID: sid1, seq: 0, bytes: Data(count: FrameCodec.maxOutputBytes + 1)))
        #expect(throws: FrameError.frameTooLarge(length: ProtocolLimits.maxFrameLength + 1)) { try FrameCodec.encode(big) }
        let bigInput = Frame.input(InputFrame(sessionID: sid1, origin: .key, bytes: Data(count: FrameCodec.maxInputBytes + 1)))
        #expect(throws: FrameError.self) { try FrameCodec.encode(bigInput) }
    }

    @Test func frameOfExactlyOneMiBIsAccepted() throws {
        let max = Frame.output(OutputFrame(sessionID: sid1, seq: 7, bytes: Data(repeating: 0x41, count: FrameCodec.maxOutputBytes)))
        let bytes = try FrameCodec.encode(max)
        #expect(bytes.count == ProtocolLimits.lengthPrefixSize + ProtocolLimits.maxFrameLength)
        #expect(try FrameCodec.decode(bytes) == max)
        let maxInput = Frame.input(InputFrame(sessionID: sid1, origin: .ctl, bytes: Data(repeating: 0x42, count: FrameCodec.maxInputBytes)))
        #expect(try FrameCodec.decode(FrameCodec.encode(maxInput)) == maxInput)
    }

    @Test func oversizedControlMessageIsRejectedOnEncode() {
        let huge = String(repeating: "x", count: ProtocolLimits.maxFrameLength)
        let message = ControlMessage.event(DaemonEvent(sessionID: sid1, payload: .title(TitleEvent(text: huge))))
        #expect(throws: FrameError.self) { try FrameCodec.encode(.control(message)) }
    }

    @Test func decoderRejectsOversizedLengthAsSoonAsThePrefixArrives() {
        var decoder = FrameDecoder()
        let prefix = lengthPrefix(UInt32(ProtocolLimits.maxFrameLength + 1))
        #expect(throws: FrameError.frameTooLarge(length: ProtocolLimits.maxFrameLength + 1)) { try decoder.append(prefix) }
        // Falha permanente: bytes seguintes não "consertam" o decoder.
        #expect(throws: FrameError.self) { try decoder.append(Data([0x01])) }
        #expect(throws: FrameError.self) { try decoder.finish() }
    }

    @Test func decoderRejectsHugeLengthsWithoutWaitingForPayload() {
        for length in [UInt32(2 << 20), UInt32(0x7FFF_FFFF), UInt32.max] {
            var decoder = FrameDecoder()
            #expect(throws: FrameError.frameTooLarge(length: Int(length))) { try decoder.append(lengthPrefix(length) + Data([0x01])) }
        }
    }

    @Test func frameTooLargeMapsToErrorCode() {
        #expect(FrameError.frameTooLarge(length: 2 << 20).daemonErrorCode == .frameTooLarge)
        #expect(FrameError.frameTooLarge(length: 2 << 20).daemonError.code == .frameTooLarge)
        #expect(FrameError.emptyFrame.daemonErrorCode == .badRequest)
        #expect(FrameError.unknownKind(9).daemonErrorCode == .badRequest)
    }

    // MARK: Corrompidos

    @Test func zeroLengthFrameIsRejected() {
        var decoder = FrameDecoder()
        #expect(throws: FrameError.emptyFrame) { try decoder.append(lengthPrefix(0)) }
    }

    @Test func unknownKindIsRejected() {
        for kind: UInt8 in [0x00, 0x04, 0x7F, 0xFF] {
            var decoder = FrameDecoder()
            #expect(throws: FrameError.unknownKind(kind)) { try decoder.append(lengthPrefix(2) + Data([kind, 0x00])) }
        }
    }

    @Test func shortOutputAndInputPayloadsAreRejected() {
        var output = FrameDecoder()
        #expect(throws: FrameError.payloadTooShort(kind: 0x02, minimum: 24, actual: 23)) {
            try output.append(lengthPrefix(24) + Data([0x02]) + Data(count: 23))
        }
        var input = FrameDecoder()
        #expect(throws: FrameError.payloadTooShort(kind: 0x03, minimum: 17, actual: 16)) {
            try input.append(lengthPrefix(17) + Data([0x03]) + Data(count: 16))
        }
        var control = FrameDecoder()
        #expect(throws: FrameError.self) { try control.append(lengthPrefix(1) + Data([0x01])) }  // JSON vazio
    }

    @Test func invalidInputOriginIsRejected() {
        for origin: UInt8 in [0x06, 0x7F, 0xFF] {
            var decoder = FrameDecoder()
            let payload = lengthPrefix(UInt32(1 + 17)) + Data([0x03]) + Data(sid1.bytes) + Data([origin])
            #expect(throws: FrameError.invalidInputOrigin(origin)) { try decoder.append(payload) }
        }
    }

    @Test func malformedControlJSONIsRejected() {
        let bodies = ["{", "not json", "[]", "{\"op\":\"list\"}", "{\"op\":42,\"id\":1}", "\"x\"", "null", "{\"op\":\"ping\",\"id\":-1}"]
        for body in bodies {
            let data = Data(body.utf8)
            var decoder = FrameDecoder()
            let frame = lengthPrefix(UInt32(1 + data.count)) + Data([0x01]) + data
            #expect(throws: FrameError.self, "\(body)") { try decoder.append(frame) }
        }
    }

    @Test func invalidUTF8ControlPayloadIsRejected() {
        var decoder = FrameDecoder()
        let frame = lengthPrefix(4) + Data([0x01, 0xFF, 0xFE, 0xFD])
        #expect(throws: FrameError.self) { try decoder.append(frame) }
    }

    // MARK: Truncados e fragmentados

    @Test func everyStrictPrefixOfAFrameYieldsNothingAndTruncatedAtEOF() throws {
        let frames = [
            try Fixtures.hexData("control-hello"), try Fixtures.hexData("output-hello-world"), try Fixtures.hexData("input-key"),
        ]
        for full in frames {
            for cut in 0 ..< full.count {
                var decoder = FrameDecoder()
                let produced = try decoder.append(full.prefix(cut))
                #expect(produced.isEmpty, "prefix \(cut) of \(full.count) must not produce frames")
                #expect(decoder.bufferedByteCount == cut)
                if cut == 0 {
                    try decoder.finish()
                } else {
                    #expect(throws: FrameError.self) { try decoder.finish() }
                }
            }
        }
    }

    @Test func truncatedErrorReportsExpectedAndAvailable() throws {
        let full = try Fixtures.hexData("output-hello-world")
        var decoder = FrameDecoder()
        _ = try decoder.append(full.prefix(10))
        #expect(throws: FrameError.truncatedFrame(expected: full.count, available: 10)) { try decoder.finish() }
        var tiny = FrameDecoder()
        _ = try tiny.append(Data([0x00, 0x00]))
        #expect(throws: FrameError.truncatedFrame(expected: 4, available: 2)) { try tiny.finish() }
    }

    @Test func byteByByteFeedingReassemblesEveryFrame() throws {
        let originals: [Frame] = allSampleMessages().map { .control($0) } + [
            .output(OutputFrame(sessionID: sid1, seq: 0, bytes: Data("abc".utf8))),
            .input(InputFrame(sessionID: sid2, origin: .parentToChild, bytes: Data("hi\r".utf8))),
        ]
        let stream = try originals.reduce(Data()) { $0 + (try FrameCodec.encode($1)) }
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in stream { decoded += try decoder.append(Data([byte])) }
        try decoder.finish()
        #expect(decoded == originals)
    }

    @Test func manyFramesInOneChunkAndRandomChunkBoundaries() throws {
        var generator = SplitMix64(seed: 42)
        let originals: [Frame] = (0 ..< 300).map { index in
            .output(OutputFrame(sessionID: sid1, seq: UInt64(index) * 10, bytes: Data(repeating: UInt8(index & 0xFF), count: 10)))
        }
        let stream = try originals.reduce(Data()) { $0 + (try FrameCodec.encode($1)) }
        var whole = FrameDecoder()
        #expect(try whole.append(stream) == originals)
        for _ in 0 ..< 20 {
            var decoder = FrameDecoder()
            var decoded: [Frame] = []
            var offset = 0
            while offset < stream.count {
                let step = min(Int(generator.next() % 97) + 1, stream.count - offset)
                decoded += try decoder.append(stream[offset ..< offset + step])
                offset += step
            }
            #expect(decoded == originals)
            try decoder.finish()
        }
    }

    @Test func decoderCompactsItsBufferUnderSustainedLoad() throws {
        var decoder = FrameDecoder()
        let frame = try FrameCodec.encode(.output(OutputFrame(sessionID: sid1, seq: 0, bytes: Data(count: 4000))))
        for _ in 0 ..< 2000 { #expect(try decoder.append(frame).count == 1) }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func goodFramesBeforeABadOneAreStillDelivered() throws {
        let good = try FrameCodec.encode(.control(.request(DaemonRequest(id: 1, command: .ping))))
        var decoder = FrameDecoder()
        // A falha vem no mesmo chunk: o chamador recebe o erro; o decoder fica quebrado.
        #expect(throws: FrameError.unknownKind(0x55)) { try decoder.append(good + lengthPrefix(1) + Data([0x55])) }
    }

    @Test func drainReturnsValidFramesBeforeTheFirstInvalidOne() throws {
        let good = Frame.control(.request(DaemonRequest(id: 1, command: .ping)))
        let bytes = try FrameCodec.encode(good) + FrameCodec.encode(good) + lengthPrefix(1) + Data([0x55]) + (try FrameCodec.encode(good))
        var decoder = FrameDecoder()
        let result = decoder.drain(bytes)
        #expect(result.frames == [good, good])
        #expect(result.error == .unknownKind(0x55))
        // Sticky: nada mais sai depois da falha.
        let again = decoder.drain(try FrameCodec.encode(good))
        #expect(again.frames.isEmpty && again.error == .unknownKind(0x55))
    }

    @Test func fuzzedGarbageNeverCrashesAndEitherFailsOrParses() {
        var generator = SplitMix64(seed: 0xDEADBEEF)
        var failures = 0
        for _ in 0 ..< 2000 {
            let size = Int(generator.next() % 200)
            let garbage = Data((0 ..< size).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            var decoder = FrameDecoder()
            do {
                _ = try decoder.append(garbage)
                _ = try? decoder.finish()
            } catch {
                failures += 1
            }
        }
        #expect(failures > 0)
    }

    @Test func fuzzedBitFlipsInValidFramesNeverCrash() throws {
        var generator = SplitMix64(seed: 7)
        let originals = try allSampleMessages().map { try FrameCodec.encode(.control($0)) }
        for original in originals {
            for _ in 0 ..< 10 {
                var mutated = original
                let index = Int(generator.next() % UInt64(mutated.count))
                mutated[index] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                var decoder = FrameDecoder()
                _ = try? decoder.append(mutated)
                _ = try? decoder.finish()
            }
        }
    }

    // MARK: seq

    @Test func outputSeqIsContiguousByteOffset() {
        let a = OutputFrame(sessionID: sid1, seq: 100, bytes: Data(count: 50))
        let b = OutputFrame(sessionID: sid1, seq: a.nextSeq, bytes: Data(count: 10))
        #expect(a.nextSeq == 150 && b.nextSeq == 160)
        var validator = OutputSequenceValidator(expectedSeq: 100)
        #expect(validator.accept(a) == .continuous)
        #expect(validator.accept(b) == .continuous)
        #expect(validator.expectedSeq == 160)
    }

    @Test func sequenceValidatorDetectsGapsAndOverlaps() {
        var validator = OutputSequenceValidator(expectedSeq: 0)
        #expect(validator.accept(OutputFrame(sessionID: sid1, seq: 0, bytes: Data(count: 10))) == .continuous)
        #expect(validator.accept(OutputFrame(sessionID: sid1, seq: 15, bytes: Data(count: 5))) == .gap(expected: 10, got: 15))
        #expect(validator.accept(OutputFrame(sessionID: sid1, seq: 18, bytes: Data(count: 2))) == .overlap(expected: 20, got: 18))
        var fresh = OutputSequenceValidator()
        #expect(fresh.accept(OutputFrame(sessionID: sid1, seq: 4096, bytes: Data(count: 1))) == .continuous)
        #expect(fresh.expectedSeq == 4097)
    }
}
