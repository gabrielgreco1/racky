import Foundation
import Observation

/// O que o viewer precisa de um computador (07 §5). `ManagedComputer` implementa; os testes usam um falso.
public protocol ViewerComputer: Sendable {
    var computerName: String { get }
    func requestTakeOver(force: Bool, wait: TimeInterval) async throws -> Bool
    func handBack(note: String?) async throws
    func vncEndpoint() async throws -> URL
    func declineHelp(_ id: String, reason: String?) async
    func viewerSnapshot() async -> ViewerSnapshot
}

/// Foto do computador para o viewer, a miniatura e a página Computers.
public struct ViewerSnapshot: Sendable, Equatable {
    public var name: String
    public var state: BoxState
    public var display: String
    public var control: ControlPhase
    public var proxy: String
    public var url: String?
    public var lastDoing: String?
    public var help: HelpSummary?
    /// Progresso (`Building computer image… 3 of 14`) ou motivo da falha; `nil` fora de provisioning/failed.
    public var detail: String?
    public var queuePosition: Int?

    public init(name: String, state: BoxState, display: String, control: ControlPhase, proxy: String, url: String? = nil, lastDoing: String? = nil, help: HelpSummary? = nil, detail: String? = nil, queuePosition: Int? = nil) {
        self.detail = detail; self.queuePosition = queuePosition
        self.name = name; self.state = state; self.display = display; self.control = control; self.proxy = proxy; self.url = url; self.lastDoing = lastDoing; self.help = help
    }
}

public struct HelpSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: HelpKind
    public var reason: String
    public var host: String?
    public var question: String?
    public var options: [String]
    public var takenOver: Bool

    public init(id: String, kind: HelpKind, reason: String, host: String?, question: String? = nil, options: [String] = [], takenOver: Bool = false) {
        self.id = id; self.kind = kind; self.reason = reason; self.host = host; self.question = question; self.options = options; self.takenOver = takenOver
    }

    /// Texto do banner e do Inbox: `<Kind> on <host>` (CS-433), sem conteúdo de página.
    public var headline: String {
        let label: String
        switch kind {
        case .captcha: label = "CAPTCHA"
        case .login: label = "Sign-in"
        case .mfa: label = "Verification code"
        case .choice: label = "Question"
        case .download: label = "Download"
        case .permission: label = "Permission"
        case .other: label = "Help"
        }
        return host.map { "\(label) on \($0)" } ?? label
    }
}

/// Estados do stream (07 CS-404). Stream caído suspende o input humano e nunca resolve pedido nem devolve controle.
public enum ViewerConnection: Sendable, Equatable {
    case connecting
    case live
    /// Último quadro/dado há mais de 2 s ("Slow connection"); guarda o horário do último dado.
    case delayed(since: Date)
    case reconnecting(attempt: Int)
    case error(String)
    case disconnected
    case stopped
}

public struct ViewerStatsSample: Sendable, Equatable {
    public var fps: Double
    public var frames: Int
    public var silentMs: Int
}

/// Modelo do viewer: controle (agent/revoking/human), stream e pedido de ajuda. Lógica pura e testável; o tempo entra por
/// `tick(now:)`. A UI e o WebView só leem e chamam estes métodos.
@MainActor
@Observable
public final class ComputerViewerModel {
    public static let revokeTimeout: TimeInterval = 10
    public static let delayedAfter: TimeInterval = 2
    public static let maxReconnects = 5
    /// Primeira conexão: o computador pode estar subindo (fila, imagem, Xvfb). Até ~2 min de tentativas a tela diz
    /// "Starting computer…"/"Connecting…", nunca "Reconnecting…" (não houve conexão para reconectar).
    public static let maxFirstConnectAttempts = 60

    public let computer: any ViewerComputer
    public var name: String { computer.computerName }
    public private(set) var connection: ViewerConnection = .connecting
    public private(set) var control: ControlPhase = .agent
    public private(set) var help: HelpSummary?
    public private(set) var snapshot: ViewerSnapshot?
    /// Agente pai (`Claude`, `Codex`, `OpenCode`): "<Agent> is using", "Hand back to <Agent>?".
    public var agentName = "Claude"
    public private(set) var keyboardCaptured = false
    public private(set) var stats = ViewerStatsSample(fps: 0, frames: 0, silentMs: 0)
    /// `"Force Take Over"` aparece depois de 10 s sem ACK (CS-410).
    public private(set) var forceAvailable = false
    public private(set) var revokingSince: Date?
    public var handBackNoteVisible = false
    public var handBackNote = ""
    /// Popover do `"Decline…"` (CS-432): motivo opcional.
    public var declineVisible = false
    public var declineReason = ""
    public private(set) var lastError: String?
    /// Tooltip do clique bloqueado: `Claude is using this computer. Take over to interact.`
    public private(set) var blockedClickAt: Date?
    public private(set) var lastFrameAt: Date?
    private var reconnectAttempts = 0
    /// O stream já ficou vivo alguma vez nesta abertura do viewer. Antes disso, queda e ticket negado são "ainda conectando".
    public private(set) var hasBeenLive = false
    private var firstConnectAttempts = 0

    /// O computador ainda está na fila ou subindo (a tela mostra "Starting computer…" e o progresso).
    public var isStarting: Bool { snapshot?.state == .queued || snapshot?.state == .provisioning }
    private var takeOverInFlight = false

    public init(computer: any ViewerComputer) { self.computer = computer }

    /// Humano no controle e stream vivo: só então mouse e teclado vão ao computador (CS-404, CS-402).
    public var inputEnabled: Bool { control == .human && connection == .live }
    public var needsReconnect: Bool {
        switch connection { case .reconnecting, .disconnected, .error: true; default: false }
    }
    public var canTakeOver: Bool { connection != .stopped && control == .agent }
    public var canHandBack: Bool { control == .human }

    // MARK: Snapshot

    public func apply(snapshot: ViewerSnapshot) {
        self.snapshot = snapshot
        help = snapshot.help
        if snapshot.state == .stopped { connection = .stopped } else if connection == .stopped { connection = .connecting }
        // O runtime é a fonte da verdade do lease: mudanças externas (Inbox, outra janela) aparecem aqui.
        if !takeOverInFlight { control = snapshot.control }
        if snapshot.control == .human { forceAvailable = false }
    }

    public func refresh() async { apply(snapshot: await computer.viewerSnapshot()) }

    // MARK: Stream

    public func streamState(_ value: String, detail: String? = nil, now: Date = Date()) {
        switch value {
        case "connecting":
            if case .reconnecting = connection { return }
            connection = .connecting
        case "live":
            connection = .live
            hasBeenLive = true
            reconnectAttempts = 0
            lastFrameAt = now
        case "disconnected":
            // Reconectar não resolve o pedido nem devolve o controle: só o stream muda.
            guard connection != .stopped else { return }
            if !hasBeenLive { return firstConnectFailed(nil) }
            reconnectAttempts += 1
            connection = reconnectAttempts > Self.maxReconnects ? .disconnected : .reconnecting(attempt: reconnectAttempts)
        default: break
        }
    }

    public func streamError(_ message: String) { connection = .error(message) }

    /// Não saiu o ticket (computador subindo, reiniciando, runtime fora): conta como queda de stream. Reconecta com backoff e,
    /// passado o limite, mostra o erro; nunca fica parado em "Disconnected" sem tentar de novo.
    public func ticketFailed(_ message: String) {
        guard connection != .stopped else { return }
        if !hasBeenLive { return firstConnectFailed(message) }
        reconnectAttempts += 1
        connection = reconnectAttempts > Self.maxReconnects ? .error(message) : .reconnecting(attempt: reconnectAttempts)
    }

    private func firstConnectFailed(_ message: String?) {
        firstConnectAttempts += 1
        lastError = message
        connection = firstConnectAttempts > Self.maxFirstConnectAttempts ? (message.map { .error($0) } ?? .disconnected) : .connecting
    }

    public func streamStats(fps: Double, frames: Int, silentMs: Int, now: Date = Date()) {
        stats = ViewerStatsSample(fps: fps, frames: frames, silentMs: silentMs)
        guard connection == .live || isDelayed else { return }
        if silentMs < Int(Self.delayedAfter * 1000) {
            connection = .live
            lastFrameAt = now.addingTimeInterval(-Double(silentMs) / 1000)
        } else if !isDelayed {
            connection = .delayed(since: now.addingTimeInterval(-Double(silentMs) / 1000))
        }
    }

    private var isDelayed: Bool { if case .delayed = connection { true } else { false } }

    /// Chamado a cada segundo pelo controlador. Hoje só avança o prazo do `Force Take Over`.
    public func tick(now: Date = Date()) {
        if let revokingSince, control == .revoking, now.timeIntervalSince(revokingSince) >= Self.revokeTimeout { forceAvailable = true }
    }

    public func reconnectRequested() {
        reconnectAttempts = 0
        firstConnectAttempts = 0
        if connection != .stopped { connection = .connecting }
    }

    // MARK: Teclado

    public func keyboard(captured: Bool) { keyboardCaptured = captured && inputEnabled }
    public func releaseKeyboard() { keyboardCaptured = false }

    public func blockedClick(now: Date = Date()) { if control != .human { blockedClickAt = now } }

    // MARK: Controle (07 §5.2)

    /// `"Take Over"`: `revoking` na hora; o botão mostra `Requesting control…` até o ACK do runtime.
    @discardableResult
    public func takeOver(force: Bool = false, now: Date = Date()) async -> Bool {
        guard control != .human, connection != .stopped else { return control == .human }
        if control != .revoking { revokingSince = now }
        control = .revoking
        forceAvailable = force ? false : forceAvailable
        lastError = nil
        let id = UUID()
        revokeToken = id
        takeOverInFlight = true  // enquanto pede, o snapshot não sobrescreve o estado local
        do {
            // O humano assume na hora (dono): sempre `force_take`, que cancela a ação em curso do agente sem esperar o ACK.
            let acked = try await computer.requestTakeOver(force: true, wait: 2)
            guard revokeToken == id else { return acked }
            takeOverInFlight = false
            if acked {
                control = .human
                forceAvailable = false
                revokingSince = nil
            } else {
                forceAvailable = true  // 10 s sem ACK
            }
            return acked
        } catch {
            guard revokeToken == id else { return false }
            takeOverInFlight = false
            control = .agent
            revokingSince = nil
            lastError = "\(error)"
            return false
        }
    }

    private var revokeToken: UUID?

    public func showHandBackNote() { if control == .human { handBackNoteVisible = true } }
    public func cancelHandBackNote() { handBackNoteVisible = false }

    /// `"Hand Back"` com a nota opcional (CS-413). O teclado é solto.
    public func handBack() async {
        guard control == .human || control == .revoking else { return }
        let note = handBackNote.trimmingCharacters(in: .whitespacesAndNewlines)
        handBackNoteVisible = false
        keyboardCaptured = false
        revokeToken = nil
        takeOverInFlight = false
        do {
            try await computer.handBack(note: note.isEmpty ? nil : note)
            control = .agent
            handBackNote = ""
            forceAvailable = false
            revokingSince = nil
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        await refresh()
    }

    /// ⇧⌘R: alterna entre Take Over e Hand Back (o Hand Back abre o campo de nota).
    public func toggleControl() async {
        switch control {
        case .agent: await takeOver()
        case .human: showHandBackNote()
        case .revoking: break
        }
    }

    public func decline(reason: String?) async {
        guard let help else { return }
        declineVisible = false
        declineReason = ""
        await computer.declineHelp(help.id, reason: (reason?.isEmpty ?? true) ? nil : reason)
        await refresh()
    }

    public func showDecline() { if help != nil { declineVisible = true } }
    public func cancelDecline() { declineVisible = false }
    public func confirmDecline() async { await decline(reason: declineReason.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
