import RackyDocker
import Foundation

/// Runtime de computadores sem Docker (`RackyVZ`: VMs por Virtualization.framework). `AppComputerProvisioning` o usa no lugar do
/// Docker quando `RuntimeSelector` escolhe `.native`; o `RackyCore` só conhece este protocolo (não importa a apple/containerization).
///
/// Ciclo de vida: as VMs vivem no processo do app (limite do Virtualization.framework: a VM morre com o processo que a criou).
/// Por isso, depois de um reinício não há nada a readotar: o scheduler marca esses computadores como removidos e libera as reservas
/// dos filhos (a mesma adoção que reconhece contêineres do Docker, mas com lista vazia).
public protocol NativeComputerRuntime: Sendable {
    /// Por que este Mac não consegue rodar o runtime (versão do macOS, arquitetura...); `nil` = pode rodar.
    var unavailableReason: String? { get }
    /// Garante kernel, vminit e a imagem do computador (baixa e desempacota na primeira vez). Idempotente: chamadas concorrentes
    /// esperam a mesma preparação. `progress` recebe `.downloading`/`.preparing`; quem chama marca `.ready` no fim.
    func ensureReady(progress: @escaping @Sendable (ComputerSetupState) -> Void) async throws
    /// Memória e CPUs que a admissão pode usar (fração da memória física do Mac; sem VM do Docker no meio).
    func vmCapacity() async -> VMCapacity
    func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle
    /// Para todas as VMs deste processo (fim do app). Não lança.
    func shutdown() async
}
