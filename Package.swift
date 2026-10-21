// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clocked",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Clocked",
            path: "Sources/Clocked",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
