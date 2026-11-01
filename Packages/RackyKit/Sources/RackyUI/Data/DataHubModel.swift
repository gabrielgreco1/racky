import Foundation
import RackyDesignSystem
import RackyStore

// Área Data (spec data-hub): o que está no Racky (datasets dos agentes) e o que está fora (conexões). Estes tipos descrevem lugares
// e objetos para o explorer, as tabs e a barra de localização. Na etapa 2 as conexões vêm de exemplo (`DataHubFixtures`); a etapa 3
// liga os drivers de verdade.

/// Tipo de conexão. A família decide o ícone, o agrupamento no "Add connection" e o que dá para fazer.
public enum DataConnectionKind: String, CaseIterable, Sendable, Codable {
    case postgres, supabase, mysql, sqlServer, sqlite
    case bigQuery, snowflake, clickHouse, databricks
    case s3, gcs, r2
    case googleSheets, airtable
    case webhook
    case prefect

    public enum Family: String, CaseIterable, Sendable { case database, warehouse, storage, spreadsheet, outgoing, orchestrator }

    public var family: Family {
        switch self {
        case .postgres, .supabase, .mysql, .sqlServer, .sqlite: .database
        case .bigQuery, .snowflake, .clickHouse, .databricks: .warehouse
        case .s3, .gcs, .r2: .storage
        case .googleSheets, .airtable: .spreadsheet
        case .webhook: .outgoing
        case .prefect: .orchestrator
        }
    }

    public var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .supabase: "Supabase"
        case .mysql: "MySQL"
        case .sqlServer: "SQL Server"
        case .sqlite: "SQLite"
        case .bigQuery: "BigQuery"
        case .snowflake: "Snowflake"
        case .clickHouse: "ClickHouse"
        case .databricks: "Databricks"
        case .s3: "Amazon S3"
        case .gcs: "Google Cloud Storage"
        case .r2: "Cloudflare R2"
        case .googleSheets: "Google Sheets"
        case .airtable: "Airtable"
        case .webhook: "Webhook"
        case .prefect: "Prefect"
        }
    }

    /// O logo do tipo (cor da marca).
    public var brand: DSDataBrand {
        switch self {
        case .postgres: .postgres
        case .supabase: .supabase
        case .mysql: .mysql
        case .sqlServer: .sqlServer
        case .sqlite: .sqlite
        case .bigQuery: .bigQuery
        case .snowflake: .snowflake
        case .clickHouse: .clickHouse
        case .databricks: .databricks
        case .s3: .s3
        case .gcs: .gcs
        case .r2: .r2
        case .googleSheets: .googleSheets
        case .airtable: .airtable
        case .webhook: .webhook
        case .prefect: .prefect
        }
    }

    /// Uma linha que diz o que é ("Postgres hosted by Supabase").
    public var tagline: String {
        switch self {
        case .postgres: String(localized: "Any Postgres (RDS, Neon, self-hosted)", bundle: .module)
        case .supabase: String(localized: "Postgres hosted by Supabase", bundle: .module)
        case .mysql: String(localized: "MySQL or MariaDB", bundle: .module)
        case .sqlServer: String(localized: "SQL Server or Azure SQL", bundle: .module)
        case .sqlite: String(localized: "A database file on this Mac", bundle: .module)
        case .bigQuery: String(localized: "Google Cloud data warehouse", bundle: .module)
        case .snowflake: String(localized: "Snowflake data warehouse", bundle: .module)
        case .clickHouse: String(localized: "Fast analytics database", bundle: .module)
        case .databricks: String(localized: "Lakehouse tables", bundle: .module)
        case .s3: String(localized: "Files in an AWS bucket", bundle: .module)
        case .gcs: String(localized: "Files in a Google Cloud bucket", bundle: .module)
        case .r2: String(localized: "Files in a Cloudflare bucket", bundle: .module)
        case .googleSheets: String(localized: "Rows in a spreadsheet tab", bundle: .module)
        case .airtable: String(localized: "Rows in an Airtable base", bundle: .module)
        case .webhook: String(localized: "Post new rows to a URL", bundle: .module)
        case .prefect: String(localized: "See what your flows are running now", bundle: .module)
        }
    }

    /// Webhook só recebe; o resto dá para navegar e gravar.
    public var canBrowse: Bool { self != .webhook }
    /// Dá para conectar de verdade hoje (os outros tipos ainda são de exemplo; o card diz "Soon").
    public var connectable: Bool { self == .prefect || self == .s3 || speaksPostgres }
    /// Fala o protocolo do Postgres (PostgreSQL puro, RDS, Neon, Supabase): conecta de verdade com uma connection string.
    public var speaksPostgres: Bool { self == .postgres || self == .supabase }
    public var speaksSQL: Bool { family == .database || family == .warehouse }
}

public struct DataConnection: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: DataConnectionKind
    /// Nome que o usuário deu ("Supabase", "Analytics").
    public var name: String
    /// Etiquetas que o usuário cria (prod, cliente-x, teste…): só identificam, não mudam comportamento.
    public var tags: [String] = []
    /// Protegida: o Racky pede confirmação antes de qualquer coisa que altere dados e mostra os avisos (faixa, formulário de sessão).
    public var protected = false
    /// Onde fica (host, projeto, bucket, URL), sem segredo.
    public var address: String
    public var children: [DataNode]
}

/// Um nó do explorer dentro de uma conexão.
public struct DataNode: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case schema, table, view, bucket, folder, file, spreadsheet, sheet, runs }
    public var id: String
    public var kind: Kind
    public var name: String
    /// Linhas (tabela, aba) ou bytes (arquivo).
    public var size: Int?
    public var children: [DataNode] = []
    /// Os filhos só se leem ao abrir (bucket do S3): mostra a seta mesmo sem filhos ainda.
    public var lazy = false
}

/// O que está aberto numa tab da área Data.
public enum DataObject: Hashable, Sendable {
    case dataset(String)
    case table(connection: String, schema: String, name: String)
    case query(connection: String, id: Int)
    case folder(connection: String, path: [String])
    case webhook(connection: String)
    case tab(connection: String, spreadsheet: String, name: String)
    /// Flow runs de um orquestrador (Prefect): o que está rodando, agendado e o que falhou.
    case runs(connection: String)
    /// Notebook Python (Jupyter) com datasets do Racky; o valor é o nome do notebook.
    case notebook(String)

    public var connectionID: String? {
        switch self {
        case .dataset, .notebook: nil
        case .table(let c, _, _), .query(let c, _), .folder(let c, _), .webhook(let c), .tab(let c, _, _), .runs(let c): c
        }
    }
}

/// Quem grava num lugar: um agente (com a sessão) ou um sync.
public struct DataWriter: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case agent(session: String), sync(from: DataObject) }
    public var id: String
    public var kind: Kind
    /// "Codex 1", "Sync from books2".
    public var name: String
    public var live: Bool
    /// "every new row", "daily at 06:00", "last run 3m ago".
    public var detail: String
}

/// Para onde algo vai (a seta → da linha de fluxo).
public struct DataDestination: Identifiable, Equatable, Sendable {
    public var id: String
    public var target: DataObject
    public var detail: String
}

/// Grade simples de uma tabela, arquivo ou resultado de consulta (exemplo na etapa 2).
public struct DataGrid: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var name: String
        public var type: String
        public var key = false
        public var nullable = true
    }
    public var columns: [Column]
    public var rows: [[String]]
    public var total: Int
}

/// Uma entrega a um webhook (log).
public struct DataDelivery: Identifiable, Equatable, Sendable {
    public var id: Int
    public var at: Date
    public var status: Int
    public var rows: Int
    public var milliseconds: Int
}

/// Uma conexão que o usuário adicionou (não de exemplo): o que fica salvo no app. A senha ou chave fica no cofre (`SecretVault`),
/// aqui só o id dela.
nonisolated public struct SavedConnection: Codable, Equatable, Sendable, Identifiable {
    public enum AuthKind: String, Codable, Sendable {
        case none, basic, apiKey
        /// Postgres/Supabase: a connection string inteira (com a senha) é o segredo do cofre.
        case connectionString
    }
    public var id: String
    public var kind: DataConnectionKind
    public var name: String
    /// URL do servidor (Prefect: a base da API, `…/api`; Postgres: só `host:porta/banco`, a string de conexão fica no cofre).
    public var url: String
    public var auth: AuthKind
    public var secretID: UUID?
    public var tags: [String] = []
    public var protected = false
    /// Amazon S3: região, bucket e como autenticar (as chaves ficam no cofre, nunca aqui).
    public var s3: S3Settings?

    public var connection: DataConnection {
        DataConnection(id: id, kind: kind, name: name, tags: tags, protected: protected, address: url, children: [])
    }
}
