// swift-tools-version: 6.0

import Foundation
import PackageDescription

guard let rivetRoot = ProcessInfo.processInfo.environment["RIVET_ROOT"],
      !rivetRoot.isEmpty else {
    fatalError("RIVET_ROOT is not set. Build this app through raco rivet build/dev.")
}

guard let racketFrameworkDir = ProcessInfo.processInfo.environment["RIVET_RACKET_FRAMEWORK_DIR"],
      !racketFrameworkDir.isEmpty else {
    fatalError("RIVET_RACKET_FRAMEWORK_DIR is not set. Build this app through raco rivet build/dev.")
}

let macosMinVersion = ProcessInfo.processInfo.environment["RIVET_MACOS_MIN_VERSION"] ?? "14.0"

let package = Package(
    name: "RivetHost",
    platforms: [.macOS(macosMinVersion)],
    dependencies: [
        .package(path: rivetRoot + "/platform/macos")
    ],
    targets: [
        .executableTarget(
            name: "RivetHost",
            dependencies: [
                .product(name: "RivetRuntime", package: "macos"),
                .product(name: "RivetEmbedding", package: "macos"),
                .product(name: "RivetSystem", package: "macos")
            ],
            path: "Sources/RivetHost",
            linkerSettings: [
                .unsafeFlags(["-F", racketFrameworkDir]),
                .linkedFramework("Racket")
            ]
        )
    ]
)
