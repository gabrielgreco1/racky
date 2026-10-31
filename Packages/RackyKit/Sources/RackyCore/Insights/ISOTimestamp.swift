import Foundation

/// Parser de timestamps ISO-8601 sem `ISO8601DateFormatter` (não é `Sendable` e é lento em arquivos de centenas de MB).
public enum ISOTimestamp {
    /// Aceita `2026-10-17T08:35:30.006Z` e deslocamentos `+hh:mm`. Qualquer outra forma devolve `nil`.
    public static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            var v = 0
            for _ in 0..<n {
                guard i < b.count, b[i] >= 48, b[i] <= 57 else { return nil }
                v = v * 10 + Int(b[i] - 48)
                i += 1
            }
            return v
        }
        func expect(_ ch: UInt8) -> Bool {
            guard i < b.count, b[i] == ch else { return false }
            i += 1
            return true
        }
        guard let y = digits(4), expect(45), let mo = digits(2), expect(45), let d = digits(2),
              i < b.count, b[i] == 84 || b[i] == 32 else { return nil }
        i += 1
        guard let h = digits(2), expect(58), let mi = digits(2), expect(58), let sec = digits(2) else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count, b[i] == 43 || b[i] == 45 {
            let sign = b[i] == 45 ? -1 : 1
            i += 1
            guard let oh = digits(2) else { return nil }
            _ = expect(58)
            let om = digits(2) ?? 0
            offset = (oh * 3600 + om * 60) * sign
        } else if i < b.count, b[i] == 90 {
            i += 1
        } else if i < b.count {
            return nil
        }
        let days = daysFromCivil(y, mo, d)
        let seconds = Double(days) * 86_400 + Double(h * 3600 + mi * 60 + sec - offset) + frac
        return Date(timeIntervalSince1970: seconds)
    }

    /// Algoritmo de Howard Hinnant (dias desde 1970-01-01).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
