// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "yt-grab-macos",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "yt-grab-macos",
            path: "Sources"
        ),
    ],
    swiftLanguageModes: [.v6]
)
