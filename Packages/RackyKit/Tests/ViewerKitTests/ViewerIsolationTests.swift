import AppKit
import Foundation
import Testing

@testable import RackyViewerKit

@Suite("T3-05 - viewer isolado", .tags(.integration))
@MainActor
struct ViewerIsolationTests {
    @Test func schemeServesOnlyFilesInsideTheVendoredFolder() {
        #expect(ViewerScheme.resolve(path: "/viewer.html") != nil)
        #expect(ViewerScheme.resolve(path: "/viewer.js") != nil)
        #expect(ViewerScheme.resolve(path: "/novnc/core/rfb.js") != nil)
        #expect(ViewerScheme.resolve(path: "/novnc/vendor/pako/lib/zlib/inflate.js") != nil)
        for evil in ["/../Package.swift", "/novnc/../../Viewer", "/novnc", "/", "", "/..%2f..", "/novnc/core/../../../x", "/nope.js", "/\0viewer.html"] {
            #expect(ViewerScheme.resolve(path: evil) == nil, "\(evil)")
        }
        #expect(ViewerScheme.mimeType(for: URL(fileURLWithPath: "/a/b.js")).hasPrefix("text/javascript"))
        #expect(ViewerScheme.mimeType(for: URL(fileURLWithPath: "/a/b.html")).hasPrefix("text/html"))
    }

    @Test func vendoredNoVNCIsPinnedAndLicensed() throws {
        let version = try String(contentsOf: ViewerScheme.root.appendingPathComponent("novnc/VERSION.txt"), encoding: .utf8)
        #expect(version.contains("noVNC 1.6.0") && version.contains("5066103959ef4e9b10f37e5a148627360dd8414e4cf8a7db92bdbd022e728aaa"))
        #expect(FileManager.default.fileExists(atPath: ViewerScheme.root.appendingPathComponent("novnc/LICENSE.txt").path))
    }

    @Test func onlyTheLocalSchemeMayNavigate() {
        #expect(ViewerIsolation.allowsNavigation(to: ViewerScheme.pageURL))
        for url in ["https://example.com/", "http://127.0.0.1:8790/", "file:///etc/passwd", "racky-viewer://evil/viewer.html", "ws://127.0.0.1:1/vnc", "about:blank"] {
            #expect(!ViewerIsolation.allowsNavigation(to: URL(string: url)), "\(url)")
        }
        #expect(!ViewerIsolation.allowsNavigation(to: nil))
    }

    @Test func eventsParseFromTheBridge() {
        #expect(ViewerEvent.parse(["type": "ready"]) == .ready)
        #expect(ViewerEvent.parse(["type": "state", "value": "live"]) == .state("live", detail: nil))
        #expect(ViewerEvent.parse(["type": "stats", "fps": 24.5, "frames": 100, "silentMs": 3, "sinceFrameMs": 20])
            == .stats(fps: 24.5, frames: 100, silentMs: 3, sinceFrameMs: 20))
        #expect(ViewerEvent.parse(["type": "reserved", "action": "handback"]) == .reserved("handback"))
        #expect(ViewerEvent.parse(["type": "keyboard", "captured": true]) == .keyboard(captured: true))
        #expect(ViewerEvent.parse(["type": "nope"]) == nil)
        #expect(ViewerEvent.parse("not a dict") == nil)
    }

    /// WKWebView real (sem janela): a página sobe pelo esquema local, o noVNC carrega como módulo e nada sai para a internet.
    @Test func webViewLoadsLocallyAndCannotReachTheInternet() async throws {
        let view = ComputerViewerWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        var events: [ViewerEvent] = []
        view.onEvent = { events.append($0) }
        await view.load()
        for _ in 0..<100 where !view.isReady { try await Task.sleep(for: .milliseconds(100)) }
        #expect(view.isReady, "viewer.js did not announce ready: \(events)")
        let api = await view.evaluateForTesting("return typeof window.rackyViewer.connect")
        #expect(api as? String == "function")
        // fetch para fora: CSP e regras de conteúdo
        let external = await view.evaluateForTesting(
            "try { await fetch('https://example.com/', {mode: 'no-cors'}); return 'reached'; } catch (e) { return 'blocked'; }")
        #expect(external as? String == "blocked")
        let socket = await view.evaluateForTesting(
            "return await new Promise((resolve) => { try { const ws = new WebSocket('wss://example.com/'); ws.onerror = () => resolve('blocked'); ws.onopen = () => resolve('reached'); setTimeout(() => resolve('blocked'), 3000); } catch (e) { resolve('blocked'); } })")
        #expect(socket as? String == "blocked")
        let image = await view.evaluateForTesting(
            "return await new Promise((resolve) => { const i = new Image(); i.onload = () => resolve('reached'); i.onerror = () => resolve('blocked'); i.src = 'https://example.com/x.png'; setTimeout(() => resolve('blocked'), 3000); })")
        #expect(image as? String == "blocked")
        // navegação para fora é cancelada e reportada
        _ = await view.evaluateForTesting("window.location.href = 'https://example.com/'; return 1")
        try await Task.sleep(for: .milliseconds(800))
        #expect(events.contains { if case .blockedNavigation = $0 { true } else { false } })
        let stillHere = await view.evaluateForTesting("return location.href")
        #expect((stillHere as? String)?.hasPrefix("racky-viewer://app/") == true)
    }
}
