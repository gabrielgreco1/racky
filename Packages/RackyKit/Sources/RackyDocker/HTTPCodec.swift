import Foundation

/// Requisição HTTP/1.1 mínima para a Engine API.
struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data?

    /// Bytes da linha de requisição e cabeçalhos (o corpo vai separado, para streams grandes como o tar do build).
    func head(bodyLength: Int?, upgrade: Bool) -> Data {
        var target = path
        if !query.isEmpty {
            let encoded = query.map { item -> String in
                let key = Self.escape(item.name)
                guard let value = item.value else { return key }
                return "\(key)=\(Self.escape(value))"
            }.joined(separator: "&")
            target += "?" + encoded
        }
        var lines = ["\(method) \(target) HTTP/1.1", "Host: docker"]
        var merged = headers
        if upgrade {
            merged["Connection"] = "Upgrade"
            merged["Upgrade"] = "tcp"
        } else {
            merged["Connection"] = "close"
        }
        if let bodyLength { merged["Content-Length"] = String(bodyLength) }
        for (key, value) in merged.sorted(by: { $0.key < $1.key }) { lines.append("\(key): \(value)") }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct HTTPResponseHead: Sendable, Equatable {
    var status: Int
    var reason: String
    var headers: [String: String]  // chaves em minúsculas

    var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
    var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }
    var contentType: String? { headers["content-type"] }
}

/// Acumula bytes e extrai a cabeça da resposta (até `\r\n\r\n`); o excedente é o começo do corpo.
struct HTTPHeadParser {
    private var buffer = Data()
    static let maxHeadBytes = 64 << 10

    /// Devolve a cabeça e os bytes restantes quando completa; `nil` se faltam bytes.
    mutating func feed(_ data: Data) throws -> (head: HTTPResponseHead, rest: Data)? {
        buffer.append(data)
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: terminator) else {
            if buffer.count > Self.maxHeadBytes { throw DockerError.malformedResponse("cabeçalho HTTP acima de 64 KiB") }
            return nil
        }
        let headData = Data(buffer[buffer.startIndex ..< range.lowerBound])
        let rest = Data(buffer[range.upperBound...])
        buffer = Data()
        return (try Self.parse(headData), rest)
    }

    static func parse(_ data: Data) throws -> HTTPResponseHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw DockerError.malformedResponse("linha de status inválida: \(statusLine.prefix(80))")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPResponseHead(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers)
    }
}

/// Decodificador incremental de `Transfer-Encoding: chunked`.
struct ChunkedDecoder {
    private enum State { case size, data(Int), dataEnd, trailer, done }
    private var state = State.size
    private var buffer = Data()

    var isFinished: Bool { if case .done = state { true } else { false } }

    /// Consome bytes de entrada e devolve os bytes de corpo decodificados.
    mutating func feed(_ data: Data) throws -> Data {
        buffer.append(data)
        var output = Data()
        loop: while true {
            switch state {
            case .size:
                guard let crlf = buffer.range(of: Data("\r\n".utf8)) else { break loop }
                let line = String(decoding: buffer[buffer.startIndex ..< crlf.lowerBound], as: UTF8.self)
                let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw DockerError.malformedResponse("tamanho de chunk inválido: \(line.prefix(40))")
                }
                buffer.removeSubrange(buffer.startIndex ..< crlf.upperBound)
                state = size == 0 ? .trailer : .data(size)
            case .data(let remaining):
                guard !buffer.isEmpty else { break loop }
                let take = min(remaining, buffer.count)
                output.append(buffer.prefix(take))
                buffer.removeFirst(take)
                state = take == remaining ? .dataEnd : .data(remaining - take)
            case .dataEnd:
                guard buffer.count >= 2 else { break loop }
                buffer.removeFirst(2)
                state = .size
            case .trailer:
                // Trailers são ignorados até a linha vazia.
                guard let crlf = buffer.range(of: Data("\r\n".utf8)) else { break loop }
                let empty = crlf.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex ..< crlf.upperBound)
                if empty {
                    state = .done
                    break loop
                }
            case .done:
                break loop
            }
        }
        return output
    }
}

/// Separa um stream de bytes em linhas JSON (eventos, progresso de pull/build).
struct LineSplitter {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex ..< newline])
            buffer.removeSubrange(buffer.startIndex ... newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    mutating func flush() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}

/// Fluxo de um exec/attach/logs sem TTY: stdout e stderr multiplexados com cabeçalho de 8 bytes.
public enum DockerStreamKind: UInt8, Sendable, Equatable {
    case stdin = 0
    case stdout = 1
    case stderr = 2
}

public struct DockerStreamFrame: Sendable, Equatable {
    public var kind: DockerStreamKind
    public var data: Data
    public init(kind: DockerStreamKind, data: Data) {
        self.kind = kind
        self.data = data
    }
}

/// Demultiplexador do formato `[kind, 0, 0, 0, size(4, big endian)] + payload`.
struct MultiplexDemuxer {
    private var buffer = Data()
    static let maxFrame = 64 << 20

    mutating func feed(_ data: Data) throws -> [DockerStreamFrame] {
        buffer.append(data)
        var frames: [DockerStreamFrame] = []
        while buffer.count >= 8 {
            let base = buffer.startIndex
            let kindByte = buffer[base]
            let size = Int(buffer[base + 4]) << 24 | Int(buffer[base + 5]) << 16 | Int(buffer[base + 6]) << 8 | Int(buffer[base + 7])
            guard let kind = DockerStreamKind(rawValue: kindByte), buffer[base + 1] == 0, buffer[base + 2] == 0, buffer[base + 3] == 0 else {
                throw DockerError.malformedResponse("cabeçalho de stream multiplexado inválido")
            }
            guard size <= Self.maxFrame else { throw DockerError.malformedResponse("frame multiplexado acima do limite") }
            guard buffer.count >= 8 + size else { break }
            frames.append(DockerStreamFrame(kind: kind, data: Data(buffer[(base + 8) ..< (base + 8 + size)])))
            buffer.removeFirst(8 + size)
        }
        return frames
    }

    var hasPartialFrame: Bool { !buffer.isEmpty }
}
