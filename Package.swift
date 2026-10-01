// swift-tools-version: 6.0
import PackageDescription
import Foundation

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let photoArchitecture = ProcessInfo.processInfo.environment["CROSSDIFF_ARCH"] ?? {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}()
let photoInstall = projectRoot + "/.build/photo-deps/install-" + photoArchitecture

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
        .target(name: "PhotoCVBridge", publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I", photoInstall + "/include/opencv4",
                "-ffile-prefix-map=" + projectRoot + "=.", "-fdebug-prefix-map=" + projectRoot + "=."])],
            linkerSettings: [.unsafeFlags(["-L", photoInstall + "/lib"]),
                .linkedLibrary("opencv_imgproc"), .linkedLibrary("opencv_core"), .linkedLibrary("c++"), .linkedLibrary("z")]),
        .executableTarget(name: "CrossDiff", dependencies: ["CrossDiffCore", "PhotoCVBridge"]),
        .executableTarget(name: "CrossDiffPluginHost", linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .executableTarget(name: "CrossDiffChecks", dependencies: ["CrossDiffCore"], path: "Checks"),
        .testTarget(name: "CrossDiffCoreTests", dependencies: ["CrossDiffCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
