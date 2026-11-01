import RackyProtocol
import Foundation

/// Nome automático de sessão limpa (P15, 01 §8): adjetivo + substantivo, como `quiet-harbor`. Um gerador só, usado
/// também por worktrees sem prompt. Nunca reaproveita uma pasta que já existe (AC-1102).
public enum SessionNameGenerator {
    public static let adjectives = [
        "quiet", "brave", "amber", "calm", "clever", "crisp", "dusty", "eager", "fancy", "gentle", "golden", "happy",
        "hidden", "icy", "jolly", "keen", "lively", "lucky", "mellow", "misty", "modest", "nimble", "noble", "odd",
        "plain", "proud", "rapid", "rustic", "shiny", "silent", "silver", "smooth", "snowy", "solid", "spry", "steady",
        "sunny", "swift", "tidy", "tiny", "velvet", "vivid", "warm", "wild", "windy", "witty", "young", "zesty",
    ]
    public static let nouns = [
        "harbor", "meadow", "river", "forest", "canyon", "island", "lantern", "valley", "summit", "garden", "ember",
        "falcon", "glacier", "horizon", "iris", "jungle", "kettle", "lagoon", "marble", "nebula", "orchard", "pebble",
        "quarry", "ridge", "saddle", "thicket", "umbra", "village", "willow", "yonder", "zephyr", "anchor", "beacon",
        "bridge", "cedar", "comet", "delta", "dune", "fjord", "grove", "hollow", "inlet", "junction", "knoll", "ledge",
        "mesa", "outpost", "prairie",
    ]

    /// Um nome `adjetivo-substantivo`.
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        "\(adjectives.randomElement(using: &generator)!)-\(nouns.randomElement(using: &generator)!)"
    }

    /// Um nome que não colide: tenta combinações até `attempts` vezes e, se tudo colidir, acrescenta um sufixo.
    public static func unique<G: RandomNumberGenerator>(
        exists: (String) -> Bool, attempts: Int = 64, using generator: inout G
    ) -> String {
        for _ in 0 ..< attempts {
            let candidate = random(using: &generator)
            if !exists(candidate) { return candidate }
        }
        var candidate: String
        repeat {
            candidate = random(using: &generator) + "-" + String(UInt32.random(in: 0 ..< 0xFFFF, using: &generator), radix: 16)
        } while exists(candidate)
        return candidate
    }
}

/// Pastas de sessões limpas no disco (P10): cria sem nunca reaproveitar, move para o Lixo só o que o app criou.
public enum CleanSessionFolders {
    public enum FolderError: Error, Equatable, LocalizedError {
        case notManaged
        case unsafePath(String)

        public var errorDescription: String? {
            switch self {
            case .notManaged: "The folder wasn't created by Racky."
            case .unsafePath(let p): "Refusing to touch \(p)."
            }
        }
    }

    /// Expande `~` e resolve o caminho de configuração (`cleanSessionFolder`).
    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Cria `<root>/<nome-automático>` e devolve a pasta. A criação é atômica (`createDirectory` sem pais): se a pasta
    /// já existe a chamada falha e o gerador escolhe outro nome, então uma pasta existente nunca é reaproveitada.
    public static func createManaged<G: RandomNumberGenerator>(root: URL, using generator: inout G) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var lastError: Error?
        for _ in 0 ..< 200 {
            let name = SessionNameGenerator.unique(exists: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }, using: &generator)
            let url = root.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                lastError = error  // outro processo criou no mesmo instante: tenta de novo
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    public static func createManaged(root: URL) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        return try createManaged(root: root, using: &generator)
    }

    /// Mover para o Lixo do macOS (recuperável).
    public static let systemTrash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Só pasta criada pelo app (`managed`) vai ao Lixo; nunca a home, a raiz do disco ou a própria raiz de sessões.
    public static func trash(
        folder: String, managed: Bool, sessionsRoot: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        mover: (URL) throws -> Void = CleanSessionFolders.systemTrash
    ) throws {
        guard managed else { throw FolderError.notManaged }
        let url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        let forbidden = [URL(fileURLWithPath: "/"), home.standardizedFileURL, sessionsRoot?.standardizedFileURL].compactMap { $0 }
        guard url.pathComponents.count > 2, !forbidden.contains(url) else { throw FolderError.unsafePath(url.path) }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try mover(url)
    }

    /// Run folders de uma sessão: `<runsRoot>/<sessionID>` (e `<sessionID>-*`). Só pastas diretas da raiz de runs.
    public static func runFolders(forSession id: UUID, runsRoot: URL) -> [URL] {
        let key = id.uuidString.lowercased()
        let items = (try? FileManager.default.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil)) ?? []
        return items.filter {
            let name = $0.lastPathComponent.lowercased()
            return name == key || name.hasPrefix(key + "-")
        }
    }

    @discardableResult
    public static func deleteRunFolders(forSession id: UUID, runsRoot: URL) throws -> Int {
        let folders = runFolders(forSession: id, runsRoot: runsRoot)
        for url in folders { try FileManager.default.removeItem(at: url) }
        return folders.count
    }
}

/// Onde ficam as pastas de sessões limpas e os run folders (03 §14.2 "Clean session folder", 01 §6.1).
public enum CleanSessionPaths {
    public static let defaultSessionsSetting = "~/Racky/sessions"

    /// `configured` é o valor de Settings › General. Com o valor padrão e um `RACKY_HOME` isolado (testes, evidência, dev),
    /// as pastas ficam em `<home>/Racky/...` (espelho de `~/Racky`; `<home>/sessions` é do daemon), para nada escapar para a home real. Sem isolamento vale `~/Racky/sessions`.
    public static func sessionsRoot(configured: String, isolatedHome: URL?) -> URL {
        if configured == defaultSessionsSetting, let isolatedHome { return isolatedHome.appendingPathComponent("Racky/sessions", isDirectory: true) }
        return CleanSessionFolders.expand(configured.isEmpty ? defaultSessionsSetting : configured)
    }

    public static let defaultProjectsSetting = "~/Racky/projects"

    /// Pasta de `Clone from GitHub…` (F24). Mesmo isolamento de `RACKY_HOME` das sessões limpas.
    public static func projectsRoot(configured: String, isolatedHome: URL?) -> URL {
        if configured == defaultProjectsSetting || configured.isEmpty, let isolatedHome {
            return isolatedHome.appendingPathComponent("Racky/projects", isDirectory: true)
        }
        return CleanSessionFolders.expand(configured.isEmpty ? defaultProjectsSetting : configured)
    }

    /// `~/Racky/runs` (ou `<RACKY_HOME>/runs` isolado).
    public static func runsRoot(isolatedHome: URL?) -> URL {
        (isolatedHome.map { $0.appendingPathComponent("Racky", isDirectory: true) } ?? CleanSessionFolders.expand("~/Racky")).appendingPathComponent("runs", isDirectory: true)
    }
}

/// Promoção de sessão limpa a projeto (01 §5.3): só liga a sessão ao projeto; nenhum arquivo muda e o processo segue.
public enum SessionPromotion {
    /// `kind` vira `folder`. A pasta passa a pertencer ao projeto, então deixa de ser "gerenciada": apagar a sessão
    /// depois nunca a move para o Lixo.
    public static func attach(_ session: Session, to projectID: UUID) -> Session {
        var copy = session
        copy.projectID = projectID
        copy.kind = .folder
        copy.managedFolder = false
        return copy
    }
}
