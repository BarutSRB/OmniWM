// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
struct BuildMetadata {
    let macOSDeploymentTarget: String
    let requiredZigVersion: String
    let ghosttyArchiveRelativePath: String
    let ghosttyArchiveSHA256: String

    static func load(packageDirectory: String) -> BuildMetadata {
        let metadataURL = URL(fileURLWithPath: packageDirectory).appendingPathComponent("Scripts/build-metadata.env")
        guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8) else {
            fatalError("Missing build metadata at \(metadataURL.path)")
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                fatalError("Invalid build metadata line: \(line)")
            }

            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func require(_ key: String) -> String {
            guard let value = values[key], !value.isEmpty else {
                fatalError("Missing \(key) in \(metadataURL.path)")
            }
            return value
        }

        return BuildMetadata(
            macOSDeploymentTarget: require("OMNIWM_MACOS_DEPLOYMENT_TARGET"),
            requiredZigVersion: require("OMNIWM_REQUIRED_ZIG_VERSION"),
            ghosttyArchiveRelativePath: require("OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH"),
            ghosttyArchiveSHA256: require("OMNIWM_GHOSTTY_ARCHIVE_SHA256")
        )
    }
}

let buildMetadata = BuildMetadata.load(packageDirectory: packageDirectory)
let ghosttyArchiveURL = URL(fileURLWithPath: packageDirectory).appendingPathComponent(buildMetadata.ghosttyArchiveRelativePath)
let ghosttyMacOSLibraryDirectory = ghosttyArchiveURL.deletingLastPathComponent().path

func zigKernelSwiftPMLibraryDirectory(for configuration: String) -> String {
    "\(packageDirectory)/.build/plugins/outputs/omniwm/OmniWM/destination/OmniWMKernelsBuildPlugin/zig-kernels/\(configuration)/lib"
}

let zigKernelDebugLibraryFlags = [
    "-L\(zigKernelSwiftPMLibraryDirectory(for: "debug"))"
]
let zigKernelReleaseLibraryFlags = [
    "-L\(zigKernelSwiftPMLibraryDirectory(for: "release"))"
]

let package = Package(
    name: "OmniWM",
    platforms: [
        .macOS(buildMetadata.macOSDeploymentTarget)
    ],
    products: [
        .executable(
            name: "OmniWM",
            targets: ["OmniWMApp"]
        ),
        .executable(
            name: "omniwmctl",
            targets: ["OmniWMCtl"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")
    ],
    targets: [
        .plugin(
            name: "OmniWMKernelsBuildPlugin",
            capability: .buildTool(),
            path: "Plugins/OmniWMKernelsBuildPlugin"
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "COmniWMKernels",
            path: "Sources/COmniWMKernels",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OmniWMIPC",
            dependencies: ["COmniWMKernels"],
            path: "Sources/OmniWMIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedLibrary("omniwm_kernels"),
                .unsafeFlags(zigKernelDebugLibraryFlags, .when(configuration: .debug)),
                .unsafeFlags(zigKernelReleaseLibraryFlags, .when(configuration: .release))
            ],
            plugins: [
                .plugin(name: "OmniWMKernelsBuildPlugin")
            ]
        ),
        .target(
            name: "OmniWM",
            dependencies: [
                "GhosttyKit",
                "OmniWMIPC",
                "COmniWMKernels",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.C),
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("omniwm_kernels"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .unsafeFlags(zigKernelDebugLibraryFlags, .when(configuration: .debug)),
                .unsafeFlags(zigKernelReleaseLibraryFlags, .when(configuration: .release)),
                .unsafeFlags(["-L\(ghosttyMacOSLibraryDirectory)"]),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ],
            plugins: [
                .plugin(name: "OmniWMKernelsBuildPlugin")
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
        .executableTarget(
            name: "OmniWMCtl",
            dependencies: ["OmniWMIPC"],
            path: "Sources/OmniWMCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedLibrary("omniwm_kernels"),
                .unsafeFlags(zigKernelDebugLibraryFlags, .when(configuration: .debug)),
                .unsafeFlags(zigKernelReleaseLibraryFlags, .when(configuration: .release))
            ],
            plugins: [
                .plugin(name: "OmniWMKernelsBuildPlugin")
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: ["OmniWM", "OmniWMIPC", "OmniWMCtl", "COmniWMKernels"],
            path: "Tests/OmniWMTests",
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedLibrary("omniwm_kernels"),
                .unsafeFlags(zigKernelDebugLibraryFlags, .when(configuration: .debug)),
                .unsafeFlags(zigKernelReleaseLibraryFlags, .when(configuration: .release))
            ],
            plugins: [
                .plugin(name: "OmniWMKernelsBuildPlugin")
            ]
        )
    ]
)
