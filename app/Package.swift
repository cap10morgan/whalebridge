// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Whalebridge",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Whalebridge",
            path: "Sources/Whalebridge",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
