import Foundation
import RackyCore
import RackyDocker
import Synchronization

/// Usuários da imagem do computador (os mesmos de `ComputerProvisioner`): `agent` 10001 e `egress` 10003.
public struct VZUser: Sendable, Equatable {
    public var uid: UInt32
    public var gid: UInt32

    public init(uid: UInt32, gid: UInt32) { self.uid = uid; self.gid = gid }

    /// `agent`, `egress`, `root`/`nil`, `uid` ou `uid:gid`. Nome desconhecido = `nil` (quem chama recusa).
    public static func resolve(_ name: String?) -> VZUser? {
        guard let name, !name.isEmpty, name != "root" else { return VZUser(uid: 0, gid: 0) }
        switch name {
        case ComputerProvisioner.agentUser: return VZUser(uid: 10001, gid: 10001)
        case ComputerProvisioner.egressUser: return VZUser(uid: 10003, gid: 10003)
        default:
            let parts = name.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let uid = UInt32(parts[0]) else { return nil }
            return VZUser(uid: uid, gid: parts.count == 2 ? (UInt32(parts[1]) ?? uid) : uid)
        }
    }
}

/// Exec "matável": o mesmo wrapper do Docker (`echo $$ > pidfile; exec cmd`) deixa o processo líder do próprio grupo, e o desligamento
/// manda o sinal ao grupo por um segundo exec (S9). Delega o resto à sessão crua da VM.
public final class VZGroupedExecSession: ComputerExecSession {
    private let raw: any ComputerExecSession
    private let vm: any RunningVM
    private let pidFile: String
    private let finished = Mutex(false)

    init(raw: any ComputerExecSession, vm: any RunningVM, pidFile: String) {
        self.raw = raw
        self.vm = vm
        self.pidFile = pidFile
    }

    public var frames: AsyncThrowingStream<DockerStreamFrame, any Error> { raw.frames }
    public func writeInput(_ data: Data) async throws { try await raw.writeInput(data) }
    public func closeInput() async { await raw.closeInput() }

    public func finalExitCode() async throws -> Int {
        let code = try await raw.finalExitCode()
        finished.withLock { $0 = true }
        return code
    }

    private func signalGroup(_ signal: String) async {
        let script = "p=$(cat \"$0\" 2>/dev/null) || exit 0; kill -s \"$1\" -- \"-$p\" 2>/dev/null || kill -s \"$1\" \"$p\" 2>/dev/null; exit 0"
        _ = try? await vm.run(VZExecRequest(command: ["/bin/sh", "-c", script, pidFile, signal]), timeout: .seconds(10))
    }

    /// SIGTERM no grupo; se ainda estiver rodando depois de `grace`, SIGKILL.
    public func terminateGroup(grace: Duration) async throws {
        await signalGroup("TERM")
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if finished.withLock({ $0 }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if finished.withLock({ $0 }) { return }
        await signalGroup("KILL")
        try? await raw.terminateGroup(grace: .milliseconds(200))
    }
}

/// `ComputerExecTransport` de uma VM: exec como `agent`/`egress` dentro dela e regravação da config do egress por `abx-provision`.
public struct VZExecTransport: ComputerExecTransport {
    public let vm: any RunningVM

    public init(vm: any RunningVM) { self.vm = vm }

    public func startExec(_ spec: ExecSpec) async throws -> any ComputerExecSession {
        var command = spec.command
        var pidFile: String?
        if spec.killableGroup {
            let file = "/tmp/.abx-exec-\(UUID().uuidString.lowercased())"
            pidFile = file
            command = ["/bin/sh", "-c", "echo $$ > \"$0\"; exec \"$@\"", file] + spec.command
        }
        let raw = try await vm.startProcess(VZExecRequest(command: command, environment: spec.environment, user: spec.user, workingDirectory: spec.workingDirectory, attachStdin: spec.attachStdin))
        guard let pidFile else { return raw }
        return VZGroupedExecSession(raw: raw, vm: vm, pidFile: pidFile)
    }

    public func rewriteConfig(_ config: EgressConfigFile, proxyCA: String?) async throws {
        try await VZProvisionPayload.deliver(config: config, proxyCA: proxyCA, token: nil, to: vm)
    }
}

/// Entrega de segredos ao computador: o mesmo `abx-provision` por stdin do Docker (nada em env/argv/disco do Mac). O tmpfs
/// `/run/racky` é invisível para `copyIn`/`copyOut`, então o exec com stdin é o único caminho (achado do spike).
public enum VZProvisionPayload {
    public static func deliver(config: EgressConfigFile, proxyCA: String?, token: String?, to vm: any RunningVM) async throws {
        let payload = try ComputerProvisioner.provisionPayload(config: config, proxyCA: proxyCA, token: token)
        let result = try await vm.run(VZExecRequest(command: ["abx-provision"], user: ComputerProvisioner.egressUser), stdin: payload)
        guard result.exitCode == 0 else {
            throw ComputerProvisionerError.provisioningFailed("abx-provision saiu com \(result.exitCode): \(result.stderrString.prefix(200))")
        }
    }
}
