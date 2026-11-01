import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

/// Contrato de foco e pilha do `OverlayPanelHost` (02 §12.17, AC-T06): foco preso e devolvido, Esc, scrim, pilha de um nível.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct OverlayHostTests {
    final class FakeTerminal: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    struct Rig {
        let env: AppEnvironment
        let controller: MainWindowController
        let window: NSWindow
        let host: OverlayHostingView
        let terminal: FakeTerminal
        let scheduler: ManualScheduler
    }

    /// Política de motion e agendador próprios do roteador: nada de `MotionPolicy.shared` mutável entre suítes em paralelo.
    func rig(instant: Bool = true) async -> Rig {
        let scheduler = ManualScheduler()
        let env = AppEnvironment(environment: ["RACKY_SCREEN": AppEnvironment.overlayDemoFixture])
        let motion = MotionPolicy()
        motion.mode = instant ? .instant : .normal
        env.overlays.motion = motion
        env.overlays.sleep = scheduler.sleep
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1000, height: 700))
        let window = controller.window!
        let terminal = FakeTerminal(frame: NSRect(x: 300, y: 100, width: 300, height: 200))
        window.contentView!.addSubview(terminal, positioned: .below, relativeTo: window.contentView!.subviews.last)
        window.makeFirstResponder(terminal)
        let host = window.contentView!.subviews.compactMap { $0 as? OverlayHostingView }.first!
        return Rig(env: env, controller: controller, window: window, host: host, terminal: terminal, scheduler: scheduler)
    }

    func spec(_ name: String, cancel: ActionID? = nil, dismissOnScrim: @escaping @MainActor () -> Bool = { true }) -> OverlaySpec {
        OverlaySpec(name: name, id: .overlayComposer, cancelAction: cancel, dismissOnScrim: dismissOnScrim, content: { AnyView(Color.clear.frame(width: 200, height: 100)) })
    }

    @Test func focusIsTrappedInTheOverlayAndReturnedToTheOrigin() async {
        let r = await rig()
        defer { r.window.close() }
        #expect(r.window.firstResponder === r.terminal)
        #expect(r.env.overlays.present(spec("a")))
        #expect(r.window.firstResponder === r.host, "o foco vai para o overlay")
        #expect(r.env.overlays.blocksTerminalInput)
        // Tab nunca sai do overlay: o único key view candidato é o próprio host.
        #expect(r.host.nextValidKeyView === r.host && r.host.previousValidKeyView === r.host)
        r.env.overlays.dismiss(.action)
        #expect(r.window.firstResponder === r.terminal, "o terminal volta a receber teclas")
        #expect(!r.env.overlays.blocksTerminalInput)
    }

    @Test func focusReturnsAtTheStartOfTheExitNotAtTheEnd() async {
        let r = await rig(instant: false)
        defer { r.window.close() }
        r.env.overlays.present(spec("a"))
        r.env.overlays.dismiss(.action)
        #expect(r.env.overlays.stack.count == 1, "a saída ainda está animando")
        #expect(r.window.firstResponder === r.terminal, "04 princípio 8: foco devolvido no quadro 0 da saída")
        // A remoção roda em Task com a espera injetada: avança o tempo virtual além da duração de saída, sem sleep real.
        await r.scheduler.waitForSleepers()
        await r.scheduler.advance(by: r.env.overlays.exitWait())
        #expect(r.env.overlays.stack.isEmpty)
    }

    @Test func backgroundHostsRefuseFirstResponderWhileAnOverlayIsOpen() async {
        let r = await rig()
        defer { r.window.close() }
        let hosts = r.window.contentView!.subviews.compactMap { $0 as? ChromeHostingView }
        let nested = r.window.contentView!.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeHostingView }
        let all = hosts + nested
        r.env.overlays.present(spec("a"))
        for v in all { #expect(!v.acceptsFirstResponder) }
        r.env.overlays.dismiss(.action)
    }

    @Test func escapeKeyClosesTheTopOverlay() async {
        let r = await rig()
        defer { r.window.close() }
        r.env.overlays.present(spec("a"))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        r.window.sendEvent(event)
        #expect(!r.env.overlays.isPresenting)
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func escapeRunsTheCancelActionWhenItIsRegistered() async {
        let r = await rig()
        defer { r.window.close() }
        // `composer.cancel` está registrada pelo fixture e fecha o overlay.
        r.env.overlays.present(spec("composer", cancel: .composerCancel))
        r.env.overlays.escapePressed()
        await Task.yield()
        #expect(!r.env.overlays.isPresenting)
    }

    @Test func stackAllowsOneSubOverlayAndPopReturnsToTheParent() async {
        let r = await rig()
        defer { r.window.close() }
        let o = r.env.overlays
        #expect(o.present(spec("parent")))
        #expect(o.present(spec("child")))
        #expect(!o.present(spec("third")), "só um sub-overlay")
        #expect(o.live.count == 2 && o.top?.spec.name == "child")
        o.dismiss(.escape)
        #expect(o.live.count == 1 && o.top?.spec.name == "parent")
        #expect(o.isPresenting)
        #expect(r.window.firstResponder === r.host, "o foco segue no overlay pai")
        o.dismiss(.escape)
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func scrimClickClosesOnlyWhenThereIsNoTypedData() async {
        let r = await rig()
        defer { r.window.close() }
        final class Box { var v = true }
        let hasData = Box()
        r.env.overlays.present(spec("a", dismissOnScrim: { !hasData.v }))
        r.env.overlays.scrimClicked()
        #expect(r.env.overlays.isPresenting, "com dados digitados o clique no scrim é ignorado")
        hasData.v = false
        r.env.overlays.scrimClicked()
        #expect(!r.env.overlays.isPresenting)
    }

    @Test func motionEventsFollowBeginSettledEnd() async {
        let r = await rig()
        defer { r.window.close() }
        r.env.overlays.present(spec("a"))
        r.env.overlays.dismiss(.action)
        #expect(r.env.overlays.events.map(\.name) == ["M-101 begin", "M-101 settled", "M-101 end", "M-102 begin", "M-102 end"])
    }

    @Test func originFrameComesFromTheButtonThatOpenedTheOverlay() async {
        let r = await rig()
        defer { r.window.close() }
        r.env.overlays.present(spec("a"), from: .windowSidebarToggle)
        #expect(r.env.overlays.originActive == .windowSidebarToggle)
        #expect(r.env.overlays.top?.originFrame != nil, "frame do botão lido da árvore de UI")
        r.env.overlays.dismiss(.action)
        #expect(r.env.overlays.originActive == nil)
    }

    @Test func overlayLayerIsAboveEverythingAndPassesClicksThroughWhenEmpty() async {
        let r = await rig()
        defer { r.window.close() }
        let content = r.window.contentView!
        #expect(content.subviews.last === r.host)
        let p = NSPoint(x: 400, y: 200)
        #expect(r.host.hitTest(p) == nil, "sem overlay nem toast, o clique passa para baixo")
        r.env.overlays.present(spec("a"))
        #expect(r.host.hitTest(p) != nil, "com overlay o scrim engole o clique")
    }

    /// Bug real: o toast fechado ainda anima e o `onGeometryChange` regravava o quadro dele; a área ficava morta para sempre (o
    /// header da tabela não respondia a clique nenhum).
    @Test func aDismissedToastNeverKeepsSwallowingClicks() async {
        let r = await rig()
        defer { r.window.close() }
        let content = r.window.contentView!
        let p = NSPoint(x: 400, y: 200)
        let top = CGRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height)
        let id = r.env.toasts.show(kind: .info, title: "Opened beside the agent")
        r.env.toasts.setCardFrame(id, top)
        #expect(r.host.hitTest(p) != nil, "o card visível recebe o clique")
        r.env.toasts.dismiss(id)
        r.env.toasts.setCardFrame(id, top)  // a animação de saída ainda reporta geometria
        #expect(r.env.toasts.cardFrames.isEmpty)
        #expect(r.host.hitTest(p) == nil, "toast fechado não pode deixar uma área sem clique")
    }
}

@MainActor
@Suite(.serialized, .offscreenAppKit) struct ToastCenterTests {
    static func instantMotion() -> MotionPolicy {
        let motion = MotionPolicy()
        motion.mode = .instant
        return motion
    }

    @Test func durationsFollowTheSpec() {
        #expect(ToastCenter.defaultDuration(kind: .info, hasUndo: false) == 4)
        #expect(ToastCenter.defaultDuration(kind: .success, hasUndo: true) == 8)
        #expect(ToastCenter.defaultDuration(kind: .error, hasUndo: false) == 60)
        #expect(ToastCenter.defaultDuration(kind: .progress, hasUndo: false) == nil)
    }

    @Test func showsAtMostThreeAndCollapsesTheRest() {
        let c = ToastCenter()
        c.motion = Self.instantMotion()
        c.announce = { _, _ in }
        for i in 0..<5 { c.show(kind: .info, title: "t\(i)") }
        #expect(c.visible.count == 3 && c.overflow == 2)
        #expect(c.visible.last?.title == "t4")
    }

    @Test func timerDismissesAndHoverPausesIt() async {
        let scheduler = ManualScheduler()
        let c = ToastCenter()
        c.motion = Self.instantMotion()
        c.sleep = scheduler.sleep
        c.announce = { _, _ in }
        let id = c.show(kind: .info, title: "a", duration: 0.15)
        c.pause(id)
        await scheduler.advance(by: 10)
        #expect(c.items.count == 1, "pausado pelo hover")
        c.resume(id)
        await scheduler.waitForSleepers()
        await scheduler.advance(by: 10)
        #expect(c.items.isEmpty)
    }

    @Test func errorsAreAnnouncedAsUrgent() {
        let c = ToastCenter()
        c.motion = Self.instantMotion()
        var heard: [(String, Bool)] = []
        c.announce = { heard.append(($0, $1)) }
        c.show(kind: .error, title: "Couldn't save", detail: "read-only")
        c.show(kind: .info, title: "Copied.")
        #expect(heard[0].0 == "Couldn't save. read-only" && heard[0].1)
        #expect(heard[1].1 == false)
    }
}
