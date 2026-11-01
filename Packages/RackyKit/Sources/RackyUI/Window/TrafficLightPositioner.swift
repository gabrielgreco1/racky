import RackyDesignSystem
import AppKit

/// Mantém os semáforos nativos em x 16/36/56 e centro y 18 (03 §1.2). Reaplica em resize, tela cheia,
/// mudança de tela/escala e quando o AppKit refaz o layout da titlebar.
@MainActor
final class TrafficLightPositioner {
    private weak var window: NSWindow?
    private var tokens: [any NSObjectProtocol] = []
    private var applying = false

    init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification,
        ]
        for name in names {
            tokens.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
        }
        observeTitlebarViews()
        apply()
    }

    /// O AppKit redefine a geometria da titlebar no próprio layout (`viewDidLayout` da NSTitlebarView):
    /// observamos os quadros dela e dos botões para reaplicar na hora.
    private func observeTitlebarViews() {
        guard let window, let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return }
        var views: [NSView] = [bar]
        if let container = bar.superview { views.append(container) }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = window.standardWindowButton(type) { views.append(b) }
        }
        for v in views {
            v.postsFrameChangedNotifications = true
            tokens.append(
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
        }
    }

    func apply() {
        guard !applying, let window, !window.styleMask.contains(.fullScreen) else { return }
        guard let close = window.standardWindowButton(.closeButton),
            let mini = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let bar = close.superview
        else { return }
        applying = true
        defer { applying = false }
        let height = DS.Layout.titlebarHeight
        if let container = bar.superview, let theme = container.superview {
            let frame = NSRect(x: 0, y: theme.bounds.height - height, width: theme.bounds.width, height: height)
            if container.frame != frame { container.frame = frame }
            let f = NSRect(x: 0, y: 0, width: container.bounds.width, height: height)
            if bar.frame != f { bar.frame = f }
        }
        let origins = WindowGeometry.trafficLightOrigins(buttonSize: close.frame.size, titlebarHeight: bar.bounds.height)
        for (button, origin) in zip([close, mini, zoom], origins) where button.frame.origin != origin {
            button.setFrameOrigin(origin)
        }
    }
}
