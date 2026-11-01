import Darwin
import Foundation
import Synchronization

import RackyCore
import RackyDocker

@testable import RackyVZ

/// Sessão de exec falsa: junta o que o chamador escreve no stdin e termina com a saída combinada.
final class FakeSession: ComputerExecSession {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>
    private let input = Mutex(Data())
    private let exit: Int
    private let terminated = Mutex(false)

    init(stdout: String, exit: Int) {
        self.exit = exit
        frames = AsyncThrowingStream { continuation in
            continuation.yield(DockerStreamFrame(kind: .stdout, data: Data(stdout.utf8)))
            continuation.finish()
        }
    }

    var receivedInput: Data { input.withLock { $0 } }
    var wasTerminated: Bool { terminated.withLock { $0 } }
    func writeInput(_ data: Data) async throws { input.withLock { $0.append(data) } }
    func closeInput() async {}
    func finalExitCode() async throws -> Int { exit }
    func terminateGroup(grace: Duration) async throws { terminated.withLock { $0 = true } }
}

/// VM falsa: registra os comandos, guarda o stdin do `abx-provision` e responde a admin API por um socketpair (a ponte real a alcança).
final class FakeVM: RunningVM {
    let vmID: String
    let ipAddress: String? = "192.168.64.9"
    private let started = Mutex<[(request: VZExecRequest, session: FakeSession)]>([])
    private let stopCount = Mutex(0)
    private let runtimeReady: Bool

    init(vmID: String, runtimeReady: Bool = true) {
        self.vmID = vmID
        self.runtimeReady = runtimeReady
    }

    var processes: [(request: VZExecRequest, session: FakeSession)] { started.withLock { $0 } }
    var stops: Int { stopCount.withLock { $0 } }

    func startProcess(_ request: VZExecRequest) async throws -> any ComputerExecSession {
        let isProvision = request.command.first == "abx-provision"
        let session = FakeSession(stdout: isProvision ? "ok\n" : "hi\n", exit: 0)
        started.withLock { $0.append((request, session)) }
        return session
    }

    func dialVsock(port: UInt32) async throws -> FileHandle {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw VZError.unavailable("socketpair") }
        let server = fds[1]
        let ready = runtimeReady
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var received = Data()
            while !received.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
                let count = read(server, &buffer, buffer.count)
                if count <= 0 { close(server); return }
                received.append(contentsOf: buffer[0..<count])
            }
            let request = String(decoding: received, as: UTF8.self)
            let body = request.contains("/runtime/v1/health") ? #"{"ready": \#(ready)}"# : #"{"status":"ok"}"#
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { write(server, $0, strlen($0)) }
            shutdown(server, SHUT_WR)
            // Espera o cliente fechar antes de soltar o fd (a ponte meio-fecha o lado dela).
            while read(server, &buffer, buffer.count) > 0 {}
            close(server)
        }
        return FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    }

    func copyIn(from source: URL, to guestPath: String) async throws {}
    func copyOut(from guestPath: String, to destination: URL) async throws {}
    func stop() async { stopCount.withLock { $0 += 1 } }
}

final class FakeBackend: VZBackend {
    let subnet = "192.168.64.0/24"
    private let state = Mutex<(plans: [VZVMPlan], vms: [FakeVM])>(([], []))
    private let failure: (any Error)?
    private let runtimeReady: Bool

    init(failure: (any Error)? = nil, runtimeReady: Bool = true) {
        self.failure = failure
        self.runtimeReady = runtimeReady
    }

    var internalSubnet: String { subnet }
    var plans: [VZVMPlan] { state.withLock { $0.plans } }
    var vms: [FakeVM] { state.withLock { $0.vms } }

    func boot(_ plan: VZVMPlan, image: VZBootImage) async throws -> any RunningVM {
        if let failure { throw failure }
        let vm = FakeVM(vmID: plan.vmID, runtimeReady: runtimeReady)
        state.withLock {
            $0.plans.append(plan)
            $0.vms.append(vm)
        }
        return vm
    }

    func stopAll() async {
        for vm in vms { await vm.stop() }
    }
}
