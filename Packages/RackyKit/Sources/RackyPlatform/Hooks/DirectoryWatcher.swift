import Darwin
import Dispatch
import Foundation

/// Observa um diretório por kqueue (`DispatchSource`), nunca por polling (08 AR-109). Emite um valor a cada mudança
/// (entrada criada, renomeada ou removida); valores acumulados viram um só.
public enum DirectoryWatcher {
    public enum Failure: Error { case cannotOpen(String, Int32) }

    // SAFETY: a fonte só é usada para `cancel()`, que é thread-safe; ela nasce e morre junto do stream.
    private final class SourceBox: @unchecked Sendable {
        let source: any DispatchSourceFileSystemObject
        init(_ source: any DispatchSourceFileSystemObject) { self.source = source }
    }

    public static func changes(of directory: URL) throws -> AsyncStream<Void> {
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.cannotOpen(directory.path, errno) }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .global(qos: .utility))
            source.setEventHandler { continuation.yield(()) }
            source.setCancelHandler { close(fd) }
            let box = SourceBox(source)
            continuation.onTermination = { _ in box.source.cancel() }
            source.resume()
        }
    }
}
