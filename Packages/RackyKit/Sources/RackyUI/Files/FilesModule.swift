import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Módulo Files do painel direito (10-right-panel §2): árvore do diretório da sessão e visualizador de código.
@MainActor
final class FilesModule: RightPanelModule {
    let id = PanelModuleID.files
    let title = String(localized: "Files", bundle: .module)
    let icon = "folder"
    let toggleAction: ActionID? = .rightPanelToggleFiles
    let stripButtonID: A11yID? = .tabsFilesToggle
    let controller: FilesController

    init(controller: FilesController) { self.controller = controller }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(FilesPanelView(controller: controller, compact: context.isCompact))
    }

    func makeHeaderAccessory(context: RightPanelModuleContext) -> AnyView? {
        AnyView(FilesChip(controller: controller, compact: context.isCompact))
    }
}

/// Chip do header: "Following Claude" enquanto o módulo acompanha o terminal focado; clicar fixa a pasta ("Pinned") e de novo solta.
struct FilesChip: View {
    let controller: FilesController
    let compact: Bool

    private enum Metrics {
        static let height: CGFloat = 20
        static let icon: CGFloat = 10
    }

    var body: some View {
        if controller.resolution.mode != .none {
            let pinned = controller.isPinned
            ActionButton(.filesTogglePin, id: .rightPanelFilesChip, tooltip: tooltip(pinned: pinned)) {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: pinned ? "pin.fill" : "location.fill")
                        .font(.system(size: Metrics.icon, weight: .medium))
                        .foregroundStyle(pinned ? DS.Color.warning : DS.Color.locate)
                        .symbolEffect(.bounce, options: .nonRepeating, value: MotionPolicy.shared.reduceMotion ? 0 : controller.rootEpoch)
                    if !compact {
                        Text(verbatim: label(pinned: pinned))
                            .font(DS.Font.small.font)
                            .foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, DS.Space.s1_5)
                .frame(height: Metrics.height)
                .background(Capsule().fill(pinned ? DS.Color.fg10 : DS.Color.fg6))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label(pinned: pinned)))
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: pinned)
        }
    }

    private func label(pinned: Bool) -> String {
        if pinned { return String(localized: "Pinned", bundle: .module) }
        if case .following(let agent?) = controller.resolution.mode { return String(localized: "Following \(agent)", bundle: .module) }
        return String(localized: "Following session", bundle: .module)
    }

    private func tooltip(pinned: Bool) -> String {
        pinned
            ? String(localized: "Pinned to this folder. Click to follow the terminal again.", bundle: .module)
            : String(localized: "Following the focused terminal's folder. Click to pin this folder.", bundle: .module)
    }
}
