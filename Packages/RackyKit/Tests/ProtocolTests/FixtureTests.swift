import Foundation
import Testing

@testable import RackyProtocol

@Suite struct FixtureTests {
    @Test func everyV1FixtureDecodesAndReencodesToIdenticalBytes() throws {
        let files = try Fixtures.files("v1")
        #expect(files.count >= 45)
        for file in files {
            let original = try Data(contentsOf: file)
            let message = try ControlCodec.decode(original)
            let encoded = try ControlCodec.encode(message)
            #expect(try jsonObject(encoded) == jsonObject(original), "semantic mismatch: \(file.lastPathComponent)")
            let canonical = String(decoding: original, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(String(decoding: encoded, as: UTF8.self) == canonical, "byte mismatch: \(file.lastPathComponent)")
        }
    }

    @Test func fixturesCoverEveryOpEventAndErrorCode() throws {
        var requestOps = Set<String>()
        var replyOps = Set<String>()
        var eventNames = Set<String>()
        var errorCodes = Set<DaemonErrorCode>()
        for file in try Fixtures.files("v1") {
            switch try ControlCodec.decode(Data(contentsOf: file)) {
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

    @Test func fixtureAttachModesAndSubscribeScopes() throws {
        guard case .request(let since) = try ControlCodec.decode(Fixtures.data("v1", "attach-since-seq")),
            case .attach(let attach) = since.command
        else {
            Issue.record("expected attach")
            return
        }
        #expect(attach.mode == .sinceSeq(1_048_576))
        guard case .request(let all) = try ControlCodec.decode(Fixtures.data("v1", "subscribe-all")),
            case .subscribe(let subscribe) = all.command
        else {
            Issue.record("expected subscribe")
            return
        }
        #expect(subscribe.scope == .all && subscribe.events == [.exit, .idle])
    }

    @Test func spawnFailedFixtureCarriesErrnoAndPath() throws {
        guard case .reply(.error(let id, let error)) = try ControlCodec.decode(Fixtures.data("v1", "error-spawnFailed")) else {
            Issue.record("expected error reply")
            return
        }
        #expect(id == 2 && error.code == .spawnFailed && error.errnoValue == 2 && error.path == "/nonexistent/bin")
    }

    @Test func connectionLevelErrorHasNoRequestID() throws {
        guard case .reply(.error(let id, let error)) = try ControlCodec.decode(Fixtures.data("v1", "error-no-id")) else {
            Issue.record("expected error reply")
            return
        }
        #expect(id == nil && error.code == .frameTooLarge)
    }

    @Test func compatibilityFixturesTolerateUnknownFieldsAndCapabilities() throws {
        for file in try Fixtures.files("n-1") {
            _ = try ControlCodec.decode(Data(contentsOf: file))
        }
        guard case .reply(.helloAck(_, let ack)) = try ControlCodec.decode(Fixtures.data("n-1", "hello-ack-1.7-future")) else {
            Issue.record("expected helloAck")
            return
        }
        #expect(ack.protocolVersion == ProtocolVersion(major: 1, minor: 7))
        #expect(ack.capabilities.contains("futureThing"))
        #expect(ack.sessions == 2)
    }

    @Test func invalidFixturesAreRejectedAsMalformedControl() throws {
        let files = try Fixtures.files("invalid")
        #expect(files.count >= 10)
        for file in files {
            #expect(throws: FrameError.self, "should reject \(file.lastPathComponent)") {
                try ControlCodec.decode(Data(contentsOf: file))
            }
            do {
                _ = try ControlCodec.decode(Data(contentsOf: file))
            } catch let error as FrameError {
                guard case .malformedControl = error else {
                    Issue.record("\(file.lastPathComponent): expected malformedControl, got \(error)")
                    continue
                }
                #expect(error.daemonErrorCode == .badRequest)
            }
        }
    }

    @Test func binaryFrameFixturesDecodeAndReencodeByteForByte() throws {
        let files = try Fixtures.files("frames", ext: "hex")
        #expect(files.count == 9)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let bytes = try Fixtures.hexData(name)
            let frame = try FrameCodec.decode(bytes)
            #expect(try FrameCodec.encode(frame) == bytes, "re-encode mismatch: \(name)")
        }
    }

    @Test func binaryFrameFixturesHaveExpectedContent() throws {
        guard case .output(let out) = try FrameCodec.decode(Fixtures.hexData("output-hello-world")) else {
            Issue.record("expected output")
            return
        }
        #expect(out.sessionID == sid1 && out.seq == 4096 && out.bytes == Data("hello\r\n".utf8) && out.nextSeq == 4096 + 7)
        guard case .output(let high) = try FrameCodec.decode(Fixtures.hexData("output-high-seq")) else {
            Issue.record("expected output")
            return
        }
        #expect(high.seq == (1 << 40) + 7 && high.bytes == Data([0x1b, 0x5b, 0x32, 0x4a, 0x00, 0xff]))
        guard case .output(let empty) = try FrameCodec.decode(Fixtures.hexData("output-empty")) else {
            Issue.record("expected output")
            return
        }
        #expect(empty.bytes.isEmpty && empty.seq == 0)
        guard case .input(let paste) = try FrameCodec.decode(Fixtures.hexData("input-app-paste")) else {
            Issue.record("expected input")
            return
        }
        #expect(paste.origin == .appPaste && paste.sessionID == sid1)
        guard case .input(let reply) = try FrameCodec.decode(Fixtures.hexData("input-terminal-reply")) else {
            Issue.record("expected input")
            return
        }
        #expect(reply.origin == .terminalReply && reply.sessionID == sid2)
        guard case .control(.request(let hello)) = try FrameCodec.decode(Fixtures.hexData("control-hello")) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.command.op == "hello")
    }

    @Test func frameLayoutIsLengthKindPayloadBigEndian() throws {
        let bytes = try Fixtures.hexData("input-key")
        #expect(Array(bytes.prefix(5)) == [0, 0, 0, UInt8(1 + 16 + 1 + 3), 0x03])
        #expect(Array(bytes[5 ..< 21]) == sid1.bytes)
        #expect(bytes[21] == 0x00)
        #expect(Array(bytes.suffix(3)) == Array("ls\r".utf8))
        let output = try Fixtures.hexData("output-hello-world")
        #expect(output[0 ..< 4] == Data([0, 0, 0, UInt8(1 + 16 + 8 + 7)]))
        #expect(output[21 ..< 29] == Data([0, 0, 0, 0, 0, 0, 0x10, 0x00]))  // seq 4096, big-endian
    }
}
