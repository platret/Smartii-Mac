// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Smartii",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Smartii",
            path: "Sources/Smartii",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
