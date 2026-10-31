import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings › Computers (03 §14.2, F12): o padrão de "Subagent computers" das sessões novas e o estado do runtime dos computadores.
struct ComputersSettingsView: View {
    let model: SettingsModel
    /// "Use Docker instead" fica recolhido: com o runtime nativo (o padrão) a página não fala de Docker.
    @State private var showAdvanced = false

    private var mode: SubagentComputersMode { model.settings.computers.defaultSubagentMode }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            SettingsBlock(title: "Subagents") {
                SettingsRow(title: "Subagent computers", help: "Default for new sessions. Sessions you already have keep theirs.") {
                    DSSegmented(
                        SubagentComputersMode.allCases.map { .init($0.rawValue, $0.segmentTitle) }, selection: mode.rawValue,
                        action: .settingsComputersDefaultSubagentMode, id: .settings("computers", "defaultSubagentMode"))
                }
                Text(verbatim: mode.explanation)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .id(mode)
                    .transition(.opacity)
                    .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: mode)
                SettingsRow(title: "Subagents run as", help: "Default for new sessions.") {
                    DSSegmented(
                        SubagentHarness.allCases.map { .init($0.rawValue, LocalizedStringKey($0.segmentTitle)) },
                        selection: model.settings.computers.defaultSubagentHarness.rawValue,
                        action: .settingsComputersDefaultSubagentHarness, id: .settings("computers", "defaultSubagentHarness"))
                }
                Text(verbatim: model.settings.computers.defaultSubagentHarness.explanation)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .id(model.settings.computers.defaultSubagentHarness)
                    .transition(.opacity)
                SettingsRow(
                    title: "Git from computers",
                    help: "Clone the session's repo, push feat/ branches and open PRs from the computer. Uses your gh login; the token stays out of it."
                ) {
                    DSSwitch(
                        isOn: model.settings.computers.githubAccess, action: .settingsComputersGithubAccess,
                        id: .settings("computers", "githubAccess"), ""
                    )
                    .accessibilityLabel(Text("Git from computers", bundle: .module))
                }
            }
            ProxiesSettingsBlock(model: model)
            SettingsBlock(title: "Computer runtime") {
                SettingsRow(title: "Status", help: usesNativeRuntime
                    ? "Each computer is a small virtual machine on this Mac. The first one downloads the runtime (about 470 MB), once."
                    : "Computers run in containers. The first one builds its images in the background.") {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: model.dockerStatus.text)
                            .dsFont(DS.Font.small)
                            .foregroundStyle(model.dockerStatus.stopped ? DS.Color.warning : DS.Color.textSecondary)
                            .lineLimit(1)
                        if model.dockerStatus.stopped {
                            DSButton(.dockerStart, id: .settings("computers", "openDocker"), "Open Docker", variant: .outline)
                        }
                    }
                }
                if model.runtimeInfo.nativeAvailable {
                    if showAdvanced || model.settings.computers.forceDocker {
                        SettingsRow(
                            title: "Use Docker instead",
                            help: "Run computers in Docker containers instead of the built-in runtime. Applies to the next computers you reserve."
                        ) {
                            DSSwitch(
                                isOn: model.settings.computers.forceDocker, action: .settingsComputersForceDocker,
                                id: .settings("computers", "forceDocker"), ""
                            )
                            .accessibilityLabel(Text("Use Docker instead", bundle: .module))
                        }
                    } else {
                        // lint-ui: allow buttons revela a opção avançada na própria página (apresentação); a troca em si é uma ação do registro
                        Button { showAdvanced = true } label: {
                            Text("Show advanced options", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                } else if let reason = model.runtimeInfo.unavailableReason {
                    Text(verbatim: reason)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }

    /// O runtime nativo está em uso (serve a este Mac e o usuário não forçou o Docker).
    private var usesNativeRuntime: Bool { model.runtimeInfo.nativeAvailable && !model.settings.computers.forceDocker }
}

/// O runtime nativo (sem Docker) serve a este Mac? Alimentado na abertura do app; `unavailableReason` explica o porquê quando não.
struct ComputerRuntimeInfo: Equatable {
    var nativeAvailable = false
    var unavailableReason: String?
}

/// O que o Settings mostra do runtime e das imagens do computador (alimentado pelo orquestrador).
struct DockerStatusInfo: Equatable {
    var text = String(localized: "Starts when a subagent needs a computer.", bundle: .module)
    var stopped = false
}
