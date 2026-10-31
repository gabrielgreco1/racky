import RackyPlatform
import Foundation
import Testing

@testable import RackyCore

/// Gera a evidência T2-10 contra os dados REAIS do usuário (só leitura). Só roda com `RACKY_EVIDENCE_DIR=<pasta>`.
/// O relatório do catálogo traz só nomes e contagens. Nenhum corpo, caminho de
/// projeto, valor de segredo ou texto de frontmatter é gravado.
@Suite struct T210EvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"] != nil))
    func writeRealDryRuns() async throws {
        let outDir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Catálogo: varredura real (dry-run: sem banco).
        let roots = CatalogRoots.current()
        let scan = await CatalogService.dryRun(roots: roots)
        var md = "# T2-10 catalog dry-run (real user folders, read-only)\n\nOnly names and counts. No file bodies, paths or frontmatter text.\n\n"
        md += "## Sources\n\n| Source | Present | Items | Invalid |\n|---|---|---|---|\n"
        for s in scan.sources where s.present { md += "| `\(s.label)` | yes | \(s.count) | \(s.invalid) |\n" }
        let absent = scan.sources.filter { !$0.present }.map(\.label)
        if !absent.isEmpty { md += "\nAbsent sources: \(absent.map { "`\($0)`" }.joined(separator: ", "))\n" }
        md += "\n## Totals\n\n"
        let kinds = Dictionary(grouping: scan.items, by: { "\($0.source)/\($0.kind)" })
        for key in kinds.keys.sorted() { md += "- \(key): \(kinds[key]!.count)\n" }
        md += "- total items: \(scan.items.count)\n- items with invalid frontmatter/TOML: \(scan.items.filter { $0.parseError != nil }.count)\n"
        md += "- name conflicts (same kind and name, same client): \(scan.conflicts.count)\n- shadowed items: \(scan.items.filter { $0.shadowedBy != nil }.count)\n"
        md += "- agents out of sync between `.md` and `.toml`: \(scan.outOfSync.count)\n"
        md += "\n## Names\n"
        for key in kinds.keys.sorted() {
            md += "\n### \(key) (\(kinds[key]!.count))\n\n" + kinds[key]!.map(\.name).sorted().joined(separator: ", ") + "\n"
        }
        if !scan.conflicts.isEmpty {
            md += "\n## Conflicts\n\n" + scan.conflicts.map { "- \($0.kind) `\($0.name)` (\($0.client)): \($0.shadowedIDs.count) shadowed" }.sorted().joined(separator: "\n") + "\n"
        }
        if !scan.outOfSync.isEmpty { md += "\n## Out of sync with Codex agent\n\n" + scan.outOfSync.joined(separator: ", ") + "\n" }
        let invalid = scan.items.filter { $0.parseError != nil }.map { "\($0.source)/\($0.kind) `\($0.name)`" }.sorted()
        if !invalid.isEmpty { md += "\n## Invalid\n\n" + invalid.joined(separator: "\n") + "\n" }
        try Data(md.utf8).write(to: outDir.appendingPathComponent("catalog-dry-run.md"))
    }
}
