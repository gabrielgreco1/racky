import Testing
@testable import RackyPlatform

@Suite struct PlatformTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyPlatformModule.name == "RackyPlatform")
    }
}
