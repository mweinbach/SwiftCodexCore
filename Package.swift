// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SwiftCodexCore",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "CodexCore", targets: ["CodexCore"]),
    .library(name: "CodexCoreJustBash", targets: ["CodexCoreJustBash"]),
    .executable(name: "codex-core-example", targets: ["CodexCoreExample"]),
    .executable(name: "codex-code-mode-host", targets: ["CodexCodeModeHost"]),
  ],
  dependencies: [
    .package(url: "https://github.com/mweinbach/just-bash-swift", branch: "main")
  ],
  targets: [
    .target(
      name: "CodexCore",
      linkerSettings: [.linkedFramework("JavaScriptCore")]
    ),
    .target(
      name: "CodexCoreJustBash",
      dependencies: [
        "CodexCore",
        .product(name: "JustBash", package: "just-bash-swift"),
      ]
    ),
    .executableTarget(
      name: "CodexCoreExample",
      dependencies: ["CodexCore"]
    ),
    .executableTarget(
      name: "CodexCodeModeHost",
      dependencies: ["CodexCore"]
    ),
    .testTarget(
      name: "CodexCoreTests",
      dependencies: ["CodexCore"]
    ),
    .testTarget(
      name: "CodexCoreJustBashTests",
      dependencies: ["CodexCoreJustBash"]
    ),
  ]
)
