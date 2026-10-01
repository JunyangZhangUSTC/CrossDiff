// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrossDiff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CrossDiff", targets: ["CrossDiff"]),
        .executable(name: "CrossDiffPluginHost", targets: ["CrossDiffPluginHost"]),
        .executable(name: "CrossDiffChecks", targets: ["CrossDiffChecks"])
    ],
    targets: [
        .target(name: "CrossDiffCore"),
        .executableTarget(name: "CrossDiff", dependencies: ["CrossDiffCore"]),
        .executableTarget(name: "CrossDiffPluginHost", linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .executableTarget(name: "CrossDiffChecks", dependencies: ["CrossDiffCore"], path: "Checks"),
        .testTarget(name: "CrossDiffCoreTests", dependencies: ["CrossDiffCore"])
    ],
    swiftLanguageModes: [.v5]
)
