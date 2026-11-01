import CryptoKit
import Foundation

/// Arquivo do contexto de build: caminho relativo (com `/`), bytes e bit de execução.
struct ContextFile: Sendable, Equatable {
    var path: String
    var data: Data
    var executable: Bool
}

/// Leitura determinística do diretório de contexto e geração do tar e do hash do conteúdo (07 CS-120).
///
/// Hash do contexto: `sha256` da concatenação, em ordem bytewise dos caminhos, de linhas
/// `"<caminho>\0<755|644>\0<sha256 do arquivo>\n"`. Só arquivos regulares; `.DS_Store`, `__pycache__`/`*.pyc` e symlinks ficam de fora
/// (symlink é erro: o contexto precisa ser autocontido). `scripts/build-runtime-image.sh` calcula o mesmo valor.
public enum BuildContext {
    static func files(in directory: URL) throws -> [ContextFile] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DockerError.invalidBuildContext("diretório inexistente: \(directory.path)")
        }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else {
            throw DockerError.invalidBuildContext("não foi possível listar \(directory.path)")
        }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [ContextFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { throw DockerError.invalidBuildContext("symlink no contexto: \(url.lastPathComponent)") }
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { throw DockerError.invalidBuildContext("arquivo fora do contexto: \(full)") }
            let relative = String(full.dropFirst(base.count + 1))
            // Lixo de execução local (testes Python do contexto) não entra no hash nem no tar.
            if relative.split(separator: "/").contains("__pycache__") || relative.hasSuffix(".pyc") { continue }
            let permissions = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
            result.append(ContextFile(path: relative, data: try Data(contentsOf: url), executable: permissions & 0o100 != 0))
        }
        // Ordem bytewise (UTF-8), igual a `LC_ALL=C sort`.
        return result.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Hash hexadecimal completo (64 caracteres) do conteúdo do contexto.
    public static func contentHash(of directory: URL) throws -> String {
        try contentHash(files: files(in: directory))
    }

    static func contentHash(files: [ContextFile]) -> String {
        var hasher = SHA256()
        for file in files {
            let line = "\(file.path)\0\(file.executable ? "755" : "644")\0\(hex(SHA256.hash(data: file.data)))\n"
            hasher.update(data: Data(line.utf8))
        }
        return hex(hasher.finalize())
    }

    /// `racky-box:ctx-<sha12>`.
    public static func tag(repository: String, hash: String) -> String { "\(repository):ctx-\(hash.prefix(12))" }

    /// Tar ustar determinístico (mtime 0, uid/gid 0) do contexto, pronto para `POST /build`.
    public static func tar(of directory: URL) throws -> Data {
        try TarArchive.create(files: files(in: directory))
    }
}

/// Escritor ustar mínimo (arquivos regulares e diretórios implícitos pelos caminhos).
enum TarArchive {
    static func create(files: [ContextFile]) throws -> Data {
        var out = Data()
        var directories = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/").dropLast().map(String.init)
            var prefix: [String] = []
            for part in parts {
                prefix.append(part)
                let dir = prefix.joined(separator: "/")
                if directories.insert(dir).inserted { out.append(try header(path: dir + "/", size: 0, mode: 0o755, type: "5")) }
            }
            out.append(try header(path: file.path, size: file.data.count, mode: file.executable ? 0o755 : 0o644, type: "0"))
            out.append(file.data)
            let padding = (512 - file.data.count % 512) % 512
            if padding > 0 { out.append(Data(count: padding)) }
        }
        out.append(Data(count: 1024))
        return out
    }

    static func header(path: String, size: Int, mode: Int, type: Character, uid: Int = 0, gid: Int = 0) throws -> Data {
        var name = path
        var prefix = ""
        let bytes = Array(path.utf8)
        if bytes.count > 100 {
            // Divide em prefixo (<= 155) e nome (<= 100) numa barra.
            var split: Int?
            for (index, byte) in bytes.enumerated() where byte == 0x2F && index <= 155 && bytes.count - index - 1 <= 100 && bytes.count - index - 1 > 0 {
                split = index
            }
            guard let split else { throw DockerError.invalidBuildContext("caminho longo demais para tar: \(path)") }
            prefix = String(decoding: bytes[..<split], as: UTF8.self)
            name = String(decoding: bytes[(split + 1)...], as: UTF8.self)
        }
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, byte) in text.utf8.prefix(length).enumerated() { block[offset + i] = byte }
        }
        func octal(_ value: Int, length: Int) -> String {
            let digits = String(value, radix: 8)
            return String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        }
        put(name, at: 0, length: 100)
        put(octal(mode, length: 8), at: 100, length: 7)
        put(octal(uid, length: 8), at: 108, length: 7)
        put(octal(gid, length: 8), at: 116, length: 7)
        put(octal(size, length: 12), at: 124, length: 11)
        put(octal(0, length: 12), at: 136, length: 11)
        for i in 148 ..< 156 { block[i] = 0x20 }  // checksum calculado com espaços
        block[156] = type.asciiValue ?? 0x30
        put("ustar", at: 257, length: 5)
        put("00", at: 263, length: 2)
        put(prefix, at: 345, length: 155)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(octal(checksum, length: 7), at: 148, length: 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }
}
