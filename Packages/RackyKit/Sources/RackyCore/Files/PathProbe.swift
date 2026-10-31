import Foundation

/// Consulta barata ao disco (um `stat`) para quem não pode tocar o `FileManager` (UI): o terminal confere se o caminho sob o
/// mouse existe antes de virar link. Bloqueante: chame fora do main.
public enum PathProbe {
    public enum Kind: Sendable, Equatable { case file, directory }

    public static func kind(of path: String) -> Kind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .directory : .file
    }

    public static func isExecutableFile(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
}
