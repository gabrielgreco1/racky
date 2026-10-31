import RackyProtocol
import Darwin
import Foundation

/// Spool de hooks em disco (06 §3.2, 08 §0.2): `AB/run/spool/hooks/<runID>.jsonl`, `0600`, 4 MiB por arquivo.
///
/// Protocolo entre o helper (escritor, vários processos) e o app (leitor):
/// - o escritor abre com `O_APPEND`, toma `flock(LOCK_EX)` e confere que o inode ainda é o do caminho (o leitor pode ter
///   renomeado o arquivo enquanto o escritor esperava o lock); se mudou, reabre;
/// - o leitor toma o mesmo lock, **renomeia** o arquivo para `<nome>.<id>.draining`, solta o lock e lê o renomeado.
///   Novos eventos caem num arquivo novo; nada se perde nem se lê duas vezes. O "cursor" é a existência do arquivo:
///   `discard` apaga o `.draining` depois de processado, e um `.draining` que sobrou (crash) é relido no próximo boot
///   (a ingestão é idempotente pelo id do evento). Linha inválida é pulada pelo chamador; o cursor avança de qualquer forma.
public enum HookSpool {
    public static let eventSuffix = ".jsonl"
    public static let drainingSuffix = ".draining"

    /// `AB/run/spool/hooks` a partir de `RACKY_APP_SOCK` (`AB/run/app.sock`).
    public static func directory(forSocketPath socketPath: String) -> URL {
        URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent("spool", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// Só `[A-Za-z0-9-]` e até 64 caracteres: o run id vira nome de arquivo.
    public static func isSafeRunID(_ runID: String) -> Bool {
        guard !runID.isEmpty, runID.utf8.count <= 64 else { return false }
        return runID.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }

    public static func fileURL(directory: URL, runID: String) -> URL {
        directory.appendingPathComponent(runID + eventSuffix)
    }

    public enum Failure: Error, Equatable {
        case unsafeRunID
        case system(op: String, errno: Int32)
    }

    public static func ensureDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        var current = directory
        var toCreate: [URL] = []
        while !fm.fileExists(atPath: current.path), current.path != "/" {
            toCreate.append(current)
            current.deleteLastPathComponent()
        }
        for dir in toCreate.reversed() {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        _ = chmod(directory.path, 0o700)
    }

    // MARK: - Escritor (helper)

    /// Acrescenta uma linha. Acima de `limitBytes` descarta as linhas mais antigas e grava um marcador `truncated`.
    public static func append(
        _ line: Data, runID: String, directory: URL, nowNs: Int64,
        limitBytes: Int = HookLimits.spoolFileLimitBytes, keepBytes: Int = HookLimits.spoolTruncatedKeepBytes
    ) throws {
        guard isSafeRunID(runID) else { throw Failure.unsafeRunID }
        try ensureDirectory(directory)
        let path = fileURL(directory: directory, runID: runID).path
        var payload = line
        payload.removeAll { $0 == 0x0A }  // uma linha por evento
        payload.append(0x0A)

        for _ in 0..<8 {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.system(op: "open", errno: errno) }
            defer { close(fd) }
            guard lock(fd) else { throw Failure.system(op: "flock", errno: errno) }
            var onDisk = stat(), atPath = stat()
            guard fstat(fd, &onDisk) == 0 else { throw Failure.system(op: "fstat", errno: errno) }
            guard stat(path, &atPath) == 0, atPath.st_ino == onDisk.st_ino, atPath.st_dev == onDisk.st_dev else {
                continue  // o leitor renomeou o arquivo enquanto esperávamos o lock
            }
            if Int(onDisk.st_size) + payload.count > limitBytes {
                try rewriteTruncated(path: path, appending: payload, keepBytes: keepBytes, nowNs: nowNs, directory: directory, runID: runID)
                return
            }
            try writeAll(fd, payload)
            return
        }
        throw Failure.system(op: "flock-retry", errno: EAGAIN)
    }

    private static func lock(_ fd: Int32) -> Bool {
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system(op: "write", errno: errno)
                }
                offset += n
            }
        }
    }

    /// Com o lock do arquivo atual em mãos: lê, descarta o começo, grava `marcador + restante + nova linha` num
    /// temporário e o põe no lugar do caminho (inode novo; quem esperava o lock reabre).
    private static func rewriteTruncated(path: String, appending: Data, keepBytes: Int, nowNs: Int64, directory: URL, runID: String) throws {
        let existing = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        var lines = existing.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        var dropped = 0
        // Marcadores antigos entram na contagem de descartados.
        lines.removeAll { l in
            if case .marker(let m) = HookSpoolLine.parse(l) { dropped += m.dropped; return true }
            return false
        }
        let markerReserve = 128
        var total = lines.reduce(0) { $0 + $1.count + 1 } + appending.count + markerReserve
        var firstKept = 0
        while total > keepBytes, firstKept < lines.count {
            total -= lines[firstKept].count + 1
            firstKept += 1
            dropped += 1
        }
        var out = Data()
        if dropped > 0, let marker = try? HookCodec.encoder().encode(HookSpoolMarker(dropped: dropped, atNs: nowNs)) {
            out.append(marker); out.append(0x0A)
        }
        for l in lines[firstKept...] { out.append(l); out.append(0x0A) }
        out.append(appending)

        let tmp = directory.appendingPathComponent(".\(runID).\(getpid()).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(op: "open-tmp", errno: errno) }
        defer { close(fd) }
        do { try writeAll(fd, out) } catch { unlink(tmp); throw error }
        guard rename(tmp, path) == 0 else {
            let e = errno
            unlink(tmp)
            throw Failure.system(op: "rename", errno: e)
        }
    }

    // MARK: - Leitor (app)

    /// Move cada `*.jsonl` para `.draining` (sob o lock dos escritores) e devolve todos os `.draining` pendentes,
    /// inclusive os de um crash anterior, em ordem de nome. Diretório inexistente = nada a fazer.
    public static func takeAll(directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        for name in names.sorted() where name.hasSuffix(eventSuffix) && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard lock(fd) else { continue }
            let target = path + "." + UUID().uuidString.prefix(8).lowercased() + drainingSuffix
            _ = rename(path, target)
        }
        let after = try fm.contentsOfDirectory(atPath: directory.path)
        return after.filter { $0.hasSuffix(drainingSuffix) }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Linhas não vazias do arquivo.
    public static func readLines(_ url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Avança o cursor: apaga o arquivo consumido.
    public static func discard(_ url: URL) {
        unlink(url.path)
    }
}
