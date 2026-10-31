import Foundation

/// Ponto onde um replay pode começar: corte (sequência de limpeza/alt-screen) ou checkpoint periódico.
public struct ReplayPoint: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case cut, checkpoint }
    public var seq: UInt64
    public var state: ModeState
    public var kind: Kind
}

/// Escolha do início do replay (06 §1.5 com os checkpoints do S-04):
/// corte mais recente no ring; senão checkpoint mais antigo no ring (precedido de `ESC c` e do preâmbulo);
/// senão o início do ring precedido de `ESC c`.
public struct ReplayIndex: Sendable {
    public static let checkpointInterval: UInt64 = 64 << 10

    public private(set) var lastCut: ReplayPoint?
    public private(set) var checkpoints: [ReplayPoint] = []
    private var lastCheckpointSeq: UInt64 = 0

    public init() {}

    public mutating func recordCut(_ cut: CutEvent) {
        lastCut = ReplayPoint(seq: cut.seq, state: cut.before, kind: .cut)
    }

    /// `true` quando é hora de gravar um checkpoint em `seq` (parser fora de sequência).
    public func wantsCheckpoint(at seq: UInt64, parserIsNormal: Bool) -> Bool {
        parserIsNormal && seq - lastCheckpointSeq >= Self.checkpointInterval
    }

    public mutating func recordCheckpoint(seq: UInt64, state: ModeState) {
        checkpoints.append(ReplayPoint(seq: seq, state: state, kind: .checkpoint))
        lastCheckpointSeq = seq
    }

    public mutating func prune(ringStart: UInt64) {
        if let cut = lastCut, cut.seq < ringStart { lastCut = nil }
        checkpoints.removeAll { $0.seq < ringStart }
    }

    /// `nil`: nenhum ponto no ring (replay do início do ring com `ESC c`).
    public func choose(ringStart: UInt64) -> ReplayPoint? {
        if let cut = lastCut, cut.seq >= ringStart { return cut }
        return checkpoints.first { $0.seq >= ringStart }
    }
}
