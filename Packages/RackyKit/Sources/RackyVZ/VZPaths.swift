import Foundation

/// Pastas do runtime sem Docker, sob a pasta de dados do app (`~/Library/Application Support/Racky/vz/` ou `$RACKY_HOME/vz/`):
///
///     vz/
///       registry.json        VMs vivas deste app (substitui os labels do Docker)
///       assets/              downloads verificados (kernel, vminit, imagem do computador) e o estado `ready.json`
///       store/               ImageStore da apple/containerization (blobs OCI) e `containers/<vm>/` (rootfs clonado + bootlog)
///       templates/<digest>/  rootfs.ext4 desempacotado UMA vez por digest da imagem; cada computador é um clonefile dele
public struct VZPaths: Sendable, Equatable {
    public let root: URL

    /// `appDataRoot` é a raiz de dados do app (`StorePaths.root`).
    public init(appDataRoot: URL) { root = appDataRoot.appendingPathComponent("vz", isDirectory: true) }

    public var registryFile: URL { root.appendingPathComponent("registry.json") }
    public var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var readyFile: URL { assets.appendingPathComponent("ready.json") }
    /// O runtime já foi baixado e preparado (existe o `ready.json`): a próxima reserva não precisa da rede.
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: readyFile.path) }
    public var store: URL { root.appendingPathComponent("store", isDirectory: true) }
    /// Onde a `ContainerManager` guarda cada VM (`<store>/containers/<id>`): é o que o sweep apaga.
    public var containers: URL { store.appendingPathComponent("containers", isDirectory: true) }
    public var templates: URL { root.appendingPathComponent("templates", isDirectory: true) }
    public var scratch: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    public func containerDirectory(_ id: String) -> URL { containers.appendingPathComponent(id, isDirectory: true) }

    /// `sha256:abc...` -> `abc...` (nome de pasta seguro).
    public func templateDirectory(digest: String) -> URL {
        let safe = digest.replacingOccurrences(of: ":", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return templates.appendingPathComponent(safe, isDirectory: true)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [root, assets, store, containers, templates, scratch] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    }
}
