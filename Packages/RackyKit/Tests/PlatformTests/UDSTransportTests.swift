import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyPlatform

@Suite(.tags(.integration)) struct UDSTransportTests {
    // MARK: Bytes crus

    @Test func echoesLargePayloadThroughPartialWrites() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let echo = Task {
            for await connection in listener.connections {
                Task {
                    while let chunk = try? await connection.receive() { try? await connection.send(chunk) }
                    connection.close()
                }
            }
        }
        defer { echo.cancel() }

        let client = try await UDSClient.connect(path: dir.socketPath)
        let payload = Data((0 ..< 3 << 20).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        async let sent: Void = client.send(payload)
        let received = try await readExactly(client, count: payload.count)
        try await sent
        #expect(received == payload)
        client.close()
    }

    @Test func socketFileIsOwnerOnly() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        var info = stat()
        #expect(stat(dir.socketPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
    }

    @Test func peerCloseYieldsEndOfStream() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        try await client.send(Data("bye".utf8))
        client.close()
        #expect(try await server.receive() == Data("bye".utf8))
        #expect(try await server.receive() == nil)
        #expect(try await server.receive() == nil)  // EOF é permanente
        server.close()
    }

    @Test func closeWakesPendingReceiveAndFailsLaterSends() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        let pending = Task { try await client.receive() }
        try await Task.sleep(for: .milliseconds(50))
        client.close()
        #expect(try await pending.value == nil)
        client.close()  // idempotente
        await #expect(throws: UDSError.closed) { try await client.send(Data([1])) }
    }

    @Test func cancellingReceiveClosesTheConnection() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        let pending = Task { try await client.receive() }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        #expect(try await pending.value == nil)
        // O par vê o fim do stream.
        #expect(try await server.receive() == nil)
        server.close()
    }

    @Test func concurrentReceiveIsRejected() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        let first = Task { try await client.receive() }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: UDSError.concurrentReceive) { _ = try await client.receive() }
        client.close()
        _ = try await first.value
    }

    @Test func connectToMissingSocketFails() async throws {
        let dir = try TempSocketDir()
        do {
            _ = try await UDSClient.connect(path: dir.socketPath)
            Issue.record("expected connect to fail")
        } catch let error as UDSError {
            guard case .system(let op, let code) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(op == "connect" && code == ENOENT)
        }
    }

    // MARK: Caminho, diretório e socket obsoleto

    @Test func pathTooLongIsRejected() async throws {
        let long = "/tmp/" + String(repeating: "a", count: 120)
        await #expect(throws: UDSError.pathTooLong(long.utf8.count)) { _ = try await UDSClient.connect(path: long) }
        await #expect(throws: UDSError.pathTooLong(long.utf8.count)) {
            _ = try await UDSListener.listen(path: long, requirePrivateDirectory: false)
        }
    }

    @Test func insecureDirectoryIsRejected() async throws {
        let dir = try TempSocketDir(mode: 0o755)
        await #expect(throws: UDSError.insecureDirectory(dir.url.path)) { _ = try await UDSListener.listen(path: dir.socketPath) }
        // Opt-out explícito (só para diretórios que o chamador já controla).
        let listener = try await UDSListener.listen(path: dir.socketPath, requirePrivateDirectory: false)
        listener.close()
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let dir = try TempSocketDir()
        // Cria um socket "obsoleto": faz bind sem listen e some com o dono.
        let fd = try UDSSupport.makeSocket()
        try UDSSupport.withSockaddr(path: dir.socketPath) { address, length in
            #expect(bind(fd, address, length) == 0)
        }
        Darwin.close(fd)  // o arquivo permanece
        var info = stat()
        #expect(lstat(dir.socketPath, &info) == 0)
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let client = try await UDSClient.connect(path: dir.socketPath)
        client.close()
        listener.close()
    }

    @Test func liveServerIsNotStolen() async throws {
        let dir = try TempSocketDir()
        let first = try await UDSListener.listen(path: dir.socketPath)
        defer { first.close() }
        await #expect(throws: UDSError.addressInUse(dir.socketPath)) { _ = try await UDSListener.listen(path: dir.socketPath) }
        // O primeiro continua atendendo.
        let client = try await UDSClient.connect(path: dir.socketPath)
        client.close()
    }

    @Test func regularFileAtPathIsNotRemoved() async throws {
        let dir = try TempSocketDir()
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir.socketPath))
        await #expect(throws: UDSError.pathOccupied(dir.socketPath)) { _ = try await UDSListener.listen(path: dir.socketPath) }
        #expect(FileManager.default.fileExists(atPath: dir.socketPath))
    }

    @Test func closingTheListenerRemovesTheSocketAndEndsTheStream() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        listener.close()
        var count = 0
        for await _ in listener.connections { count += 1 }
        #expect(count == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: dir.socketPath))
        await #expect(throws: UDSError.self) { _ = try await UDSClient.connect(path: dir.socketPath) }
    }

    @Test func adoptedListeningDescriptorAcceptsWithoutBindOrUnlink() async throws {
        let dir = try TempSocketDir()
        let fd = try UDSSupport.makeSocket()
        try UDSSupport.withSockaddr(path: dir.socketPath) { address, length in
            #expect(bind(fd, address, length) == 0)
        }
        #expect(Darwin.listen(fd, 4) == 0)
        let listener = try UDSListener.adopt(fileDescriptor: fd)
        #expect(listener.path == nil)
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())
        try await client.send(Data("hi".utf8))
        #expect(try await server.receive() == Data("hi".utf8))
        client.close()
        server.close()
        listener.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.fileExists(atPath: dir.socketPath))  // quem criou o arquivo é o dono do fd (launchd)
    }

    // MARK: Contrapressão e pool cooperativo

    @Test func sendSuspendsUntilThePeerDrains() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())

        let total = 16 << 20  // muito acima dos buffers do kernel
        let done = Flag()
        let completed = Task {
            try await server.send(Data(count: total))
            await done.set()
        }
        try await Task.sleep(for: .milliseconds(300))
        // Ninguém leu: o envio ainda está suspenso (não terminou, não falhou).
        #expect(await !done.isSet)

        let received = try await readExactly(client, count: total)
        #expect(received.count == total)
        try await completed.value
        client.close()
        server.close()
    }

    @Test func heavyTransferDoesNotStarveTheCooperativePool() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let server = try #require(await iterator.next())

        let probe = LatencyProbe()
        let ticker = Task { await probe.run() }
        let total = 64 << 20
        async let sent: Void = server.send(Data(count: total))
        let received = try await readExactly(client, count: total)
        try await sent
        await probe.stop()
        await ticker.value
        #expect(received.count == total)
        let gap = await probe.maxGap
        #expect(gap < .milliseconds(500), "cooperative pool stalled for \(gap)")
        client.close()
        server.close()
    }

    @Test func outboundQueuePumpedToASlowSocketResyncsInsteadOfBlocking() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let clientRaw = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let serverRaw = try #require(await iterator.next())
        let server = FramedConnection(serverRaw)
        let client = FramedConnection(clientRaw)

        // O daemon produz 8 MiB em frames de 64 KiB enquanto o cliente não lê: a fila (2 MiB) estoura.
        var queue = OutboundQueue()
        let session = SessionID()
        var seq: UInt64 = 0
        var overflowed = false
        let started = ContinuousClock.now
        for _ in 0 ..< 128 {
            let frame = Frame.output(OutputFrame(sessionID: session, seq: seq, bytes: Data(count: 64 << 10)))
            seq += 64 << 10
            if case .overflow = try queue.enqueue(frame) { overflowed = true }
        }
        #expect(ContinuousClock.now - started < .seconds(2))  // produzir nunca espera pelo cliente
        #expect(overflowed)
        #expect(queue.isAwaitingResync(session))

        // Drena a fila para o socket enquanto o cliente lê devagar; o cliente vê o resyncRequired.
        let pump = Task {
            while let frame = queue.dequeue() { try await server.send(frame) }
        }
        var sawResync = false
        var outputBytes = 0
        while !sawResync, let frame = try await client.receive() {
            switch frame {
            case .output(let output): outputBytes += output.bytes.count
            case .control(.event(let event)) where event.payload == .resyncRequired: sawResync = true
            default: break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await pump.value
        #expect(sawResync)
        #expect(outputBytes <= ProtocolLimits.clientQueueLimit)
        await client.close()
        await server.close()
    }
}

