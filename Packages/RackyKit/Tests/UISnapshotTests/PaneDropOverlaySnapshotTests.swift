import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import Testing

@testable import RackyUI

/// Zonas de drop sobre um pane (F11): prévia translúcida de cada lado, do centro (com o glifo de troca) e a variante sem espaço.
/// Referências em `__Snapshots__/`; gravar com `RACKY_RECORD_SNAPSHOTS=1`. Nenhuma janela: só views fora da tela.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct PaneDropOverlaySnapshotTests {
    static let size = CGSize(width: 520, height: 240)

    private func canvas(zone: PaneDropZone, outcome: DropOutcome = .applied) -> NSView {
        DSFonts.registerIfNeeded()
        let host = FlippedBox(frame: NSRect(origin: .zero, size: Self.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = DS.ColorSpec.terminalBackground.nsColor.cgColor
        host.appearance = NSAppearance(named: .darkAqua)
        // Dois panes lado a lado; o cursor está sobre o da direita.
        let divider = NSView(frame: NSRect(x: 258, y: 0, width: 3, height: Self.size.height))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.ColorSpec.paneDivider.nsColor.cgColor
        host.addSubview(divider)
        let overlay = PaneDropOverlayView(elements: nil)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        overlay.show(zone: zone, outcome: outcome, paneFrame: CGRect(x: 261, y: 0, width: 259, height: Self.size.height))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func snap(_ zone: PaneDropZone, outcome: DropOutcome = .applied, name: String, line: UInt = #line) {
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: canvas(zone: zone, outcome: outcome), as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "paneDrop", line: line)
        }
    }

    @Test func zones() {
        for zone in PaneDropZone.allCases { snap(zone, name: zone.rawValue) }
    }

    @Test func noRoomIsRed() {
        snap(.right, outcome: .noRoom, name: "noRoom")
    }

    @Test func previewGeometryMatchesTheSpecAndStaysInsideThePane() {
        let overlay = PaneDropOverlayView(elements: nil)
        let pane = CGRect(x: 261, y: 0, width: 259, height: 240)
        overlay.show(zone: .left, outcome: .applied, paneFrame: pane)
        #expect(overlay.previewTarget == PaneDropZone.left.previewRect(in: pane).insetBy(dx: PaneDropOverlayView.inset, dy: PaneDropOverlayView.inset))
        overlay.show(zone: .center, outcome: .applied, paneFrame: pane)
        #expect(pane.contains(overlay.previewTarget))
        #expect(overlay.alphaValue == 1)
    }
}

private final class FlippedBox: NSView {
    override var isFlipped: Bool { true }
}
