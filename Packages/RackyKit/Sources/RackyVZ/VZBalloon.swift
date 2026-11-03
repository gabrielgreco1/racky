import Containerization
import ContainerizationExtras
import Foundation
import Synchronization
@preconcurrency import Virtualization

/// Balão de memória (backlog 20). Uma VM do Virtualization.framework nunca devolve ao Mac a memória que já tocou: depois de um pico
/// (pytest, Chromium numa página pesada) o processo da VM segue ocupando o pico até ela desligar (medido em 02/11: 3,2 GB depois de
/// um job de 2 GB que já tinha acabado). Com o balão, o app infla até sobrar só o que a VM usa de fato mais uma folga, o Linux
/// entrega essas páginas, o Mac as libera, e o balão volta a esvaziar: as páginas devolvidas só voltam a ocupar o Mac se a VM
/// precisar delas de novo.
final class VZBalloonHandle: Sendable {
    private struct Device: @unchecked Sendable {  // SAFETY: só tocado na fila da VM (`queue`).
        let device: VZVirtioTraditionalMemoryBalloonDevice
        let queue: DispatchQueue
    }
    private let device = Mutex<Device?>(nil)

    private struct VMRef: @unchecked Sendable { let vm: VZVirtualMachine }  // SAFETY: só lido na fila da própria VM.

    func attach(_ instance: VZVirtualMachineInstance) {
        let queue = instance.vmQueue
        let ref = VMRef(vm: instance.vzVirtualMachine)
        queue.async { [self] in
            guard let balloon = ref.vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
            device.withLock { $0 = Device(device: balloon, queue: queue) }
        }
    }

    var isAttached: Bool { device.withLock { $0 != nil } }

    /// Tamanho de memória que a VM deve enxergar (o balão ocupa o resto). Arredonda para MiB, como o framework exige.
    func setTarget(bytes: UInt64) async {
        guard let current = device.withLock({ $0 }) else { return }
        let rounded = (bytes / (1 << 20)) * (1 << 20)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            current.queue.async {
                current.device.targetVirtualMachineMemorySize = rounded
                done.resume()
            }
        }
    }
}

/// Liga o dispositivo de balão na configuração da VM e entrega o dispositivo vivo ao `VZBalloonHandle`.
struct VZBalloonExtension: VZInstanceExtension {
    let handle: VZBalloonHandle

    func configureVZ(_ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>, storageDeviceCount: Int,
                     mountsByID: [String: [Mount]]) throws {
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }

    func didCreate(_ instance: VZVirtualMachineInstance) throws { handle.attach(instance) }
}

/// O gerenciador de VMs do framework, com o balão em cada VM criada. `LinuxContainer` não repassa extensões; este embrulho
/// as injeta na configuração antes de criar a VM.
struct VZBalloonVMM: VirtualMachineManager {
    let base: VZVirtualMachineManager
    /// Um por container: um `LinuxContainer` cria exatamente uma VM.
    let handle: VZBalloonHandle

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        var configuration = config.configuration
        configuration.extensions.append(VZBalloonExtension(handle: handle))
        return try base.create(config: StandardVMConfig(configuration: configuration))
    }
}

/// Balão ajustado o tempo todo (backlog 20). A VM fica com o que usa de verdade (programas, sem contar o cache de arquivos) mais uma
/// folga; o resto fica no balão e não ocupa o Mac. Medido em 02/11: o Chromium subindo com o balão ajustado ocupou 539 MB no Mac,
/// contra 1.229 MB sem ele (a diferença era cache de arquivo dentro da VM que o Mac guardava). Precisa de mais: esvazia na hora.
/// Sobrou: infla aos poucos. O swap da VM segura o pico entre duas leituras.
enum VZBalloonPolicy {
    static let headroom: UInt64 = 512 << 20
    static let floor: UInt64 = 768 << 20
    /// Diferença mínima para mexer (evita ajustar por ruído).
    static let hysteresis: UInt64 = 128 << 20
    /// Quanto o balão pode encher por leitura (encher de uma vez joga o cache inteiro fora e trava o que estiver rodando).
    static let maxInflateStep: UInt64 = 512 << 20

    struct MemInfo: Equatable {
        var total: UInt64
        var available: UInt64
        /// Swap em uso: memória de programa que não coube. Conta como uso, senão a VM troca para o disco em vez de pedir memória.
        var swapUsed: UInt64 = 0
    }

    static func parse(_ meminfo: String) -> MemInfo? {
        var values: [String: UInt64] = [:]
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" })
            if parts.count >= 2, let kb = UInt64(parts[1]) { values[String(parts[0])] = kb * 1024 }
        }
        guard let total = values["MemTotal"], let available = values["MemAvailable"] else { return nil }
        let swapTotal = values["SwapTotal"] ?? 0, swapFree = values["SwapFree"] ?? 0
        return MemInfo(total: total, available: available, swapUsed: swapTotal > swapFree ? swapTotal - swapFree : 0)
    }

    /// Próximo tamanho de memória da VM, dado o atual (`current`, com o balão ocupando `configured - current`).
    /// Com o balão cheio, as páginas dele aparecem como usadas no `MemAvailable`; o uso real desconta o balão.
    static func next(current: UInt64, configured: UInt64, info: MemInfo) -> UInt64 {
        let balloon = configured > current ? configured - current : 0
        let usedWithBalloon = info.total > info.available ? info.total - info.available : 0
        let used = (usedWithBalloon > balloon ? usedWithBalloon - balloon : 0) + info.swapUsed
        let want = min(max(used + headroom, floor), configured)
        if want > current { return want }  // precisa de memória: esvazia já
        if current - want < hysteresis { return current }
        return max(want, current - maxInflateStep)
    }
}
