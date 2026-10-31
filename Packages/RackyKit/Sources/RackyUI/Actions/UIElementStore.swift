import RackyProtocol
import Foundation
import SwiftUI

/// Controles montados na janela, registrados pelo modificador `.a11y(...)` (08 AR-805).
/// É a fonte da árvore de `ctl ui tree`: identificador, tipo, rótulo, valor, estado, ação e frame.
@MainActor
public final class UIElementStore {
    public struct Element: Equatable {
        public var id: A11yID
        public var kind: String
        public var label: String?
        public var value: String?
        public var action: ActionID?
        public var argument: ActionArgument?
        public var parent: A11yID?
        public var frame: CGRect?
        var order: Int
    }

    private var elements: [UUID: Element] = [:]
    /// Frames chegam antes do registro (`onGeometryChange` roda antes de `onAppear`): guardados à parte.
    private var frames: [UUID: CGRect] = [:]
    private var nextOrder = 0
    /// Resolvedor de estado habilitado/motivo por ação (ligado ao `ActionRegistry` no boot).
    public var enablement: (ActionID) -> ActionAvailability = { _ in .enabled }
    /// Janela do conteúdo (para tamanho e escala em `UIWindowInfo`).
    public weak var window: NSWindow?

    public init() {}

    func register(_ token: UUID, id: A11yID, kind: String, label: String?, value: String?, action: ActionID?, argument: ActionArgument? = nil, parent: A11yID?) {
        var el = elements[token] ?? Element(id: id, kind: kind, label: label, value: value, action: action, argument: argument, parent: parent, frame: frames[token], order: nextOrder)
        if elements[token] == nil { nextOrder += 1 }
        el.id = id
        el.kind = kind
        el.label = label
        el.value = value
        el.action = action
        el.argument = argument
        el.parent = parent
        elements[token] = el
    }

    func updateFrame(_ token: UUID, _ frame: CGRect) {
        frames[token] = frame
        elements[token]?.frame = frame
    }

    func unregister(_ token: UUID) {
        elements[token] = nil
        frames[token] = nil
    }

    /// IDs registrados duas vezes ao mesmo tempo (bug de tela: o ID deve ser único).
    public var duplicateIDs: [A11yID] {
        let counts = Dictionary(grouping: elements.values, by: \.id).filter { $0.value.count > 1 }
        return counts.keys.sorted()
    }

    public var allIDs: [A11yID] { elements.values.map(\.id).sorted() }
    public var count: Int { elements.count }

    // MARK: Árvore

    public func snapshot(root: A11yID? = nil) -> UITreeSnapshot {
        let sorted = elements.values.sorted { $0.order < $1.order }
        var byParent: [A11yID?: [Element]] = [:]
        let known = Set(sorted.map(\.id))
        for el in sorted {
            let parent = el.parent.flatMap { known.contains($0) ? $0 : nil }
            byParent[parent, default: []].append(el)
        }
        func build(_ el: Element, _ visited: Set<A11yID>) -> UITreeNode {
            let state = el.action.map(enablement) ?? .enabled
            var enabled = true
            var reason: String?
            if case .disabled(let r) = state {
                enabled = false
                reason = r
            }
            let kids = visited.contains(el.id) ? [] : (byParent[el.id] ?? []).map { build($0, visited.union([el.id])) }
            return UITreeNode(
                id: el.id, kind: el.kind, label: el.label, value: el.value, enabled: enabled, disabledReason: reason,
                action: el.action, argument: el.argument,
                frame: el.frame.map { UIFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
                children: kids)
        }
        let roots: [UITreeNode]
        if let root {
            roots = sorted.first { $0.id == root }.map { [build($0, [])] } ?? []
        } else {
            roots = (byParent[nil] ?? []).map { build($0, []) }
        }
        return UITreeSnapshot(window: windowInfo(), roots: roots)
    }

    func windowInfo() -> UIWindowInfo? {
        guard let w = window else { return nil }
        let size = w.contentView?.bounds.size ?? w.frame.size
        return UIWindowInfo(
            title: w.title, width: size.width, height: size.height, scale: w.backingScaleFactor, isKey: w.isKeyWindow)
    }

    /// O frame de um controle na janela. Pode haver mais de um registro com o mesmo id (uma view que ainda não saiu da árvore): vale
    /// o mais recente com um frame de verdade, não um qualquer (antes o "+" às vezes ancorava o menu no canto da janela).
    public func frame(of id: A11yID) -> CGRect? {
        elements.values.filter { $0.id == id && ($0.frame.map { !$0.isEmpty } ?? false) }.max { $0.order < $1.order }?.frame
    }
}

// MARK: Ambiente e modificador

extension EnvironmentValues {
    @Entry var elementStore: UIElementStore?
    @Entry var a11yParent: A11yID?
    @Entry public var actionRegistry: ActionRegistry?
}

private struct A11yProps: Equatable {
    var kind: String
    var label: String?
    var value: String?
    var action: ActionID?
    var argument: ActionArgument?
    var parent: A11yID?
}

private struct A11yModifier: ViewModifier {
    let id: A11yID
    let props: A11yProps
    @Environment(\.elementStore) private var store
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id.rawValue)
            .environment(\.a11yParent, id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                store?.updateFrame(token, frame)
            }
            .onAppear { sync() }
            .onChange(of: props) { sync() }
            .onDisappear { store?.unregister(token) }
    }

    private func sync() {
        store?.register(token, id: id, kind: props.kind, label: props.label, value: props.value, action: props.action, argument: props.argument, parent: props.parent)
    }
}

extension View {
    /// Dá identificador canônico (A11yID) ao controle e o registra na árvore de `ctl ui tree`.
    /// `action` liga o controle a uma ação do registro (estado habilitado e motivo vêm de lá).
    public func a11y(
        _ id: A11yID, kind: String = "container", label: String? = nil, value: String? = nil, action: ActionID? = nil,
        argument: ActionArgument? = nil
    ) -> some View {
        modifier(A11yParentReader(id: id, kind: kind, label: label, value: value, action: action, argument: argument))
    }
}

/// Lê o pai do ambiente antes de aplicar o modificador (o pai é o `A11yID` do ancestral mais próximo).
private struct A11yParentReader: ViewModifier {
    let id: A11yID
    let kind: String
    let label: String?
    let value: String?
    let action: ActionID?
    let argument: ActionArgument?
    @Environment(\.a11yParent) private var parent

    func body(content: Content) -> some View {
        content.modifier(
            A11yModifier(id: id, props: A11yProps(kind: kind, label: label, value: value, action: action, argument: argument, parent: parent)))
    }
}
