import RackyCore
import RackyProtocol
import Foundation
import Testing

@testable import RackyUI

@MainActor
final class FakeSurface: AutomationSurface {
    var tree = UITreeSnapshot(window: nil, roots: [])
    func uiTree(root: A11yID?) -> UITreeSnapshot { tree }
    func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult {
        ScreenshotResult(fidelity: "appkit", pixelWidth: 1, pixelHeight: 1, scale: 1, png: Data([1]))
    }
    func record(_ command: RecordingCommand) async throws -> RecordingResult { RecordingResult(state: "stopped", path: nil) }
    func appState(registeredActions: [ActionID]) -> AppStateSnapshot {
        AppStateSnapshot(
            app: "t", version: "t", pid: 1, slice: .slice1, fixture: nil, automation: true, window: nil,
            registeredActions: registeredActions, visibleControls: 0)
    }
}

struct Boom: Error {}

@MainActor
final class Flag {
    var on = false
    var count = 0
}

@MainActor
@Suite(.offscreenAppKit) struct ActionRegistryTests {
    private func make(slice: ReleaseSlice = .slice1) -> (ActionRegistry, FakeSurface) {
        let s = FakeSurface()
        return (ActionRegistry(flags: SliceFlags(current: slice), surface: s), s)
    }

    @Test func performRunsTheHandlerAndReturnsItsMessage() async throws {
        let (r, _) = make()
        let calls = Flag()
        try r.register(.sessionNew) { arg in
            calls.count += 1
            return "kind=\(arg.kind.rawValue)"
        }
        let res = try await r.perform(.sessionNew, nil)
        #expect(res.ok && res.actionID == .sessionNew)
        #expect(res.message == "kind=press")
        #expect(calls.count == 1)
        let set = try await r.perform(.sessionNew, .set("x"))
        #expect(set.message == "kind=set")
    }

    @Test func duplicateRegistrationThrows() throws {
        let (r, _) = make()
        try r.register(.appQuit) { _ in nil }
        #expect(throws: ActionRegistryError.duplicate(.appQuit)) { try r.register(.appQuit) { _ in nil } }
    }

    @Test func unregisteredActionIsReportedNotSilentlyIgnored() async {
        let (r, _) = make()
        await #expect(throws: ActionError.notRegistered(.sessionNew)) { try await r.perform(.sessionNew, nil) }
        #expect(r.availability(of: .sessionNew) == .unregistered)
    }

    @Test func disabledActionCarriesTheExactReasonAndDoesNotRun() async throws {
        let (r, _) = make()
        let enabled = Flag()
        let ran = Flag()
        try r.register(.tabNewAgent, enablement: { enabled.on ? .enabled : .disabled(reason: "Select a session first.") }) { _ in
            ran.on = true
            return nil
        }
        await #expect(throws: ActionError.disabled(.tabNewAgent, reason: "Select a session first.")) {
            try await r.perform(.tabNewAgent, nil)
        }
        #expect(!ran.on)
        #expect(r.availability(of: .tabNewAgent) == .disabled(reason: "Select a session first."))
        enabled.on = true
        _ = try await r.perform(.tabNewAgent, nil)
        #expect(ran.on)
    }

    @Test func futureSliceActionIsUnavailableEvenIfRegistered() async throws {
        let (r, _) = make(slice: .slice1)
        try r.register(.viewToggleRightPanel) { _ in nil }
        #expect(r.availability(of: .viewToggleRightPanel) == .unavailable(.slice2))
        #expect(!r.isRendered(.viewToggleRightPanel))
        await #expect(throws: ActionError.notAvailable(.viewToggleRightPanel, slice: .slice2)) {
            try await r.perform(.viewToggleRightPanel, nil)
        }
        let (r2, _) = make(slice: .slice2)
        try r2.register(.viewToggleRightPanel) { _ in nil }
        #expect(r2.isRendered(.viewToggleRightPanel))
        _ = try await r2.perform(.viewToggleRightPanel, nil)
    }

    @Test func v11ActionsAreNeverRendered() {
        let (r, _) = make(slice: .slice4)
        #expect(!r.isRendered(.sessionPin))
    }

    @Test func handlerFailuresBecomeActionErrors() async throws {
        let (r, _) = make()
        try r.register(.appAbout) { _ in throw Boom() }
        try r.register(.appSetup) { _ in throw ActionError.failed(.appSetup, message: "custom") }
        await #expect(throws: ActionError.self) { try await r.perform(.appAbout, nil) }
        await #expect(throws: ActionError.failed(.appSetup, message: "custom")) { try await r.perform(.appSetup, nil) }
    }

    @Test func indexListsEveryActionWithItsState() throws {
        let (r, _) = make()
        try r.register(.sessionNew) { _ in nil }
        let index = r.index()
        #expect(index.count == ActionID.catalog.count)
        #expect(index.first { $0.spec.id == .sessionNew }?.availability == .enabled)
        #expect(index.first { $0.spec.id == .sessionNewClean }?.availability == .unregistered)
        #expect(index.first { $0.spec.id == .pageInbox }?.availability == .unavailable(.slice2))
        #expect(r.registeredIDs == [.sessionNew])
    }

    @Test func dispatchingProtocolHopsToTheMainActor() async throws {
        let (r, s) = make()
        try r.register(.sessionNew) { _ in "ok" }
        s.tree = UITreeSnapshot(window: nil, roots: [UITreeNode(id: .tabsNew, kind: "button", action: .sessionNew)])
        let d: any ActionDispatching = r
        #expect(try await d.perform(.sessionNew, .press).message == "ok")
        #expect(await d.actionID(forControl: .tabsNew) == .sessionNew)
        #expect(await d.uiTree(root: nil).roots.count == 1)
        #expect(await d.appState().registeredActions == [.sessionNew])
        #expect(try await d.screenshot(.window(size: nil)).fidelity == "appkit")
        #expect(try await d.record(.stop).state == "stopped")
    }
}
