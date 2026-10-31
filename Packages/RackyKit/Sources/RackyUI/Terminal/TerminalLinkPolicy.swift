import RackyCore
import Foundation

/// Quais links o terminal abre com ⌘-clique (03 §4.1). Só esquemas simples e seguros: um programa no terminal pode
/// emitir OSC 8 com qualquer URL, e abrir `x-apple.systempreferences:`, `file:` ou um esquema de app registrado a
/// partir de saída não confiável é um vetor.
public enum TerminalLinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func openableURL(_ link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048, let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme)
        else { return nil }
        if scheme != "mailto", url.host?.isEmpty ?? true { return nil }
        return url
    }

    /// Extensões que o app padrão do sistema executa em vez de mostrar (⇧⌘-clique num caminho da saída do terminal): nessas o
    /// app só revela no Finder.
    public static let executableExtensions: Set<String> = [
        "app", "command", "tool", "workflow", "action", "scpt", "scptd", "applescript", "pkg", "mpkg", "dmg", "terminal", "jar", "webloc",
        "inetloc", "fileloc", "osax", "prefpane", "saver", "service", "kext", "xpc",
    ]

    /// `true` se abrir o arquivo com o app padrão não corre o risco de executá-lo (bit de execução também conta).
    public static func opensSafelyWithDefaultApp(_ path: String, isDirectory: Bool) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if executableExtensions.contains(ext) { return false }
        if isDirectory { return true }
        // Binário sem extensão com bit de execução: o sistema o rodaria no Terminal.
        return ext.isEmpty ? !PathProbe.isExecutableFile(path) : true
    }
}
