import Testing
@testable import RackyStore

@Suite struct StoreTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyStoreModule.name == "RackyStore")
    }
}
