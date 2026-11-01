import RackyCore
import RackyProtocol
import Foundation
import Testing

@testable import RackyUI

/// Snapshots offscreen de Settings › Computers › Proxies: vazio, lista com padrão e formulário aberto (com teste ok) e tela estreita.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ProxiesSnapshotTests {
    private let base = SettingsSnapshotTests()

    static let zyte = ProxyProfile(
        id: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!, name: "zyte", preset: .zyte, scheme: .http, host: "proxy.zyte.com", port: 8011,
        isDefault: true)
    static let office = ProxyProfile(
        id: UUID(uuidString: "00000000-0000-7000-8000-000000000002")!, name: "office-socks", scheme: .socks5, host: "gw.example.net", port: 1080, username: "alex",
        geo: ProxyGeo(country: "us"))

    @Test func emptyList() async {
        await base.settingsSnap("computers", size: CGSize(width: 1440, height: 900), variant: "-proxiesEmpty")
    }

    @Test func listWithDefaultAndTheFormOpenAfterATest() async {
        await base.settingsSnap("computers", size: CGSize(width: 1440, height: 1500), variant: "-proxiesForm") { model in
            model.proxies = [Self.zyte, Self.office]
            model.defaultProxyID = Self.zyte.id
            model.zyteImportAvailable = true
            model.proxyDraft = ProxyDraft(Self.office)
            model.proxyTest = .result(ProxyTestResult(ok: true, summary: "Connected through gw.example.net · 312 ms", latencyMilliseconds: 312))
        }
    }

    @Test func newProxyWithAValidationErrorAndDeleteConfirmation() async {
        await base.settingsSnap("computers", size: CGSize(width: 1440, height: 1500), variant: "-proxiesNew") { model in
            model.proxies = [Self.zyte]
            model.proxyDeleteArmed = Self.zyte.id
            model.newProxy()
            model.proxyDeleteArmed = Self.zyte.id
            model.updateProxyDraft { $0.name = "office"; $0.host = "gw.example.net"; $0.port = "99999" }
            model.setProxyError("Port must be 1–65535.")
        }
    }

    @Test func narrowWindow() async {
        await base.settingsSnap("computers", size: CGSize(width: 760, height: 900), variant: "-proxiesNarrow") { model in
            model.proxies = [Self.zyte, Self.office]
            model.defaultProxyID = Self.zyte.id
            model.proxyDraft = ProxyDraft(Self.zyte)
        }
    }
}
