import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// Barra de filtro no jeito do Datadog: "+ Filter" escolhe a coluna, o operador e o valor (com os valores mais comuns e a faixa dos
// números à mão); cada filtro vira uma pílula dentro do campo, com o x para tirar; o resto do texto é busca livre. Digitar
// `price:>20` e espaço também vira pílula. Backspace no campo vazio tira a última. Os filtros das facetas aparecem como pílulas
// também, numa cor mais neutra.

enum FilterBarMetrics {
    static let height = DS.Space.s8 + DS.Space.s1
    static let pillHeight = DS.Space.s6
    static let popoverWidth: CGFloat = 320
    static let suggestionRow = DS.Space.s6 + DS.Space.s1
    static let histogramHeight = DS.Space.s8
    static let listHeight = suggestionRow * 8
}

struct DatasetFilterBar: View {
    let snapshot: DatasetPageSnapshot
    let controller: DatasetsController
    @Bindable var model: DatasetViewModel
    /// À direita do campo (o período, quando o gráfico está em outra aba).
    var trailing: AnyView? = nil
    @FocusState private var focused: Bool
    @State private var addAnchor: CGRect = .zero
    @Environment(\.actionRegistry) private var registry
    @Environment(\.overlayRouter) private var router

    private var columns: [DatasetColumn] { snapshot.summary.dataset.columns }

    /// O texto já fechado por espaço vira pílulas; o pedaço sendo digitado continua no campo.
    private var parts: (pills: [DatasetSearchText.Pill], free: String) {
        let text = model.search
        // Sem foco, nada está sendo digitado: tudo que é filtro vira pílula.
        guard focused else { return DatasetSearchText.split(text, columns: columns) }
        guard let cut = Self.lastBoundary(text) else { return ([], text) }
        let committed = String(text[..<cut])
        let tail = String(text[cut...]).trimmingCharacters(in: .whitespaces)
        let split = DatasetSearchText.split(committed, columns: columns)
        let free = [split.free, tail].filter { !$0.isEmpty }.joined(separator: " ")
        return (split.pills, free + (text.hasSuffix(" ") && !free.isEmpty ? " " : ""))
    }

    /// Último espaço fora de aspas (o que vem depois ainda está sendo digitado).
    static func lastBoundary(_ text: String) -> String.Index? {
        var quoted = false
        var last: String.Index?
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == " ", !quoted { last = text.index(after: index) }
        }
        return last
    }

    var body: some View {
        let parts = parts
        HStack(spacing: DS.Space.s1_5) {
            addButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s1) {
                    ForEach(Array(facetPills.enumerated()), id: \.element.id) { _, pill in facetPill(pill) }
                    ForEach(Array(parts.pills.enumerated()), id: \.offset) { index, pill in columnPill(pill, index: index) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            field(free: parts.free, pills: parts.pills)
            if !model.search.isEmpty || !facetPills.isEmpty {
                // lint-ui: allow buttons limpa tudo: busca (`dataset.search`) e facetas (`dataset.facetsReset`)
                Button {
                    setSearch("")
                    perform(.datasetFacetsReset, .press)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dsTooltip(String(localized: "Clear all filters", bundle: .module), shortcut: nil)
                .a11y(.datasetSearchClear, kind: "button", label: String(localized: "Clear all filters", bundle: .module))
            }
        }
        .padding(.leading, DS.Space.s1)
        .padding(.trailing, DS.Space.s2_5)
        .frame(height: FilterBarMetrics.height)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.chrome))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(focused ? DS.Color.textTertiary : DS.Color.borderStrong, lineWidth: ComputersMetrics.separator))
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: focused)
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: parts.pills.count + facetPills.count)
        .overlay(alignment: .trailing) { EmptyView() }
        .modifier(TrailingAccessory(view: trailing))
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2_5)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    // MARK: Campo

    private func field(free: String, pills: [DatasetSearchText.Pill]) -> some View {
        ZStack(alignment: .leading) {
            if free.isEmpty {
                Text(verbatim: pills.isEmpty && facetPills.isEmpty ? placeholder : String(localized: "Search…", bundle: .module))
                    .dsFont(DS.Font.inputCompact).foregroundStyle(DS.Color.textQuaternary).lineLimit(1)
                    .allowsHitTesting(false)
            }
            TextField("", text: Binding(get: { free }, set: { setSearch((pills.map(\.raw) + [$0]).filter { !$0.isEmpty }.joined(separator: " ")) }))
                .textFieldStyle(.plain)
                .dsFont(DS.Font.inputCompact)
                .foregroundStyle(DS.Color.textPrimary)
                .focused($focused)
                .onKeyPress(.delete) {
                    // Campo vazio: o backspace tira a última pílula.
                    guard free.isEmpty, !pills.isEmpty else { return .ignored }
                    perform(.datasetRemoveFilter, .select("\(pills.count - 1)"))
                    return .handled
                }
                .a11y(.datasetSearch, kind: "textfield", value: model.search, action: .datasetSearch)
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: String {
        let numeric = columns.first { DatasetMetrics.isNumeric($0.type) }
        let text = columns.first { $0.type == .string }
        var example: [String] = []
        if let numeric { example.append("\(numeric.name):>10") }
        if let text { example.append("\(text.name):love") }
        guard !example.isEmpty else { return String(localized: "Search rows", bundle: .module) }
        return String(localized: "Search rows, or type \(example.joined(separator: " "))", bundle: .module)
    }

    private func setSearch(_ text: String) {
        model.search = text
        perform(.datasetSearch, .set(text))
    }

    private func perform(_ action: ActionID, _ argument: ActionArgument) {
        guard let registry else { return }
        Task { _ = try? await registry.perform(action, argument) }
    }

    // MARK: Pílulas

    private func columnPill(_ pill: DatasetSearchText.Pill, index: Int) -> some View {
        let column = columns.first { $0.name == pill.column }
        return HStack(spacing: DS.Space.s1) {
            Text(verbatim: pill.column).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            Text(verbatim: Self.symbol(pill.comparison, type: column?.type ?? .string)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.dataKey)
            Text(verbatim: pill.value).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            ActionButton(.datasetRemoveFilter, id: .datasetPillRemove("\(index)"), argument: .select("\(index)"), tooltip: String(localized: "Remove filter", bundle: .module)) {
                Image(systemName: "xmark").font(.system(size: DS.Space.s2, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                    .frame(width: DS.Space.s4, height: DS.Space.s4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, DS.Space.s2)
        .padding(.trailing, DS.Space.s0_5)
        .frame(height: FilterBarMetrics.pillHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.dataKey.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.dataKey.opacity(0.3)))
        .a11y(.datasetPill("\(index)"), kind: "group", label: pill.raw)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    struct FacetPill: Identifiable {
        var id: String
        var title: String
        var value: String
        var clear: String
    }

    /// Filtros das facetas da esquerda (status, computador, site, evidência, erro).
    private var facetPills: [FacetPill] {
        var out: [FacetPill] = []
        for facet in DatasetFacet.allCases where facet != .error {
            guard let excluded = model.excluded[facet], !excluded.isEmpty else { continue }
            let all = (snapshot.facets[facet] ?? []).map(\.value)
            let kept = all.filter { !excluded.contains($0) }
            let label = { (value: String) in FacetsPanel.label(facet, value, controller: controller) }
            let value = kept.count == 1 && all.count > 2
                ? label(kept[0])
                : String(localized: "not \(excluded.sorted().map(label).joined(separator: ", "))", bundle: .module)
            out.append(FacetPill(id: facet.rawValue, title: FacetsPanel.title(facet), value: value, clear: "\(facet.rawValue):*"))
        }
        if !model.errorKinds.isEmpty {
            out.append(FacetPill(id: "error", title: FacetsPanel.title(.error), value: model.errorKinds.sorted().joined(separator: ", "), clear: "error:*"))
        }
        return out
    }

    private func facetPill(_ pill: FacetPill) -> some View {
        HStack(spacing: DS.Space.s1) {
            Text(verbatim: pill.title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: pill.value).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            ActionButton(.datasetFacet, id: .datasetChipClear(pill.id), argument: .select(pill.clear), tooltip: String(localized: "Remove filter", bundle: .module)) {
                Image(systemName: "xmark").font(.system(size: DS.Space.s2, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                    .frame(width: DS.Space.s4, height: DS.Space.s4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, DS.Space.s2)
        .padding(.trailing, DS.Space.s0_5)
        .frame(height: FilterBarMetrics.pillHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.border))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// `>` → `>`, `~` → `contains`, `=` em texto → `is`.
    static func symbol(_ comparison: DatasetComparison, type: DatasetColumnType) -> String {
        switch comparison {
        case .contains: String(localized: "contains", bundle: .module)
        case .equals: DatasetMetrics.isNumeric(type) ? "=" : String(localized: "is", bundle: .module)
        case .notEquals: DatasetMetrics.isNumeric(type) ? "≠" : String(localized: "is not", bundle: .module)
        case .greater: ">"
        case .greaterOrEqual: "≥"
        case .less: "<"
        case .lessOrEqual: "≤"
        }
    }

    // MARK: + Filter

    private var addButton: some View {
        // lint-ui: allow buttons abre o popover de montar o filtro; o filtro em si entra pela ação `dataset.addFilter`
        Button { openAdd() } label: {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "plus").font(.system(size: DS.Space.s2_5, weight: .semibold))
                Text("Filter", bundle: .module).dsFont(DS.Font.label)
            }
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: FilterBarMetrics.pillHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { addAnchor = $0 }
        .fixedSize()
        .a11y(.datasetFilterAdd, kind: "button", label: String(localized: "Add filter", bundle: .module))
    }

    private func openAdd() {
        guard let router else { return }
        let snapshot = snapshot
        let registry = registry
        router.presentPopover(PopoverSpec(
            name: "datasetFilter", id: .menuPanel("datasetFilter"), anchor: addAnchor, width: FilterBarMetrics.popoverWidth
        ) { dismiss in
            AnyView(AddFilterPopover(snapshot: snapshot, registry: registry, dismiss: dismiss))
        })
    }
}

/// O popover do "+ Filter": primeiro a coluna (com busca), depois operador e valor, com sugestões tiradas dos dados.
private struct AddFilterPopover: View {
    let snapshot: DatasetPageSnapshot
    let registry: ActionRegistry?
    let dismiss: @MainActor () -> Void
    @State private var query = ""
    @State private var column: DatasetColumn?
    @State private var comparison: DatasetComparison = .contains
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let column { editor(column) } else { picker }
        }
        .frame(width: FilterBarMetrics.popoverWidth)
        .background(RoundedRectangle(cornerRadius: DS.Radius.menu).fill(DS.Color.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.menu).strokeBorder(DS.Color.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.menu))
        .onAppear { focused = true }
    }

    // MARK: Coluna

    private var picker: some View {
        let list = snapshot.summary.dataset.columns.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "magnifyingglass").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                TextField("", text: $query, prompt: Text("Filter by column…", bundle: .module))
                    .textFieldStyle(.plain).dsFont(DS.Font.inputCompact).focused($focused)
                    .onSubmit { if let first = list.first { choose(first) } }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: FilterBarMetrics.suggestionRow + DS.Space.s1)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list, id: \.name) { column in
                        PopoverRow {
                            choose(column)
                        } label: {
                            Image(systemName: Self.icon(column.type)).font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                                .frame(width: DS.Space.s4)
                            Text(verbatim: column.name).dsFont(DS.Font.menuItem).foregroundStyle(DS.Color.textPrimary)
                            Spacer(minLength: DS.Space.s2)
                            Text(verbatim: DatasetMetrics.typeLabel(column.type)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }
                .padding(DS.Space.s1)
            }
            .frame(maxHeight: FilterBarMetrics.listHeight)
        }
    }

    private func choose(_ column: DatasetColumn) {
        self.column = column
        comparison = DatasetMetrics.isNumeric(column.type) ? .greater : (snapshot.profiles[column.name]?.topValues.isEmpty == false ? .equals : .contains)
        value = ""
        focused = true
    }

    static func icon(_ type: DatasetColumnType) -> String {
        switch type {
        case .integer, .number: "number"
        case .boolean: "checkmark.square"
        case .date, .datetime: "calendar"
        case .url: "link"
        case .json: "curlybraces"
        case .string: "textformat"
        }
    }

    // MARK: Operador e valor

    private func comparisons(_ type: DatasetColumnType) -> [DatasetComparison] {
        DatasetMetrics.isNumeric(type) ? [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual] : [.contains, .equals, .notEquals]
    }

    private func editor(_ column: DatasetColumn) -> some View {
        let profile = snapshot.profiles[column.name]
        return VStack(alignment: .leading, spacing: DS.Space.s2_5) {
            HStack(spacing: DS.Space.s1_5) {
                // lint-ui: allow buttons volta para a lista de colunas (estado do popover)
                Button { self.column = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: DS.Space.s2_5, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                        .frame(width: DS.Space.s6, height: DS.Space.s6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(verbatim: column.name).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: DatasetMetrics.typeLabel(column.type)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: 0)
                if let profile { Text(verbatim: String(localized: "\(profile.distinct.formatted()) distinct", bundle: .module)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
            }
            // Operadores.
            HStack(spacing: DS.Space.s1) {
                ForEach(comparisons(column.type), id: \.self) { op in
                    // lint-ui: allow buttons escolhe o operador (estado do popover)
                    Button { comparison = op } label: {
                        Text(verbatim: DatasetFilterBar.symbol(op, type: column.type)).dsFont(DS.Font.small)
                            .foregroundStyle(comparison == op ? DS.Color.textPrimary : DS.Color.textSecondary)
                            .padding(.horizontal, DS.Space.s2)
                            .frame(height: FilterBarMetrics.pillHeight)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(comparison == op ? DS.Color.secondary : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(comparison == op ? DS.Color.borderStrong : DS.Color.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Valor.
            HStack(spacing: DS.Space.s2) {
                TextField("", text: $value, prompt: Text(verbatim: valueHint(column, profile)))
                    .textFieldStyle(.plain).dsFont(DS.Font.inputCompact).focused($focused)
                    .padding(.horizontal, DS.Space.s2_5)
                    .frame(height: FilterBarMetrics.suggestionRow)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.chrome))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.borderStrong))
                    .onSubmit { apply(column) }
                // lint-ui: allow buttons aplica o filtro montado (dispara `dataset.addFilter`)
                Button { apply(column) } label: {
                    Text("Apply", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textOnPrimary)
                        .padding(.horizontal, DS.Space.s3)
                        .frame(height: FilterBarMetrics.suggestionRow)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.primary.opacity(value.isEmpty ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(value.isEmpty)
            }
            if let profile, !profile.histogram.isEmpty, let min = profile.min, let max = profile.max {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    MiniBars(values: profile.histogram).frame(height: FilterBarMetrics.histogramHeight)
                    HStack {
                        Text(verbatim: Self.number(min)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                        Spacer(minLength: 0)
                        Text(verbatim: Self.number(max)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
            if let profile, !profile.topValues.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Most common", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        .padding(.bottom, DS.Space.s1)
                    ForEach(profile.topValues, id: \.value) { top in
                        PopoverRow {
                            value = top.value
                            apply(column)
                        } label: {
                            Text(verbatim: top.value.isEmpty ? "–" : top.value).dsFont(DS.Font.menuItem).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            Spacer(minLength: DS.Space.s2)
                            Text(verbatim: top.count.formatted()).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.s3)
    }

    private func valueHint(_ column: DatasetColumn, _ profile: DatasetColumnProfile?) -> String {
        if let min = profile?.min, let max = profile?.max { return String(localized: "Between \(Self.number(min)) and \(Self.number(max))", bundle: .module) }
        return String(localized: "Value", bundle: .module)
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? Int(value).formatted() : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func apply(_ column: DatasetColumn) {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let registry else { return }
        let argument = "\(column.name)|\(comparison.rawValue)|\(text)"
        Task { _ = try? await registry.perform(.datasetAddFilter, .select(argument)) }
        dismiss()
    }
}

/// Linha clicável do popover com hover.
private struct PopoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        // lint-ui: allow buttons linha do popover de filtro (escolha local; o filtro entra pela ação do registro)
        Button(action: action) {
            HStack(spacing: DS.Space.s2) { label() }
                .padding(.horizontal, DS.Space.s2)
                .frame(height: FilterBarMetrics.suggestionRow)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(hovering ? DS.Color.hoverRow : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Facetas por coluna

/// Na coluna da esquerda, embaixo das facetas fixas: cada coluna com poucos valores mostra os mais comuns (clicar filtra por ele);
/// cada coluna numérica mostra o histograma com mínimo e máximo editáveis (Enter aplica a faixa).
struct ColumnFacets: View {
    let snapshot: DatasetPageSnapshot
    let model: DatasetViewModel
    @State private var collapsed: Set<String> = []

    private var pills: [DatasetSearchText.Pill] { DatasetSearchText.split(model.search, columns: snapshot.summary.dataset.columns).pills }

    var body: some View {
        let columns = snapshot.summary.dataset.columns.filter { column in
            guard let profile = snapshot.profiles[column.name] else { return false }
            // URLs quase nunca se repetem: lista de valores seria ruído.
            return (!profile.topValues.isEmpty && column.type != .url) || !profile.histogram.isEmpty
        }
        if !columns.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("Columns", bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, DS.Space.s2)
                    .padding(.top, DS.Space.s2)
                ForEach(columns, id: \.name) { column in group(column) }
            }
        }
    }

    private func group(_ column: DatasetColumn) -> some View {
        let open = !collapsed.contains(column.name)
        let profile = snapshot.profiles[column.name]
        let active = pills.contains { $0.column == column.name }
        return VStack(alignment: .leading, spacing: 0) {
            // lint-ui: allow buttons recolhe o grupo (estado local da coluna)
            Button {
                withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.disclosure)) {
                    if open { collapsed.insert(column.name) } else { collapsed.remove(column.name) }
                }
            } label: {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "chevron.right").font(.system(size: DS.Space.s2, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(DS.Color.textTertiary)
                    Text(verbatim: column.name).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                    Text(verbatim: DatasetMetrics.typeLabel(column.type)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textQuaternary)
                    Spacer(minLength: 0)
                    if active { Circle().fill(DS.Color.dataKey).frame(width: DatasetMetrics.facetDot, height: DatasetMetrics.facetDot) }
                }
                .padding(.horizontal, DS.Space.s2)
                .frame(height: InsightMetrics.facetHeader)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11y(.datasetColumn(column.name), kind: "group", label: column.name)
            if open, let profile {
                if !profile.histogram.isEmpty {
                    RangeFacet(column: column, profile: profile, pills: pills.filter { $0.column == column.name })
                        .padding(.horizontal, DS.Space.s2)
                        .padding(.bottom, DS.Space.s2)
                } else {
                    ForEach(profile.topValues, id: \.value) { top in valueRow(column, top, total: max(profile.filled, 1)) }
                }
            }
        }
    }

    private func valueRow(_ column: DatasetColumn, _ top: DatasetValueCount, total: Int) -> some View {
        let index = pills.firstIndex { $0.column == column.name && $0.comparison == .equals && $0.value == top.value }
        let on = index != nil
        let action: ActionID = on ? .datasetRemoveFilter : .datasetAddFilter
        let argument: ActionArgument = on ? .select("\(index ?? 0)") : .select("\(column.name)|=|\(top.value)")
        return ActionButton(action, id: .datasetColumnValue(column.name, top.value), argument: argument) {
            HStack(spacing: DS.Space.s2) {
                CheckSquare(on: on, tint: DS.Color.dataKey)
                Text(verbatim: top.value.isEmpty ? "–" : top.value).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: (Double(top.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                    .dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(height: DatasetMetrics.facetRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Histograma de uma coluna numérica com o mínimo e o máximo do filtro; a faixa filtrada fica destacada.
private struct RangeFacet: View {
    let column: DatasetColumn
    let profile: DatasetColumnProfile
    let pills: [DatasetSearchText.Pill]
    @State private var low = ""
    @State private var high = ""
    @Environment(\.actionRegistry) private var registry

    private var bounds: (low: Double?, high: Double?) {
        var low: Double?
        var high: Double?
        for pill in pills {
            guard let value = Double(pill.value) else { continue }
            switch pill.comparison {
            case .greater, .greaterOrEqual: low = value
            case .less, .lessOrEqual: high = value
            case .equals: low = value; high = value
            default: break
            }
        }
        return (low, high)
    }

    var body: some View {
        let min = profile.min ?? 0
        let max = profile.max ?? 0
        let span = Swift.max(max - min, 1e-9)
        let bins = profile.histogram.count
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            GeometryReader { geo in
                let peak = CGFloat(Swift.max(profile.histogram.max() ?? 0, 1))
                let gap = OverviewMetrics.barGap / 2
                let width = Swift.max((geo.size.width - gap * CGFloat(bins - 1)) / CGFloat(bins), 1)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(profile.histogram.enumerated()), id: \.offset) { index, count in
                        let start = min + span * Double(index) / Double(bins)
                        let end = min + span * Double(index + 1) / Double(bins)
                        let inside = (bounds.low.map { end > $0 } ?? true) && (bounds.high.map { start <= $0 } ?? true)
                        let height = count == 0 ? ComputersMetrics.separator : Swift.max(geo.size.height * CGFloat(count) / peak, OverviewMetrics.barGap)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(inside ? DS.Color.dataKey.opacity(0.8) : DS.Color.textQuaternary.opacity(0.5))
                            .frame(width: width, height: height)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: FilterBarMetrics.histogramHeight)
            HStack(spacing: DS.Space.s1_5) {
                bound($low, placeholder: AddFilterPopoverNumber.text(min))
                Text(verbatim: "–").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                bound($high, placeholder: AddFilterPopoverNumber.text(max))
            }
        }
        .onAppear(perform: sync)
        .onChange(of: pills.map(\.raw)) { _, _ in sync() }
        .a11y(.datasetColumnRange(column.name), kind: "group", label: column.name)
    }

    private func sync() {
        low = bounds.low.map(AddFilterPopoverNumber.text) ?? ""
        high = bounds.high.map(AddFilterPopoverNumber.text) ?? ""
    }

    private func bound(_ text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(verbatim: placeholder))
            .textFieldStyle(.plain)
            .dsFont(DS.Font.monoCell)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.s1_5)
            .frame(height: DS.Space.s6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.canvas))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.borderStrong))
            .onSubmit(apply)
    }

    private func apply() {
        guard let registry else { return }
        let argument = "\(column.name)|\(low.trimmingCharacters(in: .whitespaces))|\(high.trimmingCharacters(in: .whitespaces))"
        Task { _ = try? await registry.perform(.datasetColumnRange, .select(argument)) }
    }
}

enum AddFilterPopoverNumber {
    static func text(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Coloca uma view ao lado direito do campo (mesma linha).
private struct TrailingAccessory: ViewModifier {
    let view: AnyView?

    func body(content: Content) -> some View {
        if let view {
            HStack(spacing: DS.Space.s2) {
                content
                view
            }
        } else {
            content
        }
    }
}
