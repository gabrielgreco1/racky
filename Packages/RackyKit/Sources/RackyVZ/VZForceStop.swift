import Darwin
import Foundation
import RackyPlatform

/// Desligar uma VM que não responde. O `LinuxContainer.stop()` fala com o agente dentro da VM antes de parar a máquina; com a VM
/// travada (sem memória, 02/11) essas chamadas nunca voltam e a VM fica girando a 200% de CPU depois de "liberada". Aqui: prazo para o
/// desligamento educado e, passado o prazo, SIGKILL no processo XPC do Virtualization.framework que roda aquela VM (cada VM tem o seu,
/// e é o único que mantém o `rootfs.ext4` dela aberto).
enum VZForceStop {
    /// `true` se `work` terminou dentro do prazo. Não espera o `work` travado: ele segue solto e é abandonado.
    static func finishes(within limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let flag = AtomicFlag()
            Task {
                await work()
                if flag.setOnce() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if flag.setOnce() { continuation.resume(returning: false) }
            }
        }
    }

    static let xpcName = "com.apple.Virtualization.VirtualMachine"

    /// Pids da saída de `lsof -t` (um por linha).
    static func pids(fromLsof text: String) -> [pid_t] {
        text.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Mata o processo de VM que tem `rootfs` aberto. Só toca processos do Virtualization.framework; devolve os pids mortos.
    @discardableResult
    static func killVM(holding rootfs: URL) async -> [pid_t] {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-t", "--", rootfs.path], timeout: .seconds(10))
        guard let out = try? await ProcessRunner.run(request) else { return [] }
        return pids(fromLsof: out.stdoutString).filter { pid in
            guard pid != getpid(), executablePath(pid)?.contains(xpcName) == true else { return false }
            return kill(pid, SIGKILL) == 0
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
