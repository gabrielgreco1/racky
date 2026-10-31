import Foundation

/// Ponteiro `bin/rackyd-current` do home do Racky (F30): diz ao launcher (`rackyd-launch`) qual `rackyd` executar.
/// O launcher registrado no launchd é um só; o app instalado mais novo (maior build) atualiza o ponteiro, e abrir um app de
/// outra pasta com build menor ou igual nunca troca o daemon que o launchd sobe.
public struct DaemonPointer: Equatable, Sendable {
    public var path: String
    public var build: Int

    public static func url(home: URL) -> URL { home.appendingPathComponent("bin/rackyd-current") }

    public static func read(home: URL) -> DaemonPointer? {
        guard let text = try? String(contentsOf: url(home: home), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let path = lines.first, path.hasPrefix("/") else { return nil }
        return DaemonPointer(path: path, build: lines.count > 1 ? Int(lines[1]) ?? 0 : 0)
    }

    /// Número do build em `"1.0 (41)"` ou `"41"`; sem número, 0.
    public static func buildNumber(_ build: String) -> Int {
        if let open = build.lastIndex(of: "("), let close = build.lastIndex(of: ")"), open < close {
            return Int(build[build.index(after: open) ..< close]) ?? 0
        }
        return Int(build.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Aponta para `executable` se não há ponteiro válido (arquivo some ou binário apagado) ou se `build` for maior ou igual ao
    /// gravado. Devolve `true` se gravou.
    @discardableResult
    public static func update(home: URL, executable: URL, build: String) -> Bool {
        let number = buildNumber(build)
        if let current = read(home: home), FileManager.default.isExecutableFile(atPath: current.path),
            current.path != executable.path, current.build > number
        {
            return false
        }
        let file = url(home: home)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try "\(executable.path)\n\(number)\n".write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
