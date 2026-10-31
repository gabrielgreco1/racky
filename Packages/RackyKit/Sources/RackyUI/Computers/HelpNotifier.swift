import RackyCore
import AppKit
import Foundation
import UserNotifications

/// Notificação do macOS para um pedido de ajuda de computador (03 §9.2, 07 CS-430, CS-433): uma por `request_id`, sem conteúdo de página.
@MainActor
public protocol HelpNotifying: AnyObject {
    func notify(item: InboxItem, content: HelpNotificationContent)
    /// Pedido de computador do modo Ask (F12): `<sessão> — Claude wants a computer` com Allow e Deny na notificação.
    func notify(approval: ComputerApprovalRequest)
}

extension HelpNotifying {
    public func notify(approval: ComputerApprovalRequest) {}
}

@MainActor
public final class NoopHelpNotifier: HelpNotifying {
    public init() {}
    public func notify(item: InboxItem, content: HelpNotificationContent) {}
}

/// Guarda o que foi entregue (testes de unidade e evidência).
@MainActor
public final class RecordingHelpNotifier: HelpNotifying {
    public private(set) var delivered: [(item: InboxItem, content: HelpNotificationContent)] = []
    public init() {}
    public func notify(item: InboxItem, content: HelpNotificationContent) { delivered.append((item, content)) }
}

/// Política de permissão das notificações (AC-T18): o app só LÊ o estado do sistema; quem pede é o botão `Allow Notifications`
/// (Settings › Notifications). Um pedido de ajuda ou de computador nunca abre o prompt do macOS por conta própria.
public enum NotificationPromptPolicy {
    /// Entrega só com permissão já concedida (inclusive provisória e efêmera).
    public static func canDeliver(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }
}

/// `UNUserNotificationCenter` com delegate: o clique abre o viewer (padrão) ou, na ação `Take Over`, já assume o controle.
@MainActor
public final class SystemHelpNotifier: NSObject, HelpNotifying, UNUserNotificationCenterDelegate {
    nonisolated public static let category = "racky.computer.help"
    nonisolated public static let takeOverAction = "racky.computer.takeOver"
    nonisolated public static let approvalCategory = "racky.computer.approval"
    nonisolated public static let allowAction = "racky.computer.allow"
    nonisolated public static let denyAction = "racky.computer.deny"
    /// Decisão tomada na própria notificação (Allow / Deny).
    public var decide: @MainActor (String, ComputerApprovalDecision) -> Void = { _, _ in }
    private let open: @MainActor (String, Bool) -> Void

    /// `open(computerName, takeOver)` é chamado no clique. Precisa de um app com bundle (não roda em `swift test`).
    public init?(open: @escaping @MainActor (String, Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        self.open = open
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.takeOverAction, title: "Take Over", options: [.foreground])],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.approvalCategory,
                actions: [
                    UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: []),
                    UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive]),
                ],
                intentIdentifiers: []),
        ])
    }

    public func notify(item: InboxItem, content: HelpNotificationContent) {
        let center = UNUserNotificationCenter.current()
        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.sound = .default
        payload.threadIdentifier = content.threadID
        payload.categoryIdentifier = Self.category
        payload.userInfo = ["computer": item.computer, "request": item.id]
        let request = UNNotificationRequest(identifier: "help-\(item.id)", content: payload, trigger: nil)  // id = request_id: uma vez
        Task {
            // Só entrega se o usuário já permitiu; nunca abre o prompt do sistema aqui (AC-T18).
            guard NotificationPromptPolicy.canDeliver(await center.notificationSettings().authorizationStatus) else { return }
            try? await center.add(request)
        }
    }

    public func notify(approval: ComputerApprovalRequest) {
        let center = UNUserNotificationCenter.current()
        let payload = UNMutableNotificationContent()
        payload.title = "\(approval.sessionTitle) — \(approval.kind == .spawn ? "give this subagent a computer?" : "\(approval.agentName) wants a computer")"
        payload.body = approval.kind == .spawn ? (approval.subject ?? "") : "\(approval.computerName) · \(approval.displayLabel) · \(approval.proxyLabel)"
        payload.sound = .default
        payload.threadIdentifier = approval.sessionTitle
        payload.categoryIdentifier = Self.approvalCategory
        payload.userInfo = ["approval": approval.id]
        let request = UNNotificationRequest(identifier: "approval-\(approval.id)", content: payload, trigger: nil)
        Task {
            // Só entrega se o usuário já permitiu; nunca abre o prompt do sistema aqui (AC-T18).
            guard NotificationPromptPolicy.canDeliver(await center.notificationSettings().authorizationStatus) else { return }
            try? await center.add(request)
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let approval = info["approval"] as? String {
            let decision: ComputerApprovalDecision? = switch response.actionIdentifier {
            case Self.allowAction: .allow
            case Self.denyAction: .deny
            default: nil
            }
            Task { @MainActor in
                if let decision { self.decide(approval, decision) } else { NSApp.activate() }
                completionHandler()
            }
            return
        }
        let computer = info["computer"] as? String
        let takeOver = response.actionIdentifier == Self.takeOverAction
        Task { @MainActor in
            if let computer { self.open(computer, takeOver) }
            completionHandler()
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Janela própria do viewer (03 §11, `WindowGroup(for: ComputerID.self)` no desenho; aqui uma `NSWindow`): mesmo layout sem a
/// sidebar, título `<computer> — Racky`, mínimo 640×420.
@MainActor
final class ViewerPopOut: NSObject, NSWindowDelegate {
    let controller: ComputerViewerController
    private let window: NSWindow
    private let onClose: () -> Void

    init(controller: ComputerViewerController, computers: ComputersController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        let content = ChromeHostingView(content: ComputerViewerView(controller: controller, computers: computers))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "\(controller.name) — Racky"
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        window.delegate = self
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// O computador sumiu: fecha a janela (o `windowWillClose` esquece o pop-out e para o viewer).
    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}
