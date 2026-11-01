import Foundation

/// Caminhos do daemon (08 §0.1). `RACKY_HOME` isola testes; sem ele, `~/Library/Application Support/Racky`.
struct DaemonPaths: Sendable {
    var home: URL
    var socketPath: String
    var sessionsDirectory: URL

    init(home: URL, socketPath: String? = nil) {
        self.home = home
        self.socketPath = socketPath ?? home.appendingPathComponent("run/ptyd-v1.sock").path
        sessionsDirectory = home.appendingPathComponent("sessions", isDirectory: true)
    }

    static func resolve(environment: [String: String], socketOverride: String?, homeOverride: String?) -> DaemonPaths {
        let home: URL
        if let homeOverride {
            home = URL(fileURLWithPath: homeOverride, isDirectory: true)
        } else if let value = environment["RACKY_HOME"], !value.isEmpty {
            home = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Racky", isDirectory: true)
        }
        return DaemonPaths(home: home, socketPath: socketOverride)
    }

    /// Cria `AB`, `AB/run` e `AB/sessions` com `0700`. Com o socket do launchd (sem `bind`), o diretório do socket é do launchd.
    func prepare(includeSocketDirectory: Bool = true) throws {
        let manager = FileManager.default
        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        let runDirectory = home.appendingPathComponent("run", isDirectory: true)
        for directory in includeSocketDirectory ? [home, socketDirectory, sessionsDirectory] : [home, runDirectory, sessionsDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}
