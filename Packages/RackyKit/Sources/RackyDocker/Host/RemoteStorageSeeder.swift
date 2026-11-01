import Foundation

/// Prepara os volumes de um computador num host remoto ANTES de o container subir: dono certo (`/work` do agente, `logs` do egress)
/// e os segredos de tarefa (0400, pasta 0500, dono `agent`). Sem isso o Docker cria volumes novos como root e o agente não escreve.
/// Um container auxiliar descartável monta os três volumes em leitura e escrita; os segredos entram por archive (PUT), o dono por `chown`.
public struct RemoteStorageSeeder: Sendable {
    public struct Volumes: Sendable, Equatable {
        public var work: String
        public var logs: String
        public var secrets: String
        public init(computerID: String) {
            work = "ab-work-\(computerID)"; logs = "ab-logs-\(computerID)"; secrets = "ab-sec-\(computerID)"
        }
    }

    public let client: DockerClient
    public init(client: DockerClient) { self.client = client }

    /// `image` precisa ter `/bin/sh` e `chown` (a do computador tem). `files` = conteúdo atual de `/run/abx-secrets`.
    public func seed(volumes: Volumes, labels: ComputerLabels, image: String, secretFiles: [String: Data], agentUID: Int, egressUID: Int,
                     extraLabels: [String: String] = [:]) async throws {
        let entries = try secretFiles.sorted { $0.key < $1.key }.map { name, data -> TarEntry in
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name != ".." else { throw BoxSecretFilesError.unsafeFileName(name) }
            return TarEntry(path: name, data: data, mode: 0o400)
        }
        var spec = ContainerSpec(name: "\(labels.containerName)-seed", image: image)
        spec.labels = labels.labels(role: .work).merging(extraLabels) { $1 }
        spec.entrypoint = ["/bin/sh", "-c"]
        // Só o necessário: root sem capacidades, com CHOWN/FOWNER/DAC_OVERRIDE para acertar dono e modo.
        spec.command = [
            "chown \(agentUID):\(agentUID) /seed/work && chmod 0755 /seed/work"
                + " && chown -R \(agentUID):\(agentUID) /seed/sec && chmod 0500 /seed/sec && find /seed/sec -type f -exec chmod 0400 {} +"
                + " && chown \(egressUID):\(egressUID) /seed/logs && chmod 0755 /seed/logs"
        ]
        spec.user = "0"
        spec.named = ["\(volumes.work):/seed/work", "\(volumes.logs):/seed/logs", "\(volumes.secrets):/seed/sec"]
        spec.capAdd = ["CHOWN", "FOWNER", "DAC_OVERRIDE"]
        spec.resources = ContainerResources(memoryBytes: 64 << 20, cpus: 0.5, pidsLimit: 64)
        let id = try await client.createContainer(spec)
        do {
            if !entries.isEmpty { try await client.putArchive(id, path: "/seed/sec", tar: TarArchive.create(entries: entries)) }
            try await client.startContainer(id)
            let code = try await client.waitContainer(id, timeout: .seconds(60))
            guard code == 0 else { throw ComputerProvisionerError.provisioningFailed("a preparação dos volumes saiu com \(code)") }
        } catch {
            try? await client.removeContainer(id, force: true)
            throw error
        }
        try await client.removeContainer(id, force: true)
    }
}
