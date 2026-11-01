import Foundation
import Testing

@testable import RackyPlatform

/// `finishWriting()` (T3-01, S9): half-close da escrita com a leitura ainda aberta, como o stdin de um exec hijacked.
@Suite struct HalfCloseTests {
    @Test func peerSeesEOFAfterQueuedBytesAndStillAnswers() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let server = Task { () -> Data in
            var received = Data()
            for await connection in listener.connections {
                while let chunk = try await connection.receive() { received.append(chunk) }  // só termina no EOF do cliente
                try await connection.send(Data("echo:".utf8) + received)
                connection.close()
                break
            }
            return received
        }
        let client = try await UDSClient.connect(path: dir.socketPath)
        try await client.send(Data("hello ".utf8))
        try await client.send(Data("world".utf8))
        client.finishWriting()
        var reply = Data()
        while let chunk = try await client.receive() { reply.append(chunk) }
        #expect(String(decoding: reply, as: UTF8.self) == "echo:hello world")
        #expect(String(decoding: try await server.value, as: UTF8.self) == "hello world")
        client.close()
    }

    @Test func finishWritingWithLargePendingWriteDeliversEverythingFirst() async throws {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        defer { listener.close() }
        let server = Task { () -> Int in
            var total = 0
            for await connection in listener.connections {
                while let chunk = try await connection.receive() { total += chunk.count }
                connection.close()
                break
            }
            return total
        }
        let client = try await UDSClient.connect(path: dir.socketPath)
        let big = Data(repeating: 0x41, count: 8 << 20)  // maior que o buffer do socket: o send suspende até drenar
        async let sent: Void = client.send(big)
        try await Task.sleep(for: .milliseconds(20))
        client.finishWriting()  // pedido enquanto ainda há bytes pendentes
        try await sent
        #expect(try await server.value == big.count)
        client.close()
    }
}
