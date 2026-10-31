import Foundation

public enum VZManifestError: Error, Equatable, LocalizedError, Sendable {
    case unreadable(String)
    case unsupportedSchema(Int)
    /// O manifesto embutido ainda tem placeholders: nada foi publicado. Em desenvolvimento, aponte `RACKY_VZ_MANIFEST` para um
    /// manifesto local (`scripts/vz/build-image.sh` e `fetch-kernel.sh` geram um).
    case notPublished(String)
    case invalidAsset(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "the computer runtime manifest could not be read (\(detail))"
        case .unsupportedSchema(let version): "the computer runtime manifest has an unsupported schema (\(version))"
        case .notPublished(let asset): "the computer runtime download for \(asset) isn't published yet"
        case .invalidAsset(let detail): "the computer runtime manifest is invalid: \(detail)"
        }
    }
}

/// Um arquivo do runtime: de onde baixar e como conferir.
public struct VZAssetSpec: Codable, Sendable, Equatable {
    /// `https://…`, `file:///…` ou caminho relativo ao manifesto.
    public var url: String
    public var sha256: String
    /// Tamanho em bytes (progresso e conferência rápida antes do hash). `nil` = desconhecido.
    public var size: Int64?
    /// Para imagens OCI: a referência com que o arquivo foi exportado (informativo; a importação lê o índice do próprio arquivo).
    public var reference: String?
    /// Licença e código-fonte (o kernel é GPL-2.0: o manifesto aponta o fonte e o `.config`).
    public var license: String?
    public var sourceURL: String?

    public init(url: String, sha256: String, size: Int64? = nil, reference: String? = nil, license: String? = nil, sourceURL: String? = nil) {
        self.url = url; self.sha256 = sha256; self.size = size; self.reference = reference; self.license = license; self.sourceURL = sourceURL
    }

    /// Placeholder do manifesto embutido: sha256 zerado ou URL com `PLACEHOLDER`.
    public var isPlaceholder: Bool {
        sha256.allSatisfy { $0 == "0" } || url.contains("PLACEHOLDER") || sha256.isEmpty
    }

    /// Nome do arquivo no disco (último componente da URL, só caracteres seguros).
    public var fileName: String {
        let last = URL(string: url)?.lastPathComponent ?? "asset"
        let safe = last.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "asset" : safe
    }
}

/// `runtime/vz-manifest.json`: kernel, vminit e a imagem do computador, cada um com URL e sha256.
public struct VZManifest: Codable, Sendable, Equatable {
    public static let supportedSchema = 1
    public static let environmentKey = "RACKY_VZ_MANIFEST"

    public var schema: Int
    /// Versão do conjunto (muda quando qualquer arquivo muda); entra no estado `ready.json`.
    public var version: String
    public var kernel: VZAssetSpec
    public var vminit: VZAssetSpec
    public var computer: VZAssetSpec

    public init(schema: Int = VZManifest.supportedSchema, version: String, kernel: VZAssetSpec, vminit: VZAssetSpec, computer: VZAssetSpec) {
        self.schema = schema; self.version = version; self.kernel = kernel; self.vminit = vminit; self.computer = computer
    }

    public var assets: [(name: String, spec: VZAssetSpec)] { [("kernel", kernel), ("vminit", vminit), ("computer", computer)] }

    /// Soma dos tamanhos conhecidos (0 se algum é desconhecido).
    public var totalSize: Int64 {
        let sizes = assets.compactMap(\.spec.size)
        return sizes.count == 3 ? sizes.reduce(0, +) : 0
    }

    public static func decode(_ data: Data) throws -> VZManifest {
        let manifest: VZManifest
        do { manifest = try JSONDecoder().decode(VZManifest.self, from: data) } catch { throw VZManifestError.unreadable("\(error)") }
        guard manifest.schema == supportedSchema else { throw VZManifestError.unsupportedSchema(manifest.schema) }
        for (name, spec) in manifest.assets {
            guard spec.sha256.isEmpty || spec.sha256.count == 64, spec.sha256.allSatisfy(\.isHexDigit) else {
                throw VZManifestError.invalidAsset("\(name): sha256 must be 64 hex characters")
            }
        }
        return manifest
    }

    /// Falha com `.notPublished` se algum arquivo ainda é placeholder.
    public func requirePublished() throws {
        for (name, spec) in assets where spec.isPlaceholder { throw VZManifestError.notPublished(name) }
    }

    /// URLs relativas viram absolutas em relação ao manifesto (um manifesto local aponta para os arquivos ao lado dele).
    public func resolved(against manifestURL: URL) -> VZManifest {
        func fix(_ spec: VZAssetSpec) -> VZAssetSpec {
            var spec = spec
            if URL(string: spec.url)?.scheme == nil {
                spec.url = URL(fileURLWithPath: spec.url, relativeTo: manifestURL.deletingLastPathComponent()).standardizedFileURL.absoluteString
            }
            return spec
        }
        var copy = self
        copy.kernel = fix(kernel); copy.vminit = fix(vminit); copy.computer = fix(computer)
        return copy
    }

    /// Onde procurar o manifesto: `RACKY_VZ_MANIFEST` (URL ou caminho), senão `<runtimeRoot>/vz-manifest.json`.
    public static func location(environment: [String: String], runtimeRoot: URL?) -> URL? {
        if let value = environment[environmentKey], !value.isEmpty {
            if let url = URL(string: value), url.scheme != nil { return url }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        guard let runtimeRoot else { return nil }
        let url = runtimeRoot.appendingPathComponent("vz-manifest.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func load(from url: URL) async throws -> VZManifest {
        let data: Data
        do { data = try await URLSession.shared.data(from: url).0 } catch { throw VZManifestError.unreadable("\(url.absoluteString): \(error)") }
        return try decode(data).resolved(against: url)
    }
}
