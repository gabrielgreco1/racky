import Foundation

/// O que o lançamento de um agente produz para um CLI: arquivos no diretório do lançamento (`AB/run/launch/<runID>/…`) e,
/// para o Claude Code, a definição de `--agents`. Nada é escrito em `~/.claude`, `~/.codex` nem `~/.config/opencode`.
public struct AgentLaunchArtifacts: Sendable, Equatable {
    public var client: LibraryClient
    public var files: [LaunchFile]
    public var claudeAgents: [String: [String: LibraryJSON]]
}

public enum AgentCLIGenerator {
    /// Prompt final: instruções, jeito de falar, anexos fixos e o índice curto da memória. Valores de variáveis nunca entram aqui
    /// (só os nomes, para o agente saber o que existe no computador).
    public static func prompt(
        for agent: AgentDefinition, attachments: AgentAttachmentManifest = AgentAttachmentManifest(), memoryIndex: String = "",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var parts = [agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        let tone = agent.tone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tone.isEmpty { parts.append("Voice and tone for summaries and the diary: \(tone)") }
        let att = attachments.promptSection(fileExists: fileExists)
        if !att.isEmpty { parts.append(att) }
        if !agent.variables.isEmpty {
            parts.append("Environment variables set in your computer (values are not shown): " + agent.variables.map(\.envName).sorted().joined(separator: ", "))
        }
        let mem = memoryIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mem.isEmpty {
            parts.append("Memory index (use memory_search and memory_read for details):\n\(mem)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func generate(
        _ agent: AgentDefinition, for client: LibraryClient, attachments: AgentAttachmentManifest = AgentAttachmentManifest(), memoryIndex: String = "",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AgentLaunchArtifacts {
        let body = prompt(for: agent, attachments: attachments, memoryIndex: memoryIndex, fileExists: fileExists)
        let safe = agent.name
        switch client {
        case .claude:
            var def: [String: LibraryJSON] = ["description": .string(agent.description), "prompt": .string(body)]
            if !agent.tools.isEmpty { def["tools"] = .strings(agent.tools) }
            if let m = agent.model, !m.isEmpty { def["model"] = .string(m) }
            if !agent.skills.isEmpty { def["skills"] = .strings(agent.skills) }
            return AgentLaunchArtifacts(client: client, files: [], claudeAgents: [safe: def])
        case .codex:
            var toml = "name = \(tomlString(agent.name))\ndescription = \(tomlString(agent.description))\n"
            if let m = agent.model, !m.isEmpty { toml += "model = \(tomlString(m))\n" }
            toml += "developer_instructions = \"\"\"\n\(escapeMultiline(body))\n\"\"\"\n"
            return AgentLaunchArtifacts(
                client: client, files: [LaunchFile(name: "agents-codex/agents/\(safe).toml", contents: Data(toml.utf8))], claudeAgents: [:])
        case .opencode:
            var md = "---\ndescription: \(AgentStore.quoted(agent.description))\nmode: subagent\n"
            if let m = agent.model, !m.isEmpty { md += "model: \(AgentStore.quoted(m))\n" }
            md += "---\n\n\(body)\n"
            return AgentLaunchArtifacts(
                client: client, files: [LaunchFile(name: "agents-opencode/agent/\(safe).md", contents: Data(md.utf8))], claudeAgents: [:])
        }
    }

    static func tomlString(_ s: String) -> String {
        var o = "\""
        for ch in s {
            switch ch {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            default: o.append(ch)
            }
        }
        return o + "\""
    }

    static func escapeMultiline(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\"")
    }
}
