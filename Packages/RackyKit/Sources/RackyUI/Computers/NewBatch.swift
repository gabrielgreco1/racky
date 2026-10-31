import RackyCore
import RackyDesignSystem
import RackyDocker
import RackyProtocol
import RackyStore
import AppKit
import Observation
import SwiftUI

// T3-07, 03 §16.15, 07 CS-324: o overlay "New Batch…". Cola a lista (ou CSV) de alvos, escolhe o brief, o tipo de computador, o proxy e
// os proxies permitidos, e abre um terminal Claude pai com a skill de orquestração e o pedido como prompt inicial. O app não orquestra.

@MainActor @Observable
final class NewBatchModel {
    enum SessionChoice: String, CaseIterable { case new, current }
    enum ProxyChoice: Equatable { case useDefault, none, named(String) }

    var targetsText = ""
    var brief = NewBatchPrompt.defaultBrief
    var display: ComputerDisplay = .headless
    var proxy: ProxyChoice = .useDefault
    var allowedProxies: Set<String> = []
    var session: SessionChoice = .new
    /// Nomes dos proxies salvos (Settings › Computers › Proxies) e o padrão global, para o combobox e os checkboxes.
    var proxyNames: [String] = []
    var defaultProxy: String?
    /// A sessão atual tem um terminal Claude onde colar o pedido.
    var currentSessionAvailable = false
    var name: String

    init(name: String = NewBatchPrompt.defaultName()) { self.name = name }

    var targets: [BatchTarget] { NewBatchPrompt.parseTargets(targetsText) }

    var countText: String {
        let n = targets.count
        return n == 1 ? String(localized: "1 target", bundle: .module) : String(localized: "\(n) targets", bundle: .module)
    }

    /// `Add at least one target.` (03 §24.5).
    var issue: String? { targets.isEmpty ? String(localized: "Add at least one target.", bundle: .module) : nil }

    var proxyValue: String? {
        switch proxy {
        case .useDefault: nil
        case .none: "none"
        case .named(let name): name
        }
    }

    var request: NewBatchRequest {
        NewBatchRequest(
            name: name, targets: targets, brief: brief, display: display, proxy: proxyValue,
            allowedProxies: proxyNames.filter { allowedProxies.contains($0) })
    }

    var proxySelection: String {
        switch proxy {
        case .useDefault: "default"
        case .none: "none"
        case .named(let name): name
        }
    }

    var proxyEntries: [DSMenuEntry] {
        func item(_ id: String, _ title: String, detail: String? = nil) -> DSMenuEntry {
            var entry = DSMenuItem(id, title, icon: .symbol("network"), checked: proxySelection == id, action: .dialogNewBatchSetProxy, argument: .select(id))
            entry.detail = detail
            return .item(entry)
        }
        var out = [item("default", String(localized: "Default", bundle: .module), detail: defaultProxy), item("none", String(localized: "None", bundle: .module))]
        out += proxyNames.sorted().map { item($0, $0) }
        return out
    }

    func chooseProxy(_ raw: String) {
        switch raw {
        case "default": proxy = .useDefault
        case "none": proxy = .none
        default: proxy = proxyNames.contains(raw) ? .named(raw) : proxy
        }
    }

    func toggleAllowed(_ name: String) {
        guard proxyNames.contains(name) else { return }
        if !allowedProxies.insert(name).inserted { allowedProxies.remove(name) }
    }

    var hasData: Bool { !targetsText.isEmpty }
}

struct NewBatchView: View {
    let model: NewBatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            Text("New Batch", bundle: .module).dsFont(DS.Font.composerTitle).foregroundStyle(DS.Color.textPrimary).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                field("Targets", trailing: AnyView(HStack(spacing: DS.Space.s2) {
                    Text(verbatim: model.countText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).a11y(.overlayNewBatchCount, kind: "text", value: "\(model.targets.count)")
                    DSButton(.dialogNewBatchImportCSV, id: .overlayNewBatchImportCSV, "Import CSV…", variant: .ghost, size: .xs)
                })) {
                    DSTextField(
                        "One target per line, or a CSV with a header row", text: Bindable(model).targetsText, id: .overlayNewBatchTargets,
                        action: .dialogNewBatchSetTargets, multiline: true, autofocus: true, compact: true, mono: true)
                }
                field("Brief") {
                    DSPromptField(
                        String(localized: "TASK, WHAT WE ALREADY KNOW and OUTPUT for each target. Use {{target}} and CSV columns like {{city}}.", bundle: .module),
                        text: Bindable(model).brief, id: .overlayNewBatchBrief, action: .dialogNewBatchSetBrief)
                }
            }
            .overlayGroup(0)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack(alignment: .top, spacing: DS.Space.s3) {
                    field("Computer type") {
                        DSSegmented(
                            [.init("headless", "Headless"), .init("desktop", "Desktop"), .init("http", "HTTP")], selection: model.display.rawValue,
                            action: .dialogNewBatchSetDisplay, id: .overlayNewBatchDisplay, fillWidth: true, height: DSMetrics.segmentedHeightComposer)
                    }
                    field("Proxy") {
                        DSCombobox(
                            id: .overlayNewBatchProxy, selection: model.proxySelection, entries: model.proxyEntries, action: .dialogNewBatchSetProxy,
                            searchPlaceholder: String(localized: "Search proxies…", bundle: .module))
                    }
                }
                if !model.proxyNames.isEmpty {
                    field("Allowed proxies") {
                        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                            ForEach(model.proxyNames.sorted(), id: \.self) { name in
                                DSListRow(.dialogNewBatchToggleProxy, id: .overlayNewBatchAllowedProxiesWithProxy(name), argument: .select(name)) {
                                    HStack(spacing: DS.Space.s2) {
                                        DSCheckboxVisual(isOn: model.allowedProxies.contains(name))
                                        Text(verbatim: name).dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, DS.Space.s2)
                                    .frame(minHeight: DS.Space.s8)
                                }
                            }
                        }
                        .a11y(.overlayNewBatchAllowedProxies, kind: "group")
                    }
                }
                field("Session") {
                    DSSegmented(
                        [.init("new", "New Clean Session"), .init("current", "Current session")], selection: model.session.rawValue,
                        action: .dialogNewBatchSetSession, id: .overlayNewBatchSession, fillWidth: true, height: DSMetrics.segmentedHeightComposer)
                }
                if let issue = model.issue {
                    Text(verbatim: issue).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: DS.Space.s2)
                    DSButton(.dialogNewBatchCancel, id: .overlayNewBatchCancel, "Cancel", variant: .outline)
                    DSButton(.dialogNewBatchConfirm, id: .overlayNewBatchSubmit, "Start Batch", variant: .primary, keycap: "⌘↵")
                        .disabled(model.issue != nil)
                }
            }
            .overlayGroup(1)
        }
        .padding(DSMetrics.overlayPadding)
    }

    private func field(_ title: LocalizedStringKey, trailing: AnyView? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            HStack {
                Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s2)
                if let trailing { trailing }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Abre o overlay, mantém o modelo e entrega o pedido ao launcher (terminal Claude novo) ou cola no terminal Claude da sessão atual.
@MainActor
final class NewBatchController {
    private let sidebar: SidebarModel
    private let workspace: WorkspaceModel
    private let settings: SettingsModel
    private let overlays: OverlayRouter
    private let computers: ComputersController
    private let launcher: SessionLauncher
    private weak var registry: ActionRegistry?
    private(set) var model: NewBatchModel?
    private let automationEnabled: Bool

    init(
        sidebar: SidebarModel, workspace: WorkspaceModel, settings: SettingsModel, overlays: OverlayRouter, computers: ComputersController,
        launcher: SessionLauncher, automationEnabled: Bool
    ) {
        self.sidebar = sidebar; self.workspace = workspace; self.settings = settings; self.overlays = overlays; self.computers = computers
        self.launcher = launcher; self.automationEnabled = automationEnabled
    }

    private var isOpen: Bool { overlays.top?.spec.name == "newBatch" && model != nil }

    /// Terminal Claude em execução na sessão selecionada (onde o pedido pode ser colado).
    private func currentSessionAgent() -> UUID? {
        guard let session = sidebar.selectedSession else { return nil }
        let tabs = Set(sidebar.snapshot.tabs.filter { $0.sessionID == session && $0.closedAt == nil }.map(\.id))
        return sidebar.snapshot.terminals.first { tabs.contains($0.tabID) && $0.provider.supportsSubagentComputers && $0.state == .running }?.id
    }

    @discardableResult
    func open(from origin: A11yID? = nil) async -> Bool {
        if isOpen { return true }
        let model = NewBatchModel()
        model.proxyNames = (await computers.proxyNames()).sorted()
        model.currentSessionAvailable = currentSessionAgent() != nil
        self.model = model
        let opened = overlays.present(
            OverlaySpec(
                name: "newBatch", id: .overlayNewBatch, width: DS.Layout.composerWidth, cancelAction: .dialogNewBatchCancel,
                dismissOnScrim: { !model.hasData }, content: { AnyView(NewBatchView(model: model)) }),
            from: origin)
        if !opened { self.model = nil }
        return opened
    }

    /// `Start Batch`: fecha o overlay e abre o terminal pai (ou cola o pedido no da sessão atual). Devolve o nome do lote.
    func start() async throws -> String {
        guard let model, isOpen else { throw ActionError.failed(.dialogNewBatchConfirm, message: "New Batch isn't open") }
        if let issue = model.issue { throw ActionError.failed(.dialogNewBatchConfirm, message: issue) }
        let request = model.request
        let prompt = NewBatchPrompt.prompt(for: request)
        switch model.session {
        case .new:
            var launch = SessionLaunchRequest()
            launch.provider = TerminalProvider.claude.rawValue
            launch.prompt = prompt
            launch.name = request.name
            // Iniciar o lote é o consentimento para computadores nesta sessão; o padrão de Settings vale se já liga o recurso.
            launch.subagentComputers = (settings.settings.computers.defaultSubagentMode.isOn ? settings.settings.computers.defaultSubagentMode : .ask).rawValue
            // Primeiro o terminal, depois fecha o overlay: se o lançamento falhar, o que foi digitado continua lá.
            _ = try await launcher.launch(launch)
            self.model = nil
            overlays.dismiss(.action)
        case .current:
            guard let terminal = currentSessionAgent(), let registry else {
                throw ActionError.failed(.dialogNewBatchConfirm, message: String(localized: "Select a session with Claude Code.", bundle: .module))
            }
            let payload = JSON.object(["terminal": .string(terminal.uuidString), "text": .string(prompt)]).text
            _ = try await registry.perform(.dialogPasteToAgentConfirm, .set(payload))
            self.model = nil
            overlays.dismiss(.action)
        }
        return request.name
    }

    func register(in registry: ActionRegistry) throws {
        self.registry = registry
        try registry.register(
            .batchNew,
            enablement: { [unowned self] in
                settings.agent(.claude)?.installedState == false ? .disabled(reason: String(localized: "Install Claude Code first.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            return await open() ? "opened" : "busy"
        }
        func edit(_ id: ActionID, _ change: @escaping @MainActor (NewBatchModel, ActionArgument) throws -> String?) throws {
            try registry.register(id) { [unowned self] arg in
                guard let model, isOpen else { throw ActionError.failed(id, message: "New Batch isn't open") }
                return try change(model, arg)
            }
        }
        try edit(.dialogNewBatchSetTargets) { model, arg in
            model.targetsText = arg.value ?? ""
            return String(model.targets.count)
        }
        try edit(.dialogNewBatchSetBrief) { model, arg in
            model.brief = arg.value ?? ""
            return nil
        }
        try edit(.dialogNewBatchSetDisplay) { model, arg in
            guard arg.kind == .select, let raw = arg.value, let display = ComputerDisplay(rawValue: raw) else {
                throw ActionError.failed(.dialogNewBatchSetDisplay, message: "expected select(headless|desktop|http)")
            }
            model.display = display
            return display.rawValue
        }
        try edit(.dialogNewBatchSetProxy) { model, arg in
            guard arg.kind == .select, let raw = arg.value else { throw ActionError.failed(.dialogNewBatchSetProxy, message: "expected select(default|none|<proxy>)") }
            model.chooseProxy(raw)
            return model.proxySelection
        }
        try edit(.dialogNewBatchToggleProxy) { model, arg in
            guard arg.kind == .select, let raw = arg.value, model.proxyNames.contains(raw) else {
                throw ActionError.failed(.dialogNewBatchToggleProxy, message: "expected select(<proxy>)")
            }
            model.toggleAllowed(raw)
            return model.allowedProxies.contains(raw) ? "on" : "off"
        }
        try edit(.dialogNewBatchSetSession) { model, arg in
            guard arg.kind == .select, let raw = arg.value, let choice = NewBatchModel.SessionChoice(rawValue: raw) else {
                throw ActionError.failed(.dialogNewBatchSetSession, message: "expected select(new|current)")
            }
            if choice == .current, !model.currentSessionAvailable {
                throw ActionError.failed(.dialogNewBatchSetSession, message: String(localized: "Select a session with Claude Code.", bundle: .module))
            }
            model.session = choice
            return choice.rawValue
        }
        try registry.register(.dialogNewBatchCancel) { [unowned self] _ in
            model = nil
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(.dialogNewBatchConfirm) { [unowned self] _ in try await start() }
        // `Import CSV…`: painel de abrir; `set(<caminho>)` (automação) lê direto.
        try registry.register(.dialogNewBatchImportCSV) { [unowned self] arg in
            guard let model, isOpen else { throw ActionError.failed(.dialogNewBatchImportCSV, message: "New Batch isn't open") }
            var url: URL?
            if arg.kind == .set, let path = arg.value, !path.isEmpty {
                guard automationEnabled else { throw ActionError.failed(.dialogNewBatchImportCSV, message: "Automation is off") }
                url = URL(fileURLWithPath: path)
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.commaSeparatedText, .plainText]
                let response = await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in panel.begin { c.resume(returning: $0) } }
                guard response == .OK else { return "cancelled" }
                url = panel.url
            }
            guard let url, let text = NewBatchPrompt.loadTargets(from: url) else {
                throw ActionError.failed(.dialogNewBatchImportCSV, message: String(localized: "Couldn't read that file.", bundle: .module))
            }
            model.targetsText = text
            return String(model.targets.count)
        }
    }
}
