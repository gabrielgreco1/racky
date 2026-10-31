import Foundation

public enum ManagedResourceKind: String, Sendable, Equatable {
    case container, network, volume
}

/// Recurso Docker do app encontrado por label.
public struct ManagedResource: Sendable, Equatable {
    public var kind: ManagedResourceKind
    public var id: String
    public var name: String
    public var labels: [String: String]

    public var computerID: String? { RackyLabel.value(RackyLabel.computer, in: labels) }
    public var isEphemeral: Bool { RackyLabel.value(RackyLabel.ephemeral, in: labels) == "true" }
}

/// Resultado do cruzamento do inventário com o banco (07 CS-181).
public struct GCPlan: Sendable, Equatable {
    /// Efêmeros de runs terminados: removidos sem perguntar.
    public var removeWithoutAsking: [ManagedResource] = []
    /// Sem linha no SQLite (`orphan`): listados e removidos só com confirmação.
    public var needsConfirmation: [ManagedResource] = []
}

/// GC por labels (07 CS-180/181, 08 AR-408): nunca toca em recurso sem o label pedido.
public struct GarbageCollector: Sendable {
    public let client: DockerClient

    public init(client: DockerClient) { self.client = client }

    /// `["racky.owner=<installId>"]` ou `["racky.test=1"]`.
    public func inventory(labels: [String]) async throws -> [ManagedResource] {
        // GC exige ao menos um label: nunca varrer o daemon inteiro.
        guard !labels.isEmpty else { return [] }
        let queries = [labels]
        var result: [ManagedResource] = []
        var seen = Set<String>()
        func add(_ resource: ManagedResource) {
            if seen.insert("\(resource.kind.rawValue):\(resource.id)").inserted { result.append(resource) }
        }
        for query in queries {
            let filter = ["label": query]
            for container in try await client.listContainers(all: true, filters: filter) {
                add(ManagedResource(kind: .container, id: container.id, name: container.name, labels: container.labels))
            }
            for network in try await client.listNetworks(filters: filter) {
                add(ManagedResource(kind: .network, id: network.id, name: network.name, labels: network.labels))
            }
            for volume in try await client.listVolumes(filters: filter) {
                add(ManagedResource(kind: .volume, id: volume.name, name: volume.name, labels: volume.labels))
            }
        }
        return result
    }

    /// Classifica: computador conhecido no banco = fica. Desconhecido = órfão; se for efêmero e o run terminou
    /// (`finishedComputerIDs`), some sem pergunta.
    public func plan(inventory: [ManagedResource], knownComputerIDs: Set<String>, finishedComputerIDs: Set<String> = []) -> GCPlan {
        var plan = GCPlan()
        for resource in inventory {
            let computer = resource.computerID
            if let computer, knownComputerIDs.contains(computer) { continue }
            if resource.isEphemeral, let computer, finishedComputerIDs.contains(computer) {
                plan.removeWithoutAsking.append(resource)
            } else {
                plan.needsConfirmation.append(resource)
            }
        }
        return plan
    }

    /// Remove na ordem containers, redes, volumes. Devolve o que falhou (o resto foi removido).
    @discardableResult
    public func remove(_ resources: [ManagedResource]) async -> [(ManagedResource, DockerError)] {
        var failures: [(ManagedResource, DockerError)] = []
        let ordered = resources.sorted { Self.order($0.kind) < Self.order($1.kind) }
        for resource in ordered {
            do {
                switch resource.kind {
                case .container: try await client.removeContainer(resource.id, force: true, removeVolumes: false)
                case .network: try await client.removeNetwork(resource.id)
                case .volume: try await client.removeVolume(resource.id)
                }
            } catch let error as DockerError {
                failures.append((resource, error))
            } catch {
                failures.append((resource, .transport("\(error)")))
            }
        }
        return failures
    }

    private static func order(_ kind: ManagedResourceKind) -> Int {
        switch kind {
        case .container: 0
        case .network: 1
        case .volume: 2
        }
    }

    /// Remove tudo de um computador ao fim do run (07 CS-180): containers, rede e volumes efêmeros. Volumes com
    /// `ephemeral=false` (perfil nomeado) nunca são removidos nesse fluxo.
    public func removeComputer(id computerID: String) async throws -> [(ManagedResource, DockerError)] {
        let all = try await inventory(labels: ["\(RackyLabel.computer)=\(computerID)"])
        let victims = all.filter { $0.kind != .volume || $0.isEphemeral }
        return await remove(victims)
    }
}
