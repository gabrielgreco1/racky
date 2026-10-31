import Darwin
import Foundation

/// Credenciais do peer de um socket Unix, lidas do kernel no `accept` (S-03; 06 §1.4, 08 AR-503).
///
/// - `uid`/`gid`: `getpeereid` (credenciais de quem chamou `connect`).
/// - `pid`: `LOCAL_PEERPID` (só diagnóstico; nunca base de decisão, PIDs são reaproveitados).
/// - `auditToken`: `LOCAL_PEERTOKEN` (32 bytes, `audit_token_t`). É o que identifica o processo sem corrida de PID.
public struct PeerCredentials: Sendable, Hashable {
    public var uid: uid_t
    public var gid: gid_t
    public var pid: pid_t?
    public var auditToken: Data?

    public init(uid: uid_t, gid: gid_t, pid: pid_t? = nil, auditToken: Data? = nil) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
        self.auditToken = auditToken
    }

    /// Lê as credenciais de um socket Unix conectado. `nil` se `getpeereid` falhar (fail closed).
    public static func read(from fd: Int32) -> PeerCredentials? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        let pidResult = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength)
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenResult = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength)
        let tokenData = tokenResult == 0 && Int(tokenLength) == MemoryLayout<audit_token_t>.size ? withUnsafeBytes(of: token) { Data($0) } : nil
        return PeerCredentials(uid: uid, gid: gid, pid: pidResult == 0 ? pid : nil, auditToken: tokenData)
    }
}
