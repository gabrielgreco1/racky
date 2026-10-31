import RackyDocker
import Foundation
import UniformTypeIdentifiers

extension ComputerToolService {
    /// Mapeia `browser_*` para as operações do runtime (CS-211). Display `http` não tem browser (`not_supported`).
    func browser(_ name: String, _ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        guard await c.display != .http else {
            throw ToolError(.notSupported, "this computer has display http (no browser); use http_request, or a computer with display headless")
        }
        let operation = String(name.dropFirst("browser_".count))
        switch operation {
        case "open": return try await open(args, c)
        case "screenshot": return try await screenshot(args, c)
        case "cookies": return try await cookies(args, c)
        case "download": return try await download(args, c)
        case "upload": return try await upload(args, c)
        default:
            let timeout = min(args.double("timeout_s") ?? 30, 50) + 15
            let out = try await c.backend.runtime(operation, Self.browserArguments(operation, args), timeout: timeout)
            return ToolResult(out)
        }
    }

    /// Argumentos do runtime: os mesmos do schema, mais os padrões que o runtime espera explícitos.
    static func browserArguments(_ operation: String, _ args: Args) -> JSON {
        var values = args.values
        if operation == "eval", values["max_chars"] == nil { values["max_chars"] = 20000 }
        return .object(values)
    }

    func open(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        var values = args.values
        let timeout = min(args.double("timeout_s") ?? 45, 50)
        values["timeout_s"] = .double(timeout)
        // Nenhuma ferramenta passa de 50 s: o assentamento pós-load encolhe para caber.
        values["wait_s"] = .double(min(args.double("wait_s") ?? 4, max(0, 50 - timeout)))
        let before = await Self.lastRecordID(c)
        do {
            let out = try await c.backend.runtime("open", .object(values), timeout: timeout + 20)
            if out["status"]?.int == 403, let blocked = try await blockedRecord(c, after: before, url: args.string("url")) {
                throw Self.blockedError(blocked)
            }
            return ToolResult(out)
        } catch let error as ToolError where error.code == .proxyError || error.code == .timeout {
            // A navegação falhou: se o egress recusou o destino, o motivo está no reqlog (CS-143, CA-106).
            if let blocked = try await blockedRecord(c, after: before, url: args.string("url")) { throw Self.blockedError(blocked) }
            throw error
        }
    }

    func screenshot(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        var out = try await c.backend.runtime("screenshot", args.json, timeout: 60)
        guard let b64 = out["png_b64"]?.string, let png = Data(base64Encoded: b64) else { throw ToolError(.boxRestarted, "the runtime returned no image") }
        var json: [String: JSON] = ["bytes": .int(png.count), "url": out["url"] ?? .null]
        if let saveAs = args.string("save_as") {
            json["file"] = .string(try PathGuard.write(root: c.run.work, saveAs, png))
        }
        out = .object(json)
        return ToolResult(out, image: png)
    }

    func cookies(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let action = args.string("action") ?? ""
        let fileArg = args.string("file")
        if action != "export", fileArg != nil { throw ToolError.invalid("file is only for action export") }
        var runtimeArgs = args.values
        runtimeArgs["file"] = nil
        let out = try await c.backend.runtime("cookies", .object(runtimeArgs), timeout: 30)
        guard action == "export" else { return ToolResult(out) }
        let cookies = out["cookies"]?.array ?? []
        let path = fileArg ?? "/work/cookies.json"
        let data = path.hasSuffix(".txt") ? Self.netscapeJar(cookies) : JSON.array(cookies).data(pretty: true)
        let written = try PathGuard.write(root: c.run.work, path, data)
        return ToolResult(["file": .string(written), "count": .int(cookies.count)])
    }

    /// Cookie jar no formato Netscape (`curl -b`).
    static func netscapeJar(_ cookies: [JSON]) -> Data {
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let domain = cookie["domain"]?.string ?? ""
            let include = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expires = Int(cookie["expires"]?.double ?? 0)
            let fields = [domain, include, cookie["path"]?.string ?? "/", (cookie["secure"]?.bool ?? false) ? "TRUE" : "FALSE",
                          String(max(expires, 0)), cookie["name"]?.string ?? "", cookie["value"]?.string ?? ""]
            lines.append(fields.joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func download(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let timeout = min(args.double("timeout_s") ?? 45, 50)
        var values = args.values
        values["timeout_s"] = .double(timeout)
        let out = try await c.backend.runtime("download", .object(values), timeout: timeout + 20)
        guard let b64 = out["data_b64"]?.string, let data = Data(base64Encoded: b64) else { throw ToolError(.boxRestarted, "the runtime returned no file") }
        let suggested = (out["name"]?.string ?? "download.bin")
        var name = (suggested as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty { name = "download.bin" }
        // Nome único: dois downloads com o mesmo nome não se sobrescrevem.
        var path = "/work/downloads/\(name)"
        var counter = 1
        while PathGuard.exists(root: c.run.work, path) {
            counter += 1
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            path = "/work/downloads/\(stem)-\(counter)" + (ext.isEmpty ? "" : ".\(ext)")
        }
        let file = try PathGuard.write(root: c.run.work, path, data)
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ToolResult(["file": .string(file), "bytes": .int(data.count), "mime": .string(mime)])
    }

    func upload(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let file = args.string("file") ?? ""
        let data = try PathGuard.read(root: c.run.work, file, maxBytes: 24 << 20)  // path_rejected para `..` e symlink
        let name = (try PathGuard.components(file)).last ?? "upload.bin"
        _ = try await c.backend.runtime(
            "upload", ["selector": .string(args.string("selector") ?? ""), "name": .string(name), "data_b64": .string(data.base64EncodedString())], timeout: 60)
        return ToolResult(["uploaded": true])
    }

    // MARK: Classificação de falhas de navegação (reqlog)

    /// Id do último registro do reqlog (para saber o que é posterior à chamada).
    static func lastRecordID(_ c: ManagedComputer) async -> Int {
        ChainedLog.read(c.run.requestsFile).count
    }

    /// Registro `blocked` do egress posterior à chamada cujo host é o do `url`.
    func blockedRecord(_ c: ManagedComputer, after count: Int, url: String?) async throws -> [String: JSON]? {
        guard let url, let host = URL(string: url)?.host else { return nil }
        // O egress grava na hora; o do browser chega logo depois: dá uma folga curta antes de concluir "não foi bloqueio".
        for attempt in 0..<4 {
            let records = ChainedLog.read(c.run.requestsFile).dropFirst(count)
            if let hit = records.last(where: { $0["blocked"]?.bool == true && $0["host"]?.string == host }) { return hit }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        return nil
    }

    static func blockedError(_ record: [String: JSON]) -> ToolError {
        let reason = record["blocked_reason"]?.string ?? "blocked"
        let details: JSON = ["reason": .string(reason), "request_id": record["id"] ?? .null, "host": record["host"] ?? .null]
        // DNS que não resolve não é política: é falha de destino. O resto (SSRF, ruído, allowlist) é política do egress.
        if reason == "dns-failure" { return ToolError(.proxyError, "the destination host does not resolve", details: details) }
        return ToolError(.blockedByPolicy, "blocked by the egress policy: \(reason)", details: details)
    }
}
