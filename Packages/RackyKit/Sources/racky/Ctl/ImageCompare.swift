import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Comparação de duas imagens (08 AR-808): lado a lado, sobreposição 50% e diferença absoluta.
enum ImageCompare {
    struct Result: Encodable {
        var ok = true
        var width: Int
        var height: Int
        var referenceOriginalWidth: Int
        var referenceOriginalHeight: Int
        var referenceScaled: Bool
        var aspectRatioMismatch: Bool
        /// Média da diferença absoluta por canal, de 0 a 1.
        var meanAbsoluteDifference: Double
        /// Fração de pixels com algum canal diferindo mais de 16/255.
        var differingPixelFraction: Double
        var sideBySide: String
        var overlay50: String
        var difference: String
    }

    enum Failure: Error { case load(String), render, write(String) }

    static func run(appPath: String, referencePath: String, outDir: String, name: String) throws -> Result {
        let app = try load(appPath)
        let ref = try load(referencePath)
        let w = app.width, h = app.height
        let aspectMismatch = abs(Double(ref.width) / Double(ref.height) - Double(w) / Double(h)) > 0.01
        let scaled = ref.width != w || ref.height != h

        let side = try render(width: w * 2 + gap, height: h, fill: gapColor) { ctx in
            ctx.draw(ref, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(app, in: CGRect(x: w + gap, y: 0, width: w, height: h))
        }
        let overlay = try render(width: w, height: h, fill: nil) { ctx in
            ctx.draw(ref, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setAlpha(0.5)
            ctx.draw(app, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let diff = try render(width: w, height: h, fill: CGColor(gray: 0, alpha: 1)) { ctx in
            ctx.draw(app, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setBlendMode(.difference)
            ctx.draw(ref, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let sidePath = "\(outDir)/\(name)-side-by-side.png"
        let overlayPath = "\(outDir)/\(name)-overlay50.png"
        let diffPath = "\(outDir)/\(name)-diff.png"
        try write(side, to: sidePath)
        try write(overlay, to: overlayPath)
        try write(diff, to: diffPath)
        let (mean, fraction) = try metrics(diff)
        return Result(
            width: w, height: h, referenceOriginalWidth: ref.width, referenceOriginalHeight: ref.height,
            referenceScaled: scaled, aspectRatioMismatch: aspectMismatch, meanAbsoluteDifference: mean,
            differingPixelFraction: fraction, sideBySide: sidePath, overlay50: overlayPath, difference: diffPath)
    }

    private static let gap = 16
    private static let gapColor = CGColor(gray: 0.2, alpha: 1)

    private static func load(_ path: String) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw Failure.load(path) }
        return image
    }

    private static func render(width: Int, height: Int, fill: CGColor?, _ draw: (CGContext) -> Void) throws -> CGImage {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.render }
        ctx.interpolationQuality = .high
        if let fill {
            ctx.setFillColor(fill)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        draw(ctx)
        guard let image = ctx.makeImage() else { throw Failure.render }
        return image
    }

    private static func write(_ image: CGImage, to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.write(path) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.write(path) }
    }

    private static func metrics(_ diff: CGImage) throws -> (Double, Double) {
        let w = diff.width, h = diff.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(diff, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.render }
        var sum = 0.0
        var differing = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            sum += Double(r + g + b)
            if max(r, g, b) > 16 { differing += 1 }
        }
        let n = Double(w * h)
        return (sum / (n * 3 * 255), Double(differing) / n)
    }
}
