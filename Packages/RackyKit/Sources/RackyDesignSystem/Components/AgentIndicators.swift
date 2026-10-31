import RackyProtocol
import SwiftUI

/// Glifo do indicador de estado (02 §2.6 agente, §2.7 processo). Na Fatia 1 (sem hooks) o agente vivo é `unknown`
/// e o resto vem do estado do processo.
public enum DSIndicatorGlyph: Equatable, Sendable {
    case none
    /// `launching`, ignição e linha pendente: spinner neutro.
    case spinner
    /// Agente vivo sem hooks (`unknown`, "Status unavailable"): círculo tracejado âmbar.
    case unknown
    /// Bolinha de estado de processo (`exited`, `failed`, `interrupted`...).
    case dot(DSRGBA)
    /// Falha de criação (linha pendente com erro): `AlertCircle` `destructive`.
    case alert
    /// `working` (02 §2.6): arco de 270° amarelo, 12 passos/s, fase global (M-401).
    case working
    /// `needsInput`: círculo azul cheio com `!` (v5; antes balão `?` laranja, M-402).
    case needsInput
    /// `waitingOnSubagents`: glifo de atividade, estático (M-405).
    case waiting
    /// `done` em tabs, linhas e Inbox: check em círculo esmeralda (M-403). Na coluna do card vira bolinha (`.dot`).
    case done
}

/// Caixa do indicador (02 §2.6): `sm` 10 · `md` 12 · `lg` 16.
public enum DSIndicatorSize: Sendable {
    case sm, md, lg

    public var box: CGFloat {
        switch self {
        case .sm: 10
        case .md: 12
        case .lg: 16
        }
    }
    public var dot: CGFloat {
        switch self {
        case .sm: 6
        case .md: 8
        case .lg: 10
        }
    }
    var stroke: CGFloat { self == .sm ? MotionTokens.Stroke.liveBorder : MotionTokens.Stroke.ring }
}

/// `AgentStateIndicator` (02 §12.5). Não é focável sozinho: o rótulo entra no da linha que o contém.
public struct DSAgentIndicator: View {
    private let glyph: DSIndicatorGlyph
    private let size: DSIndicatorSize

    public init(_ glyph: DSIndicatorGlyph, size: DSIndicatorSize = .md) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        ZStack {
            switch glyph {
            case .none:
                Color.clear
            case .spinner:
                DSSpinner(size: size.box, delayed: false)
            case .unknown:
                Circle()
                    .strokeBorder(DS.Color.agentUnknown, style: StrokeStyle(lineWidth: size.stroke * 0.75, dash: [size.box / 4, size.box / 5]))
                    .frame(width: size.box - size.stroke, height: size.box - size.stroke)
            case .dot(let color):
                Circle().fill(color.color).frame(width: size.dot, height: size.dot)
            case .alert:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: size.box))
                    .foregroundStyle(DS.Color.destructive)
            case .working:
                DSSpinner(kind: .agentWorking, size: size.box, delayed: false)
            case .needsInput:
                // v5: precisa de você = círculo azul cheio com `!` (a única cor de estado do app).
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: size.box, weight: .medium))
                    .foregroundStyle(DS.Color.agentNeedsInput)
            case .waiting:
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size.box, weight: .medium))
                    .foregroundStyle(DS.Color.agentWaitingOnSubagents)
            case .done:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: size.box, weight: .medium))
                    .foregroundStyle(DS.Color.agentDone)
            }
        }
        // M-408: toda troca de glifo é um crossfade de 0,18 s; Reduce Motion usa o crossfade curto da política.
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.disclosure), value: glyph)
        .frame(width: size.box, height: size.box)
        .accessibilityHidden(true)
    }
}

extension DSAgentLogo {
    /// Conveniência para o domínio (sidebar): mapeia `TerminalProvider` para `DSAgentKind`.
    public init(_ provider: TerminalProvider, size: CGFloat = 13, dimmed: Bool = false) {
        let kind: DSAgentKind = switch provider {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .shell, .custom: .shell
        }
        self.init(kind, size: size, dimmed: dimmed)
    }
}
