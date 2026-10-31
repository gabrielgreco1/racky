import AppKit
import Testing
@testable import RackyDesignSystem

/// Logos oficiais de agente (02 §2.10): PNGs em `Resources/AgentLogos`, proveniência em `sources.json`.
@MainActor @Suite(.offscreenAppKit) struct AgentLogoTests {
    @Test func officialLogosAreBundledAtBothScales() throws {
        for name in ["claude", "codex", "opencode"] {
            _ = try #require(DSAgentLogoImages.image(named: name), "\(name)@3x.png ausente no bundle")
            for scale in [2, 3] {
                #expect(DSAgentLogoImages.fileURL(name, scale: scale) != nil, "\(name)@\(scale)x.png ausente")
            }
        }
    }

    @Test func provenanceFileTravelsWithTheLogos() throws {
        let url = try #require(DSAgentLogoImages.provenanceURL, "sources.json ausente em Resources/AgentLogos")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Logos identify third-party integrations, not Racky ownership."))
        #expect(text.contains("\"file\": \"claude.png\""))
        #expect(text.contains("\"file\": \"opencode.png\""))
    }
}
