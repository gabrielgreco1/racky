import RackyDocker
import Foundation

// BK12-T10: o caminho de nuvem do scheduler fica ATRÁS de `ComputerProvisioning`. O `ComputerScheduler` não sabe de hosts: quem decide
// entre Mac e nuvem é `AppComputerProvisioning` (setting `runOn`), e o caminho local não passa por nenhum tipo deste arquivo.

/// Abre o acesso (túnel SSH) a um host já criado. A implementação real sobe `SSHTunnel` + `RemoteHostAccess`; os testes usam um falso.
public protocol HostConnecting: Sendable {
    func connect(_ host: PlacedHost) async throws -> any ComputerHostAccess
    /// O host foi encerrado: derruba o túnel.
    func disconnect(hostID: String) async
}

/// Provisionamento na nuvem: pede o host ao `HostPlacement`, abre o acesso e delega ao provisionador de um host
/// (`DockerComputerProvisioning(host:)` no app). O desmonte devolve a vaga; o host vazio é recolhido pelo pool depois da carência.
public actor CloudComputerProvisioning: ComputerProvisioning {
    private let placement: any HostPlacement
    private let connector: any HostConnecting
    private let make: @Sendable (any ComputerHostAccess) -> any ComputerProvisioning
    private var access: [String: any ComputerHostAccess] = [:]
    private var connecting: [String: Task<any ComputerHostAccess, any Error>] = [:]
    private let check: @Sendable () async throws -> Void

    /// `preflight`: confere a conta antes de pedir host (sessão da AWS vencida falha aqui, com a mensagem de reconectar).
    public init(
        placement: any HostPlacement, connector: any HostConnecting, preflight: @escaping @Sendable () async throws -> Void = {},
        make: @escaping @Sendable (any ComputerHostAccess) -> any ComputerProvisioning
    ) {
        self.placement = placement; self.connector = connector; self.make = make; self.check = preflight
    }

    public func preflight() async throws { try await check() }

    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        let computerID = spec.computerID.uuidString.lowercased()
        let host = try await placement.acquire(computerID: computerID)
        do {
            let hostAccess: any ComputerHostAccess
            if let cached = access[host.id] { hostAccess = cached } else {
                // Um connect por host em voo: o segundo computador do mesmo host espera o primeiro (senão abre outro túnel SSH).
                let task: Task<any ComputerHostAccess, any Error>
                if let running = connecting[host.id] { task = running } else {
                    let connector = connector
                    task = Task { try await connector.connect(host) }
                    connecting[host.id] = task
                }
                defer { connecting[host.id] = nil }
                hostAccess = try await task.value
                access[host.id] = hostAccess
            }
            let handle = try await make(hostAccess).provision(spec)
            let placement = placement
            return ProvisionedHandle(backend: handle.backend) {
                await handle.teardown()
                await hostAccess.releaseForwards(computerID: computerID)
                await placement.release(computerID: computerID)
            }
        } catch {
            await placement.release(computerID: computerID)
            throw error
        }
    }

    /// O pool encerrou o host (`onHostClosed`): esquece o acesso e derruba o túnel.
    public func hostClosed(_ hostID: String) async {
        access.removeValue(forKey: hostID)
        await connector.disconnect(hostID: hostID)
    }
}

/// Provisionamento na nuvem indisponível (provedor sem adaptador real, ex.: `AWSProvider` ainda não implementado): falha ANTES de
/// qualquer coisa, com a mensagem ao usuário. Nunca cai para o Mac em silêncio.
public struct UnavailableCloudProvisioning: ComputerProvisioning {
    public init() {}
    public func preflight() async throws { throw ComputerSetupError.cloudUnavailable }
    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle { throw ComputerSetupError.cloudUnavailable }
}

/// Onde os computadores sobem agora (lido a cada pedido: trocar em Settings vale para o próximo computador).
public enum ComputerRunPlace: Sendable, Equatable { case local, cloud }

/// Rota de nuvem de `AppComputerProvisioning`: `place` lê a setting `runOn`; `provisioning` é o provisionador real da nuvem, ou
/// `nil` quando o provedor escolhido não é `available` e implementado (nesse caso vale `UnavailableCloudProvisioning`).
public struct CloudComputerRoute: Sendable {
    public var place: @Sendable () async -> ComputerRunPlace
    public var provisioning: (any ComputerProvisioning)?

    public init(place: @escaping @Sendable () async -> ComputerRunPlace, provisioning: (any ComputerProvisioning)?) {
        self.place = place; self.provisioning = provisioning
    }

    var effective: any ComputerProvisioning { provisioning ?? UnavailableCloudProvisioning() }
}

/// Provedor que o app sabe usar de verdade: catálogo `available` E adaptador implementado. Hoje a AWS (pelo `aws` CLI do usuário);
/// o provedor falso só existe nos testes.
public enum CloudProviderAvailability {
    public static func implemented(_ id: String) -> Bool {
        guard CloudProviderCatalog.provider(id)?.available == true else { return false }
        return id == "aws"
    }
}
