// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCodexCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "CodexCore", targets: ["CodexCore"]),
        .library(name: "CodexCoreJustBash", targets: ["CodexCoreJustBash"]),
        .executable(name: "codex-core-example", targets: ["CodexCoreExample"])
    ],
    dependencies: [
        .package(name: "JustBash", path: "../just-bash-swift")
    ],
    targets: [
        .target(
            name: "CodexCore"
        ),
        .target(
            name: "CodexCoreJustBash",
            dependencies: [
                "CodexCore",
                .product(name: "JustBash", package: "JustBash")
            ]
        ),
        .executableTarget(
            name: "CodexCoreExample",
            dependencies: ["CodexCore"]
        ),
        .testTarget(
            name: "CodexCoreTests",
            dependencies: ["CodexCore"]
        ),
        .testTarget(
            name: "CodexCoreJustBashTests",
            dependencies: ["CodexCoreJustBash"]
        )
    ]
)
