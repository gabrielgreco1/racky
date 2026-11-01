import AppKit
import SwiftUI

// Editor de prompt multilinha (02 §12.10): `NSTextView` para controlar padding, ⌘↵, Esc, IME e a seleção ao focar.

/// `NSTextView` do prompt. Return insere quebra de linha; ⌘↵ envia (ignorado durante composição IME); Esc é do chamador.
public final class PromptTextView: NSTextView {
    public var onSubmit: () -> Void = {}
    public var onEscape: (() -> Void)?
    public var placeholder = "" { didSet { needsDisplay = true } }
    public var onFocusChange: (Bool) -> Void = { _ in }

    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    public override var acceptsFirstResponder: Bool { isEditable }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    public override func keyDown(with event: NSEvent) {
        if Self.isSubmit(event), !hasMarkedText() {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↵ com o editor em foco: quem trata é este editor, não um atalho do menu.
        if Self.isSubmit(event), window?.firstResponder === self, !hasMarkedText() {
            onSubmit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc: o chamador decide (fechar o overlay); sem tratador, segue a cadeia de responders.
    public override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) }
    }

    static func isSubmit(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, returnKeyCodes.contains(event.keyCode) else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? DS.Font.input.nsFont,
            .foregroundColor: DS.ColorSpec.textQuaternary.nsColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: attributes).draw(at: origin)
    }

    /// Altura do conteúdo com o padding vertical (base da altura automática).
    public var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height) + textContainerInset.height * 2
    }

    /// Cursor no fim, sem selecionar nada (o `TextField` do sistema seleciona tudo ao focar).
    public func placeCaretAtEnd() { setSelectedRange(NSRange(location: (string as NSString).length, length: 0)) }
}

/// Editor com altura automática: 88 pt no mínimo, cresce até 240 pt e depois rola (02 §12.10).
public struct PromptEditor: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let autofocus: Bool
    private let onSubmit: () -> Void
    private let onEscape: (() -> Void)?
    private let onFocusChange: (Bool) -> Void

    public init(
        text: Binding<String>, placeholder: String, minHeight: CGFloat = DSMetrics.textareaMinHeight,
        maxHeight: CGFloat = DSMetrics.promptMaxHeight, autofocus: Bool = false, onSubmit: @escaping () -> Void = {},
        onEscape: (() -> Void)? = nil, onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.autofocus = autofocus
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onFocusChange = onFocusChange
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var textView: PromptTextView?
        weak var scrollView: NSScrollView?
        var didAutofocus = false

        init(_ parent: PromptEditor) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? PromptTextView, parent.text != view.string else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            scrollView?.invalidateIntrinsicContentSize()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = PromptTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = DS.Font.inputCompact.nsFont
        view.textColor = DS.ColorSpec.textPrimary.nsColor
        view.insertionPointColor = DS.ColorSpec.textPrimary.nsColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: .zero, height: DS.Space.s2)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = .zero
        view.typingAttributes = [
            .font: DS.Font.inputCompact.nsFont, .foregroundColor: DS.ColorSpec.textPrimary.nsColor,
            .paragraphStyle: Self.paragraphStyle(),
        ]
        view.defaultParagraphStyle = Self.paragraphStyle()
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        context.coordinator.textView = view
        context.coordinator.scrollView = scroll
        return scroll
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = DS.Font.inputCompact.lineHeight - 1
        style.maximumLineHeight = DS.Font.inputCompact.lineHeight - 1
        return style
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PromptTextView else { return }
        view.placeholder = placeholder
        view.onSubmit = onSubmit
        view.onEscape = onEscape
        view.onFocusChange = onFocusChange
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.invalidateIntrinsicContentSize()
        }
        view.isEditable = context.environment.isEnabled
        if autofocus, !context.coordinator.didAutofocus {
            context.coordinator.didAutofocus = true
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                if window.makeFirstResponder(view) { view.placeCaretAtEnd() }
            }
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? PromptTextView else { return nil }
        let width = proposal.width ?? scroll.frame.width
        if width > 0, abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
        let content = view.contentHeight
        return CGSize(width: width, height: min(max(content, minHeight), maxHeight))
    }
}

/// Campo de prompt completo: `PromptEditor` na moldura de campo (02 §12.10), foco = borda `ring` + anel.
public struct DSPromptEditorField: View {
    @Binding private var text: String
    private let placeholder: String
    private let autofocus: Bool
    private let onSubmit: () -> Void
    private let onEscape: (() -> Void)?
    @State private var focused = false
    @Environment(\.isEnabled) private var isEnabled

    public init(
        text: Binding<String>, placeholder: String, autofocus: Bool = false, onSubmit: @escaping () -> Void = {},
        onEscape: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.autofocus = autofocus
        self.onSubmit = onSubmit
        self.onEscape = onEscape
    }

    public var body: some View {
        PromptEditor(
            text: $text, placeholder: placeholder, autofocus: autofocus, onSubmit: onSubmit, onEscape: onEscape,
            onFocusChange: { focused = $0 }
        )
        .dsFieldChrome(focused: focused, disabled: !isEnabled, height: nil)
    }
}
