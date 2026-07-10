// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MongoMigrator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MongoMigrator", targets: ["MongoMigrator"]),
        .executable(name: "MongoMigratorMCP", targets: ["MongoMigratorMCP"])
    ],
    targets: [
        .executableTarget(
            name: "MongoMigrator",
            path: "Sources/MongoMigrator"
        ),
        .executableTarget(
            name: "MongoMigratorMCP",
            path: "Sources/MongoMigratorMCP"
        )
    ]
)
