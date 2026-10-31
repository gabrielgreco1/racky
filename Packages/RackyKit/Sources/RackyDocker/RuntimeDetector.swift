import CryptoKit
import Foundation

public enum DockerRuntimeKind: String, Sendable, Equatable, CaseIterable {
    case desktop, orbstack, colima, other

    /// Comando de "Start Docker" mostrado quando o runtime está parado (07 CS-104). O app nunca instala nada.
    public var startCommand: [String]? {
        switch self {
        case .desktop: ["open", "-a", "Docker"]
        case .orbstack: ["orb", "start"]
        case .colima: ["colima", "start"]
        case .other: nil
        }
    }
}

/// De onde veio o endpoint do runtime.
public enum DockerRuntimeSource: Sendable, Equatable {
    case dockerHostEnvironment
    case activeContext(name: String)
    case knownSocket
}

public struct DockerRuntime: Sendable, Equatable {
    public var kind: DockerRuntimeKind
    public var socketPath: String
    public var source: DockerRuntimeSource

    public init(kind: DockerRuntimeKind, socketPath: String, source: DockerRuntimeSource) {
        self.kind = kind
        self.socketPath = socketPath
        self.source = source
    }
}

/// Runtime validado com `_ping`, `/version` e `/info`.
public struct DetectedRuntime: Sendable, Equatable {
    public var runtime: DockerRuntime
    public var version: DockerVersion
    public var info: DockerInfo
    /// Arquitetura verificada é arm64; amd64 aparece como `Unverified` (07 CS-122).
    public var isVerifiedArchitecture: Bool { ["aarch64", "arm64"].contains(info.architecture.lowercased()) }
    public var capacity: VMCapacity { VMCapacity(memTotalBytes: info.memTotal, cpuCount: info.cpuCount) }
}

/// Detecção do runtime em ordem (07 CS-101), sem chamar o CLI e sem depender do PATH:
/// 1. `DOCKER_HOST` do ambiente de login (só `unix://`);
/// 2. contexto ativo: `DOCKER_CONTEXT` ou `currentContext` de `~/.docker/config.json`, com o endpoint em
///    `~/.docker/contexts/meta/<sha256 do nome>/meta.json` (equivale a `docker context inspect`);
/// 3. sockets conhecidos: Docker Desktop, OrbStack, `~/.colima/<perfil>/docker.sock` e `/var/run/docker.sock`.
public struct RuntimeDetector: Sendable {
    public var environment: [String: String]
    public var homeDirectory: URL
    private let fileExists: @Sendable (String) -> Bool
    private let readFile: @Sendable (String) -> Data?
    private let listDirectory: @Sendable (String) -> [String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(environment: environment, homeDirectory: homeDirectory,
                  fileExists: { FileManager.default.fileExists(atPath: $0) },
                  readFile: { FileManager.default.contents(atPath: $0) },
                  listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
    }

    /// Para testes com sistema de arquivos falso.
    public init(environment: [String: String], homeDirectory: URL, fileExists: @escaping @Sendable (String) -> Bool,
                readFile: @escaping @Sendable (String) -> Data?, listDirectory: @escaping @Sendable (String) -> [String]) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
        self.readFile = readFile
        self.listDirectory = listDirectory
    }

    private var dockerConfigDirectory: String {
        environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory.appendingPathComponent(".docker").path
    }

    /// `unix:///path` -> `/path`. Outros esquemas (tcp, ssh) não são suportados.
    static func socketPath(fromEndpoint host: String) -> String? {
        guard host.hasPrefix("unix://") else { return nil }
        let path = String(host.dropFirst("unix://".count))
        return path.hasPrefix("/") ? path : nil
    }

    static func contextDirectoryName(_ context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Nome do contexto ativo (`DOCKER_CONTEXT`, senão `currentContext`), ou `nil` para o `default`.
    public func activeContextName() -> String? {
        if let name = environment["DOCKER_CONTEXT"], !name.isEmpty { return name == "default" ? nil : name }
        guard let data = readFile(dockerConfigDirectory + "/config.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["currentContext"] as? String, !name.isEmpty, name != "default" else { return nil }
        return name
    }

    /// Endpoint do contexto (`docker context inspect <nome>` lido dos arquivos).
    public func endpoint(ofContext name: String) -> String? {
        let meta = dockerConfigDirectory + "/contexts/meta/\(Self.contextDirectoryName(name))/meta.json"
        guard let data = readFile(meta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoints = object["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String else { return nil }
        return host
    }

    public static func classify(socketPath: String, contextName: String? = nil) -> DockerRuntimeKind {
        let lower = socketPath.lowercased()
        let context = contextName?.lowercased() ?? ""
        if lower.contains("/.orbstack/") || context.contains("orbstack") { return .orbstack }
        if lower.contains("/.colima/") || context.contains("colima") { return .colima }
        if lower.contains("/.docker/run/") || context.contains("desktop") || lower.contains("docker.raw.sock") { return .desktop }
        return .other
    }

    /// Candidatos em ordem de prioridade, sem repetir caminho. Só inclui sockets que existem, exceto os do
    /// ambiente e do contexto (esses são intenção explícita e entram mesmo ausentes, para o erro nomear o motivo).
    public func candidates() -> [DockerRuntime] {
        var result: [DockerRuntime] = []
        var seen = Set<String>()
        func add(_ path: String, _ source: DockerRuntimeSource, context: String? = nil, requireExists: Bool) {
            guard !seen.contains(path), !requireExists || fileExists(path) else { return }
            seen.insert(path)
            result.append(DockerRuntime(kind: Self.classify(socketPath: path, contextName: context), socketPath: path, source: source))
        }
        if let host = environment["DOCKER_HOST"], let path = Self.socketPath(fromEndpoint: host) {
            add(path, .dockerHostEnvironment, requireExists: false)
        }
        if let name = activeContextName(), let host = endpoint(ofContext: name), let path = Self.socketPath(fromEndpoint: host) {
            add(path, .activeContext(name: name), context: name, requireExists: false)
        }
        let home = homeDirectory.path
        add(home + "/.docker/run/docker.sock", .knownSocket, requireExists: true)
        add(home + "/.orbstack/run/docker.sock", .knownSocket, requireExists: true)
        let colimaRoot = home + "/.colima"
        for profile in listDirectory(colimaRoot).sorted(by: { $0 == "default" ? true : ($1 == "default" ? false : $0 < $1) }) {
            add("\(colimaRoot)/\(profile)/docker.sock", .knownSocket, requireExists: true)
        }
        add("/var/run/docker.sock", .knownSocket, requireExists: true)
        return result
    }

    /// Valida os candidatos em ordem e devolve o primeiro que responde. `.runtimeUnavailable` quando nenhum responde (CS-104).
    public func detect() async throws -> DetectedRuntime {
        let all = candidates()
        guard !all.isEmpty else {
            throw DockerError.runtimeUnavailable("nenhum socket Docker encontrado (DOCKER_HOST, contexto ativo, sockets conhecidos)")
        }
        var failures: [String] = []
        for candidate in all {
            let client = DockerClient(socketPath: candidate.socketPath, defaultTimeout: .seconds(5))
            do {
                try await client.ping()
                let version = try await client.version()
                let info = try await client.info()
                var runtime = candidate
                // O nome do runtime também aparece em `/info` (OrbStack, Colima): refina o tipo.
                let hint = (info.name + " " + info.operatingSystem).lowercased()
                if hint.contains("orbstack") { runtime.kind = .orbstack } else if hint.contains("colima") { runtime.kind = .colima }
                else if hint.contains("docker desktop") { runtime.kind = .desktop }
                return DetectedRuntime(runtime: runtime, version: version, info: info)
            } catch {
                failures.append("\(candidate.socketPath): \(error)")
            }
        }
        throw DockerError.runtimeUnavailable("nenhum runtime respondeu: " + failures.joined(separator: "; "))
    }
}
