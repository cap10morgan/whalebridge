// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Whalebridge",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "Whalebridge",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Whalebridge",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Sparkle.framework is copied into Contents/Frameworks by bundle.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
