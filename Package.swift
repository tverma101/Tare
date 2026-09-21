// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Tare",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TranscriberCore",
            targets: ["TranscriberCore"]
        ),
        .executable(
            name: "Tare",
            targets: ["Tare"]
        ),
        .executable(
            name: "TranscriberCoreSmokeTests",
            targets: ["TranscriberCoreSmokeTests"]
        ),
        .executable(
            name: "TranscriberBatch",
            targets: ["TranscriberBatch"]
        )
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            path: "Sources/TranscriberCore"
        ),
        .executableTarget(
            name: "Tare",
            dependencies: ["TranscriberCore"],
            path: "Sources/LocalVideoTranscriber"
        ),
        .executableTarget(
            name: "TranscriberCoreSmokeTests",
            dependencies: ["TranscriberCore"],
            path: "Sources/TranscriberCoreSmokeTests"
        ),
        .executableTarget(
            name: "TranscriberBatch",
            dependencies: ["TranscriberCore"],
            path: "Sources/TranscriberBatch"
        )
    ]
)
