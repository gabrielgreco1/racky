import RackyDesignSystem
import RackyProtocol
import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// Estado da busca do pane (03 §4.4): usa a busca pública do SwiftTerm (`findNext`, `findPrevious`,
/// `searchMatchSummary`, `clearSearch`), nunca a find bar embutida (`TerminalFindBarView`).
@MainActor
@Observable
public final class TerminalFindModel {
    public var isOpen = false
    public var query = "" { didSet { if query != oldValue { queryChanged() } } }
    public var caseSensitive = false { didSet { if caseSensitive != oldValue { queryChanged() } } }
    public var regex = false { didSet { if regex != oldValue { queryChanged() } } }
    /// Posição do resultado atual (1 a N; 0 sem resultado atual) e total.
    public private(set) var index = 0
    public private(set) var total = 0
    /// Incrementa quando a barra abre, para o campo tomar o foco.
    public private(set) var focusRequest = 0
    public var onClose: (() -> Void)?

    @ObservationIgnored weak var surface: TerminalSurfaceView?

    public init() {}

    var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive, regex: regex) }

    public var hasNoResults: Bool { !query.isEmpty && total == 0 }

    public func open() {
        isOpen = true
        focusRequest += 1
        // Seleção atual vira o termo (como em terminais nativos) quando houver.
        if let selected = surface?.getSelection(), !selected.isEmpty, !selected.contains("\n"), selected.count < 200 {
            query = selected
        } else if !query.isEmpty {
            refresh(searchFromStart: false)
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        surface?.clearSearch()
        index = 0
        total = 0
        onClose?()
    }

    @discardableResult
    public func next() -> Bool {
        guard let surface, !query.isEmpty else { return false }
        let found = surface.findNext(query, options: options)
        updateSummary()
        return found
    }

    @discardableResult
    public func previous() -> Bool {
        guard let surface, !query.isEmpty else { return false }
        let found = surface.findPrevious(query, options: options)
        updateSummary()
        return found
    }

    public func toggleCaseSensitive() { caseSensitive.toggle() }
    public func toggleRegex() { regex.toggle() }

    private func queryChanged() {
        guard isOpen else { return }
        refresh(searchFromStart: true)
    }

    private func refresh(searchFromStart: Bool) {
        guard let surface else { return }
        if searchFromStart { surface.clearSearch() }
        guard !query.isEmpty else {
            index = 0
            total = 0
            return
        }
        surface.findNext(query, options: options)
        updateSummary()
    }

    private func updateSummary() {
        guard let surface, !query.isEmpty else { return }
        let summary = surface.searchMatchSummary(query, options: options)
        index = summary.index
        total = summary.total
    }
}

/// Barra flutuante do canto superior direito do pane (03 §4.4): 340 x 32, `chrome`, borda `borderStrong`, raio 8.
struct TerminalFindBar: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 32

    @Bindable var model: TerminalFindModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            TextField(text: $model.query, prompt: Text("Find in terminal…", bundle: .module)) { EmptyView() }
                .textFieldStyle(.plain)
                .font(DS.Font.small.font)
                .foregroundStyle(DS.Color.textPrimary)
                .focused($fieldFocused)
                .onSubmit { _ = EventModifiers.held(.shift) ? model.previous() : model.next() }
                .onKeyPress(.escape) {
                    model.close()
                    return .handled
                }
                .a11y(.findField, kind: "textField", label: "Search", value: model.query)
            Text(countText)
                .font(DS.Font.microNumeric.font)
                .foregroundStyle(model.hasNoResults ? DS.Color.destructive : DS.Color.textSecondary)
                .a11y(.findCount, kind: "text", value: countText)
            ActionButton(.findCaseSensitive, id: .findCaseSensitive) {
                Text(verbatim: "Aa").font(DS.Font.small.font)
                    .foregroundStyle(model.caseSensitive ? DS.Color.textPrimary : DS.Color.textSecondary)
            }
            ActionButton(.findRegex, id: .findRegex) {
                Text(verbatim: ".*").font(DS.Font.small.font)
                    .foregroundStyle(model.regex ? DS.Color.textPrimary : DS.Color.textSecondary)
            }
            ActionButton(.findPrevious, id: .findPrevious) {
                Image(systemName: "chevron.up").foregroundStyle(DS.Color.textSecondary)
            }
            ActionButton(.findNext, id: .findNext) {
                Image(systemName: "chevron.down").foregroundStyle(DS.Color.textSecondary)
            }
            ActionButton(.findClose, id: .findClose) {
                Image(systemName: "xmark").foregroundStyle(DS.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.s2)
        .frame(width: Self.width, height: Self.height)
        .background(DS.Color.chrome)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Color.borderStrong, lineWidth: 1))
        .onChange(of: model.focusRequest, initial: true) { fieldFocused = true }
    }

    private var countText: String {
        if model.query.isEmpty { return "" }
        if model.total == 0 { return String(localized: "No results", bundle: .module) }
        return "\(model.index)/\(model.total)"
    }
}
