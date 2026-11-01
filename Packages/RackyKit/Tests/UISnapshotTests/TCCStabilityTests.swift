import Foundation
import Testing
import UserNotifications

@testable import RackyUI

/// AC-T18 (08 AR-530/AR-534): nenhum prompt do sistema em uso normal. O que dá para travar por teste: o código só LÊ permissões
/// (Gravação de Tela, notificações) e as únicas leituras do Keychain são as conhecidas. A parte manual (instalar nova build com
/// `install.sh` e ver que nada reaparece) foi feito à mão pelo dono.
@Suite struct TCCStabilityTests {
    /// Raiz de `Packages/RackyKit/Sources`, a partir deste arquivo.
    private static let sources: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    private static func swiftFiles() -> [(path: String, text: String)] {
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.path.replacingOccurrences(of: sources.path + "/", with: ""), (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return out
    }

    private static func users(of needle: String) -> Set<String> {
        Set(swiftFiles().filter { file in
            file.text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(needle)
            }
        }.map { ($0.path as NSString).lastPathComponent })
    }

    @Test func onlyTheSettingsButtonAsksForNotificationPermission() {
        // `requestAuthorization(` só existe no protocolo, no centro do sistema e na chamada do botão Allow do Settings.
        #expect(Self.users(of: "requestAuthorization(") == ["SystemNotifications.swift", "SystemNotificationCenter.swift", "SettingsModel.swift"])
        #expect(Self.users(of: "requestAuthorization(options").isSubset(of: ["SystemNotificationCenter.swift"]))
    }

    @Test func notificationPolicyOnlyReadsGrantedStatus() {
        #expect(NotificationPromptPolicy.canDeliver(.authorized) && NotificationPromptPolicy.canDeliver(.provisional))
        #expect(!NotificationPromptPolicy.canDeliver(.notDetermined) && !NotificationPromptPolicy.canDeliver(.denied))
    }

    @Test func keychainReadsAreTheKnownOnes() {
        // Cofre (item mestre do próprio app).
        #expect(Self.users(of: "SecItemCopyMatching(") == ["MasterKeyBackend.swift"])
        // Limites do Claude: o item do Claude Code é lido por `/usr/bin/security` (já está na ACL do item), nunca por SecItem.
        let limits = Self.swiftFiles().first { $0.path.hasSuffix("ClaudeLimitsClient.swift") }?.text ?? ""
        #expect(limits.contains("/usr/bin/security") && !limits.contains("SecItemCopy") && !limits.contains("kSecClass"))
    }

    @Test func noAccessibilityAppleEventsOrEventTaps() {
        for needle in ["AXIsProcessTrusted", "AXUIElement", "CGEventTapCreate", "NSAppleScript", "NSAppleEventDescriptor(", "AVCaptureDevice", "CNContactStore", "PHPhotoLibrary"] {
            #expect(Self.users(of: needle).subtracting(["AppLifecycleCoordinator.swift"]).isEmpty, "\(needle) pediria permissão do sistema")
        }
    }

    /// AC-T19: a UI do modo leve não promete isolamento do agente no Mac (palavras "isolated" e "sandboxed").
    @Test func lightModeUIDoesNotClaimIsolation() throws {
        let catalog = Self.sources.appendingPathComponent("RackyUI/Resources/Localizable.xcstrings")
        let text = try String(contentsOf: catalog, encoding: .utf8).lowercased()
        #expect(!text.contains("sandbox"))
        // "isolated" só pode aparecer ligado ao container do modo isolado (v1.1), nunca ao agente no Mac.
        let hits = text.components(separatedBy: "\n").filter { $0.contains("isolated") && $0.contains("\"") }
        #expect(hits.allSatisfy { $0.contains("container") }, "texto promete isolamento: \(hits)")
    }
}
