// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LustreAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LustreCore", targets: ["LustreCore"]),
        .library(name: "LustreAgent", targets: ["LustreAgent"]),
        .executable(name: "lustre-agent", targets: ["lustre-agent"]),
        .executable(name: "lustre-auth-helper", targets: ["lustre-auth-helper"]),
        .executable(name: "lustre", targets: ["lustre"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LustreCore", dependencies: ["CSQLite"]),
        .target(name: "LustreAgent", dependencies: ["LustreCore"]),
        .executableTarget(name: "lustre-agent", dependencies: ["LustreAgent"]),
        .executableTarget(name: "lustre-auth-helper", dependencies: ["LustreAgent"]),
        .executableTarget(name: "lustre", dependencies: ["LustreCore", "LustreAgent"]),
        .testTarget(name: "LustreCoreTests", dependencies: ["LustreCore", "LustreAgent"])
    ]
)
