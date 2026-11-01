import RackyCore
import RackyPlatform
import RackyViewerKit
import AppKit
import Foundation
import Observation

/// Medições do viewer dentro do WKWebView (spike S3): quadros por segundo do noVNC e latência de input.
public struct ViewerMeasurement: Codable, Sendable, Equatable {
    public var fpsSamples: [Double] = []
    public var fpsAverage = 0.0
    public var fpsMin = 0.0
    public var latencySamplesMs: [Double] = []
    public var latencyP50Ms = 0.0
    public var latencyP95Ms = 0.0
    public var appActive = false
    public var windowVisible = false
    public var note = ""
    public var wsMessages = 0
    public var wsBytes = 0
    public var pageHidden = false
}

/// Liga o modelo do viewer ao `WKWebView` (noVNC): pede o ticket, conecta, reconecta com recuo, repassa o lease ao WebView
/// (input só com humano no controle e stream vivo) e traduz os atalhos reservados (⇧⌘R, ⌘⎋, ⌃⌥, ⌘V).
@MainActor
@Observable
public final class ComputerViewerController {
    public let model: ComputerViewerModel
    @ObservationIgnored public let web: ComputerViewerWebView
    public let computer: ManagedComputer
    public private(set) var lastError: String?
    /// Estado das medições do S3 (só com `RACKY_VIEWER_MEASURE`).
    public private(set) var measurement: ViewerMeasurement?
    @ObservationIgnored private let log = LogFacade(.app, category: "viewer")
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Cada `connect()` pede o próprio ticket; só a tentativa mais nova conecta (a velha, que voltou tarde, é descartada).
    @ObservationIgnored private var attempt = 0
    /// Ticket -> WebSocket -> stream vivo (AR-605).
    @ObservationIgnored private var vncPerf: PerfInterval?
    @ObservationIgnored private var lastAttemptAt = Date.distantPast
    @ObservationIgnored private var pageReady = false
    /// Quedas seguidas sem nenhum quadro: o ticket de uso único (60 s) já foi gasto, então toda tentativa pede um novo.
    @ObservationIgnored public private(set) var ticketsRequested = 0
    @ObservationIgnored private var fpsHistory: [Double] = []
    @ObservationIgnored public var onClose: () -> Void = {}
    @ObservationIgnored public var onRequestPopOut: () -> Void = {}

    public var name: String { computer.name }

    public init(computer: ManagedComputer) {
        self.computer = computer
        model = ComputerViewerModel(computer: computer)
        web = ComputerViewerWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        web.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Ciclo de vida

    public func start() async {
        guard !started else { return }
        started = true
        await web.load()
        await model.refresh()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.model.tick()
                await self.model.refresh()
                self.syncInput()
                self.watchdog()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        reconnect?.cancel()
        reconnect = nil
        attempt += 1  // uma resposta de ticket que chegar depois de fechar o viewer não conecta
        web.disconnect()
        started = false
    }

    /// Pede um ticket novo (uso único, 60 s) e conecta. O ticket nunca é reaproveitado numa reconexão.
    public func connect() async {
        guard model.connection != .stopped else { return }
        attempt += 1
        let mine = attempt
        lastAttemptAt = Date()
        vncPerf?.end(tags: ["result": "superseded"])
        vncPerf = Perf.begin(.vncConnect)
        do {
            ticketsRequested += 1
            let url = try await model.computer.vncEndpoint()
            guard mine == attempt, model.connection != .stopped else { return }
            web.connect(to: url)
            lastError = nil
        } catch {
            guard mine == attempt else { return }
            lastError = "\(error)"
            log.error("viewer ticket failed: \(error)")
            model.ticketFailed("\(error)")
            retryIfNeeded()
        }
    }

    /// Roda a cada segundo: nunca deixa o viewer parado sem tentar de novo enquanto o computador está de pé. Cobre o computador
    /// que voltou de `stopped` (o modelo vira `connecting`, mas ninguém reconectava), o "connecting" que não andou e o
    /// "Disconnected" depois do limite de tentativas (uma tentativa lenta a cada 15 s; o botão Reconnect continua valendo).
    private func watchdog() {
        guard pageReady, model.connection != .stopped, reconnect == nil else { return }
        let idle = Date().timeIntervalSince(lastAttemptAt)
        switch model.connection {
        case .connecting where idle > 12, .reconnecting where idle > 12, .error where idle > 15, .disconnected where idle > 15:
            Task { await connect() }
        default: break
        }
    }

    public func reconnectNow() {
        reconnect?.cancel()
        reconnect = nil
        model.reconnectRequested()
        Task { await connect() }
    }

    // MARK: Eventos do WebView

    func handle(_ event: ViewerEvent) {
        switch event {
        case .ready:
            pageReady = true
            Task { await connect() }
        case .state(let value, let detail):
            model.streamState(value, detail: detail)
            if value == "disconnected" { retryIfNeeded() }
            if value == "live" {
                vncPerf?.end(tags: ["result": "live"])
                vncPerf = nil
                syncInput()
            }
        case .stats(let fps, let frames, let silentMs, _):
            model.streamStats(fps: fps, frames: frames, silentMs: silentMs)
            if model.connection == .live { fpsHistory.append(fps) }
        case .keyboard(let captured):
            model.keyboard(captured: captured)
        case .reserved(let action):
            reserved(action)
        case .blockedInput:
            model.blockedClick()
        case .input:
            let computer = computer
            Task { await computer.noteHumanActivity() }
        case .error(let detail):
            model.streamError(detail)
        case .jsError(let detail):
            log.error("viewer js error: \(detail)")
        case .blockedNavigation, .desktopName:
            break
        }
    }

    /// Queda ou ticket negado: antes da primeira conexão tenta de novo a cada 2 s (o computador está subindo); depois, recuo
    /// exponencial até 8 s.
    private func retryIfNeeded() {
        switch model.connection {
        case .connecting where !model.hasBeenLive: scheduleReconnect(after: 2)
        case .reconnecting(let n): scheduleReconnect(after: min(Double(1 << min(n, 3)), 8))
        default: break
        }
    }

    private func scheduleReconnect(after seconds: Double) {
        reconnect?.cancel()
        reconnect = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.reconnect = nil
            switch self.model.connection {
            case .reconnecting, .connecting: await self.connect()
            default: break
            }
        }
    }

    private func reserved(_ action: String) {
        switch action {
        case "handback": Task { await toggleControl() }
        case "release-keyboard": releaseKeyboard()
        case "paste": Task { await pasteFromClipboard() }
        default: break
        }
    }

    /// O WebView só aceita input com humano no controle e stream vivo (CS-402, CS-404).
    func syncInput() {
        web.setInputEnabled(model.inputEnabled)
    }

    // MARK: Ações

    public func takeOver(force: Bool = false) async {
        _ = await model.takeOver(force: force)
        syncInput()
        if model.control == .human { web.focusCanvas() }
    }

    public func toggleControl() async {
        switch model.control {
        case .agent: await takeOver()
        case .human:
            if model.handBackNoteVisible { await handBack() } else { model.showHandBackNote() }
        case .revoking: break
        }
    }

    public func handBack() async {
        await model.handBack()
        web.releaseKeyboard()
        syncInput()
    }

    public func releaseKeyboard() {
        model.releaseKeyboard()
        web.releaseKeyboard()
    }

    /// `Paste to Computer`: ação explícita (⌘V no viewer com controle humano ou o botão). Digita o texto do clipboard no computador.
    @discardableResult
    public func pasteFromClipboard() async -> Int {
        guard model.control == .human, model.inputEnabled, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return 0 }
        return await web.typeText(text)
    }

    /// `Copy Selection from Computer`: só a seleção da página, só por ação explícita.
    @discardableResult
    public func copySelection() async -> Bool {
        guard let out = try? await computer.backend.runtime("selection", [:], timeout: 8), let text = out["text"]?.string, !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    // MARK: Medição (S3)

    /// Mede o fps do noVNC por `seconds` (a página do computador deve estar animando) e a latência de input (a página deve
    /// reagir ao mouse). `prepareLatency` troca a página; o lease humano é pedido aqui.
    public func measure(seconds: Int, prepareLatency: @escaping @MainActor () async -> Void) async -> ViewerMeasurement {
        var result = ViewerMeasurement()
        fpsHistory = []
        for _ in 0..<80 where model.connection != .live { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(2))
        fpsHistory = []
        try? await Task.sleep(for: .seconds(seconds))
        result.fpsSamples = fpsHistory
        result.fpsAverage = fpsHistory.isEmpty ? 0 : fpsHistory.reduce(0, +) / Double(fpsHistory.count)
        result.fpsMin = fpsHistory.min() ?? 0
        await prepareLatency()
        try? await Task.sleep(for: .seconds(1))
        await takeOver()
        try? await Task.sleep(for: .milliseconds(500))
        var samples = await web.probeLatency(count: 40, gapMs: 150)
        samples.sort()
        result.latencySamplesMs = samples
        if !samples.isEmpty {
            result.latencyP50Ms = samples[samples.count / 2]
            result.latencyP95Ms = samples[max(0, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)]
        }
        result.wsMessages = web.streamInfo.messages
        result.wsBytes = web.streamInfo.bytes
        result.pageHidden = web.streamInfo.hidden
        result.appActive = NSApp.isActive
        result.windowVisible = web.window?.occlusionState.contains(.visible) ?? false
        measurement = result
        return result
    }
}
