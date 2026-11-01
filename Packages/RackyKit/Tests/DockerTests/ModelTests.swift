import Foundation
import Testing

@testable import RackyDocker

@Suite struct ModelDecodingTests {
    @Test func infoDecodesForThreeRuntimes() throws {
        let desktop = try Fixtures.decode(DockerInfo.self, "info-desktop.json")
        #expect(desktop.operatingSystem == "Docker Desktop" && desktop.cpuCount == 14 && desktop.architecture == "aarch64")
        #expect(desktop.memTotal > 7 << 30)
        let orb = try Fixtures.decode(DockerInfo.self, "info-orbstack.json")
        #expect(orb.name == "orbstack" && orb.memTotal == 16 << 30)
        let colima = try Fixtures.decode(DockerInfo.self, "info-colima.json")
        #expect(colima.name == "colima" && colima.cpuCount == 4)
        let version = try Fixtures.decode(DockerVersion.self, "version-desktop.json")
        #expect(!version.apiVersion.isEmpty && version.os == "linux")
    }

    @Test func containerInspectExposesHardeningLabelsAndPublishedPort() throws {
        let inspect = try Fixtures.decode(ContainerInspect.self, "container-inspect.json")
        #expect(inspect.name == "abx-fixture-capture")
        #expect(inspect.readonlyRootfs && inspect.capDrop == ["ALL"] && inspect.usesInit)
        #expect(inspect.securityOpt == ["no-new-privileges"])
        #expect(inspect.memoryLimit == 134_217_728 && inspect.nanoCPUs == 250_000_000 && inspect.pidsLimit == 64)
        #expect(inspect.labels[RackyLabel.role] == "egress" && inspect.labels[RackyLabel.test] == "1")
        #expect(inspect.state.running)
        let port = try #require(inspect.publishedHostPort(for: "3128/tcp"))
        #expect(port > 1024)
        #expect(inspect.ports["3128/tcp"]?.first?.hostIP == "127.0.0.1")
        // T9: nada com cara de segredo em Env.
        #expect(!inspect.env.contains { $0.lowercased().contains("token") || $0.lowercased().contains("secret") })
    }

    @Test func listNetworkVolumeImageDecode() throws {
        let list = try Fixtures.decode([ContainerSummary].self, "container-list.json")
        #expect(list.count == 1 && list[0].name == "abx-fixture-capture" && list[0].labels[RackyLabel.test] == "1")
        let network = try Fixtures.decode(NetworkInspect.self, "network-inspect.json")
        #expect(network.isInternal && network.labels[RackyLabel.computer] == "fixture-computer")
        let volume = try Fixtures.decode(VolumeInspect.self, "volume-inspect.json")
        #expect(volume.name == "abx-fixture-vol" && volume.labels[RackyLabel.test] == "1")
        let image = try Fixtures.decode(ImageInspect.self, "image-inspect.json")
        #expect(image.id.hasPrefix("sha256:") && image.architecture == "arm64" && image.labels.isEmpty)
    }

    @Test func realEventsDecodeWithBaseAction() throws {
        let lines = try Fixtures.text("events.jsonl").split(separator: "\n")
        let events = try lines.map { try JSONDecoder().decode(DockerEvent.self, from: Data($0.utf8)) }
        let actions = events.map(\.baseAction)
        #expect(actions.contains("create") && actions.contains("start") && actions.contains("die") && actions.contains("destroy"))
        #expect(events.allSatisfy { $0.type == "container" && !$0.actorID.isEmpty })
        let healthy = DockerEvent(type: "container", action: "health_status: healthy", actorID: "x")
        #expect(healthy.baseAction == "health_status")
    }

    @Test func pullAndBuildStreamsDecode() throws {
        let pull = try Fixtures.text("pull-stream.jsonl").split(separator: "\n").map { try JSONDecoder().decode(PullProgress.self, from: Data($0.utf8)) }
        #expect(pull.contains { $0.status == "Pull complete" && $0.id == "f18232174bc9" })
        #expect(pull.contains { $0.current == 28672 && $0.total == 3_623_807 })
        let pullError = try Fixtures.text("pull-error-stream.jsonl").split(separator: "\n").map { try JSONDecoder().decode(PullProgress.self, from: Data($0.utf8)) }
        #expect(pullError.last?.error == "manifest unknown")
        let build = try Fixtures.text("build-stream.jsonl").split(separator: "\n").map { try JSONDecoder().decode(BuildEvent.self, from: Data($0.utf8)) }
        #expect(build.compactMap(\.step).map(\.index) == [1, 2, 3] && build.compactMap(\.step).allSatisfy { $0.total == 3 })
        #expect(build.compactMap(\.imageID).first?.hasPrefix("sha256:feedface") == true)
        let buildError = try Fixtures.text("build-error-stream.jsonl").split(separator: "\n").map { try JSONDecoder().decode(BuildEvent.self, from: Data($0.utf8)) }
        #expect(buildError.last?.error?.contains("non-zero code") == true)
    }

    @Test func emptyNullFieldsDecodeAsEmpty() throws {
        let volumes = Data(#"{"Name":"v","Labels":null}"#.utf8)
        #expect(try JSONDecoder().decode(VolumeInspect.self, from: volumes).labels.isEmpty)
        let network = Data(#"{"Id":"n","Name":"n","Labels":null,"Containers":null}"#.utf8)
        #expect(try JSONDecoder().decode(NetworkInspect.self, from: network).containerIDs.isEmpty)
    }
}

@Suite struct ContainerSpecTests {
    private func object(_ spec: ContainerSpec) throws -> [String: Any] {
        let data = try JSONEncoder().encode(spec.body())
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func standardHardeningMatchesCS114() throws {
        var spec = ContainerSpec(name: "ab-12345678-egress", image: "racky-box:ctx-abc", command: ["sleep", "1"])
        spec.resources = ContainerResources(memoryBytes: 128 << 20, cpus: 0.25, pidsLimit: 256)
        spec.tmpfs = ["/tmp": "rw,noexec,nosuid,size=64m,uid=10003"]
        spec.labels = ComputerLabels(owner: "o", computerID: "c", computerName: "phoenix-az", isTest: true).labels(role: .egress)
        spec.network = ContainerNetworkAttachment(network: "racky-net-c", aliases: ["egress"])
        spec.publishedPorts = [PublishedPort(containerPort: "3128/tcp")]
        let root = try object(spec)
        let host = try #require(root["HostConfig"] as? [String: Any])
        #expect(host["ReadonlyRootfs"] as? Bool == true)
        #expect(host["CapDrop"] as? [String] == ["ALL"])
        #expect(host["SecurityOpt"] as? [String] == ["no-new-privileges"])
        #expect(host["Init"] as? Bool == true)
        #expect(host["Memory"] as? Int == 128 << 20 && host["MemorySwap"] as? Int == 128 << 20)
        #expect(host["NanoCpus"] as? Int == 250_000_000 && host["PidsLimit"] as? Int == 256)
        #expect(host["NetworkMode"] as? String == "racky-net-c")
        #expect(host["Privileged"] == nil && host["PublishAllPorts"] == nil)
        let bindings = try #require(host["PortBindings"] as? [String: [[String: String]]])
        #expect(bindings["3128/tcp"] == [["HostIp": "127.0.0.1", "HostPort": ""]])
        let labels = try #require(root["Labels"] as? [String: String])
        #expect(labels[RackyLabel.test] == "1" && labels[RackyLabel.role] == "egress" && labels[RackyLabel.ephemeral] == "true")
        let endpoints = try #require((root["NetworkingConfig"] as? [String: Any])?["EndpointsConfig"] as? [String: Any])
        #expect((endpoints["racky-net-c"] as? [String: Any])?["Aliases"] as? [String] == ["egress"])
        #expect(root["Env"] == nil, "sem env por padrão: token da box nunca em env (T9)")
    }

    @Test func labelsAndDeterministicNames() {
        let labels = ComputerLabels(owner: "install-1", computerID: "ABCDEF12-3456-7890-ABCD-EF1234567890", computerName: "phoenix-az",
                                    session: "s", run: "r", batch: "b", ephemeral: false, imageDigest: "sha256:x")
        #expect(labels.containerName == "ab-abcdef12")
        #expect(labels.legacyNetworkName == "racky-net-ABCDEF12-3456-7890-ABCD-EF1234567890")
        let map = labels.labels(role: .work)
        #expect(map[RackyLabel.owner] == "install-1" && map[RackyLabel.role] == "work" && map[RackyLabel.ephemeral] == "false")
        #expect(map[RackyLabel.session] == "s" && map[RackyLabel.batch] == "b" && map[RackyLabel.imageDigest] == "sha256:x")
        #expect(map[RackyLabel.test] == nil)
    }
}
