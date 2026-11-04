import AppKit
import SwiftTerm

/// Scroll liso no histórico do terminal (backlog 3). O SwiftTerm só desenha linhas inteiras: ele acumula o deslocamento do trackpad
/// e rola uma linha a cada altura de célula. Aqui o mesmo cálculo roda em paralelo e o que sobra (menos de uma linha) vira um
/// deslocamento em pixels da superfície; no fim do gesto o deslocamento volta a zero. Só no histórico local: tela alternativa
/// (vim, less) e programas que pedem o mouse continuam recebendo linhas inteiras.
struct SmoothScrollState: Equatable {
    /// Espelho do acumulador do SwiftTerm (mesma conta: soma, tira linhas inteiras, guarda o resto).
    private(set) var remainder: CGFloat = 0

    /// Aplica um evento de trackpad. Devolve quantas linhas o SwiftTerm vai rolar (positivo = para o histórico).
    mutating func feed(delta: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        remainder += delta
        let lines = Int(remainder / cellHeight)
        remainder -= CGFloat(lines) * cellHeight
        return lines
    }

    mutating func reset() { remainder = 0 }

    /// Deslocamento a desenhar: o resto, exceto contra a borda (no topo do histórico não há linha acima; no fim, nenhuma abaixo).
    func offset(atTop: Bool, atBottom: Bool) -> CGFloat {
        if remainder > 0, atTop { return 0 }
        if remainder < 0, atBottom { return 0 }
        return remainder
    }
}

extension TerminalSurfaceView {
    /// Chamado depois do `super.scrollWheel`: calcula o deslocamento e avisa o host, que move a superfície dentro do recorte.
    func trackSmoothScroll(_ event: NSEvent, before: Double) {
        // A mesma altura de célula que o SwiftTerm calcula (ascent + descent + leading, arredondado para cima).
        let ct = font as CTFont
        let cellHeight = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
        guard event.hasPreciseScrollingDeltas, canScroll, cellHeight > 0 else {
            settleSmoothScroll(animated: false)
            return
        }
        let lines = smoothScroll.feed(delta: event.scrollingDeltaY * scrollSensitivity, cellHeight: cellHeight)
        let after = scrollPosition
        let atTop = after <= 0, atBottom = after >= 1
        // Pediu linhas e nada andou longe da borda: o evento foi para o programa (mouse), não para o histórico.
        if lines != 0, after == before, !(lines > 0 && atTop), !(lines < 0 && atBottom) {
            settleSmoothScroll(animated: false)
            return
        }
        onSmoothOffset?(smoothScroll.offset(atTop: atTop, atBottom: atBottom), false)
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled { settleSmoothScroll(animated: true) }
        if event.phase == .ended || event.phase == .cancelled {
            // Sem inércia vindo, o gesto acabou aqui; com inércia, o `momentumPhase` cancela esta espera.
            smoothSettle?.cancel()
            smoothSettle = DispatchWorkItem { [weak self] in self?.settleSmoothScroll(animated: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: smoothSettle!)
        }
        if event.momentumPhase == .began { smoothSettle?.cancel() }
    }

    func settleSmoothScroll(animated: Bool) {
        smoothSettle?.cancel()
        smoothScroll.reset()
        onSmoothOffset?(0, animated)
    }
}
