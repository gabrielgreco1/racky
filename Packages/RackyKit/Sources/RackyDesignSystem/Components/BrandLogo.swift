import AppKit
import SwiftUI

/// Marca de um lugar de dados (banco, warehouse, storage, planilha, webhook): o logo na cor da marca, sozinho ou num ladrilho
/// neutro. Os SVGs vêm da Simple Icons (CC0) e da Devicon (MIT); `sources.json` guarda a origem.
public enum DSDataBrand: String, CaseIterable, Sendable {
    case postgres, supabase, mysql, sqlServer, sqlite
    case bigQuery, snowflake, clickHouse, databricks
    case s3, gcs, r2
    case googleSheets, airtable
    case webhook
    case prefect

    var file: String? {
        switch self {
        case .postgres: "data-postgresql"
        case .supabase: "data-supabase"
        case .mysql: "data-mysql"
        case .sqlServer: "data-microsoftsqlserver"
        case .sqlite: "data-sqlite"
        case .bigQuery: "data-googlebigquery"
        case .snowflake: "data-snowflake"
        case .clickHouse: "data-clickhouse"
        case .databricks: "data-databricks"
        case .s3: "data-amazons3"
        case .gcs: "data-googlecloudstorage"
        case .r2: "data-cloudflare"
        case .googleSheets: "data-googlesheets"
        case .airtable: "data-airtable"
        case .webhook: nil
        case .prefect: "data-prefect"
        }
    }

    /// Cor da marca; as muito escuras (SQLite) clareadas para aparecer no fundo escuro.
    public var color: Color {
        let hex: UInt32 = switch self {
        case .postgres: 0x6B8FEF
        case .supabase: 0x3FCF8E
        case .mysql: 0x5D96C8
        case .sqlServer: 0xE0484B
        case .sqlite: 0x5AA4D6
        case .bigQuery: 0x669DF6
        case .snowflake: 0x29B5E8
        case .clickHouse: 0xFFCC01
        case .databricks: 0xFF3621
        case .s3: 0x6DBE45
        case .gcs: 0xAECBFA
        case .r2: 0xF38020
        case .googleSheets: 0x34A853
        case .airtable: 0x18BFFF
        case .webhook: 0xD5568C
        case .prefect: 0x7DA2F5
        }
        return DSRGBA(hex: hex).color
    }
}

public struct DSDataLogo: View {
    private let brand: DSDataBrand
    private let size: CGFloat
    private let tile: Bool

    /// `tile`: o logo num quadrado arredondado com o fundo da marca (explorer, Add connection); sem ele, só o logo.
    public init(_ brand: DSDataBrand, size: CGFloat, tile: Bool = false) {
        self.brand = brand
        self.size = size
        self.tile = tile
    }

    public var body: some View {
        Group {
            if tile {
                // Ladrilho neutro: a cor é só do logo, nunca do fundo (sem brilho nem tinta).
                mark(size: size * 0.6)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.24).fill(DS.Color.secondary))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(DS.Color.border))
            } else {
                mark(size: size)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func mark(size: CGFloat) -> some View {
        if let image = DSDataLogoImages.image(brand) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .foregroundStyle(brand.color)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: size * 0.82, weight: .semibold))
                .foregroundStyle(brand.color)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum DSDataLogoImages {
    private static var cache: [DSDataBrand: NSImage] = [:]

    static func image(_ brand: DSDataBrand) -> NSImage? {
        if let cached = cache[brand] { return cached }
        guard let file = brand.file, let url = Bundle.module.url(forResource: file, withExtension: "svg", subdirectory: "AgentLogos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[brand] = image
        return image
    }
}

/// Provedor de proxy (Zyte, Bright Data…): o ícone oficial do site de cada um (`proxy-*.png`, origem em `sources.json`). O app
/// reconhece o provedor pelo host ou pelo nome do proxy; sem match, `nil` e a UI mostra o ícone de rede.
public enum DSProxyBrand: String, CaseIterable, Sendable {
    case zyte, brightData, oxylabs, decodo, iproyal, webshare, soax

    public var title: String {
        switch self {
        case .zyte: "Zyte"
        case .brightData: "Bright Data"
        case .oxylabs: "Oxylabs"
        case .decodo: "Decodo"
        case .iproyal: "IPRoyal"
        case .webshare: "Webshare"
        case .soax: "SOAX"
        }
    }

    var file: String {
        switch self {
        case .brightData: "proxy-brightdata"
        default: "proxy-\(rawValue)"
        }
    }

    /// `brd.superproxy.io` → Bright Data, `gate.smartproxy.com` → Decodo, `api.zyte.com` → Zyte…
    public static func detect(_ hints: String...) -> DSProxyBrand? {
        let text = hints.joined(separator: " ").lowercased()
        let marks: [(DSProxyBrand, [String])] = [
            (.zyte, ["zyte", "crawlera", "scrapinghub"]), (.brightData, ["brightdata", "bright data", "superproxy", "luminati", "brd."]),
            (.oxylabs, ["oxylabs"]), (.decodo, ["decodo", "smartproxy"]), (.iproyal, ["iproyal"]), (.webshare, ["webshare"]), (.soax, ["soax"]),
        ]
        return marks.first { $0.1.contains { text.contains($0) } }?.0
    }
}

/// O ícone do provedor com os cantos arredondados (o desenho e as cores são da marca).
public struct DSProxyLogo: View {
    private let brand: DSProxyBrand
    private let size: CGFloat

    public init(_ brand: DSProxyBrand, size: CGFloat) {
        self.brand = brand
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = DSProxyLogoImages.image(brand) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "network").foregroundStyle(DS.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }
}

@MainActor
enum DSProxyLogoImages {
    private static var cache: [DSProxyBrand: NSImage] = [:]

    static func image(_ brand: DSProxyBrand) -> NSImage? {
        if let cached = cache[brand] { return cached }
        guard let url = Bundle.module.url(forResource: brand.file, withExtension: "png", subdirectory: "AgentLogos"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[brand] = image
        return image
    }
}
