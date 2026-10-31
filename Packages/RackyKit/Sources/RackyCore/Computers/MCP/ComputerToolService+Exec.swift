import RackyDocker
import Foundation

extension ComputerToolService {
    static let tailLimit = 16 * 1024
    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// `argv` XOR `shell`, `cwd` dentro de `/work` sem symlink, nomes de env e de segredo válidos.
    func buildExec(_ args: Args, _ c: ManagedComputer, stdin: Data? = nil) throws -> BackendExec {
        let cwd = try PathGuard.boxPath(args.string("cwd") ?? "/work", hostRoot: c.run.work)
        let env = args.stringMap("env") ?? [:]
        for key in env.keys where !Self.validName(key) { throw ToolError.invalid("env name \(key) is not a valid variable name") }
        let secrets = args.strings("secret_env") ?? []
        for key in secrets where !Self.validName(key) { throw ToolError.invalid("secret_env name \(key) is not a valid variable name") }
        return BackendExec(argv: args.strings("argv"), shell: args.string("shell"), cwd: cwd, stdin: stdin, env: env, secretEnv: secrets)
    }

    /// Últimos `limit` bytes como texto, sem cortar um caractere no meio.
    static func tail(_ data: Data, limit: Int = tailLimit) -> (text: String, truncated: Bool) {
        guard data.count > limit else { return (String(decoding: data, as: UTF8.self), false) }
        var slice = data.suffix(limit)
        while let first = slice.first, first & 0xC0 == 0x80 { slice = slice.dropFirst() }  // continuação UTF-8 órfã
        return (String(decoding: slice, as: UTF8.self), true)
    }

    func writeCommandLog(_ c: ManagedComputer, number: Int, tool: String, request: BackendExec, outcome: BackendExecOutcome, started: Date) async -> String {
        let logID = String(format: "%04d", number)
        var body = outcome.stdout
        if !outcome.stderr.isEmpty { body += Data("\n--- stderr ---\n".utf8) + outcome.stderr }
        let file = c.run.commandsDirectory.appendingPathComponent("\(logID).log")
        try? FileManager.default.createDirectory(at: c.run.commandsDirectory, withIntermediateDirectories: true)
        try? body.write(to: file)
        var entry: [String: JSON] = [
            "command": .int(number), "tool": .string(tool), "ts": .double(started.timeIntervalSince1970),
            "ended": .double(Date().timeIntervalSince1970), "ms": .int(outcome.durationMs), "cwd": .string(request.cwd),
            "output_bytes": .int(outcome.stdout.count + outcome.stderr.count), "log_id": .string(logID),
        ]
        if let argv = request.argv { entry["argv"] = .array(argv.map { .string($0) }) }
        if let shell = request.shell { entry["shell"] = .string(shell) }
        if let exit = outcome.exitCode { entry["exit"] = .int(exit) }
        if outcome.timedOut { entry["timed_out"] = true }
        if !request.secretEnv.isEmpty { entry["secret_env"] = .array(request.secretEnv.map { .string($0) }) }  // só os NOMES
        if let stdin = request.stdin { entry["stdin_bytes"] = .int(stdin.count) }
        _ = try? await c.commands.append(entry)
        return logID
    }

    func exec(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let request = try buildExec(args, c, stdin: args.string("stdin").map { Data($0.utf8) })
        let timeout = min(args.double("timeout_s") ?? 45, 50)
        let number = await c.nextCommandNumber()
        let started = Date()
        let outcome = try await c.backend.execRun(request, timeout: .milliseconds(Int(timeout * 1000)))
        let logID = await writeCommandLog(c, number: number, tool: "exec", request: request, outcome: outcome, started: started)
        let out = Self.tail(outcome.stdout), err = Self.tail(outcome.stderr)
        if outcome.timedOut {
            throw ToolError(.timeout, "the command did not finish in \(timeout) s and was terminated; use exec_start for long commands", details: [
                "log_id": .string(logID), "stdout_tail": .string(out.text), "stderr_tail": .string(err.text),
            ])
        }
        return ToolResult(["exit_code": .int(outcome.exitCode ?? -1), "stdout_tail": .string(out.text), "stderr_tail": .string(err.text),
                           "truncated": .bool(out.truncated || err.truncated), "log_id": .string(logID), "duration_ms": .int(outcome.durationMs)])
    }

    func execStart(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let request = try buildExec(args, c)
        let number = await c.nextCommandNumber()
        let jobID = try await c.backend.execStart(request)
        jobs[jobID] = JobMeta(computer: c.name, number: number, request: request, started: Date())
        return ToolResult(["job_id": .string(jobID), "log_id": .string(String(format: "%04d", number))])
    }

    private func job(_ id: String, _ c: ManagedComputer) throws -> JobMeta {
        guard let meta = jobs[id], meta.computer == c.name else { throw ToolError(.notFound, "no job \(id) on this computer") }
        return meta
    }

    func execPoll(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let id = args.string("job_id") ?? ""
        _ = try job(id, c)
        let wait = min(max(args.double("wait_s") ?? 30, 0), 50)
        let outcome = try await c.backend.execPoll(jobID: id, wait: .milliseconds(Int(wait * 1000)))
        return try await jobResult(id, outcome, c)
    }

    func execCancel(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let id = args.string("job_id") ?? ""
        _ = try job(id, c)
        let outcome = try await c.backend.execCancel(jobID: id)
        _ = try await jobResult(id, outcome, c)
        return ToolResult(["cancelled": true, "exit_code": outcome.exitCode.map { .int($0) } ?? .null])
    }

    private func jobResult(_ id: String, _ outcome: BackendExecOutcome, _ c: ManagedComputer) async throws -> ToolResult {
        let out = Self.tail(outcome.stdout), err = Self.tail(outcome.stderr)
        var json: [String: JSON] = ["running": .bool(outcome.running), "stdout_tail": .string(out.text), "stderr_tail": .string(err.text)]
        if !outcome.running {
            json["exit_code"] = outcome.exitCode.map { .int($0) } ?? .null
            if var meta = jobs[id], !meta.logged {
                meta.logged = true
                jobs[id] = meta
                _ = await writeCommandLog(c, number: meta.number, tool: "exec_start", request: meta.request, outcome: outcome, started: meta.started)
            }
        }
        return ToolResult(.object(json))
    }

    /// Ao liberar o computador: jobs que terminaram sem ninguém consultar entram no log de comandos.
    func flushJobLogs(_ c: ManagedComputer) async throws {
        for (id, meta) in jobs where meta.computer == c.name && !meta.logged {
            guard let outcome = try? await c.backend.execPoll(jobID: id, wait: .zero), !outcome.running else { continue }
            _ = try? await jobResult(id, outcome, c)
        }
    }
}
