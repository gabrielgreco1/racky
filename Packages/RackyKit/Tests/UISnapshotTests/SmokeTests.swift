import Testing
@testable import RackyDesignSystem
@testable import RackyUI

@Suite(.offscreenAppKit) struct UISnapshotSmoke {
    @Test func uiModulesLink() {
        #expect(RackyUIModule.name == "RackyUI")
        #expect(RackyDesignSystemModule.name == "RackyDesignSystem")
    }
}
