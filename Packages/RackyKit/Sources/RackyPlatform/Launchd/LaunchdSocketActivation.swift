import Darwin
import Foundation

/// Ativação de socket pelo launchd (06 §1.2, S-01): `launch_activate_socket(3)`.
///
/// O símbolo existe em libSystem (`<launch.h>`) mas não é importado pelo Swift; resolvemos com `dlsym`.
/// O argumento é o **nome da entrada** no dicionário `Sockets` do plist (`Listeners`), não a variável de ambiente
/// publicada por `SecureSocketWithKey`.
public enum LaunchdSocketActivation {
    public enum Failure: Error, Equatable, Sendable {
        case unavailable
        case notManagedByLaunchd
        case system(Int32)
        case noSockets
    }

    /// Nome da entrada no `Sockets` do plist embutido (`Contents/Library/LaunchAgents/app.racky.ptyd.v1.plist`).
    public static let defaultSocketName = "Listeners"

    private typealias ActivateFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>
    ) -> Int32

    /// Pede ao launchd os descritores do socket `name`. Cada chamada só devolve os descritores uma vez por processo.
    public static func activate(name: String = defaultSocketName) throws(Failure) -> [Int32] {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "launch_activate_socket") else {
            throw .unavailable
        }
        let function = unsafeBitCast(symbol, to: ActivateFunction.self)
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let status = function(name, &descriptors, &count)
        switch status {
        case 0: break
        case ESRCH: throw .notManagedByLaunchd  // processo não é um job do launchd
        default: throw .system(status)
        }
        guard let descriptors, count > 0 else { throw .noSockets }
        defer { free(descriptors) }
        return Array(UnsafeBufferPointer(start: descriptors, count: count))
    }
}
