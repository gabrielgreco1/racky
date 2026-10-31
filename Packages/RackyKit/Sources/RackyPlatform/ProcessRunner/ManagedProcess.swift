import Foundation
import Synchronization

/// Espera de saída sem bloquear o pool cooperativo. `wait()` é cancelável: a espera cancelada devolve `Int32.min`
/// (quem chama confere `Task.isCancelled`), senão um grupo de tarefas ficaria preso até o processo sair.
public final class ProcessExitSignal: Sendable {
    private struct State {
        var status: Int32?
        var waiters: [UUID: CheckedContinuation<Int32, Never>] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    public func finish(_ code: Int32) {
        let pending = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
            state.status = code
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in pending { waiter.resume(returning: code) }
    }

    public func wait() async -> Int32 {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Int32? = state.withLock { state in
                    if let status = state.status { return status }
                    if Task.isCancelled { return Int32.min }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(returning: Int32.min)
        }
    }
}

/// Processo filho de longa vida (ex.: o mestre do `ssh`): ambiente explícito (nada herdado), stdin vazio, saída descartada e os
/// últimos bytes de stderr guardados para diagnóstico. Sem espera bloqueante (callbacks do GCD).
public final class ManagedProcess: Sendable {
    private let process: Mutex<Process?>
    private let exit = ProcessExitSignal()
    private let tail = Mutex(Data())
    public static let tailLimit = 4096

    private init(_ process: Process) { self.process = Mutex(process) }

    public static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> ManagedProcess {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        child.standardError = errors
        let managed = ManagedProcess(child)
        errors.fileHandleForReading.readabilityHandler = { [managed] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            managed.tail.withLock { tail in
                tail.append(data)
                if tail.count > tailLimit { tail = Data(tail.suffix(tailLimit)) }
            }
        }
        child.terminationHandler = { [managed] process in managed.exit.finish(process.terminationStatus) }
        do {
            try child.run()
        } catch {
            // Sem isto o `terminationHandler` (que segura o `managed`) e os dois lados do pipe nunca seriam soltos.
            child.terminationHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? errors.fileHandleForWriting.close()
            throw error
        }
        return managed
    }

    public func terminate() {
        process.withLock { child in if let child, child.isRunning { child.terminate() } }
    }

    public func waitUntilExit() async -> Int32 { await exit.wait() }

    /// Últimos bytes de stderr (até 4 KiB).
    public var stderrTail: String { tail.withLock { String(decoding: $0, as: UTF8.self) } }
}
