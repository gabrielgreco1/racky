import Foundation
import Testing

@testable import RackyCore

/// Regressão: o `LazyComputerBackend` (todo computador de subagente nasce com ele) não repassava `vncEndpoint`, e o viewer
/// caía no padrão "this computer has no screen" para sempre ("Reconnecting…" sem fim).
struct LazyBackendForwardingTests {
    @Test func forwardsTheViewerEndpointOnceAttached() async throws {
        let lazy = LazyComputerBackend()
        await #expect(throws: ToolError.self) { _ = try await lazy.vncEndpoint() }
        let url = URL(string: "ws://127.0.0.1:1234/vnc?ticket=t")!
        let fake = FakeBackend()
        await fake.setVNCURL(url)
        lazy.attach(fake)
        #expect(try await lazy.vncEndpoint() == url)
    }
}
