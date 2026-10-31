@testable import RackyCore
import RackyProtocol
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RackyUI

/// Prints da aba Computers e da tela Traffic com um log de run de verdade (`RACKY_TRAFFIC_LOGS=<run>/logs`). Só roda com
/// `RACKY_CAPTURE_DIR=<pasta>`; o app do usuário não é tocado.
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] != nil)) struct TrafficCaptureTests {
    private func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"]!)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func captureComputersPanelAndTraffic() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RACKY_TRAFFIC_LOGS"]))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let run = home.appendingPathComponent("runs/demo/booking-lisbon", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: run.appendingPathComponent("logs"))
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let traffic = env.traffic
        traffic.sessionRuns = { ["booking-lisbon": run] }
        traffic.proxySource = { ["zyte": .init(host: "api.zyte.com", pricePerRequestMicros: 1_200)] }
        _ = try await env.registry.perform(.rightPanelComputersPick, .select("booking-lisbon"))
        await traffic.tick()

        let panel = NSHostingView(rootView: ComputersInsightsPanel(computers: env.computers, traffic: traffic, insights: env.insights)
            .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements).preferredColorScheme(.dark))
        panel.frame = NSRect(x: 0, y: 0, width: 440, height: 1100)
        let w1 = OffscreenAppKit.makeWindow(size: panel.frame.size)
        w1.contentView = panel
        try await Task.sleep(for: .milliseconds(400))
        write(panel, "computers-panel")
        _ = w1

        let id = try #require(traffic.entries["booking-lisbon"]?.first { $0.url.contains("graphql") && $0.responseBodyFile != nil }?.id)
        _ = try await env.registry.perform(.trafficSet, .select("booking-lisbon|select=\(id)"))
        for (size, name) in [(NSSize(width: 1100, height: 820), "traffic-wide"), (NSSize(width: 620, height: 820), "traffic-narrow")] {
            let view = NSHostingView(rootView: TrafficPaneView(traffic: traffic, name: "booking-lisbon", close: {})
                .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements).preferredColorScheme(.dark))
            view.frame = NSRect(origin: .zero, size: size)
            let window = OffscreenAppKit.makeWindow(size: size)
            window.contentView = view
            try await Task.sleep(for: .milliseconds(400))
            write(view, name)
            _ = window
        }
    }

    /// Página Computers sem computadores e com dezenas de runs em Left on disk: o header fica no topo e a página rola.
    @Test func captureComputersPageWithManyLeftovers() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("leftovers-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let view = NSHostingView(rootView: ComputersPageView(controller: env.computers, settings: env.settings)
            .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements).preferredColorScheme(.dark))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let window = OffscreenAppKit.makeWindow(size: view.frame.size)
        window.contentView = view
        // Depois do `.task` da página (que relê a pasta vazia de teste).
        try await Task.sleep(for: .milliseconds(300))
        env.computers.leftovers = (0..<40).map { i in
            RunLeftover(key: "s/run-\(i)", root: home, computer: "run-\(i)", session: "session", endedAt: Date(), policy: nil, bytes: Int64(1_000_000 * (40 - i)))
        }
        try await Task.sleep(for: .milliseconds(400))
        write(view, "computers-page-leftovers")
        _ = window
    }

    /// Página Computers com a nuvem escolhida e a AWS conectada: status da conta, VM ligada e gasto.
    @Test func captureCloudConnected() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        _ = try await env.registry.perform(.computersRunOn, .select("cloud"))
        _ = try await env.registry.perform(.computersCloudRegion, .select("us-east-2"))
        env.settings.cloudConnection = .connected(account: "233320879143")
        let now = Date()
        var snapshot = CloudSnapshot()
        snapshot.hosts = [.init(id: "i-0d6833ef138646141", region: "us-east-2", shape: "t4g.small", startedAt: now.addingTimeInterval(-780), hourlyUSD: 0.0251, computers: 1)]
        snapshot.records = [
            SpendRecord(hostID: "i-01f228e35c8d19809", startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-3420), expiresAt: now, hourlyUSD: 0.0251, region: "us-east-2", shape: "t4g.small"),
            SpendRecord(hostID: "i-0007e1d33e27fba10", startedAt: now.addingTimeInterval(-1900), endedAt: now.addingTimeInterval(-1700), expiresAt: now, hourlyUSD: 0.0251, region: "us-east-2", shape: "t4g.small"),
        ]
        snapshot.todayUSD = 0.0087
        snapshot.monthUSD = 0.0087
        env.settings.cloudSnapshot = snapshot
        for state in ["setup", "saved"] {
            if state == "saved" { _ = try await env.registry.perform(.computersCloudSave, nil) }
            let view = NSHostingView(rootView: ComputersPageView(controller: env.computers, settings: env.settings)
                .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 1900)
            let window = OffscreenAppKit.makeWindow(size: view.frame.size)
            window.contentView = view
            try await Task.sleep(for: .milliseconds(300))
            env.computers.leftovers = [("booking-lisbon", "dusty-ridge", 48_500_000, nil), ("jsc-mediadores", "tidy-nebula", 21_500_000, nil),
                                       ("wiki-lisboa-2", "quiet-meadow", 1_300_000, LeftoversPolicy.days7), ("mail-maps-web", "tidy-nebula", 5_600_000, nil),
                                       ("tripadvisor-lisbon", "rapid-grove", 414_000, nil), ("books-p1-4", "datasets test", 246_000, nil)]
                .map { RunLeftover(key: "s/\($0.0)", root: home, computer: $0.0, session: $0.1, endedAt: now.addingTimeInterval(-86_400), policy: $0.3, bytes: $0.2) }
                .sorted { $0.bytes > $1.bytes }
            try await Task.sleep(for: .milliseconds(900))
            write(view, "computers-cloud-\(state)")
            _ = window
        }
    }
}
