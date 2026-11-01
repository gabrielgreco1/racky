import Foundation

/// Estado de modos que um corte de replay pode perder. A API pública do `Terminal` do SwiftTerm não expõe
/// `cursorHidden`, keypad de aplicação, título nem a codificação de mouse (S-04), então o daemon mantém o próprio.
public struct ModeState: Sendable, Equatable {
    public var dec: [Int: Bool] = [:]
    public var keypadApp: Bool?
    public var title: [UInt8]?

    public init() {}

    public var isAlt: Bool { (dec[1049] ?? false) || (dec[47] ?? false) || (dec[1047] ?? false) }
    public var bracketedPaste: Bool { dec[2004] ?? false }
    public var appCursor: Bool { dec[1] ?? false }
    public var mouse: Bool { (dec[1000] ?? false) || (dec[1002] ?? false) || (dec[1003] ?? false) }

    /// Escapes VT que restabelecem este estado (06 §1.5). `cursor` é (x, y) com origem 0.
    public func preamble(cursor: (x: Int, y: Int)?) -> [UInt8] {
        var text = ""
        if isAlt { text += "\u{1b}[?1049h" }
        for key in dec.keys.sorted() where key != 1049 && key != 47 && key != 1047 {
            text += "\u{1b}[?\(key)\(dec[key]! ? "h" : "l")"
        }
        if let keypadApp { text += keypadApp ? "\u{1b}=" : "\u{1b}>" }
        var out = [UInt8](text.utf8)
        if let title { out += [0x1b, 0x5d, 0x30, 0x3b] + title + [0x07] }
        if let cursor { out += [UInt8]("\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H".utf8) }
        return out
    }
}

/// Sequência que serve de ponto de corte: o replay pode começar em `seq` (o `ESC` da sequência).
public struct CutEvent: Sendable, Equatable {
    public var seq: UInt64
    /// Estado anterior à sequência.
    public var before: ModeState
}

/// Eventos extraídos do stream de bytes (sem emulador): alimentam `title`, `cwd`, `prompt`, `bell`, `altScreen`, `modes`.
public enum TrackerEvent: Sendable, Equatable {
    case title(String)
    case cwd(String)
    case prompt(phase: Character, exitStatus: Int32?)
    case bell
    case altScreen(Bool)
    case modes(bracketedPaste: Bool, appCursor: Bool, mouse: Bool)
}

/// Rastreador byte a byte. Aceita sequências partidas entre chunks (o estado do parser persiste).
public struct VTTracker: Sendable {
    enum Phase { case normal, esc, csi, osc, oscEsc }

    public private(set) var state = ModeState()
    private var phase = Phase.normal
    private var buffer: [UInt8] = []
    private var escSeq: UInt64 = 0
    private var atEsc = ModeState()
    private var cuts: [CutEvent] = []
    private var events: [TrackerEvent] = []

    static let maxCSI = 64
    static let maxOSC = 4096

    public init() {}

    /// `true` quando o parser está fora de qualquer sequência (seguro para gravar checkpoint).
    public var isNormal: Bool { phase == .normal }

    public mutating func feed(_ bytes: [UInt8], startSeq: UInt64) {
        var seq = startSeq
        for byte in bytes {
            feed(byte, seq: seq)
            seq += 1
        }
    }

    public mutating func takeCuts() -> [CutEvent] {
        defer { cuts.removeAll(keepingCapacity: true) }
        return cuts
    }

    public mutating func takeEvents() -> [TrackerEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    private mutating func beginEsc(_ seq: UInt64) {
        phase = .esc
        escSeq = seq
        atEsc = state
    }

    mutating func feed(_ b: UInt8, seq: UInt64) {
        switch phase {
        case .normal:
            if b == 0x1b { beginEsc(seq) } else if b == 0x07 { events.append(.bell) }
        case .esc:
            switch b {
            case 0x5b:
                phase = .csi
                buffer.removeAll(keepingCapacity: true)
            case 0x5d:
                phase = .osc
                buffer.removeAll(keepingCapacity: true)
            case 0x63:  // ESC c
                phase = .normal
                let wasAlt = state.isAlt
                state = ModeState()
                cuts.append(CutEvent(seq: escSeq, before: atEsc))
                if wasAlt { events.append(.altScreen(false)) }
                emitModes(previous: atEsc)
            case 0x3d:
                phase = .normal
                state.keypadApp = true
            case 0x3e:
                phase = .normal
                state.keypadApp = false
            case 0x1b: beginEsc(seq)
            default: phase = .normal
            }
        case .csi:
            if b >= 0x40 && b <= 0x7e {
                phase = .normal
                finishCSI(final: b)
            } else if b == 0x1b {
                beginEsc(seq)
            } else {
                buffer.append(b)
                if buffer.count > Self.maxCSI { phase = .normal }
            }
        case .osc:
            if b == 0x07 {
                finishOSC()
                phase = .normal
            } else if b == 0x1b {
                phase = .oscEsc
            } else {
                buffer.append(b)
                if buffer.count > Self.maxOSC { phase = .normal }
            }
        case .oscEsc:
            if b == 0x5c {
                finishOSC()
                phase = .normal
            } else if b == 0x1b {
                beginEsc(seq)
            } else {
                phase = .normal
            }
        }
    }

    private mutating func finishCSI(final: UInt8) {
        let text = String(decoding: buffer, as: UTF8.self)
        if text.hasPrefix("?"), final == 0x68 || final == 0x6c {  // h / l
            let before = state
            var cut = false
            for parameter in text.dropFirst().split(separator: ";").compactMap({ Int($0) }) {
                state.dec[parameter] = (final == 0x68)
                if final == 0x68, parameter == 1049 || parameter == 47 || parameter == 1047 { cut = true }
            }
            if cut { cuts.append(CutEvent(seq: escSeq, before: atEsc)) }
            if before.isAlt != state.isAlt { events.append(.altScreen(state.isAlt)) }
            emitModes(previous: before)
        } else if final == 0x4a, text == "2" || text == "3" {  // CSI 2J / 3J
            cuts.append(CutEvent(seq: escSeq, before: atEsc))
        }
    }

    private mutating func emitModes(previous: ModeState) {
        if previous.bracketedPaste != state.bracketedPaste || previous.appCursor != state.appCursor || previous.mouse != state.mouse {
            events.append(.modes(bracketedPaste: state.bracketedPaste, appCursor: state.appCursor, mouse: state.mouse))
        }
    }

    private mutating func finishOSC() {
        guard let separator = buffer.firstIndex(of: 0x3b) else { return }
        let command = String(decoding: buffer[..<separator], as: UTF8.self)
        let payload = Array(buffer[(separator + 1)...])
        switch command {
        case "0", "2":
            state.title = payload
            events.append(.title(String(decoding: payload, as: UTF8.self)))
        case "7":
            if let path = Self.path(fromFileURL: String(decoding: payload, as: UTF8.self)) { events.append(.cwd(path)) }
        case "133":
            let parts = String(decoding: payload, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            guard let first = parts.first, first.count == 1, let phase = first.first, "ABCD".contains(phase) else { return }
            let status = parts.count > 1 ? Int32(parts[1]) : nil
            events.append(.prompt(phase: phase, exitStatus: phase == "D" ? status : nil))
        default: break
        }
    }

    /// `file://host/path` (com escapes %XX) → `/path`.
    static func path(fromFileURL text: String) -> String? {
        guard text.hasPrefix("file://") else { return nil }
        let rest = text.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let raw = String(rest[slash...])
        return raw.removingPercentEncoding ?? raw
    }
}
