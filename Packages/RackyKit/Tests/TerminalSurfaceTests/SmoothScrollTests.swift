import AppKit
import Testing
@testable import RackyUI

/// Backlog 3: o resto de linha do trackpad vira deslocamento em pixels; linhas inteiras ficam com o SwiftTerm.
struct SmoothScrollTests {
    @Test func partialLinesBecomeAPixelOffsetAndWholeLinesGoToTheTerminal() {
        var s = SmoothScrollState()
        #expect(s.feed(delta: 7, cellHeight: 17) == 0)
        #expect(s.offset(atTop: false, atBottom: false) == 7)
        #expect(s.feed(delta: 12, cellHeight: 17) == 1, "passou de uma linha: o SwiftTerm rola uma")
        #expect(s.offset(atTop: false, atBottom: false) == 2)
        #expect(s.feed(delta: -40, cellHeight: 17) == -2)
        #expect(s.offset(atTop: false, atBottom: false) == -4)
    }

    @Test func noOffsetAgainstTheEdges() {
        var s = SmoothScrollState()
        _ = s.feed(delta: 5, cellHeight: 17)
        #expect(s.offset(atTop: true, atBottom: false) == 0, "no topo do histórico não há linha acima")
        s.reset()
        _ = s.feed(delta: -5, cellHeight: 17)
        #expect(s.offset(atTop: false, atBottom: true) == 0, "no fim não há linha abaixo")
        #expect(s.offset(atTop: true, atBottom: false) == -5)
    }
}
