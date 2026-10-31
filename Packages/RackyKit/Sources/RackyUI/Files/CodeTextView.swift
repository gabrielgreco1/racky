import RackyCore
import RackyDesignSystem
import AppKit
import SwiftUI

/// Cores do realce de sintaxe: a paleta do terminal (02 §3), então o código lido no painel combina com o do agente.
enum CodeTheme {
    static func color(for kind: SyntaxKind) -> NSColor {
        let ansi = DS.Terminal.ansi
        switch kind {
        case .comment: return DS.ColorSpec.textSecondary.scaled(0.7).nsColor
        case .string: return ansi[2].nsColor
        case .keyword: return ansi[5].nsColor
        case .number: return ansi[3].nsColor
        case .type: return ansi[6].nsColor
        case .function: return ansi[4].nsColor
        case .key: return ansi[4].nsColor
        case .attribute: return ansi[3].nsColor
        case .heading: return ansi[3].nsColor
        case .tag: return ansi[1].nsColor
        }
    }

    static let text = DS.ColorSpec.textPrimary.scaled(0.92).nsColor
    static let background = DS.ColorSpec.editor.nsColor
    static let gutterBackground = DS.ColorSpec.chrome.nsColor
    static let gutterText = DS.ColorSpec.textQuaternary.nsColor
    static let matchSoft = DS.ColorSpec.warning.scaled(0.28).nsColor
    static let matchCurrent = DS.ColorSpec.warning.scaled(0.75).nsColor
}

/// Texto somente leitura com realce, número de linha e calha de alterações. TextKit 1 (a régua precisa do `NSLayoutManager`),
/// com quebra de linha: o viewer nunca rola na horizontal (03 §1.5).
struct CodeTextView: NSViewRepresentable {
    let text: String
    let spans: [SyntaxSpan]
    let marks: LineChangeMarks
    let version: Int
    let matches: [NSRange]
    let current: Int
    /// Linha (base 1) para onde rolar quando `version` muda (abrir `arquivo:linha` pelo terminal).
    var line: Int?

    func makeNSView(context: Context) -> CodeScrollView { CodeScrollView() }

    func updateNSView(_ view: CodeScrollView, context: Context) {
        view.apply(text: text, spans: spans, version: version)
        view.setMarks(marks)
        view.applyMatches(matches, current: current)
        view.jump(to: line, version: version)
    }
}

@MainActor
final class CodeScrollView: NSScrollView {
    let textView: NSTextView
    private let gutter = LineNumberRuler()
    private var appliedVersion = -1
    private var appliedSpans = 0
    private var appliedMatches: [NSRange] = []
    private var appliedCurrent = -1
    private var appliedJump = -1
    private var boundsObserver: (any NSObjectProtocol)?

    static let lineHeight: CGFloat = 18

    init() {
        let textView = NSTextView(usingTextLayoutManager: false)
        self.textView = textView
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = CodeTheme.background
        textView.textColor = CodeTheme.text
        textView.insertionPointColor = .clear
        textView.selectedTextAttributes = [.backgroundColor: DS.Terminal.selectionBackground.scaled(0.9).nsColor]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = DS.Space.s2
        textView.textContainerInset = NSSize(width: 0, height: DS.Space.s1_5)
        documentView = textView
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = CodeTheme.background
        borderType = .noBorder
        verticalRulerView = gutter
        hasVerticalRuler = true
        rulersVisible = true
        gutter.clientView = textView
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
        }
        setAccessibilityLabel("Code")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    isolated deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    /// Troca o texto só quando a versão muda (a leitura nova), e o realce quando o número de trechos muda.
    func apply(text: String, spans: [SyntaxSpan], version: Int) {
        guard version != appliedVersion || spans.count != appliedSpans else { return }
        let textChanged = version != appliedVersion
        appliedVersion = version
        appliedSpans = spans.count
        let font = DSFonts.monoFont(size: 12, weight: 400)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: CodeTheme.text, .paragraphStyle: paragraph])
        let length = attributed.length
        let bold = DSFonts.monoFont(size: 12, weight: 700)
        for span in spans where NSMaxRange(span.range) <= length {
            attributed.addAttribute(.foregroundColor, value: CodeTheme.color(for: span.kind), range: span.range)
            if span.kind == .heading { attributed.addAttribute(.font, value: bold, range: span.range) }
        }
        let visibleTop = contentView.bounds.origin
        textView.textStorage?.setAttributedString(attributed)
        if textChanged { gutter.setText(text) }
        appliedMatches = []
        appliedCurrent = -1
        // Reler o mesmo arquivo (mudou no disco) mantém a posição de rolagem.
        if !textChanged { contentView.scroll(to: visibleTop) }
        gutter.needsDisplay = true
    }

    func setMarks(_ marks: LineChangeMarks) { gutter.setMarks(marks) }

    /// Rola até a linha (base 1) uma vez por leitura (`version`) e a realça de leve; fora do texto, vai para a última linha.
    func jump(to line: Int?, version: Int) {
        guard let line, line > 0, version != appliedJump, let layoutManager = textView.layoutManager,
            let storage = textView.textStorage, storage.length > 0
        else { return }
        appliedJump = version
        let text = storage.string as NSString
        var range = text.lineRange(for: NSRange(location: 0, length: 0))
        var current = 1
        while current < line, NSMaxRange(range) < text.length {
            range = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            current += 1
        }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        layoutManager.addTemporaryAttribute(.backgroundColor, value: CodeTheme.matchSoft, forCharacterRange: range)
        appliedMatches = []
        appliedCurrent = -1
        layoutManager.ensureLayout(forCharacterRange: range)
        let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: textView.textContainer!)
        let y = max(0, rect.minY + textView.textContainerOrigin.y - contentView.bounds.height / 3)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }

    func applyMatches(_ matches: [NSRange], current: Int) {
        guard matches != appliedMatches || current != appliedCurrent, let layoutManager = textView.layoutManager else { return }
        let length = textView.textStorage?.length ?? 0
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for (index, range) in matches.enumerated() where NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: index == current ? CodeTheme.matchCurrent : CodeTheme.matchSoft, forCharacterRange: range)
        }
        if matches.indices.contains(current), matches.indices.contains(current), NSMaxRange(matches[current]) <= length {
            textView.scrollRangeToVisible(matches[current])
        }
        appliedMatches = matches
        appliedCurrent = current
    }
}

/// Régua de número de linha com a calha de alterações do git (barra verde = adicionada, amarela = alterada, marca vermelha = removida).
@MainActor
final class LineNumberRuler: NSRulerView {
    private var lineStarts: [Int] = [0]
    private var marks = LineChangeMarks.none
    private var digitCount = 3
    private let font = DSFonts.monoFont(size: 10, weight: 400)

    private enum Metrics {
        static let padding = DS.Space.s2
        static let bar = DS.Space.s0_5 + DS.Space.s0_5 / 2
    }

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = thickness(forDigits: digitCount)
        clipsToBounds = true
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    override var isFlipped: Bool { true }

    private func thickness(forDigits digits: Int) -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * width) + Metrics.padding * 2 + Metrics.bar
    }

    func setText(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        if digits != digitCount {
            digitCount = digits
            ruleThickness = thickness(forDigits: digits)
        }
        needsDisplay = true
    }

    func setMarks(_ newMarks: LineChangeMarks) {
        guard newMarks != marks else { return }
        marks = newMarks
        needsDisplay = true
    }

    /// Número da linha (1-based) de um índice UTF-16 que começa uma linha, `nil` se o índice está no meio de uma.
    private func lineNumber(startingAt index: Int) -> Int? {
        var low = 0, high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] == index { return mid + 1 }
            if lineStarts[mid] < index { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer, let scroll = scrollView
        else { return }
        CodeTheme.gutterBackground.setFill()
        bounds.fill()
        DS.ColorSpec.border.nsColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let visible = scroll.contentView.bounds
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeTheme.gutterText]

        func draw(line: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.maxX - Metrics.bar - Metrics.padding - size.width, y: y + (fragment.height - size.height) / 2),
                withAttributes: attributes)
            guard let kind = marks.kind(forLine: line) else { return }
            switch kind {
            case .added:
                DS.ColorSpec.gitAdded.nsColor.setFill()
                NSRect(x: bounds.maxX - Metrics.bar - 1, y: y, width: Metrics.bar, height: fragment.height).fill()
            case .modified:
                DS.ColorSpec.gitModified.nsColor.setFill()
                NSRect(x: bounds.maxX - Metrics.bar - 1, y: y, width: Metrics.bar, height: fragment.height).fill()
            case .deleted:
                DS.ColorSpec.gitDeleted.nsColor.setFill()
                NSRect(x: bounds.maxX - Metrics.padding - Metrics.bar - 1, y: y, width: Metrics.padding + Metrics.bar, height: Metrics.bar).fill()
            }
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let index = layoutManager.characterIndexForGlyph(at: range.location)
            if let line = self.lineNumber(startingAt: index) { draw(line: line, fragment: fragment) }
        }
        // Última linha vazia (texto que termina em \n) vive no fragmento extra.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, extra.maxY + origin.y >= visible.minY, extra.minY + origin.y <= visible.maxY {
            draw(line: lineStarts.count, fragment: extra)
        }
    }
}
