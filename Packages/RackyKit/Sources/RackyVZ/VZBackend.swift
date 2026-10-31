import Foundation
import RackyCore
import RackyDocker

// ComputerRuntime do runtime sem Docker: o mínimo que provisionar / entregar segredos / exec / desmontar usam, em protocolos pequenos.
// `ContainerizationBackend` (macOS 26) é o real; os testes usam uma VM falsa. `ComputerHostAccess` (do Docker) não serve de base: ele
// carrega um `DockerClient`, e aqui não existe Engine API, label nem rede nomeada.

/// Um comando a rodar dentro da VM.
public struct VZExecRequest: Sendable, Equatable {
    public var command: [String]
    /// `KEY=VALUE` por cima do ambiente do container (a imagem e o plano).
    public var environment: [String]
    /// `agent`, `egress`, `root`, `uid[:gid]` ou `nil` (root).
    public var user: String?
    public var workingDirectory: String?
    /// Com `false`, o stdin do processo já nasce fechado (como `docker exec` sem `-i`).
    public var attachStdin: Bool

    public init(command: [String], environment: [String] = [], user: String? = nil, workingDirectory: String? = nil, attachStdin: Bool = false) {
        self.command = command; self.environment = environment; self.user = user; self.workingDirectory = workingDirectory; self.attachStdin = attachStdin
    }
}

/// Uma VM de computador em execução.
public protocol RunningVM: Sendable {
    var vmID: String { get }
    /// IP na vmnet compartilhada (informativo; o app NÃO usa o IP para falar com a VM: usa a ponte vsock).
    var ipAddress: String? { get }
    /// Inicia o processo (já com stdin aberto se a chamada escrever). `ComputerExecSession` é a mesma interface do Docker.
    func startProcess(_ request: VZExecRequest) async throws -> any ComputerExecSession
    /// Conexão vsock do Mac para uma porta da VM (o fd do socket).
    func dialVsock(port: UInt32) async throws -> FileHandle
    /// Copia arquivo ou pasta do Mac para a VM (vsock, sem passar pelo virtiofs). Não enxerga tmpfs.
    func copyIn(from source: URL, to guestPath: String) async throws
    /// Copia arquivo ou pasta da VM para o Mac. Não enxerga tmpfs.
    func copyOut(from guestPath: String, to destination: URL) async throws
    /// Para a VM e libera tudo dela (rede, pasta do rootfs). Idempotente; não lança.
    func stop() async
}

/// A imagem pronta para subir VMs: o que `VZAssetStore` entrega ao backend.
public struct VZBootImage: Sendable, Equatable {
    /// Referência da imagem no ImageStore (config: entrypoint, env, usuário).
    public var reference: String
    /// Digest do manifesto: nome do template.
    public var digest: String
    /// `rootfs.ext4` desempacotado uma vez; cada VM é um clonefile dele.
    public var templateRootfs: URL

    public init(reference: String, digest: String, templateRootfs: URL) {
        self.reference = reference; self.digest = digest; self.templateRootfs = templateRootfs
    }
}

/// Cria VMs.
public protocol VZBackend: Sendable {
    /// Sub-rede da vmnet compartilhada (`192.168.64.0/24`): vai em `internal_subnet` do egress para o filtro SSRF bloquear as outras VMs.
    var internalSubnet: String { get async }
    func boot(_ plan: VZVMPlan, image: VZBootImage) async throws -> any RunningVM
    /// Para todas as VMs deste processo.
    func stopAll() async
}

/// Resultado de um comando curto na VM.
public struct VZRunResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: Data
    public var stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

extension RunningVM {
    /// Roda um comando curto até o fim (com stdin opcional) e junta a saída. No prazo, encerra o processo e lança `timedOut`.
    public func run(_ request: VZExecRequest, stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> VZRunResult {
        var request = request
        request.attachStdin = stdin != nil
        let session = try await startProcess(request)
        if let stdin {
            try await session.writeInput(stdin)
            await session.closeInput()
        }
        return try await withThrowingTaskGroup(of: VZRunResult?.self) { group in
            group.addTask {
                var out = Data(), err = Data()
                for try await frame in session.frames {
                    if frame.kind == .stderr { err.append(frame.data) } else { out.append(frame.data) }
                }
                return VZRunResult(exitCode: try await session.finalExitCode(), stdout: out, stderr: err)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                try? await session.terminateGroup(grace: .seconds(1))
                throw VZError.timedOut("command \(request.command.first ?? "?")")
            }
            return result
        }
    }
}

public enum VZError: Error, Equatable, LocalizedError, Sendable {
    case timedOut(String)
    case unavailable(String)
    case bootFailed(String)
    case entitlementMissing
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let what): "\(what) timed out"
        case .unavailable(let why): why
        case .bootFailed(let why): "the computer's virtual machine did not start (\(why))"
        case .entitlementMissing: "this build isn't allowed to run virtual machines (missing com.apple.security.virtualization)"
        case .notReady(let why): why
        }
    }
}
