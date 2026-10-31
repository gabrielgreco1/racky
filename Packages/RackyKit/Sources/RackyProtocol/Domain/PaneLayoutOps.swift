import CoreGraphics
import Foundation

/// Caminho até um split da árvore: `false` = primeiro ramo, `true` = segundo. A raiz é o caminho vazio.
public struct SplitPath: Hashable, Sendable, Codable {
    public var steps: [Bool]
    public init(_ steps: [Bool] = []) { self.steps = steps }
    public func appending(_ second: Bool) -> SplitPath { SplitPath(steps + [second]) }
}

/// Divisor de um split já posicionado: `rect` é a linha de 3 pt; `container` é o retângulo do split inteiro.
public struct DividerGeometry: Hashable, Sendable {
    public var path: SplitPath
    public var axis: SplitAxis
    public var rect: CGRect
    public var container: CGRect
    public var ratio: Double
    /// Folha mais à esquerda/acima do segundo ramo: identifica o divisor (`pane.divider.<id>`), único por split.
    public var secondLeadingPaneID: UUID
}

/// Posição de todos os panes e divisores para um retângulo (coordenadas do chamador; y cresce para baixo).
public struct PaneArrangement: Sendable, Equatable {
    public var panes: [UUID: CGRect]
    public var dividers: [DividerGeometry]
}

extension PaneLayout {
    /// Tamanho mínimo de um pane (03 §4.3): abaixo disso o split é recusado.
    public static let minPaneSize = CGSize(width: 240, height: 120)
    /// Divisor visível (DS §12.23).
    public static let dividerThickness: CGFloat = 3

    public var leafCount: Int { panes.count }

    /// `horizontal` = filhos lado a lado (Split Right: `first` à esquerda); `vertical` = empilhados (Split Down).
    public func arrangement(in rect: CGRect, dividerThickness: CGFloat = PaneLayout.dividerThickness) -> PaneArrangement {
        var result = PaneArrangement(panes: [:], dividers: [])
        place(in: rect, thickness: dividerThickness, path: SplitPath(), into: &result)
        return result
    }

    private func place(in rect: CGRect, thickness: CGFloat, path: SplitPath, into out: inout PaneArrangement) {
        switch self {
        case .leaf(let pane):
            out.panes[pane.id] = rect
        case .split(let axis, let ratio, let first, let second):
            let (a, line, b) = Self.cut(rect, axis: axis, ratio: ratio, thickness: thickness)
            out.dividers.append(
                DividerGeometry(path: path, axis: axis, rect: line, container: rect, ratio: ratio, secondLeadingPaneID: second.firstPane.id))
            first.place(in: a, thickness: thickness, path: path.appending(false), into: &out)
            second.place(in: b, thickness: thickness, path: path.appending(true), into: &out)
        }
    }

    /// Divide `rect` em dois ramos e a linha do divisor, em pontos inteiros (o terminal nunca recebe frações).
    static func cut(_ rect: CGRect, axis: SplitAxis, ratio: Double, thickness: CGFloat) -> (CGRect, CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let free = max(0, rect.width - thickness)
            let w = (free * ratio).rounded(.down)
            return (
                CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                CGRect(x: rect.minX + w, y: rect.minY, width: thickness, height: rect.height),
                CGRect(x: rect.minX + w + thickness, y: rect.minY, width: free - w, height: rect.height))
        case .vertical:
            let free = max(0, rect.height - thickness)
            let h = (free * ratio).rounded(.down)
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: thickness),
                CGRect(x: rect.minX, y: rect.minY + h + thickness, width: rect.width, height: free - h))
        }
    }

    public var firstPane: Pane {
        switch self {
        case .leaf(let p): p
        case .split(_, _, let a, _): a.firstPane
        }
    }

    public func pane(withID id: UUID) -> Pane? { panes.first { $0.id == id } }

    public func pane(forTerminal terminalID: UUID) -> Pane? {
        panes.first { if case .terminal(let t) = $0.content { t == terminalID } else { false } }
    }

    // MARK: Foco

    /// Próximo (`delta` > 0) ou anterior pane na ordem da árvore, com volta (⌘] / ⌘[). Nil com um só pane.
    public func pane(from id: UUID, delta: Int) -> Pane? {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        let n = all.count
        return all[((i + delta) % n + n) % n]
    }

    /// Quem recebe o foco quando `id` fecha: a folha mais próxima do irmão (a primeira do ramo que ocupa o espaço).
    public func focusSuccessor(afterRemoving id: UUID) -> Pane? {
        guard case .split(_, _, let a, let b) = self else { return nil }
        if case .leaf(let p) = a, p.id == id { return b.firstPane }
        if case .leaf(let p) = b, p.id == id { return a.lastPane }
        if a.contains(paneID: id) { return a.focusSuccessor(afterRemoving: id) ?? b.firstPane }
        if b.contains(paneID: id) { return b.focusSuccessor(afterRemoving: id) ?? a.lastPane }
        return nil
    }

    var lastPane: Pane {
        switch self {
        case .leaf(let p): p
        case .split(_, _, _, let b): b.lastPane
        }
    }

    // MARK: Proporções

    /// Peso de um ramo ao longo de `axis`: folhas em cadeia do mesmo eixo contam uma a uma; um split do outro eixo conta 1.
    private func weight(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf: 1
        case .split(let a, _, let first, let second):
            a == axis ? first.weight(along: axis) + second.weight(along: axis) : 1
        }
    }

    /// Divide o espaço igualmente entre todos os panes (Equalize Pane Sizes).
    public func equalized() -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let axis, _, let first, let second):
            let a = Double(first.weight(along: axis)), b = Double(second.weight(along: axis))
            return .split(axis: axis, ratio: a / (a + b), first: first.equalized(), second: second.equalized())
        }
    }

    /// Iguala só os dois lados de um split (duplo clique no divisor).
    public func equalizing(at path: SplitPath) -> PaneLayout {
        guard let node = split(at: path), case .split(let axis, _, let a, let b) = node else { return self }
        let wa = Double(a.weight(along: axis)), wb = Double(b.weight(along: axis))
        return settingRatio(at: path, ratio: wa / (wa + wb))
    }

    public func split(at path: SplitPath) -> PaneLayout? {
        var node = self
        for step in path.steps {
            guard case .split(_, _, let a, let b) = node else { return nil }
            node = step ? b : a
        }
        if case .split = node { return node }
        return nil
    }

    public func settingRatio(at path: SplitPath, ratio: Double) -> PaneLayout {
        let r = min(max(ratio, Self.minRatio), Self.maxRatio)
        return rewriting(path.steps[...]) { node in
            guard case .split(let axis, _, let a, let b) = node else { return node }
            return .split(axis: axis, ratio: r, first: a, second: b)
        }
    }

    private func rewriting(_ path: ArraySlice<Bool>, _ transform: (PaneLayout) -> PaneLayout) -> PaneLayout {
        guard let step = path.first else { return transform(self) }
        guard case .split(let axis, let ratio, let a, let b) = self else { return self }
        let rest = path.dropFirst()
        return step
            ? .split(axis: axis, ratio: ratio, first: a, second: b.rewriting(rest, transform))
            : .split(axis: axis, ratio: ratio, first: a.rewriting(rest, transform), second: b)
    }

    /// Extensão mínima que o ramo exige ao longo de `axis` (panes de 240 × 120 e divisores no meio).
    func minimumExtent(along axis: SplitAxis, thickness: CGFloat) -> CGFloat {
        switch self {
        case .leaf:
            return axis == .horizontal ? Self.minPaneSize.width : Self.minPaneSize.height
        case .split(let a, _, let first, let second):
            let f = first.minimumExtent(along: axis, thickness: thickness), s = second.minimumExtent(along: axis, thickness: thickness)
            return a == axis ? f + s + thickness : max(f, s)
        }
    }

    /// Limita a proporção proposta para o divisor em `path` de modo que os dois lados respeitem o mínimo.
    /// Se o retângulo não comporta os mínimos, só vale o intervalo estrutural de `minRatio...maxRatio`.
    public func clampedRatio(_ proposed: Double, at path: SplitPath, in rect: CGRect, dividerThickness: CGFloat = PaneLayout.dividerThickness) -> Double {
        let structural = min(max(proposed, Self.minRatio), Self.maxRatio)
        guard let node = split(at: path), case .split(let axis, _, let a, let b) = node,
              let geometry = arrangement(in: rect, dividerThickness: dividerThickness).dividers.first(where: { $0.path == path })
        else { return structural }
        let total = axis == .horizontal ? geometry.container.width : geometry.container.height
        let free = total - dividerThickness
        guard free > 0 else { return structural }
        let lower = a.minimumExtent(along: axis, thickness: dividerThickness) / free
        let upper = 1 - b.minimumExtent(along: axis, thickness: dividerThickness) / free
        guard lower <= upper else { return structural }
        return min(max(structural, max(lower, Self.minRatio)), min(upper, Self.maxRatio))
    }

    // MARK: Splits com tamanho mínimo

    /// `true` se `paneID` pode ser dividido no eixo dado sem que algum dos dois lados fique abaixo de 240 × 120.
    public func canSplit(paneID: UUID, axis: SplitAxis, in rect: CGRect, dividerThickness: CGFloat = PaneLayout.dividerThickness) -> Bool {
        guard let frame = arrangement(in: rect, dividerThickness: dividerThickness).panes[paneID] else { return false }
        switch axis {
        case .horizontal: return (frame.width - dividerThickness) / 2 >= Self.minPaneSize.width
        case .vertical: return (frame.height - dividerThickness) / 2 >= Self.minPaneSize.height
        }
    }

    /// Troca o conteúdo de uma folha (reiniciar um terminal mantém o pane e a posição).
    public func replacingContent(ofPane id: UUID, with content: PaneContent) -> PaneLayout {
        switch self {
        case .leaf(var p):
            if p.id == id { p.content = content }
            return .leaf(p)
        case .split(let axis, let r, let a, let b):
            return .split(axis: axis, ratio: r, first: a.replacingContent(ofPane: id, with: content), second: b.replacingContent(ofPane: id, with: content))
        }
    }

    /// Remove todos os panes exceto `id` (Close Other Panes).
    public func keeping(onlyPane id: UUID) -> PaneLayout? { pane(withID: id).map { .leaf($0) } }
}
