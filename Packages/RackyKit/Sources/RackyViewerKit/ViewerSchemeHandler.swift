import Foundation
import WebKit

/// Esquema local que serve o noVNC vendorizado e o `viewer.*` (T8, 07 CS-401): o WKWebView do viewer nunca fala com a internet.
public enum ViewerScheme {
    public static let name = "racky-viewer"
    public static let pageURL = URL(string: "\(name)://app/viewer.html")!

    /// Pasta com os arquivos servidos (dentro do bundle de recursos do módulo).
    public static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Viewer", isDirectory: true)
    }

    /// Resolve um caminho do esquema para um arquivo dentro de `root`, sem sair dela (`..`, links simbólicos, caminho absoluto).
    public static func resolve(path: String, root: URL = ViewerScheme.root) -> URL? {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty, !relative.contains("\0") else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path.hasPrefix(base + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return candidate
    }

    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"  // scripts de módulo exigem um tipo JavaScript
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

/// Só entrega arquivos de `ViewerScheme.root`; qualquer outra coisa é 404.
final class ViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL = ViewerScheme.root) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == ViewerScheme.name, url.host == "app",
              let file = ViewerScheme.resolve(path: url.path, root: root), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": ViewerScheme.mimeType(for: file), "Content-Length": "\(data.count)", "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
