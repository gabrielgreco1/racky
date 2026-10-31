import Foundation

/// Upgrade do daemon na mesma major (06 §1.10): o app compara os builds no `helloAck`.
public enum DaemonUpgradePolicy {
    public enum Action: Sendable, Equatable {
        case none
        /// O daemon é mais antigo: continua aceitando sessões e sai quando a última terminar; o launchd sobe o binário novo
        /// na próxima conexão. Diagnostics mostra "Daemon update pending (n terminals running)".
        case drainWhenIdle
    }

    /// Builds numéricos (`CFBundleVersion` = número de commits). Build de desenvolvimento ("1.0 (dev)") nunca dispara upgrade.
    public static func decide(appBuild: String, daemonBuild: String) -> Action {
        guard let app = number(appBuild), let daemon = number(daemonBuild) else { return .none }
        return daemon < app ? .drainWhenIdle : .none
    }

    static func number(_ build: String) -> Int? {
        let digits = build.trimmingCharacters(in: .whitespaces)
        return digits.isEmpty || !digits.allSatisfy(\.isNumber) ? nil : Int(digits)
    }

    /// Texto do Diagnostics (06 §1.10): "Daemon update pending (7 terminals running)".
    public static func pendingText(liveTerminals: Int) -> String {
        "Daemon update pending (\(liveTerminals) \(liveTerminals == 1 ? "terminal" : "terminals") running)"
    }
}
