import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Synchronization

/// Fase e andamento de um `git clone --progress` (F24).
public struct CloneProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case starting, counting, compressing, receiving, resolving, updatingFiles

        public var label: String {
            switch self {
            case .starting: "Starting"
            case .counting: "Counting objects"
            case .compressing: "Compressing objects"
            case .receiving: "Receiving objects"
            case .resolving: "Resolving deltas"
            case .updatingFiles: "Updating files"
            }
        }
    }

    public var phase: Phase
    /// Percentual da fase atual (0...100); `nil` quando o git não informa.
    public var percent: Int?

    public init(phase: Phase, percent: Int? = nil) {
        self.phase = phase
        self.percent = percent
    }

    /// Andamento geral (0...1) para a barra: receber objetos ocupa 0–85 %, resolver deltas 85–95 %, extrair arquivos 95–100 %.
    public var overall: Double {
        let p = Double(max(0, min(100, percent ?? 0))) / 100
        switch phase {
        case .starting, .counting: return 0.02 * p
        case .compressing: return 0.02 + 0.03 * p
        case .receiving: return 0.05 + 0.80 * p
        case .resolving: return 0.85 + 0.10 * p
        case .updatingFiles: return 0.95 + 0.05 * p
        }
    }

    /// `Receiving objects 42%`.
    public var text: String { percent.map { "\(phase.label) \($0)%" } ?? phase.label }
}

/// Lê as linhas de progresso do `git clone --progress` (stderr, separadas por `\r` e `\n`).
public enum GitCloneProgressParser {
    public static func parse(line: String) -> CloneProgress? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // `remote: Counting objects: 100% (3/3), done.` e `Receiving objects:  42% (5/12), 1.2 MiB | 2 MiB/s`.
        let cleaned = text.hasPrefix("remote:") ? String(text.dropFirst("remote:".count)).trimmingCharacters(in: .whitespaces) : text
        let table: [(String, CloneProgress.Phase)] = [
            ("Enumerating objects", .counting), ("Counting objects", .counting), ("Compressing objects", .compressing),
            ("Receiving objects", .receiving), ("Resolving deltas", .resolving), ("Updating files", .updatingFiles),
        ]
        for (prefix, phase) in table where cleaned.hasPrefix(prefix) {
            return CloneProgress(phase: phase, percent: percent(in: cleaned))
        }
        return nil
    }

    private static func percent(in text: String) -> Int? {
        guard let pct = text.firstIndex(of: "%") else { return nil }
        let digits = text[..<pct].reversed().prefix(while: { $0.isNumber })
        return Int(String(digits.reversed()))
    }

    /// Junta pedaços de stderr em linhas completas (o git usa `\r` para reescrever a linha de progresso).
    public struct LineSplitter: Sendable {
        private var buffer = ""
        public init() {}

        public mutating func feed(_ chunk: String) -> [String] {
            buffer += chunk
            var lines: [String] = []
            while let index = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
                let line = String(buffer[..<index])
                buffer.removeSubrange(...index)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }

        public mutating func flush() -> String? {
            defer { buffer = "" }
            return buffer.isEmpty ? nil : buffer
        }
    }
}

public enum CloneError: Error, Sendable, Equatable, LocalizedError {
    case gitNotInstalled
    case invalidReference(String)
    case notFound
    case authenticationRequired
    case network
    case destinationConflict(path: String)
    case cancelled
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotInstalled: "Git isn't installed."
        case .invalidReference: "That doesn't look like a repository URL or owner/repo."
        case .notFound: "Repository not found. If it is private, log in to GitHub."
        case .authenticationRequired: "GitHub needs you to log in to clone this repository."
        case .network: "Couldn't reach the server."
        case .destinationConflict(let path):
            "A folder named \(URL(fileURLWithPath: path).lastPathComponent) already exists and isn't this repository."
        case .cancelled: "Clone cancelled."
        case .timedOut: "The clone took too long."
        case .failed(let detail): detail.isEmpty ? "Couldn't clone the repository." : detail
        }
    }
}

public struct CloneResult: Sendable, Equatable {
    public let destination: URL
    /// A pasta já existia com o mesmo remote: nada foi clonado.
    public let alreadyExisted: Bool
    public let project: Project
}

/// Executa `git clone` com stderr em fluxo. Produção: `GitCloneProcessRunner`; testes trocam por um fake.
public protocol GitCloneRunning: Sendable {
    func clone(arguments: [String], environment: [String: String], onStderr: @escaping @Sendable (String) -> Void) async throws -> GitCommandResult
}

public struct GitCloneProcessRunner: GitCloneRunning {
    public let executableURL: URL?
    public let timeout: Duration

    public init(executableURL: URL? = GitProcessRunner.findExecutable(), timeout: Duration = .seconds(3600)) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func clone(arguments: [String], environment: [String: String], onStderr: @escaping @Sendable (String) -> Void) async throws -> GitCommandResult {
        guard let executableURL else { throw GitError.gitNotInstalled }
        let request = ProcessRequest(
            executable: executableURL, arguments: arguments, environment: environment, timeout: timeout,
            maxOutputBytes: 256 * 1024, onStderrChunk: { onStderr(String(decoding: $0, as: UTF8.self)) })
        do {
            let output = try await ProcessRunner.run(request)
            return GitCommandResult(exitCode: output.exitCode, stdout: output.stdoutString, stderr: GitHubRedaction.redact(output.stderrString))
        } catch let error as ProcessRunnerError {
            switch error {
            case .timedOut: throw GitError.timedOut(operation: "clone")
            case .cancelled: throw GitError.cancelled
            case .launchFailed(let detail): throw GitError.launchFailed(detail)
            }
        }
    }
}

/// Clona um repositório para `<raiz>/<nome>` e o registra como projeto (F24). A credencial vem do `gh` já configurado:
/// o clone por https usa `gh auth git-credential` como helper só nesse comando (sem tocar na configuração do usuário);
/// SSH usa o agente e as chaves do usuário, sem prompts. Cancelar remove o que o clone criou.
public struct RepoCloner: Sendable {
    private let runner: any GitCloneRunning
    private let git: GitService
    private let ghExecutable: URL?
    /// Registra a pasta como projeto (`ProjectService.addProject` na produção; a UI usa o seu para toast e sidebar).
    public typealias Register = @Sendable (URL) async throws -> Project
    private let register: Register

    public init(runner: any GitCloneRunning = GitCloneProcessRunner(), git: GitService = GitService(),
                ghExecutable: URL? = GitHubProcessRunner.findExecutable(), register: @escaping Register) {
        self.runner = runner
        self.git = git
        self.ghExecutable = ghExecutable
        self.register = register
    }

    public init(runner: any GitCloneRunning = GitCloneProcessRunner(), git: GitService = GitService(),
                ghExecutable: URL? = GitHubProcessRunner.findExecutable(), projects: ProjectService) {
        self.init(runner: runner, git: git, ghExecutable: ghExecutable) { url in try await projects.addProject(folder: url).project }
    }

    /// `root` é a pasta de projetos já com `~` expandido. Lança `CloneError`.
    public func clone(_ reference: RepoReference, into root: URL, progress: @escaping @Sendable (CloneProgress) -> Void) async throws -> CloneResult {
        let fm = FileManager.default
        progress(CloneProgress(phase: .starting))
        let destination = try await resolveDestination(for: reference, root: root)
        if destination.existing {
            progress(CloneProgress(phase: .updatingFiles, percent: 100))
            return CloneResult(destination: destination.url, alreadyExisted: true, project: try await register(destination.url))
        }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
            throw CloneError.failed("Couldn't create \(root.path).")
        }
        let createdByUs = !fm.fileExists(atPath: destination.url.path)

        let splitter = Mutex(GitCloneProgressParser.LineSplitter())
        let result: GitCommandResult
        do {
            try Task.checkCancellation()
            result = try await runner.clone(arguments: arguments(for: reference, destination: destination.url), environment: environment(for: reference)) { chunk in
                for line in splitter.withLock({ $0.feed(chunk) }) {
                    if let parsed = GitCloneProgressParser.parse(line: line) { progress(parsed) }
                }
            }
        } catch is CancellationError {
            cleanup(destination.url, createdByUs: createdByUs)
            throw CloneError.cancelled
        } catch let error as GitError {
            cleanup(destination.url, createdByUs: createdByUs)
            switch error {
            case .gitNotInstalled: throw CloneError.gitNotInstalled
            case .cancelled: throw CloneError.cancelled
            case .timedOut: throw CloneError.timedOut
            default: throw CloneError.failed(String(describing: error))
            }
        }
        if Task.isCancelled {
            cleanup(destination.url, createdByUs: createdByUs)
            throw CloneError.cancelled
        }
        guard result.succeeded else {
            cleanup(destination.url, createdByUs: createdByUs)
            throw Self.classify(stderr: result.stderr)
        }
        do {
            let project = try await register(destination.url)
            return CloneResult(destination: destination.url, alreadyExisted: false, project: project)
        } catch {
            // O repositório está no disco; só o registro falhou. A pasta fica (o usuário pode adicioná-la à mão).
            throw CloneError.failed("Cloned, but couldn't add the project: \(error.localizedDescription)")
        }
    }

    // MARK: Destino

    private struct Destination {
        var url: URL
        var existing: Bool
    }

    /// `<raiz>/<nome>`; se existe com o mesmo remote, é ele; se existe com outra coisa, tenta `<nome>-<dono>`; senão conflito.
    private func resolveDestination(for reference: RepoReference, root: URL) async throws -> Destination {
        var candidates = [root.appendingPathComponent(reference.name, isDirectory: true)]
        if let owner = reference.owner { candidates.append(root.appendingPathComponent("\(reference.name)-\(owner)", isDirectory: true)) }
        let fm = FileManager.default
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return Destination(url: candidate, existing: false) }
            guard isDirectory.boolValue else { continue }
            if let remote = try? await git.remoteURL(in: candidate), Self.sameRemote(remote, reference) {
                return Destination(url: candidate, existing: true)
            }
            if ((try? fm.contentsOfDirectory(atPath: candidate.path)) ?? ["x"]).isEmpty {
                return Destination(url: candidate, existing: false)
            }
        }
        throw CloneError.destinationConflict(path: candidates[0].path)
    }

    /// Compara remotes ignorando esquema (https, ssh, scp), `.git` e maiúsculas do GitHub.
    static func sameRemote(_ remote: String, _ reference: RepoReference) -> Bool {
        if let a = GitHubRemoteParser.parse(remote), let b = GitHubRemoteParser.parse(reference.cloneURL) {
            return a.host == b.host && a.owner.lowercased() == b.owner.lowercased() && a.name.lowercased() == b.name.lowercased()
        }
        return remote.trimmingCharacters(in: .whitespacesAndNewlines) == reference.cloneURL
    }

    private func cleanup(_ url: URL, createdByUs: Bool) {
        guard createdByUs else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Comando

    func arguments(for reference: RepoReference, destination: URL) -> [String] {
        var args: [String] = []
        if reference.usesHTTPS, let host = reference.host, let gh = ghExecutable {
            // O valor vazio zera os helpers anteriores desse host; depois entra o do `gh`. Só vale para este processo.
            let key = "credential.https://\(host).helper"
            args += ["-c", "\(key)=", "-c", "\(key)=!\(Self.shellQuoted(gh.path)) auth git-credential"]
        }
        args += ["clone", "--progress", "--", reference.cloneURL, destination.path]
        return args
    }

    func environment(for reference: RepoReference) -> [String: String] {
        var env = [
            "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", "GIT_ASKPASS": "/usr/bin/true", "GCM_INTERACTIVE": "never",
            "GH_PROMPT_DISABLED": "1",
        ]
        if !reference.usesHTTPS { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" }
        return env
    }

    private static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func classify(stderr: String) -> CloneError {
        let lower = stderr.lowercased()
        if lower.contains("repository not found") || (lower.contains("does not appear to be a git repository") && lower.contains("not found")) {
            return .notFound
        }
        if lower.contains("authentication failed") || lower.contains("could not read username") || lower.contains("could not read password")
            || lower.contains("permission denied") || lower.contains("terminal prompts disabled") || lower.contains("error: 403") {
            return .authenticationRequired
        }
        if lower.contains("could not resolve host") || lower.contains("unable to access") || lower.contains("connection timed out")
            || lower.contains("network is unreachable") || lower.contains("connection refused") {
            return .network
        }
        let fatal = stderr.split(whereSeparator: \.isNewline).last(where: { $0.lowercased().hasPrefix("fatal:") || $0.lowercased().hasPrefix("error:") })
        let detail = fatal.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return .failed(detail.count > 200 ? String(detail.prefix(200)) : detail)
    }
}
