import Foundation
import Testing
@testable import RackyCore

@Suite struct RightPanelLayoutTests {
    @Test func defaultsPutFilesOnTopAndInsightsBelow() {
        let layout = RightPanelLayout()
        #expect(layout.isOpen)
        #expect(layout.visible == [.files, .insights])
        #expect(layout.module(in: .top) == .files)
        #expect(layout.module(in: .bottom) == .insights)
        #expect(abs(layout.topFraction - 2.0 / 3.0) < 0.0001)
        #expect(layout.width == RightPanelGeometry.defaultWidth)
    }

    @Test func minimizingOneModuleLetsTheOtherFillThePanel() {
        var layout = RightPanelLayout()
        layout.hide(.insights)
        #expect(layout.visible == [.files])
        #expect(layout.module(in: .bottom) == nil)
        #expect(layout.isOpen)
        #expect(layout.isOn(.files))
        #expect(!layout.isOn(.insights))
    }

    @Test func hidingTheLastModuleClosesThePanel() {
        var layout = RightPanelLayout()
        layout.hide(.insights)
        layout.hide(.files)
        #expect(!layout.isOpen)
        #expect(layout.visible.isEmpty)
    }

    @Test func stripButtonReopensEachModule() {
        var layout = RightPanelLayout()
        layout.hide(.insights)
        layout.toggle(.insights)
        #expect(layout.isOn(.insights))
        #expect(layout.visible == [.files, .insights])
        layout.toggle(.files)
        #expect(layout.visible == [.insights])
        layout.toggle(.files)
        #expect(layout.visible == [.files, .insights])
    }

    @Test func closingTheWholePanelKeepsWhichModulesWereVisible() {
        var layout = RightPanelLayout()
        layout.hide(.insights)
        layout.toggleOpen()
        #expect(!layout.isOpen)
        #expect(!layout.isOn(.files))
        layout.toggleOpen()
        #expect(layout.isOpen)
        #expect(layout.visible == [.files])
    }

    @Test func stripButtonOpensAClosedPanelWithThatModule() {
        var layout = RightPanelLayout()
        layout.toggleOpen()
        layout.toggle(.insights)
        #expect(layout.isOpen)
        #expect(layout.isOn(.insights))
    }

    @Test func reopeningAnEmptyPanelRestoresTheDefaults() {
        var layout = RightPanelLayout()
        layout.hide(.files)
        layout.hide(.insights)
        #expect(!layout.isOpen)
        layout.toggleOpen()
        #expect(layout.isOpen)
        #expect(layout.visible == [.files, .insights])
    }

    @Test func droppingTheBottomHeaderOnTopSwapsTheOrder() {
        var layout = RightPanelLayout()
        let first = layout.drop(.insights, on: .top)
        #expect(first)
        #expect(layout.module(in: .top) == .insights)
        #expect(layout.module(in: .bottom) == .files)
        let sameSlot = layout.drop(.insights, on: .top)
        #expect(!sameSlot, "soltar no próprio slot não troca")
        let back = layout.drop(.insights, on: .bottom)
        #expect(back)
        #expect(layout.module(in: .top) == .files)
    }

    @Test func dropDoesNothingWithASingleVisibleModule() {
        var layout = RightPanelLayout()
        layout.hide(.insights)
        let dropped = layout.drop(.files, on: .bottom)
        #expect(!dropped)
        #expect(layout.visible == [.files])
    }

    @Test func swapSurvivesMinimizeAndRestore() {
        var layout = RightPanelLayout()
        layout.swapVisible()
        layout.hide(.files)
        layout.toggle(.files)
        #expect(layout.visible == [.insights, .files], "a posição trocada é lembrada")
    }

    @Test func aThirdModuleEvictsTheLeastRecentlyUsed() {
        var layout = RightPanelLayout()
        layout.show(.insights)
        layout.show(.files)  // files é o mais recente; insights o menos recente
        layout.show(.computers)
        #expect(layout.isVisible(.computers))
        #expect(layout.isVisible(.files))
        #expect(!layout.isVisible(.insights))
        #expect(layout.visible.count == RightPanelLayout.slotCapacity)
    }

    @Test func widthAndFractionAreClamped() {
        var layout = RightPanelLayout()
        layout.setWidth(10)
        #expect(layout.width == RightPanelGeometry.minWidth)
        layout.setWidth(10_000)
        #expect(layout.width == RightPanelGeometry.maxWidth)
        layout.setWidth(.nan)
        #expect(layout.width == RightPanelGeometry.defaultWidth)
        layout.setTopFraction(0)
        #expect(layout.topFraction == RightPanelGeometry.minTopFraction)
        layout.setTopFraction(5)
        #expect(layout.topFraction == RightPanelGeometry.maxTopFraction)
    }

    @Test func persistedStateRoundTripsAndToleratesMissingKeys() throws {
        var layout = RightPanelLayout()
        layout.setWidth(444)
        layout.setTopFraction(0.4)
        layout.swapVisible()
        layout.hide(.files)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(RightPanelLayout.self, from: data)
        #expect(decoded == layout)

        let sparse = try JSONDecoder().decode(RightPanelLayout.self, from: Data(#"{"width": 500}"#.utf8))
        #expect(sparse.width == 500)
        #expect(sparse.isOpen)
        #expect(sparse.visible == [.files, .insights])
    }

    @Test func modulesRegisteredLaterJoinTheOrder() {
        var layout = RightPanelLayout()
        layout.register(.computers)
        #expect(layout.order == [.files, .insights, .computers])
        #expect(layout.visible == [.files, .insights], "só dois cabem; o terceiro espera ser mostrado")
        #expect(layout.hidden == [.computers], "o terceiro nasce minimizado")
        layout.hide(.insights)
        #expect(layout.visible == [.files], "esconder um módulo não promove o minimizado")
    }
}

@Suite struct RightPanelGeometryTests {
    @Test func oneModuleTakesEverything() {
        #expect(RightPanelGeometry.slotHeights(total: 600, count: 1, topFraction: 0.7) == [600])
        #expect(RightPanelGeometry.slotHeights(total: 600, count: 0, topFraction: 0.7).isEmpty)
        #expect(RightPanelGeometry.slotHeights(total: 0, count: 2, topFraction: 0.7).isEmpty)
    }

    @Test func twoModulesSplitByFractionMinusTheDivider() {
        let heights = RightPanelGeometry.slotHeights(total: 901, count: 2, topFraction: 2.0 / 3.0)
        #expect(heights.count == 2)
        #expect(abs(heights[0] - 600) < 0.5)
        #expect(abs(heights[0] + heights[1] + RightPanelGeometry.dividerThickness - 901) < 0.001)
    }

    @Test func neitherModuleGoesBelowItsMinimum() {
        let minimum = RightPanelGeometry.minModuleHeight + RightPanelGeometry.moduleHeaderHeight
        let tiny = RightPanelGeometry.slotHeights(total: 500, count: 2, topFraction: RightPanelGeometry.minTopFraction)
        #expect(tiny[0] >= minimum)
        let huge = RightPanelGeometry.slotHeights(total: 500, count: 2, topFraction: RightPanelGeometry.maxTopFraction)
        #expect(huge[1] >= minimum)
    }

    @Test func tooShortForTwoModulesSplitsEvenly() {
        let heights = RightPanelGeometry.slotHeights(total: 200, count: 2, topFraction: 0.8)
        #expect(heights[0] == heights[1])
        #expect(heights[0] + heights[1] <= 200)
    }

    @Test func draggedHeightMapsBackToAFraction() {
        let total = 801.0
        let fraction = RightPanelGeometry.topFraction(forTopHeight: 400, total: total)
        #expect(abs(fraction - 0.5) < 0.001)
        let clampedLow = RightPanelGeometry.topFraction(forTopHeight: 1, total: total)
        #expect(clampedLow >= RightPanelGeometry.minTopFraction)
        let heights = RightPanelGeometry.slotHeights(total: total, count: 2, topFraction: clampedLow)
        #expect(heights[0] >= RightPanelGeometry.minModuleHeight + RightPanelGeometry.moduleHeaderHeight)
    }

    @Test func compactModeBelowTheThreshold() {
        #expect(RightPanelGeometry.isCompact(width: 260))
        #expect(RightPanelGeometry.isCompact(width: RightPanelGeometry.compactBelowWidth - 1))
        #expect(!RightPanelGeometry.isCompact(width: RightPanelGeometry.compactBelowWidth))
        #expect(!RightPanelGeometry.isCompact(width: 480))
    }

    @Test func windowRules() {
        #expect(RightPanelGeometry.autoCollapses(windowWidth: 1099))
        #expect(!RightPanelGeometry.autoCollapses(windowWidth: 1100))
        // 1440 de janela, sidebar 280: sobra muito, vale a largura pedida.
        #expect(RightPanelGeometry.effectiveWidth(requested: 380, windowWidth: 1440, sidebarWidth: 280) == 380)
        // 1100 com sidebar 500: o centro mínimo de 320 limita o painel a 280.
        #expect(RightPanelGeometry.effectiveWidth(requested: 600, windowWidth: 1100, sidebarWidth: 500) == 280)
        // 760 com sidebar 280: sobram 160, nem a largura mínima cabe.
        #expect(RightPanelGeometry.effectiveWidth(requested: 380, windowWidth: 760, sidebarWidth: 280) == nil)
    }
}
