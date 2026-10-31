import Foundation
import RackyProtocol

/// Labels de todos os recursos Docker do app (07 CS-115, 08 §0).
public enum RackyLabel {
    public static let owner = "racky.owner"
    public static let computer = "racky.computer"
    public static let computerName = "racky.computer_name"
    public static let session = "racky.session"
    public static let run = "racky.run"
    public static let batch = "racky.batch"
    public static let role = "racky.role"
    public static let ephemeral = "racky.ephemeral"
    public static let imageDigest = "racky.image_digest"
    /// Marca recursos criados por testes. Testes só tocam em recursos com `racky.test=1`.
    public static let test = "racky.test"
    public static let contextHash = "racky.context_hash"
}

extension RackyLabel {
    /// Valor do label `key`.
    public static func value(_ key: String, in labels: [String: String]) -> String? {
        labels[key]
    }

    /// O recurso pertence a `ownerValue` (valor atual do owner).
    public static func isOwned(by ownerValue: String, labels: [String: String]) -> Bool {
        labels[owner] == ownerValue
    }
}

/// P24: um computador é UM container (`computer`). Os demais valores existem só para ler labels de computadores criados antes
/// da P24 (runtime/work/egress) e para o diretório de segredos de tarefa (`work`); nenhum container novo os usa.
public enum ComputerRole: String, Sendable, CaseIterable {
    case computer, runtime, work, egress, agent
}

/// Montagem dos labels e dos nomes determinísticos de um computador (07 CS-115/CS-116).
public struct ComputerLabels: Sendable, Equatable {
    public var owner: String
    public var computerID: String
    public var computerName: String
    public var session: String?
    public var run: String?
    public var batch: String?
    public var ephemeral: Bool
    public var imageDigest: String?
    public var isTest: Bool

    public init(owner: String, computerID: String, computerName: String, session: String? = nil, run: String? = nil,
                batch: String? = nil, ephemeral: Bool = true, imageDigest: String? = nil, isTest: Bool = false) {
        self.owner = owner
        self.computerID = computerID
        self.computerName = computerName
        self.session = session
        self.run = run
        self.batch = batch
        self.ephemeral = ephemeral
        self.imageDigest = imageDigest
        self.isTest = isTest
    }

    public func labels(role: ComputerRole?) -> [String: String] {
        var result: [String: String] = [
            RackyLabel.owner: owner, RackyLabel.computer: computerID, RackyLabel.computerName: computerName,
            RackyLabel.ephemeral: ephemeral ? "true" : "false",
        ]
        if let role { result[RackyLabel.role] = role.rawValue }
        if let session { result[RackyLabel.session] = session }
        if let run { result[RackyLabel.run] = run }
        if let batch { result[RackyLabel.batch] = batch }
        if let imageDigest { result[RackyLabel.imageDigest] = imageDigest }
        if isTest { result[RackyLabel.test] = "1" }
        return result
    }

    /// `ab-<computerId8>`.
    public var shortID: String { String(computerID.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }
    /// Nome do container único do computador (P24).
    public var containerName: String { "ab-\(shortID)" }
    /// Nome da rede criada por computadores anteriores à P24 (só para o GC por label reconhecer o legado).
    public var legacyNetworkName: String { "racky-net-\(computerID)" }
}
