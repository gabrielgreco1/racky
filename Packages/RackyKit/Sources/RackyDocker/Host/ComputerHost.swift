import Foundation

/// Host remoto (VM na nuvem) que roda computadores. Só dados: quem fala com ele é o `ComputerHostAccess`.
public struct RemoteHost: Sendable, Equatable, Codable, Hashable {
    /// Id do provedor (ex.: `i-0abc...`). Entra nos nomes de socket local; só `[A-Za-z0-9._-]`.
    public var id: String
    /// `aws`, `hetzner`... (só rótulo).
    public var provider: String
    public var region: String
    /// IP ou DNS público. O SSH é a única porta de entrada (Docker, admin API e VNC passam pelo túnel; nada é publicado).
    public var address: String
    public var sshUser: String
    public var sshPort: Int

    public init(id: String, provider: String, region: String, address: String, sshUser: String = "racky", sshPort: Int = 22) {
        self.id = id; self.provider = provider; self.region = region; self.address = address; self.sshUser = sshUser; self.sshPort = sshPort
    }
}

/// Onde o container de um computador roda.
public enum ComputerHost: Sendable, Equatable {
    /// Docker local (socket Unix do contexto ativo). Caminho de hoje.
    case local
    case remote(RemoteHost)

    public var isRemote: Bool { if case .remote = self { true } else { false } }
}

/// Como `/work`, os logs e os segredos de tarefa chegam ao container.
public enum ComputerStorage: Sendable, Equatable {
    /// Binds de pastas do próprio host (local: pastas do Mac).
    case hostBinds
    /// Volumes nomeados no host remoto (as pastas do Mac não existem lá); o conteúdo volta por `RunFileSync`.
    case volumes
}

/// Acesso a um host: o cliente Docker, o armazenamento e a ponte das portas publicadas até o Mac.
/// Local = comportamento de sempre; remoto = socket e portas encaminhados por túnel SSH.
public protocol ComputerHostAccess: Sendable {
    var host: ComputerHost { get }
    var client: DockerClient { get }
    var storage: ComputerStorage { get }
    /// Torna a porta publicada pelo Docker no loopback DO HOST (admin API, que também serve o VNC) acessível em `127.0.0.1:<retorno>` no Mac.
    func reach(publishedPort: Int, computerID: String) async throws -> Int
    /// Fecha os encaminhamentos de um computador (fim do run).
    func releaseForwards(computerID: String) async
}

/// Docker local. `reach` é a identidade: a porta publicada já está no loopback do Mac.
public struct LocalHostAccess: ComputerHostAccess {
    public let client: DockerClient
    public var host: ComputerHost { .local }
    public var storage: ComputerStorage { .hostBinds }

    public init(client: DockerClient) { self.client = client }

    public func reach(publishedPort: Int, computerID: String) async throws -> Int { publishedPort }
    public func releaseForwards(computerID: String) async {}
}

/// Docker de uma VM remota por túnel SSH (`SSHTunnel`): a Engine API sai por um socket local encaminhado e cada computador ganha
/// um `-L` próprio para a admin API/VNC.
public struct RemoteHostAccess: ComputerHostAccess {
    public let remote: RemoteHost
    public let tunnel: SSHTunnel
    public var host: ComputerHost { .remote(remote) }
    public var storage: ComputerStorage { .volumes }
    public var client: DockerClient { tunnel.client }

    public init(remote: RemoteHost, tunnel: SSHTunnel) { self.remote = remote; self.tunnel = tunnel }

    public func reach(publishedPort: Int, computerID: String) async throws -> Int {
        try await tunnel.forward(remotePort: publishedPort, key: computerID)
    }

    public func releaseForwards(computerID: String) async { await tunnel.cancelForwards(key: computerID) }
}
