// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
]

let package = Package(
    name: "paperd",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PaperdCore", targets: ["PaperdCore"]),
        .executable(name: "paperd-mcp", targets: ["PaperdMCP"]),
        .executable(name: "Paperd", targets: ["Paperd"]),
        .executable(name: "paperd-cli", targets: ["PaperdCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // 共有ロジック（DB / 検索 / bibtex / メタデータ解決 / ライブラリレイアウト / ジョブ）
        .target(
            name: "PaperdCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
        // MCPサーバのロジック（stdio JSON-RPC自前実装の薄い層）。テスト可能にするためCLI本体と分離
        .target(
            name: "PaperdMCPKit",
            dependencies: ["PaperdCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "PaperdMCP",
            dependencies: ["PaperdMCPKit"],
            swiftSettings: swiftSettings
        ),
        // macOSアプリ（最小UI: 3ペイン・リスト・BibTeXコピー・FTS検索）
        .executableTarget(
            name: "Paperd",
            dependencies: ["PaperdCore"],
            swiftSettings: swiftSettings
        ),
        // ヘッドレス運用・E2E検証用CLI
        .executableTarget(
            name: "PaperdCLI",
            dependencies: ["PaperdCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PaperdTests",
            dependencies: ["PaperdCore", "PaperdMCPKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
