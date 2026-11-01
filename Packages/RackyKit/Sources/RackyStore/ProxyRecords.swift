import RackyProtocol
import Foundation
import GRDB

// Records do proxy (T3-02): `proxy` (v3_computers), `proxy_ext` (v5_proxy_ext). Internos; a API pública usa `ProxyProfile`.

struct ProxyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "proxy"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var name: String
    var preset: String
    var scheme: String
    var host: String
    var port: Int
    var username: String?
    var secretId: String?
    var geo: String?
    var apiMode: Int
    var isDefault: Int
    var createdAt: Int64
    var updatedAt: Int64

    init(_ p: ProxyProfile) {
        id = p.id.uuidString; name = p.name; preset = p.preset.rawValue; scheme = p.scheme.rawValue; host = p.host; port = p.port
        username = p.username; secretId = p.secretID; geo = p.geo?.country; apiMode = p.apiMode ? 1 : 0; isDefault = p.isDefault ? 1 : 0
        createdAt = RowCodec.ms(p.createdAt); updatedAt = RowCodec.ms(p.updatedAt)
    }
}

struct ProxyExtRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "proxy_ext"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var proxyId: String
    var secretStorage: String
    var geoJson: String?
    var renderEndpoint: String?
    var caPem: String?
    var pricePerRequestMicros: Int64?
    var pricePerRenderMicros: Int64?

    init(_ p: ProxyProfile) throws {
        proxyId = p.id.uuidString; secretStorage = p.secretStorage.rawValue
        geoJson = try p.geo.map { try RowCodec.json($0) }
        renderEndpoint = p.renderEndpoint; caPem = p.caPEM
        pricePerRequestMicros = p.pricePerRequestMicros; pricePerRenderMicros = p.pricePerRenderMicros
    }
}

extension ProxyRecord {
    func domain(ext: ProxyExtRecord?) throws -> ProxyProfile {
        var geo: ProxyGeo?
        if let json = ext?.geoJson { geo = try RowCodec.decode(ProxyGeo.self, json, table: "proxy_ext") }
        return ProxyProfile(
            id: try RowCodec.id(id, table: "proxy"), name: name, preset: try RowCodec.enumValue(preset, ProxyPreset.self, table: "proxy"),
            scheme: try RowCodec.enumValue(scheme, ProxyScheme.self, table: "proxy"), host: host, port: port, username: username,
            secretID: secretId, secretStorage: try RowCodec.enumValue(ext?.secretStorage ?? "vault", ProxySecretStorage.self, table: "proxy_ext"),
            geo: geo, apiMode: apiMode == 1, renderEndpoint: ext?.renderEndpoint, caPEM: ext?.caPem,
            pricePerRequestMicros: ext?.pricePerRequestMicros, pricePerRenderMicros: ext?.pricePerRenderMicros,
            isDefault: isDefault == 1, createdAt: RowCodec.date(createdAt as Int64) as Date, updatedAt: RowCodec.date(updatedAt as Int64) as Date)
    }
}
