import AppKit
import Foundation
import WebKit

/// Eventos do viewer (JS -> Swift). `webkit.messageHandlers.viewer.postMessage(...)` em `viewer.js`.
public enum ViewerEvent: Sendable, Equatable {
    case ready
    /// `connecting`, `live` ou `disconnected` (`detail`: `clean`/`dirty`).
    case state(String, detail: String?)
    case stats(fps: Double, frames: Int, silentMs: Int, sinceFrameMs: Int)
    case keyboard(captured: Bool)
    /// Atalho reservado do app pressionado com o teclado capturado: `handback`, `release-keyboard`, `paste` ou `app`.
    case reserved(String)
    /// Clique com o agente no controle (input bloqueado).
    case blockedInput
    /// F28: o humano mexeu no computador (mouse ou teclado, no máximo 1 por segundo).
    case input
    case error(String)
    case desktopName(String)
    /// Navegação ou carga recusada pela política de isolamento (qualquer coisa fora do esquema local).
    case blockedNavigation(String)
    /// Erro de JavaScript dentro da página do viewer (diagnóstico).
    case jsError(String)

    static func parse(_ body: Any) -> ViewerEvent? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "ready": return .ready
        case "state": return (dict["value"] as? String).map { .state($0, detail: dict["detail"] as? String) }
        case "stats":
            func number(_ key: String) -> Double { (dict[key] as? NSNumber)?.doubleValue ?? 0 }
            return .stats(fps: number("fps"), frames: Int(number("frames")), silentMs: Int(number("silentMs")), sinceFrameMs: Int(number("sinceFrameMs")))
        case "keyboard": return .keyboard(captured: (dict["captured"] as? Bool) ?? false)
        case "reserved": return (dict["action"] as? String).map { .reserved($0) }
        case "jserror": return .jsError((dict["detail"] as? String) ?? "")
        case "blocked-input": return .blockedInput
        case "input": return .input
        case "error": return .error((dict["detail"] as? String) ?? "error")
        case "desktopname": return .desktopName((dict["name"] as? String) ?? "")
        default: return nil
        }
    }
}

/// Política de isolamento do WebView (07 CS-401: "noVNC servido localmente, sem internet").
public enum ViewerIsolation {
    /// Só o esquema local do app navega. WebSocket de loopback é regra de conteúdo e CSP, não navegação.
    public static func allowsNavigation(to url: URL?) -> Bool { url?.scheme == ViewerScheme.name && url?.host == "app" }

    /// Bloqueia tudo e libera só o esquema local e `ws://127.0.0.1`.
    static let contentRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^racky-viewer://app/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^ws://127\\\\.0\\\\.0\\\\.1[:/]"},"action":{"type":"ignore-previous-rules"}}]
    """
}

/// `WKWebView` do viewer: reserva ⌘Q, ⌘W e ⇧⌘R para o app quando o teclado está capturado (03 §11.6) e deixa o resto ir ao computador.
final class ViewerWKWebView: WKWebView {
    var keyboardCaptured = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard keyboardCaptured else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let appOwned = (flags == [.command] && ["q", "w", "h", "m"].contains(key)) || (flags == [.command, .shift] && key == "r")
            || (flags == [.command, .control] && key == "f")
        if appOwned { return false }  // vai ao menu do app, nunca ao computador
        return super.performKeyEquivalent(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ComputerViewerWebView?
    init(_ target: ComputerViewerWebView) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = ViewerEvent.parse(message.body) else { return }
        let body = message.body as? [String: Any]
        MainActor.assumeIsolated {
            if let body, body["type"] as? String == "stats" {
                target?.streamInfo = (messages: (body["wsMessages"] as? Int) ?? 0, bytes: (body["wsBytes"] as? Int) ?? 0, hidden: (body["hidden"] as? Bool) ?? false)
            }
            target?.deliver(event)
        }
    }
}

/// Viewer noVNC isolado: armazenamento não persistente, sem janelas novas, sem diálogos, navegação só no esquema local.
@MainActor
public final class ComputerViewerWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let web: ViewerWKWebView
    public var onEvent: (ViewerEvent) -> Void = { _ in }
    public private(set) var isReady = false
    /// Contadores do WebSocket dentro da página (diagnóstico do stream): mensagens, bytes e se o WebKit marcou a página como oculta.
    public internal(set) var streamInfo: (messages: Int, bytes: Int, hidden: Bool) = (0, 0, false)
    private var pending: [String] = []

    public override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(ViewerSchemeHandler(), forURLScheme: ViewerScheme.name)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        web = ViewerWKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        configuration.userContentController.add(WeakMessageHandler(self), name: "viewer")
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        web.frame = bounds
        addSubview(web)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    /// Compila as regras de conteúdo (bloqueia tudo fora do esquema local e do loopback) e só então carrega a página.
    /// Falha fechada: sem as regras a página não carrega.
    public func load() async {
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "racky.viewer.isolation", encodedContentRuleList: ViewerIsolation.contentRules)
            if let list { web.configuration.userContentController.add(list) } else { throw URLError(.cannotParseResponse) }
        } catch {
            deliver(.error("isolation rules failed to compile: \(error.localizedDescription)"))
            return
        }
        web.load(URLRequest(url: ViewerScheme.pageURL))
    }

    func deliver(_ event: ViewerEvent) {
        if case .ready = event {
            isReady = true
            let queued = pending
            pending = []
            for js in queued { run(js) }
        }
        if case .keyboard(let captured) = event { web.keyboardCaptured = captured }
        onEvent(event)
    }

    // MARK: Comandos (Swift -> JS)

    private func run(_ js: String) {
        web.evaluateJavaScript(js) { _, _ in }
    }

    private func command(_ js: String) {
        if isReady { run(js) } else { pending.append(js) }
    }

    public func connect(to url: URL) {
        let escaped = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        command("window.rackyViewer.connect('\(escaped)')")
    }

    public func disconnect() { command("window.rackyViewer.disconnect()") }

    /// Só para testes: derruba o WebSocket do noVNC de forma abrupta (queda de rede).
    public func dropConnectionForTesting() { command("window.rackyViewer.dropForTesting()") }

    /// Humano no controle: mouse e teclado vão ao computador. Sem isso o viewer é só leitura (CS-402).
    public func setInputEnabled(_ enabled: Bool) {
        command("window.rackyViewer.setInputEnabled(\(enabled))")
        if !enabled { web.keyboardCaptured = false }
    }

    public func focusCanvas() {
        window?.makeFirstResponder(web)
        command("window.rackyViewer.focus()")
    }

    /// Solta o teclado (⌘⎋ ou ⌃⌥): o app volta a receber os atalhos.
    public func releaseKeyboard() {
        web.keyboardCaptured = false
        command("window.rackyViewer.release()")
        if window?.firstResponder === web { window?.makeFirstResponder(nil) }
    }

    /// `Paste to Computer`: digita o texto no computador (ação explícita; nunca sincroniza o clipboard).
    public func typeText(_ text: String) async -> Int {
        guard isReady else { return 0 }
        let result = try? await web.callAsyncJavaScript("return await window.rackyViewer.typeText(text)", arguments: ["text": text], contentWorld: .page)
        return (result as? Int) ?? 0
    }

    /// Latência de input medida dentro do WebView (S3): tempo do `mousemove` sintético até o quadro seguinte, em ms.
    public func probeLatency(count: Int, gapMs: Int) async -> [Double] {
        guard isReady else { return [] }
        let result = try? await web.callAsyncJavaScript(
            "return await window.rackyViewer.probeLatency(count, gap)", arguments: ["count": count, "gap": gapMs], contentWorld: .page)
        return (result as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    /// Para o teste de isolamento: executa JS arbitrário e devolve o resultado (nunca usado em produção).
    func evaluateForTesting(_ body: String) async -> Any? {
        try? await web.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }

    /// Estado interno do noVNC (fila de renderização, imagem pendente) para diagnóstico.
    public func debugState() async -> String {
        let value = try? await web.callAsyncJavaScript("return JSON.stringify(window.rackyViewer.debug())", arguments: [:], contentWorld: .page)
        return (value as? String) ?? "{}"
    }

    /// Imagem do WebView (evidência: o canvas do noVNC não aparece na captura AppKit da janela).
    public func snapshotPNG() async -> Data? {
        await withCheckedContinuation { continuation in
            web.takeSnapshot(with: nil) { image, _ in
                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return continuation.resume(returning: nil) }
                continuation.resume(returning: rep.representation(using: .png, properties: [:]))
            }
        }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if ViewerIsolation.allowsNavigation(to: navigationAction.request.url) { return .allow }
        deliver(.blockedNavigation(navigationAction.request.url?.absoluteString ?? "?"))
        return .cancel
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        deliver(.state("disconnected", detail: "process-terminated"))
    }

    public override func layout() {
        super.layout()
        web.frame = bounds
    }
}
