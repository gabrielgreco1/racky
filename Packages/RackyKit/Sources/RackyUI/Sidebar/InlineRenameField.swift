import RackyDesignSystem
import AppKit
import SwiftUI

/// Campo de renomear inline (03 §2.11, DS §12.10 `inlineRename`): tudo selecionado ao abrir, ↵ confirma, Esc cancela,
/// perder o foco confirma, ↵ durante composição IME é ignorado (o `NSTextView` só chama `insertNewline:` fora da composição).
struct InlineRenameField: NSViewRepresentable {
    let initialText: String
    let font: NSFont
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialText)
        field.delegate = context.coordinator
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = DS.ColorSpec.textPrimary.nsColor
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        Task { @MainActor in
            await Task.yield()
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var finished = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true, text: textView.string)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false, text: textView.string)
                return true
            }
            return false
        }

        /// Perder o foco confirma.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            finish(commit: true, text: field.stringValue)
        }

        private func finish(commit: Bool, text: String) {
            guard !finished else { return }
            finished = true
            if commit { onCommit(text) } else { onCancel() }
        }
    }
}
