import RackyDocker
import Foundation
import Synchronization
import Testing

@testable import RackyCore

/// Motor da checklist (R1.1, AC-102): paralelo, timeout por item, cache e sondas 100% falsas.
@Suite struct DiagnosticsEngineTests {
    private final class Collected: Sendable {
        private let state = Mutex<[DiagnosticKey: [DiagnosticItem?]]>([:])
        func add(_ key: DiagnosticKey, _ item: DiagnosticItem?) { state.withLock { $0[key, default: []].append(item) } }
        func last(_ key: DiagnosticKey) -> DiagnosticItem? { state.withLock { $0[key]?.last ?? nil } }
        func history(_ key: DiagnosticKey) -> [DiagnosticItem?] { state.withLock { $0[key] ?? [] } }
    }

    private let runtime = DockerRuntime(kind: .desktop, socketPath: "/tmp/fake.sock", source: .knownSocket)

    private func probes(
        gh: @escaping @Sendable () async -> GitHubProbeResult = { GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .connected, host: "github.com", user: "me", scopes: ["repo"])) },
        docker: DockerProbeResult? = nil, image: ImageProbeResult? = .ready,
        conflicts: ConflictScan = ConflictScan()
    ) -> DiagnosticsProbes {
        let dockerResult = docker ?? .running(DockerRunning(runtime: runtime, version: "27", memoryGB: 16, headlessCapacity: 11))
        return DiagnosticsProbes(gh: gh, docker: { dockerResult }, image: { _ in image }, conflicts: { conflicts })
    }

    private func run(_ engine: DiagnosticsEngine, keys: Set<DiagnosticKey> = Set(DiagnosticKey.allCases), force: Bool = false, into collected: Collected) async {
        await engine.run(keys, force: force) { collected.add($0, $1) }
    }

    @Test func everyItemLeavesCheckingWithItsOwnResult() async {
        let engine = DiagnosticsEngine(probes: probes(conflicts: ConflictScan(findings: [ConflictFinding(kind: .notify, provider: .codex, path: "~/.codex/config.toml", message: "x")])))
        let collected = Collected()
        await run(engine, into: collected)
        #expect(collected.history(.gh).first??.state == .checking, "Checking… antes do resultado")
        #expect(collected.last(.gh)?.state == .ok)
        #expect(collected.last(.docker)?.state == .ok)
        #expect(collected.last(.image)?.detail == "Ready")
        #expect(collected.last(.conflicts)?.state == .neutral)
    }

    @Test func aStuckItemTimesOutWithTryAgainAndDoesNotDelayTheOthers() async {
        let engine = DiagnosticsEngine(
            probes: probes(gh: { try? await Task.sleep(for: .seconds(30)); return GitHubProbeResult(installed: false) }),
            configuration: .init(timeout: .milliseconds(150), cacheTTL: .seconds(60)))
        let collected = Collected()
        let start = ContinuousClock.now
        await run(engine, into: collected)
        #expect(ContinuousClock.now - start < .seconds(10), "bem abaixo dos 30 s do item preso, com folga para a suíte carregada")
        #expect(collected.last(.gh)?.fix == .retry && collected.last(.gh)?.state == .problem)
        #expect(collected.last(.docker)?.state == .ok, "o resto chegou")
    }

    @Test func resultsAreCachedUntilForced() async {
        let engine = DiagnosticsEngine(probes: probes())
        let first = Collected()
        await run(engine, into: first)
        let second = Collected()
        await run(engine, into: second)
        #expect(second.last(.gh) == first.last(.gh) && second.last(.docker) == first.last(.docker))
        let cached = await engine.probeRuns
        #expect(cached[.gh] == 1 && cached[.docker] == 1, "segunda rodada saiu do cache")
        await run(engine, force: true, into: Collected())
        let forced = await engine.probeRuns
        #expect(forced[.gh] == 2 && forced[.docker] == 2)
    }

    @Test func aTimedOutItemIsNotCached() async {
        let calls = Mutex(0)
        let engine = DiagnosticsEngine(
            probes: probes(gh: {
                let n = calls.withLock { $0 += 1; return $0 }
                if n == 1 { try? await Task.sleep(for: .seconds(30)) }
                return GitHubProbeResult(installed: false)
            }),
            configuration: .init(timeout: .milliseconds(100), cacheTTL: .seconds(60)))
        await run(engine, keys: [.gh], into: Collected())
        let retry = Collected()
        await run(engine, keys: [.gh], into: retry)
        #expect(retry.last(.gh)?.detail.hasPrefix("Not installed") == true, "Try Again refaz a sonda")
    }

    @Test func imageIsOnlyProbedWhenDockerIsRunning() async {
        let imageCalls = Mutex(0)
        let stopped = DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: false) }, docker: { .installedNotRunning(kind: .desktop) },
            image: { _ in imageCalls.withLock { $0 += 1 }; return .ready }, conflicts: { ConflictScan() })
        let collected = Collected()
        await run(DiagnosticsEngine(probes: stopped), into: collected)
        #expect(imageCalls.withLock { $0 } == 0)
        #expect(collected.last(.docker)?.fix == .startDocker)
        #expect(collected.last(.image)?.state == .neutral)
    }

    @Test func retryingOnlyTheRequestedItems() async {
        let engine = DiagnosticsEngine(probes: probes())
        await run(engine, into: Collected())
        await run(engine, keys: [.gh], force: true, into: Collected())
        let runs = await engine.probeRuns
        #expect(runs[.gh] == 2 && runs[.docker] == 1 && runs[.conflicts] == 1)
    }

    // MARK: Runtime nativo (sem Docker)

    private final class Hits: Sendable {
        private let state = Mutex(0)
        func bump() { state.withLock { $0 += 1 } }
        var value: Int { state.withLock { $0 } }
    }

    private func probes(mode: ComputerRuntimeMode, dockerCalls: Hits, imageCalls: Hits) -> DiagnosticsProbes {
        DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: false) },
            docker: { dockerCalls.bump(); return .notInstalled },
            image: { _ in imageCalls.bump(); return .missing }, conflicts: { ConflictScan() },
            runtime: { mode })
    }

    @Test func nativeRuntimeNeverProbesDockerAndShowsTheDownloadNote() async {
        let dockerCalls = Hits(), imageCalls = Hits()
        let collected = Collected()
        await run(DiagnosticsEngine(probes: probes(mode: .native(assetsInstalled: false), dockerCalls: dockerCalls, imageCalls: imageCalls)), into: collected)
        #expect(dockerCalls.value == 0 && imageCalls.value == 0, "nem o socket do Docker é tocado")
        #expect(collected.last(.docker) == nil && collected.last(.image) == nil, "nenhum item Docker nem imagem")
        let item = collected.last(.runtime)
        #expect(item?.title == "Computer runtime" && item?.state == .ok && item?.fix == nil)
        #expect(item?.detail == "Downloads automatically on first use (~470 MB)")
        for key in DiagnosticKey.allCases {
            if let text = collected.last(key).map({ "\($0.title) \($0.detail)" }) { #expect(!text.localizedCaseInsensitiveContains("docker"), "\(key): \(text)") }
        }
    }

    @Test func nativeRuntimeAlreadyDownloadedSaysInstalled() async {
        let collected = Collected()
        await run(DiagnosticsEngine(probes: probes(mode: .native(assetsInstalled: true), dockerCalls: Hits(), imageCalls: Hits())), into: collected)
        #expect(collected.last(.runtime)?.detail == "Installed")
    }

    @Test func forcedDockerKeepsTheDockerItemsAndHidesTheRuntimeItem() async {
        let dockerCalls = Hits()
        let collected = Collected()
        await run(DiagnosticsEngine(probes: probes(mode: .dockerForced, dockerCalls: dockerCalls, imageCalls: Hits())), into: collected)
        #expect(dockerCalls.value == 1)
        #expect(collected.last(.runtime) == nil)
        #expect(collected.last(.docker)?.detail == "Not installed. Needed for subagent computers.")
    }

    @Test func aMacThatCannotRunTheNativeRuntimeExplainsItAndOffersDocker() async {
        let collected = Collected()
        let mode = ComputerRuntimeMode.dockerOnly(reason: "The built-in computer runtime needs macOS 26 or later.")
        await run(DiagnosticsEngine(probes: probes(mode: mode, dockerCalls: Hits(), imageCalls: Hits())), into: collected)
        #expect(collected.last(.runtime) == nil)
        #expect(collected.last(.docker)?.detail == "Racky needs macOS 26 on Apple silicon, or Docker.")
        #expect(collected.last(.docker)?.fix == .openURL(title: "Install…", DiagnosticsEvaluator.dockerInstallURL))
    }

    @Test func aRuntimeProbeThatHangsFallsBackToTheDockerPath() async {
        let hang = DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: false) }, docker: { .notInstalled }, image: { _ in .missing }, conflicts: { ConflictScan() },
            runtime: { try? await Task.sleep(for: .seconds(30)); return .native(assetsInstalled: false) })
        let collected = Collected()
        await run(DiagnosticsEngine(probes: hang, configuration: .init(timeout: .milliseconds(100), cacheTTL: .seconds(60))), into: collected)
        #expect(collected.last(.docker)?.state == .warning)
    }
}
