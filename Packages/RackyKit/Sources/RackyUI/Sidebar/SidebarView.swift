import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Sidebar completa estruturalmente (03 §2): search, nav, seções Projects e Sessions, rodapé. Rolagem em
/// `ScrollView` + `LazyVStack` (sem `List`, 09 T1-13). Controles de fatias futuras e de ações sem dono não renderizam.
struct SidebarView: View {
    let model: SidebarModel
    @Environment(\.actionRegistry) private var registry
    @FocusState private var listFocused: Bool
    @Namespace private var selection
    @State private var glowing: UUID?

    var body: some View {
        let projection = model.projection
        VStack(spacing: 0) {
            Color.clear.frame(height: DS.Layout.titlebarHeight)
            topBlock
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        content(projection)
                    }
                    .padding(.horizontal, SidebarMetrics.paddingH)
                    .padding(.bottom, DS.Space.s2)
                }
                .scrollIndicators(.automatic)
                .background(OverlayScrollerConfigurator())
                .onChange(of: model.keyboardFocus) { _, item in
                    guard let item else { return }
                    proxy.scrollTo(item)
                }
                .onChange(of: model.reveal?.nonce) { _, _ in reveal(proxy) }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.sidebar)
        .ignoresSafeArea()
        // O foco de teclado da lista vive numa vista invisível à parte: se o contêiner fosse focável, todos os botões
        // filhos herdariam `isFocused` e desenhariam o anel.
        .background {
            Color.clear
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { handle($0, projection) }
        }
        .onChange(of: model.focusListRequest) { _, _ in listFocused = true }
        .onChange(of: listFocused) { _, focused in if !focused { model.keyboardFocus = nil } }
        .a11y(.sidebar, kind: "container")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sessions", bundle: .module))
    }

    // MARK: Topo: search e itens de nav (03 §2.2, §2.3)

    private var topBlock: some View {
        VStack(spacing: SidebarMetrics.navGap) {
            if let registry, registry.isRendered(.sidebarSearch) {
                SidebarSearchField(model: model)
            }
            // "Sessions" no lugar do Inbox: leva às sessões; o número diz quantas coisas pedem você (estão no topo da lista).
            NavItemRow(
                action: .pageSessions, id: .sidebarNavSessions, title: String(localized: "Sessions", bundle: .module), symbol: "rectangle.stack",
                hideKey: "inbox", badge: (model.attention?.center.badgeCount ?? 0) + (model.helpInbox?.attentionCount ?? 0))
            NavItemRow(action: .pageComputers, id: .sidebarNavComputers, title: String(localized: "Computers", bundle: .module), symbol: "display", hideKey: "computers")
            NavItemRow(action: .pageDatasets, id: .sidebarNavDatasets, title: String(localized: "Data", bundle: .module), symbol: "cylinder.split.1x2", hideKey: "datasets")
            NavItemRow(action: .pageLibrary, id: .sidebarNavLibrary, title: String(localized: "Library", bundle: .module), symbol: "books.vertical", hideKey: "library")
        }
        .padding(.horizontal, SidebarMetrics.paddingH)
        .padding(.top, SidebarMetrics.paddingTop)
        .padding(.bottom, SidebarMetrics.paddingBottom)
    }

    // MARK: Corpo

    @ViewBuilder private func content(_ projection: SidebarProjection) -> some View {
        if model.inboxOpen {
            InboxView(model: model)
        } else {
            sessionsContent(projection)
        }
    }

    @ViewBuilder private func sessionsContent(_ projection: SidebarProjection) -> some View {
        switch projection.empty {
        case .workspace:
            emptyWorkspace(archived: projection.archivedHidden)
        default:
            needsYou
            Section {
                if projection.empty == .searchNoResults {
                    searchEmpty
                } else if projection.empty == .filtersNoResults {
                    filtersEmpty
                }
                ForEach(projection.projects) { project in
                    projectBlock(project)
                }
            } header: {
                projectsHeader
            }
            if projection.showSessionsSection {
                Section {
                    ForEach(projection.cleanPending) { row in
                        PendingRowView(model: model, data: row).id(SidebarItemID.pending(row.id)).padding(.bottom, SidebarMetrics.cardSpacing)
                    }
                    ForEach(projection.cleanSessions) { card in
                        cardView(card).id(SidebarItemID.session(card.id)).padding(.bottom, SidebarMetrics.cardSpacing)
                    }
                } header: {
                    sessionsHeader
                }
            }
        }
    }

    /// Pedidos que esperam você (aprovar um computer, ajudar um agente): no topo da lista, só quando existem.
    @ViewBuilder private var needsYou: some View {
        let help = model.helpItems
        let approvals = model.approvalItems
        if !help.isEmpty || !approvals.isEmpty {
            Section {
                ForEach(approvals) { ComputerApprovalRowView(request: $0) }
                ForEach(help) { HelpRequestRowView(item: $0) }
            } header: {
                Text("Needs You", bundle: .module)
                    .dsFont(DS.Font.sectionLabel)
                    .foregroundStyle(DS.Color.warning)
                    .padding(.horizontal, SidebarMetrics.sectionPaddingH)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .a11y(.sidebarNeedsYou, kind: "container")
        }
    }

    @ViewBuilder private func projectBlock(_ project: ProjectSectionData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectRowView(model: model, data: project).id(SidebarItemID.project(project.id))
            if !project.collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(project.pending) { row in
                        PendingRowView(model: model, data: row).id(SidebarItemID.pending(row.id)).padding(.bottom, SidebarMetrics.cardSpacing)
                    }
                    ForEach(project.sessions) { card in
                        cardView(card).id(SidebarItemID.session(card.id)).padding(.bottom, SidebarMetrics.cardSpacing)
                    }
                    if project.hiddenCount > 0 || project.showMoreExpanded {
                        showMoreRow(project)
                    }
                    if project.hasNoSessions {
                        noSessions(project)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.expoOut, MotionTokens.Duration.disclosure), value: project.collapsed)
    }

    private func cardView(_ card: SessionCardData) -> some View {
        SessionCardView(model: model, data: card, query: model.query, selection: selection, glowing: glowing == card.id)
    }

    private func showMoreRow(_ project: ProjectSectionData) -> some View {
        let pid = project.id.uuidString
        return ActionButton(.projectShowMore, id: .sidebarProjectShowMore(pid), argument: .select(project.hiddenCount > 0 ? pid : "less:\(pid)")) {
            Text(
                project.hiddenCount > 0
                    ? String(localized: "Show \(project.hiddenCount) more", bundle: .module)
                    : String(localized: "Show less", bundle: .module)
            )
            .dsFont(DS.Font.small)
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.leading, SidebarMetrics.cardMarginLeading + SidebarMetrics.cardPaddingH + SidebarMetrics.statusColumn + SidebarMetrics.statusGap)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.agentRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(SidebarItemID.showMore(project.id))
        .overlay { focusRing(model.keyboardFocus == .showMore(project.id)) }
    }

    private func noSessions(_ project: ProjectSectionData) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            Text("No sessions", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            if let registry, registry.isOffered(.projectNewSession) {
                DSButton(.projectNewSession, id: nil, "New Session", variant: .link, size: .xs, argument: .select(project.id.uuidString))
            }
        }
        .padding(.leading, SidebarMetrics.cardMarginLeading + SidebarMetrics.cardPaddingH + SidebarMetrics.statusColumn + SidebarMetrics.statusGap)
        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.agentRowHeight, alignment: .leading)
    }

    // MARK: Cabeçalhos de seção (03 §2.4, §2.10)

    private var projectsHeader: some View {
        SectionHeader(title: String(localized: "Projects", bundle: .module), tooltip: nil) {
            HeaderHoverGroup(pinned: model.filterMenuOpen || !model.filters.isDefault || model.sort != .recent) {
            if let registry, registry.isOffered(.sidebarSortFilter) {
                DSIconButton(
                    .sidebarSortFilter, id: .sidebarProjectsFilter, symbol: "slider.horizontal.3",
                    name: String(localized: "Sort and Filter", bundle: .module), variant: .header, active: model.filterMenuOpen)
                    .overlay(alignment: .topTrailing) {
                        if !model.filters.isDefault || model.sort != .recent {
                            Circle().fill(DS.Color.textPrimary).frame(width: SidebarMetrics.unreadDot, height: SidebarMetrics.unreadDot)
                        }
                    }
                    .popover(isPresented: Bindable(model).filterMenuOpen, arrowEdge: .bottom) { FilterMenuPanel(model: model) }
            }
            if let registry, registry.isOffered(.projectAdd) {
                DSIconButton(.projectAdd, id: .sidebarProjectsAdd, symbol: "folder.badge.plus", name: String(localized: "Add Project…", bundle: .module), variant: .header)
            }
            if let registry, registry.isOffered(.projectCloneFromGitHub) {
                DSIconButton(
                    .projectCloneFromGitHub, id: .sidebarProjectsClone, symbol: "arrow.down.to.line",
                    name: String(localized: "Clone from GitHub…", bundle: .module), variant: .header)
            }
            }
            if let registry, registry.isOffered(.sessionNew) {
                DSIconButton(.sessionNew, id: .sidebarProjectsNewSession, symbol: "plus", name: String(localized: "New Session", bundle: .module), variant: .header)
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: model.filterMenuOpen)
    }

    private var sessionsHeader: some View {
        SectionHeader(title: String(localized: "Sessions", bundle: .module), tooltip: String(localized: "Sessions without a project or Git", bundle: .module)) {
            if let registry, registry.isOffered(.sessionNewClean) {
                DSIconButton(
                    .sessionNewClean, id: .sidebarCleanSessionsNew, symbol: "plus", name: String(localized: "New Clean Session", bundle: .module), variant: .header)
            }
        }
        .a11y(.sidebarCleanSessions, kind: "container")
    }

    // MARK: Estados vazios (03 §2.13, M-902)

    private func emptyWorkspace(archived: Int) -> some View {
        DSEmptyState(String(localized: "No projects yet.", bundle: .module)) {
            VStack(spacing: DS.Space.s2) {
                if let registry, registry.isOffered(.projectAdd) {
                    DSButton(.projectAdd, id: nil, "Add Project…", variant: .outline, size: .sm)
                }
                if let registry, registry.isOffered(.projectCloneFromGitHub) {
                    DSButton(.projectCloneFromGitHub, id: nil, "Clone from GitHub…", variant: .ghost, size: .sm)
                }
                if let registry, registry.isOffered(.sessionNewClean) {
                    DSButton(.sessionNewClean, id: nil, "New Clean Session", variant: .ghost, size: .sm)
                }
                if archived > 0 {
                    DSButton(.sidebarSortFilter, id: nil, "Show \(archived) Archived", variant: .ghost, size: .xs, argument: .set("archived=on"))
                }
            }
        }
        .padding(.top, DS.Space.s6)
        .a11y(.empty("sidebar"), kind: "container")
    }

    private var searchEmpty: some View {
        DSEmptyState(String(localized: "No sessions match \"\(model.query)\".", bundle: .module)) {
            if let registry, registry.isOffered(.sidebarClearSearch) {
                DSButton(.sidebarClearSearch, id: .sidebarSearchEmptyClear, "Clear Search", variant: .ghost, size: .xs)
            }
        }
        .transition(.opacity)
        .a11y(.sidebarSearchEmpty, kind: "container", label: String(localized: "No sessions match \"\(model.query)\".", bundle: .module))
    }

    private var filtersEmpty: some View {
        DSEmptyState(String(localized: "No sessions match these filters.", bundle: .module)) {
            DSButton(.sidebarClearFilters, id: nil, "Clear Filters", variant: .ghost, size: .xs)
        }
    }

    // MARK: Rodapé (03 §2.12)

    private var footer: some View {
        HStack {
            if let registry, registry.isOffered(.appSettings) {
                DSIconButton(.appSettings, id: .sidebarFooterSettings, symbol: "gearshape", name: String(localized: "Settings", bundle: .module), variant: .row)
            }
            Spacer()
            DSIconButton(.sidebarRevealCurrent, id: .sidebarFooterReveal, symbol: "scope", name: String(localized: "Reveal Current Session", bundle: .module), variant: .row)
        }
        .padding(.horizontal, SidebarMetrics.footerPaddingH)
        .frame(height: SidebarMetrics.footerHeight)
        .overlay(alignment: .top) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }

    // MARK: Revelar (M-211)

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let r = model.reveal else { return }
        let id = r.id
        Task {
            await Task.yield()
            withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.drawer, MotionTokens.Duration.panel)) {
                proxy.scrollTo(SidebarItemID.session(id), anchor: .center)
            }
            glowing = id
            try? await Task.sleep(for: .seconds(MotionTokens.Duration.flash))
            if glowing == id { glowing = nil }
        }
    }

    // MARK: Teclado (03 §2.14)

    private func handle(_ press: KeyPress, _ projection: SidebarProjection) -> KeyPress.Result {
        guard press.modifiers.subtracting(.numericPad).isEmpty else { return .ignored }
        let items = projection.items
        let current = (model.keyboardFocus ?? model.selectedSession.map(SidebarItemID.session)).flatMap { items.firstIndex(of: $0) }
        switch press.key {
        case .upArrow:
            move(to: current.map { max($0 - 1, 0) } ?? 0, items)
            return .handled
        case .downArrow:
            move(to: current.map { min($0 + 1, items.count - 1) } ?? 0, items)
            return .handled
        case .rightArrow:
            guard let item = model.keyboardFocus else { return .ignored }
            switch item {
            case .project(let id): model.setProject(id, collapsed: false)
            case .session(let id): model.setSession(id, agentsCollapsed: false)
            default: break
            }
            return .handled
        case .leftArrow:
            guard let item = model.keyboardFocus else { return .ignored }
            switch item {
            case .project(let id): model.setProject(id, collapsed: true)
            case .session(let id):
                if projection.hasVisibleAgents(id) {
                    model.setSession(id, agentsCollapsed: true)
                } else if let pid = model.session(id)?.projectID {
                    model.keyboardFocus = .project(pid)
                }
            case .agent(let session, _): model.keyboardFocus = .session(session)
            default: break
            }
            return .handled
        case .return:
            guard let item = model.keyboardFocus, let registry else { return .ignored }
            activate(item, registry)
            return .handled
        case .escape:
            if model.inboxOpen {
                model.setInbox(open: false)
            } else if let registry, !model.query.isEmpty, registry.isRendered(.sidebarSearch) {
                model.query = ""
            } else {
                model.keyboardFocus = nil
                listFocused = false
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func move(to index: Int, _ items: [SidebarItemID]) {
        guard items.indices.contains(index) else { return }
        model.keyboardFocus = items[index]
    }

    private func activate(_ item: SidebarItemID, _ registry: ActionRegistry) {
        switch item {
        case .project(let id): Task { _ = try? await registry.perform(.sidebarProjectToggle, .select(id.uuidString)) }
        case .session(let id): Task { _ = try? await registry.perform(.sessionSelect, .select(id.uuidString)) }
        case .agent(_, let terminal): Task { _ = try? await registry.perform(.paneShow, .select(terminal.uuidString)) }
        case .showMore(let id): Task { _ = try? await registry.perform(.projectShowMore, .select(id.uuidString)) }
        case .pending(let id): Task { _ = try? await registry.perform(.sessionSelect, .select(id.uuidString)) }
        }
    }
}

extension SidebarProjection {
    func hasVisibleAgents(_ session: UUID) -> Bool {
        items.contains { if case .agent(let s, _) = $0 { s == session } else { false } }
    }
}

// MARK: Cabeçalho de seção

struct SectionHeader<Actions: View>: View {
    let title: String
    let tooltip: String?
    let actions: Actions

    init(title: String, tooltip: String?, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.tooltip = tooltip
        self.actions = actions()
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s0_5) {
            Text(verbatim: title)
                .dsFont(DS.Font.sectionLabel)
                .foregroundStyle(DS.Color.textTertiary)
                .help(tooltip ?? "")
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.s1)
            actions.environment(\.sectionHeaderHovering, hovering)
        }
        .onHover { hovering = $0 }
        .padding(.horizontal, SidebarMetrics.sectionPaddingH)
        .frame(height: SidebarMetrics.sectionHeaderHeight)
        .padding(.top, SidebarMetrics.sectionMarginTop)
        .frame(maxWidth: .infinity)
        // O fundo cobre a largura toda (o conteúdo da lista tem padding de 8 dos dois lados).
        .background(DS.Color.sidebar.padding(.horizontal, -SidebarMetrics.paddingH))
    }
}

/// v5: as ações secundárias de um cabeçalho (filtro, adicionar, clonar) só aparecem com o ponteiro sobre ele, ou enquanto
/// algo delas está ativo; o `+` fica sempre.
struct HeaderHoverGroup<Content: View>: View {
    var pinned = false
    @ViewBuilder let content: Content
    @Environment(\.sectionHeaderHovering) private var hovering

    var body: some View {
        HStack(spacing: DS.Space.s0_5) { content }
            .opacity(hovering || pinned ? 1 : 0)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
    }
}

extension EnvironmentValues {
    @Entry var sectionHeaderHovering = false
}

// MARK: Item de nav (DS §12.8)

struct NavItemRow: View {
    let action: ActionID
    let id: A11yID
    let title: String
    let symbol: String
    let hideKey: String
    /// Contagem de atenção (prioridade 1–2): `sidebar.nav.inbox.badge`, laranja (M-701).
    var badge = 0
    var selected = false
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    var body: some View {
        if let registry, registry.isRendered(action) {
            ActionButton(action, id: id) {
                HStack(spacing: SidebarMetrics.navGapContent) {
                    Image(systemName: symbol)
                        .font(.system(size: SidebarMetrics.navIcon - 1, weight: .light))
                        .foregroundStyle(selected ? DS.Color.textSecondary : DS.Color.textTertiary)
                        .frame(width: SidebarMetrics.navIcon, height: SidebarMetrics.navIcon)
                    Text(verbatim: title).dsFont(DS.Font.nav).foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                    Spacer(minLength: .zero)
                    if badge > 0 { NavBadge(count: badge).a11y(.sidebarNavSessionsBadge, kind: "badge", label: "\(badge)") }
                }
                .padding(.horizontal, SidebarMetrics.navPaddingH)
                .frame(height: SidebarMetrics.navHeight)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: SidebarMetrics.navRadius).fill(selected ? DS.Color.secondary : hovering ? DS.Color.fg5 : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
            .dsContextMenu(name: "navContext", groups: {
                [[MenuEntry(action: .sidebarHideNavItem, title: String(localized: "Hide from Sidebar", bundle: .module), argument: .select(hideKey))]]
            })
        }
    }
}

/// Pílula de contagem do item `Inbox`: `orange-500`, número tabular; ao aumentar dá um bump e o número troca com
/// `numericText` (M-701, M-810). Reduce Motion: troca seca.
struct NavBadge: View {
    let count: Int
    @State private var bump = false

    var body: some View {
        Text(verbatim: String(count))
            .dsFont(DS.Font.microNumeric)
            .fontWeight(.semibold)
            .foregroundStyle(DS.ColorSpec.textOnPrimary.color)
            .contentTransition(.numericText())
            .padding(.horizontal, DS.Space.s1_5)
            .frame(minWidth: NavBadge.height, minHeight: NavBadge.height)
            .background(Capsule().fill(DS.Color.agentNeedsInput))
            .scaleEffect(bump ? MotionTokens.Scale.bump : 1)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.medium), value: count)
            .onChange(of: count) { old, new in
                guard new > old, !MotionPolicy.shared.reduceMotion else { return }
                withAnimation(Motion.spring(MotionTokens.Springs.lively)) { bump = true }
                Task {
                    try? await Task.sleep(for: .seconds(0.18))
                    withAnimation(Motion.spring(MotionTokens.Springs.lively)) { bump = false }
                }
            }
    }

    static let height: CGFloat = 16
}

// MARK: Search (DS §12.10 `sidebarSearch`)

struct SidebarSearchField: View {
    let model: SidebarModel
    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        HStack(spacing: SidebarMetrics.navGapContent) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: SidebarMetrics.navIcon - 2))
                .foregroundStyle(DS.Color.textTertiary)
                .frame(width: SidebarMetrics.navIcon, height: SidebarMetrics.navIcon)
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Search", bundle: .module).dsFont(DS.Font.nav).foregroundStyle(DS.Color.textTertiary).allowsHitTesting(false)
                }
                TextField(text: Bindable(model).query) { EmptyView() }
                    .textFieldStyle(.plain)
                    .dsFont(DS.Font.nav)
                    .foregroundStyle(DS.Color.textPrimary)
                    .focused($focused)
                    .onKeyPress(.escape) {
                        model.query = ""
                        focused = false
                        return .handled
                    }
                    .accessibilityLabel(Text("Search", bundle: .module))
            }
            if !model.query.isEmpty {
                DSIconButton(.sidebarClearSearch, id: .sidebarSearchClear, symbol: "xmark", name: String(localized: "Clear Search", bundle: .module), variant: .tabClose)
            } else if hovering || focused {
                Keycaps("⌘J")
            }
        }
        .padding(.horizontal, SidebarMetrics.navPaddingH)
        .frame(height: SidebarMetrics.searchHeight)
        .background(RoundedRectangle(cornerRadius: SidebarMetrics.navRadius).fill(DS.Color.secondary))
        .overlay(RoundedRectangle(cornerRadius: SidebarMetrics.navRadius).strokeBorder(focused ? DS.Color.ring : Color.clear, lineWidth: DSMetrics.hairline))
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering || focused)
        .onChange(of: model.focusSearchRequest) { _, _ in focused = true }
        .a11y(.sidebarSearch, kind: "textfield", value: model.query, action: .sidebarSearch)
    }
}

// MARK: Rolagem overlay (DS §12.24)

/// Faz o `NSScrollView` hospedeiro usar o estilo overlay (knob de 8 pt, invisível até o hover).
struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor [weak view] in
            await Task.yield()
            guard let scroll = view?.enclosingScrollView ?? view?.superview?.enclosingScrollView else { return }
            scroll.scrollerStyle = .overlay
            scroll.scrollerKnobStyle = .light
            scroll.autohidesScrollers = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
