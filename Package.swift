// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nits",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nits",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .testTarget(
            name: "NitsTests",
            dependencies: ["Nits"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
