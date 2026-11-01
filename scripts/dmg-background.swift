// dmg-background.swift - desenha o fundo da janela do DMG (660x400 pt, @2x): ícone do Racky, seta e a instrução de arrastar.
// Uso: swift scripts/dmg-background.swift <saida.png> [App/Racky.icns]
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("uso: dmg-background.swift <saida.png> [icone.icns]\n".utf8)); exit(2) }
let scale: CGFloat = 2
let size = NSSize(width: 660, height: 400)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.90, alpha: 1)])?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Seta entre o app (esquerda, x=170) e Applications (direita, x=490), na altura dos ícones (y=190 do topo => 210 de baixo).
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 260, y: 205)); arrow.line(to: NSPoint(x: 400, y: 205))
arrow.move(to: NSPoint(x: 378, y: 227)); arrow.line(to: NSPoint(x: 402, y: 205)); arrow.line(to: NSPoint(x: 378, y: 183))
NSColor(white: 0.45, alpha: 1).setStroke()
arrow.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
func text(_ s: String, y: CGFloat, size pt: CGFloat, weight: NSFont.Weight, gray: CGFloat) {
    (s as NSString).draw(
        in: NSRect(x: 0, y: y, width: size.width, height: pt * 1.5),
        withAttributes: [.font: NSFont.systemFont(ofSize: pt, weight: weight), .foregroundColor: NSColor(white: gray, alpha: 1), .paragraphStyle: paragraph])
}
text("Drag Racky to Applications", y: 292, size: 22, weight: .semibold, gray: 0.15)
text("First open: System Settings > Privacy & Security > Open Anyway", y: 40, size: 12, weight: .regular, gray: 0.40)

// Ícone pequeno no topo, se o .icns existir.
if args.count >= 3, let icon = NSImage(contentsOfFile: args[2]) {
    icon.draw(in: NSRect(x: size.width / 2 - 28, y: 336, width: 56, height: 56), from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[1]))
