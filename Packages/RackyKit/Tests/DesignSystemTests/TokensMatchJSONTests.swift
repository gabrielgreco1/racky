import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import RackyDesignSystem

/// Tokens gerados (`DS.*`, `MotionTokens`, `tokens.js`) = JSON fonte.
@Suite(.tags(.integration), .offscreenAppKit) struct TokensMatchJSONTests {
    @Test func colorsMatchJSON() {
        let (tokens, _) = ColorSource.load()
        #expect(tokens.count == DS.ColorSpec.all.count, "contagem de cores")
        for t in tokens {
            guard let spec = DS.ColorSpec.all[t.name], let hex = HexColor(t.dark) else {
                Issue.record("token de cor ausente ou inválido: \(t.name)")
                continue
            }
            #expect(spec.hex == hex.rgb, "\(t.name) rgb")
            if let b = hex.alphaByte {
                #expect(spec.alphaByte == b, "\(t.name) alfa (byte)")
            } else {
                #expect(spec.alpha == (t.opacity ?? 1), "\(t.name) opacity")
            }
        }
    }

    @Test func appKitAndSwiftUIColorsFollowSpec() {
        for (name, spec) in DS.ColorSpec.all {
            let ns = spec.nsColor.usingColorSpace(.sRGB)
            #expect(ns != nil, "\(name) em sRGB")
            guard let ns else { continue }
            #expect(abs(Double(ns.redComponent) - spec.red) < 1e-6, "\(name) R")
            #expect(abs(Double(ns.greenComponent) - spec.green) < 1e-6, "\(name) G")
            #expect(abs(Double(ns.blueComponent) - spec.blue) < 1e-6, "\(name) B")
            #expect(abs(Double(ns.alphaComponent) - spec.alpha) < 1e-6, "\(name) A")
        }
        #expect(DS.Color.canvas == DS.ColorSpec.canvas.color)
        #expect(DS.NS.canvas.usingColorSpace(.sRGB)?.redComponent == DS.ColorSpec.canvas.nsColor.usingColorSpace(.sRGB)?.redComponent)
    }

    @Test func alphaColorsAreNeverPreMixed() {
        // 02 §2: border = branco com alfa, nunca hex sólido.
        #expect(DS.ColorSpec.border.hex == 0xffffff)
        #expect(DS.ColorSpec.border.alpha < 0.1)
        #expect(DS.ColorSpec.fg8.hex == DS.ColorSpec.textPrimary.hex)
        #expect(DS.ColorSpec.fg8.alpha == 0.08)
    }

    @Test func terminalThemeMatchesJSON() {
        let (_, term) = ColorSource.load()
        func hex(_ key: String) -> UInt32? { HexColor(term[key] as? String ?? "")?.rgb }
        #expect(DS.Terminal.background.hex == hex("background"))
        #expect(DS.Terminal.foreground.hex == hex("foreground"))
        #expect(DS.Terminal.cursor.hex == hex("cursor"))
        #expect(DS.Terminal.cursorText.hex == hex("cursorText"))
        #expect(DS.Terminal.selectionBackground.hex == hex("selectionBackground"))
        let ansi = (term["ansi"] as? [String] ?? []).compactMap { HexColor($0)?.rgb }
        #expect(ansi.count == 16)
        #expect(DS.Terminal.ansi.map(\.hex) == ansi)
        #expect(DS.Terminal.background.hex == DS.ColorSpec.terminalBackground.hex)
    }

    @Test func typographyMatchesJSON() {
        let doc = Repo.json("design/tokens/typography.json")
        let styles = doc["styles"] as? [String: [String: Any]] ?? [:]
        #expect(styles.count == DS.Font.all.count)
        for (name, s) in styles {
            guard let t = DS.Font.all[name] else {
                Issue.record("estilo ausente: \(name)")
                continue
            }
            #expect(Double(t.size) == (s["size"] as? NSNumber)?.doubleValue, "\(name) size")
            #expect(t.weight == (s["weight"] as? NSNumber)?.doubleValue, "\(name) weight")
            #expect(Double(t.lineHeight) == (s["lineHeight"] as? NSNumber)?.doubleValue, "\(name) lineHeight")
            #expect(Double(t.tracking) == (s["tracking"] as? NSNumber)?.doubleValue, "\(name) tracking")
            #expect(t.family == ((s["family"] as? String) == "mono" ? .mono : .ui), "\(name) family")
            #expect(t.tabularDigits == ((s["tabularDigits"] as? Bool) ?? false), "\(name) tabular")
        }
        let term = doc["terminal"] as? [String: Any] ?? [:]
        #expect(Double(DS.TerminalFont.defaultSize) == (term["size"] as? NSNumber)?.doubleValue)
        #expect(DS.TerminalFont.weight == (term["weight"] as? NSNumber)?.doubleValue)
        #expect(DS.TerminalFont.boldWeight == (term["boldWeight"] as? NSNumber)?.doubleValue)
    }

    @Test func spaceAndLayoutMatchJSON() {
        let doc = Repo.json("design/tokens/spacing.json")
        for (group, all) in [("space", DS.Space.all), ("layout", DS.Layout.all)] {
            let src = doc[group] as? [String: NSNumber] ?? [:]
            #expect(src.count == all.count, "\(group) contagem")
            for (k, v) in src { #expect(all[k].map(Double.init) == v.doubleValue, "\(group).\(k)") }
        }
    }

    @Test func radiiMatchJSON() {
        let doc = Repo.json("design/tokens/radii.json")
        let src = doc["radius"] as? [String: NSNumber] ?? [:]
        #expect(src.count == DS.Radius.all.count)
        for (k, v) in src { #expect(DS.Radius.all[k].map(Double.init) == v.doubleValue, "radius.\(k)") }
        #expect(Double(DS.Radius.focusRingOutset) == (doc["focusRingOutset"] as? NSNumber)?.doubleValue)
    }

    @Test func shadowsMatchJSON() {
        let doc = Repo.json("design/tokens/shadows.json")
        let src = doc["shadows"] as? [String: [[String: Any]]] ?? [:]
        #expect(src.count == DS.Shadow.all.count)
        for (name, layers) in src {
            let got = DS.Shadow.all[name]?.layers ?? []
            #expect(got.count == layers.count, "\(name) camadas")
            for (g, l) in zip(got, layers) {
                #expect(g.x == (l["x"] as? NSNumber)?.doubleValue)
                #expect(g.y == (l["y"] as? NSNumber)?.doubleValue)
                #expect(g.blur == (l["blur"] as? NSNumber)?.doubleValue)
                #expect(g.opacity == (l["opacity"] as? NSNumber)?.doubleValue)
                #expect(g.inset == ((l["inset"] as? Bool) ?? false))
                #expect(HexColor(l["color"] as? String ?? "")?.rgb == g.colorHex)
            }
        }
        #expect(DS.Shadow.dialog.layers.first?.radius == 36)
    }

    @Test func motionTypedTokensMatchJSON() {
        let doc = Repo.json("design/motion/tokens.json")
        func numbers(_ key: String) -> [String: Double] {
            (doc[key] as? [String: NSNumber] ?? [:]).mapValues(\.doubleValue)
        }
        #expect(MotionTokens.Duration.all == numbers("duration"))
        #expect(MotionTokens.Distance.all == numbers("distance"))
        #expect(MotionTokens.Scale.all == numbers("scale"))
        #expect(MotionTokens.Opacity.all == numbers("opacity"))
        #expect(MotionTokens.Stroke.all == numbers("stroke"))
        #expect(MotionTokens.Stagger.all == numbers("stagger"))
        #expect(MotionTokens.Delay.all == numbers("delay"))
        #expect(MotionTokens.Policy.all == numbers("policy"))
        let easing = doc["easing"] as? [String: [NSNumber]] ?? [:]
        #expect(easing.count == MotionTokens.Easing.all.count)
        for (k, p) in easing {
            let d = p.map(\.doubleValue)
            #expect(MotionTokens.Easing.all[k] == Bezier(d[0], d[1], d[2], d[3]), "easing.\(k)")
        }
        let springs = doc["spring"] as? [String: [String: NSNumber]] ?? [:]
        #expect(springs.count == MotionTokens.Springs.all.count)
        for (k, p) in springs {
            #expect(MotionTokens.Springs.all[k] == SpringSpec(
                response: p["response"]?.doubleValue ?? -1, dampingFraction: p["dampingFraction"]?.doubleValue ?? -1), "spring.\(k)")
        }
        #expect(MotionTokens.Loop.all.count == (doc["loop"] as? [String: Any])?.count)
        #expect(MotionTokens.Keyframes.all.count == (doc["keyframes"] as? [String: Any])?.count)
        #expect(MotionTokens.Loop.spinner.fps == 12)
        #expect(MotionTokens.Loop.liveBorder.numbers["periodRevoking"] == [1.2])
        #expect(MotionTokens.Keyframes.rimFlash.tracks["opacity"]?.count == 4)
    }

    @Test func motionFlatLeavesMatchJSON() {
        let doc = Repo.json("design/motion/tokens.json")
        var nums: [String: Double] = [:]
        var strs: [String: String] = [:]
        flattenNumbers(doc, into: &nums)
        flattenStrings(doc, into: &strs)
        #expect(MotionTokens.flat == nums)
        #expect(MotionTokens.flatStrings == strs)
        #expect(nums.count > 150)
    }

    /// 04 §9.4 / MA1: tokens.js (usado nos protótipos HTML) tem os mesmos valores do Swift e do JSON.
    @Test func tokensJSMatchesSwiftAndJSON() throws {
        let ctx = try #require(JSContext())
        ctx.evaluateScript("var window = this;")
        ctx.evaluateScript(Repo.text("design/motion/lib/tokens.js"))
        #expect(ctx.exception == nil, "tokens.js deve avaliar sem erro")
        let motion = try #require(ctx.evaluateScript("window.MOTION")?.toDictionary() as? [String: Any])
        var nums: [String: Double] = [:]
        flattenNumbers(motion, into: &nums)
        #expect(nums == MotionTokens.flat, "window.MOTION = MotionTokens.flat")

        let ds = try #require(ctx.evaluateScript("window.DS")?.toDictionary() as? [String: Any])
        let colors = ds["color"] as? [String: [String: Any]] ?? [:]
        #expect(colors.count == DS.ColorSpec.all.count)
        for (name, spec) in DS.ColorSpec.all {
            let c = colors[name]
            #expect(c?["hex"] as? String == spec.hexString, "\(name) hex")
            #expect(abs(((c?["alpha"] as? NSNumber)?.doubleValue ?? -1) - spec.alpha) < 1e-12, "\(name) alpha")
        }
        var dsNums: [String: Double] = [:]
        flattenNumbers(ds["space"] as Any, into: &dsNums)
        for (k, v) in DS.Space.all { #expect(dsNums[k] == Double(v), "js space.\(k)") }
        var radius: [String: Double] = [:]
        flattenNumbers(ds["radius"] as Any, into: &radius)
        for (k, v) in DS.Radius.all { #expect(radius[k] == Double(v), "js radius.\(k)") }
        let fonts = (ds["font"] as? [String: Any])?["styles"] as? [String: [String: Any]] ?? [:]
        #expect(fonts.count == DS.Font.all.count)
        for (k, t) in DS.Font.all {
            #expect((fonts[k]?["size"] as? NSNumber)?.doubleValue == Double(t.size), "js font.\(k).size")
            #expect((fonts[k]?["weight"] as? NSNumber)?.doubleValue == t.weight, "js font.\(k).weight")
        }
    }

    /// O gerador está em dia com o JSON fonte (o mesmo que o CI roda).
    @Test func generatedFilesAreUpToDate() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Repo.root.appendingPathComponent("scripts/gen-tokens.py").path,
                       "--check", "--root", Repo.root.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "gen-tokens.py --check: \(msg)")
    }
}
