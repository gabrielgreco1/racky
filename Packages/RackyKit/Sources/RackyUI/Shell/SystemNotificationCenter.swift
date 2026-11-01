import RackyCore
import Foundation
import Synchronization
import UserNotifications

/// Implementação real de `NotificationCentering` (06 §3.5, 03 §9.2): `UNUserNotificationCenter` com delegate.
/// **Nunca** pede autorização por conta própria: `authorization()` só lê o estado e `requestAuthorization()` só roda
/// quando o usuário aperta `Allow Notifications` em Settings › Notifications. Só existe dentro do app com bundle;
/// testes e o modo `RACKY_NOTIFICATIONS=fake` usam `RecordingNotificationCenter`.
// SAFETY: o único estado mutável (`handler`, `installed`) fica atrás de `Mutex`; `UNUserNotificationCenter` é thread-safe.
nonisolated final class SystemNotificationCenter: NSObject, NotificationCentering, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let handler = Mutex<(@Sendable (NotificationTarget) -> Void)?>(nil)
    private let installed = Mutex(false)

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Liga o delegate (necessário para receber o clique mesmo com o app em segundo plano). Não mostra nenhum diálogo.
    func install() {
        let first = installed.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        if first { center.delegate = self }
    }

    func authorization() async -> NotificationAuthorization {
        install()
        return Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        install()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func post(_ notification: SystemNotification) async {
        install()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        content.sound = notification.sound ? .default : nil
        var info = ["terminalID": notification.target.terminalID.uuidString, "sessionID": notification.target.sessionID.uuidString]
        if let batch = notification.target.batchID { info["batchID"] = batch }
        content.userInfo = info
        try? await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func withdraw(terminalID: UUID) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { ($0.request.content.userInfo["terminalID"] as? String) == terminalID.uuidString }.map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    func setOpenHandler(_ handler: @escaping @Sendable (NotificationTarget) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Clique na notificação (M-702): entrega o alvo; quem recebe ativa o app, seleciona sessão e pane, e dá o rim flash.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let terminal = (info["terminalID"] as? String).flatMap(UUID.init(uuidString:)),
              let session = (info["sessionID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let handler = handler.withLock { $0 }
        handler?(NotificationTarget(terminalID: terminal, sessionID: session, batchID: info["batchID"] as? String))
    }

    /// Com o app em primeiro plano o coordenador já decidiu (suprime só se o pane está visível): o que chega aqui é de outra sessão.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
