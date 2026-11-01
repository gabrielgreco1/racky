import Testing

@testable import RackyUI

/// `racky.owner` dos containers: o app do dono segue com `racky`; um `RACKY_HOME` isolado (testes, e2e) nunca o compartilha.
@MainActor
@Suite struct ComputerOwnerTests {
    @Test func productionKeepsTheDefaultOwner() {
        #expect(AppEnvironment.computerOwner([:]) == "racky")
        #expect(AppEnvironment.computerOwner(["RACKY_HOME": ""]) == "racky")
    }

    @Test func isolatedHomeGetsItsOwnStableOwner() {
        let a = AppEnvironment.computerOwner(["RACKY_HOME": "/tmp/abe2e-a"])
        let b = AppEnvironment.computerOwner(["RACKY_HOME": "/tmp/abe2e-b"])
        #expect(a.hasPrefix("racky-") && a != "racky")
        #expect(a != b)
        #expect(a == AppEnvironment.computerOwner(["RACKY_HOME": "/tmp/abe2e-a"]))
    }
}
