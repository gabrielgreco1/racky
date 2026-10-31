import Foundation

/// Onde obter a imagem de um papel: digest no GHCR (caminho rápido) ou build local do contexto embutido (07 CS-121).
public struct ImageSource: Sendable, Equatable {
    /// Repositório local da tag por hash de conteúdo (`racky-box`).
    public var repository: String
    /// Contexto de build (diretório com o Dockerfile), embutido no bundle do app.
    public var contextDirectory: URL
    /// `ghcr.io/<owner>/racky-box`. Com `digest`, o pull é por digest.
    public var ghcrRepository: String?
    /// `sha256:...` embutido no app. `nil` enquanto a imagem não foi publicada: só o build local.
    public var digest: String?
    public var dockerfile: String
    /// Labels extras gravados na imagem (testes usam `racky.test=1`).
    public var extraLabels: [String: String]
    public var buildArgs: [String: String]

    public init(repository: String, contextDirectory: URL, ghcrRepository: String? = nil, digest: String? = nil,
                dockerfile: String = "Dockerfile", extraLabels: [String: String] = [:], buildArgs: [String: String] = [:]) {
        self.repository = repository
        self.contextDirectory = contextDirectory
        self.ghcrRepository = ghcrRepository
        self.digest = digest
        self.dockerfile = dockerfile
        self.extraLabels = extraLabels
        self.buildArgs = buildArgs
    }
}

public enum ImageAcquisition: Sendable, Equatable {
    case alreadyPresent, pulled, built
}

public struct EnsuredImage: Sendable, Equatable {
    public var tag: String
    public var imageID: String
    public var acquisition: ImageAcquisition
    public var contextHash: String
}

/// Progresso exibido na UI (`"Building computer image… 2 of 14 steps"`).
public enum ImageProgress: Sendable, Equatable {
    case pulling(layersDone: Int, layersTotal: Int, status: String)
    case building(step: Int, of: Int)
    case log(String)
}

public struct ImageManager: Sendable {
    public let client: DockerClient

    public init(client: DockerClient) { self.client = client }

    /// Garante que a imagem esperada (tag por hash do contexto) exista no daemon: presente, `pull` por digest ou build local.
    public func ensure(_ source: ImageSource, onProgress: (@Sendable (ImageProgress) -> Void)? = nil) async throws -> EnsuredImage {
        let hash = try BuildContext.contentHash(of: source.contextDirectory)
        let tag = BuildContext.tag(repository: source.repository, hash: hash)

        if let existing = try await client.imageIfPresent(tag) {
            return EnsuredImage(tag: tag, imageID: existing.id, acquisition: .alreadyPresent, contextHash: hash)
        }
        if let ghcr = source.ghcrRepository, let digest = source.digest {
            let reference = "\(ghcr)@\(digest)"
            do {
                try await pull(reference, onProgress: onProgress)
                let pulled = try await client.inspectImage(reference)
                // A imagem publicada precisa ter sido construída do mesmo contexto; senão é de outra versão do app.
                if let label = pulled.labels[RackyLabel.contextHash], label != hash {
                    throw DockerError.imageUnavailable("digest \(digest) foi construído de outro contexto")
                }
                try await client.tagImage(reference, repository: source.repository, tag: "ctx-\(hash.prefix(12))")
                return EnsuredImage(tag: tag, imageID: pulled.id, acquisition: .pulled, contextHash: hash)
            } catch let error as DockerError where error.isRuntimeUnavailable {
                throw error
            } catch is CancellationError {
                throw DockerError.cancelled
            } catch let error as DockerError where error == .cancelled {
                throw error
            } catch {
                // Rede, autenticação ou digest ausente: cai para o build local.
                onProgress?(.log("pull falhou (\(error)); construindo localmente"))
            }
        }
        let id = try await build(source, tag: tag, hash: hash, onProgress: onProgress)
        return EnsuredImage(tag: tag, imageID: id, acquisition: .built, contextHash: hash)
    }

    /// Remove as outras tags `<repository>:ctx-*` (versões anteriores do contexto). Só imagens cujas tags são todas desse repositório,
    /// sem `force`: uma imagem ainda usada por um container fica. Devolve quantas saíram.
    @discardableResult
    public func removeOtherTags(repository: String, keeping tag: String) async -> Int {
        guard let images = try? await client.listImages(filters: ["reference": [repository]]) else { return 0 }
        var removed = 0
        for image in images where !image.repoTags.isEmpty && !image.repoTags.contains(tag)
            && image.repoTags.allSatisfy({ $0.hasPrefix("\(repository):ctx-") }) {
            if (try? await client.removeImage(image.id)) != nil { removed += 1 }
        }
        return removed
    }

    func pull(_ reference: String, onProgress: (@Sendable (ImageProgress) -> Void)?) async throws {
        var done = Set<String>(), seen = Set<String>()
        for try await event in try await client.pullImage(reference) {
            guard let id = event.id, let status = event.status else { continue }
            seen.insert(id)
            if status == "Pull complete" || status == "Already exists" { done.insert(id) }
            onProgress?(.pulling(layersDone: done.count, layersTotal: seen.count, status: status))
        }
    }

    func build(_ source: ImageSource, tag: String, hash: String, onProgress: (@Sendable (ImageProgress) -> Void)?) async throws -> String {
        let context = try BuildContext.tar(of: source.contextDirectory)
        var labels = source.extraLabels
        labels[RackyLabel.contextHash] = hash
        var imageID: String?
        for try await event in try await client.buildImage(
            context: context, tag: tag, dockerfile: source.dockerfile, labels: labels, buildArgs: source.buildArgs) {
            if let step = event.step { onProgress?(.building(step: step.index, of: step.total)) }
            if let line = event.stream?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { onProgress?(.log(line)) }
            if let id = event.imageID { imageID = id }
        }
        let image = try await client.inspectImage(tag)
        return imageID ?? image.id
    }
}
