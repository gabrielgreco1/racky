import SwiftUI

/// Guarda os quadros dos elementos marcados com `layoutProbe(_:)`. Só existe nos testes de layout; em produção o ambiente
/// não tem sonda e o modificador não adiciona nada.
@MainActor
final class LayoutProbe {
    var frames: [String: CGRect] = [:]
}

enum LayoutProbeSpace { static let name = "layout.root" }

private struct LayoutProbeKey: EnvironmentKey { static let defaultValue: LayoutProbe? = nil }
private struct LayoutFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension EnvironmentValues {
    var layoutProbe: LayoutProbe? {
        get { self[LayoutProbeKey.self] }
        set { self[LayoutProbeKey.self] = newValue }
    }
}

private struct LayoutProbeModifier: ViewModifier {
    let id: String
    @Environment(\.layoutProbe) private var probe

    func body(content: Content) -> some View {
        if probe != nil {
            content.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: LayoutFramesKey.self, value: [id: proxy.frame(in: .named(LayoutProbeSpace.name))])
                }
            }
        } else {
            content
        }
    }
}

private struct LayoutProbeRoot: ViewModifier {
    @Environment(\.layoutProbe) private var probe

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: LayoutProbeSpace.name)
            .onPreferenceChange(LayoutFramesKey.self) { frames in
                MainActor.assumeIsolated { probe?.frames = frames }
            }
    }
}

extension View {
    /// Marca o elemento para o teste de contenção (no-op em produção).
    func layoutProbe(_ id: String) -> some View { modifier(LayoutProbeModifier(id: id)) }
    func layoutProbeRoot() -> some View { modifier(LayoutProbeRoot()) }
}
