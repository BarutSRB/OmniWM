// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmniWM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "OmniWM",
            targets: ["OmniWMApp"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        // Wraps the Zig-compiled static library so Swift can `import CZigLayout`.
        // The actual .a is produced by `make zig-build` (or ./build-zig.sh) and
        // linked via OmniWM's linkerSettings below.
        .systemLibrary(
            name: "CZigLayout",
            path: "Sources/CZigLayout",
            pkgConfig: nil,
            providers: nil
        ),
        .target(
            name: "OmniWM",
            dependencies: ["GhosttyKit", "CZigLayout"],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.C),
                .define("OMNI_NIRI_LEGACY_TEST_BACKEND", .when(configuration: .debug)),
                // Test/reference-only Dwindle backend toggle. Runtime selection is additionally
                // guarded to XCTest environments in DwindleLayoutEngine.
                .define("OMNI_DWINDLE_LEGACY_TEST_BACKEND", .when(configuration: .debug)),
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .linkedLibrary("omni_layout"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight",
                               "-L.build/zig"])
            ]
        ),
        .executableTarget(
            name: "OmniWMApp",
            dependencies: ["OmniWM"],
            path: "Sources/OmniWMApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: ["OmniWM"],
            path: "Tests/OmniWMTests",
            resources: [
                .process("Benchmarks")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
