import Testing
@testable import RackyCore

@Suite struct CoreTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyCoreModule.name == "RackyCore")
    }
}
