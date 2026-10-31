import RackyProtocol
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captura da própria janela (08 AR-806, AR-534, spike S-07).
/// Caminho fiel: ScreenCaptureKit (`desktopIndependentWindow`), que enxerga camadas Metal.
/// Fallback: renderização AppKit da view (não enxerga `CAMetalLayer`), sinalizado em `fidelity`.
@MainActor
enum WindowCapture {
    struct Capture {
        var image: CGImage
        var fidelity: String
        var note: String?
    }

    /// `true` só se o usuário já concedeu a Gravação de Tela a este app. Nunca pede (nem toca no ScreenCaptureKit) sem isso: o pedido
    /// do sistema só aparece por ação explícita do usuário, nunca por um `ctl screenshot` de teste.
    static var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func capture(_ window: NSWindow) async throws -> Capture {
        // Só consulta (nunca pede) a permissão de Gravação de Tela: sem ela, usa o render do AppKit e não abre prompt.
        guard CGPreflightScreenCaptureAccess() else {
            guard let image = viaAppKit(window) else {
                throw CtlError(code: "screenshot_failed", message: "Screen Recording permission is not granted and the AppKit fallback produced no image")
            }
            return Capture(
                image: image, fidelity: "appkit",
                note: "Screen Recording permission not granted (the app never asks); AppKit render does not include Metal layers")
        }
        do {
            return Capture(image: try await viaScreenCaptureKit(window), fidelity: "screencapturekit", note: nil)
        } catch {
            guard let image = viaAppKit(window) else {
                throw CtlError(code: "screenshot_failed", message: "ScreenCaptureKit failed (\(error)) and the AppKit fallback produced no image")
            }
            return Capture(
                image: image, fidelity: "appkit",
                note: "ScreenCaptureKit unavailable (\(error.localizedDescription)); AppKit render does not include Metal layers")
        }
    }

    private static func viaScreenCaptureKit(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let wid = CGWindowID(window.windowNumber)
        guard let target = content.windows.first(where: { $0.windowID == wid }) else {
            throw CtlError(code: "screenshot_failed", message: "window \(wid) not visible to ScreenCaptureKit (minimized or hidden?)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func viaAppKit(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        let frameView = content.superview ?? content
        let scale = window.backingScaleFactor
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(frameView.bounds.width * scale), pixelsHigh: Int(frameView.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = frameView.bounds.size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }

    /// Recorta um retângulo em pontos (origem no topo-esquerdo da área de conteúdo) da imagem da janela.
    static func crop(_ image: CGImage, to rect: CGRect, window: NSWindow) -> CGImage? {
        let scale = Double(image.width) / window.frame.width
        let titlebar = window.frame.height - (window.contentView?.bounds.height ?? window.frame.height)
        let px = CGRect(
            x: rect.minX * scale, y: (rect.minY + titlebar) * scale, width: rect.width * scale, height: rect.height * scale
        ).integral
        return image.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
