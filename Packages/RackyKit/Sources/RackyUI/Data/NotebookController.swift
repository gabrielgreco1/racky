import AppKit
import Foundation
import Observation
import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore

/// Notebooks Python da área Data: cada notebook é uma pasta em `~/Library/Application Support/Racky/notebooks/<nome>` com o
/// `.ipynb` e os CSVs dos datasets marcados em `data/`. Um JupyterLab local (via `uv`, que baixa o JupyterLab e o pandas na
/// primeira vez) serve todas as pastas; a tab mostra o lab num web view e, à esquerda, os datasets que entram no notebook.
@MainActor @Observable
public final class NotebookController {
    public enum Status: Equatable {
        case idle
        case starting(String)
        case ready(URL)
        case failed(String)
    }

    public struct Notebook: Equatable, Identifiable {
        public var id: String
        /// Datasets marcados (ids); `loaded` = os que já têm célula no `.ipynb`.
        public var selected: [String]
        public var loaded: [String]
        public var status: Status = .idle
        /// Muda a cada carga para o web view recarregar.
        public var revision = 0
    }

    public private(set) var notebooks: [String: Notebook] = [:]
    public private(set) var server: Status = .idle

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var serverStart: Task<Void, Error>?
    @ObservationIgnored private let datasets: DatasetsController
    @ObservationIgnored private let log = LogFacade(.app, category: "notebooks")

    public init(datasets: DatasetsController) {
        self.datasets = datasets
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Racky/notebooks", isDirectory: true)
    }

    /// Nome do notebook a partir do dataset (só `a-z 0-9 _ -`).
    static func notebookID(for name: String) -> String {
        let cleaned = String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return cleaned.isEmpty ? "notebook" : cleaned
    }

    /// Variável Python do dataset no notebook.
    static func variable(for name: String) -> String {
        let cleaned = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        guard let first = cleaned.first, !first.isNumber else { return "df_" + cleaned }
        return cleaned
    }

    /// Abre (ou reabre) o notebook do dataset: marca o dataset, exporta, escreve o `.ipynb` e garante o servidor.
    public func open(datasetID: String) async throws -> String {
        guard let name = datasets.name(of: datasetID) else { throw ActionError.failed(.datasetNotebook, message: "No such dataset.") }
        let id = Self.notebookID(for: name)
        if notebooks[id] == nil { notebooks[id] = Notebook(id: id, selected: [datasetID], loaded: []) }
        try await apply(id)
        return id
    }

    /// Tab de notebook reaberta depois de reiniciar o app: o estado em memória sumiu, mas a pasta continua. Os datasets com CSV em
    /// `data/` voltam marcados e carregados; sem CSV, o dataset que deu nome ao notebook. Sem pasta nem dataset, nada muda.
    @discardableResult
    public func restore(_ id: String) -> Bool { restore(id, root: Self.root) }

    @discardableResult
    func restore(_ id: String, root: URL) -> Bool {
        guard notebooks[id] == nil else { return true }
        let data = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("data", isDirectory: true)
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [])
        let all = datasets.summaries
        guard !all.isEmpty else { return false }  // datasets ainda carregando: a view tenta de novo quando chegarem
        var found = all.filter { files.contains("\(Self.notebookID(for: $0.dataset.name)).csv") }.map(\.id)
        let loaded = found
        if found.isEmpty { found = all.filter { Self.notebookID(for: $0.dataset.name) == id }.map(\.id) }
        guard !found.isEmpty || FileManager.default.fileExists(atPath: data.deletingLastPathComponent().path) else { return false }
        notebooks[id] = Notebook(id: id, selected: found, loaded: loaded)
        return true
    }

    public func toggle(_ id: String, dataset: String) throws {
        restore(id)
        guard var notebook = notebooks[id] else { throw ActionError.failed(.notebookToggleDataset, message: "No such notebook.") }
        if let index = notebook.selected.firstIndex(of: dataset) { notebook.selected.remove(at: index) } else { notebook.selected.append(dataset) }
        notebooks[id] = notebook
    }

    /// Dataset solto no notebook (arrastado da coluna Data): entra marcado na lista; já estando lá, nada muda.
    public func add(_ id: String, dataset: String) throws {
        restore(id)
        guard var notebook = notebooks[id] else { throw ActionError.failed(.notebookAddDataset, message: "No such notebook.") }
        guard datasets.name(of: dataset) != nil else { throw ActionError.failed(.notebookAddDataset, message: "No such dataset.") }
        guard !notebook.selected.contains(dataset) else { return }
        notebook.selected.append(dataset)
        notebooks[id] = notebook
    }

    /// Exporta os datasets marcados para `data/` e acrescenta ao `.ipynb` uma célula por dataset novo; depois sobe o servidor.
    public func apply(_ id: String) async throws {
        restore(id)
        guard var notebook = notebooks[id] else { throw ActionError.failed(.notebookApply, message: "No such notebook.") }
        guard let store = datasets.store else { throw ActionError.failed(.notebookApply, message: "The data store is not open.") }
        let folder = Self.root.appendingPathComponent(id, isDirectory: true)
        let dataFolder = folder.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        var fresh: [(variable: String, file: String, name: String)] = []
        for datasetID in notebook.selected {
            guard let dataset = try await store.dataset(id: datasetID) else { continue }
            let file = "data/\(Self.notebookID(for: dataset.name)).csv"
            try await DatasetExporter.write(store: store, dataset: dataset, format: .csv, to: folder.appendingPathComponent(file))
            if !notebook.loaded.contains(datasetID) { fresh.append((Self.variable(for: dataset.name), file, dataset.name)) }
        }
        let file = folder.appendingPathComponent("\(id).ipynb")
        try NotebookFile.append(cells: fresh, title: id, to: file)
        notebook.loaded.append(contentsOf: notebook.selected.filter { !notebook.loaded.contains($0) })
        notebook.revision += 1
        notebooks[id] = notebook
        try await ensureServer()
        // Carregar é ver os dados: roda o notebook (contagem de linhas e o começo de cada tabela ficam salvos no `.ipynb`) e só
        // então reabre o JupyterLab, que lê o arquivo novo em vez da versão que tinha aberta.
        notebooks[id]?.status = .starting(String(localized: "Loading the datasets into the notebook…", bundle: .module))
        await Self.execute(file)
        if case .ready(let base) = server { notebooks[id]?.status = .ready(Self.labURL(base: base, notebook: id, token: token)) }
    }

    /// `jupyter nbconvert --execute --inplace` no mesmo ambiente do servidor; uma célula com erro não impede as outras, e uma
    /// falha aqui só deixa o notebook sem as saídas (as células continuam lá para rodar à mão).
    static func execute(_ file: URL) async {
        guard let uv = uvPath() else { return }
        let output = try? await ProcessRunner.run(ProcessRequest(
            executable: URL(fileURLWithPath: uv),
            arguments: [
                "tool", "run", "--from", "jupyterlab", "--with", "pandas", "--with", "matplotlib", "jupyter-nbconvert",
                "--to", "notebook", "--execute", "--inplace", "--allow-errors", "--ExecutePreprocessor.timeout=600", file.lastPathComponent,
            ],
            currentDirectory: file.deletingLastPathComponent(), timeout: .seconds(900)))
        if output?.exitCode != 0 { LogFacade(.app, category: "notebooks").error("notebook run failed") }
    }

    static func labURL(base: URL, notebook: String, token: String) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent("doc/tree/\(notebook)/\(notebook).ipynb"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts.url!
    }

    // MARK: Servidor

    /// `uv` fora do PATH dos apps do Finder: procura nos lugares de instalação comuns.
    nonisolated static func uvPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Uma subida por vez: duas chamadas simultâneas (abrir dois notebooks) esperam a mesma, em vez de matar o servidor uma da outra.
    private func ensureServer() async throws {
        if case .ready = server, process?.isRunning == true { return }
        if let running = serverStart { return try await running.value }
        let task = Task { try await self.startServer() }
        serverStart = task
        defer { serverStart = nil }
        try await task.value
    }

    /// Todo notebook aponta para o servidor atual: porta e token mudam quando ele reinicia.
    private func publishServerStatus() {
        for id in notebooks.keys {
            if case .ready(let base) = server { notebooks[id]?.status = .ready(Self.labURL(base: base, notebook: id, token: token)) } else { notebooks[id]?.status = server }
        }
    }

    private func startServer() async throws {
        guard let uv = Self.uvPath() else {
            server = .failed(String(localized: "Install uv to open notebooks.", bundle: .module))
            throw ActionError.failed(.datasetNotebook, message: "Install uv to open notebooks.")
        }
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        port = Self.freePort()
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        server = .starting(String(localized: "Starting Jupyter… the first time it downloads JupyterLab and pandas.", bundle: .module))
        publishServerStatus()
        // Um servidor que sobrou de uma execução anterior (app encerrado à força) sai antes; e este morre junto com o app: o
        // shell vigia o processo do Racky e, quando ele some (ou o shell recebe TERM), encerra o uv e o Python filho.
        Self.killStale()
        stop()  // um servidor nosso que morreu pela metade não fica para trás
        server = .starting(String(localized: "Starting Jupyter… the first time it downloads JupyterLab and pandas.", bundle: .module))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let watch = #"""
        "$@" & c=$!
        stop() { pkill -TERM -P $c; kill -TERM $c; }
        trap 'stop; exit 0' TERM INT
        while kill -0 \#(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done
        stop
        """#
        task.arguments = [
            "-c", watch, "racky-jupyter",
            uv, "tool", "run", "--from", "jupyterlab", "--with", "pandas", "--with", "matplotlib", "jupyter-lab",
            "--no-browser", "--port", "\(port)", "--ServerApp.port_retries=0", "--ServerApp.ip=127.0.0.1",
            "--ServerApp.root_dir=\(Self.root.path)", "--LabApp.news_url=",
        ]
        task.currentDirectoryURL = Self.root
        // Tema escuro como o app e sem o aviso de notícias do Jupyter (configurações só deste servidor).
        let settings = Self.root.appendingPathComponent(".jupyter-settings", isDirectory: true)
        Self.writeSettings(to: settings)
        var environment = ProcessInfo.processInfo.environment
        environment["JUPYTERLAB_SETTINGS_DIR"] = settings.path
        environment["JUPYTER_TOKEN"] = token  // fora do argv (`ps` não mostra); o Jupyter lê daqui
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        Self.writeOwner(task.processIdentifier)
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let status = base.appendingPathComponent("api/status")
        // Primeira vez baixa JupyterLab e pandas via `uv` (pode levar vários minutos): espera até 15 min, saindo antes se o processo morrer.
        for _ in 0..<1800 {
            if !task.isRunning { break }
            var request = URLRequest(url: status)
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                server = .ready(base)
                publishServerStatus()
                log.publicInfo("jupyter ready")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        server = .failed(String(localized: "Jupyter did not start.", bundle: .module))
        publishServerStatus()
        throw ActionError.failed(.datasetNotebook, message: "Jupyter did not start.")
    }

    static func writeSettings(to folder: URL) {
        let files = [
            "@jupyterlab/apputils-extension/themes.jupyterlab-settings": #"{"theme": "JupyterLab Dark"}"#,
            "@jupyterlab/apputils-extension/notification.jupyterlab-settings": #"{"fetchNews": "false", "checkForUpdates": false}"#,
        ]
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Arquivo que marca o servidor desta pasta de dados: `<pid do app> <pid do shell vigia>`.
    static var ownerFile: URL { root.appendingPathComponent(".server-owner") }

    static func writeOwner(_ shellPID: Int32, to file: URL = ownerFile, appPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        try? Data("\(appPID) \(shellPID)".utf8).write(to: file, options: .atomic)
    }

    /// Encerra o servidor que ESTE app iniciou e ficou órfão (app encerrado à força). Só mexe no processo anotado em `ownerFile`: se o
    /// app dono ainda vive (outra instância com esta pasta) ou o pid não é mais o shell vigia do Jupyter, não toca em nada.
    static func killStale(ownerFile file: URL = ownerFile, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let pids = text.split(separator: " ").compactMap { Int32($0) }
        guard pids.count == 2, pids[0] != ownPID, pids[1] > 1 else { return }
        if kill(pids[0], 0) == 0 || errno == EPERM { return }  // o dono ainda vive: o arquivo é dele
        defer { try? FileManager.default.removeItem(at: file) }
        guard commandLine(of: pids[1])?.contains("racky-jupyter") == true else { return }
        kill(pids[1], SIGTERM)  // o shell vigia encerra o uv e o Python filho
    }

    private static func commandLine(of pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func stop() {
        process?.terminate()
        process = nil
        server = .idle
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: Ações

    /// `openTab(id, inSession)`: `select(<datasetId>|session)` vem de um dataset aberto numa sessão e abre o notebook ali.
    public func register(in registry: ActionRegistry, openTab: @escaping @MainActor (String, Bool) -> Void) throws {
        try registry.register(.datasetNotebook) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard arg.kind == .select, let datasetID = parts.first, !datasetID.isEmpty else {
                throw ActionError.failed(.datasetNotebook, message: "expected select(<datasetId>) or select(<datasetId>|session)")
            }
            let inSession = parts.count == 2 && parts[1] == "session"
            guard let name = datasets.name(of: datasetID) else { throw ActionError.failed(.datasetNotebook, message: "No such dataset.") }
            let id = Self.notebookID(for: name)
            if notebooks[id] == nil { notebooks[id] = Notebook(id: id, selected: [datasetID], loaded: [], status: .starting("")) }
            openTab(id, inSession)
            Task { [weak self] in
                do { _ = try await self?.open(datasetID: datasetID) } catch { self?.notebooks[id]?.status = .failed(error.localizedDescription) }
            }
            return id
        }
        try registry.register(.notebookToggleDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let bar = raw.firstIndex(of: "|") else {
                throw ActionError.failed(.notebookToggleDataset, message: "expected select(<notebookId>|<datasetId>)")
            }
            try toggle(String(raw[..<bar]), dataset: String(raw[raw.index(after: bar)...]))
            return raw
        }
        try registry.register(.notebookAddDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let bar = raw.firstIndex(of: "|") else {
                throw ActionError.failed(.notebookAddDataset, message: "expected select(<notebookId>|<datasetId>)")
            }
            try add(String(raw[..<bar]), dataset: String(raw[raw.index(after: bar)...]))
            return raw
        }
        try registry.register(.notebookApply) { [unowned self] arg in
            guard arg.kind == .select, let id = arg.value else { throw ActionError.failed(.notebookApply, message: "expected select(<notebookId>)") }
            try await apply(id)
            return id
        }
    }
}

/// O `.ipynb` (nbformat 4): cria com um título e o import do pandas; cada dataset novo ganha uma célula que lê o CSV e mostra o começo.
enum NotebookFile {
    static func append(cells fresh: [(variable: String, file: String, name: String)], title: String, to url: URL) throws {
        var notebook: [String: Any]
        if let data = try? Data(contentsOf: url), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            notebook = object
        } else {
            notebook = [
                "nbformat": 4, "nbformat_minor": 5,
                "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3", "language": "python"], "language_info": ["name": "python"]],
                "cells": [
                    markdown("# \(title)\nDatasets your agents collected in Racky, loaded with pandas. Pick more on the left and click **Load**."),
                    code("import pandas as pd\npd.set_option(\"display.max_columns\", 50)"),
                ],
            ]
        }
        var cells = notebook["cells"] as? [[String: Any]] ?? []
        // Um dataset já carregado (o app reabriu e não lembra) não ganha célula repetida: procura o CSV nas células.
        let existing = cells.map { cell -> String in
            if let text = cell["source"] as? String { return text }
            return (cell["source"] as? [String])?.joined() ?? ""
        }.joined(separator: "\n")
        for item in fresh where !existing.contains("\"\(item.file)\"") {
            cells.append(markdown("## \(item.name)"))
            cells.append(code("\(item.variable) = pd.read_csv(\"\(item.file)\")\nprint(len(\(item.variable)), \"rows\")\n\(item.variable).head(20)"))
        }
        notebook["cells"] = cells
        let data = try JSONSerialization.data(withJSONObject: notebook, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func markdown(_ text: String) -> [String: Any] {
        ["cell_type": "markdown", "id": UUID().uuidString.prefix(8).lowercased(), "metadata": [String: Any](), "source": text]
    }

    static func code(_ text: String) -> [String: Any] {
        ["cell_type": "code", "id": UUID().uuidString.prefix(8).lowercased(), "metadata": [String: Any](), "source": text, "outputs": [Any](), "execution_count": NSNull()]
    }
}
