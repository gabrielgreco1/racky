import Containerization
import ContainerizationOCI
import Foundation
import RackyPlatform

/// Progresso do preparo do runtime (download dos três arquivos e desempacotamento das imagens).
public enum VZSetupProgress: Sendable, Equatable {
    case downloading(done: Int64, total: Int64)
    case preparing(String)
}

/// O que sobra pronto no disco depois do preparo.
public struct VZReadyAssets: Codable, Sendable, Equatable {
    public var manifestVersion: String
    public var kernelSHA: String
    public var vminitSHA: String
    public var computerSHA: String
    public var kernelPath: String
    /// `initfs.ext4` (desempacotado do vminit): é o disco de boot de toda VM.
    public var initfsPath: String
    public var imageReference: String
    public var imageDigest: String
    public var templatePath: String

    public var kernel: URL { URL(fileURLWithPath: kernelPath) }
    public var initfs: URL { URL(fileURLWithPath: initfsPath) }
    public var template: URL { URL(fileURLWithPath: templatePath) }
    public var bootImage: VZBootImage { VZBootImage(reference: imageReference, digest: imageDigest, templateRootfs: template) }
}

public enum VZAssetError: Error, Equatable, LocalizedError, Sendable {
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .importFailed(let detail): "the computer runtime could not be prepared (\(detail))"
        }
    }
}

/// Baixa (verificado e retomável) e prepara o kernel, o vminit e a imagem do computador em `vz/assets` e `vz/templates`.
/// Depois do primeiro preparo, `ensureReady` só confere o `ready.json` e funciona offline. Um actor: preparos concorrentes viram um só.
public actor VZAssetStore {
    public let paths: VZPaths
    private let downloader: AssetDownloader
    private var inflight: Task<VZReadyAssets, any Error>?

    public init(paths: VZPaths, downloader: AssetDownloader = AssetDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    /// Estado pronto gravado, se os arquivos ainda existem e batem com o manifesto.
    public func ready(for manifest: VZManifest) -> VZReadyAssets? {
        guard let data = try? Data(contentsOf: paths.readyFile), let ready = try? JSONDecoder().decode(VZReadyAssets.self, from: data),
              ready.kernelSHA == manifest.kernel.sha256.lowercased(), ready.vminitSHA == manifest.vminit.sha256.lowercased(),
              ready.computerSHA == manifest.computer.sha256.lowercased() else { return nil }
        let fm = FileManager.default
        guard [ready.kernelPath, ready.initfsPath, ready.templatePath].allSatisfy({ fm.fileExists(atPath: $0) }) else { return nil }
        return ready
    }

    public func ensureReady(manifest: VZManifest, progress: @escaping @Sendable (VZSetupProgress) -> Void) async throws -> VZReadyAssets {
        if let ready = ready(for: manifest) { return ready }
        if let inflight { return try await inflight.value }
        let task = Task { try await self.prepare(manifest: manifest, progress: progress) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    // MARK: Preparo

    private func prepare(manifest: VZManifest, progress: @escaping @Sendable (VZSetupProgress) -> Void) async throws -> VZReadyAssets {
        try manifest.requirePublished()
        try paths.ensureDirectories()
        let kernel = try await download(manifest, name: "kernel", progress: progress)
        let vminit = try await download(manifest, name: "vminit", progress: progress)
        let computer = try await download(manifest, name: "computer", progress: progress)

        progress(.preparing("Preparing the computer runtime…"))
        let store = try ImageStore(path: paths.store)
        let initfs = try await importInitfs(archive: vminit, sha: manifest.vminit.sha256.lowercased(), store: store)
        let (reference, digest, template) = try await importComputerImage(archive: computer, store: store)

        let ready = VZReadyAssets(
            manifestVersion: manifest.version, kernelSHA: manifest.kernel.sha256.lowercased(), vminitSHA: manifest.vminit.sha256.lowercased(),
            computerSHA: manifest.computer.sha256.lowercased(), kernelPath: kernel.path, initfsPath: initfs.path, imageReference: reference,
            imageDigest: digest, templatePath: template.path)
        try JSONEncoder().encode(ready).write(to: paths.readyFile, options: .atomic)
        // Os OCI tar já estão no ImageStore; o disco de download não precisa deles (o kernel fica: é o próprio arquivo de boot).
        for archive in [vminit, computer] {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: AssetDownloader.sidecar(archive))
        }
        collectGarbage(keeping: ready)
        return ready
    }

    /// Baixa um arquivo do manifesto para `assets/<nome>-<sha8>/<arquivo>`. O progresso é agregado dos três arquivos.
    private func download(_ manifest: VZManifest, name: String, progress: @escaping @Sendable (VZSetupProgress) -> Void) async throws -> URL {
        let assets = manifest.assets
        guard let spec = assets.first(where: { $0.name == name })?.spec else { throw VZAssetError.importFailed("no \(name) in the manifest") }
        // Soma dos tamanhos dos arquivos anteriores (já completos) + o andamento deste.
        var before: Int64 = 0
        for item in assets {
            if item.name == name { break }
            before += item.spec.size ?? 0
        }
        let total = manifest.totalSize
        let base = before
        let destination = paths.assets.appendingPathComponent("\(name)-\(spec.sha256.prefix(8))", isDirectory: true).appendingPathComponent(spec.fileName)
        try await downloader.fetch(spec, to: destination) { done, size in
            progress(.downloading(done: base + done, total: total > 0 ? total : base + size))
        }
        return destination
    }

    private func importInitfs(archive: URL, sha: String, store: ImageStore) async throws -> URL {
        let target = paths.assets.appendingPathComponent("initfs-\(sha.prefix(8)).ext4")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let image = try await load(archive: archive, store: store)
        let initImage = InitImage(image: image)
        let partial = paths.scratch.appendingPathComponent("initfs-\(UUID().uuidString).ext4")
        defer { try? FileManager.default.removeItem(at: partial) }
        do { _ = try await initImage.initBlock(at: partial, for: .linuxArm) } catch {
            throw VZAssetError.importFailed("vminit: \(error)")
        }
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    private func importComputerImage(archive: URL, store: ImageStore) async throws -> (reference: String, digest: String, template: URL) {
        let image = try await load(archive: archive, store: store)
        let directory = paths.templateDirectory(digest: image.digest)
        let template = directory.appendingPathComponent("rootfs.ext4")
        let marker = directory.appendingPathComponent("complete")
        if FileManager.default.fileExists(atPath: marker.path), FileManager.default.fileExists(atPath: template.path) {
            return (image.reference, image.digest, template)
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // 6 GiB esparsos: o conteúdo da imagem (~1,4 GB) mais folga para o que o computador gravar fora dos tmpfs.
            _ = try await EXT4Unpacker(capacityInBytes: 6 << 30).unpack(image, for: .current, at: template)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw VZAssetError.importFailed("computer image: \(error)")
        }
        try Data().write(to: marker)
        return (image.reference, image.digest, template)
    }

    /// Extrai o OCI tar para uma pasta temporária e o carrega no ImageStore (a primeira imagem do índice).
    private func load(archive: URL, store: ImageStore) async throws -> Containerization.Image {
        let scratch = paths.scratch.appendingPathComponent("oci-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // `tar` do sistema (bsdtar): ler OCI tars não justifica linkar o ContainerizationArchive (o módulo libzstd dele não compila no xcodebuild).
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", scratch.path], timeout: .seconds(300)))
        guard result.exitCode == 0 else { throw VZAssetError.importFailed("tar: \(result.stderrString.prefix(200))") }
        let images: [Containerization.Image]
        do { images = try await store.load(from: scratch) } catch { throw VZAssetError.importFailed("\(archive.lastPathComponent): \(error)") }
        guard let image = images.first else { throw VZAssetError.importFailed("\(archive.lastPathComponent) has no image") }
        return image
    }

    /// Apaga templates e downloads de versões antigas (só o que não é o conjunto atual).
    private func collectGarbage(keeping ready: VZReadyAssets) {
        let fm = FileManager.default
        let keepTemplate = ready.template.deletingLastPathComponent().lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: paths.templates.path)) ?? [] where name != keepTemplate {
            try? fm.removeItem(at: paths.templates.appendingPathComponent(name))
        }
        let keepAssets: Set<String> = [
            ready.kernel.deletingLastPathComponent().lastPathComponent, ready.initfs.lastPathComponent, "ready.json",
        ]
        for name in (try? fm.contentsOfDirectory(atPath: paths.assets.path)) ?? [] where !keepAssets.contains(name) {
            try? fm.removeItem(at: paths.assets.appendingPathComponent(name))
        }
    }
}
