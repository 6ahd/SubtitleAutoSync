// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SubtitleAutoSync",
    platforms: [.iOS(.v15), .tvOS(.v15), .macOS(.v12), .visionOS(.v1)],
    products: [
        .library(name: "SubtitleAutoSync", targets: ["SubtitleAutoSync"]),
    ],
    targets: [
        .target(name: "SubtitleAutoSync"),
        .testTarget(
            name: "SubtitleAutoSyncTests",
            dependencies: ["SubtitleAutoSync"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
