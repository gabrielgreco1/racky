import RackyCore
import RackyProtocol
import AppKit
import Foundation
import ObjectiveC
import Testing

@testable import RackyUI

/// Quanto custa trocar de sessão numa janela de verdade (offscreen): a ação `session.select` mais o layout e o desenho que ela
/// provoca. Com `RACKY_SWITCH_TRACE=1` imprime o tempo próprio do `layout()` de cada classe de view (diagnóstico).
@MainActor
@Suite(.serialized, .offscreenAppKit, .tags(.integration)) struct SessionSwitchPerfTests {
    @Test func switchingSessionsIsCheap() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-switch-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let ids = Array(env.sidebar.projection.sessionOrder.prefix(6))
        try #require(ids.count >= 3)
        env.sidebar.select(ids[0])
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1500, height: 900))
        let window = try #require(c.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await VisualBatchTests.settle(500)

        let trace = ProcessInfo.processInfo.environment["RACKY_SWITCH_TRACE"] == "1"
        if trace { SwitchLayoutTrace.install() }
        defer { if trace { SwitchLayoutTrace.uninstall() } }

        func flush() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        // Aquecimento: cada sessão aparece uma vez (cria os panes); o que interessa é trocar entre sessões já vistas.
        for id in ids { _ = try await env.registry.perform(.sessionSelect, .select(id.uuidString)); flush(); await VisualBatchTests.settle(50) }
        SwitchLayoutTrace.reset()
        if trace {
            // Atribuição: depois da ação, o layout de cada hosting view (as mais fundas primeiro) e a ação em si.
            var perHost: [String: Double] = [:]
            var action = 0.0
            func hosts(_ v: NSView, _ depth: Int, _ out: inout [(NSView, Int)]) {
                if String(describing: type(of: v)).contains("Hosting") { out.append((v, depth)) }
                for c in v.subviews { hosts(c, depth + 1, &out) }
            }
            for _ in 0 ..< 3 {
                for id in ids {
                    let a0 = CFAbsoluteTimeGetCurrent()
                    _ = try await env.registry.perform(.sessionSelect, .select(id.uuidString))
                    action += (CFAbsoluteTimeGetCurrent() - a0) * 1000
                    var list: [(NSView, Int)] = []
                    if let root = window.contentView?.superview { hosts(root, 0, &list) }
                    for (v, _) in list.sorted(by: { $0.1 > $1.1 }) {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        v.layoutSubtreeIfNeeded()
                        let name = "\(type(of: v)) \(Int(v.bounds.width))x\(Int(v.bounds.height)) id=\(v.accessibilityIdentifier())"
                        perHost[name, default: 0] += (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    }
                    let d0 = CFAbsoluteTimeGetCurrent()
                    flush()
                    perHost["(rest: window layout + display)", default: 0] += (CFAbsoluteTimeGetCurrent() - d0) * 1000
                }
            }
            print(String(format: "ACTION total=%.1fms over %d switches", action, ids.count * 3))
            for (k, v) in perHost.sorted(by: { $0.value > $1.value }).prefix(20) { print(String(format: "HOST %8.1fms  %@", v, String(k.prefix(150)))) }
        }
        var times: [Double] = []
        for _ in 0 ..< 3 {
            for id in ids {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try await env.registry.perform(.sessionSelect, .select(id.uuidString))
                flush()
                // O que o SwiftUI agenda para o próximo ciclo também conta.
                await Task.yield()
                flush()
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        times.sort()
        let median = times[times.count / 2]
        print(String(format: "SWITCH median=%.1fms p90=%.1fms max=%.1fms n=%d", median, times[times.count * 9 / 10], times.last ?? 0, times.count))
        if trace { SwitchLayoutTrace.report() }
        #expect(median < 120, "trocar de sessão já vista deve caber em poucos quadros")
    }
}

/// Troca o `layout()` de NSView por uma versão que mede o tempo próprio (sem os filhos) por classe. Só no diagnóstico.
@MainActor
enum SwitchLayoutTrace {
    static var installed = false
    static var own: [String: Double] = [:]
    static var count: [String: Int] = [:]
    static var starts: [CFAbsoluteTime] = []
    static var children: [Double] = []

    static func install() {
        guard !installed else { return }
        installed = true
        swap()
    }
    static func uninstall() {
        guard installed else { return }
        installed = false
        swap()
    }
    private static func swap() {
        let a = class_getInstanceMethod(NSView.self, #selector(NSView.layout))!
        let b = class_getInstanceMethod(NSView.self, #selector(NSView.rackyTraceLayout))!
        method_exchangeImplementations(a, b)
    }
    static func reset() { own = [:]; count = [:] }
    static func begin() { starts.append(CFAbsoluteTimeGetCurrent()); children.append(0) }
    static func end(_ view: NSView) {
        guard let start = starts.popLast(), let kids = children.popLast() else { return }
        let total = CFAbsoluteTimeGetCurrent() - start
        if !children.isEmpty { children[children.count - 1] += total }
        var name = String(describing: type(of: view))
        if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) + "<" + String(name[name.index(after: generic)...].prefix(60)) }
        own[name, default: 0] += (total - kids) * 1000
        count[name, default: 0] += 1
    }
    static func report() {
        for (k, v) in own.sorted(by: { $0.value > $1.value }).prefix(25) {
            print(String(format: "LAYOUT %8.1fms x%5d  %@", v, count[k] ?? 0, k))
        }
    }
}

extension NSView {
    @objc func rackyTraceLayout() {
        MainActor.assumeIsolated { SwitchLayoutTrace.begin() }
        rackyTraceLayout()
        MainActor.assumeIsolated { SwitchLayoutTrace.end(self) }
    }
}
