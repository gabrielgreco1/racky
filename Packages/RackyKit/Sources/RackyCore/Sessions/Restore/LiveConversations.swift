import RackyPlatform
import Foundation

/// F32: conversas de agente que já têm um processo vivo nesta máquina (`--resume <id>` ou `--session-id <id>` na linha de
/// comando), venha ele de onde vier: deste app, de outra build com os mesmos dados ou de um terminal solto. A retomada
/// automática nunca relança uma dessas, senão a mesma conversa roda duas vezes.
public enum LiveConversations {
    /// IDs que aparecem depois de `--resume`/`--session-id` em `args` (uma linha de comando por elemento).
    public static func ids(inCommandLines lines: [String]) -> Set<String> {
        var found = Set<String>()
        for line in lines {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            for (i, word) in words.enumerated() {
                if (word == "--resume" || word == "--session-id" || word == "-r"), i + 1 < words.count { found.insert(words[i + 1]) }
                for prefix in ["--resume=", "--session-id="] where word.hasPrefix(prefix) { found.insert(String(word.dropFirst(prefix.count))) }
            }
        }
        return found
    }

    /// Linhas de comando de todos os processos do usuário (`ps`). Vazio se `ps` falhar: aí nada é tratado como vivo.
    public static func current() async -> Set<String> {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-x", "-ww", "-o", "args="], timeout: .seconds(5))
        guard let out = try? await ProcessRunner.run(request), out.exitCode == 0 else { return [] }
        return ids(inCommandLines: out.stdoutString.split(separator: "\n").map(String.init))
    }
}
