import Testing
@testable import RackyPlatform

@Suite struct LogFacadeTests {
    @Test func subsystemsMatchCanonicalIdentifiers() {
        #expect(LogFacade.Subsystem.app.rawValue == "app.racky")
        #expect(LogFacade.Subsystem.ptyd.rawValue == "app.racky.ptyd")
        #expect(LogFacade.Subsystem.cli.rawValue == "app.racky.cli")
    }

    @Test func facadeKeepsCategory() {
        let log = LogFacade(.app, category: "lifecycle")
        #expect(log.category == "lifecycle")
        log.info("smoke")
    }
}
