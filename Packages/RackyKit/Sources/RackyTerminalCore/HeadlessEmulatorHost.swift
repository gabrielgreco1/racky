import Foundation
import Synchronization
import SwiftTerm

/// Marca dentro de um chunk: ao chegar em `offset`, o host guarda a posição do cursor sob `key` (o `seq` do corte).
public struct EmulatorMark: Sendable {
    public var offset: Int
    public var key: UInt64
    public init(offset: Int, key: UInt64) {
        self.offset = offset
        self.key = key
    }
}

/// Emulador headless de uma sessão (`Terminal` do SwiftTerm) numa fila serial própria: o parse nunca roda na fila
/// de I/O do PTY nem no pool cooperativo. Serve a `textSnapshot`, às respostas de consulta (AR-105) e ao cursor
/// dos pontos de corte. Fica atrás do stream (o ring e o broadcast não esperam por ele).
// SAFETY: `terminal` e `delegate` só são tocados dentro de `queue`; o resto do estado compartilhado está em `Mutex`.
public final class HeadlessEmulatorHost: @unchecked Sendable {
    /// Backlog (bytes não processados) acima do qual o chamador deve pausar a leitura do PTY.
    public static let highWater = 8 << 20
    public static let lowWater = 2 << 20

    private final class Delegate: TerminalDelegate {
        var onReply: (([UInt8]) -> Void)?
        func send(source: Terminal, data: ArraySlice<UInt8>) { onReply?(Array(data)) }
    }

    private struct Shared {
        var pending = 0
        var cursors: [UInt64: (x: Int, y: Int)] = [:]
    }

    private let queue = DispatchQueue(label: "app.racky.ptyd.emulator")
    private let delegate = Delegate()
    private let terminal: Terminal
    // LOCK: protege contadores e o mapa de cursores; sem I/O sob o lock.
    private let shared = Mutex(Shared())
    private let onDrained: @Sendable () -> Void

    /// - Parameters:
    ///   - allowReplies: `true` quando este emulador é o único respondente (nenhum cliente anexado, AR-105).
    ///   - reply: bytes de resposta (já filtrados) a escrever no PTY com origem `terminalReply`.
    ///   - onDrained: chamado (em qualquer thread) quando o backlog cai abaixo de `lowWater`.
    public init(
        cols: Int, rows: Int, scrollback: Int = 5000, allowReplies: @escaping @Sendable () -> Bool,
        reply: @escaping @Sendable ([UInt8]) -> Void, onDrained: @escaping @Sendable () -> Void
    ) {
        self.onDrained = onDrained
        terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        delegate.onReply = { bytes in
            guard QueryReplyFilter.allows(bytes), allowReplies() else { return }
            reply(bytes)
        }
    }

    public var pendingBytes: Int { shared.withLock { $0.pending } }

    public func feed(_ bytes: [UInt8], marks: [EmulatorMark]) {
        shared.withLock { $0.pending += bytes.count }
        queue.async { [self] in
            var fed = 0
            for mark in marks.sorted(by: { $0.offset < $1.offset }) {
                let upTo = min(max(mark.offset, fed), bytes.count)
                if upTo > fed {
                    terminal.feed(buffer: bytes[fed ..< upTo])
                    fed = upTo
                }
                let cursor = terminal.getCursorLocation()
                shared.withLock { $0.cursors[mark.key] = cursor }
            }
            if fed < bytes.count { terminal.feed(buffer: bytes[fed...]) }
            let remaining = shared.withLock { state -> Int in
                state.pending -= bytes.count
                return state.pending
            }
            if remaining < Self.lowWater { onDrained() }
        }
    }

    public func resize(cols: Int, rows: Int) {
        queue.async { [self] in terminal.resize(cols: cols, rows: rows) }
    }

    public func cursor(forKey key: UInt64) -> (x: Int, y: Int)? {
        shared.withLock { $0.cursors[key] }
    }

    public func pruneCursors(below seq: UInt64) {
        shared.withLock { state in state.cursors = state.cursors.filter { $0.key >= seq } }
    }

    /// Retorna quando tudo que foi enviado antes a `feed`/`resize` foi processado.
    public func barrier() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Texto das últimas `lines` linhas (scrollback + tela), sem espaços à direita e sem linhas vazias no fim.
    public func textSnapshot(lines: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async { [self] in
                let data = terminal.getBufferAsData(kind: .active)
                var rows = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                while let last = rows.last, last.isEmpty { rows.removeLast() }
                continuation.resume(returning: rows.suffix(lines).joined(separator: "\n"))
            }
        }
    }

    /// Estado atual de modos públicos do emulador (para testes e diagnóstico).
    public func publicModes() async -> (alt: Bool, bracketedPaste: Bool, appCursor: Bool) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: (terminal.isCurrentBufferAlternate, terminal.bracketedPasteMode, terminal.applicationCursor))
            }
        }
    }
}
