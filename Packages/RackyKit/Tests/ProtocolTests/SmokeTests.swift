import Testing
@testable import RackyProtocol

@Suite struct ProtocolTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyProtocolModule.name == "RackyProtocol")
    }
}
