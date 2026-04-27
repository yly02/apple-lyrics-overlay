// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "apple-lyrics-overlay",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .executableTarget(name: "apple-lyrics-overlay"),
        .executableTarget(name: "lyrics-menubar-helper"),
    ],
    swiftLanguageModes: [.v6]
)
