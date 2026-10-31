// swift-tools-version: 6.2
// RackyKit - pacote local do rebuild (08 AR-121). Versões externas exatas conforme scripts/tool-versions.txt.
// Isolamento padrão (AR-402): UI e DesignSystem em MainActor; demais alvos nonisolated + NonisolatedNonsendingByDefault.
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .treatAllWarnings(as: .error),
]
let nonisolatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .treatAllWarnings(as: .error),
]

let swiftTerm: Target.Dependency = .product(name: "SwiftTerm", package: "SwiftTerm")
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let argumentParser: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")
let postgresNIO: Target.Dependency = .product(name: "PostgresNIO", package: "postgres-nio")
let snapshotTesting: Target.Dependency = .product(name: "SnapshotTesting", package: "swift-snapshot-testing")

let containerization: Target.Dependency = .product(name: "Containerization", package: "containerization")
let containerizationOCI: Target.Dependency = .product(name: "ContainerizationOCI", package: "containerization")
let containerizationExtras: Target.Dependency = .product(name: "ContainerizationExtras", package: "containerization")
let containerizationOS: Target.Dependency = .product(name: "ContainerizationOS", package: "containerization")
let containerizationArchive: Target.Dependency = .product(name: "ContainerizationArchive", package: "containerization")
let containerizationEXT4: Target.Dependency = .product(name: "ContainerizationEXT4", package: "containerization")

func lib(_ name: String, _ deps: [Target.Dependency], ui: Bool = false, resources: [Resource] = []) -> Target {
    .target(name: name, dependencies: deps, resources: resources, swiftSettings: ui ? mainActorSettings : nonisolatedSettings)
}
func tests(_ name: String, _ deps: [Target.Dependency], resources: [Resource] = []) -> Target {
    .testTarget(name: name, dependencies: deps, resources: resources, swiftSettings: nonisolatedSettings)
}

let package = Package(
    name: "RackyKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RackyProtocol", targets: ["RackyProtocol"]),
        .library(name: "RackyPlatform", targets: ["RackyPlatform"]),
        .library(name: "RackyTerminalCore", targets: ["RackyTerminalCore"]),
        .library(name: "RackyStore", targets: ["RackyStore"]),
        .library(name: "RackyDocker", targets: ["RackyDocker"]),
        .library(name: "RackyVZ", targets: ["RackyVZ"]),
        .library(name: "RackyCore", targets: ["RackyCore"]),
        .library(name: "RackyDesignSystem", targets: ["RackyDesignSystem"]),
        .library(name: "RackyUI", targets: ["RackyUI"]),
        .executable(name: "rackyd", targets: ["rackyd"]),
        .executable(name: "rackyd-launch", targets: ["rackyd-launch"]),
        .executable(name: "racky", targets: ["racky"]),
        .executable(name: "racky-bench", targets: ["RackyBench"]),
        .executable(name: "racky-vz-selftest", targets: ["RackyVZSelfTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", exact: "1.19.6"),
        // Conector PostgreSQL/Supabase/RDS da área Data (só leitura). Exata; só o RackyCore a importa.
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.2"),
        // Runtime sem Docker (RackyVZ): VMs Linux leves sobre Virtualization.framework. Exata; só o alvo RackyVZ a importa.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.52.1"),
    ],
    targets: [
        lib("RackyProtocol", []),
        lib("RackyPlatform", ["RackyProtocol"]),
        lib("RackyTerminalCore", [swiftTerm]),
        lib("RackyStore", ["RackyPlatform", "RackyProtocol", grdb]),
        lib("RackyDocker", ["RackyPlatform", "RackyProtocol"]),
        lib("RackyCore", ["RackyProtocol", "RackyPlatform", "RackyStore", "RackyDocker", postgresNIO]),
        // Backend de computadores sem Docker (VMs via apple/containerization). Isolado: RackyDocker e RackyCore não o importam.
        lib("RackyVZ", ["RackyProtocol", "RackyPlatform", "RackyDocker", "RackyCore", containerization, containerizationOCI, containerizationExtras, containerizationOS, containerizationEXT4]),
        lib("RackyDesignSystem", ["RackyProtocol"], ui: true, resources: [.copy("Resources/Fonts"), .copy("Resources/AgentLogos")]),
        // T3-05: viewer noVNC (vendorizado, v1.6.0) num WKWebView isolado, servido por esquema local (07 CS-401, 00 T8).
        lib("RackyViewerKit", [], ui: true, resources: [.copy("Resources/Viewer")]),
        lib(
            "RackyUI", ["RackyCore", "RackyStore", "RackyDesignSystem", "RackyTerminalCore", "RackyViewerKit", "RackyVZ", swiftTerm], ui: true,
            resources: [.process("Resources")]  // String Catalog (lint-ui exige strings no catálogo)
        ),
        .executableTarget(
            name: "rackyd",
            dependencies: ["RackyProtocol", "RackyPlatform", "RackyTerminalCore"],
            // Modo ad-hoc de desenvolvimento do peer auth (S-03/T1-07): só em debug por padrão; build.sh liga em Release
            // apenas quando assina ad-hoc. O daemon ainda confere que ele próprio é ad-hoc antes de usar o modo.
            swiftSettings: nonisolatedSettings + [.define("RACKY_ALLOW_ADHOC_PEERS", .when(configuration: .debug))]
        ),
        // Launcher estável do LaunchAgent (T1-24, S-01): C puro, só faz `exec` do `rackyd`; ver main.c.
        .executableTarget(name: "rackyd-launch"),
        .executableTarget(
            name: "racky",
            dependencies: ["RackyProtocol", "RackyPlatform", argumentParser],
            swiftSettings: nonisolatedSettings
        ),
        // Autoteste/CLI do backend VZ (precisa do entitlement de virtualização: scripts/vz/selftest.sh compila e assina).
        .executableTarget(name: "RackyVZSelfTest", dependencies: ["RackyVZ", "RackyCore", "RackyDocker", "RackyPlatform", "RackyProtocol", containerization, containerizationOCI, containerizationArchive], swiftSettings: nonisolatedSettings),
        // Cliente de teste do peer auth (T1-07); fora de `products`, só os testes o usam.
        .executableTarget(name: "peerprobe", dependencies: ["RackyProtocol", "RackyPlatform"], swiftSettings: nonisolatedSettings),
        .executableTarget(
            name: "RackyBench",
            dependencies: ["RackyUI", "RackyCore", "RackyProtocol", "RackyPlatform", swiftTerm],
            swiftSettings: mainActorSettings
        ),
        tests("ProtocolTests", ["RackyProtocol"], resources: [.copy("Fixtures")]),
        tests("PlatformTests", ["RackyPlatform", "RackyProtocol"]),
        tests("StoreTests", ["RackyStore", "RackyProtocol", "RackyPlatform", grdb]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["RackyCore", "RackyProtocol", "RackyPlatform", "RackyStore", "RackyDocker", "racky", postgresNIO],
            exclude: ["Launch/Fixtures", "Launch/Golden", "GitHub/Fixtures", "Computers/Orchestration/Fixtures"], // lidos por caminho (#filePath); golden gravado com RACKY_UPDATE_GOLDEN=1
            swiftSettings: nonisolatedSettings
        ),
        tests("VZTests", ["RackyVZ", "RackyDocker", "RackyCore", "RackyPlatform", "RackyProtocol", "RackyVZSelfTest"]),
        tests("DockerTests", ["RackyDocker", "RackyPlatform"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ViewerKitTests", dependencies: ["RackyViewerKit"], swiftSettings: mainActorSettings),
        tests("TerminalCoreTests", ["RackyTerminalCore", swiftTerm]),
        tests("DesignSystemTests", ["RackyDesignSystem"]),
        tests("DaemonTests", ["RackyProtocol", "RackyPlatform", "RackyTerminalCore", "RackyCore", "RackyStore", "rackyd", "peerprobe", swiftTerm]),
        .testTarget(
            name: "TerminalSurfaceTests",
            dependencies: ["RackyUI", "RackyCore", "RackyStore", "RackyProtocol", "RackyPlatform", "RackyTerminalCore", "RackyDesignSystem", "rackyd", swiftTerm],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "UISnapshotTests",
            // `racky` e Core: a integração de atenção dispara eventos de hook reais pelo helper contra o app em processo.
            dependencies: ["RackyUI", "RackyDesignSystem", "RackyStore", "RackyCore", "RackyProtocol", "RackyPlatform", "racky", snapshotTesting],
            exclude: ["__Snapshots__"],  // referências PNG do swift-snapshot-testing, lidas por caminho
            swiftSettings: mainActorSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
