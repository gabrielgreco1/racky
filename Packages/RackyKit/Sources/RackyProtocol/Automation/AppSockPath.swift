import Foundation

/// Onde mora `app.sock` (08 §0.1): `AB/run/app.sock`, `AB = ~/Library/Application Support/Racky`.
public enum AppSockPath {
    /// `RACKY_APP_SOCK` (também injetado nos terminais, AR-111) sobrepõe o padrão. Um `RACKY_HOME` isolado (testes, selftest, dev)
    /// tem o próprio `run/app.sock`: antes ele caía no `app.sock` do app do dono, e um teste rodando junto com o app trocava o
    /// arquivo por um morto ("Racky is not running" para todos os agentes, 03/11).
    public static func resolve(environment: [String: String]) -> String {
        if let override = environment["RACKY_APP_SOCK"], !override.isEmpty { return override }
        if let home = environment["RACKY_HOME"], !home.isEmpty { return (home as NSString).appendingPathComponent("run/app.sock") }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/Racky/run/app.sock"
    }
}
