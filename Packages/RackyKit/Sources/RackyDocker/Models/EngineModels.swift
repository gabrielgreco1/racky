import Foundation

// DTOs decodificados das respostas da Engine API. Só os campos que o app usa; o resto é ignorado.

public struct DockerVersion: Sendable, Equatable, Decodable {
    public var version: String
    public var apiVersion: String
    public var minAPIVersion: String?
    public var os: String
    public var arch: String

    enum CodingKeys: String, CodingKey {
        case version = "Version", apiVersion = "ApiVersion", minAPIVersion = "MinAPIVersion", os = "Os", arch = "Arch"
    }
}

public struct DockerInfo: Sendable, Equatable, Decodable {
    public var id: String?
    public var name: String
    /// Memória total da VM (bytes). Base da capacidade (07 CS-130, `M`).
    public var memTotal: Int64
    public var cpuCount: Int
    public var architecture: String
    public var operatingSystem: String
    public var osType: String?
    public var serverVersion: String?
    public var dockerRootDir: String?
    public var kernelVersion: String?
    public var containers: Int?
    public var containersRunning: Int?
    public var images: Int?

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", memTotal = "MemTotal", cpuCount = "NCPU", architecture = "Architecture"
        case operatingSystem = "OperatingSystem", osType = "OSType", serverVersion = "ServerVersion"
        case dockerRootDir = "DockerRootDir", kernelVersion = "KernelVersion"
        case containers = "Containers", containersRunning = "ContainersRunning", images = "Images"
    }
}

// MARK: Imagens

public struct ImageInspect: Sendable, Equatable, Decodable {
    public var id: String
    public var repoTags: [String]
    public var repoDigests: [String]
    public var architecture: String?
    public var os: String?
    public var size: Int64?
    public var labels: [String: String]

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests", architecture = "Architecture", os = "Os", size = "Size", config = "Config"
    }
    enum ConfigKeys: String, CodingKey { case labels = "Labels" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests) ?? []
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture)
        os = try c.decodeIfPresent(String.self, forKey: .os)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        if let config = try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            labels = try config.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        } else {
            labels = [:]
        }
    }
}

public struct ImageSummary: Sendable, Equatable, Decodable {
    public var id: String
    public var repoTags: [String]
    public var labels: [String: String]
    public var size: Int64
    public var created: Int64

    enum CodingKeys: String, CodingKey { case id = "Id", repoTags = "RepoTags", labels = "Labels", size = "Size", created = "Created" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
    }
}

/// Linha do stream de `POST /images/create`.
public struct PullProgress: Sendable, Equatable, Decodable {
    public var status: String?
    public var id: String?
    public var current: Int64?
    public var total: Int64?
    public var error: String?

    enum CodingKeys: String, CodingKey { case status, id, progressDetail, error, errorDetail }
    enum DetailKeys: String, CodingKey { case current, total }
    struct ErrorDetail: Decodable { var message: String? }

    public init(status: String?, id: String? = nil, current: Int64? = nil, total: Int64? = nil, error: String? = nil) {
        self.status = status
        self.id = id
        self.current = current
        self.total = total
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        if let detail = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .progressDetail) {
            current = try detail.decodeIfPresent(Int64.self, forKey: .current)
            total = try detail.decodeIfPresent(Int64.self, forKey: .total)
        }
        let detail = try c.decodeIfPresent(ErrorDetail.self, forKey: .errorDetail)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? detail?.message
    }
}

/// Linha do stream de `POST /build` (builder clássico).
public struct BuildEvent: Sendable, Equatable, Decodable {
    public var stream: String?
    public var error: String?
    public var imageID: String?
    public var status: String?

    enum CodingKeys: String, CodingKey { case stream, error, errorDetail, aux, status }
    struct Aux: Decodable { var ID: String? }
    struct ErrorDetail: Decodable { var message: String? }

    public init(stream: String? = nil, error: String? = nil, imageID: String? = nil, status: String? = nil) {
        self.stream = stream
        self.error = error
        self.imageID = imageID
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream = try c.decodeIfPresent(String.self, forKey: .stream)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        let detail = try c.decodeIfPresent(ErrorDetail.self, forKey: .errorDetail)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? detail?.message
        imageID = (try? c.decodeIfPresent(Aux.self, forKey: .aux))?.ID
    }

    /// `Step 2/14 : RUN ...` do builder clássico.
    public var step: (index: Int, total: Int)? {
        guard let stream, stream.hasPrefix("Step ") else { return nil }
        let head = stream.dropFirst(5).prefix { $0 != ":" }
        let parts = head.split(separator: "/")
        guard parts.count == 2, let i = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (i, n)
    }
}

// MARK: Containers

public struct ContainerState: Sendable, Equatable, Decodable {
    public var status: String
    public var running: Bool
    public var paused: Bool
    public var oomKilled: Bool
    public var exitCode: Int
    public var error: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var health: String?

    enum CodingKeys: String, CodingKey {
        case status = "Status", running = "Running", paused = "Paused", oomKilled = "OOMKilled", exitCode = "ExitCode"
        case error = "Error", startedAt = "StartedAt", finishedAt = "FinishedAt", health = "Health"
    }
    struct Health: Decodable { var Status: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        oomKilled = try c.decodeIfPresent(Bool.self, forKey: .oomKilled) ?? false
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        health = (try c.decodeIfPresent(Health.self, forKey: .health))?.Status
    }
}

public struct PortBinding: Sendable, Equatable, Decodable {
    public var hostIP: String
    public var hostPort: String
    enum CodingKeys: String, CodingKey { case hostIP = "HostIp", hostPort = "HostPort" }
}

public struct ContainerNetworkEndpoint: Sendable, Equatable, Decodable {
    public var networkID: String?
    public var ipAddress: String?
    public var aliases: [String]
    enum CodingKeys: String, CodingKey { case networkID = "NetworkID", ipAddress = "IPAddress", aliases = "Aliases" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networkID = try c.decodeIfPresent(String.self, forKey: .networkID)
        ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

public struct ContainerInspect: Sendable, Equatable, Decodable {
    public var id: String
    /// Nome sem a barra inicial.
    public var name: String
    public var created: String?
    public var imageID: String?
    public var imageRef: String?
    public var state: ContainerState
    public var labels: [String: String]
    /// `KEY=VALUE` do `Config.Env`. O app nunca põe token aqui (T9); o teste de `inspect` verifica isso.
    public var env: [String]
    public var user: String?
    public var memoryLimit: Int64?
    public var nanoCPUs: Int64?
    public var pidsLimit: Int64?
    public var readonlyRootfs: Bool
    public var capDrop: [String]
    public var capAdd: [String]
    public var securityOpt: [String]
    public var usesInit: Bool
    public var networkMode: String?
    public var ports: [String: [PortBinding]]
    public var networks: [String: ContainerNetworkEndpoint]

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", created = "Created", imageID = "Image", state = "State", config = "Config"
        case hostConfig = "HostConfig", networkSettings = "NetworkSettings"
    }
    enum ConfigKeys: String, CodingKey { case image = "Image", labels = "Labels", env = "Env", user = "User" }
    enum HostKeys: String, CodingKey {
        case memory = "Memory", nanoCPUs = "NanoCpus", pidsLimit = "PidsLimit", readonlyRootfs = "ReadonlyRootfs"
        case capDrop = "CapDrop", capAdd = "CapAdd", securityOpt = "SecurityOpt", initFlag = "Init", networkMode = "NetworkMode"
    }
    enum NetworkKeys: String, CodingKey { case ports = "Ports", networks = "Networks" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        created = try c.decodeIfPresent(String.self, forKey: .created)
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID)
        state = try c.decode(ContainerState.self, forKey: .state)
        let config = try c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
        imageRef = try config.decodeIfPresent(String.self, forKey: .image)
        labels = try config.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        env = try config.decodeIfPresent([String].self, forKey: .env) ?? []
        let rawUser = try config.decodeIfPresent(String.self, forKey: .user)
        user = (rawUser?.isEmpty ?? true) ? nil : rawUser
        let host = try c.nestedContainer(keyedBy: HostKeys.self, forKey: .hostConfig)
        let memory = try host.decodeIfPresent(Int64.self, forKey: .memory)
        memoryLimit = (memory ?? 0) > 0 ? memory : nil
        let cpus = try host.decodeIfPresent(Int64.self, forKey: .nanoCPUs)
        nanoCPUs = (cpus ?? 0) > 0 ? cpus : nil
        pidsLimit = try host.decodeIfPresent(Int64.self, forKey: .pidsLimit)
        readonlyRootfs = try host.decodeIfPresent(Bool.self, forKey: .readonlyRootfs) ?? false
        capDrop = try host.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        capAdd = try host.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        securityOpt = try host.decodeIfPresent([String].self, forKey: .securityOpt) ?? []
        usesInit = try host.decodeIfPresent(Bool.self, forKey: .initFlag) ?? false
        networkMode = try host.decodeIfPresent(String.self, forKey: .networkMode)
        if let net = try? c.nestedContainer(keyedBy: NetworkKeys.self, forKey: .networkSettings) {
            let raw = try net.decodeIfPresent([String: [PortBinding]?].self, forKey: .ports) ?? [:]
            ports = raw.compactMapValues { $0 }
            networks = try net.decodeIfPresent([String: ContainerNetworkEndpoint].self, forKey: .networks) ?? [:]
        } else {
            ports = [:]
            networks = [:]
        }
    }

    /// Porta de host publicada para `containerPort` (por exemplo `"3128/tcp"`), lida via inspect (07 CS-111).
    public func publishedHostPort(for containerPort: String) -> Int? {
        ports[containerPort]?.compactMap { Int($0.hostPort) }.first
    }
}

public struct ContainerSummary: Sendable, Equatable, Decodable {
    public var id: String
    public var names: [String]
    public var image: String
    public var state: String
    public var status: String
    public var labels: [String: String]
    public var created: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status", labels = "Labels", created = "Created"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = (try c.decodeIfPresent([String].self, forKey: .names) ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
    }

    public var name: String { names.first ?? id }
}

// MARK: Redes e volumes

public struct NetworkInspect: Sendable, Equatable, Decodable {
    public var id: String
    public var name: String
    public var driver: String
    public var isInternal: Bool
    public var labels: [String: String]
    public var containerIDs: [String]
    /// Sub-redes do IPAM (`172.18.0.0/16`).
    public var subnets: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", isInternal = "Internal", labels = "Labels", containers = "Containers", ipam = "IPAM"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        isInternal = try c.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        struct Member: Decodable {}
        containerIDs = (try c.decodeIfPresent([String: Member].self, forKey: .containers) ?? [:]).keys.sorted()
        struct IPAM: Decodable {
            struct Entry: Decodable { let Subnet: String? }
            let Config: [Entry]?
        }
        subnets = (try c.decodeIfPresent(IPAM.self, forKey: .ipam)?.Config ?? []).compactMap(\.Subnet)
    }
}

public struct VolumeInspect: Sendable, Equatable, Decodable {
    public var name: String
    public var driver: String
    public var mountpoint: String?
    public var labels: [String: String]
    public var createdAt: String?

    enum CodingKeys: String, CodingKey { case name = "Name", driver = "Driver", mountpoint = "Mountpoint", labels = "Labels", createdAt = "CreatedAt" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "local"
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

// MARK: Eventos

public struct DockerEvent: Sendable, Equatable, Decodable {
    public var type: String
    /// Ação bruta (`start`, `die`, `destroy`, `oom`, `health_status: healthy`, `exec_start: sh -c ...`).
    public var action: String
    public var actorID: String
    public var attributes: [String: String]
    public var time: Int64
    public var timeNano: Int64?

    enum CodingKeys: String, CodingKey { case type = "Type", action = "Action", actor = "Actor", time, timeNano }
    enum ActorKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }

    public init(type: String, action: String, actorID: String, attributes: [String: String] = [:], time: Int64 = 0, timeNano: Int64? = nil) {
        self.type = type
        self.action = action
        self.actorID = actorID
        self.attributes = attributes
        self.time = time
        self.timeNano = timeNano
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        time = try c.decodeIfPresent(Int64.self, forKey: .time) ?? 0
        timeNano = try c.decodeIfPresent(Int64.self, forKey: .timeNano)
        if let actor = try? c.nestedContainer(keyedBy: ActorKeys.self, forKey: .actor) {
            actorID = try actor.decodeIfPresent(String.self, forKey: .id) ?? ""
            attributes = try actor.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        } else {
            actorID = ""
            attributes = [:]
        }
    }

    /// `health_status: healthy` vira `health_status`.
    public var baseAction: String { action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action }
    public var name: String? { attributes["name"] }
    public var exitCode: Int? { attributes["exitCode"].flatMap { Int($0) } }
}

// MARK: Exec

public struct ExecInspect: Sendable, Equatable, Decodable {
    public var running: Bool
    public var exitCode: Int?
    public var pid: Int?
    public var containerID: String?
    enum CodingKeys: String, CodingKey { case running = "Running", exitCode = "ExitCode", pid = "Pid", containerID = "ContainerID" }
}

public struct ContainerStatsSnapshot: Sendable, Equatable {
    public var memoryUsageBytes: Int64
    public var memoryLimitBytes: Int64
    public var cpuTotalUsageNanos: Int64
    public var pids: Int
}
