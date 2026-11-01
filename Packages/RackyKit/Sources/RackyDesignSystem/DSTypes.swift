import AppKit
import SwiftUI

/// Namespace dos tokens (`DS.Color`, `DS.Font`, `DS.Space`, `DS.Radius`, `DS.Shadow`, `DS.Layout`, `DS.Terminal`).
/// Os membros vêm de `Tokens/*.generated.swift` (scripts/gen-tokens.py a partir de `design/tokens/*.json`).
/// Todos os tipos de token são `nonisolated`: o daemon e os testes também os leem (08 AR-402).
nonisolated public enum DS {}

/// Cor em sRGB com alfa. Alfa compõe sobre a superfície; nunca se pré-mistura em hex (02 §2).
nonisolated public struct DSRGBA: Sendable, Equatable {
    /// `0xRRGGBB`.
    public let hex: UInt32
    /// 0...1.
    public let alpha: Double

    public init(hex: UInt32, opacity: Double = 1) {
        self.hex = hex
        self.alpha = opacity
    }

    /// Para valores `#rrggbbaa` de referência: o alfa é o byte / 255.
    public init(hex: UInt32, alphaByte: UInt8) {
        self.hex = hex
        self.alpha = Double(alphaByte) / 255
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// Alfa quantizado em byte (como no CSS `#rrggbbaa`).
    public var alphaByte: Int { Int((alpha * 255).rounded()) }

    public var color: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public var nsColor: AppKit.NSColor {
        AppKit.NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// `#rrggbb` minúsculo (sem alfa).
    public var hexString: String { String(format: "#%06x", hex) }
}

/// Camada de sombra (02 §8). `blur` é o blur CSS; o `radius` do SwiftUI é `blur / 2`.
nonisolated public struct DSShadowLayer: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let blur: Double
    public let colorHex: UInt32
    public let opacity: Double
    /// Sombra interna (CSS `inset`); não existe em `.shadow`, quem desenha usa um traço/gradiente interno.
    public let inset: Bool

    public var radius: Double { blur / 2 }
    public var color: SwiftUI.Color { DSRGBA(hex: colorHex, opacity: opacity).color }
}

nonisolated public struct DSShadow: Sendable, Equatable {
    public let layers: [DSShadowLayer]
}

public extension View {
    /// Aplica só as camadas externas da sombra. As internas (`inset`) ficam a cargo do componente.
    func dsShadow(_ shadow: DSShadow) -> some View {
        shadow.layers.filter { !$0.inset }.reduce(AnyView(self)) { view, layer in
            AnyView(view.shadow(color: layer.color, radius: layer.radius, x: layer.x, y: layer.y))
        }
    }
}
