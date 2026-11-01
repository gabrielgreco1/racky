import Testing
@testable import RackyPlatform
@testable import RackyProtocol
@testable import RackyTerminalCore

@Suite(.tags(.integration), .serialized, .timeLimit(.minutes(1))) struct DaemonSmoke {
    @Test func daemonDependenciesLink() {
        #expect(RackyProtocolModule.name == "RackyProtocol")
        #expect(RackyPlatformModule.name == "RackyPlatform")
        #expect(RackyTerminalCoreModule.name == "RackyTerminalCore")
    }
}
