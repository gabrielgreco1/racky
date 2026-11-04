import Foundation

/// Avatar SVG determinístico, sorteado pelo nome. É a mesma função de `docs/design/agents.html` (só inteiros), então a mesma
/// entrada gera exatamente a mesma string nos dois lados.
public enum AgentAvatarGenerator {
    static let backgrounds = ["#4a4038", "#3c4a41", "#4a3c42", "#46463a", "#3a4348", "#4d4338", "#40384a", "#44403c"]
    static let skins = ["#e8d9c4", "#d9c3a5", "#c9b79c", "#e4cfc0", "#b8a58f", "#d6d0c4"]
    static let ink = "#22201e"

    struct Rng {
        var s: UInt32
        init(seed: String) {
            var h: UInt32 = 2_166_136_261
            for b in seed.utf8 { h ^= UInt32(b); h = h &* 16_777_619 }
            s = h == 0 ? 1 : h
            for _ in 0..<3 { _ = next() }
        }
        mutating func next() -> UInt32 {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            return s
        }
        mutating func pick(_ n: Int) -> Int { Int(next() % UInt32(n)) }
    }

    public static func svg(name: String, variant: Int = 0) -> String {
        var r = Rng(seed: "\(name)#\(variant)")
        let bg = backgrounds[r.pick(8)], skin = skins[r.pick(6)]
        let shoulders = r.pick(3), head = r.pick(4), eyes = r.pick(4), acc = r.pick(6), mouth = r.pick(3)
        let cx = 32 + r.pick(5) - 2
        let i = ink
        var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" fill=\"\(bg)\"/>"
        switch shoulders {
        case 0: o += "<ellipse cx=\"32\" cy=\"68\" rx=\"26\" ry=\"20\" fill=\"\(skin)\"/>"
        case 1: o += "<rect x=\"8\" y=\"50\" width=\"48\" height=\"30\" rx=\"14\" fill=\"\(skin)\"/>"
        default: o += "<path d=\"M4 64L12 53Q32 45 52 53L60 64Z\" fill=\"\(skin)\"/>"
        }
        switch head {
        case 0: o += "<circle cx=\"\(cx)\" cy=\"28\" r=\"13\" fill=\"\(skin)\"/>"
        case 1: o += "<rect x=\"\(cx - 12)\" y=\"15\" width=\"24\" height=\"28\" rx=\"9\" fill=\"\(skin)\"/>"
        case 2: o += "<ellipse cx=\"\(cx)\" cy=\"29\" rx=\"11\" ry=\"15\" fill=\"\(skin)\"/>"
        default: o += "<path d=\"M\(cx - 12) 43V27a12 12 0 0 1 24 0V43Z\" fill=\"\(skin)\"/>"
        }
        switch eyes {
        case 0: o += "<circle cx=\"\(cx - 5)\" cy=\"29\" r=\"2\" fill=\"\(i)\"/><circle cx=\"\(cx + 5)\" cy=\"29\" r=\"2\" fill=\"\(i)\"/>"
        case 1: o += "<rect x=\"\(cx - 8)\" y=\"28\" width=\"5\" height=\"2\" rx=\"1\" fill=\"\(i)\"/><rect x=\"\(cx + 3)\" y=\"28\" width=\"5\" height=\"2\" rx=\"1\" fill=\"\(i)\"/>"
        case 2: o += "<rect x=\"\(cx - 9)\" y=\"27\" width=\"18\" height=\"4\" rx=\"2\" fill=\"\(i)\"/>"
        default: o += "<circle cx=\"\(cx - 5)\" cy=\"29\" r=\"2\" fill=\"\(i)\"/><circle cx=\"\(cx + 5)\" cy=\"29\" r=\"3\" fill=\"\(i)\"/>"
        }
        if mouth == 1 {
            o += "<rect x=\"\(cx - 3)\" y=\"37\" width=\"6\" height=\"2\" rx=\"1\" fill=\"\(i)\"/>"
        } else if mouth == 2 {
            o += "<path d=\"M\(cx - 4) 36Q\(cx) 40 \(cx + 4) 36\" fill=\"none\" stroke=\"\(i)\" stroke-width=\"2\"/>"
        }
        switch acc {
        case 1:
            o += "<circle cx=\"\(cx - 5)\" cy=\"29\" r=\"4\" fill=\"none\" stroke=\"\(i)\" stroke-width=\"2\"/>"
            o += "<circle cx=\"\(cx + 5)\" cy=\"29\" r=\"4\" fill=\"none\" stroke=\"\(i)\" stroke-width=\"2\"/>"
            o += "<rect x=\"\(cx - 1)\" y=\"28\" width=\"2\" height=\"2\" fill=\"\(i)\"/>"
        case 2:
            o += "<rect x=\"\(cx - 10)\" y=\"25\" width=\"8\" height=\"7\" rx=\"1\" fill=\"none\" stroke=\"\(i)\" stroke-width=\"2\"/>"
            o += "<rect x=\"\(cx + 2)\" y=\"25\" width=\"8\" height=\"7\" rx=\"1\" fill=\"none\" stroke=\"\(i)\" stroke-width=\"2\"/>"
        case 3: o += "<ellipse cx=\"\(cx)\" cy=\"19\" rx=\"14\" ry=\"7\" fill=\"\(i)\"/>"
        case 4: o += "<rect x=\"\(cx - 13)\" y=\"20\" width=\"26\" height=\"4\" fill=\"\(backgrounds[r.pick(8)])\"/>"
        case 5: o += "<path d=\"M\(cx - 13) 26V20Q\(cx) 8 \(cx + 13) 20V24Q\(cx) 18 \(cx - 13) 26Z\" fill=\"\(i)\"/>"
        default: break
        }
        return o + "</svg>"
    }
}
