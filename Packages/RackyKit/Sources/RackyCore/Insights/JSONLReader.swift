import Foundation

/// Posição já lida de um arquivo `.jsonl` (leitura incremental).
public struct FileCursor: Codable, Sendable, Equatable {
    /// Offset logo após a última linha COMPLETA consumida.
    public var offset: UInt64
    public var size: UInt64
    public var mtime: Double

    public init(offset: UInt64 = 0, size: UInt64 = 0, mtime: Double = 0) {
        self.offset = offset; self.size = size; self.mtime = mtime
    }
}

/// Leitor incremental de JSONL: só consome linhas completas (terminadas em `\n`), tolera arquivo truncado/rotacionado
/// (volta ao início) e ignora linhas gigantes (blobs de request) sem estourar memória.
public enum JSONLReader {
    /// Teto de uma linha. Linhas maiores são descartadas inteiras.
    public static let maxLineBytes = 64 * 1024 * 1024

    /// Lê as linhas novas a partir de `cursor`. Devolve o novo cursor, ou `nil` se o arquivo não pôde ser lido.
    @discardableResult
    public static func readLines(path: String, cursor: FileCursor?, chunkBytes: Int = 4 * 1024 * 1024,
                                 body: (UnsafeRawBufferPointer) -> Void) -> FileCursor? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var start = cursor?.offset ?? 0
        if size < start { start = 0 }  // truncado ou substituído
        if cursor != nil, size == start {
            return FileCursor(offset: start, size: size, mtime: mtime)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return nil }

        var carry = Data()
        var consumed: UInt64 = 0
        var skipping = false
        var finished = false
        while !finished {
            // Um pool por bloco: o parse de JSON cria objetos Foundation autoreleased; numa `Task` desanexada eles só saem no fim
            // da varredura. Com GBs de transcript isso chegava a mais de 1 GB de RSS na primeira leitura (T2-11).
            autoreleasepool {
                let chunk: Data
                do { chunk = try handle.read(upToCount: chunkBytes) ?? Data() } catch { finished = true; return }
                if chunk.isEmpty { finished = true; return }
                var buffer = carry
                buffer.append(chunk)
                carry = Data()
                var lineStart = 0
                buffer.withUnsafeBytes { raw in
                    let total = raw.count
                    var pos = 0
                    while pos < total {
                        guard let nl = memchr(raw.baseAddress! + pos, 0x0A, total - pos) else { break }
                        let end = raw.baseAddress!.distance(to: UnsafeRawPointer(nl))
                        if skipping {
                            skipping = false
                        } else if end > lineStart {
                            body(UnsafeRawBufferPointer(rebasing: raw[lineStart..<end]))
                        }
                        pos = end + 1
                        lineStart = pos
                    }
                }
                consumed += UInt64(lineStart)
                if lineStart < buffer.count {
                    let tail = buffer.count - lineStart
                    if tail > maxLineBytes {
                        // Linha gigante: descarta o que tem e pula até o próximo `\n`. O offset avança para não relê-la.
                        consumed += UInt64(tail)
                        skipping = true
                    } else {
                        carry = buffer.subdata(in: lineStart..<buffer.count)
                    }
                }
            }
        }
        return FileCursor(offset: start + consumed, size: size, mtime: mtime)
    }

    /// `true` se `needle` aparece em `line` (memmem, sem copiar).
    public static func contains(_ needle: StaticString, in line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// Decodifica a linha como objeto JSON; `nil` se corrompida (nunca lança).
    public static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytes: base, count: line.count)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
