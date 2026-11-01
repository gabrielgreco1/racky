import RackyCore
import RackyDesignSystem
import Foundation

extension InsightsProvider {
    var agentKind: DSAgentKind { self == .claude ? DSAgentKind.claude : DSAgentKind.codex }
}

/// Formatação dos números do módulo Insights (pura, testável). Inglês, como toda a UI (P2).
nonisolated enum InsightsFormat {
    /// `842`, `12.3K`, `27.2M`, `1.30B`.
    static func tokens(_ n: Int) -> String {
        let v = Double(max(0, n))
        switch v {
        case ..<1_000: return "\(Int(v))"
        case ..<10_000: return trim(v / 1_000, 2) + "K"
        case ..<1_000_000: return trim(v / 1_000, 1) + "K"
        case ..<10_000_000: return trim(v / 1_000_000, 2) + "M"
        case ..<1_000_000_000: return trim(v / 1_000_000, 1) + "M"
        default: return trim(v / 1_000_000_000, 2) + "B"
        }
    }

    /// `$0.42`, `$71`, `$1.9K`.
    static func cost(_ usd: Double) -> String {
        let v = max(0, usd)
        switch v {
        case ..<10: return "$" + String(format: "%.2f", v)
        case ..<1_000: return "$" + String(format: "%.0f", v)
        default: return "$" + trim(v / 1_000, 1) + "K"
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded()))%"
    }

    /// Bytes em unidades binárias: `812 MB`, `3.4 GB`, `1.2 TB`.
    static func bytes(_ n: UInt64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_048_576: return "\(Int((v / 1024).rounded())) KB"
        case ..<1_073_741_824: return "\(Int((v / 1_048_576).rounded())) MB"
        case ..<1_099_511_627_776: return trim(v / 1_073_741_824, v / 1_073_741_824 < 10 ? 1 : 0) + " GB"
        default: return trim(v / 1_099_511_627_776, 1) + " TB"
        }
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        switch v {
        case ..<1_024: return "\(Int(v)) B/s"
        case ..<1_048_576: return "\(Int((v / 1_024).rounded())) KB/s"
        case ..<1_073_741_824: return trim(v / 1_048_576, 1) + " MB/s"
        default: return trim(v / 1_073_741_824, 2) + " GB/s"
        }
    }

    /// `45s`, `12m`, `2h 41m`, `3d 4h`.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h \((s % 3_600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3_600)h"
    }

    /// Tempo relativo curto: `now`, `12m`, `3h`, `5d`.
    static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }

    /// Custo em micros de dólar (proxies).
    static func micros(_ micros: Int64) -> String { cost(Double(micros) / 1_000_000) }

    /// Nome de modelo curto para a lista: `claude-opus-5-5` → `opus-5-5`, `gpt-6.1-sol` fica.
    static func modelName(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func trim(_ v: Double, _ decimals: Int) -> String {
        let s = String(format: "%.\(decimals)f", v)
        guard s.contains(".") else { return s }
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// Nível 0…4 de intensidade do heatmap (0 = vazio). Escala por raiz para que horas leves ainda apareçam.
    static func heatLevel(_ value: Double, max maxValue: Double) -> Int {
        guard value > 0, maxValue > 0 else { return 0 }
        let r = (value / maxValue).squareRoot()
        return min(4, max(1, Int((r * 4).rounded(.up))))
    }
}
