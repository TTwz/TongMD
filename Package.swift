// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TongMD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TongMD",
            path: "Sources/TongMD",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
