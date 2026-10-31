import RackyProtocol
import AppKit
import Foundation
import ScreenCaptureKit
import Synchronization

/// Gravação da própria janela em `.mov` (`ctl record start|stop`, 08 AR-806) via `SCRecordingOutput` (macOS 15).
/// Serve para a comparação de motion com a referência (P1/P14). Exige Gravação de Tela.
@MainActor
final class WindowRecorder {
    private var stream: SCStream?
    private var delegate: RecordingDelegate?
    private var path: String?

    var isRecording: Bool { stream != nil }

    func start(window: NSWindow, outPath: String) async throws -> RecordingResult {
        guard stream == nil else { throw CtlError(code: "recording_failed", message: "a recording is already running (\(path ?? ""))") }
        let url = URL(fileURLWithPath: outPath)
        unlink(outPath)
        // Só consulta (nunca pede) a permissão de Gravação de Tela: sem ela o macOS abriria o prompt a cada execução.
        guard CGPreflightScreenCaptureAccess() else {
            throw CtlError(code: "recording_failed", message: "Screen Recording permission is not granted (grant it in System Settings; the app never asks)")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let wid = CGWindowID(window.windowNumber)
            guard let target = content.windows.first(where: { $0.windowID == wid }) else {
                throw CtlError(code: "recording_failed", message: "window not visible to ScreenCaptureKit")
            }
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
            let recConfig = SCRecordingOutputConfiguration()
            recConfig.outputURL = url
            recConfig.outputFileType = .mov
            recConfig.videoCodecType = .h264
            let d = RecordingDelegate()
            let output = SCRecordingOutput(configuration: recConfig, delegate: d)
            try s.addRecordingOutput(output)
            try await s.startCapture()
            stream = s
            delegate = d
            path = outPath
            return RecordingResult(state: "recording", path: outPath)
        } catch let e as CtlError {
            throw e
        } catch {
            throw CtlError(code: "recording_failed", message: "could not start recording: \(error.localizedDescription)")
        }
    }

    func stop() async throws -> RecordingResult {
        guard let s = stream, let d = delegate, let p = path else {
            throw CtlError(code: "recording_failed", message: "no recording is running")
        }
        stream = nil
        delegate = nil
        path = nil
        do { try await s.stopCapture() } catch {
            throw CtlError(code: "recording_failed", message: "could not stop recording: \(error.localizedDescription)")
        }
        // O arquivo só fecha quando o delegate avisa o fim.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !d.finished && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return RecordingResult(state: d.finished ? "stopped" : "stopped-unconfirmed", path: p)
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, Sendable {
    private let done = Mutex(false)
    var finished: Bool { done.withLock { $0 } }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        done.withLock { $0 = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        done.withLock { $0 = true }
    }
}
