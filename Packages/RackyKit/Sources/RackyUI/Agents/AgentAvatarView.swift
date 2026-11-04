import RackyCore
import RackyDesignSystem
import AppKit
import SwiftUI

enum AgentMetrics {
    static let sidebarAvatar: CGFloat = 20
    static let pageAvatar: CGFloat = 72
    static let chipAvatar: CGFloat = 16
    static let pickAvatar: CGFloat = 52
    static let pageMaxWidth: CGFloat = 980
    static let columnMin: CGFloat = 320
    static let fieldLabel: CGFloat = 96
    static let chatWidth: CGFloat = 440
    static let memoryBodyHeight: CGFloat = 56
    static let separator: CGFloat = 1
    static let saveLoginWidth: CGFloat = 150
}

/// Rosto do agente: foto enviada ou o SVG gerado pelo nome (`AgentAvatarGenerator`), sempre em círculo.
struct AgentAvatarView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                DS.Color.fg5
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
        .accessibilityHidden(true)
    }
}

/// Imagem do SVG de um nome e uma variação (a escolha de rosto da tela de criar, antes de o agente existir).
enum AgentAvatarImages {
    static func image(name: String, variant: Int) -> NSImage? {
        NSImage(data: Data(AgentAvatarGenerator.svg(name: name, variant: variant).utf8))
    }
}
