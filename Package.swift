// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCodexCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "CodexCore", targets: ["CodexCore"]),
        .executable(name: "codex-core-example", targets: ["CodexCoreExample"])
    ],
    targets: [
        .target(
            name: "CodexCore"
        ),
        .executableTarget(
            name: "CodexCoreExample",
            dependencies: ["CodexCore"]
        ),
        .testTarget(
            name: "CodexCoreTests",
            dependencies: ["CodexCore"]
        )
    ]
)
