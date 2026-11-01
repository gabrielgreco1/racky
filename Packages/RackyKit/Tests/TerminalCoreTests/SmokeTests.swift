import Testing
@testable import RackyTerminalCore

@Suite struct TerminalCoreTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyTerminalCoreModule.name == "RackyTerminalCore")
    }
}
