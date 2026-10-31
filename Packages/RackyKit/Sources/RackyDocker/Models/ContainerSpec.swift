import Foundation

/// Valor JSON mínimo para montar corpos da Engine API sem `Any`.
enum JSONValue: Sendable, Equatable, Encodable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
    static func map(_ values: [String: String]) -> JSONValue { .object(values.mapValues { .string($0) }) }
}

/// Limites de recursos (07 §2.4). `--memory` não reserva memória; a admissão usa a estimativa (CS-130).
public struct ContainerResources: Sendable, Equatable {
    public var memoryBytes: Int64?
    public var cpus: Double?
    public var pidsLimit: Int64?
    public init(memoryBytes: Int64? = nil, cpus: Double? = nil, pidsLimit: Int64? = nil) {
        self.memoryBytes = memoryBytes
        self.cpus = cpus
        self.pidsLimit = pidsLimit
    }
}

/// Hardening de 07 CS-114: `--read-only`, `--cap-drop ALL`, `no-new-privileges`, `--init`, sem `--privileged`.
public struct ContainerHardening: Sendable, Equatable {
    public var readOnlyRootfs: Bool
    public var dropAllCapabilities: Bool
    public var noNewPrivileges: Bool
    public var useInit: Bool
    public init(readOnlyRootfs: Bool = true, dropAllCapabilities: Bool = true, noNewPrivileges: Bool = true, useInit: Bool = true) {
        self.readOnlyRootfs = readOnlyRootfs
        self.dropAllCapabilities = dropAllCapabilities
        self.noNewPrivileges = noNewPrivileges
        self.useInit = useInit
    }
    public static let standard = ContainerHardening()
}

public struct ContainerNetworkAttachment: Sendable, Equatable {
    public var network: String
    public var aliases: [String]
    public init(network: String, aliases: [String] = []) {
        self.network = network
        self.aliases = aliases
    }
}

public struct PublishedPort: Sendable, Equatable {
    /// `"3128/tcp"`.
    public var containerPort: String
    public var hostIP: String
    /// Vazio = porta aleatória escolhida pelo daemon (lida depois via inspect).
    public var hostPort: String
    public init(containerPort: String, hostIP: String = "127.0.0.1", hostPort: String = "") {
        self.containerPort = containerPort
        self.hostIP = hostIP
        self.hostPort = hostPort
    }
}

public struct ContainerHealthcheck: Sendable, Equatable {
    public var test: [String]
    public var interval: Duration
    public var timeout: Duration
    public var retries: Int
    public var startPeriod: Duration
    public init(test: [String], interval: Duration = .seconds(10), timeout: Duration = .seconds(3), retries: Int = 3, startPeriod: Duration = .seconds(0)) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }
}

/// Descrição de um container a criar. `body()` gera o JSON de `POST /containers/create`.
public struct ContainerSpec: Sendable, Equatable {
    /// Nome determinístico (`ab-<computerId8>-runtime`, 07 CS-116).
    public var name: String
    public var image: String
    public var command: [String]?
    public var entrypoint: [String]?
    /// `KEY=VALUE`. Nunca token da box (T9).
    public var environment: [String] = []
    public var user: String?
    public var workingDirectory: String?
    public var labels: [String: String] = [:]
    public var hostname: String?
    public var openStdin = false
    public var tty = false
    public var stopSignal: String?
    public var stopTimeoutSeconds: Int?
    public var resources = ContainerResources()
    public var hardening = ContainerHardening.standard
    /// Ponto de montagem -> opções (`rw,noexec,nosuid,size=64m,uid=10001`).
    public var tmpfs: [String: String] = [:]
    /// `host:container[:ro]`.
    public var binds: [String] = []
    public var named: [String] = []
    public var network: ContainerNetworkAttachment?
    public var publishedPorts: [PublishedPort] = []
    public var extraHosts: [String] = []
    public var healthcheck: ContainerHealthcheck?
    /// Capacidades acrescentadas depois do `CapDrop ALL` (P24: só o necessário ao supervisor do computador).
    public var capAdd: [String] = []

    public init(name: String, image: String, command: [String]? = nil) {
        self.name = name
        self.image = image
        self.command = command
    }

    func body() -> JSONValue {
        var root: [String: JSONValue] = ["Image": .string(image), "Labels": .map(labels)]
        if let command { root["Cmd"] = .strings(command) }
        if let entrypoint { root["Entrypoint"] = .strings(entrypoint) }
        if !environment.isEmpty { root["Env"] = .strings(environment) }
        if let user { root["User"] = .string(user) }
        if let workingDirectory { root["WorkingDir"] = .string(workingDirectory) }
        if let hostname { root["Hostname"] = .string(hostname) }
        if openStdin { root["OpenStdin"] = .bool(true) }
        if tty { root["Tty"] = .bool(true) }
        if let stopSignal { root["StopSignal"] = .string(stopSignal) }
        if let stopTimeoutSeconds { root["StopTimeout"] = .int(Int64(stopTimeoutSeconds)) }
        if !publishedPorts.isEmpty {
            var exposed: [String: JSONValue] = [:]
            for port in publishedPorts { exposed[port.containerPort] = .object([:]) }
            root["ExposedPorts"] = .object(exposed)
        }
        if let healthcheck {
            func nanos(_ d: Duration) -> Int64 { d.components.seconds * 1_000_000_000 + d.components.attoseconds / 1_000_000_000 }
            root["Healthcheck"] = .object([
                "Test": .strings(healthcheck.test), "Interval": .int(nanos(healthcheck.interval)), "Timeout": .int(nanos(healthcheck.timeout)),
                "Retries": .int(Int64(healthcheck.retries)), "StartPeriod": .int(nanos(healthcheck.startPeriod)),
            ])
        }

        var host: [String: JSONValue] = ["RestartPolicy": .object(["Name": .string("no")])]
        if let memory = resources.memoryBytes {
            host["Memory"] = .int(memory)
            host["MemorySwap"] = .int(memory)  // sem swap: o limite é o limite
        }
        if let cpus = resources.cpus { host["NanoCpus"] = .int(Int64((cpus * 1_000_000_000).rounded())) }
        if let pids = resources.pidsLimit { host["PidsLimit"] = .int(pids) }
        if hardening.readOnlyRootfs { host["ReadonlyRootfs"] = .bool(true) }
        if hardening.dropAllCapabilities { host["CapDrop"] = .strings(["ALL"]) }
        if !capAdd.isEmpty { host["CapAdd"] = .strings(capAdd) }
        if hardening.noNewPrivileges { host["SecurityOpt"] = .strings(["no-new-privileges"]) }
        if hardening.useInit { host["Init"] = .bool(true) }
        if !tmpfs.isEmpty { host["Tmpfs"] = .map(tmpfs) }
        let allBinds = binds + named
        if !allBinds.isEmpty { host["Binds"] = .strings(allBinds) }
        if !extraHosts.isEmpty { host["ExtraHosts"] = .strings(extraHosts) }
        if let network { host["NetworkMode"] = .string(network.network) }
        if !publishedPorts.isEmpty {
            var bindings: [String: JSONValue] = [:]
            for port in publishedPorts {
                bindings[port.containerPort] = .array([.object(["HostIp": .string(port.hostIP), "HostPort": .string(port.hostPort)])])
            }
            host["PortBindings"] = .object(bindings)
        }
        root["HostConfig"] = .object(host)

        if let network {
            var endpoint: [String: JSONValue] = [:]
            if !network.aliases.isEmpty { endpoint["Aliases"] = .strings(network.aliases) }
            root["NetworkingConfig"] = .object(["EndpointsConfig": .object([network.network: .object(endpoint)])])
        }
        return .object(root)
    }
}

/// Descrição de um exec (`POST /containers/{id}/exec`).
public struct ExecSpec: Sendable, Equatable {
    public var command: [String]
    public var environment: [String] = []
    public var user: String?
    public var workingDirectory: String?
    public var attachStdin: Bool
    /// Com `true`, o comando roda dentro de um wrapper que registra o PID e permite `ExecSession.terminate`/`kill`
    /// no grupo de processos (S9). O wrapper exige `/bin/sh` e um `/tmp` gravável na imagem.
    public var killableGroup: Bool

    public init(command: [String], attachStdin: Bool = false, killableGroup: Bool = false, user: String? = nil) {
        self.user = user
        self.command = command
        self.attachStdin = attachStdin
        self.killableGroup = killableGroup
    }
}
