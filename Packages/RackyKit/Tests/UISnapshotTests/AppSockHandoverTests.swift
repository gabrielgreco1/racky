import RackyPlatform
import Foundation
import Testing

@testable import RackyUI

/// F41: relançado logo após o quit, o app espera a instância anterior soltar `app.sock` em vez de ficar sem hub (agentes viam
/// "Racky is not running").
@MainActor
@Suite struct AppSockHandoverTests {
    @Test func hubStartsOnceThePreviousInstanceReleasesTheSocket() async throws {
        let path = "/tmp/abx-handover-\(UInt32.random(in: 0 ... 0xFFFFFF)).sock"
        defer { unlink(path) }
        let previous = AppSockServer(path: path) { { _ in AppSockReply() } }
        try await previous.start()
        let next = AppSockServer(path: path) { { _ in AppSockReply() } }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await previous.stop()
        }
        let started = await AppEnvironment.startRetryingWhileAnotherInstanceExits(
            socketPath: path, start: { try await next.start() }, log: LogFacade(.app, category: "test"), timeout: .seconds(30), interval: .milliseconds(50))
        #expect(started)
        #expect(await next.isRunning)
        await next.stop()
    }

    @Test func givesUpAfterTheTimeoutWhenTheSocketStaysTaken() async throws {
        let path = "/tmp/abx-handover-\(UInt32.random(in: 0 ... 0xFFFFFF)).sock"
        defer { unlink(path) }
        let holder = AppSockServer(path: path) { { _ in AppSockReply() } }
        try await holder.start()
        let next = AppSockServer(path: path) { { _ in AppSockReply() } }
        let started = await AppEnvironment.startRetryingWhileAnotherInstanceExits(
            socketPath: path, start: { try await next.start() }, log: LogFacade(.app, category: "test"), timeout: .milliseconds(300), interval: .milliseconds(50))
        #expect(!started)
        await holder.stop()
    }
}
