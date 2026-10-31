import Foundation

/// Ring de bytes brutos de uma sessão, endereçado por `seq` (offset absoluto desde o início da sessão).
/// Cresce sob demanda até `capacity` (não aloca 32 MiB por sessão de antemão) e depois sobrescreve o mais antigo.
/// O índice físico de `seq` é sempre `seq % capacity`.
public struct RingBuffer: Sendable {
    public let capacity: Int
    private var storage: [UInt8] = []
    public private(set) var endSeq: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Menor `seq` ainda presente.
    public var startSeq: UInt64 { endSeq > UInt64(capacity) ? endSeq - UInt64(capacity) : 0 }
    public var count: Int { Int(endSeq - startSeq) }

    public mutating func append(_ bytes: [UInt8]) {
        var chunk = bytes[...]
        if chunk.count > capacity {
            // Só os últimos `capacity` bytes cabem; `endSeq` ainda avança pelo total.
            let skipped = chunk.count - capacity
            endSeq += UInt64(skipped)
            chunk = chunk.dropFirst(skipped)
        }
        var offset = chunk.startIndex
        while offset < chunk.endIndex {
            let position = Int(endSeq % UInt64(capacity))
            let take = min(chunk.endIndex - offset, capacity - position)
            let piece = chunk[offset ..< offset + take]
            if position == storage.count {
                storage.append(contentsOf: piece)  // fase linear, antes da primeira volta
            } else {
                if storage.count < position + take {
                    // Primeira volta incompleta com salto de `skipped`: completa com zeros até a posição.
                    storage.append(contentsOf: [UInt8](repeating: 0, count: position + take - storage.count))
                }
                storage.replaceSubrange(position ..< position + take, with: piece)
            }
            offset += take
            endSeq += UInt64(take)
        }
    }

    /// Bytes de `from` a `to` (exclusivo). Faixa fora do ring é ajustada ao que existe.
    public func read(from: UInt64, to: UInt64) -> [UInt8] {
        let lower = max(from, startSeq)
        let upper = min(to, endSeq)
        guard lower < upper else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(Int(upper - lower))
        var seq = lower
        while seq < upper {
            let position = Int(seq % UInt64(capacity))
            let take = min(Int(upper - seq), capacity - position)
            out.append(contentsOf: storage[position ..< position + take])
            seq += UInt64(take)
        }
        return out
    }
}
