import Foundation
import Testing

@testable import RackyProtocol

@Suite struct RoundTripTests {
    @Test func everyControlMessageRoundTripsThroughJSON() throws {
        let messages = allSampleMessages()
        #expect(messages.count > 40)
        for message in messages {
            let data = try ControlCodec.encode(message)
            let decoded = try ControlCodec.decode(data)
            #expect(decoded == message, "round-trip mismatch for \(String(decoding: data, as: UTF8.self))")
            // Determinístico: codificar de novo dá os mesmos bytes.
            #expect(try ControlCodec.encode(decoded) == data)
        }
    }

    @Test func everyControlMessageRoundTripsThroughFrames() throws {
        for message in allSampleMessages() {
            let frame = Frame.control(message)
            let bytes = try FrameCodec.encode(frame)
            #expect(try FrameCodec.decode(bytes) == frame)
        }
    }

    @Test func samplesCoverEveryOpEventAndErrorCode() {
        var requestOps = Set<String>()
        var replyOps = Set<String>()
        var eventNames = Set<String>()
        var errorCodes = Set<DaemonErrorCode>()
        for message in allSampleMessages() {
            switch message {
            case .request(let r): requestOps.insert(r.command.op)
            case .reply(let r):
                replyOps.insert(r.op)
                if case .error(_, let e) = r { errorCodes.insert(e.code) }
            case .event(let e): eventNames.insert(e.payload.name)
            }
        }
        #expect(requestOps == Set(DaemonCommand.allOps))
        #expect(replyOps == Set(DaemonReply.allOps))
        #expect(eventNames == Set(EventPayload.allNames))
        #expect(errorCodes == Set(DaemonErrorCode.allCases))
    }

    @Test func wireShapeMatchesSpecExamples() throws {
        let hello = DaemonRequest(
            id: 1, command: .hello(HelloRequest(client: ClientInfo(kind: .app, build: "1.0 (42)"), capabilities: [.coldLog, .osc133])))
        let json = String(decoding: try ControlCodec.encode(.request(hello)), as: UTF8.self)
        #expect(json == #"{"capabilities":["coldLog","osc133"],"client":{"build":"1.0 (42)","kind":"app"},"id":1,"op":"hello","protocol":{"major":1,"minor":0}}"#)

        let err = DaemonReply.error(id: 3, DaemonError(.spawnFailed, "boom", errnoValue: 2, path: "/x"))
        let errJSON = String(decoding: try ControlCodec.encode(.reply(err)), as: UTF8.self)
        #expect(errJSON == #"{"code":"spawnFailed","errno":2,"id":3,"message":"boom","op":"error","path":"/x"}"#)
    }

    @Test func outputAndInputFramesRoundTripWithRandomPayloads() throws {
        var generator = SplitMix64(seed: 0xA6E47)
        for _ in 0 ..< 200 {
            let size = Int(generator.next() % 5000)
            let bytes = Data((0 ..< size).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            let output = Frame.output(OutputFrame(sessionID: SessionID(), seq: generator.next(), bytes: bytes))
            #expect(try FrameCodec.decode(try FrameCodec.encode(output)) == output)
            let origin = InputOrigin.allCases[Int(generator.next() % UInt64(InputOrigin.allCases.count))]
            let input = Frame.input(InputFrame(sessionID: SessionID(), origin: origin, bytes: bytes))
            #expect(try FrameCodec.decode(try FrameCodec.encode(input)) == input)
        }
    }

    @Test func sessionIDBinaryAndTextForms() throws {
        let id = SessionID()
        #expect(id.bytes.count == 16)
        #expect(SessionID(bytes: id.bytes) == id)
        #expect(SessionID(bytes: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(SessionID(string: id.description.uppercased()) == id)
        #expect(id.description == id.description.lowercased())
    }

    @Test func inputOriginRawValuesAreCanonical() {
        #expect(InputOrigin.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])
        #expect(InputOrigin(rawValue: 6) == nil)
        for origin in InputOrigin.allCases { #expect(InputOrigin(wireName: origin.wireName) == origin) }
    }

    @Test func inputByteCountsAccumulateAndSerializeByName() throws {
        var counts = InputByteCounts()
        counts.add(3, origin: .key)
        counts.add(7, origin: .key)
        counts.add(5, origin: .appPaste)
        #expect(counts[.key] == 10 && counts[.appPaste] == 5 && counts[.ctl] == 0 && counts.total == 15)
        let data = try ControlCodec.makeEncoder().encode(counts)
        #expect(try jsonObject(data) == (["key": 10, "appPaste": 5] as NSDictionary))
    }

    @Test func datesKeepMillisecondPrecisionAndAcceptNoFractionInput() throws {
        let event = DaemonEvent(sessionID: sid1, payload: .idle(IdleEvent(since: t1)))
        let json = String(decoding: try ControlCodec.encode(.event(event)), as: UTF8.self)
        #expect(json.contains("\"since\":\"2026-10-17T12:00:05.250Z\""))
        let plain = #"{"event":"idle","op":"event","sessionID":"11111111-2222-4333-8444-555555555555","since":"2026-10-17T12:00:05Z"}"#
        guard case .event(let decoded) = try ControlCodec.decode(Data(plain.utf8)), case .idle(let idle) = decoded.payload else {
            Issue.record("expected idle event")
            return
        }
        #expect(idle.since == Date(timeIntervalSince1970: 1_792_238_405))
    }
}

/// Gerador determinístico para testes de propriedade e fuzz.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
