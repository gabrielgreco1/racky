import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation

/// Ferramenta de build dos arquivos do runtime (não roda no app): baixa uma imagem OCI de um registro com o cliente da própria
/// apple/containerization e a exporta como um OCI tar que `VZAssetStore` sabe importar. É assim que sai o `vminit.oci.tar`: o `docker
/// pull` recusa a imagem publicada do vminit (o diff id das camadas é o do arquivo comprimido, ver `InitImage.create`).
enum VZImageExport {
    static func pullAndArchive(reference: String, to archive: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("racky-vz-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let store = try ImageStore(path: scratch.appendingPathComponent("store", isDirectory: true))
        _ = try await store.pull(reference: reference, platform: platform)
        let layout = scratch.appendingPathComponent("layout", isDirectory: true)
        try fm.createDirectory(at: layout, withIntermediateDirectories: true)
        try await store.save(references: [reference], out: layout, platform: platform)
        try? fm.removeItem(at: archive)
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: archive)
        try writer.archiveDirectory(layout)
        try writer.finishEncoding()
    }
}
