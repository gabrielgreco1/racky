import Foundation

/// Pasta de trabalho de uma sessão criada por lançamento (sessão limpa gerenciada, P10). A UI não toca o disco.
public enum LaunchFolder {
    /// Cria a pasta (e os pais) se não existir.
    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
