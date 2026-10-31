import Darwin
import Foundation

/// SIGTERM, SIGINT e SIGHUP no app (F30): um `kill`, o encerramento de um shell pai ou o logout NUNCA significam "parar os
/// agentes". Viram o mesmo caminho do Keep Running: o app sai e o daemon e os agentes seguem. Só as ações explícitas
/// "Stop All and Quit" e "Quit Completely" encerram agentes.
@MainActor
public final class ExternalTerminationSignals {
    public static let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
    private var sources: [DispatchSourceSignal] = []
    private let onSignal: @MainActor (Int32) -> Void

    public init(onSignal: @escaping @MainActor (Int32) -> Void) {
        self.onSignal = onSignal
    }

    public func install() {
        guard sources.isEmpty else { return }
        for number in Self.signals {
            signal(number, SIG_IGN)  // sem isto o padrão do sistema encerra o processo antes da fonte rodar
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [onSignal] in MainActor.assumeIsolated { onSignal(number) } }
            source.resume()
            sources.append(source)
        }
    }

    public func uninstall() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for number in Self.signals { signal(number, SIG_DFL) }
    }
}
