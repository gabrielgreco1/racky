import RackyProtocol
import Foundation

/// Uma conversa passada de Claude ou Codex, lida dos transcripts nativos (03 §10.5). Só metadados: nada do texto vai para
/// o banco (AC-205).
public struct ConversationSummary: Identifiable, Sendable, Equatable {
    public var id: String { nativeID }
    public var nativeID: String
    public var provider: TerminalProvider
    /// Primeira mensagem do usuário (uma linha).
    public var title: String
    public var cwd: String?
    public var branch: String?
    public var messageCount: Int
    public var updatedAt: Date
    public var path: String
    public var sizeBytes: Int
    /// Contexto da última volta segundo o `usage` do transcript.
    public var contextTokens: Int?

    public init(
        nativeID: String, provider: TerminalProvider, title: String, cwd: String? = nil, branch: String? = nil, messageCount: Int = 0,
        updatedAt: Date = Date(), path: String = "", sizeBytes: Int = 0, contextTokens: Int? = nil
    ) {
        self.nativeID = nativeID; self.provider = provider; self.title = title; self.cwd = cwd; self.branch = branch
        self.messageCount = messageCount; self.updatedAt = updatedAt; self.path = path; self.sizeBytes = sizeBytes
        self.contextTokens = contextTokens
    }

    public var estimatedTokens: Int { ResumeCost.tokens(contextTokens: contextTokens, transcriptBytes: sizeBytes) }

    /// Linha de comando que retoma a conversa (AC-205).
    public var resumeCommand: String {
        switch provider {
        case .codex: "codex resume \(nativeID)"
        case .opencode: "opencode --session \(nativeID)"
        default: "claude --resume \(nativeID)"
        }
    }
}

public struct ConversationScan: Sendable, Equatable {
    public var conversations: [ConversationSummary] = []
    /// Fontes que existem mas não puderam ser lidas ("Couldn't read Codex sessions.").
    public var unreadable: [TerminalProvider] = []

    public init(conversations: [ConversationSummary] = [], unreadable: [TerminalProvider] = []) {
        self.conversations = conversations
        self.unreadable = unreadable
    }
}

/// Bloco do transcript em leitura (03 §10.5): papel + texto.
public struct TranscriptBlock: Sendable, Equatable, Identifiable {
    public var id: Int
    public var role: String
    public var text: String

    public init(id: Int, role: String, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

/// Índice somente-leitura de `~/.claude/projects` e `~/.codex/sessions`. Nunca grava; os testes apontam para pastas temporárias.
public struct ConversationHistory: Sendable {
    public var claudeProjects: URL
    public var codexSessions: URL

    public init(claudeProjects: URL, codexSessions: URL) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
    }

    public static func standard(home: String = NSHomeDirectory()) -> ConversationHistory {
        let h = URL(fileURLWithPath: home, isDirectory: true)
        return ConversationHistory(
            claudeProjects: h.appendingPathComponent(".claude/projects", isDirectory: true),
            codexSessions: h.appendingPathComponent(".codex/sessions", isDirectory: true))
    }

    static let headBytes = 512 << 10
    static let tailBytes = 256 << 10
    static let countLimitBytes = 32 << 20

    /// Nome da pasta do Claude para um cwd: tudo que não é letra ou dígito vira `-`.
    public static func claudeDirectoryName(forCwd cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// Caminhos equivalentes de um cwd (com e sem links simbólicos, ex.: `/tmp` × `/private/tmp`).
    static func variants(of cwd: String) -> Set<String> {
        func clean(_ p: String) -> String {
            var s = URL(fileURLWithPath: p).standardizedFileURL.path
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return [clean(cwd), clean(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)]
    }

    // MARK: Varredura

    /// Conversas dos `cwds` (`nil` = todas), da mais recente para a mais antiga.
    public func scan(cwds: [String]?, limit: Int = 300) -> ConversationScan {
        let wanted = cwds.map { Set($0.flatMap(Self.variants(of:))) }
        var out = ConversationScan()
        let claude = claudeSummaries(wanted: wanted, limit: limit)
        if claude.unreadable { out.unreadable.append(.claude) }
        let codex = codexSummaries(wanted: wanted, limit: limit)
        if codex.unreadable { out.unreadable.append(.codex) }
        out.conversations = Array((claude.items + codex.items).sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
        return out
    }

    /// Mesma varredura fora do ator principal.
    public func scanAsync(cwds: [String]?, limit: Int = 300) async -> ConversationScan { scan(cwds: cwds, limit: limit) }

    /// O transcript de uma conversa pelo ID nativo (para o custo da retomada). `cwd` acelera a busca do Claude.
    public func locate(nativeID: String, provider: TerminalProvider, cwd: String?) -> ConversationSummary? {
        guard !nativeID.isEmpty, !nativeID.contains("/") else { return nil }
        let fm = FileManager.default
        switch provider {
        case .claude:
            var dirs: [URL] = []
            if let cwd { dirs = Self.variants(of: cwd).map { claudeProjects.appendingPathComponent(Self.claudeDirectoryName(forCwd: $0), isDirectory: true) } }
            if let all = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil) { dirs += all }
            for dir in dirs {
                let file = dir.appendingPathComponent(nativeID + ".jsonl")
                if fm.fileExists(atPath: file.path) { return parseClaude(file, requireTitle: false) }
            }
            return nil
        case .codex:
            for file in codexFiles().map(\.url) where file.lastPathComponent.hasSuffix(nativeID + ".jsonl") {
                return parseCodex(file, requireTitle: false)
            }
            return nil
        default: return nil
        }
    }

    // MARK: Claude

    private func claudeSummaries(wanted: Set<String>?, limit: Int) -> (items: [ConversationSummary], unreadable: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeProjects.path) else { return ([], false) }
        var dirs: [URL] = []
        if let wanted {
            for cwd in wanted {
                let dir = claudeProjects.appendingPathComponent(Self.claudeDirectoryName(forCwd: cwd), isDirectory: true)
                if fm.fileExists(atPath: dir.path), !dirs.contains(dir) { dirs.append(dir) }
            }
        } else {
            guard let all = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil) else { return ([], true) }
            dirs = all
        }
        var files: [(url: URL, mtime: Date)] = []
        for dir in dirs {
            guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in list where url.pathExtension == "jsonl" {
                files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.mtime > $1.mtime }
        var items: [ConversationSummary] = []
        for file in files.prefix(limit * 2) {
            guard let s = parseClaude(file.url, requireTitle: true) else { continue }
            if let wanted, let cwd = s.cwd, wanted.isDisjoint(with: Self.variants(of: cwd)) { continue }
            items.append(s)
            if items.count >= limit { break }
        }
        return (items, false)
    }

    func parseClaude(_ url: URL, requireTitle: Bool) -> ConversationSummary? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        var title = "", branch: String?, cwd: String?
        for object in Self.lines(head: url, bytes: Self.headBytes) {
            if branch == nil, let b = object["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            if cwd == nil, let c = object["cwd"] as? String, !c.isEmpty { cwd = c }
            if title.isEmpty, (object["type"] as? String) == "user", (object["isMeta"] as? Bool) != true,
               let message = object["message"] as? [String: Any], let text = Self.userText(message["content"]) { title = text }
            if !title.isEmpty, branch != nil, cwd != nil { break }
        }
        if requireTitle, title.isEmpty { return nil }
        var context: Int?
        for line in Self.tailData(url, bytes: Self.tailBytes).reversed() {
            guard let u = ClaudeTranscriptParser.parse(line), !u.isSidechain else { continue }
            context = u.counts.input + u.counts.cacheRead + u.counts.cacheWrite
            break
        }
        let count = size <= Self.countLimitBytes ? Self.count(url, needles: [Array("\"type\":\"user\"".utf8), Array("\"type\":\"assistant\"".utf8)]) : 0
        return ConversationSummary(
            nativeID: url.deletingPathExtension().lastPathComponent, provider: .claude, title: title, cwd: cwd, branch: branch,
            messageCount: count, updatedAt: mtime, path: url.path, sizeBytes: size, contextTokens: context)
    }

    // MARK: Codex

    private func codexFiles() -> [(url: URL, mtime: Date)] {
        guard let it = FileManager.default.enumerator(
            at: codexSessions, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var out: [(URL, Date)] = []
        for case let url as URL in it where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            out.append((url, v?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.1 > $1.1 }.map { (url: $0.0, mtime: $0.1) }
    }

    private func codexSummaries(wanted: Set<String>?, limit: Int) -> (items: [ConversationSummary], unreadable: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexSessions.path) else { return ([], false) }
        guard (try? fm.contentsOfDirectory(atPath: codexSessions.path)) != nil else { return ([], true) }
        var items: [ConversationSummary] = []
        for file in codexFiles().prefix(limit * 3) {
            guard let s = parseCodex(file.url, requireTitle: true) else { continue }
            if let wanted {
                guard let cwd = s.cwd, !wanted.isDisjoint(with: Self.variants(of: cwd)) else { continue }
            }
            items.append(s)
            if items.count >= limit { break }
        }
        return (items, false)
    }

    func parseCodex(_ url: URL, requireTitle: Bool) -> ConversationSummary? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        var id: String?, cwd: String?, branch: String?, title = ""
        for object in Self.lines(head: url, bytes: Self.headBytes) {
            let payload = object["payload"] as? [String: Any]
            switch object["type"] as? String {
            case "session_meta":
                id = payload?["id"] as? String
                cwd = payload?["cwd"] as? String
                branch = ((payload?["git"] as? [String: Any])?["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            case "event_msg" where title.isEmpty:
                if (payload?["type"] as? String) == "user_message", let m = payload?["message"] as? String { title = Self.oneLine(m) }
            default: break
            }
            if id != nil, !title.isEmpty { break }
        }
        // Nome do arquivo: rollout-<timestamp>-<uuid>.jsonl (36 caracteres de UUID no fim).
        let stem = url.deletingPathExtension().lastPathComponent
        let nativeID = id ?? (stem.count >= 36 ? String(stem.suffix(36)) : stem)
        if requireTitle, title.isEmpty { return nil }
        var context: Int?
        for line in Self.objects(tail: url, bytes: Self.tailBytes).reversed() {
            guard (line["type"] as? String) == "event_msg", let payload = line["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count", let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any], let n = (last["input_tokens"] as? NSNumber)?.intValue else { continue }
            context = n
            break
        }
        let count = size <= Self.countLimitBytes
            ? Self.count(url, needles: [Array("\"type\":\"user_message\"".utf8), Array("\"type\":\"agent_message\"".utf8)]) : 0
        return ConversationSummary(
            nativeID: nativeID, provider: .codex, title: title, cwd: cwd, branch: branch, messageCount: count, updatedAt: mtime,
            path: url.path, sizeBytes: size, contextTokens: context)
    }

    // MARK: Transcript (leitura)

    public func transcriptAsync(of summary: ConversationSummary) async -> [TranscriptBlock] { transcript(of: summary) }

    /// Mensagens em ordem, no máximo `maxMessages`, cada uma cortada em `maxChars`.
    public func transcript(of summary: ConversationSummary, maxMessages: Int = 400, maxChars: Int = 2_000) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        func add(_ role: String, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, blocks.count < maxMessages else { return }
            blocks.append(TranscriptBlock(id: blocks.count, role: role, text: String(t.prefix(maxChars))))
        }
        guard let handle = FileHandle(forReadingAtPath: summary.path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16 << 20)) ?? Data()
        for raw in data.split(separator: 0x0A) {
            guard blocks.count < maxMessages, let object = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            if summary.provider == .codex {
                let payload = object["payload"] as? [String: Any]
                guard (object["type"] as? String) == "event_msg" else { continue }
                if (payload?["type"] as? String) == "user_message" { add("You", payload?["message"] as? String ?? "") }
                if (payload?["type"] as? String) == "agent_message" { add("Codex", payload?["message"] as? String ?? "") }
                continue
            }
            let message = object["message"] as? [String: Any]
            switch object["type"] as? String {
            case "user" where (object["isMeta"] as? Bool) != true:
                if let t = Self.userText(message?["content"], oneLine: false) { add("You", t) }
            case "assistant":
                for part in (message?["content"] as? [[String: Any]]) ?? [] {
                    switch part["type"] as? String {
                    case "text": add("Claude Code", part["text"] as? String ?? "")
                    case "tool_use": add("Tool · \(part["name"] as? String ?? "tool")", (part["input"] as? [String: Any])?["command"] as? String ?? "")
                    default: break
                    }
                }
            default: break
            }
        }
        return blocks
    }

    // MARK: Leitura de arquivo

    static func oneLine(_ text: String, max: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(max))
    }

    /// Texto da mensagem do usuário (string ou partes `text`); ignora blocos de sistema (`<command-name>…`) e tool_result.
    static func userText(_ content: Any?, oneLine one: Bool = true) -> String? {
        var text: String?
        if let s = content as? String { text = s }
        if let parts = content as? [[String: Any]] {
            text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return one ? oneLine(t) : t
    }

    /// Objetos JSON das linhas completas do início do arquivo.
    static func lines(head url: URL, bytes: Int) -> [[String: Any]] {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if data.count >= bytes, !parts.isEmpty { parts.removeLast() }  // última linha pode estar cortada
        return parts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    /// Objetos JSON das linhas completas do fim do arquivo (a primeira, possivelmente cortada, é descartada).
    static func objects(tail url: URL, bytes: Int) -> [[String: Any]] {
        tailData(url, bytes: bytes).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func tailData(_ url: URL, bytes: Int) -> [Data] {
        guard let h = FileHandle(forReadingAtPath: url.path), let size = try? h.seekToEnd() else { return [] }
        defer { try? h.close() }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if start > 0, !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    /// Linhas que contêm alguma das agulhas e não são metadados (`isMeta`).
    static func count(_ url: URL, needles: [[UInt8]], excluding: [UInt8] = Array("\"isMeta\":true".utf8)) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        var n = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var pos = 0
            while pos < raw.count {
                let end: Int
                if let nl = memchr(base + pos, 0x0A, raw.count - pos) { end = base.distance(to: UnsafeRawPointer(nl)) } else { end = raw.count }
                guard end > pos else { pos = end + 1; continue }
                let isMeta = memmem(base + pos, end - pos, excluding, excluding.count) != nil
                if !isMeta, needles.contains(where: { memmem(base + pos, end - pos, $0, $0.count) != nil }) { n += 1 }
                pos = end + 1
            }
        }
        return n
    }
}
