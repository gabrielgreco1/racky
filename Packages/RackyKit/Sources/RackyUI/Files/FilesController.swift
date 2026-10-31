import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

/// Terminal focado, como o módulo Files o enxerga.
struct FilesFocusedTerminal: Equatable {
    var id: UUID
    /// Nome curto para o chip ("Claude", "Codex", "OpenCode", "Terminal").
    var agent: String?
    /// `cwd` guardado no terminal (último OSC 7, ou a pasta de lançamento depois de reabrir o app).
    var fallbackCwd: String?
}

/// De onde o módulo tira sessão e terminal focado; trocável nos testes.
struct FilesSource {
    var sessionID: () -> UUID?
    var sessionRoot: () -> String?
    var focusedTerminal: () -> FilesFocusedTerminal?
}

/// O que o módulo lembra entre aberturas (`ui_state`).
nonisolated struct FilesPersistedState: Codable, Equatable, Sendable {
    var showIgnored: Bool
}

/// Arquivo aberto no visualizador (somente leitura).
struct FileViewerState: Equatable {
    var path: String
    /// `nil` enquanto lê.
    var content: FileContent?
    var language: SyntaxLanguage
    var lineCount: Int
    var marks: LineChangeMarks
    var spans: [SyntaxSpan]
    var change: FileChange?
    /// Muda a cada (re)leitura: a view reaplica o texto.
    var version: Int
    var highlightLimited: Bool
    /// Linha (base 1) para onde o visualizador rola ao abrir, vinda de `arquivo:linha` no terminal.
    var targetLine: Int? = nil

    var name: String { (path as NSString).lastPathComponent }
}

/// Busca dentro do arquivo aberto.
struct FileSearchState: Equatable {
    var isActive = false
    var query = ""
    var matches: [NSRange] = []
    var current = 0

    var countLabel: String {
        guard !query.isEmpty else { return "" }
        return matches.isEmpty ? String(localized: "No results", bundle: .module) : String(localized: "\(current + 1) of \(matches.count)", bundle: .module)
    }
}

/// Módulo Files (10-right-panel §2): árvore do diretório da sessão que acompanha o `cwd` do terminal focado (OSC 7 e hooks),
/// com pin, FSEvents, marcação de alterados e visualizador de código. A resolução de qual pasta mostrar é pura
/// (`FilesFollow`); aqui ficam o estado observável, a carga assíncrona e as ações.
@MainActor
@Observable
final class FilesController {
    static let uiStateKey = "files"

    // Estado observável.
    private(set) var resolution = FilesRootResolution(root: nil, mode: .none, isOutsideSession: false)
    private(set) var tree: FileTreeState?
    private(set) var changes = GitChangeMap.empty
    private(set) var branch: String?
    private(set) var repositoryRoot: String?
    /// Incrementa a cada troca de raiz (a view anima a transição).
    private(set) var rootEpoch = 0
    private(set) var viewer: FileViewerState?
    private(set) var search = FileSearchState()
    private(set) var showIgnored = false
    /// Raiz sendo lida pela primeira vez.
    private(set) var isLoadingRoot = false

    // Dependências.
    @ObservationIgnored var source: FilesSource
    @ObservationIgnored let service: FilesService
    @ObservationIgnored let git: FilesGitService
    @ObservationIgnored var externalOpen: (URL, _ target: String?) async throws -> String = { _, _ in "" }
    @ObservationIgnored var revealInFinder: (URL) -> Void = { _ in }
    @ObservationIgnored var toasts: ToastCenter?
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private let log = LogFacade(.app, category: "files")

    // Interno.
    @ObservationIgnored private var cwds = AgentCwdTracker()
    @ObservationIgnored private var pins: [UUID: String] = [:]
    @ObservationIgnored private var expandedByRoot: [String: Set<String>] = [:]
    @ObservationIgnored private var inputSignature: [String?] = []
    @ObservationIgnored private var lastSessionID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var watcher: GitChangeWatcher?
    @ObservationIgnored private var watchedRoot: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    @ObservationIgnored private var viewerTask: Task<Void, Never>?
    @ObservationIgnored private var viewerVersion = 0
    @ObservationIgnored private var pendingLine: Int?
    @ObservationIgnored var treeDebounce: Duration = .milliseconds(250)
    @ObservationIgnored var gitDebounce: Duration = .milliseconds(300)

    init(source: FilesSource, service: FilesService = FilesService(), git: FilesGitService = FilesGitService()) {
        self.source = source
        self.service = service
        self.git = git
    }

    // MARK: Entradas do seguimento

    /// `cwd` de um terminal, vindo de OSC 7 (evento do daemon) ou de um hook.
    func noteCwd(_ path: String, terminal: UUID, source: AgentCwdSource) {
        cwds.record(path, terminal: terminal, source: source)
        recompute()
    }

    func terminalClosed(_ terminal: UUID) { cwds.forget(terminal) }

    /// Último `cwd` informado por OSC 7/hooks para o terminal (caminhos relativos clicáveis no terminal partem daqui).
    func trackedCwd(for terminal: UUID) -> String? { cwds.cwd(for: terminal) }

    /// Sessão, foco ou `cwd` mudaram: decide a raiz de novo (barato quando nada mudou).
    func recompute() {
        let focus = source.focusedTerminal()
        let sessionID = source.sessionID()
        let sessionRoot = source.sessionRoot()
        let cwd = focus.flatMap { cwds.cwd(for: $0.id) ?? $0.fallbackCwd }
        let pinned = sessionID.flatMap { pins[$0] }
        let signature: [String?] = [sessionID?.uuidString, sessionRoot, cwd, focus?.agent, pinned]
        guard signature != inputSignature else { return }
        inputSignature = signature
        if sessionID != lastSessionID {
            lastSessionID = sessionID
            closeViewer()
        }
        let next = FilesFollow.resolve(sessionRoot: sessionRoot, agentCwd: cwd, agentName: focus?.agent, pinnedRoot: pinned)
        if next != resolution { resolution = next }
        if next.root != tree?.root { switchRoot(to: next.root) }
    }

    // MARK: Pin

    var isPinned: Bool { resolution.mode == .pinned }

    func togglePin() {
        guard let sessionID = source.sessionID() else { return }
        if pins[sessionID] != nil {
            pins[sessionID] = nil
        } else if let root = resolution.root {
            pins[sessionID] = root
        }
        recompute()
    }

    /// Fixa na pasta da sessão (o agente foi para outro lugar e o usuário quer voltar).
    func showSessionFolder() {
        guard let sessionID = source.sessionID(), let root = source.sessionRoot() else { return }
        pins[sessionID] = FileTreeLoader.canonical(root)
        recompute()
    }

    var canShowSessionFolder: Bool {
        guard let session = source.sessionRoot(), let root = resolution.root else { return false }
        return FileTreeLoader.canonical(session) != root
    }

    // MARK: Raiz e árvore

    private func switchRoot(to root: String?) {
        generation += 1
        inFlight.removeAll()
        refreshTask?.cancel()
        gitTask?.cancel()
        if let old = tree { expandedByRoot[old.root] = old.expanded }
        stopWatching()
        changes = .empty
        branch = nil
        repositoryRoot = nil
        rootEpoch += 1
        guard let root else {
            tree = nil
            isLoadingRoot = false
            return
        }
        tree = FileTreeState(root: root, expanded: expandedByRoot[root] ?? [])
        isLoadingRoot = true
        loadPending()
        startWatching(root)
        refreshGit()
    }

    private var options: FileTreeOptions { FileTreeOptions(showIgnored: showIgnored) }

    private func loadPending() {
        guard let tree else { return }
        for directory in tree.pendingDirectories { load(directory) }
    }

    private func isIgnoredDirectory(_ directory: String, in tree: FileTreeState) -> Bool {
        let parent = (directory as NSString).deletingLastPathComponent
        return tree.listings[parent]?.entries.first { $0.path == directory }?.isIgnored ?? false
    }

    private func load(_ directory: String) {
        guard let tree, !inFlight.contains(directory) else { return }
        inFlight.insert(directory)
        let root = tree.root
        let token = generation
        let options = options
        let ancestorIgnored = isIgnoredDirectory(directory, in: tree)
        Task { [service] in
            let listing = await service.list(directory: directory, root: root, options: options, ancestorIgnored: ancestorIgnored)
            self.apply(listing, to: directory, root: root, token: token)
        }
    }

    private func apply(_ listing: FileListing, to directory: String, root: String, token: Int) {
        guard token == generation, tree?.root == root else { return }
        inFlight.remove(directory)
        if tree?.listings[directory] != listing { tree?.setListing(listing, for: directory) }
        if directory == root { isLoadingRoot = false }
        loadPending()
    }

    func toggleFolder(_ path: String) {
        guard tree != nil else { return }
        tree?.toggle(path)
        if tree?.isExpanded(path) == true, tree?.isLoaded(path) == false { load(path) }
        if let tree { expandedByRoot[tree.root] = tree.expanded }
    }

    /// Relê a raiz e as pastas expandidas (botão Refresh e eventos do disco).
    func refresh() {
        guard let tree else { return }
        generation += 1
        inFlight.removeAll()
        let token = generation
        let options = options
        for directory in tree.visibleDirectories {
            let root = tree.root
            let ancestorIgnored = isIgnoredDirectory(directory, in: tree)
            inFlight.insert(directory)
            Task { [service] in
                let listing = await service.list(directory: directory, root: root, options: options, ancestorIgnored: ancestorIgnored)
                self.apply(listing, to: directory, root: root, token: token)
            }
        }
        refreshGit()
        reloadViewerIfNeeded(paths: nil)
    }

    func setShowIgnored(_ value: Bool) {
        guard value != showIgnored else { return }
        showIgnored = value
        tree?.invalidate()
        generation += 1
        inFlight.removeAll()
        loadPending()
        persist()
    }

    // MARK: Git

    private func refreshGit() {
        guard let root = tree?.root else { return }
        gitTask?.cancel()
        let delay = gitDebounce
        gitTask = Task { [git] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let snapshot = await git.snapshot(at: root)
            guard !Task.isCancelled, self.tree?.root == root else { return }
            if snapshot.changes != self.changes { self.changes = snapshot.changes }
            self.branch = snapshot.branch
            self.repositoryRoot = snapshot.repositoryRoot
            if let viewerPath = self.viewer?.path { await self.refreshMarks(for: viewerPath) }
        }
    }

    // MARK: FSEvents

    private func startWatching(_ root: String) {
        watchedRoot = root
        let watcher = GitChangeWatcher(paths: [root], latency: 0.3) { [weak self] paths in
            Task { @MainActor in self?.diskChanged(paths) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedRoot = nil
    }

    /// Lote de eventos de arquivo: filtra o ruído e relê o que importa, com debounce.
    func diskChanged(_ paths: [String]) {
        guard let root = tree?.root else { return }
        let summary = FilesEventFilter.summarize(paths, root: root, showIgnored: showIgnored)
        guard summary.tree || summary.git else { return }
        if summary.tree {
            refreshTask?.cancel()
            let delay = treeDebounce
            refreshTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self.refreshTreeOnly()
            }
        }
        if summary.git { refreshGit() }
        reloadViewerIfNeeded(paths: summary.paths)
    }

    private func refreshTreeOnly() {
        guard let tree else { return }
        let token = generation
        let options = options
        for directory in tree.visibleDirectories {
            let root = tree.root
            let ancestorIgnored = isIgnoredDirectory(directory, in: tree)
            Task { [service] in
                let listing = await service.list(directory: directory, root: root, options: options, ancestorIgnored: ancestorIgnored)
                self.apply(listing, to: directory, root: root, token: token)
            }
        }
    }

    // MARK: Visualizador

    func open(_ path: String, line: Int? = nil) {
        viewerTask?.cancel()
        viewerVersion += 1
        pendingLine = line
        let language = SyntaxLanguage.forFile(named: (path as NSString).lastPathComponent)
        let change = changes.change(for: path)
        viewer = FileViewerState(
            path: path, content: nil, language: language, lineCount: 0, marks: .none, spans: [], change: change, version: viewerVersion,
            highlightLimited: false, targetLine: line)
        search = FileSearchState()
        tree?.reveal(path).forEach { load($0) }
        loadViewerContent(path: path)
    }

    /// Mostra uma pasta na árvore (clique no terminal): fecha o visualizador e expande até ela. `false` se está fora da raiz.
    @discardableResult
    func revealFolder(_ path: String) -> Bool {
        guard let root = tree?.root, path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return false }
        closeViewer()
        tree?.reveal(path + "/_").forEach { load($0) }
        if let tree { expandedByRoot[tree.root] = tree.expanded }
        return true
    }

    func closeViewer() {
        viewerTask?.cancel()
        viewer = nil
        search = FileSearchState()
    }

    private func loadViewerContent(path: String) {
        let language = SyntaxLanguage.forFile(named: (path as NSString).lastPathComponent)
        let version = viewerVersion
        viewerTask = Task { [service, git] in
            let content = await service.read(path: path)
            guard !Task.isCancelled, self.viewer?.path == path else { return }
            var lineCount = 0
            var spans: [SyntaxSpan] = []
            var limited = false
            if case .text(let text, let truncated) = content {
                lineCount = FileReader.lineCount(text)
                spans = await service.highlight(text: text, language: language)
                limited = truncated || (text as NSString).length > SyntaxHighlighter.defaultLimit
            }
            guard !Task.isCancelled, self.viewer?.path == path else { return }
            let change = self.changes.change(for: path)
            var marks = LineChangeMarks.none
            if change == .untracked { marks = .allAdded(lineCount: lineCount) } else if change != nil, let repo = self.repositoryRoot {
                marks = await git.lineMarks(forFile: path, repositoryRoot: repo)
            }
            guard !Task.isCancelled, self.viewer?.path == path else { return }
            self.viewer = FileViewerState(
                path: path, content: content, language: language, lineCount: lineCount, marks: marks, spans: spans, change: change,
                version: version, highlightLimited: limited, targetLine: self.pendingLine)
            self.updateSearchMatches()
        }
    }

    private func refreshMarks(for path: String) async {
        guard var current = viewer, current.path == path else { return }
        let change = changes.change(for: path)
        var marks = LineChangeMarks.none
        if change == .untracked { marks = .allAdded(lineCount: current.lineCount) } else if change != nil, let repo = repositoryRoot {
            marks = await git.lineMarks(forFile: path, repositoryRoot: repo)
        }
        guard viewer?.path == path else { return }
        current = viewer ?? current
        if current.marks != marks || current.change != change {
            current.marks = marks
            current.change = change
            viewer = current
        }
    }

    /// O arquivo aberto mudou no disco (ou o usuário pediu refresh): relê o conteúdo.
    private func reloadViewerIfNeeded(paths: [String]?) {
        guard let path = viewer?.path else { return }
        if let paths, !paths.contains(path) { return }
        pendingLine = nil  // reler não rola de novo para a linha pedida
        viewerVersion += 1
        loadViewerContent(path: path)
    }

    // MARK: Busca

    func setSearchActive(_ active: Bool) {
        search.isActive = active
        if !active {
            search.query = ""
            search.matches = []
            search.current = 0
        }
    }

    func setSearchQuery(_ query: String) {
        search.query = query
        search.current = 0
        updateSearchMatches()
    }

    private func updateSearchMatches() {
        guard search.isActive, !search.query.isEmpty, case .text(let text, _)? = viewer?.content else {
            search.matches = []
            return
        }
        search.matches = CodeSearch.ranges(of: search.query, in: text)
        if search.current >= search.matches.count { search.current = 0 }
    }

    func stepSearch(_ delta: Int) {
        guard !search.matches.isEmpty else { return }
        let count = search.matches.count
        search.current = ((search.current + delta) % count + count) % count
    }

    // MARK: Abrir fora

    func openExternally(_ path: String, target: String? = nil) async throws -> String {
        let url = URL(fileURLWithPath: path)
        if target == "finder" {
            revealInFinder(url)
            return "finder"
        }
        return try await externalOpen(url, target)
    }

    // MARK: Persistência

    func attach(store: RackyStore) async {
        self.store = store
        if let saved = try? await store.uiState(Self.uiStateKey, as: FilesPersistedState.self), saved.showIgnored != showIgnored {
            showIgnored = saved.showIgnored
            tree?.invalidate()
            loadPending()
        }
    }

    private func persist() {
        guard let store else { return }
        let value = FilesPersistedState(showIgnored: showIgnored)
        Task { try? await store.scheduleUIState(Self.uiStateKey, value) }
    }

    // MARK: Ações

    func register(in registry: ActionRegistry, openIn: OpenInController?, overlays: OverlayRouter, elements: UIElementStore) throws {
        func path(_ arg: ActionArgument, _ action: ActionID) throws -> String {
            guard arg.kind == .select, let value = arg.value, !value.isEmpty else {
                throw ActionError.failed(action, message: "expected select(<path>)")
            }
            return value
        }
        try registry.register(.filesOpen) { [unowned self] arg in
            let target = try path(arg, .filesOpen)
            let entry = tree?.listings[(target as NSString).deletingLastPathComponent]?.entries.first { $0.path == target }
            if entry?.isDirectory == true {
                toggleFolder(target)
                return tree?.isExpanded(target) == true ? "expanded" : "collapsed"
            }
            // ⌘-clique abre no editor externo (10-right-panel §2).
            if EventModifiers.held(.command) {
                return try await openExternally(target)
            }
            open(target)
            return "opened"
        }
        try registry.register(.filesOpenExternal) { [unowned self] arg in
            try await openExternally(try path(arg, .filesOpenExternal))
        }
        try registry.register(
            .filesCloseFile,
            enablement: { [unowned self] in viewer == nil ? .disabled(reason: String(localized: "No file is open.", bundle: .module)) : .enabled }
        ) { [unowned self] _ in
            closeViewer()
            return "closed"
        }
        try registry.register(
            .filesTogglePin,
            enablement: { [unowned self] in
                resolution.root == nil ? .disabled(reason: String(localized: "Select a session first.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            togglePin()
            return isPinned ? "pinned" : "following"
        }
        try registry.register(
            .filesShowSessionFolder,
            enablement: { [unowned self] in
                canShowSessionFolder ? .enabled : .disabled(reason: String(localized: "Already showing the session folder.", bundle: .module))
            }
        ) { [unowned self] _ in
            showSessionFolder()
            return resolution.root
        }
        try registry.register(.filesToggleIgnored) { [unowned self] _ in
            setShowIgnored(!showIgnored)
            return showIgnored ? "shown" : "hidden"
        }
        try registry.register(
            .filesRefresh,
            enablement: { [unowned self] in
                tree == nil ? .disabled(reason: String(localized: "Select a session first.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            refresh()
            return nil
        }
        try registry.register(
            .filesFind,
            enablement: { [unowned self] in viewer == nil ? .disabled(reason: String(localized: "Open a file first.", bundle: .module)) : .enabled }
        ) { [unowned self] arg in
            if arg.kind == .set {
                setSearchActive(true)
                setSearchQuery(arg.value ?? "")
            } else {
                setSearchActive(!search.isActive)
            }
            return search.isActive ? "open" : "closed"
        }
        try registry.register(.filesFindNext, enablement: { [unowned self] in search.matches.isEmpty ? .disabled(reason: String(localized: "No results", bundle: .module)) : .enabled }) { [unowned self] _ in
            stepSearch(1)
            return "\(search.current + 1)/\(search.matches.count)"
        }
        try registry.register(.filesFindPrevious, enablement: { [unowned self] in search.matches.isEmpty ? .disabled(reason: String(localized: "No results", bundle: .module)) : .enabled }) { [unowned self] _ in
            stepSearch(-1)
            return "\(search.current + 1)/\(search.matches.count)"
        }
        try registry.register(.filesFindClose) { [unowned self] _ in
            setSearchActive(false)
            return "closed"
        }
        try registry.register(
            .filesCopyPath,
            enablement: { [unowned self] in viewer == nil ? .disabled(reason: String(localized: "No file is open.", bundle: .module)) : .enabled }
        ) { [unowned self] _ in
            guard let path = viewer?.path else { throw ActionError.failed(.filesCopyPath, message: "No file is open.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            toasts?.show(kind: .success, title: String(localized: "Path copied.", bundle: .module))
            return path
        }
        try registry.register(
            .filesOpenIn,
            enablement: { [unowned self] in viewer == nil ? .disabled(reason: String(localized: "No file is open.", bundle: .module)) : .enabled }
        ) { _ in
            let anchor = elements.frame(of: .rightPanelFilesViewerOpenIn) ?? .zero
            let entries = openIn?.fileEntries() ?? []
            let opened = DSMenuPanel.present(router: overlays, registry: registry, name: "filesOpenIn", anchor: anchor, entries: entries)
            return opened ? "opened" : "busy"
        }
        try registry.register(.filesOpenInTarget) { [unowned self] arg in
            guard arg.kind == .select, let target = arg.value, let path = viewer?.path else {
                throw ActionError.failed(.filesOpenInTarget, message: "expected select(<target>) with a file open")
            }
            return try await openExternally(path, target: target)
        }
    }
}
