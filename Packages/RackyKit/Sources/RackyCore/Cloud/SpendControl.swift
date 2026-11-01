import Foundation

/// Tetos de gasto definidos PELO USUÁRIO (P27.3). `nil` = sem teto naquela janela.
public struct SpendCaps: Sendable, Equatable, Codable {
    public var dailyUSD: Double?
    public var monthlyUSD: Double?
    public init(dailyUSD: Double? = nil, monthlyUSD: Double? = nil) { self.dailyUSD = dailyUSD; self.monthlyUSD = monthlyUSD }
}

public enum SpendWindow: String, Sendable, Equatable { case daily, monthly }

public struct SpendDenial: Sendable, Equatable {
    public var window: SpendWindow
    public var capUSD: Double
    public var projectedUSD: Double
    public init(window: SpendWindow, capUSD: Double, projectedUSD: Double) { self.window = window; self.capUSD = capUSD; self.projectedUSD = projectedUSD }
}

/// Um host que gastou (ou está gastando). `expiresAt` é o limite duro da VM (vida máxima): a projeção nunca passa dele.
public struct SpendRecord: Sendable, Equatable, Codable {
    public var hostID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var expiresAt: Date
    public var hourlyUSD: Double
    /// Para o histórico de custo na tela (registros antigos não têm).
    public var region: String?
    public var shape: String?
    public var provider: String?
    public init(
        hostID: String, startedAt: Date, endedAt: Date? = nil, expiresAt: Date, hourlyUSD: Double, region: String? = nil, shape: String? = nil,
        provider: String? = nil
    ) {
        self.hostID = hostID; self.startedAt = startedAt; self.endedAt = endedAt; self.expiresAt = expiresAt; self.hourlyUSD = hourlyUSD
        self.region = region; self.shape = shape; self.provider = provider
    }

    /// Custo estimado até `now` (ou até o fim), sem passar da vida máxima.
    public func costUSD(now: Date) -> Double {
        hourlyUSD * max(0, min(endedAt ?? now, now, expiresAt).timeIntervalSince(startedAt)) / 3600
    }
}

/// Livro-caixa local de gasto estimado (a conta real vem do Cost Explorer, atrasada, só para reconciliar).
public struct SpendLedger: Sendable, Equatable, Codable {
    public private(set) var records: [SpendRecord] = []
    public init(records: [SpendRecord] = []) { self.records = records }

    /// Descarta o que terminou antes de `date` (as janelas vão até um mês; o arquivo não cresce para sempre).
    public mutating func prune(endedBefore date: Date) { records.removeAll { ($0.endedAt ?? .distantFuture) < date } }

    public mutating func open(_ record: SpendRecord) { records.removeAll { $0.hostID == record.hostID }; records.append(record) }
    /// Remove a reserva de um host que não chegou a subir (a criação falhou): não conta no gasto.
    public mutating func discard(hostID: String) { records.removeAll { $0.hostID == hostID } }
    public mutating func close(hostID: String, at date: Date) {
        for index in records.indices where records[index].hostID == hostID && records[index].endedAt == nil { records[index].endedAt = date }
    }

    private static func overlap(_ a: Date, _ b: Date, in window: DateInterval) -> Double {
        max(0, min(b, window.end).timeIntervalSince(max(a, window.start)))
    }

    /// Gasto acumulado até `now` na janela (o que já foi consumido). A VM se apaga em `expiresAt`, então nada conta depois disso.
    public func accrued(in window: DateInterval, now: Date) -> Double {
        records.reduce(0) { $0 + $1.hourlyUSD * Self.overlap($1.startedAt, min($1.endedAt ?? now, now, $1.expiresAt), in: window) / 3600 }
    }

    /// Gasto acumulado + o que os hosts abertos ainda vão consumir até `expiresAt` dentro da janela.
    public func projected(in window: DateInterval, now: Date) -> Double {
        records.reduce(0) { total, record in
            let end = record.endedAt ?? max(record.expiresAt, now)
            return total + record.hourlyUSD * Self.overlap(record.startedAt, end, in: window) / 3600
        }
    }
}

/// Aplica os tetos: antes de criar (projeção com o host novo) e durante (acumulado já estourou).
public struct SpendGuard: Sendable {
    public var caps: SpendCaps
    public var calendar: Calendar

    public init(caps: SpendCaps, calendar: Calendar = .current) { self.caps = caps; self.calendar = calendar }

    func windows(now: Date) -> [(SpendWindow, Double, DateInterval)] {
        var result: [(SpendWindow, Double, DateInterval)] = []
        if let cap = caps.dailyUSD, let day = calendar.dateInterval(of: .day, for: now) { result.append((.daily, cap, day)) }
        if let cap = caps.monthlyUSD, let month = calendar.dateInterval(of: .month, for: now) { result.append((.monthly, cap, month)) }
        return result
    }

    /// Nega se a projeção (tudo que já corre + o host novo até o fim da vida máxima) passa de algum teto.
    public func evaluate(newHost: SpendRecord, ledger: SpendLedger, now: Date) -> SpendDenial? {
        var trial = ledger
        trial.open(newHost)
        for (window, cap, interval) in windows(now: now) {
            let projected = trial.projected(in: interval, now: now)
            if projected > cap { return SpendDenial(window: window, capUSD: cap, projectedUSD: projected) }
        }
        return nil
    }

    /// Durante: o ACUMULADO já passou de um teto -> encerrar tudo que gasta.
    public func breach(ledger: SpendLedger, now: Date) -> SpendDenial? {
        for (window, cap, interval) in windows(now: now) {
            let accrued = ledger.accrued(in: interval, now: now)
            if accrued >= cap { return SpendDenial(window: window, capUSD: cap, projectedUSD: accrued) }
        }
        return nil
    }
}
