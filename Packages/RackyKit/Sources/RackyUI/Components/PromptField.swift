import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Campo de prompt multilinha (02 §12.10) ligado ao registro: edições passam por `action` (`set(<texto>)`), ⌘↵ dispara
/// `submitAction`. Não seleciona o texto ao focar; Esc segue para o overlay.
public struct DSPromptField: View {
    private let placeholder: String
    @Binding private var text: String
    private let id: A11yID
    private let action: ActionID?
    private let submitAction: ActionID?
    private let autofocus: Bool
    @Environment(\.actionRegistry) private var registry

    public init(
        _ placeholder: String, text: Binding<String>, id: A11yID, action: ActionID? = nil, submitAction: ActionID? = nil,
        autofocus: Bool = false
    ) {
        self.placeholder = placeholder
        self._text = text
        self.id = id
        self.action = action
        self.submitAction = submitAction
        self.autofocus = autofocus
    }

    public var body: some View {
        DSPromptEditorField(text: $text, placeholder: placeholder, autofocus: autofocus) {
            guard let submitAction, let registry else { return }
            Task { _ = try? await registry.perform(submitAction, .press) }
        }
        .onChange(of: text) { _, new in
            guard let action, let registry else { return }
            Task { _ = try? await registry.perform(action, .set(new)) }
        }
        .a11y(id, kind: "textarea", value: text, action: action)
    }
}
