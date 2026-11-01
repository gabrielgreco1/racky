import Darwin
import Foundation

/// Uma instância do app por pasta de dados: `flock` em `<dados>/run/app.lock`, com o pid de quem o tem dentro.
public enum InstanceLock {
    /// fd do lock; fica aberto a vida toda do processo (o `flock` some com ele).
    nonisolated(unsafe) private static var held: Int32 = -1  // SAFETY: gravado uma vez no launch, no main thread.

    /// `nil`: o lock é nosso. Senão, o pid de quem o tem (`-1` se ilegível).
    public static func acquire(runDirectory: URL) -> pid_t? {
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(runDirectory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            held = fd
            _ = ftruncate(fd, 0)
            let pid = "\(ProcessInfo.processInfo.processIdentifier)"
            _ = pid.withCString { write(fd, $0, strlen($0)) }
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        close(fd)
        guard count > 0 else { return -1 }
        return pid_t(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
