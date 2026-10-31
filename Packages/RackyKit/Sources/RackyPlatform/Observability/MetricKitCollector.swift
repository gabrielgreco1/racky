import Foundation
import MetricKit

/// Diagnósticos de hang e crash entregues pelo sistema (`MXMetricManager`, 08 AR-604), gravados em `logs/metrickit-*.json` já redigidos.
/// O MetricKit entrega no máximo uma vez por dia e só fora do Xcode; não pede nenhuma permissão.
public final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {  // SAFETY: só `directory` (let imutável); o MetricKit chama em fila própria
    private let directory: URL

    public init(logsDirectory: URL) {
        directory = logsDirectory
        super.init()
    }

    public func start() { MXMetricManager.shared.add(self) }
    public func stop() { MXMetricManager.shared.remove(self) }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { write(kind: "metrics", data: payload.jsonRepresentation()) }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { write(kind: "diagnostics", data: payload.jsonRepresentation()) }
    }

    private func write(kind: String, data: Data) {
        let text = LogRedactor.redact(String(decoding: data, as: UTF8.self))
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("metrickit-\(kind)-\(stamp).json")
        try? Data(text.utf8).write(to: url, options: .atomic)
        pruneOld()
    }

    /// Guarda só os 10 mais recentes.
    private func pruneOld() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let old = names.filter { $0.hasPrefix("metrickit-") }.sorted().dropLast(10)
        for name in old { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
