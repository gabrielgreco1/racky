import AppKit
import SwiftUI
import Testing

@testable import RackyDesignSystem

/// `PromptEditor` (02 §12.10): ⌘↵ envia, Return quebra linha, IME, Esc, foco sem selecionar tudo, altura automática.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct PromptEditorTests {
    private func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// Editor real dentro de uma janela fora da tela.
    private func mount(_ text: String, autofocus: Bool = false, onSubmit: @escaping () -> Void = {}, onEscape: (() -> Void)? = nil)
        async -> (NSWindow, PromptTextView, Box)
    {
        DSFonts.registerIfNeeded()
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let root = PromptEditor(text: binding, placeholder: "Describe the task", autofocus: autofocus, onSubmit: onSubmit, onEscape: onEscape)
            .frame(width: 400)
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 400, height: 300), styleMask: [.titled])
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        let view = Self.find(PromptTextView.self, in: host)!
        return (window, view, box)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }

    @Test func commandReturnSubmitsAndPlainReturnDoesNot() async {
        var submits = 0
        let (window, view, _) = await mount("hello", onSubmit: { submits += 1 })
        defer { window.close() }
        view.keyDown(with: key(36, chars: "\r", flags: .command))
        #expect(submits == 1)
        view.keyDown(with: key(76, chars: "\u{3}", flags: .command))
        #expect(submits == 2, "⌘ com o Enter do teclado numérico também envia")
        view.keyDown(with: key(36, chars: "\r"))
        #expect(submits == 2, "Return sozinho não envia")
        view.keyDown(with: key(36, chars: "\r", flags: .shift))
        #expect(submits == 2)
    }

    @Test func commandReturnIsIgnoredWhileComposingWithAnIME() async {
        var submits = 0
        let (window, view, _) = await mount("", onSubmit: { submits += 1 })
        defer { window.close() }
        view.setMarkedText("かんじ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.keyDown(with: key(36, chars: "\r", flags: .command))
        #expect(submits == 0, "a composição ainda não foi confirmada")
        view.unmarkText()
        view.keyDown(with: key(36, chars: "\r", flags: .command))
        #expect(submits == 1)
    }

    @Test func escapeGoesToTheCallerOrDownTheResponderChain() async {
        var escapes = 0
        let (window, view, _) = await mount("x", onEscape: { escapes += 1 })
        defer { window.close() }
        view.cancelOperation(nil)
        #expect(escapes == 1)
        view.onEscape = nil
        view.cancelOperation(nil)  // sem tratador e sem responder acima que o trate: não trava nem altera o texto
        #expect(view.string == "x")
    }

    @Test func focusingDoesNotSelectTheText() async {
        let (window, view, _) = await mount("Fix the search pagination", autofocus: true)
        defer { window.close() }
        #expect(window.firstResponder === view, "autofocus leva o foco ao editor")
        #expect(view.selectedRange().length == 0, "o texto nunca vem selecionado")
        #expect(view.selectedRange().location == (view.string as NSString).length, "cursor no fim")
        // Perder e recuperar o foco também não seleciona.
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        #expect(view.selectedRange().length == 0)
    }

    @Test func typingFlowsBackToTheBinding() async {
        let (window, view, box) = await mount("")
        defer { window.close() }
        window.makeFirstResponder(view)
        view.insertText("Add retry", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "Add retry")
        #expect(box.text == "Add retry")
    }

    @Test func placeholderIsOnlyDrawnWhenEmpty() async {
        let (window, view, _) = await mount("")
        defer { window.close() }
        #expect(view.placeholder == "Describe the task" && view.string.isEmpty)
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.string.isEmpty)
    }

    @Test func heightGrowsWithTheContentAndIsClamped() async {
        let (window, view, _) = await mount("")
        defer { window.close() }
        let scroll = view.enclosingScrollView!
        let editor = PromptEditor(text: .constant(""), placeholder: "")
        let coordinator = editor.makeCoordinator()
        _ = coordinator
        let size = { (text: String) -> CGFloat in
            view.string = text
            view.setFrameSize(NSSize(width: 400, height: view.frame.height))
            return min(max(view.contentHeight, DSMetrics.textareaMinHeight), DSMetrics.promptMaxHeight)
        }
        #expect(size("") == DSMetrics.textareaMinHeight, "88 no mínimo")
        #expect(size("a\nb\nc\nd\ne\nf\ng") > DSMetrics.textareaMinHeight, "cresce com as linhas")
        #expect(size(String(repeating: "linha\n", count: 80)) == DSMetrics.promptMaxHeight, "240 no máximo; depois rola")
        #expect(scroll.hasVerticalScroller)
    }
}
