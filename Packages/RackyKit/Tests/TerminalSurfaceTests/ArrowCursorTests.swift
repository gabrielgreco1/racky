import AppKit
import ObjectiveC
import SwiftTerm
import Testing

@testable import RackyUI

/// Sobre o terminal o cursor é a seta (o SwiftTerm usa o I-beam no pane inteiro).
@MainActor
@Suite struct ArrowCursorTests {
    @Test func surfaceUsesTheArrowInsteadOfSwiftTermsIBeam() throws {
        let surface = TerminalSurfaceView()
        let reset = #selector(NSView.resetCursorRects), update = #selector(NSResponder.cursorUpdate(with:))
        #expect(class_getMethodImplementation(TerminalSurfaceView.self, reset) != class_getMethodImplementation(TerminalView.self, reset))
        #expect(class_getMethodImplementation(TerminalSurfaceView.self, update) != class_getMethodImplementation(TerminalView.self, update))
        NSCursor.iBeam.set()
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        surface.perform(update, with: event)
        #expect(NSCursor.current == NSCursor.arrow)
    }
}
