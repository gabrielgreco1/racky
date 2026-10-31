import RackyProtocol
import Foundation

/// Seção do Settings (03 §14.2). `slice` é a fatia que a entrega: a nav só mostra o que a fatia atual já entregou (AC-T28).
public nonisolated struct SettingsSectionSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    /// Rótulo do grupo na nav (`AGENTS`, `WORKSPACE`...).
    public let group: String
    public let slice: ReleaseSlice

    public init(_ id: String, _ title: String, symbol: String, group: String, slice: ReleaseSlice) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.group = group
        self.slice = slice
    }
}

public enum SettingsCatalog {
    /// Todas as seções de 03 §14.2 na ordem da nav. As das fatias 2 em diante existem aqui só para a flag as esconder;
    /// nenhuma tem conteúdo ainda (`implemented`).
    public static let all: [SettingsSectionSpec] = [
        .init("agents", "Agents", symbol: "sparkles", group: "Agents", slice: .slice1),
        .init("accounts", "Accounts", symbol: "person.crop.circle", group: "Agents", slice: .slice2),
        .init("credentials", "Credentials", symbol: "key", group: "Agents", slice: .slice2),
        .init("general", "General", symbol: "gearshape", group: "Workspace", slice: .slice1),
        .init("github", "GitHub", symbol: "arrow.triangle.branch", group: "Workspace", slice: .slice2),
        .init("import", "Import", symbol: "square.and.arrow.down", group: "Workspace", slice: .slice2),
        .init("docker", "Docker", symbol: "shippingbox", group: "Computers", slice: .slice3),
        .init("computers", "Computers", symbol: "desktopcomputer", group: "Computers", slice: .slice3),
        .init("appearance", "Appearance", symbol: "paintbrush", group: "Interface", slice: .slice2),
        .init("terminal", "Terminal", symbol: "terminal", group: "Interface", slice: .slice1),
        .init("notifications", "Notifications", symbol: "bell", group: "Interface", slice: .slice2),
        .init("shortcuts", "Shortcuts", symbol: "command", group: "Interface", slice: .slice2),
        .init("diagnostics", "Diagnostics", symbol: "stethoscope", group: "System", slice: .slice2),
        .init("advanced", "Advanced", symbol: "slider.horizontal.3", group: "System", slice: .slice2),
    ]

    /// Seções com conteúdo construído (T1-26: General, Agents, Terminal; T2-04: Notifications).
    public static let implemented: Set<String> = ["agents", "general", "terminal", "notifications", "computers", "diagnostics"]

    public static func visible(flags: SliceFlags, among specs: [SettingsSectionSpec] = all, implemented: Set<String> = implemented) -> [SettingsSectionSpec] {
        specs.filter { flags.isEnabled($0.slice) && implemented.contains($0.id) }
    }
}
