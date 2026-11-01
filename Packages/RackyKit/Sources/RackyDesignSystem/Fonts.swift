import AppKit
import CoreText
import SwiftUI

/// Registro em tempo de execução da Geist Variable (02 §4.1, DS11).
/// O arquivo `Geist[wght].ttf` vem de `scripts/bootstrap.sh --fonts` (versão e SHA-256 em tool-versions.txt)
/// e fica em `Resources/Fonts/` ao lado do `OFL.txt` (SIL OFL 1.1), ambos no bundle do módulo.
/// Sem o arquivo, a UI cai em SF Pro (fallback documentado) em vez de falhar.
/// MainActor: o acessor `Bundle.module` do SwiftPM herda o isolamento padrão do módulo (UI).
@MainActor
public enum DSFonts {
    public static let familyName = DS.Font.uiFamilyName
    public static let fontFileName = "Geist[wght]"
    public static let licenseFileName = "OFL"

    /// Eixo `wght` (tag 'wght').
    static let weightAxisTag: Int = 0x7767_6874

    /// Registra a fonte uma vez por processo. Seguro para chamar de qualquer thread.
    public static let isRegistered: Bool = register()

    /// Garante o registro e devolve se a Geist está disponível.
    @discardableResult
    public static func registerIfNeeded() -> Bool { isRegistered }

    /// Local do `OFL.txt` no bundle (About cita a licença).
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: licenseFileName, withExtension: "txt", subdirectory: "Fonts")
    }

    public static var fontURL: URL? {
        Bundle.module.url(forResource: fontFileName, withExtension: "ttf", subdirectory: "Fonts")
    }

    private static func register() -> Bool {
        guard let url = fontURL else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Já registrada (segunda carga no mesmo processo) conta como disponível.
        return NSFont(name: familyName, size: 12) != nil
    }

    /// `NSFont` da UI: SF Pro do sistema, com o peso interpolado (inclui 450). A Geist era a fonte anterior; desde a identidade v5
    /// (2026-10-27) o Racky usa a fonte do Mac. O arquivo continua no bundle só para quem a pede pelo nome.
    public static func uiFont(size: CGFloat, weight: Double) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: systemWeight(weight))
    }

    /// SF Mono do sistema (terminal, caminhos, IDs).
    public static func monoFont(size: CGFloat, weight: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight(weight))
    }

    /// Mapeia 100...900 para `NSFont.Weight` (interpolando entre os pontos conhecidos).
    public static func systemWeight(_ w: Double) -> NSFont.Weight {
        let table: [(Double, NSFont.Weight)] = [
            (100, .ultraLight), (200, .thin), (300, .light), (400, .regular), (500, .medium),
            (600, .semibold), (700, .bold), (800, .heavy), (900, .black),
        ]
        guard let hi = table.firstIndex(where: { $0.0 >= w }) else { return .black }
        if hi == 0 || table[hi].0 == w { return table[hi].1 }
        let (w0, v0) = table[hi - 1]
        let (w1, v1) = table[hi]
        let f = (w - w0) / (w1 - w0)
        return NSFont.Weight(CGFloat(v0.rawValue) + CGFloat(f) * CGFloat(v1.rawValue - v0.rawValue))
    }
}

nonisolated public enum DSFontFamily: Sendable, Equatable {
    case ui
    case mono
}

/// Estilo tipográfico (02 §4.2). `tracking` em em; `lineHeight` em pt.
nonisolated public struct DSTextStyle: Sendable, Equatable {
    public let name: String
    public let family: DSFontFamily
    public let size: CGFloat
    public let weight: Double
    public let lineHeight: CGFloat
    public let tracking: CGFloat
    public let tabularDigits: Bool

    /// Cache de `NSFont` por estilo: cada `body` do SwiftUI pedia a fonte de novo (descriptor + variação de eixo), o que aparecia
    /// no perfil do app parado com o painel Insights aberto (T2-11). O estilo é imutável, então a fonte também é.
    @MainActor private static var fontCache: [String: NSFont] = [:]

    @MainActor public var nsFont: NSFont {
        let key = "\(family)|\(size)|\(weight)|\(tabularDigits)"
        if let cached = Self.fontCache[key] { return cached }
        let font = makeFont()
        Self.fontCache[key] = font
        return font
    }

    @MainActor private func makeFont() -> NSFont {
        let base = family == .ui
            ? DSFonts.uiFont(size: size, weight: weight)
            : DSFonts.monoFont(size: size, weight: weight)
        guard tabularDigits else { return base }
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: Int(kNumberSpacingType),
            .selectorIdentifier: Int(kMonospacedNumbersSelector),
        ]]
        let desc = base.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    @MainActor public var font: SwiftUI.Font { SwiftUI.Font(nsFont as CTFont) }

    /// Tracking em pontos.
    public var trackingPoints: CGFloat { tracking * size }

    /// Espaço extra de linha para o `lineSpacing` do SwiftUI (line-height do token menos a altura natural da fonte).
    @MainActor public var lineSpacing: CGFloat {
        let f = nsFont
        let natural = f.ascender - f.descender + f.leading
        return max(0, lineHeight - natural)
    }
}
