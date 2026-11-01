import RackyPlatform
import RackyProtocol
import ArgumentParser
import Foundation

/// Saída do CLI: sempre JSON em stdout (08 AR-806).
enum CtlOutput {
    static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func writeJSON<T: Encodable>(_ value: T) {
        if let data = try? CtlCodec.encoder().encode(value) { write(data) }
    }

    /// Falha em JSON e sai com código diferente de zero (1 = erro do app/ação, 2 = sem conexão, 3 = canal desligado).
    static func fail(code: String, message: String, reason: String? = nil, exit status: Int32 = 1) -> ExitCode {
        writeJSON(CtlResponse.failure(CtlError(code: code, message: message, reason: reason)))
        return ExitCode(status)
    }
}

/// Fala com o serviço `ctl` de `app.sock`: handshake de serviço e uma requisição.
struct CtlClient {
    let socketPath: String
    var timeout: Duration = .seconds(30)

    enum Failure: Error {
        case notRunning(String)
        case transport(String)
    }

    func send(_ request: CtlRequest) async throws -> CtlResponse {
        let conn: AppSockConnection
        do {
            conn = try AppSockClient.connect(path: socketPath)
        } catch {
            throw Failure.notRunning("cannot connect to \(socketPath): is the app running with the automation channel on (RACKY_AUTOMATION=1)?")
        }
        do {
            let response = try await withTimeout(timeout) { try await exchange(conn, request) }
            await conn.close()
            return response
        } catch {
            await conn.close()
            throw error
        }
    }

    private func exchange(_ conn: AppSockConnection, _ request: CtlRequest) async throws -> CtlResponse {
        let enc = CtlCodec.encoder()
        let dec = CtlCodec.decoder()
        try await conn.send(try enc.encode(AppSockHello(service: .ctl)))
        let hello = try dec.decode(AppSockHelloReply.self, from: try await conn.receive())
        guard hello.ok else {
            return .failure(hello.error ?? CtlError(code: "bad_request", message: "handshake refused"))
        }
        try await conn.send(try enc.encode(request))
        return try dec.decode(CtlResponse.self, from: try await conn.receive())
    }

    private func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Failure.transport("no reply from the app within \(limit)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.transport("no reply") }
            return first
        }
    }
}

/// Executa uma requisição e imprime o JSON; devolve o código de saída.
func runCtl(_ options: CtlOptions, _ request: CtlRequest, timeout: Duration = .seconds(30), render: (CtlResponse) throws -> Void) async throws {
    var client = CtlClient(socketPath: options.resolvedSocket)
    client.timeout = timeout
    do {
        let response = try await client.send(request)
        if response.ok {
            try render(response)
        } else {
            let err = response.error ?? CtlError(code: "bad_request", message: "unknown error")
            CtlOutput.writeJSON(response)
            throw ExitCode(err.code == "ctl_disabled" ? 3 : 1)
        }
    } catch let e as CtlClient.Failure {
        switch e {
        case .notRunning(let m): throw CtlOutput.fail(code: "not_running", message: m, exit: 2)
        case .transport(let m): throw CtlOutput.fail(code: "transport", message: m, exit: 2)
        }
    } catch let e as ExitCode {
        throw e
    } catch {
        throw CtlOutput.fail(code: "transport", message: "\(error)", exit: 2)
    }
}
