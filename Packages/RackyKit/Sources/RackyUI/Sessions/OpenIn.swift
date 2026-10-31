import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation

/// App externo que abre a pasta de uma sessão ou de um projeto (03 §24.2, "Open in…").
struct ExternalApp: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case editor, terminal }
    let bundleID: String
    let name: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(bundleID)" }
}

/// Catálogo por bundle id (nunca por caminho): o que está instalado é perguntado ao `NSWorkspace`.
enum ExternalAppCatalog {
    static let editors: [ExternalApp] = [
        ExternalApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", kind: .editor),
        ExternalApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", kind: .editor),
        ExternalApp(bundleID: "dev.zed.Zed", name: "Zed", kind: .editor),
        ExternalApp(bundleID: "com.apple.dt.Xcode", name: "Xcode", kind: .editor),
        ExternalApp(bundleID: "com.sublimetext.4", name: "Sublime Text", kind: .editor),
    ]
    static let terminals: [ExternalApp] = [
        ExternalApp(bundleID: "com.apple.Terminal", name: "Terminal", kind: .terminal),
        ExternalApp(bundleID: "com.googlecode.iterm2", name: "iTerm", kind: .terminal),
        ExternalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty", kind: .terminal),
        ExternalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp", kind: .terminal),
    ]
    static func app(forTarget id: String) -> ExternalApp? { (editors + terminals).first { $0.id == id } }
}

/// Efeitos de sistema do "Open in…", trocáveis nos testes (nenhum teste abre editor de verdade).
struct OpenInSystem: Sendable {
    /// Onde o app está instalado (`nil` = não instalado).
    var applicationURL: @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    /// Abre a pasta no app.
    var open: @Sendable (URL, URL) async throws -> Void = { folder, app in
        _ = try await NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Abre no app padrão do sistema.
    var openDefault: @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var reveal: @Sendable (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// "Open in…" e "Open in Editor" (⇧⌘O): Finder, terminais e editores detectados, aberto pelo `NSWorkspace` com o caminho real da pasta.
@MainActor
final class OpenInController {
    static let lastEditorKey = "openIn.lastEditor"

    private let sidebar: SidebarModel
    private let overlays: OverlayRouter
    private let toasts: ToastCenter
    private let elements: UIElementStore
    var system = OpenInSystem()
    private var store: RackyStore?
    private var lastEditor: String?
    private weak var registry: ActionRegistry?
    private let log = LogFacade(.app, category: "open-in")

    init(sidebar: SidebarModel, overlays: OverlayRouter, toasts: ToastCenter, elements: UIElementStore) {
        self.sidebar = sidebar
        self.overlays = overlays
        self.toasts = toasts
        self.elements = elements
    }

    func attach(store: RackyStore) {
        self.store = store
        Task { lastEditor = (try? await store.setting(Self.lastEditorKey, as: String.self)) ?? lastEditor }
    }

    // MARK: Detecção

    func installedEditors() -> [ExternalApp] { ExternalAppCatalog.editors.filter { system.applicationURL($0.bundleID) != nil } }
    func installedTerminals() -> [ExternalApp] { ExternalAppCatalog.terminals.filter { system.applicationURL($0.bundleID) != nil } }

    /// Editor de `Open in Editor`: o último usado, se ainda instalado; senão o primeiro detectado.
    func preferredEditor() -> ExternalApp? {
        let installed = installedEditors()
        return installed.first { $0.bundleID == lastEditor } ?? installed.first
    }

    // MARK: Alvo

    private func itemID(_ arg: ActionArgument, _ action: ActionID) throws -> UUID {
        if arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) { return id }
        if let selected = sidebar.selectedSession { return selected }
        throw ActionError.failed(action, message: "expected select(<id>)")
    }

    private func folder(of id: UUID, _ action: ActionID) throws -> URL {
        guard let path = sidebar.project(id)?.rootPath ?? sidebar.session(id)?.folderPath else {
            throw ActionError.failed(action, message: "Item not found")
        }
        guard SessionFolderProbe.isDirectory(path) else {
            throw ActionError.failed(action, message: "Folder not found")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Entradas do menu `Open in…` (Finder, terminais, editores instalados).
    func entries(for id: UUID) -> [DSMenuEntry] {
        var list: [DSMenuEntry] = [
            .item(DSMenuItem("finder", String(localized: "Finder", bundle: .module), icon: .symbol("folder"), action: .itemOpenInTarget, argument: .select("\(id.uuidString)/finder")))
        ]
        let terminals = installedTerminals()
        let editors = installedEditors()
        if !terminals.isEmpty {
            list.append(.separator("terminals"))
            for app in terminals {
                list.append(.item(DSMenuItem(app.id, app.name, icon: .symbol("terminal"), action: .itemOpenInTarget, argument: .select("\(id.uuidString)/\(app.id)"))))
            }
        }
        if !editors.isEmpty {
            list.append(.separator("editors"))
            for app in editors {
                list.append(.item(DSMenuItem(app.id, app.name, icon: .symbol("chevron.left.forwardslash.chevron.right"), action: .itemOpenInTarget, argument: .select("\(id.uuidString)/\(app.id)"))))
            }
        }
        return list
    }

    // MARK: Arquivos (visualizador do painel Files)

    /// Entradas do menu `Open in…` de um arquivo: Finder, app padrão do sistema e editores instalados.
    func fileEntries() -> [DSMenuEntry] {
        var list: [DSMenuEntry] = [
            .item(DSMenuItem("finder", String(localized: "Reveal in Finder", bundle: .module), icon: .symbol("folder"), action: .filesOpenInTarget, argument: .select("finder"))),
            .item(DSMenuItem("default", String(localized: "Default App", bundle: .module), icon: .symbol("arrow.up.forward.app"), action: .filesOpenInTarget, argument: .select("default"))),
        ]
        let editors = installedEditors()
        if !editors.isEmpty {
            list.append(.separator("editors"))
            for app in editors {
                list.append(.item(DSMenuItem(app.id, app.name, icon: .symbol("chevron.left.forwardslash.chevron.right"), action: .filesOpenInTarget, argument: .select(app.id))))
            }
        }
        return list
    }

    /// Abre um arquivo: `target` nil = editor preferido (senão o app padrão); `default` = app padrão; ou o id de um editor.
    func openFile(_ url: URL, target: String?) async throws -> String {
        let action = ActionID.filesOpenInTarget
        if target == "default" || (target == nil && preferredEditor() == nil) {
            // Mesma política dos links do terminal: o que o sistema executaria em vez de mostrar (.app, .command, binário com bit de
            // execução…) só é revelado no Finder. Vale para "Open in Default App" e "open change", que passam por aqui.
            guard TerminalLinkPolicy.opensSafelyWithDefaultApp(url.path, isDirectory: SessionFolderProbe.isDirectory(url.path)) else {
                system.reveal(url)
                return "finder"
            }
            let opened = system.openDefault(url)
            guard opened else { throw ActionError.failed(action, message: String(localized: "Couldn't open the file.", bundle: .module)) }
            return "default"
        }
        let app: ExternalApp
        if let target {
            guard let found = ExternalAppCatalog.app(forTarget: target) else { throw ActionError.failed(action, message: "unknown target \(target)") }
            app = found
        } else if let preferred = preferredEditor() {
            app = preferred
        } else {
            throw ActionError.failed(action, message: String(localized: "Choose an editor in Settings › General.", bundle: .module))
        }
        guard let appURL = system.applicationURL(app.bundleID) else {
            throw ActionError.failed(action, message: String(localized: "\(app.name) isn't installed.", bundle: .module))
        }
        do {
            try await system.open(url, appURL)
        } catch {
            log.error("open file in \(app.bundleID) failed: \(error)")
            toasts.show(kind: .error, title: String(localized: "Couldn't open in \(app.name).", bundle: .module), detail: error.localizedDescription)
            throw ActionError.failed(action, message: error.localizedDescription)
        }
        if app.kind == .editor { rememberEditor(app) }
        return app.id
    }

    // MARK: Abrir

    func open(itemID id: UUID, target: String) async throws -> String {
        let action = ActionID.itemOpenInTarget
        let url = try folder(of: id, action)
        if target == "finder" {
            system.reveal(url)
            return "finder"
        }
        guard let app = ExternalAppCatalog.app(forTarget: target), let appURL = system.applicationURL(app.bundleID) else {
            let name = ExternalAppCatalog.app(forTarget: target)?.name ?? target
            throw ActionError.failed(action, message: String(localized: "\(name) isn't installed.", bundle: .module))
        }
        do {
            try await system.open(url, appURL)
        } catch {
            log.error("open in \(app.bundleID) failed: \(error)")
            toasts.show(kind: .error, title: String(localized: "Couldn't open in \(app.name).", bundle: .module), detail: error.localizedDescription)
            throw ActionError.failed(action, message: error.localizedDescription)
        }
        if app.kind == .editor { rememberEditor(app) }
        return app.id
    }

    private func rememberEditor(_ app: ExternalApp) {
        lastEditor = app.bundleID
        guard let store else { return }
        Task { try? await store.setSetting(Self.lastEditorKey, app.bundleID) }
    }

    // MARK: Registro de ações

    func register(in registry: ActionRegistry) throws {
        self.registry = registry
        try registry.register(.itemOpenIn) { [unowned self] arg in
            let id = try itemID(arg, .itemOpenIn)
            _ = try folder(of: id, .itemOpenIn)
            let anchorID: A11yID = sidebar.project(id) != nil ? .sidebarProject(id.uuidString) : .sidebarSession(id.uuidString)
            let anchor = elements.frame(of: anchorID) ?? .zero
            let opened = DSMenuPanel.present(router: overlays, registry: registry, name: "openIn", anchor: anchor, entries: entries(for: id))
            return opened ? "opened" : "busy"
        }
        try registry.register(.itemOpenInTarget) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let slash = raw.firstIndex(of: "/"), let id = UUID(uuidString: String(raw[..<slash])) else {
                throw ActionError.failed(.itemOpenInTarget, message: "expected select(<id>/<target>)")
            }
            return try await open(itemID: id, target: String(raw[raw.index(after: slash)...]))
        }
        try registry.register(
            .itemOpenInEditor,
            enablement: { [unowned self] in
                preferredEditor() == nil ? .disabled(reason: String(localized: "Choose an editor in Settings › General.", bundle: .module)) : .enabled
            }
        ) { [unowned self] arg in
            guard let editor = preferredEditor() else {
                throw ActionError.failed(.itemOpenInEditor, message: String(localized: "Choose an editor in Settings › General.", bundle: .module))
            }
            return try await open(itemID: try itemID(arg, .itemOpenInEditor), target: editor.id)
        }
    }
}
