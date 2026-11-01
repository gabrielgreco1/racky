import Foundation

/// Mensagem de controle (frame `0x01`): requisição, resposta ou evento. Roteada por `op`.
public enum ControlMessage: Sendable, Hashable {
    case request(DaemonRequest)
    case reply(DaemonReply)
    case event(DaemonEvent)
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey { case op }

    public init(from decoder: any Decoder) throws {
        let op = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .op)
        if op == "event" {
            self = .event(try DaemonEvent(from: decoder))
        } else if DaemonReply.allOps.contains(op) {
            self = .reply(try DaemonReply(from: decoder))
        } else {
            self = .request(try DaemonRequest(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .request(let v): try v.encode(to: encoder)
        case .reply(let v): try v.encode(to: encoder)
        case .event(let v): try v.encode(to: encoder)
        }
    }
}

/// Frame `0x02` (daemon → cliente): `sessionID (16 B) | seq (u64 BE) | bytes`.
public struct OutputFrame: Sendable, Hashable {
    public static let headerSize = SessionID.byteCount + 8
    public var sessionID: SessionID
    /// Offset em bytes, desde o início da sessão, do primeiro byte deste frame.
    public var seq: UInt64
    public var bytes: Data

    public init(sessionID: SessionID, seq: UInt64, bytes: Data) {
        self.sessionID = sessionID
        self.seq = seq
        self.bytes = bytes
    }

    /// `seq` esperado do próximo frame (contínuo).
    public var nextSeq: UInt64 { seq + UInt64(bytes.count) }
}

/// Frame `0x03` (cliente → daemon): `sessionID (16 B) | origin (u8) | bytes`. Sem resposta.
public struct InputFrame: Sendable, Hashable {
    public static let headerSize = SessionID.byteCount + 1
    public var sessionID: SessionID
    public var origin: InputOrigin
    public var bytes: Data

    public init(sessionID: SessionID, origin: InputOrigin, bytes: Data) {
        self.sessionID = sessionID
        self.origin = origin
        self.bytes = bytes
    }
}

public enum FrameKind: UInt8, Sendable, Hashable, CaseIterable {
    case control = 0x01
    case output = 0x02
    case input = 0x03
}

public enum Frame: Sendable, Hashable {
    case control(ControlMessage)
    case output(OutputFrame)
    case input(InputFrame)

    public var kind: FrameKind {
        switch self {
        case .control: .control
        case .output: .output
        case .input: .input
        }
    }
}

/// Codec do protocolo de controle: JSON UTF-8 determinístico (chaves ordenadas, sem escape de `/`),
/// datas ISO 8601 UTC com milissegundos.
public enum ControlCodec {
    public static func encode(_ message: ControlMessage) throws -> Data {
        do {
            return try makeEncoder().encode(message)
        } catch {
            throw FrameError.malformedControl("encode failed: \(error)")
        }
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        do {
            return try makeDecoder().decode(ControlMessage.self, from: data)
        } catch {
            throw FrameError.malformedControl(describe(error))
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO 8601 date '\(text)'")
        }
        return decoder
    }

    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .dataCorrupted(let context): return "corrupted: \(context.debugDescription)"
        case .keyNotFound(let key, _): return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context): return "type mismatch: \(context.debugDescription)"
        case .valueNotFound(_, let context): return "missing value: \(context.debugDescription)"
        @unknown default: return "\(decoding)"
        }
    }
}

/// Framing: `u32 len (BE) | u8 kind | payload`, com `len` = bytes de `kind` + payload, no máximo 1 MiB.
public enum FrameCodec {
    public static let maxFrameLength = ProtocolLimits.maxFrameLength
    /// Maior quantidade de bytes de terminal que cabe em um frame `output`.
    public static let maxOutputBytes = maxFrameLength - 1 - OutputFrame.headerSize
    /// Maior quantidade de bytes que cabe em um frame `input`.
    public static let maxInputBytes = maxFrameLength - 1 - InputFrame.headerSize

    public static func encode(_ frame: Frame) throws -> Data {
        var body = Data()
        switch frame {
        case .control(let message):
            body = try ControlCodec.encode(message)
        case .output(let output):
            body.reserveCapacity(OutputFrame.headerSize + output.bytes.count)
            body.append(contentsOf: output.sessionID.bytes)
            appendBigEndian(output.seq, to: &body)
            body.append(output.bytes)
        case .input(let input):
            body.reserveCapacity(InputFrame.headerSize + input.bytes.count)
            body.append(contentsOf: input.sessionID.bytes)
            body.append(input.origin.rawValue)
            body.append(input.bytes)
        }
        let length = 1 + body.count
        guard length <= maxFrameLength else { throw FrameError.frameTooLarge(length: length) }
        var data = Data()
        data.reserveCapacity(ProtocolLimits.lengthPrefixSize + length)
        appendBigEndian(UInt32(length), to: &data)
        data.append(frame.kind.rawValue)
        data.append(body)
        return data
    }

    /// Decodifica exatamente um frame completo (sem bytes sobrando).
    public static func decode(_ data: Data) throws -> Frame {
        var decoder = FrameDecoder()
        let frames = try decoder.append(data)
        try decoder.finish()
        guard frames.count == 1, let frame = frames.first else {
            throw FrameError.malformedControl("expected exactly one frame, got \(frames.count)")
        }
        return frame
    }

    /// Tamanho em bytes do frame no fio (inclui o prefixo de 4 bytes). Lança `frameTooLarge` se `len` passar de 1 MiB.
    public static func wireSize(of frame: Frame) throws -> Int {
        let length: Int
        switch frame {
        case .output(let f): length = 1 + OutputFrame.headerSize + f.bytes.count
        case .input(let f): length = 1 + InputFrame.headerSize + f.bytes.count
        case .control: return try encode(frame).count
        }
        guard length <= maxFrameLength else { throw FrameError.frameTooLarge(length: length) }
        return ProtocolLimits.lengthPrefixSize + length
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Decodificador incremental de stream. Uma falha é permanente: a conexão deve ser fechada.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0
    private var failure: FrameError?

    public init() {}

    /// Bytes recebidos e ainda não consumidos por um frame completo.
    public var bufferedByteCount: Int { buffer.count - head }

    /// Acrescenta bytes e devolve os frames completos. `len` acima do limite falha assim que o prefixo chega.
    /// Se um frame inválido aparece, lança o erro (os frames válidos do mesmo chunk ficam perdidos para o
    /// chamador; use `drain(_:)` quando eles importam).
    public mutating func append(_ data: Data) throws -> [Frame] {
        let result = drain(data)
        if let error = result.error { throw error }
        return result.frames
    }

    /// Como `append`, mas devolve os frames válidos que vieram **antes** do primeiro frame inválido junto com o erro.
    public mutating func drain(_ data: Data) -> (frames: [Frame], error: FrameError?) {
        if let failure { return ([], failure) }
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        do {
            while let frame = try next() { frames.append(frame) }
        } catch let error as FrameError {
            failure = error
            return (frames, error)
        } catch {
            let wrapped = FrameError.malformedControl("\(error)")
            failure = wrapped
            return (frames, wrapped)
        }
        compact()
        return (frames, nil)
    }

    /// Fim do stream: sobra de bytes significa frame truncado.
    public func finish() throws {
        if let failure { throw failure }
        let available = bufferedByteCount
        guard available > 0 else { return }
        if available < ProtocolLimits.lengthPrefixSize {
            throw FrameError.truncatedFrame(expected: ProtocolLimits.lengthPrefixSize, available: available)
        }
        let length = Int(readUInt32(at: head))
        throw FrameError.truncatedFrame(expected: ProtocolLimits.lengthPrefixSize + length, available: available)
    }

    private mutating func next() throws -> Frame? {
        guard bufferedByteCount >= ProtocolLimits.lengthPrefixSize else { return nil }
        let length = Int(readUInt32(at: head))
        guard length <= ProtocolLimits.maxFrameLength else { throw FrameError.frameTooLarge(length: length) }
        guard length >= 1 else { throw FrameError.emptyFrame }
        guard bufferedByteCount >= ProtocolLimits.lengthPrefixSize + length else { return nil }
        let start = head + ProtocolLimits.lengthPrefixSize
        let kindByte = buffer[start]
        let payload = buffer[(start + 1) ..< (start + length)]
        let frame = try Self.parse(kindByte: kindByte, payload: payload)
        head += ProtocolLimits.lengthPrefixSize + length
        return frame
    }

    private static func parse(kindByte: UInt8, payload: ArraySlice<UInt8>) throws -> Frame {
        guard let kind = FrameKind(rawValue: kindByte) else { throw FrameError.unknownKind(kindByte) }
        switch kind {
        case .control:
            return .control(try ControlCodec.decode(Data(payload)))
        case .output:
            guard payload.count >= OutputFrame.headerSize else {
                throw FrameError.payloadTooShort(kind: kindByte, minimum: OutputFrame.headerSize, actual: payload.count)
            }
            let base = payload.startIndex
            guard let id = SessionID(bytes: payload[base ..< base + SessionID.byteCount]) else {
                throw FrameError.malformedControl("invalid session id")
            }
            var seq: UInt64 = 0
            for byte in payload[(base + SessionID.byteCount) ..< (base + OutputFrame.headerSize)] { seq = seq << 8 | UInt64(byte) }
            return .output(OutputFrame(sessionID: id, seq: seq, bytes: Data(payload[(base + OutputFrame.headerSize)...])))
        case .input:
            guard payload.count >= InputFrame.headerSize else {
                throw FrameError.payloadTooShort(kind: kindByte, minimum: InputFrame.headerSize, actual: payload.count)
            }
            let base = payload.startIndex
            guard let id = SessionID(bytes: payload[base ..< base + SessionID.byteCount]) else {
                throw FrameError.malformedControl("invalid session id")
            }
            let originByte = payload[base + SessionID.byteCount]
            guard let origin = InputOrigin(rawValue: originByte) else { throw FrameError.invalidInputOrigin(originByte) }
            return .input(InputFrame(sessionID: id, origin: origin, bytes: Data(payload[(base + InputFrame.headerSize)...])))
        }
    }

    private func readUInt32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16 | UInt32(buffer[index + 2]) << 8 | UInt32(buffer[index + 3])
    }

    private mutating func compact() {
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64 << 10 {
            buffer.removeFirst(head)
            head = 0
        }
    }
}

/// Valida a continuidade de `seq` dos frames `output` de uma sessão (buraco = bug, 06 §1.3).
public struct OutputSequenceValidator: Sendable {
    public enum Verdict: Sendable, Hashable {
        case continuous
        case gap(expected: UInt64, got: UInt64)
        case overlap(expected: UInt64, got: UInt64)
    }

    public private(set) var expectedSeq: UInt64?

    /// `expectedSeq` inicial: `endSeq` do `attachSnapshot` (ou `nil` para aceitar o primeiro frame como início).
    public init(expectedSeq: UInt64? = nil) { self.expectedSeq = expectedSeq }

    public mutating func accept(_ frame: OutputFrame) -> Verdict {
        defer { expectedSeq = frame.nextSeq }
        guard let expected = expectedSeq else { return .continuous }
        if frame.seq == expected { return .continuous }
        return frame.seq > expected ? .gap(expected: expected, got: frame.seq) : .overlap(expected: expected, got: frame.seq)
    }
}
