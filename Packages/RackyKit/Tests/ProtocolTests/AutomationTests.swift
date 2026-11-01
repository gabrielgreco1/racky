import Foundation
import Testing

@testable import RackyProtocol

@Suite struct A11yIDTests {
    @Test func fixedConstantsAreCanonical() {
        for id in [A11yID.windowMain, .windowTitlebar, .windowAppName, .windowAutomationBadge, .sidebar, .tabsNew, .findField, .landing] {
            #expect(A11yID(rawValue: id.rawValue) == id)
        }
        #expect(A11yID.windowMain.rawValue == "window.main")
    }

    @Test func templatesProduceCanonicalIDs() {
        let samples: [A11yID] = [
            .sidebarSession("ab12cd34"), .sidebarSessionStatus("ab12cd34"), .sidebarSessionAgent("ab12cd34", "t1"),
            .sidebarSessionAgentChildrenToggle("ab12cd34", "t1"), .tabsTabClose("t1"), .pane("p1"), .paneExitOverlayRestart("p1"),
            .paneIgnitionStep("p1", "docker"), .overlay("composer"), .viewer("c1"), .menu("terminal", "splitRight"),
            .toast("error"), .status("pane.p1"), .errorBoundary("sidebar"),
        ]
        for id in samples { #expect(A11yID(rawValue: id.rawValue) != nil, "\(id.rawValue)") }
        #expect(A11yID.sidebarSession("ab12cd34").rawValue == "sidebar.session.ab12cd34")
        #expect(A11yID.sidebarSessionAgent("s", "t").rawValue == "sidebar.session.s.agent.t")
    }

    @Test func segmentsNeverContainDots() {
        #expect(A11yID.sidebarSession("a.b c").rawValue == "sidebar.session.a-b-c")
    }

    @Test func nonCanonicalIDsAreRejected() {
        for bad in ["", "foo", "foo.bar", "sidebar.session", "sidebar.session.x.bogus", "window.main.extra", "window..main", ".window", "Window.Main"] {
            #expect(A11yID(rawValue: bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func codableRoundTripAndRejection() throws {
        let enc = JSONEncoder()
        let data = try enc.encode([A11yID.windowMain, .sidebarSession("x")])
        #expect(String(decoding: data, as: UTF8.self) == #"["window.main","sidebar.session.x"]"#)
        #expect(try JSONDecoder().decode([A11yID].self, from: data) == [.windowMain, .sidebarSession("x")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([A11yID].self, from: Data(#"["nope.nope"]"#.utf8)) }
    }

    @Test func catalogIsLargeAndWithoutDuplicates() {
        #expect(A11yID.catalog.count >= 300)
        #expect(Set(A11yID.catalog.map(\.pattern)).count == A11yID.catalog.count)
    }

    @Test func matchingSpecReportsTemplate() {
        #expect(A11yID.matchingSpec("sidebar.session.zz")?.pattern == "sidebar.session.<id>")
        #expect(A11yID.matchingSpec("window.main")?.isTemplate == false)
    }
}

@Suite struct ActionIDTests {
    @Test func catalogIsUniqueAndComplete() {
        #expect(ActionID.catalog.count >= 280)
        #expect(Set(ActionID.catalog.map(\.id)).count == ActionID.catalog.count)
        for spec in ActionID.catalog {
            #expect(spec.id.rawValue.split(separator: ".").count >= 2, "\(spec.id)")
            #expect(!spec.label.isEmpty)
        }
    }

    @Test func lookupAndSpec() {
        #expect(ActionID(rawValue: "session.new") == .sessionNew)
        #expect(ActionID(rawValue: "session.nope") == nil)
        #expect(ActionID.sessionNew.spec.shortcut == "⌘N")
        #expect(ActionID.sessionNew.group == "session")
        #expect(ActionID.sessionSelect9.spec.shortcut == "⌘9")
        #expect(ActionID.tabSelect3.spec.shortcut == "⌃3")
        #expect(ActionID.terminalFontBigger.spec.shortcut == "⌘=")
    }

    @Test func slicesFollowTheVersionColumn() {
        #expect(ActionID.sessionNew.spec.slice == .slice1)
        #expect(ActionID.viewToggleSidebar.spec.slice == .slice1)
        #expect(ActionID.viewToggleRightPanel.spec.slice == .slice2)
        #expect(ActionID.pageInbox.spec.slice == .slice2)
        #expect(ActionID.computerTakeOver.spec.slice == .slice3)
        #expect(ActionID.pageLibrary.spec.slice == .slice4)
        #expect(ActionID.sessionPin.spec.slice == .v11)
    }

    @Test func codableRejectsUnknown() throws {
        #expect(try JSONDecoder().decode(ActionID.self, from: Data(#""app.quit""#.utf8)) == .appQuit)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ActionID.self, from: Data(#""app.nope""#.utf8)) }
    }
}

@Suite struct SliceFlagsTests {
    @Test func sliceOneEnablesOnlySliceOne() {
        let f = SliceFlags()
        #expect(f.isEnabled(.slice1))
        #expect(!f.isEnabled(.slice2))
        #expect(!f.isEnabled(.slice4))
        #expect(!f.isEnabled(.v11))
        #expect(!f.isEnabled(.later))
    }

    @Test func higherSliceEnablesLowerOnes() {
        let f = SliceFlags(current: .slice3)
        #expect(f.isEnabled(.slice1) && f.isEnabled(.slice2) && f.isEnabled(.slice3))
        #expect(!f.isEnabled(.slice4))
        #expect(!f.isEnabled(.v11))
    }

    @Test func environmentOverride() {
        // F13: sem `RACKY_SLICE` o app liga o que as Fatias 1 a 3 já implementam; o valor explícito restringe.
        #expect(SliceFlags.fromEnvironment([:]).current == .slice3)
        #expect(!SliceFlags.fromEnvironment([:]).restricted)
        #expect(SliceFlags.fromEnvironment(["RACKY_SLICE": "2"]).current == .slice2)
        #expect(SliceFlags.fromEnvironment(["RACKY_SLICE": "2"]).restricted)
        #expect(SliceFlags.fromEnvironment(["RACKY_SLICE": "100"]).current == .slice3)
        #expect(SliceFlags.fromEnvironment(["RACKY_SLICE": "x"]).current == .slice3)
    }
}

@Suite struct AppSockFrameTests {
    @Test func roundTrip() throws {
        var dec = AppSockFrameDecoder()
        dec.append(AppSockFrame.encode(Data("hello".utf8)))
        #expect(try dec.next() == Data("hello".utf8))
        #expect(try dec.next() == nil)
    }

    @Test func partialAndMultipleFrames() throws {
        let two = AppSockFrame.encode(Data("a".utf8)) + AppSockFrame.encode(Data("bcd".utf8))
        var dec = AppSockFrameDecoder()
        dec.append(two.prefix(3))
        #expect(try dec.next() == nil)
        dec.append(two.dropFirst(3).prefix(4))
        #expect(try dec.next() == Data("a".utf8))
        #expect(try dec.next() == nil)
        dec.append(two.dropFirst(7))
        #expect(try dec.next() == Data("bcd".utf8))
    }

    @Test func oversizedFrameIsRejected() {
        var dec = AppSockFrameDecoder(maxLength: 16)
        dec.append(AppSockFrame.encode(Data(repeating: 1, count: 17)))
        #expect(throws: AppSockFrameError.self) { try dec.next() }
    }

    @Test func emptyPayloadIsAFrame() throws {
        var dec = AppSockFrameDecoder()
        dec.append(AppSockFrame.encode(Data()))
        #expect(try dec.next() == Data())
    }
}

@Suite struct CtlWireTests {
    @Test func requestRoundTrip() throws {
        let req = CtlRequest(
            command: .uiWait, root: .windowMain, target: "session.new", argument: .set("x"), element: .windowAppName,
            waitState: .gone, timeoutMs: 250, screenshotElement: .windowTitlebar, size: UISize(width: 1440, height: 900), outPath: "/x.png")
        let data = try CtlCodec.encoder().encode(req)
        #expect(try CtlCodec.decoder().decode(CtlRequest.self, from: data) == req)
    }

    @Test func responseRoundTripWithTreeAndScreenshot() throws {
        let node = UITreeNode(
            id: .windowMain, kind: "window", label: "Racky", enabled: false, disabledReason: "why", action: .appQuit,
            frame: UIFrame(x: 0, y: 0, width: 10, height: 20),
            children: [UITreeNode(id: .windowTitlebar, kind: "container")])
        let res = CtlResponse(
            tree: UITreeSnapshot(window: UIWindowInfo(title: "t", width: 1, height: 2, scale: 2, isKey: true), roots: [node]),
            screenshot: ScreenshotResult(fidelity: "appkit", pixelWidth: 2, pixelHeight: 2, scale: 2, png: Data([1, 2, 3])))
        let back = try CtlCodec.decoder().decode(CtlResponse.self, from: try CtlCodec.encoder().encode(res))
        #expect(back == res)
        #expect(back.tree?.find(.windowTitlebar)?.kind == "container")
        #expect(node.flattened().map(\.id) == [.windowMain, .windowTitlebar])
    }

    @Test func errorsCarryReason() throws {
        let res = CtlResponse.failure(CtlError(code: "action_disabled", message: "m", reason: "Select a session first."))
        let back = try CtlCodec.decoder().decode(CtlResponse.self, from: try CtlCodec.encoder().encode(res))
        #expect(!back.ok)
        #expect(back.error?.reason == "Select a session first.")
    }

    @Test func uiSizeParsing() {
        #expect(UISize(parsing: "1440x900") == UISize(width: 1440, height: 900))
        #expect(UISize(parsing: "760X480") == UISize(width: 760, height: 480))
        #expect(UISize(parsing: "abc") == nil)
        #expect(UISize(parsing: "0x10") == nil)
    }

    @Test func appSockPathHonorsOverride() {
        #expect(AppSockPath.resolve(environment: ["RACKY_APP_SOCK": "/x/y.sock", "HOME": "/h"]) == "/x/y.sock")
        #expect(AppSockPath.resolve(environment: ["HOME": "/h"]) == "/h/Library/Application Support/Racky/run/app.sock")
    }
}
