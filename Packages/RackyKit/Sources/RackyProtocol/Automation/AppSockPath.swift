import Foundation

/// Onde mora `app.sock` (08 §0.1): `AB/run/app.sock`, `AB = ~/Library/Application Support/Racky`.
public enum AppSockPath {
    /// `RACKY_APP_SOCK` (também injetado nos terminais, AR-111) sobrepõe o padrão.
    public static func resolve(environment: [String: String]) -> String {
        if let override = environment["RACKY_APP_SOCK"], !override.isEmpty { return override }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/Racky/run/app.sock"
    }
}
