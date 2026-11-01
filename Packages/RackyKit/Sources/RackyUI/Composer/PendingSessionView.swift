import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Centro da janela enquanto uma sessão está sendo criada (03 §2.9, §6.4): a PhaseList com as fases reais e `Cancel`;
/// em erro (M-205) a mensagem e as ações `Try Again` · `Use Existing Branch` · `Create Without Fetching` · `Discard`.
struct PendingSessionView: View {
    let model: SidebarModel

    var body: some View {
        ZStack {
            DS.Color.terminalBackground
            if let id = model.focusedPending, let pending = model.pending(id) {
                if pending.failure != nil {
                    failure(pending)
                } else {
                    progress(pending)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Progresso

    private func progress(_ pending: PendingLaunch) -> AnyView {
        if pending.isClone { return AnyView(cloneProgress(pending)) }
        return AnyView(sessionProgress(pending))
    }

    private func cloneProgress(_ pending: PendingLaunch) -> some View {
        VStack(spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s2) {
                DSSpinner(size: PaneMetrics.phaseGlyph, delayed: false)
                Text(verbatim: pending.name)
                    .dsFont(DS.Font.dialogTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
            }
            Text(verbatim: pending.phaseText)
                .dsFont(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
            DSButton(.sessionCancelLaunch, "Cancel", variant: .ghost, size: .sm, argument: .select(pending.id.uuidString))
        }
    }

    private func sessionProgress(_ pending: PendingLaunch) -> some View {
        let reduce = MotionPolicy.shared.reduceMotion
        let rows: [(PendingLaunch.Phase, Bool)] = pending.history.map { ($0, true) } + [(pending.phase, false)]
        return VStack(spacing: DS.Space.s6) {
            IgnitionLogo(provider: pending.provider)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: DS.Space.s2) {
                        ZStack {
                            if row.1 {
                                DrawnGlyph(kind: .check, color: DS.Color.agentDone)
                            } else {
                                DSSpinner(size: PaneMetrics.phaseGlyph, delayed: false)
                            }
                        }
                        .frame(width: PaneMetrics.phaseGlyph, height: PaneMetrics.phaseGlyph)
                        Text(verbatim: PendingLaunch.text(of: row.0))
                            .dsFont(DS.Font.body)
                            .foregroundStyle(row.1 ? DS.Color.textSecondary : DS.Color.textPrimary)
                            .lineLimit(1)
                    }
                    .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: DS.Space.s1)))
                }
            }
            .frame(minWidth: PaneMetrics.phaseListWidth, alignment: .leading)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: rows.count)
            DSButton(.sessionCancelLaunch, "Cancel", variant: .ghost, size: .sm, argument: .select(pending.id.uuidString))
        }
    }

    // MARK: Erro (M-205)

    private func failure(_ pending: PendingLaunch) -> some View {
        let arg = ActionArgument.select(pending.id.uuidString)
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.destructive)
                Text(verbatim: pending.failure ?? "")
                    .dsFont(DS.Font.dialogTitle)
                    .foregroundStyle(DS.Color.textPrimary)
            }
            if let detail = pending.detail {
                Text(verbatim: detail)
                    .dsFont(DS.Font.monoPane)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer(minLength: 0)
                DSButton(.sessionDiscardPending, "Discard", variant: .ghost, size: .sm, argument: arg)
                if pending.recoveries.contains(where: { if case .useExistingBranch = $0 { true } else { false } }) {
                    DSButton(.sessionUseExistingBranch, "Use Existing Branch", variant: .outline, size: .sm, argument: arg)
                }
                if pending.recoveries.contains(.createWithoutFetching) {
                    DSButton(.sessionCreateWithoutFetch, "Create Without Fetching", variant: .outline, size: .sm, argument: arg)
                }
                DSButton(.sessionRetryLaunch, "Try Again", variant: .primary, size: .sm, argument: arg)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: DS.Layout.dialogWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
    }
}
