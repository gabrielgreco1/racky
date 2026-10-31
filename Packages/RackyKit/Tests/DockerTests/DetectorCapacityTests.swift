import Foundation
import Testing

@testable import RackyDocker

/// Sistema de arquivos falso: caminho -> bytes; diretórios inferidos dos prefixos.
private func makeDetector(env: [String: String] = [:], files: [String: String]) -> RuntimeDetector {
    let table = files
    return RuntimeDetector(
        environment: env, homeDirectory: URL(fileURLWithPath: "/Users/test"),
        fileExists: { table[$0] != nil },
        readFile: { table[$0].map { Data($0.utf8) } },
        listDirectory: { dir in
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            return Set(table.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) }).sorted()
        })
}

private func contextMeta(_ name: String, host: String) -> (path: String, body: String) {
    ("/Users/test/.docker/contexts/meta/\(RuntimeDetector.contextDirectoryName(name))/meta.json",
     #"{"Name":"\#(name)","Metadata":{},"Endpoints":{"docker":{"Host":"\#(host)","SkipTLSVerify":false}}}"#)
}

@Suite struct RuntimeDetectorTests {
    @Test func contextDirectoryNameIsSha256OfNameAsDockerCLIStoresIt() {
        // Valor real de `docker context inspect desktop-linux` (Storage.MetadataPath).
        #expect(RuntimeDetector.contextDirectoryName("desktop-linux") == "fe9c6bd7a66301f49ca9b6a70b217107cd1284598bfc254700c989b916da791e")
    }

    @Test func orderIsEnvironmentThenContextThenKnownSockets() {
        let meta = contextMeta("orbstack", host: "unix:///Users/test/.orbstack/run/docker.sock")
        let detector = makeDetector(env: ["DOCKER_HOST": "unix:///custom/docker.sock"], files: [
            "/Users/test/.docker/config.json": #"{"currentContext":"orbstack"}"#, meta.path: meta.body,
            "/Users/test/.docker/run/docker.sock": "", "/Users/test/.orbstack/run/docker.sock": "",
            "/Users/test/.colima/default/docker.sock": "", "/Users/test/.colima/dev/docker.sock": "", "/var/run/docker.sock": "",
        ])
        let candidates = detector.candidates()
        #expect(candidates.map(\.socketPath) == [
            "/custom/docker.sock", "/Users/test/.orbstack/run/docker.sock", "/Users/test/.docker/run/docker.sock",
            "/Users/test/.colima/default/docker.sock", "/Users/test/.colima/dev/docker.sock", "/var/run/docker.sock",
        ])
        #expect(candidates[0].source == .dockerHostEnvironment)
        #expect(candidates[1].source == .activeContext(name: "orbstack") && candidates[1].kind == .orbstack)
        #expect(candidates[2].kind == .desktop && candidates[3].kind == .colima)
    }

    @Test func activeContextComesFromConfigWithoutTheCLIOrPATH() {
        let meta = contextMeta("desktop-linux", host: "unix:///Users/test/.docker/run/docker.sock")
        let detector = makeDetector(files: ["/Users/test/.docker/config.json": #"{"auths":{},"currentContext":"desktop-linux"}"#, meta.path: meta.body])
        #expect(detector.activeContextName() == "desktop-linux")
        #expect(detector.endpoint(ofContext: "desktop-linux") == "unix:///Users/test/.docker/run/docker.sock")
        let candidates = detector.candidates()
        #expect(candidates.count == 1 && candidates[0].kind == .desktop)
    }

    @Test func dockerContextEnvironmentOverridesConfigAndDefaultMeansNoContext() {
        let meta = contextMeta("colima", host: "unix:///Users/test/.colima/default/docker.sock")
        let files = ["/Users/test/.docker/config.json": #"{"currentContext":"desktop-linux"}"#, meta.path: meta.body]
        #expect(makeDetector(env: ["DOCKER_CONTEXT": "colima"], files: files).activeContextName() == "colima")
        #expect(makeDetector(env: ["DOCKER_CONTEXT": "default"], files: files).activeContextName() == nil)
        #expect(makeDetector(files: ["/Users/test/.docker/config.json": #"{"currentContext":"default"}"#]).activeContextName() == nil)
    }

    @Test func nonUnixEndpointsAreIgnoredAndMissingKnownSocketsSkipped() {
        let detector = makeDetector(env: ["DOCKER_HOST": "tcp://10.0.0.1:2375"], files: ["/var/run/docker.sock": ""])
        #expect(detector.candidates().map(\.socketPath) == ["/var/run/docker.sock"])
        #expect(makeDetector(files: [:]).candidates().isEmpty)
    }

    @Test func duplicatesAreCollapsed() {
        let meta = contextMeta("desktop-linux", host: "unix:///Users/test/.docker/run/docker.sock")
        let detector = makeDetector(files: ["/Users/test/.docker/config.json": #"{"currentContext":"desktop-linux"}"#, meta.path: meta.body,
                                           "/Users/test/.docker/run/docker.sock": ""])
        #expect(detector.candidates().count == 1)
    }

    @Test func noRuntimeYieldsDockerUnavailableWithStartCommands() async {
        do {
            _ = try await makeDetector(files: [:]).detect()
            Issue.record("deveria falhar")
        } catch let error as DockerError {
            #expect(error.isRuntimeUnavailable && error.reserveReason == "docker_unavailable")
        } catch {
            Issue.record("erro inesperado \(error)")
        }
        #expect(DockerRuntimeKind.desktop.startCommand == ["open", "-a", "Docker"])
        #expect(DockerRuntimeKind.orbstack.startCommand == ["orb", "start"])
        #expect(DockerRuntimeKind.colima.startCommand == ["colima", "start"])
        #expect(DockerRuntimeKind.other.startCommand == nil)
    }

    @Test func staleSocketFileIsSkippedInFavorOfLiveOne() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/_ping": await Reply.text(connection, "OK")
            case "/v1.43/version": await Reply.json(connection, body: (try? Fixtures.data("version-desktop.json")) ?? Data())
            case "/v1.43/info": await Reply.json(connection, body: (try? Fixtures.data("info-orbstack.json")) ?? Data())
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"x"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let live = daemon.socketPath
        // Candidato morto vem primeiro (DOCKER_HOST); o vivo vem pelo contexto ativo (DOCKER_CONTEXT -> meta.json).
        let meta = contextMeta("live", host: "unix://\(live)")
        let withLive = RuntimeDetector(
            environment: ["DOCKER_HOST": "unix:///nonexistent/dead.sock", "DOCKER_CONTEXT": "live"], homeDirectory: URL(fileURLWithPath: "/Users/test"),
            fileExists: { _ in false }, readFile: { $0 == meta.path ? Data(meta.body.utf8) : nil }, listDirectory: { _ in [] })
        let detected = try await withLive.detect()
        #expect(detected.runtime.socketPath == live)
        #expect(detected.runtime.kind == .orbstack, "/info com Name=orbstack refina o tipo")
        #expect(detected.capacity.memTotalBytes == 16 << 30)
    }
}

@Suite struct CapacityPlannerTests {
    private func planner(memGiB: Double) -> CapacityPlanner {
        CapacityPlanner(vm: VMCapacity(memTotalBytes: Int64(memGiB * Double(1 << 30)), cpuCount: 14))
    }

    @Test func eightGBVMFitsFourHeadlessAndQueuesTheFifth() {
        let p = planner(memGiB: 7.7)
        #expect(p.maxConcurrent(.headless) == 4)
        var active: [ComputerDisplay] = []
        for _ in 0 ..< 4 {
            #expect(p.admission(active: active, adding: .headless) == .admit)
            active.append(.headless)
        }
        #expect(p.admission(active: active, adding: .headless) == .queue(reason: "memory"))
    }

    @Test func admissionUsesSumOfEstimatesNotSingleProfile() {
        let p = planner(memGiB: 7.7)  // orçamento 5,7
        // 2 desktop (4,4) + 1 headless (1,2) = 5,6 cabe; mais um http (0,4) = 6,0 não.
        #expect(p.admission(active: [.desktop, .desktop], adding: .headless) == .admit)
        #expect(p.admission(active: [.desktop, .desktop, .headless], adding: .http) == .queue(reason: "memory"))
    }

    @Test func referenceTargetNeeds26GBAndLoadTestVMFits() {
        let eight = planner(memGiB: 7.75)
        #expect(eight.recommendedVMGB() == 26)
        #expect(eight.vmSizeWarning() == "Docker VM has 8 GB. 15 headless and 2 desktop computers need about 26 GB.")
        let load = planner(memGiB: 27.7)  // aceites de carga em 28 GB
        #expect(load.vmSizeWarning() == nil)
        #expect(abs(load.budgetGiB - 25.7) < 1e-9)
        #expect(load.admission(active: Array(repeating: .headless, count: 15) + [.desktop], adding: .desktop) == .admit)
    }

    @Test func lowDiskRejectsBeforeMemoryCheck() {
        let p = planner(memGiB: 27.7)
        #expect(p.admission(active: [], adding: .headless, freeDiskBytes: 4 << 30) == .rejectDisk)
        #expect(p.admission(active: [], adding: .headless, freeDiskBytes: 6 << 30) == .admit)
    }

    @Test func movingAverageNeedsTwentySamplesAndFixedModeIgnoresThem() {
        var tracker = EstimateTracker()
        for _ in 0 ..< 19 { tracker.record(.headless, usedGiB: 0.6) }
        #expect(tracker.estimatesGiB[.headless] == 1.2)
        tracker.record(.headless, usedGiB: 0.6)
        #expect(abs((tracker.estimatesGiB[.headless] ?? 0) - 0.6) < 1e-9)
        for _ in 0 ..< 20 { tracker.record(.headless, usedGiB: 1.0) }
        #expect(abs((tracker.estimatesGiB[.headless] ?? 0) - 1.0) < 1e-9, "janela de 20")
        var fixed = EstimateTracker(fixed: true)
        for _ in 0 ..< 30 { fixed.record(.desktop, usedGiB: 9) }
        #expect(fixed.estimatesGiB[.desktop] == 2.2)
    }

    @Test func vmCapacityConfiguredGBAddsKernelSlack() {
        #expect(VMCapacity(memTotalBytes: 8_320_954_368, cpuCount: 14).configuredGB == 8)
    }
}
