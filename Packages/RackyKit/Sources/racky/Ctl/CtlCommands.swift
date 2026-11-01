import RackyProtocol
import ArgumentParser
import Foundation

struct CtlOptions: ParsableArguments {
    @Option(name: .long, help: "Path of app.sock (default: $RACKY_APP_SOCK or ~/Library/Application Support/Racky/run/app.sock).")
    var sock: String?

    var resolvedSocket: String {
        sock ?? AppSockPath.resolve(environment: ProcessInfo.processInfo.environment)
    }
}

private func a11y(_ raw: String) throws -> A11yID {
    guard let id = A11yID(rawValue: raw) else {
        throw ValidationError("\(raw) is not a canonical A11yID (see docs/automation-ids.md)")
    }
    return id
}

/// `racky ctl`: automação do app via `app.sock` (08 AR-806). Saída sempre JSON.
struct CtlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ctl",
        abstract: "Drive the running Racky app (opt-in: the app must run with the automation channel on).",
        subcommands: [StateCommand.self, UICommand.self, ScreenshotCommand.self, RecordCommand.self, CompareCommand.self]
    )
}

struct StateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "state", abstract: "App state as JSON.")
    @OptionGroup var options: CtlOptions

    func run() async throws {
        try await runCtl(options, CtlRequest(command: .state)) { CtlOutput.writeJSON($0) }
    }
}

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui", abstract: "Inspect and drive the UI.",
        subcommands: [UITreeCommand.self, UIActionCommand.self, UIWaitCommand.self])
}

struct UITreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tree", abstract: "Tree of mounted controls (ids, labels, values, state, frames).")
    @OptionGroup var options: CtlOptions
    @Option(name: .long, help: "Only the subtree of this A11yID.") var root: String?

    func run() async throws {
        let req = CtlRequest(command: .uiTree, root: try root.map(a11y))
        try await runCtl(options, req) { CtlOutput.writeJSON($0.tree) }
    }
}

struct UIActionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract: "Run an ActionID (session.new) or the action bound to an A11yID, through the ActionRegistry.",
        discussion: "Verbs: press (default), focus, select [value], set <value>.")
    @OptionGroup var options: CtlOptions
    @Argument(help: "ActionID or A11yID.") var target: String
    @Argument(help: "press | focus | select | set") var verb: String?
    @Argument(help: "Value for select/set.") var value: String?

    func run() async throws {
        var arg = ActionArgument.press
        if let verb {
            guard let kind = ActionArgument.Kind(rawValue: verb) else {
                throw ValidationError("unknown verb \(verb) (press, focus, select, set)")
            }
            if kind == .set && value == nil { throw ValidationError("set needs a value") }
            arg = ActionArgument(kind: kind, value: value)
        }
        try await runCtl(options, CtlRequest(command: .uiAction, target: target, argument: arg)) { CtlOutput.writeJSON($0) }
    }
}

struct UIWaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for an element to appear, go away, or change state.")
    @OptionGroup var options: CtlOptions
    @Argument(help: "A11yID to wait for.") var id: String
    @Option(name: .long, help: "appear (default) | gone | enabled | disabled") var state: String = "appear"
    @Option(name: .long, help: "Seconds to wait (default 5).") var timeout: Double = 5

    func run() async throws {
        guard let waitState = UIWaitState(rawValue: state) else { throw ValidationError("unknown state \(state)") }
        let ms = Int(timeout * 1000)
        let req = CtlRequest(command: .uiWait, element: try a11y(id), waitState: waitState, timeoutMs: ms)
        try await runCtl(options, req, timeout: .milliseconds(ms + 5000)) { CtlOutput.writeJSON($0) }
    }
}

struct ScreenshotOutput: Encodable {
    var ok = true
    var out: String
    var fidelity: String
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double
    var note: String?
}

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "PNG of the app's own window (ScreenCaptureKit) or of one element.")
    @OptionGroup var options: CtlOptions
    @Flag(name: .long, help: "Capture the whole window (default).") var window = false
    @Option(name: .long, help: "Crop to this A11yID.") var element: String?
    @Option(name: .long, help: "Resize the window content to WxH points before capturing (for example 1440x900).") var size: String?
    @Option(name: .long, help: "Output PNG file.") var out: String

    func validate() throws {
        if window && element != nil { throw ValidationError("use --window or --element, not both") }
    }

    func run() async throws {
        var sz: UISize?
        if let size {
            guard let parsed = UISize(parsing: size) else { throw ValidationError("--size must look like 1440x900") }
            sz = parsed
        }
        let req = CtlRequest(command: .screenshot, screenshotElement: try element.map(a11y), size: sz, outPath: out)
        try await runCtl(options, req) { response in
            guard let shot = response.screenshot else { throw CtlOutput.fail(code: "bad_request", message: "no screenshot in response") }
            try shot.png.write(to: URL(fileURLWithPath: out))
            CtlOutput.writeJSON(
                ScreenshotOutput(
                    out: out, fidelity: shot.fidelity, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight,
                    scale: shot.scale, note: shot.note))
        }
    }
}

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record", abstract: "Record the app window to .mov.",
        subcommands: [RecordStart.self, RecordStop.self])

    struct RecordStart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "start", abstract: "Start recording.")
        @OptionGroup var options: CtlOptions
        @Option(name: .long, help: "Output .mov file.") var out: String

        func run() async throws {
            try await runCtl(options, CtlRequest(command: .recordStart, outPath: out)) { CtlOutput.writeJSON($0.recording) }
        }
    }

    struct RecordStop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop recording and close the file.")
        @OptionGroup var options: CtlOptions

        func run() async throws {
            try await runCtl(options, CtlRequest(command: .recordStop)) { CtlOutput.writeJSON($0.recording) }
        }
    }
}

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Offline: side-by-side, 50% overlay and absolute difference of two PNGs (used by scripts/compare-ui.sh).")
    @Argument(help: "Racky screenshot.") var app: String
    @Argument(help: "Reference PNG (scaled to the screenshot size when they differ).") var reference: String
    @Option(name: .long, help: "Directory for the outputs.") var outDir: String
    @Option(name: .long, help: "File name prefix.") var name: String

    func run() async throws {
        do {
            let result = try ImageCompare.run(
                appPath: app, referencePath: reference, outDir: outDir, name: name)
            CtlOutput.writeJSON(result)
        } catch {
            throw CtlOutput.fail(code: "compare_failed", message: "\(error)")
        }
    }
}
