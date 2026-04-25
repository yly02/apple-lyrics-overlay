// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "apple-lyrics-overlay",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .executableTarget(
            name: "apple-lyrics-overlay"
        ),
    ],
    swiftLanguageModes: [.v6]
)
