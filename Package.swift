// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmniWM",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "OmniWM",
            targets: ["OmniWM"]
        )
    ],
    targets: [
        .executableTarget(
            name: "OmniWM",
            path: "Sources/OmniWM",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
