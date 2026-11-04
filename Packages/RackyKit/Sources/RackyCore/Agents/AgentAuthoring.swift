import RackyPlatform
import Foundation

/// Criar agente ou skill com a ajuda do Claude (backlog 25 h): uma conversa de um lado e um rascunho que se preenche do outro.
/// O Claude responde em texto e termina com um bloco ```draft com o JSON do rascunho inteiro; o app lê o bloco e mostra o resto.
public enum AuthoringKind: String, Sendable { case agent, skill }

public struct AuthoringMessage: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable { case user, assistant }
    public var id = UUID()
    public var role: Role
    public var text: String
    public var fileNames: [String]
    public init(role: Role, text: String, fileNames: [String] = []) { self.role = role; self.text = text; self.fileNames = fileNames }
}

/// Arquivo que o usuário subiu: o texto (quando dá para ler) vai na conversa e o arquivo fica com o agente ou a skill.
public struct AuthoringUpload: Sendable, Equatable, Identifiable {
    public static let maxCharacters = 20_000
    public static let maxTotalCharacters = 80_000
    public var id = UUID()
    public var name: String
    public var path: String
    public var text: String?
    public var truncated: Bool
    public var size: Int

    /// Lê o arquivo; binários (planilha, PDF, imagem) entram só pelo nome.
    public init(url: URL) {
        name = url.lastPathComponent
        path = url.path
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        size = data.count
        if data.count <= 5_000_000, !data.prefix(4096).contains(0), let s = String(data: data, encoding: .utf8) {
            truncated = s.count > Self.maxCharacters
            text = String(s.prefix(Self.maxCharacters))
        } else {
            text = nil
            truncated = false
        }
    }

    public init(name: String, text: String?) {
        self.name = name; path = ""; self.text = text; truncated = false; size = text?.utf8.count ?? 0
    }
}

public struct AuthoringDraft: Sendable, Equatable {
    public var name = ""
    public var description = ""
    /// Instruções do agente, ou o corpo do `SKILL.md`.
    public var instructions = ""
    public var tone = ""
    public var skills: [String] = []
    public var needsComputer = false

    public init() {}

    /// O que o Claude mandou no bloco `draft`: só os campos presentes mudam.
    public mutating func apply(_ patch: [String: Any]) {
        if let v = patch["name"] as? String { name = Self.slug(v) }
        if let v = patch["description"] as? String { description = v }
        if let v = (patch["instructions"] as? String) ?? (patch["body"] as? String) { instructions = v }
        if let v = patch["tone"] as? String { tone = v }
        if let v = patch["skills"] as? [String] { skills = v }
        if let v = patch["computer"] as? Bool { needsComputer = v }
    }

    /// `QA Engineer!` → `qa-engineer`: nome seguro para pasta e arquivo.
    public static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let dashed = lowered.replacingOccurrences(of: "[^a-z0-9._]+", with: "-", options: .regularExpression)
        return String(dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-._")).prefix(64))
    }

    public var json: String {
        let obj: [String: Any] = ["name": name, "description": description, "instructions": instructions, "tone": tone, "skills": skills, "computer": needsComputer]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum AgentAuthoring {
    public static func systemPrompt(for kind: AuthoringKind) -> String {
        let what = kind == .agent
            ? "a Claude Code subagent (a persona with instructions, optional skills and an optional computer)"
            : "a Claude Code skill (a SKILL.md with a short description and step-by-step instructions, plus reference files)"
        let fields = kind == .agent
            ? #"{"name": kebab-case, "description": one sentence on when to use it, "instructions": the full system prompt, "tone": how it talks in summaries, "skills": [skill names], "computer": true only if it needs a browser or its own machine}"#
            : #"{"name": kebab-case, "description": one sentence on when to use it (this is what makes Claude pick the skill), "instructions": the body of SKILL.md, "skills": []}"#
        return """
        You help the user create \(what) inside the app Racky. Be brief: ask at most two short questions at a time, and reply in the user's language.
        Files the user uploads are examples of the result they want: study them and make the instructions reproduce that format every time. Quote nothing long from them.
        After every reply, end with the whole current draft in one fenced block exactly like this, with valid JSON and nothing after it:
        ```draft
        \(fields)
        ```
        Keep fields the user already settled. Never invent secrets, logins or API keys; tell the user to add those as variables.
        """
    }

    /// A conversa inteira como um só prompt (sem sessão no Claude: cada chamada é independente).
    public static func prompt(messages: [AuthoringMessage], uploads: [AuthoringUpload], draft: AuthoringDraft) -> String {
        var out = ["Current draft:\n```draft\n\(draft.json)\n```"]
        var budget = AuthoringUpload.maxTotalCharacters
        for u in uploads {
            if let text = u.text {
                let piece = String(text.prefix(max(0, budget)))
                budget -= piece.count
                out.append("Uploaded file \(u.name)\(u.truncated || piece.count < text.count ? " (cut)" : ""):\n<<<\n\(piece)\n>>>")
            } else {
                out.append("Uploaded file \(u.name) (\(u.size) bytes, not readable as text; it stays attached as is).")
            }
        }
        out.append(messages.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n"))
        out.append("Assistant:")
        return out.joined(separator: "\n\n")
    }

    /// Separa a resposta do bloco `draft`. Sem bloco válido, o texto fica inteiro e o rascunho não muda.
    public static func parse(_ response: String) -> (reply: String, patch: [String: Any]?) {
        guard let open = response.range(of: "```draft", options: .backwards) else { return (response.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let after = response[open.upperBound...]
        let body = after.range(of: "```").map { String(after[..<$0.lowerBound]) } ?? String(after)
        let reply = String(response[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let patch = (try? JSONSerialization.jsonObject(with: Data(body.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any]
        return (reply, patch)
    }
}

public protocol AuthoringRunner: Sendable {
    func complete(system: String, prompt: String) async throws -> String
}

public enum AuthoringError: Error, Equatable, Sendable, CustomStringConvertible {
    case claudeNotFound
    case failed(String)
    public var description: String {
        switch self {
        case .claudeNotFound: "Claude Code isn't installed or isn't on the PATH."
        case .failed(let m): m
        }
    }
}

/// `claude -p` sem ferramentas e sem sessão salva: só texto. A conversa vai pela entrada padrão.
public struct ClaudeCLIAuthoringRunner: AuthoringRunner {
    public var searchPath: String?
    public var override: String?
    public var model: String?
    public init(searchPath: String? = ProcessInfo.processInfo.environment["PATH"], override: String? = nil, model: String? = nil) {
        self.searchPath = searchPath; self.override = override; self.model = model
    }

    public func arguments(system: String) -> [String] {
        var a = ["-p", "--no-session-persistence", "--tools", "", "--system-prompt", system]
        if let model, !model.isEmpty { a += ["--model", model] }
        return a
    }

    public func complete(system: String, prompt: String) async throws -> String {
        guard let path = CLIExecutableResolver.resolve(name: "claude", searchPath: searchPath, override: override) else { throw AuthoringError.claudeNotFound }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-authoring", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try await ProcessRunner.run(ProcessRequest(
            executable: URL(fileURLWithPath: path), arguments: arguments(system: system), currentDirectory: dir, timeout: .seconds(180),
            stdin: Data(prompt.utf8)))
        guard out.exitCode == 0 else {
            let err = String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AuthoringError.failed(err.isEmpty ? "Claude Code exited with code \(out.exitCode)." : String(err.suffix(400)))
        }
        return String(decoding: out.stdout, as: UTF8.self)
    }
}
