import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// 03/11: um teste trocou o `app.sock` do app por um socket morto e todos os agentes viram "Racky is not running" com o app vivo.
/// O servidor percebe a troca e volta a se publicar; e o `stop` nunca apaga um arquivo que não é dele.
@Suite struct AppSockRebindTests {
    /// Cria em `path` um socket sem ninguém escutando (o que sobra quando um processo sai sem apagar o arquivo).
    static func leaveDeadSocket(at path: String) throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.close(fd)
        #expect(rc == 0)
    }

    static func tempPath() -> String { "/tmp/abx-rebind-\(UInt32.random(in: 0 ... 0xFFFFFF)).sock" }

    @Test func comesBackWhenItsSocketFileIsReplacedByADeadOne() async throws {
        let path = Self.tempPath()
        defer { unlink(path) }
        let server = AppSockServer(path: path, watchInterval: .seconds(3600)) { { _ in AppSockReply() } }
        try await server.start()
        #expect(AppSockClient.isListening(path: path))
        try Self.leaveDeadSocket(at: path)
        #expect(!AppSockClient.isListening(path: path))
        await server.rebindIfReplaced()
        #expect(AppSockClient.isListening(path: path))
        #expect(await server.isRunning)
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func theWatchdogRebindsOnItsOwn() async throws {
        let path = Self.tempPath()
        defer { unlink(path) }
        let server = AppSockServer(path: path, watchInterval: .milliseconds(100)) { { _ in AppSockReply() } }
        try await server.start()
        try Self.leaveDeadSocket(at: path)
        var back = false
        for _ in 0 ..< 100 where !back {
            try await Task.sleep(for: .milliseconds(50))
            back = AppSockClient.isListening(path: path)
        }
        #expect(back)
        await server.stop()
    }

    @Test func leavesAnotherLiveInstanceAloneAndNeverDeletesItsFile() async throws {
        let path = Self.tempPath()
        defer { unlink(path) }
        let first = AppSockServer(path: path, watchInterval: .seconds(3600)) { { _ in AppSockReply() } }
        try await first.start()
        unlink(path)  // alguém apagou o arquivo do primeiro
        let second = AppSockServer(path: path, watchInterval: .seconds(3600)) { { _ in AppSockReply() } }
        try await second.start()
        await first.rebindIfReplaced()  // o segundo atende em `path`: o primeiro não toma o lugar
        await first.stop()  // e ao parar não apaga o arquivo do segundo
        #expect(AppSockClient.isListening(path: path))
        await second.stop()
    }
}
