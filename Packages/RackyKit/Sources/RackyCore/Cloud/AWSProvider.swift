import Foundation

/// Adaptador AWS (BK12-T08) pelo `aws` CLI do usuário (`AWSCLI`, perfil do `aws login`). Só toca recursos com `racky:managed=true`.
///
/// O que cada operação chama:
/// - `regions`: o catálogo do app (nenhuma chamada).
/// - `quota`: `service-quotas get-service-quota` (`L-1216C47A`, vCPUs On-Demand Standard) + `ec2 describe-instances` (vCPUs em uso).
/// - `shapes` / `estimate`: tabela embutida (Graviton, preço on-demand Linux) + IPv4 público (US$ 0,005/h) + disco gp3.
/// - `provisionHost`: `ssm get-parameter` (AMI Amazon Linux 2023 arm64), security group `racky-host` (só 22/tcp e só do IP público
///   atual do usuário; regras de outros IPs saem), `ec2 run-instances` com IMDSv2 de 1 salto, `InstanceInitiatedShutdownBehavior=terminate`
///   (a chave morta da VM vira TerminateInstances), disco gp3 que some com a VM, tags em instância E volume, `ClientToken` = host do app;
///   depois `describe-instances` até ter IP público.
/// - `listHosts`: `describe-instances` filtrado pelas tags pedidas, em cada região.
/// - `terminateHost`: `ec2 terminate-instances`.
/// O user-data leva a chave privada do host (para fixar o `known_hosts` antes do boot): vai por arquivo 0600 apagado em seguida, nunca
/// pela linha de comando (que outros processos veem).
public struct AWSProvider: CloudProvider {
    public let id = CloudProviderID.aws
    public let cli: AWSCLI
    /// Disco do host (imagens dos computadores + volumes de trabalho).
    public var diskGiB: Int
    /// IP público do Mac para a regra de SSH (injetado nos testes).
    private let publicIP: @Sendable () async throws -> String
    private let pause: @Sendable (Duration) async throws -> Void

    public static let securityGroupName = "racky-host"
    public static let amiParameter = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
    /// vCPUs On-Demand das famílias padrão (A, C, D, H, I, M, R, T, Z).
    public static let vcpuQuotaCode = "L-1216C47A"
    static let ipv4HourlyUSD = 0.005
    static let gp3MonthlyUSDPerGiB = 0.08

    public init(
        cli: AWSCLI, diskGiB: Int = 30, publicIP: (@Sendable () async throws -> String)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.cli = cli; self.diskGiB = diskGiB
        self.publicIP = publicIP ?? { try await AWSProvider.fetchPublicIP() }
        self.pause = sleep
    }

    // MARK: Catálogo

    /// Graviton (arm64, mesma arquitetura das imagens dos Macs Apple silicon). Preço on-demand Linux em us-east-1/us-east-2 (US$/h).
    public static let shapeTable: [(shape: HostShape, hourlyUSD: Double)] = [
        (HostShape(id: "t4g.small", vcpus: 2, memoryGiB: 2), 0.0168),
        (HostShape(id: "t4g.medium", vcpus: 2, memoryGiB: 4), 0.0336),
        (HostShape(id: "t4g.large", vcpus: 2, memoryGiB: 8), 0.0672),
        (HostShape(id: "t4g.xlarge", vcpus: 4, memoryGiB: 16), 0.1344),
        (HostShape(id: "t4g.2xlarge", vcpus: 8, memoryGiB: 32), 0.2688),
        (HostShape(id: "c7g.large", vcpus: 2, memoryGiB: 4), 0.0725),
        (HostShape(id: "c7g.xlarge", vcpus: 4, memoryGiB: 8), 0.145),
        (HostShape(id: "c7g.2xlarge", vcpus: 8, memoryGiB: 16), 0.289),
        (HostShape(id: "m7g.xlarge", vcpus: 4, memoryGiB: 16), 0.1632),
        (HostShape(id: "m7g.2xlarge", vcpus: 8, memoryGiB: 32), 0.3264),
    ]

    /// Quanto a região custa a mais que a Virgínia (aproximado, revisado com a tabela da AWS).
    static func regionFactor(_ region: String) -> Double {
        switch region {
        case "us-east-1", "us-east-2", "us-west-2": 1
        case "sa-east-1": 1.55
        case "ap-northeast-1": 1.27
        case "eu-central-1": 1.17
        case "eu-west-1": 1.11
        default: 1.2
        }
    }

    /// Host para `computers` computadores ao mesmo tempo (1 por host pequeno, 2 por host de 4 vCPU/16 GiB).
    public static func shape(forComputers computers: Int) -> HostShape {
        let id = computers <= 1 ? "t4g.medium" : "t4g.xlarge"
        return shapeTable.first { $0.shape.id == id }!.shape
    }

    public func acceptableUsePolicy() async throws -> AcceptableUsePolicy {
        AcceptableUsePolicy(
            provider: .aws, version: "2024-aup", url: URL(string: "https://aws.amazon.com/aup/")!,
            shortNotice: "Computers run in your AWS account under the AWS Acceptable Use Policy.")
    }

    public func regions() async throws -> [CloudRegion] {
        CloudProviderCatalog.aws.regions.map { CloudRegion(id: $0.id, name: $0.id, location: $0.city, probeHost: "ec2.\($0.id).amazonaws.com") }
    }

    public func shapes(region: String) async throws -> [HostShape] { Self.shapeTable.map(\.shape) }

    public func estimate(shape: HostShape, region: String) async throws -> CostEstimate {
        let base = Self.shapeTable.first { $0.shape.id == shape.id }?.hourlyUSD ?? 0.2
        return CostEstimate(
            instanceHourlyUSD: base * Self.regionFactor(region), addressHourlyUSD: Self.ipv4HourlyUSD,
            storageHourlyUSD: Double(diskGiB) * Self.gp3MonthlyUSDPerGiB / 730)
    }

    public func quota(region: String) async throws -> CloudQuota {
        // Conta nova às vezes não responde ao Service Quotas: vale o padrão de conta nova (16 vCPUs) em vez de travar.
        let limit = (try? await cli.json(
            ["service-quotas", "get-service-quota", "--service-code", "ec2", "--quota-code", Self.vcpuQuotaCode], region: region))
            .flatMap { ($0["Quota"] as? [String: Any])?["Value"] as? Double }.map { Int($0) } ?? 16
        let running = try await instances(region: region, filters: ["Name=instance-state-name,Values=pending,running"])
        let used = running.reduce(0) { total, item in
            let cpu = item["CpuOptions"] as? [String: Any]
            return total + ((cpu?["CoreCount"] as? Int) ?? 1) * ((cpu?["ThreadsPerCore"] as? Int) ?? 1)
        }
        return CloudQuota(region: region, vcpuLimit: limit, vcpuInUse: used)
    }

    // MARK: Hosts

    /// Conta no plano gratuito novo da AWS só aceita alguns tipos (o Graviton é a `t4g.small`): cai para ela em vez de falhar.
    public static let freePlanFallback = "t4g.small"

    public func provisionHost(_ request: HostRequest) async throws -> CloudHost {
        do {
            return try await launch(request)
        } catch AWSCLI.Failure.failed(let command, let message) where message.contains("not eligible for Free Tier") && request.shape.id != Self.freePlanFallback {
            _ = command
            var smaller = request
            smaller.shape = Self.shapeTable.first { $0.shape.id == Self.freePlanFallback }!.shape
            return try await launch(smaller)
        }
    }

    private func launch(_ request: HostRequest) async throws -> CloudHost {
        let region = request.region
        let ami = try await cli.json(["ssm", "get-parameter", "--name", Self.amiParameter], region: region)
        guard let image = (ami["Parameter"] as? [String: Any])?["Value"] as? String else {
            throw CloudError.provider("No Amazon Linux image in \(region).")
        }
        let group = try await securityGroup(region: region)
        let tags = request.tags.dictionary
        let tagList = tags.sorted { $0.key < $1.key }.map { "{Key=\($0.key),Value=\($0.value)}" }.joined(separator: ",")
        let nameTag = "{Key=Name,Value=racky-host}"
        // Arquivo 0600 numa pasta 0700: o user-data tem a chave privada do host.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-ud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let userData = dir.appendingPathComponent("user-data")
        FileManager.default.createFile(atPath: userData.path, contents: Data(request.userData.utf8), attributes: [.posixPermissions: 0o600])
        let launched = try await cli.json([
            "ec2", "run-instances",
            "--image-id", image,
            "--instance-type", request.shape.id,
            "--security-group-ids", group,
            "--user-data", "file://\(userData.path)",
            "--instance-initiated-shutdown-behavior", "terminate",
            "--metadata-options", "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled",
            "--block-device-mappings", "DeviceName=/dev/xvda,Ebs={VolumeSize=\(diskGiB),VolumeType=gp3,DeleteOnTermination=true}",
            "--tag-specifications", "ResourceType=instance,Tags=[\(tagList),\(nameTag)]", "ResourceType=volume,Tags=[\(tagList)]",
            "--associate-public-ip-address",
            "--client-token", request.tags.host,
            "--count", "1",
        ], region: region, timeout: .seconds(90))
        guard let instance = (launched["Instances"] as? [[String: Any]])?.first, let instanceID = instance["InstanceId"] as? String else {
            throw CloudError.provider("AWS didn't return the new instance.")
        }
        let estimate = try await estimate(shape: request.shape, region: region)
        var host = CloudHost(
            id: instanceID, provider: .aws, region: region, shape: request.shape, state: .pending, launchedAt: Date(), tags: tags,
            hourlyUSD: estimate.hourlyUSD)
        // Até ter IP público (normalmente 10-30 s). Se não vier, o host fica sem endereço e o conector falha com mensagem.
        for _ in 0 ..< 60 {
            if let item = try? await instances(region: region, filters: [], ids: [instanceID]).first {
                host = Self.host(from: item, region: region) ?? host
                if host.address != nil, host.state == .running { break }
                if host.state == .terminated { throw CloudError.provider("The instance stopped while starting (\(Self.stateReason(item))).") }
            }
            try await pause(.seconds(3))
        }
        return host
    }

    public func listHosts(tags: [String: String], regions: [String]) async throws -> [CloudHost] {
        let filters = tags.sorted { $0.key < $1.key }.map { "Name=tag:\($0.key),Values=\($0.value)" }
            + ["Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down"]
        var hosts: [CloudHost] = []
        for region in regions {
            for item in try await instances(region: region, filters: filters) {
                if let host = Self.host(from: item, region: region) { hosts.append(host) }
            }
        }
        return hosts
    }

    public func terminateHost(id: String, region: String) async throws {
        _ = try await cli.json(["ec2", "terminate-instances", "--instance-ids", id], region: region)
    }

    // MARK: Peças

    private func instances(region: String, filters: [String], ids: [String] = []) async throws -> [[String: Any]] {
        var args = ["ec2", "describe-instances"]
        if !filters.isEmpty { args += ["--filters"] + filters }
        if !ids.isEmpty { args += ["--instance-ids"] + ids }
        let object = try await cli.json(args, region: region)
        return (object["Reservations"] as? [[String: Any]] ?? []).flatMap { $0["Instances"] as? [[String: Any]] ?? [] }
    }

    /// O `racky-host` da VPC padrão: entrada só na 22/tcp e só do IP atual do usuário (as regras de IPs antigos saem).
    func securityGroup(region: String) async throws -> String {
        let vpcs = try await cli.json(["ec2", "describe-vpcs", "--filters", "Name=is-default,Values=true"], region: region)
        guard let vpc = (vpcs["Vpcs"] as? [[String: Any]])?.first?["VpcId"] as? String else {
            throw CloudError.provider("This AWS region has no default network (VPC). Create the default VPC in the AWS console, then try again.")
        }
        let found = try await cli.json(
            ["ec2", "describe-security-groups", "--filters", "Name=group-name,Values=\(Self.securityGroupName)", "Name=vpc-id,Values=\(vpc)"], region: region)
        let existing = (found["SecurityGroups"] as? [[String: Any]])?.first
        let groupID: String
        if let id = existing?["GroupId"] as? String {
            groupID = id
        } else {
            let created = try await cli.json([
                "ec2", "create-security-group", "--group-name", Self.securityGroupName, "--vpc-id", vpc,
                "--description", "Racky computer hosts - SSH from the owner IP only",
                "--tag-specifications", "ResourceType=security-group,Tags=[{Key=\(RackyTags.managedKey),Value=true}]",
            ], region: region)
            guard let id = created["GroupId"] as? String else { throw CloudError.provider("Couldn't create the security group.") }
            groupID = id
        }
        let cidr = try await publicIP() + "/32"
        var allowed: [String] = []
        for permission in existing?["IpPermissions"] as? [[String: Any]] ?? [] {
            for range in permission["IpRanges"] as? [[String: Any]] ?? [] {
                guard let ip = range["CidrIp"] as? String else { continue }
                if ip == cidr, permission["FromPort"] as? Int == 22 { allowed.append(ip); continue }
                let proto = permission["IpProtocol"] as? String ?? "tcp"
                var args = ["ec2", "revoke-security-group-ingress", "--group-id", groupID, "--protocol", proto, "--cidr", ip]
                if let from = permission["FromPort"] as? Int { args += ["--port", "\(from)"] }
                _ = try? await cli.json(args, region: region)
            }
        }
        if !allowed.contains(cidr) {
            _ = try await cli.json(
                ["ec2", "authorize-security-group-ingress", "--group-id", groupID, "--protocol", "tcp", "--port", "22", "--cidr", cidr], region: region)
        }
        return groupID
    }

    static func host(from item: [String: Any], region: String) -> CloudHost? {
        guard let id = item["InstanceId"] as? String else { return nil }
        let tags = Dictionary((item["Tags"] as? [[String: Any]] ?? []).compactMap { tag -> (String, String)? in
            guard let key = tag["Key"] as? String, let value = tag["Value"] as? String else { return nil }
            return (key, value)
        }, uniquingKeysWith: { a, _ in a })
        let type = item["InstanceType"] as? String ?? "unknown"
        let entry = shapeTable.first { $0.shape.id == type }
        let shape = entry?.shape ?? HostShape(id: type, vcpus: 2, memoryGiB: 4)
        let stateName = (item["State"] as? [String: Any])?["Name"] as? String ?? "pending"
        let state: CloudHostState = switch stateName {
        case "running": .running
        case "pending": .pending
        case "terminated": .terminated
        default: .terminating
        }
        let launched = (item["LaunchTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let hourly = (entry?.hourlyUSD ?? 0.2) * regionFactor(region) + ipv4HourlyUSD
        return CloudHost(
            id: id, provider: .aws, region: region, shape: shape, state: state, address: item["PublicIpAddress"] as? String,
            launchedAt: launched, tags: tags, hourlyUSD: hourly)
    }

    static func stateReason(_ item: [String: Any]) -> String {
        ((item["StateReason"] as? [String: Any])?["Message"] as? String) ?? "no reason given"
    }

    /// IP público do Mac como a AWS o vê.
    static func fetchPublicIP() async throws -> String {
        var request = URLRequest(url: URL(string: "https://checkip.amazonaws.com")!)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ip.split(separator: ".").count == 4, ip.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw CloudError.provider("Couldn't find this Mac's public IP address.")
        }
        return ip
    }
}
