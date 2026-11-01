import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings › Notifications (03 §14.2, 06 §3.5): permissão do sistema, um switch por tipo, supressão com o pane visível, som,
/// badge do Dock e "Send Test Notification". O app só pede a permissão quando o usuário aperta `Allow Notifications`.
struct NotificationsSettingsView: View {
    let model: SettingsModel

    private var prefs: AppSettings.Notifications { model.settings.notifications }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            if model.notificationAuthorization != .authorized { permissionCard }
            SettingsBlock(title: "Alerts") {
                switchRow("Agent needs input", help: "A question or a permission request.", key: "needsInput", isOn: prefs.needsInput, action: .settingsNotificationsNeedsInput)
                switchRow("Agent finished", help: "A turn ended and the agent is waiting for you.", key: "finished", isOn: prefs.finished, action: .settingsNotificationsFinished)
                switchRow("Agent failed", help: "A turn failed or the agent exited with an error.", key: "failed", isOn: prefs.failed, action: .settingsNotificationsFailed)
                switchRow("Terminal bell", help: "A terminal you aren't looking at rang the bell.", key: "terminalBell", isOn: prefs.terminalBell, action: .settingsNotificationsTerminalBell)
            }
            SettingsBlock(title: "Behavior") {
                switchRow(
                    "Suppress when the session is visible", help: "No alert while Racky is in front and the pane is on screen.",
                    key: "suppressWhenVisible", isOn: prefs.suppressWhenVisible, action: .settingsNotificationsSuppressWhenVisible)
                SettingsRow(title: "Sound", help: "Played for alerts that need you.") {
                    DSSegmented(
                        [.init("system", "System"), .init("none", "None")], selection: prefs.sound.rawValue,
                        action: .settingsNotificationsSound, id: .settings("notifications", "sound"))
                }
                switchRow("Dock badge", help: "Shows how many agents need you on the Dock icon.", key: "dockBadge", isOn: prefs.dockBadge, action: .settingsNotificationsDockBadge)
            }
            SettingsBlock(title: nil) {
                SettingsRow(title: "Send Test Notification", help: "Check that alerts reach you.") {
                    DSButton(.settingsTestNotification, id: .settings("notifications", "test"), "Send Test Notification", variant: .outline)
                }
            }
        }
    }

    private var permissionCard: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text("Notifications are off for Racky.", bundle: .module)
                    .dsFont(DS.Font.label)
                    .fontWeight(.medium)
                    .foregroundStyle(DS.Color.textPrimary)
                Text(
                    model.notificationAuthorization == .denied
                        ? "Allow them in System Settings to hear when an agent needs you."
                        : "Allow them to hear when an agent needs you. macOS asks once.",
                    bundle: .module
                )
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s2)
            if model.notificationAuthorization == .denied {
                DSButton(.appOpenSystemSettings, id: .settings("notifications", "openSystemSettings"), "Open System Settings", variant: .outline, argument: .select("notifications"))
            } else {
                DSButton(.notificationsRequest, id: .settings("notifications", "allow"), "Allow Notifications", variant: .primary)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.warningBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.warningBorder, lineWidth: DSMetrics.hairline))
        .a11y(.settings("notifications", "permission"), kind: "container", label: "Notifications are off for Racky.")
    }

    private func switchRow(_ title: LocalizedStringKey, help: LocalizedStringKey?, key: String, isOn: Bool, action: ActionID) -> some View {
        SettingsRow(title: title, help: help) {
            DSSwitch(isOn: isOn, action: action, id: .settings("notifications", key), "")
                .accessibilityLabel(Text(title, bundle: .module))
        }
    }
}
