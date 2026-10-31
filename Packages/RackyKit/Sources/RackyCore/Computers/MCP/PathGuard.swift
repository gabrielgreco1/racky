import Darwin
import Foundation

/// Validação de caminhos recebidos por ferramentas (07 CS-234, CA-207). Todo caminho precisa ficar dentro de `/work` (no
/// container) ou da pasta `work/` do run (no host). Recusa com `path_rejected`: `..` que escapa depois da normalização,
/// caminhos absolutos fora da raiz, NUL e **symlinks** (qualquer componente que seja symlink: conservador, o agente cria os
/// symlinks). No host o arquivo é aberto componente a componente com `openat` + `O_NOFOLLOW`, nunca por `realpath` seguido de
/// um `open` comum.
public enum PathGuard {
    public static let boxRoot = "/work"

    /// Componentes relativos à raiz, normalizados. `/work/a/b`, `a/b` e `./a/../a/b` dão `["a","b"]`.
    public static func components(_ raw: String) throws -> [String] {
        guard !raw.isEmpty, !raw.contains("\0") else { throw ToolError(.pathRejected, "empty or invalid path") }
        var path = raw
        if path.hasPrefix("/") {
            guard path == boxRoot || path.hasPrefix(boxRoot + "/") else {
                throw ToolError(
                    .pathRejected, "absolute path outside /work: tools only save under /work (use /work/scratch/ for throwaway files)",
                    details: ["path": .string(raw)])
            }
            path = String(path.dropFirst(boxRoot.count))
        }
        var stack: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { throw ToolError(.pathRejected, "path escapes /work", details: ["path": .string(raw)]) }
                stack.removeLast()
            default: stack.append(String(part))
            }
        }
        return stack
    }

    /// Caminho normalizado dentro do container (`/work/a/b`). Também recusa symlinks existentes no caminho (via host).
    public static func boxPath(_ raw: String, hostRoot: URL? = nil) throws -> String {
        let parts = try components(raw)
        if let hostRoot { try rejectSymlinks(root: hostRoot, parts) }
        return parts.isEmpty ? boxRoot : boxRoot + "/" + parts.joined(separator: "/")
    }

    /// `lstat` componente a componente: o primeiro que for symlink recusa. Componentes que ainda não existem passam.
    public static func rejectSymlinks(root: URL, _ parts: [String]) throws {
        var current = realRoot(root)
        for part in parts {
            current = (current as NSString).appendingPathComponent(part)
            var info = stat()
            if lstat(current, &info) != 0 { return }  // não existe: nada a seguir
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw ToolError(.pathRejected, "symlinks are not allowed in /work paths", details: ["path": .string(parts.joined(separator: "/"))])
            }
        }
    }

    static func realRoot(_ root: URL) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        if realpath(root.path, &buffer) != nil { return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return root.path
    }

    // MARK: Leitura e escrita no host

    private static func openRoot(_ root: URL, create: Bool) throws -> Int32 {
        if create { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let fd = open(realRoot(root), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError(.notFound, "run folder is not available") }
        return fd
    }

    private static func reject(_ parts: [String], _ code: Int32) -> ToolError {
        if code == ELOOP || code == ENOTDIR || code == EMLINK {
            return ToolError(.pathRejected, "symlinks are not allowed in /work paths", details: ["path": .string(parts.joined(separator: "/"))])
        }
        if code == ENOENT { return ToolError(.notFound, "file not found: \(parts.joined(separator: "/"))") }
        return ToolError(.pathRejected, "cannot open \(parts.joined(separator: "/")): \(String(cString: strerror(code)))")
    }

    /// Abre o arquivo (somente leitura) sem seguir nenhum symlink. `maxBytes` evita ler arquivos enormes por engano.
    public static func read(root: URL, _ raw: String, maxBytes: Int = 64 << 20) throws -> Data {
        let parts = try components(raw)
        guard let last = parts.last else { throw ToolError(.pathRejected, "path is the /work directory") }
        var dir = try openRoot(root, create: false)
        defer { close(dir) }
        for part in parts.dropLast() {
            let next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw reject(parts, errno) }
            close(dir)
            dir = next
        }
        let fd = openat(dir, last, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw reject(parts, errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ToolError(.pathRejected, "not a regular file") }
        guard info.st_size <= maxBytes else { throw ToolError.invalid("file larger than \(maxBytes) bytes") }
        return try FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true).readToEnd() ?? Data()
    }

    public static func exists(root: URL, _ raw: String) -> Bool {
        (try? read(root: root, raw, maxBytes: Int.max)) != nil
    }

    /// Grava criando as pastas intermediárias, sem seguir symlinks e sem sobrescrever um symlink existente.
    @discardableResult
    public static func write(root: URL, _ raw: String, _ data: Data) throws -> String {
        let parts = try components(raw)
        guard let last = parts.last else { throw ToolError(.pathRejected, "path is the /work directory") }
        var dir = try openRoot(root, create: true)
        defer { close(dir) }
        for part in parts.dropLast() {
            var next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard mkdirat(dir, part, 0o755) == 0 || errno == EEXIST else { throw reject(parts, errno) }
                next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw reject(parts, errno) }
            close(dir)
            dir = next
        }
        let fd = openat(dir, last, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw reject(parts, errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        return boxRoot + "/" + parts.joined(separator: "/")
    }
}
