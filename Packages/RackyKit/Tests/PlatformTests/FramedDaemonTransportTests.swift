import RackyProtocol
import Foundation
import Testing

@testable import RackyPlatform

@Suite(.tags(.integration)) struct FramedDaemonTransportTests {
    private func connect(_ dir: TempSocketDir) async throws -> FramedConnection {
        FramedConnection(try await UDSClient.connect(path: dir.socketPath))
    }

    // MARK: Handshake de ponta a ponta

    @Test func handshakeThenPingAndListAgainstFakeDaemon() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener)
        defer {
            listener.close()
            daemon.cancel()
        }

        let client = try await connect(dir)
        let result = try await client.performHandshake(makeClientHandshake())
        #expect(result.session.version == .current)
        #expect(result.session.capabilities == Capability.initialSet)
        #expect(result.daemon == testDaemonInfo && result.sessions == 0 && !result.isCompatibilityMode)

        try await client.send(.control(.request(DaemonRequest(id: 2, command: .ping))))
        guard case .control(.reply(.ok(let id, .pong(let pong)))) = try #require(await client.receive()) else {
            Issue.record("expected pong")
            return
        }
        #expect(id == 2 && pong.uptimeMillis == 1)

        try await client.send(.control(.request(DaemonRequest(id: 3, command: .list))))
        guard case .control(.reply(.ok(3, .list(let list)))) = try #require(await client.receive()) else {
            Issue.record("expected list")
            return
        }
        #expect(list.sessions.isEmpty)
        await client.close()
    }

    @Test func inputFramesComeBackAsContiguousOutput() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener)
        defer {
            listener.close()
            daemon.cancel()
        }
        let client = try await connect(dir)
        _ = try await client.performHandshake(makeClientHandshake())
        let session = SessionID()
        let pieces = ["ls", " -la", "\r", "echo é\r"]
        for piece in pieces {
            try await client.send(.input(InputFrame(sessionID: session, origin: .key, bytes: Data(piece.utf8))))
        }
        var validator = OutputSequenceValidator(expectedSeq: 0)
        var echoed = Data()
        for _ in pieces {
            guard case .output(let output) = try #require(await client.receive()) else {
                Issue.record("expected output")
                return
            }
            #expect(validator.accept(output) == .continuous)
            echoed.append(output.bytes)
        }
        #expect(String(decoding: echoed, as: UTF8.self) == pieces.joined())
        await client.close()
    }

    @Test func manyConcurrentClientsEachHandshake() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener)
        defer {
            listener.close()
            daemon.cancel()
        }
        let path = dir.socketPath
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 25 {
                group.addTask {
                    let client = FramedConnection(try await UDSClient.connect(path: path))
                    _ = try await client.performHandshake(makeClientHandshake())
                    try await client.send(.control(.request(DaemonRequest(id: RequestID(rawValue: UInt64(index)), command: .ping))))
                    guard case .control(.reply(.ok(let id, _))) = try #require(await client.receive()) else {
                        Issue.record("expected ok")
                        return
                    }
                    #expect(id.rawValue == UInt64(index))
                    await client.close()
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: Versões

    @Test func majorMismatchOverTheWire() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener)
        defer {
            listener.close()
            daemon.cancel()
        }
        let client = try await connect(dir)
        let future = makeClientHandshake(version: ProtocolVersion(major: 2, minor: 0))
        do {
            _ = try await client.performHandshake(future)
            Issue.record("expected rejection")
        } catch let error as HandshakeError {
            guard case .rejectedByDaemon(let daemonError) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(daemonError.code == .protocolMajorMismatch)
        }
        // O daemon fechou: fim do stream.
        #expect(try await client.receive() == nil)
        await client.close()
    }

    @Test func appNTalksToDaemonNMinus1ThroughCompatibilityClient() async throws {
        // "Daemon N-1" = major 1 minor 2 sem a capability nova; app N-1-compat anuncia major 1 e aceita [1, 2].
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let oldDaemon = Task {
            for await connection in listener.connections {
                Task {
                    let framed = FramedConnection(connection)
                    let handshake = makeServerHandshake(version: ProtocolVersion(major: 1, minor: 2), capabilities: [.coldLog, .osc133, .textSnapshot, .inputOrigin])
                    _ = try? await framed.acceptHandshake(handshake, sessions: 3)
                    _ = try? await framed.receive()
                    await framed.close()
                }
            }
        }
        defer {
            listener.close()
            oldDaemon.cancel()
        }
        let client = try await connect(dir)
        let compat = ClientHandshake(version: ProtocolVersion(major: 1, minor: 0), client: ClientInfo(kind: .app, build: "N"), acceptedMajors: [1, 2])
        let result = try await client.performHandshake(compat)
        #expect(result.sessions == 3)
        #expect(result.session.version == ProtocolVersion(major: 1, minor: 0))
        #expect(!result.session.supports(.drainWhenIdle))
        await client.close()
    }

    @Test func clientNWithoutCompatRejectsDaemonNMinus1() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener, version: ProtocolVersion(major: 1, minor: 0))
        defer {
            listener.close()
            daemon.cancel()
        }
        // Cliente da major 2 anuncia major 2: o daemon major 1 o recusa antes de qualquer outra coisa.
        let client = try await connect(dir)
        await #expect(throws: HandshakeError.self) {
            _ = try await client.performHandshake(makeClientHandshake(version: ProtocolVersion(major: 2, minor: 0), accepted: [1, 2]))
        }
        await client.close()
    }

    // MARK: Timeout e frames inválidos

    @Test func handshakeTimeoutClosesTheConnection() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let silent = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let serverRaw = try #require(await iterator.next())
        let server = FramedConnection(serverRaw)

        let started = ContinuousClock.now
        await #expect(throws: HandshakeError.timedOut) {
            _ = try await server.acceptHandshake(makeServerHandshake(), sessions: 0, timeout: .milliseconds(300))
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(250) && elapsed < .seconds(2))
        // O cliente silencioso vê a conexão cair.
        #expect(try await silent.receive() == nil)
        silent.close()
    }

    @Test func defaultHandshakeTimeoutIsTwoSeconds() {
        #expect(ProtocolLimits.handshakeTimeout == .seconds(2))
    }

    @Test func nonHelloFirstFrameIsRejectedWithBadRequest() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await connect(dir)
        var iterator = listener.connections.makeAsyncIterator()
        let server = FramedConnection(try #require(await iterator.next()))

        try await client.send(.control(.request(DaemonRequest(id: 9, command: .list))))
        await #expect(throws: HandshakeError.self) {
            _ = try await server.acceptHandshake(makeServerHandshake(), sessions: 0)
        }
        guard case .control(.reply(.error(let id, let error))) = try #require(await client.receive()) else {
            Issue.record("expected error reply")
            return
        }
        #expect(id == 9 && error.code == .badRequest)
        #expect(try await client.receive() == nil)
        await client.close()
    }

    @Test func oversizedFrameGetsFrameTooLargeErrorAndDisconnect() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let daemon = serveFakeDaemon(on: listener)
        defer {
            listener.close()
            daemon.cancel()
        }
        let client = try await connect(dir)
        _ = try await client.performHandshake(makeClientHandshake())
        // Prefixo anunciando 2 MiB (sem mandar o corpo): o daemon recusa na hora.
        try await client.sendRaw(Data([0x00, 0x20, 0x00, 0x00, 0x01]))
        guard case .control(.reply(.error(nil, let error))) = try #require(await client.receive()) else {
            Issue.record("expected connection-level error")
            return
        }
        #expect(error.code == .frameTooLarge)
        #expect(try await client.receive() == nil)
        await client.close()
    }

    @Test func oversizedFirstFrameDuringHandshakeIsRejected() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await connect(dir)
        var iterator = listener.connections.makeAsyncIterator()
        let server = FramedConnection(try #require(await iterator.next()))
        try await client.sendRaw(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        await #expect(throws: FrameError.frameTooLarge(length: Int(UInt32.max))) {
            _ = try await server.acceptHandshake(makeServerHandshake(), sessions: 0)
        }
        guard case .control(.reply(.error(_, let error))) = try #require(await client.receive()) else {
            Issue.record("expected error reply")
            return
        }
        #expect(error.code == .frameTooLarge)
        await client.close()
    }

    @Test func truncatedFrameThenDisconnectIsReportedAtEndOfStream() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await connect(dir)
        var iterator = listener.connections.makeAsyncIterator()
        let server = FramedConnection(try #require(await iterator.next()))
        let full = try FrameCodec.encode(.input(InputFrame(sessionID: SessionID(), origin: .key, bytes: Data("hello".utf8))))
        try await client.sendRaw(full.prefix(full.count - 2))
        await client.close()
        await #expect(throws: FrameError.truncatedFrame(expected: full.count, available: full.count - 2)) {
            _ = try await server.receive()
        }
        await server.close()
    }

    @Test func corruptedFramesAreSurfacedNotSwallowed() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let client = try await connect(dir)
        let server = FramedConnection(try #require(await iterator.next()))

        try await client.sendRaw(Data([0, 0, 0, 2, 0x7E, 0x00]))  // kind desconhecido
        await #expect(throws: FrameError.unknownKind(0x7E)) { _ = try await server.receive() }
        // Falha permanente na mesma conexão.
        await #expect(throws: FrameError.self) { _ = try await server.receive() }
        await client.close()
        await server.close()
    }

    @Test func goodFramesBeforeCorruptionAreStillDelivered() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let client = try await connect(dir)
        let server = FramedConnection(try #require(await iterator.next()))

        let good = Frame.control(.request(DaemonRequest(id: 1, command: .ping)))
        try await client.send(good)
        try await client.sendRaw(Data([0, 0, 0, 2, 0x7E, 0x00]))
        #expect(try await server.receive() == good)
        await #expect(throws: FrameError.unknownKind(0x7E)) { _ = try await server.receive() }
        await client.close()
        await server.close()
    }

    @Test func framesSplitAcrossManyWritesReassemble() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let client = try await connect(dir)
        let server = FramedConnection(try #require(await iterator.next()))

        let frames: [Frame] = (0 ..< 50).map {
            .output(OutputFrame(sessionID: SessionID(), seq: UInt64($0), bytes: Data(repeating: UInt8($0), count: 1000)))
        }
        let stream = try frames.reduce(Data()) { $0 + (try FrameCodec.encode($1)) }
        let writer = Task {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + 7, stream.count)
                try await client.sendRaw(stream[offset ..< end])
                offset = end
            }
        }
        var received: [Frame] = []
        while received.count < frames.count, let frame = try await server.receive() { received.append(frame) }
        try await writer.value
        #expect(received == frames)
        await client.close()
        await server.close()
    }

    @Test func maxSizeFrameCrossesTheSocketIntact() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        var iterator = listener.connections.makeAsyncIterator()
        let client = try await connect(dir)
        let server = FramedConnection(try #require(await iterator.next()))
        let big = Frame.output(OutputFrame(sessionID: SessionID(), seq: 1, bytes: Data(repeating: 0xAB, count: FrameCodec.maxOutputBytes)))
        async let sent: Void = client.send(big)
        #expect(try await server.receive() == big)
        try await sent
        await client.close()
        await server.close()
    }
}
