import Foundation

/// Sanitização de texto vindo do agente (06 §3.4): sem ANSI nem caracteres de controle, espaços juntos, corte em N caracteres.
public enum HookTextSanitizer {
    public static func sanitize(_ text: String, maxCharacters: Int = HookLimits.lastMessageMaxCharacters) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var lastWasSpace = true  // descarta espaço inicial
        while let s = scalars.next() {
            if s.value == 0x1B {  // ESC
                guard let next = scalars.next() else { break }
                if next == "[" {  // CSI: parâmetros 0x30-0x3F, intermediários 0x20-0x2F, final 0x40-0x7E
                    while let c = scalars.next(), !(0x40...0x7E).contains(c.value) {}
                } else if next == "]" || next == "P" || next == "^" || next == "_" {  // OSC/DCS/PM/APC até BEL ou ST
                    var prevEsc = false
                    while let c = scalars.next() {
                        if c.value == 0x07 { break }
                        if prevEsc && c == "\\" { break }
                        prevEsc = c.value == 0x1B
                    }
                } else if (0x20...0x2F).contains(next.value) {  // ESC + intermediários + final
                    while let c = scalars.next(), (0x20...0x2F).contains(c.value) {}
                }
                continue
            }
            let isSpace = s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{000B}" || s == "\u{000C}" || s == "\u{00A0}"
                || s == "\u{2028}" || s == "\u{2029}"
            if isSpace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            if s.value < 0x20 || (0x7F...0x9F).contains(s.value) { continue }  // C0, DEL, C1
            out.append(s)
            lastWasSpace = false
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return truncate(result, maxCharacters: maxCharacters)
    }

    /// Corta em no máximo `maxCharacters` pontos de código (é o que `length()` do SQLite conta) sem partir um grafema.
    public static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.unicodeScalars.count > maxCharacters else { return text }
        var used = 0
        var out = ""
        for ch in text {
            let n = ch.unicodeScalars.count
            if used + n > maxCharacters { break }
            out.append(ch)
            used += n
        }
        return out
    }
}

/// Reduz o JSON bruto do stdin do hook aos campos de 06 §3.3. Roda no helper (o app nunca vê `tool_response` nem o prompt).
public enum HookPayloadReducer {
    public static let targetMaxCharacters = 160
    public static let fieldMaxCharacters = 300

    public static func reduce(_ raw: Data) -> ReducedHookPayload {
        guard !raw.isEmpty, let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return ReducedHookPayload()
        }
        return reduce(object)
    }

    public static func reduce(_ o: [String: Any]) -> ReducedHookPayload {
        var p = ReducedHookPayload()
        p.sessionID = id(o["session_id"])
        p.transcriptPath = text(o["transcript_path"], max: 1024, collapse: false)
        p.cwd = text(o["cwd"], max: 1024, collapse: false)
        p.source = id(o["source"])
        p.toolName = id(o["tool_name"])
        p.toolUseID = id(o["tool_use_id"])
        p.agentID = id(o["agent_id"])
        p.agentType = id(o["agent_type"])
        p.turnID = id(o["turn_id"])
        p.model = id(o["model"])
        p.reason = text(o["reason"], max: fieldMaxCharacters)
        p.notificationType = id(o["notification_type"])
        p.message = text(o["message"], max: HookLimits.lastMessageMaxCharacters)
        p.lastAssistantMessage = text(o["last_assistant_message"], max: HookLimits.lastMessageMaxCharacters)
        p.error = errorText(o)
        if let server = o["mcp_server"] as? [String: Any] { p.mcpServer = id(server["name"]) }
        if let input = o["tool_input"] as? [String: Any] { p.toolTarget = target(tool: p.toolName, input: input) }
        return p
    }

    /// Alvo curto: comando para shell, nome do arquivo para ferramentas de arquivo, URL, padrão de busca.
    static func target(tool: String?, input: [String: Any]) -> String? {
        func s(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let name = tool ?? ""
        if let command = s("command") { return clip(command) }
        if let path = s("file_path") ?? s("notebook_path") ?? s("path") {
            let base = (path as NSString).lastPathComponent
            return clip(base.isEmpty ? path : base)
        }
        if let url = s("url") { return clip(url) }
        if let pattern = s("pattern") ?? s("query") { return clip(pattern) }
        if name == "Agent" || name == "Task", let d = s("description") ?? s("subagent_type") { return clip(d) }
        // Parar uma tarefa em segundo plano: o id é o do subagente (o Claude Code não manda `SubagentStop` nesse caso).
        if name == "TaskStop" || name == "KillShell" || name == "KillBash", let id = s("task_id") ?? s("shell_id") { return clip(id) }
        return nil
    }

    private static func clip(_ s: String) -> String? {
        let clean = HookTextSanitizer.sanitize(s, maxCharacters: targetMaxCharacters)
        return clean.isEmpty ? nil : clean
    }

    /// Identificador curto (sem controle, até 128 caracteres).
    private static func id(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        let clean = HookTextSanitizer.sanitize(s, maxCharacters: 128)
        return clean.isEmpty ? nil : clean
    }

    private static func text(_ any: Any?, max: Int, collapse: Bool = true) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        let clean = collapse ? HookTextSanitizer.sanitize(s, maxCharacters: max) : HookTextSanitizer.truncate(stripControls(s), maxCharacters: max)
        return clean.isEmpty ? nil : clean
    }

    private static func stripControls(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }

    /// `StopFailure`: o nome do campo de erro não está confirmado em fixture; tenta os candidatos conhecidos.
    private static func errorText(_ o: [String: Any]) -> String? {
        for key in ["error", "error_message", "error_type", "stop_reason"] {
            if let s = o[key] as? String, let c = text(s, max: fieldMaxCharacters) { return c }
            if let nested = o[key] as? [String: Any] {
                for inner in ["message", "type", "code"] {
                    if let s = nested[inner] as? String, let c = text(s, max: fieldMaxCharacters) { return c }
                }
            }
        }
        return nil
    }
}
