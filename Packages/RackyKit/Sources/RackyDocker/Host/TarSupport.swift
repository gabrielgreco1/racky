import Foundation

/// Entrada de um tar a enviar (`PUT /containers/{id}/archive`): arquivo regular ou diretório.
struct TarEntry: Sendable, Equatable {
    var path: String
    var data: Data
    var mode: Int
    var uid = 0
    var gid = 0
    var isDirectory = false
}

extension TarArchive {
    /// Tar ustar com dono e modo por entrada (os caminhos já trazem os diretórios pais, na ordem).
    static func create(entries: [TarEntry]) throws -> Data {
        var out = Data()
        for entry in entries {
            let path = entry.isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
            out.append(try header(path: path, size: entry.isDirectory ? 0 : entry.data.count, mode: entry.mode, type: entry.isDirectory ? "5" : "0",
                                  uid: entry.uid, gid: entry.gid))
            guard !entry.isDirectory else { continue }
            out.append(entry.data)
            let padding = (512 - entry.data.count % 512) % 512
            if padding > 0 { out.append(Data(count: padding)) }
        }
        out.append(Data(count: 1024))
        return out
    }
}

public struct TarExtractionReport: Sendable, Equatable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var bytes: Int64 = 0
    /// Entradas ignoradas por segurança ou tipo (caminho com `..`, symlink que escapa, dispositivo...).
    public var skipped: [String] = []
}

public enum TarExtractionError: Error, Sendable, Equatable {
    case malformed(String)
    case tooLarge(limit: Int64)
    case io(String)
}

/// Extrator de tar incremental e defensivo para o que vem da VM remota (conteúdo do agente: NÃO confiável).
/// Nunca escreve fora de `destination`: ignora `..`, caminhos absolutos viram relativos, symlink só se apontar para dentro,
/// dispositivos/FIFOs/hardlinks são ignorados, setuid/setgid/sticky são removidos. Sobrescreve arquivos existentes (pull repetido).
/// Entende ustar, pax (`x`/`g`) e nomes longos GNU (`L`).
public struct TarExtractor {
    public let destination: URL
    public let maxBytes: Int64
    private let root: String
    private var buffer = Data()
    private var report = TarExtractionReport()
    private var state = State.header
    private var longName: String?
    private var paxPath: String?
    private var zeroBlocks = 0
    private var done = false

    private enum Kind { case file, meta(Meta), skip }
    private enum Meta { case pax, paxGlobal, gnuLongName }
    private struct Current {
        var kind: Kind
        var path: String
        var mode: Int
        var mtime: Date
        var size: Int
        var handle: FileHandle?
        var url: URL?
        var meta = Data()
    }
    private enum State { case header, body(Current, remaining: Int), padding(Int) }

    public init(destination: URL, maxBytes: Int64 = 4 << 30) {
        self.destination = destination
        self.maxBytes = maxBytes
        root = destination.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public mutating func feed(_ data: Data) throws {
        guard !done else { return }
        buffer.append(data)
        while try step() {}
    }

    /// Chame no fim do stream. Falha se o tar terminou no meio de uma entrada.
    public mutating func finish() throws -> TarExtractionReport {
        if case .body(let current, _) = state {
            try? current.handle?.close()
            throw TarExtractionError.malformed("tar truncado em \(current.path)")
        }
        return report
    }

    // MARK: Máquina de estados

    private mutating func step() throws -> Bool {
        switch state {
        case .header:
            guard buffer.count >= 512 else { return false }
            let block = Data(buffer.prefix(512))
            buffer = Data(buffer.dropFirst(512))
            if block.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                if zeroBlocks >= 2 { done = true; buffer = Data() }
                return !done
            }
            zeroBlocks = 0
            try begin(block)
            return true
        case .body(var current, let remaining):
            if remaining == 0 {
                try end(&current)
                let pad = (512 - current.size % 512) % 512
                state = .padding(pad)
                return true
            }
            guard !buffer.isEmpty else { return false }
            let take = min(remaining, buffer.count)
            let chunk = Data(buffer.prefix(take))
            buffer = Data(buffer.dropFirst(take))
            switch current.kind {
            case .file:
                report.bytes += Int64(take)
                if report.bytes > maxBytes { try? current.handle?.close(); throw TarExtractionError.tooLarge(limit: maxBytes) }
                do { try current.handle?.write(contentsOf: chunk) } catch { throw TarExtractionError.io("\(error)") }
            case .meta: current.meta.append(chunk)
            case .skip: break
            }
            state = .body(current, remaining: remaining - take)
            return true
        case .padding(let pad):
            guard pad > 0 else { state = .header; return true }
            guard !buffer.isEmpty else { return false }
            let take = min(pad, buffer.count)
            buffer = Data(buffer.dropFirst(take))
            state = take == pad ? .header : .padding(pad - take)
            return true
        }
    }

    private static func field(_ block: Data, _ offset: Int, _ length: Int) -> String {
        let slice = block[block.startIndex + offset ..< block.startIndex + offset + length]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex ..< end], as: UTF8.self)
    }

    private static func number(_ block: Data, _ offset: Int, _ length: Int) throws -> Int {
        let slice = block[block.startIndex + offset ..< block.startIndex + offset + length]
        if let first = slice.first, first & 0x80 != 0 {  // base-256 (GNU) para tamanhos grandes
            var value = Int(first & 0x7F)
            for byte in slice.dropFirst() { value = (value << 8) | Int(byte) }
            return value
        }
        let text = Self.field(block, offset, length).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8) else { throw TarExtractionError.malformed("campo numérico inválido") }
        return value
    }

    private mutating func begin(_ block: Data) throws {
        let type = block[block.startIndex + 156]
        let size = try Self.number(block, 124, 12)
        let mode = try Self.number(block, 100, 8)
        let mtime = Date(timeIntervalSince1970: TimeInterval(try Self.number(block, 136, 12)))
        var name = Self.field(block, 0, 100)
        let prefix = Self.field(block, 345, 155)
        if Self.field(block, 257, 5) == "ustar", !prefix.isEmpty { name = prefix + "/" + name }
        if let long = longName { name = long; longName = nil }
        if let pax = paxPath { name = pax; paxPath = nil }
        let link = Self.field(block, 157, 100)
        func current(_ kind: Kind) -> Current { Current(kind: kind, path: name, mode: mode, mtime: mtime, size: size) }

        switch type {
        case UInt8(ascii: "x"): state = .body(current(.meta(.pax)), remaining: size)
        case UInt8(ascii: "g"): state = .body(current(.meta(.paxGlobal)), remaining: size)
        case UInt8(ascii: "L"): state = .body(current(.meta(.gnuLongName)), remaining: size)
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            guard let url = safeURL(name) else { skip(name, size: size, mode: mode, mtime: mtime); return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Pai resolvido (symlink antigo) tem de continuar dentro do destino.
                guard isInside(url.deletingLastPathComponent().resolvingSymlinksInPath().path) else { skip(name, size: size, mode: mode, mtime: mtime); return }
                try? FileManager.default.removeItem(at: url)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw TarExtractionError.io("não criou \(url.path)") }
                var cur = current(.file)
                cur.handle = try FileHandle(forWritingTo: url)
                cur.url = url
                state = .body(cur, remaining: size)
                report.files += 1
            } catch let error as TarExtractionError { throw error } catch { throw TarExtractionError.io("\(error)") }
        case UInt8(ascii: "5"):
            if let url = safeURL(name) {
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try? FileManager.default.setAttributes([.posixPermissions: (mode & 0o777) | 0o700], ofItemAtPath: url.path)
                    report.directories += 1
                } catch { throw TarExtractionError.io("\(error)") }
            } else if !Self.components(name).isEmpty { report.skipped.append(name) }
            state = .body(current(.skip), remaining: size)
        case UInt8(ascii: "2"):
            if let url = safeURL(name), linkStaysInside(link, from: url) {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: link)
                    report.symlinks += 1
                } catch { throw TarExtractionError.io("\(error)") }
            } else { report.skipped.append(name) }
            state = .body(current(.skip), remaining: size)
        default:  // hardlink, dispositivos, FIFO...
            report.skipped.append(name)
            state = .body(current(.skip), remaining: size)
        }
    }

    private mutating func skip(_ name: String, size: Int, mode: Int, mtime: Date) {
        report.skipped.append(name)
        state = .body(Current(kind: .skip, path: name, mode: mode, mtime: mtime, size: size), remaining: size)
    }

    private mutating func end(_ current: inout Current) throws {
        switch current.kind {
        case .file:
            try? current.handle?.close()
            if let url = current.url {
                // Sem setuid/setgid/sticky; o dono do Mac sempre lê e escreve.
                try? FileManager.default.setAttributes([.posixPermissions: (current.mode & 0o777) | 0o600, .modificationDate: current.mtime], ofItemAtPath: url.path)
            }
        case .meta(.gnuLongName):
            longName = String(decoding: current.meta.prefix { $0 != 0 }, as: UTF8.self)
        case .meta(.pax):
            for line in String(decoding: current.meta, as: UTF8.self).split(separator: "\n") {
                // "<len> chave=valor"
                guard let space = line.firstIndex(of: " ") else { continue }
                let pair = line[line.index(after: space)...]
                if pair.hasPrefix("path=") { paxPath = String(pair.dropFirst(5)) }
            }
        case .meta(.paxGlobal), .skip: break
        }
    }

    // MARK: Caminhos

    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty } }

    /// `nil` se o caminho é vazio (a raiz), contém `..` ou escapa do destino.
    private func safeURL(_ path: String) -> URL? {
        let parts = Self.components(path)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        var url = URL(fileURLWithPath: root, isDirectory: true)
        for part in parts { url.appendPathComponent(part) }
        return isInside(url.standardizedFileURL.path) ? url : nil
    }

    private func isInside(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    private func linkStaysInside(_ target: String, from link: URL) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        let resolved = link.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        return isInside(resolved)
    }
}
