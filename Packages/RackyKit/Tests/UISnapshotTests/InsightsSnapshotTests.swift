import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshots das abas do módulo Insights (Claude, Codex, Machine, Proxy) em largura cheia (310, padrão do painel direito),
/// larga (480) e compacta (220). Dados 100% sintéticos (`InsightsPreviewData`). Gravar com `RACKY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite(.serialized) struct InsightsSnapshotTests {
    func registry(for model: InsightsModel) -> ActionRegistry {
        let elements = UIElementStore()
        let flags = SliceFlags()
        let registry = ActionRegistry(flags: flags, surface: WindowAutomation(store: elements, flags: flags, fixture: nil, automationEnabled: false))
        try? model.register(in: registry)
        return registry
    }

    func snap(_ model: InsightsModel, compact: Bool = false, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on  // valores finais, sem contagem em andamento
        defer { MotionPolicy.shared.preference = previous }
        let root = InsightsModuleView(model: model, compact: compact)
            .environment(\.actionRegistry, registry(for: model))
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "insights", line: line)
        }
    }

    static let tall = CGSize(width: 310, height: 760)

    @Test func claudeFull() { snap(InsightsPreviewData.model(tab: .claude), size: Self.tall, name: "claude-310") }
    @Test func claudeWithoutExactLimits() {
        snap(InsightsPreviewData.model(tab: .claude, exact: false), size: CGSize(width: 310, height: 440), name: "claude-no-exact-310")
    }
    @Test func claudeNeedsRefresh() {
        var s = InsightsPreviewData.snapshot(exact: false, limits: .needsClaudeRefresh)
        s.claude = InsightsPreviewData.provider(.claude, exact: false)
        snap(InsightsPreviewData.model(tab: .claude, snapshot: s), size: CGSize(width: 310, height: 440), name: "claude-refresh-310")
    }
    @Test func claudeNearLimit() {
        var s = InsightsPreviewData.snapshot()
        s.claude = InsightsPreviewData.provider(.claude, level: 0.82, weekly: 0.97)
        snap(InsightsPreviewData.model(tab: .claude, snapshot: s), size: CGSize(width: 310, height: 760), name: "claude-near-limit-310")
    }
    @Test func claudeWide() { snap(InsightsPreviewData.model(tab: .claude), size: CGSize(width: 560, height: 560), name: "claude-wide-560") }
    @Test func claudeCondensed() { snap(InsightsPreviewData.model(tab: .claude), size: CGSize(width: 380, height: 420), name: "claude-condensed-380") }
    @Test func codexFull() { snap(InsightsPreviewData.model(tab: .codex), size: Self.tall, name: "codex-310") }
    @Test func machineFull() { snap(InsightsPreviewData.model(tab: .machine), size: CGSize(width: 310, height: 1_000), name: "machine-310") }
    @Test func machineWide() { snap(InsightsPreviewData.model(tab: .machine), size: CGSize(width: 560, height: 640), name: "machine-wide-560") }
    @Test func proxyFull() { snap(InsightsPreviewData.model(tab: .proxy), size: CGSize(width: 310, height: 520), name: "proxy-310") }

    @Test func compactTabs() {
        for tab in InsightsTab.allCases {
            snap(InsightsPreviewData.model(tab: tab), size: CGSize(width: 260, height: 220), name: "\(tab.rawValue)-compact-260")
        }
    }

    @Test func forcedCompactAtNormalWidth() {
        snap(InsightsPreviewData.model(tab: .machine), compact: true, size: CGSize(width: 310, height: 260), name: "machine-forced-compact-310")
    }

    @Test func emptyStates() {
        snap(InsightsModel(preview: .empty, tab: .claude, now: InsightsPreviewData.now), size: CGSize(width: 310, height: 240), name: "claude-empty-310")
        snap(InsightsModel(preview: .empty, tab: .machine, now: InsightsPreviewData.now), size: CGSize(width: 310, height: 240), name: "machine-empty-310")
        snap(InsightsModel(preview: .empty, tab: .proxy, now: InsightsPreviewData.now), size: CGSize(width: 310, height: 240), name: "proxy-empty-310")
    }

    @Test func dockerUnavailableAndHighLoadStates() {
        var s = InsightsPreviewData.snapshot()
        s.dockerAvailable = false
        s.computers = []
        s.machine?.cpu = CPUSample(total: 0.93, user: 0.8, system: 0.13, perCore: Array(repeating: 0.93, count: 14), load1: 12, load5: 9, load15: 6)
        s.machine?.memory?.pressure = .critical
        snap(InsightsPreviewData.model(tab: .machine, snapshot: s), size: CGSize(width: 310, height: 1_000), name: "machine-stressed-310")
    }
}

/// Teste de layout (F21): renderiza o módulo em várias combinações de tamanho e falha se algum elemento sair dos limites.
/// Com altura abaixo do mínimo do modo compacto o módulo rola por dentro; fora disso nada pode passar da caixa.
@MainActor
@Suite(.serialized) struct InsightsLayoutTests {
    nonisolated static let sizes: [CGSize] = [
        CGSize(width: 260, height: 200), CGSize(width: 320, height: 300), CGSize(width: 380, height: 500), CGSize(width: 520, height: 800),
        CGSize(width: 260, height: 700), CGSize(width: 300, height: 260), CGSize(width: 480, height: 240), CGSize(width: 600, height: 420),
        CGSize(width: 720, height: 300), CGSize(width: 340, height: 900),
    ]
    /// Altura mínima do módulo inteiro (abas + modo compacto) abaixo da qual a rolagem interna é permitida.
    nonisolated static let compactMinHeight: CGFloat = 170

    func probe(_ tab: InsightsTab, size: CGSize, exact: Bool = true) -> [String: CGRect] {
        DSFonts.registerIfNeeded()
        let probe = LayoutProbe()
        let model = InsightsPreviewData.model(tab: tab, exact: exact)
        let host = NSHostingView(rootView: InsightsModuleView(model: model)
            .environment(\.layoutProbe, probe)
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }
        return probe.frames
    }

    @Test(arguments: InsightsTab.allCases, sizes)
    func nothingLeavesTheBox(tab: InsightsTab, size: CGSize) {
        let frames = probe(tab, size: size)
        #expect(!frames.isEmpty, "no probes reported for \(tab) at \(size)")
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
        for (id, frame) in frames {
            #expect(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX, "\(tab) \(id) leaves horizontally at \(size): \(frame)")
            if size.height >= Self.compactMinHeight {
                #expect(frame.minY >= bounds.minY && frame.maxY <= bounds.maxY, "\(tab) \(id) leaves vertically at \(size): \(frame)")
            }
        }
    }

    @Test func layoutModeFollowsTheBreakpoints() {
        func modes(_ size: CGSize) -> Set<String> { Set(probe(.claude, size: size).keys.filter { $0.hasPrefix("pane.") }) }
        #expect(modes(CGSize(width: 700, height: 800)) == ["pane.wide"])
        #expect(modes(CGSize(width: 380, height: 900)) == ["pane.medium"])
        #expect(modes(CGSize(width: 260, height: 800)) == ["pane.compact"])
        // Sem altura para a coluna inteira o módulo desce para o próximo layout que cabe.
        #expect(modes(CGSize(width: 380, height: 420)) == ["pane.condensed"])
        #expect(modes(CGSize(width: 380, height: 200)) == ["pane.compact"])
    }

    @Test func compactStillShowsBothLimitBars() {
        let frames = probe(.claude, size: CGSize(width: 260, height: 200))
        #expect(frames["limits.5h"] != nil && frames["limits.7d"] != nil)
    }

    @Test func missingExactLimitsStillFits() {
        for size in Self.sizes {
            let frames = probe(.claude, size: size, exact: false)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            for (id, frame) in frames {
                #expect(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX, "\(id) leaves horizontally at \(size)")
                if size.height >= Self.compactMinHeight { #expect(frame.maxY <= bounds.maxY, "\(id) leaves vertically at \(size)") }
            }
        }
    }
}

@MainActor
@Suite struct InsightsModelTests {
    @Test func historyKeepsOnlyTheLastSamples() {
        var h = InsightsHistory()
        let machine = InsightsPreviewData.machine()
        for _ in 0..<(InsightsHistory.capacity + 25) { h.append(machine) }
        #expect(h.cpu.count == InsightsHistory.capacity)
        #expect(h.down.count == InsightsHistory.capacity)
    }

    @Test func applyAppendsHistoryOnlyForNewMachineSamples() {
        let model = InsightsModel(preview: .empty, now: InsightsPreviewData.now)
        var s = InsightsPreviewData.snapshot()
        model.apply(s)
        model.apply(s)  // mesma amostra: não duplica
        #expect(model.history.cpu.count == 1)
        let next = s.machine!.at.addingTimeInterval(1.5)
        s.machine?.at = next
        model.apply(s)
        #expect(model.history.cpu.count == 2)
    }

    @Test func serviceBackedModelStreamsMachineSamplesWhileVisible() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-insights-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = InsightsConfig(
            claudeProjects: dir.appendingPathComponent("p"), codexSessions: dir.appendingPathComponent("c"),
            ledgerURL: dir.appendingPathComponent("l.json"), claudeRateLimitsURL: dir.appendingPathComponent("r.json"),
            machineInterval: 0.05, usageRefreshInterval: 3_600)
        let service = InsightsService(config: config, runner: SystemInsightsCommandRunner(timeout: .milliseconds(1)))
        let model = InsightsModel(service: service, tab: .machine)
        model.viewDidAppear()
        for _ in 0..<60 where model.snapshot.machine == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.snapshot.machine != nil)
        model.viewDidDisappear()
        // Fora de vista a amostragem para: espera duas leituras seguidas iguais (sob carga o `setVisible(false)` assíncrono
        // pode levar mais que um intervalo fixo).
        var stopped = false
        for _ in 0..<20 where !stopped {
            let stamp = await service.current.machine?.at
            try await Task.sleep(for: .milliseconds(300))
            stopped = await service.current.machine?.at == stamp
        }
        #expect(stopped, "machine sampling kept running after the panel hid")
        await service.stop()
    }
}

@Suite struct InsightsFormatTests {
    @Test func tokens() {
        #expect(InsightsFormat.tokens(842) == "842")
        #expect(InsightsFormat.tokens(1_000) == "1K")
        #expect(InsightsFormat.tokens(12_340) == "12.3K")
        #expect(InsightsFormat.tokens(27_222_968) == "27.2M")
        #expect(InsightsFormat.tokens(1_300_000_000) == "1.3B")
    }

    @Test func costPercentDuration() {
        #expect(InsightsFormat.cost(0.4) == "$0.40")
        #expect(InsightsFormat.cost(565.2) == "$565")
        #expect(InsightsFormat.cost(1_969) == "$2K")
        #expect(InsightsFormat.percent(0.314) == "31%")
        #expect(InsightsFormat.duration(45) == "45s")
        #expect(InsightsFormat.duration(2 * 3_600 + 41 * 60) == "2h 41m")
        #expect(InsightsFormat.duration(3 * 86_400 + 4 * 3_600) == "3d 4h")
    }

    @Test func bytesAndRates() {
        #expect(InsightsFormat.bytes(512 * 1_048_576) == "512 MB")
        #expect(InsightsFormat.bytes(3_650_722_201) == "3.4 GB")
        #expect(InsightsFormat.rate(2_350_000) == "2.2 MB/s")
        #expect(InsightsFormat.rate(512) == "512 B/s")
    }

    @Test func namesAndHeat() {
        #expect(InsightsFormat.modelName("claude-opus-5-5") == "opus-5-5")
        #expect(InsightsFormat.modelName("gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(InsightsFormat.plan("team") == "Team")
        #expect(InsightsFormat.plan(nil) == nil)
        #expect(InsightsFormat.heatLevel(0, max: 10) == 0)
        #expect(InsightsFormat.heatLevel(0.01, max: 10) == 1)
        #expect(InsightsFormat.heatLevel(10, max: 10) == 4)
        #expect(InsightsFormat.ago(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 7_300)) == "2h")
    }
}
