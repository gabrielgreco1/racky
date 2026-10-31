import Foundation
import Testing

@testable import RackyDocker

/// Host "remoto" sem túnel: o armazenamento é por volumes e as portas passam direto (o que importa aqui é o fluxo do provisionador).
private struct VolumeHost: ComputerHostAccess {
    var client: DockerClient
    var host: ComputerHost { .remote(RemoteHost(id: "i-1", provider: "fake", region: "us-east-1", address: "203.0.113.7")) }
    var storage: ComputerStorage { .volumes }
    func reach(publishedPort: Int, computerID: String) async throws -> Int { publishedPort }
    func releaseForwards(computerID: String) async {}
}

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("hs-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func request(computerID: String = "11111111-2222-3333-4444-555555555555", runDirectory: URL) -> ComputerProvisionRequest {
    ComputerProvisionRequest(
        labels: ComputerLabels(owner: "o", computerID: computerID, computerName: "n", isTest: true), image: "img", display: .headless, token: "t",
        config: EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: [], allowHosts: []),
        secrets: BoxSecretFiles(root: runDirectory.appendingPathComponent("secrets")), runDirectory: runDirectory)
}

@Suite("BK-12 - armazenamento e volta dos arquivos no host remoto")
struct HostStorageTests {
    @Test func localSpecIsUnchangedAndRemoteSpecUsesNamedVolumesAtTheSameMountPoints() throws {
        let run = URL(fileURLWithPath: "/runs/s/c", isDirectory: true)
        let req = request(runDirectory: run)
        let local = ComputerProvisioner.containerSpec(req, work: run.appendingPathComponent("work"), logs: run.appendingPathComponent("logs"),
                                                      taskSecrets: URL(fileURLWithPath: "/sec/work"), volume: "ab-prof-x")
        #expect(local.binds == ["/runs/s/c/work:/work", "/sec/work:/run/abx-secrets:ro", "/runs/s/c/logs:/run/racky/logs"])
        #expect(local.named == ["ab-prof-x:/profile"])
        let volumes = RemoteStorageSeeder.Volumes(computerID: "cid")
        let remote = ComputerProvisioner.containerSpec(req, mounts: .volumes(volumes), volume: "ab-prof-x")
        #expect(remote.binds.isEmpty, "nenhum caminho do Mac pode aparecer no host remoto")
        #expect(remote.named == ["ab-prof-x:/profile", "ab-work-cid:/work:nocopy", "ab-sec-cid:/run/abx-secrets:ro,nocopy", "ab-logs-cid:/run/racky/logs:nocopy"])
        // O resto do hardening é idêntico nos dois.
        var stripped = remote
        stripped.binds = local.binds; stripped.named = local.named
        #expect(stripped == local)
    }

    @Test func archiveGetAndPutUseTheContainerArchiveEndpoint() async throws {
        let tar = RawTar.make([.init(name: "./hello.txt", data: Data("hi".utf8))])
        let daemon = try await FakeDockerDaemon { request, connection in
            if request.method == "GET" { await Reply.chunked(connection, contentType: "application/x-tar", chunks: [Data(tar.prefix(700)), Data(tar.dropFirst(700))]) } else {
                await Reply.json(connection, body: Data("{}".utf8))
            }
        }
        defer { daemon.stop() }
        var received = Data()
        for try await chunk in try await daemon.client.archive("c1", path: "/work/.") { received.append(chunk) }
        #expect(received == tar)
        try await daemon.client.putArchive("c1", path: "/seed/sec", tar: tar)
        let items = await daemon.log.items
        #expect(items[0].path == "/v1.43/containers/c1/archive" && items[0].query == "path=%2Fwork%2F.")
        #expect(items[1].method == "PUT" && items[1].headers["content-type"] == "application/x-tar" && items[1].body == tar)
    }

    @Test func pullRunBringsWorkAndLogsIntoTheSameRunFolder() async throws {
        let work = RawTar.make([.init(name: "./", type: "5", mode: 0o755), .init(name: "./out/result.csv", data: Data("a,b\n1,2\n".utf8))])
        let logs = RawTar.make([.init(name: "./reqlog.jsonl", data: Data("{}\n".utf8))])
        let daemon = try await FakeDockerDaemon { request, connection in
            await Reply.chunked(connection, contentType: "application/x-tar", chunks: [request.query.contains("%2Fwork") ? work : logs])
        }
        defer { daemon.stop() }
        let run = try tempDir()
        defer { try? FileManager.default.removeItem(at: run) }
        try Data("app-owned".utf8).write(to: run.appendingPathComponent("logs-note.txt"))
        let result = try await RunFileSync(client: daemon.client).pullRun(
            container: "c1", workDirectory: run.appendingPathComponent("work"), logsDirectory: run.appendingPathComponent("logs"))
        #expect(result.work.files == 1 && result.logs.files == 1)
        #expect(try String(contentsOf: run.appendingPathComponent("work/out/result.csv"), encoding: .utf8) == "a,b\n1,2\n")
        #expect(FileManager.default.fileExists(atPath: run.appendingPathComponent("logs/reqlog.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: run.appendingPathComponent("logs-note.txt").path), "aditivo: nada local é apagado")
        let paths = await daemon.log.items.map(\.query)
        #expect(paths == ["path=%2Fwork%2F.", "path=%2Frun%2Fracky%2Flogs%2F."])
    }

    @Test func teardownSyncsBeforeRemovingAndKeepsEverythingWhenSyncFails() async throws {
        let inventory = #"[{"Id":"abc","Names":["/ab-1"],"Labels":{"racky.computer":"cid","racky.ephemeral":"true"},"State":"running","Created":1}]"#
        func daemonRoutes(failArchive: Bool) async throws -> FakeDockerDaemon {
            try await FakeDockerDaemon { request, connection in
                switch (request.method, request.path) {
                case ("GET", "/v1.43/containers/abc/archive"):
                    if failArchive { await Reply.json(connection, status: 500, body: Data(#"{"message":"disk error"}"#.utf8)) } else {
                        await Reply.chunked(connection, contentType: "application/x-tar", chunks: [RawTar.make([.init(name: "f.txt", data: Data("x".utf8))])])
                    }
                case ("GET", "/v1.43/containers/json"): await Reply.json(connection, body: Data(inventory.utf8))
                case ("GET", "/v1.43/networks"): await Reply.json(connection, body: Data("[]".utf8))
                case ("GET", "/v1.43/volumes"): await Reply.json(connection, body: Data(#"{"Volumes":[],"Warnings":null}"#.utf8))
                case ("DELETE", _): await Reply.raw(connection, status: 204, headers: [:], body: Data())
                default: await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
                }
            }
        }
        func computer(_ run: URL) -> ProvisionedComputer {
            ProvisionedComputer(
                labels: ComputerLabels(owner: "o", computerID: "cid", computerName: "n"), display: .headless, containerID: "abc", containerName: "ab-1",
                adminPort: 1, profileVolume: nil, workDirectory: run.appendingPathComponent("work"), logsDirectory: run.appendingPathComponent("logs"),
                admin: EgressAdminClient(port: 1, token: "t"))
        }
        let run = try tempDir()
        defer { try? FileManager.default.removeItem(at: run) }
        let secrets = BoxSecretFiles(root: run.appendingPathComponent("secrets"))

        let ok = try await daemonRoutes(failArchive: false)
        defer { ok.stop() }
        _ = try await ComputerProvisioner(host: VolumeHost(client: ok.client)).teardown(computer(run), secrets: secrets)
        let order = await ok.log.items.map { "\($0.method) \($0.path.split(separator: "/").dropFirst().joined(separator: "/"))" }
        let archiveAt = try #require(order.firstIndex { $0.contains("archive") }), deleteAt = try #require(order.firstIndex { $0.hasPrefix("DELETE") })
        #expect(archiveAt < deleteAt, "os arquivos voltam ANTES de o container ser apagado")
        #expect(FileManager.default.fileExists(atPath: run.appendingPathComponent("work/f.txt").path))

        let bad = try await daemonRoutes(failArchive: true)
        defer { bad.stop() }
        await #expect(throws: ComputerProvisionerError.self) {
            _ = try await ComputerProvisioner(host: VolumeHost(client: bad.client)).teardown(computer(run), secrets: secrets)
        }
        #expect(await bad.log.items.allSatisfy { $0.method != "DELETE" }, "sync falhou: nada é apagado (a VM não deve ser terminada)")
    }

    @Test func localTeardownNeverTouchesTheArchiveEndpoint() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/v1.43/containers/json", "/v1.43/networks": await Reply.json(connection, body: Data("[]".utf8))
            case "/v1.43/volumes": await Reply.json(connection, body: Data(#"{"Volumes":[],"Warnings":null}"#.utf8))
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let run = try tempDir()
        defer { try? FileManager.default.removeItem(at: run) }
        let computer = ProvisionedComputer(
            labels: ComputerLabels(owner: "o", computerID: "cid", computerName: "n"), display: .headless, containerID: "abc", containerName: "ab-1",
            adminPort: 1, profileVolume: nil, workDirectory: run, logsDirectory: run, admin: EgressAdminClient(port: 1, token: "t"))
        _ = try await ComputerProvisioner(client: daemon.client).teardown(computer, secrets: BoxSecretFiles(root: run))
        #expect(await daemon.log.items.allSatisfy { !$0.path.contains("archive") })
        #expect(computer.host == .local && computer.remoteAdminPort == nil)
    }

    @Test func seederCreatesAHelperWithThreeVolumesPutsSecretsChownsAndRemovesIt() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch (request.method, request.path) {
            case ("POST", "/v1.43/containers/create"): await Reply.json(connection, status: 201, body: Data(#"{"Id":"seed1"}"#.utf8))
            case ("PUT", _): await Reply.json(connection, body: Data("{}".utf8))
            case ("POST", "/v1.43/containers/seed1/start"): await Reply.raw(connection, status: 204, headers: [:], body: Data())
            case ("POST", "/v1.43/containers/seed1/wait"): await Reply.json(connection, body: Data(#"{"StatusCode":0}"#.utf8))
            case ("DELETE", _): await Reply.raw(connection, status: 204, headers: [:], body: Data())
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let labels = ComputerLabels(owner: "o", computerID: "cid", computerName: "n", isTest: true)
        try await RemoteStorageSeeder(client: daemon.client).seed(
            volumes: .init(computerID: "cid"), labels: labels, image: "img", secretFiles: ["API_KEY": Data("v".utf8)], agentUID: 10001, egressUID: 10003)
        let items = await daemon.log.items
        #expect(items.map(\.method) == ["POST", "PUT", "POST", "POST", "DELETE"])
        let create = try #require(items.first?.jsonBody)
        let binds = (create["HostConfig"] as? [String: Any])?["Binds"] as? [String] ?? []
        #expect(Set(binds) == ["ab-work-cid:/seed/work", "ab-logs-cid:/seed/logs", "ab-sec-cid:/seed/sec"])
        #expect((create["Labels"] as? [String: String])?[RackyLabel.test] == "1", "o auxiliar leva os labels do computador (o GC o encontra)")
        let command = ((create["Cmd"] as? [String])?.first) ?? ""
        #expect(command.contains("chown 10001:10001 /seed/work") && command.contains("chmod 0500 /seed/sec") && command.contains("chown 10003:10003 /seed/logs"))
        #expect(items[1].path.hasSuffix("/containers/seed1/archive") && items[1].query == "path=%2Fseed%2Fsec")
        #expect(items[1].body.count > 512 && String(decoding: items[1].body.prefix(7), as: UTF8.self) == "API_KEY")
    }

    @Test func seederRejectsUnsafeSecretNamesAndCleansUpOnFailure() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch (request.method, request.path) {
            case ("POST", "/v1.43/containers/create"): await Reply.json(connection, status: 201, body: Data(#"{"Id":"seed1"}"#.utf8))
            case ("POST", "/v1.43/containers/seed1/start"): await Reply.raw(connection, status: 204, headers: [:], body: Data())
            case ("POST", "/v1.43/containers/seed1/wait"): await Reply.json(connection, body: Data(#"{"StatusCode":1}"#.utf8))
            case ("DELETE", _): await Reply.raw(connection, status: 204, headers: [:], body: Data())
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let labels = ComputerLabels(owner: "o", computerID: "cid", computerName: "n")
        let seeder = RemoteStorageSeeder(client: daemon.client)
        await #expect(throws: BoxSecretFilesError.self) {
            try await seeder.seed(volumes: .init(computerID: "cid"), labels: labels, image: "i", secretFiles: ["../x": Data()], agentUID: 1, egressUID: 2)
        }
        #expect(await daemon.log.items.isEmpty, "nome inseguro: nada chega ao daemon")
        await #expect(throws: ComputerProvisionerError.self) {
            try await seeder.seed(volumes: .init(computerID: "cid"), labels: labels, image: "i", secretFiles: [:], agentUID: 1, egressUID: 2)
        }
        #expect(await daemon.log.items.last?.method == "DELETE", "o auxiliar é removido mesmo quando o chown falha")
    }
}
