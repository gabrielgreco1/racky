import RackyProtocol
import AppKit
import Foundation

/// Implementação de `AutomationSurface` sobre a janela real: árvore do `UIElementStore`,
/// captura e gravação via ScreenCaptureKit (08 AR-806).
@MainActor
public final class WindowAutomation: AutomationSurface {
    private let store: UIElementStore
    private let flags: SliceFlags
    private let fixture: String?
    private let automationEnabled: Bool
    private let recorder = WindowRecorder()

    public init(store: UIElementStore, flags: SliceFlags, fixture: String?, automationEnabled: Bool) {
        self.store = store
        self.flags = flags
        self.fixture = fixture
        self.automationEnabled = automationEnabled
    }

    public func uiTree(root: A11yID?) -> UITreeSnapshot { store.snapshot(root: root) }

    /// Ligado pela janela: `OverlayRouter.blocksTerminalInput`.
    public var inputBlockedProbe: (@MainActor () -> Bool)?

    public func appState(registeredActions: [ActionID]) -> AppStateSnapshot {
        let info = Bundle.main.infoDictionary
        return AppStateSnapshot(
            app: (info?["CFBundleName"] as? String) ?? "Racky",
            version: (info?["CFBundleShortVersionString"] as? String) ?? "dev",
            pid: ProcessInfo.processInfo.processIdentifier,
            slice: flags.current,
            fixture: fixture,
            automation: automationEnabled,
            window: store.windowInfo(),
            registeredActions: registeredActions,
            visibleControls: store.count,
            firstResponder: store.window?.firstResponder.map { r in
                let id = (r as? NSView)?.accessibilityIdentifier() ?? ""
                return id.isEmpty ? String(describing: type(of: r)) : "\(type(of: r)) [\(id)]"
            },
            blocksTerminalInput: inputBlockedProbe?())
    }

    public func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult {
        guard let window = store.window else { throw CtlError(code: "screenshot_failed", message: "the app has no window yet") }
        // Janela aberta em segundo plano pode estar minimizada no Dock: traz de volta sem ativar o app.
        if window.isMiniaturized { window.deminiaturize(nil) }
        if case .window(let size?) = target {
            window.setContentSize(NSSize(width: size.width, height: size.height))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
        }
        var elementFrame: CGRect?
        if case .element(let id) = target {
            guard let f = store.frame(of: id) else {
                throw CtlError(code: "unknown_target", message: "no element with id \(id.rawValue) on screen")
            }
            elementFrame = f
        }
        let capture = try await WindowCapture.capture(window)
        var image = capture.image
        if let rect = elementFrame {
            guard let cropped = WindowCapture.crop(image, to: rect, window: window) else {
                throw CtlError(code: "screenshot_failed", message: "element frame is outside the captured window")
            }
            image = cropped
        }
        guard let png = WindowCapture.png(image) else { throw CtlError(code: "screenshot_failed", message: "PNG encoding failed") }
        return ScreenshotResult(
            fidelity: capture.fidelity, pixelWidth: image.width, pixelHeight: image.height,
            scale: window.backingScaleFactor, note: capture.note, png: png)
    }

    public func record(_ command: RecordingCommand) async throws -> RecordingResult {
        switch command {
        case .start(let out):
            guard let window = store.window else { throw CtlError(code: "recording_failed", message: "the app has no window yet") }
            return try await recorder.start(window: window, outPath: out)
        case .stop:
            return try await recorder.stop()
        }
    }
}
