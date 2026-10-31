import RackyProtocol
import Darwin
import Foundation

/// Por que um terminal ficou `interrupted` (03 §4.6): decide qual das três frases o banner mostra.
public enum InterruptionReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// O Mac reiniciou (o início do processo é anterior ao boot atual).
    case macRestarted
    /// O processo morreu enquanto o app estava fechado (saída limpa do app antes da morte).
    case appClosed
    /// Qualquer outra perda: crash do daemon, `kill`, app em execução quando o PTY sumiu.
    case unexpected

    /// Texto do banner (inglês, P2).
    public var bannerText: String {
        switch self {
        case .macRestarted: "This terminal stopped when your Mac restarted."
        case .appClosed: "This terminal stopped while Racky was closed."
        case .unexpected: "This terminal stopped unexpectedly."
        }
    }
}

/// Estado de reabertura em `ui_state` (chave `restore`): o motivo de cada terminal interrompido e se o app fechou de
/// forma limpa na última execução. Nada aqui é do domínio; é só o que a UI precisa para explicar o que aconteceu.
public struct RestoreUIState: Codable, Equatable, Sendable {
    public static let key = "restore"
    /// `true` enquanto uma execução do app está viva; `false` depois de uma saída limpa (⌘Q ou fechar a janela).
    public var appRunning: Bool = false
    public var interruptions: [String: InterruptionReason] = [:]
    /// P25: terminais que o usuário parou de propósito ("Stop All and Quit"); a retomada automática nunca os revive.
    public var explicitlyStopped: [String] = []
    public init(appRunning: Bool = false, interruptions: [String: InterruptionReason] = [:], explicitlyStopped: [String] = []) {
        self.appRunning = appRunning
        self.interruptions = interruptions
        self.explicitlyStopped = explicitlyStopped
    }

    private enum CodingKeys: String, CodingKey { case appRunning, interruptions, explicitlyStopped }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appRunning = try c.decodeIfPresent(Bool.self, forKey: .appRunning) ?? false
        interruptions = try c.decodeIfPresent([String: InterruptionReason].self, forKey: .interruptions) ?? [:]
        explicitlyStopped = try c.decodeIfPresent([String].self, forKey: .explicitlyStopped) ?? []
    }
}

public enum InterruptionClassifier {
    /// Hora do boot atual (`kern.boottime`).
    public static func bootTime() -> Date {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }

    /// - Parameters:
    ///   - startedAt: início do processo (quando o app o registrou).
    ///   - previousRunWasClean: a execução anterior do app terminou limpa? `nil` = desconhecido.
    public static func reason(startedAt: Date?, bootTime: Date, previousRunWasClean: Bool?) -> InterruptionReason {
        if let startedAt, startedAt < bootTime { return .macRestarted }
        if previousRunWasClean == true { return .appClosed }
        return .unexpected
    }
}

/// Último trecho do cold log de uma sessão do daemon (`<home>/sessions/<ptySessionID>/output.log[.1]`, 06 §1.5).
public struct ColdLogTail: Sendable, Equatable {
    public var bytes: [UInt8]
    /// `true` se o início foi cortado (o log tem mais do que o trecho).
    public var truncated: Bool
}

public struct ColdLogReader: Sendable {
    public static let defaultTailBytes = 256 << 10
    public let sessionsDirectory: URL

    public init(sessionsDirectory: URL) { self.sessionsDirectory = sessionsDirectory }

    /// Lê os últimos `maxBytes` do log (juntando o segmento rotacionado se preciso). Começa na primeira quebra de linha
    /// depois do corte, para não iniciar no meio de uma sequência de escape. `nil` = sem log.
    public func tail(sessionID: String, maxBytes: Int = defaultTailBytes) -> ColdLogTail? {
        guard !sessionID.contains("/"), !sessionID.isEmpty else { return nil }
        let directory = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        var data = Data()
        var truncated = false
        if let current = Self.read(directory.appendingPathComponent("output.log"), last: maxBytes) {
            data = current.data
            truncated = !current.complete
        }
        if !truncated, data.count < maxBytes, let older = Self.read(directory.appendingPathComponent("output.log.1"), last: maxBytes - data.count) {
            data = older.data + data
            truncated = !older.complete
        }
        guard !data.isEmpty else { return nil }
        var bytes = [UInt8](data)
        if truncated, let newline = bytes.firstIndex(of: 0x0A) { bytes.removeSubrange(0 ... newline) }
        return ColdLogTail(bytes: bytes, truncated: truncated)
    }

    private static func read(_ url: URL, last count: Int) -> (data: Data, complete: Bool)? {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(count) ? size - UInt64(count) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return (data, start == 0)
    }
}

/// Monta o que o Resume e o Start Fresh relançam (06 §2.6). Nada é guardado: o argv sai do `LaunchSpec` e é regerado.
public enum RestorePlanner {
    /// Spec do Resume: ID nativo capturado no lugar do prompt; sem ID o `LaunchMode` vira `continueLast` ("Continue Last").
    public static func resume(_ terminal: Terminal) -> (spec: LaunchSpec, mode: LaunchMode) {
        var spec = terminal.launchSpec
        spec.initialPrompt = nil
        spec.initialPromptFile = nil
        if let native = nativeID(of: terminal) {
            spec.resumeOf = native
            spec.nativeSessionID = nil
            return (spec, .resume(nativeID: native))
        }
        return (spec, .continueLast)
    }

    /// Spec do Start Fresh: mesma configuração, conversa nova (sem ID e sem prompt).
    public static func startFresh(_ terminal: Terminal) -> LaunchSpec {
        var spec = terminal.launchSpec
        spec.initialPrompt = nil
        spec.initialPromptFile = nil
        spec.nativeSessionID = nil
        spec.resumeOf = nil
        return spec
    }

    public static func nativeID(of terminal: Terminal) -> String? {
        let candidates = [terminal.nativeConversationID, terminal.launchSpec.resumeOf, terminal.launchSpec.nativeSessionID]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    public static func hasExactResume(_ terminal: Terminal) -> Bool { terminal.provider.isAgent && nativeID(of: terminal) != nil }
}
