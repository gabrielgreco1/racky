import SwiftUI

// Componentes de exibição (sem ação): badge, keycap, empty state, card de toast (02 §12.4, §12.3, §12.21, §12.19).

public enum DSBadgeVariant: Sendable, CaseIterable {
    case neutral, error, warning, count, countAttention, pill, mono
}

/// Badge (02 §12.4). Sem gradiente, sombra nem emoji. O texto já vem localizado.
public struct DSBadge: View {
    private let text: String
    private let variant: DSBadgeVariant

    public init(_ text: String, variant: DSBadgeVariant = .neutral) {
        self.text = text
        self.variant = variant
    }

    private var colors: (fg: DSRGBA, bg: DSRGBA, border: DSRGBA?) {
        typealias C = DS.ColorSpec
        switch variant {
        case .neutral: return (C.textPrimary.scaled(0.7), C.fg6, C.fg20)
        case .error: return (C.destructive, C.destructiveBackground, C.destructiveBorder)
        case .warning: return (C.warning, C.warningBackground, C.warningBorder)
        case .count: return (C.textSecondary, C.secondary, nil)
        case .countAttention: return (C.textOnPrimary, C.agentNeedsInput, nil)
        case .pill: return (C.textOnPrimary, C.primary, nil)
        case .mono: return (C.textSecondary, C.accent, nil)
        }
    }

    private var isRound: Bool { variant == .count || variant == .countAttention || variant == .pill }

    public var body: some View {
        let c = colors
        HStack(spacing: DS.Space.s0_5) {
            if variant == .error {
                Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s2_5))
            }
            Text(verbatim: text)
                .dsFont(variant == .mono ? DS.Font.monoMicro : (variant == .count || variant == .countAttention ? DS.Font.microNumeric : DS.Font.micro))
                .fontWeight(variant == .count || variant == .countAttention || variant == .pill ? .semibold : .medium)
        }
        .foregroundStyle(c.fg.color)
        .padding(.horizontal, variant == .mono ? DS.Space.s1 : DS.Space.s1_5)
        .frame(minWidth: isRound ? DSMetrics.badgeHeight : nil, minHeight: DSMetrics.badgeHeight, maxHeight: DSMetrics.badgeHeight)
        .background(RoundedRectangle(cornerRadius: isRound ? DS.Radius.full : 4).fill(c.bg.color))
        .overlay {
            if let border = c.border {
                RoundedRectangle(cornerRadius: 4).strokeBorder(border.color, lineWidth: DSMetrics.hairline)
            }
        }
        .fixedSize()
    }
}

/// Uma tecla (02 §12.3): altura 16, raio 4, fundo `secondary`, texto `micro` `textSecondary`.
public struct Keycap: View {
    private let glyph: String

    public init(_ glyph: String) { self.glyph = glyph }

    public var body: some View {
        Text(verbatim: glyph)
            .dsFont(DS.Font.micro)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s1)
            .frame(minWidth: DSMetrics.keycapHeight, minHeight: DSMetrics.keycapHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm - 2).fill(DS.Color.secondary))
            .fixedSize()
    }
}

/// Atalho como teclas separadas, gap 2 ("⌘" "⇧" "D"). Cada caractere vira um `Keycap`.
public struct Keycaps: View {
    private let chord: String

    public init(_ chord: String) { self.chord = chord }

    public var body: some View {
        HStack(spacing: DS.Space.s0_5) {
            ForEach(Array(chord.enumerated()), id: \.offset) { _, ch in Keycap(String(ch)) }
        }
    }
}

/// Estado vazio (02 §12.21): sem ilustração, sem ícone grande. Uma ação opcional em `action`.
public struct DSEmptyState<Action: View>: View {
    private let message: String
    private let page: Bool
    private let action: Action

    public init(_ message: String, page: Bool = false, @ViewBuilder action: () -> Action) {
        self.message = message
        self.page = page
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: DS.Space.s2) {
            Text(verbatim: message)
                .dsFont(page ? DS.Font.body : DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
            action
        }
        .frame(maxWidth: DSMetrics.emptyStateMaxWidth)
        .padding(DS.Space.s4)
        .frame(maxWidth: .infinity)
    }
}

public extension DSEmptyState where Action == EmptyView {
    init(_ message: String, page: Bool = false) {
        self.init(message, page: page) { EmptyView() }
    }
}

public enum DSToastKind: String, Sendable, CaseIterable {
    case success, info, warning, error, progress

    public var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        case .progress: "circle.dotted"
        }
    }
    public var tint: DSRGBA {
        switch self {
        case .success: DS.ColorSpec.success
        case .info, .progress: DS.ColorSpec.textSecondary
        case .warning: DS.ColorSpec.warning
        case .error: DS.ColorSpec.destructive
        }
    }
}

/// Cartão de toast (02 §12.19): `chrome`, borda `white/14`, raio 10, `shadowFloating`, 360 de largura.
/// A ação (botão `ghost xs`) entra por `action`; a barra de tempo linear do Undo por `timeFraction` (1 → 0).
public struct DSToastCard<Action: View>: View {
    private let kind: DSToastKind
    private let title: String
    private let detail: String?
    private let timeFraction: Double?
    private let action: Action

    public init(kind: DSToastKind, title: String, detail: String? = nil, timeFraction: Double? = nil, @ViewBuilder action: () -> Action) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.timeFraction = timeFraction
        self.action = action()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            if kind == .progress {
                DSSpinner(size: DSMetrics.toastIcon, delayed: false)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: DSMetrics.toastIcon))
                    .foregroundStyle(kind.tint.color)
            }
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text(verbatim: title)
                    .dsFont(DS.Font.bodyStrong)
                    .fontWeight(.medium)
                    .foregroundStyle(DS.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(verbatim: detail)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s2)
            action
        }
        .padding(DS.Space.s3)
        .frame(width: DS.Layout.toastWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.chrome))
        .overlay(alignment: .bottomLeading) {
            if let timeFraction {
                let fraction = max(CGFloat.zero, min(CGFloat(1), CGFloat(timeFraction)))
                GeometryReader { proxy in
                    DS.Color.textSecondary.opacity(0.5)
                        .frame(width: proxy.size.width * fraction, height: DSMetrics.hairline)
                }
                .frame(height: DSMetrics.hairline)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong, lineWidth: DSMetrics.hairline))
        .dsShadow(DS.Shadow.floating)
    }
}

public extension DSToastCard where Action == EmptyView {
    init(kind: DSToastKind, title: String, detail: String? = nil, timeFraction: Double? = nil) {
        self.init(kind: kind, title: title, detail: detail, timeFraction: timeFraction) { EmptyView() }
    }
}
