import CryptoKit
import Foundation

public enum AssetDownloadError: Error, Equatable, LocalizedError, Sendable {
    case http(Int, String)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let url): "the server answered HTTP \(status) for \(url)"
        case .checksumMismatch(let expected, let actual): "the download is corrupt (sha256 \(actual.prefix(12))…, expected \(expected.prefix(12))…)"
        case .sizeMismatch(let expected, let actual): "the download has the wrong size (\(actual) bytes, expected \(expected))"
        case .io(let detail): "the download could not be saved (\(detail))"
        }
    }
}

/// Baixa um arquivo do manifesto com conferência de sha256 e retomada (`Range`). O arquivo parcial (`<destino>.part`) sobrevive a
/// cancelamento e a queda do app; a próxima chamada continua de onde parou. `file://` copia em pedaços (testes e manifesto local).
public struct AssetDownloader: Sendable {
    /// Tamanho do pedaço lido ao hashear e ao copiar de `file://`.
    static let chunk = 4 << 20

    public init() {}

    /// Chamado com `(bytes feitos, total)`; `total == 0` se desconhecido.
    public typealias Progress = @Sendable (Int64, Int64) -> Void

    // MARK: Arquivo verificado

    /// `true` se `destination` existe e bate com o sha256 (e o tamanho, se o manifesto o traz). Guarda o resultado num sidecar
    /// `<arquivo>.verified` (tamanho + mtime + hash) para não re-hashear centenas de MB a cada abertura do app.
    public func isValid(_ destination: URL, spec: VZAssetSpec) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: destination.path), let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
        if let expected = spec.size, expected != size { return false }
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let marker = Self.sidecar(destination)
        let stamp = "\(spec.sha256.lowercased()) \(size) \(Int64(mtime * 1_000_000))"
        if let text = try? String(contentsOf: marker, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines) == stamp { return true }
        guard let actual = try? Self.sha256(of: destination), actual == spec.sha256.lowercased() else { return false }
        try? stamp.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }

    static func sidecar(_ destination: URL) -> URL { destination.appendingPathExtension("verified") }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunk), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Download

    /// Garante `destination` íntegro: se já está válido, só devolve; senão baixa (retomando o `.part`), confere e renomeia.
    public func fetch(_ spec: VZAssetSpec, to destination: URL, progress: @escaping Progress) async throws {
        if isValid(destination, spec: spec) {
            let size = spec.size ?? ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0)
            progress(size, size)
            return
        }
        guard let source = URL(string: spec.url) else { throw AssetDownloadError.io("invalid URL \(spec.url)") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        for attempt in 0..<2 {
            do {
                if source.isFileURL {
                    try await copyLocal(source, to: part, spec: spec, progress: progress)
                } else {
                    try await receive(source, to: part, spec: spec, progress: progress)
                }
                break
            } catch AssetDownloadError.http(416, _) where attempt == 0 {
                // O servidor não aceita o intervalo (o parcial já era maior que o arquivo): recomeça do zero.
                try? fm.removeItem(at: part)
            }
        }
        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = spec.size, expected != size {
            if size > expected { try? fm.removeItem(at: part) }  // maior que o esperado: parcial inútil; menor: dá para retomar
            throw AssetDownloadError.sizeMismatch(expected: expected, actual: size)
        }
        let actual = try Self.sha256(of: part)
        guard actual == spec.sha256.lowercased() else {
            try? fm.removeItem(at: part)
            throw AssetDownloadError.checksumMismatch(expected: spec.sha256.lowercased(), actual: actual)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
        _ = isValid(destination, spec: spec)  // grava o sidecar
        progress(size, size)
    }

    private func copyLocal(_ source: URL, to part: URL, spec: VZAssetSpec, progress: Progress) async throws {
        let fm = FileManager.default
        guard let total = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value else {
            throw AssetDownloadError.io("missing file \(source.path)")
        }
        let offset = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        let start = offset <= total ? offset : 0
        if start == 0 { fm.createFile(atPath: part.path, contents: nil) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: part)
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(start))
        try output.seekToEnd()
        var done = start
        progress(done, total)
        while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            done += Int64(data.count)
            progress(done, total)
            await Task.yield()
        }
    }

    private func receive(_ source: URL, to part: URL, spec: VZAssetSpec, progress: Progress) async throws {
        let fm = FileManager.default
        var offset = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = spec.size, offset > expected { try? fm.removeItem(at: part); offset = 0 }
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let receiver = HTTPChunkReceiver()
        let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        task.resume()

        var output: FileHandle?
        defer { try? output?.close() }
        var done = offset
        var total = spec.size ?? 0
        for try await event in receiver.events {
            try Task.checkCancellation()
            switch event {
            case .head(let status, let length):
                switch status {
                case 200:
                    // Sem suporte a Range (ou arquivo novo): recomeça do zero.
                    offset = 0; done = 0
                    total = length > 0 ? length : total
                    fm.createFile(atPath: part.path, contents: nil)
                case 206:
                    total = length > 0 ? offset + length : total
                default:
                    throw AssetDownloadError.http(status, source.absoluteString)
                }
                output = try FileHandle(forWritingTo: part)
                try output?.seekToEnd()
                progress(done, total)
            case .data(let data):
                try output?.write(contentsOf: data)
                done += Int64(data.count)
                progress(done, total)
            }
        }
        try Task.checkCancellation()
    }
}

/// Ponte do delegate do `URLSession` para um `AsyncThrowingStream`: o cabeçalho primeiro, depois os pedaços do corpo.
final class HTTPChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {  // SAFETY: só guarda a continuation, que é Sendable
    enum Event: Sendable {
        case head(status: Int, contentLength: Int64)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, any Error>
    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

    override init() {
        var captured: AsyncThrowingStream<Event, any Error>.Continuation?
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured!  // a closure do inicializador roda de forma síncrona
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            continuation.yield(.head(status: http.statusCode, contentLength: http.expectedContentLength))
        } else {
            continuation.yield(.head(status: 200, contentLength: response.expectedContentLength))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { continuation.yield(.data(data)) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
