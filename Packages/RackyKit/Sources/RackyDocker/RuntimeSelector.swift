import Foundation

/// Qual runtime sobe os computadores neste Mac.
public enum ComputerRuntimeChoice: String, Sendable, Equatable {
    /// VMs Linux nativas (Virtualization.framework via apple/containerization), sem Docker: `RackyVZ`.
    case native
    /// Docker (Desktop, OrbStack, Colima...): o caminho original, e o único em macOS < 26 ou Intel.
    case docker
}

/// Ordem de seleção do runtime (docs/rebuild/vz-runtime.md): macOS 26+ em Apple silicon usa o runtime nativo; qualquer outro caso,
/// ou o usuário forçando Docker em Settings › Computers, usa o Docker. Função pura: os testes injetam versão e arquitetura.
public enum RuntimeSelector {
    public static let nativeMinimumMajorVersion = 26

    public static func choose(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        appleSilicon: Bool = isAppleSilicon,
        forceDocker: Bool,
        nativeLinked: Bool = true
    ) -> ComputerRuntimeChoice {
        guard !forceDocker, nativeLinked, appleSilicon, osVersion.majorVersion >= nativeMinimumMajorVersion else { return .docker }
        return .native
    }

    /// Por que o runtime nativo não serve a este Mac (para o Settings), ou `nil` se serve.
    public static func nativeUnavailableReason(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion, appleSilicon: Bool = isAppleSilicon
    ) -> String? {
        if !appleSilicon { return "The built-in computer runtime needs a Mac with Apple silicon." }
        if osVersion.majorVersion < nativeMinimumMajorVersion { return "The built-in computer runtime needs macOS \(nativeMinimumMajorVersion) or later." }
        return nil
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
